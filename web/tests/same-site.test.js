import { test } from "node:test";
import assert from "node:assert/strict";
import express from "express";
import { sameSiteWrites, fromOurPages, hasSessionCookie } from "../server/same-site.js";

async function server(t, env) {
  const app = express();
  app.use(sameSiteWrites(env));
  app.all(/.*/, (req, res) => res.json({ ok: true }));
  const s = app.listen(0, "127.0.0.1");
  await new Promise((r) => s.once("listening", r));
  t.after(() => s.close());
  return (path, method, headers = {}) => fetch(`http://127.0.0.1:${s.address().port}${path}`, { method, headers }).then((r) => r.status);
}
const COOKIE = "__Secure-authjs.session-token=abc.def";

// 2026-11-12: only /api/social checked where a signed-in browser's write came
// from; the account, cart, alert, passkey, notification and boost routes did not.
test("a signed-in browser's write must come from our own pages", async (t) => {
  const call = await server(t, { NODE_ENV: "production" });
  for (const path of ["/api/account/activity", "/api/cart", "/api/alerts/price", "/api/passkeys/x", "/api/push/subscribe", "/api/boosts/budget"]) {
    assert.equal(await call(path, "POST", { Cookie: COOKIE, Origin: "https://evil.example" }), 403, path);
    assert.equal(await call(path, "DELETE", { Cookie: COOKIE }), 403, `${path} with no origin at all`);
    assert.equal(await call(path, "POST", { Cookie: COOKIE, Origin: "https://marracat.com" }), 200, path);
    assert.equal(await call(path, "PUT", { Cookie: COOKIE, "Sec-Fetch-Site": "same-origin" }), 200, path);
  }
  assert.equal(await call("/api/cart", "POST", { Cookie: COOKIE, "Sec-Fetch-Site": "cross-site" }), 403);
  assert.equal(await call("/api/cart", "POST", { Cookie: COOKIE, Origin: "http://localhost:5173" }), 403, "localhost isn't ours in production");
});

test("reads, the app, signed-out browsers and Auth.js's own routes are left alone", async (t) => {
  const call = await server(t, { NODE_ENV: "production" });
  assert.equal(await call("/api/cart", "GET", { Cookie: COOKIE, Origin: "https://evil.example" }), 200);
  assert.equal(await call("/api/mobile/operations", "POST", { Authorization: `Bearer ${"a".repeat(64)}` }), 200, "the app sends no cookie");
  assert.equal(await call("/api/visit", "POST", { Origin: "https://evil.example" }), 200, "no session cookie, nothing to ride on");
  assert.equal(await call("/auth/callback/apple", "POST", { Cookie: COOKIE, Origin: "https://appleid.apple.com" }), 200);
});

test("a local server accepts its own localhost pages", async (t) => {
  const call = await server(t, { NODE_ENV: "development" });
  assert.equal(await call("/api/cart", "POST", { Cookie: "authjs.session-token=abc", Origin: "http://localhost:5173" }), 200);
  assert.equal(await call("/api/cart", "POST", { Cookie: "authjs.session-token=abc", Origin: "https://evil.example" }), 403);
});

test("the session cookie is recognised in each of its forms", () => {
  const req = (cookie) => ({ get: (h) => (h === "Cookie" ? cookie : undefined) });
  assert.ok(hasSessionCookie(req("a=1; __Secure-authjs.session-token=x")));
  assert.ok(hasSessionCookie(req("authjs.session-token.0=x; authjs.session-token.1=y")), "a chunked cookie");
  assert.ok(!hasSessionCookie(req("__Secure-authjs.callback-url=x; other=authjs.session-token")));
  assert.ok(!hasSessionCookie(req("")));
  assert.ok(!fromOurPages({ get: () => undefined }, {}));
});
