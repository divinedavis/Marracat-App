#!/usr/bin/env python3
"""Test tiers and the flaky-test quarantine for scripts/ship.sh (owner,
2026-10-25: "fast set nightly. quarantine flaky ui tests. trim the
accessibility audit").

    flaky_tests.py args fast|full        xcodebuild selection for the gating run
    flaky_tests.py quarantined fast|full -only-testing for the quarantine pass ("" = none)
    flaky_tests.py record fast|full GATE.xcresult [QUARANTINE.xcresult]

Tiers: "full" runs every test; "fast" runs all unit tests (MarracatTests) and
the UI tests in MarracatUITests/fast-tests.txt. Either way the tests in
MarracatUITests/quarantine.txt are skipped in the gating run and run on their
own afterwards, where a failure is reported but fails nothing.

record notes, per ship, which UI tests needed a retry or failed (gating) and
how quarantined ones did, in scripts/flaky_history.json (last 20 ships), then
keeps quarantine.txt: a test flagged in 2 of the last 5 ships comes in; a
quarantined test that passed first time in each of the last 5 ships it ran in
goes back. daily_ship.sh commits both files with the build bump.
"""
import json
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FAST = ROOT / "MarracatUITests/fast-tests.txt"
QUARANTINE = ROOT / "MarracatUITests/quarantine.txt"
HISTORY = ROOT / "scripts/flaky_history.json"
KEEP, WINDOW, FLAGS_IN, CLEAN_RUNS = 20, 5, 2, 5


def names(path):
    if not path.exists():
        return []
    return [line.strip() for line in path.read_text().splitlines() if line.strip() and not line.startswith("#")]


def args(tier):
    out = []
    if tier == "fast":
        out += ["-only-testing:MarracatTests"] + [f"-only-testing:MarracatUITests/{t}" for t in names(FAST)]
    out += [f"-skip-testing:MarracatUITests/{t}" for t in names(QUARANTINE)]
    return out


def quarantined(tier):
    q = names(QUARANTINE)
    if tier == "fast":
        fast = set(names(FAST))
        q = [t for t in q if t in fast]
    return [f"-only-testing:MarracatUITests/{t}" for t in q]


def outcomes(xcresult):
    """{Class/test: "pass" | "retried" | "fail"} for the UI tests in a bundle."""
    if not xcresult or not Path(xcresult).exists():
        return {}
    raw = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(xcresult)],
                         capture_output=True, text=True, check=False).stdout
    if not raw:
        return {}
    out = {}

    def walk(n, suite=None, ui=False):
        t = n.get("nodeType")
        ui = ui or t == "UI test bundle"
        if t == "Test Suite":
            suite = n["name"]
        if t == "Test Case":
            if ui and suite:
                reps = [c for c in n.get("children", []) if c.get("nodeType") == "Repetition"]
                key = f"{suite}/{n['name'].removesuffix('()')}"
                if n.get("result") == "Failed":
                    out[key] = "fail"
                elif n.get("result") == "Passed":
                    out[key] = "retried" if len(reps) > 1 else "pass"
            return
        for c in n.get("children", []):
            walk(c, suite, ui)

    for t in json.loads(raw).get("testNodes", []):
        walk(t)
    return out


def update(history, current):
    """(new quarantine list, added, removed) from the ship history."""
    recent = history[-WINDOW:]
    flagged = {}
    for h in recent:
        for t in h.get("flagged", []):
            flagged[t] = flagged.get(t, 0) + 1
    added = sorted(t for t, n in flagged.items() if n >= FLAGS_IN and t not in current)
    removed = []
    for t in current:
        runs = [h["quarantine"][t] for h in history if t in h.get("quarantine", {})][-CLEAN_RUNS:]
        if len(runs) == CLEAN_RUNS and all(r == "pass" for r in runs):
            removed.append(t)
    keep = [t for t in current if t not in removed] + added
    return keep, added, removed


def write_quarantine(tests):
    head = [line for line in QUARANTINE.read_text().splitlines() if line.startswith("#")] if QUARANTINE.exists() else []
    QUARANTINE.write_text("\n".join(head + tests) + "\n")


def record(tier, gate, quarantine=None):
    history = json.loads(HISTORY.read_text()) if HISTORY.exists() else []
    g, q = outcomes(gate), outcomes(quarantine)
    history.append({"at": time.strftime("%Y-%m-%d %H:%M"), "tier": tier,
                    "flagged": sorted(t for t, r in g.items() if r != "pass"),
                    "quarantine": dict(sorted(q.items()))})
    history = history[-KEEP:]
    HISTORY.write_text(json.dumps(history, indent=1) + "\n")
    keep, added, removed = update(history, names(QUARANTINE))
    if added or removed:
        write_quarantine(keep)
    for t, r in sorted(q.items()):
        if r != "pass":
            print(f"quarantined {t}: {r} (not gating)")
    for t in added:
        print(f"quarantine: added {t} (flaky in {FLAGS_IN}+ of the last {WINDOW} ships)")
    for t in removed:
        print(f"quarantine: released {t} (passed first time {CLEAN_RUNS} ships running)")
    print(f"flaky tests: {len(history[-1]['flagged'])} flagged this ship, {len(keep)} quarantined")


def main(argv):
    cmd, tier = argv[1], argv[2]
    if tier not in ("fast", "full"):
        sys.exit(f"tier must be fast or full, not {tier}")
    if cmd == "args":
        print(" ".join(args(tier)))
    elif cmd == "quarantined":
        print(" ".join(quarantined(tier)))
    elif cmd == "record":
        record(tier, argv[3], argv[4] if len(argv) > 4 else None)
    else:
        sys.exit(f"unknown command {cmd}")


if __name__ == "__main__":
    main(sys.argv)
