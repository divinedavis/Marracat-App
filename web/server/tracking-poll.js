// Every 10 minutes while anyone has an undelivered order, ask 17TRACK for
// the latest on every tracking number we follow (owner, 2026-10-09: "if a
// user has an order, we should check every 10 minutes").
//
// 17TRACK pushes changes to /api/relay/17track, but only when its own check
// of the carrier runs (every 6–12 hours in transit, per its docs), and a push
// can be lost. gettrackinfo costs no quota (registering does), takes up to 40
// numbers a request and 3 requests a second; each answer goes through the
// same handlers as a push, which only notify on a real change, so asking
// often never repeats a notification.
// Docs: https://api.17track.net/en/doc (v2.4, gettrackinfo)
const TRACK17_INFO = "https://api.17track.net/track/v2.4/gettrackinfo";
export const POLL_EVERY_MS = 10 * 60_000;
const BATCH = 40;
const GAP_MS = 400; // under 3 requests a second

// Every number still on its way: relay shipments not yet delivered or sent
// back (60 days at most) and tracked orders the order-page job hasn't closed.
// EasyPost's trackers (trk_…, USPS since 2026-10-12) aren't 17TRACK's to
// answer: they arrive by EasyPost's webhook only.
export function openNumbers(db, now = Date.now()) {
  const nums = new Set();
  const has = (t) => db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?").get(t);
  if (has("relay_events"))
    for (const r of db.prepare(`SELECT DISTINCT tracker_id FROM relay_events WHERE tracker_id IS NOT NULL AND received > ?
        AND COALESCE(tracking_status,'') NOT IN ('delivered','return_to_sender','cancelled')`).all(now - 60 * 86400_000))
      nums.add(r.tracker_id);
  if (has("tracked_orders"))
    for (const r of db.prepare("SELECT DISTINCT tracker_id FROM tracked_orders WHERE tracker_id IS NOT NULL AND done IS NULL").all())
      nums.add(r.tracker_id);
  return [...nums].filter((n) => !n.startsWith("trk_"));
}

export function trackingPoller(db, { env = process.env, fetcher = fetch, listeners = [], log = console.log,
  now = Date.now, sleep = (ms) => new Promise((r) => setTimeout(r, ms)) } = {}) {
  let running = false;
  async function poll() {
    if (!env.TRACK17_API_KEY || running) return { asked: 0, answered: 0 };
    running = true;
    let asked = 0, answered = 0;
    try {
      const numbers = openNumbers(db, now());
      for (let i = 0; i < numbers.length; i += BATCH) {
        if (i) await sleep(GAP_MS);
        const chunk = numbers.slice(i, i + BATCH);
        asked += chunk.length;
        let body;
        try {
          const res = await fetcher(TRACK17_INFO, {
            method: "POST", signal: AbortSignal.timeout(20000),
            headers: { "17token": env.TRACK17_API_KEY, "Content-Type": "application/json" },
            body: JSON.stringify(chunk.map((number) => ({ number }))),
          });
          if (!res.ok) throw new Error(`HTTP ${res.status}`);
          body = await res.json();
        } catch (e) { log(`17TRACK poll failed: ${e.message}`); continue; }
        for (const item of body?.data?.accepted || []) {
          if (typeof item?.number !== "string" || !item.track_info) continue;
          answered++;
          const payload = { event: "TRACKING_UPDATED", data: { number: item.number, track_info: item.track_info } };
          for (const listener of listeners) {
            try { await listener(payload); } catch (e) { log(`17TRACK poll handler failed: ${e.message}`); }
          }
        }
      }
    } finally { running = false; }
    return { asked, answered };
  }
  return { poll };
}
