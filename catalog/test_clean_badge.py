"""The Marracat Clean rules, one case per rule. Run: python3 -m unittest catalog/test_clean_badge.py"""
import sys
import pathlib
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from clean_badge import evaluate, family  # noqa: E402
from candle_badge import evaluate_candle, is_candle  # noqa: E402

BASE = "water, glycerin, cetearyl alcohol, aloe barbadensis leaf juice, tocopherol, xanthan gum, citric acid"


def verdict(title, inci, subs=(), category="skincare"):
    return evaluate({"title": title, "subs": list(subs), "category": category}, inci)


class CosmeticRules(unittest.TestCase):
    def test_a_plain_formula_passes(self):
        self.assertTrue(verdict("Daily Moisturizer", BASE)[0])

    def test_no_list_no_badge(self):
        ok, failures, _ = verdict("Daily Moisturizer", "")
        self.assertFalse(ok)
        self.assertIn("no published ingredient list", failures)

    def test_banned_in_the_eu(self):
        for ing in ["zinc pyrithione", "butylphenyl methylpropional", "4-methylbenzylidene camphor",
                    "cyclopentasiloxane", "dmdm hydantoin", "methylparaben"]:
            self.assertFalse(verdict("Serum", f"{BASE}, {ing}")[0], ing)

    def test_sunscreen_filters(self):
        for ing in ["oxybenzone", "benzophenone-4", "ethylhexyl methoxycinnamate", "octocrylene"]:
            self.assertFalse(verdict("Face Cream", f"{BASE}, {ing}")[0], ing)

    def test_palau_phenoxyethanol_rule_is_for_sunscreens_only(self):
        self.assertTrue(verdict("Night Cream", f"{BASE}, phenoxyethanol")[0])
        self.assertFalse(verdict("Mineral Sunscreen SPF 30", f"{BASE}, zinc oxide, phenoxyethanol")[0])
        self.assertFalse(verdict("Tinted Moisturizer", f"{BASE}, phenoxyethanol", subs=["spf"])[0])

    def test_retinyl_palmitate_fails_retinol_passes(self):
        self.assertFalse(verdict("Night Serum", f"{BASE}, retinyl palmitate")[0])
        self.assertTrue(verdict("Night Serum", f"{BASE}, retinol")[0])

    def test_carbon_black_is_not_coal_tar(self):
        self.assertTrue(verdict("Volume Mascara", f"{BASE}, ci 77266, beeswax", category="makeup")[0])
        self.assertFalse(verdict("Scalp Treatment", f"{BASE}, coal tar", category="hair")[0])

    def test_fragrance_must_be_disclosed(self):
        self.assertFalse(verdict("Body Butter", f"{BASE}, fragrance")[0])
        self.assertTrue(verdict("Body Butter", f"{BASE}, fragrance, linalool, limonene")[0])
        # menthol and camphor are actives; they can't prove a disclosure alone
        self.assertFalse(verdict("Body Butter", f"{BASE}, fragrance, menthol, camphor")[0])

    def test_misspelled_ethanolamines_still_fail(self):
        self.assertFalse(verdict("Brow Gel", f"{BASE}, trithanolamine", category="makeup")[0])

    def test_directions_are_not_an_ingredient_list(self):
        ok, failures, _ = verdict("Toxin Binder", "water, juice or a smoothie. Stir thoroughly and drink promptly, "
                                  "begin smaller, charcoal, clay, fiber, psyllium, apple pectin", category="makeup")
        self.assertFalse(ok)
        self.assertIn("no published ingredient list", failures)

    def test_excluded_categories(self):
        self.assertFalse(verdict("Skin Bleaching Cream", BASE)[0])
        self.assertFalse(verdict("No-Lye Relaxer", BASE, category="hair")[0])


class Families(unittest.TestCase):
    def fam(self, title, category, subs=()):
        return family({"title": title, "category": category, "subs": list(subs)})

    def test_where_each_product_goes(self):
        self.assertEqual(self.fam("Gentle Foaming Cleanser", "skincare", ["cleanser"]), "face")
        self.assertEqual(self.fam("Shea Body Wash", "skincare", ["body-wash"]), "body")
        self.assertEqual(self.fam("Vitamin C Serum", "skincare", ["serum"]), "skin")
        self.assertEqual(self.fam("Whipped Body Butter", "skincare", ["body-butter"]), "skin")
        self.assertEqual(self.fam("Matte Lipstick", "makeup", ["lipstick"]), "makeup")
        self.assertEqual(self.fam("Soy Candle", "home"), "candle")

    def test_things_without_a_formula(self):
        for title, cat in [("Jade Roller", "skincare"), ("Kabuki Brush", "makeup"), ("Beauty Sponge", "makeup"),
                           ("Mink Lashes", "makeup"), ("Glow Skincare Bundle", "skincare"), ("Candle Snuffer", "home"),
                           ("Candle Gift Set", "home")]:
            self.assertIsNone(self.fam(title, cat), title)


class Candles(unittest.TestCase):
    def candle(self, description, title="Lavender Candle"):
        return evaluate_candle({"title": title, "description": description, "tags": []})

    def test_disclosed_candle_passes(self):
        ok, failures, notes = self.candle("Hand-poured 100% soy wax with a cotton wick, scented with essential oils.")
        self.assertTrue(ok, failures)
        self.assertEqual(notes, [])

    def test_materials_must_be_named(self):
        self.assertFalse(self.candle("Smells like a summer night. Burns 40 hours.")[0])

    def test_fragrance_oil_alone_fails_phthalate_free_passes(self):
        self.assertFalse(self.candle("Coconut wax, cotton wick, premium fragrance oil.")[0])
        self.assertTrue(self.candle("Coconut wax, cotton wick, phthalate-free fragrance oil.")[0])
        self.assertTrue(self.candle("Coconut wax, wooden wick. Unscented.")[0])

    def test_metal_core_wick_fails(self):
        self.assertFalse(self.candle("Soy wax, zinc core wick, essential oils.")[0])

    def test_paraffin_is_noted_not_failed(self):
        ok, _, notes = self.candle("Paraffin wax blend, cotton wick, phthalate-free fragrance.")
        self.assertTrue(ok)
        self.assertIn("paraffin wax", notes)
        self.assertEqual(self.candle("Soy wax, no paraffin, cotton wick, essential oils.")[2], [])


if __name__ == "__main__":
    unittest.main()
