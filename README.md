# BeeCam Setup

This is a scripted provisioning repo, not a pure golden-image workflow. Start
from a fresh Raspberry Pi OS card, clone this repo, and run the installer on the
Pi. Then shut down, move the card to a Linux PC/laptop, and run the partitioning
script from this repo.

## Quick Start

On a fresh Raspberry Pi, paste this from the default `/home/pi` directory:

```bash
sudo apt update && sudo apt install -y git && git clone https://github.com/newgend2/beecam_2026.git setup && cd setup && chmod +x beecam_install.sh scripts/beecam-init-data.sh && ./beecam_install.sh
```

If the repo has already been cloned, rerun the installer with:

```bash
cd ~/setup && git pull && chmod +x beecam_install.sh scripts/beecam-init-data.sh && ./beecam_install.sh
```

The installer:

- installs the DATA partition initializer
- installs apt packages
- installs `astral` and `adafruit-circuitpython-ssd1306` into system Python with `--break-system-packages`
- installs Witty Pi software
- replaces Witty Pi scripts with the repo versions
- copies BeeCam code into `/home/pi/beecam`
- uses this repo's `configs/` folder as the first-boot default config source
- copies configs into `/data/configs` when `/data` already exists
- updates `/boot/firmware/cmdline.txt`
- replaces `/boot/firmware/config.txt`
- installs systemd services

The source folders inside `/home/pi/setup` remain there after installation. The
installer also copies BeeCam runtime files to `/home/pi/beecam` and Witty Pi
scripts to `/home/pi/wittypi`.

## PC/Laptop Partitioning

A booted Pi cannot safely shrink its own mounted root filesystem, so partitioning
is done from a Linux PC/laptop after the Pi-side install.

1. Shut down the Pi cleanly:

   ```bash
   sudo shutdown now
   ```

2. Insert the SD card into a Linux PC/laptop.

3. From this repo on the PC/laptop, run:

   ```bash
   ./partition_beecam_sd_on_pc.sh
   ```

The PC/laptop script shrinks root to 10GiB, creates the exFAT DATA partition,
updates the target card's `/etc/fstab`, and copies `configs/` to
`/data/configs`.

Keep `/home/pi/setup` on the Pi. The DATA initializer can use that repo copy as
a fallback source for default configs if `/data/configs` does not already exist.

## Services

`beecam.service` is installed but intentionally not enabled. Witty Pi starts it
from `wittypi/afterStartup.sh` and stops it from `wittypi/beforeShutdown.sh`.

All other service files in `systemd_services/` are enabled by the installer.

## Field Runtime Updates

For cameras that already have this repo at `/home/pi/setup`, update the runtime
capture script, preview script, service file, and camera config with:

```bash
ssh pi@cam7 'cd ~/setup && git pull --ff-only && chmod +x scripts/beecam-update-runtime.sh && scripts/beecam-update-runtime.sh --restart'
```

The updater backs up the current runtime files under `/data/update_backups/`
before replacing them. It deploys only the production camera Python scripts
(`beecam_capture_final.py` and `beecam_preview.py`) to `/home/pi/beecam/camera`,
and overwrites `/data/configs/camera_config_final.ini`.

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
