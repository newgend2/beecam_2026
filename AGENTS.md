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
  - production model captures saving the high-resolution `main` buffer from the same completed request whose metadata produced the detection;
  - production capture saving images only, with no label `.txt` output;
  - stale detection without periodic refresh captures or confidence-jump reactivation;
  - Witty Pi `WAIT` states skipping externally managed schedule endpoints;
  - BeeCam and weather-station runtime storage rooted at `/home/pi/data`;
  - `offline_update.sh` working over SSH/rsync without camera-side internet;
  - transfer archives using store-only zip with `unzip -t` verification before deletion;
  - transfer cleanup of `images_and_labels/`, `logs/`, `update_backups/`, and `.Trash-*`, followed by sync and rootfs unmount;
  - BeeCam install keeping `apt-get full-upgrade` opt-in, not default;
  - first-boot config seeding that does not overwrite existing `/home/pi/data/configs`.
  - quiet BeeCam journal defaults: normal image-save messages by default, with stale/FPS/queue/startup logs opt-in under `[debug]`;
  - production capture OLED model states limited to `SCANNING` and `DETECTION`, with no old `SAVED` overlay/state path.
  - BeeCam displayed `SD` percent measuring `/home/pi/data` size against card capacity, plus an internal rootfs-full guard;
  - BeeCam and weather-station NTP waits skipping quickly when no wired Ethernet link is detected.
- The older separate-partition guardrails were intentionally superseded by the rootfs data-directory migration.
- If a requested change conflicts with a protected behavior, call that out before editing.

## Verification

- For shell scripts, run syntax checks when practical:
  `bash -n script_name.sh`
- For service/config changes, describe how to verify on the Raspberry Pi.

<!-- opensrc:start -->

## Source Code Reference

Upstream Witty Pi 4 / Witty Pi 4 Mini source is vendored under `opensrc/` for dev-time reference. See `opensrc/sources.json` for pinned versions.

Key paths:

- Witty Pi software: `opensrc/repos/github.com/uugear/Witty-Pi-4/Software/wittypi/`
- Witty Pi 4 Mini firmware: `opensrc/repos/github.com/uugear/Witty-Pi-4/Firmware/WittyPi4/WittyPi4_Mini.ino.hex`
- UWI Witty Pi 4 support: `opensrc/repos/github.com/uugear/UUGear-Web-Interface/uwi/wittypi4/`

BeeCam runtime overlays live in `wittypi/` and `weather_station/wittypi/`. Compare against upstream `runScript.sh` before changing WAIT-state schedule logic (see `references/chat_history/README.md`).

Refresh upstream sources:

```bash
./scripts/fetch-opensrc-sources.sh
```

Runtime Pi installs still use UUGear's zip via `beecam_install.sh`; `opensrc/` is not deployed to the Pi.

### Fetching Additional Source Code

To fetch source code for another package or repository, run:

```bash
npx opensrc@0.6 <package>           # npm package (e.g., npx opensrc zod)
npx opensrc@0.6 pypi:<package>      # Python package (e.g., npx opensrc pypi:requests)
npx opensrc@0.6 crates:<package>    # Rust crate (e.g., npx opensrc crates:serde)
npx opensrc@0.6 <owner>/<repo>      # GitHub repo (e.g., npx opensrc uugear/Witty-Pi-4@V4.23)
```

<!-- opensrc:end -->