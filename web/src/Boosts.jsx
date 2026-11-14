import React, { useEffect, useRef, useState } from "react";
import { Rocket, X, Check, Eye, MousePointerClick } from "lucide-react";
import { imageURL } from "./catalog";

/// Boosts (server/boosts.js): pay to promote a product or brand on Home.
const TIERS = [
  { dollars: 5, label: "Spark", what: "A lift in its aisle and search, with a badge", days: "24 hours" },
  { dollars: 20, label: "Boost", what: "A spot in Boosted picks on Home", days: "3 days" },
  { dollars: 50, label: "Big boost", what: "Boosted picks plus a lift in its aisle and search", days: "7 days" },
  { dollars: 100, label: "Spotlight", what: "A page in the Home carousel, plus everything above", days: "7 days" },
];

const visitorID = () => {
  try { return localStorage.getItem("marracat-visitor") || ""; } catch { return ""; }
};

/// Tell the server a boosted spot was seen or tapped (once a day per visitor).
export function boostEvent(target, kind) {
  const id = visitorID();
  if (!id) return;
  fetch("/api/boosts/events", { method: "POST", keepalive: true, headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ id, events: [{ target, kind }] }) }).catch(() => {});
}

// Shown once Stripe is live; only to the owner while it's in test mode.
let statusOnce = null;
const boostsEnabled = () =>
  (statusOnce ||= fetch("/api/boosts/status").then((r) => (r.ok ? r.json() : {})).then((s) => !!s.enabled).catch(() => false));

export function BoostButton({ type, id, name, autoOpen = false }) {
  const [open, setOpen] = useState(false);
  const [enabled, setEnabled] = useState(false);
  // ?boost=1: the app's Boost link lands here with the choices already open.
  useEffect(() => { boostsEnabled().then((on) => { setEnabled(on); if (on && autoOpen) setOpen(true); }); }, [autoOpen]);
  if (!enabled) return null;
  return (
    <>
      <button className="outline-button boost-button" type="button" onClick={() => setOpen(true)} data-action="boost">
        <Rocket size={18} /> Boost
      </button>
      {open && <BoostDialog type={type} id={id} name={name} onClose={() => setOpen(false)} />}
    </>
  );
}

function BoostDialog({ type, id, name, onClose }) {
  const ref = useRef(null);
  const [tier, setTier] = useState(20);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  useEffect(() => {
    const el = ref.current;
    if (el && !el.open) el.showModal();
    return () => el?.open && el.close();
  }, []);
  const pay = async () => {
    setBusy(true);
    setError("");
    try {
      const r = await fetch("/api/boosts/checkout", { method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ type, id, tier }) });
      const d = await r.json().catch(() => ({}));
      if (!r.ok || !d.url) throw Error(d.error || "Checkout couldn't start. Try again.");
      location.href = d.url;
    } catch (e) {
      setError(e.message);
      setBusy(false);
    }
  };
  return (
    <dialog ref={ref} className="auth-dialog boost-dialog" onCancel={onClose}
      onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <button className="close-dialog icon-button" aria-label="Close" onClick={onClose}><X /></button>
      <span className="eyebrow">BOOST</span>
      <h2>Put {name} in front of more shoppers</h2>
      <div className="boost-tiers" role="radiogroup" aria-label="Boost size">
        {TIERS.map((t) => (
          <button key={t.dollars} type="button" role="radio" aria-checked={tier === t.dollars}
            className={"boost-tier" + (tier === t.dollars ? " on" : "")} onClick={() => setTier(t.dollars)} data-tier={t.dollars}>
            <b>${t.dollars}</b>
            <span>{t.label} · {t.days}</span>
            <small>{t.what}</small>
          </button>
        ))}
      </div>
      <p className="small">Boosted spots are labeled “Sponsored”. Boosts for the same {type} add up while they run, so friends can boost it together. Paid securely with Stripe.</p>
      {error && <p className="claim-message" role="alert">{error}</p>}
      <button className="primary-button" type="button" disabled={busy} onClick={pay} data-action="boost-pay">
        {busy ? "Opening checkout…" : `Boost for $${tier}`}
      </button>
    </dialog>
  );
}

/// #/boosts: the confirmation after Checkout, and the shopper's own boosts.
export function BoostsPage({ signedIn, onSignIn, params }) {
  const paid = params.get("paid");
  const [done, setDone] = useState(null);
  const [mine, setMine] = useState(null);
  useEffect(() => {
    if (!paid) return;
    let tries = 0, stop = false;
    const look = () => fetch(`/api/boosts/session/${encodeURIComponent(paid)}`).then((r) => r.ok ? r.json() : null).then((d) => {
      if (stop || !d) return;
      setDone(d);
      if (d.status !== "paid" && ++tries < 10) setTimeout(look, 2000);
    }).catch(() => {});
    look();
    return () => { stop = true; };
  }, [paid]);
  useEffect(() => {
    if (signedIn) fetch("/api/boosts/mine").then((r) => r.ok ? r.json() : []).then(setMine).catch(() => setMine([]));
  }, [signedIn, done?.status]);
  const when = (ms) => new Date(ms).toLocaleDateString("en-US", { month: "short", day: "numeric" });
  return (
    <section className="info-page boosts-page">
      <span className="eyebrow">BOOSTS</span>
      <h1>Your boosts</h1>
      {params.get("canceled") && <p className="claim-message">Checkout was canceled. Nothing was charged.</p>}
      {done && (
        <div className="claim-card" data-section="boost-done">
          <h2>{done.status === "paid" ? <><Check size={20} /> {done.name} is boosted</> : "Confirming your payment…"}</h2>
          {done.status === "paid" && <p>Running until {when(done.ends)}. It shows as “Sponsored”.</p>}
        </div>
      )}
      {!signedIn ? (
        <p>
          <button className="outline-button" type="button" onClick={onSignIn}>Sign in</button> to see every boost you've made and how many people saw it.
        </p>
      ) : mine && mine.length === 0 ? (
        <p>No boosts yet. Open any product or brand and tap <b>Boost</b>.</p>
      ) : (
        <ul className="boost-list">
          {(mine || []).map((b) => (
            <li key={b.id}>
              {b.image && <img src={imageURL(b.image, 120)} alt="" />}
              <div>
                <b>{b.name}</b>
                <span>${b.tier} · {when(b.starts)} – {when(b.ends)} {b.running ? "· running" : "· ended"}</span>
                <span className="boost-stats"><Eye size={14} /> {b.views} saw it · <MousePointerClick size={14} /> {b.taps} tapped</span>
              </div>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

/// Home's "Boosted picks": every product or brand boosted $20 or more.
export function BoostedPicks({ productMap, brandMap, productHref, brandHref }) {
  const [targets, setTargets] = useState([]);
  useEffect(() => {
    fetch("/api/boosts/active").then((r) => r.ok ? r.json() : null).then((a) => a && setTargets(a.picks || [])).catch(() => {});
  }, []);
  const items = targets.map((t) => {
    const [type, id] = [t.slice(0, t.indexOf(":")), t.slice(t.indexOf(":") + 1)];
    if (type === "product") {
      const p = productMap.get(id);
      return p && { t, href: productHref(p), image: p.images?.[0], title: p.title, sub: brandMap.get(p.brand)?.name };
    }
    const b = brandMap.get(id);
    return b && { t, href: brandHref(b), image: b.image, title: b.name, sub: "Brand" };
  }).filter(Boolean);
  useEffect(() => { items.forEach((i) => boostEvent(i.t, "view")); }, [items.map((i) => i.t).join()]);
  if (!items.length) return null;
  return (
    <section className="boosted-picks" data-section="boosted-picks">
      <h2>Boosted picks</h2>
      <div className="boosted-row">
        {items.map((i) => (
          <a key={i.t} href={i.href} className="boosted-card" onClick={() => boostEvent(i.t, "tap")}>
            <span className="sponsored-label">Sponsored</span>
            <img src={imageURL(i.image, 400)} alt="" loading="lazy" />
            <b>{i.title}</b>
            <span>{i.sub}</span>
          </a>
        ))}
      </div>
    </section>
  );
}
