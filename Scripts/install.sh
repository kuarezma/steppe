#!/bin/bash
# Installs the latest Steppe release into /Applications and clears the download quarantine flag.
#
#   curl -fsSL https://raw.githubusercontent.com/kuarezma/steppe/main/Scripts/install.sh | bash
#
# What it does, so you can read before you run: downloads the newest DMG and SHA256SUMS.txt from the project's
# GitHub release, verifies the checksum, copies Steppe.app to /Applications and removes the quarantine attribute
# (Steppe is not notarized by Apple). Nothing else is modified.
set -euo pipefail

REPO="${STEPPE_REPO:-kuarezma/steppe}"
TMP="$(mktemp -d)"
trap 'hdiutil detach "$TMP/mnt" -quiet 2>/dev/null || true; rm -rf "$TMP"' EXIT

[ "$(uname -m)" = "arm64" ] || { echo "Steppe needs a Mac with Apple silicon."; exit 1; }

echo "Looking up the latest release…"
JSON="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest")"
DMG_URL="$(printf '%s' "$JSON" | grep -o '"browser_download_url": *"[^"]*\.dmg"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')"
SUMS_URL="$(printf '%s' "$JSON" | grep -o '"browser_download_url": *"[^"]*SHA256SUMS.txt"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')"
[ -n "$DMG_URL" ] && [ -n "$SUMS_URL" ] || { echo "Could not find the release files."; exit 1; }

DMG="$TMP/$(basename "$DMG_URL")"
echo "Downloading $(basename "$DMG_URL")…"
curl -fL --progress-bar "$DMG_URL" -o "$DMG"
curl -fsSL "$SUMS_URL" -o "$TMP/SHA256SUMS.txt"
EXPECTED="$(grep " $(basename "$DMG")\$" "$TMP/SHA256SUMS.txt" | awk '{print $1}')"
ACTUAL="$(shasum -a 256 "$DMG" | awk '{print $1}')"
[ -n "$EXPECTED" ] && [ "$EXPECTED" = "$ACTUAL" ] || { echo "Checksum mismatch. Aborting."; exit 1; }

mkdir -p "$TMP/mnt"
hdiutil attach "$DMG" -mountpoint "$TMP/mnt" -nobrowse -quiet
[ -d "$TMP/mnt/Steppe.app" ] || { echo "Steppe.app not found in the disk image."; exit 1; }

if pgrep -x Steppe >/dev/null; then echo "Please quit Steppe first."; exit 1; fi
rm -rf /Applications/Steppe.app
ditto "$TMP/mnt/Steppe.app" /Applications/Steppe.app
xattr -dr com.apple.quarantine /Applications/Steppe.app 2>/dev/null || true
echo "Installed. Open Steppe from Applications."
