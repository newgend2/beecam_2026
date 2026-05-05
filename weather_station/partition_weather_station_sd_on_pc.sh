#!/usr/bin/env bash
set -euo pipefail
trap 'echo "ERROR: partition script failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_SIZE_MIB=10240
ROOT_STAGING_FS_SIZE=9G
DATA_LABEL=DATA
SCRIPT_VERSION="2026-05-05.1"

log() {
    echo
    echo "==> $*"
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        echo "Install it on the PC/laptop, for example: sudo apt install e2fsprogs parted exfatprogs util-linux" >&2
        exit 1
    fi
}

partition_path() {
    local dev="$1"
    local part="$2"
    if [[ "$dev" == *"mmcblk"* || "$dev" == *"nvme"* ]]; then
        printf '%sp%s' "$dev" "$part"
    else
        printf '%s%s' "$dev" "$part"
    fi
}

cleanup() {
    set +e
    if [[ -n "${ROOT_MNT:-}" ]] && mountpoint -q "$ROOT_MNT"; then sudo umount "$ROOT_MNT"; fi
    if [[ -n "${DATA_MNT:-}" ]] && mountpoint -q "$DATA_MNT"; then sudo umount "$DATA_MNT"; fi
    [[ -n "${ROOT_MNT:-}" ]] && rmdir "$ROOT_MNT" 2>/dev/null
    [[ -n "${DATA_MNT:-}" ]] && rmdir "$DATA_MNT" 2>/dev/null
}
trap cleanup EXIT

for cmd in awk blkid blockdev e2fsck mkfs.exfat mount mountpoint parted partprobe resize2fs udevadm; do
    require_cmd "$cmd"
done

if [[ ! -d "${SCRIPT_DIR}/configs" ]]; then
    echo "Missing ${SCRIPT_DIR}/configs" >&2
    exit 1
fi

echo "Weather station SD partition script version: ${SCRIPT_VERSION}"
echo
echo "Detected block devices:"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS,TRAN
echo
read -r -p "Enter SD device to partition (example: /dev/mmcblk0): " DEV

if [[ ! -b "$DEV" ]]; then
    echo "$DEV is not a block device" >&2
    echo "Run lsblk and enter the parent disk path, not a mount point." >&2
    exit 1
fi

ROOT="$(partition_path "$DEV" 2)"
DATA="$(partition_path "$DEV" 3)"
DATA_MODE="create"

if [[ ! -b "$ROOT" ]]; then
    echo "Expected $ROOT to exist" >&2
    exit 1
fi

if [[ -b "$DATA" ]]; then
    DATA_TYPE=$(sudo blkid -o value -s TYPE "$DATA" 2>/dev/null || true)
    if [[ "$DATA_TYPE" == "exfat" ]]; then
        DATA_MODE="reuse"
    elif [[ -z "$DATA_TYPE" ]]; then
        DATA_MODE="format-existing"
    else
        echo "$DATA already exists with filesystem type '$DATA_TYPE'; refusing to overwrite it." >&2
        echo "Current layout:" >&2
        lsblk -f "$DEV" >&2 || true
        exit 1
    fi
fi

echo
case "$DATA_MODE" in
    create)
        echo "This will shrink $ROOT to 10GiB and create exFAT DATA on the remaining space."
        ;;
    format-existing)
        echo "$DATA already exists with no filesystem. This will format it as exFAT DATA."
        ;;
    reuse)
        echo "$DATA already exists as exFAT. This will reuse it and finish fstab/config setup."
        ;;
esac
read -r -p "Type yes to continue: " CONFIRM
CONFIRM="${CONFIRM,,}"
if [[ "$CONFIRM" != "yes" && "$CONFIRM" != "y" ]]; then
    echo "Aborted."
    exit 1
fi

log "Unmounting SD card partitions"
sudo umount "${ROOT}" "$(partition_path "$DEV" 1)" "$DATA" 2>/dev/null || true

if [[ "$DATA_MODE" == "create" ]]; then
    ROOT_START_MIB=$(sudo parted -m "$DEV" unit MiB print | awk -F: '$1 == "2" { gsub(/MiB/, "", $2); printf "%.0f", $2 }')
    ROOT_END_MIB=$((ROOT_START_MIB + ROOT_SIZE_MIB))

    log "Checking root filesystem"
    sudo e2fsck -f "$ROOT"

    log "Shrinking ext4 filesystem below final 10GiB partition size"
    sudo resize2fs "$ROOT" "$ROOT_STAGING_FS_SIZE"

    log "Shrinking root partition to 10GiB"
    sudo parted ---pretend-input-tty "$DEV" resizepart 2 "${ROOT_END_MIB}MiB" Yes
    sudo partprobe "$DEV" || true
    sudo udevadm settle

    log "Growing ext4 filesystem to fill resized root partition"
    sudo e2fsck -f "$ROOT"
    sudo resize2fs "$ROOT"

    log "Creating exFAT DATA partition"
    sudo parted -s "$DEV" mkpart primary "${ROOT_END_MIB}MiB" 100%
    sudo partprobe "$DEV" || true
    sudo udevadm settle

    if [[ ! -b "$DATA" ]]; then
        echo "Waiting for $DATA to appear..."
        sleep 2
        sudo partprobe "$DEV" || true
        sudo udevadm settle
    fi
fi

if [[ "$DATA_MODE" != "reuse" ]]; then
    if [[ ! -b "$DATA" ]]; then
        echo "$DATA does not exist; cannot format DATA partition" >&2
        exit 1
    fi
    log "Formatting DATA partition as exFAT"
    sudo mkfs.exfat -n "$DATA_LABEL" "$DATA"
fi

DATA_UUID=$(sudo blkid -o value -s UUID "$DATA")
if [[ -z "$DATA_UUID" ]]; then
    echo "Could not determine DATA UUID" >&2
    exit 1
fi

ROOT_MNT="$(mktemp -d /tmp/weather-root.XXXXXX)"
DATA_MNT="$(mktemp -d /tmp/weather-data.XXXXXX)"

log "Mounting new SD card filesystems"
sudo mount "$ROOT" "$ROOT_MNT"
sudo mount "$DATA" "$DATA_MNT"

log "Updating target /etc/fstab for /data"
FSTAB_LINE=$(printf 'UUID=%s  /data  exfat  defaults,nofail,noatime,uid=1000,gid=1000,umask=000  0  0' "$DATA_UUID")
TMP_FSTAB="$(mktemp)"
sudo awk '$2 != "/data" { print }' "${ROOT_MNT}/etc/fstab" > "$TMP_FSTAB"
printf '%s\n' "$FSTAB_LINE" >> "$TMP_FSTAB"
sudo install -m 0644 "$TMP_FSTAB" "${ROOT_MNT}/etc/fstab"
rm -f "$TMP_FSTAB"
sudo mkdir -p "${ROOT_MNT}/data"

log "Copying configs to DATA partition"
sudo mkdir -p "${DATA_MNT}/configs" "${DATA_MNT}/logs" "${DATA_MNT}/weather"
sudo cp -r "${SCRIPT_DIR}/configs/." "${DATA_MNT}/configs/"

log "Final SD card layout"
lsblk -f "$DEV"

log "Done. You can put the card back in the Pi and boot it."
