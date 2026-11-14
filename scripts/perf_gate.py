#!/usr/bin/env python3
"""Performance budget for every ship (2026-10-02). Reads the XCTMetric numbers
PerformanceTests left in an .xcresult and compares each one with its baseline in
scripts/perf_baseline.json.

The baseline follows the app instead of being a fixed number (owner: "these
should be dynamic as i build features and remove features"):
  * a new performance test or metric is recorded the first time it runs;
  * one whose test was removed drops out of the file;
  * each passing ship (--record) adds its median to that metric's last 5, and
    the baseline is the median of those, so a feature that honestly costs a
    little moves the bar after a few ships while a sudden 1.5x jump fails.

FAIL when a "prefers smaller" metric's median is more than TOLERANCE over its
baseline. The tolerance is wide on purpose: it is a simulator on a Mac that
other work shares, so it catches a doubling, not a 10% wobble.

A failing first run is not trusted alone (2026-10-21: the Home stall read
156, 180, 228, 261, 174 ms on five ships with no related change): ship.sh runs
the tests twice more and passes every bundle here; each metric is judged on
the median of the runs' medians.

A rolling baseline alone lets a slow creep through: every ship a little
slower than the last still passes, and the bar follows it up (launch went
1,908 -> 2,017 ms over five passing ships, 2026-11-09). So some metrics also
have a FIXED ceiling in scripts/perf_ceilings.json, which no ship may pass
whatever the recent ones did. Raising one is a deliberate edit to that file,
with the reason, never something a run of slow ships does by itself. The
same median-of-three retry applies.

  python3 scripts/perf_gate.py build/gates/Perf.xcresult [more.xcresult ...] [--record]
"""
import json, os, statistics, subprocess, sys

TOLERANCE = 0.5      # fail above baseline * 1.5
KEEP = 5             # passing ships remembered per metric
# A relative bar is meaningless on a tiny number: "Memory Physical" during a
# scroll is the GROWTH in kB, ~300-1,700 kB from run to run on one build
# (2026-10-03: 852 vs a 344 baseline failed while total memory had dropped
# 320 MB -> 183 MB). A metric must also be this much worse, in its unit, to
# fail. The Home fling's hitch numbers (2026-10-11) sit near the noise of
# XCUITest's own accessibility snapshots (~70-200 ms stalls it causes in the
# app): a stall must grow by 3+ frames at 60 Hz, the hitch ratio by 20 ms/s.
MIN_REGRESSION = {"kB": 5000, "ms": 50, "ms/s": 20}
HERE = os.path.dirname(os.path.abspath(__file__))
BASELINE = os.path.join(HERE, "perf_baseline.json")
CEILINGS = os.path.join(HERE, "perf_ceilings.json")


def load_ceilings(path=CEILINGS):
    """{metric key: max} from perf_ceilings.json; a missing file means none."""
    try:
        raw = json.load(open(path))
    except FileNotFoundError:
        return {}
    return {k: float(v["max"]) for k, v in raw.items() if isinstance(v, dict) and "max" in v}


def over_ceiling(m, ceiling):
    """True when a prefers-smaller metric's median is above its fixed ceiling."""
    return ceiling is not None and m["smaller"] and m["median"] > ceiling


def read_metrics(xcresult):
    out = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "metrics", "--path", xcresult],
                         capture_output=True, text=True, check=True).stdout
    got = {}
    for t in json.loads(out):
        for run in t.get("testRuns", []):
            for m in run.get("metrics", []):
                if not m.get("measurements"):
                    continue
                key = f"{t['testIdentifier']} :: {m['displayName']}"
                got[key] = {"median": statistics.median(m["measurements"]), "unit": m.get("unitOfMeasurement", ""),
                            "smaller": m.get("polarity", "prefers smaller") == "prefers smaller"}
    return got


def regressed(m, ref):
    """True when metric `m` ({median, unit, smaller}) is worse than baseline
    `ref` by more than TOLERANCE and, in its unit, by more than MIN_REGRESSION."""
    over = m["median"] > ref * (1 + TOLERANCE) if m["smaller"] else m["median"] < ref * (1 - TOLERANCE)
    if over and m["smaller"] and m["median"] - ref < MIN_REGRESSION.get(m["unit"], 0):
        over = False
    return over


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    record = "--record" in sys.argv
    if not args:
        print(__doc__); return 2
    runs = [read_metrics(a) for a in args]
    got = {}
    for key in set().union(*runs):
        have = [r[key] for r in runs if key in r]
        got[key] = {**have[0], "median": statistics.median(m["median"] for m in have)}
    if len(runs) > 1:
        print(f"judging the median of {len(runs)} runs")
    if not got:
        print("perf gate: no performance metrics in the result bundle — did PerformanceTests run?")
        return 1
    try:
        base = json.load(open(BASELINE))
    except FileNotFoundError:
        base = {}

    ceilings = load_ceilings()
    failed = []
    print(f"{'metric':<92} {'now':>9} {'baseline':>9}  verdict")
    for key, m in sorted(got.items()):
        hist = base.get(key, {}).get("history", [])
        if not hist:
            verdict, ref = "new (recorded)", None
        else:
            ref = statistics.median(hist)
            over = regressed(m, ref)
            verdict = f"FAIL (>{int(TOLERANCE * 100)}% worse)" if over else "ok"
            if over:
                failed.append(key)
        if over_ceiling(m, ceilings.get(key)):
            verdict = f"FAIL (over the fixed ceiling of {ceilings[key]:g})"
            if key not in failed:
                failed.append(key)
        elif key in ceilings and verdict == "ok":
            verdict = f"ok (ceiling {ceilings[key]:g})"
        print(f"{key:<92} {m['median']:>9.3f} {ref if ref is not None else float('nan'):>9.3f}  {verdict}  {m['unit']}")
    gone = sorted(set(base) - set(got))
    for key in sorted(set(ceilings) - set(got)):
        print(f"warning: scripts/perf_ceilings.json names a metric that did not run: {key}")
    for key in gone:
        print(f"{key:<92} {'—':>9} {'':>9}  removed (test no longer exists)")

    if failed:
        print(f"perf gate FAILED: {len(failed)} metric(s) regressed. Profile it (Instruments > Time Profiler) before shipping.")
        return 1
    if record:
        new = {k: {"history": (base.get(k, {}).get("history", []) + [round(m["median"], 4)])[-KEEP:], "unit": m["unit"]}
               for k, m in got.items()}
        with open(BASELINE, "w") as f:
            json.dump(new, f, indent=2, sort_keys=True); f.write("\n")
        print(f"perf gate OK — baseline updated ({len(new)} metrics, {len(gone)} removed)")
    else:
        print("perf gate OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
