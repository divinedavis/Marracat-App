// Short-lived MapKit JS tokens for address autocomplete on the checkout
// details form (owner, 2026-10-04: "as users type, they should get autofill
// and autofill should fill in the remaining address details").
//
// MapKit JS is free up to 25,000 service calls a day. It needs a key with
// "MapKit JS" enabled, made once in the Apple Developer portal (Keys) — it is
// not the Sign in with Apple key. Until MAPKIT_KEY_ID and
// MAPKIT_PRIVATE_KEY_PATH are set, the route answers 404 and the form stays a
// plain form with the browser's own autofill.
import { SignJWT, importPKCS8 } from "jose";
import { readFileSync } from "node:fs";
import { rateLimit } from "express-rate-limit";

const LIFETIME_S = 30 * 60;

export function mapkitConfigured(env) {
  return !!(env.MAPKIT_KEY_ID && env.MAPKIT_PRIVATE_KEY_PATH && env.APPLE_TEAM_ID);
}

// One token serves everyone for REUSE_S, leaving each holder at least ten
// minutes of its thirty. Until 2026-11-12 every request read the key from
// disk and signed a new one.
export const REUSE_S = 20 * 60;
let made = null;
export async function mapkitToken(env, now = Date.now()) {
  const iat = Math.floor(now / 1000);
  const id = `${env.MAPKIT_PRIVATE_KEY_PATH}|${env.MAPKIT_KEY_ID}|${env.APPLE_TEAM_ID}|${env.MAPKIT_ORIGIN || ""}`;
  if (made && made.id === id && iat >= made.iat && iat - made.iat < REUSE_S) return made.token;
  const key = await importPKCS8(readFileSync(env.MAPKIT_PRIVATE_KEY_PATH, "utf8"), "ES256");
  // The origin claim pins the token to the site, so a copied token can't run
  // MapKit (and spend the daily quota) from anywhere else.
  const token = await new SignJWT({ origin: env.MAPKIT_ORIGIN || "https://marracat.com" })
    .setProtectedHeader({ alg: "ES256", kid: env.MAPKIT_KEY_ID, typ: "JWT" })
    .setIssuer(env.APPLE_TEAM_ID)
    .setIssuedAt(iat)
    .setExpirationTime(iat + LIFETIME_S)
    .sign(key);
  made = { id, iat, token };
  return token;
}

export function mapkitRoutes(app, { env = process.env } = {}) {
  app.get(
    "/api/mapkit-token",
    rateLimit({ windowMs: 60_000, limit: 20, standardHeaders: "draft-8", legacyHeaders: false }),
    async (_req, res) => {
      if (!mapkitConfigured(env)) return res.sendStatus(404);
      try {
        res.set("Cache-Control", "no-store").type("text/plain").send(await mapkitToken(env));
      } catch {
        res.sendStatus(503);
      }
    },
  );
}
