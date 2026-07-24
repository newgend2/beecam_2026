#!/usr/bin/env python3
from __future__ import annotations

import argparse
import configparser
import socket
from datetime import datetime
from pathlib import Path

I2C_BUS = 1
I2C_ADDRESS = 0x3C
WIDTH = 128
HEIGHT = 64
VERSION_FILE = Path(__file__).resolve().parent / "VERSION"

# Standard SSD1306 init sequence (external VCC off / charge pump on), same
# settings Adafruit's driver uses for a 128x64 panel. Written directly over
# smbus instead of through Blinka (`import board`), whose hardware
# auto-detection on boot is the main thing standing between power-on and the
# splash actually showing up.
_INIT_CMDS = bytes([
    0xAE,        # display off
    0xD5, 0x80,  # set display clock div
    0xA8, HEIGHT - 1,  # set multiplex ratio
    0xD3, 0x00,  # set display offset
    0x40,        # set start line = 0
    0x8D, 0x14,  # charge pump enable
    0x20, 0x00,  # memory addressing mode = horizontal
    0xA1,        # segment remap
    0xC8,        # COM output scan direction
    0xDA, 0x12,  # COM pins config (128x64)
    0x81, 0xCF,  # contrast
    0xD9, 0xF1,  # precharge
    0xDB, 0x40,  # VCOM detect
    0xA4,        # display all on resume (use RAM contents)
    0xA6,        # normal (non-inverted) display
    0xAF,        # display on
])


def str_to_bool(value: str | None, default: bool = False) -> bool:
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def oled_enabled(config_path: str) -> bool:
    parser = configparser.ConfigParser()
    parser.read(config_path)
    return str_to_bool(parser.get("oled", "enabled", fallback="true"), True)


def read_version() -> str:
    try:
        return VERSION_FILE.read_text(encoding="utf-8").strip() or "unknown"
    except OSError:
        return "unknown"


def get_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="/home/pi/data/configs/camera_config_final.ini")
    return parser.parse_args()


def render_splash_image():
    from PIL import Image, ImageDraw, ImageFont

    font = ImageFont.load_default()
    image = Image.new("1", (WIDTH, HEIGHT))
    draw = ImageDraw.Draw(image)
    draw.rectangle((0, 0, WIDTH, HEIGHT), outline=0, fill=0)

    hostname = socket.gethostname()
    lines = [
        f"{hostname} {datetime.now().strftime('%m-%d %H:%M')}",
        "BeeCam booting",
        "Initializing...",
        f"Version {read_version()}",
        "BOOT",
    ]
    y = 1
    for index, line in enumerate(lines):
        draw_y = y + 1 if index == 0 else y
        draw.text((0, draw_y), line, font=font, fill=255)
        y += 14 if index == 0 else 12

    return image


def image_to_ssd1306_buffer(image) -> bytearray:
    pixels = image.load()
    buf = bytearray(WIDTH * HEIGHT // 8)
    for page in range(HEIGHT // 8):
        row = page * WIDTH
        base_y = page * 8
        for x in range(WIDTH):
            byte = 0
            for bit in range(8):
                if pixels[x, base_y + bit]:
                    byte |= 1 << bit
            buf[row + x] = byte
    return buf


def show(image) -> None:
    import smbus

    buf = image_to_ssd1306_buffer(image)
    bus = smbus.SMBus(I2C_BUS)
    try:
        for cmd in _INIT_CMDS:
            bus.write_byte_data(I2C_ADDRESS, 0x00, cmd)

        # Reset the GDDRAM pointer to the top-left corner before streaming
        # the frame; horizontal addressing mode then auto-advances for us.
        bus.write_byte_data(I2C_ADDRESS, 0x00, 0x21)  # set column address
        bus.write_byte_data(I2C_ADDRESS, 0x00, 0x00)
        bus.write_byte_data(I2C_ADDRESS, 0x00, WIDTH - 1)
        bus.write_byte_data(I2C_ADDRESS, 0x00, 0x22)  # set page address
        bus.write_byte_data(I2C_ADDRESS, 0x00, 0x00)
        bus.write_byte_data(I2C_ADDRESS, 0x00, HEIGHT // 8 - 1)

        # smbus block writes are capped at 32 data bytes per call.
        for offset in range(0, len(buf), 32):
            chunk = list(buf[offset:offset + 32])
            bus.write_i2c_block_data(I2C_ADDRESS, 0x40, chunk)
    finally:
        bus.close()


def main() -> int:
    args = get_args()
    if not oled_enabled(args.config):
        return 0

    try:
        image = render_splash_image()
        show(image)
    except Exception:
        return 0

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
