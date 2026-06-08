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
SCHEDULE_FILE="/home/pi/wittypi/schedule.wpi"
GENERATOR="/home/pi/beecam/schedule/generate_wittypi_schedule.py"

mkdir -p "$(dirname "$LOGFILE")"
exec >> "$LOGFILE" 2>&1

echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: started"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: running time_init.sh"
/home/pi/beecam/schedule/time_init.sh

echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: generating schedule"
"$VENV_PY" "$GENERATOR"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: current schedule contents:"
cat "$SCHEDULE_FILE"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] beforeScript: finished"
