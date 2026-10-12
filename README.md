# BendKV

A Redis-compatible key-value server written in [Bend2](https://github.com/bendlang/bend),
whose core is formally verified: the command semantics, the hash trie behind them, the
append-only file, the databases, the connection state and the configuration are proved
against 64 laws,
checked by Bend
and rechecked by the BendTT kernel, whose soundness is proved in Lean.

BendKV speaks RESP2, so `redis-cli`, `redis-benchmark` and `memtier_benchmark` work
with it. Under pipelined load it serves GET at 1.6×, SET at 1.8× and INCR at 1.45× the
throughput of Redis 7.0.15 on the same machine, with half its memory for small values.

> **Status: research prototype.** BendKV implements a subset of Redis (strings and their
> times to live, the keyspace, several databases, connection commands, an append-only
> file). The goal now is a drop-in
> replacement for a single Redis node, measured by Redis's own test suite: of the 1,673
> tests Redis 7.0.15 passes against a server it did not start, BendKV passes 327, and 303
> of the 386 in what it implements ([docs/COMPATIBILITY.md](docs/COMPATIBILITY.md)). Do
> not use it for data you cannot lose.

BendKV is an independent project. It is not affiliated with Higher Order Company or the
Bend project, nor with Redis Ltd. Redis is a trademark of Redis Ltd.

## Why

Most of a key-value server's semantics is a pure function
`exec(command, db) -> (reply, db')`, which is exactly what a proof assistant handles
well. BendKV asks how far one can get writing a real, fast server in a language where
the code that runs is the code that is proved, without a separate model and a
refinement proof. The answer so far: the verified core is not what makes it slow;
the data representation of the runtime was, and most of the work went into fixing it
(20 patches to the Bend compiler, in [`bend-patches/`](bend-patches/), and one more
that gives it the process's directory, id and clock).

## What is proved

The laws are stated by hand in [`proof/LAWS.bend`](proof/LAWS.bend) and proved in
[`proof/PROOF.bend`](proof/PROOF.bend). A database is a record: the trie, whose
entries hold each key's value and the time it expires at; how many keys it holds (which
DBSIZE answers) and how many of them have a time; and the time its batch runs at. The
server holds several (16, as Redis), with the one a connection selected in focus while
its batch runs. A key whose time has passed is there for no command. The laws about what keys read and what
commands answer are proved of a specification, the commands on the trie alone at a time
([`proof/SPEC.bend`](proof/SPEC.bend)), and a bridge proves that the server's commands
answer as it does (DBSIZE answers the count) and leave the trie it leaves. That the count
is the trie's size is not proved yet.

| group | laws | what they say |
|---|---:|---|
| Map | 11 | the trie is a finite map from keys to a value and a time: after any sequence of writes (a value with a time, a value with its time kept, a time alone, a deletion), every key holds what was last written to it, with no stale, lost or foreign entries; a read sees a key only until its time |
| Keys | 2 | key comparison is exactly string equality, down to the bits of `U32` |
| Commands | 24 | no command changes a key it does not write, neither its value nor its time (`frame`); reads keep the database; a key whose time has passed is there for no command, and the sweep of expired keys deletes no key that is there; GET, DEL, APPEND, SETRANGE, SETNX, INCR, GETDEL, PERSIST, PTTL, SET with KEEPTTL, RENAME, MSETNX and BITOP behave as specified, a key they add counted; a pipelined batch runs exactly as its commands in order; the cache hints before a batch change nothing |
| Commuting | 5 | commands on different keys commute: replies and key contents are the same in either order, and adjacent independent commands in a batch can be swapped, when neither writes a key the other's writes depend on (RENAME moves a value from one key to another, MSETNX sets its keys only when none is there, BITOP sets its destination from its sources) |
| Persistence | 8 | logging changes no reply; the file reads back as written, times included; after any history, each batch at its own time, on any of the databases, the server restores exactly the databases it held; a file cut by a crash at any byte restores the databases after some prefix of its acts, never a partial one |
| Databases | 6 | SELECT changes no database and focuses the one it names; SWAPDB puts each of two databases in the other's place; FLUSHALL empties them all; MOVE takes a key's entry, its value and its time, out of the selected database and sets it in the other; COPY sets a key's entry at another key, in the selected database or another, when that key is not there or REPLACE is given |
| Sessions | 5 | however the server dispatches a batch, it runs as its commands in order; a batch changes the databases and the log as its executed commands do; a client that has not authenticated against a password cannot read or change any key |
| Configuration | 3 | a CONFIG SET that fails changes nothing; one that succeeds makes the new requirepass the password; after a CONFIG SET of a parameter, CONFIG GET finds the value its check gave |

`make check` takes about 4 s; `make verdict` rechecks every proof in the BendTT kernel
in about 40 s.

**Trust boundary.** The proofs cover `src/map.bend`, `src/redis.bend`, `src/batch.bend`,
`src/aof.bend`, `src/session.bend` and `src/config.bend`. Trusted without proof: the Bend
compiler and its C runtime (with the patches), the RESP parser and the network shell
(`src/resp.bend`, `src/server.bend`, tested only), the start (`src/startup.bend`, tested
against `redis-server`), clang, libc and the OS. This is not
end-to-end verification in the sense of CompCert or seL4; see
[docs/FINDINGS.md](docs/FINDINGS.md), section 1.

The BendTT kernel is proved sound in Lean, but the translation from Bend to the kernel
is not, and since Bend 2's release several bugs were reported in which `--verdict`
passes while the kernel checked something other than the source says
([#1186](https://github.com/bendlang/bend/issues/1186),
[#1236](https://github.com/bendlang/bend/issues/1236),
[#1247](https://github.com/bendlang/bend/issues/1247), open as of October 2026). None
of their triggers occurs in BendKV's proofs (no specialized parameters over empty types,
no law helpers named like Base constructors, no colon/dot name clashes), but the
translation stays in the trusted base.

## Commands

- **Strings and keys:** GET, SET, SETNX, GETSET, DEL, UNLINK, EXISTS, INCR, DECR, INCRBY,
  DECRBY, APPEND, STRLEN, MGET, MSET, MSETNX, RENAME, RENAMENX (the key's time moves with
  it), COPY (DB and REPLACE; the key's time is copied with it), DBSIZE, KEYS
  (Redis's patterns: `*`, `?`, `[...]` classes, `\` escapes), TYPE, TOUCH, SCAN (MATCH,
  COUNT, TYPE, with Redis's guarantee: a key there for a whole iteration is found, however
  the database changes meanwhile) and RANDOMKEY (picked as Redis picks one). OBJECT
  (ENCODING, REFCOUNT, IDLETIME, FREQ, HELP) answers from the value, since BendKV keeps no
  encoding and no access times: ENCODING as Redis encodes a value set whole (where Redis
  answers `raw` for one made by APPEND, SETRANGE or SETBIT), REFCOUNT by Redis's shared
  integers under the current eviction policy, IDLETIME and FREQ 0 (each refused under the
  policy Redis refuses it under).
- **Ranges and bits:** GETRANGE (and SUBSTR), SETRANGE, GETBIT, SETBIT, BITCOUNT and
  BITPOS (with BYTE and BIT ranges), their numbers read as Redis reads them and their
  errors where Redis gives them; a value grows to 512MB at most (proto-max-bulk-len at
  its default). SETRANGE and SETBIT are logged as a SETRANGE of the bytes they wrote, not
  the whole value. BITOP (AND, OR, XOR, NOT; logged as the SET of its value) and LCS (LEN,
  IDX, MINMATCHLEN, WITHMATCHLEN, its table bounded by proto-max-bulk-len as in Redis, and
  slow: about twenty times Redis's time). BITFIELD and BITFIELD_RO: fields of up to 64
  bits, signed or not, at a bit offset or `#k`, with GET, SET, INCRBY and OVERFLOW WRAP,
  SAT or FAIL, in C's wrapping arithmetic as Redis's; logged as the SETRANGE of the bytes
  its writes reach. A field across the 2^32-th bit, for which Redis grows a value past
  512MB, is refused with SETRANGE's error.
- **Times to live:** EXPIRE, PEXPIRE, EXPIREAT and PEXPIREAT (with NX, XX, GT, LT), TTL,
  PTTL, EXPIRETIME, PEXPIRETIME, PERSIST; SET with NX, XX, GET, EX, PX, EXAT, PXAT and
  KEEPTTL; SETEX, PSETEX, GETEX (EX, PX, EXAT, PXAT, PERSIST) and GETDEL. Times are read
  as Redis reads them, with its errors, and a key expires at its time for every command.
  A key whose time has passed is deleted by a write that comes to it, or by the sweep of
  expired keys ten times a second (logged as DEL, as Redis logs it); until then DBSIZE
  and INFO's keyspace count it, where Redis also deletes it when a read comes to it. A
  time at or past 10^14 ms (the year 5138) gives a key no time at all.
- **Databases:** 16 of them, or as many as `databases` says, as in Redis: SELECT, MOVE
  (the key with its time), SWAPDB, FLUSHDB and FLUSHALL (with ASYNC/SYNC, which empty at
  once), with Redis's errors for a bad number; INFO's keyspace has a line for each
  database that holds keys, and the sweep of expired keys goes over every database.
- **Connection:** PING, ECHO, TIME (the time the batch runs at, to the ms), HELLO (RESP2,
  with AUTH and SETNAME), AUTH, SELECT, QUIT,
  RESET (which selects database 0 again), CLIENT (ID, GETNAME, SETNAME,
  REPLY ON/OFF/SKIP, NO-EVICT, GETREDIR, TRACKINGINFO, CACHING, UNBLOCK, HELP),
  FUNCTION FLUSH.
- **Configuration:** CONFIG GET (names, aliases and glob patterns), SET (several
  parameters at once, all or none), RESETSTAT, REWRITE, HELP, over all 178 parameters of
  Redis 7.0.15, taken from Redis's own table by `tools/gen_config.py`: every value is
  checked as Redis checks it and read back as Redis prints it. requirepass is the
  password and hz is capped as in Redis; the port, the addresses, TLS and the append-only
  file cannot change while BendKV runs (a new value fails as it does when Redis cannot
  apply it); the other parameters are kept and read back but tune nothing, since BendKV
  has no eviction, replication or encodings for them to tune.
- **Introspection:** INFO with Redis 7.0.15's sections and fields, in Redis's order,
  picked as Redis picks them (none, `default`, `all`, `everything`, any names in any
  case): server, clients, memory, persistence, stats, replication, CPU, modules,
  errorstats, cluster, keyspace. The values are BendKV's own where it has them: its
  process, its parameters, its connections, commands and bytes (with the instantaneous
  rates sampled every 100 ms, as Redis's cron samples them), its resident memory, its
  keys, its append-only file; for what BendKV does not have (replication, forks,
  scripts, eviction) they are what Redis shows when it has none. The statistics
  per command count as Redis counts them: each command's and subcommand's calls, the
  calls refused before they run (a wrong number of arguments by Redis's arity, a client
  that must authenticate first) and the calls that fail as they run, and the error
  replies by their code, held-back replies included (CLIENT REPLY OFF); BendKV does not
  time its commands, so their usec is 0 and latencystats is empty. CONFIG
  RESETSTAT starts the counts again. COMMAND (with INFO, DOCS, COUNT, LIST and its
  filters, GETKEYS, GETKEYSANDFLAGS, HELP) describes each command BendKV has, and each
  subcommand it has, as Redis 7.0.15 describes it: `tools/gen_commands.py` takes the
  descriptions from Redis itself.
- **Start:** as `redis-server` starts: a configuration file, `--name value` options and
  `-` for the standard input, read line by line as Redis reads them (includes, `dir`
  changing the directory at once, save points that add up, the same errors at the same
  lines), and a log in Redis's form, on the standard output or in `logfile`. The port,
  `bind` (IPv4), `requirepass`, `protected-mode`, the append-only file (`appendonly`,
  `appendfilename`, `appendfsync`, `aof-load-truncated`), `logfile`, `loglevel` and
  `pidfile` act; what BendKV cannot do (modules, ACL users, renamed commands, the
  background, a cluster, a replica, TLS, a supervisor to signal, an RDB file or Redis 7's
  multi-part append-only file to load) stops the start with a line saying so.
- **Protocol:** pipelining, partial packets, inline commands with quoting,
  binary-safe values, Redis's protocol errors.
- **Persistence:** an append-only file in Redis's own format, a SELECT before the
  entries of another database, SWAPDB, MOVE and FLUSHALL as Redis writes them, and COPY
  with its DB and REPLACE spelled out (`redis-check-aof` accepts it, and Redis loads it;
  BendKV loads Redis's, COPY as the client sent it), fsync `always`, `everysec` or `no`.

Not yet: other data types, MULTI/EXEC, pub/sub, timing of commands
(usec in INFO commandstats, latencystats), CONFIG REWRITE (it answers as Redis does without a configuration file),
RDB files. Integers, and times in ms, are limited to 14 digits.

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
sh bend-patches/apply.sh ../bend-patched      # Bend 2.0.35 + 21 patches
B="bun ../bend-patched/bend2/main.ts"

make check   BEND="$B"   # check the proofs
make verdict BEND="$B"   # ... and recheck them in the BendTT kernel
make build   BEND="$B"   # build/bendkv
make run                 # ./build/bendkv 6380
redis-cli -p 6380 set foo bar
```

`./build/bendkv [/path/to/redis.conf] [--name value ...] [-]` starts as `redis-server`
does (`./build/bendkv --port 7777 --appendonly yes`, `./build/bendkv /etc/redis/redis.conf`);
replies go out from a writer thread when the process has two cores or more, and from the
event loop with `io-threads 1`. `./build/bendkv --help` lists the forms. The short form
`./build/bendkv PORT [post|send [FILE [always|everysec|no]]]` is BendKV's own: `post` or
`send` picks how replies go out, `FILE` (any path) turns on the append-only file.

## Testing

```bash
make smoke     BEND="$B"   # the pure path end to end and the append-only file, no network
make test      BEND="$B"   # needs redis-server, redis-cli and a C compiler
make perfcheck BEND="$B"   # instructions per request against a baseline (needs valgrind)
make gencheck              # the generated parts (trie, its proofs, the parameter and command tables) are up to date
make bench     BEND="$B"   # redis-benchmark: BendKV against Redis
make suite     BEND="$B" REDIS_SRC=../redis   # Redis's own test suite, on Redis and on BendKV (needs tclsh)
```

`make test` runs, against a reference `redis-server`: the start (about a hundred command
lines and configuration files, each on both servers, with the same errors and the same
parameters after them), a differential test of random
command streams compared byte for byte (times to live, SET's options and several
databases among them),
keys that expire (set with short times on both servers, then read once the times have
passed), the protocol edge cases of Redis's
`tests/unit/protocol.tcl`, the connection commands, CONFIG (every parameter, a list of
cases and thousands of random values, set and read back on both servers), INFO (the
sections and fields for 31 ways of picking them, the values that do not depend on the
machine, the counts after CONFIG RESETSTAT), the statistics per command (commandstats,
errorstats and the totals after the same requests, one at a time and pipelined, with
refused, failed, held-back and protocol errors, compared as maps), COMMAND (each
command's description and
documentation, the lists and their filters, the keys of command lines, random ones
too), SCAN and RANDOMKEY (their arguments, full iterations with COUNT, MATCH and TYPE
finding Redis's keys, each once, an iteration while other clients write, RANDOMKEY's
picks), numbers at their edges in every argument that takes one (past a long long, at
2^48, in forms Redis refuses), BITFIELD's fields at random (each reply and each value
after it compared), robustness and concurrency checks,
restarts from the append-only file (every database read back, including after a
truncated tail), disk failures
under the file, injected with an `LD_PRELOAD` shim, and the files both ways: BendKV
started from a file Redis wrote and Redis from one BendKV wrote, each holding the
databases the other held. `make suite` runs Redis's own test
suite in its mode for a server already started, on Redis and on BendKV, and counts the
tests Redis passes that BendKV passes ([docs/COMPATIBILITY.md](docs/COMPATIBILITY.md)).

## Layout

```
src/        the server
  map.bend      hash trie with string keys                         verified
  redis.bend    command semantics: exec(cmd, db) -> (reply, db')   verified
  batch.bend    a pipelined batch with cache hints                 verified
  aof.bend      append-only file: effects, encoding, loading       verified
  session.bend  connection and server state, whole batches         verified
  config.bend   the parameters, CONFIG GET and SET                 verified
  resp.bend     RESP2 parser and reply encoder                     tested
  info.bend     INFO's sections and fields                         tested
  command.bend  COMMAND, with Redis's table of BendKV's commands     tested
  startup.bend  the command line and the configuration file        tested
  server.bend   TCP, connections, the database actor, the log      tested
proof/      LAWS.bend (the laws), PROOF.bend (their proofs), SPEC.bend (the commands on the trie alone)
tests/      start, differential, expiry, protocol, session, CONFIG, INFO, COMMAND, SCAN, BITFIELD, robustness, concurrency, AOF tests
bench/      in-process benchmarks of the map, the core and channels
tools/      measurement scripts, the runner of Redis's test suite, and the generators of
            the trie, of the parameter table and of the command table, with the facts
            they take from Redis (tools/data/)
bend-patches/  the 21 patches to the Bend compiler and runtime
docs/       FINDINGS.md, DIRECTIONS.md, COMPATIBILITY.md (English), PERFORMANCE.md (Russian)
```

## Documentation

- [docs/FINDINGS.md](docs/FINDINGS.md): what building BendKV and making it fast showed.
- [docs/DIRECTIONS.md](docs/DIRECTIONS.md): verified databases, compilers, parallelism,
  and where the work goes next.
- [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md): Redis's own test suite against BendKV,
  unit by unit, and why the tests it fails fail.
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
