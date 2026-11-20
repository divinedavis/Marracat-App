import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createSearchIndex, liteIndex, serverSuggestions, suggest, suggestQuery } from "../src/search-suggestions.js";
import { filterProducts } from "../src/catalog.js";
import { websiteProduct, websiteBrand } from "../server/website-copy.js";
const catalog = JSON.parse(
  readFileSync(
    new URL("../../Marracat/Resources/catalog.json", import.meta.url),
  ),
);
const products = catalog.products.map(websiteProduct),
  brands = catalog.brands.map(websiteBrand);
const index = createSearchIndex(products, brands, catalog.categories);
test("laundry suggestions use real terms and match the full search result count", () => {
  const results = suggest(index, "laundr");
  assert.ok(
    results.items.some(
      (x) => x.kind === "Search" && /laundry detergent/i.test(x.label),
    ),
  );
  assert.ok(
    results.items.some(
      (x) => x.id.startsWith("product:") && x.image && Number.isFinite(x.price),
    ),
  );
  assert.equal(
    results.count,
    filterProducts(products, brands, { q: "laundr" }).length,
  );
  assert.equal(
    new Set(results.items.map((x) => x.id)).size,
    results.items.length,
  );
  assert.ok(results.items.length <= 10);
  assert.ok(!results.items.some((x) => x.label === "ecohome-laundry"));
  assert.ok(results.categories.some((c) => c.id === "household"));
});
test("brand-only and category searches open the intended destinations", () => {
  const brand = suggest(index, "TELFAR").items.find(
    (x) => x.id === "brand:telfar",
  );
  assert.equal(brand.to, "/shop?brand=telfar");
  const category = suggest(index, "skincare").items.find(
    (x) => x.id === "category:skincare",
  );
  assert.equal(category.to, "/shop?category=skincare");
});
test("empty and unmatched input do not invent suggestions", () => {
  assert.deepEqual(suggest(index, "  "), {
    items: [],
    categories: [],
    count: 0,
  });
  assert.equal(suggest(index, "zzzznonexistentitemqqq").items.length, 0);
  assert.doesNotThrow(() => suggest(index, "[.*+? <script>"));
  const q = "laundry detergent";
  for (const item of suggest(index, q).items.filter((x) => x.kind === "Search"))
    assert.ok(filterProducts(products, brands, { q: item.label }).length > 0);
});

// --- Sentence finishing, as in the app ---------------------------------
import { completions } from "../src/search-suggestions.js";
const full = createSearchIndex(products, brands, catalog.categories, catalog.subcategories);
test("typing a phrase finishes it from real product titles", () => {
  const labels = suggest(full, "sea moss").items.map((x) => x.label.toLowerCase());
  assert.ok(labels.filter((l) => l.startsWith("sea moss ")).length >= 3, labels.join(" | "));
  const half = suggest(full, "lip gl").items.map((x) => x.label.toLowerCase());
  assert.ok(half.includes("lip gloss"), half.join(" | "));
});
test("finishes end cleanly and a whole typed word leads", () => {
  for (const q of ["shea butter", "candle", "hoodie", "wig"]) {
    const list = completions(full, q);
    assert.ok(list.length, q);
    for (const f of list) {
      const last = f.text.split(" ").pop();
      assert.ok(!["and", "for", "with", "the", "of", "in", "by", "&"].includes(last), f.text);
    }
    assert.ok(list[0].exact, `${q} led with ${list[0].text}`);
  }
});
test("aisles are suggested and open the aisle", () => {
  const aisle = suggest(full, "shampoo").items.find((x) => x.kind === "Aisle");
  assert.ok(aisle, "no aisle suggestion for shampoo");
  assert.match(aisle.to, /category=hair&aisle=shampoo/);
  const dept = suggest(full, "bag").items.find((x) => x.kind === "Department");
  assert.ok(dept, "the Bags department must still be offered for 'bag'");
});
test("short common prefixes stay fast", () => {
  suggest(full, "zz");
  let worst = ["", 0];
  for (const q of ["s", "sh", "b", "bo", "c", "ca", "t", "th", "m", "ma", "p", "pr", "la", "de", "co", "bl"]) {
    // Best of three: the budget is about the code, and one timing on a Mac
    // that other sessions are loading measures the scheduler instead.
    let took = Infinity;
    for (let i = 0; i < 3; i++) {
      const t0 = performance.now();
      suggest(full, q);
      took = Math.min(took, performance.now() - t0);
    }
    if (took > worst[1]) worst = [q, took];
  }
  // 400 ms on the owner's Mac; the refresh droplet's slower CPU sets
  // SUGGEST_BUDGET_MS (scripts/refresh_catalog.sh).
  const budget = Number(process.env.SUGGEST_BUDGET_MS) || 400;
  assert.ok(worst[1] < budget, `'${worst[0]}' took ${worst[1].toFixed(0)}ms (budget ${budget}ms)`);
});
test("a brand typed without its spaces is suggested (owner, 2026-10-31: 'fearofgod' found nothing)", () => {
  const items = suggest(full, "fearofgod").items;
  assert.ok(items.some((x) => x.id === "brand:fear-of-god"), items.map((x) => x.label).join(" | "));
});
test("the dropdown's product cards are the search page's first results, and its count the page's", () => {
  for (const q of ["shea butter", "hoodie", "vitamin d", "durag women", "marge", "laundr"]) {
    const page = filterProducts(products, brands, { q }).map((p) => p.id);
    const s = suggest(full, q);
    const cards = s.items.filter((x) => x.id.startsWith("product:")).map((x) => x.id.slice("product:".length));
    assert.deepEqual(cards, page.slice(0, cards.length), q);
    assert.equal(s.count, page.length, q);
  }
});

test("while the catalog loads, the panel offers brands, aisles and the server's first products (owner, 2026-11-19)", () => {
  const lite = liteIndex(brands, catalog.categories); // as the index above is built
  // Before the server answers: the brand the words name, as the full index offers it.
  const early = serverSuggestions(lite, "fear of god", null);
  const full = suggest(index, "fear of god");
  const brandsOf = (r) => r.items.filter((x) => x.kind === "Brand").map((x) => x.to);
  if (brandsOf(full).length) assert.deepEqual(brandsOf(early), brandsOf(full));
  assert.equal(early.count, 0);
  // Its departments match the full index's too.
  const dept = (r) => r.items.filter((x) => x.kind === "Department" || x.kind === "Aisle").map((x) => x.id);
  assert.deepEqual(dept(serverSuggestions(lite, "laundr", null)), dept(suggest(index, "laundr")));
  // The server's products follow, as product rows that open the product.
  const found = { total: 2, products: products.slice(0, 2) };
  const answered = serverSuggestions(lite, "fear of god", found);
  const rows = answered.items.filter((x) => x.id.startsWith("product:"));
  assert.deepEqual(rows.map((x) => x.to), found.products.map((p) => "/product?id=" + encodeURIComponent(p.id)));
  assert.ok(answered.items.length <= 10);
  assert.deepEqual(serverSuggestions(lite, "   ", found).items, []);
  assert.equal(suggestQuery(" fear of god "), "/api/query?q=fear+of+god&limit=4");
});
