import { test } from "node:test";
import assert from "node:assert/strict";
import Database from "better-sqlite3";
import { installDealAlertSchema, checkDeals, droppedEnough, saleCounts } from "../server/deal-alerts.js";

const SECRET = "s".repeat(32);

test("a drop counts at 5% or more", () => {
  assert.equal(droppedEnough(100, 95), true);
  assert.equal(droppedEnough(100, 96), false);
  assert.equal(droppedEnough(100, 0), false);
});

test("sale counts are buyable, marked-down products per brand", () => {
  const c = saleCounts([{ brand: "a", available: true, price: 5, compare_at: 10 }, { brand: "a", available: false, price: 5, compare_at: 10 },
    { brand: "b", available: true, price: 5, compare_at: null }]);
  assert.deepEqual([...c], [["a", 1]]);
});

function setup() {
  const db = new Database(":memory:");
  db.exec(`CREATE TABLE users(id TEXT, name TEXT, email TEXT);
    CREATE TABLE restock_links(device TEXT PRIMARY KEY, user_id TEXT, updated INTEGER);
    CREATE TABLE restock_devices(hash TEXT PRIMARY KEY, token TEXT, environment TEXT, updated INTEGER);
    INSERT INTO users VALUES('u1','Dee Lee','dee@example.com');
    INSERT INTO restock_links VALUES('d1','u1',0); INSERT INTO restock_devices VALUES('d1','abc','production',0);`);
  installDealAlertSchema(db);
  return db;
}

test("price drops alert by push and email, once per drop", async () => {
  const db = setup();
  db.prepare("INSERT INTO price_watches(user_id,product_id,base_price,created) VALUES('u1','p1',50,0)").run();
  let price = 45;
  // A Big Cartel brand: no live check, the catalog's price.
  const lookup = { productRecord: () => ({ id: "p1", brand: "b", title: "Dress", price, available: true, currency: "USD", url: "https://x.bigcartel.com/product/d" }),
    brandRecord: () => ({ name: "Brand", platform: "bigcartel" }), allProducts: () => [] };
  const pushes = [], mails = [];
  const apns = { send: async (_d, payload) => (pushes.push(payload), { status: 200 }) };
  const mail = async (m) => mails.push(m);
  assert.equal((await checkDeals(db, { apns, mail, secret: SECRET, lookup, log: () => {} })).drops, 1);
  assert.match(pushes[0].aps.alert.body, /Dress is now \$45\.00 at Brand/);
  assert.match(mails[0].subject, /Price drop: Dress is now \$45\.00/);
  assert.equal((await checkDeals(db, { apns, mail, secret: SECRET, lookup, log: () => {} })).drops, 0, "no repeat at the same price");
  price = 42;
  assert.equal((await checkDeals(db, { apns, mail, secret: SECRET, lookup, log: () => {} })).drops, 1, "a further 5%+ drop alerts again");
});

test("a brand sale alerts when marked-down items reach 3, not on the first look", async () => {
  const db = setup();
  db.prepare("INSERT INTO brand_watches VALUES('u1','b',0,NULL)").run();
  let onSale = 1;
  const lookup = { productRecord: () => null, brandRecord: () => ({ name: "Brand" }),
    allProducts: () => Array.from({ length: onSale }, () => ({ brand: "b", available: true, price: 5, compare_at: 9 })) };
  const apns = { send: async () => ({ status: 200 }) };
  assert.equal((await checkDeals(db, { apns, mail: null, lookup, log: () => {} })).sales, 0, "first look records only");
  onSale = 4;
  assert.equal((await checkDeals(db, { apns, mail: null, lookup, log: () => {} })).sales, 1);
  assert.equal((await checkDeals(db, { apns, mail: null, lookup, log: () => {} })).sales, 0, "still on sale is not news");
});

test("a Shopify product's price is checked live, not from the catalog", async () => {
  const db = setup();
  db.prepare("INSERT INTO price_watches(user_id,product_id,base_price,created) VALUES('u1','p1',50,0)").run();
  const lookup = { productRecord: () => ({ id: "p1", brand: "b", title: "Dress", price: 50, available: true, currency: "USD", url: "https://shop.example.com/products/dress" }),
    brandRecord: () => ({ name: "Brand", platform: "shopify" }), allProducts: () => [] };
  const asked = [];
  const fetcher = async (url) => (asked.push(url), { ok: true, text: async () => JSON.stringify({ price: 4000, available: true }) });
  const r = await checkDeals(db, { apns: { send: async () => ({ status: 200 }) }, mail: null, lookup, fetcher, log: () => {} });
  assert.deepEqual(asked, ["https://shop.example.com/products/dress.js"]);
  assert.equal(r.drops, 1, "the catalog says $50; the store says $40");
  assert.equal(db.prepare("SELECT base_price FROM price_watches").get().base_price, 40);
});

// New drops (owner, 2026-10-20): watch a brand, optionally only some departments.
import { checkNewDrops, newDrops, dropsFor, dealAlertRoutes } from "../server/deal-alerts.js";

test("a new drop is a buyable product the brand never had", () => {
  const seen = new Set(["a1"]);
  const got = newDrops([{ id: "a1" }, { id: "a2", published_at: "2026-10-01" }, { id: "a3", available: false },
    { id: "a4", published_at: "2026-10-09" }], seen);
  assert.deepEqual(got.map((p) => p.id), ["a4", "a2"], "newest first; sold-out and known products aren't news");
  assert.deepEqual(dropsFor([{ id: "x", category: "bags" }, { id: "y", category: "shoes" }], ["bags"]).map((p) => p.id), ["x"]);
  assert.equal(dropsFor([{ id: "x", category: "bags" }], []).length, 1, "no departments picked = everything new");
});

test("watchers hear about new drops in their departments, once", async () => {
  const db = setup();
  db.exec(`INSERT INTO users VALUES('u2','Al','al@example.com');
    INSERT INTO restock_links VALUES('d2','u2',0); INSERT INTO restock_devices VALUES('d2','def','production',0);
    INSERT INTO drop_watches(user_id,brand_id,categories,created) VALUES('u1','tel','[]',0),('u2','tel','["shoes"]',0);`);
  let products = [{ id: "tel-1", brand: "tel", title: "Shopping Bag", category: "bags", available: true }];
  const lookup = { allProducts: () => products, brandRecord: () => ({ name: "Telfar" }), productRecord: () => null };
  const pushes = [], mails = [];
  const apns = { send: async (d, p) => { pushes.push([d.token, p]); return { status: 200 }; } };
  const mail = async (m) => { mails.push(m); };
  assert.equal(await checkNewDrops(db, { apns, mail, secret: SECRET, lookup }), 0, "the first look only remembers");
  products = [...products, { id: "tel-2", brand: "tel", title: "Duffle", category: "bags", available: true }];
  assert.equal(await checkNewDrops(db, { apns, mail, secret: SECRET, lookup }), 1, "only the shopper watching everything hears about a bag");
  assert.deepEqual(pushes.map((p) => p[0]), ["abc"]);
  assert.equal(pushes[0][1].aps.alert.title, "New from Telfar");
  assert.equal(pushes[0][1].productID, "tel-2", "one new product opens that product");
  assert.equal(mails[0].subject, "New from Telfar: Duffle");
  assert.equal(await checkNewDrops(db, { apns, mail, secret: SECRET, lookup }), 0, "already told");
  // A product back after an outage isn't new; shoes reach both watchers.
  products = [{ id: "tel-1", brand: "tel", title: "Shopping Bag", category: "bags", available: true },
    { id: "tel-3", brand: "tel", title: "Moon Boot", category: "shoes", available: true },
    { id: "tel-4", brand: "tel", title: "Clog", category: "shoes", available: true }];
  pushes.length = 0;
  assert.equal(await checkNewDrops(db, { apns, mail, secret: SECRET, lookup }), 2);
  assert.equal(pushes[0][1].brandID, "tel", "several new products open the brand");
});

test("drop watches are set, changed and removed per account", async () => {
  const db = setup();
  const { createHash } = await import("node:crypto");
  const token = "a".repeat(64);
  db.exec(`CREATE TABLE mobile_sessions (hash TEXT PRIMARY KEY, user_id TEXT NOT NULL, expires INTEGER NOT NULL);
    CREATE TABLE mobile_accounts (user_id TEXT PRIMARY KEY, generation TEXT NOT NULL);
    INSERT INTO mobile_accounts VALUES('u1','g');`);
  db.prepare("INSERT INTO mobile_sessions VALUES(?,?,?)").run(createHash("sha256").update(token).digest("hex"), "u1", Date.now() + 60_000);
  const express = (await import("express")).default;
  const app = express();
  const lookup = { brandRecord: (id) => (id === "tel" ? { id: "tel", name: "Telfar" } : null), productRecord: () => null, allProducts: () => [] };
  dealAlertRoutes(app, db, { env: {}, apns: null, mail: null, lookup, schedule: false });
  const server = app.listen(0);
  const base = `http://127.0.0.1:${server.address().port}/api/alerts`;
  const call = (method, path, body, auth = true) => fetch(base + path, { method,
    headers: { "content-type": "application/json", ...(auth ? { authorization: `Bearer ${token}` } : {}) }, body: body && JSON.stringify(body) });
  try {
    assert.equal((await call("POST", "/drops", { brandID: "tel" }, false)).status, 401, "signed out");
    assert.equal((await call("POST", "/drops", { brandID: "nope" })).status, 404);
    let r = await call("POST", "/drops", { brandID: "tel", categories: ["bags", "Bad Value!", "bags", 7] });
    assert.equal(r.status, 201);
    assert.deepEqual((await r.json()).drops.map((d) => [d.brandID, d.categories]), [["tel", ["bags"]]], "cleaned and de-duplicated");
    r = await call("POST", "/drops", { brandID: "tel", categories: [] });
    assert.deepEqual((await r.json()).drops[0].categories, [], "posting again changes the departments");
    r = await call("DELETE", "/drops", { brandID: "tel" });
    assert.deepEqual((await r.json()).drops, []);
  } finally { server.close(); }
});

// CAN-SPAM (2026-11-07): alert emails sell things, so each carries the postal
// address and a one-click unsubscribe that needs no sign-in, and it works.
import { POSTAL, unsubscribeURL, withFooter, emailOptedOut } from "../server/deal-alerts.js";

test("alert emails carry the postal address and a one-click unsubscribe", async () => {
  const db = setup();
  db.prepare("INSERT INTO brand_watches VALUES('u1','b',0,NULL)").run();
  let onSale = 1;
  const lookup = { productRecord: () => null, brandRecord: () => ({ name: "Brand" }),
    allProducts: () => Array.from({ length: onSale }, () => ({ brand: "b", available: true, price: 5, compare_at: 9 })) };
  const mails = [];
  const opts = { apns: { send: async () => ({ status: 200 }) }, mail: async (m) => mails.push(m), secret: SECRET, lookup, log: () => {} };
  await checkDeals(db, opts);
  onSale = 4;
  await checkDeals(db, opts);
  assert.equal(mails.length, 1);
  const link = unsubscribeURL("u1", SECRET);
  assert.equal(POSTAL, "Marracat · 251 Dekalb Ave, Brooklyn, NY 11205");
  assert.ok(mails[0].text.includes(POSTAL) && mails[0].text.includes(link));
  assert.ok(mails[0].html.includes("251 Dekalb Ave") && mails[0].html.includes("Unsubscribe"));
  assert.equal(mails[0].headers["List-Unsubscribe"], `<${link}>`);
  assert.equal(mails[0].headers["List-Unsubscribe-Post"], "List-Unsubscribe=One-Click");
});

test("no alert email goes out without a secret to sign the unsubscribe link", async () => {
  const db = setup();
  db.prepare("INSERT INTO price_watches(user_id,product_id,base_price,created) VALUES('u1','p1',50,0)").run();
  const lookup = { productRecord: () => ({ id: "p1", brand: "b", title: "Dress", price: 40, available: true, url: "https://x.bigcartel.com/product/d" }),
    brandRecord: () => ({ name: "Brand", platform: "bigcartel" }), allProducts: () => [] };
  const mails = [];
  const r = await checkDeals(db, { apns: { send: async () => ({ status: 200 }) }, mail: async (m) => mails.push(m), lookup, log: () => {} });
  assert.equal(r.drops, 1, "the push still goes");
  assert.equal(mails.length, 0);
});

test("the unsubscribe link works signed out, refuses a forged one, and stops alert emails", async () => {
  const db = setup();
  const express = (await import("express")).default;
  const app = express();
  const lookup = { productRecord: () => ({ id: "p1", brand: "b", title: "Dress", price: 40, available: true, url: "https://x.bigcartel.com/product/d" }),
    brandRecord: () => ({ name: "Brand", platform: "bigcartel" }), allProducts: () => [] };
  dealAlertRoutes(app, db, { env: { AUTH_SECRET: SECRET }, apns: null, mail: null, lookup, schedule: false });
  const server = app.listen(0);
  const origin = `http://127.0.0.1:${server.address().port}`;
  try {
    const path = new URL(unsubscribeURL("u1", SECRET)).pathname + new URL(unsubscribeURL("u1", SECRET)).search;
    const forged = await fetch(origin + path.replace(/t=[^&]+/, "t=" + "x".repeat(43)));
    assert.equal(forged.status, 400);
    const other = await fetch(origin + path.replace("u=u1", "u=u2"));
    assert.equal(other.status, 400, "u1's token can't unsubscribe u2");
    assert.equal(emailOptedOut(db, "u1"), false);
    const oneClick = await fetch(origin + path, { method: "POST", body: "List-Unsubscribe=One-Click",
      headers: { "Content-Type": "application/x-www-form-urlencoded" } });
    assert.equal(oneClick.status, 200);
    assert.match(await (await fetch(origin + path)).text(), /You're unsubscribed/);
    assert.equal(emailOptedOut(db, "u1"), true);
  } finally { server.close(); }
  db.prepare("INSERT INTO price_watches(user_id,product_id,base_price,created) VALUES('u1','p1',50,0)").run();
  const mails = [];
  const r = await checkDeals(db, { apns: { send: async () => ({ status: 200 }) }, mail: async (m) => mails.push(m), secret: SECRET, lookup, log: () => {} });
  assert.equal(r.drops, 1, "pushes are managed in the app and still go");
  assert.equal(mails.length, 0, "no email after an unsubscribe");
});

test("the footer keeps the alert's own text and adds to its headers", () => {
  const m = withFooter({ to: "a@b.co", subject: "s", text: "Hi", html: "<p>Hi</p>", headers: { "X-A": "1" } }, "https://marracat.com/x");
  assert.ok(m.text.startsWith("Hi\n\n--\n"));
  assert.equal(m.headers["X-A"], "1");
});

// Browser notifications (owner, 2026-11-10): an account with no phone and
// alert emails turned off still hears about a price drop in its browser.
test("a price drop reaches the account's browsers, and counts as delivered on its own", async () => {
  const db = setup();
  db.prepare("INSERT INTO price_watches(user_id,product_id,base_price,created) VALUES('u1','p1',50,0)").run();
  const lookup = { productRecord: () => ({ id: "p1", brand: "b", title: "Dress", price: 40, available: true, currency: "USD", url: "https://x.bigcartel.com/product/d" }),
    brandRecord: () => ({ name: "Brand", platform: "bigcartel" }), allProducts: () => [] };
  const notes = [];
  const webPush = { sendToUser: async (_db, userID, note) => (notes.push([userID, note]), true) };
  const apns = { send: async () => ({ status: 410 }) };
  assert.equal((await checkDeals(db, { apns, mail: null, webPush, lookup, log: () => {} })).drops, 1);
  assert.deepEqual(notes, [["u1", { title: "Price drop: $40.00 (was $50)", body: "Dress is now $40.00 at Brand", url: "/p/p1", tag: "p1" }]]);
  // A push service that is down is not an error for the alert run.
  db.prepare("UPDATE price_watches SET base_price=50").run();
  const broken = { sendToUser: async () => { throw Error("down"); } };
  assert.equal((await checkDeals(db, { apns, mail: null, webPush: broken, lookup, log: () => {} })).drops, 0);
});


// Cards (owner, 2026-11-15): the photo on the Lock Screen, the press-and-hold
// card, one card for several drops, last sizes, and the daily digest.
import { sendDigests, localTime } from "../server/deal-alerts.js";

const shop = (id, price, extra = {}) => ({ id, brand: "b", title: `Item ${id}`, price, available: true, currency: "USD",
  url: `https://x.bigcartel.com/product/${id}`, images: [`https://cdn.shopify.com/s/files/${id}.jpg`], ...extra });

test("a price drop carries its card: category, photo and the new price", async () => {
  const db = setup();
  db.prepare("INSERT INTO price_watches(user_id,product_id,base_price,created) VALUES('u1','p1',189,0)").run();
  const lookup = { productRecord: () => shop("p1", 160.65), brandRecord: () => ({ name: "Hanifa", platform: "bigcartel" }), allProducts: () => [] };
  const pushes = [];
  await checkDeals(db, { apns: { send: async (_d, p) => (pushes.push(p), { status: 200 }) }, mail: null, lookup, log: () => {} });
  const p = pushes[0];
  assert.equal(p.aps.category, "MC_PRICE");
  assert.equal(p.aps["mutable-content"], 1);
  assert.equal(p.productID, "p1", "older apps still open the product");
  assert.deepEqual([p.card.price, p.card.was, p.card.pct], ["$160.65", "$189", "−15%"]);
  assert.match(p.card.items[0].img, /width=400/);
});

test("several drops for one account are one push, and still one email each", async () => {
  const db = setup();
  for (const id of ["p1", "p2", "p3"]) db.prepare("INSERT INTO price_watches(user_id,product_id,base_price,created) VALUES('u1',?,100,0)").run(id);
  const lookup = { productRecord: (id) => shop(id, 80), brandRecord: () => ({ name: "Brand", platform: "bigcartel" }), allProducts: () => [] };
  const pushes = [], mails = [];
  const r = await checkDeals(db, { apns: { send: async (_d, p) => (pushes.push(p), { status: 200 }) }, mail: async (m) => mails.push(m), secret: SECRET, lookup, log: () => {} });
  assert.equal(r.drops, 3);
  assert.equal(pushes.length, 1);
  assert.equal(pushes[0].aps.category, "MC_SAVED");
  assert.equal(pushes[0].card.save, "$60.00");
  assert.match(pushes[0].card.open, /^marracat:\/\/picks\?title=Price%20drops&ids=p\d,p\d,p\d$/);
  assert.equal(mails.length, 3);
});

test("down to its last size since the last look: one alert", async () => {
  const db = setup();
  db.prepare("INSERT INTO price_watches(user_id,product_id,base_price,created) VALUES('u1','p1',50,0)").run();
  const lookup = { productRecord: () => shop("p1", 50, { url: "https://shop.example.com/products/set" }),
    brandRecord: () => ({ name: "Hanifa", platform: "shopify" }), allProducts: () => [] };
  let sizes = { S: true, M: true, L: false };
  const live = () => ({ price: 5000, available: true, options: [{ name: "Size" }],
    variants: Object.entries(sizes).map(([s, a], i) => ({ id: i + 1, option1: s, available: a })) });
  const fetcher = async () => ({ ok: true, text: async () => JSON.stringify(live()) });
  const pushes = [];
  const apns = { send: async (_d, p) => (pushes.push(p), { status: 200 }) };
  await checkDeals(db, { apns, mail: null, lookup, fetcher, log: () => {} });
  assert.equal(pushes.length, 0, "two sizes left: nothing yet");
  sizes = { S: false, M: true, L: false };
  db.prepare("UPDATE price_watches SET checked=0").run();
  const r = await checkDeals(db, { apns, mail: null, lookup, fetcher, log: () => {} });
  assert.equal(r.sizes, 1);
  assert.equal(pushes[0].aps.category, "MC_LASTSIZE");
  assert.deepEqual(pushes[0].card.sizes, [{ l: "S", a: false }, { l: "M", a: true }, { l: "L", a: false }]);
  assert.equal(pushes[0].card.vid, "2");
  db.prepare("UPDATE price_watches SET checked=0").run();
  assert.equal((await checkDeals(db, { apns, mail: null, lookup, fetcher, log: () => {} })).sizes, 0, "still one left is not news");
});

test("with the digest on, alerts wait and go out together once from 9 AM", async () => {
  const db = setup();
  db.prepare("INSERT INTO alert_prefs(user_id,digest,tz,updated) VALUES('u1',1,'America/New_York',0)").run();
  for (const id of ["p1", "p2"]) db.prepare("INSERT INTO price_watches(user_id,product_id,base_price,created) VALUES('u1',?,100,0)").run(id);
  const lookup = { productRecord: (id) => shop(id, 80), brandRecord: () => ({ name: "Brand", platform: "bigcartel" }), allProducts: () => [] };
  const pushes = [];
  const apns = { send: async (_d, p) => (pushes.push(p), { status: 200 }) };
  const early = Date.parse("2026-11-16T12:00:00Z"); // 7 AM in New York
  const r = await checkDeals(db, { apns, mail: null, lookup, now: () => early, log: () => {} });
  assert.equal(r.drops, 2, "held back counts as delivered");
  assert.equal(pushes.length, 0, "nothing before 9");
  const nine = Date.parse("2026-11-16T14:05:00Z");
  assert.equal(await sendDigests(db, { apns, now: () => nine, log: () => {} }), 1);
  assert.equal(pushes[0].aps.category, "MC_DIGEST");
  assert.equal(pushes[0].card.rows[0].tile, "tag");
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM digest_queue").get().n, 0);
  assert.equal(await sendDigests(db, { apns, now: () => nine + 3600_000, log: () => {} }), 0, "once a day");
});

test("local time follows the time zone, and a bad zone falls back to New York", () => {
  const at = Date.parse("2026-11-16T14:05:00Z");
  assert.deepEqual(localTime("America/Los_Angeles", at), { hour: 6, date: "2026-11-16" });
  assert.deepEqual(localTime("Nowhere/Fake", at), { hour: 9, date: "2026-11-16" });
});

test("the digest setting needs a boolean, keeps the zone, and turning it off sends what waited", async () => {
  const db = setup();
  const { createHash } = await import("node:crypto");
  const token = "b".repeat(64);
  db.exec(`CREATE TABLE mobile_sessions (hash TEXT PRIMARY KEY, user_id TEXT NOT NULL, expires INTEGER NOT NULL);
    CREATE TABLE mobile_accounts (user_id TEXT PRIMARY KEY, generation TEXT NOT NULL);
    INSERT INTO mobile_accounts VALUES('u1','g');`);
  db.prepare("INSERT INTO mobile_sessions VALUES(?,?,?)").run(createHash("sha256").update(token).digest("hex"), "u1", Date.now() + 60_000);
  const express = (await import("express")).default;
  const app = express();
  const pushes = [];
  const apns = { send: async (_d, p) => (pushes.push(p), { status: 200 }) };
  dealAlertRoutes(app, db, { env: {}, apns, mail: null, lookup: { brandRecord: () => null, productRecord: () => null, allProducts: () => [] }, schedule: false });
  const server = app.listen(0);
  const base = `http://127.0.0.1:${server.address().port}/api/alerts`;
  const call = (method, path, body) => fetch(base + path, { method, headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: body && JSON.stringify(body) });
  try {
    assert.equal((await call("POST", "/prefs", { digest: "yes" })).status, 400);
    assert.equal((await call("POST", "/prefs", { digest: true, tz: "Europe/London" })).status, 200);
    assert.equal((await (await call("GET", "")).json()).digest, true);
    assert.equal(db.prepare("SELECT tz FROM alert_prefs").get().tz, "Europe/London");
    db.prepare("INSERT INTO digest_queue(user_id,row,created) VALUES('u1',?,0)").run(JSON.stringify({ kind: "sale", tile: "sale", b: "Fenty", t: "42 items", st: "Sale", tint: "orange" }));
    assert.equal((await call("POST", "/prefs", { digest: false, tz: "Bad/Zone" })).status, 200);
    assert.equal(pushes.length, 1, "the waiting alert went out on turning it off");
    assert.equal(db.prepare("SELECT tz FROM alert_prefs").get().tz, "Europe/London", "a bad zone keeps the last good one");
    assert.equal((await (await call("GET", "")).json()).digest, false);
  } finally { server.close(); }
});
