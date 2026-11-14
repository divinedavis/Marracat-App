#!/usr/bin/env python3
"""Ask TypeSafe's Jev model to re-file the products the keyword categoriser is
least sure about.

audit_categories.py already knows which products are risky (brand fallback,
narrow margin, a single ambiguous word). This sends only those to Jev as one
Choice question over the department list, and caches every verdict in
catalog/jev_categories.json. build_catalog.py applies a verdict when Jev is
confident and the product's title/type/tags haven't changed since it was asked.

A verdict is keyed by a hash of what Jev saw, so a rerun only pays for new or
edited products. The cache is committed, so builds never need the API key.

    python3 catalog/jev_categories.py --limit 50      # pilot: ask 50, print the moves
    python3 catalog/jev_categories.py                 # every flagged product not yet cached
    python3 catalog/jev_categories.py --report        # moves already in the cache, no calls
    python3 catalog/jev_categories.py --all --limit 12000   # every product, not only flagged
                                                      # (owner, 2026-10-03; ~$0.055 per 1,000)

Needs TYPESAFE_API_KEY (see ~/.config/typesafe/api_key).
"""
import argparse
import asyncio
import json
import pathlib
import random
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import audit_categories as audit  # noqa: E402
import build_catalog as bc  # noqa: E402

VERDICTS = HERE / "jev_categories.json"
# Choice confidence rescales the winner's probability against a uniform guess
# over ~30 departments; 0.85 means the winner holds roughly 85%+ of the mass.
MIN_CONFIDENCE = 0.85
# $0.042 per million input tokens (typesafe.ai pricing, output is free). A full
# pass over ~7k products is ~3.5M tokens, about 15 cents; this stops a runaway.
MAX_CALLS = 12000
CONCURRENCY = 16

# One line per department so Jev picks on meaning, not on our keyword lists.
HINTS = {
    "bags": "Handbags, totes, backpacks, wallets, pouches",
    "fragrance": "Perfume, cologne, body mist, fragrance oil worn on the body",
    "clothing": "Garments worn on the body: tops, dresses, pants, lingerie, swimwear, outerwear",
    "jewelry": "Necklaces, earrings, rings, bracelets, waist beads, body jewelry",
    "skincare": "Face and body skin products: cleansers, serums, moisturizers, body butter, soap, sunscreen",
    "makeup": "Color cosmetics: foundation, lipstick, lip gloss, eyeshadow, lashes, brushes",
    "hair": "Hair products and tools: shampoo, conditioner, oils, wigs, extensions, bonnets, combs",
    "accessories": "Hats, scarves, sunglasses, belts, headbands, keychains, phone cases",
    "home": "Candles, home fragrance, decor, bedding, kitchenware, drinkware, wall art",
    "household": "Cleaning supplies, laundry detergent, dish soap, paper goods",
    "wellness": "Supplements, vitamins, herbal remedies, sexual wellness, deodorant, oral care, feminine care",
    "grocery": "Food and non-alcoholic drinks: snacks, coffee, tea, sauces, spices",
    "baby": "Products made for babies and children",
    "pets": "Pet food, treats, toys and gear",
    "toys": "Toys, games, puzzles, dolls",
    "sports": "Fitness and sports gear, activewear equipment, outdoor recreation",
    "books": "Books, journals with content, magazines, music, films, digital downloads",
    "crafts": "Art and craft supplies, sewing, knitting, crochet, painting kits",
    "office": "Stationery, notebooks, planners, pens, desk supplies",
    "tools": "Tools and home improvement hardware",
    "electronics": "Electronic devices, chargers, headphones, speakers",
    "shoes": "Footwear: sneakers, sandals, heels, boots, slippers",
    "luggage": "Suitcases and travel gear",
    "garden": "Plants, seeds, gardening supplies, outdoor furniture",
    "auto": "Car accessories and car care",
    "music": "Musical instruments and gear",
    "party": "Gift boxes, gift sets of mixed items, gift wrap, greeting cards, party supplies",
    "alcohol": "Wine, spirits, beer and other alcoholic drinks",
}


def state_for(p, brand):
    """What Jev sees about one product. Changing this re-asks every product."""
    return {
        "product": p["title"],
        "product_type": p.get("product_type") or "",
        "tags": (p.get("tags") or [])[:10],
        "description": (p.get("description") or "")[:500],
        "brand": brand["name"],
        "brand_usually_sells": bc.CATEGORIES_BY_ID.get(brand["category"], brand["category"]),
    }


def input_key(p):
    return bc.jev_key(p)


def question():
    from typesafe_sdk import Choice
    return Choice(
        instructions="Which store department should this product be listed under? Judge what the "
                     "item itself is, not the brand. A scent a person wears is Fragrance; a candle "
                     "or room spray is Candles & Home.",
        criteria={c["id"]: f"{c['name']}: {HINTS[c['id']]}" for c in bc.CATEGORIES if c["id"] in HINTS},
    )


async def ask_all(todo, brands_by_id):
    from typesafe_sdk import AsyncTypeSafeClient
    sem = asyncio.Semaphore(CONCURRENCY)
    q = question()
    out, tokens, failed = {}, 0, 0
    stop = asyncio.Event()

    async def one(client, p):
        nonlocal tokens, failed
        async with sem:
            if stop.is_set():
                failed += 1
                return
            try:
                r = await client.system_one(state=state_for(p, brands_by_id[p["brand"]]),
                                            questions={"dept": q})
            except Exception as e:  # noqa: BLE001 — one bad product must not sink the run
                # Out of credits (402) fails every call after it: stop asking and
                # keep what was answered, instead of 12,000 failures (2026-10-03).
                if " 402 " in str(e):
                    stop.set()
                failed += 1
                print(f"  ! {p['id']}: {type(e).__name__}: {e}", file=sys.stderr)
                return
        a = r.answers["dept"]
        tokens += r.usage.input_tokens
        out[p["id"]] = {"seen": input_key(p), "choice": a.choice, "confidence": round(a.confidence, 3),
                        "p": round(a.probabilities[a.choice], 3), "was": p["category"]}
        if len(out) % 250 == 0:
            print(f"  {len(out)}/{len(todo)} …")

    async with AsyncTypeSafeClient() as client:
        await asyncio.gather(*(one(client, p) for p in todo))
    if stop.is_set():
        print("  ! TypeSafe is out of credits (HTTP 402): add credits at "
              "https://console.typesafe.ai/settings/billing, then rerun", file=sys.stderr)
    return out, tokens, failed


def load():
    return json.loads(VERDICTS.read_text()) if VERDICTS.exists() else {}


def confident(v):
    return bc.jev_confident(v)


# Second opinion (owner, 2026-11-12): Perplexity's Decider v1.2 through Vercel
# AI Gateway, asked exactly what Jev was asked, for the unsure verdicts that
# would move a product. bc.jev_confident() decides what counts. About $8 per
# million questions on 2026-11-12, so the cap is a runaway stop, not a budget.
SECOND_MODEL = "perplexity/pplx-decider-v1.2"
SECOND_URL = "https://ai-gateway.vercel.sh/v1/decisions"
MAX_SECOND_CALLS = 8000


def gateway_key():
    import os
    path = pathlib.Path.home() / ".config" / "vercel" / "ai_gateway_key"
    return os.environ.get("AI_GATEWAY_API_KEY") or (path.read_text().strip() if path.exists() else "")


def needs_second(v, p):
    """An unsure verdict that would move `p` and has no second opinion for its input."""
    return (v and bc.JEV_SECOND_FLOOR <= v["confidence"] < bc.JEV_MIN_CONFIDENCE
            and v["choice"] != p["category"] and v["seen"] == input_key(p)
            and (v.get("second") or {}).get("seen") != v["seen"])


def ask_second(todo, brands_by_id, key, workers=8):
    """{product id: {"model", "choice", "p", "seen"}} from Decider. A call that
    fails after retries is left out, so the verdict stays unsure: no move."""
    import time
    import urllib.request
    from concurrent.futures import ThreadPoolExecutor
    q = question()
    gq = {"type": "choice", "name": "dept", "instructions": q.instructions,
          "choices": [{"value": k, "description": d} for k, d in q.criteria.items()]}

    def one(item):
        p, seen = item
        body = json.dumps({"model": SECOND_MODEL, "questions": [gq], "input": [
            {"role": "user", "content": [{"type": "input_json", "data": state_for(p, brands_by_id[p["brand"]])}]}]}).encode()
        for attempt in range(5):
            req = urllib.request.Request(SECOND_URL, data=body, method="POST",
                                         headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    ans = (json.loads(r.read()).get("answers") or [{}])[0]
            except Exception as e:  # noqa: BLE001 — 503s come in bursts (pilot, 2026-11-12)
                if attempt == 4:
                    print(f"  ! second {p['id']}: {type(e).__name__}", file=sys.stderr)
                    return p["id"], None
                time.sleep(3 * (attempt + 1))
                continue
            probs = {x.get("value"): x.get("probability", 0.0) for x in ans.get("probabilities") or []}
            if not ans.get("choice"):
                return p["id"], None
            return p["id"], {"model": SECOND_MODEL, "choice": ans["choice"],
                             "p": round(probs.get(ans["choice"], 0.0), 3), "seen": seen}
        return p["id"], None

    with ThreadPoolExecutor(workers) as ex:
        return {pid: s for pid, s in ex.map(one, todo) if s}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0, help="ask at most this many (pilot)")
    ap.add_argument("--report", action="store_true", help="print moves from the cache, no API calls")
    ap.add_argument("--all", action="store_true", help="ask about every product, not only the audit's flagged ones")
    ap.add_argument("--no-second", action="store_true", help="skip Decider's second opinion on unsure moves")
    ap.add_argument("--second-only", action="store_true", help="ask Decider about cached unsure moves; no new Jev calls")
    args = ap.parse_args()

    catalog = json.loads(audit.CATALOG.read_text())
    brands = json.loads(audit.BRANDS.read_text())
    by_id = {b["id"]: b for b in brands}
    products = {p["id"]: p for p in catalog["products"]}
    verdicts = load()

    if not args.report:
        todo = []
        if not args.second_only:
            findings = audit.audit(list(products.values()), brands, verdicts={})
            flagged = sorted(products) if args.all else sorted({p["id"] for g in findings.values() for p in g})
            todo = [products[i] for i in flagged
                    if i not in verdicts or verdicts[i]["seen"] != input_key(products[i])]
        if args.limit:
            todo = random.Random(7).sample(todo, min(args.limit, len(todo)))
        if len(todo) > MAX_CALLS:
            sys.exit(f"{len(todo)} calls is over MAX_CALLS={MAX_CALLS}; raise it deliberately")
        if not args.second_only:
            print(f"{len(flagged)} flagged, asking Jev about {len(todo)}")
        if todo:
            new, tokens, failed = asyncio.run(ask_all(todo, by_id))
            verdicts.update(new)
            VERDICTS.write_text(json.dumps(dict(sorted(verdicts.items())), indent=1) + "\n")
            print(f"{len(new)} answered, {failed} failed, {tokens:,} input tokens "
                  f"(~${tokens * 0.042 / 1e6:.3f})")

        second = [(products[pid], v["seen"]) for pid, v in verdicts.items()
                  if pid in products and needs_second(v, products[pid])]
        key = gateway_key()
        if second and args.no_second:
            print(f"second opinion: skipped (--no-second), {len(second)} unsure moves wait")
        elif second and not key:
            print(f"second opinion: skipped (no AI_GATEWAY_API_KEY), {len(second)} unsure moves wait")
        elif second:
            if len(second) > MAX_SECOND_CALLS:
                sys.exit(f"{len(second)} Decider calls is over MAX_SECOND_CALLS={MAX_SECOND_CALLS}; raise it deliberately")
            print(f"second opinion: asking {SECOND_MODEL} about {len(second)} unsure moves")
            got = ask_second(second, by_id, key)
            for pid, s2 in got.items():
                verdicts[pid]["second"] = s2
            VERDICTS.write_text(json.dumps(dict(sorted(verdicts.items())), indent=1) + "\n")
            agreed = sum(bc.jev_confident(verdicts[pid]) for pid in got)
            print(f"  {len(got)} answered, {len(second) - len(got)} failed, {agreed} now agree with Jev")

    names = bc.CATEGORIES_BY_ID
    moves = [(pid, v) for pid, v in verdicts.items()
             if pid in products and confident(v) and v["choice"] != products[pid]["category"]
             and v["seen"] == input_key(products[pid])]
    kept = sum(1 for pid, v in verdicts.items() if pid in products and confident(v)
               and v["choice"] == products[pid]["category"])
    unsure = sum(1 for pid, v in verdicts.items() if pid in products and not confident(v))
    print(f"\ncached verdicts: {len(verdicts)} — confirmed {kept}, would move {len(moves)}, unsure {unsure}")
    for pid, v in moves[:60 if args.limit or args.report else 25]:
        p = products[pid]
        print(f"  {names[p['category']]:<20} -> {names[v['choice']]:<20} {v['confidence']:.2f}  "
              f"{p['title'][:60]}")


if __name__ == "__main__":
    main()
