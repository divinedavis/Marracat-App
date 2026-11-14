import React, { useEffect, useState } from "react";

// Sponsored products from verified brands (server/sponsored.js). Every spot
// says "Sponsored"; a tap is reported so the brand pays for it (the server
// decides whether it counts).
const visitor = () => { try { return localStorage.getItem("marracat-visitor") || ""; } catch { return ""; } };

export function useSponsored(placement, { q = "", category = "", product = "" } = {}, enabled = true) {
  const [items, setItems] = useState([]);
  useEffect(() => {
    if (!enabled) { setItems([]); return; }
    const qs = new URLSearchParams({ placement, q, category, product }).toString();
    let live = true;
    fetch("/api/ads/serve?" + qs, { headers: { "X-Marracat-Visitor": visitor() } })
      .then((r) => (r.ok ? r.json() : { items: [] })).then((d) => live && setItems(d.items || [])).catch(() => {});
    return () => { live = false; };
  }, [placement, q, category, product, enabled]);
  return items;
}

export const reportTap = (item, placement) =>
  fetch("/api/ads/tap", { method: "POST", keepalive: true, headers: { "Content-Type": "application/json", "X-Marracat-Visitor": visitor() },
    body: JSON.stringify({ ...item, placement }) }).catch(() => {});

/// The sponsored products for a placement, each labeled, as product cards.
export function SponsoredRow({ placement, items, productMap, renderProduct, title }) {
  const shown = items.map((it) => ({ it, p: productMap.get(it.productID) })).filter((x) => x.p);
  if (!shown.length) return null;
  return (
    <section className={`sponsored-row sponsored-${placement}`} data-section="sponsored">
      {title && <h2>{title}</h2>}
      <div className="product-grid">
        {shown.map(({ it, p }) => (
          <div key={p.id} className="sponsored-card" onClickCapture={() => reportTap(it, placement)}>
            <span className="sponsored-label">Sponsored</span>
            {renderProduct(p)}
          </div>
        ))}
      </div>
    </section>
  );
}
