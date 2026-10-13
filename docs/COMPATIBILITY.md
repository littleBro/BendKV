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
test take one unit at a time each, each in a directory of its own, and each unit runs on
an instance started for it, so that it starts from the server's defaults whatever the
unit before it left (a test that fails before it sets back a parameter it changed
leaves the change: unit/pubsub's test of `evicted` events, which BendKV never sends,
leaves `maxmemory 1` and `allkeys-lru`, under which a unit/type/incr run after it on
the same instance found INCR's shared integers counted once). Before each group of
tests the suite empties the server (FLUSHALL, FUNCTION FLUSH) and sets the parameters
the group asks for with CONFIG SET.

The same run against `redis-server` 7.0.15 in its default configuration is the
reference: a test counts only if Redis passes it. 80 of the 1,757 tests that run in this
mode fail on Redis itself, nearly all of them because they use `DEBUG`, which Redis 7.0
refuses unless `enable-debug-command` is set at its start.

```bash
make suite REDIS_SRC=../redis      # both runs and the table, in build/suite/
```

## The result

Redis 7.0.15, October 2026. Of the 1,677 tests Redis passes in this mode, BendKV passes
**797 (47.5%)**; of the 1,172 in the units of what BendKV has, 792 (68%: 203 tests of
unit/type/list and 82 of unit/type/zset wait for RESP3). MONITOR (section 3zt of
[FINDINGS.md](FINDINGS.md)) brought 3: unit/introspection passes 25 of its 28 tests, a
monitor's lines of the commands that run, and a transaction's in order, with its EXEC's
line also when an error while it queued aborted it (of the other three, two look in a
monitor for the calls of a Lua script and of a function, and one for MIGRATE's arguments
redacted, which BendKV does not have), and unit/other the test of RESET clearing a
monitor's state (15 of its 19). CLIENT LIST, INFO and KILL (section 3zs of
[FINDINGS.md](FINDINGS.md)) brought 9, unit/introspection's tests of CLIENT LIST, of IDs,
with names and without, CLIENT INFO, KILL's errors, KILL SKIPME yes and no of all
clients, and a client named by SETNAME that closes its connection and leaves the list.
unit/querybuf's two tests now run past CLIENT LIST, to a check of the size of the
client's query buffer, which BendKV does not keep (its qbuf is 0). Since each unit runs
on an instance started for it, 4 more tests of unit/type/stream-cgroups run on Redis, and
pass there (1,677 of 1,757; the test of INCR's shared integers in unit/type/incr passes
on BendKV again, as it did before an instance left with `allkeys-lru` ran it). Pub/Sub
and keyspace notifications (section 3zr of [FINDINGS.md](FINDINGS.md)) brought 26:
unit/pubsub passes 25 of its 30 tests (of the other five, one runs over RESP3, one needs
streams, and the test of `evicted` events waits for an eviction that never comes, as
BendKV has no maxmemory, so the two after it do not run: CONFIG GET and SET of the flags,
and `new` events), and unit/other the test of RESET clearing a client's Pub/Sub state.
Transactions (section 3zq of [FINDINGS.md](FINDINGS.md)) brought 27: unit/multi passes 25
of the 53 tests Redis passes (of the other 28, 12 read the replication stream with SYNC,
4 need Lua's script timeout, 4 maxmemory's OOM, one SORT and one XGROUP, and 6 fail on
`MULTI calls can not be nested` or `WATCH inside MULTI is not allowed`, their client left
in MULTI by the test of OOM before them), unit/other RESET's test of the MULTI state, and
unit/type/set the test of SMOVE onto a set that holds the member, which watches it (all
94 of its tests now); unit/protocol's regression test of argument rewriting (issue 9598,
which runs a transaction) passes too, but Redis fails it in this mode, so it does not
count. And 14 tests that passed fail now, each on a client left in MULTI by a test before
it that failed inside a transaction on a command BendKV does not have (GEOADD in
unit/introspection-2's command stats for MULTI: the 12 tests of COMMAND after it answer
QUEUED; SORT in unit/sort; XADD in unit/type/stream), as they would on a Redis without
those commands. The blocking commands (section 3zp of [FINDINGS.md](FINDINGS.md)) brought
13: unit/type/zset passes 192 of its 289, the twelve tests of BZPOPMIN, BZPOPMAX and
BZMPOP that run over RESP2 before its HELLO 3 (a sorted set there already, several, and a
second one that has members, in both encodings), and unit/introspection-2 the statistics
of BRPOP (28 of its 43). With the tests of RESP3, MULTI, DEBUG, SORT and replication left
out, unit/type/list passes the 140 tests Redis passes, and unit/type/zset 260 of Redis's
276 (the other 16 use RESP3 within a test). Sorted sets (section 3zl of
[FINDINGS.md](FINDINGS.md)) brought 181: unit/type/zset passes 180 of its 289 tests (it
then runs the tests of its blocking commands over RESP3 first, and stops at HELLO 3,
before 82 more; of the others, 12 need the blocking commands, 14 RESP3 within a test, one
replication), unit/scan ZSCAN's four (all 17 now), unit/keyspace COPY of a sorted set in
both its encodings (49 of its 52), unit/introspection-2 COMMAND GETKEYS of more than 256
keys (of ZUNIONSTORE) and ZUNIONSTORE marked movablekeys (27 of its 43), unit/type/set
the test of SMISMEMBER that made a sorted set first (93 of its 94), unit/other the test
that makes a dataset of every type (the check of its digest after a reload is left out in
this mode; 12 of its 19), and unit/sort a test named for SORT that reads a sorted set
with infinities by ZRANGE (2 of its 52). With the tests of RESP3 left out (`--tags
-resp3`), unit/type/zset runs to its end: Redis passes 285 of its tests, BendKV 238, and
each of the other 47 needs the blocking commands, RESP3 within a test, MULTI or
replication. INCRBYFLOAT and HINCRBYFLOAT (floats, in software, as Redis computes them:
section 3zk of [FINDINGS.md](FINDINGS.md)) brought 24: unit/type/incr passes all 24 of
its tests and unit/type/hash 68 of its 72 (the other four need DUMP, RESP3, and integers
past 14 digits). Sets brought 104: unit/type/set passed 92 of its 94 tests (the other two
needed WATCH and ZADD), unit/scan 13 of its 17 (SSCAN's four, and SCAN's regression test
for issue #4906, which makes sets; the other four were ZSCAN's), unit/keyspace COPY of a
set in both its encodings (47 of its 52 now), unit/protocol the three tests of raw
protocol replies, which read SRANDMEMBER's (all 17 now), unit/type/string MGET against a
set (74 of its 77), and unit/sort one: the unit now runs past its SADD, and its last
test, named for SETRANGE, runs SORT_RO and catches every error. Lists brought 33:
unit/type/list-3 passes all 11 of its tests and unit/type/list-2 both of its own (stress
tests of quicklist nodes and their compression, and LTRIM under load, which the deque
passes as it is), unit/type/list 15 of its 218 (LPOS with its options, the pushes and the
pops with and without a count, and the checks of compressed nodes by LINSERT, LSET and
LTRIM; the unit then runs its other tests over RESP3 first, and stops at HELLO 3), and 8
tests of other units need a list: a string command's WRONGTYPE against one (three in
unit/type/string, INCR's in unit/type/incr, BITOP's in unit/bitops), COPY of a list
(unit/keyspace), EXPIRE's test of a write to a key whose time passed (unit/expire), and
the regression of a crash with blocking ops and pipelining (unit/protocol, which sends
BLPOP twice, refused, and then RPUSH). Hashes brought 64: unit/type/hash passes 56 of its
72 tests (the other 16: HINCRBYFLOAT's twelve, which waited for doubles (they pass now,
above); two that read hashes back with DUMP; HRANDFIELD over RESP3; and HINCRBY's test of
overflows, which starts from -9223372036854775484, past BendKV's integers of 14 digits),
unit/scan the three of HSCAN, unit/keyspace COPY of a hash in both its encodings (44 of
its 52 now), and unit/introspection-2 COMMAND GETKEYS of EVAL, with keys and without, and
of MEMORY USAGE, and EVAL marked movablekeys (25 of its 43). Times to live (EXPIRE and
its kin, TTL and PTTL, SET's options, GETEX, GETDEL) and the sweep of expired keys
brought 78 of them: unit/expire passes 56 of its 59 tests (the other 3 need replication
and LPUSH). Ranges and bits (GETRANGE, SETRANGE, GETBIT, SETBIT, BITCOUNT, BITPOS)
brought 49 (unit/bitops 30 of its 45 then). TOUCH, TIME and OBJECT brought 4 (TOUCH's two
in unit/introspection-2, a PEXPIREAT at a time TIME gave, and INCR's shared integers seen
by OBJECT REFCOUNT); one test more now fails on what BendKV does not keep, rather than on
a missing command: OBJECT IDLETIME is 0, where the test waits three seconds for it.
MSETNX, RENAME and RENAMENX brought 13, and COPY 7, its tests on strings: unit/keyspace
passes 42 of its 52 tests (the rest need other types, or DEBUG). BITOP and LCS brought
19: unit/bitops passes 43 of its 45, unit/type/string 70 of its 77 (the rest need other
types, or replication), and COMMAND GETKEYS of LCS passes in unit/introspection-2.
BITFIELD brought 16, all of unit/bitfield; of unit/bitops's other two tests, one needs
lists and the other counts the changes since the last save (`rdb_changes_since_last_save`
in INFO), which BendKV does not keep. Several databases brought 6 of the 17 tests Redis
passes that run only without `--singledb`: SET and GET in different databases, DEL in
database 1, and four of MOVE's five (against a key the target holds, against a database
that is no integer, with a time and without one). The fifth, MOVE's basic usage, passes
alone but counts a key that earlier tests left in the unit: the test before it, which
would remove them with FLUSHDB, stops at XADD. COPY brought 3 more (into another database
with REPLACE and without, and a copy independent of its source): 9 of the 17. The other 7
need MULTI and WATCH, Lua or lists (then).

| area | units | Redis passes | BendKV passes |
|---|---|---:|---:|
| what BendKV has: the protocol, connections and clients, the keyspace and its databases, strings and their ranges, bits and fields, counters and floats, hashes, lists, sets, sorted sets and the commands that wait on them, times to live, transactions, pub/sub and keyspace notifications, introspection | protocol, quit, keyspace, type/string, type/incr, type/hash, type/list, list-2, list-3, type/set, type/zset, scan, bitops, bitfield, expire, multi, pubsub, introspection, introspection-2, other, info-command | 1172 | **792** |
| data types, not yet | geo, hyperloglog, sort, dump, lazyfree, violations | 147 | 2 |
| client-side caching, CLIENT PAUSE, the latency monitor, the slow log, the query buffer, not yet | tracking, pause, latency-monitor, slowlog, querybuf | 48 | 0 |
| out of scope: Lua scripts, functions, streams | scripting, functions, type/stream, type/stream-cgroups | 310 | 3 |

Most of the 5 passes outside the first row pass without the feature they test: they expect an error and take
BendKV's "unknown command" for one, or catch every error and only check that the server
still answers.

By unit (units where every test needs a server of its own are left out: acl, acl-v2,
aofrw, auth, client-eviction, cluster, cluster-scripting, info, limits, maxmemory,
memefficiency, networking, obuf-limits, oom-score-adj, pendingquerybuf, printver,
pubsubshard, shutdown, tls, type/list-common, wait):

| unit | tests | Redis passes | BendKV passes |
|---|---:|---:|---:|
| unit/bitfield | 16 | 16 | 16 |
| unit/bitops | 45 | 45 | 44 |
| unit/dump | 12 | 11 | 1 |
| unit/expire | 65 | 59 | 57 |
| unit/functions | 94 | 90 | 2 |
| unit/geo | 59 | 59 | 0 |
| unit/hyperloglog | 20 | 20 | 0 |
| unit/info-command | 3 | 3 | 3 |
| unit/introspection | 28 | 28 | 25 |
| unit/introspection-2 | 43 | 43 | 16 |
| unit/keyspace | 53 | 52 | 49 |
| unit/latency-monitor | 14 | 13 | 0 |
| unit/lazyfree | 4 | 4 | 0 |
| unit/multi | 60 | 53 | 25 |
| unit/other | 22 | 19 | 15 |
| unit/pause | 14 | 14 | 0 |
| unit/protocol | 25 | 17 | 17 |
| unit/pubsub | 30 | 30 | 25 |
| unit/querybuf | 2 | 2 | 0 |
| unit/quit | 3 | 3 | 3 |
| unit/replybufsize | 1 | 0 | 0 |
| unit/scan | 17 | 17 | 17 |
| unit/scripting | 111 | 110 | 0 |
| unit/slowlog | 16 | 9 | 0 |
| unit/sort | 52 | 52 | 1 |
| unit/tracking | 13 | 10 | 0 |
| unit/type/hash | 73 | 72 | 68 |
| unit/type/incr | 25 | 24 | 24 |
| unit/type/list | 235 | 218 | 15 |
| unit/type/list-2 | 2 | 2 | 2 |
| unit/type/list-3 | 11 | 11 | 11 |
| unit/type/set | 98 | 94 | 94 |
| unit/type/stream | 72 | 63 | 0 |
| unit/type/stream-cgroups | 50 | 47 | 1 |
| unit/type/string | 77 | 77 | 74 |
| unit/type/zset | 291 | 289 | 192 |
| unit/violations | 1 | 1 | 0 |
| **all** | **1757** | **1677** | **797 (47.5%)** |

## Why the other 880 fail

- **417 stop on a command BendKV does not have.** By the number of tests each one stops:
  FUNCTION LOAD 124, XADD 61, SORT 46, GEOADD 38, PFADD 19, SYNC 17 (tests that read
  the replication stream, 12 of them unit/multi's of what a transaction propagates),
  XGROUP 13, GEORADIUS 10, CLIENT PAUSE 10, DUMP 9, SLOWLOG 9, and 25 more below nine
  (61 tests).
- **382 never ran**: their unit ended before them, on a command outside any test:
  LATENCY RESET (latency-monitor), HELLO 3 (type/list and type/zset run their later tests
  over RESP3 and then over RESP2), `CONFIG SET appendonly yes` (type/stream; BendKV turns
  its append-only file on only at its start); or on a test that waits for a reply that
  never comes, because the command before it is missing (tracking: the invalidations of
  CLIENT TRACKING; scripting: the second line of FUNCTION LOAD's reply, read raw) or
  because BendKV evicts nothing (pubsub: the `evicted` event, 3 tests). One test runs
  only on a server that names jemalloc as its allocator.
- **81 fail with another error.** 28 fail on a client left in MULTI by a test before them
  that failed inside a transaction on what BendKV does not have: GEOADD in
  unit/introspection-2's test of command stats for MULTI (every test of COMMAND after it
  runs in that state, and the 12 of them that passed before answer QUEUED now),
  maxmemory's OOM in unit/multi (9, the test itself among them), XADD in unit/type/stream
  (4), SORT in unit/sort (2) and CLIENT PAUSE in unit/pause (1); 17 need RESP3; and the
  others fail for what BendKV does not have yet: COMMAND GETKEYS of commands it does not
  have, Lua (a script's BUSY, the statistics of EVAL, a script's calls in a monitor),
  DUMP, OBJECT IDLETIME (it answers 0), `rdb_changes_since_last_save` (0), the memory
  UNLINK and FLUSHDB ASYNC give back (BendKV's used_memory is its resident memory, which
  its heap keeps and uses again), the size of a client's query buffer (CLIENT LIST's
  qbuf, 0), streams, HINCRBY past 14 digits, and MOVE's basic usage (above). (Before
  times to live, SET's options failed 30 more tests here, answered `ERR syntax error`.
  INFO's statistics per command, which `info-command` looked for, made 3 more tests pass;
  SCAN and RANDOMKEY pass all their tests on keys: SCAN's basic iteration, COUNT, MATCH,
  TYPE, and its guarantee under a load of writes, and RANDOMKEY's three.)

So the tests are where the plan goes next: RESP3, which type/list (203 tests) and
type/zset (82) need before their later tests run, maxmemory, and the data types not yet
there (147 tests). Scripts, functions and streams (310 tests) stay out of scope.

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
now draws patterns with classes, ranges, escapes and random bytes. A later review
([#4](https://github.com/littleBro/bendkv/issues/4)) asked for the rest of Redis's bounds:
the port already took a run of stars as one, ended a star's loop at its first match and
stopped a search whose rest matched nowhere; it now also matches nothing past 1000 nested
stars, as Redis has done since its fix for CVE-2024-31228 (in the 7.0.15 of Ubuntu that the
tests run against), and `tests/keyspace_test.py` compares KEYS and SCAN's MATCH with Redis
on patterns that a matcher without one of the cut-offs takes from 3.4 * 10^11 to more than
10^59 calls to answer.

## What this mode does not test

Tests that need a server of their own do not run in this mode: the units above with no
test, the tests of other units tagged `external:skip`, and all of `tests/integration`
(replication, persistence across restarts, `redis-check-aof`, `redis-cli`, and more).
BendKV starts as `redis-server` starts, with the same command line and configuration
file, so the next step is the suite's own mode with BendKV in place of
`src/redis-server`. Until then BendKV's own tests cover part of that ground: the start
(`tests/start_test.py`, against `redis-server`), restarts from the append-only file
(`tests/aof_test.py`), and its rewrite (`tests/rewrite_test.py`: BGREWRITEAOF's replies
and INFO's fields against Redis's, the rewritten file against Redis's base, writes during a
rewrite, BendKV and Redis started from the new file; Redis's unit/aofrw is tagged
`external:skip`, and most of it needs `DEBUG LOADAOF` and `CONFIG SET appendonly yes`).

## Other measures

- The test suites of client libraries (redis-py, go-redis, Jedis, node-redis) run
  against a server given by its address, and test what applications see.
- [resp-compatibility](https://github.com/tair-opensource/resp-compatibility) (Alibaba's
  Tair team) checks which commands of which Redis versions a server answers as Redis
  does, from a table of cases per command and version; it is used to compare
  Redis-compatible services.
