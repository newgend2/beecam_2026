# Weather Station Setup

This folder is a standalone weather-station install surface. It does not depend
on the BeeCam camera service.

The runtime reads the SHT31D temperature/humidity sensor, BMP3XX pressure sensor,
and ADS1115 wind sensor used by the previous station code. Readings are displayed
on the OLED and appended to daily tab-separated text files under:

```bash
/home/pi/data/weather/YYYY-MM-DD/<station_name>_YYYY-MM-DD.txt
```

Exception events are written to:

```bash
/home/pi/data/logs/weather_station_exception_log.csv
```

The weather data file also includes `wind_voltage_v` so wind-speed blanks can be
distinguished from a working ADC that is simply reading below the calibrated
wind threshold.

## Quick Start

On a fresh Raspberry Pi, paste this from the default `/home/pi` directory:

```bash
sudo apt update && sudo apt install -y git && git clone --branch main --single-branch https://github.com/newgend2/beecam_2026.git setup && cd setup/weather_station && chmod +x install_weather_station.sh scripts/weather-station-init-data.sh && ./install_weather_station.sh --skip-apt-update
```

If the repo has already been cloned, rerun the installer with:

```bash
cd ~/setup && git pull --ff-only && cd weather_station && chmod +x install_weather_station.sh scripts/weather-station-init-data.sh && ./install_weather_station.sh
```

The installer creates `/home/pi/data/configs`, `/home/pi/data/logs`, and
`/home/pi/data/weather`. It seeds configs from `weather_station/configs` only
when `/home/pi/data/configs` does not already exist.

The installer skips `apt-get full-upgrade` by default. For a slower full OS
refresh, run:

```bash
./install_weather_station.sh --full-upgrade
```

Use `--skip-apt-update` only when `sudo apt update` was already run immediately
before the installer.

## Scheduling

Witty Pi uses the same scheduling flow as BeeCam:

- `wittypi/beforeScript.sh` initializes `/home/pi/data`, syncs time, and generates
  `/home/pi/wittypi/schedule.wpi` from `/home/pi/data/configs/schedule.conf`
- `wittypi/afterStartup.sh` starts `weather-station.service`
- `wittypi/beforeShutdown.sh` stops `weather-station.service`
- Witty Pi logs are linked into `/home/pi/data/logs`

`weather-station.service` is installed but intentionally disabled; Witty Pi
starts and stops it.

## Wind Sensor Check

To test the ADS1115 wind path directly on the Pi:

```bash
cd /home/pi/weather_station
python3 wind_test.py --config /home/pi/data/configs/weather_station_config.ini --count 20
```

If the test reports that the ADS1115 channel is unavailable, check
`/home/pi/data/logs/weather_station_exception_log.csv` for `ads1115_*` events.
If the voltage prints but wind speed stays `0.00 m/s`, the ADC is working and
the value is below the configured calibration threshold in
`/home/pi/data/configs/weather_station_config.ini`.
