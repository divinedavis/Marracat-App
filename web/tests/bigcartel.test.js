import { test } from "node:test";
import assert from "node:assert/strict";
import { parseLines, bigCartelHost } from "../server/bigcartel.js";
import { checkoutURL } from "../src/catalog.js";

const products = { "r-1": { brand: "r", title: "Egypt", variants: [{ id: 301038729, title: "Silver" }] } };
const lookup = (id) => products[id];

test("Big Cartel hand-off: only this brand's products and real options", () => {
  assert.deepEqual(parseLines("r-1:301038729:2", "r", lookup), [{ title: "Egypt", option: "Silver", id: "301038729", qty: 2 }]);
  assert.equal(parseLines("r-1:999:1", "r", lookup), null, "unknown option");
  assert.equal(parseLines("r-1:301038729:1", "other", lookup), null, "another brand's product");
  assert.equal(parseLines("r-1:301038729:0", "r", lookup), null);
  assert.equal(parseLines("<script>:1:1", "r", lookup), null);
  assert.equal(bigCartelHost({ domain: "therenaebrandd.bigcartel.com" }), "therenaebrandd.bigcartel.com");
  assert.equal(bigCartelHost({ domain: "shoprenae.com", bigcartel: "therenaebrandd" }), "therenaebrandd.bigcartel.com");
});

test("the website's checkout link for a Big Cartel brand goes through /go/bigcartel", () => {
  const brand = { id: "r", shopify: true, platform: "bigcartel", domain: "therenaebrandd.bigcartel.com" };
  const lines = [{ product: { id: "r-1", available: true }, variant: { id: 301038729, available: true }, quantity: 2 }];
  assert.equal(checkoutURL(brand, lines), "/go/bigcartel?brand=r&items=r-1%3A301038729%3A2");
});
