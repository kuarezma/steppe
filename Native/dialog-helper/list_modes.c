// SPDX-License-Identifier: MIT
// Copyright (c) Steppe contributors
//
// Prints the display modes Windows programs in the prefix can enumerate. Cossacks 3 looks its
// configured resolution up among these and crashes (null write at 00427A2B) when it is missing, so
// Steppe writes only a resolution from this list. Wine's monitor can differ from the Mac screen
// Steppe's window is on (external display, clamshell), which is why this asks Windows itself.
//
// Output on stdout: "current W H" for the primary monitor, then one "mode W H" line per mode.
// Exit codes: 0 = listed, 1 = the current mode could not be read.
#include <windows.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    DEVMODEA mode;
    memset(&mode, 0, sizeof mode);
    mode.dmSize = sizeof mode;
    if (!EnumDisplaySettingsA(NULL, ENUM_CURRENT_SETTINGS, &mode)) return 1;
    printf("current %lu %lu\n", mode.dmPelsWidth, mode.dmPelsHeight);
    for (DWORD i = 0;; i++) {
        memset(&mode, 0, sizeof mode);
        mode.dmSize = sizeof mode;
        if (!EnumDisplaySettingsA(NULL, i, &mode)) break;
        printf("mode %lu %lu\n", mode.dmPelsWidth, mode.dmPelsHeight);
    }
    fflush(stdout);
    return 0;
}
