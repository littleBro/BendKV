# BendKV: make check (proofs), make verdict (proofs, rechecked by the
# Lean-proven BendTT kernel), make build, make pgo (build/bendkv-pgo, with
# profile-guided optimization), make smoke (the pure checks: a batch end to
# end, the append-only file; any that fails stops it), make test (needs
# redis-server, redis-cli, python3 and a C compiler for the disk-failure
# shim, tests/fail_io.c; redis-check-aof if there is one),
# make bench (needs redis-benchmark), make perfcheck (instructions, misses
# and prefetches per request against a baseline; needs valgrind and
# objdump), make suite (Redis's own
# test suite; needs a Redis 7.0.15 source tree in REDIS_SRC, its
# redis-server on the PATH, and tclsh), make clients (the test suites of
# redis-py and go-redis; needs python3, go, and PyPI and the Go module
# proxy). Everything needs Bend with
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
# Chan.marked; the rewrite of the append-only file puts the new file in
# place with the twenty-eighth's File.rename and takes a temporary file
# back with its File.unlink; INFO's used_memory and maxmemory read the
# heap's account with the twenty-ninth's IO.heap; OBJECT IDLETIME and FREQ
# and the eviction's LRU and LFU keep when each key was last used with the
# thirtieth's Mem.touch and Mem.cell; GEO computes, and ZADD reads its
# scores, with C's doubles, the thirty-third's F64 and F64.read; the others
# only speed up the runtime and the code):
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

.PHONY: check verdict build pgo smoke run test bench perfcheck suite clients gencheck clean

check:
	CC=$(BEND_CC) $(BEND) proof/PROOF.bend

verdict:
	CC=$(BEND_CC) $(BEND) proof/PROOF.bend --verdict

build: build/bendkv

# The emitted C is compiled here rather than by Bend, with the Lua engine
# beside it: Redis 7.0.15's Lua and three of its helpers (deps/redis,
# vendored as they are, built once into build/deps with Redis's flags),
# whose headers src/lua/engine.c includes (tools/sanitize.sh and
# tools/pgo_build.sh build the same sources with their own flags)
DEPS_SRC = $(wildcard deps/redis/deps/lua/src/*.c) $(wildcard deps/redis/src/*.c)
DEPS_OBJ = $(patsubst %.c,build/deps/%.o,$(notdir $(DEPS_SRC)))
DEPS_INC = -I deps/redis/deps/lua/src -I deps/redis/src
DEPS_FLAGS = $(DEPS_INC) -DENABLE_CJSON_GLOBAL -DREDIS_STATIC= -DLUA_USE_MKSTEMP -D_GNU_SOURCE

build/deps/%.o: deps/redis/deps/lua/src/%.c
	mkdir -p build/deps
	$(BEND_CC) -std=c11 -O3 -c $< $(DEPS_FLAGS) -o $@

build/deps/%.o: deps/redis/src/%.c
	mkdir -p build/deps
	$(BEND_CC) -std=c11 -O3 -c $< $(DEPS_FLAGS) -o $@

build/bendkv: build/bendkv.c $(DEPS_OBJ)
	$(BEND_CC) -std=c11 -O3 build/bendkv.c $(DEPS_OBJ) $(DEPS_INC) -lpthread -lm -o build/bendkv

# the server built with profile-guided optimization: an instrumented build
# serves a redis-benchmark training load, and the server is built again
# with its profile (tools/pgo_build.sh; needs llvm-profdata)
pgo: build/bendkv-pgo

build/bendkv.c: $(SRC) src/lua/engine.c src/lua/engine.js
	mkdir -p build
	CC=$(BEND_CC) $(BEND) src/server.bend -o build/bendkv.c

build/bendkv-pgo: build/bendkv.c tools/pgo_build.sh tools/pgo_exit.c $(DEPS_SRC)
	CC=$(BEND_CC) DEPS_SRC="$(DEPS_SRC)" DEPS_FLAGS="$(DEPS_FLAGS)" sh tools/pgo_build.sh build/bendkv.c build/bendkv-pgo

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

# instructions, last-level misses and prefetches per GET, SET and INCR
# under callgrind against tools/perf_baseline.txt (needs valgrind,
# redis-benchmark and objdump)
perfcheck: build
	sh tools/perf_guard.sh build/bendkv

# Redis's own test suite, the units that run against a server already
# started (tools/redis_suite.py), on redis-server and on BendKV, and the
# table of the tests Redis passes that BendKV passes (docs/COMPATIBILITY.md)
suite: build
	python3 tools/redis_suite.py --redis-src $(REDIS_SRC) --server redis-server --port 6600 --out build/suite/redis.json --logs build/suite/redis-logs
	python3 tools/redis_suite.py --redis-src $(REDIS_SRC) --server build/bendkv --port 6700 --out build/suite/bendkv.json --logs build/suite/bendkv-logs
	python3 tools/redis_suite.py --report build/suite/redis.json build/suite/bendkv.json | tee build/suite/report.md

# The test suites of client libraries (tools/client_suite.py): redis-py in
# RESP2 and RESP3, and go-redis, each against redis-server and BendKV,
# against the known failures of tools/data/clients.json (needs python3,
# go and network access to PyPI and the Go module proxy)
clients: build
	python3 tools/client_suite.py ci --client redis-py --protocol 2 --server build/bendkv --out build/clients
	python3 tools/client_suite.py ci --client redis-py --protocol 3 --server build/bendkv --out build/clients
	python3 tools/client_suite.py ci --client go-redis --server build/bendkv --out build/clients

# the generated blocks are up to date: the 16-way parts of src/map.bend,
# proof/LAWS.bend and proof/PROOF.bend (tools/gen_trie.py), the table of parameters in
# src/config.bend (tools/gen_config.py), the table of commands in
# src/command.bend and their arities in src/redis.bend
# (tools/gen_commands.py), and the counts of README.md's In numbers, and
# of its laws (tools/gen_counts.py)
gencheck:
	python3 tools/gen_trie.py --check
	python3 tools/gen_config.py --check
	python3 tools/gen_commands.py --check
	python3 tools/gen_counts.py --check

clean:
	rm -rf build
