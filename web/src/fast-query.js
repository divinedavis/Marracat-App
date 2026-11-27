import { useCallback, useEffect, useRef, useState } from "react";
import { ATTR_FIELDS } from "./attrs.js";

// While the full catalog is still downloading (9.6 MB compressed; 14–45 s on a
// phone, 2026-10-10), a shop, brand, department or search page draws from
// /api/query (server/query.js): the same filter run on the server, one page of
// products plus the counts around the grid. Once the full catalog lands the
// page filters locally again and this hook goes quiet.

export const PAGE = 72;
const FLAGS = ["sale", "under", "stock", "clean", "metal", "scent", "safer", "food", "baby", "fiber", "fabric", "lab", "pet", "material", "home"];

/// The /api/query string for the storefront's filter options.
export function queryString(options, offset = 0) {
  const s = new URLSearchParams();
  for (const k of ["q", "category", "aisle", "brand", "country", "type", ...ATTR_FIELDS, "color"]) if (options[k]) s.set(k, options[k]);
  for (const f of FLAGS) if (options[f]) s.set(f, "1");
  if (options.sort && options.sort !== "featured") s.set("sort", options.sort);
  if (offset) s.set("offset", String(offset));
  s.set("limit", String(PAGE));
  return s.toString();
}

/// The first page that draws tells the full catalog download it may start
/// (main.jsx holds it back on a first load that isn't the home page, so the
/// two don't share a phone's bandwidth).
export const FAST_READY = "marracat:fast-ready";
export const fastReady = () => window.dispatchEvent(new Event(FAST_READY));

/// { products, total, relaxedQuery, typeCounts (Map), aisleCounts, brandCounts,
///   badges, more() } for `options` while
/// `active`, else null. `more()` appends the next page.
export function useServerQuery(active, options) {
  const key = active ? queryString(options) : "";
  const [state, setState] = useState(null);
  const busy = useRef(false);
  useEffect(() => {
    if (!key) return;
    const controller = new AbortController();
    fetch("/api/query?" + key, { signal: controller.signal })
      .then((r) => (r.ok ? r.json() : Promise.reject(Error(String(r.status)))))
      .then((d) => {
        setState({ key, ...d, typeCounts: new Map(Object.entries(d.typeCounts || {})) });
        fastReady();
      })
      .catch(() => {
        // The page falls back to waiting for the full catalog, as before.
        fastReady();
      });
    return () => controller.abort();
  }, [key]);
  const more = useCallback(() => {
    if (!state || state.key !== key || busy.current || state.products.length >= state.total) return;
    busy.current = true;
    fetch("/api/query?" + queryString(options, state.products.length))
      .then((r) => (r.ok ? r.json() : Promise.reject(Error())))
      .then((d) =>
        setState((s) => (s && s.key === key && d.offset === s.products.length
          ? { ...s, products: [...s.products, ...d.products] } : s)),
      )
      .catch(() => {})
      .finally(() => { busy.current = false; });
  }, [state, key]); // eslint-disable-line react-hooks/exhaustive-deps
  return active && state?.key === key ? { ...state, more } : null;
}
