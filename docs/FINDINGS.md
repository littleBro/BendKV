# BendKV: what we found

BendKV is a Redis-compatible key-value store written in Bend2, with its core proved
against the laws of [`proof/LAWS.bend`](../proof/LAWS.bend), counted in
[README.md](../README.md#in-numbers). This file sums up what building it and making it fast
showed us. The detailed record, with every table and measurement, is in
[PERFORMANCE.md](PERFORMANCE.md) (performance, section by section) and
[OVERVIEW.md](../OVERVIEW.md) (the project, the proofs, how to run). Where the work goes
next, and why, is in [DIRECTIONS.md](DIRECTIONS.md).

## 1. The result

**Correctness.** Core code (with the parsing of commands, of their times and options,
Redis's pattern matching, several databases, the ranges and bits of strings and
BITFIELD's words of 64 bits), sessions (a connection's state and the server's), batch
hints and an append-only file; handwritten proofs with a specification that they bridge
to (section 3u), and 16-way case splits written by a script
([`tools/gen_trie.py`](../tools/gen_trie.py)): [README.md](../README.md#in-numbers)
counts the lines of each, not counting comments and blank lines, and the laws. Bend
checks the laws in about 14 s; the BendTT
kernel, whose soundness is proved in Lean, rechecks them in a minute. Among them: after
any history, the server restores from its append-only file exactly the databases it
held, and from a file cut by a crash at any byte, the databases it held after some prefix
of its acts (sections 3e and 3x). On about 266 thousand random commands the replies
matched real Redis 7 byte for byte; the versions with the 16-way trie passed about 1,050
thousand more, the current one, with BITFIELD, about 115 thousand. Shards across cores and a key hashed once were built and
proved too (sections 3a–3c, 3g, 3h), and taken out again because they paid too little
for what they cost (section 3l): 38% less code and 38% fewer lines of proof.

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

## 3. The patches to the Bend compiler

All live in [`bend-patches/`](../bend-patches/) (against `bendlang/bend` at `1cce499`,
Bend 2.0.35; [README.md](../README.md#in-numbers) counts them). The first eight switch on
by themselves for programs without GPU calls;
the ninth and tenth work where a program calls them; the eleventh changes every
program's event loop on Linux; the twelfth and thirteenth only add effects; the
fourteenth speeds up `String.code_at` everywhere; the fifteenth and sixteenth work where
a program calls `TCP.post`; the seventeenth adds string functions; the eighteenth
changes how every program's `IO` compiles; the nineteenth speeds up `Mem.prefetch` of
a buffer and `String.take` of a short string everywhere; the twentieth adds the
process's id, working directory and wall clock (section 3o); the twenty-first lays
out a datatype wider than 32 words as a node of its own, in every program (section 3p);
the twenty-second makes `String.order` native, everywhere (section 3zn); the
twenty-third keeps a socket with no room from holding up the writer, where a program
calls `TCP.post` (section 3zo); the twenty-fourth makes `File.truncate` take its
size as a `Nat` and adds `File.sync_dir` (section 3e); the twenty-fifth adds `TCP.watch`
and `TCP.unwatch`, a wait for a socket that puts a message on a channel (section 3zp);
the twenty-sixth fixes the fifth where a field of the node it keeps across a call is
shared before the call (section 3zp); the twenty-seventh adds a socket's addresses,
killing it and channel marks (section 3zs); the twenty-eighth `File.rename` and
`File.unlink` (section 3zv); the twenty-ninth the heap's account and the thirtieth
words outside the heap (section 3zw); the thirty-first has a walker that reads a
tree borrow it from a caller that owns it, in every program (section 3zza); the
thirty-second keeps the string of a value that is a string or else something else as
the string itself, with no node, in every program without GPU calls (section 3zzg);
the thirty-third adds C's doubles, `F64`, run as C runs them, strtod and libm with them
(section 3zzm); and the thirty-fourth lets AddressSanitizer check the heap, in a build
with ASan only (section 3zzp).
The sections before 3l
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
| flat limit (today's 21st) | a datatype whose flat layout is wider than 32 words is a node of its own, instead of that many words in every call, result and frame that carries it | INFO's state in the server's: the actor's calls back from 50–67 words to under 25, and every segment's signature from 67 registers to 24 (section 3p) |
| string order (today's 22nd) | `String.order` compares runs of bytes with `memcmp`, a prefix first, instead of a char at a time through `String.cmp` | ZRANK of a member of 100,000 of one score 76,861 → 9,028 instructions, of their own scores 15,877 → 7,515 (section 3zn) |
| writer hold (today's 23rd) | the writer never waits for a socket: what a socket has no room for, and what is posted to it after, it holds in order and sends once its own epoll says the socket has room; the queue grows by blocks, so a post never waits for room | a client that stops reading holds up only its own replies, not the others', the timers or the accepts (section 3zo); instructions per request as before, within what moves between runs |
| file durable (today's 24th) | `File.truncate` takes its size as a `Nat`, a 64-bit word, not a `U32` (a size `off_t` cannot hold fails with `EOVERFLOW` before the file is touched); `File.sync_dir` syncs the directory that holds a path, as Redis's `fsyncFileDir` | a file of 4 GiB or more cut back to its last whole entry keeps the entries before it, not its size modulo 2^32 of them; a new file's name is on the disk before the first write is acknowledged (section 3e) |
| tcp watch (25th) | `TCP.watch(sock, chan, msg)` puts `msg` on `chan` once the socket has bytes to read or its peer closed it, waiting in the socket's slot as a recv does; `TCP.unwatch` takes it back, `True` if it had not fired; a watch that a stale edge or flag wakes peeks at the socket and waits on when there is nothing to read | a connection whose client waits waits at once for the actor's answer and for its client's bytes or close (section 3zp) |
| spare share (26th) | a field of a node kept across a call (patch 5) that is shared before the call is written back to the node once `term_keep` has wrapped it, so the read after the call and a rebuild that skips the slot hold the shared word, not the raw one the wrap owns | no use after free in the batches that run a command at a time while clients wait; 27 stores in BendKV, all on that path, and the same instructions per request (section 3zp) |
| tcp clients (27th) | `TCP.name` gives a socket's fd and both addresses, `TCP.kill` shuts it down; `Chan.mark` and `Chan.marked` mark a channel with a client's last command and its time | CLIENT LIST, INFO and KILL (section 3zs) |
| file rename (28th) | `File.rename` puts a file in another's place in one step; `File.unlink` removes a name | the rewrite of the append-only file (section 3zv) |
| heap (29th) | `IO.heap` gives what the heap's live values hold and what it has taken, in bytes | `used_memory` and eviction by `maxmemory` (section 3zw) |
| mem cells (30th) | `Mem.touch` and `Mem.cell`: 2^20 words outside the heap that one computation writes and reads | when each key was last used, for LRU and LFU eviction and OBJECT IDLETIME and FREQ (section 3zw) |
| walk lend (31st) | a tail call that gives a walker that reads a tree (it calls itself, takes a tree, builds none of its nodes) a value its caller owns, at its last use, holds the value and drops it after the call, so the walker borrows the tree instead of copying each shared node it reads | KEYS 29% fewer instructions a key, RANDOMKEY 28%, ZRANGE of 10 of 100,000 18% (section 3zza) |
| string variant (32nd) | a datatype with one constructor whose one field is a `String` boxes that constructor as the String itself, told from the other constructors by its tag | a string value takes no node: at a million keys 24% fewer last-level misses per GET, 32% per INCR; SET ×1.08, INCR ×1.03; one word less per key (section 3zzg) |
| f64 natives (33rd) | `F64`, C's double as the two 32-bit halves of its bits, with `F64.read` (strtod), the four operations, libm's functions, the comparisons and the conversions, each a law of base that the C lane runs as C runs it, on the libm it links | GEO's positions, geohashes, cells and distances, Redis's bit for bit on 309 positions and 80 searches; ZADD's scores read by glibc's strtod itself (section 3zzm) |
| heap asan (34th) | in a build with AddressSanitizer alone, `heap_free` poisons the node it frees and holds it in a quarantine of its size class before its free chain hands it out again, so that a read through a stale pointer gets ASan's report and stack; any other build is byte for byte as before | the `sanitize` job (`tools/sanitize.sh`): the server under ASan, UBSan and TSan with no report, and patch 26's bug found again when it is taken out (section 3zzp) |

The ratios in the last column come from different series and drift by ±0.06–0.08
between series; PERFORMANCE.md gives each one with its pairs.

**What they cost.** On the runtime's `lexer` benchmark, packed strings are 1.3 times
slower than lists on one thread and 1.7 times on four: short strings built and taken
apart character by character are their worst case. The other 16 runtime benchmarks
do not change (geometric mean ×0.99). Huge pages add about 0.4 ms to the start of a
short program and 0.4–0.9 s of kernel time to programs whose heaps reach hundreds of
megabytes. The patches grow `bend2/comp.ts` from 62,940 to 104,155 tokens, over the
repository's 64,000 cap, so upstreaming them means making them smaller first. With all
sixteen, the C lane of Bend's own test suite passes exactly the tests it passes with
thirteen, plus the three new ones; with nineteen, its C and JS lanes pass exactly the
tests they pass with eighteen, plus the new one; with twenty, the tests they pass with
nineteen plus the new one on both lanes (`io_stack_fault_trap`, which overflows a 2 GB
stack, once missed the runner's 5 s under load and passes alone in 1–6 s, as before);
with the nineteen of section 3l, exactly the tests they pass with twenty, less the six
tests of what was taken out (`chan_call`, `tcp_post_recv` and `tcp_post_list`, on both
lanes); with twenty-one, exactly the tests they pass with twenty, plus the new one
(`flat_limit`) on both lanes: 1,487 of 1,746; with twenty-two, exactly those,
plus the new one (`string_order`) on both lanes: 1,489 of 1,748 (1,488 in a run under
load, where `io_stack_fault_trap` missed the 5 s again; alone it passes in 1.2 s); with twenty-three, the tests of
`tests/io` pass on both lanes exactly as with twenty-two, plus the new one
(`tcp_post_stall`, which hangs on the C lane without the patch): 231 of 238 (the seven
others need ALSA's headers, build a test that fails to build, or print to two streams in
an order that varies); with today's twenty-four, which changes only the type of
`File.truncate`'s size and adds an effect, the tests of `tests/io` pass on both lanes as
with twenty-three (the one that cuts a file gives its size as a `Nat` now), plus the new
one (`file_durable`): 233 of 240; with twenty-five, the tests of `tests/io` pass on both
lanes as with twenty-four, plus the new one (`tcp_watch`): 235 of 242; with twenty-six,
the C lane of the whole suite passes exactly the tests it passes with twenty-five (734 of
865), plus the new one (`rfc_spare_share`): 735 of 866.

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
read. (The writer also waited on a socket that had no room, so a client that stopped
reading held up every reply queued after its own, and once the ring filled, the loop
too; since the twenty-third patch the writer keeps such a socket's bytes and goes on,
section 3zo.)

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
three io-threads. Three shards reach 816. (A writer serves all of its loop's sockets;
since section 3zo one that has no room no longer holds up the others.)

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
the server loads the file and runs its entries from an empty database, once a check
finds that each of them replays as the file means it (below).

Nine laws ([`LAWS.bend`](../proof/LAWS.bend), section Persistence):
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
  are the cut file, so the server cuts off exactly the leftover;
- `checked_replay`: the start's replay with its check (`A.checked`) gives the databases
  the replay of the laws above gives, whenever the check refuses no entry.

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
covers every file. That test, and `tests/smoke.bend`, once printed a failure and still
exited 0, so `make smoke` stayed green (issue #8): now each check's failure makes the
run exit with 1, `smoke.bend` checks each reply against the one expected, and `make
smoke` also runs each with one kind of check given a wrong expectation
(`BENDKV_CHECK_BREAK`), which must fail it (`tests/smoke_check.sh`).

What is not proved: that the server appends exactly each batch's effects (it groups
batches into one write; that the encoding of a concatenation is the concatenation of
encodings is proved, `enc_cat`), and the decision to cut: that the leftover is the
start of an entry and not garbage, the server learns from the network parser of
`resp.bend` (`cut_short`). For a file cut by a crash, a mistake there could only stop
the server from starting, never change the database.

**Compatible with Redis both ways.** `redis-check-aof` accepts BendKV's files, Redis
7.0.15 loads a BendKV file and serves the same data, and BendKV loads a file Redis
wrote (SELECT moves the focus, lowercase names parse, Redis has already rewritten
GETSET as SET, and the MULTI and EXEC Redis writes around a transaction and around
a key's deletion where a write meets a key whose time had passed are marks: the
commands between them replay in order).

**What the start refuses** (issue #2 of the review of the first commit). The replay
ran every entry and dropped every reply, so a file that parsed as RESP but held an
unknown command (`SXT lost v`), a wrong number of arguments, an argument that did not
read (`SET k v EX abc`), a SELECT of a database not there or one whose number did not
read, was reported restored with those entries skipped, and the entries after a bad
SELECT landed in the wrong database. Now the start replays a file through
`A.checked`: before it runs anything it reads each entry as an act and refuses the
file at the first that would not replay as the file means it: one the parser refuses
(`R.Bad` and a session command's `R.SBad`: unknown commands and subcommands, wrong
numbers of arguments, arguments that do not read), a command of a connection or of the
server (`R.Own` that `file.act` leaves as a command, as it leaves a SELECT, SWAPDB,
MOVE or COPY whose numbers or options do not read), a SELECT, SWAPDB, MOVE or COPY of
a database not there (a start with fewer `databases` than the file names), and a MULTI
inside another or an EXEC without one (a file that ends inside a transaction has it
reverted now, as Redis does: section 3zq). The log names the entry, from 1, the byte it starts at (the file
read again: the first text is let go before the replay) and the parser's error, and
the start stops before it cuts the file or opens it to append, so the file is left
byte for byte as it was. Redis 7.0.15 stops its load at an unknown command and does
not look at the replies of the commands it runs; BendKV does not look at them either,
and refuses more, since neither server writes such entries: both log only commands
that ran. The law `checked_replay` says that the check only decides: when it refuses
nothing, the start holds the databases `A.replay` gives, those `recover` and
`recover_cut` are about. What is not proved: that the check accepts every file BendKV
writes (the tests show it on their files, `tests/aof_check.bend` and every restart of
`make test`); a refusal of BendKV's own file would stop a start, never change a
database.

**A cut at any size** (issue #1). The cut back to the last whole entry went through
`U32.from_nat` and a `File.truncate` of a `U32`, so a file whose whole entries make
2^32 bytes or more was cut to their length modulo 2^32: to nothing at exactly 4 GiB,
while the server served the databases of the whole prefix, and the next start lost
them. The twenty-fourth patch makes `File.truncate` take a `Nat`, a 64-bit word in
the runtime, and `server.bend` passes its count of bytes as it is; a size that `off_t`
cannot hold fails with `EOVERFLOW` before the file is touched. The patch's test cuts a
sparse file to 2^32 − 1, 2^32 and 2^32 + 1 bytes and reads each size back exactly,
with the file's first bytes kept.

**A new file's name** (issue #7). With `always` the server answers only once
`fdatasync` returns, but a sync of a file does not make its entry in the directory
durable: after a crash the name of a file just made could be gone, and the next start
would find no file and serve empty databases. The start now syncs the directory that
holds the file (`File.sync_dir`, the twenty-fourth patch's `fsync` of the directory,
as Redis's `fsyncFileDir`) right after it opens the file to append and before it
serves, at every start (one that stopped on a failed sync of the directory may have
left the file there, not yet on the disk); a failure stops the start.
`tests/aof_fail_test.py` traces the calls through its shim: the file made, its
directory synced, then the first reply, and a failed sync of the directory stops the
start before any reply.

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
a drop-in Redis for one node (OVERVIEW.md, "What next"; [DIRECTIONS.md](DIRECTIONS.md),
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
  database, client ids masked. Two differences stay out: HELLO 3 (BendKV spoke RESP2
  alone and refused it, so clients fell back; it speaks RESP3 since 3zx, which has a test
  of its own), and a QUIT while CLIENT REPLY is off, after
  which Redis keeps the connection open and reads nothing more from it (its close waits
  for a reply that never goes out), where BendKV closes it.
- **Redis's suite** now runs on its unmodified harness (which calls FUNCTION FLUSH):
  `unit/protocol` 14, `unit/type/string` 8 (stops at EXPIRE), `unit/type/incr` 9 (at
  RPUSH), `unit/keyspace` 11 (was 7; at RENAME).
- **Not like Redis yet.** HELLO 3 (as Redis now: section 3zx); SELECT of any database
  but 0; for a client that must
  log in, the errors BendKV's parser finds (a syntax error, a number that is not one)
  come before NOAUTH, where Redis checks only the arity and the name first (as Redis now:
  section 3zu); CLIENT HELP and FUNCTION HELP list only what BendKV has; CLIENT LIST,
  KILL, INFO, PAUSE and TRACKING need a registry of clients and their addresses. The
  password cannot be set yet: CONFIG SET and the server's options come next, with INFO
  and COMMAND.

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
maxmemory, maxmemory-policy, maxmemory-samples, maxmemory-eviction-tenacity,
lfu-log-factor and lfu-decay-time limit the memory and choose what is evicted (3zw).
The other parameters are kept and read back but tune nothing; BendKV has no
replication and no encodings.

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
(databases, snapshots, a Unix socket, syslog; maxmemory too, until it came to limit the
memory, 3zw) is said once in the log.
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

## 3p. INFO, and what carrying its state cost

INFO answers with Redis 7.0.15's sections and fields, in Redis's order, picked as
`genInfoSectionDict` picks them: no argument or `default` is the eleven default
sections, `all` adds the ones per command, `everything` the modules' too, names are
taken in any case and a repeat once, an unknown name adds nothing, and a blank line
separates the sections as Redis's `"\r\n"` does. `src/info.bend` holds the sections,
pure, over three things: the parameters (CONFIG's table), the keys (their count, read
only when the keyspace section is asked for) and INFO's own account (`Info`). That holds
the facts of the start (the system as `uname` names it, from `/proc/sys/kernel`; the
machine's memory; run and replication ids of 40 hex digits from `IO.random_u32`; the
start time and the resident memory then), the shell's last facts (`Live`: the wall
clock, the processor time of the process and of its main thread from `/proc/self/stat`
and `/proc/self/task/<pid>/stat`, the resident memory, the connections taken and open),
the counts (commands, bytes in, bytes out), the instantaneous rates and the size of the
append-only file. The values are BendKV's own where it has them; for what it has not
(replication, forks, scripts, eviction until 3zw, expiry, defragmentation, I/O threads)
they are what Redis shows when it has none of it.

The counts follow Redis's: commands by the batch (the parser counts the requests it
reads), bytes read by the connection, bytes of replies by the actor, all added a batch
at a time. They may pass 2^48, where a `Nat` stops the runtime, so each is two `Nat`s (a
count of 10^12s and the rest). Redis's `serverCron` samples its rates every 100 ms into
16 slots and INFO shows their mean; a cron of BendKV sends the actor a tick every 100 ms
that does the same, so `instantaneous_ops_per_sec` and the kbps fields come out of
Redis's arithmetic (integer rates, the mean of 16, `%.2f` of kilobytes). CONFIG RESETSTAT
clears what Redis's `resetServerStats` clears, and connections count from it on. What
only the shell can see, the connection that asks INFO (or CONFIG RESETSTAT) reads first
and sends to the actor as a message of its own (`Facts`), just before its batch; other
requests carry only their counts.

Commandstats and errorstats came later (section 3s); latencystats stays empty, since
BendKV does not time its commands. `tests/info_test.py` checks 31 ways of picking
sections against Redis (the same sections, the same fields, the same order), the values
that do not depend on the machine or the moment, the keyspace, and the counts after
CONFIG RESETSTAT for the same commands on the same connections.

**Why it first cost a quarter more.** The first version passed every test and cost 28%
more instructions per GET (3,000 → 3,842, in builds with `-g`) and 24% more per SET
(3,584 → 4,454). None of it was INFO's own work; it was how its state got around. A
profile of both versions by function (`tools/phases.py`) showed each cause:

- *Flat records.* Bend lays out a non-recursive datatype flat, up to 247 words: a
  function that takes or returns one takes or returns every word, in registers and stack
  frames. INFO's account is 38 words; inside the server's state it made `Srv` 40 words,
  the actor's group 43, a batch's outcome 47, and the actor's functions took 50–67 words
  each. The widest result (48) and the widest frameless parameter list (67) are the
  signature of every segment of the program, so every jump between segments passed 67
  registers and every return copied 48 words (`WL_FID_EXIT`: 9.6 → 109.5 instructions per
  request). The twenty-first patch lays out a datatype wider than 32 words as a node of its
  own; 32 is the widest flat layout the server had before, so the server of section 3o
  compiles to the same C, byte for byte. 3,842 → 3,611.
- *A shared list taken over.* The batch's requests were counted with `List.length` after
  `B.unzip` had taken the list over, with a `+` binder to allow both. The compiler copied
  the list, `List.length` dropped its copy request by request (300 instructions per
  request in `term_drop`), and every field the executor read from a shared request went
  through a reference count (`rfc_wrap`, `slot_keep`). Counting first, with a borrowed
  walk, while the list was still the connection's own: 3,611 → 3,133. Counting in the
  parser instead of a walk (`P.Batch` has `n`) took 11 more.
- *A borrowed field that escapes.* `srv.pass` returned the password from a borrowed
  `Srv`, which makes its parameter owned, and so `nopass`, `authed` and `ready` owned
  theirs; `S.run`, which still needs the server's state after `ready`, kept
  (`term_keep`) each of its fields on every batch. While those were the password and the
  parameter list, a keep was a count increment. INFO's node, rebuilt on every batch, was
  wrapped in a reference count each time, and the next update copied all its words back
  out (`ctr_own_slow`). `nopass` now compares inside its match, so the state stays
  borrowed, and the size of the replies is read before the answer is filed rather than
  after: 3,133 → 3,081.
- *Wide messages.* INFO's facts in the request (a variant `ReqLive` with the 9 words of
  `Live`) and three more words of channels in each connection's `Link` made a request 21
  words and the step that sends it 33 parameters. Facts as a message of their own, and the
  count of connections in one channel (`Tally`: taken and open) instead of two channels
  and the pid: 3,081 → 3,052. The start's continuations, with two environment reads moved
  into a def of their own, are narrower too: the widest frameless list is now 24 words,
  one less than before INFO.
- *A step called from two places.* A def called from two places is a segment of its own,
  entered through the work loop: the step that sends the batch and takes the answer,
  after the arm with facts and the one without, cost 22 instructions per request; written
  out in both arms, 3,052 → 3,043. Joining the arms with an `IO` step that returns at
  once when there are no facts costs 12 more: its continuation is a closure built on
  every batch.

**Cost.** What remains is +1.1% per GET and +0.8% per SET against section 3o (3,032 and
3,614 with `-g`): the counts (the parser's add and the actor's two-`Nat` sums, ~3 per
request), the request's two more fields, the cron's ticks (more of them per request
under valgrind's slow clock, ~1.5), and ~7 instructions per request in glibc. The facts
read at the start go through the runtime's helper threads, as every file read does, and
the first one makes the process multi-threaded for good, so glibc's cancellable system
calls (`recv`, `send`) take their longer path. A start from a configuration file did so
before (the file is read the same way), and a server that posts its replies has its
writer thread anyway. `make perfcheck`: GET 3,031, SET 3,614, INCR 3,921 instructions per
request, +2.0%, +1.3% and +2.3% over the baseline of 2,972, 3,566 and 3,833 (section 3o
measured 3,002, 3,583 and 3,878). Without a pipeline, where a batch's cost falls on each
request, GET goes from 8,178 to 8,602 (+5.2%) and SET from 8,701 to 9,128 (+4.9%): ~425
instructions a batch, of which ~104 are glibc's, ~250 the connection's path (the answer
is now read in a segment of its own, `conn_ans`, which both arms call; the counts; a
`Link` one word wider) and ~140 the actor's counting, less the ~150 the new `nopass`
saves.

## 3q. COMMAND from Redis itself

COMMAND describes each command BendKV has, and of CLIENT, CONFIG, FUNCTION and COMMAND
the subcommands it has, as Redis 7.0.15 describes them: COMMAND and COMMAND INFO (name,
arity, flags, first and last key and step, ACL categories, tips, key specifications,
subcommands), COMMAND DOCS (summary, since, group, complexity, history, deprecation, the
arguments down to their tokens), COMMAND COUNT, COMMAND LIST with Redis's filters (by
module, by ACL category, by pattern, case aside), and COMMAND GETKEYS and
GETKEYSANDFLAGS, the keys of a command line with their access flags.

Redis does not keep that description in one place: it builds it at its start from
`src/commands/*.json` and rules of its own (ACL categories implied by flags, the
movable-keys flag, a legacy first-last-step range computed from the key specifications,
flags hidden from the reply). Rather than port those rules, `tools/gen_commands.py
--extract` starts a `redis-server` and takes its answers to COMMAND INFO, COMMAND DOCS
and ACL CAT for BendKV's commands, kept in `tools/data/redis-commands.json`; the second
step writes them into `src/command.bend` as data, each entry ready to send, with the key
specifications and categories beside it for GETKEYS and LIST. Redis lists commands and
subcommands in the order of a hash table with a random seed, so no order is Redis's own;
BendKV lists them by name. Its keys of a command line follow Redis's
`getKeysUsingKeySpecs`, and SET's, whose key is read as well as written when the line
has GET, follow Redis's own function for it.

`tests/command_test.py` compares every answer with Redis's, restricted to BendKV's
commands and put in order of names: each command's and subcommand's description and
documentation, alone and together, by other cases of their names, unknown and
impossible names (`get|key`, `config|get|key`); the lists, filtered by every ACL
category and by patterns; the keys of lines of every command, a few thousand random ones
among them; the errors. 601 checks with the default count, byte for byte where Redis's
order is not the hash table's.

**Cost.** None, after a first try cost 0.9%. COMMAND's subcommands first went to the
session as a parsed query of two words, and the widest variant of a datatype sets the
width of all of its values: the session's operations, one word wide until then, became
two, and every parsed command, which holds one, a word wider on its way through the
parser, the batch and the executor (+27 instructions per GET). The operation now holds
COMMAND's arguments as they came, one word, and `command.bend` reads the subcommand again.
`make perfcheck`: GET 3,037, SET 3,620, INCR 3,924 (3,031, 3,614 and 3,921 before).

## 3r. Redis's own test suite

Redis's tests can run against a server they did not start (`./runtest --host --port`),
with options for servers that are compatible without being Redis (`--singledb`,
`--ignore-encoding`, `--ignore-digest`). `tools/redis_suite.py` (`make suite`) runs every
unit of Redis 7.0.15's `tests/unit` that way, on several instances of the server at
once, against Redis and against BendKV, and counts only the tests Redis passes: 1,656 of
the 1,729 that run in this mode (most of the others need `DEBUG`, off by default in
7.0). BendKV passed 124 (7.5%), and 103 of the 256 in the units of what it has (the
protocol, connections, the keyspace, strings, counters, introspection); with the
statistics per command (section 3s), 127 and 106; with SCAN and RANDOMKEY (section 3t),
135 and 109; with times to live (section 3v), 212, and 188 of the 315 in the units of
what it has, `unit/expire` among them; with the sweep of expired keys (section 3w), 213
and 189. Of the rest, 813 stop on a command BendKV does
not have (FUNCTION LOAD, ZADD, XADD, GEOADD, SADD, MULTI, LPUSH lead), 589 never run
because their unit stopped earlier, and 42 fail on COMMAND GETKEYS of commands BendKV
does not have or on RESP3. The unit-by-unit table and the
reasons are in [COMPATIBILITY.md](COMPATIBILITY.md).

The suite found one bug in what BendKV has: KEYS hung the server. Its glob tried, for
each `*`, the rest of the pattern at every later position of the key, remembering
nothing of what had failed, so a pattern that matches nowhere costs a number of tries
exponential in its stars: twenty of them against a key of forty bytes ("Regression for
pattern matching long nested loops") ran for minutes on the database's only thread. (And
since it was written `Bool.or(glob(rest, s), glob(p, tail))`, whose arguments Bend
evaluates both, even a pattern that matched explored every split.) It also lacked
`[...]` classes and `\` escapes.
KEYS now uses the port of Redis's `stringmatchlen` that CONFIG GET and COMMAND LIST had
already (moved into `redis.bend`, where all three reach it): one function with an
explicit mode, Redis's cut-off for a rest that matches nowhere, and Redis's shortcut for
`*` alone. The pattern answers at once; `tests/robust_test.py` times it, and the
differential test draws patterns with classes, ranges, escapes and random bytes.

## 3s. Statistics per command

INFO's commandstats and errorstats count as Redis 7.0.15 counts them. For each command
and subcommand: `calls`, the calls that ran; `rejected_calls`, the calls refused before
they ran (a wrong number of arguments by the arity of Redis's command table, a client
that must authenticate first); `failed_calls`, the calls that ran and answered an error.
For each error code, the first word of an error reply as Redis's `afterErrorReply` takes
it, how many replies had it, and `total_error_replies` in the stats section. An unknown
command or subcommand counts in errorstats only, an error reply counts even when CLIENT
REPLY holds it back, a protocol error counts, and the commands after a QUIT, which never
run, do not; `total_commands_processed` is the calls that ran. BendKV does not time its
commands: `usec` and `usec_per_call` stay 0, and latencystats is empty.

What a request counts as is known where it is parsed: its command and subcommand (from
its name and first argument), and whether the parser found an error in it, and which.
The parser writes it as a code (the command's key, a number below 64, times four, plus 0
for a call that runs, 1 for one refused, 2 for one that fails as it parses) in the high
byte of the request's hash, of which the hints read only the low 20 bits. It also ors
each request's mark, the code and its complement (`code × 257 xor 0xFF00`), into the
word that already counted the batch's requests. When all the requests of a batch have
one code, the marks have each bit of it once, itself or complemented, and the actor
counts the batch (one command, as most batches are) from that word in a few operations,
without a look at its requests; any other batch it counts a hash at a time. A batch's
run (code and count) goes into the newest run the server holds when it has its code, and
the runs go into the entries per command, kept last used first, at the cron's tick and
whenever INFO shows them.

Errors are looked for only where a call may have one: calls the parser refused or
failed, and INCR, DECR, INCRBY and DECRBY, which meet strings that are not integers. A
batch of one code answers a line per call (an integer or an error), so its errors are
its lines that begin with `-`, and a batch whose bytes have no `-` at all (most batches
of INCR; one `memchr`) has none. A batch of several codes walks its replies before they
are encoded. (Since section 3zzb a batch of one code walks its replies too: the commands
of the collections that may fail answer many lines, and a line of a bulk may begin with
`-`.) A batch with a command of the connection or of the server runs a command at
a time, each counted as it runs, so an INFO in the batch sees the commands before it.

Two of Redis's rules showed up only when the counts were compared. Redis refuses a call
(`rejectCommand`) only when it fails the declared arity or authentication, so PING with
two arguments and MSET with a key and no value, which pass their arity (−1, −3) and fail
inside the command, count as failed calls: BendKV takes the arities from the JSON its
COMMAND comes from (`tools/gen_commands.py` writes them into `redis.bend`). And CLIENT
REPLY ON and RESET answer even while replies are off, so a call held back runs with
replies on only when it is a command of the database, whose reply its client never gets.

`tests/stats_test.py` runs the same requests on BendKV and Redis after CONFIG RESETSTAT
and compares commandstats, errorstats and the totals as maps: commands one at a time,
errors one at a time, pipelines of one command and of several with errors among them, a
pipeline over 64 KB (more requests than the word can count, so its hashes are walked),
replies held back by CLIENT REPLY OFF and SKIP, NOAUTH and WRONGPASS, commands after
QUIT, protocol errors, and random pipelines: 40 checks. Redis's own `info-command` unit
now passes too (3 tests).

**Cost.** The first version cost +2.9% per GET and +2.8% per INCR. Each row is the next
step (callgrind, as in `make perfcheck`):

| step | GET | SET | INCR |
|---|---:|---:|---:|
| before (section 3r) | 3,039 | 3,619 | 3,926 |
| the code in the parser's result, runs counted in the parser | 3,126 | 3,699 | 4,037 |
| codes in the hash's high byte, the actor walking the hashes | 3,146 | 3,717 | 4,053 |
| marks or-ed by the parser into the batch's count | 3,075 | 3,653 | 3,997 |
| the account in word operations; INCR's bytes looked at, not its replies | 3,071 | 3,644 | 3,965 |
| a batch's run as one number, not a list | 3,067 | 3,639 | 3,959 |
| the database unshared on the general path | 3,055 | 3,639 | 3,957 |
| the mark in two operations fewer; INCR's check before the account | 3,053 | 3,637 | 3,947 |

What remains, ~+0.5% each: ~12 instructions per request in the parser's loop (the mark,
and the register it keeps busy), ~2 to write the code, ~10 in the actor (the batch's
run and count; for INCR, the `memchr`). Without a pipeline, where a batch's cost falls on
each request, GET goes from 8,605 to 8,699 (+1.1%), SET from 9,133 to 9,273 (+1.5%)
and INCR from 9,447 to 9,671 (+2.4%): ~95–140 instructions a batch, ~60 of them the
account's update (the run, the calls, in counts of two `Nat`s) and the rest the actor's
frames, which now carry the batch's word and tally; INCR's look at its bytes is ~100
more. What the steps between taught:

- Every word the parser's loop carries costs about 15 instructions per request: the mark
  as a field of the parse result and a parameter of the loop cost 31; or-ed into the word
  that already counted, 12.
- A borrowed walk of a batch's replies costs about 30 instructions per reply (`slot_keep`,
  the compare, the step): 31 per INCR. The encoded bytes are one buffer, and `memchr`
  over them costs 2.
- A list held both by the encoder and for a look after it is shared: the encoder reads
  it through reference counts and the last drop walks it (INCR 4,647).
- A run of a held-back call before its run, on a borrowed database, to see its reply,
  made the database a shared value for the whole program: the compiler's ownership
  analysis then took it owned in INFO's keyspace and `KV.size`, the session kept it on
  every CONFIG GET, and the database's root stayed wrapped in a reference count until
  the next write. In a run of GETs (redis-benchmark sends CONFIG GET as it starts) every
  hint and every lookup followed the redirect: 9 instructions per GET in the hints,
  three per hash and pass (`mov; mov; shr $24`). Comparing callgrind's counts per
  instruction of the same machine code in both builds found it. A held-back call runs
  once now.
- The newest run as one number saves a list cell taken and freed on every batch (~4 per
  request under valgrind, whose slow clock lets more batches pile up between ticks).

`make perfcheck`: GET 3,053, SET 3,637, INCR 3,947, +2.7%, +2.0% and +3.0% over the
baseline of 2,972, 3,566 and 3,833, which has stood since before INFO; it is rewritten to
the new counts (`UPDATE=1`), so that the next 3% is measured from here.

## 3t. SCAN and RANDOMKEY on the trie

Redis's SCAN walks a hash table that grows and shrinks as keys come and go. Its cursor
counts the buckets with the bits reversed, so that a key there from the first call of an
iteration to the last is returned whatever the table does meanwhile, possibly more than
once. BendKV's trie never rehashes: it is 2^20 buckets, each the end of a path of five
hex digits of the key's hash. Read with the first digit highest, the paths number the
buckets in order (KEYS's order), and a cursor is the index of the next bucket to read: a
call reads the buckets from the cursor on, each whole, until it has found COUNT keys,
and answers the next bucket's index, or 0 when it read to the end. A key there for the
whole iteration stays in one bucket, and an iteration reads each bucket once, so it
returns the key once, never twice. Keys added or deleted meanwhile may or may not come,
as in Redis. A subtrie that lies wholly before the cursor is skipped without a look
inside, and an empty one costs a step.

COUNT counts keys before MATCH and TYPE filter them, as Redis's COUNT bounds the work
and not the reply; each call but the last returns COUNT keys at least (a bucket read
whole can add a few), so an iteration takes at most keys / COUNT + 1 calls. Redis also
stops a call after 10 × COUNT buckets, for a sparse table; the trie skips empty subtries
for nothing and needs no such bound. The arguments are read as Redis 7.0.15 reads them.
The cursor goes through `strtoul`: a sign and digits up to the end of the string or its
first NUL, 2^64 − 1 at most; a blank first or anything after the digits is "ERR invalid
cursor", and the empty string is 0. (Redis 7.2 reads it with `string2ull`, which refuses
a negative number; 7.0 takes one modulo 2^64.) COUNT is a long long, and less than 1 is
a syntax error; MATCH, COUNT and TYPE come in any order, a later one over an earlier,
and an option without its value is a syntax error. BendKV holds strings only, so TYPE
`string` (any case) keeps every key and any other name none; Redis 7.0 does not refuse
an unknown name either. A cursor means nothing to another server, as between two Redis
servers: BendKV's are below 2^20, and any other, a negative one included, ends the
iteration (for Redis, an invalid cursor is undefined behavior).

RANDOMKEY picks as Redis's `dictGetFairRandomKey` does: from a random bucket on, the
keys of the buckets until 16 are found (past the last bucket, from the first one up to
the random one), and one of them, each as likely. A first version walked down the trie,
taking at each node one of its nonempty subtries, each as likely. It reads 5 nodes, but
a key alone in a subtrie beside fuller ones comes up far more often than the others:
of 1,000 keys and 20,000 picks (a mean of 20 each), the commonest came up 102 times, the
rarest once, and one never. With the window, the rarest and the commonest came up 0.25
and 2.2 times as often as the mean (Redis: 0.30 and 2.25); of 20,000 keys and 400,000
picks, 0.15 and 2.65 (Redis 0.05 and 2.8). A window of 32 keys was fairer still and cost
twice as much. The random numbers are a state in the server, seeded from the hash of
its run id, that each RANDOMKEY moves on by the golden ratio's 32 bits (a Weyl
sequence) and murmur3's finalizer scrambles; so a pipeline of RANDOMKEYs picks anew each
time. RANDOMKEY is a command of the server (R.Own), so its run moves the state;
`own_srv` says so, and the proofs that a client not yet authenticated changes nothing
cover it. In a pipeline of 20,000 from one Python client, a RANDOMKEY takes 7 µs and
Redis's 3.5–5, a CLIENT ID 2 µs on both: about 5 µs of BendKV's own, most of it the walk,
which works out the bounds of the 16 children of each node it passes.

SCAN is a read of the whole database for the laws, as KEYS is: it changes nothing
(`reads_keep_db`, `frame`), any write may change its reply (`disturbs`), and its reply
depends on the trie and not only on what keys read (`keywise`), so the swaps of a batch
leave it out. The proofs that list every command take it as they take KEYS. RANDOMKEY,
a command of the server (R.Own), reads the database and changes nothing in it, as INFO
does.

`tests/keyspace_test.py` compares both with Redis where Redis promises something: the
arguments (37 cursors and 34 command lines, errors byte for byte); full iterations of 0
to 5,000 keys, binary and empty ones among them, with COUNT from 1 to more than the
keys, MATCH and TYPE, whose keys must be Redis's, each once, with the call counts above;
an iteration while another client deletes and adds keys, which must find every key that
stayed; RANDOMKEY on an empty database, on one key, on a few (each of them in 100 picks
a key), on 1,000 (none more than four times as often as the mean), in a pipeline that
empties and fills the database, and inline: 1,012 checks. The differential test draws
SCANs that cover the database in one call and RANDOMKEYs (whether nil, compared), the
statistics test counts them, and the robustness test times SCAN's MATCH with the
pattern that hung KEYS. Redis's own suite: all five tests of SCAN on keys pass (basic,
COUNT, MATCH, TYPE, the guarantee under a load of writes), and all three of RANDOMKEY;
the other twelve of `unit/scan` are SSCAN, HSCAN and ZSCAN. In all, 135 of 1,656 (8.2%),
109 of the 256 in what BendKV has.

**The statistics' codes outgrew a byte.** The keys of INFO commandstats are now
numbered by `tools/gen_commands.py` from the parser's own numbers (the commands by
`cmd_id`, then the subcommands of CLIENT, FUNCTION, CONFIG and COMMAND): 58 of them with
SCAN and RANDOMKEY, 236 codes, close to the 256 of a byte, which the data types to come
would pass. A code now rides in the hash's high twelve bits as a word with six bits set
(there are 924 such words, room for 231 keys): two different words or-ed have seven bits
or more, so the words of a batch or-ed together have six exactly when all of them are
one. The parser ors each request's word into the low twelve bits of the batch's count
word (three operations, where the byte's mark and its complement took five), whose high
twenty bits count the requests: a batch is counted from it up to 1 MB of requests (64 KB
before). The word of a code and the code of a word are generated tables, and the
commands whose calls may fail as they run (INCR, DECR, INCRBY, DECRBY) a generated set.

**Cost.** GET, SET and INCR take 8, 7 and 14 instructions more per request than before
the step (3,062, 3,643 and 3,959; +0.2–0.4%, `make perfcheck` allows 3%); MSET, whose
name goes through `cmd_id` and its one more comparison, 12 fewer (27,028). The tables of
the statistics compile to arrays.

**Found on the way.** DBSIZE folds the whole trie: 15 µs at 40 keys, 256 µs at 1,000
(Redis: 2 µs, a counter), and so INFO's keyspace line. The count of keys will go into
the database when it changes shape, for several databases and for expiry.

## 3u. The database as a record, with its count of keys

Until this step the database was the trie: `exec` took a trie and gave one back. Expiry
and several databases need more beside the keys, so the database is now a record,
`Db{t, n, x, now, rr}`: the trie; how many keys it holds; how many of them have a time
to live; the time at which a batch runs; and a field that is always None (below). x and
now stay 0 until keys can expire. No reply changes, but DBSIZE and INFO's keyspace now
read n instead of folding the trie. In a pipeline of 2,000 DBSIZEs from one client, a
DBSIZE takes 0.15 µs at 40, 1,000 or 10,000 keys; before, 13.9 µs, 214 µs and 1.8 ms;
Redis, 0.30 µs.

**Keeping the count.** SETNX, GETSET, INCR and APPEND read their key before they write
it, so they know whether it was there, and count it when it was not. SET and MSET do
not read the key: they now ask the trie first, with a walk of the same path that
answers a Bool and copies nothing (`KV.has.at`), and count a key that was not there.
Redis also looks the key up before it adds or overwrites it. DEL takes off the keys it
removed and FLUSHALL sets 0.

**Cost.** In instructions per request (`make perfcheck`): GET 3,075 (+22, +0.7%), SET
3,977 (+340, +9.3%), INCR 4,119 (+170, +4.3%). The new baseline of
`tools/perf_baseline.txt` holds these. SET pays for the second walk (120 to 150
instructions) and for rebuilding the record; INCR for the record and its fields passed
through three helpers. Four arrangements cost more:

- **The record flat.** The compiler passes a value whose type is not recursive and
  whose fields fit in 32 words as separate registers. Five fields went through every
  call that passes the database, and GET cost 66 more instead of 22. A field of the
  record's own type (`rr: Maybe<Db>`, always None) makes the type recursive, so the
  record is boxed and passed as one pointer.
- **The presence walk beside the write.** `KV.set.at(String, t, k, v, h)` and
  `KV.has.at(String, t, k, h)` as sibling arguments share the trie between the two
  calls, and the write then copies its path: 12,500 instructions per SET. The walk
  must run first, on a lent trie, as a local of its own.
- **One walk that answers both.** A write that also answers whether the key was there
  returns a pair at every level of the path: 211 instructions more than the two walks.
- **INCR through a type of its own.** An `Inc` type with `Bool.pick` over its two
  outcomes cost 4,153, against 4,115 to 4,120 for the three helpers, which match on
  the old value and on whether the sum fits.

**The proofs.** The laws spoke of `exec` on a trie, and most of them still do: their
proofs stay as they were, about the old `exec`, which is now a specification of the
commands on the trie alone (`proof/SPEC.bend`). A bridge (`bridge_go`, a case per
command) proves that the server's `exec`, on a record that holds the trie t, answers as
the specification does on t and leaves the trie it leaves. DBSIZE is the exception: its
reply is the count. The trie part holds for every command (`bt`). Through the bridge:

- the laws about what keys read (`frame`, `del_effect`, `commute_reads`, `swap_reads`)
  follow from the specification's;
- the laws about replies (`get_after_set`, `del_one_count`, `commute_reply`,
  `swap_replies`) follow too. `commute_reply` takes DBSIZE, KEYS and SCAN apart: only
  reads leave them alone, and a read changes nothing. `swap_replies` already excludes
  them from the rest of a batch (`keywise`), so a batch of the others answers as the
  specification's batch.

The laws about the whole database are proved on the record directly, the count with
them: reads keep it (`reads_keep_db`), and so do the batch, persistence and session
laws. Three laws now say how the count changes: APPEND, SETNX and INCR of a key that was
missing count it (`append_effect`, `setnx_missing`, `incr_missing`). One new lemma
carries the counting: the walk that answers a Bool says whether the key reads as a value
(`has_at_eq`; a generated induction on the depth, `tget_kh_eq`). It is also why INCR's
effect in the append-only file, SET of the sum, counts the key as INCR did. A
fine point: DEL of no keys leaves the count as n − 0, which is n only once n is split
into 0 and a successor.

Not proved yet: that the count is the trie's size. That needs a well-formed trie, with
each key at most once in its bucket: `bdel` removes every entry for its key, so a
duplicate would make the count drift. It also needs the arithmetic of a sum over 16
children. The proof will come with the count of keys that can expire. (Proved since,
both counts together: section 3zzf.)

## 3v. Keys that expire

**What it does.** BendKV has Redis 7.0.15's times to live: EXPIRE, PEXPIRE, EXPIREAT and
PEXPIREAT with NX, XX, GT and LT; TTL, PTTL, EXPIRETIME, PEXPIRETIME; PERSIST; SET with
NX, XX, GET, EX, PX, EXAT, PXAT and KEEPTTL; SETEX, PSETEX, GETEX and GETDEL. Their
arguments are read as Redis reads them: a time is a long long as `string2ll` reads one,
a time in seconds that overflows once in milliseconds is Redis's error, and the options
are read as `parseExtendedStringArgumentsOrReply` and
`parseExtendedExpireArgumentsOrReply` read them, with the same errors in the same order.
In Redis's test suite the step made 77 more tests pass (212 in all): `unit/expire` passes
54 of the 59 that Redis passes (the other five need replication, LPUSH, TIME and the
sweep of section 3w), `unit/type/string` 41 of 77 (the rest need GETRANGE, SETRANGE, the bit
commands, LCS, MSETNX or other types).

**The model.** An entry of the trie holds its key, its value and the time it expires at,
in ms since 1970 (0: never). The record of section 3u counts the keys with a time
(INFO's `expires`) and holds the time its batch runs at, which the database actor takes
from the clock before each group of batches. A key whose time has passed is there for no
command: GET answers nil, EXISTS does not count it, SETNX sets it anew, KEYS, SCAN and
RANDOMKEY skip it. No read deletes it: its entry stays until a write sets the key again
or deletes it, and DBSIZE counts it until then. Redis deletes such a key when any
command comes to it, and in a sweep from its cron; BendKV's sweep came with the next
step (section 3w). Reads that change nothing keep the laws of reads (`reads_keep_db`)
and of commuting commands as they were.

**Fourteen digits.** BendKV's integers have at most 14 digits, since a Nat holds
2^48 − 1, and so do its times: a time from 1970 at or past 10^14 ms (the year 5138)
gives a key no time at all, as it would never come, where Redis keeps any int64. A short
time is read digit by digit as a Nat (14 digits at most, no leading zero), a long one as
a decimal kept as hi·10^9 + lo, so that Redis's checks near 2^63 come out exactly. The
bound never appears as a number: neither the code nor the proofs build 10^13 or 10^14;
they count digits instead. The checker unfolds a number literal one successor at a time,
and a proof that meets 10^14 does not finish. (INCR and its kin add Redis's long longs
since section 3zzv; times keep the bound.)

**Updates, and the changes they make.** A command that reads one key and then writes it
(SETNX, APPEND, SET with options, GETSET, GETEX, GETDEL, EXPIRE and its kin, PERSIST) is
one command for the laws, an update: from the key's entry as it stands at now it
computes its reply and a change (none, delete, set the time alone, put a value with a
time, put a value and keep the time, append), and the database makes the change where
the key lies, after one walk to it. A new command of this kind is one update more, with
no new case in most proofs. The append-only file logs the change rather than the
command, as a command that makes it again at time 0, when no key has expired: DEL,
PEXPIREAT with the absolute time, PERSIST, SET or SET with PXAT, SET with KEEPTTL,
APPEND. Every time it names is absolute, so a file means the same whenever it loads;
Redis also logs absolute times.

**The proofs.** The map's laws are now about entries, for its four writes (a value with
a time, a value that keeps the time, the time alone, a deletion), and a read sees a key
until its time: 11 laws, the axioms of finite maps for each write. Five laws of commands
are new: an expired key is there for no command (`expired`), PTTL answers the time left,
SET with KEEPTTL keeps the time, PERSIST takes it away, GETDEL answers and deletes.
Histories carry time: each batch runs at its own, and recovery gives back the database
at time 0 (the server sets its time again before its next batch). Recovery rests on
three facts. A change a command makes is a good one (`upd_good`): it deletes a key, sets
its time alone or keeps its time only when the key is there; it takes a time away only
from a key that has one; and a time it gives is one a key may keep. A good change is made again by its
effects at time 0 (`ch_replay`), because what Nat.show writes of such a time the parser
of times reads back (`num14_show`, by induction on the digits Nat.show writes, with fuel
that runs out counted as too many digits). And a command leaves the time it ran at
(`exec_at`), so a history's commands, run each at its own time, leave its database
(`single_cmds`), and the first k entries of a file cut short leave the database of its
first j commands, at time 0, for some j.

**Exact replay.** The laws hold for any database, also one whose entries hold times no
command gives (10^14 ms or more). So the map keeps a time as it is given, the commands
clamp the times they give, and a change that keeps a key's time is logged as SET with
KEEPTTL or as APPEND, which keep the time on replay too. Logged as SET with PXAT and the
old time, as a first version had it, a far time came back as none, and the count of keys
with a time with it.

**What it cost, and what did not pay.** In instructions per request (`make perfcheck`):
GET 3,082 (+7, +0.2%), SET 4,024 (+47, +1.2%), INCR 4,171 (+52, +1.3%) against section
3u's; `tools/perf_baseline.txt` holds the new numbers. An entry has a field more, and SET
and INCR count the keys with a time.
- **INCR as an update.** The first version ran INCRBY as an update too, one path for the
  server and the file: 8.8% more instructions per INCR (4,482 against 4,119). INCRBY
  keeps its own path in the server; the file runs it as the update `UIncr`, and a lemma
  (`incr_upd_eq`) proves the two the same, so the persistence proofs see one kind of
  write.
- **A recursive type for updates.** `UGet` (SET's GET option, and GETSET) holds an
  update, so the type of updates is recursive and the compiler makes an update a node of
  its own. A command travels in registers as wide as its widest form, and an update's
  options are many: flat, they would have widened every command (the record's `rr` does
  the same for the database, section 3u).
- **A proof the checker could not hold.** A pair of proofs written in place, `({==}, e)`,
  for a pair of equalities ran the checker out of memory; the same pair with its first
  half a named lemma checks at once.

## 3w. The sweep of expired keys

Redis deletes a key whose time has passed when a command comes to it, and in a sweep
from its cron, ten times a second: it samples keys with a time, deletes the expired ones,
and goes on while more than a tenth of what it sampled had expired. BendKV's database
actor sweeps at each tick of its cron, also ten times a second, when some key has a time
(the record counts them, section 3u). A round scans the trie
from where the last one stopped, 400 entries at most, for keys whose time has passed (the
scan of SCAN and RANDOMKEY, section 3t, with one more mode), and deletes them with DEL at
the group's time, a batch like any other: the append-only file logs it, as Redis logs a
DEL for each key it expires, so the laws of persistence cover the sweep as they cover
any batch. While a round finds expired more than one in ten of the entries it read,
another goes on, ten rounds at most. INFO's `expired_keys` counts the keys the sweeps
deleted (CONFIG RESETSTAT counts them again), and `unit/expire`'s "Redis should actively
expire keys incrementally" passes: 213 tests in all.

**What is proved.** The keys a scan finds are checked again before DEL runs: a filter
(`R.reap.keys`) keeps only those that are not there at now. One law follows
(`reap_keeps`): whatever keys the scan found, the sweep deletes no key that is there.
A key that is there is none of the filter's keys (key comparison is equality, and an
equal key is there too), so DEL leaves it as it was (`frame`). The proof is four lemmas;
the scan itself needs none, as nothing is proved of what it finds.

**Cost.** None on a request's path: `make perfcheck` gives GET 3,086, SET 4,022 and INCR
4,172 instructions (+0.1%, 0.0%, 0.0% against section 3v's). A sweep that finds nothing
reads at most 400 entries ten times a second. The first version swept at every tick,
keys with a time or not, and `make perfcheck` counted 14–19% more instructions per
request: under callgrind the server runs some fifty times slower while its cron still
ticks ten times a second, so each sweep's 400 entries fell on that many fewer requests.
In a database with no key that has a time, a tick now reads nothing.

## 3x. Several databases

**What it does.** BendKV holds Redis's databases: 16, or as many as `databases` says
(fixed at the start, as in Redis). SELECT, MOVE, SWAPDB, FLUSHDB and FLUSHALL (with ASYNC
and SYNC, which empty at once) answer as Redis 7.0.15 does, errors included: a number is
read as Redis's `getIntFromObjectOrReply` reads one, so `01`, `+1` and `1.5` are no
integers, a long long past an int is out of range with Redis's bounds in the error, and
SWAPDB names its own errors. A connection starts on database 0, and RESET selects it
again. INFO's keyspace has a line for each database that holds keys, and the sweep of
expired keys goes over every database with a key that has a time, a cursor for each.

**The model.** The databases are a zipper (`R.Ds`): the database in focus, those before
it (the nearest first) and those after it. A command of one database runs on the focus
exactly as it ran on the lone database before, and the actor moves the focus to a
connection's database before it runs the connection's batch (one comparison when the
focus is there already). A batch runs at the focus's time: a database that leaves the
focus keeps the time it last ran at, and one that comes into focus takes the focus's.

**MOVE in two steps.** Redis's MOVE deletes the key's entry in the target database when
the key's time has passed there, then moves the key when the target holds no entry for
it. BendKV runs these as two acts: a purge, which deletes such an entry, and the move
proper, which moves an entry, its value and its time, only to a database that holds no
entry for the key at all. Each step is one effect in the append-only file and means the
same whenever it runs, and a crash between the two restores the databases the first
left.

**The file.** An effect is located (`A.Eff`): a command's on the database it ran on, and
SWAPDB, MOVE (from the database the key leaves) and FLUSHALL. The writer remembers the
database the file selected last and writes a SELECT before the entries of another, as
Redis does, and SWAPDB, MOVE and FLUSHALL as Redis writes them. On load a SELECT moves
the replay's focus, and every other entry acts as the server acted. `redis-check-aof`
accepts the file, Redis 7.0.15 loads it into the same databases, and BendKV loads
Redis's.

**What is proved.** The laws of persistence are stated over several databases and proved
again: after any history, each batch at its own time and on any database, the server
restores exactly the databases it held (at time 0), and a file cut anywhere restores the
databases after some prefix of its acts. The replay keeps an invariant with the
server's databases (`Inv`): every database reads the same at time 0, the replay's focus
is the database the file selected last, and its time is 0. An act with no effect leaves
every database reading the same at time 0 (a moved focus, a SWAPDB, MOVE or purge that
did nothing, a command that wrote nothing); an act with an effect does to the replay
what it did to the server's databases, the replay moving its focus first when the file
selects another database (`act_inv`, a case for each kind of act). The lemmas see a
zipper's databases at time 0 as a list: a focus replaced is a database put at its number
(`zput`), and a database picked into focus at the time now reads at time 0 as it did
(`zpick0`). The numbers the file names read back as written, since the databases are
1 + n with n of 14 digits at most, the law's hypothesis (Redis's `databases` is an int).
For a cut file, the whole entries in front of the cut replay as the first effects (a
SELECT cut off from the entry after it moves the focus alone, which changes no
database), and those as the first acts, an act having one effect at most. Five new laws
say what the acts do, at time 0: SELECT changes no database and focuses the one it
names, SWAPDB puts each of two databases in the other's place, FLUSHALL empties them all,
and MOVE takes a key's entry out of the focus and sets it, its value and its time, in the
other database. 58 laws; about 1,260 lines of proof more (6,141 against 4,885), `make
check` in about 4 s, `make verdict` in about 40 s.

**What the tests found.** The differential test now moves between databases 0 to 3,
moves keys between them and swaps them, with bad numbers among them, and found one
difference: a number past an int (`SELECT 2147483648`) was "not an integer" to BendKV,
where Redis answers "value is out of range, value must between -2147483648 and
2147483647". The numbers are now read as Redis reads them, through the long long reader
of section 3v.

**Cost.** In instructions per request (`make perfcheck`): GET 3,141 (+55, +1.8%), SET
4,070 (+48, +1.2%), INCR 4,226 (+54, +1.3%) against section 3w's, for the zipper around
the focus and the focus moved to a connection's database before each batch;
`tools/perf_baseline.txt` holds the new numbers. Redis's test suite now runs with all
its databases (without `--singledb`): BendKV passes 219 of the 1,673 tests Redis passes
(213 of 1,656 before) and 195 of the 325 in what it has. Of the 17 tests Redis passes that
need several databases, it passes 6. Of the others, 10 need COPY, MULTI, WATCH, Lua or
lists, and one,
MOVE's basic test, passes alone but in its unit counts a key that earlier tests left,
since the test that would have emptied the database stops at XADD
([COMPATIBILITY.md](COMPATIBILITY.md)).

## 3y. Ranges and bits

**What it does.** GETRANGE (and SUBSTR, its old name), SETRANGE, GETBIT, SETBIT, BITCOUNT
and BITPOS answer as Redis 7.0.15 does, errors included, each where Redis gives it:
GETRANGE reads its range before it looks for its key, BITCOUNT and BITPOS read theirs
only once they find the key (so BITCOUNT of a missing key answers 0 whatever stands where
the numbers should), and BITPOS reads its bit first. A number is a long long, as
`string2ll` reads one; a range counts from the end below 0 and is cut to the value, in
bytes or, with BIT, in bits; BITCOUNT answers 0 at once for a range of two numbers below
0 whose start is after its end, and BITPOS treats a 0 sought with no end given as found
just past the value. SETRANGE and SETBIT pad a value with zero bytes and refuse one past
512MB (`proto-max-bulk-len` at its default: BendKV keeps a new value of that parameter
but does not apply it, as before).

**A command stays a word wide.** The compiler lays a datatype out flat unless it is
recursive, and a parsed command travels in registers as wide as its widest form (section
3q). A range is two long longs: kept as numbers, GETRANGE's would have made every command
three words wider. So GETRANGE, BITCOUNT and BITPOS keep their arguments as they came, one
word, and exec reads them again; the parser checks GETRANGE's first, as Redis does before
it looks for the key. GETBIT's offset is one Nat, SETRANGE's and SETBIT's ride in the
update, already a node of its own. Exec keeps a number of a range as a place: 2^41 plus
the number, whose magnitude is cut at 2^40, more than any value's length in bits. That
changes no answer once the case Redis answers early (both below 0, the start after the
end) is decided on the numbers themselves. A Nat literal is a 32-bit word at most, so
2^40 and 2^41 are products, and so is SETBIT's bound, 2^32.

**The file.** SETRANGE logs the SETRANGE of the bytes it wrote, not the value, as APPEND
logs APPEND; SETBIT logs the SETRANGE of the byte that holds its bit, so a SETBIT on a
bitmap of a megabyte costs the file a few bytes, as in Redis, where it logs the SETBIT.
A new change (`R.CRange{off, s, v}`) makes it. It is good (`GoodRange`) when a SETRANGE of
s at off would change the key (`R.range.go`: s is not empty and the value stays within
512MB) and v is the old value with s at off; its effect, run at time 0, then makes v again
(`range_replay`), and its entry parses back to itself, since the offset has 14 digits at
most (`num14_show`, as for times). SETBIT computes its change as SETRANGE's of the new
byte, so it is good by the same lemma; a SETBIT whose bit was already so, in a value long
enough, changes nothing and logs nothing. A key that is not there is made with SET of
its new value, so a key whose time passed meanwhile starts anew on replay as it did.

**What is proved.** The laws of persistence hold for the new updates with no change to
their statements: the change of every update is good (`good_none`, `good_some`, a case
each more), and the lemmas of a change (its frame, its bridge to the specification, its
time) take a case each, as APPEND's. One new law, `setrange_effect`: SETRANGE of a key
there writes s at the offset, keeps the key's time and answers the new length. 59 laws;
about 100 lines of proof more (6,238 against 6,141).

**What the tests found.** Nothing to fix: about 200 cases by hand at Redis's edges
(numbers past a long long, ranges in both directions, units in any case, offsets at
2^32 and 512MB) and the differential test, which now draws ranges, offsets and bits,
138 thousand commands, answer as Redis byte for byte, and so do INFO's statistics of the
new commands (their calls, the calls that fail, the errors). The commands that read their
range as they run (BITCOUNT, BITPOS) and SETRANGE, which fails past 512MB, have their
replies looked at for errors (`RISKY` in `tools/gen_commands.py`).

**Cost.** None: GET 3,137, SET 4,069, INCR 4,223 instructions per request (`make
perfcheck`), against 3,141, 4,070 and 4,226. The new names lengthen the parser's chains
for names of 6 and 8 letters only, and the session commands moved from number 40 to 100,
to leave the database's commands room. INFO's statistics now have 80 keys, 324 codes of
the 924 words of twelve bits with six set: room for 230 keys, fewer than Redis's commands
and subcommands, so the codes will need more bits before the data types are all in.
Redis's test suite: BendKV passes 268 of the 1,673 tests Redis passes (219 before) and
244 of the 370 in what it has: unit/type/string 60 of 77 (41 before), unit/bitops 30 of
45 (0 before). The others there need LCS, MSETNX, BITOP, BITFIELD, other types or
replication ([COMPATIBILITY.md](COMPATIBILITY.md)).

## 3z. TOUCH, TIME and OBJECT

TOUCH counts the keys that are there, as EXISTS does: Redis's TOUCH also updates a key's
time of last access, which BendKV did not keep then (it does since 3zw). TIME answers the time the batch runs at,
the clock read once for each group of batches, in s and µs (to the ms). OBJECT answers
what Redis keeps beside a value from the value itself, since BendKV keeps no encoding and
no access times: ENCODING as Redis 7.0.15 encodes a value set whole (`int` for a long,
`embstr` up to 44 bytes, `raw` past them), where Redis answers `raw` for a value made by
APPEND, SETRANGE or SETBIT whatever it holds; REFCOUNT 2147483647 for the integers 0 to
9999 that Redis shares, unless `maxmemory` is set with an LRU or LFU policy, judged by the
current parameters where Redis judges when it makes the value; IDLETIME and FREQ 0, each
refused under the policy Redis refuses it under, with Redis's errors (since 3zw they
answer from when the key was last used). TIME and OBJECT are
commands of the session (they read the clock, the parameters and the selected database),
so they change no database and the proofs of sessions take a case each for them, as for
the other session commands. OBJECT counts in INFO's statistics by its subcommands, as
CLIENT and CONFIG do, and FREQ and IDLETIME, which fail as they run under one policy or
another, have their replies looked at for errors.

**Cost.** INCR 4,235 instructions per request (+9, +0.2%): TIME lengthened the chain of
names of four letters, INCR's. GET 3,138 and SET 4,068, the same. Redis's test suite:
BendKV passes 272 of the 1,673 tests Redis passes and 248 of the 370 in what it has (TOUCH's
two tests, a PEXPIREAT at a time TIME gave, and INCR's shared integers seen by OBJECT
REFCOUNT); one test now fails on the time of last access rather than on a missing
command.

## 3za. MSETNX and RENAME: commands whose writes read other keys

MSETNX sets its pairs only when none of its keys is there (and answers 0 otherwise);
RENAME moves its source key's entry, its value and its time, to the destination,
whatever the destination held; RENAMENX moves it only when the destination is not
there. The errors and the replies for a key renamed to itself are Redis 7.0.15's ("no
such key"; OK, and 0 for RENAMENX).

**They broke a lemma the commuting laws stood on.** The laws said two commands on
different keys commute, and their proof rested on "a command changes a key only as a
function of that key's entry" (`point_cmd`): with frame, it gives that a key written by
at most one of two commands reads the same after both orders. RENAME changes its
destination as a function of its source, and MSETNX's verdict for each key depends on all
of its keys, so a key written by one command can still read differently after the other:
SET s 1 then RENAME s d leaves d = 1, RENAME s d then SET s 1 leaves d as s was. The fix
is a set of keys per command, `deps` (MSETNX's keys, RENAME's two), whose entries its
writes depend on besides the key written: `point_cmd` now holds of two tries that agree
on `deps(c)`, `commute_reads` takes the hypothesis that neither command writes a key the
other's writes depend on (`spoils`), and `clash`, which says when two adjacent commands
of a batch may not trade places, includes it. For every older command `deps` is empty,
and their proofs only take one more, ignored, argument. The induction that carries the
agreement through the rest of a batch now proves agreement on a list of keys at once
(the deps of each command, from the run before it, and the keys asked), since the per-key
version would have needed mutual recursion, which Bend refuses.

**A pair of proofs that can be used twice.** The agreement on a list of keys is a type
built by recursion on the list, a pair of an equality and the agreement on the rest. The
induction passes one agreement to every key of a list, so it must be reusable (`+`),
that is, of kind Data. `A & B` is Bend's `Pair`, `Sigma<&1, &1, A, _ => B>`, a Type;
`Sigma<&2, &2, A, _ => B>` is the same pair at kind Data, and equalities are Data, so
the agreement is spelled with it.

**The log.** MSETNX logs the MSET of its pairs when it set them, nothing otherwise.
RENAME, and RENAMENX that moved, log `RENAME src dst`, which replays at time 0 as it ran:
the entry RENAME found there at now is there at time 0, and RENAME does not look at the
destination. RENAMENX is logged as RENAME because replayed at time 0, a destination
whose time had passed would read as there, and the RENAMENX would fail. The replay is the
same code path on the same trie, so the counts of keys come out the same. Three laws pin
the commands down: `rename_effect` (the source is gone, the destination holds its entry,
the reply is OK), `msetnx_present` and `msetnx_missing`: 62 laws.

**Cost.** GET 3,144, SET 4,070 and INCR 4,229 instructions per request (the baseline's
3,141, 4,070 and 4,226): the same. Redis's test suite: BendKV passes 285 of the 1,673
tests Redis passes (17.0%) and 261 of the 370 in what it has; unit/keyspace 35 (was 27),
unit/type/string 65 (was 60). The differential tests ran about 120 thousand commands with
MSETNX and RENAME among them, every reply identical to Redis's.

## 3zb. COPY: a key copied, to another database or within one

COPY sets its destination to the source key's entry, its value and its time, in the
selected database or in the one DB names, when the destination is not there or REPLACE
is given, and answers 1, else 0. Its options are read as Redis 7.0.15 reads them, word
by word: REPLACE and DB in any order and case, DB's number as SELECT's (with Redis's
errors for one out of range or no integer), a syntax error for any other word, and
"source and destination objects are the same" for a key copied onto itself in its own
database.

**An act of several databases.** COPY reads the selected database and writes another,
so it is not a command of one database (`exec` runs on the focus alone) but an act, as
MOVE is: `ds.copy` reads the source's live entry in the focus and the destination's in
the target, and puts the target back with the entry set. The session reads the options
and checks that source and destination differ before the act, so that the act has no
error to give.

**The log.** A COPY that copied is logged after a SELECT of the database it copied from,
as `COPY src dst DB n REPLACE`, whatever the client sent: replayed at time 0, a
destination whose time had passed would read as there, and a COPY without REPLACE would
not copy. The file's reader reads that shape at once, so that the laws of recovery go
through it as through MOVE's. Any other COPY, as Redis writes it (the client's own
words: no DB, lower case, REPLACE before DB), is read word by word, into the focus when
it names no database: an act of its own (`ACopyHere`), since the reader of a file does
not know which database the file selected last. Its proofs are COPY's, with the focus's
number for the target's. A new test runs the same commands against BendKV and a
redis-server that keeps its own file, then starts BendKV from Redis's file and Redis from
BendKV's: each holds the databases the other held (`tests/aof_redis_test.py`, in `make
test`).

**What is proved.** The laws of persistence over several databases take COPY's case: a
COPY that copied does to the replay what it did to the server's databases, the replay
moving its focus to the source's database first (`post_copy`), and one that did not
changes no database. One more law, `copy_key`: when the source is there, and the
destination is not or REPLACE is given, the databases after COPY read at time 0 as
before, but for the target database, whose destination holds the source's entry; 63
laws.

**Cost.** GET 3,143, SET 4,072 and INCR 4,236 instructions per request (3,144, 4,070 and
4,229 before): INCR +7 (+0.2%), COPY lengthening the chain of names of four letters, as
TIME did. Redis's test suite: BendKV passes 292 of the 1,673 tests Redis passes (17.5%)
and 268 of the 370 in what it has; unit/keyspace 42 (was 35), all seven of COPY's tests on
strings, three of them among the 17 that need several databases (9 of those pass now).
The differential tests ran about 165 thousand commands with COPY among them (into
databases 0 to 3, with REPLACE and without, with bad numbers and options), every reply
identical to Redis's.

## 3zc. A number past 2^48 stopped the server

A database's number, read as Redis reads it (a long long, so that the error says
"out of range" where Redis says it), was made as hi * 10^9 + lo inside `Bool.pick`,
which evaluates both of its branches: for a number of 2^48 or more the product was made
even when the other branch was taken, and the runtime stops on a Nat past 2^48. `SELECT
9223372036854775807` stopped the server, and so did MOVE, SWAPDB and COPY with such a
number. The other readers of long longs already made the product in a def of its own,
which matches on whether the number is small; this one now does too. HELLO read its
protocol version as BendKV's integers (14 digits), and called a long long past them "not
an integer"; it reads a long long now, as Redis does (`NOPROTO` for 9223372036854775807).
A new test, `tests/numbers_test.py` in `make test`, sends every command that takes a
number the numbers at their edges (past a long long, LLONG_MAX and LLONG_MIN, 2^48, 2^32,
2^31, and forms Redis refuses: `+5`, `1e5`, `0x10`, `" 5"`, `-0`, `00`, `3.5`): 741
commands, each answered as Redis answers it, but INCRBY and DECRBY past 14 digits and
SCAN with a cursor BendKV did not give, the differences documented already.

## 3zd. BITOP and LCS

**BITOP.** AND, OR and XOR combine their sources byte by byte, a key not there reading
as no bytes and a shorter value padded with zero bytes; NOT complements its one source.
The value is set at the destination as SET sets it, its time gone, or the destination is
deleted when the value is empty, and the reply is the value's length. The operation is
named in any case and read only up to a NUL byte, as `strcasecmp` reads it, with Redis's
errors (a syntax error for another name; NOT with more than one source).

BITOP is the third command whose write depends on keys besides the one it writes: its
`deps` are its sources, so the commuting laws hold of it as they hold of MSETNX and
RENAME, through three lemmas: its value is the same in two tries that agree on its
sources (an induction over them), its write leaves a key that had one entry in two tries
with one entry, and it changes no key but its destination. Its write is the SET or the
DEL of its destination, and so is its log, so that the laws of the log needed nothing
SET and DEL did not have already. One more law, `bitop_store`: after BITOP the
destination holds the value with no time, or nothing when the value is empty, and the
reply is the value's length (64 laws).

**LCS.** The longest common subsequence of two values, as Redis 7.0.15's `lcsCommand`
finds it: the table of the LCS lengths of every two prefixes, then a walk back from its
last cell that takes a byte when both prefixes end with it, and otherwise drops the last
byte of the first value when the cell above holds more than the cell to the left, else
the second's (the tie decides which subsequence, and which runs, come out). LEN answers
the length with no walk; IDX the runs the walk took, the last first, each as its ranges
in both values, with its length after WITHMATCHLEN, those shorter than MINMATCHLEN left
out; otherwise the subsequence itself. LCS is a command of the session, as OBJECT is: it
reads the selected database and proto-max-bulk-len, which bounds the table at 4 bytes a
cell, as in Redis. It changes no database, so its proofs are a case of the sessions'
proofs each. The table is lists of numbers, about 16 bytes a cell where Redis has 4, and
it is slow: two values of 4,000 bytes (16 million cells) take 1.1 to 2.5 s, where Redis
takes 0.06 s; the largest table proto-max-bulk-len allows by default, 134 million cells,
would take BendKV tens of seconds and gigabytes.

**Cost.** GET 3,146, SET 4,076 and INCR 4,240 instructions per request (3,143, 4,072 and
4,236 before, +0.1%). Redis's test suite: BendKV passes 311 of the 1,673 tests Redis
passes (18.6%) and 287 of the 370 in what it has; unit/bitops 43 of 45 (was 30: BITOP's
twelve, and a fuzz test of BITPOS and BITCOUNT that BITOP NOT sets up), unit/type/string
70 of 77 (LCS's five), and COMMAND GETKEYS of LCS. The differential tests ran about 100
thousand commands with BITOP and LCS among them (operations and options in any case,
wrong ones, a destination among the sources), every reply identical to Redis's.

## 3ze. BITFIELD: words of 64 bits where a Nat stops at 2^48

**What it does.** BITFIELD and BITFIELD_RO as Redis 7.0.15's `bitfieldGeneric`: fields
of 1 to 64 bits, signed (two's complement) or unsigned (up to 63 bits), at any bit
offset, or at `#k`, k times the field's width; GET, SET (its reply the old value),
INCRBY (the new one), and OVERFLOW WRAP, SAT or FAIL for the operations after it, a
FAIL's overflow writing nothing and answering a null. The errors are Redis's, in the
order Redis checks the words: a subcommand with the words it needs after it, the type,
the offset (below 2^32, the bits of 512MB), the value (a long long). BITFIELD whose
operations are GETs alone is a read, a Peek, as BITFIELD_RO is; with a write it is an
update, an Upd, as SETBIT is. COMMAND GETKEYS gives its key the flags Redis's
`bitfieldGetKeys` gives it: read-only while its words are GETs and OVERFLOWs.

**A word of 64 bits.** A field's value reaches 2^63 in magnitude and Redis's arithmetic
on it wraps as C's does, where a Nat stops at 2^48. A word is two U32 halves (a U32
wraps as C's `uint32_t`): addition with its carry, negation, signed and unsigned
comparison, masks, sign extension, and its decimal digits by long division by 10^9 over
16-bit limbs, so no Nat past 2^47 is made. Redis's checks of overflow
(`checkSignedBitfieldOverflow`, `checkUnsignedBitfieldOverflow`) run on these words as
written, where their sums wrap too: `OVERFLOW SAT SET i8 0 -9223372036854775808` stores
127 in Redis, its `maxincr` wrapping, and in BendKV. Two traps of Bend shape the code. A
U32 shift compiles to C's, and a shift by 32 or more is undefined in C; and `Bool.pick`
evaluates both of its branches, so every shift that might reach 32 is in a def that
matches on which half it is for. The reply is the word's text, a reply of its own
(`RIntS`): an Int holds 48 bits.

**The write.** Redis grows the value to the last byte a write reaches (makes it, for a
key not there), then runs the operations in order on it. BendKV runs them on the span of
bytes the writes reach, from the first write's first byte to the last write's last, as it
starts of the value's bytes and zeros past its end; a write reads its field there and
puts it back there, a GET reads the span where it lies and the value elsewhere. The
change is the SETRANGE of the span, as SETBIT's is the SETRANGE of its byte, made when
the value grows or a write changes its bits, as Redis counts a change; so the file holds
a SETRANGE, and the proofs needed nothing SETRANGE did not have: two lemmas a case, on
whether the change is made and whether its range fits. Where every write fails
(OVERFLOW FAIL) on a key it makes or grows, Redis keeps the key and logs nothing, since
it counts only the writes it made: its file and its replicas lack a key its memory holds.
BendKV keeps the key too, and logs it. A field across the 2^32-th bit makes Redis grow
the value up to 8 bytes past 512MB; BendKV, whose values stop at 512MB, answers the
error SETRANGE answers there.

**Cost.** At pipeline 16 (`redis-benchmark`, medians of three rounds, each against Redis
in turn), a BITFIELD INCRBY of a u8 runs at 530 thousand requests per second against
Redis's 1,050 thousand, a GET of an i32 by BITFIELD_RO at 660 thousand against 1,110
thousand, and a BITFIELD of eight operations (four INCRBYs, four GETs of a u63) at 110
thousand against 340 thousand: its 34 words are parsed, a word at a time, into the
states of a machine, every field's bits pass through words of two halves, and the
runtime spends a fifth of its time dropping what they leave. The first version, which
read a field a bit at a time and every number as a long long's word, was about 30%
slower still; a field read a byte's part at a time, short numbers read as Nats (`num14`,
the long long's path left to the long ones) and branches computed only on the side taken
made up the difference. Placed after RInt among the replies, `RIntS` made GET 1.5%
dearer (3,194 instructions per request against 3,146): the tags of the replies after it
moved, and the reply's encoder compiled otherwise. Placed last, it costs nothing: GET
3,147, SET 4,077 and INCR 4,238 (3,146, 4,076 and 4,240 before). Redis's test suite:
BendKV passes 327 of the 1,673 tests Redis passes (19.5%; 311 before) and 303 of the 386
in what it has: unit/bitfield 16 of 16. One test of unit/bitops that BITFIELD now
reaches counts the changes since the last save (`rdb_changes_since_last_save`), which
BendKV does not keep. The tests: `tests/bitfield_test.py` in `make test` (3,000 random
commands on three keys, fields of every type at offsets below 256 or `#k`, values at the
edges of the fields and of a long long, each reply and each value after it compared with
Redis's), BITFIELD in the differential test (with wrong types, offsets, values and
words), its offsets and values in `tests/numbers_test.py` (`#288230376151711745` of an
i64, which wraps to 64, among them), and BITFIELD in both files, Redis's loaded by
BendKV and BendKV's by Redis.

## 3zf. A value of a type: strings and collections

**What changed.** A key held a string; now it holds a `KV.Val`: `VStr{s}`, a string, or
`VColl{c}`, a collection (`KV.Coll`). Hashes come first: `HSmall`, a list of field-value
pairs in the order they came, as Redis's listpack keeps them, or `HBig`, a trie of fields,
as its hashtable. The trie is generic in its values, so its eleven map laws hold of
`Trie<Val>` as they held of `Trie<String>`; the database, the specification, the bridge,
the append-only file and the sessions changed only the type they use. No command makes a
collection yet (hashes are next), so nothing a client sees has changed: this is the ground
the types stand on.

**What a command sees.** Redis answers `WRONGTYPE Operation against a key holding the
wrong kind of value` to a command for one type on a key of another. A string command now
reads its key's entry through a view (`peek.v` for the reads, `upd.v` for the updates): a
string's entry goes to the string code as before, unchanged; a collection's is WRONGTYPE,
the key left as it was, but for the commands that act on a key of any type. SET (with
SETEX and PSETEX) replaces it, SETNX finds it there, EXPIRE and its kin and PERSIST set
its time: they see it as a key there with its time and an empty string, which none of them
reads. TYPE names the collection's type, and TTL, PTTL, EXPIRETIME and PEXPIRETIME answer
its time. SET with GET and GETSET read the old value, so they are WRONGTYPE, as in Redis.
The key commands (DEL, EXISTS, RENAME, COPY, MOVE, KEYS, SCAN, TOUCH, the sweep) carry
any value. MGET answers a null for a collection, as Redis does; BITOP is WRONGTYPE when
any source holds one (it checks them all before it computes); LCS answers Redis 7.0's
`ERR The specified keys must contain string values` before it reads its options. SCAN's
TYPE compares the type's name (`string`, `hash`, in any case), and OBJECT ENCODING of a
hash answers `listpack` or `hashtable`. GET reads a copy made while the trie is lent
(section 3k); it now reads a `Got`, the string's copy, a mark that the key holds a
collection, or none, so a read builds no `VStr` and copies no collection. INCRBY reads the
same way.

**The proofs.** The laws of the commands now say which values they hold for: APPEND's for
a key that holds no collection, GETDEL's and SETRANGE's for one that holds a string,
BITOP's when no source holds a collection; SETNX, PTTL, PERSIST, SET with KEEPTTL,
RENAME, MOVE, COPY and the frame laws hold of a key of any type. BITOP's verdict on its
sources' types is the same in two tries that agree on its sources, which its commuting
laws need: a write to another key could otherwise change it. The persistence proof
(section 3e) replays each update's change at time 0 from the effect the file holds, and
needs the change to be good of the key's entry (`Good`); APPEND's and SETRANGE's changes
are good only of a string, whose value the replay reads again. An update that acts on a
key of any type sees a collection as a string with nothing in it (`any_v`: `upd.v(op,
now, Some{Item{w, e}})` is `upd(op, now, Some{Item{sview(w), e}})` for SET, SETNX, EXPIRE
and PERSIST), so replaying PERSIST, PEXPIREAT or SET KEEPTTL on a collection makes the
change the update made. BITOP logs nothing when it answers WRONGTYPE. Of the 928
definitions of the proof, 275 changed, most of them only in the type of their values, and
27 came in; none of the map's laws changed.

**Cost: a node per value.** A string is now behind a node of its own, the `VStr`, where
the entry held it (a value of up to 6 bytes inside the entry's word: patch 4, section 3).
Instructions per request (`make perfcheck`, 100 thousand keys): GET 3,272 (3,141 before,
+4.2%), SET 4,261 (4,070, +4.7%), INCR 4,499 (4,226, +6.5%); the baseline is rewritten.
With a million keys, where the node is a miss of its own: GET 3,376 instructions and 5.69
last-level misses per request (3,223 and 4.18 before), INCR 4,830 and 7.53 (4,513 and
5.25); the batch hints fetch the node only once the entry is in, too late for the read
behind it. In time (`tools/bench_pairs.sh`, a million keys, pipeline 16, 20 clients, five
pairs): GET and SET run as before (1.00 of the old build, medians of pairs), with 11% and
6% more user CPU per request, and INCR at 0.89, as it reads the node, builds another and
drops the old one. Memory: a million keys with 3-byte values take 64 bytes each against
56 (`VmRSS`), 8 more, one word. The way back is in the compiler, not in BendKV: a type
whose one variant holds a String and whose other variants are constructors could keep
that variant as the String's own word (a string's tag is not a constructor's), with no
node and no proof touched. It is on the list for after the types. (Done: patch 32,
section 3zzg.)

## 3zg. Hashes

**What there is.** HSET, HMSET, HSETNX, HGET, HMGET, HDEL, HLEN, HSTRLEN, HEXISTS, HKEYS,
HVALS, HGETALL, HINCRBY, HSCAN and HRANDFIELD, with MEMORY USAGE. A hash is `HSmall`, its
pairs in the order they came, while it holds at most 512 fields and values of at most 64
bytes (Redis 7.0's listpack defaults), then `HBig`, a trie of its fields, for good, as
Redis turns a listpack into a hashtable. BendKV converts at those defaults whatever the
parameters say, so that the hash a history of writes leaves depends on the writes alone
(the append-only file makes it again on any server); OBJECT ENCODING reads the parameters
as they are. A small hash answers HGETALL, HKEYS, HVALS and HSCAN in the order its fields
came, byte for byte as Redis; a large one in the order of its trie (Redis in the order of
its table: both are arbitrary), and HSCAN walks its buckets with a cursor as SCAN walks
the keys (section 3t). HRANDFIELD picks with the server's random numbers, as RANDOMKEY
does. Arguments are read where Redis reads them: HINCRBY's increment and HSCAN's cursor as
the command parses, before the key is looked for; HSCAN's options only once the key is
found to hold a hash; HSET with a field and no value fails in the command (a failed call,
not a refused one).

**The file, and a key whose time had passed.** A write is logged as what it did: the HSET
of the pairs it set (HSETNX's pair, HINCRBY's field with its sum, HMSET as HSET), the HDEL
of the fields it took, a DEL when it took the last one. The change keeps that write, and
the persistence proof replays it on the hash at time 0. One case did not fit: a write that
makes a new hash where the trie still holds an entry whose time has passed (no sweep and
no other write came to it). At time 0, where the file loads, that entry is there again: an
HSET of the new pairs would add them to the old hash, or meet a string and answer
WRONGTYPE. Redis 7.0 deletes the key when the write comes to it and logs `MULTI`, `DEL`,
the write, `EXEC`, two entries a crash can part, which its loader handles by dropping a
MULTI left open. BendKV's crash law (section 3f) rests on every act logging one entry at
most. The ways considered:

- the lazy deletion as an act of its own before each write of a collection, as MOVE's
  first step deletes an expired entry in the other database (section 3x): one entry per
  act again, but the write itself would then have to act on the raw entry (or do nothing
  on an expired one) for every sequence of acts the laws quantify over, and the fast path,
  which runs commands without acts, would have to be routed around it;
- MULTI and EXEC in the file, with a loader that drops a group left open: the shape
  transactions will need, but the laws of the file (each effect one entry that parses back
  to it) would have to be restated for groups;
- RESTORE with a DUMP payload: one standard command, but an RDB encoding and a CRC64 to
  write and prove;
- one EVAL of a fixed script, `redis.call('del',KEYS[1])` and then the HSET, a thousand
  arguments a call (Lua's `unpack` stops near 8000).

BendKV takes the last: one entry, which Redis runs as it loads the file (Redis wrote EVALs
into its own files before 5.0), and which BendKV parses back as `HWNew`, a write that makes
a new hash wherever the key was. The laws keep their shape: the effect is one entry, parses
back to itself, and its replay replaces the entry. The EVAL is logged only in that case; a
new hash where the trie holds no entry is an HSET. EVAL with any other script answers an
error (BendKV has no Lua), and a client that sends this one gets what Redis gives (0, and
the hash made). `redis-check-aof` accepts such a file; Redis loads it to the same hashes
(3,001 pairs, in chunks, in the test) and BendKV loads them as Redis runs them.

**The proofs.** Of the 972 definitions of the proof, 42 changed and 44 came in; no law
changed. The commands of hashes are reads (`Peek`) and updates (`Upd`) of their key, so
the frame, commuting, persistence and session laws cover them. The new parts: `Good` for
the two changes of a hash (a hash changed: the write it keeps, replayed on the hash the key
held, makes the same change; a new hash: its pairs set in an empty one), the replays of
HSET, HDEL and the script, the parse back of each (the pairs written as HSET's arguments
read back as themselves, `hpairs_rt`; the script compared whole), one effect per change
(the effect of a new hash depends on whether the trie held an entry, so an effect now takes
the entry's code), and HRANDFIELD and MEMORY USAGE among the commands of the connection.
Laws of hashes themselves (HSET then HGET answers the value, HDEL takes the field) are not
stated yet.

**The kernel's stack.** `make verdict` then failed with a JavaScript stack overflow in
Bend's translation toward the kernel. The statistics' table that maps a 12-bit word back to
its code (`stat.code.cw`, written by `tools/gen_commands.py`) matched on numbers up to
2,095, and a match on a number unfolds it, one level of recursion each: with the 76 codes
of the new commands, the largest number grew from 1,713 to 2,095 and passed the stack. The
table now matches on the word's high six bits, then on its low six, numbers up to 63.

**COMMAND.** EVAL's key spec counts its keys with an argument (numkeys), which BendKV's
specs (an index and a range) did not have: COMMAND GETKEYS of EVAL runs Redis's way, the
spec first (numkeys a long long of at least 1 with that many words after it; RW, access,
update), then, when it does not read, `evalGetKeys` (numkeys as `atoi` reads it; no
flags). MEMORY is a container, as OBJECT, with HELP and USAGE.

**Cost.** Instructions per request (`make perfcheck`): GET 3,291 (3,272 before, +0.6%),
SET 4,287 (+0.6%), INCR 4,561 (+1.4%), within the guard's 3%; the baseline stays. A hash
costs what its form does: HGET on a small hash walks its list, as Redis walks its
listpack, and HRANDFIELD on a large hash builds the list of its pairs on each call (O(n),
where Redis picks in O(1)). Hashes have no benchmark yet.

**Where BendKV differs.** MEMORY USAGE is an estimate (40 bytes, the key's and the value's
lengths, 32 more a pair), where Redis asks its allocator; HINCRBY stops at 14 digits, as
INCRBY; a hash written while the listpack limits were raised stays a hashtable past the
defaults (Redis keeps a listpack up to the raised limits); HRANDFIELD's picks differ, both
servers' being random.

**Redis's test suite and the tests.** BendKV passes 391 of the 1,673 tests Redis passes
(23.4%; 327 before) and 365 of the 458 in what it has. Hashes brought 64: unit/type/hash
56 of its 72 (the others: HINCRBYFLOAT's twelve, two that read a hash back with DUMP,
HRANDFIELD over RESP3, and HINCRBY's test of overflows, which starts past 14 digits), the
three of HSCAN in unit/scan, COPY of a hash in both its encodings, and COMMAND GETKEYS of
EVAL and of MEMORY USAGE. The tests: `tests/hash_test.py` in `make test` (a script of
commands at their edges, hashes of 511, 512, 513 and 1,200 fields on both sides of the
listpack's limit, keys whose time has passed, then 3,000 random commands on a few keys,
each reply compared with Redis's: HRANDFIELD by what its picks must be, MEMORY USAGE by
its kind, a hashtable's fields as a set), hashes in the differential test, in both
append-only files (Redis's loaded by BendKV and BendKV's by Redis, the script of a new
hash among them) and in the restarts from BendKV's own, and COMMAND GETKEYS of EVAL and of
the hash commands in the test of COMMAND.

## 3zh. Lists

**What there is.** LPUSH, RPUSH, LPUSHX, RPUSHX, LPOP and RPOP (with a count), LLEN,
LINDEX, LRANGE, LSET, LINSERT, LREM, LTRIM, LPOS, LMOVE, RPOPLPUSH and LMPOP. A list is a
deque of two stacks (`Deq`): the front elements in order, the back ones reversed, so a
push or a pop at either end adds or takes the head of one of them. When one part holds
more than three times the other's elements and one more, the elements are dealt again,
half to each: a push or a pop costs O(1) amortized, and LINDEX, LSET and LRANGE walk only
from the end nearer to what they read. A key never holds an empty list: a write that
takes its last element deletes the key, as in Redis. OBJECT ENCODING answers `quicklist`,
as Redis 7.0 does for every list. Arguments are read where Redis reads them: the counts
of LPOP and LREM and the ranges of LRANGE and LTRIM as the command parses, before the key
is looked for; the index of LINDEX and of LSET once the list is found; LPOS's options in
turn, the last of each counting, with a RANK of LLONG_MIN as Redis 7.0.15 has it (its
negation wraps in C: it reads from the last element and, with COUNT, takes every match).
A count or an index may be any long long.

**A command travels as wide as its widest form.** The first version of the list commands
cost every request more instructions: GET +3.6%, SET +3.0%, INCR +4.6%, though GET runs
none of them. Bend compiles a non-recursive nested type flat: a value of `Cmd` travels in
as many registers as its widest constructor needs, nested types unfolded, and the reads
of a list, kept inside a `Peek`, had forms of several fields of their own. `Cmd` grew
from 5 words to 11, and every call that passes a command (the parser, the hints, the
dispatch, the run) moved and dropped the extra words. The reads now keep their arguments
as they came, one word (a list of strings, read again as the command runs; the parser
reads LRANGE's and LPOS's first, to answer their errors as Redis does), and a write of a
list keeps two fields at most, so that a change that holds one is no wider than a hash's.
The cost fell to GET +0.8%, SET +0.7%, INCR +2.6%. INCR's share is the dispatch: the
names grow with each type, and the chain of comparisons for INCR's length holds more of
them; a dispatch by length and then by first letter comes next.

**Moves between keys.** LMOVE (RPOPLPUSH is its RIGHT LEFT form) pops from one key and
pushes onto another; LMPOP pops from the first of its keys that holds a list. Both are
commands whose writes depend on other keys (section 3za): `deps` names LMOVE's two keys
and LMPOP's keys, and the commuting laws, proved for any command with its dependencies,
cover them with no change to a law. LMPOP is logged as the pop of the key it took from (an
LPOP or RPOP with its count, or the DEL of that key when it took the last elements): one
entry. Bend 2 has no mutual recursion, so the search for the first key that is there
computes whether the first key holds a list before it recurses, and passes that down
(`lmpop.first`).

**A destination whose time had passed.** LMOVE onto a key whose entry still lies in the
trie with its time passed meets the case of hashes (section 3zg): at time 0, when the
file loads, the old entry lives again, and a plain LMOVE would push onto it. BendKV logs
such a move as one EVAL of a second fixed script,
`redis.call('del',KEYS[2]) return redis.call('lmove',KEYS[1],KEYS[2],ARGV[1],ARGV[2])`,
which Redis runs as it loads the file and BendKV parses back as `LMove` with its ends' New
form: a move that takes the destination as not there, whatever it holds, and sets the new
list where the destination's entry lies. Where it lies matters: the persistence proof
compares tries by their structure, and a delete then a set would put the key at the end of
its bucket. A list made by a push where an expired entry lay is logged as the hash's script
with the pushes. (`tests/aof_redis_test.py` makes such keys with a time of 3 ms; BendKV's
sweep, every 100 ms, may take them first, and the file then holds a plain move onto a key
not there.) One case parts the two servers, and no file BendKV writes holds it: the move
script with one key as both source and destination, for which Redis deletes the key and
moves nothing, where BendKV moves the element within the list.

**A count as large as a long long.** `tests/numbers_test.py`, with the list commands in
it, stopped the server: `LPOP key 9223372036854775807` on a list of five popped one
element a step for the whole count, a pop of an empty deque being a step that changes
nothing: 2^63 steps. Redis bounds the count by the list's length; BendKV now does too
(`lpop.cap`), and the proof follows the code. (`HRANDFIELD key -2147483649` asks both
servers for 2^31 picks, which both start to build; the test leaves it out.)

**The proofs.** Of the 1,053 definitions of the proof, the spec and the laws, 49 changed
and 156 came in; no law changed. The one-key commands of lists are reads (`Peek`) and
updates (`Upd`) of their key, as hashes are; LMOVE and LMPOP are commands of their own in
the spec (`mv.find`, `mv.do`, `lmpop.first`), with their lemmas of frame, of a key's entry
after them, of their replies, of the bridge to the server's records and of time. The new
parts of persistence: `Good` for the two changes of a list (a list changed: the write it
keeps, replayed on the list the key held, makes the same change, and is one the file can
write: a push of elements, a pop of a count that reads as one, LREM and LTRIM of numbers
that read as ones; a new list: its pushes on an empty one), proved of every write by its
shape (`lw_shape`); LMOVE's replay at time 0 (what it finds then is what it found at now:
an entry there at now is there at 0, and a dead destination is one the New form takes as
not there); the parse back of each write and of both scripts; one effect per command.
Laws of lists themselves (LPUSH, then LPOP answers the element) are not stated yet.

**Cost.** Instructions per request (`make perfcheck`): GET 3,298 (+0.8%), SET 4,289
(+0.7%), INCR 4,614 (+2.6%), within the guard. Against Redis 7.0.15 (redis-benchmark,
pipelines of 16, one key): LPUSH 1.08 M/s against 1.63 M/s, RPUSH 0.81 against 1.02, LPOP
0.60 against 1.15, RPOP 0.80 against 1.26: 0.53 to 0.80 of Redis's throughput, where GET
is 1.6 times it. A push of a hundred elements a command onto a list that grows to 200,000:
33 µs a command pipelined against Redis's 10, 89 against 67 one at a time. A read or a
write in the middle of a list of 200,000 walks cons cells: LINDEX 3.9 ms (Redis 0.06),
LSET 9.2 (0.05), LINSERT 19.9 (1.3), LREM 10.1 (2.5), LPOS 7.2 (1.5); near an end, 0.08
ms. Redis's quicklist hops nodes of many elements; a deque of chunks would do the same.

**Where BendKV differs.** MEMORY USAGE is an estimate; the blocking commands (BLPOP,
BRPOP, BLMOVE, BLMPOP, BRPOPLPUSH) are not there yet; the move script with one key at
both ends (above).

**Redis's test suite and the tests.** BendKV passes 424 of the 1,673 tests Redis passes
(25.3%; 391 before) and 401 of the 689 in what it has. Lists brought 33: all 11 of
unit/type/list-3, both of unit/type/list-2, 15 of the 218 of unit/type/list (the unit then
runs its other tests over RESP3 first, and stops at HELLO 3), and 8 tests of other units
that need a list. The tests: `tests/list_test.py` in `make test` (a script of commands at
their edges, lists of 1 to 20,000 elements read and written at both ends and in the
middle, a capped list and a queue, keys whose time has passed as sources and destinations
of moves, then 3,000 random commands on a few keys with moves between them, each reply
compared with Redis's), lists in the differential test, in the numbers test, in both
append-only files (both scripts among them) and in the restarts, in `tests/aof_check.bend`,
and COMMAND GETKEYS of LMPOP, LMOVE and the others in the test of COMMAND.

## 3zi. A dispatch by length, then by first letter

A request's name finds its command by a number (`cmd_id`), and each type of value adds
names: with lists, INCR's length (four letters) held 27 of them, and each was compared
with the name (a chain of `Bool.pick` computes all of them; for a name of up to six bytes
a comparison is one of words). `tools/gen_commands.py` now writes `cmd_id` from the
parser's own cases, each `case N:` of `parse_id` and `parse_sess` naming its command in a
comment: a match on the name's length, then on its first letter (by its place in the
alphabet, so that no match names a number past 26), then `String.eq` against the few
names left, eight at most of Redis's 241 commands. The numbers and the dispatch can no
longer disagree, and a new command needs its case in the parser and its name in the
generator's list.

**Cost** (callgrind, 20,000 requests of redis-benchmark at pipeline 16, as `make
perfcheck` counts them): INCR 4,615 instructions to 4,475 (−3.0%, 0.5% under the
guard's baseline again), LPOP −1.6%, LPUSH −1.0%, HSET −0.7%, MSET −0.5%. GET and SET,
whose length held five names, stay where they were (3,295 and 4,289): a lookup by letter
costs about what four comparisons of words did. The proofs check as before (`make
verdict`, 26.5 s): `R.parse` of a literal name reduces through the new matches.

## 3zj. Sets

**What there is.** SADD, SREM, SCARD, SISMEMBER, SMISMEMBER, SMEMBERS, SSCAN, SPOP and
SRANDMEMBER (with a count), SMOVE, SINTER, SUNION, SDIFF, their STOREs, and SINTERCARD
with LIMIT. A set is an intset or a hashtable, as in Redis 7.0 (which has no listpack
sets yet). An intset holds canonical 64-bit integers alone (as Redis's `string2ll` reads
them: no sign but a minus, no leading zero, no `-0`), at most 512 of them, as a list of
their strings in numeric order (a tree of them since section 3zzy); any other member, or
a 513th, turns the set into a hashtable for good, a trie of its members (`Trie<Unit>`,
the keyspace's own map). An
intset answers its members in numeric order, as Redis's does, and SSCAN gives it whole
with cursor 0; a hashtable answers in the order of its trie, where Redis answers in the
order of its dict, so the tests compare a hashtable's members as a set. A key never holds
an empty set. OBJECT ENCODING reads set-max-intset-entries; the set itself turns a
hashtable at 512 whatever the parameter says.

**Arguments where Redis reads them.** SPOP's and SRANDMEMBER's counts before the key is
looked for (SPOP: "must be positive", for a word too; SRANDMEMBER: any long long but
LLONG_MIN); SINTERCARD's numkeys and LIMIT with their own four errors; every key of an
operation of several sets checked for its type, even after one that is not there (SINTER
then answers an empty set); SMOVE answering 0 for a source that is not there before it
looks at the destination's type; SDIFF picking between Redis's two ways by the same costs,
and SDIFF of a set with itself empty at once.

**Picks at random.** SPOP and SRANDMEMBER take the server's random number (as HRANDFIELD
does) and the numbers of a Weyl sequence after it, each scrambled by `KV.mix`: a member of
an intset by its index, of a hashtable as RANDOMKEY picks a key. For k different members
of n, k below n, BendKV follows Redis's ways: an intset's picked and dropped in turn; a
hashtable's, when k is more than a third of n, by n − k members dropped at random (Redis's
third way), else picked until k different ones come (its fourth). The picks pass Redis's
own tests of them, the chi-square of `SRANDMEMBER histogram distribution` among them.
The persistence proof needs acts that do not depend on the
data, so SPOP's act carries its random number, and its log entry is the SREM of the
members it took (Redis propagates SPOP so too), or the DEL of the key when it took the
last ones.

**Operations of several sets.** A STORE writes its destination as the update SWNew of the
members it made, or deletes it when there are none; SMOVE takes a member out of its
source and adds it to its destination by the updates SREM and SADD make. Both are
commands whose writes depend on other keys (section 3za): `deps` names a STORE's sources
and SMOVE's two keys, and the commuting laws cover them with no change to a law. A STORE
is logged as the members it made, not as the command: the SADD of them where the trie held
no entry for its destination, else the hash's script with the SADD (one entry: the script
deletes the key first). The file then replays without its sources. SMOVE is logged as
itself, and onto a key whose time had passed as one EVAL of a third fixed script,
`redis.call('del',KEYS[2]) return redis.call('smove',KEYS[1],KEYS[2],ARGV[1])`, which
BendKV parses back as `SMv` with the member's New form, as LMOVE's (section 3zh).

**Two changes the proofs asked for.** The replay of a new set made where no entry lay
runs SADD of its members on a key not there, and that had to make the same change as the
first run, a new set. SADD decided "no change" by the count it added, so the proof needed
that adding one member or more to an empty set makes it nonempty: a lemma on sizes over
both encodings. SADD of a new set now decides by whether it has members at all (the same
answer), and the lemma is not needed. SMOVE read its keys' values (`KV.read`); its replay
at time 0 then needed to relate values read at 0 and at now. It now reads their entries
there at now (`db.ent`), as LMOVE does, and its replay follows LMOVE's: the source there
at now is there at 0, a destination whose time had passed is one the New form takes as
not there, and the update of the destination makes the same change at 0 as at now, a new
set of the member, whether SADD made it on a key not there or SWNew where the dead entry
lay.

**A bug the differential test found.** SET with GET of a key that holds a collection
answered WRONGTYPE at once; Redis checks the time first, so `SET k v XX EX
9223370399119966 GET` answers "invalid expire time" there. The set commands made such
keys common in the random stream. The order is now Redis's, and the proof that this
SET changes nothing on a collection follows the code.

**The proofs.** Of the 1,212 definitions of the proof, the spec and the laws, 60 changed
and 111 came in; no law changed. The set commands are reads (`SOp`) and updates (`Upd`)
of their key, and the STOREs and SMOVE commands of their own in the spec
(`sstore`, `smv.find`, `smove.do`), with their lemmas of frame, of a key's entry after
them, of their replies, of the bridge to the server's records and of time. `Good` for the
two changes of a set: a set changed, whose SADD or SREM, replayed on the set the key held,
makes the same change, and has members (SPOP's change is the SREM of what it took, so it
needs no case of its own); a new set, its members made into one. SMOVE's and the STOREs'
replays at time 0, the parse back of each write and of the third script, one effect per
command.

**Cost.** Instructions per request (`make perfcheck`): GET 3,296, SET 4,292, INCR 4,473,
as before sets (3,295, 4,289, 4,475): a command of sets keeps two fields at most, and
`Cmd` stays as wide as it was. Against Redis 7.0.15 (redis-benchmark, pipelines of 16, 20
clients), a member at a time is about as fast: SISMEMBER of a small set 1.38 M/s against
1.18 (of a set of 100,000, 0.72 against 0.78), SREM 1.23 against 1.06, SMOVE 1.34 against
1.18, SCARD 1.32 against 1.28, SRANDMEMBER of an intset 0.95 against 0.89; SADD of random
members up to 100,000, 0.65 against 0.80. A whole hashtable is read by a walk of its trie,
which costs by the trie's nodes: SMEMBERS of 10 members 0.22 against 0.53 (of an intset
0.60 against 0.64), SINTER of two sets of 10 0.23 against 0.62, SUNION 0.09 against 0.21,
SDIFF 0.19 against 0.38, SINTERSTORE 0.14 against 0.54. Picks from a hashtable are slow:
they scan the trie's buckets from a random one for 16 members, as RANDOMKEY does, and a
delete leaves the trie's nodes in place, so a trie drained by deletions costs as much to
scan as a full one: SRANDMEMBER of a set of 100,000, 41,000/s against 714,000; of 10
members, 111,000 against 1.1 M; SPOP of all of 100,000 members, 7,240/s against 709,000,
falling as the set empties. A delete that gives back empty nodes, and a pick that goes
down the trie by counts, are the remedy, a change of the map and of its laws, which comes
next among the costs. (The delete came in section 3zz: the last SPOPs of a set run as
fast as its first.)

**Where BendKV differs.** A hashtable's order; the picks themselves; MEMORY USAGE, an
estimate; set-max-intset-entries, read by OBJECT ENCODING alone; SRANDMEMBER of a negative
count past what memory holds, which both servers try to build (`SRANDMEMBER key
-2147483649` stopped BendKV, out of memory, as it fills Redis's: the tests leave it out);
the move script with one key at both ends, as LMOVE's (no file BendKV writes holds it).

**Redis's test suite and the tests.** BendKV passes 528 of the 1,673 tests Redis passes
(31.6%; 424 before) and 512 of the 800 in what it has. Sets brought 104: 92 of the 94 of
unit/type/set (the other two need ZADD and WATCH), five of unit/scan (SSCAN's four and
SCAN's regression test of issue #4906, which makes sets), two COPY tests of sets in
unit/keyspace, three of unit/protocol (raw protocol replies, read from SRANDMEMBER), MGET
against a set in unit/type/string, and the last test of unit/sort, which the unit now
reaches past its SADD (named for SETRANGE, it runs SORT_RO and catches every error). The
tests: `tests/set_test.py` in `make test` (a script of commands at their edges, intsets on
both sides of 512 members and hashtables of up to 20,000, an intset grown past 512 one
member at a time, keys whose time has passed as sources, destinations and operands, then
3,000 random commands on a few keys, each reply compared with Redis's: a hashtable's
members as a set, each random pick checked against the set it came from and SPOP's set
after it against the set less the picks, the key then made again on both servers), sets in
the differential test (SPOP only where its picks are the whole set), in the numbers test,
in both append-only files (the third script and the SADD script among them) and in the
restarts, in `tests/aof_check.bend`, and COMMAND GETKEYS of SINTERCARD, SMOVE and the
STOREs in the test of COMMAND.

## 3zk. Floats in software: INCRBYFLOAT and HINCRBYFLOAT

**Why in software.** Redis 7.0.15 on x86-64 keeps the score of a sorted set as a C double
(53 bits of precision) and adds INCRBYFLOAT's and HINCRBYFLOAT's numbers as an x87 long
double (64 bits). Bend has a 32-bit float alone, and a Nat stops at 2^48, so
`src/float.bend` does both in software: a number is a sign, a big integer m (limbs of 24
bits, so that a product of two limbs and a carry stays below 2^48) and an exponent e,
m * 2^e, and every operation rounds its exact result to the nearest number of the format,
to the even one on a tie, subnormal numbers and overflow to an infinity included, as the
FPU does in its default mode. Text is read as glibc's strtod and strtold read it: decimal
digits of any length (the exact value divided by a power of ten in limbs of 10^7, with a
sticky bit for what the division drops), hex digits with a binary exponent, `inf` and
`infinity` in any case, `nan`; an exponent with no digit is not read, and one past 10^9
reads as 10^9, past every range. Redis's string2d and string2ld then refuse a blank
first, a text not read to its end (a NUL inside it among them), a NaN, and a range error
(an overflow to an infinity, or a number that is not 0 rounding to 0); string2ld also a
text of 5,120 chars or more. A double is written as printf's `"%.17g"` writes it and a
long double as `"%.17Lf"`, from the number's exact decimal value (m times a power of five
for a negative exponent), rounded half to even; ld2string then takes out the zeros that
end the fraction and writes `-0` as `0`. An integer of up to 14 digits is read at once,
and a double that is an integer below 2^47 written at once.

**Checked against glibc.** `tests/float_test.py` (in `make test`) writes random texts of
numbers: decimal and hex, with up to 800 digits, exact ties between two neighbouring
doubles and between two long doubles (and texts just above and below them), numbers near
each end of both ranges, the forms strtod reads only in part; and sums and products of
doubles and sums of long doubles. A Bend program answers each one, a C program with
glibc's strtod, strtold and printf (`tests/float_ref.c`, Redis's own string2d,
string2ld and ld2string) answers it as Redis does, and the answers must be the same
bytes: 2,308 lines in `make test`, about 9,500 more while the library was written, none
different.

**INCRBYFLOAT and HINCRBYFLOAT.** As Redis 7.0.15 runs them: INCRBYFLOAT finds its key
(WRONGTYPE for a collection), reads the value and then the increment (`value is not a
valid float` for either), adds them, refuses a sum that is not finite (`increment would
produce NaN or Infinity`), and keeps the key's time; HINCRBYFLOAT reads its increment
before it looks for the key (`value is NaN or Infinity` for an infinity), then the
field's value (`hash value is not a float`). Both answer the sum as ld2string writes it
for people, and the file logs the SET of it with KEEPTTL and the HSET of the field, as
Redis propagates them, so a file reads back the same strings on any machine. After a
million INCRBYFLOATs of 0.1, BendKV and Redis both hold 100000.00000000087324992.

**Proofs.** The changes are the ones INCRBY and HINCRBY make (the SET of a value keeping
its time, the HSET of a field), so the laws needed nothing new: INCRBYFLOAT is an update
of its key (`UIncrF`), HINCRBYFLOAT a write of a hash (`HWIncrF`), and their lemmas follow
INCRBY's and HINCRBY's (of the 1,323 definitions, 8 changed and 8 came in). One trap:
the proof checker runs a Nat as Base defines it, one step per unit, and a lemma about a
write of a float stops where the write meets a value it does not know, with the format
already reduced. A format holding the biased exponent 2^40 (the bias the library keeps
exponents with) overflowed the checker's stack there; a format now holds its bounds as
small numbers and a zero's exponent is 0.

**Numbers of commands.** The parser gives each command a number, and its connection
commands (parse_sess) began at 100; the commands of hashes, lists, sets and now floats
reached 99. `tools/gen_commands.py` now writes `cmd_own`, which tells parse_sess's
numbers by their ranges, so a new command of either parser takes the next number free.

**Cost.** Instructions per request (`make perfcheck`): GET 3,298, SET 4,290, INCR 4,478,
as before. INCRBYFLOAT is slower than Redis's hardware arithmetic: 207,000 requests a
second against 512,000 (redis-benchmark, pipelines of 16, 20 clients, adding 1.5), and
HINCRBYFLOAT 131,000 against 495,000 (adding 0.1); a long double has no fast path for
integers yet, and each sum is read from its text and written back to one.

**Redis's test suite.** 552 of 1,673 (33.0%; 528 before): unit/type/incr passes all 24
of its tests (INCRBYFLOAT's twelve came in), unit/type/hash 68 of its 72 (HINCRBYFLOAT's
twelve; the other four need DUMP, RESP3, and integers past 14 digits).

## 3zl. Sorted sets

**What there is.** ZADD (NX, XX, GT, LT, CH, INCR), ZINCRBY, ZREM, ZCARD, ZSCORE,
ZMSCORE, ZRANK, ZREVRANK, ZCOUNT, ZLEXCOUNT, ZRANGE (BYSCORE, BYLEX, REV, LIMIT,
WITHSCORES) and its five older forms, ZREMRANGEBYRANK, ZREMRANGEBYSCORE and
ZREMRANGEBYLEX, ZPOPMIN and ZPOPMAX (with a count), ZMPOP, ZRANDMEMBER (a count, WITHSCORES),
ZSCAN, ZUNION, ZINTER, ZDIFF, their STOREs, ZINTERCARD (LIMIT) and ZRANGESTORE: the 32
commands of Redis 7.0.15's sorted sets but the three that block. An element is a member
and a score, a double of `src/float.bend` (section 3zk): read as strtod reads it, written
as Redis writes a double, compared and added in double arithmetic. A sorted set is one
weight-balanced tree of its elements in Redis's order, by score and then by member (each
node keeps its subtree's size, so a rank, an element at a rank and a window of ranks cost
O(log n)), and, past a listpack's limits, the same tree with a trie of its members and
their scores beside it, for good: Redis's listpack and skiplist. The limits are Redis's
defaults (128 elements, members of 64 bytes), and OBJECT ENCODING reads
zset-max-listpack-entries and -value as it answers, as for hashes. A key never holds an
empty sorted set.

**Where the two encodings answer differently.** BendKV keeps Redis's encodings because
Redis's answers depend on them, in three places. A listpack keeps a score that is an
integer of at most 2^62 in size as an integer, so a small sorted set never holds `-0` (ZSCORE
answers `0`), and ZSCAN, which answers a listpack's elements as they lie in it, writes
such a score as its digits (`100000000000000000`, where ZRANGE writes `1e+17`); BendKV
writes `0` for `-0` in a small sorted set and answers ZSCAN of one with Redis's texts.
A range by member (ZRANGEBYLEX, ZLEXCOUNT, ZREMRANGEBYLEX) is defined for elements of one
score; for others, Redis walks a listpack from its first element and answers the elements
between the first that passes the lower bound and the first that passes the upper one,
while it goes down a skiplist by its random levels. BendKV answers a small sorted set as
the listpack's walk does, and a large one by the tree's descent, which answers as a
skiplist does for elements of one score: the tests read ranges by member of those alone.
ZRANDMEMBER of a count past the size answers the whole set from its last element, as
Redis's iterator of sorted sets goes.

**Arguments where Redis reads them.** ZADD's options in any order and case, then its
errors in Redis's order (XX with NX, then GT, LT and NX together, then INCR with more
than one pair, then a score that is not a double); the pairs from the first word that is
no option's, so a score spelled `incr` is read as the option, and leaves an odd count of
words (a syntax error). ZRANGE's loop of options with each of Redis's errors (LIMIT with
fewer than two numbers, REV, BYSCORE and BYLEX more than once, WITHSCORES with BYLEX,
LIMIT without BYSCORE or BYLEX, but not when the count is -1); a range's bounds before the
key is looked for, as zslParseRange and zslParseLexRange read them. ZUNION, ZINTER and
ZDIFF look for every key and check its type before they read WEIGHTS and AGGREGATE (so a
key of another kind answers WRONGTYPE before an option's error), take a set as a sorted
set of scores 1, and go through their sources in Redis's order, sorted by size (a stable
sort, which decides the sum of three scores like 1e16, 1 and -1e16): a weight times a score
that makes a NaN (0 times an infinity) counts 0, as does a SUM of +inf and -inf.
ZMPOP reads as LMPOP does and answers each element as a pair.

**Persistence.** A sorted-set write is logged as the command the client sent: ZADD with
its options in one order (ZINCRBY as ZADD INCR), ZREM, a ZREMRANGEBY of the range as it
came (the write reads it again as it runs, so the file holds what the client sent), ZPOPMIN
or ZPOPMAX with the count (ZMPOP as that of the key it took from); the removal of a key's
last elements as its DEL. A STORE, and ZRANGESTORE, is logged as the elements it made,
each score written as Redis writes a double (`%.17g`, which reads back to the same
double): the ZADD of them where the trie held no entry for the destination, else one EVAL
of a fourth fixed script that deletes the destination and runs ZADD with the pairs, a
thousand words of them a call, each call with the options before it (a ZADD of some of
the pairs does to each what the ZADD of all does), or the DEL of the destination when
there are none; the same script logs a ZADD that makes a sorted set where a key whose
time had passed still lay. BendKV parses the script back as the update
ZWNew, with the count of options it writes after the key, and refuses it with XX, which
adds nothing to an empty sorted set.

**A command travels as wide as its widest form, again.** The first version of the sorted
sets cost every request more instructions: GET +6.9%, SET +6.0%, INCR +5.3% over the
floats (3,529, 4,547 and 4,708 against 3,300, 4,290 and 4,472), the trap the lists had
fallen into (section 3zh). ZRANGE's parsed read, the range with its bounds (two doubles
and their flags), LIMIT's longs and two flags, was 13 words, and kept inside a `Peek` it
made `Cmd` 17 words wide; ZUNION's options in ZStore were 5. Now a read from the last
element holds the read it reverses (`ZQRev`), and options with WITHSCORES hold the
options (`ZAggScores`): a type that holds itself is a node of its own, one word, as an
update is (UGet). ZCOUNT and ZLEXCOUNT keep their bounds as they came, as LRANGE does,
and ZRANK and ZREVRANK are two forms of one field. `Cmd` is 5 words again, and the cost
went back to what it was (below); the proofs, which see a range read only as a value,
did not change.

**One change the proofs asked for.** A removal of a range and a pop of a key that is not
there answered after running over the empty sorted set; the proof that they change
nothing would then need to know what a range of an empty tree holds, for every range.
They now answer the empty set's reply at once (the count 0, the empty array, or the
range's error), the same bytes.

**The proofs.** Of the 1,331 definitions of the proof, the spec and the laws, 68 changed
and 136 came in; no law changed. The commands of one sorted set are reads (`ZOp`, a
`Peek`) and updates (`Upd`) of their key, the STOREs, ZRANGESTORE and ZMPOP commands of
their own in the spec (`zstore`, `zrangestore`, `zmpop`) whose writes depend on other keys
(section 3za), with their lemmas of frame, of a key's entry after them, of their replies,
of the bridge to the server's records and of time. `Good` for the two changes of a sorted
set: a sorted set changed, whose write, replayed on the sorted set the key held, makes the
same change and parses back from the file (a ZADD whose options and pairs pass ZADD's
checks, a ZREM of members, a range that reads, a count that reads); a new sorted set, the
ZADD of options that pass the checks and have no XX: a lemma shows that ZADD with XX adds
nothing to an empty sorted set, so a new one never has it. ZADD's options parse back by a
case for each of their 64 sets (written out by a script, and checked as written): each
set, written in the file's order, is read back by ZADD's loop of options, which
stops at the first score because the checks have it be no option's word.

**Cost.** Instructions per request (`make perfcheck`): GET 3,297, SET 4,290, INCR 4,476,
as before sorted sets (3,300, 4,290 and 4,472). Against Redis 7.0.15 (redis-benchmark,
pipelines of 16, 20 clients), a read of one member is as fast: ZSCORE of a sorted set of
100,000 members 633,000 requests a second against 630,000 (of 10 members, 904,000
against 950,000), ZCARD 1.40 M against 1.34 M. What goes down the tree is slower: ZRANK
180,000 against 513,000, ZRANGE of 10 elements with their scores 104,000 against 318,000,
ZRANGEBYSCORE with LIMIT 10 64,000 against 597,000, ZCOUNT 142,000 against 989,000,
ZRANDMEMBER 229,000 against 753,000; and a write of a large sorted set slower still:
ZINCRBY 41,000 against 329,000, ZADD of random members up to 100,000 38,000 against
272,000, ZPOPMIN 70,000 against 694,000. A small one is closer (ZADD XX of a member
588,000 against 903,000, ZRANGE of its 10 elements with their scores 218,000 against
302,000, ZRANDMEMBER 825,000 against 1.27 M, ZINTER of two of 10 91,000 against
257,000), but for the STOREs: ZUNIONSTORE of two of 10 19,000 against 169,000,
ZRANGESTORE of 10 44,000 against 286,000. Where the time went (callgrind; these rates
are from before section 3zm's change): ZINCRBY of a member of 100,000 was 147,000
instructions, three fifths of them copies of tree nodes that reads owned (of the 361
sizes a write reads, as each rebalancing asks for them, 126 copied a node the tree
shares), and ZUNIONSTORE of two of 10 583,000, most of them the same copies, the rest
scores written as text and read back (a STORE makes its sorted set as the ZADD the file
logs would). Section 3zm tells why the reads owned the nodes, and how they no longer do
(77,600 and 401,400 instructions after it). BendKV compared members char by char in
Bend, where Redis's memcmp compares words; section 3zn makes `String.order` native
(ZINCRBY 61,200 instructions).

**Where BendKV differs.** A STORE (or ZRANGESTORE) of more than 128 elements: Redis
makes a skiplist of them, and a score of `-0` stays one, where BendKV makes them as the
ZADD the file logs would, and the elements of the first 128 lose the sign (ZSCORE answers
`0`), as Redis's own ZADD of them would; a range by member of elements of several scores
in a large sorted set (above); the picks of ZRANDMEMBER; MEMORY USAGE, an estimate;
zset-max-listpack-entries and -value, read by OBJECT ENCODING alone.

**Redis's test suite and the tests.** BendKV passes 733 of the 1,673 tests Redis passes
(43.8%; 552 before) and 726 of the 1,089 in what it has. Sorted sets brought 181: 170 more
of unit/type/zset, 180 of its 289 (the unit then runs the tests of its blocking commands
over RESP3 first, and stops at HELLO 3 before 82 more; with the tests of RESP3 left out it
runs to its end, and BendKV passes 238 of the 285 Redis passes, each of the other 47
needing the blocking commands, RESP3 within a test, MULTI or replication), ZSCAN's four
in unit/scan, COPY of a sorted set in both its encodings in unit/keyspace, COMMAND
GETKEYS of ZUNIONSTORE with more than 256 keys and ZUNIONSTORE marked movablekeys in
unit/introspection-2, and three tests of other units that make a sorted set on their way.
The tests: `tests/zset_test.py` in `make
test` (a script of commands at their edges, sorted sets of up to 20,000 elements with
integer and fractional scores on both sides of 128 elements, a listpack grown past 128
one element at a time, members of 64 and 65 bytes, keys whose time has passed as sources,
destinations and operands, then 3,000 random commands on a few keys; each reply compared
with Redis's, ZSCAN's whole walk by the pairs it answers, each ZRANDMEMBER pick checked
against the sorted set it came from), sorted sets in the differential test, in the
numbers test, in both append-only files (the fourth script among them) and in the
restarts, in `tests/aof_check.bend`, and COMMAND GETKEYS of the STOREs, ZRANGESTORE and
ZMPOP in the test of COMMAND.

## 3zm. A read that owns what it reads

**What callgrind showed.** ZINCRBY of a member of a sorted set of 100,000 took 147,000
instructions, three fifths of them copies of tree nodes and their drops (`ctr_own_slow`,
`term_drop`). The compiler decides once for each function whether a parameter is
borrowed or owned. It is borrowed until a caller hands it a value the caller does not
keep: a value computed for the call (`zt.size(zset.tree(z))`), or the last use of a
value the caller owns passed in a tail call; or until the function itself reads a field
of the node after a call it makes, as the compiler keeps a node across a call only when
it owns it. One such caller anywhere makes the parameter owned for every caller, and an
owned node that is shared, as every node of a sorted set the keyspace holds is, is
copied before it is read and the copy dropped after. `zt.size`, which each rebalancing
asks for both sides, owned its node because `zset.len` passed it a computed tree: 126
copies for each ZINCRBY. The tests of a range (`ZP`) were nodes, as one test could hold
another (ZNot), made at each call: `zp.ok` owned them, and so the walks down the tree
that pass them.

**The change.** The reads of a sorted set take its tree as a field of the sorted set
(`zset.len`, `zset.slice`, `zset.all`, `zset.rank`), which they borrow; a test of a range
is a few words (ZGtS and ZGtL take the place of ZNot); a walk makes the element it keeps
before it recurses; and a tree built for one use, a STORE's, is taken apart by
`zt.drain`, which owns it. Instructions per request (callgrind): ZINCRBY of a member of
100,000 77,600 (147,100 before), ZRANGE of 10 elements of 100,000 with their scores
56,700 (89,200), ZRANK 15,900 (27,800), ZUNIONSTORE of two of 10 401,400 (583,500); GET,
SET and INCR 3,298, 4,290 and 4,479, as before. No proof changed: they see these reads
only as values.

**What is left.** A walk that reads a field after a recursive call still owns, and
copies, the nodes it visits: the in-order walks of a sorted set (`zt.slice.go`,
`zt.find.go`) and of the keyspace's trie (`tkeys` and `tscan`, behind KEYS and SCAN, and
the reads of large hashes and sets): the sorted set reaches them through tail calls from
a value the command owns, and a value passed in a tail call at its last use makes the
callee own it. The remedy is in the compiler, and it is not a global rule: counting a
value that a caller keeps past a call as lent to the callee, the first try, made GET,
SET and INCR 37%, 30% and 27% dearer in instructions, so the rule stays as it is, and
the zset reads stay as this change leaves them until a narrower one is found. A native
`String.order` came first (section 3zn). What a write of a sorted set costs past that
is mostly its path, copied because the keyspace still holds the old one, and the old
path's drop: an update in place (take the value out, change it, put it back) would save
both. (The narrower rule is Bend patch 31, section 3zza: a walker that reads a tree
borrows it from a caller that owns it.)

## 3zn. Members compared a run at a time

**What callgrind showed.** After section 3zm, ZRANK of a member of a sorted set of
100,000 with scores of their own still took 15,900 instructions, and half of them went to
one comparison: the member against the element the descent stops at, which has the same
score. `String.order` is Base's `String.cmp`, which takes a char off each String at each
step and hands both Strings back; on a packed String each step makes a view of the rest
and drops it (`str_take_slow`, `str_cons_new`, `term_drop`), so two equal members of 14
bytes cost about 8,000 instructions. Where the scores are equal, as in a sorted set of
score 0 read by member (ZRANGEBYLEX and its kin, a common use), every node of a descent
compares members: ZRANK of one of 100,000 took 76,900.

**The change.** The twenty-second patch makes `String.order` native on the C lane, as
the fourth made `String.eq`. Two Strings of one run each (a member kept in the tree, a
member where the request holds it) are one `memcmp` of their common length, then a
compare of their lengths; others are walked run by run (`memcmp` of bytes, a cell's char
by its code point). A byte is a char below 256 and `memcmp` reads bytes unsigned, so the
order is the definition's: by code point, a prefix first. `String.is_lt` and its kin go
through it. BendKV's code does not change, and the proofs see `String.order` as Base
defines it.

**The numbers.** Instructions per request (callgrind, pipelines of 16):

| command | before | after |
|---|---:|---:|
| ZRANK of 100,000 of score 0 | 76,861 | 9,028 |
| ZRANGEBYLEX of 100,000 of score 0, LIMIT 10 | 129,345 | 55,144 |
| ZLEXCOUNT of 100,000 of score 0 | 160,302 | 21,435 |
| ZINCRBY of 100,000 of score 0 | 186,381 | 61,449 |
| ZRANK of 100,000 of their own scores | 15,877 | 7,515 |
| ZINCRBY of 100,000 of their own scores | 77,674 | 61,168 |
| ZRANGE of 10 with their scores | 56,715 | 56,708 |

A ZADD of a member with the score it has does not go down the tree (12,368 and 12,361),
and a range by rank compares no member. GET, SET and INCR: 3,301, 4,306 and 4,491
(3,301, 4,295 and 4,479 before, within the ±15 between runs). The patch adds 617 tokens
to `comp.ts`; with it, the C and JS lanes of Bend's own tests pass what they passed, plus
the new `string_order` on both.

**What is left.** ZRANGEBYLEX's 55,000 are now mostly the walk that owns the nodes it
visits (section 3zm): of its instructions, `term_drop`, `span_fade`, `ctr_take` and
`ctr_own_slow` take two fifths, `str_order` 3%.

## 3zo. A client that stops reading

A review of the first commit (issue #3) traced how one client could stop the server
when its replies are posted (`TCP.post`, the default with two cores or more), and it
still held after twenty-two patches. The writer sent each post to its end: on `EAGAIN`
it polled the same socket for 100 ms and tried again, with no limit, and it took the
next post off its ring only once that one was sent. So a client that stopped reading
held the writer, and every reply and close queued behind its own waited. The loop
sends a post itself only when the writer has sent all that was posted to that socket
before (patches 15 and 17), so the clients that kept up still got the replies the loop
sent them, until one needed the writer: a reply bigger than its socket's room, or the
loop gone over to posting under load. And once the ring's 4,096 posts were taken, the
loop spun on it: no request, accept or timer ran. Both happened as traced. With one
client that did not read 32 MiB of replies, another client's 8 MiB reply stopped at the
5.1 MiB the loop had sent itself; after 4,600 more requests from the stalled client,
one a batch, a PING from another client and a new connection went unanswered.

Redis keeps each client's output in a buffer of its own (normal clients have no limit
by default, `client-output-buffer-limit normal 0 0 0`), so no client's backlog delays
another's. The twenty-third patch does the same in the writer, which now never waits
for a socket. What a socket has no room for, and what is posted to it after, the writer
holds in order, and it goes on with the other sockets' posts; it sends what it holds once
the socket has room, which its own epoll set tells it (`poll` on other systems). It looks
there once per 200 µs window while it has posts to send, and while it holds any it
sleeps there instead of on its condition variable, woken by a byte down a pipe. A close
posted after held bytes closes the socket once they are sent. The loop sends a post
itself only when the writer holds nothing for the socket either (`held[fd]`), so a
socket's bytes stay in order. And the ring became a chain of blocks of 4,096 posts:
when one fills, the loop links the next (the one the writer emptied last, or a new
one), so a post never waits for room. A client that stops reading grows only its own
backlog, as in Redis; no limit was added.

[`tests/writer_test.py`](../tests/writer_test.py) runs in `make test` against each
mode of the server. A client asks for 32 MiB of replies and reads none; another then
gets an 8 MiB reply (in 22–26 ms) and a PING (under a millisecond); the stalled client
sends 4,600 requests more, one a batch, more than the old ring held; a new connection
is served and closed by QUIT; the cron's sweep deletes a key whose time has passed,
which nothing reads; a client that asks for 4 MiB and QUIT and reads late gets the
whole reply, then the close; and the stalled client reads its backlog while it sends
2,000 ECHOs, and gets every byte in order, the ECHOs' replies after the rest. The build
before the patch fails at the 8 MiB reply; a build whose loop sends a post itself
without asking `held[fd]` fails too, its ECHOs' replies out of order or the QUIT's close
cutting the reply short. In the compiler,
`tests/io/tcp_post_stall.bend` posts 8 MB and 5,000 short posts to a socket whose peer
reads nothing yet, and 8 MB to another: a timer fires, the second peer gets its bytes
and its end, then the first its own, in order, and its end. Before the patch it hangs:
its loop spins on the full ring, and with 100 short posts instead the timer fires but
the second peer's bytes wait behind the first's; a writer that closes a socket at once,
though it holds bytes for it, fails it too.

The patch adds 2,649 tokens to `comp.ts`. On the path of a post the loop also reads
`held[fd]` before it sends a post itself, and for each post the pointer to the block it
fills, and it no longer reads the writer's head a second time to look for room; the
writer tests its count of held sockets for each post, and moves to the next block at
each block's end. Under callgrind, with replies posted, a request costs what it did,
within what moves between runs: at pipeline 16, GET, SET and INCR take 3,434, 4,375 and
4,519 instructions against 3,390, 4,377 and 4,578 without the patch; without a pipeline,
10,849–10,992, 12,355–12,812 and 12,350–13,113 against 10,976–11,592, 12,364–12,389 and
12,640–12,756 (how many requests a wake finds moves a run by up to 6%). Throughput, in
pairs (`tools/bench_pairs.sh`: three trials, 100,000 keys, 20 clients) of the build with
the reviews merged (this patch, the next one and the protocol's fixes) against the build
before them, moved within what moves between trials: with replies posted on two cores,
GET, SET and INCR at 1.036, 1.023 and 0.928 of it at pipeline 16, and 1.113, 0.967 and
0.979 without a pipeline; sent from the loop on one core, 0.972, 1.015 and 0.945, and
1.037, 0.973 and 1.035.

## 3zp. Clients that wait

**What there is.** BLPOP, BRPOP, BLMOVE, BRPOPLPUSH, BLMPOP, BZPOPMIN, BZPOPMAX and BZMPOP,
the blocking commands of Redis 7.0.15's lists and sorted sets, and CLIENT UNBLOCK with
TIMEOUT and ERROR (XREAD and WAIT wait on what BendKV does not have). A blocking command
is the pop it makes once a key it waits on holds what it pops: LMPOP of its keys (BLPOP
and BRPOP pop one element and answer the key and the element), LMOVE of its source
(BRPOPLPUSH, BLMOVE) or ZMPOP (BZPOPMIN and BZPOPMAX answer the key, the member and its
score). Its timeout is read as Redis 7.0.15 reads it, a long double of seconds, with its
errors, its quirks included (`inf` and `1e400` are "timeout is negative", as Redis's cast
of them to a long long makes them); 0 waits for ever, and so does a time too far to add
to the clock, whose sum wraps in Redis. A command that finds what it pops answers at
once; one that finds nothing makes its client wait. As in Redis: the call is counted when
the client starts to wait; a client whose time is up gets a null array (`*-1`) and counts
nothing more; CLIENT UNBLOCK reads its reason before the id, ends the wait with a null
array (TIMEOUT) or `-UNBLOCKED client unblocked via CLIENT UNBLOCK` (ERROR), and counts
the waiting command's call failed either way, its error with ERROR, and with ERROR its own
call failed too (Redis counts an error reply that comes while a command runs against that
command, `incrCommandStatsOnError`); the commands a client sent after its blocking one
wait with it, as Redis leaves a blocked client's input unread; a client that closes its
connection while it waits is forgotten; INFO counts `blocked_clients` and
`clients_in_timeout_table`. A blocking command run while the client's replies are off
(CLIENT REPLY OFF or SKIP) waits and pops the same, and its reply is dropped.

**In the actor.** The clients that wait are one chain in the order they came (`Waits`),
each with its connection before and after the blocking command, its pop, its database,
its deadline and the rest of its batch. While one waits, every batch runs the general way,
a command at a time (`bg.go`, which now runs every batch that cannot run the fast way: one
with a command of the connection or of the server, or from a client not authenticated or
whose replies are off); after each command, the actor looks down the chain for the
first client one of whose keys, in its own database, holds what it waits for, makes its
pop there, takes it out, and looks again until none is ready. A client served goes on
with the rest of its batch at the end of the group, after its reply; a batch that waits
again joins the end of the chain. At the end of each group, the clients whose time is up
get their null arrays; a tick of the cron (`hz`, 10 a second by default) makes a group,
so a timeout fires within a tick of its time, as in Redis, which looks at its timeouts
before it sleeps, at least once a tick of its cron. The pop of a client served is logged
as the command that makes it: LPOP or RPOP with its count, LMOVE, ZPOPMIN or ZPOPMAX
(Redis logs the same).
To the session and to the proofs, a blocking command is its pop run once: a key that
holds what it pops answers as the blocking command does, and none answers as Redis
answers a client that may not wait, inside MULTI (a null array, or a null for BRPOPLPUSH
and BLMOVE); the actor runs the same pop when it serves the client, so what a served
client does to the databases is what the proved commands do. The waiting itself, who is served when,
is outside the proofs; CLIENT UNBLOCK is a session command that changes nothing in them
(answering 0), as it is for a session that has no client waiting.

**On the connection.** The answer to a batch whose client waits is `Hold`, with the
replies before the blocking command. The connection sends them, puts out a watch on its
socket (`TCP.watch`, the twenty-fifth patch) that puts `Ready` on its own channel when
bytes come or the client closes it, and waits on the channel: for the actor's answer
(the watch taken back, a `Ready` it put dropped, the replies sent, and the bytes that
came meanwhile read on, as after any batch), or for `Ready` (the bytes kept for after the
batch; a close tells the actor the client is gone, and the connection ends once the actor
answers that it holds nothing more for it).

**A type travels as wide as its widest form, a third time.** The first version passed
the state of a batch run the general way (its replies, effects, connection, server,
databases, the chain and the clients served) as a flat record: the widest result in the
program went from 17 words to 30 and the bank of registers that every segment shares from
28 to 48, and every request paid, though no client waited: GET 3,327 instructions, SET
4,252, INCR 4,512 against 3,256, 4,180 and 4,431 before (+2.2%, +1.7%, +1.8%; sections 3p
and 3zl met the same trap). Now that state is a node of its own (a type with a variant
that holds itself), the chain of clients is one word (a type that holds itself), and the
functions of the general way pass less: the bank is 26 registers, the widest result 17,
and a request costs GET 3,272, SET 4,194 and INCR 4,454 (+0.5%, +0.3%, +0.5%).

**Two bugs below BendKV.** Redis's suite stopped in unit/introspection, the server gone:
a client whose replies were off sent a command of the database (CLIENT REPLY OFF, then
PING), and at the next tick the server read the statistics of commands from freed memory
(`SIGSEGV`). The compiler's node update (the fifth patch) had
kept the node of the batch's state across the call to `S.run_log`, re-reading after the
call the fields it had not saved. The server's state was used twice, by the run and by the
connection's next state after it, so `term_keep` shared its words before the call,
wrapping each raw word in a count of two; the node kept the raw words. After the call the
re-read raw word went to the second use, which dropped it and freed the statistics, while
the run's answer held the wrap. The twenty-sixth patch writes a shared field back into the
node it is kept in (one store); it adds 27 stores to BendKV, all in the functions of the
general way, and no other function had the pattern (the instructions per request did not
move). The second: under the load of a build, a client served (by a push, or a MOVE), its
pop made, sometimes never got its reply. Its connection had woken on `Ready` from a watch that fired
for nothing, read the socket, found nothing, and waited there for bytes, the actor's answer
on its channel. The runtime keeps for each socket a flag of an edge that came while no one
waited on it, and a watch put out with the flag up fires at the next poll; but an edge the
loop sees only after a read has taken its bytes raises the flag on an empty socket (or
wakes a watch put out since). A build that logs such a fire logged 4 in 3,200 wake-ups on an
idle machine; the one it traced came from the flag. The twenty-fifth patch now peeks at the
socket (`recv` with `MSG_PEEK`) before it fires, and waits for the next edge when there is
nothing to read. Before it, 8 of 1,200 wake-ups after a MOVE were lost under load, and the
test below failed 13 runs of 30; after it, none of 10,500, and 60 runs passed.

**Tests.** `tests/blocking_test.py` runs in `make test` against each mode of the server:
18 scenarios on BendKV and on Redis, each with clients of its own, their transcripts
compared line by line (61 lines: pushes that serve, timeouts, CLIENT UNBLOCK with its
errors, a client that closes while it waits, the fairness of a pipeline that pushes and
then waits itself, BLMOVE chains and a circle of BRPOPLPUSH, a move onto a key of the
wrong type, commands and bytes behind a blocking one, sorted sets, a list that does not
serve a client waiting for a sorted set, INFO's statistics, a timeout with a pipeline
behind it, RENAME, MOVE and SWAPDB that
make a key, CLIENT REPLY OFF, a client served that waits again, a SELECT and a QUIT in
the batch of a blocking command); then BendKV under load: 300 clients served on 300 keys,
100 timeouts at once, 100 clients that leave while they wait (none left waiting, the
elements pushed after them kept), and 50 consumers that move 1,000 items with BRPOPLPUSH
while some leave, each item moved once. Redis's suite: 746 of the 1,673 tests Redis passes
(44.6%; 733 before), unit/type/zset 192 of its 289 (180) and unit/introspection-2 28 of its
43; unit/type/list still stops at its HELLO 3 after 15. With the tests of RESP3, MULTI,
DEBUG, SORT and replication left out, unit/type/list passes the 140 tests Redis passes,
and unit/type/zset 260 of Redis's 276, the other 16 using RESP3 within a test.

**Where BendKV differs.** Redis serves the clients of the keys a command added
(`signalKeyAsReady`, from `dbAdd`, and SWAPDB's scan), key by key in the order the keys
became ready; BendKV looks at every client after every command, in the order they came,
so when one command readies several keys (SWAPDB), clients waiting on different keys may
be served in another order. Inside a transaction a blocking command answers at once, as
in Redis (section 3zq).

## 3zq. Transactions

**What there is.** MULTI, EXEC, DISCARD, WATCH and UNWATCH, as Redis 7.0.15 runs them
(`multi.c`). After MULTI a command is queued and answered `+QUEUED`, but for EXEC,
DISCARD, MULTI (`ERR MULTI calls can not be nested`), WATCH (`ERR WATCH inside MULTI is
not allowed`), QUIT and RESET, which run. A command refused as it is queued (an unknown
command, a wrong number of arguments, NOAUTH) answers its error and flags the
transaction, and EXEC then answers `-EXECABORT Transaction discarded because of previous
errors.`; an EXEC refused itself (its arguments, NOAUTH) aborts the transaction, in MULTI
and out of it, with its reason (`-EXECABORT Transaction discarded because of: wrong
number of arguments for 'exec' command`), as Redis's `rejectCommand` does. EXEC and
DISCARD without MULTI are errors. EXEC runs the queued commands as one: their replies are
its array, an error as a command runs (WRONGTYPE) one of them; no client that waits is
served between them, a blocking command among them answers as a client that may not wait
is answered (a null array), and the clients that wait are served once EXEC is done. A key
a client watches makes its EXEC answer a null array (`*-1`), the transaction dropped,
when some command changed it after WATCH, or when it is there with its time passed as
EXEC comes (`isWatchedKeyExpired`). A change is what Redis's `touchWatchedKey` counts: a
write that changes the key, a DEL of a key that is there (not of one that is not, nor an
SADD of a member there, nor an SMOVE's destination that held the member already), FLUSHDB
and FLUSHALL of a database that holds it, SWAPDB of two databases where it is there in
either (`touchAllWatchedKeysInDb`, a SWAPDB of a database with itself none), MOVE (the
key in both databases), COPY (its destination), RENAME (both keys) and the sweep of
expired keys; a key watched while its entry lay there with its time passed (Redis 7.0's
`expired` flag) is not changed by the deletion of that entry, only by a write that sets
it again. EXEC, DISCARD, UNWATCH, RESET and a connection that closes unwatch the keys.
The calls are counted as Redis counts them: a command queued when EXEC runs it, a command
refused as it is queued as rejected, EXEC itself once, failed only when its own reply is
an error. CLIENT REPLY OFF and SKIP hold back the replies of a transaction as Redis does,
QUEUED and EXEC's array included.

**In the actor.** The session answers the five commands as a client with no transaction
is answered (MULTI and WATCH `+OK`, EXEC and DISCARD their errors), so the connection's
state and its proofs did not change; the actor keeps the clients' transactions, a chain of
the clients that have one or watch keys (`Tx`: in MULTI or not, flagged, touched, the
commands queued and the keys watched, each with its database and Redis's `expired` flag),
and acts on the commands as they run (`bg.cmd`). While the chain is empty it costs
nothing; while it is not, every batch runs the general way, a command at a time, so that
after each command its effects (the commands the append-only file logs for it) touch the
keys they name, the presence of each key before and after telling a change from none, and
FLUSHDB, FLUSHALL and SWAPDB touch as Redis's rules for them say. EXEC runs the queued
commands the general way too, with no client served between them, and its effects, when
they are two or more, are one entry of the file, between a MULTI and an EXEC, as Redis
writes them (Redis 7.0 does not wrap a transaction that propagates one command). A client
that closes its connection tells the actor (`Left`), which forgets its transaction.

**In the file, and in the laws.** A file cut by a crash inside a transaction ends with
its MULTI and some of its effects. Redis reverts such a transaction ("Revert incomplete
MULTI/EXEC transaction in AOF file") and cuts the file back to before its MULTI; so does
BendKV (`A.untx`: read from the end, the last mark decides, a MULTI before any EXEC
cuts there), and with `aof-load-truncated no` both stop the start ("Unexpected end of
file reading the append only file"), as for an entry cut short. The laws of persistence
now see a history whose batches are commands, or the commands of a transaction (`RunTx`),
and a file whose entries (`A.Ent`) are an effect, or a transaction's effects between
MULTI and EXEC. `recover` keeps its statement: after any history the file restores
exactly the databases the server held. `recover_cut` now says that a file cut anywhere
restores the databases after some prefix of the history's steps, a step being an act, or
the acts of a transaction together: none of a transaction's acts is applied unless all
of them are. The proofs: replayed, MULTI and EXEC are commands of the connection, errors
that change nothing, so an entry replays as the effects it holds (`rpe_file`); no entry
an effect writes is a mark (`mark_args`, over the strings each logged command writes:
every one is two words or more, or one word that is neither MULTI nor EXEC), so read from
the end a whole file meets each transaction's EXEC before its MULTI and the start reverts
nothing of it (`untx_all`), while a file cut inside a transaction ends with its MULTI and
entries without marks, which the start reverts exactly (`untx_open`); the first k entries
of a file are the history's first entries whole and a part of the next, a SELECT that
changes no database or a transaction's start, which is reverted (`tk`); and those entries
replay as the history's first steps (`sepe`: a step makes no entry or one). The proofs
of the file grew from 930 lines to 1,670.

**Cost.** While no client has a transaction or watches a key, a request pays one test
more, on the fast way (the chain is empty): GET takes 3,279 instructions, SET 4,200 and
INCR 4,463, against 3,272, 4,194 and 4,454 before (+0.2% at most, `make perfcheck`).

**Tests.** `tests/multi_test.py` runs in `make test` against each mode of the server: 12
scenarios on BendKV and on Redis, each with clients of its own, their transcripts
compared line by line (57 lines: replies of every kind with a SELECT inside, DISCARD, a
nested MULTI, WATCH inside MULTI, commands refused as they are queued and errors as they
run, EXEC and DISCARD without MULTI, EXEC refused in MULTI and out of it, QUIT and RESET
inside a transaction, keys changed by another client or not, a DEL of a key not there, an
SADD of a member there, an SMOVE of a member the destination holds, FLUSHALL, FLUSHDB and
SWAPDB of keys there and not, MOVE, COPY, RENAME, EXPIRE, a key of another database, keys
that expire by the sweep or are found expired at EXEC, UNWATCH, DISCARD and EXEC
forgetting a change, a blocking command inside EXEC and clients that wait served after
it, CLIENT REPLY OFF and SKIP around a transaction, and the statistics of INFO as
`info.tcl` reads them); then BendKV under load: 20 clients that add 1,000 to a counter
with WATCH, GET, MULTI, SET and EXEC (each lost race retried; the counter ends at 1,000),
a reader that never sees half of a transaction (an MGET of two keys that 500 transactions
increment together), and 100 clients that close their connections in MULTI or with keys
watched, after which a write and a transaction run as before. The differential test sends
whole transactions now and then, and MULTI, EXEC, DISCARD, WATCH and UNWATCH alone and
with wrong arguments; the tests of the append-only file revert a transaction left open
(with an entry cut short after it too), and refuse it with `aof-load-truncated no`;
BendKV restores a file Redis wrote with transactions, and Redis one BendKV wrote. Redis's
suite: 759 of the 1,673 tests Redis passes (45.4%; 746 before). unit/multi passes 25 of
its 53 (the others read the replication stream, need Lua, SORT, XGROUP or maxmemory's
OOM, or run after a test of OOM that left its client in MULTI), unit/other RESET's test
of the MULTI state, unit/protocol the regression test of argument rewriting (issue 9598),
and unit/type/set its test of an SMOVE onto a set that holds the member, which it watches
(it found the one difference the tests above had missed: the actor touched SMOVE's
destination there); 14 tests that passed fail now, their client left in MULTI by a test
that failed inside a transaction on a command BendKV does not have (GEOADD in
unit/introspection-2, whose 12 tests of COMMAND after it answer QUEUED; SORT; XADD), as
on a Redis without those commands.

**Where BendKV differs.** An LTRIM that removes nothing changes no watched key, where
Redis signals the key anyway. BendKV logs every DEL, of keys there or not, where Redis
logs only a DEL that deleted, so a transaction with such a DEL and one other effect is
written between MULTI and EXEC where Redis writes the other effect alone (the file means
the same).

## 3zr. Pub/Sub and keyspace notifications

**What there is.** SUBSCRIBE, UNSUBSCRIBE, PSUBSCRIBE, PUNSUBSCRIBE, SSUBSCRIBE,
SUNSUBSCRIBE, PUBLISH, SPUBLISH and PUBSUB (CHANNELS, NUMSUB, NUMPAT, SHARDCHANNELS,
SHARDNUMSUB, HELP), as Redis 7.0.15 runs them (`pubsub.c`). SUBSCRIBE and its kin answer
a reply for each name, with the count of the client's channels and patterns (of its
shard channels for SSUBSCRIBE and SUNSUBSCRIBE); a name subscribed to twice counts once;
UNSUBSCRIBE without names unsubscribes from all, and answers one reply with a null name
when there are none. A message goes to the subscribers of its channel (`message`, or
`smessage` for a shard channel), then to those of each pattern it matches (`pmessage`,
Redis's glob), and PUBLISH answers how many got it. A client with a subscription runs
(P|S)SUBSCRIBE, (P|S)UNSUBSCRIBE, PING (answered `[pong, its argument]`), QUIT and
RESET alone, as a client of RESP2 does in Redis (one of RESP3 runs any command, since
3zx): any other command is refused, once the
checks of its name and of the number of its arguments pass (an unknown command, or GET
with no key, answers its own error), with Redis's `Can't execute 'get': only
(P|S)SUBSCRIBE / (P|S)UNSUBSCRIBE / PING / QUIT / RESET are allowed in this context`,
counted as rejected; an EXEC so refused answers EXECABORT with that reason. The replies of
SUBSCRIBE and its kin go out even to a client whose replies are held back (CLIENT REPLY
OFF or SKIP), as Redis pushes them. In a transaction SUBSCRIBE and PSUBSCRIBE run, and
the client has its subscription after EXEC, while SSUBSCRIBE is refused (`SSUBSCRIBE
isn't allowed for a DENY BLOCKING client`), as in Redis. RESET, QUIT and a connection
that closes drop the client's subscriptions.

**Keyspace notifications.** With `notify-keyspace-events` set (K, E, g, $, l, s, h, z,
x, n and A, read and shown as Redis reads and shows them: A for the classes it covers,
n kept but not shown beside A), each change a command makes is published as Redis's
`notifyKeyspaceEvent` publishes it: the event's name to `__keyspace@<db>__:<key>` (K)
and the key to `__keyevent@<db>__:<name>` (E). Each command has Redis's events: `set`,
`expire` (after `set` for SET with a time), `del`, `persist`, `incrby`, `incrbyfloat`,
`append`, `setrange`, `setbit`, `rename_from` and `rename_to`, `move_from` and
`move_to`, `copy_to`, `lpush`, `rpush`, `lpop`, `rpop`, `linsert`, `lset`, `lrem`,
`ltrim` (sent whether it trims or not), `sadd`, `srem`, `spop`, `sinterstore` and its
kin, `hset`, `hdel`, `hincrby`, `hincrbyfloat`, `zadd`, `zincr`, `zrem`,
`zremrangebyscore` and its kin, `zpopmin`, `zpopmax`, `zunionstore` and its kin,
`zrangestore`; a key a command makes is `new` (n) before them, a collection it empties
is `del` after them, and the sweep of expired keys sends `expired` (x) for each key it
deletes. A client that waits and is served (BLPOP and its kin) sends its pop's events
after the write's, as Redis does.

**In the actor.** The session keeps no subscription and knows no other client: it
answers each command of Pub/Sub as Redis answers a client alone on the server (the
replies of SUBSCRIBE and its kin gathered in one array), so the connection's state and
its proofs stay. The actor keeps the subscriptions: the subscribers of each channel and
shard channel (tries by name, as the keyspace's), those of each pattern, and each
client's channels, patterns and shard channels. A message to a client is a push (`Push`)
on the channel its answers come back on, after the answers already there, which the
connection writes out as it comes; a client with a subscription waits for its socket and
its channel at once (a watch, `TCP.watch`, as a client that waits does, section 3zp), in
steps of its own, so that the loop of every other client is as it was; its batches go to
the actor as `SubReq`, which runs them a command at a time. With keyspace events to
send, every batch runs a command at a time, and each command's events come from the
command, from whether it changed anything (its effects, the commands the append-only
file logs for it), and from what each key it writes was before it and is after it
(there, gone, or there with its time passed).

**What a word costs.** The first version made GET 70 instructions dearer (3,349, +2.1%),
for three reasons the profile of the generated code showed, segment by segment (a
build with DWARF 4, which valgrind 3.22 reads, and callgrind's lines summed by the
segment that holds them). A command travels in as many registers as its widest form, and
the session commands' widest had two fields: a PubOp of three fields inside the session
command made every request carry a word more, through the parser and the batch (11
instructions in the parser's loop alone); SPub now carries a number and its arguments,
as narrow as the others. Pub/Sub's state was eight words flat in the state of each batch,
which every function of the fast way passes on; it is one word now, a type that holds
itself (`PsOf`, never built), as the clients that wait and the transactions are. And a
flag in the connection's link, read after each answer, gave three steps of the loop a
second caller, which the compiler no longer folds into their callers; the subscribed
client has steps of its own now. GET, SET and INCR take 3,288, 4,209 and 4,471
instructions (3,279, 4,200 and 4,463 before, +0.3% at most, `make perfcheck`).

**Tests.** `tests/pubsub_test.py` runs in `make test` against each mode of the server:
scenarios on BendKV and on Redis, their transcripts compared line by line (191 lines:
PING of a subscribed client, one client and two, UNSUBSCRIBE of some and of all, a
channel subscribed to more than once, names not subscribed to, patterns with classes,
escapes, `?`, `*` and the empty channel, NUMSUB, NUMPAT of shared patterns, message
before pmessage, the commands a subscribed client may not run and those whose checks
come first, RESET and QUIT of a subscribed client and one that closes its connection,
CLIENT REPLY OFF and SKIP, SUBSCRIBE in a transaction and SSUBSCRIBE refused there,
batches that subscribe and unsubscribe at once, PUBSUB's subcommands and errors, shard
channels apart from the others, a message of 100 KB and 50 in a row, INFO's statistics;
then the events of 138 commands, of every kind under `KEA` and under masks, `n`, `x`
from the sweep, a key replaced after its time passed, a client that waits served, a
transaction, and `notify-keyspace-events` off), and
two checks under load: 20 subscribers of a channel and a pattern each get the 2,000
messages of 4 publishers, in each publisher's order, PUBLISH counting 40 receivers each
time; and 50 subscribers close their connections while messages are published, after
which PUBLISH counts none and a new subscriber gets what is published. Redis's suite: 785
of the 1,673 tests Redis passes (46.9%; 759 before). unit/pubsub passes 25 of the 27
tests it reaches (not the one of RESP3, nor the one of streams), and unit/other its test
of RESET clearing the state of Pub/Sub; the test of `evicted` events waits for an
eviction that never comes (there is no maxmemory yet: 3zw), so the two after it do not run: CONFIG
GET and SET of the flags, which the tests of CONFIG compare with Redis on random flags,
and `new` events, which the scenarios above check; unit/pubsubshard's tests are of a
cluster, which the suite skips against a server it did not start.

**Where BendKV differs.** UNSUBSCRIBE and PUNSUBSCRIBE of all go in the order the
client subscribed, patterns are matched in the order they came, and PUBSUB CHANNELS
lists in the order of the trie, where Redis goes in the order of its hash tables (the
tests compare these sorted). There was no RESP3, so no push type (pushes since 3zx). A
slow subscriber's
messages wait in its channel without the limit of `client-output-buffer-limit pubsub`.
Keys missed (`m`), evicted (`e`, sent since 3zw) and the events of streams are not sent; a key that a
read finds with its time passed sends `expired` when the sweep deletes it, where Redis
sends it at the read. A message a client publishes to a channel it subscribed to in the
same transaction goes out before EXEC's array, where Redis puts it inside the array's
bytes, after its count.

## 3zs. CLIENT LIST, INFO and KILL

**What there is.** CLIENT LIST (all clients, those of a TYPE: normal, master, replica or
slave, pubsub; or those of the IDs given, in their order), CLIENT INFO, and CLIENT KILL
in its old form (an address, answered OK or `ERR No such client`) and its new one (the
filters ID, TYPE, ADDR, LADDR, USER and SKIPME, answered the count of clients killed), as
Redis 7.0.15 runs them (`networking.c`), with its errors (`ERR Invalid client ID`, `ERR
Unknown client type '...'`, `ERR client-id should be greater than 0`, `ERR No such user
'...'`, the syntax errors). A client's line has Redis's 27 fields in Redis's order: its
id; its address and its local address as Redis formats them (`ip:port`, `[ip]:port` for
IPv6) and its socket's fd; its name (CLIENT SETNAME, HELLO's SETNAME, cleared by RESET);
its age and idle time in whole seconds, as Redis subtracts its unix times; its flags in
Redis's order (P with a subscription, x in MULTI, b waiting in a blocking command, d with
a watched key touched, e with CLIENT NO-EVICT on, N for none); its database (SELECT,
RESET); its counts of channels, patterns and shard channels; multi, -1 or the number of
its commands queued; for the client that asks, the bytes of the batch its command came in
(qbuf) and of the command's arguments (argv-mem), and for a client that waits, of its
blocking command's arguments; and the full name of its last command (`client|list`,
`get`, NULL before the first: the blocking one while the client waits, the last of the
rest of its batch once it is served). While EXEC runs a transaction, the client's own
line shows it in MULTI with its commands queued, EXEC as its command, and the bytes of
EXEC's batch and argument, as Redis shows it. A client killed is cut off at once,
wherever it waits (in a read, in a blocking command, subscribed): its transaction, its
wait and its subscriptions are dropped, what it waited for is left as it was, and
connected_clients counts it out. The old form on the client's own address, and SKIPME no,
kill the client itself after its reply (in a transaction, after the rest of the
transaction), as Redis closes a client after its reply.

**In the actor.** The actor keeps a registry of its clients in the state of Pub/Sub (one
word in each batch's state, with the subscriptions): for each client its id, the channel
its answers go back on, its socket's fd and its addresses, the time it came, its name,
its database and its NO-EVICT, in a trie by id. A connection sends the actor its fd and
addresses (`TCP.name`, the twenty-seventh patch) with its first message (Join), and
leaves with its last (Left); the name and the database are written after a batch that ran
SETNAME, HELLO, SELECT or RESET, which run the general way. What changes with every
batch, the client's last command and its time, would cost a write to the registry for
each batch; it is a mark on the client's answer channel instead (`Chan.mark`: a table of
the runtime by the channel's row and generation, which the actor alone writes and reads),
a call a batch, and the fast way takes the last command's code from the batch's tally,
which it counts anyway. CLIENT KILL takes a client out of the registry, of the clients
that wait, of the transactions and of the subscriptions, and keeps its id and its fd; at
the end of the group, before its answers go out (after the group's entries are written,
with the append-only file), the actor's loop shuts each fd down both ways (`TCP.kill`),
so that the connection's read, or its watch, finds the end at once. Until a killed
client's connection says Left, the fast way is off (a bit of the word of the Pub/Sub
state that turns it off while keyspace events are to be sent), and a batch of that client
is answered Bye without running, as Redis frees a client with its query buffer. The fd
shut down is still that client's socket: a connection closes its socket only after the
actor's answer to its Left, and the actor takes the fd out of the registry in the group
that kills the client.

**What a word costs.** The first version made GET 51 instructions dearer (3,337): a
batch's last command was found by a walk of its hashes, one a request, with a reference
kept at each step; the code comes from the batch's tally now, which holds its runs newest
first. And a connection formatted its addresses with `inet_ntop` and `snprintf`, some
3,500 instructions of printf a connection; they are written by hand now. GET, SET and
INCR take 3,303, 4,224 and 4,482 instructions (3,286, 4,211 and 4,475 for the code
before, built by the same compiler and counted in turn: +0.5% at most, `make perfcheck`).

**Tests.** `tests/client_test.py` runs in `make test` against each mode of the server:
scenarios on BendKV and on Redis, their transcripts compared line by line, a client's
line field by field with what differs between two servers by nature put aside (ids,
addresses and fds compared as the client that holds them, age and idle as whether they
reach two seconds, the sizes of buffers BendKV does not keep): 41 lines (a client's own
line, inline and in a pipeline; LIST of ids and of types and their errors; another
client's name, database, last command (an unknown one, one refused for its arguments, a
subcommand, the last of a pipeline) and idle time; the flags P with its counts, x with
the commands queued and the line of a client while EXEC runs its transaction, b with its
blocking command's arguments, also with commands after it, d and e; KILL's errors; KILL
by id, address, local address, type and user, of the client itself, of a client that
waits, of one in MULTI, inside a transaction, and of all). And two checks under load: 100
clients at once, all listed and answering, half of them killed by id, the others still
answering and listed alone; 200 clients killed by address while four threads of clients
connect and close, none killed but those named, and connected_clients back to one after.
A connection now waits for the actor's answer to its Left before it closes its socket, so
it is counted a little longer as it ends: `tests/conn_test.py`, which counts connections
after 50 that end each way, read one count, then another, and a connection the server
took late (after its client reset it) could fall between them; it waits for ten counts of
one in a row now. Redis's suite: 794 of the 1,677 tests Redis passes (47.3%; 785 before):
unit/introspection passes 23 of its 28 (its five others are MONITOR's): CLIENT LIST, of
IDs, with names and without, CLIENT INFO, KILL's errors, KILL SKIPME yes and no of all
the clients, and a client named by SETNAME that closes its connection and leaves the
list. unit/querybuf's two tests now get past CLIENT LIST, to the size of the query buffer
of a client, which BendKV does not keep. And the runner of the suite starts an instance
of the server for each unit now: unit/pubsub's test of `evicted` events, which never
come, left `maxmemory 1` and `allkeys-lru` behind, and a unit/type/incr that ran after it
on the same instance found INCR's shared integers counted once (OBJECT REFCOUNT 1, as
Redis counts them under an LRU policy); on fresh instances, 4 more tests of streams run
on Redis, and pass (1,677 of 1,757).

**Where BendKV differs.** BendKV keeps no buffers per client: the sizes Redis gives
(qbuf-free, rbs, rbp, obl, oll, omem, tot-mem) and multi-mem (the queued commands are the
actor's, not the client's) are 0, and so is qbuf of a client other than the one that asks
(a client that waits with commands after the blocking one holds them as commands, where
Redis's query buffer holds their bytes). Idle time counts from the client's last batch,
where Redis also counts a reply written (to a subscriber that gets messages, to a client
that waited and was served). user is `default`, redir -1 and resp 2 (no ACL, no tracking;
resp 3 for a client of RESP3 since 3zx), and events `r`. There is no CLIENT KILL MAXAGE (Redis 7.4). A client killed is
cut off at the end of the actor's group, before any of the group's answers goes out,
where Redis frees it at once.

## 3zt. MONITOR

**What there is.** MONITOR as Redis 7.0.15 runs it (`monitorCommand`, `call()` and
`replicationFeedMonitors`): the client becomes a monitor, answered OK (a monitor already
is answered nothing, its call counted), and each call that runs after it, of any client,
sends every monitor a line: the time, the database after the call and the client's
address, `+<s>.<us> [<db> <ip:port>]`, then the call's arguments as its client sent them
(their case kept, an inline request split as Redis splits it), each quoted as Redis's
`sdscatrepr` quotes it (`\"`, `\\`, `\n`, `\r`, `\t`, `\a`, `\b`, a byte outside the
printable ones as `\xhh`). A call sends its line as `call()` would: a command the parser
refuses (unknown, the wrong number of arguments), one refused before the client
authenticated, to a subscribed client or to a monitor, and one queued in a transaction
send none; the queued ones send theirs as EXEC runs them, before EXEC's own, and an EXEC
refused sends its line all the same, as `execCommandAbort` does. A blocking command's
line goes out when it blocks, not when it is served. The administrative commands (CONFIG,
CLIENT LIST, KILL, NO-EVICT and UNBLOCK, MONITOR) and EVAL send none (Redis's flags
`admin` and `skip_monitor`, generated with the table of commands), and AUTH's password
and HELLO's user and password are `"(redacted)"`, as Redis redacts them while it reads
them: AUTH's when it has two arguments at most, HELLO's after a version Redis takes (2
or 3), up to its first option that is not right. A monitor reads and writes nothing: a
command that reads or writes keys, or may be replicated (PUBLISH, SPUBLISH, EVAL;
`may_replicate`, which COMMAND INFO hides), is refused "ERR Replica can't interact with
the keyspace" once the parser's checks, the client's authentication and a
subscription's limits pass, as Redis refuses it to a replica (in MULTI it flags the
transaction); MONITOR queued in a transaction answers "ERR MONITOR isn't allowed for
DENY BLOCKING client" as EXEC runs it. A monitor's own call is answered first, then its
line comes; with CLIENT REPLY OFF, or SKIP before its next command, a monitor gets no
line, its own neither, as Redis drops what it writes to such a client, and after QUIT
its own QUIT's line does not reach it. RESET makes it no monitor (the other monitors get
its RESET), as do the end of its connection and CLIENT KILL. CLIENT LIST shows a monitor
with the flag O, its type normal.

**In the actor.** The monitors are a list in the registry of clients (Clients), each with
its id, its answer channel and whether its replies were on as its last batch ended, in
the order they came. While there is one the fast way is off, a bit of Pub/Sub's word as
for a killed client; the word's classes of keyspace events, which make the actor work
out a command's events, are its low bits alone now, so neither bit makes it work out
any. After each call of the general way the actor writes the call's line once, pushes it
to every other monitor whose replies are on (Push, as a message to a subscriber; a
monitor's connection waits as a subscribed client's does), and puts it among the
client's own replies when the client monitors, after the call's reply (after EXEC's
array, for the calls EXEC runs). The arguments as sent come from the bytes the batch
came in: every batch brings them to the actor (Req's raw), the fast way drops them, and
the actor reads them into each request's arguments (`P.argvs`, the parser's framing
again) only when a line needs them, at the first line of the batch. The rest of a batch
after a blocking command keeps its arguments with it, and so does each command queued in
a transaction, so that a monitor that starts while a client waits, or queues, sees their
lines as Redis's monitor would.

**What a buffer costs.** The bytes a batch came in were the parser's: it read them, and
cut the tail of an unfinished request off them (String.drop, which drops what comes
before it). Kept for the actor while the parser read them, they were shared, and a
shared buffer is shared at a cost (`rfc_wrap`), read through a redirect at every
String.code_at, find and slice of the parse, and dropped at a cost: GET took 25 more
instructions with 16 requests a batch, and 251 more without pipelining (10,373, +2.5%).
The parser now takes the buffer and gives it back with the batch (Batch's raw), copies
out the tail of an unfinished request (a copy where String.drop made a view; there is
one only when a read ends inside a request), and parses a request longer than a window
where it lies: nothing shares the buffer, which the actor drops where the connection
did. GET, SET and INCR take 3,298, 4,223 and 4,485 instructions (3,299, 4,223 and 4,489
for the code before, built by the same compiler and counted in turn), and GET without
pipelining 10,100 (10,122).

**Tests.** `tests/monitor_test.py` runs in make test against each mode of the server:
scenarios on BendKV and on Redis with clients of their own, their transcripts compared
line by line, a monitor's line with its time and the client's address put aside: 41 lines
(the case of a command as sent, quoted bytes, an inline request, numbers; what is not
shown and what is; MULTI, the queued commands at EXEC, its errors, DISCARD, a nested
MULTI, WATCH, an EXEC refused, MONITOR in a transaction; the database after SELECT,
SWAPDB and MOVE; AUTH and HELLO redacted, and not; a blocking command that times out, one
served, one with a pipeline after it; a monitor's own commands, refused ones, MONITOR
again, MULTI and EXEC of a monitor; a subscribed client, a subscribed monitor; CLIENT
REPLY OFF, ON and SKIP of a monitor; a client without a password; monitors that start
while a transaction is queued and while a client waits with a pipeline; CLIENT LIST's
flag O; RESET, QUIT and CLIENT KILL of a monitor; MONITOR in a pipeline; INFO's
statistics). A monitor's lines are read up to a marker, a command of a client of their
own whose line comes after those of the commands before it. And a check under load: four
monitors and 20 clients that each pipeline 200 SETs, each monitor getting every line,
each client's in its order. Redis's suite: 797 of the 1,677 tests Redis passes (47.5%;
794 before): unit/introspection passes 25 of its 28, a monitor's lines of the commands
that run and a transaction's in order, with its EXEC's line also when an error while it
queued aborted it (its other three look in a monitor for the calls of a Lua script and of
a function, and for MIGRATE's arguments redacted), and unit/other the test of RESET
clearing a monitor's state.

**Where BendKV differs.** A line's time is the group's (the actor runs a group at one
time), in ms: its microseconds end in 000, where Redis reads its clock for each call.
The calls EXEC runs for a monitor put their lines after EXEC's array, where Redis writes
them between the array's replies (and a client reading the array then misreads it).
HELLO 3 was refused (BendKV spoke RESP2 alone; it takes it since 3zx), its user and
password redacted all the same, as Redis redacts them for a version it takes.

## 3zu. Authentication as Redis decides it

Two rules of Redis's that BendKV did not follow, found when MONITOR's tests compared a
client without a password.

**When a client is asked.** Redis asks a client for AUTH (`processCommand`) after it has
looked the command up and checked its number of arguments against the command's table,
and before the command runs. An unknown command or subcommand, and a number of arguments
the table refuses, are answered as they are, whoever the client is; an error the command
finds as it runs (a syntax error, a value that is not an integer, a number of arguments
the table allows and the command does not, as PING with two) is NOAUTH for a client that
must authenticate. BendKV's parser finds those errors itself, before anything runs (Bad,
and a session command's SBad), and the session answered every error the parser found,
whoever the client was: `SET k v EX abc` from a client that had not authenticated was
answered "ERR value is not an integer or out of range", where Redis answers NOAUTH. INFO
already told the two kinds apart (a call refused, a call failed: `stat.class`), so the
server now takes a failed call's error as a session command of its own, SFail
(`R.fail.if`, where the request's code is worked out), which a client is answered only
once it may run commands; Bad and SBad are what Redis refuses before it asks for AUTH. A
batch with a failed call runs the general way, as a batch with a command of the
connection does; GET, SET and INCR are parsed without it.

**Who is authenticated.** Redis authenticates a client as it connects when there is no
password then (`createClient`, `clientSetDefaultAuth`), and at RESET when there is none
then; AUTH, and HELLO's AUTH, authenticate it; nothing else changes it. A password set
later asks nothing of a client already authenticated, and a client that never
authenticated is asked again when a password removed is set again, whatever it ran while
there was none. BendKV marked a connection authenticated after any command it ran while
there was no password (`step_conn`: a client that may run commands is authenticated), so
it asked a client that came before the password and had sent nothing yet, and let through
a client that came while there was a password, ran a command while there was none, and
came back after it was set again. Now a connection keeps its authentication as Redis
keeps it: the actor answers a connection's Join with its state as it comes, authenticated
when there is no password then (`S.conn_join`), and only AUTH, HELLO and RESET change it
(`step_conn` and the other steps of a connection keep it, and the fast way leaves the
connection as it was). The connection waits for that answer before its first read: a pass
through the actor per connection, not per request.

**Proofs.** SFail is a session command that needs a client that may run commands, so the
law `noauth` (a client that has not authenticated, to a server with a password, runs
nothing on the databases but the errors the parser found) holds with three more cases, as
for MONITOR. The lemmas of the fast way (it runs a batch as the general way does) carry
the client's authentication through the batch where they set it, and the proof that a
client that has not authenticated stays so reads it from the client's state
(`or_false_l`).

**Tests.** `tests/auth_test.py` runs in make test against each mode of the server:
scenarios on BendKV and on Redis, their transcripts compared line by line: 72 lines (27
commands, an error of each kind and commands that run, from a client that must
authenticate, one at a time and pipelined, and once it has; a failed AUTH; HELLO with
AUTH and without; RESET with a password and without; a password removed and set again; a
pipeline that sets the password and goes on; a transaction with errors of each kind; a
subscribed client's errors; INFO's commandstats and errorstats). On the code before, 17
of them differ. `tests/monitor_test.py` no longer authenticates the clients that came
before the password, which only BendKV needed.

**Cost.** GET, SET and INCR take 3,303, 4,223 and 4,487 instructions (3,302, 4,222 and
4,485 for the code before, built by the same compiler and counted in turn): the requests
that go the fast way are parsed and run as before. A new connection waits for the actor
once more before its first read, which does not show against the ~90 µs a client in
Python takes to connect, send PING and close (3,000 of them in a row, three runs each
way).

## 3zv. The rewrite of the append-only file

**What there is.** BGREWRITEAOF as Redis 7.0.15 answers it (`bgrewriteaofCommand`):
"Background append only file rewriting started"; while a rewrite runs, the error
"Background append only file rewriting already in progress"; in EXEC, "Background append
only file rewriting scheduled", and the cron starts the rewrite at its next look, as
Redis's `serverCron` starts one scheduled. The cron also rewrites a file that has grown,
as Redis does with appendonly yes: past `auto-aof-rewrite-min-size`, and by
`auto-aof-rewrite-percentage` (not 0) of its size after its last rewrite (or at the
start; a base of 0 counts as 1), logged "Starting automatic rewriting of AOF on N%
growth"; after three failed rewrites in a row it holds its own rewrites back a minute,
then two, four and so on up to an hour (`aofRewriteLimited`, logged as Redis logs it),
and a rewrite asked for in EXEC forgets the failures and starts all the same. INFO's
persistence section shows it as Redis does: `aof_rewrite_in_progress`,
`aof_rewrite_scheduled` (and `aof_pending_rewrite`), `aof_last_rewrite_time_sec` and
`aof_current_rewrite_time_sec` (whole seconds, -1 for none), `aof_last_bgrewrite_status`,
`aof_rewrites` and `aof_rewrites_consecutive_failures` (CONFIG RESETSTAT counts both
again), and after a rewrite `aof_current_size` and `aof_base_size` are the new file's
size. With appendonly no BGREWRITEAOF writes `appendfilename` all the same, as Redis
does, and a server started with appendonly yes then reads it.

**What it writes.** The commands that make the databases as they are when the rewrite
starts, as Redis's `rewriteAppendOnlyFileRio` writes a base without an RDB preamble: a
SELECT of each database that holds keys, then for each key its SET, RPUSH, SADD, HMSET
or ZADD, 64 elements or pairs to a command (`AOF_REWRITE_ITEMS_PER_CMD`), a score as
`%.17g` writes it (`F.f64.show`), and the PEXPIREAT of the time it expires at when it
has one; then the entries the server appended to the file since the rewrite started,
the first of them after a SELECT of its own (Redis's `aof_selected_db = -1`). The file
is written to a temporary file next to it (`temp-rewriteaof-bg-<pid>.aof`; a rename does
not cross file systems), synced each 4 MB as it is written when
`aof-rewrite-incremental-fsync` is yes (its default; Redis's child syncs its file so,
`REDIS_AUTOSYNC_BYTES`) and at its end, renamed onto the file (`File.rename`, the
twenty-eighth patch: whoever opens the file finds the old one or the new one, whole),
and its directory synced; the actor then appends to the new file, and the syncer of
everysec opens the file each second instead of keeping a handle of its own, since a
rewrite puts a new file at its path. A rewrite that fails (a temporary file it cannot
make, write or sync, a rename that fails) logs why and "Background AOF rewrite
terminated with error", removes the temporary file (`File.unlink`) and leaves the file
as it was; one that fails after its rename (the directory's sync, the new file's
opening) stops the server, as a failed write to the file does: the new file's name may
not be on the disk, and the acknowledged writes after it with it.

**Without a fork.** Redis forks a child, which writes the memory as it was at the fork
while the parent goes on. BendKV's databases are values: the actor keeps them as they
are when the rewrite starts (the snapshot: nothing is copied, a write after it makes new
nodes where it changes nodes the snapshot shares, as the child's pages are copied when
the parent writes them) and writes them a slice at a time, the keys of a few dozen
entries of a database's trie (`A.rw.slice`, a scan from a cursor, as SCAN's), encoded and
kept until 64 KB of them go to the temporary file, each slice then with a turn of the
event loop (`IO.sleep(0)`) for the connections. When a slice comes and how large it is
weighs the rewrite's time against the requests' wait: after a group of requests, a slice
of 64 entries, at most one each 4 ms, so that a load that never lets the actor wait
gives the rewrite a small part of its time; while no request waits, slices of 32 entries
one after another (a request that comes meanwhile waits for one, about a tenth of a
millisecond), and of 256 once no group has run for 10 ms (`idle.step`: the server is
idle, and the rewrite goes faster). The entries the actor appends to the file meanwhile
are kept in memory too (Redis 6 kept them in its rewrite buffer; Redis 7 writes them to
a new file of its multi-part layout) and written after the snapshot, in the same step as
the rename, so that no group runs between the last of them and the switch.

**What a rewrite costs the requests.** 950,000 keys, a file of 42.7 MB, on a machine of
four cores whose own spread from one measure to the next is a fifth either way: with no
load the rewrite takes 3 to 4 s (2.9 to 3.1 s with `aof-rewrite-incremental-fsync no`:
the syncs each 4 MB cost a quarter of it). Under redis-benchmark's GET at full speed (20
clients, pipelines of 16), GET gives 414,000 to 460,000 requests a second while the
rewrite runs, against 513,000 to 788,000 without one; its p99 is 1.4 to 1.6 ms against
0.8 to 1.6 ms, and its longest wait 8.5 to 21 ms against 4 to 42 ms (without a rewrite,
the syncs of everysec). The first version wrote a slice of 256 entries after each group
and one after another while no request waited: the rewrite took 3.3 s, but GET fell to
about 220,000 requests a second, and the last sync, of the whole file at once, held the
actor 90 ms; the syncs each 4 MB brought that wait to 30 ms, and the slices as they are
now gave the numbers above.

**What it cost.** GET, SET and INCR take 3,301, 4,228 and 4,488 instructions (3,300,
4,226 and 4,489 for the code before, counted in turn). The first version took 3,567,
4,549 and 4,811 (+8%), for two reasons. The cron's look read two parameters of the
configuration (a walk of its 178 items) every 100 ms of the actor's time; under
callgrind, whose slowness stretches a measure over many of them, that was 65 instructions
a request, and the look now reads them only with appendonly yes, and the second only when
the first allows a rewrite. And the rewrite's state, a record of plain fields with the
rewrite that runs inside it, traveled flat, eighteen words in every frame of the actor's
loop: the widest frame or result sets the registers of every function in the program (46
instead of 35, the widest result 29 words instead of 17), and every call and return of
every request paid for them (+1.5%). The state is now a type that holds itself (`RwOf`,
never built), which the compiler makes a node of its own, as the state of Pub/Sub and the
database are, and the registers are 35 again.

**Tests.** `tests/rewrite_test.py` runs in make test: BGREWRITEAOF's replies and INFO's
account against Redis's, line by line (started and refused while it runs, in one
pipeline; scheduled in EXEC; in EXEC while one runs; the arguments it refuses; CONFIG
RESETSTAT; the statistics of the call and of its errors); the same databases on both
(strings, lists, sets of numbers and of words, hashes, sorted sets with scores of each
form, small and past 64 elements, times to expire at, three databases), rewritten by
both, BendKV's file against Redis's base command for command (each key's commands and how
many elements each holds, its elements, its time), and BendKV and Redis started from
BendKV's file; 150,000 keys and pipelines of 200 writes of each kind on five databases
(SWAPDB, MOVE, COPY, RENAME, transactions, FLUSHDB) sent to BendKV and to Redis while the
rewrite ran (about 150 of them), more after it, the databases compared, then BendKV and
Redis started from the new file; BendKV killed (SIGKILL) while a rewrite runs, the writes
acknowledged, and started again from its file as it was; appendonly no; the cron's
rewrites (none under the minimum, none with a percentage of 0 or one the file has not
grown by, one past both); and rewrites that fail (a directory where the temporary file
goes), counted and logged, three of them holding the cron back (logged), and a rewrite
scheduled in EXEC that starts all the same.

**Proofs.** BGREWRITEAOF is a session command (SRewrite) that needs a client that may run
commands, so the law `noauth` holds with three more cases, as for MONITOR. The rewrite
itself is tested, not proved. Its law would say that the rewritten file replays to the
databases it was written from, key by key; it needs a law that a scan from the first
bucket reads every key once (the invariant that a bucket holds a key once, not yet
proved: DIRECTIONS.md), laws for RPUSH, SADD, HMSET and ZADD of a key not there, and that
a double written as `%.17g` reads back as itself. The law `recover` covers a file the
server wrote as its log from an empty one; after a rewrite, the file's head is a
snapshot, and recovery rests on the tests. What still holds for any file, the rewritten
one too: it loads as the entries written to it (`load(encode(reqs)) = reqs`), and the
start replays it only when the check accepts each entry.

**Where BendKV differs.** One file, Redis 6's layout, where Redis 7 keeps a base and
increments with a manifest (`appendonlydir`); Redis 7 reads BendKV's file as a file of
Redis 6 (and moves it into its layout), and BendKV refuses to start on a manifest. No RDB
preamble: `aof-use-rdb-preamble` is kept, and the file is commands whatever it says, as
Redis writes it with `no`. A key whose time has passed is left out, where Redis writes it
with its time and it expires as the file is read. BGREWRITEAOF never answers "Can't
execute an AOF background rewriting": BendKV forks nothing, and a temporary file it
cannot make shows as a rewrite that ended with an error, as a child's failure does in
Redis. The temporary file's pid is the server's, and the log has the lines of Redis 6
that apply to one file (no "Successfully created the temporary AOF base file").

## 3zw. maxmemory and eviction

**What there is.** maxmemory and its eviction as Redis 7.0.15 runs them (`evict.c`). With
maxmemory set, the actor reads the heap's account before each group of requests it runs,
as Redis's `processCommand` calls `performEvictions` before each command, and while the
heap is past maxmemory it evicts keys by `maxmemory-policy`: `allkeys-lru`,
`volatile-lru`, `allkeys-lfu`, `volatile-lfu`, `allkeys-random`, `volatile-random`,
`volatile-ttl` or `noeviction`. Past maxmemory with nothing it may evict (`noeviction`,
or no key the policy may take), Redis's `EVICT_FAIL`, the group's commands that may take
memory (the `denyoom` flag of Redis's command table) are refused with "OOM command not
allowed when used memory > 'maxmemory'.", after the client's authentication is checked
and before the rest, as Redis's `rejectCommand` refuses them: counted as rejected calls
and as OOM errors; in MULTI any command but EXEC, DISCARD, QUIT and RESET is refused and
flags the transaction, and EXEC aborts a transaction that queued a command that may take
memory ("EXECABORT Transaction discarded because of: OOM ..."); a group with such a
refusal runs the general way, a command at a time. A CONFIG SET of maxmemory starts an
eviction at once, with Redis's warning when the heap is past the new value ("WARNING: the
new maxmemory value set via CONFIG SET (...) is smaller than the current memory usage
(...)"), as Redis's `updateMaxmemory` (the start's warning of a maxmemory below 1 MB is
Redis's too). INFO counts as Redis counts: `evicted_keys`, `total_eviction_exceeded_time`
and `current_eviction_exceeded_time` (in ms, how long the heap was past maxmemory with
keys left to evict, Redis's `update_metrics`), and CONFIG RESETSTAT counts them again.

**What the memory is.** `IO.heap` (the twenty-ninth patch) gives the bytes the heap's
live values hold: what the heap has taken from its corpus less the free chains of the
rows in use, their parked generations and the bank's, a walk of 32 size classes and not
of the nodes, cheap enough for each group. That is INFO's `used_memory`, as Redis's is
what its allocator handed out (`zmalloc_used_memory`), and what maxmemory limits;
`allocator_active` is what the heap has taken, which it keeps. Redis subtracts what it
does not count for eviction (replication and AOF buffers); BendKV has no buffer in its
heap that it would leave out, and `mem_not_counted_for_evict` is 0. maxmemory takes
Redis's values up to 2^64-1, and INFO shows them as Redis does; past 10^14 bytes, which
no heap reaches, the eviction reads them as 10^14, so that they stay within a `Nat`.

**When each key was used.** Redis keeps 24 bits in each value: the second of its last use
(the LRU clock), or under an LFU policy the minute its counter last decayed and the
counter, a logarithmic one (`LFULogIncr`, with `lfu-log-factor`), which starts at 5 and
loses one for each `lfu-decay-time` minutes since it last decayed (`LFUDecrAndReturn`).
BendKV's values are values: a word in each would make every read a write, a new node
along the key's path and a change of the database every law speaks of. The words are kept
outside the heap instead (the thirtieth patch: `Mem.touch` writes a word, `Mem.cell`
reads one), 2^20 of them by the low twenty bits of the key's hash, in Redis's 24-bit
layout with a bit for each kind (LRU or LFU) above it, so that a word written is never 0.
A word of the other kind, after a change of policy, is read as Redis reads a value's 24
bits then (an LRU second as an LFU minute and counter, which decays at once to 0, and the
reverse); a word never written counts as a key's made at the start and never used since,
with a counter of 5, as Redis counts a value loaded at its start. Before a batch runs,
the actor marks the first key of each of its requests, by the hash the parser already
took (its hint), unless the command looks its key up without touching it (Redis's
`LOOKUP_NOTOUCH`: EXISTS, TYPE, TTL, PTTL, EXPIRETIME, PEXPIRETIME, and OBJECT, whose key
is not its first argument; a predicate the command table's generator writes,
`R.stat.touch`). OBJECT IDLETIME and FREQ answer from the word, each refused under the
kind of policy Redis refuses it under, and the eviction scores keys by it.

**The eviction.** A pick, then a delete, then the heap read again, until the heap is
within maxmemory. The LRU, LFU and volatile-ttl policies keep a pool of 16 keys, best
first, from one eviction to the next, as Redis's `EvictionPoolLRU`: each pick samples
`maxmemory-samples` keys of each database that holds keys the policy may take, scores
them (the seconds since the key's last use; 255 less its LFU counter; 2^47 less the time
it expires at), puts them in the pool as Redis's `evictionPoolPopulate` does, and takes
the best key that is still there (a key deleted meanwhile is dropped as it comes up,
Redis's ghosts). A sample reads the trie's buckets one after another from a random one,
as many as should hold three times `maxmemory-samples` keys (64 at least), as Redis's
`dictGetSomeKeys` reads a bounded number of buckets and may find fewer; a sample that
finds none in any database reads on until it finds keys. The random policies take a key
of the next database with keys after the one they took from last (Redis's static
`next_db`): `allkeys-random` one at random of 16 from a random bucket on, as RANDOMKEY
picks one, `volatile-random` the first key with a time from a random bucket on. The
volatile policies take keys with a time alone. Every 16 keys the actor looks at the time:
past the limit of `maxmemory-eviction-tenacity` (50 us for each step up to 10, 15% more
for each step past it, none at 100: Redis's `evictionTimeLimitUs`), it stops with keys
left to evict, Redis's `EVICT_RUNNING`, and goes on between groups, after a turn of the
event loop for the connections, as Redis's `evictionTimeProc` goes on from its event
loop. A key evicted is deleted as a DEL of its database (`R.exec`), as the sweep deletes
an expired key: a DEL in the append-only file, the key's WATCHes touched, `evicted` to
the keyspace's subscribers; a database emptied so gets a fresh trie (below).

**During a rewrite.** Redis's parent frees what it evicts while its child writes, and its
account comes down, though the child's copy of the pages still holds it. BendKV's rewrite
holds the databases as they were (3zv): a key evicted while it runs frees nothing until
it ends, and an eviction that waited for the heap to come down would evict every key. So,
while a rewrite runs, an evicted key counts as freed by MEMORY USAGE's estimate of it,
the debt, which the heap is credited with until the rewrite ends.

**What it cost.** GET, SET and INCR take 3,328, 4,252 and 4,514 instructions (3,301,
4,228 and 4,493 before, counted in turn): +27, +24 and +21, the marks (a load and a store
of a word, and the hash's walk of the batch's hints), and a quarter of a cache miss more
a request (the words are 4 MB, and a random key's is seldom in the cache). With maxmemory
set and not reached, the read of the heap's account adds 15, 15 and 13. The eviction
itself is slower than Redis's: 200,000 keys evicted in 3.6 s, against 0.3 s for Redis,
about 190,000 instructions a key, most of them in the walks of the samples, whose buckets
are mostly empty as the database empties. An earlier version took twice as many,
380,000 a key. Its samples read the buckets with the trie's scan, which recurses on the
stack (the runtime's work loop) and so takes the nodes it is passed: a node it reads is
shared with the database, and taking it copied it. They now read the buckets with a walk
of the hash's digits written as a loop (`tget_kb`), which reads the nodes lent; the
databases are read in place where they sit (`dbs.len`, not `List.length`, which takes the
list it counts), and the pool is handed from one pick to the next rather than copied.

**What the trie keeps.** A database's trie keeps its nodes when its keys are deleted:
200,000 keys deleted leave 8.6 MB, a million 9.0 MB (the trie's 2^20 buckets, which a few
hundred thousand keys fill). Eviction counts them, so it evicts more keys than Redis
would to get within the limit: halving the memory of 200,000 keys leaves 27,904 of them,
and a limit of a tenth leaves none, where the nodes alone are past the limit. Redis does
the like on a smaller scale: its hash table keeps its buckets until the cron shrinks it,
and the first eviction of 200,000 keys to a tenth evicted them all on Redis too. A
database the eviction empties gets a fresh trie, so that what the heap holds comes down.
Pruning the nodes a delete empties would end it (DIRECTIONS.md). (It came in section
3zz: a delete takes the nodes it empties, and 200,000 keys evicted to a tenth of their
memory leave 10,208, in 1.6 s.)

**Tests.** `tests/maxmemory_test.py` runs in make test. Transcripts on BendKV and
redis-server, compared line by line: the commands refused past maxmemory with noeviction,
and in MULTI (the transaction flagged, EXEC aborted, a transaction of reads let run,
DISCARD let run), with INFO's counts of the refused calls and of the OOM error; OBJECT
IDLETIME as keys are read, written, touched (TOUCH) and looked at without being touched
(TTL, TYPE, EXISTS), and OBJECT FREQ under an LFU policy (5 for a key made, 6 after a
read, the counter's steps with lfu-log-factor 0), each refused under the other kind of
policy; and the `evicted` event of a key evicted at once by a CONFIG SET of maxmemory
(unit/pubsub.tcl). Then Redis's own tests of the policies (unit/maxmemory.tcl, which its
suite runs only against a server it starts itself), on both: for each policy, keys added
past a limit of the memory used and 100 KB, then as many again, and the memory stays
within the limit and 4 KB; with keys without a time the volatile policies refuse writes
where the allkeys ones evict; and the volatile policies evict only keys with a time. And
BendKV alone: the warnings of its log; an eviction that runs out of time and goes on with
no request to drive it (200,000 keys, the memory back within the limit, `evicted_keys`
and the time past maxmemory counted); keys evicted with the append-only file on, gone
from the file too (a restart holds what was left); and an eviction while a rewrite runs,
which leaves between half and all of 300,000 keys rather than none. Redis's suite: 805 of
the 1,677 tests Redis passes (48.0%; 797 before): unit/pubsub's test of `evicted` events
and the two it held back, unit/multi's DISCARD past maxmemory and its EXEC aborted after
a command refused while it queued, unit/introspection-2's test that TTL, TYPE and EXISTS
leave a key's last use as it was, and unit/lazyfree's two tests of the memory UNLINK and
FLUSHDB ASYNC give back.

**Two ways to stop the server.** The tests found two, both the old trap of `Bool.pick`,
which works out both its values. maxmemory's parameters were read as numbers with one: a
maxmemory of 20 digits took its cap of 10^14, but was parsed all the same, past a `Nat`,
and the runtime stopped. And INFO's `maxmemory_human`, since INFO had a memory section,
worked out the value in each unit and took the one that applies: the kilobytes of 2^64-1
are past a `Nat` too. Both are matches now, which work out the branch taken alone, and
the test sets maxmemory up to 2^64-1 and reads INFO back against Redis's.

**Proofs.** An eviction is a DEL by the proved `R.exec` on its database, and its entry in
the append-only file is that DEL: the laws of DEL and of recovery cover it as they cover
a client's. Which key is evicted, and when, is the server's, as the sweep's choice of
expired keys is, and is tested, not proved. The access words are the runtime's alone: no
law reads them, and the proved session answers OBJECT IDLETIME and FREQ as for a key no
command used since the start, its reply then made again from the word by the server
(`bg.obj`); a proved function cannot read `Mem.cell`, since the checker refuses proofs
that rest on unsafe code. The law `config_pass` says what a CONFIG SET that succeeds
leaves: the server's eviction state reads its maxmemory parameters again, and keeps its
random numbers.

**Where BendKV differs.** The same maxmemory holds another number of keys, since a key
takes other bytes in BendKV's heap than in Redis's allocator, and the trie's nodes stay
(above). A word of use is shared by keys whose hashes have the same low twenty bits, in
any database, and no delete clears it: a new key may find an old key's word, unless
RESTORE made it (section 3zzx). A request
marks its first key alone (MGET's others, MSET's and DEL's are not marked), before its
batch runs, whether the key is there or not, and a command queued in a transaction marks
its key as it is queued. Redis marks a key as a command finds it, and not while a child
runs; BendKV marks it during a rewrite too. The random step of an LFU counter mixes the
key's hash and word with the time and the request's place in its batch, where Redis calls
`rand()`. The volatile policies sample the database's keys for those with a time, where
Redis samples its table of keys with a time; `volatile-random` takes the first key with a
time from a random bucket on, which is not quite uniform. An eviction writes DEL to the
append-only file even with `lazyfree-lazy-eviction` (Redis writes UNLINK; both replay to
the same). Evictions are about ten times slower than Redis's.

## 3zx. RESP3

**What there is.** RESP3 as Redis 7.0.15 speaks it. `HELLO 3` switches a connection to
RESP3, `HELLO 2` back, `HELLO` alone answers in the protocol there is, and `RESET` goes
back to RESP2; a HELLO that fails (`NOPROTO`, a wrong password, a bad name or option,
`NOAUTH`) leaves the protocol as it was, as Redis's `helloCommand` sets it last. go-redis
v9 and Lettuce 6 send `HELLO 3` as they connect and speak RESP3 when the server takes it;
redis-py and node-redis do on request. A RESP3 client gets what Redis gives it: `_` for
every null (a null bulk and a null array alike), doubles after a comma (ZSCORE, ZMSCORE,
ZINCRBY, ZADD INCR, and the scores of ZRANGE and its family, of ZUNION, ZINTER and ZDIFF,
of ZPOPMIN, ZPOPMAX, BZPOPMIN, BZPOPMAX, ZMPOP, BZMPOP and ZRANDMEMBER; not ZSCAN's, nor
INCRBYFLOAT's and HINCRBYFLOAT's, which Redis answers as bulks), maps (HGETALL, CONFIG
GET, HELLO, LCS IDX, CLIENT TRACKINGINFO, COMMAND DOCS), sets (SMEMBERS, SINTER, SUNION,
SDIFF, SPOP with a count; COMMAND INFO's flags, categories, tips and key specs, COMMAND
GETKEYSANDFLAGS's flags), pairs as arrays of two where RESP2 has them flat (members and
scores WITHSCORES, fields and values WITHVALUES, ZPOPMIN and ZPOPMAX with a count),
verbatim texts (INFO, CLIENT LIST, CLIENT INFO, whose lines say `resp=3`) and pushes:
the replies of SUBSCRIBE and its kin, and messages. A RESP3 client with a subscription
runs any command, and its PING answers as any PING; one of RESP2 runs what it ran.

**Typed replies.** Redis types a reply where it makes it (`addReplyMapLen`,
`addReplyDouble`, ...) and writes it in the client's protocol. So does BendKV: `R.Reply`
has eight constructors more, after the eight it had (so that the others keep their tags,
and GET's encoder its code): `RDbl` (a double as its text), `RMap`, `RSet`, `RPairs` (of
`RPair`s), `RVerb`, `RPush`, and `RSw` (below). `exec`, the session and the actor build
them where Redis calls its typed functions; the RESP2 encoder writes `RDbl` and `RVerb`
as bulks and the rest as arrays, the items of pairs flat, so that every RESP2 reply's
bytes are what they were (every RESP2 test passes as before), and a second encoder writes
RESP3. A pair and a switch hold lists, not replies: Bend checks that a recursion
decreases, and the encoder walks a list it finds in a reply as it walks an array's items,
where a reply put in a list of its own would not decrease. Nor may two definitions call
each other (a definition is checked before the ones after it), so neither encoder calls
the other: a batch's replies are cut at its switches, each part written by the encoder of
its protocol. COMMAND's table is written by `tools/gen_commands.py` from what Redis
answers in RESP3, its maps and sets kept; the generator checks that, read as RESP2 reads
them, they are what Redis answers in RESP2.

**The connection's protocol.** `S.Conn` has a seventh field, `r3`. The laws about
sessions hold for both protocols (it changes how replies are written, not which replies a
batch gives): their proofs take the field as they take the selected database, 398
patterns and twelve lemmas of `PROOF.bend` written again by a script, and they check as
they did. The fast way runs as it runs, its replies written by the encoder of the
client's protocol. A command that changes the protocol (HELLO, RESET) has its replies
wrapped in a switch (`RSw`) by the actor, so that they and the replies after them in the
batch are written in the new protocol, as Redis writes HELLO's reply in the protocol it
switched to; the switch is put only where the protocol changes, so a batch's first
protocol is the other one of its first switch's, or the connection's when it has none.
A switch inside EXEC's array holds for its reply alone (below).

**Pushes.** A message is encoded once, as RESP2's array; a subscriber in RESP3 gets it
with `>` for its first byte, and each subscriber's protocol is kept with its subscription
(a client with a subscription that switches with HELLO, which only a RESP3 client may
run, has its subscriptions made again in the new one). A RESP3 client that publishes to
its own channel, or hears its own keyspace events, gets them among its replies before
its command's reply, as Redis writes them to its buffer while the command runs: the
actor keeps those pushes apart from the others (`own`) and puts them there; the pushes
to other clients go out before the batch's answer, as they did.

**Its cost.** A RESP2 client's replies are the bytes they were, written by the encoder
they had: GET, SET and INCR take 3,337, 4,259 and 4,546 instructions (3,328, 4,252 and
4,514 before, counted in turn). A RESP3 client's take the same: with one client that
pipelines 20,000 requests, GET 3,550 against RESP2's 3,548, SET 4,483 against 4,471, INCR
4,777 against 4,755. A batch with HELLO runs the general way, as any batch with a command
of the connection does, about 150,000 instructions for redis-benchmark's HELLO 3 and the
16 requests it sends with it; a client pays that once, when it switches (section 49 of
PERFORMANCE.md).

**Tests.** `tests/resp3_test.py`: HELLO and its errors, the protocol switched in the
middle of a pipeline (with CLIENT REPLY OFF too), nulls and doubles, maps, sets and pairs,
the server's replies (CONFIG GET, CLIENT TRACKINGINFO and INFO, COMMAND INFO and DOCS),
EXEC's replies and an EXEC that WATCH aborts, blocking commands that time out and that
are served, Pub/Sub's pushes with a RESP3 and a RESP2 subscriber, a subscriber that
switches its protocol, keyspace events of a client's own commands, and pipelines of the
fast way, each scenario byte for byte against Redis (but for a client's id, and CLIENT
INFO's line, compared by its kind and `resp=`). `RESP=3` makes every connection of the
differential tests speak RESP3, and `make test` runs them again so: TTL, numbers,
BITFIELD, hashes, lists, sets, sorted sets and the random stream, their normalizers
taking maps and sets as they take arrays, the kind compared.

**Redis's suite.** 1,097 of the 1,677 tests Redis passes (65.4%; 805 before), 1,090 of
the 1,172 in what BendKV has (93%). unit/type/list runs past its HELLO 3 now and passes
210 of its 218 tests (15 before), unit/type/zset 287 of its 289 (192 before),
unit/type/hash its test of HRANDFIELD over RESP3 (69 of its 72) and unit/pubsub its test
of messages with CLIENT REPLY OFF, which runs over RESP3 (29 of its 30). Of
unit/type/list's other eight, two read the replication stream (SYNC), two make their
list with SORT's STORE, two read lists back with DUMP, and two fail on the client that
the test of SORT's STORE leaves waiting on its key for five seconds, stopped at SORT
before it closes it: BLMPOP's test of a list moved into place by RENAME gets the list's
second element (that client got the first), and BLPOP's test of a timeout of 0.001 s
waits a second for no client to be blocked. unit/type/zset's other two read the
replication stream.

**Where BendKV differs.** HELLO queued in MULTI switches the protocol for the batches
after EXEC; Redis switches at once, so that the replies after it in EXEC's array, and
those after EXEC in the batch, are written in the new protocol. CLIENT TRACKING, and its
invalidation pushes, BendKV does not have.

## 3zy. Client libraries' test suites

**What runs.** Redis's suite measures the server; a client library's suite measures what
an application sees through it. `tools/client_suite.py` runs two, each at a fixed version
from its language's registry, against BendKV and against Redis 7.0.15 the same way, each
run on a server started for it: redis-py 8.1.0's tests of the sync and asyncio clients, in
RESP2 and in RESP3, and go-redis v9.23.0's Ginkgo specs, which speak RESP3. go-redis's
suite starts a ring, sentinels and a cluster of its own unless it is told it runs against
one Redis Enterprise database (`RE_CLUSTER`, with an endpoints file naming the server):
so it runs, without its specs of those and of modules; and it is told the server is
7.0, so that its specs of later versions skip themselves. Neither suite's tests of
modules, clusters, sentinels or TLS run. CI runs the three suites on every pull request,
in three jobs beside `make test`: a test Redis passes that BendKV fails, and that is not
among the known failures of `tools/data/clients.json`, fails the job.

**What they found.** Of the 2,753 tests of redis-py that Redis passes, BendKV passes 2,382
(86.5%), the same tests in RESP2 and in RESP3; of go-redis's 460, 389 (84.6%). Every test
BendKV fails of those Redis passes fails on a command or a feature it does not have: Lua,
streams, geo, HyperLogLog, SORT, DUMP and RESTORE, ACL, the slow log and the latency
monitor, CLIENT PAUSE and TRACKING (go-redis's client-side cache), WAIT, LASTSAVE, ROLE,
MODULE, MEMORY STATS; and COMMAND, which lists BendKV's commands alone (COMMAND LIST
counts 216 where redis-py waits for more than 300, and COMMAND GETKEYS knows no SORT). No
test finds a command BendKV has answering otherwise than Redis does, in either protocol.
The runs also showed that BendKV has no SHUTDOWN, which test harnesses send to stop a
server: `tools/client_suite.py` stops the servers it starts with SIGTERM.

## 3zz. Deletes that take the nodes they empty

**What there is.** A delete walks the trie with `tdel_h`, which takes the nodes it leaves
empty: when the bucket a key leaves is empty, the node above it goes too if its other 15
subtries are empty, and so up to the root, so a trie keeps no more nodes than its keys
take, and a trie whose last key goes is the empty trie again. A delete of a key that is
not there changes nothing, where the walk of the other writes (`tmod_h`), which a delete
took before, builds the nodes down to the key's bucket: a DEL of a missing key no longer
adds nodes. The walk looks at the subtrie it changed (`tis_tip`), and only when the delete
emptied it does it look at the node's 16 subtries (`tnode_if`, `tnode`). Every trie of the
server deletes so: the keyspace's, a hash's fields, a set's members, a sorted set's, and
the server's own tables, of clients by id and of channels and patterns by name, which a
server whose clients come and go filled with a path of nodes for each id it gave. The
eviction no longer gives a database it empties a fresh trie: its trie is empty.

**What it gives.** 200,000 keys deleted give back what they took: 400 bytes stay of the
22.9 MB they held, where 8.6 MB stayed, and half of them deleted leave 14.4 MB (15.8 MB
before). An eviction gets within its limit with the keys Redis keeps: 200,000 keys
evicted to a tenth of their memory under allkeys-lru leave 10,208, where every key went
before, the nodes alone being past the limit (Redis leaves 9,888), and the eviction takes
1.6 s (2.9 s before, Redis 0.16 s); to half their memory, 65,648 (27,776 before, Redis
86,352: the trie's nodes are a larger share of a smaller database). A pick or a scan of
a trie that deletes drained goes by the keys left: a set of 100,000 members popped to its
end gives its last 10,000 SPOPs at 28,700 a second, as many as its first (1,330 a second
before; Redis 420,000), RANDOMKEY with 1,000 keys left of 100,000 answers 56,800 a second
(5,000 before; Redis 319,000), and a whole SCAN of them takes 2.3 ms (21 ms before).

**What it costs.** A DEL that empties its bucket takes about 75 instructions more (5,118
against 5,041, 100,000 keys and 20,000 of them deleted): the look at the node's 16
subtries and the node given back. One that does not, or of a key that is not there,
about 8: the look at each changed subtrie. GET, SET and INCR do not change: 3,334, 4,255
and 4,548 instructions against 3,335, 4,260 and 4,540, counted in turn.

**The proofs.** The laws of DEL rest on two of the walks: a read of the bucket the walk
changes sees the change, and every other bucket reads as it did (`tget_tmod_same`,
`tget_tmod_other`), proved of `tmod_h`. A trie `tdel_h` leaves holds fewer nodes than the
one `tmod_h` leaves with `ODel`, but every bucket reads the same in both (`tdel_eq`), so
the laws of DEL come from `tmod_h`'s lemmas as they did, each through one rewrite.
`tdel_eq` goes by induction on the depth: a node reads as the trie `tnode` makes of it
(`tnode_read`: a node of 16 empty subtries reads empty, as the empty trie does); two
nodes whose children read alike read alike (`node_same`); and where `tmod_h` builds the
nodes down to the bucket of an empty trie, every bucket they hold is empty (`del_tip`,
from the two lemmas of `tmod_h`). `tools/gen_trie.py` writes the 16-way steps: 227 lines
of `PROOF.bend`, and 26 more by hand.

## 3zza. Walks that borrow the trees their callers own

**What was left.** The compiler decides once for each function whether a parameter is
borrowed or owned, and one caller that gives a function a value it owns, at its last
use in a tail call, makes the parameter owned for every caller (section 3zm). The walks
of the keyspace's trie and of a sorted set's tree had such callers: `keys` gives its
trie to `tkeys` (KEYS), `scan`, `reap` and `pick` give theirs to `tscan` (SCAN, the
sweep of expired keys, RANDOMKEY), `zt.slice` and `zt.rslice` give their trees to
`zt.slice.go` and `zt.rslice.go` (ZRANGE and its family). A walk that owns its tree
takes each node it reads, and a node another value shares (the keyspace shares every
node of a stored trie or tree, and a version of a tree shares the subtrees it kept from
the one before) is copied before it is read and the copy dropped after: KEYS copied
every node of the trie, ZRANGE every node on the way to its range.

**The change** (Bend patch 31, `walk-lend.patch`). A walker that reads is a function that
calls itself, takes a tree (a datatype with a node of two or more subtrees of its own
type) and builds none of that datatype's nodes. A tail call that gives one a value its
caller owns, at its last use, becomes a call that holds the value and drops it after,
as `r = f(t); r` does: the walker borrows the tree, and the caller drops it once, a
count less where the keyspace shares it. A call that holds such a value lends it too,
where it gave it. A tail call into the caller's own loop stays a jump. A function that
rebuilds what it is given (it builds the tree's nodes), or takes a list or a record,
owns it as before: the in-place update of a node it owns needs the node. In BendKV
eight functions borrow their trees now (`tkeys`, `tscan`, `zt.slice.go`,
`zt.rslice.go`, `zt.trie`, `zt.drain` and the cuts of a node, `zt.cutl` and `zt.cutr`),
and 34 of its 1,134 compile otherwise, their callers holding what they gave.

**What it gave.** Instructions per command under callgrind, from one client
(`tools/walks.sh`): KEYS of 9,800 keys 2,779 a key against 1,961 (−29%), SCAN 0 COUNT
1000 4.87 million against 4.31 (−12%), RANDOMKEY 134,000 against 96,600 (−28%); ZRANGE of
10 elements of a sorted set of 100,000, with their scores, 73,200 against 59,700 (−18%),
ZREVRANGE of 10 58,800 against 45,700 (−22%), ZRANGE of all 100,000 139.5 million
against 111.1 (−20%); ZUNIONSTORE of two of 10 316,400 against 290,700 (−8%), of two of
1,000 41.2 million against 39.5 (−4%), ZREMRANGEBYRANK of one element of 1,000 56,800
against 50,900 (−10%); ZRANK, ZSCORE, ZINCRBY and ZADD within 2%. GET, SET and INCR
take what they took (3,332, 4,259 and 4,542). A held call costs a frame where the tail
call jumped, once per walk. `comp.ts` takes 103,088 `ttok` tokens (102,266 before).

**The sweep.** The sweep of expired keys reads the trie with `tscan` ten times a second
(`reap`), and took the nodes it read: with 4,000 keys with a time to live, the heap held
69,152 bytes more a second after they were set, and as many from then on, copies of the
nodes the keyspace shares. With the patch it holds 96 more. With the patch alone, a test
of the eviction failed: a volatile-lru eviction of the keys with a time could not get
within its limit, since the trie kept the nodes of the keys it evicted, where the
sweep's copies, which went with those keys, had made up for them. With the deletes of
section 3zz, which take their nodes, it passes.

## 3zzb. Errors found among the replies, not in their bytes

**What was wrong.** INFO's errorstats, `total_error_replies` and each command's
`failed_calls` count a batch's error replies. The actor looked for those of a batch of
one command, most batches, in its encoded bytes, a line at a time, taking a line that
begins with `-` for an error reply. That held while the commands that may fail as they
run were INCR, DECR, INCRBY and DECRBY, whose replies are a line each (section 3s). The
collections brought dozens of commands that may fail (WRONGTYPE) and answer many lines:
LRANGE, HGETALL, SMEMBERS, ZRANGE and the like. A line of a bulk that begins with `-`
(the string "-5", a negative score, a member "-x") counted as an error: a ZRANGE
WITHSCORES of 2,000 negative scores added 2,000 to `errorstat_ERR`, to
`total_error_replies` and to ZRANGE's `failed_calls`, where Redis counts none. And the
scan read each line with `String.find` and `String.code_at` at its index, which walk an
answer of many chunks from its start: ZRANGE 0 -1 WITHSCORES of a sorted set of 20,000
members took 15 s (7 s with integer scores), and held every other client meanwhile.

**The change.** The errors of a batch of one command are found among its replies before
they are encoded, as those of a batch of several commands were: a look at each reply's
tag, the error replies taking the batch's code (`R.errs.one`). The scan of the bytes
goes.

**What it gives.** ZRANGE 0 -1 WITHSCORES of 20,000 members takes 0.145 s (14.7 s
before), 0.029 s with integer scores (7.2 s); of 1,000 with half the scores negative,
13.9 million instructions (247.8 million). DECR pipelined 16 deep on counters below zero,
whose answers all have a `-`, takes 6,679 instructions a request (6,751). GET, SET and
INCR take 3,334, 4,257 and 4,548 (3,335, 4,257 and 4,539): INCR pays the look at its
replies, about 9 instructions, where its bytes had no `-`. A first version looked at the
bytes for a `-` and then among the replies: it held the replies across their encoding,
which every batch paid for, not only those it looked at (GET +17%, INCR +14%). The look
before the encoding hands the replies on to the encoder after, as the batches of several
commands did.

**Tests.** `tests/stats_test.py` has a case of replies with lines that begin with `-` and
are no errors: a bulk "-5", negative scores and increments, members "-x", one at a time
and in pipelines of one command, two with a WRONGTYPE among them, and a ZRANGE of 2,000
negative scores. On the build before, BendKV counted 2,087 error replies where Redis
counted 2.

## 3zzc. Reads of the keyspace that borrow it

**What was left.** A parameter is owned for every caller when one caller gives it a
value it does not keep (section 3zm). Three callers did so to the reads of a key's
entry: `KV.entry` gave `bent` the bucket `tget_h` answers, so that `bent`, the walk
`tget_ke` that gives it its bucket, and `entry.at` owned what they read; and OBJECT,
HRANDFIELD, MEMORY USAGE, SRANDMEMBER and ZRANDMEMBER, and the server's reads for WATCH
and the clients that wait, gave `R.db.ent` and `R.db.entry` the database `R.ds.focused`
answers. Every command that reads a key's entry before it runs (LLEN, HGET, SISMEMBER,
ZSCORE, and the writes of a collection) then copied the database's record, which the
actor keeps, and the five nodes on the key's path, and dropped the copies after.

**The change.** `KV.entry` holds the bucket in a variable and calls `bent` before its
tail, which lends the bucket; the session and the server read the focus with `R.ds.ent`
and `R.ds.entry`, which lend its record, and a database out of focus with `R.dbs.entry`.
41 parameters that were owned are borrowed now, among them those of the eviction's and
the sweep's reads of the keyspace. They were found by logging, in a copy of the
compiler, which call made which parameter owned. No proof changed.

**What it gives** (`tools/colls.sh`: instructions per command under callgrind, one
request at a time, collections of 100,000 members): LLEN 15,874 (19,794 before, −20%),
LPUSH 18,264 (23,523, −22%), HGET 16,990 (20,906, −19%), HSET 28,412 (33,659, −16%),
SADD 26,341 (31,615, −17%), ZSCORE 17,751 (21,698, −18%), ZADD 25,324 (29,144, −13%);
GET and SET as before (14,307 and 15,184), and GET, SET and INCR pipelined too (3,334,
4,259 and 4,550). The eviction of 200,000 keys to a tenth of their memory takes 1.03 s
(allkeys-lru, 1.62 s before) and 1.4 s (allkeys-random, 5.1 s). A read of a collection
costs a GET and the read of the collection now. A write still copies the path of the
collection it changes and drops the old one's, since the keyspace holds the old version
while the command makes the new one: the update in place of section 3zm is what is left.

## 3zzd. HSET in place: the hash taken out of the keyspace

**What was left** (section 3zzc). A write of a collection made the new version while the
keyspace held the old one, so it copied the path it changed and the keyspace dropped the
old path after: of HSET's 28,412 instructions on a hash of 100,000 fields, 5,290 went to
the drop and 2,652 to the copies.

**The change.** An HSET of pairs to a key that holds a hash at now (`R.upd.takes`) takes
the hash out of the keyspace first: it writes a hole in the key's place, the write
changes the hash, held once, in place, and the change writes the new hash over the hole.
The update reads its entry's code before it gives the entry to `ent.live`, and
`KV.hash.put` and `hset.go` read whether a field is there before they write it: in a
node built of both the compiler ran the write first and held the trie for the read after
it, which made the write copy the path anyway. Only HSET takes its value: a write that
may leave its collection as it was answers CKeep and drops the collection it was given,
which a collection out of the keyspace cannot afford.

**The proofs.** An update reads as the change made where its key's entry lies, taken out
or not (`db_upd_unfold`, `run_upd_unfold`), since a change that writes its key's value
over writes the same trie over the hole as over the value (`upd_put_take`: a write after
a keep of the same key is as the write alone, through `tmod_twice`, which
`tools/gen_trie.py` writes, and two lemmas of a bucket), and an HSET of pairs to a hash
writes its value over (`takes_over`). The proofs that unfolded the update rewrite
through `db_upd_unfold` (thirteen places).

**What it gives** (`tools/colls.sh`): HSET of a field there 21,178 instructions (28,412,
−25%), of a new field 21,311 (27,818, −23%); the other commands as before. A prototype
that took every write's value, with no care for the writes that leave their collection
as it was, put SADD at −25%, ZADD at −28% and ZINCRBY at −34%: each needs a test before
the take that the write changes the collection, and its proof.

## 3zze. SADD in place: the set taken out of the keyspace

**What was left** (section 3zzd). SADD of a member new to a set still copied the path it
changed and the keyspace dropped the old path after: 26,284 instructions on a set of
100,000 members.

**The change.** An SADD to a set kept as a hashtable that lacks the SADD's first member
takes the set out of the keyspace, as HSET takes its hash: it adds that member, so it
writes the set over for sure. An intset is not taken: the test of its member walks its
list, which cost more than the take saved (511,928 instructions against 449,438).

**The proofs.** Such an SADD adds one or more members, so it answers CMems and writes
the set over (`takes_mems`, under `takes_over`): the members added to a set leave it no
smaller, the member it lacks makes it one larger, and a size one or more larger, less
the old size, is not 0 (`sadd_adds`, `sub_pos`). Two proofs that unfolded the update
rewrite through `db_upd_eq`.

**What it gives** (`tools/colls.sh`): SADD of a new member 20,273 instructions on a set
of 100,000 (26,284, −23%), 19,959 on a set of 10 to 410 strings (22,555, −12%); the
other commands as before. SADD to an intset of 100 to 500 members takes 449,545, twenty
times SADD to a hashtable: its members are strings, compared as integers at each step of
a walk along their list, which Redis keeps as an array of integers searched by halves.
Section 3zzy keeps them in a tree, and takes an intset too.

## 3zzf. The key count proved

**What was left** (section 3u). A database keeps beside its trie how many keys it holds
and how many of them have a time, so that DBSIZE and INFO's keyspace line answer without
walking the trie; each write changes the two counts as it changes the trie (`R.cnt.n`,
`R.cnt.x`). That they are the trie's own was not proved. It needs the trie well formed,
each key at most once in its bucket: a delete takes every entry of its key, so a key
there twice would make the counts drift. And it needs sums over the 16 subtries of a
node.

**The laws** (`proof/LAWS.bend`, "The key count"). After any history, the counts of
every database are its trie's own, and its trie is well formed: nodes down to the
buckets, and each key at most once in its bucket (`counts_hold`). So DBSIZE answers the
number of entries in the trie of the database in focus (`dbsize_size`, `KV.size`); keys
whose time has passed are among them until a command or the sweep deletes them, as in
Redis.

**The proofs.** Both counts are one sum over the trie's entries, with a weight for each
entry (`tsum`: 1 for every entry, or 1 for an entry with a time), so each lemma serves
both. They go up in four steps:

- in a bucket, a write of a key weighs the new entry more and the entry it replaces
  less (`bset_sum`, `bkeep_sum`, `bexp_sum`, `bdel_sum`), and keeps each key once;
- in the trie, a write of a key weighs the trie as it weighs the key's bucket, in terms
  of the key's code before it, and keeps the trie well formed (`tsum_mod`, `tsum_del`,
  `twf_mod`, `twf_del`; a delete also takes the nodes it empties, `tsum_tnode`). These
  are the 16-way parts that `tools/gen_trie.py` writes: a sum over a node's subtries
  with one of them changed (`slot0` to `slot15`), and the cases of a walk;
- in a database, each write changes the counts as `R.cnt.n` and `R.cnt.x` say, so every
  command keeps a database counted (`counted_exec`): the change an update makes finds
  its key there whenever it deletes the key, sets its time or changes its collection
  (`Good`), DEL deletes its keys one after another, and RENAME, LMOVE and INCRBY know
  from what they read that their keys are there;
- among the databases, every act keeps every database counted (`counted_act`: a
  command on the focus, SELECT, SWAPDB, MOVE, COPY, FLUSHALL), and a history starts
  from empty databases (`counted_single`).

No code changed: the counts were right. The proofs add 198 lemmas, about 940 lines by
hand and 760 written by the script, not counting comments and blank lines. `make check`
takes 13.6 s (11.3 s before), `make verdict` 63 s (57 s).

## 3zzg. Strings in the keyspace without a node of their own

**What was left** (section 3zf). A value is a string or a collection (`KV.Val`), and in
the keyspace a string lay behind a node of its own, `VStr`: the trie is generic in its
values, so its entries hold them boxed, and the box of a constructor was a node. Every
string value cost a node: an allocation on SET, a read on GET, a miss of its own in a
large keyspace, and a word of memory.

**The change** is in the compiler (patch 32): a datatype with one constructor whose one
field is a `String` boxes that constructor as the String itself, and tells the box from
the other constructors' by its tag (a node or a packed word of one of them is theirs;
no String is). No line of BendKV changed, nor of its proofs, which never saw the node.

**What it gives** (section 56 of PERFORMANCE.md): at a million keys, 24% fewer
last-level misses per GET (5.49 → 4.18), 19% per SET and 32% per INCR; 4.3% and 3.7%
fewer instructions per SET and INCR; one word less per key (about 981,000 keys of 3
bytes: 63.96 → 56.09 MB); in time, SET ×1.08 and INCR ×1.03, GET as before. Bend's own
tests pass with the patch as without it, test by test.

## 3zzh. SORT and SORT_RO

**What there is.** SORT and SORT_RO as Redis 7.0.15's `sort.c` runs them. The options are
read in order, each word compared as Redis compares it (`strcasecmp`, so up to a NUL),
LIMIT's two numbers as longs; STORE is a syntax error in SORT_RO, as is a word Redis does
not know or one without its arguments, and every such error comes before the key's type is
looked at. A list, a set or a sorted set is sorted; a key not there is an empty list, any
other type WRONGTYPE. BY with a pattern weighs each element by what the pattern names: its
first `*` (before a NUL) replaced by the element names a key that holds a string, or, with
`->` after the star and a byte after that, a hash's field; `#` names the element itself. A
BY whose pattern has no `*` sorts nothing: a list and a sorted set keep their order
(reversed by DESC), a set its own, but a set whose result is stored is sorted ALPHA, as
Redis sorts it then, so that what it writes does not hang on its hashtable's order. GET
answers what its patterns name for each element, a null where nothing is (an empty string
in a STORE), and LIMIT cuts the result where Redis clamps its start and count.

**Comparisons.** The weights are doubles, read as Redis reads them with strtod: blanks
first, then the number, and nothing after it but a NUL. A weight that does not read so, or
reads with a range error (an overflow, or a result below the smallest normal double that
is not exact, for which glibc sets ERANGE too), or as a NaN, fails the SORT with Redis's
error ("One or more scores can't be converted into double"); a weight not there counts as
0, and ties are broken by the elements' bytes. `src/float.bend`'s strtod now tells whether
its result is tiny and inexact, and `tests/float_test.py` checks the new reader against a
C one that reads as Redis does (`tests/float_ref.c`), on the numbers the test draws and on
subnormals at their edges. ALPHA compares bytes up to the first NUL, as strcoll does in
the C locale, or all of them in a STORE (where Redis compares with memcmp, so that what it
writes does not hang on the locale), a weight not there first.

**The sort.** Redis calls glibc's qsort, which sorts with a merge sort when it can take
the memory for a copy of the array (up to a quarter of the machine's), so Redis's sort is
stable: elements that compare equal keep the order they came in. BendKV's is a bottom-up merge sort: runs of
two, merged in passes. Bend checks that every recursion ends on a smaller argument, and a
merge makes one of its two lists smaller, not always the same one, so the merge and the
passes take a count of steps as their first argument (the number of elements, which
bounds both). Redis sorts with its own pqsort, which is not stable, when it sorts BY a
pattern under a LIMIT that does not take all (it sorts only the part it answers); BendKV
sorts all of it, stably.

**STORE.** SORT with STORE writes its result over its destination as a new list (whatever
the key held, with no time to live), or deletes the destination when the result is empty,
and answers the count, with the `sortstore` event (`del` for a delete), as Redis's
`setKey` and `dbDelete`; a WATCH of the destination sees a change even when the list is
the one there. In BendKV it is an act of the database in focus (`ASort`): it reads the
keyspace, makes the list, and runs the write it makes (`R.sort.write`), whose effect is
logged: the RPUSH of its elements onto a key not there, the EVAL of the lists' script onto
a key there, the DEL of the destination. Redis logs the SORT as the client sent it, and
BendKV's load runs it, so a file of Redis's restores as Redis held it. COMMAND GETKEYS
finds the destination as Redis's `sortGetKeys` does: the last STORE with a word after it,
LIMIT's two words and GET's and BY's one skipped.

**The laws.** SORT without STORE is a read (`is_read`). Its reply hangs on the keys its
patterns name, any key of the database, so it is not `keywise`, and any write disturbs it,
as any write disturbs KEYS: the laws let it swap with reads alone. Its proofs take it as
they take KEYS, through the spec, the bridge to `R.exec`, the frame, the replay and the
count of keys (25 proofs), and those of acts take `ASort` as the act of the command it
computes (`act_split`, `act_inv`, `act_now`, `one_eff`, `counted_act`). The order of the
sort itself is not proved: the laws speak of which keys SORT reads and writes, and the
tests of what it answers. `make check` and `make verdict` pass.

**Its cost** (section 57 of PERFORMANCE.md). A SORT of 1,000 integers takes 6.1 million
instructions, three times Redis's 2.0 million; of 1,000 words with ALPHA, twice Redis's;
BY a key that holds a double, five times, as strtod in software reads a double that is
not an integer in about 10,000 instructions; with STORE, nearly six times, as it sorts
twice, once for the session's reply and once for the act's write. The first version took
three times as many: its merges counted their runs, ALPHA cut its values at each
comparison, the patterns were read for each element, and integers digit by digit. A key
that BY or GET names is read as MGET reads one, about 8,000 instructions, where a whole
GET takes 3,312: the walk behind `KV.read` takes each node on the key's path from the
keyspace, which shares it, and so copies it. GET, SET and INCR take what they took, and
ZADD with an integer score 6.7% less (the powers of two of the float library).

**Tests.** `tests/sort_test.py`: a script of the cases of Redis's unit/sort and of
`sort.c` (BY with and without a `*`, hash fields, GET with `#` and with patterns that name
nothing, LIMIT at its edges, STORE that makes, replaces and deletes its destination, the
errors and their order, NULs in patterns, weights and elements, COMMAND GETKEYS), lists,
sets and sorted sets of 0 to 10,000 elements sorted every way, and 2,000 rounds of random
SORTs of random keys with BY and GET patterns over strings and hashes, each STORE's
destination read back: 4,183 commands, each answered as Redis answers it, and again over
RESP3. Where Redis's order is not its own to keep (a set kept as a hashtable, pqsort's
ties), the test compares the replies as multisets, or their sizes. SORT with STORE runs in
the scenarios of keyspace events, of WATCH and of transactions, of the append-only file
both ways (a file of Redis's with the SORTs in it, one of BendKV's with their lists), and
in the random batches of the restart test.

**Redis's suite.** 1,153 of the 1,677 tests Redis passes (68.8%; 1,097 before), 1,146
of the 1,224 in what BendKV has (94%). unit/sort passes 51 of its 52 tests (the other
calls SORT from a Lua script); unit/type/list 214 of its 218: the two tests that make
their list with SORT's STORE pass, and so do the two that failed on the client the test of
SORT's STORE, stopped at SORT, left waiting on its key; unit/multi the test of a watched
key that a SORT with STORE deletes, its result empty (28 of its 53); and unit/violations
its one test in this mode, a SORT that GETs an integer into the list it stores.

**Where BendKV differs.** A set kept as a hashtable comes in BendKV's order where Redis's
is its hashtable's: BY a constant without STORE, and elements whose weights tie under
ALPHA by a pattern. A sort BY a pattern under a LIMIT that does not take all leaves
elements whose weights tie in a stable sort's order, where Redis's pqsort may not. Redis
compares ALPHA in the locale it was started in (BendKV as in the C locale; `make test`
starts Redis with `LC_ALL=C`). Redis reads a range error from errno without clearing it
first, so after a weight that overflows or is tiny every SORT that reads a weight with
strtod fails (an element or weight kept as an integer is read without it) until a command
that clears errno runs, such as INCRBYFLOAT; BendKV judges each SORT alone. And Redis makes
a sorted set it sorts a skiplist for good, so OBJECT ENCODING answers `skiplist` for a
small one after a SORT, where BendKV's stays a listpack.

## 3zzi. Reads of keys that lend the keyspace

**What was left** (section 3zzh). A key that SORT's BY or GET names cost about 8,000
instructions, and a key of MGET as much (8,496,827 for 1,000 keys), where a whole GET takes
3,312. The walk down the trie behind `KV.read` took each of the five nodes on the key's
path (`ctr_own`): the keyspace shares them, so it copied each, its sixteen counts raised
and fifteen of them dropped, and dropped the copies after.

**Why.** As in section 3zzc: the compiler makes a parameter owned for every caller when
one caller gives it a value it does not keep. ZRANGESTORE gave `KV.read` the trie that
`db.trie` answers (`KV.read(KV.Val, db.trie(x), s, db.now(x))`, in `redis.bend` and in
`aof.bend`), a value made for the call, so `KV.read` owned its trie, and so did `live.at`
and the walk under it, `tget_kl`, for MGET, EXISTS, MSETNX, BITOP, the operations of
several sets and sorted sets, SCAN's TYPE and SORT alike.

**The change.** `R.db.read` reads a key's value in a database it lends (a match on the
database, which lends its trie), and ZRANGESTORE reads its source with it. The walk now
reads each node where it lies (`term_peek`, no copy). Three proofs that spelled the read
as `KV.read` of `R.db.trie` spell it as `R.db.read`; `make check`, `make verdict` and
`make gencheck` pass.

**What it gives** (section 58 of PERFORMANCE.md): MGET of 1,000 keys 3,240,949
instructions (8,496,827, −62%), less a key than a whole GET; SORT BY nosort GET of 1,000
keys 2,603,797 (8,018,304, −68%), 1.19 times Redis's; SORT BY a key that holds a double
14,718,297 (20,053,648, −27%). GET, SET and INCR take what they took.

## 3zzj. HyperLogLog

**What there is.** PFADD, PFCOUNT, PFMERGE, PFDEBUG (GETREG, DECODE, ENCODING, TODENSE)
and PFSELFTEST as Redis 7.0.15's `hyperloglog.c` runs them, in `src/hll.bend`. A
HyperLogLog is a string, its bytes Redis's: a header of 16 bytes ("HYLL", the encoding,
three unused bytes, and the cardinality last counted, its top bit set when a change made
it stale), then 16384 registers of 6 bits, dense in 12,288 bytes or sparse as runs of
opcodes (ZERO, XZERO and VAL). An element counts in the register that MurmurHash64A, with
Redis's seed, gives it, the 64-bit products taken as halves of 32 bits. Every value the
commands write is the one Redis writes, byte for byte: `hllSparseSet`'s split of an opcode
and its merge of the VALs around it, the turn to dense past 3,000 bytes or for a register
past 32, PFMERGE's sparse result when every HyperLogLog it reads is sparse (its registers
set in turn, in order, as Redis sets them), and the count kept in the header. A string
that is not a HyperLogLog answers Redis's WRONGTYPE of its own ("Key is not a valid
HyperLogLog string value."), a sparse one whose opcodes do not hold 16384 registers
INVALIDOBJ.

**Corrupt values.** Redis 7.0.15 as Ubuntu ships it, which the tests compare with,
carries the fix of CVE-2025-32023: a walk of the opcodes that would pass the last
register stops, and the value is invalid, so a sparse value is valid when its runs add
up to 16384 (before the fix, a run of zeros ran on, and a VAL past the end stopped the
walk where it stood, valid if that was at 16384). BendKV judges as the fix does. Opcodes
that end within an XZERO read the byte past the string's end as its second byte, as
Redis reads its sds string: the NUL there when a command starts, and, after a set that
split such an XZERO, the last byte of the opcodes the set made (Redis's `memcpy` writes it
past the new end, over the NUL that `sdsIncrLen` wrote a moment before), which the sets
after it in the same PFADD or PFMERGE read.

**The count.** Ertl's estimator as `hllCount` takes it: the histogram of the registers,
the loops of tau and sigma, their sum and the final division in the float library's
doubles (`src/float.bend` gained division and square roots, each rounded once from its
exact result), and `llroundl`'s rounding, with 2^63 past what a long long holds. glibc's
`pow(1 - x, 2)` in tau is the product rounded once, which it is but for a result within a
sliver of a tie between two doubles. PFCOUNT of one key keeps the count it made in the
header (the SETRANGE of its 8 bytes, as Redis writes them in place); PFCOUNT of several
keys counts the maxima of their registers and keeps nothing.

**Writes, events and the log.** PFADD, PFCOUNT of one key and PFDEBUG are updates of
their key (`UHll`): PFADD's change is the value it makes (a new key, or the value kept
with its time), PFCOUNT's the SETRANGE of the count, PFDEBUG GETREG's and TODENSE's the
dense value they leave; each is logged as that change (a SET, a SET with KEEPTTL, a
SETRANGE). PFMERGE is an act of the database in focus (`APfMerge`), as SORT with STORE
is: it reads its keys and writes their union over its destination, logged as a SET with
KEEPTTL. A file of Redis's, which holds the PF commands themselves, is read by running
them. The `pfadd` event, WATCH and COMMAND's table, made from Redis's JSON files, follow
Redis; PFDEBUG, which Redis does not signal, touches no watched key.

**The laws.** The proofs of updates take `UHll` with the change each command makes (a
PFADD of a key not there puts its value, also when a walk of its opcodes fails, as Redis
adds the key first), and those of sessions and acts take PFCOUNT of several keys, PFMERGE
and PFSELFTEST as they take SORT (`SPfCount`, `SPfMerge`, `SPfSelfTest`, `APfMerge`).
What the registers hold and what the estimate counts are not proved: the laws speak of
which keys the commands read and write, the tests of the bytes. `make check`, `make
verdict` and `make gencheck` pass.

**Without an Array.** The first version kept the registers of a merge in an Array. A
program that holds an Array anywhere makes the compiler pass every boxed argument of
every loop with its location (`arr_q`) and read shared blocks through their counts
(`BLK_SHR 1`): GET took 125 instructions more per request, SET 125 and INCR 150 (3,442,
4,203 and 4,541), past `make perfcheck`'s 3%, `Nat.div` among others no longer inlined.
The registers are lists now: those above 0, in order, while every HyperLogLog is sparse,
and 4096 words of four registers once one is dense (a register is below 64, so each
byte's top bit is free, and one subtraction gives the larger of two words' bytes); a
histogram is 26 words of two counts of 16 bits, which its loops keep in their parameters.

**Reading the bytes.** A walk of the opcodes matched the value a byte at a time, and
`String.code_at` read each view a run at a time (`str_code_at_far`), with a choice of
`Bool.pick` for each of an opcode's fields: 240 instructions an opcode, where Redis takes
about twenty. A walk now reads the value by index, a copy of it in one chunk (`flat`,
which a command makes when it reads a sparse value, and each set of a register makes of
what it wrote), whose bytes `String.code_at` reads where they lie; an opcode's kind,
length and value are sums of its bits: 80 instructions an opcode. A value past 2,048
bytes takes two chunks,
which `String.code_at` still reads a run at a time. The dense histogram reads the bytes
the same way, a piece of 1,536 at a time, with no list of words between. In the estimate,
a halving, a product by 2^k and a quotient by 2^14 move a double's exponent (exact for
these numbers, far from where a double's range ends), and a count of 0 adds nothing: the
float library rounds what is left.

**Its cost** (section 59 of PERFORMANCE.md). PFADD of an element a sparse HyperLogLog of
100 elements holds takes 41,277 instructions, five times Redis's 8,264; of a new one,
66,086 (Redis 10,793); on a dense one about four times Redis's. PFCOUNT of a count kept
takes four times Redis's; a count it makes, which runs the estimate on doubles in
software (about half a million instructions), 13 to 18 times Redis's for one dense
HyperLogLog or two sparse ones (886,216 for two of 100 elements, Redis 49,632), and 2.6
times for two dense ones, where most of Redis's time goes to their 16384 registers.
PFMERGE of two sparse ones takes 1.2 times Redis's, of two dense ones 2.4 times. GET, SET
and INCR take what they take on main.

**Tests.** `tests/hll_test.py`, against Redis: the cases of unit/hyperloglog and of
`hyperloglog.c`, values made by hand (registers past 32, opcodes short of 16384 registers
or past them, an XZERO cut at the end, with the sets that split it), values corrupted at
random bytes, and random sequences of the commands, each reply compared and each written
value read back byte for byte: 17,264 commands, each answered as Redis answers it, and
again over RESP3. The PF commands run in the scenarios of keyspace events, of WATCH and
of transactions, of the append-only file both ways, and in the restart test; redis-py's
tests of PFADD, PFCOUNT and PFMERGE come off the client suites' known failures.

**Redis's suite.** 1,173 of the 1,677 tests Redis passes (69.9%; 1,153 before), 1,166
of the 1,244 in what BendKV has (94%): unit/hyperloglog passes its 20 tests. Its fuzzing
test (1,000 PFADDs of up to 3,000 elements, bytes set at random, a PFCOUNT) takes 53
seconds on BendKV and 41 on Redis in the same harness, whose client takes most of both,
under the suite's limit of 60; it ran past that limit on the first version, whose walks
cost twice as much, and the six tests after it never ran.

**Where BendKV differs.** `hll-sparse-max-bytes` is not read: a sparse HyperLogLog turns
dense past 3,000 bytes, its default. PFSELFTEST runs Redis's checks on fewer cases. Redis
keeps the byte past a string's end from one command to the next, where BendKV reads 0 as
each command starts: a sparse value whose last set split an XZERO cut at its end, which
only a value written by hand ends with, reads its second byte differently in the next
command. A PFADD that a corrupt value stops after it changed registers keeps the change in
Redis without a signal, an event or a log of it; BendKV writes the value, with its event,
a touch of WATCH and its log. The log holds SETs and SETRANGEs where Redis's holds the PF
commands, and Redis 7.0.15 without Ubuntu's fix takes some values BendKV finds invalid.
OBJECT ENCODING answers `embstr` for a HyperLogLog of up to 44 bytes, which Redis made
`raw`, and MEMORY USAGE differs as it does for any value.

## 3zzk. CLIENT PAUSE and CLIENT UNPAUSE

**What there is.** CLIENT PAUSE timeout [WRITE|ALL] and CLIENT UNPAUSE as Redis 7.0.15
runs them (`pauseClients`, `unpauseClients` and the check of `processCommand`), in the
actor (`src/server.bend`, The pause). A pause of writes holds back the commands that
write or may be replicated (`stat.pausable`, generated from Redis's flags `write` and
`may_replicate`: PFCOUNT and PUBLISH among them), and an EXEC whose transaction queued
one; a pause of all holds back every command, CLIENT UNPAUSE and QUIT too, as Redis does.
A pause while one holds keeps the more restrictive kind and the later end, and one of a
timeout of 0 adds no end (CLIENT PAUSE 0 ALL turns a pause of writes into one of all
until the same time). The timeout is read as Redis reads it, after the mode: "ERR CLIENT
PAUSE mode must be WRITE or ALL", then a long long ("ERR timeout is not an integer or out
of range", "ERR timeout is negative"); one whose end passes a long long's range wraps in
Redis to a time long past and ends no pause, and so it does in BendKV. COMMAND's table
gains `client|pause` and `client|unpause` (CLIENT has 15 of Redis's 16 subcommands), and
CLIENT HELP their lines.

**Where the pause comes in.** As in `processCommand`: after the checks of the command's
name and arguments, of authentication, of maxmemory, of a RESP2 subscriber's commands and
of a monitor's (which Redis makes as for a replica), and before MULTI queues the command.
So a command refused before them (an unknown one, a wrong number of arguments) is
answered at once, a write in MULTI waits before it is queued, and EXEC waits when its
transaction holds a write. A monitor is never held back: Redis never pauses a replica,
and a monitor is one to it; under a pause of all, a monitor's CLIENT UNPAUSE is the only
one that runs before the pause's end.

**A client held back** waits as the client of a blocking command waits (Blocked
clients): in the chain of the clients that wait, as `BlkPause`, with the command at the
head of the rest of its batch and the batch's arguments as sent from it on, its call not
yet counted, its channel marked with the command. CLIENT LIST shows it with flag b, the
command as its last and the size of its arguments, and INFO's blocked_clients counts it,
as Redis counts a postponed client. No key serves it and no time ends it. When the pause
ends (CLIENT UNPAUSE, or the first tick past its end, as Redis's cron ends it), the
clients it held back go on at the end of the group, in the order they came, each from the
command held back, which runs as if it came then: counted, fed to the monitors, held back
again if a new pause holds. A client held back whose connection closes, or that CLIENT
KILL kills, is forgotten as a waiting client is.

**The data set kept still.** While a pause holds, the sweep of expired keys and eviction
do not run, and nothing is refused past maxmemory, as Redis's `activeExpireCycle` and
`isSafeToPerformEvictions` stop while clients are paused: a key whose time passed reads
as gone, as it always does in BendKV, and DBSIZE still counts it, as Redis's does. The
sweep runs as the pause ends, at CLIENT UNPAUSE or at the tick that ends it, where Redis
deletes such keys as lookups find them after the pause (unit/pause reads expired_keys
right after CLIENT UNPAUSE and two GETs).

**The fast way.** While a pause holds, bit 25 of Ps's ev keeps every batch on the
general way, a command at a time, where the shell of each command sees the pause
(`sh.of`, `pause.holds`). The pause lives in the registry of clients (`Cls`, a node that
Ps holds), so nothing grows on the fast way: GET, SET and INCR take what they took
(3,320, 4,077 and 4,394 instructions per request; 3,321, 4,075 and 4,395 on main).

**Where BendKV differs.** CLIENT UNBLOCK of a client held back answers 0 and leaves it
held back: Redis 7.0.15 crashes on it with TIMEOUT (`replyToBlockedClientTimedOut` knows
no postponed client) and, with ERROR, sends the client the error and later runs its
command all the same. EVAL of a script BendKV does not run (an error its parser finds)
is not held back, as it writes nothing; Redis holds back a script that does not declare
no-writes, and runs it after the pause. EVAL of the scripts of BendKV's own append-only
file, which write, is held back. A pause's end is seen at the tick after it (every 100
ms), where Redis also sees it when a lookup, an eviction or a cycle of its event loop
checks it. A timeout of 2^47 ms or more (thousands of years) ends at a time past any
other, a runtime's Nat staying below 2^48. Redis's other purposes of a pause (a
failover, CLUSTER FAILOVER) have no counterpart.

**The command codes.** Two more keys of INFO's statistics take 904 of the 924 words of
twelve bits with six set (`stat.cw`) that a request's code rides in: the next commands
(GEO's ten) need words of another kind. (Section 3zzl makes the room.)

**The laws.** The proofs speak of what commands do to the databases; the pause holds
commands back without changing what any does, and CLIENT PAUSE and UNPAUSE are commands
of the server (`SClient`, as CLIENT KILL is), which a session answers OK, as Redis
answers a client alone. `make check`, `make verdict` and `make gencheck` pass.

**Tests.** `tests/pause_test.py`, against Redis: the commands' errors; a pause of writes
(reads, PING and CLIENT run; a write, PFCOUNT, PUBLISH and BLPOP wait; CLIENT LIST, INFO
and the statistics of a client held back); a pause of all ended by its time, with a
CLIENT UNPAUSE and a QUIT held back until then; MULTI, EXEC and DISCARD under a pause;
a pause a transaction starts; a pause and a write in one pipeline; keys whose time passes
while the pause holds; a subscriber, PUBLISH and a monitor; a pause of writes made one
of all; a blocking command's timeout while a pause holds; the order the clients held back
go on in; a client held back that leaves or is killed; the parser's errors under a
pause: 28 lines, each as Redis's. Then BendKV alone: CLIENT UNBLOCK and EVAL as above,
100 clients held back and answered in order, and 100 let go by a pause's end. redis-py's
5 tests of CLIENT PAUSE and UNPAUSE come off the client suites' known failures.

**Redis's suite.** unit/pause passes 9 of its 14 tests; the other five run Lua scripts
(EVAL, EVAL_RO, FUNCTION LOAD) under a pause. 1,182 of the 1,677 tests Redis passes
(70.5%; 1,173 before), 1,175 of the 1,258 in what BendKV has (93%); no other test changed.

## 3zzl. LASTSAVE, ROLE, WAIT, SHUTDOWN, MEMORY and LOLWUT

**What there is.** The administrative commands a server alone answers, as Redis 7.0.15
answers them on a master with no replica:

- LASTSAVE: the time of the last save, which is the start: BendKV writes no RDB
  snapshot, and Redis's `lastsave` is its start until it saves one (INFO's
  rdb_last_save_time, which LASTSAVE equals in both).
- ROLE: `["master", 0, []]`, a master at the replication offset 0 with no replica
  (`roleCommand`).
- WAIT numreplicas timeout: its arguments read as `waitCommand` reads them (numreplicas
  a long, the timeout a long long of ms, not negative, each with Redis's error). No
  replica acknowledges anything, so WAIT answers 0 at once when it asks for none
  (numreplicas up to 0) and in MULTI, and otherwise its client waits, in the chain of
  the clients that wait (`BlkWait`), until its time is up (0 never), then answers 0, as
  Redis's `replyToBlockedClientTimedOut` answers the replicas that acknowledged. CLIENT
  UNBLOCK answers it 0 (TIMEOUT) or the UNBLOCKED error (ERROR); CLIENT LIST shows it
  (flag b, its command), INFO counts it (blocked_clients, clients_in_timeout_table), and
  its statistics are Redis's (a call unblocked by CLIENT UNBLOCK is a failed call).
- MEMORY STATS, DOCTOR, PURGE and MALLOC-STATS (`memoryCommand`; MEMORY HELP already
  listed them). STATS is Redis's 27 fields and a map for each database with keys, the
  numbers those INFO's memory section shows (`info.bend`, MEMORY STATS and MEMORY
  DOCTOR): used_memory and its peak, the start's bytes as the overhead, the allocator's
  bytes and the resident memory, no replication backlog, no client buffers apart (INFO's
  mem_clients_normal is 0), no AOF buffer, no scripts; a database's tables' overheads
  are 0, the trie's nodes being in the dataset as INFO counts them. The ratios are C
  floats as `getMemoryOverheadData` computes them, each operation rounded to a float
  (`F.fmt.f`), sent as the double the float is ("99.51629638671875"). DOCTOR reads the
  same numbers: an instance under 5 MB is empty (Redis's text, its Sam and all), past it
  a peak past 1.5 times the memory in use and fragmentation past 1.4 (of the process)
  or 1.1 (of the allocator, and of its resident memory) with more than 10 MB of it are
  issues, each with Redis's paragraph, a float compared with the double as C compares
  them. PURGE answers OK; MALLOC-STATS answers as Redis built with libc's malloc does
  ("Stats not supported for the current allocator"), as INFO's mem_allocator says
  BendKV's is.
- LOLWUT [VERSION v ...]: 7.0.15's own LOLWUT writes "Redis ver. 7.0.15", and VERSION 5
  and VERSION 6 draw the art of Redis 5 and Redis 6, picked as `lolwutCommand` picks
  them, by the version as an unsigned int (`%u.0.0`: VERSION 4294967301 is 5), their
  arguments longs clamped as `lolwut5Command` and `lolwut6Command` clamp them
  (`src/lolwut.bend`, below).
- SHUTDOWN [NOSAVE|SAVE] [NOW] [FORCE] [ABORT]: the flags read as `shutdownCommand`
  reads them (a word that is none of them, ABORT with another, NOSAVE with SAVE: a syntax
  error; ABORT alone: "No shutdown in progress.", as none ever waits for replicas), and
  in MULTI refused as `processCommand` refuses a command flagged no-multi, right after
  AUTH, the transaction flagged; the server stops (below).

COMMAND's table gains lastsave, role, wait, shutdown, lolwut and memory's doctor,
malloc-stats, purge and stats, generated from Redis's JSON files with the rest.

**The command codes.** A call counts as a code, its key and its class (0 runs, 1 is
refused, 2 fails as it parses), and a request carries its code as a word of twelve bits
with six set, of which there are 924. A code was 4 times its key plus its class, a fourth
of the words never used, room for 230 keys: CLIENT PAUSE and UNPAUSE took the keyspace
to 225. A code is 3 times its key plus its class now (`code.key`, `code.class` and
`code.refused` in redis.bend), room for 307 keys, of which these commands take 234.

**SHUTDOWN stops the server** as Redis's `prepareForShutdown` and `finishShutdown` do
when no replica waits (`src/server.bend`, SHUTDOWN): the group's entries are written to
the append-only file as after any group, and the file synced whatever appendfsync says
("Calling fsync() on the AOF file."); a rewrite that runs is stopped and its temporary
file removed ("There is a child rewriting the AOF. Killing it!"); the pid file is
removed; then the log's last line and `exit(0)` (`IO.die` with code 0, which the runtime
ends the process with, saying nothing). Its client is answered nothing, its connection
ending with the process, as in Redis. The commands after it in its batch and the requests
after it in the group do not run, nor do the end of the group (the clients whose time is
up, the batches of those unblocked) and a tick in it: Redis exits within the command.
The replies of the commands before it in the group are not sent, as Redis writes a
round's replies after it and exits within it. The registry of clients keeps the SHUTDOWN
asked for (`Cls`'s down: 1 one that failed, 2 one that stops the server, 3 one that
stops it after a save it could not make), whose bits 23 and 24 of Ps's ev keep the
batches after it off the fast way; the batches after it are dropped as a killed client's
(`ps.killed`); the shell acts on it once the group has run (`db_down`, `aof_down`).
Nothing of it reaches the fast way: GET, SET and INCR take what they took.

**SAVE.** SHUTDOWN SAVE asks for an RDB snapshot, which BendKV does not write: it fails
as Redis's SHUTDOWN does when its save fails: "ERR Errors trying to SHUTDOWN. Check
logs.", a failed call, the log saying why (Redis's lines, and "BendKV writes no RDB
snapshot: it cannot save the data set (appendonly yes keeps it)"), and the server goes
on; SAVE FORCE stops it all the same ("Error trying to save the DB. Exit anyway."). The
save points of `save` save nothing in BendKV (its start warns of it), so a SHUTDOWN
without SAVE stops the server where Redis would save first.

**LOLWUT's drawings** (`src/lolwut.bend`). VERSION 5 is Georg Nees's Schotter: rows of
squares, turned and moved a little more at random from the third row down, drawn with
Bresenham's lines on a canvas of pixels written in braille, a character for each 2x4
pixels, each row of them followed by a newline but the one that starts on the canvas's
last row of pixels (whence the empty line before Redis's last one). Its numbers are
Redis's C floats and doubles, each operation rounded as the C code rounds it: the
canvas's height (`square_side * squares_per_col + padding*2`, in float, cut to an int),
each square's place, its size over 1.4142135623 (in double, then to a float, then
`round`), its corners' angles (`M_PI/4 + angle`, each `M_PI/2` more, in double, rounded
to a float) and the corners themselves (`round(sin(k) * size + x)`). A square that is
not turned has its corners at four fixed floats, whose sines and cosines are glibc's,
kept as doubles' bits: so a drawing of one or two rows, which rand() has no part in, is
the bytes Redis sends (`tests/admin_test.py` compares eleven, up to the 750 KB of
`LOLWUT VERSION 5 500 1 2`). A turned square's angle comes from rand(), whose numbers
no client can know: its sines and cosines are a series to the 13th power in fixed point
(2^-20), within a hundred-thousandth of glibc's, which moves a corner by a pixel once in
a thousand. VERSION 6 is a skyline: skyscrapers in two grays on white, then black ones
in front with windows of the two grays, their places, sizes and window colors at random
(`generateSkyline`'s numbers), written with the terminal's colors, a space for each
pixel. Both take their random numbers from the server's (a stream of 31-bit numbers from
the seed `KV.mix` makes of its state, which the drawing moves on, as RANDOMKEY's), so the
random drawings are ones Redis could have drawn, their sizes and shapes Redis's. The
canvas is no array (an Array anywhere costs every loop of the program): VERSION 5's lit
pixels are codes of the cells they light, sorted (a merge sort, as SORT's) and or-ed a
cell at a time, VERSION 6's colors are found pixel by pixel, from the last skyscraper
drawn over it; the text is built from its end, a character at a time.

**Its cost.** LOLWUT VERSION 5 takes 16 ms (Redis 4 ms), VERSION 6 1 ms, as Redis. The
float library rounds each of a square's ninety operations in software, about 200 µs a
square: VERSION 5 of 200 columns and 50 by 50 squares takes 0.4 s (Redis 3 ms), of 1,000
columns and 100 by 100 squares 2 s (Redis 19 ms), the server answering nothing else
meanwhile; VERSION 6 of 1,000 by 1,000 pixels takes 0.7 s (Redis 0.24 s).

**The laws.** The administrative commands are commands of the server (`SAdmin`, its
kind and its arguments, as `SClient` is for CLIENT), which the session answers with the
server's state and the databases (`admin.reply`): LASTSAVE, MEMORY STATS and DOCTOR read
them, LOLWUT's drawings take the server's random numbers (`own_srv`, as RANDOMKEY), and
none changes a database. The three laws of a session that enumerate its commands take
`SAdmin` as they take `SClient` (an unauthenticated client's changes nothing). WAIT is a
blocking command (`SBlock`) whose pop is none: it acts on nothing, and a session answers
it 0. SHUTDOWN's stop is the shell's, outside the laws, as the rest of the shell is.
`make check`, `make verdict` and `make gencheck` pass.

**Where BendKV differs.** SHUTDOWN SAVE fails, as above, and a SHUTDOWN that fails leaves
a rewrite that runs as it was (Redis stops it before it tries to save). MEMORY
MALLOC-STATS has no allocator's statistics, MEMORY STATS no tables' overheads, and its
functions.caches is 0 (Redis's empty libraries take 200 bytes); DOCTOR looks for the
issues of what BendKV has (no RSS but the heap's, no client buffers apart, no replicas,
no scripts). LOLWUT's random drawings are drawn from other random numbers than Redis's
(none can be compared), and take longer, as above. WAIT never sees a replica. A
SHUTDOWN of a client waiting in a pause of all is held back like any command, and stops
the server as the pause ends, as in Redis.

**Tests.** `tests/admin_test.py`, in `make test` (each mode of the server): against Redis,
97 lines: LASTSAVE as rdb_last_save_time; ROLE; WAIT's twelve errors, its answers at once
and once its time is up, in MULTI, a client that waits as CLIENT LIST and INFO show it,
CLIENT UNBLOCK both ways, one whose connection closes, a pipeline behind it; MEMORY's
help, errors, PURGE, DOCTOR, and STATS's fields in order and the kinds of their values,
with two databases that hold keys; LOLWUT's text and errors, eleven drawings of VERSION
5 byte for byte, the shapes of three random ones and of six of VERSION 6, the verbatim
reply of RESP3; SHUTDOWN's errors and its refusal in MULTI; their statistics. Then, on
servers of their own (a redis-server and BendKV, each in a fresh directory), SHUTDOWN and
its forms stop the server (exit code 0, the connection closed), the append-only file
holds what came before it and not what came after it in the pipeline, the pid file is
removed, a SHUTDOWN in MULTI and one with a bad flag leave it running. Then BendKV alone:
MALLOC-STATS, MEMORY STATS's numbers as INFO's, SHUTDOWN SAVE failing with its log and
SAVE FORCE stopping, and a SHUTDOWN while a rewrite of 200,000 keys runs (its temporary
file removed, the old file whole on a restart). redis-py's 9 tests of LASTSAVE,
LOLWUT, MEMORY STATS, MEMORY MALLOC-STATS and ROLE (sync and asyncio, in each protocol)
and go-redis's test of WAIT come off the client suites' known failures.

**Redis's suite.** Its tests of these commands need servers of their own (unit/shutdown,
unit/wait and unit/acl's, with RDB files, signals and replicas), but one: unit/multi's
MULTI with SHUTDOWN, which passes run alone, fails in its unit's run as five tests around
it do, on a client that an earlier test, which queues a REPLICAOF, leaves in a
transaction. 1,182 of the 1,677 tests Redis passes, as before; no test changed.

## 3zzm. GEO

**What there is.** The ten commands of Redis 7.0.15's `geo.c`: GEOADD, GEOPOS, GEOHASH,
GEODIST, GEORADIUS and GEORADIUSBYMEMBER with their `_RO` forms, GEOSEARCH and
GEOSEARCHSTORE (`src/geo.bend`, from `geo.c`, `geohash.c` and `geohash_helper.c`, and
the GEO section of `src/redis.bend`). A position is a member of a sorted set whose score
is its geohash, as in Redis: its longitude and its latitude each as 26 bits of their
place in their range (-180 to 180, and -85.05112878 to 85.05112878), interleaved into an
integer of 52 bits.

- GEOADD key [NX|XX] [CH] lon lat member ...: its options and its triples read as
  `geoaddCommand` reads them, each error Redis's (a syntax error for words after the
  options that make no triples, or for NX with XX; "value is not a valid float"; "invalid
  longitude,latitude pair" with printf's `%f` of each, `F.fl.show_f`), then the ZADD of
  the scores its positions make, as Redis's GEOADD calls ZADD: its WRONGTYPE is ZADD's,
  and its entry in the append-only file is that ZADD, each score the integer Redis
  writes.
- GEOPOS, GEOHASH and GEODIST read the sorted set of their key: a position as
  `decodeGeohash` makes it from a score (the middle of its cell), GEOHASH's eleven
  characters of the position in the standard ranges (latitudes from -90 to 90), GEODIST's
  great-circle distance (haversine, on a sphere of Redis's radius) in its unit (M, KM,
  FT or MI, read before the key is looked up); a member not there is a null.
- The searches read their arguments as `georadiusGeneric` reads them once it has looked
  the key up: GEORADIUS's center and radius even for a key not there, GEORADIUSBYMEMBER's
  member only in a key that is there; then the options a word at a time, each taken only
  where its kind takes it and the words it takes follow (STORE and STOREDIST with a key
  for GEORADIUS and GEORADIUSBYMEMBER, a bare STOREDIST for GEOSEARCHSTORE, FROMMEMBER,
  FROMLONLAT, BYRADIUS and BYBOX for GEOSEARCH and GEOSEARCHSTORE), then the checks in
  Redis's order (STORE with WITHDIST, WITHHASH or WITHCOORD; no FROM; no BY; ANY without
  COUNT). A search reads the cells Redis reads (`geohashCalculateAreasByShapeWGS84`: the
  step its radius or its box picks, fewer toward the poles, the center's cell and the
  eight around it, those a step too small makes useless left out), the members of each
  in the order of their scores (`membersOfGeoHashBox`), keeps those within its circle or
  its box (`geoWithinShape`), and stops at ANY's count.
- ASC and DESC sort what a search finds by distance as glibc's `qsort` does (a stable
  merge sort, in glibc's own order of merges, so that points at the same distance, and a
  NaN distance near the antipodes, come out where Redis's do); when COUNT keeps fewer
  points than were found, as Redis's `pqsort` does (NetBSD's quicksort that sorts only
  the parts that reach the places kept): its steps are made one by one, each comparison
  and each swap, on a vector of the points, so that the points it keeps and their order
  are Redis's. COUNT without ASC, DESC or ANY sorts ASC, as Redis does.
- A point answers as Redis answers it: WITHDIST its distance in the unit with four
  decimals (`fixedpoint_d2string`), WITHHASH its score as an integer, WITHCOORD its
  position as `addReplyHumanLongDouble` writes it (`%.17Lf` with its last zeros taken
  out; a double in RESP3).
- STORE, STOREDIST and GEOSEARCHSTORE write what they find at the destination as a
  sorted set (the scores, or the distances in the unit), with no time, whatever the key
  held (`setKey`), with the keyspace event `georadiusstore` (`geosearchstore`); when they
  find nothing, or the key is not there, they delete the destination (`del`) and answer
  0.

COMMAND's table gains the ten, generated from Redis's JSON files with the rest, and
COMMAND GETKEYS finds the destination of GEORADIUS's STORE and STOREDIST as Redis's key
specs find it, by a keyword: a key spec of a new kind (`KSpecKw` in `command.bend`), the
keyword looked for from its start to the argument before the last, the key the argument
after it.

**Doubles in the runtime** (patch 33, `f64-natives.patch`). A distance is sines, cosines,
an arcsine and a square root of doubles, and Redis's are glibc's libm: float.bend's
doubles in software round as C rounds the four operations, but a sine is libm's own
polynomials. Bend's base gains the double, `F64`: C's binary64 as the two 32-bit halves
of its bits (a term holds no 64-bit word), with `F64.read` (strtod), the four operations,
`neg`, `abs`, `sqrt`, `exp`, `log`, `log2`, `log10`, `sin`, `cos`, `tan`, `asin`,
`acos`, `atan`, `atan2`, `sinh`, `cosh`, `tanh`, `pow`, `mod` (fmod), `floor`, `ceil`,
`trunc`, the six comparisons and the conversions from a U32 and a 64-bit integer and to
a 64-bit integer (cut, or rounded to the even one), each a law of base (a function the checker knows only by its
type) that the C lane runs as C's own double arithmetic, strtod and the libm it links:
a program reads, computes and rounds as a C program built with the same libm does. The
JS lane runs Number and Math, and reads what glibc's strtod reads (decimal and hex,
each rounded to the nearest, ties to even). `src/geo.bend` makes each operation of
Redis's in its order, each conversion as C makes it (a double to an unsigned 64-bit
integer as gcc makes it on x86-64, `(long long)` of a score): its positions, geohashes,
cells and distances are Redis's, bit for bit, on 309 positions and on 80 searches of a
set of 462, compared with Redis's C (`geohash.c`, `geohash_helper.c`) built alone; its
sorts are glibc's `qsort` and Redis's `pqsort`, built alone, on 640 lists (ties and NaN
distances among them); its `%f` is printf's on 329 values.
float.bend's `f64.parse`, Redis's `string2d` (ZADD's and ZINCRBY's scores, ZUNIONSTORE's
weights), reads with `F64.read` now, which is glibc's strtod itself, in place of
float.bend's strtod in software, which reads what it reads (`tests/float_test.py`
compares both with glibc).

**Its cost** (PERFORMANCE.md, section 60). On a sorted set of 20,000 positions, a
GEOSEARCH that finds 698 of them takes 0.66 ms (Redis 0.27 ms), sorted and with WITHDIST,
WITHHASH and WITHCOORD 7.4 ms (Redis 1.1 ms: each coordinate is `%.17Lf` of a long double,
made in software), COUNT 10 of them 2.5 ms (Redis 0.20 ms: `pqsort` made a step at a
time on a vector that is a tree); a GEOADD of the 20,000 takes 194 ms (Redis 22 ms), as
much as a ZADD of their scores.

**The fast way.** Two things that GEO first added cost every request. A command travels
in registers as wide as its widest form, from the parse of a request to its reply, so
each form keeps one field of a word. GEO's reads first went as one form holding the
read, a GEODIST among them with its members and its unit's meters (a double, two words):
a command four words wider (a parsed request twelve words where it was eight), which
every request pays for, in each push of the parse's continuation, each copy into the
batch and each step of exec. Each read of GEO is a form of its own now, of one word:
GEOPOS's and GEOHASH's members, GEODIST's members and unit as they came (the unit read
as the command parses, for its error, and again as it runs), a search's arguments as
they came, its kind told by the name it was called by. And the widest result of any
function sets what every return of the program copies (`WL_RESW`): a search's options
(`GOpt`: the flags, COUNT, STORE's key, the center, the shape and the unit's meters,
doubles of two words each) went flat in the results of the options' loop, 26 words
where the widest had been 17. `GOptOf`, options that hold options, never built, makes
`GOpt` a node of its own, as `RwOf` does the rewrite's state (section 3zv). GET, SET and
INCR took 90 instructions more per request with both (3,407, 4,168 and 4,479 against
3,316, 4,077 and 4,390 on main, under callgrind: the parse's loop 31 more, the work
loop's returns 26, exec's steps 24), 27 more with the second alone, and 3,316, 4,075 and 4,393 now.

**The laws.** GEOPOS, GEOHASH, GEODIST and a search that does not store read their key
(`ZRGeoPos`, `ZRGeoHash`, `ZRGeoDist` and `ZRGeoFind`, reads of a sorted set, as ZSCAN's
is), and change nothing. GEOADD is ZADD. A
search that stores is a command of the session (`SGeoStore`, its kind and its
arguments) that writes its destination with what it finds, an act of the session's
database (`AGeo`), as SORT with STORE and PFMERGE are: the laws of acts (their split,
their effects, the invariant of the databases) take it as they take those, and the three
laws of a session that enumerate its commands take `SGeoStore` as they take `SPfMerge`.
`make check`, `make verdict` and `make gencheck` pass.

**Where BendKV differs.** A COUNT past 10^14 counts as 10^14 (a runtime's Nat stays
below 2^48; no sorted set holds as many members). The doubles are those of the libm the
server is linked with, as Redis's are: two machines with different libms answer
different last digits, as two Redises would. The time, above.

**Tests.** `tests/geo_test.py`, in `make test`: against Redis, in RESP2 and RESP3, every
reply byte for byte and, after each write, the sorted set it leaves and its time to
live: the cases of Redis's unit/geo and of `geo.c` (GEOADD's options and errors, a
position's text, the searches' options, their errors and the order they come in, a key
not there and one of another kind, STORE and STOREDIST, COUNT and ANY, ASC and DESC,
points at the same distance, which `pqsort` leaves in an order of its own, boxes across
the antimeridian and near the poles), random sets and random searches (5,078 and 5,016
commands for seeds 1 and 2, none different), a search of 20,000 points, the keyspace events of the
writes, MULTI, COMMAND GETKEYS and INFO's statistics. `tests/aof_redis_test.py` takes
GEOADD and the searches that store, with destinations that are strings, have a time, or
expired: Redis's file loaded by BendKV and BendKV's by Redis hold the same sorted sets.

**Redis's suite.** unit/geo passes all its 59 tests, its fuzzing tests (random sets of
up to 20,000 points, each search compared with a search in Tcl) in 29.5 s where Redis
takes 16.4 s. unit/introspection-2 passes 37 of its 43 (17 before): the statistics of
GEOADD, of its errors and of MULTI (which queues a GEOADD), GEORADIUS marked
movablekeys (its STORE's key found by a keyword), and the 16 tests after the one of
MULTI, whose client it had left in MULTI on GEOADD, so that they were answered QUEUED.
1,261 of the 1,677 tests Redis passes (75.2%; 1,182 before), 1,254 of the 1,317 in what
BendKV has (95%); no other test changed.

## 3zzn. Long requests in time proportional to their length

**What it was.** unit/geo's fuzzing test sends GEOADDs of 20,000 points, 60,000
arguments in one request, and such a GEOADD took BendKV 3.6 to 6.2 s, past the suite's
limit; main's server takes 1.4 s to parse one before it answers that it does not know
the command, and an EXISTS of 40,000 keys takes 245 ms. A request is parsed
where it lies, in the buffer of the bytes read, a packed String of chunks of up to 2,048
bytes; a read by index (`String.code_at`) walks the chunks from the String's start, so
each argument read near the end of a request of n bytes walked n / 2,048 chunks, and a
request's parse took time in proportion to the square of its length. A long request
arrives in reads of 64 KB, each followed by a parse from its start, so this was paid
several times over.

**What it is.** The arguments of a request longer than a chunk are read through a
window (`args.from` in `src/resp.bend`): a copy of one chunk's worth of the buffer
(`String.slice`, 2,048 bytes from where the next argument starts), moved on once fewer
than 1,024 of its bytes are left, so that each read walks one chunk. An argument that
runs past the window, with more of the buffer after it, is read from the buffer itself,
as before (a long argument is one read). A request that is not whole yet asks for more
bytes as it did, so that the protocol's errors and their timing are as they were. A
GEOADD of 20,000 points now takes 194 ms, an EXISTS of 40,000 keys 29 ms (Redis 3.6 ms),
an RPUSH of 40,000 elements 30 ms where it took 249 (PERFORMANCE.md, section 60).

## 3zzo. Clients that wait or watch, and the fast way

**What it cost.** The fast way ran a batch only while no client waited in a blocking
command, none had a transaction or watched a key, and no keyspace event was to go out
(`group_job`). So one client in BLPOP or one WATCH put every batch of every client on the
general way, a command at a time. After each command the actor also walked the whole
chain of the clients that wait, with a lookup in the trie for each of their keys (3zp said
so; its cost was not measured). GET at pipeline 16 lost two thirds of its throughput with
one client in BLPOP or one after WATCH, nine tenths with 100 in BLPOP, and almost all of
it with 1,000 (#30; [PERFORMANCE section 61](PERFORMANCE.md)). Redis looks a written key up
in `blocking_keys` and `watched_keys`, and a client that waits or watches costs nothing to
the commands on other keys.

**What runs now** (`src/server.bend`, Heeded keys).
- The registry of the clients (`Cls`, in Ps) keeps the keys that clients heed (`Hd`): the
  keys a client waits on and the keys a client watches, in any database, as a trie. A key
  goes in as a client starts to wait on it (`bg.wait`) or watches it (`bg.watch`).
- While some client waits or watches, a batch of database commands (no command of the
  connection or of the server) runs the fast way when three things hold: its client may
  run it so; it is in no MULTI (`tx.in.multi`, where its commands are queued); and none of
  its commands may write a heeded key. The keys a command may write are those LAWS.bend's
  `writes` names (every key for FLUSHDB). The clients that wait and the transactions stay
  as they were (`grp.keep`). Any other batch runs the general way, as before.
- Why that is enough: the law `frame` makes a command leave as it was the entry of each key
  its `writes` does not name, and the keys a command of the database touches for the
  clients that watch (Touches, in `src/server.bend`) are keys its `writes` names. So after
  such a batch no client that waits finds what it waits for, and no watched key is
  touched.
- A batch that writes a key some client waits on still runs a command at a time, and its
  waiter is served right after the command that wrote the key: with a client in `BLPOP q`,
  the pipeline `RPUSH q x`, `LPOP q` answers nil to LPOP, as Redis does.
- On the general way the clients that wait are looked at only after a command that may
  make one ready (`bg.stir`): a command of the connection or of the server (SWAPDB, MOVE,
  COPY, SORT with STORE, EXEC among them), or a command of the database that may write a
  heeded key. Before such a command none was ready, and after any other none is. The check
  runs before the command, which changes neither the clients that wait nor the heeded keys,
  so the command is lent to it and then given to the run.
- The set is made anew at a tick when a client that heeded keys stopped since it was made
  (`heed.tick`: two counts, compared without a walk of the keys). With it goes the earliest
  time a wait ends (`soon`): at the end of a group the actor walks the chain of the clients
  that wait, for those whose time is up, only once that time has passed (`grp.end.due`),
  where it walked the chain at the end of every group.

**How a batch is checked without reading its commands.** The first check read each
command of the batch (`heed.cmd` over the list) and cost far more than it read:
- `Cmd` is laid out unboxed, and the same word holds a string in one constructor and a
  number in another (`BitOp`'s op, `IncrBy`'s amount). A `Cmd` read out of a list is
  unpacked into those words, and the compiler cannot keep a word borrowed whose
  constructors disagree (`val_arms` in `comp.ts`): it calls `slot_keep` on every string
  field of every command, whatever the check then does with it. Nested patterns
  (`Con{R.Set{k, v}, rest}`) unpack the same way. Section 7 says as much: a borrowed match
  on `Cmd` gives every pointer field it binds a reference count.
- `slot_keep` seals the string in place. A batch of SETs then put its keys and values in
  the keyspace sealed, and every later GET of those keys read one more word: under
  callgrind with 100 clients in BLPOP, GET counted 9.6% more than without them, with 0.57
  more last-level misses per GET on the seals (`term_peek`), and the prefetches of `btouch`
  reached only the seal (the same number of prefetches, none of them of a key's bytes).
So the batch is checked by the hashes its requests carry. A request's hash holds in its
high twelve bits its call's code, and the parser writes fixed marks there for a call of
GET, SET and INCR that runs (`R.stat.mark.*`). GET writes nothing; SET and INCR write their
key alone, their first argument, and the low twenty bits of the hash are that key's (the
parser's ways for the three, and `req.hash`: both commands touch their first key). A heeded
key such a write may write lies in the bucket of that hash. `KV.tget_hn` (generated with the
other walks) says whether the bucket holds an entry, reading the trie it is lent. A batch of
GETs, SETs and INCRs alone, none of whose writes finds a heeded key in its bucket, runs the
fast way with no command read (`heed.quick`). Any other batch is read command by command
(`heed.cmds`), with the counts above, and a SET whose bucket holds a heeded key is one of
those; a key in the bucket that is not the one written then costs a read, not the general
way. The walks are tight loops that match their list alone: one that matched a flag beside
the list dropped the command it had bound in one arm, and so took it over in all of them.

**What it costs.** Nothing while no client waits or watches: the first case of
`group_job` is as it was, and the generated C of the fast way is the same, function for
function (the per-function diff of `bend src/server.bend -o x.c`: the functions of the
registry, `bg.cmd`, WATCH and `group_req` change; `fast` becomes a function of its own,
entered by a jump, where `group_req` held it inline). GET, SET and INCR take 3,335, 4,083
and 4,411 instructions per request under callgrind (3,323, 4,080 and 4,395 on main,
counted the same way: two runs of one build differ by as much). With 100 clients in BLPOP,
GET and SET take 3,418 and 4,215, 2.5% and 3.2% more than without them in the same run,
and miss the last level 2.83 and 3.17 times per request, where they miss 2.80 and 3.11
without them (the build that read every command: GET 9.6% more, 3.54 misses). On main,
one client in BLPOP took GET and SET to 13,706 and 15,030 (PERFORMANCE section 61, with
the throughput). `make perfcheck` counts GET and SET with 100 clients in BLPOP and fails
past 5%.

**What is left.**
- A batch that writes a key some client heeds runs the general way, a command at a time,
  as before; on it the actor still walks the whole chain after a command that stirs
  (`waits.find`), where Redis serves from the key's list of clients.
- A batch with a command other than GET, SET and INCR is read, with the counts above: its
  strings go into the keyspace sealed while some client waits or watches. The general way
  seals them too (`bg.one.q` uses a command after running it), as it did before this change.
- A key no client heeds any more sends the batches that write it the general way until the
  tick after its client stopped.
- While keyspace events are on, a monitor is connected, a pause holds or the server is past
  maxmemory with nothing left to evict, every batch runs the general way, as before.

**Tests.**
- `tests/blocking_test.py`:
  - a pipeline that pushes to a key a client waits on and then pops it (the client served
    between them);
  - with 100 clients waiting, pipelines that write twelve kinds of commands to other keys,
    one of GETs, SETs and INCRs alone, then one that writes a key among theirs in the
    middle, and an LMOVE to one;
  - each against Redis.
- `tests/multi_test.py`:
  - a pipeline of commands in MULTI (each queued: the check of MULTI);
  - WATCH with another client's pipeline that writes other keys only (EXEC runs), or the
    watched one among them (EXEC answers a null array);
  - the same with GETs, SETs and INCRs alone, untouched and touched by an INCR.

## 3zzp. The heap under AddressSanitizer, the writer under ThreadSanitizer

**What was missing.** Eight of the compiler's patches change reference counts,
ownership, borrowing and the reuse of nodes in place (1, 3, 5, 7, 8, 26, 31 and 32), and
one bug of that kind shipped: after the fifth, the general way kept a node across a call
and freed the server's statistics while a shared cell still pointed at them, and under
CLIENT REPLY OFF the server read them from freed memory at the next tick and died
(`SIGSEGV`, section 3zp; the twenty-sixth patch fixed it). The proofs cannot see such a
bug, and nothing else looked for one: CI ran no memory checker, and valgrind served
callgrind only. AddressSanitizer alone would not have seen it either. To ASan the
runtime's heap is one mapping, all of it addressable, and a free chain is LIFO: a node
read after its free is no error, and the next allocation of its class takes the node
over at once.

**What there is.** The thirty-fourth patch (`heap-asan.patch`) gives a build with ASan a
heap it can check: the allocator poisons a free node's words, its chain's link among
them, and lifts the poison off a node it hands out; a free first puts the node in a
quarantine of its thread and class, a ring that lets it go to its chain once 2^22 more
words of its class have been freed. A stale pointer meanwhile finds poison, and ASan
reports the read or the write with its stack. Built without ASan, BendKV's C preprocesses
to the same bytes with the patch and without, and the server is the same binary.
`tools/sanitize.sh`, CI's `sanitize` job, builds the generated C at `-O1` with ASan and
UBSan, and with TSan, and runs under each, with replies posted and sent: a client that
stops reading, clients that wait, transactions, Pub/Sub, the protocol's edge cases, the
statistics per command, RESP3, the differential test (three seeds), the concurrency
checks, a load from redis-benchmark (50 clients pipelined, then 100 not, under which the
loop falls behind and posts to its writer), and connections that end. A report, a
failed test or a server that dies fails it. ASan leaves out one check, a stack frame used
after its function returns: the check moves the frames it instruments to a heap of its
own, and LLVM 19 cannot realign such a frame under the runtime's `preserve_none` and
`preserve_most` calling conventions (the build stops: "Stack realignment in presence of
dynamic allocas is not supported with this calling convention"). UBSan runs every check
of `-fsanitize=undefined`, and TSan suppresses nothing.

**What it found on main.** Nothing: no report from ASan, UBSan or TSan, and every test
passes under each. TSan watched the writer at work (4.3 s of its thread's time under a
load of redis-benchmark like the job's) and holding the posts of a client that stops
reading (`tests/writer_test.py`); outside the job, an append-only file synced at every
write, and its rewrite, gave no report either. The writer's queue, its held posts and the
loop's own sends pass between the threads through atomic operations, a mutex with its
condition variable, and a pipe, all of which TSan follows, so nothing needed a
suppression. The one read the runtime makes
racily by design, `IO.heap`'s account of other threads' allocator rows, had nothing to
race with: BendKV runs all its computations on one event loop.

**Patch 26 reverted.** `spare-share.patch` reverse-applies cleanly on the thirty-three,
and 59 write-backs leave BendKV's C and nothing else changes, in segments of the general
way (`bg.cmd`, `bg.run`, `bg.serve`, `bg.subs`, `bg.exec`, `bg.go`, `bg.watch`,
`bg.client`, `bg.put` and others), of SORT and of the RESP encoders. The plain server
shows nothing: of the 29 test files run on it, the job's and most of `make test`'s first
mode, all pass but MONITOR's, which fails now and then here on main's server too, under
the load of other builds. The job fails it at `tests/resp3_test.py`: in its scenario of
a RESP3 client subscribed to keyspace events that runs commands, ASan reports a
use-after-poison in `ctr_take` (from `ctr_own`, from `bg.put`): a node read after its
free, at the same address in every run of a build. The scenario that crashed then
(CLIENT REPLY OFF, then PING, then a tick of the cron reading the statistics) passes
clean without the patch on today's code, under the poisoned heap too; the job keeps it
(`tests/stats_test.py`'s replies held back). On Bend's own test of the patch,
`tests/rfc/spare_share.bend`, the plain build prints a wrong sum, 206 for 46; ASan alone
prints the same in silence, and so does the poison without the quarantine, since the
freed cells go to the next list at once; with the quarantine, ASan reports the read of a
freed cell in `sum`.

**What it costs.** Nothing in the normal build. The job's script took 19 minutes here,
on 4 cores shared with other builds, the generated C already made (making it is a Bend
compile of about 2.5 minutes more): the ASan build 7.4 minutes and its tests 3.2, the TSan
build 4.3 and its tests 3.7. CI gives the job an hour.

## 3zzq. The append-only file killed under load

**What was missing.** The laws prove recovery for the model of the file (`recover`,
`recover_cut`, `checked_replay`, section 3e). What the shell writes, when it syncs and
when it answers a client was tested three ways: restarts after a clean kill, a tail cut
on purpose (`restart()` in `tests/run_tests.sh`) and one SIGKILL while a rewrite runs
(`tests/rewrite_test.py`). Nothing killed the server at a random moment under load and
checked every write it had acknowledged (issue #39).

**What the test checks.** `tests/crash_test.py` runs rounds on one file: clients write,
the server is killed with SIGKILL after a random time, the replies left in the sockets
are read, the server starts again from its file, and the next round writes on. The
server runs the batches of all its connections through one actor, so it ran its
commands in one order, and its file holds their effects in that order. A unit is a
command, or a transaction whole. A start must hold the databases that a prefix of that
order leaves from those of the round's start, and the prefix must hold every unit
acknowledged. The test does not see the order whole, so the load is made for the check
to be exact: one connection's order is the order it sent its units in; with several,
each connection writes keys of its own, where the commands of different connections
commute, and they push ids onto lists they share, whose order is the server's, each
acknowledged push at the place its RPUSH answered. The databases after each prefix come
from a model of the 38 commands the load sends (and of MULTI, EXEC and DISCARD around
them); checked once against redis-server 7.0.15, it gave every reply of 285,000 units
and the keyspace after them, and BendKV's replies are compared with it in every round.
A round draws 1 to 16 connections that pipeline 1 to 128 units, the fsync policy, the
writer thread or the loop, a BGREWRITEAOF or the cron's rewrites made frequent, values
of up to 512 KB in some rounds, and in some a second kill while the start loads the
file. The units mix MSET, MSETNX, RENAME, COPY, MOVE, SWAPDB, FLUSHDB, SMOVE, LMOVE, the
stores of sets and transactions (a SELECT inside now and then) with writes of one key,
beside 20,000 keys no unit touches, so that a rewrite and a start take a while. A start
must also leave the file as the kill left it but for an entry or a transaction cut short
at its end, the bytes its log names.

SIGKILL stops the process and not the machine: what the server wrote is in the page
cache, and the next start reads it. The server writes a group's effects before it
answers (and with always syncs them first), so every policy must keep every
acknowledged unit. What sets always apart shows only when the machine stops: with
`--lazyfs`, the server's directory is on a LazyFS mount, and after each kill LazyFS drops
every write not synced, as a machine that stops loses its page cache; every round then
runs with always.

**What it found.** No durability problem. 200 rounds took 487 s here, on four cores
shared with other builds: 3,368,013 units acknowledged, all restored, and 5,132 more of
those sent after them; 59 kills while a rewrite ran, 59 starts killed again, 40 of them
while they loaded the file. On LazyFS (built here, with a libfuse 3.16 of its own), 60
rounds with always: 1,022,132 units acknowledged, all restored once the writes not
synced were dropped; with `--policy no` the first round fails, as it must, nothing
having been synced. And the test fails when the file is damaged after each kill as a
durability bug would leave it (`--break lose`: its last whole entry dropped, as if the
server had answered before writing it; `--break hole`: one of the twenty before it),
naming the connection, its units acknowledged and sent, the closest prefix and the keys
that differ.

One failure was the test's own. A round on LazyFS with one connection had two SWAPDBs
in the file that were sent and not acknowledged; stepping through one, the check compared
again only the keys the swapped databases held after it, so a key that had differed only
before it stayed counted, and no prefix matched. The check now compares again every key
that differed in a database a step changes whole, and tries itself first, before any
server (`--self-check`): a model plays the server, every connection's units in one order
that keeps each one's, cut at random, and the check must accept the databases after the
cut and refuse them without one acknowledged unit's effect, with SWAPDB and FLUSHDB
frequent. On 2,000 simulated rounds of each kind it accepted all 4,000 and refused all
1,670 such damages; without the fix it fails at its first. A failed round now keeps what
the check ran on, and `--recheck` runs the check again on it.

A kill seldom stops a write in its middle (the kernel looks for a fatal signal only
between the pages of a write): of about 1,400 rounds run here, three did, two of them in
rounds with values of up to 512 KB; their starts cut the entries cut short (3,396 to
144,667 bytes), and the rounds after them appended to the files so cut. The tail cut of
`tests/run_tests.sh` and the laws `recover_cut` and `load_cut` cover that path too.

**What it costs.** `make test` runs 20 rounds: about 50 s here, a second of it the
check's own test.

**What it does not check.** The syncs of the directory: LazyFS makes a file and renames
one at once and never drops a name (`tests/aof_fail_test.py` traces the file's creation,
its directory's sync and the first reply instead). everysec on LazyFS, which may lose the
last second's acknowledged writes: the test does not know when the syncer last ran. CI
runs no LazyFS: the job would need FUSE 3 and LazyFS built in it.

## 3zzr. Seeds of each run, and a nightly run

**What it was.** `make test` ran the differential test (`tests/diff_test.py`) 13 times,
three seeds against each of its four servers and one in RESP3, from seeds 1 to 4 and
for 1,000 rounds each: some 75,000 commands, the same ones in every run. A stream those
four seeds do not draw went unsent however often CI ran.

**What it is.** `tests/run_tests.sh` takes the seeds from `SEED` (and the three after
it): 1 by default, the seeds `make test` always took, and 4 ×
`GITHUB_RUN_ID` + 1 in CI, so that each run sends commands of its own and no two runs
share a seed (a job run again keeps its run's id, and sends the same ones). It prints
them first, with the line that sends them again (`SEED=N DIFF_ROUNDS=R make test`),
and a mismatch prints the line of `diff_test.py` that replays its stream up to the
batch that failed. `.github/workflows/nightly.yml` runs `make test` on main every night
with `DIFF_ROUNDS=13500`: 13 runs of 13,500 rounds, about a million commands. A round
is 5.8 commands on average and takes about 0.4 ms here (50,000 rounds, 290,577
commands, in 19.5 s), so the million take about 80 s of a job whose build and other
tests take the rest.

**What it found.** The first eight seeds run at that length (620,000 commands against
the defaults) found a mismatch in the test itself: an SPOP of a set {1, a}, answered
`a` by BendKV and `1` by Redis. Both are right: SPOP of a key alone pops a member at
random. The stream sent it from its line of set commands with a wrong number of
arguments (none, or a key), where every other command is an error, a plain read
(SINTER of one key) or a read whose random pick the comparison puts aside
(SRANDMEMBER), and the comparison knew SPOP's arrays (sorted) but not its one member.
Seeds 1 to 3 never draw such an SPOP, and the two that seed 4 draws happen to pass; of
200 new seeds of 1,000 rounds, one failed on it (seed 1064: `SPOP k5`), so about one
CI run in 15 would have failed for nothing. That line now sends SPOP without the key
(its error of arity) after the same draws, so the rest of every stream is as it was.
With it, the same 200 seeds pass (1.16 million commands), and so do 21 more of 13,500
rounds against each kind of server `make test` starts (the defaults in RESP2 and
RESP3, post, send, and an append-only file: 1.63 million commands).

**What it costs.** Nothing in CI's time; the nightly run is one job a day. A failure
CI meets can now be one no earlier run met, which is the point: its seed is in the
log.

## 3zzs. Tests that pass only after a rerun

**What it was.** The client suites run a failing test again: redis-py up to twice
(`--reruns 2`, but not one that fails on an unknown command), go-redis's specs up to
three attempts in all (`-ginkgo.flake-attempts=3`). A test that passed on a rerun
counted as passed, so a race in BendKV that shows once in three runs passed CI unseen.

**What it is.** `tools/client_suite.py` counts each test's attempts in a suite's
results (`attempts`): pytest writes each attempt of a test it reruns as a case of its
own, those before the last with no child, as a pass reads, and an error in the teardown
after a failed call as one more case, which is no attempt; ginkgo keeps one case and
names each retry in its timeline (`Attempt #1 Failed.  Retrying`). A test BendKV
passes only after a rerun, where Redis passes it at its first attempt, is reported in
the job's report; from `RERUN_GRACE` on (2026-11-15; `RERUN_GRACE` in the environment
gives another day) it counts as failed, so that the job fails on it as on any test
Redis passes and BendKV fails. Until then a race it shows can be fixed without failing
CI. A test that needs a rerun on Redis too is the suite's or the machine's, and is not
reported. The reruns stay: they keep the job from failing on what fails on Redis too.

**What it shows.** In two CI runs of main, every test that took more than one attempt
failed at the last, on Redis (37 tests of redis-py in each protocol, 3 of go-redis) as
on BendKV (14 and 74, all on commands BendKV does not have): none passes only after a
rerun, and the job passes as before. On a copy of main's results where redis-py's
`test_incrby` passes on BendKV at its second attempt, written as pytest writes it,
main's job passes without a word; this one reports it ("Passed on BendKV only after a
rerun, at the first attempt on Redis (1 tests; failures from 2026-11-15 on)") and exits
0, and with `RERUN_GRACE=2026-10-01` it fails, with "1 regressions ... passed only after
2 attempts on BendKV, at its first on Redis". go-redis's spec "Commands strings should
Incr", retried once, gives the same. On results written by pytest 9.1.1 with
pytest-rerunfailures 16.7 as the job runs them, and by bsm/ginkgo v2.12.0 (go-redis's),
the count finds 2 attempts for a test that passes at its second, 3 for one that always
fails (with an error in its teardown or not), and 1 for one that fails on an unknown
command.

**What it costs.** Nothing in CI's time: the results are read once more.

## 3zzu. DUMP and RESTORE

**What there is.** DUMP and RESTORE as Redis 7.0.15 runs them (`src/rdb.bend`, from
`rdb.c`'s `rdbSaveObject` and `rdbLoadObject` and `cluster.c`'s `createDumpPayload`,
`verifyDumpPayload` and `restoreCommand`, with `listpack.c`, `ziplist.c`, `zipmap.c`,
`intset.c`, `lzf_d.c` and `crc64.c` as far as a payload needs them; and the section
"Dump and restore" of `src/redis.bend`). A payload is a value's type (a byte), the value
as RDB writes it, the version of the format (10, two bytes, the low first) and the CRC64
of all that (Jones's polynomial, reflected, from 0), eight bytes, the low first.

- DUMP writes a value as Redis 7.0.15 does with `rdbcompression no`: a string as the
  integer of 1, 2 or 4 bytes it is the text of, else its length and its bytes; a list as
  a quicklist of listpacks (type 18), cut into nodes where Redis's own (8 KB,
  `list-max-listpack-size -2`) would cut it, pushed at its last end; a hash of the small
  kind as a listpack (16), a large one as its pairs (4); a set kept as an intset as one
  (11), of the narrowest width, another as its members (2); a sorted set of the small
  kind as a listpack (17), a large one as its members with their scores as binary
  doubles, from the greatest (5). Each length, listpack entry, back-length and header is
  Redis's, so that a payload is Redis's byte for byte where both servers hold the value
  alike: a string, a list pushed at its last end, a hash, set or sorted set in a listpack
  or an intset, a sorted set in a skiplist.
- RESTORE reads every type Redis 7.0.15 reads but streams' and modules': strings in
  each of their encodings, LZF's too; lists of type 1, ziplists (10) and quicklists of
  ziplists (14) or listpacks (18); sets of type 2 and intsets (11); hashes of type 4,
  zipmaps (9), ziplists (13) and listpacks (16); sorted sets of types 3 (scores as text,
  read as `strtod` reads them) and 5, ziplists (12) and listpacks (17). It makes the value
  Redis makes, of the kind Redis's load picks: a hash or sorted set from a listpack or a
  ziplist stays small by its count alone, its elements however long (`rdbLoadObject`
  converts these by `hash-max-listpack-entries` and `zset-max-listpack-entries` only),
  one of type 4, 3 or 5, or a zipmap, by its count and its longest element; a sorted set's
  -0 keeps the sign each of Redis's encodings keeps. It checks a payload as deep as Redis
  does with `sanitize-dump-payload yes`: every length against what is left, each
  listpack's and ziplist's header, entries, back-lengths and previous lengths, an intset's
  width and order, a zipmap's free bytes, pairs, duplicates and empty values, a member or
  field twice, a score that is no number; what Redis refuses there, BendKV refuses ("Bad
  data format").
- RESTORE key ttl payload [REPLACE] [ABSTTL] [IDLETIME s] [FREQ f] checks what Redis
  checks, in its order: its options first (IDLETIME not after FREQ, nor FREQ after
  IDLETIME, each with a value: "Invalid IDLETIME value, must be >= 0", "Invalid FREQ value,
  must be >= 0 and <= 255"), then, once the key is looked up, BUSYKEY, the time (not a long
  long; "Invalid TTL value, must be >= 0"), the payload's version and checksum ("DUMP
  payload version or checksum are wrong") and its value; then OK, and the key set with
  the time (none for 0; from 1970 with ABSTTL, else from now), or, for a time already
  past, or one from now past LLONG_MAX (which Redis's sum wraps into the past), the key
  deleted when REPLACE found it, else nothing. Its keyspace events are Redis's: `new` and
  `restore`, after `expired` without REPLACE for a key whose time had passed (REPLACE
  deletes such a key without one); `del` for the key REPLACE deleted.
- IDLETIME and FREQ set the key's word of use (section 3zw) as Redis's
  `objectSetLRUOrLFU` sets a value's 24 bits: FREQ's counter under an LFU policy,
  IDLETIME's time under any other, as Redis reckons it on its LRU clock of 24 bits (the
  clock less the seconds, plus `LRU_CLOCK_MAX`, 2^24 - 1, when that is below 0, cut to 24
  bits), the other option left aside. RESTORE with either is a command of the session
  (`SRestore`): the session runs its update on its database, and the server, which runs
  such a command one at a time, sets the word once the update restored the key, as its
  effects show, in MULTI too. Under an LFU policy, the mark of every RESTORE has made the
  word a new value's before it runs (section 3zzx).

The append-only file logs a RESTORE as the RESTORE of its payload with REPLACE (the key
may be there when the file loads, its time passed), and ABSTTL with the time it gave the
key, from 1970; or the DEL of the key REPLACE deleted. A file of Redis's, where RESTORE is
as the client sent it (a time from now made one from 1970, with ABSTTL), loads as Redis
loads it, IDLETIME's and FREQ's aside (below).

**The laws.** DUMP is a read of its key (`PDump`, a Peek). RESTORE is an update of its key
(`URestore`, an Upd: its payload, its time as it read it, REPLACE, and IDLETIME or FREQ)
whose change sets the key to a payload's value (`CRestore`: the payload, the value, the
time). Such a change is good when the payload's version and checksum and its value read as
the value (`D.verify`, `D.load`) and the time is one a key keeps; every RESTORE makes good
changes (`rs_busy_good` and the lemmas under it, each over one step of `restore.of`), and
the change's effect, run at time 0, makes it again (`restore_replay`: the RESTORE logged
finds the payload good and the time not past) and parses back to itself
(`restore_args`). The laws of a session that enumerate its commands take `SRestore` as
they take `SGeoStore`. `make check` and `make verdict` pass.

**Where BendKV differs.**
- DUMP writes no LZF: its payloads are those of `rdbcompression no` (Redis compresses by
  default the strings of more than 20 bytes that LZF makes shorter). RESTORE reads both.
- A hash or a set in a hashtable dumps its pairs or members in the order of BendKV's trie,
  not of Redis's dict; a list pushed at its first end, or trimmed, or changed inside, as
  the quicklist Redis makes pushing at its last end; an intset at the narrowest width
  (Redis keeps a width a member that is gone needed). Each is the same value, as each
  server reads the other's.
- RESTORE checks every payload in depth, as Redis does with `sanitize-dump-payload yes`
  (its default, `no`, checks less and takes some broken payloads that it may crash on
  later). A sorted set in a listpack whose members are out of order, which those checks
  let through, BendKV keeps sorted.
- A time at or past 10^14 ms (the year 5138) gives the key none, as everywhere in BendKV.
- REPLACE with a time already past, over a key whose time had passed but that still lay
  there: Redis deletes it (a DEL logged, `del`), BendKV leaves it to expire (`expired`).
- IDLETIME past LLONG_MAX / 1000 s, where Redis's product of it and 1000 overflows: BendKV
  takes the seconds as they are. IDLETIME and FREQ in a file that loads set no word.
- A value of 100,000 elements takes RESTORE 7 to 38 times Redis's time, DUMP 3 to 31
  times, and both less than the commands that make the value (PERFORMANCE.md, section
  62).

**Tests.** `tests/dump_test.py`, in `make test`, against Redis with `rdbcompression no`
and `sanitize-dump-payload yes`: values of every kind and encoding made by the same
commands on both servers, their DUMPs compared byte for byte where both hold them alike,
each payload restored on each server and Redis's compressed ones on both, the values and
their encodings read back; RESTORE's options, errors and times in RESP2 and RESP3; payloads
of the encodings Redis no longer writes, then 1,500 payloads cut, grown and changed at
random (their checksums made right), each restored on both, replies and values compared;
the keyspace events, IDLETIME and FREQ under LRU and LFU policies (OBJECT IDLETIME and
FREQ, past the clock's turn too), in MULTI and on a key there, WATCH, COMMAND GETKEYS,
INFO's statistics, and values of up to 5 MB and 100,000 elements: 3,167 checks, none
different. `tests/aof_redis_test.py` takes RESTORE both ways, with REPLACE, ABSTTL,
IDLETIME and FREQ, times past, keys whose time had passed and a transaction.

**What the tests found after the merge.** Run with other seeds, the random payloads found
two things. One stopped the server: an intset whose header gave a width of 0x03000008 and
a count of 0x27000000. The check that the intset's bytes hold its count of values of
that width multiplied the two before the check that the width is 2, 4 or 8, and the
product passed 2^48, where a runtime's Nat stops (`bend: a Nat past the largest
immediate`). A hash's count near 2^48 doubled past it the same way. The width in the
product is now cut to 8, and a hash's count to the bytes left, as each of its strings
takes one at least; no other number read from a payload is multiplied or added past
2^48 (a length read as 64 bits stops below 2^40 times 256). The other was a count whose
byte has the two high bits of an encoded string's kind: Redis reads a count with
`rdbLoadLen(rdb, NULL)`, which takes such a byte's six other bits for the count, where
BendKV refused the payload; it reads them so now. `tests/dump_test.py` now also restores
each payload with each of its first 16 bytes on overwritten by numbers at their
extremes, so that its headers' lengths, counts and widths pass 2^32 and 2^48, on both
servers.

**Redis's suite.** unit/dump passes the 11 of its 12 tests that Redis passes in this mode
(1 before; the twelfth uses DEBUG, which Redis refuses here), and unit/type/list its two
tests of a ziplist of various encodings, which restore one (216 of its 218).
unit/type/hash's two tests of the same kind run past DUMP and RESTORE now and fail on the
order of HGETALL of the hash they make: its values of 8 and 64 KB, which Redis keeps in a
listpack under `hash-max-ziplist-value 1000000000`, make BendKV's a table (its small
hashes are those of the parameters' defaults). 1,273 of the 1,677 tests Redis passes
(75.9%; 1,261 before), 1,270 of the 1,333 in what BendKV has (95%). The client libraries'
suites: redis-py's 12 tests of DUMP and RESTORE pass, in RESP2 and in RESP3, and
go-redis's 3, which leaves 2,513 of the 2,753 tests Redis passes in redis-py and 408 of
460 in go-redis.

## 3zzv. Long longs

**What there is.** INCR, DECR, INCRBY, DECRBY and HINCRBY on Redis's whole long long, as
`incrDecrCommand`, `decrbyCommand` and `hincrbyCommand` run them: a value or a field read
as `string2ll` reads it, an increment read before the key is looked at, a sum past
LLONG_MAX or below LLONG_MIN refused ("increment or decrement would overflow"), and
DECRBY of LLONG_MIN refused before the key is looked at ("decrement would overflow").
BendKV's integers had at most 14 digits (section 3v, "Fourteen digits"), so that a sum of
two stayed below 2^48, where a `Nat` stops the runtime: a value or an increment past 14
digits was not an integer to BendKV, and a sum past 14 digits an overflow. The
differential tests skipped those replies as a known divergence; they compare them now.

**How.** A long long's magnitude is two `Nat`s, hi·10^9 + lo (`LL`, which the readers of
times and counts already used for numbers past 14 digits): hi is below 10^10, the sum of
two below 2·10^10, far from 2^48. `ll.read` reads a value of up to nine characters at once
(`String.digits_at` and `String.dec_at`, by index) and any other through `ll.at`;
`ll.add` adds two, signs apart or alike, and checks the sum as Redis does; `ll.show` writes
it, the last nine digits padded by showing 10^9 + lo and dropping its 1. The increment a
command carries is `By`, its sign in its constructor (`ByPos{hi, lo}`, `ByNeg{hi, lo}`):
a command travels in registers as wide as its widest form, and an `LL`'s three fields made
`IncrBy` the widest, every command a word wider: GET and SET took 11 instructions more
each. The reply is the sum's text (`RIntS`).

**Cost.** Instructions per request (callgrind, `tools/perf_guard.sh`; main's in brackets,
on the same machine): INCR 4,413 (4,385), GET 3,303 (3,306), SET 4,065 (4,067). The
protocol's slow reader of a length line keeps its own reader of a long long (`ll.of`):
with `ll.at` there, the parser compiled otherwise, and SET took 62 more. By the runtime's
functions (callgrind, a build with lines), INCR makes its sum's text once where it made
it twice (to see that it fit in 14 digits, and to store it), and no longer writes its
digits into the reply (`nat_show_str` 52 instructions fewer, `nat_show_into` 30); reading
the value by index (`str_digits_at`, `str_dec_at`) costs 54, copying the text into the
reply (`str_mov`, `str_append`) 68, and the compiled Bend code takes 44 fewer. Two
attempts cost more and were left: an `Int` reply for a sum below 10^9 (13 instructions
more: the text is made anyway, for the store), and padding the digits with
`String.repeat`, which sent `ll.show` through the work loop (2 more indirect
mispredictions a request, 12 instructions).

**Proofs.** The lemmas of INCRBY and HINCRBY (the frame, the reply, the key, the bridge to
the specification, the time, the count of keys, the update's equivalence and its good
changes) case on an `LL` where they cased on a `Maybe<Int>` and a `Bool` of fitting; a key
not there gets `by.ll(by)`. `incr_missing` answers `RIntS{"1"}`. The laws keep their number.

**Tests.** `tests/numbers_test.py` adds INCRBY, DECRBY and HINCRBY to values at LLONG_MAX
and LLONG_MIN and to keys and fields not there (2,541 commands); `tests/diff_test.py`
draws values at a long long's edges and has no known divergence left of integers;
`tests/aof_redis_test.py` logs increments past 14 digits and overflows both ways;
`tests/smoke.bend` checks 99999999999999 + 1 and LLONG_MAX + 1. Redis's suite:
unit/type/hash passes HINCRBY's test of overflows, which starts from
-9223372036854775484 (70 of its 72); 1,274 of the 1,677 tests Redis passes, 1,271 of
the 1,333 in what BendKV has.

## 3zzx. The word of use of a key RESTORE makes

**What failed.** After DUMP and RESTORE merged, `make test` failed in CI on three runs of
pull requests (#57 twice, #58 once) at one check of `tests/dump_test.py`, and passed on
main's run: OBJECT FREQ of a key that RESTORE had just made under `allkeys-lfu`, with
IDLETIME alone (`lfu3`) or no option (`lfu4`), was 1 on BendKV and 5 on Redis. On fresh
servers the test passed every time, and after the servers had run five minutes too, so the
time since the start was not the cause.

**Why.** A key's word of use is one of 2^20, by the low twenty bits of its hash (section
3zw): keys share it, and no delete clears it. Before a batch runs, each request marks its
key (`use.lfu`). Under an LFU policy, a word never set becomes a new value's, a counter of
5 at the minute; any other word is decayed by the minutes since its last decay and then
stepped as a use. Most words in the table are LRU seconds, which every other policy
writes: read as an LFU minute and counter, such a word nearly always decays to 0, and the
step makes it 1 (another key's LFU word gives that key's counter, less one a minute,
stepped). RESTORE's FREQ sets the word once the key is restored (section 3zzu), but
without FREQ the word stayed as the mark left it. In `make test`, 27 test files run on the
same server before `tests/dump_test.py`, and their keys leave words in much of the table,
so whether `lfu3`'s or `lfu4`'s word had been another key's depended on the test's random
names. Redis makes RESTORE's value new, with a counter of 5 at the minute, whatever key
had the name before. A million SETs of random keys on a fresh server, then FLUSHALL, then
`tests/dump_test.py`: 4 runs of 4 failed, at `lfu3`, `lfu4` or both, 1 against 5 each
time.

**What runs now.** Under an LFU policy, the mark of a RESTORE gives its key's word a
counter of 5 at the minute (`use.lfu.word`), whatever word is there, as Redis makes a new
value; FREQ then sets the word as before, and IDLETIME, which an LFU policy ignores,
leaves it at 5. The mark tells a RESTORE by its request's hash, whose high twelve bits the
parser writes with the call's code (`R.stat.mark.restore`, which `tools/gen_commands.py`
now generates with GET's, SET's and INCR's). Under any other policy a mark already writes
the second of now, whatever word is there. No other command's mark changes.

**Where BendKV differs.** The mark comes before the command, so a RESTORE that fails makes
the word new too. BUSYKEY (the key there, no REPLACE) sets the counter of the key that is
there to 5, where Redis's lookup of that key steps its counter as a read does (after SET
and DUMP, Redis 6 and BendKV 5); with REPLACE, a time or a payload refused leaves Redis's
word as it was, where BendKV's becomes 5. A RESTORE queued in a transaction marks as it is
queued (section 3zw). Other commands that make a key, SET for one, still find the word
another key left.

Two other ways were left aside. Running every RESTORE as a command of the session
(`SRestore`) and setting the word from its effects, as IDLETIME and FREQ do, would be
exact for a RESTORE that fails too. But the RESTORE the parser reads would no longer be
the `Upd` that a logged RESTORE must parse back to (`restore_args`), and a batch of
RESTOREs would run the general way. Sending a batch with a RESTORE the general way, and
setting the word after it there, would add a test of every request to the split of every
batch (`unzip` in `src/batch.bend`).

**Tests.** `tests/dump_test.py` now makes each key it restores under an LFU policy, and
deletes it, under `allkeys-lru` first, so that RESTORE finds an LRU second in its word at
every run. With main's server that fails at `lfu3` and `lfu4` at every run (3 of 3 on
fresh servers, 1 against 5); with this change it passes, on fresh servers (2 of 2) and
after the million random SETs above (3 of 3).

## 3zzy. Intsets as trees of integers

**What was left** (sections 3zj, 3zze). An intset kept its members as a list of their
strings in increasing order. SADD, SREM and SISMEMBER walked the list from its start,
and each step compared two members as integers, reading the digits of both again (four
`String.dec_at` of ten digits each): on an intset of 100 to 500 members, SADD of a new
member took 270,366 instructions, SISMEMBER 155,772 and SREM 274,643, where a
hashtable's took 8,347, 5,403 and 14,598. SADD took no intset out of the keyspace, since
the test of its member cost more than the take saved (section 3zze).

**The change** (`src/map.bend`, Sets).

- An intset's members are a weight-balanced tree (`ITree`: a tip, or a node of n members
  whose member comes after those of its left side and before those of its right),
  balanced as a sorted set's tree is (section 3zl).
- Two members compare as integers: by their signs, then by their numbers of digits (an
  intset's integers have no leading zero), then by their bytes as memcmp orders them
  (`String.order`), the other way for two negative ones (`ints.cmp`).
- A member is found, added or taken out in O(log n) steps (`ints.has`, `ints.put`,
  `ints.del`), and the member at a rank in as many (`ints.nth`), which SRANDMEMBER and
  SPOP pick by its rank.
- SMEMBERS, SSCAN, DUMP and the rewrite of the append-only file read the members in
  increasing order from the tree (`ints.list`). RESTORE of an intset, whose members come
  in increasing order, makes the tree at once (`ints.build`, a walk with a list of jobs,
  as `zel.build` makes a sorted set's: section 3zzu) and no trie of the members to find
  one there twice, which members in increasing order cannot be.
- SADD of a member that an intset lacks takes the set out of the keyspace (`upd.takes`),
  as it takes a hashtable: the test of the member is a walk of log n steps now.

**The proofs.** The lemmas of SADD's sizes take a tree where they took a list
(`le_ints_*`), and `has_none` the empty tree. SADD of a member an intset lacks makes it
one larger (`le_ints_new`, `le_ints_putn`), so it writes the set over and may take it
(`takes_madd_ints`, under `takes_over`). `make check` and `make verdict` pass.

**What it gives.** Instructions per command (callgrind, pipelined: 400 new members
added in a random order to an intset of 100, then tested, then taken out; the same on a
hashtable of as many short strings):

| command | before | after | a hashtable |
|---|---:|---:|---:|
| SADD of a new member | 270,366 | 14,013 | 8,347 |
| SISMEMBER | 155,772 | 6,992 | 5,403 |
| SREM | 274,643 | 15,519 | 14,598 |
| DUMP of an intset of 500 | 913,736 | 900,901 | |
| RESTORE of it, with REPLACE | 3,992,621 | 1,225,958 | |

An SADD and an SREM of one member took 37,297 instructions on an intset of 8 members,
139,567 on one of 64 and 158,995 on one of 400; they take 21,866, 28,374 and 31,989 (on a
hashtable: 23,943 to 24,653). The take saves SADD 2,418 of them. Wall time, one request
at a time (the median of three runs, each the median of five): SADD 75 µs before, 53 now
and 51 on Redis; SISMEMBER 64, 51 and 48; SREM 74, 53 and 50: an intset's command takes a
round trip now, as Redis's does. An SADD of 500 integers takes 0.46 ms (7.9 before, 0.16
on Redis), and a RESTORE of them 0.19 ms (0.42 before, 0.05 on Redis). GET, SET and INCR
as before (`make perfcheck`: 3,306, 4,067 and 4,411 instructions per request; main 3,302,
4,069 and 4,411).

**Where BendKV differs.** A member takes a node of four words: an intset of 500 members
takes 16,768 bytes of BendKV's heap (8,824 as a list), where Redis's takes 1,080 (2, 4 or
8 bytes a member, the width of its widest). An add or a deletion makes a new node at
each step back up the tree and drops the old one, where Redis moves the members after the
new one with a memmove.

**Tests.** `tests/set_test.py`: an intset of 512 members of every width (400 of them long
longs at random), added in a random order and taken out in another, its members compared
in order with Redis's every 64 adds and every 32 deletions, with SCARD, SISMEMBER,
SRANDMEMBER and SPOP along the way: 6,244 commands, each answered as Redis answers it.
Redis's suite: unit/type/set, unit/sort, unit/scan, unit/dump and unit/keyspace pass the
tests they passed (222 of the 226 Redis passes).

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
- Strict arguments make `Bool.or` and `Bool.and` evaluate both sides, so a search
  written with them never stops at its first success: KEYS's old glob explored every
  split of the key even for a pattern that matched at once (section 3r). A choice that
  may stop early has to be a `match`.
- Affinity: a hypothesis (`∀k. …` or a refutation `a != b`) can be used once, while
  equalities are data and can be copied. Refutations become equalities of boolean
  verdicts.
- The checker evaluates `Nat` in unary. A constant like 10^14 overflows its stack, so
  INCR's overflow check counts digits; the parser rejects `Nat` literals above
  2^32 − 1.
- No tactics: every rewrite step is written by hand. The proofs are about as long as
  the code, and checking them is fast.
- In a proof, `case other` does not refine the goal: the variable stays abstract ("`c`,
  but not `Get`"), and functions of it do not reduce. Lemmas about commands list every
  constructor of `Cmd` (counted in [README.md](../README.md#in-numbers)), most of them as
  refutations; so commands come in groups (`Own` for those
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
  avoided it. A large one (INFO's 38 words) widened every call that carried it, and the
  widest result or frameless parameter list is the signature of every segment of the
  program; patch 21 makes a datatype wider than 32 words a node (section 3p).
- A `+` binder lets a value be used twice, and when a later use takes it over the
  compiler copies it: a list counted after a call took it over cost a copy, a drop of
  the copy element by element, and a reference count on every field read after. The same
  count made first is a borrowed walk.
- A function that returns a field of a borrowed parameter owns that parameter, and so
  does every caller that lends it on: one accessor returning the password made the
  server's state be kept field by field on every batch. Computing the answer inside the
  match keeps the parameter borrowed (section 3p).
- A def called from two places is a segment of its own, entered through the work loop;
  the same steps written out in both callers stay in their segments.
- The widest variant of a datatype sets the width of all of its values: one command of
  the session with a field of two words made every parsed command a word wider, and a
  GET 27 instructions dearer (section 3q).
- Every file read (and `IO.random_u32`) runs on a helper thread of the runtime; the first
  one makes the process multi-threaded for good, and glibc's cancellable system calls
  then take their longer path, ~50 instructions each.
- The C compiler reads types off annotations: an application chain over a variable drops
  its erased arguments and places the live ones by the head's type, so a term built by a
  compiler pass needs the same annotations the elaborator writes (section 3j).

What helped:
- The theory and the runtime representation are separate ("native kinds"): strings
  became buffers without touching a single proof.
- The C backend is readable, so each runtime idea became a patch and a measurement.
- Checking is fast: about 15 s for all the laws, plus an independent kernel proved in
  Lean.

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

Every change since the start, the patches to Bend (p1 to p25, numbered as before
section 3l, which took p16 out) and BendKV's own (sections 7.N of PERFORMANCE.md), on one
scale. The gain is the best reliable measurement
on the load the change was made for: time, or, where time stays in the noise (±5–15%),
instructions or memory. The cost is what the change adds to `comp.ts` in `ttok` tokens
(the Bend repository caps the file at 64 thousand; the original has 62,940, with our
patches 101,094), BendKV's lines of code and proof, and what lines do not show: a new
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
| 9. memory prefetch | 248 | 21. process and clock (today's 20th) | 108 |
| | | 22. flat limit (today's 21st) | 67 |
| | | 23. native `String.order` (today's 22nd) | 617 |
| | | 24. writer hold (today's 23rd) | 2,649 |
| | | 25. file durable (today's 24th) | 0 |
| | | **all** | **38,154** |

```
          cheap                                  costly
×N        p1 lazy seal, p9 hints,                p2 packed strings
          7.6 16-way trie, group commit, p23
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
  second heuristic on top of patch 15. Patch 23, a native `String.order`: ZRANK of a
  member among equal scores 8.5 times fewer instructions, among their own 2.1 times,
  for 617 tokens and 50 lines of C that must agree with Base's definition.
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
compiler 690 tokens of 38,154. Strings are nearly half the growth of `comp.ts` (17,770
tokens) and most of the single-core speed. Since 7.22, fewer instructions have rarely
meant less time: the kernel is half of a request's CPU with a pipeline and two thirds
without one, and what paid was work on the path through it (patches 15 and 17) or
cutting half the instructions (the windows). The send rules carry eight constants tuned
on one VM and should become one rule. For upstream, patch 1 is the best ratio, stands
alone and fits the 1,060 tokens left under the cap, so it should go first, before patch
19; patches 5, 7, 15, 4c and 18 are the candidates to drop or shrink (8,721 tokens), but
even without them ~29 thousand tokens remain, so `comp.ts` itself has to get simpler.

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

## 12. A review of the protocol and the connections

A review of the first commit (9bd45b6) filed, among others, five issues about the
protocol and the connections. Each was checked again against the code of 26 commits
later (914713d): one had been fixed in between, four still held.

**KEYS ([#4](https://github.com/littleBro/bendkv/issues/4)).** The first commit's glob
took both ways at each `*` with `Bool.or`, which evaluates both arguments: ten stars
against a key of ten bytes cost 537,471 calls. Section 3r's port of Redis's
`stringmatchlen` had replaced it: one function with an explicit mode, so a star's loop
ends at its first match (`SmTry`), a run of stars is one star (`sm.unstar`), a star that
ends the pattern matches at once, and a rest that matches nowhere after a star ends the
search (`SmStop`, Redis's `skipLongerMatches`), so each star's loop runs once at most. A
model of the matcher's calls gives what each cut-off saves: `"*a" * 100` against 200 a's
takes 201 calls, and 3.3 * 10^60 trying both ways; `"a*" * 20 + "b"` against 40 a's (Redis's
own regression) takes 40, and 3.4 * 10^11 without the search's end. Comparing long patterns
with Redis showed one difference left: the Redis the tests run against, Ubuntu's 7.0.15,
carries the fix for CVE-2024-31228 (upstream since 6.2.16, 7.2.6 and 7.4.1), under which a
call of `stringmatchlen_impl` nested in more than 1000 others matches nothing, so
`"*a" * 1001` matched a key of 3000 a's on BendKV only. The matcher now counts how deep
the rest after a star is nested (`SmIn`), with a bound on its depth that still holds (four
levels for each byte of the pattern, three for each of the key's). `tests/keyspace_test.py`
compares KEYS and SCAN's MATCH with Redis on 32 such patterns, adjacent stars,
alternatives that match at once or nowhere, literal mismatches, classes and escapes among
stars, and stars nested past 1000; each answers at once, where a matcher without one of the
cut-offs would not answer within the client's timeout.

**Lengths ([#9](https://github.com/littleBro/bendkv/issues/9)).** The parser read a
length's line with `String.dec_line_at`, 1 to 10 digits and `"\r\n"`, and a count's '-'
by skipping it, so `*01`, `$04` and `*-0` passed where Redis 7.0.15 refuses them, and
`*-10000000000`, which Redis skips, was refused. Redis's `processMultibulkBuffer` finds a
line's end with `strchr` (the first `'\r'`, hidden by a NUL before it, and whatever byte
comes after it, skipped unread), waits for it up to 64 KB, then reads the number with
`string2ll`: a sign, no `0` before the first digit, from -2^63 to 2^63 - 1; a count past
INT_MAX or no number is an error, a count of 0 or less skips the request, and a bulk's
length must be from 0 to 512 MB. The quick way stays for the lines clients send: a line of
two digits or more whose number has fewer digits starts with a 0 and leaves it, at the
cost of a comparison with a power of ten for those lines only. Every other line now goes
Redis's way (`line_at`, then `R.ll.of`, the reading of `string2ll` that HELLO and the
commands use), and so does a bulk that does not start with `'$'`, whose error waited, in
Redis, for its line. `tests/protocol_test.py` gained 37 cases (the issue's four among
them, and the lines Redis waits for, hides behind a NUL or refuses past 64 KB); its
closures are no longer read from a quiet socket: a server holds a connection open when
INFO counts it, and closed it when the client saw the end of the file, and every case
checks that both servers let the connection go once the client closes it. Left out: the
tighter limits Redis sets before a client authenticates (an error past 10 arguments or a
bulk of 16 KB), which need the connection's state in the parser, and a new
proto-max-bulk-len, which BendKV keeps but does not apply.

**Errors on one line ([#6](https://github.com/littleBro/bendkv/issues/6)).** HELLO's
error quoted its option as it came, so `HELLO 2 "a\r\nb"` answered two lines where Redis
answers `-ERR Syntax error in HELLO option 'a  b'`; the parser's diagnostics held a CR and
LF of their own (`expected '\r\n' after bulk data`) or the raw byte it did not expect
(`expected '$', got '\r'`), and went out as they were. Unknown commands, subcommands and
CONFIG SET's options had been mended in between, each where its error is made. Now the
encoder sends every error reply on one line: a CR or LF in its text goes out as a space,
as Redis's `addReplyErrorFormat` and `rejectCommandFormat` send theirs, after a look for
either (two `String.find`s, on error replies only); the parser's diagnostics go out through
the encoder too. HELLO's error is formatted as Redis formats it (`R.e_fmt`), and the
arguments an error quotes stop at their first NUL, as `%s` stops (HELLO's option, the name
and first arguments of an unknown command, an unknown subcommand, an unknown CONFIG SET
option): Redis answers `unknown command 'no'` to `no\0pe`. The trailer the issue noted,
`*1\r\n$4\r\nPINGxx`, which BendKV refused and Redis answers `+PONG` to: Redis never looks
at the two bytes after a bulk's data, as it never looks at the byte after a line's `'\r'`,
and BendKV no longer does either, so its diagnostic is gone, and so are two reads of the
buffer and their comparisons from every bulk the parser reads. 17 cases in
`tests/protocol_test.py`.

**A channel for each connection ([#5](https://github.com/littleBro/bendkv/issues/5)).**
Each connection opens a channel for its answers (`Chan.new` in `conn_start`), and none
was ever closed: a client that closed, reset, sent QUIT or a protocol error, or a send that
failed, closed the socket alone, so each connection left a row of the runtime's channel
table and its ring behind, and the table stops the process at 16,777,216 rows. A test
that reads the table's size in the server's memory (`chan_len`, through
`/proc/<pid>/mem`) saw 3 rows grow to 124 after 120 connections. Now every way a
connection ends goes through one teardown, `conn_end`, which closes the socket (after the
bytes posted to it) and then the channel; nothing can be on its way to the channel then,
since a connection waits for each batch's answer before it goes on, so `Chan.close` frees
the row at once and the next connection takes it again. The actor's channel, shared by
every connection, stays open. The protocol error's reply is the last thing a connection
sends (`conn_bye`), and the connection ends whether it went out or not.
`tests/conn_test.py` ends 300 connections in six ways (the client closing after a request
or before any, QUIT, a protocol error, the client resetting before the server reads its
request and while it sends a reply of a megabyte) on a BendKV of its own, posting and
sending: INFO counts no connection left, the database answers a new connection, and the
table holds 4 rows after, 3 before (304 before the fix).

**Protocol errors under CLIENT REPLY OFF ([#10](https://github.com/littleBro/bendkv/issues/10)).**
The protocol error's reply went out from the connection's loop, which never looked at the
connection's reply mode, so after `CLIENT REPLY OFF` a malformed request was answered,
where Redis answers nothing: its check of the mode is in the path every reply takes
(`prepareClientToWrite`). Nor does Redis close the connection then: a protocol error marks
it to close once its last reply is written, and there is none to write, while
`processInputBuffer` reads nothing more from a connection so marked; the connection stays
open, counted in INFO, until the client closes it (a second connection asking INFO, and a
SET sent after the error that never runs, show it on Redis 7.0.15). The loop now holds
the error back under OFF, and under SKIP for the request the error is in, as `say` holds
a reply back (the error is still counted, as Redis counts it), and then reads and drops
what comes until the client closes, when the connection ends as any other (`conn_drop`,
then `conn_end`). Six cases in `tests/protocol_test.py` (the error after OFF, after SKIP,
after a reply SKIP held back, in a later read, the requests after it, and after OFF and
ON again), and a seventh way to end in `tests/conn_test.py`. QUIT under CLIENT REPLY OFF,
after which Redis also leaves the connection open and unread, still closes it here, as
`tests/session_test.py` notes.

**Cost.** Instructions per request (callgrind, `tools/perf_guard.sh`): GET, SET and INCR
3,257, 4,176 and 4,431, against 3,296, 4,287 and 4,477 before these five changes: a bulk
no longer reads the two bytes after its data, which pays for the comparison a length line
of two digits or more now makes.
