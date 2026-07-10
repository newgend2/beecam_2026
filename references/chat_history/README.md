# BeeCam Chat History Fix Summary

This file is the compact index for fixes and design decisions that came out of
previous Codex chats. Use the chat transcripts in this directory as source
material, but verify important claims against the current code before changing
behavior.

## How To Use This

- Before a large refactor, read the relevant protected-fix section below.
- Before touching a protected file, confirm the listed behavior is either
  preserved or intentionally changed.
- Keep `AGENTS.md` short. Add detailed historical notes here instead.
- If a future transcript changes one of these decisions, update this README at
  the same time.

## Protected Fixes

### Capture, NMS, And Stale Detection

Source chat: [nms_fix.md](nms_fix.md)

Protected files:

- [beecam/camera/beecam_capture_final.py](../../beecam/camera/beecam_capture_final.py)
- [beecam/camera/beecam_preview.py](../../beecam/camera/beecam_preview.py)
- [configs/camera_config_final.ini](../../configs/camera_config_final.ini)

Important preserved behavior:

- The non-Nanodet YOLO-style detection path must run class-aware NMS before
  stale detection sees the boxes. The earlier bug was that `cfg.iou` only
  affected the Nanodet branch, so duplicate same-object boxes survived in
  normal YOLO-style output.
- The capture and preview scripts should both keep the class-aware NMS helper
  and apply it to same-class overlapping boxes with the configured model IoU.
- Stale detection should operate on cleaned detections, not stacked duplicate
  boxes. Matching uses same category plus box IoU, normalized center distance,
  and area ratio checks.
- Do not reintroduce stale refresh captures or confidence-jump reactivation
  unless that is an intentional design change. They were removed because they
  could retrigger captures for persistent static objects and because model
  confidence was too variable.
- Model-triggered captures save the high-resolution `main` buffer from the same
  completed request whose metadata produced the detection. The low-power
  switch/burst path was intentionally removed after field tests showed the
  mode-switch delay could miss fast insects.
- Production capture intentionally saves JPEG images only. Do not reintroduce
  label `.txt` output or preview-to-still label coordinate conversion unless
  that is a deliberate labeling workflow change.
- Detection and stale matching use low-resolution `lores` tracking coordinates.
- Normal `journalctl -u beecam.service` output is intentionally quiet by
  default and should show image-save messages during ordinary capture. Stale
  suppression logs, FPS counters/logs, queue timing logs, and startup/config/ROI
  logs are opt-in through `[debug]`.
- FPS bookkeeping should stay disabled unless `debug.fps_log_interval_sec > 0`
  so normal capture avoids unnecessary per-frame accounting.
- Non-stale matched detections should continue returning as fresh until they
  cross the configured stale age. Do not reintroduce one-capture-per-track
  gating; it can make capture appear to stop after the first detection without
  producing stale-suppression logs.
- Normal model-detection OLED state should be either `SCANNING` or `DETECTION`;
  the old `SAVED` state/overlay path was intentionally removed. Lifecycle and
  error states such as `INIT`, `FULL`, `STOPPING`, and `RESTART` are still
  allowed.
- Production capture no longer owns HDMI/debug preview overlays. Use
  `beecam_preview.py` for HDMI/framebuffer camera debugging.

### Witty Pi Schedule Handling

Source chats: [partitioning.md](partitioning.md), current scripts

Protected files:

- [wittypi/runScript.sh](../../wittypi/runScript.sh)
- [weather_station/wittypi/runScript.sh](../../weather_station/wittypi/runScript.sh)

Important preserved behavior:

- The patched Witty Pi `runScript.sh` files intentionally skip scheduling an
  endpoint when the matching schedule state includes `WAIT`.
- The `PATCH: always use the normal ON-state endpoint` and
  `PATCH: always use the normal OFF-state endpoint` comments document an
  intentional change from upstream-style behavior. Do not restore behavior that
  automatically revises or overwrites externally managed schedule endpoints
  without confirming that is desired.
- BeeCam and weather-station schedule behavior should stay aligned unless a
  divergence is explicitly requested.

### Offline Update And Runtime Deployment

Source chats: [nms_fix.md](nms_fix.md), [transfer_and_update_script.md](transfer_and_update_script.md)

Protected files:

- [offline_update.sh](../../offline_update.sh)
- [scripts/beecam-update-runtime.sh](../../scripts/beecam-update-runtime.sh)
- [beecam_install.sh](../../beecam_install.sh)

Important preserved behavior:

- `offline_update.sh` is a laptop-side field updater. It normalizes camera host
  names like `cam17`, `cam17.local`, or `pi@cam17.local`, rsyncs the local repo
  to `/home/pi/setup`, and runs the camera-side runtime updater over SSH.
- Hyphenated hostnames such as `cam-1` and `cam-2` are expected to work.
  Examples may still show older `cam17` or `cam7` style names, but they are not
  parsing requirements.
- The offline update path should not require internet on the camera. The field
  laptop repo is the source of truth for `/home/pi/setup`.
- `offline_update.sh` preflights that the remote rootfs data layout exists under
  `/home/pi/data` before running the runtime update.
- `scripts/beecam-update-runtime.sh` backs up runtime files to
  `/home/pi/data/update_backups/...` using normal `cp`/`cp -r` copies.
- The runtime updater intentionally replaces the whole
  `/home/pi/data/configs` directory from the repo `configs/` directory,
  including `schedule.conf`. This makes `offline_update.sh` the field mechanism
  for pushing current functional camera configs and Witty Pi scheduling changes.
- The runtime updater should leave only production camera Python files deployed
  on the Pi: `beecam_capture_final.py` and `beecam_preview.py`, plus needed
  non-Python assets such as `packerout`.

### Transfer Script And SD Cleanup

Source chats: [transfer_and_update_script.md](transfer_and_update_script.md), [nms_fix.md](nms_fix.md)

Protected files:

- [transfer_beecam.sh](../../transfer_beecam.sh)

Important preserved behavior:

- `transfer_beecam.sh` should verify that the source is a mounted Linux rootfs
  filesystem, operate only inside `home/pi/data`, archive the expected camera
  data, test the archive, and only then delete transferred data from the SD
  card data directory.
- Keep the archive as store-only zip (`zip -0`) for JPEG-heavy camera data.
  This avoids wasting time compressing already-compressed images while
  preserving the stronger `unzip -t` verification flow before deletion. Do not
  switch to plain tar unless weaker archive verification is an intentional
  tradeoff.
- The script should print rootfs disk usage before transfer, then again before
  and after cleanup.
- Cleanup should include `images_and_labels/`, `logs/`, `update_backups/`, and
  top-level `.Trash-*` directories. Hidden trash on removable media can make a
  card look full even when visible data appears removed.
- The script should flush writes, verify cleanup, print before/after disk
  usage, change directory off the SD card, and unmount the rootfs partition at
  the end.
- The script unmounts the rootfs partition it used. If a desktop also mounted
  another card partition such as `boot`, the technician may still need to eject
  that from the file manager.
- BeeCam's OLED `SD %` display reflects `/home/pi/data` recursive size divided
  by the SD card/rootfs capacity, so empty BeeCam data should read near `0%`.
  A separate internal rootfs-full guard still stops capture if non-BeeCam data
  fills the filesystem.
- `transfer_beecam.sh` names archives from `/home/pi/data/hostname` when
  present. After renaming a Pi, let the camera app boot once so it rewrites the
  hostname marker, or manually update/delete that file before transferring.

### Rootfs Data Directory, Install, And Config Seeding

Source chats: [partitioning.md](partitioning.md), [transfer_and_update_script.md](transfer_and_update_script.md)

Protected files:

- [scripts/beecam-init-data.sh](../../scripts/beecam-init-data.sh)
- [systemd_services/beecam-init-data.service](../../systemd_services/beecam-init-data.service)
- [systemd_services/beecam.service](../../systemd_services/beecam.service)
- [beecam_install.sh](../../beecam_install.sh)

Important preserved behavior:

- The separate exFAT `/data` partition behavior was intentionally superseded by
  the `feature/no-exfat-data` migration. Current BeeCam storage is rooted at
  `/home/pi/data` on the root filesystem.
- BeeCam startup, runtime update, and capture code should use
  `/home/pi/data`. Displayed storage fullness should measure BeeCam data size
  under that directory against the card/rootfs capacity, while retaining a
  non-displayed rootfs-full safety guard.
- BeeCam uses a short `beecam-oled-boot.service` oneshot for early OLED boot
  visibility. It reads `/home/pi/data/configs/camera_config_final.ini`, exits
  immediately when `[oled] enabled = false`, and should not introduce a
  long-running OLED daemon or `/run/beecam/status.json` style status file.
- Default configs seed from the repo copy at `/home/pi/setup/configs` to
  `/home/pi/data/configs` only when `/home/pi/data/configs` does not already
  exist. Existing field-edited configs should not be overwritten on boot.
- The Pi-side installer installs software, Witty Pi, BeeCam files, services,
  and rootfs data-directory setup. There is no current PC-side partition step.
- `beecam_install.sh` skips `apt-get full-upgrade` by default to keep SD setup
  faster. Use `--full-upgrade` only when an intentional full OS refresh is
  wanted, and `--skip-apt-update` only after `sudo apt update` has just run.
- Systemd unit files belong under `/etc/systemd/system`, not
  `/etc/systemd/services`.

### Weather Station

Source chat: [weather_station.md](weather_station.md)

Protected files and folders:

- [weather_station/](../../weather_station)

Important preserved behavior:

- Weather-station work is intentionally separate from the BeeCam install path.
  Keep generated/update files inside `weather_station/` unless a shared helper
  is explicitly desired.
- Weather station uses the same rootfs data-directory pattern as BeeCam: Witty
  Pi scheduling/power cycling, `/home/pi/data` storage,
  `/home/pi/data/logs`, linked logs, systemd services, and exception logging.
- BeeCam and weather-station time initialization should keep NTP primary when
  Ethernet is connected, but skip the NTP wait quickly when no wired Ethernet
  carrier is detected.
- The weather-station installer mirrors BeeCam installer behavior: it skips
  `apt-get full-upgrade` by default, supports `--full-upgrade`, and supports
  `--skip-apt-update` only for runs where `sudo apt update` has just completed.
- `weather-station-init-data.sh` creates `/home/pi/data/logs` and
  `/home/pi/data/weather`, and seeds configs only when
  `/home/pi/data/configs` does not already exist.
- The local chat verification covered syntax and writer smoke tests, but not
  hardware-level sensor/OLED tests.

## Chat Files

- [nms_fix.md](nms_fix.md): capture v2/v3 development, preview stream capture,
  stale detection, class-aware NMS, field update script, and later camera
  debugging notes.
- [transfer_and_update_script.md](transfer_and_update_script.md): DATA mount
  diagnosis, transfer cleanup hardening, offline update safety, SD repair, and
  auto-unmount behavior.
- [partitioning.md](partitioning.md): SD partitioning/install methodology,
  first-boot DATA initialization, config seeding, Witty Pi install issues, and
  systemd/service verification.
- [weather_station.md](weather_station.md): standalone weather-station
  redesign and install/runtime structure.
- [transfer_script_updates.md](transfer_script_updates.md): model evaluation
  notes, hostname guidance, install-speed changes, partition-script/card-reader
  notes, and transfer archive speed updates.
