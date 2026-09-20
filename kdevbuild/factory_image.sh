#!/bin/bash

set -euxo pipefail

WORKDIR=$(pwd)
export DEBIAN_FRONTEND=noninteractive
export BUILD_TAG="rk3588_s60_${set_rootfs}"

#==========================================================================#
#                        init build env                                    #
#==========================================================================#
apt-get update
apt-get install -qq -y ca-certificates
apt-get install -qq -y --no-install-recommends \
  acl aptly aria2 axel bc binfmt-support binutils-aarch64-linux-gnu bison \
  bsdextrautils btrfs-progs build-essential busybox ca-certificates ccache \
  clang coreutils cpio crossbuild-essential-arm64 cryptsetup curl \
  debian-archive-keyring debian-keyring debootstrap device-tree-compiler \
  dialog dirmngr distcc dosfstools dwarves e2fsprogs expect f2fs-tools \
  fakeroot fdisk file flex gawk gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi \
  gdisk git gnupg gzip htop imagemagick jq kmod lib32ncurses-dev \
  lib32stdc++6 libbison-dev libc6-dev-armhf-cross libc6-i386 libcrypto++-dev \
  libelf-dev libfdt-dev libfile-fcntllock-perl libfl-dev libfuse-dev \
  libgcc-12-dev-arm64-cross libgmp3-dev liblz4-tool libmpc-dev libncurses-dev \
  libncurses5 libncurses5-dev libncursesw5-dev libpython2.7-dev \
  libpython3-dev libssl-dev libusb-1.0-0-dev linux-base lld llvm locales \
  lsb-release lz4 lzma lzop make mtools ncurses-base ncurses-term \
  nfs-kernel-server ntpdate openssl p7zip p7zip-full parallel parted patch \
  patchutils pbzip2 pigz pixz pkg-config pv python2 python2-dev python3 \
  python3-dev python3-distutils python3-pip python3-setuptools \
  python-is-python3 qemu-user-static rar rdfind rename rsync sed \
  squashfs-tools swig tar tree u-boot-tools udev unzip util-linux uuid \
  uuid-dev uuid-runtime vim wget whiptail xfsprogs xsltproc xxd xz-utils \
  zip zlib1g-dev zstd binwalk ripgrep sudo
localedef -i zh_CN -f UTF-8 zh_CN.UTF-8 || true
mkdir -p ${WORKDIR}/rockdev
mkdir -p ${WORKDIR}/release
mkdir -p /dev

#==========================================================================#
# Task: Build Root Filesystem (rootfs) using Armbian Build System          #
#==========================================================================#
mkdir -p ${WORKDIR}/rootfs
cd ${WORKDIR}/rootfs/

if [ -z "${set_vendor}" ] || [ -z "${set_rootfs}" ]; then
  echo "skip rootfs build"
else
  echo "ROOTFS:${set_rootfs}"
  ROOTFS_URL="https://github.com/yifengyou/kdev/releases/download/${set_vendor}-rootfs/${set_rootfs}"
  echo "ROOTFS_URL:${ROOTFS_URL}"

  aria2c --check-certificate=false \
    --max-connection-per-server=16 \
    --split=16 \
    --human-readable=true \
    --summary-interval=5 \
    -o ${set_rootfs} \
    "${ROOTFS_URL}"

  ls -alh
  rar x ${set_rootfs}
  ls -alh
  mv rootfs.img ${WORKDIR}/rockdev/rootfs.img
  ls -alh ${WORKDIR}/rockdev
fi

ls -alh ${WORKDIR}/rockdev/rootfs.img


#==========================================================================#
#                        更新rootfs                                      #
#==========================================================================#
cd ${WORKDIR}

mount "${WORKDIR}/rockdev/rootfs.img" /mnt
touch /mnt/.resized

# update firmware
if [ -d img/factory-official-image/fulldisk/firmware ]; then
  mkdir -p /mnt/lib/firmware
  cp -a img/factory-official-image/fulldisk/firmware /mnt/lib/firmware
  sync
fi
# update rockchip-test
if [ -d img/factory-official-image/fulldisk/rockchip-test ]; then
  cp -a img/factory-official-image/fulldisk/rockchip-test /mnt/
  sync
fi
# update modules
if [ -d img/factory-official-image/fulldisk/modules ]; then
  cp -a img/factory-official-image/fulldisk/modules/* /mnt/lib/modules/
  sync
fi

# lazy umount
umount -l /mnt

#==========================================================================#
# Script Purpose: Generate Rockchip Firmware Image with RKDevTool          #
#                                                                          #
# This script prepares the required partition images and packages them     #
# into a firmware update bundle compatible with Rockchip's RKDevTool.      #
#                                                                          #
# Input Images (must exist before execution):                              #
#   - ${WORKDIR}/rockdev/uboot.img   : U-Boot bootloader image             #
#   - ${WORKDIR}/rockdev/boot.img    : Kernel + DTB boot image             #
#   - ${WORKFS}/rockdev/rootfs.img   : Root filesystem image               #
#                                                                          #
# Output:                                                                  #
#   - ${WORKDIR}/release/            : Final RKDevTool-compatible firmware #
#                                      package (e.g., update.img)          #
#                                                                          #
# Note: Verify that all source images are correctly built and placed in    #
#       the ${WORKDIR}/rockdev/ directory prior to running this script.    #
#==========================================================================#

cd ${WORKDIR}
git clone https://github.com/yifengyou/rockchip-tools.git rockchip-tools.git
ls -alh ${WORKDIR}/rockchip-tools.git

mkdir -p ${WORKDIR}/release
mkdir -p ${WORKDIR}/rockdev_img_tmp
cp -a ${WORKDIR}/rockchip-tools.git/RKDevTool-v3.19-aigo-s60 \
  ${WORKDIR}/rockdev_img_tmp/RKDevTool-v3.19-aigo-s60
mkdir -p ${WORKDIR}/rockdev_img_tmp/RKDevTool-v3.19-aigo-s60/Image/


cp -a ${WORKDIR}/rockdev/rootfs.img ${WORKDIR}/rockdev_img_tmp/RKDevTool-v3.19-aigo-s60/Image/

cd ${WORKDIR}/rockdev_img_tmp/
rar a ${WORKDIR}/release/${BUILD_TAG} RKDevTool-v3.19-aigo-s60
cd ${WORKDIR}/release/
sha256sum ${BUILD_TAG}

ls -alh ${WORKDIR}/release/

echo "Build completed successfully!"
exit 0
