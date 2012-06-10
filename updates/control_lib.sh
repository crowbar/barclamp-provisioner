#!/bin/bash

[[ $MAXTRIES ]] || export MAXTRIES=5

# Code library for control.sh and the state transition hooks.
parse_node_data() {
    local res=0
    if node_data=$(/tmp/parse_node_data -a name \
        -a crowbar.network.bmc.netmask \
        -a crowbar.network.bmc.address \
        -a crowbar.network.bmc.router \
        -a state \
        -a crowbar.allocated)
    then
        for s in ${node_data} ; do
            VAL=${s#*=}
            case ${s%%=*} in
                name) export HOSTNAME=$VAL;;
                state) export CROWBAR_STATE=$VAL;;
                crowbar.allocated) export ALLOCATED=$VAL;;
                crowbar.network.bmc.router) export BMC_ROUTER=$VAL;;
                crowbar.network.bmc.address) export BMC_ADDRESS=$VAL;;
                crowbar.network.bmc.netmask) export BMC_NETMASK=$VAL;;
            esac
        done
        echo "BMC_ROUTER=${BMC_ROUTER}"
        echo "BMC_ADDRESS=${BMC_ADDRESS}"
        echo "BMC_NETMASK=${BMC_NETMASK}"
        echo "CROWBAR_STATE=${CROWBAR_STATE}"
        echo "HOSTNAME=${HOSTNAME}"
        echo "ALLOCATED=${ALLOCATED}"
    else
        res=$?
        echo "Error code: $res"
        echo ${node_data}
    fi
    echo "Local IP addresses:"
    ifconfig | awk ' /127.0.0.1/ { next; } /inet addr:/ { print } '
    return $res
}

try_to() {
    # $1 = max times to try a command.
    # $2 = times to wait in between tries
    # $@ function and args to try
    local tries=1 maxtries="$1" sleeptime="$2"
    shift 2
    until "$@"; do
        ((tries >= maxtries)) && {
            echo "$* failed ${tries} times.  Rebooting..."
            reboot_system
        }
        echo "$* failed ${tries} times.  Retrying..."
        sleep "$sleeptime"
        tries=$((${tries}+1))
    done
}

__post_state() {
  local curlargs=(--connect-timeout 60 -s -L -X POST \
      --data-binary "{ \"name\": \"$1\", \"state\": \"$2\" }" \
      -H "Accept: application/json" -H "Content-Type: application/json")
  [[ $CROWBAR_KEY ]] && curlargs+=(-u "$CROWBAR_KEY" --digest --anyauth)
  parse_node_data < <(curl "${curlargs[@]}" \
      "http://$ADMIN_IP:3000/crowbar/crowbar/1.0/transition/default")
}

__get_state() {
    # $1 = hostname
    local curlargs=(--connect-timeout 60 -s -L -H "Accept: application/json" \
        -H "Content-Type: application/json")
  [[ $CROWBAR_KEY ]] && curlargs+=(-u "$CROWBAR_KEY" --digest)
  parse_node_data < <(curl "${curlargs[@]}" \
      "http://$ADMIN_IP:3000/crowbar/machines/1.0/show?name=$1")
}

post_state() { try_to "$MAXTRIES" 15 __post_state "$@"; }
get_state() { try_to "$MAXTRIES" 15 __get_state "$@"; }

reboot_system() {
  sync
  sleep 30
  umount -l /updates /install-logs
  reboot
}

wait_for_allocated() {
    # $1 = hostname
    while [[ $ALLOCATED = false ]]; do
        get_state "$1"
        [[ $ALLOCATED = true ]] && return
        sleep 15
    done
}

hook_has_run() {
    local statefile="/install-logs/$HOSTNAME-$HOOKNAME-$HOOKSTATE"
    if [[ -f $statefile ]]; then
        return 0
    else
        touch "$statefile"
        return 1
    fi
}

wait_for_crowbar_state() {
    # $1 = hostname
    # $2 = crowbar state to wait for.  If empty, wait for a state change
    [[ $2 && $2 = $CROWBAR_STATE ]] && return
    local current_state=$CROWBAR_STATE
    while [[ 1 = 1 ]]; do
        get_state "$1"
        if [[ $2 ]]; then
            [[ $2 = $CROWBAR_STATE ]] && return
        elif [[ $current_state != $CROWBAR_STATE ]]; then
            return
        fi
        sleep 15
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
