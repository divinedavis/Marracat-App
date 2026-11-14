// Address suggestions for the checkout details form, from Apple Maps (MapKit
// JS; owner, 2026-10-04). MapKit loads only when someone starts typing a
// street, and only if the server has a MapKit key (/api/mapkit-token answers
// 404 otherwise, and the form keeps the browser's own autofill).

// The full bundle (237 KB): the "core" build never fetched its services
// library when added from script, and reading mapkit.Search before that
// library arrives throws (measured 2026-10-04).
const MAPKIT_URL = "https://cdn.apple-mapkit.com/mk/5.x.x/mapkit.js";
let ready = null;

/// The details form's fields from a MapKit Place. The apartment line is not
/// in Apple's answer, so it's left to the shopper.
export function placeToAddress(place) {
  if (!place) return null;
  const street =
    place.fullThoroughfare ||
    [place.subThoroughfare, place.thoroughfare].filter(Boolean).join(" ");
  return {
    street: street || "",
    city: place.locality || place.subLocality || "",
    region: place.administrativeAreaCode || place.administrativeArea || "",
    postalCode: place.postCode || "",
    country: place.countryCode || "",
  };
}

/// Loads MapKit once; resolves to a mapkit.Search, or null when maps are off.
export function loadSearch() {
  if (ready) return ready;
  ready = (async () => {
    const probe = await fetch("/api/mapkit-token").catch(() => null);
    if (!probe?.ok) return null;
    const first = await probe.text();
    await new Promise((resolve, reject) => {
      const s = document.createElement("script");
      s.src = MAPKIT_URL;
      s.crossOrigin = "anonymous";
      s.onload = resolve;
      s.onerror = reject;
      document.head.appendChild(s);
    });
    const mk = window.mapkit;
    let token = first;
    mk.init({
      // The first token is the probe's; later ones (every 30 minutes) are fresh.
      authorizationCallback: (done) => {
        if (token) {
          done(token);
          token = null;
          return;
        }
        fetch("/api/mapkit-token").then((r) => r.text()).then(done);
      },
      language: "en-US",
    });
    return new mk.Search({ language: "en-US", includePointsOfInterest: false });
  })().catch(() => {
    ready = null; // a failed load (offline, blocked) can be retried later
    return null;
  });
  return ready;
}

/// Up to five suggestions for what's typed: [{ label, sub, result }].
export async function suggest(query) {
  const q = query.trim();
  if (q.length < 3) return [];
  const search = await loadSearch();
  if (!search) return [];
  return new Promise((resolve) => {
    search.autocomplete(q, (error, data) => {
      if (error || !data) return resolve([]);
      resolve(
        (data.results || []).slice(0, 5).map((result) => ({
          label: result.displayLines?.[0] || "",
          sub: result.displayLines?.slice(1).join(", ") || "",
          result,
        })),
      );
    });
  });
}

/// The full address behind a suggestion, US only; null otherwise.
export async function resolveSuggestion(suggestion) {
  const search = await loadSearch();
  if (!search) return null;
  return new Promise((resolve) => {
    search.search(suggestion.result, (error, data) => {
      const found = !error && placeToAddress(data?.places?.[0]);
      resolve(found && (!found.country || found.country === "US") ? found : null);
    });
  });
}
