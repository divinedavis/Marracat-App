# Sourced by ship.sh: stage timestamps, memory waits and memory samples in one
# events file, summed up in one line when the ship ends, pass or fail
# (scripts/ship_summary.py; owner, 2026-11-09).
#
#   ship_log_start            start the events file and the memory sampler
#   stage "<name>"            prints the usual "==> HH:MM:SS name" and records it
#   guard <GB> "<label>"      scripts/ram_guard.sh, with the time it waited recorded
#   note key=value            build=180, tier=fast, catalog=droplet
#   ship_log_finish <rc>      stop the sampler, print and file the summary
#
# Memory is sampled every 5 s with the guard's own "used" sum, so each
# stage's real peak can replace the guard's guessed 4 and 6 GB reservations.
SHIP_EVENTS="${SHIP_EVENTS:-build/gates/ship-events.tsv}"
SHIP_HISTORY="${SHIP_HISTORY:-build/ship-history.jsonl}"
SHIP_SAMPLER_PID=""

ship_event() { printf '%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" >> "$SHIP_EVENTS" 2>/dev/null || true; }

ship_log_start() {
    mkdir -p "$(dirname "$SHIP_EVENTS")"
    : > "$SHIP_EVENTS"
    (
        while :; do
            used=$(./scripts/ram_guard.sh --used 2>/dev/null || echo 0)
            swap=$(sysctl -n vm.swapusage 2>/dev/null | sed -E 's/.*used = ([0-9.]+)M.*/\1/')
            printf '%s\tmem\t%s\t%s\n' "$(date +%s)" "$used" "${swap:-0}" >> "$SHIP_EVENTS"
            sleep 5
        done
    ) >/dev/null 2>&1 &
    SHIP_SAMPLER_PID=$!
}

stage() { echo "==> $(date +%T) $1"; ship_event stage "$1"; }
note() { ship_event note "$1"; }

guard() {
    local began; began=$(date +%s)
    ./scripts/ram_guard.sh "$1" "$2"
    ship_event ramwait "$(( $(date +%s) - began ))"
}

ship_log_finish() {
    [[ -n "$SHIP_SAMPLER_PID" ]] && kill "$SHIP_SAMPLER_PID" 2>/dev/null || true
    SHIP_SAMPLER_PID=""
    [[ -f "$SHIP_EVENTS" ]] || return 0
    python3 scripts/ship_summary.py "$SHIP_EVENTS" --result "${1:-0}" --history "$SHIP_HISTORY" || true
}
