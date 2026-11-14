// Notifications in the browser (owner, 2026-11-10: "Web Push ... lets
// implement"). A shopper who turns them on in a browser gets the price-drop,
// sale and new-drop alerts there (server/deal-alerts.js) as well as by email.
//
// No push library: the message encryption (RFC 8291, aes128gcm) and the
// sender's signature (VAPID, RFC 8292) are a page of node:crypto, and
// tests/web-push.test.js holds them to the RFC's own worked example.
//
// The keys live in /etc/marracat/webpush.env (WEB_PUSH_PUBLIC_KEY,
// WEB_PUSH_PRIVATE_KEY, both base64url; `node server/web-push.js keys` makes a
// pair). Without them the routes answer 404 and the site offers no toggle.
import express from "express";
import { createCipheriv, createECDH, createHmac, createPrivateKey, randomBytes, sign } from "node:crypto";
import { pathToFileURL } from "node:url";
import { rateLimit } from "express-rate-limit";

const b64u = (bytes) => Buffer.from(bytes).toString("base64url");
const hmac = (key, data) => createHmac("sha256", key).update(data).digest();
/// HKDF with one block of output, which is all 32 bytes or fewer needs.
const hkdf = (salt, ikm, info, length) => hmac(hmac(salt, ikm), Buffer.concat([info, Buffer.from([1])])).subarray(0, length);

export const MAX_PAYLOAD = 3000;
const RECORD = 4096;

/// A message encrypted for one browser: the aes128gcm body a push service
/// passes on without being able to read. `p256dh` and `auth` are the
/// browser's subscription keys. The salt and sender key are random per
/// message; tests pass the RFC's.
export function encrypt(plaintext, { p256dh, auth }, { salt = randomBytes(16), senderPrivate = null } = {}) {
  const ua = Buffer.from(String(p256dh), "base64url"), secret = Buffer.from(String(auth), "base64url");
  if (ua.length !== 65 || ua[0] !== 4 || secret.length !== 16) throw Error("Bad subscription keys");
  const text = Buffer.from(plaintext);
  if (text.length > MAX_PAYLOAD) throw Error("Message too long");
  const ecdh = createECDH("prime256v1");
  if (senderPrivate) ecdh.setPrivateKey(senderPrivate);
  else ecdh.generateKeys();
  const as = ecdh.getPublicKey();
  const ikm = hkdf(secret, ecdh.computeSecret(ua), Buffer.concat([Buffer.from("WebPush: info\0"), ua, as]), 32);
  const key = hkdf(salt, ikm, Buffer.from("Content-Encoding: aes128gcm\0"), 16);
  const nonce = hkdf(salt, ikm, Buffer.from("Content-Encoding: nonce\0"), 12);
  const cipher = createCipheriv("aes-128-gcm", key, nonce);
  // 0x02 marks the last (here, only) record.
  const sealed = Buffer.concat([cipher.update(Buffer.concat([text, Buffer.from([2])])), cipher.final(), cipher.getAuthTag()]);
  const header = Buffer.alloc(21);
  salt.copy(header, 0);
  header.writeUInt32BE(RECORD, 16);
  header[20] = as.length;
  return Buffer.concat([header, as, sealed]);
}

export function generateKeys() {
  const ecdh = createECDH("prime256v1");
  ecdh.generateKeys();
  return { publicKey: b64u(ecdh.getPublicKey()), privateKey: b64u(ecdh.getPrivateKey()) };
}

/// The Authorization header that tells a push service who is sending: a
/// 12-hour ES256 token for that service's origin, and our public key.
export function vapidHeader(endpoint, { publicKey, privateKey, subject }, now = Date.now()) {
  const pub = Buffer.from(publicKey, "base64url");
  const key = createPrivateKey({ format: "jwk", key: { kty: "EC", crv: "P-256", d: privateKey, x: b64u(pub.subarray(1, 33)), y: b64u(pub.subarray(33, 65)) } });
  const part = (o) => b64u(JSON.stringify(o));
  const unsigned = `${part({ typ: "JWT", alg: "ES256" })}.${part({ aud: new URL(endpoint).origin, exp: Math.floor(now / 1000) + 12 * 3600, sub: subject })}`;
  return `vapid t=${unsigned}.${b64u(sign("sha256", Buffer.from(unsigned), { key, dsaEncoding: "ieee-p1363" }))}, k=${publicKey}`;
}

// The server posts to whatever address a subscription names, so only the
// browsers' own push services are accepted: Chrome and Edge, Firefox, Safari.
const PUSH_HOSTS = /^(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|[a-z0-9-]+\.notify\.windows\.com|([a-z0-9-]+\.)?push\.apple\.com)$/;
export function pushEndpoint(value) {
  if (typeof value !== "string" || value.length > 1000) return null;
  let url;
  try {
    url = new URL(value);
  } catch {
    return null;
  }
  return url.protocol === "https:" && !url.port && !url.username && !url.password && PUSH_HOSTS.test(url.hostname) ? url.href : null;
}
const KEY = /^[A-Za-z0-9_-]{20,120}$/;

export function installWebPushSchema(db) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS web_push_subs (
      endpoint TEXT PRIMARY KEY, user_id TEXT NOT NULL, p256dh TEXT NOT NULL, auth TEXT NOT NULL, created INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS web_push_subs_user ON web_push_subs(user_id);`);
}
export function deleteWebPushData(db, userID) {
  db.prepare("DELETE FROM web_push_subs WHERE user_id=?").run(userID);
}

/// What an alert built for the phone (APNs) says, as a browser notification.
export function noteFromAPNs(push) {
  const alert = push?.aps?.alert || {};
  const url = push?.productID ? "/p/" + encodeURIComponent(push.productID) : push?.brandID ? "/b/" + encodeURIComponent(push.brandID) : "/";
  return { title: String(alert.title || "Marracat"), body: String(alert.body || ""), url, tag: String(push?.productID || push?.brandID || "marracat").slice(0, 80) };
}

/// The sender, or null when no keys are configured.
export function webPushSender(env = process.env, { fetcher = fetch, log = console.log } = {}) {
  const publicKey = env.WEB_PUSH_PUBLIC_KEY, privateKey = env.WEB_PUSH_PRIVATE_KEY;
  if (!publicKey || !privateKey || Buffer.from(publicKey, "base64url").length !== 65) return null;
  const vapid = { publicKey, privateKey, subject: env.WEB_PUSH_SUBJECT || "mailto:hello@marracat.com" };
  /// 201 = accepted; 404/410 = that browser unsubscribed.
  const send = async (sub, note) => {
    const endpoint = pushEndpoint(sub.endpoint);
    if (!endpoint) return { status: 0, reason: "endpoint" };
    try {
      const r = await fetcher(endpoint, {
        method: "POST",
        headers: { TTL: "86400", Urgency: "normal", "Content-Encoding": "aes128gcm", "Content-Type": "application/octet-stream", Authorization: vapidHeader(endpoint, vapid) },
        body: encrypt(JSON.stringify(note), sub),
        signal: AbortSignal.timeout(10_000),
      });
      return { status: r.status };
    } catch (e) {
      return { status: 0, reason: e.name };
    }
  };
  return {
    publicKey,
    send,
    /// To every browser the account turned notifications on in. True if any took it.
    async sendToUser(db, userID, note) {
      let delivered = false;
      for (const sub of db.prepare("SELECT endpoint, p256dh, auth FROM web_push_subs WHERE user_id=?").all(userID)) {
        const result = await send(sub, note);
        if (result.status >= 200 && result.status < 300) delivered = true;
        else if (result.status === 404 || result.status === 410) db.prepare("DELETE FROM web_push_subs WHERE endpoint=?").run(sub.endpoint);
        else log(`Web push not delivered (${result.status} ${result.reason || ""})`);
      }
      return delivered;
    },
  };
}

/// /api/push: the public key, and a signed-in shopper's own browsers.
export function webPushRoutes(app, db, { sender, viewer, maxPerUser = 20 }) {
  installWebPushSchema(db);
  const router = express.Router();
  router.use((req, res, next) => { res.set("Cache-Control", "no-store"); next(); });
  router.use(rateLimit({ windowMs: 60_000, limit: 30, standardHeaders: "draft-8", legacyHeaders: false }));
  router.use(express.json({ limit: "4kb" }));
  router.use((req, res, next) => (sender ? next() : res.status(404).json({ error: "Notifications aren't available" })));
  router.get("/key", (req, res) => res.json({ key: sender.publicKey }));
  router.use(async (req, res, next) => {
    req.user = await viewer(req).catch(() => null);
    if (!req.user) return res.status(401).json({ error: "Sign in to get notifications" });
    next();
  });
  router.get("/", (req, res) => res.json({ browsers: db.prepare("SELECT COUNT(*) n FROM web_push_subs WHERE user_id=?").get(req.user.id).n }));
  router.post("/subscribe", async (req, res) => {
    const endpoint = pushEndpoint(req.body?.endpoint), keys = req.body?.keys || {};
    if (!endpoint || !KEY.test(keys.p256dh || "") || !KEY.test(keys.auth || "")) return res.status(400).json({ error: "That isn't a browser's notification address" });
    try {
      encrypt("", keys); // the keys must be ones a message can be sealed for
    } catch {
      return res.status(400).json({ error: "That isn't a browser's notification address" });
    }
    const known = db.prepare("SELECT user_id FROM web_push_subs WHERE endpoint=?").get(endpoint);
    if (!known && db.prepare("SELECT COUNT(*) n FROM web_push_subs WHERE user_id=?").get(req.user.id).n >= maxPerUser)
      db.prepare("DELETE FROM web_push_subs WHERE endpoint=(SELECT endpoint FROM web_push_subs WHERE user_id=? ORDER BY created LIMIT 1)").run(req.user.id);
    // A browser belongs to whoever signed in on it last.
    db.prepare(`INSERT INTO web_push_subs(endpoint,user_id,p256dh,auth,created) VALUES(?,?,?,?,?)
      ON CONFLICT(endpoint) DO UPDATE SET user_id=excluded.user_id, p256dh=excluded.p256dh, auth=excluded.auth`).run(endpoint, req.user.id, keys.p256dh, keys.auth, Date.now());
    // The first time, say so where the alerts will arrive: proof that it works.
    if (!known) await sender.send({ endpoint, ...keys }, { title: "Notifications are on", body: "Price drops, sales and new arrivals you follow will show up here.", url: "/account", tag: "welcome" });
    res.json({ ok: true });
  });
  router.delete("/subscribe", (req, res) => {
    const endpoint = pushEndpoint(req.body?.endpoint);
    if (endpoint) db.prepare("DELETE FROM web_push_subs WHERE endpoint=? AND user_id=?").run(endpoint, req.user.id);
    res.json({ ok: true });
  });
  app.use("/api/push", router);
}

// `node server/web-push.js keys` prints a new pair in env-file form.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href && process.argv[2] === "keys") {
  const k = generateKeys();
  console.log(`WEB_PUSH_PUBLIC_KEY=${k.publicKey}\nWEB_PUSH_PRIVATE_KEY=${k.privateKey}\nWEB_PUSH_SUBJECT=mailto:hello@marracat.com`);
}
