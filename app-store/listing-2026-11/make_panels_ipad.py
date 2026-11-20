#!/usr/bin/env python3
"""The iPad App Store screenshots: the iPhone set's look (make_panels.py:
white field, two-line Futura headline) around the current app on an iPad.

App Review rejected 1.14 (192) under 2.3.3 on 2026-11-20: the iPad set was
still September's, the old design with an iPhone in the first panel. These
are seven 2064x2752 panels (APP_IPAD_PRO_3GEN_129; every other iPad size
falls back to it), each a whole iPad showing a real screen.

    /usr/bin/python3 app-store/listing-2026-11/make_panels_ipad.py

Screens: raw-ipad/, captured by AppStoreTourUITests on an iPad Pro 13-inch
simulator in dark mode with the status bar set to 9:41:

    TEST_RUNNER_MARRACAT_TOUR=1 TEST_RUNNER_MARRACAT_SHOT_DIR=$PWD/app-store/listing-2026-11/raw-ipad \\
      xcodebuild test -project Marracat.xcodeproj -scheme Marracat -destination "id=<iPad Pro 13-inch>" \\
      -only-testing:MarracatUITests/AppStoreTourUITests/testAppStoreTour

Upload:

    ~/.venvs/marracat/bin/python scripts/asc_listing_media.py --display APP_IPAD_PRO_3GEN_129 \\
        --screens app-store/listing-2026-11/out/ipad/*.png
"""
from pathlib import Path
from PIL import Image, ImageDraw

from make_panels import font, rounded, shadow, tracked

HERE = Path(__file__).resolve().parent
RAW, OUT = HERE / "raw-ipad", HERE / "out" / "ipad"
W, H = 2064, 2752
SW = 1520                      # screen width in a panel
TOP = 640                      # iPad screen top
BEZEL, RIM = 30, 4

# (capture, headline): the iPhone set's headlines, on the iPad's own screens.
PANELS = [
    ("home", "DISCOVER YOUR\nNEXT FAVORITE"),
    ("hair-aisles", "EVERY AISLE,\nEVERY BRAND"),
    ("jewelry-results", "SEARCH THAT\nGETS YOU"),
    ("fragrance-detail", "MEET THE\nMAKERS"),
    ("fragrance-detail-scrolled", "TRACK EVERY\nPRICE DROP"),
    ("brand-sale-alert", "NEVER MISS\nA SALE"),
    ("cart", "ONE CART,\nEVERY BRAND"),
]


def panel(name, headline):
    canvas = Image.new("RGBA", (W, H))
    grad = Image.linear_gradient("L").resize((1, H))
    field = Image.composite(Image.new("RGB", (1, H), (236, 236, 240)), Image.new("RGB", (1, H), (255, 255, 255)), grad)
    canvas.paste(field.resize((W, H)), (0, 0))
    d = ImageDraw.Draw(canvas)
    hf = font(150)
    for k, line in enumerate(headline.split("\n")):
        tracked(d, W / 2, 190 + k * 190, line, hf, (17, 17, 17), 20)
    shot = Image.open(RAW / f"{name}.png").convert("RGB")
    screen = shot.resize((SW, round(shot.height * SW / shot.width)), Image.LANCZOS)
    sx = (W - SW) // 2
    fx0, fy0 = sx - BEZEL - RIM, TOP - BEZEL - RIM
    fx1, fy1 = sx + SW + BEZEL + RIM, TOP + screen.height + BEZEL + RIM
    shadow(canvas, (fx0, fy0, fx1, fy1), 64, blur=50, alpha=90, dy=30)
    d.rounded_rectangle((fx0, fy0, fx1, fy1), radius=64, fill=(200, 200, 206))
    d.rounded_rectangle((fx0 + RIM, fy0 + RIM, fx1 - RIM, fy1 - RIM), radius=60, fill=(8, 8, 9))
    canvas.alpha_composite(rounded(screen, 32), (sx, TOP))
    return canvas.convert("RGB")


def build():
    OUT.mkdir(parents=True, exist_ok=True)
    panels = []
    for i, (name, headline) in enumerate(PANELS):
        p = panel(name, headline)
        p.save(OUT / f"{i + 1:02d}.png")
        panels.append(p)
    # Overview: the strip as the App Store shows it.
    h = 900
    w = round(W * h / H)
    strip = Image.new("RGB", (len(panels) * w + (len(panels) + 1) * 24, h + 48), (233, 233, 238))
    for i, p in enumerate(panels):
        strip.paste(p.resize((w, h), Image.LANCZOS), (24 + i * (w + 24), 24))
    strip.save(HERE / "out" / "overview-ipad.png")
    return HERE / "out" / "overview-ipad.png"


if __name__ == "__main__":
    print(build())
