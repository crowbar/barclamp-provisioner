#!/bin/bash

[[ -x /etc/init.d/crowbar_join.sh || -x /etc/init.d/crowbar ]] && exit 0

set -x
nohup /bin/bash -c 'command sleep 60; exec reboot' >/tmp/nohup.out &
exit 0

