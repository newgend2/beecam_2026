#!/usr/bin/env bash
set -euo pipefail
trap 'echo "ERROR: offline update failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_USER="pi"
REMOTE_SETUP="/home/pi/setup"
REMOTE_DATA_ROOT="/home/pi/data"
SSH_CONTROL_DIR=""
SSH_CONTROL_PATH=""
UPDATE_SCHEDULE_CONF=false

usage() {
    cat <<'USAGE'
Usage:
  ./offline_update.sh [options] [camera-hostname]

Options:
  --update-schedule-conf   Also replace /home/pi/data/configs/schedule.conf.
                           Use only when intentionally overwriting live schedule settings.
  -h, --help               Show this help.
USAGE
}

die() {
    echo "Error: $*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' is required but was not found."
}

normalize_host() {
    local host="$1"
    host="${host#${REMOTE_USER}@}"
    host="${host%.local}"
    host="${host//[[:space:]]/}"
    [[ -n "$host" ]] || die "No camera hostname provided."
    printf '%s.local\n' "$host"
}

cleanup_ssh_control() {
    if [[ -n "$SSH_CONTROL_PATH" ]]; then
        ssh -S "$SSH_CONTROL_PATH" -O exit "$REMOTE" >/dev/null 2>&1 || true
    fi
    if [[ -n "$SSH_CONTROL_DIR" ]]; then
        rm -rf "$SSH_CONTROL_DIR"
    fi
}

start_ssh_control_master() {
    SSH_CONTROL_DIR="$(mktemp -d)"
    SSH_CONTROL_PATH="${SSH_CONTROL_DIR}/ssh_mux"
    trap cleanup_ssh_control EXIT

    echo
    echo "==> Opening SSH connection"
    ssh -M -N -f \
        -o ControlPath="$SSH_CONTROL_PATH" \
        -o ControlPersist=10m \
        "$REMOTE"
}

ssh_reuse() {
    ssh -o ControlPath="$SSH_CONTROL_PATH" "$REMOTE" "$@"
}

need_cmd rsync
need_cmd ssh

while [[ $# -gt 0 ]]; do
    case "$1" in
        --update-schedule-conf)
            UPDATE_SCHEDULE_CONF=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*)
            die "Unknown option: $1"
            ;;
        *)
            if [[ "${CAM_HOST:-}" != "" ]]; then
                die "Usage: ./offline_update.sh [options] [camera-hostname]"
            fi
            CAM_HOST="$1"
            shift
            ;;
    esac
done

if [[ "${CAM_HOST:-}" == "" ]]; then
    read -r -p "Camera hostname, e.g. cam17: " CAM_HOST
fi

REMOTE_HOST="$(normalize_host "$CAM_HOST")"
REMOTE="${REMOTE_USER}@${REMOTE_HOST}"

echo
echo "Camera: ${REMOTE}"
echo "Source: ${SCRIPT_DIR}/"
echo "Target: ${REMOTE}:${REMOTE_SETUP}/"
if $UPDATE_SCHEDULE_CONF; then
    echo "Schedule: will overwrite ${REMOTE_DATA_ROOT}/configs/schedule.conf"
else
    echo "Schedule: preserving existing ${REMOTE_DATA_ROOT}/configs/schedule.conf"
fi
echo
read -r -p "Proceed with offline update? [y/N] " confirm
case "$confirm" in
    [Yy]) ;;
    *) echo "Aborted."; exit 0 ;;
esac

start_ssh_control_master

echo
echo "==> Checking camera rootfs data directories"
if ! ssh_reuse 'test -d /home/pi/data && test -w /home/pi/data && test -d /home/pi/data/configs && test -d /home/pi/data/images_and_labels && test -d /home/pi/data/logs'; then
    die "Remote ${REMOTE_DATA_ROOT} is missing required BeeCam folders on ${REMOTE}. Run the BeeCam installer or data initializer first."
fi

echo
echo "==> Syncing repo to camera"
rsync -az --delete \
    -e "ssh -o ControlPath=${SSH_CONTROL_PATH}" \
    --exclude='.git/' \
    --exclude='beecam/camera/__pycache__/' \
    "${SCRIPT_DIR}/" "${REMOTE}:${REMOTE_SETUP}/"

echo
echo "==> Running runtime updater on camera"
runtime_args=(--restart)
if $UPDATE_SCHEDULE_CONF; then
    runtime_args+=(--update-schedule-conf)
fi
printf -v runtime_args_q ' %q' "${runtime_args[@]}"
ssh_reuse "cd ${REMOTE_SETUP} && chmod +x scripts/beecam-update-runtime.sh && scripts/beecam-update-runtime.sh${runtime_args_q}"

echo
echo "Offline update complete for ${REMOTE}."
