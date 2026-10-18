"""Generate independent 2x3 bitmap fixtures from literal channel records."""
from pathlib import Path
from struct import pack

destination = Path(__file__).resolve().parent
colors = [(255, 0, 0), (0, 255, 0), (0, 0, 255),
          (255, 255, 0), (255, 0, 255), (0, 255, 255)]
alpha = [255, 128, 0, 255, 64, 255]


def write(name, bits, compression=0, top_down=False, version=40):
    palette = b""
    masks = b""
    if bits == 8:
        palette = b"".join(pack("BBBB", b, g, r, 0) for r, g, b in colors)
    if bits == 16:
        masks = pack("<III", 0xF800, 0x07E0, 0x001F)
    if version == 108:
        masks = pack("<IIII", 0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000)
    data = bytearray()
    for y in (range(3) if top_down else range(2, -1, -1)):
        row = bytearray()
        for x in range(2):
            index = y * 2 + x
            r, g, b = colors[index]
            if compression == 1:
                row.extend((1, index))
            elif bits == 8:
                row.append(index)
            elif bits == 16:
                row.extend(pack("<H", ((r * 31 // 255) << 11) | ((g * 63 // 255) << 5) | (b * 31 // 255)))
            elif bits == 24:
                row.extend((b, g, r))
            else:
                row.extend((b, g, r, alpha[index]))
        if compression == 1:
            row.extend((0, 0))
        else:
            row.extend(b"\0" * (-len(row) % 4))
        data.extend(row)
    if compression == 1:
        data.extend((0, 1))
    header = pack("<IiiHHIIiiII", version, 2, -3 if top_down else 3, 1, bits,
                  compression, len(data), 0, 0, 6 if bits == 8 else 0, 0)
    if version > 40:
        header += masks
        header += b"\0" * (version - len(header))
        masks = b""
    offset = 14 + len(header) + len(masks) + len(palette)
    file_header = pack("<2sIHHI", b"BM", offset + len(data), 0, 0, offset)
    (destination / name).write_bytes(file_header + header + masks + palette + data)


write("bitmap24.bmp", 24)
write("bitmap24-top.bmp", 24, top_down=True)
write("bitmap32.bmp", 32)
write("bitmap565.bmp", 16, compression=3)
write("bitmap8.bmp", 8)
write("bitmap-rle8.bmp", 8, compression=1)
write("bitmap-alpha.bmp", 32, compression=3, version=108)

# The older core header uses RGB triples and a fixed-size palette.
core_pixels = bytes((0b01000000, 0, 0, 0, 0b10000000, 0, 0, 0,
                     0b01000000, 0, 0, 0))
core_header = pack("<IHHHH", 12, 2, 3, 1, 1)
core_palette = bytes((0, 0, 255, 0, 255, 0))
core_offset = 14 + len(core_header) + len(core_palette)
(destination / "bitmap-core.bmp").write_bytes(
    pack("<2sIHHI", b"BM", core_offset + len(core_pixels), 0, 0, core_offset)
    + core_header + core_palette + core_pixels)
