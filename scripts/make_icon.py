# -*- coding: utf-8 -*-
"""
DualCamSync App 图标生成脚本（占位用）
纯 Python 标准库实现（zlib + struct），不依赖 Pillow。
生成 1024x1024 的 PNG：
  - 深蓝渐变背景（液态玻璃质感基调）
  - 两个重叠的圆（双摄像头意象）：副摄青色 / 主摄琥珀色
"""
import os
import struct
import zlib

W = H = 1024
OUT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "DualCamSync", "Resources", "Assets.xcassets",
    "AppIcon.appiconset", "AppIcon.png",
)


def lerp(a, b, t):
    return int(a + (b - a) * t)


def gradient(y):
    """竖直渐变：#22345C(顶) -> #0A1020(底)"""
    t = y / (H - 1)
    return (lerp(0x22, 0x0A, t), lerp(0x34, 0x10, t), lerp(0x5C, 0x20, t))


def in_circle(x, y, cx, cy, r):
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def pixel_color(x, y):
    r, g, b = gradient(y)
    # 副摄：左侧青色圆
    c = (79, 195, 247)
    if in_circle(x, y, 430, 512, 195):
        r, g, b = c
    # 主摄：右侧琥珀色圆（后画覆盖，形成双摄重叠意象）
    if in_circle(x, y, 598, 512, 238):
        r, g, b = (255, 213, 79)
    # 高光：左上方向简单模拟
    d = ((x - 430) ** 2 + (y - 420) ** 2) ** 0.5
    shine = max(0.0, 1.0 - d / 380.0) * 46
    return (
        min(255, r + int(shine)),
        min(255, g + int(shine)),
        min(255, b + int(shine)),
    )


def png_chunk(tag, data):
    chunk = tag + data
    return (struct.pack(">I", len(data))
            + chunk
            + struct.pack(">I", zlib.crc32(chunk) & 0xFFFFFFFF))


def write_png(path, width, height):
    rows = []
    for y in range(height):
        row = bytearray([0])  # 每行第一个字节：滤波器类型 0
        for x in range(width):
            r, g, b = pixel_color(x, y)
            row += bytes((r, g, b, 255))
        rows.append(bytes(row))
    raw = b"".join(rows)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)  # RGBA8
    png = (b"\x89PNG\r\n\x1a\n"
           + png_chunk(b"IHDR", ihdr)
           + png_chunk(b"IDAT", zlib.compress(raw, 6))
           + png_chunk(b"IEND", b""))

    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(png)
    print("icon written:", path)


if __name__ == "__main__":
    write_png(OUT, W, H)
