import { useEffect, useState } from "react";

// "Trending now" on the home page (owner, 2026-10-10). /api/trending
// (server/trending.js) returns products gaining momentum, or "Popular this
// week" when there isn't enough recent activity, or nothing; the row is drawn
// only with at least MIN_ROW products.
export const MIN_ROW = 6;

export function useTrending(enabled = true) {
  const [row, setRow] = useState(null);
  useEffect(() => {
    if (!enabled) return;
    const controller = new AbortController();
    fetch("/api/trending?limit=24", { signal: controller.signal })
      .then((r) => (r.ok ? r.json() : null))
      .then((body) => {
        if (body && Array.isArray(body.products) && body.products.length >= MIN_ROW && typeof body.title === "string") setRow(body);
      })
      .catch(() => {});
    return () => controller.abort();
  }, [enabled]);
  return row;
}
