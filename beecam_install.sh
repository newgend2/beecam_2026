#!/usr/bin/env bash
set -euo pipefail
trap 'echo "ERROR: install failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PI_HOME="/home/pi"
DATA_INIT="/usr/local/sbin/beecam-init-data.sh"
VIDEO_ARG="video=HDMI-A-1:800x480@60D"

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
    require_file "${SCRIPT_DIR}/scripts/beecam-init-data.sh"
    require_file "${SCRIPT_DIR}/systemd_services/beecam-init-data.service"

    sudo install -m 0755 "${SCRIPT_DIR}/scripts/beecam-init-data.sh" "$DATA_INIT"
    sudo install -m 0644 "${SCRIPT_DIR}/systemd_services/beecam-init-data.service" /etc/systemd/system/beecam-init-data.service
    sudo systemctl daemon-reload
    sudo systemctl enable beecam-init-data.service
}

install_apt_packages() {
    log "Installing BeeCam apt packages"
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
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
    sudo chown -R pi:pi "${PI_HOME}/beecam"

    if mountpoint -q /data; then
        log "Copying configs to mounted /data"
        sudo mkdir -p /data/configs
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

    require_file "${boot_dir}/cmdline.txt"

    if ! grep -Fq "$VIDEO_ARG" "${boot_dir}/cmdline.txt"; then
        sudo sed -i "1 s/$/ ${VIDEO_ARG}/" "${boot_dir}/cmdline.txt"
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
        if [[ "$service_name" == "beecam.service" ]]; then
            sudo systemctl disable beecam.service 2>/dev/null || true
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

    require_file "${SCRIPT_DIR}/configs/camera_config_final.ini"
    require_file "${SCRIPT_DIR}/configs/schedule.conf"

    install_data_initializer
    install_apt_packages
    install_python_packages
    install_wittypi
    install_beecam_files
    install_boot_files
    install_systemd_services

    log "BeeCam install complete"
    echo "Reboot before testing camera startup."
}

main "$@"
