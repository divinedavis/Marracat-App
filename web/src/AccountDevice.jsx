import React, { useEffect, useState } from "react";
import { Bell, BellRing, KeyRound } from "lucide-react";
import { addPasskey, passkeysSupported } from "./passkeys";

// "On this device" on the account page (owner, 2026-11-10): notifications and
// passkeys. Notifications:
// the price-drop, sale and new-arrival alerts a shopper follows, shown by
// this browser (server/web-push.js) as well as emailed. Nothing here asks
// for permission until the button is pressed.

const keyBytes = (b64u) => Uint8Array.from(atob(b64u.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
const post = (method, body) => fetch("/api/push/subscribe", { method, headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });

/// "on" | "off" | "blocked" (the browser was told no) | "install" (an iPhone
/// or iPad, where a site must be on the Home Screen first) | "none" (this
/// browser can't, or the server has no keys).
export async function notificationState() {
  const key = await fetch("/api/push/key").then((r) => (r.ok ? r.json() : null)).catch(() => null);
  if (!key?.key) return { state: "none" };
  const can = "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
  if (!can) {
    const ios = /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
    return { state: ios && !navigator.standalone ? "install" : "none" };
  }
  if (Notification.permission === "denied") return { state: "blocked", key: key.key };
  const registration = await navigator.serviceWorker.getRegistration();
  const subscription = await registration?.pushManager.getSubscription();
  return { state: subscription && Notification.permission === "granted" ? "on" : "off", key: key.key, subscription };
}

export function NotificationsSetting({ toast }) {
  const [state, setState] = useState(null);
  const [busy, setBusy] = useState(false);
  const refresh = () => notificationState().then((s) => {
    setState(s);
    // The server may have forgotten this browser (a restore, another account
    // since): tell it again, quietly.
    if (s.state === "on") post("POST", s.subscription.toJSON()).catch(() => {});
  });
  useEffect(() => {
    refresh();
  }, []);
  if (!state || state.state === "none") return null;
  const turnOn = async () => {
    setBusy(true);
    try {
      if ((await Notification.requestPermission()) !== "granted") return refresh();
      const registration = await navigator.serviceWorker.ready;
      const subscription = await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes(state.key) });
      const r = await post("POST", subscription.toJSON());
      if (!r.ok) {
        await subscription.unsubscribe().catch(() => {});
        throw Error();
      }
      toast("Notifications are on for this browser");
    } catch {
      toast("Couldn't turn notifications on. Try again.");
    } finally {
      setBusy(false);
      refresh();
    }
  };
  const turnOff = async () => {
    setBusy(true);
    try {
      const body = state.subscription.toJSON();
      await state.subscription.unsubscribe();
      await post("DELETE", body).catch(() => {});
      toast("Notifications are off for this browser");
    } finally {
      setBusy(false);
      refresh();
    }
  };
  return (
    <div className="device-setting" data-setting="notifications" data-state={state.state}>
      <div>
        <strong>Notifications</strong>
        <p>
          {state.state === "on" && "Price drops, sales and new arrivals you follow show up in this browser."}
          {state.state === "off" && "Get price drops, sales and new arrivals you follow in this browser, as well as by email."}
          {state.state === "blocked" && "This browser is set to block notifications from Marracat. Allow them in its site settings, then come back."}
          {state.state === "install" && "On iPhone and iPad, add Marracat to your Home Screen (Share, then Add to Home Screen) and open it from there to turn notifications on."}
        </p>
      </div>
      {(state.state === "on" || state.state === "off") && (
        <button className="outline-button" type="button" disabled={busy} aria-pressed={state.state === "on"} onClick={state.state === "on" ? turnOff : turnOn}>
          {state.state === "on" ? <BellRing size={16} /> : <Bell size={16} />} {state.state === "on" ? "On" : "Turn on"}
        </button>
      )}
    </div>
  );
}

const when = (ms) => new Date(ms).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });

/// Passkeys on the account (server/passkeys.js): sign in with Face ID, Touch
/// ID, Windows Hello or a phone instead of Google, Apple or an emailed code.
export function PasskeysSetting({ toast }) {
  const [list, setList] = useState(null);
  const [busy, setBusy] = useState(false);
  const load = () => fetch("/api/passkeys").then((r) => (r.ok ? r.json() : null)).then((d) => setList(d?.passkeys ?? null)).catch(() => setList(null));
  useEffect(() => {
    if (passkeysSupported()) load();
  }, []);
  if (!passkeysSupported() || !list) return null;
  const add = async () => {
    setBusy(true);
    try {
      if ((await addPasskey()) === "added") {
        toast("Passkey added. Next time, sign in with it.");
        await load();
      }
    } catch (e) {
      toast(e.message);
    } finally {
      setBusy(false);
    }
  };
  const remove = async (id) => {
    setBusy(true);
    const r = await fetch("/api/passkeys/" + encodeURIComponent(id), { method: "DELETE" }).catch(() => null);
    setBusy(false);
    if (!r?.ok) return toast("Couldn't remove that passkey. Try again.");
    toast("Passkey removed. Delete it from your device's passwords too.");
    load();
  };
  return (
    <div className="device-setting passkeys-setting" data-setting="passkeys">
      <div>
        <strong>Passkeys</strong>
        <p>
          {list.length
            ? "Sign in with your face, fingerprint or device PIN."
            : "Sign in with your face, fingerprint or device PIN instead of Google, Apple or an emailed code."}
        </p>
        {list.length > 0 && (
          <ul className="passkey-list">
            {list.map((k) => (
              <li key={k.id}>
                <span>
                  {k.name || "Passkey"} · added {when(k.created)}
                  {k.lastUsed ? ` · last used ${when(k.lastUsed)}` : ""}
                </span>
                <button className="text-button" type="button" disabled={busy} onClick={() => remove(k.id)} aria-label={`Remove passkey ${k.name || ""}`}>
                  Remove
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>
      <button className="outline-button" type="button" disabled={busy} onClick={add}>
        <KeyRound size={16} /> {list.length ? "Add another" : "Add a passkey"}
      </button>
    </div>
  );
}

export default function AccountDevice({ toast }) {
  return (
    <section className="account-device" aria-label="On this device">
      <h2>On this device</h2>
      <NotificationsSetting toast={toast} />
      <PasskeysSetting toast={toast} />
    </section>
  );
}
