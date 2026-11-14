import { test, expect } from "./fixtures.js";

// The journey suite must never count as a visitor (fixtures.js): every way a
// spec gets a page answers /api/events and /api/visit locally.
const stubbed = (page, path) => page.evaluate((p) =>
  fetch(p, { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" })
    .then((r) => r.headers.get("x-journey-stub")), path);

test("the default page, browser.newContext and browser.newPage all keep analytics posts local", async ({ page, browser }) => {
  await page.goto("/robots.txt");
  for (const path of ["/api/events", "/api/visit"]) expect(await stubbed(page, path)).toBe("1");
  const context = await browser.newContext({ userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)" });
  const other = await context.newPage();
  await other.goto("/robots.txt");
  expect(await stubbed(other, "/api/events")).toBe("1");
  await context.close();
  const lone = await browser.newPage();
  await lone.goto("/robots.txt");
  expect(await stubbed(lone, "/api/visit")).toBe("1");
  await lone.close();
});
