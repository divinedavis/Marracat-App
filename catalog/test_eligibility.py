"""Label eligibility beyond the title (catalog/eligibility.py; owner, 2026-10-09:
FORVR Mood's perfumes, titled "NDA", were never checked)."""
import json
import pathlib
import tempfile
import eligibility as el
import safer_clean_badge as sc
import scent_badge as sb


def perfume(title, handle, tags=(), pid="p1"):
    return {"id": pid, "title": title, "product_type": None, "category": "fragrance", "subs": [],
            "tags": list(tags), "url": f"https://forvrmood.com/products/{handle}"}


def test_the_url_handle_says_what_a_scent_named_product_is():
    assert sb.eligible(perfume("NDA", "nda-edp-1-7-oz"))
    assert sb.eligible(perfume("SHE WAS HERE", "she-was-here-eau-de-parfum"))


def test_a_store_tag_counts_but_a_set_or_case_stays_out():
    assert sb.eligible(perfume("CASINO", "casino", tags=["perfume", "unisex"]))
    assert not sb.eligible(perfume("MOOD DISCOVERY SET", "mood-5pc-discovery-set", tags=["fragrance"]))
    assert not sb.eligible(perfume("FORVR Fragrance Clutch", "fragrance-clutch-bag", tags=["fragrance"]))


def test_a_tag_never_excludes():
    assert sb.eligible(perfume("I AM HER", "i-am-her-edp-1-7oz", tags=["candle lover", "fragrance"]))


def test_a_cleaner_named_only_in_its_handle_is_checked():
    p = {"id": "c1", "title": "Supersalt", "product_type": "", "category": "household", "subs": [], "tags": [],
         "url": "https://example.com/products/supersalt-laundry-detergent"}
    assert sc.eligible(p)


def test_jev_yes_counts_only_for_what_it_saw():
    p = perfume("Symphony 15 ML", "symphony-15", pid="sym")
    real = el.VERDICTS
    cache = pathlib.Path(tempfile.mkdtemp()) / "jev.json"
    cache.write_text("{}")
    el.VERDICTS = cache
    el.reset_cache()
    try:
        assert not sb.eligible(p)
        cache.write_text(json.dumps({"scent": {"sym": {"seen": el.seen_key(p), "p": 0.91}}}))
        el.reset_cache()
        assert sb.eligible(p)
        p["title"] = "Symphony Candle"
        assert not sb.eligible(p), "a product edited since Jev saw it isn't trusted"
        cache.write_text(json.dumps({"scent": {"sym": {"seen": el.seen_key(perfume("Symphony 15 ML", "symphony-15")), "p": 0.4}}}))
        el.reset_cache()
        assert not sb.eligible(perfume("Symphony 15 ML", "symphony-15", pid="sym")), "an unsure Jev isn't a yes"
    finally:
        el.VERDICTS = real
        el.reset_cache()


def test_a_sure_not_food_never_gets_the_food_badge_and_alcohol_never_comes_back():
    import food_badge as fd
    mist = {"id": "m1", "title": "Cocoa Amber Mist", "product_type": "", "category": "grocery", "subs": [], "tags": [],
            "url": "https://divinepurity.co/products/cocoa-amber-mist"}
    rum = {"id": "r1", "title": "GOLDEN HOUR JAMAICAN RUM PUNCH (4 pack)", "product_type": "", "category": "grocery",
           "subs": [], "tags": [], "url": "https://x.com/products/rum-punch"}
    real = el.VERDICTS
    cache = pathlib.Path(tempfile.mkdtemp()) / "jev.json"
    cache.write_text(json.dumps({"food_check": {"m1": {"seen": el.seen_key(mist), "p": 0.02}},
                                 "food": {"r1": {"seen": el.seen_key(rum), "p": 0.97}}}))
    el.VERDICTS = cache
    el.reset_cache()
    try:
        assert not fd.eligible(mist), "a body mist filed under grocery isn't food"
        assert not fd.eligible(rum), "Jev can't bring alcohol into Clean Food"
    finally:
        el.VERDICTS = real
        el.reset_cache()
