#!/usr/bin/env python3
"""Award the Marracat Safe Fabric badge.

The rules are in catalog/fabric_standard.md. The owner's rule (2026-10-08):
"clothes that don't include any harmful synthetic materials that are banned
anywhere". A garment earns it when its own listing:

1. states its fibre composition (shared parser: catalog/fiber_badge.py);
2. names no treatment banned somewhere: PFAS / fluorocarbon water- or
   stain-repellent finishes (California AB 1817, New York, EU), a
   water-repellent (DWR) or stain-resistant finish not stated PFAS-free,
   flame-retardant finishes (EU POPs, California), antimicrobial or
   anti-odour biocide treatments (triclosan isn't approved under the EU
   Biocidal Products Regulation), or PVC / vinyl not stated phthalate-free
   (REACH Annex XVII entry 51 restricts the plasticising phthalates);
3. is less than half synthetic (polyester, nylon, acrylic, elastane,
   polyurethane, PVC: 50% or more of the stated fibre), unless the listing
   states an OEKO-TEX Standard 100, bluesign or GOTS certification, which test
   the finished fabric for the banned substances a listing can't show.

What a listing can't show (azo dyes, nonylphenol ethoxylates, DMF, residual
PFAS) is covered only by that certification or by a natural-fibre
composition; the standard says so plainly.

Clothing only, as for Natural Fiber. Sets product["fabric"] = True on
passing products (absent otherwise) and writes catalog/fabric_report.md.

Usage:
    python3 catalog/fabric_badge.py
    python3 catalog/fabric_badge.py --explain <product-id>
    python3 catalog/fabric_badge.py --report-only     # don't rewrite the catalog
"""
import argparse
import json
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import fiber_badge as fb  # noqa: E402
from baby_badge import without_free_claims  # noqa: E402
from catalog_io import write_catalog  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = fb.CATALOG
REPORT = ROOT / "catalog" / "fabric_report.md"

SYNTHETIC_LIMIT = 50  # percent: 50% or more synthetic fails without certification

CERTIFIED = re.compile(r"\boeko[- ]?tex\b|\bbluesign\b|\bgots\b|global organic textile standard", re.I)
PFAS_FREE = re.compile(r"\b(pfas|pfc|pfcs|fluorocarbon|fluorine|pfoa)[- ]free\b|\bfree (?:of|from) (?:pfas|pfcs?|"
                       r"fluorocarbons?|pfoa)\b|\bc0 dwr\b|\bnon[- ]fluorinated\b", re.I)
PHTHALATE_FREE = re.compile(r"phthalate[- ]free|free (?:of|from) phthalates|non[- ]phthalate", re.I)

TREATMENTS = [
    ("PFAS / fluorocarbon finish", r"\bpfas\b|\bpfcs?\b|perfluoro|polyfluoro|fluorocarbon|\bpfoa\b|\bpfos\b|"
     r"teflon|scotchgard|\bc6\b|\bc8\b",
     "California AB 1817 (Health & Safety Code 108970) bans intentionally added PFAS in textiles from "
     "2025; New York S6291A bans PFAS in apparel from 2025; EU REACH Annex XVII entries 68 (PFOA) and "
     "79 (PFHxA, 2024) restrict them in textiles"),
    ("flame-retardant finish", r"flame[- ]retardant|fire[- ]retardant|\bfr[- ]treated\b|"
     r"flame[- ]resistant (?:treatment|finish|chemical|coating)|\bpbdes?\b|\bdeca-?bde\b",
     "EU POPs Regulation 2019/1021 bans PBDEs and other brominated flame retardants; California AB 2998 "
     "(2020) bans flame retardants in children's products, mattresses and upholstery"),
    ("antimicrobial treatment", r"anti-?microbial|anti-?bacterial (?:treatment|finish|fabric|technology)|"
     r"\btriclosan\b|\bmicroban\b|\bpolygiene\b|silver[- ]ion|\bx-?static\b|anti-?odou?r (?:treatment|finish|"
     r"technology)|odou?r[- ]control (?:treatment|technology)",
     "triclosan is not approved under the EU Biocidal Products Regulation 528/2012 (Commission "
     "Implementing Decision 2016/110), so articles treated with it can't be sold in the EU; an "
     "undisclosed biocide can't be shown not to be one"),
]
DWR = re.compile(r"\bdwr\b|durable water[- ]repellent|water[- ]repellent (?:finish|coating|treatment)|"
                 r"stain[- ](?:resistant|repellent|release) (?:finish|coating|treatment)|"
                 r"water[- ]repellent", re.I)
PVC = re.compile(r"\bpvc\b|\bvinyl\b|polyvinyl chloride", re.I)
NOT_FABRIC_VINYL = re.compile(r"vinyl (?:sticker|decal|print|lettering|transfer|graphic)|heat transfer vinyl|"
                              r"\bhtv\b|vinyl (?:records?|lps?|albums?|press)|(?:reggae|record|music|dj|classic) vinyl|"
                              r"on vinyl", re.I)


def evaluate(product):
    """-> (passes: bool, failures: [str], notes: [str])"""
    if not fb.eligible(product):
        return False, ["not clothing the badge covers"], []
    text = fb.text_of(product)
    comp = fb.composition(text)
    if not comp:
        return False, ["composition not stated"], []
    if not comp["complete"]:
        return False, ["composition incomplete"], []
    failures, notes = [], []
    claims = without_free_claims(text)
    for label, pattern, _src in TREATMENTS:
        m = re.search(pattern, claims, re.I)
        if m:
            failures.append(f"{label}: {m.group(0)}")
    if DWR.search(claims) and not PFAS_FREE.search(text) and not any(f.startswith("PFAS") for f in failures):
        failures.append(f"water-repellent finish not stated PFAS-free: {DWR.search(claims).group(0)}")
    pvc_part = any(name == "PVC" for _, name, _ in comp["parts"])
    pvc_word = PVC.search(claims) and not NOT_FABRIC_VINYL.search(text)
    if (pvc_part or pvc_word) and not PHTHALATE_FREE.search(text):
        failures.append("PVC / vinyl not stated phthalate-free")
    synthetic = comp["share"].get("synthetic", 0)
    certified = bool(CERTIFIED.search(text))
    if synthetic >= SYNTHETIC_LIMIT and not certified:
        failures.append(f"half or more synthetic, not certified: {round(synthetic)}% synthetic")
    if certified:
        notes.append("OEKO-TEX / bluesign / GOTS certified")
    if comp["share"].get("regenerated"):
        notes.append("regenerated cellulose (viscose, modal, lyocell)")
    if comp["varies"]:
        notes.append("fibre content varies by colour")
    if 0 < synthetic < SYNTHETIC_LIMIT:
        notes.append("some synthetic fibre")
    return not failures, failures, notes


def apply(products, store=None):
    """Rewrite `fabric` on every product. Returns report inputs."""
    stats = {"eligible": 0, "stated": 0, "passed": 0}
    failed_by, noted_by, brands = {}, {}, set()
    for p in products:
        p.pop("fabric", None)
        if not fb.eligible(p):
            continue
        stats["eligible"] += 1
        ok, failures, notes = evaluate(p)
        if not (failures and failures[0] == "composition not stated"):
            stats["stated"] += 1
        if ok:
            p["fabric"] = True
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
    lines = ["# Marracat Safe Fabric — badge report", "",
             f"{stats['eligible']} eligible garments · {stats['stated']} stating a composition · "
             f"**{stats['passed']} badged** across {len(brands)} brands.", "",
             "The standard is in catalog/fabric_standard.md: composition stated, no treatment banned anywhere, "
             f"and under {SYNTHETIC_LIMIT}% synthetic unless OEKO-TEX / bluesign / GOTS certified. Read from each "
             "product's own description; nothing is fetched.", "",
             "## Why products fail", "", "| Reason | Products |", "|---|---|"]
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
        ok, failures, notes = evaluate(p)
        print(f"{p['title']} ({p['brand']})\n  composition: {fb.composition(fb.text_of(p))}\n"
              f"  verdict: {'SAFE FABRIC' if ok else 'not badged'}\n  failures: {failures}\n  notes: {notes}")
        return
    stats, failed_by, noted_by, brands = apply(products)
    if not args.report_only:
        write_catalog(CATALOG, catalog)
    write_report(stats, failed_by, noted_by, brands)
    print(f"safe fabric badge: {stats['passed']} badged of {stats['eligible']} garments — "
          f"{REPORT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
