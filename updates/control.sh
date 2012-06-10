#!/bin/bash
# Copyright 2011, Dell
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# We get the following variables from start-up.sh
# MAC BOOTDEV ADMIN_IP DOMAIN HOSTNAME HOSTNAME_MAC MYIP

set -x

MYINDEX=${MYIP##*.}
DHCP_STATE=$(grep -o -E 'crowbar\.state=[^ ]+' /proc/cmdline)
DHCP_STATE=${DHCP_STATE#*=}
MAXTRIES=5
BMC_ADDRESS=""
BMC_NETMASK=""
BMC_ROUTER=""
ALLOCATED=false
export DHCP_STATE MYINDEX BMC_ADDRESS BMC_NETMASK BMC_ROUTER ADMIN_IP
export ALLOCATED HOSTNAME CROWBAR_KEY CROWBAR_STATE

# Make sure date is up-to-date
until /usr/sbin/ntpdate $ADMIN_IP || [[ $DHCP_STATE = 'debug' ]]
do
  echo "Waiting for NTP server"
  sleep 1
done

#
# rely on the DHCP server to do the right thing
# Stick with this address until we get finished.
#
killall dhclient
killall dhclient3

# HACK fix for chef-client
cd /root
gem install --local rest-client
cd -

# Other gem dependency installs.
cat > /etc/gemrc <<EOF
:sources:
- http://$ADMIN_IP:8091/gemsite/
gem: --no-ri --no-rdoc --bindir /usr/local/bin
EOF
gem install xml-simple
gem install libxml-ruby
gem install wsman
gem install cstruct

# Add full code set
if [ -e /updates/full_data.sh ] ; then
  cp /updates/full_data.sh /tmp
  /tmp/full_data.sh
fi

# Get stuff out of nfs.
cp /updates/parse_node_data /tmp

# get validation cert
curl -L -o /etc/chef/validation.pem \
    --connect-timeout 60 -s \
    "http://$ADMIN_IP:8091/validation.pem"

. "/updates/control_lib.sh"

nuke_everything() {
    # Make sure that the kernel knows about all the partitions
    for bd in /sys/block/sd*; do
        [[ -b /dev/${bd##*/} ]] || continue
        partprobe "/dev/${bd##*/}"
    done
    # and then wipe them all out.
    while read maj min blocks name; do
        [[ -b /dev/$name && -w /dev/$name && $name != name ]] || continue
        [[ $name = loop* ]] && continue
        [[ $name = dm* ]] && continue
        if (( blocks >= 2048)); then
            dd "if=/dev/zero" "of=/dev/$name" "bs=512" "count=2048"
            dd "if=/dev/zero" "of=/dev/$name" "bs=512" "count=2048" "seek=$(($blocks - 2048))"
        else
            dd "if=/dev/zero" "of=/dev/$name" "bs=512" "count=$blocks"
        fi
    done < <(tac /proc/partitions)

    ## for good measure, nuke partition tables on disks (nothing should remain bootable)
    for i in `ls /dev/sd?`; do  parted -m -s  $i mklabel bsd ; sleep 1 ; done
}

# If there are pre/post transition hooks for this state (per system or not),
# handle them.
run_hooks() {
    # $1 = hostname
    # $2 = state
    # $3 = pre or post
    local hookdirs=() hookdir='' hook=''
    # We only handle pre and post hooks.  Anything else is a bug in
    # control.sh that we should debug.
    case $3 in
        pre) hookdirs=("/updates/$1/$2-$3" "/updates/$2-$3");;
        post) hookdirs=("/updates/$2-$3" "/updates/$1/$2-$3");;
        *) post_state "$1" debug; reboot_system;;
    esac
    for hookdir in "${hookdirs[@]}"; do
        [[ -d $hookdir ]] || continue
        for hook in "$hookdir/"*.hook; do
            [[ -x $hook ]] || continue
            # If a hook fails, then Something Weird happened, and it
            # needs to be debugged.
            export HOOKSTATE="$2-$3" HOOKNAME="${hook##*/}"
            if "$hook"; then
                unset HOOKSTATE HOOKNAME
                get_state "$1"
                continue
            else
                post_state "$1" debug
                reboot_system
            fi
        done
    done
}

walk_node_through () {
    # $1 = hostname for chef-client run
    # $@ = states to walk through
    local name="$1" f='' state=''
    shift
    while (( $# > 1)); do
        state="$1"
        post_state "$name" "$1"
        run_hooks "$HOSTNAME" "$1" pre
        chef-client -S http://$ADMIN_IP:4000/ -N "$name"
        run_hooks "$HOSTNAME" "$1" post
        shift
    done
    state="$1"
    run_hooks "$HOSTNAME" "$1" pre
    report_state "$name" "$1"
    run_hooks "$HOSTNAME" "$1" post
}

# If there is a custom control.sh for this system, source it.
[[ -x /updates/$HOSTNAME/control.sh ]] && \
    . "/updates/$HOSTNAME/control.sh"

discover() {
    echo "Discovering with: $HOSTNAME_MAC"
    walk_node_through $HOSTNAME_MAC discovering discovered
    wait_for_allocated "$HOSTNAME"
}

hardware_install () {
    echo "Hardware installing with: $HOSTNAME"
    rm -f /etc/chef/client.pem
    nuke_everything
    walk_node_through $HOSTNAME hardware-installing hardware-installed
    nuke_everything
}

hwupdate () {
    walk_node_through $HOSTNAME hardware-updating hardware-updated
}

case $DHCP_STATE in
    discovery) discover && hardware_install;;
    hwinstall) hardware_install;;
    update) hwupdate;;
esac 2>&1 | tee -a /install-logs/$HOSTNAME-update.log
[[ $DHCP_STATE = 'debug' ]] && exit
reboot_system
