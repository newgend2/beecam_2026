#!/usr/bin/env bash
set -euo pipefail

DATA_ROOT="/home/pi/data"
CONFIG_DIR="${DATA_ROOT}/configs"
MARKER="${DATA_ROOT}/.weather-station-data-initialized"
SEED_CONFIG_DIRS=(
    "/home/pi/setup/weather_station/configs"
    "/home/pi/weather_station/configs"
)

log() {
    echo "weather-station-init-data: $*"
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log "missing required command: $1"
        exit 1
    fi
}

require_cmd cp
require_cmd install

install -d -o pi -g pi -m 0755 \
    "$DATA_ROOT" \
    "${DATA_ROOT}/logs" \
    "${DATA_ROOT}/weather"

SEEDED_CONFIGS=false
if [[ ! -e "$CONFIG_DIR" ]]; then
    for seed_dir in "${SEED_CONFIG_DIRS[@]}"; do
        if [[ -d "$seed_dir" ]]; then
            log "copying default configs from ${seed_dir} to ${CONFIG_DIR}"
            install -d -o pi -g pi -m 0755 "$CONFIG_DIR"
            cp -r "${seed_dir}/." "$CONFIG_DIR/"
            chown -R pi:pi "$CONFIG_DIR"
            SEEDED_CONFIGS=true
            break
        fi
    done
fi

if [[ ! -e "$CONFIG_DIR" ]]; then
    log "no default config directory was found; ${CONFIG_DIR} was not created"
elif [[ "$SEEDED_CONFIGS" == "false" ]]; then
    log "existing ${CONFIG_DIR} found; leaving configs unchanged"
fi

touch "$MARKER"
chown pi:pi "$MARKER"
log "rootfs data directory is ready"
