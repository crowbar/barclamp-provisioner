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
MAXTRIES=5
export BMC_ADDRESS=""
export BMC_NETMASK=""
export BMC_ROUTER=""

# Make sure date is up-to-date
until /usr/sbin/ntpdate $ADMIN_IP || [[ $STATE = 'debug' ]]
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

parse_node_data() {
  node_data=$(/tmp/parse_node_data -a name -a crowbar.network.bmc.netmask -a crowbar.network.bmc.address -a crowbar.network.bmc.router -a crowbar.allocated $1)
  export ERROR_CODE=$?

  if [ ${ERROR_CODE} -eq 0 ]
  then
    for s in ${node_data} ; do
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
  else
    echo "Error code: ${ERROR_CODE}"
    echo ${node_data}
  fi
   echo "Local IP addresses:"
  ifconfig | awk ' /127.0.0.1/ { next; } /inet addr:/ { print } '
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

run_chef () {
  chef-client -S http://$ADMIN_IP:4000/ -N $1
}

reboot_system () {
  sync
  sleep 30
  umount -l /updates /install-logs
  reboot
}

wait_for_state_change () {
  tries=0
  while [ "$NODE_STATE" != "true" ] ; do
    sleep 15
    tries=$((${tries}+1))
    get_state
    if [ ${ERROR_CODE} -ne 0 ]
    then
      if [ ${tries} -ge ${MAXTRIES} ]
      then
        echo "get_state failed ${tries} times.  Rebooting..."
        reboot_system
      else
        echo "get_state failed ${tries} times.  Retrying..."
      fi
    else 
      tries=0
    fi
  done
}

report_state () {
    if [ -a /var/log/chef/hw-problem.log ]; then
	cp /var/log/chef/hw-problem.log /install-logs/$HOSTNAME-hw-problem.log 
        post_state $HOSTNAME problem
    else
        post_state $HOSTNAME $1
    fi
}


case $STATE in
    discovery)
        echo "Discovering with: $HOSTNAME_MAC"
        post_state $HOSTNAME_MAC discovering
        run_chef $HOSTNAME_MAC
        post_state $HOSTNAME_MAC discovered

        wait_for_state_change

        echo "Hardware installing with: $HOSTNAME"
        rm -f /etc/chef/client.pem
        post_state $HOSTNAME hardware-installing
        nuke_everything
        run_chef $HOSTNAME
	report_state hardware-installed
	nuke_everything
	;;
    hwinstall)  
        wait_for_state_change
        post_state $HOSTNAME hardware-installing
        nuke_everything
        echo "Hardware installing with: $HOSTNAME"
        run_chef $HOSTNAME
	report_state hardware-installed
        nuke_everything
	;;
    update)
        post_state $HOSTNAME hardware-updating
        run_chef $HOSTNAME
	report_state hardware-updated
	;;
esac 2>&1 | tee -a /install-logs/$HOSTNAME-update.log
[[ $STATE = 'debug' ]] && exit
reboot_system
