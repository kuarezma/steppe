<!-- SPDX-License-Identifier: MIT -->
<!-- Copyright (c) Steppe contributors -->
# glfix

An x86_64 macOS interposer for Cossacks 3 under Wine and Rosetta. It emulates
CGL pbuffers with framebuffer objects, repairs shader compatibility and bone
uniform locations, and filters Command-key presses that can leave Wine stuck.
It propagates its own injection through Wine child processes.

```sh
make
make test
make debug
make clean
```

Requires macOS 14 or later and Apple command-line developer tools. Production
output is `build/libglfix.dylib`; load it with `DYLD_INSERT_LIBRARIES` set to its
absolute location. `make debug` additionally produces `build/libglfix_debug.dylib`.
The production library contains no instruction-pointer sampler.

| Environment variable | Meaning |
| --- | --- |
| `GLFIX_REMAP=2` | Recommended game mode: pbuffer/shader/bone fixes and injection propagation; no stride remapping. |
| `GLFIX_REMAP=1` | Also enable matrix-array stride remapping, used by the native uniform tests. |
| `GLFIX_REMAP` unset or `0` | Disable stride remapping and injection propagation; pbuffer/shader hooks remain installed. |
| `GLFIX_LOG=<path>` | Opt into a bounded diagnostic log appended to this file. |
| `GLFIX_FRAMETIMES=<prefix>` | Opt into buffered monotonic color-clear timestamps in `<prefix>.<pid>`; existing files are never overwritten. These are clear events, not verified display presentation times. |
| `GLFIX_CMDFILTER=0` | Disable the Command-key event filter (enabled by default). |
| `GLFIX_BUSHTEST=off` | Disable the default zero-normal foliage guard. `nanguard` or unset enables it; experimental shader modes have been removed. |

Without the two logging variables, production performs no explicit file I/O and
collects no timing samples, matrix audit data, or diagnostic counters. Config-file,
shader-dump, texture/draw probes and FPS/call-count diagnostics have been removed.
The hooks still have their normal compatibility and environment-propagation cost.

Debug only: set `GLFIX_EIPPROF=1`, `GLFIX_EIPPROF_START=<trigger>` and
`GLFIX_EIPPROF_OUT=<output>`. The trigger must contain the process ID. Sampling
starts after the first color clear, waits for that ID, then samples for 20 seconds.
The debug sampler reads the trigger and writes its output only when explicitly enabled.

Tests compile with warnings treated as errors. Buffering/thread/fork and injection
propagation tests run without GL. Rendering and pbuffer tests require an accelerated
GL context; an unavailable context is reported as `SKIP`, never as a rendering pass.
Set `GLFIX_REFERENCE_DYLIB` to an existing reference library to compare native
mode-2 pbuffer and uniform-validator output when a GL context is available.
No test launches Wine or the game. `test_eipprof` is built but its 22-second live
sampling scenario is optional and is not run by `make test`.

## Known limitations

`CGLDestroyContext` is not intercepted, so the pbuffer association table can retain
a stale context pointer after destruction. The exec hooks in `glfix.c` use `setenv`
to propagate injection settings; that environment mutation is not safe against
concurrent environment access. These lifecycle and exec-hook changes are outside
the scope of this fix.
