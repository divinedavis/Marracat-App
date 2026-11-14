// Live stock on the product page (owner, 2026-10-11): the catalog is refreshed
// about every 12 hours, so the page asks /api/products/<id>/stock (the brand's
// own store, cached ~90 s on the server) and lays its answer over the
// catalog's. No answer, or { live: false }, leaves the catalog's stock as is.

/// The product with the store's live stock (and, for dollar products, price)
/// laid over its variants. Options the store no longer lists keep the
/// catalog's values; a product whose options haven't loaded takes the store's.
export function withLiveStock(product, stock) {
  if (!product || !stock?.live || stock.id !== product.id || !Array.isArray(stock.variants)) return product;
  const live = new Map(stock.variants.map((v) => [String(v.id), v]));
  const base = product.variants?.length ? product.variants : stock.variants.map((v) => ({ id: v.id, title: v.title, price: product.price, compare_at: product.compare_at, available: false }));
  const variants = base.map((v) => {
    const l = live.get(String(v.id));
    if (!l) return v;
    const next = { ...v, available: l.available === true };
    if (typeof l.price === "number") { next.price = l.price; next.compare_at = l.compare_at ?? null; }
    return next;
  });
  return { ...product, variants, available: stock.available === true || variants.some((v) => v.available) };
}

/// The page's live stock for one product, or null until (and unless) it arrives.
export async function fetchLiveStock(id, { signal, fetchImpl = fetch } = {}) {
  try {
    const r = await fetchImpl("/api/products/" + encodeURIComponent(id) + "/stock", { signal, cache: "no-store" });
    if (!r.ok) return null;
    const body = await r.json();
    return body && body.id === id ? body : null;
  } catch {
    return null;
  }
}
