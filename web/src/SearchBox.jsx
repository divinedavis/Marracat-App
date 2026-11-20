import { toPath as hrefFor } from "./router";
import React, { useState, useEffect, useLayoutEffect, useMemo, useRef, useDeferredValue } from "react";
import { createPortal } from "react-dom";
import { Search, X, ArrowRight, Store, Grid2X2 } from "lucide-react";
import { buildSearchIndex, liteIndex, serverSuggestions, suggest, suggestQuery } from "./search-suggestions";
import { imageURL, money } from "./catalog";
import { Price } from "./fx";
import { saysOwnership, tokens } from "./search-words";
import OwnershipNotice from "./OwnershipNotice";
function Completion({ text, query }) {
  const start = text
    .toLocaleLowerCase()
    .indexOf(query.trim().toLocaleLowerCase());
  if (start < 0) return <strong>{text}</strong>;
  const end = start + query.trim().length;
  return (
    <>
      <strong>{text.slice(0, start)}</strong>
      <span>{text.slice(start, end)}</span>
      <strong>{text.slice(end)}</strong>
    </>
  );
}
export default function SearchBox({
  products,
  brands,
  categories,
  subcategories = [],
  query,
  navigationKey,
  loading,
  onSearch,
  onNavigate,
}) {
  const [text, setText] = useState(query || ""),
    [open, setOpen] = useState(false),
    [active, setActive] = useState(-1);
  const [viewportHeight, setViewportHeight] = useState(
    window.visualViewport?.height || window.innerHeight,
  );
  const area = useRef(null),
    input = useRef(null),
    list = useRef(null);
  // Built a slice at a time once the catalog lands, so the page and the field
  // stay responsive; until then the panel says the catalog is loading.
  const [index, setIndex] = useState(null);
  useEffect(() => {
    let stale = false;
    setIndex(null);
    if (products.length)
      buildSearchIndex(products, brands, categories, subcategories, () => stale)
        .then((built) => built && !stale && setIndex(built));
    return () => {
      stale = true;
    };
  }, [products, brands, categories, subcategories]);
  // Keystrokes draw first; suggestions follow for the latest text. Once a
  // list is showing, each keystroke waits 40 ms for the next, as the app's
  // search does (SearchOverlay), so fast typing skips the letters between:
  // every list is a search of the whole catalog (src/search-suggestions.js).
  const [settled, setSettled] = useState(text);
  const showing = useRef(false);
  useEffect(() => {
    if (!text.trim() || !showing.current) {
      setSettled(text);
      return;
    }
    const wait = setTimeout(() => setSettled(text), 40);
    return () => clearTimeout(wait);
  }, [text]);
  const typed = useDeferredValue(settled);
  // Until the index is built (the catalog is ~12 MB), the panel offers the
  // brands, aisles and departments the words start, plus the first products
  // of the server's search (src/search-suggestions.js, serverSuggestions).
  const lite = useMemo(() => liteIndex(brands, categories, subcategories), [brands, categories, subcategories]);
  const [remote, setRemote] = useState(null);
  const asked = typed.trim();
  useEffect(() => {
    if (index || !asked) return;
    const controller = new AbortController();
    const wait = setTimeout(() => {
      fetch(suggestQuery(asked), { signal: controller.signal })
        .then((r) => (r.ok ? r.json() : null))
        .then((found) => found && setRemote({ q: asked, found }))
        .catch(() => {});
    }, 120);
    return () => {
      clearTimeout(wait);
      controller.abort();
    };
  }, [index, asked]);
  const answered = remote?.q === asked ? remote.found : null;
  const fresh = useMemo(
    () => (index ? suggest(index, typed) : serverSuggestions(lite, typed, answered)),
    [index, typed, lite, answered],
  );
  // The list on screen when the shopper starts choosing with the arrow keys
  // stays put until they type: the index landing mid-choice would swap the
  // rows under the highlight, and Enter would open a different one.
  const [held, setHeld] = useState(null);
  const results = held || fresh;
  showing.current = results.items.length > 0;
  // Still waiting: no index, and the server hasn't answered these words.
  const indexing = (loading || !index) && !answered;
  const visible = open && text.trim().length > 0;
  useLayoutEffect(() => {
    // Preserve a new query typed while the previous navigation is finishing.
    if (document.activeElement === input.current) return;
    setText(query || "");
    setOpen(false);
    setActive(-1);
  }, [query, navigationKey]);
  useEffect(() => {
    setActive(-1);
    setHeld(null);
  }, [text]);
  useEffect(() => {
    if (!visible) return;
    const outside = (e) => {
      if (!area.current?.contains(e.target)) setOpen(false);
    };
    document.addEventListener("pointerdown", outside);
    return () => document.removeEventListener("pointerdown", outside);
  }, [visible]);
  useEffect(() => {
    const resize = () =>
      setViewportHeight(window.visualViewport?.height || window.innerHeight);
    window.visualViewport?.addEventListener("resize", resize);
    window.addEventListener("resize", resize);
    return () => {
      window.visualViewport?.removeEventListener("resize", resize);
      window.removeEventListener("resize", resize);
    };
  }, []);
  useEffect(() => {
    if (active >= 0)
      list.current
        ?.querySelector(`[data-index="${active}"]`)
        ?.scrollIntoView({ block: "nearest" });
  }, [active]);
  function choose(item) {
    setOpen(false);
    setActive(-1);
    input.current?.blur();
    onNavigate(item.to);
  }
  function search() {
    setOpen(false);
    setActive(-1);
    input.current?.blur();
    onSearch(text.trim());
  }
  function keyDown(e) {
    if (e.nativeEvent.isComposing || e.keyCode === 229) return;
    if (e.key === "Escape") {
      e.preventDefault();
      setOpen(false);
      setActive(-1);
      return;
    }
    if (
      ["ArrowDown", "ArrowUp"].includes(e.key) &&
      text.trim() &&
      results.items.length
    ) {
      e.preventDefault();
      setOpen(true);
      if (!held) setHeld(results);
      setActive((current) =>
        e.key === "ArrowDown"
          ? (current + 1) % results.items.length
          : current <= 0
            ? results.items.length - 1
            : current - 1,
      );
    }
    if (e.key === "Enter" && visible && active >= 0 && results.items[active]) {
      e.preventDefault();
      choose(results.items[active]);
    }
  }
  return (
    <>
      {visible &&
        createPortal(
          <div className="search-backdrop" aria-hidden="true" />,
          document.body,
        )}
      <div
        ref={area}
        className={`search-area ${visible ? "search-open" : ""}`}
        style={{ "--search-viewport-height": `${viewportHeight}px` }}
        onBlur={(e) => {
          if (!e.currentTarget.contains(e.relatedTarget)) {
            setOpen(false);
            setActive(-1);
          }
        }}
      >
        <form
          className="search-form"
          role="search"
          onSubmit={(e) => {
            e.preventDefault();
            search();
          }}
        >
          <input
            ref={input}
            role="combobox"
            aria-label="Search products and brands"
            aria-autocomplete="list"
            aria-expanded={visible}
            aria-controls={visible ? "search-suggestions" : undefined}
            aria-activedescendant={
              visible && active >= 0 ? `suggestion-${active}` : undefined
            }
            autoComplete="off"
            placeholder="Search everything at Marracat"
            value={text}
            onChange={(e) => {
              setText(e.target.value);
              setOpen(true);
              setActive(-1);
            }}
            onFocus={() => setOpen(true)}
            onKeyDown={keyDown}
          />
          {text && (
            <button
              className="search-clear"
              type="button"
              aria-label="Clear search"
              onClick={() => {
                setText("");
                setActive(-1);
                input.current?.focus();
              }}
            >
              <X size={17} />
            </button>
          )}
          <button type="submit" aria-label="Search">
            <Search size={22} />
          </button>
        </form>
        {visible && (
          <div className="search-panel">
            {results.categories.length > 0 && (
              <div className="search-categories">
                <span>Explore in</span>
                <div>
                  {results.categories.map((c) => (
                    <a
                      key={c.id}
                      href={hrefFor(c.to)}
                      // Keep the search box focused through the press, as the
                      // suggestion rows do: Safari doesn't focus a link on
                      // click, so the blur would close the panel and drop this
                      // link before its click arrived.
                      onMouseDown={(e) => e.preventDefault()}
                      onClick={(e) => {
                        e.preventDefault();
                        choose(c);
                      }}
                    >
                      {c.name}
                      <ArrowRight size={13} />
                    </a>
                  ))}
                </div>
              </div>
            )}
            {saysOwnership(tokens(text)) && <OwnershipNotice compact />}
            <div className="suggestion-heading">
              {results.items.length
                ? "Suggestions"
                : indexing
                  ? "Searching…"
                  : "No matches yet"}
            </div>
            {!indexing && !results.items.length && (
              <p className="suggestion-empty">
                Try another word, a product type, or a brand name.
              </p>
            )}
            <div
              id="search-suggestions"
              role="listbox"
              aria-label="Search suggestions"
              ref={list}
            >
              {results.items.map((item, i) => (
                <button
                  type="button"
                  role="option"
                  aria-selected={active === i}
                  id={`suggestion-${i}`}
                  data-index={i}
                  key={item.id}
                  tabIndex={-1}
                  className={`suggestion-row ${active === i ? "active" : ""}`}
                  onMouseDown={(e) => e.preventDefault()}
                  onClick={() => choose(item)}
                >
                  <span className="suggestion-image">
                    {item.image ? (
                      <img
                        src={imageURL(item.image, 100)}
                        alt=""
                        onError={(e) => {
                          e.currentTarget.src = "/mark.svg";
                          e.currentTarget.onerror = null;
                        }}
                      />
                    ) : item.kind === "Brand" ? (
                      <Store size={21} />
                    ) : item.kind === "Department" || item.kind === "Aisle" ? (
                      <Grid2X2 size={21} />
                    ) : (
                      <Search size={21} />
                    )}
                  </span>
                  <span className="suggestion-copy">
                    <span className="suggestion-title">
                      <Completion text={item.label} query={typed} />
                    </span>
                    <span className="suggestion-kind">{item.kind}</span>
                  </span>
                  {item.price !== undefined ? (
                    <span className="suggestion-price">
                      <Price value={item.price} currency={item.currency} />
                    </span>
                  ) : (
                    <ArrowRight className="suggestion-arrow" size={16} />
                  )}
                </button>
              ))}
            </div>
            <button
              type="button"
              className="search-all"
              onMouseDown={(e) => e.preventDefault()}
              onClick={search}
            >
              <Search size={17} />
              <span>
                {results.count
                  ? `See all ${results.count.toLocaleString()} results for “${text.trim()}”`
                  : `Search for “${text.trim()}”`}
              </span>
              <ArrowRight size={17} />
            </button>
            <span className="sr-only" role="status">
              {indexing
                ? "Loading suggestions"
                : `${results.items.length} suggestions available. Use the up and down arrow keys to choose.`}
            </span>
          </div>
        )}
      </div>
    </>
  );
}
