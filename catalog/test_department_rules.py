"""Product type and gift sets in the department choice (catalog/department_rules.py;
owner 2026-10-10: "better department sorting for gift sets and new brands")."""
import build_catalog as bc
import department_rules as dr

SKIN = {"id": "lm", "category": "skincare"}


def row(title, ptype=None, cat="party", pid="lm-1", handle="x"):
    return {"id": pid, "brand": "lm", "title": title, "product_type": ptype, "tags": [],
            "category": cat, "subs": [], "url": f"https://lm.example/products/{handle}"}


def placed(r, brand=SKIN, mode="skincare"):
    return dr.proposed(r, brand, mode, dr.Evidence(bc))


def test_type_names_one_department_and_skips_gift_words():
    assert dr.type_vote("Body, Gift Set", "skincare") == "skincare"
    assert dr.type_vote("Soap", "home") == "skincare"
    assert dr.type_vote("Bath & Body", "home") == "skincare"
    assert dr.type_vote("Bath & Beauty", "makeup") is None, "plain 'bath' names nothing"
    assert dr.type_vote("Accessories", "hair") is None, "too generic to name a department"
    assert dr.type_vote("Body", "clothing") is None, "'Body' is a bodysuit at a clothing label"
    assert dr.type_vote("Candles, Hoodies", "home") is None, "two departments: no vote"


def test_lillie_mae_misfiles_land_in_skincare_without_pins():
    # The 11 products pinned by hand on 2026-10-10, as their store lists them.
    for title, ptype, was in [
        ("Happy Mother’s Day", "Body, Gift Set", "party"),
        ("Men’s Body Ultimate Body  Butter Gift Set", "Body, Gift Set", "party"),
        ("(Full Log)  Rosehip and Cranberry", "Body, Gift Set", "party"),
        ("Customized Gift Sets", None, "party"),
        ("Dear Gentleman,", "Gift Set", "party"),
        ("Lavender Gift Set", "Gift Set", "party"),
        ("Hot~Flash Spritzer Gift Set", "Body, Gift Set", "party"),
        ("Oud Elemi and Beet Root Powder Soap", "Soap", "makeup"),
        ("Belizean Coffee Soap Bar", "Body", "grocery"),
    ]:
        assert placed(row(title, ptype, was)) == "skincare", title


def test_title_evidence_keeps_a_product_against_a_vague_type():
    assert placed(row("African Decor Edit Book", "Decor", "books"), {"id": "m", "category": "home"}, "home") is None
    assert placed(row("Dual Finish Palette - #2", "Face", "makeup"), {"id": "j", "category": "makeup"}, "makeup") is None


def test_gift_words_only_send_party_items_to_the_brand_mix():
    # Something real still names Party.
    assert placed(row("Greeting Card Bundle", None, "party"), {"id": "c", "category": "home"}, "home") is None
    # A kit that names nothing, outside Party, stays put.
    assert placed(row("Biotensify + EWG - 3 kit set", None, "skincare"), {"id": "m", "category": "hair"}, "hair") is None
    # A candle gift set names Home.
    assert placed(row("Love Luxury Candle Gift Set", "Candle Gift Set", "party"), {"id": "h", "category": "home"}, "home") == "home"


def test_refine_leaves_hand_pins_and_confident_jev_alone():
    # A pin that differs from the keyword guess (Party) was placed by hand; one
    # that equals it is a frozen import guess and may be improved.
    brand = {"id": "lm", "category": "skincare", "product_categories": {"pinned": "home"}}
    pinned = row("Lavender Gift Set", "Gift Set", "home", pid="lm-2", handle="pinned")
    saved = dict(bc.JEV)
    try:
        jev = row("Happy Mother’s Day", "Body, Gift Set", "party", pid="lm-3")
        bc.JEV["lm-3"] = {"choice": "party", "confidence": 0.95, "seen": bc.jev_key(jev)}
        free = row("(Full Log)  Rosehip and Cranberry", "Body, Gift Set", "party", pid="lm-4")
        rows = [pinned, jev, free] + [row(f"Body Butter {i}", "Body", "skincare", pid=f"lm-b{i}") for i in range(4)]
        moved = dr.refine(rows, brand, bc)
    finally:
        bc.JEV.clear()
        bc.JEV.update(saved)
    assert [r["id"] for r, _o, _n in moved] == ["lm-4"]
    assert pinned["category"] == "home" and jev["category"] == "party" and free["category"] == "skincare"


def test_owner_review_2026_10_11_misfiles():
    # A type part we can't place may be the real noun: classroom cards stay in Toys.
    assert dr.type_vote("Flashcards / Decor", "toys") is None
    assert dr.type_vote("Herbs & Spices", "wellness") == "grocery"
    # A watch gift set is an accessory, not Home.
    assert placed(row("The Legacy Timepiece Gift Set"), {"id": "mm", "category": "home"}, None) == "accessories"
    # Shower steamers are bath products, not the plant shop's Garden.
    assert placed(row("Shower Steamers | Eucalyptus + Mint | 6 Tablets | Gift Set"),
                  {"id": "cp", "category": "garden"}, "garden") == "skincare"
    # A scalp exfoliant filed as Bath & Body stays in Hair Care.
    assert placed(row("Aloe Vera, Fenugreek & Rosemary Botanical Scalp Exfoliant", "Bath & Body", cat="hair"),
                  {"id": "th", "category": "hair"}, "hair") is None


def test_gift_set_at_a_mixed_brand_stays_put():
    rows = [{"category": c, "title": "x", "product_type": None} for c in
            ["home"] * 3 + ["clothing"] * 2 + ["party"] * 2 + ["bags"] * 2]
    assert dr.brand_mode(rows, {"category": "home"}) is None, "home is 3 of 9: no clear department"
    assert placed(row("Mystery Gift Box"), {"id": "mx", "category": "home"}, None) is None
    rows = [{"category": "skincare", "title": "x", "product_type": None}] * 4 + [{"category": "home", "title": "y", "product_type": None}]
    assert dr.brand_mode(rows, {"category": "skincare"}) == "skincare"


def test_pinned_handles_make_a_pin_that_matches_the_keyword_guess_a_hand_pin():
    # A photo-check false positive (2026-10-12) pinned to where it already was.
    r = row("Lavender Body Butter", cat="skincare", handle="butter")
    guess = bc.categorize(r, SKIN)
    brand = {**SKIN, "product_categories": {"butter": guess}}
    assert not dr.hand_pinned(r, brand, bc), "a frozen import guess is not a hand pin"
    assert dr.hand_pinned(r, {**brand, "pinned_handles": ["butter"]}, bc)
    other = "home" if guess != "home" else "garden"
    assert dr.hand_pinned(r, {**SKIN, "product_categories": {"butter": other}}, bc)


class photo_moves:
    def __init__(self, moves):
        self.moves = moves

    def __enter__(self):
        self.saved, bc.PHOTO_MOVES = bc.PHOTO_MOVES, self.moves

    def __exit__(self, *exc):
        bc.PHOTO_MOVES = self.saved


def test_a_photo_move_counts_as_placed_on_purpose_only_for_the_same_photo():
    r = {**row("Philodendron 'Mamei'", cat="garden", pid="lg-1"), "images": ["https://x/1.jpg"]}
    with photo_moves({"lg-1": {"to": "garden", "photo": dr.photo_key(r)}}):
        assert dr.placed_on_purpose(r, SKIN, bc)
        assert not dr.placed_on_purpose({**r, "images": ["https://x/2.jpg"]}, SKIN, bc)
        assert not dr.placed_on_purpose({**r, "category": "wellness"}, SKIN, bc)


def test_build_applies_a_photo_move_unless_hand_pinned_or_the_photo_changed():
    r = {**row("Philodendron 'Mamei'", cat="wellness", pid="lg-1", handle="mamei"), "images": ["https://x/1.jpg"]}
    with photo_moves({"lg-1": {"to": "garden", "subs": ["plants-seeds"], "photo": dr.photo_key(r)}}):
        changed = {**r, "images": ["https://x/2.jpg"]}
        assert not bc.apply_photo_move(changed, SKIN) and changed["category"] == "wellness"
        pinned = {**SKIN, "product_categories": {"mamei": "wellness"}, "pinned_handles": ["mamei"]}
        assert not bc.apply_photo_move(dict(r), pinned)
        assert bc.apply_photo_move(r, SKIN) and (r["category"], r["subs"]) == ("garden", ["plants-seeds"])
