#!/usr/bin/env python3
"""App Store gallery in the Ralph Lauren listing's style.

One soft, out-of-focus dune landscape runs across every panel so the gallery
scrolls as a single scene; each panel carries a two-line serif title-case
headline and a real app screen in a rounded card with a thin white outline.
The panels walk through departments (body wash, hair, home, jewelry, fragrance), not
only clothes.

Input:  app-store/gallery/raw/*.png — 1320x2868 captures written by
        AppStoreTourUITests (TEST_RUNNER_MARRACAT_TOUR=1,
        TEST_RUNNER_MARRACAT_SHOT_DIR=<raw dir>) on an iPhone 17 Pro Max.
Output: app-store/gallery/iphone-69/NN-name.png, 1320x2868 (APP_IPHONE_67 slot).

    ~/.venvs/marracat/bin/python app-store/gallery/make_gallery.py

iPad (2026-09-27): the same tour on an iPad Pro 13-inch sim writes raw-ipad/,
and --ipad renders ipad-13/NN-name.png at 2064x2752 (APP_IPAD_PRO_3GEN_129).

    ~/.venvs/marracat/bin/python app-store/gallery/make_gallery.py --ipad
"""
from __future__ import annotations

import argparse
import math
import pathlib
import random

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = pathlib.Path(__file__).resolve().parent
RAW = HERE / "raw"
OUT = HERE / "iphone-69"
W, H = 1320, 2868
SERIF = "/System/Library/Fonts/Supplemental/Didot.ttc"

# (capture, headline) in App Store order.
PANELS = [
    ("home",              "Independent Brands\nAll in One Place"),
    ("browse",            "Shop Every\nCategory"),
    ("bodywash-results",  "Body Washes\nYou'll Love"),
    ("hair-grid",         "Hair Care\nMade for You"),
    ("home-detail",       "Make Home\nFeel Like You"),
    ("jewelry-detail",    "Jewelry You'll\nWear Every Day"),
    ("fragrance-results", "Find Your\nSignature Scent"),
    ("cart",              "Many Brands\nOne Cart"),
]


# iPad captures to use in place of a phone one. The candle's product photo
# hadn't arrived when the 2026-09-27 iPad tour took its detail shot.
IPAD_SWAPS = {"home-detail": "home-results"}
# Messages builds an App Store link's card from the FIRST iPad panel (its 3:4
# shape fits the bubble), so iPad panel 1 shows the iPhone home screen; panels
# 2-8 stay iPad (owner, 2026-10-09; same as Find A Crib 1.2.7).
IPAD_FROM_IPHONE = {"home"}


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def landscape(width: int, height: int) -> Image.Image:
    """Dusk sky over layered dunes, drawn small and blurred like a shallow
    depth-of-field photo, then scaled up."""
    s = 8
    w, h = width // s, height // s
    img = Image.new("RGB", (w, h))
    px = img.load()
    top, mid, horizon = (38, 58, 74), (92, 112, 124), (214, 176, 138)
    for y in range(h):
        t = y / h
        c = lerp(top, mid, t / 0.35) if t < 0.35 else lerp(mid, horizon, min(1, (t - 0.35) / 0.3))
        for x in range(w):
            px[x, y] = c
    d = ImageDraw.Draw(img)
    rnd = random.Random(7)
    layers = [(0.58, (190, 150, 110), 26), (0.68, (163, 121, 86), 34),
              (0.78, (128, 92, 64), 40), (0.9, (96, 70, 50), 30)]
    for base, colour, amp in layers:
        phases = [rnd.uniform(0, 6.28) for _ in range(3)]
        pts = []
        for x in range(0, w + 1, 2):
            yy = base * h + sum(amp / (k + 1) * math.sin(x / (140 / (k + 1)) + phases[k]) for k in range(3))
            pts.append((x, yy))
        d.polygon(pts + [(w, h), (0, h)], fill=colour)
    # Dune grass tufts along the front ridge.
    for _ in range(w // 3):
        x = rnd.uniform(0, w)
        y = h * rnd.uniform(0.84, 0.98)
        for _ in range(4):
            d.line((x, y, x + rnd.uniform(-10, 10), y - rnd.uniform(18, 40)), fill=(150, 128, 78), width=1)
    img = img.filter(ImageFilter.GaussianBlur(6))
    return img.resize((width, height), Image.BICUBIC).filter(ImageFilter.GaussianBlur(4))


def grain(img: Image.Image, seed: int) -> Image.Image:
    noise = Image.effect_noise(img.size, 14).convert("RGB")
    return Image.blend(img, noise, 0.035)


def panel(bg: Image.Image, raw: Image.Image, headline: str) -> Image.Image:
    canvas = bg.copy()
    # Darken the sky behind the headline a touch so white text always reads.
    shade = Image.new("L", (W, H), 0)
    ImageDraw.Draw(shade).rectangle((0, 0, W, int(560 * W / 1320)), fill=60)
    canvas = Image.composite(Image.new("RGB", (W, H), (20, 28, 36)), canvas,
                             shade.filter(ImageFilter.GaussianBlur(160)))
    draw = ImageDraw.Draw(canvas)
    k = W / 1320   # everything was laid out on the 1320-wide iPhone panel
    f = ImageFont.truetype(SERIF, int(118 * k))
    y = int(170 * k)
    for line in headline.split("\n"):
        tw = draw.textlength(line, font=f)
        draw.text(((W - tw) / 2, y), line, font=f, fill=(255, 255, 255))
        y += int(134 * k)

    # Screen card with a thin white outline standing off it, as in the RL set.
    # An iPad screen is squatter than a phone's, so fit the card to the height left.
    top = y + int(90 * k)
    card_w = min(int(1000 * k), int((H - top - 110 * k) * raw.width / raw.height))
    card_h = int(raw.height * card_w / raw.width)
    left = (W - card_w) // 2
    gap, stroke = int(26 * k), max(5, int(5 * k))
    outline = (left - gap, top - gap, left + card_w + gap, top + card_h + gap)
    glass = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glass)
    gd.rounded_rectangle(outline, radius=int(112 * k), fill=(255, 255, 255, 38),
                         outline=(255, 255, 255, 235), width=stroke)
    canvas.paste(glass, (0, 0), glass)
    screen = raw.resize((card_w, card_h), Image.LANCZOS)
    mask = Image.new("L", screen.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, card_w, card_h), radius=int(88 * k), fill=255)
    canvas.paste(screen, (left, top), mask)
    return canvas


def main() -> None:
    global RAW, OUT, W, H
    ap = argparse.ArgumentParser()
    ap.add_argument("--ipad", action="store_true", help="iPad Pro 13-inch panels from raw-ipad/")
    ipad = ap.parse_args().ipad
    if ipad:
        RAW, OUT, W, H = HERE / "raw-ipad", HERE / "ipad-13", 2064, 2752
    OUT.mkdir(exist_ok=True)
    for old in OUT.glob("*.png"):
        old.unlink()
    scene = landscape(W * len(PANELS), H)
    for i, (key, headline) in enumerate(PANELS, start=1):
        bg = grain(scene.crop(((i - 1) * W, 0, i * W, H)), i)
        out = OUT / f"{i:02d}-{key}.png"
        capture = IPAD_SWAPS.get(key, key) if ipad else key
        src = HERE / "raw" if ipad and key in IPAD_FROM_IPHONE else RAW
        panel(bg, Image.open(src / f"{capture}.png").convert("RGB"), headline).save(out, optimize=True)
        print("  ✓", out.name)


if __name__ == "__main__":
    main()
