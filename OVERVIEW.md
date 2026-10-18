# BendKV — a formally verified Redis-compatible KV store in Bend2 (PoC)

The goal is to judge whether a popular open-source database (SQLite, Redis and the like)
can be rewritten in [Bend2](https://github.com/bendlang/bend) so as to get a formally
verified database or cache, and to check this on a small PoC.

Environment: Bend 2.0.35 (`bendlang/bend` @ `1cce499`; the old `HigherOrderCO/Bend2`
now only points to the new repository), Lean 4.34.0 for `--verdict`, clang 19, and
Redis 7.2.16 as the reference.

See also: [docs/FINDINGS.md](docs/FINDINGS.md) (what the work found),
[docs/DIRECTIONS.md](docs/DIRECTIONS.md) (verified databases, compilers, parallelism, and
where the work goes next), [tools/README.md](tools/README.md) (how it was measured).

## In short

- **Rewriting SQLite in Bend2 is not realistic now.** What stands in the way is not only
  the size (~220 thousand lines of C) but also the platform's gaps: no 64-bit integers and
  doubles, no `fsync`, `rename`, locks or writes at an offset, files limited by U32
  (4 GiB), strings as linked lists. Even the best verified stores (IronKV, VeriBetrKV in
  Dafny, FSCQ and DaisyNFS in Coq) are person-years of work, and no verified SQL engine
  at SQLite's level exists.
- **Redis is realistic as "a verified core + a shell checked by tests"** — and the PoC
  confirms it. The result is core code (with the parsing of commands, of their times
  and options, matching against Redis's patterns, several databases, the ranges and bits
  of strings, BITFIELD's 64-bit words), sessions (the state of a connection and of the
  server), hints to the processor, an append-only file (AOF) and configuration (CONFIG by
  Redis's table, which a generator writes), with INFO and COMMAND (its command table from
  a generator) beside them, handwritten proofs, 16-way case splits of the trie written by
  a generator, and the laws: [README.md](README.md#in-numbers) counts the lines of each
  file (not counting comments and blank lines) and the laws. Bend checks the proofs in
  about 14 s, and the BendTT kernel (whose soundness is proved in Lean) in about a minute.
  Recovery after a restart is proved too: a server with an append-only file (AOF in
  Redis's format) restores from the file exactly the databases it held (16 of them, as in
  Redis), and from a file cut by a crash at any byte, the databases after some prefix of
  its acts in which every transaction is whole. On ~266 thousand random commands the
  replies matched real Redis 7 byte for byte; the versions with a 16-child trie passed
  ~1,050 thousand more, of them the current one (with BITFIELD) ~115 thousand. Shards
  across cores and a key hashed once were built and proved, but paid off weakly and were
  taken out for the sake of simpler code (section 14 of PERFORMANCE.md): the code shrank
  by 38%, the proofs by 38%.
- **The price is speed and memory, and most of it has been taken off.** On the original
  Bend, when bound by the CPU (pipeline 16), BendKV was 7–21 times slower than Redis and
  needed ~5 times more memory per key. The cause was the memory model of the Bend
  runtime, not verification. Patches to the Bend compiler
  ([`bend-patches/`](bend-patches/), counted in [README.md](README.md#in-numbers); those
  behind the numbers below: lazy sealing of reference counts, packed strings
  with byte I/O, borrowed reads, native string operations, rebuilding a node in place,
  2 MiB pages for the heap, field selection by digit without a jump table, a string of
  one chunk without a node, a prefetch hint to the processor, several cores: event loops
  on threads of their own, sending to several channels in one step, sending over TCP
  through a writer thread; `epoll` instead of `select`; byte file I/O with `fsync` and
  taking from a channel without waiting, for the append-only file; `code_at` of short
  strings in the term and sends the loop shares with the writer; sends by the loop
  itself while it keeps up; reading a string by index without a slice; `IO` compiled to
  direct continuations; a hint that reaches a buffer's bytes; a record wider than 32
  words as a node of its own) and the reworking of BendKV's hot paths gave the following:
  - by Redis's own benchmarks (its specs for `memtier_benchmark`, section 7.15 of
    PERFORMANCE.md) on a million keys, the server on one core: loading with 100-byte
    values at 1.39 of Redis's throughput, GET with pipeline 10 at 1.26, with pipeline 100
    at 1.36, INCR at 1.00, GET without pipelining at 0.90;
  - on two cores, with a writer thread sending the replies (section 7.16): loading at
    **1.94** of Redis, GET with pipeline 10 at **1.61**, with pipeline 100 at 1.39, INCR
    at 1.27, GET without pipelining at 1.11. Redis with `io-threads 2` on the same cores
    gives 0.99–1.22 of its single-threaded self. Shards across cores (there were some
    until section 14) paid off on two cores only without pipelining (1.19), and with a
    pipeline one loop with a writer is faster, because terms that pass between cores cost
    more than parallel work on the map;
  - with `epoll` instead of `select` (the eleventh patch, section 7.17), GET without
    pipelining on the same two cores is at **1.27** of Redis (1.15 with `select` in the
    same series), with 30% less OS kernel time per request. On three server cores one
    loop with a writer gives 897 thousand GET/s with pipeline 10, 2.06 of Redis with
    three io-threads (three shards gave 816 thousand then). A build with a profile
    (`make pgo`) adds 1–4%;
  - at pipeline 16 on a filled database of 100 thousand keys (`redis-benchmark` with
    3-byte values: the best case for BendKV) BendKV is faster than Redis: **GET 1.62** of
    its throughput, **SET 1.82**, **INCR 1.45** (it was 0.08–0.14). On a million keys,
    1.65, 1.80 and 1.17. This came with the batch hints to the processor: before them it
    was 1.17–1.21, 1.10–1.15 and 0.95–0.96 at 100 thousand keys and 1.02–1.14, 1.06–1.24
    and 1.04–1.12 at a million (from series on two days on different VMs). At a thousand
    keys, where everything is in the cache anyway, 1.09, 1.13 and 0.95;
  - without the hints there are fewer instructions per request than in Redis: on GET
    3,280 against 3,549, on SET 3,985 against 4,773, on PING 2,172 against 2,438; on
    INCR, 4,209 against 3,948. There are fewer L2 misses on GET and SET too: 2.4 and 2.8
    against 2.7 and 3.3. The hints add 14–17% of instructions (GET 3,834) but hide ~85%
    of the memory waits;
  - without pipelining BendKV holds 118–132% of Redis's throughput;
  - it needs half the memory per key that Redis does: ~63 bytes against ~128 on ~950
    thousand keys (60 MB of RSS against 121 MB) with 3-byte values; with 100 bytes, 192
    bytes against 221 (0.87 of Redis), and reads do not add to it (before section 7.25 of
    PERFORMANCE.md the first GET of a value added 8 bytes to it);
  - SET of a 1 MB value takes 4.4 ms, GET 1.4 ms (Redis: ~1 ms);
  - with the append-only file (AOF, section 7.19) at `everysec`, the default of both,
    BendKV with pipeline 16 is faster than Redis with the same log: SET **1.96** times,
    INCR 1.76, GET 1.74; at `always`, 1.15–1.73 times. Without pipelining at `always`
    they are equal: both are bound by `fdatasync`, and both merge the clients' requests
    into one sync. A log of a million SETs BendKV reads in 1.62 s, Redis in 1.24 s;
  - by Redis's specs on two server cores, all with an append-only file at `everysec`:
    BendKV at 1.17–1.87 of Redis (section 7.21; two shards with logs gave 1.02–1.71, and
    without pipelining they were 1.3–1.5 times faster than one loop). BendKV restores a
    log of a million SETs in 1.05 s, Redis in 1.38 s in the same series;
  - after five steps along the profile's breakdown (section 7.23 of PERFORMANCE.md:
    cheaper RESP parsing, long reads in windows, the loop sharing sends with the writer,
    effects in pairs; hints over the actor's whole group were built, measured and taken
    out) there are 8–9% fewer instructions per request at pipeline 16, 19% fewer without
    a pipeline and 44–54% fewer at pipeline 100. By Redis's specs on two cores: loading
    at **1.93** of Redis, GET with pipeline 10 at 1.46, without pipelining at **1.37**,
    with pipeline 100 at **1.69**, INCR at 1.43 (in the same series before the steps:
    1.73, 1.43, 1.23, 1.35 and 1.39). Without pipelining under `redis-benchmark` (one
    client thread) Redis was faster: BendKV with its writer at ~0.80 of it;
  - after three more steps (section 7.24 of PERFORMANCE.md) that gap is closed: the
    loop sends its replies itself while it keeps up with its sockets, and without
    pipelining under `redis-benchmark` BendKV is at 0.93–1.05 of Redis on GET and
    0.90–0.98 on SET (three series). A request is parsed straight into a command,
    together with the key's hash and a proof that the hash fits, and `IO` compiles to
    direct continuations: together that is another 10–14% of instructions (GET 2,969, SET
    3,534, INCR 3,830 at pipeline 16), but in time it is less than the noise — the kernel
    is now about half of a request's CPU. By Redis's specs on two cores: loading at
    **2.25** of Redis, GET with pipeline 10 at 1.62, without pipelining at 1.37, with
    pipeline 100 at **1.95**, INCR at 1.39; at pipeline 16 on one core, **1.86, 1.83 and
    1.54** on GET, SET and INCR.

  Where to look was shown by a time profile taken by sampling on a timer
  ([`tools/sprof.c`](tools/sprof.c)). Strings of up to 6 bytes lie right in the term
  word, and the value `"xxx"` costs not a single miss; a string of one chunk is the
  buffer itself, and a key comparison costs one miss, as in Redis. Before each batch
  BendKV walks the paths of all its keys level by level, only starting to load the next
  level (`Mem.prefetch`), and the misses of different keys overlap; the law
  `batch_hints` proves that this changes nothing. On one core BendKV is slower than
  Redis where there are no batches: GET without pipelining (0.90; the path of a single
  command through the connection, the channel and the actor costs more than Redis's) and
  INCR on a small database (0.95 at a thousand keys). The detailed analysis and the plan
  are in [PERFORMANCE.md](docs/PERFORMANCE.md).
- **What "verified" means.** It is proved that the Bend *source code* satisfies the
  laws. The Bend compiler (by the project's README, 99% written by AI and not audited),
  its C runtime, clang and the OS stay in the trusted base. This is not end-to-end
  verification in the spirit of CompCert/seL4.
- Bend2 **no longer uses HVM** — it has its own runtime, BendRT
  (C/CUDA/Metal/JS).

## Assessing the candidates

| Candidate | Size of the original | What it needs from the platform | Blockers in Bend2 today | Verdict |
|---|---|---|---|---|
| **SQLite** | ~220k lines of C/H in `src/` (B-tree 11.7k, pager 7.9k, WAL 4.8k, VDBE 9.6k) | 64-bit INTEGER and REAL, files > 4 GiB, writing pages at an offset, `fsync`, locks, SQL parsing (mutual recursion) | No I64/F64 (F32 is axiomatic: nothing can be proved about it). Files: only open/read/read_at/size/write/close, U32 offsets, no `fsync`/`rename`/lock. No mutual recursion. Strings are lists | **No.** A sensible step: a verified core of tables (an in-memory B+-tree + relational algebra) |
| **Redis** | ~212k lines of C/H, 240 commands in 7.0.15 (the string ones, `t_string.c`, ~1.7k lines) | A hash table, binary-safe strings, int64, RESP, an event loop, AOF/RDB, TTL | int64 → integers were limited to 14 digits at first; a long long is now kept as two parts below 2^48 (FINDINGS.md, section 3zzv). Persistence in stock Bend is blocked by the lack of `fsync` (patch 12 adds it; an AOF with proved recovery is done). TTL needs a model of time | **Yes, in parts.** The semantics of commands is a pure function `(command, state) → (reply, state)`, ideal for proofs. The PoC is done |
| **A memcached-like cache** | Smaller than Redis | GET/SET/DELETE/INCR, LRU eviction | The same as Redis's, plus proofs of the eviction policy | **Yes.** Simpler still than Redis |
| **An LMDB/LevelDB-like embedded on-disk KV** | ~10–30k lines | An on-disk B+-tree/LSM, atomic commits, recovery after a crash | No `fsync`/`rename`/writes at an offset. Needs a crash model (like Crash Hoare Logic in FSCQ) | **Not now.** Needs effects of its own in C and a disk model of its own |

## What was done: BendKV

A Redis-compatible in-memory server (RESP2 and RESP3). `redis-cli` and `redis-benchmark`
work, and so do clients that speak RESP3 when the server takes it (go-redis v9, Lettuce).

```
src/server.bend  TCP, connections, database actor, AOF file, log ─┐ not verified (@unsafe loops),
src/startup.bend command line and configuration file              │ checked by tests
src/info.bend    INFO, SLOWLOG, LATENCY: as Redis keeps them      │
src/command.bend COMMAND: BendKV's command table from Redis       │
src/resp.bend    RESP parsing, RESP2 and RESP3 replies           ─┘
src/session.bend connection and server: state, a whole batch     ─┐ verified:
src/config.bend  parameters, CONFIG GET and SET                   │
src/aof.bend     AOF: batch effects, write, read, replay          │ proof/LAWS.bend
src/batch.bend   a batch with hints to the processor              │ + proof/PROOF.bend
                                                                  │ (+ proof/SPEC.bend)
src/redis.bend   command semantics: exec(cmd, db) → (reply, db')  │
src/map.bend     hash trie with string keys                      ─┘
src/float.bend   double and long double in software (checked against glibc)
src/hll.bend     HyperLogLogs on a string's bytes, as Redis's (checked by tests)
src/geo.bend     geohashes, cells, distances and sorts, as Redis's (checked by tests)
src/lolwut.bend  LOLWUT's drawings, as Redis draws them (checked by tests)
src/rdb.bend     the RDB format: DUMP, RESTORE and the file, as Redis's (checked by tests)
src/aofdir.bend  the manifest of Redis 7's append-only directory, as Redis's (checked by tests)
```

**Commands:** PING, ECHO, GET, SET, SETNX, GETSET, DEL/UNLINK, EXISTS, INCR, DECR, INCRBY,
DECRBY, APPEND, STRLEN, MGET, MSET, MSETNX, RENAME, RENAMENX (the key's time moves with
it), COPY (DB and REPLACE; the key's time is copied with it), DBSIZE, KEYS (Redis's
patterns: `*`, `?`, classes `[...]`, escaping with `\`; matching as Redis's
`stringmatchlen` does it, with its cut-offs that keep a pattern's cost polynomial, and
with its limit of 1,000 nested stars, past which nothing matches), TYPE, TOUCH, SCAN
(MATCH, COUNT, TYPE; with Redis's guarantee: a key that was in the database for the
whole iteration is found by it, however the database changed meanwhile) and RANDOMKEY
(the key is chosen the same way Redis chooses it).
OBJECT (ENCODING, REFCOUNT, IDLETIME, FREQ, HELP): ENCODING and REFCOUNT answer by the
value, BendKV keeps no encodings. ENCODING is how Redis encodes a value set whole (and a
value made by APPEND, SETRANGE or SETBIT is `raw` in Redis), REFCOUNT follows Redis's
shared integers under the current eviction policy; IDLETIME and FREQ by when the key was
last touched (see "Memory" below), with a refusal under the policy under which Redis
refuses. TIME is the time the batch runs at,
to the millisecond.
Floating-point numbers: INCRBYFLOAT and HINCRBYFLOAT compute as Redis 7.2.16 does on
x86-64: the value and the increment are read as glibc's strtold reads them, added as the
x87 long double adds them, and the sum is written as `"%.17Lf"` writes it, without
trailing zeros in the fraction; an infinite sum is refused. `src/float.bend` does C's
double and x87's long double in software (Bend has only a 32-bit floating-point number):
reading as strtod and strtold do, writing as `"%.17g"` and `"%.17Lf"` do, addition and
multiplication with rounding to nearest, as the FPU does; `make test` checks the library
against glibc on random numbers. INCRBYFLOAT goes to the append-only file as a SET of
the sum with KEEPTTL, and HINCRBYFLOAT as an HSET of the field, as Redis propagates them.
Ranges and bits: GETRANGE (and SUBSTR), SETRANGE, GETBIT, SETBIT, BITCOUNT and BITPOS
(with ranges in bytes and in bits, BYTE and BIT): numbers are read as Redis reads them,
and errors come where Redis gives them; a value grows to 512 MB at most (the default
proto-max-bulk-len). SETRANGE and SETBIT log a SETRANGE of the bytes written, not the
whole value. BITOP (AND, OR, XOR, NOT; logged as a SET of its value) and LCS (LEN, IDX,
MINMATCHLEN, WITHMATCHLEN; the table is limited by proto-max-bulk-len, as in Redis, and
is computed slowly, about twenty times longer than in Redis). BITFIELD and BITFIELD_RO:
fields of up to 64 bits, signed and unsigned, at an offset in bits or `#k`, with GET,
SET, INCRBY and OVERFLOW WRAP, SAT and FAIL, in C's 64-bit arithmetic, as in Redis;
logged as a SETRANGE of the bytes its writes reached. A field across the 2^32nd bit,
for which Redis grows a value past 512 MB, is refused with SETRANGE's error.
Hashes: HSET, HMSET, HSETNX, HGET, HMGET, HDEL, HLEN, HSTRLEN, HEXISTS, HKEYS, HVALS,
HGETALL, HINCRBY, HINCRBYFLOAT, HSCAN (MATCH, COUNT) and HRANDFIELD (with a count, with
repeats when it is negative, WITHVALUES; chosen by the server's random numbers);
arguments and errors as in Redis. While a hash is small (at most 512 fields, fields and
values no longer than 64 bytes: Redis's default listpack limits), BendKV keeps its
fields in order of arrival, and past that in a trie of its own, for good, as Redis
converts a listpack to a hashtable: HSCAN returns a small hash whole with cursor 0, a
large one bucket by bucket. OBJECT ENCODING answers `listpack` or `hashtable`, as Redis
would answer under the current parameters; string commands answer WRONGTYPE on a hash,
and hash commands on a string. MEMORY USAGE (SAMPLES) estimates a key's size in bytes.
A write to a hash is logged as an HSET of the pairs set or an HDEL of the fields removed
(HINCRBY and HINCRBYFLOAT as an HSET of the sum); a hash made where an expired key still
lay, as one EVAL entry with a constant script that deletes the key and sets the pairs:
Redis runs it at load, BendKV parses it back (Redis itself writes a MULTI with DEL and
HSET, two entries between which the file may be cut). BendKV's parser reads this script,
and the like scripts of lists, sets and sorted sets (below), as the commands they stand
for; any other script runs on the engine (Scripts, below).
Lists: LPUSH, RPUSH, LPUSHX, RPUSHX, LPOP and RPOP (with a count), LLEN, LINDEX, LRANGE,
LSET, LINSERT, LREM, LTRIM, LPOS (RANK, COUNT, MAXLEN, as Redis 7.2.16 reads them,
including a RANK equal to LLONG_MIN), LMOVE, RPOPLPUSH and LMPOP; arguments and errors
where and as in Redis (a count and an index may be any long long). A list is a deque of
two stacks, so that adding and removing at either end costs O(1) on average, and LINDEX
and LRANGE go from the nearer end; a key holds no empty list. Beside it a list keeps how
Redis 7.2.16 holds it, a listpack while it is small and a quicklist past 8 KB, each
node's count and bytes moved as Redis moves its nodes, so that OBJECT ENCODING answers
`listpack` or `quicklist` and DUMP writes Redis's nodes (README's Lists says where
BendKV differs); MEMORY USAGE estimates its size. A
write to a list is logged as the write itself (LMPOP as an LPOP or RPOP, with a count,
of the key it popped from; popping the last elements as a DEL of the key); a list made
where an expired key still lay, as an EVAL entry of the same script as for hashes, with
the pushes, and a move onto such a key as one EVAL entry of a constant script that
deletes the destination and runs LMOVE: Redis runs them at load, BendKV parses them
back. The blocking BLPOP, BRPOP, BLMOVE, BRPOPLPUSH and BLMPOP are below (clients that
wait).
Sets: SADD, SREM, SCARD, SISMEMBER, SMISMEMBER, SMEMBERS, SSCAN (MATCH, COUNT), SPOP and
SRANDMEMBER (with a count, with repeats when it is negative; chosen by the server's
random numbers in the same ways as in Redis), SMOVE, SINTER, SUNION, SDIFF, SINTERSTORE,
SUNIONSTORE, SDIFFSTORE and SINTERCARD (LIMIT); arguments and errors where and as in
Redis. A set is an intset while all its members are canonical 64-bit integers and there
are no more than 512 of them, a listpack (its members in one string, in the order they
came) while it holds at most 128 of at most 64 bytes, and past that a trie of its own,
for good, as Redis 7.2.16 converts them, SADD sizing its set by its count of members as
Redis does: an intset returns its members in ascending order, a listpack in its own, and
SSCAN returns either whole with cursor 0, as in Redis. OBJECT ENCODING answers `intset`,
`listpack` or `hashtable`; MEMORY USAGE estimates the size, and a key holds no empty
set. A write
to a set is logged as its SADD or SREM (SPOP as an SREM of the members popped, or a DEL
of the key if it popped the last ones; STORE as an SADD of the resulting members, or a
DEL of the destination if there are none); a set made where the key had an entry (a
STORE's destination, an expired key), as an EVAL entry of the same script as for hashes,
with SADD, and an SMOVE onto an expired key as one EVAL entry of a third constant script
that deletes the destination and runs SMOVE.
Sorted sets: ZADD (NX, XX, GT, LT, CH, INCR), ZINCRBY, ZREM, ZCARD, ZSCORE, ZMSCORE,
ZRANK and ZREVRANK (WITHSCORE), ZCOUNT, ZLEXCOUNT, ZRANGE (BYSCORE, BYLEX, REV, LIMIT,
WITHSCORES), ZRANGEBYSCORE, ZREVRANGEBYSCORE, ZRANGEBYLEX, ZREVRANGEBYLEX, ZREVRANGE,
ZREMRANGEBYRANK, ZREMRANGEBYSCORE, ZREMRANGEBYLEX, ZPOPMIN and ZPOPMAX (with a count),
ZMPOP, ZRANDMEMBER (with a count, with repeats when it is negative, WITHSCORES; chosen
by the server's random numbers), ZSCAN, ZUNION, ZINTER, ZDIFF and their STORE forms,
ZINTERCARD (LIMIT) and ZRANGESTORE; arguments and errors where and as in Redis. Scores
are doubles, read, written, compared and added as in C (`src/float.bend`), with Redis's
rules for infinities. A sorted set keeps its elements in Redis's order (by score, then
by member): while it is small (at most 128 elements, members up to 64 bytes: Redis's
default listpack limits) in one string, each element its member and its score's 8 bytes,
or in a weight-balanced tree once that string would pass one buffer of the runtime
(2,048 bytes), and past the limits in the tree with a trie of its members beside it, for
good, as Redis converts a listpack to a skiplist (and from a ZADD of more than 128
pairs, however many members they hold, as Redis 7.2.16 does): a small one answers as a
listpack does in Redis (it never holds a score of `-0`, a range by member is walked from
the first element, ZSCAN returns it whole with cursor 0, integer scores as digits).
OBJECT ENCODING answers `listpack` or `skiplist`, MEMORY USAGE estimates the size, and a
key holds no empty sorted set. A write is logged as the command the client sent (ZINCRBY
as ZADD INCR, ZADD's options in one order, ZMPOP as a ZPOPMIN or ZPOPMAX of the key it
popped from; popping the last elements as a DEL); a sorted set made where the key had an
entry (a STORE's destination, an expired key), as one EVAL entry of a fourth constant
script that deletes the key and runs a ZADD of its elements. A STORE's destination is
the sorted set Redis makes (ZUNIONSTORE's, ZINTERSTORE's and ZDIFFSTORE's a skiplist
turned a listpack when it fits, ZRANGESTORE's sized by a range of ranks, grown from a
listpack for one of scores or members), and keeps a `-0` score where Redis does. A ZADD
of more than 128 pairs that adds and changes nothing leaves a listpack as it was, where
Redis makes it a skiplist. The blocking BZPOPMIN, BZPOPMAX and BZMPOP are below.
Sorting: SORT and SORT_RO (BY, LIMIT, GET, ASC, DESC, ALPHA and, in SORT, STORE), the
options read in order and the errors where and as in Redis, all before WRONGTYPE. The
elements of a list, a set or a sorted set are sorted as doubles read as Redis reads them
with strtod, or with ALPHA by their bytes up to the first NUL (all of them in a STORE), by
their own values or by those a BY pattern names (a key's string, or a hash's field after
`->`); a BY without a `*` keeps a list's or a sorted set's order; GET answers what its
patterns name. The sort is a stable merge sort, as glibc's qsort, which Redis calls, is.
STORE writes a new list over its destination, or deletes it when there is nothing, and is
logged as that list. Where it differs from Redis: a set kept as a hashtable comes in
BendKV's order, elements whose weights tie under a LIMIT with BY in a stable sort's order
(Redis's pqsort is not stable), ALPHA as in the C locale, no range error left over in
errno from an earlier SORT, and a small sorted set stays a listpack after a SORT.
HyperLogLogs: PFADD, PFCOUNT, PFMERGE, PFDEBUG and PFSELFTEST, on a string's bytes as
Redis 7.2.16 keeps them: Redis's header and registers, dense or sparse, every value
written byte for byte as Redis writes it, and the count as Ertl's estimator in Redis
makes it, on doubles in software. A corrupt sparse value is judged as Redis 7.2.16
judges it, with the fix of CVE-2025-32023. PFADD, PFCOUNT of one key and PFDEBUG are
logged as the changes they make, PFMERGE as the SET of its destination. Where it differs
from Redis: while `hll-sparse-max-bytes` is not 3,000 every command runs one at a time,
a file of Redis's runs its PFADD and PFMERGE with the parameter at 3,000, PFSELFTEST
checks fewer cases, the byte past a sparse string's end is 0 as each command starts
(Redis keeps what a set wrote there), a PFADD that a corrupt value stops keeps its
change with an event and a log, and a HyperLogLog of up to 44 bytes is `embstr` to
OBJECT ENCODING.
GEO: GEOADD, GEOPOS, GEOHASH, GEODIST, GEORADIUS and GEORADIUSBYMEMBER with their `_RO`
forms, GEOSEARCH and GEOSEARCHSTORE, as Redis 7.2.16's `geo.c` runs them: a position is
a member of a sorted set whose score is its 52-bit geohash, GEOADD is the ZADD of its
scores (and is logged as that ZADD), and a search reads the nine cells Redis reads, keeps
the points within its circle or its box by their haversine distances, sorts them as
glibc's qsort does, or as Redis's pqsort does when COUNT keeps fewer than it found, and
answers each with Redis's text (four decimals of a distance, `%.17Lf` of a coordinate).
Its doubles are C's: Bend's base runs them on the CPU and its libm (patch 33), so a
distance is the double Redis computes on the same libm. A search's options and errors
come in Redis's order; STORE, STOREDIST and GEOSEARCHSTORE write their destination as a
sorted set, or delete it when they find nothing (section 3zzm of docs/FINDINGS.md).
DUMP and RESTORE: a value's payload as Redis 7.2.16 writes it with `rdbcompression no`
(the value as RDB encodes it, version 11 of the format, the CRC64), byte for byte
Redis's where both hold the value alike; RESTORE reads every type Redis 7.2.16 reads but
modules' (LZF's strings, ziplists, zipmaps, quicklists of ziplists and streams too),
makes the value of the kind Redis's load makes, checks a payload as deep as Redis does
with `sanitize-dump-payload yes`, and takes REPLACE, ABSTTL, IDLETIME and FREQ, its
errors in Redis's order and its keyspace events Redis's. It is logged as a RESTORE with
REPLACE and ABSTTL (section 3zzu of docs/FINDINGS.md). A stream is a value BendKV holds,
from RESTORE and the RDB file, its nodes Redis's listpacks byte for byte, with its groups
(section 3zzzu of docs/FINDINGS.md); XLEN, XRANGE, XREVRANGE, XREAD, XINFO and XPENDING
read it, and XADD, XTRIM, XDEL and XSETID write it, as Redis does (sections 3zzzy and
3zzzza); the commands of groups and XREAD's wait are not there yet.
The RDB file, as Redis 7.2.16 writes and reads it: SAVE writes it (`temp-<pid>.rdb`,
synced, renamed onto `dbfilename`, the directory synced), SHUTDOWN saves it with SAVE or
with save points, FLUSHALL with save points saves the emptied databases, and the start
loads it with `appendonly no`: every version from 1 to 11 and every encoding the codec
reads, keys whose time has passed dropped and counted, Redis's lines for a file that does
not load. BGSAVE writes it in the background, from a snapshot of the databases at the
command, a slice at a time between the groups the server answers (the databases are
values: no fork), and so does the cron at the save points, Redis's by default
(`3600 1 300 100 60 10000`), counting the changes since the last save as Redis counts
them; a background save that fails stops the writes (MISCONF) until a save ends well.
SIGTERM and SIGINT run SHUTDOWN's shutdown, as Redis's handler has them run it. No LZF
or IDLE and FREQ written (sections 3zzzc, 3zzzf and 3zzzk of docs/FINDINGS.md).
Clients that wait: BLPOP, BRPOP, BLMOVE, BRPOPLPUSH, BLMPOP, BZPOPMIN, BZPOPMAX and
BZMPOP; their timeout (seconds, a double; 0 means wait forever) is read as Redis reads
it, with its errors. A command that has nothing to pop makes the client wait, and its
call is counted at that moment, as in Redis; the commands the client sent after it wait
with it and run when it is served. After each command the waiting clients are served in
order of arrival while a key holds what one of them waits for: the pop is made on that
key and logged as the command that makes it (LPOP or RPOP with a count, LMOVE, ZPOPMIN
or ZPOPMAX); a client whose time is up gets an empty array at the nearest tick of the
cron (that is Redis's precision too); CLIENT UNBLOCK ends a wait with an empty array
(TIMEOUT) or with the UNBLOCKED error (ERROR); a client that closed its connection while
waiting is forgotten. `blocked_clients` and `clients_in_timeout_table` in INFO count
them, and failed calls and errors are counted as Redis counts them. A command with
replies turned off (CLIENT REPLY OFF or SKIP) pops as it does with them on. Where BendKV
differs: Redis serves the clients of the keys a command added (`signalKeyAsReady` from
`dbAdd`), key by key in order of readiness, while BendKV looks at all waiting clients,
in order of their arrival, after each command that may make one ready (one that may
write a key a client waits on, or a command of the connection or of the server); there
is no XREAD, and WAIT's wait ends only by its time or CLIENT UNBLOCK (below). In a
transaction a blocking command does not wait, as in Redis (below).
Transactions: MULTI, EXEC, DISCARD, WATCH and UNWATCH, as Redis 7.2.16 runs them. After
MULTI a command is queued (QUEUED), except EXEC, DISCARD, MULTI (an error: transactions
do not nest), WATCH (an error inside MULTI), QUIT and RESET, which run; a command refused
when queued (an unknown command, a wrong number of arguments, NOAUTH) makes EXEC's reply
the EXECABORT error, and an EXEC that is itself refused aborts the transaction with its
reason. EXEC runs the queue as one whole: the commands' replies are its array (an error
while running a command goes into it), waiting clients are not served between the
commands, and a blocking command in the queue answers at once. A watched key that any
command changed, or that lies with its time passed by EXEC, makes EXEC's reply an empty
array. A change is what Redis counts as a change: a write that changes the key, a DEL of
a key that is there, FLUSHDB, FLUSHALL and SWAPDB of a database where it is, MOVE, COPY,
RENAME, the sweep of expired keys; a key watched after its time changes only when it is
written again (its deletion is not a change). EXEC, DISCARD, UNWATCH, RESET and a closed
connection remove the watch. Calls are counted as Redis counts them (a queued command
when EXEC runs it, EXEC itself once). A transaction's effects go to the append-only file
between MULTI and EXEC when there are two or more of them, as Redis writes them. Where
BendKV differs: an LTRIM that deleted nothing does not change a watched key (Redis
signals it all the same), and a DEL of a missing key is logged (BendKV logs every DEL),
so a transaction with one can land between MULTI and EXEC where Redis writes its single
other effect on its own.
Pub/Sub: SUBSCRIBE, UNSUBSCRIBE, PSUBSCRIBE, PUNSUBSCRIBE, SSUBSCRIBE, SUNSUBSCRIBE,
PUBLISH, SPUBLISH and PUBSUB (CHANNELS, NUMSUB, NUMPAT, SHARDCHANNELS, SHARDNUMSUB, HELP),
as Redis 7.2.16 runs them. Each name gets a reply with the client's count of channels
and patterns (of shard channels for SSUBSCRIBE and SUNSUBSCRIBE); a message goes to the
subscribers of its channel (`message`, `smessage` for a shard channel), then to the
subscribers of each matching pattern (`pmessage`), and PUBLISH answers how many clients
got it. A subscribed client of RESP2 runs only (P|S)SUBSCRIBE, (P|S)UNSUBSCRIBE, PING,
QUIT and RESET, as in Redis, and any other command is refused with Redis's error; one of
RESP3 runs any command, and its messages are pushes among its replies (its own messages,
keyspace events and invalidations after the reply of the command that made them, after
EXEC's or a script's for the commands they ran, as Redis 7.2 sends them); the replies of
SUBSCRIBE and its kin go out even with replies turned off; in a
transaction SUBSCRIBE and PSUBSCRIBE run, and SSUBSCRIBE is refused; RESET, QUIT and a
closed connection remove the client's subscriptions. Keyspace notifications: when
`notify-keyspace-events` is set, each change a command makes is published to
`__keyspace@<db>__:<key>` and `__keyevent@<db>__:<event>` with Redis's event names
(`new` for a key created, `del` for a collection emptied, `expired` from the sweep,
`evicted` from an eviction, and the pop of a waiting client that was served comes after
the write that served it). Where
BendKV differs: UNSUBSCRIBE of all goes in order of subscription, and PUBSUB CHANNELS in
the trie's order, whereas Redis goes in the order of its hash tables; a slow subscriber
has no `client-output-buffer-limit pubsub` limit; there are no events for misses (`m`)
or streams; a key that a read found with its time passed sends `expired` when the sweep
deletes it, and Redis at the read.
Clients: CLIENT LIST (all, those of one TYPE, by ID numbers), CLIENT INFO and CLIENT
KILL (the old form with an address, and the filters ID, TYPE, ADDR, LADDR, USER and
SKIPME), as Redis 7.2.16 runs them, with its errors. A client's line has Redis's fields
in its order: the id, the address and the local address, the socket's fd, the name, the
age and the idle time, the flags (P subscribed, x in MULTI, b waiting, d a watched key
touched, e NO-EVICT on, T NO-TOUCH on, N nothing), the database, the count of subscriptions, the queued
commands, the bytes of the batch and of the arguments of the running command (for a
waiting client, of the blocking one), the full name of the last command (while the
client waits, the blocking one; while EXEC runs a transaction, EXEC, with the client in
MULTI) and the library CLIENT SETINFO names, which RESET keeps. A killed client is cut off at once, wherever it waits (its socket is shut down),
its transaction, wait and subscriptions are removed, and what it waited for stays as it
was; the old form and SKIPME no kill the client itself too, after its reply, and in a
transaction after its end. Where BendKV differs: it has no buffers per client, and their
sizes are 0 (qbuf-free, multi-mem, rbs, rbp, obl, oll, omem, tot-mem), as is another
client's qbuf (the commands after a blocking one lie in the query buffer in Redis, and
as commands in BendKV); idle time counts from the client's last batch, while Redis also
counts a reply written (to a subscriber that gets messages, to a client that waited);
user is `default`, redir -1, resp 2.
MONITOR, as Redis 7.2.16 runs it: every call after it, by any client, sends each monitor
a line `+<s>.<µs> [<db> <ip:port>]` with the call's arguments as the client sent them,
in quotes as Redis puts them. As in Redis, a command refused before it runs (unknown,
with a wrong number of arguments, before AUTH, to a subscribed client) sends no line,
nor do the administrative commands (CONFIG, CLIENT LIST, KILL, NO-EVICT and UNBLOCK);
EVAL and its kin send theirs before their script runs, and each call of the script its
own, from `[<db> lua]`; a command from a transaction's queue sends its line when EXEC
runs it, a blocking
one when it blocks, and the password of AUTH and the user and password of HELLO are
replaced by `"(redacted)"`. A monitor is refused the commands that read or write keys
("ERR Replica can't interact with the keyspace"); it gets its own line after the reply,
and with CLIENT REPLY OFF or SKIP it gets no lines; RESET, QUIT and CLIENT KILL remove
it, and CLIENT LIST shows it with the flag O. Where BendKV differs: a line's time is the
time of the actor's group, in ms (the microseconds end in 000), and a monitor gets the
lines of the calls EXEC runs after EXEC's array, whereas Redis writes them between its
replies.
The server's administrative commands, as Redis 7.2.16 answers them on a master with no
replica: LASTSAVE (the last save that ended well, the start until one does), ROLE, WAIT (0: at once
when it asks for no replica, otherwise when its timeout ends, its client waiting as a
blocking command's does), MEMORY STATS, DOCTOR, PURGE and MALLOC-STATS (Redis's fields
and advice from the numbers of INFO's memory section; no allocator's statistics), LOLWUT
(Redis 7.2.16's line, and VERSION 5's and 6's drawings, byte for byte those that take
no random number), and SHUTDOWN with its flags: the append-only file written and synced,
a rewrite or a background save that runs stopped, the RDB file saved with SAVE or with
save points and not with NOSAVE (a save that fails stops nothing, Redis's error
answered, but with FORCE), the pid file removed, the process ended with code 0 (sections
3zzl, 3zzzc and 3zzzk of docs/FINDINGS.md). CLUSTER answers as Redis 7.2.16 answers it with
cluster support disabled, for each of its subcommands, HELP and MYSHARDID among them, once
its number of arguments is Redis's (section 3zzzzi).
Times to live: EXPIRE, PEXPIRE, EXPIREAT and PEXPIREAT (with NX, XX, GT, LT), TTL, PTTL,
EXPIRETIME, PEXPIRETIME, PERSIST; SET with NX, XX, GET, EX, PX, EXAT, PXAT and KEEPTTL;
SETEX, PSETEX, GETEX (EX, PX, EXAT, PXAT, PERSIST) and GETDEL. Times are read as Redis
reads them, with its errors, and a key expires at its time for every command. An
expired key is deleted by the write that comes to it, or by the sweep of expired keys
ten times a second (it logs a DEL, as Redis does); until then DBSIZE and INFO's keyspace
line count it, while Redis deletes it also when a read comes to it. A time of 10^14 ms
(the year 5138) or later gives the key no time at all.
Databases: 16 of them, or as many as `databases` says, as in Redis: SELECT, MOVE (the
key with its time), SWAPDB, FLUSHDB and FLUSHALL (with ASYNC/SYNC, which empty at once),
with Redis's errors for a wrong number; INFO's keyspace has a line for each database
with keys, and the sweep of expired keys goes over all databases.
The connection: HELLO (2 or 3; with AUTH and SETNAME), AUTH (a password, or a user and
its password), SELECT, QUIT, RESET (selects database 0 again, RESP2 and the default
user), CLIENT ID,
GETNAME, SETNAME, SETINFO, REPLY ON/OFF/SKIP, NO-EVICT, NO-TOUCH (the client's commands
leave the keys' access times and counters as they were, but TOUCH's, and its scripts'
calls, TOUCH's too), TRACKING
(client-side caching: the keys a
client read, invalidated when they change, as Redis's tracking.c; section 3zzzb of
FINDINGS.md), CACHING, GETREDIR, TRACKINGINFO, UNBLOCK (TIMEOUT or ERROR), LIST, INFO,
KILL, HELP. A client must be authenticated where Redis requires it:
after the check of the command's name and number of arguments and before it runs (a
syntax error for an unauthenticated client is NOAUTH); a client is authenticated on
connecting and on RESET if the default user is on and takes no password then, and after
AUTH or AUTH in HELLO, and nothing else changes that. While it must authenticate, its
requests are read with Redis's limits: 10 arguments, and bulks of 16384 bytes (section
3zzzzn of FINDINGS.md).
ACL: users as Redis 7.2.16 keeps them, set by ACL SETUSER (selectors, key patterns with
what each may do, channels, passwords kept as SHA-256, Redis's errors) and read by
GETUSER, LIST, USERS, WHOAMI, CAT, DRYRUN, GENPASS, LOG and HELP. A call of a client whose
user may not run every command, read and write every key and use every channel is
checked as Redis's `processCommand` checks it, after NOAUTH and before the rest: refused,
it answers NOPERM, counts as a refused call and adds an entry to ACL LOG; EXEC checks its
commands again as it runs them. ACL DELUSER closes the clients of the users it removes,
and ACL SETUSER that takes a channel away closes the subscribers that had it. While no
client's user is restricted, nothing is checked (section 3zzzh of FINDINGS.md).
Configuration: CONFIG GET (names, alias names, glob patterns), SET (several parameters
at once, all or none), RESETSTAT, REWRITE, HELP over every parameter of Redis 7.2.16
(counted in [README.md](README.md#in-numbers)):
`tools/gen_config.py` writes the table from Redis's own `config.c`, each value is
checked as Redis checks it and read back as Redis prints it. `requirepass` (the
password), `hz` (with a limit, as in Redis) and `notify-keyspace-events` (which keyspace
events are published) take effect; the port, the addresses, TLS and the append-only file
do not change while the server runs (a new value is refused with the same error Redis
gives when it cannot apply one); `maxmemory` with its policy, samples, tenacity and the
parameters of LFU limit the memory and choose what to evict (see "Memory" below); the
other parameters are kept and read, but configure nothing: BendKV has no replication or
encodings.
INFO has the sections and fields of Redis 7.2.16 in its order; sections are chosen as
in Redis (no arguments, `default`, `all`, `everything`, names in any case): server,
clients, memory, persistence, stats, replication, cpu, modules, errorstats, cluster,
keyspace. The values are BendKV's own where BendKV has them: the process, parameters,
connections, commands and bytes (instantaneous rates are samples every 100 ms, as in
Redis's `serverCron`), memory (`used_memory` is how many bytes the heap's live values
hold, as Redis's is how many its allocator handed out; see "Memory" below), keys,
evictions, the append-only file, the scripts and functions (the engine's memory, the
scripts cached, the functions and libraries); for what BendKV lacks (replication,
`fork`), what Redis shows when it lacks it.
CONFIG RESETSTAT starts the counts over. Statistics per command are counted as in
Redis: the calls of each command and subcommand, the calls refused before they run (a
wrong number of arguments by Redis's arity, a client without a password, a refusal for
memory), and those that failed while running; error replies by code (errorstats), including those the
client did not get (CLIENT REPLY OFF); usec and, with `latency-tracking`, each
command's histogram (latencystats, LATENCY HISTOGRAM) from the timing of calls below.
SLOWLOG and LATENCY, as Redis 7.2.16 keeps them: the actor reads the clock around each
batch of requests, as Redis around each call, and a batch's calls share its time. A call
that takes `slowlog-log-slower-than` µs or more goes to the slow log with its arguments
as sent (32 at most, 128 bytes each; AUTH's, HELLO's and CONFIG SET's secrets redacted;
EXEC's commands but not EXEC; a blocking command when it is served); one that takes
`latency-monitor-threshold` ms, when that is set, is a sample of the event "command" or
"fast-command", and a cron's sweep of expired keys one of "expire-cycle". Where BendKV
differs: a pipeline's calls share its time; a batch's entries go to the slow log when it
ends; there are no events of the append-only file, of eviction or of fork (section 3zzz
of docs/FINDINGS.md).
COMMAND (with INFO, DOCS, COUNT, LIST and its filters, GETKEYS, GETKEYSANDFLAGS, HELP)
describes each BendKV command and each of its subcommands that BendKV has, as Redis
7.2.16 describes them: `tools/gen_commands.py` takes the descriptions from Redis itself.
Memory: `maxmemory` and eviction as Redis 7.2.16 runs them. With `maxmemory` set, BendKV
reads how much its heap's live values hold before each group of requests (Redis measures
before each command), and while that is more than `maxmemory` it evicts keys by
`maxmemory-policy`: the LRU, LFU and volatile-ttl policies from a pool of the 16 best
candidates of their samples (`maxmemory-samples` keys of each database), kept from one
eviction to the next; the random ones a key of each database in turn; the volatile ones
only among keys with a time to live. An evicted key is deleted as an expired one is: a
DEL in the append-only file, its WATCHes touched, the event `evicted`, a count in INFO's
`evicted_keys`. Past the time `maxmemory-eviction-tenacity` gives, the eviction goes on
between groups, as Redis's goes on from its event loop; with nothing to evict, the
commands that may need memory get Redis's OOM error, so does any command a client queues
in MULTI, and EXEC aborts a transaction that queued one. CONFIG SET `maxmemory` evicts at
once, with Redis's warning when the memory is already past the new value; INFO shows how
long the memory was past the limit (`total_eviction_exceeded_time`,
`current_eviction_exceeded_time`). When a key was touched, BendKV keeps as Redis does: the
LRU clock (seconds) or the LFU counter (logarithmic, with `lfu-log-factor`, decaying by
`lfu-decay-time`); OBJECT IDLETIME and FREQ answer by them. Where BendKV differs: the same
`maxmemory` holds another number of keys, a key taking another number of bytes in BendKV's
heap (with its share of the trie's nodes) than in Redis's allocator; while a rewrite or a
background save runs, the eviction counts the dataset's change by its number of keys, each
at the average size when the job started, as its snapshot holds the values the writes
replace where Redis's parent counts no page its child keeps; the marks are kept in
a table of 2^20 words by the key's hash, and keys whose hashes have the same low 20 bits
share a word; a request marks only its first key, and before it runs (the other keys of
MGET are not marked); evicting many keys at once is about ten times slower than in Redis.
Start-up is as for `redis-server`: a configuration file, `--name value` parameters and
`-` for standard input are read line by line as Redis reads them (`include`; `dir`,
which changes the directory at once; `save` points, which add up; the same errors on the
same lines), and the log is written in Redis's form, to standard output or to
`logfile`. The port, `bind` (IPv4), `requirepass`, `protected-mode`, the append-only
file (`appendonly`, `appendfilename`, `appenddirname`, `appendfsync`,
`aof-load-truncated`, `aof-disable-auto-gc`), `logfile`, `loglevel` and `pidfile` take
effect; with `appendonly no` the RDB file is loaded, as Redis loads it; what BendKV
cannot do (modules, ACL users from the configuration or a file, command renaming,
daemonizing, cluster, replica, TLS, supervisor signaling, or an RDB file that holds a
module's data) stops the start with a line in the log.
Pipelining, partial packets, inline commands (one can work through `nc`) and
binary-safe values are supported. Requests are parsed as Redis 7.2.16 parses them: a
length as `string2ll` reads it (no `0` before the first digit), a count of 0 or less
(down to -2^63) is skipped, a line ends with its `\r` and any byte after it, and without
a `\r` it is no longer than 64 KB, and the two bytes after a bulk's data are skipped
unread. An error goes out as one line, as Redis formats it: CR and LF in its text as
spaces, an argument in it up to the first NUL. With CLIENT REPLY OFF, or SKIP for the
request it happened in, a protocol error gets no reply, as in Redis, and the connection
stays open, running nothing more, until the client closes it. The only things missing
are Redis's stricter limits for a client that still has to pass AUTH (10 arguments, a
bulk of 16 KB) and a new value of proto-max-bulk-len.

**Design.** Commands are run by the database actor. As in Redis, all commands run one
after another, in order of arrival. The actor holds the databases as a zipper (`R.Ds`):
one in focus, the others on both sides of it; before a connection's batch it moves the
focus to the database the connection selected, and the commands of one database run on
the focus just as on a single database. Connections parse requests and send them to the
actor in batches through channels; a connection waits for the answer to its batch on
its own channel, and when the connection ends, however it ends, it closes both the
socket and that channel (the actor's shared channel stays open). The actor takes at
once all the batches that wait for it (`Chan.drain`), runs them in turn and answers
them all in one step (`Chan.send_all`). Replies are handed to a writer thread
(`TCP.post`), and the loop does not wait for the `send` system call; the writer switches
on by itself when the process may use at least two cores (on one it would only take
time from the loop); `io-threads 1` sends from the loop, as single-threaded Redis does,
and the short form `./bendkv PORT post` or `send` chooses explicitly. A client that
stopped reading holds up only its own replies: the writer sets them aside in order and
sends them once the socket has room, while the other connections, the timers and
`accept` go on as usual (section 40 of docs/PERFORMANCE.md). Before, the database could
be split into shards across cores, but they paid off only without pipelining and with
an append-only file, and cost two files of code and two fifths of the proofs; in
section 14 of docs/PERFORMANCE.md they were taken out (the code is in the branch
[`archive/shards`](https://github.com/littleBro/BendKV/tree/archive/shards)).

**Sessions.** The state of a connection (`session.bend`: the id, whether the client is
authenticated, the name, the CLIENT REPLY mode, whether it asked to close) travels to
the actor with the batch and comes back with the replies; the state of the server (for
now, the password) the actor keeps beside the database. The parser gathers the commands
of the connection and of the server into one command `Own`, and reads of one key whose
reply depends only on its value (TYPE) into `Peek`: the laws see each group as one
command, and a new command in a group adds no proofs. A batch of database commands only,
from a client that may run them and gets all the replies, the actor runs as before
(`exec_batch`, `log_batch`); any other, a command at a time (`S.gen`): a command after
QUIT is dropped, a parser error is answered, a command of a client that must log in
first is refused (NOAUTH), a session command runs with the state, a database command
through `exec`, and the reply goes out or not as CLIENT REPLY says. After the replies
the connection goes on without continuation closures: the `@unsafe` steps call each
other and the connection's loop directly. Sessions cost from −0.5 to +0.2% of
instructions per request at pipeline 16 and +2% without a pipeline (section 15 of
PERFORMANCE.md).

**The append-only file (AOF).** With `appendonly yes` (or
`./bendkv PORT post|send FILE [always|everysec|no]`) the actor runs a batch through
`exec_log` (`aof.bend`, after the hints to the processor, as usual): besides the replies
and the database it gives the effects, what the batch did, as commands. A read gives
nothing, SET, SETNX, GETSET, APPEND, DEL, MSET and FLUSHDB give themselves, and INCRBY a
SET of the new value (that is how Redis writes INCRBYFLOAT): when the log is read, only
times and database numbers are parsed from text. An effect is tied to its database: the
entries of a database other than the one the file selected last are preceded by a
SELECT, SWAPDB, MOVE and FLUSHALL are written as Redis writes them (MOVE after a SELECT
of the database the key leaves), and COPY after a SELECT of the database the key is
copied from, always with DB and REPLACE: on replay at time 0 a target key whose time
had passed would "be there". A COPY as Redis writes it (as the client sent it: without
DB, into the selected database, options in any order and case) the loader reads too.
The effects are appended to the file before the reply to the client, in Redis's own AOF
format (arrays of bulk strings). The actor takes a request and with it all those that
came while it worked (`Chan.drain`), runs their batches one after another, writes their
effects as one write, with `always` does one `fsync`, and answers them all at once
(group commit, as in Redis's loop). With `everysec` (the default, as in Redis) a
separate computation syncs the file once a second through its own descriptor, with `no`
the OS does.
At start the server reads the file and runs its entries on empty databases (SELECT
moves the focus), but first it checks that each entry will replay as it was written
(`checked` in `aof.bend`): an entry the parser refuses (an unknown command or
subcommand, a wrong number of arguments, an argument that does not read), a command of
the connection or of the server, a SELECT, SWAPDB, MOVE or COPY of a database that is
not there or with a number that does not read, a MULTI inside MULTI and an EXEC without
MULTI make it refuse to start. The log has the entry's number (from 1), the byte it
starts at and the parser's error, and the file stays byte for byte as it was: the
refusal comes before the file is cut or opened to append. The replay used to run such
entries with an error and go on, and the entries after a bad SELECT landed in the wrong
database. Redis also stops its load at an unknown command; neither it nor BendKV writes
such entries: both write only commands that ran. The MULTI and EXEC that Redis writes
around a transaction, and around the deletion of a key whose time had passed before a
write to it, are marks: the commands between them replay in order; BendKV itself also
writes a transaction's effects between MULTI and EXEC when there are two or more. A
file that ends inside a transaction (a crash cut its write short) has it reverted, as
Redis does ("Revert incomplete MULTI/EXEC transaction"): the file is cut back to its
MULTI, and with `aof-load-truncated no` the start stops, as for an entry cut short. If
the file ends in the middle of an entry (a crash during `write`), it is cut back to the
last whole entry, as in Redis with `aof-load-truncated yes`, at any size:
`File.truncate` of the twenty-fourth patch takes the size as a `Nat`, while before the
size went through a `U32`, and a file of 4 GiB or more would have been cut to its size
modulo 2^32. It is proved that the databases are then those after some prefix of the
acts in which every transaction is whole; anything else after the entries makes it
refuse to start, also as in Redis. Having opened the file to append, the start syncs its
directory (`File.sync_dir`, an `fsync` of the directory, as Redis's `fsyncFileDir`) and
only then serves clients: an `fsync` of the file itself does not make its entry in the
directory durable, and after a crash the name of a file just made could be lost, and
the next start could bring up empty databases; a failure stops the start too.
A file that is there but does not open (no permission, an I/O error, no free
descriptors) is a refusal too: an empty database appending to the old file would part
from it. A failed `fsync` stops the server with `everysec` as with `always`:
acknowledged writes may not have reached the disk, and after such an error the kernel
may drop dirty pages, and the next successful `fsync` will not show it (in this case
Redis answers writes with the `MISCONF` error until an `fsync` passes again).
BGREWRITEAOF and the rewrites on the file's growth (`auto-aof-rewrite-percentage`,
`auto-aof-rewrite-min-size`, started by the cron) write the file anew, as Redis writes
its base: the commands that make the databases as they are at the start of the rewrite
(SET, RPUSH, SADD, HMSET, ZADD of 64 elements each, PEXPIREAT), then the entries
appended meanwhile, into a temporary file that is then put in place of the file
(`File.rename`, the twenty-eighth patch), and the directory is synced. Without `fork`:
the databases are values, and the actor keeps a snapshot of them and writes it a slice
at a time between the groups of requests it serves meanwhile (section 47 of
PERFORMANCE.md). Where `appenddirname` is there in `dir`, the files are Redis 7's: a
manifest, read and written as Redis 7.2.16 does, a base (an RDB file or commands) and
the incremental files since, loaded in turn; the last incremental file is appended to,
and a rewrite starts a new one, then renames its temporary file into the directory as
the next base and makes the files before it history, which it removes (section 3zzzq
of docs/FINDINGS.md, with where BendKV differs: without the directory, which the
runtime cannot make, BendKV keeps Redis 6's single file; its bases are commands).

**The store** is a 16-child trie over 5 hex digits of the FNV-1a hash (2^20 buckets).
A bucket is a chain of entries right in the trie, for collisions; an entry holds the
key, the value and the time the key expires at (in ms since 1970; 0 means never). The
structure was chosen for provability: no order on keys is needed (as in search trees),
and different paths lead to different nodes. So the laws are proved by induction on the
depth of the walk. For correctness the hash may be anything; a good hash only shortens
the buckets. The walks go by the digits of the hash itself, each digit computed in
advance and passed as a parameter. A key read (`get`) searches the bucket right at the
end of the walk and only borrows the database: the compiler with the `borrow-reads`
patch keeps the value found in place instead of sharing the whole trie. The server's
GET answers with a copy of the value made right there (`get_copy`): the value in the
database stays unshared, with no counter cell, and the batch hints reach its bytes; the
laws of GET (`get_after_set`, `get_missing`) are proved of this GET, which answers the
copy. A write rebuilds the path in place.
The 16-way and 256-way case splits in the code and in the proofs are written by
`tools/gen_trie.py`.

### What is proved (proof/LAWS.bend)

A person states the laws; the proofs (`PROOF.bend`) are written and checked by the
machine. How many laws each group holds is in README.md's
[table](README.md#what-is-proved).

**The map.** This is a complete axiomatization of a finite map from keys to an
entry, a value and a time: after any sequence of writes of four kinds (a value with a
time, a value with the old time, the time alone, a deletion) the entry of any key is
uniquely determined, so there are no stale, lost or "foreign" entries.
- `entry_empty` — an empty database has no keys;
- `entry_setx_same`, `entry_setx_other` — after a write of a value with a time the key
  holds them, and the other keys hold what they held;
- `entry_keep_same`, `entry_keep_other` — a value with the old time (KEEPTTL, INCR,
  APPEND): the key holds the new value and the time it had (a new key, no time);
- `entry_expire_same`, `entry_expire_other` — the time alone (EXPIRE, PERSIST): the key
  holds its value with the new time, and such a write does not create a key that is not
  there;
- `entry_del_same`, `entry_del_other` — after a deletion the key is gone, and the others
  are as they were;
- `get_entry`, `read_entry` — a read gives the entry's value; `read`, which commands read
  with, does so only while the key's time has not passed.

**Keys.** `key_eq_true` and `key_eq_false`: the key comparison `str_eq` is
exactly the equality of strings. `str_eq` is `String.eq` from Base (in the C runtime
with the patch, a `memcmp` by chunks); it is proved to agree with comparison character
by character, and the proof goes down the representation to the 32 bits of a `U32`.

**Commands:** laws about the function `exec`, which is what the server runs:
- `frame` — **no command changes a key it does not write, neither its value nor its
  time**: SET/DEL/MSET/INCR/EXPIRE/… touch only the keys they name, FLUSHALL all of
  them. Proved for every kind of command, each constructor of `Cmd` (counted in
  [README.md](README.md#in-numbers)), with the groups `Peek`, `Upd` and `Own`;
- `reads_keep_db` — read commands (GET, EXISTS, MGET, STRLEN, KEYS, SCAN, DBSIZE, SORT
  without STORE, PING, ECHO, errors) do not change the database as a whole;
- `get_after_set`, `get_missing` — GET after SET, and GET of a key that is not there
  (never set, deleted or expired);
- `expired` — **a key whose time has passed does not exist for any command**: GET
  answers nil, DEL does not count it, SETNX sets it anew;
- `del_effect` — after DEL each named key is deleted (with repeats and in any order);
  `del_one_count` — DEL of one key answers 1 or 0;
- `append_effect` — APPEND to a key without a collection stores "old ++ new" and
  answers the new length; a new key is added to the database's count of keys;
- `setrange_effect` — SETRANGE of an existing key with a string writes the bytes from
  the offset (padding the value with zero bytes), keeps the key's time and answers the
  new length, when it changes the key (non-empty bytes, a value of at most 512 MB); the
  change SETBIT makes is the same SETRANGE of its byte;
- `setnx_missing` and `setnx_present` — SETNX sets a missing key (the count grows by
  one) and does not touch an existing one;
- `incr_missing` — INCR of a missing key stores "1" without a time, answers 1 and
  counts the key;
- `pttl_left` — PTTL of a key with a time answers how many milliseconds it has left;
- `set_keepttl` — SET with KEEPTTL keeps the key's time, whatever the type of the
  value;
- `persist_effect` — PERSIST takes the time off a key and answers 1;
- `getdel_effect` — GETDEL of a key with a string answers with it and deletes the key;
- `rename_effect` — RENAME of a key that is there to another key moves the entry (the
  value and the time) and answers OK: the source key is gone, and the target holds what
  the source held, whatever it held before;
- `msetnx_present` and `msetnx_missing` — MSETNX sets nothing and answers 0 if even one
  of its keys is there, and otherwise sets them all, as MSET does, and answers 1;
- `bitop_store` — after BITOP the target key holds the value the sources gave, with no
  time to live (or is deleted if the value is empty), and the reply is the value's
  length if no source holds a collection (WRONGTYPE otherwise);
- `reap_keeps` — **the sweep of expired keys deletes no key that is there**: it deletes
  with DEL the keys that the filter `reap.keys` kept of those the scan found, whatever
  the scan found;
- `batch_step` and `batch_nil` — **a batch of commands runs exactly as a sequence of
  commands**. This ties the laws about one command to how the server runs pipelined
  batches;
- `batch_hints` — **the hints to the processor change nothing**: the server runs a
  batch through `batch.bend`, which first starts loading the paths of its keys into the
  cache (by the hashes the parser read from the requests) and then runs it as
  `exec_all`; the law holds for any hashes.

A database is the record `Db`: the trie, the number of keys in it (DBSIZE and INFO's
keyspace line give it), the number of keys with a time, and the time the batch runs at;
there are several databases, and a batch runs on the one in focus. The laws about how
keys read and what commands answer are stated of the server's `exec` and proved through
the specification, `exec` on one trie at a moment of time (`proof/SPEC.bend`), which a
bridge in the proofs (`bridge_go`) relates to the server's `exec` (DBSIZE, whose reply
is the count, aside). The laws about the database as a whole are proved
on the record together with the count, and the counts are the trie's own (the key count,
below).

**Commutativity.** Commands on different keys can run in any order. A key
after a command depends only on how, before it, the key itself read and how the keys
read that the command's writes depend on (`deps`): RENAME moves a value from one key to
another, MSETNX sets its keys only if none of them is there, BITOP sets the target key
from its sources. So:
- `commute_reads` — after two commands in either order, every key that at most one of
  them writes reads the same, if neither writes a key that the other's writes depend on
  (`spoils`);
- `commute_reply` — a command answers the same after another one that does not
  "disturb" it (`disturbs`: it writes no key the first one reads; for DBSIZE, KEYS and
  SCAN, and for SORT, whose patterns may name any key, it writes nothing at all);
- `commute` — two commands that do not disturb each other give the same replies in
  either order;
- `swap_replies` and `swap_reads` — **two adjacent independent commands of a batch can
  be swapped** (independent: they write no common keys, and neither writes a key the
  other's writes depend on): their replies swap places, the rest of the batch answers
  the same (if it has no DBSIZE, KEYS, SCAN and SORT), and at the end every key reads the same
  (this for any rest of the batch).

The laws speak of how keys read, not of the trie itself: two new keys of one bucket lie
in the order they were written, and KEYS and SCAN may list them in another order (Redis
promises no order anyway). So DBSIZE, KEYS and SCAN after a swap are left out: they
would need the invariant "a bucket holds no key twice".

**Persistence:** laws about the append-only file (`aof.bend`):
- `log_exec` — `exec_log` answers and changes the database exactly as `exec_all` does:
  with the append-only file the server answers as it does without it;
- `log_hints` — the hints to the processor change nothing here either: the actor runs
  a batch through `log_batch`, and for any hashes that is exactly `exec_log`;
- `log_replay` — a batch's effects, run at time 0 on the database the batch ran on,
  give the same database as the batch (at time 0: the file loads at time 0, when no key
  has expired, and the effects name every time from 1970);
- `log_args` — the effects of any batch, written as request strings, parse back to
  themselves; the times in them are such as a key holds (under 10^14 ms), and the parser
  of times (`num14`) reads back what `Nat.show` wrote (`num14_show`);
- `aof_load` — **a file reads as exactly the entries written to it**, and nothing is
  left. The decimal round trip is proved here too: a length written by `Nat.show` the
  digit parser reads back (through division by 10 "by steps of ten" and `Nat.show`'s
  fuel);
- `recover` — **after any history of batches, each at its own time and on any of the
  databases, the server restores from its file exactly the databases it held** (at
  time 0: the server sets the time before its next batch), and after the last entry
  nothing is left. The replay of the file keeps an invariant with the server's
  databases: each database reads the same at time 0, the replay's focus is the database
  the file selected last, and its time is 0; an act without an effect (a focus moved, a
  SWAPDB or MOVE that did nothing, a command that wrote nothing) leaves the databases
  the same at time 0, and an act with an effect does to the replay what it does to the
  server's databases. Database numbers in the file are shorter than 15 digits, and the
  parser reads back what `Nat.show` wrote;
- `recover_cut` — **a file cut by a crash at any byte restores the databases the server
  held after some prefix of its acts in which every transaction is whole**: no act is
  applied in part, none out of order, none after one that was lost, and no act of a
  transaction without the others. An entry cut short never reads (a number line without
  its `\r\n`, a bulk without its bytes or without its `\r\n`); an entry of the file is an
  effect (one command string, or a SELECT and one) or the effects of a transaction
  between MULTI and EXEC, and on replay MULTI and EXEC are connection commands that
  change nothing; no effect string is a mark (not the single word MULTI or EXEC), so the
  start, reading from the end, reverts exactly the transaction inside which the file was
  cut; a SELECT with no entry after it changes no database; a step (an act or a whole
  transaction) has at most one entry: the first k strings give the databases after the
  first j steps, for some j;
- `load_cut` — the whole entries read, written again, together with the leftover are
  the cut file: the server cuts off exactly the leftover, and whole entries stay in the
  file;
- `checked_replay` — the start's replay with its check (`A.checked`), when the check
  refused no entry, gives the same databases as the replay `A.replay` the laws above are
  about: the check only decides whether to replay. It is not proved that the check
  passes every file BendKV writes (the tests show it); a refusal of its own file could
  only stop a start, not change the databases;
- `load_windows` — **the start reads its file a window at a time, and makes of any
  windows what it made of the whole file**: the check's verdict on the entries the
  loader keeps, their number, the entries of a transaction it reverts, and what follows
  the last whole entry. An entry read with more bytes after it reads the same and
  leaves them after what it left (each part of the parser, for strings it does not
  know: the chars it expects are compared by their code, `U32.is_eq`, so that a proof
  can follow it), and it takes a byte at least, so the loader's fuel lasts on any
  string; so the loader reads two strings one after the other as the entries of the
  first, then those of what the first left with the second after it. The start holds,
  after each entry, what `untx`, `checked` and `replay` make of the entries so far,
  a transaction held from its MULTI until its EXEC. So the laws above, stated of the
  whole file, are about the start that reads it in windows.

Mutations of the log (not writing APPEND, writing the wrong number for INCR, shifting a
digit, taking fuel from the loader, writing an extra element into an array's count,
losing a pair of MSET, not cutting off a bulk string's body) break the proof exactly at
the place they spoil. Two more mutations of the loader pass all the laws about a whole
file, and only the laws about a cut catch them: a bulk cut in the middle of its bytes
reads as a shorter string (a value nobody wrote), and an entry cut between its
arguments reads as what had arrived (DEL a b c would run as DEL a b). Eight mutations
of the start in windows (an entry run without its check, an EXEC that forgets the
entries held before it, a window read before what the last one left, the reverted
entries written in the wrong order, a MULTI inside another that goes on, a second MULTI
that keeps the first's cut, a bulk or a number line taken without its line's end at
the end of a window) break the proof of `load_windows` where they spoil the start.

**Databases:** laws about the acts that change whole databases (`R.Act`), at time 0:
- `focus_keeps` and `focus_on` — SELECT changes no database and puts in focus the one
  it names, if it is there;
- `swap_dbs` — SWAPDB puts each of the two databases in the other's place;
- `wipe_dbs` — FLUSHALL empties all databases;
- `move_key` — MOVE of a key that is there to another database where it has no entry
  removes the key's entry from the selected database and puts it, with its value and
  time to live, into that one;
- `copy_key` — COPY of a key that is there gives its entry (the value and the time to
  live) to the target key in the database it names (or in the selected one), if the
  target key is not there or REPLACE is given, and changes nothing else.

**The key count:** laws about the counts a database keeps beside its trie:
- `counts_hold` — **after any history, the counts of every database are its trie's
  own**: how many keys it holds and how many of them have a time; and its trie is well
  formed, each key at most once in its bucket;
- `dbsize_size` — so DBSIZE answers the number of keys in the trie of the database in
  focus, keys whose time has passed among them until a command or the sweep deletes
  them, as in Redis.

**Sessions:** laws about `session.bend`:
- `run_gen` and `run_log_gen` — **however the server took a batch apart, it runs it as
  the general path runs its commands in order**: the fast path (`exec_batch`,
  `log_batch`) for a batch of database commands only from a ready client is the same
  general path (`fast_eq`), with the same replies, the same state of the connection and
  of the server, and the same database;
- `gen_db` — a batch changes the databases exactly as the acts of the commands that ran
  in it do (`S.plan`), so the laws of commands and databases hold for them too;
- `gen_log` — and it logs the effects `exec_log` gives them: the file holds the history
  of the commands that ran, and the laws of persistence hold as they are;
- `noauth` — **a client that has not logged in, on a server with a password, runs
  nothing on the database but parser errors until AUTH or HELLO**: it can neither read
  nor change a single key.

**Configuration:** laws about `config.bend`:
- `config_fail` — **a CONFIG SET that failed leaves the server as it was** (Redis sets
  the parameters before the failing one and puts them back, BendKV sets none);
- `config_pass` — one that succeeded leaves the server with the new parameters, and
  their `requirepass` is the password from that moment on (and the eviction's state takes
  the parameters of `maxmemory` from them);
- `config_set_get` — **after a successful CONFIG SET of a parameter it holds the value
  its check gave, and CONFIG GET finds it by the same name** (a case-insensitive search,
  by name or alias name).

`bend proof/PROOF.bend` (`make check`) → `ALL PROOFS CHECK` (~15 s);
`bend proof/PROOF.bend --verdict` → `ALL PROOFS CHECK` (about a minute). In the second
case each proof is rechecked by the BendTT kernel, whose soundness is proved in Lean.
The translation the kernel reads can be dumped with
`bend proof/PROOF.bend -o PROOF.bendtt`, and the statements of the laws read by eye.

### What is checked by tests

- **Redis's own test suite** (`tools/redis_suite.py`, `make suite`; in detail,
  [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md)). The `tests/` suite of Redis 7.2.16
  itself in external mode (`runtest --host --port` with
  `--ignore-encoding --ignore-digest --durable`; without `--singledb`, since BendKV has
  16 databases): each unit of `tests/unit` and `tests/unit/type` runs against a server
  already started, and the tests that need a server of their own (`external:skip`) are
  skipped. The reference is the same run on redis-server 7.2.16 with default settings,
  each unit on a freshly started server instance: in this mode 1,905 tests run, and
  Redis passes 1,812 (almost all the others need DEBUG, off by default in 7). BendKV
  passes 1,676 of them (92.5%), and in the units of what it has (the protocol, the
  connection and clients and their pause, the keyspace and databases, strings with
  ranges, bits and fields, counters, hashes, lists, sets, sorted sets, SORT, HyperLogLogs,
  GEO, DUMP and RESTORE, times to live, lazy freeing, transactions, Pub/Sub and keyspace
  notifications, introspection, the slow log and the latency monitor, client-side
  caching, ACL users, Lua scripts and functions), 1,635 of 1,688 (96.9%); streams' values,
  reads and writes pass 41 of the 122 tests of `unit/type/stream` and
  `unit/type/stream-cgroups` that Redis passes. The others stop on commands that do not
  exist (74 tests: XGROUP, SYNC…), do not run because the unit stopped earlier (24), or
  fail on XREAD's wait and streams' groups, on clients left in MULTI or subscribed by
  tests that failed on a command that does not exist, and on what the list in
  docs/COMPATIBILITY.md gives (38). Against Redis 7.0.15, whose suite runs 1,757 tests
  in this mode, BendKV passed 1,556 of the 1,677 that Redis passed (92.8%), and 1,516
  of 1,565 in the units of what it has. Times to live and
  the sweep of expired keys added 78 passed tests: before them there were 135, and 30
  tests failed on SET's options; ranges and bits added 49 more, TOUCH, TIME and OBJECT
  4, MSETNX, RENAME and RENAMENX 13, COPY 7, BITOP and LCS 19, BITFIELD 16, hashes 64,
  lists 33, sets 104, INCRBYFLOAT and HINCRBYFLOAT 24, sorted sets 181, blocking
  commands 13, transactions 27 (and 14 tests that passed before now fail on a client
  left in MULTI by a test that failed on a command that does not exist), Pub/Sub and
  keyspace notifications 26, CLIENT LIST, INFO and KILL 9, MONITOR 3, maxmemory and its
  eviction 8, RESP3 292 (`unit/type/list` and `unit/type/zset` no longer stop at their
  HELLO 3), SORT 56, HyperLogLogs 20, CLIENT PAUSE and UNPAUSE 9, the administrative
  commands none (their tests need servers of their own), GEO 79 (`unit/geo`'s 59, and 20
  of `unit/introspection-2`, 16 of them run after a test that left its client in MULTI
  on GEOADD), DUMP and RESTORE 12 (`unit/dump`'s 10, and two of `unit/type/list`), the RDB file 2
  (`unit/other`'s tests of SAVE), streams 41 (`unit/type/stream`'s 39, a COPY of a
  stream and XREAD's movablekeys), Lua scripts 13 (14 tests of other units that run a
  script, less one of `unit/functions`), and functions 195 (`unit/functions`' 89,
  `unit/scripting`'s 104, which runs past its half of functions now, and one each of
  `unit/pause` and `unit/introspection`).
  The suite found three bugs in what there is. KEYS matched with a naive glob, and the
  pattern `a*a*…a*b` against a key of forty `a` characters hung the server for minutes;
  there were no classes `[...]` and no escaping either. Fixed: KEYS matches as Redis's
  `stringmatchlen` does, together with the limit of 1,000 nested stars that Redis
  introduced against CVE-2024-31228. And a request's parse took time in proportion to
  the square of its length (a GEOADD of 20,000 points 3.6 to 6.2 s, past the limit of
  `unit/geo`'s fuzzing tests): its arguments were read by index in a packed String that
  a read by index walks from its start. Fixed: a long request's arguments are read
  through a window of one chunk (the GEOADD takes 0.19 s; section 3zzn of
  docs/FINDINGS.md). And the walks of a sparse HyperLogLog's opcodes read to the value's
  end, by index, so that 7.2.16's test of 32 MB of them, past the last register, stopped
  its unit: they now end at the first opcode past it, as Redis's do (8 ms; section
  3zzzzk of docs/FINDINGS.md).
- **The test suites of client libraries** (`tools/client_suite.py`, `make clients`; and in
  CI's heavy tier, before a pull request merges): redis-py 8.1.0's tests of its sync and asyncio clients, in
  RESP2 and in RESP3, and go-redis v9.23.0's specs, in RESP3, each against Redis 7.2.16
  and against BendKV, each on a server started for it, without their tests of modules,
  clusters, sentinels and TLS. Of the tests Redis passes, BendKV passes 2,723 of 2,772 in
  redis-py, the same tests in RESP2 and in RESP3, and 449 of 463 in go-redis; every other
  one fails on what BendKV does not have (streams' groups and XREAD's wait, MODULE,
  REPLICAOF, WAITAOF, and COMMAND's entries of those), none on a command BendKV has
  otherwise. A test Redis passes that BendKV fails, and that is not among the
  known failures of `tools/data/clients.json`, fails CI.
- **Differential testing against Redis 7.2.16** (`tests/diff_test.py`). Random streams
  of commands with random binary arguments, pipelines of different lengths, and arity
  and format errors go in parallel to BendKV and to real Redis. Against 7.2.16, 12 runs,
  ≈163 thousand commands (3 of the runs in RESP3): all replies identical; against 7.0.15
  before, 28 runs, ≈266 thousand commands, all replies identical (and ≈1,050 thousand
  more on the versions with a 16-child trie, ≈115 thousand of them on the current one
  then). Among the commands are times to live and the options of SET, GETEX and EXPIRE:
  relative times (from 100 s) and absolute ones (long past or far off), with bad values
  and overflows; the generator avoids times of 10^14 ms or more (in BendKV such a time
  gives a key no time to live). TTL, PTTL, EXPIRETIME and PEXPIRETIME read each server's
  clock and are compared to the second. The stream moves over databases 0–3 (SELECT),
  moves keys between them (MOVE), swaps them (SWAPDB) and empties one (FLUSHDB) or all
  (FLUSHALL), with bad numbers among them (`01`, `-1`, `2147483648`, 20 digits): the
  errors too match byte for byte. Ranges and bits (GETRANGE, SETRANGE, GETBIT, SETBIT,
  BITCOUNT, BITPOS) take small offsets, and now and then wrong and huge ones, but never
  such that a value would grow to nearly 512 MB.
- **Key expiry** (`tests/ttl_test.py`): seven scenarios set keys with short times on both
  servers, wait for the times to pass and compare the replies: reads of expired keys,
  KEYS, SCAN and RANDOMKEY when only expired keys are left, writes over expired keys
  (SETNX, SET with XX and NX, GETSET, APPEND, INCR, MSET, KEEPTTL), time commands on
  expired keys, times kept and changed by different commands, and times in the past,
  and the sweep of expired keys: DBSIZE is compared a second after the expiry, when the
  sweeps of both servers have run (before that, Redis deletes an expired key when any
  command comes to it, and BendKV when a write or the sweep comes).
- **Robustness** (`tests/robust_test.py`): a request one byte at a time (parsing across
  many TCP reads), a 1 MB value, garbage in the protocol (an error and the connection
  closed, as in Redis), 50 parallel clients.
- **A client that does not read** (`tests/writer_test.py`, in each server mode): a
  client asks for 32 MiB of replies and does not read them, while another meanwhile gets
  a reply of 8 MiB and a PONG, new connections are served, the cron's sweep deletes an
  expired key, and a QUIT after a large reply closes the connection only after it; then
  the stuck client gets all its replies in order (section 40 of docs/PERFORMANCE.md).
- **Clients that wait** (`tests/blocking_test.py`, in each server mode): 18 scenarios
  of blocking commands on BendKV and on Redis, their transcripts compared line by line
  (pushes, timeouts, CLIENT UNBLOCK, a client leaving while it waits, chains of BLMOVE,
  RENAME, MOVE and SWAPDB, CLIENT REPLY OFF, INFO's statistics); then 300 clients
  served at once, 100 timeouts at once, clients that leave while they wait, and 50
  consumers moving 1,000 elements while some of them leave (section 41 of
  docs/PERFORMANCE.md).
- **Transactions** (`tests/multi_test.py`, in each server mode): 12 scenarios of MULTI,
  EXEC, DISCARD, WATCH and UNWATCH on BendKV and on Redis, their transcripts compared
  line by line (replies of all kinds and SELECT inside, DISCARD, a nested MULTI, WATCH
  inside MULTI, refused commands and EXECABORT, errors while running, QUIT and RESET
  inside a transaction, changes of watched keys by another client and non-changes,
  FLUSHALL, FLUSHDB, SWAPDB, MOVE, COPY, RENAME, EXPIRE, expiring keys, a blocking
  command inside EXEC, CLIENT REPLY OFF and SKIP, INFO's statistics); then under load:
  20 clients raise a counter to 1,000 through WATCH (each lost race is retried), a
  reader never sees half a transaction, 100 clients leave in the middle of MULTI or with
  watched keys (section 42 of docs/PERFORMANCE.md). The differential test sends random
  transactions too.
- **Pub/Sub** (`tests/pubsub_test.py`, in each server mode): Pub/Sub scenarios on BendKV
  and on Redis, their transcripts compared line by line (216 lines: PING of a subscribed
  client, UNSUBSCRIBE of some and of all, patterns with classes and escaping, NUMSUB and
  NUMPAT, commands a subscribed client may not run, RESET, QUIT and a closed connection,
  CLIENT REPLY OFF and SKIP, SUBSCRIBE in a transaction, shard channels, a message of
  100 KB, INFO's statistics, then the events of 162 commands with `KEA` and with masks,
  `new`, `expired` from the sweep, a waiting client served, a transaction); then under
  load: 20 subscribers of a channel and a pattern each get 2,000 messages from 4
  publishers in each publisher's order, while 50 subscribers close their connections as
  messages are published (section 43 of docs/PERFORMANCE.md).
- **Clients** (`tests/client_test.py`, in each server mode): scenarios of CLIENT LIST,
  INFO and KILL on BendKV and on Redis, their lines compared field by field, leaving out
  what differs by nature (ids, addresses and fds are compared as the clients they name;
  age and idle time by whether they reached two seconds; the sizes of buffers, which
  BendKV does not have): the client's own line, LIST by ids and types and their errors,
  the name, the database, the last command and idle time of another client, the flags
  P, x (and the client's line while EXEC runs its commands), b, d and e, KILL's errors,
  KILL of another client by id, address, local address, type and user, of itself, of a
  waiting client, of a client in MULTI, KILL in a transaction and KILL of all; then
  under load: 100 clients listed, half of them killed by id, and 200 clients killed by
  address while others connect and leave — and no one killed but those named (section
  44 of docs/PERFORMANCE.md).
- **MONITOR** (`tests/monitor_test.py`, in each server mode): MONITOR scenarios on
  BendKV and on Redis, their transcripts compared line by line, a monitor's line without
  the time and the client's address (41 lines: a command's case, bytes in quotes, an
  inline request; what is not shown; transactions, EXEC and its errors; the database
  after SELECT, SWAPDB and MOVE; AUTH and HELLO; blocking commands; the monitor's own
  commands; a subscription; CLIENT REPLY; a client without a password; monitors started
  in the middle of a transaction and of a wait; the flag O; RESET, QUIT and CLIENT KILL;
  INFO's statistics); then under load: four monitors each get all the lines of 20
  clients that pipeline 200 SETs each, each client's lines in order (section 45 of
  docs/PERFORMANCE.md).
- **CLIENT PAUSE and UNPAUSE** (`tests/pause_test.py`, in each server mode): scenarios
  on BendKV and on Redis, their transcripts compared line by line (28 lines: the errors;
  a pause of writes, what it holds back and lets run, and its client as CLIENT LIST and
  INFO show it; a pause of all ended by its time, with a CLIENT UNPAUSE and a QUIT held
  back; MULTI, EXEC and DISCARD under a pause; a pause a transaction starts, and one in a
  pipeline; keys whose time passes while it holds; a subscriber, PUBLISH and a monitor; a
  pause of writes made one of all; a blocking command's timeout; the order the clients go
  on in; a client held back that leaves or is killed; the parser's errors); then BendKV
  alone: CLIENT UNBLOCK where Redis differs, 100 clients held back and answered in order,
  and 100 let go by a pause's end (section 3zzk of docs/FINDINGS.md).
- **Lua scripts** (`tests/script_test.py`, in each server mode): scenarios on BendKV and
  on Redis, each with clients of its own, their replies compared byte for byte (EVAL's
  replies of every Lua type in RESP2 and RESP3, KEYS and ARGV; `redis.call` and
  `redis.pcall`, the errors of calls and the commands a script may not call; error texts
  with their suffix; the script cache, EVALSHA, EVAL_RO, EVALSHA_RO and the shebang;
  cjson, cmsgpack, bit, struct and Redis's random numbers; scripts in MULTI and EXEC and
  with WATCH; INFO's statistics after scripts; a script past `lua-time-limit`, BUSY,
  SCRIPT KILL and UNKILLABLE; the slow log and the latency monitor of scripts; scripts in
  pipelines, and the pushes of a subscribed client's script in their order; scripts under
  a pause of writes, by their flags) (section 3zzzd of docs/FINDINGS.md).
- **Functions** (`tests/function_test.py`, in each server mode): scenarios on BendKV and
  on Redis, their replies compared byte for byte, a reply that lists libraries or
  functions as a set (FUNCTION LOAD and each of its errors, the library API at load time;
  FCALL and FCALL_RO, each type a function returns in RESP2 and RESP3, numkeys's errors
  and the flags; LIST, DELETE, FLUSH, STATS, KILL and HELP; DUMP's bytes and RESTORE's
  policies, collisions and bad payloads; functions in transactions and with WATCH;
  INFO's statistics; a function past `busy-reply-threshold`, BUSY, FUNCTION STATS while
  it runs, FUNCTION KILL and UNKILLABLE), and each server's payload restored on the
  other; the libraries in both files, at the start and after a rewrite, both ways
  (`tests/rdb_test.py`, `tests/aof_redis_test.py`, `tests/rewrite_test.py`) (section
  3zzzp of docs/FINDINGS.md).
- **The administrative commands** (`tests/admin_test.py`, in each server mode):
  scenarios on BendKV and on Redis, their replies compared (97 lines: LASTSAVE as INFO's
  rdb_last_save_time; ROLE; WAIT's errors, its answers at once and when its time is up,
  in MULTI, a client that waits as CLIENT LIST and INFO show it, CLIENT UNBLOCK both ways;
  MEMORY's subcommands, STATS's fields in order and the kinds of their values; LOLWUT's
  text, errors and eleven drawings of VERSION 5 byte for byte, the shapes of random ones
  and of VERSION 6; SHUTDOWN's errors and its refusal in MULTI; the statistics); then
  SHUTDOWN and its forms on a redis-server and a BendKV of their own (the exit code, the
  closed connection, the append-only file and the pid file after it, SHUTDOWN SAVE and
  a save that fails), and BendKV alone: MEMORY STATS's numbers as INFO's, a SHUTDOWN
  while a rewrite of 200,000 keys runs (section 3zzl of docs/FINDINGS.md).
- **GEO** (`tests/geo_test.py`, with the server's defaults): the same commands on BendKV and on
  Redis, in RESP2 and RESP3, every reply compared byte for byte and, after each write,
  the sorted set it leaves and its time to live: the cases of Redis's unit/geo and of
  `geo.c` (GEOADD's options and errors, the searches' options, their errors and the
  order they come in, STORE and STOREDIST, COUNT and ANY, points at the same distance,
  which pqsort leaves in an order of its own, boxes across the antimeridian and near the
  poles), random sets and searches, a search of 20,000 points, the keyspace events,
  MULTI, COMMAND GETKEYS and the statistics (section 3zzm of docs/FINDINGS.md).
- **DUMP and RESTORE** (`tests/dump_test.py`, against Redis with `rdbcompression no` and
  `sanitize-dump-payload yes`): values of every kind and encoding made on both servers,
  their payloads compared byte for byte where both hold them alike, each restored on
  each server (Redis's compressed ones too) and read back with its encoding; RESTORE's
  options, errors and times in RESP2 and RESP3; payloads of the encodings Redis no
  longer writes, and 1,500 payloads cut, grown and changed at random, restored on both;
  the keyspace events, IDLETIME and FREQ under LRU and LFU, MULTI, WATCH, COMMAND
  GETKEYS, the statistics and values of up to 100,000 elements (section 3zzu of
  docs/FINDINGS.md).
- **AUTH** (`tests/auth_test.py`, in each server mode): scenarios on BendKV and on
  Redis, their transcripts compared line by line — when a client must authenticate and
  what it is answered before that: commands with errors of each kind, one at a time and
  pipelined, before AUTH and after, a failed AUTH, HELLO, RESET with a password and
  without, a password removed and set again, a transaction, a subscribed client, INFO's
  statistics (section 46 of docs/PERFORMANCE.md).
- **RESP3** (`tests/resp3_test.py`): 14 scenarios on BendKV and on Redis compared byte
  for byte — HELLO and its errors; the protocol switched in the middle of a pipeline
  (with CLIENT REPLY OFF too); nulls and doubles; maps, sets and pairs; the server's
  replies (CONFIG GET, CLIENT TRACKINGINFO, INFO, COMMAND INFO and DOCS); EXEC's replies
  and an EXEC that WATCH aborts; blocking commands that time out and that are served;
  Pub/Sub's pushes to a RESP3 and a RESP2 subscriber; a subscriber that switches its
  protocol; keyspace events of a client's own commands; a client's own pushes in a
  transaction and a script, and those of pops served; the classes of events set within a
  pipeline and a transaction; pipelines of the fast way. And
  the differential tests of times to live, numbers, BITFIELD, hashes, lists, sets,
  sorted sets and the random stream again, with every connection in RESP3 (`RESP=3`).
  Of the 16 constructors of a reply, RESP2 writes the 8 new ones as it wrote what they
  replace: every RESP2 test passes as before (section 49 of docs/PERFORMANCE.md).
- **The rewrite of the append-only file** (`tests/rewrite_test.py`): BGREWRITEAOF's
  replies and INFO's fields against Redis's line by line (started, and refused while one
  runs; in EXEC, scheduled; in EXEC while one runs; argument errors; CONFIG RESETSTAT;
  the statistics of the call and of its errors); the same databases on both, rewritten
  by both, BendKV's file against Redis's base command for command (each key's commands,
  how many elements each holds, the elements themselves and the time), BendKV and Redis
  started from BendKV's file; 150 thousand keys and writes of all kinds on five
  databases (SWAPDB, MOVE, COPY, RENAME, transactions, FLUSHDB) to BendKV and to Redis
  during the rewrite and after it, the databases compared, then BendKV and Redis from
  the new file; BendKV, killed (SIGKILL) in the middle of a rewrite, comes up from the
  old file with all the acknowledged writes; `appendonly no`; the cron's rewrites on the
  file's growth; failed rewrites, their count, the log and the cron's limit after three
  in a row (section 47 of docs/PERFORMANCE.md).
- **Redis 7's directory of files** (`tests/aofdir_test.py`): BendKV and Redis each start
  on a copy of the same `appendonlydir`, and their databases, manifests, files and the
  lines they log are compared: Redis's directory, with an RDB base and with one of
  commands; an empty directory, then writes and rewrites on both; an old single file
  moved in, with an empty directory and with an upgrade stopped half way; manifests
  Redis refuses; files cut short, last or not, and a file not there; history files,
  removed or kept (`aof-disable-auto-gc`); a rewrite with `appendonly no`.
- **maxmemory and eviction** (`tests/maxmemory_test.py`): the transcripts of BendKV and
  Redis are compared line by line — the OOM refusals past `maxmemory` under noeviction,
  and in MULTI (the transaction flagged, EXEC aborted, a transaction of reads and DISCARD
  pass), with INFO's counts of rejected calls and of the error; OBJECT IDLETIME while keys
  are read, written, touched (TOUCH) and looked at without touching (TTL, TYPE, EXISTS),
  and OBJECT FREQ under an LFU policy, each with its refusal under a policy of the other
  kind; the `evicted` event of a key evicted at once by CONFIG SET `maxmemory`. Then
  Redis's own tests of the policies (`unit/maxmemory.tcl`, which its suite runs only on a
  server it started itself) on both. And BendKV alone: the log's warnings, as Redis's; an
  eviction out of time that goes on without requests (200 thousand keys, the memory back
  under the limit, `evicted_keys` and the time past the limit counted); keys evicted with
  the append-only file on are gone from the file too (a restart holds what is left); an
  eviction while the append-only file is rewritten counts the keys the snapshot holds as
  freed and does not evict all the keys (section 48 of docs/PERFORMANCE.md).
- **The RDB file** (`tests/rdb_test.py`): files Redis writes, with LZF and without, of
  keys of every kind and encoding in several databases, and a file of the encodings
  Redis no longer writes: BendKV and Redis start from each, and every key of every
  database reads back the same, with the counts and lines of the load; BendKV's SAVE,
  which `redis-check-rdb` finds whole, loaded by Redis and by BendKV; SAVE, LASTSAVE,
  INFO's fields and the saves of FLUSHALL and SHUTDOWN against Redis's transcripts;
  files that do not load, each stopping both starts with Redis's line (section 3zzzc of
  docs/FINDINGS.md).
- **Background saves** (`tests/bgsave_test.py`): the count of changes of writes of
  every kind, alone, in a pipeline and in MULTI; BGSAVE's replies, INFO's fields while
  it runs and after it, the file and the log; BGSAVE and BGREWRITEAOF scheduled while
  the other runs; the save points; MISCONF after a save that failed, for each command of
  a pipeline, and the cron's next try; the parameters a save keeps from its start, and
  its temporary file removed while it runs; SHUTDOWN and FLUSHALL while a save runs;
  the default save points, all against Redis's transcripts (section 3zzzk of
  docs/FINDINGS.md).
- **The end of a connection** (`tests/conn_test.py`): connections end by every path —
  the client closes after a request and before one, QUIT, a protocol error, a reset
  before the server has read the request and while it sends a reply of a megabyte — 50
  times each, on a BendKV of its own in the post and send modes; then INFO counts the
  test's one connection, the database answers a new connection, and the runtime's table
  of channels (`chan_len`, read in the server's memory through `/proc/<pid>/mem`) does
  not grow: each connection closed its channel (4 rows after, 3 before; before the fix,
  304 after).
- **Protocol edges** (`tests/protocol_test.py`): 84 cases after Redis's own
  `tests/unit/protocol.tcl` and after `processMultibulkBuffer` — empty and negative
  counts, bad lengths, inline requests with quotes and escapes (`\xHH`, `\n`, `'...'`),
  unclosed quotes, inline longer than 64 KB, a NUL before the newline, an unknown
  command with its first arguments; lengths with a leading `0`, `-0`, counts down to
  -2^63 and past it, lines that a `\r` with another byte ends, that wait for a `\r` (or
  a NUL hides it) or are longer than 64 KB, bytes after a bulk's data that are not
  `\r\n`; errors with CR, LF and NUL in the text (HELLO, unknown commands and
  subcommands, CONFIG SET, a byte in place of `$`), protocol errors with CLIENT REPLY
  OFF and SKIP (no reply; the connection is open, and the requests after the error do
  not run) — are compared with Redis byte for byte, together with whether the server
  closes the connection: an open connection shows in INFO's connected_clients, a closed
  one by the end of file, not by silence on the socket; and each reply of BendKV is
  parsed as RESP.
- **Connection commands** (`tests/session_test.py`): 51 cases — HELLO with versions and
  options, AUTH without a password, SELECT with numbers of all kinds, databases kept
  apart, MOVE (with a time to live too), SWAPDB, RESET, which selects database 0 again,
  TYPE, TOUCH, OBJECT (under the LFU policy too), CLIENT subcommands with arity errors
  and unknown subcommands, CLIENT REPLY OFF/ON/SKIP mixed with other commands, QUIT
  dropping the tail of the batch, FUNCTION FLUSH, mixed pipelines — are compared with
  Redis (both with 16 databases) byte for byte; client ids are masked, and TIME is
  compared to the second (HELLO 3 and RESP3 have a test of their own, above). One known
  difference is left out of the comparison: QUIT with CLIENT REPLY OFF, after which
  Redis leaves the connection open but reads it no more, while BendKV closes it.
- **CONFIG** (`tests/config_test.py`): all 191 keys of CONFIG GET * at start (except
  the port) match Redis; 146 prepared cases (patterns, alias names, hidden parameters,
  immutable and protected ones, repeats, rollback on a bad value and on a failure to
  apply, memory with units and overflow, percentages, flags, save,
  client-output-buffer-limit, notify-keyspace-events, percentiles) and thousands of
  random values for each parameter that can be changed — replies byte for byte, and the
  values read back are the same. Pattern matching is checked against a port of Redis's
  `stringmatchlen` on 1,400 random patterns. Of Redis's own suite, all 8 CONFIG tests in
  `unit/introspection` pass (sanity, rollback, duplicate, immutable, hidden, multiple
  args).
- **INFO** (`tests/info_test.py`): 31 ways to choose sections (no arguments, default,
  all, everything, each section, several, different case, unknown ones, repeats) — the
  same sections and the same fields in the same order as in Redis; the values that do
  not depend on the machine and the moment (versions, modes, parameters, replication)
  the same; run_id and master_replid 40 hex digits each; the keyspace after three keys
  and empty, as in Redis; the counters after CONFIG RESETSTAT (connections accepted,
  commands run, connections open) the same on the same commands and connections.
- **Statistics per command** (`tests/stats_test.py`): the same requests on BendKV and
  Redis after CONFIG RESETSTAT — one at a time, in pipelines of one command and mixed,
  with errors among them, a pipeline over 64 KB, replies held back by CLIENT REPLY OFF
  and SKIP, NOAUTH and WRONGPASS, commands after QUIT, protocol errors, random
  pipelines — then commandstats (calls, refused and failed), errorstats and the totals
  are compared as maps (the order of Redis's lines comes from a hash table; usec, which
  depends on the machine, is left to `tests/timing_test.py`): 44 checks.
- **The timing of calls** (`tests/timing_test.py`): scenarios on BendKV and Redis with
  clients of their own, their transcripts compared with what depends on how long a call
  took put aside: SLOWLOG's and LATENCY's errors, arities and help in RESP2 and RESP3;
  the slow log with every call logged (arguments as sent and cut, secrets redacted,
  rewritten commands as they came, EXEC's commands, a served BLPOP), its counts, RESET
  and `slowlog-max-len`; LATENCY with no event; histograms after CONFIG RESETSTAT;
  latencystats with its parameters; usec_per_call as Redis divides.
- **COMMAND** (`tests/command_test.py`): COMMAND INFO and DOCS of each command and
  subcommand, one at a time, several at once, in another case, unknown ones and those
  Redis does not find (`get|key`, `config|get|key`); COMMAND, INFO and DOCS of all;
  LIST whole and with filters — by each ACL category, by patterns, by module — and its
  syntax errors; GETKEYS and GETKEYSANDFLAGS of command lines of each command with keys
  (and random ones), of commands without keys, of unknown commands and subcommands; the
  errors of COMMAND itself and its HELP. BendKV's reply is compared with Redis's reply
  with only BendKV's commands left in it, in order of names (Redis lists commands in the
  order of a hash table with a random seed); where the order does not come from the
  table, byte for byte.
- **SCAN and RANDOMKEY** (`tests/keyspace_test.py`): BendKV's replies to them are its
  own (the cursor, the order of keys, the choice of a key), so what is checked is what
  Redis promises. Argument parsing (37 cursors and 34 command lines, errors byte for
  byte); full iterations over 0 to 5,000 keys (binary ones and an empty one among them)
  with COUNT from 1 to more than there are keys, with MATCH and TYPE — the same keys as
  in Redis, each once, in no more than keys / COUNT + 1 calls; an iteration while
  another client deletes and adds keys finds every key that was there all along;
  RANDOMKEY on an empty database, on one key, on several (each comes up), on 1,000 (none
  more than four times as often as the mean), in a pipeline that empties and fills the
  database, and inline; KEYS and SCAN's MATCH on patterns that only matching with
  Redis's cut-offs answers at once (adjacent stars, branches that match at once or
  nowhere, stars deeper than 1,000 calls; without one of the cut-offs they need from
  3.4·10^11 calls to more than 10^59): the replies are the same as Redis's and come
  within the client's timeout: 1,052 checks.
- **Start-up** (`tests/start_test.py`): 49 cases that Redis refuses (unknown
  directives, the number of arguments, quotes, each type of value, `dir`, `logfile`,
  `include`, an error in an included file on its line, a busy port, port 0, an empty
  `bind`) — the same exit code and the same report (except the line with the server's
  name) or the same last line of the log; 32 cases that both start (parameters after the
  file, `save` adding up and reset, also after `include`, `--save` without a value,
  alias names, quotes and escapes, `hz` out of bounds, memory units, a relative `dir`
  and an `include` after it, standard input) — the same values of CONFIG GET; 16
  refusals of BendKV itself, and what is BendKV's alone: `--version`, the short form, a
  log in a file, a pid file, protected mode, two addresses with shared numbering of
  clients.
- `tests/smoke.bend` — an end-to-end run "buffer → parsing → execution → RESP" without
  the network.
- **Numbers at the edges** (`tests/numbers_test.py`): each command that takes a number
  gets numbers above long long, LLONG_MAX and LLONG_MIN, 2^48, 2^32, 2^31, 2^58 + 1 (an
  offset `#k` of an i64 field that, multiplied by 64, wraps around to 64) and the forms
  Redis refuses (`+5`, `1e5`, `0x10`, `" 5"`, `-0`, `00`, `3.5`), INCRBY, DECRBY and
  HINCRBY on values at LLONG_MAX and LLONG_MIN too — 2,541 commands, replies as in Redis
  (except SCAN with a foreign cursor). The test found that `SELECT 9223372036854775807`
  stopped the server (section 28 of PERFORMANCE.md).
- **Floating-point numbers** (`tests/float_test.py`): the library `src/float.bend`
  against glibc — random texts of numbers (decimal and hex of up to 800 digits, exact
  midpoints between adjacent doubles and long doubles, the edges of the ranges, forms
  strtod reads only in part), read and written as a double (`"%.17g"`) and as a long
  double (`"%.17Lf"`), sums and products; a C program with glibc's strtod, strtold and
  printf (`tests/float_ref.c`) answers as Redis does, and the replies are compared byte
  for byte.
- **BITFIELD** (`tests/bitfield_test.py`): 3,000 random commands on three keys —
  fields of all types at offsets of up to 256 bits or `#k`, values at the edges of the
  fields and of long long, all kinds of overflow; after each, the key's value is read.
  Replies and values as in Redis.
- **Many clients.** `make test` runs the robustness and differential tests with the
  writer and without it. `tests/concurrency_test.py` checks three things under many
  clients: no INCR is lost, an MSET of sixteen keys is atomic for MGET, and the order of
  one client's writes to different keys is seen by others as in Redis.
- **The append-only file.** `tests/aof_check.bend` writes the log of a batch, reads it,
  runs it and compares the database (and the replay with its check, as at start), then
  cuts the file at each of its 7,646 lengths and checks that what was read and the
  leftover together make the cut piece, and that the leftover holds no whole entry; the
  same for a log of acts on several databases (SELECT, SWAPDB, both steps of MOVE, COPY
  as BendKV writes it and as Redis writes it, FLUSHALL): the databases after the replay
  are the same, and each of its 1,251 cut pieces reads. Then files the start must
  refuse (an unknown command, a wrong number of arguments, an argument that does not
  read, a database that is not there, a server command, an unclosed transaction), each
  with the entry's number and its byte, and a file as Redis writes it (SELECT, MULTI and
  EXEC), which replays. Any failed check ends the run with exit code 1, as does a
  mismatch of replies in `tests/smoke.bend`, and `make smoke` also runs both with a
  deliberately wrong expectation of one kind of check (`BENDKV_CHECK_BREAK`): the run
  must fail (`tests/smoke_check.sh`).
  `make test` runs the whole suite on a server with an append-only file too, and then
  restarts it: a random stream with a FLUSHALL in the middle (it moves over databases,
  moves keys and swaps databases) plus 20 thousand keys, a restart from the file, a
  comparison of the whole keyspace of each of the 16 databases (matched: 20,237 keys);
  an entry cut short appended, a restart that cuts it off, and the same keyspace again.
  `tests/crash_test.py` kills the server (SIGKILL) at random moments while clients
  write, 20 rounds on one file, and each start must hold the databases after a prefix of
  the commands sent, every acknowledged one among them (section 3zzq of
  docs/FINDINGS.md). `tests/aof_fail_test.py` breaks the disk under the log with the shim
  `tests/fail_io.c` (`LD_PRELOAD`): a file that is there but does not read makes the
  server refuse to start, with the file untouched; a failed `fsync` with `everysec` and
  `always` stops it; a new file is made, its directory is synced, and only then does the
  server answer (the shim writes the order of the calls to a trace), and a failed
  `fsync` of the directory makes it refuse to start before the first reply; files the
  start refuses give a refusal with the entry's number and its byte, the file untouched.
  `redis-check-aof` from Redis 7 accepts BendKV's files as valid (with SELECT, SWAPDB,
  MOVE, COPY and FLUSHALL), Redis 7.0.15 and 7.2.16 load BendKV's append-only file and
  get the same data in the same databases, encodings too, and BendKV loads an append-only
  file written by Redis (with `SELECT`, command names in lower case, GETSET already
  rewritten as SET, and COPY as the client sent it). `tests/aof_redis_test.py` (in
  `make test`) checks this both ways: the same commands go to BendKV and to
  redis-server, each with its own log, then BendKV starts from Redis's file and Redis
  from BendKV's, and each holds the same databases the other held.

### Performance (`make bench`: 20 clients, 100 thousand requests, ops/s)

BendKV is built by Bend with the patches from [`bend-patches/`](bend-patches/) and
clang 19. Medians of five runs. As in `make bench`, FLUSHALL runs before each test, so
GET with random keys reads an empty database. Measurements on a filled database are in
[PERFORMANCE.md](docs/PERFORMANCE.md), sections 7.14, 9 and 10: there GET gives 1.62 of
Redis's speed, SET 1.82, INCR 1.45. The table below was taken before short strings in
the term (section 7.8).

| test | Redis 7.0.15 | BendKV | BendKV / Redis | BendKV on the original Bend |
|---|---:|---:|---:|---:|
| PING, no pipeline | 93,985 | 112,486 | 1.20 | 122,549 |
| SET, 1 key, no pipeline | 89,526 | 118,343 | 1.32 | 79,428 |
| GET, 1 key, no pipeline | 94,877 | 114,811 | 1.21 | 83,472 |
| SET, 100k keys, no pipeline | 104,384 | 123,153 | 1.18 | 60,716 |
| GET, 100k keys, no pipeline | 92,593 | 115,075 | 1.24 | 77,459 |
| INCR, 100k keys, no pipeline | 97,561 | 120,773 | 1.24 | 48,008 |
| PING, pipeline 16 | 1,587,302 | 1,587,302 | 1.00 | 568,182 |
| SET, 1 key, pipeline 16 | 1,234,568 | 1,298,701 | 1.05 | 138,313 |
| GET, 1 key, pipeline 16 | 1,449,275 | 1,785,714 | 1.23 | 186,567 |
| SET, 100k keys, pipeline 16 | 892,857 | 877,193 | 0.98 | 64,725 |
| GET, 100k keys, pipeline 16 | 1,428,571 | 1,449,275 | 1.01 | 98,425 |
| INCR, 100k keys, pipeline 16 | 1,020,408 | 662,252 | 0.65 | 48,520 |

Without pipelining both sides are bound by network latency, and the difference is
within the noise. At pipeline 16 the bound is the CPU: here one sees what each request
costs.

- **Memory:** ~950 thousand keys with 3-byte values take 60 MB of RSS in BendKV
  against 121 MB in Redis (section 7.13); a million keys with 100-byte values, 183 MB
  against 211 MB (section 13). On the original Bend it was 543 MB (≈5×). The key
  `key:000000012345` is 32 bytes of buffer with no node instead of 256 bytes of cells.
- **Large values:** SET of 1 MB takes 4.4 ms, GET 1.4 ms in BendKV (it was ~0.1 s)
  against ~1 ms in Redis.
- **Where the time went on the original Bend** (callgrind, SET with random keys): ≈50%
  went to memory management. That is freeing cells and the 8-byte counter cells the
  compiler creates on *building* each value of a "hot" (shared anywhere) type. ≈20%
  went to list strings and byte conversion, ≈11% to the trie, ≈5% to RESP parsing. The
  verified core itself is the smaller part of the cost; the main part is the
  representation of data.
- **What was fixed** (in detail in [PERFORMANCE.md](docs/PERFORMANCE.md)):
  - in Bend: lazy sealing of reference counts; packed strings in the C runtime;
    `TCP.recv_raw`/`send_raw`; borrowed reads (a field of a lent value is kept in place
    instead of making the whole value owned); native `++`, `length`, `eq`, `take`,
    `drop`, `hash`, `code_at`, `find`, `slice` and `Nat.show` on packed strings;
    literals and digits written straight into the spare room of the reply buffer;
    strings of up to 6 bytes right in the term word; rebuilding a node in place (across
    a call the node is kept, not its fields); 2 MiB pages for the heap; selecting a
    node's field by digit with one load, without a jump table and with one continuation
    instead of sixteen; a string of one chunk as the buffer's term itself, with no node;
    the hint to the processor `Mem.prefetch`; `IO` in direct continuations (a `do` block
    calls effects directly, without `IO.bind` closures);
  - in BendKV: I/O by buffers; a 16-child trie; reads without sharing the database;
    requests parsed by index straight into a command with the key's hash; a reply built
    from the end into one buffer; a command chosen by the length of its name; INCR's
    number parsed by index, without taking the string apart; batch hints: the paths of
    all the batch's keys are loaded level by level before it runs.

  Allocations per SET are now 62 instead of 392, per GET 35 instead of 305.

### The trust boundary

The proofs cover `map.bend`, `redis.bend`, `batch.bend`, `aof.bend`, `session.bend`,
`config.bend` and the laws themselves. What remains trusted:
1. **The Bend compiler and runtime.** `U32` in theory is a vector of 32 bits
   (`Word(32n)`), in the runtime a machine u32; `Nat` in theory is unary, in the
   runtime a 64-bit word with an abort past 2^48−1; `String` in theory is a list, and in
   the C runtime with the patch a chain of byte buffers, and `String.eq`, `String.hash`
   and the other operations on it are C functions. That the runtime agrees with the
   definitions is not proved. The server is built by Bend with the patches of
   [`bend-patches/`](bend-patches/) (counted in [README.md](README.md#in-numbers)). They
   are in the trusted base too: checked by Bend's test suite, by differential tests
   against Redis and under the sanitizers (`tools/sanitize.sh`), but not proved. The
   same goes for
   event loops on several threads, `epoll`, the atomicity of `Chan.send_all`, the writer
   thread and the sends the loop shares with it, the file
   `write`/`read`/`fdatasync`/`ftruncate`, `Chan.drain`, the native
   `String.dec_line_at` and `hash_at`, the translation of `IO` into continuations and
   the layout of records wider than 32 words as a node of their own in the compiler. The
   translation of a Bend program into the language of the BendTT kernel is trusted too:
   the kernel itself is proved in Lean, the translation is not. After Bend 2 came out,
   several bugs were found in which `--verdict` passes while the kernel checked
   something other than what the source says
   ([#1186](https://github.com/bendlang/bend/issues/1186),
   [#1236](https://github.com/bendlang/bend/issues/1236),
   [#1247](https://github.com/bendlang/bend/issues/1247), open as of October 2026).
   Their conditions do not occur in BendKV's proofs (no specialized parameters of empty
   types, no law helpers named like Base's constructors, no name clashes through a colon
   and a dot), but the translation stays in the trusted base.
2. **`resp.bend`, `info.bend`, `command.bend`, `server.bend`, `startup.bend`,
   `float.bend`, `hll.bend`, `geo.bend`, `lolwut.bend`, `rdb.bend` and `aofdir.bend`** —
   the protocol, INFO, COMMAND, the network, start-up, the doubles in software, what
   HyperLogLogs, GEO and LOLWUT compute, DUMP's payloads and the manifest of Redis 7's
   append-only directory; they are checked only by tests (start-up against
   `redis-server`, `tests/start_test.py`, INFO by `tests/info_test.py`, COMMAND by
   `tests/command_test.py`, the doubles against glibc by `tests/float_test.py`, the
   others against Redis by `tests/hll_test.py`, `tests/geo_test.py`,
   `tests/admin_test.py`, `tests/dump_test.py` and `tests/aofdir_test.py`).
   With the append-only file, it is also trusted that the server appends to the file
   exactly the effects of each batch (a group of batches is written as one write: that
   the `encode` of a concatenation is the concatenation of `encode`s is a lemma of the
   proofs, `enc_cat`, which no law states). When the file ends in the middle of an
   entry, it is proved which database
   the server brings up and to which byte it cuts the file (`recover_cut`, `load_cut`);
   only the decision to cut is trusted: that the leftover is the start of an entry and
   not garbage, the server learns from the network parser of `resp.bend` (`cut_short`).
   For a cut file a mistake there can only stop a start, not change the database. The
   same with the check at start: it is proved that, having refused no entry, it gives
   the databases of `A.replay` (`checked_replay`), but not that it passes every file of
   BendKV. The definitions of `server.bend` with infinite loops are marked `@unsafe` and
   honestly stand outside the guarantees.
3. **clang, libc, the OS.**
4. **Resource limits** are outside Bend's logic. `Nat` overflow is prevented by
   construction: a long long kept as hi·10^9 + lo (hi below 10^10), times and other
   integers of ≤14 digits, lengths of ≤10 digits, the parser's fuel 2^32−1 (a request is
   no shorter than 4 bytes). But this is an argument, not a proved law. Running out of
   heap is an abort.

## Limits of Bend2 found in practice

- **No `match` on a computed value or on a let variable; recursion only structural,
  with no mutual recursion; a function can be called only above it in the file.** A
  forward declaration through `law` is allowed only to Base. Branches have to be moved
  into helper functions, and arguments are evaluated strictly — hence the "eager"
  computations (see `bget`, `bdel`) and the fuel in the parser. In KEYS this cost a
  lot: the old `glob` computed both branches of `Bool.or` for each `*`, that is, it
  tried all the splits of a key even for a pattern that matched at once (and the pattern
  `a*a*…a*b`, which matches nowhere, without Redis's cut-off hung the server for
  minutes — Redis's test suite found it); now KEYS matches as Redis's `stringmatchlen`
  does, with one function with an explicit mode and a cut-off.
- **Affinity.** A hypothesis that is a function (`∀k. …` or a refutation `a != b`) is
  used once, while equalities are `Data` and can be copied. So refutations are turned
  into equalities of boolean verdicts (`{False == str_eq(j,k)}`). For the same reason
  refinement proofs against a reference model with a ∀-invariant are awkward. We proved
  the laws directly. That is why the laws of the append-only file are stated from the
  server's start, for any history of batches, and the properties of the history they
  need are derived anew by a top-level function that can be called any number of times.
- **`case other` in a proof does not refine the goal.** In a function `case other`
  covers the remaining constructors, while in a proof the variable stays abstract
  ("`c`, but not `Get`"), and functions of it do not reduce. So the lemmas about
  commands list every constructor of `Cmd` (counted in
  [README.md](README.md#in-numbers)), most of them by refutations. That is why the
  connection commands are gathered into one command `Own`, and reads of one key into
  `Peek`: each group is one constructor in these lemmas, however many commands it holds.
- **The checker computes `Nat` in unary form.** A constant such as 10^14 overflows the
  checker's stack, so INCR's overflow check is done by the number of digits.
- **No tactics and no automation.** Each rewrite step is written by hand, with an
  explicit motive. The proofs came out about as long as the code — not bad for manual
  mode. Checking, though, is really fast.
- **`match` comes before local bindings, and a pair can be taken apart only as a
  variable.** `match x` after `%rewrite` or `+y = …` in the same body is not accepted;
  the checker cannot infer the taking apart of a nested pair `(a, (b, c))` in one body —
  the second level goes into a separate function. On the other hand there are the
  patterns `case 10n+m` and `case 1n++p` (a duplicable variable), which is what allowed
  dividing by 10 "by steps of ten".
- **Data representation:** in stock Bend strings are linked lists (a patch packs them
  in the C runtime, see PERFORMANCE.md), there are no 64-bit numbers, and there are few
  effects (in stock Bend, file I/O has no `fsync`; the twelfth patch adds it). For a
  DBMS this is the main practical blocker.

## How to run

Both the proofs and the server need Bend with the patches: the server uses
`TCP.recv_raw`/`TCP.send_raw` from the second patch, and the map hashes keys with
`String.hash`, which the fourth patch adds to Base; it hints the processor with
`Mem.prefetch` from the ninth, takes the writer thread (`TCP.post`) and `Chan.send_all`
from the tenth, and the append-only file takes `File.write_raw`, `read_raw`, `sync` and
`truncate` from the twelfth, `Chan.drain` from the thirteenth, and `File.truncate` with
a `Nat` size and `File.sync_dir` from the twenty-fourth. The parser reads number lines
and key hashes by index with functions of the seventeenth. Start-up changes the
directory and writes the pid and the date to the log with functions of the twentieth
(`IO.chdir`, `IO.cwd`, `IO.pid`, `IO.clock`); with the same functions INFO knows the pid
and the time. The connection of a waiting or subscribed client waits at once for its
socket and its channel (`TCP.watch`, `TCP.unwatch` from the twenty-fifth), and CLIENT
LIST, INFO and KILL take a socket's fd and addresses (`TCP.name`), shut a socket down
(`TCP.kill`) and mark a client's channel with its last command and time (`Chan.mark`,
`Chan.marked`) with functions of the twenty-seventh. The rewrite of the append-only file
puts the new file in place of the old one (`File.rename`) and removes the temporary one
(`File.unlink`) with functions of the twenty-eighth. INFO's `used_memory` and
`maxmemory` read the heap's account (`IO.heap`) of the twenty-ninth, and OBJECT IDLETIME
and FREQ and the eviction's LRU and LFU keep when a key was last touched with functions of
the thirtieth (`Mem.touch`, `Mem.cell`). GEO computes, and ZADD reads its scores, with
C's doubles, `F64` and `F64.read` of the thirty-third. The others only speed up the
runtime and the code.
The Makefile passes `CC=clang-19` to Bend if there is one: clang 18 ignores the
`preserve_none` convention, and the code comes out ~8% slower.

```bash
# Bend with the patches: a clone of bendlang/bend with the patches of bend-patches/ on it;
# --verdict needs Lean 4.34.0 (elan)
git clone https://github.com/bendlang/bend ../bend-patched
sh bend-patches/apply.sh ../bend-patched
B="bun ../bend-patched/bend2/main.ts"
make check BEND="$B"     # the proofs
make verdict BEND="$B"   # the proofs + a recheck by the BendTT kernel (the first time it builds the kernel, ~40 s)
make build BEND="$B"   # the native server build/bendkv (clang, ~40 s)
make run               # ./build/bendkv 6380 (./build/bendkv 6380 post — with a writer thread,
                       # ./build/bendkv 6380 send — without a writer,
                       # ./build/bendkv 6380 post data.aof always — with an append-only file;
                       # as redis-server: ./build/bendkv redis.conf --port 7777)
redis-cli -p 6380 set foo bar
make test BEND="$B"    # start-up (about a hundred command lines and files on both servers),
                       # robustness, a client that does not read, the differential
                       # test against redis-server and
                       # consistency under many clients: by default, with the writer,
                       # without it, with an append-only file; protocol edges, connection commands, CONFIG,
                       # INFO and COMMAND against Redis; restart from the append-only file and a cut tail;
                       # disk failures under the append-only file (needs a C compiler)
make pgo BEND="$B"     # build/bendkv-pgo: a build with a profile (needs llvm-profdata)
make bench BEND="$B"   # redis-benchmark: BendKV against Redis
make suite BEND="$B" REDIS_SRC=../redis   # Redis's test suite on Redis and on BendKV
                       # (a Redis 7.2.16 source tree with tests/, tclsh)
make clients BEND="$B" # redis-py's and go-redis's test suites on Redis and on BendKV
                       # (python3, go; PyPI and the Go module proxy)
```

## What next

1. **A drop-in replacement for Redis on one node (no changes to the client).** The goal
   and the measure are Redis's own test suite (`runtest --host --port`, external mode)
   and the tests of client libraries. First the protocol and the connection: protocol
   errors as in Redis, HELLO, SELECT, CLIENT, AUTH, INFO, COMMAND, CONFIG GET/SET, TYPE,
   RENAME, UNLINK, SCAN. Then the value as a sum of types with the WRONGTYPE error, and
   a model of time in the state for TTL; then the types one at a time, each with its own
   laws: hashes, lists, sets, sorted sets; then MULTI/EXEC/WATCH and pub/sub (done);
   then the rewrite of the append-only file and `maxmemory`. Out of scope: Lua and
   functions, streams, cluster, replication, modules. Done:
   protocol edges, connection commands (sessions with laws), CONFIG by the full table of
   Redis's parameters (with laws), INFO with Redis's sections and fields, COMMAND with
   the command descriptions from Redis itself, statistics per command in INFO
   (commandstats, errorstats), SCAN and RANDOMKEY, keys' times to live (EXPIRE and its
   kin, TTL, SET's options, GETEX, GETDEL — with laws and recovery from the append-only
   file with times), the sweep of expired keys, several databases (SELECT, MOVE, SWAPDB,
   FLUSHDB, FLUSHALL, keyspace lines per database — with laws and recovery of all the
   databases from the append-only file), the ranges and bits of strings (GETRANGE,
   SETRANGE, GETBIT, SETBIT, BITCOUNT, BITPOS — with a law of SETRANGE and recovery from
   the append-only file). Redis's suite in external mode: BendKV passes 1,676 of the
   1,812 tests Redis 7.2.16 itself passes, and 1,635 of 1,688 in the units of what it has
   ([docs/COMPATIBILITY.md](docs/COMPATIBILITY.md)). Start-up as for redis-server (the
   command line and the configuration file). The database as a record with a count of
   keys (DBSIZE in O(1)).
   TOUCH, TIME and OBJECT. MSETNX, RENAME and RENAMENX — with laws, commutativity for
   commands whose writes depend on other keys, and recovery from the append-only file.
   COPY (into the selected database or another one) — with a law and recovery from the
   append-only file, which also reads COPY as Redis writes it. BITOP — with a law and
   laws of commutativity; LCS. BITFIELD and BITFIELD_RO — fields of up to 64 bits (words
   of two U32 halves) logged as a SETRANGE of the bytes the writes reached. A value is a
   string or a collection, with the WRONGTYPE error, as in Redis, for a command of the
   wrong type (the basis for types; the price was a node per value, section 31 of
   PERFORMANCE.md, until patch 32 boxed a string as itself, section 56). Hashes (HSET and its kin, HINCRBY, HSCAN, HRANDFIELD; MEMORY USAGE)
   — a small hash in order of the fields' arrival, a large one in a trie of its own, as
   listpack and hashtable in Redis; logged as HSET and HDEL, and a hash over an expired
   key as one EVAL entry of a constant script (the laws of the append-only file require
   one entry per act; Redis writes a MULTI of two here). Lists (LPUSH and its kin,
   LPOP/RPOP with a count, LINDEX, LRANGE, LSET, LINSERT, LREM, LTRIM, LPOS, LMOVE,
   RPOPLPUSH, LMPOP) — a deque of two stacks; LMOVE and LMPOP with laws of commutativity
   for commands over several keys; logged as the write itself, and a move onto an
   expired key as one EVAL entry of a constant script. Sets (SADD and its kin, SPOP and
   SRANDMEMBER, SSCAN, SINTER, SUNION, SDIFF and their STORE forms, SINTERCARD, SMOVE) —
   intset and hashtable, as in Redis 7.0; SMOVE and STORE with laws of commutativity;
   logged as SADD and SREM, and STORE as the resulting members. Floating-point numbers
   in software (`src/float.bend`, double and x87 long double, checked against glibc):
   INCRBYFLOAT and HINCRBYFLOAT. Sorted sets (ZADD and its kin, ZRANGE in all its forms,
   ZREMRANGEBY*, ZPOPMIN/ZPOPMAX, ZMPOP, ZRANDMEMBER, ZSCAN, ZUNION, ZINTER, ZDIFF and
   their STORE forms, ZINTERCARD, ZRANGESTORE) — one string of its elements for a small
   set, a weight-balanced tree and a trie of members for a large one, as listpack and
   skiplist in Redis; STORE, ZRANGESTORE and
   ZMPOP with laws of commutativity; logged as the writes themselves, and STORE as the
   resulting pairs (the fourth constant script). The blocking commands of lists and
   sorted sets (BLPOP, BRPOP, BLMOVE, BRPOPLPUSH, BLMPOP, BZPOPMIN, BZPOPMAX, BZMPOP) and
   CLIENT UNBLOCK: the waiting clients are a chain in order of arrival that the actor
   looks through after each command that may make one ready (a batch that writes no key a
   client waits on or watches runs the fast way: section 3zzo of FINDINGS.md), and a
   connection waits at once for the actor's answer and for its socket (`TCP.watch`, the
   twenty-fifth patch); for them a compiler bug (the twenty-sixth patch) and a false
   firing of the socket watch were found and fixed (section 41 of PERFORMANCE.md).
   Transactions (MULTI, EXEC, DISCARD, WATCH, UNWATCH): the actor keeps a chain of the
   clients with a transaction or watched keys, the effects of each command touch the
   watched keys, and a transaction is logged between MULTI and EXEC; the laws of the
   append-only file are restated for transactions: a cut file gives the databases after a
   prefix of steps, where a transaction is one step, and the start reverts the transaction
   inside which the file was cut (section 42 of PERFORMANCE.md). Pub/Sub (SUBSCRIBE and
   its kin, PUBLISH, SPUBLISH, PUBSUB) and keyspace notifications
   (`notify-keyspace-events`): the session
   answers them as Redis answers a client alone on the server, so its laws did not
   change; the actor holds the subscriptions, a message to a client is a push onto its
   reply channel, a subscribed client waits at once for its socket and its channel with
   its loop's own steps, and a command's events are taken from its effects and from what
   its keys were before it and became after (section 43 of PERFORMANCE.md). CLIENT LIST,
   INFO and KILL: the clients' lines come from a registry in the actor's Pub/Sub state
   (the id, the reply channel, the fd, the addresses, the time of connection, the name,
   the database), and the last command and the batch's time are a mark on the client's
   reply channel (`Chan.mark`, the twenty-seventh patch), on the fast path one store per
   batch; a killed client is cut off by shutting down its socket (`TCP.kill`) at the end
   of the group (section 44 of PERFORMANCE.md). MONITOR: the monitors are a list in the
   registry of clients; after each call on the general path the actor writes the call's
   line and pushes it to the monitors, and takes the arguments as they were sent from
   the batch's bytes, which the parser returns with the batch, so the fast path pays
   nothing (section 45 of PERFORMANCE.md). Authentication as Redis decides it: an error
   the command itself finds reaches an unauthenticated client as NOAUTH, and a client is
   authenticated from connecting if there is no password then (section 46 of
   PERFORMANCE.md). The rewrite of the append-only file (BGREWRITEAOF and the cron's
   rewrites on the file's growth): a snapshot of the databases as commands, as Redis
   writes its base, a slice at a time between groups of requests, without `fork`, then
   the entries appended meanwhile, into a temporary file that takes the file's place
   (section 47 of PERFORMANCE.md); it is checked by tests against Redis but not proved
   (below). `maxmemory` and eviction: before each group of requests the actor reads the
   heap's account and evicts keys by Redis's policy — from a pool of the 16 best
   candidates of a sample, or at random by database — deleting them as the sweep deletes
   expired ones; when the keys were touched is kept in a table of words by the key's hash,
   outside the values (section 48 of PERFORMANCE.md); checked by tests against Redis, only
   the law of CONFIG SET proved. RESP3: replies typed where Redis types them, written by
   the encoder of the client's protocol (RESP2's bytes as they were), pushes for a
   subscriber in RESP3, the protocol a field of the connection that the laws of sessions
   take as they take the selected database (section 49 of PERFORMANCE.md); checked by
   tests against Redis byte for byte. The test suites of client libraries (redis-py's
   and go-redis's) run against BendKV and Redis in CI. SORT and SORT_RO: a stable merge
   sort of the elements with their weights read once, the patterns of BY and GET read
   once per SORT, and SORT with STORE an act of the database in focus that writes the
   list it makes (section 3zzh of FINDINGS.md); checked by tests against Redis.
   HyperLogLogs: PFADD, PFCOUNT, PFMERGE, PFDEBUG and PFSELFTEST on a string's bytes as
   Redis writes them, the estimate on doubles in software (section 3zzj of FINDINGS.md);
   checked by tests against Redis byte for byte. CLIENT PAUSE and CLIENT UNPAUSE: the
   commands a pause holds back wait, with the rest of their clients' batches, until it
   ends, while the data set is kept still (section 3zzk of FINDINGS.md); checked by tests
   against Redis. The administrative commands LASTSAVE, ROLE, WAIT, SHUTDOWN, MEMORY and
   LOLWUT: answered from the server's state as Redis answers them on a master with no
   replica, WAIT a blocking command that no replica ends, SHUTDOWN an exit after the
   append-only file is synced (section 3zzl of FINDINGS.md); checked by tests against
   Redis. GEO: its ten commands as Redis's `geo.c` runs them, on C's doubles (Bend's
   base runs them natively, patch 33), its sorts glibc's qsort and Redis's pqsort made
   step by step (section 3zzm of FINDINGS.md); checked by tests against Redis byte for
   byte. DUMP and RESTORE: Redis's payloads, every type Redis reads but streams' and
   modules', checked as deep as Redis checks them with `sanitize-dump-payload yes`
   (section 3zzu of FINDINGS.md); checked by tests against Redis byte for byte. CLIENT
   TRACKING: client-side caching as Redis's `tracking.c` keeps it, its invalidations
   pushed at once but to a client of RESP3 that others redirect to and that sends
   nothing, which gets them with its next reply (section 3zzzb of FINDINGS.md); checked
   by tests against Redis byte for byte. Lua scripts: EVAL, EVALSHA, EVAL_RO, EVALSHA_RO
   and SCRIPT on Redis 7.2.16's own Lua, driven a step at a time from the actor, a
   script's calls run as EXEC runs its commands (section 3zzzd of FINDINGS.md); Lua's
   functions, FUNCTION and FCALL, on the same engine, their libraries in both files
   (section 3zzzp); checked by tests against Redis byte for byte. ACL users: Redis's
   users, selectors, key patterns and channels, each call of a restricted client checked
   as Redis checks it (a script's and a function's with its caller's user), ACL LOG, and
   the clients ACL SETUSER and DELUSER close (section 3zzzh of FINDINGS.md); checked by
   tests against Redis line by line. The client libraries' suites find nothing else
   missing within the scope above but BGSAVE, an RDB file; the query buffer's limits are
   the next step.
2. **The append-only file, further.** A law of the rewrite: the rewritten file replays
   to the databases it was written from (key by key, not by the shape of the trie); it
   needs a law that a scan from the first bucket reads every key once (the invariant "a
   bucket holds no key twice", item 3), laws of RPUSH, SADD, HMSET and ZADD of a key
   that is not there, and that a number written as `%.17g` reads back as itself. A law
   of continuation: after a cut and new entries the file is the log of the history
   "prefix + new batches". And a law of invertibility of the network parser of
   `resp.bend`: the format of the append-only file is the same arrays of bulk strings
   that clients send, and that law would also prove the decision to cut a file cut
   short (`cut_short`).
3. **Laws for the new types.** The laws of commutativity are already generalized to
   commands whose writes depend on other keys (RENAME, MSETNX, BITOP, LMOVE, LMPOP);
   SUNIONSTORE and its kin will fit the same scheme. The invariant of the count of keys
   (DBSIZE is the size of the trie) and a law of KEYS's completeness; the same invariant
   ("a bucket holds no key twice") will let DBSIZE into the laws about swaps.
4. **Performance.** A request's time is now mostly system time: fewer system calls per
   request (`io_uring`, waiting for several ready sockets); post buffers without
   `malloc` (~690 instructions per request without a pipeline); the continuation after
   an effect without a task node; RESP parsing cheaper once more (~1,370 instructions
   per GET with the hash); bring the shards (the branch
   [`archive/shards`](https://github.com/littleBro/BendKV/tree/archive/shards)) back
   into the finished project in the next round of optimization, and test them on a
   machine where the server gets more than three cores. Interleaving pure tasks in the
   runtime on likely misses: the gain of the hints without manual batching. PGO in the
   Bend driver (in BendKV, `make pgo`), a hardware hash (the key is hashed twice: for
   the hints and in `exec`), INCR in one pass over the trie. Offer the patches to
   `bendlang/bend` (remove the regression on the `lexer` benchmark and the cost of 2 MiB
   pages for short programs, and fit under the size cap of `comp.ts`; first lazy
   sealing: the best ratio of gain to cost, and it fits in the room left under the cap;
   then the translation of `IO` into continuations). See
   [PERFORMANCE.md](docs/PERFORMANCE.md), sections 7.14, 7.17, 7.23, 7.24, 9.6, 11 and 14.
5. **The SQL direction:** a verified in-memory B+-tree, then a small engine of
   relational algebra with laws of the optimizer's correctness (after the model of
   `demos/proof_typed_eval`), and only then the disk.
