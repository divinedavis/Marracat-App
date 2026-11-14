#!/usr/bin/env python3
"""What each device shows of Marracat's App Store creative assets, plus a
check that no type is cropped or sits under the App Store's buttons.

The iPhone crop is calibrated from the owner's screen recording of the live
page on an iPhone 17 Pro (1206 x 2622, 2026-10-12): the header shows canvas
x 1006-2833 by y 232-1410 of 3840 x 1646 (the header is 0.644 x the screen
width tall, from the top of the screen) and the back button and mute/share
pill sit 1-43 pt below the top safe inset. Other iPhones are scaled from
that, assuming the header keeps its proportion (an assumption: Apple
publishes no per-device crop). iPad is an estimate: full width, 21:9 in
portrait and a vertical crop in landscape. What Apple does publish is the
art safe area in its template (make_creative_assets.SAFE); everything but
the edge-to-edge rule must sit inside it, and that check is exact.

    ~/.venvs/marracat/bin/python scripts/preview_creative_crops.py DIR [OUT]

DIR is a make_creative_assets.py output folder; OUT (default DIR/previews)
gets one contact sheet per header (PNG) and per video tagline. Exits 1 if
any frame of any asset puts type outside the safe area or under a button.
"""
from __future__ import annotations

import pathlib
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from make_creative_assets import CANVASES, SAFE, VIDEO_FPS, VIDEO_LINES  # noqa: E402

W, H = CANVASES["header"]
VIS_W = 1827 / W            # visible fraction of the width on an iPhone
VIS_Y0, VIS_Y1 = 232, 1410  # visible canvas rows on an iPhone 17 Pro
HEADER_RATIO = 0.644        # header height / screen width (iPhone)

# name, width pt, scale, top inset pt
IPHONES = [
    ("iPhone SE", 375, 2, 20),
    ("iPhone 13 mini", 375, 3, 50),
    ("iPhone 17 Pro", 402, 3, 62),
    ("iPhone 17 Pro Max", 440, 3, 62),
]
# name, width pt, scale, header height / width (estimate)
IPADS = [("iPad 11-inch portrait (est.)", 834, 2, 9 / 21), ("iPad 13-inch landscape (est.)", 1376, 2, 0.30)]


def iphone_view(name, pt, scale, inset):
    """Canvas rect shown, and the canvas rects the buttons cover."""
    vw = W * VIS_W
    x0 = (W - vw) / 2
    k = vw / pt                                   # canvas px per pt
    y0 = VIS_Y0                                   # same proportional crop
    y1 = y0 + HEADER_RATIO * pt * k
    by0, by1 = y0 + (inset + 1) * k, y0 + (inset + 43) * k
    buttons = [(x0 + 16 * k, by0, x0 + 60 * k, by1), (x0 + vw - 126 * k, by0, x0 + vw - 15 * k, by1)]
    status = (x0, y0, x0 + vw, y0 + inset * k)
    return (x0, y0, x0 + vw, min(H, y1)), buttons, status, pt * scale


def ipad_view(name, pt, scale, ratio):
    vh = min(H, W * ratio)
    y0 = (H - vh) / 2
    k = W / pt
    by0, by1 = y0 + 25 * k, y0 + 67 * k
    buttons = [(20 * k, by0, 64 * k, by1), (W - 130 * k, by0, W - 20 * k, by1)]
    return (0, y0, W, y0 + vh), buttons, (0, y0, W, y0 + 24 * k), pt * scale


VIEWS = [(n, iphone_view(n, *a)) for n, *a in IPHONES] + [(n, ipad_view(n, *a)) for n, *a in IPADS]


def ink_mask(gray: np.ndarray, rule_rows: slice | None) -> np.ndarray:
    m = gray < 128
    if rule_rows is not None:
        m[rule_rows] = False
    return m


def rule_rows(gray: np.ndarray) -> slice | None:
    full = np.where((gray < 128).mean(axis=1) > 0.98)[0]
    return slice(full.min() - 2, full.max() + 3) if len(full) else None


def problems(gray: np.ndarray, kind: str, rows: slice | None = None) -> list[str]:
    m = ink_mask(gray, rows or rule_rows(gray))
    ys, xs = np.nonzero(m)
    if not len(ys):
        return []
    out = []
    sx, sy, sw, sh = SAFE[kind]
    if xs.min() < sx or xs.max() >= sx + sw or ys.min() < sy or ys.max() >= sy + sh:
        out.append(f"type at x {xs.min()}-{xs.max()} y {ys.min()}-{ys.max()} leaves the safe area {SAFE[kind]}")
    if kind == "header":
        for name, (_, buttons, status, _) in VIEWS:
            for bx0, by0, bx1, by1 in buttons + [status]:
                if m[int(by0):int(by1), int(bx0):int(bx1)].any():
                    out.append(f"{name}: type under a button or the status bar")
    return out


def device_shot(img: Image.Image, view) -> Image.Image:
    (x0, y0, x1, y1), buttons, status, px = view
    shot = img.crop((int(x0), int(y0), int(x1), int(y1))).convert("RGBA")
    k = px / (x1 - x0)
    shot = shot.resize((int(px), int((y1 - y0) * k)), Image.LANCZOS)
    over = Image.new("RGBA", shot.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(over)
    for bx0, by0, bx1, by1 in buttons:
        r = ((bx0 - x0) * k, (by0 - y0) * k, (bx1 - x0) * k, (by1 - y0) * k)
        d.rounded_rectangle(r, radius=(r[3] - r[1]) / 2, fill=(120, 120, 120, 200))
    sb = status
    d.rectangle(((sb[0] - x0) * k, 0, (sb[2] - x0) * k, (sb[3] - y0) * k), fill=(255, 80, 80, 40))
    return Image.alpha_composite(shot, over).convert("RGB")


def sheet(img: Image.Image, title: str, out: pathlib.Path) -> None:
    shots = [(n, device_shot(img, v)) for n, v in VIEWS]
    col = 900
    canvas_prev = img.resize((col * 2, int(col * 2 * H / W)))
    d0 = ImageDraw.Draw(canvas_prev)
    sx, sy, sw, sh = SAFE["header"]
    f = col * 2 / W
    d0.rectangle((sx * f, sy * f, (sx + sw) * f, (sy + sh) * f), outline=(0, 160, 255), width=3)
    tiles = [("Full canvas, Apple safe area in blue", canvas_prev)]
    for n, s in shots:
        tw = col if "iPad" not in n else col * 2
        tiles.append((n, s.resize((tw, int(s.height * tw / s.width)))))
    font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Futura.ttc", 28)
    pad, rows, x, y, rowh = 20, [], 0, 0, 0
    layout = []
    for n, t in tiles:
        if x + t.width > col * 2 + pad:
            x, y = 0, y + rowh + 50 + pad
            rowh = 0
        layout.append((n, t, x, y))
        x += t.width + pad
        rowh = max(rowh, t.height)
    out_img = Image.new("RGB", (col * 2 + pad * 2, y + rowh + 50 + pad * 2 + 50), (40, 40, 40))
    d = ImageDraw.Draw(out_img)
    d.text((pad, 10), title, fill="white", font=font)
    for n, t, x, y in layout:
        out_img.paste(t, (pad + x, 60 + y + 40))
        d.text((pad + x, 60 + y), n, fill="white", font=font)
    out.parent.mkdir(parents=True, exist_ok=True)
    out_img.save(out)


def video_frames(path: pathlib.Path):
    p = subprocess.Popen(["ffmpeg", "-loglevel", "error", "-i", str(path), "-f", "rawvideo", "-pix_fmt", "gray", "-"],
                         stdout=subprocess.PIPE)
    n = 0
    while True:
        buf = p.stdout.read(W * H)
        if len(buf) < W * H:
            break
        yield n, np.frombuffer(buf, np.uint8).reshape(H, W)
        n += 1
    p.wait()


def main() -> int:
    src = pathlib.Path(sys.argv[1]).expanduser()
    out = pathlib.Path(sys.argv[2]).expanduser() if len(sys.argv) > 2 else src / "previews"
    bad = []
    for f in sorted(src.rglob("*.png")):
        if out in f.parents:
            continue
        kind = f.stem.split("-")[0]
        if kind not in SAFE:
            continue
        img = Image.open(f).convert("RGB")
        for p in problems(np.asarray(img.convert("L")), kind):
            bad.append(f"{f.relative_to(src)}: {p}")
        if kind == "header":
            sheet(img, str(f.relative_to(src)), out / f"{f.parent.name}-header.png")
    for f in sorted(src.rglob("header-video-*.mp4")):
        # The rule draws out from the centre; its rows come from the last frame.
        *_, (_, final) = video_frames(f)
        rows = rule_rows(final)
        # One sheet per tagline, at the middle of its time on screen.
        mids = {round((1.6 + (i + 0.5) * 3.0) * VIDEO_FPS): i for i in range(len(VIDEO_LINES))}
        n_frames = 0
        for n, g in video_frames(f):
            n_frames += 1
            for p in problems(g.copy(), "header", rows):
                bad.append(f"{f.name} frame {n}: {p}")
            if n in mids:
                sheet(Image.fromarray(g).convert("RGB"), f"{f.name} frame {n}", out / f"video-{mids[n] + 1}.png")
        print(f"checked {n_frames} frames of {f.name}")
    for b in bad[:40]:
        print("PROBLEM", b)
    print("previews in", out)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
