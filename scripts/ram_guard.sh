#!/usr/bin/env bash
# Wait until this Mac has room for a heavy step (owner, 2026-11-01: "take
# note of our ram and dont go over 15gb"). It's a 16 GB machine; an 18 GB
# embedding run beside a build swapped it hard that day.
#
#   scripts/ram_guard.sh <the step's peak, GB> [label]
#   RAM_CAP_GB=15 (default)  RAM_GUARD_MAX_WAIT=1200 (seconds, then go on anyway)
#   scripts/ram_guard.sh --used    just print the GB in use (ship.sh samples it)
#
# "Used" is Activity Monitor's Memory Used: app memory (anonymous pages less
# purgeable) + wired + compressed. Waits while used + the step's peak would
# pass the cap; after RAM_GUARD_MAX_WAIT it says so and lets the step run,
# so a stuck process can't hold a ship forever.
set -euo pipefail
need=${1:-4}
label=${2:-step}
cap=${RAM_CAP_GB:-15}
max_wait=${RAM_GUARD_MAX_WAIT:-1200}

used_gb() {
    vm_stat | awk -v ps="$(sysctl -n hw.pagesize)" '
        /^Anonymous pages/        { gsub(/\./, "", $3); a = $3 }
        /^Pages purgeable/        { gsub(/\./, "", $3); p = $3 }
        /^Pages wired down/       { gsub(/\./, "", $4); w = $4 }
        /occupied by compressor/  { gsub(/\./, "", $5); c = $5 }
        END { printf "%.1f", (a - p + w + c) * ps / 1073741824 }'
}

if [[ "${1:-}" == --used ]]; then used_gb; echo; exit 0; fi

fits() { awk -v u="$1" -v n="$need" -v c="$cap" 'BEGIN { exit !(u + n <= c) }'; }

waited=0
while :; do
    used=$(used_gb)
    if fits "$used"; then
        echo "ram: ${used} GB used + ~${need} GB for ${label} fits under ${cap} GB"
        exit 0
    fi
    if (( waited >= max_wait )); then
        echo "ram: still ${used} GB used after ${waited}s; running ${label} anyway" >&2
        exit 0
    fi
    (( waited % 120 == 0 )) && echo "ram: ${used} GB used; waiting for room for ${label} (~${need} GB, cap ${cap} GB)"
    sleep 15
    waited=$((waited + 15))
done
