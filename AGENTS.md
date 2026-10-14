# BendKV: notes for coding agents

BendKV is a Redis 7.0.15-compatible server written in Bend2. Its core is proved
against the laws of `proof/LAWS.bend`; everything else is tested against a real
`redis-server`. Read `CONTRIBUTING.md` first: this file adds what an agent needs on
top of it.

Claude Code reads this file only while the repository has no `CLAUDE.md`,
`.claude/CLAUDE.md` or `CLAUDE.local.md`: do not add one.

## Map

    src/map.bend       hash trie                                   verified
    src/redis.bend     command semantics, exec(cmd, db)            verified
    src/batch.bend     a batch with prefetch hints (batch_hints)   verified
    src/aof.bend       append-only file: effects, encode, load     verified
    src/session.bend   connection and server state, whole batches  verified
    src/config.bend    CONFIG GET and SET                          verified
    src/resp.bend, info.bend, command.bend, startup.bend          tested only
    src/server.bend    the shell: actor, connections, AOF I/O, waits,
                       transactions, pub/sub, eviction, rewrite     tested only
    proof/LAWS.bend    the laws: stated by people
    proof/SPEC.bend    the commands on the bare trie (the bridge's other side)
    proof/PROOF.bend   the proofs: written by machine, checked by Bend and BendTT
    tests/             tests against redis-server, run by tests/run_tests.sh
    tools/             generators (gen_*.py), measurement and CI scripts
                       (tools/README.md lists them)
    bend-patches/      32 patches to bendlang/bend@1cce499: the compiler and its
                       runtime are part of the trusted base
    docs/FINDINGS.md   what each change found and cost, one section per change

## Toolchain

    git clone https://github.com/bendlang/bend ../bend-patched
    sh bend-patches/apply.sh ../bend-patched
    export BEND="bun ../bend-patched/bend2/main.ts"

clang 19 (the Makefile's `BEND_CC`; clang 18 builds, but counts about 8% more
instructions, so `make perfcheck` only means something with clang 19). Lean 4.34.0
through elan for `make verdict` (the kernel is built once into `~/.bend/bendtt`).
`redis-server`, `redis-cli` and `redis-benchmark` 7.0.15 for `make test`.

In Claude Code's cloud sessions, `.claude/hooks/session-start.sh` sets all of this
up at the start and exports `BEND` and `BEND_CC`, so `make check` needs no
arguments; it prints what it found.

## Checks

Every pull request passes all of these; CI runs the same.

    make check     # the proofs, about 15 s
    make verdict   # the proofs in the BendTT kernel, about 2 min
    make gencheck  # the generated blocks are current
    make smoke     # pure checks; each must also fail when broken
    make test      # against redis-server 7.0.15, about 8 min on 4 cores
    make perfcheck # instructions per request against tools/perf_baseline.txt

## Rules

1. **Laws are stated by people.** Do not add, remove or change the statement of a
   law in `proof/LAWS.bend`, or what `proof/SPEC.bend` means, without a human's
   approval in the issue or the pull request. When a change needs a new or
   different law, write the exact statement in the pull request and wait. Proofs
   in `proof/PROOF.bend` are yours to write.
2. **Do not weaken a check to make it pass.** No skipped or loosened tests, no new
   entries in `tools/data/clients.json`, no edit of `tools/perf_baseline.txt`, no
   higher tolerance, unless the issue asks for it; when one is justified, the
   commit message says why.
3. **Generated blocks** (`BEGIN gen_trie` … `END gen_trie`, the tables of parameters
   and commands) come from `tools/gen_*.py`: change the generator and rerun it.
4. **English everywhere**: code, comments, documents, commits, issues.
5. **No stub intrinsics in verified files.** `Mem.cell`, `Mem.touch`, `Chan.mark`,
   `Chan.marked` and `IO.heap` have Bend bodies that are constants; only
   `src/server.bend` may call them, or the proofs are about the constant.
6. **Bend's constraints.** Define before use (except `@unsafe`), no mutual
   recursion, structural recursion (fuel otherwise), `match` on parameters only.
   `Bool.pick` evaluates both arms, and a `Nat` past 2^48 − 1 aborts the process:
   never put arithmetic that can grow that far in an arm (FINDINGS 3zc). Nested
   literal `Char` patterns blow up `--verdict`: compare with `U32.is_eq`.
7. **Performance traps** are listed in `docs/FINDINGS.md` section 7: a new call
   site can change how the compiler passes arguments to hot functions. Run
   `make perfcheck` after any change to the hot path.
8. **Redis is the reference.** Replies match Redis 7.0.15 byte for byte, unless the
   difference is listed under "Where BendKV differs" in README.md and in
   `docs/COMPATIBILITY.md`.
9. **Claims follow the laws.** Do not call anything "proved" or "verified" in the
   documents unless a law in `proof/LAWS.bend` states it.

## Workflow

- Work comes from GitHub issues. Those labeled `agent-ok` are yours to take;
  those labeled `needs-decision` wait for a human: do not start them.
- One issue, one branch, one pull request; its description says `Fixes #N`, so
  the issue closes when it merges.
- Before changing code, run the issue's verification command and see it fail.
- Check the open pull requests first: two sessions must not change
  `src/server.bend` at once.
- After the change: a section in `docs/FINDINGS.md` in the existing style (what,
  why, what it cost), `docs/PERFORMANCE.md` when counts or throughput change,
  README and `docs/COMPATIBILITY.md` when behavior changes. Put a number in one
  document and link to it from the others rather than copying it.
