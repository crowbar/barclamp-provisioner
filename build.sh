#!/bin/bash

[[ $BC_CACHE ]] || export BC_CACHE="$HOME/.crowbar-build-cache/barclamps/provisioner"
[[ $CROWBAR_DIR ]] || export CROWBAR_DIR="$HOME/crowbar"
[[ $BC_DIR ]] || export BC_DIR="$HOME/crowbar/barclamps/provisioner"

echo "Using: BC_CACHE = $BC_CACHE"
echo "Using: CROWBAR_DIR = $CROWBAR_DIR"
echo "Using: BC_DIR = $BC_DIR"

bc_needs_build() {
    true
}

bc_build() {
    mkdir -p "$BC_CACHE/files/wsman"
    mkdir -p "$BC_CACHE/gems"

    cd "$BC_DIR/updates/wsman"
    gem build wsman.gemspec

    mv "$BC_DIR"/updates/wsman/wsman*.gem "$BC_CACHE/gems"
}
