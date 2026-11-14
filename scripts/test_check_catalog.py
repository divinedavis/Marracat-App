import contextlib
import io
import json
import os
import tempfile
import unittest
from unittest import mock

import check_catalog as cc

GOOD = dict(generated_at="2026-10-01T00:00:00Z", brands=[dict(id="b")],
            products=[dict(id=str(i), brand="b") for i in range(100)])


class Problems(unittest.TestCase):
    def test_a_good_catalog_has_none(self):
        self.assertEqual(cc.problems(GOOD), [])

    def test_empty_or_wrong_shapes_are_refused(self):
        self.assertIn("no products", cc.problems(dict(GOOD, products=[])))
        self.assertIn("no brands", cc.problems(dict(GOOD, brands=[])))
        self.assertIn("no generated_at", cc.problems(dict(GOOD, generated_at="")))
        self.assertEqual(cc.problems([1, 2]), ["not a JSON object"])

    def test_products_need_an_id_and_brand(self):
        self.assertEqual(cc.problems(dict(GOOD, products=[dict(id="1")])), ["1 products without an id or brand"])


class Shrink(unittest.TestCase):
    def test_small_drop_passes(self):
        self.assertIsNone(cc.shrink_problem(91, 100, allow=False))

    def test_big_drop_fails_unless_allowed(self):
        self.assertIn("lost 11%", cc.shrink_problem(89, 100, allow=False))
        self.assertIsNone(cc.shrink_problem(89, 100, allow=True))

    def test_nothing_live_yet_passes(self):
        self.assertIsNone(cc.shrink_problem(5, None, allow=False))

    def test_growth_passes(self):
        self.assertIsNone(cc.shrink_problem(500, 100, allow=False))


class Check(unittest.TestCase):
    def setUp(self):
        quiet = contextlib.redirect_stdout(io.StringIO())
        quiet.__enter__()
        self.addCleanup(quiet.__exit__, None, None, None)
        fd, self.path = tempfile.mkstemp(suffix=".json")
        os.close(fd)

    def tearDown(self):
        os.unlink(self.path)

    def write(self, text):
        with open(self.path, "w") as fh:
            fh.write(text)

    def test_invalid_json_is_refused_before_any_fetch(self):
        self.write("{not json")
        with mock.patch.object(cc, "live_products") as live:
            self.assertFalse(cc.check(self.path, "https://example.invalid/c.json"))
            live.assert_not_called()

    def test_shrunk_catalog_is_refused(self):
        self.write(json.dumps(GOOD))
        with mock.patch.object(cc, "live_products", return_value=200), mock.patch.dict(os.environ, {"ALLOW_SHRINK": ""}):
            self.assertFalse(cc.check(self.path, "u"))
        with mock.patch.object(cc, "live_products", return_value=105):
            self.assertTrue(cc.check(self.path, "u"))


if __name__ == "__main__":
    unittest.main()
