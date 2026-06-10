# BeeCam Setup

This is a scripted provisioning repo, not a pure golden-image workflow. Start
from a fresh Raspberry Pi OS card, clone this repo, and run the installer on the
Pi. BeeCam stores configs, captures, logs, host metadata, and update backups on
the root filesystem under:

```bash
/home/pi/data
```

There is no separate removable data partition in the current fresh-card workflow.

## Quick Start

On a fresh Raspberry Pi, paste this from the default `/home/pi` directory:

```bash
sudo apt update && sudo apt install -y git && git clone https://github.com/newgend2/beecam_2026.git setup && cd setup && chmod +x beecam_install.sh scripts/beecam-init-data.sh && ./beecam_install.sh --skip-apt-update
```

If the repo has already been cloned, rerun the installer with:

```bash
cd ~/setup && git pull && chmod +x beecam_install.sh scripts/beecam-init-data.sh && ./beecam_install.sh
```

The installer:

- installs the BeeCam data directory initializer
- creates `/home/pi/data/configs`, `/home/pi/data/logs`, and `/home/pi/data/images_and_labels`
- seeds configs from this repo only when `/home/pi/data/configs` does not already exist
- installs apt packages without running a full OS upgrade by default
- installs `astral` and `adafruit-circuitpython-ssd1306` into system Python with `--break-system-packages`
- installs Witty Pi software
- replaces Witty Pi scripts with the repo versions
- copies BeeCam code into `/home/pi/beecam`
- updates `/boot/firmware/cmdline.txt`
- replaces `/boot/firmware/config.txt`, disabling Wi-Fi, Bluetooth, and audio while preserving HDMI/framebuffer support
- installs systemd services

The source folders inside `/home/pi/setup` remain there after installation. The
installer also copies BeeCam runtime files to `/home/pi/beecam` and Witty Pi
scripts to `/home/pi/wittypi`.

For a slower full OS refresh, run the installer with:

```bash
./beecam_install.sh --full-upgrade
```

Use `--skip-apt-update` only when `sudo apt update` was already run immediately
before the installer.

## Data Transfer

To transfer data, shut the Pi down cleanly, insert the SD card into a Linux
PC/laptop, mount the SD card root filesystem, and run:

```bash
./transfer_beecam.sh /media/user/rootfs /media/user/BackupSSD
```

The transfer script expects the mounted rootfs path, not `/home/pi/data`
directly. It archives `/home/pi/data` contents with store-only zip, verifies the
archive with `unzip -t`, cleans transferred capture/log/update data from
`/home/pi/data`, flushes writes, and unmounts the rootfs partition.

## Services

`beecam.service` is installed but intentionally not enabled. Witty Pi starts it
from `wittypi/afterStartup.sh` and stops it from `wittypi/beforeShutdown.sh`.

All other service files in `systemd_services/` are enabled by the installer,
including `beecam-oled-boot.service`. The OLED boot service is a short oneshot:
it shows an early splash only when `[oled] enabled = true` in
`/home/pi/data/configs/camera_config_final.ini`, then exits. Live OLED updates
still come from `beecam_capture_final.py`.

Wi-Fi is disabled in the BeeCam boot config to save power. Use Ethernet for SSH
and NTP time sync. Time initialization skips the NTP wait when no wired Ethernet
link is detected.

## Capture And Storage

Production capture scans in low-resolution mode by default and switches briefly
to high-resolution still mode for a 2-image burst when a new detection track
appears. The previous high-resolution same-request stream remains available
with `capture_strategy = same_request` for hardware fallback.

Production capture saves JPEG images only. The directory name
`images_and_labels` is retained for compatibility with transfer workflows, but
no label `.txt` files are produced.

The OLED `SD` percentage shows BeeCam data size under `/home/pi/data` as a
percentage of the SD card/root filesystem capacity. A separate internal rootfs
fullness guard still stops capture if non-BeeCam data fills the card.

## Logging And Debugging

By default, normal `journalctl -u beecam.service` output is quiet and records
image-save messages during capture. Stale-detection logs, FPS logs, queue timing
logs, and startup/config logs are opt-in under the `[debug]` section of
`camera_config_final.ini`.

HDMI/framebuffer preview debugging remains available through
`beecam_preview.py`, with DRM preview as the default and `--preview-backend` for
overrides.

## Field Runtime Updates

For cameras that can be reached over Ethernet from a field laptop with this repo
checked out locally, update the runtime capture script, preview script, service
file, OLED boot splash service, and camera config with:

```bash
./offline_update.sh cam7
```

The offline updater does not require internet on the camera. It rsyncs this repo
to `/home/pi/setup`, verifies the rootfs data folders under `/home/pi/data`, and
runs the camera-side runtime updater over SSH.

If you are already on the camera and `/home/pi/setup` already contains the
updated repo, you can run the camera-side updater directly:

```bash
cd ~/setup
chmod +x scripts/beecam-update-runtime.sh
scripts/beecam-update-runtime.sh --restart
```

The updater backs up the current runtime files under
`/home/pi/data/update_backups/` before replacing them. It deploys only the
production camera Python scripts (`beecam_capture_final.py` and
`beecam_preview.py`) to `/home/pi/beecam/camera`, updates
`beecam-oled-boot.service`, and overwrites
`/home/pi/data/configs/camera_config_final.ini`.

## Troubleshooting

Systemd service files are installed to:

```bash
/etc/systemd/system
```

If the installer stops early, rerun it and look for a line like:

```bash
ERROR: install failed at line ...
```

The installer is intentionally fail-fast, so if Witty Pi installation fails,
later steps such as copying `/home/pi/beecam`, updating boot files, and
installing services will not run.
