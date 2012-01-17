#!/bin/bash

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
