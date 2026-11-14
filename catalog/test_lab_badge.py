"""The Marracat Lab Verified rules, one case per rule. Run: python3 -m unittest catalog/test_lab_badge.py"""
import sys
import pathlib
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from lab_badge import apply, evaluate  # noqa: E402


def item(title, description="", tags=(), subs=("supplements",), category="wellness"):
    return {"id": title, "brand": "b", "url": f"https://b.example/products/{title}", "title": title,
            "product_type": "", "category": category, "subs": list(subs), "description": description,
            "tags": list(tags)}


class LabVerified(unittest.TestCase):
    def test_a_named_programme_passes(self):
        for claim in ("NSF Certified for Sport", "USP Verified", "Informed Choice certified", "BSCG Certified",
                      "Clean Label Project certified"):
            ok, _, notes = evaluate(item("Vitamin D3 Capsules", claim))
            self.assertTrue(ok, claim)
            self.assertTrue(notes[0].startswith("certified"))
        self.assertTrue(evaluate(item("B12 Gummies", tags=["nsf-certified"]))[0], "a store tag counts")

    def test_a_published_independent_coa_passes(self):
        self.assertTrue(evaluate(item("Sea Moss Capsules", "Third-party tested. See our certificate of analysis."))[0])

    def test_vague_testing_and_facility_audits_fail(self):
        ok, failures, _ = evaluate(item("Moringa Capsules", "Third-party tested for purity"))
        self.assertFalse(ok)
        self.assertTrue(failures[0].startswith("third-party testing claimed"))
        ok, failures, _ = evaluate(item("Elderberry Gummies", "Made in an NSF-registered, GMP certified facility"))
        self.assertFalse(ok)
        self.assertTrue(failures[0].startswith("facility audit only"))
        self.assertFalse(evaluate(item("Tea Blend", "Made with love"))[0])

    def test_banned_ingredients_fail_even_when_certified(self):
        for bad in ("yohimbe bark", "DMAA", "kratom", "phenibut", "full spectrum CBD", "delta-8", "kava root"):
            ok, failures, _ = evaluate(item("Energy Capsules", f"NSF Certified for Sport. Contains {bad}."))
            self.assertFalse(ok, bad)
        self.assertTrue(evaluate(item("Gummies", "NSF Certified for Sport. THC-free, no CBD."))[0],
                        "claims of absence aren't ingredients")

    def test_topicals_and_other_departments_are_not_judged(self):
        self.assertEqual(evaluate(item("Natural Deodorant", "NSF Certified"))[1],
                         ["not a wellness product the badge covers"])
        self.assertEqual(evaluate(item("Vitamin C Serum", "USP Verified", category="skincare"))[1],
                         ["not a wellness product the badge covers"])

    def test_apply_sets_the_flag_and_counts(self):
        products = [item("A Capsules", "USP Verified"), item("B Capsules", "third-party tested"),
                    item("Deodorant", "NSF Certified")]
        stats, failed_by, _, brands = apply(products)
        self.assertEqual((stats["eligible"], stats["passed"], stats["claimed"]), (2, 1, 2))
        self.assertTrue(products[0]["lab"])
        self.assertNotIn("lab", products[1])
        self.assertEqual(brands, ["b"])


if __name__ == "__main__":
    unittest.main()
