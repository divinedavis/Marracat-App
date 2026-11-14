"""scripts/website_listed.py: what marracat.com lists, so deploy checks expect it."""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import website_listed as wl  # noqa: E402


class WebsiteListedTests(unittest.TestCase):
    def test_labels(self):
        self.assertEqual(wl.website_label("Independent"), "")
        self.assertEqual(wl.website_label("Independent Candle"), "Candle")
        self.assertEqual(wl.website_label("Soap — independent"), "Soap")
        self.assertEqual(wl.website_label("Black Cotton Tee"), "Black Cotton Tee")
        self.assertIsNone(wl.website_label(None))

    def test_expectations_leave_out_title_less_products(self):
        catalog = {"generated_at": "2026-11-11T23:00:00Z", "products": [
            {"id": "book", "title": "Independent"}, {"id": "a", "title": "Shea Butter"}, {"id": "b", "title": "Tee"}]}
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(catalog, f)
        self.assertEqual(wl.expectations(f.name), ("2026-11-11T23:00:00Z", 2, "a"))
        Path(f.name).unlink()


if __name__ == "__main__":
    unittest.main()
