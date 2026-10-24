"""Draws the app icon: a squircle with a waveform, rendered at every size iconutil wants."""
import pathlib, subprocess, sys
from PIL import Image, ImageDraw, ImageFilter

S = 1024
def draw() -> Image.Image:
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    m = 100                                         # macOS icon grid margin
    bg = Image.new("RGBA", (S, S))
    px = bg.load()
    for y in range(S):                              # vertical gradient, deep ink to violet
        t = y / S
        c = (int(28 + 70 * t), int(24 + 30 * t), int(62 + 120 * t), 255)
        for x in range(S):
            px[x, y] = c
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([m, m, S - m, S - m], radius=185, fill=255)
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([m, m + 14, S - m, S - m + 14], radius=185, fill=(0, 0, 0, 90))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18)))
    img.paste(bg, (0, 0), mask)
    d = ImageDraw.Draw(img)
    bars = [0.28, 0.52, 0.86, 0.62, 1.0, 0.7, 0.44, 0.24]
    w, gap = 46, 30
    total = len(bars) * w + (len(bars) - 1) * gap
    x0, cy, hmax = (S - total) // 2, S // 2, 470
    for i, b in enumerate(bars):
        h = max(w, int(hmax * b))
        x = x0 + i * (w + gap)
        d.rounded_rectangle([x, cy - h // 2, x + w, cy + h // 2], radius=w // 2, fill=(255, 255, 255, 240))
    return img

out = pathlib.Path(sys.argv[1])
iconset = out.with_suffix(".iconset")
iconset.mkdir(exist_ok=True)
base = draw()
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        base.resize((size * scale,) * 2, Image.LANCZOS).save(iconset / f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png")
subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(out)], check=True)
base.save(out.with_suffix(".png"))
