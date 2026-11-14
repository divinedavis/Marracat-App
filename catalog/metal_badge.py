#!/usr/bin/env python3
"""Award the Marracat True Metal jewelry badge from what the listing says.

The rules are in catalog/metal_standard.md. In short: every metal the listing
names is a real, solid, skin-safe metal (10k+ gold, sterling silver, platinum,
316L/surgical steel, titanium, niobium), and nothing is plated or toned to look
like something it isn't. A True Metal product that names a sourcing scheme
(recycled metal, Fairmined/Fairtrade gold, RJC, lab-grown or conflict-free
stones) gets the Ethically Sourced tier.

It reads title, description, tags and product type only: no fetching. The
verdict sets product["metal"] to "true" or "ethical" (absent otherwise).

Usage:
    python3 catalog/metal_badge.py                 # rewrite flags + report
    python3 catalog/metal_badge.py --explain <product-id>
"""
import argparse
import json
import pathlib
import re
import sys
from catalog_io import write_catalog

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Marracat" / "Resources" / "catalog.json"
REPORT = ROOT / "catalog" / "metal_report.md"

# Phrases that mention a bad material only to deny it: removed before scanning.
_BAD = r"(?:nickel|lead|cadmium)"
NEGATED = re.compile(rf"\b{_BAD}(?:\s*(?:,|and|&|/)\s*{_BAD})*,?\s*(?:and\s+)?[- ]?free\b|"
                     rf"\bfree (?:of|from) {_BAD}(?:\s*(?:,|and|or|&)\s*{_BAD})*\b|"
                     r"\btrace (?:amounts?|quantities) of nickel\b|"
                     r"\b(nickel|lead|cadmium|brass|copper)[- ]?free\b|\bfree (of|from) (nickel|lead|cadmium)\b|"
                     r"\bno (nickel|lead|cadmium)\b|\bwithout (nickel|lead|cadmium)\b|\bnot (gold[- ]?)?plated\b|"
                     r"\bnever plated\b|\bno plating\b|\bwon'?t tarnish\b", re.I)

QUALIFY = [
    ("gold 10k+", re.compile(r"\b(1[0-9]|2[0-4])\s?(k|kt|karat|carat)\b(?!\s*(?:diamond|stone|total|tw|ctw))|\bsolid gold\b", re.I)),
    ("sterling silver", re.compile(r"\bsterling\b|(?<![\d.])\.?925\b|\bfine silver\b|\b999 silver\b|\bargentium\b", re.I)),
    ("platinum", re.compile(r"\bplatinum\b(?! (?:collection|edition|series|blonde|member|card|level|tier|package|plan))", re.I)),
    ("implant-grade steel", re.compile(r"\b316\s?l\b|\bsurgical(?:[- ]grade)? (?:stainless )?steel\b|\bimplant[- ]grade\b", re.I)),
    # "Titanium steel" is a marketing name for stainless steel, not titanium.
    ("titanium", re.compile(r"\btitanium\b(?! steel| stainless)", re.I)),
    ("niobium", re.compile(r"\bniobium\b", re.I)),
]
STAINLESS = re.compile(r"\bstainless(?: steel)?\b", re.I)
NICKEL_FREE = re.compile(r"\bnickel[- ]?free\b|\bfree (of|from) nickel\b", re.I)

FAIL = [
    ("base metal", re.compile(r"\b(brass|bronze|zinc|pewter|alumin(?:i)?um|iron|tin|base metal|copper)\b|"
                              r"(?<!gold )(?<!silver )(?<!platinum )\balloy\b", re.I)),
    ("plated or toned", re.compile(r"\b(plated|plating|electroplated|gold[- ]tone|silver[- ]tone|rose[- ]gold[- ]tone|"
                                   r"dipped|coated|coating|pvd|ip[- ]plated|flashed|gold[- ]washed)\b", re.I)),
    ("gold-filled or vermeil", re.compile(r"\bgold[- ]filled\b|\bvermeil\b|\bgf\b", re.I)),
    # Faux pearls on sterling are fine: only imitation *metal* or costume pieces fail.
    ("imitation", re.compile(r"\b(?:faux|imitation|simulated|fake) (?:gold|silver|platinum|metal)\b|"
                             r"\bcostume jewel(?:le)?ry\b|\bfashion jewel(?:le)?ry\b", re.I)),
    # Lead as a material, not "lead time" or "will lead you".
    ("lead or cadmium", re.compile(r"\bcadmium\b|\blead(?:ed)? (?:crystal|glass|content|alloy|solder)\b|"
                                   r"\b(?:contains?|with|of) lead\b|\blead[- ]based\b", re.I)),
    ("nickel", re.compile(r"\bnickel\b", re.I)),
]
# Rhodium over a precious metal is that metal's standard finish, not a disguise.
RHODIUM = re.compile(r"\brhodium[- ](?:plated|plating|finish)\b|\b(?:plated|finished|dipped) (?:in|with) rhodium\b", re.I)

ETHICAL = re.compile(r"\brecycled (?:solid )?(?:\d+k |sterling )?(?:gold|silver|sterling|metals?|platinum)\b|\bfairmined\b|"
                     r"\bfair ?trade (?:certified )?gold\b|\bresponsible jewell?ery council\b|\brjc[- ]certified\b|"
                     r"\b(?:lab|laboratory)[- ](?:grown|created)\b|\bconflict[- ]free\b|\bkimberley process\b", re.I)

JEWELRY_SUBS = {"earrings", "necklaces", "rings", "bracelets", "pendants", "chains", "anklets", "brooches",
                "engagement", "jewelry-sets", "grillz", "diamonds", "gold", "body-jewelry", "charms"}


def eligible(product):
    return product.get("category") == "jewelry" or bool(set(product.get("subs") or []) & JEWELRY_SUBS)


def text_of(product):
    """Everything the listing says about itself. Variant titles count: fine
    jewelry often names the metal only there ("14K Yellow Gold / 6"), and a
    listing that also offers a plated variant fails, which is the point."""
    tags = product.get("tags") or []
    variants = " / ".join(str(v.get("title") or "") for v in (product.get("variants") or [])
                          if v.get("title") not in (None, "Default Title"))
    return " ".join([product.get("title") or "", product.get("product_type") or "",
                     product.get("description") or "", " ".join(tags if isinstance(tags, list) else [str(tags)]),
                     variants])


def evaluate(product):
    """-> (verdict: "true" | "ethical" | None, metals: [str], failures: [str])"""
    raw = text_of(product)
    text = NEGATED.sub(" ", raw)
    # Rhodium plating is allowed; take it out before the plating check.
    text_no_rhodium = RHODIUM.sub(" ", text)
    metals = [name for name, rx in QUALIFY if rx.search(text)]
    steel_ok = STAINLESS.search(text) and NICKEL_FREE.search(raw)
    if steel_ok and "implant-grade steel" not in metals:
        metals.append("nickel-free stainless steel")
    failures = []
    for name, rx in FAIL:
        hay = text_no_rhodium if name == "plated or toned" else text
        m = rx.search(hay)
        if m:
            failures.append(f"{name}: {m.group(0).lower()}")
    if not metals:
        if STAINLESS.search(text):
            failures.append("stainless steel, grade not stated")
        else:
            failures.append("metal not named")
    if failures:
        return None, metals, failures
    return ("ethical" if ETHICAL.search(raw) else "true"), metals, []


def apply(products):
    """Rewrite `metal` on every product. Returns report inputs."""
    stats = {"eligible": 0, "true": 0, "ethical": 0}
    failed_by, metal_by, brands, ethical_brands = {}, {}, set(), set()
    for p in products:
        p.pop("metal", None)
        if not eligible(p):
            continue
        stats["eligible"] += 1
        verdict, metals, failures = evaluate(p)
        if verdict:
            p["metal"] = verdict
            stats[verdict] += 1
            brands.add(p["brand"])
            if verdict == "ethical":
                ethical_brands.add(p["brand"])
            for m in metals:
                metal_by[m] = metal_by.get(m, 0) + 1
        else:
            for f in failures:
                key = f.split(":")[0]
                failed_by[key] = failed_by.get(key, 0) + 1
    return stats, failed_by, metal_by, sorted(brands), sorted(ethical_brands)


def write_report(stats, failed_by, metal_by, brands, ethical_brands):
    badged = stats["true"] + stats["ethical"]
    lines = ["# Marracat True Metal — badge report", "",
             f"{stats['eligible']} jewelry products · **{badged} badged** across {len(brands)} brands · "
             f"{stats['ethical']} of them Ethically Sourced ({len(ethical_brands)} brands).", "",
             "The standard is in catalog/metal_standard.md. A listing that doesn't name its metal is never badged; "
             "one that names a real metal and a plating or base metal fails.", "",
             "## Metals on badged products", "", "| Metal | Products |", "|---|---|"]
    lines += [f"| {k} | {v} |" for k, v in sorted(metal_by.items(), key=lambda kv: -kv[1])]
    lines += ["", "## Why products fail", "", "| Reason | Products |", "|---|---|"]
    lines += [f"| {k} | {v} |" for k, v in sorted(failed_by.items(), key=lambda kv: -kv[1])]
    lines += ["", "## Badged brands", "", ", ".join(brands), "",
              "## Ethically Sourced brands", "", ", ".join(ethical_brands) or "none", ""]
    REPORT.write_text("\n".join(lines))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--explain", metavar="PRODUCT_ID")
    args = ap.parse_args()
    catalog = json.loads(CATALOG.read_text())
    products = catalog["products"]
    if args.explain:
        p = next((p for p in products if p["id"] == args.explain), None)
        if not p:
            sys.exit(f"no product {args.explain}")
        verdict, metals, failures = evaluate(p)
        print(f"{p['title']} ({p['brand']})\n  eligible: {eligible(p)}\n  verdict: {verdict or 'not badged'}\n"
              f"  metals: {metals}\n  failures: {failures}")
        return
    stats, failed_by, metal_by, brands, ethical_brands = apply(products)
    write_catalog(CATALOG, catalog)
    write_report(stats, failed_by, metal_by, brands, ethical_brands)
    print(f"true metal badge: {stats['true'] + stats['ethical']} badged ({stats['ethical']} ethically sourced) "
          f"of {stats['eligible']} jewelry products — {REPORT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
