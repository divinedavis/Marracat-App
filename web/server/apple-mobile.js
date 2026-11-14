import { readFileSync } from "node:fs";
import { createRemoteJWKSet, importPKCS8, jwtVerify, SignJWT } from "jose";

const appleKeys = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"));
const validText = (v, max = 12000) => typeof v === "string" && v.length > 0 && v.length <= max;
const unavailable = () => Object.assign(new Error("Apple sign-in is unavailable"), { status: 503 });

export async function verifyAppleToken(token, nonce, env = process.env, keys = appleKeys) {
  if (!env.APPLE_IOS_CLIENT_ID) throw unavailable();
  if (!validText(token) || !/^[a-f0-9]{64}$/.test(nonce || "")) throw new Error("Invalid Apple identity");
  const { payload } = await jwtVerify(token, keys, {
    issuer: "https://appleid.apple.com", audience: env.APPLE_IOS_CLIENT_ID,
    algorithms: ["RS256"], requiredClaims: ["sub", "exp", "iat", "nonce"], maxTokenAge: "5m", clockTolerance: 5,
  });
  if (!validText(payload.sub, 200) || payload.nonce !== nonce) throw new Error("Invalid Apple identity");
  if (payload.email != null && (!validText(payload.email, 320) || ![true, "true"].includes(payload.email_verified)))
    throw new Error("Unverified Apple email");
  return { id: `apple:${payload.sub}`, name: null, email: payload.email ?? null };
}

export function appleMobileAuth(env = process.env, { keys = appleKeys, fetcher = fetch } = {}) {
  let signingKey;
  const configured = () => Boolean(env.APPLE_IOS_CLIENT_ID && env.APPLE_TEAM_ID && env.APPLE_KEY_ID && env.APPLE_PRIVATE_KEY_PATH);
  async function clientSecret() {
    if (!configured()) throw unavailable();
    signingKey ??= importPKCS8(readFileSync(env.APPLE_PRIVATE_KEY_PATH, "utf8"), "ES256");
    return new SignJWT({}).setProtectedHeader({ alg: "ES256", kid: env.APPLE_KEY_ID })
      .setIssuer(env.APPLE_TEAM_ID).setSubject(env.APPLE_IOS_CLIENT_ID)
      .setAudience("https://appleid.apple.com").setIssuedAt().setExpirationTime("5m").sign(await signingKey);
  }
  async function post(endpoint, parameters) {
    const response = await fetcher(`https://appleid.apple.com/auth/${endpoint}`, {
      method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ client_id: env.APPLE_IOS_CLIENT_ID, client_secret: await clientSecret(), ...parameters }),
      signal: AbortSignal.timeout(12000), redirect: "error",
    });
    if (!response.ok) throw new Error("Apple authorization failed");
    return response;
  }
  return {
    configured,
    async authorize(body, nonce) {
      if (!validText(body?.authorizationCode, 4000)) throw new Error("Missing Apple authorization code");
      const user = await verifyAppleToken(body.idToken, nonce, env, keys);
      const response = await post("token", { code: body.authorizationCode, grant_type: "authorization_code" });
      const tokens = await response.json();
      const exchanged = await verifyAppleToken(tokens.id_token, nonce, env, keys);
      if (exchanged.id !== user.id || !validText(tokens.refresh_token, 12000)) throw new Error("Mismatched Apple authorization");
      // The name is optional, user-provided display text. Identity and email come only from Apple's signed token.
      user.name = typeof body.name === "string" ? body.name.trim().slice(0, 100) || null : null;
      return { user, refreshToken: tokens.refresh_token };
    },
    async revoke(refreshToken) {
      // Account deletion reauthenticates to obtain a fresh code/token. No Apple refresh token is retained in our database.
      await post("revoke", { token: refreshToken, token_type_hint: "refresh_token" });
    },
  };
}
