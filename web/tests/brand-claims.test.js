import { test } from "node:test";
import assert from "node:assert/strict";
import { emailMatchesBrand, bareHost } from "../server/brand-claims.js";

// Claiming a brand: a one-time link to an address at its own domain.
test("only an address at the brand's own domain counts", () => {
  assert.equal(emailMatchesBrand("ade@diarrablu.com", "diarrablu.com"), true);
  assert.equal(emailMatchesBrand("Ade@Shop.DiarraBlu.com", "www.diarrablu.com"), true, "subdomain, any case, www stripped");
  assert.equal(emailMatchesBrand("ade@gmail.com", "diarrablu.com"), false);
  assert.equal(emailMatchesBrand("ade@diarrablu.com.evil.io", "diarrablu.com"), false);
  assert.equal(emailMatchesBrand("x@notdiarrablu.com", "diarrablu.com"), false, "suffix of another word");
  assert.equal(emailMatchesBrand("a@store.myshopify.com", "store.myshopify.com"), false, "shared platform domains never count");
  assert.equal(bareHost("www.boldenusa.com"), "boldenusa.com");
});

// Audit 2026-10-07 (M4): opening the link changes nothing; only a POST from
// the same signed-in account confirms it. Email caps are per requester.
import Database from "better-sqlite3";
import express from "express";
import { brandClaimRoutes } from "../server/brand-claims.js";

async function claimServer() {
  const db = new Database(":memory:");
  const mails = [];
  let who = null;
  const app = express();
  brandClaimRoutes(app, db, {
    env: { PUBLIC_URL: "https://marracat.com" }, mailer: async (m) => mails.push(m),
    viewer: async () => who, brandLookup: (id) => ({ b1: { id: "b1", name: "Diarra Blu", domain: "diarrablu.com" }, b2: { id: "b2", name: "Two", domain: "two.com" } })[id],
  });
  const server = app.listen(0, "127.0.0.1"); await new Promise((r) => server.once("listening", r));
  const base = `http://127.0.0.1:${server.address().port}/api/brand-claims`;
  const as = (id) => { who = id ? { id, email: `${id}@example.com` } : null; };
  const ask = (brand, email) => fetch(`${base}/email`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ brand, email }) });
  const tokenOf = (m) => m.text.match(/token=([a-f0-9]{48})/)[1];
  const confirm = (token, headers = {}) => fetch(`${base}/confirm`, { method: "POST", redirect: "manual",
    headers: { "Content-Type": "application/x-www-form-urlencoded", Origin: "https://marracat.com", ...headers }, body: `token=${token}` });
  return { db, mails, as, ask, tokenOf, confirm, base, close: () => server.close() };
}

test("GET /confirm shows a page with a POST button and grants nothing", async () => {
  const t = await claimServer();
  t.as("u1");
  assert.equal((await t.ask("b1", "ade@diarrablu.com")).status, 201);
  const token = t.tokenOf(t.mails[0]);
  const page = await fetch(`${t.base}/confirm?token=${token}`, { redirect: "manual" });
  assert.equal(page.status, 200);
  const html = await page.text();
  assert.match(html, /<form method="post" action="\/api\/brand-claims\/confirm">/);
  assert.match(html, /Diarra Blu/);
  assert.equal(page.headers.get("referrer-policy"), "no-referrer");
  assert.equal(t.db.prepare("SELECT COUNT(*) n FROM brand_admins").get().n, 0);
  t.close();
});

test("only the account that asked can confirm, and only once", async () => {
  const t = await claimServer();
  t.as("u1");
  await t.ask("b1", "ade@diarrablu.com");
  const token = t.tokenOf(t.mails[0]);
  t.as(null);
  assert.match((await t.confirm(token)).headers.get("location"), /claim=signin/);
  t.as("u2");
  assert.match((await t.confirm(token)).headers.get("location"), /claim=account/);
  assert.equal((await t.confirm(token, { Origin: "https://evil.example" })).status, 403);
  // 2026-11-12: a post that names no origin used to pass the check.
  assert.equal((await t.confirm(token, { Origin: "" })).status, 403);
  t.as("u1");
  assert.match((await t.confirm(token)).headers.get("location"), /claim=verified/);
  assert.deepEqual(t.db.prepare("SELECT brand_id, user_id, role FROM brand_admins").all(), [{ brand_id: "b1", user_id: "u1", role: "owner" }]);
  assert.match((await t.confirm(token)).headers.get("location"), /claim=used/);
  t.close();
});

test("one account's requests can't use up a brand's links for others", async () => {
  const t = await claimServer();
  t.as("spammer");
  for (let i = 0; i < 3; i++) assert.equal((await t.ask("b1", "x@diarrablu.com")).status, 201);
  assert.equal((await t.ask("b1", "x@diarrablu.com")).status, 429);
  t.as("owner");
  assert.equal((await t.ask("b1", "ade@diarrablu.com")).status, 201, "the real owner still gets a link");
  t.close();
});
