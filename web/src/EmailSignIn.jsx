import React, { useState } from "react";
import { ArrowLeft } from "lucide-react";

// "Use email instead" in the sign-in dialog (owner, 2026-11-09: "give user a
// hypertext to use email"): an address, then the 6-digit code sent to it
// (server/email-code.js). The code is posted to Auth.js like the other
// sign-ins, so the session it opens is the same kind.
export default function EmailSignIn({ onBack, onStart }) {
  const [step, setStep] = useState("email");
  const [email, setEmail] = useState("");
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [note, setNote] = useState("");

  async function send(e) {
    e?.preventDefault();
    setBusy(true);
    setError("");
    try {
      const r = await fetch("/api/email-code", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ email }),
      });
      if (r.status === 204) {
        setStep("code");
        setCode("");
        setNote(`We sent a 6-digit code to ${email.trim()}. It works for 10 minutes.`);
      } else {
        setError((await r.json().catch(() => null))?.error || "We couldn't send a code. Please try again.");
      }
    } catch {
      setError("Unable to connect. Please try again.");
    }
    setBusy(false);
  }

  async function verify(e) {
    e.preventDefault();
    setBusy(true);
    setError("");
    try {
      onStart?.();
      const { csrfToken } = await fetch("/auth/csrf").then((r) => r.json());
      const r = await fetch("/auth/callback/email", {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded", "X-Auth-Return-Redirect": "1" },
        body: new URLSearchParams({ csrfToken, email, code, callbackUrl: location.origin + "/account" }),
      });
      const { url } = await r.json().catch(() => ({}));
      if (!url || /[?&]error=/.test(url)) {
        setError("That code didn't work. Check it, or send a new one.");
        setBusy(false);
        return;
      }
      location.assign(url);
    } catch {
      setError("Unable to connect. Please try again.");
      setBusy(false);
    }
  }

  return (
    <div className="email-signin">
      {step === "email" ? (
        <form onSubmit={send}>
          <label className="sr-only" htmlFor="signin-email">Email</label>
          <input
            id="signin-email"
            className="auth-input"
            type="email"
            autoComplete="email"
            placeholder="Email"
            required
            autoFocus
            value={email}
            onChange={(e) => setEmail(e.target.value)}
          />
          <button className="auth-continue" disabled={busy || !email.trim()}>
            {busy ? "Sending…" : "Continue"}
          </button>
        </form>
      ) : (
        <form onSubmit={verify}>
          <p className="auth-note" role="status">{note}</p>
          <label className="sr-only" htmlFor="signin-code">6-digit code</label>
          <input
            id="signin-code"
            className="auth-input auth-code"
            inputMode="numeric"
            autoComplete="one-time-code"
            pattern="[0-9]{6}"
            placeholder="000000"
            required
            autoFocus
            value={code}
            onChange={(e) => setCode(e.target.value.replace(/\D/g, "").slice(0, 6))}
          />
          <button className="auth-continue" disabled={busy || code.length !== 6}>
            {busy ? "Signing in…" : "Sign in"}
          </button>
          <div className="auth-links">
            <button type="button" className="auth-email-link" disabled={busy} onClick={() => send()}>Send a new code</button>
            <button type="button" className="auth-email-link" onClick={() => { setStep("email"); setError(""); }}>Use a different email</button>
          </div>
        </form>
      )}
      {error && <p className="auth-error" role="alert">{error}</p>}
      <button type="button" className="auth-email-link auth-back" onClick={onBack}>
        <ArrowLeft size={14} /> Other ways to sign in
      </button>
    </div>
  );
}
