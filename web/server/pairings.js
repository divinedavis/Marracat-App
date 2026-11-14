import express from "express";
import { createHash } from "node:crypto";
import { rateLimit } from "express-rate-limit";
import { productRecord } from "./catalog.js";

// "Frequently bought together" (owner, 2026-10-02): which products from
// different departments end up in the same cart or order. Each pair counts
// once per install (hashed per-install key, never an account), and a pair is
// only shown once three installs have made it, so one shopper's habits never
// surface on their own. The app falls back to style-matched picks before then.
//
// Counted by client IP, not the install key (audit 2026-10-07): the key is
// any 64 hex characters the client makes up, so one script could pose as
// three installs and plant a pair. The key is still required (old and new
// builds send it); three distinct IPs are what make a pair show.

const hash = (value) => createHash("sha256").update(value).digest("hex");
const deviceKey = /^[a-f0-9]{64}$/;
export const MIN_INSTALLS = 3;

export function installPairingsSchema(db) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS pair_installs (
      a TEXT NOT NULL, b TEXT NOT NULL, device TEXT NOT NULL, created INTEGER NOT NULL,
      PRIMARY KEY(a, b, device));
    CREATE INDEX IF NOT EXISTS pair_installs_a ON pair_installs(a);
    CREATE INDEX IF NOT EXISTS pair_installs_b ON pair_installs(b);
  `);
}

export function pairingsRoutes(app, db, { lookup = productRecord, now = Date.now } = {}) {
  installPairingsSchema(db);
  const router = express.Router();
  router.use(rateLimit({ windowMs: 60_000, limit: 30, standardHeaders: "draft-8", legacyHeaders: false }));
  router.use(express.json({ limit: "8kb" }));
  router.post("/", (req, res) => {
    res.set("Cache-Control", "no-store");
    const key = req.get("X-Marracat-Device");
    if (!key || !deviceKey.test(key)) return res.status(401).json({ error: "Missing device key" });
    const ids = req.body?.products;
    if (!Array.isArray(ids) || ids.length < 2 || ids.length > 20 || !ids.every((id) => typeof id === "string" && id.length <= 200))
      return res.status(400).json({ error: "Send 2 to 20 products" });
    const products = [...new Set(ids)].map((id) => lookup(id)).filter(Boolean);
    const device = hash("ip:" + (req.ip || "unknown")), t = now();
    const insert = db.prepare("INSERT OR IGNORE INTO pair_installs(a,b,device,created) VALUES(?,?,?,?)");
    db.transaction(() => {
      for (let i = 0; i < products.length; i++)
        for (let j = i + 1; j < products.length; j++) {
          const [p, q] = [products[i], products[j]];
          if (p.category === q.category) continue;   // across departments only
          const [a, b] = p.id < q.id ? [p.id, q.id] : [q.id, p.id];
          insert.run(a, b, device, t);
        }
    })();
    res.sendStatus(204);
  });
  router.get("/", (req, res) => {
    const id = String(req.query.product || "");
    if (!id || id.length > 200) return res.status(400).json({ error: "Invalid product" });
    const rows = db.prepare(`SELECT CASE WHEN a=? THEN b ELSE a END AS other, COUNT(DISTINCT device) AS n
      FROM pair_installs WHERE a=? OR b=? GROUP BY other HAVING n >= ? ORDER BY n DESC, other LIMIT 12`)
      .all(id, id, id, MIN_INSTALLS);
    res.set("Cache-Control", "public, max-age=3600").json({ pairs: rows.map((r) => r.other) });
  });
  router.use((error, req, res, next) => {
    res.status(error.type === "entity.parse.failed" ? 400 : error.type === "entity.too.large" ? 413 : 500).json({ error: "Request could not be completed" });
  });
  app.use("/api/pairs", router);
}
