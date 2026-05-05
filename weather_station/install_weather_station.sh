#!/usr/bin/env bash
set -euo pipefail
trap 'echo "ERROR: install failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PI_HOME="/home/pi"
DATA_INIT="/usr/local/sbin/weather-station-init-data.sh"

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

install_data_initializer() {
    log "Installing DATA partition initializer"
    require_file "${SCRIPT_DIR}/scripts/weather-station-init-data.sh"
    require_file "${SCRIPT_DIR}/systemd_services/weather-station-init-data.service"

    sudo install -m 0755 "${SCRIPT_DIR}/scripts/weather-station-init-data.sh" "$DATA_INIT"
    sudo install -m 0644 "${SCRIPT_DIR}/systemd_services/weather-station-init-data.service" /etc/systemd/system/weather-station-init-data.service
    sudo systemctl daemon-reload
    sudo systemctl enable weather-station-init-data.service
}

install_apt_packages() {
    log "Installing weather station apt packages"
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        exfatprogs \
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

    if mountpoint -q /data; then
        log "Copying configs to mounted /data"
        sudo mkdir -p /data/configs /data/weather /data/logs
        sudo cp -a "${SCRIPT_DIR}/configs/." /data/configs/
    else
        warn "/data is not mounted; first boot will copy configs from ${SCRIPT_DIR}/configs."
        warn "Keep this repo at /home/pi/setup on the Pi."
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
