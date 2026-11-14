import contextlib
import io
import json
import os
import sqlite3
import tempfile
import unittest

import split_server_catalog as split

FULL = dict(
    generated_at="2026-10-02T00:00:00Z", brands=[dict(id="b", name="B")], categories=[dict(id="bags")],
    products=[
        dict(id="one", brand="b", title="Tote", category="bags", price=10, available=True,
             description="A long description " * 50, images=["a.jpg", "b.jpg", "c.jpg"],
             variants=[dict(id=1, title="Default", price=10, available=True)],
             url="https://b.example/products/tote", tags=["x"], metal="ethical", scent=True, safer=True,
             food=True, baby=True, fiber="organic", fabric=True, lab=True, pet=True, material="veg",
             home="certified"),
        dict(id="two", brand="b", title="Tee", category="clothing", price=20, available=True,
             description="Soft", images=["t.jpg"],
             variants=[dict(id=2, title="S"), dict(id=3, title="M")], url="https://b.example/products/tee"),
    ])


class Split(unittest.TestCase):
    def run_split(self):
        d = tempfile.mkdtemp()
        src = os.path.join(d, "catalog.json")
        with open(src, "w") as f:
            json.dump(FULL, f)
        with contextlib.redirect_stdout(io.StringIO()):
            split.main(src, d)
        return d

    def test_the_slim_file_keeps_what_the_server_reads_in_memory(self):
        d = self.run_split()
        slim = json.load(open(os.path.join(d, "catalog-slim.json")))
        self.assertEqual(slim["generated_at"], FULL["generated_at"])
        self.assertEqual(slim["brands"], FULL["brands"])
        one, two = slim["products"]
        self.assertNotIn("description", one)
        self.assertEqual(one["metal"], "ethical", "the True Metal badge reaches the website")
        self.assertNotIn("metal", two)
        self.assertTrue(one["scent"] and one["safer"], "Clear Scent and Safer Clean reach the website")
        self.assertNotIn("scent", two)
        self.assertTrue(one["food"] and one["baby"], "Clean Food and Baby Safe reach the website")
        self.assertNotIn("food", two)
        self.assertEqual((one["fiber"], one["fabric"]), ("organic", True), "Natural Fiber and Safe Fabric reach the website")
        self.assertNotIn("fiber", two)
        self.assertEqual((one["lab"], one["pet"], one["material"], one["home"]), (True, True, "veg", "certified"),
                         "Lab Verified, Pet Safe, True Material and Natural Home reach the website")
        self.assertNotIn("material", two)
        self.assertEqual(one["images"], ["a.jpg"])
        self.assertEqual(one["url"], "https://b.example/products/tote", "restock checks read the store URL")
        self.assertEqual(len(one["variants"]), 1, "a single variant still adds straight to the cart")
        self.assertEqual(two["variants"], [], "options come from the details row")

    def test_tile_hero_attrs_and_colourways_reach_the_website(self):
        d = tempfile.mkdtemp()
        src = os.path.join(d, "catalog.json")
        full = json.loads(json.dumps(FULL))
        full["products"][0].update(tile_image=2, hero_image=1, attrs={"free": ["vegan"]},
                                   group="b:12345678", color="Black", swatch="#1b1b1b")
        with open(src, "w") as f:
            json.dump(full, f)
        with contextlib.redirect_stdout(io.StringIO()):
            split.main(src, d)
        one, two = json.load(open(os.path.join(d, "catalog-slim.json")))["products"]
        self.assertEqual(one["images"], ["c.jpg"], "the grid photo is the tile")
        self.assertEqual(one["hero"], "b.jpg")
        self.assertEqual((one["attrs"], one["group"], one["color"], one["swatch"]),
                         ({"free": ["vegan"]}, "b:12345678", "Black", "#1b1b1b"))
        self.assertNotIn("tile_image", one)
        self.assertNotIn("hero", two)
        self.assertEqual(two["images"], ["t.jpg"])

    def test_every_product_is_kept_in_full_in_the_details_db(self):
        d = self.run_split()
        db = sqlite3.connect(os.path.join(d, "product-details.sqlite"))
        rows = dict(db.execute("SELECT id, data FROM product_details"))
        self.assertEqual(set(rows), {"one", "two"})
        self.assertEqual(json.loads(rows["two"]), FULL["products"][1])
        self.assertEqual(db.execute("SELECT value FROM meta WHERE key='generated_at'").fetchone()[0], FULL["generated_at"])


if __name__ == "__main__":
    unittest.main()
