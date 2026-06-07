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
- Model-triggered captures save the full-resolution main buffer from the same
  completed request whose metadata produced the detection. Do not move normal
  model capture back to `switch_mode_and_capture_file`; that can separate the
  saved still from the detection timing. Timelapse mode can still use its
  still-only `capture_file` path.
- Detection and stale matching use preview/lores coordinates. Saved labels are
  scaled from preview/lores coordinates to the full still image.
- Startup/debug logging for detection settings and capture saves is useful for
  `journalctl -u beecam -f`; preserve or replace it with equivalent visibility.

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

- [offline_update](../../offline_update)
- [scripts/beecam-update-runtime.sh](../../scripts/beecam-update-runtime.sh)
- [beecam_install.sh](../../beecam_install.sh)

Important preserved behavior:

- `offline_update` is a laptop-side field updater. It normalizes camera host
  names like `cam17`, `cam17.local`, or `pi@cam17.local`, rsyncs the local repo
  to `/home/pi/setup`, and runs the camera-side runtime updater over SSH.
- Hyphenated hostnames such as `cam-1` and `cam-2` are expected to work.
  Examples may still show older `cam17` or `cam7` style names, but they are not
  parsing requirements.
- The offline update path should not require internet on the camera. The field
  laptop repo is the source of truth for `/home/pi/setup`.
- `offline_update` preflights that remote `/data` is mounted and has
  `/data/configs` before running the runtime update.
- `scripts/beecam-update-runtime.sh` backs up runtime files to
  `/data/update_backups/...`, but uses normal `cp`/`cp -r` copies rather than
  `cp -a` when writing backups to exFAT. exFAT cannot preserve Unix ownership.
- The runtime updater overwrites only
  `/data/configs/camera_config_final.ini`, not the whole configs directory and
  not `schedule.conf`.
- The runtime updater should leave only production camera Python files deployed
  on the Pi: `beecam_capture_final.py` and `beecam_preview.py`, plus needed
  non-Python assets such as `packerout`.

### Transfer Script And SD Cleanup

Source chats: [transfer_and_update_script.md](transfer_and_update_script.md), [nms_fix.md](nms_fix.md)

Protected files:

- [transfer_beecam.sh](../../transfer_beecam.sh)

Important preserved behavior:

- `transfer_beecam.sh` should verify that the source is a mounted DATA
  filesystem, archive the expected camera data, test the archive, and only then
  delete transferred data from the SD card.
- Keep the archive as store-only zip (`zip -0`) for JPEG-heavy camera data.
  This avoids wasting time compressing already-compressed images while
  preserving the stronger `unzip -t` verification flow before deletion. Do not
  switch to plain tar unless weaker archive verification is an intentional
  tradeoff.
- The script should print DATA partition disk usage before transfer, then again
  before and after cleanup.
- Cleanup should include `images_and_labels/`, `logs/`, `update_backups/`, and
  top-level `.Trash-*` directories. Hidden trash on removable media can make a
  card look full even when visible data appears removed.
- The script should flush writes, verify cleanup, print before/after disk
  usage, change directory off the SD card, and unmount the DATA partition at
  the end.
- The script unmounts the DATA partition it used. If a desktop also mounted
  another card partition such as `boot`, the technician may still need to eject
  that from the file manager.
- A display showing `0 pictures` but non-trivial `SD %` can mean `/data` was
  not mounted and the camera was reading root filesystem usage, or that hidden
  trash/filesystem metadata remain on the DATA partition.
- SD repair guidance should always target the DATA partition, normally
  partition 3, not the whole SD device. There is intentionally no
  `SD_CARD_REPAIR.md` in this checkout.
- `transfer_beecam.sh` names archives from `/data/hostname` when present. After
  renaming a Pi, let the camera app boot once so it rewrites `/data/hostname`,
  or manually update/delete that file before transferring.

### DATA Partition, Install, And Config Seeding

Source chats: [partitioning.md](partitioning.md), [transfer_and_update_script.md](transfer_and_update_script.md)

Protected files:

- [scripts/beecam-init-data.sh](../../scripts/beecam-init-data.sh)
- [systemd_services/beecam-init-data.service](../../systemd_services/beecam-init-data.service)
- [systemd_services/beecam.service](../../systemd_services/beecam.service)
- [fstab](../../fstab)
- [beecam_install.sh](../../beecam_install.sh)

Important preserved behavior:

- `/data` is the exFAT DATA partition, expected as partition 3 on the Pi SD
  card. Init scripts may create or format an empty partition 3, reuse an
  existing exFAT partition 3, and must refuse to overwrite another filesystem.
- Keep the Pi recoverable: use `nofail` style mounting so the Pi can still boot
  and allow SSH, but prevent BeeCam runtime/update paths from using a plain
  root-directory `/data`.
- BeeCam startup, runtime update, and capture code should require `/data` to be
  mounted before writing camera data or configs.
- Default configs seed from the repo copy at `/home/pi/setup/configs` to
  `/data/configs` only when `/data/configs` does not already exist. Existing
  field-edited configs should not be overwritten on boot.
- The Pi-side installer installs software, Witty Pi, BeeCam files, services,
  and runtime setup. PC-side partition/prep scripts handle SD-card partitioning
  work.
- `beecam_install.sh` skips `apt-get full-upgrade` by default to keep SD setup
  faster. Use `--full-upgrade` only when an intentional full OS refresh is
  wanted, and `--skip-apt-update` only after `sudo apt update` has just run.
- The PC partition script accepts the parent disk device, not a partition path.
  Both `/dev/mmcblk0` and `/dev/sda` style card readers are valid when they are
  the actual SD card. It still keeps an explicit user confirmation before
  partition changes.
- The PC partition script uses `e2fsck -fy` during root filesystem resize so
  normal ext4 optimize prompts do not stall the scripted workflow.
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
- Weather station uses the same operational pattern as BeeCam: Witty Pi
  scheduling/power cycling, `/data` exFAT storage, `/data/logs`, linked logs,
  systemd services, and exception logging.
- `weather-station-init-data.sh` creates or reuses `/dev/mmcblk0p3`, mounts it
  at `/data`, creates `/data/logs` and `/data/weather`, and seeds configs only
  when `/data/configs` does not already exist.
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
