import React, { useEffect, useState } from "react";
import { BellRing, Bell } from "lucide-react";
import { track } from "./events";

/// "Track price" (product) and "Sale alerts" (brand): price-drop and
/// brand-sale alerts by email, and push on any phone signed in to the app
/// (server/deal-alerts.js; owner, 2026-10-04).
let mineOnce = null;
const loadMine = () => (mineOnce ||= fetch("/api/alerts").then((r) => (r.ok ? r.json() : null)).catch(() => null));

export function AlertButton({ kind, id, signedIn, onSignIn, toast, className = "outline-button" }) {
  const [on, setOn] = useState(false);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    if (!signedIn) return;
    loadMine().then((m) => m && setOn(kind === "price" ? m.prices.some((p) => p.productID === id) : m.brands.some((b) => b.brandID === id)));
  }, [signedIn, id, kind]);
  const toggle = async () => {
    if (!signedIn) return onSignIn();
    setBusy(true);
    const body = JSON.stringify(kind === "price" ? { productID: id } : { brandID: id });
    const r = await fetch(`/api/alerts/${kind}`, { method: on ? "DELETE" : "POST", headers: { "Content-Type": "application/json" }, body }).catch(() => null);
    setBusy(false);
    if (!r?.ok) return toast("Couldn't change that alert. Try again.");
    mineOnce = null;
    setOn(!on);
    // Price alerts track a product; a brand's sale alerts are how the website follows a brand.
    if (kind === "price") track(on ? "alert_off" : "alert_on", { kind: "price", product: id });
    else {
      track(on ? "alert_off" : "alert_on", { kind: "brand_sale", brand: id });
      track(on ? "brand_unfollow" : "brand_follow", { brand: id });
    }
    toast(on ? "Alert off" : kind === "price" ? "We'll email you if the price drops" : "We'll email you when this brand has a sale");
  };
  const label = kind === "price" ? (on ? "Tracking price" : "Track price") : (on ? "Sale alerts on" : "Sale alerts");
  return (
    <button className={className} type="button" disabled={busy} onClick={toggle} data-action={`alert-${kind}`} aria-pressed={on}>
      {on ? <BellRing size={16} /> : <Bell size={16} />} {label}
    </button>
  );
}
