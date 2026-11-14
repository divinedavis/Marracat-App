#!/usr/bin/env python3
"""Publish the catalog snapshots the app and the website read.

Three files, because three generations of client read them:

  catalog-v3.json  every product a brand has in stock, without the two fields
                   only a product page needs: the description and the images
                   after the first. A page fills those in from
                   /api/products/:id. Variants stay, because the cart and the
                   checkout read them straight from the catalog. That is 84 MB
                   for 75,000 products, 10 MB over the wire — less than the
                   13 MB that 40,000 full-fat products cost.
  catalog-v2.json  the full shape, for builds that shipped before v3 and read
                   descriptions and variants straight out of the catalog. It
                   stays capped (LEGACY_CAP a brand) so those builds don't
                   suddenly download three times what they used to.
  catalog.json     the same as v2, minus every brand that prices in anything
                   but dollars — the oldest builds hardcode a dollar sign.
"""
import copy
import json
import sys
from pathlib import Path

from catalog_io import write_catalog

# What an older build downloads must not grow because newer builds carry more.
# 80 a brand is what those builds shipped with and were measured against: at
# 200 the file reached 128 MB of full-fat JSON, which is a heavier launch for
# 1.1 than 1.1 was ever tested with.
LEGACY_CAP = 80
# The claim phrases Product.isCertifiedOrganic looks for. The badge is worked
# out here because the description it reads is what compacting removes.
ORGANIC_CLAIMS = ("gots certified organic", "usda organic",
                  "usda certified organic", "certified usda organic")


def option_words(variants):
    """Every part of every variant title, once. "Black / Large" -> black, large.

    The app filters by size and colour off these. They travel instead of the
    variants themselves, which were 56% of the catalog: a few short words a
    product against a list of objects carrying an id, a price and a compare-at
    for every combination a store sells.
    """
    words = []
    for v in variants:
        title = (v.get("title") or "").strip()
        if not title or title == "Default Title":
            continue
        for part in title.split("/"):
            part = part.strip().lower()
            if part and part not in words:
                words.append(part)
    return words[:24]


def compact_product(p):
    # option_names travel with the variants, which a product page fetches.
    row = {k: v for k, v in p.items() if k not in ("description", "variants", "tile_image", "option_names")}
    if p.get("images"):
        # The one photo a grid shows is the tile (catalog/photo_roles.py), so
        # tile_image is spent here; hero_image still indexes the full images.
        tile = p.get("tile_image") or 0
        row["images"] = [p["images"][tile if 0 <= tile < len(p["images"]) else 0]]
    variants = p.get("variants") or []
    # One variant means one thing to buy, so it can go straight in a basket
    # from a grid. Anything with choices is chosen on its own page, which
    # fetches them.
    if len(variants) == 1:
        row["variants"] = variants
    else:
        words = option_words(variants)
        if words:
            row["opts"] = words
    text = " ".join([p.get("title") or "", p.get("description") or "", *(p.get("tags") or [])]).lower()
    if any(claim in text for claim in ORGANIC_CLAIMS):
        row["organic"] = True
    return row


def compact_catalog(catalog):
    snapshot = {k: v for k, v in catalog.items() if k != "products"}
    snapshot["products"] = [compact_product(p) for p in catalog["products"]]
    return snapshot


def capped_catalog(catalog, cap=LEGACY_CAP):
    """The full shape, but no deeper into any one brand than older builds saw."""
    kept, seen = [], {}
    for p in catalog["products"]:
        n = seen.get(p["brand"], 0)
        if n >= cap:
            continue
        seen[p["brand"]] = n + 1
        kept.append(p)
    trimmed = {k: v for k, v in catalog.items() if k != "products"}
    trimmed["products"] = kept
    return trimmed


def legacy_catalog(catalog):
    legacy = copy.deepcopy(catalog)
    legacy['products'] = [p for p in legacy['products'] if p.get('currency', 'USD') == 'USD']
    # Exclude foreign-currency brands from old clients, which hardcode dollars.
    legacy['brands'] = [b for b in legacy['brands'] if b.get('currency', 'USD') == 'USD']
    brand_ids = {b['id'] for b in legacy['brands']}
    legacy['products'] = [p for p in legacy['products'] if p['brand'] in brand_ids]
    subs = {f"{p['category']}:{s}" for p in legacy['products'] for s in p['subs']}
    legacy['subcategories'] = [s for s in legacy['subcategories'] if s['id'] in subs]
    return legacy


def main():
    source, destination = map(Path, sys.argv[1:])
    catalog = json.loads(source.read_text())
    destination.mkdir(parents=True, exist_ok=True)
    capped = capped_catalog(catalog)
    # One snapshot built at a time, each written and dropped before the next:
    # all three at once (plus each one's text) peaked at 5.4 GB (2026-10-18).
    for filename, make in [('catalog-v3.json', lambda: compact_catalog(catalog)),
                           ('catalog-v2.json', lambda: capped),
                           ('catalog.json', lambda: legacy_catalog(capped))]:
        snapshot = make()
        write_catalog(destination / filename, snapshot)
        print(f"  {filename}: {len(snapshot['products'])} products, {(destination / filename).stat().st_size / 1e6:.0f} MB")
        del snapshot


if __name__ == '__main__':
    main()
