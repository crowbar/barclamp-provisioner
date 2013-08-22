#!/bin/bash

[[ $MAXTRIES ]] || export MAXTRIES=5

# Code library for control.sh and the state transition hooks.
parse_node_data() {
    local res=0
    if node_data=$(/tmp/parse_node_data -a name \
        -a crowbar.network.admin.address \
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
                crowbar.network.admin.address) export ADMIN_ADDRESS=$VAL;;
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
  umount -l /updates /var/log/crowbar/sledgehammer
  reboot -f
}

wait_for_allocated() {
    # $1 = hostname
    while [[ $ALLOCATED != true ]]; do
        sleep 15
        get_state "$1"
    done
}

hook_has_run() {
    local statefile="/var/log/crowbar/sledgehammer/$HOSTNAME-$HOOKNAME-$HOOKSTATE"
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


wait_for_pxe() {
    # $1 = [present|absent]
    # $2 = <state>
    mode=$1
    state=$2
    [ $mode != "present" ] && state=

    # If we've transitioned states, there sometimes needs to be a link for
    # pxe boot for this IP address.  Without it, we'll just reboot into
    # discovery again and get "stuck".  This can happen if the admin node is
    # very slow updating pxe config.  So just in case we'll poll here for up
    # to five minutes before giving up and just rebooting

    wantedexit=88
    [ $mode == "present" ] && wantedexit=0
    [ $mode == "absent" ] && wantedexit=22
    # 22 is the curl exit code for HTTP status codes of 400 and above

    # convert ADMIN_ADDRESS from decimal to hex
    MYHEXIP=`IFS="." ; for i in $ADMIN_ADDRESS; do printf '%02X' $i ; done`

    count=0
    done=0

    if [ -n "$state" ]; then
        echo -n "waiting for pxe file to contain: $state "
    else
        echo -n "waiting for pxe file to be: $mode "
    fi

    until [ 1 = $done ] ; do
        if [ -n "$state" ]; then
            curl --fail --silent --connect-timeout 5 "http://$ADMIN_IP:8091/discovery/pxelinux.cfg/$MYHEXIP" | grep -q "^DEFAULT $state$"
            ret=$?
        else
            curl --fail --silent --head --connect-timeout 5 "http://$ADMIN_IP:8091/discovery/pxelinux.cfg/$MYHEXIP" > /dev/null
            ret=$?
        fi

        if [ $wantedexit = $ret ] ; then
            if [ -n "$state" ]; then
                echo "pxe file now contains: $state"
            else
                echo "pxe file is now: $mode"
            fi
            done=1
            break
        else
            echo -n "."
            let count=count+1
            [ $count -gt 30 ] && {
                if [ -n "$state" ]; then
                    echo "Warning: pxe file still contains $state. giving up."
                else
                    echo "Warning: pxe file still not $mode. giving up."
                fi
                break
            }
            sleep 10
        fi
    done
}


wait_for_pxe_state() {
    # $1 = <state>
    wait_for_pxe "present" "$1"
}


wait_for_pxe_file() {
    # $1 = [present|absent]
    wait_for_pxe "$1" ""
}


report_state () {
    if [ -a /var/log/chef/hw-problem.log ]; then
	"cp /var/log/chef/hw-problem.log /var/log/crowbar/sledgehammer/$1-hw-problem.log"
        post_state "$1" problem
    else
        post_state "$1" "$2"
    fi
}
