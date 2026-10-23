#!/bin/bash
# Builds dist/Steppe.app (Apple silicon), ad-hoc signed.
#
#   Scripts/build-app.sh                 build with defaults
#   VERSION=1.2.0 BUILD=42 Scripts/build-app.sh
#
# Needs: Xcode command line tools, mingw-w64 (brew install mingw-w64) for the Windows helper DLLs.
# VORBIS_FAST_OFFLINE_DIR may point at a folder with the Xiph tarballs to build without network access.
#
# Signing: ad hoc only ("-"). Never sign public builds with a personal Apple Development certificate:
# its subject (your e-mail address) would be embedded in the app. For a Developer ID build set
# CODESIGN_IDENTITY and see Scripts/release.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
FEED_URL="${FEED_URL:-https://github.com/kuarezma/steppe/releases/latest/download/appcast.xml}"
IDENTITY="${CODESIGN_IDENTITY:--}"
ED_KEY="$(tr -d '[:space:]' < Config/sparkle_public_key.txt)"
APP="dist/Steppe.app"

echo "==> Native components"
make -C Native/glfix
make -C Native/vorbis-fast
make -C Native/dialog-helper

echo "==> Swift build (release, arm64)"
# -file-prefix-map keeps the build machine's directory names out of the binary; its module-cache warnings are noise.
BUILD_LOG="dist/tmp/swift-build.log"
mkdir -p dist/tmp
if ! swift build -c release --arch arm64 --product Steppe \
        -Xswiftc -file-prefix-map -Xswiftc "$PWD=/steppe" > "$BUILD_LOG" 2>&1; then
    grep -v -E "SDKExplicitPrecompiledModules|^note: while processing" "$BUILD_LOG" | tail -40
    echo "swift build failed"
    exit 1
fi
grep -v -E "SDKExplicitPrecompiledModules|^note: while processing" "$BUILD_LOG" | tail -3
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

echo "==> Icon"
mkdir -p dist/tmp
swiftc -O -o dist/tmp/make-icon Scripts/make-icon.swift
dist/tmp/make-icon dist/tmp/icon1024.png
ICONSET=dist/tmp/AppIcon.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s dist/tmp/icon1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) dist/tmp/icon1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o dist/tmp/AppIcon.icns

echo "==> Bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Native" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Steppe" "$APP/Contents/MacOS/Steppe"
strip -x "$APP/Contents/MacOS/Steppe"
cp dist/tmp/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
for lang in en tr; do
    mkdir -p "$APP/Contents/Resources/$lang.lproj"
    cp "Resources/$lang.lproj/Localizable.strings" "$APP/Contents/Resources/$lang.lproj/"
    [ -f "Resources/$lang.lproj/InfoPlist.strings" ] && cp "Resources/$lang.lproj/InfoPlist.strings" "$APP/Contents/Resources/$lang.lproj/"
done
cp Native/glfix/build/libglfix.dylib \
   Native/vorbis-fast/build/ogg.dll Native/vorbis-fast/build/vorbis.dll Native/vorbis-fast/build/vorbisfile.dll \
   Native/dialog-helper/build/dismiss-dialog.exe Native/dialog-helper/build/list-modes.exe \
   "$APP/Contents/Resources/Native/"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
sed -e "s|__VERSION__|$VERSION|g" -e "s|__BUILD__|$BUILD|g" -e "s|__FEED_URL__|$FEED_URL|g" -e "s|__ED_KEY__|$ED_KEY|g" \
    Resources/Info.plist.template > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

SPARKLE="$(find "$BIN_DIR" .build/artifacts -name Sparkle.framework -type d -path '*macos-arm64*' -o -name Sparkle.framework -type d -path "$BIN_DIR/*" 2>/dev/null | head -1)"
[ -n "$SPARKLE" ] || { echo "Sparkle.framework not found; run 'swift build' once"; exit 1; }
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Steppe" 2>/dev/null || true

echo "==> Signing (identity: $IDENTITY)"
ENTITLEMENTS="Config/Steppe.entitlements"
SIGN=(codesign --force --sign "$IDENTITY" --timestamp=none)
APP_SIGN=(codesign --force --sign "$IDENTITY" --timestamp=none --entitlements "$ENTITLEMENTS")
if [ "$IDENTITY" != "-" ]; then
    SIGN=(codesign --force --sign "$IDENTITY" --timestamp --options runtime)
    APP_SIGN=(codesign --force --sign "$IDENTITY" --timestamp --options runtime --entitlements "$ENTITLEMENTS")
fi
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for nested in "$FW/XPCServices/Installer.xpc" "$FW/XPCServices/Downloader.xpc" "$FW/Updater.app" "$FW/Autoupdate"; do
    [ -e "$nested" ] && "${SIGN[@]}" "$nested"
done
"${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
"${APP_SIGN[@]}" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Checks"
lipo -info "$APP/Contents/MacOS/Steppe"
if strings -a "$APP/Contents/MacOS/Steppe" | grep -q -E "/Users/[A-Za-z0-9_.-]+/"; then
    echo "WARNING: the executable still contains a home-directory path:"
    strings -a "$APP/Contents/MacOS/Steppe" | grep -E "/Users/[A-Za-z0-9_.-]+/" | head -3
    exit 1
fi
echo "Built $APP (version $VERSION, build $BUILD)"
