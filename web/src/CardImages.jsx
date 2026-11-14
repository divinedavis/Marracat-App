import React, { useSyncExternalStore } from "react";
import { ChevronLeft, ChevronRight } from "lucide-react";
import { productURL } from "./prefetch";

// A card's photo with arrows to click through the product's other photos
// (owner, 2026-11-09: "can we give buttons for people to click through the
// images of a product on a brand screen"). The catalog a grid is built from
// carries one photo per product, so the rest come from /api/products/:id,
// once per product per visit.
//
// Quick to cycle (owner, 2026-11-09: "it takes a while for the images to
// show"): the list is asked for as soon as the pointer is over the photo, the
// photos either side of the one showing are downloaded ahead, and an arrow
// keeps the current photo up until the next one is ready, never a blank.
const loaded = new Map();
export function productPhotos(id) {
  if (!loaded.has(id)) {
    loaded.set(
      id,
      fetch(productURL(id))
        .then((r) => (r.ok ? r.json() : null))
        .then((d) => (Array.isArray(d?.images) ? d.images.filter((x) => typeof x === "string") : []))
        .catch(() => {
          loaded.delete(id);
          return [];
        }),
    );
  }
  return loaded.get(id);
}

/// The card's own photo first, then the product's others in the brand's order.
export function photoList(first, all) {
  const rest = (all || []).filter((x) => x && x !== first);
  return first ? [first, ...rest] : rest;
}

// The card photo is drawn at about a third of a wide window and half a phone's.
export const SIZES = "(min-width: 1001px) 30vw, (min-width: 601px) 33vw, 50vw";
export const srcSet = (imageURL, u) => `${imageURL(u, 500)} 500w, ${imageURL(u, 900)} 900w`;

// One download per photo; the promise settles when it can be drawn.
const fetched = new Map();
function warm(imageURL, u) {
  if (!u) return Promise.resolve();
  if (!fetched.has(u)) {
    const img = new Image();
    img.decoding = "async";
    img.sizes = SIZES;
    img.srcset = srcSet(imageURL, u);
    img.src = imageURL(u);
    fetched.set(u, (img.decode ? img.decode() : Promise.resolve()).catch(() => {}));
  }
  return fetched.get(u);
}
const within = (ms) => new Promise((r) => setTimeout(r, ms));

// Which photo each product is on, kept outside the card: the storefront's
// cards are redrawn as new components whenever the page's state changes, and
// state inside the card would be lost (a click landing mid-redraw went
// nowhere, and the list was asked for again).
const NONE = { photos: null, at: 0 };
const states = new Map();
const listeners = new Set();
const stateOf = (id) => states.get(id) || NONE;
function update(id, patch) {
  states.set(id, { ...stateOf(id), ...patch });
  listeners.forEach((l) => l());
}
function subscribe(l) {
  listeners.add(l);
  return () => listeners.delete(l);
}

export default function CardImages({ p, href, imageURL }) {
  const first = p.images?.[0];
  const { photos, at } = useSyncExternalStore(subscribe, () => stateOf(p.id));
  const list = photos || (first ? [first] : []);
  const single = photos !== null && photos.length < 2;

  const around = (l, i) => {
    if (l.length < 2) return;
    warm(imageURL, l[(i + 1) % l.length]);
    warm(imageURL, l[(i - 1 + l.length) % l.length]);
  };
  const load = () => {
    const known = stateOf(p.id).photos;
    if (known) return Promise.resolve(known);
    return productPhotos(p.id).then((all) => {
      if (stateOf(p.id).photos) return stateOf(p.id).photos;
      const l = photoList(first, all);
      update(p.id, { photos: l });
      around(l, stateOf(p.id).at);
      return l;
    });
  };
  const step = (d) => (e) => {
    e.preventDefault();
    e.stopPropagation();
    load().then(async (l) => {
      if (l.length < 2) return;
      // Quick clicks each count: step from the photo last asked for.
      const from = stateOf(p.id).want ?? stateOf(p.id).at;
      const i = (from + d + l.length) % l.length;
      states.set(p.id, { ...stateOf(p.id), want: i });
      // Hold the current photo until the next can be drawn (at most 1.5 s).
      await Promise.race([warm(imageURL, l[i]), within(1500)]);
      if (stateOf(p.id).want !== i) return; // a later click took over
      update(p.id, { at: i, want: undefined });
      around(l, i);
    });
  };
  const shown = list[at] || first;

  return (
    <div className="card-photos" onPointerEnter={load}>
      <a href={href}>
        <img
          src={imageURL(shown)}
          srcSet={shown ? srcSet(imageURL, shown) : undefined}
          sizes={SIZES}
          alt={at ? `${p.title}, photo ${at + 1} of ${list.length}` : p.title}
          loading={at ? "eager" : "lazy"}
          onError={(e) => {
            e.currentTarget.onerror = null;
            e.currentTarget.removeAttribute("srcset");
            e.currentTarget.src = "/mark.svg";
          }}
        />
      </a>
      {!single && (
        <>
          <button
            type="button"
            className="card-photo-arrow is-prev"
            aria-label={`Previous photo of ${p.title}`}
            onPointerDown={load}
            onClick={step(-1)}
          >
            <ChevronLeft size={18} />
          </button>
          <button
            type="button"
            className="card-photo-arrow is-next"
            aria-label={`Next photo of ${p.title}`}
            onPointerDown={load}
            onClick={step(1)}
          >
            <ChevronRight size={18} />
          </button>
          {list.length > 1 && (
            <span className="card-photo-count" aria-hidden="true">
              {at + 1}/{list.length}
            </span>
          )}
        </>
      )}
    </div>
  );
}
