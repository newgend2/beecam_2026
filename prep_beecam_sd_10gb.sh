#!/usr/bin/env bash
set -e

ROOT_SIZE_MIB=10240
ROOT_STAGING_FS_SIZE=9G
DATA_LABEL=DATA

echo "Detecting SD card..."
lsblk -o NAME,SIZE,MODEL,TRAN | grep mmc

read -p "Enter SD device (example: /dev/mmcblk0): " DEV

BOOT="${DEV}p1"
ROOT="${DEV}p2"
DATA="${DEV}p3"

echo "Unmounting partitions..."
sudo umount "${DEV}"p* 2>/dev/null || true

if [[ -e "$DATA" ]]; then
    echo "Data partition already exists at $DATA; refusing to overwrite it."
    exit 1
fi

ROOT_START_MIB=$(sudo parted -m "$DEV" unit MiB print | awk -F: '$1 == "2" { gsub(/MiB/, "", $2); printf "%.0f", $2 }')
ROOT_END_MIB=$((ROOT_START_MIB + ROOT_SIZE_MIB))

read -r FS_BLOCKS FS_BLOCK_SIZE < <(
    sudo dumpe2fs -h "$ROOT" 2>/dev/null |
        awk -F: '
            /^Block count:/ { gsub(/ /, "", $2); blocks=$2 }
            /^Block size:/ { gsub(/ /, "", $2); size=$2 }
            END { print blocks, size }
        '
)

FS_BYTES=$((FS_BLOCKS * FS_BLOCK_SIZE))
PART_BYTES=$(sudo blockdev --getsize64 "$ROOT")

if (( FS_BYTES > PART_BYTES )); then
    echo "Filesystem is larger than the current partition; expanding partition before fsck..."
    sudo parted ---pretend-input-tty "$DEV" resizepart 2 "${ROOT_END_MIB}MiB" Yes
    sudo partprobe "$DEV" || true
    sudo udevadm settle
fi

echo "Checking filesystem..."
sudo e2fsck -f "$ROOT"

echo "Shrinking filesystem below final 10GiB partition size..."
sudo resize2fs "$ROOT" "$ROOT_STAGING_FS_SIZE"

echo "Shrinking partition to 10GiB..."
sudo parted ---pretend-input-tty "$DEV" resizepart 2 "${ROOT_END_MIB}MiB" Yes
sudo partprobe "$DEV" || true
sudo udevadm settle

echo "Growing filesystem to fill the resized partition..."
sudo e2fsck -f "$ROOT"
sudo resize2fs "$ROOT"

echo "Creating exFAT data partition..."
sudo parted -s "$DEV" mkpart primary "${ROOT_END_MIB}MiB" 100%
sudo partprobe "$DEV" || true
sudo udevadm settle

echo "Formatting exFAT partition..."
sudo mkfs.exfat -n "$DATA_LABEL" "$DATA"

echo ""
echo "Finished. Final layout:"
lsblk -f "$DEV"
