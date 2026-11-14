#!/usr/bin/env python3
"""Award the Marracat Lab Verified badge.

The rules are in catalog/lab_standard.md. A wellness product you swallow
(supplements, vitamins, herbs, teas and powders sold for wellness) earns it
when its own listing:

1. names a third-party certification programme that tests the finished
   product: NSF Certified for Sport, NSF/ANSI 173 or "NSF certified" (not an
   NSF-registered facility, which is a GMP audit of the plant), USP Verified,
   Informed Sport / Informed Choice, BSCG Certified, or Clean Label Project;
   or publishes a certificate of analysis (COA) or lab results from an
   independent / third-party / ISO 17025-accredited lab; and
2. names no ingredient banned somewhere: DMAA, DMHA, ephedra alkaloids,
   sibutramine, tianeptine, phenibut, kratom, yohimbe, higenamine, DHEA,
   kava, comfrey taken internally, and CBD, THC or delta-8 in something
   swallowed.

"Third-party tested" with no named programme or lab is noted, not passed:
nobody can check it. Topicals (deodorant, lubricants, balms), devices and
merch aren't judged. Read from each product's own title, description and
tags; nothing is fetched. Sets product["lab"] = True on passing products
(absent otherwise) and writes catalog/lab_report.md.

Usage:
    python3 catalog/lab_badge.py
    python3 catalog/lab_badge.py --explain <product-id>
    python3 catalog/lab_badge.py --report-only     # don't rewrite the catalog
"""
import argparse
import json
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from baby_badge import text_of, without_free_claims  # noqa: E402
from catalog_io import write_catalog  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Marracat" / "Resources" / "catalog.json"
REPORT = ROOT / "catalog" / "lab_report.md"

INGESTIBLE_SUBS = {"supplements", "herbs", "fitness-nutrition", "digestion", "immunity", "sleep-stress",
                   "mens-health", "womens-health"}
INGESTIBLE = re.compile(r"\b(capsules?|caps|tablets?|softgels?|gumm(?:y|ies)|powders?|tea|teas|tinctures?|"
                        r"extracts?|supplements?|vitamins?|multivitamins?|protein|collagen|elixirs?|sea ?moss|"
                        r"irish moss|bitters|drops|syrups?|shots?|greens|probiotics?|prebiotics?|electrolytes?|"
                        r"adaptogens?|herbs?|herbal blend|nutrition|chlorophyll|mushroom blend|"
                        r"(?:lions?|lion's) mane|ashwagandha|moringa|elderberry)\b", re.I)
TOPICAL = re.compile(r"\b(deodorants?|lubricants?|lube|balms?|salves?|lotions?|creams?|massage oils?|roll[- ]?on|"
                     r"soaps?|body wash|bath|steam|yoni (?:steam|wash)|oils? for (?:skin|hair)|serum|spray|"
                     r"condoms?|vibrator|toys?|book|journal|gift card|t-?shirt|tee|hoodie|mug|sticker|"
                     r"bandages?|first aid|thermometer|massager|device|candle)\b", re.I)

# Programmes that test the finished product (not just audit the plant).
PROGRAMMES = [
    ("NSF Certified for Sport", r"nsf certified for sport|certified for sport"),
    ("NSF/ANSI 173", r"nsf/ansi 173|nsf 173|ansi 173"),
    ("NSF certified", r"\bnsf[- ]certified\b|certified by nsf|nsf contents certified"),
    ("USP Verified", r"\busp[- ]verified\b|usp verification|usp dietary supplement verification"),
    ("Informed Sport / Informed Choice", r"informed[- ]sport|informed[- ]choice|informed ingredient"),
    ("BSCG Certified", r"\bbscg\b|banned substances control group"),
    ("Clean Label Project", r"clean label project"),
]
COA = re.compile(r"certificates? of analysis|\bcoas?\b|lab(?:oratory)? (?:test )?(?:results|reports?)|"
                 r"test results", re.I)
INDEPENDENT = re.compile(r"third[- ]party|independent(?:ly)?|iso ?17025|accredited lab|eurofins|alkemist|"
                         r"nsf international|sc labs|kaycha|botanacor|evio", re.I)
VAGUE = re.compile(r"third[- ]party[- ](?:lab[- ])?(?:tested|testing|verified)|independently tested|lab[- ]tested|"
                   r"tested for (?:purity|potency|heavy metals)", re.I)
FACILITY_ONLY = re.compile(r"nsf[- ]registered|registered (?:by|with) nsf|nsf (?:gmp|registered facility)", re.I)

# Each: (label, regex over the listing, where it is banned).
BANNED = [
    ("DMAA / DMHA", r"\bdmaa\b|1,3-dimethylamylamine|methylhexanamine|geranamine|\bdmha\b|"
     r"2-aminoisoheptane|octodrine",
     "FDA: DMAA is not a lawful dietary ingredient (2013 import alert 54-11; warning letters); DMHA warning "
     "letters 2019; banned in Canada, Australia and New Zealand; WADA S6 stimulant"),
    ("ephedra / ephedrine alkaloids", r"\bephedra\b|ephedrine|ma huang|ephedra sinica",
     "US ban on dietary supplements containing ephedrine alkaloids (21 CFR 119.1, 2004); restricted in "
     "the EU (Reg. 2019/650 adds ephedra to Reg. 1925/2006 Annex III Part A)"),
    ("sibutramine", r"sibutramine", "withdrawn in the EU and US (2010); undeclared in supplements, FDA warnings"),
    ("tianeptine", r"tianeptine",
     "FDA warnings (2018, 2022, 2025); banned in Alabama, Michigan, Ohio, Tennessee and other states; "
     "prescription-only where approved"),
    ("phenibut", r"phenibut|β-phenyl-gaba|beta-phenyl-gaba",
     "FDA: not a lawful dietary ingredient (warning letters 2019); Schedule 9 prohibited in Australia "
     "(Poisons Standard 2018); controlled in Hungary, Italy, Lithuania"),
    ("kratom", r"kratom|mitragyna|mitragynine|7-hydroxymitragynine|7-oh",
     "controlled in Australia (Schedule 9), Denmark, Poland, Sweden, the UK (Psychoactive Substances Act "
     "2016) and in US states including Alabama, Arkansas, Indiana, Rhode Island, Vermont and Wisconsin"),
    ("yohimbe / yohimbine", r"yohimb|pausinystalia",
     "EU Reg. 2019/650 places yohimbe under Union scrutiny (Reg. 1925/2006 Annex III Part C); yohimbine "
     "is prescription-only in the UK and Australia (Poisons Standard Schedule 4)"),
    ("higenamine", r"higenamine|norcoclaurine|nandina",
     "WADA Prohibited List S3 (beta-2 agonist); FDA warning letters (2019) for supplements listing it"),
    ("DHEA", r"\bdhea\b|dehydroepiandrosterone|prasterone",
     "prescription-only in Canada (Prescription Drug List), Australia (Schedule 4) and the EU; WADA S1 "
     "anabolic agent"),
    ("kava", r"\bkava\b|piper methysticum|kavalactone",
     "banned in food in the UK (Kava-kava in Food (England) Regulations 2002) and restricted in other EU "
     "states"),
    ("comfrey (internal use)", r"comfrey|symphytum",
     "FDA (2001) asked for comfrey to be removed from dietary supplements; Canada and Australia restrict "
     "internal use (pyrrolizidine alkaloids)"),
    ("CBD / THC / delta-8", r"\bcbd\b|cannabidiol|\bthc\b|tetrahydrocannabinol|delta[- ]?8|delta[- ]?9|"
     r"delta[- ]?10|\bhhc\b|full[- ]spectrum hemp extract",
     "FDA: CBD and THC are excluded from the dietary-supplement definition (21 USC 321(ff)(3)(B)); CBD in "
     "food is an unauthorised novel food in the EU and UK; banned outright in Hong Kong (2023); delta-8 THC "
     "is banned or restricted in more than 20 US states"),
]


def eligible(product):
    if product.get("category") != "wellness":
        return False
    title = f"{product.get('title') or ''} {product.get('product_type') or ''}"
    if TOPICAL.search(title):
        return False
    return bool(INGESTIBLE.search(title)) or bool(set(product.get("subs") or []) & INGESTIBLE_SUBS)


def certification(text):
    """The named programme or published COA in the listing, or None."""
    for name, pattern in PROGRAMMES:
        if re.search(pattern, text, re.I):
            if name == "NSF certified" and FACILITY_ONLY.search(text) and not re.search(
                    r"\bnsf[- ]certified (?:product|for)|certified by nsf", text, re.I):
                continue
            return name
    m = COA.search(text)
    if m and INDEPENDENT.search(text):
        return "third-party certificate of analysis"
    return None


def evaluate(product):
    """-> (passes: bool, failures: [str], notes: [str])"""
    if not eligible(product):
        return False, ["not a wellness product the badge covers"], []
    text = text_of(product)
    claims = without_free_claims(text)
    failures, notes = [], []
    for label, pattern, _src in BANNED:
        m = re.search(pattern, claims, re.I)
        if m:
            failures.append(f"{label}: {m.group(0)}")
    cert = certification(text)
    if not cert:
        if VAGUE.search(text):
            failures.append("third-party testing claimed, no programme or lab named")
        elif FACILITY_ONLY.search(text) or re.search(r"\bc?gmp\b", text, re.I):
            failures.append("facility audit only (GMP / NSF-registered), product not certified")
        else:
            failures.append("no third-party certification stated")
    else:
        notes.append(f"certified: {cert}")
    return not failures, failures, notes


def apply(products, store=None):
    """Rewrite `lab` on every product. Returns report inputs."""
    stats = {"eligible": 0, "claimed": 0, "passed": 0}
    failed_by, noted_by, brands = {}, {}, set()
    for p in products:
        p.pop("lab", None)
        if not eligible(p):
            continue
        stats["eligible"] += 1
        ok, failures, notes = evaluate(p)
        if any(n.startswith("certified") for n in notes) or any(
                f.startswith(("third-party testing claimed", "facility audit")) for f in failures):
            stats["claimed"] += 1
        if ok:
            p["lab"] = True
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
    lines = ["# Marracat Lab Verified — badge report", "",
             f"{stats['eligible']} eligible wellness products · {stats['claimed']} claiming some testing · "
             f"**{stats['passed']} badged** across {len(brands)} brands.", "",
             "The standard is in catalog/lab_standard.md: a named third-party programme (NSF, USP, Informed, BSCG, "
             "Clean Label Project) or a published independent certificate of analysis, and no ingredient banned "
             "anywhere. Read from each product's own description; nothing is fetched.", "",
             "## Why products fail", "", "| Reason | Products |", "|---|---|"]
    lines += [f"| {k} | {v} |" for k, v in sorted(failed_by.items(), key=lambda kv: -kv[1])]
    lines += ["", "## How badged products are certified", "", "| Programme | Products |", "|---|---|"]
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
        ok, failures, notes = evaluate(p)
        print(f"{p['title']} ({p['brand']})\n  verdict: {'LAB VERIFIED' if ok else 'not badged'}\n"
              f"  failures: {failures}\n  notes: {notes}")
        return
    stats, failed_by, noted_by, brands = apply(products)
    if not args.report_only:
        write_catalog(CATALOG, catalog)
    write_report(stats, failed_by, noted_by, brands)
    print(f"lab verified badge: {stats['passed']} badged of {stats['eligible']} wellness products — "
          f"{REPORT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
