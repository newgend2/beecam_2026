#!/usr/bin/env bash
# Transfer BeeCam data from SD card to external SSD.
#
# Usage:
#   ./transfer_beecam.sh <sd_data_path> <dest_path>
#
# Arguments:
#   sd_data_path   Mount point of the SD card /data exFAT partition
#   dest_path      Destination directory on the external SSD
#
# Example (Linux):
#   ./transfer_beecam.sh /media/user/DATA /media/user/BackupSSD
# Example (macOS):
#   ./transfer_beecam.sh /Volumes/DATA /Volumes/BackupSSD
#
# Requires: zip
# Optional: pv  (progress bars — apt install pv / brew install pv)

set -euo pipefail

# ── helpers ──────────────────────────────────────────────────────────────────

die() { echo "Error: $*" >&2; exit 1; }

path_is_mountpoint() {
    local path="$1"
    if command -v mountpoint &>/dev/null; then
        mountpoint -q "$path"
        return
    fi

    # Best-effort fallback for systems without mountpoint(1), such as macOS.
    local parent
    parent=$(dirname "$path")
    [[ "$(df -P "$path" 2>/dev/null | awk 'NR==2 {print $1}')" != "$(df -P "$parent" 2>/dev/null | awk 'NR==2 {print $1}')" ]]
}

flush_filesystem() {
    local path="$1"
    echo "Flushing SD card writes..."
    if sync -f "$path" &>/dev/null; then
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
    if command -v findmnt &>/dev/null; then
        findmnt -n -o SOURCE --target "$path" 2>/dev/null | sed -n '1p'
        return
    fi
    df -P "$path" 2>/dev/null | awk 'NR==2 {print $1}'
}

get_partition_parent_device() {
    local device="$1"
    local real_device parent_name

    [[ -n "$device" && "$device" == /dev/* ]] || return 1

    if command -v readlink &>/dev/null; then
        real_device=$(readlink -f "$device" 2>/dev/null || true)
    fi
    real_device=${real_device:-$device}

    if command -v lsblk &>/dev/null; then
        parent_name=$(lsblk -no PKNAME "$real_device" 2>/dev/null | sed -n '1p')
        if [[ -n "$parent_name" ]]; then
            printf '/dev/%s\n' "$parent_name"
            return 0
        fi
    fi

    return 1
}

get_darwin_whole_disk() {
    local device="$1"
    local whole_disk

    [[ -n "$device" ]] || return 1

    whole_disk=$(diskutil info "$device" 2>/dev/null | awk -F': *' '/Part of Whole/ {print $2; exit}')
    if [[ -n "$whole_disk" ]]; then
        printf '/dev/%s\n' "$whole_disk"
        return 0
    fi

    return 1
}

try_unmount() {
    local path="$1"
    local device="$2"

    if [[ "$OSTYPE" == darwin* ]]; then
        if [[ -n "$path" ]] && diskutil unmount "$path" >/dev/null; then
            return 0
        fi
        if [[ -n "$device" ]] && diskutil unmount "$device" >/dev/null; then
            return 0
        fi
        return 1
    fi

    if [[ -n "$device" && "$device" == /dev/* ]] && command -v udisksctl &>/dev/null; then
        if udisksctl unmount -b "$device" >/dev/null 2>&1; then
            return 0
        fi
    fi

    if [[ -n "$path" ]] && umount "$path" 2>/dev/null; then
        return 0
    fi

    if [[ -n "$device" && "$device" == /dev/* ]] && umount "$device" 2>/dev/null; then
        return 0
    fi

    if command -v sudo &>/dev/null; then
        if [[ -n "$path" ]] && sudo -n umount "$path" 2>/dev/null; then
            return 0
        fi
        if [[ -n "$device" && "$device" == /dev/* ]] && sudo -n umount "$device" 2>/dev/null; then
            return 0
        fi
    fi

    return 1
}

unmount_source() {
    local path="$1"
    local device="$2"

    echo ""
    echo "Unmounting SD card DATA partition..."

    # The script zipped from inside $SRC, so leave the mount before unmounting it.
    cd /

    if try_unmount "$path" "$device"; then
        echo "  Unmounted: $path"
        return
    fi

    die "Could not unmount $path without prompting. Close any windows or terminals using the SD card, then unmount it manually."
}

unmount_related_sd_partitions() {
    local data_device="$1"
    local parent_device found failed part label target

    if [[ "$OSTYPE" == darwin* ]]; then
        echo ""
        echo "Unmounting other SD card partitions..."
        parent_device=$(get_darwin_whole_disk "$data_device" 2>/dev/null || true)
        if [[ -z "$parent_device" ]]; then
            die "Could not identify the SD card disk for rootfs/bootfs auto-unmount. Archive and cleanup completed, but eject any remaining SD-card partitions manually."
        fi
        if diskutil unmountDisk "$parent_device" >/dev/null; then
            echo "  Unmounted all mountable partitions on: $parent_device"
            return
        fi
        die "Could not unmount all SD card partitions. Close windows/terminals using the SD card, then eject it manually."
    fi

    if ! command -v lsblk &>/dev/null; then
        die "Could not auto-unmount rootfs/bootfs partitions because lsblk is not available. Archive and cleanup completed, but eject any remaining SD-card partitions manually."
    fi

    parent_device=$(get_partition_parent_device "$data_device" 2>/dev/null || true)
    if [[ -z "$parent_device" ]]; then
        die "Could not identify the SD card parent disk for rootfs/bootfs auto-unmount. Archive and cleanup completed, but eject any remaining SD-card partitions manually."
    fi

    found=false
    failed=false

    echo ""
    echo "Unmounting SD card rootfs/bootfs partitions..."

    while read -r part label target; do
        case "$label" in
            rootfs|bootfs) ;;
            *) continue ;;
        esac

        [[ -n "${target:-}" ]] || continue

        found=true
        if try_unmount "$target" "$part"; then
            echo "  Unmounted: $label ($target)"
        else
            echo "  Could not unmount: $label ($target)"
            failed=true
        fi
    done < <(lsblk -nrpo NAME,LABEL,MOUNTPOINT "$parent_device" 2>/dev/null)

    if ! $found; then
        echo "  No mounted rootfs/bootfs partitions found."
    fi

    if $failed; then
        die "Could not unmount all SD card partitions. Close any windows or terminals using the SD card, then eject it manually."
    fi
}

get_current_hostname() {
    local h
    h=$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'unknown')
    h=${h%%.*}
    h=${h//[[:space:]]/}
    [[ -n "$h" ]] || h="unknown"
    printf '%s\n' "$h"
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

usage() {
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

# ── arguments ────────────────────────────────────────────────────────────────

CURRENT_USER=$(get_current_user)
DEFAULT_SRC="/media/${CURRENT_USER}/DATA"
DEFAULT_DEST="/media/${CURRENT_USER}/T7 Shield"

if [[ $# -eq 0 ]]; then
    SRC="$DEFAULT_SRC"
    DEST="$DEFAULT_DEST"
elif [[ $# -eq 2 ]]; then
    SRC="$1"
    DEST="$2"
else
    usage
fi

SRC="${SRC%/}"   # strip trailing slash
DEST="${DEST%/}"

[[ -d "$SRC" ]]  || die "Source path does not exist: $SRC"
[[ -d "$DEST" ]] || die "Destination path does not exist: $DEST"

if [[ "$OSTYPE" != darwin* ]] && ! path_is_mountpoint "$SRC"; then
    die "Source path exists but is not a mounted filesystem: $SRC. Reinsert/eject the SD card and make sure the DATA partition is mounted."
fi

SRC_DEVICE=$(get_mount_source "$SRC" 2>/dev/null || true)

# ── dependency checks ─────────────────────────────────────────────────────────

for cmd in zip; do
    command -v "$cmd" &>/dev/null || die "'$cmd' is required but not found."
done

HAS_PV=false
if command -v pv &>/dev/null; then
    HAS_PV=true
else
    echo "Note: 'pv' not found — no progress bars (apt install pv / brew install pv)."
fi

# ── read camera hostname ──────────────────────────────────────────────────────

CURRENT_HOSTNAME=$(get_current_hostname)

if [[ -s "$SRC/hostname" ]]; then
    CAM_HOSTNAME=$(tr -d '[:space:]' < "$SRC/hostname")
else
    CAM_HOSTNAME="$CURRENT_HOSTNAME"
    if printf '%s\n' "$CAM_HOSTNAME" > "$SRC/hostname"; then
        echo "Wrote current hostname to $SRC/hostname."
    else
        echo "Warning: could not write $SRC/hostname; archive will use current hostname in its filename."
    fi
fi

echo "Camera: $CAM_HOSTNAME"

# ── determine zip filename from date range in images_and_labels ───────────────

IMAGES_DIR="$SRC/images_and_labels"
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

if   [[ $DATE_COUNT -eq 0 ]]; then
    DATE_SUFFIX="${TODAY}_noimages"
elif [[ $DATE_COUNT -eq 1 ]]; then
    DATE_SUFFIX="${DATE_DIRS[0]}"
else
    LAST_DATE="${DATE_DIRS[$((DATE_COUNT - 1))]}"
    DATE_SUFFIX="${DATE_DIRS[0]}_${LAST_DATE}"
fi

ZIP_NAME="${CAM_HOSTNAME}_${DATE_SUFFIX}.zip"
DEST_ZIP="$DEST/$ZIP_NAME"

echo "Archive:  $DEST_ZIP"

# ── check for conflicts ───────────────────────────────────────────────────────

if [[ -f "$DEST_ZIP" ]]; then
    read -r -p "File already exists at destination. Overwrite? [y/N] " ow
    case "$ow" in
        [Yy]) ;;
        *) echo "Aborted."; exit 0 ;;
    esac
fi

# ── collect source data to include ────────────────────────────────────────────

INCLUDE=()
for item in images_and_labels logs configs hostname update_backups; do
    if [[ -e "$SRC/$item" ]]; then
        INCLUDE+=("$item")
    else
        echo "Warning: $SRC/$item not found; skipping."
    fi
done

[[ ${#INCLUDE[@]} -gt 0 ]] || die "No source data found in $SRC"

echo "Including: ${INCLUDE[*]}"

echo ""
echo "Disk usage before transfer:"
print_disk_usage "SD card DATA" "$SRC"

# ── advisory space check ──────────────────────────────────────────────────────

if [[ "$OSTYPE" == darwin* ]]; then
    SRC_KB=$(du -sk "${INCLUDE[@]/#/$SRC/}" 2>/dev/null | awk '{s+=$1} END {print s}')
else
    SRC_KB=$(du -sk "${INCLUDE[@]/#/$SRC/}" 2>/dev/null | awk '{s+=$1} END {print s}')
fi
DEST_KB=$(df -k "$DEST" | awk 'NR==2 {print $4}')

if [[ $DEST_KB -lt $((SRC_KB / 2)) ]]; then
    echo ""
    echo "Warning: destination may not have enough free space."
    printf  "  Source data:       %d MB\n" "$((SRC_KB  / 1024))"
    printf  "  Destination free:  %d MB\n" "$((DEST_KB / 1024))"
fi

# ── confirm ───────────────────────────────────────────────────────────────────

echo ""
echo "Plan:"
echo "  1. Zip ${INCLUDE[*]} → $DEST_ZIP (store-only, no compression)"
echo "  2. Skip zip integrity verification"
echo "  3. Delete from SD:   images_and_labels/  logs/  update_backups/  .Trash-*/"
echo "  4. Keep on SD:       configs/  hostname"
echo "  5. Unmount SD card DATA/rootfs/bootfs partitions"
echo ""
read -r -p "Proceed? [y/N] " confirm
case "$confirm" in
    [Yy]) ;;
    *) echo "Aborted."; exit 0 ;;
esac
echo ""

# ── zip directly to destination ───────────────────────────────────────────────

cd "$SRC"

if $HAS_PV; then
    # Estimate uncompressed byte total for pv -s
    if [[ "$OSTYPE" == darwin* ]]; then
        TOTAL_BYTES=$(du -sk "${INCLUDE[@]}" 2>/dev/null | awk '{s+=$1} END {print s * 1024}')
    else
        TOTAL_BYTES=$(du -sb "${INCLUDE[@]}" 2>/dev/null | awk '{s+=$1} END {print s}')
    fi
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

echo "Zip completed; skipping zip integrity verification."
echo ""

# ── delete transferred data from SD ──────────────────────────────────────────

echo "Cleaning up SD card..."
print_disk_usage "Before cleanup" "$SRC"

for d in images_and_labels logs; do
    if [[ -d "$SRC/$d" ]]; then
        rm -rf "${SRC:?}/$d"
        mkdir -p "$SRC/$d"
        echo "  Cleared: $d/"
    fi
done

if [[ -d "$SRC/update_backups" ]]; then
    rm -rf "${SRC:?}/update_backups"
    echo "  Deleted: update_backups/"
fi

while IFS= read -r trash_dir; do
    rm -rf "$trash_dir"
    echo "  Deleted: $(basename "$trash_dir")/"
done < <(find "$SRC" -mindepth 1 -maxdepth 1 -type d -name '.Trash-*' -print 2>/dev/null)

for d in images_and_labels logs; do
    if [[ -d "$SRC/$d" ]]; then
        if ! remaining=$(find "$SRC/$d" -mindepth 1 -print -quit 2>/dev/null); then
            die "Cleanup verification failed; could not scan $SRC/$d"
        fi
        [[ -z "$remaining" ]] || die "Cleanup verification failed; still found data under $SRC/$d"
    fi
done
[[ ! -e "$SRC/update_backups" ]] || die "Cleanup verification failed; $SRC/update_backups still exists"
if remaining_trash=$(find "$SRC" -mindepth 1 -maxdepth 1 -type d -name '.Trash-*' -print -quit 2>/dev/null); then
    [[ -z "$remaining_trash" ]] || die "Cleanup verification failed; still found $remaining_trash"
else
    die "Cleanup verification failed; could not scan for SD card trash directories"
fi

flush_filesystem "$SRC"
print_disk_usage "After cleanup" "$SRC"

# ── summary ───────────────────────────────────────────────────────────────────

ZIP_MB=$(du -k "$DEST_ZIP" 2>/dev/null | awk '{printf "%.1f", $1/1024}')

unmount_source "$SRC" "$SRC_DEVICE"
unmount_related_sd_partitions "$SRC_DEVICE"

echo ""
echo "Done."
echo "  Archive:    $DEST_ZIP  (${ZIP_MB} MB)"
echo "  Date range: $DATE_SUFFIX"
echo "  Kept on SD: configs/  hostname  empty images_and_labels/  empty logs/"
echo "  SD card:    DATA/rootfs/bootfs partitions unmounted when mounted and detectable"
echo "  Safe next step: remove the SD card."
