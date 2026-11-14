import { test } from "node:test";
import assert from "node:assert/strict";
import { setCatalog, querySource } from "../server/catalog.js";
import { filterProducts } from "../src/catalog.js";
import { attrOptions, ATTR_FILTERS, attrApplies, attributeRows, departmentOf } from "../src/attrs.js";
import { collapseGroups, groupIndex, dotColor } from "../src/colorways.js";
import { queryString } from "../src/fast-query.js";

// Shopper filters, colourways and best photos (owner, 2026-10-10;
// catalog/attributes.py, colorways.py, photo_roles.py).
const product = (id, extra = {}) => ({
  id, brand: "b", title: id, category: "hair", price: 10, currency: "USD", images: [`https://x/${id}-0.jpg`, `https://x/${id}-1.jpg`, `https://x/${id}-2.jpg`],
  available: true, variants: [{ id: 1, title: "Default Title", price: 10, available: true }], tags: [], ...extra,
});
const brands = [{ id: "b", name: "B" }];

test("attribute filters keep only products whose brand says so", () => {
  const ps = [product("a", { attrs: { hair: ["4c", "coils"], free: ["vegan"] } }), product("b", { attrs: { hair: ["curls"] } }), product("c")];
  const ids = (o) => filterProducts(ps, brands, o).map((p) => p.id).sort();
  assert.deepEqual(ids({ hair: "4c" }), ["a"]);
  assert.deepEqual(ids({ hair: "curls" }), ["b"]);
  assert.deepEqual(ids({ free: "vegan", hair: "4c" }), ["a"]);
  assert.deepEqual(ids({ skin: "acne" }), []);
  assert.deepEqual(ids({}), ["a", "b", "c"]);
});

test("skincare filters: skin type, key ingredient, formulation, SPF, minis & sets", () => {
  const sk = (id, attrs) => product(id, { category: "skincare", attrs });
  const ps = [sk("serum", { skintype: ["oily"], ingredient: ["niacinamide"], form: ["serum"] }),
    sk("spf", { spf: ["high"], pack: ["mini"] }), sk("plain", {})];
  const ids = (o) => filterProducts(ps, brands, o).map((p) => p.id).sort();
  assert.deepEqual(ids({ skintype: "oily" }), ["serum"]);
  assert.deepEqual(ids({ ingredient: "niacinamide", form: "serum" }), ["serum"]);
  assert.deepEqual(ids({ spf: "high" }), ["spf"]);
  assert.deepEqual(ids({ pack: "mini" }), ["spf"]);
  assert.match(queryString({ skintype: "oily", spf: "high" }), /skintype=oily.*spf=high/);
});

test("each filter group shows only in its own department (owner, 2026-11-04)", () => {
  assert.ok(attrApplies("skintype", "oily", "skincare"));
  assert.ok(!attrApplies("skintype", "oily", "makeup"));
  assert.ok(!attrApplies("hair", "4c", "skincare"));
  assert.ok(attrApplies("free", "sulfate", "hair"));
  assert.ok(!attrApplies("free", "noncomedogenic", "hair"), "non-comedogenic is a skin preference");
  assert.equal(departmentOf("", [{ category: "skincare" }, { category: "skincare" }]), "skincare");
  assert.equal(departmentOf("", [{ category: "skincare" }, { category: "hair" }]), null);
  const mixed = [product("h", { attrs: { hair: ["4c"] } }), product("s", { category: "skincare", attrs: { skintype: ["dry"] } })];
  const none = { gender: "", hair: "", skin: "", skintype: "", ingredient: "", free: "", form: "", spf: "", pack: "" };
  assert.deepEqual(attributeRows({ category: "", products: mixed, active: none }), [], "a mixed search shows no department's filters");
  assert.deepEqual(attributeRows({ category: "skincare", products: mixed, active: none }).map((r) => r.f), ["skintype"]);
  assert.deepEqual(attributeRows({ category: "hair", products: mixed, active: none }).map((r) => r.f), ["hair"]);
});

test("Women / Men on clothing and shoes, across departments (owner, 2026-11-08)", () => {
  const c = (id, gender, category = "clothing") => product(id, { category, attrs: gender ? { gender } : undefined });
  const ps = [c("w", ["women"]), c("m", ["men"]), c("u", ["men", "women"]), c("x", null), c("bag", null, "bags")];
  const ids = (o) => filterProducts(ps, brands, o).map((p) => p.id).sort();
  assert.deepEqual(ids({ gender: "women" }), ["u", "w"], "unisex shows under Women");
  assert.deepEqual(ids({ gender: "men" }), ["m", "u"]);
  assert.deepEqual(ids({}), ["bag", "m", "u", "w", "x"]);
  const none = { gender: "", hair: "", skin: "", skintype: "", ingredient: "", free: "", form: "", spf: "", pack: "" };
  // A search spanning clothing and bags still offers Gender; department filters stay off.
  assert.deepEqual(attributeRows({ category: "", products: ps, active: none }).map((r) => [r.f, r.values]), [["gender", ["women", "men"]]]);
  assert.ok(attrApplies("gender", "women", null) && !attrApplies("gender", "kids", null));
  assert.equal(attrOptions(new URLSearchParams("gender=women")).gender, "women");
  assert.equal(attrOptions(new URLSearchParams("gender=other")).gender, "");
  assert.match(queryString({ gender: "men", q: "pants" }), /gender=men/);
});

test("attrOptions takes allow-listed values only", () => {
  const none = { gender: "", hair: "", skin: "", skintype: "", ingredient: "", free: "", form: "", spf: "", pack: "" };
  assert.deepEqual(attrOptions(new URLSearchParams("hair=4c&skin=nope&free=__proto__")), { ...none, hair: "4c" });
  assert.deepEqual(attrOptions({ free: "fragrance", ingredient: "niacinamide" }), { ...none, free: "fragrance", ingredient: "niacinamide" });
  for (const spec of Object.values(ATTR_FILTERS)) for (const label of Object.values(spec.values)) assert.ok(label.length < 30);
  assert.match(queryString({ hair: "4c", free: "vegan" }), /hair=4c.*free=vegan/);
});

test("one card per colourway, the first (in-stock) member as its face", () => {
  const ps = [product("x"), product("b1", { group: "b:1", color: "Black" }), product("y"), product("s1", { group: "b:1", color: "Sand" })];
  assert.deepEqual(collapseGroups(ps).map((p) => p.id), ["x", "b1", "y"]);
  assert.deepEqual(groupIndex(ps).get("b:1").map((p) => p.id), ["b1", "s1"]);
  assert.equal(dotColor({ swatch: "#1b1b1b" }), "#1b1b1b");
  assert.equal(dotColor({ swatch: "red;background:url(x)" }), null, "only a plain hex reaches a style");
});

// A date past any real catalog: setCatalog ignores one older than what is loaded.
test("the list projection shows the tile photo and carries the hero, attrs and colourway", () => {
  setCatalog({
    generated_at: "2099-01-01T00:00:00Z", brands, categories: [{ id: "hair", name: "Hair" }],
    products: [
      product("t", { tile_image: 2, hero_image: 1, attrs: { hair: ["4c"] }, group: "b:1", color: "Black", swatch: "#1b1b1b" }),
      product("plain"),
      // The deployed slim file: tile already first, hero as a URL.
      product("slim", { images: ["https://x/slim-tile.jpg"], hero: "https://x/slim-hero.jpg" }),
    ],
  });
  const [t, plain, slim] = querySource().products;
  assert.deepEqual(t.images, ["https://x/t-2.jpg"]);
  assert.equal(t.hero, "https://x/t-1.jpg");
  assert.deepEqual([t.attrs, t.group, t.color, t.swatch], [{ hair: ["4c"] }, "b:1", "Black", "#1b1b1b"]);
  assert.deepEqual(plain.images, ["https://x/plain-0.jpg"]);
  assert.equal(plain.hero, undefined);
  assert.equal(plain.attrs, undefined);
  assert.equal(plain.group, undefined);
  assert.deepEqual([slim.images, slim.hero], [["https://x/slim-tile.jpg"], "https://x/slim-hero.jpg"]);
});
