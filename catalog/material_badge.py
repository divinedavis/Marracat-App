#!/usr/bin/env python3
"""Award the Marracat True Material badge.

The rules are in catalog/material_standard.md. A bag earns it when its own
listing names what the bag is made of, honestly:

- Real leather named as such: full-grain, top-grain, genuine or real leather,
  cowhide, calfskin, lambskin, goatskin, nappa, suede (US FTC Guides for
  Select Leather and Imitation Leather Products, 16 CFR 24). Plain "leather"
  counts only when nothing in the listing says vegan, faux, PU or synthetic.
- A natural material: cotton or canvas, linen, hemp, jute, raffia, straw,
  rattan, sisal, seagrass, wool, felt, cork.
- A named alternative: recycled nylon or polyester, cactus (Desserto), apple,
  mushroom (Mylo), pineapple (Piñatex) or grape leather.
- An honestly named synthetic: polyurethane (PU), nylon, polyester. They're not
  natural, but the bag says what it is, which is what this badge rewards; they
  are noted.

Fails: "vegan leather", "faux leather", "leatherette", "leather-look",
"pleather" or "synthetic leather" without the material named; PVC or vinyl not
stated phthalate-free (EU REACH Annex XVII entry 51 restricts the plasticising
phthalates, and California Prop 65 lists them); and a bag that doesn't say what
it's made of.

Tier "Marracat True Material · Vegetable Tanned": leather stated vegetable-
tanned or chrome-free. Chromium VI in leather is banned in the EU above 3 mg/kg
(REACH Annex XVII entry 47), and chrome-tanned leather is where it forms.

Bag-care products (cleaners, conditioners) and gift cards aren't judged. Read
from each product's own title, description, tags and options; nothing is
fetched. Sets product["material"] = "true" or "veg" on passing products (absent
otherwise) and writes catalog/material_report.md.

Usage:
    python3 catalog/material_badge.py
    python3 catalog/material_badge.py --explain <product-id>
    python3 catalog/material_badge.py --report-only     # don't rewrite the catalog
"""
import argparse
import json
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from baby_badge import text_of, without_free_claims  # noqa: E402
from catalog_io import write_catalog  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Marracat" / "Resources" / "catalog.json"
REPORT = ROOT / "catalog" / "material_report.md"

NOT_A_BAG = re.compile(r"\b(gift ?cards?|e-?gift|cleaner|conditioner|protector spray|care kit|leather care|"
                       r"stickers?|keychains?|key rings?|charms?|straps? only|replacement strap|insert|"
                       r"organizer insert|dust bag only|patches?)\b", re.I)

STRONG_LEATHER = re.compile(r"full[- ]grain|top[- ]grain|genuine leather|real leather|100\s*% leather|"
                            r"cow ?hide|calf ?skin|lamb ?skin|goat ?skin|sheep ?skin|nappa|nubuck|"
                            r"pebbled leather|saffiano leather|italian leather|vachetta|patent leather|"
                            r"croc(?:odile)?[- ]embossed leather", re.I)
# Plain "leather" names the bag only in the title, a material statement or a
# "leather bag" phrase; "swap the leather strap" doesn't make the bag leather.
LEATHER_MAIN = re.compile(r"(?:made (?:of|from|with|in)|crafted (?:from|in|of)|material|materials|"
                          r"constructed (?:from|of)|exterior|outer|body)\s*[:\-–]?\s*(?:\w+\s+){0,2}"
                          r"(?:leather|suede)\b|\b(?:leather|suede)\s+(?:bags?|totes?|handbags?|purses?|"
                          r"wallets?|clutch(?:es)?|crossbody|backpacks?|satchels?|duffels?|duffles?|"
                          r"pouch(?:es)?|card ?holders?|belt bags?|shoulder bags?|bucket bags?|briefcases?|"
                          r"messenger|weekenders?|hobo|minaudi\w+)\b", re.I)
FAUX = re.compile(r"vegan leather|faux leather|faux suede|vegan suede|leatherette|leather[- ]look|"
                  r"leather[- ]like|pleather|synthetic leather|imitation leather|artificial leather|"
                  r"pu leather|\bvegan\b(?! (?:friendly|food))", re.I)
NATURAL = re.compile(r"\b(organic cotton|cotton canvas|canvas|cotton|linen|hemp|jute|raffia|straw|rattan|sisal|"
                     r"seagrass|water hyacinth|wicker|wool|felt|cork|kente|mudcloth|bogolan|ankara|"
                     r"denim|corduroy|velvet|silk)\b", re.I)
ALTERNATIVE = re.compile(r"recycled (?:nylon|polyester|pet|plastic bottles?)|\brpet\b|econyl|repreve|"
                         r"cactus leather|desserto|apple leather|appleskin|mushroom leather|mylo|mycelium|"
                         r"pi[ñn]atex|pineapple leather|grape leather|vegea|cork leather", re.I)
SYNTHETIC = re.compile(r"\bpolyurethane\b|\bpu\b|\bnylon\b|\bpolyester\b|\bneoprene\b|\btpu\b|\bacrylic\b|"
                       r"\bmicrofib(?:er|re)\b", re.I)
PVC = re.compile(r"\bpvc\b|\bvinyl\b(?! (?:sticker|decal|print|record))|polyvinyl chloride", re.I)
PHTHALATE_FREE = re.compile(r"phthalate[- ]free|free (?:of|from) phthalates|non[- ]phthalate", re.I)
VEG_TAN = re.compile(r"vegetable[- ]tann(?:ed|ing)|veg[- ]tan(?:ned)?|chrome[- ]free|tanned with (?:tree )?"
                     r"(?:bark|plant|vegetable)|bark[- ]tanned|tannins? from", re.I)


def eligible(product):
    if product.get("category") != "bags":
        return False
    if "bag-care" in set(product.get("subs") or []):
        return False
    return not NOT_A_BAG.search(f"{product.get('title') or ''} {product.get('product_type') or ''}")


def evaluate(product):
    """-> (tier: "true" | "veg" | None, failures: [str], notes: [str])"""
    if not eligible(product):
        return None, ["not a bag the badge covers"], []
    text = text_of(product)
    claims = without_free_claims(text)
    failures, notes, named = [], [], []
    faux = FAUX.search(claims)
    if STRONG_LEATHER.search(text):
        named.append("real leather")
    elif not faux and (re.search(r"\b(?:leather|suede)\b", product.get("title") or "", re.I)
                       or LEATHER_MAIN.search(text)
                       or (VEG_TAN.search(text) and re.search(r"\bleather\b", text, re.I))):
        named.append("leather")
    if NATURAL.search(text):
        named.append(NATURAL.search(text).group(1).lower())
    if ALTERNATIVE.search(text):
        named.append("recycled or plant-based material")
    synthetic = SYNTHETIC.search(claims)
    if synthetic:
        named.append("synthetic")
        notes.append(f"honestly named synthetic: {synthetic.group(0).lower()}")
    if faux and not (synthetic or ALTERNATIVE.search(text)):
        failures.append(f"vegan or faux leather without the material named: {faux.group(0)}")
    if PVC.search(claims) and not PHTHALATE_FREE.search(text):
        failures.append("PVC / vinyl not stated phthalate-free")
    if not named and not failures:
        failures.append("material not stated")
    if failures:
        return None, failures, notes
    if named == ["synthetic"]:
        notes.append("synthetic only")
    leather = any(n in ("real leather", "leather") for n in named)
    if leather and VEG_TAN.search(text):
        return "veg", [], notes + ["vegetable-tanned or chrome-free"]
    return "true", [], notes


def apply(products, store=None):
    """Rewrite `material` on every product. Returns report inputs."""
    stats = {"eligible": 0, "stated": 0, "passed": 0, "veg": 0}
    failed_by, noted_by, brands = {}, {}, set()
    for p in products:
        p.pop("material", None)
        if not eligible(p):
            continue
        stats["eligible"] += 1
        tier, failures, notes = evaluate(p)
        if not (failures and failures[0] == "material not stated"):
            stats["stated"] += 1
        if tier:
            p["material"] = tier
            stats["passed"] += 1
            stats["veg"] += tier == "veg"
            brands.add(p["brand"])
            for n in notes:
                key = n.split(":")[0]
                noted_by[key] = noted_by.get(key, 0) + 1
        else:
            for f in failures:
                key = f.split(":")[0]
                failed_by[key] = failed_by.get(key, 0) + 1
    return stats, failed_by, noted_by, sorted(brands)


def write_report(stats, failed_by, noted_by, brands):
    lines = ["# Marracat True Material — badge report", "",
             f"{stats['eligible']} eligible bags · {stats['stated']} naming a material · "
             f"**{stats['passed']} badged** across {len(brands)} brands · {stats['veg']} of them Vegetable Tanned.", "",
             "The standard is in catalog/material_standard.md: the bag's material named honestly, no unnamed vegan or "
             "faux leather, no PVC without phthalate-free. Read from each product's own description; nothing is "
             "fetched.", "",
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
        print(f"{p['title']} ({p['brand']})\n  verdict: {tier or 'not badged'}\n  failures: {failures}\n"
              f"  notes: {notes}")
        return
    stats, failed_by, noted_by, brands = apply(products)
    if not args.report_only:
        write_catalog(CATALOG, catalog)
    write_report(stats, failed_by, noted_by, brands)
    print(f"true material badge: {stats['passed']} badged ({stats['veg']} vegetable tanned) of {stats['eligible']} "
          f"bags — {REPORT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
