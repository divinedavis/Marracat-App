import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import colorways as C  # noqa: E402


def item(id, title, colour=None, brand="fog", price=150, available=True, category="clothing", rank=None):
    variants = [dict(title=f"{colour} / {s}") for s in ("XS", "S")] if colour else [dict(title=s) for s in ("XS", "S")]
    p = dict(id=id, brand=brand, title=title, product_type="Tops", category=category, price=price,
             available=available, variants=variants)
    if rank is not None:
        p["best_rank"] = rank
    return p


class Grouping(unittest.TestCase):
    def test_same_style_in_two_colours_is_one_group(self):
        a, b = item("a", "Classic Hoodie", "Vintage Black"), item("b", "Classic Hoodie", "Homestead Heather")
        groups = C.group_products([a, b])
        self.assertEqual(len(groups), 1)
        self.assertEqual(a["group"], b["group"])
        self.assertTrue(a["group"].startswith("fog:"))
        self.assertEqual((a["color"], b["color"]), ("Vintage Black", "Homestead Heather"))
        self.assertEqual(a["swatch"], C.SWATCH["black"])

    def test_title_colour_suffix(self):
        a, b = item("a", "Throw Blanket - NAVY"), item("b", "Throw Blanket - Burgundy")
        a["category"] = b["category"] = "home"
        C.group_products([a, b])
        self.assertEqual(a["group"], b["group"])
        self.assertEqual(a["color"], "Navy")

    def test_never_across_brands_or_prices(self):
        a, b = item("a", "Classic Hoodie", "Black"), item("b", "Classic Hoodie", "Sand", brand="other")
        c = item("c", "Classic Hoodie", "Sand", price=400)
        self.assertEqual(C.group_products([a, b, c]), [])
        self.assertNotIn("group", a)

    def test_no_colour_no_group_and_sizes_are_not_colours(self):
        a, b = item("a", "Classic Hoodie"), item("b", "Classic Hoodie")
        self.assertEqual(C.group_products([a, b]), [])

    def test_shades_and_scents_are_left_alone(self):
        a, b = item("a", "Lipstick - Red", category="makeup"), item("b", "Lipstick - Pink", category="makeup")
        self.assertEqual(C.group_products([a, b]), [])

    def test_one_member_per_colour_in_stock_first(self):
        a = item("a", "Classic Hoodie", "Black", available=False)
        b = item("b", "Classic Hoodie", "Black", rank=3)
        c = item("c", "Classic Hoodie", "Sand")
        [g] = C.group_products([a, b, c])
        self.assertEqual({p["id"] for p in g}, {"b", "c"})
        self.assertNotIn("group", a)

    def test_rerun_clears_stale_fields(self):
        a, b = item("a", "Classic Hoodie", "Black"), item("b", "Classic Hoodie", "Sand")
        C.group_products([a, b])
        b["brand"] = "other"
        C.group_products([a, b])
        self.assertNotIn("group", a)
        self.assertNotIn("color", b)

    def test_collapsed_count(self):
        a, b, c = item("a", "Classic Hoodie", "Black"), item("b", "Classic Hoodie", "Sand"), item("c", "Tee")
        C.group_products([a, b, c])
        self.assertEqual(C.collapsed_count([a, b, c]), (3, 2))


if __name__ == "__main__":
    unittest.main()
