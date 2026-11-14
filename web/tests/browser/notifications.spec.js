import { test, expect } from "./fixtures.js";
import { authCore } from "../auth-core.js";
const { encode } = await authCore("/jwt");
import Database from "better-sqlite3";
import path from "node:path";
import { createECDH } from "node:crypto";

// Notifications in the browser (owner, 2026-11-10). The account page offers
// them under "On this device"; nothing asks for permission until the button
// is pressed. Signed-in tests need the local server's secret and data
// directory, as tests/browser/social.spec.js does.
const SECRET = process.env.TEST_AUTH_SECRET;
const DATA = process.env.TEST_DATA_DIR;
const COOKIE = "authjs.session-token";

async function signIn(context, baseURL, id, name, email) {
  const db = new Database(path.join(DATA, "marracat.sqlite"));
  db.prepare("INSERT OR IGNORE INTO users(id,name,email) VALUES(?,?,?)").run(id, name, email);
  db.close();
  const value = await encode({ token: { sub: id, name, email }, secret: SECRET, salt: COOKIE });
  await context.addCookies([{ name: COOKIE, value, domain: new URL(baseURL).hostname, path: "/", httpOnly: true, sameSite: "Lax" }]);
}
const rows = (userID) => {
  const db = new Database(path.join(DATA, "marracat.sqlite"), { readonly: true });
  try {
    return db.prepare("SELECT endpoint FROM web_push_subs WHERE user_id=?").all(userID).map((r) => r.endpoint);
  } finally {
    db.close();
  }
};
/// A stand-in for the browser's push service: headless Chrome has none. The
/// page still asks permission, subscribes, and tells our server.
async function fakePushService(page, endpoint) {
  const browser = createECDH("prime256v1");
  browser.generateKeys();
  await page.addInitScript(({ endpoint, p256dh }) => {
    let live = null, asked = 0;
    const make = () => ({ endpoint, toJSON: () => ({ endpoint, keys: { p256dh, auth: "AwMDAwMDAwMDAwMDAwMDAw" } }), unsubscribe: async () => { live = null; return true; } });
    PushManager.prototype.subscribe = async function (options) { window.__subscribedWith = options; return (live = make()); };
    PushManager.prototype.getSubscription = async () => live;
    window.__permissionAsks = () => asked;
    const real = Notification.requestPermission.bind(Notification);
    Notification.requestPermission = async () => { asked++; return real(); };
  }, { endpoint, p256dh: browser.getPublicKey().toString("base64url") });
}

test("signed out, the account page offers no device settings and asks for nothing", async ({ page }) => {
  await page.goto("/account");
  await expect(page.getByRole("button", { name: /Sign in or create account/ })).toBeVisible({ timeout: 30000 });
  await expect(page.locator(".account-device")).toHaveCount(0);
});

test.describe("signed in", () => {
  test.skip(!(SECRET && DATA), "set TEST_AUTH_SECRET and TEST_DATA_DIR to match the local server");
  const run = Date.now().toString(36);

  test("turning notifications on asks once, registers this browser, and turning them off forgets it", async ({ browser, baseURL }) => {
    const context = await browser.newContext({ serviceWorkers: "allow", permissions: ["notifications"] });
    const page = await context.newPage();
    const user = `google:nora-${run}`, endpoint = `https://fcm.googleapis.com/fcm/send/journey-${run}`;
    await signIn(context, baseURL, user, "Nora Bell", `nora-${run}@example.test`);
    await fakePushService(page, endpoint);
    // Who answered /auth/session, if the page comes up signed out.
    const session = [];
    page.on("response", (r) => { if (r.url().includes("/auth/session") || r.url().includes("/api/push/")) session.push(`${r.status()} ${new URL(r.url()).pathname}`); });
    await page.goto("/account");
    await page.getByRole("heading", { name: /Welcome, Nora/ }).waitFor({ timeout: 30000 }).catch(() => {
      throw Error("signed out on /account; responses: " + session.join(", "));
    });
    const setting = page.locator('[data-setting="notifications"]');
    await expect(setting).toHaveAttribute("data-state", "off", { timeout: 30000 });
    // Nothing was asked for just by opening the page.
    expect(await page.evaluate(() => window.__permissionAsks())).toBe(0);
    await setting.getByRole("button", { name: "Turn on" }).click();
    await expect(setting).toHaveAttribute("data-state", "on");
    await expect(page.getByText("Notifications are on for this browser")).toBeVisible();
    expect(await page.evaluate(() => window.__permissionAsks())).toBe(1);
    expect(await page.evaluate(() => window.__subscribedWith.userVisibleOnly)).toBe(true);
    expect(await page.evaluate(() => window.__subscribedWith.applicationServerKey.length)).toBe(65);
    expect(rows(user)).toEqual([endpoint]);
    await setting.getByRole("button", { name: "On" }).click();
    await expect(setting).toHaveAttribute("data-state", "off");
    expect(rows(user)).toEqual([]);
    await context.close();
  });

  // 2026-11-12: signing out left the shopper's name, email, phone and address
  // (and what they searched and opened) in the browser for whoever used it next.
  test("signing out clears the checkout details and browsing history this browser kept", async ({ browser, baseURL }) => {
    const context = await browser.newContext();
    const page = await context.newPage();
    await signIn(context, baseURL, `google:pat-${run}`, "Pat Lane", `pat-${run}@example.test`);
    await page.goto("/account");
    await page.getByRole("heading", { name: /Welcome, Pat/ }).waitFor({ timeout: 30000 });
    await page.evaluate(() => {
      localStorage.setItem("marracat-buyer", JSON.stringify({ email: "pat@example.test", firstName: "Pat", lastName: "Lane", phone: "7185550100", address1: "1 Main St", city: "Brooklyn", province: "NY", zip: "11201", country: "US" }));
      localStorage.setItem("marracat-recent", JSON.stringify({ searches: ["bag charms"], viewed: ["koba-1"] }));
      localStorage.setItem("marracat-saved", JSON.stringify(["koba-1"]));
    });
    await page.reload();
    await page.getByRole("heading", { name: /Welcome, Pat/ }).waitFor({ timeout: 30000 });
    await page.getByRole("button", { name: "Sign out" }).click();
    await expect(page.getByText("You are signed out")).toBeVisible({ timeout: 15000 });
    await expect.poll(() => page.evaluate(() => [localStorage.getItem("marracat-buyer"), localStorage.getItem("marracat-recent")])).toEqual([null, null]);
    expect(await page.evaluate(() => localStorage.getItem("marracat-saved"))).toBe('["koba-1"]');
    await context.close();
  });

  // 2026-11-12: the website had no way to delete an account ("email us").
  test("Delete account asks for the emailed code, then signs this browser out and clears what it kept", async ({ browser, baseURL }) => {
    const context = await browser.newContext();
    const page = await context.newPage();
    await signIn(context, baseURL, `email:dee-${run}`, "Dee Moss", `dee-${run}@example.test`);
    const calls = [];
    await page.route("**/api/account/delete/code", (r) => { calls.push("code"); r.fulfill({ status: 204 }); });
    await page.route("**/api/account", (r) => {
      if (r.request().method() !== "DELETE") return r.fallback();
      const code = r.request().postDataJSON().code;
      calls.push(`delete ${code}`);
      r.fulfill(code === "424242" ? { status: 204 } : { status: 401, contentType: "application/json", body: JSON.stringify({ error: "That code isn't right or has expired. Ask for a new one." }) });
    });
    await page.goto("/account");
    await page.getByRole("heading", { name: /Welcome, Dee/ }).waitFor({ timeout: 30000 });
    await page.evaluate(() => {
      localStorage.setItem("marracat-buyer", JSON.stringify({ email: "dee@example.test", firstName: "Dee" }));
      localStorage.setItem("marracat-saved", JSON.stringify(["koba-1"]));
    });
    await page.reload();
    await page.getByRole("button", { name: "Delete account" }).click();
    const panel = page.locator(".account-delete");
    await expect(panel).toHaveAttribute("data-how", "email");
    await expect(panel).toContainText(`we'll email a code to dee-${run}@example.test`);
    await panel.getByRole("button", { name: "Email me a code" }).click();
    const field = panel.getByLabel("Deletion code");
    await field.fill("111111");
    await panel.getByRole("button", { name: "Delete my account" }).click();
    await expect(page.getByText("That code isn't right or has expired")).toBeVisible();
    await field.fill("424242");
    await panel.getByRole("button", { name: "Delete my account" }).click();
    await expect(page.getByText("Your Marracat account has been deleted")).toBeVisible({ timeout: 15000 });
    expect(calls).toEqual(["code", "delete 111111", "delete 424242"]);
    await expect.poll(() => page.evaluate(() => [localStorage.getItem("marracat-buyer"), localStorage.getItem("marracat-saved")])).toEqual([null, "[]"]);
    await context.close();
  });

  test("a browser told to block notifications says so instead of asking again", async ({ browser, baseURL }) => {
    const context = await browser.newContext({ serviceWorkers: "allow" });
    const page = await context.newPage();
    await signIn(context, baseURL, `google:omar-${run}`, "Omar Reed", `omar-${run}@example.test`);
    await page.addInitScript(() => Object.defineProperty(Notification, "permission", { get: () => "denied" }));
    await page.goto("/account");
    const setting = page.locator('[data-setting="notifications"]');
    await expect(setting).toHaveAttribute("data-state", "blocked", { timeout: 30000 });
    await expect(setting.getByRole("button")).toHaveCount(0);
    await expect(setting).toContainText("site settings");
    await context.close();
  });
});
