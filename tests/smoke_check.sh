#!/bin/sh
# smoke_check.sh SMOKE_JS AOF_CHECK_JS STREAM_CHECK_JS: runs the pure
# checks, tests/smoke.bend, tests/aof_check.bend and
# tests/stream_check.bend built for bun (make smoke builds them), which
# must pass (exit 0); then each again with one kind
# of its checks given a wrong expectation (BENDKV_CHECK_BREAK), which must
# fail it (exit 1) with the line that names the failure: a check that
# cannot fail the run would let a regression through green.
set -e
smoke=$1
aof=$2
stream=$3
out=build/smoke_check.out
bun "$smoke"
bun "$aof"
bun "$stream"
fails() {
  set +e
  BENDKV_CHECK_BREAK=$2 bun "$1" > "$out" 2>&1
  code=$?
  set -e
  if [ "$code" -ne 1 ]; then
    echo "FAIL: $1 with BENDKV_CHECK_BREAK=$2 exits $code, not 1"
    exit 1
  fi
  if ! grep -aqF "$3" "$out"; then
    echo "FAIL: $1 with BENDKV_CHECK_BREAK=$2 does not say: $3"
    exit 1
  fi
  echo "OK: with BENDKV_CHECK_BREAK=$2, $1 exits 1: $3"
}
fails "$smoke" smoke "FAIL line 1: got +OK"
fails "$aof" log "exec_log's database is exec_all's: differ"
fails "$aof" db "replayed database: differ"
fails "$aof" cut "cut at 0 fails"
fails "$aof" check "the start refuses an unknown command: differ"
fails "$aof" win "the start reads the file in windows as whole: differ"
fails "$stream" head "FAIL stream heads"
fails "$stream" walk "FAIL stream walks"
