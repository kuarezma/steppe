# Changelog

All notable changes are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Fixed
- Setup and launch can no longer hang behind Wine's background processes (`ProcessRunner.run`): `wineserver` and Wine's services inherit the output pipes of the command that started them, and the runner used to wait for those pipes to close, which defeated every timeout and made *Cancel* unresponsive. Output is now awaited for a bounded time after the command exits, and not at all once it timed out or was cancelled.
- *Force Quit Game* no longer leaves an error note such as "The operation couldn't be completed" on the Ready screen (`SteppeController.runPlay`), and the Ready screen appears only once everything is stopped: a *Play* pressed right after it could be killed by the Force Quit that was still finishing (`SteppeController.forceStop`).
- Cancelling the setup or a launch now really closes Steam (`SteppeController.shutDownSteam`): the cleanup ran inside the cancelled task, where every process call returned immediately and Steam was left running.
- *Cancel* while a command is running (unpacking, a registry step) ends as a cancelled setup instead of "Setup failed": a command stopped by a cancellation now reports the cancellation, not the exit status of the kill (`ProcessRunner.run`).
- A launch that was force-quit while the macOS microphone prompt was still open no longer starts Steam afterwards.
- A refresh that was already in flight when *Install & Play*, *Play*, *Repair* or *Uninstall* was pressed can no longer overwrite the screen of the running operation (`SteppeController.applyRefresh`), and one that belongs to a previous install location no longer reports that location's free space.
- *Uninstall Everything* keeps the chosen install location. It used to forget it while the running app kept using it, so a reinstall on an external disk was not found after the next launch.
- *Uninstall Everything* reports when files could not be deleted. It used to continue silently, and if the game was among what was left, Steppe started installing the missing parts again.
- *Uninstall Everything* no longer waits for a game that Steppe only attached to; the game is stopped like everything else.
- *Repair…* checks that it can start (supported Mac, install folder not in use by another copy) before it touches any file.
- Rebuilding a damaged Windows environment keeps game profiles and saves (`PrefixBuilder.clearForCreation`): a prefix that contains the game's documents is moved aside as `cossacks3.damaged-<date>` instead of being deleted.
- Processes of an engine whose path resolves below `/private` (for example an install location under `/tmp`) are found again (`ProcessScanner.processes`).
- Settings survive an update (`AppSettings`): a `settings.json` written by an older or newer version, or one with a single invalid value, no longer resets every setting; an out-of-range custom resolution falls back to the default instead of being written into the game's configuration.
- *Export Diagnostics* includes Wine and game logs that contain bytes that are not valid UTF-8, and reads only the end of large logs (`Diagnostics.report`).
- One unreadable `profile.cfg` no longer stops the resolution from being applied to the other profiles (`ProfileTuner.apply`).
- The download-speed label no longer shows the previous download's speed while Steam is being downloaded.
- `glfix` pbuffer copies ignore pixel-store state left in the context (`pb_CGLTexImagePBuffer`): a non-default row length or skip could write past the copy buffer; the state is now saved, neutralised and restored.

### Security
- The Steam installer, which cannot be pinned by checksum, is never resumed from a partial file, neither one left by an earlier run nor one from a failed attempt, so it cannot be assembled from two different versions (`Downloader.download`).
- The build's privacy gate now fails when the executable contains a home-directory path (`Scripts/build-app.sh`; the previous `grep -q` under `pipefail` reported a match as clean), and the CI scan covers binary files.
- A Python bytecode file that embedded a local path was removed from the repository and `__pycache__` is ignored. CI runs with a read-only token.

## [0.1.10]

### Fixed
- Preserve custom resolution (`AppSettings.resolution(for:modes:)`): custom resolutions (such as `1600×900` on a notched built-in MacBook display) are now written directly to `profile.cfg` without being snapped to Windows `DisplayModes`, giving users full manual control over game dimensions.
- Skip redundant display-mode probe before launch (`SteppeController.runPlay`): `list-modes.exe` is no longer spawned before launching `cossacks.exe` when custom resolution is enabled, and cached `displayModes` are reused across launches unless the macOS display topology changes (`handleDisplayChange`), noticeably speeding up launch times.
- Startup environment diagnostics (`SteppeController.seedFirstRunFiles`): logs the selected Windows user folder, directory listing under `drive_c/users`, and `cossacks.ini` `UseMultithreadedMode` setting on startup to streamline troubleshooting and prefix analysis.

## [0.1.9]

### Fixed
- MacBook camera notch HUD layout (`GameFiles.applyNotchHUD`): splits the top 6-resource bar left and right of the camera notch at the very top edge (**Wood, Food, Stone** on the left; **Gold, Iron, Coal** on the right) while shifting the left-side status column (**Population/House icon and text**, **Idle Peasants**, **Idle Mines**, and **Scenario Objectives**) down onto the row directly below the left resource bar (`notchLeftDropY = 48`). This keeps the resource bar docked cleanly at the top edge beside the notch while completely preventing any overlap with the top-left population text.

## [0.1.8]

### Added
- In-app **Updates** section in *Settings* and quick **Check for Updates…** button on the Welcome and Ready screens: shows the current Steppe version and last update check timestamp, lets users check for updates with one click, toggle automatic update checks and automatic background update installation, and open GitHub release notes directly.

## [0.1.7]

### Fixed
- Refined MacBook camera notch HUD layout (`GameFiles.applyNotchHUD`): instead of splitting the top resource bar horizontally at `y = 0` (where the left half could overlap long localized Population strings such as Turkish `"18 üzerinden 0"` on 14″ MacBooks), Steppe now keeps **Population** (top-left) and **Game Menu** (top-right) in the auxiliary areas beside the notch and lowers the complete, unbroken 6-resource bar (`1159×58`) cleanly below the camera notch (`notchDropY = Max(46, round(GetViewerHeight * 0.042 / dpiscale))`), while leaving `data/hud/hud.mat`, windowed mode, and non-notched displays completely untouched.

## [0.1.6]

### Added
- Automatic MacBook camera notch HUD layout (`GameFiles.applyNotchHUD` & `DisplayInfo.hasNotch`): on MacBooks with a camera notch (`safeAreaInsets.top > 0`), the top resource bar (`ShowResourcePanel`) is automatically split around the notch — **Wood, Food, Stone** sit cleanly to the left of the notch and **Gold, Iron, Coal** sit to the right. Non-notched Macs, external monitors, and 16:10/16:9 display modes keep the original single-piece bar untouched, and `.steppe-orig` backups are automatically restored when switching to a non-notched display or running *Restore original game files*.

## [0.1.5]

### Added
- Early-crash detection (`LaunchOutcome`): detects rapid exits (< 15 seconds), classifies crash signatures (including Delphi `00427A2B` access violations), and surfaces actionable recovery hints on the Ready screen.
- Screen topology and wake detection: monitors display changes, clamshell transitions, and system wake events, re-querying display modes so game configurations never target detached screens.
- Resumable download resiliency: automatic retry and corruption recovery in engine and tool downloaders with exponential backoff and pinned SHA-256 hash checks.
- External volume protection: detects detached or unmounted drives (`0 bytes free`) and halts safely before write operations, preventing prefix corruption or phantom local directories.
- Comprehensive native test suites for `vorbis-fast` and `dialog-helper` in CI.

### Fixed
- Multi-monitor and ultrawide display mode snapping (`DisplayModes.snap`): falls back gracefully to standard aspect-ratio modes (including 16:9 on 21:9 ultrawide screens) within the preset pixel budget without triggering Delphi's `TStringList` crash.
- Lossless Delphi profile encoding (`ProfileTuner`): uses ISO-Latin-1 byte preservation when rewriting `profile.cfg`, protecting Cyrillic, Turkish, and extended 8-bit ANSI player names from UTF-8 corruption.
- OpenGL PBuffer emulation memory lifecycle (`pbemu.c`): reference-counted pbuffer table reclamation (`gc_pb_locked`) prevents table exhaustion (`MAXPB = 4096`) and memory leaks across prolonged play sessions.

### Documentation
- Fixed Markdown table syntax in compatibility matrix and added a verified multi-display Apple M3 report.
- Comprehensive troubleshooting guide covering macOS Sequoia (15+) Gatekeeper overrides, manual log inspection, external volume unmounts, and display crash recovery.
- Updated architectural documentation and contribution guides reflecting expanded test suites (75+ unit tests).

## [0.1.4]

### Fixed
- Crash at `00427A2B` (null write) with an external display: the resolution was planned for the screen Steppe's window was on, and could be a size Windows cannot list as a display mode. Steppe now asks Windows for its display modes before each launch (`list-modes.exe`), plans for the monitor the game runs on and writes only a listed mode. The custom-resolution picker offers those modes. ([#1](https://github.com/kuarezma/steppe/issues/1))

## [0.1.3]

### Fixed
- Microphone permission for Steam and voice chat on MacBooks: added `NSMicrophoneUsageDescription`, `com.apple.security.device.audio-input` entitlements (for both `Steppe.app` and the Wine engine binaries), proactive macOS TCC authorization before Steam starts, automatic TCC signature recovery after ad-hoc updates, and microphone permission controls in *Settings → Game*.

## [0.1.2]

### Added
- Language setting (Automatic, English, Türkçe) in Settings. English is the default unless macOS is set to Turkish.

## [0.1.1]

First release built by the automated release workflow; no functional changes.

## [0.1.0]

First public version.

### Added
- One-click installer for Cossacks 3 on Apple silicon: verified Wine engine, isolated Windows environment, Steam, game download through the user's own Steam account.
- Automatic graphics tuning for the current display (Performance, Balanced, Quality, Native presets).
- OpenGL fixes (`glfix`), audio cache (`vorbis-fast`), startup dialog helper and first-run files.
- English and Turkish interface; diagnostics export with personal data removed.
- In-app updates with Sparkle (EdDSA-signed).
