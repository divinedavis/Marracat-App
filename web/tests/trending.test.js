import { test } from "node:test";
import assert from "node:assert/strict";
import express from "express";
import Database from "better-sqlite3";
import { installEventSchema, recordEvent } from "../server/events.js";
import { computeTrending, trendingRoutes, snapshotProfiles, MIN_PEOPLE, LIMIT_MAX, CACHE_MS } from "../server/trending.js";
import { localDay } from "../server/visits.js";

const NOW = Date.UTC(2026, 9, 10, 18, 0, 0);
const H = 3_600_000;
const products = [
  ...Array.from({ length: 10 }, (_, i) => ({ id: `p${i}`, brand: "b", title: `P${i}`, category: i < 8 ? "skincare" : "bags", price: 10, available: true, tags: ["x"] })),
  { id: "gone", brand: "b", title: "Sold out", category: "skincare", price: 10, available: false },
];
const env = { OWNER_EMAILS: "owner@example.com" };

function db0() {
  const db = new Database(":memory:");
  installEventSchema(db);
  db.exec("CREATE TABLE users (id TEXT PRIMARY KEY, name TEXT, email TEXT)");
  db.exec("CREATE TABLE mobile_profiles (user_id TEXT PRIMARY KEY, data TEXT NOT NULL)");
  db.prepare("INSERT INTO users(id,email) VALUES('owner-1','owner@example.com')").run();
  return db;
}
const visitor = (i) => `visitor-${String(i).padStart(12, "0")}`;
/// `n` different visitors each do `name` on `product`, `ago` ms before NOW.
function events(db, product, n, name = "product_open", ago = H) {
  for (let i = 0; i < n; i++) recordEvent(db, visitor(`${product}-${name}-${i}`), { name, product, brand: "b", q: null, n: null, via: name === "buy_click" ? "cart" : null }, NOW - ago);
}
const run = (db, opts = {}) => computeTrending(db, { now: NOW, products, env, ...opts });

test("a product needs at least three different people to show", () => {
  const db = db0();
  for (let i = 0; i < 6; i++) events(db, `p${i}`, MIN_PEOPLE);
  events(db, "p6", MIN_PEOPLE - 1);
  // One visitor opening p7 many times is still one person.
  for (let k = 0; k < 10; k++) recordEvent(db, visitor("same"), { name: "product_open", product: "p7", brand: "b" }, NOW - H);
  const r = run(db);
  assert.equal(r.basis, "momentum");
  const ids = r.products.map((p) => p.id);
  assert.ok(!ids.includes("p6") && !ids.includes("p7"), ids.join());
  assert.equal(ids.length, 6);
});

test("Buy clicks outrank opens, and a steady product doesn't count as trending", () => {
  const db = db0();
  for (let i = 0; i < 5; i++) events(db, `p${i}`, 3);
  events(db, "p5", 3, "buy_click");
  // p6 got 3 opens in the last 48 h, but it gets far more every week: no surge.
  events(db, "p6", 3);
  for (let d = 3; d < 14; d++) events(db, "p6", 6, "product_open", d * 24 * H);
  const r = run(db);
  assert.equal(r.products[0].id, "p5");
  assert.ok(!r.products.some((p) => p.id === "p6"));
  assert.equal(r.products[0].tags, undefined, "cards drop search tags");
});

test("sold-out products and other departments are left out", () => {
  const db = db0();
  for (const id of ["p0", "p1", "p2", "p3", "p4", "p5", "p8", "gone"]) events(db, id, 3);
  const all = run(db).products.map((p) => p.id);
  assert.ok(!all.includes("gone"));
  const skincare = run(db, { category: "skincare" });
  assert.equal(skincare.basis, "momentum");
  assert.ok(skincare.products.every((p) => p.category === "skincare"));
});

test("taps on sponsored rows aren't momentum", () => {
  const db = db0();
  if (!db.prepare("SELECT 1 FROM pragma_table_info('site_events') WHERE name='row'").get())
    db.exec("ALTER TABLE site_events ADD COLUMN row TEXT");
  const tap = (product, i, row) => db.prepare("INSERT INTO site_events(ts,day,visitor,name,product,brand,row) VALUES(?,?,?,?,?,?,?)")
    .run(NOW - H, localDay(NOW - H), `v-${product}-${row}-${i}`, "rec_tap", product, "b", row);
  for (let i = 0; i < 6; i++) for (let k = 0; k < 3; k++) tap(`p${i}`, k, "sponsored");
  assert.equal(run(db).basis, "none");
  for (let i = 0; i < 6; i++) for (let k = 0; k < 3; k++) tap(`p${i}`, k, "search");
  assert.equal(run(db).basis, "momentum");
});

test("app orders count, but never the owner's", () => {
  const db = db0();
  const appleSeconds = (ms) => (ms - 978_307_200_000) / 1000;
  const profile = (id, productIDs) => db.prepare("INSERT INTO mobile_profiles(user_id,data) VALUES(?,?)").run(id, JSON.stringify({
    personalizationEnabled: true, recentlyViewed: [], saved: [],
    checkouts: [{ date: appleSeconds(NOW - 2 * H), productIDs }],
  }));
  const six = ["p0", "p1", "p2", "p3", "p4", "p5"];
  profile("owner-1", six);
  profile("u1", six);
  profile("u2", six);
  assert.equal(run(db).basis, "none", "the owner's orders must not make up the third person");
  profile("u3", six);
  const r = run(db);
  assert.equal(r.basis, "momentum");
  assert.equal(r.products.length, 6);
});

test("shoppers who turned personalization off aren't counted", () => {
  const db = db0();
  const ids = ["p0", "p1", "p2", "p3", "p4", "p5"];
  for (const u of ["u1", "u2", "u3"])
    db.prepare("INSERT INTO mobile_profiles(user_id,data) VALUES(?,?)").run(u, JSON.stringify({ personalizationEnabled: false, recentlyViewed: ids, saved: ids, checkouts: [] }));
  assert.equal(run(db).basis, "none");
});

test("app lists show momentum against the daily snapshots", () => {
  const db = db0();
  const ids = ["p0", "p1", "p2", "p3", "p4", "p5"];
  // Yesterday nobody had them; today three accounts saved all six.
  snapshotProfiles(db, [], NOW - 24 * H);
  for (const u of ["u1", "u2", "u3"])
    db.prepare("INSERT INTO mobile_profiles(user_id,data) VALUES(?,?)").run(u, JSON.stringify({ personalizationEnabled: true, recentlyViewed: [], saved: ids, checkouts: [] }));
  const r = run(db);
  assert.equal(r.basis, "momentum");
  assert.deepEqual(r.products.map((p) => p.id).sort(), ids);
  // Only per-product counts are stored.
  const cols = db.prepare("SELECT name FROM pragma_table_info('trending_snapshots')").all().map((c) => c.name);
  assert.deepEqual(cols.sort(), ["day", "product", "saved", "viewed"]);
});

test("falls back to Popular this week, then to nothing", () => {
  const db = db0();
  assert.deepEqual(run(db), { title: "Trending now", basis: "none", products: [] });
  for (let i = 0; i < 6; i++) events(db, `p${i}`, 3, "product_open", 4 * 24 * H); // a few days ago
  const r = run(db);
  assert.equal(r.basis, "popular");
  assert.equal(r.title, "Popular this week");
  assert.equal(r.products.length, 6);
});

async function serve(db, opts) {
  const app = express();
  trendingRoutes(app, db, { env, products: () => products, ...opts });
  const server = app.listen(0);
  await new Promise((r) => server.once("listening", r));
  return { url: `http://127.0.0.1:${server.address().port}`, close: () => server.close() };
}

test("the route caches for ten minutes and bounds its input", async () => {
  const db = db0();
  let t = NOW;
  const s = await serve(db, { now: () => t });
  try {
    const first = await (await fetch(`${s.url}/api/trending`)).json();
    assert.equal(first.basis, "none");
    for (let i = 0; i < 6; i++) events(db, `p${i}`, 3);
    assert.equal((await (await fetch(`${s.url}/api/trending`)).json()).basis, "none", "served from cache");
    t += CACHE_MS + 1;
    assert.equal((await (await fetch(`${s.url}/api/trending`)).json()).basis, "momentum");
    assert.equal((await fetch(`${s.url}/api/trending?category=../x`)).status, 400);
    const capped = await (await fetch(`${s.url}/api/trending?limit=9999`)).json();
    assert.ok(capped.products.length <= LIMIT_MAX);
  } finally { s.close(); }
});

test("the app's own events don't count as website momentum", () => {
  const db = db0();
  const ev = (product, i, platform) => db.prepare("INSERT INTO site_events(ts,day,visitor,name,product,brand,platform) VALUES(?,?,?,?,?,?,?)")
    .run(NOW - H, localDay(NOW - H), `v-${product}-${platform}-${i}`, "add_to_cart", product, "b", platform);
  for (let i = 0; i < 6; i++) for (let k = 0; k < 3; k++) ev(`p${i}`, k, "ios");
  assert.equal(run(db).basis, "none");
  for (let i = 0; i < 6; i++) for (let k = 0; k < 3; k++) ev(`p${i}`, k, "web");
  assert.equal(run(db).basis, "momentum");
});

test("sex toys stay off the home page's row but not their department's", () => {
  const toys = Array.from({ length: 6 }, (_, i) => ({ id: `t${i}`, brand: "nytc", title: `T${i}`, category: "wellness", subs: ["sexual-wellness"], price: 30, available: true }));
  const db = db0();
  for (const p of toys) events(db, p.id, 3);
  const home = run(db, { products: [...products, ...toys] });
  assert.ok(home.products.every((p) => !p.id.startsWith("t")), "home row has none");
  const wellness = run(db, { products: [...products, ...toys], category: "wellness" });
  assert.equal(wellness.products.length, 6, "the Wellness department's row still lists them");
});
