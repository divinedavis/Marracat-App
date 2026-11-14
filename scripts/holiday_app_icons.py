#!/usr/bin/env python3
"""Holiday app icons for the owner (2026-10-20): the day's colours behind a
white MARRACAT, no bar. Writes a sheet of every icon as it looks on the Home
Screen, beside today's icon, and each icon at 1024 px (square: iOS rounds it).

    python3 scripts/holiday_app_icons.py [OUT_DIR]
    python3 scripts/holiday_app_icons.py --xcassets   # the app's AppIcon-<id> sets

The --xcassets form writes Marracat/Assets.xcassets/AppIcon-<id>.appiconset
for every holiday in holidays.json (opaque 1024 px, as App Store icons must be).

Needs Playwright (the sheet and 1024 px files are rendered in Chromium).
"""
from __future__ import annotations

import html
import pathlib
import shutil
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from holiday_theme_examples import HOLIDAYS, icon_bg, icon_ink, icon_type, next_on  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
TODAY_ICON = ROOT / "Marracat/Assets.xcassets/AppIcon.appiconset/icon-1024.png"

CSS = """
:root { --ink:#0A0A0A; --muted:#6b6b6b; }
* { box-sizing: border-box; }
body { margin: 0; background: #fff; color: var(--ink); font-family: -apple-system, 'Helvetica Neue', sans-serif; }
.wrap { max-width: 1100px; margin: 0 auto; padding: 28px 16px 40px; }
h1 { font-family: Futura, sans-serif; font-weight: 500; letter-spacing: .18em; font-size: 26px; margin: 0 0 4px; }
.lede { color: var(--muted); margin: 0 0 24px; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 26px 14px; }
.cell { display: flex; flex-direction: column; align-items: center; text-align: center; }
.icon { width: 120px; height: 120px; border-radius: 26.8px; overflow: hidden; display: flex; align-items: center; justify-content: center;
        box-shadow: 0 1px 4px rgba(0,0,0,.2); }
.icon img { width: 100%; height: 100%; }
.wm { font-family: Futura, sans-serif; font-weight: 500; color: #fff; text-shadow: 0 1px 2px rgba(0,0,0,.25); }
.name { font-size: 13px; font-weight: 600; margin-top: 9px; }
.when { font-size: 11.5px; color: var(--muted); }
.big { width: 1024px; height: 1024px; display: flex; align-items: center; justify-content: center; }
.big .wm { text-shadow: 0 4px 10px rgba(0,0,0,.22); }
"""


def xcassets() -> None:
    import json
    from PIL import Image
    from playwright.sync_api import sync_playwright
    doc = json.loads((ROOT / "Marracat/Resources/holidays.json").read_text())
    assets = ROOT / "Marracat/Assets.xcassets"
    with sync_playwright() as p:
        b = p.chromium.launch()
        pg = b.new_page(viewport={"width": 1024, "height": 1024})
        for h in doc["holidays"]:
            d = assets / f"{h['icon']}.appiconset"
            d.mkdir(exist_ok=True)
            pg.set_content(f'<!doctype html><html><head><style>{CSS} body{{margin:0}}</style></head><body>'
                           f'<div class="big" style="background:{icon_bg(h["id"])}"><div class="wm" style="{icon_type(1024)};color:{icon_ink(h["id"])}">MARRACAT</div></div></body></html>')
            png = d / "icon-1024.png"
            pg.screenshot(path=str(png))
            Image.open(png).convert("RGB").save(png, optimize=True)
            (d / "Contents.json").write_text(json.dumps({
                "images": [{"filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
                "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
        b.close()
    print(f"{len(doc['holidays'])} icon sets in {assets}")


def main() -> None:
    if sys.argv[1:] == ["--xcassets"]:
        xcassets()
        return
    out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "~/Downloads/Marracat-holiday-themes").expanduser()
    idir = out / "app-icons"
    idir.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(TODAY_ICON, idir / "00-everyday-1024.png")
    order = sorted(HOLIDAYS, key=lambda h: next_on(h["date"]))
    cells = ('<div class="cell"><div class="icon"><img src="app-icons/00-everyday-1024.png" alt=""></div>'
             '<div class="name">Every other day</div><div class="when">Today\'s icon</div></div>')
    cells += "".join(
        f'<div class="cell"><div class="icon" style="background:{icon_bg(h["key"])}"><div class="wm" style="{icon_type(120)};color:{icon_ink(h['key'])}">MARRACAT</div></div>'
        f'<div class="name">{html.escape(h["name"])}</div><div class="when">{next_on(h["date"]):%b %-d, %Y}</div></div>'
        for h in order)
    sheet = out / "app-icons.html"
    sheet.write_text(f'''<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Marracat Holiday Icons</title>
<style>{CSS}</style></head><body><div class="wrap"><h1>MARRACAT · ICONS</h1>
<p class="lede">Each holiday's colours behind a white MARRACAT, as on the Home Screen. Full-size files are in app-icons/.</p>
<div class="grid">{cells}</div></div></body></html>''')
    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        b = p.chromium.launch()
        pg = b.new_page(viewport={"width": 1100, "height": 900}, device_scale_factor=2)
        pg.goto(sheet.as_uri())
        pg.wait_for_timeout(300)
        pg.screenshot(path=str(out / "app-icons.png"), full_page=True)
        big = b.new_page(viewport={"width": 1024, "height": 1024})
        for i, h in enumerate(order, 1):
            big.set_content(f'<!doctype html><html><head><style>{CSS} body{{margin:0}}</style></head><body>'
                            f'<div class="big" style="background:{icon_bg(h["key"])}"><div class="wm" style="{icon_type(1024)};color:{icon_ink(h["key"])}">MARRACAT</div></div></body></html>')
            big.screenshot(path=str(idir / f"{i:02d}-{h['key']}-1024.png"))
        b.close()
    print(out / "app-icons.png")


if __name__ == "__main__":
    main()
