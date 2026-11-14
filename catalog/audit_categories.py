#!/usr/bin/env python3
"""Audit how every product got its category, and flag the ones most likely wrong.

The categoriser is keyword scoring, so its mistakes are predictable. This finds
them by re-running the scoring and asking, per product, *why* the winner won:

  fallback   nothing matched, so the product took its brand's category — only
             risky for brands that sell across several departments
  tag-only   only the brand's own tags matched, never the title or product type
  narrow     the runner-up was within MARGIN, so one word decided it
  ambiguous  the winner matched on a single word that another department also
             claims ("top", "wine", "gel", "detergent") — every misfile found
             by hand so far has been one of these

Run it after a build:
    python3 catalog/audit_categories.py
    python3 catalog/audit_categories.py --sample 40   # print a random sample to read
    python3 catalog/audit_categories.py --max-risky 12   # non-zero exit above that %
"""
import argparse
import collections
import json
import pathlib
import random
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import build_catalog as bc  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Marracat" / "Resources" / "catalog.json"
BRANDS = ROOT / "catalog" / "brands.json"
MARGIN = 1.0


def score_table(product, brand):
    """Every category's score, and the longest keyword that earned it."""
    tags = product.get("tags") or []
    fields = [(product.get("product_type") or "", 3.0), (product.get("title") or "", 2.0),
              (" ".join(tags), 0.5)]
    table = {}
    for cat, pats in bc._patterns.items():
        total, named, best_kw, tag_only = 0.0, False, "", True
        for i, (text, weight) in enumerate(fields):
            if not text:
                continue
            hits = [k for k, p in pats if p.search(text)]
            if hits:
                longest = max(hits, key=lambda k: len(k.split()))
                total += weight * (1 + 0.4 * (len(longest.split()) - 1))
                if len(longest.split()) > len(best_kw.split()):
                    best_kw = longest
                if i < 2:
                    named, tag_only = True, False
        if not named:
            total = 0.0
        if total and any(p.search(f"{fields[0][0]} {fields[1][0]}")
                         for p in bc.DISQUALIFY.get(cat, [])):
            total = 0.0
        if cat == "alcohol" and brand["category"] != "alcohol":
            total = 0.0
        if total:
            table[cat] = (total + (1.5 if cat == brand["category"] else 0), best_kw, tag_only)
    return table


def load_verdicts():
    return json.loads(bc.JEV_FILE.read_text()) if bc.JEV_FILE.exists() else {}


def ambiguous_words():
    """Single words that more than one department claims."""
    seen = collections.Counter()
    for cat, kws in bc.KEYWORDS.items():
        for k in kws:
            if len(k.split()) == 1:
                seen[k] += 1
    return {w for w, n in seen.items() if n > 1}


def audit(products, brands, verdicts=None):
    by_id = {b["id"]: b for b in brands}
    findings = collections.defaultdict(list)
    shared = ambiguous_words()
    # A brand's default is a guess when its own products span departments.
    spread = collections.defaultdict(set)
    for p in products:
        spread[p["brand"]].add(p["category"])
    verdicts = load_verdicts() if verdicts is None else verdicts
    for p in products:
        brand = by_id.get(p["brand"])
        if not brand:
            continue
        # Jev read it and agreed with where it sits (or moved it there).
        v = verdicts.get(p["id"])
        if (bc.jev_confident(v) and v["choice"] == p["category"]
                and v["seen"] == bc.jev_key(p)):
            findings["jev-settled"].append(p)
            continue
        table = score_table(p, brand)
        if not table:
            if len(spread[p["brand"]]) >= 3:
                findings["fallback"].append(p)
            continue
        ranked = sorted(table.items(), key=lambda kv: -kv[1][0])
        (_win_cat, (win_score, win_kw, win_tag_only)) = ranked[0]
        if win_tag_only:
            findings["tag-only"].append(p)
        if len(ranked) > 1 and win_score - ranked[1][1][0] < MARGIN:
            findings["narrow"].append(p)
        if win_kw and len(win_kw.split()) == 1 and win_kw in shared:
            findings["ambiguous"].append(p)
    return findings


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sample", type=int, default=0, help="print this many random flagged products")
    ap.add_argument("--max-risky", type=float, default=None,
                    help="exit non-zero if more than this %% of products are flagged")
    args = ap.parse_args()

    catalog = json.loads(CATALOG.read_text())
    brands = json.loads(BRANDS.read_text())
    products = catalog["products"]
    names = {c["id"]: c["name"] for c in catalog["categories"]}
    findings = audit(products, brands)

    settled = len(findings.pop("jev-settled", []))
    flagged = {p["id"] for group in findings.values() for p in group}
    print(f"{len(products)} products, {len(flagged)} flagged ({len(flagged) * 100 / len(products):.1f}%)\n")
    print(f"  jev-settled {settled:>4}  (Jev confirmed or re-filed; not counted)")
    for kind in ("fallback", "tag-only", "narrow", "ambiguous"):
        group = findings[kind]
        print(f"  {kind:<10} {len(group):>5}  ({len(group) * 100 / len(products):.1f}%)")
        worst = collections.Counter(names.get(p["category"], p["category"]) for p in group)
        print(f"             {', '.join(f'{c} {n}' for c, n in worst.most_common(4))}")

    if args.sample:
        print(f"\nrandom sample of {args.sample} flagged products to read:")
        random.seed(7)
        for p in random.sample(sorted(flagged), min(args.sample, len(flagged))):
            prod = next(x for x in products if x["id"] == p)
            print(f"  {names.get(prod['category'], prod['category']):<22} {prod['title'][:52]:<54}"
                  f" type={(prod.get('product_type') or '-')[:24]!r}")

    if args.max_risky is not None:
        pct = len(flagged) * 100 / len(products)
        if pct > args.max_risky:
            print(f"\nerror: {pct:.1f}% flagged, over the {args.max_risky}% the build allows",
                  file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
