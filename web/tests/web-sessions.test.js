import { test } from "node:test";
import assert from "node:assert/strict";
import Database from "better-sqlite3";
import { createAuthConfig } from "../server/auth.js";
import { newSession, revokeSession, revokeOtherSessions, sessionLive, SESSION_MS } from "../server/web-sessions.js";

const env = { AUTH_SECRET: "s".repeat(40), AUTH_GOOGLE_ID: "g", AUTH_GOOGLE_SECRET: "x" };
async function setup() {
  const db = new Database(":memory:");
  db.exec("CREATE TABLE users (id TEXT PRIMARY KEY, name TEXT, email TEXT, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)");
  const config = await createAuthConfig(db, env);
  const signIn = () => config.callbacks.jwt({ token: {}, account: { provider: "google", providerAccountId: "ann" },
    user: { name: "Ann", email: "ann@example.test" }, profile: { email_verified: true } });
  const use = (token) => config.callbacks.jwt({ token: { ...token } });
  return { db, config, signIn, use };
}

// 2026-11-12: signing out only deleted the browser's cookie; a copy of it
// kept working for the rest of its 30 days.
test("a signed-out session's cookie no longer opens the account; other sessions stay", async () => {
  const { config, signIn, use } = await setup();
  const laptop = await signIn(), phone = await signIn();
  assert.match(laptop.sid, /^[a-f0-9]{32}$/);
  assert.notEqual(laptop.sid, phone.sid);
  assert.ok(laptop.since > 0);
  assert.equal((await use(laptop)).sub, "google:ann");
  await config.events.signOut({ token: laptop });
  assert.equal(await use(laptop), null, "the copied cookie is dead");
  assert.equal((await use(phone)).sub, "google:ann");
  const session = await config.callbacks.session({ session: { user: { email: "ann@example.test" } }, token: phone });
  assert.equal(session.user.sid, phone.sid);
});

test("removing a passkey ends every other session of the account, old cookies included", async () => {
  const { db, signIn, use } = await setup();
  const here = await signIn(), elsewhere = await signIn();
  const old = { sub: "google:ann", name: "Ann", email: "ann@example.test" };  // a cookie from before sessions had ids
  const upgraded = await use(old);
  assert.match(upgraded.sid, /^[a-f0-9]{32}$/, "it gets an id on its next use");
  assert.equal(upgraded.since, 0);
  revokeOtherSessions(db, "google:ann", here.sid, here.since + 1000);
  assert.equal((await use(here)).sub, "google:ann", "the browser that removed it stays in");
  assert.equal(await use(elsewhere), null);
  assert.equal(await use(old), null);
  assert.equal(await use(upgraded), null);
  const later = { ...(await signIn()), since: here.since + 2000 };
  assert.equal((await use(later)).sub, "google:ann", "a sign-in after the removal is a new session");
});

test("the signed-out list forgets a session once its cookie would have expired", () => {
  const db = new Database(":memory:");
  const a = newSession(0), b = newSession(0);
  revokeSession(db, a.sid, 0);
  assert.equal(sessionLive(db, { sub: "u", ...a }), false);
  revokeSession(db, b.sid, SESSION_MS + 1);
  assert.equal(db.prepare("SELECT COUNT(*) n FROM web_sessions_revoked").get().n, 1, "the expired entry was pruned");
  revokeSession(db, "not-a-session-id", 0);
  revokeSession(db, undefined, 0);
  assert.equal(db.prepare("SELECT COUNT(*) n FROM web_sessions_revoked").get().n, 1);
  assert.equal(sessionLive(db, { sub: "u" }), true, "a cookie with no id and no cutoff is still good");
});
