# Weather Station Setup

This folder is a standalone weather-station install surface. It does not depend
on the BeeCam camera service.

The runtime reads the SHT31D temperature/humidity sensor, BMP3XX pressure sensor,
and ADS1115 wind sensor used by the previous station code. Readings are displayed
on the OLED and appended to daily tab-separated text files under:

```bash
/data/weather/YYYY-MM-DD/<station_name>_YYYY-MM-DD.txt
```

Exception events are written to:

```bash
/data/logs/weather_station_exception_log.csv
```

## Quick Start

On a fresh Raspberry Pi, clone the setup repo and run the weather-station
installer from this folder:

```bash
cd ~/setup/weather_station
chmod +x install_weather_station.sh scripts/weather-station-init-data.sh partition_weather_station_sd_on_pc.sh
./install_weather_station.sh
```

Then shut down, move the card to a Linux PC/laptop, and run:

```bash
./partition_weather_station_sd_on_pc.sh
```

The partition script creates or reuses the exFAT `/data` partition and seeds
`/data/configs` with `weather_station_config.ini` and `schedule.conf`.

## Scheduling

Witty Pi uses the same scheduling flow as BeeCam:

- `wittypi/beforeScript.sh` initializes `/data`, syncs time, and generates
  `/home/pi/wittypi/schedule.wpi` from `/data/configs/schedule.conf`
- `wittypi/afterStartup.sh` starts `weather-station.service`
- `wittypi/beforeShutdown.sh` stops `weather-station.service`
- Witty Pi logs are linked into `/data/logs`

`weather-station.service` is installed but intentionally disabled; Witty Pi
starts and stops it.
