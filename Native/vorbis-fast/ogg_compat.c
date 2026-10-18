// SPDX-License-Identifier: MIT
// Copyright (c) Steppe contributors
#include "ogg/ogg.h"
long oggpack_look_huff(oggpack_buffer *b, int bits) { return oggpack_look(b, bits); }
void oggpack_adv_huff(oggpack_buffer *b, int bits) { oggpack_adv(b, bits); }
