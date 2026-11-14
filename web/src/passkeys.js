// The page's side of passkeys (server/passkeys.js): ask the device to make or
// use one, and pass what it signed to the server. Every byte field travels as
// base64url.
const b64u = (buffer) => btoa(String.fromCharCode(...new Uint8Array(buffer))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const bytes = (value) => Uint8Array.from(atob(value.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
const post = (url, body) => fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: body ? JSON.stringify(body) : undefined });

/// Can this browser make and use passkeys?
export const passkeysSupported = () => typeof window !== "undefined" && !!window.PublicKeyCredential && !!navigator.credentials?.create;

/// Make a passkey for the signed-in account. Resolves "added", "cancelled"
/// (the shopper closed the device's sheet) or throws with a message.
export async function addPasskey() {
  const r = await post("/api/passkeys/register/options");
  if (!r.ok) throw Error("Couldn't start. Please try again.");
  const o = await r.json();
  let credential;
  try {
    credential = await navigator.credentials.create({
      publicKey: {
        ...o,
        challenge: bytes(o.challenge),
        user: { ...o.user, id: bytes(o.user.id) },
        excludeCredentials: o.excludeCredentials.map((c) => ({ ...c, id: bytes(c.id) })),
      },
    });
  } catch (e) {
    if (e?.name === "InvalidStateError") throw Error("This device already has a passkey for your account.");
    if (e?.name === "NotAllowedError" || e?.name === "AbortError") return "cancelled";
    throw Error("This device couldn't make a passkey.");
  }
  const response = credential.response;
  const publicKey = response.getPublicKey?.();
  if (!publicKey) throw Error("This browser can't add passkeys yet. Try the latest Safari, Chrome, Edge or Firefox.");
  const saved = await post("/api/passkeys/register", {
    id: credential.id,
    clientDataJSON: b64u(response.clientDataJSON),
    authenticatorData: b64u(response.getAuthenticatorData()),
    publicKey: b64u(publicKey),
    publicKeyAlgorithm: response.getPublicKeyAlgorithm(),
    transports: response.getTransports?.() || [],
  });
  if (!saved.ok) throw Error((await saved.json().catch(() => null))?.error || "That passkey couldn't be added.");
  return "added";
}

/// Sign in with a passkey this device holds for marracat.com. Resolves the
/// address to go to, "cancelled", or throws.
export async function signInWithPasskey() {
  const r = await post("/api/passkeys/login/options");
  if (!r.ok) throw Error("Couldn't start. Please try again.");
  const o = await r.json();
  let credential;
  try {
    credential = await navigator.credentials.get({ publicKey: { ...o, challenge: bytes(o.challenge) } });
  } catch (e) {
    if (e?.name === "NotAllowedError" || e?.name === "AbortError") return "cancelled";
    throw Error("This device couldn't use a passkey.");
  }
  const response = credential.response;
  const assertion = JSON.stringify({
    id: credential.id,
    clientDataJSON: b64u(response.clientDataJSON),
    authenticatorData: b64u(response.authenticatorData),
    signature: b64u(response.signature),
  });
  const { csrfToken } = await fetch("/auth/csrf").then((x) => x.json());
  const signed = await fetch("/auth/callback/passkey", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded", "X-Auth-Return-Redirect": "1" },
    body: new URLSearchParams({ csrfToken, assertion, callbackUrl: location.origin + "/account" }),
  });
  const { url } = await signed.json().catch(() => ({}));
  if (!url || /[?&]error=/.test(url)) throw Error("That passkey isn't on a Marracat account. Sign in another way, then add it on your account page.");
  return url;
}
