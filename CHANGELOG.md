# Changelog

All notable changes are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/).

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
