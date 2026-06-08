#!/usr/bin/env bash
set -euo pipefail

DATA_ROOT="/home/pi/data"
CONFIG_DIR="${DATA_ROOT}/configs"
SEED_CONFIG_DIR="/home/pi/setup/configs"
MARKER="${DATA_ROOT}/.beecam-data-initialized"

log() {
    echo "beecam-init-data: $*"
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
    "${DATA_ROOT}/images_and_labels"

if [[ -d "$SEED_CONFIG_DIR" && ! -e "$CONFIG_DIR" ]]; then
    log "copying default configs from ${SEED_CONFIG_DIR} to ${CONFIG_DIR}"
    install -d -o pi -g pi -m 0755 "$CONFIG_DIR"
    cp -r "${SEED_CONFIG_DIR}/." "$CONFIG_DIR/"
    chown -R pi:pi "$CONFIG_DIR"
elif [[ ! -e "$CONFIG_DIR" ]]; then
    log "default config directory ${SEED_CONFIG_DIR} was not found; ${CONFIG_DIR} was not created"
else
    log "existing ${CONFIG_DIR} found; leaving configs unchanged"
fi

touch "$MARKER"
chown pi:pi "$MARKER"
log "rootfs data directory is ready"
