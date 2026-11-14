"""Checkout add-ons aren't products (2026-10-30: Big Mouth Toothbrush lists
6- and 12-month protection plans and gift wrapping next to its brushes)."""
import build_catalog as bc

BRAND = {"id": "bm", "domain": "bm.example", "category": "wellness"}


def row(title):
    return bc.normalize({"id": 1, "handle": "x", "title": title, "product_type": "",
                         "images": [{"src": "https://cdn.example/1.jpg"}],
                         "variants": [{"id": 2, "title": "Default Title", "price": "9.99", "available": True}]}, BRAND)


def test_plans_warranties_and_wrap_services_are_skipped():
    for t in ["12 Month Electronic Protection Plan", "Extended Warranty", "Gift Wrapping",
              "Gift Wrap", "Gift Wrapping Service", "Upgraded Gift Wrapping"]:
        assert row(t) is None, t


def test_wrapping_paper_and_the_brush_stay():
    for t in ["Black Santa Gift Wrapping Paper", "Kente Gift Wrap Set | 4 Rolls", "Big Mouth Sonic Toothbrush 2.0"]:
        assert row(t) is not None, t
