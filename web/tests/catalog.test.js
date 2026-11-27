import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { filterProducts, countryChoices, countryName, relaxedSearch, checkoutURL, usesMarracatCart, safeURL, money, cartTotals, optionNoun } from "../src/catalog.js";
const catalog = JSON.parse(
  readFileSync(
    new URL("../../Marracat/Resources/catalog.json", import.meta.url),
  ),
);
test("all catalog brands are represented and search supports brand names", () => {
  const registry = JSON.parse(readFileSync(new URL("../../catalog/brands.json", import.meta.url)));
  const listed = new Set(catalog.brands.map((b) => b.id));
  // Every listed brand is registered, and every listed brand has something to
  // sell: a store that is locked, unpaid or has no public feed is left out of
  // the catalog rather than shown as an empty shelf, while staying registered
  // so it returns the day its store does.
  assert.ok([...listed].every((id) => registry.some((b) => b.id === id)));
  const withProducts = new Set(catalog.products.map((p) => p.brand));
  assert.deepEqual(listed, withProducts);
  const found = filterProducts(catalog.products, catalog.brands, {
    q: "Brown Girl Jane",
  });
  assert.ok(found.length > 0);
  // The brand's own products are what the search is for. A word-by-word match
  // across title, brand, type and tags will also catch the odd product from
  // elsewhere — at 100,000 products, "Brown Sugar Babe / Girl From Bahia"
  // carries all three words between its brand, title and tags — so this asks
  // that the brand dominates rather than that nothing else appears.
  const own = found.filter((p) => p.brand === "brown-girl-jane");
  assert.ok(own.length >= found.length * 0.9, `${own.length} of ${found.length} were the brand's own`);
});
test("the Clear Scent and Safer Clean filters keep only their badged products", () => {
  const products = [
    { id: "p", brand: "b", title: "Oud parfum", category: "fragrance", price: 80, available: true, scent: true },
    { id: "q", brand: "b", title: "Fragrance oil", category: "fragrance", price: 20, available: true },
    { id: "r", brand: "b", title: "Dish soap", category: "household", price: 9, available: true, safer: true },
  ];
  const brands = [{ id: "b", name: "B" }];
  assert.deepEqual(filterProducts(products, brands, { scent: true }).map((p) => p.id), ["p"]);
  assert.deepEqual(filterProducts(products, brands, { safer: true }).map((p) => p.id), ["r"]);
  assert.equal(filterProducts(products, brands, {}).length, 3, "off by default");
});

test("the Clean Food and Baby Safe filters keep only their badged products", () => {
  const products = [
    { id: "f", brand: "b", title: "Rooibos", category: "grocery", price: 12, available: true, food: true },
    { id: "g", brand: "b", title: "Candy", category: "grocery", price: 3, available: true },
    { id: "k", brand: "b", title: "Organic onesie", category: "baby", price: 24, available: true, baby: true },
  ];
  const brands = [{ id: "b", name: "B" }];
  assert.deepEqual(filterProducts(products, brands, { food: true }).map((p) => p.id), ["f"]);
  assert.deepEqual(filterProducts(products, brands, { baby: true }).map((p) => p.id), ["k"]);
  assert.equal(filterProducts(products, brands, {}).length, 3, "off by default");
});

test("the Natural Fiber and Safe Fabric filters keep only their badged garments, either fibre tier", () => {
  const products = [
    { id: "n", brand: "b", title: "Linen shirt", category: "clothing", price: 80, available: true, fiber: "natural", fabric: true },
    { id: "o", brand: "b", title: "Organic tee", category: "clothing", price: 30, available: true, fiber: "organic" },
    { id: "p", brand: "b", title: "Poly jacket", category: "clothing", price: 60, available: true },
  ];
  const brands = [{ id: "b", name: "B" }];
  assert.deepEqual(filterProducts(products, brands, { fiber: true }).map((p) => p.id), ["n", "o"]);
  assert.deepEqual(filterProducts(products, brands, { fabric: true }).map((p) => p.id), ["n"]);
  assert.equal(filterProducts(products, brands, {}).length, 3, "off by default");
});

test("the Lab Verified, Pet Safe, True Material and Natural Home filters keep only their badged products", () => {
  const products = [
    { id: "l", brand: "b", title: "D3 capsules", category: "wellness", price: 20, available: true, lab: true },
    { id: "p", brand: "b", title: "Liver treats", category: "pets", price: 12, available: true, pet: true },
    { id: "m", brand: "b", title: "Saddle bag", category: "bags", price: 200, available: true, material: "veg" },
    { id: "h", brand: "b", title: "Oak board", category: "home", price: 60, available: true, home: "certified" },
    { id: "n", brand: "b", title: "Plain mug", category: "home", price: 15, available: true },
  ];
  const brands = [{ id: "b", name: "B" }];
  assert.deepEqual(filterProducts(products, brands, { lab: true }).map((p) => p.id), ["l"]);
  assert.deepEqual(filterProducts(products, brands, { pet: true }).map((p) => p.id), ["p"]);
  assert.deepEqual(filterProducts(products, brands, { material: true }).map((p) => p.id), ["m"]);
  assert.deepEqual(filterProducts(products, brands, { home: true }).map((p) => p.id), ["h"]);
  assert.equal(filterProducts(products, brands, {}).length, 5, "off by default");
});

test("the Marracat True Metal filter keeps only badged jewelry, either tier", () => {
  const products = [
    { id: "a", brand: "b", title: "14k ring", category: "jewelry", price: 100, available: true, metal: "true" },
    { id: "c", brand: "b", title: "Lab grown studs", category: "jewelry", price: 90, available: true, metal: "ethical" },
    { id: "d", brand: "b", title: "Gold tone ring", category: "jewelry", price: 20, available: true },
  ];
  const brands = [{ id: "b", name: "B" }];
  assert.deepEqual(filterProducts(products, brands, { metal: true }).map((p) => p.id), ["a", "c"]);
  assert.equal(filterProducts(products, brands, {}).length, 3, "off by default");
});
test("real discounts and combined filters preserve prices and stock", () => {
  const found = filterProducts(catalog.products, catalog.brands, {
    category: "skincare",
    stock: true,
    sale: true,
    sort: "low",
  });
  assert.ok(found.length);
  assert.ok(
    found.every(
      (p) => p.category === "skincare" && p.available && p.compare_at > p.price,
    ),
  );
  assert.ok(found.every((p, i) => !i || (p.currency || "USD") !== (found[i - 1].currency || "USD") || p.price >= found[i - 1].price));
});
test("checkout uses actual variants and rejects unavailable or malformed lines", () => {
  const brand = catalog.brands.find(
    (b) =>
      b.shopify &&
      catalog.products.some(
        (p) =>
          p.brand === b.id &&
          p.available &&
          p.variants.some((v) => v.available),
      ),
  );
  const product = catalog.products.find(
    (p) =>
      p.brand === brand.id &&
      p.available &&
      p.variants.some((v) => v.available),
  );
  const variant = product.variants.find((v) => v.available);
  const line = { product, variant, quantity: 2 };
  assert.equal(
    checkoutURL(brand, [line]),
    `https://${brand.domain}/cart/${variant.id}:2${brand.currency ? "?currency=" + brand.currency : ""}`,
  );
  assert.equal(checkoutURL(brand, [{ ...line, quantity: -1 }]), null);
  assert.equal(
    checkoutURL(brand, [
      { ...line, variant: { ...variant, available: false } },
    ]),
    null,
  );
  assert.equal(checkoutURL({ ...brand, shopify: false }, [line]), null);
});
test("catalog URLs cannot execute script or point to non-HTTPS protocols", () => {
  for (const url of [
    "javascript:alert(1)",
    "data:text/html,test",
    "http://insecure.com",
    "//evil.com",
  ])
    assert.equal(safeURL(url), "");
});
// A Wix brand (owner, 2026-11-11: Deseta, the test brand) and a WooCommerce
// store without a verified hand-off are bought on the brand's own page, as
// in the app (Brand.usesMarracatCart): no cart, no Shopify-style cart link.
test("Wix and unverified WooCommerce brands are bought on the brand's page", () => {
  const line = { product: { available: true }, variant: { id: 5, available: true }, quantity: 1 };
  const wix = { id: "deseta", domain: "www.deseta.net", shopify: true, platform: "wix" };
  assert.equal(usesMarracatCart(wix), false);
  assert.equal(checkoutURL(wix, [line]), null);
  assert.equal(usesMarracatCart({ shopify: true, platform: "woocommerce", checkout: null }), false);
  assert.equal(usesMarracatCart({ shopify: true, platform: "woocommerce", checkout: "link" }), true);
  assert.equal(usesMarracatCart({ shopify: true, platform: "shopify" }), true);
  assert.equal(usesMarracatCart({ shopify: true }), true);
  assert.equal(usesMarracatCart({ shopify: true, platform: "swell" }), true);
  assert.equal(usesMarracatCart({ shopify: false }), false);
});


test("foreign currencies remain distinct in prices, cart totals and dollar-only deals", () => {
  assert.equal(money(12), "$12.00");
  assert.equal(money(12, "GBP"), "£12.00");
  assert.equal(money(12, "EUR"), "€12.00");
  const products = [
    {id: "u", price: 20},
    {id: "g", price: 10, currency: "GBP"},
    {id: "e", price: 15, currency: "EUR"},
  ];
  assert.deepEqual(filterProducts(products, [], {under: true}).map(p => p.id), ["u"]);
  assert.equal(cartTotals(products.map(product => ({product, variant: {price: product.price}, quantity: 2}))), "€30.00 + £20.00 + $40.00");
  // Sorted in dollars: £10 ≈ $13.21, €15 ≈ $16.79, then $20.
  assert.deepEqual(filterProducts(products, [], {sort: "low"}).map(p => p.id), ["g", "e", "u"]);
  assert.deepEqual(filterProducts(products, [], {sort: "high"}).map(p => p.id), ["u", "e", "g"]);
  // A brand's own rate wins over the fallback: at $2 a pound, £10 is dearest.
  assert.deepEqual(filterProducts(products.map(p => ({...p, brand: p.id})), [{id: "g", usd_rate: 2}], {sort: "low"}).map(p => p.id), ["e", "u", "g"]);
});
test("an aisle narrows a department to the products the taxonomy put there", () => {
  const withSubs = catalog.products.filter((p) => p.category === "hair" && p.subs?.length);
  assert.ok(withSubs.length > 100);
  const leaf = withSubs[0].subs[0];
  const found = filterProducts(catalog.products, catalog.brands, { category: "hair", aisle: leaf });
  assert.ok(found.length);
  assert.ok(found.every((p) => p.category === "hair" && p.subs.includes(leaf)));
  assert.ok(found.length < filterProducts(catalog.products, catalog.brands, { category: "hair" }).length);
});
test("a UCP-checkout brand (Telfar) gets no cart permalink; the review page builds its checkout", () => {
  const telfar = catalog.brands.find((b) => b.id === "telfar");
  assert.ok(telfar, "Telfar should be in the catalog");
  assert.equal(telfar.checkout, "ucp");
  assert.match(telfar.ucp, /^https:\/\/[a-z0-9-]+\.myshopify\.com\/api\/ucp\/mcp$/);
  const p = catalog.products.find((x) => x.brand === "telfar" && x.available);
  const v = p.variants.find((x) => x.available);
  const lines = [{ product: p, variant: v, quantity: 1 }];
  assert.equal(checkoutURL(telfar, lines), null);
  // Any Shopify brand on cart permalinks, not a named one: Karbon Footprint
  // closed its store (401) and dropped out of the catalog on 2026-10-22, and
  // this test stopped every catalog refresh for nine days.
  const op = catalog.products.find((x) => x.available && x.variants?.some((v) => v.available) && (() => {
    const b = catalog.brands.find((y) => y.id === x.brand);
    return b && b.platform === "shopify" && b.checkout !== "ucp";
  })());
  assert.ok(op, "some Shopify brand should check out by cart permalink");
  const other = catalog.brands.find((b) => b.id === op.brand);
  assert.ok(checkoutURL(other, [{ product: op, variant: op.variants.find((x) => x.available), quantity: 1 }]));
});

test("a word no product uses falls back to the rest of the search", () => {
  // A made-up word: "bulk" was one until braiding hair and shea butter sold in
  // bulk (2026-10-22), and then the test failed every catalog refresh.
  const opts = { q: "xyzzy t shirts" };
  assert.equal(filterProducts(catalog.products, catalog.brands, opts).length, 0);
  const relaxed = relaxedSearch(catalog.products, catalog.brands, opts);
  assert.equal(relaxed?.q, "t shirts");
  assert.ok(relaxed.result.length > 20, `only ${relaxed.result.length} t-shirts`);
  assert.equal(relaxedSearch(catalog.products, catalog.brands, { q: "t shirts" }), null);
  assert.equal(relaxedSearch(catalog.products, catalog.brands, { q: "zzqxv wqkjx" }), null);
});

test("sold-out products sort last under every sort", () => {
  for (const sort of ["featured", "low", "high", "new"]) {
    const r = filterProducts(catalog.products, catalog.brands, { category: "bags", sort });
    const firstOut = r.findIndex((p) => !p.available);
    assert.ok(firstOut === -1 || r.slice(firstOut).every((p) => !p.available), `${sort}: an in-stock item came after a sold-out one`);
  }
});
test("the product-type filter keeps one aisle of one department", () => {
  const products = [
    { id: "s", brand: "fog", title: "Classic Sweatpant", category: "clothing", subs: ["pants", "sweatpants"], price: 90, available: true },
    { id: "t", brand: "fog", title: "Classic Tee", category: "clothing", subs: ["tees", "tops"], price: 50, available: true },
    // Same leaf name in another department must not match "clothing:kids".
    { id: "k", brand: "fog", title: "Kids Cap", category: "accessories", subs: ["kids"], price: 30, available: true },
    { id: "c", brand: "fog", title: "Kids Sweatpant", category: "clothing", subs: ["kids", "sweatpants"], price: 60, available: true },
  ];
  const brands = [{ id: "fog", name: "Fear of God" }];
  const ids = (type) => filterProducts(products, brands, { brand: "fog", type }).map((p) => p.id).sort();
  assert.deepEqual(ids("clothing:sweatpants"), ["c", "s"]);
  assert.deepEqual(ids("clothing:kids"), ["c"]);
  assert.equal(ids("").length, 4, "off by default");
});

test("the product page names options as the store does, else 'an option'", () => {
  assert.equal(optionNoun(["Color"]), "color");
  assert.equal(optionNoun(["Color", "Size"]), "color / size");
  assert.equal(optionNoun(undefined), "an option");
  assert.equal(optionNoun([" "]), "an option");
});
test("the Country filter keeps the brands based in one country", () => {
  // Owner, 2026-11-26: "Let's put a filter for the country the company is founded".
  const products = [
    { id: "a", brand: "lagos-one", title: "Agbada", category: "clothing", price: 90, available: true },
    { id: "k", brand: "lagos-two", title: "Kaftan", category: "clothing", price: 50, available: true },
    { id: "t", brand: "london-co", title: "Trench", category: "clothing", price: 30, available: true },
    { id: "m", brand: "unknown-co", title: "Mystery", category: "clothing", price: 60, available: true },
  ];
  const brands = [
    { id: "lagos-one", name: "Lagos One", country: "NG" },
    { id: "lagos-two", name: "Lagos Two", country: "NG" },
    { id: "london-co", name: "London Co", country: "GB" },
    { id: "unknown-co", name: "Unknown Co" },
    { id: "odd-co", name: "Odd Co", country: "africa" },
  ];
  const ids = (options) => filterProducts(products, brands, options).map((p) => p.id).sort();
  assert.deepEqual(ids({ country: "NG" }), ["a", "k"]);
  assert.deepEqual(ids({ country: "GB" }), ["t"]);
  assert.deepEqual(ids({ country: "NG", brand: "lagos-two" }), ["k"]);
  assert.deepEqual(ids({ country: "US" }), [], "a brand with no country on record is in no country");
  assert.equal(ids({}).length, 4, "off by default");
  // The filter's choices, most products first, named in full.
  const counts = [{ id: "lagos-one", count: 1 }, { id: "lagos-two", count: 1 }, { id: "london-co", count: 1 }, { id: "unknown-co", count: 1 }, { id: "odd-co", count: 5 }];
  assert.deepEqual(countryChoices(brands, counts), [
    { id: "NG", name: "Nigeria", count: 2 },
    { id: "GB", name: "United Kingdom", count: 1 },
  ]);
  assert.equal(countryName("US"), "United States");
});
