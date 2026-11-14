// "Claim your brand": proves a Marracat account speaks for a brand before it
// can book promotions (owner, 2026-10-04; options 2 and 3 of the plan).
//
//  - Domain email: a one-time sign-in link goes to an address at the brand's
//    own domain (you@brand.com); opening it proves that inbox. (A code on the
//    brand's store was the other way until 2026-10-06, when the owner chose
//    the email link alone.)
//
// The domain is always the one in our catalog, never one the claimant types,
// so neither route can be pointed at a site someone else controls. Every
// promotion still needs the owner's approval before it runs.
import express from "express";
import { fromOurPages } from "./same-site.js";
import { randomBytes, createHash } from "node:crypto";
import { rateLimit } from "express-rate-limit";
import { brandRecord } from "./catalog.js";
import { viewerOf } from "./social.js";
import { isOwnerEmail } from "./owner-metrics.js";

const LINK_TTL_MS = 30 * 60 * 1000;
// Caps are per requester (audit 2026-10-07): a cap on the brand alone let
// anyone use up the brand's links for the day.
const MAX_EMAILS_PER_USER_BRAND_PER_DAY = 3;
const MAX_EMAILS_PER_USER_PER_DAY = 10;

const sha = (v) => createHash("sha256").update(v).digest("hex");
const escapeHTML = (v) => String(v).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

export function installBrandClaimSchema(db) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS brand_claims (
      id TEXT PRIMARY KEY, brand_id TEXT NOT NULL, user_id TEXT NOT NULL,
      method TEXT NOT NULL, code TEXT, email TEXT, link_hash TEXT,
      status TEXT NOT NULL DEFAULT 'pending', created INTEGER NOT NULL,
      expires INTEGER NOT NULL, verified INTEGER, checks INTEGER NOT NULL DEFAULT 0);
    CREATE INDEX IF NOT EXISTS brand_claims_user ON brand_claims(user_id);
    CREATE INDEX IF NOT EXISTS brand_claims_brand ON brand_claims(brand_id);
    CREATE TABLE IF NOT EXISTS brand_admins (
      brand_id TEXT NOT NULL, user_id TEXT NOT NULL, role TEXT NOT NULL,
      via TEXT NOT NULL, created INTEGER NOT NULL, PRIMARY KEY (brand_id, user_id));`);
}

/// The brand's registrable host: "www.boldenusa.com" -> "boldenusa.com".
export const bareHost = (domain) => String(domain || "").toLowerCase().replace(/^www\./, "").replace(/\/.*$/, "");

/// An email at the brand's own domain (or a subdomain of it). Store
/// platforms' shared domains never count: anyone can have one.
export function emailMatchesBrand(email, domain) {
  const m = /^[^\s@]+@([a-z0-9.-]+\.[a-z]{2,})$/i.exec(String(email || "").trim());
  const host = bareHost(domain);
  if (!m || !host || /(^|\.)(myshopify\.com|shopify\.com|squarespace\.com|wixsite\.com)$/.test(host)) return false;
  const at = m[1].toLowerCase();
  return at === host || at.endsWith("." + host);
}

function grantAdmin(db, brandID, userID, via) {
  const owners = db.prepare("SELECT COUNT(*) AS n FROM brand_admins WHERE brand_id=?").get(brandID).n;
  db.prepare("INSERT OR IGNORE INTO brand_admins(brand_id,user_id,role,via,created) VALUES(?,?,?,?,?)")
    .run(brandID, userID, owners ? "member" : "owner", via, Date.now());
}

export function brandClaimRoutes(app, db, { env = process.env, fetcher = fetch, mailer = null, now = Date.now,
  viewer = (req) => viewerOf(req, db, env), brandLookup = brandRecord } = {}) {
  installBrandClaimSchema(db);
  const router = express.Router();
  router.use(express.json({ limit: "4kb" }));
  router.use(rateLimit({ windowMs: 60_000, limit: 30, standardHeaders: "draft-8", legacyHeaders: false }));

  const signedIn = async (req, res) => {
    const user = await viewer(req);
    if (!user) res.status(401).json({ error: "Sign in to claim a brand." });
    return user;
  };
  const view = (c) => ({ id: c.id, brand: c.brand_id, method: c.method, status: c.status,
    email: c.email || undefined, expires: c.expires });

  // The brands this account speaks for, and its open claims.
  router.get("/me", async (req, res) => {
    const user = await signedIn(req, res);
    if (!user) return;
    res.json({
      brands: db.prepare("SELECT brand_id AS brand, role, via FROM brand_admins WHERE user_id=?").all(user.id),
      claims: db.prepare("SELECT * FROM brand_claims WHERE user_id=? AND status='pending' AND expires>?").all(user.id, now()).map(view),
    });
  });

  // Send a one-time link to an address at the brand's own domain.
  router.post("/email", async (req, res) => {
    const user = await signedIn(req, res);
    if (!user) return;
    const brand = brandLookup(String(req.body?.brand || ""));
    if (!brand) return res.status(404).json({ error: "That brand isn't on Marracat." });
    const email = String(req.body?.email || "").trim().toLowerCase();
    if (!emailMatchesBrand(email, brand.domain))
      return res.status(400).json({ error: `Use an address ending in @${bareHost(brand.domain)}.` });
    if (!mailer) return res.status(503).json({ error: "Email isn't available right now. Try again later." });
    const since = now() - 86400000;
    const forBrand = db.prepare("SELECT COUNT(*) AS n FROM brand_claims WHERE user_id=? AND brand_id=? AND method='email' AND created>?").get(user.id, brand.id, since).n;
    const total = db.prepare("SELECT COUNT(*) AS n FROM brand_claims WHERE user_id=? AND method='email' AND created>?").get(user.id, since).n;
    if (forBrand >= MAX_EMAILS_PER_USER_BRAND_PER_DAY || total >= MAX_EMAILS_PER_USER_PER_DAY)
      return res.status(429).json({ error: "Too many links sent today. Try tomorrow." });
    const token = randomBytes(24).toString("hex");
    const id = randomBytes(9).toString("hex");
    db.prepare("INSERT INTO brand_claims(id,brand_id,user_id,method,email,link_hash,created,expires) VALUES(?,?,?,?,?,?,?,?)")
      .run(id, brand.id, user.id, "email", email, sha(token), now(), now() + LINK_TTL_MS);
    const link = `${env.PUBLIC_URL || "https://marracat.com"}/api/brand-claims/confirm?token=${token}`;
    try {
      await mailer({
        to: email,
        subject: `Confirm you manage ${brand.name} on Marracat`,
        text: `Someone asked to manage ${brand.name} on Marracat with this address.\n\nIf it was you, open this link within 30 minutes:\n${link}\n\nIf not, ignore this email; nothing changes.`,
        html: `<p>Someone asked to manage <b>${escapeHTML(brand.name)}</b> on Marracat with this address.</p><p>If it was you, <a href="${link}">confirm here</a> within 30 minutes.</p><p>If not, ignore this email; nothing changes.</p>`,
      });
    } catch {
      db.prepare("DELETE FROM brand_claims WHERE id=?").run(id);
      return res.status(502).json({ error: "We couldn't send the email. Try again." });
    }
    res.status(201).json({ id, brand: brand.id, method: "email", status: "pending", email });
  });

  // The link in that email. Opening it changes nothing (mail scanners and
  // link previews open links too): it shows a page whose button POSTs, and
  // the POST must come from the same signed-in account that asked
  // (audit 2026-10-07). Single use.
  const claimFor = (token) => /^[a-f0-9]{48}$/.test(token) && db.prepare("SELECT * FROM brand_claims WHERE link_hash=? AND method='email'").get(sha(token));
  const back = (res, state) => res.redirect(303, `/#/for-brands?claim=${state}`);
  router.get("/confirm", (req, res) => {
    const token = String(req.query.token || "");
    const c = claimFor(token);
    if (!c || c.status !== "pending") return back(res, "used");
    if (c.expires <= now()) return back(res, "expired");
    const name = brandLookup(c.brand_id)?.name || c.brand_id;
    res.set({ "Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "X-Frame-Options": "DENY",
      "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'" });
    res.type("html").send(`<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Confirm ${escapeHTML(name)} on Marracat</title>
<style>body{font:16px/1.5 -apple-system,system-ui,sans-serif;max-width:32rem;margin:15vh auto;padding:0 16px;color:#111;background:#fff}
button{font:inherit;padding:.7rem 1.4rem;border:0;border-radius:999px;background:#111;color:#fff;cursor:pointer}</style></head>
<body><h1>Manage ${escapeHTML(name)} on Marracat</h1>
<p>Confirm from the browser where you're signed in to the Marracat account that asked.</p>
<form method="post" action="/api/brand-claims/confirm"><input type="hidden" name="token" value="${escapeHTML(token)}">
<button type="submit">Confirm</button></form></body></html>`);
  });
  router.post("/confirm", express.urlencoded({ extended: false, limit: "1kb" }), async (req, res) => {
    // Same-origin form posts only.
    // A request naming no origin at all is refused too (until 2026-11-12 a
    // missing Origin header passed).
    if (!fromOurPages(req, env)) return res.sendStatus(403);
    const token = String(req.body?.token || "");
    const c = claimFor(token);
    if (!c || c.status !== "pending") return back(res, "used");
    if (c.expires <= now()) return back(res, "expired");
    const user = await viewer(req);
    if (!user) return back(res, "signin");
    if (user.id !== c.user_id) return back(res, "account");
    db.prepare("UPDATE brand_claims SET status='verified', verified=?, link_hash=NULL WHERE id=? AND status='pending'").run(now(), c.id);
    grantAdmin(db, c.brand_id, c.user_id, "domain-email");
    back(res, "verified");
  });

  // The owner's view of who manages which brand.
  router.get("/admin", async (req, res) => {
    const user = await signedIn(req, res);
    if (!user) return;
    if (!isOwnerEmail(user.email)) return res.sendStatus(403);
    res.json({
      admins: db.prepare("SELECT brand_id AS brand, role, via, created FROM brand_admins ORDER BY created DESC").all(),
      claims: db.prepare("SELECT id, brand_id AS brand, method, status, created FROM brand_claims ORDER BY created DESC LIMIT 200").all(),
    });
  });

  app.use("/api/brand-claims", router);
}
