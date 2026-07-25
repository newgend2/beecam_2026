#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

npx opensrc@0.6 uugear/Witty-Pi-4@V4.23 --modify
npx opensrc@0.6 uugear/UUGear-Web-Interface --modify

echo "Upstream sources refreshed under opensrc/"
