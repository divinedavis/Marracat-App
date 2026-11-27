import { test } from "node:test";
import assert from "node:assert/strict";
import express from "express";
import { querySource } from "../server/catalog.js";
import { queryOptions, runQuery, queryRoutes, buildHaystack, PAGE_MAX } from "../server/query.js";
import { buildWordIndex, filterProducts, relaxedSearch, searchCandidates, wordIndexBuilder, searchScorer } from "../src/catalog.js";
import { queryString, PAGE } from "../src/fast-query.js";
import { collapseGroups } from "../src/colorways.js";

// /api/query (2026-10-10): shop, brand, department and search pages draw from
// the server until the 9.6 MB full catalog lands, so the server's answer must
// be exactly what the page computes locally afterwards.
const { products, brands } = querySource();
const someBrand = products.find((p) => p.available).brand;
const someCategory = products.find((p) => p.subs?.length).category;
const someLeaf = products.find((p) => p.category === someCategory && p.subs?.length).subs[0];
const cases = [
  { q: "", sort: "featured" },
  { brand: someBrand, sort: "featured" },
  { q: "shea butter", sort: "low" },
  { category: someCategory, aisle: someLeaf, stock: true, sort: "high" },
  { category: someCategory, clean: true, sort: "new" },
  { q: "zzqx shea", sort: "featured" }, // relaxed
  { brand: someBrand, type: `${someCategory}:${someLeaf}`, sort: "featured" },
  { category: "hair", hair: "4c", sort: "featured" },
  { category: "skincare", free: "fragrance", skin: "acne", sort: "low" },
  { brand: "fear-of-god", sort: "featured" }, // colourways
];

test("the server's page is the storefront's own filter, in the same order", () => {
  for (const options of cases) {
    const local = filterProducts(products, brands, options);
    const relaxed = !local.length && options.q ? relaxedSearch(products, brands, options) : null;
    // One card per colourway (catalog/colorways.py).
    const want = collapseGroups(relaxed ? relaxed.result : local).map((p) => p.id);
    const got = runQuery(products, brands, queryOptions(Object.fromEntries(new URLSearchParams(queryString(options)))));
    assert.deepEqual(got.shown.map((p) => p.id), want, JSON.stringify(options));
    assert.equal(got.relaxedQuery, relaxed ? relaxed.q : null);
  }
});

test("the counts around the grid cover the whole result, not the page", () => {
  const options = { brand: someBrand, sort: "featured" };
  const got = runQuery(products, brands, options);
  const want = {};
  for (const p of filterProducts(products, brands, options))
    for (const leaf of p.subs || []) want[`${p.category}:${leaf}`] = (want[`${p.category}:${leaf}`] || 0) + 1;
  assert.deepEqual(got.typeCounts, want);
  const dept = runQuery(products, brands, { category: someCategory, sort: "featured" });
  const inDept = products.filter((p) => p.category === someCategory);
  assert.equal(Object.values(dept.brandCounts).reduce((a, b) => a + b, 0), inDept.length);
  assert.equal(dept.aisleCounts[someLeaf], inDept.filter((p) => (p.subs || []).includes(someLeaf)).length);
  assert.equal(dept.deptBrands.length, new Set(inDept.map((p) => p.brand)).size);
  assert.ok(dept.badges.every((b) => inDept.some((p) => p[b])));
});

test("query options are bounded and malformed ones refused", () => {
  assert.equal(queryOptions({ brand: "../etc" }), null);
  assert.equal(queryOptions({ category: "a b" }), null);
  assert.equal(queryOptions({ type: "clothing" }), null, "a type is department:leaf");
  assert.equal(queryOptions({ sort: "drop table" }), null);
  assert.equal(queryOptions({ country: "NG" }).country, "NG");
  assert.equal(queryOptions({}).country, "");
  assert.equal(queryOptions({ country: "Nigeria" }), null, "a country is a two-letter code");
  assert.equal(queryOptions({ country: "ng" }), null);
  assert.equal(queryOptions({ q: "x".repeat(5000) }).q.length, 200);
  assert.equal(queryOptions({ q: ["a", "b"] }).q, "", "repeated params are ignored, not joined");
  assert.equal(queryOptions({ clean: "1", stock: "yes" }).clean, true);
  assert.equal(queryOptions({ clean: "1", stock: "yes" }).stock, false);
  // Shopper filters take allow-listed values only.
  assert.equal(queryOptions({ hair: "4c" }).hair, "4c");
  assert.equal(queryOptions({}).skin, "");
  assert.equal(queryOptions({ hair: "4z" }), null);
  assert.equal(queryOptions({ free: "constructor" }), null);
  assert.equal(queryOptions({ skin: ["acne", "oily"] }).skin, "", "repeated params are ignored");
});

test("GET /api/query pages through the result and sends only card fields", async () => {
  const app = express();
  queryRoutes(app, querySource);
  const server = app.listen(0, "127.0.0.1"); await new Promise((r) => server.once("listening", r));
  const base = `http://127.0.0.1:${server.address().port}/api/query?`;
  try {
    const first = await (await fetch(base + queryString({ q: "", sort: "featured" }))).json();
    assert.equal(first.products.length, PAGE);
    assert.equal(first.total, collapseGroups(products).length);
    const next = await (await fetch(base + queryString({ q: "", sort: "featured" }, PAGE))).json();
    assert.equal(next.offset, PAGE);
    const want = collapseGroups(filterProducts(products, brands, {})).slice(0, PAGE * 2).map((p) => p.id);
    assert.deepEqual([...first.products, ...next.products].map((p) => p.id), want);
    // Nothing a card doesn't need; nothing /api/catalog doesn't already send.
    const listed = new Set(products.flatMap((p) => Object.keys(p)));
    for (const p of first.products) {
      assert.equal(p.tags, undefined);
      // members: a colourway's other colours, so its dots work from this page.
      for (const k of Object.keys(p)) assert.ok(listed.has(k) || k === "members", k);
      if (p.members) assert.ok(p.group && p.members.length > 1 && p.members.every((m) => m.group === p.group && !m.tags));
    }
    const fog = await (await fetch(base + queryString({ brand: "fear-of-god", sort: "featured" }))).json();
    assert.ok(fog.products.some((p) => p.members), "Fear of God's colourways carry their dots");
    const big = await (await fetch(base + "limit=100000")).json();
    assert.equal(big.products.length, PAGE_MAX);
    assert.equal((await fetch(base + "brand=%2E%2E%2Fx")).status, 400);
    assert.equal((await fetch(base + "offset=-5")).status, 200);
  } finally {
    server.close();
  }
});

test("a newer catalog replaces cached answers", async () => {
  const app = express();
  let source = { generated_at: "a", products: products.slice(0, 10), brands };
  queryRoutes(app, () => source);
  const server = app.listen(0, "127.0.0.1"); await new Promise((r) => server.once("listening", r));
  const url = `http://127.0.0.1:${server.address().port}/api/query?limit=120`;
  try {
    assert.equal((await (await fetch(url)).json()).total, collapseGroups(products.slice(0, 10)).length);
    source = { generated_at: "b", products: products.slice(0, 20), brands };
    assert.equal((await (await fetch(url)).json()).total, collapseGroups(products.slice(0, 20)).length);
  } finally {
    server.close();
  }
});

test("a long nonsense search can't hold the server: no word-dropping past 6 words", () => {
  const q = Array.from({ length: 20 }, (_, i) => `zq${i}x`).join(" ");
  const started = performance.now();
  const got = runQuery(products, brands, { q, sort: "featured" });
  assert.equal(got.shown.length, 0);
  assert.equal(got.relaxedQuery, null);
  assert.ok(performance.now() - started < 2000);
  // A short search with one stray word still drops it, as the storefront does.
  const stray = runQuery(products, brands, { q: "shea butter zzqq1", sort: "featured" });
  assert.equal(stray.relaxedQuery, "shea butter");
});

test("the colour filter: allow-listed, counted without itself, same as the page", () => {
  assert.equal(queryOptions({ color: "pink" }).color, "pink");
  assert.equal(queryOptions({ color: "chartreuse" }), null);
  assert.match(queryString({ q: "top", color: "pink" }), /color=pink/);
  const all = runQuery(products, brands, { q: "top", color: "" });
  const pink = runQuery(products, brands, { q: "top", color: "pink" });
  assert.ok(pink.shown.length > 0 && pink.shown.length < all.shown.length);
  // Picking Pink still offers the other colours, with the counts from before.
  assert.deepEqual(pink.colors, all.colors);
  assert.deepEqual(pink.shown, collapseGroups(filterProducts(products, brands, { q: "top", color: "pink" })));
});

// The word index (2026-11-10): searches score only the products that could
// match instead of all of them. It must change how long a search takes and
// nothing else.
const page = (r) => JSON.stringify([r.shown.map((p) => p.id), r.relaxedQuery, r.guesses, r.typeCounts, r.aisleCounts, r.brandCounts, r.deptBrands, r.badges, r.colors]);
const haystack = buildHaystack(products, brands);
const wordIndex = buildWordIndex(products, brands, haystack);

test("the word index answers every search exactly as scoring every product does", () => {
  const brandName = brands.find((b) => b.id === someBrand).name;
  const searches = [
    "shea butter", "candle", "candles", "dress", "dres", "butter", "sh", "a", "bag charm", "bag charms", "keyring",
    "red dress", "pink top", "gold hoop earrings for women", "mens hoodie", "independent hair oil", "vitamin d",
    "t-shirt", "Women's tops!", "crème", "12oz candle", brandName, brandName.split(" ")[0], `${brandName} oil`,
    "hair", "skin care", "durag", "fruit charm", "lipstik", "musthavejoy", "zzqx shea", "shea butter zzqq1", "zzqx", "---",
  ];
  for (const [i, q] of searches.entries())
    for (const extra of i % 5 ? [{}] : [{}, { category: someCategory }, { sort: "low", stock: true }]) {
      const options = { q, sort: "featured", ...extra };
      assert.equal(page(runQuery(products, brands, options, haystack, wordIndex)), page(runQuery(products, brands, options, haystack)), JSON.stringify(options));
    }
});

test("the index narrows a search to a few products and never drops one that matches", () => {
  for (const q of ["shea butter", "red dress", "keyring", "pink top women", "candl"]) {
    const narrowed = searchCandidates(wordIndex, searchScorer(q, brands).wordings);
    const found = filterProducts(products, brands, { q, haystack });
    assert.ok(found.length > 0, q);
    assert.ok(narrowed.length < products.length / 4, `${q}: ${narrowed.length} of ${products.length}`);
    const kept = new Set(narrowed);
    assert.ok(found.every((p) => kept.has(p)), q);
    // Catalog order, which the page's order is built on.
    const at = new Map(products.map((p, i) => [p, i]));
    assert.ok(narrowed.every((p, i) => i === 0 || at.get(narrowed[i - 1]) < at.get(p)), q);
  }
  // A lone colour reads as text; beside another word it can match by the
  // product's colour, so only the other word narrows.
  const dress = searchCandidates(wordIndex, searchScorer("dress", brands).wordings);
  assert.equal(searchCandidates(wordIndex, searchScorer("red dress", brands).wordings).length, dress.length);
});

test("an index for another list, or other brands, is not used", () => {
  const few = products.slice(0, 500);
  const want = filterProducts(few, brands, { q: "oil", haystack }).map((p) => p.id);
  assert.deepEqual(filterProducts(few, brands, { q: "oil", haystack, index: wordIndex }).map((p) => p.id), want);
  assert.deepEqual(filterProducts(products, [...brands], { q: "shea butter", haystack, index: wordIndex }).map((p) => p.id),
    filterProducts(products, [...brands], { q: "shea butter", haystack }).map((p) => p.id));
});

test("the index built a slice at a time is the one built at once, and unusable until finished", () => {
  const builder = wordIndexBuilder(products, brands, haystack);
  assert.equal(builder.step(1000), products.length <= 1000);
  assert.throws(() => builder.index(), /not finished/);
  while (!builder.step(50_000));
  const sliced = builder.index();
  assert.deepEqual(sliced.words, wordIndex.words);
  assert.deepEqual(sliced.starts, wordIndex.starts);
  assert.deepEqual(sliced.postings, wordIndex.postings);
});

test("the search text and index are made when the server starts, not by the first search", async () => {
  const app = express();
  let asked = 0;
  queryRoutes(app, () => { asked++; return querySource(); });
  assert.equal(asked, 0);
  await new Promise((done) => setTimeout(done, 50));
  assert.ok(asked >= 1, "the catalog is read without a request");
  // No catalog yet is no error: the first request prepares it instead.
  queryRoutes(express(), () => undefined);
  await new Promise((done) => setTimeout(done, 20));
});

test("/api/query answers the same before and after its index is ready", async () => {
  const app = express();
  queryRoutes(app, querySource);
  const server = app.listen(0, "127.0.0.1"); await new Promise((r) => server.once("listening", r));
  const get = async (q) => (await fetch(`http://127.0.0.1:${server.address().port}/api/query?limit=120&q=${encodeURIComponent(q)}`)).json();
  const ids = (q) => collapseGroups(runQuery(products, brands, { ...queryOptions({ q }) }).shown).slice(0, 120).map((p) => p.id);
  try {
    // The first request starts the index; this answer comes from the whole list.
    assert.deepEqual((await get("shea butter")).products.map((p) => p.id), ids("shea butter"));
    // Give the slices their turns, then ask something not yet cached.
    await new Promise((done) => setTimeout(done, 1500));
    const started = performance.now();
    assert.deepEqual((await get("body butter")).products.map((p) => p.id), ids("body butter"));
    assert.deepEqual((await get("zzqx shea")).relaxedQuery, "shea");
    // 3 s on the Mac; the 2-vCPU refresh droplet is about twice as slow and
    // missed 3 s on 2026-11-11, so it sets QUERY_BUDGET_MS (refresh_catalog.sh).
    const budget = Number(process.env.QUERY_BUDGET_MS) || 3000;
    const took = performance.now() - started;
    assert.ok(took < budget, `${Math.round(took)} ms, budget ${budget} ms`);
  } finally {
    server.close();
  }
});

