import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { homeProducts, HOME_FEED, HOME_FEATURED, HOME_HERO } from "../server/catalog.js";
import { websiteProduct } from "../server/website-copy.js";
import { filterProducts } from "../src/catalog.js";

// The home page draws from a small payload before the full catalog arrives,
// then swaps the full catalog in. If the two disagreed about what the first
// screen shows, products would jump around under the shopper.
const source = JSON.parse(readFileSync(new URL("../../Marracat/Resources/catalog.json", import.meta.url), "utf8"));
const compact = source.products.map(websiteProduct).map((p) => ({
  ...p, variants: p.variants.length === 1 ? p.variants : undefined,
}));
const subset = homeProducts(compact);

test("the home payload is a small fraction of the catalog", () => {
  assert.ok(subset.length < 200, `home carries ${subset.length} products`);
  assert.ok(subset.length >= HOME_FEED);
});

test("the home feed's first screen matches the full catalog's exactly", () => {
  const full = filterProducts(compact, source.brands, { stock: true }).slice(0, HOME_FEED).map((p) => p.id);
  const partial = filterProducts(subset, source.brands, { stock: true }).slice(0, HOME_FEED).map((p) => p.id);
  assert.deepEqual(partial, full);
});

test("every product the home page looks up is in the home payload", () => {
  const ids = new Set(subset.map((p) => p.id));
  const available = filterProducts(compact, source.brands, { stock: true });
  const hero = compact.find((p) => p.id === HOME_HERO);
  if (hero) assert.ok(ids.has(hero.id), "hero missing");
  for (const brand of HOME_FEATURED) {
    for (const found of [available.find((p) => p.brand === brand && p.images?.length), available.find((p) => p.brand === brand)])
      if (found) assert.ok(ids.has(found.id), `${brand} pick missing`);
  }
  for (const category of new Set(compact.map((p) => p.category))) {
    const found = available.find((p) => p.category === category && p.images?.length);
    if (found) assert.ok(ids.has(found.id), `${category} photo missing`);
  }
});
