# Beecam Project Instructions

## Project Context

This repo supports the Beecam 2026 Raspberry Pi setup, including SD card prep, install scripts, systemd services, camera and schedule code, and weather station code.



## Important Files/Folders

- `beecam_install.sh`: main install/setup script.
- `weather_station/`: weather station code and services.
- `beecam/camera`: camera-related code.
- `beecam/schedule`: schedule-related code.


## Working Rules

- Prefer small, reversible changes.
- Do not run destructive disk commands unless explicitly asked.
- When editing install or SD card scripts, explain the risk and verification path.
- Preserve user edits in the working tree.

## Historical Fix Preservation

- For prior fixes and design decisions, read `references/chat_history/README.md`.
- Before editing capture, preview, Witty Pi schedule, offline update, transfer, install, or data-directory init logic, check the protected-fix summary in `references/chat_history/README.md`.
- Do not accidentally remove these protected behaviors:
  - class-aware NMS in the non-Nanodet YOLO path before stale detection;
  - model captures saving the main buffer from the same completed preview/lores request;
  - stale detection without periodic refresh captures or confidence-jump reactivation;
  - Witty Pi `WAIT` states skipping externally managed schedule endpoints;
  - BeeCam and weather-station runtime storage rooted at `/home/pi/data`;
  - `offline_update` working over SSH/rsync without camera-side internet;
  - transfer archives using store-only zip with `unzip -t` verification before deletion;
  - transfer cleanup of `images_and_labels/`, `logs/`, `update_backups/`, and `.Trash-*`, followed by sync and rootfs unmount;
  - BeeCam install keeping `apt-get full-upgrade` opt-in, not default;
  - first-boot config seeding that does not overwrite existing `/home/pi/data/configs`.
- The older separate-partition guardrails were intentionally superseded by the rootfs data-directory migration.
- If a requested change conflicts with a protected behavior, call that out before editing.

## Verification

- For shell scripts, run syntax checks when practical:
  `bash -n script_name.sh`
- For service/config changes, describe how to verify on the Raspberry Pi.
