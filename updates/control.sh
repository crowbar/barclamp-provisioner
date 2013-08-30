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

if [[ ! $IN_SCRIPT ]]; then
    export IN_SCRIPT=true
    script -a -f -c "$0" "/var/log/crowbar/sledgehammer/$HOSTNAME_MAC.transcript"
    exit $?
fi
#set -x
export PS4='${BASH_SOURCE}@${LINENO}(${FUNCNAME[0]}): '

function is_suse {
    [ -f /etc/SuSE-release ]
}

#
# Override HOSTNAME if it is specified.  In kernel,
# This handles changing boot IFs in the middle of
# hardware updating.
#
# we could just use DHCP, but the discovery pass
# doesn't have a hostname in it.  So, we need to
# let the crowbar start-up script create our name.
# From then on, we can use DHCP (port-install) or
# kernel variable (pre-install).
#
hostname_re='crowbar\.hostname=([^ ]+)'
[[ $(cat /proc/cmdline) =~ $hostname_re ]] && \
    HOSTNAME="${BASH_REMATCH[1]}" || \
    HOSTNAME="d${MAC//:/-}.${DOMAIN}"
sed -i -e "s/\(127\.0\.0\.1.*\)/127.0.0.1 $HOSTNAME ${HOSTNAME%%.*} localhost.localdomain localhost/" /etc/hosts
if is_suse; then
    echo "$HOSTNAME" > /etc/HOSTNAME
else
    if [ -f /etc/sysconfig/network ] ; then
        sed -i -e "s/HOSTNAME=.*/HOSTNAME=${HOSTNAME}/" /etc/sysconfig/network
    fi
    echo "${HOSTNAME#*.}" >/etc/domainname
fi
hostname "$HOSTNAME"
HOSTNAME_MAC="$HOSTNAME"
export HOSTNAME HOSTNAME_MAC

ip_re='inet ([0-9.]+)/([0-9]+)'
ik_re='crowbar\.install\.key=([^ ]+)'

[[ $(cat /proc/cmdline) =~ $ik_re ]] && \
    export CROWBAR_KEY="${BASH_REMATCH[1]}"

RSYSLOGSERVICE=rsyslog
is_suse && {
 RSYSLOGSERVICE=syslog
}

# enable remote logging to our admin node.
if ! grep -q "${ADMIN_IP}" /etc/rsyslog.conf; then
    echo "# Sledgehammer added to log to the admin node" >> /etc/rsyslog.conf
    echo "*.* @@${ADMIN_IP}" >> /etc/rsyslog.conf
    service $RSYSLOGSERVICE restart
fi

# enable SSH access from admin node (same keys).
(umask 077 ; mkdir -p /root/.ssh)
curl -L -o /root/.ssh/authorized_keys \
     --connect-timeout 60 -s \
     "http://$ADMIN_IP:8091/authorized_keys"

MYINDEX=${MYIP##*.}
DHCP_STATE=$(grep -o -E 'crowbar\.state=[^ ]+' /proc/cmdline)
DHCP_STATE=${DHCP_STATE#*=}
echo "DHCP_STATE=$DHCP_STATE"
MAXTRIES=5
# ADMIN_ADDRESS is the address on the admin network; do not confuse with
# ADMIN_IP which is the IP of the admin node...
ADMIN_ADDRESS=""
BMC_ADDRESS=""
BMC_NETMASK=""
BMC_ROUTER=""
ALLOCATED=false
export DHCP_STATE MYINDEX ADMIN_ADDRESS BMC_ADDRESS BMC_NETMASK BMC_ROUTER ADMIN_IP
export ALLOCATED HOSTNAME CROWBAR_KEY CROWBAR_STATE

if is_suse; then
    ntp="sntp -P no -r $ADMIN_IP"
else
    ntp="/usr/sbin/ntpdate $ADMIN_IP"
fi

# Make sure date is up-to-date
until $ntp || [[ $DHCP_STATE = 'debug' ]]; do
  echo "Waiting for NTP server"
  sleep 1
done

#
# rely on the DHCP server to do the right thing
# Stick with this address until we get finished.
#
killall dhclient
killall dhclient3


if ! is_suse
then
  # HACK fix for chef-client
  if [ -e /root/rest-client*gem ]
  then
    pushd /root
    gem install --local rest-client
    popd
  fi

  # Other gem dependency installs.
  cat > /etc/gemrc <<EOF
:sources:
- http://$ADMIN_IP:8091/gemsite/
gem: --no-ri --no-rdoc --bindir /usr/local/bin
EOF
  gem install rest-client
  gem install xml-simple
  gem install libxml-ruby
  gem install wsman
  gem install cstruct
fi

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
    local uuid maj min blocks name
    # Make sure that the kernel knows about all the partitions
    for bd in /sys/block/sd*; do
        [[ -b /dev/${bd##*/} ]] || continue
        partprobe "/dev/${bd##*/}"
    done
    vgscan
    while read uuid; do
        vgremove -f "$uuid"
    done < <(vgs --noheading -o vg_name)
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
        # write new unique MBR signature
        # This initializes a random 32bit Disk signature used to
        # distinguish disks, which helps installing boot loader properly
        echo w | fdisk /dev/$name
    done < <(tac /proc/partitions)
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
[[ -n "$HOSTNAME" ]] && \
[[ -x /updates/$HOSTNAME/control.sh ]] && \
    . "/updates/$HOSTNAME/control.sh"

discover() {
    echo "Discovering with: $HOSTNAME"
    walk_node_through $HOSTNAME discovering discovered
}

hardware_install () {
    wait_for_allocated "$HOSTNAME"
    echo "Hardware installing with: $HOSTNAME"
    rm -f /etc/chef/client.pem
    nuke_everything
    walk_node_through $HOSTNAME hardware-installing hardware-installed
    nuke_everything
    # We want the os_install state, but its name changes depending on the OS.
    # For instance: suse-11.3_install. Since no other state end with
    # "_install", we're good enough with this regexp.
    wait_for_pxe_state ".*_install"
    walk_node_through $HOSTNAME installing
}

hwupdate () {
    walk_node_through $HOSTNAME hardware-updating hardware-updated
    wait_for_pxe_file "absent"
}

case $DHCP_STATE in
    reset|discovery) discover && hardware_install;;
    hwinstall) hardware_install;;
    update) hwupdate;;
esac 2>&1 | tee -a /var/log/crowbar/sledgehammer/$HOSTNAME.log
[[ $DHCP_STATE = 'debug' ]] && exit
reboot_system
