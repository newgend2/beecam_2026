#!/usr/bin/env python3

import argparse
import configparser
import datetime as dt
import os
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from functools import lru_cache

import cv2
from libcamera import controls
from picamera2 import MappedArray, Picamera2, Preview
from picamera2.devices import IMX500
from picamera2.devices.imx500 import NetworkIntrinsics, postprocess_nanodet_detection


picam2 = None
imx500 = None
intrinsics = None
cfg = None
last_results = None
last_detections = []
last_saved_message = ""
last_saved_message_until = 0.0
stale_tracks = []
stale_next_track_id = 1

SERVICE_NAME = "beecam.service"
WITTYPI_DIR = "/home/pi/wittypi"
WITTYPI_SCHEDULE = os.path.join(WITTYPI_DIR, "schedule.wpi")
WITTYPI_RUN_SCRIPT = os.path.join(WITTYPI_DIR, "runScript.sh")
WITTYPI_BEFORE_SCRIPT = os.path.join(WITTYPI_DIR, "beforeScript.sh")


@dataclass
class AppConfig:
    model_path: str
    labels_path: str
    preview_width: int
    preview_height: int
    fps: int
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
    ae_enable: bool
    ae_exposure_mode: str
    display_width: int
    display_height: int
    preview_backend: str


@dataclass
class StaleTrack:
    id: int
    category: int
    box: tuple
    conf: float
    first_seen: float
    last_seen: float
    suppressed_count: int = 0


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

    postprocess = get("model", "postprocess", fallback="").strip() or None

    return AppConfig(
        model_path=os.path.expanduser(get("model", "model_path")),
        labels_path=os.path.expanduser(get("model", "labels_path")),
        preview_width=getint("camera", "preview_width", fallback=640),
        preview_height=getint("camera", "preview_height", fallback=480),
        fps=getint("camera", "fps", fallback=10),
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
        ae_enable=getbool("exposure", "ae_enable", fallback=True),
        ae_exposure_mode=get("exposure", "ae_exposure_mode", fallback="short").strip().lower(),
        display_width=getint("display", "display_width", fallback=1920),
        display_height=getint("display", "display_height", fallback=1080),
        preview_backend="drm",
    )


def ae_exposure_mode_from_string(name: str):
    mapping = {
        "normal": controls.AeExposureModeEnum.Normal,
        "short": controls.AeExposureModeEnum.Short,
        "long": controls.AeExposureModeEnum.Long,
        "custom": controls.AeExposureModeEnum.Custom,
    }
    return mapping[name]


def preview_enum(name: str):
    mapping = {
        "qt": Preview.QT,
        "qtgl": Preview.QTGL,
        "drm": Preview.DRM,
        "null": Preview.NULL,
    }
    return mapping.get(name, Preview.DRM)


def compute_preview_window(display_w, display_h, content_w, content_h):
    """Largest content-aspect-ratio rectangle that fits the display, centered.

    Returns (x, y, width, height). Because the returned window matches the
    camera stream's aspect ratio, the image fills it without distortion
    whether the DRM layer letterboxes or stretches to the window.
    """
    if content_w <= 0 or content_h <= 0 or display_w <= 0 or display_h <= 0:
        return 0, 0, max(1, display_w), max(1, display_h)

    content_ar = content_w / content_h
    display_ar = display_w / display_h

    if content_ar >= display_ar:
        # Content is relatively wider -> limited by display width.
        win_w = display_w
        win_h = max(1, round(display_w / content_ar))
    else:
        # Content is relatively taller/narrower -> limited by display height.
        win_h = display_h
        win_w = max(1, round(display_h * content_ar))

    x = max(0, (display_w - win_w) // 2)
    y = max(0, (display_h - win_h) // 2)
    return x, y, win_w, win_h


def handle_shutdown_signal(signum, _frame):
    name = signal.Signals(signum).name
    raise KeyboardInterrupt(f"received {name}")


def install_shutdown_signal_handlers():
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        try:
            signal.signal(signum, handle_shutdown_signal)
        except (AttributeError, ValueError):
            pass


def run_command(cmd: list[str], input_text: str | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        cmd,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def service_is_active(name: str = SERVICE_NAME) -> bool:
    return run_command(["systemctl", "is-active", "--quiet", name]).returncode == 0


def stop_beecam_service(grace_sec: float = 2.0) -> bool:
    if not service_is_active():
        print(f"{SERVICE_NAME} is not active; preview can use the camera.")
        return False

    print(f"Stopping {SERVICE_NAME} for preview...")
    result = run_command(["sudo", "systemctl", "stop", SERVICE_NAME])
    if result.returncode != 0:
        stderr = result.stderr.strip() or "unknown error"
        raise RuntimeError(f"Could not stop {SERVICE_NAME}: {stderr}")
    if service_is_active():
        raise RuntimeError(f"{SERVICE_NAME} is still active after stop; refusing to open the camera.")

    print(f"{SERVICE_NAME} stopped.")
    if grace_sec > 0:
        time.sleep(grace_sec)
    return True


def restart_beecam_service():
    print(f"Restarting {SERVICE_NAME}...")
    result = run_command(["sudo", "systemctl", "start", SERVICE_NAME])
    if result.returncode != 0:
        stderr = result.stderr.strip() or "unknown error"
        print(f"WARNING: could not restart {SERVICE_NAME}: {stderr}", file=sys.stderr)
        return
    print(f"{SERVICE_NAME} restarted.")


def duration_to_tokens(delta: dt.timedelta) -> str:
    total = max(0, int(delta.total_seconds()))
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


def fmt_timestamp(ts: dt.datetime) -> str:
    return ts.strftime("%Y-%m-%d %H:%M:%S")


def current_schedule_is_after_hours() -> bool:
    try:
        with open(WITTYPI_SCHEDULE, "r") as f:
            return "after-hours" in f.read().lower()
    except FileNotFoundError:
        return False


def arm_after_hours_preview_hold(hold_hours: float = 2.0) -> bool:
    if hold_hours <= 0 or not current_schedule_is_after_hours():
        return False
    if not os.path.exists(WITTYPI_RUN_SCRIPT):
        print(f"{WITTYPI_RUN_SCRIPT} not found; skipping Witty Pi after-hours hold.")
        return False

    now = dt.datetime.now().replace(microsecond=0)
    hold_duration = dt.timedelta(hours=hold_hours)
    off_duration = dt.timedelta(hours=1)
    end = now + hold_duration + off_duration + dt.timedelta(minutes=1)
    schedule_text = f"""# Auto-generated temporary BeeCam preview hold schedule
# Generated at: {fmt_timestamp(now)}
# Reason: keep Pi awake for beecam_preview.py during after-hours testing
BEGIN {fmt_timestamp(now)}
END   {fmt_timestamp(end)}
ON    {duration_to_tokens(hold_duration)}
OFF   {duration_to_tokens(off_duration)}
"""

    print(f"After-hours Witty Pi schedule detected; extending preview runtime by {hold_hours:g} hour(s)...")
    write_result = run_command(["sudo", "tee", WITTYPI_SCHEDULE], input_text=schedule_text)
    if write_result.returncode != 0:
        stderr = write_result.stderr.strip() or "unknown error"
        raise RuntimeError(f"Could not write {WITTYPI_SCHEDULE}: {stderr}")

    arm_result = run_command(["sudo", WITTYPI_RUN_SCRIPT])
    if arm_result.returncode != 0:
        stderr = arm_result.stderr.strip() or "unknown error"
        raise RuntimeError(f"Could not arm Witty Pi preview hold: {stderr}")

    if arm_result.stdout.strip():
        print(arm_result.stdout.strip())
    print("After-hours Witty Pi preview hold armed.")
    return True


def restore_witty_schedule():
    if not os.path.exists(WITTYPI_BEFORE_SCRIPT) or not os.path.exists(WITTYPI_RUN_SCRIPT):
        print("Witty Pi scripts not found; preview hold schedule was not restored.")
        return

    print("Restoring normal Witty Pi schedule...")
    before_result = run_command(["sudo", WITTYPI_BEFORE_SCRIPT])
    if before_result.returncode != 0:
        stderr = before_result.stderr.strip() or "unknown error"
        print(f"WARNING: could not regenerate normal Witty Pi schedule: {stderr}", file=sys.stderr)
        return

    arm_result = run_command(["sudo", WITTYPI_RUN_SCRIPT])
    if arm_result.returncode != 0:
        stderr = arm_result.stderr.strip() or "unknown error"
        print(f"WARNING: could not re-arm normal Witty Pi schedule: {stderr}", file=sys.stderr)
        return

    if arm_result.stdout.strip():
        print(arm_result.stdout.strip())
    print("Normal Witty Pi schedule restored.")


class Detection:
    def __init__(self, coords, category, conf, metadata):
        self.category = int(category)
        self.conf = float(conf)
        self.box = imx500.convert_inference_coords(coords, metadata, picam2)
        self.is_stale = False
        self.track_age_sec = 0.0
        self.track_id = None


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


def metadata_has_current_inference(metadata: dict) -> bool:
    output_tensor = metadata.get("CnnOutputTensor")
    if output_tensor is None:
        return False
    try:
        return len(output_tensor) > 0
    except TypeError:
        return True


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
    intersection = max(0.0, ix2 - ix1) * max(0.0, iy2 - iy1)
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
        if track.id in excluded_track_ids or track.category != detection.category:
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


def create_stale_track(detection, now_mono: float) -> StaleTrack:
    global stale_next_track_id
    track = StaleTrack(
        id=stale_next_track_id,
        category=int(detection.category),
        box=_box_tuple(detection.box),
        conf=float(detection.conf),
        first_seen=now_mono,
        last_seen=now_mono,
    )
    stale_next_track_id += 1
    stale_tracks.append(track)
    return track


def update_track_from_detection(track: StaleTrack, detection, now_mono: float):
    track.box = _box_tuple(detection.box)
    track.conf = float(detection.conf)
    track.last_seen = now_mono


def annotate_stale_detections(detections):
    if not cfg.stale_detection_enabled:
        return detections

    now_mono = time.monotonic()
    expire_stale_tracks(now_mono)
    matched_track_ids = set()

    for detection in detections:
        detection.is_stale = False
        detection.track_age_sec = 0.0
        detection.track_id = None

        track, metrics = find_stale_track(detection, matched_track_ids)
        if track is None:
            track = create_stale_track(detection, now_mono)
            matched_track_ids.add(track.id)
            detection.track_id = track.id
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
            track.suppressed_count = 0
            stale_age = 0.0
        elif stale_age >= cfg.stale_detection_sec:
            detection.is_stale = True
            track.suppressed_count += 1

        detection.track_age_sec = stale_age
        detection.track_id = track.id
        update_track_from_detection(track, detection, now_mono)

    return detections


@lru_cache
def get_labels():
    labels = intrinsics.labels
    if intrinsics.ignore_dash_labels:
        labels = [label for label in labels if label and label != "-"]
    return labels


def draw_detections(request, stream="main"):
    detections = last_results
    if not detections:
        return

    labels = get_labels()
    with MappedArray(request, stream) as m:
        for d in detections:
            x, y, w, h = [int(v) for v in d.box]
            label = labels[d.category] if 0 <= d.category < len(labels) else str(d.category)
            if d.is_stale:
                color = (0, 0, 255)
                text = f"STALE {label} {d.conf:.2f} {d.track_age_sec:.1f}s"
            else:
                color = (0, 255, 0)
                text = f"{label} {d.conf:.2f} {d.track_age_sec:.1f}s"
            cv2.rectangle(m.array, (x, y), (x + w, y + h), color, 2)
            cv2.putText(
                m.array, text, (x + 4, max(14, y + 14)),
                cv2.FONT_HERSHEY_SIMPLEX, 0.5, color, 1
            )

        if time.monotonic() < last_saved_message_until:
            cv2.putText(
                m.array, last_saved_message, (20, 30),
                cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 255), 2
            )


def get_args():
    p = argparse.ArgumentParser()
    p.add_argument("--config", default="/home/pi/data/configs/camera_config_final.ini")
    p.add_argument("--preview-backend", choices=("drm", "qt", "qtgl", "null"))
    return p.parse_args()


def main():
    global cfg, imx500, intrinsics, picam2, last_results, last_saved_message, last_saved_message_until

    args = get_args()
    install_shutdown_signal_handlers()

    service_was_active = False
    witty_hold_armed = False
    started_camera = False

    cfg = read_config(args.config)
    if args.preview_backend:
        cfg.preview_backend = args.preview_backend

    try:
        witty_hold_armed = arm_after_hours_preview_hold(hold_hours=2.0)
        service_was_active = stop_beecam_service()

        imx500 = IMX500(cfg.model_path)
        intrinsics = imx500.network_intrinsics
        if not intrinsics:
            intrinsics = NetworkIntrinsics()
            intrinsics.task = "object detection"

        intrinsics.bbox_order = cfg.bbox_order
        intrinsics.bbox_normalization = cfg.bbox_normalization
        intrinsics.ignore_dash_labels = cfg.ignore_dash_labels
        intrinsics.preserve_aspect_ratio = cfg.preserve_aspect_ratio
        if cfg.postprocess is not None:
            intrinsics.postprocess = cfg.postprocess

        if cfg.labels_path and os.path.exists(cfg.labels_path):
            with open(cfg.labels_path, "r") as f:
                intrinsics.labels = f.read().splitlines()

        intrinsics.update_with_defaults()
        print(f"Preview detection config: postprocess={intrinsics.postprocess} threshold={cfg.threshold} iou={cfg.iou}")

        picam2 = Picamera2(imx500.camera_num)
        ae_mode = ae_exposure_mode_from_string(cfg.ae_exposure_mode)

        main_size = (1280, 960)
        preview_config = picam2.create_preview_configuration(
            main={"size": main_size},
            controls={
                "FrameRate": cfg.fps,
                "AeEnable": cfg.ae_enable,
                "AeExposureMode": ae_mode,
            },
            buffer_count=3,
        )

        picam2.pre_callback = draw_detections

        win_x, win_y, win_w, win_h = compute_preview_window(
            cfg.display_width, cfg.display_height, main_size[0], main_size[1]
        )
        print(
            f"Preview window: {win_w}x{win_h} at ({win_x},{win_y}) "
            f"on {cfg.display_width}x{cfg.display_height} display "
            f"(stream {main_size[0]}x{main_size[1]})"
        )

        if cfg.preview_backend == "null":
            picam2.start_preview(preview_enum(cfg.preview_backend))
        else:
            picam2.start_preview(
                preview_enum(cfg.preview_backend),
                x=win_x, y=win_y, width=win_w, height=win_h,
            )
        imx500.show_network_fw_progress_bar()
        picam2.start(preview_config)
        started_camera = True

        if intrinsics.preserve_aspect_ratio:
            imx500.set_auto_aspect_ratio()

        while True:
            metadata = picam2.capture_metadata()
            results = parse_detections(metadata)
            if metadata_has_current_inference(metadata):
                results = annotate_stale_detections(results)
            last_results = results
            if results:
                last_saved_message = f"Detected {len(results)} object(s)"
                last_saved_message_until = time.monotonic() + 0.5
            time.sleep(0.001)
    except KeyboardInterrupt as exc:
        if exc.args:
            print(f"Preview interrupted: {exc}", file=sys.stderr)
        else:
            print("Preview interrupted.", file=sys.stderr)
    finally:
        if picam2 is not None and started_camera:
            try:
                picam2.stop()
            except Exception:
                pass
        if witty_hold_armed:
            restore_witty_schedule()
        if service_was_active:
            restart_beecam_service()


if __name__ == "__main__":
    main()