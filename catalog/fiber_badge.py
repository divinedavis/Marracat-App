#!/usr/bin/env python3
"""Award the Marracat Natural Fiber badge.

The rules are in catalog/fiber_standard.md. A garment earns it when its own
listing states a fibre composition that is at least 90% natural fibre: cotton,
linen (flax), hemp, ramie, wool (merino, alpaca, mohair, cashmere, camel,
yak, angora) or silk. A tier, "Marracat Natural Fiber · Organic", goes to a
passing garment whose listing says the fibre is organic or GOTS certified.

Viscose, rayon, modal, lyocell (Tencel), cupro, acetate and "bamboo" fabric
are regenerated cellulose: plant pulp dissolved in chemicals and re-spun.
They're not natural fibres here, even though they start as plants.

The composition must be stated: percentages ("95% cotton, 5% elastane"),
"100% linen", or one fibre named as the material ("Fabric: organic cotton").
A listing that doesn't say what it's made of is never badged, and one that
says the fibre content varies by colour isn't either.

Clothing only. Shoes are mostly leather and rubber, and accessories mix
metals, plastics and textiles, so neither is judged. Read from each product's
own title, description, tags and options; the catalog already carries them,
so nothing is fetched. Sets product["fiber"] = "natural" or "organic" on
passing products (absent otherwise) and writes catalog/fiber_report.md.

The composition parser here is shared with catalog/fabric_badge.py.

Usage:
    python3 catalog/fiber_badge.py
    python3 catalog/fiber_badge.py --explain <product-id>
    python3 catalog/fiber_badge.py --report-only     # don't rewrite the catalog
"""
import argparse
import html
import json
import pathlib
import re
import sys
import eligibility as el  # noqa: E402
from catalog_io import write_catalog

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Marracat" / "Resources" / "catalog.json"
REPORT = ROOT / "catalog" / "fiber_report.md"

THRESHOLD = 90  # percent natural fibre

# Fibre names -> (canonical name, class). Longest names first in the regex.
FIBRES = {
    # natural
    "organic cotton": ("organic cotton", "natural"), "pima cotton": ("cotton", "natural"),
    "supima cotton": ("cotton", "natural"), "egyptian cotton": ("cotton", "natural"),
    "cotton": ("cotton", "natural"), "linen": ("linen", "natural"), "flax": ("linen", "natural"),
    "organic linen": ("organic linen", "natural"), "hemp": ("hemp", "natural"),
    "organic hemp": ("organic hemp", "natural"), "ramie": ("ramie", "natural"),
    "merino wool": ("wool", "natural"), "merino": ("wool", "natural"), "wool": ("wool", "natural"),
    "organic wool": ("organic wool", "natural"), "lambswool": ("wool", "natural"),
    "alpaca": ("alpaca", "natural"), "mohair": ("mohair", "natural"), "cashmere": ("cashmere", "natural"),
    "camel hair": ("camel", "natural"), "yak": ("yak", "natural"), "angora": ("angora", "natural"),
    "silk": ("silk", "natural"), "mulberry silk": ("silk", "natural"),
    # regenerated cellulose
    "viscose": ("viscose", "regenerated"), "rayon": ("rayon", "regenerated"), "modal": ("modal", "regenerated"),
    "lyocell": ("lyocell", "regenerated"), "tencel": ("lyocell", "regenerated"), "cupro": ("cupro", "regenerated"),
    "triacetate": ("acetate", "regenerated"), "acetate": ("acetate", "regenerated"),
    "bamboo viscose": ("viscose", "regenerated"), "bamboo rayon": ("rayon", "regenerated"),
    "bamboo": ("bamboo (viscose)", "regenerated"), "ecovero": ("viscose", "regenerated"),
    # synthetic
    "recycled polyester": ("polyester", "synthetic"), "polyester": ("polyester", "synthetic"),
    "poly": ("polyester", "synthetic"), "nylon": ("nylon", "synthetic"), "polyamide": ("nylon", "synthetic"),
    "acrylic": ("acrylic", "synthetic"), "spandex": ("elastane", "synthetic"), "elastane": ("elastane", "synthetic"),
    "lycra": ("elastane", "synthetic"), "polyurethane": ("polyurethane", "synthetic"),
    "polypropylene": ("polypropylene", "synthetic"), "olefin": ("polypropylene", "synthetic"),
    "pvc": ("PVC", "synthetic"), "vinyl": ("PVC", "synthetic"), "metallic": ("metallic", "synthetic"),
    "lurex": ("metallic", "synthetic"), "elasterell": ("elastane", "synthetic"),
}
# EU/EN label abbreviations, only read directly after a percentage
# ("89% rec.pes, 11%el"): EU Textile Regulation 1007/2011 Annex I names.
ABBREV = {"pes": "polyester", "pa": "polyamide", "el": "elastane",
          "ea": "elastane", "pan": "acrylic", "pu": "polyurethane", "pp": "polypropylene", "co": "cotton",
          "li": "linen", "wo": "wool", "wv": "wool", "cv": "viscose", "vi": "viscose", "cmd": "modal",
          "cly": "lyocell", "se": "silk", "ws": "cashmere", "ha": "hemp", "pl": "polyester", "ac": "acrylic",
          "cot": "cotton", "org cot": "organic cotton", "rec pes": "recycled polyester"}

_names = sorted(FIBRES, key=len, reverse=True)
FIBRE = r"(?:" + "|".join(re.escape(n) for n in _names) + r")"
ABBR = r"(?:" + "|".join(re.escape(a).replace(r"\ ", r"[ .]?") for a in sorted(ABBREV, key=len, reverse=True)) + r")"
# "95% cotton", "61%Cotton", "100% Airlume combed and ringspun cotton", "89% rec.pes"
PCT_FIRST = re.compile(r"(\d{1,3}(?:[.,]\d+)?)\s*%\s*((?:[a-z®™\-]+\s+){0,4}?)(" + FIBRE + r")(?![a-z])", re.I)
PCT_ABBR = re.compile(r"(\d{1,3}(?:[.,]\d+)?)\s*%\s*(" + ABBR + r")(?![a-z])", re.I)
# "Cotton 95%", "cotton: 95%"
NAME_FIRST = re.compile(r"\b(" + FIBRE + r")\s*[:\-]?\s*(\d{1,3}(?:[.,]\d+)?)\s*%", re.I)
# "Fabric: organic cotton", "Made from pure linen", "Material - 100 percent silk"
LABELLED = re.compile(r"\b(?:materials?|fabric(?:ation)?|composition|content|shell|made (?:of|from|with|in)|"
                      r"crafted (?:from|in|of)|knit (?:from|in)|woven (?:from|in))\s*[:\-–]?\s*"
                      r"(?:(?:a|an|the|soft|pure|premium|luxe|luxurious|lightweight|breathable|heavyweight|"
                      r"100 percent|100%|fine|washed|brushed|combed|ring-?spun)\s+){0,3}(" + FIBRE + r")\b", re.I)
VARIES = re.compile(r"(fib(?:er|re)|fabric) content (?:may )?var(?:y|ies)|blend varies|composition varies", re.I)
ORGANIC = re.compile(r"\borganic (cotton|linen|hemp|wool|silk)\b|\bgots\b|global organic textile standard", re.I)

# "print" alone is a garment's pattern ("African Print Cardigan", 2026-10-09);
# only an art print is not clothing.
NOT_GARMENT = re.compile(r"\b(gift ?cards?|e-?gift|stickers?|decals?|posters?|(?:art|giclee|giclée|wall|canvas) prints?|"
                         r"prints? on (?:paper|canvas)|mugs?|magnets?|"
                         r"pins?|keychains?|tote bags?|candles?|patterns? \(pdf\)|digital|pdf|book)\b", re.I)


def text_of(product):
    parts = [product.get("title") or "", product.get("product_type") or "", product.get("description") or "",
             " ".join(product.get("tags") or []), " ".join(product.get("opts") or [])]
    t = html.unescape(re.sub(r"<[^>]+>", " ", " ".join(parts)))
    return re.sub(r"\s+", " ", t)


def eligible(product):
    if product.get("category") != "clothing":
        return False
    return not NOT_GARMENT.search(f"{product.get('title') or ''} {product.get('product_type') or ''}") \
        or el.jev_says("garment", product)


def _abbr_key(s):
    """"REC.PES", "rec pes", "ORG COT" -> the ABBREV key ("rec pes", "org cot")."""
    return re.sub(r"[ .]+", " ", s.lower()).strip()


def _num(s):
    return float(s.replace(",", "."))


def composition(text):
    """-> {"parts": [(pct, name, class)], "share": {class: pct}, "organic": bool,
    "varies": bool} or None when no composition is stated."""
    parts = []
    taken = []  # spans already read, so "100% cotton" isn't also read as "cotton 100%"

    def add(span, pct, raw):
        if any(span[0] < e and s < span[1] for s, e in taken):
            return
        name, cls = FIBRES[raw.lower()]
        if 0 < pct <= 100:
            parts.append((pct, name, cls))
            taken.append(span)

    def pct_first():
        for m in PCT_FIRST.finditer(text):
            add(m.span(), _num(m.group(1)), m.group(3))
        for m in PCT_ABBR.finditer(text):
            add(m.span(), _num(m.group(1)), ABBREV[_abbr_key(m.group(2))])

    def name_first():
        for m in NAME_FIRST.finditer(text):
            add(m.span(), _num(m.group(2)), m.group(1))

    # "Cotton 95% Spandex 5%" reads name-first; "95% cotton, 5% spandex"
    # percent-first. Whichever style the listing opens with is read first, so
    # "95% Spandex" in the first isn't taken as a pair.
    m1, m2 = PCT_FIRST.search(text), NAME_FIRST.search(text)
    if m2 and (not m1 or m2.start() < m1.start()):
        name_first(); pct_first()
    else:
        pct_first(); name_first()
    if not parts:
        m = LABELLED.search(text)
        if not m:
            return None
        name, cls = FIBRES[m.group(1).lower()]
        parts = [(100.0, name, cls)]
    total = sum(p for p, _, _ in parts)
    # Percentages that don't add up to a whole garment ("60% cotton" and
    # nothing else read) can't be judged: the rest could be anything.
    complete = total >= 95
    share = {}
    for pct, _, cls in parts:
        share[cls] = share.get(cls, 0) + pct * 100 / total
    return {"parts": parts, "share": share, "varies": bool(VARIES.search(text)), "complete": complete,
            "organic": bool(ORGANIC.search(text)) or any(n.startswith("organic") for _, n, _ in parts)}


def evaluate(product):
    """-> (tier: "natural" | "organic" | None, failures: [str], notes: [str])"""
    if not eligible(product):
        return None, ["not clothing the badge covers"], []
    text = text_of(product)
    comp = composition(text)
    if not comp:
        return None, ["composition not stated"], []
    notes = []
    if not comp["complete"]:
        return None, ["composition incomplete"], notes
    natural = comp["share"].get("natural", 0)
    if comp["varies"]:
        return None, ["fibre content varies by colour"], notes
    if natural + 1e-9 < THRESHOLD:
        if comp["share"].get("regenerated", 0) >= comp["share"].get("synthetic", 0) and comp["share"].get("regenerated"):
            return None, [f"regenerated fibre (viscose, modal, lyocell, bamboo): {round(natural)}% natural"], notes
        return None, [f"synthetic fibre: {round(natural)}% natural"], notes
    if natural < 100:
        notes.append("blend with up to 10% other fibre")
    return ("organic" if comp["organic"] else "natural"), [], notes


def apply(products, store=None):
    """Rewrite `fiber` on every product. Returns report inputs."""
    stats = {"eligible": 0, "stated": 0, "passed": 0, "organic": 0}
    failed_by, noted_by, brands = {}, {}, set()
    for p in products:
        p.pop("fiber", None)
        if not eligible(p):
            continue
        stats["eligible"] += 1
        tier, failures, notes = evaluate(p)
        if not (failures and failures[0] == "composition not stated"):
            stats["stated"] += 1
        if tier:
            p["fiber"] = tier
            stats["passed"] += 1
            stats["organic"] += tier == "organic"
            brands.add(p["brand"])
            for n in notes:
                noted_by[n] = noted_by.get(n, 0) + 1
        else:
            key = failures[0].split(":")[0]
            failed_by[key] = failed_by.get(key, 0) + 1
    return stats, failed_by, noted_by, sorted(brands)


def write_report(stats, failed_by, noted_by, brands):
    lines = ["# Marracat Natural Fiber — badge report", "",
             f"{stats['eligible']} eligible garments · {stats['stated']} stating a composition · "
             f"**{stats['passed']} badged** across {len(brands)} brands · {stats['organic']} of them Organic.", "",
             f"The standard is in catalog/fiber_standard.md: at least {THRESHOLD}% natural fibre, stated in the "
             "listing. Read from each product's own description; nothing is fetched.", "",
             "## Why products fail", "", "| Reason | Products |", "|---|---|"]
    lines += [f"| {k} | {v} |" for k, v in sorted(failed_by.items(), key=lambda kv: -kv[1])]
    lines += ["", "## Allowed but noted", "", "| Note | Products |", "|---|---|"]
    lines += [f"| {k} | {v} |" for k, v in sorted(noted_by.items(), key=lambda kv: -kv[1])] or ["| none | 0 |"]
    lines += ["", "## Badged brands", "", ", ".join(brands) or "none yet", ""]
    REPORT.write_text("\n".join(lines))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--explain", metavar="PRODUCT_ID")
    ap.add_argument("--report-only", action="store_true", help="write the report without rewriting the catalog")
    args = ap.parse_args()
    catalog = json.loads(CATALOG.read_text())
    products = catalog["products"]
    if args.explain:
        p = next((p for p in products if p["id"] == args.explain), None)
        if not p:
            sys.exit(f"no product {args.explain}")
        tier, failures, notes = evaluate(p)
        print(f"{p['title']} ({p['brand']})\n  composition: {composition(text_of(p))}\n"
              f"  verdict: {tier or 'not badged'}\n  failures: {failures}\n  notes: {notes}")
        return
    stats, failed_by, noted_by, brands = apply(products)
    if not args.report_only:
        write_catalog(CATALOG, catalog)
    write_report(stats, failed_by, noted_by, brands)
    print(f"natural fiber badge: {stats['passed']} badged ({stats['organic']} organic) of {stats['eligible']} "
          f"garments — {REPORT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
