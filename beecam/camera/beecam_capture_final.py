#!/usr/bin/env python3

import argparse
import configparser
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
from functools import lru_cache

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

capture_in_progress = False
last_capture_time = 0.0
last_detections = []
last_timelapse_time = 0.0

hostname = socket.gethostname()


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

    ae_enable: bool
    ae_exposure_mode: str
    exposure_time_us: int | None
    analogue_gain: float | None

    storage_check_path: str
    storage_stop_percent: float
    storage_check_interval_sec: float

    schedule_wpi_path: str

    oled_enabled: bool
    oled_refresh_sec: float

    debug_preview: bool
    draw_detections: bool
    show_saved_overlay: bool
    preview_backend: str | None

    timelapse_enabled: bool
    timelapse_interval_sec: float

    restart_on_exception: bool
    restart_delay_sec: float
    exception_log_path: str


@dataclass
class SharedStatus:
    state: str = "BOOT"
    disk_used_percent: float = 0.0
    image_count_today: int = 0
    schedule_message: str | None = None
    startup_short: str = "--:--"
    shutdown_short: str = "--:--"
    saved_flash_until: float = 0.0
    last_saved_stem: str = ""
    stop_due_to_storage: bool = False
    storage_locked: bool = False
    capture_mode_label: str = "MODEL"


status = SharedStatus()
status_lock = threading.Lock()
log_lock = threading.Lock()


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
    preview_backend = get("debug", "preview_backend", fallback="").strip() or None

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

        ae_enable=getbool("exposure", "ae_enable", fallback=True),
        ae_exposure_mode=get("exposure", "ae_exposure_mode", fallback="short").strip().lower(),
        exposure_time_us=exposure_time_us,
        analogue_gain=analogue_gain,

        storage_check_path=os.path.expanduser(get("storage", "check_path", fallback="/data")),
        storage_stop_percent=getfloat("storage", "stop_percent", fallback=95.0),
        storage_check_interval_sec=getfloat("storage", "check_interval_sec", fallback=30.0),

        schedule_wpi_path=os.path.expanduser(get("schedule", "schedule_wpi_path", fallback="/home/pi/wittypi/schedule.wpi")),

        oled_enabled=getbool("oled", "enabled", fallback=True),
        oled_refresh_sec=getfloat("oled", "refresh_sec", fallback=1.0),

        debug_preview=getbool("debug", "debug_preview", fallback=False),
        draw_detections=getbool("debug", "draw_detections", fallback=False),
        show_saved_overlay=getbool("debug", "show_saved_overlay", fallback=True),
        preview_backend=preview_backend,

        timelapse_enabled=getbool("timelapse", "enabled", fallback=False),
        timelapse_interval_sec=getfloat("timelapse", "interval_sec", fallback=60.0),

        restart_on_exception=getbool("service", "restart_on_exception", fallback=True),
        restart_delay_sec=getfloat("service", "restart_delay_sec", fallback=2.0),
        exception_log_path=os.path.expanduser(get("logging", "exception_log_path", fallback="/data/logs/beecam_exception_log.csv")),
    )


def format_exception_name_and_message(exc: BaseException) -> str:
    return f"{type(exc).__name__}: {exc}"


def cleanup_camera():
    global picam2, imx500, intrinsics, still_config, preview_config, capture_in_progress
    capture_in_progress = False
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
    time.sleep(max(0.0, cfg.restart_delay_sec))
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


def dated_dirs(save_root: str):
    day = datetime.now().strftime("%Y-%m-%d")
    base = os.path.join(save_root, day)
    images_dir = os.path.join(base, "images")
    labels_dir = os.path.join(base, "labels")
    os.makedirs(images_dir, exist_ok=True)
    os.makedirs(labels_dir, exist_ok=True)
    return images_dir, labels_dir


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


def get_disk_used_percent(path: str) -> float:
    total, used, _free = shutil.disk_usage(path)
    if total <= 0:
        return 100.0
    return (used / total) * 100.0


def shorten_schedule_time(dt_str: str) -> str:
    try:
        return datetime.strptime(dt_str, "%Y-%m-%d %H:%M:%S").strftime("%H:%M")
    except Exception:
        return "??:??"


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
    startup_re = re.compile(r"^#\s*Startup at:\s*(.+?)\s*$")
    shutdown_re = re.compile(r"^#\s*Shutdown at:\s*(.+?)\s*$")

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
    except Exception:
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
        except Exception as e:
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
                now_str = f"{hostname} {datetime.now().strftime('%m-%d %H:%M')}"
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
                pct = get_disk_used_percent(cfg.storage_check_path)
                with status_lock:
                    status.disk_used_percent = pct
                    if pct >= cfg.storage_stop_percent:
                        status.stop_due_to_storage = True
                        status.storage_locked = True
                        status.state = "FULL"
                    elif not status.storage_locked and status.state not in {"DETECTION", "SAVED", "TIMELAPSE", "INIT"}:
                        status.state = "SCANNING"
            except Exception as e:
                log_exception_event("storage_monitor_error", "Storage monitor exception", e)
                print(f"Storage monitor error: {e}", file=sys.stderr)
            self.stop_event.wait(cfg.storage_check_interval_sec)


class Detection:
    def __init__(self, coords, category, conf, metadata):
        self.category = int(category)
        self.conf = float(conf)
        self.box = imx500.convert_inference_coords(coords, metadata, picam2)


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

    last_detections = [
        Detection(box, category, score, metadata)
        for box, score, category in zip(boxes, scores, classes)
        if score > cfg.threshold
    ]
    return last_detections


@lru_cache
def get_labels():
    labels = intrinsics.labels
    if intrinsics.ignore_dash_labels:
        labels = [label for label in labels if label and label != "-"]
    return labels


def scale_box_preview_to_still(x, y, w, h):
    sx = cfg.still_width / cfg.preview_width
    sy = cfg.still_height / cfg.preview_height

    x2 = float(x * sx)
    y2 = float(y * sy)
    w2 = float(w * sx)
    h2 = float(h * sy)

    x2 = max(0.0, min(float(cfg.still_width), x2))
    y2 = max(0.0, min(float(cfg.still_height), y2))
    w2 = max(1.0, min(float(cfg.still_width) - x2, w2))
    h2 = max(1.0, min(float(cfg.still_height) - y2, h2))
    return x2, y2, w2, h2


def write_label_txt(label_path: str, detections):
    # YOLO format: class_id x_center y_center width height confidence
    # xywh normalized to still capture resolution; confidence in [0, 1]
    with open(label_path, "w", encoding="utf-8") as f:
        for d in detections:
            x, y, w, h = d.box
            x2, y2, w2, h2 = scale_box_preview_to_still(x, y, w, h)
            xc = (x2 + (w2 / 2.0)) / float(cfg.still_width)
            yc = (y2 + (h2 / 2.0)) / float(cfg.still_height)
            wn = w2 / float(cfg.still_width)
            hn = h2 / float(cfg.still_height)

            xc = max(0.0, min(1.0, xc))
            yc = max(0.0, min(1.0, yc))
            wn = max(0.0, min(1.0, wn))
            hn = max(0.0, min(1.0, hn))

            f.write(f"{d.category} {xc:.6f} {yc:.6f} {wn:.6f} {hn:.6f} {d.conf:.6f}\n")


def draw_debug_detections(request, stream="main"):
    if not cfg.draw_detections:
        return

    try:
        from picamera2 import MappedArray
        import cv2
    except Exception:
        return

    detections = last_detections
    labels = get_labels() if intrinsics is not None else []

    with MappedArray(request, stream) as m:
        for d in detections:
            x, y, w, h = d.box
            label = labels[d.category] if 0 <= d.category < len(labels) else str(d.category)
            text = f"{label} {d.conf:.2f}"
            cv2.rectangle(m.array, (x, y), (x + w, y + h), (0, 255, 0), 2)
            cv2.putText(m.array, text, (x + 3, max(12, y + 12)), cv2.FONT_HERSHEY_SIMPLEX, 0.4, (255, 255, 255), 1)

        if cfg.show_saved_overlay and time.monotonic() < status.saved_flash_until:
            cv2.putText(m.array, "SAVED", (10, 20), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 255), 2)


def update_saved_status(stem: str):
    with status_lock:
        status.image_count_today += 1
        status.saved_flash_until = time.monotonic() + 1.0
        status.last_saved_stem = stem
        if status.storage_locked:
            status.state = "FULL"
        elif cfg.timelapse_enabled:
            status.state = "TIMELAPSE"
        else:
            status.state = "SCANNING"


def capture_still(stem: str, detections=None):
    global capture_in_progress, last_capture_time

    if capture_in_progress:
        return False
    if time.monotonic() - last_capture_time < cfg.capture_cooldown_sec:
        return False

    with status_lock:
        if status.storage_locked or status.disk_used_percent >= cfg.storage_stop_percent:
            status.stop_due_to_storage = True
            status.storage_locked = True
            status.state = "FULL"
            return False

    images_dir, labels_dir = dated_dirs(cfg.save_root)
    image_path = os.path.join(images_dir, f"{stem}.jpg")
    label_path = os.path.join(labels_dir, f"{stem}.txt")

    capture_in_progress = True
    try:
        with status_lock:
            status.state = "TIMELAPSE" if (cfg.timelapse_enabled and detections is None) else "DETECTION"

        # Timelapse uses a still-only pipeline so no mode switch is needed.
        if cfg.timelapse_enabled and detections is None:
            picam2.capture_file(image_path)
        else:
            # Blocks until the full-res JPEG is written to disk before returning,
            # preventing re-entry into the inference loop mid-save.
            picam2.switch_mode_and_capture_file(still_config, image_path)

        if detections is not None:
            write_label_txt(label_path, detections)
            print(f"Saved: {label_path}")
        last_capture_time = time.monotonic()
        print(f"Saved: {image_path}")
        update_saved_status(stem)
        return True
    finally:
        capture_in_progress = False


def capture_full_res_image(detections):
    return capture_still(make_stem(), detections=detections)


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


def maybe_get_preview_arg():
    if not cfg.debug_preview:
        return False
    if cfg.preview_backend:
        return cfg.preview_backend
    return True


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
            main={"size": (cfg.preview_width, cfg.preview_height), "format": "YUV420"},
            controls=preview_controls,
            buffer_count=cfg.buffer_count_preview,
        )

    still_config = picam2.create_still_configuration(
        main={"size": (cfg.still_width, cfg.still_height), "format": "YUV420"},
        controls=still_controls,
        buffer_count=cfg.buffer_count_still,
    )

    if (cfg.draw_detections or cfg.show_saved_overlay) and not cfg.timelapse_enabled:
        picam2.pre_callback = draw_debug_detections


def stay_alive_storage_locked(stop_event: threading.Event):
    print(
        "Storage is above the stop threshold. Imaging is disabled until storage is cleared and the service is restarted.",
        file=sys.stderr,
    )
    while not stop_event.is_set():
        with status_lock:
            status.state = "FULL"
        time.sleep(1.0)


def main():
    global cfg

    oled = OledDisplay()
    _oled_show_safe(oled, [
        f"{hostname} {datetime.now().strftime('%m-%d %H:%M')}",
        "Initializing...",
        "",
        "",
        "INIT",
    ])

    args = get_args()
    cfg = read_config(args.config)

    if not cfg.oled_enabled:
        oled.enabled = False

    try:
        with open("/data/hostname", "w", encoding="utf-8") as f:
            f.write(hostname + "\n")
    except Exception:
        pass

    schedule_info = parse_schedule_wpi(cfg.schedule_wpi_path)
    initial_count = count_today_images(cfg.save_root)
    initial_disk_pct = get_disk_used_percent(cfg.storage_check_path)

    with status_lock:
        status.image_count_today = initial_count
        status.disk_used_percent = initial_disk_pct
        status.startup_short = schedule_info["startup_short"]
        status.shutdown_short = schedule_info["shutdown_short"]
        status.schedule_message = schedule_info["message"]
        status.capture_mode_label = "TIMELAPSE" if cfg.timelapse_enabled else "MODEL"
        if initial_disk_pct >= cfg.storage_stop_percent:
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

    def _sigterm_handler(_signum, _frame):
        with status_lock:
            status.state = "STOPPING"
        sys.exit(0)

    signal.signal(signal.SIGTERM, _sigterm_handler)

    if initial_disk_pct >= cfg.storage_stop_percent:
        stay_alive_storage_locked(stop_event)
        return

    try:
        build_camera_objects()

        if imx500 is not None:
            imx500.show_network_fw_progress_bar()

        if cfg.timelapse_enabled:
            picam2.start(still_config, show_preview=maybe_get_preview_arg())
        else:
            picam2.start(preview_config, show_preview=maybe_get_preview_arg())

        if intrinsics is not None and intrinsics.preserve_aspect_ratio:
            imx500.set_auto_aspect_ratio()

        with status_lock:
            status.state = "TIMELAPSE" if cfg.timelapse_enabled else "SCANNING"

        print("beecam_capture started")

        while True:
            with status_lock:
                should_lock = status.storage_locked

            if should_lock:
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

            metadata = picam2.capture_metadata()
            detections = parse_detections(metadata)
            if detections:
                capture_full_res_image(detections)
            time.sleep(0.001)

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
