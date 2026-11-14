import { test, expect } from "./fixtures.js";
import { authCore } from "../auth-core.js";
const { encode } = await authCore("/jwt");
import Database from "better-sqlite3";
import path from "node:path";

// Comments, sharing, profiles and end-to-end encrypted sends, in a real browser.
//
// Signed-in tests need the local server's AUTH_SECRET and DATA_DIR, so they
// can seed people and mint a genuine Auth.js session cookie; nothing in the
// app is bypassed. Run the server with the same values, for example:
//   DATA_DIR=/tmp/mc AUTH_SECRET=<hex> OWNER_EMAILS=owner@example.test AUTH_RATE_LIMIT=1000 PORT=3107 node server/index.js
//   TEST_DATA_DIR=/tmp/mc TEST_AUTH_SECRET=<hex> npx playwright test
const SECRET = process.env.TEST_AUTH_SECRET;
const DATA = process.env.TEST_DATA_DIR;
const signedInReady = !!(SECRET && DATA);
const COOKIE = "authjs.session-token";

async function signIn(context, baseURL, id, name, email) {
  const db = new Database(path.join(DATA, "marracat.sqlite"));
  db.prepare("INSERT OR IGNORE INTO users(id,name,email) VALUES(?,?,?)").run(id, name, email);
  db.close();
  const value = await encode({ token: { sub: id, name, email }, secret: SECRET, salt: COOKIE });
  const url = new URL(baseURL);
  await context.addCookies([{ name: COOKIE, value, domain: url.hostname, path: "/", httpOnly: true, sameSite: "Lax" }]);
}

async function anyProductID(page) {
  const catalog = await page.evaluate(async () => (await fetch("/api/catalog?v=3")).json());
  return catalog.products.find((p) => p.available && p.images?.length).id;
}

test("signed out: product page shows comments and a sign-in prompt", async ({ page }) => {
  await page.goto("/");
  const id = await anyProductID(page);
  await page.goto(`/#/product?id=${encodeURIComponent(id)}`);
  const comments = page.getByTestId("comments");
  await expect(comments).toBeVisible({ timeout: 30000 });
  await expect(comments.getByRole("heading", { name: /Comments/ })).toBeVisible();
  await comments.getByRole("button", { name: "Sign in to comment" }).click();
  await expect(page.locator("#auth-dialog")).toBeVisible();
});

test("share uses the /p/<id> link, and that link lands on the product", async ({ page }) => {
  await page.addInitScript(() => {
    window.__shared = null;
    navigator.share = async (data) => {
      window.__shared = data;
    };
  });
  await page.goto("/");
  const id = await anyProductID(page);
  await page.goto(`/#/product?id=${encodeURIComponent(id)}`);
  // An old "#/" link opens the same product at its real address.
  const own = new RegExp(`/p/${encodeURIComponent(id).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}$`);
  await expect(page).toHaveURL(own);
  await page.getByTestId("share-button").click();
  const shared = await page.evaluate(() => window.__shared);
  expect(shared.url).toBe(`https://marracat.com/p/${encodeURIComponent(id)}`);
  // The link itself stays the crawlable /p/<id> (SEO, 2026-10-09; it used to
  // turn into "#/product?id=").
  await page.goto(`/p/${encodeURIComponent(id)}`);
  await expect(page).toHaveURL(own);
  await expect(page.getByTestId("comments")).toBeVisible({ timeout: 30000 });
});

test("share falls back to copying the link", async ({ page, context }) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await page.addInitScript(() => {
    delete Navigator.prototype.share;
  });
  await page.goto("/");
  const id = await anyProductID(page);
  await page.goto(`/#/product?id=${encodeURIComponent(id)}`);
  await page.getByTestId("share-button").click();
  await expect(page.getByText("Link copied")).toBeVisible();
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(`https://marracat.com/p/${encodeURIComponent(id)}`);
});

test.describe("signed in", () => {
  test.skip(!signedInReady, "set TEST_AUTH_SECRET and TEST_DATA_DIR to match the local server");
  const run = Date.now().toString(36);

  test("commenting: guidelines once, post, reply, delete, and the profile it links to", async ({ page, context, baseURL }) => {
    await signIn(context, baseURL, `google:alice-${run}`, "Alice Adams", `alice-${run}@example.test`);
    await page.goto("/");
    const id = await anyProductID(page);
    await page.goto(`/#/product?id=${encodeURIComponent(id)}`);
    const comments = page.getByTestId("comments");
    const said = `Love the texture on this (${run})`;
    await comments.getByRole("textbox", { name: "Add a comment" }).fill(said);
    await comments.getByRole("button", { name: "Post" }).click();
    const guidelines = page.getByRole("dialog", { name: "Community guidelines" });
    await expect(guidelines).toBeVisible();
    await guidelines.getByRole("button", { name: "I agree" }).click();
    const thread = comments.locator(".thread").filter({ hasText: said });
    await expect(thread).toBeVisible();
    // Reply: one level only.
    await thread.getByRole("button", { name: "Reply" }).first().click();
    await comments.getByRole("textbox", { name: /Reply to/ }).fill("Update: still love it");
    await comments.getByRole("button", { name: "Post reply" }).click();
    await expect(thread.locator(".replies").getByText("Update: still love it")).toBeVisible();
    // The filter's message shows inline.
    await comments.getByRole("textbox", { name: "Add a comment" }).fill("buy at brand.com");
    await comments.getByRole("button", { name: "Post" }).click();
    await expect(comments.getByRole("alert")).toContainText("Links can");
    await comments.getByRole("textbox", { name: "Add a comment" }).fill("");
    // Delete the reply.
    page.once("dialog", (d) => d.accept());
    await thread.locator(".replies").getByRole("button", { name: "More actions" }).click();
    await thread.getByRole("menuitem", { name: "Delete" }).click();
    await expect(thread.locator(".replies")).toHaveCount(0);
    // The author name links to a profile.
    await thread.locator(".comment-author").first().click();
    await expect(page.getByTestId("profile-page").getByRole("heading", { name: "Alice A." })).toBeVisible();
    await expect(page.getByRole("link", { name: "Edit your profile" })).toBeVisible();
  });

  test("friends, then an end-to-end encrypted share that only the friend's browser opens", async ({ browser, baseURL }) => {
    const aliceCtx = await browser.newContext({ baseURL });
    const bobCtx = await browser.newContext({ baseURL });
    await signIn(aliceCtx, baseURL, `google:alicef-${run}`, "Alice Friend", `alicef-${run}@example.test`);
    await signIn(bobCtx, baseURL, `google:bobf-${run}`, "Bob Friend", `bobf-${run}@example.test`);
    const alice = await aliceCtx.newPage(), bob = await bobCtx.newPage();

    // Bob opens his account: that registers his browser's key, and shows his handle.
    await bob.goto("/#/account");
    const bobHandle = (await bob.getByRole("textbox", { name: "Handle" }).inputValue({ timeout: 30000 }));
    await bob.waitForFunction(async () => {
      const dbs = await indexedDB.databases();
      return dbs.some((d) => d.name === "marracat-keys");
    });

    // Alice finds Bob and sends a request; Bob accepts.
    await alice.goto(`/#/u/${bobHandle}`);
    await alice.getByRole("button", { name: "Add friend" }).click();
    await expect(alice.getByRole("button", { name: "Requested" })).toBeVisible();
    await bob.reload();
    await bob.getByRole("tab", { name: /Friends/ }).click();
    await bob.getByTestId("friends").getByRole("button", { name: "Accept" }).click();
    await expect(bob.getByTestId("friends").getByText("Alice F.")).toBeVisible();

    // Alice sends a product with a note.
    await alice.goto("/");
    const id = await anyProductID(alice);
    await alice.goto(`/#/product?id=${encodeURIComponent(id)}`);
    await alice.getByRole("button", { name: "Send to friends" }).click();
    const send = alice.getByRole("dialog", { name: "Send to friends" });
    await expect(send.getByText(/End-to-end encrypted/)).toBeVisible();
    await send.getByRole("checkbox").check();
    await send.getByRole("textbox", { name: "Add a note" }).fill("For your wash day");
    await send.getByRole("button", { name: "Send" }).click();
    await alice.getByRole("dialog", { name: "Community guidelines" }).getByRole("button", { name: "I agree" }).click();
    await expect(alice.getByText("Sent")).toBeVisible();

    // The server holds nothing readable.
    const db = new Database(path.join(DATA, "marracat.sqlite"), { readonly: true });
    const stored = JSON.stringify(db.prepare("SELECT * FROM share_envelopes").all());
    db.close();
    expect(stored).not.toContain("wash day");
    expect(stored).not.toContain(id);

    // Bob's browser opens it.
    await bob.reload();
    await bob.getByRole("tab", { name: /Shared with you/ }).click();
    const inbox = bob.getByTestId("inbox");
    await expect(inbox.getByText("“For your wash day”")).toBeVisible();
    await expect(inbox.getByText("Alice F.")).toBeVisible();

    await aliceCtx.close();
    await bobCtx.close();
  });

  test("the moderation queue is the owner's alone", async ({ page, context, baseURL }) => {
    await signIn(context, baseURL, `google:carl-${run}`, "Carl Case", `carl-${run}@example.test`);
    await page.goto("/#/moderation");
    await expect(page.getByRole("heading", { name: "Nothing here." })).toBeVisible({ timeout: 30000 });
  });
});
