#!/bin/bash

[[ -x /etc/init.d/crowbar_join.sh || -x /etc/init.d/crowbar ]] && exit 0

exec 2>&1
set -x
# <Chancellor Palpatine> Wipe them out.  All of them.
# Start with volume groups.
vgscan --ignorelockingfailure -P
while read vg; do
    vgremove -f "$vg"
done < <(vgs --noheadings -o vg_name)
# Continue with physical volumes
pvscan --ignorelockingfailure
while read pv; do
    pvremove -f -y "$pv"
done < <(pvs --noheadings -o pv_name)
# Now zap any partitions.
while read maj min blocks name; do
    [[ -b /dev/$name && -w /dev/$name && $name != name ]] || continue
    [[ $name = loop* ]] && continue
    [[ $name = dm* ]] && continue
    # Do our best to also zap any MD format metadata lying around that we can see.
    mdadm --zero-superblock --force "/dev/$name" || :
    if (( blocks >= 2048)); then
        dd "if=/dev/zero" "of=/dev/$name" "bs=512" "count=2048"
        dd "if=/dev/zero" "of=/dev/$name" "bs=512" "count=2048" "seek=$(($blocks - 2048))"
    else
        dd "if=/dev/zero" "of=/dev/$name" "bs=512" "count=$blocks"
    fi
done < <(tac /proc/partitions)
exit 0

