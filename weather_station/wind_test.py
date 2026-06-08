#!/usr/bin/env python3
from __future__ import annotations

import argparse
import time
from datetime import datetime

from sensors import SensorSuite
from weather_station import read_config


def print_event(event_type: str, message: str, exc: BaseException | None = None) -> None:
    detail = f" | {type(exc).__name__}: {exc}" if exc is not None else ""
    print(f"{event_type}: {message}{detail}")


def get_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Read the weather station wind ADC directly.")
    parser.add_argument("--config", default="/home/pi/data/configs/weather_station_config.ini")
    parser.add_argument("--count", type=int, default=20)
    parser.add_argument("--interval", type=float, default=1.0)
    return parser.parse_args()


def main() -> None:
    args = get_args()
    cfg = read_config(args.config)
    sensors = SensorSuite(
        wind_calibration=cfg.wind_calibration,
        wind_adc_config=cfg.wind_adc_config,
        error_handler=print_event,
        error_log_interval_sec=0,
    )

    print(sensors.wind_debug_summary())
    try:
        for _index in range(max(1, args.count)):
            reading = sensors.read()
            voltage = "--" if reading.wind_voltage_v is None else f"{reading.wind_voltage_v:.4f} V"
            speed = "--" if reading.wind_speed_m_s is None else f"{reading.wind_speed_m_s:.2f} m/s"
            print(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} wind_voltage={voltage} wind_speed={speed}")
            time.sleep(max(0.1, args.interval))
    finally:
        sensors.deinit()


if __name__ == "__main__":
    main()
