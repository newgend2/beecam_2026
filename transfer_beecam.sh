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
DATA_OWNER=""
SUDO_READY=false
SCRIPT_PATH="${BASH_SOURCE[0]}"
if [[ "$SCRIPT_PATH" != /* ]]; then
    SCRIPT_PATH="$PWD/$SCRIPT_PATH"
fi
ORIGINAL_ARGS=("$@")

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

mount_is_readonly() {
    local path="$1"
    local opts

    if command -v findmnt >/dev/null 2>&1; then
        opts="$(findmnt -n -o OPTIONS --target "$path" 2>/dev/null | sed -n '1p')"
        [[ ",$opts," == *,ro,* ]]
        return
    fi

    return 1
}

require_data_child_path() {
    local path="$1"
    case "$path" in
        "$DATA_SRC"/*) ;;
        *) die "Refusing to delete path outside BeeCam data directory: $path" ;;
    esac
}

set_data_owner() {
    DATA_OWNER="$(stat -c '%u:%g' "$DATA_SRC" 2>/dev/null || true)"
    [[ -n "$DATA_OWNER" ]] || DATA_OWNER="1000:1000"
}

ensure_sudo_ready() {
    if [[ "$(id -u)" -eq 0 ]] || $SUDO_READY; then
        return 0
    fi
    command -v sudo >/dev/null 2>&1 || die "sudo is required to clean root-owned files from this card"
    sudo -v || die "sudo authentication failed; cannot clean root-owned files from this card"
    SUDO_READY=true
}

run_with_privilege() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    else
        ensure_sudo_ready
        sudo "$@"
    fi
}

remount_source_readwrite() {
    echo "Source mount is read-only: $SOURCE_MOUNT"
    echo "Trying to remount it read-write..."

    if run_with_privilege mount -o remount,rw "$SOURCE_MOUNT"; then
        if ! mount_is_readonly "$SOURCE_MOUNT"; then
            echo "Remounted source read-write."
            return 0
        fi
    fi

    return 1
}

ensure_source_writable() {
    mount_is_readonly "$SOURCE_MOUNT" || return 0

    if remount_source_readwrite; then
        return 0
    fi

    die "Could not remount source read-write: $SOURCE_MOUNT. The script must delete transferred data after archiving. Unmount the card and run fsck on the SD partition before retrying; Linux mounted it read-only, often because ext4 detected filesystem errors."
}

maybe_chown_data_path() {
    local path="$1"
    [[ -n "$DATA_OWNER" && -e "$path" ]] || return 0

    if chown "$DATA_OWNER" "$path" 2>/dev/null; then
        return 0
    fi
    if [[ "$(id -u)" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
        sudo -n chown "$DATA_OWNER" "$path" 2>/dev/null || true
    fi
}

maybe_chown_archive() {
    local path="$1"
    [[ -f "$path" ]] || return 0
    if [[ "$(id -u)" -eq 0 && -n "${SUDO_UID:-}" ]]; then
        chown "${SUDO_UID}:${SUDO_GID:-$SUDO_UID}" "$path" 2>/dev/null || true
    fi
}

preflight_cleanup_sudo() {
    if [[ "$SOURCE_KIND" == "rootfs" && -d "$DATA_SRC/update_backups" && "$(id -u)" -ne 0 ]]; then
        echo ""
        echo "Note: this rootfs card has update_backups/, which may contain root-owned files."
        echo "Caching sudo credentials now so cleanup does not stop after the archive is written."
        ensure_sudo_ready
    fi
}

remove_data_path() {
    local path="$1"
    local label="$2"
    local verb="${3:-Deleted}"

    require_data_child_path "$path"
    [[ -e "$path" ]] || return 0

    if rm -rf "$path" 2>/dev/null; then
        echo "  ${verb}: $label"
        return 0
    fi

    echo "  Permission denied deleting ${label}; retrying with sudo..."
    if [[ "$(id -u)" -eq 0 ]]; then
        rm -rf "$path" || die "Could not delete $path"
    else
        ensure_sudo_ready
        sudo rm -rf "$path" || die "Could not delete $path even with sudo"
    fi
    echo "  ${verb}: $label"
}

ensure_empty_data_dir() {
    local path="$1"
    local label="$2"

    require_data_child_path "$path"
    if mkdir -p "$path" 2>/dev/null; then
        maybe_chown_data_path "$path"
        return 0
    fi

    echo "  Permission denied creating ${label}; retrying with sudo..."
    if [[ "$(id -u)" -eq 0 ]]; then
        mkdir -p "$path" || die "Could not create $path"
    else
        ensure_sudo_ready
        sudo mkdir -p "$path" || die "Could not create $path even with sudo"
    fi
    maybe_chown_data_path "$path"
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

    if [[ -n "$device" && "$device" == /dev/* ]] && command -v sudo >/dev/null 2>&1; then
        if run_with_privilege udisksctl unmount -b "$device" >/dev/null 2>&1; then
            return 0
        fi
    fi

    if umount "$path" 2>/dev/null; then
        return 0
    fi

    if [[ -n "$device" && "$device" == /dev/* ]] && umount "$device" 2>/dev/null; then
        return 0
    fi

    if command -v sudo >/dev/null 2>&1 && run_with_privilege umount "$path" 2>/dev/null; then
        return 0
    fi

    if [[ -n "$device" && "$device" == /dev/* ]] && command -v sudo >/dev/null 2>&1 && run_with_privilege umount "$device" 2>/dev/null; then
        return 0
    fi

    return 1
}

power_off_card_device() {
    local parent_disk="$1"

    [[ -n "$parent_disk" && "$parent_disk" == /dev/* ]] || return 0
    command -v udisksctl >/dev/null 2>&1 || return 0

    if udisksctl power-off -b "$parent_disk" >/dev/null 2>&1; then
        echo "  Powered off card device: $parent_disk"
        return 0
    fi

    if command -v sudo >/dev/null 2>&1 && run_with_privilege udisksctl power-off -b "$parent_disk" >/dev/null 2>&1; then
        echo "  Powered off card device: $parent_disk"
        return 0
    fi

    echo "  Warning: could not power off card device $parent_disk; remove it after unmount completes."
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
    local parent_disk entry device mount_path failures unmounted_count parent_known

    echo ""
    echo "Unmounting all mounted SD card partitions..."
    cd /

    failures=()
    unmounted_count=0
    parent_known=false

    if parent_disk="$(get_parent_disk "$source_device")"; then
        parent_known=true
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

    if $parent_known; then
        power_off_card_device "$parent_disk"
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

rerun_with_sudo_for_rootfs_access() {
    local source_path="$1"

    [[ "$(id -u)" -ne 0 ]] || return 0
    [[ -d "${source_path}/home/pi" ]] || return 0
    [[ ! -x "${source_path}/home/pi" || ! -r "${source_path}/home/pi" ]] || return 0

    command -v sudo >/dev/null 2>&1 || die "Rootfs card is mounted, but ${source_path}/home/pi is not readable by this user and sudo is not available."

    echo ""
    echo "Rootfs card found at ${source_path}, but ${source_path}/home/pi is not readable by this user."
    echo "Re-running with sudo so the script can read /home/pi/data and clean root-owned files."
    if [[ ${#ORIGINAL_ARGS[@]} -eq 0 ]]; then
        exec sudo bash "$SCRIPT_PATH" "$source_path" "$DEFAULT_DEST"
    fi
    exec sudo bash "$SCRIPT_PATH" "${ORIGINAL_ARGS[@]}"
}

add_candidate() {
    local kind="$1"
    local mount_path="$2"
    local data_path="$3"
    local candidate existing
    [[ -d "$mount_path" && -d "$data_path" ]] || return 0
    path_is_mountpoint "$mount_path" || return 0
    if [[ "$kind" != "DATA" ]]; then
        path_has_beecam_data "$data_path" || return 0
    fi
    candidate="${kind}|${mount_path}|${data_path}"
    for existing in "${SOURCE_CANDIDATES[@]}"; do
        [[ "$existing" == "$candidate" ]] && return 0
    done
    SOURCE_CANDIDATES+=("$candidate")
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

auto_mount_removable_partitions() {
    local device type removable mountpoint mounted_any

    command -v lsblk >/dev/null 2>&1 || return 0
    command -v udisksctl >/dev/null 2>&1 || return 0

    mounted_any=false
    while read -r device type removable mountpoint; do
        [[ "$type" == "part" && "$removable" == "1" ]] || continue
        [[ -z "${mountpoint:-}" ]] || continue

        echo "Trying to mount removable partition: $device"
        if udisksctl mount -b "$device" >/dev/null 2>&1; then
            mounted_any=true
        else
            echo "  Warning: could not auto-mount $device"
        fi
    done < <(lsblk -nrpo NAME,TYPE,RM,MOUNTPOINT 2>/dev/null)

    if $mounted_any; then
        echo "Auto-mount complete; rescanning BeeCam source candidates..."
    fi
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
    local base path children

    SOURCE_CANDIDATES=()
    for base in "${MEDIA_ROOTS[@]}"; do
        for path in "${base}/DATA" "${base}/data"; do
            add_candidate "DATA" "$path" "$path"
        done
    done
    if choose_candidate "DATA"; then
        return
    fi

    auto_mount_removable_partitions

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
        [[ -d "$base" ]] || continue
        shopt -s nullglob
        children=("${base}"/*)
        shopt -u nullglob
        for path in "${children[@]}"; do
            if path_is_mountpoint "$path"; then
                rerun_with_sudo_for_rootfs_access "$path"
            fi
            add_candidate "rootfs" "$path" "${path}/home/pi/data"
        done
    done
    if choose_candidate "rootfs"; then
        return
    fi

    die "Could not find a mounted BeeCam DATA partition or rootfs. Checked mounted directories under /media/wlab, /media/nate, and /media/field3; expected either DATA or <mount>/home/pi/data with BeeCam data markers."
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

    rerun_with_sudo_for_rootfs_access "$source_path"

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
set_data_owner
ensure_source_writable

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

preflight_cleanup_sudo

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
maybe_chown_archive "$DEST_ZIP"

echo ""
echo "Archive command completed; skipping zip integrity verification."
echo ""

echo "Cleaning up SD card data directory..."
print_disk_usage "Before cleanup" "$SOURCE_MOUNT"

for d in images_and_labels logs; do
    if [[ -d "$DATA_SRC/$d" ]]; then
        remove_data_path "$DATA_SRC/$d" "$d/" "Cleared"
    fi
done
ensure_empty_data_dir "$DATA_SRC/images_and_labels" "images_and_labels/"
ensure_empty_data_dir "$DATA_SRC/logs" "logs/"

if [[ -d "$DATA_SRC/update_backups" ]]; then
    remove_data_path "$DATA_SRC/update_backups" "update_backups/"
fi

while IFS= read -r trash_dir; do
    remove_data_path "$trash_dir" "$(basename "$trash_dir")/"
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
