#!/bin/sh
# cc_variants.sh FILE.c OUT: builds one generated C file (bend FILE.bend
# -o FILE.c) several ways, to tell what the C compiler adds from what the
# program does:
#   OUT/c19     clang-19 -O3, as `make build`
#   OUT/c18     clang-18 -O3: it ignores preserve_none
#   OUT/v3      -march=x86-64-v3 (AVX2, BMI2)
#   OUT/native  -march=native
#   OUT/inline  every INLINE helper always_inline
#   OUT/crc     String.hash as CRC32C over 8-byte words, then a mix: a
#               different hash, for measurement only
#   OUT/pgo     with PGO=1: an instrumented build is trained by a
#               redis-benchmark run (SET, GET, INCR and PING over 100k
#               keys, pipeline 16) and rebuilt with its profile
set -e
here=$(cd "$(dirname "$0")" && pwd)
C=$1; OUT=$2
mkdir -p "$OUT"
cc19() { clang-19 -std=c11 -O3 -w "$@" -lpthread -lm; }
cc19 "$C" -o "$OUT/c19"
clang-18 -std=c11 -O3 -w "$C" -lpthread -lm -o "$OUT/c18"
cc19 -march=x86-64-v3 "$C" -o "$OUT/v3"
cc19 -march=native "$C" -o "$OUT/native"
sed 's/^#define INLINE  static inline$/#define INLINE  static inline __attribute__((always_inline))/' \
  "$C" > "$OUT/inline.c"
cc19 "$OUT/inline.c" -o "$OUT/inline"
python3 - "$C" "$OUT/crc.c" <<'EOF'
import sys
src = open(sys.argv[1]).read()
i = src.index("FAR u64 str_hash(u64* H, Term s) {")
j = src.index("\n}\n", i) + 3
crc = '''__attribute__((target("sse4.2"), noinline))
static u64 str_hash(u64* H, Term s) {
  u32    h = 2166136261u;
  StrRun r;
  for (Term t = s; str_run(H, t, &r); t = r.t) {
    if (r.p == NULL) {
      h = __builtin_ia32_crc32qi(h, (u8)r.c);
      continue;
    }
    u32 j = 0;
    for (; j + 8 <= r.n; j += 8) {
      u64 w;
      memcpy(&w, r.p + j, 8);
      h = (u32)__builtin_ia32_crc32di(h, w);
    }
    for (; j < r.n; j += 1) {
      h = __builtin_ia32_crc32qi(h, r.p[j]);
    }
  }
  h ^= h >> 16;
  h *= 0x7feb352du;
  h ^= h >> 15;
  return h;
}
'''
open(sys.argv[2], "w").write(src[:i] + crc + src[j:])
EOF
cc19 "$OUT/crc.c" -o "$OUT/crc"
if [ -n "$PGO" ]; then
  PORT=${PORT:-6697}
  cc -O2 -shared -fPIC "$here/pgo_exit.c" -o "$OUT/pgo_exit.so"
  cc19 -fprofile-instr-generate "$C" -o "$OUT/pgo_gen"
  rm -f "$OUT/pgo.profraw"
  LLVM_PROFILE_FILE="$OUT/pgo.profraw" LD_PRELOAD="$OUT/pgo_exit.so" \
    taskset -c 3 "$OUT/pgo_gen" "$PORT" > /dev/null 2>&1 &
  PID=$!
  for i in $(seq 1 50); do redis-cli -p "$PORT" ping > /dev/null 2>&1 && break; sleep 0.1; done
  taskset -c 1 redis-benchmark -p "$PORT" -t set -r 100000 -n 300000 -c 20 -P 64 -q > /dev/null 2>&1
  for t in get set incr ping_mbulk; do
    taskset -c 1 redis-benchmark -p "$PORT" -t $t -r 100000 -n 400000 -c 20 -P 16 -q > /dev/null 2>&1
  done
  kill -USR2 $PID
  wait $PID 2>/dev/null || true
  llvm-profdata-19 merge -o "$OUT/pgo.profdata" "$OUT/pgo.profraw"
  cc19 -fprofile-instr-use="$OUT/pgo.profdata" "$C" -o "$OUT/pgo"
fi
ls -l "$OUT"
