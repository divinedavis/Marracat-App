import { test, expect } from "./fixtures.js";

// The catalog is read by a worker, a line at a time, and kept on the device
// (owner, 2026-11-10: "background threads" and "data kept on the device").

/// Where the page says its catalog came from, and whether it has its search
/// index: the marks src/vitals.js leaves on the performance timeline.
async function catalogFrom(page) {
  await expect.poll(() => page.evaluate(() => performance.getEntriesByName("marracat:catalog").length), { timeout: 60000 }).toBe(1);
  return page.evaluate(() => ({
    catalog_from: performance.getEntriesByName("marracat:catalog")[0].detail,
    catalog: performance.getEntriesByName("marracat:catalog")[0].startTime,
    indexed: performance.getEntriesByName("marracat:index")[0]?.detail,
  }));
}
const catalogCalls = (page) => {
  const calls = [];
  page.on("response", (r) => { if (r.url().includes("/api/catalog")) calls.push({ url: r.url(), status: r.status() }); });
  return calls;
};
test("first visit: the worker downloads the catalog as lines; the page never reads one big document", async ({ page }) => {
  const calls = catalogCalls(page);
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  await page.goto("/brands");
  await expect(page.locator(".brand-card, .brand-tile, a[href^='/b/']").first()).toBeVisible({ timeout: 60000 });
  // The index arrives just after the catalog; search on the page then uses it.
  await page.waitForTimeout(2000);
  const report = await catalogFrom(page);
  expect(report.catalog_from).toBe("network");
  expect(report.indexed).toBe(true);
  expect(report.catalog).toBeGreaterThan(0);
  expect(calls.length).toBe(1);
  expect(calls[0].url).toContain("lines=1");
  expect(errors).toEqual([]);
});

test("a repeat visit reads the catalog from the device and only asks the server whether it changed", async ({ browser }) => {
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto("/brands");
  await expect(page.locator("a[href^='/b/']").first()).toBeVisible({ timeout: 60000 });
  // The copy is written as the lines arrive; give the compressor a moment to finish.
  await expect.poll(() => page.evaluate(async () => !!(await (await caches.open("marracat-catalog-v1")).match("/__device/catalog-lines"))), { timeout: 30000 }).toBe(true);
  const size = await page.evaluate(async () => (await (await (await caches.open("marracat-catalog-v1")).match("/__device/catalog-lines")).blob()).size);
  expect(size).toBeGreaterThan(1_000_000);
  expect(size).toBeLessThan(40_000_000); // compressed, not the 107 MB text

  const second = await context.newPage();
  const calls = catalogCalls(second);
  await second.goto("/brands");
  await expect(second.locator("a[href^='/b/']").first()).toBeVisible({ timeout: 60000 });
  const report = await catalogFrom(second);
  expect(report.catalog_from).toBe("device");
  // One conditional request, answered "not modified": no catalog body came down.
  await expect.poll(() => calls.length, { timeout: 15000 }).toBe(1);
  expect(calls[0].status).toBe(304);
  await context.close();
});

test("with the catalog on the device, search works with the network off", async ({ browser }) => {
  const context = await browser.newContext({ serviceWorkers: "allow" });
  const page = await context.newPage();
  await page.goto("/");
  await expect(page.locator(".product-card").first()).toBeVisible({ timeout: 60000 });
  await expect.poll(() => page.evaluate(async () => !!(await (await caches.open("marracat-catalog-v1")).match("/__device/catalog-lines"))), { timeout: 30000 }).toBe(true);
  await page.evaluate(() => navigator.serviceWorker.ready);
  await page.reload(); // now under the service worker, so the shell is kept too
  await expect(page.locator(".product-card").first()).toBeVisible({ timeout: 60000 });
  await context.setOffline(true);
  await page.goto("/shop?q=shea%20butter");
  await expect(page.locator(".product-grid .product-card").first()).toBeVisible({ timeout: 30000 });
  await expect(page.locator(".load-more [role=status]")).toContainText(/of [\d,]+ products/);
  await context.close();
});

test("search on the page uses the worker's index and matches the server's answer", async ({ page, request }) => {
  await page.goto("/brands");
  await expect(page.locator("a[href^='/b/']").first()).toBeVisible({ timeout: 60000 });
  for (const q of ["shea butter", "red dress", "lipstik"]) {
    const server = await (await request.get("/api/query?limit=24&q=" + encodeURIComponent(q))).json();
    // The page answers from its own catalog now: keep the server out of it.
    await page.route("**/api/query*", (route) => route.abort());
    await page.goto("/shop?q=" + encodeURIComponent(q));
    const cards = page.locator(".product-grid .product-card .product-art a");
    await expect(cards.first()).toBeVisible({ timeout: 60000 });
    const ids = await cards.evaluateAll((links) => links.slice(0, 24).map((a) => decodeURIComponent(a.getAttribute("href").replace(/^\/p\//, ""))));
    expect(ids, q).toEqual(server.products.slice(0, ids.length).map((p) => p.id));
    await page.unroute("**/api/query*");
  }
});

test("a browser without workers still gets its catalog, the old way", async ({ page }) => {
  await page.addInitScript(() => { delete window.Worker; });
  const calls = catalogCalls(page);
  await page.goto("/brands");
  await expect(page.locator("a[href^='/b/']").first()).toBeVisible({ timeout: 60000 });
  expect((await catalogFrom(page)).catalog_from).toBe("page");
  expect(calls.map((c) => c.url.includes("lines=1"))).toEqual([false]);
});

test("the page stays responsive while the catalog arrives", async ({ page }) => {
  await page.addInitScript(() => {
    window.__longest = 0;
    new PerformanceObserver((list) => { for (const e of list.getEntries()) window.__longest = Math.max(window.__longest, e.duration); }).observe({ type: "longtask", buffered: true });
  });
  await page.goto("/brands");
  await expect(page.locator("a[href^='/b/']").first()).toBeVisible({ timeout: 60000 });
  await page.waitForTimeout(500);
  // Reading the catalog as one document blocked the page for over a second
  // on this machine; a line is a few milliseconds. What is left is drawing
  // the page once the catalog is in.
  expect(await page.evaluate(() => window.__longest)).toBeLessThan(1500);
});
