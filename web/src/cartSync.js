// The cart follows the account between the website and the app
// (server/cart-sync.js; owner, 2026-10-05). The browser remembers the
// account cart's `updated` stamp from its last sync and whether it has
// changes not yet sent ("dirty"). On sign-in, load and focus it reads the
// account's cart: with nothing unsent here, that cart replaces this one;
// with unsent changes (a cart started signed out, or a failed send), the two
// merge, keeping the larger quantity of each item, and the result is sent.

const KEY = "marracat-cart-sync";
const state = () => {
  try { return JSON.parse(localStorage.getItem(KEY)) || {}; } catch { return {}; }
};
const store = (s) => { try { localStorage.setItem(KEY, JSON.stringify(s)); } catch { /* private window */ } };

export const toServer = (lines) => lines.map((l) => ({ productID: l.id, variantID: String(l.variant), quantity: Math.min(99, l.quantity) }));
export const fromServer = (lines) => lines.map((l) => ({ key: `${l.productID}:${l.variantID}`, id: l.productID, variant: String(l.variantID), quantity: l.quantity }));

export function mergeCarts(a, b) {
  const out = new Map();
  for (const l of [...a, ...b]) {
    const have = out.get(l.key);
    out.set(l.key, have ? { ...have, quantity: Math.max(have.quantity, l.quantity) } : l);
  }
  return [...out.values()];
}

export const sameCart = (a, b) =>
  a.length === b.length && a.every((l) => b.some((m) => m.key === l.key && m.quantity === l.quantity));

export function markDirty() { store({ ...state(), dirty: true }); }
export function forget() { store({}); }

export async function pushCart(lines) {
  const r = await fetch("/api/cart", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ lines: toServer(lines) }) }).catch(() => null);
  if (!r?.ok) return false;
  const { updated } = await r.json();
  store({ updated, dirty: false });
  return true;
}

/// The cart this browser should show now, or null to keep its own.
export async function pullCart(local) {
  const r = await fetch("/api/cart").catch(() => null);
  if (!r?.ok) return null;
  const remote = await r.json();
  const s = state();
  const theirs = fromServer(remote.lines || []);
  if (s.dirty) {
    const merged = mergeCarts(theirs, local);
    await pushCart(merged);
    return sameCart(merged, local) ? null : merged;
  }
  store({ updated: remote.updated, dirty: false });
  if (remote.updated === 0) {
    // The account has no cart yet: this one becomes it.
    if (local.length) await pushCart(local);
    return null;
  }
  return sameCart(theirs, local) ? null : theirs;
}
