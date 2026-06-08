#!/usr/bin/python3
from __future__ import annotations

import datetime as dt
from pathlib import Path
from zoneinfo import ZoneInfo

from astral import Observer
from astral.sun import sun

CONFIG_PATH = Path("/home/pi/data/configs/schedule.conf")
OUT_PATH = Path("/home/pi/wittypi/schedule.wpi")


def load_config(path: Path) -> dict[str, str]:
    cfg: dict[str, str] = {}
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("#") or "=" not in s:
                continue
            k, v = s.split("=", 1)
            cfg[k.strip()] = v.strip()
    return cfg


def parse_hhmm(value: str) -> tuple[int, int]:
    h, m = value.split(":")
    return int(h), int(m)


def fmt_timestamp(ts: dt.datetime) -> str:
    return ts.strftime("%Y-%m-%d %H:%M:%S")


def duration_to_tokens(delta: dt.timedelta) -> str:
    total = int(delta.total_seconds())
    if total < 0:
        raise ValueError(f"Negative duration: {delta}")

    days, rem = divmod(total, 86400)
    hours, rem = divmod(rem, 3600)
    minutes, seconds = divmod(rem, 60)

    parts = []
    if days:
        parts.append(f"D{days}")
    if hours:
        parts.append(f"H{hours}")
    if minutes:
        parts.append(f"M{minutes}")
    if seconds or not parts:
        parts.append(f"S{seconds}")
    return " ".join(parts)


def next_occurrence(now: dt.datetime, hhmm: str) -> dt.datetime:
    hour, minute = parse_hhmm(hhmm)
    candidate = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if candidate <= now:
        candidate += dt.timedelta(days=1)
    return candidate


def solar_times(date_obj: dt.date, tz: ZoneInfo, lat: float, lon: float) -> tuple[dt.datetime, dt.datetime]:
    observer = Observer(latitude=lat, longitude=lon)
    s = sun(observer, date=date_obj, tzinfo=tz)
    return s["sunrise"], s["sunset"]


def generate_schedule_text(begin: dt.datetime, shutdown: dt.datetime, startup: dt.datetime, reason: str) -> str:
    if shutdown <= begin:
        raise RuntimeError(f"Invalid schedule: shutdown={shutdown}, begin={begin}")
    if startup <= shutdown:
        raise RuntimeError(f"Invalid schedule: startup={startup}, shutdown={shutdown}")

    on_duration = shutdown - begin
    off_duration = startup - shutdown
    end = (startup + dt.timedelta(minutes=1)).replace(microsecond=0)

    return f"""# Auto-generated schedule
# Reason: {reason}
# Generated at: {fmt_timestamp(begin)}
# Shutdown at:  {fmt_timestamp(shutdown)}
# Startup at:   {fmt_timestamp(startup)}
BEGIN {fmt_timestamp(begin.replace(microsecond=0))}
END   {fmt_timestamp(end)}
ON    {duration_to_tokens(on_duration)}
OFF   {duration_to_tokens(off_duration)}
"""


def generate_solar(cfg: dict[str, str], now: dt.datetime) -> str:
    tz = ZoneInfo(cfg.get("TIMEZONE", "America/Los_Angeles"))
    lat = float(cfg["LATITUDE"])
    lon = float(cfg["LONGITUDE"])
    sunrise_offset = int(cfg.get("SUNRISE_OFFSET_MIN", "0"))
    sunset_offset = int(cfg.get("SUNSET_OFFSET_MIN", "0"))
    after_hours_restart_delay_min = int(cfg.get("AFTER_HOURS_RESTART_DELAY_MIN", "2"))

    today = now.date()
    tomorrow = today + dt.timedelta(days=1)

    sunrise_today, sunset_today = solar_times(today, tz, lat, lon)
    sunrise_tomorrow, sunset_tomorrow = solar_times(tomorrow, tz, lat, lon)

    sunrise_today += dt.timedelta(minutes=sunrise_offset)
    sunset_today += dt.timedelta(minutes=sunset_offset)
    sunrise_tomorrow += dt.timedelta(minutes=sunrise_offset)
    sunset_tomorrow += dt.timedelta(minutes=sunset_offset)

    # Operating hours: run through today's daylight period
    if sunrise_today <= now < sunset_today:
        shutdown = sunset_today
        startup = sunrise_tomorrow
        reason = "daytime operating schedule"
        return generate_schedule_text(now, shutdown, startup, reason)

    # After midnight but before sunrise: use today's sunrise
    if now < sunrise_today:
        shutdown = sunrise_today
        startup = sunrise_today + dt.timedelta(minutes=after_hours_restart_delay_min)
        reason = "after-hours pre-sunrise recovery schedule"
        return generate_schedule_text(now, shutdown, startup, reason)

    # After sunset: use tomorrow's sunrise
    shutdown = sunrise_tomorrow
    startup = sunrise_tomorrow + dt.timedelta(minutes=after_hours_restart_delay_min)
    reason = "after-hours post-sunset recovery schedule"
    return generate_schedule_text(now, shutdown, startup, reason)


def generate_fixed(cfg: dict[str, str], now: dt.datetime) -> str:
    startup_str = cfg["FIXED_STARTUP"]
    shutdown_str = cfg["FIXED_SHUTDOWN"]
    after_hours_restart_delay_min = int(cfg.get("AFTER_HOURS_RESTART_DELAY_MIN", "2"))

    start_h, start_m = parse_hhmm(startup_str)
    shut_h, shut_m = parse_hhmm(shutdown_str)

    startup_today = now.replace(hour=start_h, minute=start_m, second=0, microsecond=0)
    shutdown_today = now.replace(hour=shut_h, minute=shut_m, second=0, microsecond=0)

    startup_tomorrow = startup_today + dt.timedelta(days=1)
    shutdown_tomorrow = shutdown_today + dt.timedelta(days=1)

    # During operating hours
    if startup_today <= now < shutdown_today:
        shutdown = shutdown_today
        startup = startup_tomorrow
        reason = "daytime fixed operating schedule"
        return generate_schedule_text(now, shutdown, startup, reason)

    # After midnight but before today's startup
    if now < startup_today:
        shutdown = startup_today
        startup = startup_today + dt.timedelta(minutes=after_hours_restart_delay_min)
        reason = "after-hours pre-start fixed recovery schedule"
        return generate_schedule_text(now, shutdown, startup, reason)

    # After today's shutdown
    shutdown = startup_tomorrow
    startup = startup_tomorrow + dt.timedelta(minutes=after_hours_restart_delay_min)
    reason = "after-hours post-shutdown fixed recovery schedule"
    return generate_schedule_text(now, shutdown, startup, reason)

def main() -> None:
    cfg = load_config(CONFIG_PATH)
    tz = ZoneInfo(cfg.get("TIMEZONE", "America/Los_Angeles"))
    now = dt.datetime.now(tz)
    mode = cfg.get("MODE", "solar").strip().lower()

    if mode == "solar":
        text = generate_solar(cfg, now)
    elif mode == "fixed":
        text = generate_fixed(cfg, now)
    else:
        raise ValueError(f"Unsupported MODE: {mode}")

    OUT_PATH.write_text(text, encoding="utf-8")
    print(text, end="")


if __name__ == "__main__":
    main()
