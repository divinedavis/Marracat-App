import { test } from "node:test";
import assert from "node:assert/strict";
import Database from "better-sqlite3";
import { createAuthConfig, authStatus, hasAppSession } from "../server/auth.js";
import { authCore } from "./auth-core.js";
const env = {
  AUTH_SECRET: "test-secret-that-is-longer-than-thirty-two-characters",
};
function database() {
  const db = new Database(":memory:");
  db.exec("CREATE TABLE users(id TEXT PRIMARY KEY,name TEXT,email TEXT)");
  return db;
}
test("missing providers stay disabled and missing session secret fails closed", async () => {
  // A passkey needs nothing configured (server/passkeys.js), so it is always on.
  assert.deepEqual(authStatus({}), { email: false, passkey: true, google: false, apple: false });
  await assert.rejects(() => createAuthConfig(database(), {}), /AUTH_SECRET/);
});
test("Google and Apple accounts cannot merge based on a matching email", async () => {
  const db = database();
  const config = await createAuthConfig(db, env);
  const user = { name: "Test shopper", email: "test@example.test" };
  for (const provider of ["google", "apple"]) {
    const token = await config.callbacks.jwt({
      token: {},
      account: { provider, providerAccountId: "subject-123" },
      user,
    });
    assert.equal(token.sub, `${provider}:subject-123`);
  }
  assert.equal(db.prepare("SELECT count(*) AS n FROM users").get().n, 2);
  db.close();
});
test("repeat sign-ins preserve account identity and do not duplicate records", async () => {
  const db = database(),
    config = await createAuthConfig(db, env);
  for (let i = 0; i < 2; i++)
    await config.callbacks.jwt({
      token: {},
      account: { provider: "google", providerAccountId: "123" },
      user: { name: "Person", email: "p@example.test" },
    });
  assert.equal(db.prepare("SELECT count(*) AS n FROM users").get().n, 1);
  db.close();
});
test("external callback redirects are rejected", async () => {
  const db = database(),
    config = await createAuthConfig(db, env),
    baseUrl = "https://marracat.com";
  for (const url of ["https://evil.test", "//evil.test", "javascript:alert(1)"])
    assert.equal(await config.callbacks.redirect({ url, baseUrl }), baseUrl);
  assert.equal(
    await config.callbacks.redirect({ url: "/account", baseUrl }),
    baseUrl + "/account",
  );
  db.close();
});

test("Google authorization uses a real CSRF token and PKCE before redirecting", async () => {
  const { Auth } = await authCore();
  const db = database();
  const config = await createAuthConfig(db, {
    ...env,
    AUTH_GOOGLE_ID: "test-client",
    AUTH_GOOGLE_SECRET: "test-secret",
  });
  const csrf = await Auth(new Request("http://localhost/auth/csrf"), config);
  const { csrfToken } = await csrf.json();
  const cookies = csrf.headers
    .getSetCookie()
    .map((c) => c.split(";")[0])
    .join("; ");
  const result = await Auth(
    new Request("http://localhost/auth/signin/google", {
      method: "POST",
      headers: {
        cookie: cookies,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: new URLSearchParams({
        csrfToken,
        callbackUrl: "http://localhost/",
      }),
    }),
    config,
  );
  assert.equal(result.status, 302);
  const url = new URL(result.headers.get("location"));
  assert.equal(url.hostname, "accounts.google.com");
  assert.equal(url.searchParams.get("client_id"), "test-client");
  assert.equal(url.searchParams.get("code_challenge_method"), "S256");
  assert.ok(url.searchParams.get("code_challenge"));
  db.close();
});

test("signed sessions resolve identity while forged cookies are rejected", async () => {
  const { Auth } = await authCore();
  const { encode } = await authCore("/jwt");
  const db = database();
  const config = await createAuthConfig(db, { ...env, NODE_ENV: "production" });
  db.prepare("INSERT INTO users(id,name,email) VALUES(?,?,?)").run("google:fixture", "Fixture shopper", "fixture@example.test");
  const name = "__Secure-authjs.session-token";
  const token = await encode({
    token: { sub: "google:fixture", name: "Fixture shopper" },
    secret: env.AUTH_SECRET,
    salt: name,
  });
  const response = await Auth(
    new Request("https://marracat.com/auth/session", {
      headers: { cookie: `${name}=${token}` },
    }),
    config,
  );
  assert.equal((await response.json()).user.id, "google:fixture");
  db.prepare("DELETE FROM users WHERE id=?").run("google:fixture");
  const deleted = await Auth(new Request("https://marracat.com/auth/session", { headers: { cookie: `${name}=${token}` } }), config);
  assert.equal(await deleted.json(), null, "deleted accounts lose their existing web session");
  const rejected = await Auth(
    new Request("https://marracat.com/auth/session", {
      headers: { cookie: `${name}=forged` },
    }),
    config,
  );
  assert.equal(await rejected.json(), null);
  db.close();
});

test("Apple authorization preserves nonce/state cookies for its cross-site callback", async () => {
  const { Auth } = await authCore();
  const { generateKeyPair, exportPKCS8, jwtVerify } = await import("jose");
  const { mkdtempSync, writeFileSync, rmSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const dir = mkdtempSync(join(tmpdir(), "marracat-apple-test-"));
  const db = database();
  try {
    const { privateKey, publicKey } = await generateKeyPair("ES256", {
      extractable: true,
    });
    const keyPath = join(dir, "test.p8");
    writeFileSync(keyPath, await exportPKCS8(privateKey), { mode: 0o600 });
    const config = await createAuthConfig(db, {
      ...env,
      NODE_ENV: "production",
      AUTH_APPLE_ID: "com.example.marracat.web",
      APPLE_TEAM_ID: "TESTTEAM",
      APPLE_KEY_ID: "TESTKEY",
      APPLE_PRIVATE_KEY_PATH: keyPath,
    });
    const verified = await jwtVerify(
      config.providers[0].options.clientSecret,
      publicKey,
      { issuer: "TESTTEAM", audience: "https://appleid.apple.com" },
    );
    assert.equal(verified.payload.sub, "com.example.marracat.web");
    const csrf = await Auth(
      new Request("https://marracat.com/auth/csrf"),
      config,
    );
    const { csrfToken } = await csrf.json();
    const cookies = csrf.headers
      .getSetCookie()
      .map((c) => c.split(";")[0])
      .join("; ");
    const response = await Auth(
      new Request("https://marracat.com/auth/signin/apple", {
        method: "POST",
        headers: {
          cookie: cookies,
          "Content-Type": "application/x-www-form-urlencoded",
        },
        body: new URLSearchParams({ csrfToken }),
      }),
      config,
    );
    const url = new URL(response.headers.get("location"));
    assert.equal(url.hostname, "appleid.apple.com");
    assert.equal(url.searchParams.get("response_mode"), "form_post");
    assert.ok(url.searchParams.get("nonce"));
    assert.ok(url.searchParams.get("state"));
    for (const name of ["state", "nonce"]) {
      const cookie = response.headers
        .getSetCookie()
        .find((c) => c.startsWith(`__Secure-authjs.${name}=`));
      assert.match(cookie, /HttpOnly/);
      assert.match(cookie, /Secure/);
      assert.match(cookie, /SameSite=None/i);
    }
  } finally {
    db.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a session says the account has the app only while an app session is live", async () => {
  const db = database();
  const config = await createAuthConfig(db, env);
  const session = () => config.callbacks.session({ session: { user: { email: "a@example.test" } }, token: { sub: "u1" } });
  assert.equal(hasAppSession(db, "u1"), false, "no mobile_sessions table yet");
  assert.equal((await session()).user.hasApp, undefined);
  db.exec("CREATE TABLE mobile_sessions(hash TEXT PRIMARY KEY,user_id TEXT NOT NULL,expires INTEGER NOT NULL)");
  db.prepare("INSERT INTO mobile_sessions VALUES('old','u1',?)").run(Date.now() - 1000);
  db.prepare("INSERT INTO mobile_sessions VALUES('other','u2',?)").run(Date.now() + 86400000);
  assert.equal((await session()).user.hasApp, undefined, "expired, or someone else's");
  db.prepare("INSERT INTO mobile_sessions VALUES('live','u1',?)").run(Date.now() + 86400000);
  assert.equal((await session()).user.hasApp, true);
});

test("an unverified provider email is not stored and never links to an account", async () => {
  const db = database();
  const { installIdentitySchema } = await import("../server/identities.js");
  installIdentitySchema(db);
  const config = await createAuthConfig(db, env);
  db.prepare("INSERT INTO users(id,name,email) VALUES('apple:victim','Victim','victim@example.test')").run();
  const unverified = await config.callbacks.jwt({
    token: {}, account: { provider: "google", providerAccountId: "attacker" },
    user: { name: "Attacker", email: "victim@example.test" }, profile: { email_verified: false },
  });
  assert.equal(unverified.sub, "google:attacker");
  assert.equal(db.prepare("SELECT email FROM users WHERE id='google:attacker'").get().email, null);
  const verified = await config.callbacks.jwt({
    token: {}, account: { provider: "google", providerAccountId: "victim" },
    user: { name: "Victim", email: "victim@example.test" }, profile: { email_verified: true },
  });
  assert.equal(verified.sub, "apple:victim");
  db.close();
});

// Passkeys (2026-11-10): a passkey's identity opens the account it was added
// to, and the session carries that account's name and email, which a passkey
// itself doesn't send.
test("a passkey opens its own account, with the account's name and email", async () => {
  const db = database();
  db.prepare("INSERT INTO users (id, name, email) VALUES ('google:ada', 'Ada', 'ada@example.test')").run();
  db.exec("CREATE TABLE IF NOT EXISTS user_identities (identity TEXT PRIMARY KEY, user_id TEXT NOT NULL, linked INTEGER NOT NULL)");
  db.prepare("INSERT INTO user_identities VALUES ('passkey:cred-1', 'google:ada', 1)").run();
  const config = await createAuthConfig(db, env);
  assert.ok(config.providers.some((p) => (p.options?.id ?? p.id) === "passkey"));
  const token = await config.callbacks.jwt({ token: {}, account: { provider: "passkey", providerAccountId: "cred-1" }, user: { id: "cred-1", name: null, email: null } });
  assert.deepEqual([token.sub, token.name, token.email], ["google:ada", "Ada", "ada@example.test"]);
  assert.equal(db.prepare("SELECT COUNT(*) n FROM users").get().n, 1, "no second account");
});


// 2026-11-12: every signed-in website request built the sign-in config, and
// each build read Apple's key from disk and signed a new client secret.
test("Apple's client secret is signed once and reused for 45 minutes", async () => {
  const { generateKeyPair, exportPKCS8, jwtVerify } = await import("jose");
  const { writeFileSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const { appleClientSecret, APPLE_SECRET_REUSE_MS } = await import("../server/auth.js");
  const { privateKey, publicKey } = await generateKeyPair("ES256", { extractable: true });
  const keyPath = join(tmpdir(), `apple-secret-${process.pid}.p8`);
  writeFileSync(keyPath, await exportPKCS8(privateKey));
  const env = { APPLE_PRIVATE_KEY_PATH: keyPath, APPLE_KEY_ID: "KEYCACHE", APPLE_TEAM_ID: "TEAM45", AUTH_APPLE_ID: "com.marracat.web" };
  const now = Date.UTC(2026, 10, 12, 12);
  const first = await appleClientSecret(env, now);
  const { payload, protectedHeader } = await jwtVerify(first, publicKey, { currentDate: new Date(now) });
  assert.equal(protectedHeader.kid, "KEYCACHE");
  assert.equal(payload.aud, "https://appleid.apple.com");
  assert.equal(payload.exp - payload.iat, 3600);
  writeFileSync(keyPath, "gone");  // a reuse never touches the disk
  assert.equal(await appleClientSecret(env, now + APPLE_SECRET_REUSE_MS - 1000), first);
  await assert.rejects(appleClientSecret(env, now + APPLE_SECRET_REUSE_MS + 1000), "after 45 minutes it is signed again, from the key");
});
