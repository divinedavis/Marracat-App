"""The Marracat True Metal rules, one case per rule. Run: python3 -m unittest catalog/test_metal_badge.py"""
import sys
import pathlib
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from metal_badge import apply, eligible, evaluate  # noqa: E402


def verdict(title, description="", variants=(), category="jewelry", subs=()):
    p = {"title": title, "description": description, "category": category, "subs": list(subs),
         "variants": [{"title": v} for v in variants]}
    return evaluate(p)


class Qualifying(unittest.TestCase):
    def test_karat_gold_10k_and_up(self):
        for t in ["14k Gold Hoops", "18K yellow gold studs", "Ring in 10kt gold", "22 karat gold bangle", "Solid Gold Chain"]:
            self.assertEqual(verdict(t)[0], "true", t)

    def test_under_10k_is_not_gold(self):
        self.assertIsNone(verdict("9k gold ring")[0])

    def test_sterling_and_925(self):
        for t in ["Sterling Silver Cuff", "925 silver ring", "Hoops in .925", "Argentium silver studs"]:
            self.assertEqual(verdict(t)[0], "true", t)

    def test_platinum_titanium_niobium_surgical_steel(self):
        for t in ["Platinum band", "Titanium labret", "Niobium hoop", "316L steel stud", "Surgical steel barbell"]:
            self.assertEqual(verdict(t)[0], "true", t)

    def test_plain_stainless_needs_nickel_free(self):
        ok, _, failures = verdict("Stainless steel cuff")
        self.assertIsNone(ok)
        self.assertIn("stainless steel, grade not stated", failures)
        self.assertEqual(verdict("Stainless steel cuff", "Hypoallergenic, nickel-free.")[0], "true")

    def test_metal_named_only_in_variants(self):
        self.assertEqual(verdict("Moyo Diamond Ring", variants=["14K Yellow Gold / 6", "14K White Gold / 7"])[0], "true")

    def test_beads_on_sterling_wires(self):
        self.assertEqual(verdict("Green Wood Earrings", "Wooden beads, sterling silver ear wire")[0], "true")

    def test_rhodium_over_sterling_is_allowed(self):
        self.assertEqual(verdict("Onyx Cufflinks", "925 sterling silver with white rhodium plating")[0], "true")


class PlatingTraps(unittest.TestCase):
    def test_gold_plated_brass(self):
        ok, metals, failures = verdict("18k Gold Plated Brass Hoops")
        self.assertIsNone(ok)
        self.assertTrue(any(f.startswith("base metal") for f in failures))
        self.assertTrue(any(f.startswith("plated or toned") for f in failures))

    def test_gold_tone(self):
        self.assertIsNone(verdict("Gold Tone Chain Necklace")[0])

    def test_sterling_silver_plated(self):
        self.assertIsNone(verdict("Sterling Silver Plated Ring")[0])

    def test_plated_stainless(self):
        self.assertIsNone(verdict("Lola Bangle", "18k gold-plated stainless steel")[0])

    def test_pvd_and_dipped(self):
        self.assertIsNone(verdict("Watch", "316L PVD stainless steel case")[0])
        self.assertIsNone(verdict("Pendant", "18k gold dipped stainless steel")[0])

    def test_gold_filled_and_vermeil_noted_not_badged(self):
        for t in ["14k Gold Filled Chain", "Gold Vermeil Studs"]:
            ok, _, failures = verdict(t)
            self.assertIsNone(ok, t)
            self.assertTrue(any(f.startswith("gold-filled or vermeil") for f in failures), t)

    def test_any_plated_variant_fails_the_listing(self):
        self.assertIsNone(verdict("MLK Studs", "Made to order in 18K gold plated brass, sterling silver, or solid 14K gold")[0])


class BaseMetalsAndHazards(unittest.TestCase):
    def test_brass_with_sterling_posts_is_brass(self):
        self.assertIsNone(verdict("Ayla Earrings", "Brass with sterling silver posts. Nickel and lead free.")[0])

    def test_nickel_as_material_fails(self):
        self.assertIsNone(verdict("Sterling ring", "Sterling silver and nickel")[0])

    def test_nickel_and_lead_free_is_not_nickel(self):
        ok, _, failures = verdict("Sterling Studs", "Sterling silver. Nickel and lead free.")
        self.assertEqual(ok, "true", failures)

    def test_trace_nickel_in_a_gemstone(self):
        self.assertEqual(verdict("Lyre Ring - Solid Gold", "its color comes from trace quantities of nickel")[0], "true")

    def test_lead_and_cadmium(self):
        self.assertIsNone(verdict("14k gold charm", "Contains lead")[0])
        self.assertIsNone(verdict("Sterling bracelet", "with leaded crystal")[0])
        self.assertIsNone(verdict("Sterling bracelet", "cadmium")[0])
        self.assertEqual(verdict("14k gold charm", "Ships after a 2 week lead time")[0], "true")

    def test_imitation_metal_fails_faux_pearls_do_not(self):
        self.assertIsNone(verdict("Fashion Jewelry Earrings", "sterling post")[0])
        self.assertEqual(verdict("Pearl Hoop", "Sterling silver post, faux pearls")[0], "true")

    def test_no_metal_named(self):
        ok, _, failures = verdict("Beaded Bracelet", "Glass beads on elastic")
        self.assertIsNone(ok)
        self.assertIn("metal not named", failures)

    def test_platinum_collection_is_not_platinum(self):
        self.assertIsNone(verdict("Platinum Collection Hoops", "Glass beads")[0])

    def test_titanium_steel_is_not_titanium(self):
        self.assertIsNone(verdict("Titanium Steel Ring")[0])


class EthicalTier(unittest.TestCase):
    def test_named_schemes(self):
        for d in ["Made with recycled 14k gold", "Fairmined gold", "Fairtrade gold", "RJC certified",
                  "lab-grown diamonds", "Lab Grown Diamond", "conflict-free diamonds", "Kimberley Process stones",
                  "recycled sterling silver"]:
            self.assertEqual(verdict("18k gold ring", d)[0], "ethical", d)

    def test_vague_claims_and_grading_labs_do_not_count(self):
        self.assertEqual(verdict("18k gold ring", "Ethically sourced and responsibly made")[0], "true")
        self.assertEqual(verdict("14k gold ring", "Natural diamond, Lab IGI certificate")[0], "true")

    def test_tier_needs_true_metal_first(self):
        self.assertIsNone(verdict("Lab grown diamond studs", "18k gold plated brass")[0])


class Applying(unittest.TestCase):
    def test_apply_sets_and_clears_flags(self):
        products = [
            {"id": "a", "brand": "x", "title": "14k gold hoop", "category": "jewelry", "metal": "stale"},
            {"id": "b", "brand": "x", "title": "Recycled sterling silver ring", "category": "jewelry"},
            {"id": "c", "brand": "y", "title": "Gold tone ring", "category": "jewelry", "metal": "true"},
            {"id": "d", "brand": "y", "title": "Shea butter", "category": "skincare", "metal": "true"},
        ]
        stats, failed_by, metal_by, brands, ethical = apply(products)
        self.assertEqual([p.get("metal") for p in products], ["true", "ethical", None, None])
        self.assertEqual(stats, {"eligible": 3, "true": 1, "ethical": 1})
        self.assertEqual(brands, ["x"])
        self.assertEqual(ethical, ["x"])

    def test_eligibility(self):
        self.assertTrue(eligible({"category": "jewelry"}))
        self.assertTrue(eligible({"category": "accessories", "subs": ["rings"]}))
        self.assertFalse(eligible({"category": "bags", "subs": ["totes"]}))


if __name__ == "__main__":
    unittest.main()
