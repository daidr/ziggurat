"""Literal raster fixtures plus a Pillow-produced LZW dictionary-growth oracle."""
from pathlib import Path
from struct import pack
from random import Random
from PIL import Image

destination = Path(__file__).resolve().parent
palette = bytes((255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0))


def subblocks(data):
    return b"".join(bytes((len(data[i:i + 255]),)) + data[i:i + 255]
                    for i in range(0, len(data), 255)) + b"\0"


def bits(codes):
    accumulator = count = 0
    result = bytearray()
    for code, width in codes:
        accumulator |= code << count
        count += width
        while count >= 8:
            result.append(accumulator & 255)
            accumulator >>= 8
            count -= 8
    if count:
        result.append(accumulator)
    return bytes(result)


# A local palette, interlace passes, nonzero frame origin, and transparency.
canvas_width, canvas_height, width, height, left, top = 7, 11, 3, 9, 2, 1
indices = [(x + y) % 4 for y in range(height) for x in range(width)]
rows = list(range(0, height, 8)) + list(range(4, height, 8)) \
    + list(range(2, height, 4)) + list(range(1, height, 2))
codes = [(4, 3)]
for y in rows:
    for x in range(width):
        codes.extend(((indices[y * width + x], 3), (4, 3)))
codes.append((5, 3))
data = b"GIF89a" + pack("<HHBBB", canvas_width, canvas_height, 0, 0, 0)
data += b"\x21\xfe\x03abc\0\x21\xff\x0bAPPFIXTURE1\x03xyz\0"
data += b"\x21\xf9\x04\x01\0\0\x02\0"
data += b"," + pack("<HHHHB", left, top, width, height, 0xc1)
data += palette + b"\x02" + subblocks(bits(codes)) + b";"
(destination / "graphic-interlaced.gif").write_bytes(data)
expected = bytearray(canvas_width * canvas_height * 4)
for y in range(height):
    for x in range(width):
        index = indices[y * width + x]
        if index != 2:
            at = ((top + y) * canvas_width + left + x) * 4
            expected[at:at + 4] = palette[index * 3:index * 3 + 3] + b"\xff"
(destination / "graphic-interlaced.rgba").write_bytes(expected)

# Dictionary growth through 12-bit codes, with encoder clears and subblocks.
random = Random(0x6a11)
image = Image.new("P", (192, 128))
image.putpalette(bytes(v for i in range(256) for v in (i, i ^ 0x55, 255 - i)))
image.putdata([random.randrange(256) for _ in range(192 * 128)])
image.save(destination / "graphic-dictionary.gif", optimize=False)
(destination / "graphic-dictionary.rgba").write_bytes(image.convert("RGBA").tobytes())

# Saturate the dictionary and continue without a clear code: a legal deferred
# clear stream, deliberately independent of Pillow's encoder clear decisions.
codes = [(4, 3)]
next_code, width_bits, previous = 6, 3, False
for i in range(40000):
    codes.append((i % 4, width_bits))
    if previous and next_code < 4096:
        next_code += 1
        if next_code == 1 << width_bits and width_bits < 12:
            width_bits += 1
    previous = True
codes.append((5, width_bits))
data = b"GIF87a" + pack("<HHBBB", 200, 200, 0x81, 0, 0) + palette
data += b"," + pack("<HHHHB", 0, 0, 200, 200, 0)
data += b"\x02" + subblocks(bits(codes)) + b";"
(destination / "graphic-deferred-clear.gif").write_bytes(data)
expected = bytes(v for i in range(40000) for v in (*palette[(i % 4) * 3:(i % 4) * 3 + 3], 255))
with Image.open(destination / "graphic-deferred-clear.gif") as verify:
    assert verify.convert("RGBA").tobytes() == expected
(destination / "graphic-deferred-clear.rgba").write_bytes(expected)

# The KwKwK dictionary case expands a code equal to the next free entry.
data = b"GIF87a" + pack("<HHBBB", 3, 1, 0x81, 0, 0) + palette
data += b"," + pack("<HHHHB", 0, 0, 3, 1, 0)
data += b"\x02" + subblocks(bits([(4, 3), (0, 3), (6, 3), (5, 3)])) + b";"
(destination / "graphic-special.gif").write_bytes(data)
with Image.open(destination / "graphic-special.gif") as verify:
    assert verify.convert("RGBA").tobytes() == bytes((255, 0, 0, 255)) * 3

# Two distinct animation frames: the public decoder must return only the first.
first = Image.new("RGB", (2, 2), (255, 0, 0))
second = Image.new("RGB", (2, 2), (0, 255, 0))
first.save(destination / "graphic-animated.gif", save_all=True,
           append_images=[second], duration=10, loop=0)
