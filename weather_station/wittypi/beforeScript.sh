#!/bin/bash
# file: beforeScript.sh
#
# This script runs before Witty Pi reads schedule.wpi.
# Use absolute paths because Witty Pi runs these scripts as root.

set -euo pipefail

/usr/local/sbin/weather-station-init-data.sh

VENV_PY="/usr/bin/python3"
LOGFILE="/home/pi/data/logs/before_script.log"
CONFIG_FILE="/home/pi/data/configs/schedule.conf"
SCHEDULE_FILE="/home/pi/wittypi/schedule.wpi"
GENERATOR="/home/pi/weather_station/schedule/generate_wittypi_schedule.py"
WITTYPI_UTILS="/home/pi/wittypi/utilities.sh"

read_config_value() {
    local key="$1"
    awk -F= -v key="$key" '
        /^[[:space:]]*#/ { next }
        NF >= 2 {
            k = $1
            gsub(/^[ \t]+|[ \t]+$/, "", k)
            if (k == key) {
                v = $0
                sub(/^[^=]*=/, "", v)
                sub(/[[:space:]]+#.*$/, "", v)
                gsub(/^[ \t]+|[ \t]+$/, "", v)
                print v
                exit
            }
        }
    ' "$CONFIG_FILE" 2>/dev/null || true
}

apply_wittypi_power_settings() {
    local dummy_load before after

    dummy_load="$(read_config_value "WITTYPI_DUMMY_LOAD_DURATION")"
    if [[ -z "$dummy_load" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: no Witty Pi dummy-load setting in ${CONFIG_FILE}; leaving unchanged"
        return 0
    fi

    case "${dummy_load,,}" in
        disabled|disable|off|none)
            dummy_load=0
            ;;
    esac

    if ! [[ "$dummy_load" =~ ^[0-9]+$ ]] || (( dummy_load > 255 )); then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: invalid WITTYPI_DUMMY_LOAD_DURATION=${dummy_load}; expected 0-255"
        return 0
    fi

    if [[ ! -r "$WITTYPI_UTILS" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: missing ${WITTYPI_UTILS}; cannot apply Witty Pi power settings"
        return 0
    fi

    # shellcheck disable=SC1090
    . "$WITTYPI_UTILS"

    set +e
    before="$(i2c_read "$I2C_BUS" "$I2C_MC_ADDRESS" "$I2C_CONF_DUMMY_LOAD" 2>/dev/null)"
    i2c_write "$I2C_BUS" "$I2C_MC_ADDRESS" "$I2C_CONF_DUMMY_LOAD" "$dummy_load"
    after="$(i2c_read "$I2C_BUS" "$I2C_MC_ADDRESS" "$I2C_CONF_DUMMY_LOAD" 2>/dev/null)"
    set -e

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: Witty Pi dummy-load duration ${before:-unknown} -> ${after:-unknown} (requested ${dummy_load})"
}

mkdir -p "$(dirname "$LOGFILE")"
exec >> "$LOGFILE" 2>&1

echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: started"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: applying Witty Pi power settings"
apply_wittypi_power_settings

echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: running time_init.sh"
/home/pi/weather_station/schedule/time_init.sh

echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: generating schedule"
"$VENV_PY" "$GENERATOR"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: current schedule contents:"
cat "$SCHEDULE_FILE"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: finished"
