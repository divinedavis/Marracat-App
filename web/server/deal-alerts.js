// Price-drop and brand-sale alerts, by push and email (owner, 2026-10-04: "we
// need to allow people to sign up for product price drops, brand sales - ios
// notifications and emails"). Built on the restock alerts' phones and mailer:
// a signed-in shopper's phones are restock_links -> restock_devices.
//
//  - Price drop: a tracked product's price falls at least DROP below the
//    price it was tracked at (or last alerted at). The alert resets that
//    price, so a further drop alerts again.
//  - Brand sale: a followed brand goes from fewer than SALE_ITEMS products
//    marked down to SALE_ITEMS or more; at most one alert per brand a week.
//
//  - New drops (owner, 2026-10-20: "watch explicitly a brand to get notified
//    when any new products drop", with a choice of departments): a product
//    the watched brand has never had before, in a department the shopper
//    picked (none picked = any). Products seen once are remembered, so one
//    that comes back after a store outage isn't news. New products land with
//    each catalog publish (every 3 h); one alert per brand per publish.
//
// Prices are checked live every 15 minutes (owner, 2026-10-11; was 30):
// Shopify's public product JSON (the same request restock alerts make), up to
// PER_RUN products a run, least recently checked first. Big Cartel stores fall back to the catalog's price,
// which only changes when the catalog is republished. Brand sales use the
// catalog's markdowns.
//
// These emails sell things (sales, price drops, new products), so CAN-SPAM
// treats them as commercial even though the shopper asked for them
// (2026-11-07): each carries Marracat's postal address and a one-click
// unsubscribe (link in the body, List-Unsubscribe + List-Unsubscribe-Post
// headers, RFC 8058) that needs no sign-in. An unsubscribed account gets no
// more alert emails; its pushes, managed in the app, are unchanged. Restock
// alerts (restock.js) are the one-time notice the shopper asked for and are
// left as they are.
import { noteFromAPNs } from "./web-push.js";
import express from "express";
import { createHash, createHmac, timingSafeEqual } from "node:crypto";
import { rateLimit } from "express-rate-limit";
import { productRecord, brandRecord, allProducts } from "./catalog.js";
import { mobileSessionUser } from "./mobile.js";
import { watchable, fetchLive } from "./restock.js";
import { viewerOf } from "./social.js";

export const DROP = 0.05;
export const SALE_ITEMS = 3;
const WEEK = 7 * 86400 * 1000;
const MAX_WATCHES = 200;
const CHECK_EVERY_MS = 15 * 60 * 1000;
const PER_RUN = 300;
const CONCURRENCY = 4;
const sha = (v) => createHash("sha256").update(v).digest("hex");
const esc = (v) => String(v).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const money = (n, cur = "USD") => new Intl.NumberFormat("en-US", { style: "currency", currency: cur }).format(n);

export const POSTAL = "Marracat · 251 Dekalb Ave, Brooklyn, NY 11205";

export function installDealAlertSchema(db) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS email_optouts (user_id TEXT PRIMARY KEY, created INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS price_watches (
      user_id TEXT NOT NULL, product_id TEXT NOT NULL, base_price REAL NOT NULL,
      created INTEGER NOT NULL, last_alert INTEGER, PRIMARY KEY(user_id, product_id));
    CREATE TABLE IF NOT EXISTS brand_watches (
      user_id TEXT NOT NULL, brand_id TEXT NOT NULL, created INTEGER NOT NULL, last_alert INTEGER,
      PRIMARY KEY(user_id, brand_id));
    CREATE TABLE IF NOT EXISTS brand_sale_state (brand_id TEXT PRIMARY KEY, on_sale INTEGER NOT NULL, updated INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS drop_watches (
      user_id TEXT NOT NULL, brand_id TEXT NOT NULL, categories TEXT NOT NULL DEFAULT '[]',
      created INTEGER NOT NULL, last_alert INTEGER, PRIMARY KEY(user_id, brand_id));
    CREATE TABLE IF NOT EXISTS brand_drop_state (brand_id TEXT PRIMARY KEY, seen TEXT NOT NULL, updated INTEGER NOT NULL);`);
  if (!db.prepare("SELECT 1 FROM pragma_table_info('price_watches') WHERE name='checked'").get())
    db.exec("ALTER TABLE price_watches ADD COLUMN checked INTEGER");
}

/// The price a shopper would pay now: live from a Shopify store (product.js
/// gives the lowest variant price in cents), else the catalog's. Null when
/// it can't be bought.
export async function currentPrice(product, { lookup, fetcher = fetch }) {
  const target = watchable(product.id, lookup);
  if (target) {
    const live = await fetchLive(target.url, fetcher);
    if (live && typeof live.price === "number") return live.available === false ? null : live.price / 100;
  }
  return product.available ? product.price : null;
}

export function deleteDealAlertData(db, userID) {
  db.prepare("DELETE FROM price_watches WHERE user_id=?").run(userID);
  db.prepare("DELETE FROM brand_watches WHERE user_id=?").run(userID);
  db.prepare("DELETE FROM drop_watches WHERE user_id=?").run(userID);
}

/// Whether a product's price fell enough to tell the shopper.
export const droppedEnough = (base, now) => now > 0 && now <= base * (1 - DROP) + 1e-9;

/// Products marked down (compare-at above price) and buyable, per brand.
export function saleCounts(products) {
  const out = new Map();
  for (const p of products) if (p.available && p.compare_at > p.price) out.set(p.brand, (out.get(p.brand) || 0) + 1);
  return out;
}

export function priceDropEmail({ to, name, title, brand, productID, was, now, currency }) {
  const link = `https://marracat.com/p/${encodeURIComponent(productID)}`;
  const hi = name ? `Hi ${String(name).split(" ")[0]},` : "Hi,";
  return {
    to, subject: `Price drop: ${title} is now ${money(now, currency)}`,
    text: `${hi}\n\n${title} from ${brand} dropped from ${money(was, currency)} to ${money(now, currency)}.\n\n${link}\n\nYou're tracking its price on Marracat. Stop in the app under You > Alerts.`,
    html: `<p>${esc(hi)}</p><p><strong>${esc(title)}</strong> from ${esc(brand)} dropped from ${esc(money(was, currency))} to <strong>${esc(money(now, currency))}</strong>.</p><p><a href="${esc(link)}">See it on Marracat</a></p><p style="color:#666;font-size:13px">You're tracking its price on Marracat. Stop in the app under You &gt; Alerts.</p>`,
  };
}

export function brandSaleEmail({ to, name, brand, brandID, count }) {
  const link = `https://marracat.com/b/${encodeURIComponent(brandID)}`;
  const hi = name ? `Hi ${String(name).split(" ")[0]},` : "Hi,";
  return {
    to, subject: `${brand} is having a sale`,
    text: `${hi}\n\n${brand} has ${count} items marked down right now.\n\n${link}\n\nYou follow ${brand}'s sales on Marracat. Stop in the app under You > Alerts.`,
    html: `<p>${esc(hi)}</p><p><strong>${esc(brand)}</strong> has ${count} items marked down right now.</p><p><a href="${esc(link)}">Shop the sale on Marracat</a></p><p style="color:#666;font-size:13px">You follow ${esc(brand)}'s sales on Marracat. Stop in the app under You &gt; Alerts.</p>`,
  };
}

/// Up to this many product ids remembered per brand: far more than any
/// store's catalog, so a returning product is never mistaken for a new one.
const SEEN_CAP = 20000;

/// A brand's products that aren't in `seen`, buyable, newest first.
export function newDrops(products, seen) {
  return products.filter((p) => p.available !== false && !seen.has(p.id))
    .sort((a, b) => String(b.published_at || "").localeCompare(String(a.published_at || "")));
}

/// The new products a shopper asked about: all, or only the departments picked.
export function dropsFor(drops, categories) {
  return categories.length ? drops.filter((p) => categories.includes(p.category)) : drops;
}

export function dropEmail({ to, name, brand, brandID, products }) {
  const link = `https://marracat.com/b/${encodeURIComponent(brandID)}`;
  const hi = name ? `Hi ${String(name).split(" ")[0]},` : "Hi,";
  const lines = products.slice(0, 5).map((p) => p.title);
  const more = products.length > 5 ? products.length - 5 : 0;
  return {
    to, subject: products.length === 1 ? `New from ${brand}: ${products[0].title}` : `${products.length} new from ${brand}`,
    text: `${hi}\n\n${brand} just dropped:\n${lines.map((t) => `- ${t}`).join("\n")}${more ? `\n…and ${more} more` : ""}\n\n${link}\n\nYou watch ${brand}'s new drops on Marracat. Stop on the brand's page or under You > Alerts.`,
    html: `<p>${esc(hi)}</p><p><strong>${esc(brand)}</strong> just dropped:</p><ul>${lines.map((t) => `<li>${esc(t)}</li>`).join("")}</ul>${more ? `<p>…and ${more} more</p>` : ""}<p><a href="${esc(link)}">See what's new</a></p><p style="color:#666;font-size:13px">You watch ${esc(brand)}'s new drops on Marracat. Stop on the brand's page or under You &gt; Alerts.</p>`,
  };
}

/// The unsubscribe link's proof that it was made for this account: an HMAC
/// of the account id under the server's AUTH_SECRET, so no one can opt out
/// someone else by guessing ids.
export const unsubscribeToken = (userID, secret) =>
  createHmac("sha256", "deal-email-unsubscribe:" + secret).update(String(userID)).digest("base64url");
export const unsubscribeURL = (userID, secret) =>
  `https://marracat.com/api/email/unsubscribe?u=${encodeURIComponent(userID)}&t=${unsubscribeToken(userID, secret)}`;

/// An alert email with the CAN-SPAM footer and one-click unsubscribe headers.
export function withFooter(message, link) {
  const text = `\n\n--\nUnsubscribe from Marracat alert emails: ${link}\n${POSTAL}`;
  const html = `<p style="color:#666;font-size:13px"><a href="${esc(link)}">Unsubscribe from Marracat alert emails</a><br>${esc(POSTAL)}</p>`;
  return { ...message, text: message.text + text, html: message.html + html,
    headers: { ...message.headers, "List-Unsubscribe": `<${link}>`, "List-Unsubscribe-Post": "List-Unsubscribe=One-Click" } };
}

export const emailOptedOut = (db, userID) => !!db.prepare("SELECT 1 FROM email_optouts WHERE user_id=?").get(userID);

/// Push to every phone signed in to the account and every browser it turned
/// notifications on in, and email. True if any landed.
/// No email without a secret to sign the unsubscribe link, or after an unsubscribe.
async function notify(db, { apns, mail, webPush, log, secret }, userID, push, email) {
  let delivered = false;
  if (webPush && (await webPush.sendToUser(db, userID, noteFromAPNs(push)).catch(() => false))) delivered = true;
  const devices = db.prepare(`SELECT d.hash, d.token, d.environment FROM restock_links l
    JOIN restock_devices d ON d.hash=l.device WHERE l.user_id=? AND d.token IS NOT NULL`).all(userID);
  for (const device of devices) {
    const result = await apns.send({ token: device.token, environment: device.environment }, push);
    if (result.status === 200) delivered = true;
    else if (result.status === 410) {
      db.prepare("DELETE FROM restock_links WHERE device=?").run(device.hash);
      db.prepare("DELETE FROM restock_devices WHERE hash=?").run(device.hash);
    } else log(`Deal push not delivered (${result.status} ${result.reason})`);
  }
  const user = db.prepare("SELECT email, name FROM users WHERE id=?").get(userID);
  if (mail && email && secret && !emailOptedOut(db, userID) && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(user?.email || "")) {
    try { await mail(withFooter(email({ to: user.email, name: user.name }), unsubscribeURL(userID, secret))); delivered = true; }
    catch (e) { log(`Deal email not delivered (${e.code || e.name})`); }
  }
  return delivered;
}

export async function checkDeals(db, { apns, mail, webPush, secret, lookup = { productRecord, brandRecord, allProducts }, fetcher = fetch, now = Date.now, log = console.log } = {}) {
  let drops = 0, sales = 0;
  // Price drops: each tracked product once, least recently checked first.
  const ids = db.prepare(`SELECT product_id, MIN(COALESCE(checked,0)) AS last FROM price_watches
    GROUP BY product_id ORDER BY last LIMIT ?`).all(PER_RUN).map((r) => r.product_id);
  const queue = [...ids];
  const worker = async () => {
    for (let id; (id = queue.shift()); ) {
      const p = lookup.productRecord(id);
      const price = p ? await currentPrice(p, { lookup, fetcher }) : null;
      db.prepare("UPDATE price_watches SET checked=? WHERE product_id=?").run(now(), id);
      if (price == null) continue;
      const brand = lookup.brandRecord(p.brand)?.name || "";
      for (const w of db.prepare("SELECT user_id, base_price FROM price_watches WHERE product_id=?").all(id)) {
        if (!droppedEnough(w.base_price, price)) continue;
        const ok = await notify(db, { apns, mail, webPush, log, secret }, w.user_id,
          { aps: { alert: { title: "Price drop", body: `${p.title} is now ${money(price, p.currency)} at ${brand}` }, sound: "default" }, productID: p.id },
          (u) => priceDropEmail({ ...u, title: p.title, brand, productID: p.id, was: w.base_price, now: price, currency: p.currency || "USD" }));
        if (ok) { drops++; db.prepare("UPDATE price_watches SET base_price=?, last_alert=? WHERE user_id=? AND product_id=?").run(price, now(), w.user_id, id); }
      }
    }
  };
  await Promise.all(Array.from({ length: CONCURRENCY }, worker));
  // Brand sales: compare with the last count seen.
  const counts = saleCounts(lookup.allProducts());
  const followed = db.prepare("SELECT DISTINCT brand_id FROM brand_watches").all().map((r) => r.brand_id);
  for (const brandID of followed) {
    const count = counts.get(brandID) || 0;
    const prev = db.prepare("SELECT on_sale FROM brand_sale_state WHERE brand_id=?").get(brandID);
    db.prepare(`INSERT INTO brand_sale_state(brand_id,on_sale,updated) VALUES(?,?,?)
      ON CONFLICT(brand_id) DO UPDATE SET on_sale=excluded.on_sale, updated=excluded.updated`).run(brandID, count, now());
    // The first look only records the count: a sale already running when
    // someone followed isn't news.
    if (!prev || prev.on_sale >= SALE_ITEMS || count < SALE_ITEMS) continue;
    const brand = lookup.brandRecord(brandID)?.name || "A brand you follow";
    for (const w of db.prepare("SELECT user_id, last_alert FROM brand_watches WHERE brand_id=?").all(brandID)) {
      if (w.last_alert && now() - w.last_alert < WEEK) continue;
      const ok = await notify(db, { apns, mail, webPush, log, secret }, w.user_id,
        { aps: { alert: { title: `${brand} is having a sale`, body: `${count} items marked down` }, sound: "default" }, brandID },
        (u) => brandSaleEmail({ ...u, brand, brandID, count }));
      if (ok) { sales++; db.prepare("UPDATE brand_watches SET last_alert=? WHERE user_id=? AND brand_id=?").run(now(), w.user_id, brandID); }
    }
  }
  const fresh = await checkNewDrops(db, { apns, mail, webPush, secret, lookup, now, log });
  return { drops, sales, fresh };
}

/// New drops from watched brands since the last look. The first look at a
/// brand only remembers what it has.
export async function checkNewDrops(db, { apns, mail, webPush, secret, lookup = { productRecord, brandRecord, allProducts }, now = Date.now, log = console.log } = {}) {
  const watched = db.prepare("SELECT DISTINCT brand_id FROM drop_watches").all().map((r) => r.brand_id);
  if (!watched.length) return 0;
  const byBrand = new Map();
  for (const p of lookup.allProducts()) {
    if (!watched.includes(p.brand)) continue;
    if (!byBrand.has(p.brand)) byBrand.set(p.brand, []);
    byBrand.get(p.brand).push(p);
  }
  let sent = 0;
  for (const brandID of watched) {
    const products = byBrand.get(brandID) || [];
    const prev = db.prepare("SELECT seen FROM brand_drop_state WHERE brand_id=?").get(brandID);
    const seen = new Set(prev ? JSON.parse(prev.seen) : []);
    const drops = prev ? newDrops(products, seen) : [];
    for (const p of products) seen.add(p.id);
    const kept = [...seen].slice(-SEEN_CAP);
    db.prepare(`INSERT INTO brand_drop_state(brand_id,seen,updated) VALUES(?,?,?)
      ON CONFLICT(brand_id) DO UPDATE SET seen=excluded.seen, updated=excluded.updated`).run(brandID, JSON.stringify(kept), now());
    if (!drops.length) continue;
    const brand = lookup.brandRecord(brandID)?.name || "A brand you watch";
    for (const w of db.prepare("SELECT user_id, categories FROM drop_watches WHERE brand_id=?").all(brandID)) {
      let cats = [];
      try { cats = JSON.parse(w.categories); } catch { cats = []; }
      const mine = dropsFor(drops, cats);
      if (!mine.length) continue;
      const body = mine.length === 1 ? mine[0].title : `${mine.length} new products, including ${mine[0].title}`;
      const push = mine.length === 1
        ? { aps: { alert: { title: `New from ${brand}`, body }, sound: "default" }, productID: mine[0].id }
        : { aps: { alert: { title: `New from ${brand}`, body }, sound: "default" }, brandID };
      const ok = await notify(db, { apns, mail, webPush, log, secret }, w.user_id, push, (u) => dropEmail({ ...u, brand, brandID, products: mine }));
      if (ok) { sent++; db.prepare("UPDATE drop_watches SET last_alert=? WHERE user_id=? AND brand_id=?").run(now(), w.user_id, brandID); }
    }
  }
  return sent;
}

export function dealAlertRoutes(app, db, { env = process.env, apns, mail, webPush = null, lookup = { productRecord, brandRecord, allProducts }, schedule = env.NODE_ENV === "production" } = {}) {
  installDealAlertSchema(db);
  const secret = env.AUTH_SECRET || "";
  // One click, no sign-in (CAN-SPAM: no steps beyond visiting one page).
  // GET is the link in the email; POST is the mail app's RFC 8058 one-click.
  const unsubscribe = (req, res) => {
    res.set({ "Cache-Control": "no-store", "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'" });
    const userID = String(req.query.u || "").slice(0, 200), token = String(req.query.t || "");
    const want = secret && userID ? Buffer.from(unsubscribeToken(userID, secret)) : null;
    if (!want || Buffer.byteLength(token) !== want.length || !timingSafeEqual(Buffer.from(token), want))
      return res.status(400).type("html").send(page("This unsubscribe link isn't valid. Reply to any Marracat email with \"unsubscribe\" and we'll take you off the list."));
    db.prepare("INSERT OR IGNORE INTO email_optouts(user_id,created) VALUES(?,?)").run(userID, Date.now());
    res.type("html").send(page("You're unsubscribed. Marracat won't email you price, sale or new-drop alerts again. Phone notifications are in the app under You &gt; Alerts."));
  };
  const page = (msg) => `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Marracat</title>` +
    `<body style="font-family:Arial,sans-serif;max-width:32rem;margin:15vh auto;padding:0 1rem;color:#111"><h1 style="font-size:1.4rem">Marracat</h1><p>${msg}</p><p style="color:#666;font-size:13px">${esc(POSTAL)}</p></body>`;
  const limited = rateLimit({ windowMs: 60_000, limit: 30, standardHeaders: "draft-8", legacyHeaders: false });
  app.get("/api/email/unsubscribe", limited, unsubscribe);
  app.post("/api/email/unsubscribe", limited, unsubscribe);
  const router = express.Router();
  router.use((req, res, next) => { res.set("Cache-Control", "no-store"); next(); });
  router.use(rateLimit({ windowMs: 60_000, limit: 60, standardHeaders: "draft-8", legacyHeaders: false }));
  router.use(express.json({ limit: "4kb" }));
  // The app (bearer token) or the website (session); a phone that calls with
  // its device key is linked to the account so pushes reach it.
  router.use(async (req, res, next) => {
    const user = mobileSessionUser(db, req) || await viewerOf(req, db, env).catch(() => null);
    if (!user) return res.status(401).json({ error: "Sign in to get price and sale alerts" });
    req.user = user;
    const key = req.get("X-Marracat-Device");
    if (key && /^[a-f0-9]{64}$/.test(key)) db.prepare(`INSERT INTO restock_links(device,user_id,updated) VALUES(?,?,?)
      ON CONFLICT(device) DO UPDATE SET user_id=excluded.user_id, updated=excluded.updated`).run(sha(key), user.id, Date.now());
    next();
  });
  const mine = (id) => ({
    prices: db.prepare("SELECT product_id AS productID, base_price AS price, created FROM price_watches WHERE user_id=? ORDER BY created DESC").all(id),
    brands: db.prepare("SELECT brand_id AS brandID, created FROM brand_watches WHERE user_id=? ORDER BY created DESC").all(id),
    drops: db.prepare("SELECT brand_id AS brandID, categories, created FROM drop_watches WHERE user_id=? ORDER BY created DESC").all(id)
      .map((r) => ({ ...r, categories: JSON.parse(r.categories || "[]") })),
  });
  const count = (id) => db.prepare(`SELECT (SELECT COUNT(*) FROM price_watches WHERE user_id=?) + (SELECT COUNT(*) FROM brand_watches WHERE user_id=?)
    + (SELECT COUNT(*) FROM drop_watches WHERE user_id=?) AS n`).get(id, id, id).n;
  router.get("/", (req, res) => res.json(mine(req.user.id)));
  router.post("/price", (req, res) => {
    const p = lookup.productRecord(String(req.body?.productID || ""));
    if (!p) return res.status(404).json({ error: "That isn't on Marracat" });
    if (count(req.user.id) >= MAX_WATCHES) return res.status(429).json({ error: `Up to ${MAX_WATCHES} alerts` });
    db.prepare(`INSERT INTO price_watches(user_id,product_id,base_price,created) VALUES(?,?,?,?)
      ON CONFLICT(user_id,product_id) DO UPDATE SET base_price=excluded.base_price, created=excluded.created`).run(req.user.id, p.id, p.price, Date.now());
    res.status(201).json(mine(req.user.id));
  });
  router.delete("/price", (req, res) => {
    db.prepare("DELETE FROM price_watches WHERE user_id=? AND product_id=?").run(req.user.id, String(req.body?.productID || ""));
    res.json(mine(req.user.id));
  });
  router.post("/brand", (req, res) => {
    const b = lookup.brandRecord(String(req.body?.brandID || ""));
    if (!b) return res.status(404).json({ error: "That brand isn't on Marracat" });
    if (count(req.user.id) >= MAX_WATCHES) return res.status(429).json({ error: `Up to ${MAX_WATCHES} alerts` });
    db.prepare("INSERT OR IGNORE INTO brand_watches(user_id,brand_id,created) VALUES(?,?,?)").run(req.user.id, b.id, Date.now());
    res.status(201).json(mine(req.user.id));
  });
  router.delete("/brand", (req, res) => {
    db.prepare("DELETE FROM brand_watches WHERE user_id=? AND brand_id=?").run(req.user.id, String(req.body?.brandID || ""));
    res.json(mine(req.user.id));
  });
  // New drops: the departments to hear about ([] = everything new). Posting
  // again changes them.
  router.post("/drops", (req, res) => {
    const b = lookup.brandRecord(String(req.body?.brandID || ""));
    if (!b) return res.status(404).json({ error: "That brand isn't on Marracat" });
    const raw = Array.isArray(req.body?.categories) ? req.body.categories : [];
    const categories = [...new Set(raw.filter((c) => typeof c === "string" && /^[a-z0-9-]{1,40}$/.test(c)))].slice(0, 40);
    const exists = db.prepare("SELECT 1 FROM drop_watches WHERE user_id=? AND brand_id=?").get(req.user.id, b.id);
    if (!exists && count(req.user.id) >= MAX_WATCHES) return res.status(429).json({ error: `Up to ${MAX_WATCHES} alerts` });
    db.prepare(`INSERT INTO drop_watches(user_id,brand_id,categories,created) VALUES(?,?,?,?)
      ON CONFLICT(user_id,brand_id) DO UPDATE SET categories=excluded.categories`).run(req.user.id, b.id, JSON.stringify(categories), Date.now());
    res.status(201).json(mine(req.user.id));
  });
  router.delete("/drops", (req, res) => {
    db.prepare("DELETE FROM drop_watches WHERE user_id=? AND brand_id=?").run(req.user.id, String(req.body?.brandID || ""));
    res.json(mine(req.user.id));
  });
  app.use("/api/alerts", router);

  if (schedule) {
    let running = false;
    const run = async () => {
      if (running) return;
      running = true;
      try {
        const r = await checkDeals(db, { apns, mail, webPush, secret, lookup });
        if (r.drops || r.sales || r.fresh) console.log(`Deal alerts: ${r.drops} price drops, ${r.sales} brand sales, ${r.fresh} new drops`);
      } catch (e) { console.error("Deal alert check failed:", e.name); } finally { running = false; }
    };
    setTimeout(run, 90_000).unref();
    setInterval(run, CHECK_EVERY_MS).unref();
  }
}
