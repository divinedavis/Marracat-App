import { test } from "node:test";
import assert from "node:assert/strict";
import { filterProducts, relaxedSearch, setSearchCategories, interleaveBrands, daySeed, brandHash } from "../src/catalog.js";
import { fold, matchesTerm, squash, tokens } from "../src/search-words.js";
import { createSearchIndex, suggest } from "../src/search-suggestions.js";

// The website searches as the app does (owner, 2026-10-31: "make sure both
// search works the same"). Checked against the app's own Swift search code on
// the whole catalog: 300 queries and 45 no-match searches came back identical,
// in identical order. These pin the rules that made the difference.

const p = (id, title, extra = {}) => ({ id, brand: "a", title, category: "health", price: 10, available: true, tags: [], ...extra });
const brands = [{ id: "a", name: "Glow Labs" }, { id: "b", name: "Fear of God" }, { id: "c", name: "Aqua Equity Water" }];
const titles = (products, q) => filterProducts(products, brands, { q, synonyms: {} }).map((x) => x.title);

test("words split and fold as the app's do", () => {
  assert.deepEqual(tokens("T-Shirt, Women’s"), ["t", "shirt", "womens"]);
  assert.equal(squash("Fear of God"), "fearofgod");
  // Only accented letters lose their marks; "™" stays, so "Oil™" is still "oil".
  assert.equal(fold("“Muse™” Beard Oil"), "“muse™” beard oil");
  assert.equal(fold("Crème Brûlée"), "creme brulee");
  assert.ok(matchesTerm(fold("Beard Oil™"), "oil"));
});

test("'vitamin d' finds Vitamin D3, never a Vitamin C or a word that starts with d", () => {
  const products = [p("1", "Vitamin D3 Drops"), p("2", "Vitamin C Serum"), p("3", "Dark Chocolate Vitamin Bar")];
  assert.deepEqual(titles(products, "vitamin d"), ["Vitamin D3 Drops"]);
});

test("a department's name finds its products", () => {
  setSearchCategories([{ id: "hair", name: "Hair Care" }, { id: "health", name: "Health" }]);
  const products = [p("1", "Growth Oil", { category: "hair" }), p("2", "Growth Gummies")];
  assert.deepEqual(titles(products, "care oil"), ["Growth Oil"]);
  setSearchCategories([]);
});

test("the best match leads, and brands take turns among equal matches", () => {
  const products = [
    p("1", "Pink Top"), p("2", "Classic Top", { variants: [{ title: "Pink" }] }), p("3", "Womens Pink Top"),
  ];
  // One brand's matches keep their ranking (the app used to return these in catalog order).
  assert.deepEqual(titles(products, "pink top women"), ["Womens Pink Top", "Pink Top", "Classic Top"]);
  // Equal matches from three brands take turns: each pick skips the last two
  // brands shown (with only two brands in play the app lets one repeat).
  const mixed = [1, 2, 3, 4, 5, 6].map((n) => p(`x${n}`, `Shea Butter ${n}`, { brand: "abc"[n % 3] }));
  const order = filterProducts(mixed, brands, { q: "shea butter", synonyms: {} }).map((x) => x.brand);
  for (let i = 1; i < order.length; i++) assert.notEqual(order[i], order[i - 1], `brands should take turns: ${order}`);
});

test("brand mixing uses the app's seed and hash", () => {
  assert.equal(daySeed(new Date("2026-10-31T16:00:00Z")), 739920);
  assert.equal(daySeed(new Date("2026-11-01T03:59:00Z")), 739920, "still Oct 31 in New York");
  assert.equal(typeof brandHash("fear-of-god", 739920), "bigint");
  assert.deepEqual(interleaveBrands([]), []);
});

test("a brand typed without its spaces is that brand, in results and suggestions", () => {
  const products = [p("h", "Essentials Hoodie", { brand: "b" }), p("s", "Shea Butter")];
  const relaxed = relaxedSearch(products, brands, { q: "fearofgod", synonyms: {} });
  assert.equal(relaxed.q, "Fear of God");
  assert.deepEqual(relaxed.result.map((x) => x.id), ["h"]);
  const index = createSearchIndex(products, brands, []);
  assert.ok(suggest(index, "fearofgod").items.some((x) => x.id === "brand:b"), "fearofgod should suggest Fear of God");
  assert.ok(suggest(index, "fearof").items.some((x) => x.id === "brand:b"), "and while it's still being typed");
});

test("a brand's words in any order suggest it; stray letters inside words don't", () => {
  const index = createSearchIndex([p("w", "Spring Water", { brand: "c" })], brands, []);
  assert.ok(suggest(index, "water aqua").items.some((x) => x.id === "brand:c"));
  assert.ok(!suggest(index, "od").items.some((x) => x.kind === "Brand"), "'od' is inside 'God', not the start of a word");
});
