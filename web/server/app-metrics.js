import express from "express";
import { createHash } from "node:crypto";
import { rateLimit } from "express-rate-limit";

// MetricKit reports from the iPhone app (Marracat/Stores/MetricsReporter.swift,
// owner 2026-10-02): iOS's own daily summary of launch time, hangs, memory and
// CPU on a real device, plus hang and crash diagnostics. Stored as Apple wrote
// them for metrics/marracat_metrics.py to summarise by build. Counts and
// timings only; keyed by the hashed per-install key, never an account.

const hash = (value) => createHash("sha256").update(value).digest("hex");
const deviceKey = /^[a-f0-9]{64}$/;
const MAX_REPORT = 512 * 1024;
const PER_DEVICE_PER_DAY = 20;
const KEEP_DAYS = 90;
// All installs together, per UTC day (audit 2026-11-04): device keys are free
// to make, so the per-install cap alone let one script write ~5 MB a minute
// per address until the droplet's disk (shared with every app on it) filled.
// Real phones send about two dozen reports a day, ~10 KB each.
export const MAX_BYTES_PER_DAY = 25 * 1024 * 1024;

export function installAppMetricsSchema(db) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS app_metrics (
      id INTEGER PRIMARY KEY AUTOINCREMENT, device TEXT NOT NULL, kind TEXT NOT NULL,
      build TEXT NOT NULL, received INTEGER NOT NULL, report TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS app_metrics_received ON app_metrics(received);
  `);
}

export function appMetricsRoutes(app, db, { now = Date.now } = {}) {
  installAppMetricsSchema(db);
  // Bytes stored today, read from the table once per day and counted after.
  let spent = null;
  const storedToday = (t) => {
    const day = Math.floor(t / 86_400_000);
    if (spent?.day !== day)
      spent = { day, bytes: db.prepare("SELECT COALESCE(SUM(length(report)), 0) AS b FROM app_metrics WHERE received>=?").get(day * 86_400_000).b };
    return spent;
  };
  const router = express.Router();
  router.use(rateLimit({ windowMs: 60_000, limit: 10, standardHeaders: "draft-8", legacyHeaders: false }));
  router.use(express.json({ limit: "600kb" }));
  router.post("/", (req, res) => {
    res.set("Cache-Control", "no-store");
    const key = req.get("X-Marracat-Device");
    if (!key || !deviceKey.test(key)) return res.status(401).json({ error: "Missing device key" });
    const { kind, build, report } = req.body || {};
    if (!["metric", "diagnostic"].includes(kind)) return res.status(400).json({ error: "Invalid kind" });
    if (typeof build !== "string" || !/^\d{1,6}$/.test(build)) return res.status(400).json({ error: "Invalid build" });
    if (typeof report !== "string" || report.length > MAX_REPORT) return res.status(413).json({ error: "Report too large" });
    try {
      const parsed = JSON.parse(report);
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw Error();
    } catch {
      return res.status(400).json({ error: "Invalid report" });
    }
    const device = hash(key), t = now();
    const today = db.prepare("SELECT COUNT(*) AS n FROM app_metrics WHERE device=? AND received>?").get(device, t - 86_400_000).n;
    if (today >= PER_DEVICE_PER_DAY) return res.status(429).json({ error: "Too many reports today" });
    const day = storedToday(t);
    if (day.bytes + report.length > MAX_BYTES_PER_DAY) return res.status(429).json({ error: "Too many reports today" });
    day.bytes += report.length;
    db.prepare("DELETE FROM app_metrics WHERE received<?").run(t - KEEP_DAYS * 86_400_000);
    db.prepare("INSERT INTO app_metrics(device,kind,build,received,report) VALUES(?,?,?,?,?)").run(device, kind, build, t, report);
    res.sendStatus(204);
  });
  router.use((error, req, res, next) => {
    res.status(error.type === "entity.parse.failed" ? 400 : error.type === "entity.too.large" ? 413 : 500).json({ error: "Request could not be completed" });
  });
  app.use("/api/app-metrics", router);
}
