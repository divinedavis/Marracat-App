import React from "react";
import { attributeRows } from "./attrs";

export { attributeRows };

/// Chips for the shopper filters ("For 4C hair", "Fragrance-free", skin
/// concerns, skin type, key ingredient, formulation, SPF, minis & sets), each
/// group on its own department only: a department page, or a search whose
/// results all sit in that department. `active` is { hair, skin, free }; `onChange(field, value)`
/// sets one ("" clears it). Only values something on the page carries are
/// offered, plus whatever is on, so it can be turned off.
export default function AttributeFilters({ category, products, active, onChange }) {
  const rows = attributeRows({ category, products, active });
  if (!rows.length) return null;
  return (
    <div className="attr-filters" aria-label="Filter by what the brand says">
      {rows.map(({ f, spec, values }) => (
        <div className="attr-row" key={f} role="group" aria-label={spec.label}>
          <span className="attr-label">{spec.label}</span>
          {values.map((v) => (
            <button
              key={v}
              type="button"
              className={`attr-chip ${active[f] === v ? "is-on" : ""}`}
              aria-pressed={active[f] === v}
              onClick={() => onChange(f, active[f] === v ? "" : v)}
            >
              {spec.values[v]}
            </button>
          ))}
        </div>
      ))}
    </div>
  );
}
