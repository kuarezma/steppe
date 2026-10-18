#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) Steppe contributors
set -eu
cd "$(dirname "$0")"
mkdir -p .cache
fetch() {
    archive=$1
    expected=$2
    url=$3
    target=".cache/$archive"
    if [ ! -f "$target" ]; then
        partial="$target.part.$$"
        trap 'rm -f "$partial"' EXIT HUP INT TERM
        if [ -n "${VORBIS_FAST_OFFLINE_DIR:-}" ]; then
            cp "$VORBIS_FAST_OFFLINE_DIR/$archive" "$partial"
        else
            curl --fail --location --proto '=https' --tlsv1.2 "$url" -o "$partial"
        fi
        actual=$(shasum -a 256 "$partial" | cut -d ' ' -f 1)
        [ "$actual" = "$expected" ] || { echo "Checksum mismatch: $archive" >&2; exit 1; }
        mv "$partial" "$target"
        trap - EXIT HUP INT TERM
    fi
    actual=$(shasum -a 256 "$target" | cut -d ' ' -f 1)
    [ "$actual" = "$expected" ] || { echo "Checksum mismatch: $archive" >&2; exit 1; }
    echo "SHA256 PASS $archive $actual"
}
fetch libogg-1.3.5.tar.gz 0eb4b4b9420a0f51db142ba3f9c64b333f826532dc0f48c6410ae51f4799b664 https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.gz
fetch libvorbis-1.3.7.tar.gz 0e982409a9c3fc82ee06e08205b1355e5c6aa4c36bca58146ef399621b0ce5ab https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz
