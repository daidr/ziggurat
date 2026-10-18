"""Generate lossy/lossless/animated WebP and independent decoded RGBA oracles."""
from pathlib import Path
from random import Random
from PIL import Image

destination = Path(__file__).resolve().parent
random = Random(0x8e3b)
image = Image.new("RGBA", (31, 27))
image.putdata([(random.randrange(256), random.randrange(256), random.randrange(256),
                (0, 64, 128, 255)[(x + y) % 4])
               for y in range(27) for x in range(31)])
for lossless in (False, True):
    name = "webp-lossless" if lossless else "webp-lossy"
    image.save(destination / (name + ".webp"), lossless=lossless, quality=85,
               method=6, exact=True)
    with Image.open(destination / (name + ".webp")) as verify:
        (destination / (name + ".rgba")).write_bytes(verify.convert("RGBA").tobytes())
image.convert("RGB").save(destination / "webp-opaque.webp", quality=85, method=6)
palette = Image.new("RGBA", (31, 27))
colors = [(255, 0, 0, 255), (0, 255, 0, 128), (0, 0, 255, 0), (255, 255, 0, 64)]
palette.putdata([colors[(x // 3 + y) % 4] for y in range(27) for x in range(31)])
palette.save(destination / "webp-palette.webp", lossless=True, exact=True)
for name in ("webp-opaque", "webp-palette"):
    with Image.open(destination / (name + ".webp")) as verify:
        (destination / (name + ".rgba")).write_bytes(verify.convert("RGBA").tobytes())
first = Image.new("RGB", (2, 3), (255, 0, 0))
second = Image.new("RGB", (2, 3), (0, 255, 0))
first.save(destination / "webp-animated.webp", save_all=True,
           append_images=[second], duration=10, loop=0, lossless=True)
