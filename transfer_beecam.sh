#!/usr/bin/env bash
# Transfer BeeCam data from an SD card rootfs or DATA mount to external storage.
#
# Usage:
#   ./transfer_beecam.sh
#   ./transfer_beecam.sh <mounted_source_path> <dest_path>
#
# Arguments:
#   mounted_source_path   Mount point of the SD card rootfs or DATA partition
#   dest_path             Destination directory on the external SSD
#
# Example:
#   ./transfer_beecam.sh /media/user/rootfs /media/user/BackupSSD
#
# Requires: zip, unzip
# Optional: pv  (progress bars - apt install pv)

set -euo pipefail

die() { echo "Error: $*" >&2; exit 1; }

MEDIA_ROOTS=(/media/wlab /media/nate /media/field3)

path_is_mountpoint() {
    local path="$1"
    if command -v mountpoint >/dev/null 2>&1; then
        mountpoint -q "$path"
        return
    fi

    local parent
    parent=$(dirname "$path")
    [[ "$(df -P "$path" 2>/dev/null | awk 'NR==2 {print $1}')" != "$(df -P "$parent" 2>/dev/null | awk 'NR==2 {print $1}')" ]]
}

flush_filesystem() {
    local path="$1"
    echo "Flushing SD card writes..."
    if sync -f "$path" >/dev/null 2>&1; then
        return
    fi
    sync
}

print_disk_usage() {
    local label="$1"
    local path="$2"
    local used size pct
    if ! read -r size used pct < <(df -h "$path" | awk 'NR==2 {print $2, $3, $5}'); then
        return
    fi
    [[ -n "${size:-}" ]] || return
    printf "  %s: %s used of %s (%s)\n" "$label" "$used" "$size" "$pct"
}

get_mount_source() {
    local path="$1"
    if command -v findmnt >/dev/null 2>&1; then
        findmnt -n -o SOURCE --target "$path" 2>/dev/null | sed -n '1p'
        return
    fi
    df -P "$path" 2>/dev/null | awk 'NR==2 {print $1}'
}

unmount_source() {
    local path="$1"
    local device="$2"
    local label="$3"

    echo ""
    echo "Unmounting SD card ${label} partition..."
    cd /

    if [[ -n "$device" && "$device" == /dev/* ]] && command -v udisksctl >/dev/null 2>&1; then
        if udisksctl unmount -b "$device" >/dev/null 2>&1; then
            echo "  Unmounted: $device"
            return
        fi
    fi

    if umount "$path" 2>/dev/null; then
        echo "  Unmounted: $path"
        return
    fi

    if [[ -n "$device" && "$device" == /dev/* ]] && umount "$device" 2>/dev/null; then
        echo "  Unmounted: $device"
        return
    fi

    if command -v sudo >/dev/null 2>&1 && sudo -n umount "$path" 2>/dev/null; then
        echo "  Unmounted: $path"
        return
    fi

    die "Could not unmount $path without prompting. Close any windows or terminals using the SD card, then unmount it manually."
}

get_current_user() {
    local u
    u=${SUDO_USER:-${USER:-}}
    if [[ -z "$u" ]]; then
        u=$(id -un 2>/dev/null || printf 'user')
    fi
    u=${u//[[:space:]]/}
    [[ -n "$u" ]] || u="user"
    printf '%s\n' "$u"
}

path_has_beecam_data() {
    local path="$1"
    [[ -d "$path" ]] || return 1
    [[ -e "$path/images_and_labels" || -e "$path/logs" || -e "$path/configs" || -e "$path/hostname" ]]
}

add_candidate() {
    local kind="$1"
    local mount_path="$2"
    local data_path="$3"
    [[ -d "$mount_path" && -d "$data_path" ]] || return 0
    path_is_mountpoint "$mount_path" || return 0
    if [[ "$kind" != "DATA" ]]; then
        path_has_beecam_data "$data_path" || return 0
    fi
    SOURCE_CANDIDATES+=("${kind}|${mount_path}|${data_path}")
}

detect_default_dest() {
    local current_user="$1"
    local path

    path="/media/${current_user}/T7 Shield"
    if [[ -d "$path" ]]; then
        printf '%s\n' "$path"
        return
    fi

    for base in "${MEDIA_ROOTS[@]}"; do
        path="${base}/T7 Shield"
        if [[ -d "$path" ]]; then
            printf '%s\n' "$path"
            return
        fi
    done

    printf '%s\n' "/media/${current_user}/T7 Shield"
}

choose_candidate() {
    local kind="$1"
    local count="${#SOURCE_CANDIDATES[@]}"
    local candidate

    if [[ "$count" -eq 0 ]]; then
        return 1
    fi
    if [[ "$count" -gt 1 ]]; then
        echo "Found multiple mounted BeeCam ${kind} candidates:" >&2
        for candidate in "${SOURCE_CANDIDATES[@]}"; do
            IFS='|' read -r _kind mount_path data_path <<< "$candidate"
            echo "  ${mount_path} -> ${data_path}" >&2
        done
        die "Pass the intended source mount path explicitly."
    fi

    IFS='|' read -r SOURCE_KIND SOURCE_MOUNT DATA_SRC <<< "${SOURCE_CANDIDATES[0]}"
    return 0
}

auto_detect_source() {
    local base path

    SOURCE_CANDIDATES=()
    for base in "${MEDIA_ROOTS[@]}"; do
        for path in "${base}/DATA" "${base}/data"; do
            add_candidate "DATA" "$path" "$path"
        done
    done
    if choose_candidate "DATA"; then
        return
    fi

    SOURCE_CANDIDATES=()
    for base in "${MEDIA_ROOTS[@]}"; do
        for path in "${base}/rootfs" "${base}/ROOTFS"; do
            add_candidate "rootfs" "$path" "${path}/home/pi/data"
        done
    done
    if choose_candidate "rootfs"; then
        return
    fi

    die "Could not find a mounted BeeCam DATA partition or rootfs under /media/wlab, /media/nate, or /media/field3."
}

resolve_explicit_source() {
    local source_path="$1"
    local source_name
    source_path="${source_path%/}"
    source_name="$(basename "$source_path")"

    [[ "$source_path" != "/" ]] || die "Refusing to use / as the mounted SD source path."
    [[ -d "$source_path" ]] || die "Mounted source path does not exist: $source_path"

    if ! path_is_mountpoint "$source_path"; then
        die "Source path exists but is not a mounted filesystem: $source_path. Mount the SD card rootfs or DATA partition and pass that mount point."
    fi

    if [[ "$source_name" == "DATA" || "$source_name" == "data" ]]; then
        SOURCE_KIND="DATA"
        SOURCE_MOUNT="$source_path"
        DATA_SRC="$source_path"
        return
    fi

    if path_has_beecam_data "$source_path"; then
        SOURCE_KIND="DATA"
        SOURCE_MOUNT="$source_path"
        DATA_SRC="$source_path"
        return
    fi

    if [[ -d "${source_path}/home/pi/data" ]]; then
        SOURCE_KIND="rootfs"
        SOURCE_MOUNT="$source_path"
        DATA_SRC="${source_path}/home/pi/data"
        return
    fi

    die "Mounted source does not contain BeeCam data. Checked ${source_path} and ${source_path}/home/pi/data."
}

usage() {
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

CURRENT_USER=$(get_current_user)
DEFAULT_DEST=$(detect_default_dest "$CURRENT_USER")

if [[ $# -eq 0 ]]; then
    auto_detect_source
    DEST="$DEFAULT_DEST"
elif [[ $# -eq 2 ]]; then
    resolve_explicit_source "$1"
    DEST="$2"
else
    usage
fi

DEST="${DEST%/}"

[[ "$OSTYPE" != darwin* ]] || die "This rootfs transfer workflow requires Linux ext4 support."
[[ -d "$DEST" ]] || die "Destination path does not exist: $DEST"

SOURCE_DEVICE=$(get_mount_source "$SOURCE_MOUNT" 2>/dev/null || true)

for cmd in zip unzip; do
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required but not found."
done

HAS_PV=false
if command -v pv >/dev/null 2>&1; then
    HAS_PV=true
else
    echo "Note: 'pv' not found - no progress bars (apt install pv)."
fi

if [[ -s "$DATA_SRC/hostname" ]]; then
    CAM_HOSTNAME=$(tr -d '[:space:]' < "$DATA_SRC/hostname")
else
    CAM_HOSTNAME="unknown"
    echo "Warning: $DATA_SRC/hostname not found; archive will use 'unknown' in its filename."
fi

echo "Camera: $CAM_HOSTNAME"

IMAGES_DIR="$DATA_SRC/images_and_labels"
DATE_DIRS=()

if [[ -d "$IMAGES_DIR" ]]; then
    while IFS= read -r d; do
        [[ -n "$d" ]] && DATE_DIRS+=("$d")
    done < <(
        find "$IMAGES_DIR" -maxdepth 1 -type d \
            -name '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' \
        | while IFS= read -r p; do basename "$p"; done \
        | sort
    )
fi

DATE_COUNT=${#DATE_DIRS[@]}
TODAY=$(date '+%Y-%m-%d')

if [[ $DATE_COUNT -eq 0 ]]; then
    DATE_SUFFIX="${TODAY}_noimages"
elif [[ $DATE_COUNT -eq 1 ]]; then
    DATE_SUFFIX="${DATE_DIRS[0]}"
else
    LAST_DATE="${DATE_DIRS[$((DATE_COUNT - 1))]}"
    DATE_SUFFIX="${DATE_DIRS[0]}_${LAST_DATE}"
fi

ZIP_NAME="${CAM_HOSTNAME}_${DATE_SUFFIX}.zip"
DEST_ZIP="$DEST/$ZIP_NAME"

echo "Source:   $SOURCE_MOUNT ($SOURCE_KIND)"
echo "Data:     $DATA_SRC"
echo "Archive:  $DEST_ZIP"

if [[ -f "$DEST_ZIP" ]]; then
    read -r -p "File already exists at destination. Overwrite? [y/N] " ow
    case "$ow" in
        [Yy]) ;;
        *) echo "Aborted."; exit 0 ;;
    esac
fi

INCLUDE=()
for item in images_and_labels logs configs hostname update_backups; do
    if [[ -e "$DATA_SRC/$item" ]]; then
        INCLUDE+=("$item")
    else
        echo "Warning: $DATA_SRC/$item not found; skipping."
    fi
done

[[ ${#INCLUDE[@]} -gt 0 ]] || die "No BeeCam data found in $DATA_SRC"

echo "Including: ${INCLUDE[*]}"

echo ""
echo "Disk usage before transfer:"
print_disk_usage "SD card ${SOURCE_KIND}" "$SOURCE_MOUNT"

SRC_KB=$(du -sk "${INCLUDE[@]/#/$DATA_SRC/}" 2>/dev/null | awk '{s+=$1} END {print s}')
DEST_KB=$(df -k "$DEST" | awk 'NR==2 {print $4}')

if [[ $DEST_KB -lt $((SRC_KB / 2)) ]]; then
    echo ""
    echo "Warning: destination may not have enough free space."
    printf "  Source data:       %d MB\n" "$((SRC_KB / 1024))"
    printf "  Destination free:  %d MB\n" "$((DEST_KB / 1024))"
fi

echo ""
echo "Plan:"
echo "  1. Zip ${INCLUDE[*]} -> $DEST_ZIP (store-only, no compression)"
echo "  2. Verify zip integrity"
echo "  3. Delete from SD data dir: images_and_labels/  logs/  update_backups/  .Trash-*/"
echo "  4. Keep in data dir:       configs/  hostname"
echo "  5. Unmount SD card ${SOURCE_KIND} partition"
echo ""
read -r -p "Proceed? [y/N] " confirm
case "$confirm" in
    [Yy]) ;;
    *) echo "Aborted."; exit 0 ;;
esac
echo ""

cd "$DATA_SRC"

if $HAS_PV; then
    TOTAL_BYTES=$(du -sb "${INCLUDE[@]}" 2>/dev/null | awk '{s+=$1} END {print s}')
    echo "Zipping and transferring without compression..."
    zip -0 -r - "${INCLUDE[@]}" \
        -x "*.DS_Store" -x "__MACOSX*" \
        2>/dev/null \
        | pv -s "$TOTAL_BYTES" -N "Progress" \
        > "$DEST_ZIP"
else
    echo "Zipping and transferring without compression (no progress bar)..."
    zip -0 -rq "$DEST_ZIP" "${INCLUDE[@]}" \
        -x "*.DS_Store" -x "__MACOSX*"
fi

echo ""
echo "Verifying zip integrity..."

if $HAS_PV; then
    ENTRY_COUNT=$(unzip -l "$DEST_ZIP" 2>/dev/null | tail -1 | awk '{print $2}')
    unzip -t "$DEST_ZIP" \
        | pv -l -s "$ENTRY_COUNT" -N "Verifying" \
        >/dev/null \
        || die "Zip verification failed - NOT deleting source data."
else
    unzip -t "$DEST_ZIP" >/dev/null 2>&1 \
        || die "Zip verification failed - NOT deleting source data."
fi

echo "Verification passed."
echo ""

echo "Cleaning up SD card data directory..."
print_disk_usage "Before cleanup" "$SOURCE_MOUNT"

for d in images_and_labels logs; do
    if [[ -d "$DATA_SRC/$d" ]]; then
        rm -rf "${DATA_SRC:?}/$d"
        echo "  Cleared: $d/"
    fi
done
mkdir -p "$DATA_SRC/images_and_labels" "$DATA_SRC/logs"

if [[ -d "$DATA_SRC/update_backups" ]]; then
    rm -rf "${DATA_SRC:?}/update_backups"
    echo "  Deleted: update_backups/"
fi

while IFS= read -r trash_dir; do
    rm -rf "$trash_dir"
    echo "  Deleted: $(basename "$trash_dir")/"
done < <(find "$DATA_SRC" -mindepth 1 -maxdepth 1 -type d -name '.Trash-*' -print 2>/dev/null)

for d in images_and_labels logs; do
    if [[ -d "$DATA_SRC/$d" ]]; then
        if ! remaining=$(find "$DATA_SRC/$d" -mindepth 1 -print -quit 2>/dev/null); then
            die "Cleanup verification failed; could not scan $DATA_SRC/$d"
        fi
        [[ -z "$remaining" ]] || die "Cleanup verification failed; still found data under $DATA_SRC/$d"
    fi
done

[[ ! -e "$DATA_SRC/update_backups" ]] || die "Cleanup verification failed; $DATA_SRC/update_backups still exists"
if remaining_trash=$(find "$DATA_SRC" -mindepth 1 -maxdepth 1 -type d -name '.Trash-*' -print -quit 2>/dev/null); then
    [[ -z "$remaining_trash" ]] || die "Cleanup verification failed; still found $remaining_trash"
else
    die "Cleanup verification failed; could not scan for SD card trash directories"
fi

flush_filesystem "$SOURCE_MOUNT"
print_disk_usage "After cleanup" "$SOURCE_MOUNT"

ZIP_MB=$(du -k "$DEST_ZIP" 2>/dev/null | awk '{printf "%.1f", $1/1024}')

unmount_source "$SOURCE_MOUNT" "$SOURCE_DEVICE" "$SOURCE_KIND"

echo ""
echo "Done."
echo "  Archive:    $DEST_ZIP  (${ZIP_MB} MB)"
echo "  Date range: $DATE_SUFFIX"
echo "  Kept:       configs/  hostname  empty images_and_labels/  empty logs/"
echo "  SD card:    ${SOURCE_KIND} partition unmounted"
echo "              Eject the card if any other partitions remain mounted."
