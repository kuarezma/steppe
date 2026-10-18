// SPDX-License-Identifier: MIT
// Copyright (c) Steppe contributors
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

int main(void) {
    const char *log = getenv("GLFIX_LOG");
    if (log && *log) {
        struct stat target, opened;
        int found = 0;
        if (stat(log, &target)) return 1;
        for (int fd = 0; fd < getdtablesize(); fd++) {
            if (!fstat(fd, &opened) && target.st_dev == opened.st_dev && target.st_ino == opened.st_ino) {
                if (!(fcntl(fd, F_GETFD) & FD_CLOEXEC)) {
                    fprintf(stderr, "FAIL explicit log CLOEXEC: fd=%d\n", fd);
                    return 1;
                }
                found = 1;
            }
        }
        if (!found) return 1;
        puts("PASS explicit log CLOEXEC");
    }
    const char *dyld = getenv("DYLD_INSERT_LIBRARIES");
    printf("CHILD_DYLD=%s\n", dyld ? dyld : "(null)");
    return 0;
}
