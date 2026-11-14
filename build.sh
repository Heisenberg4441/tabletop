#!/bin/bash
#
# build.sh — builds Tabletop.app with nothing but the Command Line Tools.
#
# There is no Xcode here and no xcodebuild, so the bundle is assembled by hand:
# SwiftPM produces the executable, this script wraps it in the directory
# structure and Info.plist that macOS needs in order to treat it as a real app
# with a Dock icon and a menu bar.
#
# Usage:  ./build.sh [--install] [--debug]
#           --install   also copy the finished app into /Applications
#           --debug     build without optimisation, for faster iteration

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Tabletop"
BUNDLE_ID="com.tabletop.games"
VERSION="1.0"
BUILD="1"
CONFIG="release"
INSTALL=0

for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --debug)   CONFIG="debug" ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

APP="build/${APP_NAME}.app"
CONTENTS="${APP}/Contents"
BINARY=".build/${CONFIG}/${APP_NAME}"

echo "==> Compiling (${CONFIG})"
# The previous build's executable goes first, so a compile that fails can
# never leave a stale binary behind for the checks below to test and package.
rm -f "$BINARY"
BUILD_LOG="$(mktemp)"
trap 'rm -f "$BUILD_LOG"' EXIT
set +e
if [ "$CONFIG" = "release" ]; then
  # Whole-module optimisation is on by default in release; dead-stripping the
  # link keeps the binary small without touching the source.
  swift build -c release -Xlinker -dead_strip >"$BUILD_LOG" 2>&1
else
  swift build >"$BUILD_LOG" 2>&1
fi
BUILD_STATUS=$?
set -e
# The compiler's own progress lines are noise; errors and warnings are not.
grep -vE "search path|^\[" "$BUILD_LOG" || true
if [ "$BUILD_STATUS" -ne 0 ]; then
  echo "build FAILED (swift build exited ${BUILD_STATUS})" >&2
  exit "$BUILD_STATUS"
fi
[ -x "$BINARY" ] || { echo "build produced no executable" >&2; exit 1; }

# Every harness mode runs against a throwaway storage directory, so none of
# these can touch the player's saved games. Each one exits non-zero on a
# failure, and `set -e` with pipefail turns that into a failed build.
echo "==> Running self-tests (kit and every game)"
"$BINARY" --selftest | tail -3
echo "==> Playing solitaire games through the real board"
"$BINARY" --playtest 40
echo "==> Checking every button and menu item is wired to something"
"$BINARY" --controls | tail -2
echo "==> Rendering the library and the kit gallery off-screen"
SHOT_DIR="$(mktemp -d)"
"$BINARY" --shot library "${SHOT_DIR}/library.png" >/dev/null
"$BINARY" --shot kit "${SHOT_DIR}/kit.png" >/dev/null
rm -rf "$SHOT_DIR"

echo "==> Assembling ${APP}"
rm -rf "$APP"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"
cp "$BINARY" "${CONTENTS}/MacOS/${APP_NAME}"

echo "==> Drawing the icon"
ICONSET="build/${APP_NAME}.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
"$BINARY" --icon "build/icon-1024.png"
# iconutil insists on exactly these names and sizes.
for spec in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
            "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" \
            "512:icon_256x256@2x" "512:icon_512x512" "1024:icon_512x512@2x"; do
  size="${spec%%:*}"; name="${spec##*:}"
  sips -z "$size" "$size" "build/icon-1024.png" --out "${ICONSET}/${name}.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "${CONTENTS}/Resources/AppIcon.icns"

echo "==> Copying translations"
# The Russian tables are generated from Tools/l10n/*.json, and regenerating
# them here also checks that every string in the source has a translation — a
# missing one would otherwise show up as a stray English word in the app.
python3 Tools/l10n/build-strings.py
cp -R Resources/*.lproj "${CONTENTS}/Resources/"
rm -rf "$ICONSET"

cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
	<key>CFBundleExecutable</key><string>${APP_NAME}</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key><string>${APP_NAME}</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>${VERSION}</string>
	<key>CFBundleVersion</key><string>${BUILD}</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.board-games</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSHumanReadableCopyright</key><string>Tabletop — classic table games.</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "${CONTENTS}/PkgInfo"
plutil -lint "${CONTENTS}/Info.plist" >/dev/null

echo "==> Signing (ad-hoc)"
# An ad-hoc signature is enough to run locally and keeps macOS from nagging on
# every launch; it is not a Developer ID and cannot be notarised.
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null

SIZE=$(du -sh "$APP" | cut -f1)
echo "==> Built ${APP} (${SIZE})"

if [ "$INSTALL" = "1" ]; then
  echo "==> Installing to /Applications"
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "$APP" "/Applications/${APP_NAME}.app"
  echo "    open -a ${APP_NAME}"
fi
