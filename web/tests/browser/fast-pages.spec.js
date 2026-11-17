import { test, expect } from "./fixtures.js";

// Brand, search and department pages draw from /api/query while the 9.6 MB
// full catalog is still on its way (2026-10-10: 14–45 s on a phone). With the
// full catalog blocked outright they must still show products, page through
// them, and open a product.
test.beforeEach(async ({ page }) => {
  await page.route("**/api/catalog*", (route) => route.abort());
});

test("a brand page and a search show products without the full catalog", async ({ page }) => {
  for (const path of ["/b/fear-of-god", "/shop?q=shea%20butter"]) {
    const started = Date.now();
    await page.goto(path);
    await expect(page.locator(".product-card").first()).toBeVisible({ timeout: 10000 });
    expect(Date.now() - started).toBeLessThan(10000);
    await expect(page.locator(".load-more [role=status]")).toContainText(/Showing \d+ of [\d,]+ products/);
  }
});

test("scrolling keeps loading pages from the server", async ({ page }) => {
  await page.goto("/shop?q=shea%20butter");
  await expect(page.locator(".product-card").first()).toBeVisible({ timeout: 10000 });
  const first = await page.locator(".product-card").count();
  for (let i = 0; i < 4; i++) {
    await page.mouse.wheel(0, 20000);
    await page.waitForTimeout(600);
  }
  expect(await page.locator(".product-card").count()).toBeGreaterThan(first + 36);
});

test("a department's chips and type-free filters work before the catalog", async ({ page }) => {
  await page.goto("/c/skincare");
  await expect(page.locator(".product-card").first()).toBeVisible({ timeout: 10000 });
  // No intro line under the breadcrumb (owner, 2026-11-15: removed).
  await expect(page.locator(".dept-intro")).toHaveCount(0);
});

test("a product page opens from its own record", async ({ page, request }) => {
  const { products } = await (await request.get("/api/query?brand=fear-of-god&limit=1")).json();
  await page.goto("/p/" + encodeURIComponent(products[0].id));
  await expect(page.locator(".product-detail")).toBeVisible({ timeout: 10000 });
});

// A reload of the cart draws from its lines' own product records, not the
// full catalog (2026-10-12: it used to show "Good things are on their way."
// until all 147k products had arrived).
test("a cart reload shows its lines without the full catalog", async ({ page, request }) => {
  const { products } = await (await request.get("/api/query?brand=fear-of-god&stock=1&limit=1")).json();
  const p = (await (await request.get("/api/products/" + encodeURIComponent(products[0].id) + "?v=3")).json());
  const v = p.variants.find((x) => x.available) || p.variants[0];
  await page.goto("/");
  await page.evaluate((line) => localStorage.setItem("marracat-cart", JSON.stringify([line])),
    { key: `${p.id}:${v.id}`, id: p.id, variant: String(v.id), quantity: 1 });
  await page.goto("/cart");
  await expect(page.locator(".cart-line")).toHaveCount(1, { timeout: 10000 });
  await expect(page.locator(".cart-line")).toContainText(p.title);
});

// Pages with no fast path of their own (cart, saved items) start the full
// catalog download at once. They used to hold it back 4 s for a FAST_READY
// that only /shop, /product and the order pages ever send, which made a
// reload of either page miss a 5 s wait about two runs in three.
test("cart and saved items request the full catalog without the 4 s hold", async ({ page }) => {
  for (const path of ["/cart", "/saved"]) {
    let asked = 0;
    const onRequest = (r) => { if (r.url().includes("/api/catalog")) asked ||= Date.now(); };
    page.on("request", onRequest);
    const started = Date.now();
    await page.goto(path);
    await expect.poll(() => asked, { timeout: 10000 }).toBeGreaterThan(0);
    expect(asked - started, path).toBeLessThan(2500);
    page.off("request", onRequest);
  }
});
