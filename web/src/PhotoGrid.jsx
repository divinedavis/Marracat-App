import React, { useEffect, useRef, useState } from "react";
import { ChevronLeft, ChevronRight, X } from "lucide-react";
import { imageURL } from "./catalog";

/// Zoom shown over the details column, magnifying the photo this many times.
const ZOOM = 2.5;

/// Every photo at once (owner, 2026-11-09, picked "1 Editorial grid"): the
/// first across the column, the rest two up, so the details beside them stay
/// in view while the shopper scrolls through. Each photo keeps the hover zoom
/// over the details column. On a phone the photos swipe sideways instead.
export function PhotoGrid({ images, title }) {
  const [zoom, setZoom] = useState(null);
  const [at, setAt] = useState(0);
  const [open, setOpen] = useState(null); // the photo the lightbox shows
  const list = (images || []).slice(0, 8);
  const rest = list.length - 1;

  const canZoom = () =>
    typeof window !== "undefined" &&
    window.matchMedia?.("(hover: hover) and (pointer: fine)").matches;

  const update = (e, src) => {
    const img = e.currentTarget;
    const info = img.closest(".product-detail")?.querySelector(".detail-info");
    if (!info || !img.naturalWidth || !canZoom()) return setZoom(null);
    const box = img.getBoundingClientRect();
    const side = info.getBoundingClientRect();
    if (side.left < box.right) return setZoom(null);
    const scale = Math.min(box.width / img.naturalWidth, box.height / img.naturalHeight);
    const w = img.naturalWidth * scale;
    const h = img.naturalHeight * scale;
    const left = box.left + (box.width - w) / 2;
    const top = box.top + (box.height - h) / 2;
    const x = e.clientX - left;
    const y = e.clientY - top;
    if (x < 0 || y < 0 || x > w || y > h) return setZoom(null);
    // The panel covers the details column from the top of the window down.
    const paneTop = Math.max(side.top, 12);
    const pane = { left: side.left, top: paneTop, width: side.right - side.left, height: Math.min(box.height, window.innerHeight - paneTop - 12) };
    const lw = Math.min(w, pane.width / ZOOM);
    const lh = Math.min(h, pane.height / ZOOM);
    const lx = Math.max(0, Math.min(w - lw, x - lw / 2));
    const ly = Math.max(0, Math.min(h - lh, y - lh / 2));
    setZoom({
      src,
      lens: { left: left + lx, top: top + ly, width: lw, height: lh },
      pane,
      background: { size: `${w * ZOOM}px ${h * ZOOM}px`, position: `${-lx * ZOOM}px ${-ly * ZOOM}px` },
    });
  };

  return (
    <>
      <div
        className="photo-grid"
        onScroll={(e) => {
          const el = e.currentTarget;
          setAt(Math.round(el.scrollLeft / Math.max(1, el.clientWidth)));
        }}
      >
        {list.map((src, i) => (
          <img
            key={src}
            src={imageURL(src, i ? 800 : 1200)}
            alt={i ? `${title}, photo ${i + 1} of ${list.length}` : title}
            loading={i < 3 ? "eager" : "lazy"}
            className={[i === 0 || (rest % 2 === 1 && i === list.length - 1) ? "is-wide" : "", zoom?.src === src ? "zooming" : ""].join(" ").trim() || undefined}
            onMouseMove={(e) => update(e, src)}
            onMouseEnter={(e) => {
              if (canZoom()) new Image().src = imageURL(src, 2000);
              update(e, src);
            }}
            onMouseLeave={() => setZoom(null)}
            onClick={() => {
              setZoom(null);
              setOpen(i);
            }}
          />
        ))}
      </div>
      {list.length > 1 && (
        <div className="photo-dots" aria-hidden="true">
          {list.map((src, i) => <i key={src} className={i === at ? "is-on" : undefined} />)}
        </div>
      )}
      {open !== null && <Lightbox images={list} title={title} start={open} onClose={() => setOpen(null)} />}
      {zoom && (
        <>
          <div className="zoom-lens" style={zoom.lens} aria-hidden="true" />
          <div
            className="zoom-pane"
            aria-hidden="true"
            style={{
              ...zoom.pane,
              backgroundImage: `url("${imageURL(zoom.src, 2000)}"), url("${imageURL(zoom.src, 1200)}")`,
              backgroundSize: zoom.background.size,
              backgroundPosition: zoom.background.position,
            }}
          />
        </>
      )}
    </>
  );
}

/// A photo clicked opens here (owner, 2026-11-09, picked "1 Lightbox"): dark,
/// the photo as large as the window allows, arrows, "2 / 5" with the title,
/// and thumbnails along the bottom. Arrow keys and swipes move, Esc closes.
export function Lightbox({ images, title, start = 0, onClose }) {
  const [at, setAt] = useState(start);
  const ref = useRef(null);
  const touch = useRef(null);
  const n = images.length;
  const go = (d) => setAt((i) => (i + d + n) % n);

  useEffect(() => {
    const dialog = ref.current;
    dialog?.showModal?.();
    const scroll = document.body.style.overflow;
    document.body.style.overflow = "hidden"; // the page stays put underneath
    return () => {
      document.body.style.overflow = scroll;
      dialog?.close?.();
    };
  }, []);
  // The photos either side are fetched ahead, so an arrow never waits.
  useEffect(() => {
    for (const d of [1, -1]) new Image().src = imageURL(images[(at + d + n) % n], 1600);
  }, [at, images, n]);

  return (
    <dialog
      ref={ref}
      className="lightbox"
      aria-label={`${title}, photo ${at + 1} of ${n}`}
      onCancel={(e) => {
        e.preventDefault();
        onClose();
      }}
      onKeyDown={(e) => {
        if (e.key === "ArrowRight") go(1);
        if (e.key === "ArrowLeft") go(-1);
      }}
      onClick={(e) => {
        if (e.target === e.currentTarget || e.target.classList.contains("lightbox-stage")) onClose();
      }}
    >
      <p className="lightbox-count">
        {at + 1} / {n} · {title}
      </p>
      <button type="button" className="lightbox-button lightbox-close" aria-label="Close photos" onClick={onClose} autoFocus>
        <X size={22} />
      </button>
      <div
        className="lightbox-stage"
        onTouchStart={(e) => (touch.current = e.touches[0].clientX)}
        onTouchEnd={(e) => {
          const dx = e.changedTouches[0].clientX - (touch.current ?? 0);
          if (Math.abs(dx) > 40) go(dx < 0 ? 1 : -1);
          touch.current = null;
        }}
      >
        <img key={images[at]} src={imageURL(images[at], 1600)} alt={`${title}, photo ${at + 1} of ${n}`} />
      </div>
      {n > 1 && (
        <>
          <button type="button" className="lightbox-button lightbox-prev" aria-label="Previous photo" onClick={() => go(-1)}>
            <ChevronLeft size={26} />
          </button>
          <button type="button" className="lightbox-button lightbox-next" aria-label="Next photo" onClick={() => go(1)}>
            <ChevronRight size={26} />
          </button>
          <div className="lightbox-thumbs">
            {images.map((src, i) => (
              <button
                key={src}
                type="button"
                className={i === at ? "is-on" : undefined}
                aria-label={`Photo ${i + 1}`}
                aria-current={i === at}
                onClick={() => setAt(i)}
              >
                <img src={imageURL(src, 200)} alt="" />
              </button>
            ))}
          </div>
        </>
      )}
    </dialog>
  );
}
