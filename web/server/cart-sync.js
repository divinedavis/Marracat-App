// One cart per account, shared by the website and the app (owner,
// 2026-10-05: "our cart online should carry over to the app"). Each side
// sends its whole cart after a change (PUT) and reads it back on launch,
// focus and sign-in (GET); `updated` lets a side tell whether the account's
// cart moved on since it last synced. Merging a guest cart into the
// account's on sign-in happens on the device, which then PUTs the result.
import express from "express";
import { rateLimit } from "express-rate-limit";
import { viewerOf } from "./social.js";

export const MAX_LINES = 100;
export const MAX_QTY = 99;

export function installCartSchema(db) {
  db.exec("CREATE TABLE IF NOT EXISTS carts (user_id TEXT PRIMARY KEY, lines TEXT NOT NULL, updated INTEGER NOT NULL)");
}

export function deleteCartData(db, userID) {
  db.prepare("DELETE FROM carts WHERE user_id=?").run(userID);
}

/// Only these fields, in these shapes; anything else is refused.
export function cleanLines(lines) {
  if (!Array.isArray(lines) || lines.length > MAX_LINES) return null;
  const out = [];
  const seen = new Set();
  for (const l of lines) {
    if (!l || typeof l.productID !== "string" || !l.productID || l.productID.length > 200) return null;
    const variantID = String(l.variantID ?? "");
    if (!/^\d{1,20}$/.test(variantID)) return null;
    if (!Number.isInteger(l.quantity) || l.quantity < 1 || l.quantity > MAX_QTY) return null;
    const line = { productID: l.productID, variantID, quantity: l.quantity };
    if (typeof l.option === "string" && l.option.length <= 200) line.option = l.option;
    if (Number.isFinite(l.unitPrice) && l.unitPrice >= 0 && l.unitPrice < 1e7) line.unitPrice = l.unitPrice;
    if (typeof l.currency === "string" && /^[A-Z]{3}$/.test(l.currency)) line.currency = l.currency;
    const key = line.productID + "#" + variantID;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(line);
  }
  return out;
}

export function cartRoutes(app, db, { env = process.env, viewer = (req) => viewerOf(req, db, env), now = Date.now } = {}) {
  installCartSchema(db);
  const router = express.Router();
  router.use((req, res, next) => { res.set("Cache-Control", "no-store"); next(); });
  router.use(rateLimit({ windowMs: 60_000, limit: 120, standardHeaders: "draft-8", legacyHeaders: false }));
  router.use(express.json({ limit: "64kb" }));
  router.use(async (req, res, next) => {
    const user = await viewer(req).catch(() => null);
    if (!user) return res.status(401).json({ error: "Sign in to keep your cart across devices" });
    req.user = user;
    next();
  });
  const read = (id) => {
    const row = db.prepare("SELECT lines, updated FROM carts WHERE user_id=?").get(id);
    return row ? { lines: JSON.parse(row.lines), updated: row.updated } : { lines: [], updated: 0 };
  };
  router.get("/", (req, res) => res.json(read(req.user.id)));
  router.put("/", (req, res) => {
    const lines = cleanLines(req.body?.lines);
    if (!lines) return res.status(400).json({ error: "That cart couldn't be saved" });
    const updated = now();
    db.prepare(`INSERT INTO carts(user_id,lines,updated) VALUES(?,?,?)
      ON CONFLICT(user_id) DO UPDATE SET lines=excluded.lines, updated=excluded.updated`).run(req.user.id, JSON.stringify(lines), updated);
    res.json({ lines, updated });
  });
  router.use((error, req, res, next) => {
    res.status(error.type === "entity.parse.failed" ? 400 : error.type === "entity.too.large" ? 413 : 500).json({ error: "Request could not be completed" });
  });
  app.use("/api/cart", router);
}
