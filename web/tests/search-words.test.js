import { test } from "node:test";
import assert from "node:assert/strict";
import {
  fold, singular, startsWord, splitAudience, audienceFit, splitRunTogether, closestWord, respell, distance,
  dropOwnership, onlyFiller, saysOwnership, tokens,
} from "../src/search-words.js";
import { productColors, colorCounts, colorOption } from "../src/colors.js";
import { filterProducts, relaxedSearch } from "../src/catalog.js";

// Search robustness and the colour filter (owner, 2026-10-15), after a
// visitor's "musthavejoy" found nothing, "pink shirt women" found far less
// than "pink shirt", and five minutes of pink searches ended on earrings.

test("queries and titles fold accents and apostrophes the same way", () => {
  assert.equal(fold("Adèle Dejak"), "adele dejak");
  assert.equal(fold("Women’s"), "womens");
  assert.equal(fold("McDonald's"), "mcdonalds");
});

test("plurals meet their singular, including -es plurals", () => {
  assert.equal(singular("shirts"), "shirt");
  assert.equal(singular("dresses"), "dress");
  assert.equal(singular("watches"), "watch");
  assert.equal(singular("boxes"), "box");
  assert.equal(singular("dress"), "dress");
});

test("a word must start a word: no 'dress' in 'Hairdressings'", () => {
  assert.ok(startsWord("midi dress (pink)", "dress"));
  assert.ok(startsWord("cotton t-shirt", "shirt"));
  assert.ok(!startsWord("oils & hairdressings", "dress"));
  assert.ok(!startsWord("crewneck sweatshirt", "shirt"));
});

test("women/men are a preference, not a required word", () => {
  assert.deepEqual(splitAudience(["pink", "shirt", "womens"]), { words: ["pink", "shirt"], audience: "women" });
  assert.deepEqual(splitAudience(["mens", "shirt"]), { words: ["shirt"], audience: "men" });
  assert.deepEqual(splitAudience(["womens"]), { words: ["womens"], audience: "" });
  assert.equal(audienceFit("pink shirt", "women"), 0);
  assert.equal(audienceFit("womens pink shirt", "women"), 1);
  assert.equal(audienceFit("mens pink shirt", "women"), -1);
  assert.equal(audienceFit("unisex pink shirt", "women"), 1);
  assert.equal(audienceFit("womens pink shirt", "men"), -1);
});

test("run-together and misspelled words are respelled from the catalog's words", () => {
  const vocab = new Map([["must", 40], ["have", 90], ["joy", 30], ["hoodie", 500], ["hood", 20], ["ban", 3], ["bangs", 4]]);
  assert.equal(splitRunTogether("musthavejoy", vocab), "must have joy");
  assert.equal(splitRunTogether("bangsi", vocab), null, "no two-letter pieces");
  assert.equal(closestWord("hodie", vocab), "hoodie");
  assert.equal(closestWord("zzzz", vocab), null);
  assert.equal(respell("musthavejoy", vocab), "must have joy");
  assert.equal(respell("must have joy", vocab), null, "nothing to change");
  assert.equal(distance("hodie", "hoodie"), 1);
  assert.equal(distance("teh", "the"), 1, "a swap is one edit");
});

const p = (title, extra = {}) => ({ id: title, brand: "b", title, category: "clothing", price: 20, available: true, tags: [], ...extra });

test("a product's colours come from its colourway, variants and title", () => {
  assert.deepEqual([...productColors(p("Classic Tee", { variants: [{ title: "Blush / M" }, { title: "Navy / L" }] }))].sort(), ["blue", "pink"]);
  assert.deepEqual([...productColors(p("Oversized Hoodie", { color: "Vintage Black" }))], ["black"]);
  assert.deepEqual([...productColors(p("Exotic Bloom | Metallic Pink Earrings", { category: "jewelry" }))], ["pink"]);
  assert.deepEqual([...productColors(p("Rose Gold Hoops", { category: "jewelry" }))], ["gold"]);
  // Who it's for, not its colour; and no colours on food or scents.
  assert.deepEqual([...productColors(p("Black TV Moms Sweatshirt"))], []);
  assert.deepEqual([...productColors(p("Brown Skin Girl Tee"))], []);
  assert.deepEqual([...productColors(p("Shea Butter", { category: "skincare", variants: [{ title: "Lavender" }] }))], []);
  assert.deepEqual([...productColors(p("Orange Juice", { category: "grocery" }))], []);
  assert.deepEqual(colorCounts([p("Pink Top"), p("Pink Skirt"), p("Black Top")]), { black: 1, pink: 2 });
  assert.equal(colorOption("pink"), "pink");
  assert.equal(colorOption("<script>"), "");
});

test("the search page: colour words, the colour filter, women and respelling", () => {
  const brands = [{ id: "b", name: "Must Have Joy" }, { id: "c", name: "Other" }];
  const products = [
    p("Classic Top", { variants: [{ title: "Pink / S" }] }),
    p("Blush Satin Top"),
    p("Black Top"),
    p("Mens Pink Top"),
    p("Womens Pink Top"),
    p("Pink Growth Oil", { category: "hair", tags: ["Oils & Hairdressings"] }),
    p("Midi Dress", { variants: [{ title: "Pink" }] }),
    p("Knit Tote", { brand: "c" }),
  ];
  const titles = (o) => filterProducts(products, brands, o).map((x) => x.title);
  // "pink" finds a Pink variant and a Blush title; the title that says it leads.
  assert.deepEqual(titles({ q: "pink top" }).sort(), ["Blush Satin Top", "Classic Top", "Mens Pink Top", "Womens Pink Top"]);
  assert.equal(titles({ q: "pink top women" })[0], "Womens Pink Top");
  assert.ok(!titles({ q: "pink top women" }).includes("Mens Pink Top"));
  assert.ok(!titles({ q: "pink dress" }).includes("Pink Growth Oil"));
  assert.deepEqual(titles({ q: "top", color: "pink" }).sort(), ["Blush Satin Top", "Classic Top", "Mens Pink Top", "Womens Pink Top"]);
  assert.deepEqual(titles({ q: "dresses" }), ["Midi Dress"]);
  // "musthavejoy" is the brand Must Have Joy run together, answered with its
  // own products, as the app's relaxedSearch answers it (2026-10-31).
  const relaxed = relaxedSearch(products, brands, { q: "musthavejoy" });
  assert.equal(relaxed.q, "Must Have Joy");
  assert.ok(relaxed.result.every((x) => x.brand === "b"));
});

test("respelling stays cheap on junk: long words aren't split or corrected", () => {
  const vocab = new Map([["must", 40], ["have", 90], ["joy", 30]]);
  const junk = "musthavejoy".repeat(10);
  const t = Date.now();
  assert.equal(splitRunTogether(junk, vocab), null);
  assert.equal(closestWord("a".repeat(25), vocab), null);
  assert.ok(Date.now() - t < 50);
});

// Owner, 2026-11-01: October's searches that found nothing were "independent
// bag charms" (then only black-coloured charms), "xennial co" (then 6,627
// products for "co") and "bag charm 3d". The app does the same
// (SearchRobustnessTests).
test("'independent' is who every brand is, not a word a product must hold", () => {
  assert.deepEqual(dropOwnership(["black", "owned", "bag", "charms"]), ["bag", "charms"]);
  assert.deepEqual(dropOwnership(["independent", "hair", "oil"]), ["hair", "oil"]);
  assert.deepEqual(dropOwnership(["black", "own", "business", "tote"]), ["business", "tote"]);
  assert.deepEqual(dropOwnership(["black", "owned"]), ["black", "owned"], "alone it stays");
  assert.deepEqual(dropOwnership(["black", "bag", "charm"]), ["black", "bag", "charm"], "a colour is still a colour");
  const brands = [{ id: "b", name: "B" }];
  const products = [
    p("Black Bag Charm", { category: "bags" }),
    p("Pink Bag Charm", { category: "bags" }),
    p("Canvas Tote", { category: "bags" }),
    p("Minding My Independent Business Tote", { category: "bags" }),
  ];
  const titles = (q) => filterProducts(products, brands, { q }).map((x) => x.title);
  assert.deepEqual(titles("independent bag charms").sort(), ["Black Bag Charm", "Pink Bag Charm"]);
  assert.deepEqual(titles("independent business tote"), ["Minding My Independent Business Tote"]);
  assert.deepEqual(titles("independent tote").sort(), ["Canvas Tote", "Minding My Independent Business Tote"]);
  assert.deepEqual(titles("independent tote")[0], titles("tote")[0]);
  const both = [...products, p("Business Tote")];
  assert.deepEqual(filterProducts(both, brands, { q: "independent business tote" }).map((x) => x.title),
    ["Minding My Independent Business Tote", "Business Tote"],
    "the title that says what was typed goes first");
  assert.ok(titles("independent").includes("Minding My Independent Business Tote"));
  assert.equal(relaxedSearch(products, brands, { q: "independent xyzzy" }), null, "not relaxed to the phrase alone");
});

test("a brand we don't carry isn't relaxed to 'co' or split off one product's word", () => {
  assert.ok(onlyFiller(["co"]));
  assert.ok(onlyFiller(["the", "shop"]));
  assert.ok(!onlyFiller(["bag", "co"]));
  assert.equal(splitRunTogether("xennial", new Map([["xen", 2], ["nial", 1]])), null, "'nial' is on one product");
  assert.equal(splitRunTogether("xennial", new Map([["xen", 2], ["nial", 2]])), "xen nial");
  const brands = [{ id: "b", name: "Pecandy Co" }];
  const products = [p("Gift Box Co-Branded"), p("Bag Charm"), p("Bag Charm Keychain")];
  assert.equal(relaxedSearch(products, brands, { q: "xennial co" }), null);
  // A word nothing has still drops when a real one is left.
  assert.equal(relaxedSearch(products, brands, { q: "bag charm 3d" }).q, "bag charm");
});

// Owner, 2026-11-08: the "independent" card shows whatever words come before
// or after it, and for its near spellings. As SearchRobustnessTests in the app.
test("the independent card shows for any words around it", () => {
  for (const q of ["independent", "independent brands", "independent bracelets", "bracelets independent",
    "best independent hair care for kids", "independent", "independent skincare", "independent candles",
    "independent tees", "independent gifts", "Independent Jewelry"]) {
    assert.ok(saysOwnership(tokens(q)), q);
  }
  for (const q of ["black bracelets", "black dress", "owned", "black", "blackberry owned"]) {
    assert.ok(!saysOwnership(tokens(q)), q);
  }
  assert.deepEqual(dropOwnership(["blk", "owned", "tees"]), ["tees"]);
  assert.deepEqual(dropOwnership(["candles", "black", "ownd"]), ["candles"]);
});
