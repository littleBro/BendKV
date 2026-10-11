# Tools

Scripts behind the numbers in [PERFORMANCE.md](../docs/PERFORMANCE.md) and
[docs/FINDINGS.md](../docs/FINDINGS.md). The servers they drive take their port as
their first argument: `build/bendkv` (a second argument, `post` or `send`, picks how
replies go out, and a third names an append-only file), or any build of the same C from
`cc_variants.sh`. They need `redis-server`, `redis-cli`, `redis-benchmark`, `taskset`
and, for profiles, `valgrind`.

| tool | what it does |
|---|---|
| `gen_trie.py` | writes the 16-way parts of `src/map.bend` and `proof/PROOF.bend` (between `BEGIN gen_trie` and `END gen_trie`); `--check` fails if one is out of date |
| `gen_config.py` | writes the table of parameters in `src/config.bend` from `data/redis-configs.json`, the facts of Redis 7.0.15's own table (`--extract ../redis` reads them from Redis's `src/config.c`); `--check` fails if it is out of date |
| `gen_commands.py` | writes the table of commands in `src/command.bend` from `data/redis-commands.json`, Redis 7.0.15's descriptions of BendKV's commands (`--extract` starts a `redis-server` and asks it COMMAND INFO, COMMAND DOCS and ACL CAT); `--check` fails if it is out of date |
| `bench_pairs.sh` | paired throughput runs of several servers (and Redis) on fresh processes, with the server's CPU time per request; `PIPE`, `CLIENTS`, `SCPU`, `CCPU` and `SARGS` change the load and the pinning |
| `pair_ratios.py` | medians and geometric means of per-trial ratios from `bench_pairs.sh` (or `memtier_hits.sh`), against Redis or any variant; `--cpu` for CPU per request. Builds named `NAME_s1`, `NAME_s2`, ... count as one variant `NAME` |
| `layouts.sh` | builds one generated C file once per seed, each with its functions in a different shuffled order (`NAME_s1`, `NAME_s2`, ...), so that a variant is timed over several code layouts rather than one |
| `perf_guard.sh`, `perf_baseline.txt` | `make perfcheck`: instructions per GET, SET and INCR against a baseline; fails 3% above it. The server sends from its loop. The count repeats to ~0.05%, and the guard flags the 27% regression of PERFORMANCE.md 7.17 at +15–19% |
| `callgrind_req.sh` | instructions, last-level misses and mispredicted branches per request, under callgrind with a 2 MiB last-level cache; `PIPE`, `CLIENTS` and `DATA` (the value size, 3 bytes by default) change the load |
| `phases.py` | where a request's instructions and time go, by phase (RESP parsing, command parsing, hashes and hints, execution, replies, the actor, the event loop, the kernel): `cg` for a dump of `callgrind_req.sh` (a server built with `-g`; runtime helpers count for the phases of their callers), `callers` for who calls a function, `sprof` for samples of `sprof_run.sh` (`--redis` for Redis's own functions) |
| `spin_names.sh` | names the generated C's `spin_N` loops after the Bend defs they run, for `phases.py --spins`: a copy of the patched Bend writes each spin's def in a comment, with the same numbering |
| `sprof.c`, `sprof_run.sh`, `sprof_report.py` | a timer-sampling profiler for machines without performance counters (VMs): the share of samples per function, from the interrupted instruction addresses. With `SPROF_CPU=1` the timer is the process's CPU time (`ITIMER_PROF`, one sample per kernel tick), which lands on the running thread, and each sample keeps its thread: `sprof_report.py OUT 40 EXE --thread N` reports thread N alone |
| `cc_variants.sh` | one generated C file built several ways: clang 19 and 18, `-march=x86-64-v3` and `native`, forced inlining, a CRC32C hash, PGO |
| `pgo_exit.c` | shim that lets an instrumented server exit cleanly on `SIGUSR2`, so its profile gets written |
| `nothp.c` | runs a command with transparent huge pages off, to measure one binary with and without 2 MiB pages |
| `hash_buckets.py` | how redis-benchmark's keys spread over the trie's buckets under FNV-1a and CRC32C |
| `memtier_specs.py` | runs specs from Redis's own performance suite ([redis-benchmarks-specification](https://github.com/redis/redis-benchmarks-specification)) with `memtier_benchmark` against Redis and BendKV builds, interleaved, with the server's CPU time per operation. A server takes extra arguments after commas: `build/bendkv,send` sends replies from its loop, `redis,io-threads=2` passes `--io-threads 2`. Its summary pools layouts as `pair_ratios.py` does |
| `memtier_hits.sh` | GETs that all hit: the 1Mkeys GET specs read keys from a range ten times wider than they load, so 90% of their GETs miss; this loads 1M keys and reads the same range, at a given pipeline depth, with output for `pair_ratios.py` |
| `loadgen.c` | a load generator light enough to leave three of four cores to the server: one thread, epoll, P requests in flight per connection (as memtier's `--pipeline`), GETs, SETs or MGETs of random keys, after one preload of every key |
| `scale_bench.sh` | throughput as a server gets more cores: each server on CPUs 1–3, `loadgen` on CPU 0, for several load shapes (pipeline depth, GET share), interleaved trials. `redis,3` runs Redis with 3 io-threads |
| `iocount.c` | an `LD_PRELOAD` shim that counts a server's `recv` (and empty `EAGAIN` ones), `send`, `select`, `epoll_wait`, pipe reads and writes; `kill -USR1` resets, `kill -USR2` writes the counts |
| `pgo_build.sh` | `make pgo`: builds the generated C with profile-guided optimization, trained by redis-benchmark with replies posted to the writer and sent from the loop |

`bench/run_bench.sh` (`make bench`) is the quick comparison with Redis on an empty
database; `bench/bench_map.bend` times the map alone, in process, without the network.

## How the numbers were measured

- **Two load generators.** `redis-benchmark` (from the Redis repository) sends 16
  commands per connection and waits for all 16 replies, so every read the server makes
  is a full batch; with 3-byte values that is the best case for BendKV. Redis's own CI
  suite drives `memtier_benchmark` instead: several threads, hundreds of connections,
  10–1000-byte values, and a new command as soon as a reply arrives. `memtier_specs.py`
  runs those specs unchanged except for client threads and duration, and they are the
  main yardstick. memtier is built from source (`RedisLabs/memtier_benchmark`; it needs
  `libevent-dev`).

- **Pairs, not absolute numbers.** The test machine is a 4-vCPU VM (Xeon at 2.1 GHz,
  2 MiB L2 per core, an L3 shared with other VMs; from PERFORMANCE.md 9.7 on, a Cascade
  Lake Xeon at 2.8 GHz with 1 MiB of L2 per core). Absolute throughput drifted by
  ~15% between days and by up to ±10% between series on one day. Each trial of
  `bench_pairs.sh` runs every variant once, interleaved, and `pair_ratios.py`
  compares variants within a trial only. Results are medians over 4–24 pairs.
- **Pinning.** The server runs on CPU 3 and `redis-benchmark` on CPU 1: 20 clients,
  pipeline depth 16, keys drawn from the same space that was filled first.
- **Instructions are deterministic, time is not.** `callgrind_req.sh` counts per request
  after a warm-up of 3×KEYS requests (so INCR finds its counters and the caches are
  warm). An instruction difference shows up in one run; a time difference under ~5%
  needs many pairs.
- **Code layout noise.** Two builds of the same C with almost the same instruction
  counts can differ by ±5–10% in time: `-march=x86-64-v3` made the server 4–9%
  slower and the in-process map benchmark 4–9% faster. Only effects that hold across
  workloads and series count. Since PERFORMANCE.md 7.23, every variant is built in
  three shuffled layouts (`layouts.sh`), and the ratios pool them.
- **Isolating memory stalls.** The trie always has five levels, so a request runs the
  same instructions with 1 thousand, 100 thousand or 1 million keys. The difference in
  user time between those runs is time spent waiting for memory.
- **What valgrind cannot do.** valgrind 3.22 stops on some code built with `-march`
  (a register-to-register `vmovq`), so those builds are timed but not counted.
