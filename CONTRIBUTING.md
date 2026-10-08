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

For the tests you also need `redis-server` and `redis-cli` (Redis 7.0.15 is the
reference), Python 3 and a C compiler; for `make perfcheck`, `valgrind` and
`redis-benchmark`.

## Before you open a pull request

```bash
make check     BEND="$B"   # every proof checks
make verdict   BEND="$B"   # ... in the BendTT kernel too
make gencheck              # generated blocks are up to date
make smoke     BEND="$B"
make test      BEND="$B"   # byte-for-byte against Redis
make perfcheck BEND="$B"   # no more than 3% more instructions per request
```

## How changes are made

- **A new command or behavior** comes with: its semantics in `src/redis.bend` (or
  `src/session.bend` for the state of a connection), the existing laws extended to it
  in `proof/PROOF.bend` (the `frame` law covers every command), a new law in
  `proof/LAWS.bend` when it promises something new, and a case in the tests under
  `tests/` that compares it with Redis byte for byte.
- **Laws are stated by people.** A change to `proof/LAWS.bend` that weakens a law needs
  a reason in the pull request.
- **The 16-way parts** of `src/map.bend` and `proof/PROOF.bend`, between
  `BEGIN gen_trie` and `END gen_trie`, are written by `tools/gen_trie.py`: change the
  script and rerun it, not the blocks.
- **Performance.** The server's hot path is sensitive to how the Bend compiler lays out
  terms; [docs/FINDINGS.md](docs/FINDINGS.md) (section 7) lists the traps. A deliberate
  change in instructions per request updates `tools/perf_baseline.txt` with the numbers
  and the reason. Throughput claims are measured as [tools/README.md](tools/README.md)
  describes (interleaved pairs over several code layouts), not from a single run.
- **Bend constraints** worth knowing: a function can call only functions defined above
  it (except `@unsafe` ones), there is no mutual recursion, recursion is structural,
  and `match` takes a parameter, not a computed value. README.ru.md lists more.

## Style

- Code comments and English docs in English; Russian docs (`README.ru.md`,
  `docs/PERFORMANCE.md`, `bend-patches/README.md`) in Russian.
- Comments say what a definition means and why, in plain sentences, as the existing code
  does.
- Commits are small and say what changed and why.
