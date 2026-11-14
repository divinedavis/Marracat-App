#!/usr/bin/env python3
"""Render launch-20s.html to a 1920x1080 30 fps MP4.

    /usr/bin/python3 app-store/promo/render.py            # full render
    /usr/bin/python3 app-store/promo/render.py --stills   # one PNG per scene, for review

Seeks every CSS animation to each frame's time (window.seek) and screenshots
it, so the output is frame-exact regardless of machine speed.
"""
import argparse
import pathlib
import subprocess
import tempfile

from playwright.sync_api import sync_playwright

HERE = pathlib.Path(__file__).resolve().parent
PAGE = HERE / "launch-20s.html"
OUT = HERE / "marracat-launch-20s.mp4"
FPS, DURATION = 30, 20
STILLS = [1.0, 2.6, 4.2, 6.6, 8.4, 10.2, 12.0, 13.6, 14.8, 16.6, 19.2]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stills", action="store_true")
    args = ap.parse_args()

    with sync_playwright() as p, tempfile.TemporaryDirectory() as tmp:
        browser = p.chromium.launch()
        page = browser.new_page(viewport={"width": 1920, "height": 1080})
        page.goto(PAGE.as_uri())
        page.evaluate("window.ready")
        times = STILLS if args.stills else [i / FPS for i in range(FPS * DURATION)]
        for i, t in enumerate(times):
            page.evaluate(f"seek({t})")
            if args.stills:
                page.screenshot(path=str(HERE / f"still-{t:05.2f}.png"))
            else:
                page.screenshot(path=f"{tmp}/f{i:04d}.png")
        browser.close()
        if args.stills:
            return
        subprocess.run([
            "ffmpeg", "-v", "error", "-y", "-framerate", str(FPS), "-i", f"{tmp}/f%04d.png",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "16", "-preset", "slow",
            "-movflags", "+faststart", str(OUT),
        ], check=True)
    print(OUT)


if __name__ == "__main__":
    main()
