import { test, expect } from "./fixtures.js";
import { authCore } from "../auth-core.js";
const { encode } = await authCore("/jwt");
import Database from "better-sqlite3";
import path from "node:path";

// Passkeys (owner, 2026-11-10), with Chrome's virtual authenticator standing
// in for Face ID / Touch ID: the page makes a real key pair and signs real
// challenges, and our server checks them. A passkey can't belong to an IP
// address, so these run on http://localhost against the local server
// (TEST_AUTH_SECRET / TEST_DATA_DIR, as tests/browser/social.spec.js).
const SECRET = process.env.TEST_AUTH_SECRET;
const DATA = process.env.TEST_DATA_DIR;
const COOKIE = "authjs.session-token";
const HOST = "http://localhost:3107";

test.skip(!(SECRET && DATA), "set TEST_AUTH_SECRET and TEST_DATA_DIR to match the local server");
test.skip(({ browserName }) => browserName !== "chromium", "the virtual authenticator is Chrome's");

async function signIn(context, id, name, email) {
  const db = new Database(path.join(DATA, "marracat.sqlite"));
  db.prepare("INSERT OR IGNORE INTO users(id,name,email) VALUES(?,?,?)").run(id, name, email);
  db.close();
  const value = await encode({ token: { sub: id, name, email }, secret: SECRET, salt: COOKIE });
  await context.addCookies([{ name: COOKIE, value, domain: "localhost", path: "/", httpOnly: true, sameSite: "Lax" }]);
}
async function faceID(page) {
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("WebAuthn.enable");
  const { authenticatorId } = await cdp.send("WebAuthn.addVirtualAuthenticator", {
    options: { protocol: "ctap2", transport: "internal", hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true },
  });
  return { cdp, authenticatorId, held: async () => (await cdp.send("WebAuthn.getCredentials", { authenticatorId })).credentials };
}
const openSignIn = async (page) => {
  await page.goto(HOST + "/account");
  await page.getByRole("button", { name: "Sign in or create account" }).click();
  return page.locator("#auth-dialog");
};

test("add a passkey on the account page, sign out, and sign back in to the same account with it", async ({ page, context }) => {
  const run = Date.now().toString(36), user = `google:pia-${run}`;
  const device = await faceID(page);
  await signIn(context, user, "Pia Grant", `pia-${run}@example.test`);
  await page.goto(HOST + "/account");
  await expect(page.getByRole("heading", { name: /Welcome, Pia/ })).toBeVisible({ timeout: 30000 });
  const setting = page.locator('[data-setting="passkeys"]');
  await setting.getByRole("button", { name: "Add a passkey" }).click();
  await expect(page.getByText("Passkey added")).toBeVisible();
  await expect(setting.locator(".passkey-list li")).toHaveCount(1);
  await expect(setting).toContainText("Chrome on Mac");
  // The device holds it, as a discoverable passkey for this site.
  const held = await device.held();
  expect(held.length).toBe(1);
  expect(held[0].rpId).toBe("localhost");
  expect(held[0].isResidentCredential).toBe(true);

  await context.clearCookies();
  const dialog = await openSignIn(page);
  await dialog.getByRole("button", { name: /Sign in with a passkey/ }).click();
  await expect(page).toHaveURL(/\/account$/);
  await expect(page.getByRole("heading", { name: /Welcome, Pia/ })).toBeVisible({ timeout: 30000 });
  await expect(page.locator('[data-setting="passkeys"] .passkey-list li')).toContainText("last used");
  // The same account, not a new one.
  const db = new Database(path.join(DATA, "marracat.sqlite"), { readonly: true });
  expect(db.prepare("SELECT COUNT(*) n FROM users WHERE id LIKE 'passkey:%'").get().n).toBe(0);
  expect(db.prepare("SELECT user_id FROM user_identities WHERE identity=?").get("passkey:" + (await page.evaluate(async () => (await (await fetch("/api/passkeys")).json()).passkeys[0].id))).user_id).toBe(user);
  db.close();
});

test("a removed passkey no longer signs in, and says so", async ({ page, context }) => {
  const run = Date.now().toString(36);
  await faceID(page);
  await signIn(context, `google:quinn-${run}`, "Quinn Hale", `quinn-${run}@example.test`);
  await page.goto(HOST + "/account");
  const setting = page.locator('[data-setting="passkeys"]');
  await setting.getByRole("button", { name: "Add a passkey" }).click();
  await expect(setting.locator(".passkey-list li")).toHaveCount(1);
  await setting.getByRole("button", { name: /Remove passkey/ }).click();
  await expect(page.getByText("Passkey removed")).toBeVisible();
  await expect(setting.locator(".passkey-list li")).toHaveCount(0);
  await context.clearCookies();
  const dialog = await openSignIn(page);
  await dialog.getByRole("button", { name: /Sign in with a passkey/ }).click();
  await expect(dialog.getByRole("alert")).toContainText("isn't on a Marracat account");
  await expect(page.getByRole("heading", { name: /Welcome/ })).toHaveCount(0);
});

test("closing the device's sheet is not an error", async ({ page }) => {
  const device = await faceID(page);
  // No person present: the device never signs, as when the sheet is dismissed.
  await device.cdp.send("WebAuthn.setAutomaticPresenceSimulation", { authenticatorId: device.authenticatorId, enabled: false });
  const dialog = await openSignIn(page);
  await dialog.getByRole("button", { name: /Sign in with a passkey/ }).click();
  await page.waitForTimeout(1500);
  await expect(dialog.getByRole("alert")).toHaveCount(0);
});
