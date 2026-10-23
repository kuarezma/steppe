# Changelog

All notable changes are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/).

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
