import { test, expect } from "./fixtures.js";

// The installable site and its service worker (owner, 2026-11-10: "implement
// repeat visits cache"). The rest of the suite runs with service workers
// blocked; these contexts allow them.
const withWorker = async (browser) => {
  const context = await browser.newContext({ serviceWorkers: "allow" });
  const page = await context.newPage();
  return { context, page };
};
const ready = (page) => page.evaluate(async () => {
  await navigator.serviceWorker.ready;
  if (!navigator.serviceWorker.controller) await new Promise((r) => navigator.serviceWorker.addEventListener("controllerchange", r, { once: true }));
  return true;
});

test("the site can be installed: a manifest with a name, a start page and icons that exist", async ({ page, request }) => {
  await page.goto("/");
  const href = await page.locator('link[rel="manifest"]').getAttribute("href");
  const manifest = await (await request.get(href)).json();
  expect(manifest.name).toBe("Marracat");
  expect(manifest.display).toBe("standalone");
  expect(manifest.start_url).toBe("/");
  expect(manifest.icons.some((i) => i.sizes === "192x192")).toBe(true);
  expect(manifest.icons.some((i) => i.sizes === "512x512" && i.purpose === "maskable")).toBe(true);
  for (const icon of manifest.icons) {
    const r = await request.get(icon.src);
    expect(r.status(), icon.src).toBe(200);
    expect(r.headers()["content-type"]).toContain("image/png");
  }
  for (const s of manifest.shortcuts) expect((await request.get(s.url)).status(), s.url).toBe(200);
});

test("after one visit the site opens with no network at all", async ({ browser }) => {
  const { context, page } = await withWorker(browser);
  await page.goto("/");
  await expect(page.getByRole("heading", { name: /Your next favorite/ })).toBeVisible({ timeout: 30000 });
  await ready(page);
  // The script and styles this page asked for are on the device.
  const kept = await page.evaluate(async () => (await (await caches.open("marracat-assets-v1")).keys()).map((r) => new URL(r.url).pathname));
  expect(kept.some((p) => /^\/assets\/index-.*\.js$/.test(p))).toBe(true);
  expect(kept.some((p) => /^\/assets\/index-.*\.css$/.test(p))).toBe(true);
  // One more load so /api/home is kept too (the worker took control after the first).
  await page.reload();
  await expect(page.getByRole("heading", { name: /Your next favorite/ })).toBeVisible({ timeout: 30000 });
  await expect(page.locator(".product-card").first()).toBeVisible({ timeout: 30000 });
  await context.setOffline(true);
  await page.reload();
  await expect(page.getByRole("heading", { name: /Your next favorite/ })).toBeVisible({ timeout: 15000 });
  await expect(page.locator(".product-card").first()).toBeVisible({ timeout: 15000 });
  // A page it has never opened still opens the storefront, not the browser's error page.
  await page.goto("/saved");
  await expect(page.locator("header.header")).toBeVisible({ timeout: 15000 });
  await context.close();
});

test("the worker leaves sign-in, the catalog and other sites' files alone", async ({ browser }) => {
  const { context, page } = await withWorker(browser);
  await page.goto("/");
  await ready(page);
  await page.reload();
  await expect(page.locator(".product-card").first()).toBeVisible({ timeout: 30000 });
  await page.waitForTimeout(1500);
  const kept = await page.evaluate(async () => {
    const out = [];
    for (const name of await caches.keys()) if (!name.startsWith("marracat-catalog")) for (const r of await (await caches.open(name)).keys()) out.push(new URL(r.url));
    return out.map((u) => u.origin === location.origin ? u.pathname : u.origin);
  });
  expect(kept.length).toBeGreaterThan(2);
  for (const path of kept) expect(path, path).toMatch(/^\/$|^\/assets\/|^\/api\/home$|^\/(favicon|apple-touch-icon|icon-|mark\.svg|logo\.svg|manifest\.json)/);
  await context.close();
});

test("a new version of the site replaces the kept one on the next visit", async ({ browser }) => {
  const { context, page } = await withWorker(browser);
  await page.goto("/");
  await ready(page);
  // Pretend an older release left a script behind.
  await page.evaluate(async () => (await caches.open("marracat-assets-v1")).put("/assets/index-OLDOLD.js", new Response("old")));
  await page.goto("/");
  await expect.poll(() => page.evaluate(async () => !!(await (await caches.open("marracat-assets-v1")).match("/assets/index-OLDOLD.js"))), { timeout: 10000 }).toBe(false);
  await context.close();
});
