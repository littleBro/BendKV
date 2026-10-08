// An LD_PRELOAD shim for the append-only file's failure tests
// (tests/aof_fail_test.py). Opening the path in BENDKV_FAIL_OPEN for
// reading fails with EACCES, as a file of mode 0222 does for a user who is
// not root (the tests run as root too, where chmod would not do); opening
// it to append still works. With BENDKV_FAIL_SYNC set, fsync and fdatasync
// fail with EIO, as on a disk that lost the writes. Everything else passes
// through.
//
//   cc -shared -fPIC -o build/fail_io.so tests/fail_io.c -ldl
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

static int fails_open(const char* path, int flags) {
  const char* p = getenv("BENDKV_FAIL_OPEN");
  return p != NULL && path != NULL && strcmp(p, path) == 0
    && (flags & O_ACCMODE) == O_RDONLY;
}

static int fails_sync(void) {
  return getenv("BENDKV_FAIL_SYNC") != NULL;
}

static int has_mode(int flags) {
  return (flags & O_CREAT) != 0 || (flags & O_TMPFILE) == O_TMPFILE;
}

#define OPEN_AT(name, ...)                                         \
  int name(__VA_ARGS__, const char* path, int flags, ...) {        \
    static int (*real)(__VA_ARGS__, const char*, int, ...);        \
    mode_t mode = 0;                                               \
    if (has_mode(flags)) {                                         \
      va_list ap;                                                  \
      va_start(ap, flags);                                         \
      mode = va_arg(ap, mode_t);                                   \
      va_end(ap);                                                  \
    }                                                              \
    if (fails_open(path, flags)) {                                 \
      errno = EACCES;                                              \
      return -1;                                                   \
    }                                                              \
    if (real == NULL) {                                            \
      real = dlsym(RTLD_NEXT, #name);                              \
    }                                                              \
    return real(dirfd, path, flags, mode);                         \
  }

#define OPEN(name)                                                 \
  int name(const char* path, int flags, ...) {                     \
    static int (*real)(const char*, int, ...);                     \
    mode_t mode = 0;                                               \
    if (has_mode(flags)) {                                         \
      va_list ap;                                                  \
      va_start(ap, flags);                                         \
      mode = va_arg(ap, mode_t);                                   \
      va_end(ap);                                                  \
    }                                                              \
    if (fails_open(path, flags)) {                                 \
      errno = EACCES;                                              \
      return -1;                                                   \
    }                                                              \
    if (real == NULL) {                                            \
      real = dlsym(RTLD_NEXT, #name);                              \
    }                                                              \
    return real(path, flags, mode);                                \
  }

OPEN(open)
OPEN(open64)
OPEN_AT(openat, int dirfd)
OPEN_AT(openat64, int dirfd)

#define SYNC(name)                                                 \
  int name(int fd) {                                               \
    static int (*real)(int);                                       \
    if (fails_sync()) {                                            \
      errno = EIO;                                                 \
      return -1;                                                   \
    }                                                              \
    if (real == NULL) {                                            \
      real = dlsym(RTLD_NEXT, #name);                              \
    }                                                              \
    return real(fd);                                               \
  }

SYNC(fsync)
SYNC(fdatasync)
