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
# Requires: zip, unzip
# Optional: pv  (progress bars — apt install pv / brew install pv)

set -euo pipefail

# ── helpers ──────────────────────────────────────────────────────────────────

die() { echo "Error: $*" >&2; exit 1; }

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

# ── dependency checks ─────────────────────────────────────────────────────────

for cmd in zip unzip; do
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
for item in images_and_labels logs configs hostname; do
    if [[ -e "$SRC/$item" ]]; then
        INCLUDE+=("$item")
    else
        echo "Warning: $SRC/$item not found; skipping."
    fi
done

[[ ${#INCLUDE[@]} -gt 0 ]] || die "No source data found in $SRC"

echo "Including: ${INCLUDE[*]}"

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
echo "  1. Zip ${INCLUDE[*]} → $DEST_ZIP"
echo "  2. Verify zip integrity"
echo "  3. Delete from SD:   images_and_labels/  logs/"
echo "  4. Keep on SD:       configs/  hostname"
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
    echo "Zipping and transferring..."
    zip -r - "${INCLUDE[@]}" \
        -x "*.DS_Store" -x "__MACOSX*" \
        2>/dev/null \
        | pv -s "$TOTAL_BYTES" -N "Progress" \
        > "$DEST_ZIP"
else
    echo "Zipping and transferring (no progress bar)..."
    zip -rq "$DEST_ZIP" "${INCLUDE[@]}" \
        -x "*.DS_Store" -x "__MACOSX*"
fi

echo ""

# ── verify ────────────────────────────────────────────────────────────────────

echo "Verifying zip integrity..."

if $HAS_PV; then
    ENTRY_COUNT=$(unzip -l "$DEST_ZIP" 2>/dev/null | tail -1 | awk '{print $2}')
    unzip -t "$DEST_ZIP" \
        | pv -l -s "$ENTRY_COUNT" -N "Verifying" \
        > /dev/null \
        || die "Zip verification failed — NOT deleting source data."
else
    unzip -t "$DEST_ZIP" > /dev/null 2>&1 \
        || die "Zip verification failed — NOT deleting source data."
fi

echo "Verification passed."
echo ""

# ── delete transferred data from SD ──────────────────────────────────────────

echo "Cleaning up SD card..."
for d in images_and_labels logs; do
    if [[ -d "$SRC/$d" ]]; then
        rm -rf "${SRC:?}/$d"
        echo "  Deleted: $d/"
    fi
done

# ── summary ───────────────────────────────────────────────────────────────────

ZIP_MB=$(du -k "$DEST_ZIP" 2>/dev/null | awk '{printf "%.1f", $1/1024}')

echo ""
echo "Done."
echo "  Archive:    $DEST_ZIP  (${ZIP_MB} MB)"
echo "  Date range: $DATE_SUFFIX"
echo "  Kept on SD: configs/  hostname"
