# Security policy

## Reporting a vulnerability

Please report security issues privately through GitHub's **Security → Report a vulnerability** on this repository rather than a public issue. Include steps to reproduce and the affected version. You can expect an acknowledgement within a week.

## Scope and design notes

- Steppe downloads executable code (a Wine engine) and the Steam installer. Engine and library archives are pinned by SHA‑256 in `RuntimeManifest`; the Steam installer comes over HTTPS from Valve's CDN and is not pinned because Valve updates it.
- Updates use Sparkle with EdDSA signatures; the private key is never stored in the repository.
- The Windows environment is isolated from the Mac's file system (no `Z:` drive, no mapped user folders), but it is **not a security sandbox**: Wine runs with your user's privileges. Only run software you trust inside it.
- Steppe is not notarized by Apple; verify downloads with the published `SHA256SUMS.txt`.
- `Scripts/install.sh` verifies the DMG against `SHA256SUMS.txt` from the same GitHub release. That protects against corrupted downloads, **not** against someone who can change the release assets (they could change both files). If that matters to you, download the DMG in the browser and compare its checksum with the one shown in the release notes of an earlier release or announced by the maintainers. Updates delivered inside the app are different: they are verified with the project's EdDSA key, which GitHub does not hold.
