#!/usr/bin/env python3
"""Turn mini2d's dumped frames (PPM) in a folder into PNG, standard library only."""
import struct
import sys
import zlib
from pathlib import Path


def png(path, w, h, rgb):
    raw = b"".join(b"\x00" + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


if __name__ == "__main__":
    for ppm in sorted(Path(sys.argv[1]).glob("*.ppm")):
        data = ppm.read_bytes()
        head = data.split(b"\n", 3)
        w, h = map(int, head[1].split())
        png(ppm.with_suffix(".png"), w, h, head[3][:w * h * 3])
        ppm.unlink()
