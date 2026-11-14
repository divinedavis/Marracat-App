#!/usr/bin/env python3
"""Award the Marracat Pet Safe badge.

The rules are in catalog/pet_standard.md. Pet products are judged by kind, and
the listing has to say what the product is:

- Food and treats: an AAFCO "complete and balanced" statement (or the EU's
  FEDIAF "complete feed"), or a single-ingredient treat with that ingredient
  named ("Ingredients: beef liver", "100% green tripe", "single-ingredient",
  or one named animal part sold air-dried, freeze-dried or raw). Nothing
  toxic to pets (xylitol, grapes and raisins, onion and garlic, chocolate,
  macadamia, caffeine, alcohol), no propylene glycol in cat food (FDA, 21 CFR
  589.1001) and no ethoxyquin (EU authorisation suspended).
- Grooming (shampoos, balms, sprays, wipes, paw and ear care): a published
  ingredient list with nothing on Clean's ban list and no essential oil that
  is toxic to cats or dogs (tea tree, pennyroyal, wintergreen, cinnamon,
  citrus, pine, ylang-ylang, peppermint, eucalyptus, clove).
- Toys, beds, bowls, collars, leashes, harnesses, clothing and tags: the
  material named; plastic, rubber or vinyl that a pet chews or eats from
  stated BPA- and phthalate-free; no PVC unless stated phthalate-free.

Merch for people (T-shirts, mugs, stickers, books) isn't judged. Read from each
product's own title, description, tags and options; grooming lists are also
read from product pages by --scrape. Sets product["pet"] = True on passing
products (absent otherwise) and writes catalog/pet_report.md.

Usage:
    python3 catalog/pet_badge.py
    python3 catalog/pet_badge.py --scrape --max-new 200
    python3 catalog/pet_badge.py --explain <product-id>
    python3 catalog/pet_badge.py --report-only     # don't rewrite the catalog
"""
import argparse
import json
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import clean_badge as cb  # noqa: E402
import ingredient_lists as il  # noqa: E402
from baby_badge import text_of, without_free_claims  # noqa: E402
from catalog_io import write_catalog  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Marracat" / "Resources" / "catalog.json"
REPORT = ROOT / "catalog" / "pet_report.md"

PET_WORD = re.compile(r"\b(dogs?|cats?|pups?|puppy|puppies|kittens?|pets?|canine|feline|doggie|doggy|k9)\b", re.I)
HUMAN_MERCH = re.compile(r"\b(t-?shirts?|tees?|hoodies?|sweatshirts?|crewnecks?|mugs?|stickers?|decals?|posters?|"
                         r"prints?|books?|journals?|gift cards?|e-?gift|tote bags?|hats?|caps?|socks|candles?|"
                         r"keychains?|magnets?|pins?|records?|vinyl lp|cards?)\b", re.I)
FOOD = re.compile(r"\b(treats?|chews?|jerky|food|kibble|biscuits?|cookies?|kookies?|bully sticks?|raw|"
                  r"freeze[- ]dried|air[- ]dried|dehydrated|tripe|bones?|toppers?|broth|meals?|pops|puffs|bites|"
                  r"necks?|feet|paws|ears|tracheas?|hearts?|livers?|gizzards?|sticks|whole (?:quail|fish|rabbit)|"
                  r"ground (?:beef|venison|turkey|chicken|lamb|duck|rabbit|pork|bison|goat)|goat milk|"
                  r"pupsicles?|cakes?|cupcakes?|donuts?|pupcakes?|bark(?:ery|s)?)\b", re.I)
GROOMING = re.compile(r"\b(shampoos?|conditioners?|balms?|sprays?|wipes?|cologne|perfume|deodori[sz]ers?|"
                      r"paw (?:wax|butter|cream|balm)|ear (?:cleaner|wash|drops)|toothpaste|dental (?:spray|gel)|"
                      r"salves?|lotions?|oils?|soaps?|spritz|detanglers?)\b", re.I)
NOT_FOOD_WORDS = re.compile(r"\b(toy|bowl|mat|bed|leash|collar|harness|bandanna|tag|holder|bag|jar|container|"
                            r"dispenser|feeder)\b", re.I)

COMPLETE = re.compile(r"complete (?:and|&) balanced|aafco|fediaf|complete (?:pet )?(?:food|feed)\b", re.I)
SINGLE = re.compile(r"single[- ]ingredient|one[- ]ingredient|only one ingredient|100\s*% (?:pure |natural |raw |"
                    r"wild[- ]caught |grass[- ]fed |human[- ]grade )?(?:beef|chicken|salmon|lamb|duck|turkey|pork|"
                    r"bison|venison|fish|rabbit|goat|cod|pollock|sardines?|anchov(?:y|ies)|quail|tripe|"
                    r"beef green tripe|green tripe|liver|heart|kangaroo|elk|yak|cheese|pumpkin|sweet potato)", re.I)
INGREDIENTS = re.compile(r"\bingredients?\s*[:\-–]\s*([^.|•\n]{2,400})", re.I)
WHOLE_PART = re.compile(r"\b(beef|chicken|duck|turkey|lamb|pork|bison|venison|rabbit|goat|quail|salmon|cod|"
                        r"pollock|sardines?|anchov(?:y|ies)|minnows?|smelt|fish|elk|kangaroo|yak)\b.{0,30}\b("
                        r"necks?|feet|paws|ears|tracheas?|hearts?|livers?|gizzards?|tripe|bully sticks?|tendons?|"
                        r"ribs?|bones?|backs?|wings?|tails?|skins?|chips?|bites|pops|whole|knuckles?|"
                        r"pizzles?|lungs?|spleen|kidneys?)\b|\bwhole (quail|fish|rabbit|sardines?|anchov(?:y|ies)|"
                        r"minnows?|smelt)\b|\bgreen tripe\b", re.I)
AIR_FREEZE_RAW = re.compile(r"air[- ]dried|freeze[- ]dried|dehydrated|\braw\b|smoked|baked", re.I)

FOOD_TOXIC = [
    ("xylitol / birch sugar", r"xylitol|birch sugar",
     "FDA: xylitol is toxic to dogs (consumer update 2021); ASPCA Animal Poison Control"),
    ("grapes or raisins", r"\bgrapes?\b|raisins?|sultanas?|currants?",
     "ASPCA Animal Poison Control: grapes and raisins cause kidney failure in dogs"),
    ("onion or garlic", r"\bonions?\b|garlic|\bchives?\b|\bleeks?\b|allium",
     "ASPCA: onion, garlic and other alliums damage red blood cells in cats and dogs"),
    ("chocolate / cocoa", r"chocolate|cocoa|cacao|theobromine",
     "ASPCA and FDA: theobromine in chocolate is toxic to dogs and cats"),
    ("macadamia nuts", r"macadamia", "ASPCA: macadamia nuts are toxic to dogs"),
    ("caffeine", r"caffeine|coffee|\bguarana\b", "ASPCA: caffeine is toxic to cats and dogs"),
    ("alcohol", r"\balcohol\b(?! free)|\bethanol\b|\bbeer\b|\bwine\b", "ASPCA: alcohol is toxic to pets"),
    ("ethoxyquin", r"ethoxyquin",
     "EU Implementing Regulation 2017/962 suspended ethoxyquin as a feed additive"),
]
CAT_PG = ("propylene glycol in cat food", r"propylene glycol",
          "FDA: propylene glycol is not generally recognised as safe in cat food (21 CFR 589.1001)")

# Essential oils toxic to cats or dogs (ASPCA; Merck Veterinary Manual).
PET_TOXIC_OILS = re.compile(
    r"\b(tea tree|melaleuca|pennyroyal|mentha pulegium|wintergreen|gaultheria|methyl salicylate|cinnamon|"
    r"cinnamomum|cassia|citrus|orange|lemon|lime|grapefruit|bergamot|limonene|d-limonene|pine|pinus|"
    r"ylang|cananga|peppermint|mentha piperita|spearmint|eucalyptus|clove|eugenia|sweet birch|betula|"
    r"thyme|thymus|oregano|origanum|camphor|wormwood|artemisia|anise|juniper)\b", re.I)
PET_OIL_SOURCE = ("ASPCA Animal Poison Control and the Merck Veterinary Manual list tea tree, pennyroyal, "
                  "wintergreen, cinnamon, citrus, pine, ylang-ylang, peppermint, eucalyptus and clove oils as "
                  "toxic to cats and dogs")

SAFE_MATERIAL = re.compile(
    r"\b(nylon|polyester|cotton|organic cotton|canvas|hemp|jute|linen|wool|felt|fleece|leather|full[- ]grain|"
    r"suede|biothane|rope|natural rubber|food[- ]grade silicone|silicone|stainless steel|ceramic|stoneware|"
    r"porcelain|bamboo|wood|wooden|aluminum|aluminium|brass|zinc alloy|neoprene|mesh|denim|corduroy|"
    r"sherpa|velvet|microfiber|recycled (?:plastic|polyester|nylon)|tpr|thermoplastic rubber|latex|"
    r"polypropylene|abs|metal|iron|acrylic)\b", re.I)
CHEWABLE = re.compile(r"\b(chew toys?|toys?|balls?|teethers?|bones? toy|frisbee|squeak\w*|tug)\b", re.I)
PLASTICKY = re.compile(r"\b(plastic|rubber|tpr|thermoplastic|vinyl|pvc|latex|polypropylene|abs)\b", re.I)
BOWL = re.compile(r"\b(bowls?|feeders?|dishes|water bottle|lick mats?|slow feeder)\b", re.I)
BPA_PHTHALATE_FREE = re.compile(r"bpa[- ]free|phthalate[- ]free|non[- ]toxic|food[- ]grade|free (?:of|from) "
                                r"(?:bpa|phthalates)", re.I)
PVC = re.compile(r"\bpvc\b|\bvinyl\b(?! (?:sticker|decal|print))|polyvinyl chloride", re.I)


def kind(product):
    """'food', 'grooming', 'goods' or None when the badge can't apply."""
    if product.get("category") != "pets":
        return None
    title = f"{product.get('title') or ''} {product.get('product_type') or ''}"
    people = re.search(r"\b(?:dog|cat|pet|fur|pup|puppy|doggie|kitty)\s*(?:mom|mama|mommy|dad|daddy|papa|parent|"
                       r"lover|lady|owner|person|grandma|aunt|uncle)s?\b|\bunisex\b|\bfor humans\b|\badult\b",
                       title, re.I)
    if HUMAN_MERCH.search(title) and (people or not PET_WORD.search(title)) and not re.search(
            r"measure your (?:pup|dog|pet|cat)|your (?:pup|dog)'s (?:neck|chest|back)|\bD\.O\.G\.",
            f"{title} {product.get('description') or ''}", re.I):
        return None
    if re.search(r"\b(gift card|e-?gift|sticker|poster|book)\b", title, re.I):
        return None
    if GROOMING.search(title) and not NOT_FOOD_WORDS.search(title):
        return "grooming"
    subs = set(product.get("subs") or [])
    if (FOOD.search(title) and not NOT_FOOD_WORDS.search(title)) or "pet-treats" in subs:
        return "food"
    return "goods"


def single_ingredient(text, title):
    if SINGLE.search(text):
        return True
    m = INGREDIENTS.search(text)
    if m:
        items = [i for i in re.split(r",|;|\band\b", m.group(1)) if i.strip()]
        return len(items) == 1
    return bool(WHOLE_PART.search(title) and AIR_FREEZE_RAW.search(text))


def evaluate(product, inci=""):
    """-> (passes: bool, failures: [str], notes: [str])"""
    k = kind(product)
    if not k:
        return False, ["not a pet product the badge covers"], []
    text = text_of(product)
    claims = without_free_claims(text)
    title = product.get("title") or ""
    failures, notes = [], []
    if k == "food":
        for label, pattern, _src in FOOD_TOXIC + ([CAT_PG] if re.search(r"\bcats?\b|feline|kitten", text, re.I)
                                                  else []):
            m = re.search(pattern, claims, re.I)
            if m:
                failures.append(f"{label}: {m.group(0)}")
        if COMPLETE.search(text):
            notes.append("complete and balanced (AAFCO / FEDIAF)")
        elif single_ingredient(text, title):
            notes.append("single ingredient")
        else:
            failures.append("no complete-and-balanced statement and not single-ingredient")
        if re.search(r"\bbha\b|butylated hydroxyanisole", claims, re.I):
            notes.append("BHA preservative")
        return not failures, failures, notes
    if k == "grooming":
        inci = inci or il.extract_list(without_free_claims(text))
        if inci and cb.NOT_A_LIST.search(inci):
            inci = ""
        if not inci:
            return False, ["no published ingredient list"], notes
        toks = il.tokens(inci)
        for label, hits in il.banned_hits(toks):
            failures.append(f"{label}: {', '.join(hits[:3])}")
        oils = [t for t in toks if PET_TOXIC_OILS.search(t) and re.search(r"oil|extract|limonene|salicylate|"
                                                                        r"camphor|eugenol|terpene", t, re.I)
                or re.search(r"d-limonene|methyl salicylate", t, re.I)]
        if oils:
            failures.append(f"essential oil toxic to pets: {oils[0]}")
        bare = il.fragrance_undisclosed(inci, toks)
        if bare:
            failures.append(f"undisclosed fragrance: {bare}")
        return not failures, failures, notes
    # goods: toys, beds, bowls, collars, leashes, harnesses, clothing, tags
    if PVC.search(claims) and not re.search(r"phthalate[- ]free", text, re.I):
        failures.append("PVC / vinyl not stated phthalate-free")
    if not SAFE_MATERIAL.search(text) and not PLASTICKY.search(text):
        failures.append("materials not stated")
    elif (CHEWABLE.search(title) or BOWL.search(title)) and PLASTICKY.search(text) \
            and not BPA_PHTHALATE_FREE.search(text) and not re.search(
                r"natural rubber|silicone|stainless|ceramic|cotton|hemp|rope|wool|felt", text, re.I):
        failures.append("plastic or rubber not stated BPA- and phthalate-free")
    return not failures, failures, notes


def apply(products, store):
    """Rewrite `pet` on every product. Returns report inputs."""
    stats = {"eligible": 0, "stated": 0, "passed": 0}
    by_kind = {}
    failed_by, noted_by, brands = {}, {}, set()
    for p in products:
        p.pop("pet", None)
        k = kind(p)
        if not k:
            continue
        stats["eligible"] += 1
        inci = store.get(p["url"], "") if k == "grooming" else ""
        ok, failures, notes = evaluate(p, inci)
        if not (failures and failures[0] in ("no published ingredient list", "materials not stated",
                                             "no complete-and-balanced statement and not single-ingredient")):
            stats["stated"] += 1
        kb = by_kind.setdefault(k, [0, 0])
        kb[0] += 1
        if ok:
            p["pet"] = True
            stats["passed"] += 1
            kb[1] += 1
            brands.add(p["brand"])
            for n in notes:
                noted_by[n] = noted_by.get(n, 0) + 1
        else:
            for f in failures:
                key = f.split(":")[0]
                failed_by[key] = failed_by.get(key, 0) + 1
    stats["by_kind"] = by_kind
    return stats, failed_by, noted_by, sorted(brands)


def write_report(stats, failed_by, noted_by, brands):
    lines = ["# Marracat Pet Safe — badge report", "",
             f"{stats['eligible']} eligible pet products · {stats['stated']} stating what they are · "
             f"**{stats['passed']} badged** across {len(brands)} brands.", "",
             "The standard is in catalog/pet_standard.md. Food needs a complete-and-balanced statement or a single "
             "named ingredient; grooming a published list with no pet-toxic oil; goods their material named. "
             "Grooming lists are also read from product pages by `pet_badge.py --scrape`.", "",
             "| Kind | Eligible | Badged |", "|---|---|---|"]
    lines += [f"| {k} | {v[0]} | {v[1]} |" for k, v in sorted(stats.get("by_kind", {}).items())]
    lines += ["", "## Why products fail", "", "| Reason | Products |", "|---|---|"]
    lines += [f"| {k} | {v} |" for k, v in sorted(failed_by.items(), key=lambda kv: -kv[1])]
    lines += ["", "## Allowed but noted", "", "| Note | Products |", "|---|---|"]
    lines += [f"| {k} | {v} |" for k, v in sorted(noted_by.items(), key=lambda kv: -kv[1])] or ["| none | 0 |"]
    lines += ["", "## Badged brands", "", ", ".join(brands) or "none yet", ""]
    REPORT.write_text("\n".join(lines))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scrape", action="store_true", help="fetch grooming ingredient lists not yet stored")
    ap.add_argument("--max-new", type=int, default=0, help="cap on pages fetched this run (0 = no cap)")
    ap.add_argument("--explain", metavar="PRODUCT_ID")
    ap.add_argument("--report-only", action="store_true", help="write the report without rewriting the catalog")
    args = ap.parse_args()
    catalog = json.loads(CATALOG.read_text())
    products = catalog["products"]
    store, misses = cb.load(cb.STORE, {}), cb.load(cb.MISSES, {})
    if args.scrape:
        il.scrape([p for p in products if kind(p) == "grooming"], store, misses, args.max_new)
        il.save(store, misses)
    if args.explain:
        p = next((p for p in products if p["id"] == args.explain), None)
        if not p:
            sys.exit(f"no product {args.explain}")
        ok, failures, notes = evaluate(p, store.get(p["url"], ""))
        print(f"{p['title']} ({p['brand']})\n  kind: {kind(p)}\n"
              f"  verdict: {'PET SAFE' if ok else 'not badged'}\n  failures: {failures}\n  notes: {notes}")
        return
    stats, failed_by, noted_by, brands = apply(products, store)
    if not args.report_only:
        write_catalog(CATALOG, catalog)
    write_report(stats, failed_by, noted_by, brands)
    print(f"pet safe badge: {stats['passed']} badged of {stats['eligible']} pet products — {REPORT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
