import express from "express";
import { createHash, createPrivateKey, sign } from "node:crypto";
import { connect } from "node:http2";
import { readFileSync } from "node:fs";
import { rateLimit } from "express-rate-limit";
import nodemailer from "nodemailer";
import { productRecord, brandRecord } from "./catalog.js";
import { mobileSessionUser } from "./mobile.js";
import { getStoreJSON } from "./store-fetch.js";

// "Notify me when it's back": an app shopper asks to hear when a sold-out
// product (or one option of it) is back, and gets a push when the brand's own
// store says it is (owner, 2026-09-30).
//
// Signed-in shoppers only (owner, 2026-10-02): an alert belongs to the
// account, and when the item is back it goes out as an email to the account's
// address and as a push to every phone currently signed in to that account.
// A phone is known by a random 256-bit per-install key (X-Marracat-Device);
// only its hash is stored, next to the APNs token. restock_links says which
// account is signed in on which phone: set on every signed-in call, removed
// when the app signs out, so a signed-out phone gets no alert pushes.
//
// A job checks only watched products, against the brand's live Shopify
// product JSON (/products/<handle>.js), a bounded number per run.

const hash = (value) => createHash("sha256").update(value).digest("hex");
const MAX_ALERTS = 100;
// Every 5 minutes (owner, 2026-09-30): brands' stores send us no webhooks, so
// polling often is the closest thing to real time. A run skips if the last
// one is still going, and PER_RUN keeps a long watch list light on the stores.
export const CHECK_EVERY_MS = 5 * 60_000;
const PER_RUN = 300;          // products checked per run, at most
const CONCURRENCY = 4;
const FETCH_TIMEOUT_MS = 10_000;

export function installRestockSchema(db) {
  // Until 2026-10-02 alerts were per phone (restock_alerts, keyed by device);
  // that table never held a row in production and is dropped.
  db.exec(`
    DROP TABLE IF EXISTS restock_alerts;
    CREATE TABLE IF NOT EXISTS restock_devices (hash TEXT PRIMARY KEY, token TEXT, environment TEXT, updated INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS restock_links (device TEXT PRIMARY KEY, user_id TEXT NOT NULL, updated INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS restock_links_user ON restock_links(user_id);
    CREATE TABLE IF NOT EXISTS restock_watches (
      user_id TEXT NOT NULL, product_id TEXT NOT NULL, variant_id TEXT NOT NULL DEFAULT '',
      created INTEGER NOT NULL, checked INTEGER, fulfilled INTEGER,
      PRIMARY KEY(user_id, product_id, variant_id));
    CREATE INDEX IF NOT EXISTS restock_watches_open ON restock_watches(fulfilled, product_id);
  `);
  installDeviceTimeZone(db);
}

// The phone's time zone, so "Arriving today" lands in its morning (relay.js).
export function installDeviceTimeZone(db) {
  db.exec("CREATE TABLE IF NOT EXISTS restock_devices (hash TEXT PRIMARY KEY, token TEXT, environment TEXT, updated INTEGER NOT NULL)");
  if (!db.prepare("SELECT 1 FROM pragma_table_info('restock_devices') WHERE name='tz'").get())
    db.exec("ALTER TABLE restock_devices ADD COLUMN tz TEXT");
}
const validTimeZone = (tz) => {
  if (typeof tz !== "string" || tz.length > 64) return null;
  try { new Intl.DateTimeFormat("en-US", { timeZone: tz }); return tz; } catch { return null; }
};

// Deleting the account takes its alerts and phone links with it.
export function deleteRestockData(db, userID) {
  db.prepare("DELETE FROM restock_watches WHERE user_id=?").run(userID);
  db.prepare("DELETE FROM restock_links WHERE user_id=?").run(userID);
}

// ---- email ---------------------------------------------------------------

// The same mailbox the order email sends from (hello@marracat.com).
export function restockMailer(env = process.env) {
  if (!env.RELAY_SMTP_HOST || !env.RELAY_SMTP_USER || !env.RELAY_SMTP_PASS) return null;
  const port = Number(env.RELAY_SMTP_PORT || 465);
  const transport = nodemailer.createTransport({ host: env.RELAY_SMTP_HOST, port, secure: port === 465,
    auth: { user: env.RELAY_SMTP_USER, pass: env.RELAY_SMTP_PASS } });
  const from = { name: "Marracat", address: env.RELAY_SMTP_USER };
  return (message) => transport.sendMail({ from, ...message });
}

const escapeHTML = (v) => String(v).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

export function restockEmail({ to, name, title, brand, productID }) {
  // A universal link (/.well-known/apple-app-site-association claims /p/*):
  // with the app installed iOS opens the product there, otherwise the same
  // URL opens it on marracat.com. The old /#/product link could only ever
  // open the website, since universal links never see the part after "#".
  const link = `https://marracat.com/p/${encodeURIComponent(productID)}`;
  const hi = name ? `Hi ${String(name).split(" ")[0]},` : "Hi,";
  return {
    to,
    subject: `Back in stock: ${title}`,
    text: `${hi}\n\n${title} is back in stock at ${brand}.\n\n${link}\n\nOpen Marracat to buy it before it sells out again.\n\n` +
      `You asked Marracat to tell you when this was back. This was a one-time alert; turn alerts off in the app under You > Restock alerts.`,
    html: `<p>${escapeHTML(hi)}</p><p><strong>${escapeHTML(title)}</strong> is back in stock at ${escapeHTML(brand)}.</p>` +
      `<p><a href="${escapeHTML(link)}">See it on Marracat</a></p>` +
      `<p style="color:#666;font-size:13px">You asked Marracat to tell you when this was back. This was a one-time alert; turn alerts off in the app under You &gt; Restock alerts.</p>`,
  };
}

// The watched thing's name, store and live-JSON URL, or null when the catalog
// doesn't have it or the brand isn't a Shopify store.
export function watchable(productID, lookup = { productRecord, brandRecord }) {
  const product = lookup.productRecord(productID);
  const brand = product && lookup.brandRecord(product.brand);
  if (!product || !brand || (brand.platform ?? "shopify") !== "shopify") return null;
  let url;
  try { url = new URL(product.url); } catch { return null; }
  if (url.protocol !== "https:" || !/^\/products\/[^/]+\/?$/.test(url.pathname)) return null;
  url.pathname = url.pathname.replace(/\/$/, "") + ".js";
  url.search = "";
  return { title: product.title, brand: brand.name, url: url.toString() };
}

// Whether the live product (or the one watched option) can be bought.
export function inStock(live, variantID) {
  if (!live || !Array.isArray(live.variants)) return false;
  if (!variantID) return live.available === true || live.variants.some((v) => v.available === true);
  return live.variants.some((v) => String(v.id) === variantID && v.available === true);
}

// ---- APNs --------------------------------------------------------------

export function apnsSender(env = process.env, { connectTo = connect, now = () => Date.now() } = {}) {
  const configured = Boolean(env.APNS_KEY_PATH && env.APNS_KEY_ID && env.APNS_TEAM_ID);
  const topic = env.APNS_TOPIC || "com.divinedavis.marracat";
  let key, jwt, minted = 0;
  const token = () => {
    // Apple wants a fresh provider token between 20 and 60 minutes old.
    if (jwt && now() - minted < 40 * 60_000) return jwt;
    key ??= createPrivateKey(readFileSync(env.APNS_KEY_PATH, "utf8"));
    const b64 = (v) => Buffer.from(typeof v === "string" ? v : JSON.stringify(v)).toString("base64url");
    const head = b64({ alg: "ES256", kid: env.APNS_KEY_ID });
    const body = b64({ iss: env.APNS_TEAM_ID, iat: Math.floor(now() / 1000) });
    // Apple takes the raw r||s signature, not OpenSSL's DER.
    const signature = sign("sha256", Buffer.from(`${head}.${body}`), { key, dsaEncoding: "ieee-p1363" }).toString("base64url");
    minted = now();
    jwt = `${head}.${body}.${signature}`;
    return jwt;
  };
  const host = (environment) => environment === "sandbox" ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
  // Live Activity pushes (live-activity.js) go to "<bundle>.push-type.liveactivity"
  // with apns-push-type liveactivity, per Apple's "Starting and updating Live
  // Activities with ActivityKit push notifications"; the same team key signs them.
  const post = (environment, deviceToken, payload, { pushType = "alert", priority = 10 } = {}) => new Promise((resolve) => {
    const session = connectTo(host(environment));
    session.on("error", () => resolve({ status: 0, reason: "connection" }));
    const req = session.request({
      ":method": "POST", ":path": `/3/device/${deviceToken}`,
      authorization: `bearer ${token()}`,
      "apns-topic": pushType === "liveactivity" ? `${topic}.push-type.liveactivity` : topic,
      "apns-push-type": pushType === "liveactivity" ? "liveactivity" : "alert",
      "apns-priority": priority === 5 ? "5" : "10",
      "content-type": "application/json",
    });
    let status = 0, data = "";
    req.setTimeout(FETCH_TIMEOUT_MS, () => { req.close(); });
    req.on("response", (h) => { status = h[":status"]; });
    req.on("data", (c) => { data += c; });
    req.on("close", () => {
      session.close();
      let reason = "";
      try { reason = JSON.parse(data).reason || ""; } catch {}
      resolve({ status, reason });
    });
    req.on("error", () => {});
    req.end(JSON.stringify(payload));
  });
  // The stored environment is the device's claim and can be wrong; on
  // BadDeviceToken try the other host and report which one took it.
  async function send(device, payload, options = {}) {
    if (!configured) return { status: 0, reason: "not_configured" };
    const first = device.environment === "sandbox" ? "sandbox" : "production";
    let result = await post(first, device.token, payload, options);
    if (result.status === 400 && result.reason === "BadDeviceToken") {
      const other = first === "sandbox" ? "production" : "sandbox";
      const retry = await post(other, device.token, payload, options);
      if (retry.status === 200) return { ...retry, environment: other };
      return retry.status === 410 ? retry : result;
    }
    return { ...result, environment: first };
  }
  return { configured: () => configured, send };
}

// ---- the check ---------------------------------------------------------

// At most one redirect, and only to the same store's /products/<handle>.js
// (store-fetch.js). Until 2026-11-12 this followed any redirect, so a store's
// domain could send the server to an internal address.
export async function fetchLive(url, fetcher) {
  try {
    return await getStoreJSON(url, fetcher, { max: 2_000_000, timeoutMs: FETCH_TIMEOUT_MS, path: /^\/products\/[^/]+\.js$/ });
  } catch { return null; }
}

export async function checkRestocks(db, { apns, mail = null, fetcher = fetch, lookup = { productRecord, brandRecord }, now = Date.now, log = console.log, onLive = null } = {}) {
  // The least recently checked products first, so a long list rotates.
  const products = db.prepare(`SELECT product_id, MIN(COALESCE(checked,0)) AS last FROM restock_watches
    WHERE fulfilled IS NULL GROUP BY product_id ORDER BY last LIMIT ?`).all(PER_RUN).map((r) => r.product_id);
  let checked = 0, back = 0, sent = 0, emailed = 0;
  const queue = [...products];
  const worker = async () => {
    for (let id; (id = queue.shift()); ) {
      const target = watchable(id, lookup);
      if (!target) continue;
      const live = await fetchLive(target.url, fetcher);
      checked++;
      db.prepare("UPDATE restock_watches SET checked=? WHERE product_id=? AND fulfilled IS NULL").run(now(), id);
      if (!live) continue;
      // Product pages read live stock too (live-stock.js); the page a push
      // opens should see what the push saw.
      try { onLive?.(id, live); } catch {}
      const watches = db.prepare(`SELECT w.user_id, w.variant_id, u.email, u.name FROM restock_watches w
        JOIN users u ON u.id=w.user_id WHERE w.product_id=? AND w.fulfilled IS NULL`).all(id);
      for (const watch of watches) {
        if (!inStock(live, watch.variant_id)) continue;
        back++;
        let delivered = false;
        // Every phone signed in to the account right now.
        const devices = db.prepare(`SELECT d.hash, d.token, d.environment FROM restock_links l
          JOIN restock_devices d ON d.hash=l.device WHERE l.user_id=? AND d.token IS NOT NULL`).all(watch.user_id);
        const payload = {
          aps: { alert: { title: "Back in stock", body: `${target.title} is back in stock at ${target.brand}` }, sound: "default" },
          productID: id,
        };
        for (const device of devices) {
          const result = await apns.send({ token: device.token, environment: device.environment }, payload);
          if (result.status === 200) {
            delivered = true; sent++;
            if (result.environment && result.environment !== device.environment)
              db.prepare("UPDATE restock_devices SET environment=? WHERE hash=?").run(result.environment, device.hash);
          } else if (result.status === 410) {
            // The app is gone from that phone; the account's alerts stay.
            db.prepare("DELETE FROM restock_links WHERE device=?").run(device.hash);
            db.prepare("DELETE FROM restock_devices WHERE hash=?").run(device.hash);
          } else {
            log(`Restock push not delivered (${result.status} ${result.reason})`);
          }
        }
        if (mail && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(watch.email || "")) {
          try {
            await mail(restockEmail({ to: watch.email, name: watch.name, title: target.title, brand: target.brand, productID: id }));
            delivered = true; emailed++;
          } catch (e) { log(`Restock email not delivered (${e.code || e.name})`); }
        }
        if (delivered) db.prepare("UPDATE restock_watches SET fulfilled=? WHERE user_id=? AND product_id=? AND variant_id=?").run(now(), watch.user_id, id, watch.variant_id);
      }
    }
  };
  await Promise.all(Array.from({ length: CONCURRENCY }, worker));
  return { products: products.length, checked, back, sent, emailed };
}

// ---- routes ------------------------------------------------------------

const deviceKey = /^[a-f0-9]{64}$/;
const apnsToken = /^[a-f0-9]{64,200}$/;

export function restockRoutes(app, db, { env = process.env, apns = apnsSender(env), mail = restockMailer(env), lookup = { productRecord, brandRecord }, schedule = env.NODE_ENV === "production", onLive = null } = {}) {
  installRestockSchema(db);
  const router = express.Router();
  router.use((req, res, next) => { res.set("Cache-Control", "no-store"); next(); });
  router.use(rateLimit({ windowMs: 60_000, limit: 60, standardHeaders: "draft-8", legacyHeaders: false }));
  router.use(express.json({ limit: "8kb" }));
  router.use((req, res, next) => {
    const key = req.get("X-Marracat-Device");
    if (!key || !deviceKey.test(key)) return res.status(401).json({ error: "Missing device key" });
    req.device = hash(key);
    next();
  });
  // Alerts are for signed-in shoppers. Each signed-in call also records that
  // this phone is signed in to this account, which is where pushes go.
  const signedIn = (req, res, next) => {
    const user = mobileSessionUser(db, req);
    if (!user) return res.status(401).json({ error: "Sign in to get restock alerts" });
    req.user = user;
    db.prepare(`INSERT INTO restock_links(device,user_id,updated) VALUES(?,?,?)
      ON CONFLICT(device) DO UPDATE SET user_id=excluded.user_id, updated=excluded.updated`).run(req.device, user.id, Date.now());
    next();
  };
  const list = (userID) => db.prepare(`SELECT product_id AS productID, variant_id AS variantID, created FROM restock_watches
    WHERE user_id=? AND fulfilled IS NULL ORDER BY created DESC`).all(userID)
    .map((a) => ({ productID: a.productID, variantID: a.variantID || null, created: a.created }));

  // The push token. No account needed: order tracking and the order email
  // use the same registration.
  router.put("/device", (req, res) => {
    const { token, environment, timeZone } = req.body || {};
    if (typeof token !== "string" || !apnsToken.test(token) || !["production", "sandbox"].includes(environment))
      return res.status(400).json({ error: "Invalid notification token" });
    db.prepare(`INSERT INTO restock_devices(hash,token,environment,updated,tz) VALUES(?,?,?,?,?)
      ON CONFLICT(hash) DO UPDATE SET token=excluded.token, environment=excluded.environment, updated=excluded.updated, tz=COALESCE(excluded.tz, restock_devices.tz)`)
      .run(req.device, token, environment, Date.now(), validTimeZone(timeZone));
    res.sendStatus(204);
  });
  // Signing out: this phone stops getting the account's alert pushes. The
  // device key alone is enough; it only ever unlinks the caller's own phone.
  router.delete("/link", (req, res) => {
    db.prepare("DELETE FROM restock_links WHERE device=?").run(req.device);
    res.sendStatus(204);
  });
  router.get("/alerts", signedIn, (req, res) => res.json({ alerts: list(req.user.id) }));
  router.post("/alerts", signedIn, (req, res) => {
    const { productID, variantID } = req.body || {};
    if (typeof productID !== "string" || productID.length > 200) return res.status(400).json({ error: "Invalid product" });
    if (variantID != null && !(typeof variantID === "string" && /^\d{1,20}$/.test(variantID))) return res.status(400).json({ error: "Invalid option" });
    if (!watchable(productID, lookup)) return res.status(422).json({ error: "Alerts aren't available for this item" });
    const open = db.prepare("SELECT COUNT(*) AS n FROM restock_watches WHERE user_id=? AND fulfilled IS NULL").get(req.user.id).n;
    if (open >= MAX_ALERTS) return res.status(429).json({ error: `You can watch up to ${MAX_ALERTS} items` });
    db.prepare(`INSERT INTO restock_watches(user_id,product_id,variant_id,created) VALUES(?,?,?,?)
      ON CONFLICT(user_id,product_id,variant_id) DO UPDATE SET created=excluded.created, fulfilled=NULL, checked=NULL`)
      .run(req.user.id, productID, variantID || "", Date.now());
    res.status(201).json({ alerts: list(req.user.id) });
  });
  router.delete("/alerts", signedIn, (req, res) => {
    const { productID, variantID } = req.body || {};
    if (typeof productID !== "string" || productID.length > 200) return res.status(400).json({ error: "Invalid product" });
    db.prepare("DELETE FROM restock_watches WHERE user_id=? AND product_id=? AND variant_id=?").run(req.user.id, productID, variantID || "");
    res.json({ alerts: list(req.user.id) });
  });
  router.use((error, req, res, next) => {
    res.status(error.type === "entity.parse.failed" ? 400 : error.type === "entity.too.large" ? 413 : 500).json({ error: "Request could not be completed" });
  });
  app.use("/api/restock", router);

  if (schedule) {
    let running = false;
    const run = async () => {
      if (running) return;
      running = true;
      try {
        const r = await checkRestocks(db, { apns, mail, lookup, onLive });
        if (r.products) console.log(`Restock check: ${r.checked}/${r.products} products, ${r.back} back, ${r.sent} pushed, ${r.emailed} emailed`);
      } catch (e) { console.error("Restock check failed:", e.name); } finally { running = false; }
    };
    setTimeout(run, 60_000).unref();
    setInterval(run, CHECK_EVERY_MS).unref();
  }
}
