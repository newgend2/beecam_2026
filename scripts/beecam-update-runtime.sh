#!/usr/bin/env bash
set -euo pipefail
trap 'echo "ERROR: update failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PI_HOME="/home/pi"
APP_DIR="${PI_HOME}/beecam"
DATA_ROOT="${PI_HOME}/data"
DATA_CONFIG_DIR="${DATA_ROOT}/configs"
SERVICE_DIR="/etc/systemd/system"
DATA_INIT="/usr/local/sbin/beecam-init-data.sh"
WITTYPI_DIR="${PI_HOME}/wittypi"
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
  - /home/pi/beecam/camera/packerout model assets
  - /home/pi/data/configs, replaced from this repo
  - /usr/local/sbin/beecam-init-data.sh
  - /home/pi/wittypi BeeCam scripts
  - Witty Pi power settings and schedule, applied immediately after install
  - /etc/systemd/system BeeCam service files

It does not install apt packages, Witty Pi, boot files, or partition anything.
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

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' is required but was not found."
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

if $DO_GIT_PULL; then
    log "Pulling latest repo changes"
    git -C "$REPO_DIR" pull --ff-only
fi

require_file "${REPO_DIR}/beecam"
require_file "${REPO_DIR}/beecam/oled_boot_splash.py"
require_file "${REPO_DIR}/beecam/camera/packerout"
require_file "${REPO_DIR}/configs"
require_file "${REPO_DIR}/scripts/beecam-init-data.sh"
for script in beforeScript.sh afterStartup.sh runScript.sh beforeShutdown.sh; do
    require_file "${REPO_DIR}/wittypi/${script}"
done
shopt -s nullglob
SERVICE_FILES=("${REPO_DIR}"/systemd_services/*.service)
shopt -u nullglob
[[ ${#SERVICE_FILES[@]} -gt 0 ]] || die "No service files found in ${REPO_DIR}/systemd_services"

[[ "$CAPTURE_SCRIPT" != */* ]] || die "--capture-script must be a filename, not a path"
require_file "${REPO_DIR}/beecam/camera/${CAPTURE_SCRIPT}"
require_file "${REPO_DIR}/beecam/camera/beecam_preview.py"

if [[ ! -d "$DATA_CONFIG_DIR" ]]; then
    die "${DATA_CONFIG_DIR} does not exist. Run the BeeCam installer or data initializer first."
fi
if [[ ! -d "$WITTYPI_DIR" ]]; then
    die "${WITTYPI_DIR} does not exist. Run the BeeCam installer first."
fi

SERVICE_WAS_ACTIVE=false
if systemctl is-active --quiet beecam.service; then
    SERVICE_WAS_ACTIVE=true
fi

if $SERVICE_WAS_ACTIVE; then
    log "Stopping beecam.service"
    sudo systemctl stop beecam.service
fi

BACKUP_ROOT="${DATA_ROOT}/update_backups/$(date +%Y%m%d_%H%M%S)"
log "Backing up current runtime files to ${BACKUP_ROOT}"
sudo mkdir -p "$BACKUP_ROOT"
if [[ -d "$APP_DIR" ]]; then
    sudo cp -r "$APP_DIR" "${BACKUP_ROOT}/beecam"
fi
if [[ -d "$DATA_CONFIG_DIR" ]]; then
    sudo mkdir -p "${BACKUP_ROOT}/configs"
    sudo cp -r "${DATA_CONFIG_DIR}/." "${BACKUP_ROOT}/configs/"
fi
sudo mkdir -p "${BACKUP_ROOT}/systemd_services"
for service in "${SERVICE_FILES[@]}"; do
    service_name="$(basename "$service")"
    if [[ -f "${SERVICE_DIR}/${service_name}" ]]; then
        sudo cp "${SERVICE_DIR}/${service_name}" "${BACKUP_ROOT}/systemd_services/${service_name}"
    fi
done
if [[ -f "$DATA_INIT" ]]; then
    sudo cp "$DATA_INIT" "${BACKUP_ROOT}/beecam-init-data.sh"
fi
if [[ -d "$WITTYPI_DIR" ]]; then
    sudo mkdir -p "${BACKUP_ROOT}/wittypi"
    for script in beforeScript.sh afterStartup.sh runScript.sh beforeShutdown.sh; do
        if [[ -f "${WITTYPI_DIR}/${script}" ]]; then
            sudo cp "${WITTYPI_DIR}/${script}" "${BACKUP_ROOT}/wittypi/${script}"
        fi
    done
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

log "Replacing ${DATA_CONFIG_DIR} from repo configs"
sudo rm -rf "$DATA_CONFIG_DIR"
sudo install -d -o pi -g pi -m 0755 "$DATA_CONFIG_DIR"
sudo cp -a "${REPO_DIR}/configs/." "$DATA_CONFIG_DIR/"
sudo chown -R pi:pi "$DATA_CONFIG_DIR"

log "Updating ${DATA_INIT}"
sudo install -m 0755 "${REPO_DIR}/scripts/beecam-init-data.sh" "$DATA_INIT"

log "Updating Witty Pi scripts"
for script in beforeScript.sh afterStartup.sh runScript.sh beforeShutdown.sh; do
    sudo install -m 0755 "${REPO_DIR}/wittypi/${script}" "${WITTYPI_DIR}/${script}"
done
sudo chown pi:pi "${WITTYPI_DIR}/"*.sh

log "Updating systemd service files"
for service in "${SERVICE_FILES[@]}"; do
    service_name="$(basename "$service")"
    if [[ "$service_name" == "beecam.service" ]]; then
        tmp_service="$(mktemp)"
        sed "s#ExecStart=.*#ExecStart=/usr/bin/python3 /home/pi/beecam/camera/${CAPTURE_SCRIPT} --config ${DATA_CONFIG_DIR}/camera_config_final.ini#" \
            "$service" > "$tmp_service"
        sudo install -m 0644 "$tmp_service" "${SERVICE_DIR}/${service_name}"
        rm -f "$tmp_service"
    else
        sudo install -m 0644 "$service" "${SERVICE_DIR}/${service_name}"
    fi
done
sudo systemctl daemon-reload
for service in "${SERVICE_FILES[@]}"; do
    service_name="$(basename "$service")"
    if [[ "$service_name" != "beecam.service" ]]; then
        sudo systemctl enable "$service_name"
    fi
done

log "Applying Witty Pi power settings and arming updated schedule"
sudo "${WITTYPI_DIR}/beforeScript.sh"
sudo "${WITTYPI_DIR}/runScript.sh"

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
echo "  Configs:        ${DATA_CONFIG_DIR}"
echo "  Backup:         ${BACKUP_ROOT}"
echo "  Service:        $(systemctl is-active beecam.service || true)"
