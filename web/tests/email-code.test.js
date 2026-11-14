// Sign in with an email code (owner, 2026-11-09: "give user a hypertext to
// use email"; a 6-digit code chosen over a password or a link).
import { test } from "node:test";
import assert from "node:assert/strict";
import Database from "better-sqlite3";
import { issueCode, checkCode, normalEmail, codeEmail, MAX_TRIES, CODE_TTL } from "../server/email-code.js";
import { createAuthConfig, authStatus } from "../server/auth.js";

const secret = "test-secret-that-is-longer-than-thirty-two-characters";
const env = { AUTH_SECRET: secret, RELAY_SMTP_HOST: "smtp.test", RELAY_SMTP_USER: "hello@marracat.com", RELAY_SMTP_PASS: "x" };
const db = () => {
  const d = new Database(":memory:");
  d.exec("CREATE TABLE users(id TEXT PRIMARY KEY,name TEXT,email TEXT)");
  return d;
};

test("addresses are trimmed, lowercased, and junk is refused", () => {
  assert.equal(normalEmail("  Shopper@Example.COM "), "shopper@example.com");
  for (const bad of ["", "no-at-sign", "a@b", "a b@c.com", "<x@y.com>", "x@y.com\nBcc: z@w.com", "a".repeat(250) + "@x.com"])
    assert.equal(normalEmail(bad), null, bad);
});

test("a code works once, and only for its own address", () => {
  const d = db();
  const { code } = issueCode(d, "a@x.com", { secret, now: 0 });
  assert.match(code, /^\d{6}$/);
  assert.equal(checkCode(d, "b@x.com", code, { secret, now: 1 }), false);
  assert.equal(checkCode(d, "a@x.com", code, { secret, now: 1 }), true);
  assert.equal(checkCode(d, "a@x.com", code, { secret, now: 2 }), false, "spent");
  assert.equal(d.prepare("SELECT count(*) n FROM email_codes WHERE hash LIKE ?").get(`%${code}%`).n, 0, "kept only as a hash");
});

test("a code expires after 10 minutes and dies after 5 wrong tries", () => {
  const d = db();
  const { code } = issueCode(d, "a@x.com", { secret, now: 0, code: "123456" });
  assert.equal(checkCode(d, "a@x.com", code, { secret, now: CODE_TTL + 1 }), false);
  issueCode(d, "b@x.com", { secret, now: 0, code: "123456" });
  for (let i = 0; i < MAX_TRIES; i++) assert.equal(checkCode(d, "b@x.com", "000000", { secret, now: 1 }), false);
  assert.equal(checkCode(d, "b@x.com", "123456", { secret, now: 2 }), false, "locked after 5 wrong");
  assert.equal(checkCode(d, "b@x.com", "12345", { secret, now: 2 }), false);
});

test("one address gets a new code at most every 30 seconds and 6 an hour", () => {
  const d = db();
  assert.ok(issueCode(d, "a@x.com", { secret, now: 0 }).code);
  assert.equal(issueCode(d, "a@x.com", { secret, now: 10_000 }).error, "wait");
  for (let i = 1; i < 6; i++) assert.ok(issueCode(d, "a@x.com", { secret, now: i * 31_000 }).code);
  assert.equal(issueCode(d, "a@x.com", { secret, now: 7 * 31_000 }).error, "limit");
  assert.ok(issueCode(d, "a@x.com", { secret, now: 3_600_001 }).code, "a new hour");
});

test("the email says the code and nothing else to act on", () => {
  const m = codeEmail("a@x.com", "042137");
  assert.equal(m.subject, "042137 is your Marracat code");
  assert.match(m.text, /042137/);
  assert.doesNotMatch(m.html, /<a /, "no links to phish with");
});

test("email sign-in is offered only with a mailbox to send from", () => {
  assert.equal(authStatus(env).email, true);
  assert.equal(authStatus({ AUTH_SECRET: secret }).email, false);
});

test("a right code signs in to the account that address already has", async () => {
  const d = db();
  const config = await createAuthConfig(d, env);
  // Someone who signed in with Google under the same verified address.
  await config.callbacks.jwt({ token: {}, account: { provider: "google", providerAccountId: "g1" },
    user: { name: "Shopper", email: "shopper@example.com" }, profile: { email_verified: true } });
  const email = config.providers.find((p) => p.options?.id === "email").options;
  assert.equal(await email.authorize({ email: "Shopper@example.com", code: "000000" }), null, "no code issued");
  const { code } = issueCode(d, "shopper@example.com", { secret });
  const user = await email.authorize({ email: "Shopper@example.com", code });
  assert.deepEqual(user, { id: "shopper@example.com", email: "shopper@example.com", name: null });
  const token = await config.callbacks.jwt({ token: {}, account: { provider: "email", providerAccountId: user.id }, user });
  assert.equal(token.sub, "google:g1");
});

test("a first email sign-in makes an account with that address", async () => {
  const d = db();
  const config = await createAuthConfig(d, env);
  const token = await config.callbacks.jwt({ token: {}, account: { provider: "email", providerAccountId: "new@example.com" },
    user: { id: "new@example.com", email: "new@example.com", name: null } });
  assert.equal(token.sub, "email:new@example.com");
  assert.equal(d.prepare("SELECT email FROM users WHERE id=?").get(token.sub).email, "new@example.com");
});

// Through Auth.js itself, as the dialog posts it: a right code answers with
// the account page and a session cookie; a wrong one with an error and none.
test("the sign-in endpoint takes a right code and turns down a wrong one", async () => {
  const { authCore } = await import("./auth-core.js");
  const { Auth } = await authCore();
  const d = db();
  const config = await createAuthConfig(d, env);
  const post = async (code) => {
    const csrf = await Auth(new Request("http://localhost/auth/csrf"), config);
    const { csrfToken } = await csrf.json();
    const cookie = csrf.headers.getSetCookie().map((c) => c.split(";")[0]).join("; ");
    const res = await Auth(new Request("http://localhost/auth/callback/email", {
      method: "POST",
      headers: { cookie, "Content-Type": "application/x-www-form-urlencoded", "X-Auth-Return-Redirect": "1" },
      body: new URLSearchParams({ csrfToken, email: "a@example.com", code, callbackUrl: "http://localhost/account" }),
    }), config);
    return { url: (await res.json()).url, session: res.headers.getSetCookie().some((c) => c.startsWith("authjs.session-token=")) };
  };
  const { code } = issueCode(d, "a@example.com", { secret });
  const wrong = await post(code === "000000" ? "111111" : "000000");
  assert.match(wrong.url, /error=/);
  assert.equal(wrong.session, false);
  const right = await post(code);
  assert.equal(right.url, "http://localhost/account");
  assert.equal(right.session, true);
});
