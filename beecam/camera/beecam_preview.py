#!/usr/bin/env python3

import argparse
import configparser
import os
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
    ae_enable: bool
    ae_exposure_mode: str
    preview_backend: str


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
        ae_enable=getbool("exposure", "ae_enable", fallback=True),
        ae_exposure_mode=get("exposure", "ae_exposure_mode", fallback="short").strip().lower(),
        preview_backend=get("debug", "preview_backend", fallback="qt").strip().lower(),
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
    return mapping.get(name, Preview.QT)


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


def draw_detections(request, stream="main"):
    detections = last_results
    if not detections:
        return

    labels = get_labels()
    with MappedArray(request, stream) as m:
        for d in detections:
            x, y, w, h = [int(v) for v in d.box]
            label = labels[d.category] if 0 <= d.category < len(labels) else str(d.category)
            text = f"{label} ({d.conf:.2f})"
            cv2.rectangle(m.array, (x, y), (x + w, y + h), (0, 255, 0), 2)
            cv2.putText(
                m.array, text, (x + 4, max(14, y + 14)),
                cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 0, 255), 1
            )

        if time.monotonic() < last_saved_message_until:
            cv2.putText(
                m.array, last_saved_message, (20, 30),
                cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 255), 2
            )


def get_args():
    p = argparse.ArgumentParser()
    p.add_argument("--config", default="camera_config.ini")
    return p.parse_args()


def main():
    global cfg, imx500, intrinsics, picam2, last_results, last_saved_message, last_saved_message_until

    args = get_args()
    cfg = read_config(args.config)

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

    picam2 = Picamera2(imx500.camera_num)
    ae_mode = ae_exposure_mode_from_string(cfg.ae_exposure_mode)

    preview_config = picam2.create_preview_configuration(
        main={"size": (cfg.preview_width, cfg.preview_height)},
        controls={
            "FrameRate": cfg.fps,
            "AeEnable": cfg.ae_enable,
            "AeExposureMode": ae_mode,
        },
        buffer_count=3,
    )

    picam2.pre_callback = draw_detections
    picam2.start_preview(preview_enum(cfg.preview_backend))
    imx500.show_network_fw_progress_bar()
    picam2.start(preview_config)

    if intrinsics.preserve_aspect_ratio:
        imx500.set_auto_aspect_ratio()

    try:
        while True:
            metadata = picam2.capture_metadata()
            results = parse_detections(metadata)
            last_results = results
            if results:
                last_saved_message = f"Detected {len(results)} object(s)"
                last_saved_message_until = time.monotonic() + 0.5
            time.sleep(0.001)
    except KeyboardInterrupt:
        pass
    finally:
        picam2.stop()


if __name__ == "__main__":
    main()
