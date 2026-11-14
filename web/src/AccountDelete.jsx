import React, { useState } from "react";

// "Delete account" on the account page (2026-11-12; until then the site said
// to email us). The server says how this account is deleted
// (server/account-web.js howToDelete): with a code emailed to its address,
// in the app when it signs in with Apple, or once its ad budget is canceled.
const json = (r) => r.json().catch(() => ({}));

export default function AccountDelete({ toast, onDeleted }) {
  const [way, setWay] = useState(null);
  const [sent, setSent] = useState(false);
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const open = async () => {
    const r = await fetch("/api/account/delete").catch(() => null);
    if (!r?.ok) return toast("Couldn't open that just now. Try again.");
    setWay(await json(r));
  };
  const send = async () => {
    setBusy(true);
    const r = await fetch("/api/account/delete/code", { method: "POST" }).catch(() => null);
    setBusy(false);
    if (r?.status === 204) return setSent(true);
    toast((r && (await json(r)).error) || "We couldn't send the email. Please try again.");
  };
  const confirm = async (event) => {
    event.preventDefault();
    setBusy(true);
    const r = await fetch("/api/account", { method: "DELETE", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ code: code.trim() }) }).catch(() => null);
    setBusy(false);
    if (r?.status === 204) return onDeleted();
    toast((r && (await json(r)).error) || "Couldn't delete the account. Please try again.");
  };
  if (!way)
    return (
      <button className="text-link account-delete-open" onClick={open}>
        Delete account
      </button>
    );
  return (
    <section className="account-delete" aria-label="Delete account" data-how={way.how}>
      <h2>Delete account</h2>
      {way.how === "email" && !sent && (
        <>
          <p>
            This deletes your Marracat account and everything kept with it: saved items, lists, order history, alerts,
            comments and friends. It can't be undone. Orders you placed stay with the brands you bought from.
          </p>
          <p>To confirm it's you, we'll email a code to {way.email}.</p>
          <div className="account-delete-actions">
            <button className="outline-button" disabled={busy} onClick={send}>Email me a code</button>
            <button className="text-link" onClick={() => setWay(null)}>Keep my account</button>
          </div>
        </>
      )}
      {way.how === "email" && sent && (
        <form onSubmit={confirm}>
          <p>Enter the 6-digit code we sent to {way.email}.</p>
          <input className="account-delete-code" inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]{6}" maxLength={6}
            aria-label="Deletion code" value={code} onChange={(e) => setCode(e.target.value.replace(/[^0-9]/g, ""))} required />
          <div className="account-delete-actions">
            <button className="outline-button danger" type="submit" disabled={busy || code.length !== 6}>Delete my account</button>
            <button className="text-link" type="button" onClick={() => { setWay(null); setSent(false); setCode(""); }}>Keep my account</button>
          </div>
        </form>
      )}
      {way.how === "app" && (
        <p>
          This account signs in with Apple, so it is deleted in the Marracat app, where Apple's access is removed with it:
          open You, then Account settings, then Delete account. Without the app, email{" "}
          <a href="mailto:privacy@marracat.com">privacy@marracat.com</a> and we'll delete it for you.
        </p>
      )}
      {way.how === "cancel-budget" && (
        <p>
          This account pays for a monthly ad budget. <a href={`/brand-ads?brand=${encodeURIComponent(way.brand)}`}>Cancel it first</a>,
          then come back to delete the account.
        </p>
      )}
      {way.how === "support" && (
        <p>
          Email <a href="mailto:privacy@marracat.com">privacy@marracat.com</a> from the address you use with Marracat and
          we'll delete the account for you.
        </p>
      )}
      {way.how !== "email" && <button className="text-link" onClick={() => setWay(null)}>Close</button>}
    </section>
  );
}
