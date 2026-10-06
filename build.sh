#!/bin/bash
# Build GoTo.app into ./build.
#   ./build.sh             build for this Mac
#   ./build.sh --install   build, copy to /Applications and (re)launch
#   ./build.sh --release   universal (Apple silicon + Intel) build, zipped for distribution
#
# Two binaries are produced:
#   build/GoTo.app         the app; no developer entry points, signed with the hardened runtime
#   build/goto-tools       developer tools (icon rendering, search benchmark, panel snapshots); never installed
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"
APP=build/GoTo.app
TOOLS=build/goto-tools
NATIVE=$(uname -m)
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
ARCHS=("$NATIVE")
[[ "$MODE" == "--release" ]] && ARCHS=(arm64 x86_64)

# -file-prefix-map keeps this machine's paths (home folder, user name) out of the binaries.
swift_build() { # arch, output, extra flags...
  local arch=$1 out=$2; shift 2
  swiftc -O -whole-module-optimization -target "$arch-apple-macos12.0" -sdk "$(xcrun --show-sdk-path)" \
    -module-name GoTo -import-objc-header Sources/Bridging.h -file-prefix-map "$PWD=." \
    "$@" Sources/*.swift -o "$out"
}

rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

SLICES=()
for arch in "${ARCHS[@]}"; do
  echo "› Compiling app ($arch)…"
  swift_build "$arch" "build/obj/GoTo-$arch"
  SLICES+=("build/obj/GoTo-$arch")
done
lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/GoTo"

# Release builds make the tools universal too, so the Intel slice can be tested under Rosetta.
TOOL_SLICES=()
for arch in "${ARCHS[@]}"; do
  echo "› Compiling developer tools ($arch)…"
  swift_build "$arch" "build/obj/goto-tools-$arch" -D GOTO_DEVTOOLS
  TOOL_SLICES+=("build/obj/goto-tools-$arch")
done
lipo -create "${TOOL_SLICES[@]}" -output "$TOOLS"
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
echo "✓ Built $APP ($(lipo -archs "$APP/Contents/MacOS/GoTo"))"

case "$MODE" in
  --install)
    pkill -x GoTo 2>/dev/null && sleep 0.5 || true
    rm -rf /Applications/GoTo.app
    cp -R "$APP" /Applications/
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/GoTo.app
    open /Applications/GoTo.app
    echo "✓ Installed to /Applications/GoTo.app and launched"
    ;;
  --release)
    ZIP="build/GoTo-$VERSION.zip"
    rm -f "$ZIP"
    # No extended attributes or quarantine flags from this machine in the archive.
    ditto -c -k --keepParent --noextattr --noqtn --norsrc "$APP" "$ZIP"
    echo "✓ Release archive: $ZIP"
    shasum -a 256 "$ZIP"
    ;;
esac
