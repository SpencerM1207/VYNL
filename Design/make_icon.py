# Renders the VYNL app icon: the vinyl logo on a pink gradient squircle (macOS Big Sur grid).
import math
from PIL import Image, ImageDraw, ImageFilter, ImageChops

S = 4                      # supersampling
SIZE = 1024 * S
BODY = 824 * S             # Apple's icon grid: 824 body in a 1024 canvas
ORIGIN = (SIZE - BODY) / 2
TOP, BOTTOM = (0xFA, 0xD3, 0xDB), (0xE8, 0x86, 0x9C)   # from the accent #F4BAC5
INK, PAPER = (0x10, 0x10, 0x12), (0xFF, 0xFF, 0xFF)

def squircle(cx, cy, half, n=5.0, steps=2000):
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        pts.append((cx + half * math.copysign(abs(c) ** (2 / n), c), cy + half * math.copysign(abs(s) ** (2 / n), s)))
    return pts

def mask_of(draw_fn):
    m = Image.new("L", (SIZE, SIZE), 0)
    draw_fn(ImageDraw.Draw(m))
    return m

center = SIZE / 2
shape = squircle(center, center, BODY / 2)
body_mask = mask_of(lambda d: d.polygon(shape, fill=255))

# Diagonal gradient with a soft glow at the top left.
grad = Image.new("RGB", (SIZE, SIZE))
gp = grad.load()
small = Image.new("RGB", (256, 256))
sp = small.load()
for y in range(256):
    for x in range(256):
        t = min(max((0.35 * x + 0.65 * y) / 255, 0), 1)
        r, g, b = [TOP[i] + (BOTTOM[i] - TOP[i]) * t for i in range(3)]
        glow = max(0, 1 - math.hypot(x - 60, y - 40) / 170) ** 2 * 0.22
        sp[x, y] = tuple(int(c + (255 - c) * glow) for c in (r, g, b))
grad = small.resize((SIZE, SIZE), Image.BICUBIC)

canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
# Icon shadow, as in Apple's template.
shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
shadow.putalpha(body_mask.point(lambda v: v * 0.28))
shadow = shadow.transform(shadow.size, Image.AFFINE, (1, 0, 0, 0, 1, -10 * S)).filter(ImageFilter.GaussianBlur(14 * S))
canvas = Image.alpha_composite(canvas, shadow)
body = grad.convert("RGBA")
body.putalpha(body_mask)
canvas = Image.alpha_composite(canvas, body)

# The record, from the logo's proportions (radius R): label 0.338, hole 0.087,
# grooves at 0.545 and 0.769 with stroke 0.079 and round ends, spanning 117°-177° and the
# same rotated 180°.
R = 300 * S
cx = cy = center
disc_shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
ds = ImageDraw.Draw(disc_shadow)
ds.ellipse((cx - R, cy - R + 16 * S, cx + R, cy + R + 16 * S), fill=(90, 20, 40, 120))
disc_shadow = disc_shadow.filter(ImageFilter.GaussianBlur(22 * S))
clip = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0)); clip.putalpha(body_mask)
disc_shadow.putalpha(ImageChops.multiply(disc_shadow.getchannel("A"), body_mask))
canvas = Image.alpha_composite(canvas, disc_shadow)

logo = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
d = ImageDraw.Draw(logo)
d.ellipse((cx - R, cy - R, cx + R, cy + R), fill=INK)
w = 0.079 * R
def groove(r, a0, a1):
    # a0..a1 in math degrees (counterclockwise, y up)
    rr = r + w / 2
    d.arc((cx - rr, cy - rr, cx + rr, cy + rr), start=360 - a1, end=360 - a0, fill=PAPER, width=int(round(w)))
    for a in (a0, a1):
        x = cx + r * math.cos(math.radians(a)); y = cy - r * math.sin(math.radians(a))
        d.ellipse((x - w / 2, y - w / 2, x + w / 2, y + w / 2), fill=PAPER)
for base in (0, 180):
    groove(0.545 * R, base + 118, base + 176)
    groove(0.769 * R, base + 117, base + 177)
lr = 0.338 * R; hr = 0.087 * R
d.ellipse((cx - lr, cy - lr, cx + lr, cy + lr), fill=PAPER)
d.ellipse((cx - hr, cy - hr, cx + hr, cy + hr), fill=INK)
canvas = Image.alpha_composite(canvas, logo)

icon = canvas.resize((1024, 1024), Image.LANCZOS)
icon.save("AppIcon-1024.png")

# Logo alone, to compare with the original.
flat = Image.new("RGBA", (SIZE, SIZE), (247, 247, 247, 255))
flat = Image.alpha_composite(flat, logo).resize((512, 512), Image.LANCZOS)
flat.save("logo-check.png")

# .icns with every standard size.
sizes = [16, 32, 64, 128, 256, 512, 1024]
icon.save("AppIcon.icns", format="ICNS", append_images=[icon.resize((s, s), Image.LANCZOS) for s in sizes[:-1]])
print("ok")
