#!/usr/bin/env bash
# The tests a change touches, on one simulator, for iterating between daily
# builds (owner, 2026-10-21). The full suite runs on every ship.
#
#   SIM_UDID=<free simulator> scripts/test_affected.sh [--base <ref>]
#   (default base origin/main: this branch's commits plus uncommitted edits)
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source scripts/build_lock.sh
build_lock_take "Marracat test_affected.sh"
SIM_UDID="${SIM_UDID:-5A719729-4195-4CA3-85C4-BD578509470D}"
# An empty selection must never read as a green run (2026-11-09): with no
# -only-testing arguments xcodebuild would run something else entirely, and a
# crash in affected_tests.py inside $(…) doesn't stop this script by itself.
picked=$(python3 scripts/affected_tests.py "$@") || { echo "error: scripts/affected_tests.py failed; no tests were selected" >&2; exit 1; }
read -r -a only <<<"$picked"
[[ ${#only[@]} -gt 0 && "${only[0]}" == -only-testing:* ]] \
    || { echo "error: no tests selected for this change; refusing to report a pass" >&2; exit 1; }
python3 scripts/affected_tests.py "$@" --list | sed 's/^/  /'
xcodegen generate --quiet
mkdir -p build/gates
rm -rf build/gates/Affected.xcresult
./scripts/ram_guard.sh 6 "the affected tests"
xcodebuild -project Marracat.xcodeproj -scheme Marracat \
    -destination "platform=iOS Simulator,id=$SIM_UDID" -derivedDataPath build/smoke -quiet \
    -retry-tests-on-failure -test-iterations 2 -resultBundlePath build/gates/Affected.xcresult \
    "${only[@]}" test
# ...and the run must have executed tests: xcodebuild exits 0 when a selection
# matches nothing (a renamed or deleted test).
ran=$(xcrun xcresulttool get test-results summary --path build/gates/Affected.xcresult \
    | python3 -c 'import json, sys; print(json.load(sys.stdin).get("totalTestCount", 0))')
[[ "$ran" -gt 0 ]] || { echo "error: the selection matched no tests; nothing ran" >&2; exit 1; }
echo "affected tests: $ran ran"
