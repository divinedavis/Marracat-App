// What this browser has searched and opened, kept on this device only (never
// sent), for "Picked for you" on a short search (owner, 2026-11-03: someone
// who has been looking at charms and searches "fruit" sees a charm or two).
// The app keeps the same lists in ShopperStore: 30 searches, 100 views.
const KEY = "marracat-recent";
const MAX_SEARCHES = 30, MAX_VIEWED = 100;

const clean = (list, max) => (Array.isArray(list) ? list.filter((x) => typeof x === "string" && x && x.length <= 200).slice(0, max) : []);

export function readRecent(storage = globalThis.localStorage) {
  try {
    const v = JSON.parse(storage?.getItem(KEY) || "{}");
    return { searches: clean(v.searches, MAX_SEARCHES), viewed: clean(v.viewed, MAX_VIEWED) };
  } catch {
    return { searches: [], viewed: [] };
  }
}

function write(v, storage) {
  try { storage?.setItem(KEY, JSON.stringify(v)); } catch {}
}

/// Newest first, a repeat moving to the front (case aside), as the app does.
export function rememberSearch(q, storage = globalThis.localStorage) {
  const text = String(q || "").trim().slice(0, 200);
  if (!text) return;
  const v = readRecent(storage);
  v.searches = [text, ...v.searches.filter((s) => s.toLowerCase() !== text.toLowerCase())].slice(0, MAX_SEARCHES);
  write(v, storage);
}

export function rememberView(id, storage = globalThis.localStorage) {
  if (!id || typeof id !== "string") return;
  const v = readRecent(storage);
  if (v.viewed[0] === id) return;
  v.viewed = [id, ...v.viewed.filter((x) => x !== id)].slice(0, MAX_VIEWED);
  write(v, storage);
}

/// Signing out: this browser forgets what was searched and opened.
export function forgetRecent(storage = globalThis.localStorage) {
  try { storage?.removeItem(KEY); } catch {}
}
