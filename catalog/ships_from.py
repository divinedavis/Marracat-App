#!/usr/bin/env python3
"""Where a brand ships from, as the region the app labels ("Ships from
Africa", owner 2026-10-14): `ships_from` on a registry brand, one of
africa, europe, canada, caribbean or elsewhere. US brands carry none.

It comes from research — the country the brand is based in — not from the
store's /meta.json, whose `country` is the Shopify billing address: Ziva
Lagos prices in naira from Lagos but bills from the UK, KIZA (Rwanda) from
Estonia (2026-10-15).

    python3 catalog/ships_from.py --backfill   # label brands that price in a non-dollar currency
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BRANDS = ROOT / "catalog" / "brands.json"
REGIONS = ("africa", "europe", "canada", "caribbean", "elsewhere")

AFRICA = set("DZ AO BJ BW BF BI CV CM CF TD KM CG CD CI DJ EG GQ ER SZ ET GA GM GH GN GW KE LS LR LY MG MW ML MR MU "
             "MA MZ NA NE NG RW ST SN SC SL SO ZA SS SD TZ TG TN UG ZM ZW".split())
EUROPE = set("AL AD AT BY BE BA BG HR CY CZ DK EE FI FR DE GR HU IS IE IT LV LI LT LU MT MD MC ME NL MK NO PL PT RO "
             "SM RS SK SI ES SE CH UA GB VA GG JE IM".split())
CARIBBEAN = set("AG BS BB BZ CU DM DO GD HT JM KN LC VC TT PR VI VG KY AW CW SX BQ GP MQ BL MF TC AI MS".split())
# The countries the 2026-10 scans name, by the names they use.
COUNTRY = {"Nigeria": "NG", "Ghana": "GH", "Senegal": "SN", "Mali": "ML", "Togo": "TG", "Benin": "BJ",
           "South Africa": "ZA", "Kenya": "KE", "Ethiopia": "ET", "Rwanda": "RW", "Botswana": "BW",
           "Zimbabwe": "ZW", "Uganda": "UG", "Cameroon": "CM", "UK": "GB", "Netherlands": "NL",
           "Lesotho": "LS", "Sweden": "SE", "France": "FR", "Germany": "DE", "Canada": "CA", "US": "US"}
# A brand that prices in one of these is based where the currency is.
CURRENCY = {"NGN": "africa", "KES": "africa", "ZAR": "africa", "GHS": "africa", "XOF": "africa", "RWF": "africa",
            "BWP": "africa", "GBP": "europe", "EUR": "europe", "SEK": "europe", "CAD": "canada"}


def region(country):
    """Region for an ISO 3166 alpha-2 code; None for the US or no country."""
    c = (country or "").upper()
    if not c or c == "US":
        return None
    if c == "CA":
        return "canada"
    if c in AFRICA:
        return "africa"
    if c in EUROPE:
        return "europe"
    if c in CARIBBEAN:
        return "caribbean"
    return "elsewhere"


def backfill(brands):
    """Label every non-dollar brand without one by its currency; a French
    brand in Guadeloupe is Caribbean. Returns how many were labelled."""
    n = 0
    for b in brands:
        if b.get("ships_from"):
            continue
        r = CURRENCY.get((b.get("currency") or "USD").upper())
        if r == "europe" and "guadeloupe" in (b.get("city") or "").lower():
            r = "caribbean"
        if r:
            b["ships_from"] = r
            n += 1
    return n


if __name__ == "__main__":
    if "--backfill" in sys.argv:
        brands = json.loads(BRANDS.read_text())
        n = backfill(brands)
        BRANDS.write_text(json.dumps(brands, indent=1, ensure_ascii=False) + "\n")
        print(f"ships_from set on {n} brands")
    else:
        print(__doc__)
