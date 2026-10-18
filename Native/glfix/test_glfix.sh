#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) Steppe contributors
set -eu
cd "$(dirname "$0")"
python3 test_safety.py
flags="-arch x86_64 -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.0"
for name in test_child test_spawner test_frametimes; do
    clang $flags "$name.c" -o "build/$name"
done
clang $flags -dynamiclib dummy_lib.c -o build/libdummy.dylib
# pbemu identifies Wine through the CGL caller's return address. Keep the shim's
# frame: an -O2 tail jump would report test_pbemu as the caller instead of Wine.
clang $flags -fno-optimize-sibling-calls -dynamiclib test_winemac_shim.c -framework OpenGL -o build/winemac.so
# Negative control: the optimized shim must lose that return address.
mkdir -p build/tailcall
clang $flags -dynamiclib test_winemac_shim.c -framework OpenGL -o build/tailcall/winemac.so
clang $flags -DTEST_CALLER_INTERPOSER -dynamiclib test_winemac_caller.c -framework OpenGL -o build/libtest_winemac_caller.dylib
clang $flags test_winemac_caller.c -framework OpenGL -o build/test_winemac_caller
for name in glfix_validate test_prog_uniform test_share_group test_pbemu glfix_dump_bones test_gl_context test_eipprof; do
    clang $flags "$name.c" -framework OpenGL -o "build/$name"
done
python3 test_runner.py
