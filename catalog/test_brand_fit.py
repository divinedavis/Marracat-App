"""Products far from their brand's usual department, settled by cached Jev
verdicts (catalog/brand_fit.py; owner 2026-10-10)."""
import build_catalog as bc
import brand_fit as bf


def prod(pid, cat, title="Thing", brand="b"):
    return {"id": pid, "brand": brand, "title": title, "product_type": None, "tags": [],
            "category": cat, "subs": [], "url": f"https://b.example/products/{pid}"}


BRANDS = {"b": {"id": "b", "name": "B", "category": "skincare"}}


def catalog():
    return [prod(f"s{i}", "skincare", f"Body Butter {i}") for i in range(19)] + [prod("odd", "grocery", "Coffee Soap Bar")]


def test_flags_a_rare_department_at_a_focused_brand():
    flags = bf.flagged(catalog(), BRANDS)
    assert [(p["id"], m) for p, m in flags] == [("odd", "skincare")]


def test_small_or_mixed_brands_are_not_flagged():
    small = [prod(f"s{i}", "skincare") for i in range(5)] + [prod("odd", "grocery")]
    assert bf.flagged(small, BRANDS) == []
    mixed = [prod(f"s{i}", "skincare") for i in range(10)] + [prod(f"c{i}", "clothing") for i in range(10)]
    assert bf.flagged(mixed, BRANDS) == []


def test_a_confident_yes_moves_it_and_anything_else_leaves_it():
    for p_yes, moves in [(0.97, True), (0.6, False)]:
        rows = catalog()
        odd = rows[-1]
        v = {"odd": {"seen": bc.jev_key(odd), "main": "skincare", "from": "grocery", "p": p_yes}}
        moved = bf.apply(rows, BRANDS, v)
        assert (odd["category"] == "skincare") is moves and len(moved) == int(moves)


def test_an_edited_or_already_moved_product_ignores_its_old_verdict():
    rows = catalog()
    odd = rows[-1]
    v = {"odd": {"seen": bc.jev_key(odd), "main": "skincare", "from": "grocery", "p": 0.99}}
    odd["title"] = "Coffee Beans 1 lb"          # the merchant changed the listing
    assert bf.apply(rows, BRANDS, v) == [] and odd["category"] == "grocery"
    odd["title"] = "Coffee Soap Bar"
    odd["category"] = "home"                    # something else re-filed it since
    assert bf.apply(rows, BRANDS, v) == [] and odd["category"] == "home"


def test_the_committed_cache_is_well_formed():
    # Builds apply this file without the key, so a bad row would break them.
    cache = bf.load()
    assert cache, "catalog/jev_brand_fit.json should ship with the verdicts already asked"
    for pid, v in cache.items():
        assert set(v) >= {"seen", "main", "from", "p"}, pid
        assert v["main"] in bc.CATEGORIES_BY_ID and v["from"] in bc.CATEGORIES_BY_ID, pid
        assert 0.0 <= v["p"] <= 1.0 and len(v["seen"]) == 12, pid
