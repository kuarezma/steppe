#!/bin/bash
# Packages dist/Steppe.app into dist/Steppe-<version>.dmg and dist/Steppe-<version>.zip (the zip is what Sparkle serves).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
APP="dist/Steppe.app"
[ -d "$APP" ] || { echo "Run Scripts/build-app.sh first"; exit 1; }

STAGE="dist/tmp/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Steppe.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read Me First.txt" <<'TXT'
1. Drag Steppe to Applications.
2. Open it. If macOS says it "cannot be opened because the developer cannot be verified":
   System Settings > Privacy & Security > scroll down > "Open Anyway".
   (Steppe is open source and not notarized by Apple. See the project page for details.)
TXT
rm -f "dist/Steppe-$VERSION.dmg"
hdiutil create -volname "Steppe $VERSION" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "dist/Steppe-$VERSION.dmg" >/dev/null
rm -f "dist/Steppe-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/Steppe-$VERSION.zip"
shasum -a 256 "dist/Steppe-$VERSION.dmg" "dist/Steppe-$VERSION.zip"
