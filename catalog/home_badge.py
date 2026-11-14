#!/usr/bin/env python3
"""Award the Marracat Natural Home badge.

The rules are in catalog/home_standard.md. A home product earns it when its
own listing names its main material, and that material is natural or
certified:

- Textiles (rugs, throws, pillows, bedding, towels, table linens, curtains):
  a stated composition at least 90% natural fibre (the parser shared with
  Marracat Natural Fiber: catalog/fiber_badge.py), or one natural fibre named
  with no synthetic beside it, or OEKO-TEX Standard 100 / GOTS certified.
- Tableware and kitchen (mugs, glasses, plates, bowls, serveware): glass,
  stainless steel, cast iron, solid wood, stone or marble, or ceramic,
  stoneware, porcelain or earthenware stated lead-free. Lead leaches from
  glazes: the FDA sets action levels for lead in ceramicware (CPG Sec.
  545.450) and California Prop 65 requires a warning above its limits, so a
  glaze has to be stated lead-free. Lead crystal fails for the same reason.
  Melamine and other plastics aren't natural and fail; bamboo-fibre melamine
  is barred from EU food contact outright.
- Décor and furniture (baskets, vases, lighting, furniture, décor): solid wood,
  rattan, wicker, seagrass, jute, bamboo (the cane, not bamboo viscose), stone,
  marble, ceramic, glass, linen, cotton, wool, or a solid metal (cast or wrought
  iron, brass, copper, stainless steel). MDF, particleboard and other composite
  wood fail unless stated CARB Phase 2 or TSCA Title VI compliant (the US and
  California formaldehyde emission limits); PVC or vinyl fails unless stated
  phthalate-free (EU REACH Annex XVII entry 51).

Tier "Marracat Natural Home · Certified": organic or GOTS textiles, or FSC
certified wood. Candles (judged by Marracat Clean's candle rules), incense,
diffusers, wall art, games and gift cards aren't judged. Read from each
product's own title, description, tags and options; nothing is fetched. Sets
product["home"] = "natural" or "certified" on passing products (absent
otherwise) and writes catalog/home_report.md.

Usage:
    python3 catalog/home_badge.py
    python3 catalog/home_badge.py --explain <product-id>
    python3 catalog/home_badge.py --report-only     # don't rewrite the catalog
"""
import argparse
import json
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import candle_badge as cdl  # noqa: E402
import fiber_badge as fb  # noqa: E402
from baby_badge import text_of, without_free_claims  # noqa: E402
from catalog_io import write_catalog  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Marracat" / "Resources" / "catalog.json"
REPORT = ROOT / "catalog" / "home_report.md"

EXCLUDED_SUBS = {"candles", "candle-sets", "diffusers", "incense", "wall-art", "games", "wellness", "office"}
EXCLUDED_TITLE = re.compile(r"\b(candles?|wax melts?|incense|diffusers?|reed diffuser|room sprays?|linen sprays?|"
                            r"fragrance oils?|essential oils?|gift cards?|e-?gift|stickers?|decals?|posters?|"
                            r"art prints?|prints?|digital downloads?|books?|journals?|cards?|calendars?|puzzles?|"
                            r"games?|wallpaper|matches|lighters?|bundle|gift box|subscription|mists?|sprays?|soaps?|hand wash|"
                            r"lotions?|creams?|butters?|scrubs?|air fresheners?|car fresheners?|fresheners?|"
                            r"polish|cleaners?|detergents?|chocolates?|candy|coffee beans?|ground coffee|loose leaf|tea bags?|"
                            r"herbal tea|tea blend|sauces?|seasonings?|"
                            r"magnets?|keychains?|pins?|golf|apparel|t-?shirts?|hoodies?)\b", re.I)

TEXTILE = re.compile(r"\b(rugs?|runners?|throws?|blankets?|pillows?|pillowcases?|cushions?|shams?|duvets?|"
                     r"comforters?|quilts?|sheets?|sheet sets?|bedding|towels?|napkins?|tablecloths?|"
                     r"table runners?|curtains?|drapes?|placemats?|tea towels?|dish towels?|aprons?|bath mats?|"
                     r"oven mitts?|pot holders?|poufs?|hammocks?)\b", re.I)
TEXTILE_SUBS = {"rugs", "throws", "pillows", "bedding", "linens"}
TABLEWARE = re.compile(r"\b(mugs?|cups?|tumblers?|glass(?:es|ware)?|wine glasses|goblets?|plates?|bowls?|"
                       r"dinnerware|platters?|serving (?:board|tray|bowl|spoon)s?|teapots?|carafes?|pitchers?|"
                       r"jugs?|decanters?|saucers?|ramekins?|utensils?|flatware|cutlery|spoons?|forks?|"
                       r"chopsticks?|cutting boards?|charcuterie boards?|serving trays?|coasters?|butter dish|"
                       r"salt (?:cellar|pinch)|cookware|skillets?|frying pans?|sauce ?pans?|dutch ovens?|kettles?|"
                       r"water bottles?)\b",
                       re.I)
TABLEWARE_SUBS = {"glassware", "dinnerware", "kitchen"}

CERTIFIED_TEXTILE = re.compile(r"\boeko[- ]?tex\b|\bgots\b|global organic textile standard", re.I)
SYNTH_FIBRE = re.compile(r"\b(polyester|nylon|acrylic|polypropylene|olefin|microfib(?:er|re)|viscose|rayon|"
                         r"spandex|faux fur|faux sheepskin|faux wool|fleece|minky|velboa|poly blend|"
                         r"bamboo (?:viscose|rayon|fib(?:er|re)))\b", re.I)
NAT_FIBRE = re.compile(r"\b(organic cotton|cotton|linen|flax|wool|merino|alpaca|mohair|cashmere|silk|jute|hemp|"
                       r"sisal|seagrass|ramie|coir|kente|mudcloth|bogolan)\b", re.I)

CERAMIC = re.compile(r"\b(stoneware|ceramics?|porcelain|earthenware|terracotta|terra cotta|bone china|"
                     r"fine china|china mug)\b", re.I)
LEAD_FREE = re.compile(r"lead[- ]free|lead and cadmium[- ]free|free (?:of|from) lead|no lead|"
                       r"prop(?:osition)? ?65 compliant|lead[- ]safe", re.I)
LEAD_CRYSTAL = re.compile(r"lead(?:ed)? crystal|lead glass", re.I)
GLASS = re.compile(r"\b(glass|borosilicate|crystal)\b", re.I)
WOOD = re.compile(r"\b(solid wood|hardwood|wood(?:en)?|oak|walnut|acacia|mango wood|teak|maple|cherry wood|"
                  r"beech|ash wood|olive ?wood|sheesham|mahogany|pine|cedar|ebony|iroko|reclaimed wood|"
                  r"driftwood|bamboo(?! (?:viscose|rayon|fib(?:er|re)|blend|composite|melamine)))\b", re.I)
FSC = re.compile(r"\bfsc\b|forest stewardship council", re.I)
WOVEN = re.compile(r"\b(rattan|wicker|seagrass|jute|sisal|water hyacinth|raffia|palm leaf|banana leaf|cane|"
                   r"bolga|elephant grass|sweetgrass|abaca|willow|straw)\b", re.I)
STONE = re.compile(r"\b(marble|granite|travertine|soapstone|onyx|alabaster|slate|stone|quartz|agate)\b", re.I)
METAL = re.compile(r"\b(cast iron|wrought iron|iron|brass|copper|stainless steel|steel|bronze|pewter|aluminum|"
                   r"aluminium|enamelware|enamel)\b", re.I)
COMPOSITE = re.compile(r"\b(mdf|particle ?board|chip ?board|fib(?:er|re) ?board|engineered wood|"
                       r"composite wood|plywood|pressed wood|hardboard|laminate)\b", re.I)
FORMALDEHYDE_OK = re.compile(r"carb (?:phase )?(?:2|ii)|tsca title vi|carb[- ]compliant|e0\b|e1\b|"
                             r"nauf|no added (?:urea[- ])?formaldehyde", re.I)
SYNTH_SOLID = re.compile(r"\b(melamine|plastic|acrylic|resin|polyresin|poly ?resin|polystone|polyurethane|"
                         r"\bpu\b|silicone|polypropylene|abs|polycarbonate|foam)\b", re.I)
PVC = re.compile(r"\bpvc\b|\bvinyl\b(?! (?:records?|lps?|sticker|decal|print))|polyvinyl chloride", re.I)
PHTHALATE_FREE = re.compile(r"phthalate[- ]free|free (?:of|from) phthalates|non[- ]phthalate", re.I)
BAMBOO_MELAMINE = re.compile(r"bamboo (?:fib(?:er|re)|composite|melamine|plastic)|melamine.{0,30}bamboo", re.I)


def kind(product):
    """'textile', 'tableware', 'decor' or None when the badge can't apply."""
    if product.get("category") != "home":
        return None
    subs = set(product.get("subs") or [])
    title = f"{product.get('title') or ''} {product.get('product_type') or ''}"
    if subs & EXCLUDED_SUBS or EXCLUDED_TITLE.search(title):
        return None
    if cdl.is_candle({"title": product.get("title"), "description": "", "tags": product.get("tags") or []}):
        return None
    if subs & TEXTILE_SUBS or TEXTILE.search(title):
        return "textile"
    if subs & TABLEWARE_SUBS or TABLEWARE.search(title):
        return "tableware"
    return "decor"


def _textile(text, claims, failures, notes):
    comp = fb.composition(text)
    certified = bool(CERTIFIED_TEXTILE.search(text))
    if comp and comp["complete"]:
        natural = comp["share"].get("natural", 0)
        if natural + 1e-9 >= fb.THRESHOLD:
            return "certified" if comp["organic"] else "natural"
        if certified:
            notes.append("OEKO-TEX / GOTS certified blend")
            return "certified" if comp["organic"] else "natural"
        failures.append(f"synthetic or regenerated fibre: {round(natural)}% natural")
        return None
    nat = NAT_FIBRE.search(text)
    synth = SYNTH_FIBRE.search(claims)
    if nat and not synth:
        return "certified" if fb.ORGANIC.search(text) else "natural"
    if certified:
        notes.append("OEKO-TEX / GOTS certified")
        return "certified" if fb.ORGANIC.search(text) else "natural"
    if synth:
        failures.append(f"synthetic or regenerated fibre: {synth.group(0).lower()}")
    else:
        failures.append("material not stated")
    return None


def evaluate(product):
    """-> (tier: "natural" | "certified" | None, failures: [str], notes: [str])"""
    k = kind(product)
    if not k:
        return None, ["not a home product the badge covers"], []
    text = text_of(product)
    claims = without_free_claims(text)
    failures, notes = [], []
    if PVC.search(claims) and not PHTHALATE_FREE.search(text):
        failures.append("PVC / vinyl not stated phthalate-free")
    if k == "textile":
        tier = _textile(text, claims, failures, notes)
        return (None if failures else tier), failures, notes
    if BAMBOO_MELAMINE.search(claims):
        failures.append("bamboo-fibre melamine (barred from EU food contact)")
    if COMPOSITE.search(claims) and not FORMALDEHYDE_OK.search(text):
        failures.append(f"composite wood not stated CARB Phase 2 / TSCA Title VI: {COMPOSITE.search(claims).group(0)}")
    if LEAD_CRYSTAL.search(claims):
        failures.append("lead crystal")
    natural = []
    ceramic = CERAMIC.search(text)
    if ceramic:
        if k == "tableware" and not LEAD_FREE.search(text):
            failures.append("ceramic tableware not stated lead-free")
        else:
            natural.append("ceramic")
    for name, rx in (("glass", GLASS), ("wood", WOOD), ("woven fibre", WOVEN), ("stone", STONE),
                     ("metal", METAL), ("textile", NAT_FIBRE)):
        if rx.search(text):
            if name == "glass" and LEAD_CRYSTAL.search(text):
                continue
            natural.append(name)
    synth = SYNTH_SOLID.search(claims)
    if synth and not natural and not ceramic:
        failures.append(f"synthetic material: {synth.group(0).lower()}")
    elif synth:
        notes.append(f"part synthetic: {synth.group(0).lower()}")
    if not natural and not failures:
        failures.append("material not stated")
    if failures:
        return None, failures, notes
    if "metal" in natural and len(natural) == 1:
        notes.append("solid metal")
    certified = "wood" in natural and FSC.search(text)
    return ("certified" if certified else "natural"), [], notes


def apply(products, store=None):
    """Rewrite `home` on every product. Returns report inputs."""
    stats = {"eligible": 0, "stated": 0, "passed": 0, "certified": 0}
    by_kind = {}
    failed_by, noted_by, brands = {}, {}, set()
    for p in products:
        p.pop("home", None)
        k = kind(p)
        if not k:
            continue
        stats["eligible"] += 1
        tier, failures, notes = evaluate(p)
        if not (failures and failures[0] == "material not stated"):
            stats["stated"] += 1
        kb = by_kind.setdefault(k, [0, 0])
        kb[0] += 1
        if tier:
            p["home"] = tier
            stats["passed"] += 1
            stats["certified"] += tier == "certified"
            kb[1] += 1
            brands.add(p["brand"])
            for n in notes:
                key = n.split(":")[0]
                noted_by[key] = noted_by.get(key, 0) + 1
        else:
            for f in failures:
                key = f.split(":")[0]
                failed_by[key] = failed_by.get(key, 0) + 1
    stats["by_kind"] = by_kind
    return stats, failed_by, noted_by, sorted(brands)


def write_report(stats, failed_by, noted_by, brands):
    lines = ["# Marracat Natural Home — badge report", "",
             f"{stats['eligible']} eligible home products · {stats['stated']} naming a material · "
             f"**{stats['passed']} badged** across {len(brands)} brands · {stats['certified']} of them Certified.", "",
             "The standard is in catalog/home_standard.md: the main material named and natural or certified; "
             "ceramic tableware stated lead-free; no composite wood without CARB Phase 2 / TSCA Title VI; no PVC "
             "without phthalate-free. Read from each product's own description; nothing is fetched.", "",
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
    ap.add_argument("--explain", metavar="PRODUCT_ID")
    ap.add_argument("--report-only", action="store_true", help="write the report without rewriting the catalog")
    args = ap.parse_args()
    catalog = json.loads(CATALOG.read_text())
    products = catalog["products"]
    if args.explain:
        p = next((p for p in products if p["id"] == args.explain), None)
        if not p:
            sys.exit(f"no product {args.explain}")
        tier, failures, notes = evaluate(p)
        print(f"{p['title']} ({p['brand']})\n  kind: {kind(p)}\n  verdict: {tier or 'not badged'}\n"
              f"  failures: {failures}\n  notes: {notes}")
        return
    stats, failed_by, noted_by, brands = apply(products)
    if not args.report_only:
        write_catalog(CATALOG, catalog)
    write_report(stats, failed_by, noted_by, brands)
    print(f"natural home badge: {stats['passed']} badged ({stats['certified']} certified) of {stats['eligible']} "
          f"home products — {REPORT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
