// What every fetch of a brand's store shares: a body read that stops at a
// byte cap, and the one redirect a store may make.
//
// `await res.text()` buffers the whole answer before any length check, so a
// store (or whoever answers for its domain) sending gigabytes would take the
// 2 GB server down with it. readText stops reading at the cap instead.
import { getDomain } from "tldts";

const IP_LITERAL = /^(\d+(\.\d+){3}|\[.*\])$/;

/// The body as text, or null once it passes `max` bytes (`truncate` keeps the
/// first `max` instead). A declared Content-Length over the cap is refused
/// without reading. Test doubles with only `text()` are measured afterwards.
export async function readText(res, max, { truncate = false } = {}) {
  const declared = Number(res.headers?.get?.("content-length"));
  if (!truncate && Number.isFinite(declared) && declared > max) {
    try { await res.body?.cancel?.(); } catch {}
    return null;
  }
  const reader = res.body?.getReader?.();
  if (!reader) {
    const text = await res.text();
    if (text.length <= max) return text;
    return truncate ? text.slice(0, max) : null;
  }
  const chunks = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    const room = max - size;
    if (value.byteLength > room) {
      try { await reader.cancel(); } catch {}
      if (!truncate) return null;
      chunks.push(value.subarray(0, room));
      break;
    }
    chunks.push(value);
    size += value.byteLength;
  }
  return Buffer.concat(chunks).toString("utf8");
}

/// Where a store's redirect may lead: https, no port, no address literal, and
/// the same registrable domain as `host` or the store's myshopify.com name.
/// `path`, when given, must still match. Returns the URL or null.
export function storeRedirect(location, from, host, { path = null } = {}) {
  let next;
  try { next = new URL(location || "", from); } catch { return null; }
  if (!location || next.protocol !== "https:" || next.port || next.username || next.password || IP_LITERAL.test(next.hostname)) return null;
  if (path && !path.test(next.pathname)) return null;
  const same = getDomain(next.hostname) && getDomain(next.hostname) === getDomain(host);
  return same || next.hostname.endsWith(".myshopify.com") ? next.toString() : null;
}

/// One GET of a store's JSON, following at most one redirect and only where
/// storeRedirect allows. null for anything else: an error, a body over `max`,
/// or text that isn't JSON.
export async function getStoreJSON(url, fetchImpl, { max, timeoutMs, path = null } = {}) {
  const host = new URL(url).hostname;
  let target = url;
  for (let hop = 0; hop < 2; hop++) {
    const res = await fetchImpl(target, {
      redirect: "manual", signal: AbortSignal.timeout(timeoutMs),
      headers: { Accept: "application/json", "User-Agent": "Marracat/1.0 (+https://marracat.com)" },
    });
    if (res.status >= 300 && res.status < 400) {
      const next = hop ? null : storeRedirect(res.headers?.get?.("location"), target, host, { path });
      if (!next) return null;
      target = next;
      continue;
    }
    if (!res.ok) return null;
    const text = await readText(res, max);
    if (text == null) return null;
    try { return JSON.parse(text); } catch { return null; }
  }
  return null;
}
