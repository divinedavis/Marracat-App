"""Swell stores in the catalog (catalog/build_catalog.py: shape_swell; owner,
2026-10-10: Yeezy, the first Swell brand)."""
import build_catalog as bc

P = "6a91f2d30942e900131a077b"


def product(**over):
    p = {
        "id": P, "name": "KP 01", "slug": "kp-01", "price": 30, "stock_status": "in_stock",
        "description": "80% Polyester<br>20% Spandex", "date_created": "2026-08-28T20:42:59.399Z",
        "attributes": {"slot": {"value": "Underwear"}},
        "images": [{"file": {"url": "https://cdn.swell.store/yzy-prod/a/kp-01_flat.png"}}, {"file": None}],
        "options": [
            {"name": "Color", "values": [{"id": "c1", "name": "White"}]},
            {"name": "Size", "values": [{"id": "s4", "name": "4"}, {"id": "s5", "name": "5"}]},
            {"name": "Option", "values": [{"id": "o1", "name": "blank"}]},
        ],
        "variants": {"count": 2, "results": [
            # Swell lists a variant's option values in no particular order.
            {"id": "6a91f2d30942e900131a07b1", "option_value_ids": ["c1", "o1", "s4"], "price": 30, "stock_status": "in_stock"},
            {"id": "6a91f2d30942e900131a07b0", "option_value_ids": ["s5", "c1", "o1"], "price": None, "stock_status": "out_of_stock"},
        ]},
    }
    p.update(over)
    return p


def test_a_swell_product_takes_shopifys_shape_with_its_swell_ids_beside():
    s = bc.shape_swell(product())
    assert s["handle"] == "kp-01" and s["swell_product"] == P and s["product_type"] == "Underwear"
    assert [i["src"] for i in s["images"]] == ["https://cdn.swell.store/yzy-prod/a/kp-01_flat.png"]
    v4, v5 = s["variants"]
    assert (v4["title"], v5["title"]) == ("White / 4", "White / 5"), "option order, no 'blank'"
    assert v4["swell"] == "6a91f2d30942e900131a07b1" and v4["id"] == bc.swell_number(v4["swell"])
    assert v5["price"] == "30", "a variant without a price takes the product's"
    assert v4["available"] and not v5["available"]


def test_variant_ids_fit_int64_and_javascript():
    n = bc.swell_number("ffffffffffffffffffffffff")
    assert 0 <= n < 2 ** 53


def test_a_product_with_no_options_is_its_own_variant_and_normalizes_with_its_url():
    s = bc.shape_swell(product(options=[], variants={"count": 0, "results": []}))
    assert len(s["variants"]) == 1 and s["variants"][0]["title"] == "Default Title"
    brand = {"id": "yeezy", "domain": "yeezy.com", "category": "clothing", "platform": "swell"}
    row = bc.normalize(bc.shape_swell(product()), brand)
    assert row["url"] == "https://yeezy.com/products/kp-01"
    assert row["swell_product"] == P and row["variants"][0]["swell"] == "6a91f2d30942e900131a07b1"
    assert row["price"] == 30.0 and row["available"]


def test_option_names_follow_the_variant_titles_and_skip_placeholders():
    """"Color / Size: White / 4", not "Option:" (owner, 2026-10-16); YEEZY's
    unused "Option" with only "blank" is left out, as in the titles."""
    brand = {"id": "yeezy", "domain": "yeezy.com", "category": "clothing", "platform": "swell"}
    assert bc.normalize(bc.shape_swell(product()), brand)["option_names"] == ["Color", "Size"]
    shopify = {"options": [{"name": "Color", "values": ["Black"]}, {"name": "Size", "values": ["S", "M"]}]}
    assert bc.option_names(shopify) == ["Color", "Size"]
    assert bc.option_names({"options": [{"name": "Title", "values": ["Default Title"]}]}) == []
    assert bc.option_names({}) == []
    no_options = bc.normalize(bc.shape_swell(product(options=[], variants={"count": 0, "results": []})), brand)
    assert "option_names" not in no_options
