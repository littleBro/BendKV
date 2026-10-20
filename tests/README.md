# Tests

BendKV is tested against a real `redis-server` 7.2.16. Most tests send the same commands
to both servers and compare the replies, byte for byte wherever Redis's reply does not
depend on chance or on the machine. The core is also proved
([README](../README.md#what-is-proved)); the tests cover what the laws do not state, and
everything outside the files the laws are about.

## Running them

| command | what it runs | what it needs |
|---|---|---|
| `make smoke` | the pure checks, without a network ([below](#pure-checks)) | Bend |
| `make test` | [`run_tests.sh`](run_tests.sh): every other test on this page | `redis-server` and `redis-cli` 7.2.16, Python 3, a C compiler; `redis-check-aof` when there is one |
| `make suite REDIS_SRC=../redis` | Redis's own test suite, on Redis and on BendKV (`tools/redis_suite.py`; [COMPATIBILITY.md](../docs/COMPATIBILITY.md)) | a Redis 7.2.16 source tree, `tclsh` |
| `make clients` | the test suites of redis-py (in RESP2 and in RESP3) and of go-redis, on Redis and on BendKV (`tools/client_suite.py`; [COMPATIBILITY.md](../docs/COMPATIBILITY.md#client-libraries-test-suites)) | Python 3, Go, access to PyPI and the Go module proxy |
| `sh tools/sanitize.sh` | the server built with AddressSanitizer and UndefinedBehaviorSanitizer (the Bend heap's free nodes poisoned: patch 34), then with ThreadSanitizer, each serving the tests that stress its memory and its writer thread most ([FINDINGS.md](../docs/FINDINGS.md), section 3zzp) | clang 19's sanitizer runtimes (`libclang-rt-19-dev`) |

CI ([`.github/workflows/ci.yml`](../.github/workflows/ci.yml)) has two tiers. The light
one runs `make smoke` with the proofs, the build and `make perfcheck` on every push. The
heavy one, started by hand before a pull request merges, runs `make test` in parts side by
side, the client suites and the sanitizers, against Redis 7.2.16 built from its tarball.
In the jobs of the client libraries, a test Redis passes that BendKV fails fails the job,
unless `tools/data/clients.json` lists it among the known failures, with the reason it
fails for; in the sanitizers' job, any report does. A nightly run sends about a million
random commands to the server built from `main`
([`.github/workflows/nightly.yml`](../.github/workflows/nightly.yml)).

### What `make test` runs

`PARTS` picks the parts, all of them by default, as CI's jobs share them out:

1. **start**: the float library against glibc, the start against `redis-server`, and
   connections that end, each on servers of their own.
2. **defaults**, **post**, **send** and **aof**: a reference Redis, and BendKV with its
   defaults, posting its replies to its writer thread (`post`), sending them from its
   event loop (`send`), and with an append-only file (`aof`). Against each: the
   robustness checks, a client that stops reading, the scenarios of clients that wait,
   transactions, Pub/Sub, CLIENT, CLIENT TRACKING, MONITOR, CLIENT PAUSE, scripts and
   functions, the administrative commands and AUTH, the differential test and the checks
   under concurrent clients. Against the defaults alone: the protocol, connections,
   CONFIG, INFO, the statistics, the timing of calls, the query buffer, COMMAND, the
   keyspace, expiry, numbers, BITFIELD, every data type, SORT, HyperLogLogs, GEO, DUMP
   and RESTORE, streams, and RESP3, then the differential tests again with every
   connection in RESP3. Against `send`, the protocol test again.
3. **files**: the append-only file (a restart from it, a restart from it cut short, kills
   under load, disk failures, files read both ways, files read in windows, the rewrite,
   Redis 7's directory, the file turned on and off), the replies of a client that must
   authenticate, maxmemory, the RDB file and the background saves.

### Seeds

The random tests take a seed. The differential tests run from the seeds `SEED` to
`SEED+3`, for `DIFF_ROUNDS` rounds each (`ROUNDS`, 1,000, by default). `SEED` is 1 by
default; in CI it is `4 * GITHUB_RUN_ID + 1`, so that each run sends commands no run sent
before. The log names the seeds first, and `SEED=N make test`, with the same
`DIFF_ROUNDS`, sends the same commands again.

### Running one test

Each test is a Python script. Most take the ports of a BendKV and of a Redis already
running; those that start servers of their own take `--bin build/bendkv`. The text at the
top of each file says what it checks and how to run it.

```bash
make build
./build/bendkv 6380 &
LC_ALL=C redis-server --port 6390 --save '' --appendonly no --bind 127.0.0.1 &   # the C locale, for SORT's ALPHA
python3 tests/hash_test.py --bendkv 6380 --redis 6390 --rounds 3000 --seed 1
RESP=3 python3 tests/hash_test.py --bendkv 6380 --redis 6390                      # every connection in RESP3
```

## How replies are compared

- **Byte for byte**, wherever Redis's reply depends neither on chance nor on the machine.
- **As sets or maps**, where Redis answers in the order of one of its hash tables, which
  BendKV does not share: a large hash or set, the keys of KEYS and of a whole SCAN, a
  whole ZSCAN of a large sorted set (by its pairs), CONFIG GET, INFO's statistics per
  command.
- **By kind and size**, where a server picks at random (SPOP, SRANDMEMBER, HRANDFIELD,
  ZRANDMEMBER, RANDOMKEY), each pick checked against what it was picked from; and for an
  estimate (MEMORY USAGE).
- **Within a second**, for what reads the clock (TTL, PTTL, EXPIRETIME, PEXPIRETIME,
  TIME).
- **As transcripts.** A scenario test runs each scenario on both servers, with clients of
  their own, and compares the transcripts line by line; what differs between two servers
  by nature (a client's id and address, an age, a time) is masked or compared by its
  form.

## The tests

### Pure checks

`make smoke` builds these for Bun and runs them; no server, no network.

| file | what it checks |
|---|---|
| [`smoke.bend`](smoke.bend) | a pipelined buffer parsed and run end to end, each reply against the one expected, in RESP2 and RESP3 |
| [`aof_check.bend`](aof_check.bend) | a batch's effects, written as the file and read back, rebuild the batch's database, through the start's checked replay too; the file cut at every length loads as whole entries and a leftover; the same on several databases; files the start must refuse |
| [`stream_check.bend`](stream_check.bend) | the head of each entry of a stream's node read the fast way and the slow way, which must agree |
| [`smoke_check.sh`](smoke_check.sh) | runs the three, then each again with one kind of its checks given a wrong expectation (`BENDKV_CHECK_BREAK`), which must fail it: a check that cannot fail would let a regression through |

### Commands and data, against Redis

| file | what it compares |
|---|---|
| [`diff_test.py`](diff_test.py) | random command streams, pipelined in random batches with random bytes: strings and keys, times to live, ranges and bits, BITOP, LCS, BITFIELD, hashes, lists, sets, sorted sets, several databases and transactions |
| [`numbers_test.py`](numbers_test.py) | numbers at their edges in every argument that takes one: past a long long, at 2^48, in forms Redis refuses |
| [`ttl_test.py`](ttl_test.py) | keys that expire: set with short times on both servers, read once the times have passed |
| [`keyspace_test.py`](keyspace_test.py) | SCAN's arguments and full iterations (each key found once, also while other clients write), RANDOMKEY's picks, and KEYS and SCAN's MATCH on patterns that only a matcher with Redis's cut-offs answers in time (adjacent stars, alternatives that match at once or nowhere, stars nested past 1000) |
| [`bitfield_test.py`](bitfield_test.py) | random BITFIELD and BITFIELD_RO commands, each reply and the value after it |
| [`hash_test.py`](hash_test.py) | hashes: each command at its edges, past the listpack limits, on keys whose time has passed, and at random, the fields of a hashtable compared as sets |
| [`list_test.py`](list_test.py) | lists: each command at its edges, lists of up to 20,000 elements, moves onto keys whose time has passed, and at random, with moves between a few keys |
| [`set_test.py`](set_test.py) | sets: each command at its edges, intsets on both sides of 512 members, small sets on both sides of 128 members of 64 bytes and hashtables of up to 20,000, STOREs and moves onto keys whose time has passed, and at random, each random pick checked against its set |
| [`zset_test.py`](zset_test.py) | sorted sets: each command at its edges, sorted sets of up to 20,000 elements on both sides of the listpack limits, STOREs and pops of keys whose time has passed, and at random, ZSCAN's walk compared by its pairs |
| [`sort_test.py`](sort_test.py) | SORT and SORT_RO: the cases of Redis's tests and of its `sort.c`, lists, sets and sorted sets of up to 10,000 elements sorted every way, random SORTs with BY and GET patterns over strings and hashes, each STORE's destination read back |
| [`hll_test.py`](hll_test.py) | HyperLogLogs: the cases of Redis's tests and of its `hyperloglog.c`, values made by hand and corrupted at random, random sequences of the PF commands, each value read back byte for byte |
| [`geo_test.py`](geo_test.py) | GEO: the cases of Redis's tests and of its `geo.c`, random sets and searches, each reply byte for byte in RESP2 and RESP3, each write's sorted set read back |
| [`dump_test.py`](dump_test.py) | DUMP and RESTORE: values of every kind and encoding, their payloads compared byte for byte and restored on both servers, payloads of the encodings Redis no longer writes, 1,500 payloads cut, grown and changed at random, RESTORE's options, errors, times and keyspace events, IDLETIME and FREQ |
| [`stream_dump_test.py`](stream_dump_test.py) | streams of 27 shapes Redis made, restored and dumped back byte for byte, and 2,000 payloads changed at random |
| [`stream_read_test.py`](stream_read_test.py) | the reads of those streams, each reply compared whole in RESP2 and RESP3, over the streams' IDs, their neighbours and the edges, counts, groups, consumers and errors |
| [`stream_write_test.py`](stream_write_test.py) | random XADD, XTRIM, XDEL and XSETID, each reply and each stream's DUMP and XINFO after each write, the errors, the events, WATCH and MULTI |
| [`stream_group_test.py`](stream_group_test.py) | random writes of groups (XGROUP, XREADGROUP, XACK, XCLAIM, XAUTOCLAIM) among XADD, XDEL and trims: each reply, each stream's XINFO and XPENDING, the changes counted, the errors, the events, WATCH, MULTI and BLOCK |
| [`float_test.py`](float_test.py) | not Redis but glibc: random texts of numbers read, written and added by `src/float.bend` and by C ([`float_ref.c`](float_ref.c)), the answers compared byte for byte |

### Connections and clients, against Redis

| file | what it compares |
|---|---|
| [`protocol_test.py`](protocol_test.py) | raw bytes on fresh connections: the cases of Redis's `tests/unit/protocol.tcl` and of the lengths and lines of its `processMultibulkBuffer`, the replies CLIENT REPLY holds back; whether each server closes the connection, seen in its count of clients rather than in a quiet socket; then, on BendKV alone, one MSET of 200,000 keys timed against as many SETs, sent at once and in pieces of 60 KB |
| [`session_test.py`](session_test.py) | the commands of a connection, byte for byte |
| [`resp3_test.py`](resp3_test.py) | HELLO and the switch of protocol (in a pipeline too), the replies RESP3 types, EXEC, blocking commands and Pub/Sub's pushes, a client's own pushes after the reply of what made them |
| [`auth_test.py`](auth_test.py) | when a client must authenticate, and what it is answered before it does |
| [`obuf_test.py`](obuf_test.py) | a client that must authenticate, held to 16 KB of replies: BendKV posting its replies and sending them from its loop, and Redis, each started with a password, the clients closed and the lines logged for them |
| [`acl_test.py`](acl_test.py) | a user's calls allowed and refused, alone and pipelined behind AUTH, ACL LOG, MULTI and EXEC, the clients ACL SETUSER and DELUSER close, CLIENT LIST and CLIENT KILL USER, SORT's BY and GET, the slow log |
| [`blocking_test.py`](blocking_test.py) | 18 scenarios of the blocking commands; then 300 clients served at once, 100 timeouts at once, clients that leave while they wait, and 50 consumers moving 1,000 items while some of them leave |
| [`stream_block_test.py`](stream_block_test.py) | 41 scenarios of XREAD and XREADGROUP with BLOCK |
| [`multi_test.py`](multi_test.py) | 13 scenarios of MULTI, EXEC, DISCARD, WATCH and UNWATCH; then 20 clients raising a counter with WATCH (each lost race retried), a reader that never sees half of a transaction, and 100 clients that leave in MULTI or with keys watched |
| [`pubsub_test.py`](pubsub_test.py) | scenarios of Pub/Sub, and of keyspace notifications in each class and mask; then 20 subscribers, each of a channel and of a pattern, that get the 1,000 messages of 4 publishers in order, through both, and 50 subscribers that leave while messages are published |
| [`client_test.py`](client_test.py) | CLIENT LIST, INFO and KILL, line by line, field by field; then 100 clients listed and half of them killed by id, and 200 killed by address while other clients connect and close |
| [`querybuf_test.py`](querybuf_test.py) | a client's query buffer as another client sees it in CLIENT LIST (`qbuf`, `qbuf-free`), after commands, big arguments and the cron's looks |
| [`tracking_test.py`](tracking_test.py) | CLIENT TRACKING: the bytes every client received after each step of each scenario |
| [`monitor_test.py`](monitor_test.py) | MONITOR's lines, their time and address put aside; then 4 monitors that each get every line of 20 clients that pipeline 200 SETs each, each client's lines in order |
| [`pause_test.py`](pause_test.py) | CLIENT PAUSE and UNPAUSE: what a pause holds back and lets run, its end and the order the clients go on in; then 100 clients held back and let go in order |
| [`script_test.py`](script_test.py) | EVAL's replies in RESP2 and RESP3, `redis.call` and `redis.pcall`, errors, the script cache, the libraries, scripts in transactions and with WATCH, the statistics, a script past `lua-time-limit`, BUSY and SCRIPT KILL, the slow log and the latency monitor of scripts, scripts in pipelines and under a pause |
| [`function_test.py`](function_test.py) | FUNCTION and FCALL: libraries loaded, listed, dumped and restored, BUSY and FUNCTION KILL, payloads both ways |

### The server, against Redis

| file | what it compares |
|---|---|
| [`start_test.py`](start_test.py) | about a hundred command lines and configuration files, each on both servers: the same errors, or the same parameters once started |
| [`config_test.py`](config_test.py) | CONFIG: every parameter as the servers start, a list of cases and errors, and thousands of random values set and read back |
| [`info_test.py`](info_test.py) | INFO's sections and fields for 31 ways of picking them, the values that do not depend on the machine, the counts after CONFIG RESETSTAT |
| [`stats_test.py`](stats_test.py) | INFO's statistics per command after the same requests, one at a time and pipelined, with refused, failed, held-back and protocol errors, compared as maps |
| [`timing_test.py`](timing_test.py) | SLOWLOG, LATENCY, the histograms and `latencystats`, the slow log's entries with every call logged, what depends on how long a call took put aside |
| [`command_test.py`](command_test.py) | COMMAND: each command's description and documentation, the lists and their filters, the keys of command lines (random ones too) |
| [`admin_test.py`](admin_test.py) | LASTSAVE, ROLE, WAIT, MEMORY, LOLWUT's drawings byte for byte and SHUTDOWN's errors; then SHUTDOWN on servers of their own: the file synced, the pid file removed, a rewrite that runs stopped |
| [`maxmemory_test.py`](maxmemory_test.py) | the refusals past maxmemory, OBJECT IDLETIME and FREQ and the `evicted` event against Redis's, Redis's own tests of the eviction policies on both servers; then an eviction that goes on alone, with the append-only file on and while a rewrite runs |

### Files

| file | what it checks |
|---|---|
| [`aof_test.py`](aof_test.py) | a random stream on the 16 databases (transactions and a FLUSHALL among it), the server restarted from its file, every database read back the same; `run_tests.sh` then cuts the file's last entry short, and the restart must cut it back |
| [`crash_test.py`](crash_test.py) | rounds of SIGKILL at a random moment while 1 to 16 connections write, some while a rewrite runs and some while a start loads the file: each start must hold the databases after a prefix of the commands sent, every acknowledged one among them |
| [`aof_fail_test.py`](aof_fail_test.py) | the disk failing under the file, injected by [`fail_io.c`](fail_io.c) (an `LD_PRELOAD` shim): a file that cannot be read, a failed fsync, a failed sync of the directory, the order in which the file is made, its directory synced and the first reply sent; files the start must refuse, each left as it was |
| [`aof_redis_test.py`](aof_redis_test.py), [`stream_aof_test.py`](stream_aof_test.py), [`stream_group_aof_test.py`](stream_group_aof_test.py) | the files both ways: the same commands to BendKV and to a `redis-server` that keeps its own file, then BendKV started from Redis's file and Redis from BendKV's, each holding the databases the other held; of streams' writes and of their groups' too |
| [`aof_window_test.py`](aof_window_test.py) | files whose entries, transactions and values straddle the windows the start reads them in, cut short or with a transaction left open, each started on by BendKV and by Redis: both start or refuse alike, with the same databases |
| [`rewrite_test.py`](rewrite_test.py) | BGREWRITEAOF's replies and INFO's account against Redis's, the rewritten file against Redis's base, command for command, writes during a rewrite and a kill during one, the cron's rewrites, rewrites that fail, and both servers started from the new file |
| [`aofdir_test.py`](aofdir_test.py) | Redis 7's directory of files: BendKV and Redis each started on a copy of the same directory (an RDB base and one of commands, none and an empty one, an old single file to move in, manifests Redis refuses, files cut short or not there, history files) and rewriting in it, with the same databases, manifests and lines logged |
| [`aof_switch_test.py`](aof_switch_test.py) | CONFIG SET appendonly yes and no at run time, in the directory and as the single file: the replies, INFO's fields, the files, the manifests, the lines logged and the databases after a restart |
| [`rdb_test.py`](rdb_test.py) | the RDB file: files Redis wrote (with LZF and without) and of the encodings Redis no longer writes, BendKV and Redis started from each; BendKV's SAVE, Redis started from it; files read in windows; SAVE, LASTSAVE, INFO and the saves of FLUSHALL and SHUTDOWN; files that do not load |
| [`bgsave_test.py`](bgsave_test.py) | the background saves: the count of changes of each write, BGSAVE and its fields in INFO, the save points, MISCONF after a save that failed, and SHUTDOWN and FLUSHALL while a save runs |

`tools/restore_mem.sh` checks the resident memory after a restart from a file of a
million SETs: at most 1.3 times what it was before.

### Robustness

| file | what it checks |
|---|---|
| [`robust_test.py`](robust_test.py) | requests split into single bytes, a large value, a pattern slow to match, protocol garbage, many connections at once |
| [`writer_test.py`](writer_test.py) | a client that stops reading holds up only itself, while others get large replies and quick ones |
| [`concurrency_test.py`](concurrency_test.py) | under concurrent pipelined clients: no lost update, a command on several keys seen whole, writes to two keys seen in order |
| [`conn_test.py`](conn_test.py) | connections that end every way one can (a close, QUIT, a protocol error, a reset), many times, on a BendKV of their own: each must close the channel it opened |
