#!/usr/bin/env python3
"""Dollar rates for brands that don't charge in dollars.

The app shows each product in its brand's own currency, but sorts, filters
and estimates in dollars, so every brand record carries `usd_rate`: dollars
per one unit of its currency. Approximate on purpose: it is set when the
catalog is built, and the brand's checkout charges the real amount.

Sources (both free, no key):
  - The European Central Bank's reference rates via Frankfurter, for the
    currencies the ECB publishes (GBP, EUR, SEK, ZAR, CAD, CHF).
  - ExchangeRate-API's open endpoint for the ones it doesn't (NGN, KES, GHS,
    XOF, RWF, BWP, the Caribbean's JMD, BBD, BSD and XCD, and AED).
    Its terms ask for attribution: "Rates by Exchange Rate API"
    (https://www.exchangerate-api.com), credited in the app's price note.
A rate that is missing or wildly off keeps the fallback below, so a bad
answer never prices ₦32,000 as $32,000.
"""
import json
import urllib.request

ECB = "https://api.frankfurter.dev/v1/latest?base=USD&symbols=GBP,EUR,SEK,ZAR,CAD,CHF"
OPEN = "https://open.er-api.com/v6/latest/USD"

# Units of each currency per US dollar, 2026-10-08 (ECB / ExchangeRate-API);
# CAD, XOF, RWF and BWP 2026-10-15, for the brands held for the owner's test
# checkout (catalog/research/2026-10-15-scan-import). The Caribbean ones
# 2026-10-23 for the Canada and Caribbean scan (owner, 2026-10-22); BBD, BSD
# and XCD are pegged to the dollar, JMD floats. AED (pegged at 3.6725)
# 2026-10-23 for a Dubai-based brand in the North Africa scan. CHF (ECB,
# 2026-11-11) for Sahara Accessories, Switzerland (owner, 2026-11-11: "cant
# you just add chf exchange rate?").
FALLBACK_PER_USD = {"GBP": 0.757, "EUR": 0.894, "SEK": 10.0, "ZAR": 16.65, "CAD": 1.422,
                    "NGN": 1331.0, "KES": 129.6, "GHS": 11.65, "XOF": 586.7, "RWF": 1478.0, "BWP": 13.95,
                    "JMD": 158.8, "BBD": 2.0, "BSD": 1.0, "XCD": 2.7, "AED": 3.6725, "CHF": 0.8299}
ECB_CURRENCIES = ("GBP", "EUR", "SEK", "ZAR", "CAD", "CHF")


def _get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "Marracat catalog"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r)


def sane(currency, per_usd):
    """A live rate within a factor of two of the fallback; anything else is a
    bad answer, not a currency crisis."""
    ref = FALLBACK_PER_USD.get(currency)
    return ref is not None and isinstance(per_usd, (int, float)) and ref / 2 < per_usd < ref * 2


def per_usd(fetch=_get):
    """{currency: units per USD}, live where the sources answer sanely."""
    rates = dict(FALLBACK_PER_USD)
    for url in (ECB, OPEN):
        try:
            got = fetch(url).get("rates") or {}
        except Exception:
            continue
        for cur in FALLBACK_PER_USD:
            if cur in got and sane(cur, got[cur]) and (url == ECB or cur not in ECB_CURRENCIES):
                rates[cur] = float(got[cur])
    return rates


def usd_rates(fetch=_get):
    """{currency: dollars per one unit}, rounded for a stable catalog diff."""
    return {cur: round(1 / v, 6) for cur, v in per_usd(fetch).items()}


def apply(brands, rates):
    """Stamp `usd_rate` on every brand that charges in a currency we know.
    Dollar brands get none; an unknown currency gets none (the app then
    leaves it out of dollar filters instead of guessing)."""
    for b in brands:
        cur = (b.get("currency") or "USD").upper()
        if cur == "USD":
            b.pop("usd_rate", None)
        elif cur in rates:
            b["usd_rate"] = rates[cur]
    return brands
