"""Ingredient lists for the badges that read a product page beyond Clean's
families: Marracat Clear Scent (scent_badge.py) and Marracat Safer Clean
(safer_clean_badge.py).

Both keep their lists in the same store as Clean (catalog/ingredients.json,
product URL -> list) and the same miss cache, so a page is fetched once
whichever badge asked. Perfume and cleaner formulas are short ("Alcohol Denat.,
Parfum, Aqua, Linalool, Limonene"), so a list introduced by an "Ingredients"
label counts from MIN_LABELLED names; an unlabelled run still needs Clean's
longer MIN_TOKENS, which keeps marketing copy out. Stdlib only.
"""
import concurrent.futures
import datetime as dt
import re
import sys
import threading
import time

import clean_badge as cb
import relaxed_lists

MIN_LABELLED = 3
OR_FRAGRANCE = re.compile(r"\b(fragrance|parfum)\b", re.I)


def extract_list(text):
    """Clean's extractor first; failing that, the longest labelled run of at
    least MIN_LABELLED ingredient-looking names."""
    found = cb.extract_inci(text)
    if found:
        return found
    best, best_len = "", 0
    for m in list(cb.LABEL.finditer(text))[:200]:
        chunk = text[m.end():m.end() + 3000]
        tokens, misses = [], 0
        for raw in re.split(r",|\s\|\s", chunk):
            tok = re.sub(r"^(and|&)\s+", "", raw.strip(" .;*|†‡"), flags=re.I)
            if cb.looks_like_inci(tok, in_run=len(tokens) >= 2):
                tokens.append(tok)
                misses = 0
            else:
                misses += 1
                if misses >= 2 or (tokens and cb.STOP.search(tok)):
                    break
        if len(tokens) >= MIN_LABELLED and len(tokens) > best_len:
            best, best_len = ", ".join(tokens), len(tokens)
    # A Jev-confirmed second reading of the heading's comma run (relaxed_lists.py).
    return best or relaxed_lists.read(text)


def scrape(products, store, misses, max_new, fetch=None):
    """Fetch the pages of `products` that have no stored list and no recent
    miss, at most `max_new` of them spread across stores, one store at a time
    per worker with Clean's politeness delay."""
    fetch = fetch or (lambda url: cb.page_text(cb.fetch_page(url)))
    today = dt.date.today().isoformat()
    stale = "9999" if relaxed_lists.retry_misses() else (dt.date.today() - dt.timedelta(days=cb.MISS_TTL_DAYS)).isoformat()
    todo = {}
    for p in products:
        url = p["url"]
        if url in store or misses.get(url, "") > stale:
            continue
        todo.setdefault(url.split("/")[2], []).append(url)
    urls = sum(len(v) for v in todo.values())
    if max_new and urls > max_new:
        per = max(1, max_new // max(len(todo), 1))
        todo = {d: u[:per] for d, u in todo.items()}
        urls = sum(len(v) for v in todo.values())
    print(f"fetching {urls} product pages across {len(todo)} stores", file=sys.stderr)
    lock, found = threading.Lock(), [0]

    def run_store(domain):
        for url in todo[domain]:
            try:
                inci = extract_list(fetch(url))
            except Exception as e:  # noqa: BLE001 — one bad page must not stop the store
                print(f"  ! {url}: {str(e)[:80]}", file=sys.stderr)
                inci = ""
            with lock:
                if inci:
                    store[url] = inci
                    found[0] += 1
                else:
                    misses[url] = today
            time.sleep(cb.DELAY)

    with concurrent.futures.ThreadPoolExecutor(cb.STORE_WORKERS) as ex:
        list(ex.map(run_store, sorted(todo, key=lambda d: -len(todo[d]))))
    print(f"found lists on {found[0]} of {urls} pages", file=sys.stderr)
    return found[0], urls


def save(store, misses):
    import json
    cb.STORE.write_text(json.dumps(dict(sorted(store.items())), indent=0, ensure_ascii=False) + "\n")
    cb.MISSES.parent.mkdir(exist_ok=True)
    cb.MISSES.write_text(json.dumps(misses))


def tokens(inci):
    return cb.tokens_of(inci)


def banned_hits(toks, extra=()):
    """[(label, [hits])] for Clean's ban list plus `extra` (label, regex, source).
    A label on both lists (PFAS, triclosan) is reported once with every hit."""
    out = {}
    for label, pattern, _source in list(cb.BANNED) + list(extra):
        rx = re.compile(pattern, re.I)
        hits = {t for t in toks if rx.search(t) and "free" not in t}
        if hits:
            out[label] = sorted(set(out.get(label, [])) | hits)
    return list(out.items())


def fragrance_undisclosed(inci, toks):
    """The first bare fragrance/parfum token when fewer than Clean's minimum of
    EU allergens are named beside it; None when the scent is disclosed, made of
    named essential oils or isolates, or absent."""
    # "Essential Oil or Fragrance Oil" may be the fragrance oil: only an
    # essential oil that names no fragrance or parfum counts as disclosed.
    fragrance = [t for t in toks if cb.FRAGRANCE.search(t) and not cb.UNSCENTED.search(t)
                 and ("essential oil" not in t or OR_FRAGRANCE.search(t))]
    named = {m.group(1).lower() for m in cb.ALLERGENS.finditer(inci)}
    named = {a for a in named if not cb.AMBIGUOUS_ALLERGENS.match(a)}
    if fragrance and len(named) < cb.MIN_ALLERGENS:
        return fragrance[0]
    return None
