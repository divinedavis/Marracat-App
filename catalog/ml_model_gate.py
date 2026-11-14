#!/usr/bin/env python3
"""No-degrade gate for a new on-device text model (owner, 2026-10-08).

Compares a candidate compiled model (.mlmodelc) with the reference the app
falls back to (mobileclip-text-v2, 32-bit) over every department and aisle
name in the catalog plus shopper phrases, on each Core ML compute unit, and
ranks the published product vectors the way the app does (similarity minus
0.5 x hub). A candidate passes only with no NaN/Inf, cosine >= 0.999 on
every phrase, top-20 overlap >= 95% on average and the same top product on
>= 98%. It also times one phrase per compute unit. Needs both models
unpacked locally (aa extract -d DIR -i model.aar) and the published vectors.

    ~/.venvs/marracat-ml/bin/python catalog/ml_model_gate.py CANDIDATE.mlmodelc REFERENCE.mlmodelc [s0|s4]

The third argument picks the model family and its vectors (default s4, the
app's model since 2026-10-24; s0 for S0's v2/v3).

v3 (2026-10-08, M5 Neural Engine): cos >= 0.99940, top-20 99.1%, top-1 98.9%,
1.1 ms vs v2's 5-10 ms.
"""
import json
import struct
import sys
import time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
FAMILIES = {"s0": ("MobileCLIP2-S0", ROOT / "catalog/.cache/embeddings/product-vectors.bin"),
            "s4": ("MobileCLIP2-S4", ROOT / "catalog/.cache/embeddings-s4/product-vectors.bin")}
MODEL, VECTORS = FAMILIES["s4"]
SHOPPER = ["gift for my mom who loves candles", "cozy fall sweater", "skincare for dry skin", "natural hair products for curls",
           "something for a new baby", "men's beard oil", "hot sauce gift set", "vegan lip gloss", "date night outfit",
           "self care sunday", "summer dress for a wedding", "coffee lover gift", "journal for gratitude", "shea butter body lotion",
           "edge control", "silk bonnet", "wall art for living room", "scented soy candle", "natural deodorant", "plant mom gift",
           "graduation present", "workout leggings", "hair growth oil", "earrings gold hoops", "baby shampoo", "tea sampler"]
UNITS = ["CPU_AND_NE", "ALL", "CPU_AND_GPU", "CPU_ONLY"]


def phrases():
    cat = json.load(open(ROOT / "Marracat/Resources/catalog-compact.json"))
    return sorted({c["name"] for c in cat["categories"]} | {s["name"] for s in cat["subcategories"]}) + SHOPPER


def read_vectors():
    d = VECTORS.read_bytes()
    assert d[:4] == b"MRV1"
    ver, dims, md, n = struct.unpack("<IIII", d[4:20])
    at = 20

    def f(k):
        nonlocal at
        a = np.frombuffer(d, np.float32, k, at)
        at += k * 4
        return a
    mean, P, scale = f(md), f(md * dims).reshape(md, dims), f(n)
    hub = f(n) if ver == 2 else np.zeros(n, np.float32)
    for _ in range(n):
        at += 4 + struct.unpack("<I", d[at:at + 4])[0]
    return mean, P, scale, hub, np.frombuffer(d, np.int8, n * dims, at).reshape(n, dims).astype(np.float32)


def top(V, e, k=20):
    mean, P, scale, hub, rows = V
    q = (e - mean) @ P
    q /= np.linalg.norm(q)
    s = (rows @ q) * scale - 0.5 * hub
    i = np.argpartition(-s, k)[:k]
    return list(i[np.argsort(-s[i])])


def main():
    import coremltools as ct
    import open_clip
    global MODEL, VECTORS
    cand, ref_path = sys.argv[1], sys.argv[2]
    MODEL, VECTORS = FAMILIES[sys.argv[3] if len(sys.argv) > 3 else "s4"]
    Q = phrases()
    T = open_clip.get_tokenizer(MODEL)(Q).numpy().astype(np.int32)
    V = read_vectors()

    def run(path, unit):
        m = ct.models.CompiledMLModel(path, compute_units=getattr(ct.ComputeUnit, unit))
        out = np.stack([m.predict({"tokens": T[i:i + 1]})["embedding"][0] for i in range(len(T))])
        for _ in range(5):
            m.predict({"tokens": T[:1]})
        ts = []
        for _ in range(100):
            t = time.perf_counter()
            m.predict({"tokens": T[:1]})
            ts.append((time.perf_counter() - t) * 1000)
        return out, float(np.median(ts))

    ref, ref_ms = run(ref_path, "ALL")
    ref_top = [top(V, e) for e in ref]
    print(f"{len(Q)} phrases, {len(V[-1])} products; reference (ALL) {ref_ms:.2f} ms")
    ok_all = True
    for unit in UNITS:
        out, ms = run(cand, unit)
        finite = np.isfinite(out).all()
        cos = (out * ref).sum(1)
        tops = [top(V, e) for e in out]
        overlap = np.mean([len(set(a) & set(b)) / 20 for a, b in zip(tops, ref_top)])
        same = np.mean([a[0] == b[0] for a, b in zip(tops, ref_top)])
        ok = bool(finite and cos.min() >= 0.999 and overlap >= 0.95 and same >= 0.98)
        ok_all &= ok if unit == "CPU_AND_NE" else True
        print(f"{unit:12s} {'PASS' if ok else 'FAIL'}  finite {finite}  cos min {cos.min():.5f}  "
              f"top-20 {overlap:.3f}  top-1 {same:.3f}  {ms:.2f} ms")
    sys.exit(0 if ok_all else 1)


if __name__ == "__main__":
    main()
