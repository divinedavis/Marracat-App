#!/usr/bin/env python3
"""How each In-App Event would look on the App Store (owner, 2026-10-20), and
its art at Apple's sizes.

For every holiday, commemoration and the two standing events:
  - the event card as it shows in search, Today and the product page: the
    art with Apple's text over its foot (date, name, short description) and
    the app's row (icon, name, Get) under it;
  - the event's details page, as a phone screen;
  - the art itself: card 3840x2160 and details 2160x3840 (the sizes the
    event scripts upload), in the day's colours behind a white MARRACAT.

The App Store icon on the card stays the everyday one: the listing's icon
changes only with a new version.

    python3 scripts/holiday_app_store_events.py [OUT_DIR]
"""
from __future__ import annotations

import datetime as dt
import html
import pathlib
import shutil
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from holiday_theme_examples import (EXTRA_EVENTS, HOLIDAYS, ICON_BANDS, ICON_PATTERN, INK, icon_bg,  # noqa: E402
                                    icon_type, next_on, pattern_css)

ROOT = pathlib.Path(__file__).resolve().parent.parent
TODAY_ICON = ROOT / "Marracat/Assets.xcassets/AppIcon.appiconset/icon-1024.png"

# The standing events have no holiday of their own: dates and colours here.
ICON_BANDS.setdefault("new-brands", [("#0E7C7B", 1), (INK, 2), ("#C9A227", 1)])
ICON_BANDS.setdefault("spotlight", [("#3A3A3A", 1), (INK, 2), ("#3A3A3A", 1)])
EXTRA_DATES = {"new-brands": (dt.date(2026, 10, 27), dt.date(2026, 11, 19), "NEW BRANDS"),
               "spotlight": (dt.date(2026, 11, 2), dt.date(2026, 11, 8), "BRAND SPOTLIGHT")}


def events() -> list[dict]:
    out = []
    for h in HOLIDAYS:
        d = next_on(h["date"])
        w = h["event"].get("window", (0, 0))
        out.append(dict(key=h["key"], what=h["name"], kind=h["kind"], line=h["line"], e=h["event"],
                        start=d + dt.timedelta(days=w[0]), end=d + dt.timedelta(days=w[1])))
    for x in EXTRA_EVENTS:
        s, e, line = EXTRA_DATES[x["key"]]
        out.append(dict(key=x["key"], what=x["name"], kind=x["rule"], line=line, e=x["event"], start=s, end=e))
    return sorted(out, key=lambda v: v["start"])


def span(a: dt.date, b: dt.date) -> str:
    if a == b:
        return a.strftime("%b %-d").upper()
    if a.month == b.month:
        return f"{a:%b %-d} – {b:%-d}".upper()
    return f"{a:%b %-d} – {b:%b %-d}".upper()


def art_bands(key: str, reach: float) -> tuple[str, float]:
    """The day's bands squeezed into the top `reach` of the art, the last
    colour running on under Apple's text, and where the dark middle band's
    centre lands (the word sits there, as on the icon)."""
    if key in ICON_PATTERN:
        return pattern_css(ICON_PATTERN[key], 0.25 * reach, 0.75 * reach), 0.5 * reach
    bands = ICON_BANDS[key]
    total, at, stops, mid = sum(w for _, w in bands), 0, [], 0.5
    for c, w in bands:
        a, b = at / total, (at + w) / total
        if a <= 0.5 < b:
            mid = (a + b) / 2
        stops.append(f"{c} {a * reach * 100:.2f}% {(b if b < 1 else 1 / reach) * reach * 100:.2f}%")
        at += w
    return f"linear-gradient(180deg, {', '.join(stops)})", mid * reach


def art(key: str, line: str, w: float, h: float, reach: float) -> str:
    """The art: the day's bands, MARRACAT at the icon's proportions of the
    width on the dark band, the day's line under it, all above the foot
    where Apple lays its text."""
    size = min(w, h) * (0.62 if w > h else 0.9)
    bg, mid = art_bands(key, reach)
    cap = size * 0.106   # the word's letters, as on the icon
    return (f'<div class="art" style="width:{w:.0f}px;height:{h:.0f}px;background:{bg}">'
            f'<div class="words" style="top:{h * mid - cap * 0.95:.0f}px">'
            f'<div class="wm" style="{icon_type(size)}">MARRACAT</div>'
            f'<div class="line" style="font-size:{size * 0.045:.1f}px;letter-spacing:{size * 0.014:.1f}px;margin-top:{size * 0.03:.0f}px">{html.escape(line)}</div>'
            f'</div></div>')


def card(v: dict, width: int = 360) -> str:
    e = v["e"]
    h = width * 9 / 16
    return f'''<div class="card" style="width:{width}px">
      <div class="media">{art(v["key"], v["line"], width, h, 0.62)}
        <div class="shade"></div>
        <div class="over"><div class="when">{html.escape(e["badge"].upper())} · {span(v["start"], v["end"])}</div>
          <div class="ename">{html.escape(e["name"])}</div><div class="eshort">{html.escape(e["short"])}</div></div></div>
      <div class="approw"><img src="event-art/app-icon.png" alt=""><div><div class="an">Marracat</div><div class="as">Shopping</div></div>
        <span class="get">Get</span></div></div>'''


def details(v: dict) -> str:
    e = v["e"]
    W = 300
    return f'''<div class="phone"><div class="screen">
      <div class="dmedia">{art(v["key"], v["line"], W, W * 16 / 9 * 0.62, 0.62)}<div class="dshade"></div>
        <div class="close">✕</div>
        <div class="dover"><div class="when">{html.escape(e["badge"].upper())}</div>
          <div class="dname">{html.escape(e["name"])}</div><div class="dshort">{html.escape(e["short"])}</div></div></div>
      <div class="dbody">
        <div class="approw"><img src="event-art/app-icon.png" alt=""><div><div class="an">Marracat</div><div class="as">Shopping</div></div><span class="get">Get</span></div>
        <p class="dlong">{html.escape(e["long"])}</p>
        <div class="dates"><div><b>Starts</b><span>{v["start"]:%a, %b %-d, %Y}</span></div><div><b>Ends</b><span>{v["end"]:%a, %b %-d, %Y}</span></div></div>
      </div></div></div>'''


CSS = """
:root { --ink:#0A0A0A; --muted:#6b6b6b; --line:#e6e6e6; }
* { box-sizing: border-box; }
body { margin: 0; background: #fff; color: var(--ink); font-family: -apple-system, 'Helvetica Neue', sans-serif; }
.wrap { max-width: 1100px; margin: 0 auto; padding: 24px 16px 60px; }
h1 { font-family: Futura, sans-serif; font-weight: 500; letter-spacing: .18em; font-size: 28px; margin: 0 0 4px; }
.lede { color: var(--muted); margin: 0 0 8px; max-width: 820px; }
section { border-top: 1px solid var(--line); padding: 22px 0 10px; break-inside: avoid; }
h2 { font-size: 19px; margin: 0 0 2px; } .sub { color: var(--muted); font-size: 13px; margin-bottom: 14px; }
.row { display: flex; gap: 28px; flex-wrap: wrap; align-items: flex-start; }
.lbl { font-size: 11px; color: var(--muted); letter-spacing: .05em; margin-bottom: 6px; text-transform: uppercase; }
.art { position: relative; overflow: hidden; }
.words { position: absolute; left: 0; right: 0; display: flex; flex-direction: column; align-items: center; }
.wm { font-family: Futura, sans-serif; font-weight: 500; color: #fff; text-shadow: 0 1px 3px rgba(0,0,0,.2); white-space: nowrap; }
.line { font-family: Futura, sans-serif; color: #fff; opacity: .95; text-align: center; white-space: nowrap; }
.card { border-radius: 16px; overflow: hidden; box-shadow: 0 4px 18px rgba(0,0,0,.14); background: #fff; }
.media { position: relative; }
.shade { position: absolute; inset: 40% 0 0 0; background: linear-gradient(transparent, rgba(0,0,0,.62)); }
.over { position: absolute; left: 14px; right: 14px; bottom: 11px; color: #fff; }
.when { font-size: 10.5px; font-weight: 700; letter-spacing: .04em; opacity: .85; }
.ename { font-size: 19px; font-weight: 700; line-height: 1.15; margin-top: 2px; }
.eshort { font-size: 13px; opacity: .9; margin-top: 1px; }
.approw { display: flex; align-items: center; gap: 10px; padding: 10px 14px; }
.approw img { width: 34px; height: 34px; border-radius: 8px; border: 1px solid #e3e3e3; }
.an { font-size: 14px; font-weight: 600; } .as { font-size: 12px; color: var(--muted); }
.get { margin-left: auto; background: #eef0f4; color: #0a64d6; font-weight: 700; font-size: 14px; border-radius: 14px; padding: 4px 18px; }
.phone { width: 314px; border-radius: 40px; background: #111; padding: 7px; }
.screen { width: 300px; height: 620px; border-radius: 34px; overflow: hidden; background: #fff; position: relative; }
.dmedia { position: relative; }
.dshade { position: absolute; inset: 45% 0 0 0; background: linear-gradient(transparent, rgba(0,0,0,.66)); }
.close { position: absolute; top: 14px; right: 14px; width: 28px; height: 28px; border-radius: 50%; background: rgba(0,0,0,.35); color: #fff; font-size: 13px; display: flex; align-items: center; justify-content: center; }
.dover { position: absolute; left: 16px; right: 16px; bottom: 14px; color: #fff; }
.dname { font-size: 24px; font-weight: 800; line-height: 1.1; margin-top: 3px; } .dshort { font-size: 14px; opacity: .92; margin-top: 3px; }
.dbody { padding: 4px 4px; }
.dlong { font-size: 13.5px; line-height: 1.4; margin: 6px 14px 12px; }
.dates { display: flex; gap: 10px; margin: 0 14px; }
.dates div { flex: 1; background: #f4f4f6; border-radius: 10px; padding: 8px 10px; font-size: 12px; display: flex; flex-direction: column; }
.dates b { font-size: 11px; color: var(--muted); font-weight: 600; text-transform: uppercase; letter-spacing: .04em; }
.files { font-size: 12px; color: var(--muted); margin-top: 10px; }
"""


def main() -> None:
    out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "~/Downloads/Marracat-holiday-themes").expanduser()
    adir = out / "event-art"
    adir.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(TODAY_ICON, adir / "app-icon.png")
    evs = events()
    secs = "".join(f'''<section><h2>{html.escape(v["what"])}</h2>
      <div class="sub">{html.escape(v["kind"])} · event runs {v["start"]:%a %b %-d} – {v["end"]:%a %b %-d, %Y} · {html.escape(v["e"]["link"])}</div>
      <div class="row"><div><div class="lbl">Card · search, Today, product page</div>{card(v)}
        <div class="files">Art: event-art/{i:02d}-{v["key"]}-card-3840x2160.png · {v["key"]}-details-2160x3840.png</div></div>
        <div><div class="lbl">Details page</div>{details(v)}</div></div></section>'''
                   for i, v in enumerate(evs, 1))
    page = out / "app-store-events.html"
    page.write_text(f'''<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Marracat App Store Events</title>
<style>{CSS}</style></head><body><div class="wrap"><h1>MARRACAT · EVENTS</h1>
<p class="lede">Every In-App Event as it would look on the App Store, in calendar order: the card (Apple lays the date, name and short description over the art's foot) and the details page a tap opens. The App Store icon stays the everyday one; only a new version can change it. Art at Apple's sizes is in event-art/.</p>
{secs}</div></body></html>''')
    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        b = p.chromium.launch()
        pg = b.new_page(viewport={"width": 3840, "height": 2160})
        for i, v in enumerate(evs, 1):
            for kind, (w, h, y) in {"card": (3840, 2160, 0.62), "details": (2160, 3840, 0.62)}.items():
                pg.set_viewport_size({"width": w, "height": h})
                pg.set_content(f'<!doctype html><html><head><style>{CSS} body{{margin:0}}</style></head><body>{art(v["key"], v["line"], w, h, y)}</body></html>')
                pg.screenshot(path=str(adir / f"{i:02d}-{v['key']}-{kind}-{w}x{h}.png"))
        sheet = b.new_page(viewport={"width": 1100, "height": 900}, device_scale_factor=2)
        sheet.goto(page.as_uri())
        sheet.wait_for_timeout(300)
        sheet.pdf(path=str(out / "Marracat App Store events.pdf"), width="11in", height="8.5in", print_background=True,
                  margin={"top": "0.3in", "bottom": "0.3in", "left": "0.3in", "right": "0.3in"})
        b.close()
    print(page)
    print(f"{len(evs)} events, {len(evs) * 2} art files in {adir}")


if __name__ == "__main__":
    main()
