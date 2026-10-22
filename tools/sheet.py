#!/usr/bin/env python3
"""A contact sheet of runs: the last frame of each out/run/<game>/frames, at half size,
four to a row, standard library only (reads the PNGs ppm2png writes: RGB, filter 0).
   tools/sheet.py OUT.png RUN_DIR..."""
import struct
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from ppm2png import png  # noqa: E402  (writes the sheet)

W, H, COLS = 320, 240, 4


def read_png(path):
    data = Path(path).read_bytes()
    pos, idat, w, h = 8, b"", 0, 0
    while pos < len(data):
        n, t = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if t == b"IHDR":
            w, h = struct.unpack(">II", body[:8])
        elif t == b"IDAT":
            idat += body
        pos += 12 + n
    raw = zlib.decompress(idat)
    stride = w * 3 + 1
    return w, h, [raw[y * stride + 1:(y + 1) * stride] for y in range(h)]


def main():
    out, runs = sys.argv[1], sys.argv[2:]
    shots = []
    for r in runs:
        frames = sorted(Path(r, "frames").glob("*.png"))
        if frames:
            shots.append(read_png(frames[-1]))
    rows = (len(shots) + COLS - 1) // COLS
    sw, sh = W * COLS, H * rows
    sheet = bytearray(sw * sh * 3)
    for i, (w, h, lines) in enumerate(shots):
        ox, oy = (i % COLS) * W, (i // COLS) * H
        for y in range(H):
            line = lines[min(h - 1, y * h // H)]
            for x in range(W):
                sx = min(w - 1, x * w // W) * 3
                d = ((oy + y) * sw + ox + x) * 3
                sheet[d:d + 3] = line[sx:sx + 3]
    png(Path(out), sw, sh, bytes(sheet))
    print(out, len(shots), "games")


if __name__ == "__main__":
    main()
