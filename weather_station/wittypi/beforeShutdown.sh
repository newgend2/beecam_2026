#!/bin/bash
# file: beforeShutdown.sh
#
# This script runs after Witty Pi receives the shutdown command.

/usr/bin/systemctl is-active --quiet weather-station.service && /usr/bin/systemctl stop weather-station.service
