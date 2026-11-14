#!/usr/bin/env python3
"""Holiday splash animations for the owner (2026-10-20): the app's launch
animation, with each holiday's disc, ring, line and mark, so it can be judged
in motion before any of it is built.

Timings are LaunchAnimationView's: the disc grows from 18% in 0.88 s on
(0.16, 1, 0.3, 1), MARRACAT fades in from 0.137 s to 0.78 s while easing up
from 94%, the disc breathes (to 107%, 1.01 s each way) until Home is ready,
then the exit: the disc swells past the screen corners by 0.46 s on
(0.55, 0, 0.85, 0.5) while the word lifts 23% of the screen and fades, and
the whole splash dissolves by 0.68 s. The holiday adds only the day's line and
mark, fading in after the word, and a ring drawn round the disc.

    python3 scripts/holiday_splash_animations.py [OUT_DIR]

Writes OUT_DIR/splash-animations.html (every holiday, looping) and, with
Playwright and ffmpeg available, one MP4 per holiday in OUT_DIR/splash-videos.
"""
from __future__ import annotations

import html
import pathlib
import shutil
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from holiday_theme_examples import HOLIDAYS, MOTIFS, INK, kinara, next_on, fmt  # noqa: E402

W, H = 390, 844                    # iPhone 16-class points
D = min(W * 0.68, 300)             # disc diameter, as LaunchSurface lays it out
ARRIVE, HOLD, EXIT, HOME = 0.88, 1.6, 0.68, 0.9   # HOLD shows a typical wait; the app's minimum is 0.52 s
LOOP = ARRIVE + HOLD + EXIT + HOME


def pct(t: float) -> str:
    return f"{t / LOOP * 100:.3f}%"


def keyframes() -> str:
    a, h, e = ARRIVE, ARRIVE + HOLD, ARRIVE + HOLD + EXIT
    k = 0.68 / 0.62
    cover = ((W ** 2 + H ** 2) ** 0.5) / D + 0.08
    # The breathe: 1 -> 1.07 -> 1 every 2.02 s from landing until the exit.
    breath = []
    t, up = a, True
    while t + 1.01 < h:
        t += 1.01
        breath.append(f"{pct(t)} {{ transform: scale({1.07 if up else 1}); animation-timing-function: ease-in-out; }}")
        up = not up
    last = 1.07 if not up else 1.0
    return f"""
@keyframes disc {{
  0% {{ transform: scale(.18); animation-timing-function: cubic-bezier(.16,1,.3,1); }}
  {pct(a)} {{ transform: scale(1); animation-timing-function: ease-in-out; }}
  {' '.join(breath)}
  {pct(h)} {{ transform: scale({last}); animation-timing-function: cubic-bezier(.55,0,.85,.5); }}
  {pct(h + 0.42 * k)} {{ transform: scale({cover:.3f}); }}
  100% {{ transform: scale({cover:.3f}); }}
}}
@keyframes word {{
  0%, {pct(0.137)} {{ opacity: 0; transform: translateY(0) scale(.94); }}
  {pct(0.78)} {{ opacity: 1; }}
  {pct(a)} {{ transform: translateY(0) scale(1); }}
  {pct(h + 0.05 * k)} {{ opacity: 1; transform: translateY(0); }}
  {pct(h + 0.42 * k)} {{ opacity: 0; transform: translateY({-H * 0.23:.0f}px); }}
  100% {{ opacity: 0; transform: translateY({-H * 0.23:.0f}px); }}
}}
@keyframes extra {{
  0%, {pct(0.55)} {{ opacity: 0; transform: translateY(6px); }}
  {pct(1.05)} {{ opacity: 1; transform: translateY(0); }}
  {pct(h + 0.05 * k)} {{ opacity: 1; transform: translateY(0); }}
  {pct(h + 0.3 * k)} {{ opacity: 0; transform: translateY({-H * 0.2:.0f}px); }}
  100% {{ opacity: 0; }}
}}
@keyframes ring {{
  0% {{ --sweep: 0deg; }}
  {pct(0.4)} {{ --sweep: 0deg; animation-timing-function: cubic-bezier(.3,0,.2,1); }}
  {pct(1.4)} {{ --sweep: 360deg; }}
  100% {{ --sweep: 360deg; }}
}}
@keyframes splash {{
  0%, {pct(h + 0.42 * k)} {{ opacity: 1; }}
  {pct(e)} {{ opacity: 0; }}
  100% {{ opacity: 0; }}
}}
@keyframes home {{
  0%, {pct(h + 0.3 * k)} {{ opacity: 0; }}
  {pct(e)} {{ opacity: 1; }}
  {pct(LOOP - 0.15)} {{ opacity: 1; }}
  100% {{ opacity: 0; }}
}}
@keyframes flame {{ 0%, {pct(0.9)} {{ opacity: 0; }} {pct(1.0)} {{ opacity: 1; }} 100% {{ opacity: 1; }} }}
@keyframes twinkle {{ 0%, {pct(0.9)} {{ transform: scale(.4) rotate(-30deg); }} {pct(1.4)} {{ transform: scale(1.15) rotate(10deg); }} {pct(1.8)} {{ transform: scale(1) rotate(0); }} 100% {{ transform: scale(1); }} }}
@keyframes sway {{ 0%, {pct(0.9)} {{ transform: rotate(-14deg); }} {pct(1.6)} {{ transform: rotate(8deg); }} {pct(2.2)} {{ transform: rotate(-4deg); }} {pct(2.7)} {{ transform: rotate(0); }} 100% {{ transform: rotate(0); }} }}
@keyframes flicker {{ 0%, 100% {{ transform: scaleY(1); }} 30% {{ transform: scaleY(1.12) skewX(3deg); }} 60% {{ transform: scaleY(.94) skewX(-2deg); }} }}
@keyframes rise {{ 0%, {pct(0.9)} {{ transform: translateY(8px); }} {pct(2.0)} {{ transform: translateY(-3px); }} {pct(2.6)} {{ transform: translateY(0); }} 100% {{ transform: translateY(0); }} }}
"""


MOTION = {"moon": "rise", "star": "twinkle", "sparkle": "twinkle", "burst": "twinkle", "leaf": "sway", "tag": "sway",
          "ornament": "sway", "flame": "flicker", "dove": "rise"}


def mark(h: dict, size: float) -> str:
    key = h.get("motif")
    if not key:
        return ""
    if key == "kinara":
        # Candles light left to right, one every 0.12 s, the way a kinara is lit.
        svg = kinara(int(size * 3.2))
        out, i = [], 0
        for part in svg.split('<path d="M')[1:]:
            out.append(part)
        head = svg.split('<path d="M')[0]
        lit = "".join(
            f'<path style="animation: flame {LOOP}s linear infinite; animation-delay: {i * 0.12:.2f}s; transform-box: fill-box" d="M{p}'
            for i, p in enumerate(out))
        return f'<div class="mark">{head}{lit}</div>'
    motion = MOTION.get(key, "twinkle")
    dur = f"{LOOP}s" if motion != "flicker" else "0.9s"
    return (f'<div class="mark"><svg viewBox="0 0 24 24" width="{size:.0f}" height="{size:.0f}" fill="#fff" '
            f'style="animation: {motion} {dur} ease-in-out infinite; transform-origin: 50% 80%">{MOTIFS[key]}</svg></div>')


def fireworks() -> str:
    """New Year's: three bursts around the disc as it lands, as the app's
    CAEmitterLayer does (gold, silver and red sparks, falling as they fade;
    white would vanish on the white splash)."""
    import math
    spots = [(-0.48, -0.62), (0.5, -0.78), (0.1, 0.8)]
    colors = ["#E8B000", "#A9AEB8", "#C8102E"]
    out = []
    for i, (sx, sy) in enumerate(spots):
        cx, cy = W / 2 + sx * D, H / 2 + sy * D
        for j in range(24):
            a = j / 24 * 2 * math.pi
            r = D * (0.42 + 0.12 * ((j * 7) % 3) / 2)
            out.append(f'<i class="spark" style="left:{cx:.0f}px;top:{cy:.0f}px;background:{colors[j % 3]};'
                       f'--dx:{math.cos(a) * r:.0f}px;--dy:{math.sin(a) * r + D * 0.18:.0f}px;'
                       f'animation-delay:{0.55 + i * 0.45:.2f}s"></i>')
    return "".join(out)


def phone(h: dict | None, scale: float = 1.0) -> str:
    """One splash at device size; `scale` shrinks it for the grid."""
    if h is None:
        h = {"disc": INK, "line": "", "theme_days": (0, 0)}
    ring = h.get("ring")
    ring_html = ""
    if ring:
        n = len(ring)
        stops = ", ".join(f"{c} {i * 360 / n:.0f}deg {(i + 1) * 360 / n:.0f}deg" for i, c in enumerate(ring))
        ring_html = (f'<div class="ringwrap"><div class="ring" style="background: conic-gradient({stops}); '
                     f'-webkit-mask: conic-gradient(#000 var(--sweep), transparent 0); mask: conic-gradient(#000 var(--sweep), transparent 0)"></div></div>')
    line = h.get("line", "")
    fw = fireworks() if h.get("effect") == "fireworks" else ""
    extra = ""
    if line:
        extra = f'<div class="extra"><div class="dline">{html.escape(line)}</div>{mark(h, D * 0.11)}</div>'
    return f'''<div class="device" style="transform: scale({scale}); width:{W}px; height:{H}px">
      <div class="home"><div class="hbar"></div><div class="hcard"></div><div class="hrow"><i></i><i></i><i></i></div><div class="hrow"><i></i><i></i><i></i></div></div>
      <div class="splash">{fw}
        <div class="discwrap">{ring_html}<div class="disc" style="background:{h['disc']}"></div></div>
        <div class="word">MARRACAT</div>
        {extra}
      </div></div>'''


def css() -> str:
    return f"""
@property --sweep {{ syntax: '<angle>'; inherits: true; initial-value: 0deg; }}
:root {{ --ink:#0A0A0A; --muted:#6b6b6b; }}
* {{ box-sizing: border-box; }}
body {{ margin: 0; background: #fff; color: var(--ink); font-family: -apple-system, 'Helvetica Neue', sans-serif; }}
.device {{ position: relative; overflow: hidden; background: #fff; transform-origin: top left; }}
.splash {{ position: absolute; inset: 0; background: #fff; animation: splash {LOOP}s linear infinite; }}
.discwrap {{ position: absolute; left: {(W - D) / 2:.1f}px; top: {(H - D) / 2:.1f}px; width: {D:.1f}px; height: {D:.1f}px;
        animation: disc {LOOP}s linear infinite; }}
.disc {{ position: absolute; inset: 0; border-radius: 50%; }}
.ringwrap {{ position: absolute; inset: -{D * 0.055:.1f}px; border-radius: 50%; animation: ring {LOOP}s linear infinite; }}
.ring {{ position: absolute; inset: 0; border-radius: 50%; }}
.word {{ position: absolute; left: 0; right: 0; top: {H / 2 - D * 0.075:.1f}px; text-align: center; color: #fff;
        font-family: Futura, sans-serif; font-weight: 500; font-size: {D * 0.10:.1f}px; letter-spacing: {D * 0.014:.1f}px;
        animation: word {LOOP}s linear infinite; }}
.extra {{ position: absolute; left: 0; right: 0; top: {H / 2 + D * 0.06:.1f}px; display: flex; flex-direction: column; align-items: center; gap: {D * 0.035:.1f}px;
         animation: extra {LOOP}s linear infinite; }}
.dline {{ font-family: Futura, sans-serif; color: #fff; font-size: {D * 0.042:.1f}px; letter-spacing: {D * 0.012:.1f}px; text-align: center; max-width: {D * 0.78:.0f}px; line-height: 1.35; }}
.mark svg {{ display: block; }}
.spark {{ position: absolute; width: 11px; height: 11px; margin: -5px 0 0 -5px; border-radius: 50%; opacity: 0; box-shadow: 0 0 10px 2px rgba(255,220,120,.85);
         animation: spark {LOOP}s linear infinite; }}
@keyframes spark {{ 0% {{ opacity: 1; transform: translate(0, 0) scale(1); }}
  {1.1 / LOOP * 100:.2f}% {{ opacity: 0; transform: translate(var(--dx), var(--dy)) scale(.4); }}
  100% {{ opacity: 0; transform: translate(var(--dx), var(--dy)) scale(.4); }} }}
.home {{ position: absolute; inset: 0; padding: 60px 18px; animation: home {LOOP}s linear infinite; }}
.hbar {{ height: 40px; border-radius: 20px; background: #f1f1f1; }}
.hcard {{ height: 200px; border-radius: 14px; background: #ececec; margin: 18px 0; }}
.hrow {{ display: flex; gap: 10px; margin-bottom: 10px; }} .hrow i {{ flex: 1; height: 120px; border-radius: 10px; background: #f3f3f3; }}
.wrap {{ max-width: 1180px; margin: 0 auto; padding: 24px 16px 60px; }}
h1 {{ font-family: Futura, sans-serif; font-weight: 500; letter-spacing: .18em; font-size: 28px; margin: 0 0 4px; }}
.lede {{ color: var(--muted); margin: 0 0 22px; max-width: 760px; }}
.grid {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(190px, 1fr)); gap: 26px 18px; }}
.cell {{ display: flex; flex-direction: column; align-items: center; }}
.frame {{ width: {W * 0.42 + 14:.0f}px; height: {H * 0.42 + 14:.0f}px; border-radius: 30px; background: #111; padding: 7px; }}
.screen {{ width: {W * 0.42:.0f}px; height: {H * 0.42:.0f}px; border-radius: 24px; overflow: hidden; }}
.cap {{ font-size: 13px; font-weight: 600; margin-top: 8px; text-align: center; }}
.when {{ font-size: 11.5px; color: var(--muted); text-align: center; }}
@media (prefers-reduced-motion: reduce) {{ .lede::after {{ content: ' (Reduce Motion is on: the animations are paused.)'; }} }}
""" + keyframes()


def page(cells: str, title: str, intro: str) -> str:
    return f'''<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>{title}</title>
<style>{css()}</style></head><body>{cells if not intro else f'<div class="wrap"><h1>MARRACAT · SPLASH</h1><p class="lede">{intro}</p><div class="grid">{cells}</div></div>'}</body></html>'''


def when(h: dict) -> str:
    return f"{h['rule']} · next {fmt(next_on(h['date']))}"


def main() -> None:
    out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "~/Downloads/Marracat-holiday-themes").expanduser()
    out.mkdir(parents=True, exist_ok=True)
    order = [h for h in sorted(HOLIDAYS, key=lambda h: next_on(h["date"])) if h.get("theme_days") is not None]
    scale = 0.42
    cells = (f'<div class="cell"><div class="frame"><div class="screen">{phone(None, scale)}</div></div>'
             f'<div class="cap">Every other day</div><div class="when">Today\'s splash</div></div>')
    cells += "".join(
        f'<div class="cell"><div class="frame"><div class="screen">{phone(h, scale)}</div></div>'
        f'<div class="cap">{html.escape(h["name"])}</div><div class="when">{html.escape(when(h))}</div></div>'
        for h in order)
    intro = ("The app's own launch animation, in each holiday's colours, looping: the disc lands, the word and the "
             "day's line fade in, the disc breathes while Home loads, then swells past the screen and dissolves into "
             f"Home. Timings are the app's; the wait is shown at {HOLD} s (the real one ends when Home is ready).")
    (out / "splash-animations.html").write_text(page(cells, "Marracat Splash", intro))
    print(out / "splash-animations.html")
    videos(out, order)


def videos(out: pathlib.Path, order: list[dict]) -> None:
    """One MP4 per holiday at device size, two loops each."""
    ffmpeg = shutil.which("ffmpeg")
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print("no Playwright: skipped the videos")
        return
    if not ffmpeg:
        print("no ffmpeg: skipped the videos")
        return
    vdir = out / "splash-videos"
    tmp = vdir / ".raw"
    tmp.mkdir(parents=True, exist_ok=True)
    jobs = [("00-everyday", None)] + [(f"{i + 1:02d}-{h['key']}", h) for i, h in enumerate(order)]
    with sync_playwright() as p:
        browser = p.chromium.launch()
        for name, h in jobs:
            src = tmp / f"{name}.html"
            src.write_text(page(phone(h), name, ""))
            ctx = browser.new_context(viewport={"width": W, "height": H}, device_scale_factor=2,
                                      record_video_dir=str(tmp), record_video_size={"width": W * 2, "height": H * 2})
            pg = ctx.new_page()
            pg.goto(src.as_uri())
            pg.wait_for_timeout(int((LOOP * 2 + 0.4) * 1000))
            raw = pg.video.path()
            ctx.close()
            subprocess.run([ffmpeg, "-y", "-loglevel", "error", "-ss", "0.4", "-i", raw, "-t", f"{LOOP * 2:.2f}",
                            "-vf", f"scale={W * 2}:{H * 2},fps=30", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                            "-movflags", "+faststart", str(vdir / f"{name}.mp4")], check=True)
        browser.close()
    shutil.rmtree(tmp)
    print(f"{len(jobs)} videos in {vdir}")


if __name__ == "__main__":
    main()
