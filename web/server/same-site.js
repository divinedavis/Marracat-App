// A signed-in browser's cookie rides along on any request to marracat.com,
// including one another site makes it send. Every request that changes
// something with that cookie must therefore come from our own pages.
//
// social.js checked this for /api/social alone; the account, cart, alerts,
// passkey, notification, boost and brand-claim routes had no check
// (2026-11-12). The session cookie is SameSite=Lax, which already stops most
// cross-site posts, so this is the second lock, in one place.
//
// The app is untouched: it signs in with a bearer token and sends no cookie.
// /auth is Auth.js's own (its CSRF token; Apple's sign-in posts back from
// appleid.apple.com).
const SAFE = new Set(["GET", "HEAD", "OPTIONS"]);
const LOCAL = /^https?:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/;

/// Whether the request was made by one of our own pages. Browsers put Origin
/// on every non-GET fetch and form post, and Sec-Fetch-Site on all requests
/// (Safari from 16.4); a request with neither is not a page of ours.
export function fromOurPages(req, env = process.env) {
  const site = env.PUBLIC_URL || "https://marracat.com";
  const origin = req.get("Origin");
  if (origin) return origin === site || (env.NODE_ENV !== "production" && LOCAL.test(origin));
  return req.get("Sec-Fetch-Site") === "same-origin";
}

export const hasSessionCookie = (req) => /(?:^|;\s*)(?:__Secure-)?authjs\.session-token(?:\.\d+)?=/.test(req.get("Cookie") || "");

export function sameSiteWrites(env = process.env) {
  return (req, res, next) => {
    if (SAFE.has(req.method) || req.path.startsWith("/auth/") || !hasSessionCookie(req)) return next();
    if (fromOurPages(req, env)) return next();
    res.status(403).json({ error: "Request refused" });
  };
}
