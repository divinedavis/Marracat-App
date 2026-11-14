"""The Marracat Clear Scent rules, one case per rule. Run: python3 -m unittest catalog/test_scent_badge.py"""
import sys
import pathlib
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from scent_badge import apply, eligible, evaluate  # noqa: E402
from ingredient_lists import extract_list  # noqa: E402

DISCLOSED = "Alcohol Denat., Parfum, Aqua, Linalool, Limonene, Citronellol, Geraniol"


def perfume(title="Velvet Eau de Parfum", subs=("edp",), ptype="", category="fragrance"):
    return {"title": title, "product_type": ptype, "subs": list(subs), "category": category}


def passes(inci, **kw):
    return evaluate(perfume(**kw), inci)


class Passing(unittest.TestCase):
    def test_fragrance_with_allergens_named(self):
        ok, failures, notes = passes(DISCLOSED)
        self.assertTrue(ok, failures)
        self.assertIn("denatured alcohol base", notes)

    def test_named_essential_oils_need_no_allergens(self):
        ok, failures, _ = passes("Simmondsia Chinensis (Jojoba) Seed Oil, Lavandula Angustifolia Oil, "
                                 "Citrus Aurantium Bergamia Peel Oil")
        self.assertTrue(ok, failures)


class Failing(unittest.TestCase):
    def test_no_list(self):
        self.assertEqual(passes(""), (False, ["no published ingredient list"], []))

    def test_bare_fragrance_oil(self):
        ok, failures, _ = passes("Fractionated Coconut Oil, Fragrance Oil, Vitamin E")
        self.assertFalse(ok)
        self.assertTrue(failures[0].startswith("undisclosed fragrance"))

    def test_essential_oil_or_fragrance_oil_is_undisclosed(self):
        ok, failures, _ = passes("Jojoba Oil, Essential Oil or Fragrance Oil")
        self.assertFalse(ok)

    def test_every_phthalate_fails_dep_included(self):
        for p in ["Diethyl Phthalate", "DEP", "Dibutyl Phthalate", "DEHP"]:
            ok, failures, _ = passes(f"{DISCLOSED}, {p}")
            self.assertFalse(ok, p)
            self.assertTrue(any(f.startswith("phthalates") for f in failures), (p, failures))
            self.assertEqual(sum(f.startswith("phthalates") for f in failures), 1, "reported once")

    def test_ifra_and_eu_fragrance_bans(self):
        for bad in ["Musk Tibetene", "Musk Moskene", "Atranol", "Chloroatranol", "Methyl Eugenol",
                    "Butylphenyl Methylpropional", "Hydroxyisohexyl 3-Cyclohexene Carboxaldehyde",
                    "Musk Ambrette", "Acetyl Ethyl Tetramethyl Tetralin"]:
            ok, failures, _ = passes(f"{DISCLOSED}, {bad}")
            self.assertFalse(ok, bad)

    def test_clean_ban_list_applies(self):
        ok, failures, _ = passes(f"{DISCLOSED}, BHT, Benzophenone-3")
        self.assertFalse(ok)
        self.assertTrue(any(f.startswith("BHA / BHT") for f in failures))


class Eligibility(unittest.TestCase):
    def test_worn_fragrance(self):
        self.assertTrue(eligible(perfume()))
        self.assertTrue(eligible(perfume("Midnight Perfume Oil", subs=())))
        self.assertTrue(eligible(perfume("Shea Body Mist", subs=("body-mist",))))

    def test_not_candles_sets_home_or_other_categories(self):
        self.assertFalse(eligible(perfume("Fig Candle", subs=())))
        self.assertFalse(eligible(perfume("Discovery Set", subs=("discovery",))))
        self.assertFalse(eligible(perfume("Amber Reed Diffuser", subs=())))
        self.assertFalse(eligible(perfume("Room Spray", subs=())))
        self.assertFalse(eligible(perfume(category="skincare")))


class ShortLists(unittest.TestCase):
    def test_labelled_short_list_is_read(self):
        text = "Notes of oud and rose | Ingredients: Alcohol Denat, Parfum, Aqua, Linalool | Add to cart"
        self.assertEqual(extract_list(text), "Alcohol Denat, Parfum, Aqua, Linalool")

    def test_unlabelled_short_run_is_not_a_list(self):
        self.assertEqual(extract_list("Notes of oud, rose, amber | Add to cart"), "")


class Apply(unittest.TestCase):
    def test_apply_sets_and_clears_the_flag(self):
        products = [
            {"id": "a", "brand": "x", "url": "u/a", "title": "Oud Eau de Parfum", "category": "fragrance", "subs": ["edp"],
             "scent": True},
            {"id": "b", "brand": "x", "url": "u/b", "title": "Rose Perfume Oil", "category": "fragrance", "subs": []},
            {"id": "c", "brand": "y", "url": "u/c", "title": "Shea Butter", "category": "skincare", "scent": True},
        ]
        store = {"u/a": "Fragrance Oil, Coconut Oil", "u/b": DISCLOSED}
        stats, failed_by, noted_by, brands = apply(products, store)
        self.assertEqual([p.get("scent") for p in products], [None, True, None])
        self.assertEqual(stats, {"eligible": 2, "listed": 2, "passed": 1})
        self.assertEqual(failed_by, {"undisclosed fragrance": 1})
        self.assertEqual(brands, ["x"])


if __name__ == "__main__":
    unittest.main()
