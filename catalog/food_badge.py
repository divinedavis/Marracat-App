#!/usr/bin/env python3
"""Award the Marracat Clean Food badge from a product's published ingredient
list.

The rules are in catalog/food_standard.md. In short: a packaged food, drink,
tea, coffee, spice or sauce whose brand publishes its ingredient list, where
nothing on it is banned as a food additive in any country (the list below,
each entry cited), and with no high-fructose corn syrup, which no country bans
but the Marracat standard excludes. Alcohol, supplements, pet food and
merchandise (mugs, infusers, gift cards) are never badged.

Food lists are short and plain ("Ingredients: organic hibiscus, ginger"), so
they're read with their own extractor: the run after an "Ingredients" label,
up to the first sentence that isn't part of it. The product's own description
is read first; product pages fetched by --scrape are stored in the same store
as Clean (catalog/ingredients.json). Sets product["food"] = True on passing
products (absent otherwise) and writes catalog/food_report.md.

Usage:
    python3 catalog/food_badge.py
    python3 catalog/food_badge.py --scrape --max-new 200
    python3 catalog/food_badge.py --explain <product-id>
    python3 catalog/food_badge.py --report-only     # don't rewrite the catalog
"""
import argparse
import html
import json
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import clean_badge as cb  # noqa: E402
import ingredient_lists as il  # noqa: E402
import eligibility as el  # noqa: E402
from catalog_io import write_catalog  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Marracat" / "Resources" / "catalog.json"
REPORT = ROOT / "catalog" / "food_report.md"

# Not a food, or a food another rule covers.
NOT_FOOD = re.compile(
    r"\b(mug|mugs|cup set|tumbler|kettle|teapot|tea pot|infuser|strainer|french press|grinder|"
    r"gift card|e-?gift|subscription box|tote|t-?shirt|hoodie|apron|candle|book|cookbook|"
    r"supplement|capsules?|tablets?|vitamins?|protein powder|pre-?workout|collagen|"
    r"dog|cat|pet|treats? for (dogs|cats)|wine|beer|liquor|spirits?|vodka|whiskey|rum|tequila|gin\b|"
    r"cbd|thc|delta[- ]?8|hemp extract)\b", re.I)

# Food additives banned somewhere. label, regex over one ingredient, source.
FOOD_BANNED = [
    ("Red No. 3 (erythrosine)", r"\bred (no\.? ?)?3\b|erythrosine?\b|\be-?127\b|fd&c red 3",
     "US FDA revoked its food authorisation (January 2025); California Food Safety Act AB 418 (2023) bans it "
     "from 2027"),
    ("synthetic azo and coal-tar dyes", r"\b(red|yellow|blue|green) ?(no\.? ?|# ?)?(40|5|6|1|2|3)\b|allura red|tartrazine|"
     r"sunset yellow|brilliant blue|indigo ?(carmine|tine)|fast green|citrus red|orange b\b|"
     r"\be-?(102|110|129|132|133|143)\b|fd&c|artificial colou?rs?|\blake ?# ?\d|(aluminum|aluminium|colou?r) lake",
     "West Virginia HB 2354 (2025) bans Red 40, Yellow 5, Yellow 6, Blue 1, Blue 2, Green 3 and Red 3 in food "
     "sold in the state from 2028; Green 3 (E143) is not authorised in the EU (Reg. 1333/2008 Annex II)"),
    ("titanium dioxide (E171)", r"titanium dioxide|\be-?171\b",
     "banned as a food additive in the EU since August 2022 (Commission Regulation 2022/63)"),
    ("potassium bromate", r"bromate|bromated",
     "banned in the EU, UK, Canada, China and Brazil; California AB 418 bans it from 2027"),
    ("brominated vegetable oil", r"brominated|\bbvo\b",
     "US FDA revoked its authorisation (2024); never permitted in the EU or Japan"),
    ("azodicarbonamide", r"azodicarbonamide|\bada\b(?= ?\()|\be-?927a\b",
     "not permitted in the EU (Directive 2004/1/EC) or Australia/New Zealand; banned in Singapore"),
    ("propylparaben", r"propyl ?paraben|\be-?216\b",
     "removed from the EU additive list (2006); California AB 418 bans it from 2027"),
    ("partially hydrogenated oil", r"partially hydrogenated|hydrogenated (vegetable |soybean |palm |cottonseed )?oil",
     "US FDA removed its GRAS status (2018); Canada banned it (2018); the EU caps industrial trans fat at 2 g "
     "per 100 g of fat (Reg. 2019/649)"),
    ("rBST / rBGH dairy", r"\brbst\b|\brbgh\b|recombinant bovine",
     "the hormone is banned in Canada, the EU, Japan, Australia and New Zealand"),
    ("cyclamate", r"cyclamate", "banned in US foods since 1969 (21 CFR 189.135)"),
    ("olestra", r"olestra|olean\b", "not authorised in the EU or Canada"),
    ("illegal dyes", r"sudan (i|1|red)|rhodamine|para red", "banned as food additives everywhere"),
]
# Excluded by the Marracat standard although no country bans it.
FOOD_EXCLUDED = [
    ("high-fructose corn syrup", r"high[- ]fructose|\bhfcs\b|glucose-fructose syrup|isoglucose|corn syrup solids",
     "Marracat standard (owner, 2026-10-08); not banned anywhere"),
]
# Allowed but noted.
FOOD_NOTED = [
    ("BHA / BHT", r"\bbha\b|\bbht\b|butylated hydroxy"),
    ("caramel colour", r"caramel colou?r"),
    ("carrageenan", r"carrageenan"),
    ("sodium nitrite", r"nitrite"),
]

LABEL = re.compile(r"\bingredients?\s*(?:[:\-–]+|\bare\b)\s*", re.I)
END = re.compile(r"(?:\.\s+(?=[A-Z])|\s[|•]\s|\bcontains?\s*:|\ballergen|\bnutrition|\bdirections?\b|\bstorage\b|"
                 r"\bnet (wt|weight)\b|\bmay contain\b|\bproduced in\b|\bmanufactured in\b|\bbest (before|by)\b|"
                 r"\bhow to\b|\bbrewing\b|\bsteep\b|\bserving\b|\bnote:|\bproduct details\b|\bdetails\s*:|\bsize\s*:|"
                 r"\bweight\s*:|\bshipping\b)", re.I)


def split_top(text):
    """Comma-separated items, keeping "(...)" sub-lists inside their item."""
    out, depth, cur = [], 0, []
    for ch in text:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth = max(0, depth - 1)
        if ch == "," and depth == 0:
            out.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    out.append("".join(cur))
    return [o.strip(" .;*") for o in out if o.strip(" .;*")]


def extract_food(text):
    """The labelled ingredient list in `text`, or ""."""
    if not text:
        return ""
    text = html.unescape(re.sub(r"<[^>]+>", " ", text))
    text = re.sub(r"\s+", " ", text)
    best = ""
    for m in LABEL.finditer(text):
        chunk = text[m.end():m.end() + 1500]
        stop = END.search(chunk)
        chunk = chunk[:stop.start()] if stop else chunk[:600]
        items = [i for i in split_top(chunk) if len(i) <= 120 and len(i.split()) <= 14]
        # Marketing copy after the label ("Features red pepper and garlic for
        # bold flavor") isn't a list.
        if not items or re.search(r"\b(features|for (bold|a|the)|perfect|delicious)\b", items[0], re.I):
            continue
        joined = ", ".join(items)
        if len(joined) > len(best):
            best = joined
    return best


ALCOHOL = re.compile(r"\b(wine|rum|whiske?y|vodka|tequila|gin|beer|liquor|liqueur|champagne|prosecco|bourbon|"
                     r"cognac|brandy|hennessy|spirits?|alcohol(?:ic)?|cider|sake|mezcal)\b", re.I)


def eligible(product):
    if product.get("category") != "grocery":
        return False
    text = f"{product.get('title') or ''} {product.get('product_type') or ''}"
    if not NOT_FOOD.search(text):
        # Some cosmetics are filed under grocery ("Cocoa Amber Mist", a body
        # mist, wore the food badge, 2026-10-09): Jev checks every grocery
        # product, and a sure "not food" is never eligible.
        return not el.jev_says_no("food_check", product)
    # Jev can bring back a tea or coffee a keyword shut out, never alcohol: the
    # standard leaves alcohol out (Jev said yes to rum punch and wine, 2026-10-09).
    return el.jev_says("food", product) and not ALCOHOL.search(f"{text} {product.get('description') or ''}"[:600])


def list_for(product, store):
    return extract_food(product.get("description") or "") or store.get(product["url"], "")


def evaluate(product, ingredients):
    """-> (passes: bool, failures: [str], notes: [str])"""
    failures, notes = [], []
    if not ingredients:
        return False, ["no published ingredient list"], notes
    toks = [t.strip().lower() for t in re.split(r",|\(|\)|;", ingredients) if t.strip()]
    for label, pattern, _source in FOOD_BANNED + FOOD_EXCLUDED:
        rx = re.compile(pattern, re.I)
        hits = sorted({t for t in toks if rx.search(t) and "free" not in t and "no " not in t})
        if hits:
            failures.append(f"{label}: {', '.join(hits[:3])}")
    for label, pattern in FOOD_NOTED:
        rx = re.compile(pattern, re.I)
        if any(rx.search(t) for t in toks):
            notes.append(label)
    return not failures, failures, notes


def apply(products, store):
    """Rewrite `food` on every product. Returns report inputs."""
    stats = {"eligible": 0, "listed": 0, "passed": 0}
    failed_by, noted_by, brands = {}, {}, set()
    for p in products:
        p.pop("food", None)
        if not eligible(p):
            continue
        stats["eligible"] += 1
        ingredients = list_for(p, store)
        if ingredients:
            stats["listed"] += 1
        ok, failures, notes = evaluate(p, ingredients)
        if ok:
            p["food"] = True
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
    lines = ["# Marracat Clean Food — badge report", "",
             f"{stats['eligible']} eligible foods and drinks · {stats['listed']} with a published list · "
             f"**{stats['passed']} badged** across {len(brands)} brands.", "",
             "The standard is in catalog/food_standard.md. A food without a published list is never badged; "
             "lists are read from the product's description, and from its page by `food_badge.py --scrape` "
             "(ship.sh runs it with a cap), so this count grows as pages are read.", "",
             "## Why products fail", "", "| Reason | Products |", "|---|---|"]
    lines += [f"| {k} | {v} |" for k, v in sorted(failed_by.items(), key=lambda kv: -kv[1])]
    lines += ["", "## Allowed but noted", "", "| Note | Products |", "|---|---|"]
    lines += [f"| {k} | {v} |" for k, v in sorted(noted_by.items(), key=lambda kv: -kv[1])] or ["| none | 0 |"]
    lines += ["", "## Badged brands", "", ", ".join(brands) or "none yet", ""]
    REPORT.write_text("\n".join(lines))


def scrape(products, store, misses, max_new, fetch=None):
    """Fetch the pages of eligible foods whose description has no list, one at
    a time with Clean's politeness delay, and store what this module's food
    extractor finds (ingredient_lists' extractor is tuned for cosmetics)."""
    import datetime as dt
    import time
    fetch = fetch or cb.fetch_page
    today = dt.date.today().isoformat()
    stale = (dt.date.today() - dt.timedelta(days=cb.MISS_TTL_DAYS)).isoformat()
    urls = [p["url"] for p in products if eligible(p) and not extract_food(p.get("description") or "")
            and p["url"] not in store and misses.get(p["url"], "") <= stale]
    if max_new:
        urls = urls[:max_new]
    print(f"fetching {len(urls)} food pages", file=sys.stderr)
    found = 0
    for url in urls:
        try:
            got = extract_food(fetch(url))
        except Exception as e:  # noqa: BLE001 — one bad page must not stop the run
            print(f"  ! {url}: {str(e)[:80]}", file=sys.stderr)
            got = ""
        if got:
            store[url] = got
            found += 1
        else:
            misses[url] = today
        time.sleep(cb.DELAY)
    print(f"found food lists on {found} of {len(urls)} pages", file=sys.stderr)
    return found, len(urls)


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
        scrape(products, store, misses, args.max_new)
        il.save(store, misses)
    if args.explain:
        p = next((p for p in products if p["id"] == args.explain), None)
        if not p:
            sys.exit(f"no product {args.explain}")
        ingredients = list_for(p, store)
        ok, failures, notes = evaluate(p, ingredients)
        print(f"{p['title']} ({p['brand']})\n  eligible: {eligible(p)}\n  list: {ingredients[:300] or '—'}\n"
              f"  verdict: {'CLEAN FOOD' if ok else 'not badged'}\n  failures: {failures}\n  notes: {notes}")
        return
    stats, failed_by, noted_by, brands = apply(products, store)
    if not args.report_only:
        write_catalog(CATALOG, catalog)
    write_report(stats, failed_by, noted_by, brands)
    print(f"clean food badge: {stats['passed']} badged of {stats['listed']} listed "
          f"({stats['eligible']} eligible) — {REPORT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
