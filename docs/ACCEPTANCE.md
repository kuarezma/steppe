# Apple Silicon and second-game acceptance

Status: **pending hardware/game verification**. A green CI run is not a played-game result.
PR #3 provides the lifecycle fixes this branch builds on; do not infer that either PR was merged.

## Automated checks on a Mac

Use an Apple Silicon Mac with a logged-in desktop, Xcode command-line tools,
Python 3 and mingw-w64 (`brew install mingw-w64`). From this checkout run:

```sh
Scripts/verify-mac.sh
```

This runs Swift/localization/native tests and builds/verifies the app bundle.
`STEPPE_REQUIRE_GL=1` makes unavailable accelerated GL a failure, so pbuffer tests
cannot silently be counted as verified. The optional old-library reference
comparison may still be skipped; it is not the hardware test gate.
The script neither signs in to Steam nor starts or removes an existing game install.
Inspect test output for any other skips (in particular the external-volume test).

## Manual game matrix (use a disposable install and copied saves)

Record commit SHA, Mac/chip/RAM, macOS, game build, display/refresh, preset,
custom resolution, and whether experimental math patches are enabled.
Never run destructive acceptance against the only copy of a player's saves.

| Check | Evidence required | Status |
| --- | --- | --- |
| Fresh install through Steam sign-in and game download | Redacted diagnostics; successful menu and map load | Pending |
| Three launches, quitting normally between them | Three successful project loads and playable sessions | Pending |
| At least 15 minutes in a busy map | Frame-time log, median and p99; compare same scene with base commit | Pending |
| Cancel setup, retry | Steam closes; retry reaches sign-in without hanging | Pending |
| Force Quit then immediate Play | No stale stop kills the new launch | Pending |
| Force Quit while microphone permission is open | After answering, no Steam/game starts; record the wait | Pending |
| Internal/external display, clamshell and wake | Correct resolution and HUD after each topology change | Pending |
| External install: quit, reopen, uninstall, reinstall | Chosen location survives; no unintended reinstall after deletion failure | Pending |
| Damaged disposable prefix with copied save/profile | Backup exists and content matches; manually restore and load save | Pending |
| Ukrainian locale/font startup and multithreading | Change one variable at a time; record repeated loads, not just error address | Pending |

Do not mark the old `00427A2B` report resolved from process tests alone. The
locale/font report and the thread-timing hypothesis require separate reproductions:
https://github.com/kuarezma/steppe/issues/1

Add actual results to `docs/COMPATIBILITY.md`, including failed attempts and skips.
Do not overwrite older evidence with an unplayed version number.

## Second-game integration

`GameDefinition` now owns Steam ID, executable, prefix key and Windows documents/profile
paths. Paths, Steam discovery/install requests, process detection and save preservation
use that definition. Existing Cossacks paths and identity are unchanged. New definitions
start with `.none` integration and do not inherit Cossacks GL injection or math patches.

This is the shared core foundation, **not a second supported game**. The app/controller
and its bootstrap, profile writer, audio hashes, engine patches, disk budgets and UI
remain Cossacks-specific. The controller intentionally has no alternate-game selector.
Do not expose a candidate until those remaining policies are separated and tested.
Two definitions sharing an engine/root are not a concurrent-launch guarantee:
process cleanup, settings and engine state remain shared. Validate candidates in a
separate root, one at a time.

For the next implementation, choose a legitimately owned Steam game and record its
verified app ID/executable/config/save paths. Provide a game-specific bootstrap/tuner
(or explicit no-op), engine and DLL policy, disk budget and UI text. Never guess an
app ID or copy Cossacks binary patches to another executable. Then repeat the full
matrix above and add a compatibility row only after actual play. The synthetic
`fixture-game` in unit tests is not a Steam catalog entry or compatibility evidence.
