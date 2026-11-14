#!/usr/bin/env bash
# Weekly "learn from failed searches" (catalog/search_gaps.py). Run by
# launchd every Monday at 8:00 (scripts/com.marracat.search-gaps.plist).
# Writes build/search-gaps/<date>.md and an email draft; confirmed synonyms
# change web/src/search-synonyms.json, which goes live with the next
# web/deploy.sh (commit it first). Sends the email only with SEND=1.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
mkdir -p build/search-gaps
key="$HOME/.config/typesafe/api_key"
[[ -f "$key" ]] && export TYPESAFE_API_KEY="$(cat "$key")"
args=(--remote --email)
[[ "${SEND:-0}" == 1 ]] && args+=(--send)
echo "=== $(date '+%F %T') search gaps"
python3 catalog/search_gaps.py "${args[@]}"
