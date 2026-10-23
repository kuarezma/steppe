# Troubleshooting

First, open **Settings → Export Diagnostics**. It writes a text file with your system, Steppe's state and recent log lines, with personal data removed. Attach it to any bug report.

## macOS says Steppe “cannot be opened”

Steppe is not notarized by Apple. Open **System Settings → Privacy & Security**, scroll down and choose **Open Anyway**. Or install with the script in the README, which clears the quarantine flag.

## The install location shows “Checking the disk…” for a long time

If you picked an external disk, macOS may be showing a permission prompt (“Steppe would like to access files on a removable volume”). Answer it; Steppe continues automatically. If you clicked Don't Allow: *System Settings → Privacy & Security → Files and Folders / Full Disk Access*.

## “Not enough free disk space”

About 16 GB are needed (the game is ~9 GB). Free space or press *Change…* to pick another disk before installing.

## Steam asks me to sign in again every time

Make sure *Remember me* is ticked in Steam's login window. Steppe quits Steam after the game so your Cloud saves sync; the session is kept inside the Windows environment.

## Steam microphone permission does not work

Steppe declares microphone access (`NSMicrophoneUsageDescription` and `com.apple.security.device.audio-input`) and forwards it to the Wine/Steam child processes on your MacBook. If you previously denied microphone access or updated from an earlier ad-hoc build:

- Open **Settings → Game → Microphone access** in Steppe and click **Reset Microphone Permission** (or **Allow Microphone**).
- Or check **System Settings → Privacy & Security → Microphone** and make sure **Steppe** is enabled.

## The game does not start / the app waits at “Waiting for Steam”

- Look at the Steam window; it may need you to sign in, accept an update or confirm an install.
- *Settings → Maintenance → Repair…* re-checks the engine and the Windows environment.
- If you moved or renamed the install folder, set it up again; the Windows environment contains absolute paths.

## The game crashes with “Access violation at address 00427A2B”

This is the fresh-install crash Steppe prevents with its first-run files. If you still see it, a profile folder or `hardware.info` in `Documents/cossacks` (inside the Windows environment) is probably from another setup. Close the game, delete that `cossacks` folder (your cloud saves return from Steam), and press Play again.

The same crash happens when `profile.cfg` names a resolution Windows cannot list as a display mode, for example one planned for the built-in panel while the game runs on an external display. Steppe asks Windows for its modes before every launch and writes only one of them; the log shows `Windows monitor …, writing …`. If that line is missing, `list-modes.exe` could not run: attach *Settings → Export Diagnostics* to an issue.

## Black units, missing textures or a black screen

Please file an issue with diagnostics and your Mac model. *Settings → Advanced → Record frame times* and the log in *Show Logs* help.

## Stutter or low frame rate

- Choose **Performance** (or a custom resolution) in *Settings → Preset*.
- Make sure nothing else heavy is running; on laptops use power mode “High Performance” if available.
- Check Activity Monitor for leftover `wine`/`wineserver` processes after you quit; *Force Quit Game* removes them.

## Updating the game or Steam

Steam updates the game normally. After a game update Steppe re-applies its audio libraries only if the game's originals are unchanged; otherwise it leaves the files alone and the diagnostics say so.

## Uninstall

*Settings → Maintenance → Uninstall Everything…* deletes Steppe's engine, Windows environment, Steam and the game. Then drag Steppe.app to the Trash. Your Steam account and Cloud saves are untouched.
