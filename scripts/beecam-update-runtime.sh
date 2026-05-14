#!/usr/bin/env bash
set -euo pipefail
trap 'echo "ERROR: update failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PI_HOME="/home/pi"
APP_DIR="${PI_HOME}/beecam"
DATA_CONFIG_DIR="/data/configs"
SERVICE_FILE="/etc/systemd/system/beecam.service"
CAPTURE_SCRIPT="beecam_capture_final.py"
DO_GIT_PULL=false
RESTART_MODE="auto"

usage() {
    cat <<'USAGE'
Usage:
  scripts/beecam-update-runtime.sh [options]

Options:
  --git-pull                 Run git pull in this repo before installing files.
  --capture-script NAME      Use NAME in beecam.service ExecStart.
                             Default: beecam_capture_final.py
  --restart                  Restart beecam.service after updating.
  --no-restart               Do not restart beecam.service after updating.
  -h, --help                 Show this help.

Updates only runtime files:
  - /home/pi/beecam, excluding relegated reference scripts
  - /data/configs/camera_config_final.ini, overwritten from this repo
  - /etc/systemd/system/beecam.service

It does not install apt packages, Witty Pi, boot files, or repartition anything.
USAGE
}

log() {
    echo
    echo "==> $*"
}

warn() {
    echo
    echo "WARNING: $*" >&2
}

die() {
    echo "Error: $*" >&2
    exit 1
}

require_file() {
    [[ -e "$1" ]] || die "Missing required file: $1"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --git-pull)
            DO_GIT_PULL=true
            shift
            ;;
        --capture-script)
            [[ $# -ge 2 ]] || die "--capture-script requires a filename"
            CAPTURE_SCRIPT="$2"
            if [[ "$CAPTURE_SCRIPT" == "beecam_capture_final_v3.py" ]]; then
                CAPTURE_SCRIPT="beecam_capture_final.py"
                warn "beecam_capture_final_v3.py is now deployed as beecam_capture_final.py"
            fi
            shift 2
            ;;
        --restart)
            RESTART_MODE="yes"
            shift
            ;;
        --no-restart)
            RESTART_MODE="no"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

if [[ "$(id -u)" -eq 0 ]]; then
    die "Run as the pi user, not with sudo. The script will call sudo when needed."
fi

require_file "${REPO_DIR}/beecam"
require_file "${REPO_DIR}/configs/camera_config_final.ini"
require_file "${REPO_DIR}/systemd_services/beecam.service"

if $DO_GIT_PULL; then
    log "Pulling latest repo changes"
    git -C "$REPO_DIR" pull --ff-only
fi

[[ "$CAPTURE_SCRIPT" != */* ]] || die "--capture-script must be a filename, not a path"
require_file "${REPO_DIR}/beecam/camera/${CAPTURE_SCRIPT}"
require_file "${REPO_DIR}/beecam/camera/beecam_preview.py"

if [[ ! -d "$DATA_CONFIG_DIR" ]]; then
    die "${DATA_CONFIG_DIR} does not exist. Is /data mounted?"
fi

SERVICE_WAS_ACTIVE=false
if systemctl is-active --quiet beecam.service; then
    SERVICE_WAS_ACTIVE=true
fi

if $SERVICE_WAS_ACTIVE; then
    log "Stopping beecam.service"
    sudo systemctl stop beecam.service
fi

BACKUP_ROOT="/data/update_backups/$(date +%Y%m%d_%H%M%S)"
log "Backing up current runtime files to ${BACKUP_ROOT}"
sudo mkdir -p "$BACKUP_ROOT"
if [[ -d "$APP_DIR" ]]; then
    sudo cp -a "$APP_DIR" "${BACKUP_ROOT}/beecam"
fi
if [[ -d "$DATA_CONFIG_DIR" ]]; then
    sudo mkdir -p "${BACKUP_ROOT}/configs"
    sudo cp -a "${DATA_CONFIG_DIR}/." "${BACKUP_ROOT}/configs/"
fi
if [[ -f "$SERVICE_FILE" ]]; then
    sudo cp -a "$SERVICE_FILE" "${BACKUP_ROOT}/beecam.service"
fi

log "Updating /home/pi/beecam"
sudo rm -rf "$APP_DIR"
sudo cp -a "${REPO_DIR}/beecam" "$APP_DIR"
sudo rm -rf "${APP_DIR}/camera/relegated" "${APP_DIR}/camera/__pycache__"
sudo find "${APP_DIR}/camera" -maxdepth 1 -type f -name '*.py' \
    ! -name "${CAPTURE_SCRIPT}" \
    ! -name 'beecam_preview.py' \
    -delete
sudo chown -R pi:pi "$APP_DIR"

log "Updating /data/configs/camera_config_final.ini"
sudo mkdir -p "$DATA_CONFIG_DIR"
sudo install -m 0644 "${REPO_DIR}/configs/camera_config_final.ini" "${DATA_CONFIG_DIR}/camera_config_final.ini"

log "Updating beecam.service"
tmp_service="$(mktemp)"
sed "s#ExecStart=.*#ExecStart=/usr/bin/python3 /home/pi/beecam/camera/${CAPTURE_SCRIPT} --config /data/configs/camera_config_final.ini#" \
    "${REPO_DIR}/systemd_services/beecam.service" > "$tmp_service"
sudo install -m 0644 "$tmp_service" "$SERVICE_FILE"
rm -f "$tmp_service"
sudo systemctl daemon-reload

if [[ "$RESTART_MODE" == "yes" || ( "$RESTART_MODE" == "auto" && "$SERVICE_WAS_ACTIVE" == "true" ) ]]; then
    log "Starting beecam.service"
    sudo systemctl start beecam.service
elif [[ "$RESTART_MODE" == "auto" ]]; then
    warn "beecam.service was not active, so it was left stopped."
else
    warn "Restart skipped by --no-restart."
fi

log "Runtime update complete"
echo "  Capture script: ${CAPTURE_SCRIPT}"
echo "  Backup:         ${BACKUP_ROOT}"
echo "  Service:        $(systemctl is-active beecam.service || true)"
