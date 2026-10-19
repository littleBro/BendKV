# BendKV against Redis's own test suite

Redis keeps its tests next to its code (`tests/`, run by `./runtest`), and the suite can
run against a server it did not start: given `--host` and `--port`, it leaves out the
tests tagged `external:skip`, those that start servers of their own, and runs the rest
against the server it is pointed at. Redis has options for that mode meant for servers
that are compatible without being Redis: `--singledb` uses database 0 alone,
`--ignore-encoding` skips the checks of Redis's internal encodings (listpack, intset,
quicklist), `--ignore-digest` the checks with `DEBUG DIGEST`
([tests/README.md](https://github.com/redis/redis/blob/7.2.16/tests/README.md)). BendKV
has Redis's 16 databases, so it runs without `--singledb`: the suite keeps its keys in
database 9 and uses the others for the tests of SELECT, MOVE and SWAPDB. It is the
measure of BendKV as a drop-in replacement for one Redis node.

## How it runs

`tools/redis_suite.py` runs each unit of `tests/unit` and `tests/unit/type` of a Redis
7.2.16 source tree in that mode, with `--ignore-encoding --ignore-digest --durable`
(`--durable`: a test that ends in an error counts as failed and the unit goes
on; an error between tests still ends the unit). Three instances of the server under
test take one unit at a time each, each in a directory of its own, and each unit runs on
an instance started for it, so that it starts from the server's defaults whatever the
unit before it left (a test that fails before it sets back a parameter it changed
leaves the change: unit/pubsub's test of `evicted` events, when BendKV did not send them,
left `maxmemory 1` and `allkeys-lru`, under which a unit/type/incr run after it on
the same instance found INCR's shared integers counted once). Before each group of
tests the suite empties the server (FLUSHALL, FUNCTION FLUSH) and sets the parameters
the group asks for with CONFIG SET.

The same run against `redis-server` 7.2.16 in its default configuration is the
reference: a test counts only if Redis passes it. 93 of the 1,905 tests that run in this
mode fail on Redis itself, 82 of them because they use `DEBUG`, which Redis 7 refuses
unless `enable-debug-command` is set at its start.

```bash
make suite REDIS_SRC=../redis      # both runs and the table, in build/suite/
```

## The result

Redis 7.2.16, October 2026. Of the 1,812 tests Redis passes in this mode, BendKV passes
**1,769 (97.6%)**; of the 1,690 in the units of what BendKV has, 1,649 (97.6%), and 120
of the 122 of streams'.

7.2.16's suite runs 148 tests more in this mode than 7.0.15's, and Redis passes 135 more.
At the move BendKV passed 120 more, 1,676 where it passed 1,556 of the 1,677 that 7.0.15
passed (92.8%), and since, streams' groups brought 43, their waits 22, the append-only
file turned on at run time 23, a client's query buffer 2 (below), and NOREPLICAS
and MODULE 3 (sections 3zzzzza and 3zzzzzb of [FINDINGS.md](FINDINGS.md)). The suite
found six things to fix (section 3zzzzk of
[FINDINGS.md](FINDINGS.md)), and BendKV passed 1,657 before them:
- unit/hyperloglog, 27 tests where 7.0.15's had 20, sets a sparse HyperLogLog of 32 MB of
  opcodes whose runs pass the last register, the test of the fix of CVE-2025-32023.
  BendKV answered INVALIDOBJ as Redis does, but its walks of the opcodes read on to the
  end, in a time that grew with the square of the length, and the unit stopped at the
  suite's limit of 60 s, 13 tests passed. They now end at the first opcode past the last
  register, as Redis's do. Its other two new tests set `hll-sparse-max-bytes`, which
  BendKV did not read; it does now, and passes the 27.
- unit/type/list's tests of a timeout whose ms pass LLONG_MAX, which 7.2.16 finds out of
  range where 7.0.15 found it negative, and of the changes a served BLPOP or BLMOVE
  counts, which 7.2.16 counts as their calls, as it runs the command again for the client
  it serves (234 of its 237).
- unit/bitops's test of the changes a SETBIT or a BITFIELD counts, which 7.2.16 counts
  as a change of the value: a write that leaves it as it was counts none (45 of its 45).
- unit/pause, 17 tests where 7.0.15's had 14: while a pause holds back writes, RANDOMKEY
  of a database whose keys have all passed their times answers one of them in 7.2.16,
  which deletes none then, where BendKV answered nil (17 of its 17).

Of the others that 7.2.16 passes and BendKV did not then:
- unit/pubsub, 46 tests where 7.0.15's had 30, passed 42: its test of streams' events
  stopped at XGROUP before it closed its client, subscribed to every channel, so that the
  three tests of a client that publishes to itself counted one receiver more (run without
  that test, they passed). It passes all 46 since streams' groups.
- unit/other's test of every HELP subcommand asks MODULE's, which BendKV answers since
  MODULE (section 3zzzzzb of [FINDINGS.md](FINDINGS.md)), and unit/dump's and
  unit/type/set's new tests read the replication stream.

One test passed in one run of the suite and failed in another: unit/pubsub's PUNSUBSCRIBE
without arguments, which a client sends without waiting for its reply before another
client publishes. BendKV may run the PUBLISH first, as each connection reaches the actor
on its own; it failed in the first run, three units at once, and passed in the run above
and alone.

Streams' groups (section 3zzzzt of [FINDINGS.md](FINDINGS.md)) brought 43:
- unit/type/stream-cgroups passes 35 of the 56 tests Redis passes, where it passed one, a
  test that expects an error, which BendKV's answer to a command it did not have matched.
  They are its tests of XGROUP CREATE (MKSTREAM, ENTRIESREAD, a name taken),
  CREATECONSUMER and SETID, XREADGROUP of new entries and of a consumer's history (entries
  deleted since, a history empty, BLOCK with an ID other than `>`), XACK, XCLAIM,
  XAUTOCLAIM, XPENDING, XINFO STREAM FULL, and a consumer's seen and active times. Of its
  other 21, 14 wait in XREAD or XREADGROUP, and 7 never run, as the unit stops at `CONFIG
  SET appendonly yes`.
- unit/pubsub passes all its 46 (above): its test of streams' events, which now runs to
  its end and closes its client, subscribed to every channel, and the three tests that
  counted that client as one receiver more.
- unit/keyspace passes all its 53: COPY of a stream with groups, and MOVE's basic usage,
  which counted keys that the test before it, stopped at XGROUP, had left.
- unit/lazyfree passes 3 of its 4: a stream whose group was destroyed is freed at once,
  as Redis frees it. The fourth sets `stream-node-max-entries`.
- unit/introspection-2 passes 45 of its 46: COMMAND GETKEYS of XGROUP.
- unit/scripting passes 115 of its 119: XREADGROUP with BLOCK is refused in a script, as
  XREAD with BLOCK is.

Streams' waits (section 3zzzzu of [FINDINGS.md](FINDINGS.md)) brought 22, all the tests of
the streams' units that waited in XREAD or XREADGROUP:
- unit/type/stream passes 48 of the 66 tests Redis passes, where it passed 40: a blocking
  XREAD served by new data, on a stream that ran dry (issue #5299), with the same stream
  three times, at the edge of an ID's sequence, by XADDs in a transaction, and not woken
  by an XADD and a DEL (and an LPUSH) in one, nor answered an empty array. Of its other
  18, 16 never run, as the unit stops at `CONFIG SET appendonly yes`, and 2 set
  `stream-node-max-entries`.
- unit/type/stream-cgroups passes 49 of its 56, where it passed 35: a blocking XREADGROUP
  answered NOGROUP or WRONGTYPE when its key is deleted, set, of another kind after a
  transaction, flushed or renamed over, or when its group is destroyed; served by RENAME
  with data; on a stream that ran dry, never with an empty array; with clients blocked on
  a list or on the stream before it, run again without an endless loop; and an XREAD
  that goes on waiting while its key is deleted or set, served by the XADD after it. Its
  other 7 never run, as the unit stops at the same command.

The append-only file turned on at run time (section 3zzzzx of [FINDINGS.md](FINDINGS.md))
brought 23, the tests of the streams' units that never ran, as each unit stopped at
`CONFIG SET appendonly yes`: unit/type/stream passes 64 of its 66 (the other two set
`stream-node-max-entries`), and unit/type/stream-cgroups all its 56. One of them, XADD
with a partial ID at the maximal sequence, found a bug: XADD of `<ms>-*` past the last
sequence of ms answered "Elements are too large to be stored", where Redis answers that
the ID is not past the stream's last; it does now.

A client's query buffer (section 3zzzzy of [FINDINGS.md](FINDINGS.md)) brought 2, the two
tests of unit/querybuf that Redis passes in this mode: a new client's buffer after CLIENT
SETNAME, of 16 KB to 32 KB, freed once the client is idle 3 s; and the buffer of an
argument of 1,000,000 bytes sized to it from its length's line on, then taken back once
its client is idle 3 s.

### Against Redis 7.0.15

Redis 7.0.15, October 2026. Of the 1,677 tests Redis passes in this mode, BendKV passed
**1,556 (92.8%)**; of the 1,565 in the units of what BendKV has, 1,516 (96.9%), and 40
of the 110 of streams'. What each feature brought then, as measured against 7.0.15:
Functions (section 3zzzp of [FINDINGS.md](FINDINGS.md)) brought 195:
- unit/functions passes all the 90 tests Redis passes. Its other four use DEBUG RELOAD,
  which Redis refuses unless `enable-debug-command` is set and which BendKV does not have.
- unit/scripting passes 104 of the 110. It runs its tests twice, functions first, and now
  runs past that half. Each of the other six needs what BendKV does not have:
  replication (three read the replication stream, one counts good replicas), streams'
  groups (XGROUP) and CLUSTER.
- unit/pause passes all its 14: the fourteenth loads a function.
- unit/introspection passes 27 of its 28, with a monitor's lines of a function's calls.
  The 28th redacts MIGRATE's arguments.

Streams' values, reads and writes (sections 3zzzu, 3zzzy and 3zzzza of
[FINDINGS.md](FINDINGS.md)) brought 41: unit/type/stream passes 39 of the 63 tests Redis
passes (none before), XADD's IDs, options and errors, its trims, XRANGE and XREVRANGE,
XREAD without BLOCK, XDEL, XTRIM and XSETID; of its other 24, 8 wait in XREAD, 2 set
`stream-node-max-entries`, and 14 never run, as the unit stops at `CONFIG SET appendonly
yes`. unit/keyspace's COPY of a stream passes too, and unit/introspection-2's test that
XREAD is marked movablekeys.

ACL users (section 3zzzh of [FINDINGS.md](FINDINGS.md)) brought 2: unit/other's test of
RESET making its client the default user again (all 19 of its tests that Redis passes),
and unit/slowlog's of the redaction of ACL SETUSER's rules (8 of its 9; the ninth uses
MIGRATE). Redis's unit/acl and unit/acl-v2 are tagged `external:skip` as a whole, though
most of their tests need no server of their own. Run in this mode with the tag taken off
the blocks that need none, BendKV passes 68 of the 70 tests of unit/acl that Redis
passes, and 27 of the 29 of unit/acl-v2: the others use commands BendKV does not have
(streams', MIGRATE) or Redis 7.0's description of a selector's commands, and section
3zzzh lists them. Lua scripts and functions brought four of unit/acl's (64 of the 70 on
main): its test of SCRIPT HELP refused, its test of a script's call in the log, the test
after the first, which that one's failure left logged in as a user that may run nothing,
and its test of EVAL_RO, EVALSHA_RO and FCALL_RO. unit/auth, run so too, passes 6 of the
7 tests Redis passes there, its test of the limits Redis puts on the requests of a
client that must authenticate among them (section 3zzzzn): the other is its test of such
a client's output buffer, cut off past 1024 bytes, which needs the accounting of output
buffers BendKV does not have yet.

The RDB file (section 3zzzc of [FINDINGS.md](FINDINGS.md)) brought 2: unit/other's SAVE
of a database with a value of every type, and its final SAVE (18 of its 19 then; its BGSAVE
and its reload with DEBUG RELOAD need what BendKV does not have yet).
Lua scripts (section 3zzzd of [FINDINGS.md](FINDINGS.md)) brought 13, each a test of
another unit that runs a script: unit/pause passes 13 of its 14 tests (its four of
scripts under a pause, by their flags and in transactions; the fourteenth loads a
function), unit/multi 32 of its 53 (its four of a transaction and a script past
`lua-time-limit`: MULTI, EXEC, the body of a transaction and EXEC alone while the script
runs), unit/latency-monitor all 13 (the expire-cycle event of a set a script fills, and
LATENCY RESET of the events), unit/introspection-2 40 of its 43 (the statistics of
scripts' commands, and COMMAND LIST FILTERBY ACLCAT, which lists the scripting
category's commands), unit/introspection 26 of its 28 (a monitor's lines of a script's
calls), and unit/sort all 52 (SORT BY nosort from a script). unit/functions passed one
test fewer then (1 of its 90): its test of FUNCTION KILL against EVAL left the script it
started looping, which FUNCTION KILL would have ended, and the rest of the unit met BUSY.
unit/scripting passed none in that run: it runs its tests twice, functions first, and
stopped in that half. Its tests of EVAL, run alone (its loop `foreach is_eval {0 1}` cut
to `{1}`), passed 103 of the 110 that Redis passes; 104 with ACL users, as both halves
now do.
CLIENT TRACKING (section 3zzzb of [FINDINGS.md](FINDINGS.md)) brought 11: unit/tracking
passes the 10 of its 13 tests that Redis passes in this mode, and unit/other its test of
RESET clearing a client's state (16 of its 19). The other three of unit/tracking fail on
Redis too: the test of a lazily expired key uses DEBUG, which leaves its client in MULTI,
so the two tests of HELLO after it get QUEUED; the unit then ends, on both, at a test that
waits for an invalidation of a command queued in that MULTI. No test of the unit reaches
the differences that section lists; one of them a client would see: a client of RESP3
that others redirect to, with no subscription and whose batches all run the fast way,
gets its invalidations with its next reply, where Redis pushes them at once.
SLOWLOG and LATENCY (section 3zzz of [FINDINGS.md](FINDINGS.md)) brought 18:
unit/latency-monitor passes 11 of the 13 tests Redis passes (the other two need Lua: one
fills a set with a script, the next resets the events its expiry would have given), and
unit/slowlog 7 of its 9 (the other two use ACL and MIGRATE).
INCRBY's family on long longs (section 3zzv of [FINDINGS.md](FINDINGS.md)) brought 1:
unit/type/hash's test of HINCRBY's overflows, which starts from -9223372036854775484
(70 of its 72 tests).
DUMP and RESTORE (section 3zzu of [FINDINGS.md](FINDINGS.md)) brought 12: unit/dump
passes the 11 of its 12 tests that Redis passes (the twelfth uses DEBUG), and
unit/type/list its two tests of a ziplist of various encodings, which restore one (216 of
its 218). unit/type/hash's two tests of the same kind run past DUMP and RESTORE now and
fail on the order of HGETALL of the hash they make: its values of 8 and 64 KB, which Redis
keeps in a listpack under `hash-max-ziplist-value 1000000000`, make BendKV's a table (its
small hashes are those of the parameters' defaults).
GEO (section 3zzm of [FINDINGS.md](FINDINGS.md)) brought 79: unit/geo passes all its 59
tests, its fuzzing tests (random sets of up to 20,000 points, each search compared with
one made in Tcl) in 29.5 s where Redis takes 16.4 s, and unit/introspection-2 20 more
(37 of its 43): its tests of the statistics of GEOADD, of its errors and of MULTI (which
queues a GEOADD), GEORADIUS marked movablekeys, and the 16 tests after the one of MULTI,
which a client it left in MULTI answered QUEUED (COMMAND GETKEYS, GETKEYSANDFLAGS, INFO
and LIST, and SORT, SORT_RO, EVAL and ZUNIONSTORE marked movablekeys).
LASTSAVE, ROLE, WAIT, SHUTDOWN, MEMORY and LOLWUT (section 3zzl of
[FINDINGS.md](FINDINGS.md)) brought none: their tests need servers of their own
(unit/shutdown, unit/wait, unit/acl's), but unit/multi's MULTI with SHUTDOWN, which passes
run alone and fails in its unit on the client that REPLICAOF's test leaves in MULTI
(below).
CLIENT PAUSE and CLIENT UNPAUSE (section 3zzk of [FINDINGS.md](FINDINGS.md)) brought 9:
unit/pause passes the 9 of its 14 tests that run no Lua script; the other five run
scripts under a pause (EVAL, EVAL_RO, FUNCTION LOAD).
HyperLogLogs (section 3zzj of [FINDINGS.md](FINDINGS.md)) brought 20: unit/hyperloglog
passes all its tests, its fuzzing test (1,000 PFADDs of up to 3,000 elements, bytes set at
random, a PFCOUNT) in 53 seconds where Redis takes 41, under the suite's limit of 60.
SORT and SORT_RO (section 3zzh of [FINDINGS.md](FINDINGS.md)) brought 56: unit/sort passes
51 of its 52 tests (the other calls SORT from a Lua script), unit/type/list 214 of its
218 (the two tests that make their list with SORT's STORE, and the two that failed on the
client the test of SORT's STORE left waiting, above), unit/multi the test of a watched key
that SORT with STORE deletes, its result empty (28 of its 53), and unit/violations its one
test that runs in this mode, a SORT that stores an integer it GETs into a list. RESP3
(section 3zx of [FINDINGS.md](FINDINGS.md)) brought 292: unit/type/list runs past its
HELLO 3 now and passes 210 of its 218 tests, unit/type/zset 287 of its 289, unit/type/hash
its test of HRANDFIELD over RESP3 (69 of its 72) and unit/pubsub its test of messages with
CLIENT REPLY OFF, which runs over RESP3 (29 of its 30). Of unit/type/list's other eight,
two read the replication stream, two make their list with SORT's STORE, two read lists
back with DUMP, and two fail on the client that the test of SORT's STORE, stopped at
SORT, leaves waiting on its key for five seconds (BLMPOP's test of a list moved into
place by RENAME gets the list's second element, and BLPOP's test of a timeout of 0.001 s
waits a second for no client to be blocked); unit/type/zset's other two read the
replication stream. maxmemory and its eviction
(section 3zw of [FINDINGS.md](FINDINGS.md)) brought 8: unit/pubsub's test of `evicted`
events, and the two after it that it held back (CONFIG GET and SET of the flags, and
`new` events); unit/multi's DISCARD past maxmemory and its EXEC aborted after a command
refused for memory while it queued; unit/introspection-2's test that TTL, TYPE and
EXISTS leave a key's last use as it was; and unit/lazyfree's two tests of the memory
UNLINK and FLUSHDB ASYNC give back, now that `used_memory` is what the heap's live values
hold. While a rewrite of the append-only file or a background save runs, the eviction
and the refusal past maxmemory count the dataset's change by its number of keys, each at
the average size when the job started, and a value grown in place counts when the job
ends (README.md, Memory; section 3zzzk of [FINDINGS.md](FINDINGS.md)): Redis's parent
counts no page its child keeps, and BendKV's snapshot keeps the values the writes
replace. MONITOR (section 3zt of
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
client's query buffer, which BendKV did not keep then (its qbuf was 0; it does since
section 3zzzzy of [FINDINGS.md](FINDINGS.md)). Since each unit runs
on an instance started for it, 4 more tests of unit/type/stream-cgroups run on Redis, and
pass there (1,677 of 1,757; the test of INCR's shared integers in unit/type/incr passes
on BendKV again, as it did before an instance left with `allkeys-lru` ran it). Pub/Sub
and keyspace notifications (section 3zr of [FINDINGS.md](FINDINGS.md)) brought 26:
unit/pubsub passes 25 of its 30 tests (of the other five, one runs over RESP3, one needs
streams, and the test of `evicted` events waited for an eviction that never came, as
BendKV had no maxmemory then, so the two after it did not run: CONFIG GET and SET of the flags,
and `new` events), and unit/other the test of RESET clearing a client's Pub/Sub state.
Transactions (section 3zq of [FINDINGS.md](FINDINGS.md)) brought 27: unit/multi passes 25
of the 53 tests Redis passes (of the other 28, 12 read the replication stream with SYNC,
4 need Lua's script timeout, 4 maxmemory's OOM, one SORT and one XGROUP, and 6 fail on
`MULTI calls can not be nested` or `WATCH inside MULTI is not allowed`, their client left
in MULTI by the test of OOM before them; since maxmemory, two of the four pass, and the
client is left in MULTI by REPLICAOF instead), unit/other RESET's test of the MULTI state, and
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
a missing command: OBJECT IDLETIME was 0, where the test waits three seconds for it (it
passes since maxmemory).
MSETNX, RENAME and RENAMENX brought 13, and COPY 7, its tests on strings: unit/keyspace
passes 42 of its 52 tests (the rest need other types, or DEBUG). BITOP and LCS brought
19: unit/bitops passes 43 of its 45, unit/type/string 70 of its 77 (the rest need other
types, or replication), and COMMAND GETKEYS of LCS passes in unit/introspection-2.
BITFIELD brought 16, all of unit/bitfield; of unit/bitops's other two tests, one needs
lists and the other counts the changes since the last save (`rdb_changes_since_last_save`
in INFO), which BendKV did not keep when the suite last ran (it does since section 3zzzk
of [FINDINGS.md](FINDINGS.md), counting some writes otherwise than Redis: README.md,
Persistence). Several databases brought 6 of the 17 tests Redis
passes that run only without `--singledb`: SET and GET in different databases, DEL in
database 1, and four of MOVE's five (against a key the target holds, against a database
that is no integer, with a time and without one). The fifth, MOVE's basic usage, passes
alone but counts a key that earlier tests left in the unit: the test before it, which
would remove them with FLUSHDB, stops at XGROUP (at XADD before streams). COPY brought 3
more (into another database with REPLACE and without, and a copy independent of its
source): 9 of the 17. The other 7 need MULTI and WATCH, Lua or lists (then).

### By area and by unit, against Redis 7.2.16

| area | units | Redis passes | BendKV passes |
|---|---|---:|---:|
| what BendKV has: the protocol, connections and clients and their pause, the keyspace and its databases, strings and their ranges, bits and fields, counters and floats, hashes, lists, sets, sorted sets and the commands that wait on them, SORT, HyperLogLogs, GEO, DUMP and RESTORE, times to live, lazy freeing, transactions, pub/sub and keyspace notifications, introspection and the query buffer, the slow log and the latency monitor, client-side caching, ACL users, Lua scripts and functions | protocol, quit, keyspace, type/string, type/incr, type/hash, type/list, list-2, list-3, type/set, type/zset, sort, hyperloglog, geo, dump, scan, bitops, bitfield, expire, lazyfree, violations, multi, pubsub, pause, introspection, introspection-2, querybuf, other, info-command, latency-monitor, slowlog, tracking, scripting, functions | 1690 | **1649** |
| streams: their values, reads, writes, groups and waits | type/stream, type/stream-cgroups | 122 | **120** |

Of the first row's, unit/lazyfree's first two pass on BendKV's account of its heap, and
its third frees a stream whose group was destroyed (the fourth sets
`stream-node-max-entries`); unit/violations's one is a SORT.

By unit (units where every test needs a server of its own are left out: acl, acl-v2,
aofrw, auth, client-eviction, info, limits, maxmemory, memefficiency, networking,
obuf-limits, oom-score-adj, printver, pubsubshard, shutdown, tls, type/list-common,
wait):

| unit | tests | Redis passes | BendKV passes |
|---|---:|---:|---:|
| unit/bitfield | 18 | 18 | 18 |
| unit/bitops | 45 | 45 | 45 |
| unit/dump | 14 | 12 | 11 |
| unit/expire | 66 | 59 | 57 |
| unit/functions | 96 | 92 | 92 |
| unit/geo | 64 | 64 | 64 |
| unit/hyperloglog | 27 | 27 | 27 |
| unit/info-command | 3 | 3 | 3 |
| unit/introspection | 34 | 34 | 33 |
| unit/introspection-2 | 47 | 46 | 45 |
| unit/keyspace | 54 | 53 | 53 |
| unit/latency-monitor | 16 | 14 | 14 |
| unit/lazyfree | 4 | 4 | 3 |
| unit/multi | 60 | 53 | 33 |
| unit/other | 25 | 22 | 22 |
| unit/pause | 17 | 17 | 17 |
| unit/protocol | 25 | 17 | 17 |
| unit/pubsub | 46 | 46 | 46 |
| unit/querybuf | 3 | 2 | 2 |
| unit/quit | 3 | 3 | 3 |
| unit/replybufsize | 1 | 0 | 0 |
| unit/scan | 21 | 18 | 18 |
| unit/scripting | 120 | 119 | 116 |
| unit/slowlog | 17 | 9 | 8 |
| unit/sort | 53 | 53 | 53 |
| unit/tracking | 13 | 10 | 10 |
| unit/type/hash | 73 | 72 | 70 |
| unit/type/incr | 32 | 31 | 31 |
| unit/type/list | 257 | 237 | 234 |
| unit/type/list-2 | 2 | 2 | 2 |
| unit/type/list-3 | 11 | 11 | 11 |
| unit/type/set | 118 | 114 | 113 |
| unit/type/stream | 75 | 66 | 64 |
| unit/type/stream-cgroups | 59 | 56 | 56 |
| unit/type/string | 82 | 82 | 79 |
| unit/type/zset | 303 | 300 | 298 |
| unit/violations | 1 | 1 | 1 |
| **all** | **1905** | **1812** | **1769 (97.6%)** |

## Why the other 43 fail

Against Redis 7.2.16:

- **29 stop on a command BendKV does not have.** By the number of tests each one stops:
  - SYNC 26: tests that read the replication stream, 12 of them unit/multi's of what a
    transaction propagates and 3 unit/scripting's of what a script propagates;
  - MIGRATE 2 and REPLICAOF 1.
- **One never ran**: it runs only on a server that names jemalloc as its allocator.
- **13 fail with another error.**
  - 3 are streams': the tests that set `stream-node-max-entries`, one of them
    unit/lazyfree's.
  - 7 fail on a client that a test before them left in MULTI: REPLICAOF's, in
    unit/multi.
  - The others fail for what BendKV does not have yet, or has otherwise:
    - COMMAND's entry of a command it does not have: MIGRATE marked movablekeys;
    - the order of a hash Redis keeps in a listpack past the parameters' defaults
      (2, above).

Against 7.0.15, 121 failed: 64 on a command BendKV does not have, 19 that never ran, and
38 with another error, CLUSTER's among them (its subcommands in COMMAND LIST, and called
from a script), which pass since BendKV answers CLUSTER as Redis 7.2.16 answers it with
cluster support disabled.

Before times to live, SET's options failed 30 more tests here, answered `ERR syntax error`.
INFO's statistics per command, which `info-command` looked for, made 3 more tests pass.
SCAN and RANDOMKEY pass all their tests on keys: SCAN's basic iteration, COUNT, MATCH,
TYPE, and its guarantee under a load of writes, and RANDOMKEY's three.

So what the suite counts next is replication, whose SYNC stops 26 tests, then the query
buffer of the third row (2 tests).

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

A cost that grew with the square of a request's length. unit/geo's fuzzing tests send
GEOADDs of 20,000 points, 60,000 arguments in one request, which took BendKV 3.6 to 6.2
s, past the suite's limit (an EXISTS of 40,000 keys took 245 ms): each
argument was read by index in the buffer of the request, a packed String that a read by
index walks from its start a chunk of 2,048 bytes at a time. The arguments of a long
request are read through a window of one chunk now, moved on as the parse goes, so that
its parse takes time in proportion to its length: the GEOADD takes 194 ms, the EXISTS
29 ms (section 3zzn of [FINDINGS.md](FINDINGS.md)).

Bugs in Redis and Valkey. Comparing BendKV with Redis 7.2.16, 8.10.2 and Valkey 9.1.2
found nine bugs in them: LSET takes its index modulo 2^32, a failed AUTH in a pipeline
gets no reply, CONFIG SET tls-port crashes a server built without TLS, CLIENT UNBLOCK with
ERROR counts a WAIT twice, RESTORE with a time to live near 2^63 ms makes a key that
7.0.15 does not, PFADD reads the byte after a sparse HyperLogLog's end (every version),
CLIENT UNBLOCK of a client CLIENT PAUSE holds crashes the server, CLIENT TRACKING
answers an overlap of its prefixes twice, and a client served by a blocking pop does not
wait for its pop in WAIT or WAITAOF (every version). BendKV does not copy them, but for
the sixth, where it reads that byte as 0. [UPSTREAM.md](UPSTREAM.md) has how to see each,
where it is in the code, and where it is to be reported.

A difference kept on purpose. `locale-collate`, new in 7.2, names the locale in which SORT's
ALPHA compares; BendKV compares bytes, as the C locales do, and takes those alone: CONFIG
SET of another answers "Invalid locale name", and a start with one stops (README's
Configuration). No test of the suite sets it. And BendKV has no defragmentation:
`activedefrag yes` fails as it does in a Redis built without its own jemalloc, where a
Redis built from its tarball, as the reference is, turns it on (README's Memory).

Encodings. BendKV holds lists and sets as Redis 7.2.16 holds them at the parameters'
defaults: a small list or set as a listpack, a larger list as a quicklist of the nodes
Redis's would have (README's Lists and Sets). A test that sets `list-max-listpack-size`,
`list-compress-depth` or `set-max-listpack-*` and then checks an encoding sees what the
defaults give. Redis also turns a listpack into a quicklist on an LSET of an index the
list does not have and on an LINSERT whose pivot is not there, and a set into a hashtable
on an SADD that adds nothing, none of which its append-only file holds; BendKV leaves
those as they were, and checks LMOVE's lists where README says.

## What this mode does not test

Tests that need a server of their own do not run in this mode: the units above with no
test, the tests of other units tagged `external:skip`, and all of `tests/integration`
(replication, persistence across restarts, `redis-check-aof`, `redis-cli`, and more).
BendKV starts as `redis-server` starts, with the same command line and configuration
file, so the next step is the suite's own mode with BendKV in place of
`src/redis-server`. Until then BendKV's own tests cover part of that ground: the start
(`tests/start_test.py`, against `redis-server`), restarts from the append-only file
(`tests/aof_test.py`, and after kills under load: `tests/crash_test.py`), starts from
files that straddle the windows the start reads them in, cut short or with a transaction
left open, against `redis-server` (`tests/aof_window_test.py`; where BendKV differs: a
file that ends inside a transaction, then in an entry cut short, BendKV cuts back to
before the MULTI and Redis after the transaction's last whole entry, which its next
start reverts, the databases the same), the RDB file (`tests/rdb_test.py`: files of
Redis's and of BendKV's, each loaded by both, SAVE and the saves of SHUTDOWN and
FLUSHALL; `tests/bgsave_test.py`: BGSAVE, the save points, MISCONF and the count of
changes), and the append-only file's
rewrite (`tests/rewrite_test.py`: BGREWRITEAOF's replies
and INFO's fields against Redis's, the rewritten file against Redis's base, writes during a
rewrite, BendKV and Redis started from the new file; Redis's unit/aofrw is tagged
`external:skip`, and most of it needs `DEBUG LOADAOF`). Redis 7's directory of files,
`appendonlydir`, has `tests/aofdir_test.py`: BendKV and Redis each started on a copy of
the same directory, and rewriting in it, with the same databases, manifests and lines
logged; and the file turned on and off at run time, `tests/aof_switch_test.py`: BendKV
and Redis each on a directory of its own, the file turned on, off and on again (in the
directory and as the single file), with WAITAOF, writes while it turns on, the
rewrites it stops and schedules, the ones that fail, and SHUTDOWN and SIGTERM refused
while it turns on, with the same replies, INFO fields, files, manifests, lines logged and
databases after a restart (FINDINGS 3zzzzx); a start with `appendonly yes` makes the
directory where it is not there, and stops where a file has its name, as Redis does
(FINDINGS 3zzzzzf). Where BendKV differs: a server started with `appendonly no` and no
directory turns the file on and rewrites it as Redis 6's single file, where Redis makes
the directory; BendKV writes its bases as commands whatever `aof-use-rdb-preamble` says; an RDB base followed by commands stops
its start, where Redis loads both; a base or history line whose sequence number is
below 1, or 10^13 or more, is refused; only a base is read as an RDB file, and one that
does not load stops the start, the file left as it was, where Redis may cut it to
nothing; a BGREWRITEAOF whose new incremental file cannot be made is answered as
started, then fails, where Redis answers with an error (FINDINGS 3zzzq).

## Client libraries' test suites

Redis's own suite measures the server; a client library's suite measures what an
application sees through it. `tools/client_suite.py` runs two of them against BendKV and
against Redis 7.2.16 the same way, each at a fixed version taken from its language's
registry, each run against a server started for it, in a directory of its own:

- **redis-py 8.1.0** (PyPI): its tests of the sync and asyncio clients, in RESP2 and in
  RESP3 (`--protocol`), but its tests of modules (JSON, search, time series,
  probabilistic structures, vector sets), clusters, sentinels, TLS and Redis Enterprise's
  services;
- **go-redis v9.23.0** (the Go module proxy): its Ginkgo specs as against one Redis
  Enterprise database (`RE_CLUSTER`, an endpoints file naming the server), so that it
  starts no ring, sentinel or cluster of its own, but its specs of those and of modules.
  It speaks RESP3 (HELLO 3 as it connects), and some of its specs RESP2.

A client's suite is written for the newest Redis: its tests of versions after 7.2 skip
themselves (go-redis is told the server is 7.2), and of the rest what counts is what
Redis 7.2.16 passes. A test that fails runs again up to twice before it counts as
failed, in both suites; one that passes on BendKV only after such a rerun, where Redis
passes it at the first attempt, is reported (a race in BendKV passes so), and from
2026-11-15 on it counts as failed. CI's heavy tier runs the three suites before a pull
request merges, in three jobs
after `build`: a test Redis passes that BendKV fails, and that is not among the known
failures of `tools/data/clients.json`, fails the job; a known failure that passes is
reported, to be taken off the list.
Each known failure is kept with the reason it fails for (the command BendKV does not
have, as "unknown command 'XADD'", or the line of another error, its numbers as `#`),
and one that fails for another reason fails the job too.

```bash
make clients                       # the three suites, against Redis and build/bendkv
```

| suite | Redis 7.2.16 passes | BendKV passes |
|---|---:|---:|
| redis-py 8.1.0, RESP2 | 2,772 | **2,770 (99.9%)** |
| redis-py 8.1.0, RESP3 | 2,772 | **2,770 (99.9%)** |
| go-redis v9.23.0, RESP3 | 463 | **463 (100%)** |

Against Redis 7.0.15 BendKV passed 2,708 of the 2,753 tests it passes in redis-py, and
447 of 460 in go-redis. 7.2.16 passes each of those, and 19 more in redis-py and 3 in
go-redis. BendKV passes all 19 of redis-py's (ACL GETUSER, SETUSER and LOG with 7.2's
fields, CLIENT NO-TOUCH, ZRANK and ZREVRANK with WITHSCORE, and since streams' groups the
four that create a stream's group, `test_xinfo_consumers`, of 7.2, in the sync and
asyncio clients, and `test_xgroup_create_entriesread`) and all 3 of go-redis's
(WITHSCORE's, and WAITAOF's since WAITAOF: section 3zzzzp of [FINDINGS.md](FINDINGS.md)).

redis-py's tests give in RESP3 what they give in RESP2, test by test, against Redis and
against BendKV: the same tests pass, and the same fail. (Its three tests of subscribing
to a server that is down pass or fail from one run to the next, against both servers
alike.)

Every test BendKV fails of those Redis passes fails on what BendKV does not have:

- **A command it does not have:** in redis-py, REPLICAOF 1 (in each protocol); in
  go-redis, none. MODULE (section 3zzzzzb of [FINDINGS.md](FINDINGS.md)) brought
  redis-py's 2 tests of MODULE LIST, of its asyncio client, in each protocol.
  Streams' groups (section 3zzzzt of [FINDINGS.md](FINDINGS.md)) brought redis-py's 45
  tests in each protocol that stopped on XGROUP (40), XACK (3) and XREADGROUP (2), and
  go-redis's 12 of groups (XGROUP's subcommands, XREADGROUP, XACK, XCLAIM, XAUTOCLAIM,
  XPENDING and XINFO GROUPS and CONSUMERS).
  Functions (section 3zzzp of [FINDINGS.md](FINDINGS.md)) brought redis-py's 7 tests of
  FUNCTION and FCALL in each protocol (LOAD, LIST, DELETE, FLUSH, DUMP and RESTORE, FCALL
  and FCALL_RO) and its test of COMMAND LIST, which wants more than 300 commands, and
  go-redis's 6 (FCALL, FCALL_RO, DELETE, FLUSH, FLUSH ASYNC, and KILL of a running
  function). Lua scripts (section 3zzzd of [FINDINGS.md](FINDINGS.md)) brought
  redis-py's 107 tests in each protocol that stopped on EVALSHA, SCRIPT or a script
  BendKV did not run (its locks, which are scripts, its scripting tests and MONITOR's
  test of a script) and go-redis's 9 of EVAL, EVAL_RO and a hook's error. redis-py's 32
  tests of streams that need no group, and go-redis's 13, pass since streams' reads and
  writes (sections 3zzzy and 3zzzza of [FINDINGS.md](FINDINGS.md)), and redis-py's test
  of BGSAVE since the background saves (section 3zzzk). SORT's tests, 37 in redis-py and
  2 in go-redis, pass since SORT (section 3zzh of [FINDINGS.md](FINDINGS.md)), and so
  does go-redis's test of COMMAND GETKEYS, which asks for SORT's keys; redis-py's 9 tests
  of PFADD, PFCOUNT and PFMERGE pass since HyperLogLogs (section 3zzj), its 5 of CLIENT
  PAUSE and UNPAUSE since the pause (section 3zzk), and its 9 of LASTSAVE, LOLWUT, MEMORY
  STATS, MEMORY MALLOC-STATS and ROLE, and go-redis's of WAIT and its filter of commands
  by the ACL category admin (it wants more than 10; BendKV has 37), since the
  administrative commands (section 3zzl); geo's 59 in redis-py and 11 in go-redis pass
  since GEO (section 3zzm), and the 12 tests of DUMP and RESTORE in redis-py and 3 in
  go-redis since DUMP and RESTORE (section 3zzu); redis-py's 9 tests of SLOWLOG and 3 of
  LATENCY, and go-redis's of SLOWLOG, pass since the timing of calls (section 3zzz),
  redis-py's test of CLIENT TRACKING and go-redis's 9 specs of its client-side cache
  since CLIENT TRACKING (section 3zzzb), and redis-py's 34 tests of ACL, of AUTH with a
  user and of CLIENT KILL USER, and go-redis's of ACL CAT, since ACL users (section
  3zzzh).
- **Another error, on the same ground:** redis-py's parser of commands, which asks
  COMMAND for MIGRATE's keys. go-redis's test of XRead, which waits, passes since
  streams' waits (section 3zzzzu of [FINDINGS.md](FINDINGS.md)).

So no test of these suites finds a command BendKV has answering otherwise than Redis.

## Other measures

- The test suites of other client libraries (Jedis, Lettuce, node-redis) run against a
  server given by its address too; their tests ship in no registry as redis-py's and
  go-redis's do, so they need the libraries' repositories.
- [resp-compatibility](https://github.com/tair-opensource/resp-compatibility) (Alibaba's
  Tair team) checks which commands of which Redis versions a server answers as Redis
  does, from a table of cases per command and version; it is used to compare
  Redis-compatible services.
