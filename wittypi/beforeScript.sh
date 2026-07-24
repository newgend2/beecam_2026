#!/bin/bash
# file: beforeScript.sh
#
# This script will run after Raspberry Pi boot up, and before running the schedule script.
# If you want to change the schedule script before running it, you may do so here.
#
# Remarks: please use absolute path of the command, or it can not be found (by root user).
# Remarks: you may append '&' at the end of command to avoid blocking the main daemon.sh.
#

#!/bin/bash
set -euo pipefail

/usr/local/sbin/beecam-init-data.sh

VENV_PY="/usr/bin/python3"
LOGFILE="/home/pi/data/logs/before_script.log"
CONFIG_FILE="/home/pi/data/configs/schedule.conf"
SCHEDULE_FILE="/home/pi/wittypi/schedule.wpi"
GENERATOR="/home/pi/beecam/schedule/generate_wittypi_schedule.py"
WITTYPI_UTILS="/home/pi/wittypi/utilities.sh"
WAKE_REASON_FILE="/home/pi/data/.wake_reason"
I2C_CONF_POWER_ON_WHEN_POWER_CONNECTED=17
I2C_CONF_LOW_VOLTAGE_THRESHOLD=19
I2C_CONF_RECOVERY_VOLTAGE_THRESHOLD=22
I2C_ACTION_REASON=11

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
    local dummy_load power_on_return before after

    dummy_load="$(read_config_value "WITTYPI_DUMMY_LOAD_DURATION")"
    power_on_return="$(read_config_value "WITTYPI_POWER_ON_WHEN_POWER_CONNECTED")"

    if [[ ! -r "$WITTYPI_UTILS" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: missing ${WITTYPI_UTILS}; cannot apply Witty Pi power settings"
        return 0
    fi

    # shellcheck disable=SC1090
    . "$WITTYPI_UTILS"

    if [[ -z "$dummy_load" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: no Witty Pi dummy-load setting in ${CONFIG_FILE}; leaving unchanged"
    else
        case "${dummy_load,,}" in
            disabled|disable|off|none)
                dummy_load=0
                ;;
        esac

        if ! [[ "$dummy_load" =~ ^[0-9]+$ ]] || (( dummy_load > 255 )); then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: invalid WITTYPI_DUMMY_LOAD_DURATION=${dummy_load}; expected 0-255"
        else
            set +e
            before="$(i2c_read "$I2C_BUS" "$I2C_MC_ADDRESS" "$I2C_CONF_DUMMY_LOAD" 2>/dev/null)"
            i2c_write "$I2C_BUS" "$I2C_MC_ADDRESS" "$I2C_CONF_DUMMY_LOAD" "$dummy_load"
            after="$(i2c_read "$I2C_BUS" "$I2C_MC_ADDRESS" "$I2C_CONF_DUMMY_LOAD" 2>/dev/null)"
            set -e
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: Witty Pi dummy-load duration ${before:-unknown} -> ${after:-unknown} (requested ${dummy_load})"
        fi
    fi

    if [[ -z "$power_on_return" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: no Witty Pi power-on-return setting in ${CONFIG_FILE}; leaving unchanged"
        return 0
    fi

    case "${power_on_return,,}" in
        1|true|yes|on|enabled|enable)
            power_on_return=1
            ;;
        0|false|no|off|disabled|disable)
            power_on_return=0
            ;;
        *)
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: invalid WITTYPI_POWER_ON_WHEN_POWER_CONNECTED=${power_on_return}; expected 0/1"
            return 0
            ;;
    esac

    set +e
    before="$(i2c_read "$I2C_BUS" "$I2C_MC_ADDRESS" "$I2C_CONF_POWER_ON_WHEN_POWER_CONNECTED" 2>/dev/null)"
    i2c_write "$I2C_BUS" "$I2C_MC_ADDRESS" "$I2C_CONF_POWER_ON_WHEN_POWER_CONNECTED" "$power_on_return"
    after="$(i2c_read "$I2C_BUS" "$I2C_MC_ADDRESS" "$I2C_CONF_POWER_ON_WHEN_POWER_CONNECTED" 2>/dev/null)"
    set -e
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: Witty Pi power-on-5V-return ${before:-unknown} -> ${after:-unknown} (requested ${power_on_return})"
}

apply_voltage_threshold() {
    local label="$1" cfg_key="$2" register="$3" raw reg before after

    raw="$(read_config_value "$cfg_key")"
    if [[ -z "$raw" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: no ${label} setting in ${CONFIG_FILE}; leaving unchanged"
        return 0
    fi

    case "${raw,,}" in
        0|0.0|disabled|disable|off|none)
            reg=255
            ;;
        *)
            if ! [[ "$raw" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: invalid ${cfg_key}=${raw}; expected a voltage 0-25.0 or 0/disabled"
                return 0
            fi
            reg="$(awk -v v="$raw" 'BEGIN { printf "%d", (v * 10) + 0.5 }')"
            if (( reg > 250 )); then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: ${cfg_key}=${raw} out of range (max 25.0V); leaving unchanged"
                return 0
            fi
            ;;
    esac

    set +e
    before="$(i2c_read "$I2C_BUS" "$I2C_MC_ADDRESS" "$register" 2>/dev/null)"
    i2c_write "$I2C_BUS" "$I2C_MC_ADDRESS" "$register" "$reg"
    after="$(i2c_read "$I2C_BUS" "$I2C_MC_ADDRESS" "$register" 2>/dev/null)"
    set -e
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: Witty Pi ${label} ${before:-unknown} -> ${after:-unknown} (requested ${raw} -> reg ${reg})"
}

apply_wittypi_voltage_thresholds() {
    if [[ ! -r "$WITTYPI_UTILS" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: missing ${WITTYPI_UTILS}; cannot apply Witty Pi voltage thresholds"
        return 0
    fi

    # shellcheck disable=SC1090
    . "$WITTYPI_UTILS"

    apply_voltage_threshold "low-voltage threshold" "WITTYPI_LOW_VOLTAGE_THRESHOLD" "$I2C_CONF_LOW_VOLTAGE_THRESHOLD"
    apply_voltage_threshold "recovery-voltage threshold" "WITTYPI_RECOVERY_VOLTAGE_THRESHOLD" "$I2C_CONF_RECOVERY_VOLTAGE_THRESHOLD"
}

# Records why Witty Pi woke up this boot (register 11 / I2C_ACTION_REASON),
# so beecam_capture_final.py can tell a deliberate human action (button
# click, cable/USB connected, plain reboot, normal scheduled alarm) apart
# from an automatic low-voltage recovery wake (0x05), and hold off on
# starting the power-hungry camera/ML hardware only in the latter case.
# Always overwrites the marker every boot -- unlike the .time_unknown
# marker, a stale value here must never be allowed to survive into a boot
# it doesn't describe, since that could wrongly delay (or wrongly skip
# delaying) camera startup. Any failure to read resolves to "unknown",
# which downstream treats as "not a low-voltage recovery" -- the safe
# direction, since deliberate human wakes must never be delayed.
record_wittypi_wake_reason() {
    local reason

    mkdir -p "$(dirname "$WAKE_REASON_FILE")"

    if [[ ! -r "$WITTYPI_UTILS" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: missing ${WITTYPI_UTILS}; cannot read Witty Pi wake reason"
        echo "unknown" > "$WAKE_REASON_FILE"
        return 0
    fi

    # shellcheck disable=SC1090
    . "$WITTYPI_UTILS"

    set +e
    reason="$(i2c_read "$I2C_BUS" "$I2C_MC_ADDRESS" "$I2C_ACTION_REASON" 2>/dev/null)"
    set -e

    if [[ -z "$reason" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: could not read Witty Pi wake reason (register ${I2C_ACTION_REASON})"
        echo "unknown" > "$WAKE_REASON_FILE"
        return 0
    fi

    echo "$reason" > "$WAKE_REASON_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: Witty Pi wake reason = ${reason} (written to ${WAKE_REASON_FILE})"
}

mkdir -p "$(dirname "$LOGFILE")"
exec >> "$LOGFILE" 2>&1

echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: started"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: recording Witty Pi wake reason"
record_wittypi_wake_reason

echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: applying Witty Pi power settings"
apply_wittypi_power_settings

echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: applying Witty Pi voltage thresholds"
apply_wittypi_voltage_thresholds

echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: running time_init.sh"
if ! /home/pi/beecam/schedule/time_init.sh; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: time_init.sh failed; continuing with current system/RTC time so the schedule still gets (re)armed"
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: generating schedule"
"$VENV_PY" "$GENERATOR"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: current schedule contents:"
cat "$SCHEDULE_FILE"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: finished"
