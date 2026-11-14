#!/usr/bin/env bash
# Does marracat.com search exactly as the app does? (owner, 2026-10-31)
# Compiles the app's own search code (scripts/search_parity/build_harness.py)
# and runs it over the bundled catalog beside web/src/catalog.js: every query
# in queries.json and relax_queries.json must come back identical, in the
# same order. Needs Xcode's swiftc, so it isn't part of run_tests.sh; run it
# after changing search on either side. ~1 minute.
set -euo pipefail
cd "$(dirname "$0")/.."
here=scripts/search_parity
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 "$here/build_harness.py" "$work"
python3 - "$work" <<'PY'
import json, sys
c = json.load(open("Marracat/Resources/catalog.json"))
slim = {"products": [{"id": p["id"], "brand": p["brand"], "title": p["title"], "category": p.get("category") or "",
                      "product_type": p.get("product_type"), "tags": p.get("tags") or [], "available": bool(p.get("available"))}
                     for p in c["products"]],
        "brands": [{"id": b["id"], "name": b["name"]} for b in c["brands"]],
        "categories": [{"id": x["id"], "name": x["name"]} for x in c["categories"]]}
json.dump(slim, open(sys.argv[1] + "/catalog.json", "w"))
PY
(cd "$work" && xcrun swiftc -O -o search main.swift SearchWords.swift)
seed=$(node -e 'import("./web/src/catalog.js").then((m) => console.log(m.daySeed()))')
"$work/search" "$work/catalog.json" "$here/queries.json" "$here/relax_queries.json" "$seed" "$work/app.json"
node "$here/compare.mjs" "$PWD/web" "$work" "$PWD/$here"
