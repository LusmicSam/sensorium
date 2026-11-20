#!/bin/bash
# Build Sensorium + its background helper, wrap them in one .app (helper inside
# Contents/Library/LoginItems), sign ad-hoc, install to ~/Applications and (re)launch.
# If the background service is installed, it is restarted on the new build.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --product Sensorium
swift build -c release --product SensoriumHelper
APP=build/Sensorium.app
HELPER="$APP/Contents/Library/LoginItems/SensoriumHelper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$HELPER/Contents/MacOS"
cp .build/release/Sensorium "$APP/Contents/MacOS/Sensorium"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/SensoriumHelper "$HELPER/Contents/MacOS/SensoriumHelper"
cp Resources/Helper-Info.plist "$HELPER/Contents/Info.plist"
codesign --force --sign - "$HELPER" >/dev/null 2>&1
codesign --force --sign - "$APP" >/dev/null 2>&1
pkill -x Sensorium 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Sensorium.app"
ditto "$APP" "$HOME/Applications/Sensorium.app"
LABEL=local.personal.sensorium.helper
if [ -f "$HOME/Library/LaunchAgents/$LABEL.plist" ]; then
  launchctl kickstart -k "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  echo "Background service restarted on the new build."
fi
open "$HOME/Applications/Sensorium.app"
echo "Sensorium installed to ~/Applications and launched."
