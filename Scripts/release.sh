#!/bin/bash
# Builds a release and prepares everything Sparkle and GitHub need in dist/release/.
#
#   VERSION=0.2.0 Scripts/release.sh
#
# Output (dist/release/):  Steppe-<version>.dmg   download for new users
#                          Steppe-<version>.zip   what Sparkle serves to existing users
#                          appcast.xml            update feed (EdDSA-signed entries)
#                          SHA256SUMS.txt
#
# Signing keys:
#  - Update signatures use the Sparkle EdDSA key in your login keychain (created with Sparkle's generate_keys),
#    or SPARKLE_PRIVATE_KEY_FILE pointing at an exported key (used by CI).
#  - The app itself is signed ad hoc by default. If you own an Apple Developer ID certificate, set
#    CODESIGN_IDENTITY="Developer ID Application: …" and NOTARY_PROFILE=<notarytool keychain profile> to also
#    notarize and staple. That path is optional and untested by the maintainers.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${VERSION:?set VERSION, for example VERSION=0.2.0}"
REPO="${GITHUB_REPOSITORY:-kuarezma/steppe}"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
OUT="dist/release"

export VERSION
Scripts/build-app.sh
Scripts/make-dmg.sh

if [ -n "${NOTARY_PROFILE:-}" ] && [ "${CODESIGN_IDENTITY:--}" != "-" ]; then
    echo "==> Notarizing"
    xcrun notarytool submit "dist/Steppe-$VERSION.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple dist/Steppe.app
    Scripts/make-dmg.sh   # re-package with the stapled app
fi

rm -rf "$OUT"; mkdir -p "$OUT/updates"
cp "dist/Steppe-$VERSION.dmg" "$OUT/"
cp "dist/Steppe-$VERSION.zip" "$OUT/updates/"
[ -f docs/release-notes/"$VERSION".md ] && cp docs/release-notes/"$VERSION".md "$OUT/updates/Steppe-$VERSION.md" || true

echo "==> Appcast"
KEY_ARGS=()
[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ] && KEY_ARGS=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE")
"$SPARKLE_BIN/generate_appcast" ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
    "$OUT/updates"
mv "$OUT/updates/appcast.xml" "$OUT/appcast.xml"
# Only the signed zip is published for Sparkle; keep the folder out of the release assets.
cp "$OUT/updates/Steppe-$VERSION.zip" "$OUT/"
rm -rf "$OUT/updates"
(cd "$OUT" && shasum -a 256 Steppe-"$VERSION".dmg Steppe-"$VERSION".zip > SHA256SUMS.txt)

echo
echo "Done. Next, when you are ready to publish:"
echo "  gh release create v$VERSION $OUT/Steppe-$VERSION.dmg $OUT/Steppe-$VERSION.zip $OUT/appcast.xml $OUT/SHA256SUMS.txt \\"
echo "     --repo $REPO --title \"Steppe $VERSION\" --notes-file docs/release-notes/$VERSION.md"
