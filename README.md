# BendKV

BendKV is a key-value server compatible with Redis 7.0.15, written in
[Bend2](https://github.com/bendlang/bend). Its central guarantees are proved against 67 laws:

- no command changes a key it does not write, neither its value nor its time;
- a key whose time has passed is gone;
- a pipelined batch runs exactly as its commands, one after another;
- the append-only file, as the server appends it, restores exactly the databases the
  server held, and a file cut by a crash at any byte restores them as they were after
  some prefix of what ran, with no transaction applied in part;
- GET, SET, DEL, APPEND, RENAME and the other string and key commands the laws name
  answer and write as specified.

Bend checks the proofs, and the BendTT kernel, whose soundness is proved in Lean, checks
them again. What the other commands answer (those of hashes, lists, sets, sorted sets and
the rest) is tested byte for byte against a real `redis-server`.
[What is proved](#what-is-proved) has the details.

BendKV speaks RESP2 and RESP3, so `redis-cli`, `redis-benchmark`, `memtier_benchmark` and
clients that speak RESP3 by default (go-redis v9, Lettuce) work with it. Under pipelined
load it serves GET at 1.6×, SET at 1.8× and INCR at 1.45× the throughput of Redis 7.0.15
on the same machine, with half its memory for small values ([Performance](#performance)).

> **Status: research prototype.** Do not use it for data you cannot lose. The goal is a
> drop-in replacement for a single Redis node, measured by Redis's own test suite: of the
> 1,677 tests Redis 7.0.15 passes against a server it did not start, BendKV passes 1,292,
> and 1,289 of the 1,355 in what it implements
> ([docs/COMPATIBILITY.md](docs/COMPATIBILITY.md)). [What works](#what-works) lists what
> it implements, and what it does not have yet.

BendKV is an independent project. It is not affiliated with Higher Order Company or the
Bend project, nor with Redis Ltd. Redis is a trademark of Redis Ltd.

## Quick start

You need [Bun](https://bun.sh), clang 19 and Python 3. Build Bend with BendKV's patches
once, then BendKV:

```bash
git clone https://github.com/bendlang/bend ../bend-patched
sh bend-patches/apply.sh ../bend-patched        # Bend 2.0.35 with the patches of bend-patches/
export BEND="bun ../bend-patched/bend2/main.ts"

make check                                      # check the proofs
make build                                      # build/bendkv
./build/bendkv --port 6380
redis-cli -p 6380 set foo bar
```

[Building and running](#building-and-running) has the other targets and the server's
command line.

## Why

Most of what a key-value server does is a pure function,
`exec(command, db) -> (reply, db')`, and pure functions are what a proof assistant
handles best. BendKV asks how far one can get writing a real, fast server in a language
where the code that runs is the code that is proved, with no separate model and no
refinement proof.

The answer so far: the proofs are not what makes such a server slow. The runtime's data
representation was, and most of the work went into fixing it, with patches to the Bend
compiler ([`bend-patches/`](bend-patches/), counted in [In numbers](#in-numbers)). Most of
the patches speed up the runtime and its data representation. The others add what a
server needs from the system (the process's directory, id and clock, cutting and renaming
files, the heap's size, C's doubles), and one lets AddressSanitizer check the heap.

## What is proved

The laws are stated by people, in [`proof/LAWS.bend`](proof/LAWS.bend), and proved in
[`proof/PROOF.bend`](proof/PROOF.bend). They are about the server's own code, not about a
model of it:

- A database is a record: a hash trie whose entries hold each key's value (a string, or a
  collection) and the time it expires at; how many keys it holds (what DBSIZE answers) and
  how many of them have a time; and the time its batch runs at.
- The server holds several databases (16, as Redis does). The one a connection selected
  is in focus while its batch runs.
- A key whose time has passed is not there for any command.
- The laws about what keys hold and what commands answer are stated of the server's
  commands. They are proved through a specification of the commands on the bare trie
  ([`proof/SPEC.bend`](proof/SPEC.bend)), which a bridge in the proofs ties to the server's
  commands. The counts of keys are proved to be the trie's own.

| group | laws | what they say |
|---|---:|---|
| Map | 11 | The trie is a finite map from keys to a value and a time. After any sequence of writes (a value with a time, a value that keeps its time, a time alone, a deletion), every key holds what was last written to it: no stale, lost or foreign entries. A read sees a key only until its time. |
| Keys | 2 | Comparing keys is exactly string equality, down to the bits of `U32`. |
| Commands | 24 | No command changes a key it does not write, neither its value nor its time (`frame`). Reads leave the database as it was. A key whose time has passed is not there, and the sweep of expired keys deletes no key that is there. GET (of a key just set, and of a key that is not there), DEL, APPEND, SETRANGE (and so SETBIT), SETNX, INCR of a key that is not there, GETDEL, PERSIST, PTTL, SET with KEEPTTL, RENAME, MSETNX and BITOP answer and write as specified, in the cases their laws state. A pipelined batch runs as its commands in order, and the cache hints before a batch change nothing. The commands of hashes, lists, sets and sorted sets, PFADD, PFCOUNT of one key, PFDEBUG, and the commands that move between keys (LMOVE, LMPOP, SMOVE, ZMPOP, the STOREs) are reads and writes of their keys to these laws, so `frame`, the reads' law and the laws below hold of them; what they answer is tested, not proved. |
| Commuting | 5 | Commands on different keys commute: in either order they answer the same and leave every key the same, as long as neither writes a key that the other's writes depend on (RENAME, MSETNX, BITOP, LMOVE, LMPOP, SMOVE, ZMPOP and the STOREs write keys from other keys). Two such commands next to each other in a batch can swap places. DBSIZE, KEYS and SCAN, which look at the whole database, and SORT, whose patterns may read any key, commute with reads alone. |
| Persistence | 9 | Logging changes no reply. The file reads back as written, times included. After any history, each batch at its own time and on any of the databases, the server restores from its file exactly the databases it held. A file cut by a crash at any byte restores the databases as they were after some prefix of the server's acts, in which every transaction is whole. The start first checks that each entry replays as written, and when it refuses none, it holds what that replay gives. These laws are about the file as the server appends it: a rewritten file (BGREWRITEAOF, or the automatic rewrite), a file appended to after a start that cut it, and a tail of garbage that a power loss may leave are outside them ([#34](https://github.com/littleBro/BendKV/issues/34)). |
| Databases | 6 | SELECT changes no database and focuses the one it names. SWAPDB puts each of two databases in the other's place. FLUSHALL empties them all. MOVE takes a key's entry, its value and its time, out of the selected database and sets it in the other. COPY sets a key's entry at another key, in the same database or another, when that key is not there or REPLACE is given. |
| Key count | 2 | After any history, the counts each database keeps (its keys, and its keys with a time) are its trie's own, and its trie holds each key once; so DBSIZE answers the number of keys in its trie. |
| Sessions | 5 | However the server takes a batch apart, it runs it as its commands in order, with an append-only file or without. A batch changes the databases, and the file, exactly as its executed commands do. A client that has not authenticated to a server with a password can neither read nor change a key. |
| Configuration | 3 | A CONFIG SET that fails changes nothing. One that succeeds installs the new parameters, and their `requirepass` is the password from then on. After a CONFIG SET of a parameter, CONFIG GET finds the value its check gave. |

`make check` checks every proof in about 15 s, and `make verdict` checks them again in
the BendTT kernel in about two minutes.

### The trust boundary

The laws are about six files: `src/map.bend`, `src/redis.bend`, `src/batch.bend`,
`src/aof.bend`, `src/session.bend` and `src/config.bend`, those `proof/LAWS.bend`
imports ([Layout](#layout) shows which laws are about which file, and
[In numbers](#in-numbers) counts their lines). They state what the table above says, not
everything those files do. Everything else is trusted:

- **Tested against `redis-server`, not proved:** the RESP parser and the network shell
  (`src/resp.bend`, `src/server.bend`), the start (`src/startup.bend`), INFO and COMMAND
  (`src/info.bend`, `src/command.bend`), DUMP's payloads (`src/rdb.bend`), what
  HyperLogLogs, GEO and LOLWUT compute (`src/hll.bend`, `src/geo.bend`,
  `src/lolwut.bend`), and the doubles in software (`src/float.bend`, tested against
  glibc too).
- **Trusted as they are:** the Bend compiler and its C runtime, with the patches; clang,
  libc and the operating system.

This is not end-to-end verification in the sense of CompCert or seL4
([docs/FINDINGS.md](docs/FINDINGS.md), section 1).

The BendTT kernel is proved sound in Lean, but the translation from Bend to the kernel is
not. Since Bend 2's release, several bugs were reported in which `--verdict` passes while
the kernel checked something other than what the source says
([#1186](https://github.com/bendlang/bend/issues/1186),
[#1236](https://github.com/bendlang/bend/issues/1236),
[#1247](https://github.com/bendlang/bend/issues/1247), open as of October 2026). None of
their triggers occurs in BendKV's proofs (no specialized parameters over empty types, no
law helpers named like Base constructors, no colon/dot name clashes), but the translation
stays in the trusted base.

## What works

Each area links to [docs/COMMANDS.md](docs/COMMANDS.md), which says what its commands do
in detail. A command answers as Redis 7.0.15 does, byte for byte, unless
[Where BendKV differs](#where-bendkv-differs) says otherwise.

| area | commands |
|---|---|
| [Strings and keys](docs/COMMANDS.md#strings-and-keys) | GET, SET, SETNX, GETSET, MGET, MSET, MSETNX, APPEND, STRLEN, INCR, DECR, INCRBY, DECRBY, DEL, UNLINK, EXISTS, TYPE, TOUCH, RENAME, RENAMENX, COPY, DBSIZE, KEYS, SCAN, RANDOMKEY, OBJECT |
| [Times to live](docs/COMMANDS.md#times-to-live) | EXPIRE, PEXPIRE, EXPIREAT, PEXPIREAT, TTL, PTTL, EXPIRETIME, PEXPIRETIME, PERSIST, SET's options, SETEX, PSETEX, GETEX, GETDEL |
| [Floats](docs/COMMANDS.md#floats) | INCRBYFLOAT, HINCRBYFLOAT, computed as Redis computes them on x86-64 |
| [Ranges and bits](docs/COMMANDS.md#ranges-and-bits) | GETRANGE, SUBSTR, SETRANGE, GETBIT, SETBIT, BITCOUNT, BITPOS, BITOP, LCS, BITFIELD, BITFIELD_RO |
| [Hashes](docs/COMMANDS.md#hashes) | HSET, HMSET, HSETNX, HGET, HMGET, HDEL, HLEN, HSTRLEN, HEXISTS, HKEYS, HVALS, HGETALL, HINCRBY, HINCRBYFLOAT, HSCAN, HRANDFIELD |
| [Lists](docs/COMMANDS.md#lists) | LPUSH, RPUSH, LPUSHX, RPUSHX, LPOP, RPOP, LLEN, LINDEX, LRANGE, LSET, LINSERT, LREM, LTRIM, LPOS, LMOVE, RPOPLPUSH, LMPOP |
| [Sets](docs/COMMANDS.md#sets) | SADD, SREM, SCARD, SISMEMBER, SMISMEMBER, SMEMBERS, SSCAN, SPOP, SRANDMEMBER, SMOVE, SINTER, SUNION, SDIFF, SINTERSTORE, SUNIONSTORE, SDIFFSTORE, SINTERCARD |
| [Sorted sets](docs/COMMANDS.md#sorted-sets) | ZADD, ZINCRBY, ZREM, ZCARD, ZSCORE, ZMSCORE, ZRANK, ZREVRANK, ZCOUNT, ZLEXCOUNT, ZRANGE, ZRANGEBYSCORE, ZREVRANGEBYSCORE, ZRANGEBYLEX, ZREVRANGEBYLEX, ZREVRANGE, ZREMRANGEBYRANK, ZREMRANGEBYSCORE, ZREMRANGEBYLEX, ZPOPMIN, ZPOPMAX, ZMPOP, ZRANDMEMBER, ZSCAN, ZUNION, ZINTER, ZDIFF, ZUNIONSTORE, ZINTERSTORE, ZDIFFSTORE, ZINTERCARD, ZRANGESTORE |
| [SORT](docs/COMMANDS.md#sort) | SORT, SORT_RO |
| [HyperLogLogs](docs/COMMANDS.md#hyperloglogs) | PFADD, PFCOUNT, PFMERGE, PFDEBUG, PFSELFTEST, on Redis's own bytes |
| [GEO](docs/COMMANDS.md#geo) | GEOADD, GEOPOS, GEOHASH, GEODIST, GEORADIUS, GEORADIUSBYMEMBER, GEORADIUS_RO, GEORADIUSBYMEMBER_RO, GEOSEARCH, GEOSEARCHSTORE |
| [DUMP and RESTORE](docs/COMMANDS.md#dump-and-restore) | DUMP, RESTORE, with Redis's payloads |
| [Databases](docs/COMMANDS.md#databases) | SELECT, MOVE, SWAPDB, FLUSHDB, FLUSHALL; 16 databases, or as many as `databases` says |
| [Clients that wait](docs/COMMANDS.md#clients-that-wait) | BLPOP, BRPOP, BLMOVE, BRPOPLPUSH, BLMPOP, BZPOPMIN, BZPOPMAX, BZMPOP |
| [Transactions](docs/COMMANDS.md#transactions) | MULTI, EXEC, DISCARD, WATCH, UNWATCH |
| [Pub/Sub](docs/COMMANDS.md#pubsub-and-keyspace-notifications) | SUBSCRIBE, UNSUBSCRIBE, PSUBSCRIBE, PUNSUBSCRIBE, SSUBSCRIBE, SUNSUBSCRIBE, PUBLISH, SPUBLISH, PUBSUB; keyspace notifications |
| [Connections](docs/COMMANDS.md#connections) | PING, ECHO, TIME, HELLO, AUTH, QUIT, RESET, CLIENT (ID, GETNAME, SETNAME, REPLY, NO-EVICT, GETREDIR, TRACKINGINFO, CACHING, UNBLOCK, HELP), FUNCTION FLUSH |
| [Clients](docs/COMMANDS.md#client-list-info-and-kill) | CLIENT LIST, INFO and KILL; [CLIENT PAUSE and UNPAUSE](docs/COMMANDS.md#client-pause-and-unpause); [MONITOR](docs/COMMANDS.md#monitor) |
| [Server](docs/COMMANDS.md#server-commands) | LASTSAVE, ROLE, WAIT, MEMORY, LOLWUT, SHUTDOWN, BGREWRITEAOF |
| [Configuration](docs/COMMANDS.md#configuration) | CONFIG GET, SET, RESETSTAT, REWRITE and HELP, over every parameter of Redis 7.0.15 |
| [Introspection](docs/COMMANDS.md#info-and-command) | INFO, COMMAND, [SLOWLOG and LATENCY](docs/COMMANDS.md#slowlog-and-latency) |
| [Memory](docs/COMMANDS.md#memory-and-eviction) | `maxmemory` with every eviction policy; OBJECT IDLETIME and FREQ |
| [Persistence](docs/COMMANDS.md#the-append-only-file) | an append-only file in Redis's format, `appendfsync` always, everysec or no, BGREWRITEAOF and automatic rewrites |
| [Starting](docs/COMMANDS.md#starting) | `redis-server`'s command line and configuration file |
| [Protocol](docs/COMMANDS.md#protocol) | RESP2 and RESP3, pipelining, inline commands |

**Not yet:** streams; Lua scripts and functions; CLIENT TRACKING; RDB files (SAVE, BGSAVE,
loading `dump.rdb`); CONFIG REWRITE, which answers as Redis does without a configuration
file; replication, cluster, ACL users, modules and TLS.

## Performance

Pipeline depth 16, 20 clients, a filled database, 3-byte values, and Redis 7.0.15 on the
same VM, each server pinned to one core; medians over 8 to 13 interleaved pairs of runs:

| BendKV's throughput, as a share of Redis's | GET | SET | INCR |
|---|---:|---:|---:|
| on unpatched Bend | 0.08–0.14 | 0.08–0.14 | 0.08–0.14 |
| with 100 thousand keys | **1.62** | **1.82** | **1.45** |
| with 1 million keys | **1.65** | **1.80** | **1.17** |

- With Redis's own benchmark specs, run by `memtier_benchmark`, BendKV reaches 1.26 to
  1.39 times Redis's throughput.
- Without pipelining, both servers are bound by the network's latency, and stay within
  noise of each other.
- About 950 thousand keys with 3-byte values take 60 MB of resident memory, against
  Redis's 121 MB.
- Some commands are much slower than in Redis: LCS, SORT, the HyperLogLog commands, GEO's
  searches, DUMP and RESTORE of large values, LOLWUT's large drawings, and the eviction of
  many keys at once. [docs/COMMANDS.md](docs/COMMANDS.md) gives each factor in its
  command's section.

The full record, with every measurement and how it was made, is in
[docs/PERFORMANCE.md](docs/PERFORMANCE.md), [docs/FINDINGS.md](docs/FINDINGS.md) and
[tools/README.md](tools/README.md).

## Building and running

You need:

- [Bun](https://bun.sh), clang 19 (clang 18 works, at about 8% more instructions per
  request) and Python 3;
- Bend with the patches of [`bend-patches/`](bend-patches/): `bend-patches/apply.sh` puts
  them on `bendlang/bend` at `1cce499` (Bend 2.0.35), as [Quick start](#quick-start)
  shows;
- for `make verdict`, Lean 4.34.0, through elan;
- for the tests, `redis-server` and `redis-cli` 7.0.15 and a C compiler, and for
  `make perfcheck`, `valgrind` and `redis-benchmark`.

With `BEND` exported as in Quick start (or passed as `make ... BEND=...`):

| command | what it does |
|---|---|
| `make check` | checks the proofs, in about 15 s |
| `make verdict` | checks them again in the BendTT kernel, in about two minutes |
| `make build` | builds `build/bendkv` |
| `make pgo` | builds `build/bendkv-pgo`, with profile-guided optimization (needs `llvm-profdata`) |
| `make run` | runs `./build/bendkv 6380` |

`./build/bendkv [/path/to/redis.conf] [--name value ...] [-]` starts as `redis-server`
does: `./build/bendkv --port 7777 --appendonly yes`, or
`./build/bendkv /etc/redis/redis.conf`. `./build/bendkv --help` lists the forms. Replies go
out from a writer thread when the process has two cores or more, so that a client that
stops reading holds up only its own replies; with `io-threads 1`, they go out from the
event loop.

The tests and the tools also use a short form of BendKV's own,
`./build/bendkv PORT [post|send [FILE [always|everysec|no]]]`: `post` or `send` picks how
replies go out (from the writer thread, or from the event loop), and `FILE`, any path,
turns on the append-only file.

## Testing

| command | what it checks |
|---|---|
| `make smoke` | the pure checks, without a network: a batch end to end, and the append-only file |
| `make test` | the server against `redis-server` 7.0.15, in about 8 minutes on 4 cores |
| `make perfcheck` | instructions, cache misses and prefetches per request, against `tools/perf_baseline.txt` (needs `valgrind`) |
| `make gencheck` | the generated parts are up to date: the trie and its proofs, the tables of parameters and commands, the counts of [In numbers](#in-numbers) |
| `make bench` | `redis-benchmark`, BendKV against Redis |
| `make suite REDIS_SRC=../redis` | Redis's own test suite, on Redis and on BendKV (needs `tclsh`) |
| `make clients` | the test suites of redis-py and go-redis, on Redis and on BendKV (needs Go) |

Most tests send the same commands to BendKV and to Redis and compare the replies: random
command streams, every command at its edges, and scenarios of clients that wait,
transactions, Pub/Sub, MONITOR and the rest, compared transcript by transcript, then the
same features under load from hundreds of clients. The append-only file is tested by
killing the server at random moments under load, by failing the disk under it, and by
starting each server from the other's file. [tests/README.md](tests/README.md) lists
every test and how it compares. CI runs them on every pull request, with the client
libraries' suites and the server built with sanitizers
([CONTRIBUTING.md](CONTRIBUTING.md)).

## Layout

| path | what it holds | checked by |
|---|---|---|
| `src/map.bend` | the hash trie behind the keyspace | laws: Map, Keys |
| `src/redis.bend` | command semantics: `exec(cmd, db) -> (reply, db')` | laws: Commands, Commuting, Persistence, Databases, Key count; tests |
| `src/batch.bend` | a pipelined batch, with cache hints | laws: Commands, Sessions |
| `src/aof.bend` | the append-only file: effects, encoding, loading | laws: Persistence |
| `src/session.bend` | the state of a connection and of the server, whole batches | laws: Sessions, Configuration; tests |
| `src/config.bend` | the parameters, CONFIG GET and SET | laws: Configuration; tests |
| `src/resp.bend` | the RESP parser, RESP2 and RESP3 replies | tests |
| `src/info.bend` | INFO's sections and fields, SLOWLOG, LATENCY | tests |
| `src/command.bend` | COMMAND, with Redis's descriptions of BendKV's commands | tests |
| `src/startup.bend` | the command line and the configuration file | tests |
| `src/float.bend` | doubles and long doubles in software | tests, against glibc too |
| `src/hll.bend` | HyperLogLogs on a string's bytes, as Redis's | tests |
| `src/geo.bend` | geohashes, cells, distances and sorts, as Redis's | tests |
| `src/lolwut.bend` | LOLWUT's drawings, as Redis draws them | tests |
| `src/rdb.bend` | DUMP's payloads and RESTORE's reading, as Redis's | tests |
| `src/server.bend` | the shell: TCP, connections, the database actor, the append-only file's I/O, waits, transactions, Pub/Sub, eviction, rewrites | tests |
| `proof/LAWS.bend` | the laws | stated by people |
| `proof/SPEC.bend` | the commands on the bare trie, which the proofs bridge to | |
| `proof/PROOF.bend` | the proofs | Bend and the BendTT kernel |

A file the laws are about is not proved whole: the laws state what
[What is proved](#what-is-proved) says, and the rest of the file is tested. The other
directories:

- `tests/`: the tests ([tests/README.md](tests/README.md));
- `bench/`: in-process benchmarks of the map, the core and channels, and `make bench`
  against Redis;
- `tools/`: the generators, with the facts they take from Redis (`tools/data/`), the
  scripts behind the measurements, and the runners of Redis's and the client libraries'
  test suites ([tools/README.md](tools/README.md));
- `bend-patches/`: the patches to the Bend compiler and runtime
  ([bend-patches/README.md](bend-patches/README.md));
- `docs/`: the documents [below](#documentation).

## Where BendKV differs

Everything not listed here answers as Redis 7.0.15 does, byte for byte. The groups follow
the sections of [docs/COMMANDS.md](docs/COMMANDS.md), and
[docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) shows what the differences, and what is
missing, mean for Redis's own test suite.

- **Throughout.**
  - Where Redis answers in the order of one of its hash tables (the fields of a large
    hash, the members of a large set, the keys of KEYS and SCAN), BendKV answers in its
    own order, and SCAN's cursors are its own.
  - A hash, a set or a sorted set takes its large form at Redis's default limits,
    whatever `hash-max-listpack-*`, `set-max-intset-entries` and `zset-max-listpack-*`
    say. Under other limits, OBJECT ENCODING may name a value otherwise than Redis does,
    and a hash's fields or a set's members may come in another order.
  - Some commands are much slower than in Redis ([Performance](#performance)).
- **Strings and keys.** OBJECT ENCODING of a string that APPEND, SETRANGE, SETBIT or a
  command of HyperLogLogs made answers as for the same value set whole (`int`, `embstr`
  up to 44 bytes, `raw` past that), where Redis answers `raw`.
- **Times to live.**
  - A key whose time has passed is deleted only by a write that comes to it or by the
    sweep of expired keys, ten times a second; until then DBSIZE and INFO's keyspace
    count it. Redis also deletes it when a read comes to it.
  - A time at or past 10^14 ms (the year 5138) gives a key no time at all: BendKV keeps
    times in milliseconds to 14 digits, where Redis keeps any 64-bit time.
- **Ranges and bits.** BITFIELD refuses a field that crosses bit 2^32, with SETRANGE's
  error; Redis grows the value past 512 MB.
- **Sorted sets.** A STORE of more than 128 elements loses the sign of a `-0` score;
  Redis keeps it.
- **SORT.**
  - A set kept as a hash table comes in BendKV's order where SORT leaves a set in its own
    (BY a constant, without STORE), and so do elements whose weights tie under ALPHA BY
    a pattern; Redis's order there is its hash table's.
  - A sort BY a pattern under a LIMIT that does not take every element leaves the
    elements whose weights tie in a stable order; Redis's `pqsort` may not.
  - ALPHA compares as the C locale does; Redis compares in the locale it started in.
  - Redis reads a range error from `errno` without clearing it, so that after a SORT
    that met a weight too large or too small, its SORTs fail on weights that are not
    integers, until a command clears `errno`. BendKV does not.
  - SORT of a small sorted set leaves it a listpack; Redis makes it a skiplist, for
    good.
- **HyperLogLogs.**
  - `hll-sparse-max-bytes` is not read: a sparse HyperLogLog turns dense past 3,000
    bytes.
  - PFSELFTEST checks fewer cases.
  - The byte past a sparse string's end, which an XZERO cut at that end reads, is 0 as
    each command starts; Redis keeps what an earlier write left there.
  - A PFADD that a corrupt value stops keeps its change with a keyspace event and an
    entry in the append-only file; Redis keeps it silently.
- **DUMP and RESTORE.**
  - DUMP writes no LZF.
  - The pairs or members of a hash table come in the order of BendKV's trie.
  - RESTORE checks every payload in depth, as Redis does only with
    `sanitize-dump-payload yes`.
- **Clients that wait.** Redis serves the clients of the keys a command added
  (`signalKeyAsReady`, from `dbAdd`), key by key in the order the keys became ready.
  BendKV looks at every waiting client, in the order the clients came, after every
  command that may make one ready: one that may write a key a client waits on, or a
  command of the connection or of the server.
- **Transactions.**
  - An LTRIM that removes nothing changes no watched key; Redis signals the key anyway.
  - BendKV logs every DEL, even of a key that is not there, so the append-only file may
    wrap a transaction with one in MULTI and EXEC where Redis writes its one other
    effect alone.
- **Pub/Sub and keyspace notifications.**
  - UNSUBSCRIBE of every channel answers in the order the client subscribed, and PUBSUB
    CHANNELS in the trie's order; Redis answers in the order of its hash tables.
  - A slow subscriber has no `client-output-buffer-limit pubsub`.
  - There are no events of misses (`m`) or of streams.
  - A key that a read finds expired sends `expired` when the sweep deletes it; Redis
    sends it at the read.
- **Connections.**
  - TIME answers the time the batch runs at, to the millisecond (its microseconds end in
    000); Redis reads its clock to the microsecond.
  - A QUIT while CLIENT REPLY is OFF closes the connection; Redis keeps it open, reading
    nothing more from it.
- **CLIENT LIST, INFO and KILL.**
  - BendKV keeps no buffers per client, so their sizes are 0 (`qbuf-free`, `multi-mem`,
    `rbs`, `rbp`, `obl`, `oll`, `omem`, `tot-mem`), and so is another client's `qbuf`:
    Redis's query buffer holds the commands after a blocking one, where BendKV holds them
    as commands.
  - `idle` counts from the client's last batch; Redis also counts a reply written to it
    (to a subscriber that gets messages, to a client that waited).
  - `user` is always `default`, and `redir` -1.
- **CLIENT PAUSE and UNPAUSE.**
  - CLIENT UNBLOCK of a client held back answers 0; Redis 7.0.15 crashes on it.
  - EVAL of a script BendKV does not run is answered at once, under a pause of writes
    too ([docs/FINDINGS.md](docs/FINDINGS.md), section 3zzk).
- **MONITOR.**
  - A line's time is the time of the group of requests its call ran in, to the
    millisecond (its microseconds end in 000).
  - A monitor's own lines for the calls EXEC runs come after EXEC's array; Redis writes
    them between its replies.
- **SLOWLOG and LATENCY.**
  - The calls of a pipeline share its time, so a slow command lends its time to the
    others.
  - A batch's entries reach the slow log when the batch ends, so a SLOWLOG GET in the
    same pipeline does not see them.
  - There are no latency events of the append-only file, of eviction or of fork
    ([docs/FINDINGS.md](docs/FINDINGS.md), section 3zzz).
- **Server commands.**
  - SHUTDOWN SAVE fails, as Redis's does when it cannot save, since BendKV writes no RDB
    snapshot; SAVE FORCE stops the server all the same.
  - MEMORY MALLOC-STATS has no statistics of an allocator.
  - MEMORY USAGE, MEMORY STATS and INFO's memory section measure BendKV's own heap, so
    their numbers are not Redis's.
- **Configuration.**
  - The port, the addresses, TLS and the append-only file cannot change while BendKV
    runs: CONFIG SET fails as it does when Redis cannot apply a value.
  - The parameters BendKV has no use for (those of replication and of encodings, among
    others) are kept and read back, but change nothing.
  - CONFIG REWRITE answers as Redis does without a configuration file.
- **Memory and eviction.**
  - BendKV measures its memory before each group of requests, where Redis measures
    before each command, and it measures the live values of its heap, so the same
    `maxmemory` holds another number of keys than in Redis.
  - The last uses of keys are kept in a table of 2^20 words, by the key's hash: keys
    whose hashes share their low 20 bits share a word. A request marks only its first
    key, before it runs (MGET's other keys are not marked).
- **Starting.**
  - `bind` takes IPv4 addresses only.
  - What BendKV cannot do stops the start with a line saying so: modules, ACL users,
    renamed commands, running in the background, a cluster, a replica, TLS, a supervisor
    to signal, and loading an RDB file or Redis 7's multi-part append-only file.
- **Protocol.** A client that must still authenticate is not held to the tighter limits
  Redis puts on it (10 arguments, a bulk of 16 KB), and a new `proto-max-bulk-len`
  changes nothing.
- **The append-only file.**
  - Where a write makes a collection on a key whose time had passed, or a STORE writes
    over a key, BendKV logs one EVAL of a fixed script that deletes the key and writes
    it; Redis logs a MULTI with a DEL and the write. Each server loads the other's form.
  - BendKV logs some writes as what they did where Redis logs the command as it was
    sent: BITOP, BITFIELD, SORT with STORE, the PF commands, GEO searches that store,
    COPY and RESTORE among them. BendKV runs Redis's form again when it loads a file.
  - The start stops at any entry it cannot replay as it was written (an unknown
    command, a wrong number of arguments, an argument that does not read, a database
    that is not there, a MULTI inside another, an EXEC without one); Redis stops only at
    an unknown command.

## In numbers

Counts that the other documents link to. [`tools/gen_counts.py`](tools/gen_counts.py)
writes them from the files they count, and `make gencheck` fails when one is out of date.
Lines of code leave out comments and blank lines, and are rounded to two significant
figures; a count is written again once its file drifts a tenth away from it.

<!-- BEGIN gen_counts: numbers -->
| what | how many | counted in |
|---|---:|---|
| laws | 67 | `proof/LAWS.bend` (by group: [What is proved](#what-is-proved)) |
| patches to the Bend compiler | 35 | `bend-patches/apply.sh` |
| constructors of `Cmd`, a parsed command | 30 | `src/redis.bend` |
| Redis 7.0.15's parameters, all of which CONFIG serves | 178 | `tools/data/redis-configs.json` |

| file | lines of code | of them written by a generator | the laws import it |
|---|---:|---:|---|
| `src/map.bend` | 2,000 | 640 | yes |
| `src/redis.bend` | 16,000 | 6,400 | yes |
| `src/batch.bend` | 84 |  | yes |
| `src/aof.bend` | 1,200 |  | yes |
| `src/session.bend` | 2,400 |  | yes |
| `src/config.bend` | 1,200 | 180 | yes |
| `src/command.bend` | 1,700 | 1,100 | no |
| `src/float.bend` | 1,200 |  | no |
| `src/geo.bend` | 870 |  | no |
| `src/hll.bend` | 1,400 |  | no |
| `src/info.bend` | 2,200 |  | no |
| `src/lolwut.bend` | 470 |  | no |
| `src/rdb.bend` | 1,500 |  | no |
| `src/resp.bend` | 880 |  | no |
| `src/server.bend` | 6,600 |  | no |
| `src/startup.bend` | 460 |  | no |
| `proof/LAWS.bend` | 920 | 20 |  |
| `proof/SPEC.bend` | 370 |  |  |
| `proof/PROOF.bend` | 16,000 | 2,800 |  |
| `src/`, the 6 files the laws import | 23,000 | 7,100 |  |
| `src/`, the 10 others | 18,000 | 1,100 |  |
| `proof/` | 18,000 | 2,800 |  |
<!-- END gen_counts: numbers -->

## Documentation

- [docs/COMMANDS.md](docs/COMMANDS.md): what each command does, in detail, and how its
  writes are logged.
- [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md): Redis's own test suite against BendKV,
  unit by unit, and why the tests it fails fail; the test suites of redis-py and go-redis.
- [docs/PERFORMANCE.md](docs/PERFORMANCE.md): every optimization, section by section,
  with its measurements.
- [docs/FINDINGS.md](docs/FINDINGS.md): what building BendKV and making it fast showed.
- [docs/DIRECTIONS.md](docs/DIRECTIONS.md): verified databases, compilers and
  parallelism, and where the work goes next.
- [OVERVIEW.md](OVERVIEW.md): the full project report, with the feasibility study
  (SQLite, Redis, memcached and LMDB in Bend2) and the limits of Bend2 met in practice.
- [tests/README.md](tests/README.md): the tests, and how they compare BendKV with Redis.
- [tools/README.md](tools/README.md): the generators and the measurement scripts, and how
  the numbers were measured.
- [bend-patches/README.md](bend-patches/README.md): the patches to the Bend compiler.

## History

BendKV began as a proof of concept inside a fork of HVM4, and moved here once it grew into
a project of its own. Sharding across cores was built, proved, and later taken out,
because it paid too little for its cost ([docs/FINDINGS.md](docs/FINDINGS.md), section
3l); that version is kept on the
[`archive/shards`](https://github.com/littleBro/BendKV/tree/archive/shards) branch.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md); coding agents also read [AGENTS.md](AGENTS.md).

## License

Not decided yet. Until a license is added, all rights are reserved by the authors.
