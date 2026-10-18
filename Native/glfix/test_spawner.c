// SPDX-License-Identifier: MIT
// Copyright (c) Steppe contributors
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <spawn.h>
#include <sys/wait.h>
#include <string.h>

int run_child(const char *child_path, char *const envp[], char *out_buf, size_t out_sz) {
    int pipefd[2];
    if (pipe(pipefd) != 0) return -1;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipefd[0]);

    char *const argv[] = { (char *)child_path, NULL };
    pid_t pid;
    int r = posix_spawn(&pid, child_path, &actions, NULL, argv, envp);
    close(pipefd[1]);
    posix_spawn_file_actions_destroy(&actions);

    if (r != 0) {
        close(pipefd[0]);
        return -1;
    }
    ssize_t n = read(pipefd[0], out_buf, out_sz - 1);
    close(pipefd[0]);
    if (n >= 0) out_buf[n] = '\0';
    int status = 0;
    waitpid(pid, &status, 0);
    return WEXITSTATUS(status);
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <child_path> <mode: clean | merge | dup> [dummy_lib_path]\n", argv[0]);
        return 1;
    }
    const char *child_path = argv[1];
    const char *mode = argv[2];
    const char *dummy_lib = (argc >= 4) ? argv[3] : "build/libdummy.dylib";

    char out[2048] = {0};
    if (!strcmp(mode, "clean")) {
        char *envp[] = { "PORT=test", NULL };
        int rc = run_child(child_path, envp, out, sizeof(out));
        printf("RC=%d %s", rc, out);
    } else if (!strcmp(mode, "merge")) {
        char env_dyld[1024];
        snprintf(env_dyld, sizeof(env_dyld), "DYLD_INSERT_LIBRARIES=%s", dummy_lib);
        char *envp[] = { env_dyld, "PORT=test", NULL };
        int rc = run_child(child_path, envp, out, sizeof(out));
        printf("RC=%d %s", rc, out);
    } else if (!strcmp(mode, "dup")) {
        char env_dyld[2048];
        const char *cur = getenv("DYLD_INSERT_LIBRARIES");
        snprintf(env_dyld, sizeof(env_dyld), "DYLD_INSERT_LIBRARIES=%s:%s", dummy_lib, cur ? cur : "");
        char *envp[] = { env_dyld, "PORT=test", NULL };
        int rc = run_child(child_path, envp, out, sizeof(out));
        printf("RC=%d %s", rc, out);
    }
    return 0;
}
