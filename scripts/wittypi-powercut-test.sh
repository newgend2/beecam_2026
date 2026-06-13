#!/usr/bin/env bash
set -euo pipefail

WITTY_DIR="/home/pi/wittypi"
SCHEDULE_FILE="${WITTY_DIR}/schedule.wpi"
RUN_SCRIPT="${WITTY_DIR}/runScript.sh"
DATA_ROOT="/home/pi/data"
LOG_DIR="${DATA_ROOT}/logs/wittypi_powercut_tests"
BACKUP_DIR="${DATA_ROOT}/update_backups/wittypi_powercut_tests"

SHUTDOWN_DELAY_SEC=180
OFF_DURATION_SEC=300
END_PADDING_SEC=120
DRY_RUN=false
RESTORE=false
ORIGINAL_ARGS=("$@")

usage() {
    cat <<'USAGE'
Usage:
  sudo scripts/wittypi-powercut-test.sh [options]

Options:
  --shutdown-delay-sec N   Seconds from now until Witty Pi shutdown. Default: 180.
  --off-duration-sec N     Seconds between shutdown and startup. Default: 300.
  --end-padding-sec N      Extra schedule window after startup. Default: 120.
  --dry-run                Print the test schedule but do not install or arm it.
  --restore                Restore the newest schedule backup and re-arm Witty Pi.
  -h, --help               Show this help.

This writes /home/pi/wittypi/schedule.wpi, runs Witty Pi's normal runScript.sh,
and logs the expected shutdown/startup times under /home/pi/data/logs.
USAGE
}

die() {
    echo "Error: $*" >&2
    exit 1
}

need_file() {
    [[ -e "$1" ]] || die "Missing required file: $1"
}

need_positive_int() {
    local name="$1"
    local value="$2"
    [[ "$value" =~ ^[0-9]+$ && "$value" -gt 0 ]] || die "${name} must be a positive integer"
}

check_clock() {
    local year
    year="$(date '+%Y')"
    [[ "$year" =~ ^[0-9]+$ ]] || die "Could not read system clock year"
    (( year >= 2024 )) || die "System clock looks wrong (${year}); initialize time before arming a Witty Pi schedule test."
}

fmt_ts() {
    date -d "@$1" '+%Y-%m-%d %H:%M:%S'
}

duration_tokens() {
    local total="$1"
    local days hours minutes seconds
    local parts=()

    days=$((total / 86400))
    total=$((total % 86400))
    hours=$((total / 3600))
    total=$((total % 3600))
    minutes=$((total / 60))
    seconds=$((total % 60))

    (( days > 0 )) && parts+=("D${days}")
    (( hours > 0 )) && parts+=("H${hours}")
    (( minutes > 0 )) && parts+=("M${minutes}")
    if (( seconds > 0 || ${#parts[@]} == 0 )); then
        parts+=("S${seconds}")
    fi

    printf '%s\n' "${parts[*]}"
}

run_as_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            exec sudo "$0" "$@"
        fi
        die "Run as root, or install sudo."
    fi
}

latest_backup() {
    find "$BACKUP_DIR" -maxdepth 1 -type f -name 'schedule.wpi.*' 2>/dev/null \
        | sort \
        | tail -n 1
}

restore_schedule() {
    local backup log_file

    need_file "$RUN_SCRIPT"
    mkdir -p "$LOG_DIR"
    backup="$(latest_backup)"
    [[ -n "$backup" ]] || die "No schedule backups found in ${BACKUP_DIR}"

    log_file="${LOG_DIR}/restore_$(date '+%Y%m%d_%H%M%S').log"
    cp "$backup" "$SCHEDULE_FILE"
    chown pi:pi "$SCHEDULE_FILE" 2>/dev/null || true

    {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Restored $SCHEDULE_FILE from $backup"
        echo "Re-arming Witty Pi with restored schedule:"
        "$RUN_SCRIPT"
    } | tee -a "$log_file"

    echo
    echo "Restored schedule and re-armed Witty Pi."
    echo "Log: $log_file"
}

write_and_arm_test() {
    local now shutdown startup end schedule_text tmp backup log_file

    need_positive_int "--shutdown-delay-sec" "$SHUTDOWN_DELAY_SEC"
    need_positive_int "--off-duration-sec" "$OFF_DURATION_SEC"
    need_positive_int "--end-padding-sec" "$END_PADDING_SEC"
    check_clock

    now="$(date +%s)"
    shutdown=$((now + SHUTDOWN_DELAY_SEC))
    startup=$((shutdown + OFF_DURATION_SEC))
    end=$((startup + END_PADDING_SEC))

    schedule_text="$(cat <<EOF
# Auto-generated Witty Pi power-cut survival test
# Generated at: $(fmt_ts "$now")
# Shutdown at:  $(fmt_ts "$shutdown")
# Startup at:   $(fmt_ts "$startup")
# Test:
#   1. Let Witty Pi shut the Pi down at the shutdown time.
#   2. During the OFF interval, cut upstream power to Witty Pi/regulator.
#   3. Restore upstream power before the startup time.
#   4. Confirm whether the Pi boots at the startup time.
BEGIN $(fmt_ts "$now")
END   $(fmt_ts "$end")
ON    $(duration_tokens "$SHUTDOWN_DELAY_SEC")
OFF   $(duration_tokens "$OFF_DURATION_SEC")
EOF
)"

    if $DRY_RUN; then
        printf '%s\n' "$schedule_text"
        return 0
    fi

    need_file "$RUN_SCRIPT"
    mkdir -p "$LOG_DIR" "$BACKUP_DIR"

    if [[ -f "$SCHEDULE_FILE" ]]; then
        backup="${BACKUP_DIR}/schedule.wpi.$(date '+%Y%m%d_%H%M%S')"
        cp "$SCHEDULE_FILE" "$backup"
        chown pi:pi "$backup" 2>/dev/null || true
    else
        backup="none"
    fi

    tmp="$(mktemp)"
    printf '%s\n' "$schedule_text" > "$tmp"
    install -m 0644 "$tmp" "$SCHEDULE_FILE"
    rm -f "$tmp"
    chown pi:pi "$SCHEDULE_FILE" 2>/dev/null || true

    log_file="${LOG_DIR}/test_$(date '+%Y%m%d_%H%M%S').log"
    {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Witty Pi power-cut survival test"
        echo "Backup:   $backup"
        echo "Schedule: $SCHEDULE_FILE"
        echo
        cat "$SCHEDULE_FILE"
        echo
        echo "Arming Witty Pi with runScript.sh:"
        "$RUN_SCRIPT"
    } | tee -a "$log_file"

    echo
    echo "Power-cut schedule test armed."
    echo "  Shutdown: $(fmt_ts "$shutdown")"
    echo "  Startup:  $(fmt_ts "$startup")"
    echo "  Log:      $log_file"
    echo
    echo "Recommended test:"
    echo "  1. Keep power connected until the Pi shuts down at the shutdown time."
    echo "  2. After the Pi is off, cut upstream power to the Witty Pi/regulator."
    echo "  3. Re-enable upstream power before the startup time."
    echo "  4. Watch whether Witty Pi keeps the Pi off, then boots it at startup."
    echo
    echo "Do not run /home/pi/wittypi/beforeScript.sh during the test; it regenerates the normal schedule."
    echo "Normal BeeCam scheduling will be regenerated on the next Witty Pi-managed boot."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --shutdown-delay-sec)
            [[ $# -ge 2 ]] || die "--shutdown-delay-sec requires a value"
            SHUTDOWN_DELAY_SEC="$2"
            shift 2
            ;;
        --off-duration-sec)
            [[ $# -ge 2 ]] || die "--off-duration-sec requires a value"
            OFF_DURATION_SEC="$2"
            shift 2
            ;;
        --end-padding-sec)
            [[ $# -ge 2 ]] || die "--end-padding-sec requires a value"
            END_PADDING_SEC="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --restore)
            RESTORE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

if ! $DRY_RUN; then
    run_as_root "${ORIGINAL_ARGS[@]}"
fi

if $RESTORE; then
    restore_schedule
else
    write_and_arm_test
fi
