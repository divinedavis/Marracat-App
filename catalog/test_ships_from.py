"""Ships-from regions and held brands (catalog/ships_from.py; owner, 2026-10-14/15)."""
import json
from pathlib import Path

import fx
import ships_from

BRANDS = json.loads((Path(__file__).resolve().parent / "brands.json").read_text())


def test_region_by_country():
    assert ships_from.region("NG") == "africa"
    assert ships_from.region("gb") == "europe"
    assert ships_from.region("CA") == "canada"
    assert ships_from.region("GP") == "caribbean"
    assert ships_from.region("SG") == "elsewhere"
    assert ships_from.region("US") is None and ships_from.region(None) is None


def test_backfill_labels_by_currency_and_keeps_research():
    brands = [{"id": "a", "currency": "NGN"}, {"id": "b", "currency": "GBP"}, {"id": "c"},
              {"id": "d", "currency": "EUR", "city": "France (Guadeloupe)"},
              {"id": "e", "currency": "GBP", "ships_from": "africa"}]
    assert ships_from.backfill(brands) == 3
    assert [b.get("ships_from") for b in brands] == ["africa", "europe", None, "caribbean", "africa"]


def test_registry_regions_are_known():
    bad = [b["id"] for b in BRANDS if b.get("ships_from") and b["ships_from"] not in ships_from.REGIONS]
    assert not bad, bad


def test_every_non_dollar_brand_has_a_region():
    bad = [b["id"] for b in BRANDS if (b.get("currency") or "USD") != "USD" and not b.get("ships_from")]
    assert not bad, bad


def test_held_brands_have_a_reason_and_a_dollar_rate():
    held = [b for b in BRANDS if b.get("hold")]
    assert all(isinstance(b["hold"], str) and b["hold"] for b in held)
    missing = sorted({b["currency"] for b in held
                      if (b.get("currency") or "USD") != "USD" and b["currency"] not in fx.FALLBACK_PER_USD})
    assert not missing, f"lifting a hold needs a dollar rate for {missing}"


def test_a_hold_says_when_it_was_set():
    # Dollar brands are held too since 2026-10-27 (a checkout behind the
    # store's sign-in page, a closed store): the date says when to re-check.
    import re
    undated = [b["id"] for b in BRANDS if b.get("hold") and (b.get("currency") or "USD") == "USD"
               and not re.search(r"\d{4}-\d{2}-\d{2}", b["hold"])]
    assert not undated, undated
