#!/bin/bash
#
# Copyright 2011-2013, Dell
# Copyright 2013-2014, SUSE LINUX Products GmbH
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

bc_needs_build () [[ ! -x $BC_CACHE/files/curl ]]

bc_build() {
    sudo cp "$BC_DIR/build_curl_chroot.sh" "$CHROOT/tmp"
    if [[ $OS_TOKEN = redhat-6.2 ]]; then
	cd "$BC_CACHE/$OS_TOKEN/pkgs"
	[[ -f glibc-static-2.12-1.47.el6.x86_64.rpm ]] || \
	    wget http://centos.mirror.lstn.net/6.2/os/x86_64/Packages/glibc-static-2.12-1.47.el6.x86_64.rpm
	in_chroot rpm -Uvh "/mnt/$OS_TOKEN/pkgs/glibc-static-2.12-1.47.el6.x86_64.rpm"
    elif [[ $OS_TOKEN = centos-6* ]]; then
	in_chroot yum -y install glibc-static
    fi
    in_chroot /tmp/build_curl_chroot.sh
    cp "$CHROOT/tmp/curl" "$BC_CACHE/files/curl"
}