// Orders on the website, from the account the app syncs (server/account-web.js;
// owner, 2026-10-05: "i dont see my orders synced here"). The app stores dates
// as seconds since 2001-01-01 (Swift's Date default), so they convert here.
const APPLE_EPOCH = 978307200;
export const fromAppleDate = (s) => new Date((s + APPLE_EPOCH) * 1000);
export const toAppleDate = (ms) => ms / 1000 - APPLE_EPOCH;

/// An order placed on the website, in the record the app keeps.
export function webOrderRecord({ brandID, lines, subtotal, currency, now = Date.now() }) {
  return {
    id: (crypto.randomUUID?.() || String(now)).toUpperCase(),
    brandID, date: toAppleDate(now),
    itemCount: lines.reduce((n, l) => n + l.quantity, 0),
    subtotal: Math.round(subtotal * 100) / 100,
    productIDs: lines.map((l) => l.id).slice(0, 100),
    currency, subtotalCurrency: currency,
    items: lines.slice(0, 100).map((l) => ({ title: (l.title || "Item").slice(0, 500), quantity: l.quantity })),
  };
}

export async function recordWebOrder(record) {
  await fetch("/api/account/activity", { method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ operations: [{ id: record.id, kind: "checkout", checkout: record }] }) }).catch(() => {});
}

