// sprof.c: a sampling profiler to LD_PRELOAD where the CPU has no PMU: a
// CLOCK_MONOTONIC timer raises SIGPROF every SPROF_US microseconds (the
// process is pinned and busy, so wall time is CPU time), the handler
// records the interrupted PC; on SIGTERM or exit the PCs go to SPROF_OUT
// and the process's maps to SPROF_OUT.maps. With SPROF_WAIT set, sampling
// starts on SIGUSR1. With SPROF_CPU set, the timer is the process's CPU
// time instead (ITIMER_PROF): Linux raises it on the thread that is
// running, so a process of several busy threads is sampled in each, and
// each sample's line also holds the thread's id
#define _GNU_SOURCE
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <ucontext.h>
#include <unistd.h>

static unsigned long* buf;
static unsigned*      tid;
static size_t n;
static size_t cap = 1 << 24;
static int done;
static int cpu;

static void on_prof(int sig, siginfo_t* si, void* uc) {
  (void)sig; (void)si;
  ucontext_t* u = uc;
  size_t i = __atomic_fetch_add(&n, 1, __ATOMIC_RELAXED);
  if (i < cap) {
    buf[i] = (unsigned long)u->uc_mcontext.gregs[REG_RIP];
    tid[i] = (unsigned)syscall(SYS_gettid);
  }
}

static void dump(void) {
  if (done) return;
  done = 1;
  const char* out = getenv("SPROF_OUT");
  if (!out) return;
  FILE* f = fopen(out, "w");
  size_t k = n < cap ? n : cap;
  for (size_t i = 0; i < k; i++) {
    if (cpu) fprintf(f, "%lx %u\n", buf[i], tid[i]);
    else fprintf(f, "%lx\n", buf[i]);
  }
  fclose(f);
  char p[4096];
  snprintf(p, sizeof p, "%s.maps", out);
  FILE* m = fopen("/proc/self/maps", "r");
  FILE* o = fopen(p, "w");
  int c;
  while ((c = fgetc(m)) != EOF) fputc(c, o);
  fclose(m); fclose(o);
}

static timer_t tm;
static struct itimerspec its;

static struct itimerval itv;

static void on_usr1(int sig) {
  (void)sig;
  if (cpu) setitimer(ITIMER_PROF, &itv, NULL);
  else timer_settime(tm, 0, &its, NULL);
}

static void on_term(int sig) {
  (void)sig;
  dump();
  _exit(0);
}

__attribute__((constructor)) static void init(void) {
  const char* us = getenv("SPROF_US");
  long per = us ? atol(us) : 100;
  buf = malloc(cap * sizeof *buf);
  tid = malloc(cap * sizeof *tid);
  cpu = getenv("SPROF_CPU") != NULL;
  itv.it_interval.tv_usec = per;
  itv.it_value.tv_usec = per;
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_sigaction = on_prof;
  sa.sa_flags = SA_SIGINFO | SA_RESTART;
  sigaction(SIGPROF, &sa, NULL);
  signal(SIGTERM, on_term);
  struct sigevent ev;
  memset(&ev, 0, sizeof ev);
  ev.sigev_notify = SIGEV_SIGNAL;
  ev.sigev_signo = SIGPROF;
  timer_create(CLOCK_MONOTONIC, &ev, &tm);
  its.it_interval.tv_nsec = per * 1000;
  its.it_value.tv_nsec = per * 1000;
  if (getenv("SPROF_WAIT")) {
    signal(SIGUSR1, on_usr1);
  } else {
    on_usr1(0);
  }
  atexit(dump);
}
