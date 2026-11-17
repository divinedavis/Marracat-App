// The shopping alerts' cards (owner, 2026-11-15: the designs picked from
// "Marracat Alerts Preview v2" and the alert videos). Each push keeps Apple's
// text alert for the Lock Screen and adds:
//   - mutable-content, so the app's service extension puts the product photo
//     on the banner (MarracatNotificationService);
//   - a category, which picks the press-and-hold card and its buttons
//     (MarracatNotificationContent, AlertCategories in the app);
//   - `card`, the card's content (AlertCards/AlertCard.swift reads it: keep
//     the short field names in step).
// The old fields (productID, brandID) stay, so older app versions still open
// the right page.

const money = (n, cur = "USD") => new Intl.NumberFormat("en-US", { style: "currency", currency: cur || "USD" }).format(n);
/// A whole-dollar price without cents ("$189"), else with them.
const short = (n, cur) => (Number.isInteger(n) ? money(n, cur).replace(/\.00$/, "") : money(n, cur));
const clip = (s, n = 70) => { const t = String(s ?? "").trim(); return t.length > n ? t.slice(0, n - 1).trimEnd() + "…" : t; };
const pct = (was, now) => `−${Math.round((1 - now / was) * 100)}%`;

/// A Shopify image at notification size; other https images as they are.
export function small(url, width = 400) {
  try {
    const u = new URL(url);
    if (u.protocol !== "https:") return null;
    if (/shopify/.test(u.host) || u.pathname.includes("/cdn/shop/")) u.searchParams.set("width", String(width));
    return u.toString();
  } catch { return null; }
}

export const item = (p, extra = {}) => ({ id: p.id, t: clip(p.title), p: short(p.price, p.currency), img: small(p.images?.[0]), ...extra });

const productLink = (id) => `marracat://product/${encodeURIComponent(id)}`;
const brandLink = (id) => `marracat://brand/${encodeURIComponent(id)}`;
const picksLink = (title, ids) => `marracat://picks?title=${encodeURIComponent(title)}&ids=${ids.slice(0, 24).map(encodeURIComponent).join(",")}`;

/// APNs takes 4 KB: drop photos, then items, until it fits.
export const MAX_BYTES = 3800;
export function fit(payload) {
  const size = () => Buffer.byteLength(JSON.stringify(payload));
  const card = payload.card;
  while (card && size() > MAX_BYTES && card.items?.length > 1) card.items.pop();
  while (card && size() > MAX_BYTES && card.rows?.length > 1) card.rows.pop();
  if (size() > MAX_BYTES) { delete payload.card; delete payload.aps["mutable-content"]; }
  return payload;
}

function push({ title, body, card, extra = {} }) {
  const aps = { alert: { title, body }, sound: "default", "mutable-content": 1, category: `MC_${card.k.toUpperCase()}` };
  if (card.bid) aps["thread-id"] = `brand-${card.bid}`;
  for (const k of Object.keys(card)) if (card[k] == null) delete card[k];
  return fit({ aps, card, ...extra });
}

/// C01: a watched brand's new products.
export function dropPush(brand, brandID, products) {
  const n = products.length;
  const body = n === 1 ? products[0].title : `${n} new products, including ${products[0].title}`;
  const card = { k: "drop", t: `New from ${brand}`, s: n === 1 ? "1 new piece just dropped" : `${n} new pieces just dropped`,
    items: products.slice(0, 3).map((p) => item(p)), bid: brandID, pid: n === 1 ? products[0].id : null,
    open: n === 1 ? productLink(products[0].id) : brandLink(brandID) };
  return push({ title: `New from ${brand}`, body, card, extra: n === 1 ? { productID: products[0].id } : { brandID } });
}

/// C03: a followed brand's sale, with its biggest markdowns.
export function salePush(brand, brandID, count, products = []) {
  const marked = products.filter((p) => p.brand === brandID && p.available !== false && p.compare_at > p.price)
    .sort((a, b) => (1 - b.price / b.compare_at) - (1 - a.price / a.compare_at));
  const best = marked[0] ? Math.round((1 - marked[0].price / marked[0].compare_at) * 100) : 0;
  const card = { k: "sale", t: `${brand} sale`, s: best ? `${count} items marked down · up to ${best}% off` : `${count} items marked down`,
    items: marked.slice(0, 4).map((p) => item(p, { badge: pct(p.compare_at, p.price) })), bid: brandID, open: brandLink(brandID) };
  return push({ title: `${brand} is having a sale`, body: `${count} items marked down`, card, extra: { brandID } });
}

/// C04: back in stock, with Add to bag.
export function restockPush(product, brand, variantID = null) {
  const card = { k: "restock", t: "Back in stock", s: `${brand} · your restock alert`,
    items: [item(product)], pid: product.id, bid: product.brand, vid: variantID ? String(variantID) : null, open: productLink(product.id) };
  return push({ title: "Back in stock", body: `${product.title} is back in stock at ${brand}`, card, extra: { productID: product.id } });
}

/// D01: one watched price dropped. The new price is the card's hero.
export function pricePush(product, brand, was, now) {
  const cur = product.currency || "USD";
  const card = { k: "price", t: "Price drop", s: `${brand} · you're watching its price`, price: money(now, cur), was: short(was, cur),
    pct: pct(was, now), items: [item({ ...product, price: now })], pid: product.id, bid: product.brand, open: productLink(product.id) };
  return push({ title: `Price drop: ${money(now, cur)} (was ${short(was, cur)})`,
    body: `${product.title} is now ${money(now, cur)} at ${brand}`, card, extra: { productID: product.id } });
}

/// D02: several watched prices dropped at once: one card, the total saved.
export function savedPush(drops) {
  const n = drops.length;
  const brands = [...new Set(drops.map((d) => d.brand).filter(Boolean))];
  const saved = drops.reduce((sum, d) => sum + Math.max(0, d.was - d.now), 0);
  const cur = drops[0].product.currency || "USD";
  const names = brands.length > 3 ? `${brands.slice(0, 3).join(", ")} and ${brands.length - 3} more` : brands.join(brands.length === 2 ? " and " : ", ");
  const title = `${n} things you're watching just got cheaper`;
  const card = { k: "saved", t: title, s: names, save: money(saved, cur),
    items: drops.slice(0, 3).map((d) => item({ ...d.product, price: d.now })),
    open: picksLink("Price drops", drops.map((d) => d.product.id)) };
  return push({ title, body: `${names}. Save ${money(saved, cur)} in all.`, card, extra: { productID: drops[0].product.id } });
}

/// D04: one size left of something they watch.
export function lastSizePush(product, brand, state) {
  const card = { k: "lastsize", t: "Last size left", s: `${brand} · ${short(product.price, product.currency)} · you're watching it`,
    items: [item(product)], sizes: state.sizes, size: state.size, vid: state.variant ? String(state.variant) : null,
    pid: product.id, bid: product.brand, open: productLink(product.id) };
  return push({ title: "Last size left", body: `${product.title} at ${brand} is down to size ${state.size}`, card, extra: { productID: product.id } });
}

/// C06: the day's held-back alerts together.
export function digestPush(rows) {
  const n = rows.length;
  const kinds = [...new Set(rows.map((r) => r.kind))];
  const words = { price: "price drops", sale: "sales", drop: "new drops", lastsize: "last sizes" };
  const summary = kinds.map((k) => words[k] || k);
  const s = summary.length > 1 ? `${summary.slice(0, -1).join(", ")} and ${summary.at(-1)}` : summary[0] || "";
  const card = { k: "digest", t: n === 1 ? "1 update today" : `${n} updates today`, s: s.charAt(0).toUpperCase() + s.slice(1),
    rows: rows.slice(0, 4).map(({ tile, b, t, st, tint }) => ({ tile, b, t: clip(t, 60), st, tint })), open: rows[0]?.open || null };
  const body = rows.slice(0, 4).map((r) => `${r.b}: ${r.t}`).join("; ") + (n > 4 ? `; and ${n - 4} more` : "");
  return push({ title: card.t, body, card });
}

/// The digest's row for an alert held back, from its card.
export function digestRow(card) {
  const first = card.items?.[0];
  switch (card.k) {
    case "price": return { kind: "price", tile: "tag", b: (card.s || "").split(" · ")[0], t: first?.t || "", st: card.pct || "Price drop", tint: "green", open: card.open };
    case "saved": return { kind: "price", tile: "tag", b: card.s || "", t: card.t, st: "Drops", tint: "green", open: card.open };
    case "sale": return { kind: "sale", tile: "sale", b: card.t.replace(/ sale$/, ""), t: (card.s || "").split(" · ")[0], st: "Sale", tint: "orange", open: card.open };
    case "drop": return { kind: "drop", tile: "new", b: card.t.replace(/^New from /, ""), t: first?.t || card.s || "", st: "New", tint: "blue", open: card.open };
    case "lastsize": return { kind: "lastsize", tile: "size", b: (card.s || "").split(" · ")[0], t: first?.t || "", st: `Size ${card.size}`, tint: "orange", open: card.open };
    default: return null;
  }
}

/// The sizes of a live Shopify product (its .js), when it sells in sizes:
/// each size and whether any of its variants can be bought.
export function sizeState(live) {
  if (!live || !Array.isArray(live.variants) || live.variants.length < 2) return null;
  const options = Array.isArray(live.options) ? live.options : [];
  const at = options.findIndex((o) => /size/i.test(typeof o === "string" ? o : o?.name || ""));
  if (at < 0) return null;
  const key = `option${at + 1}`;
  const sizes = new Map();
  for (const v of live.variants) {
    const label = String(v[key] ?? "").trim();
    if (label) sizes.set(label, sizes.get(label) === true || v.available === true);
  }
  if (sizes.size < 2) return null;
  const list = [...sizes].map(([l, a]) => ({ l: clip(l, 8), a }));
  const left = [...sizes].filter(([, a]) => a).map(([l]) => l);
  const variant = left.length === 1 ? live.variants.find((v) => String(v[key] ?? "").trim() === left[0] && v.available === true)?.id : null;
  return { sizes: list.slice(0, 6), left: left.length, size: left.length === 1 ? clip(left[0], 8) : null, variant: variant ?? null };
}
