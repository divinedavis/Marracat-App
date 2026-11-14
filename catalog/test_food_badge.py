"""The Marracat Clean Food rules, one case per rule. Run: python3 -m unittest catalog/test_food_badge.py"""
import sys
import pathlib
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from food_badge import apply, eligible, evaluate, extract_food  # noqa: E402


def food(title="Hibiscus Ginger Tea", description="", category="grocery", ptype="Tea"):
    return {"id": title, "brand": "b", "url": f"https://b.example/products/{title}", "title": title,
            "product_type": ptype, "category": category, "description": description}


class Reading(unittest.TestCase):
    def test_a_labelled_list_ends_at_the_next_section(self):
        d = "<p>Ingredients: Organic hibiscus, ginger, cinnamon. Contains: no allergens. Steep 5 minutes.</p>"
        self.assertEqual(extract_food(d), "Organic hibiscus, ginger, cinnamon")

    def test_sub_lists_stay_inside_their_item(self):
        d = "Ingredients: Enriched flour (wheat flour, niacin, iron), sugar, salt. Net wt 8 oz"
        self.assertEqual(extract_food(d), "Enriched flour (wheat flour, niacin, iron), sugar, salt")

    def test_a_one_ingredient_tea_is_a_list(self):
        self.assertEqual(extract_food("Ingredients: organic burdock root Product Details: 2 oz"), "organic burdock root")

    def test_marketing_after_the_label_is_not_a_list(self):
        self.assertEqual(extract_food("Ingredients – Features red pepper and garlic for bold flavor."), "")


class Passing(unittest.TestCase):
    def test_whole_foods_pass_and_preservatives_are_noted(self):
        ok, failures, notes = evaluate(food(), "Hibiscus, ginger, cane sugar, carrageenan")
        self.assertTrue(ok, failures)
        self.assertEqual(notes, ["carrageenan"])

    def test_free_claims_are_not_hits(self):
        self.assertTrue(evaluate(food(), "Corn, salt, no high fructose corn syrup, dye-free")[0])


class Failing(unittest.TestCase):
    def test_no_list(self):
        self.assertEqual(evaluate(food(), ""), (False, ["no published ingredient list"], []))

    def test_additives_banned_somewhere(self):
        for bad, label in [("Red No. 3", "Red No. 3 (erythrosine)"), ("Red 40", "synthetic azo and coal-tar dyes"),
                           ("Yellow #5 Lake", "synthetic azo and coal-tar dyes"),
                           ("titanium dioxide", "titanium dioxide (E171)"),
                           ("wheat flour (potassium bromate)", "potassium bromate"),
                           ("brominated vegetable oil", "brominated vegetable oil"),
                           ("azodicarbonamide", "azodicarbonamide"), ("propylparaben", "propylparaben"),
                           ("partially hydrogenated soybean oil", "partially hydrogenated oil"),
                           ("milk from cows treated with rBST", "rBST / rBGH dairy"),
                           ("sodium cyclamate", "cyclamate"), ("olestra", "olestra")]:
            ok, failures, _ = evaluate(food(), f"Sugar, {bad}, salt")
            self.assertFalse(ok, bad)
            self.assertTrue(any(f.startswith(label) for f in failures), (bad, failures))

    def test_hfcs_is_excluded_by_the_standard(self):
        ok, failures, _ = evaluate(food(), "Water, high fructose corn syrup, lemon")
        self.assertFalse(ok)
        self.assertTrue(failures[0].startswith("high-fructose corn syrup"))

    def test_lake_salt_is_not_a_dye(self):
        self.assertTrue(evaluate(food(), "Sea salt, lake salt, pepper")[0])


class Scope(unittest.TestCase):
    def test_merch_supplements_alcohol_and_pet_food_are_not_judged(self):
        for title in ["Ceramic Tea Mug", "Tea Infuser", "Gift Card", "Vitamin D Capsules", "Red Wine Jelly",
                      "Dog Treats", "Protein Powder"]:
            self.assertFalse(eligible(food(title)), title)
        self.assertFalse(eligible(food(category="wellness")))
        self.assertTrue(eligible(food("Jerk Seasoning")))

    def test_apply_reads_the_description_and_sets_the_flag(self):
        products = [food(description="Ingredients: rooibos, vanilla bean"),
                    food("Candy", description="Ingredients: sugar, Red 40, Blue 1"),
                    food("Mystery Blend")]
        stats, failed_by, _, brands = apply(products, {})
        self.assertEqual([p.get("food") for p in products], [True, None, None])
        self.assertEqual((stats["eligible"], stats["listed"], stats["passed"]), (3, 2, 1))
        self.assertEqual(failed_by["no published ingredient list"], 1)
        self.assertEqual(brands, ["b"])


if __name__ == "__main__":
    unittest.main()
