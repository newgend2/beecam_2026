#!/usr/bin/env bash
set -euo pipefail

DEV="/dev/mmcblk0"
DATA_PART="${DEV}p3"
MOUNTPOINT="/data"
DATA_LABEL="DATA"
SEED_CONFIG_DIR="/home/pi/setup/configs"
FSTAB="/etc/fstab"
MARKER="${MOUNTPOINT}/.beecam-data-initialized"

log() {
    echo "beecam-init-data: $*"
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log "missing required command: $1"
        exit 1
    fi
}

require_cmd awk
require_cmd blkid
require_cmd mountpoint

if [[ ! -b "$DEV" ]]; then
    log "expected SD device $DEV was not found"
    exit 1
fi

if [[ ! -b "$DATA_PART" ]]; then
    require_cmd blockdev
    require_cmd parted
    require_cmd partprobe
    require_cmd udevadm

    log "creating DATA partition in remaining SD-card space"
    ROOT_END_SECTOR=$(
        parted -m "$DEV" unit s print |
            awk -F: '$1 == "2" { gsub(/s/, "", $3); print $3 }'
    )

    if [[ -z "${ROOT_END_SECTOR:-}" ]]; then
        log "could not determine root partition end"
        exit 1
    fi

    DATA_START_SECTOR=$((ROOT_END_SECTOR + 1))
    DISK_SECTORS=$(blockdev --getsz "$DEV")
    FREE_SECTORS=$((DISK_SECTORS - DATA_START_SECTOR))
    MIN_FREE_SECTORS=$((1024 * 1024 * 1024 / 512))

    if (( FREE_SECTORS < MIN_FREE_SECTORS )); then
        log "not enough unallocated space after root to create DATA partition"
        log "the root partition probably fills the SD card"
        log "run partition_beecam_sd_on_pc.sh from a Linux PC/laptop"
        exit 2
    fi

    parted -s "$DEV" unit s mkpart primary "${DATA_START_SECTOR}s" 100%
    partprobe "$DEV" || true
    udevadm settle
fi

if [[ ! -b "$DATA_PART" ]]; then
    log "DATA partition $DATA_PART still does not exist after creation"
    exit 1
fi

DATA_TYPE=$(blkid -o value -s TYPE "$DATA_PART" 2>/dev/null || true)
if [[ -z "$DATA_TYPE" ]]; then
    require_cmd mkfs.exfat
    log "formatting $DATA_PART as exFAT"
    mkfs.exfat -n "$DATA_LABEL" "$DATA_PART"
elif [[ "$DATA_TYPE" != "exfat" ]]; then
    log "$DATA_PART has unexpected filesystem type '$DATA_TYPE'; refusing to overwrite it"
    exit 1
fi

DATA_UUID=$(blkid -o value -s UUID "$DATA_PART")
if [[ -z "$DATA_UUID" ]]; then
    log "could not determine DATA filesystem UUID"
    exit 1
fi

mkdir -p "$MOUNTPOINT"

FSTAB_LINE=$(printf 'UUID=%s  %s  exfat  defaults,nofail,noatime,uid=1000,gid=1000,umask=000  0  0' "$DATA_UUID" "$MOUNTPOINT")
if ! grep -Eq "^UUID=${DATA_UUID}[[:space:]]+${MOUNTPOINT}[[:space:]]" "$FSTAB"; then
    log "updating DATA mount in $FSTAB"
    TMP_FSTAB=$(mktemp)
    awk '$2 != "/data" { print }' "$FSTAB" > "$TMP_FSTAB"
    printf '%s\n' "$FSTAB_LINE" >> "$TMP_FSTAB"
    cp "$TMP_FSTAB" "$FSTAB"
    rm -f "$TMP_FSTAB"
fi

if ! mountpoint -q "$MOUNTPOINT"; then
    log "mounting DATA partition"
    mount "$MOUNTPOINT" || mount "$DATA_PART" "$MOUNTPOINT"
fi

mkdir -p "${MOUNTPOINT}/logs" "${MOUNTPOINT}/images_and_labels"

if [[ -d "$SEED_CONFIG_DIR" && ! -e "${MOUNTPOINT}/configs" ]]; then
    log "copying default configs from ${SEED_CONFIG_DIR} to ${MOUNTPOINT}/configs"
    mkdir -p "${MOUNTPOINT}/configs"
    cp -a "${SEED_CONFIG_DIR}/." "${MOUNTPOINT}/configs/"
elif [[ ! -e "${MOUNTPOINT}/configs" ]]; then
    log "default config directory ${SEED_CONFIG_DIR} was not found; /data/configs was not created"
fi

touch "$MARKER"
log "DATA partition is ready"
