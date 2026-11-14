#!/usr/bin/env bash
# Installs launchd com.marracat.daily-ship: scripts/daily_ship.sh at 03:00,
# after the 01:30 nightly photo + AI steps. A Mac asleep at 03:00 runs it on
# waking. Re-run after moving the checkout.
set -euo pipefail
cd "$(dirname "$0")/.."
here=$(pwd -P)
label=com.marracat.daily-ship
plist="$HOME/Library/LaunchAgents/$label.plist"
cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string><string>-c</string>
    <string>$here/scripts/daily_ship.sh &gt;&gt; $here/build/daily-ship.log 2&gt;&amp;1</string>
  </array>
  <key>WorkingDirectory</key><string>$here</string>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>0</integer></dict>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "installed $label: daily at 03:00 -> build/daily-ship.log"
