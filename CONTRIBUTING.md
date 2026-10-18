# Contributing to Steppe

Thank you for helping! Bug reports, compatibility reports, translations, tests, performance work and new-game support are all welcome. By contributing you agree your work is released under the [MIT license](LICENSE).

## Quick start

```bash
git clone https://github.com/kuarezma/steppe && cd steppe
brew install mingw-w64                     # for the Windows helper DLLs
swift test                                 # unit tests (44, run in about a second)
python3 Scripts/extract-strings.py --check # every UI string has an English and Turkish entry
make -C Native/glfix test                  # OpenGL shim tests (needs a normal desktop session)
Scripts/build-app.sh                       # builds dist/Steppe.app, ad hoc signed
```

Open `Package.swift` in Xcode to work on the app, or use `swift run Steppe` for a quick look (updates are disabled without the app bundle).

`swift run steppe-cli --help`-style usage is documented at the top of [`Sources/steppe-cli/main.swift`](Sources/steppe-cli/main.swift). The command `steppe-cli setup --root /some/folder --stop-at-sign-in` runs the real install pipeline up to the Steam login without any UI, which is the easiest way to test changes to the installer.

## Repository map

| Path | What lives there |
| --- | --- |
| `Sources/SteppeCore` | All logic: manifest, downloads, patching, prefix, Steam, profiles, play flow. UI-free and unit tested |
| `Sources/Steppe` | SwiftUI app |
| `Sources/steppe-cli` | Developer / CI tool |
| `Native/` | C code: `glfix` (macOS OpenGL fixes), `vorbis-fast` (Windows DLLs), `dialog-helper` |
| `Resources/` | Info.plist template and `Localizable.strings` |
| `Scripts/` | Build, icon, DMG, release and install scripts |
| `docs/` | Architecture, engine patches, troubleshooting, releasing |

Start with [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) and [`docs/ENGINE_PATCHES.md`](docs/ENGINE_PATCHES.md).

## Ground rules

- **Privacy first.** Never log or store Steam credentials, account IDs, Mac user names or home paths. New diagnostics must go through `Redaction`. Do not parse account fields of Steam's files (read only what you need; see `SteamACF`).
- **Do not commit game files, Wine binaries, built `.dll`/`.dylib` files or secrets.** The CI bundle scan and `.gitignore` help, but check your diff.
- **Verify what you download.** New third-party artifacts need a pinned SHA‑256 in `RuntimeManifest`.
- **Binary patches are verified, not assumed.** A patch applies only when the expected bytes match; otherwise skip and report.
- **Keep it testable.** Put logic in `SteppeCore` with a unit test; the app target should only present state.
- Match the surrounding code style. Comments explain constraints the code cannot show.
- Run `swift test` and the localization check before opening a pull request.

## Translations

User-facing text uses the English sentence as its key. Add the key to `Resources/en.lproj/Localizable.strings` and your language's `Localizable.strings`, add the language code to `CFBundleLocalizations` in `Resources/Info.plist.template`, and run `python3 Scripts/extract-strings.py --check`. Messages that contain values use `%@` / `%d` (or `%1$@` when your word order differs).

## Adding another game

Steppe is built around one game today (`RuntimeManifest.steam.appID`, `GameBootstrap`, `ProfileTuner`). To support another Steam game, the pieces to generalise are: the app ID and display name, the game's config files and first-run requirements, which patches/DLLs apply, and the profile tuner. Open an issue first so we can agree on the shape (a `GameDefinition` type is the intended direction).

## Updating the Wine engine

1. Change the URLs and hashes in `Sources/SteppeCore/RuntimeManifest.swift`.
2. Re-derive the four `winemac.so` patches (see `docs/ENGINE_PATCHES.md`), update `originalSHA256`, `patchedUnsignedSHA256` and offsets, bump `patchRevision`.
3. Run `steppe-cli setup` on a clean folder, then play to the main menu and into a match; compare rendering with the previous engine.
4. Note the result in `docs/COMPATIBILITY.md`.

## Reporting a problem

Use the issue templates and attach **Settings → Export Diagnostics**. For crashes, say what you were doing and your Mac model.

## Releases

Maintainers: see [`docs/RELEASING.md`](docs/RELEASING.md).
