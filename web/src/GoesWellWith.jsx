import { useEffect, useState } from "react";
import { track } from "./events";

// "Goes well with" on a product page (owner, 2026-10-10): the brand's own
// Shopify recommendations plus what other shoppers put in the cart with it
// (server/complements.js). Shown only with at least four products.
export const MIN_SHOWN = 4;

/// The complement products for one product: the catalog's own records where
/// the page has them, else the card the server sent.
export function useComplements(productID, productMap) {
  const [answer, setAnswer] = useState(null);
  useEffect(() => {
    setAnswer(null);
    if (!productID) return;
    const controller = new AbortController();
    fetch(`/api/products/${encodeURIComponent(productID)}/complements`, { signal: controller.signal })
      .then((r) => (r.ok ? r.json() : null))
      .then((d) => d && Array.isArray(d.products) && setAnswer(d))
      .catch(() => {});
    return () => controller.abort();
  }, [productID]);
  if (!answer) return [];
  const cards = new Map((answer.items || []).map((c) => [c.id, c]));
  return answer.products
    .map((id) => productMap.get(id) || cards.get(id))
    .filter((p) => p && p.available && p.id !== productID);
}

/// Counts the row once per product shown, and each tap on it (rec_view /
/// rec_tap, row "complements"), so we can tell whether it helps.
export function useRowTracking(row, productID, shown) {
  useEffect(() => {
    if (shown) track("rec_view", { row, product: productID, platform: "web" });
  }, [row, productID, shown]);
  return (tapped, position) => track("rec_tap", { row, product: tapped, position, platform: "web" });
}
