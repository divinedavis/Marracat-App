#!/usr/bin/env bash
# Install (or refresh) the daily holiday App Store job: mc_holidays_auto.py
# --apply every day at 06:10 on this Mac (launchd runs a missed one at the
# next wake). The scripts and holidays.json are copied out of the repo, in
# the repo's layout, so a checkout mid-edit never runs; re-run this after
# changing any of them. Log: ~/Library/Logs/marracat-holidays.log
# PATH includes /opt/homebrew/bin: launchd's default PATH has no ffmpeg,
# which the animated holiday header videos need.
set -euo pipefail
cd "$(dirname "$0")/../.."
DEST="$HOME/Library/Application Support/marracat-holidays"
PLIST="$HOME/Library/LaunchAgents/com.divinedavis.marracat-holidays.plist"
PY="${PY:-$HOME/.venvs/dhcr-map/bin/python}"
ASC="${ASC:-$HOME/projects/dhcr-map/ios/scripts}"
mkdir -p "$DEST/scripts/asc_growth" "$DEST/Marracat/Resources" "$DEST/Marracat/Assets.xcassets/AppIcon.appiconset" "$DEST/asc"
cp scripts/asc_growth/mc_holidays_auto.py scripts/asc_growth/mc_growth.py scripts/asc_growth/asc_app_events.py "$DEST/scripts/asc_growth/"
cp scripts/holiday_app_store_events.py scripts/holiday_theme_examples.py scripts/make_creative_assets.py "$DEST/scripts/"
cp Marracat/Resources/holidays.json "$DEST/Marracat/Resources/"
cp Marracat/Assets.xcassets/AppIcon.appiconset/icon-1024.png "$DEST/Marracat/Assets.xcassets/AppIcon.appiconset/"
cp "$ASC/asc_creative_assets.py" "$DEST/asc/"
cp "$ASC/asc-config.env" "$DEST/asc/" && chmod 600 "$DEST/asc/asc-config.env"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.divinedavis.marracat-holidays</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PY</string>
    <string>$DEST/scripts/asc_growth/mc_holidays_auto.py</string>
    <string>--apply</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict><key>PYTHONPATH</key><string>$DEST/scripts/asc_growth:$DEST/asc</string><key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>WorkingDirectory</key><string>$DEST</string>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>6</integer><key>Minute</key><integer>10</integer></dict>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/marracat-holidays.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/marracat-holidays.log</string>
</dict>
</plist>
PL
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed: $PLIST (daily 06:10); log ~/Library/Logs/marracat-holidays.log"
