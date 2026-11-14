import express from "express";
import { createHash } from "node:crypto";
import { rateLimit } from "express-rate-limit";
import { brandRecord } from "./catalog.js";
import { mobileSessionUser } from "./mobile.js";
import { isOwnerEmail } from "./owner-metrics.js";

// "Late shipment" on an order in the app (owner, 2026-10-01): which brands
// shoppers say ship late, counted on the owner dashboard. One report per
// order per install, keyed like restock alerts and order tracking so it works
// signed out. The order itself is stored only as a hash — the dashboard needs
// the brand and how many shoppers, never which order.

const hash = (value) => createHash("sha256").update(value).digest("hex");
const deviceKey = /^[a-f0-9]{64}$/;
const orderKey = /^[A-Za-z0-9:/?=._-]{1,120}$/;

export function installLateSchema(db) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS late_shipments (
      device TEXT NOT NULL, order_hash TEXT NOT NULL,
      brand_id TEXT NOT NULL, brand_name TEXT NOT NULL,
      owner INTEGER NOT NULL DEFAULT 0, created INTEGER NOT NULL,
      PRIMARY KEY(device, order_hash));
    CREATE INDEX IF NOT EXISTS late_shipments_brand ON late_shipments(brand_id);
  `);
}

export function lateShipmentRoutes(app, db, { env = process.env, lookup = brandRecord, now = Date.now } = {}) {
  installLateSchema(db);
  const router = express.Router();
  router.use((req, res, next) => { res.set("Cache-Control", "no-store"); next(); });
  router.use(rateLimit({ windowMs: 60_000, limit: 30, standardHeaders: "draft-8", legacyHeaders: false }));
  router.use(express.json({ limit: "2kb" }));
  router.use((req, res, next) => {
    const key = req.get("X-Marracat-Device");
    if (!key || !deviceKey.test(key)) return res.status(401).json({ error: "Missing device key" });
    req.device = hash(key);
    next();
  });
  const order = (req) => {
    const value = req.body?.order;
    return typeof value === "string" && orderKey.test(value) ? hash(value) : null;
  };

  router.post("/", (req, res) => {
    const { brandID } = req.body || {};
    const brand = typeof brandID === "string" && brandID.length <= 120 ? lookup(brandID) : null;
    if (!brand) return res.status(422).json({ error: "Unknown brand" });
    const h = order(req);
    if (!h) return res.status(400).json({ error: "Invalid order" });
    // The owner's own testing stays out of the dashboard, when signed in.
    const owner = isOwnerEmail(mobileSessionUser(db, req)?.email, env) ? 1 : 0;
    db.prepare(`INSERT INTO late_shipments(device, order_hash, brand_id, brand_name, owner, created) VALUES(?,?,?,?,?,?)
      ON CONFLICT(device, order_hash) DO NOTHING`).run(req.device, h, brand.id, String(brand.name || brand.id).slice(0, 120), owner, now());
    res.status(201).json({ reported: true });
  });
  // Undo a mistaken tap, or ({all: true}) forget every report from this
  // install when the account is deleted.
  router.delete("/", (req, res) => {
    if (req.body?.all === true) {
      db.prepare("DELETE FROM late_shipments WHERE device=?").run(req.device);
      return res.json({ reported: false });
    }
    const h = order(req);
    if (!h) return res.status(400).json({ error: "Invalid order" });
    db.prepare("DELETE FROM late_shipments WHERE device=? AND order_hash=?").run(req.device, h);
    res.json({ reported: false });
  });
  router.use((error, req, res, next) => {
    res.status(error.type === "entity.parse.failed" ? 400 : error.type === "entity.too.large" ? 413 : 500).json({ error: "Request could not be completed" });
  });
  app.use("/api/orders/late", router);
}
