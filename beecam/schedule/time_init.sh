#!/bin/bash
set -euo pipefail

UTIL_DIR="/home/pi/wittypi"
TIMEZONE="America/Los_Angeles"
NTP_WAIT_SECONDS=20
WITTYPI_LOG="${UTIL_DIR}/wittyPi.log"
TIME_UNKNOWN_MARKER="/home/pi/data/.time_unknown"

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

wired_link_up() {
    local carrier
    for carrier in /sys/class/net/eth*/carrier /sys/class/net/en*/carrier; do
        if [ -r "$carrier" ] && [ "$(cat "$carrier" 2>/dev/null || echo 0)" = "1" ]; then
            return 0
        fi
    done
    return 1
}

# Witty Pi's daemon.sh runs its own RTC-vs-system time reconciliation before
# beforeScript.sh (and therefore this script) ever runs. If its RTC read came
# back with a zero year -- which is what happens once the onboard supercap
# (rated for ~17h of backup) has been depleted by a long power outage -- it
# logs "RTC has bad time" and instead trusts (uncertain) system time into the
# RTC. By the time we get here that has already overwritten the RTC's bad
# year, so we can't detect it by re-reading the RTC ourselves; the verdict
# only exists in this boot's daemon.sh log lines, which is why we check there.
#
# On its own this only means Witty Pi's onboard clock is stale -- it does NOT
# mean the system clock is wrong, because the DS3231 module (much longer
# battery retention than the ~17h onboard supercap) still gets a chance to
# correct it via hwclock below. TIME_UNKNOWN is only set if that recovery
# also fails to produce a trustworthy time.
pcf_rtc_was_bad_this_boot() {
    local recent last_start last_bad

    [ -r "$WITTYPI_LOG" ] || return 1

    set +e
    recent="$(tail -n 40 "$WITTYPI_LOG" 2>/dev/null)"
    last_start="$(grep -n "daemon.*is started" <<<"$recent" | tail -n1 | cut -d: -f1)"
    last_bad="$(grep -n "RTC has bad time" <<<"$recent" | tail -n1 | cut -d: -f1)"
    set -e

    [ -n "$last_start" ] && [ -n "$last_bad" ] && [ "$last_bad" -gt "$last_start" ]
}

log "Starting time initialization"

pcf_was_bad=0
if pcf_rtc_was_bad_this_boot; then
    pcf_was_bad=1
    log "NOTE: Witty Pi's onboard RTC had a bad time this boot (outage likely exceeded its ~17h backup); expecting the DS3231 (or NTP) below to correct it."
fi

# Set timezone for the system clock display/interpretation.
# Keep RTC interpreted as UTC (best practice on Linux).
log "Setting timezone to $TIMEZONE"
sudo timedatectl set-timezone "$TIMEZONE"
sudo timedatectl set-local-rtc 0 || true

# 1) First recover system time from DS3231. This is the long-retention
# source (battery-backed, years not hours), so it's worth a couple of
# retries against a transient I2C hiccup rather than accepting the first
# failure -- especially right after an extended outage, when it matters most.
ds3231_ok=0
log "Setting system time from DS3231 (hwclock)"
for attempt in 1 2 3; do
    if sudo hwclock --hctosys; then
        ds3231_ok=1
        break
    fi
    log "WARNING: hwclock --hctosys failed (attempt ${attempt}/3)"
    sleep 1
done
# 2) Then sync Witty Pi RTC from system time
log "Syncing Witty Pi RTC from system time"
system_to_rtc

# 3) Try NTP
log "Enabling NTP"
sudo timedatectl set-ntp true

ntp_ok=0
if ! wired_link_up; then
    log "No wired Ethernet link detected; skipping NTP wait and keeping RTC-derived time"
elif wait_for_ntp_sync; then
    log "NTP synchronized successfully"
    ntp_ok=1

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

# Only flag the clock as genuinely untrustworthy if every source failed this
# boot: Witty Pi's own RTC was bad AND the DS3231 read failed AND no NTP fix
# arrived. If the DS3231 (or NTP) came through, system time is fine even
# though Witty Pi's onboard RTC alone had lost track of time.
if [ "$pcf_was_bad" = "1" ] && [ "$ds3231_ok" = "0" ] && [ "$ntp_ok" = "0" ]; then
    log "WARNING: no trustworthy time source this boot (Witty Pi RTC bad, DS3231 read failed, no NTP). Marking ${TIME_UNKNOWN_MARKER}."
    mkdir -p "$(dirname "$TIME_UNKNOWN_MARKER")"
    touch "$TIME_UNKNOWN_MARKER"
else
    rm -f "$TIME_UNKNOWN_MARKER"
fi

log "Final times:"
echo "  System:  $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "  DS3231:  $(sudo hwclock -r 2>/dev/null || echo 'unavailable')"
echo "  WittyPi: $(get_rtc_time 2>/dev/null || echo 'unavailable')"
echo "  NTP synchronized: $(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo 'unknown')"
echo "  Timezone: $(timedatectl show -p Timezone --value 2>/dev/null || echo 'unknown')"
