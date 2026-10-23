# Architecture

Steppe is a SwiftUI app around a headless, unit-tested Swift library (`SteppeCore`). Everything the app does can also be driven from the command line with `steppe-cli`, which is how the install pipeline is tested end to end.

```
Steppe.app (SwiftUI)                steppe-cli (developer tool)
        \                              /
         +------ SteppeCore ----------+
                 SteppeController  ← state machine for setup, play, repair
                 RuntimeManifest   ← pinned engine/library URLs + SHA-256 + patch table
                 Downloader / Archive / WinePatcher / PrefixBuilder / SteamKit
                 GameBootstrap / ProfileTuner / ResolutionPlanner / GameFiles
                 ProcessRunner / ProcessScanner / Diagnostics / Redaction
Native/
   glfix/          x86_64 dylib injected into Wine (OpenGL fixes)
   vorbis-fast/    32-bit Windows DLLs (audio cache + startup patches)
   dialog-helper/  32-bit Windows helpers that run inside the prefix (startup box, display modes)
```

## Data layout (default `~/Library/Application Support/Steppe`)

| Path | Contents |
| --- | --- |
| `engine/wswine.bundle` | Wine 10 engine with Steppe's byte patches |
| `frameworks/` | FreeType, MoltenVK, GStreamer, SDL… used via `DYLD_FALLBACK_LIBRARY_PATH` |
| `prefixes/cossacks3` | The Windows environment: Steam, the game, its saves |
| `downloads/` | Temporary downloads (deleted after install) |
| `logs/`, `settings.json` | App log (rotated, redacted), user settings |

The location can be changed once, before installing (it is remembered in `UserDefaults`).

## Install pipeline (`SteppeController.runSetup`)

Every stage checks disk state first, so setup is resumable and idempotent. Markers (`.steppe-*.json`) record which engine revision produced a directory.

1. **Mac check**: Apple silicon, macOS ≥ 14.6, free space (≥ 16 GB), Rosetta (`arch -x86_64 /usr/bin/true`; install via the standard administrator prompt).
2. **Engine**: resumable download (HTTP range, retries) → SHA‑256 → `tar -xJf` into a temp dir → `WinePatcher` → atomic move.
3. **Frameworks**: only `Contents/Frameworks` is extracted from the Sikarugir template archive.
4. **Prefix**: `wineboot --init`, then isolation (drive mappings other than `C:` removed, user-folder symlinks replaced by real folders), `AeDebug` disabled, DirectSound buffering values.
5. **Steam**: official installer copied *into* the prefix (the isolated prefix has no drive that maps the Mac's disk, so the installer cannot be run from outside) and run silently.
6. **Sign‑in and game**: Steam is started; the app polls `config/loginusers.vdf` (existence only) and `steamapps/appmanifest_333420.acf` (state flags and byte counters only; account fields are never parsed). Once signed in it sends `steam://install/333420`.
7. **Ready**. Steam is shut down so that the next start can inject the graphics fixes.

## Play pipeline (`runPlay`)

1. Stop Steam/Wine of this engine if running (so graphics fixes get injected into Steam and the game).
2. Re-apply prefix isolation.
3. Run `list-modes.exe` inside the prefix, plan the render resolution for the monitor Windows reports as primary (`ResolutionPlanner`), snap it to a mode Windows lists (`DisplayModes`) and write it into every existing `profile.cfg` (`ProfileTuner`, backup `profile.cfg.steppe-orig`). Without the helper, the Mac's menu-bar display is used unchecked.
4. `GameBootstrap` creates first-run files if they are missing (see below).
5. `GameFiles` replaces `ogg.dll`/`vorbis.dll`/`vorbisfile.dll` only if they are still the verified originals (backup `*.steppe-orig`).
6. Start `Steam.exe -applaunch 333420` with `DYLD_INSERT_LIBRARIES=libglfix.dylib`, `GLFIX_REMAP=2`, `WINEESYNC=0`.
7. Start `dismiss-dialog.exe` inside the prefix (presses OK on the game's informational startup box).
8. Watch for `cossacks.exe`; when it exits, re-apply tuning (a profile created in-game now has a `profile.cfg`), quit Steam gracefully (Cloud sync) and make sure no Wine process is left.

## Process identification

Wine rewrites the title and hides the environment of its child processes, so "which processes belong to Steppe's Wine?" is answered with `proc_pidpath`: a process counts if its executable lives inside Steppe's engine bundle. Other Wine installs (CrossOver, Whisky, …) are never touched.

## Privacy by construction

- The prefix has no `Z:` drive, `mountmgr` is disabled and user folders are plain directories.
- The Windows user is named `steppe` for new prefixes.
- Logs and diagnostics go through `Redaction` (home path, user name, SteamID64, e‑mail, IPv4, token-like values).
- Nothing is uploaded anywhere.

## Why the first-run files exist

On a fresh install the game opens its configuration dialog and then crashes (access violation at `0x00427A2B`, inside Delphi's `TStringList.InsertItem`, while loading `font1254.lib`). It starts cleanly when `Documents/cossacks` already contains `hardware.info`, `video.info`, a default profile `Cossack` and one named profile. `GameBootstrap` writes exactly those text files (in the game's own format) when they are missing. `hardware.info` reports no optional OpenGL features, which keeps the game on the conservative rendering path that the OpenGL fixes were validated against.
