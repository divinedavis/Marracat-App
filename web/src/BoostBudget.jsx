import React, { useEffect, useState } from "react";
import { CalendarClock, Rocket } from "lucide-react";

/// "Monthly boost budget" on the Brand ads page (server/boost-budgets.js;
/// owner, 2026-10-10: brands set a recurring budget). The brand picks what to
/// promote, which boost and how much a month; Marracat runs that boost
/// back-to-back until the month's money is used. Amounts are checked again on
/// the server; this page only shows the ranges.
export default function BoostBudget({ brandID, products, money, toast, params }) {
  const [options, setOptions] = useState([]);
  const [plan, setPlan] = useState(undefined);
  const [tier, setTier] = useState(100);
  const [dollars, setDollars] = useState("400");
  const [what, setWhat] = useState("brand");
  const [busy, setBusy] = useState(false);

  const option = options.find((o) => o.tier === Number(tier));
  const load = () =>
    fetch(`/api/boost-budgets?brand=${encodeURIComponent(brandID)}`)
      .then((r) => (r.ok ? r.json() : { plan: null, unavailable: r.status === 503 }))
      .then((d) => setPlan(d.unavailable ? false : d.plan))
      .catch(() => setPlan(false));
  useEffect(() => {
    fetch("/api/boost-budgets/options").then((r) => r.json()).then(setOptions).catch(() => {});
  }, []);
  useEffect(() => { if (brandID) load(); }, [brandID]);
  // Back from Stripe Checkout: confirm the subscription straight away.
  useEffect(() => {
    const sid = params.get("budget");
    if (!sid || !brandID) return;
    fetch(`/api/boost-budgets/session/${encodeURIComponent(sid)}`).then((r) => (r.ok ? r.json() : null))
      .then((d) => { if (d?.plan) { setPlan(d.plan); toast("Monthly budget started"); } }).catch(() => {});
  }, [brandID]);
  useEffect(() => {
    if (plan) { setTier(plan.tier); setDollars(String(plan.monthly)); }
  }, [plan?.id]);

  const post = async (url, body) => {
    setBusy(true);
    try {
      const r = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
      const d = await r.json().catch(() => ({}));
      if (!r.ok) throw Error(d.error || "Something went wrong.");
      return d;
    } catch (e) { toast(e.message); return null; } finally { setBusy(false); }
  };

  if (plan === undefined) return null;
  if (plan === false) return null; // payments not available to this account yet
  const running = plan && plan.status !== "canceled";
  const [type, id] = what === "brand" ? ["brand", brandID] : ["product", what];
  const weeks = option ? Math.floor((Number(dollars) || 0) / option.tier) * option.days : 0;

  return (
    <div className="claim-card boost-budget" data-section="boost-budget">
      <h2><CalendarClock size={20} /> Monthly boost budget</h2>
      <p>Set what to spend each month and Marracat keeps your boost running until it's used, labeled Sponsored. Billed monthly; cancel anytime and what you've paid still runs.</p>
      {plan?.test && <p className="small">Test mode: nothing real is charged and these boosts show only to Marracat's team.</p>}
      {running && (
        <div className="ads-stats" data-field="budget-stats">
          <div><strong>{money(plan.monthly)}</strong><span>a month · {plan.label}</span></div>
          <div><strong>{money(plan.left)}</strong><span>left to spend</span></div>
          <div><strong>{plan.views}</strong><span>views (30 days)</span></div>
          <div><strong>{plan.taps}</strong><span>taps (30 days)</span></div>
        </div>
      )}
      {running && (
        <p className="small" data-field="budget-status">
          {plan.status === "past_due" ? "Your last payment didn't go through, so boosts are paused. Update your card below."
            : plan.status === "pending" ? "Waiting for Stripe to confirm the first payment."
            : `${plan.running ? `Running now until ${new Date(plan.running.ends).toLocaleDateString()}. ` : ""}${plan.nextCharge ? `Next charge ${new Date(plan.nextCharge).toLocaleDateString()}.` : ""} Spent so far: ${money(plan.spent)} of ${money(plan.paid)} paid.`}
        </p>
      )}
      {!running && (
        <label className="buyer-field"><span>Promote</span>
          <select value={what} onChange={(e) => setWhat(e.target.value)} data-field="budget-target">
            <option value="brand">Your brand page</option>
            {products.slice(0, 200).map((p) => <option key={p.id} value={p.id}>{p.title}</option>)}
          </select>
        </label>
      )}
      <div className="ads-fields">
        <label className="buyer-field"><span>Boost</span>
          <select value={tier} onChange={(e) => { setTier(Number(e.target.value)); const o = options.find((x) => x.tier === Number(e.target.value)); if (o && (Number(dollars) > o.max || Number(dollars) < o.min)) setDollars(String(Math.min(o.max, Math.max(o.min, Number(dollars) || o.min)))); }} data-field="budget-tier">
            {options.map((o) => <option key={o.tier} value={o.tier}>{o.label}: ${o.tier} for {o.days === 1 ? "24 hours" : `${o.days} days`}</option>)}
          </select>
        </label>
        <label className="buyer-field"><span>Monthly budget{option ? ` ($${option.min}–$${option.max})` : ""}</span>
          <input type="number" min={option?.min} max={option?.max} step="1" value={dollars} onChange={(e) => setDollars(e.target.value)} data-field="budget-dollars" />
        </label>
      </div>
      {option && <p className="small" data-field="budget-estimate">About {weeks} day{weeks === 1 ? "" : "s"} of {option.label} a month.</p>}
      {!running ? (
        <button className="primary-button" type="button" disabled={busy}
          onClick={() => post("/api/boost-budgets/checkout", { brand: brandID, type, id, tier: Number(tier), dollars: Number(dollars) }).then((d) => d?.url && (location.href = d.url))}
          data-action="budget-start"><Rocket size={16} /> Start monthly budget</button>
      ) : (
        <>
          <button className="primary-button" type="button" disabled={busy}
            onClick={() => post("/api/boost-budgets/change", { brand: brandID, tier: Number(tier), dollars: Number(dollars) }).then((d) => { if (d?.plan) { setPlan(d.plan); toast("Changes start next month"); } })}
            data-action="budget-change">Save for next month</button>
          <button className="outline-button" type="button" disabled={busy}
            onClick={() => post("/api/boost-budgets/portal", { brand: brandID }).then((d) => d?.url && (location.href = d.url))}
            data-action="budget-portal">Card, invoices or cancel</button>
        </>
      )}
    </div>
  );
}
