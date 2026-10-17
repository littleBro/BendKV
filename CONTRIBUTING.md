# Contributing to BendKV

Thank you for your interest. BendKV is a research prototype, and its rule is simple:
what runs is what is proved, and what is not proved is tested against Redis.

## Setup

Build the patched Bend once (see [README.md](README.md#building)):

```bash
git clone https://github.com/bendlang/bend ../bend-patched
sh bend-patches/apply.sh ../bend-patched
export B="bun ../bend-patched/bend2/main.ts"
```

For the tests you also need `redis-server`, `redis-cli` and `redis-benchmark` (Redis
7.0.15 is the reference), Python 3 and a C compiler; for `make perfcheck`, `valgrind`
too.

## Before you open a pull request

```bash
make check     BEND="$B"   # every proof checks
make verdict   BEND="$B"   # ... in the BendTT kernel too
make gencheck              # generated blocks are up to date
make smoke     BEND="$B"
make test      BEND="$B"   # byte-for-byte against Redis
make perfcheck BEND="$B"   # instructions per request within 3% of the baseline, misses and prefetches too
```

CI runs them in two tiers ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)). The
light tier runs on every push to a pull request and to `main`: `make gencheck`, the
proofs and `make smoke`, the server built (kept in the cache while what it is built from
stays the same) and `make perfcheck`; a change of documents alone runs `make gencheck`
alone. The heavy tier runs only when it is started by hand, on a branch: the branch merged
with `main`, `make test` against the Redis 7.0.15 that Ubuntu 24.04 ships (in three parts
side by side, `tests/run_tests.sh`'s `PARTS`), the client suites, and the server built
with AddressSanitizer and UndefinedBehaviorSanitizer and with ThreadSanitizer, the tests
that stress its memory and its writer thread run under each (`sh tools/sanitize.sh`, which
runs the same here; it needs clang 19's sanitizer runtimes). Its result is the commit
status "CI heavy" on the branch's head, and a pull request merges once it is success there
(AGENTS.md, Merging). Its toolchain is
the one above: bun 1.3.14, clang 19, the patched Bend (kept in the cache while
`bend-patches/` stays the same) and, for `make verdict`, Lean 4.34.0, which builds the
BendTT kernel once (cached too). A change goes in through a pull request whose checks
pass.

The differential tests of `make test` take their seeds from the CI run, so each run
sends random commands of its own; the log names them first, and `SEED=N make test`
sends them again. A nightly run ([`.github/workflows/nightly.yml`](.github/workflows/nightly.yml))
sends about a million of them to main's server.

## How changes are made

- **A new command or behavior** comes with: its semantics in `src/redis.bend` (or
  `src/session.bend` for the state of a connection), the same on the trie alone in the
  specification `proof/SPEC.bend` with its case of the bridge (`bridge_go`, `bt_go`),
  the existing laws extended to it in `proof/PROOF.bend` (the `frame` law covers every
  command), a new law in `proof/LAWS.bend` when it promises something new, and a case in
  the tests under `tests/` that compares it with Redis byte for byte.
- **A human approves every change to the laws.** A new law, a removed one or a changed
  statement in `proof/LAWS.bend` merges once the owner has approved it in the pull
  request, and one that weakens a law gives the reason there.
- **The 16-way parts** of `src/map.bend`, `proof/LAWS.bend` and `proof/PROOF.bend`,
  between `BEGIN gen_trie` and `END gen_trie`, are written by `tools/gen_trie.py`, and the
  table of parameters in `src/config.bend` by `tools/gen_config.py` (from
  `tools/data/redis-configs.json`, which it extracts from Redis's `src/config.c`), and the
  table of commands in `src/command.bend` and the commands' arities, statistics and
  dispatch in `src/redis.bend` by `tools/gen_commands.py` (from
  `tools/data/redis-commands.json`, which it asks a `redis-server` for):
  change the script and rerun it, not the blocks.
- **The counts** in README.md's [In numbers](README.md#in-numbers) (the laws, the
  patches, `Cmd`'s constructors, Redis's parameters, the lines of each file) are written
  by `tools/gen_counts.py`; rerun it when `make gencheck` finds one out of date, and link
  to them from another document rather than copy a count into it.
- **Patterns of literal characters** nested inside a String (`SCon{a, SCon{'-', ...}}`)
  make `--verdict` explode: a Char is a 32-bit word in the kernel, and its decision
  trees multiply. Compare bytes with `U32.is_eq` instead (see `cls.kind` in
  `src/config.bend`); a literal at the head of a match is fine.
- **Performance.** The server's hot path is sensitive to how the Bend compiler lays out
  terms; [docs/FINDINGS.md](docs/FINDINGS.md) (section 7) lists the traps. A deliberate
  change in instructions per request updates `tools/perf_baseline.txt` with the numbers
  and the reason. Throughput claims are measured as [tools/README.md](tools/README.md)
  describes (interleaved pairs over several code layouts), not from a single run.
- **Bend constraints** worth knowing: a function can call only functions defined above
  it (except `@unsafe` ones), there is no mutual recursion, recursion is structural,
  and `match` takes a parameter, not a computed value. OVERVIEW.md lists more.

## Style

- Everything in English: code, comments, documents and commit messages.
- Comments say what a definition means and why, in plain sentences, as the existing code
  does.
- Commits are small and say what changed and why.

## License

BendKV is licensed under the Apache License, Version 2.0 ([LICENSE](LICENSE)). A
contribution you submit comes under that license, as its section 5 says, unless you state
otherwise in writing.

Code, text or data from elsewhere comes in only under a license compatible with Apache 2.0
(MIT, BSD, Apache 2.0, Boost, CC0, public domain), and the pull request that brings it in
adds its entry to [NOTICE](NOTICE): what it is, from which file of which version, and under
which license.

- **Redis 7.2.x and earlier** are under the BSD 3-Clause License: their code, tables and
  tests may be ported, with their notice. Security fixes come from Redis's 7.2 branch.
- **Redis 7.4 and later** are under RSALv2 and SSPLv1, and Redis 8 adds AGPLv3. Do not read
  their sources: no file of those trees, their tests and their commands' JSON included. A
  behavior of theirs may be written from what a running server answers and from what the
  documentation describes, in our own words; the text of their documentation, on redis.io
  (CC BY-NC-SA 4.0) or in COMMAND DOCS, is not copied.
- **Valkey** is under the BSD 3-Clause License and may be ported, with its notice.
