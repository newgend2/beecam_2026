#!/usr/bin/env python3
from __future__ import annotations

import math
import sys
import time
from dataclasses import dataclass
from typing import Callable


try:
    import board
    BOARD_IMPORT_ERROR = None
except Exception as exc:  # pragma: no cover - depends on Raspberry Pi hardware libs
    board = None
    BOARD_IMPORT_ERROR = exc

try:
    import adafruit_sht31d
    SHT31D_IMPORT_ERROR = None
except Exception as exc:  # pragma: no cover - depends on Raspberry Pi hardware libs
    adafruit_sht31d = None
    SHT31D_IMPORT_ERROR = exc

try:
    import adafruit_bmp3xx
    BMP3XX_IMPORT_ERROR = None
except Exception as exc:  # pragma: no cover - depends on Raspberry Pi hardware libs
    adafruit_bmp3xx = None
    BMP3XX_IMPORT_ERROR = exc

try:
    import adafruit_ads1x15.ads1115 as ADS
    from adafruit_ads1x15.analog_in import AnalogIn
    ADS1115_IMPORT_ERROR = None
except Exception as exc:  # pragma: no cover - depends on Raspberry Pi hardware libs
    ADS = None
    AnalogIn = None
    ADS1115_IMPORT_ERROR = exc


ErrorHandler = Callable[[str, str, BaseException | None], None]


@dataclass(frozen=True)
class WindCalibration:
    voltage_offset: float = 0.00575
    min_voltage: float = 0.4
    max_voltage: float = 2.0
    max_speed_m_s: float = 32.4


@dataclass(frozen=True)
class WindAdcConfig:
    address: int = 0x48
    gain: float = 1.0
    data_rate: int | None = None
    mode: str = "differential"
    positive_pin: str = "P0"
    negative_pin: str = "P1"


@dataclass(frozen=True)
class WeatherReading:
    temperature_c: float | None
    relative_humidity_percent: float | None
    pressure_hpa: float | None
    wind_speed_m_s: float | None
    wind_voltage_v: float | None = None

    def has_any_value(self) -> bool:
        return any(
            value is not None
            for value in (
                self.temperature_c,
                self.relative_humidity_percent,
                self.pressure_hpa,
                self.wind_speed_m_s,
            )
        )


def adc_to_wind_speed(voltage: float | None, calibration: WindCalibration | None = None) -> float | None:
    """Convert the ADS1115 differential voltage to wind speed using the legacy field calibration."""
    if voltage is None:
        return None

    calibration = calibration or WindCalibration()
    span = calibration.max_voltage - calibration.min_voltage
    if span <= 0:
        raise ValueError("Wind calibration max_voltage must be greater than min_voltage")

    adjusted_voltage = max(float(voltage) - calibration.voltage_offset, calibration.min_voltage)
    speed = ((adjusted_voltage - calibration.min_voltage) / span) * calibration.max_speed_m_s
    return max(0.0, speed)


def _round_or_none(value: float | None, digits: int = 2) -> float | None:
    if value is None:
        return None
    try:
        numeric_value = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(numeric_value):
        return None
    return round(numeric_value, digits)


def _default_error_handler(event_type: str, message: str, exc: BaseException | None = None) -> None:
    detail = f": {exc}" if exc is not None else ""
    print(f"{event_type}: {message}{detail}", file=sys.stderr)


class ErrorThrottle:
    def __init__(self, interval_sec: float = 60.0):
        self.interval_sec = max(0.0, float(interval_sec))
        self._last_logged_at: dict[str, float] = {}

    def should_log(self, key: str) -> bool:
        now = time.monotonic()
        last = self._last_logged_at.get(key)
        if last is None or now - last >= self.interval_sec:
            self._last_logged_at[key] = now
            return True
        return False


class SensorSuite:
    """Small hardware facade for the weather station's I2C sensors."""

    def __init__(
        self,
        i2c=None,
        wind_calibration: WindCalibration | None = None,
        wind_adc_config: WindAdcConfig | None = None,
        error_handler: ErrorHandler | None = None,
        error_log_interval_sec: float = 60.0,
    ):
        self.error_handler = error_handler or _default_error_handler
        self.error_throttle = ErrorThrottle(error_log_interval_sec)
        self.wind_calibration = wind_calibration or WindCalibration()
        self.wind_adc_config = wind_adc_config or WindAdcConfig()
        self.i2c = i2c
        self._owns_i2c = i2c is None

        self._temp_rh = None
        self._pressure = None
        self._wind_adc = None
        self._wind_channel = None
        self.last_wind_voltage_v = None

        if self.i2c is None:
            if board is None:
                self._emit(
                    "board_import",
                    "sensor_init_error",
                    "Could not import board; sensor I2C bus is unavailable",
                    BOARD_IMPORT_ERROR,
                )
                return
            try:
                self.i2c = board.I2C()
            except Exception as exc:
                self._emit("i2c_init", "sensor_init_error", "Could not initialize I2C bus", exc)
                return

        self._temp_rh = self._init_temperature_humidity_sensor()
        self._pressure = self._init_pressure_sensor()
        self._wind_channel = self._init_wind_sensor()

    def _emit(
        self,
        key: str,
        event_type: str,
        message: str,
        exc: BaseException | None = None,
    ) -> None:
        if self.error_throttle.should_log(key):
            self.error_handler(event_type, message, exc)

    def _ads_pin(self, pin_name: str):
        key = pin_name.strip().upper()
        if key and key[0].isdigit():
            key = f"P{key}"
        if not key.startswith("P"):
            key = f"P{key}"
        if ADS is None or not hasattr(ADS, key):
            raise ValueError(f"Unsupported ADS1115 pin '{pin_name}'")
        return getattr(ADS, key), key

    def _init_temperature_humidity_sensor(self):
        if adafruit_sht31d is None:
            self._emit(
                "sht31d_import",
                "sensor_init_error",
                "Could not import adafruit_sht31d; temperature/humidity disabled",
                SHT31D_IMPORT_ERROR,
            )
            return None
        try:
            return adafruit_sht31d.SHT31D(self.i2c)
        except Exception as exc:
            self._emit(
                "sht31d_init",
                "sensor_init_error",
                "Temperature/humidity sensor initialization failed",
                exc,
            )
            return None

    def _init_pressure_sensor(self):
        if adafruit_bmp3xx is None:
            self._emit(
                "bmp3xx_import",
                "sensor_init_error",
                "Could not import adafruit_bmp3xx; pressure disabled",
                BMP3XX_IMPORT_ERROR,
            )
            return None
        try:
            return adafruit_bmp3xx.BMP3XX_I2C(self.i2c)
        except Exception as exc:
            self._emit("bmp3xx_init", "sensor_init_error", "Pressure sensor initialization failed", exc)
            return None

    def _init_wind_sensor(self):
        if ADS is None or AnalogIn is None:
            self._emit(
                "ads1115_import",
                "sensor_init_error",
                "Could not import ADS1115 libraries; wind speed disabled",
                ADS1115_IMPORT_ERROR,
            )
            return None
        try:
            config = self.wind_adc_config
            self._wind_adc = ADS.ADS1115(self.i2c, address=config.address)
            self._wind_adc.gain = config.gain
            if config.data_rate is not None:
                self._wind_adc.data_rate = config.data_rate

            positive_pin, positive_name = self._ads_pin(config.positive_pin)
            mode = config.mode.strip().lower().replace("-", "_")
            if mode in {"single", "single_ended", "singleended"}:
                channel = AnalogIn(self._wind_adc, positive_pin)
                pin_summary = positive_name
            elif mode in {"diff", "differential"}:
                negative_pin, negative_name = self._ads_pin(config.negative_pin)
                channel = AnalogIn(self._wind_adc, positive_pin, negative_pin)
                pin_summary = f"{positive_name}-{negative_name}"
            else:
                raise ValueError(f"Unsupported wind ADC mode '{config.mode}'")

            self._emit(
                "ads1115_init_ok",
                "sensor_status",
                (
                    "Wind sensor initialized "
                    f"address=0x{config.address:02x} mode={mode} pins={pin_summary} "
                    f"gain={config.gain} data_rate={config.data_rate or 'default'}"
                ),
            )
            return channel
        except Exception as exc:
            self._emit("ads1115_init", "sensor_init_error", "Wind sensor initialization failed", exc)
            return None

    def _read_attr(self, sensor, sensor_name: str, attr_name: str) -> float | None:
        if sensor is None:
            return None
        try:
            return getattr(sensor, attr_name)
        except Exception as exc:
            self._emit(
                f"{sensor_name}_{attr_name}_read",
                "sensor_read_error",
                f"Could not read {sensor_name} {attr_name}",
                exc,
            )
            return None

    def _read_wind_speed(self) -> float | None:
        if self._wind_channel is None:
            self._emit(
                "wind_channel_missing",
                "sensor_read_error",
                "Wind ADC channel is unavailable; check earlier ADS1115 initialization errors",
            )
            return None
        try:
            voltage = self._wind_channel.voltage
            self.last_wind_voltage_v = voltage
            return adc_to_wind_speed(voltage, self.wind_calibration)
        except Exception as exc:
            self._emit("wind_speed_read", "sensor_read_error", "Could not read wind speed", exc)
            return None

    def read(self) -> WeatherReading:
        return WeatherReading(
            temperature_c=_round_or_none(
                self._read_attr(self._temp_rh, "temperature_humidity", "temperature")
            ),
            relative_humidity_percent=_round_or_none(
                self._read_attr(self._temp_rh, "temperature_humidity", "relative_humidity")
            ),
            pressure_hpa=_round_or_none(self._read_attr(self._pressure, "pressure", "pressure")),
            wind_speed_m_s=_round_or_none(self._read_wind_speed()),
            wind_voltage_v=_round_or_none(self.last_wind_voltage_v, digits=4),
        )

    def wind_debug_summary(self) -> str:
        config = self.wind_adc_config
        channel_state = "ready" if self._wind_channel is not None else "unavailable"
        voltage = "--" if self.last_wind_voltage_v is None else f"{self.last_wind_voltage_v:.4f}V"
        return (
            f"ADS1115 address=0x{config.address:02x} mode={config.mode} "
            f"pins={config.positive_pin}-{config.negative_pin} gain={config.gain} "
            f"channel={channel_state} last_voltage={voltage}"
        )

    def deinit(self) -> None:
        if self._owns_i2c and self.i2c is not None and hasattr(self.i2c, "deinit"):
            try:
                self.i2c.deinit()
            except Exception:
                pass
