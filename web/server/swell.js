// Checking out a Swell brand (owner, 2026-10-10: Yeezy, the first; more Swell
// brands if it works).
//
// Swell's storefront API builds a cart with the store's public key — the one
// its own site sends, which Swell issues for browsers — and answers with a
// checkout_url on the brand's own site (yeezy.com/checkout/<id>) that opens
// with the items in it, no cookie needed. So this route builds the cart and
// redirects there; the app's checkout sheet and the website both open it.
// Swell ids are 24-hex ObjectIds, too wide for the app's Int64 variant ids, so
// the catalog carries a hash as the variant id and the Swell ids beside it
// (catalog/build_catalog.py: shape_swell).
import { rateLimit } from "express-rate-limit";
import { brandRecord, productDetails } from "./catalog.js";

const esc = (v) => String(v).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const OBJECT_ID = /^[a-f0-9]{24}$/;

/// "productID:variantID:qty,…" -> Swell lines of this brand, or null if any is
/// wrong, unknown, sold out or not a Swell product.
export function parseSwellLines(items, brandID, lookup = productDetails) {
  const lines = [];
  for (const part of String(items || "").split(",").slice(0, 20)) {
    const m = /^([A-Za-z0-9_-]{1,200}):(\d{1,16}):(\d{1,2})$/.exec(part);
    if (!m) return null;
    const p = lookup(m[1]);
    const v = p?.variants?.find((x) => String(x.id) === m[2]);
    if (!p || p.brand !== brandID || !v || !v.available || +m[3] < 1) return null;
    if (!OBJECT_ID.test(p.swell_product || "") || (v.swell != null && !OBJECT_ID.test(v.swell))) return null;
    const line = { product_id: p.swell_product, quantity: +m[3] };
    if (v.swell) line.variant_id = v.swell;
    lines.push(line);
  }
  return lines.length ? lines : null;
}

/// The brand's Swell store and key, when they look like Swell's own.
export function swellConfig(brand) {
  const s = brand?.platform === "swell" ? brand.swell : null;
  if (!s || !/^[a-z0-9-]{1,63}$/.test(s.store || "") || !/^pk_[A-Za-z0-9]{8,64}$/.test(s.key || "")) return null;
  return s;
}

/// Is this where a checkout may go? Only the brand's own site or its Swell
/// store, over https — never wherever a reply happens to point.
export function safeCheckoutURL(url, brand, store) {
  let u;
  try {
    u = new URL(url);
  } catch {
    return false;
  }
  const host = u.hostname.toLowerCase(), domain = String(brand.domain).toLowerCase();
  return u.protocol === "https:" && (host === domain || host === "www." + domain || host === `${store}.swell.store`);
}

/// Builds the cart: the first item makes it and hands back a session, the rest
/// join it, then the Marracat referral and note go on it (Swell keeps both on
/// the order). Returns the checkout URL or throws.
export async function createSwellCheckout(cfg, lines, { fetchImpl = fetch, note } = {}) {
  const base = `https://${cfg.store}.swell.store/api`;
  const auth = "Basic " + Buffer.from(`${cfg.key}:`).toString("base64");
  let session = null, cart = null;
  const call = async (method, path, body) => {
    const headers = { Authorization: auth, "Content-Type": "application/json", Accept: "application/json" };
    if (session) headers["X-Session"] = session;
    const r = await fetchImpl(base + path, { method, headers, body: JSON.stringify(body), signal: AbortSignal.timeout(10_000) });
    session = r.headers.get("x-session") || session;
    const data = await r.json().catch(() => null);
    if (!r.ok || !data || data.error || data.errors) throw Error(`swell ${path} ${r.status}`);
    return data;
  };
  for (const line of lines) cart = await call("POST", "/cart/items", line);
  cart = await call("PUT", "/cart", { metadata: { referral: "marracat" }, comments: note });
  if (!cart?.checkout_url || cart.item_quantity !== lines.reduce((n, l) => n + l.quantity, 0)) throw Error("swell cart incomplete");
  return cart.checkout_url;
}

/// The cheapest shipping the store offers these lines to a US ZIP, from the
/// rating Swell puts on a cart once it has an address (owner, 2026-10-16:
/// estimate every brand's shipping in the bag). The cart is never checked
/// out; it carries only the items and the ZIP. { amount, currency, title } or
/// null when the store rated nothing.
export async function swellShippingQuote(cfg, lines, zip, { fetchImpl = fetch } = {}) {
  const base = `https://${cfg.store}.swell.store/api`;
  const auth = "Basic " + Buffer.from(`${cfg.key}:`).toString("base64");
  let session = null, cart = null;
  const call = async (method, path, body) => {
    const headers = { Authorization: auth, "Content-Type": "application/json", Accept: "application/json" };
    if (session) headers["X-Session"] = session;
    const r = await fetchImpl(base + path, { method, headers, body: JSON.stringify(body), signal: AbortSignal.timeout(10_000) });
    session = r.headers.get("x-session") || session;
    const data = await r.json().catch(() => null);
    if (!r.ok || !data || data.error || data.errors) throw Error(`swell ${path} ${r.status}`);
    return data;
  };
  for (const line of lines) await call("POST", "/cart/items", line);
  cart = await call("PUT", "/cart", { shipping: { zip, country: "US" } });
  const services = (cart?.shipment_rating?.services || []).filter((s) => Number.isFinite(s?.price) && s.price >= 0);
  if (!services.length) return null;
  const best = services.reduce((a, b) => (b.price < a.price ? b : a));
  return { amount: Math.round(best.price * 100) / 100, currency: String(cart.currency || "USD").slice(0, 3), title: String(best.name || "").slice(0, 80) || null };
}

function errorPage(res, status, brand, message) {
  res.status(status).set("Cache-Control", "no-store").type("html").send(`<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Checkout · Marracat</title>
<style>body{font:16px/1.45 -apple-system,system-ui,sans-serif;max-width:520px;margin:40px auto;padding:0 18px;color:#111}
a{display:block;margin:16px 0;padding:14px;border-radius:999px;background:#111;color:#fff;text-align:center;text-decoration:none}</style></head><body>
<h1>${esc(message)}</h1>
${brand ? `<a href="https://${esc(brand.domain)}/">Shop at ${esc(brand.name)}</a>` : ""}</body></html>`);
}

export function swellRoutes(app, { lookup = { brandRecord, productRecord: productDetails }, fetchImpl = fetch } = {}) {
  // Each request makes up to 21 calls to the brand's store; keep it to what a shopper does.
  app.use("/go/swell", rateLimit({ windowMs: 60_000, limit: 20, standardHeaders: "draft-8", legacyHeaders: false }));
  app.use("/api/ship-quote/swell", rateLimit({ windowMs: 60_000, limit: 30, standardHeaders: "draft-8", legacyHeaders: false }));
  app.get("/api/ship-quote/swell", async (req, res) => {
    const brand = lookup.brandRecord(String(req.query.brand || ""));
    const cfg = swellConfig(brand);
    if (!cfg) return res.status(404).json({ error: "Not found" });
    const zip = String(req.query.zip || "");
    if (!/^\d{5}(-\d{4})?$/.test(zip)) return res.status(400).json({ error: "Bad ZIP" });
    const lines = parseSwellLines(req.query.items, brand.id, lookup.productRecord);
    if (!lines) return res.status(400).json({ error: "Those items aren't available." });
    try {
      const quote = await swellShippingQuote(cfg, lines, zip.slice(0, 5), { fetchImpl });
      res.set("Cache-Control", "no-store").json({ quote });
    } catch (e) {
      console.error(`swell quote ${brand.id}:`, e.message);
      res.status(500).json({ error: "The store didn't answer." });
    }
  });
  app.get("/go/swell", async (req, res) => {
    const brand = lookup.brandRecord(String(req.query.brand || ""));
    const cfg = swellConfig(brand);
    if (!cfg) return errorPage(res, 404, null, "Not found");
    const lines = parseSwellLines(req.query.items, brand.id, lookup.productRecord);
    if (!lines) return errorPage(res, 400, brand, "Those items aren't available.");
    try {
      const url = await createSwellCheckout(cfg, lines, { fetchImpl, note: `Order placed through Marracat` });
      if (!safeCheckoutURL(url, brand, cfg.store)) throw Error("unexpected checkout host");
      res.set("Cache-Control", "no-store").redirect(303, url);
    } catch (e) {
      console.error(`swell checkout ${brand.id}:`, e.message);
      // 500, not 502: nginx swaps a 502-504 from /go/ for the storefront.
      errorPage(res, 500, brand, `${brand.name}'s checkout didn't answer. Try again in a minute.`);
    }
  });
}
