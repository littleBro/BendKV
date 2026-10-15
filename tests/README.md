# Tests

BendKV is tested against a real `redis-server` 7.0.15. Most tests send the same commands
to both servers and compare the replies, byte for byte wherever Redis's reply does not
depend on chance or on the machine. The core is also proved
([README](../README.md#what-is-proved)); the tests cover what the laws do not state, and
everything outside the files the laws are about.

## Running them

| command | what it runs | what it needs |
|---|---|---|
| `make smoke` | the pure checks, without a network ([below](#pure-checks)) | Bend |
| `make test` | [`run_tests.sh`](run_tests.sh): every other test on this page; about 8 minutes on 4 cores | `redis-server` and `redis-cli` 7.0.15, Python 3, a C compiler; `redis-check-aof` when there is one |
| `make suite REDIS_SRC=../redis` | Redis's own test suite, on Redis and on BendKV (`tools/redis_suite.py`; [COMPATIBILITY.md](../docs/COMPATIBILITY.md)) | a Redis 7.0.15 source tree, `tclsh` |
| `make clients` | the test suites of redis-py (in RESP2 and in RESP3) and of go-redis, on Redis and on BendKV (`tools/client_suite.py`; [COMPATIBILITY.md](../docs/COMPATIBILITY.md#client-libraries-test-suites)) | Python 3, Go, access to PyPI and the Go module proxy |
| `sh tools/sanitize.sh` | the server built with AddressSanitizer and UndefinedBehaviorSanitizer (the Bend heap's free nodes poisoned: patch 34), then with ThreadSanitizer, each serving the tests that stress its memory and its writer thread most ([FINDINGS.md](../docs/FINDINGS.md), section 3zzp) | clang 19's sanitizer runtimes (`libclang-rt-19-dev`) |

CI runs all of them but `make suite` on every pull request
([`.github/workflows/ci.yml`](../.github/workflows/ci.yml)). In the jobs of the client
libraries, a test Redis passes that BendKV fails fails the job, unless
`tools/data/clients.json` lists it among the known failures, with the reason it fails
for; in the sanitizers' job, any report does. A nightly run sends about a million random
commands to the server built from `main`
([`.github/workflows/nightly.yml`](../.github/workflows/nightly.yml)).

### What `make test` runs

1. The float library against glibc, the start against `redis-server`, and connections
   that end, each on servers of their own.
2. A reference Redis, and BendKV four times: with its defaults, posting its replies to
   its writer thread (`post`), sending them from its event loop (`send`), and with an
   append-only file. Against each of the four: the robustness checks, a client that stops
   reading, the scenarios of clients that wait, transactions, Pub/Sub, CLIENT, MONITOR,
   CLIENT PAUSE, the administrative commands and AUTH, the differential test (three
   seeds) and the checks under concurrent clients. Against the defaults alone: the tests
   of the protocol, connections, CONFIG, INFO, statistics, timing, COMMAND, the keyspace,
   expiry, numbers, BITFIELD, every data type, SORT, HyperLogLogs, GEO, DUMP and RESTORE,
   and RESP3, then eight of them and the differential test again with every connection
   in RESP3. Against `send`, the protocol test again.
3. The append-only file: a restart from it, a restart from it cut short, kills under
   load, disk failures, files read both ways, the rewrite; then maxmemory.

### Seeds

The random tests take a seed. The differential test runs from the seeds `SEED` to
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
| [`smoke_check.sh`](smoke_check.sh) | runs both, then each again with one kind of its checks given a wrong expectation (`BENDKV_CHECK_BREAK`), which must fail it: a check that cannot fail would let a regression through |

### Commands and data, against Redis

| file | what it compares |
|---|---|
| [`diff_test.py`](diff_test.py) | random command streams, pipelined in random batches with random bytes: strings and keys, times to live, ranges and bits, BITOP, LCS, BITFIELD, hashes, lists, sets, sorted sets, several databases and transactions |
| [`numbers_test.py`](numbers_test.py) | numbers at their edges in every argument that takes one: past a long long, at 2^48, in forms Redis refuses |
| [`ttl_test.py`](ttl_test.py) | keys that expire: set with short times on both servers, read once the times have passed |
| [`keyspace_test.py`](keyspace_test.py) | SCAN's arguments and full iterations (each key found once, also while other clients write), RANDOMKEY's picks, and KEYS and SCAN's MATCH on patterns that only a matcher with Redis's cut-offs answers in time (adjacent stars, alternatives that match at once or nowhere, stars nested past 1000) |
| [`bitfield_test.py`](bitfield_test.py) | random BITFIELD and BITFIELD_RO commands, each reply and the value after it |
| [`hash_test.py`](hash_test.py) | hashes: each command at its edges, past the listpack limits, on keys whose time has passed, and at random |
| [`list_test.py`](list_test.py) | lists: each command at its edges, lists of up to 20,000 elements, moves onto keys whose time has passed, and at random |
| [`set_test.py`](set_test.py) | sets: each command at its edges, intsets on both sides of 512 members and hash tables of up to 20,000, STOREs and moves onto keys whose time has passed, and at random |
| [`zset_test.py`](zset_test.py) | sorted sets: each command at its edges, sorted sets of up to 20,000 elements on both sides of the listpack limits, STOREs and pops of keys whose time has passed, and at random |
| [`sort_test.py`](sort_test.py) | SORT and SORT_RO: the cases of Redis's tests and of its `sort.c`, lists, sets and sorted sets of up to 10,000 elements sorted every way, random SORTs with BY and GET patterns over strings and hashes, each STORE's destination read back |
| [`hll_test.py`](hll_test.py) | HyperLogLogs: the cases of Redis's tests and of its `hyperloglog.c`, values made by hand and corrupted at random, random sequences of the PF commands, each value read back byte for byte |
| [`geo_test.py`](geo_test.py) | GEO: the cases of Redis's tests and of its `geo.c`, random sets and searches, each reply byte for byte in RESP2 and RESP3, each write's sorted set read back |
| [`dump_test.py`](dump_test.py) | DUMP and RESTORE: values of every kind and encoding, their payloads compared byte for byte and restored on both servers, payloads of the encodings Redis no longer writes, 1,500 payloads cut, grown and changed at random, RESTORE's options, errors, times and keyspace events, IDLETIME and FREQ |
| [`float_test.py`](float_test.py) | not Redis but glibc: random texts of numbers read, written and added by `src/float.bend` and by C ([`float_ref.c`](float_ref.c)), the answers compared byte for byte |

### Connections and clients, against Redis

| file | what it compares |
|---|---|
| [`protocol_test.py`](protocol_test.py) | raw bytes on fresh connections: the cases of Redis's `tests/unit/protocol.tcl` and of its `processMultibulkBuffer`, the errors' form, protocol errors under CLIENT REPLY OFF; whether each server closes the connection, seen in its count of clients rather than in a quiet socket |
| [`session_test.py`](session_test.py) | the commands of a connection, byte for byte |
| [`resp3_test.py`](resp3_test.py) | HELLO and the switch of protocol (in a pipeline too), the replies RESP3 types, EXEC, blocking commands and Pub/Sub's pushes |
| [`auth_test.py`](auth_test.py) | when a client must authenticate, and what it is answered before it does |
| [`blocking_test.py`](blocking_test.py) | scenarios of clients that wait; then 300 clients served at once, 100 timeouts at once, clients that leave while they wait, and 50 consumers moving 1,000 items while some of them leave |
| [`multi_test.py`](multi_test.py) | scenarios of MULTI, EXEC, DISCARD, WATCH and UNWATCH; then 20 clients raising a counter with WATCH (each lost race retried), a reader that never sees half of a transaction, and 100 clients that leave in MULTI or with keys watched |
| [`pubsub_test.py`](pubsub_test.py) | scenarios of Pub/Sub, and the keyspace events of 76 commands in 162 cases; then 20 subscribers, each of a channel and of a pattern, that get the 1,000 messages of 4 publishers in order, through both, and 50 subscribers that leave while messages are published |
| [`client_test.py`](client_test.py) | CLIENT LIST, INFO, KILL and NO-EVICT, line by line; then 100 clients listed and half of them killed by id, and 200 killed by address while other clients connect and close |
| [`monitor_test.py`](monitor_test.py) | MONITOR's lines; then 4 monitors that each get every line of 20 clients that pipeline 200 commands each, each client's lines in order |
| [`pause_test.py`](pause_test.py) | CLIENT PAUSE and UNPAUSE: what a pause holds back and lets run, its end and the order the clients go on in; then 100 clients held back and let go in order |

### The server, against Redis

| file | what it compares |
|---|---|
| [`start_test.py`](start_test.py) | about 80 command lines and configuration files, each on both servers: the same errors, or the same parameters once started; then what BendKV refuses although Redis starts with it |
| [`config_test.py`](config_test.py) | CONFIG: every parameter as the servers start, a list of cases and errors, and thousands of random values set and read back |
| [`info_test.py`](info_test.py) | INFO's sections and fields for every way of picking them, the values that do not depend on the machine, the counts after CONFIG RESETSTAT |
| [`stats_test.py`](stats_test.py) | INFO's statistics per command after the same requests, one at a time and pipelined, with refused, failed, held-back and protocol errors |
| [`timing_test.py`](timing_test.py) | SLOWLOG, LATENCY, INFO's `usec` and `latencystats`, what depends on how long a call took put aside |
| [`command_test.py`](command_test.py) | COMMAND: each command's description and documentation, the lists and their filters, the keys of command lines (random ones too) |
| [`admin_test.py`](admin_test.py) | LASTSAVE, ROLE, WAIT, MEMORY, LOLWUT's drawings and SHUTDOWN's errors; then SHUTDOWN on servers of its own: the file synced, the pid file removed, a rewrite that runs stopped |
| [`maxmemory_test.py`](maxmemory_test.py) | the refusals past maxmemory, OBJECT IDLETIME and FREQ and the `evicted` event against Redis's, Redis's own tests of the eviction policies on both servers; then an eviction that goes on alone, with the append-only file on and while a rewrite runs |

### The append-only file

| file | what it checks |
|---|---|
| [`aof_test.py`](aof_test.py) | a random stream on the 16 databases (transactions and a FLUSHALL among it), the server restarted from its file, every database read back the same; `run_tests.sh` then cuts the file's last entry short, and the restart must cut it back |
| [`crash_test.py`](crash_test.py) | rounds of SIGKILL at a random moment while 1 to 16 connections write, some while a rewrite runs and some while a start loads the file: each start must hold the databases after a prefix of the commands sent, every acknowledged one among them |
| [`aof_fail_test.py`](aof_fail_test.py) | the disk failing under the file, injected by [`fail_io.c`](fail_io.c) (an `LD_PRELOAD` shim): a file that cannot be read, a failed fsync, a failed sync of the directory, the order in which the file is made, its directory synced and the first reply sent; files the start must refuse, each left as it was |
| [`aof_redis_test.py`](aof_redis_test.py) | the files both ways: the same commands to BendKV and to a `redis-server` that keeps its own file, then BendKV started from Redis's file and Redis from BendKV's, each holding the databases the other held |
| [`rewrite_test.py`](rewrite_test.py) | BGREWRITEAOF's replies and INFO's account against Redis's, the rewritten file against Redis's base, command for command, writes during a rewrite and a kill during one, the cron's rewrites, rewrites that fail, and both servers started from the new file |

### Robustness

| file | what it checks |
|---|---|
| [`robust_test.py`](robust_test.py) | requests split into single bytes, a large value, a pattern slow to match, protocol garbage, many connections at once |
| [`writer_test.py`](writer_test.py) | a client that stops reading holds up only itself, while others get large replies and quick ones |
| [`concurrency_test.py`](concurrency_test.py) | under concurrent pipelined clients: no lost update, a command on several keys seen whole, writes to two keys seen in order |
| [`conn_test.py`](conn_test.py) | connections that end every way one can (a close, QUIT, a protocol error, a reset), many times, on a BendKV of its own: each must close the channel it opened |
