# Refactor weather station flow

> Broad overview:
> Within the folder [weather_station](weather_station) I have pasted old code which parses sensor data from our weather stations units. These were used alongside the beecam units in the field and were designed so that when installing software for a new sd card you could either choose camera (for beecams) or server (for weather stations, which were called server because they had additional LTE functionality). I bascially want to redesign the whole operation of the weather station and gave you [sensors.py](weather_station/sensors.py) as reference for which sensors we used. I would like to update the weather station so that it uses our already established scripts for scheduling and power cycling ( [wittypi](wittypi) [schedule](beecam/schedule)),  and keep the same format of saving into an exfat data partition.  I would also like to keep this process separate from the beecam install, by creating/copying all relevant scripts/files you generate/update into the [weather_station](weather_station) folder.
>
> More details:
> We bascially want sensor readings from the pressure, temperature, windspeed, and humidity sensors to both be displayed on the OLED Display (while also keeping the current functionality for showing hostname, datetime, and sd %), and saved within txt files in /data/weather/<yyyy-mm-dd>
>
> Ensure that the functionality for scheduling, scheduling configs, and linking schedule logs to /data/logs is the same. Also ensure we have exception logging (write to an exception csv file in /data/logs) just like we do within [beecam_capture_final.py](beecam/camera/beecam_capture_final.py) .
>
> We can ignore all aspects of "if mode='camera'" within [sensors.py](weather_station/sensors.py) because this was only used in the sd card was meant for a beecam. Additionally all aspects of LTE comminication/wifi/servers can be disregarded as we seek to simplify this new weather station by having it only internally save weather data/display it on OLED. We are also not using databases to store data anymore so that functionality can be ignored aswell.

<details><summary>11 previous messages</summary>

> I’ll trace the existing beecam scheduling, Witty Pi, logging, and OLED patterns first, then I’ll fold the weather-station pieces into a separate `weather_station` install surface so it stays cleanly independent.
>
> The repo shows `weather_station/` as untracked, so I’ll treat everything in there as your pasted/reference work and only make deliberate additions/updates inside that folder. Next I’m reading the beecam scripts that define the behavior we want to mirror.
>
> I’ve got the core shape now: Witty Pi calls `beforeScript.sh` to initialize `/data`, run `time_init.sh`, generate `schedule.wpi`, then starts/stops the main service through `afterStartup.sh` and `beforeShutdown.sh`. I’m checking the remaining capture service code for its shutdown/restart and storage behavior so the weather daemon has the same operational feel.
>
> The old sensor file is tightly coupled to removed pieces (`utilities.*`, SQLite, server/camera mode), so I’m going to leave it conceptually behind and build a self-contained weather daemon beside it. I’ll still reuse its actual sensor choices and wind conversion logic.
>
> I’m ready to edit. I’m going to add a standalone weather-station runtime, config set, Witty Pi scripts, systemd units, and install/partition helpers under `weather_station/`, then I’ll syntax-check the Python and shell pieces.
>
> <details><summary>Created 14 files, edited 1 file</summary>
>
> - Wrote `./weather_station/sensors.py` (+260 -0)
> - Wrote `./weather_station/weather_station.py` (+606 -0)
> - Wrote `./weather_station/configs/weather_station_config.ini` (+35 -0)
> - Wrote `./weather_station/scripts/weather-station-init-data.sh` (+125 -0)
> - Wrote `./weather_station/systemd_services/weather-station-init-data.service` (+12 -0)
> - Wrote `./weather_station/systemd_services/weather-station.service` (+20 -0)
> - Wrote `./weather_station/systemd_services/wittypi-log-links.service` (+16 -0)
> - Wrote `./weather_station/systemd_services/README.txt` (+10 -0)
> - Wrote `./weather_station/wittypi/afterStartup.sh` (+8 -0)
> - Wrote `./weather_station/wittypi/beforeShutdown.sh` (+6 -0)
> - Wrote `./weather_station/wittypi/beforeScript.sh` (+30 -0)
> - Wrote `./weather_station/install_weather_station.sh` (+170 -0)
> - Wrote `./weather_station/partition_weather_station_sd_on_pc.sh` (+180 -0)
> - Wrote `./weather_station/README.md` (+51 -0)
> - Wrote `./weather_station/configs/schedule.conf` (+2 -1)
>
> </details>
>
> The main files are in place now. I’m tightening the copied config wording and marking the runtime shell/Python entrypoints executable before running syntax checks.
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./weather_station/boot_firmware/config.txt` (+0 -3)
>
> </details>
>
> The first verification pass is clean. I noticed the copied boot config still had a camera auto-detect line, so I removed that from the weather-station copy and normalized non-script file permissions.
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./weather_station/schedule/time_init.sh` (+5 -1)
>
> </details>
>
> The weather-station copy no longer contains the old server/camera branches, SQLite path, or LTE/Wi-Fi/database utility imports. The only remaining “mode” language is the solar/fixed schedule mode, which is the part we do want.
</details>

Implemented a standalone weather-station stack entirely under [weather_station](./weather_station).

What changed:
- Rebuilt [sensors.py](./weather_station/sensors.py) as a clean sensor facade for SHT31D temp/humidity, BMP3XX pressure, and ADS1115 wind speed. No old camera/server mode, SQLite, LTE, Wi-Fi, or `utilities.*` dependencies.
- Added [weather_station.py](./weather_station/weather_station.py), a daemon that displays hostname/date/time/SD percent plus sensor readings on OLED and appends readings to:
  `/data/weather/YYYY-MM-DD/<station>_YYYY-MM-DD.txt`
- Added exception logging to:
  `/data/logs/weather_station_exception_log.csv`
- Added weather-specific configs, Witty Pi scripts, systemd services, `/data` initializer, installer, and PC partition helper inside `weather_station/`.

Verification passed:
- Python syntax check
- Bash syntax check
- Writer smoke test for daily text output

I did not run hardware-level sensor/OLED tests here, since that needs the Raspberry Pi with the I2C devices attached. Next practical step is on the Pi: `cd ~/setup/weather_station && ./install_weather_station.sh`.

> can you explain how the [weather-station-init-data.sh](weather_station/scripts/weather-station-init-data.sh) works?

<details><summary>1 previous message</summary>

> I’ll pull the current file with line numbers so the explanation lines up with exactly what’s open in your workspace.
</details>

[weather-station-init-data.sh](./weather_station/scripts/weather-station-init-data.sh:1) is a boot-time “make `/data` usable” script. It is meant to run as root from systemd and Witty Pi before the weather station service starts.

**Flow**
1. It runs in strict Bash mode with `set -euo pipefail`, so missing variables, failed commands, and failed pipeline steps stop the script early. See [line 2](./weather_station/scripts/weather-station-init-data.sh:2).

2. It assumes the Pi SD card is `/dev/mmcblk0`, and that the data partition should be partition 3: `/dev/mmcblk0p3`. The mount point is `/data`, the filesystem label is `DATA`, and configs can be seeded from either `/home/pi/setup/weather_station/configs` or `/home/pi/weather_station/configs`. See [lines 4-13](./weather_station/scripts/weather-station-init-data.sh:4).

3. It checks for required commands, then verifies that `/dev/mmcblk0` exists as a block device. If the SD card device is not found, it exits. See [lines 19-33](./weather_station/scripts/weather-station-init-data.sh:19).

4. If `/dev/mmcblk0p3` does not exist, it tries to create it in the remaining free space after root partition 2. It finds partition 2’s ending sector, starts partition 3 immediately after it, and refuses to proceed if there is less than 1 GiB free. See [lines 35-67](./weather_station/scripts/weather-station-init-data.sh:35).

5. Once partition 3 exists, it checks the filesystem. If it has no filesystem, it formats it as exFAT. If it is already exFAT, it reuses it. If it is anything else, it refuses to overwrite it. That is the main safety guard. See [lines 74-82](./weather_station/scripts/weather-station-init-data.sh:74).

6. It reads the partition UUID and writes an `/etc/fstab` entry so the partition mounts at `/data` on future boots. It removes any existing `/data` fstab entry first, then writes the new UUID-based exFAT mount line. See [lines 84-100](./weather_station/scripts/weather-station-init-data.sh:84).

7. If `/data` is not already mounted, it mounts it. See [lines 102-105](./weather_station/scripts/weather-station-init-data.sh:102).

8. It creates the runtime directories the weather station needs: `/data/logs` and `/data/weather`. See [line 107](./weather_station/scripts/weather-station-init-data.sh:107).

9. If `/data/configs` does not already exist, it copies default config files from the first available seed directory. This preserves existing field configs because it only seeds configs when `/data/configs` is absent. See [lines 109-118](./weather_station/scripts/weather-station-init-data.sh:109).

10. Finally, it writes a marker file at `/data/.weather-station-data-initialized` and logs that the data partition is ready. See [lines 124-125](./weather_station/scripts/weather-station-init-data.sh:124).

In short: it creates or reuses the exFAT data partition, mounts it as `/data`, makes the weather/log/config folders, seeds default configs only once, and then lets the weather service start with stable storage.

> can make the install work the same as in [README.md](README.md) where you provide a command, and it clones into a setup folder in /home/pi

<details><summary>3 previous messages</summary>

> I’ll update the weather-station docs so the Pi-side install mirrors the BeeCam quick start: start from `/home/pi`, clone into `setup`, then run the installer from the weather-station subfolder.
>
> I’m going to replace the current weather-station quick start with the same one-line clone-and-install pattern, plus a rerun command for an already-cloned `/home/pi/setup`.
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./weather_station/README.md` (+9 -5)
>
> </details>
</details>

Done. I updated [weather_station/README.md](./weather_station/README.md:19) so the weather-station install now mirrors the main BeeCam README:

```bash
sudo apt update && sudo apt install -y git && git clone https://github.com/newgend2/beecam_2026.git setup && cd setup/weather_station && chmod +x install_weather_station.sh scripts/weather-station-init-data.sh partition_weather_station_sd_on_pc.sh && ./install_weather_station.sh
```

I also added the matching rerun command for an existing `~/setup` clone.

> It appears that the wind speed is not recording any values (or displaying any values) can you check its functionality, and I will drop in place any changes to test on the pi for further feedback

<details><summary>7 previous messages</summary>

> I’ll inspect the weather-station sensor path against the old reference and add better wind diagnostics/config knobs so your next Pi test can tell us whether this is an import/init/address/channel/read issue instead of silently showing `--`.
>
> The code path was using the same differential ADS1115 setup as the old file, so I don’t see an obvious formula bug. I’m going to make the wind side less opaque: configurable ADS address/channel mode, stronger one-time diagnostics, and raw voltage tracking so the Pi can tell us whether the ADC is missing, wired differently, or just reading below the wind threshold.
>
> I’m going to patch the wind sensor facade now. The defaults will remain the legacy setup, but `/data/configs/weather_station_config.ini` can now switch ADS address/mode/pins without code edits if the Pi shows the ADC is wired differently.
>
> <details><summary>Created 1 file, edited 4 files</summary>
>
> - Wrote `./weather_station/sensors.py` (+69 -2)
> - Wrote `./weather_station/weather_station.py` (+24 -2)
> - Wrote `./weather_station/configs/weather_station_config.ini` (+10 -0)
> - Wrote `./weather_station/wind_test.py` (+48 -0)
> - Wrote `./weather_station/README.md` (+18 -0)
>
> </details>
>
> I added a small `wind_test.py` utility as well, so testing on the Pi doesn’t require watching the OLED or waiting for scheduled service behavior. Now I’m running local syntax and writer smoke checks.
>
> One small robustness tweak: since existing daily files may already have the older header, I’m making the writer respect an existing header for the rest of that day. New files get the extra voltage column; old same-day files won’t get malformed rows.
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./weather_station/weather_station.py` (+15 -1)
>
> </details>
</details>

I checked the wind path and didn’t find an obvious mismatch from the old code: the default is still ADS1115 differential `P0-P1`, address `0x48`, using the same wind-speed calibration.

I added better diagnostics instead:

- [sensors.py](./weather_station/sensors.py): configurable ADS1115 address/mode/pins/gain, clearer init/read errors, tracks raw wind voltage.
- [weather_station.py](./weather_station/weather_station.py): OLED now shows wind speed plus raw voltage, like `W 0.0m/s 0.398V`.
- [weather_station_config.ini](./weather_station/configs/weather_station_config.ini): added `[wind]` ADS config knobs.
- Added [wind_test.py](./weather_station/wind_test.py), a direct Pi-side wind ADC test.

On the Pi, after dropping this in place, run:

```bash
cd /home/pi/weather_station
python3 wind_test.py --config /data/configs/weather_station_config.ini --count 20
```

Useful outcomes:
- `channel=unavailable`: ADS1115 import/init/address/wiring problem. Check `/data/logs/weather_station_exception_log.csv` for `ads1115_*`.
- Voltage prints but speed is `0.00 m/s`: ADC is working, but voltage is below the calibration threshold.
- If wiring is single-ended to `P0` and GND, change `/data/configs/weather_station_config.ini` to `ads_mode = single_ended`.

Validation passed locally: Python syntax, writer smoke test, and the wind test degrades cleanly here without Pi hardware.

> how can I clone without running the installer

From `/home/pi`, just run the clone command without the install part:

```bash
sudo apt update && sudo apt install -y git && git clone https://github.com/newgend2/beecam_2026.git setup
```

Then you can inspect files at:

```bash
cd ~/setup/weather_station
```

If `~/setup` already exists and you just want the latest code:

```bash
cd ~/setup && git pull
```

> Ok, I went to setup and did git pull. Won't this just update the files in /home/pi/setup/weather_station and not the executive files in /home/pi/weather_station?

Yes, exactly. `git pull` only updates the repo copy at:

```bash
/home/pi/setup/weather_station
```

It does **not** automatically update the runtime copy at:

```bash
/home/pi/weather_station
```

The installer copies from `~/setup/weather_station` to `/home/pi/weather_station`. To update the runtime files after `git pull`, run:

```bash
cd ~/setup/weather_station
./install_weather_station.sh
```

That will reinstall/copy the weather station files, systemd units, Witty Pi scripts, configs, etc.

For just testing code changes quickly, you can copy only the app files:

```bash
sudo cp -a ~/setup/weather_station/sensors.py ~/setup/weather_station/weather_station.py ~/setup/weather_station/wind_test.py /home/pi/weather_station/
sudo chown pi:pi /home/pi/weather_station/sensors.py /home/pi/weather_station/weather_station.py /home/pi/weather_station/wind_test.py
```

Then test:

```bash
cd /home/pi/weather_station
python3 wind_test.py --config /data/configs/weather_station_config.ini --count 20
```

> pi@weather1:~/weather_station $ python3 wind_test.py --config weather_station.py --count 20
> Traceback (most recent call last):
>   File "/home/pi/weather_station/wind_test.py", line 48, in <module>
>     main()
>   File "/home/pi/weather_station/wind_test.py", line 27, in main
>     cfg = read_config(args.config)
>           ^^^^^^^^^^^^^^^^^^^^^^^^
>   File "/home/pi/weather_station/weather_station.py", line 85, in read_config
>     if not parser.read(config_path):
>            ^^^^^^^^^^^^^^^^^^^^^^^^
>   File "/usr/lib/python3.11/configparser.py", line 713, in read
>     self._read(fp, filename)
>   File "/usr/lib/python3.11/configparser.py", line 1101, in _read
>     raise MissingSectionHeaderError(fpname, lineno, line)
> configparser.MissingSectionHeaderError: File contains no section headers.
> file: 'weather_station.py', line: 2
> 'from __future__ import annotations\n'

You pointed `--config` at the Python app file by accident:

```bash
--config weather_station.py
```

`wind_test.py` expects the INI config file, not the script. Run this instead:

```bash
cd /home/pi/weather_station
python3 wind_test.py --config /data/configs/weather_station_config.ini --count 20
```

That error is just `configparser` saying “I tried to read `weather_station.py` as an INI file, but it starts with Python code instead of `[weather]` / `[wind]` sections.”

If `/data/configs/weather_station_config.ini` does not exist yet, copy the updated config over:

```bash
sudo mkdir -p /data/configs
sudo cp ~/setup/weather_station/configs/weather_station_config.ini /data/configs/
```

> I get these errors in the weather station exception log. The test script says it still has no voltage readings.
>
> 2026-05-05 12:26:18	sensor_init_error	Wind sensor initialization failed	Unsupported ADS1115 pin 'P0'
> 2026-05-05 12:26:18	sensor_status	ADS1115 address=0x48 mode=differential pins=P0-P1 gain=1.0 channel=unavailable last_voltage=--
> 2026-05-05 12:26:18	sensor_read_error	Wind ADC channel is unavailable; check earlier ADS1115 initialization errors
> 2026-05-05 12:27:19	sensor_read_error	Wind ADC channel is unavailable; check earlier ADS1115 initialization errors
> 2026-05-05 12:27:31	sensor_read_error	Could not read temperature_humidity temperature	[Errno 5] Input/output error
> 2026-05-05 12:27:31	sensor_read_error	Could not read temperature_humidity relative_humidity	[Errno 5] Input/output error
> 2026-05-05 12:29:54	sensor_init_error	Wind sensor initialization failed	Unsupported ADS1115 pin 'P0'
> 2026-05-05 12:29:54	sensor_status	ADS1115 address=0x48 mode=differential pins=P0-P1 gain=1.0 channel=unavailable last_voltage=--
> 2026-05-05 12:29:54	sensor_read_error	Wind ADC channel is unavailable; check earlier ADS1115 initialization errors
> 2026-05-05 12:30:55	sensor_read_error	Wind ADC channel is unavailable; check earlier ADS1115 initialization errors
> 2026-05-05 12:32:53	sensor_read_error	Wind ADC channel is unavailable; check earlier ADS1115 initialization errors

<details><summary>6 previous messages</summary>

> That log is useful: the ADS1115 object itself is being created at `0x48`, but my configurable pin lookup is too strict for the library version on your Pi. I’m going to patch the pin resolver so it works with both newer `ADS.P0` constants and older/raw ADS1x15 pin objects.
>
> <details><summary>Searched web 1 time</summary>
>
> <details><summary>Searched web 1 time</summary>
>
> - Searched web for `adafruit_ads1x15 analog_in AnalogIn ADS.P0 source`
>
> </details>
>
> </details>
>
> The log also shows the ADS address itself was reachable, so this is not yet proof of wiring failure. The failure happened before `AnalogIn(...)` was created because this installed ADS library doesn’t expose `ADS.P0`; I’m adding a fallback to raw channel numbers and the newer `ads1x15.Pin.A0` style.
>
> <details><summary>Edited 1 file</summary>
>
> - Wrote `./weather_station/sensors.py` (+29 -7)
>
> </details>
>
> I noticed one more compatibility trap in my own patch: the optional common-pin import should not be able to disable the whole ADS import. I’m separating that import so older libraries still work cleanly.
>
> <details><summary>Edited 1 file, searched web 1 time</summary>
>
> - Wrote `./weather_station/sensors.py` (+5 -2)
>
> <details><summary>Searched web 1 time</summary>
>
> - Searched web for `https://docs.circuitpython.org/projects/ads1x15/en/stable/api.html`
>
> </details>
>
> </details>
</details>

Yep, the key error is:

```text
Unsupported ADS1115 pin 'P0'
```

So the ADS1115 at `0x48` likely initialized, but your installed Adafruit library does not expose `ADS.P0`. I patched [sensors.py](./weather_station/sensors.py) to support:

- old style: `ADS.P0`
- newer style: `ads1x15.Pin.A0`
- fallback raw integer channels: `0`, `1`, `2`, `3`

Adafruit’s current ADS1x15 docs list common pins as `Pin.A0` through `Pin.A3`, so this was a library-version mismatch: https://docs.circuitpython.org/projects/ads1x15/en/stable/api.html

On the Pi, update the runtime file:

```bash
sudo cp ~/setup/weather_station/sensors.py /home/pi/weather_station/
sudo chown pi:pi /home/pi/weather_station/sensors.py
```

Then rerun:

```bash
cd /home/pi/weather_station
python3 wind_test.py --config /data/configs/weather_station_config.ini --count 20
```

A better result should show `channel=ready`. If it still has no voltage after that, then we’re past the code-level pin issue and into ADC wiring/address/channel/debug territory.
