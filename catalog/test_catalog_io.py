"""catalog_io.write_catalog (2026-10-18): streamed instead of one json.dumps
string, through a temporary file. Same bytes as before; a failed write leaves
the old file whole."""
import json
import tempfile
import unittest
from pathlib import Path

from catalog_io import write_catalog

CATALOG = {"generated_at": "2026-10-18T00:00:00Z",
           "products": [{"id": "p1", "title": "Crème brûlée candle 🕯️", "price": 18.5, "subs": ["candles"]},
                        {"id": "p2", "title": "Tee", "available": False, "images": []}]}


class WriteCatalogTest(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.path = self.dir / "catalog.json"

    def test_bytes_match_the_old_json_dumps_write(self):
        write_catalog(self.path, CATALOG)
        self.assertEqual(self.path.read_text(), json.dumps(CATALOG, separators=(",", ":"), ensure_ascii=False))
        self.assertEqual(list(self.dir.iterdir()), [self.path], "no temporary file left behind")

    def test_a_failed_write_keeps_the_previous_catalog(self):
        write_catalog(self.path, CATALOG)
        with self.assertRaises(TypeError):
            write_catalog(self.path, {"products": [object()]})
        self.assertEqual(json.loads(self.path.read_text()), CATALOG)
        self.assertEqual(list(self.dir.iterdir()), [self.path], "the half-written file is removed")


if __name__ == "__main__":
    unittest.main()


from catalog_io import products_of_brands  # noqa: E402


def big_catalog(brands=40, each=30):
    return {"generated_at": "2026-11-12T00:00:00Z",
            "categories": [{"id": "home", "name": "Home"}],
            "brands": [{"id": f"b{i}", "name": f"Brand {i}", "domain": f"b{i}.example"} for i in range(brands)],
            "products": [{"id": f"b{i}-{n}", "brand": f"b{i}", "title": "Crème %d 🕯️ \"quoted\" ]} [" % n,
                          "description": "x" * (n * 37 % 900), "subs": ["candles"],
                          "variants": [{"id": n * 10 + v, "title": f"v{v}", "price": 9.5} for v in range(n % 4 + 1)]}
                         for i in range(brands) for n in range(each)]}


class ProductsOfBrandsTest(unittest.TestCase):
    """The previous catalog is read a product at a time (2026-11-12: loading
    all of it beside the new one ran the refresh server out of memory)."""

    def setUp(self):
        self.path = Path(tempfile.mkdtemp()) / "catalog.json"
        self.catalog = big_catalog()
        write_catalog(self.path, self.catalog)

    def expect(self, wanted):
        return {b: [p for p in self.catalog["products"] if p["brand"] == b] for b in wanted}

    def test_gives_the_wanted_brands_products_and_every_brand_seen(self):
        kept, seen = products_of_brands(self.path, {"b3", "b17", "nobody"})
        self.assertEqual(kept, self.expect(["b3", "b17"]))
        self.assertEqual(seen, {f"b{i}" for i in range(40)})

    def test_same_answer_when_products_straddle_every_read(self):
        for chunk in (7, 64, 1000):
            kept, seen = products_of_brands(self.path, {"b0", "b39"}, chunk=chunk)
            self.assertEqual(kept, self.expect(["b0", "b39"]), f"chunk {chunk}")
            self.assertEqual(len(seen), 40)

    def test_reads_a_catalog_written_with_spaces_and_newlines(self):
        self.path.write_text(json.dumps(self.catalog, indent=1, ensure_ascii=False))
        kept, seen = products_of_brands(self.path, {"b5"}, chunk=500)
        self.assertEqual(kept, self.expect(["b5"]))
        self.assertEqual(len(seen), 40)

    def test_wanting_nothing_still_says_which_brands_had_products(self):
        kept, seen = products_of_brands(self.path, set())
        self.assertEqual(kept, {})
        self.assertEqual(len(seen), 40)

    def test_a_catalog_cut_short_gives_what_was_whole(self):
        text = self.path.read_text()
        self.path.write_text(text[:len(text) // 2])
        kept, seen = products_of_brands(self.path, {"b1", "b38"}, chunk=300)
        self.assertEqual(kept, self.expect(["b1"]))
        self.assertNotIn("b38", seen)

    def test_a_product_that_never_ends_stops_the_read_instead_of_filling_memory(self):
        text = self.path.read_text()
        cut = text.index('{"id":"b20-0"')
        self.path.write_text(text[:cut] + '{"id":"broken","brand":"b20","title":"' + "x" * 5000)
        kept, seen = products_of_brands(self.path, {"b2"}, chunk=100, longest=3000)
        self.assertEqual(kept, self.expect(["b2"]))
        self.assertEqual(len(seen), 20)

    def test_a_file_with_no_products_gives_nothing(self):
        self.path.write_text('{"generated_at":"x","brands":[]}')
        self.assertEqual(products_of_brands(self.path, {"b1"}), ({}, set()))
