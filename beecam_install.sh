#!/usr/bin/env bash
set -euo pipefail
trap 'echo "ERROR: install failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PI_HOME="/home/pi"
DATA_ROOT="${PI_HOME}/data"
DATA_CONFIG_DIR="${DATA_ROOT}/configs"
DATA_INIT="/usr/local/sbin/beecam-init-data.sh"
VIDEO_ARG="video=HDMI-A-1:800x480@60D"
COHERENT_POOL_ARG="coherent_pool=2M"
RUN_APT_UPDATE="${BEECAM_APT_UPDATE:-1}"
RUN_FULL_UPGRADE="${BEECAM_FULL_UPGRADE:-0}"

log() {
    echo
    echo "==> $*"
}

warn() {
    echo
    echo "WARNING: $*" >&2
}

require_file() {
    if [[ ! -e "$1" ]]; then
        echo "Missing required file: $1" >&2
        exit 1
    fi
}

# Adds KEY=VALUE to an existing config file only if that key is missing.
# Existing field-edited configs are otherwise preserved untouched; this
# specifically backfills newly-introduced settings that older configs
# predate, so preservation doesn't leave them permanently absent.
ensure_config_key() {
    local file="$1" key="$2" value="$3"
    [[ -f "$file" ]] || return 0
    if grep -Eq "^[[:space:]]*${key}=" "$file"; then
        return 0
    fi
    log "Adding missing ${key}=${value} to $(basename "$file")"
    printf '%s=%s\n' "$key" "$value" | sudo tee -a "$file" >/dev/null
}

usage() {
    cat <<'USAGE'
Usage:
  ./beecam_install.sh [options]

Options:
  --full-upgrade       Run apt-get full-upgrade before installing packages.
  --skip-apt-update    Skip apt-get update. Use only after running sudo apt update.
  -h, --help           Show this help.

Environment:
  BEECAM_FULL_UPGRADE=1   Same as --full-upgrade.
  BEECAM_APT_UPDATE=0     Same as --skip-apt-update.
USAGE
}

is_enabled() {
    case "${1,,}" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --full-upgrade)
                RUN_FULL_UPGRADE=1
                shift
                ;;
            --skip-apt-update)
                RUN_APT_UPDATE=0
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Unknown argument: $1" >&2
                usage >&2
                exit 1
                ;;
        esac
    done
}

install_data_initializer() {
    log "Installing BeeCam data directory initializer"
    require_file "${SCRIPT_DIR}/scripts/beecam-init-data.sh"
    require_file "${SCRIPT_DIR}/systemd_services/beecam-init-data.service"

    sudo install -m 0755 "${SCRIPT_DIR}/scripts/beecam-init-data.sh" "$DATA_INIT"
    sudo install -m 0644 "${SCRIPT_DIR}/systemd_services/beecam-init-data.service" /etc/systemd/system/beecam-init-data.service
    sudo systemctl daemon-reload
    sudo systemctl enable beecam-init-data.service
}

install_apt_packages() {
    log "Installing BeeCam apt packages"
    if is_enabled "$RUN_APT_UPDATE"; then
        sudo apt-get update
    else
        log "Skipping apt-get update because --skip-apt-update was requested"
    fi

    if is_enabled "$RUN_FULL_UPGRADE"; then
        log "Running apt-get full-upgrade"
        sudo DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y
    else
        log "Skipping apt-get full-upgrade; use --full-upgrade for a full OS refresh"
    fi

    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        feh \
        fbi \
        git \
        i2c-tools \
        imx500-all \
        python3-munkres \
        python3-opencv \
        python3-pil \
        python3-pip \
        python3-smbus \
        wget
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        python3-picamera2
}

install_python_packages() {
    log "Installing BeeCam pip packages"
    sudo python3 -m pip install --break-system-packages \
        astral \
        adafruit-circuitpython-ssd1306
}

install_wittypi() {
    log "Installing Witty Pi software"
    local install_script="${PI_HOME}/wittypi-install.sh"
    wget -O "$install_script" https://www.uugear.com/repo/WittyPi4/install.sh
    (cd "$PI_HOME" && sudo sh "$install_script")
    rm -f "$install_script"

    if [[ ! -d "${PI_HOME}/wittypi" ]]; then
        echo "Expected ${PI_HOME}/wittypi after Witty Pi install, but it was not found." >&2
        echo "Check whether the UUGear installer created wittypi somewhere else with: sudo find / -maxdepth 3 -type d -name wittypi 2>/dev/null" >&2
        exit 1
    fi

    log "Disabling fake-hwclock for Witty Pi RTC"
    sudo apt-get -y remove fake-hwclock || true
    sudo update-rc.d -f fake-hwclock remove || true
    sudo systemctl disable fake-hwclock || true
    sudo rm -f /lib/udev/hwclock-set

    log "Installing BeeCam Witty Pi scripts"
    for script in beforeScript.sh afterStartup.sh runScript.sh beforeShutdown.sh; do
        require_file "${SCRIPT_DIR}/wittypi/${script}"
        sudo install -m 0755 "${SCRIPT_DIR}/wittypi/${script}" "${PI_HOME}/wittypi/${script}"
    done
    sudo chown pi:pi "${PI_HOME}/wittypi/"*.sh
    log "Witty Pi installed at ${PI_HOME}/wittypi"
}

install_beecam_files() {
    log "Copying BeeCam application files"
    require_file "${SCRIPT_DIR}/beecam"
    sudo rm -rf "${PI_HOME}/beecam"
    sudo cp -a "${SCRIPT_DIR}/beecam" "${PI_HOME}/beecam"
    sudo rm -rf "${PI_HOME}/beecam/camera/relegated" "${PI_HOME}/beecam/camera/__pycache__"
    sudo find "${PI_HOME}/beecam/camera" -maxdepth 1 -type f -name '*.py' \
        ! -name 'beecam_capture_final.py' \
        ! -name 'beecam_preview.py' \
        -delete
    sudo chown -R pi:pi "${PI_HOME}/beecam"

    log "Preparing BeeCam data directory"
    sudo install -d -o pi -g pi -m 0755 \
        "$DATA_ROOT" \
        "${DATA_ROOT}/logs" \
        "${DATA_ROOT}/images_and_labels"
    if [[ ! -e "$DATA_CONFIG_DIR" ]]; then
        log "Copying default configs to ${DATA_CONFIG_DIR}"
        sudo install -d -o pi -g pi -m 0755 "$DATA_CONFIG_DIR"
        sudo cp -r "${SCRIPT_DIR}/configs/." "$DATA_CONFIG_DIR/"
        sudo chown -R pi:pi "$DATA_CONFIG_DIR"
    else
        log "Preserving existing ${DATA_CONFIG_DIR}"
        ensure_config_key "${DATA_CONFIG_DIR}/schedule.conf" "WITTYPI_LOW_VOLTAGE_THRESHOLD" "3.5"
        ensure_config_key "${DATA_CONFIG_DIR}/schedule.conf" "WITTYPI_RECOVERY_VOLTAGE_THRESHOLD" "4.0"
    fi
}

install_boot_files() {
    log "Updating boot firmware files"
    require_file "${SCRIPT_DIR}/boot_firmware/config.txt"

    local boot_dir="/boot/firmware"
    if [[ ! -d "$boot_dir" ]]; then
        boot_dir="/boot"
    fi

    require_file "${boot_dir}/cmdline.txt"

    if ! grep -Fq "$VIDEO_ARG" "${boot_dir}/cmdline.txt"; then
        sudo sed -i "1 s/$/ ${VIDEO_ARG}/" "${boot_dir}/cmdline.txt"
    fi

    # Enlarge the atomic DMA-coherent pool used by USB/network drivers. Prevents
    # "Cannot allocate memory" when peripherals (USB ethernet) are attached alongside
    # the camera. Appended idempotently; cmdline.txt is never wholesale-replaced because
    # it carries the card-specific root=PARTUUID.
    if ! grep -Fq "$COHERENT_POOL_ARG" "${boot_dir}/cmdline.txt"; then
        sudo sed -i "1 s/$/ ${COHERENT_POOL_ARG}/" "${boot_dir}/cmdline.txt"
    fi

    sudo install -m 0644 "${SCRIPT_DIR}/boot_firmware/config.txt" "${boot_dir}/config.txt"

    if ! sudo cmp -s "${SCRIPT_DIR}/boot_firmware/config.txt" "${boot_dir}/config.txt"; then
        echo "Failed to replace ${boot_dir}/config.txt" >&2
        exit 1
    fi

    log "Disabling Bluetooth UART service"
    sudo systemctl disable --now hciuart 2>/dev/null || true
}

apply_wittypi_schedule_now() {
    log "Applying Witty Pi power settings and arming schedule"
    sudo "${PI_HOME}/wittypi/beforeScript.sh"
    sudo "${PI_HOME}/wittypi/runScript.sh"
}

install_systemd_services() {
    log "Installing systemd services"
    sudo mkdir -p /etc/systemd/system
    for service in "${SCRIPT_DIR}"/systemd_services/*.service; do
        sudo install -m 0644 "$service" "/etc/systemd/system/$(basename "$service")"
    done

    sudo systemctl daemon-reload

    for service in "${SCRIPT_DIR}"/systemd_services/*.service; do
        service_name="$(basename "$service")"
        if [[ "$service_name" == "beecam.service" ]]; then
            sudo systemctl disable beecam.service 2>/dev/null || true
        else
            sudo systemctl enable "$service_name"
        fi
    done
    log "Systemd services installed in /etc/systemd/system"
}

main() {
    parse_args "$@"

    if [[ "$(id -u)" -eq 0 ]]; then
        echo "Run this script as the pi user, not with sudo. It will call sudo when needed." >&2
        exit 1
    fi

    require_file "${SCRIPT_DIR}/configs/camera_config_final.ini"
    require_file "${SCRIPT_DIR}/configs/schedule.conf"

    install_data_initializer
    install_apt_packages
    install_python_packages
    install_wittypi
    install_beecam_files
    install_boot_files
    install_systemd_services
    apply_wittypi_schedule_now

    log "BeeCam install complete"
    echo "Reboot before testing camera startup."
}

main "$@"
