# Troubleshooting

First, if Steppe is running, open **Settings → Export Diagnostics**. It writes a shareable report with your system configuration, Steppe's state, and recent log lines, with personal data (user names, home paths, Steam IDs, IP addresses) strictly removed. Attach it to any issue or bug report.

## macOS Sequoia (15+) & Gatekeeper (“Steppe cannot be opened”)

Steppe is an open-source project and is not notarized through Apple's paid developer program. Modern macOS versions—especially macOS Sequoia (15.0+)—will display a security dialog stating that the developer cannot be verified or that Steppe "cannot be opened because it is from an unidentified developer".

You have two simple ways to allow Steppe to run:

1. **macOS System Settings (GUI)**:
   - Attempt to open Steppe once so macOS registers the attempt.
   - Open **System Settings → Privacy & Security**.
   - Scroll down to the **Security** section.
   - You will see a notice: *"Steppe was blocked from use because it is not from an identified developer"*. Click **Open Anyway**.
   - Enter your Mac admin password or use Touch ID when prompted.

2. **Terminal Command (Quickest)**:
   - If you downloaded the `.dmg` or moved the app manually, clear the quarantine attribute:
     ```bash
     xattr -dr com.apple.quarantine /Applications/Steppe.app
     ```
   - Alternatively, install via `curl -fsSL https://raw.githubusercontent.com/kuarezma/steppe/main/Scripts/install.sh | bash`, which clears the quarantine flag automatically.

## External monitors, Ultrawide displays & Clamshell mode (Crash at `00427A2B`)

In Cossacks 3 (a 32-bit Delphi application), setting a screen resolution that Windows cannot list via `EnumDisplaySettings` causes an instant access violation at `0x00427A2B` inside `TStringList.InsertItem`.

Steppe actively manages display modes to prevent this crash:
- **Windows Display Probing:** Before every launch, Steppe runs `list-modes.exe` inside the prefix to probe the exact display modes reported by Windows for the primary monitor.
- **Mode Snapping & Ultrawide Fallback:** `DisplayModes.snap` snaps your chosen preset to the largest enumerable resolution matching your monitor's aspect ratio within the preset's pixel budget (or the smallest same-aspect mode if smaller same-aspect modes exist above the budget). On **21:9 or 32:9 ultrawide monitors** where the display lists no smaller modes of its own aspect ratio and you choose a lower preset, Steppe falls back to the largest enumerable mode of another aspect ratio (such as 16:9 1600×900 or 1280×720) that fits the preset budget (or the smallest enumerable mode if none fits).
- **Lossless ANSI Profile Handling:** When updating `profile.cfg`, Steppe uses lossless ISO-Latin-1 encoding. Player profiles containing Turkish, Cyrillic, or other extended 8-bit characters are never corrupted.
- **Dynamic Screen & Wake Detection:** When plugging or unplugging external monitors, closing the laptop lid (clamshell mode), or waking the Mac from sleep, Steppe refreshes the primary display info and invalidates cached Windows modes so the next **Play** re-queries `list-modes.exe`.
- **Early-Crash Hints:** If the game exits within 15 seconds of launch, Steppe checks the log tail: if a crash signature (`00427a2b`, `access violation`, `unhandled page fault`, or `unhandled exception`) is present, it recommends switching to the **Balanced** preset or running **Settings → Repair…**; otherwise, for a generic early exit, it prompts you to check **Settings → Export Diagnostics…** or **Show Logs**.

If you still experience crash `00427A2B`:
1. Delete the `cossacks` folder located at `~/Library/Application Support/Steppe/prefixes/cossacks3/drive_c/users/steppe/Documents/cossacks` (your campaign progress and Cloud saves are safely stored on Steam).
2. Choose the **Balanced** or **Performance** preset in *Settings → Preset*.
3. Run *Settings → Maintenance → Repair…* to re-verify bootstrap files.

## If Steppe itself cannot open or you need logs manually

If the GUI app will not start or you are troubleshooting headlessly, you can access logs and run diagnostics directly from the command line:

- **Log File Locations:**
  - App & Orchestrator Log: `~/Library/Application Support/Steppe/logs/steppe.log`
  - Game Session Log (Wine & Game stdout/stderr): `~/Library/Application Support/Steppe/logs/game-session.log`
  - Steam Setup Log: `~/Library/Application Support/Steppe/logs/steam-setup.log`
  - Dialog & Mode Probing Log: `~/Library/Application Support/Steppe/logs/dialog-helper.log`

- **Headless CLI Status:**
  Run the developer CLI tool from the repository root:
  ```bash
  swift run steppe-cli status
  ```
  This command prints the state of the engine, prefix, installed game files, and disk space without launching any GUI window.

## External SSD / USB drives & Unmounted Volumes

Steppe fully supports installing the Wine prefix and Steam library on external SSDs or USB-C drives.

- **Unmount & Detached Drive Detection:** If an external drive is unplugged or fails to mount, Steppe's disk space check detects that the destination volume is unavailable (`0 bytes free`) and stops setup before downloading anything.
- **Removable Volume Permissions:** On first launch from an external drive, macOS will prompt: *"Steppe would like to access files on a removable volume"*. Click **Allow**. If accidentally denied, re-enable it in **System Settings → Privacy & Security → Files and Folders → Steppe**.
- **Safe Ejection:** When quitting Cossacks 3, Steam remains active in the background for a few moments to sync your save games to Steam Cloud. Always wait until Steppe returns to the *Ready to Play* screen before unplugging your drive.

## Steam microphone / voice chat permissions

Steppe includes `NSMicrophoneUsageDescription` and the `com.apple.security.device.audio-input` entitlement, forwarding the macOS audio input device to Wine's CoreAudio stack.

If voice chat in Steam is not picking up audio or you previously declined the macOS microphone prompt:
- Open Steppe, navigate to **Settings → Game**, and click **Reset Microphone Permission** (or **Allow Microphone**).
- Alternatively, go to macOS **System Settings → Privacy & Security → Microphone** and toggle **Steppe** ON.
- Restart Steppe and launch the game.

## “Not enough free disk space”

About 16 GB of free disk space is required during installation (the game download and unpacked assets take ~9 GB, plus engine and prefix overhead).
- If space is low on your internal drive, connect an external SSD and click **Change…** on the welcome screen to set the install root there.

## Steam asks to sign in again every time

Make sure the **Remember me** checkbox is ticked in Steam's Windows login window. Steppe cleanly terminates Steam processes after gameplay to allow Steam Cloud synchronization while preserving your login session inside the isolated Windows prefix.

## The game does not start / app waits at “Waiting for Steam”

- Look for the Steam window: Steam may be updating itself, prompting for Steam Guard, or waiting for you to accept a dialog.
- Open **Settings → Maintenance → Repair…** to re-verify engine hashes, prefix permissions, and helper binaries.
- If you manually moved or renamed your Steppe folder, the internal prefix symlinks will break. Re-select the folder in Settings or run a repair.

## Black units, missing textures or visual artifacts

The Cossacks 3 rendering engine relies on fixed OpenGL profiles. Steppe's `glfix` library shims shader versions and emulates legacy PBuffers with modern Framebuffer Objects (FBOs).
- Verify that *Settings → Advanced → Math patches* is kept OFF (the shipping default).
- Capture frame times via *Settings → Advanced → Record frame times*, play a busy match, quit, and attach `logs/game-session.log` and *Settings → Export Diagnostics* to an issue.

## Low frame rate or stuttering

- Cossacks 3 is a 32-bit x86 game running under Rosetta 2; performance is primarily CPU-bound.
- Switch to the **Balanced** or **Performance** preset in *Settings → Preset*.
- On MacBooks, set Energy Mode to **High Power** (if supported by your model) and ensure your laptop is plugged into power during massive battles.
- If a game session stops responding, click **Force Quit Game** in Steppe, which terminates only Steppe's own Wine processes without affecting other Wine installations.

## Updating the game or Steam

Steam handles all game and client updates automatically. On each launch, Steppe checks `ogg.dll`, `vorbis.dll`, and `vorbisfile.dll`: if Steam restored the verified original DLLs (or if Steppe's own older DLLs are present), Steppe installs its `vorbis-fast` libraries; if a game update introduces unknown modified DLLs, Steppe leaves them untouched so it never overwrites unrecognized game files.

## Complete Uninstall

To completely remove Steppe and reclaim disk space:
1. Open **Settings → Maintenance → Uninstall Everything…**; this cleanly deletes the Wine engine, prefix, Steam, downloaded game files, and caches.
2. Drag `Steppe.app` from *Applications* to the Trash.
3. Your Steam account, purchased games, and Steam Cloud saves remain completely untouched.
