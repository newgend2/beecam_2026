# BeeCam Setup

This repo is intended to be cloned onto a Raspberry Pi at:

```bash
/home/pi/setup
```

Then run:

```bash
cd /home/pi/setup
./beecam_install.sh
```

The installer:

- installs the DATA partition initializer
- installs apt packages
- installs Python packages from `PIP_LIST.txt` into system Python with `--break-system-packages`
- installs Witty Pi software
- replaces Witty Pi scripts with the repo versions
- copies BeeCam code into `/home/pi/beecam`
- stages default DATA configs under `/opt/beecam/default-data/configs`
- copies configs into `/data/configs` when `/data` already exists
- updates `/boot/firmware/cmdline.txt`
- replaces `/boot/firmware/config.txt`
- installs systemd services

## Partitioning Note

A booted Pi cannot safely shrink its own mounted root filesystem. If Raspberry Pi
OS has expanded root to fill the whole SD card, `beecam_install.sh` will install
and enable `beecam-init-data.service`, but it will not be able to create
`/dev/mmcblk0p3` immediately.

For the small golden-image workflow:

1. Run `beecam_install.sh` on the Pi.
2. Shut down cleanly.
3. Move the card to a Linux PC.
4. Shrink root offline so the image ends after `p2`.
5. Create the small image from `p1` + `p2`.
6. On first boot from a flashed card, `beecam-init-data.service` creates and
   formats `/dev/mmcblk0p3`, mounts it at `/data`, and copies default configs to
   `/data/configs`.

## Services

`beecam.service` is installed but intentionally not enabled. Witty Pi starts it
from `wittypi/afterStartup.sh` and stops it from `wittypi/beforeShutdown.sh`.

All other service files in `systemd_services/` are enabled by the installer.
