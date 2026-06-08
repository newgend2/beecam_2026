#!/bin/bash
# file: afterStartup.sh
#
# This script will run after Raspberry Pi boot up and finish running the schedule script.
# If you want to run your commands after boot, you can place them here.
# 
# Remarks: please use absolute path of the command, or it can not be found (by root user).
# Remarks: you may append '&' at the end of command to avoid blocking the main daemon.sh.
#


if ! /usr/local/sbin/beecam-init-data.sh; then
    echo "afterStartup.sh: data directory initialization failed; not starting beecam.service" >&2
    exit 1
fi

/usr/bin/systemctl start beecam.service
