#!/usr/bin/env python3
from __future__ import annotations

import argparse
import configparser
import socket
from datetime import datetime


def str_to_bool(value: str | None, default: bool = False) -> bool:
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def oled_enabled(config_path: str) -> bool:
    parser = configparser.ConfigParser()
    parser.read(config_path)
    return str_to_bool(parser.get("oled", "enabled", fallback="true"), True)


def get_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="/home/pi/data/configs/camera_config_final.ini")
    return parser.parse_args()


def main() -> int:
    args = get_args()
    if not oled_enabled(args.config):
        return 0

    try:
        from PIL import Image, ImageDraw, ImageFont
        import adafruit_ssd1306
        import board
    except Exception:
        return 0

    try:
        width = 128
        height = 64
        display = adafruit_ssd1306.SSD1306_I2C(width, height, board.I2C())
        font = ImageFont.load_default()
        image = Image.new("1", (width, height))
        draw = ImageDraw.Draw(image)
        draw.rectangle((0, 0, width, height), outline=0, fill=0)

        hostname = socket.gethostname()
        lines = [
            f"{hostname} {datetime.now().strftime('%m-%d %H:%M')}",
            "BeeCam booting",
            "Initializing...",
            "",
            "BOOT",
        ]
        y = 1
        for index, line in enumerate(lines):
            draw_y = y + 1 if index == 0 else y
            draw.text((0, draw_y), line, font=font, fill=255)
            y += 14 if index == 0 else 12

        display.image(image)
        display.show()
    except Exception:
        return 0

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
