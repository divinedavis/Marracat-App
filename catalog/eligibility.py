"""What a product says it is, for the label scanners that decide by words.

Titles alone miss a lot: FORVR Mood names its perfumes "NDA" and "I AM HER"
with no product type, so Clear Scent never read their published lists (owner,
2026-10-09). The product's own URL handle ("nda-edp-1-7-oz") and the store's
tags ("fragrance") say what it is, so a scanner's positive keywords now look
at those too. Exclusions (sets, bottles, candles…) look at the title, type and
handle but not tags: a perfume tagged "candle lover" is still a perfume.

When none of those say anything, catalog/jev_eligibility.py may have asked
TypeSafe's Jev; its cached yes counts here.
"""
import json
import pathlib
import re
from urllib.parse import urlparse

VERDICTS = pathlib.Path(__file__).resolve().parent / "jev_eligibility.json"
MIN_P = 0.85
_cache = None


def handle_words(p):
    path = urlparse(p.get("url") or "").path.rstrip("/")
    return re.sub(r"[-_]+", " ", path.rsplit("/", 1)[-1])


def exclusion_text(p):
    return " ".join([p.get("title") or "", p.get("product_type") or "", handle_words(p)])


def positive_text(p):
    return " ".join([exclusion_text(p), " ".join(p.get("tags") or [])])


def jev_says(label, p):
    """Jev's cached yes for this label and product, if it was asked about
    exactly what the product shows now."""
    global _cache
    if _cache is None:
        _cache = json.loads(VERDICTS.read_text()) if VERDICTS.exists() else {}
    v = _cache.get(label, {}).get(p.get("id"))
    return bool(v) and v.get("seen") == seen_key(p) and v.get("p", 0) >= MIN_P


def jev_says_no(label, p, max_p=0.15):
    """Jev was sure this product is NOT what the label covers."""
    global _cache
    if _cache is None:
        _cache = json.loads(VERDICTS.read_text()) if VERDICTS.exists() else {}
    v = _cache.get(label, {}).get(p.get("id"))
    return bool(v) and v.get("seen") == seen_key(p) and v.get("p", 1) <= max_p


def seen_key(p):
    return f"{p.get('title')}|{p.get('product_type')}|{handle_words(p)}|{','.join(sorted(p.get('tags') or []))}"


def reset_cache():
    global _cache
    _cache = None
