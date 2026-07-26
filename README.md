# BeeCam

Solar-powered Pi Zero 2W insect camera (Witty Pi 4 Mini, DS3231 RTC, OLED, IMX500 AI camera).
All runtime data lives on the root filesystem under `/home/pi/data`.

---

## 1. Install (fresh Raspberry Pi OS card)

From `/home/pi` on the Pi, paste one line:

```bash
sudo apt update && sudo apt install -y git && git clone --branch main --single-branch https://github.com/newgend2/beecam_2026.git setup && cd setup && chmod +x beecam_install.sh scripts/*.sh && ./beecam_install.sh --skip-apt-update
```

Reinstall / re-run later:

```bash
cd ~/setup && git pull --ff-only && ./beecam_install.sh
```

- Add `--full-upgrade` for a full OS refresh (slow). Use `--skip-apt-update` only if you just ran `sudo apt update`.
- Installs apt/pip packages, Witty Pi, BeeCam code, boot config, and systemd services.
- **Reboot after install** for boot-config (I2C/CMA) changes to take effect. If
  I2C was not already active, the installer defers Witty Pi setup cleanly and
  its boot service applies the power settings and arms the schedule after this
  reboot.

---

## 2. Operation (automatic)

- Witty Pi runs a fixed daily schedule: **on 07:00, off 19:00** (`/home/pi/data/configs/schedule.conf`).
- On boot, Witty Pi regenerates the schedule, starts `beecam.service`, and the camera images on insect detection (full-res JPEGs to `/home/pi/data/images_and_labels/<date>/images/`).
- If power returns off-hours, the Pi runs briefly, re-arms the next start, and shuts down.
- OLED shows host, next on/off, image count, and SD %.
- Capture stops automatically at 97% disk full.

No manual start needed — Witty Pi controls power and the service.

---

## 3. Update a deployed camera

From a field laptop with this repo, on the same Ethernet network:

```bash
./offline_update.sh cam7          # use the camera hostname
```

Pushes code, configs, Witty Pi scripts, services, and boot config over SSH, then **auto-reboots** the camera. No internet needed on the camera.

Already on the camera (`~/setup` up to date)?

```bash
cd ~/setup && scripts/beecam-update-runtime.sh --restart
```

Previous runtime files are backed up to `/home/pi/data/update_backups/` before replacement.

---

## 4. Transfer data off a card

Shut the Pi down, move the SD card to a Linux PC, mount it, then:

```bash
./transfer_beecam.sh                                  # auto-detect card
./transfer_beecam.sh /media/user/rootfs /media/backup # explicit source + dest
```

- Auto-detects cards under `/media/wlab`, `/media/nate`, `/media/field3`.
- Writes `HOST_DATERANGE_YYYY-MM-DD-HH-MM-SS.zip` to the destination, then clears transferred data, flushes, and unmounts the card.
- Run with `sudo` if it reports permission errors (ext4 root-owned files).

---

## Key paths

| What | Where |
|------|-------|
| Data (captures, logs, configs) | `/home/pi/data` |
| Camera config | `/home/pi/data/configs/camera_config_final.ini` |
| Schedule config | `/home/pi/data/configs/schedule.conf` |
| BeeCam code | `/home/pi/beecam` |
| Witty Pi scripts | `/home/pi/wittypi` |
| Services | `/etc/systemd/system` |
| Logs | `journalctl -u beecam.service` |

## Troubleshooting

- **Install stopped early:** it's fail-fast — rerun and look for `ERROR: install failed at line ...`.
- **Camera won't image:** check `journalctl -u beecam.service`; confirm the schedule window and that the disk isn't full.
- **Wi-Fi/Bluetooth are off** (power saving) — use Ethernet for SSH and NTP.
- **Verify power-cut recovery:** `sudo scripts/wittypi-powercut-test.sh --shutdown-delay-sec 180 --off-duration-sec 300` (restore with `--restore`).
- **Camera won't boot despite 5V present:** check `WITTYPI_LOW_VOLTAGE_THRESHOLD`/`WITTYPI_RECOVERY_VOLTAGE_THRESHOLD` in `schedule.conf` and `/home/pi/data/logs/before_script.log` — these registers (19/22) keep the Pi from getting stuck off after a brownout even though input is back in range; unmanaged/mismatched thresholds are a common cause of a camera that looks powered but stays off until unplugged and replugged.
