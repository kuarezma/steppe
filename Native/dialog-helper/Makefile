# SPDX-License-Identifier: MIT
# Copyright (c) Steppe contributors
CC = i686-w64-mingw32-gcc
.PHONY: all test clean
all: build/dismiss-dialog.exe build/list-modes.exe
build/dismiss-dialog.exe: dismiss_dialog.c
	mkdir -p build
	$(CC) -O2 -s -mwindows -Wall -Wextra -Werror -Wl,--no-insert-timestamp -o $@ $< -luser32
# Console program: Steppe reads its stdout.
build/list-modes.exe: list_modes.c
	mkdir -p build
	$(CC) -O2 -s -Wall -Wextra -Werror -Wl,--no-insert-timestamp -o $@ $< -luser32
test: all
	python3 test_portable.py
clean:
	rm -rf build
