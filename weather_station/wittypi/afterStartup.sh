#!/bin/bash
# file: afterStartup.sh
#
# This script runs after Raspberry Pi boot and Witty Pi schedule handling.
# Use absolute paths because Witty Pi runs these scripts as root.

/usr/local/sbin/weather-station-init-data.sh
/usr/bin/systemctl start weather-station.service
