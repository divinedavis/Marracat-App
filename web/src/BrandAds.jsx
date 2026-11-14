import React, { useEffect, useMemo, useState } from "react";
import { Megaphone, CreditCard, Pause, Play } from "lucide-react";
import BoostBudget from "./BoostBudget.jsx";

/// "Brand ads": a verified brand promotes its own products, paying per tap
/// (server/sponsored.js; owner, 2026-10-06). Budgets and the card live here
/// on the website; the app shows the stats and can pause or resume.
export default function BrandAds({ params, products, money, signedIn, onSignIn, toast }) {
  const [brands, setBrands] = useState(null);
  const [brandID, setBrandID] = useState(params.get("brand") || "");
  const [picked, setPicked] = useState([]);
  const [budget, setBudget] = useState("10");
  const [cpc, setCPC] = useState("0.50");
  const [busy, setBusy] = useState(false);
  // The owner's review queue (server/sponsored.js /admin): campaigns wait
  // for approval before they show. 403 for everyone else, so it stays empty.
  const [queue, setQueue] = useState([]);
  const loadQueue = () => fetch("/api/ads/admin/campaigns").then((r) => (r.ok ? r.json() : { campaigns: [] })).then((d) => setQueue(d.campaigns || [])).catch(() => {});
  useEffect(() => { if (signedIn) loadQueue(); }, [signedIn]);
  const review = (brand, approve) => fetch("/api/ads/admin/approve", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ brand, approve }) })
    .then((r) => { toast(r.ok ? (approve ? "Approved" : "Rejected") : "Couldn't save"); loadQueue(); });
  const reviewQueue = queue.length > 0 && (
    <div className="claim-card" data-section="ads-review">
      <h2>Campaigns to review</h2>
      {queue.map((q) => (
        <div key={q.brand.id} className="ads-review-row">
          <strong>{q.brand.name}</strong> · {q.campaign.productIDs.length} products · {money(q.campaign.dailyBudget)}/day · up to {money(q.campaign.maxCPC)}/tap · {q.campaign.approval}
          {q.campaign.approval !== "approved" && <button className="outline-button" type="button" onClick={() => review(q.brand.id, true)} data-action="ads-approve">Approve</button>}
          {q.campaign.approval !== "rejected" && <button className="outline-button" type="button" onClick={() => review(q.brand.id, false)} data-action="ads-reject">Reject</button>}
        </div>
      ))}
    </div>
  );

  const load = () => fetch("/api/ads/brands").then((r) => (r.ok ? r.json() : { brands: [] })).then((d) => setBrands(d.brands || [])).catch(() => setBrands([]));
  useEffect(() => { if (signedIn) load(); }, [signedIn]);
  const mine = brands?.find((b) => b.brand.id === brandID) || brands?.[0];
  useEffect(() => {
    if (!mine) return;
    setBrandID(mine.brand.id);
    if (mine.campaign) { setPicked(mine.campaign.productIDs); setBudget(String(mine.campaign.dailyBudget)); setCPC(mine.campaign.maxCPC.toFixed(2)); }
  }, [mine?.brand.id, brands]);
  // Back from Stripe with a saved card.
  useEffect(() => {
    const session = params.get("setup");
    if (!signedIn || !session || !brandID) return;
    call("/api/ads/billing/confirm", "POST", { brand: brandID, session }).then((d) => d && toast("Card saved"));
  }, [signedIn, brandID]);

  const own = useMemo(() => products.filter((p) => p.brand === brandID && p.available), [products, brandID]);
  const call = async (url, method, body) => {
    setBusy(true);
    try {
      const r = await fetch(url, { method, headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
      const d = await r.json().catch(() => ({}));
      if (!r.ok) throw Error(d.error || "Something went wrong.");
      if (d.brand) setBrands((bs) => bs.map((b) => (b.brand.id === d.brand.id ? d : b)));
      return d;
    } catch (e) { toast(e.message); return null; } finally { setBusy(false); }
  };

  if (!signedIn) return (
    <section className="info-page brand-ads"><h1>Brand ads</h1><p>Sign in with the account you verified your brand with.</p>
      <button className="primary-button" type="button" onClick={onSignIn}>Sign in</button></section>);
  if (brands === null) return <section className="info-page brand-ads"><p>Loading…</p></section>;
  if (!brands.length) return (
    <section className="info-page brand-ads"><h1>Brand ads</h1>{reviewQueue}
      <p>First confirm you're part of your brand's team. We'll email a one-time link to an address at your brand's own domain.</p>
      <a className="primary-button" href="/for-brands">Verify your brand</a></section>);

  const c = mine.campaign, s = mine.stats;
  return (
    <section className="info-page brand-ads">
      <span className="eyebrow">BRAND ADS</span>
      <h1><Megaphone size={26} /> Promote {mine.brand.name}</h1>
      <p>Your products appear at the top of matching searches, in their aisle and beside similar products, labeled Sponsored. You pay only when a shopper taps, never more than your limit, and never past your daily budget.</p>
      {mine.test && <p className="small">Payments are in test mode: ads show only to Marracat's team and no real card is charged.</p>}
      {reviewQueue}
      {c?.approval === "pending" && <p className="small" data-field="ads-approval">Waiting for Marracat to review your ads. They start once approved; changing the products sends them back for review.</p>}
      {c?.approval === "rejected" && <p className="error-message" data-field="ads-approval">Marracat didn't approve these ads. Change the products and save to ask again.</p>}
      {brands.length > 1 && (
        <select value={brandID} onChange={(e) => setBrandID(e.target.value)} aria-label="Brand">
          {brands.map((b) => <option key={b.brand.id} value={b.brand.id}>{b.brand.name}</option>)}
        </select>
      )}
      <div className="ads-stats">
        <div><strong>{s.views}</strong><span>views (7 days)</span></div>
        <div><strong>{s.taps}</strong><span>taps (7 days)</span></div>
        <div><strong>{money(s.spentCents / 100)}</strong><span>spent (7 days)</span></div>
        <div><strong>{money(s.todayCents / 100)}</strong><span>today</span></div>
      </div>

      <div className="claim-card">
        <h2>Products to promote</h2>
        <div className="ads-products">
          {own.map((p) => (
            <label key={p.id} className="ads-product">
              <input type="checkbox" checked={picked.includes(p.id)} onChange={(e) => setPicked((x) => (e.target.checked ? [...x, p.id] : x.filter((i) => i !== p.id)).slice(0, 50))} />
              <span>{p.title}</span>
            </label>
          ))}
        </div>
        <div className="ads-fields">
          <label className="buyer-field"><span>Daily budget ($5–$500)</span>
            <input type="number" min="5" max="500" step="1" value={budget} onChange={(e) => setBudget(e.target.value)} data-field="ads-budget" /></label>
          <label className="buyer-field"><span>Most per tap ($0.20–$5)</span>
            <input type="number" min="0.2" max="5" step="0.05" value={cpc} onChange={(e) => setCPC(e.target.value)} data-field="ads-cpc" /></label>
        </div>
        <button className="primary-button" type="button" disabled={busy || !picked.length}
          onClick={() => call("/api/ads/campaign", "PUT", { brand: brandID, productIDs: picked, dailyBudget: Number(budget), maxCPC: Number(cpc) }).then((d) => d && toast("Saved"))}
          data-action="ads-save">{c ? "Save changes" : "Start promoting"}</button>
        {c && (
          <button className="outline-button" type="button" disabled={busy}
            onClick={() => call("/api/ads/campaign/status", "POST", { brand: brandID, status: c.status === "active" ? "paused" : "active" })}
            data-action="ads-toggle">{c.status === "active" ? <><Pause size={16} /> Pause</> : <><Play size={16} /> Resume</>}</button>
        )}
      </div>

      <BoostBudget brandID={brandID} products={own} money={money} toast={toast} params={params} />

      <div className="claim-card">
        <h2><CreditCard size={20} /> Payment</h2>
        {mine.cardProblem && <p className="error-message">Your last charge didn't go through ({mine.cardProblem}). Ads are paused until you add a card.</p>}
        <p>{mine.card ? `Taps are charged to ${mine.card} once $25 is owed, or weekly.` : "Add a card to start. Nothing is charged until shoppers tap."}{s.owedCents ? ` Owed now: ${money(s.owedCents / 100)}.` : ""}</p>
        <button className="outline-button" type="button" disabled={busy}
          onClick={() => call("/api/ads/billing/setup", "POST", { brand: brandID }).then((d) => d?.url && (location.href = d.url))}
          data-action="ads-card">{mine.card ? "Change card" : "Add a card"}</button>
      </div>
    </section>
  );
}
