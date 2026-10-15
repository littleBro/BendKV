#!/bin/sh
# perf_guard.sh [SERVER]: `make perfcheck`. Instructions per request of
# SERVER (build/bendkv) for GET, SET and INCR, counted under callgrind by
# tools/callgrind_req.sh, against tools/perf_baseline.txt; fails when one
# is more than TOL percent (3) above its baseline. The count is
# deterministic to ~0.05%, so a change in it is a change in the code: a
# new call site, for one, can change how the compiler passes an argument
# to a hot function and add reference counting to every request. The
# server sends from its loop (no writer thread, whose spinning would add
# noise). The baseline is CI's count (the perfcheck job: Ubuntu 24.04's
# clang 19, the patches of bend-patches/), where one build has counted up
# to 3.4% apart from one run to the next (GET 3,312 and 3,425 for patch
# 32's, which counts 3,310 to 3,313 locally), and a local count about 1%
# below; after a deliberate change, rewrite it from the job's output (or
# with UPDATE=1), a count in the middle of those CI has seen. Then GET
# and SET are counted again with 100 clients waiting in BLPOP on keys of
# their own (callgrind_req.sh's IDLE), which no request touches; it fails
# when one is more than IDLE_TOL percent (5) above its count without them
# in the same run (server.bend's Heeded keys: a client that waits costs
# nothing to the commands on other keys). The CPU of the machine that
# counted is printed after the counts.
set -e
here=$(cd "$(dirname "$0")" && pwd)
SERVER=${1:-build/bendkv}
TOL=${TOL:-3}
IDLE_TOL=${IDLE_TOL:-5}
PORT=${PORT:-6852}
BASE=$here/perf_baseline.txt
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
TESTS="get set incr" sh "$here/callgrind_req.sh" "$W/pg" "$PORT" "$SERVER" "$PORT" send > "$W/out.txt" 2> "$W/err.txt"
if [ -n "$UPDATE" ]; then
  awk '{print $1, $3}' "$W/out.txt" > "$BASE"
  echo "baseline written:"
  cat "$BASE"
  exit 0
fi
IDLE="blpop 100" TESTS="get set" sh "$here/callgrind_req.sh" "$W/pi" "$PORT" "$SERVER" "$PORT" send > "$W/idle.txt" 2> "$W/err2.txt"
st=0
awk -v tol="$TOL" '
  FNR == NR { base[$1] = $2; next }
  { t = $1; ir = $3; b = base[t]
    pct = b > 0 ? 100 * (ir - b) / b : 0
    bad = pct > tol
    printf "%-5s %6d instructions per request (baseline %d, %+.1f%%)%s\n", t, ir, b, pct, bad ? "  REGRESSION" : ""
    if (bad) fail = 1 }
  END { exit fail }' "$BASE" "$W/out.txt" || st=$?
awk -v tol="$IDLE_TOL" '
  FNR == NR { plain[$1] = $3; next }
  { t = $1; ir = $3; b = plain[t]
    pct = b > 0 ? 100 * (ir - b) / b : 0
    bad = b == 0 || pct > tol
    printf "%-5s %6d instructions per request with 100 clients in BLPOP (without them %d, %+.1f%%)%s\n", t, ir, b, pct, bad ? "  REGRESSION" : ""
    if (bad) fail = 1 }
  END { exit fail }' "$W/out.txt" "$W/idle.txt" || st=$?
sed -n 's/^model name[^:]*: */cpu: /p' /proc/cpuinfo 2>/dev/null | head -n 1
exit $st
