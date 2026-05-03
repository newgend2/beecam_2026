#!/usr/bin/env bash
set -euo pipefail

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

install_partition_tools() {
    log "Installing partition and mount tools"
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        exfatprogs \
        parted \
        util-linux
}

install_data_initializer() {
    log "Installing DATA partition initializer"
    require_file "${SCRIPT_DIR}/scripts/beecam-init-data.sh"
    require_file "${SCRIPT_DIR}/systemd_services/beecam-init-data.service"

    sudo install -m 0755 "${SCRIPT_DIR}/scripts/beecam-init-data.sh" "$DATA_INIT"
    sudo install -m 0644 "${SCRIPT_DIR}/systemd_services/beecam-init-data.service" /etc/systemd/system/beecam-init-data.service
    sudo systemctl daemon-reload
    sudo systemctl enable beecam-init-data.service

    log "Attempting to initialize /data now"
    if sudo "$DATA_INIT"; then
        log "/data is ready"
    else
        warn "/data could not be created while booted from this card."
        warn "This is expected if Raspberry Pi OS expanded root to fill the SD card."
        warn "The golden-image workflow should shrink/truncate offline, then beecam-init-data.service will create /data on first boot."
    fi
}

install_apt_packages() {
    log "Installing BeeCam apt packages"
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        feh \
        fbi \
        git \
        i2c-tools \
        imx500-all \
        python3-dev \
        python3-munkres \
        python3-opencv \
        python3-pip \
        python3-smbus \
        wget
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        python3-picamera2
}

make_pip_requirements() {
    local req_file
    req_file="$(mktemp)"

    awk '
        BEGIN {
            skip["av"] = 1
            skip["munkres"] = 1
            skip["numpy"] = 1
            skip["picamera2"] = 1
            skip["pip"] = 1
            skip["python-apt"] = 1
            skip["setuptools"] = 1
            skip["wheel"] = 1
        }
        NR <= 2 { next }
        NF < 2 { next }
        $1 ~ /^-+$/ { next }
        {
            name = $1
            version = $2
            key = tolower(name)
            if (key in skip) {
                next
            }
            print name "==" version
        }
    ' "${SCRIPT_DIR}/PIP_LIST.txt" > "$req_file"

    echo "$req_file"
}

install_python_packages() {
    log "Installing Python packages from PIP_LIST.txt"
    require_file "${SCRIPT_DIR}/PIP_LIST.txt"

    local req_file
    req_file="$(make_pip_requirements)"
    sudo python3 -m pip install --break-system-packages -r "$req_file"
    rm -f "$req_file"
}

install_wittypi() {
    log "Installing Witty Pi software"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    wget -O "${tmp_dir}/install.sh" https://www.uugear.com/repo/WittyPi4/install.sh
    (cd "$tmp_dir" && sudo sh install.sh)
    rm -rf "$tmp_dir"

    if [[ ! -d "${PI_HOME}/wittypi" ]]; then
        echo "Expected ${PI_HOME}/wittypi after Witty Pi install, but it was not found." >&2
        exit 1
    fi

    log "Installing BeeCam Witty Pi scripts"
    for script in beforeScript.sh afterStartup.sh runScript.sh beforeShutdown.sh; do
        require_file "${SCRIPT_DIR}/wittypi/${script}"
        sudo install -m 0755 "${SCRIPT_DIR}/wittypi/${script}" "${PI_HOME}/wittypi/${script}"
    done
    sudo chown pi:pi "${PI_HOME}/wittypi/"*.sh
}

install_beecam_files() {
    log "Copying BeeCam application files"
    require_file "${SCRIPT_DIR}/beecam"
    sudo rm -rf "${PI_HOME}/beecam"
    sudo cp -a "${SCRIPT_DIR}/beecam" "${PI_HOME}/beecam"
    sudo chown -R pi:pi "${PI_HOME}/beecam"

    log "Installing default DATA configs on root"
    sudo mkdir -p /opt/beecam/default-data/configs
    sudo cp -a "${SCRIPT_DIR}/configs/." /opt/beecam/default-data/configs/

    if mountpoint -q /data; then
        log "Copying configs to mounted /data"
        sudo mkdir -p /data/configs
        sudo cp -a "${SCRIPT_DIR}/configs/." /data/configs/
    else
        warn "/data is not mounted; configs are staged in /opt/beecam/default-data/configs for first boot."
    fi
}

install_boot_files() {
    log "Updating boot firmware files"
    require_file "${SCRIPT_DIR}/boot_firmware/config.txt"

    if ! grep -q "$VIDEO_ARG" /boot/firmware/cmdline.txt; then
        sudo sed -i "1 s/$/ ${VIDEO_ARG}/" /boot/firmware/cmdline.txt
    fi

    sudo install -m 0644 "${SCRIPT_DIR}/boot_firmware/config.txt" /boot/firmware/config.txt
}

install_systemd_services() {
    log "Installing systemd services"
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
}

main() {
    if [[ "$(id -u)" -eq 0 ]]; then
        echo "Run this script as the pi user, not with sudo. It will call sudo when needed." >&2
        exit 1
    fi

    require_file "${SCRIPT_DIR}/PIP_LIST.txt"
    require_file "${SCRIPT_DIR}/configs/camera_config_final.ini"
    require_file "${SCRIPT_DIR}/configs/schedule.conf"

    install_partition_tools
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
