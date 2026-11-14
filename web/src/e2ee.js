// End-to-end encryption for products shared between friends.
//
// Every device holds its own P-256 key pair; the private half never leaves it.
// To send, the sender makes a fresh ephemeral key pair per recipient device,
// agrees a secret with that device's public key (ECDH), stretches it with
// HKDF-SHA256 into an AES-256-GCM key, and seals the message. The server only
// ever sees public keys and ciphertext.
//
//   salt = ephemeral public key (65 bytes) || recipient public key (65 bytes)
//   info = "marracat-share-v1"
//   plaintext = JSON with sorted keys: {"note":"…","product_id":"…"}
//   ciphertext = AES-GCM output with its 16-byte tag appended
//
// The iPhone app's ShareCrypto.swift implements the same thing with CryptoKit,
// and tests/e2ee.test.js plus the app's ShareCryptoTests pin both to one test
// vector, so a share sealed on either opens on the other.
//
// Plain WebCrypto only, so it runs unchanged in the browser and in Node tests.

const enc = new TextEncoder();
const dec = new TextDecoder();
const INFO = enc.encode("marracat-share-v1");
const CURVE = { name: "ECDH", namedCurve: "P-256" };

export function toB64(bytes) {
  let s = "";
  for (const b of new Uint8Array(bytes)) s += String.fromCharCode(b);
  return btoa(s);
}
export function fromB64(text) {
  const s = atob(text);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}
const concat = (a, b) => {
  const out = new Uint8Array(a.length + b.length);
  out.set(a);
  out.set(b, a.length);
  return out;
};

/** A new device key pair. The private key can be used but never exported, so
 * a script injected into the page later can't carry it away. */
export function generateDeviceKey() {
  return crypto.subtle.generateKey(CURVE, false, ["deriveBits"]);
}
export async function exportPublic(publicKey) {
  return toB64(await crypto.subtle.exportKey("raw", publicKey));
}
function importPublic(b64) {
  return crypto.subtle.importKey("raw", fromB64(b64), CURVE, true, []);
}

async function messageKey(privateKey, peerPublic, ephemeralRaw, recipientRaw) {
  const shared = await crypto.subtle.deriveBits({ name: "ECDH", public: peerPublic }, privateKey, 256);
  const hkdf = await crypto.subtle.importKey("raw", shared, "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: concat(ephemeralRaw, recipientRaw), info: INFO },
    hkdf,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

/** The exact bytes sealed: sorted keys, so every platform produces the same
 * plaintext for the same message. */
export function plaintext({ product_id, note = "" }) {
  return enc.encode(JSON.stringify({ note: String(note), product_id: String(product_id) }));
}

/** Seal `message` for one device. `ephemeral` and `nonce` are only passed by
 * tests, to reproduce the shared test vector. */
export async function seal(recipientPublicB64, message, { ephemeral, nonce } = {}) {
  const recipientRaw = fromB64(recipientPublicB64);
  if (recipientRaw.length !== 65 || recipientRaw[0] !== 4) throw new Error("Invalid device key");
  const recipient = await importPublic(recipientPublicB64);
  const eph = ephemeral ?? (await crypto.subtle.generateKey(CURVE, true, ["deriveBits"]));
  const ephemeralRaw = new Uint8Array(await crypto.subtle.exportKey("raw", eph.publicKey));
  const key = await messageKey(eph.privateKey, recipient, ephemeralRaw, recipientRaw);
  const iv = nonce ?? crypto.getRandomValues(new Uint8Array(12));
  const sealed = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, plaintext(message));
  return { ephemeral_key: toB64(ephemeralRaw), nonce: toB64(iv), ciphertext: toB64(sealed) };
}

/** Open an envelope sealed for this device. Throws if it was tampered with. */
export async function open(devicePrivate, devicePublicB64, envelope) {
  const ephemeralRaw = fromB64(envelope.ephemeral_key);
  const key = await messageKey(devicePrivate, await importPublic(envelope.ephemeral_key), ephemeralRaw, fromB64(devicePublicB64));
  const bytes = await crypto.subtle.decrypt({ name: "AES-GCM", iv: fromB64(envelope.nonce) }, key, fromB64(envelope.ciphertext));
  const m = JSON.parse(dec.decode(bytes));
  return { product_id: String(m.product_id ?? ""), note: typeof m.note === "string" ? m.note : "" };
}

/** Seal one message for every device of every recipient, in the shape
 * POST /api/social/shares takes. `keys` is GET /api/social/keys's answer. */
export async function sealForFriends(keys, handles, message) {
  const messages = [];
  const unreachable = [];
  for (const handle of handles) {
    const devices = keys[handle] || [];
    if (!devices.length) {
      unreachable.push(handle);
      continue;
    }
    messages.push({
      to: handle,
      envelopes: await Promise.all(devices.map(async (d) => ({ device_id: d.device_id, ...(await seal(d.public_key, message)) }))),
    });
  }
  return { messages, unreachable };
}
