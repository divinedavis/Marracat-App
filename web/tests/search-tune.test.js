import { test } from "node:test";
import assert from "node:assert/strict";
import { alternatives, interests, namesBrand, leadsWithBrand, offDepartments, prefersGuess, saysOwnership, tokens } from "../src/search-words.js";
import { filterProducts, personalPicks, searchWithGuesses, setSearchCategories } from "../src/catalog.js";
import { readRecent, rememberSearch, rememberView } from "../src/recent.js";

// Owner, 2026-11-03, after a returning shopper's searches: lead with a brand
// when its name is searched, synonyms, a charm or two for someone looking at
// charms, guesses instead of "no matches", and the "independent" notice.

const brands = [
  { id: "fraiche-studios", name: "Fraîche Studios" },
  { id: "kami", name: "Kami Cosmetics" },
  { id: "xennial", name: "The Xennial Co" },
  { id: "okra", name: "O'kra" },
  { id: "garden", name: "Garden Goods" },
  { id: "charms", name: "Charm House" },
  { id: "craft", name: "Crafty" },
];
const p = (id, brand, title, category = "accessories", subs = [], available = true) => ({ id, brand, title, category, subs, available, tags: [] });
const products = [
  p("k1", "kami", "Creme Fraiche Lipstick", "makeup"),
  p("k2", "kami", "Creme Fraiche Gloss", "makeup"),
  p("f1", "fraiche-studios", "Camo Tote", "bags"),
  p("f2", "fraiche-studios", "Matching Charm", "bags"),
  p("x1", "xennial", "Olive Tote", "bags"),
  p("o1", "okra", "Glow Serum", "skincare"),
  p("g1", "garden", "Red Okra Seeds", "garden"),
  p("g2", "garden", "Okra Plant", "garden"),
  p("c1", "charms", "Cherry Bag Charm", "accessories", ["keychains"]),
  p("c2", "charms", "Strawberry Keychain", "accessories", ["keychains"]),
  p("c3", "charms", "Dunk Charm", "accessories", ["keychains"]),
  p("c4", "charms", "Leather Key Ring", "accessories", ["keychains"]),
  p("c5", "charms", "Fruit Basket Print", "home"),
  p("t1", "craft", "Fuzzy Fruit Bag Charm Felting Kit", "crafts"),
];
setSearchCategories([]);
const ids = (q) => filterProducts(products, brands, { q, synonyms: {} }).map((x) => x.id);

test("a brand's name leads with that brand, an everyday word does not", () => {
  assert.deepEqual(ids("fraiche").slice(0, 2).sort(), ["f1", "f2"]);
  assert.equal(namesBrand(tokens("xennial co"), "The Xennial Co").full, true);
  // "okra" names O'kra's one product, but two others say okra: no lead.
  assert.deepEqual(ids("okra").slice(0, 2).sort(), ["g1", "g2"]);
  assert.equal(leadsWithBrand(namesBrand(["okra"], "O'kra"), 1, 2), false);
  assert.equal(leadsWithBrand(namesBrand(["xennial"], "The Xennial Co"), 1, 5), false, "a partial name outnumbered elsewhere does not lead");
  assert.equal(leadsWithBrand(namesBrand(["fraiche", "studios"], "Fraîche Studios"), 1, 5), true, "a whole two-word name always leads");
});

test("synonyms: keychain and key ring, charm and keychain beside other words, fruit names", () => {
  assert.ok(ids("keychain").includes("c4"), "a key ring is a keychain");
  assert.deepEqual(ids("dunk keychain"), ["c3"]);
  const fruit = ids("bag charm fruit");
  assert.ok(fruit.includes("c1"), "a cherry charm is a fruit charm");
  assert.equal(fruit[0], "t1", "the title that says fruit still ranks first");
  assert.ok(!ids("fruit").includes("c1"), "fruit alone stays fruit");
});

test("the 'independent' notice reads every spelling, and only that", () => {
  for (const q of ["independent", "independent bag charms", "independent", "independent candles"]) assert.ok(saysOwnership(tokens(q)), q);
  for (const q of ["black bag", "owned by me", "black"]) assert.ok(!saysOwnership(tokens(q)), q);
});

test("guesses instead of no matches: a close brand, a looser respelling, single words", () => {
  const vocab = () => [["xennial", 3], ["tote", 4], ["charm", 5]];
  const count = (q) => filterProducts(products, brands, { q, synonyms: {} }).length;
  assert.deepEqual(alternatives("xenial", brands.map((b) => b.name), vocab, count), ["The Xennial Co"]);
  assert.ok(prefersGuess("xennail", "The Xennial Co", "nail"));
  assert.ok(!prefersGuess("hodie", "Hodi", "hoodie"), "a tie keeps the respelling");
  const g = searchWithGuesses(products, brands, { q: "xennail co", synonyms: {} });
  assert.equal(g.showing, "The Xennial Co");
  assert.deepEqual(g.result.map((x) => x.id), ["x1"]);
  assert.deepEqual(searchWithGuesses(products, brands, { q: "fraiche", synonyms: {} }).guesses, []);
});

test("picked for you: a charm for 'fruit' after looking at charms, never from other departments", () => {
  const byId = new Map(products.map((x) => [x.id, x]));
  const aisle = (x) => (x.subs[0] === "keychains" ? "Keychains & Charms" : null);
  const picks = personalPicks(products, brands, "fruit", ["fruit", "bag charm"], [], aisle, byId);
  assert.equal(picks.phrase, "bag charm");
  assert.ok(picks.products.every((x) => x.category === "accessories"), "no felting kit");
  assert.ok(picks.products.length >= 1 && picks.products.length <= 2);
  const viewed = personalPicks(products, brands, "fruit", ["fruit"], ["c3"], aisle, byId);
  assert.equal(viewed.searched, false);
  assert.ok(viewed.products.every((x) => x.subs.includes("keychains")));
  assert.equal(personalPicks(products, brands, "fruit", ["fruit"], [], aisle, byId), null, "nothing looked at, nothing picked");
  assert.equal(personalPicks(products, brands, "independent", ["bag charm"], [], aisle, byId), null);
  assert.equal(personalPicks(products, brands, "big red fruit bowl", ["bag charm"], [], aisle, byId), null, "three words or more");
  assert.deepEqual(interests("fruit", ["fruit salad", "Independent", "the co", "charm"], []).map((i) => i.phrase), ["charm"]);
});

test("recent history stays in this browser, newest first, capped", () => {
  const store = new Map();
  const storage = { getItem: (k) => store.get(k) ?? null, setItem: (k, v) => store.set(k, v) };
  rememberSearch("Bag charm", storage);
  rememberSearch("fruit", storage);
  rememberSearch("bag CHARM", storage);
  rememberView("c1", storage);
  rememberView("c1", storage);
  for (let i = 0; i < 40; i++) rememberSearch(`q${i}`, storage);
  const r = readRecent(storage);
  assert.equal(r.searches.length, 30);
  assert.equal(r.searches[0], "q39");
  assert.deepEqual(r.viewed, ["c1"]);
  store.set("marracat-recent", "{not json");
  assert.deepEqual(readRecent(storage), { searches: [], viewed: [] });
});

test("a department a focused search barely touches goes below the rest", () => {
  const many = [];
  for (let i = 0; i < 18; i++) many.push(p(`b${i}`, "charms", `Gem Bag Charm ${i}`, "bags"));
  many.push(p("kit", "craft", "Fuzzy Bag Charms Felting Kit", "crafts"));
  many.push(p("ear", "charms", "Bag Charm Earrings", "jewelry"));
  const got = filterProducts(many, brands, { q: "bag charms", synonyms: {} }).map((x) => x.id);
  assert.equal(got.at(-1), "kit", "the craft kit drops below every real charm");
  assert.ok(got.indexOf("ear") < got.indexOf("kit"), "only departments that merely mention things drop");
  // A broad word spread across departments moves nothing.
  assert.equal(offDepartments(new Map([["clothing", 30], ["home", 30], ["garden", 30], ["crafts", 2]]), 92, 1).size, 0);
  // One word: under 1 in 20. Two or more: under 1 in 8.
  assert.deepEqual([...offDepartments(new Map([["bags", 17], ["crafts", 2]]), 19, 3)], ["crafts"]);
  assert.equal(offDepartments(new Map([["bags", 17], ["crafts", 2]]), 19, 1).size, 0);
  assert.equal(offDepartments(new Map([["bags", 9]]), 9, 2).size, 0, "fewer than 10 matches: no change");
});
