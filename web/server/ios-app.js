// Whether the iPhone app is actually on the App Store right now.
//
// The banner that points people at the app must never point at a dead page.
// On 2026-09-23 the listing 404'd because the app had been removed from sale
// in App Store Connect while it was otherwise approved, so "we shipped it"
// and "someone can download it" are not the same question. This asks Apple.
//
// iTunes' lookup API answers with resultCount 0 for an app that isn't
// available in the storefront, and with the listing when it is. The answer is
// cached so the site doesn't call Apple on every page view, and a failed call
// keeps the last known answer rather than hiding a live app.

export const IOS_APP_ID = "6810905687";
export const IOS_APP_URL = `https://apps.apple.com/us/app/marracat/id${IOS_APP_ID}`;

const LOOKUP = `https://itunes.apple.com/lookup?id=${IOS_APP_ID}&country=us`;
// Apple answers the lookup with an empty result set — 200, no rows — unless the
// caller looks like a browser. Node's fetch doesn't, so the live app read as
// missing and the banner stayed hidden. Measured on the droplet 2026-09-23.
const LOOKUP_HEADERS = {
  "User-Agent":
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
    "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
  Accept: "application/json",
};
const FRESH_MS = 60 * 60 * 1000; // an hour: releasing an app is not a per-minute event
const RETRY_MS = 5 * 60 * 1000; // after a failed call, try again sooner

export function iosAppRoutes(app, { fetcher = fetch, now = Date.now, env = process.env } = {}) {
  // IOS_APP_FORCE_LIVE=1 shows the banner before Apple's lookup catches up.
  // Availability can be saved in App Store Connect and still take hours to
  // reach the store, and during that gap the honest answer ("not yet") is not
  // the useful one. Clear it once the lookup answers on its own.
  const forced = () => env.IOS_APP_FORCE_LIVE === "1";
  // `nextCheckAt: 0` means "never asked", which is not the same as "asked long
  // ago" — an earlier version compared timestamps and read a fresh process as
  // already up to date, so it never called Apple at all.
  let cached = { live: false, version: null, minimumOsVersion: null };
  let nextCheckAt = 0;
  let asked = false;
  let inFlight = null;

  async function check() {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 8000);
    try {
      const r = await fetcher(LOOKUP, { signal: controller.signal, headers: LOOKUP_HEADERS });
      if (!r.ok) throw new Error(`lookup ${r.status}`);
      const body = await r.json();
      const listing = Array.isArray(body.results) ? body.results[0] : null;
      cached = {
        live: Boolean(listing),
        version: listing?.version ?? null,
        minimumOsVersion: listing?.minimumOsVersion ?? null,
      };
      nextCheckAt = now() + FRESH_MS;
    } catch {
      // Keep whatever we last knew and retry sooner, so a blip at Apple never
      // hides a live app.
      nextCheckAt = now() + RETRY_MS;
    } finally {
      clearTimeout(timer);
      asked = true;
      inFlight = null;
    }
    return cached;
  }

  function state() {
    if (forced()) return Promise.resolve({ ...cached, live: true });
    if (asked && now() < nextCheckAt) return Promise.resolve(cached);
    inFlight ??= check();
    // Once we have an answer, a stale one beats making the page wait on Apple;
    // the refresh lands for the next caller. Only the first call ever blocks.
    return asked ? Promise.resolve(cached) : inFlight;
  }

  app.get("/api/ios-app", async (_, res) => {
    const s = await state();
    res.set("Cache-Control", "public, max-age=600");
    res.json({ live: s.live, url: IOS_APP_URL, appId: IOS_APP_ID, version: s.version });
  });

  return { state, check };
}
