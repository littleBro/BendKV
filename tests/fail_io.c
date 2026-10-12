// An LD_PRELOAD shim for the append-only file's failure tests
// (tests/aof_fail_test.py). Opening the path in BENDKV_FAIL_OPEN for
// reading fails with EACCES, as a file of mode 0222 does for a user who is
// not root (the tests run as root too, where chmod would not do); opening
// it to append still works. With BENDKV_FAIL_SYNC set, fsync and fdatasync
// of a file fail with EIO, as on a disk that lost the writes; with
// BENDKV_FAIL_DIRSYNC set, those of a directory do (the sync that makes a
// new file's name durable). With BENDKV_TRACE naming a file, each open
// that may make a file (O_CREAT) and each fsync and fdatasync appends a
// line to it, "create", "fsync" or "fdatasync" and the file's absolute
// path, in the order they happen. Everything else passes through.
//
//   cc -shared -fPIC -o build/fail_io.so tests/fail_io.c -ldl
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

static int fails_open(const char* path, int flags) {
  const char* p = getenv("BENDKV_FAIL_OPEN");
  return p != NULL && path != NULL && strcmp(p, path) == 0
    && (flags & O_ACCMODE) == O_RDONLY;
}

static int is_dir(int fd) {
  struct stat st;
  return fstat(fd, &st) == 0 && S_ISDIR(st.st_mode);
}

static int fails_sync(int fd) {
  return getenv(is_dir(fd) ? "BENDKV_FAIL_DIRSYNC" : "BENDKV_FAIL_SYNC") != NULL;
}

static int has_mode(int flags) {
  return (flags & O_CREAT) != 0 || (flags & O_TMPFILE) == O_TMPFILE;
}

// a line in the trace: what was done, and the absolute path of fd (the
// trace file is opened past the wrappers, by the real open)
static void trace(const char* what, int fd) {
  const char* t = getenv("BENDKV_TRACE");
  if (t == NULL || fd < 0) {
    return;
  }
  static int (*real)(const char*, int, ...);
  if (real == NULL) {
    real = dlsym(RTLD_NEXT, "open");
  }
  char at[64];
  char path[PATH_MAX];
  char line[PATH_MAX + 32];
  int  saved = errno;
  snprintf(at, sizeof at, "/proc/self/fd/%d", fd);
  ssize_t n = readlink(at, path, sizeof path - 1);
  path[n < 0 ? 0 : n] = '\0';
  int len = snprintf(line, sizeof line, "%s %s\n", what, path);
  int out = real(t, O_WRONLY | O_CREAT | O_APPEND, 0644);
  if (out >= 0) {
    if (write(out, line, (size_t)len) < 0) {
    }
    close(out);
  }
  errno = saved;
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
    int fd = real(dirfd, path, flags, mode);                       \
    if ((flags & O_CREAT) != 0) {                                  \
      trace("create", fd);                                         \
    }                                                              \
    return fd;                                                     \
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
    int fd = real(path, flags, mode);                              \
    if ((flags & O_CREAT) != 0) {                                  \
      trace("create", fd);                                         \
    }                                                              \
    return fd;                                                     \
  }

OPEN(open)
OPEN(open64)
OPEN_AT(openat, int dirfd)
OPEN_AT(openat64, int dirfd)

#define SYNC(name)                                                 \
  int name(int fd) {                                               \
    static int (*real)(int);                                       \
    trace(#name, fd);                                              \
    if (fails_sync(fd)) {                                          \
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
