# SPDX-License-Identifier: MIT
# Copyright (c) Steppe contributors
CC = i686-w64-mingw32-gcc
CFLAGS = -O3 -msse2 -mfpmath=sse -march=pentium4 -mtune=generic -fno-math-errno -fomit-frame-pointer
CPPFLAGS = -isystem .cache/libogg-1.3.5/include -isystem .cache/libvorbis-1.3.7/include -I.cache/libvorbis-1.3.7/lib
OGG = .cache/libogg-1.3.5
VORBIS = .cache/libvorbis-1.3.7
VORBIS_NAMES = mdct smallft block envelope window lsp lpc analysis synthesis psy info floor1 floor0 res0 mapping0 registry codebook sharedbook lookup bitrate
VORBIS_SOURCES = $(addprefix $(VORBIS)/lib/,$(addsuffix .c,$(VORBIS_NAMES)))
RENAMES = $(foreach n,clear open_callbacks pcm_total pcm_seek raw_seek time_seek info comment read,-Dov_$(n)=real_ov_$(n))
.PHONY: all sources test clean
all: build/ogg.dll build/vorbis.dll build/vorbisfile.dll
# Validate archives on every invocation, including already cached sources.
sources:
	sh fetch-sources.sh
	@test -d $(OGG) || tar -xzf .cache/libogg-1.3.5.tar.gz -C .cache
	@test -d $(VORBIS) || tar -xzf .cache/libvorbis-1.3.7.tar.gz -C .cache
build:
	mkdir -p $@
build/ogg.dll: ogg_compat.c ogg.def | sources build
	$(CC) $(CFLAGS) $(CPPFLAGS) -shared -s -static-libgcc $(OGG)/src/bitwise.c $(OGG)/src/framing.c ogg_compat.c ogg.def -Wl,--no-insert-timestamp -Wl,--out-implib,build/libogg.dll.a -o $@
build/vorbis.dll: vorbis_compat.c vorbis.def build/ogg.dll | sources
	$(CC) $(CFLAGS) $(CPPFLAGS) -shared -s -static-libgcc $(VORBIS_SOURCES) vorbis_compat.c vorbis.def -Lbuild -logg -lm -Wl,--no-insert-timestamp -Wl,--out-implib,build/libvorbis.dll.a -o $@
build/vorbisfile_real.o: | sources build
	$(CC) $(CFLAGS) $(CPPFLAGS) $(RENAMES) -c $(VORBIS)/lib/vorbisfile.c -o $@
build/vorbisfile.dll: vorbisfile_fast.c game_build.h vorbisfile.def build/vorbisfile_real.o build/vorbis.dll
	$(CC) $(CFLAGS) $(CPPFLAGS) -Wall -Wextra -Werror -shared -s -static-libgcc vorbisfile_fast.c build/vorbisfile_real.o vorbisfile.def -Lbuild -lvorbis -logg -lm -Wl,--no-insert-timestamp -o $@
build/test_vorbis_bench.exe: test_vorbis_bench.c | sources build
	$(CC) $(CFLAGS) $(CPPFLAGS) -Wall -Wextra -Werror $< -Wl,--no-insert-timestamp -o $@
test: all build/test_vorbis_bench.exe
	python3 test_portable.py
	@echo "PASS: Windows benchmark cross-compiled; execution intentionally omitted."
clean:
	rm -rf build
