#!/usr/bin/env python3
"""App preview video, Translate Now style (owner, 2026-11-01: "do an animated
video like this too ... use our font that we have for the app icon"): the
app's own screens, a dot where each tap lands, a short Futura caption per
feature, and the wordmark at both ends with Apple's App Store badge.

    /usr/bin/python3 app-store/listing-2026-11/make_preview.py

Input: cfr.mp4, the tour recording (AppStoreTourUITests on an iPhone 17 Pro
Max simulator, updated app) at 30 fps and 886x1920, and tour-events.json,
the tour's tap times; OFFSET below lines the two clocks up. Output: out/marracat-preview-886x1920.mp4 (H.264, 30 fps, silent AAC).
"""
import subprocess
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
FUTURA = "/System/Library/Fonts/Supplemental/Futura.ttc"
W, H, FPS = 886, 1920, 30
OUT = HERE / "out" / "marracat-preview-886x1920.mp4"

# Taps from the tour's activity log (tour-events.json, seconds after the
# recording's creation time). The recording's own clock runs OFFSET seconds
# from that log: measured each recording from the Browse and store-card
# taps (the screen changes ~0.2 s after the touch). 2026-11-01 second take.
import json
EV = json.loads((HERE / "tour-events.json").read_text())
OFFSET = -4.95


def at(name, delta=0.0):
    return EV[name] + OFFSET + delta


def touch(name, look=5.0):
    """When the tap actually landed: the log has when the test asked, and
    XCTest waits for the app to settle first (once 3 s), so take the first
    frame after it that changes the screen, less 0.15 s."""
    import numpy as np
    t0 = at(name, -0.4)
    raw = subprocess.run(["ffmpeg", "-v", "error", "-ss", f"{t0}", "-t", f"{look}", "-i", str(HERE / "cfr.mp4"),
                          "-vf", "fps=30,scale=60:130,format=gray", "-f", "rawvideo", "-"], capture_output=True).stdout
    frames = np.frombuffer(raw, np.uint8).reshape(-1, 130, 60).astype(float)
    diffs = np.abs(np.diff(frames, axis=0)).mean(axis=(1, 2))
    hit = next((i for i, v in enumerate(diffs) if v > max(4.0, diffs.max() * 0.3)), int(diffs.argmax()))
    return t0 + (hit + 1) / 30 - 0.15


# ((start, end) in the recording, caption, taps as (time, x, y) in frame px, caption y)
# Read off the 2026-11-01 recording frame by frame where the detector caught
# a neighbouring change instead (the splash's end; Hair Care opening before
# the aisle tap; the scroll after the bell). Re-check after a new recording.
BY_EYE = {"home": 28.2, "sub": 48.35, "sale": 204.3}


def segments():
    t = {k: touch(k) for k in ("browse", "res", "visit", "cart")}
    t.update({k: v for k, v in BY_EYE.items() if k != "home"})
    print("taps at", {k: round(v, 2) for k, v in t.items()})
    return [
        # Home from the top, once the splash is gone and before the tour scrolls it.
        ((BY_EYE["home"], BY_EYE["home"] + 2.8), "SHOP INDEPENDENT BRANDS", [], 1430),
        ((t["browse"] - 0.25, t["browse"] + 0.75), "SHOP INDEPENDENT BRANDS", [(t["browse"], 281, 1772)], 1430),
        ((t["sub"] - 0.75, t["sub"] + 1.0), "EVERY AISLE", [(t["sub"], 360, 1090)], 1430),
        # Above the keyboard while the search is being typed.
        ((at("p", -0.66), at("p", 4.34)), "SEARCH THAT GETS YOU", [], 820),
        ((t["res"] - 0.3, t["res"] + 2.1), None, [(t["res"], 520, 470)], 1430),
        ((at("swipe", 0.69), at("swipe", 3.09)), "TRACK EVERY PRICE DROP", [], 1430),
        ((t["visit"] - 0.3, t["visit"] + 2.1), "MEET THE MAKERS", [(t["visit"], 443, 315)], 1430),
        ((t["sale"] - 0.3, t["sale"] + 2.6), "NEVER MISS A SALE", [(t["sale"], 805, 952)], 1430),
        ((t["cart"] - 0.25, t["cart"] + 2.55), "ONE CART, EVERY BRAND", [(t["cart"], 434, 1778)], 1430),
    ]


INTRO, OUTRO = 2.3, 2.6


def futura(size):
    return ImageFont.truetype(FUTURA, size, index=0)


def tracked_width(d, text, f, tracking):
    return sum(d.textlength(c, font=f) for c in text) + tracking * (len(text) - 1)


def draw_tracked(d, cx, y, text, f, fill, tracking):
    x = cx - tracked_width(d, text, f, tracking) / 2
    for c in text:
        d.text((x, y), c, font=f, fill=fill)
        x += d.textlength(c, font=f) + tracking


def ease(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def card(t, total, outro):
    """The wordmark on white, as the app icon draws it."""
    im = Image.new("RGB", (W, H), (255, 255, 255))
    d = ImageDraw.Draw(im)
    a = ease(t / 0.6) if not outro else ease(t / 0.5)
    ink = tuple(int(255 - (255 - c) * a) for c in (17, 17, 17))
    grey = tuple(int(255 - (255 - c) * ease((t - 0.35) / 0.6)) for c in (110, 110, 116))
    draw_tracked(d, W / 2, 820 - 20 * (1 - a), "MARRACAT", futura(98), ink, 16)
    draw_tracked(d, W / 2, 960, "DISCOVER YOUR NEXT FAVORITE", futura(30), grey, 5)
    if outro:
        badge = Image.open(HERE / "img" / "badge-black.png").convert("RGBA")
        bw = 360
        badge = badge.resize((bw, round(badge.height * bw / badge.width)), Image.LANCZOS)
        ba = ease((t - 0.5) / 0.5)
        badge.putalpha(badge.getchannel("A").point(lambda v: int(v * ba)))
        im.paste(badge, ((W - bw) // 2, 1130), badge)
    if not outro and t > total - 0.25:            # fade to the app
        k = ease((t - (total - 0.25)) / 0.25)
        im = Image.blend(im, Image.new("RGB", (W, H), (0, 0, 0)), k)
    return im


def pill(im, text, age, y=1430):
    """A white capsule caption (lower third unless the keyboard is up), rising in."""
    a = ease(age / 0.3)
    if a <= 0 or not text:
        return
    f = futura(44)
    layer = Image.new("RGBA", im.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    tw = tracked_width(d, text, f, 4)
    pw, ph = tw + 84, 108
    x0, y0 = (W - pw) / 2, y + 24 * (1 - a)
    d.rounded_rectangle((x0 + 4, y0 + 10, x0 + pw + 4, y0 + ph + 10), radius=ph / 2, fill=(0, 0, 0, int(90 * a)))
    d.rounded_rectangle((x0, y0, x0 + pw, y0 + ph), radius=ph / 2, fill=(255, 255, 255, int(250 * a)))
    draw_tracked(d, W / 2, y0 + 27, text, f, (17, 17, 17, int(255 * a)), 4)
    im.alpha_composite(layer)


def dot(im, age):
    """Where the finger lands: a soft white dot that swells and fades."""
    if not -0.08 <= age <= 0.5:
        return None
    k = max(0.0, age) / 0.5
    r = 42 + 26 * k
    alpha = int(170 * (1 - k)) if age >= 0 else int(170 * (1 + age / 0.08))
    return r, alpha


def main():
    OUT.parent.mkdir(exist_ok=True)
    enc = subprocess.Popen([
        "ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-",
        "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=44100",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-profile:v", "high", "-crf", "16", "-preset", "slow",
        "-c:a", "aac", "-b:a", "128k", "-shortest", "-movflags", "+faststart", str(OUT)], stdin=subprocess.PIPE)
    n = 0
    for i in range(round(INTRO * FPS)):
        enc.stdin.write(card(i / FPS, INTRO, False).tobytes()); n += 1
    last_caption, caption_start = None, 0.0
    clock = 0.0
    for (start, end), caption, taps, cap_y in segments():
        if caption != last_caption:
            last_caption, caption_start = caption, clock
        frames = round((end - start) * FPS)
        dec = subprocess.Popen(["ffmpeg", "-v", "error", "-ss", f"{start}", "-i", str(HERE / "cfr.mp4"), "-frames:v", str(frames),
                                "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
        for k in range(frames):
            raw = dec.stdout.read(W * H * 3)
            if len(raw) < W * H * 3:
                break
            t_rec = start + k / FPS
            im = Image.frombytes("RGB", (W, H), raw).convert("RGBA")
            for (tt, x, y) in taps:
                got = dot(im, t_rec - tt)
                if got:
                    r, alpha = got
                    layer = Image.new("RGBA", im.size, (0, 0, 0, 0))
                    ImageDraw.Draw(layer).ellipse((x - r, y - r, x + r, y + r), fill=(255, 255, 255, alpha),
                                                  outline=(255, 255, 255, min(255, alpha + 60)), width=3)
                    im.alpha_composite(layer)
            pill(im, caption, clock + k / FPS - caption_start - 0.15, cap_y)
            enc.stdin.write(im.convert("RGB").tobytes()); n += 1
        dec.wait()
        clock += frames / FPS
    for i in range(round(OUTRO * FPS)):
        enc.stdin.write(card(i / FPS, OUTRO, True).tobytes()); n += 1
    enc.stdin.close()
    enc.wait()
    print(f"{OUT} — {n} frames, {n / FPS:.1f} s")


if __name__ == "__main__":
    main()
