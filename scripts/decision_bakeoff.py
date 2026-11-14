#!/usr/bin/env python3
"""Decision-model bake-off on Marracat's own catalog judgments.

Owner, 2026-11-12: "i think we should try these and see which ones perform
better than jev and compare pricing" (a screenshot of Artificial Analysis's
Decision Index: Drex Max v1.1, GLiDE v1.2, Mammoth 27B, d1-ultra,
Decider v1.2, and Google's Gemini Decision 1). Benchmarks are other people's
tasks; this asks every model the same questions Marracat asks Jev and scores
the answers against an answer key the models never see.

Two tasks, built from Marracat/Resources/catalog.json with a fixed seed:

  department  Choice: which department a product belongs in, from its title,
              description and brand (what catalog/jev_categories.py asks).
              Truth: the brand's own Shopify product_type, used only for types
              that map to one department at least 97% of the time across the
              catalog, and never for a product Jev has moved (so the key can't
              lean toward Jev).
  is_a        Noul / predicate: "Is this product a <type>?", the core of search
              matching. Half true (that product_type), half look-alikes from
              the same department. Truth: product_type, hidden from the model.

Every model is called through Vercel AI Gateway's OpenAI-compatible
/decisions endpoint (one key, identical request), so only the model differs.
GLiDE isn't on the gateway (Fastino's own API); it is listed as not run.

Scores per model and task: accuracy, Brier score (lower is better), the
Decision Score Artificial Analysis uses, 50 x (1 + accuracy - Brier), median
and p95 latency, the gateway's reported cost, and failed calls.

    AI_GATEWAY_API_KEY=... scripts/decision_bakeoff.py [--n 300] [--models a,b] [--budget 2.00]
    scripts/decision_bakeoff.py --dry-run          # build the test sets only, no calls

Writes build/bakeoff/<task>.json (the sets), build/bakeoff/answers.jsonl and
build/bakeoff/report.md. A hard --budget (dollars, from the gateway's own cost
field) stops the run before it can overspend.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import statistics
import sys
import threading
import time
import urllib.error
import urllib.request
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "build" / "bakeoff"
GATEWAY = "https://ai-gateway.vercel.sh/v1/decisions"
SEED = 20261112

# The screenshot's models, Jev, and the cheaper siblings on the gateway, for the price comparison.
MODELS = [
    "typesafe-ai/jev-1.14.0",
    "direct:jev-1.14.0",
    "nace-ai/drex-max-v1.1",
    "baseten/mammoth-1",
    "liquid/d1-ultra",
    "perplexity/pplx-decider-v1.2",
    "google/gemini-decision-1",
    "microsoft/microsoft-decision-1",
    "nace-ai/drex-v2.0",
    "perplexity/pplx-decider-flash-v1.2",
    "liquid/d1",
    "baseten/elephant-1",
]
NOT_ON_GATEWAY = {"fastino/glide-v1.2": "GLiDE v1.2 is on Fastino's own API, not Vercel AI Gateway"}
# Jev also runs straight through TypeSafe with Marracat's own key ("direct:"), the way the
# catalog calls it, beside the gateway's Jev: same model, two paths, to show the routing cost.
# The gateway's free tier serves neither Jev, Gemini Decision 1, Microsoft Decision-1 nor
# Liquid d1, and limits each provider to 5 requests a minute, so the run needs paid credit
# (the owner added it on 2026-11-12).
FREE_TIER_BLOCKED = []
TYPESAFE_PER_TOKEN = 0.042 / 1e6


def clip(text, n):
    text = " ".join(str(text or "").split())
    return text if len(text) <= n else text[: n - 1] + "…"


def build_sets(n, seed=SEED):
    catalog = json.loads((ROOT / "Marracat" / "Resources" / "catalog.json").read_text())
    names = {c["id"]: c["name"] for c in catalog["categories"]}
    brands = {b["id"]: b["name"] for b in catalog["brands"]}
    moved = {pid for pid, v in json.loads((ROOT / "catalog" / "jev_categories.json").read_text()).items()
             if isinstance(v, dict) and v.get("choice") and v.get("choice") != v.get("was")}
    products = [p for p in catalog["products"] if p.get("product_type") and p.get("title") and p["id"] not in moved]
    by_type = defaultdict(Counter)
    for p in products:
        by_type[p["product_type"].strip().lower()][p["category"]] += 1
    clean = {}
    for t, cats in by_type.items():
        total = sum(cats.values())
        cat, top = cats.most_common(1)[0]
        if total >= 30 and top / total >= 0.97 and len(t) >= 3 and cat in names:
            clean[t] = cat
    rng = random.Random(seed)

    def state(p):
        return {"product": {"title": clip(p["title"], 140), "brand": brands.get(p["brand"], p["brand"]),
                            "description": clip(p.get("description"), 500)}}

    # department: spread across departments, at most n // len(departments) + 1 each.
    pool = [p for p in products if p["product_type"].strip().lower() in clean]
    rng.shuffle(pool)
    cap = n // max(1, len(set(clean.values()))) + 1
    taken, dept = Counter(), []
    for p in pool:
        truth = clean[p["product_type"].strip().lower()]
        if taken[truth] < cap:
            taken[truth] += 1
            dept.append({"id": p["id"], "state": state(p), "truth": truth})
        if len(dept) >= n:
            break

    # is_a: only types that are product words, i.e. the type's name appears in at least 60% of
    # its products' titles ("headwrap", "candle"), not a collection name ("new world") or a
    # hypernym ("beverage", where "is this bourbon a beverage? no" would be a wrong key). A
    # look-alike never has the query word in its title.
    def named(t):
        ps = [p for p in pool if p["product_type"].strip().lower() == t]
        return ps and sum(t in p["title"].lower() for p in ps) / len(ps) >= 0.6
    types = sorted(t for t in clean if named(t))
    rng.shuffle(types)
    by_cat_type = defaultdict(list)
    for p in pool:
        by_cat_type[(clean[p["product_type"].strip().lower()], p["product_type"].strip().lower())].append(p)
    is_a = []
    for t in types:
        cat = clean[t]
        pos = by_cat_type[(cat, t)]
        neg = [p for (c, tt), ps in by_cat_type.items() if c == cat and tt != t and t not in tt and tt not in t
               for p in ps[:20] if t not in p["title"].lower()]
        if not pos or not neg:
            continue
        for p, truth in ((rng.choice(pos), True), (rng.choice(neg), False)):
            is_a.append({"id": p["id"], "state": state(p), "query": t, "truth": truth})
        if len(is_a) >= n:
            break
    return {"department": dept, "is_a": is_a, "departments": {c: names[c] for c in sorted(set(clean.values()))}}


def question(task, item, departments):
    if task == "department":
        return {"type": "choice", "name": "department",
                "instructions": "Which department of an online store does `product` belong in?",
                "choices": [{"value": c, "description": n} for c, n in departments.items()]}
    return {"type": "predicate", "name": "is_a",
            "instructions": f"Is `product` a {item['query']}? Answer yes only if the product itself is a {item['query']}, "
                            "not an accessory for one or a different kind of product."}


class Budget:
    def __init__(self, dollars):
        self.limit, self.spent, self.lock = dollars, 0.0, threading.Lock()

    def add(self, cost):
        with self.lock:
            self.spent += cost
            return self.spent < self.limit


def ask_typesafe(model, task, item, departments, attempts=3):
    """The same question to Jev through TypeSafe's own SDK, answered in the gateway's shape."""
    from typesafe_sdk import Choice, Noul, TypeSafeClient
    q = question(task, item, departments)
    tq = (Choice(instructions=q["instructions"], criteria={c["value"]: c["description"] for c in q["choices"]})
          if task == "department" else Noul(instructions=q["instructions"]))
    client = TypeSafeClient()
    for attempt in range(attempts):
        t = time.time()
        try:
            r = client.system_one(state=item["state"], questions={"q": tq}, model=model)
        except Exception as e:  # noqa: BLE001
            if attempt < attempts - 1:
                time.sleep(2 * (attempt + 1))
                continue
            return {"ok": False, "error": f"{type(e).__name__}: {str(e)[:200]}"}
        ms = (time.time() - t) * 1000
        a = r.answers["q"]
        answer = ({"choice": a.choice, "probabilities": [{"value": k, "probability": v} for k, v in a.probabilities.items()]}
                  if task == "department" else {"probability": a.noul})
        tokens = r.usage.input_tokens
        return {"ok": True, "ms": ms, "answer": answer, "cost": tokens * TYPESAFE_PER_TOKEN, "tokens": tokens}


def ask(key, model, task, item, departments, attempts=3):
    if model.startswith("direct:"):
        return ask_typesafe(model.removeprefix("direct:"), task, item, departments, attempts)
    body = {"model": model, "input": [{"role": "user", "content": [{"type": "input_json", "data": item["state"]}]}],
            "questions": [question(task, item, departments)]}
    req = urllib.request.Request(GATEWAY, data=json.dumps(body).encode(), method="POST",
                                 headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    for attempt in range(attempts):
        t = time.time()
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                res = json.loads(r.read())
            ms = (time.time() - t) * 1000
            ans = (res.get("answers") or [{}])[0]
            cost = float(((res.get("provider_metadata") or {}).get("gateway") or {}).get("cost") or 0)
            return {"ok": True, "ms": ms, "answer": ans, "cost": cost,
                    "tokens": (res.get("usage") or {}).get("input_tokens")}
        except urllib.error.HTTPError as e:
            detail = e.read()[:300].decode("utf-8", "replace")
            if e.code in (429, 500, 502, 503, 504) and attempt < attempts - 1:
                time.sleep(2 * (attempt + 1))
                continue
            return {"ok": False, "error": f"HTTP {e.code}: {detail}"}
        except (OSError, ValueError) as e:
            if attempt < attempts - 1:
                time.sleep(2)
                continue
            return {"ok": False, "error": f"{type(e).__name__}: {e}"}


def probabilities(task, ans):
    """(predicted label, probability given to the true answer's alternatives) per task."""
    if task == "department":
        probs = {p.get("value"): p.get("probability", 0.0) for p in ans.get("probabilities") or []}
        if not probs and ans.get("choice") is not None:
            probs = {ans["choice"]: 1.0}
        return probs
    p = ans.get("probability")
    return {True: p, False: None if p is None else 1 - p}


def score(task, rows):
    ok = [r for r in rows if r["ok"]]
    correct, brier = [], []
    for r in ok:
        probs = probabilities(task, r["answer"])
        if not probs or any(v is None for v in probs.values()):
            continue
        pred = max(probs, key=probs.get)
        correct.append(pred == r["truth"])
        if task == "department":
            brier.append(sum((probs.get(c, 0.0) - (1.0 if c == r["truth"] else 0.0)) ** 2 for c in set(probs) | {r["truth"]}) / 2)
        else:
            brier.append((probs[True] - (1.0 if r["truth"] else 0.0)) ** 2)
    ms = sorted(r["ms"] for r in ok)
    acc = sum(correct) / len(correct) if correct else 0.0
    b = statistics.mean(brier) if brier else 1.0
    return {"n": len(rows), "answered": len(correct), "failed": len(rows) - len(ok), "accuracy": acc, "brier": b,
            "decision_score": 50 * (1 + acc - b), "p50_ms": ms[len(ms) // 2] if ms else None,
            "p95_ms": ms[int(len(ms) * 0.95) - 1] if ms else None, "cost": sum(r.get("cost", 0) for r in ok),
            "tokens": sum(r.get("tokens") or 0 for r in ok)}


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=300)
    ap.add_argument("--models", default=",".join(MODELS))
    ap.add_argument("--budget", type=float, default=2.00, help="stop once the gateway's reported cost reaches this")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args(argv)
    OUT.mkdir(parents=True, exist_ok=True)
    sets = build_sets(a.n)
    for task in ("department", "is_a"):
        (OUT / f"{task}.json").write_text(json.dumps(sets[task], indent=1, ensure_ascii=False))
    print(f"department: {len(sets['department'])} items over {len(sets['departments'])} departments "
          f"{dict(Counter(i['truth'] for i in sets['department']))}")
    print(f"is_a: {len(sets['is_a'])} items, {sum(i['truth'] for i in sets['is_a'])} true")
    if a.dry_run:
        return
    key = os.environ.get("AI_GATEWAY_API_KEY") or (Path.home() / ".config" / "vercel" / "ai_gateway_key").read_text().strip()
    budget = Budget(a.budget)
    results = defaultdict(dict)
    log = open(OUT / "answers.jsonl", "w")
    for model in a.models.split(","):
        for task in ("department", "is_a"):
            items = sets[task]

            def one(item, model=model, task=task):
                res = ask(key, model, task, item, sets["departments"])
                if res["ok"] and not budget.add(res["cost"]):
                    raise SystemExit(f"budget ${a.budget:.2f} reached")
                return {**res, "truth": item["truth"], "id": item["id"]}

            with ThreadPoolExecutor(max_workers=a.workers) as pool:
                rows = list(pool.map(one, items))
            for r in rows:
                log.write(json.dumps({"model": model, "task": task, **r}, default=str) + "\n")
            results[model][task] = s = score(task, rows)
            print(f"{model:36} {task:10} acc {s['accuracy']:.3f} brier {s['brier']:.3f} DS {s['decision_score']:.1f} "
                  f"p50 {s['p50_ms'] or 0:.0f}ms fail {s['failed']} cost ${s['cost']:.4f}", flush=True)
            if s["failed"] == len(rows):
                print(f"  first error: {rows[0].get('error')}", flush=True)
    log.close()
    report(results, sets, budget.spent)


def report(results, sets, spent):
    lines = ["# Decision-model bake-off on Marracat's catalog judgments", "",
             f"Department: {len(sets['department'])} products over {len(sets['departments'])} departments. "
             f"Is-a: {len(sets['is_a'])} questions, half true. Same questions to every model through Vercel AI Gateway "
             f"/decisions. Total spend ${spent:.4f}.", "",
             "Decision Score = 50 x (1 + accuracy - Brier), as Artificial Analysis computes it. Cost is the gateway's own figure.", ""]
    for task in ("department", "is_a"):
        lines += [f"## {task}", "", "| Model | Accuracy | Brier | Decision Score | p50 ms | p95 ms | Failed | Cost | Cost per 1M questions |",
                  "|---|---|---|---|---|---|---|---|---|"]
        rows = sorted(((m, r[task]) for m, r in results.items() if task in r), key=lambda x: -x[1]["decision_score"])
        for m, s in rows:
            per_m = s["cost"] / max(1, s["answered"]) * 1e6
            lines.append(f"| {m} | {s['accuracy']:.3f} | {s['brier']:.3f} | {s['decision_score']:.1f} | "
                         f"{s['p50_ms'] or 0:.0f} | {s['p95_ms'] or 0:.0f} | {s['failed']} | ${s['cost']:.4f} | ${per_m:.2f} |")
        lines.append("")
    lines += ["Not run: " + "; ".join(f"{m} ({why})" for m, why in NOT_ON_GATEWAY.items()) + ".",
              "direct:jev-1.14.0 is the same Jev called through TypeSafe's own API, as Marracat's catalog calls it, "
              "priced at TypeSafe's $0.042 per million input tokens.", ""]
    (OUT / "report.md").write_text("\n".join(lines))
    print(f"report: {OUT / 'report.md'}")


if __name__ == "__main__":
    main(sys.argv[1:])
