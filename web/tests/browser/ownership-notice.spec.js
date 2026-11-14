import { test, expect } from "./fixtures.js";

// Owner, 2026-11-08: the headline card (option 2 of five) on any search
// saying "independent", whatever words come before or after, and over the
// suggestions while it's being typed. As testIndependentCardShowsWhileTypingAndOnResults.
for (const q of ["independent", "independent bracelets", "bracelets independent", "independent candles"]) {
  test(`the card heads the results for "${q}"`, async ({ page }) => {
    await page.goto("/shop?q=" + encodeURIComponent(q));
    const card = page.getByTestId("ownership-notice");
    await expect(card).toBeVisible({ timeout: 60000 });
    await expect(card).toContainText("You’re in the right place.");
    await expect(card).toContainText(/Every (one of our [\d,]+ brands|brand on Marracat) is independent/);
  });
}

test("no card for a colour search", async ({ page }) => {
  await page.goto("/shop?q=" + encodeURIComponent("black bracelets"));
  await expect(page.locator(".product-card").first()).toBeVisible({ timeout: 60000 });
  await expect(page.getByTestId("ownership-notice")).toHaveCount(0);
});

test("the one-line card sits over the suggestions while typing", async ({ page }) => {
  await page.goto("/");
  const box = page.getByRole("combobox", { name: "Search products and brands" }).first();
  await box.click();
  await box.pressSequentially("hair oil independent", { delay: 20 });
  const card = page.locator(".ownership-notice.compact");
  await expect(card).toBeVisible({ timeout: 30000 });
  await expect(card).toContainText("Every brand on Marracat is independent.");
});
