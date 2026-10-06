#!/bin/bash
# Build GoTo.app into ./build. Pass --install to copy it to /Applications and (re)launch it.
#
# Two binaries are produced:
#   build/GoTo.app         the app; no developer entry points, signed with the hardened runtime
#   build/goto-tools       developer tools (icon rendering, search benchmark, panel snapshots); never installed
set -euo pipefail
cd "$(dirname "$0")"

APP=build/GoTo.app
TOOLS=build/goto-tools
ARCH=$(uname -m)
SWIFTC=(swiftc -O -whole-module-optimization -target "$ARCH-apple-macos13.0" -sdk "$(xcrun --show-sdk-path)"
        -module-name GoTo -import-objc-header Sources/Bridging.h)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "› Compiling app ($ARCH)…"
"${SWIFTC[@]}" Sources/*.swift -o "$APP/Contents/MacOS/GoTo"

echo "› Compiling developer tools…"
"${SWIFTC[@]}" -D GOTO_DEVTOOLS Sources/*.swift -o "$TOOLS"
codesign --force --sign - --options runtime "$TOOLS"

cp Info.plist "$APP/Contents/Info.plist"

echo "› Rendering icon…"
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
"$TOOLS" --make-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Hardened runtime: no DYLD_* injection, no unsigned libraries, no debugger attach — so other
# processes can't borrow Go To's folder access or its permission to control Finder.
codesign --force --sign - --options runtime --entitlements GoTo.entitlements \
  --identifier local.goto.GoTo "$APP"
codesign --verify --strict "$APP"
echo "✓ Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x GoTo 2>/dev/null && sleep 0.5 || true
  rm -rf /Applications/GoTo.app
  cp -R "$APP" /Applications/
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/GoTo.app
  open /Applications/GoTo.app
  echo "✓ Installed to /Applications/GoTo.app and launched"
fi
