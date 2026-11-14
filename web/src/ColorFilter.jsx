import React from "react";
import { COLOR_FAMILIES } from "./colors";

// Departments whose products have a colour worth choosing by (src/colors.js
// leaves out books, food, scents and skincare).
const COLOURED = new Set(["clothing", "shoes", "bags", "accessories", "jewelry", "home", "baby", "luggage",
  "sports", "hair", "makeup", "office", "party", "toys", "pets", "crafts", "electronics"]);

/// A row of colour chips on a search or a department that has colours (owner,
/// 2026-10-15). `counts` is { family: products } for the page without its own
/// colour; `active` is the family picked or ""; `onChange(value)` sets it.
/// The colours ColorFilter would offer; empty means it draws nothing.
export function colorChoices({ category, search, counts, active }) {
  if (!search && !COLOURED.has(category)) return [];
  const shown = COLOR_FAMILIES.filter((f) => f.id === active || counts?.[f.id]);
  // One colour on offer is no choice, unless it's the one switched on.
  return shown.length < 2 && !active ? [] : shown;
}

export default function ColorFilter({ category, search, counts, active, onChange }) {
  const shown = colorChoices({ category, search, counts, active });
  if (!shown.length) return null;
  return (
    <div className="attr-filters color-filter" aria-label="Filter by color">
      <div className="attr-row" role="group" aria-label="Color">
        <span className="attr-label">Color</span>
        {shown.map((f) => (
          <button
            key={f.id}
            type="button"
            className={`attr-chip color-chip ${active === f.id ? "is-on" : ""}`}
            aria-pressed={active === f.id}
            data-testid={`color-${f.id}`}
            onClick={() => onChange(active === f.id ? "" : f.id)}
          >
            <span className={`chip-swatch ${f.hex ? "" : "is-multi"}`} style={f.hex ? { background: f.hex } : undefined} aria-hidden="true" />
            {f.label}
            {counts?.[f.id] ? <span className="chip-count">{counts[f.id].toLocaleString()}</span> : null}
          </button>
        ))}
      </div>
    </div>
  );
}
