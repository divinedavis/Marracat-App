#!/usr/bin/env python3
"""Award the Marracat Clear Scent fragrance badge from a product's published
ingredient list.

The rules are in catalog/scent_standard.md. In short: a perfume, body mist,
perfume oil or cologne whose brand publishes its ingredient list, where nothing
on it is banned in any country (Clean's ban list plus the fragrance bans and
IFRA prohibitions below), no phthalate of any kind is used, and the scent is
disclosed: named EU fragrance allergens beside "fragrance/parfum", or a
formula of named essential oils and isolates. Candles have their own badge.

Lists come from the same store as Clean (catalog/ingredients.json); --scrape
fetches pages not yet stored (catalog/ingredient_lists.py). Sets product["scent"]
= True on passing products (absent otherwise) and writes catalog/scent_report.md.

Usage:
    python3 catalog/scent_badge.py                       # rewrite flags + report
    python3 catalog/scent_badge.py --scrape --max-new 200
    python3 catalog/scent_badge.py --explain <product-id>
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
REPORT = ROOT / "catalog" / "scent_report.md"

# Worn fragrance: what the badge can apply to.
SCENT_SUBS = {"perfume-oil", "edp", "edt", "cologne", "body-mist", "refill"}
SCENT_WORDS = re.compile(r"\b(perfume|parfum|cologne|eau de|edp|edt|extrait|body mist|hair mist|body spray|"
                         r"fragrance oil|perfume oil|scented oil|attar|roll[- ]?on|solid perfume|"
                         r"fine fragrance|fragrance mist)\b", re.I)
# Several formulas in one box, the bottle rather than the juice, or scent for a
# room or a car: none of them are a worn fragrance with one list.
NOT_SCENT = re.compile(r"\b(set|sampler|samples?|discovery|bundle|gift box|kit|trio|duo|collection box|"
                       r"atomi[sz]er|empty|bottle only|case|pouch|funnel|diffuser|burner|reed|wax melts?|"
                       r"room spray|linen spray|car (?:freshener|diffuser)|incense|home fragrance|"
                       r"candle|soap|body wash|shower gel|lotion|body butter|shampoo|conditioner)\b", re.I)

# Fragrance bans beyond Clean's list. label, regex over one INCI token, source.
SCENT_BANNED = [
    ("musk tibetene / musk moskene",
     r"musk (tibetene|moskene)|\bmoskene\b|\btibetene\b",
     "EU Annex II (entries 413, 414); IFRA prohibited"),
    ("atranol / chloroatranol", r"\b(chloro)?atranol\b",
     "EU Annex II since August 2021 (Reg. 2017/1410); IFRA prohibited"),
    ("methyl eugenol", r"methyl ?eugenol",
     "EU Annex III caps it at trace levels (0.01% fine fragrance) and Canada's Hotlist restricts it; "
     "a list can't show the level, so a named addition fails"),
    ("AETT (versalide)", r"acetyl ethyl tetramethyl tetralin|\baett\b|\bversalide\b",
     "EU Annex II; IFRA prohibited"),
    ("7-methylcoumarin", r"7-methylcoumarin", "EU Annex II; IFRA prohibited"),
    ("diethyl maleate", r"diethyl maleate", "IFRA prohibited (sensitiser)"),
    ("dihydrocoumarin", r"dihydrocoumarin", "IFRA prohibited (sensitiser)"),
    ("benzene", r"^benzene$", "EU Annex II; carcinogen"),
]

# Every phthalate fails, DEP included. DEP is not banned anywhere — the EU,
# US and Canada allow it — but the badge promises phthalate-free, and Clean's
# list already fails any phthalate.
PHTHALATE = re.compile(r"phthalate|\bdep\b|\bdehp\b|\bdbp\b|\bbbp\b|\bdibp\b", re.I)


def eligible(product):
    if product.get("category") != "fragrance" or is_candle(product):
        return False
    subs = set(product.get("subs") or [])
    if NOT_SCENT.search(el.exclusion_text(product)) or subs & {"fragrance-set", "discovery", "fragrance-bath"}:
        return False
    return (bool(subs & SCENT_SUBS) or bool(SCENT_WORDS.search(el.positive_text(product)))
            or el.jev_says("scent", product))


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
    phth = sorted({t for t in toks if PHTHALATE.search(t) and "free" not in t})
    if phth:
        failures.append(f"phthalates: {', '.join(phth[:3])}")
    for label, hits in il.banned_hits(toks, SCENT_BANNED):
        if label == "phthalates":
            continue  # reported once, above
        failures.append(f"{label}: {', '.join(hits[:3])}")
    bare = il.fragrance_undisclosed(inci, toks)
    if bare:
        failures.append(f"undisclosed fragrance: {bare}")
    if any("alcohol denat" in t for t in toks):
        notes.append("denatured alcohol base")
    return not failures, failures, notes


def apply(products, store):
    """Rewrite `scent` on every product from the stored lists. Returns report inputs."""
    stats = {"eligible": 0, "listed": 0, "passed": 0}
    failed_by, noted_by, brands = {}, {}, set()
    for p in products:
        p.pop("scent", None)
        if not eligible(p):
            continue
        stats["eligible"] += 1
        inci = store.get(p["url"], "")
        if inci:
            stats["listed"] += 1
        ok, failures, notes = evaluate(p, inci)
        if ok:
            p["scent"] = True
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
    lines = ["# Marracat Clear Scent — badge report", "",
             f"{stats['eligible']} eligible fragrances · {stats['listed']} with a published list · "
             f"**{stats['passed']} badged** across {len(brands)} brands.", "",
             "The standard is in catalog/scent_standard.md. A fragrance without a published list is never badged; "
             "lists are fetched by `scent_badge.py --scrape` (ship.sh runs it with a cap), so this count grows as "
             "pages are read.", "",
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
              f"  verdict: {'CLEAR SCENT' if ok else 'not badged'}\n  failures: {failures}\n  notes: {notes}")
        return
    stats, failed_by, noted_by, brands = apply(products, store)
    if not args.report_only:
        write_catalog(CATALOG, catalog)
    write_report(stats, failed_by, noted_by, brands)
    print(f"clear scent badge: {stats['passed']} badged of {stats['listed']} listed "
          f"({stats['eligible']} eligible) — {REPORT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
