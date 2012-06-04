#!/bin/bash

# Code library for control.sh and the state transition hooks.
parse_node_data() {
    local res=0
    if node_data=$(/tmp/parse_node_data -a name \
        -a crowbar.network.bmc.netmask \
        -a crowbar.network.bmc.address \
        -a crowbar.network.bmc.router \
        -a crowbar.allocated)
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
        echo "BMC_ROUTER=${BMC_ROUTER}"
        echo "BMC_ADDRESS=${BMC_ADDRESS}"
        echo "BMC_NETMASK=${BMC_NETMASK}"
        echo "HOSTNAME=${HOSTNAME}"
        echo "NODE_STATE=${NODE_STATE}"
    else
        res=$?
        echo "Error code: $res"
        echo ${node_data}
    fi
    echo "Local IP addresses:"
    ifconfig | awk ' /127.0.0.1/ { next; } /inet addr:/ { print } '
    return $res
}


post_state() {
  local curlargs=(--connect-timeout 60 -s -L -X POST \
      --data-binary "{ \"name\": \"$1\", \"state\": \"$2\" }" \
      -H "Accept: application/json" -H "Content-Type: application/json")
  [[ $CROWBAR_KEY ]] && curlargs+=(-u "$CROWBAR_KEY" --digest --anyauth)
  parse_node_data < <(curl "${curlargs[@]}" \
      "http://$ADMIN_IP:3000/crowbar/crowbar/1.0/transition/default")
}

get_state() {
    # $1 = hostname
    local curlargs=(--connect-timeout 60 -s -L -H "Accept: application/json" \
        -H "Content-Type: application/json")
  [[ $CROWBAR_KEY ]] && curlargs+=(-u "$CROWBAR_KEY" --digest)
  parse_node_data < <(curl "${curlargs[@]}" \
      "http://$ADMIN_IP:3000/crowbar/machines/1.0/show?name=$1")
}


reboot_system () {
  sync
  sleep 30
  umount -l /updates /install-logs
  reboot
}

wait_for_state_change () {
    # $1 = hostname
    local tries=1
    until get_state "$1"; do
        ((tries >= MAXTRIES)) && {
            echo "get_state failed ${tries} times.  Rebooting..."
            reboot_system
        }
        echo "get_state failed ${tries} times.  Retrying..."
        sleep 15
        tries=$((${tries}+1))
    done
}

report_state () {
    if [ -a /var/log/chef/hw-problem.log ]; then
	"cp /var/log/chef/hw-problem.log /install-logs/$1-hw-problem.log"
        post_state "$1" problem
    else
        post_state "$1" "$2"
    fi
}
