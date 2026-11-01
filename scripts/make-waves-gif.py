"""Draws examples/assets/waves.gif, the clip the video example plays."""
import math
import sys
from PIL import Image

WIDTH, HEIGHT, FRAMES = 160, 90, 24


def frame(t):
    image = Image.new("RGB", (WIDTH, HEIGHT))
    pixels = image.load()
    for y in range(HEIGHT):
        for x in range(WIDTH):
            wave = math.sin(x / 14 + t * 2 * math.pi) * 6 + math.sin(x / 7 - t * 4 * math.pi) * 3
            depth = (y - HEIGHT / 2 - wave) / HEIGHT
            if depth < 0:
                sky = 1 + depth
                pixels[x, y] = (int(40 + 80 * sky), int(70 + 90 * sky), int(120 + 110 * sky))
            else:
                shade = max(0.0, 1 - depth * 1.6)
                pixels[x, y] = (int(10 + 30 * shade), int(60 + 90 * shade), int(110 + 100 * shade))
    return image.quantize(colors=32, dither=Image.Dither.NONE)


frames = [frame(i / FRAMES) for i in range(FRAMES)]
frames[0].save(sys.argv[1] if len(sys.argv) > 1 else "examples/assets/waves.gif", save_all=True, append_images=frames[1:], duration=60, loop=0, disposal=1, optimize=True)
