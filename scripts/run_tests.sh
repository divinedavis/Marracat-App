#!/usr/bin/env bash
# The one fast test command: every automated test that runs without a
# simulator, a browser or the network. The pre-push hook, web/deploy.sh and
# scripts/publish_catalog.sh all call it before anything leaves the Mac.
#
#   scripts/run_tests.sh
#
# What it runs:
#   1. Python: catalog/test_*.py + scripts/test_*.py (scripts/run_py_tests.py)
#   2. Shell:  bash -n over every deploy/ship script (a typo there only shows
#              up mid-deploy otherwise)
#      and no UI test calling the slow waitForExistence (Waiting.swift)
#      and no `xcresulttool | grep -q` under pipefail (a false gate failure)
#   3. Node:   web/tests/*.test.js (npm test, one file at a time, ~2.5 min)
#
# Deliberately NOT here (each runs elsewhere):
#   - MarracatTests (Swift unit) + MarracatUITests: need a simulator; ship.sh
#     runs both on every TestFlight build.
#   - web/tests/browser/*.spec.js (Playwright): needs a running site;
#     `cd web && npm run test:browser`.
#   - catalog/audit_categories.py --max-risky 30: a data gate over the built
#     catalog, ~40 s; ship.sh runs it, and so must a brand-only publish.
#   - checkout.test.js "a real store builds a checkout": opt-in, REAL_UCP=1
#     (talks to a live Shopify store).
#   - scripts/search_parity.sh: the website's search against the app's own
#     Swift search code, ~1 min; needs Xcode's swiftc. Run it after changing
#     search on either side.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== python"
python3 scripts/run_py_tests.py

echo "== shell syntax"
for f in scripts/*.sh web/deploy.sh .githooks/pre-push refresh-server/*.sh refresh-server/receiver/* refresh-server/signer/*; do
  [[ -f "$f" ]] || continue
  case "$f" in *.socket|*.service) continue ;; esac   # systemd units
  case "$(head -n 1 "$f")" in
    "#!"*python*) python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$f" || { echo "syntax error in $f" >&2; exit 1; }; continue ;;
  esac
  bash -n "$f" || { echo "syntax error in $f" >&2; exit 1; }
done
echo "shell syntax: ok"
# Under pipefail, `xcresulttool … | grep -q` fails whenever grep stops early on a
# long list (SIGPIPE, exit 141): it stopped build 179's ship on an audit that ran.
if grep -nE 'xcresulttool[^|]*\|[[:space:]]*grep[[:space:]]+-[a-zA-Z]*q' scripts/*.sh \
    | grep -vE '^scripts/run_tests\.sh:|^[^:]+:[0-9]+:[[:space:]]*#'; then
  echo "read xcresulttool output into a variable before searching it (pipefail + grep -q)" >&2; exit 1
fi

echo "== UI test waits"
# waitForExistence spends ~1 s even on an element already there; the suite
# waits with appears()/disappears() (MarracatUITests/Waiting.swift, 2026-10-18).
# PerformanceTests keeps its own timing; the tours are videos, skipped in ships.
slow=$(grep -nE '\.wait(For|ForNon)Existence\(' MarracatUITests/*.swift \
  | grep -vE '^MarracatUITests/(Waiting|PerformanceTests|AppStoreTourUITests|TikTokTourUITests)\.swift:' || true)
[[ -z "$slow" ]] || { echo "use appears(timeout:)/disappears(timeout:) instead:" >&2; echo "$slow" >&2; exit 1; }
echo "UI test waits: ok"

echo "== node (web/tests)"
# Five web test files read the full catalog, which is build output and not in
# git. Say so instead of failing with an ENOENT stack.
if [[ ! -f Marracat/Resources/catalog.json ]]; then
  echo "error: Marracat/Resources/catalog.json is missing; the web tests need it." >&2
  echo "  fetch: curl -s --compressed https://marracat.com/catalog-v2.json -o Marracat/Resources/catalog.json" >&2
  exit 1
fi
[[ -d web/node_modules ]] || (cd web && npm ci --no-fund --silent)
# Node's default heap is sized to the machine: about 1.8 GB on the 4 GB
# refresh droplet, where tests/home.test.js ran out of memory on the
# 348 MB catalog and stopped every refresh from 2026-10-22 to 10-31. Room
# for 4 GB (the droplet has 4 GB of swap besides); a larger setting the
# caller already made wins.
[[ "${NODE_OPTIONS:-}" == *max-old-space-size* ]] || export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--max-old-space-size=4096"
# One retry, the same policy ship.sh uses for UI tests: a few web tests time
# themselves (search-suggestions "stay fast"), and when other sessions load
# the Mac they fail (load average 156 on 2026-10-01: one 'ma' lookup took
# 31 s). The retry runs only the failing files, one at a time, so it is not
# fighting four other files that each parse the 190 MB catalog. A test that
# is actually broken fails twice.
if ! out=$(cd web && npm test --silent 2>&1); then
  files=$(echo "$out" | grep -oE 'tests/[A-Za-z0-9_-]+\.test\.js' | sort -u | tr '\n' ' ')
  echo "$out" | grep -E '^✖' | sort -u | sed 's/^/  failed once, retrying: /'
  [[ -n "$files" ]] || files="tests/*.test.js"
  first=$(echo "$out" | grep -E '^ℹ (tests|pass|fail|skipped)' | tr '\n' ' ')
  # shellcheck disable=SC2086
  out=$(cd web && node --test --test-concurrency=1 $files 2>&1) || { echo "$out" | grep -vE '^✔' >&2; echo "web tests FAILED twice" >&2; exit 1; }
  echo "  retry passed: $files"
  # The whole suite's count, not just the retried files'.
  echo "  first run: $first"
  echo -n "  retry: "
fi
echo "$out" | grep -E '^ℹ (tests|pass|fail|skipped)' | tr '\n' ' '; echo
