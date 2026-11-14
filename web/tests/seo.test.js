import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { setCatalog, shareCard, brandCard, categoryCard, sitemapEntries } from "../server/catalog.js";
import { sharePage, brandSharePage, categorySharePage } from "../server/share-page.js";
import { robotsTxt, sitemapIndex, sitemapFile, PRODUCTS_PER_FILE } from "../server/seo.js";
import { toPath, fromPath } from "../src/router.js";

// SEO foundation (owner, 2026-10-09): real paths, per-page meta + JSON-LD,
// a sitemap and robots.txt.
const catalog = JSON.parse(readFileSync(new URL("../../Marracat/Resources/catalog.json", import.meta.url)));
const shell = readFileSync(new URL("../index.html", import.meta.url), "utf8");
const ld = (html) => [...html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)].map((m) => JSON.parse(m[1]));

test("routes map to crawlable paths and back", () => {
  const cases = [
    ["/product?id=a-1", "/p/a-1"],
    ["/shop?brand=the-lip-bar", "/b/the-lip-bar"],
    ["/shop?category=beauty", "/c/beauty"],
    ["/shop?category=bags&aisle=tote", "/c/bags/tote"],
    ["/brands", "/brands"],
    ["/shop?q=shea+butter", "/shop?q=shea+butter"],
    ["/u/someone", "/u/someone"],
    ["/", "/"],
  ];
  for (const [route, path] of cases) {
    assert.equal(toPath(route), path, route);
    const [p, q = ""] = path.split("?");
    assert.equal(fromPath(p, q ? "?" + q : ""), route, path);
  }
  // Old "#/…" links resolve to the same path.
  assert.equal(toPath("#/product?id=x"), "/p/x");
  assert.equal(toPath("#/shop?category=beauty"), "/c/beauty");
  // A filtered department stays a query (robots.txt keeps /shop? out of the index).
  assert.equal(toPath("/shop?category=beauty&sort=price"), "/shop?category=beauty&sort=price");
  // Ids are encoded both ways; tracking params on home aren't a route.
  assert.equal(toPath("/product?id=a%2Fb"), "/p/a%2Fb");
  assert.equal(fromPath("/p/a%2Fb"), "/product?id=a%2Fb");
  assert.equal(fromPath("/", "?src=tt"), "/");
  assert.equal(fromPath("/brands/"), "/brands");
});

test("a product page carries its description and Product JSON-LD", () => {
  setCatalog(catalog);
  const product = catalog.products.find((p) => p.available && p.images?.length && typeof p.price === "number");
  const html = sharePage(shell, shareCard(product.id));
  assert.match(html, /<meta name="description" content="[^"]+"/);
  assert.equal((html.match(/name="description"/g) || []).length, 1, "the site's description is replaced");
  const data = ld(html);
  assert.equal(data.length, 1, "the home page's Organization block is replaced");
  assert.equal(data[0]["@type"], "Product");
  assert.equal(data[0].offers.priceCurrency, product.currency || "USD");
  assert.equal(data[0].offers.availability, "https://schema.org/InStock");
  assert.equal(data[0].url, `https://marracat.com/p/${encodeURIComponent(product.id)}`);
});

test("JSON-LD can't close its script tag", () => {
  const html = sharePage(shell, { id: "x", title: "</script><script>alert(1)</script>", brand: "B", price: 5, currency: "USD", available: true });
  assert.ok(!html.includes("</script><script>alert(1)"));
  assert.equal(ld(html)[0].name, "</script><script>alert(1)</script>", "the value survives, escaped");
});

test("a brand page lists its products as an ItemList", () => {
  setCatalog(catalog);
  const brand = catalog.brands.find((b) => catalog.products.some((p) => p.brand === b.id && p.available));
  const html = brandSharePage(shell, brandCard(brand.id));
  const [data] = ld(html);
  assert.equal(data["@type"], "CollectionPage");
  assert.ok(data.mainEntity.itemListElement.length > 0);
  assert.match(data.mainEntity.itemListElement[0].url, /^https:\/\/marracat\.com\/p\//);
});

test("department pages: independent-brands title, canonical, top brands; unknown ones are null", () => {
  setCatalog(catalog);
  const entries = sitemapEntries();
  const cat = entries.categories[0];
  const card = categoryCard(cat);
  assert.ok(card.count > 0 && card.brandCount > 0 && card.brands.length > 0);
  const html = categorySharePage(shell, card);
  assert.match(html, new RegExp(`<title>[^<]*from independent brands \\| Marracat</title>`));
  assert.ok(html.includes(`<link rel="canonical" href="https://marracat.com/c/${cat}"/>`));
  assert.ok(!/black[- ]owned/i.test(html), "public copy never says independent (owner rule)");
  const [data] = ld(html);
  assert.equal(data["@type"], "CollectionPage");
  assert.equal(data.mainEntity.numberOfItems, card.count);

  const [c, leaf] = entries.aisles[0].split(":");
  const aisle = categorySharePage(shell, categoryCard(c, leaf));
  assert.ok(aisle.includes(`<link rel="canonical" href="https://marracat.com/c/${c}/${leaf}"/>`));
  assert.equal(ld(aisle)[0].isPartOf.url, `https://marracat.com/c/${c}`);

  assert.equal(categoryCard("no-such-dept"), null);
  assert.equal(categoryCard(cat, "no-such-aisle"), null);
  assert.equal(categorySharePage(shell, null), shell);
});

test("robots.txt points at the sitemap and keeps private pages out", () => {
  const txt = robotsTxt();
  assert.match(txt, /^Sitemap: https:\/\/marracat\.com\/sitemap\.xml$/m);
  for (const p of ["/api/", "/cart", "/checkout", "/account", "/shop?"]) assert.ok(txt.includes(`Disallow: ${p}`), p);
  assert.ok(!/Disallow: \/(p|b|c)\//.test(txt));
});

test("sitemap index and files cover the catalog, split at the per-file cap", () => {
  setCatalog(catalog);
  const entries = sitemapEntries();
  const index = sitemapIndex(entries);
  // The date of the catalog the server is serving. setCatalog ignores an
  // older one, so on a machine where the published slim catalog is newer
  // than the bundled one, that newer date is the right lastmod.
  const day = entries.generated.slice(0, 10);
  assert.match(day, /^\d{4}-\d{2}-\d{2}$/);
  assert.ok(day >= catalog.generated_at.slice(0, 10));
  assert.ok(index.includes(`<lastmod>${day}</lastmod>`));
  for (const f of ["pages", "categories", "brands", "products-1"]) assert.ok(index.includes(`/sitemaps/${f}.xml`), f);
  const products = sitemapFile(entries, "products-1");
  assert.equal((products.match(/<url>/g) || []).length, Math.min(entries.products.length, PRODUCTS_PER_FILE));
  assert.equal((sitemapFile(entries, "brands").match(/<url>/g) || []).length, entries.brands.length);
  assert.equal(sitemapFile(entries, "products-999"), null);
  assert.equal(sitemapFile(entries, "nope"), null);

  // A catalog bigger than one file splits.
  const big = { ...entries, products: Array.from({ length: PRODUCTS_PER_FILE + 2 }, (_, i) => `p${i}&<`) };
  assert.ok(sitemapIndex(big).includes("/sitemaps/products-2.xml"));
  const second = sitemapFile(big, "products-2");
  assert.equal((second.match(/<url>/g) || []).length, 2);
  assert.ok(second.includes("/p/p45000%26%3C"), "ids are URL-encoded");
});
