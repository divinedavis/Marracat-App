import { test, expect } from "./fixtures.js";

// What the browser offers that the site now uses (owner, 2026-11-10): page
// transitions, a product's page loading from the press, off-screen cards
// skipped, and real-visit speed sent as the page is left.

test("going to another page cross-fades; a filter on the same page does not", async ({ page }) => {
  await page.addInitScript(() => {
    window.__fades = 0;
    const real = document.startViewTransition?.bind(document);
    if (real) document.startViewTransition = (update) => { window.__fades++; return real(update); };
  });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  await page.goto("/b/fear-of-god");
  const card = page.locator(".product-grid .product-card").first();
  await expect(card).toBeVisible({ timeout: 60000 });
  expect(await page.evaluate(() => typeof document.startViewTransition)).toBe("function");
  // Same page, another sort: the address changes, the page does not fade.
  await page.getByLabel(/sort/i).first().selectOption("low");
  await expect(card).toBeVisible();
  expect(await page.evaluate(() => window.__fades)).toBe(0);
  // Another page: one fade, and the new page is there when it ends.
  await card.locator(".product-art a").click();
  await expect(page).toHaveURL(/\/p\//);
  await expect(page.locator("h1").first()).toBeVisible();
  expect(await page.evaluate(() => window.__fades)).toBe(1);
  // Back is a move between pages too.
  await page.goBack();
  await expect(page).toHaveURL(/\/b\/fear-of-god/);
  await expect(card).toBeVisible();
  expect(await page.evaluate(() => window.__fades)).toBe(2);
  expect(errors).toEqual([]);
});

test("someone who asked for less motion gets no fade", async ({ browser }) => {
  const context = await browser.newContext({ reducedMotion: "reduce" });
  const page = await context.newPage();
  await page.addInitScript(() => {
    window.__fades = 0;
    const real = document.startViewTransition?.bind(document);
    if (real) document.startViewTransition = (update) => { window.__fades++; return real(update); };
  });
  await page.goto("/b/fear-of-god");
  const card = page.locator(".product-grid .product-card").first();
  await expect(card).toBeVisible({ timeout: 60000 });
  await card.locator(".product-art a").click();
  await expect(page).toHaveURL(/\/p\//);
  expect(await page.evaluate(() => window.__fades)).toBe(0);
  await context.close();
});

test("pressing a product's link starts loading its page before the click ends", async ({ page }) => {
  await page.goto("/b/fear-of-god");
  const link = page.locator(".product-grid .product-card .product-art a").first();
  await expect(link).toBeVisible({ timeout: 60000 });
  const id = decodeURIComponent((await link.getAttribute("href")).replace(/^\/p\//, ""));
  const box = await link.boundingBox();
  const asked = page.waitForRequest((r) => r.url().endsWith("/api/products/" + encodeURIComponent(id) + "?v=3"));
  // Down, not up: no click has happened yet.
  await page.mouse.move(box.x + 5, box.y + 5);
  const before = page.url();
  await page.mouse.down();
  await asked;
  expect(page.url()).toBe(before);
  await page.mouse.up();
});

test("a grid's off-screen cards are skipped until they are near the screen", async ({ page }) => {
  await page.goto("/b/fear-of-god");
  const cards = page.locator(".product-grid .product-card");
  await expect(cards.nth(30)).toBeAttached({ timeout: 60000 });
  expect(await cards.first().evaluate((el) => getComputedStyle(el).contentVisibility)).toBe("auto");
  // A card far below is still there to find, to link to and to scroll to.
  const far = cards.nth(30);
  await far.scrollIntoViewIfNeeded();
  await expect(far.locator(".product-title")).toBeVisible();
});

test("how fast the visit was is sent once, as the page is left, with nothing that names the visitor", async ({ page }) => {
  const sent = [];
  await page.route("**/api/vitals", (route) => { sent.push(route.request().postData()); route.fulfill({ status: 204 }); });
  await page.goto("/");
  await expect(page.locator(".product-card, .hero, main").first()).toBeVisible({ timeout: 60000 });
  await page.waitForTimeout(500);
  const leave = () => page.evaluate(() => {
    Object.defineProperty(document, "visibilityState", { value: "hidden", configurable: true });
    document.dispatchEvent(new Event("visibilitychange"));
  });
  await leave();
  await leave();
  await expect.poll(() => sent.length).toBe(1);
  // WebKit's test harness can't show a beacon's body; one was sent, once.
  test.skip(sent[0] === null, "this engine's harness hides beacon bodies");
  const body = JSON.parse(sent[0]);
  expect(body.ttfb).toBeGreaterThan(0);
  expect(body.fcp).toBeGreaterThan(0);
  expect(body.screen).toBe("home");
  expect(Object.keys(body).filter((k) => /id|visitor|ua|email/i.test(k))).toEqual([]);
});

test("the owner's own browser sends no speed report", async ({ page }) => {
  let sent = 0;
  await page.route("**/api/vitals", (route) => { sent++; route.fulfill({ status: 204 }); });
  await page.addInitScript(() => localStorage.setItem("marracat-owner", "1"));
  await page.goto("/");
  await page.waitForTimeout(800);
  await page.evaluate(() => {
    Object.defineProperty(document, "visibilityState", { value: "hidden", configurable: true });
    document.dispatchEvent(new Event("visibilitychange"));
  });
  await page.waitForTimeout(300);
  expect(sent).toBe(0);
});
