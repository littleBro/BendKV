# BendKV: what we found

BendKV is a Redis-compatible key-value store written in Bend2, with its core proved
against 41 laws. This file sums up in English what building it and making it fast
showed us. The detailed record, with every table and measurement, is in Russian:
[PERFORMANCE.md](PERFORMANCE.md) (performance, section by section) and
[README.ru.md](../README.ru.md) (the project, the proofs, how to run). Where the work goes
next, and why, is in [DIRECTIONS.md](DIRECTIONS.md).

## 1. The result

**Correctness.** About 920 lines of core code (with the parsing of commands), about 500
lines of sessions (a connection's state and the server's), about 70 lines of batch
hints, about 220 lines of append-only file, about 3,200 lines of handwritten proofs, and
about 1,600 lines of 16-way case splits written by a script
([`tools/gen_trie.py`](../tools/gen_trie.py)), not counting comments and blank lines.
Bend checks the 41 laws in about a second; the BendTT kernel, whose soundness is proved
in Lean, rechecks them in about 8 s. Among them: after any history, the server restores
from its append-only file exactly the database it held, and from a file cut by a crash
at any byte, the database it held after some prefix of its commands (section 3e). On
about 266 thousand random commands the replies matched real Redis 7 byte for byte; the
versions with the 16-way trie passed about 300 thousand more, the current one about 70
thousand. Shards across cores and a key hashed once were built and proved too (sections
3a–3c, 3g, 3h), and taken out again because they paid too little for what they cost
(section 3l): 38% less code and 38% fewer lines of proof.

**Speed and memory** (Redis 7.0.15 on the same VM; pipeline depth 16, 20 clients,
filled database):

| share of Redis throughput | GET | SET | INCR |
|---|---:|---:|---:|
| original Bend | 0.08–0.14 | 0.08–0.14 | 0.08–0.14 |
| eight patches, 100k keys | 1.17–1.21 | 1.10–1.15 | 0.95–0.96 |
| eight patches, 1M keys | 1.02–1.14 | 1.06–1.24 | 1.04–1.12 |
| **with batch hints (patch 9), 100k keys** | **1.62** | **1.82** | **1.45** |
| **with batch hints, 1M keys** | **1.65** | **1.80** | **1.17** |
| with batch hints, 1k keys (all in cache) | 1.09 | 1.13 | 0.95 |

| instructions per request | GET | SET | INCR |
|---|---:|---:|---:|
| original Bend | 11,994 | 15,137 | – |
| eight patches | 3,280 | 3,985 | 4,209 |
| with batch hints | 3,834 | 4,544 | 4,785 |
| Redis 7.0.15 | 3,549 | 4,773 | 3,948 |

Ranges for the eight patches come from series on two days on different VMs; the
batch-hint rows are medians over 8–13 pairs. Those numbers come from `redis-benchmark`
with 3-byte values, which sends 16 commands per connection and waits for all 16
replies: every read the server makes is a full batch, the best case for BendKV.

**Redis's own benchmarks** ([redis-benchmarks-specification](https://github.com/redis/redis-benchmarks-specification),
run with `memtier_benchmark` by [`tools/memtier_specs.py`](../tools/memtier_specs.py):
1M keys, hundreds of connections, a new command as soon as a reply arrives), medians
of three interleaved runs, share of Redis's throughput:

| spec | eight patches | with batch hints |
|---|---:|---:|
| load 1M keys, 100-byte values, pipeline 10 | 1.03 | **1.39** |
| GET, 100-byte values, pipeline 10 | 1.26 | **1.26** |
| GET, 10-byte values, pipeline 100 | 1.07 | **1.36** |
| INCR, pipeline 10 | 1.05 | **1.00** |
| GET, 100-byte values, no pipeline | 0.90 | **0.90** |

Without pipelining both servers are bound by the kernel (~6.5 µs per request), and
BendKV's path for a single command (connection, channel, database actor, a `select`
that rebuilds its descriptor set every time) costs more user time than Redis's. Under
`redis-benchmark` without pipelining BendKV serves 1.18–1.32 of Redis's throughput.

**Two cores** (section 3a; server on two cores, `memtier` on the other two, medians of
three interleaved runs, share of single-threaded Redis's throughput):

| spec | Redis io-threads 2 | one loop | **one loop + writer thread** | two shards |
|---|---:|---:|---:|---:|
| load 1M keys, 100-byte values, pipeline 10 | 1.03 | 1.44 | **1.94** | 1.59 |
| GET, 100-byte values, pipeline 10 | 1.04 | 1.34 | **1.61** | 1.09 |
| GET, 10-byte values, pipeline 100 | 1.03 | 1.32 | **1.39** | 1.33 |
| INCR, pipeline 10 | 0.99 | 1.05 | **1.27** | 0.85 |
| GET, 100-byte values, no pipeline | 1.22 | 0.95 | 1.11 | **1.19** |

**With epoll** (section 3b; the same two cores, two runs): load 1.98–2.07 of Redis, GET
with pipeline 10 1.72–1.78, GET without pipelining 1.27 (1.15 with `select` in the same
series). On three server cores, with a one-thread load generator on the fourth, one loop
with a writer serves 897 thousand GETs a second at pipeline 10, 2.06 times Redis with
three io-threads; three shards serve 816 thousand.

**After five more steps** (section 3i, on a newer VM; two server cores, two series):
load 1.93 of Redis (1.73 before them in the same series), GET at pipeline 10 1.46
(1.43), GET without pipelining 1.37 (1.23), GET at pipeline 100 1.69 (1.35), INCR 1.43
(1.39). Under `redis-benchmark` without pipelining, one client thread over 50
connections, Redis is still faster: BendKV with its writer serves ~0.80 of it.

**After three more** (section 3j): the loop sends its own replies while it keeps up,
which closes that gap (0.93–1.05 of Redis on GET and 0.90–0.98 on SET, in three
series); requests are parsed straight into commands, and `IO` compiles to direct
continuations, together 10–14% fewer instructions per request (GET 2,969, SET 3,534,
INCR 3,830 at pipeline 16), which no longer shows in time: the kernel is now about half
of a request's CPU with a pipeline and two thirds without, as for Redis. On Redis's
specs on two server cores: load **2.25** of Redis, GET at pipeline 10 1.62, without
pipelining 1.37, at pipeline 100 **1.95**, INCR 1.39; at pipeline 16 on one core
(`redis-benchmark`) **1.86 / 1.83 / 1.54** on GET / SET / INCR.

**Memory.** About 950 thousand keys with 3-byte values take 60 MB of RSS
(63 bytes per key) against 513 MB in the original Bend and 121 MB in Redis. With
100-byte values the two are close: a million keys take 183 MB against 211 MB, and the
first GET of a value added 8 bytes to it until a GET answered a copy (sections 11 and
3k). A 1 MB value takes 4.4 ms to SET and 1.4 ms to GET (Redis: about 1 ms).

**What "verified" means here.** The Bend source is proved to satisfy the laws. The
Bend compiler (by its own README, 99% written by AI and not audited), its C runtime,
clang, the OS and the hardware are trusted. This is not end-to-end verification in
the sense of CompCert or seL4; [DIRECTIONS.md](DIRECTIONS.md), section 5, discusses
how far that could go.

## 2. Why it was slow: the runtime's memory model, not verification

The proofs cost nothing at run time. The gap came from how the Bend C runtime
represented data:
- **Reference counts everywhere.** The original SET made about 390 heap allocations
  and about 150 atomic reference-count operations; Redis makes a handful of
  allocations.
- **Strings as lists.** A `String` was a linked list with a 16-byte cell per
  character, so parsing, hashing, comparing and copying went one character at a
  time. Even with packed buffers, parsing a GET character by character took about
  5,000 instructions against about 900 in Redis.
- **Reading meant sharing.** Reading a field of a persistent structure made the
  reader an owner of the whole value: O(depth) reference-count operations per read.
- **A deep trie.** The first map was a binary trie of 20 levels: 20 dependent loads.

## 3. Twenty patches to the Bend compiler

All live in [`bend-patches/`](../bend-patches/) (against `bendlang/bend` at `1cce499`,
Bend 2.0.35). The first eight switch on by themselves for programs without GPU calls;
the ninth and tenth work where a program calls them; the eleventh changes every
program's event loop on Linux; the twelfth and thirteenth only add effects; the
fourteenth speeds up `String.code_at` everywhere; the fifteenth and sixteenth work where
a program calls `TCP.post`; the seventeenth adds string functions; the eighteenth
changes how every program's `IO` compiles; the nineteenth speeds up `Mem.prefetch` of
a buffer and `String.take` of a short string everywhere; and the twentieth adds the
process's id, working directory and wall clock (section 3o). The sections before 3l
number the patches as they were then: patch 16 was effect pairs, taken out in 3l with
`TCP.post_list` of patch 11, and their patches 17–20 are today's 16–19. None changes the
theory: `String`
is still a list of characters to the checker, a native operation is proved (or defined)
to agree with the list definition, and `IO` is still a function of `R` and `k`.

| patch | idea | what it bought |
|---|---|---|
| 1. lazy seal | create a reference count only when a value is actually shared | allocations per SET 392 → 187, per GET 305 → 153 |
| 2. packed strings | in the C runtime a `String` is a chain of byte buffers; TCP reads and writes buffers | allocations per SET → 62, per GET → 35 (with the BendKV changes); GET ×4.5 |
| 3. borrowed reads | a field read from a borrowed value stays in place (`slot_keep`) instead of taking the whole value | reads from the persistent map cost O(1) reference-count work; the hand-written `find` workaround is gone |
| 4. string natives | `++`, `length`, `eq`, `take`, `drop`, `hash`, `code_at`, `find`, `slice`, `Nat.show` run on buffers (`memcpy`, `memcmp`); strings of up to 6 bytes live inside the term word | instructions per GET 11,159 → 6,999 at first, then the parser and replies rewritten on top; GET 0.74 → 0.86 of Redis from the small strings alone |
| 5. node update | a node the function owns is rebuilt in place; across a call the node pointer is kept, not its fields | GET 0.86 → 0.96 |
| 6. huge pages | `madvise(MADV_HUGEPAGE)` on the heap | GET 0.96 → 1.02, INCR 0.74 → 0.80 |
| 7. digit select | a match whose arms each take a different field of one node becomes one indexed field access | no unpredictable indirect jump per trie level; together with INCR reading its number by index and a one-chunk `str_eq`, GET 1.02 → 1.05, INCR 0.80 → 0.87 |
| 8. string blobs | a string of one chunk is its buffer term, with no node | key comparison is one cache miss, not two; GET 1.05 → 1.21, INCR 0.87 → 0.96; 75 → 60 MB |
| 9. memory prefetch | `Mem.prefetch(A, x, k)` is `k`; on the C lane it also starts loading `x`'s node into the cache | BendKV's batch hints (section 4): ×1.54 / 1.67 / 1.58 on GET / SET / INCR at 100k keys, ×1.51 / 1.69 / 1.47 at 1M |
| 10. io loops | `IO.spawn_on` runs a computation on an event loop of its own thread; `Chan.send_all` puts values on several channels as one step; `TCP.post` hands bytes to a writer thread; recv and send keep one buffer per thread | with the writer, ×1.08–1.36 on Redis's pipelined specs and 1.61–1.94 of Redis on two cores; sharding works, but loses on two cores (section 3a) |
| 11. io epoll | `epoll` on Linux, edge-triggered for the runtime's own sockets, so a drained socket costs no `EAGAIN`; `TCP_NODELAY` on accepted sockets; `TCP.post_list` posted several strings as one buffer (taken out in 3l) | GET without pipelining 1.15 → 1.27 of Redis, 30% less kernel time per request; +14% and a third of the p99 on the load spec (section 3b) |
| 12. file raw | `File.write_raw` and `File.read_raw` carry bytes as they are (stock `File.write` writes UTF-8); `File.sync` (`fdatasync`) and `File.truncate`; `write_raw` runs on the loop's own thread, as Redis appends to its log | an append-only file at all; writing on the loop instead of a helper thread saved ~20 µs per batch (section 3e) |
| 13. chan drain | `Chan.drain` takes what a channel holds now, without waiting | group commit: one write and one `fdatasync` for every batch that waited (section 3e) |
| 14. string imm index | `String.code_at` of a string of up to six bytes that lives in the term word reads the byte from the word | INCR, which reads its number by index, 3.9% fewer instructions (section 3i) |
| 15. writer share | the event loop sends posted bytes itself while it is less busy than its writer (by its share of busy time) or while the writer sleeps; a socket's bytes stay in order | without a pipeline, on two cores, 1.15–1.20 under `redis-benchmark` (section 3i) |
| 16. effect pairs (taken out in 3l) | `Chan.call` (hand a value to an actor and wait for its answer) and `TCP.post_recv_raw` (post a reply and wait for the next request), one effect each | 17% fewer instructions per request without a pipeline (section 3i) |
| 17. writer demand | the loop sends its own replies while it keeps up with its sockets (under four ready per `epoll_wait`) and posts them to the writer once it falls behind | without a pipeline under `redis-benchmark`, GET and SET ×1.21 and ×1.26, to 0.93–1.05 and 0.90–0.98 of Redis (section 3j) |
| 18. string scan | `String.dec_line_at` (a line of digits and its `"\r\n"`: number and length in one pass), `hash_at`, `dec_at` and `digits_at` read a string where it lies; a borrowing native may return several words; `String.to_upper` of a short string a word at a time | a number line 212 → 89 instructions; with BendKV's new parser, GET 3,414 → 3,028 (section 3j) |
| 19. io cps | a def whose type ends in `IO` takes its continuation as a parameter, and its `do` blocks call effects and defs directly with a continuation that holds the rest of the block, instead of building `IO` values that `IO.bind` applies through closures | closure applications per request without a pipeline 14.5 → 7.1 (send) and 2.3 (post); 8% fewer instructions per request (section 3j) |
| 20. value reads | `Mem.prefetch` of a buffer loads its bytes to its end (four cache lines at most), not its first 64 bytes; `String.take` of a string in the term word at its whole length gives the word back | lets a GET answer a copy of the value with its bytes hinted: +1.5–2% on GET hits, memory no longer grows with reads (section 3k) |

The ratios in the last column come from different series and drift by ±0.06–0.08
between series; PERFORMANCE.md gives each one with its pairs.

**What they cost.** On the runtime's `lexer` benchmark, packed strings are 1.3 times
slower than lists on one thread and 1.7 times on four: short strings built and taken
apart character by character are their worst case. The other 16 runtime benchmarks
do not change (geometric mean ×0.99). Huge pages add about 0.4 ms to the start of a
short program and 0.4–0.9 s of kernel time to programs whose heaps reach hundreds of
megabytes. The patches grow `bend2/comp.ts` from 62,940 to 97,653 tokens, over the
repository's 64,000 cap, so upstreaming them means making them smaller first. With all
sixteen, the C lane of Bend's own test suite passes exactly the tests it passes with
thirteen, plus the three new ones; with nineteen, its C and JS lanes pass exactly the
tests they pass with eighteen, plus the new one; with twenty, the tests they pass with
nineteen plus the new one on both lanes (`io_stack_fault_trap`, which overflows a 2 GB
stack, once missed the runner's 5 s under load and passes alone in 1–6 s, as before);
with the nineteen of section 3l, exactly the tests they pass with twenty, less the six
tests of what was taken out (`chan_call`, `tcp_post_recv` and `tcp_post_list`, on both
lanes).

**BendKV's own changes.** A 16-way trie (5 levels instead of 20) whose leaves are
buckets inside the trie; laws reproved for it. Requests parsed by index, with no
shared buffer. Replies written back to front into one chunk. Commands picked by the
length of their name. INCR reading its number by index. Hints for each pipelined batch
(section 4).

## 3a. More than one core

The tenth patch gives a Bend program more than one core, and BendKV uses it two ways
(PERFORMANCE.md, section 7.16).

**Shards.** `./bendkv PORT N` cuts the database into N shards by the lowest hex digit
of a key's hash, the digit the trie's root branches on. Each shard is an actor on its
own event loop, and connections are spread over the loops. A connection cuts each
batch into a part per shard ([`shard.bend`](https://github.com/littleBro/BendKV/blob/archive/shards/shard.bend)):
- a command on one key goes whole to its key's shard;
- MGET, DEL, EXISTS and MSET go as one command per key;
- DBSIZE, KEYS and FLUSHALL went to every shard (since section 3c, as one command for
  each digit of the trie's root, to the shard that holds that digit's subtrie);
- PING, ECHO and bad commands are answered by the connection itself.

The connection hands all the parts to the shards in one step, `Chan.send_all`, under
one lock. So every shard takes the batches of all connections in the same order, and
running them is equivalent to running the batches one after another in that order, as
in deterministic databases (Calvin). No locking between shards is needed, and a batch
is atomic, even an MSET over keys of different shards. The replies are merged back in
the batch's order.

Three new tests check that the single-threaded semantics survives. `tests/shard_check.bend`
compares split and merge with one trie for 1 to 16 shards. The differential test against
Redis passes with 1, 2 and 4 shards. `tests/concurrency_test.py` checks, under many
clients, three things:
- no INCR is lost;
- an MSET over 16 keys in different shards is never seen half-done by an MGET;
- one client's writes to two shards are seen in order by another.

It passes on Redis and on BendKV with 1, 2 and 4 shards. The send_all test does catch a
non-atomic send: releasing the lock between channels breaks the order in 31 runs of 40.

**Why sharding loses on two cores.** Per-thread profiles (`tools/sprof.c` in its new
`SPROF_CPU` mode) put GET with pipeline 10 at 2,098 ns of CPU per operation with two
shards, against 1,064 with one loop. Of the difference:
- about 500 ns are cache misses: command terms, reply terms and the reference counts of
  values cross cores, and every function that touches them gets slower;
- about 190 ns are the split and merge code;
- about 140 ns are spinning for hand-overs;
- about 150 ns are the channels between loops.

System calls barely grew. More than half of a single loop's time is the kernel's (send,
recv, select: 579 of 1,064 ns). The data structure is the smaller part of the work, and
splitting it costs more than it saves. Redis's io-threads gain little on this machine
for the same reason, while burning 2–3 times the CPU. Shards pay off only without
pipelining (1.19 of Redis), where a request's latency is the limit and two loops share
the system calls of a hundred connections. To pay off with pipelining, shards would need
more cores than the kernel and the client take, and to pass bytes rather than terms
between cores.

**The second core is best spent on sending.** `send` alone is 41% of a loop's time.
With `TCP.post` the loop puts the finished reply buffer on a ring, and a writer thread
sends it on the other core: one contiguous buffer per batch crosses cores, not terms
per command. The loop runs at ~90%, the writer at ~78%. This is now the default. The
costs: more CPU per operation (1.39 µs instead of 0.97 for GET with pipeline 10), and
a failed send is no longer reported to the program; a dead client shows on the next
read.

**One more fix along the way.** Each connection waiting in `recv` used to hold a 64 KiB
buffer from `malloc`. With a hundred connections glibc kept handing that memory back
to the kernel and taking it again: `brk` in the main thread, `madvise(MADV_DONTNEED)`
in another thread's arena (the call stacks came from `strace -k`). A waiting `recv` now
gives the buffer back to its thread, and `send_raw` writes into a per-thread buffer:
+7% on one loop.

**Proving it.** Two laws are proved ([`LAWS.bend`](https://github.com/littleBro/BendKV/blob/archive/shards/LAWS.bend) of that time, section Shards).
A history is the batches the server has run since it started. After any history, the
sharded server answers the next batch exactly as the single one does
(`shard_replies`), and every key reads in its shard as it reads in the single
database (`shard_holds`). They hold for any number of shards. This round proved them
for batches of every command but DBSIZE, KEYS and FLUSHALL, which read or clear the
whole database; section 3c adds those three. The laws are about `split` and `merge`
in `shard.bend`; how `server.bend` hands the parts to the shards over channels and
collects their replies stays trusted.

A command on several keys goes to the shards in pieces, one command of one key per
key: a GET for each key of MGET, a DEL or EXISTS of one key for each of DEL and
EXISTS, a SET for each pair of MSET. The proof (about 1,250 lines) runs a history
piece by piece, each on its key's shard. The shards then hold the database pointwise,
because a piece's effect on its own key depends only on how that key reads, and it
leaves every other key alone (`frame`). So the map's laws suffice, and nothing looks
inside the trie. A batch's pieces, pushed on the shards' lists, come back off them in
the batch's order, each reply the one the key's shard gives, which is the database's;
merge's folds turn them into the command's reply (an array, a sum of counts, OK). And
a command's pieces, run one after another on the database, give its reply and its
database: MGET's values are its GETs' replies, DEL removes and counts as its pieces
do, MSET writes as its SETs do. One obstacle came from
Bend: a hypothesis "for every key" is a closure, and a closure can be called once. So
the proof never assumes one; the pointwise correspondence is a top-level function,
called at whatever key a step needs. Refutations ("these shards differ") are
closures too, and became equalities of boolean verdicts.

## 3b. Bytes between cores, epoll, iolists and PGO

Four questions (PERFORMANCE.md, section 7.17): do shards pay off once cores pass bytes
instead of terms; does `epoll` lift GET without pipelining; what does profile-guided
optimization give; and should a reply be an iolist, as in Erlang, a tree of pieces sent
without gluing?

**A lighter load generator.** memtier takes two of the machine's four cores. To give a
server three, [`tools/loadgen.c`](../tools/loadgen.c) drives it from one: a single
epoll thread keeping P requests in flight per connection, as memtier's `--pipeline`
does. [`tools/scale_bench.sh`](../tools/scale_bench.sh) runs servers on CPUs 1–3
against it, interleaved. Without pipelining, loadgen itself is the limit (about
170–200 thousand requests a second), so that case was also measured with memtier on
2+2 cores.

**epoll (the eleventh patch).** A socket the runtime made joins its loop's epoll set
once, edge-triggered; the loop remembers whether it is readable and writable, and a
short `recv` marks it drained, so the next `recv` waits for an edge instead of spending
a system call on `EAGAIN`. Other descriptors are armed one-shot for each wait, since a
custom effect may close them behind the runtime's back. The Bend test suite and stress
runs caught three bugs on the way: a reused descriptor number, timers starved by a
steady stream of connections when `accept` tried before parking, and a lost FIN when
it arrived with the last bytes (fixed by remembering the end of stream apart from
readiness). Accepted sockets also get `TCP_NODELAY`: a reply written in several pieces
used to wait 40 ms for a delayed ACK.

With pipelining, on three server cores, `epoll` and `TCP_NODELAY` together lift GET by
18% (736 → 872 thousand a second) and a half-SET mix by 13%. Without pipelining,
measured with memtier on 2+2 cores, GET goes from 1.15 to 1.27 of Redis, and kernel time
per request falls 30%, from 8.3 to 5.8 µs (Redis: 5.3). Counting the calls with an
`LD_PRELOAD` shim: with `select`, a request cost two `recv`s (one of them an empty
`EAGAIN`), a `send` and a share of a `select` that polled all 100 sockets; with `epoll`,
one `recv`, one `send` and 0.62 of an `epoll_wait` that returns the ready sockets
directly. `TCP_NODELAY` alone gave the load spec +14% and cut its p99 from 12.9 to 4.4 ms.
User time per request is still 2.6 times Redis's (2.7 vs 1.0 µs), part of it the
loop's and the writer's spinning.

**Bytes in replies pay; bytes in requests do not.** A shard now encodes each of its
replies itself ([`wire.bend`](https://github.com/littleBro/BendKV/blob/archive/shards/wire.bend)), so a value leaves its shard as RESP bytes
and the connection merges bytes. Before, the connection read reply terms that pointed
into the other core's trie, and the values' reference counts bounced between cores.

Three laws prove the merge in bytes. `merge_bytes`: it gives shard.bend's merged
replies, each encoded. `encodes_glue`: replies encoded one by one and glued are the
batch encoded at once. So `shard_bytes`: after any history the sharded server sends for
a batch the very bytes the single server sends. For that, each command comes out of the
merge as one string, and a GET's reply leaves its shard as a kind of its own (`OBulk`),
which an MGET array takes as an item and any other reply as a nil, as shard.bend does.
The proof (about 340 lines) walks both merges step by step; a seeded bug in the merge
fails it.

With pipeline 10 on three server cores, bytes in replies lift GET on two shards by 33%
(516 → 686 thousand a second); on three, by 2% (797 → 816), within noise.

Passing requests as bytes too (the connection frames each request without copying,
routes it by name and key hash, and the shard parses its requests out of the shared
buffer) passed every test but was slower: GET with pipeline 10 on three shards
715–744 thousand against 752–809, SET of 1 KB values 543–551 against 570–613. The shard
has to pull the request's bytes from another core's cache and parse them again, while a
command term carries a pointer to its value, which SET stores without reading. Bytes pay
in the direction where the receiver reads the data anyway: a reply's bytes must be sent,
so they are best produced where the value is in cache.

**A compiler trap.** The first version of that byte routing slowed even a single shard
by 27%, on a path it did not touch. Bend's compiler decides per function whether a
parameter is borrowed or owned, from all its call sites: one call with a fresh argument
the caller no longer needs makes the parameter owned, and every other caller that still
holds its argument then takes a reference before the call and drops it after. A new
call `R.parse(args)` with `args` used afterwards made `R.parse` borrow (`slot_keep` on
every field, a `term_drop` of the request after), and `KV.hash(String.slice(...))` made
`KV.hash` own its key (four `term_keep`s in `exec`). Comparing the generated C of the two
builds function by function, with ids normalized, found it. In Bend, adding a call site
can change a hot function's calling convention globally.

**A writer pays only with a core of its own.** Two shards with writers (four threads on
three cores) beat two without by 13–17%; three with writers (six threads) lose 32%. The
server takes a third argument, `post` or `send`, and defaults to a writer for one shard
and to sending from the loop for more. On three server cores one shard with a writer is
still the fastest with pipelining: 897 thousand GETs a second, 2.06 times Redis with
three io-threads. Three shards reach 816.

**iolists lose here.** `TCP.post_list` (eleventh patch) posts a list of pieces as one
buffer, so a GET reply can be its header, the value straight from the trie, and
`"\r\n"`, and the value is copied once instead of twice. With one shard it was 15–30%
slower with pipelining (100-byte and 4 KB values) and faster only for short replies
without pipelining. In Bend's heap each piece is a list cell and a string, and three
cells per GET cost more than copying 100 bytes into the reply's chunk. A real `writev`
without gluing is out of reach: the writer thread sends after the loop has moved on,
and a value in the loop's heap may be freed by the next SET (reference counts are not
atomic), so the pieces are glued into the post's buffer anyway. The first version also
grew that buffer by doubling, and the reallocations contended with the writer's frees
for the malloc arena lock (20% of the profile); it now sums the lengths first. An iolist
would pay for values of hundreds of kilobytes, and only with buffers the writer can hold
safely, like Erlang's reference-counted binaries. BendKV keeps `post_list` for merging
shards' replies, where each piece is a whole encoded reply.

**PGO.** `make pgo` builds the server with clang's profile-guided optimization, trained
by redis-benchmark on one shard and on two: +4% on GET and on a half-SET mix with one
shard, +1–3% with three, and 3–6% less user time per operation on memtier's specs.
Without pipelining the kernel's time is twice the user's, and PGO is within noise there.

**Spinning needs its own cores.** In two series, multithreaded servers suddenly
collapsed: Redis with three io-threads fell from about 400 to 76 thousand GETs a second
(155 to 7.8 thousand without pipelining), and BendKV with three loops, or with writers
on two shards, lost 30–40%, while single-loop servers barely moved. The cause was a
waiting process of our own (`read -t N < /dev/zero` in bash reads zeros nonstop and
takes a whole core) sharing a core with the server. Threads that spin while they wait
(Redis's io-threads wait for each other every iteration; BendKV's loops spin 30 µs
before sleeping, its writers 50 µs) then burn their slices while their partner waits
to run. Those series were discarded. It is also why shards send their replies
themselves by default: a writer pays only with a core of its own.

## 3c. DBSIZE, KEYS and FLUSHALL on the shards, proved

The shard laws now hold without conditions: after any history, the sharded server
answers any batch, and sends for it the very bytes, as the single server does
(PERFORMANCE.md, section 7.18).

**A command for each digit of the root.** A key's shard is chosen by the lowest hex
digit of its hash, the digit the trie's root branches on. So DBSIZE, KEYS and FLUSHALL
are cut into 16 pieces, one per digit, each sent to the shard that holds that digit's
subtrie (`owner(n, x) = x·n/16`, and `shard_of(n, h) = owner(n, hex(h))`). The pieces
are internal commands of `redis.bend` that no request parses into: `SizeAt{x}` (the
number of entries under x), `KeysAt{p, x}` (its keys that match p) and `FlushAt{x}`
(empties it). Their replies merge with the folds merge already has: a sum, arrays
joined, OK. The earlier plan needed a fact about machine words, `(h & 15)·n >> 4 < n`,
because FLUSHALL cleared shards `0..n-1` and every key's shard had to be among them.
This one needs none: the proof holds for any map from digits to shards.

**A structural invariant.** The old proof kept a pointwise correspondence: every key
reads in its shard as in the single database. That is too weak for DBSIZE and KEYS: two
tries that read alike can differ in the order of a bucket's entries (so in KEYS's
order) and in the empty nodes deletes leave behind. The new invariant is that under
each digit of the root, that digit's shard holds exactly the subtrie the database holds
there; the pointwise law follows from it. A step needs three facts about a piece: it
changes only its digit's subtrie, and both that subtrie after it and its reply depend
only on that subtrie before it. For writes to a key these follow from two lemmas about
the root, generated 16 and 48 ways: a read from the root goes on in its first digit's
subtrie, and a write from the root writes that subtrie and puts it back (`with_child`).
Then each command equals its pieces: DBSIZE is the sum of the subtries' sizes, KEYS
their matching keys one digit after another (the glob filter commutes with list
append), FLUSHALL each subtrie emptied in turn. `map.bend` now defines the map's size
and keys through the root's subtries, digit by digit.

**Two more compiler traps,** both caught before measuring anything else:
- FLUSHALL's first version returned a root of 16 empty subtries written as a constant.
  Bend allocates constant constructors statically, and a constructor that may be static
  is never rebuilt in place (patch 5). Every match on the trie's `Node`, including the
  write path of SET, switched from reusing the node to copying it: SET +29% and INCR
  +28% instructions. `make perfcheck` flagged it, and comparing the generated C
  function by function found the cause. FLUSHALL now empties one digit at a time.
- `tsize` and `tkeys`, called on `child(t, x)`, a fresh argument, became functions that
  own their trie, and a function that owns a shared node copies it to take it apart:
  every DBSIZE and KEYS would have copied the database. `size.at` and `keys.at` match
  the root themselves and hand those walks a field of a borrowed node, as before.

With both fixed, GET, SET and INCR cost 3,846, 4,582 and 4,828 instructions (the
baseline: 3,850, 4,585 and 4,834), and DBSIZE, KEYS and FLUSHALL run as fast as
before on one shard; KEYS * on three shards got faster (15–17 against 9–10 a second on
100 thousand keys), for reasons not investigated. Six mutations (a DBSIZE piece one too
high, a KEYS piece reading the wrong digit, a FlushAt that clears nothing, the old
`size`, DBSIZE without pieces, a FlushAt sent to the wrong shard) each break the proof.

## 3d. Commands on different keys commute

Five more laws ([`LAWS.bend`](../proof/LAWS.bend), section Commuting commands) say when
commands may run in another order. No command moves a value from one key to another:
what a key reads after a command depends only on what it read before. So:
- after two commands, in either order, every key that at most one of them writes reads
  the same (`commute_reads`);
- a command answers the same after another one that writes no key it reads, or for
  DBSIZE and KEYS, that writes nothing at all (`commute_reply`); two commands that do
  not disturb each other answer the same in either order (`commute`);
- two adjacent commands of a batch that do not interfere may trade places: their
  replies trade places, the rest of the batch answers the same unless it holds DBSIZE
  or KEYS, and every key reads the same at the end (`swap_replies`, `swap_reads`).

The laws speak of what keys read, not of the trie: two new keys of one bucket sit in
the order they were set, so after a swap KEYS may list them in the other order (Redis
promises no order), and equal sizes would need an invariant that no bucket holds a key
twice. The swap proof meets Bend's affinity again: "the two databases read alike at
every key" is a closure that can be called once, so the proof instead keeps both runs
explicit and re-derives the claim at whatever key a step needs (`eq_at`), as the shard
proof does. About 600 lines; all 30 laws check in about a second, and in about 2.5 s
with the BendTT kernel.

## 3e. An append-only file, with recovery proved

With a file (`./bendkv PORT 1 post FILE [always|everysec|no]`), the database actor
runs each batch with `exec_log` ([`aof.bend`](../src/aof.bend)): `exec_all` that also
collects what the batch did, as commands (its effects), and appends them to the file
before it answers, in Redis's own AOF format (an array of bulk strings per command).
Reads and errors have no effects; SET, SETNX, GETSET, APPEND, DEL, MSET and FLUSHALL
log themselves; INCRBY logs the SET of the value it stored, as Redis logs
INCRBYFLOAT, so that no number is ever read back from text. The reply decides the
effect, so the actor never looks at the database twice and keeps owning it. At start
the server loads the file and runs its entries from an empty database.

Eight laws ([`LAWS.bend`](../proof/LAWS.bend), section Persistence):
- `log_exec`: `exec_log` answers and leaves the database as `exec_all` does;
- `log_hints`: the actor runs each batch after the hints of `batch.bend` (its keys'
  trie paths start loading first), and they change nothing;
- `log_replay`: a batch's effects, run on the database the batch ran on, leave the
  database the batch left;
- `log_args`: a client batch's effects, written as request strings, parse back to
  themselves;
- `aof_load`: a file loads as exactly the entries written to it, with nothing left;
- `recover`: after any history of client batches, the server restores from its file
  exactly the database it held;
- `recover_cut`: a file cut anywhere by a crash restores the database the server held
  after some prefix of its commands: no command is applied in part, none out of order,
  and none after one that was lost;
- `load_cut`: the entries the loader reads, written again, followed by what it leaves,
  are the cut file, so the server cuts off exactly the leftover.

The interesting part is the decimal round trip inside `aof_load`. `Nat.show` writes the
last digit, then the digits of the quotient by 10, with the number itself as fuel; its
division is `Nat.divmod.go`, a remainder counting up. The proof defines the quotient
and last digit "by steps of ten" (`case 10n+m` is a structural pattern), shows that
`divmod` by 10 gives them (ten steps of `divmod.go` the checker just computes), that
`n = 10·q + r`, and that `Nat.show`'s fuel lasts (a number below 1 + g has its tens
below g). The digit char reads back by a 10-way case split, and the digit parser reads
`show.go(f, n, acc)` as "`acc`, read on from `n`" by induction on `Nat.show`'s fuel.
The loader's fuel is the file's length: an entry takes at least one byte. Eight
mutations of the code break the proof where they break the code.

**A file cut by a crash.** A crash during a write leaves the file cut short: like
Redis with `aof-load-truncated yes`, the server cuts it back to its last whole entry,
and refuses anything else after the entries. The cut can fall on any byte. The proof
has three steps. An entry cut short never parses (`entry_cut`): a cut number line ends
without its `\r\n`, a cut bulk lacks bytes or its `\r\n`, a cut entry lacks a bulk;
Levi's lemma for strings (`split`: if `c ++ d = x ++ z`, then `c` is `x` and more, or
`c` is a strict prefix of `x`) drives each case. Then the loader, by induction on the
entries and its fuel, reads the first k of them and stops at the cut one
(`load_cut_go`). Last, the entries are the effects of the commands in order, and a
command has none or one (`effect_one`), so the first k effects leave the database the
first j commands leave, for some j (`effs_prefix`): a command with no effect changes
nothing.

Two mutations of the loader are real recovery bugs that every law about whole files
lets through: a bulk cut inside its bytes read as a shorter string (a value nobody
wrote), and an entry cut between its arguments read as what arrived (DEL a b c run as
DEL a b). With either, all the earlier proofs still check; the proof of the cut fails.
The runtime test `tests/aof_check.bend` catches the first on its sample file; the law
covers every file.

What is not proved: that the server appends exactly each batch's effects (it groups
batches into one write; that the encoding of a concatenation is the concatenation of
encodings is proved, `enc_cat`), and the decision to cut: that the leftover is the
start of an entry and not garbage, the server learns from the network parser of
`resp.bend` (`cut_short`). For a file cut by a crash, a mistake there could only stop
the server from starting, never change the database.

**Compatible with Redis both ways.** `redis-check-aof` accepts BendKV's files, Redis
7.0.15 loads a BendKV file and serves the same data, and BendKV loads a file Redis
wrote (`SELECT 0` parses to a stub, lowercase names parse, and Redis has already
rewritten GETSET as SET).

**Group commit.** The first version wrote each batch's effects with its own `write`
on the runtime's helper threads, as Bend runs every file effect, and with `always`
synced each batch. Without pipelining, SET fell from 83 to 31 thousand a second even
without syncing: the hop to a helper thread and back cost about 20 µs per batch. With
`always` it reached 4 thousand against Redis's 35 thousand: an `fdatasync` here (ext4
on virtio) takes about 144 µs, and the batches of 20 clients synced one after another,
while Redis appends the buffer of all clients once per turn of its loop and syncs
once. Now `File.write_raw` writes from the loop's own thread (`File.sync` stays on a
helper), and the actor takes, with each request, all those that came meanwhile
(`Chan.drain`), runs their batches in order, writes all their effects at once, syncs
once and answers them all at once.

The log's path first ran without the batch hints (`exec_log`, not `exec_batch`), and
pipelined GET fell from 1.27–1.39 to 0.85–1.10 million a second; the actor now runs
each batch through `log_batch`, after the same hint pass, and a sixth law, `log_hints`,
says that is exactly `exec_log`.

`redis-benchmark`, 20 clients, 200 thousand requests over 100 thousand keys, 3-byte
values, servers not pinned to cores on the 4-core VM, medians of three interleaved
rounds, thousands of requests a second:

| test | Redis, no log | Redis everysec | Redis always | BendKV, no log | BendKV no | BendKV everysec | BendKV always |
|---|---:|---:|---:|---:|---:|---:|---:|
| SET, no pipeline | 103 | 118 | 35 | 71 | 78 | 83 | 34 |
| SET, pipeline 16 | 781 | 627 | 209 | 1,389 | 1,163 | 1,227 | 309 |
| INCR, no pipeline | 101 | 114 | 36 | 77 | 86 | 82 | 35 |
| INCR, pipeline 16 | 813 | 581 | 251 | 1,600 | 1,163 | 1,020 | 289 |
| GET, no pipeline | 102 | 109 | 101 | 77 | 78 | 76 | 82 |
| GET, pipeline 16 | 763 | 787 | 778 | 1,266 | 1,681 | 1,370 | 1,342 |

With `everysec`, both servers' default, pipelined BendKV serves 1.96 (SET), 1.76 (INCR)
and 1.74 (GET) times Redis with the same log; without pipelining 0.70–0.72, as without
a log in this setup. With `always` and no pipelining both are bound by `fdatasync` and
equal; pipelined, BendKV leads by 1.15–1.73. The group machinery even speeds up the
path without a disk: with `no`, pipelined GET reaches 1.68 million against 1.27 million
without a log, so the actor without a log should drain its channel too. Restoring a
log of a million SETs (53 MB) takes 1.62 s to the first PONG against Redis's 1.24 s.
Without a log nothing changed: the same instructions per request, and the same
generated C for every hot function.

## 3f. Groups in every actor, and a writer only with a core of its own

The actor without a log now works as the one with a log does: with each request it
takes those that came meanwhile, runs their batches in order and answers them all with
one `Chan.send_all`; shards' actors too. The laws do not change, since the batches
still run one at a time in the channel's order. It costs 1.4–1.8% fewer instructions
per request. Under Redis's specs it adds 1–7% on two cores to everything but INCR,
moves reads by ±3–7% on one core, adds 3–12% to loading new keys and cuts that load's
p99 latency two to three times; a request's time goes to its
connection (recv, parsing, encoding, send), not to scheduling the actor, and a group
delays the answers of its first requests to its end.

The bigger finding was the writer thread. For one shard, replies went to a writer
thread by default, which pays only with a core of its own: on one core (`taskset`) it
cost 12–28% of loading and about a quarter of GET without pipelining. The default is
now a writer only when the process may use two cores or more (`IO.thread_count`, which
reads `sched_getaffinity`). On one core BendKV is back at section 7.15's level or above:
loading at 1.48 of Redis, GET at pipeline 100 at 1.46.

On two server cores, with the writer, the specs now give: loading at 2.19 of Redis
(2.04 before the groups), GET at pipeline 10 at 1.53 (1.44), without pipelining 1.27
(1.21), at pipeline 100 1.36 (1.26), INCR 1.32 (1.31); the load's p99 fell from about 8
to about 4 ms.

## 3g. The append-only file on shards

With n shards and a file, each shard keeps a log of its own: `FILE.0` to `FILE.(n-1)`
(with one shard, `FILE` itself, which Redis loads). Each shard's actor logs its part
of every batch, with its own group commit and its own `fsync`, so the shards write and
sync in parallel; at start every shard restores its file at once, each on its own loop.

The obstacle was FLUSHALL. On shards it runs as one `FlushAt` per digit of the trie's
root (section 3c), and those pieces had no entry, which is why the log was for one
shard only. A piece now logs as `FLUSHAT <hex digit>`, an entry of BendKV's own: the
log's loader reads it (`parse_cmd` takes the name `FLUSHAT` itself and hands every other
entry to `R.parse`), and the network parser does not know it, so clients never see a
new command. `redis-check-aof` accepts the shards' files; Redis cannot load one with a
`FLUSHAT` in it, but a shard's file is only part of a database anyway.

With every effect now parsing back, the hypothesis that a batch is a client's left the
log's laws (`log_args`, `recover`, `recover_cut`): they hold for any batch, a shard's
part included. Three laws on top, about 60 lines of proof:
- `shard_recover`: after any history, each shard restores from its file exactly the
  database it held. A shard's history is its part of each batch, and a batch's parts
  leave shard s its part run on its trie;
- `shard_restore`: so every key reads, in the database its shard restores, as it reads
  in the single database (with `shard_holds`);
- `shard_recover_cut`: a shard's file cut anywhere restores the shard's database after
  some prefix of its own commands.

What these laws do not promise: the files restore each on its own, so after a crash
the shards together need not hold a prefix of the server's commands. A command cut into
pieces over several shards (MSET or DEL of several keys, FLUSHALL) can survive on one
shard and be lost on another, and with `everysec` each shard loses its own last
second. In memory such a command is atomic (`shard_replies`); on disk it is not. Redis
Cluster refuses such commands outright (CROSSSLOT). A consistent cut would need one
order of entries across the files, say a batch number in each, and a restore up to the
last batch whole on every shard.

The keys are spread over the shards by their count (digit d to shard d·n/16), so a
server refuses the files of another count: `FILE.0` with one shard, `FILE` or `FILE.n`
with n, and, once a shard's file is restored, any key under a digit of another shard.

Measured with redis-benchmark (20 clients, 4-core VM, servers unpinned, medians of
three rounds), with `everysec`: without pipelining two shards beat one by 1.3–1.5 times
and Redis by 1.09–1.16 (SET 122 thousand a second against 91 and 110); the log costs
them nothing there. At pipeline 16 one shard still leads, as without a log (section
3b): SET 1,162 thousand, two shards 784, Redis 552. With `always`, every server is
bound by `fdatasync` without pipelining (35–38 thousand); pipelined, one shard beats
two (340 against 277 thousand on SET), because a batch over both shards waits for two
syncs of two files on one disk. A log of a million SETs (53 MB) restores in 0.44 s on
two shards at once, against 0.85 s one after the other, 1.05 s on one shard and 1.38 s
for Redis.

Under Redis's specs (memtier, the server on two cores, all with `everysec`), BendKV
with its log beats Redis with its log on all five specs in both layouts: one shard
(with a writer) at 1.17–1.87 times Redis, two shards at 1.02–1.71; loading a million
keys at 1.87 and 1.71. On two server cores one shard still wins pipelined, as its writer
has a core of its own, while two shards' loops both parse requests and run a shard;
without pipelining two shards are slightly ahead (GET at 1.38 against 1.33).

## 3h. A key hashed once

The key used to be hashed twice: by the connection, for the batch hints (or by `split`,
to pick the key's shard), and again by `exec`. FNV-1a on a 16-byte key is 135
instructions. Now `R.exec.at(c, h, db)` runs a command with its key's hash given: a
command on one key walks the trie with it, and the rest hash their keys themselves. A
batch reaches its actor with the hashes of its keys: on one shard the connection reads
them off its requests (the hash of each request's first argument), on several they come
with the parts of the batch.

Four laws carry it (45 in all). A hash fits a command when it is the hash of the
command's key, and any hash fits a command that does not use one; `exec_at` says that
with a fitting hash `exec.at` is `exec`, and `batch_hints` (and `log_hints`) now need the
batch's hashes to fit. `req_hashes` says the hashes the connection reads off its requests
fit the commands they parse to: the proof goes through all 24 cases of the command
parser, and every command on one key takes its key from the first argument. (Section 3j
restates it as `fit_hashes`, for a parser that builds each request with its proof.)
`shard_hashes` says a shard's part comes with fitting hashes (the shard proof already
builds parts from pieces with their hint, `Part{c, hint(c)}`), and `unzip_parts` that the
server's `unzip` splits a part into its commands and hashes. Six mutations break the
proof where they break the code.

The first version read the hashes from the parsed commands and cost 3.3–4.0% more
instructions instead of 3.5% fewer. Per-function callgrind on a `-g` build showed why:
the second hash was gone (`str_hash` 270 → 138 instructions per request), but reading the
keys of commands the batch still needs costs reference counts (+86), and walking the hash
list in step with the commands costs 142 instructions per request against 73 for
`exec_all.go`. Reading the hashes off the requests, as the hints did, removed the
reference counts, at the price of the parser proof. The result: 1.6%, 1.0% and 0.8%
fewer instructions on GET, SET and INCR on one shard, 1.2%, 0.6% and 0.6% on two; in
paired runs throughput moved by 0.98, 1.03 and 1.04, inside the scatter between two builds
of the same C. Half of the saved hash goes to carrying the hashes. A cheaper hash itself
(CRC32C on the `crc32` instruction) looked like the next step, but the breakdown at the
end of section 4 puts the whole hash at 1.1–1.5% of the time, off the chain of misses:
under 1% to win.

## 3i. Five steps after the breakdown, each measured on its own

The breakdown at the end of section 4 ranked five next steps. All five were built, each
on its own on top of 3h and then together; four are in the server, and the fifth (hints
across the actor's whole group) was measured and taken out. Instructions come from
callgrind (deterministic to ~0.1%; to ~1.5% without a pipeline, where the actor's groups
depend on how the scheduler interleaves threads). Time comes from pairs in which every
variant is built in three shuffled code layouts (`tools/layouts.sh`), since two builds
of one C differ by 5–10%; even so, a run of a million requests on this VM varies by
±15%, and two series of twelve runs per variant put the same five-step build at 0.98
and 1.07 of the base on GET. Only effects above ~5–8% show in time; smaller ones show in
instructions.

| instructions per request | GET, pipeline 16 | SET | INCR | GET, pipeline 100 | SET, pipeline 100 | GET, no pipeline |
|---|---:|---:|---:|---:|---:|---:|
| base (3h) | 3,729 | 4,473 | 4,731 | 5,657 | 8,482 | 11,080 |
| 1. cheaper RESP parsing | 3,471 | 4,144 | 4,474 | | | 10,830 |
| 2. long reads, `code_at` of small strings | 3,709 | 4,464 | 4,547 | 3,447 | 4,212 | 10,927 |
| 3. the loop shares the sends | 3,737 | 4,472 | 4,724 | | | 10,984 |
| 4. hints across the group (dropped) | 3,765 | 4,513 | 4,763 | | | 11,712 |
| 5. effect pairs | 3,671 | 4,438 | 4,694 | | | 9,191 |
| **1, 2, 3 and 5: the server now** | **3,418** | **4,112** | **4,284** | **3,196** | **3,891** | **8,962** |
| all five | 3,450 | 4,135 | 4,319 | 3,220 | 3,909 | 9,529 |

(Pipeline 16 and 100: one shard sending from its loop, 20 clients; no pipeline: 50
clients, the replies posted to the writer, so the writer's own instructions count too.)

1. **Cheaper RESP parsing** (`resp.bend`). A number line is read a character at a time
   up to its `\r`, with no `memchr` call (lengths have one or two digits, and the call
   with its saved registers cost ~110 instructions); requests of one, two and three
   arguments are built in order, without the list that `bulks` reversed; an empty
   request is a case of its own, so the batch no longer rebuilds every request to tell.
   Parsing a GET went from 1,562 to 1,221 instructions, a SET from 2,037 to 1,654. Not
   done: `U32` lengths (string indices in Base are `Nat`) and parsing straight into a
   `Cmd` (it needs `req_hashes` restated for a new parser).
2. **Long reads without the slow paths.** Done in BendKV rather than in the runtime: a
   read stays one `recv` of up to 64 KiB, and is parsed in windows of at most 2 KiB, each
   copied into one chunk (`String.slice`), so `code_at`, `find` and `slice` never leave
   the fast path; a request longer than a window is parsed in the rest of the buffer, once
   all its bytes are in. At pipeline 100 a GET dropped from 5,657 to 3,447 instructions
   and a SET from 8,482 to 4,212. Patch 14 gives `String.code_at` a fast path for strings
   of up to six bytes that live in the term word: INCR reads its number by index, and
   every digit used to take the slow path (INCR's execution, 1,649 → 1,473).
3. **The loop shares the sends with the writer** (patch 15). The loop and the writer
   each measure the share of their time they work, in 200 µs windows; a loop less busy
   than its writer by more than 10 points sends posted bytes itself, and so does a loop
   whose writer sleeps (up to four sends in a row, then it rings the writer). A socket's
   bytes stay in order: the loop sends only when the writer has sent all that was posted
   to that socket before. Simpler rules either lost 2–10% at pipeline 10, where the
   writer's core should pay for the sends, or gained nothing without a pipeline. io_uring
   was not tried: entering the kernel costs 114 ns here, a loopback `send` 5–6 µs.
4. **Hints across the actor's whole group — dropped.** The actor takes all the batches
   waiting for it (~28 one-request batches without a pipeline, ~6.6 batches of 16 at
   pipeline 16). The variant walked the trie paths of all their keys first, then ran each
   batch without hints of its own; a law, `group_hints`, proved that this is `exec_all`
   whatever the hints return. At pipeline 16 it cost 6–7% of throughput on all three
   commands for 1% more instructions: callgrind shows twice the L1 misses in hints and
   execution (7.8 → 15.8 per GET), because a hundred keys push each other's lines out of
   L1 before the batch reaches them, while one batch's 16 keys fit. Without a pipeline it
   cost ~600 instructions per request and moved throughput by 0.98–1.02, within the
   noise: there the system calls are the bottleneck, and overlapping ~2.5 misses (~200 ns)
   costs ~200 ns of instructions. A version that gave the group's hints to one-request
   batches only matched the build without it at pipeline 16, and paid off in one place:
   GETs that all hit, at a million keys, without a pipeline (`tools/memtier_hits.sh`;
   1.34 of Redis against 1.23), where every GET walks all the way to its value. In
   Redis's specs, though, 90% of GETs look for missing keys, and memtier sends a new
   request for every reply, so one-request batches occur even with a pipeline: the load
   spec fell from 1.12 to 1.04 of the base, GET at pipeline 10 from 1.02 to 0.93.
   The code and the proved law are in the history (commit 468a84a).
5. **Effect pairs** (patch 16). `Chan.call` hands a batch to the actor and waits for its
   answer, `TCP.post_recv_raw` posts a reply and waits for the next request: one effect
   each instead of two. Every effect is a step of the event loop (the `do` block's
   continuation applied through a closure, the next effect decoded and dispatched); a
   request without a pipeline took four, now two, and the event loop's share of a GET
   fell from 5,827 to 3,812 instructions. Compiling `IO` binds to direct continuations
   would remove the remaining closures, but changes how every program's `IO` compiles.

**Time.** At pipeline 16 on one core (`redis-benchmark`, 100 thousand keys, four pairs ×
three layouts) the steps alone moved GET, SET and INCR by 1.06/0.99/1.03 (1), 0.99/
1.02/0.98 (2), 1.05/1.01/0.98 (3), **0.94/0.94/0.93** (4) and 0.96/0.97/1.04 (5); the
server now, 1.06/1.13/1.09 in a second series (the build with all five gave 0.96–1.07
across the two). Without a pipeline, on two cores with the writer
(`redis-benchmark`, 50 clients on one thread), step 3 gave **1.20/1.16** on GET/SET, the
others 0.94–1.03, and the server now 1.15/1.08; Redis is still faster there, 1.42/1.32
of the base. Step 5 alone moves no time without a pipeline: the loop spends 17% fewer
instructions per request, but the writer's sends are the bottleneck. Redis's specs
(memtier, two server cores, two series × two layouts), share of the base's throughput:

| spec | 1 | 2 | 3 | 4 | 5 | 1, 2, 3, 5 | Redis |
|---|---:|---:|---:|---:|---:|---:|---:|
| load 1M keys, 100-byte values, pipeline 10 | 1.16 | 1.18 | 1.11 | 1.11 | 1.14 | 1.12 | 0.58 |
| GET, 100-byte values, pipeline 10 | 0.96 | 0.97 | 0.95 | 0.97 | 1.06 | 1.02 | 0.70 |
| GET, 100-byte values, no pipeline | 0.97 | 1.01 | **1.12** | 1.00 | 0.99 | **1.11** | 0.82 |
| GET, 10-byte values, pipeline 100 | 1.03 | **1.27** | 0.93 | **0.84** | 0.98 | **1.26** | 0.74 |
| INCR, pipeline 10 | 1.01 | 0.99 | 0.93 | 0.95 | 1.01 | 1.03 | 0.72 |

On the load spec every variant beats the base by 11–18%, including those that do not
touch its path: the ratios share one denominator, and the base's runs came out slow
in this series (p99 13.8 ms against 6–7 ms), so the steps cannot be told apart there.
Against Redis in the same series the server now serves **1.93** of its throughput on
the load spec (the base 1.73), 1.46 on GET at pipeline 10 (1.43), **1.37** on GET
without a pipeline (1.23), **1.69** on GET at pipeline 100 (1.35) and 1.43 on INCR
(1.39); on GETs that all hit, at a million keys, 1.23 without a pipeline (1.13) and 1.37
at pipeline 10 (1.39).

## 3j. The gap without a pipeline, requests parsed into commands, IO in continuations

Three items of the plan after 3i, each built on its own and then together: (A) the gap to
Redis without a pipeline under `redis-benchmark`, (B) parsing a request straight into its
command, (C) compiling `IO` to direct continuations. A and C are patches to Bend (17 and
19), B is BendKV's parser with a small runtime patch (18).

**A. The loop sends while it keeps up** (patch 17). Without a pipeline, BendKV with its
writer thread served 0.80 of Redis under `redis-benchmark` but more than Redis under
memtier. The difference is the client: `redis-benchmark` drives 50 connections from one
thread, so requests trickle in one or two at a time, while memtier's two threads keep the
loop busy. The loop shows it: under `redis-benchmark` an `epoll_wait` returns 1.4–2 ready
sockets, under memtier 9–65, and the loop and writer together are busy ~40% of the time
against 90–130%. When the loop keeps up, handing a reply to the writer only lengthens
the path (a ring, a futex wake, a `send` on another core while the client waits); when it
falls behind, the writer frees it. Patch 15 decided by the busy shares, which are low on
both sides without a pipeline, so the loop nearly always posted. The new rule decides by
demand: over spans of 32 windows of 200 µs, while an `epoll_wait` averages fewer than four
ready sockets the loop sends its replies itself, at once; after two spans above that (or
without a single wait) it posts to the writer, and it goes back once the two together are
busy under 60% for three spans. While it posts, patch 15's rule applies. A first version
judged by instantaneous busy shares and flip-flopped. On two cores, 50 clients, GET and
SET gained **1.21** and **1.26** over the build without the patch, to 0.93 and 0.90 of
Redis in that series (medians; geometric means 0.99 and 0.93); with a pipeline nothing was
lost (1.03–1.15 at pipeline 16 on two cores, 0.98–1.07 on Redis's specs).

**B. Requests parsed into commands.** The parser used to produce a list of words per
request; `R.parse` turned each into a `Cmd` and `req_hashes` walked the lists again for the
keys' hashes, with a law that the hashes fit. Now GET, SET and INCR read their arguments
straight into the command and the rest go through an argument list. Each request comes as
a `B.Fit{cmd, hash, ok}`, with `ok: fits(cmd, hash)` a proof that the hash is the hash of
the command's key, so the type checker checks every place the parser picks a hash. The
key's hash is read off the buffer (`String.hash_at`, no slice), and its proof is `{==}`:
Base defines `String.hash_at` as `String.hash` of the slice. At run time the proof is a
constant. The law `fit_hashes` was restated for the new parser (the commands and hashes
the server takes from the `Fit`s fit), and there are still 45 laws. The first version cost
more than the old parser (3,473 instructions per GET against 3,414): a number line was read
by two natives and two `code_at`s, each of which unpacked the buffer's term again. Three
steps fixed it: `String.dec_line_at` reads a line of digits and its `"\r\n"` in one pass
and returns its number and length in one word (212 → 89 instructions per line; a native
of several C parts may now borrow its arguments); `String.to_upper` of a string that lives
in the term word upcases its bytes at once (62 → 27); and a batch is kept newest first, so
the server takes it apart into commands and hashes with one tail loop that also restores
the order, instead of the parser building it in order by non-tail recursion that copied
each `Fit` (eight words, unboxed by the compiler) through stack frames. Parsing, command
and hash now take ~1,370 instructions per GET, from ~1,750.

**C. `IO` in direct continuations** (patch 19). In Bend `IO(A)` is a function of an answer
type `R` and a continuation `k`, and a `do` block becomes `IO.bind(m, x => ...)`. Compiled,
`IO.bind(m, f, k)` builds a closure `{f, k}` and applies `m` to it; when `m`'s effect
completes, the runtime applies that closure, which applies `f(x)` through a stack frame and
the result to `k`: four `CLO_APPLY`s and two or three allocations per bind, 14.5
`CLO_APPLY`s and 1,428 instructions per request without a pipeline. The compiler now
rewrites every def whose type ends in `IO(A)`: it takes `R` and `k` as parameters of its
own, `IO.bind(m, f)` becomes `m` run with the continuation `x => f(x)` run with `k`,
`IO.pure(x)` becomes `k(x)` (a `let` when the compiler built `k`), a `let` or a match passes
`R` and `k` to its body or arms, and any other `IO` value is applied to them. A bound
effect or def is then called directly with a continuation that holds the rest of the
block: one closure and one `CLO_APPLY` per bind. `main` is left as it is (the runtime runs
it for its `IO` value). The checker sees the old terms. Two traps, both about types the
compiler reads off annotations: an `IO` value applied to `R` and `k` needs the type of
`m(R)` annotated, or the compiler, which drops erased arguments of a spine over a variable
and places the live ones by the head's type, put `k` where `R` was and lost it; and a
variable in a position whose type the context gives may carry no annotation at all, so the
rewrite passes `IO(A)` down from the def's type, `IO.bind`'s arguments and the arms'
annotations, and applies a value of unknown type to `k` alone. Bend's own TCP and UDP
tests caught the second. Without a pipeline, `CLO_APPLY`s per request fell to 7.1 in send
mode and 2.3 in post mode (only the continuations applied after effects), mispredicted
indirect branches from 22.4 to 4.8.

| instructions per request | GET, pipeline 16 | SET | INCR | GET, no pipeline, send | SET | GET, no pipeline, post | SET |
|---|---:|---:|---:|---:|---:|---:|---:|
| base (17 patches) | 3,414 | 4,103 | 4,271 | 8,460 | 9,102 | 9,044 | 9,220 |
| B. parsed into `Cmd` | 3,028 | 3,591 | 3,887 | 8,296 | 8,811 | 8,700 | 8,793 |
| C. `IO` in continuations | 3,337 | 4,027 | 4,177 | 7,766 | 8,402 | 8,325 | 8,595 |
| B and C | **2,969** | **3,534** | **3,830** | **7,459** | **7,970** | **7,820** | **7,911** |

**Time.** At pipeline 16 on one core (`redis-benchmark`, 100 thousand keys, four pairs ×
three layouts) B, C and both moved GET, SET and INCR by 0.95/0.95/1.06, 1.01/0.96/1.04
and 1.03/0.94/1.02, within the noise, though both together spend 5–10% less user time per
request: the kernel is almost half of a request's CPU here (~450 ns against ~500 ns of
user time), so 12–14% of the instructions is ~5% of the CPU. Without a pipeline on two
cores (50 clients) they gave 0.95/1.03, 0.92/1.00 and 0.89/1.00 on GET/SET, and both
together 0.95/0.97 in a second series of their own. They make the same system calls per
request as the base (one `recv`, one `send`, 0.54–0.61 `epoll_wait`, by
[`tools/iocount.c`](../tools/iocount.c)), add no memory or page faults, and in long runs
of a million GETs the two serve the same (92 and 90 thousand a second against 90 and 90);
yet in both series B, C and both spent 0.3–0.9 µs more kernel time per request than the
base, with less user time (the kernel takes 6.4–7.7 µs per request, user code 3.3–3.9).
We did not find why, and the difference sits at the edge of the noise. On Redis's specs
(memtier, two server cores, two series × two layouts) all three gave 0.98–1.03 of the base
on GET and INCR and B 1.12 at pipeline 100; on the load spec all three gave 1.11–1.12, but
the base's runs came out slow again (p99 12 ms against 5–6 ms). Share of Redis's
throughput in that series:

| spec | base (17 patches) | B | C | B and C |
|---|---:|---:|---:|---:|
| load 1M keys, 100-byte values, pipeline 10 | 2.04 | 2.28 | 2.26 | **2.25** |
| GET, 100-byte values, pipeline 10 | 1.64 | 1.63 | 1.62 | 1.62 |
| GET, 100-byte values, no pipeline | 1.41 | 1.38 | 1.44 | 1.37 |
| GET, 10-byte values, pipeline 100 | 1.98 | 2.21 | 2.07 | **1.95** |
| INCR, pipeline 10 | 1.35 | 1.33 | 1.36 | 1.39 |

So A closed the gap without a pipeline under `redis-benchmark`, and B and C cut 12–14% of
the instructions, which on these loads weigh less than the noise: a request's time is now
mostly the kernel's, and BendKV's user time per request is 0.37–0.51 of Redis's at
pipeline 16 and 1.1–1.3 of it without a pipeline.

## 3k. After the review: a value's bytes within reach of the hints, a GET with no seal

The three items the outside review added to the plan (section 11) were built one by one
on top of section 11's HEAD, measured, and put through section 10's test: code that gets
more complex has to pay for it. Instructions and L2 misses came from callgrind (a model
that does not see the hints), time from three loads, each variant in three code layouts:
GET hits with 100-byte values at pipeline 10 on one core (1 and 10 million keys), Redis's
specs on two cores, and `redis-benchmark` with 3-byte values at pipeline 16. One caveat:
this VM's L3 holds 260 MB, so at a million keys the values sit in it (~40 ns an L2 miss),
where the colleague's i9, with 24 MB, goes to memory.

**Hints that reach the bytes.** Patch 20 makes `Mem.prefetch` of a buffer load its bytes
to the end, up to four lines, not its first 64 bytes (+22 instructions per GET). That
alone does little, because a value is sealed after its first GET and the hint stops at
the seal. A fourth pass over the batch that read the seal, fetched by the third, and
hinted the buffer behind it (`Mem.prefetch_in`) cost ~200 instructions on every request
of a batch, 3-byte values included, and lost: 0.98 on GET hits, 0.93 on SET and INCR with
3-byte values. It was dropped.

**A GET that shares nothing.** The seal was there because a GET's reply held the value
that the trie holds too. Instead of encoding the reply while the database is lent, as
the review proposed, the GET answers a copy made where the value lies: the value is then
only read, and the compiler does not seal it. `KV.get_copy.at` walks as `get.at` does,
but its bucket answers `String.take(v, String.length(v))`; `exec.at` calls it for GET. In
the theory a copy of a whole string is the string (`take_len`), so the copying lookup
answers as the plain one (`bget_c_eq`, `tget_kc_eq`, by induction on the depth, the
16-way part written by the generator), `exec_at` takes one more rewrite, and there are
still 45 laws. The copy costs an allocation and a `memcpy`, and saves `slot_keep`, two
atomic count operations and the read of the seal before the bytes; with patch 20 a copy
of a word string is the word, not 77 instructions to rebuild it.

| per GET | base | fourth pass | copying GET |
|---|---:|---:|---:|
| instructions, 100k keys, 100-byte values | 3,458 | 3,689 | 3,577 |
| L2 misses (model) | 5.10 | 5.13 | **4.46** |
| instructions / L2 misses, 1M keys | 3,531 / 6.72 | | 3,639 / **5.85** |
| instructions, 3-byte values, GET / INCR | 2,957 / 3,832 | 3,156 / 4,009 | 2,976 / 3,845 |
| time, GET hits, 1M keys (user CPU) | 1 | 0.98 (0.94) | 1.02 (1.045) |
| time, GET hits, 10M keys (user CPU) | 1 | 1.03 (1.01) | 1.015 (1.024) |
| Redis specs: load / GET p10 / no pipeline / GET p100 / INCR | 1 | 1.04 / 1.00 / 1.00 / 0.96 / 1.03 | 1.02 / 1.00 / 1.00 / 1.05 / 1.02 |
| `redis-benchmark`, 3 bytes: GET / SET / INCR | 1 | 0.99 / 0.93 / 0.93 | 1.03 / 1.00 / 0.99 |

A million keys with 100-byte values take 183.1 MB after loading and 183.3 MB after a GET
of every key (183.0 and 191.1 MB before). The copying GET stays, on the boundary: its gain
in time here is small (+1.5–2% on GET hits, +5% on one spec, the rest in the noise), but
it is never below the base, reads no longer grow memory (8 bytes per key read, 4% with
100-byte values), and a GET takes 0.6–0.9 fewer misses and two fewer atomic operations,
which should count for more where values are not in the L3. It costs 97 tokens of runtime
and about 50 hand-written and 80 generated lines of code and proof, with no new law.

**Hash bits in a bucket entry.** At a million keys a bucket holds 0.95 entries on average,
and a GET passing a foreign entry reads that key's bytes to compare. The entry could
keep the 12 bits of the hash that the path leaves (`h >> 20`) and compare keys only when
they match; it costs no memory, since a three-field entry already takes a four-word
block. The prototype, against the copying GET: 14 more instructions at 100k keys, 49
fewer and 0.52 fewer misses at a million, and in time 1.01 on GET hits at a million keys,
0.99–1.05 on the specs, 0.96–0.97 with 3-byte values. Only at 10 million keys, with ~9.5
entries per bucket, did it gain (1.07), and an overloaded trie wants more buckets (a
sixth level), not a filter in its chains. Its proofs would have to change in all 111
places that take an entry apart, plus a lemma that `U32.is_eq(h, h)` holds of a 32-bit
vector. It was not taken.

## 3l. Taking out what did not pay

On the scale of section 10, three changes gave the least for a visible cost: the shards
(3a–3c, 3g), the key hashed once (3h, with its obligation carried in a type since 3j),
and the effect pairs with a fast path of their own in the connection (3i, step 5). We
took them out, keeping every series of measurements within 5% of before, measured as
before: pairs over three code layouts, callgrind, `make perfcheck`. The branch
[`archive/shards`](https://github.com/littleBro/BendKV/tree/archive/shards) keeps all of it, so the shards can come back into a finished project in a
later round of optimization. From here the work goes after features rather than speed:
a drop-in Redis for one node (README.ru.md, "Что дальше"; [DIRECTIONS.md](DIRECTIONS.md),
section 7).

- **Shards.** `shard.bend` and `wire.bend`; in `server.bend` the connection's link to N
  actors, cutting batches and collecting the parts' replies, the per-shard journal files
  with their layout check, and the restore on the shards' loops; the commands `SizeAt`,
  `KeysAt` and `FlushAt` and the journal's `FLUSHAT` entry; the trie's root section in
  `map.bend` (`digits`, `child`, `with_child`, `size.at`, `keys.at`): FLUSHALL gives an
  empty trie again, and DBSIZE and KEYS fold the whole trie, as before 3c. Ten laws went
  (shards 4, bytes 3, journal on shards 3) with their proofs and the lemmas about the
  root; about twenty lemmas from them (a command on one key answers as its key reads,
  gluing strings) were moved to where the remaining laws need them.
- **The key hashed once.** `exec.at`, `exec_all.at`, the hashed log, `fits`, and the
  proof field of a parsed request: it is now `B.Req{cmd, hash}`, and the hash serves the
  batch hints only. The laws `exec_at` and `fit_hashes` went; `batch_hints` and
  `log_hints` hold for any hashes; `exec` hashes its key itself, as before 3h. The
  copying GET of 3k stays: `exec` itself now reads with `KV.get_copy`, and the proofs
  needed one lemma, `get_copy_eq`: the copy is what `KV.get` reads.
- **Effect pairs.** One path for every connection: the batch goes to the actor with
  `Chan.send`, the answer comes with `Chan.recv`, the replies go out with `TCP.post` or
  `TCP.send_raw`, and the next read is `TCP.recv_raw`. Patch 16 (`Chan.call`,
  `TCP.post_recv_raw`) had no other user and went, with its tests; patches 17–20 are now
  16–19.
- **In the runtime,** also `TCP.post_list` of patch 11, which only the merge of the
  shards' replies called. The patches after it were regenerated on the fork's branch:
  three only moved lines in `base.bend`, and `comp.ts` is unchanged (97,653 tokens).
  Both of Bend's compiled test lanes pass exactly the tests they passed with twenty
  patches, less the six tests of what went.

What it took off (lines without comments and blank lines): BendKV's code 3,387 → 2,104
(573 → 357 of it written by the script), `server.bend` 697 → 464, laws 45 → 33 (524 →
354 lines), proofs 6,711 → 4,102 (2,028 → 1,576 written by the script), the server's
generated C 1.10 → 0.72 MB, the patches 20 → 19 (436 lines fewer, 255 of them tests).
Code and proofs are each 38% shorter. `make check`, `make verdict`, `make smoke` (the
batch's replies are the same bytes as before), `make test` (about 70 thousand commands
against Redis, robustness, concurrency, the journal, disk failures) pass, and seven
mutations of the code (no APPEND in the journal, a copying GET that answers nothing or
a cut value, hints that change the batch or the log, a journal entry lost on reading,
a FLUSHALL that keeps a key) each break a proof.

Instructions per request (callgrind, 100 thousand keys, 20 clients) barely move with
the shards and the second hash gone: within −0.3…+0.5% at pipeline 16 with the loop
sending. The effect pairs show where they were made for: without a pipeline and with
the writer, 11–14% more instructions than before the rollback, 14–18% more than the
rollback with them kept. In time:

| series | pairs | `new` GET | SET | INCR | `v16` GET | SET | INCR |
|---|---:|---:|---:|---:|---:|---:|---:|
| `redis-benchmark`, pipeline 16, 100k keys, server on one core | 12 | 1.019 | 1.012 | 0.983 | 1.004 | 1.061 | 1.006 |
| `redis-benchmark`, no pipeline, 50 connections, two cores (writer) | 8 | 0.968 | 0.996 | 1.010 | 0.986 | 0.985 | 1.029 |
| memtier GET hits, 1M keys of 100 bytes, pipeline 10, one core | 4 | 1.006 | | | 0.963 | | |
| Redis's specs on two cores: load 1M keys, pipeline 10 | 2 | 1.025 | | | 1.036 | | |
| GET 100 bytes, pipeline 10 | 2 | 0.971 | | | 0.996 | | |
| GET 100 bytes, no pipeline | 2 | 1.003 | | | 1.033 | | |
| GET 10 bytes, pipeline 100 | 7 | 0.949 | | | 0.980 | | |
| INCR, pipeline 10 | 2 | 1.027 | | | 1.039 | | |

(ratios to the code before the rollback, `base`; `new` is the rollback, `v16` the
rollback with the effect pairs kept, to tell their share)

Everything is within ±3%, the noise, but two places: GET without a pipeline loses 3%
(18% more user CPU per request: the effect pairs), and GET of 10-byte values at pipeline
100 loses 5%, on the budget's edge. There all three variants run the same instructions
per GET (3,052–3,092 at pipeline 100) with no more misses; the difference is in the
loop's user time, in how its sends are shared with the writer when many batches come
per step, and patch 16 brings back three of those five points and two of the three
without a pipeline. So the rollback kept to its budget, and the effect pairs belong to
the next round of optimization, together with the send rules (section 10), not as a
second path in the connection. The second hash of each key (for the hints and in
`exec`) does not show in time. The perf baseline is rewritten: 2,972, 3,566 and 3,833
instructions on GET, SET and INCR.

## 3m. Sessions: the state of a connection, proved

The drop-in step starts with the commands of a connection: HELLO (RESP2, with AUTH and
SETNAME), AUTH, SELECT (one database, as Redis with `databases 1`), QUIT, RESET, CLIENT
(ID, GETNAME, SETNAME, REPLY ON/OFF/SKIP, NO-EVICT, GETREDIR, TRACKINGINFO, CACHING,
UNBLOCK, HELP: BendKV has no client tracking and no blocking commands, so those answer
as Redis does when they are not in use), FUNCTION FLUSH (BendKV runs no functions), and
TYPE.

- **Design.** `session.bend` holds a connection's state, `Conn{id, auth, name, mode,
  quit}`, which travels to the actor with each batch and comes back with its replies, and
  the server's, `Srv{pass}`, which the actor keeps next to the database. The parser puts
  every command of a connection or of the server into one command, `Own{op}`, and the
  reads of one key whose reply depends on its value alone into another, `Peek{key, op}`
  (TYPE now; TTL or OBJECT ENCODING later). A proof cannot match with `case _` (section
  8: the goal is not refined), so the 13 lemmas that take a command apart list every
  constructor; a group is one more constructor in each, however many commands it holds.
- **Two paths.** A batch of database commands only, from a client that may run them and
  gets every reply (`S.ready`), runs as before (`exec_batch`, `log_batch`). Any other
  runs a command at a time (`S.gen`): a command after QUIT is dropped, an error the
  parser found is answered as `exec` answers it, a command of a client that must log in
  first gets NOAUTH, a session command runs with the states, a database command with
  `exec`; each reply is sent or held back as CLIENT REPLY says. The parser's batch is
  split at its first `Own` (`B.unzip`, `B.job`), so telling the paths apart costs one
  constructor test that the flattened request already holds.
- **Five laws.** `run_gen`, `run_log_gen`: however the server takes a batch apart, it
  runs it as the general path runs its commands in order (the fast path is the general
  path: same replies, states and database). `gen_db`, `gen_log`: the general path changes
  the database exactly as `exec_all` runs the commands that ran (`S.plan`) and logs the
  effects `exec_log` gives them, so the laws of the commands and of persistence carry
  over. `noauth`: a client that has not logged in, to a server with a password, runs
  nothing on the database but the parser's errors until it sends AUTH or HELLO. The
  proofs (about 700 lines) give the fold of `gen` a plain recursive spec once
  (`gen_spec`) and reason on that; `Cmd`'s 19 constructors are listed three times and
  `SessOp`'s 11 once.
- **Cost.** The first draft cost 10% more instructions per request at pipeline 16, from
  four things the profile named: classifying each command with a borrowed match copied
  its fields (`term_drop` +84 per request); a second constructor in the parser's request
  type added a tag to the flattened request in the parser and in the split (+50);
  curried continuations (+10); and `String.is_empty` takes a packed String apart, a copy
  of its tail (+65 per batch, on the received bytes and on the reply). Fixed: `Own`
  inside `Cmd`; the split by the constructor the request already has; after the actor
  answers, the connection's steps are `@unsafe` defs that call each other and its loop
  directly, with no continuation closures (closure applications −290 instructions per
  request without a pipeline, indirect mispredictions 23 → 15); a `Maybe` for "no
  replies" instead of testing the string; `String.length` for emptiness. Left: GET, SET
  and INCR −0.2%, −0.5% and +0.2% at pipeline 16 (against the perf baseline), GET and SET
  +2.2% and +1.9% without a pipeline (callgrind, 100 thousand keys). In time, four pairs
  over three code layouts each: GET and SET at 1.09 and 1.04 of the code before at
  pipeline 16, 1.01 and 1.01 without a pipeline, all within the noise.
- **Tests.** `tests/session_test.py`: 34 cases byte for byte against Redis 7.0.15 with one
  database, client ids masked. Two differences stay out: HELLO 3 (BendKV speaks RESP2
  alone and refuses it, so clients fall back), and a QUIT while CLIENT REPLY is off, after
  which Redis keeps the connection open and reads nothing more from it (its close waits
  for a reply that never goes out), where BendKV closes it.
- **Redis's suite** now runs on its unmodified harness (which calls FUNCTION FLUSH):
  `unit/protocol` 14, `unit/type/string` 8 (stops at EXPIRE), `unit/type/incr` 9 (at
  RPUSH), `unit/keyspace` 11 (was 7; at RENAME).
- **Not like Redis yet.** HELLO 3; SELECT of any database but 0; for a client that must
  log in, the errors BendKV's parser finds (a syntax error, a number that is not one)
  come before NOAUTH, where Redis checks only the arity and the name first; CLIENT HELP
  and FUNCTION HELP list only what BendKV has; CLIENT LIST, KILL, INFO, PAUSE and TRACKING
  need a registry of clients and their addresses. The password cannot be set yet: CONFIG
  SET and the server's options come next, with INFO and COMMAND.

## 3n. CONFIG from Redis's own table

CONFIG GET and CONFIG SET serve all 178 parameters of Redis 7.0.15 (as distributions
build it, with TLS). `tools/gen_config.py` reads `static_configs[]` in Redis's
`src/config.c`, resolves the constants of its enums from `server.h`, and keeps the
facts in `tools/data/redis-configs.json`; from that file it writes the table in
`src/config.bend`, so the check that the table is current (`make gencheck`) needs no
Redis source. Each parameter carries its type (yes/no, names or bit flags, a number
with its bounds, memory units, percents or octal, a string with its check, or one of
eight with a syntax of their own: save, client-output-buffer-limit, bind,
notify-keyspace-events, latency percentiles and the like), whether it may change while
the server runs, whether patterns skip it, and its other name. BendKV's defaults differ
from Redis's in three: one database, no snapshots, the loopback address.

CONFIG SET runs as Redis's `configSetCommand` does: every name first (an unknown one,
one that cannot change, a protected one and one named twice fail, the first in order);
then every value, checked as Redis checks it and kept as Redis prints it; then what the
new values do; a failure anywhere leaves every parameter as it was. Numbers reach
2^64-1, past what a Nat holds in the runtime, so they stay decimal strings, compared by
length and digit, multiplied a digit at a time, and wrapped around 2^64 as Redis's
`memtoull` wraps a memory value with a unit. Some details came from the differential
test rather than from reading the source: Redis keeps a parameter's other name as a
parameter of its own, so `CONFIG SET replica-priority 1 slave-priority 2` is not a
duplicate and an error names the spelling used; repl-backlog-size never goes below 16 kB;
and the reference build refuses `activedefrag yes`. CONFIG GET matches patterns with a
port of Redis's `stringmatchlen` (classes, ranges, escapes, case aside), checked against
Redis's own on 1,400 random patterns; a run of stars stops as Redis's does once the rest
of the pattern matches nowhere, so a pattern costs polynomial time.

What a value does: requirepass is the password (the session's state holds it next to the
table), hz is capped to 1..500. The port, the addresses, TLS and the append-only file
cannot change while BendKV runs: a new value fails with the error Redis gives when it
cannot apply one ("Unable to listen on this port. Check server logs.", and so on).
The other parameters are kept and read back but tune nothing; BendKV has no eviction,
no replication and no encodings.

Three laws: a CONFIG SET that fails leaves the server as it was; one that succeeds
leaves it with the new parameters, whose requirepass is the password; and after a
CONFIG SET of a parameter that succeeds, a lookup by the same name finds the value its
check gave. The last needs a lemma on lookups after an update (a parameter found by a
name is found again, with its new value; the others keep theirs) and walks the whole
path of CONFIG SET, each decision split with the equation that says what it is.

The test (`tests/config_test.py`) compares all 191 keys of `CONFIG GET *` at start, 146
listed cases and thousands of random values, set and read back on both servers: no
difference. Redis's own `unit/introspection` CONFIG tests (sanity, multiple args,
rollback on a set error and on an apply error, duplicates, immutable, hidden configs,
multiple args of GET) all pass.

**A trap for `--verdict`.** The first version of the pattern matcher took the kernel
from 4 s to 11 minutes. The cause was one function, the class matcher, whose patterns
put literal characters inside a String two levels deep
(`SCon{a, SCon{'-', SCon{z, rest}}}`): in the kernel a Char is a 32-bit word, and a
literal is a decision on its bits, so nested literals multiply decision trees. Telling
the elements of a class apart by comparing bytes (`U32.is_eq`) brought the whole
recheck back to 8 s. A literal at the head of a match costs nothing noticeable.

**Cost.** CONFIG GET of one name walks the table until the name (an early-exit search:
a `Bool.pick` would compute the rest of the walk too): 38k to 85k instructions.
redis-benchmark sends two at its start, which shows in `make perfcheck` as 3 to 6
instructions per request; the requests themselves did not change.

## 3o. Starting as redis-server starts

`bendkv [/path/to/redis.conf] [--name value ...] [-]` starts as `redis-server` 7.0.15
does, so that a Redis configuration file, a command line from a service file and the
test suite's generated configurations start BendKV unchanged. `src/startup.bend` holds
the rules, pure; `src/server.bend` reads the files, changes the directory and writes the
log when they say so. The command line follows Redis's `main`: a first argument that does
not start with `-` is the file; each `--name` starts a line of its own, and the arguments
after it are appended quoted as `sdscatrepr` quotes them, unless the name already came
with a value in the same argument; a `--save` followed by another option or by nothing is
`save ""`; `-` first or last reads the standard input after the file. The configuration
follows `loadServerConfigFromString`: lines trimmed, comments and blank lines skipped,
words split by `sdssplitargs` (the splitter of inline commands in `resp.bend`, reused),
the name lowered, then the parameter's own check (`config.bend`), with the differences
Redis has at start: the words of the line as they are (CONFIG SET splits at each space),
immutable and protected parameters allowed, and nothing done with a new value but hz's
cap. The errors are Redis's, in its report, at the same line of the same file.

Some rules came out of the differential test rather than from a first reading of the
source. Redis appends a newline and the options to the file, so an option's line number
depends on whether the file ends in a newline. Save points add up within the
configuration, the first `save` line taking the defaults away; but a static flag in
`config.c` says whether a file is being read, and the end of an `include` clears it, so
after an include each `save` line replaces the points. `dir` changes the directory at
once, and the includes, the log file and the append-only file after it are found from
there. A directory given as the configuration file reads as an empty one. hz is capped
at the end of each file, while repl-backlog-size is raised to 16 kB only by CONFIG SET.
`dir` and the log needed four effects the runtime did not have: the twentieth patch adds
`IO.chdir` and `IO.cwd` (for `dir` and `CONFIG GET dir`), `IO.pid` and `IO.clock` (the
log's pid and date), and lets `IO.die` with an empty message exit silently, so that a
start that fails says so in the log only, as Redis does.

At start BendKV writes Redis's log lines (pid, role, date in UTC, level), the logo with
its "PID:" when asked, "Ready to accept connections", and on a busy port "Failed
listening on port N (TCP), aborting.": Redis's test suite reads the last two, the second
to try another port. It listens on each address of `bind` with Redis's rules: a `-` makes
an address optional, and an address lost for a reason Redis lets go is a warning. Two
things it cannot do as Redis does. It listens on IPv4 only, so an IPv6 address is let go,
as on a host without IPv6. And it cannot see a client's address, so protected mode with
no password (where Redis takes only clients on the loopback) listens on the loopback only:
`*` and `0.0.0.0` become `127.0.0.1`, other addresses are left out, each with a warning.
Client ids stay one sequence over all the listeners, through a channel they share.

What BendKV cannot do stops the start with a line saying so, rather than a start that
silently differs: modules, ACL users, renamed commands, the background, a cluster, a
replica, TLS, a supervisor it would have to signal; and data it cannot read, an RDB file
(when the data is not in an append-only file) or Redis 7's multi-part append-only file,
since starting empty there would lose data. What it keeps and does nothing with
(databases, snapshots, maxmemory, a Unix socket, syslog) is said once in the log.
`aof-load-truncated no` now stops a start on a file cut short, as in Redis.

`tests/start_test.py` starts both servers on each case: 49 cases Redis refuses (each
type of value, quotes, counts, `dir`, `logfile`, `include`, an error inside an include at
its own line, a busy port, port 0, no address), with the same exit code and report; 32
cases both start, with the same CONFIG GET after; then BendKV's 15 refusals and its own
behavior. The start is pure but not proved; a law could say that a configuration of
parameters gives the table CONFIG SET of them would give, immutable ones aside.

**Cost.** None on requests: `make perfcheck` shows +0.2 to +0.3% against the CONFIG
version (GET 2994 to 3002, SET 3573 to 3583, INCR 3871 to 3878 instructions); the
requests' code did not change, and the counted window holds redis-benchmark's 20 new
connections, which now take their ids from the shared channel.

## 4. Where a request's time goes, and hiding the memory waits

With the eight patches, BendKV ran fewer instructions on GET and SET than Redis, missed
L2 less often and mispredicted fewer branches. Three costs remained, the same for both:

| server CPU per GET, ns (user + kernel) | BendKV, eight patches | Redis |
|---|---:|---:|
| 1 thousand keys | 369 + 431 | 466 + 362 |
| 100 thousand keys | 862 + 384 | 960 + 403 |
| 1 million keys | 1,128 + 406 | 1,209 + 384 |

- **Memory.** The trie always has five levels, so a request runs the same
  instructions whatever the number of keys. The extra user time with more keys is
  waiting for memory: 56–57% of user time at 100 thousand keys and 66–68% at a
  million, for Redis as for BendKV. A miss past L2 costs about 170–250 ns on this VM,
  whose L3 is shared with other VMs.
- **The kernel.** About 0.4 µs per request goes to `select`, `read` and `write`,
  from a quarter of the CPU at a million keys to half at a thousand.
- **Instructions.** What is left: parsing, dispatch, reply, reference counts.

A lookup is a chain of dependent loads (trie node at depth 4, the bucket's first
entry, the key's bytes), so the processor waited for one miss at a time, although it
can keep dozens in flight. A pipelined batch, though, holds 16 independent keys.

**Batch hints** ([`batch.bend`](../src/batch.bend), patch 9). Before a batch runs, BendKV
walks the trie paths of all its keys level by level, and each step only starts loading
the next level with `Mem.prefetch`: first the nodes at depth 4, then the buckets, then
the keys and values of their first entries. The misses of different keys then overlap,
and the batch runs as before and finds its paths in the cache. Valkey 8 does the same
for its batches ("memory access amortization"); Redis 7 does not. A law, `batch_hints`,
proves that a batch run with hints gives exactly `exec_all`'s replies and database,
whatever the hints.

| server CPU per GET, ns (user + kernel) | eight patches | with batch hints | Redis |
|---|---:|---:|---:|
| 1 thousand keys | 328 + 362 | 356 + 372 | 406 + 381 |
| 100 thousand keys | 844 + 400 | 431 + 406 | 1,006 + 412 |
| 1 million keys | 1,156 + 388 | 612 + 406 | 1,256 + 444 |

(Medians over the pairs of the batch-hint series; the eight-patch column comes from
the same series, so it differs a little from the table above.) The hints hide about
85% of the memory waits at 100 thousand keys and 70% at a million. They cost 14–17%
more instructions: a second hash of each key and three walks from the root. With all
keys in the cache, at a thousand keys, that cost is pure overhead: 5–11% slower.

Two traps on the way:
- **Bend drops pure computations whose result is unused,** hints included. The hints
  return a number, and the batch runs in a function whose two branches on that number
  both run `exec_all`. The hints must finish first, and nothing can drop them.
- **Reading the hashes from the batch's commands put reference counts on the keys.**
  A `Cmd` is unpacked into words when a match binds it, and every pointer field read
  from a borrowed one gets a count (`slot_keep`). Each key was sealed that way:
  +180 instructions and atomic operations per request, and only +10…17% at a million
  keys. The connection now hashes the first word of each request as it parses it.

### Where the time goes now

A fresh breakdown after 3h, on another VM (Cascade Lake Xeon at 2.8 GHz, 1 MiB L2 per
core; PERFORMANCE.md 9.7). Functions come from callgrind on a `-g` build, the generated
C's `spin_N` loops are named after the Bend defs they run (`tools/spin_names.sh`), and
`tools/phases.py` sums them by phase of the request.

| server CPU per request, ns (user + kernel), pipeline 16 | GET: BendKV | GET: Redis | SET: BendKV | SET: Redis |
|---|---:|---:|---:|---:|
| 1 thousand keys | 510 + 440 | 510 + 430 | 600 + 430 | 770 + 420 |
| 100 thousand keys | 520 + 370 | 1,070 + 450 | 620 + 470 | 1,220 + 490 |
| 1 million keys | 720 + 430 | 1,460 + 480 | 720 + 450 | 1,520 + 500 |

- With every key in the cache the two servers spend the same: 510 ns of user time per
  GET, and about as many instructions (3,717 against 3,648). At 100 thousand keys the
  hints hide the memory waits entirely, so BendKV's user time is now almost all
  instructions; at a million, ~210 ns of waiting remain (29% of user time).
- The kernel costs both the same, 0.37–0.50 µs per request: 42–46% of BendKV's CPU at
  pipeline 16, and 66–80% for both servers without a pipeline, where one `send` alone
  takes 51–59%.
- **Parsing RESP is 41–45% of the instructions** of a GET or a SET (1,560–2,040 of
  3,717–4,472), and 13–17% of the time against Redis's 2.6%. Reading a 1–2 digit number
  costs ~230 instructions: a `memchr` call for the `\r`, a `String.code_at` per digit,
  and `Nat` arithmetic with overflow checks. No law covers the RESP parser, so it can be
  rewritten in `resp.bend` alone; ~1,000 fewer instructions would be +15–20% at
  pipeline 16.
- **Reads longer than 2 KiB fall off the fast path.** A packed string's chunk holds at
  most 2 KiB (its position takes 11 bits of the term), and `code_at`, `find` and `slice`
  past the first chunk walk the chunks from the start. At pipeline 100 a GET costs 5,649
  instructions instead of 3,717, 2,117 of them in those slow paths. Reading at most
  2 KiB at a time brings it to 3,455, but splits the client's batches and adds system
  calls: GET throughput did not move (0.94–1.08), while a load of 100-byte values gained
  9–30% and its p99 latency fell 2.5–3× (a 64 KiB read was parsed in time quadratic in
  its chunks). The fix belongs in the runtime, keeping one system call per read.
- **The hash is no longer worth chasing:** 135 instructions, 1.1–1.5% of the time, and
  computed by the connection before the trie walk, off the chain of misses. CRC32C would
  save under 1%.
- Without a pipeline, the writer thread costs more than it saves under one client
  thread: waking it through a futex takes 17% of the loop's CPU, and `redis-benchmark`
  gets 67 thousand requests per second instead of 86.

Section 3i takes the next steps this breakdown suggests, one at a time.

## 5. CPU features and the C compiler

Bend compiles its C with `clang -std=c11 -O3`: baseline x86-64, no profile, one
thread. Builds of the same C, measured
([`tools/cc_variants.sh`](../tools/cc_variants.sh), PERFORMANCE.md section 9.6):

| build | instructions, GET / SET / INCR | throughput against clang 19 `-O3` |
|---|---|---|
| clang 18 (`preserve_none` ignored) | +9.8% / – / +8.5% | GET 1.06 → 0.95 of Redis |
| `-march=x86-64-v3` (AVX2, BMI2) | −1.4% / −1.8% / −0.3% | 0.91 / 0.96 / 0.96 |
| `-march=native` (Sapphire Rapids) | not counted (valgrind) | 0.99 / 0.98 / 0.99 |
| PGO | −21% / −24% / −19% | 1.05 / 1.05 / 1.08 over 24 pairs |
| every `INLINE` helper `always_inline` | −16% / −17% / −13% | 0.95 / 1.01 / 1.06; code ×1.6 |
| CRC32C hash instead of FNV-1a | −1.0% / −0.8% / −0.3% | 1.09 / 1.07 / 1.07 over 19 pairs |

- **Vector extensions do nothing here.** The hot code is dependent loads, branches
  and copies of 2–5 words; long strings already go through libc's AVX2 `memcpy`,
  `memchr` and `memcmp`. Even `-march=native` emitted no 512-bit instruction.
- **PGO is the one flag that pays,** mostly by inlining the `spin_*` loops (tail
  recursion turned into loops: RESP lines, bucket search, field reads). Without a
  profile clang leaves them out of line even at four times the usual inline threshold,
  and their results go through memory. Forcing every helper inline cuts three
  quarters of the same instructions but grows the code 1.6 times and loses the time.
- **The hash is latency, not instructions.** FNV-1a over a 16-byte key is a chain of
  16 dependent multiplications (~64 cycles) right before the lookup's first miss;
  CRC32C does 8 bytes per instruction (~13 cycles). Both spread redis-benchmark's
  keys over the buckets the same way
  ([`tools/hash_buckets.py`](../tools/hash_buckets.py)).

## 6. How to measure on a noisy VM

The methods are in [`tools/README.md`](../tools/README.md). The lessons:
- Use more than one load generator. `redis-benchmark`'s lock-step pipelines and tiny
  default values flattered BendKV (1.6–1.8× Redis); Redis's own specs under
  `memtier_benchmark` give 0.90–1.39×, depending on the spec.
- Profile per thread when there is more than one. A wall-clock timer signal lands on
  any thread; the process CPU timer (`ITIMER_PROF`) lands on the thread that is
  running, so `sprof`'s `SPROF_CPU` mode attributes samples to threads. Count each
  thread's CPU ticks from `/proc/PID/task/*/stat` to see which one saturates.
- Compare inside a trial, never across days: absolute throughput drifted by ~15%
  between VMs and up to ±10% between series.
- Count instructions with callgrind for anything below ~5%, then confirm the time
  with many interleaved pairs.
- Expect ±5–10% from code layout alone between builds of the same C. The same flag
  made the server slower and the in-process map benchmark faster. Build each variant
  in several shuffled layouts (`tools/layouts.sh`) and pool them.
- Ratios against one base share its noise: when the base's runs come out slow, every
  variant looks faster by the same margin (section 3i, the load spec). Look at the
  variants against each other as well, and at a variant that cannot matter.
- A pipeline in memtier is not a batch: it sends a new request for every reply, so a
  server's reads can hold fewer requests than the depth, unlike `redis-benchmark`'s
  lock-step batches. A change aimed at one-request batches is not idle at pipeline 10
  there (section 3i, step 4).
- Separate memory from instructions by running the same code at 1 thousand,
  100 thousand and 1 million keys.
- Where the CPU has no performance counters, a timer-sampling profiler
  ([`tools/sprof.c`](../tools/sprof.c)) still gives time shares per function, and
  showed which loads of the trie walk stall.
- Check that the load generator is not the limit: watch its own CPU. One loadgen
  thread is at 60% of its core with pipeline 10, but at 93–97% without pipelining,
  where it caps every server near 180–200 thousand requests a second.
- Nothing else may run during a series, not even a waiting loop: a busy wait on one
  core sank Redis with io-threads to a fifth of its throughput and multi-loop BendKV
  by a third (section 3b), while single-loop servers barely noticed.

## 7. Toolchain traps

- **A new call site can change a hot function's calling convention.** Bend decides
  per function whether a parameter is borrowed or owned, from all its call sites. One
  new caller slowed the single-shard server by 27% through `R.parse` and `KV.hash`
  (section 3b); diffing the generated C function by function found it. A function that
  owns its argument copies a shared node to take it apart, so a walk that comes to own
  a shared trie copies all of it (section 3c).
- **A constant can turn off an optimization everywhere.** A constructor written as a
  constant is allocated statically, and then no match on that constructor anywhere in
  the program rebuilds a node in place: one constant root node made SET 29% more
  expensive (section 3c).
- **clang 18 ignores `preserve_none` without a word,** and Bend's runtime is built
  around it: 8.5–9.8% more instructions. Bend's driver uses plain `clang` unless `CC`
  is set, and on Ubuntu 24.04 that is clang 18. The Makefile sets `clang-19`.
- **valgrind 3.22 cannot decode some `-march` code** (a register-to-register `vmovq`).
- **Transparent huge pages in `madvise` mode** need the program to ask; Bend's heap is
  one big reservation, so one `madvise` covers it.
- **Machine time drifts.** A restarted VM ran BendKV ~15% slower while Redis ran at
  the same speed: BendKV's longer chains of dependent loads make it more sensitive to
  the neighbours sharing the L3.

## 8. Bend2 in practice

What got in the way:
- No `match` on a computed value or a let variable; structural recursion only, no
  mutual recursion; a function can only call functions defined above it. Branches
  become helper functions, and arguments are evaluated strictly, so the parser takes
  fuel.
- Affinity: a hypothesis (`∀k. …` or a refutation `a != b`) can be used once, while
  equalities are data and can be copied. Refutations become equalities of boolean
  verdicts.
- The checker evaluates `Nat` in unary. A constant like 10^14 overflows its stack, so
  INCR's overflow check counts digits; the parser rejects `Nat` literals above
  2^32 − 1.
- No tactics: every rewrite step is written by hand. The proofs are about as long as
  the code, and checking them is fast.
- In a proof, `case other` does not refine the goal: the variable stays abstract ("`c`,
  but not `Get`"), and functions of it do not reduce. Lemmas about commands list all 19
  constructors, most of them as refutations; so commands come in groups (`Own` for those
  of a connection, `Peek` for the reads of one key), one constructor each (section 3m).
- No 64-bit integers, few effects (stock files have no `fsync`; patch 12 adds it), and
  in stock Bend strings are lists. For a database these are the practical blockers.
- A `match` must come before any local statement (a rewrite or a `+x = …`) in its
  body, and only a parameter or a field can be taken apart, so a nested pair
  `(a, (b, c))` needs a helper function for its second level. Literal patterns help:
  `case 10n+m` recurses by tens, and `case 1n++p` binds a duplicable predecessor.
- The compiler drops a pure computation whose result is not used, so a hint for the
  hardware has to feed a value that is (section 4).
- A borrowed match on a type laid out without a box (such as BendKV's `Cmd`) gives every
  pointer field it binds a reference count; the same read from a boxed type is free.
  Classifying every command of a batch that way cost 84 instructions per request
  (section 3m).
- Base's `String.is_empty` matches its String into a head and a tail, which on a packed
  String copies the tail: test emptiness with `String.length`.
- A function compiles into a tight loop of its own only when everything it calls does
  too (`flat_of` in `comp.ts`); and an `@unsafe` def may call any other, so a chain of
  them can replace continuation closures.
- The compiler lays out every non-recursive data type unboxed, so a small record that a
  function returns travels in registers and through stack frames word by word: a parsed
  request (`B.Fit`, eight words) cost more to pass through a non-tail recursion than to
  build. Keeping a list newest first, so that the consumer's tail loop restores the order,
  avoided it.
- The C compiler reads types off annotations: an application chain over a variable drops
  its erased arguments and places the live ones by the head's type, so a term built by a
  compiler pass needs the same annotations the elaborator writes (section 3j).

What helped:
- The theory and the runtime representation are separate ("native kinds"): strings
  became buffers without touching a single proof.
- The C backend is readable, so each runtime idea became a patch and a measurement.
- Checking is fast: about a second for all 38 laws, plus an independent kernel proved
  in Lean.

## 9. What our patches rediscovered

Most of the patches have prior art in functional runtimes that also compile through
C and count references:

| BendKV / Bend patch | prior art |
|---|---|
| lazy seal | one-bit (unique or shared) reference counts: pay for counting only once a value is shared |
| packed strings with list semantics | Lean 4's `String`: a list of characters in the theory, a UTF-8 byte array in the runtime |
| borrowed reads | borrowed parameters in Lean 4 ("Counting Immutable Beans", 2019) and in Koka's Perceus |
| node update in place | Lean's reset/reuse, Perceus reuse analysis, "functional but in-place" programming |
| strings of up to 6 bytes in the term | small-string optimization; Redis's `embstr` and integer encodings |
| strings of one chunk as their buffer | BEAM's reference-counted binaries and sub-binaries |
| digit select | switch-to-lookup-table, at the level of Bend's `match` |
| replies encoded from a reversed list | a workaround for missing tail recursion modulo cons (Koka, OCaml 4.14+) |
| batch hints with `Mem.prefetch` | group prefetching for hash joins (Chen, Ailamaki, Gibbons and Mowry, ICDE 2004), AMAC (VLDB 2015), Valkey 8's memory access amortization |
| shards fed by one multi-channel send | deterministic databases ordering transactions up front, as Calvin (Thomson et al., SIGMOD 2012); shard-per-core servers such as Seastar/ScyllaDB and Dragonfly |
| a writer thread for sends | Redis's io-threads for writes; io_uring's submission-queue polling thread |
| effects logged instead of commands, INCRBY as SET | Redis's command propagation rewrites (INCRBYFLOAT as SET, GETSET as SET); physiological logging in databases |
| one write and one sync for every batch that waited | group commit (DeWitt et al., 1984); Redis's `flushAppendOnlyFile` in `beforeSleep` |
| a request parsed with a proof that its hash fits | proof-carrying code (Necula, 1997), here only for the checker: the proof is erased |
| `IO` binds compiled to direct continuations | the standard compilation of a continuation monad: inline `bind` and `return`, raise the arity of functions that return the monad (GHC's arity analysis and "state hack" for `IO`); compiling with continuations (Appel, 1992) |
| the loop sends while it keeps up | adaptive batching by load, as in interrupt coalescing (NAPI) and Redis 6's io-threads, which stay idle while the load is low |

These are compared in more detail, with what else to borrow, in
[DIRECTIONS.md](DIRECTIONS.md), section 2.

## 10. What each change gave, and what it cost

Every change since the start, the twenty patches to Bend (p1 to p20, numbered as before
section 3l, which took p16 out) and BendKV's own (sections 7.N of PERFORMANCE.md), on one
scale. The gain is the best reliable measurement
on the load the change was made for: time, or, where time stays in the noise (±5–15%),
instructions or memory. The cost is what the change adds to `comp.ts` in `ttok` tokens
(the Bend repository caps the file at 64 thousand; the original has 62,940, with our
patches 97,653), BendKV's lines of code and proof, and what lines do not show: a new
representation of data, threads, heuristics with tuned thresholds, effects at a
distance. The tokens were counted on the patch branch, commit by commit:

| patch | `comp.ts` tokens | patch | `comp.ts` tokens |
|---|---:|---|---:|
| 1. lazy seal | 442 | 10. loops on threads, writer | 3,350 |
| 2. packed strings | 3,232 | 11. `epoll`, `TCP_NODELAY`, `post_list` | 3,625 |
| 3. borrowed reads | 1,648 | 12. raw files, `fsync` | 0 |
| 4a. string natives | 4,327 | 13. `Chan.drain` | 0 |
| 4b. index natives, literal forms | 4,129 | 14. `code_at` of a word string | 39 |
| 4c. strings of up to 6 bytes in a word | 1,728 | 15. the loop shares sends | 1,151 |
| 4d. one-chunk string compare | 372 | 16. effect pairs | 0 |
| 5. node update in place | 925 | 17. the loop sends while it keeps up | 536 |
| 6. 2 MiB pages | 108 | 18. strings read in place | 1,708 |
| 7. digit select | 3,209 | 19. `IO` in continuations | 2,221 |
| 8. string blobs | 1,618 | 20. value reads | 97 |
| 9. memory prefetch | 248 | **all** | **34,713** |

```
          cheap                                  costly
×N        p1 lazy seal, p9 hints,                p2 packed strings
          7.6 16-way trie, group commit
+20-50%   7.7 parse and reply, 7.23 windows, p17 p4a/p4b natives, p8 blobs, p10 writer
+5-20%    p6 2 MiB pages, 7.20 groups            p11 epoll, p4c word strings, p7, p15
noise     clang 19, PGO, p14, p4d, 7.23 RESP,    p5, p16, p18 + 7.24B, p19, 7.22, shards
          p20 + copying GET (3k)                 hash bits in entries (3k, not taken)
worse     iolist                                 hints over a group (taken out),
                                                 a pass through the seal (3k, not taken)
```

- **Large gains, small cost.** Lazy seal: +43–53% with a pipeline, loading ×2, memory −28%,
  for 442 tokens. Batch hints with p9: ×1.5–1.7 at 100 thousand and a million keys, +27–35%
  on Redis's specs, for 248 tokens and ~200 lines of BendKV with a law. The 16-way trie:
  GET ×2.25, SET ×2.1, INCR ×1.6, memory −32%, for +1,380 lines of proof that a script
  mostly writes, under the same laws. Group commit of the journal: `always` ×8.5,
  `everysec` ×2.7 without a pipeline. Parsing and replies (7.7): +12–36%. Long reads in
  windows (7.23): +27% at pipeline 100. Patch 17: +21–26% without a pipeline, though a
  second heuristic on top of patch 15.
- **Large gains, high cost.** Packed strings (×2.2–2.9 with BendKV's buffer IO; 3,232
  tokens, a second representation of `String` across the runtime, `lexer` 1.3–1.7 times
  slower), the string natives (GET +17%, INCR +26%, 1 MB values 3.6–11 times faster; 4,327
  tokens, ~340 lines of C that must agree with Bend's definitions), the index natives and
  literal forms (with 7.7, +12–36%; 4,129 tokens), blobs (GET +25%, memory −20%; a fourth
  representation), the writer thread (+8–36% on two cores; threads, futexes, spinning).
- **Middling gains, high cost.** `epoll` and `TCP_NODELAY` (+10% without a pipeline, +18%
  with one; 3,625 tokens, but `select` cannot go past 1,024 descriptors), strings of up to
  6 bytes in a word (+7–19%, mostly on short values such as redis-benchmark's `xxx`;
  values of 100 bytes do not fit), digit select (+3–9%; 3,209 tokens for a pattern that
  one trie uses), patch 15 (+15–20% without a pipeline; since patch 17 it only runs while
  the loop posts, unmeasured).
- **Little or nothing, at a cost.** The key hashed once (7.22: −1–1.6% instructions, four
  laws and +500 lines of proof, the worst ratio), shards (up to −33% with a pipeline
  against one loop and a writer; +7% without one, +32–52% with a journal; 635 lines and
  ~2,900 lines of proof), node update in place (−10% instructions, time in the noise;
  925 tokens), effect pairs, strings read in place with requests parsed into commands,
  and `IO` in continuations (each 2–17% fewer instructions, time in the noise), iolists
  (up to −30%). Section 3l took out the key hashed once, the shards, the effect pairs
  and the last iolist (`TCP.post_list`). Measured and not taken in 3k: a fourth hint pass through the seal (0.93–0.98)
  and hash bits in bucket entries (~1% at a million keys, 111 places in the proofs).
- **Small gains, cheap.** Besides clang 19, PGO, patch 14 and the like: patch 20 with the
  copying GET (3k), +1.5–2% on GET hits, 2–4% less user CPU, no memory growth from reads,
  for 97 tokens and ~50 hand-written lines with no new law.
- **Simpler code.** Borrowed reads took `find`, `tfind`, `bfind`, `copy` and five lemmas
  out of BendKV (−32 lines of code, −30 of proof) and made 1 MB GETs faster, with the
  same speed otherwise; their cost moved into the compiler, where a new call anywhere
  can turn a hot function from borrowing to owning (four times the hot path got dearer
  for it), and every value a GET read kept a counter cell for good (8 bytes per key,
  section 11) until the copying GET of 3k. Parsing into commands replaced a 24-case proof with a type the checker checks
  at each site (−197 lines of proof). The hints over a group went out with their law.

What follows. The best ratios came from removing a whole class of memory or disk work:
allocations, trie levels, waits on misses, a sync per request; together they cost the
compiler 690 tokens of 34,713. Strings are half the growth of `comp.ts` (17,153 tokens)
and most of the single-core speed. Since 7.22, fewer instructions have rarely meant less
time: the kernel is half of a request's CPU with a pipeline and two thirds without one,
and what paid was work on the path through it (patches 15 and 17) or cutting half the
instructions (the windows). The send rules carry eight constants tuned on one VM and
should become one rule. For upstream, patch 1 is the best ratio, stands alone and fits
the 1,060 tokens left under the cap, so it should go first, before patch 19; patches 5,
7, 15, 4c and 18 are the candidates to drop or shrink (8,721 tokens), but even without
them ~26 thousand tokens remain, so `comp.ts` itself has to get simpler.

## 11. An outside review

A colleague reviewed HEAD 641566c (after 3i, before 3j, sixteen patches) on a laptop
with an i9-11900H under WSL2: correctness (the 45 laws through the BendTT kernel, the
smoke and full tests, disk failures) and speed (memtier, 100 connections, 100-byte
values, keys `local-N`, every GET a hit; `perf` and callgrind profiles).

**Three bugs, confirmed and fixed.** The restore took any failure to open the
append-only file for a missing file: on `EACCES`, an I/O error or no descriptors left, the
server started on an empty database and appended new writes to the old file, whose
values came back at the next restart. Now only `ENOENT` means an empty database; any
other failure stops the start, and so it does in the check of the shard layout, which
had the same flaw. The background `fsync` of `everysec` went unchecked; now a failed one
stops the server, as it already did with `always` (after a failed `fsync` the kernel
may drop the dirty pages, so a later one that succeeds proves nothing; Redis instead
answers writes with `MISCONF` until an `fsync` succeeds). And `tests/robust_test.py`
exited 0 on a failure, so `make test` went on; it exits 1 now. A new test,
[`tests/aof_fail_test.py`](../tests/aof_fail_test.py), breaks the disk under the
journal with an `LD_PRELOAD` shim ([`tests/fail_io.c`](../tests/fail_io.c): reading a
given file fails with `EACCES`, `fsync` and `fdatasync` with `EIO`) in six cases; the
build before the fix fails four of them, the fixed one passes all, and `make test` runs
it.

**Speed there.** On one core BendKV won all six loads in all pairs, 1.20–1.49 of
Redis; on two cores (one shard and its writer against the better of Redis and Redis with
`io-threads 2`) 1.59–1.82 with a pipeline, and 0.92 on GET without one, as in section 1
(1.11 against Redis's 1.22 with `io-threads 2`).

**Memory depends on the sizes.** Our "half of Redis" holds for 3-byte values. A million
16-byte keys on our VM: 61 against 123 MB with 3-byte values (0.50), 183 against 211 MB
with 100-byte values (0.87); the colleague, with shorter keys, measured 0.74 and 1.04
(the latter after a GET run). A 100-byte value costs both the same (a 128-byte blob, or
Redis's `robj` and `sds`); BendKV saves on the entry and the key. And the first GET of a
value added a counter cell to it for good, 8 bytes per key: GET borrowed the trie while
the value went out in the reply, so the entry's field was sealed (`slot_keep`) and stayed
sealed. Since 3k a GET answers a copy, and reads add nothing.

**Copying a reply waits on memory.** In the colleague's profile, about 17% of a GET's
cycles (100-byte values, pipeline 10) were copies in libc: 11.6% the value into the
reply, 5.1% the reply into the send buffer. Our callgrind of the same request (100
thousand keys, a 2 MiB L2 modelled, a `-g` build): 3,466 instructions and 5.1 L2 misses
per GET; the copies themselves take 48 instructions, but `memcpy` takes 1.64 of the
misses, 1.41 of them copying the value into the reply. Copying into the send buffer
takes about 90 instructions and 0.24 misses. So the cost is waiting for the value's
bytes, and the batch hints do not reach them: after its first GET the value's field is
sealed, and `Mem.prefetch` of a sealed field touches only its counter cell; of a buffer,
only its first 64 bytes, while a 100-byte value with its header spans two lines. With
redis-benchmark's 3-byte values, on which most of our numbers were taken, a value is a
word inside the term, with no cell and no buffer, so we never saw it; it also explains
why the hints gained nothing on Redis's "GET, 100-byte values, pipeline 10" spec
(section 1).

**The rest agrees, with one caveat.** Without the hints GET lost 14–16% in every pair.
PGO cut 10% of instructions and 26% of the code, with GET between −19% and +11% and INCR
+6%; `-march=x86-64-v3` and `native` cut 2% of instructions with GET +9–10%. Each of
those is a single build, and two builds of the same C differ by 5–10% in time from code
layout alone (section 6), so they need several layouts (`tools/layouts.sh`). The parser's
share (31% of GET's instructions) predates 3j, which cut parsing and hashing by 22% and
parses requests straight into commands, as the review suggests. BendKV ran at 1.81
instructions per cycle against Redis's 0.94: the hints hide the memory waits.

**Added to the plan**, for values longer than 6 bytes: a hint that reaches the value's
bytes (every line of a buffer, by its size class; for a sealed field, one more pass over
the batch that reads the cell already fetched and hints its buffer), up to 1.4 misses
per GET of a 100-byte value for a few lines of runtime and one pass of BendKV; GET without
sealing the value (the reply encoded while the trie is borrowed, with a law that it is
the encoded reply of `exec`; −8 bytes per key); a part of the hash in each bucket entry,
so that a million keys' collision chains do not cost a miss per foreign key; and one
buffer for encoding and sending, which is worth less than its share of cycles suggested.
Section 3k took them in turn: the copying GET, with every line of a buffer hinted, went
in; the pass through the seal and the hash bits were measured and left out; the shared
buffer is still open.

