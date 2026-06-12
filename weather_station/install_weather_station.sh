#!/usr/bin/env bash
set -euo pipefail
trap 'echo "ERROR: install failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PI_HOME="/home/pi"
DATA_ROOT="${PI_HOME}/data"
DATA_CONFIG_DIR="${DATA_ROOT}/configs"
DATA_INIT="/usr/local/sbin/weather-station-init-data.sh"
RUN_APT_UPDATE="${WEATHER_STATION_APT_UPDATE:-1}"
RUN_FULL_UPGRADE="${WEATHER_STATION_FULL_UPGRADE:-0}"

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

usage() {
    cat <<'USAGE'
Usage:
  ./install_weather_station.sh [options]

Options:
  --full-upgrade       Run apt-get full-upgrade before installing packages.
  --skip-apt-update    Skip apt-get update. Use only after running sudo apt update.
  -h, --help           Show this help.

Environment:
  WEATHER_STATION_FULL_UPGRADE=1   Same as --full-upgrade.
  WEATHER_STATION_APT_UPDATE=0     Same as --skip-apt-update.
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
    log "Installing weather station data directory initializer"
    require_file "${SCRIPT_DIR}/scripts/weather-station-init-data.sh"
    require_file "${SCRIPT_DIR}/systemd_services/weather-station-init-data.service"

    sudo install -m 0755 "${SCRIPT_DIR}/scripts/weather-station-init-data.sh" "$DATA_INIT"
    sudo install -m 0644 "${SCRIPT_DIR}/systemd_services/weather-station-init-data.service" /etc/systemd/system/weather-station-init-data.service
    sudo systemctl daemon-reload
    sudo systemctl enable weather-station-init-data.service
}

install_apt_packages() {
    log "Installing weather station apt packages"
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
        git \
        i2c-tools \
        python3-pil \
        python3-pip \
        python3-smbus \
        wget
}

install_python_packages() {
    log "Installing weather station pip packages"
    sudo python3 -m pip install --break-system-packages \
        astral \
        adafruit-circuitpython-ads1x15 \
        adafruit-circuitpython-bmp3xx \
        adafruit-circuitpython-sht31d \
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

    log "Installing weather station Witty Pi scripts"
    for script in beforeScript.sh afterStartup.sh runScript.sh beforeShutdown.sh; do
        require_file "${SCRIPT_DIR}/wittypi/${script}"
        sudo install -m 0755 "${SCRIPT_DIR}/wittypi/${script}" "${PI_HOME}/wittypi/${script}"
    done
    sudo chown pi:pi "${PI_HOME}/wittypi/"*.sh
    log "Witty Pi installed at ${PI_HOME}/wittypi"
}

install_weather_station_files() {
    log "Copying weather station application files"
    require_file "${SCRIPT_DIR}/weather_station.py"
    require_file "${SCRIPT_DIR}/sensors.py"
    require_file "${SCRIPT_DIR}/configs/weather_station_config.ini"
    require_file "${SCRIPT_DIR}/configs/schedule.conf"
    require_file "${SCRIPT_DIR}/schedule/generate_wittypi_schedule.py"
    require_file "${SCRIPT_DIR}/schedule/time_init.sh"

    sudo rm -rf "${PI_HOME}/weather_station"
    sudo cp -a "$SCRIPT_DIR" "${PI_HOME}/weather_station"
    sudo chown -R pi:pi "${PI_HOME}/weather_station"

    log "Preparing weather station data directory"
    sudo install -d -o pi -g pi -m 0755 \
        "$DATA_ROOT" \
        "${DATA_ROOT}/logs" \
        "${DATA_ROOT}/weather"
    if [[ ! -e "$DATA_CONFIG_DIR" ]]; then
        log "Copying default configs to ${DATA_CONFIG_DIR}"
        sudo install -d -o pi -g pi -m 0755 "$DATA_CONFIG_DIR"
        sudo cp -r "${SCRIPT_DIR}/configs/." "$DATA_CONFIG_DIR/"
        sudo chown -R pi:pi "$DATA_CONFIG_DIR"
    else
        log "Preserving existing ${DATA_CONFIG_DIR}"
    fi
}

install_boot_files() {
    log "Updating boot firmware files"
    require_file "${SCRIPT_DIR}/boot_firmware/config.txt"

    local boot_dir="/boot/firmware"
    if [[ ! -d "$boot_dir" ]]; then
        boot_dir="/boot"
    fi

    sudo install -m 0644 "${SCRIPT_DIR}/boot_firmware/config.txt" "${boot_dir}/config.txt"

    if ! sudo cmp -s "${SCRIPT_DIR}/boot_firmware/config.txt" "${boot_dir}/config.txt"; then
        echo "Failed to replace ${boot_dir}/config.txt" >&2
        exit 1
    fi
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
        if [[ "$service_name" == "weather-station.service" ]]; then
            sudo systemctl disable weather-station.service 2>/dev/null || true
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

    require_file "${SCRIPT_DIR}/configs/weather_station_config.ini"
    require_file "${SCRIPT_DIR}/configs/schedule.conf"

    install_data_initializer
    install_apt_packages
    install_python_packages
    install_wittypi
    install_weather_station_files
    install_boot_files
    install_systemd_services

    log "Weather station install complete"
    echo "Reboot before testing scheduled sensor logging."
}

main "$@"
