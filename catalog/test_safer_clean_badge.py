"""The Marracat Safer Clean rules, one case per rule. Run: python3 -m unittest catalog/test_safer_clean_badge.py"""
import sys
import pathlib
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from safer_clean_badge import apply, eligible, evaluate  # noqa: E402

GOOD = ("Water, Capryl/Capryl Glucoside, Potassium Cocoate, Sodium Gluconate, Lauryl Glucoside, "
        "Sodium Citrate, Glycerin, Amylase, Potassium Sorbate, Sodium Benzoate, Lavandula Angustifolia Oil")


def cleaner(title="Natural Laundry Detergent", subs=("laundry",), category="household", ptype=""):
    return {"title": title, "product_type": ptype, "subs": list(subs), "category": category}


def passes(inci, **kw):
    return evaluate(cleaner(**kw), inci)


class Passing(unittest.TestCase):
    def test_plant_surfactants_and_named_essential_oil(self):
        ok, failures, notes = passes(GOOD)
        self.assertTrue(ok, failures)
        self.assertEqual(notes, [])

    def test_quats_and_brighteners_are_noted_not_failed(self):
        ok, failures, notes = passes(f"{GOOD}, Benzalkonium Chloride, Fabric Whitening Agents")
        self.assertTrue(ok, failures)
        self.assertEqual(notes, ["quaternary ammonium (quats)", "optical brighteners"])


class Failing(unittest.TestCase):
    def test_no_list(self):
        self.assertEqual(passes(""), (False, ["no published ingredient list"], []))

    def test_cleaning_bans(self):
        for bad, label in [("Sodium Hypochlorite", "chlorine bleach"), ("Sodium Tripolyphosphate", "phosphates"),
                           ("Nonylphenol Ethoxylate", "nonylphenol ethoxylates"),
                           ("Triclosan", "triclosan / triclocarban"), ("Fluorosurfactant", "PFAS"),
                           ("1,4-Dioxane", "1,4-dioxane"), ("Sodium Borate", "borax and borates"),
                           ("Sodium Perborate", "borax and borates")]:
            ok, failures, _ = passes(f"{GOOD}, {bad}")
            self.assertFalse(ok, bad)
            self.assertEqual([f.split(":")[0] for f in failures], [label], bad)

    def test_a_ban_on_both_lists_is_reported_once(self):
        ok, failures, _ = passes(f"{GOOD}, Triclosan, Triclocarban")
        self.assertEqual(len(failures), 1)
        self.assertIn("triclocarban", failures[0])

    def test_clean_ban_list_applies(self):
        ok, failures, _ = passes(f"{GOOD}, Methylisothiazolinone, Tetrasodium EDTA")
        labels = [f.split(":")[0] for f in failures]
        self.assertIn("isothiazolinone preservatives", labels)
        self.assertIn("EDTA and its salts", labels)

    def test_undisclosed_fragrance(self):
        ok, failures, _ = passes("Water, Coconut Amide, Fatty Acid Soap, Fragrance")
        self.assertFalse(ok)
        self.assertTrue(failures[0].startswith("undisclosed fragrance"))
        ok, _, _ = passes("Sodium Carbonate, Citric Acid, Essential Oil or Fragrance Oil")
        self.assertFalse(ok, "may be the fragrance oil")

    def test_bleach_free_is_not_bleach(self):
        ok, failures, _ = passes(f"{GOOD}, Bleach-free Oxygen Booster")
        self.assertNotIn("chlorine bleach", [f.split(":")[0] for f in failures])


class Eligibility(unittest.TestCase):
    def test_cleaning_formulas(self):
        self.assertTrue(eligible(cleaner()))
        self.assertTrue(eligible(cleaner("Lavender Dish Soap", subs=())))
        self.assertTrue(eligible(cleaner("All-Purpose Cleaner", subs=("cleaners",))))

    def test_not_tools_paper_air_or_personal_care(self):
        self.assertFalse(eligible(cleaner("Wool Dryer Balls", subs=("laundry",))))
        self.assertFalse(eligible(cleaner("Bamboo Dish Brush", subs=("dish",))))
        self.assertFalse(eligible(cleaner("Toilet Paper 12 rolls", subs=("paper",))))
        self.assertFalse(eligible(cleaner("Hand Soap", subs=("hand-soap",))))
        self.assertFalse(eligible(cleaner("Room Spray", subs=("air-care",))))
        self.assertFalse(eligible(cleaner(category="skincare")))


class Apply(unittest.TestCase):
    def test_apply_sets_and_clears_the_flag(self):
        products = [
            {"id": "a", "brand": "x", "url": "u/a", "title": "Dish Soap", "category": "household", "subs": ["dish"],
             "safer": True},
            {"id": "b", "brand": "x", "url": "u/b", "title": "Laundry Detergent", "category": "household",
             "subs": ["laundry"]},
            {"id": "c", "brand": "y", "url": "u/c", "title": "Glass Cleaner", "category": "household", "subs": []},
        ]
        store = {"u/a": f"{GOOD}, Sodium Hypochlorite", "u/b": GOOD}
        stats, failed_by, noted_by, brands = apply(products, store)
        self.assertEqual([p.get("safer") for p in products], [None, True, None])
        self.assertEqual(stats, {"eligible": 3, "listed": 2, "passed": 1})
        self.assertEqual(failed_by, {"chlorine bleach": 1, "no published ingredient list": 1})
        self.assertEqual(brands, ["x"])


if __name__ == "__main__":
    unittest.main()
