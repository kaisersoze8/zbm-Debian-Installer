#!/usr/bin/env bash
# Set Labels for ZFS Datasets

DATE=$(date +%Y%m%d)
# List of ZFS datasets
ZFSL=`/usr/sbin/zfs list -H -o name`
ZFST=`/usr/sbin/zfs list -H -o name -t snapshot`
# Name of option flag
ZOPT='com.sun:auto-snapshot'
# Define periods
ZPER=':monthly :weekly :daily :hourly :frequent'
# Extract Name of ROOT Dataset
ZROOT=$(df | grep -w "/" | cut -d ' ' -f 1)
# Number of Snaphots to keep in string format to append
ZKEEP=",keep=6"
# Wanted snapshots. Defaults to :daily 'pool/xyz :weekly' for other period
declare -a ZWANT=( 'rpool/home/myfolder'
    'rpool/ROOT/debian/var/lib//mysql :hourly'
    'rpool/ROOT/debian/opt :weekly'
)

function disable()  {
  # Set the fs top level flags to false
  for Z in "$ZFSL"; do
    /usr/sbin/zfs set "$ZOPT"=false $Z
    echo $(/usr/sbin/zfs get -H "$ZOPT" "$Z")
    # Set the periodic flags to false
    for ZP in "$ZPER"; do
      /usr/sbin/zfs set "$ZOPT""$ZP"=false "$Z"
      echo $(/usr/sbin/zfs get -H "$ZOPT""$ZP" "$Z")
    done
  done
}

function enable()  {
  # Array processing must use " (' does not work)
  for Z in "${ZWANT[@]}"; do
    # Parse the array values
    ZWFS=$(echo "$Z" | cut -f1 -d ' ')
    ZWPER=$(echo "$Z" | cut -f2 -d ' ')
    # Correct cut output & set default value for ZPER
    if [[ "$ZWPER" == "$ZWFS" ]]; then ZWPER=':daily'; fi
    # auto-snapshot need 2 flags - top-level & period to be set
    /usr/sbin/zfs set "$ZOPT"=true "$ZWFS"
    echo $(/usr/sbin/zfs get -H "$ZOPT" "$ZWFS")
    /usr/sbin/zfs set "$ZOPT$""ZWPER"=true"$ZKEEP" "$ZWFS"
    echo $(/usr/sbin/zfs get -H "$ZOPT""$ZWPER""$ZKEEP" "$ZWFS")
  done
}

function manual_snap()  {
  # Array processing must use " (' does not work)
  for Z in "${ZWANT[@]}"; do
    # Parse the array values, get first field
    ZWFS=$(echo "$Z" | cut -f1 -d ' ')
    /usr/sbin/zfs snapshot -o snapshot:type='manual' "$ZWFS@manual-$DATE"
  done
}

function remove_manual_snap()  {
  for Z in "$ZFST"; do
    manual_flag=$(echo "$Z" | cut -f2 -d '@' | cut -f1 -d '-')
    if [ "$manual_flag" == 'manual' ]; then
        read -p "Destroy y/n  "$Z"  ?" -n 1 -r
        if [[ "$REPLY" =~ ^[Yy]$ ]]; then
            /usr/sbin/zfs destroy "$Z"
            echo   # move to new line
        fi
    fi
  done
}

function remove_all_snap()  {
  for Z in "$ZFST"; do
    /usr/sbin/zfs destroy "$Z"
    echo "$Z"
  done
}

function os_snap()  {
  ZOS=$(df | grep "$ZROOT" | cut -d ' ' -f 1)
  for Z in "$ZOS"; do
    /usr/sbin/zfs snapshot -o snapshot:type='manual' "$Z@manual-$DATE"
    echo "$Z"
}

function os_rollback()  {
  ZOS=$(df | grep "$ZROOT" | cut -d ' ' -f 1)
  for Z in "$ZOS"; do
    ZS=$(/usr/sbin/zfs list -t snapshot -s creation -o name "$Z" | tail -n 1)
    /usr/sbin/zfs rollback "$ZS"
    echo "$Z  $ZS"
  done
}

function usage()  {
    cat <<EOF
Possible Options:
    -d  disable flags (set false)
    -e  enable flags (set true)
    -m  take manual snapshots of Wanted Datasets
    -n  remove manual snapshots selectively
    -o  snapshot the OS level Datasets
    -r  rollback the OS level Datasets
    -x  remove all snapshots
EOF
    exit 1
}

#############################
# End of function definitions

while getopts "demnorx" flag; do
    case "${flag}" in
    #g) ACTION="mygrub"  ;;
    d) MODULE="disable"  ;;
    e) MODULE="enable"  ;;
    m) MODULE="manual_snap"  ;;
    n) MODULE="remove_manual_snap"  ;;
    o) MODULE="os_snap"  ;;
    r) MODULE="os_rollback"  ;;
    x) MODULE="remove_all_snap"  ;;
    *) MODULE="usage"  ;;
    esac
done

eval  ${MODULE}
