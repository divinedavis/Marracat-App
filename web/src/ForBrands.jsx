import React, { useEffect, useMemo, useState } from "react";
import { ShieldCheck, Mail, Megaphone } from "lucide-react";

/// "For brands": a brand's team proves they manage it before booking
/// promotions (server/brand-claims.js): a one-time link to an address at the
/// brand's own domain (the only way since 2026-10-06).
export default function ForBrands({ brands, signedIn, onSignIn, claimState }) {
  const [mine, setMine] = useState({ brands: [], claims: [] });
  const [query, setQuery] = useState("");
  const [brandID, setBrandID] = useState("");
  const [email, setEmail] = useState("");
  const [message, setMessage] = useState(
    claimState === "verified" ? "Confirmed. You now manage this brand on Marracat."
      : claimState === "expired" ? "That link expired. Send a new one below."
      : claimState === "used" ? "That link was already used or isn't valid."
      : claimState === "signin" ? "Sign in with the account that asked, then open the link again."
      : claimState === "account" ? "That link belongs to a different Marracat account. Sign in with the one that asked." : "",
  );
  const [busy, setBusy] = useState(false);

  const byID = useMemo(() => new Map(brands.map((b) => [b.id, b])), [brands]);
  const brand = byID.get(brandID);
  const matches = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (q.length < 2) return [];
    return brands.filter((b) => b.name.toLowerCase().includes(q)).slice(0, 8);
  }, [brands, query]);

  const load = () =>
    fetch("/api/brand-claims/me").then((r) => (r.ok ? r.json() : null)).then((d) => d && setMine(d)).catch(() => {});
  useEffect(() => { if (signedIn) load(); }, [signedIn]);

  const call = async (url, body) => {
    setBusy(true);
    setMessage("");
    try {
      const r = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body || {}) });
      const d = await r.json().catch(() => ({}));
      if (!r.ok) throw Error(d.error || "Something went wrong. Try again.");
      return d;
    } catch (e) {
      setMessage(e.message);
      return null;
    } finally {
      setBusy(false);
    }
  };

  const sendLink = async () => {
    const d = await call("/api/brand-claims/email", { brand: brandID, email });
    if (d) setMessage(`We sent a link to ${d.email}. It works for 30 minutes.`);
  };

  return (
    <section className="info-page for-brands">
      <span className="eyebrow">FOR BRANDS</span>
      <h1>Manage your brand on Marracat</h1>
      <p>Confirm you're part of a brand's team to promote it on Marracat. It takes about two minutes.</p>
      {message && <p className="claim-message" role="status">{message}</p>}
      {!signedIn ? (
        <button className="primary-button" type="button" onClick={onSignIn}>Sign in to continue</button>
      ) : (
        <>
          {mine.brands.length > 0 && (
            <div className="claim-card">
              <h2><ShieldCheck size={20} /> Brands you manage</h2>
              <ul>{mine.brands.map((b) => <li key={b.brand}>{byID.get(b.brand)?.name || b.brand} · {b.role} · <a href={`/brand-ads?brand=${encodeURIComponent(b.brand)}`} data-action="brand-ads"><Megaphone size={14} /> Brand ads</a></li>)}</ul>
            </div>
          )}
          <label className="buyer-field">
            <span>Your brand</span>
            <input value={brand ? brand.name : query} placeholder="Start typing your brand's name"
              onChange={(e) => { setBrandID(""); setQuery(e.target.value); }} data-field="claim-brand" />
          </label>
          {!brand && matches.length > 0 && (
            <ul className="address-suggestions claim-brands">
              {matches.map((b) => (
                <li key={b.id} onMouseDown={(e) => { e.preventDefault(); setBrandID(b.id); setQuery(b.name); }} data-action="claim-pick">
                  <b>{b.name}</b><span>{b.domain}</span>
                </li>
              ))}
            </ul>
          )}
          {brand && (
            <div className="claim-options">
              <div className="claim-card">
                <h2><Mail size={20} /> Use your work email</h2>
                <p>We'll email a one-time link to an address at <b>@{brand.domain.replace(/^www\./, "")}</b>. Opening it confirms you're on the team.</p>
                <label className="buyer-field">
                  <span>Work email</span>
                  <input type="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder={`you@${brand.domain.replace(/^www\./, "")}`} data-field="claim-email" />
                </label>
                <button className="outline-button" type="button" disabled={busy || !email} onClick={sendLink} data-action="claim-email">Email me a link</button>
              </div>
            </div>
          )}
        </>
      )}
    </section>
  );
}
