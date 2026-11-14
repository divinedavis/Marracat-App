import { test } from "node:test";
import assert from "node:assert/strict";
import express from "express";
import Database from "better-sqlite3";
import { cleanVitals, installVitalsSchema, recordVitals, vitalsReport, vitalsRoutes, LINES, EDGES } from "../server/vitals.js";
import { shiftScore } from "../src/vitals.js";
import { productIDFor, productURL } from "../src/prefetch.js";

// Real-visitor speed (owner, 2026-11-10). A row is ranges, never numbers, and
// never says who.
test("a page load's timings are kept as ranges, with nothing that names the visitor", () => {
  const row = cleanVitals({ ttfb: 61.2, fcp: 900, lcp: 2100, inp: 48, cls: 0.03, catalog: 3.2, catalog_from: "device",
    screen: "home", conn: "4g", repeat: true, installed: false, id: "visitor-1234567890abcdef", ua: "x", ip: "1.2.3.4" });
  assert.deepEqual(row, { screen: "home", ttfb: "0-200", fcp: "0-1000", lcp: "1500-2500", inp: "0-100", cls: "0-0.1",
    catalog: "2-4", catalog_from: "device", conn: "4g", installed: 0, repeat: 1 });
  assert.equal(cleanVitals({ lcp: 99_999 }).lcp, "10000+");
});

test("junk is dropped: no measure, wrong types, unknown names", () => {
  for (const body of [null, [], "x", {}, { screen: "home" }, { lcp: "fast" }, { lcp: -1 }, { lcp: Infinity }]) assert.equal(cleanVitals(body), null);
  const row = cleanVitals({ lcp: 10, screen: "<script>", catalog_from: "moon", conn: "5g" });
  assert.deepEqual([row.screen, row.catalog_from, row.conn], [null, null, null]);
});

test("the good line of every measure is a range edge, so 'good' needs no exact time", () => {
  for (const m of ["ttfb", "fcp", "lcp", "inp", "catalog"]) for (const line of LINES[m]) assert.ok(EDGES[m].includes(line), `${m} ${line}`);
});

test("the report gives the share of loads that were good and poor", () => {
  const db = new Database(":memory:");
  installVitalsSchema(db);
  const now = Date.UTC(2026, 10, 10, 18);
  for (const lcp of [900, 2000, 2400, 3000, 9000]) recordVitals(db, cleanVitals({ lcp, catalog: 2, catalog_from: "device", repeat: true }), now);
  recordVitals(db, cleanVitals({ lcp: 800 }), now - 30 * 86_400_000); // outside the window
  const r = vitalsReport(db, { days: 7, now });
  assert.equal(r.loads, 5);
  assert.deepEqual([r.measures.lcp.good_pct, r.measures.lcp.poor_pct], [60, 20]);
  assert.deepEqual(Object.keys(r.measures.lcp.ranges), ["0-1500", "1500-2500", "2500-4000", "6000-10000"]);
  assert.deepEqual(r.catalog_from, { device: 5 });
  assert.equal(r.repeat, 5);
  assert.equal(r.measures.inp, undefined, "a measure nobody reported is left out");
});

test("POST /api/vitals stores a row from a beacon and answers 204 to anything", async () => {
  const db = new Database(":memory:");
  const app = express();
  vitalsRoutes(app, db);
  const server = app.listen(0);
  const url = `http://127.0.0.1:${server.address().port}/api/vitals`;
  try {
    // sendBeacon posts a Blob typed application/json.
    assert.equal((await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ lcp: 1200, screen: "product" }) })).status, 204);
    assert.equal((await fetch(url, { method: "POST", body: "not json" })).status >= 400, true);
    assert.equal((await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" })).status, 204);
    assert.equal((await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ x: "y".repeat(5000) }) })).status, 413);
    const rows = db.prepare("SELECT * FROM web_vitals").all();
    assert.equal(rows.length, 1);
    assert.deepEqual([rows[0].lcp, rows[0].screen], ["0-1500", "product"]);
  } finally {
    server.close();
  }
});

test("layout shift is the worst burst, and shifts after the visitor's own input don't count", () => {
  const e = (startTime, value, hadRecentInput = false) => ({ startTime, value, hadRecentInput });
  assert.equal(shiftScore([]), 0);
  // Two bursts more than a second apart: the larger one.
  assert.ok(Math.abs(shiftScore([e(100, 0.05), e(600, 0.05), e(3000, 0.02)]) - 0.1) < 1e-9);
  assert.equal(shiftScore([e(100, 0.3, true), e(200, 0.01)]), 0.01);
  // A burst is cut at five seconds however close its shifts are.
  assert.ok(shiftScore(Array.from({ length: 12 }, (_, i) => e(i * 900, 0.01))) < 0.07);
});

test("a press on a product link names the product whose page to start loading", () => {
  assert.equal(productIDFor("/p/the-lip-bar-123"), "the-lip-bar-123");
  assert.equal(productIDFor("/p/a%20b/"), "a b");
  for (const href of ["/b/the-lip-bar", "/p/", "/p/x/y", "https://evil.example/p/x", null, "/p/%E0%A4%A"]) assert.equal(productIDFor(href), null);
  assert.equal(productURL("a b"), "/api/products/a%20b?v=3");
});
