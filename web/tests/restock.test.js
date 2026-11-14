import { test } from "node:test";
import assert from "node:assert/strict";
import express from "express";
import Database from "better-sqlite3";
import { createHash, generateKeyPairSync, verify as verifySignature } from "node:crypto";
import { writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { EventEmitter } from "node:events";
import { restockRoutes, checkRestocks, watchable, inStock, apnsSender } from "../server/restock.js";

const products = {
  tote: { id: "tote", brand: "curves", title: "Knit Tote", url: "https://shop.example.com/products/knit-tote" },
  tee: { id: "tee", brand: "curves", title: "Tee", url: "https://shop.example.com/products/tee/" },
  woo: { id: "woo", brand: "woostore", title: "Candle", url: "https://woo.example.com/product/candle" },
  odd: { id: "odd", brand: "curves", title: "Odd", url: "http://shop.example.com/products/odd" },
};
const brands = {
  curves: { id: "curves", name: "Curves", platform: "shopify" },
  woostore: { id: "woostore", name: "Woo", platform: "woocommerce" },
};
const lookup = { productRecord: (id) => products[id], brandRecord: (id) => brands[id] };
const key = (c) => c.repeat(64);

const sha = (v) => createHash("sha256").update(v).digest("hex");
// Sessions: token key("1") is Ada (ada@example.com), key("2") is Bo.
const USERS = [["apple:ada", "Ada Lovelace", "ada@example.com", key("1")], ["google:bo", "Bo", "bo@example.com", key("2")]];

async function fixture(t, apns = { send: async () => ({ status: 200, environment: "production" }) }) {
  const db = new Database(":memory:");
  db.exec(`CREATE TABLE users (id TEXT PRIMARY KEY, name TEXT, email TEXT);
    CREATE TABLE mobile_sessions (hash TEXT PRIMARY KEY, user_id TEXT NOT NULL, expires INTEGER NOT NULL);
    CREATE TABLE mobile_accounts (user_id TEXT PRIMARY KEY, generation TEXT NOT NULL);`);
  for (const [id, name, email, token] of USERS) {
    db.prepare("INSERT INTO users VALUES(?,?,?)").run(id, name, email);
    db.prepare("INSERT INTO mobile_sessions VALUES(?,?,?)").run(sha(token), id, Date.now() + 60_000);
    db.prepare("INSERT INTO mobile_accounts VALUES(?,?)").run(id, "g");
  }
  const app = express();
  restockRoutes(app, db, { apns, mail: null, lookup, schedule: false });
  const server = app.listen(0, "127.0.0.1");
  await new Promise((r) => server.once("listening", r));
  t.after(() => { server.close(); db.close(); });
  const base = `http://127.0.0.1:${server.address().port}/api/restock/`;
  const call = async (p, device, body, method = body ? "POST" : "GET", session) => {
    const headers = { "Content-Type": "application/json", ...(device ? { "X-Marracat-Device": device } : {}) };
    if (session) headers.Authorization = "Bearer " + session;
    const r = await fetch(base + p, { method, headers, body: body ? JSON.stringify(body) : undefined });
    return { status: r.status, data: r.status === 204 ? null : await r.json() };
  };
  return { db, call };
}

test("watchable only takes Shopify product pages over https", () => {
  assert.equal(watchable("tote", lookup).url, "https://shop.example.com/products/knit-tote.js");
  assert.equal(watchable("tee", lookup).url, "https://shop.example.com/products/tee.js");
  assert.equal(watchable("woo", lookup), null);
  assert.equal(watchable("odd", lookup), null);
  assert.equal(watchable("missing", lookup), null);
});

test("inStock reads the whole product or one option", () => {
  const live = { available: false, variants: [{ id: 1, available: false }, { id: 2, available: true }] };
  assert.equal(inStock(live, ""), true);
  assert.equal(inStock(live, "1"), false);
  assert.equal(inStock(live, "2"), true);
  assert.equal(inStock({ available: false, variants: [{ id: 1, available: false }] }, ""), false);
  assert.equal(inStock(null, ""), false);
});

test("alerts need a signed-in account and a watchable product; accounts can't see each other's", async (t) => {
  const { call } = await fixture(t);
  const a = key("a"), b = key("b"), ada = key("1"), bo = key("2");
  assert.equal((await call("alerts", null, undefined, "GET", ada)).status, 401);
  assert.equal((await call("alerts", "short", undefined, "GET", ada)).status, 401);
  // Signed out: no alerts, even with a push token.
  assert.equal((await call("device", a, { token: key("9"), environment: "production" }, "PUT")).status, 204);
  const out = await call("alerts", a, { productID: "tote" });
  assert.equal(out.status, 401);
  assert.equal(out.data.error, "Sign in to get restock alerts");
  assert.equal((await call("alerts", a, undefined, "GET", key("7"))).status, 401, "an unknown session is signed out");
  assert.equal((await call("device", a, { token: "zz", environment: "production" }, "PUT")).status, 400);
  assert.equal((await call("device", a, { token: key("1"), environment: "elsewhere" }, "PUT")).status, 400);
  assert.equal((await call("alerts", a, { productID: "woo" }, "POST", ada)).status, 422);
  assert.equal((await call("alerts", a, { productID: "tote", variantID: "x1" }, "POST", ada)).status, 400);
  // Notifications off is fine: the email still goes.
  const made = await call("alerts", b, { productID: "tote", variantID: "52294910411026" }, "POST", ada);
  assert.equal(made.status, 201);
  assert.deepEqual(made.data.alerts.map((x) => [x.productID, x.variantID]), [["tote", "52294910411026"]]);
  // The alert follows the account to another phone, and only that account.
  assert.equal((await call("alerts", a, undefined, "GET", ada)).data.alerts.length, 1);
  assert.deepEqual((await call("alerts", a, undefined, "GET", bo)).data.alerts, []);
  await call("alerts", a, { productID: "tote", variantID: "52294910411026" }, "DELETE", bo);
  assert.equal((await call("alerts", a, undefined, "GET", ada)).data.alerts.length, 1);
  const removed = await call("alerts", a, { productID: "tote", variantID: "52294910411026" }, "DELETE", ada);
  assert.deepEqual(removed.data.alerts, []);
});

test("when an item is back: one email and a push to each signed-in phone, then never again", async (t) => {
  const sent = [];
  const apns = { send: async (device, payload) => { sent.push({ device, payload }); return { status: 200, environment: "sandbox" }; } };
  const { db, call } = await fixture(t, apns);
  const phone = key("c"), ipad = key("d"), signedOut = key("e"), ada = key("1");
  for (const [device, token] of [[phone, key("2")], [ipad, key("3")], [signedOut, key("4")]])
    await call("device", device, { token, environment: "production" }, "PUT");
  await call("alerts", phone, { productID: "tote" }, "POST", ada);
  await call("alerts", ipad, { productID: "tee", variantID: "7" }, "POST", ada);
  // signedOut was signed in once, then signed out.
  await call("alerts", signedOut, undefined, "GET", ada);
  assert.equal((await call("link", signedOut, undefined, "DELETE")).status, 204);
  let stock = { tote: false, tee: false };
  const fetched = [];
  const fetcher = async (url) => {
    fetched.push(url);
    const id = url.includes("knit-tote") ? "tote" : "tee";
    return { ok: true, text: async () => JSON.stringify({ available: stock[id], variants: [{ id: 7, available: stock[id] }] }) };
  };
  const mails = [];
  const mail = async (m) => { mails.push(m); };
  let r = await checkRestocks(db, { apns, mail, fetcher, lookup, log: () => {} });
  assert.deepEqual(r, { products: 2, checked: 2, back: 0, sent: 0, emailed: 0 });
  stock.tote = true;
  r = await checkRestocks(db, { apns, mail, fetcher, lookup, log: () => {} });
  assert.equal(r.sent, 2, "both signed-in phones");
  assert.deepEqual(sent.map((s) => s.device.token).sort(), [key("2"), key("3")].sort());
  assert.equal(sent[0].payload.aps.alert.body, "Knit Tote is back in stock at Curves");
  assert.equal(sent[0].payload.productID, "tote");
  assert.equal(mails.length, 1);
  assert.equal(mails[0].to, "ada@example.com");
  assert.equal(mails[0].subject, "Back in stock: Knit Tote");
  assert.match(mails[0].text, /^Hi Ada,/);
  assert.ok(mails[0].text.includes("https://marracat.com/p/tote"), "a universal link, so the app opens it");
  assert.ok(mails[0].html.includes('href="https://marracat.com/p/tote"'));
  // Fulfilled: gone from the list, never sent again, and the device's
  // environment follows where the push actually landed.
  assert.deepEqual((await call("alerts", phone, undefined, "GET", ada)).data.alerts.map((x) => x.productID), ["tee"]);
  r = await checkRestocks(db, { apns, mail, fetcher, lookup, log: () => {} });
  assert.equal(r.products, 1);
  assert.equal(sent.length, 2);
  assert.equal(mails.length, 1);
  assert.equal(db.prepare("SELECT environment FROM restock_devices WHERE token=?").get(key("2")).environment, "sandbox");
  // Only watched products are fetched, and only as .js product JSON.
  assert.ok(fetched.every((u) => /^https:\/\/shop\.example\.com\/products\/[a-z-]+\.js$/.test(u)));
});

test("the email alone delivers an alert; nothing delivered keeps it waiting", async (t) => {
  const { db, call } = await fixture(t, { send: async () => ({ status: 500, reason: "InternalServerError" }) });
  await call("alerts", key("f"), { productID: "tote" }, "POST", key("2"));
  const fetcher = async () => ({ ok: true, text: async () => JSON.stringify({ available: true, variants: [{ id: 1, available: true }] }) });
  let r = await checkRestocks(db, { apns: { send: async () => ({ status: 500 }) }, mail: async () => { throw Object.assign(new Error("x"), { code: "ECONNECTION" }); }, fetcher, lookup, log: () => {} });
  assert.equal(r.emailed, 0);
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM restock_watches WHERE fulfilled IS NULL").get().n, 1, "kept for the next run");
  const mails = [];
  r = await checkRestocks(db, { apns: { send: async () => ({ status: 500 }) }, mail: async (m) => { mails.push(m); }, fetcher, lookup, log: () => {} });
  assert.equal(r.emailed, 1);
  assert.equal(mails[0].to, "bo@example.com");
  assert.ok(!mails[0].html.includes("<script"), "html is escaped");
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM restock_watches WHERE fulfilled IS NULL").get().n, 0);
});

test("a 410 from APNs drops that phone but keeps the account's alerts", async (t) => {
  const apns = { send: async () => ({ status: 410, reason: "Unregistered" }) };
  const { db, call } = await fixture(t, apns);
  const a = key("b");
  await call("device", a, { token: key("3"), environment: "production" }, "PUT");
  await call("alerts", a, { productID: "tote" }, "POST", key("1"));
  const fetcher = async () => ({ ok: true, text: async () => JSON.stringify({ available: true, variants: [{ id: 1, available: true }] }) });
  await checkRestocks(db, { apns, fetcher, lookup, log: () => {} });
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM restock_devices").get().n, 0);
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM restock_links").get().n, 0);
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM restock_watches WHERE fulfilled IS NULL").get().n, 1);
});

test("a store that times out or answers junk doesn't stop the run", async (t) => {
  const { db, call } = await fixture(t);
  const a = key("e");
  await call("device", a, { token: key("4"), environment: "production" }, "PUT");
  await call("alerts", a, { productID: "tote" }, "POST", key("1"));
  await call("alerts", a, { productID: "tee" }, "POST", key("1"));
  const fetcher = async (url) => {
    if (url.includes("tee")) throw new Error("timeout");
    return { ok: true, text: async () => "<html>" };
  };
  const r = await checkRestocks(db, { apns: { send: async () => ({ status: 200 }) }, fetcher, lookup, log: () => {} });
  assert.deepEqual(r, { products: 2, checked: 2, back: 0, sent: 0, emailed: 0 });
});

test("APNs sender signs ES256 as raw r||s and retries the other host on BadDeviceToken", async () => {
  const dir = mkdtempSync(path.join(tmpdir(), "apns-"));
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const keyPath = path.join(dir, "key.p8");
  writeFileSync(keyPath, privateKey.export({ type: "pkcs8", format: "pem" }));
  const hosts = [];
  let headersSeen;
  const connectTo = (host) => {
    hosts.push(host);
    const session = new EventEmitter();
    session.close = () => {};
    session.request = (headers) => {
      headersSeen = headers;
      const req = new EventEmitter();
      req.setTimeout = () => {};
      req.end = () => setImmediate(() => {
        const sandbox = host.includes("sandbox");
        req.emit("response", { ":status": sandbox ? 200 : 400 });
        if (!sandbox) req.emit("data", JSON.stringify({ reason: "BadDeviceToken" }));
        req.emit("close");
      });
      return req;
    };
    return session;
  };
  const apns = apnsSender({ APNS_KEY_PATH: keyPath, APNS_KEY_ID: "KEYID", APNS_TEAM_ID: "TEAM" }, { connectTo });
  const r = await apns.send({ token: key("5"), environment: "production" }, { aps: {} });
  assert.equal(r.status, 200);
  assert.equal(r.environment, "sandbox");
  assert.deepEqual(hosts, ["https://api.push.apple.com", "https://api.sandbox.push.apple.com"]);
  assert.equal(headersSeen["apns-topic"], "com.divinedavis.marracat");
  const [h, b, s] = headersSeen.authorization.replace("bearer ", "").split(".");
  assert.deepEqual(JSON.parse(Buffer.from(h, "base64url")), { alg: "ES256", kid: "KEYID" });
  assert.equal(JSON.parse(Buffer.from(b, "base64url")).iss, "TEAM");
  const sig = Buffer.from(s, "base64url");
  assert.equal(sig.length, 64);
  assert.ok(verifySignature("sha256", Buffer.from(`${h}.${b}`), { key: publicKey, dsaEncoding: "ieee-p1363" }, sig));
  assert.equal((await apnsSender({}).send({ token: key("5") }, {})).reason, "not_configured");
});

// Product pages read live stock (live-stock.js); each JSON the check reads is
// handed over, so the page a push opens agrees with the push (owner, 2026-10-11).
test("every live read is shared with the product page's stock, and a failing share doesn't stop the run", async (t) => {
  const { db, call } = await fixture(t);
  await call("alerts", key("e"), { productID: "tote" }, "POST", key("1"));
  const live = { available: true, variants: [{ id: 1, available: true }] };
  const fetcher = async () => ({ ok: true, text: async () => JSON.stringify(live) });
  const shared = [];
  await checkRestocks(db, { apns: { send: async () => ({ status: 200 }) }, fetcher, lookup, log: () => {}, onLive: (id, json) => shared.push([id, json]) });
  assert.deepEqual(shared, [["tote", live]]);
  await call("alerts", key("e"), { productID: "tote" }, "POST", key("1"));
  const r = await checkRestocks(db, { apns: { send: async () => ({ status: 200 }) }, fetcher, lookup, log: () => {}, onLive: () => { throw new Error("x"); } });
  assert.equal(r.back, 1);
});
