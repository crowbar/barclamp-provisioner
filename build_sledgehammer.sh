#!/bin/bash
#
# Build a sledgehammer image for Crowbar and put it in the build cache.

# Copyright 2011, Dell
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Author: VictorLowther

# We always use the C language and locale
export LANG="C"
export LC_ALL="C"

GEM_RE='([^0-9].*)-([0-9].*)'

readonly currdir="$PWD"
export PATH="$PATH:/sbin:/usr/sbin:/usr/local/sbin"

if ! [[ $CACHE_DIR ]]; then
    # Source our config file if we have one
    [[ -f $HOME/.build-crowbar.conf ]] && \
        . "$HOME/.build-crowbar.conf"
    # Look for a local one.
    [[ -f build-crowbar.conf ]] && \
        . "build-crowbar.conf"
fi
# Always run in verbose mode for now.
VERBOSE=true
SLEDGEHAMMER_OS="centos-6.4"
OS_TO_STAGE="$SLEDGEHAMMER_OS"
OS_TOKEN="$OS_TO_STAGE"

# Location for caches that should not be erased between runs
[[ $CACHE_DIR ]] || CACHE_DIR="$HOME/.crowbar-build-cache"

# The directory that we will mount the OS .ISO on .
[[ $IMAGE_DIR ]] || \
    IMAGE_DIR="$CACHE_DIR/$OS_TOKEN/sledgehammer-image"

# Location to store .iso images that we use in the build process.
# These are usually OS install DVDs that we will stage Crowbar on to.
[[ $ISO_LIBRARY ]] || ISO_LIBRARY="$CACHE_DIR/iso"

CHROOT="$CACHE_DIR/$OS_TOKEN/sledgehammer-chroot"
sudo rm -rf "$CHROOT"

mkdir -p "$CACHE_DIR" "$IMAGE_DIR" "$CHROOT"

# Location of the Crowbar checkout we are building from.
[[ $CROWBAR_DIR ]] || CROWBAR_DIR="${0%/*}/../.."
[[ $CROWBAR_DIR = /* ]] || CROWBAR_DIR="$currdir/$CROWBAR_DIR"
[[ -f $CROWBAR_DIR/build_crowbar.sh && -d $CROWBAR_DIR/.git ]] || \
    die "$CROWBAR_DIR is not a git checkout of Crowbar!"
export CROWBAR_DIR

# Directory that holds our Sledgehammer PXE tree.
[[ $SLEDGEHAMMER_PXE_DIR ]] || SLEDGEHAMMER_PXE_DIR="$CACHE_DIR/barclamps/provisioner/tftpboot"

unset CROWBAR_BUILD_PID
# Source our common build functions
. "$CROWBAR_DIR/build_lib.sh" || exit 1
. "$CROWBAR_DIR/test_lib.sh" || exit 1

if ! which cpio &>/dev/null; then
    die "Cannot find cpio, we cannot proceed."
fi

if ! which rpm rpm2cpio &>/dev/null; then
    die "Cannot find rpm and rpm2cpio, we cannot proceed."
fi

if ! which ruby &>/dev/null; then
    die "You must have Ruby installed to run this script.  We cannot proceed."
fi

# Make sure that we actually know how to build the ISO we were asked to
# build.  If we do not, print a helpful error message.
if ! [[ $OS_TO_STAGE && -d $CROWBAR_DIR/$OS_TO_STAGE-extra && \
    -f $CROWBAR_DIR/$OS_TO_STAGE-extra/build_lib.sh ]]; then
    cat <<EOF
You must pass the name of the operating system you want to stage Sledgehammer
on to.  Valid choices are:
EOF
cd "$CROWBAR_DIR"
for d in *-extra; do
    [[ -d $d && -f $d/build_lib.sh ]] || continue
    echo "    ${d%-extra}"
done
exit 1
fi

SLEDGEHAMMER_CHROOT_CACHE="$CACHE_DIR/sledgehammer/$OS_TO_STAGE/chroot_cache"
SLEDGEHAMMER_LIVECD_CACHE="$CACHE_DIR/sledgehammer/$OS_TO_STAGE/livecd_cache"

[[ -f $CROWBAR_DIR/$OS_TO_STAGE-extra/build_sledgehammer_lib.sh && \
    -f $CROWBAR_DIR/$OS_TO_STAGE-extra/sledgehammer.ks ]] || \
    die "Do not know how to build Sledgehammer on this OS!"

. "$CROWBAR_DIR/$OS_TO_STAGE-extra/build_lib.sh"

# This file contains library routines needed to build Sledgehammer

EXTRA_REPOS=('http://mirror.centos.org/centos/6/os/x86_64' \
    'http://mirror.centos.org/centos/6/updates/x86_64' \
    'http://mirror.centos.org/centos/6/extras/x86_64' \
    'http://mirror.us.leaseweb.net/epel/6/x86_64' \
    'http://www.nanotechnologies.qc.ca/propos/linux/centos-live/x86_64/live' \
    'http://rbel.frameos.org/stable/el6/x86_64' \
    'http://download.opensuse.org/repositories/Openwsman/CentOS_CentOS-6')

setup_sledgehammer_chroot() {
    local repo rnum
    local packages=() pkg
    local files=() file
    local mirror="${EXTRA_REPOS[0]}"
    local -A base_pkgs
    # Build a hash of base packages. We will use this to track the packages we found in the mirror.
    for pkg in "${OS_BASIC_PACKAGES[@]}"; do
        base_pkgs["$pkg"]="needed"
    done
    # Fourth, get a list of packages in the mirror that we will use.
    match_re='^([A-Za-z0-9._+-]+)-([0-9]+:)?([0-9a-zA-Z._]+)-([^-]+)(\.el6.*)?\.(x86_64|noarch)\.rpm'
    while read file; do
        # Do we actaully care at all about this file?
        [[ $file =~ $match_re ]] || continue
        # Is this a file we need to download?
        [[ ${base_pkgs["${BASH_REMATCH[1]}"]} ]] || continue
        # It is. Mark it as found and put it in the list.
        base_pkgs["${BASH_REMATCH[1]}"]="found"
        files+=("-O" "${mirror}/Packages/$file")
    done < <(curl -sfL "{$mirror}/Packages/" | \
        sed -rn 's/.*"([^"]+\.(x86_64|noarch).rpm)".*/\1/p')
    # Fifth, make sure we found all our packages.
    for pkg in "${base_pkgs[@]}"; do
        [[ $pkg = found ]] && continue
        die "Not all files for CentOS chroot found."
    done
    # Sixth, suck all of our files and install them in one go
    sudo mkdir -p "$CHROOT"
    (
        set -e
        set -o pipefail
        cd "$CHROOT"
        debug "Fetching files needed for chroot"
        curl -sfL "${files[@]}" || exit 1
        for file in *.rpm; do
            debug "Extracting $file"
            rpm2cpio "$file" | sudo cpio --extract --make-directories \
                --no-absolute-filenames --preserve-modification-time &>/dev/null
            if [[ $file =~ (centos|redhat)-release ]]; then
                sudo mkdir -p "$CHROOT/tmp"
                sudo cp "$file" "$CHROOT/tmp/${file##*/}"
                postcmds+=("/bin/rpm -ivh --force --nodeps /tmp/${file##*/}")
            fi
            rm "$file"
        done
        # Seventh, fix up the chroot so that it is fully functional.
        sudo cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"
        for d in /proc /sys /dev /dev/pts /dev/shm; do
            [[ -L $d ]] && d="$(readlink -f "$d")"
            mkdir -p "${CHROOT}$d"
            sudo mount --bind "$d" "${CHROOT}$d"
        done
        # Eighth, run any post cmds we got earlier
        for cmd in "${postcmds[@]}"; do
            in_chroot $cmd
        done
    ) || die "Not all files needed for CentOS chroot downloaded."
    sudo rm -f "$CHROOT/etc/yum.repos.d/"*
    rnum=0
    for repo in "${EXTRA_REPOS[@]}"; do
        add_repos "bare r${rnum} 10 $repo"
        rnum=$((rnum + 1))
    done
    # Eleventh, bootstrap the rest of the chroot with yum.
    in_chroot yum -y install yum yum-downloadonly createrepo
    # fastestmirror support behind a proxy is not that good.
    [[ -f $CHROOT/etc/yum/pluginconf.d/fastestmirror.conf ]] && \
        in_chroot sed -ie '/^enabled/ s/1/0/' \
        /etc/yum/pluginconf.d/fastestmirror.conf
    # Make sure yum does not throw away our caches for any reason.
    in_chroot /bin/sed -i -e '/keepcache/ s/0/1/' /etc/yum.conf
    in_chroot sh -c "echo 'exclude = *.i386' >>/etc/yum.conf"
    # fourth, have yum bootstrap everything else into usefulness
    chroot_install livecd-tools tar
}

setup_sledgehammer_chroot
sudo cp "$CROWBAR_DIR/barclamps/provisioner/sledgehammer.ks" "$CHROOT/mnt"
sudo cp "$CROWBAR_DIR/barclamps/provisioner/sledgehammer-common/"* "$CHROOT/mnt"
mkdir -p "$SLEDGEHAMMER_CHROOT_CACHE"
mkdir -p "$SLEDGEHAMMER_LIVECD_CACHE"
in_chroot mkdir -p /mnt/cache
sudo mount --bind "$SLEDGEHAMMER_CHROOT_CACHE" "$CHROOT/$CHROOT_PKGDIR"
sudo mount --bind "$SLEDGEHAMMER_LIVECD_CACHE" "$CHROOT/mnt/cache"
in_chroot touch /mnt/make_sledgehammer
in_chroot chmod 777 /mnt/make_sledgehammer
echo '#!/bin/bash' >>"$CHROOT/mnt/make_sledgehammer"
if [[ $USE_PROXY = "1" ]]; then
    printf "\nexport no_proxy=%q http_proxy=%q\n" \
        "$no_proxy" "$http_proxy" >> "$CHROOT/mnt/make_sledgehammer"
    printf "\nexport NO_PROXY=%q HTTP_PROXY=%q\n" \
        "$no_proxy" "$http_proxy" >> "$CHROOT/mnt/make_sledgehammer"
fi
cat >> "$CHROOT/mnt/make_sledgehammer" <<EOF
set -e
cd /mnt
livecd-creator --config=sledgehammer.ks --cache=./cache -f sledgehammer
$SLEDGEECHO rm -fr /mnt/tftpboot
livecd-iso-to-pxeboot sledgehammer.iso
$SLEDGEECHO /bin/rm /mnt/sledgehammer.iso
EOF
in_chroot ln -s /proc/self/mounts /etc/mtab
in_chroot /mnt/make_sledgehammer
mkdir -p "$SLEDGEHAMMER_PXE_DIR"
cp -af "$CHROOT/mnt/tftpboot/"* "$SLEDGEHAMMER_PXE_DIR"
$SLEDGEECHO in_chroot /bin/rm -rf /mnt/tftpboot

# Make sure that the loopback kernel module is loaded.
[[ -d /sys/module/loop ]] || sudo modprobe loop

while read line; do
    sudo losetup -d "${line%%:*}"
done < <(sudo losetup -a |grep sledgehammer.iso)

[[ -f $SLEDGEHAMMER_PXE_DIR/initrd0.img ]]
