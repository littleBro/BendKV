// iocount.c: counts a server's IO calls as an LD_PRELOAD shim: recv (and
// how many of them found nothing, EAGAIN), send, select, epoll_wait (and how
// many returned nothing), write, read, poll and pthread_cond_signal. kill
// -USR1 resets the counts, kill -USR2 writes them to $IOCOUNT_OUT
// (iocount.out). Divided by the requests served in between, they give the
// calls per request of PERFORMANCE.md, section 7.17.
//
//   cc -O2 -shared -fPIC -o iocount.so tools/iocount.c -ldl
//   IOCOUNT_OUT=calls.txt LD_PRELOAD=./iocount.so build/bendkv 6380 &
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

enum { C_RECV, C_AGAIN, C_SEND, C_SELECT, C_EPOLL, C_EZERO, C_WRITE, C_READ, C_POLL, C_SIG, C_N };
static const char* names[C_N] = { "recv", "recv_eagain", "send", "select", "epoll_wait",
  "epoll_wait_none", "write", "read", "poll", "cond_signal" };
static _Atomic unsigned long cnt[C_N];

#define REAL(name, ret, ...) \
  static ret (*real)(__VA_ARGS__); \
  if (real == NULL) real = (ret (*)(__VA_ARGS__))dlsym(RTLD_NEXT, name)

ssize_t recv(int fd, void* b, size_t n, int f) {
  REAL("recv", ssize_t, int, void*, size_t, int);
  ssize_t r = real(fd, b, n, f);
  int e = errno;
  cnt[C_RECV]++;
  if (r < 0 && (e == EAGAIN || e == EWOULDBLOCK)) cnt[C_AGAIN]++;
  errno = e;
  return r;
}

ssize_t send(int fd, const void* b, size_t n, int f) {
  REAL("send", ssize_t, int, const void*, size_t, int);
  cnt[C_SEND]++;
  return real(fd, b, n, f);
}

int select(int n, fd_set* r, fd_set* w, fd_set* x, struct timeval* t) {
  REAL("select", int, int, fd_set*, fd_set*, fd_set*, struct timeval*);
  cnt[C_SELECT]++;
  return real(n, r, w, x, t);
}

int epoll_wait(int ep, struct epoll_event* ev, int m, int t) {
  REAL("epoll_wait", int, int, struct epoll_event*, int, int);
  int r = real(ep, ev, m, t);
  int e = errno;
  cnt[C_EPOLL]++;
  if (r == 0) cnt[C_EZERO]++;
  errno = e;
  return r;
}

ssize_t write(int fd, const void* b, size_t n) {
  REAL("write", ssize_t, int, const void*, size_t);
  cnt[C_WRITE]++;
  return real(fd, b, n);
}

ssize_t read(int fd, void* b, size_t n) {
  REAL("read", ssize_t, int, void*, size_t);
  cnt[C_READ]++;
  return real(fd, b, n);
}

int poll(struct pollfd* p, nfds_t n, int t) {
  REAL("poll", int, struct pollfd*, nfds_t, int);
  cnt[C_POLL]++;
  return real(p, n, t);
}

int pthread_cond_signal(pthread_cond_t* c) {
  static int (*real)(pthread_cond_t*);
  if (real == NULL) real = (int (*)(pthread_cond_t*))dlvsym(RTLD_NEXT, "pthread_cond_signal", "GLIBC_2.3.2");
  cnt[C_SIG]++;
  return real(c);
}

static void on_reset(int s) {
  (void)s;
  for (int i = 0; i < C_N; i++) cnt[i] = 0;
}

static void on_dump(int s) {
  (void)s;
  const char* p = getenv("IOCOUNT_OUT");
  FILE* f = fopen(p ? p : "iocount.out", "w");
  for (int i = 0; i < C_N; i++) fprintf(f, "%s %lu\n", names[i], (unsigned long)cnt[i]);
  fclose(f);
}

static void __attribute__((constructor)) iocount_init(void) {
  signal(SIGUSR1, on_reset);
  signal(SIGUSR2, on_dump);
}
