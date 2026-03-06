#!/usr/bin/env bash

source /root/install_vars.sh
# CHANGE BELOW PARAMETERS BEFORE RUNNING AS "source ./this-script.sh"
export HOSTNAME="this-pc"
export HOSTDOMAIN="example.org"
export RPASSWD="root-password"
export SECUSER="myuser"
export SPASSWD="myuser-password"

export TZONE="Europe/City"
export LOCALE_PRIMARY="en_US.UTF-8"
export LOCALE_SECONDARY="xy_XY.UTF-8"

export ZFS_ARC_MAX="0"            # Set in bytes, or 0 for default
export ZFS_PREFETCH_DISABLE="n"   # Set to "y" to disable prefetch !! NOT ADVISED


# Function to setup system identity basics
setup_identity() {
    # Set hostname
    echo "$HOSTNAME" > /etc/hostname
    # Using > instead of >> to ensure a clean file in the chroot
    cat <<EOF > /etc/hosts
127.0.0.1   localhost
127.0.1.1   ${HOSTNAME}.${HOSTDOMAIN} ${HOSTNAME}

# The following lines are desirable for IPv6 capable hosts
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF
}


config_basics() {
    apt-get update
    echo "Configuring Timezone, Locales, and Keyboard..." >&2
    # Set Non-interactive frontend
    export DEBIAN_FRONTEND=noninteractive
    # Install necessary pkgs
    apt-get install -y locales keyboard-configuration console-setup curl

    # Configure Timezone - Linking ensures dpkg-reconfigure picks it up
    ln -sf "/usr/share/zoneinfo/$TZONE" /etc/localtime
    echo "$TZONE" > /etc/timezone
    dpkg-reconfigure -f noninteractive tzdata

    # Configure Locales
    if [[ -f /etc/locale.gen ]]; then
        # Enable both locales in the generation file
        local L
        for L in "$LOCALE_PRIMARY" "$LOCALE_SECONDARY"; do
            # Only attempt if the variable is not empty
            [[ -n "$L" ]] && sed -i "s/^# *$L/$L/" /etc/locale.gen
        done
        # Generate all enabled locales
        locale-gen
        # Set the primary locale as the system default LANG
        update-locale LANG="$LOCALE_PRIMARY"
    fi

    locale -a    # Print generated locales
    # Configure Keyboard and Console
    dpkg-reconfigure keyboard-configuration
    dpkg-reconfigure console-setup
}


# Install ZFS Modules & Enable
config_zfs() {
    echo "Configuring ZFS Modules, Services, and Boot Properties..." >&2
    export DEBIAN_FRONTEND=noninteractive
    # Pre-seed debconf to bypass the ZFS license/taint note
    echo "zfs-dkms zfs-dkms/note-incompatible-license note" | debconf-set-selections
    # Install Kernel and ZFS Initramfs components
    apt-get install -y linux-headers-amd64 linux-image-amd64 zfs-initramfs dosfstools

    # ZFS Module & Initramfs Tweaks
    echo "REMAKE_INITRD=yes" > /etc/dkms/zfs.conf
    echo "UMASK=0077" > /etc/initramfs-tools/conf.d/umask.conf
    # Modprobe settings (ARC Max and Prefetch)
    {
        echo "# ZFS Tuning"
        [[ "$ZFS_ARC_MAX" != "0" ]] && echo "options zfs zfs_arc_max=$ZFS_ARC_MAX"
        [[ "$ZFS_PREFETCH_DISABLE" =~ ^[Yy]$ ]] && echo "options zfs zfs_prefetch_disable=1"
    } > /etc/modprobe.d/zfs.conf

    # Enable ZFS Systemd Services
    systemctl enable zfs.target zfs-import-cache zfs-mount zfs-import.target
    # ZFSBootMenu - set commandline options on ROOT dataset
    zfs set org.zfsbootmenu:commandline="zbm.timeout=4 loglevel=4" \
        "$POOL_NAME/ROOT"
    # If using encryption, set the keysource to the OS dataset
    if [[ -n "$POOL_KEY" ]]; then
        zfs set org.zfsbootmenu:keysource="${POOL_NAME}/keystore" "$POOL_NAME"
    fi

    update-initramfs -c -k all
}


config_gpt() {
    # Format and Mount EFI Partition
    mkfs.vfat -F32 -n "EFIBOOT" "$BOOT_DEV"
    mkdir -p /boot/efi
    mount "$BOOT_DEV" /boot/efi

    # Download ZFSBootMenu EFI Stub
    mkdir -p /boot/efi/EFI/ZBM
    curl -L -o /boot/efi/EFI/ZBM/VMLINUZ.EFI https://get.zfsbootmenu.org/efi || exit 1
    cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI

    # Check if efivarfs is mounted, if not, mount it (required for efibootmgr)
    mountpoint -q /sys/firmware/efi/efivars || mount -t efivarfs efivarfs /sys/firmware/efi/efivars

    # Install efibootmgr and register boot entries
    apt-get install -y efibootmgr
    
    # Extract numeric index (e.g., p1 or 1 -> 1)
    local BOOT_NDX=${BOOT_PART//[!0-9]/}

    # Register Backup first so it's lower in priority
    efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_NDX" \
        -L "ZFSBootMenu (Backup)" -l '\EFI\ZBM\VMLINUZ-BACKUP.EFI'
    # Register Primary
    efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_NDX" \
        -L "ZFSBootMenu" -l '\EFI\ZBM\VMLINUZ.EFI'
}


config_mbr() {
    # Format and Mount Boot Partition
    mkfs.ext2 -L "SYSLINUX" "$BOOT_DEV"
    mkdir -p /boot/syslinux
    mount "$BOOT_DEV" /boot/syslinux

    # Download and Extract ZFSBootMenu Component Assets
    mkdir -p /boot/syslinux/zfsbootmenu
    curl -L -o /tmp/zbm.tar.gz https://get.zfsbootmenu.org/latest.tar.gz || exit 1
    tar -xf /tmp/zbm.tar.gz --strip-components=1 -C /boot/syslinux/zfsbootmenu/
    rm /tmp/zbm.tar.gz

    # Create Backups
    cp /boot/syslinux/zfsbootmenu/vmlinuz-bootmenu /boot/syslinux/zfsbootmenu/vmlinuz-bootmenu-backup
    cp /boot/syslinux/zfsbootmenu/initramfs-bootmenu.img /boot/syslinux/zfsbootmenu/initramfs-bootmenu-backup.img

    # Install Syslinux
    apt-get install -y syslinux extlinux syslinux-common
    
    # Copy required modules
    cp /usr/lib/syslinux/modules/bios/*.c32 /boot/syslinux/
    extlinux --install /boot/syslinux

    # Write MBR to the disk (Stage 1)
    dd bs=440 count=1 conv=notrunc if=/usr/lib/syslinux/mbr/mbr.bin of="$BOOT_DISK"

    # Create Syslinux Configuration
    cat <<EOF > /boot/syslinux/syslinux.cfg
UI menu.c32
PROMPT 0
TIMEOUT 30
MENU TITLE ZFSBootMenu (Legacy BIOS)
DEFAULT zfsbootmenu

LABEL zfsbootmenu
    MENU LABEL ZFSBootMenu
    KERNEL /zfsbootmenu/vmlinuz-bootmenu
    INITRD /zfsbootmenu/initramfs-bootmenu.img
    APPEND zfsbootmenu zbm.timeout=5 loglevel=4

LABEL zfsbootmenu-backup
    MENU LABEL ZFSBootMenu (Backup)
    KERNEL /zfsbootmenu/vmlinuz-bootmenu-backup
    INITRD /zfsbootmenu/initramfs-bootmenu-backup.img
    APPEND zfsbootmenu zbm.timeout=5 loglevel=4
EOF
}


# Install Boot Record per Partition Label Type
setup_bootloader() {
    case "${HDDPL,,}" in
        gpt) config_gpt ;;
        mbr) config_mbr ;;
        *)   echo "Error: Invalid partition label type: $HDDPL"; exit 1 ;;
    esac
}


# /etc/fstab Setup - Read about noexec on /tmp, breaks /tmp resident scripts
config_fstab() {
    #Prepare Swap
    mkswap -f -L "SWAP" "$SWAP_DEV"
    # Write Base fstab (ZFS Root and Tmpfs)
    cat <<EOF > /etc/fstab
# <file system> <mount point> <type> <options> <dump> <pass>
${POOL_NAME}/ROOT/${OS_ID}  /  zfs  defaults,noatime,x-systemd.requires=zfs-import.target  0  0

# Temporary filesystems
tmpfs  /tmp      tmpfs  rw,nosuid,nodev,relatime  0  0
tmpfs  /var/tmp  tmpfs  rw,nosuid,nodev,relatime  0  0
EOF

    # Handle Boot Partition (GPT/EFI or MBR/Syslinux)
    local BOOT_UUID BOOT_TYPE MPOINT
    BOOT_UUID=$(lsblk -dno UUID "$BOOT_DEV")
    BOOT_TYPE=$(lsblk -dno FSTYPE "$BOOT_DEV")
    
    [[ "${HDDPL,,}" == "gpt" ]] && MPOINT="/boot/efi" || MPOINT="/boot/syslinux"

    if [[ -n "$BOOT_UUID" ]]; then
        echo "UUID=$BOOT_UUID  $MPOINT  $BOOT_TYPE  defaults,noatime  0  2" >> /etc/fstab
    fi

    # Handle Swap Partition
    local SWAP_UUID
    SWAP_UUID=$(lsblk -dno UUID "$SWAP_DEV")
    if [[ -n "$SWAP_UUID" ]]; then
        echo "UUID=$SWAP_UUID  none  swap  sw,pri=10  0  0" >> /etc/fstab
    fi
}


config_user() {
    #Set Root Password
    echo "root:$RPASSWD" | chpasswd

    # Create Secure_User
    if [[ -n "$SECUSER" ]]; then
        echo "Creating user $SECUSER..." >&2
        zfs create "$POOL_NAME/home/$SECUSER"
        useradd -m -s /bin/bash -G sudo,users,netdev,audio,video "$SECUSER"
        echo "$SECUSER:$SPASSWD" | chpasswd
        chown -R "$SECUSER:$SECUSER" "/home/$SECUSER"
        # Optional: Set secure permissions for home directory
        ## chmod 700 "/home/$SECUSER"
    fi
}


setup_services() {
    echo "Installing and configuring system services..." >&2
    export DEBIAN_FRONTEND=noninteractive

    # Pre-seed localepurge (adjust locales to match your config_basic selections)
    echo "localepurge localepurge/nopurge multiselect $LOCALE_PRIMARY, $LOCALE_SECONDARY" | debconf-set-selections
    echo "localepurge localepurge/use-dpkg-feature boolean true" | debconf-set-selections

    # Install Packages: Add if wanted: unattended-upgrades netplan.io
    apt-get install -y localepurge ntpsec openssh-server smartmontools \
        bash-completion rsync isenkram-cli 


    # isenkram checks kernel log & hardware modaliases, installs missing firmware
    isenkram-autoinstall-firmware
    # CPU Microcode Detection & Installation - just to be sure
    if grep -qi "GenuineIntel" /proc/cpuinfo; then
        apt-get install -y intel-microcode
    elif grep -qi "AuthenticAMD" /proc/cpuinfo; then
        apt-get install -y amd64-microcode
    fi

    # Configure SSH (Allow Root Password Login)
    if [[ -f /etc/ssh/sshd_config ]]; then
        # Replace either commented or existing PermitRootLogin line
        sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
        # Explicitly ensure Password Authentication is enabled
        sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
        systemctl enable ssh
    fi

    # Enable ZFS Scrub & Smartmontools
    systemctl enable "zfs-scrub-monthly@${POOL_NAME}.timer"
    systemctl enable smartmontoolsqq
    localepurge
}


## IF YOU NEED WIFI
want_wifi() {
    # Install packages
    apt-get install -y firmware-iwlwifi wpasupplicant iw dhcpcd
    # Get WiFi Details
    read -rp "Enter WiFi SSID: " WIFI_SSID
    read -rp "Enter WiFi Password: " WIFI_PASS

    # Identify Interface
    ip -color link show >&2
    read -rp "Name of WiFi Interface (e.g., wlan0): " WIFI_IFACE

    # Securely generate wpa_supplicant config
    mkdir -p /etc/wpa_supplicant
    ( umask 0077 && wpa_passphrase "$WIFI_SSID" "$WIFI_PASS" > /etc/wpa_supplicant/wpa_supplicant.conf )

    # Configure for next boot
    cat <<EOF > /etc/network/interfaces.d/"$WIFI_IFACE"
auto $WIFI_IFACE
iface $WIFI_IFACE inet dhcp
    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
EOF

    systemctl enable dhcpcd
    echo "WiFi configured for $WIFI_IFACE." >&2
}


want_staticip() {
    # Install ifupdown
    apt-get install -y ifupdown

    # Identify Interface
    ip -color link show >&2
    read -rp "Interface Name (e.g., eno1): " STATIC_NIC
    read -rp "IP Address with CIDR (e.g., 192.168.1.50/24): " STATIC_IP
    read -rp "Gateway IP (e.g., 192.168.1.1): " STATIC_GW
    read -rp "DNS Servers (e.g., 1.1.1.1 8.8.8.8): " STATIC_DNS

    # Write Config
    cat <<EOF > /etc/network/interfaces.d/"$STATIC_NIC"
auto $STATIC_NIC
iface $STATIC_NIC inet static
    address $STATIC_IP
    gateway $STATIC_GW
    dns-nameservers $STATIC_DNS
EOF

    echo "Static IP configured for $STATIC_NIC." >&2
}


unmount_chroot() {
    umount -f "$BOOT_DEV"
    umount -f /sys/firmware/efi/efivars
    umount -f /dev/pts
    for FS in dev proc sys; do umount "/$FS"; done
}


####################
# MAIN EXECUTION #
####################
setup_identity
config_basics
config_zfs
setup_bootloader
config_fstab
config_user
setup_services


##### FINISH UP #####
read -rp "Do you want WiFi? (N/y): " YN
[[ "$YN" =~ ^[Yy]$ ]] && want_wifi
read -rp "Do you want Static IP? (N/y): " YN
[[ "$YN" =~ ^[Yy]$ ]] && want_staticip

apt-get clean

# REVIEW FSTAB ENTRIES
cat /etc/fstab

echo "+++ DONE - type 'exit' to end chroot environment +++"
echo "--- Remember to 'umount -n -R /mnt && zpool export ${POOL_NAME}' - No problem if you get an 'export error / pool busy' message"
echo "Then reboot"

read -rp "Unmount /proc /dev etc?" YN
[[ "$YN" =~ ^[Yy]$ ]] && unmount_chroot

