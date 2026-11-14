import { MixedTotal, Price } from "./fx";
import React, { useEffect, useRef, useState } from "react";
import { Store, ShieldCheck, ExternalLink, X, CheckCircle2, ArrowRight } from "lucide-react";
import { money, imageURL, checkoutURL, safeURL } from "./catalog";
import { buyerFromAccount } from "./buyer";
import { suggest, resolveSuggestion } from "./addressSearch";

export const emptyBuyer = {
  firstName: "", lastName: "", email: "", phone: "",
  street: "", extended: "", city: "", region: "", postalCode: "", country: "US",
};
export const buyerComplete = (b) =>
  !!b &&
  ["firstName", "lastName", "street", "city", "region", "postalCode", "phone"].every((k) => String(b[k] || "").trim()) &&
  /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(b.email || "");

/// The one form: name, contact and shipping address, kept in this browser.
export function BuyerForm({ buyer, account, onSave, onClose }) {
  const [d, setD] = useState(() => {
    const start = { ...emptyBuyer, ...(buyer || {}) };
    const known = buyerFromAccount(account);
    for (const k of Object.keys(known)) if (!String(start[k] || "").trim()) start[k] = known[k];
    return start;
  });
  const ref = useRef(null);
  // Apple Maps suggestions while the street is typed (addressSearch.js).
  const [found, setFound] = useState([]);
  const [active, setActive] = useState(-1);
  const asked = useRef(0);
  const typeStreet = (value) => {
    setD((cur) => ({ ...cur, street: value }));
    const n = ++asked.current;
    setTimeout(async () => {
      if (n !== asked.current) return; // a newer keystroke owns the list
      const list = await suggest(value);
      if (n === asked.current) {
        setFound(list);
        setActive(-1);
      }
    }, 180);
  };
  const pick = async (s) => {
    asked.current++;
    setFound([]);
    const a = await resolveSuggestion(s);
    if (!a) return;
    setD((cur) => ({
      ...cur,
      street: a.street || cur.street,
      city: a.city || cur.city,
      region: a.region || cur.region,
      postalCode: a.postalCode || cur.postalCode,
    }));
    ref.current?.querySelector('[data-field="extended"]')?.focus();
  };
  useEffect(() => {
    const el = ref.current;
    if (el && !el.open) el.showModal();
    return () => el?.open && el.close();
  }, []);
  const field = (key, label, extra = {}) => (
    <label className="buyer-field">
      <span>{label}</span>
      <input
        value={d[key]}
        onChange={(e) => setD({ ...d, [key]: e.target.value })}
        name={key}
        data-field={key}
        {...extra}
      />
    </label>
  );
  return (
    <dialog
      ref={ref}
      className="auth-dialog buyer-dialog"
      onCancel={onClose}
      onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}
    >
      <button className="close-dialog icon-button" aria-label="Close" onClick={onClose}>
        <X />
      </button>
      <span className="eyebrow">ONCE, FOR EVERY BRAND</span>
      <h2>Your details</h2>
      <form
        className="buyer-form"
        onSubmit={(e) => {
          e.preventDefault();
          if (buyerComplete(d)) onSave(d);
        }}
      >
        <div className="buyer-grid">
          {field("firstName", "First name", { autoComplete: "given-name", required: true })}
          {field("lastName", "Last name", { autoComplete: "family-name", required: true })}
        </div>
        {field("email", "Email", { type: "email", autoComplete: "email", required: true })}
        {field("phone", "Phone", { type: "tel", autoComplete: "tel", required: true })}
        <div className="address-field">
          {field("street", "Street address", {
            autoComplete: "address-line1",
            required: true,
            onChange: (e) => typeStreet(e.target.value),
            onBlur: () => setTimeout(() => setFound([]), 150),
            onKeyDown: (e) => {
              if (!found.length) return;
              if (e.key === "ArrowDown") { e.preventDefault(); setActive((i) => Math.min(found.length - 1, i + 1)); }
              else if (e.key === "ArrowUp") { e.preventDefault(); setActive((i) => Math.max(-1, i - 1)); }
              else if (e.key === "Enter" && active >= 0) { e.preventDefault(); pick(found[active]); }
              else if (e.key === "Escape") setFound([]);
            },
            role: "combobox",
            "aria-expanded": found.length > 0,
            "aria-controls": "address-suggestions",
          })}
          {found.length > 0 && (
            <ul className="address-suggestions" id="address-suggestions" role="listbox">
              {found.map((s, i) => (
                <li
                  key={s.label + s.sub + i}
                  role="option"
                  aria-selected={i === active}
                  className={i === active ? "active" : undefined}
                  data-action="address-suggestion"
                  onMouseDown={(e) => { e.preventDefault(); pick(s); }}
                >
                  <b>{s.label}</b>
                  {s.sub && <span>{s.sub}</span>}
                </li>
              ))}
            </ul>
          )}
        </div>
        {field("extended", "Apt, suite (optional)", { autoComplete: "address-line2" })}
        <div className="buyer-grid">
          {field("city", "City", { autoComplete: "address-level2", required: true })}
          {field("region", "State", { autoComplete: "address-level1", required: true })}
          {field("postalCode", "ZIP", { autoComplete: "postal-code", required: true })}
        </div>
        <p className="small">
          United States. Saved in this browser only; each brand's store receives it when its checkout is built,
          as it would from its own form.
        </p>
        {/* Never greyed out: a tap on an unfinished form lets the browser point
            at the field that's missing, instead of a dead button (2026-09-30). */}
        <button className="primary-button" type="submit" data-action="save-buyer">
          Save and continue <ArrowRight size={17} />
        </button>
      </form>
    </dialog>
  );
}

/// One review for a cart with several brands: every brand's store builds its
/// checkout from the saved details and reports real shipping and totals, and
/// each brand is paid on its own checkout page, already filled in.
export function CheckoutReview({ groups, buyer, onEditBuyer, onPaid, shopHref }) {
  const [outcomes, setOutcomes] = useState({});
  const [opened, setOpened] = useState({});
  const key = groups.map((g) => g.brand.id + ":" + g.lines.map((l) => l.variant?.id + "x" + l.quantity).join(",")).join("|")
    + "|" + JSON.stringify(buyer);
  useEffect(() => {
    if (!buyerComplete(buyer)) return;
    const controller = new AbortController();
    setOutcomes((o) => Object.fromEntries(groups.map((g) => [g.brand.id, o[g.brand.id]?.kind === "ready" && o[g.brand.id].key === key ? o[g.brand.id] : { kind: "loading" }])));
    for (const g of groups) {
      fetch("/api/checkout/build", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        signal: controller.signal,
        body: JSON.stringify({
          brand: g.brand.id,
          lines: g.lines.map((l) => ({ variant: String(l.variant?.id), quantity: l.quantity })),
          buyer,
        }),
      })
        .then(async (r) => {
          const body = await r.json().catch(() => ({}));
          if (!r.ok) throw Error(body.error || "Couldn't build this checkout");
          return body;
        })
        .then((c) => setOutcomes((o) => ({ ...o, [g.brand.id]: { kind: "ready", key, checkout: c } })))
        .catch((e) => {
          if (controller.signal.aborted) return;
          setOutcomes((o) => ({ ...o, [g.brand.id]: { kind: "failed", reason: e.message } }));
        });
    }
    return () => controller.abort();
  }, [key]);
  const totals = new Map();
  let pending = 0;
  for (const g of groups) {
    const o = outcomes[g.brand.id];
    if (o?.kind === "ready" && o.checkout.total != null) {
      const cur = o.checkout.currency || g.brand.currency || "USD";
      totals.set(cur, (totals.get(cur) || 0) + o.checkout.total);
    } else if (o?.kind !== "failed") pending++;
  }
  const grandTotals = [...totals].sort(([a], [b]) => a.localeCompare(b)).map(([cur, minor]) => [cur, minor / 100]);
  return (
    <>
      <section className="page-title">
        <span className="eyebrow">ONE CHECKOUT, EVERY BRAND</span>
        <h1>Review your order</h1>
        <p>
          {groups.length > 1
            ? "Shipping included. Each brand is paid on its own checkout — one click each with Shop Pay, Apple Pay or a card."
            : "Shipping included. You'll pay on the brand's own checkout, already filled in."}
        </p>
      </section>
      {groups.length ? (
        <div className="cart-layout">
          <div>
            <section className="cart-group buyer-card" data-section="buyer">
              <h2><ShieldCheck size={21} /> Ship to</h2>
              {buyer ? (
                <p>
                  <b>{buyer.firstName} {buyer.lastName}</b>
                  <br />
                  {buyer.street}{buyer.extended ? `, ${buyer.extended}` : ""}, {buyer.city}, {buyer.region} {buyer.postalCode}
                  <br />
                  {buyer.email} · {buyer.phone}
                </p>
              ) : (
                <p>Add your details to build the checkout.</p>
              )}
              <button className="outline-button" type="button" onClick={onEditBuyer} data-action="edit-buyer">
                {buyer ? "Edit" : "Add"} details
              </button>
            </section>
            {groups.map((g) => {
              const o = outcomes[g.brand.id] || { kind: "loading" };
              const c = o.checkout;
              const cur = c?.currency || g.brand.currency || "USD";
              const fallback = checkoutURL(g.brand, g.lines);
              const payHref = o.kind === "ready" ? c.continueUrl || fallback : fallback;
              return (
                <section className="cart-group review-brand" key={g.brand.id} data-brand={g.brand.id}>
                  <h2>
                    <Store size={21} />
                    {g.brand.name}
                    {o.kind === "ready" && c.total != null && <b className="review-total"><Price value={c.total / 100} currency={cur} /></b>}
                  </h2>
                  {g.lines.map((l) => (
                    <div className="review-line" key={l.key}>
                      <img src={imageURL(l.product?.images?.[0], 120)} alt="" />
                      <span>{l.product?.title}</span>
                      <small>× {l.quantity}</small>
                    </div>
                  ))}
                  {o.kind === "loading" && <p className="small">Getting shipping and total from {g.brand.name}…</p>}
                  {o.kind === "ready" && c.shippingOption && (
                    <p className="small">
                      {c.shippingOption} · {money((c.shipping || 0) / 100, cur)}
                    </p>
                  )}
                  {o.kind === "ready" && c.needsAttention && c.messages[0]?.content && (
                    <p className="error-message">{c.messages[0].content}</p>
                  )}
                  {o.kind === "failed" && <p className="error-message">{o.reason}</p>}
                  {opened[g.brand.id] ? (
                    <div className="review-actions">
                      <a className="outline-button" href={payHref} target="_blank" rel="noopener noreferrer"
                        data-track-brand={g.brand.id} data-track-via="checkout">
                        Open again <ExternalLink size={16} />
                      </a>
                      <button className="primary-button" type="button" onClick={() => onPaid(g.brand.id)} data-action="paid">
                        <CheckCircle2 size={17} /> Paid — remove from cart
                      </button>
                    </div>
                  ) : payHref && o.kind !== "loading" ? (
                    <a
                      className="primary-button"
                      href={payHref}
                      target="_blank"
                      rel="noopener noreferrer"
                      data-action="pay"
                      data-track-brand={g.brand.id}
                      data-track-via={o.kind === "ready" && c.continueUrl ? "checkout" : g.brand.platform === "bigcartel" || g.brand.platform === "swell" ? g.brand.platform : "cart"}
                      onClick={() => setOpened((s) => ({ ...s, [g.brand.id]: true }))}
                    >
                      {o.kind === "ready" && !c.needsAttention && c.total != null
                        ? `Pay ${g.brand.name} · ${money(c.total / 100, cur)}`
                        : o.kind === "ready"
                          ? `Finish at ${g.brand.name}`
                          : `Check out at ${g.brand.name}`}{" "}
                      <ExternalLink size={17} />
                    </a>
                  ) : null}
                </section>
              );
            })}
          </div>
          <aside className="cart-summary">
            <h2>Total</h2>
            <div>
              <span>{groups.length} {groups.length === 1 ? "brand" : "brands"}, shipping included</span>
              <b data-field="grand-total">{grandTotals.length ? <MixedTotal totals={grandTotals} /> : "—"}{pending ? " …" : ""}</b>
            </div>
            <p>Taxes, if any, are added by each brand at its checkout.</p>
            <hr />
            <p>
              <ShieldCheck size={20} /> You pay each brand directly on its own secure checkout. Marracat never holds
              your payment.
            </p>
          </aside>
        </div>
      ) : (
        <div className="empty-state" data-section="all-done">
          <CheckCircle2 size={44} />
          <h2>All orders placed</h2>
          <p>Each brand emails its own confirmation.</p>
          <a className="primary-button" href={shopHref}>
            Keep discovering <ArrowRight size={17} />
          </a>
        </div>
      )}
    </>
  );
}

export const brandStoreHref = (brand) => safeURL("https://" + (brand?.domain || ""));
