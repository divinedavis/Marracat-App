// Whether a phone's delivery Live Activity speaks for an order today, so the
// order's ordinary notification would only say the same thing twice (owner,
// 2026-10-17: "we should only have one notification, not two - lets use live
// notifications"). The card's own update carries the alert instead, with
// sound, on the Lock Screen and in the Dynamic Island (live-activity.js).
//
// Covered: the steps the card shows on the day. "Shipped" and reschedules
// stay ordinary notifications (no card runs before the day). Not covered:
// Live Activities off in the app or in iOS Settings, no start token yet, or
// the card swiped away today; then the ordinary notification goes as before.
// No import from relay.js: it imports this.
// A problem is covered only when a card is on screen now and shows an order
// from that brand (owner, 2026-10-21: "we dont need both notifications, we
// only need the top one"); otherwise it stays an ordinary notification, since
// it can hit an order the day's card doesn't show.
// A reschedule to today is the card's too when it already shows that brand's
// order (owner, 2026-10-26: "do we need both notifications?" — a "Delivery
// rescheduled … Monday" alert under a card saying Out for delivery). A move
// to another day, or with no such card, is still told.
export const LIVE_STEPS = new Set(["out_for_delivery", "delivered", "arriving_today"]);

// Mirrors live-activity.js: a card runs at most 8 hours (Apple), and one
// merely due today starts between 7 am and 9 pm local.
const LIFETIME_MS = 8 * 60 * 60_000;
const START_HOURS = [7, 21];

function local(ms, tz) {
  const parts = (zone) => new Intl.DateTimeFormat("en-CA", { timeZone: zone, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", hourCycle: "h23" }).formatToParts(new Date(ms));
  let p;
  try { p = parts(tz || "America/New_York"); } catch { p = parts("America/New_York"); }
  const get = (t) => p.find((x) => x.type === t)?.value;
  return { day: `${get("year")}-${get("month")}-${get("day")}`, hour: Number(get("hour")) };
}

export function liveCovers(db, device, step, now = Date.now(), { brand, day: newDay } = {}) {
  if (!device || !(LIVE_STEPS.has(step) || step === "problem" || step === "rescheduled")) return false;
  if (!db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='live_activities'").get()) return false;
  const r = db.prepare("SELECT enabled, start_token, dismissed_day, authorized, state, started, demo FROM live_activities WHERE device=?").get(device);
  if (!r || !r.enabled || !r.start_token || r.authorized === 0) return false;
  const tz = db.prepare("SELECT 1 FROM sqlite_master WHERE name='restock_devices'").get()
    ? db.prepare("SELECT tz FROM restock_devices WHERE hash=?").get(device)?.tz : null;
  const { day, hour } = local(now, tz);
  if (r.dismissed_day === day) return false;
  const onScreen = r.state && !r.demo && r.started && now - r.started < LIFETIME_MS;
  if (step === "problem" || step === "rescheduled") {
    if (!onScreen || !brand) return false;
    if (step === "rescheduled" && String(newDay || "").slice(0, 10) !== day) return false;
    let orders = [];
    try { orders = JSON.parse(r.state).orders || []; } catch { return false; }
    const name = String(brand).slice(0, 40);
    return orders.some((o) => o.brand === name);
  }
  // A card on screen now announces any step with its next update.
  if (onScreen) return true;
  // None yet: one starts, with its own alert, for out for delivery at any
  // hour and for "arriving today" in the day's window. Delivered or a
  // problem with no card on screen would go unsaid, so they stay ordinary.
  if (step === "out_for_delivery") return true;
  return step === "arriving_today" && hour >= START_HOURS[0] && hour < START_HOURS[1];
}
