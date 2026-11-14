#!/usr/bin/env python3
"""App Store screenshots, Translate Now style (owner, 2026-11-01: "update our
app store screenshots to look like this ... use our font that we have for
the app icon"): one field across seven 1320x2868 panels, a two-line Futura
headline (the icon's wordmark face), a big phone cropped by the bottom edge,
one UI piece lifted out of each screen, and product photos straddling the
seams so the set reads as one strip.

    /usr/bin/python3 app-store/listing-2026-11/make_panels.py [black|white]

Screens: raw/, the updated app (build after 114eaa9) captured by
AppStoreTourUITests on an iPhone 17 Pro Max simulator.
"""
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).resolve().parent
RAW, OUT = HERE / "raw", HERE / "out"
FUTURA = "/System/Library/Fonts/Supplemental/Futura.ttc"   # index 0 = Medium
W, H, N = 1320, 2868, 7
SW = 1000                      # screen width in a panel
SCALE = SW / 1320              # capture px -> panel px
TOP = 700                      # phone screen top
BEZEL, RIM = 24, 4

# (capture, headline, lifted piece as (x0, y0, x1, y1) in capture px, lift scale, nudge y)
PANELS = [
    ("home", "DISCOVER YOUR\nNEXT FAVORITE", None, 0, 0),
    ("hair-grid", "EVERY AISLE,\nEVERY BRAND", None, 0, 0),
    ("jewelry-results", "SEARCH THAT\nGETS YOU", (0, 195, 1320, 306), 1.0, -40),
    ("fragrance-detail", "MEET THE\nMAKERS", (36, 384, 1284, 591), 0.97, 0),
    ("fragrance-detail-scrolled", "TRACK EVERY\nPRICE DROP", (36, 1086, 1284, 1239), 0.97, 0),
    ("brand-sale-alert", "NEVER MISS\nA SALE", (246, 372, 1074, 486), 1.25, 0),
    ("cart", "ONE CART,\nEVERY BRAND", None, 0, 0),
]
# Product photos on the seams: (capture, crop box in capture px, y centre in the panel)
BUBBLES = [
    ("fragrance-detail", (330, 800, 1030, 1500), 1640),
    ("hair-grid", (100, 650, 560, 1110), 2380),
    ("jewelry-detail", (330, 1180, 1010, 1860), 1500),
    ("home-detail", (230, 990, 890, 1650), 2320),
    ("bodywash-detail", (200, 1100, 1100, 2000), 1620),
    ("brand", (300, 450, 1000, 1150), 2360),
]


def font(size):
    return ImageFont.truetype(FUTURA, size, index=0)


def rounded(img, r):
    m = Image.new("L", (img.width * 3, img.height * 3), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, m.width - 1, m.height - 1), radius=r * 3, fill=255)
    out = img.convert("RGBA")
    out.putalpha(m.resize(img.size, Image.LANCZOS))
    return out


def shadow(canvas, box, r, blur=40, alpha=150, dy=18):
    x0, y0, x1, y1 = [int(v) for v in box]
    pad = blur * 3
    s = Image.new("L", (x1 - x0 + pad * 2, y1 - y0 + pad * 2), 0)
    ImageDraw.Draw(s).rounded_rectangle((pad, pad, pad + x1 - x0, pad + y1 - y0), radius=r, fill=alpha)
    s = s.filter(ImageFilter.GaussianBlur(blur))
    canvas.paste(Image.new("RGBA", s.size, (0, 0, 0, 255)), (x0 - pad, y0 - pad + dy), s)


def tracked(d, cx, y, text, f, fill, tracking):
    widths = [d.textlength(c, font=f) for c in text]
    x = cx - (sum(widths) + tracking * (len(text) - 1)) / 2
    for c, w in zip(text, widths):
        d.text((x, y), c, font=f, fill=fill)
        x += w + tracking


def build(variant):
    dark = variant == "black"
    ink = (255, 255, 255) if dark else (17, 17, 17)
    top, bottom = ((22, 22, 24), (0, 0, 0)) if dark else ((255, 255, 255), (236, 236, 240))
    canvas = Image.new("RGBA", (W * N, H))
    grad = Image.linear_gradient("L").resize((1, H))
    field = Image.composite(Image.new("RGB", (1, H), bottom), Image.new("RGB", (1, H), top), grad)
    canvas.paste(field.resize((W * N, H)), (0, 0))
    d = ImageDraw.Draw(canvas)
    hf = font(100)
    for i, (name, headline, lift, lscale, ny) in enumerate(PANELS):
        ox = i * W
        for k, line in enumerate(headline.split("\n")):
            tracked(d, ox + W / 2, 250 + k * 128, line, hf, ink, 13)
        shot = Image.open(RAW / f"{name}.png").convert("RGB")
        screen = shot.resize((SW, round(shot.height * SCALE)), Image.LANCZOS)
        sx = ox + (W - SW) // 2
        fx0, fy0 = sx - BEZEL - RIM, TOP - BEZEL - RIM
        fx1, fy1 = sx + SW + BEZEL + RIM, TOP + screen.height + BEZEL + RIM
        shadow(canvas, (fx0, fy0, fx1, fy1), 150, blur=50, alpha=170 if dark else 90, dy=30)
        rim = (74, 74, 78) if dark else (200, 200, 206)
        ImageDraw.Draw(canvas).rounded_rectangle((fx0, fy0, fx1, fy1), radius=150, fill=rim)
        ImageDraw.Draw(canvas).rounded_rectangle((fx0 + RIM, fy0 + RIM, fx1 - RIM, fy1 - RIM), radius=146, fill=(8, 8, 9))
        canvas.alpha_composite(rounded(screen, 122), (sx, TOP))
        if lift:
            x0, y0, x1, y1 = lift
            piece = shot.crop(lift)
            # As wide as it sits in the screen, enlarged to break past the frame.
            pw = round((x1 - x0) * SCALE * lscale * 1.30)
            ph = round(pw * piece.height / piece.width)
            piece = piece.resize((pw, ph), Image.LANCZOS)
            cx = sx + ((x0 + x1) / 2) * SCALE
            cy = TOP + ((y0 + y1) / 2) * SCALE + ny
            px, py = round(cx - pw / 2), round(cy - ph / 2)
            r = min(ph // 2, 52)
            shadow(canvas, (px, py, px + pw, py + ph), r, blur=34, alpha=200 if dark else 120, dy=22)
            canvas.alpha_composite(rounded(piece, r), (px, py))
    # Photos straddling the seams.
    for k, (name, box, cy) in enumerate(BUBBLES):
        shot = Image.open(RAW / f"{name}.png").convert("RGB").crop(box)
        s = min(shot.size)
        shot = shot.crop(((shot.width - s) // 2, (shot.height - s) // 2, (shot.width + s) // 2, (shot.height + s) // 2))
        D, ring = 300, 12
        photo = rounded(shot.resize((D, D), Image.LANCZOS), D // 2)
        cx = (k + 1) * W
        shadow(canvas, (cx - D / 2 - ring, cy - D / 2 - ring, cx + D / 2 + ring, cy + D / 2 + ring), D // 2 + ring, blur=30, alpha=190, dy=16)
        ImageDraw.Draw(canvas).ellipse((cx - D / 2 - ring, cy - D / 2 - ring, cx + D / 2 + ring, cy + D / 2 + ring), fill=(255, 255, 255))
        canvas.alpha_composite(photo, (int(cx - D / 2), int(cy - D / 2)))
    out = OUT / variant
    out.mkdir(parents=True, exist_ok=True)
    panels = []
    for i in range(N):
        p = canvas.crop((i * W, 0, (i + 1) * W, H)).convert("RGB")
        p.save(out / f"{i + 1:02d}.png")
        panels.append(p)
    # Overview: the strip as the App Store shows it, small gaps between panels.
    h = 1000
    w = round(W * h / H)
    strip = Image.new("RGB", (N * w + (N + 1) * 24, h + 48), (233, 233, 238))
    for i, p in enumerate(panels):
        strip.paste(p.resize((w, h), Image.LANCZOS), (24 + i * (w + 24), 24))
    strip.save(OUT / f"overview-{variant}.png")
    return OUT / f"overview-{variant}.png"


if __name__ == "__main__":
    for v in (sys.argv[1:] or ["black", "white"]):
        print(build(v))
