#!/bin/sh
# perf_guard.sh [SERVER]: `make perfcheck`. Instructions per request of
# SERVER (build/bendkv) for GET, SET and INCR, counted under callgrind by
# tools/callgrind_req.sh, against tools/perf_baseline.txt; fails when one
# is more than TOL percent (3) above its baseline. The count is
# deterministic to ~0.05%, so a change in it is a change in the code: a
# new call site, for one, can change how the compiler passes an argument
# to a hot function and add reference counting to every request. The
# server runs one shard and sends from its loop (no writer thread, whose
# spinning would add noise). The baseline holds for one toolchain (clang
# 19, the patches of bend-patches/); after a deliberate change, rewrite
# it with UPDATE=1.
set -e
here=$(cd "$(dirname "$0")" && pwd)
SERVER=${1:-build/bendkv}
TOL=${TOL:-3}
PORT=${PORT:-6852}
BASE=$here/perf_baseline.txt
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
TESTS="get set incr" sh "$here/callgrind_req.sh" "$W/pg" "$PORT" "$SERVER" "$PORT" 1 send > "$W/out.txt" 2> "$W/err.txt"
if [ -n "$UPDATE" ]; then
  awk '{print $1, $3}' "$W/out.txt" > "$BASE"
  echo "baseline written:"
  cat "$BASE"
  exit 0
fi
awk -v tol="$TOL" '
  FNR == NR { base[$1] = $2; next }
  { t = $1; ir = $3; b = base[t]
    pct = b > 0 ? 100 * (ir - b) / b : 0
    bad = pct > tol
    printf "%-5s %6d instructions per request (baseline %d, %+.1f%%)%s\n", t, ir, b, pct, bad ? "  REGRESSION" : ""
    if (bad) fail = 1 }
  END { exit fail }' "$BASE" "$W/out.txt"
