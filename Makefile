# BendKV: make check (proofs), make verdict (proofs, rechecked by the
# Lean-proven BendTT kernel), make build, make pgo (build/bendkv-pgo, with
# profile-guided optimization), make smoke (the pure checks: a batch end to
# end, the append-only file; any that fails stops it), make test (needs
# redis-server, redis-cli, python3 and a C compiler for the disk-failure
# shim, tests/fail_io.c; redis-check-aof if there is one),
# make bench (needs redis-benchmark), make perfcheck (instructions per
# request against a baseline; needs valgrind), make suite (Redis's own
# test suite; needs a Redis 7.0.15 source tree in REDIS_SRC, its
# redis-server on the PATH, and tclsh). Everything needs Bend with
# bend-patches/ applied (src/map.bend hashes with String.hash, which the fourth
# patch adds to Base, and hints with Mem.prefetch, which the ninth adds;
# replies are posted to the tenth's writer thread (TCP.post), and the
# actor answers a group of batches with its Chan.send_all; the append-only
# file is written with the twelfth's File.write_raw and File.sync, a group
# at a time with the thirteenth's Chan.drain; the parser reads number
# lines and key hashes by index with the seventeenth's String.dec_line_at
# and String.hash_at; the start changes the directory and logs the pid
# and the date with the twentieth's IO.chdir, IO.cwd, IO.pid and
# IO.clock, and cuts a file of any size and syncs its directory with the
# twenty-fourth's File.truncate of a Nat and File.sync_dir; a connection
# whose client waits or is subscribed waits on its socket and its channel
# at once with the twenty-fifth's TCP.watch and TCP.unwatch; CLIENT LIST,
# INFO and KILL read a socket's fd and addresses with the twenty-seventh's
# TCP.name, shut a socket down with its TCP.kill, and mark a client's
# channel with its last command and time with its Chan.mark and
# Chan.marked; the others only speed up the runtime and the code):
#   make build BEND="bun <patched bend>/bend2/main.ts"
# Bend compiles with $(BEND_CC) when it has one: clang 19 honors the
# preserve_none calling convention of the runtime's segments, clang 18
# ignores it (~8% more instructions); Bend falls back to plain clang.

BEND       ?= bend
BEND_CC    ?= clang-19
PORT       ?= 6380
REDIS_PORT ?= 6390
REDIS_SRC  ?= ../redis

SRC = $(wildcard src/*.bend)

.PHONY: check verdict build pgo smoke run test bench perfcheck suite gencheck clean

check:
	CC=$(BEND_CC) $(BEND) proof/PROOF.bend

verdict:
	CC=$(BEND_CC) $(BEND) proof/PROOF.bend --verdict

build: build/bendkv

build/bendkv: $(SRC)
	mkdir -p build
	CC=$(BEND_CC) $(BEND) src/server.bend -o build/bendkv

# the server built with profile-guided optimization: an instrumented build
# serves a redis-benchmark training load, and the server is built again
# with its profile (tools/pgo_build.sh; needs llvm-profdata)
pgo: build/bendkv-pgo

build/bendkv.c: $(SRC)
	mkdir -p build
	CC=$(BEND_CC) $(BEND) src/server.bend -o build/bendkv.c

build/bendkv-pgo: build/bendkv.c tools/pgo_build.sh tools/pgo_exit.c
	CC=$(BEND_CC) sh tools/pgo_build.sh build/bendkv.c build/bendkv-pgo

# the pure checks, built once for bun: each must pass, and each must fail
# (exit 1) when one kind of its checks is given a wrong expectation
# (tests/smoke_check.sh)
smoke:
	mkdir -p build
	$(BEND) tests/smoke.bend -o build/smoke.js
	$(BEND) tests/aof_check.bend -o build/aof_check.js
	sh tests/smoke_check.sh build/smoke.js build/aof_check.js

run: build
	./build/bendkv $(PORT)

test: build
	CC=$(BEND_CC) BEND="$(BEND)" PORT=$(PORT) REDIS_PORT=$(REDIS_PORT) sh tests/run_tests.sh

bench: build
	PORT=$(PORT) REDIS_PORT=$(REDIS_PORT) sh bench/run_bench.sh

# instructions per GET, SET and INCR under callgrind against
# tools/perf_baseline.txt (needs valgrind and redis-benchmark)
perfcheck: build
	sh tools/perf_guard.sh build/bendkv

# Redis's own test suite, the units that run against a server already
# started (tools/redis_suite.py), on redis-server and on BendKV, and the
# table of the tests Redis passes that BendKV passes (docs/COMPATIBILITY.md)
suite: build
	python3 tools/redis_suite.py --redis-src $(REDIS_SRC) --server redis-server --port 6600 --out build/suite/redis.json --logs build/suite/redis-logs
	python3 tools/redis_suite.py --redis-src $(REDIS_SRC) --server build/bendkv --port 6700 --out build/suite/bendkv.json --logs build/suite/bendkv-logs
	python3 tools/redis_suite.py --report build/suite/redis.json build/suite/bendkv.json | tee build/suite/report.md

# the generated blocks are up to date: the 16-way parts of src/map.bend
# and proof/PROOF.bend (tools/gen_trie.py), the table of parameters in
# src/config.bend (tools/gen_config.py), and the table of commands in
# src/command.bend and their arities in src/redis.bend
# (tools/gen_commands.py)
gencheck:
	python3 tools/gen_trie.py --check
	python3 tools/gen_config.py --check
	python3 tools/gen_commands.py --check

clean:
	rm -rf build
