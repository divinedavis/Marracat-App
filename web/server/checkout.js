// Builds a brand's Shopify checkout from the shopper's saved details over the
// Universal Commerce Protocol, on the shopper's behalf: the browser can't call
// a brand's store directly (cross-origin), so marracat.com does, with the
// same request the iOS app sends (Marracat/Checkout/UCP.swift). The store
// answers with real shipping and totals and a continue_url that opens its
// own checkout page already filled in; the shopper pays there.
//
// Completing a checkout by API and Shop Pay tokens need permissions Shopify
// grants case by case (brand/shopify-ucp-access-request.md). Nothing here
// holds money or card data, and the shopper's details go only to the store
// whose checkout is being built.
import express from "express";
import { rateLimit } from "express-rate-limit";
import { brandRecord } from "./catalog.js";
import { readText } from "./store-fetch.js";

export const PROFILE_URL = "https://marracat.com/.well-known/ucp";
const text = (v, max) => typeof v === "string" && v.trim().length > 0 && v.length <= max;
const fail = (status, message) => Object.assign(new Error(message), { status });

export function validateBuyer(b) {
  if (!b || typeof b !== "object") throw fail(400, "Missing details");
  for (const [key, max] of [["firstName", 60], ["lastName", 60], ["street", 120], ["city", 80], ["region", 40], ["postalCode", 12]])
    if (!text(b[key], max)) throw fail(400, `Missing ${key}`);
  if (b.extended != null && (typeof b.extended !== "string" || b.extended.length > 120)) throw fail(400, "Invalid address line");
  if (!text(b.email, 254) || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(b.email)) throw fail(400, "Invalid email");
  if (!text(b.phone, 30) || !/^[+\d][\d\s().-]{6,}$/.test(b.phone)) throw fail(400, "Invalid phone");
  return {
    firstName: b.firstName.trim(), lastName: b.lastName.trim(), email: b.email.trim(), phone: b.phone.trim(),
    street: b.street.trim(), extended: (b.extended || "").trim(), city: b.city.trim(), region: b.region.trim(),
    postalCode: b.postalCode.trim(), country: "US",
  };
}

export function validateLines(lines) {
  if (!Array.isArray(lines) || !lines.length || lines.length > 30) throw fail(400, "Invalid cart lines");
  return lines.map((l) => {
    if (!l || !/^\d{1,20}$/.test(String(l.variant)) || !Number.isInteger(l.quantity) || l.quantity < 1 || l.quantity > 99)
      throw fail(400, "Invalid cart line");
    return { variant: String(l.variant), quantity: l.quantity };
  });
}

// The store's UCP endpoint comes from our own catalog, never from the request,
// and still has to look like one before the server will call it.
export function endpointFor(brand) {
  let url;
  try { url = new URL(brand?.ucp || ""); } catch { return null; }
  const host = url.hostname.toLowerCase();
  if (url.protocol !== "https:" || !url.pathname.endsWith("/api/ucp/mcp")) return null;
  if (!host.endsWith(".myshopify.com") && host !== String(brand.domain || "").toLowerCase().replace(/^www\./, "")) return null;
  return url.href;
}

export function createArguments(currency, lines, buyer) {
  const destination = {
    first_name: buyer.firstName, last_name: buyer.lastName, street_address: buyer.street,
    address_locality: buyer.city, address_region: buyer.region, postal_code: buyer.postalCode,
    address_country: buyer.country, phone_number: buyer.phone,
  };
  if (buyer.extended) destination.extended_address = buyer.extended;
  return {
    meta: { "ucp-agent": { profile: PROFILE_URL } },
    checkout: {
      currency,
      line_items: lines.map((l) => ({ quantity: l.quantity, item: { id: `gid://shopify/ProductVariant/${l.variant}` } })),
      buyer: { email: buyer.email, first_name: buyer.firstName, last_name: buyer.lastName, phone_number: buyer.phone },
      attribution: { referring_domain: "marracat.com", utm_source: "marracat", utm_medium: "web" },
      fulfillment: { methods: [{ type: "shipping", line_item_ids: [], destinations: [destination] }] },
    },
  };
}

// The checkout inside a JSON-RPC reply. Shopify puts it in
// result.structuredContent next to a `ucp` negotiation envelope and flags
// isError even for a checkout that merely wants a phone number, so a
// checkout with an id wins over the flag.
export function parseCheckout(reply) {
  if (reply?.error) {
    throw fail(502, reply.error.data?.content || reply.error.message || "The store refused the request");
  }
  const c = reply?.result?.structuredContent;
  if (!c || typeof c.id !== "string") {
    const textPart = reply?.result?.content?.find?.((x) => x.type === "text")?.text;
    throw fail(502, textPart ? String(textPart).slice(0, 200) : "The store didn't return a checkout");
  }
  const amount = (type) => c.totals?.find((t) => t.type === type)?.amount;
  let shippingOption = null;
  for (const m of c.fulfillment?.methods || [])
    for (const g of m.groups || []) {
      const o = g.options?.find((x) => x.id === g.selected_option_id) || g.options?.[0];
      if (o?.title) { shippingOption = o.title; break; }
    }
  const messages = (c.messages || []).filter((m) => m && typeof m === "object").map((m) => ({
    type: m.type, code: m.code, content: typeof m.content === "string" ? m.content.slice(0, 300) : undefined, severity: m.severity,
  }));
  const blockers = messages.filter((m) => m.type === "error");
  let continueUrl = null;
  try {
    const u = new URL(c.continue_url);
    if (u.protocol === "https:") continueUrl = u.href;
  } catch { /* no usable handoff */ }
  const status = typeof c.status === "string" ? c.status : "unknown";
  return {
    id: c.id, status, currency: c.currency || null,
    subtotal: amount("subtotal") ?? null, shipping: amount("fulfillment") ?? null, total: amount("total") ?? null,
    shippingOption, continueUrl, expiresAt: c.expires_at || null, messages,
    needsAttention: ["requires_escalation", "canceled", "unknown"].includes(status) || blockers.length > 0,
  };
}

export async function buildBrandCheckout({ brand, lines, buyer }, fetcher = fetch) {
  const endpoint = endpointFor(brand);
  if (!endpoint) throw fail(409, "This brand's store doesn't take a filled-in checkout yet");
  const body = {
    jsonrpc: "2.0", id: 1, method: "tools/call",
    params: { name: "create_checkout", arguments: createArguments(brand.currency || "USD", lines, buyer) },
  };
  let response;
  try {
    response = await fetcher(endpoint, {
      method: "POST", redirect: "error",
      headers: { "Content-Type": "application/json", Accept: "application/json, text/event-stream", "User-Agent": "Marracat/web (+https://marracat.com)" },
      body: JSON.stringify(body), signal: AbortSignal.timeout(25000),
    });
  } catch {
    throw fail(502, "The store didn't answer");
  }
  if (!response.ok) throw fail(502, `The store answered HTTP ${response.status}`);
  const raw = await readText(response, 2_000_000);
  if (raw == null) throw fail(502, "The store's answer was too large");
  let reply;
  try {
    const ct = response.headers?.get?.("content-type") || "";
    const payload = ct.includes("text/event-stream")
      ? raw.split("\n").filter((l) => l.startsWith("data:")).map((l) => l.slice(5).trim()).pop()
      : raw;
    reply = JSON.parse(payload);
  } catch {
    throw fail(502, "The store's reply couldn't be read");
  }
  return parseCheckout(reply);
}

// Who may build checkouts, and how often (audit 2026-10-07, L2): the route
// calls brands' stores under Marracat's UCP agent profile, so an open proxy
// could get Marracat blocked by a brand or by Shopify. A caller is a signed-in
// shopper or the website itself (a same-origin browser fetch); a guest gets
// BUILDS_PER_IP_BRAND builds per brand per 10 minutes, and guests together
// BUILDS_PER_BRAND_HOUR per brand per hour. Signed-in shoppers skip the
// shared brand cap, so guests can't use it up for them.
export const BUILDS_PER_IP_BRAND = 10;
export const BUILDS_PER_BRAND_HOUR = 120;
export const LIMITER_KEYS = 20000;
export function buildLimiter(now = Date.now, maxKeys = LIMITER_KEYS) {
  // Per-address counts and per-brand counts live apart, and a full map drops
  // its oldest key. Until 2026-11-12 one map held both and was emptied at
  // 20,000 keys, so a flood of addresses reset every brand's hourly cap.
  const perIP = new Map(), perBrand = new Map();
  const take = (hits, key, max, windowMs) => {
    const t = now(), list = (hits.get(key) || []).filter((x) => t - x < windowMs);
    hits.delete(key);
    if (list.length >= max) { hits.set(key, list); return false; }
    list.push(t); hits.set(key, list);
    while (hits.size > maxKeys) hits.delete(hits.keys().next().value);
    return true;
  };
  return ({ ip, brandID, signedIn }) =>
    take(perIP, `${ip}:${brandID}`, BUILDS_PER_IP_BRAND, 600_000) && (signedIn || take(perBrand, brandID, BUILDS_PER_BRAND_HOUR, 3600_000));
}
export const sameOriginBrowser = (req, site) =>
  req.get("Sec-Fetch-Site") === "same-origin" || (req.get("Origin") || "") === site;

export function checkoutRoutes(app, { viewer = async () => null, env = process.env, now = Date.now, lookup = brandRecord, build = buildBrandCheckout } = {}) {
  const router = express.Router();
  const site = env.PUBLIC_URL || "https://marracat.com";
  const allow = buildLimiter(now);
  router.use(rateLimit({ windowMs: 60_000, limit: 40, standardHeaders: "draft-8", legacyHeaders: false }));
  router.use(express.json({ limit: "32kb" }));
  router.post("/build", async (req, res) => {
    try {
      const user = await viewer(req).catch(() => null);
      if (!user && !sameOriginBrowser(req, site)) throw fail(401, "Sign in to check out");
      const brandID = req.body?.brand;
      if (!text(brandID, 80)) throw fail(400, "Missing brand");
      const brand = lookup(brandID);
      if (!brand) throw fail(404, "Unknown brand");
      if (!allow({ ip: req.ip, brandID, signedIn: Boolean(user) })) throw fail(429, "Too many checkouts for this brand. Try again in a few minutes.");
      const result = await build({ brand, lines: validateLines(req.body?.lines), buyer: validateBuyer(req.body?.buyer) });
      res.set("Cache-Control", "no-store").json(result);
    } catch (error) {
      const status = error.status || 500;
      if (status >= 500 && !error.status) console.error("Checkout build failed:", error.name);
      res.status(status).json({ error: error.status ? error.message : "Checkout could not be built" });
    }
  });
  app.use("/api/checkout", router);
}
