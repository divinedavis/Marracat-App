#!/usr/bin/env bash
# Waits until a simulator's own background work has settled, so the
# performance gate measures the app and not the simulator.
#
# A freshly erased or first-booted simulator runs mediaanalysisd at ~180% CPU
# (plus diagnosticd, chronod, STExtractionService) for several minutes, and it
# defers that work while the device is busy, so it can start right when the UI
# tests stop. On 2026-10-18 that alone made launch 2.7-4.9 s against a 1.47 s
# baseline on every code version tried; the same build measured 1.455 s once
# the simulator had idled. dev-cleanup erases the ship simulator between runs,
# so this happens after most erases.
#
#   SIM_UDID=<udid> ./scripts/wait_sim_quiet.sh [max_seconds]
set -euo pipefail
: "${SIM_UDID:?SIM_UDID is required}"
MAX="${1:-900}"
QUIET_PCT=25     # all of the simulator's processes together
QUIET_FOR=30     # seconds in a row under that

xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
start=$(date +%s); calm=0
while :; do
    # Simulator processes run from the runtime's RuntimeRoot; ps prints that path.
    pct=$(ps -axo %cpu=,command= | awk '/RuntimeRoot/ && !/awk/ {s += $1} END {printf "%d", s}')
    if (( pct < QUIET_PCT )); then calm=$((calm + 5)); else calm=0; fi
    (( calm >= QUIET_FOR )) && { echo "simulator quiet (${pct}% CPU) after $(( $(date +%s) - start )) s"; exit 0; }
    if (( $(date +%s) - start >= MAX )); then
        echo "warning: simulator still busy (${pct}% CPU) after ${MAX} s; measuring anyway" >&2
        exit 0
    fi
    sleep 5
done
