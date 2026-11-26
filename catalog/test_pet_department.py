"""Pet Supplies takes things for a pet, not things that mention one
(build_catalog.names_pet_goods). A shopper looking at collars in Pet Supplies
met a Telfar "Collar T" on 2026-11-25; 19 records and 35 stickers, cards and
prints sat in the department with it."""
import build_catalog as bc
import department_rules as dr

CLOTHING = {"id": "tf", "category": "clothing"}
MUSIC = {"id": "rs", "category": "music"}
PARTY = {"id": "am", "category": "party"}
BAGS = {"id": "kg", "category": "bags"}
PETS = {"id": "tp", "category": "pets"}


def p(title, ptype=None, handle="x"):
    return {"id": "x-1", "brand": "x", "title": title, "product_type": ptype, "tags": [],
            "url": f"https://x.example/products/{handle}"}


def test_a_collar_on_a_shirt_is_not_a_pet_collar():
    assert bc.categorize(p("Infinity Canal All Over Collar T - Black", "clothing"), CLOTHING) == "clothing"
    assert bc.categorize(p("Mars Ill – Blue Collar Sessions", 'Vinyl 12"'), MUSIC) == "music"
    assert bc.categorize(p("Unisex Fashion Harness - Black", "Unisex Harness"), BAGS) != "pets"
    assert bc.categorize(p("Pink Collar Crime - Gel Lacquer", "Nail Lacquer"),
                         {"id": "pn", "category": "makeup"}) == "makeup"


def test_a_title_about_a_pet_is_not_for_one():
    for title, ptype, brand in [
        ("David Bowie - Diamond Dogs: 2016 Remastered Version [LP]", "Vinyl", MUSIC),
        ("Pet Shop Boys – It's A Sin", 'Vinyl 12"', MUSIC),
        ("Al Stewart - Year of the Cat (Rhino Reserve)", "Vinyl", MUSIC),
        ("Birthday Dog Card", "Card", PARTY),
        ("Sleeping Dog Print - A5", "Print", PARTY),
        ("Best Cat Mom Sticker", "Sticker", PARTY),
        ("Cat Christmas Tree Card", None, PARTY),
        ("Cat’s Eye", None, {"id": "hs", "category": "wellness"}),
        ("Cat Eye Brush", None, {"id": "mk", "category": "makeup"}),
    ]:
        assert bc.categorize(p(title, ptype), brand) != "pets", title


def test_pet_goods_at_any_brand_still_land_in_pets():
    for title, ptype, brand in [
        ("Aisha Dog Bandana", None, BAGS),
        ("Tibuno Pet house", None, BAGS),
        ("Pet Refresh Spray", None, {"id": "lj", "category": "hair"}),
        ("Handmade Dog/Cat Accessories", None, CLOTHING),
        ("TDE New Classic Dog Bowl", "Accessories", MUSIC),
        ("Luoto Dog Bed - Signature", "Decor", {"id": "gd", "category": "home"}),
        ("Etna Woven Cotton Dog Collar - Navy", "Pets", {"id": "gd", "category": "home"}),
        ("Beltline Collar - Natural", "Dog Collar", BAGS),          # the type says whose
        ("Crystal Pet Guardian Charm", "Pet Collar Charm", {"id": "lj", "category": "jewelry"}),
        ("Beltline Leash - Brown", None, BAGS),                      # goods by name
        ("Catnip Organic", "Bulk Herbs", {"id": "ss", "category": "wellness"}),
        ("Neem PET Wash (8 oz)", "Pet Care", {"id": "ah", "category": "skincare"}),
    ]:
        assert bc.categorize(p(title, ptype), brand) == "pets", title


def test_a_pet_brands_own_products_are_untouched():
    assert bc.categorize(p("Collar Ice Blue", "Collars"), PETS) == "pets"
    assert bc.categorize(p("Cuban Link Gold Chain Collar", "Collars"), PETS) == "pets"
    assert bc.categorize(p("Sushi Harness"), PETS) == "pets"


def test_a_pin_that_froze_the_old_guess_no_longer_holds_a_product_in_pets():
    polish = p("Pink Collar Crime - Classic Lacquer", "Nail Lacquer", handle="pink-collar-crime")
    brand = {"id": "pn", "category": "makeup", "product_categories": {"pink-collar-crime": "pets"}}
    assert bc.categorize(polish, brand, bare_pet_words=True) == "pets", "what the import froze"
    assert bc.placed("pets", polish, brand, "pink-collar-crime") == "makeup"
    assert not dr.hand_pinned(polish, brand, bc), "or Jev's move to Makeup would be undone"
    # A review that confirmed it (pinned_handles) still holds, as does a pin
    # to pets the keywords never gave, and any pin to another department.
    reviewed = {**brand, "pinned_handles": ["pink-collar-crime"]}
    assert bc.placed("pets", polish, reviewed, "pink-collar-crime") == "pets"
    assert dr.hand_pinned(polish, reviewed, bc)
    oil = p("RizFrizz Premium Healing Dry Oil", "Oil", handle="dry-oil")
    by_hand = {"id": "sv", "category": "household", "product_categories": {"dry-oil": "pets"}}
    assert bc.placed("pets", oil, by_hand, "dry-oil") == "pets"
    assert dr.hand_pinned(oil, by_hand, bc)
    assert bc.placed("home", polish, brand, "pink-collar-crime") == "home"
    assert bc.placed(None, polish, brand, "pink-collar-crime") == "makeup"
