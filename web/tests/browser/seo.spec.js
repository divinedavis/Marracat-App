import { test, expect } from "./fixtures.js";

// Crawlers read the server's HTML, not the app (server/seo.js; unit tests in
// tests/seo.test.js). These ask the live site the way a crawler does: plain
// requests, no JavaScript.

const head = (html, re) => (html.match(re) || [])[1];

test("brand, product and department pages are served with their own title, canonical and JSON-LD", async ({ request }) => {
  const { products } = await (await request.get("/api/query?brand=telfar&stock=1&limit=1")).json();
  const pages = [
    ["/b/telfar", /Telfar/],
    ["/p/" + encodeURIComponent(products[0].id), new RegExp(products[0].title.slice(0, 20).replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))],
    ["/c/bags", /Bags/i],
  ];
  for (const [path, title] of pages) {
    const r = await request.get(path);
    expect(r.status(), path).toBe(200);
    const html = await r.text();
    expect(head(html, /<title>([^<]*)<\/title>/), path).toMatch(title);
    expect(head(html, /<link rel="canonical" href="([^"]+)"/), path).toBe("https://marracat.com" + path);
    expect(html, path).toContain("application/ld+json");
    expect(html, path).toMatch(/<meta name="description" content="[^"]{20,}"/);
  }
});

test("robots.txt keeps private pages out and names the sitemap, which lists every sitemap file", async ({ request }) => {
  const robots = await (await request.get("/robots.txt")).text();
  for (const line of ["Disallow: /api/", "Disallow: /cart", "Disallow: /account", "Sitemap: https://marracat.com/sitemap.xml"]) {
    expect(robots).toContain(line);
  }
  const index = await (await request.get("/sitemap.xml")).text();
  const files = [...index.matchAll(/<loc>https:\/\/marracat\.com(\/sitemaps\/[^<]+)<\/loc>/g)].map((m) => m[1]);
  expect(files).toEqual(expect.arrayContaining(["/sitemaps/pages.xml", "/sitemaps/categories.xml", "/sitemaps/brands.xml"]));
  for (const f of files) {
    const r = await request.get(f);
    expect(r.status(), f).toBe(200);
    expect((await r.text()).match(/<loc>/g)?.length ?? 0, f).toBeGreaterThan(0);
  }
});
