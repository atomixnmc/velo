"""Write the identity colour lookup table for PostProcess.lut (render/postfx.v).

    python tools/make_lut.py [size] [out.png]      default: 16 -> lut_identity_16.png (256 x 16)

The strip has `size` slices of size x size: red grows across a slice, green grows downward, blue grows across
the slices. Grade a screenshot in an image editor, apply the same adjustments to this file, and set it as the
PostProcess `lut` (lut_strength 0..1 blends it in). Keep the texture filter linear and never resize it.
"""
import struct
import sys
import zlib


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 16
    out = sys.argv[2] if len(sys.argv) > 2 else f"lut_identity_{n}.png"
    w, h = n * n, n
    rows = bytearray()
    for y in range(h):
        rows.append(0)  # filter: none
        for x in range(w):
            r, b = x % n, x // n
            rows += bytes((round(r * 255 / (n - 1)), round(y * 255 / (n - 1)), round(b * 255 / (n - 1))))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b"")
    with open(out, "wb") as f:
        f.write(png)
    print(f"{out}: {w} x {h}")


if __name__ == "__main__":
    main()
