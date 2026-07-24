#!/usr/bin/env python3

import argparse
import configparser
import os
import queue
import re
import shutil
import signal
import socket
import sys
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path

from libcamera import controls
from picamera2 import Picamera2
from picamera2.devices import IMX500
from picamera2.devices.imx500 import NetworkIntrinsics, postprocess_nanodet_detection


# Optional OLED dependencies. If unavailable, imaging still runs.
try:
    from PIL import Image, ImageDraw, ImageFont
    import board
    import adafruit_ssd1306
    OLED_AVAILABLE = True
except Exception:
    OLED_AVAILABLE = False


picam2 = None
imx500 = None
intrinsics = None
cfg = None
still_config = None
preview_config = None
save_queue = None
save_worker = None
save_stop_event = None

CAPTURE_STREAM = "main"
# IMX500 inference runs on the sensor's input tensor/ROI. This stream is the
# Picamera2 output used for preview/debug coordinates, not the model input.
DETECTION_STREAM = "lores"

capture_in_progress = False
last_capture_time = 0.0
last_detections = []
last_timelapse_time = 0.0
last_save_queue_full_log = 0.0
async_saves_completed = 0
async_saves_failed = 0
async_saves_dropped = 0
stale_tracks = []
stale_next_track_id = 1
stale_suppressed_total = 0
last_stale_suppression_log = 0.0

hostname = socket.gethostname()
DATA_ROOT = "/home/pi/data"

VERSION_FILE = Path(__file__).resolve().parent.parent / "VERSION"


def read_version() -> str:
    try:
        return VERSION_FILE.read_text(encoding="utf-8").strip() or "unknown"
    except OSError:
        return "unknown"


def short_version(value: str, max_chars: int = 5) -> str:
    # VERSION is "YYYY.MM.DD"; drop the year on space-constrained OLED lines
    # since the release date alone already answers "how stale is this".
    parts = value.split(".")
    if len(parts) == 3 and all(parts):
        return f"{parts[1]}.{parts[2]}"
    return value[-max_chars:]


# Set by time_init.sh when Witty Pi's daemon found the RTC had lost its time
# (a power outage longer than the ~17h supercap backup). Checked once at
# startup: past that point the clock is either fixed by NTP or still wrong
# for the rest of this boot, so there is no need to re-stat it every refresh.
TIME_UNKNOWN = os.path.exists(os.path.join(DATA_ROOT, ".time_unknown"))

# Register 11 (I2C_ACTION_REASON) value meaning "voltage crossed back above
# the Witty Pi recovery threshold after a low-voltage cutoff, while power
# stayed continuously connected." Written once per boot by
# wittypi/beforeScript.sh's record_wittypi_wake_reason() into
# /home/pi/data/.wake_reason. Read once here since it cannot change again
# until the next boot.
REASON_VOLTAGE_RESTORE = "0x05"
WAKE_REASON_FILE = os.path.join(DATA_ROOT, ".wake_reason")


def _read_wake_reason() -> str | None:
    try:
        with open(WAKE_REASON_FILE, "r", encoding="utf-8") as f:
            value = f.read().strip().lower()
            return value or None
    except OSError:
        return None


WAKE_REASON = _read_wake_reason()


def fit_display_line(value: str, max_chars: int = 21) -> str:
    text = str(value)
    if len(text) <= max_chars:
        return text
    return text[: max_chars - 1] + "."


VERSION = read_version()
SHORT_VERSION = short_version(VERSION)

# Monotonic timestamp captured when this process image started. Reset on every
# os.execv restart, so it measures how long the current run survived before failing.
PROCESS_START_MONOTONIC = time.monotonic()
cached_images_root = None
cached_images_day = None
cached_images_dir = None


@dataclass
class AppConfig:
    model_path: str
    labels_path: str
    save_root: str

    preview_width: int
    preview_height: int
    still_width: int
    still_height: int
    buffer_count_preview: int
    buffer_count_still: int
    async_save_queue_size: int
    fps: int
    capture_cooldown_sec: float

    threshold: float
    iou: float
    max_detections: int
    bbox_order: str
    bbox_normalization: bool
    ignore_dash_labels: bool
    preserve_aspect_ratio: bool
    postprocess: str | None

    stale_detection_enabled: bool
    stale_detection_sec: float
    stale_iou_threshold: float
    stale_center_threshold: float
    stale_expire_sec: float
    stale_area_ratio_min: float
    stale_area_ratio_max: float
    stale_log_interval_sec: float

    ae_enable: bool
    ae_exposure_mode: str
    exposure_time_us: int | None
    analogue_gain: float | None

    storage_check_path: str
    storage_stop_percent: float
    storage_check_interval_sec: float

    schedule_wpi_path: str

    low_battery_recovery_delay_min: float

    oled_enabled: bool
    oled_refresh_sec: float

    log_stale_detections: bool
    log_capture_queue: bool
    log_startup: bool
    fps_log_interval_sec: float

    timelapse_enabled: bool
    timelapse_interval_sec: float

    restart_on_exception: bool
    restart_delay_sec: float
    restart_backoff_max_sec: float
    restart_healthy_runtime_sec: float
    exception_log_path: str


@dataclass
class SharedStatus:
    state: str = "BOOT"
    disk_used_percent: float = 0.0
    rootfs_used_percent: float = 0.0
    image_count_today: int = 0
    schedule_message: str | None = None
    startup_short: str = "--:--"
    shutdown_short: str = "--:--"
    stop_due_to_storage: bool = False
    storage_locked: bool = False
    capture_mode_label: str = "MODEL"


status = SharedStatus()
status_lock = threading.Lock()
log_lock = threading.Lock()
save_stats_lock = threading.Lock()


@dataclass
class SaveJob:
    stem: str
    image_path: str
    detection_count: int
    request: object
    queued_monotonic: float | None
    queued_wall: str | None
    frame_age_ms: float | None


@dataclass
class StaleTrack:
    id: int
    category: int
    box: tuple
    conf: float
    first_seen: float
    last_seen: float
    last_capture: float
    suppressed_count: int = 0


def log_exception_event(event_type: str, message: str, exc: BaseException | None = None):
    global cfg
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    detail = str(exc) if exc is not None else ""
    path = None
    if cfg is not None:
        path = cfg.exception_log_path
    if not path:
        print(f"[{timestamp}] {event_type}: {message} {detail}", file=sys.stderr)
        return

    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
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


def str_to_bool(value: str, default: bool = False) -> bool:
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def read_config(config_path: str) -> AppConfig:
    parser = configparser.ConfigParser()
    if not parser.read(config_path):
        raise FileNotFoundError(f"Could not read config file: {config_path}")

    def get(section, key, fallback=None):
        return parser.get(section, key, fallback=fallback)

    def getint(section, key, fallback=None):
        return parser.getint(section, key, fallback=fallback)

    def getfloat(section, key, fallback=None):
        return parser.getfloat(section, key, fallback=fallback)

    def getbool(section, key, fallback=False):
        raw = parser.get(section, key, fallback=None)
        if raw is None:
            return fallback
        return str_to_bool(raw, fallback)

    exposure_time_us = get("exposure", "exposure_time_us", fallback="").strip()
    exposure_time_us = int(exposure_time_us) if exposure_time_us else None

    analogue_gain = get("exposure", "analogue_gain", fallback="").strip()
    analogue_gain = float(analogue_gain) if analogue_gain else None

    postprocess = get("model", "postprocess", fallback="").strip() or None
    return AppConfig(
        model_path=os.path.expanduser(get("model", "model_path", fallback="")),
        labels_path=os.path.expanduser(get("model", "labels_path", fallback="")),
        save_root=os.path.expanduser(get("camera", "save_root")),

        preview_width=getint("camera", "preview_width", fallback=640),
        preview_height=getint("camera", "preview_height", fallback=480),
        still_width=getint("camera", "still_width", fallback=2028),
        still_height=getint("camera", "still_height", fallback=1520),
        buffer_count_preview=getint("camera", "buffer_count_preview", fallback=4),
        buffer_count_still=getint("camera", "buffer_count_still", fallback=1),
        async_save_queue_size=getint("camera", "async_save_queue_size", fallback=2),
        fps=getint("camera", "fps", fallback=10),
        capture_cooldown_sec=getfloat("camera", "capture_cooldown_sec", fallback=0.1),

        threshold=getfloat("model", "threshold", fallback=0.30),
        iou=getfloat("model", "iou", fallback=0.65),
        max_detections=getint("model", "max_detections", fallback=10),
        bbox_order=get("model", "bbox_order", fallback="yx"),
        bbox_normalization=getbool("model", "bbox_normalization", fallback=False),
        ignore_dash_labels=getbool("model", "ignore_dash_labels", fallback=False),
        preserve_aspect_ratio=getbool("model", "preserve_aspect_ratio", fallback=False),
        postprocess=postprocess,

        stale_detection_enabled=getbool("stale_detection", "enabled", fallback=True),
        stale_detection_sec=getfloat("stale_detection", "detection_sec", fallback=7.0),
        stale_iou_threshold=getfloat("stale_detection", "iou_threshold", fallback=0.50),
        stale_center_threshold=getfloat("stale_detection", "center_threshold", fallback=0.10),
        stale_expire_sec=getfloat("stale_detection", "expire_sec", fallback=3.0),
        stale_area_ratio_min=getfloat("stale_detection", "area_ratio_min", fallback=0.50),
        stale_area_ratio_max=getfloat("stale_detection", "area_ratio_max", fallback=2.00),
        stale_log_interval_sec=getfloat("debug", "stale_log_interval_sec", fallback=5.0),

        ae_enable=getbool("exposure", "ae_enable", fallback=True),
        ae_exposure_mode=get("exposure", "ae_exposure_mode", fallback="short").strip().lower(),
        exposure_time_us=exposure_time_us,
        analogue_gain=analogue_gain,

        storage_check_path=os.path.expanduser(get("storage", "check_path", fallback=DATA_ROOT)),
        storage_stop_percent=getfloat("storage", "stop_percent", fallback=95.0),
        storage_check_interval_sec=getfloat("storage", "check_interval_sec", fallback=30.0),

        schedule_wpi_path=os.path.expanduser(get("schedule", "schedule_wpi_path", fallback="/home/pi/wittypi/schedule.wpi")),

        low_battery_recovery_delay_min=getfloat("power", "low_battery_recovery_delay_min", fallback=15.0),

        oled_enabled=getbool("oled", "enabled", fallback=True),
        oled_refresh_sec=getfloat("oled", "refresh_sec", fallback=1.0),

        log_stale_detections=getbool("debug", "log_stale_detections", fallback=False),
        log_capture_queue=getbool("debug", "log_capture_queue", fallback=False),
        log_startup=getbool("debug", "log_startup", fallback=False),
        fps_log_interval_sec=getfloat("debug", "fps_log_interval_sec", fallback=0.0),

        timelapse_enabled=getbool("timelapse", "enabled", fallback=False),
        timelapse_interval_sec=getfloat("timelapse", "interval_sec", fallback=60.0),

        restart_on_exception=getbool("service", "restart_on_exception", fallback=True),
        restart_delay_sec=getfloat("service", "restart_delay_sec", fallback=2.0),
        restart_backoff_max_sec=getfloat("service", "restart_backoff_max_sec", fallback=300.0),
        restart_healthy_runtime_sec=getfloat("service", "restart_healthy_runtime_sec", fallback=120.0),
        exception_log_path=os.path.expanduser(get("logging", "exception_log_path", fallback=f"{DATA_ROOT}/logs/beecam_exception_log.csv")),
    )


def format_exception_name_and_message(exc: BaseException) -> str:
    return f"{type(exc).__name__}: {exc}"


def cleanup_camera():
    global picam2, imx500, intrinsics, still_config, preview_config, capture_in_progress
    capture_in_progress = False
    stop_async_save_worker(timeout=5.0)
    try:
        if picam2 is not None:
            picam2.stop()
    except Exception:
        pass
    picam2 = None
    imx500 = None
    intrinsics = None
    still_config = None
    preview_config = None


def _oled_show_safe(oled: object | None, lines: list, timeout: float = 2.0):
    """Render lines on the OLED from a daemon thread so a hung I2C call can't block the caller."""
    if oled is None or not getattr(oled, "enabled", False):
        return
    t = threading.Thread(target=oled.show_lines, args=(lines,), daemon=True)
    t.start()
    t.join(timeout=timeout)


def restart_self(reason: str, oled: object | None = None):
    log_exception_event("restart", reason)
    print(reason, file=sys.stderr)

    with status_lock:
        status.state = "RESTART"
        img_count = status.image_count_today
        disk_pct = int(round(status.disk_used_percent))

    _oled_show_safe(oled, [
        f"{hostname} {datetime.now().strftime('%m-%d %H:%M')}",
        f"Err: {reason.split(':')[0][:16]}",
        f"Imgs {img_count}",
        f"SD  {disk_pct}%",
        "Restarting...",
    ])

    cleanup_camera()
    if not cfg.restart_on_exception:
        return

    # Exponential backoff with a health-based reset, persisted across os.execv via the
    # environment (which survives the re-exec). A persistent fault (dead camera, bad
    # model file) is capped at one retry per restart_backoff_max_sec instead of a tight
    # ~2s loop that drains the solar battery; a crash after a healthy run restarts fast.
    run_duration = time.monotonic() - PROCESS_START_MONOTONIC
    count = int(os.environ.get("BEECAM_RESTART_COUNT", "0"))
    if run_duration >= cfg.restart_healthy_runtime_sec:
        count = 0
    count += 1
    os.environ["BEECAM_RESTART_COUNT"] = str(count)
    backoff = min(
        cfg.restart_delay_sec * (2 ** (count - 1)),
        cfg.restart_backoff_max_sec,
    )
    time.sleep(max(0.0, backoff))
    os.execv(sys.executable, [sys.executable] + sys.argv)


def ae_exposure_mode_from_string(name: str):
    mapping = {
        "normal": controls.AeExposureModeEnum.Normal,
        "short": controls.AeExposureModeEnum.Short,
        "long": controls.AeExposureModeEnum.Long,
        "custom": controls.AeExposureModeEnum.Custom,
    }
    if name not in mapping:
        raise ValueError(f"Unsupported ae_exposure_mode '{name}'")
    return mapping[name]


def dated_images_dir(save_root: str):
    global cached_images_root, cached_images_day, cached_images_dir
    day = datetime.now().strftime("%Y-%m-%d")
    if cached_images_root == save_root and cached_images_day == day and cached_images_dir:
        return cached_images_dir

    base = os.path.join(save_root, day)
    images_dir = os.path.join(base, "images")
    os.makedirs(images_dir, exist_ok=True)
    cached_images_root = save_root
    cached_images_day = day
    cached_images_dir = images_dir
    return images_dir


def make_stem() -> str:
    now = datetime.now()
    ms = now.microsecond // 1000
    return f"{hostname}_{now.strftime('%Y-%m-%d_%H-%M-%S')}-{ms:03d}"


def get_today_images_dir(save_root: str) -> str:
    return os.path.join(save_root, datetime.now().strftime("%Y-%m-%d"), "images")


def count_today_images(save_root: str) -> int:
    images_dir = get_today_images_dir(save_root)
    if not os.path.isdir(images_dir):
        return 0
    try:
        return sum(1 for name in os.listdir(images_dir) if name.lower().endswith(".jpg"))
    except Exception:
        return 0


def existing_path_for_usage(path: str) -> str:
    current = os.path.abspath(path)
    while not os.path.exists(current):
        parent = os.path.dirname(current)
        if parent == current:
            return os.path.abspath(os.sep)
        current = parent
    return current


@dataclass
class StorageUsage:
    data_used_percent: float
    rootfs_used_percent: float


def get_storage_usage(path: str) -> StorageUsage:
    usage_path = existing_path_for_usage(path)
    total, _used, free = shutil.disk_usage(usage_path)
    if total <= 0:
        return StorageUsage(data_used_percent=100.0, rootfs_used_percent=100.0)
    # Fill relative to space writable by the non-root 'pi' user (free == statvfs
    # f_bavail). On ext4 the ~5% root-reserved blocks make used/total top out near
    # 95% at ENOSPC, so a used/total threshold never triggers. Available-based fill
    # hits ~100% exactly when pi can no longer write.
    used_percent = (total - free) / total * 100.0
    return StorageUsage(data_used_percent=used_percent, rootfs_used_percent=used_percent)


def storage_usage_exceeds_threshold(usage: StorageUsage) -> bool:
    return (
        usage.data_used_percent >= cfg.storage_stop_percent
        or usage.rootfs_used_percent >= cfg.storage_stop_percent
    )


def storage_locked_or_full() -> bool:
    with status_lock:
        return (
            status.storage_locked
            or status.disk_used_percent >= cfg.storage_stop_percent
            or status.rootfs_used_percent >= cfg.storage_stop_percent
        )


def write_hostname_marker():
    try:
        os.makedirs(DATA_ROOT, exist_ok=True)
        with open(os.path.join(DATA_ROOT, "hostname"), "w", encoding="utf-8") as f:
            f.write(hostname + "\n")
    except Exception:
        pass


def shorten_schedule_time(dt_str: str) -> str:
    try:
        return datetime.strptime(dt_str, "%Y-%m-%d %H:%M:%S").strftime("%H:%M")
    except Exception:
        return "??:??"


def parse_schedule_timestamp(line: str) -> datetime | None:
    parts = line.split(maxsplit=2)
    if len(parts) < 3:
        return None
    try:
        return datetime.strptime(parts[1] + " " + parts[2], "%Y-%m-%d %H:%M:%S")
    except Exception:
        return None


def parse_schedule_duration_seconds(text: str) -> int | None:
    total = 0
    found = False
    for unit, value in re.findall(r"\b([DHMS])([0-9]+)\b", text):
        found = True
        amount = int(value)
        if unit == "D":
            total += amount * 86400
        elif unit == "H":
            total += amount * 3600
        elif unit == "M":
            total += amount * 60
        elif unit == "S":
            total += amount
    return total if found else None


def schedule_datetimes_from_states(begin: datetime | None, states: list[tuple[str, int]]) -> tuple[str | None, str | None]:
    if begin is None or not states:
        return None, None

    cursor = begin
    startup = None
    shutdown = None

    for state, duration_sec in states:
        next_cursor = cursor + timedelta(seconds=duration_sec)
        if state == "ON" and shutdown is None:
            startup = startup or cursor
            shutdown = next_cursor
        elif state == "OFF" and startup is None:
            startup = next_cursor

        if startup is not None and shutdown is not None:
            break
        cursor = next_cursor

    startup_str = startup.strftime("%Y-%m-%d %H:%M:%S") if startup else None
    shutdown_str = shutdown.strftime("%Y-%m-%d %H:%M:%S") if shutdown else None
    return startup_str, shutdown_str


def parse_schedule_wpi(path: str):
    if not os.path.exists(path):
        return {
            "ok": False,
            "startup_short": "--:--",
            "shutdown_short": "--:--",
            "message": "No schedule.wpi found",
        }

    startup = None
    shutdown = None
    begin = None
    states = []
    startup_re = re.compile(r"^#\s*Startup at:\s*(.+?)\s*$")
    shutdown_re = re.compile(r"^#\s*Shutdown at:\s*(.+?)\s*$")
    state_re = re.compile(r"^(ON|OFF)\s+(.+?)\s*$")

    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                m = startup_re.match(line)
                if m:
                    startup = m.group(1)
                    continue
                m = shutdown_re.match(line)
                if m:
                    shutdown = m.group(1)
                    continue
                content = line.split("#", 1)[0].strip()
                if not content:
                    continue
                if content.startswith("BEGIN"):
                    begin = parse_schedule_timestamp(content)
                    continue
                m = state_re.match(content)
                if m:
                    duration_sec = parse_schedule_duration_seconds(m.group(2))
                    if duration_sec is not None:
                        states.append((m.group(1), duration_sec))
    except Exception:
        return {
            "ok": False,
            "startup_short": "--:--",
            "shutdown_short": "--:--",
            "message": "Schedule read error",
        }

    if not startup and not shutdown:
        startup, shutdown = schedule_datetimes_from_states(begin, states)

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


class OledDisplay:
    def __init__(self, enabled: bool = True, log_errors: bool = False):
        self.enabled = False
        self.log_errors = log_errors
        self.width = 128
        self.height = 64

        if not enabled:
            return

        if not OLED_AVAILABLE:
            if self.log_errors:
                print("OLED libraries not available; continuing without display", file=sys.stderr)
            return

        try:
            self.font = ImageFont.load_default()
            self._i2c = board.I2C()
            self._disp = adafruit_ssd1306.SSD1306_I2C(self.width, self.height, self._i2c)
            self._disp.fill(0)
            self._disp.show()
            self.enabled = True
        except Exception as e:
            if self.log_errors:
                print(f"OLED init failed: {e}", file=sys.stderr)
            self.enabled = False

    def show_lines(self, lines, line_height=12):
        if not self.enabled:
            return
        try:
            image = Image.new("1", (self.width, self.height))
            draw = ImageDraw.Draw(image)
            draw.rectangle((0, 0, self.width, self.height), outline=0, fill=0)

            y = 1
            for i, line in enumerate(lines[:5]):
                draw_y = y + 1 if i == 0 else y
                draw.text((0, draw_y), str(line), font=self.font, fill=255)
                y += line_height
                if i == 0:
                    y += 2

            self._disp.image(image)
            self._disp.show()
        except Exception as e:
            if self.log_errors:
                print(f"OLED render failed: {e}", file=sys.stderr)

    def clear(self):
        if not self.enabled:
            return
        try:
            self._disp.fill(0)
            self._disp.show()
        except Exception:
            pass


class OledWorker(threading.Thread):
    def __init__(self, display: OledDisplay, stop_event: threading.Event):
        super().__init__(daemon=True)
        self.display = display
        self.stop_event = stop_event

    def run(self):
        if not self.display.enabled:
            return

        while not self.stop_event.is_set():
            with status_lock:
                station = fit_display_line(hostname, max_chars=8)
                clock = "CLK?" if TIME_UNKNOWN else datetime.now().strftime('%H:%M')
                now_str = f"{station} v{SHORT_VERSION} {clock}"
                current_state = status.state

                if current_state == "INIT":
                    line2 = "Initializing..."
                    line3 = f"Imgs {status.image_count_today}"
                    line4 = f"SD  {int(round(status.disk_used_percent))}%"
                    line5 = current_state
                elif status.schedule_message:
                    line2 = status.schedule_message
                    line3 = f"Imgs {status.image_count_today}"
                    line4 = f"SD  {int(round(status.disk_used_percent))}%"
                    line5 = current_state
                else:
                    line2 = f"ON  {status.startup_short}"
                    line3 = f"OFF {status.shutdown_short}"
                    line4 = f"Imgs {status.image_count_today}"
                    line5 = f"SD  {int(round(status.disk_used_percent))}% {current_state}"

            self.display.show_lines([now_str, line2, line3, line4, line5])
            self.stop_event.wait(cfg.oled_refresh_sec)


class StorageMonitor(threading.Thread):
    def __init__(self, stop_event: threading.Event):
        super().__init__(daemon=True)
        self.stop_event = stop_event

    def run(self):
        while not self.stop_event.is_set():
            try:
                usage = get_storage_usage(cfg.storage_check_path)
                with status_lock:
                    status.disk_used_percent = usage.data_used_percent
                    status.rootfs_used_percent = usage.rootfs_used_percent
                    if storage_usage_exceeds_threshold(usage):
                        status.stop_due_to_storage = True
                        status.storage_locked = True
                        status.state = "FULL"
                    elif not status.storage_locked and status.state not in {"DETECTION", "TIMELAPSE", "INIT"}:
                        status.state = "SCANNING"
            except Exception as e:
                log_exception_event("storage_monitor_error", "Storage monitor exception", e)
                print(f"Storage monitor error: {e}", file=sys.stderr)
            self.stop_event.wait(cfg.storage_check_interval_sec)


class Detection:
    def __init__(self, coords, category, conf, metadata):
        self.category = int(category)
        self.conf = float(conf)
        try:
            self.box = imx500.convert_inference_coords(coords, metadata, picam2, stream=DETECTION_STREAM)
        except TypeError as e:
            if "stream" not in str(e):
                raise
            # Older Picamera2 releases only convert to the main stream. Main is
            # full-res in model mode, so convert back to preview/lores tracking
            # coordinates.
            box = imx500.convert_inference_coords(coords, metadata, picam2)
            self.box = scale_box_still_to_preview(*box)


def parse_detections(metadata: dict):
    global last_detections

    np_outputs = imx500.get_outputs(metadata, add_batch=True)
    _, input_h = imx500.get_input_size()

    if np_outputs is None:
        return last_detections

    if intrinsics.postprocess == "nanodet":
        boxes, scores, classes = postprocess_nanodet_detection(
            outputs=np_outputs[0],
            conf=cfg.threshold,
            iou_thres=cfg.iou,
            max_out_dets=cfg.max_detections,
        )[0]
        from picamera2.devices.imx500.postprocess import scale_boxes
        input_w, input_h = imx500.get_input_size()
        boxes = scale_boxes(boxes, 1, 1, input_h, input_w, False, False)
    else:
        boxes, scores, classes = np_outputs[0][0], np_outputs[1][0], np_outputs[2][0]

        if intrinsics.bbox_normalization:
            boxes = boxes / input_h

        if intrinsics.bbox_order == "xy":
            boxes = boxes[:, [1, 0, 3, 2]]

        keep = class_aware_nms(boxes, scores, classes)
        boxes = [boxes[i] for i in keep]
        scores = [scores[i] for i in keep]
        classes = [classes[i] for i in keep]

    if intrinsics.postprocess == "nanodet":
        detections_iter = [
            (box, score, category)
            for box, score, category in zip(boxes, scores, classes)
            if score > cfg.threshold
        ]
    else:
        detections_iter = zip(boxes, scores, classes)

    last_detections = [
        Detection(box, category, score, metadata)
        for box, score, category in detections_iter
    ]
    return last_detections


def metadata_has_current_inference(metadata: dict) -> bool:
    output_tensor = metadata.get("CnnOutputTensor")
    if output_tensor is None:
        return False
    try:
        return len(output_tensor) > 0
    except TypeError:
        return True


def inference_box_iou(a, b) -> float:
    ay1, ax1, ay2, ax2 = [float(v) for v in a]
    by1, bx1, by2, bx2 = [float(v) for v in b]
    ix1 = max(ax1, bx1)
    iy1 = max(ay1, by1)
    ix2 = min(ax2, bx2)
    iy2 = min(ay2, by2)
    intersection = max(0.0, ix2 - ix1) * max(0.0, iy2 - iy1)
    area_a = max(0.0, ax2 - ax1) * max(0.0, ay2 - ay1)
    area_b = max(0.0, bx2 - bx1) * max(0.0, by2 - by1)
    union = area_a + area_b - intersection
    if union <= 0:
        return 0.0
    return intersection / union


def class_aware_nms(boxes, scores, classes):
    candidates = [
        i for i, score in enumerate(scores)
        if float(score) > cfg.threshold
    ]
    candidates.sort(key=lambda i: float(scores[i]), reverse=True)

    keep = []
    while candidates and len(keep) < cfg.max_detections:
        current = candidates.pop(0)
        keep.append(current)

        remaining = []
        for candidate in candidates:
            same_class = int(classes[candidate]) == int(classes[current])
            overlaps = inference_box_iou(boxes[candidate], boxes[current]) > cfg.iou
            if same_class and overlaps:
                continue
            remaining.append(candidate)
        candidates = remaining

    return keep


def format_wall_time_with_ms() -> str:
    now = datetime.now()
    return f"{now.strftime('%Y-%m-%d %H:%M:%S')}.{now.microsecond // 1000:03d}"


def sensor_age_ms(metadata: dict, now_monotonic_ns: int | None = None) -> float | None:
    sensor_timestamp = metadata.get("SensorTimestamp")
    if sensor_timestamp is None:
        return None
    try:
        sensor_timestamp = int(sensor_timestamp)
    except (TypeError, ValueError):
        return None
    if now_monotonic_ns is None:
        now_monotonic_ns = time.monotonic_ns()
    age_ms = (now_monotonic_ns - sensor_timestamp) / 1_000_000.0
    if age_ms < 0:
        return None
    return age_ms


def _box_tuple(box) -> tuple:
    x, y, w, h = box
    return float(x), float(y), float(w), float(h)


def box_area(box) -> float:
    _x, _y, w, h = _box_tuple(box)
    return max(0.0, w) * max(0.0, h)


def box_iou(a, b) -> float:
    ax, ay, aw, ah = _box_tuple(a)
    bx, by, bw, bh = _box_tuple(b)
    ax2, ay2 = ax + aw, ay + ah
    bx2, by2 = bx + bw, by + bh

    ix1 = max(ax, bx)
    iy1 = max(ay, by)
    ix2 = min(ax2, bx2)
    iy2 = min(ay2, by2)
    iw = max(0.0, ix2 - ix1)
    ih = max(0.0, iy2 - iy1)
    intersection = iw * ih
    union = box_area(a) + box_area(b) - intersection
    if union <= 0:
        return 0.0
    return intersection / union


def center_distance_norm(a, b) -> float:
    ax, ay, aw, ah = _box_tuple(a)
    bx, by, bw, bh = _box_tuple(b)
    acx = ax + (aw / 2.0)
    acy = ay + (ah / 2.0)
    bcx = bx + (bw / 2.0)
    bcy = by + (bh / 2.0)
    dx = abs(acx - bcx) / max(1.0, float(cfg.preview_width))
    dy = abs(acy - bcy) / max(1.0, float(cfg.preview_height))
    return max(dx, dy)


def area_ratio(current, tracked) -> float:
    tracked_area = box_area(tracked)
    if tracked_area <= 0:
        return float("inf")
    return box_area(current) / tracked_area


def expire_stale_tracks(now_mono: float):
    global stale_tracks
    stale_tracks = [
        track for track in stale_tracks
        if now_mono - track.last_seen <= cfg.stale_expire_sec
    ]


def find_stale_track(detection, excluded_track_ids=None):
    if excluded_track_ids is None:
        excluded_track_ids = set()

    best = None
    best_metrics = None
    best_score = None

    for track in stale_tracks:
        if track.id in excluded_track_ids:
            continue
        if track.category != detection.category:
            continue

        iou_value = box_iou(detection.box, track.box)
        center_value = center_distance_norm(detection.box, track.box)
        ratio_value = area_ratio(detection.box, track.box)
        center_match = (
            center_value <= cfg.stale_center_threshold
            and cfg.stale_area_ratio_min <= ratio_value <= cfg.stale_area_ratio_max
        )
        if iou_value < cfg.stale_iou_threshold and not center_match:
            continue

        score = iou_value - center_value
        if best_score is None or score > best_score:
            best = track
            best_metrics = (iou_value, center_value, ratio_value)
            best_score = score

    return best, best_metrics


def update_track_from_detection(track: StaleTrack, detection, now_mono: float):
    track.box = _box_tuple(detection.box)
    track.conf = float(detection.conf)
    track.last_seen = now_mono


def create_stale_track(detection, now_mono: float) -> StaleTrack:
    global stale_next_track_id
    track = StaleTrack(
        id=stale_next_track_id,
        category=int(detection.category),
        box=_box_tuple(detection.box),
        conf=float(detection.conf),
        first_seen=now_mono,
        last_seen=now_mono,
        last_capture=now_mono,
    )
    stale_next_track_id += 1
    stale_tracks.append(track)
    return track


def filter_stale_detections(detections):
    global stale_suppressed_total, last_stale_suppression_log

    if not cfg.stale_detection_enabled:
        return detections, []

    now_mono = time.monotonic()
    expire_stale_tracks(now_mono)

    fresh = []
    suppressed = []
    stale_count_before = len(stale_tracks)
    matched_track_ids = set()

    for detection in detections:
        track, metrics = find_stale_track(detection, matched_track_ids)
        if track is None:
            track = create_stale_track(detection, now_mono)
            matched_track_ids.add(track.id)
            fresh.append(detection)
            continue

        matched_track_ids.add(track.id)
        _iou_value, _center_value, ratio_value = metrics
        stale_age = now_mono - track.first_seen
        size_change = (
            ratio_value < cfg.stale_area_ratio_min
            or ratio_value > cfg.stale_area_ratio_max
        )

        if size_change:
            track.first_seen = now_mono
            track.last_capture = now_mono
            fresh.append(detection)
        elif stale_age >= cfg.stale_detection_sec:
            suppressed.append(detection)
            track.suppressed_count += 1
            stale_suppressed_total += 1
        else:
            track.last_capture = now_mono
            fresh.append(detection)

        update_track_from_detection(track, detection, now_mono)

    if (
        cfg.log_stale_detections
        and suppressed
        and now_mono - last_stale_suppression_log >= cfg.stale_log_interval_sec
    ):
        print(
            f"Stale detections suppressed: fresh={len(fresh)} suppressed={len(suppressed)} "
            f"tracks={len(stale_tracks)} total_suppressed={stale_suppressed_total}",
            flush=True,
        )
        last_stale_suppression_log = now_mono
    elif stale_count_before and not detections:
        expire_stale_tracks(now_mono)

    return fresh, suppressed


def scale_box_still_to_preview(x, y, w, h):
    sx = cfg.preview_width / cfg.still_width
    sy = cfg.preview_height / cfg.still_height

    x2 = float(x * sx)
    y2 = float(y * sy)
    w2 = float(w * sx)
    h2 = float(h * sy)

    x2 = max(0.0, min(float(cfg.preview_width), x2))
    y2 = max(0.0, min(float(cfg.preview_height), y2))
    w2 = max(1.0, min(float(cfg.preview_width) - x2, w2))
    h2 = max(1.0, min(float(cfg.preview_height) - y2, h2))
    return x2, y2, w2, h2


def _record_async_save(success: bool):
    global async_saves_completed, async_saves_failed
    with save_stats_lock:
        if success:
            async_saves_completed += 1
        else:
            async_saves_failed += 1


def _record_async_save_dropped():
    global async_saves_dropped
    with save_stats_lock:
        async_saves_dropped += 1


def get_async_saves_completed() -> int:
    with save_stats_lock:
        return async_saves_completed


def get_async_saves_dropped() -> int:
    with save_stats_lock:
        return async_saves_dropped


class AsyncSaveWorker(threading.Thread):
    def __init__(self, jobs: queue.Queue, stop_event: threading.Event):
        super().__init__(daemon=True)
        self.jobs = jobs
        self.stop_event = stop_event
        self._error = None
        self._error_lock = threading.Lock()

    def get_error(self):
        with self._error_lock:
            return self._error

    def _set_error(self, exc: BaseException):
        with self._error_lock:
            if self._error is None:
                self._error = exc

    def run(self):
        while not self.stop_event.is_set() or not self.jobs.empty():
            try:
                job = self.jobs.get(timeout=0.1)
            except queue.Empty:
                continue

            success = False
            try:
                job.request.save(CAPTURE_STREAM, job.image_path)

                if cfg.log_capture_queue and job.queued_monotonic is not None:
                    save_delay_ms = (time.monotonic() - job.queued_monotonic) * 1000.0
                    frame_age_text = f" frame_age_ms={job.frame_age_ms:.1f}" if job.frame_age_ms is not None else ""
                    print(
                        f"Capture saved: {job.image_path} detections={job.detection_count} "
                        f"queued_at={job.queued_wall} saved_at={format_wall_time_with_ms()} "
                        f"save_delay_ms={save_delay_ms:.1f}{frame_age_text}",
                        flush=True,
                    )
                else:
                    print(f"Capture saved: {job.image_path} detections={job.detection_count}", flush=True)
                update_saved_status(job.stem)
                success = True
            except Exception as e:
                log_exception_event("async_save_error", f"Async save failed for {job.image_path}", e)
                print(f"Async save failed: {job.image_path}: {e}", file=sys.stderr, flush=True)
                self._set_error(e)
            finally:
                try:
                    job.request.release()
                except Exception as e:
                    log_exception_event("async_save_release_error", "Failed to release async save request", e)
                    print(f"Async save request release failed: {e}", file=sys.stderr, flush=True)
                    self._set_error(e)
                _record_async_save(success)
                self.jobs.task_done()


def start_async_save_worker():
    global save_queue, save_worker, save_stop_event
    if save_worker is not None:
        return
    maxsize = max(1, cfg.async_save_queue_size)
    save_queue = queue.Queue(maxsize=maxsize)
    save_stop_event = threading.Event()
    save_worker = AsyncSaveWorker(save_queue, save_stop_event)
    save_worker.start()
    if cfg.log_startup:
        print(f"Async saver started queue_size={maxsize}", flush=True)


def stop_async_save_worker(timeout: float = 10.0):
    global save_queue, save_worker, save_stop_event
    worker = save_worker
    if worker is None:
        return
    if save_stop_event is not None:
        save_stop_event.set()
    worker.join(timeout=timeout)
    if worker.is_alive():
        pending = save_queue.qsize() if save_queue is not None else 0
        print(f"Async saver still busy; pending_saves={pending}", file=sys.stderr, flush=True)
    else:
        save_worker = None
        save_queue = None
        save_stop_event = None


def raise_async_save_error_if_any():
    if save_worker is None:
        return
    error = save_worker.get_error()
    if error is not None:
        raise RuntimeError(f"Async save worker failed: {error}") from error


def update_saved_status(stem: str):
    with status_lock:
        status.image_count_today += 1
        if status.storage_locked:
            status.state = "FULL"
        elif cfg.timelapse_enabled:
            status.state = "TIMELAPSE"
        else:
            status.state = "SCANNING"


def lock_storage_full():
    with status_lock:
        status.stop_due_to_storage = True
        status.storage_locked = True
        status.state = "FULL"


def capture_still(stem: str, detections=None, request=None):
    global capture_in_progress, last_capture_time

    if capture_in_progress:
        return False
    if time.monotonic() - last_capture_time < cfg.capture_cooldown_sec:
        return False

    if storage_locked_or_full():
        lock_storage_full()
        return False

    images_dir = dated_images_dir(cfg.save_root)
    image_path = os.path.join(images_dir, f"{stem}.jpg")

    capture_in_progress = True
    try:
        with status_lock:
            status.state = "TIMELAPSE" if (cfg.timelapse_enabled and detections is None) else "DETECTION"

        if request is not None:
            # Save the full-res main buffer from the same completed request
            # whose metadata produced the detection boxes.
            request.save(CAPTURE_STREAM, image_path)
        elif cfg.timelapse_enabled and detections is None:
            # Timelapse uses a still-only pipeline so no mode switch is needed.
            picam2.capture_file(image_path)
        else:
            raise RuntimeError("Model captures require a completed request")

        last_capture_time = time.monotonic()
        detection_count = len(detections) if detections is not None else 0
        print(f"Capture saved: {image_path} detections={detection_count}", flush=True)
        update_saved_status(stem)
        return True
    finally:
        capture_in_progress = False


def queue_capture_still(stem: str, detections, request, metadata):
    global last_capture_time, last_save_queue_full_log

    if time.monotonic() - last_capture_time < cfg.capture_cooldown_sec:
        return False

    if storage_locked_or_full():
        lock_storage_full()
        return False

    if save_queue is None:
        raise RuntimeError("Async save worker is not running")

    images_dir = dated_images_dir(cfg.save_root)
    image_path = os.path.join(images_dir, f"{stem}.jpg")
    queued_monotonic = None
    queued_wall = None
    frame_age_ms = None
    if cfg.log_capture_queue:
        queued_monotonic = time.monotonic()
        queued_wall = format_wall_time_with_ms()
        frame_age_ms = sensor_age_ms(metadata, time.monotonic_ns())
    job = SaveJob(
        stem=stem,
        image_path=image_path,
        detection_count=len(detections) if detections is not None else 0,
        request=request,
        queued_monotonic=queued_monotonic,
        queued_wall=queued_wall,
        frame_age_ms=frame_age_ms,
    )

    request.acquire()
    try:
        save_queue.put_nowait(job)
    except queue.Full:
        request.release()
        _record_async_save_dropped()
        now_mono = time.monotonic()
        if cfg.log_capture_queue and now_mono - last_save_queue_full_log >= 5.0:
            print(
                f"Async save queue full; dropping capture request pending_saves={save_queue.qsize()} "
                f"total_dropped={get_async_saves_dropped()}",
                file=sys.stderr,
                flush=True,
            )
            last_save_queue_full_log = now_mono
        return False
    except Exception:
        request.release()
        raise

    last_capture_time = time.monotonic()
    with status_lock:
        status.state = "DETECTION"
    if cfg.log_capture_queue:
        detection_count = len(detections) if detections is not None else 0
        frame_age_text = f" frame_age_ms={frame_age_ms:.1f}" if frame_age_ms is not None else ""
        print(
            f"Capture grabbed: {image_path} detections={detection_count} "
            f"queued_at={queued_wall}{frame_age_text} pending_saves={save_queue.qsize()}",
            flush=True,
        )
    return True


def capture_full_res_image(detections, request, metadata):
    return queue_capture_still(make_stem(), detections=detections, request=request, metadata=metadata)


def capture_timelapse_image_if_due():
    global last_timelapse_time
    if not cfg.timelapse_enabled:
        return

    now_mono = time.monotonic()
    if last_timelapse_time and now_mono - last_timelapse_time < cfg.timelapse_interval_sec:
        return

    if capture_still(make_stem(), detections=None):
        last_timelapse_time = now_mono


def get_args():
    p = argparse.ArgumentParser()
    p.add_argument("--config", default="camera_config.ini")
    return p.parse_args()


def build_camera_objects():
    global imx500, intrinsics, picam2, still_config, preview_config

    if not cfg.timelapse_enabled:
        imx500 = IMX500(cfg.model_path)
        intrinsics = imx500.network_intrinsics

        if not intrinsics:
            intrinsics = NetworkIntrinsics()
            intrinsics.task = "object detection"
        elif intrinsics.task != "object detection":
            print("Network is not an object detection task", file=sys.stderr)
            sys.exit(1)

        intrinsics.bbox_order = cfg.bbox_order
        intrinsics.bbox_normalization = cfg.bbox_normalization
        intrinsics.ignore_dash_labels = cfg.ignore_dash_labels
        intrinsics.preserve_aspect_ratio = cfg.preserve_aspect_ratio
        if cfg.postprocess is not None:
            intrinsics.postprocess = cfg.postprocess

        if cfg.labels_path and os.path.exists(cfg.labels_path):
            with open(cfg.labels_path, "r", encoding="utf-8") as f:
                intrinsics.labels = f.read().splitlines()

        intrinsics.update_with_defaults()
        if cfg.log_startup:
            print(
                f"Detection config: postprocess={intrinsics.postprocess} "
                f"threshold={cfg.threshold} iou={cfg.iou}",
                flush=True,
            )
        picam2 = Picamera2(imx500.camera_num)
    else:
        # Timelapse mode uses a still-only camera pipeline and skips model inference.
        imx500 = None
        intrinsics = None
        picam2 = Picamera2()

    ae_mode = ae_exposure_mode_from_string(cfg.ae_exposure_mode)

    preview_controls = {
        "FrameRate": cfg.fps,
        "AeEnable": cfg.ae_enable,
        "AeExposureMode": ae_mode,
    }
    still_controls = {
        "AeEnable": cfg.ae_enable,
        "AeExposureMode": ae_mode,
    }

    if not cfg.ae_enable:
        if cfg.exposure_time_us is not None:
            preview_controls["ExposureTime"] = cfg.exposure_time_us
            still_controls["ExposureTime"] = cfg.exposure_time_us
        if cfg.analogue_gain is not None:
            preview_controls["AnalogueGain"] = cfg.analogue_gain
            still_controls["AnalogueGain"] = cfg.analogue_gain

    preview_config = None
    if not cfg.timelapse_enabled:
        preview_config = picam2.create_preview_configuration(
            main={"size": (cfg.still_width, cfg.still_height), "format": "YUV420"},
            lores={"size": (cfg.preview_width, cfg.preview_height), "format": "YUV420"},
            controls=preview_controls,
            buffer_count=cfg.buffer_count_preview,
            display=DETECTION_STREAM,
            encode=CAPTURE_STREAM,
            queue=False,
        )

    still_config = None
    if cfg.timelapse_enabled:
        still_config = picam2.create_still_configuration(
            main={"size": (cfg.still_width, cfg.still_height), "format": "YUV420"},
            controls=still_controls,
            buffer_count=cfg.buffer_count_still,
        )

def configure_inference_roi():
    if imx500 is None or intrinsics is None:
        return

    if intrinsics.preserve_aspect_ratio:
        imx500.set_auto_aspect_ratio()
        if cfg.log_startup:
            print(f"IMX500 inference ROI: auto aspect ratio input_size={imx500.get_input_size()}", flush=True)
        return

    full_roi = (0, 0, cfg.still_width, cfg.still_height)
    try:
        full_sensor = imx500.get_full_sensor_resolution()
        full_roi = full_sensor.to_tuple() if hasattr(full_sensor, "to_tuple") else tuple(full_sensor)
    except AttributeError:
        pass

    imx500.set_inference_roi_abs(full_roi)
    if cfg.log_startup:
        print(f"IMX500 inference ROI: full sensor {full_roi}", flush=True)


def stay_alive_storage_locked(stop_event: threading.Event):
    print(
        "Storage is above the stop threshold. Imaging is disabled until storage is cleared and the service is restarted.",
        file=sys.stderr,
    )
    while not stop_event.is_set():
        with status_lock:
            status.state = "FULL"
        time.sleep(1.0)


def hold_low_battery_recovery(oled: object | None, delay_min: float):
    if WAKE_REASON != REASON_VOLTAGE_RESTORE:
        if cfg.log_startup:
            print(
                f"Low-battery recovery hold skipped (wake reason={WAKE_REASON or 'unknown'}, "
                f"expected {REASON_VOLTAGE_RESTORE})",
                flush=True,
            )
        return

    if delay_min <= 0:
        if cfg.log_startup:
            print("Low-battery recovery hold skipped (low_battery_recovery_delay_min <= 0)", flush=True)
        return

    if cfg.log_startup:
        print(
            f"Low-battery recovery detected (wake reason={REASON_VOLTAGE_RESTORE}); "
            f"holding camera init for {delay_min:.1f} min before resuming",
            flush=True,
        )

    with status_lock:
        status.state = "CHARGING"

    oled_redraw_interval_sec = 20.0
    end_monotonic = time.monotonic() + (delay_min * 60.0)
    last_draw_monotonic = 0.0

    while True:
        with status_lock:
            if status.state == "STOPPING":
                return

        remaining_sec = end_monotonic - time.monotonic()
        if remaining_sec <= 0:
            break

        now_mono = time.monotonic()
        if now_mono - last_draw_monotonic >= oled_redraw_interval_sec or last_draw_monotonic == 0.0:
            remaining_min = max(1, int((remaining_sec + 59) // 60))
            _oled_show_safe(oled, [
                f"{hostname} {datetime.now().strftime('%m-%d %H:%M')}",
                "Low-voltage recovery",
                "Delaying camera init",
                "",
                f"CHARGING {remaining_min}m",
            ])
            last_draw_monotonic = now_mono

        time.sleep(min(1.0, remaining_sec))

    if cfg.log_startup:
        print("Low-battery recovery hold complete; resuming normal startup", flush=True)


def main():
    global cfg

    args = get_args()
    cfg = read_config(args.config)

    if cfg.log_startup:
        print(f"BeeCam version {VERSION}", flush=True)
        if TIME_UNKNOWN:
            print("WARNING: Witty Pi reported a bad RTC time this boot; system clock is unverified", flush=True)

    oled = OledDisplay(enabled=cfg.oled_enabled, log_errors=cfg.log_startup)
    _oled_show_safe(oled, [
        f"{hostname} {datetime.now().strftime('%m-%d %H:%M')}",
        "Initializing...",
        f"Version {VERSION}",
        "",
        "INIT",
    ])

    def _sigterm_handler(_signum, _frame):
        with status_lock:
            status.state = "STOPPING"
        sys.exit(0)

    signal.signal(signal.SIGTERM, _sigterm_handler)

    hold_low_battery_recovery(oled, cfg.low_battery_recovery_delay_min)

    write_hostname_marker()

    schedule_info = parse_schedule_wpi(cfg.schedule_wpi_path)
    initial_count = count_today_images(cfg.save_root)
    initial_storage_usage = get_storage_usage(cfg.storage_check_path)

    with status_lock:
        status.image_count_today = initial_count
        status.disk_used_percent = initial_storage_usage.data_used_percent
        status.rootfs_used_percent = initial_storage_usage.rootfs_used_percent
        status.startup_short = schedule_info["startup_short"]
        status.shutdown_short = schedule_info["shutdown_short"]
        status.schedule_message = schedule_info["message"]
        status.capture_mode_label = "TIMELAPSE" if cfg.timelapse_enabled else "MODEL"
        if storage_usage_exceeds_threshold(initial_storage_usage):
            status.stop_due_to_storage = True
            status.storage_locked = True
            status.state = "FULL"
        else:
            status.state = "INIT"

    stop_event = threading.Event()
    storage_monitor = StorageMonitor(stop_event)
    oled_worker = OledWorker(oled, stop_event)
    storage_monitor.start()
    oled_worker.start()

    if storage_usage_exceeds_threshold(initial_storage_usage):
        stay_alive_storage_locked(stop_event)
        return

    try:
        build_camera_objects()

        if imx500 is not None and cfg.log_startup:
            imx500.show_network_fw_progress_bar()

        if cfg.timelapse_enabled:
            picam2.start(still_config, show_preview=False)
        else:
            picam2.start(preview_config, show_preview=False)
            start_async_save_worker()

        configure_inference_roi()

        with status_lock:
            status.state = "TIMELAPSE" if cfg.timelapse_enabled else "SCANNING"

        if cfg.log_startup:
            print("beecam_capture_final started")

        fps_logging_enabled = cfg.fps_log_interval_sec > 0
        if fps_logging_enabled:
            fps_window_start = time.monotonic()
            fps_request_count = 0
            fps_inference_count = 0
            fps_queued_count = 0
            fps_stale_suppressed_count = 0
            fps_saved_start = get_async_saves_completed()
            fps_dropped_start = get_async_saves_dropped()

        while True:
            raise_async_save_error_if_any()

            with status_lock:
                should_lock = status.storage_locked

            if should_lock:
                stop_async_save_worker(timeout=10.0)
                try:
                    picam2.stop()
                except Exception:
                    pass
                stay_alive_storage_locked(stop_event)
                break

            if cfg.timelapse_enabled:
                capture_timelapse_image_if_due()
                time.sleep(0.05)
                continue

            request = picam2.capture_request()
            metadata = None
            capture_succeeded = False
            try:
                metadata = request.get_metadata()
                has_current_inference = metadata_has_current_inference(metadata)
                detections = parse_detections(metadata)
                fresh_detections = detections
                stale_detections = []

                if fps_logging_enabled:
                    fps_request_count += 1
                if has_current_inference:
                    if fps_logging_enabled:
                        fps_inference_count += 1
                    fresh_detections, stale_detections = filter_stale_detections(detections)
                    if fps_logging_enabled:
                        fps_stale_suppressed_count += len(stale_detections)

                if fresh_detections and has_current_inference:
                    capture_succeeded = capture_full_res_image(fresh_detections, request, metadata)
            finally:
                request.release()

            if capture_succeeded and fps_logging_enabled:
                fps_queued_count += 1

            if fps_logging_enabled:
                now_mono = time.monotonic()
                elapsed = now_mono - fps_window_start
                if elapsed >= cfg.fps_log_interval_sec:
                    request_fps = fps_request_count / elapsed
                    inference_fps = fps_inference_count / elapsed
                    queued_fps = fps_queued_count / elapsed
                    saves_completed = get_async_saves_completed()
                    saved_fps = (saves_completed - fps_saved_start) / elapsed
                    saves_dropped = get_async_saves_dropped()
                    dropped_count = saves_dropped - fps_dropped_start
                    pending_saves = save_queue.qsize() if save_queue is not None else 0
                    frame_duration = metadata.get("FrameDuration") if metadata else None
                    sensor_fps = (1000000.0 / frame_duration) if frame_duration else None
                    sensor_text = f" sensor_fps={sensor_fps:.2f}" if sensor_fps else ""
                    print(
                        f"FPS: requests={request_fps:.2f} inference={inference_fps:.2f} "
                        f"queued={queued_fps:.2f} saved={saved_fps:.2f} "
                        f"stale_suppressed={fps_stale_suppressed_count} "
                        f"dropped={dropped_count} total_dropped={saves_dropped} "
                        f"pending_saves={pending_saves}{sensor_text}",
                        flush=True,
                    )
                    fps_window_start = now_mono
                    fps_request_count = 0
                    fps_inference_count = 0
                    fps_queued_count = 0
                    fps_stale_suppressed_count = 0
                    fps_saved_start = saves_completed
                    fps_dropped_start = saves_dropped
    except KeyboardInterrupt:
        with status_lock:
            status.state = "STOPPING"
    except Exception as e:
        stop_event.set()
        restart_self(format_exception_name_and_message(e), oled)
        raise  # only reached when restart_on_exception = false
    finally:
        stop_event.set()
        try:
            storage_monitor.join(timeout=2)
            oled_worker.join(timeout=2)
        except Exception:
            pass

        stop_async_save_worker(timeout=10.0)

        try:
            if picam2 is not None:
                picam2.stop()
        except Exception:
            pass

        with status_lock:
            final_state = status.state
            img_count = status.image_count_today
            disk_pct = int(round(status.disk_used_percent))

        if final_state == "STOPPING":
            _oled_show_safe(oled, [
                f"{hostname} {datetime.now().strftime('%m-%d %H:%M')}",
                f"Imgs {img_count}",
                f"SD  {disk_pct}%",
                "",
                "Beecam stopping...",
            ])
            time.sleep(2.0)
            oled.clear()
        else:
            _oled_show_safe(oled, [
                f"{hostname} {datetime.now().strftime('%m-%d %H:%M')}",
                schedule_info["message"] or f"ON  {schedule_info['startup_short']}",
                f"Imgs {img_count}",
                f"SD  {disk_pct}%",
                final_state,
            ])


if __name__ == "__main__":
    main()
