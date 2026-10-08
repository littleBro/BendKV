# BendKV

A Redis-compatible key-value server written in [Bend2](https://github.com/bendlang/bend),
whose core is formally verified: the command semantics, the hash trie behind them, the
append-only file and the connection state are proved against 38 laws, checked by Bend
and rechecked by the BendTT kernel, whose soundness is proved in Lean.

BendKV speaks RESP2, so `redis-cli`, `redis-benchmark` and `memtier_benchmark` work
with it. Under pipelined load it serves GET at 1.6×, SET at 1.8× and INCR at 1.45× the
throughput of Redis 7.0.15 on the same machine, with half its memory for small values.

> **Status: research prototype.** BendKV implements a subset of Redis (strings, the
> keyspace, connection commands, an append-only file). The goal now is a drop-in
> replacement for a single Redis node, measured by Redis's own test suite. Do not use
> it for data you cannot lose.

BendKV is an independent project. It is not affiliated with Higher Order Company or the
Bend project, nor with Redis Ltd. Redis is a trademark of Redis Ltd.

## Why

Most of a key-value server's semantics is a pure function
`exec(command, db) -> (reply, db')`, which is exactly what a proof assistant handles
well. BendKV asks how far one can get writing a real, fast server in a language where
the code that runs is the code that is proved, without a separate model and a
refinement proof. The answer so far: the verified core is not what makes it slow;
the data representation of the runtime was, and most of the work went into fixing it
(19 patches to the Bend compiler, in [`bend-patches/`](bend-patches/)).

## What is proved

The laws are stated by hand in [`proof/LAWS.bend`](proof/LAWS.bend) and proved in
[`proof/PROOF.bend`](proof/PROOF.bend).

| group | laws | what they say |
|---|---:|---|
| Map | 5 | the trie is a finite map: after any sequence of SET/DEL, every key reads as determined, with no stale, lost or foreign values |
| Keys | 2 | key comparison is exactly string equality, down to the bits of `U32` |
| Commands | 13 | no command changes a key it does not write (`frame`); reads keep the database; GET/DEL/APPEND/SETNX/INCR behave as specified; a pipelined batch runs exactly as its commands in order; the cache hints before a batch change nothing |
| Commuting | 5 | commands on different keys commute: replies and key contents are the same in either order, and adjacent independent commands in a batch can be swapped |
| Persistence | 8 | logging changes no reply; the file reads back as written; after any history the server restores exactly the database it held; a file cut by a crash at any byte restores the database after some prefix of its commands, never a partial command |
| Sessions | 5 | however the server dispatches a batch, it runs as its commands in order; a batch changes the database and the log as its executed commands do; a client that has not authenticated against a password cannot read or change any key |

`make check` takes about a second; `make verdict` rechecks every proof in the BendTT
kernel in about 4 s.

**Trust boundary.** The proofs cover `src/map.bend`, `src/redis.bend`, `src/batch.bend`,
`src/aof.bend` and `src/session.bend`. Trusted without proof: the Bend compiler and its
C runtime (with the patches), the RESP parser and the network shell (`src/resp.bend`,
`src/server.bend`, tested only), clang, libc and the OS. This is not end-to-end
verification in the sense of CompCert or seL4; see
[docs/FINDINGS.md](docs/FINDINGS.md), section 1.

## Commands

- **Strings and keys:** GET, SET, SETNX, GETSET, DEL, UNLINK, EXISTS, INCR, DECR, INCRBY,
  DECRBY, APPEND, STRLEN, MGET, MSET, DBSIZE, FLUSHALL, FLUSHDB (with ASYNC/SYNC), KEYS
  (glob with `*` and `?`), TYPE.
- **Connection:** PING, ECHO, HELLO (RESP2, with AUTH and SETNAME), AUTH, SELECT (one
  database, as Redis with `databases 1`), QUIT, RESET, CLIENT (ID, GETNAME, SETNAME,
  REPLY ON/OFF/SKIP, NO-EVICT, GETREDIR, TRACKINGINFO, CACHING, UNBLOCK, HELP),
  FUNCTION FLUSH.
- **Protocol:** pipelining, partial packets, inline commands with quoting,
  binary-safe values, Redis's protocol errors.
- **Persistence:** an append-only file in Redis's own format (`redis-check-aof` accepts
  it, and Redis loads it), fsync `always`, `everysec` or `no`.

Not yet: other data types, expiry, multiple databases, MULTI/EXEC, pub/sub, CONFIG,
INFO, COMMAND (CONFIG and COMMAND are placeholders so that `redis-cli` and
`redis-benchmark` work). Integers are limited to 14 digits.

## Performance

Pipeline depth 16, 20 clients, filled database, 3-byte values, Redis 7.0.15 on the same
VM (medians over 8–13 interleaved pairs):

| share of Redis throughput | GET | SET | INCR |
|---|---:|---:|---:|
| BendKV on unpatched Bend | 0.08–0.14 | 0.08–0.14 | 0.08–0.14 |
| BendKV, 100k keys | **1.62** | **1.82** | **1.45** |
| BendKV, 1M keys | **1.65** | **1.80** | **1.17** |

With Redis's own benchmark specs run by `memtier_benchmark`, BendKV reaches 1.26–1.39×
Redis. Without pipelining both are bound by network latency and stay within noise of each
other. About 950 thousand keys with 3-byte values take 60 MB RSS against Redis's 121 MB.
The full record, with every measurement and method, is in
[docs/PERFORMANCE.md](docs/PERFORMANCE.md) (Russian) and
[docs/FINDINGS.md](docs/FINDINGS.md) (English).

## Building

You need [Bun](https://bun.sh), clang 19 (clang 18 works, about 8% slower), Python 3,
and Bend with the patches in [`bend-patches/`](bend-patches/) applied; `make verdict`
also needs Lean 4.34.0 (through elan).

```bash
git clone https://github.com/bendlang/bend ../bend-patched
sh bend-patches/apply.sh ../bend-patched      # Bend 2.0.35 + 19 patches
B="bun ../bend-patched/bend2/main.ts"

make check   BEND="$B"   # check the proofs
make verdict BEND="$B"   # ... and recheck them in the BendTT kernel
make build   BEND="$B"   # build/bendkv
make run                 # ./build/bendkv 6380
redis-cli -p 6380 set foo bar
```

`./build/bendkv PORT [post|send [FILE [always|everysec|no]]]`: `post` sends replies from
a writer thread (the default when the process has two cores or more), `send` from the
event loop; `FILE` turns on the append-only file.

## Testing

```bash
make smoke     BEND="$B"   # the pure path end to end and the append-only file, no network
make test      BEND="$B"   # needs redis-server, redis-cli and a C compiler
make perfcheck BEND="$B"   # instructions per request against a baseline (needs valgrind)
make gencheck              # the generated parts of the trie and its proofs are up to date
make bench     BEND="$B"   # redis-benchmark: BendKV against Redis
```

`make test` runs, against a reference `redis-server`: a differential test of random
command streams compared byte for byte, the protocol edge cases of Redis's
`tests/unit/protocol.tcl`, the connection commands, robustness and concurrency checks,
restarts from the append-only file (including a truncated tail), and disk failures
under the file, injected with an `LD_PRELOAD` shim.

## Layout

```
src/        the server
  map.bend      hash trie with string keys                         verified
  redis.bend    command semantics: exec(cmd, db) -> (reply, db')   verified
  batch.bend    a pipelined batch with cache hints                 verified
  aof.bend      append-only file: effects, encoding, loading       verified
  session.bend  connection and server state, whole batches         verified
  resp.bend     RESP2 parser and reply encoder                     tested
  server.bend   TCP, connections, the database actor               tested
proof/      LAWS.bend (the laws) and PROOF.bend (their proofs)
tests/      differential, protocol, session, robustness, concurrency, AOF tests
bench/      in-process benchmarks of the map, the core and channels
tools/      measurement scripts and the trie generator (tools/README.md)
bend-patches/  the 19 patches to the Bend compiler and runtime
docs/       FINDINGS.md, DIRECTIONS.md (English), PERFORMANCE.md (Russian)
```

## Documentation

- [docs/FINDINGS.md](docs/FINDINGS.md): what building BendKV and making it fast showed.
- [docs/DIRECTIONS.md](docs/DIRECTIONS.md): verified databases, compilers, parallelism,
  and where the work goes next.
- [docs/PERFORMANCE.md](docs/PERFORMANCE.md) (Russian): every optimization, section by
  section, with measurements.
- [README.ru.md](README.ru.md) (Russian): the full project report, including the
  feasibility study (SQLite, Redis, memcached, LMDB in Bend2) and Bend2's limitations
  met in practice.
- [tools/README.md](tools/README.md): how it was measured.
- [bend-patches/README.md](bend-patches/README.md) (Russian): the compiler patches.

## History

BendKV began as a proof of concept inside a fork of HVM4 and moved here once it grew
into a project of its own. Sharding across cores was built, proved and later taken out
because it paid too little for its cost ([docs/FINDINGS.md](docs/FINDINGS.md), section
3l); that version is kept on the [`archive/shards`](https://github.com/littleBro/BendKV/tree/archive/shards) branch.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Not decided yet. Until a license is added, all rights are reserved by the authors.
