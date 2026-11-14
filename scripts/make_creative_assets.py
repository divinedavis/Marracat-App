#!/usr/bin/env python3
"""App Store creative assets (Asset Library, fall 2026) for Marracat.

Three canvases, as in Apple's templates:

    header    3840x1646  product page header (and each custom product page's)
    search    3840x2560  search results slot
    universal 5244x2950  16:9 master Apple can crop into either

The look is type only, after MR PORTER's header (owner's pick, 2026-10-06):
a white field, the letter-spaced black Futura MARRACAT wordmark from the app
icon, a heavy black rule running edge to edge, and one short line in
letter-spaced capitals under it. No photos.

Everything but the rule sits inside the "ART SAFE AREA" of Apple's own
template (developer.apple.com/go/?id=sketch-creative-assets-templates ->
creative_assets-templates.sketch, measured 2026-10-12, see SAFE below). The
header's safe area is only the centre 43% x 40% (1646 x 661): the first set
filled ~58% of the width and an iPhone 17 Pro showed "/ARRACA" with the back
and mute/share buttons over it (owner's screen recording, 2026-10-12). On the
header the wordmark also sits below the band those buttons cover on every
iPhone (canvas y ~490-725, measured from that recording), and a tagline that
is too wide for one line wraps onto two. Only the rule reaches the edges,
where a device crop loses nothing. Apple's content rules: no prices,
discounts, URLs, (c), awards or other stores.

Preview what each device shows: scripts/preview_creative_crops.py.

One set per page: "default" (all three canvases plus the header video), then
one header per custom product page. Upload with dhcr-map ios/scripts/asc_creative_assets.py.

Usage:
    ~/.venvs/marracat/bin/python scripts/make_creative_assets.py [OUT_DIR]
    ~/.venvs/marracat/bin/python scripts/make_creative_assets.py --holidays [OUT_DIR]   # a header per holiday
Default OUT_DIR: ~/Downloads/ASC-creative-assets/marracat
"""
from __future__ import annotations

import pathlib
import sys

from PIL import Image, ImageDraw, ImageFont

FUTURA = "/System/Library/Fonts/Supplemental/Futura.ttc"
CANVASES = {"header": (3840, 1646), "search": (3840, 2560), "universal": (5244, 2950)}
# Apple's art safe areas (x, y, w, h) from creative_assets-templates.sketch.
SAFE = {"header": (1097, 493, 1646, 661), "search": (836, 765, 2168, 1030), "universal": (1921, 660, 1402, 962)}
# Where each element goes, as fractions of the safe area: the name's centre
# and widest extent, the rule's centre, the line block's centre, the line's
# type size and widest extent. The header keeps its upper half clear for the
# App Store's back and mute/share buttons.
LAYOUT = {
    "header": {"name_cy": 0.49, "name_w": 0.68, "rule_cy": 0.665, "line_cy": 0.855, "line_size": 0.105, "line_w": 0.90},
    "search": {"name_cy": 0.30, "name_w": 0.80, "rule_cy": 0.55, "line_cy": 0.78, "line_size": 0.075, "line_w": 0.92},
    "universal": {"name_cy": 0.28, "name_w": 0.80, "rule_cy": 0.55, "line_cy": 0.79, "line_size": 0.072, "line_w": 0.92},
}
WHITE = (255, 255, 255)
INK = (10, 10, 10)

PAGES = {
    "default": {"line": "Independent brands, all in one place"},
    "cpp-beauty": {"line": "Skincare and hair care in one place"},
    "cpp-gifts": {"line": "Gifts from independent brands"},
    "cpp-deals": {"line": "Sale alerts from brands you follow"},
}

# The header video (21:9, 3840x1646, 30 fps, 5-30 s per /v1/appAssetLibraryRefData):
# the same type on white, in motion. The rule draws out from the centre, the
# name fades up, then the line under it changes every few seconds.
VIDEO_FPS = 30
VIDEO_LINES = [
    "Independent brands, all in one place",
    "Skincare, hair care and fragrance",
    "Jewelry, home and gifts",
    "One cart for every brand",
]


def tracked_width(d: ImageDraw.ImageDraw, text: str, f, tracking: float) -> float:
    return sum(d.textlength(c, font=f) for c in text) + tracking * (len(text) - 1)


def draw_tracked(d: ImageDraw.ImageDraw, text: str, f, tracking: float, cy: float, w: int) -> None:
    """Centre `text` horizontally with extra letter spacing, capitals centred on cy."""
    cap = f.getbbox("M")
    x = (w - tracked_width(d, text, f, tracking)) / 2
    y = cy - (cap[1] + cap[3]) / 2
    for c in text:
        d.text((x, y), c, font=f, fill=INK)
        x += d.textlength(c, font=f) + tracking


def fit(d, text, max_w, start, tracking_ratio, index=0):
    size = start
    while True:
        f = ImageFont.truetype(FUTURA, int(size), index=index)
        if tracked_width(d, text, f, size * tracking_ratio) <= max_w:
            return f, size * tracking_ratio
        size -= 2


def wrap(d, text: str, f, tracking: float, max_w: float) -> list[str]:
    """One line if it fits, else the most even two-line break at a space."""
    if tracked_width(d, text, f, tracking) <= max_w:
        return [text]
    words = text.split(" ")
    splits = [(" ".join(words[:i]), " ".join(words[i:])) for i in range(1, len(words))]
    return list(min(splits, key=lambda ab: max(tracked_width(d, x, f, tracking) for x in ab)))


def render(w: int, h: int, page: dict, parts: str = "name rule line", kind: str | None = None) -> Image.Image:
    kind = kind or next(k for k, v in CANVASES.items() if v == (w, h))
    sx, sy, sw, sh = SAFE[kind]
    L = LAYOUT[kind]
    img = Image.new("RGB", (w, h), WHITE)
    d = ImageDraw.Draw(img)
    name_f, name_t = fit(d, "MARRACAT", sw * L["name_w"], sh * 0.40, 0.16)
    if "name" in parts:
        draw_tracked(d, "MARRACAT", name_f, name_t, sy + sh * L["name_cy"], w)
    rule = max(4, round(h * 0.016))
    ry = round(sy + sh * L["rule_cy"])
    if "rule" in parts:
        # A holiday's rule is its colours in equal bands, edge to edge.
        colors = page.get("rule") or ["#0A0A0A"]
        for i, c in enumerate(colors):
            x0, x1 = round(w * i / len(colors)), round(w * (i + 1) / len(colors))
            d.rectangle([x0, ry - rule // 2, x1, ry + rule - rule // 2], fill=c)
    if "line" in parts and page["line"]:
        size = sh * L["line_size"]
        f = ImageFont.truetype(FUTURA, int(size), index=0)
        lines = wrap(d, page["line"].upper(), f, size * 0.06, sw * L["line_w"])
        if any(tracked_width(d, x, f, size * 0.06) > sw * L["line_w"] for x in lines):
            raise SystemExit(f"line too long for the safe area even on two lines: {page['line']!r}")
        pitch = size * 1.25
        cy0 = sy + sh * L["line_cy"] - pitch * (len(lines) - 1) / 2
        for i, text in enumerate(lines):
            draw_tracked(d, text, f, size * 0.06, cy0 + i * pitch, w)
    return img


def header_video(path: pathlib.Path, seconds_per_line: float = 3.0) -> None:
    """Writes the header video with ffmpeg: ink layers rendered once, then
    blended per frame (ink coverage 0..1 -> white..INK)."""
    import subprocess

    import numpy as np

    w, h = CANVASES["header"]

    def ink(page, parts):
        g = np.asarray(render(w, h, page, parts).convert("L"), dtype=np.float32)
        return (255.0 - g) / (255.0 - INK[0])

    name = ink({"line": ""}, "name")
    rule = ink({"line": ""}, "rule")
    lines = [ink({"line": t}, "line") for t in VIDEO_LINES]
    ease = lambda t: 0.0 if t <= 0 else 1.0 if t >= 1 else t * t * (3 - 2 * t)
    cols = np.abs(np.arange(w) - w / 2) / (w / 2)   # 0 at the centre, 1 at the edges

    intro, fade = 1.6, 0.5
    total = intro + seconds_per_line * len(lines)
    cmd = ["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "gray",
           "-s", f"{w}x{h}", "-r", str(VIDEO_FPS), "-i", "-",
           "-c:v", "libx264", "-preset", "slow", "-crf", "16", "-pix_fmt", "yuv420p",
           "-profile:v", "high", "-movflags", "+faststart", str(path)]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    for n in range(round(total * VIDEO_FPS)):
        t = n / VIDEO_FPS
        cover = rule * (cols <= ease((t - 0.2) / 0.9))[None, :]
        cover = np.maximum(cover, name * ease((t - 0.6) / 0.8))
        for i, layer in enumerate(lines):
            start = intro + i * seconds_per_line
            a = ease((t - start) / fade)
            if i < len(lines) - 1:
                a = min(a, 1 - ease((t - start - seconds_per_line + fade) / fade))
            if a > 0:
                cover = np.maximum(cover, layer * a)
        frame = 255.0 - np.clip(cover, 0, 1) * (255.0 - INK[0])
        proc.stdin.write(frame.astype(np.uint8).tobytes())
    proc.stdin.close()
    if proc.wait():
        raise SystemExit("ffmpeg failed")


def holiday_header_video(path: pathlib.Path, hd: dict, scale: float = 1.0, seconds_per_line: float = 3.0) -> None:
    """A holiday's header video (owner, 2026-10-20: "animate the header in
    the app store for each"): the everyday video's motion in the day's
    colours. The rule draws out from the centre, MARRACAT fades up, then the
    day's line and the event's name take turns. `scale` < 1 makes a small
    preview; Apple's upload is 3840x1646 at 30 fps."""
    import subprocess

    import numpy as np
    from PIL import Image

    W, H = CANVASES["header"]
    w, h = round(W * scale) // 2 * 2, round(H * scale) // 2 * 2

    def small(img):
        return img if scale == 1 else img.resize((w, h), Image.LANCZOS)

    def ink(page, parts):
        g = np.asarray(small(render(W, H, page, parts, kind="header").convert("L")), dtype=np.float32)
        return ((255.0 - g) / (255.0 - INK[0]))[..., None]

    name = ink({"line": ""}, "name")
    lines = [ink({"line": t}, "line") for t in (hd["line"], hd["event"]["name"].upper())]
    rule_rgb = np.asarray(small(render(W, H, {"line": "", "rule": hd["rule_colors"]}, "rule", kind="header")), dtype=np.float32)
    rule_mask = (np.abs(rule_rgb - 255.0).sum(axis=2) > 30)[..., None]
    ease = lambda t: 0.0 if t <= 0 else 1.0 if t >= 1 else t * t * (3 - 2 * t)
    cols = (np.abs(np.arange(w) - w / 2) / (w / 2))[None, :, None]
    white = np.full((h, w, 3), 255.0, dtype=np.float32)
    ink_rgb = np.array(INK, dtype=np.float32)

    intro, fade = 1.6, 0.5
    total = intro + seconds_per_line * len(lines)
    cmd = ["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
           "-s", f"{w}x{h}", "-r", str(VIDEO_FPS), "-i", "-",
           "-c:v", "libx264", "-preset", "slow" if scale == 1 else "fast", "-crf", "16", "-pix_fmt", "yuv420p",
           "-profile:v", "high", "-movflags", "+faststart", str(path)]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    for n in range(round(total * VIDEO_FPS)):
        t = n / VIDEO_FPS
        shown = rule_mask & (cols <= ease((t - 0.2) / 0.9))
        frame = np.where(shown, rule_rgb, white)
        cover = name * ease((t - 0.6) / 0.8)
        for i, layer in enumerate(lines):
            start = intro + i * seconds_per_line
            a = ease((t - start) / fade)
            if i < len(lines) - 1:
                a = min(a, 1 - ease((t - start - seconds_per_line + fade) / fade))
            if a > 0:
                cover = np.maximum(cover, layer * a)
        cover = np.clip(cover, 0, 1)
        frame = frame * (1 - cover) + ink_rgb * cover
        proc.stdin.write(frame.astype(np.uint8).tobytes())
    proc.stdin.close()
    if proc.wait():
        raise SystemExit(f"ffmpeg failed on {path}")


def holidays(out: pathlib.Path) -> None:
    """The App Store header for each holiday in holidays.json (2026-10-20):
    the same type on white, the rule in the day's colours, the day's line."""
    import json
    doc = json.loads((pathlib.Path(__file__).resolve().parent.parent / "Marracat/Resources/holidays.json").read_text())
    w, h = CANVASES["header"]
    for hd in doc["holidays"]:
        img = render(w, h, {"line": hd["line"], "rule": hd["rule_colors"]}, kind="header")
        p = out / hd["id"] / f"header-{w}x{h}.png"
        p.parent.mkdir(parents=True, exist_ok=True)
        img.save(p, optimize=True)
        print("wrote", p)
        v = out / hd["id"] / f"header-video-{w}x{h}.mp4"
        holiday_header_video(v, hd, scale=float(__import__("os").environ.get("HEADER_VIDEO_SCALE", "1")))
        print("wrote", v)


def main() -> None:
    if sys.argv[1:2] == ["--holidays"]:
        holidays(pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else
                              pathlib.Path.home() / "Downloads/ASC-creative-assets/marracat/holidays").expanduser())
        return
    out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else
                       pathlib.Path.home() / "Downloads/ASC-creative-assets/marracat").expanduser()
    for name, page in PAGES.items():
        canvases = CANVASES if name == "default" else {"header": CANVASES["header"]}
        for kind, (w, h) in canvases.items():
            img = render(w, h, page)
            assert img.mode == "RGB" and img.size == (w, h)
            p = out / name / f"{kind}-{w}x{h}.png"
            p.parent.mkdir(parents=True, exist_ok=True)
            img.save(p, optimize=True)
            print("wrote", p)
    video = out / "default" / f"header-video-{CANVASES['header'][0]}x{CANVASES['header'][1]}.mp4"
    header_video(video)
    print("wrote", video)


if __name__ == "__main__":
    main()
