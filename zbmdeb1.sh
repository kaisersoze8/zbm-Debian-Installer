#!/usr/bin/env bash

# CHANGE THESE PARAMETERS BEFORE RUNNING AS "source ./this-script.sh"
export POOL_NAME="rpool"
#Encrypted HDD Password. Remove (#) if Encryption
#export POOL_KEY="encrypt-string"
# ZFS compatibility level setting if needed
# export POOL_COMPAT="2.1"
# Use (NVME: /dev/nvme0n1, PART p1,p2,p3) ; (KVM/Virtio: /dev/vda, PART 1,2,3)
export BOOT_DISK="/dev/sda"
export POOL_DISK="/dev/sda"
export BOOT_PART="1"
export SWAP_PART="2"
export POOL_PART="3"
# Desired HDD Partition Label - in lowercase, GPT or MBR?
export HDDPL="mbr"

###################
export BOOT_DEV="$BOOT_DISK""$BOOT_PART"
export SWAP_DEV="$POOL_DISK""$SWAP_PART"
export POOL_DEV="$POOL_DISK""$POOL_PART"

if [ -z "$POOL_KEY" ]; then
    POOL_KEYSTR=""
else
    POOL_KEYSTR="-O encryption=aes-256-gcm  -O keyformat=passphrase -O keylocation=file:///etc/zfs/zroot.key"
fi

if [ -z "$POOL_COMPAT" ]; then
    POOL_COMPATSTR=""
else
    POOL_COMPATSTR="-o compatibility=openzfs-"$POOL_COMPAT"-linux"
fi

# Zpool ashift for NVME is 13
if [ $(echo "$POOL_DISK" | cut -d"/" -f3 | cut -b1-4) == "nvme" ]; then
    POOL_ASHIFT="13"; else POOL_ASHIFT="12"
fi

function part_gpt () {
    sgdisk --zap-all "$POOL_DISK"
    sgdisk --zap-all "$BOOT_DISK"
    # HDD Format, 3 Partitions Leading 1M Space Needed for Boot Core.img
    sgdisk -n "${BOOT_PART}:1m:+512m" -t "${BOOT_PART}:ef00" "$BOOT_DISK"
    # Swap Partition 6G
    sgdisk -n "${SWAP_PART}:0:+6g" -t "${SWAP_PART}:8200" "$POOL_DISK"
    # ZPOOL Partition - All of Remaining Space
    sgdisk -n "${POOL_PART}:0:0" -t "${POOL_PART}:bf00" "$POOL_DISK"
}

function part_mbr () {
    apt install -y parted

    # HDD Format, 3 Partitions. Leading 1M Space Needed for Boot Core.img
    parted -sf "$BOOT_DISK" mklabel msdos
    parted -sf -a cyl "$BOOT_DISK" mkpart primary ext4 1MB 512MB
    parted -sf "$BOOT_DISK" set "$BOOT_PART" boot on

    if [ "$POOL_DISK" != "$BOOT_DISK" ]; then
        parted -sf "$POOL_DISK" mklabel msdos; fi
    # Swap Partition 6G
    parted -sf -a cyl "$POOL_DISK" mkpart primary linux-swap 512MB 6656MiB
    # ZPOOL Partition - All of Remaining Space
    parted -sf -a cyl "$POOL_DISK" mkpart primary btrfs 6656MB 100%
}

# Modify Apt Sources. See /etc/os-release for Available Parameters
source /etc/os-release
export VC="$VERSION_CODENAME"
export VID="$ID"
cat << EOF >> /etc/apt/sources.list
deb http://deb.debian.org/debian "$VC" main contrib
deb-src http://deb.debian.org/debian "$VC" main contrib
EOF

# Install ZFS Modules to Live System - exit if headers package not found
apt update
apt install -y debootstrap gdisk dkms linux-headers-$(uname -r) || exit 1
# Suppress TAINTED KERNEL confirm message- FAILS TO INSTALL WITH THIS
#DEBIAN_FRONTEND=noninteractive apt install -y zfsutils-linux
apt install -y zfsutils-linux
zgenhostid -f 0x00bab10c

# Wipe the HDD clean - modify this if previous zpool was elsewhere
zpool labelclear -f "$POOL_DEV"
# Allow pre-formatted HDD to skip re-format; proceed to install
read -p "Re-Format HDD? 'n' to Skip" RFHDD
if [ "$RFHDD" != "n" ]; then
    wipefs -a "$BOOT_DISK"
    wipefs -a "$POOL_DISK"
    # Begin HDD Partition According to GPT or MBR
    eval "part_""$HDDPL"
fi

# Setup & Configure Root Zpool
if [ -n "$POOL_KEY" ]; then
  echo "$POOL_KEY" > /etc/zfs/zroot.key
else
  echo "" > /etc/zfs/zroot.key
fi
chmod 000 /etc/zfs/zroot.key

zpool create -f -o ashift="$POOL_ASHIFT" -O compression=lz4 -O xattr=sa \
    -o autotrim=on -O acltype=posixacl -O relatime=on -m none \
    "$POOL_KEYSTR"  "$POOL_COMPATSTR"  "$POOL_NAME"  "$POOL_DEV" || exit 1
# Create the Desired ZFS Datasets (Not using -o utf8only=on)
zfs create -o mountpoint=none "$POOL_NAME"/ROOT
zfs create -o mountpoint=/ -o canmount=noauto  "$POOL_NAME"/ROOT/"$VID"
zpool set bootfs="$POOL_NAME"/ROOT/"$VID"  "$POOL_NAME"
# Base system /usr Binaries are preferred on the Root Dataset
zfs create -o canmount=off  "$POOL_NAME"/ROOT/"$VID"/usr
zfs create -o canmount=on  "$POOL_NAME"/ROOT/"$VID"/usr/local
zfs create -o canmount=on  "$POOL_NAME"/ROOT/"$VID"/var
zfs create -o canmount=on  "$POOL_NAME"/ROOT/"$VID"/var/lib
zfs create -o canmount=on  "$POOL_NAME"/ROOT/"$VID"/opt
# This /home Setup Allows Independence from Linux Versions in case of Multiboot
zfs create -o mountpoint=/home -o canmount=on "$POOL_NAME"/home

# Export then re-Import the zpool
zpool export "$POOL_NAME"
zpool import -Nf -R /mnt "$POOL_NAME"
if [ -n "$POOL_KEY" ]; then
  zfs load-key -L prompt "$POOL_NAME" || exit 1
fi
zfs mount "$POOL_NAME"/ROOT/"$VID"
zfs mount -a
# ZFS Dataset Visual Check / Confirm
zfs list
read -p "If listed ZFS datasets are correct, <Enter>, ctrl+c to exit script" </dev/tty

# Copy Base System to new install
udevadm trigger
debootstrap "$VC" /mnt
cp /etc/hostid /mnt/etc/hostid
cp /etc/resolv.conf /mnt/etc/
mkdir /mnt/etc/zfs && cp /etc/zfs/zroot.key /mnt/etc/zfs

# Copy Scripts to Chroot Env
cp -av /media/scripts/* /mnt/root
# Shorten chroot "apt update" by using previous live update records
cp -a /var/lib/apt/lists /mnt/var/lib/apt

# Setup Chroot
mount -t proc proc /mnt/proc
mount -t sysfs sys /mnt/sys
mount -B /dev /mnt/dev
mount -t devpts pts /mnt/dev/pts
echo "You are now in chroot - run the second script"
chroot /mnt /bin/bash
