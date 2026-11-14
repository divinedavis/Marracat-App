"""catalog_delta.py: a delta applied to the version it was made from gives
exactly the new catalog's products, in order (2026-10-18)."""
import json, os, sys, unittest

sys.path.insert(0, os.path.dirname(__file__))
import catalog_delta as cd


def product(pid, price=10, brand="b", **extra):
    return {"id": pid, "brand": brand, "title": f"Item {pid}", "price": price, "available": True, **extra}


def catalog(products, date="2026-10-18T00:00:00Z", brands=None):
    return {"generated_at": date, "categories": [{"id": "bags", "name": "Bags"}], "subcategories": [],
            "brands": brands or [{"id": "b", "name": "B"}], "products": products}


class CatalogDeltaTests(unittest.TestCase):
    def roundtrip(self, old, new):
        base = cd.manifest(old, "a" * 16)
        delta = cd.make_delta(base, new, "b" * 16)
        got = cd.apply(old, json.loads(cd.dump(delta)))
        self.assertEqual(got, json.loads(cd.dump(new)))
        return delta

    def test_unchanged_catalog_is_one_run_and_no_products(self):
        ps = [product(str(i)) for i in range(50)]
        d = self.roundtrip(catalog(ps), catalog(ps, date="2026-10-19T00:00:00Z"))
        self.assertEqual(d["order"], [0, 50])
        self.assertEqual(d["products"], [])

    def test_changes_adds_removes_and_moves(self):
        old = [product(str(i)) for i in range(20)]
        new = [p for p in old if p["id"] not in ("3", "4")]          # removed
        new[5] = product(new[5]["id"], price=99)                      # changed in place
        new.insert(8, product("new-1"))                                # added
        new.append(new.pop(0))                                         # moved to the end
        d = self.roundtrip(catalog(old), catalog(new, brands=[{"id": "b", "name": "B2"}]))
        self.assertEqual(sorted(p["id"] for p in d["products"]), sorted([new[4]["id"], "new-1"]))

    def test_key_order_alone_is_not_a_change(self):
        a = product("1", tags=["x"])
        b = dict(reversed(list(a.items())))
        d = self.roundtrip(catalog([a]), catalog([b]))
        self.assertEqual(d["products"], [])

    def test_repeated_ids_keep_their_positions(self):
        old = [product("1"), product("2"), product("1", price=5)]
        new = [product("1", price=5), product("1"), product("2")]
        self.roundtrip(catalog(old), catalog(new))

    def test_generated_at_is_the_first_key(self):
        d = cd.make_delta(cd.manifest(catalog([product("1")]), "a" * 16), catalog([product("1")]), "b" * 16)
        self.assertTrue(cd.dump(d).startswith(b'{"generated_at":'))

    def test_apply_refuses_a_delta_for_another_base(self):
        old, new = catalog([product("1"), product("2")]), catalog([product("2"), product("3")])
        d = cd.make_delta(cd.manifest(old, "a" * 16), new, "b" * 16)
        with self.assertRaises(AssertionError):
            cd.apply(catalog([product("9")]), d)

    def test_fingerprints_are_16_hex(self):
        self.assertEqual(len(cd.fingerprint(b"x")), 16)
        self.assertEqual(cd.ids_digest(["a", "b"]), cd.ids_digest(iter(["a", "b"])))
        self.assertNotEqual(cd.ids_digest(["a", "b"]), cd.ids_digest(["b", "a"]))


if __name__ == "__main__":
    unittest.main()
