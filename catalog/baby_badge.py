#!/usr/bin/env python3
"""Award the Marracat Baby Safe badge.

The rules are in catalog/baby_standard.md. Baby products are judged by what
they're made of, and the listing has to say:

- Formulas (washes, lotions, oils, balms, diaper creams, wipes, powders): a
  published ingredient list that passes Clean's ban list (nothing banned in any
  major market), plus the under-3 rules below, and no fragrance at all, not
  even essential oils.
- Feeding and teething (bottles, cups, plates, spoons, teethers, pacifiers):
  the material named, nothing banned in children's feeding articles anywhere,
  and plastic stated BPA-free.
- Textiles (clothing, swaddles, bedding, cloth diapers, bibs): a natural or
  certified-organic fibre named (cotton, organic cotton, linen, wool, merino,
  silk, hemp, or OEKO-TEX / GOTS), and no flame retardant or PFAS treatment.
- Toys: a named safe material (solid wood, silicone, organic cotton, natural
  rubber) and no PVC.

A listing that states neither ingredients nor materials is never badged.
Strollers, car seats and other gear aren't judged. Sets product["baby"] = True
on passing products (absent otherwise) and writes catalog/baby_report.md.

Usage:
    python3 catalog/baby_badge.py
    python3 catalog/baby_badge.py --scrape --max-new 200
    python3 catalog/baby_badge.py --explain <product-id>
    python3 catalog/baby_badge.py --report-only     # don't rewrite the catalog
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
from catalog_io import write_catalog  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Marracat" / "Resources" / "catalog.json"
REPORT = ROOT / "catalog" / "baby_report.md"

FORMULA = re.compile(r"\b(wash|shampoo|lotion|cream|balm|salve|ointment|butter|oil|oils|powder|wipes?|soap|"
                     r"serum|bubble bath|bath (?:soak|milk|salts?)|diaper rash|rash|sunscreen|spf|moisturi[sz]er|"
                     r"conditioner|detangler|massage)\b", re.I)
FEEDING = re.compile(r"\b(bottles?|nipples?|teethers?|teething|pacifiers?|soothers?|sippy|cups?|plates?|bowls?|"
                     r"spoons?|forks?|feeders?|straws?|snack cups?|place ?mats?|suction|utensils?|dinnerware|"
                     r"pacifier clips?|binky)\b", re.I)
TOY = re.compile(r"\b(toys?|rattles?|blocks?|stacker|stacking|play ?mat|activity|puzzles?|plush|doll|teddy)\b", re.I)
GEAR = re.compile(r"\b(stroller|car seat|carrier|high ?chair|crib|bassinet|monitor|bouncer|swing|walker|"
                  r"gift card|e-?gift|book|cycling|bib shorts|bundle|gift set|gift box|kit|stickers?|decals?|prints?|"
                  r"posters?|greeting cards?|mugs?|magnets?)\b", re.I)
NOT_BABY = re.compile(r"\b(women'?s|men'?s|adult|mama|mom|maternity|nursing bra|nipple cream|"
                      r"breast|postpartum|belly)\b", re.I)

# Formulas: extra bans for products used on children under 3.
UNDER3_BANNED = [
    ("salicylic acid (not in a shampoo)", r"salicylic acid",
     "EU Cosmetics Regulation 1223/2009 Annex III entry 98: not to be used in products for children under 3, "
     "except shampoos"),
    ("methylisothiazolinone", r"methylisothiazolinone|methylchloroisothiazolinone",
     "banned in EU leave-on cosmetics (Reg. 2016/1198) and restricted in rinse-off; Canada Hotlist"),
    ("talc", r"\btalc\b",
     "EU Annex III entry 59 requires 'keep powder away from children's nose and mouth'; Canada proposed "
     "inhalation-hazard labelling (2021); the Marracat standard excludes it from baby powder"),
    ("boric acid and borates", r"boric acid|\bborax\b|sodium borate|\bborate\b",
     "EU Annex III entry 1a: not for children under 3 (and on peeling or irritated skin)"),
]
# Any fragrance at all, including essential oils, fails a baby formula.
SCENTED = re.compile(r"\b(fragrance|parfum|perfume|aroma|essential oils?|linalool|limonene|geraniol|"
                     r"citronellol|eugenol|coumarin|citral|farnesol|benzyl (alcohol|benzoate|salicylate))\b", re.I)
# An essential oil named by its plant: a token holding one of these and "oil".
# Carrier oils (sunflower, jojoba, coconut, almond, olive, shea) aren't here.
ESSENTIAL_PLANTS = re.compile(r"\b(lavand\w*|lavender|melaleuca|tea tree|eucalyptus|mentha|peppermint|spearmint|"
                              r"rosmarinus|rosemary|bergamot|ylang|cananga|clary|salvia sclarea|geranium|pelargonium|"
                              r"patchouli|pogostemon|frankincense|boswellia|cedarwood|cedrus|sandalwood|santalum|"
                              r"orange peel|lemon peel|citrus (aurantium|limon|sinensis|paradisi|bergamia)|"
                              r"chamomile oil|anthemis|cinnamomum|clove|eugenia|lemongrass|cymbopogon|rose oil|"
                              r"rosa damascena|vetiver|myrrh|thyme|thymus)\b", re.I)

# Feeding articles.
FEED_SAFE = re.compile(r"\b(food[- ]grade silicone|platinum silicone|medical[- ]grade silicone|silicone|"
                       r"stainless steel|18/8|borosilicate|glass|natural rubber|hevea|beech ?wood|maple|"
                       r"solid wood|wooden|ceramic)\b", re.I)
FEED_BANNED = [
    ("polycarbonate / BPA", r"polycarbonate|contains bpa|\bbpa\b(?![- ]free)",
     "BPA is banned in baby bottles in the EU (Directive 2011/8/EU), the US (FDA 2012) and Canada (2010), "
     "and in all food-contact materials in the EU from 2026 (Reg. 2024/3190)"),
    ("melamine or bamboo-fibre plastic", r"melamine|bamboo fi(b|bre|ber)|bamboo composite|bamboo plastic",
     "the EU bars plastic food-contact articles with bamboo filler (Commission statement 2021, Reg. 10/2011)"),
    ("PVC / phthalates", r"\bpvc\b|vinyl|phthalate(?![- ]free)",
     "phthalates are restricted in childcare articles in the EU (REACH Annex XVII entries 51-52) and the US "
     "(CPSIA §108, 16 CFR 1307)"),
    ("lead or cadmium", r"\bcadmium\b|lead[- ](based|paint|content)|contains lead",
     "CPSIA limits lead in children's products to 100 ppm; EU REACH entry 23 restricts cadmium"),
]
PLASTIC = re.compile(r"\b(plastic|polypropylene|\bpp\b|tritan|polyethylene|abs\b)\b", re.I)

# Textiles.
FIBRE_SAFE = re.compile(r"\b(organic cotton|100 ?% cotton|cotton|linen|flax|wool|merino|silk|hemp|cashmere|"
                        r"gots|oeko-?tex)\b", re.I)
TEXTILE_BANNED = [
    ("flame retardant", r"flame[- ]retardant|fire[- ]retardant|pbde|tdcpp|tris\(",
     "California AB 2998 (2020) bans flame retardants in juvenile products, mattresses and upholstery; "
     "EU POPs Regulation bans PBDEs"),
    ("PFAS treatment", r"\bpfas\b|perfluoro|polyfluoro|teflon|fluorocarbon|stain[- ]resistant finish",
     "California AB 1817 bans intentionally added PFAS in textiles from 2025; New York (2024) bans PFAS in "
     "apparel"),
]
TOY_SAFE = re.compile(r"\b(solid wood|wooden|wood|beech|maple|food[- ]grade silicone|silicone|organic cotton|"
                      r"natural rubber|felt wool|wool)\b", re.I)


def kind(product):
    """'formula', 'feeding', 'textile', 'toy', or None when the badge can't apply."""
    if product.get("category") != "baby":
        return None
    title = f"{product.get('title') or ''} {product.get('product_type') or ''}"
    subs = set(product.get("subs") or [])
    if GEAR.search(title) or NOT_BABY.search(title) or "baby-gear" in subs:
        return None
    if FORMULA.search(title) and not FEEDING.search(title):
        return "formula"
    if FEEDING.search(title) or "feeding" in subs:
        return "feeding"
    if TOY.search(title) or "kids-toys" in subs:
        return "toy"
    return "textile"


# "Free of BPA, PVC and phthalates", "BPA, PVC & phthalate free", "non-toxic,
# lead-free": a claim of absence, removed before the bans are looked for.
FREE_CLAIM = re.compile(
    r"\bfree\s+(?:of|from)\b[^.•|;!\n]{0,120}"
    r"|(?:\b[\w/&]+(?:\s*(?:,|and|&)\s*)?){1,6}[- ]?free\b(?!\s+(?:of|from)\b)"
    r"|\b(?:no|without|never(?: any| use[sd]?| contains?)?|not treated with|zero|"
    r"(?:does not|doesn'?t|do not|don'?t|will not|won'?t) contain|contains? no)\b[^.•|;!]{0,120}"
    r"|\bnon[- ]toxic\b", re.I)


def without_free_claims(text):
    return FREE_CLAIM.sub(" ", text)


def text_of(product):
    parts = [product.get("title") or "", product.get("product_type") or "", product.get("description") or "",
             " ".join(product.get("tags") or []), " ".join(product.get("opts") or [])]
    t = html.unescape(re.sub(r"<[^>]+>", " ", " ".join(parts)))
    return re.sub(r"\s+", " ", t)


def evaluate(product, inci=""):
    """-> (passes: bool, failures: [str], notes: [str])"""
    k = kind(product)
    text = text_of(product)
    failures, notes = [], []
    if k == "formula":
        inci = inci or il.extract_list(without_free_claims(text))
        if inci and cb.NOT_A_LIST.search(inci):
            inci = ""
        if not inci:
            return False, ["no published ingredient list"], notes
        ok, fails, cnotes = cb.evaluate(product, inci)
        failures += [f for f in fails if not f.startswith("undisclosed fragrance")]
        notes += cnotes
        toks = il.tokens(inci)
        for label, hits in il.banned_hits(toks, UNDER3_BANNED):
            if label.startswith("salicylic") and re.search(r"shampoo", product.get("title") or "", re.I):
                continue
            if label not in {f.split(":")[0] for f in failures}:
                failures.append(f"{label}: {', '.join(hits[:3])}")
        scented = [t for t in toks if (SCENTED.search(t) or (ESSENTIAL_PLANTS.search(t) and "oil" in t))
                   and not re.search(r"fragrance[- ]free|unscented", t)]
        if scented:
            failures.append(f"fragrance or essential oil: {scented[0]}")
        return not failures, failures, notes
    claims = without_free_claims(text)
    if k == "feeding":
        for label, pattern, _src in FEED_BANNED:
            m = re.search(pattern, claims, re.I)
            if m:
                failures.append(f"{label}: {m.group(0)}")
        if not FEED_SAFE.search(text) and not PLASTIC.search(text):
            failures.append("materials not stated")
        elif PLASTIC.search(text) and not FEED_SAFE.search(text) and not re.search(r"\bbpa\b", text, re.I):
            failures.append("plastic not stated BPA-free")
        return not failures, failures, notes
    if k in ("textile", "toy"):
        for label, pattern, _src in TEXTILE_BANNED + [FEED_BANNED[2], FEED_BANNED[3]]:
            m = re.search(pattern, claims, re.I)
            if m:
                failures.append(f"{label}: {m.group(0)}")
        safe = TOY_SAFE if k == "toy" else FIBRE_SAFE
        if not safe.search(text):
            failures.append("materials not stated" if not re.search(
                r"\b(polyester|nylon|spandex|acrylic|polyurethane|\bpul\b|microfib|fleece|bamboo|viscose|rayon|"
                r"modal|plastic)\b", text, re.I) else "synthetic or regenerated fibre only")
        return not failures, failures, notes
    return False, ["not a baby product the badge covers"], notes


def apply(products, store):
    """Rewrite `baby` on every product. Returns report inputs."""
    stats = {"eligible": 0, "listed": 0, "passed": 0}
    by_kind = {}
    failed_by, noted_by, brands = {}, {}, set()
    for p in products:
        p.pop("baby", None)
        k = kind(p)
        if not k:
            continue
        stats["eligible"] += 1
        inci = store.get(p["url"], "") if k == "formula" else ""
        ok, failures, notes = evaluate(p, inci)
        if not (failures and failures[0] in ("no published ingredient list", "materials not stated")):
            stats["listed"] += 1
        kb = by_kind.setdefault(k, [0, 0])
        kb[0] += 1
        if ok:
            p["baby"] = True
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
    lines = ["# Marracat Baby Safe — badge report", "",
             f"{stats['eligible']} eligible baby products · {stats['listed']} stating ingredients or materials · "
             f"**{stats['passed']} badged** across {len(brands)} brands.", "",
             "The standard is in catalog/baby_standard.md. A listing that states neither ingredients nor materials "
             "is never badged; formula lists are also read from product pages by `baby_badge.py --scrape` "
             "(ship.sh runs it with a cap).", "",
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
    ap.add_argument("--scrape", action="store_true", help="fetch formula ingredient lists not yet stored")
    ap.add_argument("--max-new", type=int, default=0, help="cap on pages fetched this run (0 = no cap)")
    ap.add_argument("--explain", metavar="PRODUCT_ID")
    ap.add_argument("--report-only", action="store_true", help="write the report without rewriting the catalog")
    args = ap.parse_args()
    catalog = json.loads(CATALOG.read_text())
    products = catalog["products"]
    store, misses = cb.load(cb.STORE, {}), cb.load(cb.MISSES, {})
    if args.scrape:
        il.scrape([p for p in products if kind(p) == "formula"], store, misses, args.max_new)
        il.save(store, misses)
    if args.explain:
        p = next((p for p in products if p["id"] == args.explain), None)
        if not p:
            sys.exit(f"no product {args.explain}")
        ok, failures, notes = evaluate(p, store.get(p["url"], ""))
        print(f"{p['title']} ({p['brand']})\n  kind: {kind(p)}\n"
              f"  verdict: {'BABY SAFE' if ok else 'not badged'}\n  failures: {failures}\n  notes: {notes}")
        return
    stats, failed_by, noted_by, brands = apply(products, store)
    if not args.report_only:
        write_catalog(CATALOG, catalog)
    write_report(stats, failed_by, noted_by, brands)
    print(f"baby safe badge: {stats['passed']} badged of {stats['eligible']} eligible — {REPORT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
