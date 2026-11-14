// Checking out a Big Cartel brand from the website (owner, 2026-10-04).
//
// A Big Cartel cart takes one item per form post to <store>.bigcartel.com/cart
// (cart[add][id] = the option's id). A page on another site can make that post
// only as the shopper's own navigation, so this page does: one item goes
// straight to the brand's cart; several get an "Add" button each, all aimed at
// the same tab, then "Go to checkout". (The app posts every line itself.)
import { brandRecord, productDetails } from "./catalog.js";

const esc = (v) => String(v).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

export const bigCartelHost = (brand) => `${brand.bigcartel || String(brand.domain).split(".")[0]}.bigcartel.com`;

/// "productID:optionID:qty,…" -> lines of this brand, or null if any is wrong.
// productDetails: the full record with variants (the in-memory one is slim).
export function parseLines(items, brandID, lookup = productDetails) {
  const lines = [];
  for (const part of String(items || "").split(",").slice(0, 20)) {
    const m = /^([A-Za-z0-9_-]{1,200}):(\d{1,15}):(\d{1,2})$/.exec(part);
    if (!m) return null;
    const p = lookup(m[1]);
    const v = p?.variants?.find((x) => String(x.id) === m[2]);
    if (!p || p.brand !== brandID || !v || +m[3] < 1) return null;
    lines.push({ title: p.title, option: v.title !== "Default Title" ? v.title : "", id: m[2], qty: +m[3] });
  }
  return lines.length ? lines : null;
}

export function bigCartelRoutes(app, { lookup = { brandRecord, productRecord: productDetails } } = {}) {
  app.get("/go/bigcartel", (req, res) => {
    const brand = lookup.brandRecord(String(req.query.brand || ""));
    if (!brand || brand.platform !== "bigcartel") return res.status(404).send("Not found");
    const lines = parseLines(req.query.items, brand.id, lookup.productRecord);
    if (!lines) return res.status(400).send("Those items aren't available.");
    const host = bigCartelHost(brand), target = "bc-" + brand.id.replace(/[^a-z0-9-]/gi, "");
    const form = (l, i) => `<form method="post" action="https://${host}/cart" target="${target}"${lines.length === 1 ? " data-auto" : ""}>
      <input type="hidden" name="cart[add][id]" value="${esc(l.id)}"><input type="hidden" name="cart[add][quantity]" value="${l.qty}">
      <button type="submit">${lines.length === 1 ? "Continue to" : `${i + 1}. Add`} ${esc(l.title)}${l.option ? " · " + esc(l.option) : ""} × ${l.qty}${lines.length === 1 ? ` at ${esc(brand.name)}` : ""}</button></form>`;
    res.set("Cache-Control", "no-store").type("html").send(`<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Checking out at ${esc(brand.name)} · Marracat</title>
<style>body{font:16px/1.45 -apple-system,system-ui,sans-serif;max-width:520px;margin:40px auto;padding:0 18px;color:#111}
button,a.go{display:block;width:100%;margin:10px 0;padding:14px;border-radius:999px;border:1px solid #111;background:#fff;font:inherit;cursor:pointer;text-align:center;text-decoration:none;color:#111}
a.go{background:#111;color:#fff}.small{color:#6b6b6b;font-size:14px}</style></head><body>
<h1>Checking out at ${esc(brand.name)}</h1>
<p class="small">${esc(brand.name)} sells on Big Cartel, which takes one item at a time. ${lines.length === 1 ? "Taking you to its cart…" : "Add each item to its cart (they open in one tab), then go to checkout."}</p>
${lines.map(form).join("\n")}
${lines.length > 1 ? `<a class="go" href="https://${host}/checkout" target="${target}">Go to checkout</a>` : ""}
<p class="small">${esc(brand.name)} handles payment, shipping and returns.</p>
<script src="/bigcartel-go.js"></script></body></html>`);
  });
}
