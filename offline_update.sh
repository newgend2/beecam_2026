#!/usr/bin/env bash
set -euo pipefail
trap 'echo "ERROR: offline update failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_USER="pi"
REMOTE_SETUP="/home/pi/setup"
REMOTE_DATA_ROOT="/home/pi/data"

die() {
    echo "Error: $*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' is required but was not found."
}

quote_for_remote_shell() {
    printf "'"
    printf "%s" "$1" | sed "s/'/'\\\\''/g"
    printf "'"
}

normalize_host() {
    local host="$1"
    host="${host#${REMOTE_USER}@}"
    host="${host%.local}"
    host="${host//[[:space:]]/}"
    [[ -n "$host" ]] || die "No camera hostname provided."
    printf '%s.local\n' "$host"
}

run_remote_runtime_update() {
    local remote_command
    remote_command=$(cat <<'REMOTE'
set -euo pipefail

cd /home/pi/setup
chmod +x scripts/beecam-update-runtime.sh

echo
echo "==> Authenticating sudo on camera"
sudo -v

(
    while true; do
        sudo -n -v >/dev/null 2>&1 || exit
        sleep 30
    done
) &
sudo_keepalive_pid=$!
trap 'kill "$sudo_keepalive_pid" >/dev/null 2>&1 || true' EXIT

scripts/beecam-update-runtime.sh --restart
REMOTE
)

    ssh -tt "$REMOTE" "bash -lc $(quote_for_remote_shell "$remote_command")"
}

need_cmd rsync
need_cmd ssh

if [[ $# -gt 1 ]]; then
    die "Usage: ./offline_update.sh [camera-hostname]"
fi

if [[ $# -eq 1 ]]; then
    CAM_HOST="$1"
else
    read -r -p "Camera hostname, e.g. cam17: " CAM_HOST
fi

REMOTE_HOST="$(normalize_host "$CAM_HOST")"
REMOTE="${REMOTE_USER}@${REMOTE_HOST}"

echo
echo "Camera: ${REMOTE}"
echo "Source: ${SCRIPT_DIR}/"
echo "Target: ${REMOTE}:${REMOTE_SETUP}/"
echo
read -r -p "Proceed with offline update? [y/N] " confirm
case "$confirm" in
    [Yy]) ;;
    *) echo "Aborted."; exit 0 ;;
esac

echo
echo "==> Checking camera rootfs data directories"
if ! ssh "$REMOTE" 'test -d /home/pi/data && test -w /home/pi/data && test -d /home/pi/data/configs && test -d /home/pi/data/images_and_labels && test -d /home/pi/data/logs'; then
    die "Remote ${REMOTE_DATA_ROOT} is missing required BeeCam folders on ${REMOTE}. Run the BeeCam installer or data initializer first."
fi

echo
echo "==> Syncing repo to camera"
rsync -az --delete \
    --exclude='.git/' \
    --exclude='beecam/camera/__pycache__/' \
    "${SCRIPT_DIR}/" "${REMOTE}:${REMOTE_SETUP}/"

echo
echo "==> Running runtime updater on camera"
run_remote_runtime_update

echo
echo "Offline update complete for ${REMOTE}."
