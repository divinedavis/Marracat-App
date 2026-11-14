import { readFile } from "node:fs/promises";
import { createHash, timingSafeEqual } from "node:crypto";

// The owner dashboard (divinedavis.com/dashboard/?site=marracat) reads the
// numbers metrics/marracat_metrics.py writes every five minutes. That API runs
// on another droplet, so it asks this route with a shared key; without one set
// the route does not exist.

const RANGES = ["all", "6m", "3m", "month", "today"];
const digest = (v) => createHash("sha256").update(String(v)).digest();
const ownerEmails = (env) =>
  new Set((env.OWNER_EMAILS || "divinejdavis@gmail.com").split(",").map((e) => e.trim().toLowerCase()).filter(Boolean));
export const isOwnerEmail = (email, env = process.env) => ownerEmails(env).has(String(email || "").toLowerCase());

export function installOwnerSchema(db) {
  db.exec("CREATE TABLE IF NOT EXISTS owner_sightings (day TEXT NOT NULL, ip TEXT NOT NULL, PRIMARY KEY(day, ip))");
}

// Remember which address the owner's signed-in phone used today, so the
// metrics job can leave the owner's own testing out of the app numbers. A
// cellular address changes all day; the account does not.
export function ownerSighting(db, env = process.env) {
  installOwnerSchema(db);
  const owners = ownerEmails(env);
  const insert = db.prepare("INSERT OR IGNORE INTO owner_sightings(day, ip) VALUES(?, ?)");
  return (email, ip) => {
    if (!ip || !owners.has(String(email || "").toLowerCase())) return;
    insert.run(new Date().toISOString().slice(0, 10), ip);
  };
}

export function ownerMetricsRoutes(app, env = process.env) {
  const file = env.METRICS_FILE || "/var/lib/marracat-metrics/metrics.json";
  // The shopper roster for the dashboard's Marracat Users page: same key, same file.
  app.get("/api/owner/users", async (req, res) => {
    res.set("Cache-Control", "no-store");
    const key = env.METRICS_KEY || "";
    const given = req.get("X-Metrics-Key") || "";
    if (key.length < 32 || !timingSafeEqual(digest(key), digest(given))) return res.sendStatus(404);
    let data;
    try { data = JSON.parse(await readFile(file, "utf8")); }
    catch { return res.status(503).json({ error: "metrics_unavailable" }); }
    res.json({ generated_at: data.generated_at, users: data.users || [] });
  });
  app.get("/api/owner/metrics", async (req, res) => {
    res.set("Cache-Control", "no-store");
    const key = env.METRICS_KEY || "";
    const given = req.get("X-Metrics-Key") || "";
    if (key.length < 32 || !timingSafeEqual(digest(key), digest(given))) return res.sendStatus(404);
    let data;
    try { data = JSON.parse(await readFile(file, "utf8")); }
    catch { return res.status(503).json({ error: "metrics_unavailable" }); }
    const range = RANGES.includes(req.query.range) && Object.hasOwn(data.ranges || {}, req.query.range) ? req.query.range : "all";
    res.json({
      generated_at: data.generated_at, log_since: data.log_since, site_log_since: data.site_log_since,
      // MetricKit by build: not cut by the range (iOS reports daily, per build).
      performance: data.performance || [],
      // Find A Crib-style fixed windows (actives, retention, sources, the
      // daily series): not cut by the range, as on Find A Crib.
      fac: data.fac || null,
      // Devices on S0 vs S4 search builds, the last 30 days (2026-10-25).
      search_models: data.search_models || null,
      range, ...data.ranges[range],
    });
  });
}
