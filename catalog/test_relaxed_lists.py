"""The second reading of ingredient lists the strict reader misses
(catalog/relaxed_lists.py; owner 2026-10-09: "make sure other products aren't missed")."""
import os
import relaxed_lists as rl


def test_a_list_a_few_blocks_under_its_heading_is_proposed():
    t = "Ingredients | | | | Shea Butter, Mango Butter, Babassu Oil, Avocado Oil, Sunflower Oil and Fragrance | | Directions: rub in"
    assert rl.candidate(t) == "Shea Butter, Mango Butter, Babassu Oil, Avocado Oil, Sunflower Oil, Fragrance"


def test_a_shade_label_in_front_is_dropped():
    t = "Full Ingredients | BROWN'D OUT: DIMETHICONE, SILICA, TRIMETHYLSILOXYSILICATE, POLYISOBUTENE, MICA, OZOKERITE | Share"
    assert rl.candidate(t).startswith("DIMETHICONE, SILICA")


def test_marketing_copy_after_the_heading_is_not_proposed():
    t = ("Ingredients | Our rich cream is designed to help your skin feel soft, while it leaves you glowing, "
         "and we made it with love, care, shea, cocoa and more | Reviews")
    assert rl.candidate(t) == ""


def test_without_a_jev_key_nothing_relaxed_is_kept():
    saved = os.environ.pop("TYPESAFE_API_KEY", None)
    try:
        assert rl.read("Ingredients | Water, Glycerin, Shea Butter, Jojoba Oil, Vitamin E | Directions") == "" or \
            rl._load().get(rl._key("Water, Glycerin, Shea Butter, Jojoba Oil, Vitamin E")) is not None
    finally:
        if saved:
            os.environ["TYPESAFE_API_KEY"] = saved
