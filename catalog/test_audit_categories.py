"""The category ship gate (ship.sh: audit_categories.py --max-risky 30)."""
import contextlib
import io
import json
import pathlib
import tempfile
import unittest
from unittest import mock

import audit_categories as ac
import build_catalog as bc

BRANDS = [dict(id="mixed", category="skincare"), dict(id="focused", category="skincare")]


def product(pid, brand, title, category, product_type="", tags=()):
    return dict(id=pid, brand=brand, title=title, category=category, product_type=product_type, tags=list(tags))


# "mixed" sells across three departments, so its default is only a guess.
SPREAD = [product("m1", "mixed", "Body Lotion", "skincare", "Lotion"),
          product("m2", "mixed", "Crew Neck T-Shirt", "clothing", "T-Shirt"),
          product("m3", "mixed", "Soy Candle", "home", "Candle")]


class Audit(unittest.TestCase):
    def test_nothing_matched_is_risky_only_at_a_brand_spanning_departments(self):
        odd = product("m4", "mixed", "Zqxv", "skincare")
        lone = product("f1", "focused", "Zqxv", "skincare")
        found = ac.audit(SPREAD + [odd, lone], BRANDS, verdicts={})
        self.assertIn("m4", {p["id"] for p in found["fallback"]})
        self.assertNotIn("f1", {p["id"] for g in found.values() for p in g})

    def test_a_confident_jev_verdict_for_this_exact_text_settles_it(self):
        odd = product("m4", "mixed", "Zqxv", "skincare")
        sure = {"m4": dict(confidence=0.95, choice="skincare", seen=bc.jev_key(odd))}
        found = ac.audit(SPREAD + [odd], BRANDS, verdicts=sure)
        self.assertEqual([p["id"] for p in found["jev-settled"]], ["m4"])
        self.assertNotIn("m4", {p["id"] for p in found["fallback"]})
        # An edited title, a low confidence or another department reopens it.
        for v in (dict(sure["m4"], seen="stale"), dict(sure["m4"], confidence=0.5), dict(sure["m4"], choice="home")):
            found = ac.audit(SPREAD + [odd], BRANDS, verdicts={"m4": v})
            self.assertIn("m4", {p["id"] for p in found["fallback"]}, v)

    def test_products_of_unknown_brands_are_skipped(self):
        found = ac.audit([product("x", "gone", "Zqxv", "skincare")], BRANDS, verdicts={})
        self.assertEqual(sum(len(g) for g in found.values()), 0)


class Gate(unittest.TestCase):
    def run_gate(self, products, limit):
        with tempfile.TemporaryDirectory() as d:
            cat, brands = pathlib.Path(d, "catalog.json"), pathlib.Path(d, "brands.json")
            cat.write_text(json.dumps(dict(products=products, categories=[dict(id="skincare", name="Skincare")])))
            brands.write_text(json.dumps(BRANDS))
            out, err = io.StringIO(), io.StringIO()
            with mock.patch.object(ac, "CATALOG", cat), mock.patch.object(ac, "BRANDS", brands), \
                 mock.patch.object(ac, "load_verdicts", lambda: {}), \
                 mock.patch("sys.argv", ["audit_categories.py", "--max-risky", str(limit)]), \
                 contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                return ac.main(), err.getvalue()

    def test_over_the_limit_fails_the_ship_and_under_it_passes(self):
        risky = SPREAD + [product(f"m{i}", "mixed", "Zqxv", "skincare") for i in range(4, 10)]
        flagged = len({p["id"] for g in ac.audit(risky, BRANDS, verdicts={}).values() for p in g})
        pct = flagged * 100 / len(risky)
        self.assertGreater(pct, 30)
        code, err = self.run_gate(risky, 30)
        self.assertEqual(code, 1)
        self.assertIn("over the 30.0% the build allows", err)
        self.assertEqual(self.run_gate(risky, 100)[0], 0)


if __name__ == "__main__":
    unittest.main()
