import React, { useEffect, useMemo, useRef, useState } from "react";
import { ChevronDown, Search, X } from "lucide-react";
import { rankBrands } from "./brand-match";

// The shop page's brand filter: a button that opens a type-to-search list
// (owner, 2026-09-30), in place of a plain <select> of ~1,000 names.
export default function BrandPicker({ brands, value, onChange }) {
  const [open, setOpen] = useState(false),
    [text, setText] = useState(""),
    [active, setActive] = useState(0);
  const area = useRef(null),
    input = useRef(null),
    list = useRef(null);
  const current = brands.find((b) => b.id === value);
  const options = useMemo(
    () => [
      ...(text.trim() ? [] : [{ id: "", name: "All brands" }]),
      ...rankBrands(brands, text).slice(0, 60),
    ],
    [brands, text],
  );
  useEffect(() => {
    if (!open) return;
    const outside = (e) => {
      if (!area.current?.contains(e.target)) setOpen(false);
    };
    document.addEventListener("pointerdown", outside);
    input.current?.focus();
    return () => document.removeEventListener("pointerdown", outside);
  }, [open]);
  useEffect(() => setActive(0), [text]);
  useEffect(() => {
    list.current
      ?.querySelector(`[data-index="${active}"]`)
      ?.scrollIntoView({ block: "nearest" });
  }, [active]);
  function choose(id) {
    onChange(id);
    setOpen(false);
    setText("");
  }
  function keyDown(e) {
    if (e.nativeEvent.isComposing) return;
    if (e.key === "Escape") {
      e.preventDefault();
      setOpen(false);
    } else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      const n = options.length;
      if (n) setActive((a) => (e.key === "ArrowDown" ? (a + 1) % n : (a - 1 + n) % n));
    } else if (e.key === "Enter") {
      e.preventDefault();
      if (options[active]) choose(options[active].id);
    }
  }
  return (
    <div className="brand-picker" ref={area}>
      <button
        type="button"
        className="brand-picker-button"
        aria-label="Filter by brand"
        aria-haspopup="listbox"
        aria-expanded={open}
        onClick={() => setOpen(!open)}
      >
        <span>{current ? current.name : "All brands"}</span>
        <ChevronDown size={15} />
      </button>
      {open && (
        <div className="brand-picker-panel">
          <label className="brand-picker-search">
            <Search size={16} />
            <input
              ref={input}
              role="combobox"
              aria-label="Search brands"
              aria-autocomplete="list"
              aria-expanded="true"
              aria-controls="brand-picker-list"
              aria-activedescendant={options[active] ? `brand-option-${active}` : undefined}
              autoComplete="off"
              placeholder="Search brands"
              value={text}
              onChange={(e) => setText(e.target.value)}
              onKeyDown={keyDown}
            />
            {text && (
              <button type="button" aria-label="Clear brand search" onClick={() => { setText(""); input.current?.focus(); }}>
                <X size={15} />
              </button>
            )}
          </label>
          <div id="brand-picker-list" role="listbox" aria-label="Brands" ref={list}>
            {options.map((b, i) => (
              <button
                type="button"
                role="option"
                id={`brand-option-${i}`}
                data-index={i}
                key={b.id || "all"}
                tabIndex={-1}
                aria-selected={b.id === (value || "")}
                className={`brand-picker-option ${i === active ? "active" : ""}`}
                onMouseDown={(e) => e.preventDefault()}
                onMouseMove={() => setActive(i)}
                onClick={() => choose(b.id)}
              >
                <span>{b.name}</span>
                {b.count !== undefined && <small>{b.count.toLocaleString()}</small>}
              </button>
            ))}
            {!options.length && <p className="brand-picker-empty">No brand matches “{text.trim()}”.</p>}
          </div>
        </div>
      )}
    </div>
  );
}
