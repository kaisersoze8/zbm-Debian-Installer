#!/usr/bin/env bash

set -e

# READ PARAMETERS FROM USER
read -rp "Set ZFS Pool Name [rpool]: " POOL_NAME
export POOL_NAME=${POOL_NAME:-rpool}
# Encrypted HDD Password (<enter> if no encryption)
read -rp "Set ZFS Pool Key, <enter> for None: " POOL_KEY
# If encryption is enabled, build keystring
export POOL_KEYSTR=${POOL_KEY:+"-O encryption=aes-256-gcm -O keyformat=passphrase -O keylocation=file:///etc/zfs/key/zroot.key"}
# ZFS compatibility level setting (if needed)
read -rp "Set ZFS Compatibililty Default 2.1? (N/y): " YN
[[ $YN == [Yy]* ]] && export POOL_COMPAT="2.1" || export POOL_COMPAT=""
# If compatibility is set, append compatibility option
POOL_COMPATSTR=${POOL_COMPAT:+"-o compatibility=openzfs-$POOL_COMPAT-linux"}
# Desired partition label (either "gpt" or "mbr")
read -rp "Partition Label to use: gpt/mbr [gpt]: " HDDPL
export HDDPL=${HDDPL:-gpt}


check_basics() {
    # Are we Root?
    [[ $EUID -ne 0 ]] && { echo "Must be Root to run this script."; exit 1; }
    # Check Connection
    ping -c 2 8.8.8.8 &>/dev/null && echo "Internet is reachable" || \
        { echo "No internet connection"; exit 1; }

    # One-Shot Date/Time refresh
    read -pn "Adjust System Time (bad cmos battery) - y/[N]?" YN
    if [[ "$YN" =~ ^[Yy]$ ]]; then
        local CW_STRING
        if command -v curl > /dev/null; then CW_STRING='curl -sI';
        elif command -v wget > /dev/null; then CW_STRING='wget -q --max-redirect=0';
        else echo "Neither curl nor wget installed. Set manually (date -s)" && exit 1;
        fi

        date -s "$($CW_STRING https://google.com | grep -i '^Date:' | cut -d' ' -f3-)"
    fi
}

##### DYNAMIC VARIABLE DETECTION #####
# Function to select disk /w confirmation. Avoid  output contamination.
# everything echoed inside function is captured into the DISK variable
# to fix this, all UI text must be sent to stderr (>&2)
select_disk() {
    local DISK_TYPE="$1"
    shift
    local DISKS=("$@")
    local DISK_NAME=""
    local CHOICE=""

    while true; do
        # Display available disks (Redirected to stderr via >&2)
        echo -e "\n--- Available ${DISK_TYPE} disks ---" >&2
        for i in "${!DISKS[@]}"; do
            echo "$((i+1)). ${DISKS[$i]}" >&2
        done

        # Get the user's selection
        read -rp "Select ${DISK_TYPE} disk by number: " CHOICE

        # Ensure input is number and in-range. Regex ^[0-9]+$ is integer
        if [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= ${#DISKS[@]} )); then
            DISK_NAME="${DISKS[$((CHOICE-1))]}"
            
            # Confirm disk selection
            read -rp "Confirm ${DISK_TYPE} disk selection: ${DISK_NAME}? (y/N): " CONFIRMATION
            if [[ "$CONFIRMATION" =~ ^[Yy]$ ]]; then
                break # Exit loop
            fi
        else
            echo "Invalid selection: '$CHOICE'. Please enter a number between 1 and ${#DISKS[@]}." >&2
        fi
    done

    # Return ONLY the disk name to stdout
    echo "$DISK_NAME"
}

# Function to detect available disks, disk type and ashift
detect_disk() {
    # Map sector sizes to ashift using a Bash Associative Array
    declare -A ASHIFTS=([512]=9 [4096]=12 [8192]=13 [16384]=14)

    # Detect whole disks only (avoiding partitions sda1, nvme0n1p1)
    local DISKS=($(lsblk -dpno NAME,TYPE | awk '$2=="disk" {print $1}'))
    # If no disks found, exit
    [[ ${#DISKS[@]} -eq 0 ]] && { echo "Error: No disks found."; exit 1; }
    # Display available disks
    echo "Available disks:"
    for i in "${!DISKS[@]}"; do echo "$((i+1)). ${DISKS[$i]}"; done

    # Prompt user for selections
    BOOT_DISK=$(select_disk "BOOT" "${DISKS[@]}")
    POOL_DISK=$(select_disk "POOL" "${DISKS[@]}")

    # Determine disk type and partition suffix (sda1 vs nvme0n1p1)
    [[ "$POOL_DISK" =~ "nvme" ]] && export PART_SUFFIX="p" || export PART_SUFFIX=""
    # Get Physical Sector Size
    local BLOCK_SIZE
    BLOCK_SIZE=$(blockdev --getpbsz "$POOL_DISK")
    # Match block size to ashift, default to 12
    export POOL_ASHIFT=${ASHIFTS[$BLOCK_SIZE]:-12}
    echo "Detected block size $BLOCK_SIZE. Setting POOL_ASHIFT to $POOL_ASHIFT."

    # Assign partition values
    export BOOT_PART="${PART_SUFFIX}1"
    export SWAP_PART="${PART_SUFFIX}2"
    export POOL_PART="${PART_SUFFIX}3"

    export BOOT_DEV="${BOOT_DISK}${BOOT_PART}"
    export SWAP_DEV="${POOL_DISK}${SWAP_PART}"
    export POOL_DEV="${POOL_DISK}${POOL_PART}"
}

##### PREP LIVE SYSTEM FOR ZFS #####
# Function to modify apt sources
modify_sources() {
    . /etc/os-release
    export OS_CODENAME="$VERSION_CODENAME"
    export OS_ID="$ID"
    # Define components (use non-free-firmware)
    local COMP="main contrib non-free-firmware non-free"

   # Create a full sources.list file
    cat <<EOF > /etc/apt/sources.list
deb http://deb.debian.org/debian $OS_CODENAME $COMP
deb-src http://deb.debian.org/debian $OS_CODENAME $COMP

deb http://deb.debian.org/debian-security ${OS_CODENAME}-security $COMP
deb-src http://deb.debian.org/debian-security ${OS_CODENAME}-security $COMP

deb http://deb.debian.org/debian ${OS_CODENAME}-updates $COMP
deb-src http://deb.debian.org/debian ${OS_CODENAME}-updates $COMP
EOF
}

# Install required packages. Use apt-get in scripts for better stability
install_packages() {
    # Set environment to non-interactive
    export DEBIAN_FRONTEND=noninteractive
    # Pre-seed debconf to bypass the ZFS license/taint note
    echo "zfs-dkms zfs-dkms/note-incompatible-license note" | debconf-set-selections
    # Update and install in a single optimized block
    apt-get update
    local PKGS=(
        debootstrap 
        gdisk 
        dkms 
        linux-headers-"$(uname -r)" 
        zfsutils-linux 
        zfs-dkms
    )

    apt-get install -y "${PKGS[@]}" || \
        { echo "Package installation failed"; exit 1; }

    # Set hostid for ZFS
    zgenhostid -f 0x00bab10c
}

##### HDD OPS #####
extract_indices() {
    BOOT_NDX=${BOOT_PART//[!0-9]/}
    SWAP_NDX=${SWAP_PART//[!0-9]/}
    POOL_NDX=${POOL_PART//[!0-9]/}
}

# Function to partition the disk using GPT
partition_gpt() {
    extract_indices
    # Zap disks only once (if BOOT_DISK = POOL_DISK)
    local TARGETS=("$BOOT_DISK")
    [[ "$BOOT_DISK" != "$POOL_DISK" ]] && TARGETS+=("$POOL_DISK")
    for DISK in "${TARGETS[@]}"; do sgdisk --zap-all "$DISK"; done

    # Create partitions, 6G SWAP. Change '0:+6g' to your preference
    sgdisk -n "${BOOT_NDX}:1m:+512m" -t "${BOOT_NDX}:ef00" "$BOOT_DISK"
    sgdisk -n "${SWAP_NDX}:0:+6g"    -t "${SWAP_NDX}:8200" "$POOL_DISK"
    # All remaining space to the Pool
    sgdisk -n "${POOL_NDX}:0:0"      -t "${POOL_NDX}:bf00" "$POOL_DISK"
}

# Function to partition the disk using MBR
partition_mbr() {
    apt-get install -y parted
    extract_indices
    # Setup Boot Disk
    parted -sf "$BOOT_DISK" mklabel msdos
    # ZBM requires chained SysLinux for MBR Boot. SysLinux has issues > ext2
    parted -sf -a optimal "$BOOT_DISK" mkpart primary ext2 1MiB 513MiB
    parted -sf "$BOOT_DISK" set "$BOOT_NDX" boot on

    # Setup Pool Disk if different
    [[ "$POOL_DISK" != "$BOOT_DISK" ]] && parted -sf "$POOL_DISK" mklabel msdos
    # Setup Swap and Pool
    parted -sf -a optimal "$POOL_DISK" mkpart primary linux-swap 513MiB 6657MiB
    parted -sf -a optimal "$POOL_DISK" mkpart primary 6657MiB 100%
}

# Function to wipe and partition the disk
wipe_and_partition() {
    # Wipe the HDD clean and re-format if needed
    zpool labelclear -f "$POOL_DEV" 2>/dev/null || true
    # Prompt for format
    read -rp "Re-Format Disks? This WIPES ALL DATA! (y/N): " RFHDD
    if [[ "$RFHDD" =~ ^[Yy]$ ]]; then
        echo "Wiping filesystem signatures..." >&2
        wipefs -a "$BOOT_DISK"
        [[ "$BOOT_DISK" != "$POOL_DISK" ]] && wipefs -a "$POOL_DISK"

        # Execute partitioning based on HDDPL (gpt or mbr)
        case "${HDDPL,,}" in # ,, converts to lowercase for safety
            gpt) partition_gpt ;;
            mbr) partition_mbr ;;
            *)   echo "Error: Invalid partition type '$HDDPL'"; exit 1 ;;
        esac
    else
        echo "Skipping format. Ensure partitions $BOOT_DEV and $POOL_DEV exist." >&2
    fi
}


# Function to create the ZFS pool and datasets
create_zpool() {
    # Only create the file if POOL_KEY is not empty
    if [[ -n "$POOL_KEY" ]]; then
        mkdir -p /etc/zfs/key
        echo "$POOL_KEY" > /etc/zfs/key/zroot.key
        chmod 600 /etc/zfs/key/zroot.key
    fi

    # Create Zpool
    # use POOL_KEYSTR and POOL_COMPATSTR (which are empty if not set)
    zpool create -f \
        -o ashift="$POOL_ASHIFT" \
        -o autotrim=on \
        -O compression=lz4 \
        -O xattr=sa \
        -O acltype=posixacl \
        -O relatime=on \
        -m none \
        $POOL_KEYSTR $POOL_COMPATSTR \
        "$POOL_NAME" "$POOL_DEV" || { echo "Failed to create pool"; exit 1; }

    # Create ROOT and OS datasets
    zfs create -o mountpoint=none "$POOL_NAME"/ROOT
    zfs create -o mountpoint=/ -o canmount=noauto "$POOL_NAME"/ROOT/"$OS_ID"
    zpool set bootfs="$POOL_NAME"/ROOT/"$OS_ID" "$POOL_NAME"

    # Create sub-datasets for OS & Home
    zfs create -o mountpoint=/home -o canmount=on "$POOL_NAME"/home
    # usr is specifically set to canmount=off in most ZFS-on-Linux layouts
    zfs create -o canmount=off "$POOL_NAME"/ROOT/"$OS_ID"/usr
    local DATASET
    for DATASET in usr/local var var/lib opt; do
        zfs create -o canmount=on "$POOL_NAME"/ROOT/"$OS_ID"/"$DATASET"
    done

    # Export and re-import to /mnt
    zpool export "$POOL_NAME"
    zpool import -Nf -R /mnt "$POOL_NAME"
    [[ -n "$POOL_KEY" ]] && zfs load-key "$POOL_NAME"
    zfs mount "$POOL_NAME"/ROOT/"$OS_ID"
    zfs mount -a
}

# Function to copy base system
copy_base_system() {
    udevadm trigger
    debootstrap "$OS_CODENAME" /mnt || { echo "Debootstrap failed"; exit 1; }
    cp /etc/hostid /mnt/etc/hostid
     # Use -L to ensure we copy the actual content if resolv.conf is a symlink
    cp -L /etc/resolv.conf /mnt/etc/

    # Generate and copy ZFS Cache so initramfs finds pool faster at boot
    mkdir -p /mnt/etc/zfs/key
    zpool set cachefile=/etc/zfs/zpool.cache "$POOL_NAME"
    # Copy cache and key (if exists) preserving permissions
    cp -p /etc/zfs/zpool.cache /mnt/etc/zfs/
    if [ -f /etc/zfs/key/zroot.key ]; then
        zfs create -o canmount=noauto -o mountpoint=/etc/zfs/key "$POOL_NAME"/keystore
        zfs mount "$POOL_NAME"/keystore
        cp -p /etc/zfs/key/zroot.key /mnt/etc/zfs/key/
    fi

    # Sync APT sources & cache to chroot
    cp -a /etc/apt /mnt/etc/
    mkdir -p /mnt/var/lib/apt/lists
    cp -a /var/lib/apt/lists/* /mnt/var/lib/apt/lists/ 2>/dev/null || true
}

####################
# MAIN EXECUTION #
####################
check_basics
detect_disk
modify_sources
install_packages
wipe_and_partition
create_zpool
copy_base_system

#### PREPARE CHROOT LAUNCH ####
# Detect current script directory and copy to /mnt/root
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
SCRIPT_FOLDER=$(basename "$SCRIPT_DIR")
cp -r "$SCRIPT_DIR" /mnt/root/

# Save environment variables to /mnt/root/install_vars.sh
cat <<EOF > /mnt/root/install_vars.sh
export OS_ID="$OS_ID"
export OS_CODENAME="$OS_CODENAME"
export HDDPL="$HDDPL"
export DISK_TYPE="$DISK_TYPE"
export BOOT_DISK="$BOOT_DISK"
export SWAP_DISK="$SWAP_DISK"
export POOL_DISK="$POOL_DISK"
export BOOT_DEV="$BOOT_DEV"
export SWAP_DEV="$SWAP_DEV"
export POOL_DEV="$POOL_DEV"
export PART_SUFFIX="$PART_SUFFIX"
export BOOT_PART="$BOOT_PART"
export SWAP_PART="$SWAP_PART"
export POOL_PART="$POOL_PART"
export BOOT_NDX="$BOOT_NDX"
export SWAP_NDX="$SWAP_NDX"
export POOL_NDX="$POOL_NDX"
export POOL_NAME="$POOL_NAME"
export POOL_KEY="$POOL_KEY"
EOF

# Mount essential filesystems
for FS in proc sys dev; do
    mount --bind "/$FS" "/mnt/$FS"
done
mount --bind /dev/pts /mnt/dev/pts

# Transition to script2 within the chroot
echo "Entering chroot to execute second script..."
chroot /mnt /usr/bin/env bash "/root/$SCRIPT_FOLDER/zbmdeb2.sh"

