# SPDX-License-Identifier: MIT
# Copyright (c) Steppe contributors
CC = clang
CFLAGS = -arch x86_64 -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.0
FRAMEWORKS = -framework OpenGL -framework AppKit -framework Carbon
SOURCES = glfix.c pbemu.c cmdfilter.m
.PHONY: all debug test clean
all: build/libglfix.dylib
build:
	mkdir -p $@
build/libglfix.dylib: $(SOURCES) frametimes.h | build
	$(CC) $(CFLAGS) -dynamiclib $(SOURCES) $(FRAMEWORKS) -o $@
debug: build/libglfix_debug.dylib
build/libglfix_debug.dylib: $(SOURCES) eipprof.c eipprof.h frametimes.h | build
	$(CC) $(CFLAGS) -DGLFIX_EIPPROF_BUILD -dynamiclib $(SOURCES) eipprof.c $(FRAMEWORKS) -o $@
test: all
	bash test_glfix.sh
clean:
	rm -rf build
