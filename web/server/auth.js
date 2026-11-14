import { isOwnerEmail } from "./owner-metrics.js";
import { accountFor } from "./identities.js";
import Google from "@auth/express/providers/google";
import Apple from "@auth/express/providers/apple";
import Credentials from "@auth/express/providers/credentials";
import { normalEmail, checkCode } from "./email-code.js";
import { verifyAssertion } from "./passkeys.js";
import { SignJWT, importPKCS8 } from "jose";
import { readFileSync } from "node:fs";
import { newSession, sessionLive, revokeSession } from "./web-sessions.js";
export function authStatus(env = process.env) {
  return {
    // A 6-digit code by email (email-code.js) needs the mailbox it sends from.
    email: Boolean(env.RELAY_SMTP_HOST && env.RELAY_SMTP_USER && env.RELAY_SMTP_PASS),
    // A passkey (passkeys.js) needs nothing configured.
    passkey: true,
    google: Boolean(env.AUTH_GOOGLE_ID && env.AUTH_GOOGLE_SECRET),
    apple: Boolean(
      env.AUTH_APPLE_ID &&
      env.APPLE_TEAM_ID &&
      env.APPLE_KEY_ID &&
      env.APPLE_PRIVATE_KEY_PATH,
    ),
  };
}
/// Whether this account is signed in on the iPhone/iPad app right now: the
/// app's sign-in opens the same account (identities.js), so an unexpired app
/// session means the app is installed. A browser can't see installed apps,
/// so this is how the site hides "Get the app" from those who have it.
export function hasAppSession(db, userID) {
  try {
    return !!db.prepare("SELECT 1 FROM mobile_sessions WHERE user_id=? AND expires>? LIMIT 1").get(userID, Date.now());
  } catch {
    return false; // no mobile_sessions table yet
  }
}

// Apple's client secret is a one-hour token signed with our key. It is made
// once and reused for 45 minutes: every signed-in website request builds this
// config (social.js viewerOf), and until 2026-11-12 each one read the key
// from disk and signed a new token.
export const APPLE_SECRET_REUSE_MS = 45 * 60_000;
let appleSecret = null;
export async function appleClientSecret(env, now = Date.now()) {
  const id = `${env.APPLE_PRIVATE_KEY_PATH}|${env.APPLE_KEY_ID}|${env.APPLE_TEAM_ID}|${env.AUTH_APPLE_ID}`;
  if (appleSecret && appleSecret.id === id && now - appleSecret.made < APPLE_SECRET_REUSE_MS) return appleSecret.value;
  const key = await importPKCS8(readFileSync(env.APPLE_PRIVATE_KEY_PATH, "utf8"), "ES256");
  const iat = Math.floor(now / 1000);
  const value = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: env.APPLE_KEY_ID })
    .setIssuer(env.APPLE_TEAM_ID)
    .setAudience("https://appleid.apple.com")
    .setSubject(env.AUTH_APPLE_ID)
    .setIssuedAt(iat)
    .setExpirationTime(iat + 3600)
    .sign(key);
  appleSecret = { id, made: now, value };
  return value;
}

export async function createAuthConfig(db, env = process.env) {
  const secure = env.NODE_ENV === "production";
  if (!env.AUTH_SECRET || env.AUTH_SECRET.length < 32)
    throw new Error("AUTH_SECRET must be at least 32 characters");
  const status = authStatus(env),
    providers = [];
  if (status.google)
    providers.push(
      Google({
        clientId: env.AUTH_GOOGLE_ID,
        clientSecret: env.AUTH_GOOGLE_SECRET,
      }),
    );
  if (status.apple) {
    const clientSecret = await appleClientSecret(env);
    providers.push(
      Apple({
        clientId: env.AUTH_APPLE_ID,
        clientSecret,
        checks: ["state", "nonce"],
      }),
    );
  }
  if (status.email)
    providers.push(
      Credentials({
        id: "email",
        name: "Email",
        credentials: { email: {}, code: {} },
        // The account is the address the code was sent to.
        authorize: async (input) => {
          const email = normalEmail(input?.email);
          if (!email || !checkCode(db, email, input?.code, { secret: env.AUTH_SECRET })) return null;
          return { id: email, email, name: null };
        },
      }),
    );
  // A passkey: the device signed our challenge with a key kept for an account
  // (passkeys.js). The identity "passkey:<credential id>" is linked to it.
  providers.push(
    Credentials({
      id: "passkey",
      name: "Passkey",
      credentials: { assertion: {} },
      authorize: async (input) => {
        let assertion;
        try {
          assertion = JSON.parse(String(input?.assertion ?? ""));
        } catch {
          return null;
        }
        const id = verifyAssertion(db, assertion);
        return id ? { id, email: null, name: null } : null;
      },
    }),
  );
  return {
    secret: env.AUTH_SECRET,
    trustHost: true,
    basePath: "/auth",
    providers,
    useSecureCookies: secure,
    session: { strategy: "jwt", maxAge: 30 * 24 * 60 * 60 },
    pages: { signIn: "/signin", error: "/signin" },
    ...(secure
      ? {
          cookies: {
            state: {
              name: "__Secure-authjs.state",
              options: {
                httpOnly: true,
                sameSite: "none",
                secure: true,
                path: "/",
                maxAge: 900,
              },
            },
            nonce: {
              name: "__Secure-authjs.nonce",
              options: {
                httpOnly: true,
                sameSite: "none",
                secure: true,
                path: "/",
                maxAge: 900,
              },
            },
          },
        }
      : {}),
    callbacks: {
      async jwt({ token, account, user, profile }) {
        if (account && user) {
          // One account per person, as in the app (identities.js): a sign-in
          // whose verified email matches an account opens that account.
          const identity = `${account.provider}:${account.providerAccountId}`;
          // Only an address the provider verified is kept (audit 2026-11-04).
          // An unverified one stored here was later matched by another
          // person's verified sign-in (identities.js step 3), which would
          // have opened this account to them, and it was where order mail
          // and alert emails went.
          // An email code proves the address as a provider's check does.
          const emailVerified = account.provider === "email" || [true, "true"].includes(profile?.email_verified);
          const email = emailVerified ? user.email || null : null;
          token.sub = accountFor(db, { id: identity, email, emailVerified });
          // The account's own name and email win over a linked sign-in's.
          db.prepare(
            token.sub === identity
              ? "INSERT INTO users (id, name, email) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET name=COALESCE(excluded.name,users.name),email=COALESCE(excluded.email,users.email)"
              : "INSERT INTO users (id, name, email) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET name=COALESCE(users.name,excluded.name),email=COALESCE(users.email,excluded.email)",
          ).run(token.sub, user.name || null, email);
          // A passkey brings no name or email: the account's own fill in.
          if (!token.name || !token.email) {
            const row = db.prepare("SELECT name, email FROM users WHERE id=?").get(token.sub);
            token.name ||= row?.name || null;
            token.email ||= row?.email || null;
          }
        }
        if (token.sub && !db.prepare("SELECT id FROM users WHERE id=?").get(token.sub)) return null;
        // A session that was signed out, or cut off when a passkey was
        // removed, is over even though its cookie hasn't expired
        // (web-sessions.js). A new sign-in starts a new one.
        if (account && user) Object.assign(token, newSession());
        else if (token.sub && !sessionLive(db, token)) return null;
        // A cookie from before 2026-11-12 gets an id on its next use; it keeps
        // no start time, so any cutoff still ends it.
        if (!token.sid) { token.sid = newSession().sid; token.since = Number(token.since) || 0; }
        return token;
      },
      async session({ session, token }) {
        if (session.user) {
          session.user.id = token.sub;
          // Which session this is, so removing a passkey can keep it open.
          session.user.sid = token.sid;
          // Lets the owner's own browser leave itself out of the dashboard's
          // visitor count. Only the owner's session ever carries it.
          if (isOwnerEmail(session.user.email)) session.user.owner = true;
          if (hasAppSession(db, token.sub)) session.user.hasApp = true;
        }
        return session;
      },
      async redirect({ url, baseUrl }) {
        if (url.startsWith("/") && !url.startsWith("//")) return baseUrl + url;
        try {
          if (new URL(url).origin === baseUrl) return url;
        } catch {}
        return baseUrl;
      },
    },
    events: {
      // Signing out ends the session itself, not just this browser's cookie.
      signOut(message) {
        if (message?.token?.sid) revokeSession(db, message.token.sid);
      },
    },
    logger: {
      error(error) {
        console.error("Authentication error:", error.type || error.name);
      },
    },
  };
}
