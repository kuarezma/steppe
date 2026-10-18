# Compatibility reports

Steppe was developed on one machine. Reports from other Macs make this table useful, so please open an issue with the **Compatibility report** template (or a pull request) after a play session of at least 15 minutes.

| Mac | macOS | Steppe | Preset | Display | Result | Frame times | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Apple M3, 16 GB | 27.0.1 | 0.1.0 | Balanced (1838×1034) | external, scaled 2560×1440 | Install, first run, menu and in‑game rendering verified | median ~35 ms (earlier build with math patches on), re-measurement pending | Multiplayer not tested |

How to measure: *Settings → Advanced → Record frame times*, play a busy scene, quit; the file `logs/frames.ns.<pid>` in the Steppe folder holds one monotonic timestamp per rendered frame (see `Native/glfix/README.md`); differences between consecutive lines are the frame times.
