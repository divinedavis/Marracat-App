"""catalog/gender.py: Women / Men on clothing and shoes (owner, 2026-11-08)."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import gender as G  # noqa: E402


def product(pid, title="Tee", brand="b", category="clothing", subs=("tees",), tags=(), ptype="", url=None):
    return {"id": pid, "brand": brand, "title": title, "category": category, "subs": list(subs),
            "tags": list(tags), "product_type": ptype, "url": url or f"https://b.example/products/{pid}"}


def test_words_that_say_who_it_is_for():
    assert G.side_of_text("Men's Pinnacle Zipper Hoodie", "", []) == {"men"}
    assert G.side_of_text("Womens Cotton Twill Jacket", "", []) == {"women"}
    assert G.side_of_text("adidas Adistar Control 5 Women (Preloved)", "", []) == {"women"}
    assert G.side_of_text("Tee", "Womens Tops", []) == {"women"}
    assert G.side_of_text("Tee", "", ["Gender: Female"]) == {"women"}
    assert G.side_of_text("Tee", "", ["mens-tops"]) == {"men"}
    assert G.side_of_text("Hoodie", "", ["Unisex"]) == {"women", "men"}
    assert G.side_of_text("Tee", "", ["Women", "Men"]) == {"women", "men"}


def test_slogans_and_lookalikes_say_nothing():
    assert G.side_of_text("“I Love Black Women” Shirt", "", []) == set()
    assert G.side_of_text("Female Rappers Remix Sweatshirt", "", []) == set()
    assert G.side_of_text("Batman Tee", "", ["menu", "mental health"]) == set()


def test_collections_beat_words_and_kids_are_left_out():
    cols = {"b": {"women": ["a"], "men": ["c"], "unisex": ["d"]}}
    ps = [product("a", "Men's tee"), product("c"), product("d"), product("k", "Women's tee", subs=["kids"]),
          product("bag", "Women's tote", category="bags", subs=["tote"])]
    G.annotate(ps, cols)
    assert ps[0]["attrs"]["gender"] == ["women"], "the brand's own collection decides"
    assert ps[1]["attrs"]["gender"] == ["men"]
    assert ps[2]["attrs"]["gender"] == ["men", "women"]
    assert "attrs" not in ps[3] and "attrs" not in ps[4], "kids and other departments stay unlabelled"


def test_women_only_aisles_and_brand_defaults():
    ps = [product(f"d{i}", "Maxi", brand="lab", subs=["dresses"]) for i in range(20)]
    ps += [product("t1", "Linen top", brand="lab"), product("t2", "Top", brand="mixed")]
    counts, defaults = G.annotate(ps, {})
    assert ps[0]["attrs"]["gender"] == ["women"]
    assert defaults == {"lab": "women"}
    assert ps[20]["attrs"]["gender"] == ["women"], "a womenswear label's unlabelled top follows the brand"
    assert "attrs" not in ps[21]
    assert counts["brand"] == 1 and counts["unlabelled"] == 1


def test_a_mixed_brand_gets_no_default():
    ps = [product(f"w{i}", "Women's tee", brand="m") for i in range(19)] + \
         [product(f"m{i}", "Men's tee", brand="m") for i in range(3)] + [product("x", "Tee", brand="m")]
    _, defaults = G.annotate(ps, {})
    assert defaults == {}
    assert "attrs" not in ps[-1]


def test_other_attrs_survive_and_old_gender_is_replaced():
    p = product("a", "Tee")
    p["attrs"] = {"fabric": "cotton", "gender": ["men"]}
    G.annotate([p], {})
    assert p["attrs"] == {"fabric": "cotton"}


def test_collection_handles():
    pick = G.gendered_collections(["womens", "womens-dresses", "for-him", "mens-tops", "menu", "women-of-color-art",
                                   "unisex-hoodies", "home", "mentorship"])
    assert pick["women"][0] == "womens"
    assert "menu" not in pick["men"] and "mentorship" not in pick["men"]
    assert pick["unisex"] == ["unisex-hoodies"]
