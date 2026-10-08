// nothp.c: nothp CMD ARGS... runs CMD with transparent huge pages off for
// it. PR_SET_THP_DISABLE survives execve, so the runtime's
// madvise(MADV_HUGEPAGE) has no effect, and the same binary can be
// measured with and without 2 MiB pages (PERFORMANCE.md, 7.13).
// Build: cc -O2 tools/nothp.c -o build/nothp
#include <stdio.h>
#include <sys/prctl.h>
#include <unistd.h>

int main(int argc, char** argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: nothp CMD ARGS...\n");
    return 2;
  }
  if (prctl(PR_SET_THP_DISABLE, 1, 0, 0, 0) != 0) {
    perror("prctl");
    return 1;
  }
  execv(argv[1], argv + 1);
  perror("execv");
  return 1;
}
