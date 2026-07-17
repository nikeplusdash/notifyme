#!/bin/bash
#
# Assemble the teleport harness into an ad-hoc-signed .app bundle.
#
# This exists for one reason: UNUserNotificationCenter refuses to work outside a properly formed,
# code-signed bundle, so a bare `swiftc -o /tmp/cttp` can never test the notification path — it can
# only ever exercise the osascript fallback. This reproduces the exact conditions `make build` gives
# the real app (same Info.plist shape, same `codesign -s -` ad-hoc signature, same LSUIElement
# accessory policy) so the notification path can be verified for real.
#
#   ./Tools/teleport/bundle.sh && /tmp/CTHarness.app/Contents/MacOS/cttp notify <pid> done
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-/tmp/CTHarness.app}"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"

swiftc -target arm64-apple-macos13.0 \
    -o "$OUT/Contents/MacOS/cttp" \
    "$ROOT"/Sources/NotifyMe/Model/*.swift \
    "$ROOT"/Sources/NotifyMe/Teleport/*.swift \
    "$ROOT"/Sources/NotifyMe/Notify/*.swift \
    "$ROOT"/Tools/teleport/main.swift \
    -framework AppKit \
    -framework UserNotifications

# Its own bundle identifier, deliberately not the app's: two binaries claiming to be
# com.madebynikesh.NotifyMe would leave LaunchServices pointing at whichever it saw last.
cat >"$OUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>NotifyMe Harness</string>
    <key>CFBundleDisplayName</key>
    <string>NotifyMe Harness</string>
    <key>CFBundleExecutable</key>
    <string>cttp</string>
    <key>CFBundleIdentifier</key>
    <string>com.madebynikesh.NotifyMe.TeleportHarness</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$OUT"
codesign --verify --verbose "$OUT" 2>&1 | sed 's/^/  /'

echo "built $OUT"
echo "run: $OUT/Contents/MacOS/cttp notify <pid> done"
