#!/usr/bin/env python3
"""Check every product's department by its photo (owner, 2026-10-11: "use our
neural engine to look at products and make sure they're categorized
correctly" ... "reading the product name is causing confusion").

The title-based categoriser misfiles products whose names are words from
another aisle ("Ruby Necklace" a plant, "Denim 3" a sticker, "Blue Jeans" a
lip gloss). This looks only at the first photo:

1. A photo-only MobileCLIP2-S0 image vector per product, on the Mac's GPU
   (torch MPS). Cached in catalog/.cache/embeddings/image-vectors.npz keyed by
   product id + photo URL, so a rerun only reads new or changed photos. (The
   app's vectors.npz is title + photo summed, so it can't be used here.)
2. Zero-shot scores against "a product photo of <aisle>" for every aisle of
   every department (plus a few "this photo says nothing" prompts: a logo, a
   text graphic, a gift card). A department's score is the mean of its aisle
   prompts' likelihoods, so a department with many aisles gets no head start;
   the scores are softmaxed into a probability per department.
3. A second opinion that knows the catalog's own conventions (a watch is
   Accessories here, a vinyl record Music): a linear probe on the photo
   vectors, trained on the current departments and scored out-of-fold (5
   folds by product id), so no product votes on itself. Zero-shot alone read
   records as books and sewing patterns as clothes (31% disagreement, mostly
   noise); the probe alone repeats a brand's habits. Both must agree.
4. A product is flagged when both say the same other department:
       clear       probe >= CLEAR_P for it, <= CURRENT_MAX for the current
                   department, zero-shot >= ZS_CLEAR_P for it, the two
                   departments are not look-alikes (LOOKALIKE: a serum and a
                   shampoo bottle look the same) and the current department is
                   not one a photo can't show (PURPOSE: a dog's chain collar
                   looks like jewelry)
       borderline  probe >= BORDER_P, current <= BORDER_CURRENT_MAX, zero-shot
                   >= ZS_BORDER_P: report only, for Jev or the owner, with
                   the photo's verdict as context
   Hand pins (brands.json product_categories that differ from the keyword
   guess, or whose handle is in the brand's pinned_handles) are never flagged; photos that read as a logo/text/gift card are
   skipped, and so are products whose photo shows what they depict rather
   than what they are (DEPICTS: a dress sewing pattern, an HTV transfer, a
   book cover, a record sleeve).

5. With --auto-move (owner, 2026-10-12: "Yes" to clear flags moving on
   their own), clear flags move: each is recorded in catalog/photo_moves.json
   (product id, from, to, aisles, photo key), which build_catalog.py applies
   on every rebuild for as long as the product shows the same first photo,
   and every stored move is re-applied to the catalog here. Never moved: hand
   pins and confident Jev verdicts (department_rules.placed_on_purpose).
   Safety cap: when a run would make more than MAX_NEW_MOVES new moves, or
   more than max(BRAND_MIN_MOVES, BRAND_SHARE of a brand's products) at one
   brand, it makes none (exit 3, so the refresh notifies) and the held moves
   are listed. Every move, made or held, is appended to --move-log.
   Jev confirms each new move first (2026-10-25, the switch to S4: Jev sided
   with the photo on only 24 of S4's 33 clear flags, and no score cut-off
   separated the 9 wrong ones). A move goes ahead only when Jev says the
   photo's department is right; one Jev rejects or couldn't judge (no key,
   call cap, error) stays where it is, logged "rejected"/"unchecked".

    ~/.venvs/marracat-ml/bin/python catalog/photo_categories.py --max-new 5000   # embed up to 5k new photos, then flag
    ~/.venvs/marracat-ml/bin/python catalog/photo_categories.py --no-embed       # flag from the cache only
    ... --auto-move --move-log build/photo-category-moves.csv                     # what the refresh runs
    ... --csv ~/Downloads/marracat-photo-category-flags.csv --sheet flags.jpg

Cadence: every catalog refresh (scripts/refresh_catalog.sh, --auto-move) with a
--max-new cap on new and changed photos; the check reads every cached photo, so
each run is also the full sweep. ~1 min plus embedding. Cost: local, plus one
Jev call per new move (cached; at most JEV_MAX_CALLS, well under $0.01).
"""
import argparse
import concurrent.futures as cf
import csv
import hashlib
import json
import os
import pathlib
import re
import sys
import time
from catalog_io import write_catalog

try:
    import numpy as np
except ImportError:  # the fast test run has no numpy; the checks below need it
    np = None

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
ROOT = HERE.parent
CATALOG = ROOT / "Marracat" / "Resources" / "catalog.json"
BRANDS = HERE / "brands.json"
# The photo model (owner, 2026-10-25: S4 for everything, after the search
# switch): each keeps its own photo cache, since their vectors don't mix.
MODELS = {"s0": ("MobileCLIP2-S0", HERE / ".cache" / "embeddings" / "image-vectors.npz"),
          "s4": ("MobileCLIP2-S4", HERE / ".cache" / "embeddings-s4" / "image-vectors.npz")}
MODEL, CACHE = MODELS["s4"]
REPORT = HERE / "photo_category_report.md"
MOVES = HERE / "photo_moves.json"
JEV_CACHE = HERE / ".cache" / "photo-move-judgments.json"
JEV_MAX_CALLS = 100   # a normal night plans a handful of new moves; the cap holds at 50

# Auto-move safety cap (owner, 2026-10-12). The first reviewed run had 104
# clear flags over the whole catalog, ~18 at the largest brand; a run past
# these numbers means a model, threshold or catalog change, not a few misfiles.
MAX_NEW_MOVES = 50
BRAND_SHARE = 0.02
BRAND_MIN_MOVES = 3

BATCH = 64           # photos per GPU batch
WORKERS = 12         # photo downloads in flight (owner: keep the Mac's load low)
SAVE_EVERY = 40      # batches between cache saves

# Thresholds, hand-checked on the 2026-10-11 run (146,592 photos). Zero-shot
# alone at 0.80/0.05 flagged 6,963 products, mostly noise; the probe + zero-shot
# agreement below flags a few hundred, most of them real.
CLEAR_P = 0.93       # probe's probability for the photo's department
CURRENT_MAX = 0.02   # ...while the current department gets at most this
ZS_CLEAR_P = 0.80    # ...and zero-shot agrees at least this strongly
BORDER_P = 0.80
BORDER_CURRENT_MAX = 0.05
ZS_BORDER_P = 0.50
TEMPERATURE = 100.0  # CLIP's own logit scale
FOLDS = 5

# Departments a photo cannot tell apart: a bottle is a serum or a shampoo, a
# printed card is stationery or party, a pouch is a bag or an accessory.
LOOKALIKE = [
    {"skincare", "makeup", "hair", "fragrance", "wellness", "household", "baby"},
    {"books", "office", "crafts", "party", "music"},
    {"home", "garden", "household", "tools", "party"},
    {"clothing", "baby", "sports"},
    {"bags", "accessories", "luggage"},
    # Worn on a model, scarves, hats and gloves read as clothes; bag chains,
    # brooches and hair jewels read as jewelry. Taxonomy calls, not misfiles.
    {"clothing", "accessories"},
    {"jewelry", "accessories", "hair", "bags"},
    {"jewelry", "clothing"},  # waist beads and body chains are worn over swimwear
    {"grocery", "wellness", "alcohol"},
    {"toys", "baby", "crafts", "party"},
]

# Departments chosen by who or what the product is for, not how it looks: a
# dog collar is a chain, period underwear is underwear. Never a clear flag.
PURPOSE = {"pets", "baby"}

# Products whose photo shows what they depict, not what they are, and sets
# whose photo shows one piece (gift sets are Party on purpose).
DEPICTS = re.compile(r"\b(patterns?|htv|transfers?|stickers?|prints?|posters?|cards?|book|panel|vinyl|"
                     r"cd|\d?lp|puzzles?|games?|figurines?|charms?|gift sets?|bundles?|kits?|duo)\b", re.I)

# Dried herbs, teas and powders are often shown as the living plant (a
# botanical photo of burdock for "Burdock Root – Loose Dried Herb", the first
# auto-move, 2026-10-12): a Garden reading of one is never a clear flag.
HERBAL = re.compile(r"\b(dried|loose|herbs?|herbal|teas?|infusions?|powders?|roots?|bark|leaf|leaves|capsules?|"
                    r"tinctures?|extracts?|bitters|tonic|sea moss|supplements?)\b", re.I)

# Prompts that say the photo shows no product to judge by.
NO_SIGNAL = ["a logo on a plain background", "a graphic with only text", "a gift card",
             "a blank placeholder image", "a size chart table"]

# Extra phrasing for departments whose aisle names read abstractly.
EXTRA = {
    "books": ["a book cover", "a hardcover book"],
    "music": ["a guitar", "a musical instrument", "a vinyl record"],
    "alcohol": ["a bottle of wine", "a bottle of liquor"],
    "grocery": ["packaged food", "a bag of coffee beans", "a jar of sauce"],
    "pets": ["a dog collar", "a pet bed", "a dog toy"],
    "garden": ["a potted plant", "seeds packet"],
    "auto": ["a car accessory", "a car air freshener"],
    "electronics": ["a phone case", "headphones", "a charging cable"],
    "household": ["a cleaning product bottle", "laundry detergent"],
    "party": ["a greeting card", "party decorations and balloons"],
}


def vkey(p):
    """Product id + first photo URL (department_rules.photo_key is the same)."""
    return hashlib.sha1(f"{p['id']}|{(p.get('images') or [''])[0]}".encode()).hexdigest()[:20]


def load_cache():
    if not CACHE.exists():
        return {}
    z = np.load(CACHE, allow_pickle=False)
    return dict(zip(z["keys"].tolist(), z["vectors"]))


def save_cache(cache):
    CACHE.parent.mkdir(parents=True, exist_ok=True)
    keys = np.array(list(cache.keys()))
    vectors = np.stack(list(cache.values())).astype(np.float16) if cache else np.zeros((0, 1), np.float16)
    tmp = CACHE.with_suffix(".tmp.npz")
    np.savez(tmp, keys=keys, vectors=vectors)
    os.replace(tmp, CACHE)


def model():
    import torch
    import open_clip
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    m, _, preprocess = open_clip.create_model_and_transforms(MODEL, pretrained="dfndr2b")
    return m.to(device).eval(), preprocess, open_clip.get_tokenizer(MODEL), device


def embed(todo, cache, loaded):
    """Image-only vectors for `todo`; a photo that won't load gets none (and
    is retried on the next run)."""
    import torch
    from embed_products import fetch
    m, preprocess, _, device = loaded
    started, done, missing = time.time(), 0, 0
    with cf.ThreadPoolExecutor(WORKERS) as pool:
        for b, i in enumerate(range(0, len(todo), BATCH)):
            chunk = todo[i:i + BATCH]
            images = list(pool.map(lambda p: fetch(p["images"][0]), chunk))
            have = [j for j, im in enumerate(images) if im is not None]
            missing += len(chunk) - len(have)
            if have:
                with torch.no_grad():
                    x = torch.stack([preprocess(images[j]) for j in have]).to(device)
                    v = m.encode_image(x)
                    v = (v / v.norm(dim=-1, keepdim=True)).float().cpu().numpy()
                for k, j in enumerate(have):
                    cache[vkey(chunk[j])] = v[k]
            done += len(chunk)
            if b % SAVE_EVERY == 0:
                save_cache(cache)
                rate = done / max(time.time() - started, 1e-6)
                print(f"  {done}/{len(todo)} ({rate:.0f}/s, ~{(len(todo) - done) / max(rate, 1e-6) / 60:.0f} min left,"
                      f" {missing} photos unreadable)", flush=True)
    save_cache(cache)
    return missing


def prompts(catalog):
    """[(department or None, text)]: every aisle of every department, the
    department's own name, EXTRA phrasing, and the no-signal prompts."""
    out = []
    for c in catalog["categories"]:
        names = {c["name"].replace("&", "and")}
        names |= {s["name"] for s in catalog["subcategories"] if s["category"] == c["id"]}
        names |= set(EXTRA.get(c["id"], []))
        out += [(c["id"], f"a product photo of {n.lower()}") for n in sorted(names)]
    out += [(None, f"a photo of {n}") for n in NO_SIGNAL]
    return out


def aisle_prompts(catalog):
    return [(s["category"], s["id"], f"a product photo of {s['name'].lower()}") for s in catalog["subcategories"]]


def text_vectors(texts, loaded):
    import torch
    m, _, tok, device = loaded
    with torch.no_grad():
        t = m.encode_text(tok(texts).to(device))
        return (t / t.norm(dim=-1, keepdim=True)).float().cpu().numpy()


def department_probs(V, labels, T, depts):
    """Per product: probability per department (equal prior per department,
    whatever its number of aisles) and the no-signal probability."""
    logits = TEMPERATURE * (V @ T.T)
    logits -= logits.max(1, keepdims=True)
    e = np.exp(logits)
    groups = depts + [None]
    cols = np.stack([e[:, [i for i, d in enumerate(labels) if d == g]].mean(1) for g in groups], 1)
    cols /= cols.sum(1, keepdims=True)
    return cols[:, :-1], cols[:, -1]


def fold_of(product_id, folds=FOLDS):
    return int(hashlib.sha1(product_id.encode()).hexdigest(), 16) % folds


def probe_probs(V, y, n, fold, folds=FOLDS, steps=300):
    """Out-of-fold department probabilities from a linear probe trained on
    the catalog's current departments (y: index, -1 = unknown; fold: each
    row's fold), so a product never votes on itself. ~30 s on CPU."""
    import torch
    torch.manual_seed(0)
    out = np.zeros((len(y), n), np.float32)
    for f in range(folds):
        tr = (fold != f) & (y >= 0)
        if not tr.any() or not (fold == f).any():
            continue
        X, Y = torch.tensor(V[tr]), torch.tensor(y[tr], dtype=torch.long)
        lin = torch.nn.Linear(V.shape[1], n)
        opt = torch.optim.Adam(lin.parameters(), lr=0.01, weight_decay=1e-5)
        for _ in range(steps):
            opt.zero_grad()
            torch.nn.functional.cross_entropy(lin(X), Y).backward()
            opt.step()
        with torch.no_grad():
            out[fold == f] = torch.softmax(lin(torch.tensor(V[fold == f])), 1).numpy()
    return out


def tier(best, cur, probe_best, probe_cur, zs_best, text):
    """'clear', 'borderline' or None for a product whose probe and zero-shot
    both put it in `best` instead of `cur`."""
    if DEPICTS.search(text):
        return None
    if (probe_best >= CLEAR_P and probe_cur <= CURRENT_MAX and zs_best >= ZS_CLEAR_P
            and not lookalike(best, cur) and cur not in PURPOSE
            and not (best == "garden" and HERBAL.search(text))):
        return "clear"
    if probe_best >= BORDER_P and probe_cur <= BORDER_CURRENT_MAX and zs_best >= ZS_BORDER_P:
        return "borderline"
    return None


def lookalike(a, b):
    return any(a in g and b in g for g in LOOKALIKE)


def hand_pinned(products, brands):
    """Product ids whose department was set by hand: a brands.json pin that
    differs from what the keyword categoriser would say."""
    import build_catalog as bc
    import department_rules as dr
    by_id = {b["id"]: b for b in brands}
    return {p["id"] for p in products if dr.hand_pinned(p, by_id.get(p["brand"]) or {}, bc)}


def classify(products, cache, catalog, brands, loaded):
    depts = [c["id"] for c in catalog["categories"]]
    names = {c["id"]: c["name"] for c in catalog["categories"]}
    labeled = prompts(catalog)
    T = text_vectors([t for _, t in labeled], loaded)
    aisles = aisle_prompts(catalog)
    A = text_vectors([t for _, _, t in aisles], loaded)
    sub_names = {s["id"]: s["name"] for s in catalog["subcategories"]}
    rows = [(p, cache.get(vkey(p))) for p in products if p.get("images")]
    rows = [(p, v) for p, v in rows if v is not None]
    V = np.stack([v for _, v in rows]).astype(np.float32)
    P, none = department_probs(V, [d for d, _ in labeled], T, depts)
    ix = {d: i for i, d in enumerate(depts)}
    y = np.array([ix.get(p["category"], -1) for p, _ in rows])
    Q = probe_probs(V, y, len(depts), np.array([fold_of(p["id"]) for p, _ in rows]))
    pinned = hand_pinned([p for p, _ in rows], brands)
    flags = []
    for r, (p, _) in enumerate(rows):
        if p["id"] in pinned or none[r] > max(P[r].max(), 0.5):
            continue
        top = int(Q[r].argmax())
        best, cur = depts[top], p["category"]
        if best == cur or cur not in ix or int(P[r].argmax()) != top:
            continue
        pb, pc = float(Q[r, top]), float(Q[r, ix[cur]])
        level = tier(best, cur, pb, pc, float(P[r, top]), f"{p['title']} {p.get('product_type') or ''}")
        if not level:
            continue
        cand = [k for k, (d, _, _) in enumerate(aisles) if d == best]
        aisle = aisles[cand[int((V[r] @ A[cand].T).argmax())]][1] if cand else ""
        flags.append({
            "tier": level, "id": p["id"], "brand": p["brand"], "title": p["title"],
            "current": cur, "current_name": names[cur], "current_p": round(pc, 3),
            "photo": best, "photo_name": names[best], "photo_aisle": sub_names.get(aisle, ""),
            "photo_aisle_id": aisle.split(":", 1)[-1],
            "photo_p": round(pb, 3), "zeroshot_p": round(float(P[r, top]), 3), "image": p["images"][0], "url": p.get("url", ""),
        })
    flags.sort(key=lambda f: (f["tier"] != "clear", -f["photo_p"], f["current_p"]))
    return flags, len(rows), len(pinned)


def load_moves(path=MOVES):
    return json.loads(path.read_text()) if path.exists() else {}


def plan_moves(flags, products, moves, brands, bc=None):
    """New moves from this run's clear flags: ([move], held_reason or None).
    Skips products already moved to that department and anything placed on
    purpose (hand pin, confident Jev verdict)."""
    if bc is None:
        import build_catalog as bc
    import department_rules as dr
    from taxonomy import subcategories_of
    by_id = {p["id"]: p for p in products}
    by_brand = {b["id"]: b for b in brands}
    sizes = {}
    for p in products:
        sizes[p["brand"]] = sizes.get(p["brand"], 0) + 1
    new = []
    for f in flags:
        p = by_id.get(f["id"])
        if f["tier"] != "clear" or not p or p["category"] != f["current"]:
            continue
        if moves.get(p["id"], {}).get("to") == f["photo"] and moves[p["id"]]["photo"] == vkey(p):
            continue
        if dr.placed_on_purpose(p, by_brand.get(p["brand"]) or {}, bc):
            continue
        # The aisles the title names there. Not the photo's closest aisle: on
        # the first run it put houseplants in Soil & Plant Care and period
        # underwear in Swimwear; no aisle beats a wrong one.
        subs = subcategories_of(p, f["photo"])
        new.append({"id": p["id"], "brand": p["brand"], "title": p["title"], "from": f["current"],
                    "to": f["photo"], "subs": subs, "photo": vkey(p), "photo_p": f["photo_p"],
                    "zeroshot_p": f["zeroshot_p"]})
    return new, held_reason(new, sizes)


def held_reason(new, sizes, max_new=MAX_NEW_MOVES, share=BRAND_SHARE, brand_min=BRAND_MIN_MOVES):
    """Why this run's moves trip the safety cap, or None."""
    if len(new) > max_new:
        return f"{len(new)} moves in one run (cap {max_new})"
    per = {}
    for m in new:
        per[m["brand"]] = per.get(m["brand"], 0) + 1
    over = sorted(b for b, n in per.items() if n > max(brand_min, share * sizes.get(b, 0)))
    if over:
        return "too many at " + ", ".join(f"{b} ({per[b]} of {sizes.get(b, 0)})" for b in over)
    return None


def split_held(new, sizes, max_new=MAX_NEW_MOVES, share=BRAND_SHARE, brand_min=BRAND_MIN_MOVES):
    """(moves to make, moves held, why) for this run's new moves. Too many in
    all holds everything (a model or threshold change); too many at one brand
    holds only that brand's (2026-10-21: four Dagmawit flags held the whole
    catalog's moves every night from 10/16 on)."""
    if len(new) > max_new:
        return [], new, f"{len(new)} moves in one run (cap {max_new})"
    reason = held_reason(new, sizes, max_new, share, brand_min)
    if not reason:
        return new, [], None
    per = {}
    for m in new:
        per[m["brand"]] = per.get(m["brand"], 0) + 1
    over = {b for b, n in per.items() if n > max(brand_min, share * sizes.get(b, 0))}
    return [m for m in new if m["brand"] not in over], [m for m in new if m["brand"] in over], reason


def apply_moves(products, moves, brands, bc=None):
    """Re-apply every stored move whose photo is unchanged (the build applies
    them too; the refresh's brand-fit pass runs in between). Returns the
    number of products whose department changed."""
    if bc is None:
        import build_catalog as bc
    import department_rules as dr
    by_brand = {b["id"]: b for b in brands}
    n = 0
    for p in products:
        m = moves.get(p["id"])
        if (not m or m["to"] == p["category"] or m["photo"] != vkey(p)
                or dr.hand_pinned(p, by_brand.get(p["brand"]) or {}, bc)):
            continue
        p["category"], p["subs"] = m["to"], list(m.get("subs") or [])
        n += 1
    return n


def q_photo_right():
    from typesafe_sdk import Noul
    return Noul(instructions="A store files this product in the current department. Its photo suggests the other "
                             "department. Would a shopper expect to find this product in the other department?",
                criteria={"true": "The other department is where this product belongs",
                          "false": "The current department is right, or both fit equally"})


def jev_state(p, cur, photo):
    """What Jev reads about a planned move (same shape as the 2026-10-25 S0/S4
    comparison, catalog/research/2026-10-25-photo-s4, so its verdicts reuse)."""
    return {"product": p.get("title", ""), "type": p.get("product_type") or p.get("productType") or "",
            "brand": p.get("brand", ""), "description": " ".join((p.get("description") or "").split())[:400],
            "current department": cur, "other department": photo}


def confirm_moves(planned, products, names, jev):
    """Split planned moves into (confirmed, rejected, unchecked) by Jev's
    verdict that the photo's department is right (p >= 0.5)."""
    by_id = {p["id"]: p for p in products}
    ok, no, unknown = [], [], []
    for m in planned:
        v = jev.verdict("photo_right", jev_state(by_id[m["id"]], names.get(m["from"], m["from"]),
                                                 names.get(m["to"], m["to"])), q_photo_right)
        (unknown if v is None else ok if v >= 0.5 else no).append(m)
    return ok, no, unknown


def log_moves(rows, status, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = ["at", "status", "id", "brand", "title", "from", "to", "subs", "photo_p", "zeroshot_p"]
    fresh = not path.exists()
    with open(path, "a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        if fresh:
            w.writeheader()
        at = time.strftime("%Y-%m-%d %H:%M")
        for m in rows:
            w.writerow({**m, "at": at, "status": status, "subs": "|".join(m.get("subs") or [])})


def contact_sheet(flags, path, cell=160, cols=8):
    """QA: photos of the flags, labelled current -> photo."""
    from PIL import Image, ImageDraw
    from embed_products import fetch
    with cf.ThreadPoolExecutor(WORKERS) as pool:
        ims = list(pool.map(lambda f: fetch(f["image"]), flags))
    rows = (len(flags) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * cell, rows * (cell + 34)), "white")
    d = ImageDraw.Draw(sheet)
    for i, (f, im) in enumerate(zip(flags, ims)):
        x, y = (i % cols) * cell, (i // cols) * (cell + 34)
        if im is not None:
            im.thumbnail((cell, cell))
            sheet.paste(im, (x, y))
        d.text((x + 2, y + cell), f"{i + 1}. {f['current']}>{f['photo']} {f['photo_p']:.2f}", fill="black")
        d.text((x + 2, y + cell + 14), f["title"][:26], fill="gray")
    sheet.save(path, quality=85)


def write_report(flags, checked, pinned, minutes, path=REPORT, top=50, moved=None, held=None, kept=None):
    clear = [f for f in flags if f["tier"] == "clear"]
    pairs = {}
    for f in clear:
        k = (f["current_name"], f["photo_name"])
        pairs[k] = pairs.get(k, 0) + 1
    lines = [
        "# Photo category check",
        "",
        "Generated by `catalog/photo_categories.py`: each product's first photo, read two ways on",
        f"this Mac ({MODEL} zero-shot against every department's aisles, and a probe trained",
        "on the catalog's own departments, out-of-fold). Flagged only when both agree on another",
        "department. Clear flags move on their own when run with --auto-move (catalog/photo_moves.json),",
        "under a safety cap; borderline flags are report only.",
        "",
        f"- Checked by photo: {checked:,} products ({pinned:,} hand pins never flagged)",
        f"- Clear disagreements: {len(clear):,}",
        f"- Borderline: {len(flags) - len(clear):,}",
        f"- Runtime: {minutes:.1f} min, cost $0",
    ] + ([f"- Moved this run: {len(moved or [])}" + (f" — HELD {len(kept or [])}: {held}" if held else "")]
         if moved is not None else []) + [
        "",
        "## Most common clear moves (current -> photo)",
        "",
        "| Current | Photo says | Products |",
        "|---|---|---|",
    ] + [f"| {a} | {b} | {n} |" for (a, b), n in sorted(pairs.items(), key=lambda x: -x[1])[:25]] + [
        "",
        f"## Top {top} clear flags",
        "",
        "| Product | Brand | Current | Photo says | Confidence | Photo |",
        "|---|---|---|---|---|---|",
    ] + [f"| {f['title'][:60].replace('|', '/')} | {f['brand']} | {f['current_name']} | {f['photo_name']}"
         f"{' / ' + f['photo_aisle'] if f['photo_aisle'] else ''} | {f['photo_p']:.2f} | [photo]({f['image']}) |"
         for f in clear[:top]]
    for title, rows in (("Moves this run", moved), ("Held by the safety cap (read these)", kept)):
        if rows:
            lines += ["", f"## {title}", "", "| Product | Brand | From | To |", "|---|---|---|---|"]
            lines += [f"| {m['title'][:60].replace('|', '/')} | {m['brand']} | {m['from']} | {m['to']} |" for m in rows]
    path.write_text("\n".join(lines) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", choices=MODELS, default="s4")
    ap.add_argument("--report", type=pathlib.Path, default=REPORT)
    ap.add_argument("--max-new", type=int, default=0, help="embed at most this many new photos (0 = all)")
    ap.add_argument("--no-embed", action="store_true", help="flag from the cache only")
    ap.add_argument("--embed-only", action="store_true")
    ap.add_argument("--csv", type=pathlib.Path)
    ap.add_argument("--sheet", type=pathlib.Path, help="contact sheet of flags (QA)")
    ap.add_argument("--sheet-tier", default="clear")
    ap.add_argument("--sheet-n", type=int, default=96)
    ap.add_argument("--auto-move", action="store_true", help="move clear flags (under the safety cap)")
    ap.add_argument("--move-log", type=pathlib.Path, default=ROOT / "build" / "photo-category-moves.csv")
    args = ap.parse_args()
    global MODEL, CACHE
    MODEL, CACHE = MODELS[args.model]
    print(f"model {MODEL}, cache {CACHE.relative_to(ROOT)}", flush=True)
    t0 = time.time()
    catalog = json.load(open(CATALOG))
    products = catalog["products"]
    brands = json.load(open(BRANDS))
    cache = load_cache()
    loaded = model()
    if not args.no_embed:
        todo = [p for p in products if p.get("images") and vkey(p) not in cache]
        if args.max_new:
            todo = todo[:args.max_new]
        print(f"{len(products)} products, {len(cache)} photos cached, embedding {len(todo)}", flush=True)
        if todo:
            embed(todo, cache, loaded)
    if args.embed_only:
        print(f"done in {(time.time() - t0) / 60:.1f} min")
        return
    flags, checked, pinned = classify(products, cache, catalog, brands, loaded)
    clear = [f for f in flags if f["tier"] == "clear"]
    print(f"checked {checked} products by photo ({pinned} hand pins skipped): "
          f"{len(clear)} clear, {len(flags) - len(clear)} borderline, in {(time.time() - t0) / 60:.1f} min")
    moved, kept, held, status = None, None, None, 0
    if args.auto_move:
        moves = load_moves()
        planned, _ = plan_moves(flags, products, moves, brands)
        from search_gaps import Jev
        jcache = json.loads(JEV_CACHE.read_text()) if JEV_CACHE.exists() else {}
        jev = Jev(jcache, max_calls=JEV_MAX_CALLS)
        names = {c["id"]: c["name"] for c in catalog["categories"]}
        planned, rejected, unchecked = confirm_moves(planned, products, names, jev)
        JEV_CACHE.parent.mkdir(parents=True, exist_ok=True)
        JEV_CACHE.write_text(json.dumps(jcache))
        log_moves(rejected, "rejected", args.move_log)
        log_moves(unchecked, "unchecked", args.move_log)
        print(f"jev: {len(planned)} move(s) confirmed, {len(rejected)} rejected, {len(unchecked)} unchecked "
              f"({jev.calls} call(s))")
        sizes = {}
        for p in products:
            sizes[p["brand"]] = sizes.get(p["brand"], 0) + 1
        moved, kept, held = split_held(planned, sizes)
        if held:
            print(f"auto-move HELD {len(kept)} move(s): {held}; moving the other {len(moved)}")
            log_moves(kept, "held", args.move_log)
            status = 3
        if moved:
            for m in moved:
                moves[m["id"]] = {k: m[k] for k in ("from", "to", "subs", "photo", "photo_p")} | {
                    "at": time.strftime("%Y-%m-%d")}
            MOVES.write_text(json.dumps(dict(sorted(moves.items())), indent=0, ensure_ascii=False) + "\n")
            log_moves(moved, "moved", args.move_log)
        changed = apply_moves(products, moves, brands)
        if changed:
            write_catalog(CATALOG, catalog)
        print(f"auto-move: {len(moved)} new, {changed} products re-filed in the catalog")
    write_report(flags, checked, pinned, (time.time() - t0) / 60, path=args.report, moved=moved, held=held, kept=kept)
    if args.csv:
        with open(args.csv, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(flags[0].keys()) if flags else ["tier"])
            w.writeheader()
            w.writerows(flags)
        print(f"wrote {args.csv}")
    if args.sheet:
        contact_sheet([f for f in flags if f["tier"] == args.sheet_tier][:args.sheet_n], args.sheet)
        print(f"wrote {args.sheet}")
    return status


if __name__ == "__main__":
    sys.exit(main())
