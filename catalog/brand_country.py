#!/usr/bin/env python3
"""The country a brand is based in: `country` on a registry brand, an ISO
3166 alpha-2 code ("US", "NG", "GB"), and `country_source`, the evidence it
came from. The app's and the site's Country filter read it (owner,
2026-11-26: "Let's put a filter for the country the company is founded").

Nobody recorded where each company was founded, so this is where the brand
is based, which is what the research did record. Evidence, strongest first:

  research  the by-country scans (catalog/research/*/brands.json). A scan
            files a diaspora brand under the founder's heritage country
            (Eloli: Cameroon, run from Montreal); for those the country the
            scan saw the store registered in is used instead.
  currency  a brand that prices in naira is in Nigeria. One-country
            currencies only: euros and CFA francs name no country.
  place     the registry's `city` when it is a country name ("Kenya"), a
            known city abroad ("Lagos") or a US state ("GA").
  store     the country on the store's public /meta.json
            (catalog/store_countries.json). It is the billing address, which
            is not always home (ships_from.py: Ziva Lagos bills from the UK),
            so it is last.

Whatever the evidence says has to agree with `ships_from`, which is research
too: a brand marked "ships from Africa" is never given a European country.
When they disagree the brand gets no country and is listed for a person.

    python3 catalog/brand_country.py              # report, change nothing
    python3 catalog/brand_country.py --backfill   # write country onto brands.json
    python3 catalog/brand_country.py --fetch      # read /meta.json for stores not yet in store_countries.json
"""
import json
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ships_from import region  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
BRANDS = ROOT / "catalog" / "brands.json"
RESEARCH = ROOT / "catalog" / "research"
STORES = ROOT / "catalog" / "store_countries.json"

# The names the scans and the registry's `city` use.
NAMES = {
    "United States": "US", "US": "US", "USA": "US", "UK": "GB", "United Kingdom": "GB", "England": "GB", "Scotland": "GB",
    "Wales": "GB", "Canada": "CA", "Nigeria": "NG", "Ghana": "GH", "Kenya": "KE", "South Africa": "ZA", "Senegal": "SN",
    "Mali": "ML", "Togo": "TG", "Benin": "BJ", "Ethiopia": "ET", "Rwanda": "RW", "Botswana": "BW", "Zimbabwe": "ZW",
    "Uganda": "UG", "Cameroon": "CM", "Netherlands": "NL", "Lesotho": "LS", "Sweden": "SE", "France": "FR",
    "Germany": "DE", "Côte d'Ivoire": "CI", "Ivory Coast": "CI", "Aruba": "AW", "Austria": "AT", "Cayman Islands": "KY",
    "Chad": "TD", "Comoros": "KM", "DR Congo": "CD", "Republic of the Congo": "CG", "Eritrea": "ER", "Finland": "FI",
    "Gambia": "GM", "Haiti": "HT", "Iceland": "IS", "Ireland": "IE", "Italy": "IT", "Norway": "NO", "Portugal": "PT",
    "Sierra Leone": "SL", "Sudan": "SD", "Tanzania": "TZ", "Belgium": "BE", "United Arab Emirates": "AE",
    "US Virgin Islands": "VI", "Jamaica": "JM", "Dominican Republic": "DO", "Martinique": "MQ", "Guadeloupe": "GP",
    "Bahamas": "BS", "Saint Vincent and the Grenadines": "VC", "Somalia": "SO", "Eswatini": "SZ", "Spain": "ES",
    "Switzerland": "CH", "Denmark": "DK", "Barbados": "BB", "Trinidad and Tobago": "TT", "Morocco": "MA",
    "Egypt": "EG", "Tunisia": "TN", "Zambia": "ZM", "Malawi": "MW", "Namibia": "NA", "Mozambique": "MZ",
    "Angola": "AO", "Liberia": "LR", "Burkina Faso": "BF", "Niger": "NE", "Guinea": "GN", "Madagascar": "MG",
    "Mauritius": "MU", "Puerto Rico": "PR", "Singapore": "SG", "Australia": "AU", "Brazil": "BR",
}
# Cities abroad the registry names without a country.
CITIES = {
    "London": "GB", "Manchester": "GB", "Birmingham, UK": "GB", "Bristol": "GB", "Leeds": "GB", "Nottingham": "GB",
    "Lagos": "NG", "Lekki": "NG", "Abuja": "NG", "Ikeja": "NG", "Port Harcourt": "NG", "Ibadan": "NG",
    "Nairobi": "KE", "Mombasa": "KE", "Accra": "GH", "Kumasi": "GH", "Dakar": "SN", "Kigali": "RW",
    "Johannesburg": "ZA", "Cape Town": "ZA", "Durban": "ZA", "Pretoria": "ZA", "Addis Ababa": "ET", "Asmara": "ER",
    "Kampala": "UG", "Dar es Salaam": "TZ", "Gaborone": "BW", "Harare": "ZW", "Abidjan": "CI", "Bamako": "ML",
    "Douala": "CM", "Freetown": "SL", "Khartoum": "SD", "Maseru": "LS", "Lomé": "TG", "Cotonou": "BJ",
    "Paris": "FR", "Lyon": "FR", "Marseille": "FR", "Berlin": "DE", "Hamburg": "DE", "Amsterdam": "NL",
    "Rotterdam": "NL", "Stockholm": "SE", "Dublin": "IE", "Brussels": "BE", "Lisbon": "PT", "Milan": "IT",
    "Oslo": "NO", "Helsinki": "FI", "Reykjavik": "IS", "Zurich": "CH", "Dubai": "AE",
    "Toronto": "CA", "Montreal": "CA", "Vancouver": "CA", "Ottawa": "CA", "Edmonton": "CA", "Calgary": "CA",
    "Niamey": "NE", "Mississauga": "CA", "Bolgatanga": "GH", "Haarlem": "NL", "Kingston": "JM", "Port-au-Prince": "HT", "Nassau": "BS",
}
# Brands a person ruled on, where the evidence disagreed: id -> country.
# Each has its reason beside it.
HAND = {
    # Lagos workshop and flagship store (howwemadeitinafrica.com, lionessesofafrica.com); the store bills from the UK.
    "zashadu": "NG",
    # Toronto label (blogto.com 2018, 15percentpledge.org); the store is registered in Canada.
    "ofuure": "CA",
    # "Founded in Birmingham" on its Faire page; the store is registered in the UK.
    "taelor-boutique": "GB",
    # Hapsatou Sy's company is in Paris (premiumbeautynews.com); the store bills from the UK.
    "hapsatousy-la-maison": "FR",
    # Accra: the registry's city is just "Ghana".
    "hamamat-africa": "GH",
    "r-r-skincare": "GH",
    # Amsterdam label by a Gambian-heritage founder (west-africa scan, diaspora row, store in NL).
    "jekkah": "NL",
    # Christiansted, St Croix: the US Virgin Islands have their own code.
    "ib-designs": "VI",
    # Anita's brand is in Guadeloupe, which has its own code (registry city "France (Guadeloupe)").
    "mango-butterfull": "GP",
    # Hayes, west London; the store is registered in the UK.
    "natural-babe": "GB",
    # Los Angeles loungewear label; only the store's billing address is in Hong Kong.
    "local-european": "US",
    # Stores that did not answer on 2026-11-26. The registry's city was read
    # from the store itself when the brand was added, and is a US one.
    "freshpawz": "US",               # Los Angeles
    "perryco": "US",                 # Los Angeles
    "the-fragrance-chest": "US",     # Oxon Hill, Maryland
    "chika-paper-studio": "US",      # Lexington
    "hot-sauce-shero": "US",         # North Miami
    "funky-mello": "US",             # Elgin
    "bernadette-thompson": "US",     # Yonkers
    "people-of-color-beauty": "US",  # Laguna Beach
    "iv-kulture": "US",              # Hamden
    "infinite-age": "US",            # Tacoma
    "seventeenth-watches": "US",     # Las Vegas
    "paint-by-shawn-denise": "US",   # Decatur
    "dream-fury-comics": "US",       # Bronx
    "xen-matcha": "US",              # Norcross
    "babalid": "US",                 # Monroe
    "2t-water": "US",                # Georgia (the registry's tagline)
    "herbin-co": "US",               # Atlanta (the registry's tagline)
    "topicals": "US",                # Los Angeles
    "ten-to-one": "US",              # New York
    "yeezy": "US",                   # Los Angeles
    # Diaspora rows of the west-africa scan: the brand is in a US city and
    # makes or posts from Africa, which is what `ships_from` records.
    "ahsmah": "US",              # Los Angeles
    "troy-massa": "US",          # Burtonsville, Maryland
    "sai-sankoh": "US",          # Dallas
    "washington-roberts": "US",  # Brooklyn
    "chuks-collins": "US",       # New York
}
PROVINCES = {"ON", "QC", "BC", "AB", "MB", "SK", "NS", "NB", "NL", "PE"}
STATES = set("AL AK AZ AR CA CO CT DE FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND "
             "OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY DC".split())
# A brand that prices in one of these is based where the currency is.
CURRENCY = {"NGN": "NG", "KES": "KE", "ZAR": "ZA", "GHS": "GH", "RWF": "RW", "BWP": "BW", "GBP": "GB", "SEK": "SE",
            "CAD": "CA", "CHF": "CH", "AED": "AE"}


def domain_key(domain):
    return (domain or "").lower().removeprefix("www.")


def named(text):
    """The country a scan's `country` cell names: "UK", "Nigeria/Ghana" (the
    first), "Zimbabwe (Netherlands-based)" (where it is based)."""
    text = (text or "").strip()
    based = re.search(r"\(([A-Za-z' ]+)-based\)", text)
    if based:
        return NAMES.get(based.group(1).strip())
    head = re.split(r"[/(]", text)[0].strip()
    return NAMES.get(head)


def research_rows():
    """Every scan row by store domain; a later scan replaces an earlier one."""
    rows = {}
    for path in sorted(RESEARCH.glob("**/brands.json")):
        try:
            data = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        scan = str(path.parent.relative_to(RESEARCH))
        for r in data if isinstance(data, list) else []:
            if isinstance(r, dict) and r.get("domain"):
                for d in {domain_key(r["domain"]), domain_key(r.get("final_domain"))} - {""}:
                    rows[d] = {**r, "_scan": scan}
    return rows


def from_research(row):
    if not row:
        return None
    if row.get("state"):
        return "US"  # only the US scans name a state
    country = named(row.get("country"))
    if row.get("diaspora") in (True, "True", "true"):
        # Filed under the founder's heritage; the store is somewhere else.
        return (row.get("meta_country") or "").upper() or from_place(row.get("city")) or None
    return country


def from_place(city):
    """A country from the registry's `city`: "Kenya", "Lagos", "Toronto, ON",
    "GA". A bare US city ("Springfield") says nothing by itself."""
    city = (city or "").strip()
    if not city:
        return None
    parts = [p.strip() for p in city.split(",")]
    tail = parts[-1]
    if tail in NAMES:
        return NAMES[tail]
    if len(parts) > 1 and tail in PROVINCES:
        return "CA"
    if city in CITIES:
        return CITIES[city]
    if parts[0] in CITIES and len(parts) > 1 and tail not in STATES:
        return CITIES[parts[0]]
    if tail in STATES:
        return "US"
    return None


def agrees(country, brand):
    """Whether the country sits in the brand's `ships_from` region. A brand
    with no region is taken to ship from the US."""
    return region(country) == brand.get("ships_from")


def decide(brand, rows, stores):
    """(country, source) for one brand, or (None, why not).

    `ships_from` is research too, so it referees: the first of research,
    currency and place that sits in its region wins. It describes the
    parcel, though, not the company (Washington Roberts is in Brooklyn and
    ships from Lagos), so two of the three agreeing with each other also
    win. The store's own country only ever confirms: alone when it matches
    the region, or with one other source when the brand has no region.
    """
    if brand["id"] in HAND:
        return HAND[brand["id"]], "hand"
    code = lambda v: v if re.fullmatch(r"[A-Z]{2}", (v or "").upper()) else None  # noqa: E731
    said = {"research": code(from_research(rows.get(domain_key(brand.get("domain"))))),
            "currency": code(CURRENCY.get((brand.get("currency") or "").upper())),
            "place": code(from_place(brand.get("city")))}
    said = {k: v.upper() for k, v in said.items() if v}
    store = code((stores.get(brand["id"]) or "").upper())
    for source, country in said.items():
        if agrees(country, brand):
            return country, source
    for source, country in said.items():
        others = [k for k, v in said.items() if k != source and v == country]
        if others:
            return country, f"{source}+{others[0]}"
        if store == country and not brand.get("ships_from"):
            return country, f"{source}+store"
    if store and agrees(store, brand):
        return store, "store"
    if store:
        said["store"] = store
    if not said:
        return None, "no evidence"
    return None, "; ".join(f"{k} says {v}" for k, v in said.items()) + f"; ships_from is {brand.get('ships_from') or 'none (US)'}"


def backfill(brands, rows, stores):
    """Sets or clears `country` on every brand. Returns (set, unresolved)."""
    unresolved = []
    for b in brands:
        country, source = decide(b, rows, stores)
        if country:
            b["country"], b["country_source"] = country, source
        else:
            b.pop("country", None)
            b.pop("country_source", None)
            unresolved.append((b["id"], source))
    return len(brands) - len(unresolved), unresolved


def fetch(brands, stores, pause=0.7, get=None):
    """Reads /meta.json for Shopify stores not yet in the file, one at a
    time (Shopify answers 429 to a burst). Returns how many were read."""
    def read(domain):
        req = urllib.request.Request(f"https://{domain}/meta.json", headers={"User-Agent": "Mozilla/5.0 (compatible; MarracatCatalog)"})
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.load(r)
    get = get or read
    n = 0
    for b in brands:
        if b["id"] in stores or not (b.get("platform", "shopify") == "shopify" and b.get("shopify", True)):
            continue
        try:
            country = (get(b["domain"]).get("country") or "").upper()
        except (urllib.error.URLError, OSError, ValueError):
            country = ""
        if re.fullmatch(r"[A-Z]{2}", country):
            stores[b["id"]] = country
            n += 1
        time.sleep(pause)
    return n


def main(argv):
    brands = json.loads(BRANDS.read_text())
    stores = json.loads(STORES.read_text()) if STORES.exists() else {}
    if "--fetch" in argv:
        n = fetch(brands, stores)
        STORES.write_text(json.dumps(dict(sorted(stores.items())), indent=0) + "\n")
        print(f"read {n} stores; {len(stores)} on file")
    done, unresolved = backfill(brands, research_rows(), stores)
    if "--backfill" in argv:
        BRANDS.write_text(json.dumps(brands, indent=1, ensure_ascii=False) + "\n")
    by = {}
    for b in brands:
        if b.get("country"):
            by[b["country"]] = by.get(b["country"], 0) + 1
    print(f"{done} of {len(brands)} brands have a country; {len(unresolved)} do not")
    print(", ".join(f"{c} {n}" for c, n in sorted(by.items(), key=lambda kv: -kv[1])))
    for brand_id, why in unresolved:
        print(f"  no country: {brand_id}: {why}")


if __name__ == "__main__":
    main(sys.argv[1:])
