import { useSyncExternalStore } from "react";
import { money } from "./catalog";

// Dollar rates for £ and € prices, from /api/rates (ECB, refreshed twice a
// day). Until they arrive, approximate dollar figures are simply left out.
// The last rates are kept in localStorage, so a returning visitor's prices
// come up in dollars straight away instead of flicking over when they arrive.
const RATES_KEY = "marracat-rates";
const stored = (key) => {
  try {
    return JSON.parse(localStorage.getItem(key));
  } catch {
    return null;
  }
};
let rates = stored(RATES_KEY)?.usd || null;
const listeners = new Set();
let started = false;
function start() {
  if (started) return;
  started = true;
  fetch("/api/rates")
    .then((r) => (r.ok ? r.json() : null))
    .then((body) => {
      if (body?.usd) {
        rates = body.usd;
        try {
          localStorage.setItem(RATES_KEY, JSON.stringify(body));
        } catch {}
        listeners.forEach((l) => l());
      }
    })
    .catch(() => {});
}
export function useRates() {
  return useSyncExternalStore(
    (l) => {
      start();
      listeners.add(l);
      return () => listeners.delete(l);
    },
    () => rates,
    () => null,
  );
}
export const toUSD = (amount, currency, r) =>
  currency === "USD" || !currency ? amount : r?.[currency] ? amount * r[currency] : null;

// Where a brand charging in another currency ships from, for the product page.
const SHIPS_FROM = { GBP: "the UK", EUR: "Europe", SEK: "Sweden", ZAR: "South Africa", NGN: "Nigeria", KES: "Kenya", GHS: "Ghana" };
export const shipsFrom = (currency) => SHIPS_FROM[currency] || null;

// The currency prices are shown in: US dollars unless the visitor picks
// another one, or ORIGINAL for each brand's own currency (owner, 2026-11-08:
// "instead of another currency being the leading price, it should be in usd
// by default"). Brands still charge in their own currency at checkout, so a
// converted price keeps the real one beside it.
export const ORIGINAL = "ORIGINAL";
const CURRENCY_KEY = "marracat-currency";
let currency = (() => {
  try {
    return localStorage.getItem(CURRENCY_KEY) || "USD";
  } catch {
    return "USD";
  }
})();
const currencyListeners = new Set();
export function setCurrency(next) {
  currency = next || "USD";
  try {
    if (currency === "USD") localStorage.removeItem(CURRENCY_KEY);
    else localStorage.setItem(CURRENCY_KEY, currency);
  } catch {}
  currencyListeners.forEach((l) => l());
}
export function useCurrency() {
  return useSyncExternalStore(
    (l) => {
      currencyListeners.add(l);
      return () => currencyListeners.delete(l);
    },
    () => currency,
    () => "USD",
  );
}
// amount in `from` -> `to`, through dollars; null while a rate is missing.
export function convert(amount, from, to, r) {
  from = from || "USD";
  if (from === to) return amount;
  const usd = toUSD(amount, from, r);
  if (usd == null) return null;
  if (to === "USD") return usd;
  return r?.[to] ? usd / r[to] : null;
}
// The currencies a visitor can pick: dollars, each brand's own, and every
// currency a brand charges in (the ones /api/rates knows).
export function currencyChoices(r) {
  const names = typeof Intl.DisplayNames === "function" ? new Intl.DisplayNames(["en"], { type: "currency" }) : null;
  const name = (c) => names?.of(c) || c;
  return [
    ["USD", `USD · ${name("USD")}`],
    ...Object.keys(r || {}).sort().map((c) => [c, `${c} · ${name(c)}`]),
    [ORIGINAL, "Each brand's own currency"],
  ];
}

// "$23.92 (£18.00)" for a brand that charges in £ or €: the visitor's
// currency first, the real price beside it. With ORIGINAL it is the brand's
// "£18.00 (≈ $23.92)" as before. Until rates arrive, the real price alone.
export function Price({ value, currency: from }) {
  const r = useRates();
  const shown = useCurrency();
  from = from || "USD";
  if (shown === ORIGINAL) {
    const usd = from !== "USD" ? toUSD(value, from, r) : null;
    return (
      <>
        {money(value, from)}
        {usd != null && <>{" "}<span className="fx-approx">(≈ {money(usd)})</span></>}
      </>
    );
  }
  const converted = from === shown ? null : convert(value, from, shown, r);
  if (converted == null) return money(value, from);
  return (
    <>
      {money(converted, shown)}
      {" "}
      <span className="fx-approx">({money(value, from)})</span>
    </>
  );
}

// An amount alone in the visitor's currency, for a struck-through "was"
// price beside <Price>: no second figure, so the pair reads as one currency.
export function Money({ value, currency: from }) {
  const r = useRates();
  const shown = useCurrency();
  from = from || "USD";
  if (shown === ORIGINAL || shown === from) return money(value, from);
  const converted = convert(value, from, shown, r);
  return converted == null ? money(value, from) : money(converted, shown);
}

// A cart's total. One currency reads as before. Mixed £/€/$ reads as one
// approximate dollar figure, with the real amounts beneath it.
export function totalsByCurrency(entries) {
  const totals = new Map();
  for (const [currency, amount] of entries)
    totals.set(currency || "USD", (totals.get(currency || "USD") || 0) + amount);
  return [...totals].sort(([a], [b]) => a.localeCompare(b));
}
export function MixedTotal({ totals, compact = false }) {
  const r = useRates();
  if (!totals.length) return money(0);
  const exact = totals.map(([c, a]) => money(a, c)).join(" + ");
  if (totals.length === 1 && totals[0][0] === "USD") return exact;
  const usd = totals.reduce((sum, [c, a]) => (sum == null ? null : toUSD(a, c, r) == null ? null : sum + toUSD(a, c, r)), 0);
  if (usd == null) return exact;
  if (compact) return `≈ ${money(usd)}`;
  return (
    <span className="fx-total">
      ≈ {money(usd)}
      <small>{exact}, charged by each brand in its own currency</small>
    </span>
  );
}
