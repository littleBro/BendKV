# Bend2, after BendKV: a review

What building BendKV says about Bend2: how it is to write in, how well the language is
made, whether it suits coding agents, and what we would change. It was written in October
2026, at main 3da6f0d, by the Claude Code session that wrote most of BendKV's features
and of its patches to the Bend compiler. The numbers are those of that commit; the
documents linked keep the current ones.

## In short

The idea is strong and the implementation is still raw. The project's main finding
holds: what made BendKV slow was never the proofs, it was how Bend's runtime represents
data.

- **Stock Bend was slow for a server.** On it, BendKV served 0.08 to 0.14 of Redis's
  rate, and a single SET cost about 390 heap allocations and 150 atomic operations on
  reference counts ([PERFORMANCE.md](PERFORMANCE.md), "In short").
- **39 patches to the compiler and its runtime closed the gap on strings.** Strings run
  1.11 to 1.47 times as fast as Redis 8.10.2 on one core with a pipeline
  ([PERFORMANCE.md](PERFORMANCE.md), section 94). But 39 patches are in effect a fork of
  Bend ([bend-patches/README.md](../bend-patches/README.md)).
- **Collections and streams are still behind,** at 0.38 to 0.86 of Redis 8.10.2 with a
  pipeline, and 0.12 on XADD.

## Writing in it

Hard in places, but predictable.

### What gets in the way

- **The surface of the language.** There is no `match` on a computed value, so every
  branch becomes a helper function. A function must be defined above its callers, there
  is no mutual recursion, and recursion is structural, so the parser counts its steps
  with fuel ([FINDINGS.md](FINDINGS.md), section 8).
- **Strict evaluation where one does not expect it.** `Bool.or` evaluates both sides.
  A pattern like `a*a*…a*b` made the old KEYS try every split of a key and hang the
  server for minutes; Redis's own test suite found it.
- **Numbers.** The checker counts `Nat` in unary, so a constant of 10^14 overflows its
  stack, and a `Nat` past 2^48 − 1 aborts the process. Stock Bend has no 64-bit
  integers.
- **A cost model one cannot see.**
  - One accessor that returned a field of a parameter made the server's state be taken
    apart and kept field by field on every batch.
  - One field two words wide, in one command, made every GET 27 instructions dearer,
    since the widest variant of a type sets the width of all its values.

  Such costs show only in the generated C and in callgrind's counts.
- **Proofs without tactics.** Each rewrite is written by hand, with its motive. In a
  proof, `case other` does not refine the goal, so the lemmas list every constructor of
  `Cmd`. `proof/PROOF.bend` is as long as the code it proves.

### What helps

- **The code that runs is the code that is proved.** There is no separate model, and no
  proof that the code refines it.
- **Checking is fast:** about 15 s for every law, and about two minutes to check them
  again in the BendTT kernel, whose soundness is proved in Lean.
- **The theory and the runtime representation are apart.** Strings became byte buffers
  in the runtime without one proof being touched.
- **The C backend is readable,** so each idea for the runtime became a patch and a
  measurement.

## Is the language well made?

The design is good: dependent types, proofs erased when the code is compiled, and the
lineage of HVM. The implementation is a research prototype.

- **The compiler.** By its own README it is 99% written by AI and not audited.
- **The translation to the kernel.** Bugs have been reported in which `--verdict` passes
  while the kernel checked something other than the source says (bendlang/bend
  [#1186](https://github.com/bendlang/bend/issues/1186),
  [#1236](https://github.com/bendlang/bend/issues/1236),
  [#1247](https://github.com/bendlang/bend/issues/1247)). So the translation stays in the
  trusted base.
- **The runtime lacked the standard optimizations of functional compilers.** Most of our
  patches rediscover known techniques ([FINDINGS.md](FINDINGS.md), section 9):
  - strings as byte arrays, as Lean 4 has them;
  - borrowed parameters and reuse in place, as Lean 4 and Koka's Perceus do;
  - small strings kept inside the term.

## Is it a good tool for agents?

Yes, with corrections.

### What held

- **The laws are a contract.** A person approves `proof/LAWS.bend`, and the agents write
  the code and its proofs. No person needs to read the proofs: the checker does. So the
  surface a person reviews shrinks to the specification. This is the main gain for
  agents.
- **The proofs guard refactoring.** Optimizations such as updates in place and borrowed
  reads keep the behavior, and the checker says so.
- **The feedback is fast and strict,** which matters to an agent more than anything else.

### What needs a correction

- **The tests, not the proofs, made BendKV compatible.** BendKV passes 1,769 of the 1,812
  tests of Redis 7.2.16's own suite that Redis passes against a server it did not start
  ([COMPATIBILITY.md](COMPATIBILITY.md)). That came from differential tests against a
  real `redis-server`, and from that suite.
- **The laws cover only part of the server.** They state:
  - the semantics of the string and key commands;
  - properties of every command: keys kept apart, batches run as their commands, commands
    on different keys commuting;
  - the append-only file, a file cut at any byte included.

  The rest, `src/server.bend` included, is tested only.
- **The weak point is the trusted base.** That is the compiler and the translation to the
  kernel, which nothing proves.
- **Against other tools.** For a verified store meant for production, Lean 4, or Rust
  with Verus, would be the choice today: tactics, mature compilers, and costs one can
  predict. Bend's strength is a single artifact that runs and is proved. Its runtime in
  the spirit of HVM, made for parallelism, BendKV did not use: sharding was built, proved
  and taken out, since it did not pay ([FINDINGS.md](FINDINGS.md), section 3l).

## What we would change

### In Bend

1. **Take the speed patches upstream:**
   - packed strings, borrowed reads, updates in place and small strings in the term;
   - `Mem.prefetch` with its batch hints.

   They are general, and taking them upstream shrinks the fork.
2. **Check the translation:** that the kernel receives what the source says.
3. **Lighten the proofs:**
   - let `case other` refine the goal;
   - add a little automation;
   - let hypotheses be used more than once.
4. **Add numbers a database needs:** native U64 and I64, and `Nat` in binary in the
   checker.
5. **Show the costs:** diagnostics such as "this call copies x", in place of callgrind.

### In BendKV

1. **Differential tests against Redis from the first day.** They found the most bugs.
2. **Fewer early optimizations that were later taken out:** the shards and the key hashed
   once.
3. **Mutable structures in place for collections and streams,** such as listpacks kept as
   byte buffers. BendKV runs 4.7 times Redis 8.10.2's instructions on ZADD and 7.6 times
   on XADD ([PERFORMANCE.md](PERFORMANCE.md), section 94), and Bend's pure data model makes
   this hard.
4. **Parsing and encoding outside the actor,** as Valkey's I/O threads do. One actor runs
   every command, so on three cores with a pipeline BendKV serves about a quarter less
   than Redis and Valkey do with three I/O threads.

## What next

1. **Bring BendKV to a release:**
   - the open issues;
   - the speed of collections;
   - replication, if it comes into scope.
2. **Write the study up.** FINDINGS and PERFORMANCE hold rare data on agents building a
   verified system: patches to the compiler, laws, and a measurement of each step.
3. **Not a relational database yet.** A verified SQL database, with its planner,
   isolation and recovery, is a very large step, and Bend's present limits make it
   heavier. A natural step between is a verified storage engine, such as a B-tree or an
   LSM tree with recovery after a crash proved. VeriBetrKV (Dafny) and FSCQ (Coq) took
   that road. If the work on Bend itself is worth most, taking the patches upstream comes
   first.

## References

- Hance, Lattuada, Hawblitzel, Howell, Johnson and Parno: *Storage Systems are Distributed
  Systems (So Verify Them That Way!)*, OSDI 2020 (VeriBetrKV).
- Chen, Ziegler, Chajed, Chlipala, Kaashoek and Zeldovich: *Using Crash Hoare Logic for
  Certifying the FSCQ File System*, SOSP 2015.
- Ullrich and de Moura: *Counting Immutable Beans: Reference Counting Optimized for Purely
  Functional Programming*, IFL 2019 (Lean 4).
- Reinking, Xie, de Moura and Leijen: *Perceus: Garbage Free Reference Counting with
  Reuse*, PLDI 2021 (Koka).
- Lattuada, Hance, Cho, Brun, Subasinghe, Zhou, Howell, Parno and Hawblitzel: *Verus:
  Verifying Rust Programs using Linear Ghost Types*, OOPSLA 2023.
