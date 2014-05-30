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

SOURCE=curl-7.23.1.tar.gz
CONFIG_OPTS=(--without-nss --without-libssh --without-libidn \
    --without-librtmp --disable-shared --disable-nonblocking \
    --disable-threaded-resolver --without-gssapi --without-ssl \
    --without-zlib --without-librtmp)

cp /mnt/files/$SOURCE /tmp
cd /tmp
tar xzf "$SOURCE"
cd "${SOURCE%.tar.gz}"
./configure "${CONFIG_OPTS[@]}"
make LDFLAGS="-all-static"
strip src/curl
cp src/curl /tmp
