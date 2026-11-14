// Dollar rates for brands that don't charge in dollars: the London and Paris
// brands (£, €) and, from 2026-10-08, the Swedish (kr), South African (R),
// Nigerian (₦), Kenyan (KSh) and Ghanaian (GH₵) ones.
//
// The site shows "£18.00 (≈ $23.92)" and totals a mixed cart as one
// approximate dollar figure. The ECB's reference rates come from Frankfurter
// (free, no key; they change once a working day); the ECB doesn't publish
// NGN, KES or GHS, so those come from ExchangeRate-API's open endpoint (free,
// no key; attribution: "Rates by Exchange Rate API",
// https://www.exchangerate-api.com). The server asks at most every 12 hours
// and keeps the last good rate per currency when a call fails or answers
// something absurd. The fallback is for a server that has never reached them.

const ECB = "https://api.frankfurter.dev/v1/latest?base=USD&symbols=GBP,EUR,SEK,ZAR";
const OPEN = "https://open.er-api.com/v6/latest/USD";
const FROM_ECB = ["GBP", "EUR", "SEK", "ZAR"];
const FROM_OPEN = ["NGN", "KES", "GHS"];
const FRESH_MS = 12 * 60 * 60 * 1000;
const RETRY_MS = 15 * 60 * 1000;
// Units per US dollar, 2026-10-08 (ECB; ExchangeRate-API for NGN, KES, GHS).
const PER_USD = { GBP: 0.757, EUR: 0.894, SEK: 10.0, ZAR: 16.65, NGN: 1331, KES: 129.6, GHS: 11.65 };
const FALLBACK = {
  date: "2026-10-08",
  usd: Object.fromEntries(Object.entries(PER_USD).map(([c, v]) => [c, 1 / v])),
  fallback: true,
};
// A rate more than twice or under half the reference is a bad answer, not a
// currency crisis.
const sane = (cur, rate) => rate > PER_USD[cur] / 2 && rate < PER_USD[cur] * 2;

export function fxRoutes(app, { fetcher = fetch, now = Date.now } = {}) {
  let cached = FALLBACK;
  let nextAt = 0;
  let inflight = null;

  async function refresh() {
    const usd = { ...cached.usd };
    let date = cached.date, gotAny = false, allOk = true;
    for (const [url, currencies] of [[ECB, FROM_ECB], [OPEN, FROM_OPEN]]) {
      try {
        const res = await fetcher(url, { signal: AbortSignal.timeout(8000) });
        if (!res.ok) throw new Error(`rates ${res.status}`);
        const body = await res.json();
        for (const cur of currencies) {
          const rate = Number(body?.rates?.[cur]);
          if (sane(cur, rate)) { usd[cur] = 1 / rate; gotAny = true; } else allOk = false;
        }
        if (url === ECB && body?.date) date = String(body.date);
      } catch {
        allOk = false;
      }
    }
    if (gotAny) cached = { date, usd };
    nextAt = now() + (allOk ? FRESH_MS : RETRY_MS);
  }

  app.get("/api/rates", async (_req, res) => {
    if (now() >= nextAt) {
      inflight ??= refresh().finally(() => (inflight = null));
      await inflight;
    }
    res.set("Cache-Control", "public, max-age=3600");
    res.json(cached);
  });
}
