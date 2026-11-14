#!/usr/bin/env python3
"""Ask TypeSafe's Jev whether the products no keyword can place are what a
label covers.

Clear Scent and Safer Clean decide eligibility by words in the title, type,
URL handle and tags (eligibility.py). Some products say nothing: perfumes
titled "Symphony 15 ML" or "CASABLANCA", a "Supersalt Brightening Powder".
This sends only those leftovers to Jev as one yes/no (Noul) question per
label and caches each answer in catalog/jev_eligibility.json, keyed by what
Jev saw, so a rerun only pays for new or edited products. The cache is
committed, so builds never need the API key. A yes at p >= 0.85 makes the
product eligible; the label's own rules still decide whether it's badged.

    python3 catalog/jev_eligibility.py --dry-run   # count what would be asked
    python3 catalog/jev_eligibility.py             # ask, then rewrite the cache

Needs TYPESAFE_API_KEY (~/.config/typesafe/api_key). ~$0.042 per million
input tokens; ~420 tokens a product, so 1,000 products cost about 2 cents.
"""
import argparse
import asyncio
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import eligibility as el  # noqa: E402
import clean_badge as cb  # noqa: E402
import fiber_badge as fb  # noqa: E402
import food_badge as fd  # noqa: E402
import safer_clean_badge as sc  # noqa: E402
import scent_badge as sb  # noqa: E402
from candle_badge import is_candle  # noqa: E402

CATALOG = HERE.parent / "Marracat" / "Resources" / "catalog.json"
MAX_CALLS = 15000
CONCURRENCY = 16

LABELS = {
    "scent": {
        "category": "fragrance", "module": sb, "exclude": sb.NOT_SCENT,
        "exclude_subs": {"fragrance-set", "discovery", "fragrance-bath"},
        "instructions": "Is this product a fragrance a person wears on the body: a perfume, cologne, "
                        "eau de parfum, body mist, perfume oil or solid perfume?",
        "criteria": {"true": "A wearable fragrance, in any size",
                     "false": "Anything else: candles, room or car scent, sets of several products, "
                              "bottles or cases, accessories, bath or skin products"},
    },
    "safer": {
        "category": "household", "module": sc, "exclude": sc.NOT_CLEANER,
        "exclude_subs": {"cleaning-tools", "paper", "air-care", "hand-soap"},
        "instructions": "Is this product a cleaning, laundry or dishwashing product: something whose "
                        "ingredients do the cleaning, like a detergent, cleaner, softener or stain remover?",
        "criteria": {"true": "A cleaning, laundry or dish product with a formula",
                     "false": "A tool, container, bag, paper good, air freshener, bundle of several "
                              "products, clothing, or anything that isn't a cleaning formula"},
    },
    # Every product in these categories that no rule checks, whatever the
    # reason (owner, 2026-10-09: "make sure other products aren't missed").
    "beauty": {
        "categories": {"hair", "makeup", "skincare"}, "checked": lambda p: cb.family(p) is not None,
        "instructions": "Is this one beauty product with its own formula — a hair, skin, body or makeup "
                        "product a person applies, which would have an ingredient list?",
        "criteria": {"true": "One product with its own ingredient list: shampoo, cream, serum, lipstick, oil…",
                     "false": "A tool, wig, extension, bonnet, brush, accessory, gift card, or a bundle or set "
                              "of several products"},
    },
    "food": {
        "categories": {"grocery"}, "checked": fd.eligible,
        "instructions": "Is this a food or drink a person eats or drinks — something that would have an "
                        "ingredient list, including tea and coffee?",
        "criteria": {"true": "A food, drink, tea, coffee, spice, sauce or snack",
                     "false": "A mug, tumbler, infuser, strainer, sticker, merchandise or other non-food item"},
    },
    # Every grocery product the keywords accept, asked once more: is it food?
    "food_check": {
        "categories": {"grocery"}, "checked": lambda p: not fd.eligible(p),
        "instructions": "Is this a food or drink a person eats or drinks — something that would have an "
                        "ingredient list, including tea and coffee?",
        "criteria": {"true": "A food, drink, tea, coffee, spice, sauce or snack",
                     "false": "A soap, body mist, lotion, bath soak, shampoo, candle, room spray, mug, "
                              "sticker or anything else people don't eat or drink"},
    },
    "garment": {
        "categories": {"clothing"}, "checked": fb.eligible,
        "instructions": "Is this a garment a person wears — clothing whose fibre content could be stated?",
        "criteria": {"true": "A garment: top, dress, pants, leggings, jacket, underwear, socks…",
                     "false": "A sticker, poster, art print, mug, pin, gift card, digital pattern or other "
                              "non-garment"},
    },
}


def leftovers(products, label):
    cfg = LABELS[label]
    out = []
    for p in products:
        if "categories" in cfg:
            if p.get("category") in cfg["categories"] and not cfg["checked"](p) and not is_candle(p):
                out.append(p)
            continue
        if p.get("category") != cfg["category"] or is_candle(p):
            continue
        if cfg["exclude"].search(el.exclusion_text(p)) or set(p.get("subs") or []) & cfg["exclude_subs"]:
            continue
        if cfg["module"].eligible(p):
            continue
        out.append(p)
    return out


def state_for(p, brand):
    return {"product": p.get("title") or "", "product_type": p.get("product_type") or "",
            "url_words": el.handle_words(p), "tags": (p.get("tags") or [])[:10],
            "description": (p.get("description") or "")[:500], "brand": brand.get("name", ""),
            "brand_usually_sells": brand.get("category", "")}


async def ask(todo, brands):
    from typesafe_sdk import AsyncTypeSafeClient, Noul
    sem = asyncio.Semaphore(CONCURRENCY)
    out, tokens, failed = {}, 0, 0

    async def one(client, label, p):
        nonlocal tokens, failed
        cfg = LABELS[label]
        async with sem:
            try:
                r = await client.system_one(state=state_for(p, brands.get(p["brand"], {})),
                                            questions={"q": Noul(instructions=cfg["instructions"], criteria=cfg["criteria"])})
            except Exception as e:  # noqa: BLE001 — one product must not sink the run
                failed += 1
                print(f"  ! {label} {p['id']}: {type(e).__name__}: {e}", file=sys.stderr)
                return
        tokens += r.usage.input_tokens
        out.setdefault(label, {})[p["id"]] = {"seen": el.seen_key(p), "p": round(r.answers["q"].noul, 3),
                                              "title": (p.get("title") or "")[:80]}

    async with AsyncTypeSafeClient() as client:
        await asyncio.gather(*(one(client, label, p) for label, p in todo))
    return out, tokens, failed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    catalog = json.loads(CATALOG.read_text())
    brands = {b["id"]: b for b in catalog["brands"]}
    cache = json.loads(el.VERDICTS.read_text()) if el.VERDICTS.exists() else {}
    todo = []
    for label in LABELS:
        for p in leftovers(catalog["products"], label):
            v = cache.get(label, {}).get(p["id"])
            if not v or v.get("seen") != el.seen_key(p):
                todo.append((label, p))
    print(f"{len(todo)} to ask ({', '.join(f'{l}: {sum(1 for x, _ in todo if x == l)}' for l in LABELS)})")
    if args.dry_run or not todo:
        return
    todo = todo[:MAX_CALLS]
    got, tokens, failed = asyncio.run(ask(todo, brands))
    for label, verdicts in got.items():
        cache.setdefault(label, {}).update(verdicts)
    el.VERDICTS.write_text(json.dumps(cache, indent=1, ensure_ascii=False, sort_keys=True) + "\n")
    yes = {l: sum(1 for v in got.get(l, {}).values() if v["p"] >= el.MIN_P) for l in LABELS}
    print(f"asked {sum(len(v) for v in got.values())}, failed {failed}, {tokens} input tokens "
          f"(~${tokens * 0.042 / 1e6:.4f}); eligible now: {yes}")


if __name__ == "__main__":
    main()
