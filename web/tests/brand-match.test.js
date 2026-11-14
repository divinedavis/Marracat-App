import { test } from "node:test";
import assert from "node:assert/strict";
import { brandScore, rankBrands, fold } from "../src/brand-match.js";

const brands = [
  "Brown Girl Jane", "Telfar", "E & E Essentials", "Café Mocha Beauty", "The Honey Pot Company",
  "Pattern Beauty", "Brother Vellies", "Denim Tears", "SIA Collective", "Mielle Organics",
].map((name, i) => ({ id: String(i), name }));
const top = (q) => rankBrands(brands, q)[0]?.name;

test("fold drops accents, case, punctuation and spells out &", () => {
  assert.equal(fold("Café  & Co."), "cafe and co");
  assert.equal(fold("L’Oréal"), "loreal");
});
test("prefix, mid-name, spacing and acronym find the brand", () => {
  assert.equal(top("brown"), "Brown Girl Jane");
  assert.equal(top("girl jane"), "Brown Girl Jane");
  assert.equal(top("browngirl"), "Brown Girl Jane");
  assert.equal(top("bgj"), "Brown Girl Jane");
  assert.equal(top("BROWN GIRL JANE"), "Brown Girl Jane");
  assert.equal(top("honey pot"), "The Honey Pot Company");
  assert.equal(top("cafe"), "Café Mocha Beauty");
  assert.equal(top("e and e"), "E & E Essentials");
  assert.equal(top("e&e"), "E & E Essentials");
});
test("typos still find the brand", () => {
  assert.equal(top("brwon girl"), "Brown Girl Jane");
  assert.equal(top("telfr"), "Telfar");
  assert.equal(top("brother velies"), "Brother Vellies");
  assert.equal(top("meille"), "Mielle Organics");
  assert.equal(top("denim tares"), "Denim Tears");
});
test("a slip on a whole word ranks above one on the start of a longer word", () => {
  // Kemi Telford sorts first and "telfo" is one letter from "telfr" too.
  const withTelford = [{ id: "k", name: "Kemi Telford" }, ...brands];
  assert.equal(rankBrands(withTelford, "telfr")[0].name, "Telfar");
  assert.ok(rankBrands(withTelford, "telfr").some((b) => b.name === "Kemi Telford"), "still found");
});
test("exact and prefix names rank above looser matches", () => {
  const names = rankBrands(brands, "beauty").map((b) => b.name);
  assert.deepEqual(names.slice(0, 2).sort(), ["Café Mocha Beauty", "Pattern Beauty"]);
  assert.ok(brandScore("Telfar", "telfar") > brandScore("Telfar", "telf"));
});
test("nonsense matches nothing and empty keeps everything", () => {
  assert.equal(rankBrands(brands, "zzqqxx").length, 0);
  assert.equal(rankBrands(brands, "  ").length, brands.length);
  assert.equal(rankBrands(brands, "a").length <= brands.length, true);
});
