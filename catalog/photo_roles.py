#!/usr/bin/env python3
"""The right photo for the right place (owner, 2026-10-10): a grid tile reads
best as the product alone on a plain background; a hero banner reads best as
the product being worn or used.

Labels each of a product's first photos as
    "product"    shot on a plain, even background (a studio or packshot), or
    "lifestyle"  anything else (on a model, in a room, outdoors, a collage),
from a 64-px thumbnail: how even the photo's outer border is, and how much
of the frame differs from it ("flat": a size chart or a label on white, which
is never picked).
No model and no network beyond the thumbnail; the two numbers are cached by photo
URL in catalog/.cache/photo_roles.json, so a photo is fetched once.

Writes on the product, only when not 0 (0 is what every reader assumes):
    product["tile_image"] = 2   index into product["images"] of the first packshot
    product["hero_image"] = 1   index of the first lifestyle photo
A product whose photos are all one kind keeps 0 for both.

    ~/.venvs/marracat-ml/bin/python catalog/photo_roles.py --max-new 4000 --clip 2000
    ... --sample 300 --sheet out.jpg   # QA: a contact sheet of 300 products
"""
import argparse
import hashlib
import io
import json
import pathlib
import random
import statistics
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from functools import lru_cache
from catalog_io import write_catalog

HERE = pathlib.Path(__file__).resolve().parent
CATALOG = HERE.parent / "Marracat" / "Resources" / "catalog.json"
CACHE = HERE / ".cache" / "photo_roles.json"
FIRST = 4            # photos looked at per product
WORKERS = 4          # owner, 2026-10-11: keep the Mac's load low
MAX_BYTES = 2_000_000
# Measured on a 300-product sample (2026-10-11): a packshot's border varies by
# well under 10 grey levels; a model or a room varies by 20 and more.
EVEN = 10.0
EVEN_SHARE = 0.85
# Below this share of the frame the "subject" is a few lines of text.
MIN_COVER = 0.12
CLEARLY_NOT, CLEARLY_EVEN, HERO_COVER = 0.5, 0.95, 0.6
LIFE_MIN = 0.6
# The model behind the lifestyle score (owner, 2026-10-25: S4 for everything).
# An S4 score is stored as [even, cover, score, 4]; a three-number entry is
# S0's, used until S4 re-reads that photo.
CLIP_MODEL, CLIP_MARK = "MobileCLIP2-S4", 4
# S4's cut-off passes the same share of hero candidates as S0's 0.6 did (47%
# vs 49% on 1,499 photos; on the 60 they split over, S4 was right about 30
# times to S0's 20: catalog/research/2026-10-25-photo-s4).
LIFE_MIN_S4 = 0.47
# Zero-shot prompts: a hero shows the product worn or in use, not a detail.
LIFE = ["a photo of a person wearing clothing or accessories", "a person using a product at home",
        "a fashion model posing outdoors", "a styled room interior with furniture and decor"]
NOT_LIFE = ["a close-up of fabric texture", "a product on a plain studio background", "an infographic with text",
            "a size chart table", "a close-up of a product detail", "a product box and packaging",
            "a close-up of skin or hands", "a graphic design illustration"]


def key(url):
    return hashlib.sha1(url.split("?")[0].encode()).hexdigest()[:16]


def thumb_url(url):
    base = url.split("?")[0]
    return base + "?width=96" if "shopify" in base or "/cdn/shop/" in base else url


@lru_cache(maxsize=2048)  # the QA sheet redraws what was just labelled
def fetch(url):
    """A 64x64 RGB thumbnail, or None. https only; capped in size."""
    if not isinstance(url, str) or not url.startswith("https://"):
        return None
    from PIL import Image
    try:
        req = urllib.request.Request(thumb_url(url), headers={"User-Agent": "Mozilla/5.0 (Marracat catalog)"})
        with urllib.request.urlopen(req, timeout=15) as r:
            data = r.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            return None
        im = Image.open(io.BytesIO(data))
        im.draft("RGB", (128, 128))
        return im.convert("RGB").resize((64, 64))
    except Exception:  # noqa: BLE001 — a dead photo is just unlabelled
        return None


def border(im, width=4):
    px = im.load()
    n = im.size[0]
    return [px[x, y] for y in range(n) for x in range(n) if x < width or y < width or x >= n - width or y >= n - width]


def stats(im):
    """[even, cover]: the share of the border within EVEN levels of its median
    colour, and the share of the whole photo that differs from that colour
    (how much of the frame the subject fills)."""
    ring = border(im)
    med = [statistics.median(c[i] for c in ring) for i in range(3)]
    off = lambda c, tol: max(abs(c[i] - med[i]) for i in range(3)) > tol  # noqa: E731
    even = sum(1 for c in ring if not off(c, EVEN)) / len(ring)
    raw = im.tobytes()
    pixels = [raw[i:i + 3] for i in range(0, len(raw), 3)]
    cover = sum(1 for c in pixels if off(c, 2 * EVEN)) / len(pixels)
    return [round(even, 3), round(cover, 3)]


def role(s):
    """"product": a plain, even background with a subject on it. "flat": a
    plain background with next to nothing on it (a size chart, a label, a
    blank card) — never a tile. "lifestyle": everything else."""
    if not isinstance(s, list):
        return None
    even, cover = s[:2]
    if even >= EVEN_SHARE:
        return "product" if cover >= MIN_COVER else "flat"
    return "lifestyle"


def label(url):
    im = fetch(url)
    return None if im is None else stats(im)


def pick(stats):
    """(tile, hero) indices from a product's photos' [even, cover] stats.

    Measured on the 300-product sample (2026-10-11), moving the tile whenever
    a later photo looked more like a packshot changed 44 tiles and 12 of them
    for the worse (a size chart, a fabric close-up, another colour). So: the
    brand's first photo stays the tile unless it is clearly not a packshot
    (border under half even) and a later one clearly is (border 95% even,
    something on it). The hero is the first clearly lifestyle photo that fills
    the frame and that MobileCLIP agrees shows the product worn or in use
    (without --clip, no hero is picked: border stats alone picked a close-up,
    a box or an infographic for about a third of heroes on the sample)."""
    tile = 0
    if stats[0][0] < CLEARLY_NOT:
        tile = next((i for i, x in enumerate(stats) if x[0] >= CLEARLY_EVEN and x[1] >= MIN_COVER), 0)
    hero = next((i for i, x in enumerate(stats) if hero_candidate(x) and lifestyle(x)), tile)
    return tile, hero


def lifestyle(x):
    """MobileCLIP says the photo shows the product worn or in use."""
    if len(x) > 3 and x[3] == CLIP_MARK:
        return x[2] >= LIFE_MIN_S4
    return len(x) > 2 and x[2] >= LIFE_MIN


def hero_candidate(x):
    return x[0] < CLEARLY_NOT and x[1] >= HERO_COVER


def clip_scores(cache, products, limit, deadline=None):
    """Adds a lifestyle probability (third number) to the hero candidates of
    up to `limit` products, two photos a product at most. Needs the ML venv
    (open_clip); bounded and cached like the stats."""
    import torch
    import open_clip
    from PIL import Image
    todo = []
    for p in products:
        stats = [(u, cache.get(key(u))) for u in (p.get("images") or [])[:FIRST] if isinstance(u, str)]
        if not all(isinstance(x, list) for _, x in stats):
            continue
        cands = [u for u, x in stats if hero_candidate(x)][:2]
        new = [u for u in cands if len(cache[key(u)]) < 4]
        if new:
            todo += new
            limit -= 1
            if limit <= 0:
                break
    if not todo:
        return 0
    # The Mac's GPU, as photo_categories.py does: on the CPU this step took
    # hours a night (2026-10-18/20: photo roles ran 4.7 and 7.5 h).
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    model, _, preprocess = open_clip.create_model_and_transforms(CLIP_MODEL, pretrained="dfndr2b")
    model = model.to(device).eval()
    tok = open_clip.get_tokenizer(CLIP_MODEL)

    def big(url):
        try:
            req = urllib.request.Request(thumb_url(url).replace("width=96", "width=256"),
                                         headers={"User-Agent": "Mozilla/5.0 (Marracat catalog)"})
            with urllib.request.urlopen(req, timeout=15) as r:
                data = r.read(MAX_BYTES + 1)
            return None if len(data) > MAX_BYTES else Image.open(io.BytesIO(data)).convert("RGB")
        except Exception:  # noqa: BLE001
            return None
    with torch.no_grad():
        t = model.encode_text(tok(LIFE + NOT_LIFE).to(device))
        t = t / t.norm(dim=-1, keepdim=True)
        with ThreadPoolExecutor(WORKERS) as ex:
            for i in range(0, len(todo), 32):
                if deadline and time.time() > deadline:
                    print(f"clip: time budget spent after {i} of {len(todo)} photos; the rest wait for tomorrow")
                    return i
                chunk = todo[i:i + 32]
                ims = list(ex.map(big, chunk))
                have = [j for j, im in enumerate(ims) if im is not None]
                if not have:
                    continue
                v = model.encode_image(torch.stack([preprocess(ims[j]) for j in have]).to(device))
                v = v / v.norm(dim=-1, keepdim=True)
                prob = (100 * v @ t.T).softmax(dim=-1)[:, :len(LIFE)].sum(dim=-1).cpu()
                for j, pr in zip(have, prob.tolist()):
                    cache[key(chunk[j])] = cache[key(chunk[j])][:2] + [round(pr, 3), CLIP_MARK]
    return len(todo)


def load_cache():
    try:
        return json.loads(CACHE.read_text())
    except (OSError, ValueError):
        return {}


def label_products(products, cache, max_new, deadline=None):
    """Fills the cache for up to max_new products' photos (best sellers and
    in-stock first); returns how many photos were fetched."""
    order = sorted(products, key=lambda p: (not p.get("available"), p.get("best_rank") if p.get("best_rank") is not None else 999))
    todo, n = [], 0
    for p in order:
        urls = [u for u in (p.get("images") or [])[:FIRST] if isinstance(u, str) and key(u) not in cache]
        if not urls or len(p.get("images") or []) < 2:
            continue
        todo += urls
        n += 1
        if n >= max_new:
            break
    done = 0
    with ThreadPoolExecutor(WORKERS) as ex:
        for i in range(0, len(todo), 200):
            if deadline and time.time() > deadline:
                print(f"photo roles: time budget spent after {done} of {len(todo)} photos; the rest wait for tomorrow")
                break
            chunk = todo[i:i + 200]
            for u, r in zip(chunk, ex.map(label, chunk)):
                cache[key(u)] = r or "?"
            done += len(chunk)
    return done


def annotate(products, cache):
    counts = {"tile_moved": 0, "hero_moved": 0, "labelled": 0}
    for p in products:
        p.pop("tile_image", None)
        p.pop("hero_image", None)
        imgs = (p.get("images") or [])[:FIRST]
        stats = [cache.get(key(u)) for u in imgs if isinstance(u, str)]
        if len(stats) < 2 or not all(isinstance(x, list) for x in stats):
            continue
        counts["labelled"] += 1
        tile, hero = pick(stats)
        if tile:
            p["tile_image"] = tile
            counts["tile_moved"] += 1
        if hero:
            p["hero_image"] = hero
            counts["hero_moved"] += 1
    return counts


def contact_sheet(products, cache, path, cell=80):
    """One row a product: its first photos, framed green (product), grey (flat)
    or orange (lifestyle), the chosen tile underlined in blue."""
    from PIL import Image, ImageDraw
    rows = [p for p in products if all(role(cache.get(key(u))) for u in p["images"][:FIRST])]
    per_row = 3  # products side by side
    cols = per_row * FIRST
    sheet = Image.new("RGB", (cols * cell, ((len(rows) + per_row - 1) // per_row) * cell), "white")
    draw = ImageDraw.Draw(sheet)
    for n, p in enumerate(rows):
        tile, _ = pick([cache[key(u)] for u in p["images"][:FIRST]])
        for i, u in enumerate(p["images"][:FIRST]):
            im = fetch(u)
            x, y = ((n % per_row) * FIRST + i) * cell, (n // per_row) * cell
            if im:
                sheet.paste(im.resize((cell - 8, cell - 8)), (x + 4, y + 4))
            colour = {"product": (40, 160, 70), "flat": (150, 150, 150)}.get(role(cache[key(u)]), (235, 130, 30))
            draw.rectangle([x + 1, y + 1, x + cell - 2, y + cell - 2], outline=colour, width=3)
            if i == tile:
                draw.rectangle([x + 4, y + cell - 7, x + cell - 5, y + cell - 3], fill=(30, 90, 220))
    sheet.save(path, quality=80)
    return len(rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--max-new", type=int, default=4000, help="products whose photos may be fetched this run")
    ap.add_argument("--sample", type=int, help="label a random sample of N products only (QA)")
    ap.add_argument("--sheet", help="with --sample: write a contact sheet here")
    ap.add_argument("--clip", type=int, default=0, help="products whose hero candidates MobileCLIP may check (ML venv)")
    ap.add_argument("--budget-min", type=float, default=0, help="stop fetching after this many minutes (0 = no limit)")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    catalog = json.loads(CATALOG.read_text())
    products = catalog["products"]
    cache = load_cache()
    if args.sample:
        random.seed(11)
        pool = [p for p in products if len(p.get("images") or []) >= 2]
        sample = random.sample(pool, args.sample)
        fetched = label_products(sample, cache, args.sample)
        if args.clip:
            print(f"clip: {clip_scores(cache, sample, args.clip)} photos")
        CACHE.parent.mkdir(exist_ok=True)
        CACHE.write_text(json.dumps(cache, separators=(",", ":")))
        print(f"sample: fetched {fetched} photos; {annotate(sample, cache)}")
        if args.sheet:
            print(f"sheet: {contact_sheet(sample, cache, args.sheet)} products -> {args.sheet}")
        return
    t0 = time.time()
    deadline = t0 + args.budget_min * 60 if args.budget_min else None
    fetched = label_products(products, cache, args.max_new, deadline) if args.max_new else 0
    t1 = time.time()
    print(f"photo roles: {fetched} thumbnails in {(t1 - t0) / 60:.1f} min", flush=True)
    if args.clip:
        n = clip_scores(cache, products, args.clip, deadline)
        print(f"photo roles: MobileCLIP read {n} photos in {(time.time() - t1) / 60:.1f} min", flush=True)
        fetched += n
    if fetched:
        CACHE.parent.mkdir(exist_ok=True)
        CACHE.write_text(json.dumps(cache, separators=(",", ":")))
    counts = annotate(products, cache)
    print(f"photo roles: fetched {fetched} photos; {counts}")
    if not args.dry_run:
        write_catalog(CATALOG, catalog)


if __name__ == "__main__":
    sys.exit(main())
