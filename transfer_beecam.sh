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
# Requires: zip
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

unmount_one_mount() {
    local path="$1"
    local device="$2"

    if [[ -n "$device" && "$device" == /dev/* ]] && command -v udisksctl >/dev/null 2>&1; then
        if udisksctl unmount -b "$device" >/dev/null 2>&1; then
            return 0
        fi
    fi

    if umount "$path" 2>/dev/null; then
        return 0
    fi

    if [[ -n "$device" && "$device" == /dev/* ]] && umount "$device" 2>/dev/null; then
        return 0
    fi

    if command -v sudo >/dev/null 2>&1 && sudo -n umount "$path" 2>/dev/null; then
        return 0
    fi

    if [[ -n "$device" && "$device" == /dev/* ]] && command -v sudo >/dev/null 2>&1 && sudo -n umount "$device" 2>/dev/null; then
        return 0
    fi

    return 1
}

get_parent_disk() {
    local device="$1"
    local parent type

    [[ -n "$device" && "$device" == /dev/* ]] || return 1
    command -v lsblk >/dev/null 2>&1 || return 1

    type="$(lsblk -no TYPE "$device" 2>/dev/null | sed -n '1p')"
    [[ -n "$type" ]] || return 1
    if [[ "$type" == "disk" ]]; then
        printf '%s\n' "$device"
        return 0
    fi

    parent="$(lsblk -no PKNAME "$device" 2>/dev/null | sed -n '1p')"
    [[ -n "$parent" ]] || return 1
    printf '/dev/%s\n' "$parent"
}

list_mount_targets_for_device() {
    local device="$1"

    if command -v findmnt >/dev/null 2>&1; then
        findmnt -rn -S "$device" -o TARGET 2>/dev/null
        return
    fi

    awk -v dev="$device" '$1 == dev { print $2 }' /proc/mounts 2>/dev/null \
        | sed 's/\\040/ /g; s/\\011/\t/g; s/\\134/\\/g'
}

collect_card_mounts() {
    local parent_disk="$1"
    local device type mount_path

    CARD_MOUNT_ENTRIES=()
    while read -r device type; do
        [[ "$type" == "part" ]] || continue
        while IFS= read -r mount_path; do
            [[ -n "$mount_path" ]] || continue
            CARD_MOUNT_ENTRIES+=("${device}|${mount_path}")
        done < <(list_mount_targets_for_device "$device" || true)
    done < <(lsblk -nrpo NAME,TYPE "$parent_disk" 2>/dev/null)
}

unmount_card_partitions() {
    local source_path="$1"
    local source_device="$2"
    local source_label="$3"
    local parent_disk entry device mount_path failures unmounted_count

    echo ""
    echo "Unmounting all mounted SD card partitions..."
    cd /

    failures=()
    unmounted_count=0

    if parent_disk="$(get_parent_disk "$source_device")"; then
        echo "  Card device: $parent_disk"
        collect_card_mounts "$parent_disk"
    else
        echo "  Warning: could not determine sibling partitions for ${source_device:-$source_path}; unmounting only ${source_label}."
        CARD_MOUNT_ENTRIES=("${source_device}|${source_path}")
    fi

    if [[ ${#CARD_MOUNT_ENTRIES[@]} -eq 0 ]]; then
        echo "  No mounted SD card partitions found."
        return 0
    fi

    for entry in "${CARD_MOUNT_ENTRIES[@]}"; do
        IFS='|' read -r device mount_path <<< "$entry"
        if [[ -n "$mount_path" ]] && ! path_is_mountpoint "$mount_path"; then
            echo "  Already unmounted: $mount_path"
            continue
        fi

        if unmount_one_mount "$mount_path" "$device"; then
            if [[ -n "$device" ]]; then
                echo "  Unmounted: $mount_path ($device)"
            else
                echo "  Unmounted: $mount_path"
            fi
            unmounted_count=$((unmounted_count + 1))
        else
            failures+=("${mount_path:-$device}")
        fi
    done

    if [[ ${#failures[@]} -gt 0 ]]; then
        echo "  Failed to unmount:" >&2
        printf '    %s\n' "${failures[@]}" >&2
        die "Could not unmount all SD card partitions without prompting. Close any windows or terminals using the SD card, then unmount it manually."
    fi

    if [[ "$unmounted_count" -eq 0 ]]; then
        echo "  No partitions needed unmounting."
    fi
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

for cmd in zip; do
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
echo "  2. Delete from SD data dir after zip completes: images_and_labels/  logs/  update_backups/  .Trash-*/"
echo "  3. Keep in data dir:                      configs/  hostname"
echo "  4. Unmount all mounted SD card partitions: bootfs/rootfs/DATA if present"
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
echo "Archive command completed; skipping zip integrity verification."
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

unmount_card_partitions "$SOURCE_MOUNT" "$SOURCE_DEVICE" "$SOURCE_KIND"

echo ""
echo "Done."
echo "  Archive:    $DEST_ZIP  (${ZIP_MB} MB)"
echo "  Date range: $DATE_SUFFIX"
echo "  Kept:       configs/  hostname  empty images_and_labels/  empty logs/"
echo "  SD card:    mounted partitions unmounted"
