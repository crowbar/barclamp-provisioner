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

MYINDEX=${MYIP##*.}
STATE=$(grep -o -E 'crowbar\.state=[^ ]+' /proc/cmdline)
STATE=${STATE#*=}
DEBUG=`grep dhcp-client-debug /var/lib/dhclient/dhclient*.leases | uniq | cut -d" " -f5 | cut -d";" -f1`
export BMC_ADDRESS=""
export BMC_NETMASK=""
export BMC_ROUTER=""

# Make sure date is up-to-date
while ! /usr/sbin/ntpdate $ADMIN_IP 
do
  echo "Waiting for NTP server"
  sleep 1
done

# HACK fix for chef-client
cd /root
gem install --local rest-client
cd -

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

parse_node_data() {
  for s in $(/tmp/parse_node_data -a name -a crowbar.network.bmc.netmask -a crowbar.network.bmc.address -a crowbar.network.bmc.router -a crowbar.allocated $1) ; do
    VAL=${s#*=}
    case ${s%%=*} in
      name) export HOSTNAME=$VAL;;
      crowbar.allocated) export NODE_STATE=$VAL;;
      crowbar.network.bmc.router) export BMC_ROUTER=$VAL;;
      crowbar.network.bmc.address) export BMC_ADDRESS=$VAL;;
      crowbar.network.bmc.netmask) export BMC_NETMASK=$VAL;;
    esac
  done

  echo BMC_ROUTER=${BMC_ROUTER}
  echo BMC_ADDRESS=${BMC_ADDRESS}
  echo BMC_NETMASK=${BMC_NETMASK}
  echo HOSTNAME=${HOSTNAME}
  echo NODE_STATE=${NODE_STATE}
}


post_state() {
  local curlargs=(-o "/tmp/node_data.$$" --connect-timeout 60 -s \
      -L -X POST --data-binary "{ \"name\": \"$1\", \"state\": \"$2\" }" \
      -H "Accept: application/json" -H "Content-Type: application/json")
  [[ $CROWBAR_KEY ]] && curlargs+=(-u "$CROWBAR_KEY" --digest --anyauth)
  curl "${curlargs[@]}" "http://$ADMIN_IP:3000/crowbar/crowbar/1.0/transition/default"
  parse_node_data /tmp/node_data.$$
  rm /tmp/node_data.$$
}

get_state() {
    local curlargs=(-o "/tmp/node_data.$$" --connect-timeout 60 -s \
      -L -H "Accept: application/json" -H "Content-Type: application/json")
  [[ $CROWBAR_KEY ]] && curlargs+=(-u "$CROWBAR_KEY" --digest)
  curl "${curlargs[@]}" "http://$ADMIN_IP:3000/crowbar/machines/1.0/show?name=$HOSTNAME"
  parse_node_data /tmp/node_data.$$
  rm /tmp/node_data.$$
}

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
} 

maybe_reboot () { [[ $DEBUG != 1 ]] && reboot; }

run_chef () {
  chef-client -S http://$ADMIN_IP:4000/ -N $1
}

case $STATE in
    discovery)  
        echo "Discovering with: $HOSTNAME_MAC"
        post_state $HOSTNAME_MAC discovering
        run_chef $HOSTNAME_MAC
        post_state $HOSTNAME_MAC discovered

        #
        # rely on the DHCP server to do the right thing
        # Stick with this address until we get finished.
        #
        killall dhclient
        killall dhclient3

        while [ "$NODE_STATE" != "true" ] ; do
          sleep 15
          get_state
        done

        echo "Hardware installing with: $HOSTNAME"
        rm -f /etc/chef/client.pem
        post_state $HOSTNAME hardware-installing
        nuke_everything
        run_chef $HOSTNAME
        if [ -a /var/log/chef/hw-problem.log ]; then
          post_state $HOSTNAME problem
        else          
          post_state $HOSTNAME hardware-installed
        fi
        nuke_everything
        sleep 30 # Allow settle time
        maybe_reboot;;
    hwinstall)  
        while [ "$NODE_STATE" != "true" ] ; do
            sleep 15
            get_state
        done

        post_state $HOSTNAME hardware-installing
        nuke_everything
        echo "Hardware installing with: $HOSTNAME"
        run_chef $HOSTNAME
        if [ -a /var/log/chef/hw-problem.log ]; then
            post_state $HOSTNAME problem
        else          
            post_state $HOSTNAME hardware-installed
        fi
        nuke_everything
        sleep 30 # Allow settle time
        maybe_reboot;;
    update)  
        post_state $HOSTNAME hardware-updating
        run_chef $HOSTNAME
        if [ -a /var/log/chef/hw-problem.log ]; then
            post_state $HOSTNAME problem
        else          
            post_state $HOSTNAME hardware-updated
        fi
        sleep 30 # Allow settle time
        maybe_reboot;;
esac 2>&1 | tee -a /install-logs/$HOSTNAME-update.log
