#!/usr/bin/env python3
"""A third App Store look, from the owner's 2026-11-01 recording of Cosmos's
listing ("give me previews of this one too"): a warm off-white field, a
small two-line sentence-case headline (Futura Medium, the icon's face),
frameless screens with rounded corners cropped by the bottom edge, a first
panel built around a circle of product photos over the search bar, and one
accent panel tinted from its own screen.

    /usr/bin/python3 app-store/listing-2026-11/make_panels_cosmos.py
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).resolve().parent
RAW, OUT = HERE / "raw", HERE / "out" / "cosmos"
W, H = 1320, 2868
FUTURA = "/System/Library/Fonts/Supplemental/Futura.ttc"
FIELD, INK = (243, 242, 239), (34, 34, 36)

# (capture, headline, accent field or None)
PANELS = [
    ("hair-grid", "Every aisle,\nevery brand", None),
    ("jewelry-results", "Search and\ndiscover", None),
    ("brand", "Meet the\nmakers", (150, 84, 58)),
    ("fragrance-detail-scrolled", "Track every\nprice drop", None),
    ("brand-sale-alert", "Never miss\na sale", None),
    ("cart", "One cart,\nevery brand", None),
]


def futura(size):
    return ImageFont.truetype(FUTURA, size, index=0)


def rounded(img, r):
    m = Image.new("L", (img.width * 2, img.height * 2), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, m.width - 1, m.height - 1), radius=r * 2, fill=255)
    out = img.convert("RGBA")
    out.putalpha(m.resize(img.size, Image.LANCZOS))
    return out


def soft_shadow(canvas, box, r, alpha=60):
    x0, y0, x1, y1 = [int(v) for v in box]
    pad = 90
    s = Image.new("L", (x1 - x0 + 2 * pad, y1 - y0 + 2 * pad), 0)
    ImageDraw.Draw(s).rounded_rectangle((pad, pad, pad + x1 - x0, pad + y1 - y0), radius=r, fill=alpha)
    canvas.paste(Image.new("RGBA", s.size, (0, 0, 0, 255)), (x0 - pad, y0 - pad + 18), s.filter(ImageFilter.GaussianBlur(36)))


def headline(d, text, fill):
    f = futura(84)
    for k, line in enumerate(text.split("\n")):
        d.text(((W - d.textlength(line, font=f)) / 2, 250 + k * 104), line, font=f, fill=fill)


def tiles():
    out = []
    for name in ["bodywash-results", "home-results", "jewelry-results", "fragrance-results"]:
        im = Image.open(RAW / f"{name}.png").convert("RGB")
        out += [im.crop((40, y + 6, 450, y + 416)) for y in (645, 1135, 1625)]
    hg = Image.open(RAW / "hair-grid.png").convert("RGB")
    out += [hg.crop(b) for b in [(40, 640, 620, 1220), (670, 640, 1250, 1220), (40, 1540, 620, 2120), (670, 1540, 1250, 2120)]]
    return out


def panel_one():
    c = Image.new("RGBA", (W, H), FIELD + (255,))
    d = ImageDraw.Draw(c)
    headline(d, "Your next favorite,\nin one place", INK)
    small = futura(34)
    cap = "1,600+ independent brands"
    d.text(((W - d.textlength(cap, font=small)) / 2, 500), cap, font=small, fill=(120, 120, 124))
    # A circle of product photos: a 4x4 grid of rounded tiles inside a round mask.
    D, n, gap = 1060, 4, 14
    t = (D - gap * (n - 1)) // n
    grid = Image.new("RGBA", (D, D), (0, 0, 0, 0))
    for i, tile in enumerate(tiles()[:n * n]):
        s = min(tile.size)
        tile = tile.crop(((tile.width - s) // 2, (tile.height - s) // 2, (tile.width + s) // 2, (tile.height + s) // 2))
        grid.alpha_composite(rounded(tile.resize((t, t), Image.LANCZOS), 26), ((i % n) * (t + gap), (i // n) * (t + gap)))
    mask = Image.new("L", (D * 2, D * 2), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, D * 2 - 1, D * 2 - 1), fill=255)
    grid.putalpha(Image.composite(grid.getchannel("A"), Image.new("L", (D, D), 0), mask.resize((D, D), Image.LANCZOS)))
    c.alpha_composite(grid, ((W - D) // 2, 760))
    # The search bar under it, as the app draws it.
    bw, bh, by = 900, 132, 1930
    soft_shadow(c, ((W - bw) / 2, by, (W + bw) / 2, by + bh), bh // 2, alpha=45)
    d.rounded_rectangle(((W - bw) / 2, by, (W + bw) / 2, by + bh), radius=bh // 2, fill=(255, 255, 255))
    gx, gy = (W - bw) / 2 + 70, by + bh / 2
    d.ellipse((gx - 22, gy - 26, gx + 18, gy + 14), outline=(110, 110, 114), width=6)
    d.line((gx + 12, gy + 8, gx + 34, gy + 30), fill=(110, 110, 114), width=7)
    d.text((gx + 70, gy - 26), "Search Marracat", font=futura(46), fill=(120, 120, 124))
    return c


def feature(name, text, accent):
    field = accent or FIELD
    c = Image.new("RGBA", (W, H), field + (255,))
    d = ImageDraw.Draw(c)
    headline(d, text, (255, 255, 255) if accent else INK)
    shot = Image.open(RAW / f"{name}.png").convert("RGB")
    sw = 1040
    screen = shot.resize((sw, round(shot.height * sw / shot.width)), Image.LANCZOS)
    x, y = (W - sw) // 2, 600
    soft_shadow(c, (x, y, x + sw, y + screen.height), 70, alpha=110 if accent else 70)
    c.alpha_composite(rounded(screen, 70), (x, y))
    return c


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    panels = [panel_one()] + [feature(*p) for p in PANELS]
    for i, p in enumerate(panels):
        p.convert("RGB").save(OUT / f"{i + 1:02d}.png")
    h = 1000
    w = round(W * h / H)
    strip = Image.new("RGB", (len(panels) * w + (len(panels) + 1) * 24, h + 48), (255, 255, 255))
    for i, p in enumerate(panels):
        strip.paste(p.convert("RGB").resize((w, h), Image.LANCZOS), (24 + i * (w + 24), 24))
    strip.save(HERE / "out" / "overview-cosmos.png")
    print(HERE / "out" / "overview-cosmos.png")


if __name__ == "__main__":
    main()
