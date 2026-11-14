#!/usr/bin/env python3
"""A second App Store look, from the owner's 2026-11-01 recording of a
minimalist-launcher app ("give me previews of this one too"): black fading
to a periwinkle glow, a serif-italic lead-in over a bold sans line (Didot
Italic + Futura Bold, Futura being the icon's face), laurel badges, a big
tilted white phone first, then straight dark phones with one UI piece
breaking out. Badges carry only real counts from the catalog.

    /usr/bin/python3 app-store/listing-2026-11/make_panels_glow.py
"""
import math
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).resolve().parent
RAW, OUT = HERE / "raw", HERE / "out" / "glow"
W, H = 1320, 2868
FUTURA = "/System/Library/Fonts/Supplemental/Futura.ttc"
DIDOT = "/System/Library/Fonts/Supplemental/Didot.ttc"
WHITE = (255, 255, 255)

# (capture, italic lead, bold lines, lifted piece in capture px, where it sits: dx, dy in panel px)
PANELS = [
    ("jewelry-results", "Search less,", ["find more."], (0, 195, 1320, 306), (0, -30)),
    ("fragrance-detail", "Meet the", ["makers."], (36, 384, 1284, 591), (-120, 0)),
    ("fragrance-detail-scrolled", "Track every", ["price drop."], (36, 1086, 1284, 1239), (110, 0)),
    ("brand-sale-alert", "Never miss", ["a sale."], (246, 372, 1074, 486), (-90, 0)),
    ("cart", "One cart,", ["every brand."], None, (0, 0)),
]


def f(path, size, index):
    return ImageFont.truetype(path, size, index=index)


def didot_italic(size):
    for i in range(4):
        g = f(DIDOT, size, i)
        if "Italic" in g.getname()[1]:
            return g
    return f(DIDOT, size, 1)


def field():
    """Black, with a periwinkle glow rising from the bottom edge."""
    y = np.linspace(0, 1, H)[:, None]
    x = np.linspace(-1, 1, W)[None, :]
    d = np.sqrt((x * 0.85) ** 2 + ((y - 1.12) * 2.1) ** 2)
    g = np.clip(1 - d, 0, 1) ** 1.6
    base = np.stack([g * 150 + 4, g * 150 + 4, g * 235 + 8], axis=-1)
    return Image.fromarray(base.astype(np.uint8), "RGB").convert("RGBA")


def centred(d, cx, y, text, font, fill=WHITE):
    d.text((cx - d.textlength(text, font=font) / 2, y), text, font=font, fill=fill)


def laurel(canvas, cx, cy, big, small):
    """A two-branch laurel around a figure and a word, in white."""
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    leaf = Image.new("RGBA", (40, 92), (0, 0, 0, 0))
    ImageDraw.Draw(leaf).ellipse((4, 2, 36, 90), fill=WHITE)
    R = 270
    # Each branch climbs from under the figure up its side: angle 250° (bottom)
    # to 130° (top) on the left, mirrored on the right; each leaf lies along
    # the branch.
    for side in (-1, 1):
        for i in range(10):
            theta = 250 - i * 12.5
            t = math.radians(theta)
            lx = cx + R * math.cos(t) if side == -1 else cx - R * math.cos(t)
            ly = cy - R * math.sin(t)
            scale = 0.42 + 0.03 * i
            l2 = leaf.resize((int(40 * scale), int(92 * scale)))
            rot = (theta - 180 + 18) if side == -1 else -(theta - 180 + 18)
            l2 = l2.rotate(rot, expand=True, resample=Image.BICUBIC)
            layer.alpha_composite(l2, (int(lx - l2.width / 2), int(ly - l2.height / 2)))
    d = ImageDraw.Draw(layer)
    centred(d, cx, cy - 72, big, f(FUTURA, 92, 2))
    centred(d, cx, cy + 36, small, f(FUTURA, 40, 0))
    canvas.alpha_composite(layer)


def rounded(img, r):
    m = Image.new("L", (img.width * 2, img.height * 2), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, m.width - 1, m.height - 1), radius=r * 2, fill=255)
    out = img.convert("RGBA")
    out.putalpha(m.resize(img.size, Image.LANCZOS))
    return out


def phone(shot, sw, body, rim):
    """A phone at screen width `sw`: body colour, rim colour, the capture inside."""
    sh = round(shot.height * sw / shot.width)
    b = 26 if body == WHITE else 22
    ph = Image.new("RGBA", (sw + 2 * b, sh + 2 * b), (0, 0, 0, 0))
    d = ImageDraw.Draw(ph)
    d.rounded_rectangle((0, 0, ph.width - 1, ph.height - 1), radius=int(sw * 0.16), fill=rim)
    d.rounded_rectangle((5, 5, ph.width - 6, ph.height - 6), radius=int(sw * 0.155), fill=body)
    ph.alpha_composite(rounded(shot.resize((sw, sh), Image.LANCZOS), int(sw * 0.125)), (b, b))
    return ph


def perspective(img, quad):
    """Warp `img` so its corners land on `quad` (TL, TR, BR, BL) in a canvas its size of the quad's bounds."""
    w, h = img.size
    xs, ys = [p[0] for p in quad], [p[1] for p in quad]
    ox, oy = min(xs), min(ys)
    dst = [(x - ox, y - oy) for x, y in quad]
    src = [(0, 0), (w, 0), (w, h), (0, h)]
    A, B = [], []
    for (x, y), (u, v) in zip(dst, src):
        A += [[x, y, 1, 0, 0, 0, -u * x, -u * y], [0, 0, 0, x, y, 1, -v * x, -v * y]]
        B += [u, v]
    coeffs = np.linalg.solve(np.array(A, float), np.array(B, float))
    size = (int(max(xs) - ox), int(max(ys) - oy))
    return img.transform(size, Image.PERSPECTIVE, tuple(coeffs), Image.BICUBIC), (int(ox), int(oy))


def shadow(canvas, box, r, blur=40, alpha=170, dy=24):
    x0, y0, x1, y1 = [int(v) for v in box]
    pad = blur * 3
    s = Image.new("L", (x1 - x0 + 2 * pad, y1 - y0 + 2 * pad), 0)
    ImageDraw.Draw(s).rounded_rectangle((pad, pad, pad + x1 - x0, pad + y1 - y0), radius=r, fill=alpha)
    canvas.paste(Image.new("RGBA", s.size, (0, 0, 0, 255)), (x0 - pad, y0 - pad + dy), s.filter(ImageFilter.GaussianBlur(blur)))


def panel_one():
    c = field()
    laurel(c, W / 2, 400, "1,600+", "independent brands")
    ph = phone(Image.open(RAW / "home.png").convert("RGB"), 1000, WHITE, (196, 196, 202))
    w, h = ph.size
    # Turned to the right and leaning back, running off the bottom-left.
    quad = [(120, 760), (1150, 900), (1060, 3300), (-40, 3080)]
    warped, (ox, oy) = perspective(ph, quad)
    blur = warped.getchannel("A").filter(ImageFilter.GaussianBlur(40))
    c.paste(Image.new("RGBA", warped.size, (0, 0, 0, 255)), (ox + 30, oy + 40), blur.point(lambda v: int(v * 0.7)))
    c.alpha_composite(warped, (ox, oy))
    return c


def panel_two():
    c = field()
    d = ImageDraw.Draw(c)
    lead = didot_italic(128)
    bold = f(FUTURA, 150, 2)
    y = 820
    centred(d, W / 2, y, "Discover your", lead)
    centred(d, W / 2, y + 190, "next", bold)
    centred(d, W / 2, y + 370, "favorite.", bold)
    laurel(c, W / 2, 2230, "180,000+", "products, one cart")
    return c


def feature(name, lead, lines, lift, nudge):
    c = field()
    d = ImageDraw.Draw(c)
    centred(d, W / 2, 230, lead, didot_italic(118))
    for k, line in enumerate(lines):
        centred(d, W / 2, 380 + k * 150, line, f(FUTURA, 128, 2))
    shot = Image.open(RAW / f"{name}.png").convert("RGB")
    sw = 760
    ph = phone(shot, sw, (10, 10, 11), (70, 70, 76))
    x, y = (W - ph.width) // 2, 900
    shadow(c, (x, y, x + ph.width, y + ph.height), 120, blur=50, alpha=200, dy=30)
    c.alpha_composite(ph, (x, y))
    if lift:
        x0, y0, x1, y1 = lift
        s = sw / shot.width
        piece = shot.crop(lift)
        pw = round((x1 - x0) * s * 1.42)
        piece = piece.resize((pw, round(pw * piece.height / piece.width)), Image.LANCZOS)
        cx = x + 22 + (x0 + x1) / 2 * s + nudge[0]
        cy = y + 22 + (y0 + y1) / 2 * s + nudge[1]
        px, py = int(cx - piece.width / 2), int(cy - piece.height / 2)
        r = min(piece.height // 2, 44)
        shadow(c, (px, py, px + piece.width, py + piece.height), r, blur=30, alpha=220, dy=20)
        c.alpha_composite(rounded(piece, r), (px, py))
    return c


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    panels = [panel_one(), panel_two()] + [feature(*p) for p in PANELS]
    for i, p in enumerate(panels):
        p.convert("RGB").save(OUT / f"{i + 1:02d}.png")
    h = 1000
    w = round(W * h / H)
    strip = Image.new("RGB", (len(panels) * w + (len(panels) + 1) * 24, h + 48), (233, 233, 238))
    for i, p in enumerate(panels):
        strip.paste(p.convert("RGB").resize((w, h), Image.LANCZOS), (24 + i * (w + 24), 24))
    strip.save(HERE / "out" / "overview-glow.png")
    print(HERE / "out" / "overview-glow.png")


if __name__ == "__main__":
    main()
