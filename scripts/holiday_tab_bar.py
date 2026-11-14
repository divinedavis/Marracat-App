#!/usr/bin/env python3
"""Holiday tab bar animations for the owner (2026-10-20): the floating tab bar
(FloatingTabBar: a charcoal capsule, white icons, a faint pill under the
selected tab) moving in each holiday's colours. Three styles, so one can be
picked, then the recommended one on every holiday:

  A  Ribbon: a thin band of the day's colours flows along the top edge.
  B  Pill:   the selected tab's pill fills with the colours, drifting, and
             leaves a brief trail of colour when it slides to a new tab.
  C  Glow:   the capsule's outline is the colours, turning slowly, with a
             soft glow beneath.

    python3 scripts/holiday_tab_bar.py [OUT_DIR]

Writes OUT_DIR/tab-bar.html and, with Playwright and ffmpeg, MP4s in
OUT_DIR/tab-bar-videos (each style on Kwanzaa and Juneteenth, then style B
on every holiday).
"""
from __future__ import annotations

import html
import pathlib
import shutil
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from holiday_theme_examples import HOLIDAYS, ICON_BANDS, INK, fmt, next_on  # noqa: E402

W, H = 390, 300          # the bottom of an iPhone screen: content, then the bar
BAR_H, BAR_X = 62, 20
TABS = 5
STEP = 1.3               # the demo taps a new tab this often
LOOP = STEP * TABS

# The bar is charcoal, so pure black reads as a gap; these days get colours
# that show on it.
TAB_COLORS = {
    "black-friday": ["#F2F2F2", "#8C8C8C", "#F2F2F2", "#5A5A5A"],
    "cyber-monday": ["#1D4ED8", "#60A5FA", "#22D3EE"],
    "mlk": ["#FFFFFF", "#9A9A9A", "#5A5A5A"],
}


def palette(key: str) -> list[str]:
    h = next((x for x in HOLIDAYS if x["key"] == key), None)
    if h and h.get("tab"):
        return h["tab"]
    if key in TAB_COLORS:
        return TAB_COLORS[key]
    out = []
    for c, _ in ICON_BANDS[key]:
        c = "#3A3A3A" if c == INK else c
        if c not in out:
            out.append(c)
    return out if len(out) > 1 else out * 2


ICONS = [  # Home (the M mark), Browse, Cart, Saved, You, in the app's order
    '<path d="M4 19V6l8 8 8-8v13" fill="none" stroke="#fff" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>',
    '<path d="M3 6h7M3 11h5M3 16h7" stroke="#fff" stroke-width="2" stroke-linecap="round"/><circle cx="16" cy="12" r="4.2" fill="none" stroke="#fff" stroke-width="2"/><path d="M19 15l3 3" stroke="#fff" stroke-width="2" stroke-linecap="round"/>',
    '<path d="M5 8h14l-1 12H6z" fill="none" stroke="#fff" stroke-width="2" stroke-linejoin="round"/><path d="M9 8V6a3 3 0 0 1 6 0v2" fill="none" stroke="#fff" stroke-width="2"/>',
    '<path d="M12 20s-7-4.4-7-10a4 4 0 0 1 7-2.6A4 4 0 0 1 19 10c0 5.6-7 10-7 10z" fill="none" stroke="#fff" stroke-width="2" stroke-linejoin="round"/>',
    '<circle cx="12" cy="8" r="4" fill="none" stroke="#fff" stroke-width="2"/><path d="M4 21c1-4.5 4.5-6 8-6s7 1.5 8 6" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round"/>',
]


def grad(colors: list[str], angle: int = 90) -> str:
    seq = colors + [colors[0]]
    return f"linear-gradient({angle}deg, {', '.join(seq)})"


def conic(colors: list[str]) -> str:
    seq = colors + [colors[0]]
    return f"conic-gradient(from var(--a), {', '.join(seq)})"


def pill_keyframes() -> str:
    """The pill moves Home -> Browse -> Cart -> Saved -> You and back, with
    the app's spring (response 0.35, damping 0.82: a quick move, slight settle)."""
    inner = W - 2 * BAR_X - 10
    slot = inner / TABS
    frames = []
    for i in range(TABS):
        t0 = i * STEP / LOOP * 100
        x = i * slot
        frames.append(f"{t0:.2f}% {{ transform: translateX({x:.1f}px); }}")
        frames.append(f"{(i * STEP + STEP - 0.36) / LOOP * 100:.2f}% {{ transform: translateX({x:.1f}px); animation-timing-function: cubic-bezier(.3,1.25,.5,1); }}")
    frames.append("100% { transform: translateX(0); }")
    trail = []
    for i in range(TABS):
        a = (i * STEP + STEP - 0.36) / LOOP * 100
        b = (i * STEP + STEP + 0.25) / LOOP * 100
        trail.append(f"{a:.2f}% {{ opacity: 0; }} {(a + b) / 2:.2f}% {{ opacity: .55; }} {b:.2f}% {{ opacity: 0; }}")
    return (f"@keyframes pill {{ {' '.join(frames)} }}\n"
            f"@keyframes trail {{ 0% {{ opacity: 0; }} {' '.join(trail)} 100% {{ opacity: 0; }} }}")


def bar(key: str | None, style: str) -> str:
    cols = palette(key) if key else None
    inner = W - 2 * BAR_X - 10
    slot = inner / TABS
    icons = "".join(f'<div class="tab"><svg viewBox="0 0 24 24" width="23" height="23">{p}</svg></div>' for p in ICONS)
    pill_bg = "linear-gradient(180deg, rgba(255,255,255,.20), rgba(255,255,255,.13))"   # frosted-grey selected pill
    extras = ""
    if cols and style == "B":
        pill_bg = grad(cols, 120)
        extras = f'<div class="trail" style="width:{slot:.1f}px; background:{grad(cols, 90)}"></div>'
    pill = f'<div class="pill {"pill-color" if cols and style == "B" else ""}" style="width:{slot:.1f}px; background:{pill_bg}"></div>'
    ribbon = f'<div class="ribbon" style="background:{grad(cols)}"></div>' if cols and style == "A" else ""
    glow = (f'<div class="glow" style="background:{conic(cols)}"></div><div class="edge" style="background:{conic(cols)}"></div>'
            if cols and style == "C" else "")
    return f'''<div class="device">
      <div class="content"><div class="card"></div><div class="row"><i></i><i></i><i></i></div></div>
      <div class="bar">{glow}<div class="body"></div>{ribbon}<div class="tabs">{extras}{pill}{icons}</div></div></div>'''


def css() -> str:
    return f"""
@property --a {{ syntax: '<angle>'; inherits: true; initial-value: 0deg; }}
:root {{ --ink:#0A0A0A; --muted:#6b6b6b; }}
* {{ box-sizing: border-box; }}
body {{ margin: 0; background: #fff; color: var(--ink); font-family: -apple-system, 'Helvetica Neue', sans-serif; }}
.device {{ position: relative; width: {W}px; height: {H}px; overflow: hidden; background: #fff; }}
.content {{ padding: 18px; }}
.card {{ height: 120px; border-radius: 14px; background: #ececec; }}
.row {{ display: flex; gap: 10px; margin-top: 12px; }} .row i {{ flex: 1; height: 90px; border-radius: 10px; background: #f2f2f2; }}
.bar {{ position: absolute; left: {BAR_X}px; right: {BAR_X}px; bottom: 30px; height: {BAR_H}px; border-radius: {BAR_H / 2}px; }}
/* the bar as of build 166 (FloatingTabBar.swift, 10/24): the owner's medium
   tint, dark ink at 60% over a blur, with a light rim along the top */
.body {{ position: absolute; inset: 0; border-radius: inherit; background: rgba(40,44,48,.60);
        backdrop-filter: blur(14px) saturate(1.4); -webkit-backdrop-filter: blur(14px) saturate(1.4);
        box-shadow: 0 8px 24px rgba(0,0,0,.35), inset 0 1px 0 rgba(255,255,255,.22), inset 0 -1px 0 rgba(255,255,255,.06), inset 0 0 0 .5px rgba(255,255,255,.14); }}
.tabs {{ position: absolute; inset: 5px; display: flex; }}
.tab {{ position: relative; flex: 1; display: flex; align-items: center; justify-content: center; z-index: 2; }}
.pill {{ position: absolute; top: 0; bottom: 0; left: 0; border-radius: 30px; z-index: 1; animation: pill {LOOP}s linear infinite; }}
.pill-color {{ background-size: 170% 100% !important; animation: pill {LOOP}s linear infinite, drift 4s linear infinite;
              box-shadow: inset 0 0 0 1px rgba(255,255,255,.18); }}
.pill-color::after {{ content: ''; position: absolute; inset: 0; border-radius: inherit; background: rgba(0,0,0,.18); }}
.trail {{ position: absolute; top: 6px; bottom: 6px; left: 0; border-radius: 30px; filter: blur(8px); z-index: 0; background-size: 300% 100% !important;
         animation: pill {LOOP}s linear infinite, trail {LOOP}s linear infinite; }}
.ribbon {{ position: absolute; left: 30px; right: 30px; top: 4px; height: 3.5px; border-radius: 2px; background-size: 200% 100% !important;
          animation: drift 3s linear infinite; z-index: 3; }}
.edge {{ position: absolute; inset: -2px; border-radius: {BAR_H / 2 + 2}px; animation: spin 5s linear infinite;
        -webkit-mask: linear-gradient(#000 0 0) content-box, linear-gradient(#000 0 0); -webkit-mask-composite: xor; mask-composite: exclude; padding: 2.5px; }}
.glow {{ position: absolute; inset: 4px 10px -4px; border-radius: {BAR_H / 2}px; filter: blur(14px); opacity: .8; animation: spin 5s linear infinite; }}
.sbar {{ position: absolute; left: {BAR_X - 4}px; right: {BAR_X - 4}px; bottom: {30 + BAR_H + 10}px; height: 44px; border-radius: 22px;
         background: rgba(52,53,57,.62); backdrop-filter: blur(6px) saturate(1.8); -webkit-backdrop-filter: blur(6px) saturate(1.8);
         box-shadow: inset 0 1px 0 rgba(255,255,255,.35), inset 0 0 0 .5px rgba(255,255,255,.25); display: flex; align-items: center; gap: 8px; padding: 0 16px; color: #9a9aa0; font-size: 16px; z-index: 4; }}
.srim {{ position: absolute; inset: 0; border-radius: 22px; padding: 2px; animation: spin 6s linear infinite;
        -webkit-mask: linear-gradient(#000 0 0) content-box, linear-gradient(#000 0 0); -webkit-mask-composite: xor; mask-composite: exclude; }}
.sglass {{ font-size: 18px; transform: scaleX(-1); }}
@keyframes drift {{ from {{ background-position: 0% 50%; }} to {{ background-position: 150% 50%; }} }}
@keyframes spin {{ to {{ --a: 360deg; }} }}
{pill_keyframes()}
.wrap {{ max-width: 1240px; margin: 0 auto; padding: 24px 16px 60px; }}
h1 {{ font-family: Futura, sans-serif; font-weight: 500; letter-spacing: .18em; font-size: 28px; margin: 0 0 4px; }}
h2 {{ font-size: 18px; margin: 30px 0 4px; }}
.lede {{ color: var(--muted); margin: 0 0 18px; max-width: 800px; }}
.grid {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: 22px 18px; }}
.cell {{ display: flex; flex-direction: column; align-items: center; }}
.frame {{ width: {W * 0.66 + 4:.0f}px; height: {H * 0.66 + 4:.0f}px; border-radius: 16px; overflow: hidden; border: 2px solid #111; }}
.frame .device {{ transform: scale(.66); transform-origin: top left; }}
.cap {{ font-size: 13px; font-weight: 600; margin-top: 8px; text-align: center; }}
.when {{ font-size: 11.5px; color: var(--muted); text-align: center; }}
"""


def search_bar(key: str | None) -> str:
    """Browse's floating search bar above the tab bar (owner, 2026-10-21):
    on a holiday, its colours turn round the pill's edge with a soft glow."""
    cols = palette(key) if key else None
    rim = (f'<div class="srim" style="background:{conic(cols)}"></div>' if cols else "")
    glow = f"box-shadow: 0 0 18px 2px {cols[0]}aa;" if cols else "box-shadow: 0 4px 10px rgba(0,0,0,.25);"
    return f'''<div class="device">
      <div class="content"><div class="card"></div><div class="row"><i></i><i></i><i></i></div></div>
      <div class="sbar" style="{glow}">{rim}<span class="sglass">⌕</span><span class="sph">Search Marracat</span></div>
      {bar(key, "B")[bar(key, "B").index('<div class="bar">'):]}'''


STYLES = {"A": "Ribbon", "B": "Pill", "C": "Glow"}
STYLE_TEXT = {
    "A": "A thin band of the day's colours flows along the top edge. The quietest.",
    "B": "The selected tab's pill fills with the colours and leaves a short trail when it moves. Recommended: it lives where the eye already is.",
    "C": "The outline is the day's colours, turning slowly, with a soft glow under the bar. The loudest.",
}


def cell(key: str | None, style: str, cap: str, when: str = "") -> str:
    return (f'<div class="cell"><div class="frame">{bar(key, style)}</div><div class="cap">{html.escape(cap)}</div>'
            f'<div class="when">{html.escape(when)}</div></div>')


def main() -> None:
    out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "~/Downloads/Marracat-holiday-themes").expanduser()
    out.mkdir(parents=True, exist_ok=True)
    byk = {h["key"]: h for h in HOLIDAYS}
    order = sorted(HOLIDAYS, key=lambda h: next_on(h["date"]))
    styles = "".join(cell(k, s, f"{s} · {STYLES[s]} · {byk[k]['name']}", STYLE_TEXT[s])
                     for s in "ABC" for k in ("kwanzaa", "juneteenth"))
    every = cell(None, "B", "Every other day", "Today's tab bar") + "".join(
        cell(h["key"], "B", h["name"], f"{h['rule']} · next {fmt(next_on(h['date']))}") for h in order)
    page = f'''<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Marracat Tab Bar</title>
<style>{css()}</style></head><body><div class="wrap"><h1>MARRACAT · TAB BAR</h1>
<p class="lede">The floating tab bar in each holiday's colours. The demo taps a new tab every {STEP} s so the movement shows.
In the app the colour moves for a few seconds after opening and after each tap, then rests (it saves battery), and it stays still with Reduce Motion on.</p>
<h2>Three styles</h2><div class="grid">{styles}</div>
<h2>Style B on every holiday</h2><div class="grid">{every}</div></div></body></html>'''
    (out / "tab-bar.html").write_text(page)
    print(out / "tab-bar.html")
    videos(out, order)


def videos(out: pathlib.Path, order: list[dict]) -> None:
    ffmpeg = shutil.which("ffmpeg")
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print("no Playwright: skipped the videos")
        return
    if not ffmpeg:
        print("no ffmpeg: skipped the videos")
        return
    vdir = out / "tab-bar-videos"
    tmp = vdir / ".raw"
    tmp.mkdir(parents=True, exist_ok=True)
    jobs = [(f"style-{s}-{STYLES[s].lower()}-{k}", k, s) for s in "ABC" for k in ("kwanzaa", "juneteenth")]
    jobs += [("B-00-everyday", None, "B")] + [(f"B-{i + 1:02d}-{h['key']}", h["key"], "B") for i, h in enumerate(order)]
    with sync_playwright() as p:
        browser = p.chromium.launch()
        for name, key, style in jobs:
            src = tmp / f"{name}.html"
            src.write_text(f'<!doctype html><html><head><meta charset="utf-8"><style>{css()}</style></head><body>{bar(key, style)}</body></html>')
            ctx = browser.new_context(viewport={"width": W, "height": H}, device_scale_factor=2,
                                      record_video_dir=str(tmp), record_video_size={"width": W * 2, "height": H * 2})
            pg = ctx.new_page()
            pg.goto(src.as_uri())
            pg.wait_for_timeout(int((LOOP + 0.4) * 1000))
            raw = pg.video.path()
            ctx.close()
            subprocess.run([ffmpeg, "-y", "-loglevel", "error", "-ss", "0.4", "-i", raw, "-t", f"{LOOP:.2f}",
                            "-vf", f"scale={W * 2}:{H * 2},fps=30", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                            "-movflags", "+faststart", str(vdir / f"{name}.mp4")], check=True)
        browser.close()
    shutil.rmtree(tmp)
    print(f"{len(jobs)} videos in {vdir}")


if __name__ == "__main__":
    main()
