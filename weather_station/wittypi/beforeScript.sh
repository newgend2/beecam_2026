#!/bin/bash
# file: beforeScript.sh
#
# This script runs before Witty Pi reads schedule.wpi.
# Use absolute paths because Witty Pi runs these scripts as root.

set -euo pipefail

/usr/local/sbin/weather-station-init-data.sh

VENV_PY="/usr/bin/python3"
LOGFILE="/data/logs/before_script.log"
SCHEDULE_FILE="/home/pi/wittypi/schedule.wpi"
GENERATOR="/home/pi/weather_station/schedule/generate_wittypi_schedule.py"

mkdir -p "$(dirname "$LOGFILE")"
exec >> "$LOGFILE" 2>&1

echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: started"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: running time_init.sh"
/home/pi/weather_station/schedule/time_init.sh

echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: generating schedule"
"$VENV_PY" "$GENERATOR"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: current schedule contents:"
cat "$SCHEDULE_FILE"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: finished"
