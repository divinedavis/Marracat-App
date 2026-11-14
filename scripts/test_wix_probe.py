"""scripts/wix_probe.py: the parts that need no live Wix store."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import wix_probe as wp  # noqa: E402

V = "5d6d0ab2-0b1c-4d8e-9f00-111122223333"


class WixProbeTests(unittest.TestCase):
    def test_pick_v1_skips_sold_out_and_hidden_variants(self):
        products = [{"id": "p1", "variants": [{"id": "a", "stock": {"inStock": False}},
                                              {"id": "b", "variant": {"visible": False}}]},
                    {"id": "p2", "variants": [{"id": "c", "stock": {"inStock": True}}]}]
        p, v = wp.pick_v1(products)
        self.assertEqual((p["id"], v["id"]), ("p2", "c"))
        self.assertIsNone(wp.pick_v1([{"id": "p", "variants": []}]))

    def test_line_item_is_a_wix_stores_catalog_reference(self):
        item = wp.line_item({"productId": "prod-1", "variantId": V})
        self.assertEqual(item["catalogReference"]["appId"], wp.STORES_APP_ID)
        self.assertEqual(item["catalogReference"]["options"], {"variantId": V})
        self.assertEqual(item["quantity"], 1)
        # A product without managed variants has the all-zero default variant: no option sent.
        plain = wp.line_item({"productId": "prod-1", "variantId": "00000000-0000-0000-0000-000000000000"})
        self.assertNotIn("options", plain["catalogReference"])


if __name__ == "__main__":
    unittest.main()
