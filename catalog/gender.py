#!/usr/bin/env python3
"""Women / Men for clothing and shoes (owner, 2026-11-08: "for clothes do
some brands have a women and men filter? if so lets use it ... do it for
web/mobile").

Writes product["attrs"]["gender"]: ["women"], ["men"], or ["men", "women"]
for unisex. A shopper picking Women sees women's and unisex; Men likewise.
Kids (clothing > Kids & Baby, the baby department) are left out.

Signals, strongest first; the first that speaks decides:
1. The brand's own Shopify collections: a product listed in its "women",
   "womens", "for-her", "menswear", "unisex"... collections
   (catalog/gender_collections.json, refreshed by --fetch).
2. The product's own words: title, product type or tags say "Women's",
   "Mens", "Female", "Unisex" (both sides named = unisex).
3. An aisle only women's clothing has: dresses, skirts, bras, lingerie,
   and heels.
4. The brand: when at least 20 of its clothing products are labelled and
   95% of those are one side (no more than one the other way), the rest of
   its clothing takes that side. A womenswear label rarely says "women's"
   on every listing.
Anything else stays unlabelled and shows only when no gender is picked.

    python3 catalog/gender.py                 # label from the cache, rewrite catalog
    python3 catalog/gender.py --fetch 60      # first refresh up to 60 stale brands' collections
    python3 catalog/gender.py --dry-run       # counts only
"""
import argparse, json, re, sys, time, urllib.request
from collections import Counter, defaultdict
from datetime import date, timedelta
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from catalog_io import write_catalog  # noqa: E402

CATALOG = HERE.parent / "Marracat/Resources/catalog.json"
BRANDS = HERE / "brands.json"
CACHE = HERE / "gender_collections.json"
DEPARTMENTS = {"clothing", "shoes"}
STALE_DAYS = 14
UA = "Mozilla/5.0 (compatible; Marracat catalog builder)"

# Collection handles. "-" separated words; a store's sub-collections
# ("womens-dresses") count too.
WOMEN_HANDLE = re.compile(r"^(?:shop-|all-)*(?:women|womens|womenswear|woman|ladies|for-her|her|female)(?:-.*)?$")
MEN_HANDLE = re.compile(r"^(?:shop-|all-)*(?:men|mens|menswear|for-him|him|male)(?:-.*)?$")
UNISEX_HANDLE = re.compile(r"^(?:shop-|all-)*unisex(?:-.*)?$")
# Words that say who a product is for, not a slogan on it ("I Love Black
# Women" tee, "Female Rappers" sweatshirt): in a title or type only the
# possessive or "for ..." forms, or the word closing the name ("Adistar
# Control 5 Women"); a tag must be the word itself ("Womens", "Gender:
# Female", "mens-tops"). "Unisex" counts anywhere. "Women" never matches
# \bmen\b.
WOMEN_NAME = re.compile(r"\b(?:women'?s|womens|womenswear|ladies'?|lady's)\b|\bfor (?:women|her|ladies)\b|\bwomen\s*(?:$|[(\-–|/,])", re.I)
MEN_NAME = re.compile(r"\b(?:men'?s|mens|menswear|gentlemen'?s)\b|\bfor (?:men|him)\b|\bmen\s*(?:$|[(\-–|/,])", re.I)
WOMEN_TAG = re.compile(r"^(?:gender\s*[:_\-]\s*)?(?:women|womens|women's|womenswear|woman|ladies|female|her|for her)(?:$|[\s\-_'/])", re.I)
MEN_TAG = re.compile(r"^(?:gender\s*[:_\-]\s*)?(?:men|mens|men's|menswear|man|male|him|for him)(?:$|[\s\-_'/])", re.I)
UNISEX_WORDS = re.compile(r"\b(?:unisex|gender[- ]?neutral|genderless)\b", re.I)
WOMEN_AISLES = {"clothing:dresses", "clothing:skirts", "clothing:bras", "clothing:lingerie", "shoes:heels"}
KIDS_AISLES = {"clothing:kids"}

BRAND_MIN_LABELLED = 20
BRAND_SHARE = 0.95


def handle_of(p):
    url = p.get("url") or ""
    return url.split("/products/", 1)[1].split("?")[0].strip("/").lower() if "/products/" in url else None


def side_of_text(title, ptype, tags):
    tags = [t.strip() for t in tags or [] if t and t.strip()]
    if any(UNISEX_WORDS.search(t or "") for t in [title, ptype, *tags]):
        return {"women", "men"}
    named = " | ".join(t for t in (title, ptype) if t)
    w = bool(WOMEN_NAME.search(named)) or any(WOMEN_TAG.match(t) for t in tags)
    m = bool(MEN_NAME.search(named)) or any(MEN_TAG.match(t) for t in tags)
    return {"women", "men"} if w and m else {"women"} if w else {"men"} if m else set()


def in_scope(p):
    if p.get("category") not in DEPARTMENTS:
        return False
    return not any(f"{p['category']}:{s}" in KIDS_AISLES for s in p.get("subs") or [])


def own_label(p, collections):
    """Steps 1-3 for one product: a set of sides, empty when nothing says."""
    entry = collections.get(p["brand"]) or {}
    h = handle_of(p)
    if h:
        sides = set()
        if h in set(entry.get("women") or ()):
            sides.add("women")
        if h in set(entry.get("men") or ()):
            sides.add("men")
        if h in set(entry.get("unisex") or ()):
            sides |= {"women", "men"}
        if sides:
            return sides, "collection"
    sides = side_of_text(p.get("title"), p.get("product_type"), p.get("tags"))
    if sides:
        return sides, "words"
    if any(f"{p['category']}:{s}" in WOMEN_AISLES for s in (p.get("subs") or [])[:1]):
        return {"women"}, "aisle"
    return set(), None


def brand_defaults(labels):
    """Step 4: brand -> side, from its labelled products' one-sidedness."""
    tally = defaultdict(Counter)
    for brand, sides in labels:
        if len(sides) == 1:
            tally[brand][next(iter(sides))] += 1
    out = {}
    for brand, c in tally.items():
        total = c["women"] + c["men"]
        for side, other in (("women", "men"), ("men", "women")):
            if total >= BRAND_MIN_LABELLED and c[side] / total >= BRAND_SHARE and c[other] <= 1:
                out[brand] = side
    return out


def annotate(products, collections):
    counts = Counter()
    pending, labels = [], []
    for p in products:
        attrs = p.get("attrs") or {}
        attrs.pop("gender", None)
        if attrs:
            p["attrs"] = attrs
        else:
            p.pop("attrs", None)
        if not in_scope(p):
            continue
        sides, why = own_label(p, collections)
        if sides:
            labels.append((p["brand"], sides))
            set_gender(p, sides)
            counts[why] += 1
        else:
            pending.append(p)
    defaults = brand_defaults(labels)
    for p in pending:
        side = defaults.get(p["brand"])
        if side:
            set_gender(p, {side})
            counts["brand"] += 1
        else:
            counts["unlabelled"] += 1
    return counts, defaults


def set_gender(p, sides):
    p.setdefault("attrs", {})["gender"] = sorted(sides)


# --- collections cache -------------------------------------------------------

def _get(url):
    for attempt in range(4):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=20) as r:
                return json.loads(r.read(5_000_000))
        except urllib.error.HTTPError as e:
            if e.code == 429:
                time.sleep(5 * (attempt + 1))
                continue
            return None
        except Exception:  # noqa: BLE001 - offline or not JSON: no answer
            return None
    return None


def gendered_collections(handles):
    """The collections worth reading per side: the broadest first (shortest
    handle), at most four, since sub-collections repeat what a parent has."""
    pick = {}
    for side, rx in (("women", WOMEN_HANDLE), ("men", MEN_HANDLE), ("unisex", UNISEX_HANDLE)):
        found = sorted((h for h in handles if rx.match(h)), key=len)
        if found:
            pick[side] = found[:4]
    return pick


def fetch_brand(domain, pause=0.8):
    cols = _get(f"https://{domain}/collections.json?limit=250")
    if cols is None:
        return None
    picked = gendered_collections([c["handle"] for c in cols.get("collections", [])])
    entry = {"checked": date.today().isoformat(), "collections": picked}
    for side, handles in picked.items():
        products = set()
        for h in handles:
            for page in range(1, 11):
                time.sleep(pause)
                d = _get(f"https://{domain}/collections/{h}/products.json?limit=250&page={page}")
                batch = (d or {}).get("products") or []
                products.update(p["handle"].lower() for p in batch)
                if len(batch) < 250:
                    break
        entry[side] = sorted(products)
    return entry


def refresh(collections, products, limit, pause=0.8):
    """Fetch up to `limit` brands whose entry is missing or stale, biggest
    clothing range first."""
    brands = {b["id"]: b for b in json.loads(BRANDS.read_text())}
    sizes = Counter(p["brand"] for p in products if in_scope(p))
    cutoff = (date.today() - timedelta(days=STALE_DAYS)).isoformat()
    todo = [b for b, _ in sizes.most_common()
            if b in brands and brands[b].get("shopify") and (collections.get(b) or {}).get("checked", "") < cutoff]
    done = 0
    for b in todo[:limit]:
        entry = fetch_brand(brands[b]["domain"], pause)
        if entry is not None:
            collections[b] = entry
            done += 1
        time.sleep(pause)
    return done, max(0, len(todo) - limit)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fetch", type=int, default=0, help="refresh up to N stale brands' collections first")
    ap.add_argument("--pause", type=float, default=0.8)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    catalog = json.loads(CATALOG.read_text())
    collections = json.loads(CACHE.read_text()) if CACHE.exists() else {}
    if args.fetch:
        done, left = refresh(collections, catalog["products"], args.fetch, args.pause)
        CACHE.write_text(json.dumps(collections, indent=0, sort_keys=True) + "\n")
        print(f"gender: refreshed {done} brands' collections, {left} still stale")
    counts, defaults = annotate(catalog["products"], collections)
    tagged = Counter(tuple(p["attrs"]["gender"]) for p in catalog["products"] if (p.get("attrs") or {}).get("gender"))
    print(f"gender: {dict(counts)}; women {tagged[('women',)]}, men {tagged[('men',)]}, "
          f"unisex {tagged[('men', 'women')]}; {len(defaults)} brands one-sided")
    if not args.dry_run:
        write_catalog(CATALOG, catalog)


if __name__ == "__main__":
    main()
