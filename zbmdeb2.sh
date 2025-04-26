#!/usr/bin/env bash

# CHANGE BELOW PARAMETERS BEFORE RUNNING AS "source ./this-script.sh"
export HOSTNAME="this-pc"
export HOSTDOMAIN="example.org"
export RPASSWD="root-password"
export SECUSER="myuser"
export SPASSWD="myuser-password"
export TZONE="Europe/City"
export MYLOCALE="en_US.UTF-8"
# ZFS arc_max in Bytes. 10% of RAM for LowMem systems. Normally set to 0.
ZFSARCMAX="0"

echo "$HOSTNAME" > /etc/hostname
cat << EOF >> /etc/hosts
127.0.0.1    "$HOSTNAME"."$HOSTDOMAIN" "$HOSTNAME" localhost
EOF

# Configure Apt Sources
cat << EOF > /etc/apt/sources.list
deb http://deb.debian.org/debian "$VC" main contrib non-free-firmware
deb-src http://deb.debian.org/debian "$VC" main contrib non-free-firmware
deb http://deb.debian.org/debian-security "$VC"-security main contrib non-free-firmware
deb-src http://deb.debian.org/debian-security "$VC"-security main contrib non-free-firmware
deb http://deb.debian.org/debian "$VC"-updates main contrib non-free-firmware
deb-src http://deb.debian.org/debian "$VC"-updates main contrib non-free-firmware
EOF

apt update
apt install -y locales keyboard-configuration console-setup curl
# Configure TimeZone
echo "$TZONE" > /etc/timezone && dpkg-reconfigure -f noninteractive tzdata
# Configure Locales
sed -i -e "s/# $MYLOCALE UTF-8/$MYLOCALE UTF-8/" /etc/locale.gen && \
    dpkg-reconfigure --frontend=noninteractive locales && \
    locale-gen && update-locale LANG="$MYLOCALE"
    # echo "$MYLOCALE" > /etc/default/locale
dpkg-reconfigure keyboard-configuration console-setup

# Install ZFS Modules & Enable
apt install -y linux-headers-amd64 linux-image-amd64 dosfstools
# Suppress TAINTED KERNEL confirm message
#DEBIAN_FRONTEND=noninteractive apt install -y zfs-initramfs
apt install -y zfs-initramfs
echo "REMAKE_INITRD=yes" > /etc/dkms/zfs.conf
systemctl enable zfs.target
systemctl enable zfs-import-cache
systemctl enable zfs-mount
systemctl enable zfs-import.target
echo "UMASK=0077" > /etc/initramfs-tools/conf.d/umask.conf
echo "options zfs zfs_arc_max=$ZFSARCMAX" >> /etc/modprobe.d/zfs.conf
echo "$ZFSARCMAX" /sys/module/zfs/parameters/zfs_arc_max
read -p "Disable ZFS Prefetch (ARC)? Complete disable not advised (N/y)" ZPD
if [[ "$ZPD" == "y" ]]; then
    echo "options zfs zfs_prefetch_disable=1" >> /etc/modprobe.d/zfs.conf
fi
update-initramfs -c -k all

# ZFSBootMenu Settings on Root Zpool. zbm.skip
# zfs set org.zfsbootmenu:commandline="zfs.zfs_arc_max=8589934592" zroot
zfs set org.zfsbootmenu:commandline="zbm.timeout=5 loglevel=4"  "$POOL_NAME"/ROOT
if [ -n "$POOL_KEY" ]; then
  zfs set org.zfsbootmenu:keysource="${POOL_NAME}/ROOT/${VID}" "$POOL_NAME"
fi

# BOOT CONFIGURATION FUNCTIONS
function boot_gpt () {
    mkfs.vfat -F32 -n EFIBOOT "$BOOT_DEV"
    # EFI Boot Records
    mkdir -p /boot/efi
    mount "$BOOT_DEV" /boot/efi
    mkdir -p /boot/efi/EFI/ZBM
    # Using pre-built ZBM image
    curl -o /boot/efi/EFI/ZBM/VMLINUZ.EFI -L https://get.zfsbootmenu.org/efi
    cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI
    mount -t efivarfs efivarfs /sys/firmware/efi/efivars
    apt install -y efibootmgr

    # Specific to NVME PART - drop first char (p)
    if [ ${#BOOT_PART} -gt 1 ]; then EFI_DEV=${BOOT_PART:1}; else EFI_DEV=$BOOT_PART; fi

    efibootmgr -c -d "$BOOT_DISK" -p "$EFI_DEV" \
        -L "ZFSBootMenu (Backup)" -l '\EFI\ZBM\VMLINUZ-BACKUP.EFI'
    efibootmgr -c -d "$BOOT_DISK" -p "$EFI_DEV" \
         -L "ZFSBootMenu" -l '\EFI\ZBM\VMLINUZ.EFI'
}

function boot_mbr () {
    mkfs.ext4 -L SYSLINUX "$BOOT_DEV"
    mkdir -p /boot/syslinux
    mount "$BOOT_DEV" /boot/syslinux
    mkdir /boot/syslinux/zfsbootmenu
    # Using pre-built ZBM image
    curl -o ~/zfsbootmenu.tar.gz -L https://get.zfsbootmenu.org/latest.tar.gz
    tar -xf ~/zfsbootmenu.tar.gz --strip-components=1 \
        -C /boot/syslinux/zfsbootmenu/
    rm ~/zfsbootmenu.tar.gz
    cp /boot/syslinux/zfsbootmenu/vmlinuz-bootmenu \
       /boot/syslinux/zfsbootmenu/vmlinuz-bootmenu-backup
    cp /boot/syslinux/zfsbootmenu/initramfs-bootmenu.img \
       /boot/syslinux/zfsbootmenu/initramfs-bootmenu-backup.img

    apt install -y syslinux extlinux
    cp /usr/lib/syslinux/modules/bios/*.c32 /boot/syslinux
    extlinux --install /boot/syslinux
    dd bs=440 count=1 conv=notrunc if=/usr/lib/syslinux/mbr/mbr.bin of="$BOOT_DISK"

    cat > /boot/syslinux/syslinux.cfg <<EOF
UI menu.c32
PROMPT 1
TIMEOUT 1
MENU TITLE ZFSBootMenu
DEFAULT zfsbootmenu

LABEL zfsbootmenu
        MENU LABEL ZFSBootMenu
        KERNEL /zfsbootmenu/vmlinuz-bootmenu
        INITRD /zfsbootmenu/initramfs-bootmenu.img
        APPEND zfsbootmenu zbm.timeout=5

LABEL zfsbootmenu-backup
         MENU LABEL ZFSBootMenu (Backup)
        KERNEL /zfsbootmenu/vmlinuz-bootmenu-backup
        INITRD /zfsbootmenu/initramfs-bootmenu-backup.img
        APPEND zfsbootmenu zbm.timeout=5
EOF
}

# Install Boot Record per Partition Label Type
eval "boot_""$HDDPL"

# /etc/fstab Setup - Read about noexec on /tmp, breaks /tmp resident scripts
mkswap -L swap "$SWAP_DEV"
cat << EOF > /etc/fstab
# Scipt Created FSTAB Entries
${POOL_NAME}/ROOT/${VID}     /    zfs    rw  0  0
tmpfs           /tmp            tmpfs  rw,nosuid,nodev,relatime,noexec  0  0
tmpfs           /var/tmp        tmpfs  rw,nosuid,nodev,relatime,noexec  0  0
EOF

# Parse blkid output for each partition and feed to fstab
PARTS="$(env | grep '_DEV' | grep -v 'POOL' | cut -d = -f 2)"
# Transform to Array for loop
PARR=($PARTS)
for PART in "${PARR[@]}"; do
    # Remove the device/partition header from string
    PSTR="$(blkid $PART | cut -d : -f 2)"
    FUUID="$(echo $PSTR | tr ' ' '\n' | grep '^UUID')"
    FTYPE="$(echo $PSTR | tr ' ' '\n' | grep 'TYPE' | cut -d = -f 2 | tr -d '\"')"
    MSTR="defaults 0 0"
    if [ "$FTYPE" == "vfat" ]; then 
        MPOINT="/boot/efi"
    elif [ "$FTYPE" == "ext4" ]; then 
        MPOINT="/boot/syslinux"
    elif [ "$FTYPE" == "swap" ]; then 
        MPOINT="none" && MSTR="sw,pri=0  0  0"  
    else
        MPOINT="none"
    fi
    echo "$FUUID   $MPOINT   $FTYPE   $MSTR" >> /etc/fstab
done

# User Setup
echo "root:$RPASSWD" | chpasswd
zfs create rpool/home/"$SECUSER"
useradd -m -s /bin/bash -U -G sudo,operator,users "$SECUSER"
echo "$SECUSER:$SPASSWD" | chpasswd
chown -R "$SECUSER":"$SECUSER" /home/"$SECUSER"

# Basic Functionality Packages Before Reboot
apt install -y localepurge ntp openssh-server

## IF YOU NEED WIFI
function want_wifi() {
    # Use dhcp-client for Debian-12, dhcpd for Debian-13
    apt install -y firmware-iwlwifi ifupdown iproute2 wpasupplicant iw 
    WSSID="wifi-ssid"
    WPASS="wifi-password"
    ip a
    read -p "Name of WiFI Interface? " IWF
    ip link set "$IWF" down
    ip link set "$IWF" up
    wpa_passphrase "$WSSID" "$WPASS" | \
        tee -a /etc/wpa_supplicant/wpa_supplicant.conf
    wpa_supplicant -B -c /etc/wpa_supplicant/wpa_supplicant.conf -i "$IWF"
    dhcpcd -b "$IWF"
}

## STATIC IP SETTING
function want_staticip() {
    MYNIC="eno1"
    cat << EOF >> /etc/network/interfaces.d/"$MYNIC".cfg
auto "$MYNIC"
    iface "$MYNIC" inet static
        address 192.168.1.x/24
        gateway 192.168.1.1
EOF
}

read -p "Do you want WiFi (N/y)" SIP
if [ "$SIP" == "y" ]; then eval want_wifi(); fi
read -p "Do you want Static IP? (N/y)" WIP
if [ "$WIP" == "y" ]; then eval want_staticip(); fi

# REVIEW FSTAB ENTRIES
cat /etc/fstab

echo "+++ DONE - type 'exit' to end chroot environment +++"
echo "--- Remember to 'umount -n -R /mnt && zpool export ${POOL_NAME}' - No problem if you get an 'export error / pool busy' message"
echo "Then reboot"
