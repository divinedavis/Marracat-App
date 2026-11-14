import { test } from "node:test";
import assert from "node:assert/strict";
import { mergeCarts, toServer, fromServer, sameCart } from "../src/cartSync.js";

const line = (id, v, q) => ({ key: `${id}:${v}`, id, variant: v, quantity: q });

test("a cart started signed out merges into the account's, keeping the larger quantity", () => {
  const merged = mergeCarts([line("a", "1", 1), line("b", "2", 3)], [line("a", "1", 2), line("c", "3", 1)]);
  assert.deepEqual(merged.map((l) => [l.key, l.quantity]), [["a:1", 2], ["b:2", 3], ["c:3", 1]]);
});

test("web lines and account lines convert both ways", () => {
  const web = [line("p1", "123456789012345", 2)];
  assert.deepEqual(toServer(web), [{ productID: "p1", variantID: "123456789012345", quantity: 2 }]);
  assert.ok(sameCart(fromServer(toServer(web)), web));
});
