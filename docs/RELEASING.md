# Releasing

## What is signed, and with what

| Thing | Signature | Why |
| --- | --- | --- |
| Update feed entries (`appcast.xml`) | **Sparkle EdDSA** key | Lets installed copies trust updates without Apple's help |
| `Steppe.app` | **ad hoc** (`codesign -s -`) | No Apple Developer ID certificate. Never sign public builds with a personal "Apple Development" certificate: its subject contains your e-mail address |
| Downloads | `SHA256SUMS.txt` | Users can verify the DMG |

Because the app is not notarized, first-time users need the *Open Anyway* step described in the README. Sparkle updates do not carry the quarantine flag, so they install without prompts. If the maintainers later enrol in the Apple Developer Program, set `CODESIGN_IDENTITY` and `NOTARY_PROFILE` (see the header of `Scripts/release.sh`); that path is optional and untested.

## The EdDSA key

The public key is committed (`Config/sparkle_public_key.txt`) and embedded in the app. The **private key must never be committed.** Create or export it with Sparkle's tool:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys        # creates the key in the login keychain, prints the public key
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x ~/secure/steppe-sparkle.key   # export a backup (keep it in a password manager)
```

If the private key is lost, installed copies can never be updated (they would have to download a new build), so back it up. To let GitHub Actions publish releases, store the exported key's contents as the repository secret `SPARKLE_PRIVATE_KEY`.

## Cutting a release

1. Update `CHANGELOG.md` and add `docs/release-notes/<version>.md`.
2. Make sure `swift test`, `python3 Scripts/extract-strings.py --check` and `make -C Native/glfix test` pass and that you have played a match on a clean install (`steppe-cli setup`, then Play).
3. **Locally:** `VERSION=0.2.0 Scripts/release.sh` and then the `gh release create …` command it prints.
   **Or with CI:** push a tag `v0.2.0`; `.github/workflows/release.yml` builds, signs the feed and publishes.
4. Install the previous release, then use *Check for Updates…* to confirm that the update path works.

The app looks for updates at `https://github.com/kuarezma/steppe/releases/latest/download/appcast.xml`, so every release must upload `appcast.xml` as an asset.
