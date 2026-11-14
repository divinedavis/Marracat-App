// One account per person, whichever way they sign in (owner, 2026-10-02).
//
// Accounts were keyed by the sign-in itself ("google:<sub>", "apple:<sub>"),
// so signing in with Apple after Google, with the same email, made a second,
// empty account and the first one's orders seemed to vanish. Now each sign-in
// is an identity linked to an account:
//
//   1. an identity already linked opens its account;
//   2. an identity that is itself an account (every account made before this)
//      opens that account;
//   3. otherwise a verified email that matches an existing account links the
//      identity to it — Google and Apple both verify the address, and Apple's
//      private relay addresses never match anything;
//   4. otherwise the identity starts a new account, keyed by itself as before.
//
// The account id never changes, so every table keyed by user_id stays right.

const RELAY = /@privaterelay\.appleid\.com$/i;

export function installIdentitySchema(db) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS user_identities (identity TEXT PRIMARY KEY, user_id TEXT NOT NULL, linked INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS user_identities_user ON user_identities(user_id);
  `);
}

// The account this sign-in opens. `emailVerified` must be true for step 3.
export function accountFor(db, { id, email, emailVerified }) {
  installIdentitySchema(db);
  const exists = (userID) => Boolean(db.prepare("SELECT 1 FROM users WHERE id=?").get(userID));
  const link = (userID) => {
    db.prepare("INSERT INTO user_identities(identity,user_id,linked) VALUES(?,?,?) ON CONFLICT(identity) DO UPDATE SET user_id=excluded.user_id")
      .run(id, userID, Date.now());
    return userID;
  };
  const linked = db.prepare("SELECT user_id FROM user_identities WHERE identity=?").get(id);
  if (linked && exists(linked.user_id)) return linked.user_id;
  if (exists(id)) return link(id);
  if (emailVerified && typeof email === "string" && email.includes("@") && !RELAY.test(email)) {
    const match = db.prepare("SELECT id FROM users WHERE lower(email)=lower(?) ORDER BY rowid LIMIT 1").get(email);
    if (match) return link(match.id);
  }
  return link(id);
}

// Whether deleting this account must be confirmed with Apple: any Apple
// sign-in on it means Apple's token has to be revoked (App Store 5.1.1(v)).
export function confirmWith(db, userID) {
  installIdentitySchema(db);
  if (userID.startsWith("apple:")) return "apple";
  const apple = db.prepare("SELECT 1 FROM user_identities WHERE user_id=? AND identity LIKE 'apple:%'").get(userID);
  return apple ? "apple" : "google";
}

export function deleteIdentities(db, userID) {
  installIdentitySchema(db);
  db.prepare("DELETE FROM user_identities WHERE user_id=?").run(userID);
}
