# Changelog

All notable changes are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/).

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
