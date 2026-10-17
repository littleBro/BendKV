#!/bin/sh
# script_bench.sh PORT...: requests per second of scripts and functions
# on each server at PORT (sections 68 and 76 of PERFORMANCE.md), from
# redis-benchmark: 50 clients (CLIENTS), one request at a time and
# pipelined 16 deep, after 100000 random keys are set: GET for scale,
# EVAL "return 1" 0, EVALSHA of it, the scripts that call GET and INCR on
# a random key, and FCALL of a function that returns 1 and of one that
# calls GET on a random key. Prints the test, the depth and each server's
# rate, in the order of the ports, the servers' runs of a test taking
# turns.
CLIENTS=${CLIENTS:-50}
PORTS="$*"
for p in $PORTS; do
  redis-cli -p "$p" flushall > /dev/null
  redis-benchmark -p "$p" -t set -r 100000 -n 200000 -P 16 -q > /dev/null 2>&1
  redis-cli -p "$p" script load "return 1" > /dev/null
  redis-cli -p "$p" function load replace "$(printf '#!lua name=bench\nredis.register_function("one", function() return 1 end)\nredis.register_function("get1", function(keys) return redis.call("get", keys[1]) end)')" > /dev/null
done
SHA=$(printf 'return 1' | sha1sum | cut -d' ' -f1)
rate() {
  p=$1; pipe=$2; shift 2
  n=$((pipe == 1 ? 100000 : 400000))
  redis-benchmark -p "$p" -n $n -c "$CLIENTS" -P "$pipe" -r 100000 -q "$@" 2> /dev/null | tr '\r' '\n' |
    grep -o '[0-9.]* requests per second' | tail -1 | cut -d' ' -f1
}
for pipe in 1 16; do
  for t in get eval1 evalsha1 evalget evalincr fcall1 fcallget; do
    case $t in
      get) set -- get key:__rand_int__ ;;
      eval1) set -- eval "return 1" 0 ;;
      evalsha1) set -- evalsha "$SHA" 0 ;;
      evalget) set -- eval "return redis.call('get', KEYS[1])" 1 key:__rand_int__ ;;
      evalincr) set -- eval "return redis.call('incr', KEYS[1])" 1 counter:__rand_int__ ;;
      fcall1) set -- fcall one 0 ;;
      fcallget) set -- fcall get1 1 key:__rand_int__ ;;
    esac
    line="$t P$pipe"
    for p in $PORTS; do line="$line $(rate "$p" "$pipe" "$@")"; done
    echo "$line"
  done
done
