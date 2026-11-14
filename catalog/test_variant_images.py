"""Each colour keeps its own Shopify photo (variant featured_image), so the
app's product page can turn to it when the colour is picked (owner,
2026-10-17, on Walter Calvin's Legacy Satchel: Deep Navy's photo is 8 of 19).
"""
import build_catalog as bc

BRAND = {"id": "wc", "domain": "wc.example", "category": "bags"}


def img(n):
    return f"https://cdn.example/{n}.jpg"


def product(variant_photos):
    return {
        "id": 1, "handle": "satchel", "title": "Legacy Satchel", "product_type": "Bags",
        "images": [{"src": img(n)} for n in range(1, 20)],
        "variants": [{"id": 100 + i, "title": t, "price": "1475.00", "available": True,
                      **({"featured_image": {"src": img(n)}} if n else {})}
                     for i, (t, n) in enumerate(variant_photos)],
    }


def test_a_colour_points_at_its_photo_even_past_the_first_six():
    row = bc.normalize(product([("Cream", 1), ("Deep Wine", 2), ("Deep Navy", 8), ("Stone Gray", 14)]), BRAND)
    images = row["images"]
    assert images[:6] == [img(n) for n in range(1, 7)]
    by_title = {v["title"]: v for v in row["variants"]}
    for title, n in [("Cream", 1), ("Deep Wine", 2), ("Deep Navy", 8), ("Stone Gray", 14)]:
        assert images[by_title[title]["image"]] == img(n), title
    assert len(images) == 8, "only the colours' own photos are added past six"


def test_no_variant_photo_means_no_image_key():
    row = bc.normalize(product([("Default Title", None)]), BRAND)
    assert "image" not in row["variants"][0]
    assert len(row["images"]) == bc.MAX_IMAGES


def test_every_colour_keeps_its_photo_however_many_colours():
    # Styl Charm's Boston bag (owner, 2026-10-31): 18 colours, and a cap of
    # eight colour photos left pink, blue and black showing the wrong bag.
    many = [(f"C{i}", 7 + i) for i in range(12)] + [("Late", 3)]
    row = bc.normalize(product(many), BRAND)
    assert len(row["images"]) == bc.MAX_IMAGES + 12
    by_title = {v["title"]: v for v in row["variants"]}
    for i in range(12):
        assert row["images"][by_title[f"C{i}"]["image"]] == img(7 + i)
    assert row["images"][by_title["Late"]["image"]] == img(3), "a photo already in the first six is not added twice"


def test_two_variants_sharing_a_photo_share_one_url():
    row = bc.normalize(product([("Pink / Small", 9), ("Pink / Large", 9)]), BRAND)
    assert len(row["images"]) == bc.MAX_IMAGES + 1
    assert {v["image"] for v in row["variants"]} == {6}
