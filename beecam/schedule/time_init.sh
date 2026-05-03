#!/bin/bash
set -euo pipefail

UTIL_DIR="/home/pi/wittypi"
TIMEZONE="America/Los_Angeles"
NTP_WAIT_SECONDS=20

if [ ! -f "$UTIL_DIR/utilities.sh" ]; then
    echo "ERROR: Missing $UTIL_DIR/utilities.sh"
    exit 1
fi

# shellcheck disable=SC1091
. "$UTIL_DIR/utilities.sh"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

wait_for_ntp_sync() {
    local i
    for ((i=0; i<NTP_WAIT_SECONDS; i++)); do
        if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo no)" = "yes" ]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

log "Starting time initialization"

# Set timezone for the system clock display/interpretation.
# Keep RTC interpreted as UTC (best practice on Linux).
log "Setting timezone to $TIMEZONE"
sudo timedatectl set-timezone "$TIMEZONE"
sudo timedatectl set-local-rtc 0 || true

# 1) First recover system time from DS3231
log "Setting system time from DS3231 (hwclock)"
if ! sudo hwclock --hctosys; then
    log "WARNING: hwclock --hctosys failed; continuing with current system time"
fi
# 2) Then sync Witty Pi RTC from system time
log "Syncing Witty Pi RTC from system time"
system_to_rtc

# 3) Try NTP
log "Enabling NTP"
sudo timedatectl set-ntp true

if wait_for_ntp_sync; then
    log "NTP synchronized successfully"

    # Push corrected system time back to all other clocks

    log "Writing system time to DS3231"
    if ! sudo hwclock --systohc; then
        log "WARNING: hwclock --systohc failed; continuing"
    fi

    log "Writing system time to Witty Pi RTC"
    system_to_rtc
else
    log "NTP not synchronized within ${NTP_WAIT_SECONDS}s; keeping RTC-derived time"
fi

log "Final times:"
echo "  System:  $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "  DS3231:  $(sudo hwclock -r 2>/dev/null || echo 'unavailable')"
echo "  WittyPi: $(get_rtc_time 2>/dev/null || echo 'unavailable')"
echo "  NTP synchronized: $(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo 'unknown')"
echo "  Timezone: $(timedatectl show -p Timezone --value 2>/dev/null || echo 'unknown')"
