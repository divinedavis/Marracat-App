// The website's side of the account profile the app syncs (mobile.js): the
// same saved items, lists, history and orders (owner, 2026-10-05: "i dont
// see my orders synced here"). Signed in on the website, it reads and
// changes the one profile; the app sees the changes on its next sync.
import express from "express";
import { rateLimit } from "express-rate-limit";
import { viewerOf } from "./social.js";
import { installMobileSchema, loadProfile, applyOperations } from "./mobile.js";
import { confirmWith } from "./identities.js";
import { issueCode, checkCode } from "./email-code.js";
import { purgeAccount, openBudget } from "./account-delete.js";

// Deleting the account on the website (2026-11-12; until then the site said
// "email us"). The shopper proves it is still them with a code emailed to the
// account's address, kept apart from sign-in codes by its "delete:" key. An
// account with an Apple sign-in is deleted in the app instead, where Apple's
// access is revoked with it (App Store 5.1.1(v)).
const deleteKey = (email) => `delete:${String(email).trim().toLowerCase()}`;
export function howToDelete(db, user) {
  const budget = openBudget(db, user.id);
  if (budget) return { how: "cancel-budget", brand: budget };
  if (confirmWith(db, user.id) === "apple") return { how: "app" };
  if (!user.email) return { how: "support" };
  return { how: "email", email: user.email };
}
export function deleteCodeEmail(to, code) {
  const line = `Your code to delete your Marracat account is ${code}`;
  const rest = "It works for 10 minutes. If you didn't ask to delete your account, ignore this email and nothing changes.";
  return {
    to,
    subject: `${code} is your Marracat account deletion code`,
    text: `${line}\n\n${rest}`,
    html: `<div style="font-family:Arial,sans-serif;color:#1d1d1d;max-width:420px"><p style="font-size:15px">Your code to delete your Marracat account is</p>` +
      `<p style="font-size:34px;font-weight:700;letter-spacing:8px;margin:8px 0 18px">${code}</p><p style="font-size:13px;color:#6d6d6d">${rest}</p></div>`,
  };
}

export function accountWebRoutes(app, db, { env = process.env, viewer = (req) => viewerOf(req, db, env), relay = null, mailer = null, secret = env.AUTH_SECRET } = {}) {
  installMobileSchema(db);
  const router = express.Router();
  router.use((req, res, next) => { res.set("Cache-Control", "no-store"); next(); });
  router.use(rateLimit({ windowMs: 60_000, limit: 120, standardHeaders: "draft-8", legacyHeaders: false }));
  router.use(express.json({ limit: "256kb" }));
  router.use(async (req, res, next) => {
    const user = await viewer(req).catch(() => null);
    if (!user) return res.status(401).json({ error: "Please sign in" });
    req.user = user;
    next();
  });
  router.get("/profile", (req, res) => res.json({ profile: loadProfile(db, req.user.id) }));
  // Shipping updates for the website's order details (owner, 2026-10-11:
  // "similar to what mobile app provides"): what brands' emails said through
  // this account's order address (relay.js), and what brands' own order pages
  // say for the orders its phones placed (order-tracking.js). The page matches
  // them to orders the way the app does (src/orderUpdates.js).
  router.get("/orders/updates", (req, res) => res.json(orderUpdates(db, relay, req.user.id)));
  router.post("/activity", (req, res) => {
    const operations = req.body?.operations;
    if (!Array.isArray(operations) || operations.length > 100) return res.status(400).json({ error: "Send up to 100 changes" });
    try { res.json({ profile: applyOperations(db, req.user.id, operations) }); }
    catch (e) { res.status(e.status || 400).json({ error: e.status ? e.message : "Invalid change" }); }
  });
  // How this account is deleted: by an emailed code here, in the app, or
  // after its ad budget is canceled.
  router.get("/delete", (req, res) => res.json(howToDelete(db, req.user)));
  const deleteLimit = rateLimit({ windowMs: 10 * 60_000, limit: 10, standardHeaders: "draft-8", legacyHeaders: false });
  router.post("/delete/code", deleteLimit, async (req, res) => {
    const way = howToDelete(db, req.user);
    if (way.how !== "email") return res.status(409).json(way);
    if (!mailer || !secret) return res.status(503).json({ error: "We can't send the code right now. Email privacy@marracat.com and we'll delete the account for you." });
    const issued = issueCode(db, deleteKey(way.email), { secret });
    if (issued.error === "wait") return res.status(429).json({ error: "A code is on its way. Wait a few seconds before asking for another." });
    if (issued.error) return res.status(429).json({ error: "Too many codes. Try again in an hour." });
    try {
      await mailer(deleteCodeEmail(way.email, issued.code));
      res.sendStatus(204);
    } catch {
      res.status(502).json({ error: "We couldn't send the email. Please try again." });
    }
  });
  router.delete("/", deleteLimit, (req, res) => {
    const way = howToDelete(db, req.user);
    if (way.how !== "email") return res.status(409).json(way);
    if (!secret || !checkCode(db, deleteKey(way.email), req.body?.code, { secret }))
      return res.status(401).json({ error: "That code isn't right or has expired. Ask for a new one." });
    purgeAccount(db, req.user.id);
    db.prepare("DELETE FROM email_codes WHERE email=?").run(deleteKey(way.email));
    res.sendStatus(204);
  });
  router.use((error, req, res, next) => res.status(error.type === "entity.parse.failed" ? 400 : 500).json({ error: "Request could not be completed" }));
  app.use("/api/account", router);
}

const hasTable = (db, name) => !!db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?").get(name);

export function orderUpdates(db, relay, userID) {
  const events = relay ? relay.events(userID) : [];
  // The phones signed in to this account (restock pushes, order address).
  const devices = new Set();
  if (hasTable(db, "restock_links"))
    for (const r of db.prepare("SELECT device FROM restock_links WHERE user_id=?").all(userID)) devices.add(r.device);
  if (hasTable(db, "relay_addresses"))
    for (const r of db.prepare("SELECT device FROM relay_addresses WHERE user_id=? AND device IS NOT NULL").all(userID)) devices.add(r.device);
  let tracked = [];
  if (devices.size && hasTable(db, "tracked_orders")) {
    const marks = [...devices].map(() => "?").join(",");
    // No checkout ids: each is a credential to that checkout.
    tracked = db.prepare(`SELECT brand_id AS brandID, order_gid AS orderID, permalink AS statusPage, state, carrier,
        tracking_number AS trackingNumber, tracking_url AS trackingURL, created, updated
      FROM tracked_orders WHERE device IN (${marks}) AND order_gid IS NOT NULL ORDER BY created DESC LIMIT 100`).all(...devices);
  }
  return { events, tracked };
}
