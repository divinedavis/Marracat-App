#!/usr/bin/env python3
"""Screenshots for Marracat's custom product pages and the A/B treatment
(owner, 2026-10-11), in the live gallery's look (make_gallery.py: one soft
landscape across the panels, Didot title-case headline, the real screen in
an outlined card).

Captures come from AppStoreTourUITests.testCustomPageTour into raw-cpp/.
Output: cpp-<slug>/NN-<capture>.png here and a copy under
~/Downloads/ASC-creative-assets/marracat/cpp-<slug>/screens/ for review.

    ~/.venvs/marracat/bin/python app-store/gallery/make_cpp_gallery.py
"""
import pathlib
import shutil

from PIL import Image

import make_gallery as g

HERE = pathlib.Path(__file__).resolve().parent
RAW = HERE / "raw-cpp"
DOWNLOADS = pathlib.Path.home() / "Downloads/ASC-creative-assets/marracat"

# Public copy: no "independent", no prices or price claims in headlines.
PAGES = {
    "beauty": [
        ("cpp-bodybutter-results", "Body Care From\nIndependent Brands"),
        ("cpp-skincare-aisles",    "Shop Every\nSkincare Aisle"),
        ("cpp-shampoo-results",    "Hair Care\nMade for You"),
        ("cpp-home",               "Independent Brands\nAll in One Place"),
        ("cpp-cart",               "Many Brands\nOne Cart"),
    ],
    "gifts": [
        ("cpp-necklace-detail",    "Jewelry They'll\nWear Every Day"),
        ("cpp-giftset-results",    "Gift Sets\nReady to Give"),
        ("cpp-candle-detail",      "Gifts for\nEvery Home"),
        ("cpp-home",               "Independent Brands\nAll in One Place"),
        ("cpp-cart",               "Many Brands\nOne Cart"),
    ],
    "deals": [
        ("cpp-deals",              "Deals From\nIndependent Brands"),
        ("cpp-price-alerts",       "Track Any\nPrice"),
        ("cpp-brand-sale-alerts",  "Follow a Brand's\nSales"),
        ("cpp-home",               "Independent Brands\nAll in One Place"),
        ("cpp-cart",               "Many Brands\nOne Cart"),
    ],
    # The A/B treatment's new first panel; the live eight follow it.
    "experiment": [
        ("cpp-deals",              "Deals From\nIndependent Brands"),
    ],
}


def main() -> None:
    W, H = g.W, g.H
    for slug, panels in PAGES.items():
        out = HERE / f"cpp-{slug}"
        out.mkdir(exist_ok=True)
        for old in out.glob("*.png"):
            old.unlink()
        scene = g.landscape(W * len(panels), H)
        dl = DOWNLOADS / f"cpp-{slug}" / "screens"
        if dl.exists():
            shutil.rmtree(dl)
        dl.mkdir(parents=True)
        for i, (key, headline) in enumerate(panels, start=1):
            bg = g.grain(scene.crop(((i - 1) * W, 0, i * W, H)), i)
            img = g.panel(bg, Image.open(RAW / f"{key}.png").convert("RGB"), headline)
            assert img.size == (W, H) and img.mode == "RGB"
            p = out / f"{i:02d}-{key.removeprefix('cpp-')}.png"
            img.save(p, optimize=True)
            shutil.copy(p, dl / p.name)
            print("  ✓", p.relative_to(HERE))


if __name__ == "__main__":
    main()
