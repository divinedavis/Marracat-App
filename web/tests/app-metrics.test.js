import { test } from "node:test";
import assert from "node:assert/strict";
import express from "express";
import Database from "better-sqlite3";
import { appMetricsRoutes } from "../server/app-metrics.js";

async function fixture(t, now = () => Date.now()) {
  const db = new Database(":memory:");
  const app = express();
  appMetricsRoutes(app, db, { now });
  const server = app.listen(0, "127.0.0.1");
  await new Promise((r) => server.once("listening", r));
  t.after(() => { server.close(); db.close(); });
  const url = `http://127.0.0.1:${server.address().port}/api/app-metrics`;
  const post = async (body, key = "a".repeat(64)) => (await fetch(url, {
    method: "POST", headers: { "Content-Type": "application/json", ...(key ? { "X-Marracat-Device": key } : {}) },
    body: JSON.stringify(body) })).status;
  return { db, post };
}
const report = JSON.stringify({ applicationLaunchMetrics: { histogrammedTimeToFirstDraw: { histogramNumBuckets: 1 } } });

test("a MetricKit report is stored under the hashed install key", async (t) => {
  const { db, post } = await fixture(t);
  assert.equal(await post({ kind: "metric", build: "94", report }), 204);
  const row = db.prepare("SELECT * FROM app_metrics").get();
  assert.equal(row.kind, "metric"); assert.equal(row.build, "94"); assert.equal(row.report, report);
  assert.notEqual(row.device, "a".repeat(64));
});

test("bad reports are refused", async (t) => {
  const { db, post } = await fixture(t);
  assert.equal(await post({ kind: "metric", build: "94", report }, null), 401);
  assert.equal(await post({ kind: "other", build: "94", report }), 400);
  assert.equal(await post({ kind: "metric", build: "9x", report }), 400);
  assert.equal(await post({ kind: "metric", build: "94", report: "not json" }), 400);
  assert.equal(await post({ kind: "metric", build: "94", report: "[1,2]" }), 400);
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM app_metrics").get().n, 0);
});

test("one install sends at most 20 a day, and reports older than 90 days go", async (t) => {
  const clock = Date.now();
  const { db, post } = await fixture(t, () => clock);
  const { createHash } = await import("node:crypto");
  const device = createHash("sha256").update("b".repeat(64)).digest("hex");
  db.prepare("INSERT INTO app_metrics(device,kind,build,received,report) VALUES('old','metric','1',?,'{}')").run(clock - 91 * 86_400_000);
  for (let i = 0; i < 20; i++)
    db.prepare("INSERT INTO app_metrics(device,kind,build,received,report) VALUES(?,'metric','94',?,'{}')").run(device, clock - 1000);
  assert.equal(await post({ kind: "metric", build: "94", report }, "b".repeat(64)), 429);
  assert.equal(await post({ kind: "metric", build: "94", report }, "c".repeat(64)), 204);
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM app_metrics WHERE device='old'").get().n, 0);
});

test("all installs together store at most MAX_BYTES_PER_DAY a day (fresh device keys don't get around it)", async (t) => {
  const { MAX_BYTES_PER_DAY } = await import("../server/app-metrics.js");
  const clock = Date.UTC(2026, 10, 4, 12);
  const { db, post } = await fixture(t, () => clock);
  db.prepare("INSERT INTO app_metrics(device,kind,build,received,report) VALUES('x','metric','94',?,?)")
    .run(clock - 1000, "{" + " ".repeat(MAX_BYTES_PER_DAY - report.length - 2) + "}");
  assert.equal(await post({ kind: "metric", build: "94", report }, "d".repeat(64)), 204);
  assert.equal(await post({ kind: "metric", build: "94", report }, "e".repeat(64)), 429);
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM app_metrics").get().n, 2);
});
