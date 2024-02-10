#!/bin/bash -eu

function log_progress () {
  if declare -F setup_progress > /dev/null
  then
    setup_progress "create-backingfiles-partition: $1"
    return
  fi
  echo "create-backingfiles-partition: $1"
}

# install XFS tools if needed
if ! hash mkfs.xfs
then
  apt-get -y --force-yes install xfsprogs
fi

function partition_prefix_for {
  case $1 in
    /dev/mmcblk* | /dev/nvme*)
      echo p
      ;;
    /dev/sd*)
      echo
      ;;
    *)
      setup_progress "STOP: can't determine partition naming scheme for '$1'"
      exit 1
      ;;
  esac
}

# Will check for USB Drive before running sd card
if [ -n "$DATA_DRIVE" ]
then
  log_progress "DATA_DRIVE is set to $DATA_DRIVE"
  PARTITION_PREFIX=$(partition_prefix_for "$DATA_DRIVE")
  P1="${DATA_DRIVE}${PARTITION_PREFIX}1"
  P2="${DATA_DRIVE}${PARTITION_PREFIX}2"
  # Check if backingfiles and mutable partitions exist
  if [ /dev/disk/by-label/backingfiles -ef "$P2" ] && [ /dev/disk/by-label/mutable -ef "$P1" ]
  then
    log_progress "Looks like backingfiles and mutable partitions already exist. Skipping partition creation."
  else
    log_progress "WARNING !!! This will delete EVERYTHING in $DATA_DRIVE."
    wipefs -afq "$DATA_DRIVE"
    parted "$DATA_DRIVE" --script mktable gpt
    log_progress "$DATA_DRIVE fully erased. Creating partitions..."
    parted -a optimal -m "$DATA_DRIVE" mkpart primary ext4 '0%' 2GB
    parted -a optimal -m "$DATA_DRIVE" mkpart primary ext4 2GB '100%'
    log_progress "Backing files and mutable partitions created."

    log_progress "Formatting new partitions..."
    # Force creation of filesystems even if previous filesystem appears to exist
    mkfs.ext4 -F -L mutable "$P1"
    mkfs.xfs -f -m reflink=1 -L backingfiles "$P2"
  fi

  BACKINGFILES_MOUNTPOINT="$1"
  MUTABLE_MOUNTPOINT="$2"
  if grep -q backingfiles /etc/fstab
  then
    log_progress "backingfiles already defined in /etc/fstab. Not modifying /etc/fstab."
  else
    echo "LABEL=backingfiles $BACKINGFILES_MOUNTPOINT xfs auto,rw,noatime 0 2" >> /etc/fstab
  fi
  if grep -q 'mutable' /etc/fstab
  then
    log_progress "mutable already defined in /etc/fstab. Not modifying /etc/fstab."
  else
    echo "LABEL=mutable $MUTABLE_MOUNTPOINT ext4 auto,rw 0 2" >> /etc/fstab
  fi
  log_progress "Done."
  exit 0
else
  echo "DATA_DRIVE not set. Proceeding to SD card setup"
fi

readonly LAST_PARTITION_DEVICE=$(sfdisk -l "$BOOT_DISK" | tail -1 | awk '{print $1}')
readonly LAST_PART_NUM=${LAST_PARTITION_DEVICE:0-1}
readonly BACKINGFILES_DEVICE="${BOOT_DEVICE_PARTITION_PREFIX}$((LAST_PART_NUM + 1))"
readonly MUTABLE_DEVICE="${BOOT_DEVICE_PARTITION_PREFIX}$((LAST_PART_NUM + 2))"
# If the backingfiles partition follows the root partition, is type xfs,
# and is in turn followed by the mutable partition, type ext4, then return early.
if [ /dev/disk/by-label/backingfiles -ef "${BACKINGFILES_DEVICE}" ] && \
    [ /dev/disk/by-label/mutable -ef "${MUTABLE_DEVICE}" ] && \
    blkid "${MUTABLE_DEVICE}" | grep -q 'TYPE="ext4"'
then
  if blkid "${BACKINGFILES_DEVICE}" | grep -q 'TYPE="xfs"'
  then
    # assume these were either created previously by the setup scripts,
    # or manually by the user, and that they're big enough
    log_progress "using existing backingfiles and mutable partitions"
    return &> /dev/null || exit 0
  elif blkid "${BACKINGFILES_DEVICE}" | grep -q 'TYPE="ext4"'
  then
    # special case: convert existing backingfiles from ext4 to xfs
    log_progress "reformatting existing backingfiles as xfs"
    killall archiveloop || true
    /root/bin/disable_gadget.sh || true
    if mount | grep -qw "/mnt/cam"
    then
      if ! umount /mnt/cam
      then
        log_progress "STOP: couldn't unmount /mnt/cam"
        exit 1
      fi
    fi
    if mount | grep -qw "/backingfiles"
    then
      if ! umount /backingfiles
      then
        log_progress "STOP: couldn't unmount /backingfiles"
        exit 1
      fi
    fi
    mkfs.xfs -f -m reflink=1 -L backingfiles "${BACKINGFILES_DEVICE}"

    # update /etc/fstab
    sed -i 's/LABEL=backingfiles .*/LABEL=backingfiles \/backingfiles xfs auto,rw,noatime 0 2/' /etc/fstab
    mount /backingfiles
    log_progress "backingfiles converted to xfs and mounted"
    return &> /dev/null || exit 0
  fi
fi

# backingfiles and mutable partitions either don't exist, or are the wrong type
if [ -e "${BACKINGFILES_DEVICE}" ] || [ -e "${MUTABLE_DEVICE}" ]
then
  log_progress "STOP: partitions already exist, but are not as expected"
  log_progress "please delete them and re-run setup"
  exit 1
fi

BACKINGFILES_MOUNTPOINT="$1"
MUTABLE_MOUNTPOINT="$2"

log_progress "Checking existing partitions..."

DISK_SECTORS=$(blockdev --getsz "${BOOT_DISK}")
LAST_DISK_SECTOR=$((DISK_SECTORS - 1))
# mutable partition is 100MB at the end of the disk, calculate its start sector
FIRST_MUTABLE_SECTOR=$((LAST_DISK_SECTOR-204800+1))
# backingfiles partition sits between the last and mutable partition, calculate its start sector and size
LAST_PART_SECTOR=$(sfdisk -l "${BOOT_DISK}" | grep "${LAST_PARTITION_DEVICE}" | awk '{print $3}')
FIRST_BACKINGFILES_SECTOR=$((LAST_PART_SECTOR + 1))
BACKINGFILES_NUM_SECTORS=$((FIRST_MUTABLE_SECTOR - FIRST_BACKINGFILES_SECTOR))

echo firstbackingfilesmutable $FIRST_BACKINGFILES_SECTOR
echo first mutable $FIRST_MUTABLE_SECTOR

# As a rule of thumb, one gigabyte of /backingfiles space can hold about 36
# recording files. We need enough inodes in /mutable to create symlinks to
# the recordings. Leaving enough headroom to account for short recordings,
# directories, duplication of sentry files in recentclips, etc, this works
# out to about 1 inode for every 20000 sectors in /backingfiles.
NUM_MUTABLE_INODES=$((BACKINGFILES_NUM_SECTORS / 20000))

ORIGINAL_DISK_IDENTIFIER=$( fdisk -l "${BOOT_DISK}" | grep -e "^Disk identifier" | sed "s/Disk identifier: 0x//" )

log_progress "Modifying partition table for backing files partition..."
echo "$FIRST_BACKINGFILES_SECTOR,$BACKINGFILES_NUM_SECTORS" | sfdisk --force "${BOOT_DISK}" -N $((LAST_PART_NUM + 1))

log_progress "Modifying partition table for mutable (writable) partition for script usage..."
echo "$FIRST_MUTABLE_SECTOR," | sfdisk --force "${BOOT_DISK}" -N $((LAST_PART_NUM + 2))

# manually adding the partitions to the kernel's view of things is sometimes needed
if [ ! -e "${BACKINGFILES_DEVICE}" ] || [ ! -e "${MUTABLE_DEVICE}" ]
then
  partx --add --nr $((LAST_PART_NUM + 1)):$((LAST_PART_NUM + 2)) "${BOOT_DISK}"
fi
if [ ! -e "${BACKINGFILES_DEVICE}" ] || [ ! -e "${MUTABLE_DEVICE}" ]
then
  log_progress "failed to add partitions"
  exit 1
fi

NEW_DISK_IDENTIFIER=$( fdisk -l "${BOOT_DISK}" | grep -e "^Disk identifier" | sed "s/Disk identifier: 0x//" )

log_progress "Writing updated partitions to fstab and cmdline.txt"
sed -i "s/${ORIGINAL_DISK_IDENTIFIER}/${NEW_DISK_IDENTIFIER}/g" /etc/fstab
if [ -f "$CMDLINE_PATH" ]
then
  sed -i "s/${ORIGINAL_DISK_IDENTIFIER}/${NEW_DISK_IDENTIFIER}/" "$CMDLINE_PATH"
fi

log_progress "Formatting new partitions..."
# Force creation of filesystems even if previous filesystem appears to exist
mkfs.xfs -f -m reflink=1 -L backingfiles "${BACKINGFILES_DEVICE}"
mkfs.ext4 -F -N "$NUM_MUTABLE_INODES" -L mutable "${MUTABLE_DEVICE}"

echo "LABEL=backingfiles $BACKINGFILES_MOUNTPOINT xfs auto,rw,noatime 0 2" >> /etc/fstab
echo "LABEL=mutable $MUTABLE_MOUNTPOINT ext4 auto,rw 0 2" >> /etc/fstab
