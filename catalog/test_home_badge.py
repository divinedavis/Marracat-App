"""The Marracat Natural Home rules, one case per rule. Run: python3 -m unittest catalog/test_home_badge.py"""
import sys
import pathlib
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from home_badge import apply, evaluate, kind  # noqa: E402


def item(title, description="", subs=()):
    return {"id": title, "brand": "b", "url": f"https://b.example/products/{title}", "title": title,
            "product_type": "", "category": "home", "subs": list(subs), "description": description, "tags": []}


class NaturalHome(unittest.TestCase):
    def test_kinds_and_exclusions(self):
        self.assertEqual(kind(item("Linen Napkins")), "textile")
        self.assertEqual(kind(item("Stoneware Mug")), "tableware")
        self.assertEqual(kind(item("Rattan Basket")), "decor")
        self.assertIsNone(kind(item("Soy Candle")), "candles have their own rules")
        self.assertIsNone(kind(item("Room Mist")))
        self.assertEqual(kind(item("Tea Towel")), "textile", "a tea towel isn't tea")

    def test_textiles_by_composition_or_named_fibre(self):
        self.assertEqual(evaluate(item("Throw", "100% wool"))[0], "natural")
        self.assertEqual(evaluate(item("Linen Sheet Set", "Stonewashed linen"))[0], "natural")
        self.assertEqual(evaluate(item("Pillow Cover", "Organic cotton, GOTS certified"))[0], "certified")
        tier, failures, _ = evaluate(item("Throw Blanket", "Soft microfiber fleece"))
        self.assertIsNone(tier)
        self.assertTrue(failures[0].startswith("synthetic or regenerated fibre"))

    def test_ceramic_tableware_must_be_stated_lead_free(self):
        tier, failures, _ = evaluate(item("Abstract Mug", "11oz ceramic mug"))
        self.assertIsNone(tier)
        self.assertEqual(failures, ["ceramic tableware not stated lead-free"])
        self.assertEqual(evaluate(item("Abstract Mug", "Ceramic, lead-free glaze"))[0], "natural")
        self.assertEqual(evaluate(item("Ceramic Vase", "Handmade ceramic"))[0], "natural",
                         "the lead rule is for food and drink")
        self.assertEqual(evaluate(item("Rocks Glass", "Hand-blown glass"))[0], "natural")
        self.assertIsNone(evaluate(item("Decanter", "Lead crystal"))[0])

    def test_composite_wood_pvc_and_plastic(self):
        self.assertIsNone(evaluate(item("Side Table", "MDF with walnut veneer"))[0])
        self.assertEqual(evaluate(item("Side Table", "MDF with walnut veneer, CARB Phase 2 compliant"))[0], "natural")
        self.assertEqual(evaluate(item("Coffee Table", "Solid oak, FSC certified"))[0], "certified")
        self.assertIsNone(evaluate(item("Kids Plate", "Bamboo fiber melamine"))[0])
        self.assertIsNone(evaluate(item("Vase", "Resin"))[0])
        self.assertIsNone(evaluate(item("Shower Curtain", "Vinyl"))[0])

    def test_no_material_fails(self):
        self.assertEqual(evaluate(item("Wall Clock", "Afro reading"))[1], ["material not stated"])

    def test_apply_sets_the_tier(self):
        products = [item("Wool Throw", "100% wool"), item("Oak Board", "Solid oak, FSC"), item("Mug", "ceramic")]
        stats, _, _, _ = apply(products)
        self.assertEqual((stats["passed"], stats["certified"]), (2, 1))
        self.assertEqual([p.get("home") for p in products], ["natural", "certified", None])


if __name__ == "__main__":
    unittest.main()
