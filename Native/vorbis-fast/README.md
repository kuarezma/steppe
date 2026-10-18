<!-- SPDX-License-Identifier: MIT -->
<!-- Copyright (c) Steppe contributors -->
# vorbis-fast

32-bit Windows drop-in Ogg/Vorbis DLLs for Cossacks 3 under Wine. Builds Xiph
libogg 1.3.5 and libvorbis 1.3.7 with SSE2, retains the reference exports and adds
a filename-keyed PCM cache for non-streaming game sound effects. Cache entries
are immutable after publication and protected by a critical section, with a
128 MiB PCM budget (including pending decodes), 512 entries and 3 MiB per effect.
Music/ambient streams keep normal decoding. The cache assumes files do not change
during a process lifetime; it is not a general-purpose replacement for every
Vorbis API usage or PCM output format.

Requires `i686-w64-mingw32-gcc`, POSIX make, curl, tar, shasum, Python 3 and a host
C compiler for portable tests. Build flags use `-O3 -msse2 -mfpmath=sse
-march=pentium4 -mtune=generic -fno-math-errno -fomit-frame-pointer`.

```sh
make
make test
make clean
```

`fetch-sources.sh` downloads the pinned official archives, verifies SHA-256 and
extracts sources under ignored `.cache/`. To use local archives without networking:

```sh
VORBIS_FAST_OFFLINE_DIR="$ARCHIVE_DIRECTORY" make
```

The directory must contain `libogg-1.3.5.tar.gz` and `libvorbis-1.3.7.tar.gz`.
Offline archives receive the same hash verification. `make clean` removes build
outputs; `.cache/` can be removed separately. Nothing upstream is vendored.
See [THIRD_PARTY.md](THIRD_PARTY.md) for the BSD-3-Clause notices.

| Environment variable | Meaning |
| --- | --- |
| `STEPPE_MATH_PATCHES=1` | Explicitly enable determinant, plane-distance (two sites) and volume-culling detours. Every other value leaves them disabled. Multiplayer simulation equivalence has not been established. |
| `C3_VORBIS_CACHE=0` | Disable the PCM cache; other values/unset allow it only after the verified file-open bypass is installed. |
| `STEPPE_PATCH_LOG=<path>` | Append each patch site's applied/skipped status to this file. Unset/empty performs no patch-log file I/O. |
| `VORBIS_FAST_OFFLINE_DIR=<directory>` | Build-time local archive source. |
| `HOST_CC=<compiler>` | Host compiler used by the portable unit tests (default `clang`). |

Before any code patch, the main module must match the known-build table: Steam
build 3154226 has a mapped `CODE` section at RVA `0x1000`, length `0x4f0da8` and
FNV-1a64 `0xf491ea677467298c`. The hash covers `min(VirtualSize, SizeOfRawData)`
bytes at the mapped section's VirtualAddress, before any detour writes. Unknown
builds skip all code patches, disable the cache and report `skipped: unknown game build`
when logging is enabled. Each patch site also requires its expected byte signature;
the volume-culling detour additionally checks both original callees.

Patch logging writes only when `STEPPE_PATCH_LOG` is set to a nonempty path;
the application sets it on every launch.
FPS-counter repair, cached-sound file-open bypass and hardware-acceleration warning
bypass are always attempted independently of the math switch. File-open bypass
only takes effect for an existing cache hit, so disabling the cache keeps normal I/O.
If that bypass cannot be installed, both cache hits and publication are disabled
to preserve ownership of the game's file handles.

`make test` executes extracted production patch-policy/logger and cache-budget
helpers against host API mocks, including synthetic mapped PE identity, signature
failures and concurrent budget reservations. Cached PCM tests check ordered 4096-byte
reads, repeated EOF and seeks while modeling the i686 cursor alias; they also check
failed-open ownership and disabled-cache behavior. The suite cross-compiles
`test_vorbis_bench.exe` and never runs a Windows executable.
These tests do not establish real decoder PCM equivalence, actual detour execution,
Wine compatibility or multiplayer safety; those require separate runtime validation.
