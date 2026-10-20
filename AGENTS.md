# BendKV: notes for coding agents

BendKV is a Redis 7.2.16-compatible server written in Bend2. Its core is proved
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
    src/resp.bend, info.bend, command.bend, startup.bend,
        float.bend, hll.bend, geo.bend, lolwut.bend, rdb.bend    tested only
    src/server.bend    the shell: actor, connections, AOF I/O, waits,
                       transactions, pub/sub, eviction, rewrite     tested only
    proof/LAWS.bend    the laws: a human approves every change
    proof/SPEC.bend    the commands on the bare trie (the bridge's other side)
    proof/PROOF.bend   the proofs: written by machine, checked by Bend and BendTT
    tests/             tests against redis-server, run by tests/run_tests.sh
                       (tests/README.md lists them)
    tools/             generators (gen_*.py), measurement and CI scripts
                       (tools/README.md lists them)
    bend-patches/      the patches to bendlang/bend@1cce499, in apply.sh's order:
                       the compiler and its runtime are part of the trusted base
    docs/COMMANDS.md   every command, area by area, and where BendKV differs
    docs/FINDINGS.md   what each change found and cost, one section per change
    LICENSE, NOTICE    Apache 2.0, and what comes from elsewhere (rule 10)

## Toolchain

    git clone https://github.com/bendlang/bend ../bend-patched
    sh bend-patches/apply.sh ../bend-patched
    export BEND="bun ../bend-patched/bend2/main.ts"

clang 19 (the Makefile's `BEND_CC`; clang 18 builds, but counts about 8% more
instructions, so `make perfcheck` only means something with clang 19). Lean 4.34.0
through elan for `make verdict` (the kernel is built once into `~/.bend/bendtt`).
`redis-server` and `redis-cli` 7.2.16 for `make test`, and 7.0.15's `redis-benchmark`
for `make perfcheck`, whose baseline counts the requests that tool sends.

In Claude Code's cloud sessions, `.claude/hooks/session-start.sh` sets all of this
up at the start and exports `BEND` and `BEND_CC`, so `make check` needs no
arguments; it prints what it found.

## Checks

Every pull request passes all of these before it merges. CI runs the light ones on
every push, and `make test` with the client suites and the sanitizers when it is run
by hand (Merging).

    make check     # the proofs, about 15 s
    make verdict   # the proofs in the BendTT kernel, about 2 min
    make gencheck  # the generated blocks are current
    make smoke     # pure checks; each must also fail when broken
    make test      # against redis-server 7.2.16, about 8 min on 4 cores
    make perfcheck # instructions per request against tools/perf_baseline.txt

## Rules

1. **A human approves every change to the laws.** Do not add, remove or change the
   statement of a law in `proof/LAWS.bend`, or what `proof/SPEC.bend` means,
   without a human's approval in the issue or the pull request. When a change
   needs a new or different law, write the exact statement in the pull request
   and wait. Proofs in `proof/PROOF.bend` are yours to write.
2. **Do not weaken a check to make it pass.** No skipped or loosened tests, no new
   entries in `tools/data/clients.json`, no edit of `tools/perf_baseline.txt`, no
   higher tolerance, unless the issue asks for it or the owner approves it in the
   pull request; when one is justified, the commit message says why.
3. **Generated blocks** (`BEGIN gen_trie` … `END gen_trie`, the tables of parameters
   and commands) come from `tools/gen_*.py`: change the generator and rerun it.
4. **English everywhere**: code, comments, documents, commits, issues.
5. **No stub intrinsics in verified files.** `Mem.cell`, `Mem.touch`, `Chan.mark`,
   `Chan.marked`, `IO.heap` and `Clock.us` have Bend bodies that are constants;
   only `src/server.bend` may call them, or the proofs are about the constant.
6. **Bend's constraints.** Define before use (except `@unsafe`), no mutual
   recursion, structural recursion (fuel otherwise), `match` on parameters only.
   `Bool.pick` evaluates both arms, and a `Nat` past 2^48 − 1 aborts the process:
   never put arithmetic that can grow that far in an arm (FINDINGS 3zc). Nested
   literal `Char` patterns blow up `--verdict`: compare with `U32.is_eq`.
7. **Performance traps** are listed in `docs/FINDINGS.md` section 7: a new call
   site can change how the compiler passes arguments to hot functions. Run
   `make perfcheck` after any change to the hot path.
8. **Redis is the reference.** Replies match Redis 7.2.16 byte for byte, unless the
   difference is listed under "Where BendKV differs" in its area of
   `docs/COMMANDS.md`.
9. **Claims follow the laws.** Do not call anything "proved" or "verified" in the
   documents unless a law in `proof/LAWS.bend` states it.
10. **Licenses.** BendKV is under the Apache License 2.0, and NOTICE lists what
    comes from elsewhere. Do not read the sources of Redis 7.4 or later, Redis 8
    included (RSALv2, SSPLv1, AGPLv3): no file of those trees, their tests and JSON
    included. Port only from Redis 7.2.x or earlier, from Valkey, or from other
    sources under a license compatible with Apache 2.0, and add their entry to
    NOTICE in the same pull request. Redis 8 is only built and run, as a yardstick
    of speed; the text of its documentation, on redis.io or in COMMAND DOCS, is not
    copied. CONTRIBUTING.md (License) has the details.

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
  `docs/COMMANDS.md` when behavior changes (and README's table of areas when an
  area or a command is added), `tests/README.md` for a new test. Put a number in one
  document and link to it from the others rather than copying it.

## Merging

While BendKV is pre-release, several sessions work on it at once.

- **Who merges.** A pull request merges into `main` once CI has passed on its head
  and nothing in it waits for the owner (below). Its author merges it. For now,
  at the owner's word, the sessions do not wait for each other's reviews; a
  session may still ask another for one. All sessions post from the owner's
  account, so GitHub's own approval is not available.
- **CI's two tiers.** The light tier (the generated blocks, the proofs, the pure
  checks, the build and `make perfcheck`) runs on every push; "CI ok" sums it up.
  The heavy tier (`make test`, the client suites and the sanitizers) runs only by
  hand: start the CI workflow on the pull request's branch (GitHub's "Run
  workflow", or the GitHub tools' `run_workflow` with `ci.yml` and the branch as
  its ref). It tests the branch merged with `main` as `main` is then, and sets the
  commit status "CI heavy" on the branch's head. A pull request merges once "CI ok"
  is green and "CI heavy" is success on its head; a push sets "CI heavy" back to
  pending, and a pull request of documents alone needs no heavy run. Run it when
  the branch is ready, not on every push. There is no need to merge `main` into a
  branch to test it: merge `main` when the branch conflicts with it.
- **When the owner decides.** Some pull requests merge only once the owner has
  approved them. That is a pull request that does any of these:
  - adds, removes or changes the statement of a law, or changes what
    `proof/SPEC.bend` means (rule 1);
  - skips or loosens a test, adds an entry to `tools/data/clients.json`, edits
    `tools/perf_baseline.txt` or raises a tolerance (rule 2);
  - adds or changes a patch in `bend-patches/`, which is part of the trusted base;
  - changes this file, or what CI runs (`.github/workflows/`).

  Such a pull request describes that change in a section of its own: for a law,
  its old and new statement; for the baseline, the old and new counts. Its author
  also asks the owner in the session's own conversation. The owner approves in the
  pull request, or in that conversation; then the author records the approval in
  the pull request, in the owner's words, before merging. If you are not sure
  whether a change is one of these, ask the owner.
