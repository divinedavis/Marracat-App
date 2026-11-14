import React, { useEffect, useState } from "react";
import { X } from "lucide-react";

// "Shop this in the app" on product and brand pages, for iPhone and iPad
// visitors only (owner, 2026-10-10: two thirds of website visits are iPhones,
// and the app is faster). A slim row in the page, never a popup on entry
// (owner rule: no unsolicited prompts). Dismissing it, or the app banner,
// keeps it gone in this browser.
//
// Opening the very product in the app: a link from marracat.com to
// marracat.com never opens an app (iOS keeps same-site taps in the browser),
// so the deep link rides Safari's own Smart App Banner, whose app-argument the
// server sets to this page's /p/ address (server/share-page.js) and the app
// opens (MarracatApp.openProductLink). This row's button goes to the App
// Store, which offers Open when the app is installed.
export const PROMPT_KEY = "marracat.appPrompt";

export function isAppleMobile(ua = navigator.userAgent, touch = navigator.maxTouchPoints) {
  return /iPhone|iPod/.test(ua) || (/iPad|Macintosh/.test(ua) && touch > 1);
}

function wasDismissed() {
  try {
    return localStorage.getItem(PROMPT_KEY) === "dismissed" || localStorage.getItem("marracat.appBanner") === "dismissed";
  } catch {
    return false;
  }
}

let appInfo = null; // one /api/ios-app answer per page load
function liveApp() {
  appInfo ||= fetch("/api/ios-app").then((r) => (r.ok ? r.json() : null)).catch(() => null);
  return appInfo;
}

export default function AppPrompt({ kind, name, hasApp = false }) {
  const [app, setApp] = useState(null);
  const [dismissed, setDismissed] = useState(wasDismissed);
  const show = typeof navigator !== "undefined" && isAppleMobile() && !dismissed;
  useEffect(() => {
    if (!show) return;
    let live = true;
    liveApp().then((body) => live && body?.live && setApp(body));
    return () => {
      live = false;
    };
  }, [show]);
  if (!show || !app) return null;
  const close = () => {
    setDismissed(true);
    try {
      localStorage.setItem(PROMPT_KEY, "dismissed");
    } catch {
      /* private browsing: it comes back next visit */
    }
  };
  return (
    <aside className="app-prompt" data-testid="app-prompt" aria-label="Marracat app">
      <img className="app-prompt-icon" src="/apple-touch-icon.png" alt="" width="36" height="36" />
      <div className="app-prompt-copy">
        <strong>{kind === "brand" ? `Shop ${name} in the app` : "Shop this in the app"}</strong>
        <span>Faster, with price alerts.</span>
      </div>
      <a className="app-prompt-open" href={app.url} target="_blank" rel="noopener noreferrer">
        {hasApp ? "Open app" : "Get the app"}
      </a>
      <button type="button" className="app-prompt-close" onClick={close} aria-label="Dismiss app suggestion">
        <X size={16} />
      </button>
    </aside>
  );
}
