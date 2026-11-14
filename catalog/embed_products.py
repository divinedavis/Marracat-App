#!/usr/bin/env python3
"""A "meaning" vector for every product, for the app's on-device AI features
(search by meaning, personalization, Shop by Style, similar items, Interests).

Apple's MobileCLIP2 (S4 since 2026-10-24; S0 still published for older app
builds, --model) reads each product's title (with its type and brand)
and its first photo into one shared space where words and pictures can be
compared; the app runs the same model's text half on the iPhone's Neural
Engine (Core ML) for what a shopper types. A product's vector is the average
of its text and photo vectors.

Vectors are cached per product in catalog/.cache/embeddings/ keyed by what was
read (title, type, brand, photo URL), so a rerun only reads new or changed
products. Photos stream through memory at 256 px and are never written to disk.

    ~/.venvs/marracat-ml/bin/python catalog/embed_products.py            # embed what's new
    ~/.venvs/marracat-ml/bin/python catalog/embed_products.py --publish  # + write the app's file
    ~/.venvs/marracat-ml/bin/python catalog/embed_products.py --model s4 --publish  # S4 (product-vectors-v2)

--publish writes catalog/.cache/embeddings/product-vectors.bin: PCA to 256
dimensions, int8, with the projection the app applies to query vectors.
Format (little-endian): "MRV1", u32 version (2), u32 dims (256), u32 model
dims (512), u32 count, f32 mean[512], f32 projection[512*256], f32
scale[count], f32 hub[count], then for each product u32 id length + UTF-8
id, then int8 vectors[count*256].

hub[i] is how close product i sits to shopping phrases in general (the mean
of its 20 best similarities to the catalog's ~320 department and aisle
names). A few products sit close to every phrase and surfaced for every
search; the app ranks by similarity - 0.5 * hub (HUB_WEIGHT), which on the
2026-10-02 evaluation turned "gift for my mom who loves candles" from a hat
and a conditioner into mom-themed candles.
"""
import argparse
import concurrent.futures as cf
import hashlib
import io
import json
import os
import struct
import sys
import time
import urllib.request
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Marracat/Resources/catalog-compact.json"
# Which MobileCLIP2 builds the vectors (--model). S4 since 2026-10-24 (owner:
# "switch to s4"; catalog/research/2026-10-24-embedding-eval). S0 keeps
# publishing product-vectors-v1.bin for app builds that still run S0's text
# model; S4's file is product-vectors-v2.bin. Each has its own cache and
# frozen projection, so the two spaces never mix.
MODELS = {"s0": ("MobileCLIP2-S0", ROOT / "catalog/.cache/embeddings"),
          "s4": ("MobileCLIP2-S4", ROOT / "catalog/.cache/embeddings-s4")}
MODEL, CACHE = MODELS["s0"]
DIMS = 256
UA = "Mozilla/5.0 (compatible; Marracat catalog builder)"


def key(p, brand_name):
    text = text_for(p, brand_name)
    return hashlib.sha1(f"{text}|{(p.get('images') or [''])[0]}".encode()).hexdigest()


def text_for(p, brand_name):
    kind = p.get("productType") or p.get("product_type") or ""
    return " ".join(x for x in [p["title"], kind, f"by {brand_name}" if brand_name else ""] if x)[:300]


def image_url(raw):
    if "cdn.shopify.com" in raw or "/cdn/shop/" in raw:
        sep = "&" if "?" in raw else "?"
        return f"{raw}{sep}width=256"
    return raw


def fetch(url):
    from PIL import Image
    try:
        req = urllib.request.Request(image_url(url), headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=15) as r:
            data = r.read(8_000_000)
        im = Image.open(io.BytesIO(data))
        im.draft("RGB", (320, 320))
        return im.convert("RGB")
    except Exception:  # noqa: BLE001 - a missing photo falls back to text only
        return None


def load_cache():
    CACHE.mkdir(parents=True, exist_ok=True)
    f = CACHE / "vectors.npz"
    if not f.exists():
        return {}
    z = np.load(f, allow_pickle=False)
    return dict(zip(z["keys"].tolist(), z["vectors"]))


def save_cache(cache):
    keys = np.array(list(cache.keys()))
    vectors = np.stack(list(cache.values())).astype(np.float16) if cache else np.zeros((0, 768), np.float16)
    tmp = CACHE / "vectors.tmp.npz"
    np.savez(tmp, keys=keys, vectors=vectors)
    os.replace(tmp, CACHE / "vectors.npz")


def embed(todo, brands, cache):
    import torch
    import open_clip
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    model, _, preprocess = open_clip.create_model_and_transforms(MODEL, pretrained="dfndr2b")
    model = model.to(device).eval()
    tok = open_clip.get_tokenizer(MODEL)
    batch, started, done = 128, time.time(), 0
    with cf.ThreadPoolExecutor(48) as pool:
        for i in range(0, len(todo), batch):
            chunk = todo[i:i + batch]
            names = [brands.get(p["brand"], "") for p in chunk]
            images = list(pool.map(lambda p: fetch((p.get("images") or [""])[0]) if p.get("images") else None, chunk))
            with torch.no_grad():
                t = model.encode_text(tok([text_for(p, n) for p, n in zip(chunk, names)]).to(device))
                t = (t / t.norm(dim=-1, keepdim=True)).float().cpu().numpy()
                have = [j for j, im in enumerate(images) if im is not None]
                v = t.copy()
                if have:
                    x = torch.stack([preprocess(images[j]) for j in have]).to(device)
                    im = model.encode_image(x)
                    im = (im / im.norm(dim=-1, keepdim=True)).float().cpu().numpy()
                    for k, j in enumerate(have):
                        v[j] = t[j] + im[k]
            v /= np.linalg.norm(v, axis=1, keepdims=True)
            # Kept at the cache file's float16 from the start: half the memory
            # for a run's new vectors, and the same numbers the next run reads.
            for p, n, vec in zip(chunk, names, v.astype(np.float16)):
                cache[key(p, n)] = vec
            done += len(chunk)
            if (i // batch) % 20 == 0:
                save_cache(cache)
                # Hand MPS's cached blocks back (owner, 2026-11-01: keep the
                # Mac under 15 GB; an S4 run had grown to 18 GB).
                if device == "mps":
                    torch.mps.empty_cache()
                rate = done / max(time.time() - started, 1e-6)
                print(f"  {done}/{len(todo)} ({rate:.0f}/s, ~{(len(todo) - done) / max(rate, 1e-6) / 60:.0f} min left)", flush=True)
    save_cache(cache)
    del model
    if device == "mps":
        torch.mps.empty_cache()


def publish(products, brands, cache, names):
    rows = [(p["id"], cache.get(key(p, brands.get(p["brand"], "")))) for p in products]
    rows = [(i, v) for i, v in rows if v is not None]
    X = np.stack([v for _, v in rows]).astype(np.float32)
    # The projection is fitted once and kept (catalog/.cache/embeddings/
    # projection.npz): vectors the app stores (a shopper's interests, style
    # boards) live in this space, and a re-fit on every publish would quietly
    # move them. Delete the file only to re-fit on purpose.
    proj = CACHE / "projection.npz"
    if proj.exists():
        z = np.load(proj)
        mean, P = z["mean"].astype(np.float32), z["P"].astype(np.float32)
        centred = X - mean
        kept = float(((centred @ P) ** 2).sum() / (centred ** 2).sum())
    else:
        mean = X.mean(0)
        # PCA by SVD of a sample: the top DIMS directions keep most of the meaning.
        rng = np.random.default_rng(0)
        sample = X[rng.choice(len(X), min(len(X), 40000), replace=False)] - mean
        _, s, vt = np.linalg.svd(sample, full_matrices=False)
        P = vt[:DIMS].T.astype(np.float32)                       # model dims x DIMS
        kept = float((s[:DIMS] ** 2).sum() / (s ** 2).sum())
        np.savez(proj, mean=mean, P=P)
    Y = (X - mean) @ P
    Y /= np.linalg.norm(Y, axis=1, keepdims=True)
    scale = np.abs(Y).max(1) / 127.0
    Q = np.round(Y / scale[:, None]).astype(np.int8)
    hub = hub_scores(Q.astype(np.float32) * scale[:, None], mean, P, names)
    out = CACHE / "product-vectors.bin"
    with open(out, "wb") as f:
        f.write(b"MRV1")
        f.write(struct.pack("<IIII", 2, DIMS, X.shape[1], len(rows)))
        f.write(mean.astype("<f4").tobytes())
        f.write(P.astype("<f4").tobytes())
        f.write(scale.astype("<f4").tobytes())
        f.write(hub.astype("<f4").tobytes())
        for i, _ in rows:
            b = i.encode()
            f.write(struct.pack("<I", len(b)))
            f.write(b)
        f.write(Q.tobytes())
    print(f"published {len(rows)} vectors, {DIMS} dims (PCA keeps {kept:.0%} of the variance), "
          f"{out.stat().st_size / 1e6:.0f} MB -> {out}")


def hub_scores(V, mean, P, names):
    """Each product's mean of its 20 best similarities to the catalog's
    department and aisle names (`names`, from the catalog main() already
    read: reading the 122 MB file a second time cost ~1.5 GB), in the
    published space."""
    import torch
    import open_clip
    model, _, _ = open_clip.create_model_and_transforms(MODEL, pretrained="dfndr2b")
    tok = open_clip.get_tokenizer(MODEL)
    with torch.no_grad():
        t = model.eval().encode_text(tok(names))
        t = (t / t.norm(dim=-1, keepdim=True)).numpy()
    T = (t - mean) @ P
    T /= np.linalg.norm(T, axis=1, keepdims=True)
    hub = np.zeros(len(V), np.float32)
    for i in range(0, len(V), 8192):
        sims = V[i:i + 8192] @ T.T
        hub[i:i + 8192] = np.sort(np.partition(sims, -20, axis=1)[:, -20:], axis=1).mean(1)
    print(f"hub scores from {len(names)} phrases: mean {hub.mean():.2f}, p99 {np.percentile(hub, 99):.2f}")
    return hub


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--publish", action="store_true")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--model", choices=MODELS, default="s0")
    args = ap.parse_args()
    global MODEL, CACHE
    MODEL, CACHE = MODELS[args.model]
    print(f"model {MODEL}, cache {CACHE.relative_to(ROOT)}", flush=True)
    catalog = json.load(open(CATALOG))
    brands = {b["id"]: b["name"] for b in catalog["brands"]}
    products = catalog["products"]
    names = sorted({c["name"] for c in catalog["categories"]} | {s["name"] for s in catalog.get("subcategories", [])})
    cache = load_cache()
    todo = [p for p in products if key(p, brands.get(p["brand"], "")) not in cache]
    if args.limit:
        todo = todo[:args.limit]
    print(f"{len(products)} products, {len(products) - len(todo)} cached, embedding {len(todo)}", flush=True)
    if todo:
        embed(todo, brands, cache)
    if args.publish:
        publish(products, brands, cache, names)


if __name__ == "__main__":
    sys.exit(main())
