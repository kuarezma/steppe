# Engine and game patches

Everything Steppe changes, why, and how to re-derive it when an upstream component moves. Nothing here modifies `cossacks.exe` on disk.

## 1. Wine macOS driver (`winemac.so`): four byte patches

Applied by `WinePatcher` after verifying the upstream file's SHA‑256 (`4cbf65e3…`). Offsets are file offsets in `lib/wine/x86_64-unix/winemac.so` of `WS12WineSikarugir10.0_6`.

| Offset | Bytes | Meaning |
| --- | --- | --- |
| 194532 | `0f 84 0b 02 00 00` → `e9 0c 02 00 00 90` | Always skip registering `WGL_ARB_pbuffer` / `render_texture`. `CGLCreatePBuffer` fails with error 10005 (`invalid drawable`) on current macOS, so the game must not see pbuffers. |
| 222017 | `e8 14 d0 00 00` → five `nop` | Skip a `free()` of the pbuffer device context that is freed twice. |
| 223138 | `e8 b3 cb 00 00` → five `nop` | The second such `free()`. |
| 233474 | `75 0e` → `90 90` | Make `wglGetPixelFormat` succeed for the default (“behind”) surface mode; without it the game reports “Need OpenGL 1.1”. |

After patching the file is re-signed ad hoc (`codesign --force --sign -`) and checked: the file is copied, its signature stripped, and the SHA‑256 compared with `patchedUnsignedSHA256` (`5c422f82…`). A plain `--remove-signature` on the freshly patched file is *not* canonical (leftover signature padding), which is why the check goes through a sign‑and‑strip round trip.

To move to another engine: find the equivalent instructions, update `RuntimeManifest.winemac`, bump `patchRevision`.

## 2. `glfix` (`Native/glfix`)

An x86_64 dylib injected with `DYLD_INSERT_LIBRARIES` into the Wine processes:

- adds `#version 120` to the game's GLSL shaders that do not declare a version (Apple's default GLSL 1.10 rejects implicit int→float conversions → black units);
- emulates pbuffers with framebuffer objects (`pbemu.c`, `GLFIX_REMAP=2`);
- repairs foliage normals and bone-uniform locations;
- filters Command‑key chords that macOS would otherwise swallow.

Debug environment variables: `GLFIX_LOG`, `GLFIX_FRAMETIMES`. See `Native/glfix/README.md`. `make -C Native/glfix test` runs the suite (some checks need a real GL context).

## 3. `vorbis-fast` (`Native/vorbis-fast`)

`ogg.dll`, `vorbis.dll`, `vorbisfile.dll` built from libogg 1.3.5 and libvorbis 1.3.7 (pinned SHA‑256) with SSE2, plus game-specific code in `vorbisfile_fast.c`:

- a bounded PCM cache so repeated sound effects are not decoded again (about a third of the main thread in heavy battles was spent there);
- `FPS=0,0` fix (a race in the game's performance monitor, `0x004d1870`);
- an optional geometry-math patch set (`STEPPE_MATH_PATCHES=1`, off by default; multiplayer determinism unverified).

Before any code patch, the main module must match every region in a verified build's table. Identity uses FNV-1a64 hashes of the regions touched by the patches: the full `CODE` section differs at runtime, while these five regions matched the file in four separate Wine runs. Limiting identity to patch coverage tolerates user-specific memory changes elsewhere in `CODE`. The module must remain at ImageBase `0x400000`, with valid MZ/PE headers and sections; every region must lie within a mapped section and be readable. Hashes cover `length` bytes at `base + (VA - 0x400000)`.

Steam build 3154226:

| VA | Length | FNV-1a64 |
| --- | --- | --- |
| `0x4a4000` | `0x5000` | `0x4251b6bbba49be48` |
| `0x4d1800` | `0x100` | `0xcbde57ca8ed08a0a` |
| `0x571f00` | `0x200` | `0x60e5031fe6a3b410` |
| `0x4c32f0` | `0x40` | `0x7ad043e46808a559` |
| `0x8ef100` | `0x40` | `0x2e3f22362e18bef3` |

Unknown builds skip all code patches and disable the PCM cache. Each patch also requires exact target signatures; the volume-culling detour checks both original callees.

Patch logging writes only when `STEPPE_PATCH_LOG` is set to a nonempty path (the application sets it on every launch). An unknown build reports one line, `skipped: unknown game build (regions <va>:<fnv> …)`, within the 512-byte log buffer; unreadable regions are marked `unreadable`. Add builds only after independent verification of the logged region hashes. The PCM cache is enabled only if the cached-sound file-open bypass was installed successfully. The DLLs link `libgcc` statically; a dynamic link makes the DLL fail to load under Wine.

Note: `vorbisfile.dll` is loaded lazily, *after* the game's startup box. Its own patch for that box therefore never takes effect; the dialog helper handles the box.

## 4. `dismiss-dialog.exe` (`Native/dialog-helper`)

Runs inside the prefix. Finds the game's informational “video card does not support hardware acceleration” form (Delphi class `TMessageForm`, title “Cossacks III”, exactly one button, “OK”) and posts a mouse click to that button. `BM_CLICK` is ignored by the game's Delphi button; posted `WM_LBUTTONDOWN/UP` works. Dialogs with other buttons are left alone.

`list-modes.exe` (same folder) prints the primary monitor's current mode and every mode `EnumDisplaySettings` returns. The game crashes at `00427A2B` when its configured resolution is not among them, so Steppe plans the resolution for that monitor and snaps it to a listed mode (`DisplayModes.snap`) before writing `profile.cfg`.

## 5. First-run files (`GameBootstrap`)

See [ARCHITECTURE.md](ARCHITECTURE.md#why-the-first-run-files-exist).

## 6. Runtime environment

`WINEESYNC=0` (ESYNC makes Wine's helper services spin at 100 % CPU on this engine), `WINEDLLOVERRIDES=mscoree,mshtml=;mountmgr.sys=d`, `WINEDEBUG=-all` while playing, `LANG=en_US.UTF-8`, `USER=steppe`.
