# BendKV: make check (proofs), make verdict (proofs, rechecked by the
# Lean-proven BendTT kernel), make build, make pgo (build/bendkv-pgo, with
# profile-guided optimization), make smoke (the pure checks: a batch end to
# end, the append-only file), make test (needs
# redis-server, redis-cli, python3 and a C compiler for the disk-failure
# shim, tests/fail_io.c; redis-check-aof if there is one),
# make bench (needs redis-benchmark), make perfcheck (instructions per
# request against a baseline; needs valgrind). Everything needs Bend with
# bend-patches/ applied (src/map.bend hashes with String.hash, which the fourth
# patch adds to Base, and hints with Mem.prefetch, which the ninth adds;
# replies are posted to the tenth's writer thread (TCP.post), and the
# actor answers a group of batches with its Chan.send_all; the append-only
# file is written with the twelfth's File.write_raw and File.sync, a group
# at a time with the thirteenth's Chan.drain; the parser reads number
# lines and key hashes by index with the seventeenth's String.dec_line_at
# and String.hash_at; the others only speed up the runtime and the
# code):
#   make build BEND="bun <patched bend>/bend2/main.ts"
# Bend compiles with $(BEND_CC) when it has one: clang 19 honors the
# preserve_none calling convention of the runtime's segments, clang 18
# ignores it (~8% more instructions); Bend falls back to plain clang.

BEND       ?= bend
BEND_CC    ?= clang-19
PORT       ?= 6380
REDIS_PORT ?= 6390

SRC = $(wildcard src/*.bend)

.PHONY: check verdict build pgo smoke run test bench perfcheck gencheck clean

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

smoke:
	CC=$(BEND_CC) $(BEND) tests/smoke.bend
	CC=$(BEND_CC) $(BEND) tests/aof_check.bend

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

# the generated blocks are up to date: the 16-way parts of src/map.bend
# and proof/PROOF.bend (tools/gen_trie.py), and the table of parameters
# in src/config.bend (tools/gen_config.py)
gencheck:
	python3 tools/gen_trie.py --check
	python3 tools/gen_config.py --check

clean:
	rm -rf build
