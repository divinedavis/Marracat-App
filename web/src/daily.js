// Today's picks: the home page's photos change once a day (owner, 2026-10-09).
// Days are counted in New York, so every visitor sees the same picks and they
// turn over at midnight Eastern.
export function dayNumber(now = new Date()) {
  const ymd = new Intl.DateTimeFormat("en-CA", { timeZone: "America/New_York" }).format(now);
  return Math.floor(Date.parse(ymd + "T00:00:00Z") / 86400000);
}

// One item of `list` for today; `salt` lets two tiles differ on the same day.
export const daily = (list, salt = 0, day = dayNumber()) =>
  list.length ? list[(day + salt) % list.length] : undefined;

// `list` starting at today's position, `step` places further each day, so a
// row shows a different run daily. (A step that divides the list length
// repeats the same start every day: 7 with a 7-brand pool did.)
export function rotateDaily(list, salt = 0, day = dayNumber(), step = 1) {
  if (!list.length) return list;
  const at = (((day * step + salt) % list.length) + list.length) % list.length;
  return [...list.slice(at), ...list.slice(0, at)];
}

// Brands with strong product photography for each home-page tile.
export const HERO_BRANDS = ["silver-riley", "brandon-blackwood", "telfar", "anima-iris", "ahluwalia", "px-studio", "bruceglen"];
export const BEAUTY_BRANDS = ["hanahana-beauty", "brown-girl-jane", "the-lip-bar", "pattern-beauty", "fenty-beauty",
  "bread-beauty-supply", "mented-cosmetics", "danessa-myricks-beauty", "buttah-skin", "epara-skincare",
  "koba-skincare", "beauty-bakerie"];
// RIPL EFEK (laundry, "household") joined on 2026-10-10 as a premier brand; the
// Home & living tile takes home and household products.
export const HOME_BRANDS = ["estelle-colored-glass", "harlem-candle-co", "be-so-selfish", "house-of-takura", "ripl-efek"];
