"""A store that resells other labels lists only its own (2026-11-04: Hair
Majesty sells MIZANI and Design Essentials beside its own wigs)."""
import build_catalog as bc

BRAND = {"id": "hm", "domain": "hm.example", "category": "hair", "exclude_vendors": ["MIZANI", "Design Essentials"]}


def row(vendor, brand=BRAND):
    return bc.normalize({"id": 1, "handle": "x", "title": "Body Wave Wig 20 inch", "product_type": "", "vendor": vendor,
                         "images": [{"src": "https://cdn.example/1.jpg"}],
                         "variants": [{"id": 2, "title": "Default Title", "price": "99.00", "available": True}]}, brand)


def test_named_vendors_are_skipped_whatever_the_case():
    assert row("MIZANI") is None
    assert row("DESIGN ESSENTIALS") is None
    assert row(" design essentials ") is None


def test_the_brands_own_products_stay():
    assert row("Hair Majesty") is not None
    assert row("") is not None


def test_a_brand_without_the_list_keeps_everything():
    assert row("MIZANI", {"id": "x", "domain": "x.example", "category": "hair"}) is not None
