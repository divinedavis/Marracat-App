import { test } from "node:test";
import assert from "node:assert/strict";
import { unseenIn, brandFirst } from "../src/catalog.js";

// Owner, 2026-11-17: "Goes well with" repeated products from the rows above it.
test("goes well with skips products the rows above already show", () => {
  const p = (id) => ({ id });
  const complements = ["a", "b", "c", "d", "e"].map(p);
  const left = unseenIn(complements, [[p("b")], [p("d"), p("z")]]);
  assert.deepEqual(left.map((x) => x.id), ["a", "c", "e"]);
  assert.deepEqual(unseenIn(complements, []).length, 5);
});

test("goes well with leads with the product's own brand", () => {
  const items = [{ id: "1", brand: "x" }, { id: "2", brand: "fenty" }, { id: "3", brand: "y" }, { id: "4", brand: "fenty" }];
  assert.deepEqual(brandFirst(items, "fenty").map((p) => p.id), ["2", "4", "1", "3"]);
});
