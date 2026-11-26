#!/usr/bin/env bash
# One TestFlight build a day (owner, 2026-10-21: "bundle the builds and ship
# once a day"). launchd com.marracat.daily-ship runs this at 03:00
# (scripts/install_daily_ship.sh); sessions commit and push their app changes
# during the day and no longer ship each one.
#
#   1. nothing to ship unless main has app changes since the last build bump
#      (on a Sunday with none, the full test suite still runs, shipping nothing);
#   2. waits for any other build or ship on this Mac (one at a time), and
#      for another session's uncommitted app files to be committed, until 09:00;
#   3. runs scripts/ship.sh (full UI suite, perf gate, catalog, upload);
#   4. commits and pushes the bump with the day's changes in its body.
# Failures notify and land in build/daily-ship.log; the day's changes wait for
# the next night or a manual ship.
#
#   scripts/daily_ship.sh [--dry-run]     (DAILY_SHIP_NOW=1: run after 09:00 too;
#                                          DAILY_SHIP_CHECK=1: full suite with no ship on any quiet day)
set -euo pipefail
# A build runs 40+ minutes; on battery this Mac idle-sleeps after 1 minute
# (pmset sleep 1), so hold the Mac awake for the whole run. Closing the lid
# still sleeps it.
# The 2:58 AM scheduled wake is only a "dark wake" when the Mac is on battery:
# on 2026-11-03 it dozed and dark-woke 26 times under this job and a 10-minute
# test pass ended at 08:38 (pmset -g log). Declaring user activity turns a
# dark wake into a full one (lid open); the assertion below then holds it.
if [[ -z "${DAILY_SHIP_AWAKE:-}" ]]; then
    /usr/bin/caffeinate -u -t 30 &
    exec env DAILY_SHIP_AWAKE=1 /usr/bin/caffeinate -i "$0" "$@"
fi
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# What goes into the shipped binary: the app's sources and tests, and (since
# 2026-11-09) the three things outside them that shape the IPA: the export
# options, the catalog.bin writer and the script that builds the bundled
# catalog. The ship scripts themselves change no binary, so they never cause a
# build on their own; a change to them is named in the log below and is
# exercised by the next ship or by Sunday's full suite, whichever is first.
APP_PATHS=(Marracat MarracatTests MarracatUITests MarracatWidgets AlertCards MarracatNotificationService MarracatNotificationContent project.yml
           scripts/ExportOptions.plist scripts/catalog_binary catalog/make_compact.py)
PIPELINE_PATHS=(scripts/ship.sh scripts/daily_ship.sh scripts/smoke_test.sh scripts/ship_log.sh
                scripts/ship_summary.py scripts/catalog_freshness.py scripts/pull_catalog.sh
                scripts/publish_catalog.sh scripts/perf_gate.py scripts/perf_ceilings.json
                scripts/flaky_tests.py scripts/coverage_gate.py scripts/ram_guard.sh
                scripts/build_lock.sh scripts/wait_sim_quiet.sh scripts/next_version.py)
DRY=0; [[ "${1:-}" == "--dry-run" ]] && DRY=1
mkdir -p build

say() { echo "$(date '+%F %T') $1"; }
notify() {
    say "$1"
    osascript -e "display notification \"$1 (build/daily-ship.log)\" with title \"Marracat daily build\"" 2>/dev/null || true
}
# Any other project's or session's build, judged by what each process IS
# (its executable), not by text in its command line: a session's shell whose
# command merely mentions "xcodebuild build" while it waits its turn read as a
# build and kept the 2026-10-24 manual ship waiting until the 09:00 cutoff.
# (grep -q under pipefail broke the older check the other way, 2026-10-23.)
busy() {
    ps -axo comm=,args= | awk '$1 ~ /(^|\/)xcodebuild$/ || ($1 ~ /(^|\/)altool$/ && / --upload/) ||
        ($1 ~ /(^|\/)(ba)?sh$/ && / [^ ]*scripts\/ship\.sh( |$)/) {f=1} END {exit !f}'
}
dirty() { [[ -n "$(git status --porcelain -- "${APP_PATHS[@]}")" ]]; }
past_cutoff() { (( 10#$(date +%H) >= 9 )); }
# The shared build lock (scripts/build_lock.sh, same file and path as Find A
# Crib's, 2026-10-24) as well as busy(): the lock serialises the two apps'
# builds exactly; busy() still catches anything that doesn't take it.
# shellcheck disable=SC1091
source scripts/build_lock.sh

say "=== daily build"
if [[ "$(pmset -g batt 2>/dev/null)" == *"'Battery Power'"* ]]; then
    notify "the Mac is on battery: tonight's build may stall or sleep. Leave it plugged in with the lid open"
fi
# Asleep at 03:00, launchd runs this on waking: after 09:00 that's the
# owner's working day, so the build waits for tonight instead.
if past_cutoff && [[ "${DAILY_SHIP_NOW:-0}" != "1" ]]; then
    notify "the Mac was asleep at 03:00; today's changes ship tonight"; exit 0
fi
[[ "$(git branch --show-current)" == "main" ]] || { notify "the checkout isn't on main; skipped"; exit 1; }
git pull --ff-only --quiet || { notify "could not fast-forward main; skipped"; exit 1; }

# The cleaned public copy (divinedavis/Marracat-App) follows main every night,
# build or no build. Never fatal and capped at 15 minutes: a sync that stops
# publishes nothing and says why in build/public-mirror.log.
if (( ! DRY )); then
    perl -e 'alarm shift; exec @ARGV' 900 scripts/public_mirror/publish.sh >> build/public-mirror.log 2>&1 \
        || notify "public copy not synced; see build/public-mirror.log"
fi

# What main holds that no build has: the app commits since the last build bump.
unbuilt_changes() {
    last=$(git log -1 --format=%H -G'CURRENT_PROJECT_VERSION: "' -- project.yml)
    changes=$(git log --format='- %s' --no-merges "$last"..HEAD -- "${APP_PATHS[@]}" | grep -v '^- Bump to' || true)
}
unbuilt_changes
pipeline=$(git log --format='- %s' --no-merges "$last"..HEAD -- "${PIPELINE_PATHS[@]}" | grep -v '^- Bump to' || true)
[[ -z "$pipeline" ]] || { say "ship-script changes since the last build (this run exercises them):"; echo "$pipeline"; }
# The weekly full suite belongs to Sunday, not to "a Sunday that happens to
# have a ship": with no app changes the old script exited before it picked a
# tier, so a quiet Sunday skipped the week's only full run (found 2026-11-09).
# The catalog the tests read changes daily, and so can Xcode and the scripts.
check_only=0
if [[ -z "$changes" ]]; then
    if [[ "${DAILY_SHIP_CHECK:-$([[ $(date +%u) == 7 ]] && echo 1 || echo 0)}" == 1 ]]; then
        check_only=1
        say "no app changes since $(git log -1 --format=%h "$last"); Sunday: running the full suite, shipping nothing"
    else
        say "no app changes since $(git log -1 --format=%h "$last"); nothing to ship"; exit 0
    fi
else
    say "app changes since the last build:"; echo "$changes"
fi
(( DRY )) && { (( check_only )) && say "dry run: would run the full suite only" || say "dry run: would ship"; exit 0; }

until ! busy && ! dirty && build_lock_try "Marracat daily_ship.sh"; do
    if past_cutoff && [[ "${DAILY_SHIP_NOW:-0}" != "1" ]]; then
        dirty && why="uncommitted app files: $(git status --porcelain -- "${APP_PATHS[@]}" | head -3 | tr '\n' ' ')" || why="another build kept the Mac busy ($(build_lock_holder))"
        notify "no build today: $why"; exit 1
    fi
    sleep 300
done

# The wait can be for another ship of this very app. 2026-11-26: a by-hand
# ship made build 201 while this run waited for the lock; the list above was
# from before it, so this run tested the same code again and was a failed
# speed test away from uploading it a second time as 202. Look again now
# that the Mac is ours.
git pull --ff-only --quiet || { notify "could not fast-forward main after the wait; skipped"; exit 1; }
unbuilt_changes
if [[ -z "$changes" ]] && (( ! check_only )); then
    say "another ship built these changes while this one waited (build bump $(git log -1 --format=%h "$last")); nothing to ship"; exit 0
fi

# What a run learnt about flaky tests is kept whether it shipped or not.
keep_flaky_history() {
    git add scripts/flaky_history.json MarracatUITests/quarantine.txt
    git diff --cached --quiet || { git commit --quiet -m "$1" -m "Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>" && git push --quiet; } || true
}
if (( check_only )); then
    rc=0
    SHIP_TESTS_ONLY=1 SHIP_TIER=full SIM_UDID="${SIM_UDID:-5A719729-4195-4CA3-85C4-BD578509470D}" ./scripts/ship.sh || rc=$?
    # next_version.py may have moved the version for a ship that isn't happening.
    git checkout -- project.yml scripts/perf_baseline.json
    keep_flaky_history "Flaky-test history from the Sunday full suite"
    if (( rc )); then notify "Sunday's full suite FAILED with nothing to ship; see build/daily-ship.log"; exit 1; fi
    notify "Sunday's full suite passed; nothing to ship"; exit 0
fi

# A failed ship leaves its unused build-number bump behind; drop it, or
# tomorrow's run would wait on "uncommitted app files" (project.yml) all night.
# The fast test set nightly, the full suite on Sundays (owner, 2026-10-25:
# "fast set nightly"; scripts/flaky_tests.py). DAILY_SHIP_TIER overrides.
tier="${DAILY_SHIP_TIER:-$([[ $(date +%u) == 7 ]] && echo full || echo fast)}"
say "test tier: $tier"
SHIP_TIER="$tier" SIM_UDID="${SIM_UDID:-5A719729-4195-4CA3-85C4-BD578509470D}" ./scripts/ship.sh \
    || { git checkout -- project.yml scripts/perf_baseline.json
         # Keep what this run learnt about flaky tests even though it failed.
         keep_flaky_history "Flaky-test history from a failed ship"
         notify "ship failed; see build/daily-ship.log"; exit 1; }

build=$(grep -m1 'CURRENT_PROJECT_VERSION:' project.yml | sed -E 's/.*"([0-9]+)".*/\1/')
version=$(grep -m1 'MARKETING_VERSION:' project.yml | sed -E 's/.*"([0-9.]+)".*/\1/')
git add project.yml scripts/perf_baseline.json scripts/flaky_history.json MarracatUITests/quarantine.txt
git commit --quiet -F - <<EOF
Bump to $version ($build): daily build

The day's app changes, on TestFlight in one build:
$changes

Shipped by scripts/daily_ship.sh after the $tier test tier, the perf gate
and the category audit passed.

Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>
EOF
git push --quiet || notify "build $build shipped but the bump didn't push"
notify "build $build ($version) is on its way to TestFlight"
