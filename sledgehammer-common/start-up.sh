#!/bin/bash

export PS4='${BASH_SOURCE}@${LINENO}(${FUNCNAME[0]}): '
set -x
set -e
shopt -s extglob

get_param() {
    [[ $(cat /proc/cmdline) =~ $1 ]] && echo "${BASH_REMATCH[1]}"
}

is_suse() [[ -f /etc/SuSE-release ]]

DHCPDIR=/var/lib/dhclient
RSYSLOGSERVICE=rsyslog

is_suse && {
 DHCPDIR=/var/lib/dhcp
 RSYSLOGSERVICE=syslog
}

# Some useful boot parameter matches
ip_re='([0-9a-f.:]+/[0-9]+)'
bootif_re='BOOTIF=([^ ]+)'
host_re='crowbar\.fqdn=([^ ]+)'
install_key_re='crowbar\.install\.key=([^ ]+)'
provisioner_re='provisioner\.web=([^ ]+)'
crowbar_re='crowbar\.web=([^ ]+)'
domain_re='crowbar\.dns\.domain=([^ ]+)'
dns_server_re='crowbar\.dns\.servers=([^ ]+)'

# Grab the boot parameters we should always be passed

# install key first
export CROWBAR_KEY="$(get_param "$install_key_re")"

# Provisioner and Crowbar web endpoints next
export PROVISIONER_WEB="$(get_param "$provisioner_re")"
export CROWBAR_WEB="$(get_param "$crowbar_re")"
export DOMAIN="$(get_param "$domain_re")"
export DNS_SERVERS="$(get_param "$dns_server_re")"

# Test to see if we got everything we must have.
# Die horribly otherwise.
if ! [[ $CROWBAR_KEY && $PROVISIONER_WEB && $CROWBAR_WEB && \
    $DOMAIN && $DNS_SERVERS ]]; then
    echo "Sledgehammer was not booted off a Crowbar 2 provisioner."
    echo "This cannot happen"
    exit 1
fi

# Figure out where we PXE booted from.
if [[ $(cat /proc/cmdline) =~ $bootif_re ]]; then
    MAC="${BASH_REMATCH[1]//-/:}"
    MAC="${MAC#*:}"
elif [[ -d /sys/firmware/efi ]]; then
    declare -A boot_entries
    bootent_re='^Boot([0-9]{4})'
    efimac_re='MAC\(([0-9a-f]+)'
    while read line; do
        k="${line%% *}"
        v="${line#* }"
        if [[ $k = BootCurrent:* ]]; then
            current_bootent="${line##BootCurrent: }"
        elif [[ $k =~ $bootent_re ]]; then
            boot_entries["${BASH_REMATCH[1]}"]="$v"
        fi
    done < <(efibootmgr -v)

    if [[ ${boot_entries["$current_bootent"]} =~ $efimac_re ]]; then
        MAC=''
        for o in 0 2 4 6 8 10; do
            MAC+="${BASH_REMATCH[1]:$o:2}:"
        done
        MAC=${MAC%:}
    fi
fi
for nic in /sys/class/net/*; do
    [[ -f $nic/address && -f $nic/type && \
        $(cat "$nic/type") = 1 && \
        $(cat "$nic/address") = $MAC ]] || continue
    BOOTDEV="${nic##*/}"
    break
done

if [[ ! $BOOTDEV ]]; then
    echo "We don't know what the MAC address of our boot NIC was!"
    exit 1
fi

killall dhclient && sleep 5
# Make sure our PXE interface is up, then fire up DHCP on it.
ip link set "$BOOTDEV" up || :
dhclient "$BOOTDEV" || :

bootdev_ip_re='inet ([0-9.]+)/([0-9]+)'
if ! [[ $(ip -4 -o addr show dev $BOOTDEV) =~ $bootdev_ip_re ]]; then
    echo "We did not get an address on $BOOTDEV"
    echo "Things will end badly."
    exit 1
fi

# Let Crowbar know what is happening.
if ! [[ $(cat /proc/cmdline) =~ $host_re ]]; then
    export HOSTNAME="d${MAC//:/-}.${DOMAIN}"
    curl -f -g --digest -u "$CROWBAR_KEY" -X POST \
        -d "name=$HOSTNAME" \
        -d "mac=$MAC" \
        "$CROWBAR_WEB/api/v2/nodes/"
else
    export HOSTNAME="${BASH_REMATCH[1]}"
    curl -f -g --digest -u "$CROWBAR_KEY" \
        -X PUT "$CROWBAR_WEB/api/v2/nodes/$HOSTNAME" \
        -d 'alive=false' \
        -d 'bootenv=sledgehammer'
fi

# Figure out what IP addresses we should have.
netline=$(curl -f -g --digest -u "$CROWBAR_KEY" \
    -X GET "$CROWBAR_WEB/network/api/v2/networks/admin/allocations" \
    -d "node=$HOSTNAME")

# Bye bye to DHCP.
killall dhclient || :
ip addr flush "$BOOTDEV"

# Add our new IP addresses.
nets=(${netline//,/ })
for net in "${nets[@]}"; do
    [[ $net =~ $ip_re ]] || continue
    net=${BASH_REMATCH[1]}
    # Make this more complicated and exact later.
    ip addr add "$net" dev "$BOOTDEV" || :
done

# Set our hostname for everything else.
if is_suse; then
    echo "$HOSTNAME" > /etc/HOSTNAME
else
    if [ -f /etc/sysconfig/network ] ; then
      sed -i -e "s/HOSTNAME=.*/HOSTNAME=${HOSTNAME}/" /etc/sysconfig/network
    fi
    echo "${HOSTNAME#*.}" >/etc/domainname
fi
hostname "$HOSTNAME"

# Update our /etc/resolv.conf with the IP address of our DNS servers,
# which were passed to us via kernel param.
chattr -i /etc/resolv.conf || :
echo "domain $DOMAIN" >/etc/resolv.conf.new

for server in ${DNS_SERVERS//,/ }; do
    echo "nameserver ${server}" >> /etc/resolv.conf.new
done

mv -f /etc/resolv.conf.new /etc/resolv.conf

# Force reliance on DNS
echo '127.0.0.1 localhost' >/etc/hosts
echo '::1 localhost6' >>/etc/hosts

# Wait for up to 30 seconds for Crowbar to notice that we are alive.
for (( count=0; count < 30; count=$count + 1)); do
    ping6 -c 1 -w 1 "$HOSTNAME" && break
    sleep 1
done

if [[ $? != 0 ]]; then
    echo "Crowbar did not register that we exist!"
    exit 1
fi

while [[ ! -x /tmp/control.sh ]]; do
    curl -s -f -L -o /tmp/control.sh "$PROVISIONER_WEB/nodes/$HOSTNAME/control.sh" || :
    if grep -q '^exit 0$' /tmp/control.sh && \
        head -1 /tmp/control.sh | grep -q '^#!/bin/bash'; then
        chmod 755 /tmp/control.sh
        break
    fi
    sleep 1
done

export CROWBAR_KEY PROVISIONER_WEB CROWBAR_WEB
export MAC BOOTDEV DOMAIN HOSTNAME

[[ -x /tmp/control.sh ]] && exec /tmp/control.sh

echo "Did not get control.sh from $PROVISIONER_WEB/nodes/$HOSTNAME/control.sh"
exit 1
