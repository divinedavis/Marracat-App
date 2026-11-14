import React from "react";
import { dotColor } from "./colorways";

/// A colourway's dots under a product card. Picking one shows that colour's
/// photo, title, price and link on the card (`onPick(id)`).
export default function ColorDots({ members, active, onPick }) {
  if (!members || members.length < 2) return null;
  const shown = members.slice(0, 8);
  return (
    <div className="color-dots" role="group" aria-label="Colors">
      {shown.map((m) => {
        const c = dotColor(m);
        return (
          <button
            key={m.id}
            type="button"
            className={`color-dot ${m.id === active ? "is-on" : ""} ${c ? "" : "no-swatch"} ${m.available ? "" : "sold-out"}`}
            style={c ? { background: c } : undefined}
            title={m.color || ""}
            aria-label={`${m.color || "Color"}${m.available ? "" : " (sold out)"}`}
            aria-pressed={m.id === active}
            onClick={() => onPick(m.id)}
          />
        );
      })}
      {members.length > shown.length && <span className="color-more">+{members.length - shown.length}</span>}
    </div>
  );
}
