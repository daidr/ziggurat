"""Deterministic original pixel fixtures for image sampling tests."""
import pathlib
import struct
import zlib


def png(path, width, height, pixel):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    rows = b"".join(b"\0" + bytes(v for x in range(width) for v in pixel(x, y)) for y in range(height))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))


directory = pathlib.Path(__file__).parent
png(directory / "drawing.png", 16, 16, lambda x, y: ((255, 0, 0, 255) if x < 8 else (0, 255, 0, 128)) if y < 8 else ((0, 0, 255, 0) if x < 8 else (255, 255, 255, 255)))
png(directory / "checker.png", 64, 64, lambda x, y: (255, 0, 0, 0) if (x + y) % 2 == 0 else (0, 0, 255, 255))
png(directory / "bands.png", 8, 4, lambda x, y: (255, 0, 0, 255) if x < 2 else (0, 0, 255, 255) if x >= 6 else (0, 255, 0, 255))
png(directory / "update-red.png", 16, 16, lambda x, y: (255, 0, 0, 255))
png(directory / "update-blue.png", 16, 16, lambda x, y: (0, 0, 255, 255))
