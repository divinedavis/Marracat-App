import { test, expect } from "./fixtures.js";

// "What people are saying" on the home page, fed by /api/comments/recent.
const comments = [
  { id: "c1", body: "Love this <b>headband</b>", created_at: 1, author: { handle: "alice1", name: "Alice A." },
    product: { id: "koba-123", title: "Keep It Together Headband", brand: "KOBA", image: null } },
];

test("the home page shows recent comments, escaped, linking to the product", async ({ page }) => {
  await page.route("**/api/comments/recent", (r) => r.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ comments }) }));
  await page.goto("/");
  const section = page.getByTestId("home-comments");
  await expect(section).toBeVisible({ timeout: 60000 });
  await expect(section.getByRole("heading", { name: "What people are saying" })).toBeVisible();
  await expect(section).toContainText("Love this <b>headband</b>");
  await expect(section.locator("blockquote b")).toHaveCount(0); // the <b> stayed text
  await expect(section.getByRole("link")).toHaveAttribute("href", "/p/koba-123");
});

test("with no comments the section isn't drawn", async ({ page }) => {
  await page.route("**/api/comments/recent", (r) => r.fulfill({ status: 200, contentType: "application/json", body: '{"comments":[]}' }));
  await page.goto("/");
  await expect(page.getByRole("heading", { name: /Your next favorite/ })).toBeVisible({ timeout: 60000 });
  await expect(page.getByTestId("home-comments")).toHaveCount(0);
});
