import express from "express";
import { createHash, createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { readFileSync } from "node:fs";
import { rateLimit } from "express-rate-limit";
import { SMTPServer } from "smtp-server";
import { simpleParser } from "mailparser";
import nodemailer from "nodemailer";
import mailauth from "mailauth";
import { getDomain } from "tldts";
import { apnsSender, installDeviceTimeZone } from "./restock.js";
import { mobileSessionUser } from "./mobile.js";
import { parseOrderEmail } from "./relay-parse.js";
import { itemPhrase, allowedPage } from "./order-tracking.js";
import { claimPush, releasePush, installPushLog } from "./push-once.js";
import { liveCovers } from "./live-cover.js";

// The Marracat order email (owner, 2026-09-30).
//
// A shopper's checkout goes out with a private address, u-<random>@orders.
// marracat.com, instead of their own email; name, address and phone stay
// theirs. The brand's order and shipping emails come here: each is read for
// the order number, its status page and the tracking number, then forwarded
// to the shopper's real inbox. A tracking number becomes a 17TRACK tracker
// (EasyPost when only its key is set), and each step (shipped, out for
// delivery, delivered) updates the order in the app and sends a push.
//
// Behind a flag: only RELAY_USERS (the owner, to start) get an address, while
// real orders show whether brands' fraud checks mind a new-domain email.
//
// Security (audit 2026-10-07):
// - Mail goes only to the email on the account itself, which Google or Apple
//   verified at sign-in. The app's "forwardTo" is ignored: letting a client
//   name the target made hello@marracat.com a phishing relay to anyone.
// - Only mail whose DKIM signature proves it came from a catalog brand's own
//   domain (aligned with From), or from the shop platforms brands send
//   through (Shopify, Big Cartel), is forwarded, tracked or pushed. Anything
//   else is dropped unread. The name shown is the catalog's, not the sender's.
// - The forward is plain text with no attachments, headed by who sent it.
//
// Stored: the address, the account it belongs to, where to forward and the
// parsed events. A message's raw text is kept only until it's forwarded
// (retried for 3 days), never after.
//
// Guests (owner, 2026-10-13): a shopper who isn't signed in gets an address
// too, owned by the install's device key (X-Marracat-Device, stored hashed,
// as restock and order tracking do) instead of an account: owner
// "device:<hash>". Its emails are read and tracked, and push to that phone,
// but there is no inbox to forward them to: the raw copy waits in the outbox
// (the usual 3 days) in case the shopper signs in, then is dropped. Signing in
// on that phone merges the address and its events into the account, which
// keeps one address: a guest address becomes the account's when the account
// has none, else an alias that still receives (orders placed as a guest
// keep their emails) but is never handed out again. Creation is capped per
// device and per IP, addresses are 50 random bits, and nothing personal
// (address, device, email) is logged.

export const RELAY_DOMAIN = "orders.marracat.com";
const hash = (v) => createHash("sha256").update(v).digest("hex");
const MAX_MESSAGE = 10 * 1024 * 1024;
const OUTBOX_DAYS = 3;
const FORWARDS_PER_DAY = 60;
const STEPS = ["confirmation", "shipped", "out_for_delivery", "delivered"];
// DKIM signers that send on brands' behalf: Shopify's notification mail and
// Big Cartel's. Their mail proves the platform sent it, not which brand.
export const PLATFORM_SIGNERS = new Set(["shopify.com", "shopifyemail.com", "myshopify.com", "bigcartel.com"]);
const MAX_FORWARD_TEXT = 100_000;
const emailRe = /^[^\s@<>()",;:\\]{1,64}@[a-z0-9.-]{1,253}\.[a-z]{2,24}$/i;
const GUEST_PER_DEVICE = 3;            // new guest addresses per install per 30 days
const GUEST_DAILY_MAX = 300;           // new guest addresses per day, all installs
const GUEST_IDLE_DAYS = 180;           // a guest address with no mail this long is deleted

/// The relay owner for a guest install: its hashed device key.
export const guestOwner = (deviceHash) => `device:${deviceHash}`;
export const isGuestOwner = (owner) => String(owner).startsWith("device:");
/// Guests get the order email when it's on for everyone.
export const relayGuestsEnabled = (env = process.env) => (env.RELAY_USERS ?? "").trim() === "*" || env.RELAY_GUESTS === "1";

export function installRelaySchema(db) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS relay_addresses (
      local TEXT PRIMARY KEY, user_id TEXT NOT NULL UNIQUE, forward_to TEXT NOT NULL,
      device TEXT, created INTEGER NOT NULL, updated INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS relay_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL, received INTEGER NOT NULL,
      kind TEXT NOT NULL, subject TEXT, brand_name TEXT, brand_domain TEXT, order_name TEXT,
      status_url TEXT, carrier TEXT, tracking_number TEXT, tracker_id TEXT, tracking_status TEXT,
      tracking_updated INTEGER, forwarded INTEGER);
    CREATE INDEX IF NOT EXISTS relay_events_user ON relay_events(user_id, received);
    CREATE INDEX IF NOT EXISTS relay_events_tracking ON relay_events(tracking_number);
    CREATE TABLE IF NOT EXISTS relay_outbox (event_id INTEGER PRIMARY KEY, raw BLOB NOT NULL, tries INTEGER NOT NULL DEFAULT 0, next_try INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS relay_spend (day TEXT PRIMARY KEY, trackers INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS relay_aliases (local TEXT PRIMARY KEY, user_id TEXT NOT NULL, created INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS relay_aliases_user ON relay_aliases(user_id);
    CREATE TABLE IF NOT EXISTS relay_guest_log (device TEXT NOT NULL, created INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS relay_guest_log_device ON relay_guest_log(device, created);
  `);
  installDeviceTimeZone(db);
  // The carrier's expected delivery day, and the day "Arriving today" went out
  // for (owner, 2026-10-05: notify when it shipped, the morning it's due, if
  // it's rescheduled, and when it's delivered).
  // sender_domain: the domain DKIM proved sent it (2026-10-07).
  // item_title/item_count: what shipped, for "KOBA shipped your Keep It
  // Together Headband" (owner, 2026-10-08).
  for (const col of ["est_delivery TEXT", "arriving_sent TEXT", "sender_domain TEXT", "item_title TEXT", "item_count INTEGER", "tracking_detail TEXT"])
    if (!db.prepare("SELECT 1 FROM pragma_table_info('relay_events') WHERE name=?").get(col.split(" ")[0]))
      db.exec(`ALTER TABLE relay_events ADD COLUMN ${col}`);
}

export function deleteRelayData(db, userID) {
  const ids = db.prepare("SELECT id FROM relay_events WHERE user_id=?").all(userID).map((r) => r.id);
  for (const id of ids) db.prepare("DELETE FROM relay_outbox WHERE event_id=?").run(id);
  db.prepare("DELETE FROM relay_events WHERE user_id=?").run(userID);
  db.prepare("DELETE FROM relay_addresses WHERE user_id=?").run(userID);
  if (db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='relay_aliases'").get())
    db.prepare("DELETE FROM relay_aliases WHERE user_id=?").run(userID);
  if (db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='push_log'").get())
    db.prepare("DELETE FROM push_log WHERE who=?").run(userID);
}

/// 10 random base32 characters: 50 bits from the CSPRNG, unguessable, easy
/// to read out. Rejection sampling keeps every character equally likely.
const ALPHABET = "abcdefghijkmnpqrstuvwxyz23456789";
export function newLocal() {
  let out = "u-";
  while (out.length < 12) for (const b of randomBytes(16)) if (b < 256 - (256 % ALPHABET.length) && out.length < 12) out += ALPHABET[b % ALPHABET.length];
  return out;
}

// RELAY_USERS="*" turns it on for every account.
export const relayEnabledFor = (email, env = process.env) => (env.RELAY_USERS ?? "").trim() === "*" ||
  new Set((env.RELAY_USERS ?? "divinejdavis@gmail.com").split(",").map((e) => e.trim().toLowerCase()).filter(Boolean))
    .has(String(email || "").toLowerCase());

// ---- the pieces that talk to the outside, swappable in tests ------------

// Who provably sent a message, from its DKIM signatures: a catalog brand
// (signature aligned with the From domain, and that domain is the brand's) or
// a shop platform, else null. `brandFor(domain)` looks the domain up in the
// catalog; `resolver` swaps DNS out in tests.
export async function verifiedSender(raw, { brandFor = () => null, resolver } = {}) {
  let result;
  try { result = await mailauth.dkimVerify(raw, resolver ? { resolver } : {}); } catch { return null; }
  const from = result.headerFrom || [];
  if (from.length !== 1) return null;
  const fromDomain = String(from[0]).split("@").pop().toLowerCase();
  const passed = (result.results || []).filter((r) => r.status?.result === "pass");
  if (passed.some((r) => r.status.aligned)) {
    const brand = brandFor(fromDomain);
    if (brand) return { via: "brand", domain: getDomain(fromDomain) || fromDomain, brand };
  }
  const platform = passed.map((r) => getDomain(String(r.signingDomain || "").toLowerCase())).find((d) => PLATFORM_SIGNERS.has(d));
  if (platform) return { via: "platform", domain: platform, brand: null };
  return null;
}

/// What DKIM proved about a forwarded email, in the note above it. A brand's
/// own signature proves the brand. A shop platform's proves only that the
/// mail left that platform: any shop on it could have sent it, so the note no
/// longer calls the brand verified (2026-11-12).
export function provenance(senderDomain) {
  if (!senderDomain) return "unknown sender";
  return PLATFORM_SIGNERS.has(senderDomain)
    ? `sent through ${senderDomain}; the shop itself isn't verified`
    : `${senderDomain}; sender verified`;
}

export function mailForwarder(env = process.env) {
  if (!env.RELAY_SMTP_HOST || !env.RELAY_SMTP_USER || !env.RELAY_SMTP_PASS) return null;
  const transport = nodemailer.createTransport({
    host: env.RELAY_SMTP_HOST, port: Number(env.RELAY_SMTP_PORT || 465), secure: Number(env.RELAY_SMTP_PORT || 465) === 465,
    auth: { user: env.RELAY_SMTP_USER, pass: env.RELAY_SMTP_PASS },
  });
  return (message) => transport.sendMail(message);
}

export function easyPost(env = process.env, fetcher = fetch) {
  if (!env.EASYPOST_API_KEY) return null;
  const auth = "Basic " + Buffer.from(`${env.EASYPOST_API_KEY}:`).toString("base64");
  return Object.assign(async ({ trackingNumber, carrier }) => {
    const res = await fetcher("https://api.easypost.com/v2/trackers", {
      method: "POST", signal: AbortSignal.timeout(15000),
      headers: { Authorization: auth, "Content-Type": "application/json" },
      body: JSON.stringify({ tracker: { tracking_code: trackingNumber, ...(carrier ? { carrier } : {}) } }),
    });
    if (!res.ok) throw new Error(`EasyPost ${res.status}`);
    const t = await res.json();
    return { id: t.id, status: t.status, estDelivery: t.est_delivery_date || null };
  }, { service: "EasyPost", costUSD: 0.03 });
}

// 17TRACK (owner, 2026-10-07: EasyPost's verification stalled). One quota per
// number registered, re-polling included: 200 free once, then annual blocks
// (~$0.024 each at 5,000 for $119). It identifies a shipment by its number,
// so the number is the tracker id. Docs: https://api.17track.net/en/doc (v2.4)
const TRACK17_API = "https://api.17track.net/track/v2.4";
// The parser's carrier names onto 17TRACK's carrier codes; anything else is
// left to its auto-detection.
export const TRACK17_CARRIERS = { USPS: 21051, UPS: 100002, FedEx: 100003, DHLExpress: 100001, OnTrac: 100049 };
export function seventeenTrack(env = process.env, fetcher = fetch) {
  if (!env.TRACK17_API_KEY) return null;
  return Object.assign(async ({ trackingNumber, carrier }) => {
    const code = TRACK17_CARRIERS[carrier];
    const res = await fetcher(`${TRACK17_API}/register`, {
      method: "POST", signal: AbortSignal.timeout(15000),
      headers: { "17token": env.TRACK17_API_KEY, "Content-Type": "application/json" },
      body: JSON.stringify([{ number: trackingNumber, ...(code ? { carrier: code } : {}) }]),
    });
    if (!res.ok) throw new Error(`17TRACK ${res.status}`);
    const body = await res.json();
    const rejected = body?.data?.rejected?.[0];
    // Already registered (-18019901): it's tracked, and costs nothing more.
    if (rejected && rejected.error?.code !== -18019901) throw new Error(`17TRACK rejected: ${rejected.error?.code} ${rejected.error?.message || ""}`.trim());
    if (!rejected && !body?.data?.accepted?.length) throw new Error(`17TRACK code ${body?.code}`);
    return { id: trackingNumber, status: null, estDelivery: null };
  }, { service: "17TRACK", costUSD: 0.024 });
}

// Which carriers EasyPost follows, and the rest 17TRACK. USPS first (owner,
// 2026-10-12: since USPS tied tracking to a shipper's Mailer ID on
// 2026-04-01, 17TRACK's USPS lookups are limited). UPS and OnTrac joined
// 2026-10-17: 17TRACK re-checks a carrier only every 6-12 hours, so a Ripl
// Efek OnTrac parcel delivered at 7 am still read "at the facility" at 11,
// and the Live Activity never moved; EasyPost pushes each scan as the
// carrier posts it, at about the same price. FedEx stays with 17TRACK
// (EasyPost needs the shipper's FedEx account for it), and so does an
// unknown carrier (17TRACK detects it). If EasyPost refuses a number,
// 17TRACK takes it. With one key alone, that service takes every number.
export const EASYPOST_CARRIERS = new Set(["USPS", "UPS", "OnTrac"]);
export function trackerFor(env = process.env, { usps = easyPost(env), rest = seventeenTrack(env) } = {}) {
  if (!usps || !rest) return rest || usps;
  const viaRest = async (shipment) => ({ service: rest.service, ...(await rest(shipment)) });
  return Object.assign(async (shipment) => {
    if (!EASYPOST_CARRIERS.has(shipment.carrier)) return viaRest(shipment);
    try { return { service: usps.service, ...(await usps(shipment)) }; }
    catch { return viaRest(shipment); }
  }, { service: `${rest.service}/${usps.service}`, costUSD: Math.max(rest.costUSD, usps.costUSD) });
}

// 17TRACK signs a push with sha256(raw body + "/" + key), hex, in "sign".
export function valid17TrackSignature(rawBody, header, key) {
  if (!key || typeof header !== "string") return false;
  const expected = createHash("sha256").update(Buffer.concat([rawBody, Buffer.from("/" + key)])).digest("hex");
  const a = Buffer.from(expected), b = Buffer.from(header.toLowerCase());
  return a.length === b.length && timingSafeEqual(a, b);
}

// 17TRACK's status onto the EasyPost words the rest of the relay (and the
// app's trackingStatus) already uses.
export function statusFrom17Track(latest) {
  const sub = latest?.sub_status || "";
  switch (latest?.status) {
    case "InfoReceived": return "pre_transit";
    case "InTransit": return "in_transit";
    case "AvailableForPickup": return "available_for_pickup";
    case "OutForDelivery": return "out_for_delivery";
    case "Delivered": return "delivered";
    case "DeliveryFailure": return "failure";
    case "Exception": return /Return/i.test(sub) ? "return_to_sender" : "failure";
    default: return "unknown";   // NotFound, Expired
  }
}

// What the carrier said last, in its own words, for the app's explanation
// of a problem (owner, 2026-10-21): 17TRACK's latest event, EasyPost's last
// tracking detail. Plain text, at most 200 characters.
const clipDetail = (s) => (typeof s === "string" && s.trim() ? s.replace(/\s+/g, " ").trim().slice(0, 200) : null);
export function detailFrom17Track(info) {
  return clipDetail(info?.latest_event?.description) || clipDetail(info?.latest_status?.sub_status_descr);
}
export function detailFromEasyPost(t) {
  const last = Array.isArray(t?.tracking_details) ? t.tracking_details[t.tracking_details.length - 1] : null;
  return clipDetail(last?.message) || clipDetail(t?.status_detail?.replace?.(/_/g, " "));
}

// EasyPost signs webhooks with HMAC-SHA256 of the raw body, keyed by the
// NFKD-normalised secret, sent as "hmac-sha256-hex=<hex>".
export function validEasyPostSignature(rawBody, header, secret) {
  if (!secret || typeof header !== "string") return false;
  const expected = "hmac-sha256-hex=" + createHmac("sha256", secret.normalize("NFKD")).update(rawBody).digest("hex");
  const a = Buffer.from(expected), b = Buffer.from(header);
  return a.length === b.length && timingSafeEqual(a, b);
}

// EasyPost's statuses onto the app's tracker.
export function stepForTrackerStatus(status) {
  if (status === "delivered") return "delivered";
  if (status === "out_for_delivery") return "out_for_delivery";
  if (["in_transit", "available_for_pickup", "pre_transit"].includes(status)) return "shipped";
  if (["return_to_sender", "failure", "cancelled", "error"].includes(status)) return "problem";
  return null;
}

// One order number however a brand wrote it: "#KOBA-11906", "11906" and
// "#11906" are all "11906" (the app's RelayStore.orderKey does the same).
export const orderKey = (name) => {
  const s = String(name || "").toLowerCase().replace(/#/g, "").trim();
  const m = s.match(/^[a-z]+-(.+)$/);
  return m ? m[1] : s;
};

// With the item known, every step names it (owner, 2026-10-09: an "Arriving
// today" still read "order #KOBA-11906"); without it, the order number.
const pushText = (kind, brand, orderName, extra, item) => {
  const who = brand || "Your order";
  const order = orderName ? ` ${orderName}` : "";
  if (item) {
    const from = brand ? ` from ${brand}` : "";
    return {
      shipped: { title: "Shipped", body: brand ? `${brand} shipped your ${item}` : `Your ${item} shipped` },
      out_for_delivery: { title: "Out for delivery", body: `Your ${item}${from} is out for delivery.` },
      delivered: { title: "Delivered", body: `Your ${item}${from} was delivered.` },
      problem: { title: "Delivery problem", body: `The carrier reported a problem with your ${item}${from}.` },
      arriving_today: { title: "Arriving today", body: `Your ${item}${from} arrives today.` },
      rescheduled: { title: "Delivery rescheduled", body: `Your ${item}${from} is now expected ${extra || "later"}.` },
    }[kind];
  }
  return {
    shipped: { title: "Shipped", body: `${who} shipped your order${order}.` },
    out_for_delivery: { title: "Out for delivery", body: `Your ${brand ? brand + " " : ""}order${order} is out for delivery.` },
    delivered: { title: "Delivered", body: `Your ${brand ? brand + " " : ""}order${order} was delivered.` },
    problem: { title: "Delivery problem", body: `The carrier reported a problem with your ${brand ? brand + " " : ""}order${order}.` },
    arriving_today: { title: "Arriving today", body: `Your ${brand ? brand + " " : ""}order${order} is scheduled to arrive today.` },
    rescheduled: { title: "Delivery rescheduled", body: `Your ${brand ? brand + " " : ""}order${order} is now expected ${extra || "later"}.` },
  }[kind];
};

/// "2026-10-09" from an ISO time, or null.
export const dayOf = (iso) => (typeof iso === "string" && /^\d{4}-\d{2}-\d{2}/.test(iso) ? iso.slice(0, 10) : null);

/// The date and hour now in a time zone.
export function localNow(ms, tz) {
  let parts;
  try { parts = new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", hourCycle: "h23" }).formatToParts(new Date(ms)); }
  catch { return localNow(ms, "America/New_York"); }
  const get = (t) => parts.find((p) => p.type === t)?.value;
  return { day: `${get("year")}-${get("month")}-${get("day")}`, hour: Number(get("hour")) };
}

/// "on Thursday, Oct 9".
export function dayName(day) {
  const d = new Date(day + "T12:00:00Z");
  return "on " + d.toLocaleDateString("en-US", { weekday: "long", month: "short", day: "numeric", timeZone: "UTC" });
}

// One daily cap on new trackers, shared by the relay and the order-page
// tracker (order-tracking.js), since both spend the same quota.
export function trackerBudget(db, env = process.env, now = Date.now) {
  db.exec("CREATE TABLE IF NOT EXISTS relay_spend (day TEXT PRIMARY KEY, trackers INTEGER NOT NULL DEFAULT 0)");
  const cap = Number(env.TRACKER_DAILY_MAX || env.EASYPOST_DAILY_MAX || 50);
  const day = () => new Date(now()).toISOString().slice(0, 10);
  const spent = () => db.prepare("SELECT trackers FROM relay_spend WHERE day=?").get(day())?.trackers || 0;
  return {
    cap,
    allowed: () => spent() < cap,
    charge: () => { db.prepare("INSERT INTO relay_spend(day,trackers) VALUES(?,1) ON CONFLICT(day) DO UPDATE SET trackers=trackers+1").run(day()); return spent(); },
  };
}

// ---- the relay itself ----------------------------------------------------

export function createRelay(db, { env = process.env, forward = mailForwarder(env), tracker = trackerFor(env), apns = apnsSender(env), now = Date.now, log = console.log,
  brandFor = () => null, verify = (raw) => verifiedSender(raw, { brandFor }), onChange = () => {} } = {}) {
  installRelaySchema(db);
  // Addresses set up before 2026-10-07 could forward anywhere the app named;
  // from now on, only to the account's own email.
  db.prepare(`UPDATE relay_addresses SET forward_to=(SELECT email FROM users WHERE users.id=relay_addresses.user_id)
    WHERE EXISTS (SELECT 1 FROM users WHERE users.id=relay_addresses.user_id AND email IS NOT NULL AND email!=relay_addresses.forward_to)`).run();
  const budget = trackerBudget(db, env, now);
  const service = tracker?.service || "Tracker";

  function addressFor(userID) {
    const row = db.prepare("SELECT local, forward_to FROM relay_addresses WHERE user_id=?").get(userID);
    return row ? { address: `${row.local}@${RELAY_DOMAIN}`, forwardTo: row.forward_to } : null;
  }

  // The account's own sign-in email (Google/Apple verified it), never one the
  // client names.
  function accountEmail(userID) {
    const email = db.prepare("SELECT email FROM users WHERE id=?").get(userID)?.email;
    return typeof email === "string" && emailRe.test(email) && !email.toLowerCase().endsWith("@" + RELAY_DOMAIN) ? email : null;
  }

  // Called only by the signed-in PUT, with the device key the phone sent: a
  // phone can only merge its own guest data, into the account signed in on it.
  function register(userID, deviceHash) {
    const forwardTo = accountEmail(userID);
    if (!forwardTo) throw Object.assign(new Error("Your sign-in has no email address to forward to"), { status: 409 });
    if (deviceHash) merge(userID, deviceHash, forwardTo);
    const existing = db.prepare("SELECT local FROM relay_addresses WHERE user_id=?").get(userID);
    if (existing) {
      db.prepare("UPDATE relay_addresses SET forward_to=?, device=COALESCE(?, device), updated=? WHERE user_id=?").run(forwardTo, deviceHash, now(), userID);
    } else {
      db.prepare("INSERT INTO relay_addresses(local,user_id,forward_to,device,created,updated) VALUES(?,?,?,?,?,?)").run(newLocal(), userID, forwardTo, deviceHash, now(), now());
    }
    return addressFor(userID);
  }

  // A guest install's address: the one it has, else a new one within the caps.
  function registerGuest(deviceHash) {
    const owner = guestOwner(deviceHash);
    const existing = db.prepare("SELECT local FROM relay_addresses WHERE user_id=?").get(owner);
    if (existing) {
      db.prepare("UPDATE relay_addresses SET updated=? WHERE user_id=?").run(now(), owner);
      return addressFor(owner);
    }
    const tooMany = () => Object.assign(new Error("Too many new order addresses. Try again later."), { status: 429 });
    if (db.prepare("SELECT COUNT(*) AS n FROM relay_guest_log WHERE device=? AND created>?").get(deviceHash, now() - 30 * 86400_000).n >= GUEST_PER_DEVICE) throw tooMany();
    const cap = Number(env.RELAY_GUEST_DAILY_MAX || GUEST_DAILY_MAX);
    if (db.prepare("SELECT COUNT(*) AS n FROM relay_guest_log WHERE created>?").get(now() - 86400_000).n >= cap) {
      log(`Relay: guest address cap reached (${cap}/day)`);
      throw tooMany();
    }
    db.transaction(() => {
      db.prepare("INSERT INTO relay_guest_log(device,created) VALUES(?,?)").run(deviceHash, now());
      db.prepare("INSERT INTO relay_addresses(local,user_id,forward_to,device,created,updated) VALUES(?,?,'',?,?,?)").run(newLocal(), owner, deviceHash, now(), now());
    })();
    return addressFor(owner);
  }

  // This phone's guest address and what it received become the account's.
  function merge(userID, deviceHash, forwardTo) {
    const owner = guestOwner(deviceHash);
    const guest = db.prepare("SELECT local FROM relay_addresses WHERE user_id=?").get(owner);
    const events = db.prepare("SELECT COUNT(*) AS n FROM relay_events WHERE user_id=?").get(owner).n;
    if (!guest && !events) return false;
    installPushLog(db);
    db.transaction(() => {
      if (guest) {
        if (!db.prepare("SELECT 1 FROM relay_addresses WHERE user_id=?").get(userID)) {
          db.prepare("UPDATE relay_addresses SET user_id=?, forward_to=?, updated=? WHERE user_id=?").run(userID, forwardTo, now(), owner);
        } else {
          db.prepare("INSERT OR REPLACE INTO relay_aliases(local,user_id,created) VALUES(?,?,?)").run(guest.local, userID, now());
          db.prepare("DELETE FROM relay_addresses WHERE user_id=?").run(owner);
        }
      }
      db.prepare("UPDATE relay_aliases SET user_id=? WHERE user_id=?").run(userID, owner);
      db.prepare("UPDATE relay_events SET user_id=? WHERE user_id=?").run(userID, owner);
      // Steps already announced stay announced.
      db.prepare("UPDATE OR IGNORE push_log SET who=? WHERE who=?").run(userID, owner);
      db.prepare("DELETE FROM push_log WHERE who=?").run(owner);
      if (db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='tracked_orders'").get())
        db.prepare("UPDATE tracked_orders SET relay_owner=? WHERE relay_owner=?").run(userID, owner);
      // Mail that waited for an inbox goes out on the next retry.
      db.prepare("UPDATE relay_outbox SET next_try=? WHERE event_id IN (SELECT id FROM relay_events WHERE user_id=?)").run(now(), userID);
    })();
    log(`Relay: a guest order address merged into an account (${events} event${events === 1 ? "" : "s"})`);
    changed();
    return true;
  }

  // Which owner a local part delivers to: its address, or an alias left by a merge.
  const ownerOf = (local) => (db.prepare("SELECT user_id FROM relay_addresses WHERE local=?").get(local) ||
    db.prepare("SELECT user_id FROM relay_aliases WHERE local=?").get(local))?.user_id || null;

  const changed = () => { try { onChange(); } catch (e) { log(`Relay order sync failed (${e.name})`); } };

  // Every phone signed in to the account (restock_links), or the phone that
  // set up the order email.
  const phones = (userID) => {
    const linked = db.prepare("SELECT name FROM sqlite_master WHERE name='restock_links'").get()
      ? db.prepare(`SELECT d.hash, d.token, d.environment, d.tz FROM restock_links l JOIN restock_devices d ON d.hash = l.device
          WHERE l.user_id=? AND d.token IS NOT NULL`).all(userID) : [];
    if (linked.length) return linked;
    return db.prepare(`SELECT d.hash, d.token, d.environment, d.tz FROM relay_addresses a JOIN restock_devices d ON d.hash = a.device
      WHERE a.user_id=? AND d.token IS NOT NULL`).all(userID);
  };

  // What's in the order: the email's own item list or what the app told us
  // for that order number (setItems), else the item the app named when that
  // brand's order was placed on one of this account's phones — only when
  // every such recent order names the same thing.
  function itemFor(userID, event) {
    const fromMail = itemPhrase(event.item_title, event.item_count);
    if (fromMail) return fromMail;
    if (event.order_name) {
      const key = orderKey(event.order_name);
      const known = db.prepare("SELECT order_name, item_title, item_count FROM relay_events WHERE user_id=? AND brand_domain=? AND item_title IS NOT NULL")
        .all(userID, event.brand_domain).find((r) => orderKey(r.order_name) === key);
      if (known) return itemPhrase(known.item_title, known.item_count);
    }
    const brandID = event.brand_domain ? brandFor(event.brand_domain)?.id : null;
    if (!brandID || !db.prepare("SELECT 1 FROM sqlite_master WHERE name='tracked_orders'").get()) return null;
    const window = [event.received - 30 * 86400_000, event.received];
    // A guest's own phone, else every phone signed in to the account.
    const rows = isGuestOwner(userID)
      ? db.prepare(`SELECT DISTINCT item_title, item_count FROM tracked_orders WHERE device=? AND brand_id=? AND created BETWEEN ? AND ?`)
        .all(userID.slice("device:".length), brandID, ...window)
      : db.prepare("SELECT 1 FROM sqlite_master WHERE name='restock_links'").get()
        ? db.prepare(`SELECT DISTINCT t.item_title, t.item_count FROM tracked_orders t JOIN restock_links l ON l.device = t.device
            WHERE l.user_id=? AND t.brand_id=? AND t.created BETWEEN ? AND ?`).all(userID, brandID, ...window)
        : [];
    const phrases = new Set(rows.map((r) => itemPhrase(r.item_title, r.item_count)));
    return phrases.size === 1 ? [...phrases][0] : null;
  }

  // One order's identity across its records: the order number when a brand
  // email named it ("#11906" and "#KOBA-11906" are one), else the package.
  const orderIdentity = (event) =>
    `${event.brand_domain || ""}|${event.order_name ? orderKey(event.order_name) : event.tracking_number || event.tracker_id || event.id}`;

  async function notify(userID, kind, event, extra, newDay) {
    const text = pushText(kind, event.brand_name, event.order_name, extra, itemFor(userID, event));
    if (!text || !apns?.configured?.()) return false;
    // Each step once per order; "Arriving today" once per expected day, and a
    // reschedule once per new day.
    const key = `${kind}|${orderIdentity(event)}${kind === "arriving_today" ? "|" + event.est_delivery : kind === "rescheduled" ? "|" + extra : ""}`;
    if (!claimPush(db, userID, key, now())) return false;
    let sent = false;
    for (const row of phones(userID)) {
      // The phone's delivery card announces this step itself (live-cover.js).
      if (liveCovers(db, row.hash, kind, now(), { brand: event.brand_name, day: newDay })) { sent = true; continue; }
      const result = await apns.send(row, { aps: { alert: text, sound: "default" }, orderEvent: { brandDomain: event.brand_domain, orderName: event.order_name } });
      if (result.status === 200) sent = true;
      else log(`Relay push not delivered (${result.status} ${result.reason})`);
    }
    if (!sent) releasePush(db, userID, key);
    return sent;
  }

  async function startTracking(event) {
    if (!tracker || !event.tracking_number) return;
    const known = db.prepare("SELECT tracker_id FROM relay_events WHERE tracking_number=? AND tracker_id IS NOT NULL").get(event.tracking_number);
    if (known) { db.prepare("UPDATE relay_events SET tracker_id=? WHERE id=?").run(known.tracker_id, event.id); return; }
    if (!budget.allowed()) { log(`${service} daily cap reached (${budget.cap}); not tracking ${event.tracking_number}`); return; }
    try {
      const t = await tracker({ trackingNumber: event.tracking_number, carrier: event.carrier });
      const spent = budget.charge();
      db.prepare("UPDATE relay_events SET tracker_id=?, tracking_status=?, tracking_updated=?, est_delivery=? WHERE id=?")
        .run(t.id, t.status || null, now(), dayOf(t.estDelivery), event.id);
      log(`${t.service || service} tracker ${t.id} created${tracker.costUSD ? ` (~$${tracker.costUSD.toFixed(3)})` : ""}; ${spent} today`);
    } catch (e) { log(`${service} tracker failed: ${e.message}`); }
  }

  async function deliver(eventID) {
    const job = db.prepare("SELECT o.raw, o.tries, e.* FROM relay_outbox o JOIN relay_events e ON e.id = o.event_id WHERE o.event_id=?").get(eventID);
    if (!job) return false;
    const to = accountEmail(job.user_id);
    if (!to || !forward) {
      db.prepare("UPDATE relay_outbox SET tries=tries+1, next_try=? WHERE event_id=?").run(now() + 15 * 60_000, eventID);
      return false;
    }
    const mail = await simpleParser(job.raw);
    const sender = mail.from?.value?.[0];
    const clean = (v, max) => String(v || "").replace(/["<>\r\n]/g, "").slice(0, max);
    const name = clean(job.brand_name || job.sender_domain || "A brand", 80);
    // Replies go to the sender only when its address is on the domain DKIM proved.
    const replyTo = [mail.replyTo?.value?.[0]?.address, sender?.address]
      .find((a) => a && job.sender_domain && getDomain(String(a).split("@").pop().toLowerCase()) === job.sender_domain);
    const body = String(mail.text || "").slice(0, MAX_FORWARD_TEXT);
    try {
      await forward({
        from: { name: `${name} via Marracat`, address: env.RELAY_SMTP_USER },
        to,
        ...(replyTo ? { replyTo } : {}),
        subject: clean(mail.subject || "(no subject)", 200),
        // Plain text only, no attachments: a forward can't carry a lookalike
        // page or a file, and says plainly where it came from.
        text: `Forwarded by Marracat from ${name} (${provenance(job.sender_domain)}) to the email on your Marracat account. ` +
          `Marracat never asks for passwords or payment details by email.\n\n----------\n\n${body}`,
        headers: { "X-Marracat-Relay": String(job.id), "Auto-Submitted": "auto-forwarded" },
      });
      db.transaction(() => {
        db.prepare("DELETE FROM relay_outbox WHERE event_id=?").run(eventID);
        db.prepare("UPDATE relay_events SET forwarded=? WHERE id=?").run(now(), eventID);
      })();
      return true;
    } catch (e) {
      log(`Relay forward failed (${e.code || e.message})`);
      db.prepare("UPDATE relay_outbox SET tries=tries+1, next_try=? WHERE event_id=?").run(now() + Math.min(6, job.tries + 1) * 10 * 60_000, eventID);
      return false;
    }
  }

  // One message for one relay address.
  async function receive(raw, local) {
    const ownerID = ownerOf(local);
    if (!ownerID) return null;
    const owner = { user_id: ownerID };
    // Unproven mail is dropped: it's not forwarded, tracked or pushed.
    const from = await verify(raw);
    if (!from) { log("Relay dropped a message without a brand or platform DKIM signature"); return null; }
    const mail = await simpleParser(raw);
    const sender = mail.from?.value?.[0] || {};
    const parsed = parseOrderEmail({ subject: mail.subject || "", html: typeof mail.html === "string" ? mail.html : "", text: mail.text || "", fromName: sender.name || "", fromAddress: sender.address || "" });
    // The brand is the catalog's: by the signing domain, or for platform mail
    // by the store the email links to. A platform email naming no catalog
    // brand keeps its sender name (the platform vouches for the shop).
    const brand = from.brand || (parsed.brandDomain ? brandFor(parsed.brandDomain) : null);
    const brandName = brand?.name || (from.via === "platform" ? parsed.brandName : null);
    const brandDomain = from.via === "brand" ? from.domain : (brand?.domain || parsed.brandDomain);
    // The order link is kept only when it is https on the brand's own site or
    // Shopify's (order-tracking.js allowedPage); until 2026-11-12 whatever
    // link the email carried was stored.
    const statusURL = parsed.statusURL && allowedPage(parsed.statusURL, brand || { domain: brandDomain }) ? parsed.statusURL : null;
    const info = db.prepare(`INSERT INTO relay_events(user_id,received,kind,subject,brand_name,brand_domain,order_name,status_url,carrier,tracking_number,sender_domain,item_title,item_count)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)`).run(owner.user_id, now(), parsed.kind, (mail.subject || "").slice(0, 300), brandName, brandDomain,
      parsed.orderName, statusURL, parsed.carrier, parsed.trackingNumber, from.domain, parsed.itemTitle, parsed.itemCount);
    const id = Number(info.lastInsertRowid);
    const event = db.prepare("SELECT * FROM relay_events WHERE id=?").get(id);
    // A leaked address can't turn hello@marracat.com into a spam cannon: past
    // the daily cap, mail is still read for the order but not forwarded.
    const today = db.prepare("SELECT COUNT(*) AS n FROM relay_events WHERE user_id=? AND received>?").get(owner.user_id, now() - 86400_000).n;
    if (today <= FORWARDS_PER_DAY) {
      db.prepare("INSERT INTO relay_outbox(event_id,raw,next_try) VALUES(?,?,?)").run(id, raw, now());
      await deliver(id);
    } else log(`Relay forward skipped: ${FORWARDS_PER_DAY}/day cap for one address`);
    if (event.tracking_number) await startTracking(event);
    if (["shipped", "out_for_delivery", "delivered"].includes(parsed.kind)) await notify(owner.user_id, parsed.kind, event);
    changed();
    return event;
  }

  async function retryOutbox() {
    db.prepare("DELETE FROM relay_outbox WHERE event_id IN (SELECT id FROM relay_events WHERE received < ?)").run(now() - OUTBOX_DAYS * 86400_000);
    expireGuests();
    for (const { event_id } of db.prepare("SELECT event_id FROM relay_outbox WHERE next_try<=? LIMIT 20").all(now())) await deliver(event_id);
  }

  // EasyPost's webhook.
  async function trackerUpdate(payload) {
    const t = payload?.result;
    if (payload?.description !== "tracker.updated" || !t?.id) return 0;
    return applyTracking(t.id, t.status, dayOf(t.est_delivery_date), detailFromEasyPost(t));
  }

  // 17TRACK's webhook: TRACKING_UPDATED carries the latest status and the
  // expected window (its last day is the one shown).
  async function track17Update(payload) {
    const d = payload?.data;
    if (payload?.event !== "TRACKING_UPDATED" || typeof d?.number !== "string") return 0;
    const eta = d.track_info?.time_metrics?.estimated_delivery_date;
    return applyTracking(d.number, statusFrom17Track(d.track_info?.latest_status), dayOf(eta?.to) || dayOf(eta?.from), detailFrom17Track(d.track_info));
  }

  // A guest address with no mail for 180 days goes, with what it received.
  function expireGuests() {
    const idle = now() - GUEST_IDLE_DAYS * 86400_000;
    for (const { user_id } of db.prepare(`SELECT user_id FROM relay_addresses a WHERE user_id LIKE 'device:%' AND created < ?
        AND NOT EXISTS (SELECT 1 FROM relay_events e WHERE e.user_id = a.user_id AND e.received >= ?)`).all(idle, idle)) deleteRelayData(db, user_id);
    db.prepare("DELETE FROM relay_guest_log WHERE created < ?").run(now() - 31 * 86400_000);
  }

  async function applyTracking(trackerID, status, est, detail = null) {
    const step = stepForTrackerStatus(status);
    const rows = db.prepare("SELECT * FROM relay_events WHERE tracker_id=?").all(trackerID);
    for (const e of rows) {
      const before = stepForTrackerStatus(e.tracking_status);
      db.prepare("UPDATE relay_events SET tracking_status=?, tracking_updated=?, est_delivery=COALESCE(?, est_delivery), tracking_detail=COALESCE(?, tracking_detail) WHERE id=?").run(status, now(), est, detail, e.id);
      if (step && step !== before && step !== "shipped") await notify(e.user_id, step, e);
      // The carrier moved the day: say when it's now expected. Only once a
      // day was known, and not once it's delivered.
      if (est && e.est_delivery && est !== e.est_delivery && step !== "delivered") {
        db.prepare("UPDATE relay_events SET arriving_sent=NULL WHERE id=?").run(e.id);
        await notify(e.user_id, "rescheduled", e, dayName(est, phones(e.user_id)[0]?.tz), est);
      }
    }
    if (rows.length) changed();
    return rows.length;
  }

  function events(userID) {
    return db.prepare(`SELECT id, received, kind, brand_name AS brandName, brand_domain AS brandDomain, order_name AS orderName,
        carrier, tracking_number AS trackingNumber, tracking_status AS trackingStatus, tracking_updated AS trackingUpdated, tracking_detail AS trackingDetail,
        est_delivery AS estDelivery
      FROM relay_events WHERE user_id=? ORDER BY received DESC LIMIT 200`).all(userID)
      .map((e) => ({ ...e, step: STEPS.includes(e.kind) ? e.kind : null, trackingStep: stepForTrackerStatus(e.trackingStatus) }));
  }

  // "Arriving today", from 8 am on the expected day in the phone's own time
  // zone (America/New_York when the phone never said), once per day.
  async function morningNotes() {
    let sent = 0;
    const due = db.prepare(`SELECT * FROM relay_events WHERE est_delivery IS NOT NULL AND (arriving_sent IS NULL OR arriving_sent != est_delivery)
      AND COALESCE(tracking_status,'') NOT IN ('delivered','return_to_sender','cancelled')`).all();
    for (const e of due) {
      const tz = phones(e.user_id)[0]?.tz || "America/New_York";
      const { day, hour } = localNow(now(), tz);
      if (day !== e.est_delivery || hour < 8 || hour >= 14) continue;
      db.prepare("UPDATE relay_events SET arriving_sent=? WHERE id=?").run(e.est_delivery, e.id);
      if (await notify(e.user_id, "arriving_today", e)) sent++;
    }
    return sent;
  }

  // A shipment by tracking number, as a brand's shipping email gives it. Not
  // reachable from the app: the shopper is never asked for a tracking number
  // (owner, 2026-10-05); the tests use it to stand a shipment up.
  async function addTracking(userID, { trackingNumber, carrier, brandName, brandDomain, orderName }) {
    const info = db.prepare(`INSERT INTO relay_events(user_id,received,kind,subject,brand_name,brand_domain,order_name,carrier,tracking_number)
      VALUES(?,?,'shipped','Tracking number added in the app',?,?,?,?,?)`).run(userID, now(), brandName, brandDomain, orderName, carrier, trackingNumber);
    const event = db.prepare("SELECT * FROM relay_events WHERE id=?").get(Number(info.lastInsertRowid));
    await startTracking(event);
    return db.prepare("SELECT * FROM relay_events WHERE id=?").get(event.id);
  }

  // The app knows what each order held (its own receipt) and which brand
  // emails belong to it; it names the items per order number so later pushes
  // can say "Your Keep It Together Headband…". Only this account's events.
  function setItems(userID, orders) {
    let updated = 0;
    for (const o of orders) {
      const item = itemPhrase(o.itemTitle, 1);
      if (!item || !o.orderName || !o.brandDomain) continue;
      const key = orderKey(o.orderName);
      const rows = db.prepare("SELECT id, order_name FROM relay_events WHERE user_id=? AND brand_domain=?").all(userID, String(o.brandDomain).toLowerCase());
      for (const r of rows.filter((r) => r.order_name && orderKey(r.order_name) === key)) {
        updated += db.prepare("UPDATE relay_events SET item_title=?, item_count=? WHERE id=?").run(item, o.itemCount ?? null, r.id).changes;
      }
    }
    return updated;
  }

  return { register, registerGuest, merge, addressFor, ownerOf, receive, retryOutbox, expireGuests, trackerUpdate, track17Update, events, deliver, morningNotes, addTracking, setItems };
}

// ---- HTTP: the app's calls and the trackers' webhooks ---------------------

// `track17` also hears each 17TRACK push (order-tracking.js follows the
// numbers it found on brands' order pages).
export function relayRoutes(app, db, relay, { env = process.env, track17 = [], easypost = [] } = {}) {
  const router = express.Router();
  router.use((req, res, next) => { res.set("Cache-Control", "no-store"); next(); });
  router.use(rateLimit({ windowMs: 60_000, limit: 60, standardHeaders: "draft-8", legacyHeaders: false }));
  router.use(express.json({ limit: "8kb" }));
  router.use((req, res, next) => {
    const user = mobileSessionUser(db, req);
    if (!user) return res.status(401).json({ error: "Please sign in again" });
    req.relayUser = user;
    next();
  });
  const state = (user) => {
    const enabled = relayEnabledFor(user.email, env);
    return { enabled, ...(enabled ? relay.addressFor(user.id) || {} : {}) };
  };
  router.get("/", (req, res) => res.json(state(req.relayUser)));
  router.put("/", (req, res) => {
    if (!relayEnabledFor(req.relayUser.email, env)) return res.status(403).json({ enabled: false });
    // A body "forwardTo" (sent by every app build) is ignored: mail only ever
    // goes to the account's own sign-in email.
    const key = req.get("X-Marracat-Device");
    const device = key && /^[a-f0-9]{64}$/.test(key) ? createHash("sha256").update(key).digest("hex") : null;
    try { relay.register(req.relayUser.id, device); }
    catch (e) { return res.status(e.status || 500).json({ error: e.status ? e.message : "Could not set up your order email" }); }
    res.json(state(req.relayUser));
  });
  router.get("/events", (req, res) => res.json({ events: relayEnabledFor(req.relayUser.email, env) || relay.addressFor(req.relayUser.id) ? relay.events(req.relayUser.id) : [] }));
  // What each order held, by order number, so its pushes can name it.
  router.put("/items", (req, res) => {
    const orders = req.body?.orders;
    const valid = Array.isArray(orders) && orders.length <= 50 && orders.every((o) =>
      o && typeof o.brandDomain === "string" && o.brandDomain.length <= 120 && typeof o.orderName === "string" && o.orderName.length <= 40 &&
      typeof o.itemTitle === "string" && o.itemTitle.length <= 300 && (o.itemCount == null || (Number.isInteger(o.itemCount) && o.itemCount >= 1 && o.itemCount <= 999)));
    if (!valid) return res.status(400).json({ error: "Invalid items" });
    res.json({ updated: relay.setItems(req.relayUser.id, orders) });
  });
  router.use((error, req, res, next) => res.status(error.type === "entity.parse.failed" ? 400 : 500).json({ error: "Request could not be completed" }));
  app.use("/api/mobile/relay", router);

  // Guests: the same order email, keyed to the install's device key. A guest
  // address never shows a forwarding inbox (there is none).
  const guest = express.Router();
  guest.use((req, res, next) => { res.set("Cache-Control", "no-store"); next(); });
  guest.use(rateLimit({ windowMs: 60_000, limit: 30, standardHeaders: "draft-8", legacyHeaders: false }));
  guest.use(express.json({ limit: "1kb" }));
  guest.use((req, res, next) => {
    const key = req.get("X-Marracat-Device");
    if (!key || !/^[a-f0-9]{64}$/.test(key)) return res.status(401).json({ error: "Missing device key" });
    req.guestOwner = guestOwner(createHash("sha256").update(key).digest("hex"));
    next();
  });
  const guestState = (owner) => {
    const enabled = relayGuestsEnabled(env);
    const a = enabled ? relay.addressFor(owner) : null;
    return { enabled, ...(a ? { address: a.address } : {}) };
  };
  guest.get("/", (req, res) => res.json(guestState(req.guestOwner)));
  // New addresses: 10 an hour from one IP (device keys are free to make), on
  // top of the per-install and daily caps in registerGuest.
  guest.put("/", rateLimit({ windowMs: 3600_000, limit: Number(env.RELAY_GUEST_PER_IP_HOUR || 10), standardHeaders: "draft-8", legacyHeaders: false,
    skip: (req) => !!relay.addressFor(req.guestOwner) }), (req, res) => {
    if (!relayGuestsEnabled(env)) return res.status(403).json({ enabled: false });
    try { relay.registerGuest(req.guestOwner.slice("device:".length)); }
    catch (e) { return res.status(e.status || 500).json({ error: e.status ? e.message : "Could not set up your order email" }); }
    res.json(guestState(req.guestOwner));
  });
  guest.get("/events", (req, res) => res.json({ events: relay.addressFor(req.guestOwner) || relayGuestsEnabled(env) ? relay.events(req.guestOwner) : [] }));
  guest.delete("/", (req, res) => { deleteRelayData(db, req.guestOwner); res.json({ enabled: relayGuestsEnabled(env) }); });
  guest.use((error, req, res, next) => res.status(error.type === "entity.parse.failed" ? 400 : 500).json({ error: "Request could not be completed" }));
  app.use("/api/relay/guest", guest);

  app.post("/api/relay/easypost", rateLimit({ windowMs: 60_000, limit: 120, legacyHeaders: false }),
    express.raw({ type: "*/*", limit: "256kb" }), async (req, res) => {
      if (!validEasyPostSignature(req.body, req.get("X-Hmac-Signature"), env.EASYPOST_WEBHOOK_SECRET)) return res.sendStatus(401);
      let payload;
      try { payload = JSON.parse(req.body.toString("utf8")); } catch { return res.sendStatus(400); }
      await relay.trackerUpdate(payload);
      for (const listener of easypost) await listener(payload);
      res.sendStatus(200);
    });

  app.post("/api/relay/17track", rateLimit({ windowMs: 60_000, limit: 120, legacyHeaders: false }),
    express.raw({ type: "*/*", limit: "512kb" }), async (req, res) => {
      if (!valid17TrackSignature(req.body, req.get("sign"), env.TRACK17_API_KEY)) return res.sendStatus(401);
      let payload;
      try { payload = JSON.parse(req.body.toString("utf8")); } catch { return res.sendStatus(400); }
      await relay.track17Update(payload);
      for (const listener of track17) await listener(payload);
      res.sendStatus(200);
    });
}

// ---- SMTP: mail for u-…@orders.marracat.com ------------------------------

export function startRelaySMTP(relay, db, { env = process.env, log = console.log } = {}) {
  const port = Number(env.RELAY_SMTP_LISTEN || 0);
  if (!port) return null;
  const perIP = new Map();
  let tls = {};
  try {
    if (env.RELAY_TLS_KEY && env.RELAY_TLS_CERT) tls = { key: [readFileSync(env.RELAY_TLS_KEY)], cert: [readFileSync(env.RELAY_TLS_CERT)] };
    // An RSA pair beside the ECDSA one: senders that only offer RSA suites
    // failed the handshake (ERR_SSL_NO_SHARED_CIPHER in the log, 2026-10-01).
    if (tls.key && env.RELAY_TLS_KEY_RSA && env.RELAY_TLS_CERT_RSA) {
      tls.key.push(readFileSync(env.RELAY_TLS_KEY_RSA));
      tls.cert.push(readFileSync(env.RELAY_TLS_CERT_RSA));
    }
  } catch (e) { log(`Relay TLS not loaded (${e.code})`); }
  const server = new SMTPServer({
    name: RELAY_DOMAIN,
    banner: "Marracat order mail",
    authOptional: true,
    disabledCommands: ["AUTH"],
    hideSTARTTLS: !tls.key,
    ...tls,
    size: MAX_MESSAGE,
    maxClients: 50,
    socketTimeout: 60_000,
    onConnect(session, cb) {
      // At most 60 messages per sending IP per 10 minutes.
      const now = Date.now(), ip = session.remoteAddress;
      const hits = (perIP.get(ip) || []).filter((t) => now - t < 600_000);
      if (hits.length >= 60) return cb(Object.assign(new Error("Too many messages, try later"), { responseCode: 421 }));
      hits.push(now); perIP.set(ip, hits);
      if (perIP.size > 5000) perIP.clear();
      cb();
    },
    onRcptTo(address, session, cb) {
      const [local, domain] = String(address.address || "").toLowerCase().split("@");
      if (domain !== RELAY_DOMAIN) return cb(Object.assign(new Error("Relay access denied"), { responseCode: 554 }));
      if (session.envelope.rcptTo.length >= 5) return cb(Object.assign(new Error("Too many recipients"), { responseCode: 452 }));
      if (!/^u-[a-z0-9]{10}$/.test(local) || !relay.ownerOf(local))
        return cb(Object.assign(new Error("No such user"), { responseCode: 550 }));
      cb();
    },
    onData(stream, session, cb) {
      const chunks = [];
      let size = 0;
      stream.on("data", (c) => { size += c.length; if (size <= MAX_MESSAGE) chunks.push(c); });
      stream.on("end", async () => {
        if (stream.sizeExceeded || size > MAX_MESSAGE) return cb(Object.assign(new Error("Message too big"), { responseCode: 552 }));
        const raw = Buffer.concat(chunks);
        try {
          for (const r of session.envelope.rcptTo) await relay.receive(raw, r.address.toLowerCase().split("@")[0]);
          cb();
        } catch (e) {
          log(`Relay receive failed (${e.message})`);
          cb(Object.assign(new Error("Try again later"), { responseCode: 451 }));
        }
      });
    },
  });
  // The sending server's address (not a shopper's) shows which MTA a TLS
  // failure is, e.g. the every-2-hours ERR_SSL_NO_SUITABLE_SIGNATURE_ALGORITHM.
  server.on("error", (e) => log(`Relay SMTP error (${e.code || e.message})${e.remoteAddress ? ` from ${e.remoteAddress}` : ""}`));
  server.listen(port, "0.0.0.0", () => log(`Relay SMTP listening on ${port}`));
  const timer = setInterval(() => relay.retryOutbox().catch(() => {}), 5 * 60_000);
  timer.unref();
  return server;
}
