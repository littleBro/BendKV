# Directions: verified databases, compilers and parallelism

This note looks past BendKV's current state ([FINDINGS.md](FINDINGS.md)) at six
questions: is there prior work on verified relational databases; what other
languages do well that Bend could learn from; whether hints in the code would help
the C compiler; whether Bend should emit LLVM IR itself; how far the compiler and the
toolchain could be verified; and what Bend's purity and proofs make possible for
parallelism. It ends with the direction we chose. Works are cited by name and venue;
the links are at the end.

## 1. Formally verified relational databases

No production relational database is formally verified. There are research
prototypes of whole systems, verified layers, and design-level verification of
production systems.

**Whole systems, as prototypes.**
- Malecha, Morrisett, Shinnar and Wisnesky, *Toward a Verified Relational Database
  Management System* (POPL 2010): an in-memory relational database in Coq with Ynot.
  The specification of the relational algebra, its implementation on B+-trees, and a
  set of query optimizations are proved correct, the optimizations both for meaning
  and for cost. The SQL subset is small. It is the closest thing to a "verified
  SQLite".
- Fiat2 (MIT): a Python-like language for data-intensive programs with Coq proofs of
  rewrite-based query optimizations: filters, joins, projections, join reordering.

**SQL semantics and optimizers.**
- DataCert (Benzaken, Contejean and others): a Coq semantics of realistic SQL, with
  nulls and aggregates, reconciled with bag relational algebra; and a Coq
  formalization of the physical layer of SQL execution engines (iterators, physical
  plans).
- HoTTSQL and Cosette (PLDI 2017, CIDR 2017), SQLSolver (SIGMOD 2024), VeriEQL
  (OOPSLA 2024): proving or refuting that two queries are equivalent, that is,
  checking an optimizer's rewrite rules.
- DBSP (VLDB 2023, the theory behind Feldera): incremental view maintenance for rich
  query languages, formalized in Lean.

**Storage without SQL.** VeriBetrKV (Dafny, a Bε-tree key-value store), IronKV
(Dafny), Perennial with GoJournal and DaisyNFS (Coq, crash safety and concurrency),
FSCQ (a Coq file system), verified B+-trees in Isabelle (Mündler and Nipkow).

**Existing databases** are verified at the level of designs and protocols, not code:
- TLA+ and P at AWS (DynamoDB, S3), MongoDB (replication, with traces checked against
  the model), CockroachDB (parallel commits), Azure Cosmos DB (consistency levels).
- Amazon S3's ShardStore is checked with "lightweight formal methods" (SOSP 2021): an
  executable specification and property-based tests of the Rust code against it.
- SQLite relies on 100% MC/DC branch coverage and fuzzing. SQLancer (OSDI 2020 and
  later papers) found hundreds of logic bugs in SQLite, PostgreSQL and MySQL by
  testing query results against each other. For existing engines, testing is far
  ahead of proof.

So proofs about the code of a real SQL engine are an open niche. A path for Bend, in
order: a verified B+-tree in memory, then a small relational-algebra engine with laws
for its optimizer (as `demos/proof_typed_eval` in Bend does for an evaluator), and
only then the disk. Bend's advantage over the Coq prototypes is that the same
definitions run fast, as BendKV shows.

## 2. What other languages do well

Half of our compiler patches already exist in **Lean 4 and Koka**, functional
languages that also compile to C and count references:
- *Counting Immutable Beans* (Ullrich and de Moura, IFL 2019): borrowed parameters
  (our third patch) and reset/reuse, which rebuilds a dead node in place (our fifth).
- *Perceus* (Reinking, Xie, de Moura and Leijen, PLDI 2021): precise reference
  counting with drop specialization and reuse analysis.
- *FP²: Fully in-Place Functional Programming* (Lorenzen, Leijen and Swierstra,
  ICFP 2023): a discipline that *guarantees* a function runs without allocating. In
  Bend such a guarantee would be a theorem rather than a hope about the optimizer.
- Tail recursion modulo cons (Koka; OCaml since 4.14): a recursive call under a
  constructor becomes a loop. BendKV encodes its replies from a reversed list to work
  around its absence.
- Lean 4's `String` is a list of characters in the theory and a UTF-8 byte array in
  the runtime, exactly what the packed-strings patch does for Bend.

**Erlang and the BEAM** are almost a blueprint for a server:
- Binaries over 64 bytes live outside the process heap with a reference count, and
  sub-binaries point into them: our one-chunk strings and string views.
- The compiler parses a binary without building intermediate sub-binaries (the match
  context optimization), which is what BendKV's parser does by index.
- An *iolist* reply is a tree of chunks handed to `writev` without concatenation.
  We tried it ([FINDINGS.md](FINDINGS.md), section 3b), and it lost 15–30% with
  pipelining: in Bend's heap a piece is a list cell and a string, which costs more
  than copying a short value, and since the writer thread cannot hold values of the
  loop's heap, the pieces are glued into one buffer anyway. Erlang's iolists pay
  because its large binaries are reference-counted outside the process heap, where
  any thread may read them.
- Every process has its own heap and collector and nothing is shared. Sharding BendKV
  across cores would look the same.

**Go:**
- PGO turns on by itself when a `default.pgo` profile sits next to the main package;
  Go reports 2–7% on typical programs, mostly from inlining hot calls and
  devirtualizing, as we saw with clang. This is a ready model for Bend's driver;
  BendKV's `make pgo` gets 1–4% (FINDINGS.md, section 3b).
- The network poller is part of the scheduler, on epoll. Bend's runtime used `select`
  until patch 11; with epoll, GET without pipelining went from 1.15 to 1.27 of Redis.
- Escape analysis puts values that do not escape on the stack.

**Rust:** affine types instead of reference counts for unique values; `noalias` on
references, which LLVM's optimizer uses; `#[cold]` and `#[inline]`. rustc itself is
built with PGO.

**Zig:** `comptime` (the 16-way trie code that a Python script writes would be
ordinary code); arena allocators that free a whole request at once instead
of counting; built-in `@prefetch` and `@branchHint`.

**GHC:** strictness analysis with the worker/wrapper split (unboxed arguments),
fusion (no intermediate lists), and user rewrite rules (`RULES`). GHC trusts its
rules; in Bend they could be proved laws, which the compiler could then apply safely.

**Database engines.** HyPer and Umbra generate machine code from query plans.
*Asynchronous Memory Access Chaining* (VLDB 2015) and *Interleaving with Coroutines*
(VLDB 2017) interleave independent index lookups: issue a prefetch, switch to another
lookup, come back when the line has arrived. That is the technique behind the
direction we chose (section 7).

## 3. Would hints in the code help the C compiler?

Measured on BendKV ([FINDINGS.md](FINDINGS.md), section 5), mostly no, with one
exception.
- **Inlining.** Forcing every helper inline cuts 16% of the instructions and gains no
  time; the code grows 1.6 times. Targeted inlining needs to know the hot call sites,
  which is what a profile is for.
- **`cold`** on error paths and on the slow `*_far` fallbacks. Bend's compiler knows
  these statically (fail-stop branches, fallbacks for strings of many chunks), so it
  could mark them itself. This is part of what PGO does when it moves cold code out of
  the way. Our estimate is 1–3%, below the ±5% layout noise of a single series.
- **`likely` and `unlikely`.** The processor learns branches at run time; a static
  hint only changes code layout, the same thing `cold` does.
- **`restrict` and aliasing.** Little to gain: the generated code already keeps a
  node's fields in locals.
- **`__builtin_prefetch`** is the one hint with a large potential, since 56–68% of
  user time is spent waiting for memory. It needs the code restructured: a prefetch
  right before the load is useless; it has to be issued a few lookups ahead.

The sensible form is not hand-written C attributes but annotations in Bend (`cold`,
`inline`) plus inference in the compiler. Separately, `#line` directives in the
generated C would make profilers and debuggers show Bend source lines instead of C.
That is cheap and useful.

## 4. Should Bend emit LLVM IR itself?

That is an LLVM front end: Bend would produce LLVM IR, and LLVM would optimize it and
generate machine code.
- **Effort: moderate.** Textual IR can be printed from TypeScript. The standard trick
  for SSA is to put every variable in an `alloca` and let LLVM's `mem2reg` build SSA.
  The runtime (heap, natives, IO) stays in C, is compiled to bitcode and linked with
  the program. Rewriting the emitter of `comp.ts` is a few thousand lines and a lot of
  testing.
- **What IR can say that C cannot:**
  - `!invariant.load`: a field of an immutable term never changes, so its load can
    be hoisted and shared.
  - `noalias` and `alias.scope`: two different nodes never overlap.
  - `!range` on tags, and branch weights.
  - Calling conventions such as `ghccc` or `tailcc` without depending on clang 19's
    `preserve_none`.
  - Debug information pointing at Bend source.
- **What it would cost:** simplicity and portability. Bend also has CUDA and Metal
  back ends, and Metal's IR is Apple's closed format built on LLVM. Textual IR also
  changes between LLVM versions.
- **What others found:** GHC's LLVM back end (`-fllvm`) wins mainly on numeric loops.
  Lean 4 and Koka still compile through C; an MLIR back end for Lean was a research
  project (*Lambda the Ultimate SSA*, CGO 2022) and did not become the default.

Our estimate is 5–15% fewer instructions from the metadata. That is less than what
changing data representations bought (packed strings, one-chunk strings, nodes
rebuilt in place). As a project it is interesting; for performance now it does not
pay. It would make sense together with an MLIR dialect for Bend, where
reference-count and reuse optimizations live, or for a verified pipeline through
Vellvm (next section).

## 5. Verifying the compiler: how far can "verified Bend" go?

**What exists.**
- **CompCert** (Leroy): a C compiler proved in Coq to preserve the semantics of the
  source down to assembly. Csmith (PLDI 2011) found hundreds of bugs in GCC and LLVM
  and no wrong-code bug in CompCert's verified middle end.
- **CakeML:** a verified compiler for an ML dialect down to machine code, with a
  verified garbage collector, bootstrapped in itself. It has run on the verified
  processor Silver (PLDI 2019), so a stack verified "down to instructions" exists,
  for a simple processor.
- **CertiCoq:** compiles Coq's Gallina to Clight, which CompCert compiles further. It
  is the nearest model for a verified Bend.
- **LLVM is not verified.** Vellvm gives LLVM IR a formal semantics in Coq and proves
  some passes; Alive2 (PLDI 2021) checks LLVM's rewrites with an SMT solver, has found
  dozens of bugs and is part of LLVM development.
- **seL4** proved its *binary* refines its C code by translation validation (PLDI
  2013), so GCC did not have to be trusted.

**Where BendKV stands.** The proofs are trustworthy: Bend's checker, and
independently the BendTT kernel proved sound in Lean, check them. The compiled code is
not: the trusted base is the Bend compiler (TypeScript, unaudited), its C runtime
including our patches, clang, the OS and the hardware.

**A realistic path,** by increasing cost:
1. Prove that the native string operations refine the list theory: about 1–2
   thousand lines of C, with VST or Frama-C. This is the layer that most deserves
   suspicion, since it is where our patches replaced the theory's representation.
2. Formalize the runtime model in Lean (reference counts, borrowing, rebuilding in
   place) and prove each optimization on it separately, as the Perceus papers do.
3. Check each compilation instead of the compiler: a small verified checker
   validates that the generated code matches the source. This fits a compiler that AI
   writes: the optimizations can come quickly, and trust comes from the checker.
4. "Down to instructions": compile a subset of Bend through CompCert (losing
   `musttail` and `preserve_none`, so slower), or translate Bend to CakeML.

A fully verified Bend is possible in principle, and the precedents exist. It is years
of work, and the result would likely not be fast.

## 6. Bend and safe parallelism

Pure code has no data races by construction, and a parallel evaluation gives the same
result as a sequential one. Proofs about the sequential semantics therefore carry
over to parallel execution, as long as the runtime is correct. This much is classic
(NESL, Futhark, Haskell's strategies, MaPLe). What Bend adds is laws that *permit
optimizations*. What is "risky" in C becomes a theorem:
- **Reordering and batching.** A law that commands on different keys commute lets a
  batch run out of order: grouped, prefetched, or spread across cores (done for
  adjacent swaps in a batch, [FINDINGS.md](FINDINGS.md), section 3d).
- **Sharding across cores,** with laws that the shards hold the map pointwise by
  `hash(k)`: a multi-threaded server proved equivalent to the single-threaded one
  (done for all commands, then taken out again because it did not pay for its cost;
  section 7). Each shard owned its event loop; a heap of its own, as BEAM processes
  have, would also keep terms from crossing cores.
- **Snapshots for free.** The trie is persistent, so an old root is a consistent
  snapshot. That gives BGSAVE without `fork()` (done, [FINDINGS.md](FINDINGS.md),
  section 3zzzk), rollback for MULTI/EXEC, and readers on other threads without locks.
  Nodes shared across threads need atomic reference counts; Lean marks such objects
  and keeps plain counts for the rest.
- **Interleaving in the runtime.** Bend's runtime already runs code as segments with
  explicit continuations, which are coroutines in all but name. At a load that will
  probably miss, the runtime could issue a prefetch and switch to another pure task.
  This is hyperthreading in software, and it is safe precisely because the tasks are
  pure.
- **Speculation and replay.** A pure task can be abandoned or run twice with no
  effect, and a deterministic core can be replayed exactly when testing.

The limits: input and output stay sequential per connection, atomic reference counts
on shared nodes cost more than plain ones, and the runtime's scheduler and atomics
are part of the trusted base.

## 7. The direction we chose

Where performance and proof meet: **batched execution under proved laws.**
1. **Done: batch hints.** A pure prefetch operation in Bend, `Mem.prefetch(A, x, k)`
   (patch 9: its value is `k`; in C it also runs `__builtin_prefetch` on `x`'s heap
   node), and a pass in BendKV ([`batch.bend`](../src/batch.bend)) that, before a pipeline
   batch runs, walks the trie paths of all its keys level by level and prefetches the
   next node of each. A proved law, `batch_hints`, says the batch then gives exactly
   `exec_all`'s replies and database, whatever the hints. Result: 1.54, 1.67 and 1.58
   times the previous throughput on GET, SET and INCR at 100 thousand keys, and 1.62,
   1.82 and 1.45 times Redis's; about 85% of the memory waits are hidden there
   ([FINDINGS.md](FINDINGS.md), section 4). Valkey 8 does the same for batches of up
   to 16 commands and reports almost 50%.
2. **Done: laws that commands on different keys commute** ([FINDINGS.md](FINDINGS.md),
   section 3d): two adjacent commands of a batch that do not interfere may trade
   places, so a batch can be reordered by such swaps. Not yet used by the server.
3. Interleaving of pure tasks in the runtime at likely misses, so programs get
   memory-level parallelism without batching by hand.
4. **Done: sharding across cores** (patch 10, [FINDINGS.md](FINDINGS.md), section 3a).
   Event loops on threads of their own, shards by the trie's root digit, and batches
   handed to all shards in one atomic step, so the shards run them in one order, as one
   actor would. It is correct under every test, including concurrent clients, but on
   two cores it loses to one loop with a writer thread: terms crossing cores cost more
   than the parallel map work saves. Two proved laws, `shard_replies` and
   `shard_holds`, say that after any history of batches from the start the sharded
   server answers as the single one, and that its shards hold the database pointwise.
   Both are proved for batches of every command; DBSIZE, KEYS and FLUSHALL, which read
   or clear the whole database, came last, as a command for each digit of the trie's
   root ([FINDINGS.md](FINDINGS.md), section 3c). The shards answer in bytes,
   which lifted two shards by a third, and the loops wait on epoll (patch 11); passing
   requests as bytes too did not pay ([FINDINGS.md](FINDINGS.md), section 3b). On
   three server cores one loop with a writer still leads with pipelining. **Taken out
   again** ([FINDINGS.md](FINDINGS.md), section 3l): the shards paid only without
   pipelining and with a journal, and cost two source files and two fifths of the
   proofs. They are kept on the branch
   [`archive/shards`](https://github.com/littleBro/BendKV/tree/archive/shards), to come back once BendKV does
   what a drop-in Redis must.

5. **Done: persistence with recovery proved** ([FINDINGS.md](FINDINGS.md), section
   3e). An append-only file in Redis's own format, written with group commit, and nine
   laws: logging changes no reply, nor do the hints before it, a batch's effects
   replay to its database, they
   parse back to themselves, a file loads as the entries written to it, after any
   history the restored databases are the ones the server held, a file cut by a
   crash at any byte restores the databases after some prefix of the acts, the
   server cutting off exactly the part of an entry the crash left, and the start's
   replay, which refuses a file with an entry it cannot replay as written, is that
   replay whenever it refuses none. (With the shards,
   each shard logged to a file of its own, with three more laws; section 3g.) The
   rewrite of the log from a snapshot (BGREWRITEAOF) is done and tested against Redis
   (section 3zv): the persistent trie made the snapshot free, a root is one. Not yet
   proved: that the rewritten file replays to the databases it was written from, a law
   about what keys read, not the trie's shape, which needs a scan from the first bucket
   to read every key once (with the invariant that a bucket holds a key once, proved
   now: [FINDINGS.md](FINDINGS.md), section 3zzf) and a double
   written as `%.17g` to read back as itself; and that a file cut back and written on
   is the log of the prefix and the new batches. The file format is the requests
   clients send, so the same kind of law would cover the network parser of `resp.bend`,
   and with it the server's decision to cut a file (`cut_short`). Nor is it proved yet
   that the start's check accepts every file the server writes (the tests show it on
   theirs).
6. **Next: a drop-in Redis for one node.** Strings, hashes, lists, sets and sorted sets
   with WRONGTYPE (a value of a type, with WRONGTYPE: done, section 3zf; hashes: done,
   section 3zg; lists: done, section 3zh; sets: done, section 3zj; floats in software
   and INCRBYFLOAT: done, section 3zk; sorted sets: done, section 3zl; the blocking
   commands of lists and sorted sets: done, section 3zp),
   times to live with time in the state and a sweep of expired keys
   (done; FINDINGS.md, sections 3v and 3w), several databases with SELECT, MOVE and
   SWAPDB (done; section 3x), the ranges and bits of strings (GETRANGE, SETRANGE,
   GETBIT, SETBIT, BITCOUNT, BITPOS; done, section 3y), MSETNX and RENAME (done,
   section 3za), COPY (done, section 3zb), BITOP and LCS (done, section 3zd), BITFIELD
   (done, section 3ze), MULTI/EXEC/WATCH (done, section 3zq), pub/sub and keyspace
   notifications (done, section 3zr), the connection commands clients send on connect
   (HELLO, SELECT, CLIENT, AUTH, INFO, COMMAND, CONFIG; done), CLIENT LIST, INFO and KILL
   (done, section 3zs), SCAN and RANDOMKEY (done), MONITOR (done, section 3zt), the
   log's rewrite (done, section 3zv), maxmemory and its eviction (done, section 3zw),
   RESP3 (done, section 3zx), SORT and SORT_RO (done, section 3zzh), HyperLogLogs (done,
   section 3zzj), CLIENT PAUSE and UNPAUSE (done, section 3zzk), the administrative
   commands LASTSAVE, ROLE, WAIT, SHUTDOWN, MEMORY and LOLWUT (done, section 3zzl),
   GEO (done, section 3zzm), DUMP and RESTORE (done, section 3zzu), the slow log and
   the latency monitor (done, section 3zzz), the RDB file with SAVE, the saves of
   SHUTDOWN and FLUSHALL and its load at the start (done, section 3zzzc), CLIENT TRACKING
   (done, section 3zzzb), ACL users (done, section 3zzzh), BGSAVE and the save points
   (done, section 3zzzk), Lua scripts on Redis's own Lua (done, section 3zzzd), and Lua's
   functions, FUNCTION and FCALL, on the same engine (done, section 3zzzp), measured by
   Redis's own test suite run against BendKV and by client libraries' test suites
   (redis-py's and go-redis's, in CI: done, section 3zy).
   Streams are done but for the size of their nodes, which no parameter sets: a stream
   is a value BendKV holds (section 3zzzu), its reads, its writes and the commands of its
   groups answer as Redis's (sections 3zzzy, 3zzzza and 3zzzzt), and XREAD and
   XREADGROUP wait as Redis's do (section 3zzzzu). Cluster, replication and modules are
   out of scope. The suite's count: of the 1,812 tests Redis 7.2.16 passes against a
   server it did not start, BendKV passes 1,741, 1,644 of the 1,688 in what it has
   ([COMPATIBILITY.md](COMPATIBILITY.md)); most of the other 44 need replication's SYNC
   (26) or run after a test that left its client in MULTI with a command BendKV does not
   have (7).
   What maxmemory left to do (section 3zw): a delete takes the nodes it empties now
   (section 3zz), so the eviction gets within a limit with the keys Redis keeps, but its
   samples still walk the trie's empty buckets, and an eviction takes six times Redis's
   time (ten before the reads of section 3zzc); a pick that goes down the trie by counts
   would end that, for RANDOMKEY and SRANDMEMBER too. The compiler no longer copies the
   nodes a walk of a tree reads when the walk's caller owns the tree and the keyspace
   shares it (Bend patch 31, section 3zza): KEYS, SCAN, RANDOMKEY and the ranges of a
   sorted set borrow their trees now, and so do the reads of a key's entry (section
   3zzc), so a read of a collection costs a GET and the read. HSET, and SADD of a member
   new to a set, take their collection out of the keyspace and change it in place
   (sections 3zzd, 3zze, 3zzy), and so do ZADD and ZINCRBY whose first pair changes a
   large sorted set for sure, its tree too (section 3zzza: 15 to 29% fewer
   instructions); ZREM, the ZPOPs and the ZREMRANGEBYs still copy their paths. An
   intset is a tree of its members compared as integers (section 3zzy):
   its SADD, SISMEMBER and SREM take 1.7, 1.3 and 1.1 times a hashtable's instructions,
   where a list of them took twenty times, and a round trip as Redis's do; a member takes
   34 bytes of the heap, where Redis's array of integers takes 2 to 8. SORT of 1,000
   elements costs two to six times Redis's
   instructions (section 3zzh): each step of the merge sort shares and drops its runs'
   cells; a weight that is not an integer is read by strtod in software (Clinger's fast
   path, one rounding for up to 15 digits and a power of ten up to 22, would read most of
   them at once, and every other reader of doubles with them); SORT with STORE sorts
   twice, once for the session's reply and once for its act's write. The keys its
   patterns name are read as MGET reads its keys, each now for less than a whole GET:
   the walk behind `KV.read` copied each node on a key's path until ZRANGESTORE lent it
   the keyspace (section 3zzi). A PFADD costs four to six times Redis's instructions, and
   a PFCOUNT that counts one HyperLogLog 13 times (section 3zzj): the estimate runs on
   doubles in software, about half a million instructions (the runtime's doubles of Bend
   patch 33, section 3zzm, would end it), a step of a walk of the sparse opcodes takes 80 instructions where Redis's
   takes about 20, and a sparse value past 2,048 bytes is two chunks, which
   `String.code_at` reads a run at a time. LOLWUT VERSION 5 rounds each of a square's
   ninety float operations in software (section 3zzl): a drawing of 10,000 squares takes
   2 s where Redis takes 19 ms, the server answering nothing else meanwhile; the
   runtime's doubles would make each one operation of C's. GEO runs on them (section
   3zzm): a search takes 2.5 to 4 times Redis's time, 7 times with WITHCOORD, whose
   coordinates are `%.17Lf` of long doubles written in software, and 13 times with
   COUNT's partial sort, Redis's pqsort made a comparison and a swap at a time on a vector
   that is a tree; a GEOADD of 20,000 points takes 9 times, as a ZADD of their scores does
   (PERFORMANCE.md, section 60). A request of tens of thousands of arguments takes 7 to 11
   times Redis's time, its parse linear since section 3zzn. DUMP and RESTORE of a value of
   100,000 elements take 3 to 38 times Redis's time, and less than the commands that make
   the value (section 3zzu): Redis copies and checks the listpacks it holds where BendKV
   writes and reads each element; the checksum walks a payload a character at a time,
   two steps of four bits a byte, a sorted set's tree is made one insertion at a time,
   each copying a path and dropping the old one, and the read of a request of a large
   value counts its pieces' bytes one at a time (PERFORMANCE.md, section 62). The timing
   of calls costs a request without a pipeline 13% more instructions (section 3zzz): a
   window's check and update take about 1,300 (PERFORMANCE.md, section 64). CLIENT
   TRACKING leaves the batches on keys no client tracks the fast way (section 3zzzb); a
   tracking client's own commands, and every batch while a client is in BCAST mode, run
   the general way, a command at a time (PERFORMANCE.md, section 66). ACL users cost
   nothing while no client's user is restricted (section 3zzzh); while one is, its
   batches run the general way, each call checked against its user's selectors, and the
   client of each other batch is looked up by its id in a trie of the restricted
   (PERFORMANCE.md, section 70). A stream's groups take 5 to 9 times Redis's time to
   read and claim (sections 3zzzzt and 3zzzzv): the walks read a node's entries in
   place, about 500 instructions an entry they pass where Redis takes 550, and go down
   from a node's newest entry when their start is nearer it, but a group's write still
   walks its stream about twice as often as Redis's, and on a stream the keyspace holds
   it copies the group and drops the old stream; a stream taken out of the keyspace for
   its groups' writes, as HSET's hash is, is next (PERFORMANCE.md, section 89). Next
   within the scope: the query buffer's limits.

After that comes proving the native strings (section 5, step 1): a small piece of
work that makes the word "verified" much stronger.

## References

- [Malecha et al., Toward a Verified Relational Database Management System, POPL 2010](https://doi.org/10.1145/1706299.1706329)
- [Benzaken et al., A Coq formalisation of SQL's execution engines](https://hal.archives-ouvertes.fr/hal-01716048)
- [DataCert project](https://usr.lmf.cnrs.fr/datacert/roadmap.html)
- [Fiat2, MIT](https://dspace.mit.edu/handle/1721.1/163042)
- [DBSP: Automatic Incremental View Maintenance for Rich Query Languages](https://arxiv.org/pdf/2203.16684)
- [Valkey: Unlock 1 Million RPS, part 2 (memory access amortization)](https://valkey.io/blog/unlock-one-million-rps-part2/)
- [Go 1.21 release: profile-guided optimization](https://go.dev/blog/go1.21)
- [Lambda the Ultimate SSA: Optimizing Functional Programs in SSA (Lean, MLIR)](https://arxiv.org/pdf/2201.07272)
