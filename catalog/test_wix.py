"""Wix Stores brands in the catalog (catalog/build_catalog.py: shape_wix,
fetch_store_wix; owner, 2026-11-11: "lets do only one wix brand as a test")."""
import json

import build_catalog as bc

URL = "https://www.deseta.net/product-page/baby-angel-green-blanket"


def page(product=None, extra=""):
    ld = {"@context": "https://schema.org/", "@type": "Product",
          "name": "Organic Cotton Knit Baby Angel Blanket Green", "description": "Soft &amp; warm.",
          "image": [{"@type": "ImageObject", "contentUrl": "https://static.wixstatic.com/media/a.jpg"},
                    {"@type": "ImageObject", "contentUrl": "https://static.wixstatic.com/media/b.jpg"}],
          "offers": {"@type": "Offer", "url": URL, "priceCurrency": "USD", "price": "80",
                     "availability": "https://schema.org/InStock"}}
    if product is not None:
        ld = product
    return (f'<html><head>{extra}<script type="application/ld+json">{json.dumps(ld)}</script>'
            '</head><body></body></html>')


def test_a_product_page_becomes_one_buyable_variant():
    p = bc.shape_wix(URL, page())
    assert p["handle"] == "baby-angel-green-blanket"
    assert p["title"] == "Organic Cotton Knit Baby Angel Blanket Green"
    assert [i["src"] for i in p["images"]] == ["https://static.wixstatic.com/media/a.jpg",
                                               "https://static.wixstatic.com/media/b.jpg"]
    [v] = p["variants"]
    assert (v["title"], v["price"], v["available"]) == ("Default Title", "80", True)
    assert v["id"] == p["id"] == bc.swell_number("wix:baby-angel-green-blanket")


def test_sold_out_and_unpriced_pages():
    sold = json.loads(json.dumps({"@type": "Product", "name": "Tats", "image": [],
                                  "offers": {"price": "20", "availability": "https://schema.org/OutOfStock"}}))
    assert bc.shape_wix(URL, page(sold))["variants"][0]["available"] is False
    unpriced = {"@type": "Product", "name": "Gift card", "offers": {}}
    assert bc.shape_wix(URL, page(unpriced)) is None
    assert bc.shape_wix(URL, "<html>no product data</html>") is None


def test_other_json_ld_blocks_are_ignored():
    org = '<script type="application/ld+json">{"@type": "Organization", "name": "deseta"}</script>'
    assert bc.shape_wix(URL, page(extra=org))["title"].startswith("Organic Cotton")


def test_normalized_url_is_the_wix_product_page():
    brand = {"id": "deseta", "name": "Deseta", "domain": "www.deseta.net", "category": "accessories",
             "platform": "wix", "currency": "USD", "shopify": True}
    row = bc.normalize(bc.shape_wix(URL, page()), brand)
    assert row["url"] == URL
    assert row["price"] == 80.0 and row["available"]


def test_sitemap_lists_only_product_pages():
    xml = ("<urlset><url><loc>https://www.deseta.net/product-page/a</loc></url>"
           "<url><loc>https://www.deseta.net/about</loc></url>"
           "<url><loc> https://www.deseta.net/product-page/b </loc></url></urlset>")
    assert bc.WIX_PAGE.findall(xml) == ["https://www.deseta.net/product-page/a",
                                        "https://www.deseta.net/product-page/b"]
