import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import Database from "better-sqlite3";
import { filterProducts, relaxedSearch, expandQuery } from "../src/catalog.js";
import { collect, cleanQuery } from "../server/search-gaps.js";

// Learn-from-failed-searches (owner, 2026-10-10): confirmed wordings widen a
// search phrase; the weekly job's input leaves personal data out.
const brands = [{ id: "b", name: "B" }];
const products = [
  { id: "1", brand: "b", title: "Silky Wave Cap", category: "accessories", price: 10, available: true },
  { id: "2", brand: "b", title: "Satin Durag", category: "accessories", price: 12, available: true },
  { id: "3", brand: "b", title: "Waffle Weave Towel", category: "home", price: 30, available: true },
];
const ids = (q, synonyms) => filterProducts(products, brands, { q, synonyms }).map((p) => p.id).sort();

test("a confirmed synonym widens only its own phrase", () => {
  const synonyms = { durag: ["wave cap"] };
  assert.deepEqual(ids("durag", {}), ["2"]);
  assert.deepEqual(ids("durag", synonyms), ["1", "2"]);
  assert.deepEqual(ids("Durags", synonyms), ["2"], "no entry for the plural phrase: unchanged");
  assert.deepEqual(ids("satin durag", synonyms), ["2"], "phrase-level: a longer query isn't expanded");
  assert.deepEqual(ids("towel", synonyms), ["3"]);
});

test("expandQuery ignores case and spacing, bad entries and caps the list", () => {
  assert.deepEqual(expandQuery("  DURAG ", { durag: ["wave cap", "", 7, "du rag"] }), ["  DURAG ", "wave cap", "du rag"]);
  assert.deepEqual(expandQuery("toString", {}), ["toString"], "no prototype keys");
  assert.equal(expandQuery("x", { x: Array.from({ length: 20 }, (_, i) => `w${i}`) }).length, 9);
});

test("relaxed search still works with synonyms in play", () => {
  const r = relaxedSearch(products, brands, { q: "blue waffle towel", synonyms: {} });
  assert.equal(r.q, "waffle towel");
});

test("the website and app copies of the synonyms file match", () => {
  const a = readFileSync(new URL("../src/search-synonyms.json", import.meta.url), "utf8");
  const b = readFileSync(new URL("../public/search-synonyms.json", import.meta.url), "utf8");
  assert.equal(a, b);
  assert.equal(typeof JSON.parse(a).synonyms, "object");
});

test("the weekly input groups searches and drops personal data", () => {
  assert.equal(cleanQuery("  Nail   Clipper "), "nail clipper");
  assert.equal(cleanQuery("me@example.com"), null);
  assert.equal(cleanQuery("call 917 555 0100"), null);
  assert.equal(cleanQuery("x"), null);
  const db = new Database(":memory:");
  db.exec("CREATE TABLE site_events (id INTEGER PRIMARY KEY, ts INTEGER, day TEXT, visitor TEXT, name TEXT, product TEXT, brand TEXT, q TEXT, n INTEGER, via TEXT)");
  const now = Date.UTC(2026, 9, 10);
  const add = (q, n, visitor, ago = 0) =>
    db.prepare("INSERT INTO site_events(ts,day,visitor,name,q,n) VALUES(?,?,?,?,?,?)").run(now - ago, "d", visitor, "search", q, n);
  add("Nail Clipper", 0, "a"); add("nail clipper", 0, "b"); add("durag", 485, "a");
  add("me@x.com", 0, "c"); add("old", 0, "a", 30 * 86_400_000);
  const out = collect(db, { days: 7, now });
  assert.deepEqual(out.queries.map((q) => [q.q, q.searches, q.zero, q.visitors]), [["nail clipper", 2, 2, 2], ["durag", 1, 0, 1]]);
  assert.equal(out.queries[0].source, "web", "an old table without platform reads as the website");
  assert.equal(collect(new Database(":memory:"), { now }).queries.length, 0, "no table yet: empty, not an error");
});

test("app searches from /api/events come through, marked by platform", () => {
  const db = new Database(":memory:");
  db.exec("CREATE TABLE site_events (id INTEGER PRIMARY KEY, ts INTEGER, day TEXT, visitor TEXT, name TEXT, q TEXT, n INTEGER, platform TEXT)");
  const now = Date.UTC(2026, 9, 11);
  const add = (q, visitor, platform) =>
    db.prepare("INSERT INTO site_events(ts,day,visitor,name,q,n,platform) VALUES(?,?,?,?,?,?,?)").run(now, "d", visitor, "search", q, 0, platform);
  add("wave cap", "a", "ios"); add("wave cap", "b", "web"); add("bonnet", "c", "ios");
  const by = Object.fromEntries(collect(db, { days: 7, now }).queries.map((q) => [q.q, q.source]));
  assert.deepEqual(by, { "wave cap": "ios+web", bonnet: "ios" });
});
