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
LV_SHUTDOWN_FILE="/home/pi/data/.wittypi_lv_shutdown"
I2C_CONF_POWER_ON_WHEN_POWER_CONNECTED=17
I2C_CONF_LOW_VOLTAGE_THRESHOLD=19
I2C_CONF_RECOVERY_VOLTAGE_THRESHOLD=22
I2C_ACTION_REASON=11
I2C_LV_SHUTDOWN=8

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

# Records two independent signals so beecam_capture_final.py can tell a
# deliberate human action (button click, cable/USB connected, plain reboot,
# normal scheduled alarm) apart from an automatic low-battery recovery, and
# hold off on starting the power-hungry camera/ML hardware only in the
# latter case:
#
#   1. Why Witty Pi woke up this boot (register 11 / I2C_ACTION_REASON).
#      0x05 (REASON_VOLTAGE_RESTORE) means input voltage was watched
#      crossing back above the recovery threshold after a low-voltage
#      cutoff, while staying continuously connected.
#   2. Whether Witty Pi's *previous* shutdown was caused by its own
#      low-voltage protection (register 8 / I2C_LV_SHUTDOWN). This is
#      decoupled from how fast the reconnect looked: on DC-regulator setups
#      where input voltage collapses straight to 0V rather than lingering
#      in the threshold band, a real low-battery event can end up reading
#      as an ordinary "power connected" wake (same as a manual unplug),
#      never producing 0x05 -- but Witty Pi's own decision to shut down for
#      low voltage still gets recorded here regardless of how the
#      subsequent reconnect looked.
#
# Both markers are always overwritten every boot -- unlike the
# .time_unknown marker, a stale value here must never be allowed to survive
# into a boot it doesn't describe, since that could wrongly delay (or
# wrongly skip delaying) camera startup. Any failure to read resolves to
# "unknown"/not-set, which downstream treats as "not a low-battery event" --
# the safe direction, since deliberate human wakes must never be delayed.
record_wittypi_power_event_flags() {
    local reason lv_shutdown

    mkdir -p "$(dirname "$WAKE_REASON_FILE")"

    if [[ ! -r "$WITTYPI_UTILS" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: missing ${WITTYPI_UTILS}; cannot read Witty Pi power event flags"
        echo "unknown" > "$WAKE_REASON_FILE"
        echo "unknown" > "$LV_SHUTDOWN_FILE"
        return 0
    fi

    # shellcheck disable=SC1090
    . "$WITTYPI_UTILS"

    set +e
    reason="$(i2c_read "$I2C_BUS" "$I2C_MC_ADDRESS" "$I2C_ACTION_REASON" 2>/dev/null)"
    lv_shutdown="$(i2c_read "$I2C_BUS" "$I2C_MC_ADDRESS" "$I2C_LV_SHUTDOWN" 2>/dev/null)"
    set -e

    if [[ -z "$reason" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: could not read Witty Pi wake reason (register ${I2C_ACTION_REASON})"
        echo "unknown" > "$WAKE_REASON_FILE"
    else
        echo "$reason" > "$WAKE_REASON_FILE"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: Witty Pi wake reason = ${reason} (written to ${WAKE_REASON_FILE})"
    fi

    if [[ -z "$lv_shutdown" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: could not read Witty Pi low-voltage-shutdown flag (register ${I2C_LV_SHUTDOWN})"
        echo "unknown" > "$LV_SHUTDOWN_FILE"
    else
        echo "$lv_shutdown" > "$LV_SHUTDOWN_FILE"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: Witty Pi previous-shutdown-was-low-voltage flag = ${lv_shutdown} (written to ${LV_SHUTDOWN_FILE})"
    fi
}

mkdir -p "$(dirname "$LOGFILE")"
exec >> "$LOGFILE" 2>&1

echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: started"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: recording Witty Pi power event flags"
record_wittypi_power_event_flags

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
