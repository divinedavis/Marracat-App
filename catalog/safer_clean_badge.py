#!/usr/bin/env python3
"""Award the Marracat Safer Clean household badge from a product's published
ingredient list.

The rules are in catalog/safer_clean_standard.md. In short: a cleaner,
detergent, dish or laundry product whose brand publishes its ingredient list
(California's Cleaning Product Right to Know Act requires one online), where
nothing on it is banned in any country: Clean's ban list plus chlorine bleach,
phosphates, nonylphenol ethoxylates, triclosan and triclocarban, PFAS and
1,4-dioxane below. Fragrance must be disclosed as Clean requires. Quats and
optical brighteners are allowed but noted. Tools, paper goods and air
fresheners aren't formulas and are never badged.

Lists come from the same store as Clean (catalog/ingredients.json); --scrape
fetches pages not yet stored. Sets product["safer"] = True on passing products
(absent otherwise) and writes catalog/safer_clean_report.md.

Usage:
    python3 catalog/safer_clean_badge.py
    python3 catalog/safer_clean_badge.py --scrape --max-new 200
    python3 catalog/safer_clean_badge.py --explain <product-id>
"""
import argparse
import json
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import clean_badge as cb  # noqa: E402
import ingredient_lists as il  # noqa: E402
import eligibility as el  # noqa: E402
from candle_badge import is_candle  # noqa: E402
from catalog_io import write_catalog  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Marracat" / "Resources" / "catalog.json"
REPORT = ROOT / "catalog" / "safer_clean_report.md"

CLEAN_SUBS = {"laundry", "cleaners", "fabric-care", "dish"}
CLEAN_WORDS = re.compile(r"\b(detergent|cleaner|cleaning (?:spray|solution|concentrate|paste|tablets?)|"
                         r"all[- ]purpose|multi[- ]purpose|multi-surface|surface (?:spray|cleaner)|"
                         r"dish (?:soap|liquid|wash)|dishwasher|laundry|stain (?:remover|spray|stick)|"
                         r"fabric (?:softener|refresher|spray)|scouring|degreaser|glass cleaner|"
                         r"toilet (?:bowl )?cleaner|floor cleaner|oxygen (?:bleach|booster)|wash(?:ing)? powder)\b",
                         re.I)
# Not a formula, or a formula another badge covers (hand soap and sanitiser
# are personal care; Clean judges hand soap).
NOT_CLEANER = re.compile(r"\b(brush|brushes|sponges?|cloths?|towels?|mop|bucket|gloves?|dryer balls?|"
                         r"bottle|empty|dispenser|caddy|basket|bag|hamper|toilet paper|paper towels?|"
                         r"napkins?|tissues?|candle|diffuser|air freshener|room spray|incense|"
                         r"hand soap|hand wash|hand sanitizer|sanitizer gel|body wash)\b", re.I)

# Cleaning-product bans beyond Clean's list. label, regex over one token, source.
SAFER_BANNED = [
    ("chlorine bleach", r"hypochlorite|chlorine bleach|\bbleach\b(?!-free)|calcium hypochlorite|"
     r"sodium dichloroisocyanurate|trichloroisocyanuric",
     "excluded by the EU Ecolabel for detergents and cleaners (reactive chlorine, Decisions 2017/1217-1219); "
     "hazardous with acids and ammonia"),
    ("phosphates", r"phosphate|phosphonic|phosphonate|\bstpp\b|tripolyphosphate|pyrophosphate",
     "EU Reg. 259/2012 caps phosphorus in consumer laundry and dishwasher detergents; 17 US states ban "
     "phosphates in dishwasher detergent (2010)"),
    ("nonylphenol ethoxylates", r"nonylphenol|nonoxynol|\bnpe\b|octylphenol",
     "EU REACH Annex XVII entry 46 bans them in cleaning products"),
    ("triclosan / triclocarban", r"triclosan|triclocarban",
     "Minnesota bans triclosan in cleaning products (Minn. Stat. 145.945, 2017); not approved under the EU "
     "Biocidal Products Regulation for hygiene use (Decision 2016/110)"),
    ("PFAS", r"perfluoro|polyfluoro|fluorotelomer|fluorosurfactant|\bptfe\b|polytetrafluoroethylene",
     "Minnesota bans intentionally added PFAS in cleaning products from 2025 (Amara's Law); Maine from 2026"),
    ("1,4-dioxane", r"1,?4-dioxane|\bdioxane\b",
     "New York caps it at 1 ppm in household cleansing products from 2023 (ECL 35-0105)"),
    ("borax and borates", r"\bborax\b|sodium (tetra)?borate|boric acid|sodium perborate|disodium octaborate|"
     r"\bborate\b",
     "EU CLP classifies borax, boric acid and perborate toxic to reproduction (Repr. 1B), and REACH Annex XVII "
     "entries 28-30 bar them from mixtures sold to the public above the classification limit; a list can't "
     "show the level"),
]
# Allowed but noted: legal everywhere, worth knowing.
SAFER_NOTED = [
    ("quaternary ammonium (quats)", r"benzalkonium|ammonium chloride|quaternium|didecyldimethyl|"
     r"alkyl dimethyl benzyl"),
    ("optical brighteners", r"optical brightener|stilbene|distyrylbiphenyl|fluorescent brightener|"
     r"(whitening|brightening) agent"),
]


def eligible(product):
    if product.get("category") != "household" or is_candle(product):
        return False
    subs = set(product.get("subs") or [])
    if NOT_CLEANER.search(el.exclusion_text(product)) or subs & {"cleaning-tools", "paper", "air-care", "hand-soap"}:
        return False
    return (bool(subs & CLEAN_SUBS) or bool(CLEAN_WORDS.search(el.positive_text(product)))
            or el.jev_says("safer", product))


def evaluate(product, inci):
    """-> (passes: bool, failures: [str], notes: [str])"""
    failures, notes = [], []
    if inci and cb.NOT_A_LIST.search(inci):
        inci = ""
    if not inci:
        return False, ["no published ingredient list"], notes
    if cb.VARIABLE.search(inci):
        failures.append("the brand says the formula varies")
    toks = il.tokens(inci)
    for label, hits in il.banned_hits(toks, SAFER_BANNED):
        failures.append(f"{label}: {', '.join(hits[:3])}")
    bare = il.fragrance_undisclosed(inci, toks)
    if bare:
        failures.append(f"undisclosed fragrance: {bare}")
    for label, pattern in SAFER_NOTED:
        rx = re.compile(pattern, re.I)
        if any(rx.search(t) for t in toks):
            notes.append(label)
    return not failures, failures, notes


def apply(products, store):
    """Rewrite `safer` on every product from the stored lists. Returns report inputs."""
    stats = {"eligible": 0, "listed": 0, "passed": 0}
    failed_by, noted_by, brands = {}, {}, set()
    for p in products:
        p.pop("safer", None)
        if not eligible(p):
            continue
        stats["eligible"] += 1
        inci = store.get(p["url"], "")
        if inci:
            stats["listed"] += 1
        ok, failures, notes = evaluate(p, inci)
        if ok:
            p["safer"] = True
            stats["passed"] += 1
            brands.add(p["brand"])
            for n in notes:
                noted_by[n] = noted_by.get(n, 0) + 1
        else:
            for f in failures:
                key = f.split(":")[0]
                failed_by[key] = failed_by.get(key, 0) + 1
    return stats, failed_by, noted_by, sorted(brands)


def write_report(stats, failed_by, noted_by, brands):
    lines = ["# Marracat Safer Clean — badge report", "",
             f"{stats['eligible']} eligible cleaning products · {stats['listed']} with a published list · "
             f"**{stats['passed']} badged** across {len(brands)} brands.", "",
             "The standard is in catalog/safer_clean_standard.md. A product without a published list is never "
             "badged; lists are fetched by `safer_clean_badge.py --scrape` (ship.sh runs it with a cap), so this "
             "count grows as pages are read.", "",
             "## Why products fail", "", "| Reason | Products |", "|---|---|"]
    lines += [f"| {k} | {v} |" for k, v in sorted(failed_by.items(), key=lambda kv: -kv[1])]
    lines += ["", "## Allowed but noted", "", "| Note | Products |", "|---|---|"]
    lines += [f"| {k} | {v} |" for k, v in sorted(noted_by.items(), key=lambda kv: -kv[1])] or ["| none | 0 |"]
    lines += ["", "## Badged brands", "", ", ".join(brands) or "none yet", ""]
    REPORT.write_text("\n".join(lines))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scrape", action="store_true", help="fetch ingredient lists not yet stored")
    ap.add_argument("--max-new", type=int, default=0, help="cap on pages fetched this run (0 = no cap)")
    ap.add_argument("--explain", metavar="PRODUCT_ID")
    ap.add_argument("--report-only", action="store_true", help="write the report without rewriting the catalog")
    args = ap.parse_args()
    catalog = json.loads(CATALOG.read_text())
    products = catalog["products"]
    store, misses = cb.load(cb.STORE, {}), cb.load(cb.MISSES, {})
    if args.scrape:
        il.scrape([p for p in products if eligible(p)], store, misses, args.max_new)
        il.save(store, misses)
    if args.explain:
        p = next((p for p in products if p["id"] == args.explain), None)
        if not p:
            sys.exit(f"no product {args.explain}")
        inci = store.get(p["url"], "")
        ok, failures, notes = evaluate(p, inci)
        print(f"{p['title']} ({p['brand']})\n  eligible: {eligible(p)}\n  list: {inci[:300] or '—'}\n"
              f"  verdict: {'SAFER CLEAN' if ok else 'not badged'}\n  failures: {failures}\n  notes: {notes}")
        return
    stats, failed_by, noted_by, brands = apply(products, store)
    if not args.report_only:
        write_catalog(CATALOG, catalog)
    write_report(stats, failed_by, noted_by, brands)
    print(f"safer clean badge: {stats['passed']} badged of {stats['listed']} listed "
          f"({stats['eligible']} eligible) — {REPORT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
