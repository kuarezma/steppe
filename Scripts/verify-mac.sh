#!/bin/bash
# Hardware acceptance preparation. Does not sign in to Steam or claim a game was played.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
    echo "Requires a Mac with a logged-in desktop and accelerated OpenGL." >&2
    exit 1
fi
# uname can report x86_64 under Rosetta; hw.optional.arm64 reflects the hardware.
if [[ "$(sysctl -n hw.optional.arm64)" != 1 ]]; then
    echo "Requires Apple Silicon hardware." >&2
    exit 1
fi
python3 Scripts/verify-appcast.py --selftest
python3 Scripts/extract-strings.py --check
swift test
STEPPE_REQUIRE_GL=1 make -C Native/glfix clean test
make -C Native/vorbis-fast clean test
make -C Native/dialog-helper clean test
Scripts/build-app.sh
codesign --verify --deep --strict dist/Steppe.app
! codesign -d --entitlements :- dist/Steppe.app 2>/dev/null | grep -q "com.apple.security.cs." || {
    echo "Unexpected hardened-runtime bypass entitlement" >&2
    exit 1
}
if grep -rla -E "/Users/[A-Za-z0-9_.-]+/" dist/Steppe.app; then
    echo "Home path leaked into app bundle" >&2
    exit 1
fi
echo "Automated hardware checks complete. Game acceptance is still required: docs/ACCEPTANCE.md"
