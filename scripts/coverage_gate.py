#!/usr/bin/env python3
"""Every screen is exercised by a test (2026-10-03; owner: the checks must
follow features as they are added and removed).

Reads the code coverage of ship.sh's test run (unit + XCUITest, collected with
-enableCodeCoverage YES) and fails any screen file — Marracat/Views/*,
Social/SocialViews.swift, the Checkout views — that no test executed a single
line of. A new screen cannot ship without a test that opens it, and nothing is
listed by hand: the folders ARE the list. A deleted screen drops out; a UI test
still looking for it fails on its own (waitForExistence).

  python3 scripts/coverage_gate.py build/gates/Ship.xcresult
"""
import json, re, subprocess, sys

SCREENS = re.compile(r"/Marracat/(Views/[^/]+|Social/SocialViews|Checkout/[^/]*View[^/]*|Checkout/WooCheckoutSheet)\.swift$")


def main():
    if len(sys.argv) < 2:
        print(__doc__); return 2
    out = subprocess.run(["xcrun", "xccov", "view", "--report", "--json", sys.argv[1]],
                         capture_output=True, text=True, check=True).stdout
    files = {}
    for target in json.loads(out).get("targets", []):
        for f in target.get("files", []):
            m = SCREENS.search(f["path"])
            if m:
                files[m.group(1)] = max(files.get(m.group(1), 0), f.get("coveredLines", 0))
    if not files:
        print("coverage gate: no screen files in the coverage report — was -enableCodeCoverage YES set?")
        return 1
    cold = sorted(k for k, n in files.items() if n == 0)
    print(f"coverage gate: {len(files) - len(cold)}/{len(files)} screen files exercised by a test")
    if cold:
        print("NO TEST touches these screens (add a UI test that opens each one):")
        for c in cold:
            print(f"  - Marracat/{c}.swift")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
