import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
  websiteProduct,
  websiteBrand,
  websiteCopy,
  websiteLabel,
  websiteListed,
} from "../server/website-copy.js";
const catalog = JSON.parse(
  readFileSync(
    new URL("../../Marracat/Resources/catalog.json", import.meta.url),
  ),
);
test("website descriptions omit ownership claims without broadening superlatives", () => {
  assert.equal(
    websiteCopy("Made of cotton. The largest independent company. Wash cold."),
    "Made of cotton. Wash cold.",
  );
  assert.equal(
    websiteCopy("Black color. 100% cotton."),
    "Black color. 100% cotton.",
  );
});
test("website catalog removes the requested wording and preserves purchase data", () => {
  const original = JSON.stringify(catalog);
  const products = catalog.products.map(websiteProduct),
    brands = catalog.brands.map(websiteBrand);
  const mention = /\bindependent/i;
  const visible = {
    brands: brands.map((b) => ({ name: b.name, tagline: b.tagline })),
    products: products.map((p) => ({
      title: p.title,
      description: p.description,
      product_type: p.product_type,
      tags: p.tags,
      variants: p.variants.map((v) => v.title),
    })),
  };
  assert.ok(!mention.test(JSON.stringify(visible)));
  assert.ok(products.filter(websiteListed).every((p) => p.title.trim().length > 0));
  for (let i = 0; i < products.length; i++) {
    const p = products[i],
      source = catalog.products[i];
    assert.equal(p.id, source.id);
    assert.equal(p.price, source.price);
    assert.equal(p.url, source.url);
    assert.deepEqual(
      p.variants.map((v) => [v.id, v.price, v.available]),
      source.variants.map((v) => [v.id, v.price, v.available]),
    );
  }
  assert.equal(JSON.stringify(catalog), original);
});
test("a product titled only with the omitted wording is left off the website", () => {
  const book = { id: "b1", title: "Independent", product_type: null, tags: [], variants: [], description: null };
  assert.equal(websiteListed(websiteProduct(book)), false);
  assert.equal(websiteListed(websiteProduct({ ...book, title: "Independent Candle" })), true);
  assert.equal(websiteProduct({ ...book, title: "Independent Candle" }).title, "Candle");
});
test("the deploy checks' Python copy of the label rule matches this one", () => {
  // scripts/website_listed.py counts what the site will serve; a drift
  // between the two failed marracat.com's 2026-11-11 data publish.
  const titles = ["Independent", "Independent Candle", "Soap — independent", "Black Cotton Tee",
    "INDEPENDENT: Tote", "independent brand", "Owned by independent founders"];
  const out = execFileSync("python3", [fileURLToPath(new URL("../../scripts/website_listed.py", import.meta.url)), "--labels"],
    { input: JSON.stringify(titles) });
  assert.deepEqual(JSON.parse(out), titles.map(websiteLabel));
});
test("a product the omission doesn't touch is passed through, not copied", () => {
  // ~194k copies held the server near its heap limit on start-up (2026-11-11).
  const plain = { id: "p", title: "Shea Butter", product_type: "Body", description: "Rich.", tags: ["shea"],
    variants: [{ id: 1, title: "8 oz", price: 10, available: true }] };
  assert.equal(websiteProduct(plain), plain);
  const tagged = { ...plain, tags: ["independent", "shea"] };
  assert.notEqual(websiteProduct(tagged), tagged);
  assert.deepEqual(websiteProduct(tagged).tags, ["shea"]);
  assert.deepEqual(tagged.tags, ["independent", "shea"], "the catalog's own record is left as it was");
  const spaced = { ...plain, title: "Shea  Butter" };
  assert.equal(websiteProduct(spaced).title, "Shea Butter", "titles are still tidied as before");
});
