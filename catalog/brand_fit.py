#!/usr/bin/env python3
"""Products filed far from what their brand sells, checked by Jev.

A bath-and-body brand's soap in Grocery, or its gift box in Party, is almost
always a misfile (Lillie Mae, 2026-10-10). This finds every product in a
department its brand rarely uses — the brand has at least MIN_BRAND_PRODUCTS
products, at least MAIN_SHARE of them in one department, and this product's
department holds at most RARE_SHARE of them — and asks TypeSafe's Jev one
yes/no (Noul) question: should it be listed under the brand's main department
instead? A yes at p >= MIN_P moves it.

Verdicts are cached in catalog/jev_brand_fit.json, keyed by what Jev saw
(build_catalog.jev_key), so a rerun only pays for new or edited products, and
the cache is committed so builds never need the key. build_catalog.py applies
the cache too, so a --only rebuild keeps the moves.

Never touched: a hand-reviewed pin (brands.json product_categories entry that
differs from the keyword guess) or a confident jev_categories.json verdict.

    python3 catalog/brand_fit.py              # apply cached verdicts + report, no calls
    python3 catalog/brand_fit.py --ask        # ask Jev about flagged, uncached products first
    python3 catalog/brand_fit.py --ask --limit 50 --dry-run   # pilot, catalog untouched

--ask reads TYPESAFE_API_KEY, or ~/.config/typesafe/api_key when it isn't
set. $0.042 per million input tokens; ~450 tokens a question, so the
MAX_CALLS cap of 2,000 a run costs at most about 4 cents.
"""
import argparse
import asyncio
import collections
import json
import os
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import build_catalog as bc  # noqa: E402
import department_rules as dr  # noqa: E402
from taxonomy import flat_subcategories, subcategories_of, with_added_aisles  # noqa: E402
from catalog_io import write_catalog  # noqa: E402

ROOT = HERE.parent
CATALOG = ROOT / "Marracat" / "Resources" / "catalog.json"
BRANDS = HERE / "brands.json"
VERDICTS = HERE / "jev_brand_fit.json"
REPORT = HERE / "brand_fit_report.md"
KEY_FILE = pathlib.Path.home() / ".config" / "typesafe" / "api_key"

MIN_BRAND_PRODUCTS = 8
MAIN_SHARE = 0.6
RARE_SHARE = 0.05
MIN_P = 0.85
MAX_CALLS = 2000
CONCURRENCY = 16
PRICE_PER_M_TOKENS = 0.042


def brand_mains(products):
    """{brand: (main department, its share, product count)}."""
    counts = collections.defaultdict(collections.Counter)
    for p in products:
        counts[p["brand"]][p["category"]] += 1
    out = {}
    for b, c in counts.items():
        dept, n = c.most_common(1)[0]
        out[b] = (dept, n / sum(c.values()), sum(c.values()), c)
    return out


def flagged(products, brands_by_id):
    """[(product, main department)] for products far from their brand's mix."""
    mains = brand_mains(products)
    out = []
    for p in products:
        brand = brands_by_id.get(p["brand"])
        if not brand:
            continue
        main, share, total, counts = mains[p["brand"]]
        if total < MIN_BRAND_PRODUCTS or share < MAIN_SHARE or p["category"] == main:
            continue
        if counts[p["category"]] > max(1, RARE_SHARE * total):
            continue                      # the brand really sells this department too
        if dr.placed_on_purpose(p, brand, bc):
            continue
        out.append((p, main))
    return out


def state_for(p, brand, main):
    return {
        "product": p["title"],
        "product_type": p.get("product_type") or "",
        "tags": (p.get("tags") or [])[:10],
        "description": (p.get("description") or "")[:400],
        "brand": brand["name"],
        "brand_mostly_sells": bc.CATEGORIES_BY_ID.get(main, main),
        "listed_now_under": bc.CATEGORIES_BY_ID.get(p["category"], p["category"]),
    }


def question(main, current):
    from typesafe_sdk import Noul
    from jev_categories import HINTS
    m, c = bc.CATEGORIES_BY_ID.get(main, main), bc.CATEGORIES_BY_ID.get(current, current)
    return Noul(
        instructions=f"Should this product be listed under {m} ({HINTS.get(main, m)}) rather than {c}? "
                     "Judge what the item itself is, not the brand.",
        criteria={"true": f"It is a {m} item (a gift set or bundle of {m} items counts)",
                  "false": f"It is really a {c} item, or something else that isn't {m}"})


async def ask_all(todo, brands_by_id):
    from typesafe_sdk import AsyncTypeSafeClient
    sem = asyncio.Semaphore(CONCURRENCY)
    out, tokens, failed = {}, 0, 0
    stop = asyncio.Event()

    async def one(client, p, main):
        nonlocal tokens, failed
        async with sem:
            if stop.is_set():
                failed += 1
                return
            try:
                r = await client.system_one(state=state_for(p, brands_by_id[p["brand"]], main),
                                            questions={"q": question(main, p["category"])})
            except Exception as e:  # noqa: BLE001 — one product must not sink the run
                if " 402 " in str(e):
                    stop.set()         # out of credits: every later call fails too
                failed += 1
                print(f"  ! {p['id']}: {type(e).__name__}: {e}", file=sys.stderr)
                return
        tokens += r.usage.input_tokens
        out[p["id"]] = {"seen": bc.jev_key(p), "main": main, "from": p["category"],
                        "p": round(r.answers["q"].noul, 3), "title": p["title"][:80]}

    async with AsyncTypeSafeClient() as client:
        await asyncio.gather(*(one(client, p, m) for p, m in todo))
    return out, tokens, failed


def load():
    return json.loads(VERDICTS.read_text()) if VERDICTS.exists() else {}


def apply(products, brands_by_id, verdicts=None):
    """Move products Jev confidently placed in their brand's main department.
    Returns [(product, old, new)]."""
    verdicts = load() if verdicts is None else verdicts
    moved = []
    for p in products:
        v = verdicts.get(p["id"])
        brand = brands_by_id.get(p["brand"])
        if (not v or not brand or v["p"] < MIN_P or v["seen"] != bc.jev_key(p)
                or p["category"] != v["from"] or v["main"] == p["category"]):
            continue
        if dr.placed_on_purpose(p, brand, bc):
            continue
        moved.append((p, p["category"], v["main"]))
        p["category"] = v["main"]
        p["subs"] = with_added_aisles(p, v["main"], subcategories_of(p, v["main"]))
    return moved


def load_key():
    if not os.environ.get("TYPESAFE_API_KEY") and KEY_FILE.exists():
        os.environ["TYPESAFE_API_KEY"] = KEY_FILE.read_text().strip()
    return bool(os.environ.get("TYPESAFE_API_KEY"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ask", action="store_true", help="ask Jev about flagged products not yet cached")
    ap.add_argument("--limit", type=int, default=MAX_CALLS, help=f"most questions this run (≤ {MAX_CALLS})")
    ap.add_argument("--dry-run", action="store_true", help="don't rewrite the catalog")
    args = ap.parse_args()

    catalog = json.loads(CATALOG.read_text())
    brands_by_id = {b["id"]: b for b in json.loads(BRANDS.read_text())}
    products = catalog["products"]
    verdicts = load()
    flags = flagged(products, brands_by_id)
    todo = [(p, m) for p, m in flags
            if p["id"] not in verdicts or verdicts[p["id"]]["seen"] != bc.jev_key(p)
            or verdicts[p["id"]]["main"] != m]
    spend = ""
    if args.ask and todo:
        todo = todo[:min(args.limit, MAX_CALLS)]
        if not load_key():
            print("brand fit: no TypeSafe key; applying cached verdicts only", file=sys.stderr)
        else:
            try:
                new, tokens, failed = asyncio.run(ask_all(todo, brands_by_id))
                verdicts.update(new)
                VERDICTS.write_text(json.dumps(dict(sorted(verdicts.items())), indent=0,
                                               ensure_ascii=False) + "\n")
                spend = (f"asked {len(new)} ({failed} failed), {tokens:,} input tokens, "
                         f"~${tokens * PRICE_PER_M_TOKENS / 1e6:.4f}")
                print(f"brand fit: {spend}")
            except Exception as e:  # noqa: BLE001 — Jev trouble must not stop a refresh
                print(f"brand fit: asking failed ({type(e).__name__}: {e}); applying cache only",
                      file=sys.stderr)

    moved = apply(products, brands_by_id, verdicts)
    if moved and not args.dry_run:
        used = {f"{p['category']}:{s}" for p in products for s in p["subs"]}
        catalog["subcategories"] = [s for s in flat_subcategories() if s["id"] in used]
        write_catalog(CATALOG, catalog)
    names = bc.CATEGORIES_BY_ID
    stayed = [(p, m) for p, m in flags if p["id"] in verdicts and verdicts[p["id"]]["p"] < MIN_P]
    lines = [f"# Brand fit report\n",
             f"{len(flags)} products sit in a department their brand rarely uses "
             f"(brand ≥{MIN_BRAND_PRODUCTS} products, ≥{MAIN_SHARE:.0%} in one department, "
             f"this one ≤{RARE_SHARE:.0%}). {'Moved' if not args.dry_run else 'Would move'} "
             f"{len(moved)} on a Jev yes (p ≥ {MIN_P}); {len(stayed)} Jev said belong where they are; "
             f"{len([1 for p, m in flags if p['id'] not in verdicts])} not asked yet."
             + (f" This run: {spend}." if spend else "") + "\n",
             "| Brand | Product | From | To |", "|---|---|---|---|"]
    lines += [f"| {p['brand']} | {p['title'][:60]} | {names.get(o, o)} | {names.get(n, n)} |"
              for p, o, n in moved[:300]]
    REPORT.write_text("\n".join(lines) + "\n")
    print(f"brand fit: {len(flags)} flagged, {len(moved)} moved, {len(stayed)} kept by Jev")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
