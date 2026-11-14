import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import photo_categories as C  # noqa: E402

CATALOG = {
    "categories": [{"id": "jewelry", "name": "Jewelry"}, {"id": "garden", "name": "Garden & Outdoor"}],
    "subcategories": [{"id": "jewelry:necklaces", "name": "Necklaces", "category": "jewelry"},
                      {"id": "jewelry:rings", "name": "Rings", "category": "jewelry"},
                      {"id": "garden:plants", "name": "Plants", "category": "garden"}],
}


class Keys(unittest.TestCase):
    def test_a_new_first_photo_is_a_new_key(self):
        p = {"id": "a-1", "images": ["https://x/1.jpg"]}
        self.assertNotEqual(C.vkey(p), C.vkey({**p, "images": ["https://x/2.jpg"]}))
        self.assertEqual(C.vkey(p), C.vkey({**p, "title": "renamed"}))


class Lookalikes(unittest.TestCase):
    def test_bottles_are_lookalikes_but_a_plant_is_not_a_necklace(self):
        self.assertTrue(C.lookalike("skincare", "hair"))
        self.assertTrue(C.lookalike("books", "office"))
        self.assertFalse(C.lookalike("jewelry", "garden"))
        self.assertFalse(C.lookalike("makeup", "clothing"))


class Prompts(unittest.TestCase):
    def test_every_aisle_and_the_no_signal_prompts(self):
        ps = C.prompts(CATALOG)
        self.assertIn(("jewelry", "a product photo of necklaces"), ps)
        self.assertIn(("garden", "a product photo of garden and outdoor"), ps)
        self.assertIn(("garden", "a product photo of a potted plant"), ps)
        self.assertEqual(sum(1 for d, _ in ps if d is None), len(C.NO_SIGNAL))


class Tiers(unittest.TestCase):
    def test_a_plant_filed_as_wellness_is_a_clear_flag(self):
        self.assertEqual(C.tier("garden", "wellness", 0.98, 0.01, 0.99, "Philodendron 'Mamei'"), "clear")

    def test_both_readings_must_be_strong_for_a_clear_flag(self):
        self.assertEqual(C.tier("garden", "wellness", 0.90, 0.01, 0.99, "Fern"), "borderline")
        self.assertEqual(C.tier("garden", "wellness", 0.98, 0.04, 0.99, "Fern"), "borderline")
        self.assertEqual(C.tier("garden", "wellness", 0.98, 0.01, 0.60, "Fern"), "borderline")
        self.assertIsNone(C.tier("garden", "wellness", 0.70, 0.01, 0.99, "Fern"))
        self.assertIsNone(C.tier("garden", "wellness", 0.98, 0.10, 0.99, "Fern"))
        self.assertIsNone(C.tier("garden", "wellness", 0.98, 0.01, 0.30, "Fern"))

    def test_lookalikes_and_purpose_departments_are_only_borderline(self):
        self.assertEqual(C.tier("makeup", "skincare", 0.99, 0.0, 0.99, "Lip Serum"), "borderline")
        self.assertEqual(C.tier("clothing", "jewelry", 0.99, 0.0, 0.99, "Waist Beads"), "borderline")
        self.assertEqual(C.tier("jewelry", "pets", 0.99, 0.0, 0.99, "Cuban Link Collar"), "borderline")

    def test_a_dried_herb_shown_as_the_living_plant_is_only_borderline(self):
        for title in ["Burdock Root – Loose Dried Herb", "Nettle Leaf Tea", "Moringa Capsules – 60 Count"]:
            self.assertEqual(C.tier("garden", "wellness", 0.99, 0.0, 0.99, title), "borderline", title)
        self.assertEqual(C.tier("garden", "wellness", 0.99, 0.0, 0.99, "Hoya Krohniana Black"), "clear")

    def test_photos_that_show_what_a_product_depicts_are_never_flagged(self):
        for title in ["Fumeterre Skirt Pattern - PDF Pattern", "Copper Glitter HTV", "Sunnies Sticker",
                      "The Weeknd - Starboy [2LP]", "Mr. Brown Gift Set", "Monarch Bundle"]:
            self.assertIsNone(C.tier("clothing", "crafts", 0.99, 0.0, 0.99, title), title)

    def test_folds_are_stable_per_product(self):
        self.assertEqual(C.fold_of("a-1"), C.fold_of("a-1"))
        self.assertEqual({C.fold_of(f"p-{i}") for i in range(200)}, set(range(C.FOLDS)))


@unittest.skipIf(C.np is None, "numpy is in the ML venv only")
class Probabilities(unittest.TestCase):
    def test_a_department_with_more_aisles_gets_no_head_start(self):
        np = C.np
        labels = ["jewelry", "jewelry", "jewelry", "garden", None]
        # The photo matches every prompt equally: both departments tie.
        T = np.eye(5, dtype=np.float32)
        V = np.full((1, 5), 0.1, np.float32)
        P, none = C.department_probs(V, labels, T, ["jewelry", "garden"])
        self.assertAlmostEqual(float(P[0, 0]), float(P[0, 1]), places=5)
        self.assertAlmostEqual(float(P.sum() + none.sum()), 1.0, places=5)

    def test_the_closest_prompt_wins_its_department(self):
        np = C.np
        labels = ["jewelry", "jewelry", "garden", None]
        T = np.eye(4, dtype=np.float32)
        V = np.array([[0.0, 0.0, 0.3, 0.0]], np.float32)
        P, _ = C.department_probs(V, labels, T, ["jewelry", "garden"])
        self.assertGreater(P[0, 1], 0.99)


class FakeBC:
    """Just enough of build_catalog for department_rules' pin checks."""
    JEV, JEV_MIN_CONFIDENCE, PHOTO_MOVES = {}, 0.85, {}

    @staticmethod
    def categorize(p, brand):
        return p.get("guess", p["category"])

    @staticmethod
    def jev_key(p):
        return "k"

    @staticmethod
    def jev_confident(v):
        return bool(v and v["confidence"] >= FakeBC.JEV_MIN_CONFIDENCE)


def product(i, brand="lg", cat="wellness", title="Philodendron 'Mamei'"):
    return {"id": f"{brand}-{i}", "brand": brand, "title": title, "category": cat, "subs": [],
            "images": [f"https://x/{brand}{i}.jpg"], "url": f"https://lg.example/products/p{i}"}


def flag(p, to="garden", tier="clear"):
    return {"tier": tier, "id": p["id"], "current": p["category"], "photo": to, "photo_aisle_id": "plants-seeds",
            "photo_p": 0.98, "zeroshot_p": 0.95}


class SafetyCap(unittest.TestCase):
    def test_one_brand_over_holds_only_that_brand(self):
        new = [{"brand": "s"}] * 4 + [{"brand": "a"}, {"brand": "b"}]
        go, kept, why = C.split_held(new, {"s": 126, "a": 50, "b": 50})
        self.assertEqual([m["brand"] for m in go], ["a", "b"])
        self.assertEqual(len(kept), 4)
        self.assertIn("s (4 of 126)", why)

    def test_too_many_in_all_holds_everything(self):
        go, kept, why = C.split_held([{"brand": f"b{i}"} for i in range(51)], {f"b{i}": 1000 for i in range(51)})
        self.assertEqual((go, len(kept)), ([], 51))

    def test_a_normal_run_moves(self):
        new = [{"brand": "lg"}] * 3 + [{"brand": f"b{i}"} for i in range(40)]
        self.assertIsNone(C.held_reason(new, {"lg": 100, **{f"b{i}": 10 for i in range(40)}}))

    def test_more_than_fifty_in_one_run_holds_everything(self):
        new = [{"brand": f"b{i}"} for i in range(51)]
        self.assertIn("51 moves", C.held_reason(new, {f"b{i}": 1000 for i in range(51)}))

    def test_more_than_two_percent_of_a_big_brand_holds(self):
        sizes = {"big": 1000}
        self.assertIsNone(C.held_reason([{"brand": "big"}] * 20, sizes))
        self.assertIn("big (21 of 1000)", C.held_reason([{"brand": "big"}] * 21, sizes))

    def test_a_small_brand_may_move_up_to_three(self):
        self.assertIsNone(C.held_reason([{"brand": "s"}] * 3, {"s": 10}))
        self.assertIsNotNone(C.held_reason([{"brand": "s"}] * 4, {"s": 10}))


class AutoMove(unittest.TestCase):
    def setUp(self):
        self.products = [product(i) for i in range(400)]
        self.brands = [{"id": "lg", "category": "wellness"}]

    def test_only_clear_flags_move_with_their_photo_key(self):
        a, b = self.products[:2]
        new, held = C.plan_moves([flag(a), flag(b, tier="borderline")], self.products, {}, self.brands, FakeBC)
        self.assertIsNone(held)
        self.assertEqual([(m["id"], m["from"], m["to"], m["photo"]) for m in new],
                         [(a["id"], "wellness", "garden", C.vkey(a))])

    def test_hand_pins_are_never_moved(self):
        a = self.products[0]
        brands = [{"id": "lg", "category": "wellness", "product_categories": {"p0": "wellness"},
                   "pinned_handles": ["p0"]}]
        self.assertEqual(C.plan_moves([flag(a)], self.products, {}, brands, FakeBC)[0], [])
        moves = {a["id"]: {"to": "garden", "subs": [], "photo": C.vkey(a)}}
        self.assertEqual(C.apply_moves(self.products, moves, brands, FakeBC), 0)
        self.assertEqual(a["category"], "wellness")

    def test_stored_moves_reapply_until_the_photo_changes(self):
        a, b = self.products[:2]
        moves = {a["id"]: {"to": "garden", "subs": ["plants-seeds"], "photo": C.vkey(a)},
                 b["id"]: {"to": "garden", "subs": [], "photo": "stale"}}
        self.assertEqual(C.apply_moves(self.products, moves, self.brands, FakeBC), 1)
        self.assertEqual((a["category"], a["subs"], b["category"]), ("garden", ["plants-seeds"], "wellness"))

    def test_too_many_at_one_brand_are_held(self):
        flags = [flag(p) for p in self.products[:9]]
        new, held = C.plan_moves(flags, self.products, {}, self.brands, FakeBC)
        self.assertEqual(len(new), 9)
        self.assertIn("lg (9 of 400)", held)

    def test_jev_must_side_with_the_photo_before_a_move(self):
        a, b, c = self.products[:3]
        a["title"], b["title"], c["title"] = "Fern", "Fern print tee", "Hoya"
        planned = C.plan_moves([flag(a), flag(b), flag(c)], self.products, {}, self.brands, FakeBC)[0]
        import search_gaps as sg
        said = {a["title"]: 0.9, b["title"]: 0.2}
        jev = sg.Jev({}, ask=lambda kind, state, q: said[state["product"]] if state["product"] in said else 1 / 0)
        ok, no, unknown = C.confirm_moves(planned, self.products, {"garden": "Garden & Outdoor"}, jev)
        self.assertEqual([[m["id"] for m in x] for x in (ok, no, unknown)], [[a["id"]], [b["id"]], [c["id"]]])

    def test_no_jev_key_means_no_moves(self):
        planned = C.plan_moves([flag(self.products[0])], self.products, {}, self.brands, FakeBC)[0]
        import search_gaps as sg
        jev = sg.Jev({})
        jev.available = False
        self.assertEqual(C.confirm_moves(planned, self.products, {}, jev), ([], [], planned))

    def test_every_move_is_logged(self):
        import csv
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            path = pathlib.Path(d) / "moves.csv"
            C.log_moves([{"id": "lg-1", "brand": "lg", "title": "Fern", "from": "wellness", "to": "garden",
                          "subs": ["plants-seeds"]}], "moved", path)
            C.log_moves([{"id": "lg-2", "brand": "lg", "title": "Hoya", "from": "wellness", "to": "garden"}],
                        "held", path)
            rows = list(csv.DictReader(open(path)))
        self.assertEqual([(r["id"], r["status"], r["subs"]) for r in rows],
                         [("lg-1", "moved", "plants-seeds"), ("lg-2", "held", "")])

    def test_the_photo_key_matches_the_builds(self):
        import department_rules as dr
        self.assertEqual(C.vkey(self.products[0]), dr.photo_key(self.products[0]))


try:
    import torch  # noqa: F401
except ImportError:
    torch = None


@unittest.skipIf(C.np is None or torch is None, "torch is in the ML venv only")
class Probe(unittest.TestCase):
    def test_a_misfiled_product_is_outvoted_by_its_lookalikes(self):
        np = C.np
        rng = np.random.default_rng(0)
        centers = np.eye(2, 8, dtype=np.float32) * 3
        y = np.array([0] * 60 + [1] * 60)
        V = centers[y] + rng.normal(0, 0.3, (120, 8)).astype(np.float32)
        y[5] = 1  # a department-0 photo filed under department 1
        fold = np.arange(120) % 5
        Q = C.probe_probs(V, y, 2, fold, steps=200)
        self.assertGreater(Q[5, 0], 0.9)
        self.assertGreater((Q.argmax(1) == np.array([0] * 60 + [1] * 60)).mean(), 0.95)


if __name__ == "__main__":
    unittest.main()
