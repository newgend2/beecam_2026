#!/usr/bin/env bash
# Apply BeeCam boot-firmware settings on an already-installed camera.
#
# Installs the repo config.txt (which carries dtoverlay=vc4-kms-v3d,cma-256) over
# /boot/firmware/config.txt, and idempotently appends coherent_pool=2M to cmdline.txt.
# Together these enlarge the CMA and DMA-coherent pools so the full-res camera preview
# plus HDMI/USB peripherals no longer exhaust memory ("Cannot allocate memory").
#
# cmdline.txt is edited in place, never wholesale-replaced, because it carries the
# card-specific root=PARTUUID. A reboot (or the next Witty Pi power cycle) applies changes.
#
# Usage:
#   beecam-apply-boot-config.sh <repo_boot_firmware_dir> [backup_dir]
set -euo pipefail

REPO_BOOT_DIR="${1:-}"
BACKUP_DIR="${2:-}"
COHERENT_POOL_ARG="coherent_pool=2M"

log() {
    echo
    echo "==> $*"
}

die() {
    echo "Error: $*" >&2
    exit 1
}

[[ -n "$REPO_BOOT_DIR" ]] || die "Usage: beecam-apply-boot-config.sh <repo_boot_firmware_dir> [backup_dir]"
[[ -f "${REPO_BOOT_DIR}/config.txt" ]] || die "Missing ${REPO_BOOT_DIR}/config.txt"

if [[ "$(id -u)" -ne 0 ]]; then
    die "Must run as root (via sudo)."
fi

BOOT_DIR="/boot/firmware"
if [[ ! -d "$BOOT_DIR" ]]; then
    BOOT_DIR="/boot"
fi
CONFIG_TXT="${BOOT_DIR}/config.txt"
CMDLINE_TXT="${BOOT_DIR}/cmdline.txt"
[[ -f "$CMDLINE_TXT" ]] || die "Missing ${CMDLINE_TXT}"

changed=0

# Back up current boot files before touching them.
if [[ -n "$BACKUP_DIR" ]]; then
    mkdir -p "$BACKUP_DIR"
    [[ -f "$CONFIG_TXT" ]] && cp "$CONFIG_TXT" "${BACKUP_DIR}/config.txt"
    cp "$CMDLINE_TXT" "${BACKUP_DIR}/cmdline.txt"
    log "Backed up boot files to ${BACKUP_DIR}"
fi

log "Updating ${CONFIG_TXT} from repo (brings dtoverlay=vc4-kms-v3d,cma-256)"
if [[ -f "$CONFIG_TXT" ]] && cmp -s "${REPO_BOOT_DIR}/config.txt" "$CONFIG_TXT"; then
    echo "config.txt already up to date."
else
    install -m 0644 "${REPO_BOOT_DIR}/config.txt" "$CONFIG_TXT"
    cmp -s "${REPO_BOOT_DIR}/config.txt" "$CONFIG_TXT" || die "Failed to replace ${CONFIG_TXT}"
    changed=1
    echo "config.txt updated."
fi

log "Ensuring ${COHERENT_POOL_ARG} in ${CMDLINE_TXT}"
if grep -Fq "$COHERENT_POOL_ARG" "$CMDLINE_TXT"; then
    echo "cmdline.txt already has ${COHERENT_POOL_ARG}."
else
    sed -i "1 s/$/ ${COHERENT_POOL_ARG}/" "$CMDLINE_TXT"
    grep -Fq "$COHERENT_POOL_ARG" "$CMDLINE_TXT" || die "Failed to append ${COHERENT_POOL_ARG} to ${CMDLINE_TXT}"
    changed=1
    echo "cmdline.txt updated."
fi

echo
if [[ "$changed" -eq 1 ]]; then
    echo "Boot config changed. Reboot to apply now, or it takes effect on the next Witty Pi power cycle."
else
    echo "Boot config already current; no reboot needed."
fi
