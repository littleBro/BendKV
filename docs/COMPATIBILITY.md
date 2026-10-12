# BendKV against Redis's own test suite

Redis keeps its tests next to its code (`tests/`, run by `./runtest`), and the suite can
run against a server it did not start: given `--host` and `--port`, it leaves out the
tests tagged `external:skip`, those that start servers of their own, and runs the rest
against the server it is pointed at. Redis has options for that mode meant for servers
that are compatible without being Redis: `--singledb` uses database 0 alone,
`--ignore-encoding` skips the checks of Redis's internal encodings (listpack, intset,
quicklist), `--ignore-digest` the checks with `DEBUG DIGEST`
([tests/README.md](https://github.com/redis/redis/blob/7.0.15/tests/README.md)). BendKV
has Redis's 16 databases, so it runs without `--singledb`: the suite keeps its keys in
database 9 and uses the others for the tests of SELECT, MOVE and SWAPDB. It is the
measure of BendKV as a drop-in replacement for one Redis node.

## How it runs

`tools/redis_suite.py` runs each unit of `tests/unit` and `tests/unit/type` of a Redis
7.0.15 source tree in that mode, with `--ignore-encoding --ignore-digest --durable`
(`--durable`: a test that ends in an error counts as failed and the unit goes
on; an error between tests still ends the unit). Three instances of the server under
test take one unit at a time each, each in a directory of its own; an instance that
stops answering is started again. Before each group of tests the suite empties the
server (FLUSHALL, FUNCTION FLUSH) and sets the parameters the group asks for with
CONFIG SET.

The same run against `redis-server` 7.0.15 in its default configuration is the
reference: a test counts only if Redis passes it. 78 of the 1,751 tests that run in this
mode fail on Redis itself, nearly all of them because they use `DEBUG`, which Redis 7.0
refuses unless `enable-debug-command` is set at its start.

```bash
make suite REDIS_SRC=../redis      # both runs and the table, in build/suite/
```

## The result

Redis 7.0.15, October 2026. Of the 1,673 tests Redis passes in this mode, BendKV passes
**285 (17.0%)**; of the 370 in the units of what BendKV has, 261 (71%). Times to live
(EXPIRE and its kin, TTL and PTTL, SET's options, GETEX, GETDEL) and the sweep of
expired keys brought 78 of them: unit/expire passes 56 of its 59 tests (the other 3 need
replication and LPUSH). Ranges and bits (GETRANGE, SETRANGE, GETBIT, SETBIT,
BITCOUNT, BITPOS) brought 49: unit/bitops passes 30 of its 45 tests (the rest need
BITOP, BITFIELD or lists). TOUCH, TIME and OBJECT brought 4 (TOUCH's two in
unit/introspection-2, a PEXPIREAT at a time TIME gave, and INCR's shared integers seen
by OBJECT REFCOUNT); one test more now fails on what BendKV does not keep, rather than
on a missing command: OBJECT IDLETIME is 0, where the test waits three seconds for it.
MSETNX, RENAME and RENAMENX brought 13: unit/type/string passes 65 of its 77 tests (the
rest need LCS, other types, or replication), unit/keyspace 35 of 52 (the rest need COPY,
other types, or DEBUG).
Several databases brought 6 of the 17 tests
Redis passes that run only without `--singledb`: SET and GET in different databases, DEL in database
1, and four of MOVE's five (against a key the target holds, against a database that is no
integer, with a time and without one). The fifth, MOVE's basic usage, passes alone but
counts a key that earlier tests left in the unit: the test before it, which would remove
them with FLUSHDB, stops at XADD. The other 10 need COPY, MULTI and WATCH, Lua or lists.

| area | units | Redis passes | BendKV passes |
|---|---|---:|---:|
| what BendKV has: the protocol, connections, the keyspace and its databases, strings and their ranges and bits, counters, times to live, introspection | protocol, quit, keyspace, type/string, type/incr, bitops, expire, introspection, introspection-2, other, info-command | 370 | **261** |
| data types, not yet | type/hash, type/list, list-2, list-3, type/set, type/zset, geo, hyperloglog, bitfield, sort, scan, dump, lazyfree, violations | 866 | 20 |
| transactions, pub/sub, client-side caching, CLIENT PAUSE, the latency monitor, the slow log, the query buffer, not yet | multi, pubsub, tracking, pause, latency-monitor, slowlog, querybuf | 131 | 0 |
| out of scope: Lua scripts, functions, streams | scripting, functions, type/stream, type/stream-cgroups | 306 | 4 |

Of the 24 passes outside the first row, 5 are the tests of SCAN in unit/scan, all of
them (the unit's other 12 scan sets, hashes and sorted sets: SSCAN, HSCAN, ZSCAN). Most
of the others pass without the feature they test: they expect an error and take
BendKV's "unknown command" for one, or catch every error and only check that the server
still answers.

By unit (units where every test needs a server of its own are left out: acl, acl-v2,
aofrw, auth, client-eviction, cluster, cluster-scripting, info, limits, maxmemory,
memefficiency, networking, obuf-limits, oom-score-adj, pendingquerybuf, printver,
pubsubshard, shutdown, tls, type/list-common, wait):

| unit | tests | Redis passes | BendKV passes |
|---|---:|---:|---:|
| unit/bitfield | 16 | 16 | 0 |
| unit/bitops | 45 | 45 | 30 |
| unit/dump | 12 | 11 | 1 |
| unit/expire | 65 | 59 | 56 |
| unit/functions | 94 | 90 | 2 |
| unit/geo | 59 | 59 | 0 |
| unit/hyperloglog | 20 | 20 | 0 |
| unit/info-command | 3 | 3 | 3 |
| unit/introspection | 28 | 28 | 14 |
| unit/introspection-2 | 43 | 43 | 20 |
| unit/keyspace | 53 | 52 | 35 |
| unit/latency-monitor | 14 | 13 | 0 |
| unit/lazyfree | 4 | 4 | 0 |
| unit/multi | 60 | 53 | 0 |
| unit/other | 22 | 19 | 11 |
| unit/pause | 14 | 14 | 0 |
| unit/protocol | 25 | 17 | 13 |
| unit/pubsub | 30 | 30 | 0 |
| unit/querybuf | 2 | 2 | 0 |
| unit/quit | 3 | 3 | 3 |
| unit/replybufsize | 1 | 0 | 0 |
| unit/scan | 17 | 17 | 5 |
| unit/scripting | 111 | 110 | 0 |
| unit/slowlog | 16 | 9 | 0 |
| unit/sort | 52 | 52 | 0 |
| unit/tracking | 13 | 10 | 0 |
| unit/type/hash | 73 | 72 | 1 |
| unit/type/incr | 25 | 24 | 11 |
| unit/type/list | 235 | 218 | 0 |
| unit/type/list-2 | 2 | 2 | 0 |
| unit/type/list-3 | 11 | 11 | 3 |
| unit/type/set | 98 | 94 | 0 |
| unit/type/stream | 72 | 63 | 1 |
| unit/type/stream-cgroups | 44 | 43 | 1 |
| unit/type/string | 77 | 77 | 65 |
| unit/type/zset | 291 | 289 | 10 |
| unit/violations | 1 | 1 | 0 |
| **all** | **1751** | **1673** | **285 (17.0%)** |

## Why the other 1,388 fail

- **755 stop on a command BendKV does not have.** By the number of tests each one stops:
  FUNCTION LOAD 123, ZADD 118, XADD 60, GEOADD 37, SADD 31, MULTI 23, LPUSH 19, PFADD 19,
  WATCH 18, BITFIELD 17, SYNC 17 (tests that read the replication stream), RPUSH 16,
  BITOP 13, XGROUP 12, INCRBYFLOAT 11, GEORADIUS 10, ZINCRBY 9, and 62 more below nine
  (202 tests), COPY among them with 7 and LCS with 5.
- **590 never ran**: their unit ended before them, on a command outside any test:
  LATENCY RESET (latency-monitor), LPUSH (sort), HSET (type/hash), SADD (type/set),
  SUBSCRIBE (tracking), HELLO 3 (type/list and type/zset run their tests over RESP2 and
  then over RESP3), `CONFIG SET appendonly yes` (type/stream; BendKV turns its
  append-only file on only at its start); or on a test that waits for a reply that never
  comes because the command before it is missing (pubsub: PSUBSCRIBE after CLIENT REPLY
  OFF; scripting: the second line of FUNCTION LOAD's reply, read raw). One test runs
  only on a server that names jemalloc as its allocator.
- **43 fail with another error**, all of them for what BendKV does not have yet: COMMAND
  GETKEYS, INFO and LIST of commands BendKV does not have (19), RESP3 (16), 7 that
  fail because a command before them is missing (MOVE's basic usage among them, above),
  and one for the time of a key's last access, which BendKV does not keep (OBJECT
  IDLETIME answers 0). (Before times to live, SET's options failed 30 more tests here,
  answered `ERR syntax error`. INFO's statistics per command, which `info-command` looked
  for, made 3 more tests pass; SCAN and RANDOMKEY pass all their tests on keys: SCAN's
  basic iteration, COUNT, MATCH, TYPE, and its guarantee under a load of writes, and
  RANDOMKEY's three.)

So the tests are where the plan goes next: the rest of the commands on strings and keys
(BITOP, BITFIELD, LCS, COPY), then the data types
one by one (866 tests), RESP3, which
two units need before their second half runs, and MULTI/EXEC and pub/sub. Scripts,
functions and streams (306 tests) stay out of scope.

## What it found

A bug in what BendKV has. KEYS matched patterns with a naive glob that tried, for each
`*`, the rest of the pattern at every later position of the key, so `KEYS a*a*a*...a*b`
(twenty `a*`) against a key of forty `a`s, which matches nowhere, took a number of tries
exponential in the stars and ran for minutes; the server, one thread over the database,
answered nothing else meanwhile (keyspace's "Regression for pattern matching long nested
loops"). It also lacked `[...]` classes and `\` escapes. KEYS now uses the port of
Redis's `stringmatchlen` that CONFIG GET and COMMAND LIST used already, with Redis's
cut-off that keeps a pattern's cost polynomial and Redis's shortcut for `*` alone; it
answers that pattern at once. `tests/robust_test.py` times it, and the differential test
now draws patterns with classes, ranges, escapes and random bytes.

## What this mode does not test

Tests that need a server of their own do not run in this mode: the units above with no
test, the tests of other units tagged `external:skip`, and all of `tests/integration`
(replication, persistence across restarts, `redis-check-aof`, `redis-cli`, and more).
BendKV starts as `redis-server` starts, with the same command line and configuration
file, so the next step is the suite's own mode with BendKV in place of
`src/redis-server`. Until then BendKV's own tests cover part of that ground: the start
(`tests/start_test.py`, against `redis-server`) and restarts from the append-only file
(`tests/aof_test.py`).

## Other measures

- The test suites of client libraries (redis-py, go-redis, Jedis, node-redis) run
  against a server given by its address, and test what applications see.
- [resp-compatibility](https://github.com/tair-opensource/resp-compatibility) (Alibaba's
  Tair team) checks which commands of which Redis versions a server answers as Redis
  does, from a table of cases per command and version; it is used to compare
  Redis-compatible services.
