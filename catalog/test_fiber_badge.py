"""The Marracat Natural Fiber rules, one case per rule. Run: python3 -m unittest catalog/test_fiber_badge.py"""
import sys
import pathlib
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from fiber_badge import apply, composition, eligible, evaluate  # noqa: E402


def garment(title, description="", category="clothing"):
    return {"id": title, "brand": "b", "url": f"https://b.example/products/{title}", "title": title,
            "product_type": "", "category": category, "subs": [], "description": description, "tags": []}


class Composition(unittest.TestCase):
    def test_percent_first_name_first_and_glued(self):
        self.assertEqual([(p, n) for p, n, _ in composition("95% cotton, 5% spandex")["parts"]],
                         [(95, "cotton"), (5, "elastane")])
        self.assertEqual([(p, n) for p, n, _ in composition("Cotton 95% Spandex 5%")["parts"]],
                         [(95, "cotton"), (5, "elastane")], "name-first isn't read as 95% spandex")
        self.assertEqual([(p, n) for p, n, _ in composition("Content: 83% VISCOSE17% ELASTANE")["parts"]],
                         [(83, "viscose"), (17, "elastane")])

    def test_eu_label_abbreviations(self):
        self.assertEqual([(p, n) for p, n, _ in composition("72%ORG COT 22%REC PES 6%PA")["parts"]],
                         [(72, "organic cotton"), (22, "polyester"), (6, "nylon")])
        self.assertEqual([(p, n) for p, n, _ in composition("89% rec.pes, 11%el")["parts"]],
                         [(89, "polyester"), (11, "elastane")])

    def test_adjectives_between_percent_and_fibre(self):
        self.assertEqual(composition("100% Airlume combed and ringspun cotton")["parts"][0][1], "cotton")

    def test_a_single_labelled_fibre_counts_as_whole(self):
        self.assertEqual(composition("Fabric: organic linen")["parts"], [(100.0, "organic linen", "natural")])
        self.assertIsNone(composition("Soft and comfy, made in Brooklyn"))

    def test_a_partial_composition_is_incomplete(self):
        self.assertFalse(composition("60% cotton")["complete"])


class Verdicts(unittest.TestCase):
    def test_all_natural_passes(self):
        self.assertEqual(evaluate(garment("Tee", "100% cotton"))[0], "natural")

    def test_ninety_percent_threshold(self):
        self.assertEqual(evaluate(garment("Jeans", "92% cotton, 8% elastane"))[0], "natural")
        tier, failures, _ = evaluate(garment("Tee", "80% cotton, 20% polyester"))
        self.assertIsNone(tier)
        self.assertTrue(failures[0].startswith("synthetic fibre"))

    def test_regenerated_cellulose_is_not_natural(self):
        tier, failures, _ = evaluate(garment("Dress", "100% bamboo viscose"))
        self.assertIsNone(tier)
        self.assertTrue(failures[0].startswith("regenerated fibre"))

    def test_organic_tier(self):
        self.assertEqual(evaluate(garment("Tee", "95% organic cotton, 5% elastane"))[0], "organic")
        self.assertEqual(evaluate(garment("Tee", "100% cotton, GOTS certified"))[0], "organic")

    def test_no_composition_or_varies_never_passes(self):
        self.assertEqual(evaluate(garment("Tee", "Our softest tee"))[1], ["composition not stated"])
        self.assertEqual(evaluate(garment("Tee", "100% cotton. Fiber content may vary for different colors"))[1],
                         ["fibre content varies by colour"])
        self.assertEqual(evaluate(garment("Tee", "60% cotton"))[1], ["composition incomplete"])

    def test_only_garments_are_judged(self):
        self.assertFalse(eligible(garment("Tote Bag", "100% cotton")))
        self.assertFalse(eligible(garment("Silk Scarf", "100% silk", category="accessories")))

    def test_apply_marks_and_counts(self):
        products = [garment("A", "100% linen"), garment("B", "100% polyester"), garment("C", "")]
        stats, failed_by, _, brands = apply(products)
        self.assertEqual(products[0]["fiber"], "natural")
        self.assertNotIn("fiber", products[1])
        self.assertEqual((stats["eligible"], stats["stated"], stats["passed"]), (3, 2, 1))
        self.assertEqual(failed_by["composition not stated"], 1)


if __name__ == "__main__":
    unittest.main()
