"""Aisle assignment for products (catalog/taxonomy.py)."""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from taxonomy import flat_subcategories, subcategories_of  # noqa: E402


def test_sweatpants_get_their_own_aisle_and_stay_pants():
    for title in ["Essentials SS26 Classic Sweatpant", "Mauve Travel Joggers", "Ripstop Classic Track Pant"]:
        subs = subcategories_of({"title": title, "product_type": "Bottoms"}, "clothing")
        assert "sweatpants" in subs and "pants" in subs, (title, subs)


def test_trousers_are_not_sweatpants():
    subs = subcategories_of({"title": "Cotton Twill Pleated Trouser", "product_type": "Bottoms"}, "clothing")
    assert "pants" in subs and "sweatpants" not in subs


def test_sweatpants_aisle_is_listed():
    assert {"id": "clothing:sweatpants", "name": "Sweatpants & Joggers", "category": "clothing"} in flat_subcategories()


def test_a_saved_pants_aisle_still_gains_sweatpants():
    from taxonomy import with_added_aisles
    p = {"title": "home/wear by Curves Sweatpant (Magenta)", "product_type": None}
    assert with_added_aisles(p, "clothing", ["pants", "plus"]) == ["pants", "plus", "sweatpants"]
    assert with_added_aisles({"title": "Pleated Trouser"}, "clothing", ["pants"]) == ["pants"]
    assert with_added_aisles(p, "clothing", ["sweatpants"]) == ["sweatpants"], "no duplicate"
