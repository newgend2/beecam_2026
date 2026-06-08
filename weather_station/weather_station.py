#!/usr/bin/env python3
from __future__ import annotations

import argparse
import configparser
import csv
import os
import re
import shutil
import signal
import socket
import sys
import threading
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from sensors import ErrorThrottle, SensorSuite, WeatherReading, WindAdcConfig, WindCalibration


try:
    from PIL import Image, ImageDraw, ImageFont
    import board
    import adafruit_ssd1306

    OLED_AVAILABLE = True
except Exception:  # pragma: no cover - depends on Raspberry Pi hardware libs
    OLED_AVAILABLE = False


hostname = socket.gethostname()
DATA_ROOT = "/home/pi/data"
cfg = None
log_lock = threading.Lock()
status_lock = threading.Lock()


@dataclass(frozen=True)
class AppConfig:
    unit_name: str
    save_root: str
    sample_interval_sec: float

    storage_check_path: str
    storage_stop_percent: float
    storage_check_interval_sec: float

    schedule_wpi_path: str

    oled_enabled: bool
    oled_refresh_sec: float

    restart_on_exception: bool
    restart_delay_sec: float
    exception_log_path: str

    wind_calibration: WindCalibration
    wind_adc_config: WindAdcConfig
    sensor_error_log_interval_sec: float


@dataclass
class SharedStatus:
    state: str = "BOOT"
    disk_used_percent: float = 0.0
    readings_today: int = 0
    latest_reading: WeatherReading | None = None
    schedule_message: str | None = None
    startup_short: str = "--:--"
    shutdown_short: str = "--:--"
    storage_locked: bool = False


status = SharedStatus()


def str_to_bool(value: str | None, default: bool = False) -> bool:
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def read_config(config_path: str) -> AppConfig:
    parser = configparser.ConfigParser()
    if not parser.read(config_path):
        raise FileNotFoundError(f"Could not read config file: {config_path}")

    def get(section: str, key: str, fallback: str = "") -> str:
        return parser.get(section, key, fallback=fallback)

    def getfloat(section: str, key: str, fallback: float) -> float:
        return parser.getfloat(section, key, fallback=fallback)

    def getbool(section: str, key: str, fallback: bool = False) -> bool:
        return str_to_bool(parser.get(section, key, fallback=None), fallback)

    def getint_auto(section: str, key: str, fallback: int) -> int:
        raw = parser.get(section, key, fallback=str(fallback)).strip()
        return int(raw, 0)

    def getoptional_int_auto(section: str, key: str) -> int | None:
        raw = parser.get(section, key, fallback="").strip()
        return int(raw, 0) if raw else None

    unit_name = get("weather", "unit_name", fallback="").strip() or hostname

    return AppConfig(
        unit_name=unit_name,
        save_root=os.path.expanduser(get("weather", "save_root", fallback=f"{DATA_ROOT}/weather")),
        sample_interval_sec=getfloat("weather", "sample_interval_sec", fallback=2.0),
        storage_check_path=os.path.expanduser(get("storage", "check_path", fallback=DATA_ROOT)),
        storage_stop_percent=getfloat("storage", "stop_percent", fallback=97.0),
        storage_check_interval_sec=getfloat("storage", "check_interval_sec", fallback=60.0),
        schedule_wpi_path=os.path.expanduser(
            get("schedule", "schedule_wpi_path", fallback="/home/pi/wittypi/schedule.wpi")
        ),
        oled_enabled=getbool("oled", "enabled", fallback=True),
        oled_refresh_sec=getfloat("oled", "refresh_sec", fallback=1.0),
        restart_on_exception=getbool("service", "restart_on_exception", fallback=True),
        restart_delay_sec=getfloat("service", "restart_delay_sec", fallback=2.0),
        exception_log_path=os.path.expanduser(
            get("logging", "exception_log_path", fallback=f"{DATA_ROOT}/logs/weather_station_exception_log.csv")
        ),
        wind_calibration=WindCalibration(
            voltage_offset=getfloat("wind", "voltage_offset", fallback=0.00575),
            min_voltage=getfloat("wind", "min_voltage", fallback=0.4),
            max_voltage=getfloat("wind", "max_voltage", fallback=2.0),
            max_speed_m_s=getfloat("wind", "max_speed_m_s", fallback=32.4),
        ),
        wind_adc_config=WindAdcConfig(
            address=getint_auto("wind", "ads_address", fallback=0x48),
            gain=getfloat("wind", "ads_gain", fallback=1.0),
            data_rate=getoptional_int_auto("wind", "ads_data_rate"),
            mode=get("wind", "ads_mode", fallback="differential"),
            positive_pin=get("wind", "ads_positive_pin", fallback="P0"),
            negative_pin=get("wind", "ads_negative_pin", fallback="P1"),
        ),
        sensor_error_log_interval_sec=getfloat("sensors", "error_log_interval_sec", fallback=60.0),
    )


def format_exception_name_and_message(exc: BaseException) -> str:
    return f"{type(exc).__name__}: {exc}"


def log_exception_event(event_type: str, message: str, exc: BaseException | None = None) -> None:
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    detail = str(exc) if exc is not None else ""
    path = cfg.exception_log_path if cfg is not None else f"{DATA_ROOT}/logs/weather_station_exception_log.csv"

    directory = os.path.dirname(path)
    if directory:
        try:
            os.makedirs(directory, exist_ok=True)
        except Exception:
            pass

    line = f"{timestamp}\t{event_type}\t{message}\t{detail}\n"
    try:
        with log_lock:
            new_file = not os.path.exists(path)
            with open(path, "a", encoding="utf-8") as f:
                if new_file:
                    f.write("timestamp\tevent_type\tmessage\texception\n")
                f.write(line)
    except Exception as log_exc:
        print(f"Failed to write exception log: {log_exc}", file=sys.stderr)
        print(line.rstrip(), file=sys.stderr)


def get_disk_used_percent(path: str) -> float:
    total, used, _free = shutil.disk_usage(path)
    if total <= 0:
        return 100.0
    return (used / total) * 100.0


def safe_disk_used_percent(path: str) -> float:
    try:
        return get_disk_used_percent(path)
    except Exception as exc:
        log_exception_event("storage_check_error", f"Could not check storage at {path}", exc)
        return 100.0


def shorten_schedule_time(dt_str: str) -> str:
    try:
        return datetime.strptime(dt_str, "%Y-%m-%d %H:%M:%S").strftime("%H:%M")
    except Exception:
        return "??:??"


def parse_schedule_wpi(path: str) -> dict[str, str | bool | None]:
    if not os.path.exists(path):
        return {
            "ok": False,
            "startup_short": "--:--",
            "shutdown_short": "--:--",
            "message": "No schedule.wpi found",
        }

    startup = None
    shutdown = None
    startup_re = re.compile(r"^#\s*Startup at:\s*(.+?)\s*$")
    shutdown_re = re.compile(r"^#\s*Shutdown at:\s*(.+?)\s*$")

    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                startup_match = startup_re.match(line)
                if startup_match:
                    startup = startup_match.group(1)
                    continue
                shutdown_match = shutdown_re.match(line)
                if shutdown_match:
                    shutdown = shutdown_match.group(1)
    except Exception as exc:
        log_exception_event("schedule_read_error", "Could not read schedule.wpi", exc)
        return {
            "ok": False,
            "startup_short": "--:--",
            "shutdown_short": "--:--",
            "message": "Schedule read error",
        }

    if not startup and not shutdown:
        return {
            "ok": False,
            "startup_short": "--:--",
            "shutdown_short": "--:--",
            "message": "No schedule info",
        }

    return {
        "ok": True,
        "startup_short": shorten_schedule_time(startup) if startup else "--:--",
        "shutdown_short": shorten_schedule_time(shutdown) if shutdown else "--:--",
        "message": None,
    }


def sanitize_filename_part(value: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", value.strip())
    return safe[:64].strip("._") or "weather_station"


def format_data_value(value: float | None) -> str:
    return "" if value is None else f"{value:.2f}"


class WeatherDataWriter:
    fieldnames = [
        "timestamp",
        "station_name",
        "temperature_c",
        "relative_humidity_percent",
        "pressure_hpa",
        "wind_speed_m_s",
        "wind_voltage_v",
    ]

    def __init__(self, save_root: str, station_name: str):
        self.save_root = Path(save_root)
        self.station_name = station_name
        self.safe_station_name = sanitize_filename_part(station_name)

    def day_dir(self, timestamp: datetime | None = None) -> Path:
        timestamp = timestamp or datetime.now()
        return self.save_root / timestamp.strftime("%Y-%m-%d")

    def file_path(self, timestamp: datetime | None = None) -> Path:
        timestamp = timestamp or datetime.now()
        day = timestamp.strftime("%Y-%m-%d")
        return self.day_dir(timestamp) / f"{self.safe_station_name}_{day}.txt"

    def count_today(self) -> int:
        path = self.file_path(datetime.now())
        if not path.exists():
            return 0
        try:
            with open(path, "r", encoding="utf-8", newline="") as f:
                return max(0, sum(1 for _line in f) - 1)
        except Exception:
            return 0

    def fieldnames_for_path(self, path: Path) -> list[str]:
        if not path.exists() or path.stat().st_size == 0:
            return self.fieldnames
        try:
            with open(path, "r", encoding="utf-8", newline="") as f:
                first_line = f.readline().strip()
            existing_fieldnames = [name.strip() for name in first_line.split("\t") if name.strip()]
            if "timestamp" in existing_fieldnames and "station_name" in existing_fieldnames:
                return existing_fieldnames
        except Exception:
            pass
        return self.fieldnames

    def write(self, reading: WeatherReading, timestamp: datetime | None = None) -> Path:
        timestamp = timestamp or datetime.now()
        day_dir = self.day_dir(timestamp)
        day_dir.mkdir(parents=True, exist_ok=True)
        path = self.file_path(timestamp)
        new_file = not path.exists() or path.stat().st_size == 0
        fieldnames = self.fieldnames if new_file else self.fieldnames_for_path(path)

        row = {
            "timestamp": timestamp.strftime("%Y-%m-%d %H:%M:%S"),
            "station_name": self.station_name,
            "temperature_c": format_data_value(reading.temperature_c),
            "relative_humidity_percent": format_data_value(reading.relative_humidity_percent),
            "pressure_hpa": format_data_value(reading.pressure_hpa),
            "wind_speed_m_s": format_data_value(reading.wind_speed_m_s),
            "wind_voltage_v": "" if reading.wind_voltage_v is None else f"{reading.wind_voltage_v:.4f}",
        }

        with open(path, "a", encoding="utf-8", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=fieldnames, delimiter="\t", extrasaction="ignore")
            if new_file:
                writer.writeheader()
            writer.writerow(row)
        return path


class OledDisplay:
    def __init__(self):
        self.enabled = False
        self.width = 128
        self.height = 64

        if not OLED_AVAILABLE:
            print("OLED libraries not available; continuing without display", file=sys.stderr)
            return

        try:
            self.font = ImageFont.load_default()
            self._i2c = board.I2C()
            self._disp = adafruit_ssd1306.SSD1306_I2C(self.width, self.height, self._i2c)
            self._disp.fill(0)
            self._disp.show()
            self.enabled = True
        except Exception as exc:
            print(f"OLED init failed: {exc}", file=sys.stderr)
            self.enabled = False

    def show_lines(self, lines: list[str], line_height: int = 12) -> None:
        if not self.enabled:
            return
        try:
            image = Image.new("1", (self.width, self.height))
            draw = ImageDraw.Draw(image)
            draw.rectangle((0, 0, self.width, self.height), outline=0, fill=0)

            y = 1
            for index, line in enumerate(lines[:5]):
                draw_y = y + 1 if index == 0 else y
                draw.text((0, draw_y), fit_display_line(line), font=self.font, fill=255)
                y += line_height
                if index == 0:
                    y += 2

            self._disp.image(image)
            self._disp.show()
        except Exception as exc:
            log_exception_event("oled_render_error", "OLED render failed", exc)

    def clear(self) -> None:
        if not self.enabled:
            return
        try:
            self._disp.fill(0)
            self._disp.show()
        except Exception:
            pass


def fit_display_line(value: str, max_chars: int = 21) -> str:
    text = str(value)
    if len(text) <= max_chars:
        return text
    return text[: max_chars - 1] + "."


def display_value(value: float | None, unit: str, digits: int = 1) -> str:
    if value is None:
        return f"--{unit}"
    return f"{value:.{digits}f}{unit}"


def _oled_show_safe(oled: OledDisplay | None, lines: list[str], timeout: float = 2.0) -> None:
    if oled is None or not getattr(oled, "enabled", False):
        return
    thread = threading.Thread(target=oled.show_lines, args=(lines,), daemon=True)
    thread.start()
    thread.join(timeout=timeout)


class OledWorker(threading.Thread):
    def __init__(self, display: OledDisplay, stop_event: threading.Event):
        super().__init__(daemon=True)
        self.display = display
        self.stop_event = stop_event

    def run(self) -> None:
        if not self.display.enabled:
            return

        while not self.stop_event.is_set():
            with status_lock:
                reading = status.latest_reading
                state = status.state
                disk_percent = int(round(status.disk_used_percent))
                readings_today = status.readings_today

            station = fit_display_line(cfg.unit_name, max_chars=8)
            line1 = f"{station} {datetime.now().strftime('%m-%d %H:%M')}"

            if reading is None:
                line2 = "Sensors starting"
                line3 = ""
                line4 = ""
            else:
                line2 = (
                    f"T {display_value(reading.temperature_c, 'C')} "
                    f"RH {display_value(reading.relative_humidity_percent, '%')}"
                )
                line3 = f"P {display_value(reading.pressure_hpa, 'hPa')}"
                wind_voltage = "--V" if reading.wind_voltage_v is None else f"{reading.wind_voltage_v:.3f}V"
                line4 = f"W {display_value(reading.wind_speed_m_s, 'm/s')} {wind_voltage}"

            line5 = f"SD {disk_percent}% R {readings_today}"
            if state in {"FULL", "ERROR", "RESTART"}:
                line5 = f"SD {disk_percent}% {state}"

            self.display.show_lines([line1, line2, line3, line4, line5])
            self.stop_event.wait(cfg.oled_refresh_sec)


class StorageMonitor(threading.Thread):
    def __init__(self, stop_event: threading.Event):
        super().__init__(daemon=True)
        self.stop_event = stop_event

    def run(self) -> None:
        while not self.stop_event.is_set():
            try:
                pct = get_disk_used_percent(cfg.storage_check_path)
                with status_lock:
                    status.disk_used_percent = pct
                    if pct >= cfg.storage_stop_percent:
                        status.storage_locked = True
                        status.state = "FULL"
                    elif status.storage_locked and pct < cfg.storage_stop_percent:
                        status.storage_locked = False
                        status.state = "RUNNING"
            except Exception as exc:
                log_exception_event("storage_monitor_error", "Storage monitor exception", exc)
            self.stop_event.wait(cfg.storage_check_interval_sec)


def restart_self(reason: str, oled: OledDisplay | None = None) -> None:
    log_exception_event("restart", reason)
    print(reason, file=sys.stderr)

    with status_lock:
        status.state = "RESTART"
        disk_pct = int(round(status.disk_used_percent))
        readings_today = status.readings_today

    _oled_show_safe(
        oled,
        [
            f"{hostname} {datetime.now().strftime('%m-%d %H:%M')}",
            f"Err: {reason.split(':')[0][:16]}",
            f"Rows {readings_today}",
            f"SD {disk_pct}%",
            "Restarting...",
        ],
    )

    if cfg is None or not cfg.restart_on_exception:
        return
    time.sleep(max(0.0, cfg.restart_delay_sec))
    os.execv(sys.executable, [sys.executable] + sys.argv)


def get_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default=f"{DATA_ROOT}/configs/weather_station_config.ini")
    return parser.parse_args()


def write_hostname_file() -> None:
    try:
        os.makedirs(DATA_ROOT, exist_ok=True)
        with open(os.path.join(DATA_ROOT, "hostname"), "w", encoding="utf-8") as f:
            f.write(hostname + "\n")
    except Exception:
        pass


def main() -> None:
    global cfg

    args = get_args()
    cfg = read_config(args.config)

    oled = OledDisplay()
    if not cfg.oled_enabled:
        oled.enabled = False

    _oled_show_safe(
        oled,
        [
            f"{hostname} {datetime.now().strftime('%m-%d %H:%M')}",
            "Initializing...",
            "",
            "",
            "INIT",
        ],
    )

    write_hostname_file()

    writer = WeatherDataWriter(cfg.save_root, cfg.unit_name)
    schedule_info = parse_schedule_wpi(cfg.schedule_wpi_path)
    initial_disk_pct = safe_disk_used_percent(cfg.storage_check_path)

    with status_lock:
        status.readings_today = writer.count_today()
        status.disk_used_percent = initial_disk_pct
        status.startup_short = str(schedule_info["startup_short"])
        status.shutdown_short = str(schedule_info["shutdown_short"])
        status.schedule_message = schedule_info["message"] if schedule_info["message"] else None
        status.storage_locked = initial_disk_pct >= cfg.storage_stop_percent
        status.state = "FULL" if status.storage_locked else "INIT"

    stop_event = threading.Event()
    storage_monitor = StorageMonitor(stop_event)
    oled_worker = OledWorker(oled, stop_event)
    storage_monitor.start()
    oled_worker.start()

    def _sigterm_handler(_signum, _frame):
        with status_lock:
            status.state = "STOPPING"
        stop_event.set()

    signal.signal(signal.SIGTERM, _sigterm_handler)

    sensors = None
    write_error_throttle = ErrorThrottle(60.0)

    try:
        sensors = SensorSuite(
            wind_calibration=cfg.wind_calibration,
            wind_adc_config=cfg.wind_adc_config,
            error_handler=log_exception_event,
            error_log_interval_sec=cfg.sensor_error_log_interval_sec,
        )
        log_exception_event("sensor_status", sensors.wind_debug_summary())

        with status_lock:
            if not status.storage_locked:
                status.state = "RUNNING"

        print("weather_station started")

        while not stop_event.is_set():
            reading_time = datetime.now()
            reading = sensors.read()

            with status_lock:
                status.latest_reading = reading
                storage_locked = status.storage_locked
                if not storage_locked:
                    status.state = "READING" if not reading.has_any_value() else "RUNNING"

            if not storage_locked:
                try:
                    writer.write(reading, reading_time)
                    with status_lock:
                        status.readings_today += 1
                        status.state = "SAVED"
                except Exception as exc:
                    if write_error_throttle.should_log("weather_write_error"):
                        log_exception_event("weather_write_error", "Failed to write weather reading", exc)
                    with status_lock:
                        status.state = "ERROR"

            stop_event.wait(max(0.1, cfg.sample_interval_sec))

    except KeyboardInterrupt:
        with status_lock:
            status.state = "STOPPING"
    except Exception as exc:
        stop_event.set()
        restart_self(format_exception_name_and_message(exc), oled)
        raise
    finally:
        stop_event.set()
        try:
            storage_monitor.join(timeout=2)
            oled_worker.join(timeout=2)
        except Exception:
            pass

        if sensors is not None:
            sensors.deinit()

        with status_lock:
            final_state = status.state
            disk_pct = int(round(status.disk_used_percent))
            readings_today = status.readings_today

        if final_state == "STOPPING":
            _oled_show_safe(
                oled,
                [
                    f"{hostname} {datetime.now().strftime('%m-%d %H:%M')}",
                    f"Rows {readings_today}",
                    f"SD {disk_pct}%",
                    "",
                    "Weather stopping",
                ],
            )
            time.sleep(2.0)
            oled.clear()
        else:
            _oled_show_safe(
                oled,
                [
                    f"{hostname} {datetime.now().strftime('%m-%d %H:%M')}",
                    f"Rows {readings_today}",
                    f"SD {disk_pct}%",
                    "",
                    final_state,
                ],
            )


if __name__ == "__main__":
    main()
