// This browser's end-to-end encryption key, one per signed-in account.
//
// The private key is generated non-extractable and kept in IndexedDB as a
// CryptoKey object, so page scripts can use it to open shares but never read
// its bytes. Only the public half is sent to the server (POST /devices).
// Signing out forgets it here and unregisters it there, which means shares sent
// to this browser can't be opened again afterwards; that is the price of the
// server never holding a key.

import { generateDeviceKey, exportPublic } from "./e2ee.js";

const DB = "marracat-keys";
const STORE = "devices";

function idb() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB, 1);
    request.onupgradeneeded = () => request.result.createObjectStore(STORE);
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}
async function run(mode, action) {
  const db = await idb();
  return new Promise((resolve, reject) => {
    const request = action(db.transaction(STORE, mode).objectStore(STORE));
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}
const read = (userID) => run("readonly", (s) => s.get(userID));
const write = (userID, record) => run("readwrite", (s) => s.put(record, userID));
const remove = (userID) => run("readwrite", (s) => s.delete(userID));

/** This browser's device for `userID`, registering one if there isn't one yet. */
export async function ensureDevice(userID, api) {
  const existing = await read(userID).catch(() => null);
  if (existing?.deviceId && existing.privateKey) return existing;
  const pair = await generateDeviceKey();
  const publicKey = await exportPublic(pair.publicKey);
  const { device_id } = await api("devices", { method: "POST", body: { public_key: publicKey } });
  const record = { deviceId: device_id, privateKey: pair.privateKey, publicKey };
  await write(userID, record);
  return record;
}

/** A fresh key for this browser, when the old one is gone from the server. */
export async function replaceDevice(userID, api) {
  await remove(userID).catch(() => {});
  return ensureDevice(userID, api);
}

/** Unregister and forget this browser's key; used when signing out. */
export async function forgetDevice(userID, api) {
  const existing = await read(userID).catch(() => null);
  if (!existing) return;
  try {
    await api(`devices/${encodeURIComponent(existing.deviceId)}`, { method: "DELETE" });
  } catch {}
  await remove(userID).catch(() => {});
}
