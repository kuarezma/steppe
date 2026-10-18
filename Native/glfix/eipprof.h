// SPDX-License-Identifier: MIT
// Copyright (c) Steppe contributors
#ifndef GLFIX_EIPPROF_H
#define GLFIX_EIPPROF_H
void eipprof_init(void);
void eipprof_start(void);
int eipprof_env_key(const char *entry);
int eipprof_build_env(char **env, int count);
void eipprof_ensure_env(void);
#endif
