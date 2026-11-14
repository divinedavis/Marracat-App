import { test, expect } from "./fixtures.js";

// "Goes well with" on product pages (owner, 2026-10-10). The endpoint is
// stubbed so the row doesn't depend on a brand's store answering.
async function catalog(request) {
  return (await request.get("/api/catalog?v=5")).json();
}

test("a product page shows Goes well with from the endpoint, and counts the row", async ({ page, request }) => {
  const c = await catalog(request);
  const live = c.products.filter((p) => p.available && p.images?.length);
  const [p, ...others] = live;
  const picks = others.slice(0, 5).map((x) => x.id);
  await page.route(`**/api/products/${encodeURIComponent(p.id)}/complements`, (r) =>
    r.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ products: picks, source: "shopify", intent: "related", items: [] }) }));
  const events = [];
  await page.route("**/api/events", (r) => { events.push(r.request().postData() || ""); r.fulfill({ status: 204 }); });
  await page.goto(`/p/${p.id}`);
  const row = page.getByTestId("goes-well-with");
  await expect(row).toBeVisible({ timeout: 60000 });
  await expect(row.getByRole("heading", { name: "Goes well with" })).toBeVisible();
  await expect(row.locator(".product-card")).toHaveCount(5);
  await expect.poll(() => events.some((e) => e.includes('"rec_view"') && e.includes('"complements"'))).toBe(true);
  await row.locator(".product-card a").first().click();
  await expect.poll(() => events.some((e) => e.includes('"rec_tap"'))).toBe(true);
});

test("with fewer than four picks the row stays hidden", async ({ page, request }) => {
  const c = await catalog(request);
  const [p, q, r] = c.products.filter((x) => x.available && x.images?.length);
  await page.route(`**/api/products/${encodeURIComponent(p.id)}/complements`, (route) =>
    route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ products: [q.id, r.id], source: "carts", items: [] }) }));
  await page.goto(`/p/${p.id}`);
  await expect(page.locator(".detail-info h1, h1").first()).toBeVisible({ timeout: 60000 });
  await page.waitForTimeout(1500);
  await expect(page.getByTestId("goes-well-with")).toHaveCount(0);
});

// Owner, 2026-11-08: "Goes well with" was tapped 4 times in 291 views, so
// "Top picks in <aisle>" (other brands, same aisle) takes its place under
// the comments and "Goes well with" moves below "More from <brand>".
test("Top picks in the aisle comes first, from other brands, and is counted", async ({ page, request }) => {
  const c = await catalog(request);
  const live = c.products.filter((p) => p.available && p.images?.length && (p.subs || []).length);
  const bySub = new Map();
  for (const p of live) {
    const k = `${p.category}:${p.subs[0]}`;
    if (!bySub.has(k)) bySub.set(k, new Set());
    bySub.get(k).add(p.brand);
  }
  const p = live.find((x) => bySub.get(`${x.category}:${x.subs[0]}`).size >= 8);
  const picks = live.filter((x) => x.id !== p.id).slice(0, 5).map((x) => x.id);
  await page.route(`**/api/products/${encodeURIComponent(p.id)}/complements`, (r) =>
    r.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ products: picks, source: "shopify", items: [] }) }));
  const events = [];
  await page.route("**/api/events", (r) => { events.push(r.request().postData() || ""); r.fulfill({ status: 204 }); });
  await page.goto(`/p/${p.id}`);
  const top = page.getByTestId("type-top-picks");
  await expect(top).toBeVisible({ timeout: 60000 });
  await expect(top.getByRole("heading", { name: /^Top picks in / })).toBeVisible();
  const brandsShown = await top.locator(".product-card").evaluateAll((cards) => cards.length);
  expect(brandsShown).toBeGreaterThanOrEqual(4);
  const goes = page.getByTestId("goes-well-with");
  await expect(goes).toBeVisible();
  const [topY, goesY] = [(await top.boundingBox()).y, (await goes.boundingBox()).y];
  expect(topY).toBeLessThan(goesY);
  await expect.poll(() => events.some((e) => e.includes('"rec_view"') && e.includes('"type_top"'))).toBe(true);
});
