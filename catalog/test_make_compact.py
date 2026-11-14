"""make_compact.py's binary step (2026-10-11): the app bundles its catalog in
binary form and Home's slice of it, written by the app's own Swift code, so no
launch parses the JSON. Compiles the tool once (cached in build/)."""
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import make_compact

MAGIC = (0x4D524331).to_bytes(4, "little")


def product(i, brand, available=True):
    return {"id": f"p{i}", "brand": brand, "title": f"Tee {i}", "category": "clothing", "url": f"https://x/{i}",
            "price": 10 + i, "available": available, "images": [f"https://x/{i}.jpg"], "compareAt": 20 if i % 2 else None}


def catalog():
    products = [product(i, "telfar" if i < 3 else f"b{i % 4}", available=i != 5) for i in range(12)]
    for p in products:
        if p["compareAt"] is None:
            del p["compareAt"]
    return {"generatedAt": "2026-10-11T00:00:00Z",
            "categories": [{"id": "clothing", "name": "Clothing", "symbol": "tshirt"}],
            "subcategories": [],
            "brands": [{"id": b, "name": b, "domain": f"{b}.com", "category": "clothing", "shopify": True}
                       for b in ["telfar", "b0", "b1", "b2", "b3"]],
            "products": products}


@unittest.skipUnless(shutil.which("xcrun"), "needs Xcode's swiftc")
class BinaryCatalog(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.dir)

    def test_writes_the_binary_and_the_home_slice(self):
        src = self.dir / "catalog-compact.json"
        src.write_text(json.dumps(catalog()))
        make_compact.write_binary(src, self.dir)
        full, home = (self.dir / "catalog.bin").read_bytes(), (self.dir / "catalog-home.bin").read_bytes()
        self.assertEqual(full[:4], MAGIC)
        self.assertEqual(home[:4], MAGIC)
        self.assertIn(b"\"generatedAt\":\"2026-10-11T00:00:00Z\"", full)

    def test_a_catalog_that_does_not_decode_stops_the_build(self):
        src = self.dir / "catalog-compact.json"
        src.write_text('{"generatedAt":"x","products":[{"id":1}]}')
        with self.assertRaises(subprocess.CalledProcessError):
            make_compact.write_binary(src, self.dir)
        self.assertFalse((self.dir / "catalog.bin").exists())


class NoBinary(unittest.TestCase):
    """--no-binary (the refresh droplet, 2026-10-12): JSON only, no Xcode."""

    def test_writes_the_json_and_skips_the_binary(self):
        d = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, d)
        full = catalog()
        full["generated_at"] = full.pop("generatedAt")
        (d / "catalog.json").write_text(json.dumps(full))
        with mock.patch.object(make_compact, "FULL", d / "catalog.json"), \
                mock.patch.object(make_compact, "COMPACT", d / "catalog-compact.json"), \
                mock.patch.object(make_compact, "write_binary") as wb:
            make_compact.main(["--no-binary"])
            wb.assert_not_called()
            make_compact.main([])
            wb.assert_called_once()
        self.assertEqual(len(json.loads((d / "catalog-compact.json").read_text())["products"]), 12)


if __name__ == "__main__":
    unittest.main()
