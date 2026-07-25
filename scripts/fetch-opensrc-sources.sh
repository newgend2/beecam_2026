#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Witty Pi 4 / 4 Mini (matches UUGear release track)
npx opensrc@0.6 uugear/Witty-Pi-4@V4.23 --modify
npx opensrc@0.6 uugear/UUGear-Web-Interface --modify

# Picamera2 / IMX500 (apt installs may differ; see references/external-docs.md)
PICAMERA2_TAG="${PICAMERA2_TAG:-v0.3.36}"
npx opensrc@0.6 "raspberrypi/picamera2@${PICAMERA2_TAG}" --modify
npx opensrc@0.6 raspberrypi/imx500-models --modify

echo "Upstream sources refreshed under opensrc/"
