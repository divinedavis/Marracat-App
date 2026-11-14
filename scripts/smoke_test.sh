#!/usr/bin/env bash
# Build, install, cold-launch on a simulator, and confirm the app is still
# alive 8 seconds later. A green XCUITest run does not prove a cold launch.
#
#   SIM_UDID=<udid> ./scripts/smoke_test.sh
#   SMOKE_ACTION=build-for-testing ...   also build the test bundles, so the
#                                        ship's test passes can start from these
#                                        products (test-without-building)
set -euo pipefail
cd "$(dirname "$0")/.."

UDID="${SIM_UDID:-$(xcrun simctl list devices available | awk -F'[()]' '/iPhone 17 Pro \(/ {print $2; exit}')}"
BUNDLE=com.divinedavis.marracat

# Other sessions share these simulators — never drive one mid-run.
if ps -axo comm=,args= | awk -v u="$UDID" '$1 ~ /xcodebuild$/ && index($0,u)' | grep -q .; then
    echo "error: another xcodebuild is using $UDID — pass a free SIM_UDID" >&2
    exit 1
fi

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null

xcodebuild -project Marracat.xcodeproj -scheme Marracat \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build/smoke -quiet "${SMOKE_ACTION:-build}"
APP=build/smoke/Build/Products/Debug-iphonesimulator/Marracat.app
# The app bundles the compact catalog as catalog.bin plus Home's slice of it
# (catalog/make_compact.py) — every product a brand sells, minus the
# description and spare images a product page fetches. Since 2026-10-18 the
# 105 MB JSON they're built from stays out of the bundle: install size for a
# fallback the binary already covers.
for f in catalog.bin catalog-home.bin; do
    if [[ ! -f "$APP/$f" ]]; then
        echo "error: $f is missing from the app bundle — run: python3 catalog/make_compact.py" >&2
        exit 1
    fi
done
if [[ -f "$APP/catalog-compact.json" || -f "$APP/catalog.json" ]]; then
    echo "error: a JSON catalog is back in the app bundle (project.yml resources)" >&2
    exit 1
fi
SRC=Marracat/Resources/catalog-compact.json
if [[ "$SRC" -nt Marracat/Resources/catalog.bin ]]; then
    echo "error: catalog.bin is older than $SRC — run: python3 catalog/make_compact.py" >&2
    exit 1
fi
products=$(python3 -c "import json;print(len(json.load(open('$SRC'))['products']))")
if (( products < 50000 )); then
    echo "error: the bundled catalog carries only $products products" >&2
    exit 1
fi
echo "bundle: $products products"

xcrun simctl install "$UDID" "$APP"
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
sleep 8
# Capture first: `launchctl list | grep -q` SIGPIPEs launchctl when grep exits
# early, and pipefail turns that into a false "died after launch".
running=$(xcrun simctl spawn "$UDID" launchctl list)
if [[ "$running" != *"UIKitApplication:$BUNDLE"* ]]; then
    echo "error: Marracat died after launch. Newest crash report:" >&2
    ls -t ~/Library/Logs/DiagnosticReports/Marracat* 2>/dev/null | head -1 >&2
    exit 1
fi
echo "smoke: Marracat launched and is alive on $UDID"
