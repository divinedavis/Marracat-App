import { test, expect } from "./fixtures.js";

// What the live catalog must hold, whichever refresh published it.

// The refresh droplet republishes every 6 h (b562e3d); a catalog older than
// 8 h means a run failed or stalled.
test("the published catalog is under 8 hours old", async ({ request }) => {
  const r = await request.head("/catalog-v3.json");
  expect(r.status()).toBe(200);
  const modified = Date.parse(r.headers()["last-modified"]);
  expect(Number.isFinite(modified), "no Last-Modified on the catalog").toBe(true);
  const hours = (Date.now() - modified) / 3600e3;
  expect(hours, `catalog-v3.json last changed ${hours.toFixed(1)} h ago`).toBeLessThan(8);
});

// The Butter Bar Skincare came off on 2026-10-12 (e3bbbf0) and came back on
// 2026-10-14 (e12dc50, owner: the order arrived, only late): it is in the
// catalog, its search and the brand sitemap again, with a page of its own.
test("a restored brand is back in the catalog, search, sitemap and its page", async ({ page, request }) => {
  const id = "the-butter-bar-skincare";
  const c = await (await request.get("/api/catalog?v=5")).json();
  expect(c.brands.map((b) => b.id)).toContain(id);
  expect(c.products.filter((p) => p.brand === id).length).toBeGreaterThan(0);
  const q = await (await request.get("/api/query?q=" + encodeURIComponent("butter bar skincare") + "&limit=60")).json();
  expect(q.products.filter((p) => p.brand === id).length).toBeGreaterThan(0);
  expect(await (await request.get("/sitemaps/brands.xml")).text()).toContain(`/b/${id}`);
  expect((await page.goto(`/b/${id}`)).status()).toBe(200);
  await expect(page).toHaveTitle(/Butter Bar/);
});

// The photo check moved Ruby Love's period underwear to Clothing (1f000df):
// the site files it there too.
test("Ruby Love's period underwear is under Clothing", async ({ request }) => {
  const { products, total } = await (await request.get("/api/query?brand=ruby-love&q=underwear&limit=60")).json();
  expect(total).toBeGreaterThan(10);
  const pieces = products.filter((p) => /underwear/i.test(p.title) && !/kit/i.test(p.title));
  expect(pieces.length).toBeGreaterThan(10);
  expect(pieces.filter((p) => p.category !== "clothing").map((p) => `${p.title} -> ${p.category}`)).toEqual([]);
});
