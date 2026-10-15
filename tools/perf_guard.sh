#!/bin/sh
# perf_guard.sh [SERVER]: `make perfcheck`. Per request of SERVER
# (build/bendkv) for GET, SET and INCR, counted under callgrind by
# tools/callgrind_req.sh: instructions, last-level data read misses (a
# 2 MiB last level, and L1 caches of 32 KiB whatever the machine's), and
# the server's software prefetches (its prefetch instructions that ran).
# Against tools/perf_baseline.txt, it fails when the instructions are more
# than TOL percent (3) above or below their baseline (a count that falls
# is a change too: work lost, as hints the compiler drops, or a baseline
# left behind), when the misses are more than MTOL percent (10) off
# theirs, or the prefetches more than PTOL percent (5) off theirs.
# callgrind's caches do not see a prefetch (valgrind decodes one as no
# access), so a prefetch lost shows only in the count of prefetches: it
# saves a few dozen instructions and no miss (FINDINGS.md 3zzt). The
# misses and prefetches in the baseline were counted locally (clang 19;
# within 1.5% and 0.3% over six runs), the instructions in CI. The count is
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
MTOL=${MTOL:-10}
PTOL=${PTOL:-5}
IDLE_TOL=${IDLE_TOL:-5}
PORT=${PORT:-6852}
BASE=$here/perf_baseline.txt
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
CG_FLAGS="--dump-instr=yes --I1=32768,8,64 --D1=32768,8,64" TESTS="get set incr" \
  sh "$here/callgrind_req.sh" "$W/pg" "$PORT" "$SERVER" "$PORT" send > "$W/out.txt" 2> "$W/err.txt"
# the server's prefetches per request of each test, from its dump's counts
# per instruction ("positions: instr line", Ir first; the cost on the line
# after calls= is the call's, not its instruction's) at the addresses of
# the server's prefetch instructions (objdump); 20,000 requests a dump
python3 - "$SERVER" "$W"/pg.cg.* > "$W/pf.txt" <<'EOF'
import os, re, subprocess, sys
server = os.path.realpath(sys.argv[1])
asm = subprocess.run(["objdump", "-d", "--no-show-raw-insn", server],
                     capture_output=True, text=True, check=True).stdout
pf = {int(m.group(1), 16) for m in re.finditer(r"^ *([0-9a-f]+):\s+prefetch", asm, re.M)}
for dump in filter(os.path.exists, sys.argv[2:]):
    test, names, mine, addr, call, n = None, {}, False, 0, False, 0
    for line in open(dump, errors="replace"):
        if line[:1] in "0123456789+-*":
            tok = line.split()
            if tok[0].startswith("0x"):
                addr = int(tok[0], 16)
            elif tok[0][0] in "+-":
                addr += int(tok[0])
            elif tok[0] != "*":
                addr = int(tok[0])
            if call:
                call = False
            elif mine and addr in pf and len(tok) > 2:
                n += int(tok[2])
        elif line.startswith(("ob=", "cob=")):
            m = re.match(r"c?ob=\((\d+)\)(?: (.*))?", line.rstrip("\n"))
            if m.group(2) is not None:
                names[m.group(1)] = os.path.realpath(m.group(2))
            if line.startswith("ob="):
                mine = names.get(m.group(1)) == server
        elif line.startswith("calls="):
            call = True
        elif line.startswith("positions:") and line.split()[1:] != ["instr", "line"]:
            sys.exit("perf_guard.sh: %s has no counts per instruction" % dump)
        elif test is None and re.search(r"dump [a-z_]+", line):
            test = re.search(r"dump ([a-z_]+)", line).group(1)
    if test:
        print(test, n / 20000)
EOF
# a line per test: its name, instructions, misses and prefetches (a test
# with no counts fails the guard)
awk 'FNR == NR { pf[$1] = $2; next } { print $1, $3, $7, ($1 in pf) ? pf[$1] : -1 }' "$W/pf.txt" "$W/out.txt" > "$W/now.txt"
if [ "$(wc -l < "$W/now.txt")" -ne 3 ]; then
  echo "perf_guard.sh: no counts for GET, SET and INCR" >&2
  cat "$W/err.txt" "$W/out.txt" >&2
  exit 1
fi
if [ -n "$UPDATE" ]; then
  awk '{ print $1, $2; m = m sprintf("%s.misses %.2f\n", $1, $3); p = p sprintf("%s.prefetches %.2f\n", $1, $4) }
       END { printf "%s%s", m, p }' "$W/now.txt" > "$BASE"
  echo "baseline written:"
  cat "$BASE"
  exit 0
fi
IDLE="blpop 100" TESTS="get set" sh "$here/callgrind_req.sh" "$W/pi" "$PORT" "$SERVER" "$PORT" send > "$W/idle.txt" 2> "$W/err2.txt"
st=0
awk -v tol="$TOL" -v mtol="$MTOL" -v ptol="$PTOL" '
  function pct(x, b) { return b > 0 ? 100 * (x - b) / b : 0 }
  FNR == NR { base[$1] = $2; next }
  { t = $1; ir = $2; b = base[t]; p = pct(ir, b)
    bad = p > tol ? "  REGRESSION" : p < -tol ? "  BELOW THE BASELINE: work lost, or a baseline to rewrite" : ""
    printf "%-5s %6d instructions per request (baseline %d, %+.1f%%)%s\n", t, ir, b, p, bad
    if (bad != "") fail = 1
    if ((t ".misses") in base) {
      b = base[t ".misses"]; p = pct($3, b)
      bad = p > mtol ? "  MORE MISSES" : p < -mtol ? "  FEWER MISSES: rewrite the baseline" : ""
      printf "      %6.2f last-level misses (baseline %.2f, %+.1f%%)%s\n", $3, b, p, bad
      if (bad != "") fail = 1
    }
    if ((t ".prefetches") in base) {
      b = base[t ".prefetches"]; p = pct($4, b)
      bad = p < -ptol ? "  PREFETCHES LOST" : p > ptol ? "  MORE PREFETCHES: rewrite the baseline" : ""
      printf "      %6.2f prefetches (baseline %.2f, %+.1f%%)%s\n", $4, b, p, bad
      if (bad != "") fail = 1
    } }
  END { exit fail }' "$BASE" "$W/now.txt" || st=$?
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
