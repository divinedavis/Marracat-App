import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import attributes as A  # noqa: E402


def product(title="", category="hair", product_type="", tags=(), description=""):
    return dict(id="x", title=title, category=category, product_type=product_type, tags=list(tags),
                description=description)


class Rules(unittest.TestCase):
    def test_a_title_or_tag_naming_the_hair_type_settles_it(self):
        attrs, cand = A.rules(product("Curl Pudding for Curly & 4C Hair"))
        self.assertIn("4c", attrs["hair"])
        self.assertIn("curls", attrs["hair"])

    def test_a_description_saying_for_4c_settles_it(self):
        attrs, _ = A.rules(product("Wash and Go", description="Perfect for 4C and high-density hair"))
        self.assertEqual(attrs["hair"], ["4c"])

    def test_a_passing_mention_is_only_a_candidate(self):
        attrs, cand = A.rules(product("Edge Gel", description="Unlike gels that flake, 4C looks stay soft."))
        self.assertNotIn("hair", attrs)
        self.assertIn(("hair", "4c"), cand)

    def test_all_hair_types_is_no_type(self):
        _, cand = A.rules(product("Oil", description="Works on all hair types, from waves to 4C."))
        self.assertEqual(cand, [])

    def test_free_of_needs_the_brands_words(self):
        attrs, _ = A.rules(product("Cream", category="skincare", description="Fragrance-free. Sulfate free formula."))
        self.assertEqual(attrs["free"], ["fragrance", "sulfate"])
        attrs, _ = A.rules(product("Cream", category="skincare", description="Made with shea, no water."))
        self.assertNotIn("free", attrs)

    def test_non_vegan_is_not_vegan(self):
        attrs, _ = A.rules(product("Balm", category="skincare", description="Non-vegan: contains beeswax."))
        self.assertNotIn("free", attrs)
        attrs, _ = A.rules(product("Balm", category="skincare", description="100% vegan."))
        self.assertEqual(attrs["free"], ["vegan"])

    def test_skin_concerns(self):
        attrs, _ = A.rules(product("Serum", category="skincare", description="Fades dark spots on acne-prone skin."))
        self.assertEqual(sorted(attrs["skin"]), ["acne", "dark_spots"])

    def test_scent_notes_come_from_the_title_or_a_notes_passage(self):
        attrs, _ = A.rules(product("Vanilla Oud Candle", category="home", description="Top notes: bergamot, rose."))
        self.assertEqual(attrs["scent"], ["vanilla", "oud", "bergamot"])
        attrs, _ = A.rules(product("Candle", category="home", description="Poured by hand near a rose garden."))
        self.assertNotIn("scent", attrs)

    # Owner, 2026-11-22: hair and scalp concerns, texture and porosity, and
    # the skin concerns a parent shops baby products by.
    def test_hair_and_scalp_concerns_need_the_brands_words(self):
        attrs, cand = A.rules(product("Scalp Serum", description="Soothes a dry, itchy scalp and prevents breakage."))
        self.assertEqual(attrs["hairneed"], ["dry_scalp", "damage"])
        self.assertEqual(cand, [])
        attrs, _ = A.rules(product("Anti-Dandruff Shampoo", description="For sensitive scalps."))
        self.assertEqual(attrs["hairneed"], ["sensitive_scalp", "dandruff"])
        attrs, _ = A.rules(product("Growth Oil", description="Promotes hair growth and fuller edges."))
        self.assertEqual(attrs["hairneed"], ["thinning"])
        attrs, _ = A.rules(product("Leave-In", description="Safe for color-treated hair. Fights frizz."))
        self.assertEqual(sorted(attrs["hairneed"]), ["color_treated", "frizz"])

    def test_a_warning_or_a_passing_mention_is_not_a_concern(self):
        attrs, cand = A.rules(product("Edge Gel", description="Holds all day with no flakes."))
        self.assertNotIn("hairneed", attrs)
        self.assertEqual(cand, [])
        # A warning names the problem without the product being for it.
        attrs, cand = A.rules(product("Relaxer", description="Overuse may cause breakage."))
        self.assertNotIn("hairneed", attrs)
        self.assertIn(("hairneed", "damage"), cand)
        # Thinning shears are a tool, not a product for thinning hair.
        attrs, _ = A.rules(product("Thinning Shears", description="Steel shears."))
        self.assertNotIn("hairneed", attrs)

    def test_dry_hair_is_a_need_not_an_instruction(self):
        attrs, cand = A.rules(product("Wide Tooth Comb", description="Glides through wet or dry hair. Apply to dry hair before styling."))
        self.assertNotIn("hairneed", attrs)
        self.assertEqual(cand, [])
        attrs, _ = A.rules(product("Deep Conditioner", description="Quenches dry hair and softens brittle hair."))
        self.assertEqual(attrs["hairneed"], ["dry_hair"])
        attrs, _ = A.rules(product("Butter for Dry, Damaged Hair"))
        self.assertIn("dry_hair", attrs["hairneed"])

    def test_texture_and_porosity_sit_with_the_hair_types(self):
        attrs, _ = A.rules(product("Leave-In", description="Made for low porosity, fine hair."))
        self.assertEqual(sorted(attrs["hair"]), ["fine", "low_porosity"])
        attrs, _ = A.rules(product("Butter", description="Rich enough for thick hair and high-porosity curls."))
        self.assertIn("thick", attrs["hair"])
        self.assertIn("high_porosity", attrs["hair"])
        # "Thinning hair" is a concern, not the fine/thin texture.
        attrs, _ = A.rules(product("Serum", description="For thinning hair."))
        self.assertNotIn("hair", attrs)
        self.assertEqual(attrs["hairneed"], ["thinning"])

    def test_baby_products_carry_the_three_skin_concerns_and_free_of(self):
        attrs, _ = A.rules(product("Baby Balm", category="baby",
                                   description="Gentle, fragrance-free care for eczema-prone and sensitive skin. Fades dark spots."))
        self.assertEqual(attrs["skin"], ["eczema", "sensitive"])
        self.assertEqual(attrs["free"], ["fragrance"])
        self.assertNotIn("skintype", attrs)
        attrs, cand = A.rules(product("Teether", category="baby", description="A toy."))
        self.assertEqual((attrs, cand), ({}, []))

    def test_razor_bumps_are_a_skin_concern(self):
        attrs, _ = A.rules(product("Shave Oil", category="skincare", description="Helps prevent razor bumps and ingrown hairs."))
        self.assertIn("razor_bumps", attrs["skin"])

    def test_every_value_jev_can_be_asked_about_has_a_label(self):
        for field, table in (("hair", A.HAIR), ("skin", A.SKIN), ("hairneed", A.HAIRNEED)):
            self.assertIn(field, A.QUESTION)
            for value in table:
                self.assertIn(value, A.LABEL, f"{field}:{value}")

    def test_no_attrs_outside_their_departments(self):
        attrs, cand = A.rules(product("4C Hair Tee", category="clothing", description="Fragrance-free fun"))
        self.assertNotIn("hair", attrs)
        self.assertNotIn("free", attrs)


class Verdicts(unittest.TestCase):
    def test_a_candidate_needs_a_cached_yes_at_09(self):
        p = product("Edge Gel", description="Unlike gels that flake, 4C looks stay soft.")
        k = A.seen_key(p, "hair", "4c")
        _, todo = A.annotate([p], {k: 0.89})
        self.assertNotIn("attrs", p)
        self.assertEqual(todo, [])
        A.annotate([p], {k: 0.93})
        self.assertEqual(p["attrs"], {"hair": ["4c"]})

    def test_uncached_candidates_are_returned_to_ask(self):
        p = product("Edge Gel", description="Unlike gels that flake, 4C looks stay soft.")
        _, todo = A.annotate([p], {})
        self.assertEqual([(f, v) for _, f, v in todo], [("hair", "4c")])

    def test_every_question_is_one_allow_listed_value(self):
        for field, value in [("hair", v) for v in A.HAIR] + [("skin", v) for v in A.SKIN]:
            self.assertIn(value, A.LABEL)
            self.assertTrue(A.QUESTION[field].format(label=A.LABEL[value]))


if __name__ == "__main__":
    unittest.main()


def skin(title, product_type="", description="", tags=()):
    return product(title, category="skincare", product_type=product_type, tags=tags, description=description)


class Skincare(unittest.TestCase):
    """Sephora-style skincare filters (owner, 2026-11-04), skincare only."""

    def test_skin_types_from_a_for_passage_and_all_skin_types(self):
        attrs, _ = A.rules(skin("Gel Cleanser", description="Made for oily and combination skin. Gentle enough for all skin types."))
        self.assertEqual(attrs["skintype"], ["oily", "combination", "all"])

    def test_a_skin_type_mentioned_in_passing_is_not_one(self):
        attrs, _ = A.rules(skin("Body Butter", description="Our founder has dry skin."))
        self.assertNotIn("skintype", attrs)

    def test_ingredients_from_the_name_the_description_or_the_published_list(self):
        attrs, _ = A.rules(skin("Niacinamide Serum", description="Powered by hyaluronic acid."),
                           inci="Water, Glycerin, Squalane, Sodium Ascorbyl Phosphate")
        self.assertEqual(attrs["ingredient"], ["vitamin_c", "hyaluronic", "niacinamide", "squalane"])

    def test_an_ingredient_left_out_or_compared_against_is_not_in_it(self):
        attrs, _ = A.rules(skin("Bakuchiol Night Oil", description="A gentle alternative to retinol. Free of salicylic acid."))
        self.assertEqual(attrs["ingredient"], ["bakuchiol"])

    def test_lactic_acid_late_in_the_list_is_a_ph_adjuster_not_an_aha(self):
        late = ", ".join(["Water"] + [f"Extract {i}" for i in range(14)] + ["Lactic Acid"])
        attrs, _ = A.rules(skin("Face Cream"), inci=late)
        self.assertNotIn("ingredient", attrs)
        attrs, _ = A.rules(skin("Face Cream"), inci="Water, Lactic Acid, Glycerin")
        self.assertEqual(attrs["ingredient"], ["aha"])

    def test_one_form_the_word_the_name_ends_on(self):
        self.assertEqual(A.rules(skin("Yuzu Body Oil Bar"))[0]["form"], ["bar"])
        self.assertEqual(A.rules(skin("Shea Butter Infused Body Lotion"))[0]["form"], ["lotion"])
        self.assertNotIn("form", A.rules(skin("Turmeric Soap with Neem Oil"))[0])
        self.assertNotIn("form", A.rules(skin("Oil-Free Moisturizer"))[0])

    def test_sets_minis_and_refills(self):
        self.assertEqual(A.rules(skin("Glow Gift Set"))[0]["pack"], ["set"])
        self.assertNotIn("form", A.rules(skin("Body Butter and Oil Gift Set"))[0], "a set holds several forms")
        self.assertEqual(A.rules(skin("Toner (Travel Size)"))[0]["pack"], ["mini"])
        self.assertEqual(A.rules(skin("Moisturizer Refill"))[0]["pack"], ["refill"])

    def test_spf_from_the_name_or_a_sun_products_claim_only(self):
        self.assertEqual(A.rules(skin("Mineral Sunscreen SPF 50"))[0]["spf"], ["high"])
        self.assertEqual(A.rules(skin("Daily Sunscreen", description="Broad spectrum SPF 30."))[0]["spf"], ["low"])
        self.assertNotIn("spf", A.rules(skin("Vitamin C Serum", description="Follow with a broad spectrum SPF 30."))[0])

    def test_new_concerns_need_a_skin_word(self):
        self.assertIn("dullness", A.rules(skin("Glow Serum", description="Brightens dull skin."))[0]["skin"])
        self.assertNotIn("skin", A.rules(skin("Herbal Tea", description="Helps brighten your morning."))[0])

    def test_skin_filters_are_skincare_only_and_hair_filters_hair_only(self):
        makeup = product("Foundation for Oily Skin SPF 30", category="makeup", description="Fragrance-free.")
        self.assertEqual(A.rules(makeup)[0], {})
        baby = product("Baby Hair Oil for Curls", category="baby")
        self.assertEqual(A.rules(baby)[0], {})
        hair = product("Sulfate-Free Shampoo for Oily Scalp", category="hair")
        self.assertEqual(A.rules(hair)[0], {"free": ["sulfate"]})

    def test_skin_only_preferences(self):
        attrs, _ = A.rules(skin("Moisturizer", description="Oil-free and non-comedogenic. Cruelty-free."))
        self.assertEqual(sorted(attrs["free"]), ["cruelty_free", "noncomedogenic", "oil"])

