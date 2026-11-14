"""The Marracat Baby Safe rules, one case per rule. Run: python3 -m unittest catalog/test_baby_badge.py"""
import sys
import pathlib
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from baby_badge import apply, evaluate, kind, without_free_claims  # noqa: E402

WASH = ("Aqua, Decyl Glucoside, Sodium Lauroyl Lactylate, Aloe Barbadensis Leaf Juice, Glycerin, Panthenol, "
        "Xanthan Gum, Sodium Benzoate, Potassium Sorbate, Citric Acid")


def baby(title, description="", subs=(), category="baby"):
    return {"id": title, "brand": "b", "url": f"https://b.example/products/{title}", "title": title,
            "product_type": "", "category": category, "subs": list(subs), "description": description, "tags": []}


class Kinds(unittest.TestCase):
    def test_each_kind(self):
        self.assertEqual(kind(baby("Gentle Baby Wash")), "formula")
        self.assertEqual(kind(baby("Silicone Teether")), "feeding")
        self.assertEqual(kind(baby("Silicone Place Mat")), "feeding")
        self.assertEqual(kind(baby("Organic Onesie")), "textile")
        self.assertEqual(kind(baby("Wooden Rattle")), "toy")

    def test_gear_stickers_and_adult_items_are_not_judged(self):
        for title in ["Travel Stroller", "Infant Car Seat", "Bible Verse Sticker", "Nursing Bra", "Gift Card"]:
            self.assertIsNone(kind(baby(title)), title)
        self.assertIsNone(kind(baby("Body Wash", category="skincare")))


class Formulas(unittest.TestCase):
    def test_unscented_gentle_wash_passes(self):
        ok, failures, _ = evaluate(baby("Gentle Baby Wash"), WASH)
        self.assertTrue(ok, failures)

    def test_any_scent_fails_even_essential_oils(self):
        for scent in ["Fragrance", "Lavandula Angustifolia (Lavender) Oil", "Linalool"]:
            ok, failures, _ = evaluate(baby("Gentle Baby Wash"), f"{WASH}, {scent}")
            self.assertFalse(ok, scent)
            self.assertTrue(any(f.startswith("fragrance or essential oil") for f in failures), failures)

    def test_under_three_rules(self):
        ok, failures, _ = evaluate(baby("Baby Lotion"), f"{WASH}, Salicylic Acid")
        self.assertFalse(ok)
        self.assertTrue(evaluate(baby("Baby Shampoo"), f"{WASH}, Salicylic Acid")[0], "allowed in a shampoo")
        self.assertFalse(evaluate(baby("Baby Powder"), "Zea Mays Starch, Talc, Kaolin, Zinc Oxide, "
                                  "Tocopherol, Calendula Officinalis Extract, Aloe, Glycerin")[0])

    def test_no_list(self):
        self.assertEqual(evaluate(baby("Diaper Cream"))[1], ["no published ingredient list"])


class Materials(unittest.TestCase):
    def test_free_claims_are_removed_before_the_bans(self):
        self.assertNotIn("PVC", without_free_claims("Free of BPA, PVC, Phthalates • Microwave safe"))
        self.assertNotIn("PVC", without_free_claims("100% BPA, PVC and phthalates free"))
        self.assertNotIn("flame", without_free_claims("does not contain flame retardants and is soft"))

    def test_feeding(self):
        self.assertTrue(evaluate(baby("Silicone Teether", "100% food-grade silicone, free of BPA and PVC"))[0])
        self.assertFalse(evaluate(baby("Baby Bottle", "Polycarbonate bottle"))[0])
        self.assertEqual(evaluate(baby("Snack Cup", "Durable plastic, dishwasher safe"))[1],
                         ["plastic not stated BPA-free"])
        self.assertTrue(evaluate(baby("Snack Cup", "Durable plastic, BPA-free"))[0])
        self.assertFalse(evaluate(baby("Bamboo Plate", "Made of bamboo fiber and melamine"))[0])
        self.assertEqual(evaluate(baby("Pacifier Clip", "Cute colors"))[1], ["materials not stated"])

    def test_textiles(self):
        self.assertTrue(evaluate(baby("Organic Onesie", "100% GOTS organic cotton"))[0])
        self.assertEqual(evaluate(baby("Swaddle", "95% polyester, 5% spandex"))[1], ["synthetic or regenerated fibre only"])
        self.assertEqual(evaluate(baby("Swaddle", "So soft"))[1], ["materials not stated"])
        self.assertFalse(evaluate(baby("Sleep Sack", "Cotton, treated with flame retardant"))[0])
        self.assertTrue(evaluate(baby("Sleep Sack", "Cotton. No flame retardants or PFAS."))[0])

    def test_apply_sets_the_flag_and_counts_kinds(self):
        products = [baby("Organic Onesie", "organic cotton"), baby("Swaddle", "polyester"), baby("Stroller")]
        stats, failed_by, _, brands = apply(products, {})
        self.assertEqual([p.get("baby") for p in products], [True, None, None])
        self.assertEqual(stats["eligible"], 2)
        self.assertEqual(stats["by_kind"]["textile"], [2, 1])
        self.assertEqual(brands, ["b"])


if __name__ == "__main__":
    unittest.main()
