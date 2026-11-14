// Ending a website session for real. The session is a 30-day signed cookie
// with nothing kept on the server, so until 2026-11-12 signing out only
// deleted the browser's copy: a copy taken earlier kept working for the rest
// of its 30 days, and so did every session after a passkey was removed.
//
// Each session now carries an id (`sid`) and when it began (`since`).
// Signing out puts its id on a short list until it would have expired
// anyway; removing a passkey ends every session of the account that began
// before that moment, except the one that removed it. A cookie from before
// this change has neither value: it can't be listed, but a cutoff ends it.
import { randomBytes } from "node:crypto";

export const SESSION_MS = 30 * 24 * 60 * 60_000;

export function installWebSessionSchema(db) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS web_sessions_revoked (sid TEXT PRIMARY KEY, expires INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS web_session_cutoffs (user_id TEXT PRIMARY KEY, after INTEGER NOT NULL, keep_sid TEXT);`);
}

export const newSession = (now = Date.now()) => ({ sid: randomBytes(16).toString("hex"), since: now });
const SID = /^[a-f0-9]{32}$/;

/// Signing out: this session's cookie stops working everywhere.
export function revokeSession(db, sid, now = Date.now()) {
  if (!SID.test(String(sid || ""))) return;
  installWebSessionSchema(db);
  db.prepare("DELETE FROM web_sessions_revoked WHERE expires<?").run(now);
  db.prepare("INSERT OR REPLACE INTO web_sessions_revoked(sid,expires) VALUES(?,?)").run(sid, now + SESSION_MS);
}

/// Every session of the account that began before now ends, except `keepSid`.
export function revokeOtherSessions(db, userID, keepSid = null, now = Date.now()) {
  installWebSessionSchema(db);
  db.prepare(`INSERT INTO web_session_cutoffs(user_id,after,keep_sid) VALUES(?,?,?)
    ON CONFLICT(user_id) DO UPDATE SET after=excluded.after, keep_sid=excluded.keep_sid`).run(userID, now, SID.test(String(keepSid || "")) ? keepSid : null);
}

/// Whether the session this token names is still open.
export function sessionLive(db, token) {
  installWebSessionSchema(db);
  if (token.sid && db.prepare("SELECT 1 FROM web_sessions_revoked WHERE sid=?").get(String(token.sid))) return false;
  const cut = db.prepare("SELECT after, keep_sid FROM web_session_cutoffs WHERE user_id=?").get(token.sub);
  if (cut && (Number(token.since) || 0) < cut.after && !(token.sid && token.sid === cut.keep_sid)) return false;
  return true;
}

export function deleteWebSessionData(db, userID) {
  installWebSessionSchema(db);
  db.prepare("DELETE FROM web_session_cutoffs WHERE user_id=?").run(userID);
}
