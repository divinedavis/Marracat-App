// Sign in with a 6-digit code sent to an email address (owner, 2026-11-09:
// "give user a hypertext to use email", choosing a code over a password or a
// link). The code proves the address, so the account it opens is safe to link
// by email with a Google or Apple sign-in (identities.js); an email account
// with a password and no check would let anyone open another person's
// account. Codes are kept only as an HMAC, last 10 minutes, allow 5 tries,
// and one address gets a new one at most every 30 seconds and 6 an hour.
import { createHmac, randomInt, timingSafeEqual } from "node:crypto";
import express from "express";
import { rateLimit } from "express-rate-limit";

export const CODE_TTL = 10 * 60_000;
export const MAX_TRIES = 5;
const RESEND_GAP = 30_000;
const HOURLY = 6;

const EMAIL = /^[^\s@<>()[\]\\,;:"]{1,64}@[a-z0-9-]+(\.[a-z0-9-]+)+$/;
export function normalEmail(value) {
  const email = String(value ?? "").trim().toLowerCase();
  return email.length <= 254 && EMAIL.test(email) ? email : null;
}

export function installEmailCodeSchema(db) {
  db.exec(`CREATE TABLE IF NOT EXISTS email_codes (
    email TEXT PRIMARY KEY,
    hash TEXT NOT NULL,
    expires INTEGER NOT NULL,
    tries INTEGER NOT NULL DEFAULT 0,
    sent INTEGER NOT NULL,
    hour_start INTEGER NOT NULL,
    hour_count INTEGER NOT NULL
  )`);
}

const digest = (secret, email, code) => createHmac("sha256", secret).update(`${email}:${code}`).digest("hex");

/// A new code for this address, or why not: "wait" when one went out under
/// 30 seconds ago, "limit" after 6 in an hour.
export function issueCode(db, email, { secret, now = Date.now(), code = String(randomInt(0, 1_000_000)).padStart(6, "0") }) {
  installEmailCodeSchema(db);
  const row = db.prepare("SELECT sent, hour_start, hour_count FROM email_codes WHERE email=?").get(email);
  if (row && now - row.sent < RESEND_GAP) return { error: "wait" };
  const fresh = !row || now - row.hour_start >= 3_600_000;
  if (!fresh && row.hour_count >= HOURLY) return { error: "limit" };
  db.prepare(`INSERT INTO email_codes (email, hash, expires, tries, sent, hour_start, hour_count) VALUES (?,?,?,0,?,?,?)
    ON CONFLICT(email) DO UPDATE SET hash=excluded.hash, expires=excluded.expires, tries=0, sent=excluded.sent,
      hour_start=excluded.hour_start, hour_count=excluded.hour_count`)
    .run(email, digest(secret, email, code), now + CODE_TTL, now, fresh ? now : row.hour_start, fresh ? 1 : row.hour_count + 1);
  return { code };
}

/// Whether the code is this address's current one. A right code is used up;
/// a wrong one counts against the 5 tries, after which the code is gone.
export function checkCode(db, email, code, { secret, now = Date.now() }) {
  installEmailCodeSchema(db);
  if (!email || !/^\d{6}$/.test(String(code ?? ""))) return false;
  const row = db.prepare("SELECT hash, expires, tries FROM email_codes WHERE email=?").get(email);
  if (!row || row.expires < now || row.tries >= MAX_TRIES) return false;
  const want = Buffer.from(row.hash, "hex");
  const got = Buffer.from(digest(secret, email, String(code)), "hex");
  if (want.length === got.length && timingSafeEqual(want, got)) {
    // Spent, but the hourly count stays so the limit still holds.
    db.prepare("UPDATE email_codes SET expires=0, tries=? WHERE email=?").run(MAX_TRIES, email);
    return true;
  }
  db.prepare("UPDATE email_codes SET tries=tries+1 WHERE email=?").run(email);
  return false;
}

export function codeEmail(to, code) {
  return {
    to,
    subject: `${code} is your Marracat code`,
    text: `Your Marracat sign-in code is ${code}\n\nIt works for 10 minutes. If you didn't ask for it, you can ignore this email; nobody can sign in without the code.`,
    html: `<div style="font-family:Arial,sans-serif;color:#1d1d1d;max-width:420px">` +
      `<p style="font-size:15px">Your Marracat sign-in code is</p>` +
      `<p style="font-size:34px;font-weight:700;letter-spacing:8px;margin:8px 0 18px">${code}</p>` +
      `<p style="font-size:13px;color:#6d6d6d">It works for 10 minutes. If you didn't ask for it, you can ignore this email; nobody can sign in without the code.</p></div>`,
  };
}

/// POST /api/email-code {email}: sends a code. 204 when sent, 400 for an
/// address that can't be one, 429 when asked too often, 503 without mail.
export function emailCodeRoutes(app, db, { mailer, secret = process.env.AUTH_SECRET } = {}) {
  const perIP = rateLimit({ windowMs: 10 * 60_000, limit: 10, standardHeaders: "draft-8", legacyHeaders: false });
  app.post("/api/email-code", perIP, express.json({ limit: "2kb" }), async (req, res) => {
    res.set("Cache-Control", "no-store");
    if (!mailer || !secret) return res.status(503).json({ error: "Email sign-in is not available right now." });
    const email = normalEmail(req.body?.email);
    if (!email) return res.status(400).json({ error: "Enter a full email address." });
    const issued = issueCode(db, email, { secret });
    if (issued.error === "wait") return res.status(429).json({ error: "A code is on its way. Wait a few seconds before asking for another." });
    if (issued.error) return res.status(429).json({ error: "Too many codes for this address. Try again in an hour." });
    try {
      await mailer(codeEmail(email, issued.code));
      res.sendStatus(204);
    } catch {
      res.status(502).json({ error: "We couldn't send the email. Please try again." });
    }
  });
}
