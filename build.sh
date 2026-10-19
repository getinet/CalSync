#!/usr/bin/env bash
# Builds CalSync.app.
#
# SwiftPM produces a bare executable, but macOS grants calendar access to a *bundle*
# with a stable identity — so the .app is assembled here rather than by Xcode.
#
#   ./build.sh             build to dist/CalSync.app
#   ./build.sh --install   also copy it into /Applications and launch it
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="CalSync"
BUNDLE_ID="net.beezwax.calsync"
VERSION="2.0.0"
APP="dist/${APP_NAME}.app"

echo "==> Building (release)"
swift build -c release --product CalSyncApp

echo "==> Assembling ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/CalSyncApp" "$APP/Contents/MacOS/${APP_NAME}"

# The icon is rendered from the same drawing code the menu bar uses, so the two can
# never drift apart and no image files need committing.
echo "==> Rendering icon"
ICONSET="dist/${APP_NAME}.iconset"
rm -rf "$ICONSET"
".build/release/CalSyncApp" --export-icon "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/${APP_NAME}.icns"
rm -rf "$ICONSET"

# NSCalendarsFullAccessUsageDescription is REQUIRED. Without it macOS silently denies
# the access request instead of prompting — no dialog, no error, just no access.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>                <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>         <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>          <string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key>          <string>${APP_NAME}</string>
  <key>CFBundleIconFile</key>            <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>         <string>APPL</string>
  <key>CFBundleShortVersionString</key>  <string>${VERSION}</string>
  <key>CFBundleVersion</key>             <string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key>      <string>14.0</string>
  <!-- Menu bar only: no Dock icon, no app switcher entry. -->
  <key>LSUIElement</key>                 <true/>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>CalSync reads your two calendars so it can block out matching busy time on each one.</string>
</dict>
</plist>
PLIST

# Editing Info.plist invalidates any existing signature, and TCC requires a valid one.
# Ad-hoc (-) is fine for personal use; sharing this app would need a Developer ID.
echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1

echo "==> Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="/Applications/${APP_NAME}.app"
  echo "==> Installing to ${DEST}"

  # Terminating the old copy is NOT optional. An LSUIElement app does not answer the
  # AppleScript quit, and `open` on an already-running app just activates it — so
  # without this you silently keep running the previous build over a new bundle.
  osascript -e "quit app \"${APP_NAME}\"" 2>/dev/null || true
  pkill -x "${APP_NAME}" 2>/dev/null || true
  for _ in $(seq 1 20); do
    pgrep -x "${APP_NAME}" >/dev/null 2>&1 || break
    perl -e 'select(undef,undef,undef,0.25)'
  done
  if pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
    echo "!! ${APP_NAME} would not quit; quit it from the menu bar and re-run." >&2
    exit 1
  fi

  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  open "$DEST"
  echo "==> Launched. Look for the calendar icon in your menu bar."
else
  echo
  echo "Next:  ./build.sh --install     (copies to /Applications and launches)"
  echo "   or:  open $APP"
fi
