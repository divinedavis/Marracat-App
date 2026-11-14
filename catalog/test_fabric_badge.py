"""The Marracat Safe Fabric rules, one case per rule. Run: python3 -m unittest catalog/test_fabric_badge.py"""
import sys
import pathlib
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from fabric_badge import apply, evaluate  # noqa: E402


def garment(title, description="", category="clothing"):
    return {"id": title, "brand": "b", "url": f"https://b.example/products/{title}", "title": title,
            "product_type": "", "category": category, "subs": [], "description": description, "tags": []}


class SafeFabric(unittest.TestCase):
    def test_natural_or_mostly_natural_passes(self):
        self.assertTrue(evaluate(garment("Tee", "100% cotton"))[0])
        self.assertTrue(evaluate(garment("Hoodie", "60% cotton, 40% polyester"))[0], "under half synthetic")

    def test_half_or_more_synthetic_fails_unless_certified(self):
        ok, failures, _ = evaluate(garment("Hoodie", "50% cotton, 50% polyester"))
        self.assertFalse(ok)
        self.assertTrue(failures[0].startswith("half or more synthetic"))
        ok, _, notes = evaluate(garment("Leggings", "80% recycled polyester, 20% elastane. OEKO-TEX Standard 100"))
        self.assertTrue(ok)
        self.assertIn("OEKO-TEX / bluesign / GOTS certified", notes)

    def test_pfas_and_unstated_water_repellent_finishes_fail(self):
        self.assertFalse(evaluate(garment("Jacket", "100% cotton with a fluorocarbon DWR"))[0])
        ok, failures, _ = evaluate(garment("Jacket", "100% cotton, water-repellent finish"))
        self.assertFalse(ok)
        self.assertTrue(failures[0].startswith("water-repellent finish not stated PFAS-free"))
        self.assertTrue(evaluate(garment("Jacket", "100% cotton, PFC-free DWR finish"))[0])

    def test_flame_retardant_and_antimicrobial_treatments_fail(self):
        self.assertFalse(evaluate(garment("PJs", "100% cotton, flame-retardant finish"))[0])
        self.assertFalse(evaluate(garment("Polo", "100% cotton with antimicrobial technology"))[0])
        self.assertTrue(evaluate(garment("PJs", "100% cotton. This garment is not flame resistant."))[0],
                        "a safety notice isn't a treatment")

    def test_pvc_needs_phthalate_free(self):
        self.assertFalse(evaluate(garment("Shorts", "100% cotton, PVC patch"))[0])
        self.assertTrue(evaluate(garment("Shorts", "100% cotton, phthalate-free PVC patch"))[0])
        self.assertTrue(evaluate(garment("Hoodie", "100% cotton. Inspired by classic reggae vinyl."))[0])

    def test_claims_of_absence_are_not_treatments(self):
        self.assertTrue(evaluate(garment("Tee", "100% cotton. Free of PFAS and flame retardants."))[0])

    def test_no_or_partial_composition_never_passes(self):
        self.assertEqual(evaluate(garment("Tee", "So soft"))[1], ["composition not stated"])
        self.assertEqual(evaluate(garment("Tee", "60% cotton"))[1], ["composition incomplete"])

    def test_apply_marks_and_counts(self):
        products = [garment("A", "100% wool"), garment("B", "100% nylon"), garment("C", "")]
        stats, failed_by, _, _ = apply(products)
        self.assertTrue(products[0]["fabric"])
        self.assertNotIn("fabric", products[1])
        self.assertEqual((stats["eligible"], stats["stated"], stats["passed"]), (3, 2, 1))


if __name__ == "__main__":
    unittest.main()
