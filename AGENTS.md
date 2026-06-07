# Beecam Project Instructions

## Project Context

This repo supports the Beecam 2026 Raspberry Pi setup, including SD card prep, install scripts, systemd services, camera and schedule code, and weather station code.



## Important Files/Folders

- `beecam_install.sh`: main install/setup script.
- `prep_beecam_sd_on_pc.sh`: SD card preparation script.
- `weather_station/`: weather station code and services.
- `beecam/camera`: camera-related code.
- `beecam/schedule`: schedule-related code.


## Working Rules

- Prefer small, reversible changes.
- Do not run destructive disk commands unless explicitly asked.
- When editing install or SD card scripts, explain the risk and verification path.
- Preserve user edits in the working tree.

## Verification

- For shell scripts, run syntax checks when practical:
  `bash -n script_name.sh`
- For service/config changes, describe how to verify on the Raspberry Pi.