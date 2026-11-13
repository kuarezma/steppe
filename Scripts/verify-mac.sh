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
swift test
python3 Scripts/extract-strings.py --check
STEPPE_REQUIRE_GL=1 make -C Native/glfix test
make -C Native/vorbis-fast test
make -C Native/dialog-helper test
Scripts/build-app.sh
codesign --verify --deep --strict dist/Steppe.app
echo "Automated hardware checks complete. Game acceptance is still required: docs/ACCEPTANCE.md"
