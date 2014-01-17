#!/bin/bash

[[ $BC_CACHE ]] || export BC_CACHE="$HOME/.crowbar-build-cache/barclamps/provisioner"
[[ $CROWBAR_DIR ]] || export CROWBAR_DIR="$HOME/crowbar"
[[ $BC_DIR ]] || export BC_DIR="$HOME/crowbar/barclamps/provisioner"
export SLEDGEHAMMER_PXE_DIR="$BC_CACHE/tftpboot"

echo "Using: BC_CACHE = $BC_CACHE"
echo "Using: CROWBAR_DIR = $CROWBAR_DIR"
echo "Using: BC_DIR = $BC_DIR"


bc_needs_build() [[ ! -f $SLEDGEHAMMER_PXE_DIR/initrd0.img ]]

bc_build() {
    die "Please run $BC_DIR/build_sledgehammer.sh to build Sledgehammer!"
}
