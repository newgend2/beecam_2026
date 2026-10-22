#!/usr/bin/env bash
# Copy-only BeeCam transfer: transfer_beecam.sh with --no-clear --yes, so the card's data is
# zipped and verified but never cleared. --clear-after-verify restores transfer_beecam.sh's
# default (clear only after verification passes); --skip-unreadable is passed through.
#
#   sudo ./transfer_beecam_copyonly.sh [--clear-after-verify | --skip-unreadable] [source] <dest>
set -euo pipefail
args=()
clear=false
for a in "$@"; do
    if [[ "$a" == "--clear-after-verify" ]]; then clear=true; else args+=("$a"); fi
done
$clear || args=(--no-clear "${args[@]}")
exec bash "$(dirname "$(readlink -f "$0")")/transfer_beecam.sh" --yes "${args[@]}"
