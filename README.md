# zfsbootmanager
Script to Automate Debian Install on ZFS ROOT with ZFSBootManager

ZFS Boot Manager (ZBM) is the SOTA when it come to ZFS on ROOT in my opinion. This script takes the excellent [documentation provided](https://docs.zfsbootmenu.org/en/v2.3.x/guides/debian/bookworm-uefi.html) and adds several automation layers and configuration options. With thanks to the ZBM team for their input on MBR HDD.

There are 2 scripts. The first is to chroot, the second is to install (must be started from within the chrooted environment). The scripts could be combined to one, but it is better to visually confirm critical steps.

For older BIOS based Hardware, it is advised that an MBR partition should be used since ZBM only works with UEFI and a chainloaded (Syslinux/Grub -> ZBM) is needed for ZBM. Further, Syslinux does not work with GPT Partitions. Grub is not preferred in this case as on package update and the subsequent update-grub command messes with the boot menu.

__zbmdeb*.sh__
* Please read through the scripts to understand pittfalls and limitations. Assumes a standard HDD partition (3) for ZFS with Boot, Swap, Zpool. You must modify if you want something else.
* Boot partition uses Vfat32 for UEFI/GPT and Ext4 for BIOS/MBR
* It is a misconception that ZFS is inadvisible on LowMemory systems. This is completely dependent on the ZFS ARC (Adaptive Replacement Cache) setting, which this script addresses. Setting the `zfs_arc_max` to 10% (or whatever) of available RAM will make ZFS work on LowMem hardware (see [here](https://forums.freebsd.org/threads/zfs-on-low-end-computer.79062/)). You can also toggle `zfs_prefetch_disable` (Disable ARC), but this produces a slugish system.
* Distinguishes Sata & Nvme HDD settings.
* Populates `/etc/fstab` entries, with /tmp & /var/tmp mounted as tmpfs with the `noexec` flag (you should be using `noexec` for these folders). `noexec` will prevent script or binary execution from there, so something like `curl <some_http> | bash` will fail since the command fisrt places the file in /tmp.
* tzdata & locales are buggy, not exactly giving the desired results with `noninteractive`, so be aware...
* Assumes zbmdeb* scripts are mounted on `/media/scripts/` to copy into chroot. Modify accordingly.

__zfsflags.sh__
* This script is to work with `zfs-auto-snapshot` package. By default, snaphots are all Enabled for all Datasets for all Periods. This creates many unwanted snapshots. A simple script that sets all flags to false, then sets the Wanted Dataset:Period to true.
* Set the ZKEEP variable for number of snapshots to keep and the ZWANT array for Datasets to auto-snapshot. Same as `zfs set com.sun:auto-snapshot:weekly=true,keep=6 pool/dataset` OR edit each `/etc//cron.<period>/zfs-auto-snapshot` & modify to `--keep=6`
* See Usage: Take manual snaps of ZWANT Datasets. Take snaps of all OS level (/, /var, /usr/local, etc) Datasets and rollback same in batch - usefull for keeping a fresh / pristine copy of a system. 
