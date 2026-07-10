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


def generate_repeating_schedule_text(
    begin: dt.datetime,
    on_duration: dt.timedelta,
    off_duration: dt.timedelta,
    end: dt.datetime,
    reason: str,
    generated_at: dt.datetime,
    display_shutdown: dt.datetime,
    display_startup: dt.datetime,
) -> str:
    if on_duration <= dt.timedelta(0):
        raise RuntimeError(f"Invalid repeating schedule: on_duration={on_duration}")
    if off_duration <= dt.timedelta(0):
        raise RuntimeError(f"Invalid repeating schedule: off_duration={off_duration}")
    if end <= begin:
        raise RuntimeError(f"Invalid repeating schedule: end={end}, begin={begin}")

    return f"""# Auto-generated schedule
# Reason: {reason}
# Generated at: {fmt_timestamp(generated_at)}
# Shutdown at:  {fmt_timestamp(display_shutdown)}
# Startup at:   {fmt_timestamp(display_startup)}
# Repeating from: {fmt_timestamp(begin)}
# Repeating until: {fmt_timestamp(end)}
BEGIN {fmt_timestamp(begin.replace(microsecond=0))}
END   {fmt_timestamp(end.replace(microsecond=0))}
ON    {duration_to_tokens(on_duration)}
OFF   {duration_to_tokens(off_duration)}
"""


def generate_after_hours_recovery(
    cfg: dict[str, str],
    now: dt.datetime,
    startup: dt.datetime,
    reason: str,
) -> str:
    shutdown_delay_min = int(
        cfg.get("AFTER_HOURS_SHUTDOWN_DELAY_MIN", cfg.get("AFTER_HOURS_RESTART_DELAY_MIN", "3"))
    )
    shutdown = now + dt.timedelta(minutes=shutdown_delay_min)
    if startup <= shutdown:
        startup = shutdown + dt.timedelta(minutes=1)
    return generate_schedule_text(now, shutdown, startup, reason)


def generate_solar(cfg: dict[str, str], now: dt.datetime) -> str:
    tz = ZoneInfo(cfg.get("TIMEZONE", "America/Los_Angeles"))
    lat = float(cfg["LATITUDE"])
    lon = float(cfg["LONGITUDE"])
    sunrise_offset = int(cfg.get("SUNRISE_OFFSET_MIN", "0"))
    sunset_offset = int(cfg.get("SUNSET_OFFSET_MIN", "0"))
    after_hours_shutdown_delay_min = int(
        cfg.get("AFTER_HOURS_SHUTDOWN_DELAY_MIN", cfg.get("AFTER_HOURS_RESTART_DELAY_MIN", "3"))
    )

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
        if sunrise_today <= now + dt.timedelta(minutes=after_hours_shutdown_delay_min):
            reason = "near-sunrise operating schedule"
            return generate_schedule_text(now, sunset_today, sunrise_tomorrow, reason)
        return generate_after_hours_recovery(cfg, now, sunrise_today, "after-hours pre-sunrise recovery schedule")

    # After sunset: use tomorrow's sunrise
    return generate_after_hours_recovery(cfg, now, sunrise_tomorrow, "after-hours post-sunset recovery schedule")


def generate_fixed(cfg: dict[str, str], now: dt.datetime) -> str:
    startup_str = cfg["FIXED_STARTUP"]
    shutdown_str = cfg["FIXED_SHUTDOWN"]
    after_hours_shutdown_delay_min = int(
        cfg.get("AFTER_HOURS_SHUTDOWN_DELAY_MIN", cfg.get("AFTER_HOURS_RESTART_DELAY_MIN", "3"))
    )
    schedule_days = int(cfg.get("FIXED_SCHEDULE_DAYS", "3650"))

    start_h, start_m = parse_hhmm(startup_str)
    shut_h, shut_m = parse_hhmm(shutdown_str)

    startup_today = now.replace(hour=start_h, minute=start_m, second=0, microsecond=0)
    shutdown_today = now.replace(hour=shut_h, minute=shut_m, second=0, microsecond=0)

    startup_tomorrow = startup_today + dt.timedelta(days=1)
    shutdown_tomorrow = shutdown_today + dt.timedelta(days=1)

    if shutdown_today <= startup_today:
        raise RuntimeError("FIXED_SHUTDOWN must be later than FIXED_STARTUP on the same day")

    on_duration = shutdown_today - startup_today
    off_duration = startup_tomorrow - shutdown_today
    end = startup_today + dt.timedelta(days=schedule_days)

    # During operating hours
    if startup_today <= now < shutdown_today:
        return generate_repeating_schedule_text(
            startup_today,
            on_duration,
            off_duration,
            end,
            "fixed daily operating schedule",
            now,
            shutdown_today,
            startup_tomorrow,
        )

    # After midnight but before today's startup
    if now < startup_today:
        if startup_today <= now + dt.timedelta(minutes=after_hours_shutdown_delay_min):
            return generate_repeating_schedule_text(
                startup_today,
                on_duration,
                off_duration,
                end,
                "near-start fixed daily operating schedule",
                now,
                shutdown_today,
                startup_today,
            )
        return generate_after_hours_recovery(cfg, now, startup_today, "after-hours pre-start fixed recovery schedule")

    # After today's shutdown
    return generate_after_hours_recovery(cfg, now, startup_tomorrow, "after-hours post-shutdown fixed recovery schedule")

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
