import { test, expect } from "./fixtures.js";

// Sign-in is a plain card with Apple and Google side by side and a link to
// use email instead (owner, 2026-11-09). The email way sends a 6-digit code
// (server/email-code.js; tests/email-code.test.js covers the server side);
// here the two server calls are answered locally so no mail goes out.
test("the sign-in card offers Apple, Google, and email by a 6-digit code", async ({ page }) => {
  await page.route("**/api/auth-status", (r) => r.fulfill({ json: { email: true, google: true, apple: true } }));
  const sent = [];
  await page.route("**/api/email-code", (r) => { sent.push(r.request().postDataJSON()); r.fulfill({ status: 204 }); });
  let posted;
  await page.route("**/auth/callback/email", (r) => {
    posted = new URLSearchParams(r.request().postData());
    const ok = posted.get("code") === "123456";
    r.fulfill({ json: { url: ok ? new URL("/account", r.request().url()).href : new URL("/signin?error=CredentialsSignin", r.request().url()).href } });
  });
  await page.goto("/");
  await page.getByRole("button", { name: "Sign in Account" }).click();
  const dialog = page.locator("#auth-dialog");
  await expect(dialog.getByRole("heading", { name: "Log in or sign up" })).toBeVisible();
  await expect(dialog.getByRole("button", { name: "Continue with Apple" })).toBeVisible();
  await expect(dialog.getByRole("button", { name: "Continue with Google" })).toBeVisible();

  await dialog.getByRole("button", { name: "Use email instead" }).click();
  await dialog.getByLabel("Email").fill("Shopper@Example.com");
  await dialog.getByRole("button", { name: "Continue", exact: true }).click();
  await expect(dialog.getByRole("status")).toContainText("Shopper@Example.com");
  expect(sent).toEqual([{ email: "Shopper@Example.com" }]);

  await dialog.getByLabel("6-digit code").fill("12a3456");
  await expect(dialog.getByLabel("6-digit code")).toHaveValue("123456");
  await dialog.getByLabel("6-digit code").fill("999999");
  await dialog.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(dialog.getByRole("alert")).toContainText("That code didn't work");
  await dialog.getByLabel("6-digit code").fill("123456");
  await dialog.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(page).toHaveURL(/\/account$/);
  expect(posted.get("email")).toBe("Shopper@Example.com");
  expect(posted.get("csrfToken")).toBeTruthy();
});

test("Other ways to sign in goes back, and the card opens at Apple and Google again", async ({ page }) => {
  await page.route("**/api/auth-status", (r) => r.fulfill({ json: { email: true, google: true, apple: true } }));
  await page.goto("/");
  await page.getByRole("button", { name: "Sign in Account" }).click();
  const dialog = page.locator("#auth-dialog");
  await dialog.getByRole("button", { name: "Use email instead" }).click();
  await dialog.getByRole("button", { name: "Other ways to sign in" }).click();
  await expect(dialog.getByRole("button", { name: "Continue with Apple" })).toBeVisible();
  await dialog.getByRole("button", { name: "Use email instead" }).click();
  await page.getByRole("button", { name: "Close sign in" }).click();
  await page.getByRole("button", { name: "Sign in Account" }).click();
  await expect(dialog.getByRole("button", { name: "Continue with Google" })).toBeVisible();
});

test("without a mailbox to send from there is no email link", async ({ page }) => {
  await page.route("**/api/auth-status", (r) => r.fulfill({ json: { email: false, google: true, apple: true } }));
  await page.goto("/");
  await page.getByRole("button", { name: "Sign in Account" }).click();
  await expect(page.locator("#auth-dialog").getByRole("button", { name: "Continue with Apple" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Use email instead" })).toHaveCount(0);
});
