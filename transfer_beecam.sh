#!/usr/bin/env bash
# Transfer BeeCam data from an SD card rootfs or DATA mount to external storage.
#
# Zips images_and_labels/ logs/ configs/ hostname update_backups/ (store-only, zip -0) to
# <dest>/<hostname>_<first-date>_<last-date>_<YYYY-MM-DD-HH-MM-SS>.zip, then verifies it:
# unzip -t, plus the zip's file count and total bytes against the card (<zip>.verify.txt).
# Only after verification passes is the card's transferred data cleared (images_and_labels/ and
# logs/ emptied, update_backups/ and .Trash-*/ removed; configs/ and hostname kept), flushed,
# and the card's partitions unmounted and powered off. A failed verification leaves the card
# untouched and mounted.
#
# Usage:
#   ./transfer_beecam.sh [options] [mounted_source_path] [dest_path]
#
# Options:
#   --dest DIR         destination directory (or give it as the second positional argument).
#                      Without one, mounted drives under /media/<user> are listed with free
#                      space to pick from (interactive terminals only).
#   --no-clear         copy and verify only; never clear the card
#   --skip-unreadable  for a failing card: leave out files that cannot be listed or read, list
#                      them in <zip>.unreadable.txt, verify the rest; never clears the card
#   --yes              do not ask for confirmation
#
# Examples:
#   sudo ./transfer_beecam.sh                                     # auto-detect card, pick a drive
#   sudo ./transfer_beecam.sh --dest /media/nate/Expansion/beecam_data_2026/california_cams
#   sudo ./transfer_beecam.sh /media/nate/rootfs /media/nate/BackupSSD
#
# Refuses to write to the card itself, to /mnt/nas*, or to the reviewed-images drive "T7 Shield".
# Requires: zip, unzip, python3, udisksctl

set -euo pipefail

die() { echo "Error: $*" >&2; exit 1; }

MEDIA_ROOTS=(/media/wlab /media/nate /media/field3)
SCRIPT_PATH="${BASH_SOURCE[0]}"
[[ "$SCRIPT_PATH" == /* ]] || SCRIPT_PATH="$PWD/$SCRIPT_PATH"
ORIGINAL_ARGS=("$@")

# Destinations never written to: the NAS, and the drive holding reviewed images.
dest_forbidden() {
    local target="$1"
    case "$target" in
        /mnt/nas*) echo "the NAS"; return 0 ;;
        /media/*/"T7 Shield") echo "the reviewed-images drive (T7 Shield)"; return 0 ;;
    esac
    return 1
}

path_is_mountpoint() {
    mountpoint -q "$1"
}

get_mount_source() {
    findmnt -n -o SOURCE --target "$1" 2>/dev/null | sed -n '1p'
}

get_mount_target() {
    findmnt -n -o TARGET --target "$1" 2>/dev/null | sed -n '1p'
}

path_has_beecam_data() {
    local path="$1"
    [[ -d "$path" ]] || return 1
    [[ -e "$path/images_and_labels" || -e "$path/logs" || -e "$path/configs" || -e "$path/hostname" ]]
}

check_rootfs_readable() {
    local source_path="$1"
    [[ "$(id -u)" -ne 0 ]] || return 0
    [[ -d "${source_path}/home/pi" ]] || return 0
    [[ ! -x "${source_path}/home/pi" || ! -r "${source_path}/home/pi" ]] || return 0
    command -v sudo >/dev/null 2>&1 || die "${source_path}/home/pi is not readable by this user and sudo is not available."
    echo "Rootfs card found at ${source_path}, but ${source_path}/home/pi is not readable; re-running with sudo."
    exec sudo bash "$SCRIPT_PATH" "${ORIGINAL_ARGS[@]}"
}

add_candidate() {
    local kind="$1" mount_path="$2" data_path="$3" candidate existing
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

choose_candidate() {
    local kind="$1" count="${#SOURCE_CANDIDATES[@]}" candidate
    [[ "$count" -gt 0 ]] || return 1
    if [[ "$count" -gt 1 ]]; then
        echo "Found multiple mounted BeeCam ${kind} candidates:" >&2
        for candidate in "${SOURCE_CANDIDATES[@]}"; do
            IFS='|' read -r _kind mount_path data_path <<< "$candidate"
            echo "  ${mount_path} -> ${data_path}" >&2
        done
        die "Pass the intended source mount path explicitly."
    fi
    IFS='|' read -r SOURCE_KIND SOURCE_MOUNT DATA_SRC <<< "${SOURCE_CANDIDATES[0]}"
}

auto_mount_removable_partitions() {
    local device type removable mountpoint
    command -v udisksctl >/dev/null 2>&1 || return 0
    while read -r device type removable mountpoint; do
        [[ "$type" == "part" && "$removable" == "1" && -z "${mountpoint:-}" ]] || continue
        echo "Trying to mount removable partition: $device"
        udisksctl mount -b "$device" >/dev/null 2>&1 || echo "  Warning: could not auto-mount $device"
    done < <(lsblk -nrpo NAME,TYPE,RM,MOUNTPOINT 2>/dev/null)
}

auto_detect_source() {
    local base path children
    SOURCE_CANDIDATES=()
    for base in "${MEDIA_ROOTS[@]}"; do
        for path in "${base}/DATA" "${base}/data"; do
            add_candidate "DATA" "$path" "$path"
        done
    done
    choose_candidate "DATA" && return
    auto_mount_removable_partitions
    SOURCE_CANDIDATES=()
    for base in "${MEDIA_ROOTS[@]}"; do
        for path in "${base}/DATA" "${base}/data"; do
            add_candidate "DATA" "$path" "$path"
        done
    done
    choose_candidate "DATA" && return

    SOURCE_CANDIDATES=()
    for base in "${MEDIA_ROOTS[@]}"; do
        [[ -d "$base" ]] || continue
        shopt -s nullglob
        children=("${base}"/*)
        shopt -u nullglob
        for path in "${children[@]}"; do
            path_is_mountpoint "$path" && check_rootfs_readable "$path"
            add_candidate "rootfs" "$path" "${path}/home/pi/data"
        done
    done
    choose_candidate "rootfs" && return

    die "Could not find a mounted BeeCam DATA partition or rootfs under ${MEDIA_ROOTS[*]}."
}

resolve_explicit_source() {
    local source_path="${1%/}" source_name
    source_name="$(basename "$source_path")"
    [[ "$source_path" != "/" && -n "$source_path" ]] || die "Refusing to use / as the mounted SD source path."
    [[ -d "$source_path" ]] || die "Mounted source path does not exist: $source_path"
    path_is_mountpoint "$source_path" || die "Source path is not a mounted filesystem: $source_path"

    if [[ "$source_name" == "DATA" || "$source_name" == "data" ]] || path_has_beecam_data "$source_path"; then
        SOURCE_KIND="DATA"; SOURCE_MOUNT="$source_path"; DATA_SRC="$source_path"
        return
    fi
    check_rootfs_readable "$source_path"
    if [[ -d "${source_path}/home/pi/data" ]]; then
        SOURCE_KIND="rootfs"; SOURCE_MOUNT="$source_path"; DATA_SRC="${source_path}/home/pi/data"
        return
    fi
    die "Mounted source does not contain BeeCam data. Checked ${source_path} and ${source_path}/home/pi/data."
}

get_parent_disk() {
    local device="$1" parent type
    [[ -n "$device" && "$device" == /dev/* ]] || return 1
    type="$(lsblk -no TYPE "$device" 2>/dev/null | sed -n '1p')"
    [[ -n "$type" ]] || return 1
    if [[ "$type" == "disk" || "$type" == "loop" ]]; then printf '%s\n' "$device"; return 0; fi
    parent="$(lsblk -no PKNAME "$device" 2>/dev/null | sed -n '1p')"
    [[ -n "$parent" ]] || return 1
    printf '/dev/%s\n' "$parent"
}

unmount_and_power_off_card() {
    local parent_disk="$1" device type mp failures=()
    echo ""
    echo "Unmounting all mounted partitions of $parent_disk..."
    cd /
    while read -r device type; do  # the card and its partitions (a filesystem may sit on the whole device)
        while IFS= read -r mp; do
            [[ -n "$mp" ]] || continue
            if udisksctl unmount -b "$device" >/dev/null 2>&1 || umount "$mp" 2>/dev/null; then
                echo "  Unmounted: $mp ($device)"
            else
                failures+=("$mp")
            fi
        done < <(findmnt -rn -S "$device" -o TARGET 2>/dev/null || true)
    done < <(lsblk -nrpo NAME,TYPE "$parent_disk" 2>/dev/null)

    [[ ${#failures[@]} -eq 0 ]] || die "Could not unmount: ${failures[*]}. Card left as is; close anything using it and unmount manually."

    if udisksctl power-off -b "$parent_disk" >/dev/null 2>&1; then
        echo "  Powered off card device: $parent_disk"
    else
        echo "  Warning: could not power off $parent_disk; it is unmounted and safe to remove."
    fi
}

mount_is_readonly() {
    local opts
    opts="$(findmnt -n -o OPTIONS --target "$1" 2>/dev/null | sed -n '1p')"
    [[ ",$opts," == *,ro,* ]]
}

require_data_child_path() {
    case "$1" in
        "$DATA_SRC"/?*) ;;
        *) die "Refusing to delete path outside BeeCam data directory: $1" ;;
    esac
}

# Called only after verification passes.
clear_card_data() {
    local owner d trash_dir remaining
    echo ""
    echo "Verification passed; clearing transferred data from the SD card..."
    df -h "$SOURCE_MOUNT" | awk 'NR==2 {printf "  Before cleanup: %s used of %s (%s)\n", $3, $2, $5}'

    if mount_is_readonly "$SOURCE_MOUNT"; then
        echo "  Source is mounted read-only; trying remount rw..."
        { mount -o remount,rw "$SOURCE_MOUNT" && ! mount_is_readonly "$SOURCE_MOUNT"; } \
            || die "Could not remount $SOURCE_MOUNT read-write. Archive is verified; card NOT cleared and left mounted. Check the card before any fsck."
    fi

    owner="$(stat -c '%u:%g' "$DATA_SRC" 2>/dev/null || echo 1000:1000)"
    for d in images_and_labels logs; do
        if [[ -d "$DATA_SRC/$d" ]]; then
            require_data_child_path "$DATA_SRC/$d"
            rm -rf "${DATA_SRC:?}/$d" || die "Could not delete $DATA_SRC/$d"
            echo "  Cleared: $d/"
        fi
        mkdir -p "$DATA_SRC/$d" || die "Could not recreate $DATA_SRC/$d"
        chown "$owner" "$DATA_SRC/$d" 2>/dev/null || true
    done
    if [[ -d "$DATA_SRC/update_backups" ]]; then
        require_data_child_path "$DATA_SRC/update_backups"
        rm -rf "${DATA_SRC:?}/update_backups" || die "Could not delete $DATA_SRC/update_backups"
        echo "  Deleted: update_backups/"
    fi
    while IFS= read -r trash_dir; do
        require_data_child_path "$trash_dir"
        rm -rf "$trash_dir" || die "Could not delete $trash_dir"
        echo "  Deleted: $(basename "$trash_dir")/"
    done < <(find "$DATA_SRC" -mindepth 1 -maxdepth 1 -type d -name '.Trash-*' -print)

    for d in images_and_labels logs; do
        remaining=$(find "$DATA_SRC/$d" -mindepth 1 -print -quit) || die "Cleanup check failed; could not scan $DATA_SRC/$d"
        [[ -z "$remaining" ]] || die "Cleanup check failed; data still under $DATA_SRC/$d"
    done
    [[ ! -e "$DATA_SRC/update_backups" ]] || die "Cleanup check failed; update_backups still exists"
    remaining=$(find "$DATA_SRC" -mindepth 1 -maxdepth 1 -type d -name '.Trash-*' -print -quit)
    [[ -z "$remaining" ]] || die "Cleanup check failed; found $remaining"
    [[ -e "$DATA_SRC/configs" && -e "$DATA_SRC/hostname" ]] || echo "  Warning: configs/ or hostname missing (they were not touched)."

    echo "  Flushing SD card writes..."
    sync -f "$SOURCE_MOUNT" 2>/dev/null || sync
    df -h "$SOURCE_MOUNT" | awk 'NR==2 {printf "  After cleanup: %s used of %s (%s)\n", $3, $2, $5}'
    echo "card_cleared: yes ($(date '+%F %T'))" >> "$VERIFY_TXT"
}

CLEAR_AFTER_VERIFY=true
SKIP_UNREADABLE=false
ASSUME_YES=false
DEST=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dest) [[ $# -ge 2 ]] || die "--dest needs a directory"; DEST="$2"; shift ;;
        --dest=*) DEST="${1#--dest=}" ;;
        --no-clear) CLEAR_AFTER_VERIFY=false ;;
        --clear-after-verify) ;;  # the default; accepted for older command lines
        --skip-unreadable) SKIP_UNREADABLE=true; CLEAR_AFTER_VERIFY=false ;;
        --yes|-y) ASSUME_YES=true ;;
        -h|--help) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --*) die "Unknown option: $1" ;;
        *) POSITIONAL+=("$1") ;;
    esac
    shift
done
case ${#POSITIONAL[@]} in
    0) auto_detect_source ;;
    1) resolve_explicit_source "${POSITIONAL[0]}" ;;
    2) resolve_explicit_source "${POSITIONAL[0]}"
       [[ -z "$DEST" || "$DEST" == "${POSITIONAL[1]}" ]] || die "Destination given twice: --dest $DEST and ${POSITIONAL[1]}"
       DEST="${POSITIONAL[1]}" ;;
    *) die "Too many arguments; see --help" ;;
esac

SOURCE_DEVICE=$(get_mount_source "$SOURCE_MOUNT")
CARD_DISK=$(get_parent_disk "$SOURCE_DEVICE") || die "Could not determine the card device for $SOURCE_MOUNT"

choose_destination() {
    local user base mp disk avail n=0 choice candidates=()
    user="${SUDO_USER:-${USER:-$(id -un)}}"
    for base in "/media/$user" "${MEDIA_ROOTS[@]}"; do
        [[ -d "$base" ]] || continue
        while IFS= read -r mp; do
            [[ -n "$mp" && "$mp" == "$base"/* ]] || continue
            disk="$(get_parent_disk "$(get_mount_source "$mp")" || true)"
            [[ "$disk" == "$CARD_DISK" ]] && continue
            [[ -n "$disk" && "$(lsblk -dno RM "$disk" 2>/dev/null | tr -d ' ')" == "1" ]] && continue  # other SD cards
            dest_forbidden "$mp" >/dev/null && continue
            [[ " ${candidates[*]} " == *" $mp "* ]] && continue
            candidates+=("$mp")
        done < <(findmnt -rn -o TARGET | sed 's/\\x20/ /g')
    done
    [[ ${#candidates[@]} -gt 0 ]] || die "No mounted destination drives found under /media; pass --dest DIR"
    [[ -t 0 ]] || die "No destination given and no terminal to choose one; pass --dest DIR"
    echo "Destination drives:"
    for mp in "${candidates[@]}"; do
        n=$((n + 1))
        avail=$(df -h --output=avail "$mp" | tail -1 | tr -d ' ')
        printf "  %d) %s  (%s free)\n" "$n" "$mp" "$avail"
    done
    read -r -p "Pick a drive [1-$n]: " choice
    [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le $n ]] || die "No drive chosen"
    DEST="${candidates[$((choice - 1))]}"
    read -r -p "Folder on that drive (blank for the drive root): " choice
    if [[ -n "$choice" ]]; then
        DEST="$DEST/${choice#/}"
        mkdir -p "$DEST" || die "Could not create $DEST"
    fi
}
[[ -n "$DEST" ]] || choose_destination

DEST="${DEST%/}"
[[ -d "$DEST" ]] || die "Destination path does not exist: $DEST"

# Destination guards: never write to the SD card itself, the NAS, or the reviewed-images drive.
DEST_DEVICE=$(get_mount_source "$DEST")
DEST_MOUNT=$(get_mount_target "$DEST")
DEST_DISK=$(get_parent_disk "$DEST_DEVICE" || echo "")
[[ "$DEST_DISK" != "$CARD_DISK" ]] || die "Destination is on the SD card itself: $DEST"
for target in "$(readlink -f "$DEST")" "$DEST_MOUNT"; do
    if why=$(dest_forbidden "$target"); then
        die "Refusing to write to $why: $DEST"
    fi
done

for cmd in zip unzip python3 udisksctl; do
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required but not found."
done

if [[ -s "$DATA_SRC/hostname" ]]; then
    CAM_HOSTNAME=$(tr -d '[:space:]' < "$DATA_SRC/hostname")
else
    CAM_HOSTNAME="unknown"
    echo "Warning: $DATA_SRC/hostname not found; archive will use 'unknown' in its filename."
fi

IMAGES_DIR="$DATA_SRC/images_and_labels"
DATE_DIRS=()
if [[ -d "$IMAGES_DIR" ]]; then
    while IFS= read -r d; do
        [[ -n "$d" ]] && DATE_DIRS+=("$d")
    done < <(
        find "$IMAGES_DIR" -maxdepth 1 -type d -name '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' \
        | while IFS= read -r p; do basename "$p"; done | sort
    )
fi

DATE_COUNT=${#DATE_DIRS[@]}
if [[ $DATE_COUNT -eq 0 ]]; then
    DATE_SUFFIX="$(date '+%Y-%m-%d')_noimages"
elif [[ $DATE_COUNT -eq 1 ]]; then
    DATE_SUFFIX="${DATE_DIRS[0]}"
else
    DATE_SUFFIX="${DATE_DIRS[0]}_${DATE_DIRS[$((DATE_COUNT - 1))]}"
fi

TRANSFER_TS=$(date '+%Y-%m-%d-%H-%M-%S')
ZIP_NAME="${CAM_HOSTNAME}_${DATE_SUFFIX}_${TRANSFER_TS}.zip"
DEST_ZIP="$DEST/$ZIP_NAME"
VERIFY_TXT="$DEST_ZIP.verify.txt"
[[ ! -e "$DEST_ZIP" ]] || die "Archive already exists: $DEST_ZIP"

INCLUDE=()
for item in images_and_labels logs configs hostname update_backups; do
    if [[ -e "$DATA_SRC/$item" ]]; then
        INCLUDE+=("$item")
    else
        echo "Warning: $DATA_SRC/$item not found; skipping."
    fi
done
[[ ${#INCLUDE[@]} -gt 0 ]] || die "No BeeCam data found in $DATA_SRC"

echo "Camera:    $CAM_HOSTNAME"
echo "Source:    $SOURCE_MOUNT ($SOURCE_KIND, $SOURCE_DEVICE on $CARD_DISK)"
echo "Data:      $DATA_SRC"
echo "Dest:      $DEST ($DEST_DEVICE)"
echo "Archive:   $DEST_ZIP"
echo "Including: ${INCLUDE[*]}"
echo ""
echo "Date dirs (image files per day):"
for d in "${DATE_DIRS[@]}"; do
    n=$(find "$IMAGES_DIR/$d" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) 2>/dev/null | wc -l)
    s=$( { du -sh "$IMAGES_DIR/$d" 2>/dev/null || true; } | cut -f1)
    printf "  %s  %8d images  %s\n" "$d" "$n" "$s"
done
echo ""
if [[ -f "$DATA_SRC/configs/camera_config_final.ini" ]]; then
    echo "----- configs/camera_config_final.ini -----"
    cat "$DATA_SRC/configs/camera_config_final.ini"
    echo "----- end config -----"
else
    echo "configs/camera_config_final.ini not found; configs/ contains:"
    ls -la "$DATA_SRC/configs" 2>/dev/null || true
fi
echo ""

cd "$DATA_SRC"

# Source manifest, matching zip's behavior (follows symlinks, same exclusions).
if $SKIP_UNREADABLE; then
    WORK=$(mktemp -d)
    find -L "${INCLUDE[@]}" -type f ! -name '.DS_Store' ! -path '__MACOSX*' -printf '%s\t%p\n' \
        > "$WORK/manifest.tsv" 2> "$WORK/find_errors.txt" || true
    read -r SRC_FILES SRC_BYTES < <(awk -F'\t' '{n++; s+=$1} END {printf "%d %d\n", n, s}' "$WORK/manifest.tsv")
    echo "Listed $SRC_FILES files; $(grep -c . "$WORK/find_errors.txt" || true) entries could not be listed."
else
    read -r SRC_FILES SRC_BYTES < <(
        find -L "${INCLUDE[@]}" -type f ! -name '.DS_Store' ! -path '__MACOSX*' -printf '%s\n' \
        | awk '{n++; s+=$1} END {printf "%d %d\n", n, s}'
    )
fi
DEST_FREE=$(df -B1 --output=avail "$DEST" | tail -1 | tr -d ' ')
echo "Source: $SRC_FILES files, $SRC_BYTES bytes. Destination free: $DEST_FREE bytes."
[[ "$DEST_FREE" -gt $((SRC_BYTES + SRC_BYTES / 50)) ]] || die "Not enough free space on destination."

df -h "$SOURCE_MOUNT" | awk 'NR==2 {printf "SD card %s before transfer: %s used of %s (%s)\n", $6, $3, $2, $5}'
echo ""
echo "Plan:"
echo "  1. Zip ${INCLUDE[*]} -> $DEST_ZIP (store-only), verify: unzip -t, file count, bytes"
if $CLEAR_AFTER_VERIFY; then
    echo "  2. Only if verification passes: clear images_and_labels/ logs/ update_backups/ .Trash-*/ (keep configs/ hostname)"
else
    echo "  2. Leave the card's data in place ($($SKIP_UNREADABLE && echo skip-unreadable || echo no-clear) mode)"
fi
echo "  3. Unmount the card's partitions and power it off"
if ! $ASSUME_YES; then
    [[ -t 0 ]] || die "Not a terminal; pass --yes to proceed without confirmation"
    read -r -p "Proceed? [y/N] " confirm
    [[ "$confirm" == [Yy] ]] || { echo "Aborted."; exit 0; }
fi
echo "Zipping (store-only) started $(date '+%F %T')..."
if $SKIP_UNREADABLE; then
    # zip exit 18 means some listed files could not be read; those are reported, everything else verified.
    set +e
    cut -f2- "$WORK/manifest.tsv" | zip -0 -q "$DEST_ZIP" -@ 2> "$WORK/zip_warnings.txt"
    rc=$?
    set -e
    [[ $rc -eq 0 || $rc -eq 18 ]] || die "zip exited with error $rc; card left mounted. Partial archive: $DEST_ZIP"
else
    zip -0 -rq "$DEST_ZIP" "${INCLUDE[@]}" -x "*.DS_Store" -x "__MACOSX*" \
        || die "zip exited with an error; card left mounted. Partial archive: $DEST_ZIP"
fi
echo "Zip finished $(date '+%F %T'). Archive size: $(stat -c %s "$DEST_ZIP") bytes"

echo "Testing archive (unzip -tq)..."
if UNZIP_OUT=$(unzip -tq "$DEST_ZIP" 2>&1); then UNZIP_OK=PASS; else UNZIP_OK=FAIL; fi
echo "  $UNZIP_OUT"

read -r ZIP_FILES ZIP_BYTES < <(python3 -I -c '
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
fs = [i for i in z.infolist() if not i.is_dir()]
print(len(fs), sum(i.file_size for i in fs))
' "$DEST_ZIP")

COUNT_OK=FAIL; BYTES_OK=FAIL
if $SKIP_UNREADABLE; then
    # Every zipped file must be in the manifest with the same size; listed files missing from the
    # zip are the unreadable ones and go to the report with the files that could not be listed.
    UNREADABLE_TXT="$DEST_ZIP.unreadable.txt"
    read -r MISSING EXTRA MISMATCH ZIP_FILES ZIP_BYTES < <(python3 -I -c '
import sys, zipfile
manifest = {}
for line in open(sys.argv[2], encoding="utf-8", errors="surrogateescape"):
    size, name = line.rstrip("\n").split("\t", 1)
    manifest[name] = int(size)
entries = {i.filename: i.file_size for i in zipfile.ZipFile(sys.argv[1]).infolist() if not i.is_dir()}
missing = sorted(set(manifest) - set(entries))
extra = sorted(set(entries) - set(manifest))
mismatch = sorted(n for n in entries if n in manifest and entries[n] != manifest[n])
with open(sys.argv[3], "w") as out:
    out.write("# Files left out of the archive (could not be listed or read on the card)\n")
    for line in open(sys.argv[4], errors="replace"):
        out.write("not_listed\t" + line)
    for n in missing:
        out.write("not_read\t" + n + "\n")
print(len(missing), len(extra), len(mismatch), len(entries), sum(entries.values()))
' "$DEST_ZIP" "$WORK/manifest.tsv" "$UNREADABLE_TXT" "$WORK/find_errors.txt")
    [[ "$EXTRA" == 0 && "$MISMATCH" == 0 ]] && COUNT_OK=PASS && BYTES_OK=PASS
    NOT_LISTED=$(grep -c . "$WORK/find_errors.txt" || true)
    if [[ -s "$WORK/zip_warnings.txt" ]]; then cp "$WORK/zip_warnings.txt" "$DEST_ZIP.zip_warnings.txt"; fi
else
    [[ "$ZIP_FILES" == "$SRC_FILES" ]] && COUNT_OK=PASS
    [[ "$ZIP_BYTES" == "$SRC_BYTES" ]] && BYTES_OK=PASS
fi
OVERALL=FAIL
[[ "$UNZIP_OK$COUNT_OK$BYTES_OK" == PASSPASSPASS ]] && OVERALL=PASS

{
    echo "archive: $DEST_ZIP"
    echo "archive_bytes: $(stat -c %s "$DEST_ZIP")"
    echo "verified_at: $(date '+%F %T')"
    echo "camera: $CAM_HOSTNAME"
    echo "source: $DATA_SRC ($SOURCE_DEVICE)"
    echo "included: ${INCLUDE[*]}"
    echo "source_file_count: $SRC_FILES"
    echo "zip_file_count: $ZIP_FILES ($COUNT_OK)"
    echo "source_bytes: $SRC_BYTES"
    echo "zip_uncompressed_bytes: $ZIP_BYTES ($BYTES_OK)"
    echo "unzip_tq: $UNZIP_OK ($UNZIP_OUT)"
    if $SKIP_UNREADABLE; then
        echo "mode: skip-unreadable (card is never cleared)"
        echo "files_not_listed: $NOT_LISTED"
        echo "files_listed_but_not_read: $MISSING"
        echo "zip_entries_not_in_manifest: $EXTRA"
        echo "zip_entries_size_mismatch: $MISMATCH"
        echo "unreadable_list: $UNREADABLE_TXT"
    fi
    for d in "${DATE_DIRS[@]}"; do
        echo "date_dir: $d $(find "$IMAGES_DIR/$d" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) 2>/dev/null | wc -l) images"
    done
    echo "result: $OVERALL"
} > "$VERIFY_TXT"
if [[ "$(id -u)" -eq 0 && -n "${SUDO_UID:-}" ]]; then
    chown "${SUDO_UID}:${SUDO_GID:-$SUDO_UID}" "$DEST_ZIP" "$VERIFY_TXT" "$DEST_ZIP".*.txt 2>/dev/null || true
fi
cat "$VERIFY_TXT"

[[ "$OVERALL" == PASS ]] || die "Verification FAILED; card left mounted. See $VERIFY_TXT"

if $CLEAR_AFTER_VERIFY; then
    clear_card_data
fi

unmount_and_power_off_card "$CARD_DISK"

echo ""
echo "Done. Archive: $DEST_ZIP  ($(du -h "$DEST_ZIP" | cut -f1)), verification PASS, card cleared: $CLEAR_AFTER_VERIFY, card $CARD_DISK unmounted."
