"""The Marracat True Material rules, one case per rule. Run: python3 -m unittest catalog/test_material_badge.py"""
import sys
import pathlib
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from material_badge import apply, evaluate  # noqa: E402


def bag(title, description="", subs=("tote",)):
    return {"id": title, "brand": "b", "url": f"https://b.example/products/{title}", "title": title,
            "product_type": "", "category": "bags", "subs": list(subs), "description": description, "tags": []}


class TrueMaterial(unittest.TestCase):
    def test_real_leather_and_natural_materials_pass(self):
        self.assertEqual(evaluate(bag("Tote", "Full-grain cowhide"))[0], "true")
        self.assertEqual(evaluate(bag("Leather Crossbody", ""))[0], "true", "leather in the title")
        self.assertEqual(evaluate(bag("Market Bag", "Hand-woven jute"))[0], "true")
        self.assertEqual(evaluate(bag("Tote", "Heavy cotton canvas"))[0], "true")

    def test_a_leather_strap_doesnt_make_the_bag_leather(self):
        ok = evaluate(bag("Belt Bag", "Swap out the leather strap for our chain"))[0]
        self.assertIsNone(ok)

    def test_vegetable_tanned_tier(self):
        tier, _, notes = evaluate(bag("Saddle Bag", "Vegetable-tanned leather, made in Lagos"))
        self.assertEqual(tier, "veg")
        self.assertIn("vegetable-tanned or chrome-free", notes)

    def test_unnamed_vegan_leather_fails_but_named_pu_or_plant_passes(self):
        tier, failures, _ = evaluate(bag("Mini Bag", "Made from vegan leather"))
        self.assertIsNone(tier)
        self.assertTrue(failures[0].startswith("vegan or faux leather without the material named"))
        self.assertEqual(evaluate(bag("Mini Bag", "Vegan leather (polyurethane)"))[0], "true")
        self.assertEqual(evaluate(bag("Mini Bag", "Cactus leather by Desserto"))[0], "true")
        self.assertIsNone(evaluate(bag("Clutch", "Luxe leatherette finish"))[0])

    def test_pvc_needs_phthalate_free(self):
        self.assertIsNone(evaluate(bag("Clear Tote", "Clear PVC"))[0])
        self.assertEqual(evaluate(bag("Clear Tote", "Clear PVC, phthalate-free, with cotton handles"))[0], "true")

    def test_no_material_fails_and_bag_care_isnt_judged(self):
        self.assertEqual(evaluate(bag("Ruby Bag", "So cute"))[1], ["material not stated"])
        self.assertEqual(evaluate(bag("Leather Cleaner", "Cleans leather", subs=("bag-care",)))[1],
                         ["not a bag the badge covers"])

    def test_apply_sets_the_tier(self):
        products = [bag("A", "Vegetable-tanned leather tote"), bag("B", "Canvas"), bag("C", "vegan leather")]
        stats, _, _, _ = apply(products)
        self.assertEqual((stats["passed"], stats["veg"]), (2, 1))
        self.assertEqual([p.get("material") for p in products], ["veg", "true", None])


if __name__ == "__main__":
    unittest.main()
