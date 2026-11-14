#!/usr/bin/env python3
"""One card per style, a dot per colour (owner, 2026-10-10: Fear of God lists
the same hoodie as a separate product for every colour, so a grid shows the
same photo six times).

Groups a brand's products that differ only by colour and writes, on every
member of a group:

    product["group"]  = "fear-of-god:3f9a1c2e"   brand id + 8 hex, same for every member
    product["color"]  = "Vintage Black"           the member's colour, as the brand names it
    product["swatch"] = "#23201e"                 a dot colour, when the name has a known colour word

Products in no group carry none of the three.

Two products are colourways of one style when, at the same brand, they have
- the same title once the colour is taken out of it ("Classic Hoodie - Black"
  and "Classic Hoodie - Sand"; Fear of God's titles carry no colour at all and
  the colour is the first option every variant shares: "Vintage Black / XS"),
- the same product type and department, and
- prices within 25% of the group's middle price,
and each has a colour, and no two members share one. Departments where a
"colour" option is really a shade or a scent (makeup, fragrance, food) are
left alone. Groups never cross brands.

    python3 catalog/colorways.py            # rewrite the catalog
    python3 catalog/colorways.py --dry-run  # counts only
"""
import argparse
import hashlib
import json
import pathlib
import re
import statistics
from catalog_io import write_catalog

HERE = pathlib.Path(__file__).resolve().parent
CATALOG = HERE.parent / "Marracat" / "Resources" / "catalog.json"

# Where a product's first shared option is its colour.
APPAREL = {"clothing", "shoes", "bags", "accessories", "luggage", "sports"}
# Where it counts only if it names a colour word (gold/silver jewelry, a grey throw).
COLOURED = APPAREL | {"jewelry", "home", "baby", "pets", "toys", "office"}
MAX_GROUP = 24
PRICE_SPREAD = 0.25

# colour word -> dot colour. Also how a title's colour is recognised.
SWATCH = {
    "black": "#1b1b1b", "onyx": "#1b1b1b", "jet": "#1b1b1b", "ink": "#1f2433",
    "white": "#f7f7f5", "ivory": "#f3eedf", "cream": "#efe6d2", "ecru": "#e8dfc8", "bone": "#e6dccb", "off-white": "#f1ede4",
    "grey": "#8d8f91", "gray": "#8d8f91", "heather": "#9fa1a3", "charcoal": "#3d3f42", "slate": "#5d6670", "iron": "#5a5c5e",
    "silver": "#c4c6c8", "smoke": "#7d7f80", "ash": "#b2b1ad", "graphite": "#4a4b4d",
    "red": "#b3261e", "burgundy": "#6d1a2a", "maroon": "#6b1f24", "wine": "#5e1a2b", "cherry": "#9b1b30", "crimson": "#9e1b32",
    "rust": "#a4462a", "brick": "#9c4632",
    "pink": "#e9a1b5", "blush": "#e8c0bb", "rose": "#d7899a", "fuchsia": "#c2185b", "magenta": "#c2185b", "coral": "#ee7a62",
    "orange": "#e2702a", "peach": "#f3b88f", "apricot": "#f0b27a", "terracotta": "#b85c3c",
    "yellow": "#efc93a", "mustard": "#c99a2e", "gold": "#c9a54a", "lemon": "#f2df63", "sulphur": "#d8c54b", "butter": "#f1e1a0",
    "green": "#3f7d4a", "olive": "#6b6a3a", "sage": "#9caf88", "mint": "#a8d8bf", "forest": "#2f4f37", "emerald": "#1f7a55",
    "khaki": "#a99a6b", "moss": "#6f7a45", "lime": "#a5c84a", "army": "#4f5434", "hunter": "#355e3b",
    "blue": "#2f5fa7", "navy": "#1f2a44", "royal": "#2747a0", "cobalt": "#2747a0", "sky": "#8cbbe0", "denim": "#4a6589",
    "indigo": "#34407a", "teal": "#2a7a7a", "turquoise": "#3cb4b0", "aqua": "#6fd0d0", "sea": "#3f6f86", "powder": "#b8cfe3",
    "purple": "#6a3f8f", "lavender": "#b9a6d6", "lilac": "#c3a8d1", "plum": "#5d2a4c", "violet": "#6b4aa0", "mauve": "#a7848f",
    "brown": "#6b4a32", "chocolate": "#4a2f22", "mocha": "#6b5040", "espresso": "#3b2a22", "coffee": "#5b4033", "cocoa": "#5b3f32",
    "tan": "#c3a27c", "camel": "#b8885a", "beige": "#d9c7a7", "sand": "#d4c3a0", "stone": "#bfb5a3", "taupe": "#8f8274",
    "oat": "#d8ccb3", "oatmeal": "#d8ccb3", "dune": "#cdb892", "clay": "#b77a5c", "cognac": "#9a5a2e", "caramel": "#b8743a",
    "chestnut": "#7a4a2e", "natural": "#e3d7c0", "nude": "#d8b49a", "seal": "#5b5249", "bronze": "#8c6a3c", "copper": "#b06b3c",
    "multi": None, "multicolor": None, "print": None, "tie-dye": None, "camo": "#5c5a3a", "leopard": None, "clear": None,
}
COLOUR_WORD = re.compile(r"\b(" + "|".join(sorted(map(re.escape, SWATCH), key=len, reverse=True)) + r")\b", re.I)
SIZE = re.compile(
    r"^(?:\d*x*[sml]|xxs|xs|s|m|l|xl|\d?xl|one size|os|o/s|osfa|small|medium|large|extra large|petite|tall|regular|"
    r"\d+(?:\.\d+)?(?:\s*(?:/\s*\d+)?)?(?:\s*(?:oz|ml|g|kg|lb|lbs|in|inch|cm|mm|ft|pack|pk|ct|count|w|l|us|uk|eu|m|t|y|yr|yrs|mo|months?))?|"
    r"\d+[-/]\d+(?:\s*\w+)?|\d+\s*x\s*\d+.*|[a-z]{0,2}\d+[a-z]{0,2}|w\d+\s*l\d+|default title)$", re.I)


def norm(s):
    return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9]+", " ", (s or "").lower())).strip()


def shared_option(p):
    """The option part every variant has in the same position and value, when
    it is the first part and isn't a size: "Vintage Black / XS", "Vintage
    Black / S" -> "Vintage Black"."""
    titles = [(v.get("title") or "").strip() for v in p.get("variants") or []]
    titles = [t for t in titles if t and t.lower() != "default title"]
    if not titles:
        return None
    firsts = {t.split(" / ")[0].strip() for t in titles}
    if len(firsts) != 1:
        return None
    first = firsts.pop()
    if not first or SIZE.match(first) or len(first) > 40 or not re.search(r"[a-z]", first, re.I):
        return None
    # A one-part variant title must be the only variant: "Black" alone is a
    # colour, while ten variants all titled "Black" can't happen.
    return first


def title_colour(title):
    """("Classic Hoodie", "Black") for "Classic Hoodie - Black" / "Classic
    Hoodie | Black" / "Classic Hoodie (Black)", or (None, None)."""
    m = re.match(r"^(.*\S)\s*(?:[-–—|/,]\s*|\()([^-–—|/,()]{2,30})\)?\s*$", title or "")
    if m and COLOUR_WORD.search(m.group(2)):
        return m.group(1), m.group(2).strip()
    return None, None


def colour_of(p):
    """(colour name, title without it) or (None, None)."""
    cat = p.get("category")
    if cat not in COLOURED:
        return None, None
    title = p.get("title") or ""
    opt = shared_option(p)
    if opt and (cat in APPAREL or COLOUR_WORD.search(opt)):
        base = re.sub(re.escape(opt), " ", title, flags=re.I)
        return opt, base
    base, c = title_colour(title)
    if c:
        return c, base
    return None, None


def swatch(colour):
    words = COLOUR_WORD.findall(colour or "")
    # The last colour word is the colour ("Washed Vintage Black", "Iron Grey Heather" -> heather is a texture; prefer the
    # last word that isn't a texture).
    for w in reversed(words):
        w = w.lower()
        if w in ("heather",) and len(words) > 1:
            continue
        return SWATCH.get(w)
    return None


def group_products(products):
    """Sets group/color/swatch on members; returns the groups as lists."""
    keyed = {}
    for p in products:
        for k in ("group", "color", "swatch"):
            p.pop(k, None)
        colour, base = colour_of(p)
        if not colour:
            continue
        b = norm(base)
        if not b:
            continue
        key = (p["brand"], b, norm(p.get("product_type")), p.get("category"), p.get("currency") or "USD")
        keyed.setdefault(key, []).append((p, colour))
    groups = []
    for key, members in keyed.items():
        if len(members) < 2:
            continue
        prices = [float(p.get("price") or 0) for p, _ in members]
        mid = statistics.median(prices)
        members = [(p, c) for p, c in members if mid > 0 and abs(float(p.get("price") or 0) - mid) <= PRICE_SPREAD * mid]
        # One member per colour: in stock first, then best seller.
        members.sort(key=lambda m: (not m[0].get("available"), m[0].get("best_rank", 999) if m[0].get("best_rank") is not None else 999))
        seen, kept = set(), []
        for p, c in members:
            if norm(c) not in seen:
                seen.add(norm(c))
                kept.append((p, c))
        if not 2 <= len(kept) <= MAX_GROUP:
            continue
        gid = f"{key[0]}:{hashlib.sha1('|'.join(key).encode()).hexdigest()[:8]}"
        for p, c in kept:
            c = c.strip()
            # "NAVY" / "black" -> "Navy" / "Black"; "Vintage Black" stays.
            p["group"], p["color"] = gid, c.title() if c.isupper() or c.islower() else c
            s = swatch(c)
            if s:
                p["swatch"] = s
        groups.append([p for p, _ in kept])
    return groups


def collapsed_count(products, brand=None):
    """Cards on screen before and after showing one card per group."""
    ps = [p for p in products if brand is None or p["brand"] == brand]
    return len(ps), len({p.get("group") or p["id"] for p in ps})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    catalog = json.loads(CATALOG.read_text())
    products = catalog["products"]
    groups = group_products(products)
    before, after = collapsed_count(products)
    fb, fa = collapsed_count(products, "fear-of-god")
    print(f"colorways: {len(groups)} groups, {sum(map(len, groups))} products; "
          f"cards {before} -> {after} (-{before - after}); fear-of-god {fb} -> {fa}")
    if not args.dry_run:
        write_catalog(CATALOG, catalog)


if __name__ == "__main__":
    main()
