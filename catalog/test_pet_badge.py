"""The Marracat Pet Safe rules, one case per rule. Run: python3 -m unittest catalog/test_pet_badge.py"""
import sys
import pathlib
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from pet_badge import apply, evaluate, kind  # noqa: E402


def item(title, description="", product_type="", subs=()):
    return {"id": title, "brand": "b", "url": f"https://b.example/products/{title}", "title": title,
            "product_type": product_type, "category": "pets", "subs": list(subs), "description": description,
            "tags": []}


class PetSafe(unittest.TestCase):
    def test_kinds(self):
        self.assertEqual(kind(item("Freeze Dried Salmon Treats")), "food")
        self.assertEqual(kind(item("Oatmeal Dog Shampoo")), "grooming")
        self.assertEqual(kind(item("Woven Cotton Dog Collar")), "goods")
        self.assertIsNone(kind(item("Dog Mom T-Shirt")), "merch for people isn't judged")
        self.assertEqual(kind(item("Blessed D.O.G. Hoodie", "Please measure your pup")), "goods",
                         "a pet hoodie is judged")

    def test_food_needs_complete_and_balanced_or_one_named_ingredient(self):
        self.assertTrue(evaluate(item("Adult Dog Food", "Formulated to meet AAFCO complete and balanced"))[0])
        self.assertTrue(evaluate(item("Beef Liver Treats", "Ingredients: beef liver"))[0])
        self.assertTrue(evaluate(item("Green Tripe", "This product is 100% beef green tripe"))[0])
        self.assertTrue(evaluate(item("Duck Necks Air Dried", "Air-dried duck necks"))[0])
        ok, failures, _ = evaluate(item("Peanut Butter Biscuits", "Ingredients: oat flour, peanut butter, egg"))
        self.assertFalse(ok)
        self.assertTrue(failures[0].startswith("no complete-and-balanced"))

    def test_food_toxic_to_pets_fails(self):
        for bad in ("xylitol", "raisins", "garlic powder", "cocoa", "macadamia"):
            ok, failures, _ = evaluate(item("Dog Cookies", f"Complete and balanced. Ingredients: oats, {bad}"))
            self.assertFalse(ok, bad)
        ok, failures, _ = evaluate(item("Cat Treats", "AAFCO complete and balanced for cats. Propylene glycol."))
        self.assertFalse(ok)
        self.assertTrue(any(f.startswith("propylene glycol in cat food") for f in failures))
        self.assertTrue(evaluate(item("Dog Treats", "Single-ingredient. Xylitol-free."))[0],
                        "claims of absence aren't ingredients")

    def test_grooming_needs_a_list_without_pet_toxic_oils(self):
        self.assertFalse(evaluate(item("Dog Shampoo", "Gentle and natural"))[0])
        self.assertTrue(evaluate(item("Dog Shampoo", "Ingredients: water, decyl glucoside, colloidal oatmeal, "
                                                     "aloe barbadensis leaf juice, glycerin"))[0])
        ok, failures, _ = evaluate(item("Dog Shampoo", "Ingredients: water, decyl glucoside, colloidal oatmeal, "
                                                       "melaleuca alternifolia (tea tree) leaf oil, glycerin"))
        self.assertFalse(ok)
        self.assertTrue(any(f.startswith("essential oil toxic to pets") for f in failures))

    def test_goods_need_a_named_material_and_safe_plastics(self):
        self.assertTrue(evaluate(item("Dog Leash", "Made from durable nylon webbing"))[0])
        self.assertFalse(evaluate(item("Dog Bed Basket", "Cozy and stylish"))[0])
        ok, failures, _ = evaluate(item("Squeaky Chew Toy", "Tough rubber toy"))
        self.assertFalse(ok)
        self.assertTrue(failures[0].startswith("plastic or rubber not stated"))
        self.assertTrue(evaluate(item("Squeaky Chew Toy", "Tough rubber toy, BPA-free and phthalate-free"))[0])
        self.assertFalse(evaluate(item("Raincoat", "PVC shell"))[0])

    def test_apply_sets_the_flag(self):
        products = [item("Beef Liver Treats", "Ingredients: beef liver"), item("Dog Bed", "Comfy")]
        stats, _, _, _ = apply(products, {})
        self.assertEqual((stats["eligible"], stats["passed"]), (2, 1))
        self.assertTrue(products[0]["pet"])
        self.assertNotIn("pet", products[1])


if __name__ == "__main__":
    unittest.main()
