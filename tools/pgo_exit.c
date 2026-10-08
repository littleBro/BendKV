// pgo_exit.c: LD_PRELOAD shim for PGO training (tools/cc_variants.sh).
// SIGUSR2 exits the process normally, so the profile runtime of an
// instrumented server writes its counters at exit; a server killed by a
// signal would write nothing.
#include <signal.h>
#include <stdlib.h>

static void bye(int s) {
  (void)s;
  exit(0);
}

__attribute__((constructor)) static void init(void) {
  signal(SIGUSR2, bye);
}
