import React from "react";

// A product's options as chips, one row per option ("Color", "Size"), read
// from the store's variant titles ("Off Black / XS") (owner, 2026-11-09,
// picked "1 Editorial grid"). Null when the titles don't split into the
// store's option names; the page keeps its dropdown then.
export function optionAxes(optionNames, variants) {
  const names = (optionNames || []).filter((n) => typeof n === "string" && n.trim());
  if (!names.length || !variants?.length) return null;
  const parts = variants.map((v) => String(v.title ?? "").split(" / "));
  if (parts.some((p) => p.length !== names.length)) return null;
  return names.map((name, i) => ({ name, values: [...new Set(parts.map((p) => p[i]))] }));
}

/// The variant to open when one option changes: the same other options if
/// that one exists and can be bought, else the first in stock with the value.
export function variantFor(variants, current, i, value) {
  const split = (v) => String(v.title ?? "").split(" / ");
  const want = current.map((c, j) => (j === i ? value : c)).join(" / ");
  const exact = variants.find((v) => v.title === want);
  if (exact?.available) return exact;
  return variants.find((v) => v.available && split(v)[i] === value) || exact || variants.find((v) => split(v)[i] === value);
}

export default function VariantPicker({ axes, variants, variant, onPick }) {
  const current = String(variant?.title ?? "").split(" / ");
  return (
    <div className="variant-picker">
      {axes.map((axis, i) => (
        <div className="variant-axis" key={axis.name}>
          <p className="variant-axis-label" id={`axis-${i}`}>
            <b>{axis.name}</b> {current[i]}
          </p>
          <div className="variant-chips" role="radiogroup" aria-labelledby={`axis-${i}`}>
            {axis.values.map((value) => {
              const on = current[i] === value;
              const want = current.map((c, j) => (j === i ? value : c)).join(" / ");
              const buyable = variants.some((v) => v.title === want && v.available);
              return (
                <button
                  key={value}
                  type="button"
                  role="radio"
                  aria-checked={on}
                  aria-label={buyable ? value : `${value}, sold out`}
                  className={`variant-chip${on ? " is-on" : ""}${buyable ? "" : " is-out"}`}
                  onClick={() => {
                    const next = variantFor(variants, current, i, value);
                    if (next) onPick(String(next.id));
                  }}
                >
                  {value}
                </button>
              );
            })}
          </div>
        </div>
      ))}
    </div>
  );
}
