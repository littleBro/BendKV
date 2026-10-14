# Why BendKV is slower than Redis, and what was fixed in Bend and in BendKV

A summary is in [FINDINGS.md](FINDINGS.md); the scripts behind the
numbers are in [tools/](../tools/README.md).

## In short

1. **The gap came mostly from the memory model of the Bend runtime, not from
   verification and not from the logic of the commands.** The original SET cost ~390
   heap cell allocations and ~150 atomic reference-count operations. Redis makes a
   handful of allocations per SET.
2. **Bend itself is fixed by thirty-one patches to the compiler**
   ([`bend-patches/`](../bend-patches/)). The first eight switch on by themselves for
   programs without GPU calls `!`, the ninth and tenth where a program calls them, the
   eleventh changes every program's event loop on Linux, the twelfth and thirteenth only
   add effects, the fourteenth speeds up `String.code_at` everywhere, the fifteenth and
   sixteenth act where a program calls `TCP.post`, the seventeenth adds string functions,
   the eighteenth changes how every program's `IO` compiles, the nineteenth speeds up
   `Mem.prefetch` of buffers and `String.take` of short strings, the twenty-first lays out
   a type wider than 32 words as a node of its own (section 16), the twenty-second makes
   `String.order` native (section 39), the twenty-third keeps a socket with no room from
   holding up the `TCP.post` writer (section 40), the twenty-sixth fixes the fifth
   (section 41), and the thirty-first has a walker that reads a tree borrow it from a
   caller that owns it (section 51). Seven more only add effects: the twentieth, the
   process and the clock for starting as `redis-server` does; the twenty-fourth, cutting a
   file of any size and syncing a directory (`File.sync_dir`); the twenty-fifth, waiting
   for a socket on a channel (`TCP.watch`, section 41); the twenty-seventh, a socket's
   addresses, killing it and channel marks (section 44); the twenty-eighth, a file put in
   another's place and a name removed (section 47); the twenty-ninth, the heap's account
   (`IO.heap`); the thirtieth, words outside the heap (`Mem.touch`, `Mem.cell`; both
   section 48). Before section 14 there were twenty patches: the sixteenth (effect pairs)
   was taken out in section 14, and the sections before 14 number the patches the old way
   — there, 17–20 are today's 16–19.
   - **Lazy sealing** (section 3): a reference count is created when a value is
     actually shared, not at every construction.
   - **Packed strings** (section 4): in the C runtime a `String` is a chain of byte
     buffers, not a list of 16-byte cells, one per character, plus network I/O straight
     in buffers (`TCP.recv_raw`/`TCP.send_raw`). The theory does not change: `String` is
     still a list of `SCon`/`SNil`, so all the proofs stay valid.
   - **Borrowed reads** (section 5): a field read from a lent value and passed on as
     owned is kept in place (`slot_keep`) instead of making the whole value owned. A
     read from a persistent structure that is kept costs O(1) reference-count operations
     instead of O(depth), without hand-written workaround functions.
   - **Native string operations** (section 6): `++`, `String.length`, `eq`, `take`,
     `drop`, `hash` and `Nat.show` go a chunk at a time (`memcpy`, `memcmp`), not a
     character at a time. The new `String.code_at`, `find` and `slice` read a string by
     index. A literal or `Nat.show` before `++` is written straight into the chunk's
     spare room, and a comparison with a literal is one `memcmp`. A string of up to 6
     bytes is stored right in the term word, with no node and no buffer (section 7.8).
     Reading operations only borrow the string.
   - **A node is rebuilt in place** (section 7.9): a node the function owns and has
     taken apart stays the same block; across a non-tail call the pointer to it is kept,
     not its fields, and the rebuild writes only the fields that changed.
   - **2 MiB pages for the heap** (section 7.10): `madvise(MADV_HUGEPAGE)` on the
     runtime's corpus, so that random reads over a large heap miss the TLB less often.
   - **Field selection by digit** (section 7.11): a match on an enumeration whose arms
     each take a different field of one node is one arm, which reads the field by number
     and writes the slot by number, with one continuation. The descent through the trie
     goes without an unpredictable indirect jump at each level.
   - **A string of one chunk is the buffer itself** (section 7.13): such a string has no
     node; its term is the buffer's term. A key comparison costs one miss, not two, and
     each key takes one allocation and 16 bytes less.
   - **A hint to the processor** (section 7.14): `Mem.prefetch(A, x, k)` equals `k`, and
     on the C lane it also starts loading the node of `x` into the cache. Before each
     batch BendKV walks the paths of all its keys level by level, and the misses of
     different keys overlap.
   - **Several cores** (section 7.16): event loops on threads of their own
     (`IO.spawn_on`), sending to several channels in one step (`Chan.send_all`), sending
     over TCP through a writer thread (`TCP.post`), `recv`/`send` buffers per thread.
   - **`epoll`** (section 7.17): the event loop waits for sockets edge-triggered and
     spends no `recv` on `EAGAIN`; accepted connections get `TCP_NODELAY`
     (`TCP.post_list`, a post of chunks as one buffer for the shards' replies, was taken
     out with the shards in section 14).
   - **Files as bytes, `fsync`, and taking from a channel without waiting** (section 7.19):
     `File.write_raw`/`read_raw`, `File.sync`, `File.truncate` and `Chan.drain`, for an
     append-only file with group commit.
   - **The loop shares sends with the writer** (section 7.23): the event loop itself
     sends what is posted to the writer while it is less busy than the writer or the
     writer sleeps; `String.code_at` of a short string in the term reads the byte from
     the term itself. (The effect pairs `Chan.call` and `TCP.post_recv_raw` of the same
     section were taken out in section 14.)
   - **Whoever keeps up sends; a string is read in place; `IO` in continuations**
     (section 7.24): while the loop keeps up with its sockets (fewer than four ready per
     wait), it sends itself, and when it falls behind it hands the sends to the writer;
     `String.dec_line_at`, `hash_at` and `dec_at` read a string by index without a
     slice; a definition whose type ends in `IO` takes its continuation as a parameter,
     and a `do` block calls effects directly, without `IO.bind` closures.
   - **A hint that reaches a buffer's bytes** (section 7.25): `Mem.prefetch` of a buffer
     loads its bytes to the end (up to four cache lines), not the first 64 bytes;
     `String.take` of a string in the term word at its whole length gives back the word
     itself.
   - **A native `String.order`** (section 39): two strings are compared a chunk at a
     time through `memcmp`, not a character at a time; ZRANK of a member among equal
     scores takes 8.5 times fewer instructions.
   - **A socket with no room holds up only its own posts** (section 40): the writer does
     not wait for a socket that takes no bytes, but holds them in order and sends them
     once the socket has room; the queue of posts grows by blocks, and the loop never
     waits for the writer.
3. **BendKV is reworked** (section 7). A key read does not share the database, and it
   is an ordinary `get`: the hand-written `find` with a copy of the value is not needed
   after the third patch and is removed. Keys are compared and hashed natively; it is
   proved that `String.eq` is the same comparison character by character. The trie now
   has 16 children (section 7.6): 5 levels instead of 20, a bucket is a chain of entries
   in the trie itself, and a write rebuilds the path in place. The map's laws are
   reproved for it, and the 16-way and 256-way case splits are written by a script.
   Requests are parsed by index without sharing the buffer, replies are written from the
   end into one chunk, and a command is chosen by the length of its name (section 7.7);
   a request is parsed straight into a command with its key's hash for the hints
   (section 7.24). A batch runs after the hints to the processor (section 7.14), and the
   law `batch_hints` proves that they change nothing, for any hashes. All 33 laws check,
   including in the BendTT kernel. With a file (`./bendkv PORT post|send FILE`) the
   server keeps an append-only file in Redis's AOF format, and it is proved that after
   any history it restores from the file exactly the database it held, and from a file
   cut by a crash, the database after some prefix of its commands (section 7.19).
   Replies are sent by the writer thread. Shards across cores, with a proved equivalence
   to the single-threaded server (sections 7.16–7.18 and 7.21), and a key hashed once
   (7.22) were built, but taken out in section 14: they paid off weakly and cost two
   files of code and two fifths of the proofs.
4. **The result** (sections 6, 7.6–7.14 and 10):
   - allocations per SET 392 → 62, per GET 305 → 35 (before native strings);
   - instructions per GET 11,994 → 3,280 (Redis: 3,549), per SET 15,137 → 3,985
     (4,773), per PING 2,172 (2,438); per INCR on existing counters 4,209 (3,948). The
     hints to the processor (7.14) add 14–17%: GET 3,834, SET 4,544, INCR 4,785;
   - by Redis's own benchmarks (the specs of `redis-benchmarks-specification` and
     `memtier_benchmark`, section 7.15): loading a million keys with 100-byte values at
     1.39 of Redis, GET with pipeline 10 at 1.26, with pipeline 100 at 1.36, INCR at
     1.00, GET without pipelining at 0.90 (the server on one core);
   - with sending on a second core (section 7.16, the server on two cores): loading at
     **1.94** of Redis, GET with pipeline 10 at **1.61**, with pipeline 100 at 1.39,
     INCR at 1.27, GET without pipelining at 1.11 (1.19 with two shards). Redis with
     `io-threads 2` on the same cores gives 0.99–1.22 of its single-threaded self;
   - with `epoll` (section 7.17, the same two cores): GET without pipelining at **1.27**
     of Redis (it was 1.15 with `select` in the same series), loading at 1.98–2.07, GET
     with pipeline 10 at 1.72–1.78. On three server cores GET with pipeline 10 gives 897
     thousand ops/s against 436 thousand for Redis with three io-threads;
   - at pipeline 16 on a filled database of 100 thousand keys (`redis-benchmark`, the
     best case for BendKV) BendKV is faster than Redis:
     **GET 1.62, SET 1.82, INCR 1.45** of its throughput (0.08–0.14 on the original
     Bend). On a million keys, **1.65, 1.80 and 1.17** (section 7.14). Without the hints
     it was 1.17–1.21, 1.10–1.15 and 0.95–0.96 at 100 thousand keys and 1.02–1.14,
     1.06–1.24 and 1.04–1.12 at a million (from series on two days on different VMs). At
     a thousand keys, where everything is in the cache anyway, 1.09, 1.13 and 0.95;
   - without pipelining BendKV is not slower than Redis (1.18–1.32 of it); at pipeline
     16 on an empty database (`make bench`), 0.98–1.23 on PING, GET and SET and 0.65 on
     INCR;
   - after the five steps of breakdown 9.7 (section 7.23; four went in, and the hints
     over the whole group were taken out after measurement) there are 8–9% fewer
     instructions per request at pipeline 16, 19% fewer without a pipeline and 44–54%
     fewer at pipeline 100; by Redis's specs on two cores: loading at **1.93** of Redis,
     GET with pipeline 10 at 1.46, without pipelining at **1.37**, with pipeline 100 at
     **1.69**, INCR at 1.43 (in the same series before the steps: 1.73, 1.43, 1.23, 1.35
     and 1.39);
   - after 7.24 there are another 10–14% fewer instructions per request (GET 2,969, SET
     3,534, INCR 3,830 at pipeline 16; GET 7,820 without a pipeline, counting the
     writer); without pipelining under `redis-benchmark` with one client thread BendKV is
     at 0.93–1.05 of Redis on GET and 0.90–0.98 on SET (it was ~0.80); by Redis's specs
     on two cores: loading at **2.25** of Redis, GET with pipeline 10 at 1.62, without
     pipelining at 1.37, with pipeline 100 at **1.95**, INCR at 1.39;
   - memory for ~950 thousand keys 513 → 60 MB, Redis 121 MB (section 7.13), with
     3-byte values; with 100 bytes on a million keys, 183 MB against 211 (section 13),
     and since section 7.25 reads do not add to it;
   - SET of a 1 MB value takes 4.4 ms, GET 1.4 ms (it was ~16 ms; Redis: ~1 ms).
5. **Where a gap remains** (sections 7.13–7.16 and 9.5). On one core without
   pipelining BendKV is slower than Redis: GET at 0.90, as the path of a single command
   through the connection, the channel and the database actor costs more than Redis's.
   With a second core for sending it is faster there too (1.11). INCR on a small
   database is at 0.95 at a thousand keys: INCR walks the path in the trie a second
   time, and the hints there are pure overhead. Shards on two cores lost to one loop with
   a writer: terms that pass between cores cost more than parallel work on the map gives
   (7.16); in section 14 they were taken out. A fresh breakdown (9.7): with a pipeline,
   when everything is in the cache, BendKV and Redis spend the same per request, and at
   100 thousand keys the hints hide memory entirely, so BendKV's user time is almost all
   instructions, and 41–45% of them are RESP parsing; reads longer than 2 KiB the parser
   read by the slow path. The kernel costs both the same, 42–46% of BendKV's CPU at
   pipeline 16 and 66–80% without it. Four steps of the plan from this breakdown are
   done (7.23): RESP parsing is now a third of GET's instructions, long reads are parsed
   in windows, the loop shares sends with the writer, and effects go in pairs. The gap
   without pipelining under `redis-benchmark` is closed (7.24): the loop sends itself
   while it keeps up. Parsing straight into a command and `IO` in continuations cut
   another 12–14% of instructions, but in time this is less than the noise: the kernel
   is now about half of a request's CPU with a pipeline and two thirds without one, as
   for Redis. The plan is in section 11.
6. **The processor and the compiler** (section 9.6). Vector extensions give nothing:
   `-march=x86-64-v3` removes 0.3–1.8% of instructions, and in time neither it nor
   `-march=native` wins. PGO removes 19–24% of instructions and gives +5…+8%. Waiting
   for memory cost the most: 56–68% of the user time per request, as much as for Redis.
   The batch hints (7.14), as in Valkey 8, hide ~85% of it at 100 thousand keys and
   ~70% at a million.
7. **The cost.** On the runtime's `lexer` benchmark packed strings are 1.3 times slower
   than lists on one thread and 1.7 times on four. This is their worst case: short
   strings are built and taken apart a character at a time. The other 16 runtime
   benchmarks did not change (geometric mean ×0.99). Borrowed reads and selection by
   digit do not change the generated code of any of the 17 runtime benchmarks. 2 MiB
   pages give them ×0.99 on average (from 0.88 to 1.07), but a short program starts
   ~0.4 ms later, and programs with heaps of hundreds of megabytes spend 0.4–0.9 s more
   in the kernel (section 7.10). A directory array instead of the top of the trie was
   not built: it needs a proved theory of `Array` and moving the whole database to an
   affine type (section 7.5). To upstream the patches, they will have to be made
   smaller: with them `comp.ts` exceeds the size cap of the Bend repository (section
   11).
8. **Why strings in Bend are lists:** that is how the theory is built (section 8). The
   kernel has only inductive types, and speed is brought back by "native views" in the
   runtime. For `String` such a view existed only in the JS backend; the second patch
   adds it in C.
9. **What cost what** (section 12). Gains of several times at a small cost came from
   the changes that remove a whole class of work with memory or the disk: lazy sealing,
   the 16-way trie, the batch hints, group commit of the append-only file; in `comp.ts`
   they cost 0.7 thousand tokens of the 38.2 thousand the patches added. Strings are
   almost half of that growth and the main contribution to the speed of one core. From
   7.22 on, cutting instructions almost stopped saving time, and the worst payoffs were
   the key hashed once (7.22) and the shards on two or three cores — they are what was
   taken out in section 14.
10. **An outside review** (section 13) found three bugs: an unreadable append-only file
   gave an empty database, the background `fsync` with `everysec` was not checked, and
   the robustness test did not return an error. All three are fixed, and there is a
   test for disk failures. On an i9 BendKV is at 1.20–1.49 of Redis on one core. The
   halving of memory holds only for short values: with 100 bytes BendKV is at 0.87 of
   Redis. And on a GET of values longer than 6 bytes the batch hints did not reach the
   value's bytes, and copying the reply waited for memory. Of the three items the review
   added to the plan, one went in (section 7.25): GET answers with a copy of the value
   made at the read, the value is not sealed, and the hints reach its bytes: +2% in
   time, −2…4% of user CPU, and memory does not grow from reads. A fourth hint pass
   through the cell and part of the hash in the bucket entry were measured and not
   taken: they gave no gain beyond the noise, and their cost is noticeable.
11. **Rolling back what did not pay** (section 14). Shards, the key hashed once and
   effect pairs were taken out, and `TCP.post_list` in the runtime too: 38% less code
   and proofs, 33 laws instead of 45, 19 patches. The speed is the same within ±3%,
   except GET without pipelining (−3%) and GET of short values with pipeline 100 (−5%,
   at the edge of the budget): that was the contribution of the sixteenth patch, now
   removed.

Measurement conditions: a Linux VM with 4 cores (Xeon at 2.1 GHz, 2 MB of L2 per
core), clang 18 (clang 19 from section 6 on), Redis 7.0.15, `redis-benchmark` (20
clients, 100 thousand requests, keys from a space of 100 thousand), medians of three
runs on fresh processes. The noise between runs is ±10–15%.

## 1. How Bend stores data

- **A term** is a 64-bit word: a tag, a constructor number, an address. A heap cell has
  no header, and its size is rounded up to a power of two words. A constructor with two
  fields takes 16 bytes, with three, 32.
- **A string** is a list of characters `SCon{Char, String}`, that is, 16 bytes for each
  byte. The key `key:000000012345` (16 bytes) is 16 cells and 256 bytes, plus 15 more
  counter cells of 8 bytes each if the string is "sealed". In Redis such a key takes
  ~20–30 bytes. (That is how a string is built in theory and without the second patch;
  with it the C runtime stores it as buffers, section 4.)
- **Shared ownership** (`+x`) is implemented by a reference count that lies not in the
  object but in a separate 8-byte redirect cell; a pointer with the RFC bit points to
  it. An unshared value has no count at all — a deliberate choice of the authors (the
  BendRT paper, section "Ownership at Run Time").
- **"Hot" types.** Share inference works at the level of a *type* and for the whole
  program at once. If even one variable of type T is used twice somewhere, T becomes
  hot. Then *every* constructor of T, at *every* construction, allocates a counter cell
  for each pointer field, so that the value can later be shared in O(1). The paper says:
  "Only hot types pay any of this, and they seal every stored field with a count at
  build time". In BendKV the hot types turn out to be `String`, `List`, `Trie`,
  `Bucket`, `Maybe` — almost all the server's data. A typical server shares at least
  one key, and that is enough to make the whole `String` type hot.
- **Taking a shared node** (`ctr_take`) atomically increments the counts of all its
  fields. **Freeing** (`term_drop`) walks and frees every cell and every counter cell,
  with an atomic decrement.
- **I/O.** `TCP.recv_bytes` returns a `List<U32>`, one cell for each byte received. A
  reply goes out through the same kind of list.

## 2. Measurements on the original Bend

### 2.1. Allocations per request

The server is built with counters inside the runtime; pipeline 16, 100 thousand
requests.

| request | allocations | of them counter cells (8 B) | 16 B cells (bytes, lists) | 32 B cells (trie nodes) | atomic RC operations |
|---|---:|---:|---:|---:|---:|
| PING | 130 | 79 | 49 | 1 | 44 |
| SET | 392 | 252 | 116 | 24 | 146 |
| GET | 305 | 196 | 108 | 1 | 209 |
| INCR | 421 | 262 | 134 | 25 | 209 |

For comparison: Redis makes about 2–4 allocations per SET (the value, the dictionary
entry, the key) and touches no atomic counters.

### 2.2. Profile (callgrind, SET with random keys)

| what | share of instructions |
|---|---:|
| `term_drop` (freeing cells) | 25% |
| `rfc_wrap` (creating counter cells) | 19.5% |
| other memory management (`span_fade`, allocator misses) | ~6% |
| list strings: reversals, byte conversion | ~20% |
| the trie (`tmod`, `mk`, the path by bits) | ~11% |
| RESP parsing | ~5% |

`rfc_wrap` is called ~230 times per SET. By the call tree, almost all the calls are
sealing at construction: the list of bytes from the socket, string reversals, the path by
the hash's bits, new trie nodes. Real sharings among them are a handful.

### 2.3. Why it is cheaper in Redis

- Strings are contiguous buffers (sds). A request is parsed with pointers right into
  the receive buffer, and replies are appended to the client's shared buffer.
- A hash table: a lookup is 1–2 memory accesses. In BendKV's binary trie it is 20
  dependent pointer hops, that is, up to 20 cache misses.
- Update in place. In BendKV the structure is persistent: SET copies the path in the
  trie.
- There are no reference counts on the hot path; jemalloc gives good locality.

### 2.4. Fragmentation

Bend's allocator keeps freed cells in LIFO lists by size class. After a large structure
is freed (FLUSHALL of a database of ~1 million keys), these lists are shuffled across
addresses, and new structures lose locality. In the same process throughput falls 2–3
times, and operations on large values 6–10 times.

## 3. A fix in Bend itself: lazy sealing

### The idea

Do not allocate counter cells at construction. A field is sealed at the moment a
co-owner of a shared node first takes that node:
- the field gets a count of 2: one reference from the node, the other held by the
  taker;
- the count is set atomically through a CAS, because another co-owner may be sealing
  the same field at the same time. The loser frees its cell and increments the winner's
  count;
- a field already sealed never changes again, so `ctr_take` rereads the fields after
  sealing and only then lets go of the node;
- the last owner rereads the fields after an acquire.

A value that was never shared (bytes received, temporary strings, a path in the trie,
fresh nodes) pays nothing. A shared value pays only for the fields actually touched.

### Why this way

- **The variant "seal the whole subgraph at the first sharing"** needs no CAS: while a
  value is not shared it has one owner, and writing into it is safe. But it gives
  pauses: the first GET after loading ~950 thousand keys sealed the whole database in
  **475 ms**. The variant "one field at a time on taking" gives no pause (the first GET
  takes 0.17 ms) at the same throughput.
- **The first version of the patch slowed `lexer` by 40%,** although there is no
  sharing there at all. The cause was in code generation: the address of the field
  array escaped into an out-of-line function, and clang stopped keeping the fields in
  registers in all the inlined `ctr_take` calls. In the final version `span_fade` seals
  the fields right in the node, and `ctr_take` rereads them itself — the regression
  went away.

### The limitation

A 64-bit CAS exists on the CPU and in CUDA, but not on all Apple GPUs (Metal). So the
patch turns on the lazy mode only for programs without `!` (`#define SEAL_LAZY`), and
GPU programs behave as before.

### Checking correctness

- **Bend's tests.** A local counterpart of `gates/test.ts` (the C lane): each runnable
  test is built into a native binary, run with a timeout of 5 s, and its output is
  checked against the `#|` lines. Of 843 tests, 127 do not run in C (an unprintable
  `main`; the gate only checks them too). Of the other 716, the patched compiler passes
  712 — as many as the original on an idle machine. No test that passes with the
  original fails with the patch. The remaining 4 fail with both because of the
  environment: 3 lack ALSA's headers, 1 depends on the order of stdout/stderr when the
  output is captured. Two more tests depend on timing (`io_stack_fault_trap`,
  `io_tcp_send_slow_peer`): under load they failed with the original compiler too, and
  on an idle machine they pass with both.
- **The Bend runtime's benchmarks.** 17 programs ran in multithreaded CPU mode (`!`
  removed, calls run in parallel on threads). This is also a check of concurrent
  sealing: all the checksums matched the reference ones.
- **BendKV.** The robustness tests and the differential test against Redis: ~25
  thousand commands on the final version of the patch and ~44 thousand on intermediate
  ones, with no differences.

### Results

**Allocations per request:**

| request | original Bend | Bend + lazy sealing |
|---|---:|---:|
| PING | 130 | 66 |
| SET | 392 | 187 |
| GET | 305 | 153 |
| INCR | 421 | 229 |

**BendKV's throughput, pipeline 16 (ops/s):**

| | PING | SET | GET | INCR |
|---|---:|---:|---:|---:|
| Redis 7.0.15 | 1,428,571 | 884,956 | 847,458 | 813,008 |
| BendKV, original Bend | 510,204 | 112,486 | 86,505 | 93,023 |
| BendKV, Bend + patch | 609,756 (+20%) | 172,117 (+53%) | 129,870 (+50%) | 132,626 (+43%) |

**Without pipelining (ops/s; here the numbers are bound by network latency):**

| | PING | SET | GET | INCR |
|---|---:|---:|---:|---:|
| Redis 7.0.15 | 80,906 | 99,108 | 104,493 | 101,626 |
| BendKV, original Bend | 111,857 | 61,387 | 60,753 | 56,689 |
| BendKV, Bend + patch | 108,108 | 74,627 (+22%) | 65,876 (+8%) | 62,112 (+10%) |

**Loading ~950 thousand keys (pipeline 64):**

| | loading, ops/s | RSS memory | first GET after loading |
|---|---:|---:|---:|
| original Bend | 40,428 | 513 MB | 0.19 ms |
| Bend + patch | 82,073 (×2.0) | 370 MB (−28%) | 0.17 ms |
| Redis | 872,346 | 113 MB | — |

**The Bend runtime's benchmarks** (CPU, 4 threads): geometric mean ×0.99, from ×0.93
(histogram) to ×1.09 (terrain). This is within the noise, or slightly worse on programs
that read a lot of shared data. The gain goes to programs that build many short-lived
values of hot types — that is, to servers and parsers.


## 4. A fix in Bend itself: packed strings

The patch [`bend-patches/packed-strings.patch`](../bend-patches/packed-strings.patch)
applies on top of lazy sealing: `bend2/comp.ts` +334/−12 lines, `base.bend` and the TCP
effects, a new test `tests/io/tcp_raw.bend`.

### The idea

The theory does not change: `String` is still `SNil | SCon{Char, String}`, and the
proofs about strings stay valid. Only the representation in the C runtime changes —
just as `U32` is a vector of bits in theory and a machine word in the runtime.

- **A string is a chain of links.** A link is `SNil`, an ordinary `SCon` cell
  [character, tail] or a *chunk* [buffer, continuation].
- **A chunk.** The bytes `buf[pos..cap)` are the string's first characters, and the
  continuation comes after them. The buffer is an ordinary `BUF` block: the size class
  in bits 0–4 of the aux field, `pos` in bits 5–15. So a chunk is at most 2 KB, and the
  common `term_drop` frees the buffer like any `BUF`. A chunk's node is 16 bytes. The
  key `key:000000012345` now takes 16 B of node + 16 B of buffer = 32 B instead of 256 B
  (and up to 120 B more of counter cells).
- **`SCon{c, s}`** (`str_cons`). If `s` is a chunk with a sole owner and there is room
  before `pos`, the byte is written in place and `pos` decreases. Otherwise a new chunk
  is started before `s`; if `s` is a full chunk, the new one is twice as large (up to
  2 KB). A character ≥ 256 becomes an ordinary cell.
- **`match` on an owned string** (`str_take`). The sole owner moves `pos` in place. A
  co-owner takes the chunk as an ordinary shared node and makes its own node on the same
  buffer. The buffer is sealed lazily, like a field: `span_fade` now handles `BUF` too.
- **`match` on a lent string.** "Views" are used: the word `pos << 40 | chunk address`
  with tag 0. Such a word is trivial — it is neither counted nor freed — so a read
  allocates nothing. A view lives only inside a borrow: the ownership analysis already
  guarantees that a lent value does not escape.
- **What stays as cells:** literals in the program image and characters ≥ 256. Chains
  mix freely. The end of a buffer coincides with the end of its block, so no end marker
  is needed.
- **I/O.** `io_str` (UTF-8 → String) builds whole chunks, and ASCII is copied with
  `memcpy`; `io_cbuf` emits whole chunks. The new effects `TCP.recv_raw` and
  `TCP.send_raw` carry bytes as they are, one `Char` 0..255 per byte in a `String`. This
  is the same as `recv_bytes` and `send_bytes`, but without a cell per byte. There are
  twins for C and JS.
- **The mode switches on only for programs without `!`**, like lazy sealing. GPU code
  would need an implementation of its own (Metal has no 64-bit CAS), so programs with
  `!` compile as before.

### Checks

- **Bend's tests** (the C lane, `tools/c_lane_tests.py`): 713 of 844 pass. These are
  exactly the same tests as with the original compiler and with lazy sealing, plus the
  new `io_tcp_raw`. No differences.
- **String stress tests:**
  - strings longer than 2 KB (several chunks);
  - characters ≥ 256 mixed with bytes;
  - shared strings that parallel tasks take apart at the same time: 32 runs on 2–8
    threads.

  The answers match the original Bend, the JS backend and the interpreter. The counters
  confirmed that all the paths work: the move in place, taking by a co-owner, new
  chunks, views.
- **BendKV:** the robustness test and the differential test against Redis (5 runs,
  ~29 thousand commands), with no differences.

### The cost

- **17 runtime benchmarks** (CPU, 4 threads, runs interleaved with lazy sealing): 16
  did not change, geometric mean ×0.99, spread from ×0.91 to ×1.08. **`lexer` is 1.69
  times slower** (1.3 times on one thread).
- **Why `lexer`.** It builds a string of ~60 characters one character at a time and at
  once takes it apart a character at a time. A list is almost ideal here: a cell is
  taken from a hot LIFO free list and goes back to it. A chunk, for each character, has
  to decode the position and the class from the word and check the bounds. By the
  profile this is ~165 million instructions against ~124 million for 2^14 strings.
- **How to remove it:** keep a ready byte cursor in the chunk's node (the node would
  become 32 bytes) and make `String.append`/`reverse`/`length` native in C. Now these
  are Bend loops over characters.

## 5. A fix in Bend itself: borrowed reads

The patch [`bend-patches/borrow-reads.patch`](../bend-patches/borrow-reads.patch)
applies on top of packed strings: `bend2/comp.ts` +168/−22 lines, a new test
`tests/rfc/borrow_field.bend` and updated comments in three borrow witness tests
(`tests/reg/brw_*`), which described the old rule.

### The problem

The Bend compiler decides by itself whether a function owns a parameter or only borrows
it. If the parameter is only read, ownership stays with the caller, and nodes are read
without counts (`term_peek`). But as soon as a function returned a *part* of a lent
value (a node's field), put it into a new node or passed it to an owning parameter, the
analysis made the whole parameter owned. A caller that still needed the value had to
share it (`term_keep`). Then each level of the descent takes a shared node (`ctr_take`
→ `span_fade`): it raises the counts of all its fields, and with lazy sealing also
allocates counter cells. A read from a persistent structure of depth d cost O(d) atomic
operations and allocations instead of O(1). That is why BendKV needed the hand-written
`find`, which answers with a copy of the value (section 7.3).

### The idea

A field that passes into ownership is kept in place: `slot_keep(e, field address)`. It
seals the field in the parent node just as `span_fade` does with lazy sealing: a
redirect with a count of 2, one reference stays with the node, the other goes to the
reader. It is set through a CAS, because other readers may race for the same slot. If
the field is already sealed, `slot_keep` only increments the count. The parameter stays
borrowed, the nodes on the path are read without counts, and a read from the structure
costs O(1) reference-count operations at any depth.

### How it works in the compiler

- **The field key.** Each read of a field from a lent node gets a key, the path from
  the parameter, for example `f~3:0/Node#1.0`: parameter 3 of function `f`, constructor
  `Node`, the second read of this path in the function, word 0. The key is determined
  by the structure of the code, so it is the same on all passes of the analysis.
- **An escape in the same segment.** If the field passes into ownership in the same
  code segment where it is read, `slot_keep` is placed right at the point of escape.
  The other paths have not a single extra operation.
- **An escape after a call.** In the continuation segment the slot's address is gone.
  Then the key is recorded in the `keeps` facts, and on the next pass of the analysis
  the field is read through `slot_keep` at once and counts as owned from then on. The
  same goes for a merge of branches and a capture by a closure.
- **Heating.** The type of a kept field becomes "hot": its nodes may now be shared. But
  heating applies only on the pass where the ownership facts have settled. Otherwise
  the early, optimistic passes would leave hot the types of parameters that in the end
  became owned anyway.
- **Limits.** Only fields of Data types: they hold no closures, arrays or files, which
  cannot be shared. Only programs without `!`, like lazy sealing: on the GPU nodes are
  sealed at construction.

### Checks

- **Bend's tests** (the C lane): 714 of 845 pass — the same tests as with the first two
  patches, plus the new `rfc_borrow_field`. No differences.
- **What changed in the code.** Of the 717 tests that build, the generated code
  changed in 7, everywhere as expected: a function that returns or stores a field of a
  lent value (like `head`, `tail` or a walk with an accumulator) no longer makes the
  caller share the whole value. The `term_keep` is gone, and one `slot_keep` stands in
  its place. In two tests a type that was hot only because of that `term_keep` is cold
  again, and other functions take its nodes by the cheap path. In the 17 runtime
  benchmarks the code did not change in any.
- **The new test** `tests/rfc/borrow_field.bend` gathers all the paths: a field
  returned from a walk, an escape after a call, a merge of `Maybe` branches, a capture
  by a closure and 4,096 parallel readers of one field (a race for the CAS). The tree
  is used after each read too, so a lost count or a double free would give a wrong sum
  or a runtime error.
- **BendKV:** the proofs (and `--verdict`), the robustness test, the differential test
  against Redis (3 seeds, ~17 thousand commands), with no differences.

### Results

**Reads from a trie that is needed after them too:** a trie of 200 thousand keys,
2 × 200 thousand reads. Medians of 7 interleaved runs; the filling (0.375 s) is
subtracted from the total time.

| read | compiler | time of the reads | allocations per read | atomic RC operations per read |
|---|---|---:|---:|---:|
| `get` (walk + `bget`) | without the third patch | 0.89 s | 8.0 | 87 |
| `get` (walk + `bget`) | with the third patch | 0.63 s | 6.2 | 9.0 |
| `get` (`tget_k`, BendKV now) | with the third patch | 0.56 s | 5.2 | 4.3 |
| `find` with a copy (BendKV before) | without the third patch | 0.58 s | 4.0 | ~0 |

The ordinary `get` with the patch caught up with the hand-written `find`, but copies
nothing.

**The server, per request (pipeline 16):**

| | GET: allocations | GET: atomic RC operations | INCR: allocations | INCR: counter cells |
|---|---:|---:|---:|---:|
| `find` with a copy, without the third patch (before) | 34.9 | 5.9 | 68.1 | 1.8 |
| `get`, with the third patch (now) | 34.4 | 8.5 | 68.5 | 2.4 |
| `get`, without the third patch | 37.7 | 79.6 | 95.3 | 29.3 |

- **The throughput** of the server with `find` and with `get` is the same within the
  noise: medians of three interleaved runs at pipeline 16 — GET 305,810 and 326,797
  ops/s, INCR 238,663 and 220,751 ops/s (Redis in the same run: 704,225 and 602,410).
  The same speed used to come from the hand-written `find`; now the compiler gives it.
- **Large values.** GET of a 1 MB value: 17.6–20.4 ms instead of 25.3–25.5 ms with
  `find` (medians of 24 reads), because the value is no longer copied. SET did not
  change (~20 ms).
- **Where extra work remains.** In `bget` the value outlives the call to `str_eq`, so
  it is kept at the read (through a `keeps` fact), not at the point of escape. If the
  entry's key did not match, that is a couple of extra reference-count operations per
  bucket entry. Buckets are short, and this does not show in the measurements.

## 6. A fix in Bend itself: native string operations

The patch [`bend-patches/string-natives.patch`](../bend-patches/string-natives.patch)
applies on top of the previous three: `bend2/comp.ts` +428/−6 lines (~340 of them C
runtime functions), `bend2/base.bend` +11 (the new definition of `String.hash`).

### The problem

Packed strings store bytes in chunks, but the operations on `String` from Base (`++`,
`String.length`, `String.eq`, `String.take`/`drop`, `Nat.show`) are defined by
recursion on `SCon`/`SNil`, and the C runtime ran them a character at a time. Each step
took a character off a view (`str_take`), compared it and put it into a new chain
(`str_cons`). A key of 16 characters was compared in 16 calls with a continuation, a
GET's reply was built by four `++` a character at a time, and a 1 MB value was copied in
a million steps: SET and GET of such a value cost ~16 ms against ~1 ms in Redis.

### The idea

`U32.add` or `Nat.mul` compile to machine operations. In the same way the known
definitions of Base on strings now compile to calls of runtime functions that work a
chunk at a time:

| operation | what the runtime does |
|---|---|
| `String.append` (`++`) | if the left string is not shared, its last node is relinked to the right one, without copying; if the right one is an unshared chunk with room before its start, the left one is written into that room; otherwise a `memcpy` copy |
| `String.length`, `String.eq`, `String.hash` | a pass over the chunks: a sum of lengths, `memcmp`, FNV-1a |
| `String.take` | a copy of the first n bytes |
| `String.drop` | a shift of the view inside the chunk, without copying |
| `String.to_upper` | in place if the string is not shared, otherwise a copy |
| `Nat.show` | digits straight into a chunk |

- **The theory does not change.** The proofs see the reference definitions in Bend, as
  for `U32`, `Nat` and `Array`. A native function in C must behave as the definition
  does — this is part of the trusted base, as the earlier natives are. `String.hash` is
  a new definition in Base: FNV-1a over character codes, written in Bend; in C the same
  algorithm goes a chunk at a time.
- **Reading without ownership.** The compiler knows that `length`, `eq`, `take` and
  `hash` only read the string (the `brw` flag in the table of operations). The caller
  need not share the string to use it after the call. If the argument is an expression,
  its value lives in a temporary variable and is freed after the call.
- **Only for packed strings.** The natives switch on where packing does: in CPU
  programs without `!`. The JS lane and programs with `!` run the old definitions.
- **Overflow as before.** `Nat.show` and `String.length` past the limit of the machine
  `Nat` (2^48) stop the program with a `Nat` error, as the reference definitions do (the
  test `io_nat_host_neg`).

### Checks

- **Bend's tests** (the C lane): 714 of 845, exactly the same as with three patches.
  All 710 tests that pass on the original Bend pass here too. The other 131 fail
  without the patches as well: printing functions and types is not supported on the C
  lane, ALSA's headers are missing, the order of stdout and stderr differs.
- **Leaks.** A loop of 300 thousand and of 3 million iterations of `++`, `take`, `eq`
  and `hash` on computed arguments keeps a constant RSS, ~10 MB.
- **BendKV:** the proofs (and `--verdict`), the robustness test, the differential test
  against Redis (3 seeds, ~17 thousand commands), with no differences.

### Results

Instructions per request (callgrind, pipeline 16, 100 thousand keys):

| | PING | GET | SET | INCR |
|---|---:|---:|---:|---:|
| Redis 7.0.15 | 2,490 | 3,521 | 5,574 | 4,246 |
| BendKV, three patches, clang 18 | 5,747 | 11,994 | 15,137 | 16,261 |
| BendKV, three patches, clang 19 | 5,127 | 11,159 | 14,054 | 14,983 |
| BendKV, + native strings, clang 19 | 4,625 | 6,999 | 10,463 | 9,753 |

- **clang 19.** The Bend runtime's segments are declared `preserve_none` and pass into
  each other by tail calls. clang 18 ignores this attribute, and each transfer saves and
  restores registers; clang 19 does not. That is −7–11% of instructions without a
  single edit. Bend takes `$CC`, then `clang`; BendKV's Makefile passes `CC=clang-19`.
- **Throughput** (medians of three interleaved runs, pipeline 16, ops/s):

  | | PING | SET | GET | INCR |
  |---|---:|---:|---:|---:|
  | Redis 7.0.15 | 1,176,471 | 666,667 | 900,901 | 952,381 |
  | BendKV, three patches | 1,190,476 | 403,226 | 359,712 | 274,725 |
  | BendKV, + native strings | 1,149,425 | 418,410 | 420,168 | 347,222 |

  GET +17%, INCR +26%. SET hardly changed: its time goes to the trie (section 9).
- **Large values** (medians of 10 SETs and 30 GETs of a 1 MB value):

  | | SET 1 MB | GET 1 MB |
  |---|---:|---:|
  | BendKV, three patches | 15.8 ms | 15.6 ms |
  | BendKV, + native strings | 4.4 ms | 1.4 ms |
  | Redis 7.0.15 | 1.1 ms | 1.0 ms |

### The second round: reading by index, and forms the compiler sees

The same patch was extended (now `bend2/comp.ts` +799/−7, `bend2/base.bend` +36,
`bend2/effs/tcp_recv.c` +28/−2 and the test `tests/base/string_index.bend`):

| what | how |
|---|---|
| `String.code_at(s, i)`, `String.find(s, c, i)`, `String.slice(s, i, n)` | new definitions in Base, in Bend. In C, a byte of a chunk, a `memchr` over a chunk and one copy. All three borrow the string |
| `"literal" ++ s` | the compiler knows the literal's bytes and writes them straight into the spare room of the chunk of `s` (`str_append_lit`) |
| `Nat.show(n) ++ s` | the digits straight into the spare room of the chunk of `s`, without an intermediate chunk (`nat_show_into`) |
| `String.eq(s, "literal")` | a comparison of one chunk with the literal's bytes (`str_eq_lit`), not a walk over the cells of a static string |
| copies of up to 16 bytes | two overlapping words instead of a call to `memcpy` (`str_mov`) |
| `String.to_upper` of an unshared chunk | in place, without a walk over the chain |
| `TCP.recv_raw` | the read buffer is reused. The old `malloc` and `free` of the maximum (64 KB) on every read made glibc give back and take again the top of the heap (`brk`) and fault its pages in anew |

The specializations are forms of expressions the compiler recognizes when it generates
C. It sees a literal also when it comes from a call that folds into a constant, for
example `crlf()`. The semantics does not change: in the proofs these are the same `++`
and `String.eq`.

- **Bend's tests** (the C lane): 714 of 845, exactly the same. The new test checks
  `code_at`, `find`, `slice` on a string of several chunks and the specialized forms on
  both lanes.
- **BendKV:** the proofs and `--verdict`, the robustness test, the differential test
  against Redis (11 seeds, ~85 thousand commands), with no differences.

What this gave together with the reworked parsing and replies in BendKV is in sections
7.7 and 10.

## 7. Changes in BendKV

### 7.1. I/O by buffers

`server.bend` reads and writes through `TCP.recv_raw`/`TCP.send_raw`: the data received
becomes a packed string at once, and a reply goes out as one buffer. The chunks read
pile up in a list and are glued without copying the last one (`glue`). The length of a
new chunk is counted only up to `need` (`count_upto`), not in full. The parser's fuel
is the constant 2^32−1: a request takes at least 4 bytes.

### 7.2. A path in the trie without a list

- **Before:** `path(k) = bits(20n, hash(k))`, a list of 20 `Bool`s for every
  operation. That is 20 cells, and for a hot `List` 20 counter cells more.
- **Now:** `tget_h` and `tmod_h` go by the bits of the hash itself. The current bit is
  computed in advance and passed as a parameter, because Bend does not pattern-match on
  a computed value.
- **The proofs of the map's laws were not rewritten.** It is proved that the new walks
  agree with the old ones (`tget_h_eq`, `tmod_h_eq`: induction on the depth, the step
  generalizes the bit). Each of the five laws starts with a rewrite by these lemmas,
  and then the old proof follows.
- **Later** (7.6) the trie became 16-way, and the walks go the same way, by the digits
  of the hash itself, each computed in advance and passed as a parameter.

### 7.3. Reads without sharing the database

- **The problem.** `get` returns a value that lies in the trie. So the original
  compiler assumed that the trie "escapes" into the result and that `get` must own it.
  But `exec(GET)` returns the database too, so the database had to be shared (`+d`).
  Then all 20 nodes of the path were taken as shared: ~80 atomic operations on every
  GET. INCR after such a read also sealed the whole path: ~30 counter cells.
- **The first solution, in BendKV.** `KV.find(t, k)` searched the same way but
  answered with a *copy* of the value, and `find(t, k) == get(String, t, k)` was proved.
  This worked, but got around the compiler's limitation at the cost of extra functions
  (`find`, `tfind`, `bfind`, `copy`), five lemmas and a copy of the value on every read
  (for a 1 MB value, a megabyte).
- **Now, in the compiler** (section 5). `get` itself only borrows the trie: the value
  found is kept in place. `find`, `copy` and the lemmas about them are deleted, and
  `exec` reads through `KV.get`. So that the bucket too is only borrowed, `get` searches
  for the key right at the end of the walk (`tget_k`). It is proved that
  `bget(k, tget_h(…)) == tget_k(…, k)` (`tget_k_eq`, the same induction on the depth),
  and `get_list` is rewritten by this lemma. The laws `get_after_set`, `get_missing`,
  `append_effect`, `setnx_*`, `incr_missing` and `frame` are back to their old form,
  without rewrites through `find`.
- **The effect** compared with `get` without the third patch: atomic operations per
  GET 80 → 8.5, counter cells per INCR 29 → 2.4. That is as much as `find` gave, but
  without a copy of the value (section 5).

### 7.4. The parser

`parse` still holds the buffer as `+s`, but this is no longer expensive. Sharing a
packed string is one counter cell and one 16-byte node per request. Before, every
character had to be sealed, hence the ~45 allocations. Now all the sharings together
give 1–2.5 counter cells per request. I did not rewrite the parser into two passes (a
completeness check, then parsing without sharing) for the sake of 2–3 allocations.

### 7.5. A directory array instead of the top of the trie: not needed

- **The database would become affine.** `Array` in Bend is a type of kind `Type`, and
  an array cannot be shared. Then all the reads in `exec` would have to thread the
  database through. And all the laws about commands are stated for
  `+db: KV.Trie<String>`: they would have to be restated or proved through refinement
  (an abstraction function "directory → trie"). That is a rework of most of
  `PROOF.bend`.
- **The laws of `Array.get/set` in Base are not proved.** Their definitions find the
  cell by `U32` arithmetic: they compare the index with half the size, subtract the
  half, mask with `n−1`. `U32` in theory is a vector of 32 bits, and Base has not a
  single lemma about comparison or subtraction.
- **The arithmetic can be avoided.** "A read at the same index after a write" is proved
  structurally: the write and the read make the same decisions at each level.
  "Different indices", by comparing the sequences of the walk's decisions, like paths in
  the trie (`path_eq`). This is a plan, not a finished proof.
- **What a directory of 2^16 would give:** SET would copy 4 nodes instead of 20 (−16
  allocations of 32 bytes), memory about −40 bytes per key. After 7.3 reads no longer
  pay for the trie's depth in reference counts, only in pointer hops.
- **In the end:** the 16-child trie (7.6) gave the same and more, and the database
  stayed a `Data` type.

### 7.6. A 16-child trie

**Why.** The profile (section 9) showed that the descent through a binary trie of
depth 20 gives 60% of the L2 misses on GET and 11 mispredicted branches. The top levels
lie in the cache, but the last 5–8 at 100 thousand keys no longer do, and each level is
a dependent pointer hop on a random bit of the hash.

**How it works.**
- **A `Node` holds 16 subtrees**: the path is 5 hex digits of the hash instead of 20
  bits. A digit is the type `Hex` of 16 constructors. The Bend runtime stores such an
  enumeration as a number, and the function "number → digit" (`hex.of`) is a chain of
  `Nat` comparisons that clang folds into the number itself. Choosing a child is one
  jump table per level.
- **A bucket is the trie itself**: a chain of `Ent{key, val, rest}` cells ending in
  `Tip`. There is no wrapper: the entry comes right after the last node.
- **The walk looks first at the node, then at the digit**: an empty subtree ends the
  walk at any digit.
- **A write rebuilds the path in place.** For this the compiler must own the node, not
  borrow it, and two details were needed. The comparison of the key with the bucket's
  first entry (`bhead`) is computed before the bucket is passed on. And the last arm of
  `bset`/`bdel` returns the end of the bucket, not a new `Tip`. Without this, after the
  third patch the compiler finds it cheaper to borrow the bucket, keep its fields
  (`slot_keep`) and build a copy. That is what happened in the first version: SET cost
  15,667 instructions instead of 8,477.
- **The strict `Bool.pick` in buckets is replaced by a match on a comparison computed
  in advance**: a read stops at the first entry for the key, and a write builds only
  one branch.
- **Empty nodes are not collapsed after deletions.** There are at most 69,905 of them
  (~9 MB) for 2^20 buckets. Collapsing would cost a check of 16 children at each level
  of a write and a rewrite in every step of the proofs. (Section 50 collapses them on
  deletes alone: a delete checks the 16 children of a node only where it emptied the
  child it walked through, and the proofs take it through one lemma, `tdel_eq`.)

**The proofs.** The map's laws are reproved for the new trie by induction on the depth
of the walk, without list paths.
- `tget_tmod_same`: a read of the bucket the walk writes to sees the write. That is 16
  cases per kind of node.
- `walk_same`: two walks with the same digits arrive at one bucket.
- `tget_tmod_other`: a read of another bucket does not see the write. For a node that
  is 256 combinations of digits, 240 of which reduce to computation. An empty subtree
  reduces to a node of empty children.
- The bucket lemmas are rewritten for the new `bget`, `bset` and `bdel`.

The 16-way and 256-way case splits are written by the script
[`tools/gen_trie.py`](../tools/gen_trie.py). In `map.bend` and `PROOF.bend` they stand
between the lines `BEGIN gen_trie` and `END gen_trie`, and `--check` checks that they
are not stale. The laws about commands did not change: they rest only on the five laws
of the map. `bend PROOF.bend` takes 4.9 s, `--verdict` 8.9 s.

**The result** (100 thousand keys, pipeline 16, a filled database, the cache model of
section 9):

| per request | GET: before → after | SET: before → after | INCR: before → after | Redis: GET / SET / INCR |
|---|---:|---:|---:|---:|
| instructions | 7,380 → 7,047 | 10,740 → 8,477 | 9,780 → 7,771 | 3,648 / 4,892 / 4,228 |
| L1d misses | 29.8 → 15.4 | 38.0 → 22.1 | 26.6 → 14.0 | 6.7 / 7.9 / 5.2 |
| L2 read misses | 12.7 → 5.1 | 14.8 → 6.0 | 7.3 → 2.5 | 2.8 / 2.8 / 1.4 |
| branch mispredictions | 40.7 → 29.6 | 67.2 → 36.0 | 65.8 → 41.1 | 20.4 / 26.2 / 22.8 |

On GET the descent now gives 2.2 L2 misses instead of 7.6. The other 2.9 are the nodes
and buffers of the key and the value.

Throughput, pipeline 16, a filled database (medians of three interleaved runs,
ops/s):

| keys | | GET | SET | INCR |
|---:|---|---:|---:|---:|
| 100 | Redis | 1,333,333 | 1,136,364 | 1,041,667 |
| | BendKV, binary trie | 1,030,928 | 787,402 | 806,452 |
| | BendKV, 16-way trie | 1,075,269 | 980,392 | 793,651 |
| 100k | Redis | 925,926 | 840,336 | 719,424 |
| | BendKV, binary trie | 276,243 | 238,663 | 334,448 |
| | BendKV, 16-way trie | 621,118 | 500,000 | 543,478 |
| 1M | Redis | 666,667 | 574,713 | 719,424 |
| | BendKV, binary trie | 167,224 | 132,626 | 230,415 |
| | BendKV, 16-way trie | 289,855 | 311,526 | 398,406 |

At 100 thousand keys GET grew 2.25 times, SET 2.1 times, INCR 1.6 times; that is
0.67, 0.60 and 0.76 of Redis. At 1 million, 0.43, 0.54 and 0.55 of Redis (it was 0.25,
0.23 and 0.32).

**Memory.** ~950 thousand keys take 113 MB of RSS instead of 167 MB, Redis 118 MB:
125 bytes per key against 131. Loading these keys (pipeline 64) runs at 431 thousand
ops/s instead of 176 thousand (Redis: 824 thousand).

### 7.7. Parsing, the command and the reply without extra steps

After the 16-child trie the number of instructions became the main thing (section
9.3). Parsing, choosing the command and building the reply were rewritten, and the
fourth patch was extended for their forms in Bend (section 6, the second round).

- **Parsing by index.** The request buffer is only lent to the parser. It reads it by
  index: `String.code_at` for a byte, `String.find` for the `'\r'` in a number line,
  `String.slice` for a copy of an argument. The parsed bytes are dropped once, at the
  end of the batch (`String.drop`). The old parser took characters off the buffer and
  shared it for the sake of an unfinished tail (section 7.4), and parsed a number line
  by taking off the first character and putting it back.
- **The reply from the end.** A batch's replies are written from the last to the
  first: each part goes before the next one, into the spare room of the same chunk
  (`encode_into(r, out)`). A batch of short replies is one chunk, with no copies of
  parts. Literals (`"$"`, `"\r\n"`) and the digits of a length are written straight
  into the spare room (section 6).
- **The command chosen by the length of its name.** Before,
  `match name: case "PING": …` compiled into a match a character at a time. Its failure
  arms rebuilt the string for `case other`, the function took 51 KB of machine code and
  pushed everything else out of the instruction cache: 12 L1i misses per request
  against 2.3 for Redis. Now the name's length cuts off everything but a few
  candidates, each compared whole with a literal (`cmd_id`, one `memcmp`), and
  `parse_id` parses the arguments by the command's number.
- **INCR hashes its key once.** INCR, SETNX, GETSET and APPEND read and write one key.
  They compute the hash themselves and pass it to `KV.get.at`/`KV.set.at`, that is, to
  `KV.get`/`KV.set` with a ready hash. The proofs of the laws about these commands were
  adjusted for the new argument; the laws themselves did not change. INCR's reply
  writes the number into the reply at once (`int_into`), without an intermediate
  string.

Instructions per request by step (callgrind, pipeline 16, a filled database of 100
thousand keys):

| step | PING | GET | SET | INCR |
|---|---:|---:|---:|---:|
| 16-child trie (section 7.6) | 4,626 | 7,047 | 8,477 | 7,771 |
| number line without putting a character back | 4,096 | 6,243 | 7,405 | 6,967 |
| reply from the end, into the chunk's spare room | 3,456 | 5,865 | 6,886 | 7,024 |
| parser does not share the buffer | 3,070 | 5,478 | 6,497 | 6,624 |
| fast paths of the natives for a string of one chunk | 2,785 | 4,593 | 5,523 | 5,745 |
| parsing by index | 2,712 | 4,417 | 5,256 | 5,566 |
| literals and digits straight into the spare room, short copies without `memcpy` | 2,572 | 4,009 | 5,161 | 5,447 |
| INCR: one hash, the number straight into the reply | 2,573 | 4,031 | 5,170 | 5,053 |
| command chosen by the length of its name | 2,640 | 3,936 | 5,080 | 5,087 |
| read buffer without `malloc` | 2,632 | 3,930 | 5,075 | 5,073 |
| Redis 7.0.15 | 2,453 | 3,648 | 4,892 | 4,228 |

There are 35–44% fewer instructions. Now there are 4–8% more of them than in Redis
(20% more on INCR). Mispredicted branches on GET: 10.4 (it was 29.6; Redis 20.4); L1i
misses: 8.5 (it was 12; Redis 2.3). What this is worth in real time is in sections 9.5
and 10.

Tried and dropped: encoding the replies from a list in reverse order (`exec_all`
without the last `List.reverse`) by tail recursion. On GET this is −5 instructions,
within how clang reshuffles inlining. The server still calls `exec_all`, about which
there are laws, and `encode_all`.

### 7.8. Short strings right in the term

The time profile (section 9.5) showed that after 7.7 the main thing is the dependent
misses in accessing the map. Two of the seven on GET fell on the value: the bucket entry
points to the chunk's node, the node to the buffer with the bytes. The value `"xxx"` of
`redis-benchmark` takes three bytes, and a Bend term is 64 bits.

**How it works** (the fourth patch). A string of 1–6 bytes can be one word: tag 0 with
bit 55 set, the length in bits 48–50 and the bytes themselves in the low 48 bits. Chunk
views (section 4) also have tag 0, but their position is below 2048, so their bit 55 is
always clear. Such a word is trivial, like a number: owning it is a copy, freeing it is
nothing, and it need not be shared through a counter cell. It is always the last chunk
of a string. Short strings are made this way by `String.slice`, `take`, copies,
`Nat.show`, short reads from a socket and `str_cons` onto an empty string. All the
readers — passes over chunks, views, matches with ownership and without, comparison,
length, hash, search, `++`, `to_upper`, output — understand this form. A comparison
with a literal of up to 6 bytes is a comparison of two words: the compiler passes the
literal already as a word (`str_eq_imm`).

**Checks.** Bend's tests: 715 of 846, all the earlier ones plus the new
`string_index`. A separate run of strings of 0–11 bytes (at the edge of the form),
built and read in every way, gives the same output on the JS and C lanes. BendKV: the
robustness test and the differential test against Redis (9 seeds, ~70 thousand
commands) with no differences.

**The result** (callgrind, pipeline 16, a filled database of 100 thousand keys):

| per request | PING | GET | SET | INCR |
|---|---:|---:|---:|---:|
| instructions: section 7.7 → now | 2,632 → 2,290 | 3,930 → 3,621 | 5,075 → 4,823 | 5,073 → 4,460 |
| instructions in Redis | 2,453 | 3,648 | 4,892 | 4,228 |
| L1d misses: section 7.7 → now | 0.9 → 0.5 | 15.6 → 10.8 | 21.7 → 15.3 | 12.7 → 12.0 |
| L2 misses: section 7.7 → now | 0 → 0 | 5.0 → 3.3 | 5.9 → 4.6 | 2.3 → 2.1 |
| L2 misses in Redis | 0 | 2.8 | 2.8 | 1.4 |

There are now fewer instructions on PING, GET and SET than in Redis. Throughput, as a
ratio to Redis in one and the same run (the median of 13 pairs of interleaved runs,
server and client pinned to cores): GET 0.86, SET 1.01, INCR 0.74. It was 0.80, 0.86
and 0.62. The spread of the ratio itself between series is ±0.06: in another series
GET gave 0.94.

**What remained.** On GET after this: the descent through the trie is 33% of the
samples (the nodes of levels 4 and 5, the bucket entry), the key comparison 17% (the
key's node and its bytes), `send` 20%. `redis-benchmark`'s keys are 16 bytes and do not
fit in a word. INCR is slower than GET because after the read it rebuilds the path in
the trie. The compiler then takes all 16 children out of the node and puts 15 of them
into the continuation, and after the call builds the node anew (section 11).

### 7.9. The fifth patch: a node is rebuilt in place

**The problem** (section 7.8). A write to the trie, `tmod_h`, at each level takes apart
the node `Node{c0, …, c15}` and builds it with one changed child, and that child comes
from a recursive call. The compiler did this: it read all 16 fields (both cache lines
of the node), freed the node, put the 15 unchanged children into the continuation's
frame, and after the call took a new node and wrote all 16 fields into it. Over five
levels that is ~400 memory accesses, although the node belongs to one owner and one
word in it changes.

**The patch [`node-update.patch`](../bend-patches/node-update.patch)** (`bend2/comp.ts`
+80/−17, the test `tests/rfc/node_update.bend`) does this in the code generator, for
any program without GPU calls:
- a match on a node the function owns keeps the node as a spare block and reads the
  fields straight from it. `ctr_own` gives the node itself, and copies a shared one
  just as `ctr_take` hands its fields out to co-owners;
- if one non-tail call stands between the match and the rebuild, the continuation's
  frame keeps the pointer to the spare node, not the fields that are live after the
  call. The continuation reads them back from the node;
- building the same constructor into this node does not write the fields that stayed
  in their places.

Each level of `tmod_h` now saves one word and writes one field:

```c
// before: 15 fields into the frame, after the call a new node and 16 stores
STK(0) = _f_1; … STK(14) = _f_15; STK(15) = FID_MAP_TMOD_H_K234;
// after: the node into the frame, after the call one store into the same node
STK(0) = _sp_0; STK(1) = FID_MAP_TMOD_H_K234;
…
e.mem[_sp_1 + 0] = _h_1; r0 = term_ctr(CID_MAP_NODE, _sp_1);
```

**Checks.** Bend's tests: 715 of 846, the same as without the patch. The new test
updates shared and unshared trees and checks the sums on both lanes. BendKV: the
robustness test and the differential test against Redis (9 seeds, ~68 thousand
commands) with no differences.

**The result.** `tmod_h` on SET takes 212 instructions instead of 464. Per request
(callgrind, pipeline 16, 100 thousand keys):

| per request | SET: before → after | INCR: before → after | Redis: SET / INCR |
|---|---:|---:|---:|
| instructions | 4,823 → 4,350 | 4,460 → 4,025 | 4,892 / 4,228 |
| L1d misses | 15.3 → 12.0 | 12.0 → 9.2 | 7.9 / 5.2 |
| L2 misses | 4.6 → 3.4 | 2.1 → 1.3 | 2.8 / 1.4 |

Now BendKV has fewer instructions than Redis on all four commands. In real time the
gain is smaller than in the model: in INCR's profile the share of `tmod_h` fell from 11%
to 5.5%, and the ratio to Redis in the same runs (8 pairs) is GET 0.92, SET 0.96, INCR
0.75. Before the patch it was 0.88, 1.00 and 0.72, so the change is within the spread
of these measurements (±0.06). The node's second line was probably pulled in anyway by
the hardware's adjacent-line prefetcher.

### 7.10. The sixth patch: 2 MiB pages

**Why.** After 7.9 BendKV has no more instructions than Redis, and the difference in
real time is memory latency (section 9.5). This machine has 2 MB of L2 per core and
260 MB of L3 shared by all. The working set of a database of 100 thousand keys (~16 MB)
and even of a million (~160 MB) lies wholly in L3. So an L2 miss is an access to L3
plus a page-table walk: with 4 KB pages the second-level TLB covers only ~6–8 MB, and a
random read of a trie node almost always misses the TLB.

**How.** The runtime reserves the heap (the corpus) as one region of 8 GB at a high
address and doubles it in place. The patch
[`huge-pages.patch`](../bend-patches/huge-pages.patch) (`bend2/comp.ts`, +11) marks this
region and each extension of it with `madvise(MADV_HUGEPAGE)`. On this VM transparent
huge pages are in `madvise` mode, so without the mark there are none. First I checked
the idea without recompiling: a shim through `LD_PRELOAD` marked every anonymous
mapping of 4 GB or more. At 100 thousand keys the server's heap (16 MB) went wholly
into 2 MiB pages.

**The result** (the same binary, with the mark and without, pairs interleaved, ratio
to Redis):

| | GET | SET | INCR |
|---|---:|---:|---:|
| 100k keys, without → with (5 pairs) | 0.85 → 0.93 | 0.92 → 0.98 | 0.76 → 0.80 |
| 1M keys, without → with (3 pairs) | 0.81 → 0.96 | 0.91 → 1.08 | 0.75 → 0.75 |

The user time per GET fell by ~11%.

**A fair comparison.** Redis 7 does not ask for huge pages itself (and in `always`
mode turns them off for itself). Its jemalloc can ask for them:
`MALLOC_CONF=thp:always`. At 100 thousand keys Redis does not get faster from this
(0.96–1.01 of the usual), at a million it does: GET 1.13–1.15, SET 1.10, INCR
0.94–0.96. So below, at a million keys, the ratio to Redis with huge pages is given
too.

**The cost.**
- A short program (the test `string_index`) takes two 2 MiB pages, and the kernel
  zeroes them whole: the start takes ~0.4 ms longer (the median of 30 runs is 3.3 ms
  against 2.9 ms, the worst 9.7 ms against 4.0 ms). The kernel did not have to compact
  memory on this machine (`compact_stall` = 0).
- Insertions at a million keys (INCR on new counters) spend ~150 ns more per request in
  the kernel: a 2 MiB page is zeroed whole. They spend about as much less user time, so
  INCR neither speeds up nor slows down.
- The Bend runtime's benchmarks (the same binary with the mark and without, the best of
  5 interleaved runs): geometric mean ×0.99, from 0.88 (`tree-radix`, a heap of 276 MB:
  fewer TLB misses) to 1.07 (`tree-matmul`). Programs with a large heap spend more in
  the kernel: `merkle` and `tree-bitonic` (136 MB) +0.4 s, `tree-radix` +0.9 s. The
  first touch of a 2 MiB page costs more on this VM than that of 512 pages of 4 KB, and
  for `merkle` and `tree-bitonic` this gives +3.5% and +4% of time.

### 7.11. The seventh patch: field selection by digit

**The problem.** Each level of the trie chooses a child by a match on a digit of the
hash, `Hex`, an enumeration of 16 constructors without fields. The compiler gave 16
arms, identical up to which field of the node they take, and clang turned them into a
jump table. On a random digit the indirect jump is predicted in ~1/16 of cases. The
rebuild of the path (`tmod_h`) also returned through the stack to one of 16
continuations (`K234`…`K249`, and 16 more for an empty subtree), that is, a second
unpredictable jump per level. Callgrind (with its predictor model) counted per request
10.5 mispredicted indirect jumps on GET and 19.1 on a warmed-up INCR. INCR after the
read rebuilds the same path, from the cache by then, and there these mispredictions
stand on the critical path.

**A prototype.** First I merged the arms right in the generated C: one arm reads
`e.mem[sp + x]`, the continuation's frame holds `x`, and one continuation writes
`e.mem[sp + x]`. An in-process benchmark of the map alone (1 million operations over
100 thousand keys, the keys shuffled in advance; `bench/bench_map.bend`), medians of
six runs, ms:

| | get | set | get+set (as INCR) |
|---|---:|---:|---:|
| as before | 806 | 924 | 966 |
| one arm for the descent | 726 (−10%) | 780 (−16%) | 876 (−9%) |
| and one continuation | 726 (−10%) | 720 (−22%) | 828 (−14%) |

**The patch** [`digit-select.patch`](../bend-patches/digit-select.patch)
(`bend2/comp.ts` +298/−16, the test `tests/rfc/digit_select.bend`) does this in the
compiler, for any program without GPU calls. A match on a digit — an enumeration of
three or more constructors without fields, with every arm written out — compiles to
one arm if arm i is arm 0 with the fields `off` and `off + i` of the node taken apart
above swapped. Both the variables and the slots of each node of this constructor that
the arm builds are swapped. The comparison is structural, on terms, not on the C text.
Then arm 0 serves all digits:
- it reads the field `off + x` (and the field `off + i` from the slot `off` if
  `x == i`);
- it builds the node with its slots permuted: the result goes to `off + x`, the rest
  stays in place. If the node is rebuilt in place (patch 5), one word is written;
- it keeps `x` in the continuation's frame, so there is one continuation for all
  digits.

Arms that only build a node (a descent into an empty subtree: a new node of `Tip`s and
the result) merge the same way. Arms do not merge if the fields are taken through
`slot_keep`, if an arm can create a closure or a fork (more than one non-"flat" call),
or if it differs in something else — then the old chain stays.

```c
// before: r1 = _f_0 / _f_1 / … in 16 arms, a jump by table, 16 continuations
// after: one arm
Term _f_16 = e.mem[_sp_0 + 0 + _x_0];
STK(0) = _sp_0; STK(1) = _x_0; STK(2) = FID_MAP_TMOD_H_K234;   // frame: the node and the digit
…
WL_POPN(2); Term _sp_1 = STK(0); u32 _x_1 = STK(1);           // one continuation
e.mem[_sp_1 + 0 + _x_1] = _h_1; r0 = term_ctr(CID_MAP_NODE, _sp_1);
```

`tmod_h` has 2 continuations left instead of 32, and the server's generated C became
8% shorter. None of the 17 Bend runtime benchmarks has a match on a digit, and the patch
does not change their code.

**Checks.** Bend's tests: 717 of 848, all the earlier ones plus `digit_select` and
`node_update`. The new test walks, rebuilds and grows a tree of four-way nodes with a
field before the subtrees (`off` = 1). Shared trees in it are copied on write, and a
function with a differing arm stays a chain. The output matches the original Bend.
BendKV: the robustness test and the differential tests against Redis with no
differences, and the proofs check.

### 7.12. INCR: the number is read by index, keys are compared with one `memcmp`

After 7.11 INCR still spent ~1,200 instructions more than GET. Of them ~380 went to
parsing the old value, ~200 to the second key comparison, and the rest to the second
rebuild of the path and to the reply.

- **`int_read` reads the string by index.** Before, it took the string apart a
  character at a time: it took the head, compared it with `'-'`, rebuilt the string for
  the "unsigned" branch, and then took it apart again. Now it is `String.length` and
  `String.code_at` (native, and they only borrow the string) without a single
  allocation. The proofs keep `int_read` opaque, so they do not change. Replacing
  `int_fits` (now `Nat.show` and the string's length) with a comparison against 10^14
  did not work: the proof check unfolds a `Nat` literal into unary form, and
  `Laws.incr_missing` computes `int_fits(1)`.
- **Two strings of one chunk each are compared at once** (now in the fourth patch).
  `str_eq` went by the general loop over chunks. Now, if each of the two strings is an
  immediate word or one chunk (or a window into it) without a continuation, it is one
  comparison of lengths and one `memcmp`. `str_eq` on GET: 200 → 124 instructions.

**The outcome of sections 7.10–7.12** (callgrind, pipeline 16, 100 thousand keys; INCR
on counters that already exist; p18 is the server after 7.9):

| per request | PING | GET | SET | INCR |
|---|---:|---:|---:|---:|
| instructions: 7.9 → now | 2,267 → 2,249 | 3,593 → 3,492 | 4,342 → 4,234 | 4,772 → 4,445 |
| instructions in Redis | 2,438 | 3,549 | 4,773 | 3,948 |
| mispredicted branches: 7.9 → now | 11.9 → 9.6 | 21.8 → 13.7 | 28.3 → 17.5 | 30.8 → 14.7 |
| the same in Redis | 10.5 | 23.1 | 26.7 | 22.7 |
| L2 misses: now / in Redis | 0 / 0 | 3.2 / 2.7 | 3.7 / 3.3 | 4.1 / 2.3 |

Throughput, as a ratio to Redis in the same runs (server and client pinned to cores,
pairs interleaved, medians):

| | GET | SET | INCR |
|---|---:|---:|---:|
| 100k keys (7 pairs): after 7.9 | 0.96 | 0.97 | 0.74 |
| + 2 MiB pages (7.10) | 1.02 | 1.02 | 0.80 |
| + selection by digit, `int_read`, `str_eq` (7.11–7.12) | **1.05** | **1.09** | **0.87** |
| 1M keys (4 pairs): after 7.9 | 0.86 | 0.84 | 0.75 |
| now | **1.02** | **1.01** | **0.83** |
| now, against Redis with huge pages | 0.89 | 0.92 | 0.88 |

The server's CPU time per request now (100 thousand keys, medians of seven runs): GET
1,000 ns against 1,106 for Redis, SET 1,093 against 1,169, INCR 1,288 against 1,131.

**What remained.** By GET's time profile: the descent through the trie is 25% of the
samples, the key comparison 15% (half a miss on the key's node, half on its bytes),
`send` 26%. The key's node would be removed by a string of one chunk without a
separate node (section 11). INCR costs ~950 instructions more than GET: the second pass
over the path, `int_fits` and `int_show` (two `Nat.show`) and the reply as a number. At
a million keys INCR mostly inserts new counters, and there another ~150 ns per request
go to the kernel for pages.

### 7.13. The eighth patch: a string of one chunk is the buffer itself, with no node

**Why.** After 7.12 the key comparison took 15% of GET's time: the key's term points
to the chunk's node `[buffer, continuation]`, the node to the buffer with the bytes,
and these are two dependent misses where Redis has one (`sds` keeps the header and the
bytes together). `redis-benchmark`'s keys (`key:000000012345`, 16 bytes; `counter:…`,
20 bytes) do not fit in the term word (7.8).

**How it works** (the patch [`string-blobs.patch`](../bend-patches/string-blobs.patch),
`bend2/comp.ts` +189/−43, the test `tests/base/string_blob.bend`). A string of one
chunk with nothing after it is the buffer's term (BUF) itself, with no node: a "blob".
The position where the bytes start and the buffer's class lie in the term's `aux`
anyway. A shared blob carries the RFC bit, like any term, and the position lives in
each owner's own word. So an owning match (`str_take`) just shifts the position in the
word — even when others hold the buffer too, with no copy. A non-owning match reads the
blob through a view: a word with tag 0, like a view into a chunk, but with the buffer's
class in bits 51–54 (zero for a view into a chunk) and the buffer's address instead of
the node's.

- **Who makes blobs.** Every place where a chunk is created before an empty string:
  `String.slice` (this is how request parsing copies the key and the value), `take`,
  copies, `Nat.show` of a long number, the tail of a read from a socket and the last
  chunk of any copy.
- **Who understands them.** All the readers (a pass over chunks, a view, matches with
  ownership and without, length, comparison, hash, `code_at`, `find`, `slice`,
  `take`/`drop`), writing into the spare room in front (a literal, digits, a reply
  built from the end), `++` both ways (a blob before a non-empty string becomes a
  chunk), `to_upper` in place, printing and I/O. Freeing and sharing a BUF term already
  existed in the runtime: that is how chunk buffers were stored.

**Checks.** Bend's tests: 718 of 849, all the earlier ones plus `string_blob`. The new
test takes slices of 0–40 bytes from a string of several chunks and runs each through
all the operations, owned and shared, with growth past the spare room and without. Its
full output (10.6 KB) matches the output of a build without blobs. BendKV: the
robustness test (a 1 MB value, a request a byte at a time, protocol errors, 50 clients)
and the differential tests against Redis (9 seeds, ~70 thousand commands) with no
differences.

**The result** (callgrind, pipeline 16, 100 thousand keys, INCR on existing counters):

| per request | PING | GET | SET | INCR |
|---|---:|---:|---:|---:|
| instructions: 7.12 → now | 2,249 → 2,172 | 3,492 → 3,280 | 4,234 → 3,985 | 4,445 → 4,209 |
| instructions in Redis | 2,438 | 3,549 | 4,773 | 3,948 |
| L1d misses: now / in Redis | 0 / 1.1 | 7.8 / 6.3 | 8.7 / 8.3 | 11.7 / 5.9 |
| L2 misses: 7.12 → now | 0 → 0 | 3.21 → 2.43 | 3.70 → 2.78 | 4.05 → 3.03 |
| L2 misses in Redis | 0 | 2.73 | 3.25 | 2.34 |
| mispredicted branches: now / in Redis | 8.7 / 10.5 | 12.5 / 23.1 | 15.1 / 26.7 | 16.4 / 22.7 |

Throughput, as a ratio to Redis (pairs interleaved, medians):

| | GET | SET | INCR |
|---|---:|---:|---:|
| 100k keys (7 pairs): 7.12 | 0.97 | 1.01 | 0.90 |
| 100k keys: with blobs | **1.21** | **1.10** | **0.96** |
| 1M keys (4 pairs): 7.12 | 0.99 | 1.07 | 0.86 |
| 1M keys: with blobs | **1.14** | **1.24** | **1.04** |
| 1M keys: with blobs, against Redis with huge pages | 1.03 | 1.09 | 1.08 |

The 7.12 rows here come from the same series as the rows with blobs. In the series of
section 7.12 the same state gave 1.05, 1.09 and 0.87 — the spread between series is
±0.06–0.08. The server's CPU time per request (100 thousand keys): GET 963 ns against
1,169 for Redis, SET 1,181 against 1,262, INCR 1,275 against 1,231.

**Without huge pages.** The next day, on a restarted VM, I compared the same binary
with huge pages and without them: `prctl(PR_SET_THP_DISABLE)` before the start forbids
them, so the code and the layout are the same. This is a comparison with ordinary
Redis, which has no huge pages either. Medians over all the pairs of three series (100
thousand keys, 21 pairs) and two series (1 million keys, 9 pairs):

| against Redis | GET | SET | INCR |
|---|---:|---:|---:|
| 100k keys: all eight patches | 1.17 | 1.15 | 0.95 |
| 100k keys: without the sixth (2 MiB pages) | **1.07** | **1.13** | **0.92** |
| 1M keys: all eight patches | 1.02 | 1.06 | 1.12 |
| 1M keys: without the sixth | **1.00** | **1.10** | **1.01** |

Huge pages add 0.03–0.11 to GET and INCR; on SET the difference is within the noise.
The ratios themselves are lower on this day than in the series above (at a million keys
1.02 against 1.14 on GET): Redis on the new VM ran at the same speed, and BendKV ~15%
slower. The 260 MB L3 is shared with neighboring VMs, and BendKV's chain of dependent
memory accesses is longer, so it is more sensitive to which host and which neighbors it
runs with. Separate series on this day differed by up to ±0.1, so only pairs from one
series can be compared here.

**Memory.** ~950 thousand keys with the value `xxx`: 60 MB of RSS against 75 MB before
the patch and 121 MB for Redis, that is, ~63 bytes per key against ~128. Each key's node
(16 bytes) is gone.

**What remained.** INCR still walks the path twice (the read and the write) and prints
the number twice, and it has twice as many L1d misses as Redis. On GET and SET BendKV
now gets by with fewer instructions, L2 misses and mispredicted branches than Redis.

### 7.14. The ninth patch and batch hints: the misses of different keys overlap

**The task.** After 7.13 more than half of a request's user time is waiting for memory
(section 9.6): 56–57% at 100 thousand keys and 66–68% at a million, as much as for
Redis. A key lookup is a chain of dependent loads: the node at depth 4, the bucket's
first entry, the key's bytes. Each is an L2 miss, and the processor waits for them one
at a time, although it can keep dozens of misses in flight at once. And at pipeline 16
a batch holds sixteen independent keys.

**The idea.** Before a batch runs, walk the paths of all its keys level by level, at
each step only starting the load of the next level. Then in the time of one miss the
misses of all the batch's keys are in flight. Valkey 8 does the same for batches of up
to 16 commands ("memory access amortization"). Redis 7, which we compare against, does
not.

**The ninth patch to Bend** (`bend-patches/mem-prefetch.patch`): the operation
`Mem.prefetch(A, x, k)`. By its definition in Base it equals `k`, and on the JS lane
that is how it runs. On the C lane it also starts loading the node of `x`:
`__builtin_prefetch` on every line of the constructor's fields, on the first 64 bytes
of a buffer, on the seal of a shared node. It reads nothing, so it never waits. It
changes no value, so the theory has nothing to do with it.

**BendKV.**
- In `map.bend`, hints for future descents: `touch.node(t, h, d, acc)` starts loading
  the node at depth `d` of the path of hash `h`, and `touch.entry(t, h, acc)` the key
  and value of the first entry of its bucket. Both equal `acc`. Each descends from the
  root; the top levels it reads the batch keeps in the cache. Their 16-way case splits
  are written by `tools/gen_trie.py`, as for the other descents.
- A new module `batch.bend`. A batch goes in three passes over all its keys: the nodes
  at depth 4 (the top four levels are in the cache anyway), the buckets, then the keys
  and values of their first entries. Then `exec_all` runs the batch as before and finds
  the paths in the cache. A batch of one request gets no hints: there is nothing to
  overlap.
- The law `batch_hints` in `LAWS.bend`:
  `B.exec_batch(cs, hs, db) == R.exec_all(cs, db)`, whatever the hints' hashes. It is
  proved (`PROOF.bend`) and rechecked by the BendTT kernel; there are now 20 laws.

**Two traps.**
- **The Bend compiler drops pure computations whose result is not needed.**
  `u = touch(...)` with an unused `u` disappears entirely, hints and all. So the hints
  return a number, and the batch runs in `exec_hinted(U32.is_eq(u, 0), cs, db)`, both
  of whose arms are `exec_all`. The hints must finish before the batch starts, and they
  cannot be dropped. clang then folds the branch, and `__builtin_prefetch` stays.
- **The hashes cannot be taken from the batch's commands.** The type `Cmd` has an
  unboxed layout: a match on a lent command lays its fields out into words, and each
  pointer field gets a reference count (`slot_keep` → `rfc_wrap` and a CAS). In the
  first version every key was sealed this way: +180 instructions and atomic operations
  per request, and the gain at a million keys was only +10…17%. Now the connection
  computes the hashes from the request's words. Strings are boxes and are read in
  place: the hash of each request's first argument goes into the batch together with
  the commands. For commands not on a key the first argument gives a hint that will not
  be used.

**The cost.** Instructions per request (callgrind, 100 thousand keys): GET 3,280 →
3,834 (+17%), SET 3,985 → 4,544 (+14%), INCR 4,209 → 4,785 (+14%). That is a second
hash of the key (`exec` computes it too), three descents from the root and the list of
hashes. One more pass, at depth 3, gave nothing: +0…+10% at a million keys, within the
noise.

**Results.** Paired interleaved runs, medians over all series of this code (`n` is the
number of pairs in the comparison with the previous build and with Redis):

| keys | against the 7.13 build: GET / SET / INCR | against Redis: GET / SET / INCR | n |
|---|---|---|---:|
| 1k | 0.92 / 0.89 / 0.95 | 1.09 / 1.13 / 0.95 (it was 1.17 / 1.25 / 1.00) | 8 / 8 |
| 100k | **1.54 / 1.67 / 1.58** | **1.62 / 1.82 / 1.45** | 9 / 13 |
| 1M | **1.51 / 1.69 / 1.47** | **1.65 / 1.80 / 1.17** | 7 / 11 |

The server's CPU time per request, ns (in user mode + in the kernel):

| keys | GET: Redis | GET: 7.13 | GET: 7.14 | SET: Redis | SET: 7.13 | SET: 7.14 | INCR: Redis | INCR: 7.13 | INCR: 7.14 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1k | 406 + 381 | 328 + 362 | 356 + 372 | 500 + 384 | 344 + 350 | 384 + 396 | 472 + 384 | 412 + 382 | 459 + 368 |
| 100k | 1,006 + 412 | 844 + 400 | 431 + 406 | 1,162 + 400 | 962 + 400 | 419 + 362 | 1,000 + 400 | 1,062 + 419 | 550 + 400 |
| 1M | 1,256 + 444 | 1,156 + 388 | 612 + 406 | 1,438 + 412 | 1,275 + 431 | 656 + 375 | 1,356 + 444 | 1,350 + 669 | 838 + 588 |

Waiting for memory is the difference from a thousand keys. On GET it fell from ~516 to
~75 ns at 100 thousand keys and from ~828 to ~256 ns at a million: the hints hide ~85%
and ~70% of it. GET's user time at 100 thousand keys is now 431 ns, Redis's 1,006. The
differential tests (~70 thousand commands in 12 thousand batches) matched Redis byte
for byte. Bend's test suite on the C lane with the ninth patch gives the same as with
eight, plus the new test. The only difference is `io_stack_fault_trap`: it overflows a
2 GB stack, runs 1–11 s and under parallel load does not fit in the runner's 5 s. On
its own it passes with both builds.

**What remained.**
- At a thousand keys everything is in the cache anyway, and the hints are pure
  overhead: −5…−11%. But BendKV is still not slower than Redis, except INCR (0.95).
- `exec` hashes the key a second time. Handing it a ready hash means changing the
  proved core (`exec.at` with the law `exec.at(c, hash(key(c)), db) == exec(c, db)`);
  that is −135 instructions.
- INCR's kernel time at a million keys is higher than Redis's (588–669 ns against
  444), and it was so before the hints too. The cause is yet to be found.

### 7.15. A check with Redis's own benchmarks

Until now everything was measured with `redis-benchmark` from the Redis repository: 20
clients, pipeline 16, 3-byte values. Redis also has a full set of benchmarks on which it
is checked in CI:
[redis/redis-benchmarks-specification](https://github.com/redis/redis-benchmarks-specification),
529 specs in YAML. They are run by `memtier_benchmark` (Redis Ltd.): several threads,
hundreds of connections, values of 10–1,000 bytes, latency percentiles. The script
[`tools/memtier_specs.py`](../tools/memtier_specs.py) takes the specs as they are. Only
the number of client threads changes (we have three cores for the client, with the same
total number of connections) and the duration (12 s instead of 120–180). The server, as
before, is on one core, and all runs are interleaved on fresh processes. Under
`memtier` the server is loaded 97–99%, under `redis-benchmark` 80–90%.

Five specs, three runs each, the median of the ratio to Redis 7.0.15:

| spec | Redis, ops/s | 7.13 build | with hints (7.14) |
|---|---:|---:|---:|
| `1Mkeys-load-string-with-100B-values-pipeline-10` (SET of new keys) | ~480k | 1.03 | **1.39** |
| `1Mkeys-string-get-100B-pipeline-10` | ~700k | 1.26 | **1.26** |
| `1Mkeys-string-get-100B` (no pipeline) | ~128k | 0.90 | **0.90** |
| `1Mkeys-string-get-10B-pipeline-100` | ~976k | 1.07 | **1.36** |
| `1Mkeys-string-incr-pipeline-10` | ~950k | 1.05 | **1.00** |

The server's CPU time per operation (user + kernel, ns, medians):

| spec | Redis | 7.13 | 7.14 |
|---|---:|---:|---:|
| load 100 B, pipeline 10 | 1,381 + 666 | 1,143 + 812 | 882 + 565 |
| GET 100 B, pipeline 10 | 781 + 597 | 502 + 607 | 518 + 591 |
| GET 100 B, no pipeline | 1,205 + 6,444 | 1,833 + 6,544 | 1,854 + 6,472 |
| GET 10 B, pipeline 100 | 907 + 88 | 871 + 86 | 654 + 82 |
| INCR, pipeline 10 | 461 + 568 | 454 + 531 | 494 + 521 |

What follows from this:
- **The numbers of section 7.14 are the best case.** `redis-benchmark` sends 16
  commands at a time and waits for all 16 replies, so each read of the server is a full
  batch, and the hints on it work at full strength. 3-byte values lie right in the term
  word (7.8). `memtier` sends a new command as soon as a reply has come, and the
  batches come out uneven.
- **The hints help where batches are large:** pipeline 100 (1.07 → 1.36) and loading
  new keys (1.03 → 1.39). On GET with pipeline 10 they give nothing, but cost nothing
  either.
- **Without pipelining BendKV is slower than Redis: 0.90.** Both sides are bound by
  the kernel: ~6.5 µs of system time per request. But BendKV has more user time:
  1.8–1.9 µs against 1.2. This is the path of a single command through the connection,
  the channel and the database actor, plus `select`, which rebuilds the descriptor set
  at every step. Redis uses `epoll`.
- **INCR is level with Redis.**
- **The p99 latency** on the pipelined specs is lower for BendKV than for Redis: on GET
  with pipeline 10, 2.8 ms against 3.4; on the load, 6.2 against 9.2.
- **Huge pages spoil the load.** In one of the trial runs the load of the same build
  went twice as slow, and all the time went to the kernel: up to 1.4 µs per operation.
  That is memory compaction for 2 MiB pages as the heap grows (section 7.10). Redis
  turns huge pages off for itself by default (`disable-thp yes`). In the series above
  there were no such dips.

From here on these specs count as the main ones, and `redis-benchmark` remains a quick
comparison. On a multi-core server the single-threaded `redis-benchmark` would become
the ceiling anyway.

### 7.16. Several cores: shards and sending on a separate thread

Until now BendKV ran on one core, as Redis does. The tenth patch to Bend
([`bend-patches/io-loops.patch`](../bend-patches/io-loops.patch)) gives a program
several cores:

- `IO.spawn_on(A, i, act)` runs a computation on event loop `i`. Loop 0 is the main
  thread, and each next one is a thread of its own, with its own allocator row, its own
  computation root and its own queues. Computations on different loops talk through
  channels: a waiter is woken on its own loop, through the loop's mailbox (and a `NULL`
  in its pipe if the loop sleeps in `select`). Before it falls asleep, the loop
  busy-waits ~30 µs for a handoff.
- `Chan.send_all(A, [(c1, x1), (c2, x2), …])` puts values on several channels in one
  step, under one lock. Two such sends order their values the same way in every channel
  they share.
- `TCP.post(sock, data)` hands bytes to its loop's writer thread and gives the socket
  back at once. The writer sends them in order, and `Socket.close` closes the socket
  after them.

**Shards.** `./bendkv PORT N` splits the database into N shards (one by default). A
key's shard is set by the lowest hex digit of its hash, the one the trie's root
branches on: shard s of n owns the digits d with d·n/16 = s. Each shard is an actor on
its own loop, and connections are spread over the loops round-robin. A connection cuts
each batch into parts
([`shard.bend`](https://github.com/littleBro/BendKV/blob/archive/shards/shard.bend),
`split`):

- a command with one key goes whole to the key's shard;
- MGET, DEL, EXISTS and MSET as one command per key (GET, DEL of one key, EXISTS of one
  key, SET);
- DBSIZE, KEYS and FLUSHALL to every shard (since section 7.18 as a piece for each
  digit of the trie's root, to that digit's shard);
- PING, ECHO and bad commands the connection answers itself.

All the parts of a batch go to the shards in one `Chan.send_all`, so each shard sees
the batches of all connections in the same order. Running them is then equivalent to
running the batches one after another in that order, as in deterministic databases
(Calvin): no locking between shards is needed, and a batch is atomic, even an MSET over
keys of different shards. The replies are gathered back in the batch's order
(`merge`).

**Checks.**
- [`tests/shard_check.bend`](https://github.com/littleBro/BendKV/blob/archive/shards/tests/shard_check.bend)
  runs split and merge without the network. The batch of the smoke test (all 16
  commands, repeated keys in MGET, DEL and EXISTS, KEYS, FLUSHALL) with n = 1, 2, 3, 4
  and 16 gives exactly the same replies as one trie.
- `diff_test.py` against Redis with 1, 2 and 4 shards: all replies match.
  `robust_test.py` passes.
- The new [`tests/concurrency_test.py`](../tests/concurrency_test.py) checks that the
  single-threaded semantics holds under many clients:
  1. no lost INCR: 8 clients doing 3,000 INCRs each over 16 keys in different shards;
  2. an MSET over 16 keys of different shards is atomic: not a single "torn" MGET of
     ~13 thousand;
  3. the order across shards holds: a writer does SET x, then SET y (in one batch or in
     different ones), and a reader that does GET y and then GET x never sees x behind y.

  The test passes on Redis and on BendKV with 1, 2 and 4 shards. `make test` runs all
  these checks for one shard and for two.
- The test really does catch the atomicity of `send_all`. If the lock is released
  between channels, Bend's test `chan_send_all` (two loops each send 100 pairs to two
  channels) finds different orders in 31 runs of 40, and with the lock in 0 of 100.

**Measurements.** The same five Redis specs (7.15), three interleaved runs each. The
server on two cores (CPUs 2–3), `memtier` on the other two (`-t 2`). The variants:
- "1 loop": one loop, sending right in the loop;
- "1 loop + writer": with `TCP.post`, which is now `./bendkv PORT`;
- "2 shards": two loops, sending right in the loop.

Thousands of ops/s (median) and the ratio to Redis:

| spec | Redis | Redis io-threads 2 | 1 loop | **1 loop + writer** | 2 shards |
|---|---:|---:|---:|---:|---:|
| load 100 B, pipeline 10 | 504 | 498 (1.03) | 723 (1.44) | **980 (1.94)** | 752 (1.59) |
| GET 100 B, pipeline 10 | 764 | 763 (1.04) | 1,022 (1.34) | **1,202 (1.61)** | 812 (1.09) |
| GET 100 B, no pipeline | 148 | 171 (1.22) | 139 (0.95) | 165 (1.11) | **176 (1.19)** |
| GET 10 B, pipeline 100 | 1,024 | 1,012 (1.03) | 1,347 (1.32) | **1,454 (1.39)** | 1,394 (1.33) |
| INCR, pipeline 10 | 941 | 1,012 (0.99) | 990 (1.05) | **1,269 (1.27)** | 877 (0.85) |

Latency p50/p99, ms (median):

| spec | Redis | 1 loop | 1 loop + writer | 2 shards |
|---|---:|---:|---:|---:|
| load 100 B, pipeline 10 | 3.76 / 9.21 | 2.48 / 12.41 | **1.89 / 4.93** | 2.46 / 6.43 |
| GET 100 B, pipeline 10 | 1.22 / 3.26 | 0.91 / 2.37 | **0.73 / 2.43** | 1.10 / 3.06 |
| GET 100 B, no pipeline | 0.60 / 1.73 | 0.68 / 1.53 | 0.56 / 1.49 | **0.53 / 1.52** |
| INCR, pipeline 10 | 1.96 / 5.38 | 1.85 / 4.70 | **1.42 / 4.01** | 2.10 / 5.82 |

The server's CPU per operation (user + kernel, ns):

| spec | Redis | Redis io-threads 2 | 1 loop | 1 loop + writer | 2 shards |
|---|---:|---:|---:|---:|---:|
| load 100 B, pipeline 10 | 1,321 + 643 | 3,107 + 757 | 747 + 640 | 868 + 631 | 1,948 + 600 |
| GET 100 B, pipeline 10 | 731 + 546 | 1,857 + 670 | 453 + 519 | 687 + 700 | 1,580 + 672 |
| GET 100 B, no pipeline | 986 + 5,611 | 5,099 + 6,021 | 1,486 + 5,656 | 2,505 + 8,915 | 5,199 + 5,864 |
| GET 10 B, pipeline 100 | 878 + 82 | 1,818 + 93 | 636 + 79 | 653 + 104 | 1,237 + 83 |
| INCR, pipeline 10 | 493 + 523 | 1,256 + 635 | 482 + 488 | 632 + 648 | 1,611 + 555 |

What follows from this.

- **The second core is best given to sending.** `send` is the most expensive part of
  the loop's work: 435 of 1,064 ns on GET with pipeline 10. With `TCP.post` the loop
  puts the finished reply buffer into a ring, and the writer thread sends it on another
  core. One contiguous buffer per batch crosses between cores, not terms for each
  command. By thread: the loop is loaded ~90%, the writer ~78% (part of it
  busy-waiting). Throughput grew by 8–36% with pipelines, and the p99 latency of the
  load fell 2.5 times. The price: CPU per operation grows (GET with pipeline 10:
  1.39 µs instead of 0.97), and a send error no longer comes back to the program: a dead
  client shows up at the next read.
- **Shards on two cores pay off only without pipelining and on the load.** A profile by
  thread (`tools/sprof.c` in the new `SPROF_CPU` mode: a CPU-time timer, samples with
  the thread's number) on GET with pipeline 10 showed 2,098 ns of CPU per operation for
  two shards against 1,064 for one loop. The increase breaks down like this:
  - ~500 ns: cache misses: the terms of commands, the terms of replies and the
    reference counts of values cross between cores, and every function that touches
    them gets more expensive;
  - ~190 ns: the code of split and merge;
  - ~140 ns: busy-waiting for handoffs;
  - ~150 ns: the channels between loops.

  System calls barely increased: for 20 thousand batches, ~1.2 thousand writes to a
  pipe and ~1.5 thousand `select` calls. More than half of one loop's time is the OS
  kernel (send, recv, select: 579 of 1,064 ns). Working on the data structure is the
  smaller part, and splitting it between cores costs more than doing it. Redis
  io-threads gives almost nothing for the same reason (1.03–1.22), although it spends
  2–3 times more CPU. Without pipelining the shards win (1.19): there everything is
  bound by the latency of one request, and two loops split between them the system
  calls of hundreds of connections.
- **Shards with writers on two cores are the worst variant** (591 thousand ops/s on GET
  with pipeline 10 in a trial run): four threads on two cores get in each other's way.
- **Buffers per thread gave another +7%** (900 → 959 thousand ops/s on one loop).
  Before, each connection waiting in `recv` held a 64 KiB buffer from `malloc`. With a
  hundred connections glibc kept giving this memory back to the kernel and taking it
  again: `brk` in the main thread and `madvise(DONTNEED)` in another thread's arena
  (the call stack was shown by `strace -k`). Now a waiting `recv` gives its buffer back
  to the thread, and `send_raw` writes into the thread's buffer instead of a `malloc`
  with five doublings for a reply of a kilobyte.

**When shards will pay off.** It takes more cores than the OS kernel and the client
occupy, and sending bytes instead of terms (its check is in section 7.17: bytes paid off
in the replies but not in the requests). A connection hands a shard the bytes of its
requests, the shard parses them itself, runs them and encodes the replies, and bytes go
back. Then about three cache lines per command cross between cores, not dozens, and the
values' reference counts do not bounce between cores. The laws do not change for this:
the shard runs the same `exec_all`.

**The proof.** Two laws are proved (`LAWS.bend`, section Shards). A history is the
batches the server has run since the start, from newest to oldest. After any history
the sharded server answers the next batch as the single-threaded one does
(`shard_replies`), and each key reads in its shard as in the single database
(`shard_holds`). The laws hold for any number of shards: the list of tries grows as
needed, and past its end lies an empty trie. They are proved for batches of any
commands except DBSIZE, KEYS and FLUSHALL (section 7.18 added those later, with another
invariant). The laws speak of `split` and `merge` from `shard.bend`; the sending of the
parts over channels and the gathering of replies in `server.bend` remain trusted.

A command with several keys goes to the shards in pieces: MGET as a GET per key, DEL
and EXISTS as a DEL and an EXISTS of one key, MSET as a SET per pair. The course of the
proof (~1,250 lines of `PROOF.bend` without comments):
- **a sequential model.** The history runs piece by piece, each on its key's shard
  (`seqT` on the list of tries, `seqD` on one database). A command with one key is its
  own piece;
- **correspondence.** In the model each key reads in its shard as in the database
  (`holds_seq`). A piece's action on its key depends only on how that key reads
  (`loc_key`), and it does not touch the other keys (`frame`). So there is no need to
  look inside the trie; the map's laws suffice;
- **replies.** The pieces of a batch, put on the shards' lists, are taken off in the
  batch's order (`pop_push`). Each reply is what its key's shard would give, and that
  matches the single database's reply (`loc_reply`). The folds of `merge` build the
  command's reply from the pieces' replies: an array of values (`items_pieces`), a sum
  of counts (`sum_pieces`), OK (`ok_pieces`). The shards after the batch are the same as
  in the model (`after_push`);
- **a command as its pieces.** A command's pieces, run one after another on the single
  database, give its reply and its database: MGET's values are the replies of its GETs
  (`mget_items`), EXISTS counts the same as its pieces (`exists_total`), DEL deletes and
  counts as its one-key DELs do (`del_total`, `del_db`), MSET writes as its SETs do
  (`mset_db`);
- **gluing.** The batches of the history, run by the server, are the same model
  unfolded into pieces (`tries_go`, `db_go`, `shards_eq`, `single_eq`).

Bend's affinity got in the way: the hypothesis "for all keys" is a closure, and a
closure can be called only once. So the proof never assumes it: `holds_seq` is a
top-level function, called at whatever key a step needs. The refutation "the shards
differ" cannot be used twice either, and it became an equality of boolean verdicts
(`{False == nat_eq(i, s)}`). All 25 laws check in ~1 s, with the BendTT kernel in ~2 s
(the 22 laws of then and the three laws about bytes from section 7.17).

### 7.17. Bytes between cores, `epoll`, iolists and PGO

This round's four questions:
- will shards pay off if bytes, not terms, are passed between cores;
- will `epoll` instead of `select` lift GET without pipelining;
- what will a build with a profile (PGO) give;
- is it worth building a reply as an Erlang iolist: a tree of chunks that goes to the
  socket without gluing.

**A load generator on one core.** memtier takes two of this machine's four cores,
leaving the server two. To give the server three cores, a lighter generator is needed.
[`tools/loadgen.c`](../tools/loadgen.c) is one thread on epoll; on each connection it
keeps P requests in flight, like memtier's `--pipeline`, and takes random keys from a
space loaded in advance. With one core it loads Redis up to 450 thousand GET/s and is
itself ~37% busy doing so. [`tools/scale_bench.sh`](../tools/scale_bench.sh) puts the
server on CPUs 1–3 and `loadgen` on CPU 0 and runs three shapes of load: GET with
pipeline 10, GET without pipelining and 50% SET with pipeline 10. Everywhere 100
connections and 1 million keys of 100 bytes, with interleaved runs. Without pipelining
`loadgen` itself is bound by its core (~170–200 thousand requests/s: for each request
it has a `send`, a `recv` and a share of an `epoll_wait`). So GET without pipelining
was also measured with a memtier spec on 2+2 cores.

**`epoll` (the eleventh patch,
[`bend-patches/io-epoll.patch`](../bend-patches/io-epoll.patch)).** A socket made by
the runtime itself joins its loop's epoll once and is waited for edge-triggered. The
loop remembers whether the socket is ready to read and to write. A `recv` that read
less than it asked for marks the socket drained, and the next `recv` waits for an edge,
without spending a system call on `EAGAIN`. Other descriptors (files, pipes, sockets of
user effects) join epoll one-shot for each wait: code may close them behind the
runtime's back. Three bugs were found by Bend's tests and by stress runs:
- a test with a FIFO hung. A user effect closed the descriptor itself, and the loop
  took a new file with the same number for one already registered. Hence the split into
  the runtime's sockets and all other descriptors;
- in the tests `tcp_backlog_timer` and `udp_backlog_timer` the timer fell behind a
  steady stream of connections when `accept` tried to accept a connection before
  parking. Now `accept`, UDP's `recv_from` and `TCP.poll` park first, as with
  `select`;
- `io_tcp_post` hung in 7 runs of 30. The FIN came with the last bytes, the short read
  marked the socket drained, and no new edge would come. Now the end of the stream
  (`RDHUP`, `HUP`, `ERR`) is remembered apart, and such a socket does not count as
  drained: 60 runs of 60.

Along the way a fourth problem turned up. `loadgen` loaded keys in batches of 1,000
SETs, and each batch took 45 ms. The reply to a batch went out in several writes, and
the second waited for the acknowledgment of the first: Nagle's algorithm on the server
against delayed ACK on the client. Now accepted connections get `TCP_NODELAY`, as in
Redis. Bend's tests on the C lane: 722 of 854, the same failures as without the patch
(721 of 853), plus the new test `tcp_post_list`.

**What `epoll` and `TCP_NODELAY` gave.** The server on three cores, `loadgen` on the
fourth, medians of three runs, thousands of ops/s (for GET with a pipeline, the spread
in parentheses). The same table holds all the shard variants discussed below:

| server | GET, pipeline 10 | GET, no pipeline\* | 50% SET, pipeline 10 |
|---|---:|---:|---:|
| Redis | 405 (384–413) | 126 | 362 |
| Redis, 3 io-threads | 436 (430–439) | 157 | 403 |
| BendKV, `select` | 736 (712–870) | 186 | 737 |
| + `TCP_NODELAY` | 788 (666–797) | 180 | 785 |
| + `epoll` | 872 (870–895) | 176 | 832 |
| final, 1 shard | 897 (883–914) | 176 | 841 |
| 2 shards, sending from the loop | 686 (682–701) | 170 | 687 |
| 2 shards, writers | 800 (765–809) | 165 | 777 |
| 3 shards, sending from the loop | 816 (713–825) | 193 | 802 |
| 3 shards, writers | 558 (531–569) | 129 | 544 |
| 2 shards, replies as terms | 516 (514–585) | 170 | 694 |
| 3 shards, replies as terms | 797 (739–812) | 195 | 805 |

\* Without pipelining `loadgen` is 93–97% busy on its core, and BendKV is bound by it;
this column is good only for comparison with Redis. With pipeline 10 `loadgen` is ~60%
busy.

With a pipeline, `epoll` together with `TCP_NODELAY` gave GET +18% (736 → 872
thousand) and the mix with SET +13%. GET without pipelining was measured with Redis's
specs on 2+2 cores (the server on CPUs 2–3, memtier on 0–1, two runs; thousands of
ops/s and the ratio to Redis):

| spec | Redis | `select` | + `TCP_NODELAY` | + `epoll` | final | final, PGO |
|---|---:|---:|---:|---:|---:|---:|
| load 100 B, pipeline 10 | 499 | 886 (1.77) | 1,012 (2.03) | 987 (1.98) | 1,004 (2.01) | 1,032 (2.07) |
| GET 100 B, pipeline 10 | 740 | 1,287 (1.75) | 1,168 (1.58) | 1,313 (1.78) | 1,268 (1.72) | 1,285 (1.74) |
| GET 100 B, no pipeline | 154 | 177 (1.15) | 177 (1.15) | 195 (1.27) | 187 (1.22) | 190 (1.24) |

System calls per request ([`tools/iocount.c`](../tools/iocount.c) counts `recv`,
`send`, `select` and `epoll_wait` through `LD_PRELOAD`; 100 connections, 5 s):

| | `recv` (of them `EAGAIN`) | `send` | `select` or `epoll_wait` |
|---|---:|---:|---:|
| no pipeline, `select` | 2.00 (1.00) | 1.00 | 0.12 |
| no pipeline, `epoll` | 1.00 (0) | 1.00 | 0.62 |
| no pipeline, `epoll`, 3 shards | 1.00 (0) | 1.00 | 0.06 |
| pipeline 10, `select` | 0.20 (0.10) | 0.10 | 0.002 |
| pipeline 10, `epoll` | 0.10 (0) | 0.10 | 0.008 |

Without pipelining each request costs a `recv` and a `send`. It cannot get lower until
the system calls of different connections are gathered into a batch (io_uring). With
`select` the loop also tried a `recv` before parking, and each request came with one
empty `EAGAIN`. Besides, each `select` polled all 100 sockets. `epoll` removed both.
The OS kernel time per request without pipelining (by memtier) fell by 30%, from 8.3 to
5.8 µs (Redis: 5.3), and GET without pipelining rose from 1.15 to 1.27 of Redis.
`epoll_wait` is called more often than `select` was (0.62 times per request against
0.12), but it gives back the ready sockets at once, without a scan. BendKV's user time
per request is still 2.6 times Redis's (2.7 µs against 1.0); it includes the
busy-waiting of the loop and of the writer. `TCP_NODELAY` gave the load +14%, and its
p99 fell from 12.9 to 4.4 ms (Redis: 10.2).

**Replies as bytes.** Before, a shard returned the terms of the replies to the
connection. The connection read the values from another core's trie, encoded them and
let them go, and the values' reference counts bounced between cores (~500 ns of misses
per operation, section 7.16). Now a shard encodes the reply of each of its commands
itself
([`wire.bend`](https://github.com/littleBro/BendKV/blob/archive/shards/wire.bend)). A
GET's reply leaves the shard as ready RESP bytes. The reply to an EXISTS or a DEL of
one key leaves as a number: the connection will add it to the pieces from other
shards. The reply to KEYS leaves as a list of keys. The connection merges the replies in
the batch's order, as `merge` from `shard.bend` does, but from bytes, and sends the
chunks together.

The merge of bytes is proved by three laws (`LAWS.bend`, section Bytes).
`merge_bytes`: it gives the replies of `merge` from `shard.bend`, each encoded.
`encodes_glue`: replies encoded one at a time and glued are the batch encoded whole.
Hence `shard_bytes`: after any history the sharded server sends for a batch the same
bytes as the single-threaded one. For this each command gives one reply string in the
merge, and a GET's reply leaves the shard as a separate form (`OBulk`): in MGET's array
it becomes an element, and any other reply becomes nil, as in `shard.bend`. The proof
(~340 lines) goes by the steps of both merges and keeps a correspondence: the store in
bytes is the shards' replies, encoded (`W.store_of`), and the replies accumulated are
the encoded replies of `merge`. The encoders write before what follows them
(`into_glue`), hence the gluing. If a bug is put into the merge (starting DEL's sum at
1, or changing the nil in an array), the check fails.

Replies as bytes lifted GET with a pipeline on two shards by 33% (516 → 686 thousand,
the table above). On three shards the gain is 2% (797 → 816), within the spread. On the
mix with SET there is no difference: the reply to SET is `+OK`, and its term pulls
nothing from the trie.

**Requests as bytes did not pay off.** The second half of the idea was to pass the
requests to a shard as bytes too. The connection marked up a request in the buffer
without copying anything: where it ends, how many arguments it has, where the name and
the key lie. Then it chose the shard by the command's name and the key's hash, handed
the shard the buffer and the places of its requests, and the shard parsed them itself.
Commands on several keys and on all shards were parsed and cut into pieces as before.
The variant passed all the tests on 1, 2 and 4 shards, but turned out slower on GET of
100 bytes and on SET, and within the spread on GET of 1 KB:

| 3 shards, sending from the loop | GET 100 B, pipeline 10 | SET 1 KB, pipeline 10 | GET 1 KB, pipeline 10 |
|---|---:|---:|---:|
| requests as terms, replies as bytes | 752–809 | 570–613 | 553–583 |
| requests and replies as bytes | 715–744 | 543–551 | 587–612 |

Thousands of ops/s, from two to four runs. The shard has to read the request's bytes
from another core's cache and parse them, although the connection has already gone over
them while marking them up. A command's term carries a pointer to the value, and SET
puts it into the trie without ever reading the value's bytes. Bytes pay off in the
direction where the receiver reads the data anyway: the connection must send a reply
whole, so it pays to encode it where the value is already in the cache.

**A compiler trap.** The first version of routing by bytes slowed down by 27% even the
server with one shard (650 thousand GET/s against 900), although the path of one shard
did not change. The Bend compiler decides for each function whether it borrows a
parameter or owns it, over all its call sites. A call with a fresh argument that the
caller no longer needs makes the parameter owned. Then the other callers, which still
hold their argument, take a reference to it before the call and let it go after. A new
call `R.parse(args)`, after which `args` is still needed, switched `R.parse` to
borrowing: a `slot_keep` on each field and a `term_drop` of the parsed request after.
And `KV.hash(String.slice(…))` switched `KV.hash` to ownership, and a `term_keep` of the
key appeared in four arms of `exec`. In the profile `memcmp` took 11.7% of the time
instead of 2%, and `term_drop` and `slot_keep` appeared. What helped was comparing the
generated C of the two builds function by function, with the numbers aligned. The fix:
the task for a shard carries the key's hash, which the router has already computed, and
the router calls `String.hash` directly. The lesson: in Bend a new call can change the
calling convention of a hot function globally, and after edits it is worth comparing
the generated C of the hot path.

**A writer, or sending from the loop.** A writer pays off while it has enough of a
core. Two shards with writers (four threads on three cores) are 13–17% faster than
without them: 800 thousand GET/s against 686. Three shards with writers (six threads)
are 32% slower: 558 against 816. So the server got a third argument: `post` hands the
replies to writers, `send` sends them from the loop. By default one shard has a writer,
and with several shards the loop itself sends the replies. If there are at least
2n − 1 cores, it is worth adding `post` for the shards. `make test` runs both modes.

**Do shards pay off now.** On three server cores with a pipeline, still no. The best
result comes from one shard with a writer: 897 thousand GET/s, 2.06 of Redis with
io-threads on the same cores. Three shards give 816 thousand. Without pipelining three
shards have the most of all (193 thousand), but here `loadgen` is the bound.

**iolist.** `TCP.post_list(sock, [s1, s2, …])` (the eleventh patch) posts chunks as one
buffer. A GET's reply then consists of three chunks: the header, the value right from
the trie and `"\r\n"`. So the value is copied once, into the post buffer, not twice
(into the reply string and into the post buffer). One shard, GET, thousands of ops/s
over three runs:

| value | reply as one string | iolist |
|---|---:|---:|
| 100 B, pipeline 10 | 834–947 | 646–742 |
| 100 B, no pipeline | 162–173 | 183–196 |
| 4 KB, pipeline 10 | 291–315 | 230–301 |
| 4 KB, no pipeline | 136–142 | 112–122 |

The iolist won only on short replies without pipelining, and in the other cases lost up
to 30%. There are three reasons:
- in Bend's heap a chunk is a list cell and a string, and each value has its own
  header as well. Building and walking three cells per GET costs more than appending 100
  bytes to the reply chunk: `encode_into` writes each reply right into the spare room
  of one chunk;
- a real `writev` without gluing is impossible here. The writer sends the bytes when
  the loop has already moved on, and the next SET of the same key may free the value in
  the loop's heap. It cannot be referenced from another thread: the reference counts are
  not atomic. So the chunks are glued into the post buffer anyway, and the iolist saves
  one copy of the value but pays for every chunk;
- the first version of `post_list` grew the buffer by doublings from 64 bytes: seven
  `realloc` calls per reply of 4 KB, under the lock of the malloc arena, which the
  writer takes when it frees buffers. `__lll_lock_wait` and `__lll_lock_wake` took 20%
  of the profile. Now the chunks' lengths are summed in advance, and the buffer is
  allocated once; the table above was taken with this fix already.

An iolist would pay off on values of hundreds of kilobytes (on 1 MB one copy costs
50–100 µs). But only with buffers the writer can read without getting in the loop's
way, like Erlang's refc binaries: there a binary of 64 bytes or more is passed by
reference with a count of its own. In BendKV `post_list` stayed only for merging the
shards' replies: there each chunk is already a whole encoded reply.

**PGO.** `make pgo` builds `build/bendkv-pgo`
([`tools/pgo_build.sh`](../tools/pgo_build.sh)). First comes an instrumented build
(`-fprofile-instr-generate`). It is trained by load from `redis-benchmark` on one shard
and on two: SET with pipeline 64; GET, SET, INCR and MSET with pipeline 10; GET and SET
without pipelining; GET with pipeline 100. Then `llvm-profdata merge` and a rebuild with
the profile. Three interleaved runs, the server on three cores, thousands of ops/s:

| | GET, pipeline 10 | GET, no pipeline | 50% SET, pipeline 10 |
|---|---:|---:|---:|
| 1 shard | 905 | 182 | 859 |
| 1 shard, PGO | 939 (+4%) | 177 | 893 (+4%) |
| 3 shards | 804 | 200 | 810 |
| 3 shards, PGO | 814 (+1%) | 206 | 837 (+3%) |

On the memtier specs (the table above) PGO cut the user time per operation by 6% on
the load and by 3% on GET with a pipeline. That is what the measurement in 9.6
predicted (+5…8% by instructions), but user code is the smaller part of the work.
Without pipelining the OS kernel time is twice the user time, and the difference there
is within the noise: PGO does not lift GET without pipelining.

**A foreign thread on a server core.** In two series the multi-threaded servers
suddenly slowed down sharply. Redis with three io-threads fell from ~400 to 76 thousand
GET/s, and without pipelining from 155 to 7.8 thousand. The BendKV variants with three
loops or with writers at two shards lost 30–40%, and the servers with one loop barely
changed. The cause turned out to be my own waiting process (`read -t N < /dev/zero` in
bash reads zeros without stopping and takes a whole core). It shared a core with the
server, and threads that wait actively spun while their partner stood in the run queue:
Redis's io-threads wait for each other at every iteration, BendKV's loops wait 30 µs
for a handoff before they sleep, the writers 50 µs. These series were discarded; all
the numbers here were taken without foreign processes. The lesson for designs with
busy-waiting: they need cores of their own. That is why there are no writers by default
for several shards.

**The outcome of the round.**
- GET without pipelining rose from 1.15 to 1.27 of Redis, and that is `epoll`'s doing.
  What stands in the way next is a `recv` and a `send` for each request and a user time
  2.6 times Redis's.
- Shards: replies as bytes paid off (+33% on two shards), requests as bytes did not. On
  three server cores one shard with a writer is still the best with a pipeline.
- In this runtime an iolist loses to gluing everywhere except short replies without
  pipelining.
- PGO gives +1…4%; it is now `make pgo`.

### 7.18. Shard laws for DBSIZE, KEYS and FLUSHALL

Before this round the shard laws (7.16) were proved for batches without DBSIZE, KEYS
and FLUSHALL: these three commands went to every shard, and the laws required the
hypothesis "they are not in the history or in the batch". Now the laws `shard_replies`,
`shard_holds` and `shard_bytes` have no conditions: after any history the sharded
server answers any batch the same way, and with the same bytes, as the single-threaded
one.

**Pieces by the root's digits.** A key's shard is set by the lowest digit of its hash,
the one the trie's root branches on. So DBSIZE, KEYS and FLUSHALL are cut into 16
pieces, one per digit of the root, and the piece of digit x goes to the shard that
holds subtree x: `owner(n, x) = x·n/16`, and `shard_of(n, h) = owner(n, hex(h))`. A
piece is an internal command of `redis.bend`: `SizeAt{x}` (the number of entries in
subtree x), `KeysAt{p, x}` (its keys that match the pattern) and `FlushAt{x}` (clearing
the subtree). Request parsing never produces them. The pieces' replies are merged by the
existing folds of `merge`: a sum (DBSIZE), a concatenation of arrays (KEYS), OK
(FLUSHALL). The earlier plan required a fact about machine words,
`(h & 15)·n >> 4 < n`: FLUSHALL cleared the shards `0..n-1`, and any key's shard had to
be among them. Here it is not needed: the proof holds for any mapping of digits to
shards, and the list of tries grows as needed.

**A structural invariant instead of a pointwise one.** The earlier proof rested on each
key reading in its shard as in the single database. For DBSIZE and KEYS this is not
enough: two tries that read the same can differ in the order of the entries in a bucket
(and so in the order of KEYS) and in empty nodes left after deletions. The new
invariant (`struct_seq`): under each digit of the root, that digit's shard holds exactly
the same subtree as the single database. The pointwise correspondence (`shard_holds`)
follows from it. The induction step rests on three lemmas about pieces:
- a piece changes only the subtree of its digit (`child_frame`);
- the subtree of its digit after it depends only on that subtree before it
  (`child_loc`);
- its reply also depends only on that subtree (`reply_loc`).

For a write by key this follows from two lemmas about the root: a read from the root
goes on in the subtree of the first digit (`get_root`), and a write from the root is a
write into that subtree, put back in place (`mod_root`, `with_child`). Both are 16-way
and 48-way case splits, written by `tools/gen_trie.py`. Then comes the fact that a
command equals its pieces: DBSIZE is the sum of the subtrees' sizes (`size_total`),
KEYS the concatenation of their keys filtered by the pattern (`keys_cats`: the filter
commutes with concatenation, and `tkeys` writes the trie's keys before the
accumulator), FLUSHALL the clearing of the subtrees in turn (`flush_db`).

**What changed in `map.bend`.** `size` and `keys` are defined through the root's
subtrees by digit (`size.at`, `keys.at`), and FLUSHALL clears the subtree of each digit
(`KV.clear`). A root that is not a node has no keys, as in a read. Before, `size` and
`keys` counted over the whole trie, including entries that are never built at the
root.

**Two compiler traps.** Both of the same kind as in 7.17: a change of calling
convention because of a new call site.
- The first version of FLUSHALL returned a root of 16 empty subtrees written as the
  constant `Node{Tip{}, …}`. Bend places constant constructors statically, and a
  constructor that may turn out static is never rebuilt in place (the fifth patch,
  7.9). In every `match` on `Node`, including `tmod_h` on SET's path, `ctr_own` changed
  to `ctr_take` with a copy of the node: +29% of instructions on SET and +28% on INCR.
  `make perfcheck` caught it (5,929 instructions on SET against 4,585 in the baseline),
  and comparing the generated C function by function found it. Now `KV.clear` clears
  the digits one at a time through `with_child`, and the node is built only from
  computed fields.
- `tsize` and `tkeys`, called on `child(t, x)`, got a fresh argument and became owning
  functions. An owning walk of a shared trie copies every node (`ctr_own_slow`), so
  every DBSIZE and KEYS would have copied the database. `size.at` and `keys.at` take the
  root apart themselves and pass `tsize` and `tkeys` a field of a lent node, as before;
  `child` remained only in the proofs.

After both fixes GET, SET and INCR cost 3,846, 4,582 and 4,828 instructions (the
baseline 3,850, 4,585 and 4,834). The generated C for `tmod_h`, `tsize` and `tkeys` is
the same as the old.

**Rare commands.** 100 thousand keys, two runs of each build interleaved, requests per
second (FLUSHALL in milliseconds):

| | DBSIZE | KEYS * | KEYS with a pattern | FLUSHALL |
|---|---:|---:|---:|---:|
| 1 shard, before | 76–80 | 9.0–9.8 | 13.1–13.3 | 43–47 |
| 1 shard, after | 77–79 | 8.6–9.1 | 11.8–13.0 | 47–49 |
| 3 shards, before | 190–198 | 9.4–9.9 | 19.6–21.3 | 31–32 |
| 3 shards, after | 195–205 | 14.6–17.5 | 20.0–21.8 | 23–38 |

On one shard everything is within the noise. KEYS * on three shards became faster; I
did not look into why. The replies are checked: KEYS * on three shards returns exactly
DBSIZE distinct keys.

**Checks.** Six mutations break the proof: a DBSIZE piece answering a size one too
large; a KEYS piece reading a digit not its own; a FlushAt that clears nothing; the old
`size = tsize`; DBSIZE without pieces; a FlushAt sent to the shard of digit 0. The tests
(`make test`, `tests/shard_check.bend` with 1, 2, 3, 4 and 16 shards) pass. The proof's
section on shards grew from ~1,250 to ~1,570 lines without comments, and the lemmas
about the root are ~530 generated lines more. All 25 laws check in ~1 s, with the
BendTT kernel in ~2 s.

### 7.19. The append-only file (AOF): Redis's format, proved recovery, group commit

**What is written.** With a file (`./bendkv PORT 1 post FILE [always|everysec|no]`)
the actor runs a batch through `exec_log` (`aof.bend`). This is `exec_all` that also
gathers the batch's effects: what it did, as commands. Reads (GET, EXISTS, MGET,
STRLEN, KEYS, DBSIZE, PING, ECHO) and errors have no effects. SET, SETNX, GETSET,
APPEND, DEL, MSET and FLUSHALL write themselves, even if they changed nothing (SETNX of
an existing key, DEL of a missing one; Redis does not write these, but the replay gives
the same database). INCRBY writes a SET of the new value, as Redis writes INCRBYFLOAT —
when the log is read, no number is parsed from text — and on an error nothing. The
command's reply decides what to write: there is no need to look into the database a
second time, and the database stays owned by the actor, without sharing (otherwise a
write would rebuild the path as a copy). The format is the same as Redis's AOF: an
array of bulk strings per command.

**What is proved** (`LAWS.bend`, section Persistence; ~1,150 lines of proofs without
comments, ~510 of them about a cut):
- `log_exec`: `exec_log` answers and changes the database exactly as `exec_all` does;
- `log_hints`: the actor runs a batch through `log_batch`, after the hints to the
  processor on its keys, as `exec_batch` does, and that is exactly `exec_log`;
- `log_replay`: a batch's effects, run on its initial database, give its final
  database;
- `log_args`: the effects of a client batch, written as request strings, `R.parse`
  parses back into themselves;
- `aof_load`: a file of entries reads as exactly these entries, with an empty leftover;
- `recover`: after any history of client batches the server restores from the file
  exactly the database it held;
- `recover_cut`: a file cut at any byte restores the database after some prefix of the
  history's commands;
- `load_cut`: the entries read, written again, together with the leftover give the cut
  file.

The least obvious part is the decimal round trip in `aof_load`. `Nat.show` writes the
last digit, then the digits of the quotient by 10, with the number itself as fuel, and
the division is `Nat.divmod.go` with a remainder counting up. The proof introduces
`quot10` and `rem10`, the quotient and the last digit "by steps of ten" (the pattern
`case 10n+m` is structurally recursive), shows that `divmod` by 10 gives them
(`divmod_10`: ten steps of `divmod.go` the checker just computes), that
`n = 10·quot10(n) + rem10(n)`, and that `Nat.show`'s fuel lasts (`le_quot`: a number
below 1 + g has a quotient below g). The digit `Nat.show` writes reads back by trying
the ten values of `rem10`, and the digit parser reads the string `show.go(f, n, acc)`
as "`acc`, continued from `n`" (`num_go`, induction on `Nat.show`'s fuel). Then come
`take`/`drop` over a concatenation for a bulk string's body, entries as an array, and
the loader with "the file's length" as fuel: an entry needs at least one byte
(`load_fuel`). Eight mutations break the proof where they break the code.

**Recovery.** At start the server reads the file, and `load` gives the entries and a
leftover. An empty leftover means the file is whole, and the database is the
`A.replay` of the entries. A leftover that starts with `*` and that the network parser
of `resp.bend` considers unfinished is an entry cut by a crash during a `write`: the
file is cut back to the last whole entry (`File.truncate`), as in Redis with
`aof-load-truncated yes`. Any other leftover means a refusal to start, as in Redis.

**A cut.** A crash leaves of the file a beginning `c`, where `c ++ d` is the whole
file, and the cut can fall on any byte. `recover_cut` proves that from `c` the server
brings up the database after the first j commands of the history, for some j, and
`load_cut` that the `encode` of the entries read, followed by the leftover, is `c`: the
server cuts off exactly the leftover. The proof has three steps. First, an entry cut
short never reads (`entry_cut`): a number line ends without its `\r\n` (`num_cut`), a
bulk lacks bytes or its `\r\n` (`bulk_cut`), and an entry lacks one of its bulks
(`bulks_cut`). For this Levi's lemma (`split`) takes apart the concatenation
`c ++ d = x ++ z`: either `c` is `x` and one more piece, or `c` is strictly shorter than
`x`. Then induction on the entries with the loader's fuel (`load_cut_go`): the loader
reads the first k entries and stops at the cut one. Finally, the entries are the
effects of the commands in order, and a command has zero or one effects
(`effect_one`), so the first k effects give the database of the first j commands
(`effs_prefix`): a command without an effect does not change the database. The bridge
between the history of batches and the list of its commands is `all_effs_cmds` and
`single_cmds`.

Five mutations test the proof. Two are real recovery bugs that the laws about a whole
file let through (with them all the earlier proofs still pass): a bulk cut in the
middle of its bytes reads as a shorter string, that is, a value nobody wrote
(`bulk.end` accepts the end of the file), and an entry cut between its arguments reads
as what had arrived: DEL a b c would run as DEL a b (`bulks` gives back what it read
when it runs short). Both break the proof of the cut (`bulk_end_cut`,
`bulks_cut_last`); the first is also caught by `tests/aof_check.bend` on its sample
("cut at 26 fails"), but the law is for any file. The third, a number line accepted
without its `\n` at the end of the file, is harmless in itself (the next bulk will not
read anyway), but the proof does not let it through either (`num_cut_cr`): it demands
strictness from every step. The fourth, a loader that loses the leftover, breaks the
old `aof_load` too. The fifth, a law that promises the whole database from a cut file,
does not prove.

The decision to cut remains trusted: that the leftover is the start of an entry and
not garbage, the server learns from the network parser of `resp.bend` (`cut_short`).
For a cut file a mistake there can only stop a start, not change the database; a law
of invertibility of `resp.bend`'s parser would close this link too.

**Compatibility with Redis.** `redis-check-aof` accepts BendKV's files as valid, Redis
7.0.15 loads BendKV's append-only file (moving it into its `appendonlydir`) and gets
the same data, and BendKV loads an append-only file written by Redis: `SELECT 0` parses
into a stub, `R.parse` understands command names in lower case, and Redis itself has
already rewritten GETSET as SET.

**The runtime: the twelfth and thirteenth patches.** In stock Bend `File.write` writes
a string in UTF-8, and there is no `fsync` at all. `File.write_raw` and `File.read_raw`
carry bytes as they are, `File.sync` is `fdatasync`, `File.truncate` is `ftruncate`.
`Chan.drain` takes everything a channel holds, without waiting.

**At first it was slow, and here is why.** The first version wrote each batch's
effects with a separate `write` through the runtime's pool of helper threads (that is
how all of Bend's file effects go) and with `always` did an `fsync` per batch. SET
without pipelining fell from 83 to 31 thousand/s even without `fsync`: the hop to a
helper thread and back (a signal, a pipe, waking the loop) cost ~20 µs per batch. With
`always` it came to 4 thousand/s against 35 thousand for Redis: an `fsync` on this disk
(ext4 on virtio) costs ~144 µs (`dd oflag=dsync`), and the batches of 20 clients synced
one after another. Redis, at each turn of its loop, appends the buffer of all clients
in one write and syncs once (`flushAppendOnlyFile` in `beforeSleep`). Two fixes:
- `File.write_raw` writes straight from the loop's thread, as Redis does: a write to
  the page cache almost never waits, and what waits for the disk is `File.sync`, which
  stayed on a helper thread;
- the actor, on getting a request, also takes all those that came while it worked
  (`Chan.drain`, up to 255), runs their batches one after another, writes the effects
  of all of them in one write, with `always` does one `fsync`, and answers them all with
  one `Chan.send_all`. By the law `enc_cat` the encoding of a concatenation is the
  concatenation of the encodings, so the file is the same as when written batch by
  batch.

One more finding concerns the hints to the processor. At first the log's path went
without them (`exec_log`, not `exec_batch`), and GET with a pipeline fell from
1.27–1.39 to 0.85–1.10 million/s. Now the actor runs a batch through `log_batch`, after
the same pass of hints, and the law `log_hints` proves that this is exactly `exec_log`.

**Measurements.** `redis-benchmark`, 20 clients, 200 thousand requests, keys from 100
thousand, 3-byte values; servers not pinned to cores on the 4-core VM; medians of three
interleaved rounds (the column "Redis, no log" is from the previous series), thousands
of requests per second:

| test | Redis, no log | Redis everysec | Redis always | BendKV, no log | BendKV no | BendKV everysec | BendKV always |
|---|---:|---:|---:|---:|---:|---:|---:|
| SET, no pipeline | 103 | 118 | 35 | 71 | 78 | 83 | 34 |
| SET, pipeline 16 | 781 | 627 | 209 | 1,389 | 1,163 | 1,227 | 309 |
| INCR, no pipeline | 101 | 114 | 36 | 77 | 86 | 82 | 35 |
| INCR, pipeline 16 | 813 | 581 | 251 | 1,600 | 1,163 | 1,020 | 289 |
| GET, no pipeline | 102 | 109 | 101 | 77 | 78 | 76 | 82 |
| GET, pipeline 16 | 763 | 787 | 778 | 1,266 | 1,681 | 1,370 | 1,342 |

- With `everysec` (the default of both) pipelined BendKV is faster than Redis with the
  same log: SET **1.96** times, INCR 1.76, GET 1.74. Without pipelining 0.70–0.72, as
  without a log in this setup (0.69–0.76: the path of a single command through the
  connection, the channel and the actor costs more; with a separate core for sending,
  section 7.16, BendKV is faster here too).
- With `always` and no pipelining both are bound by `fdatasync` and equal (34–35
  against 35–36 thousand); with a pipeline BendKV is faster: SET 1.48, INCR 1.15, GET
  1.73.
- The log costs BendKV 12% on pipelined SET with `everysec` (INCR is noisy:
  543–1,081 thousand in three rounds), and Redis 20% on SET and 29% on INCR. Without
  pipelining BendKV with a log is even faster than without one: an actor that takes a
  group of requests (`Chan.drain`) and answers them all with one `Chan.send_all` spends
  less per request. Pipelined GET with `no` gives 1,681 thousand against 1,266 without a
  log, for the same reason; this is worth carrying over to the actor without a log too.
- Before group commit and writing from the loop's thread it was: SET without
  pipelining 31 thousand (`no` and `everysec`) and 4 thousand (`always`); with a
  pipeline 368 and 56 thousand.
- **Recovery.** A log of a million SETs (53 MB): BendKV comes up in 1.62 s (from the
  start to the first PONG), Redis in 1.24 s. After loading BendKV has 261 MB of RSS
  against 122 MB for Redis: the Bend runtime's heap does not give back to the OS the
  memory where the file and the parsed entries lay (in the steady state BendKV needs
  half the memory Redis does, section 7.13).
- Without a log nothing changed: `make perfcheck` gives GET 3,855, SET 4,591, INCR
  4,836 instructions per request (the baseline 3,850, 4,585, 4,834), and the generated
  C of the hot functions matches the old one up to the offsets of static strings.

**Checks.** `make test`: the whole suite (robustness, the differential test,
concurrent clients) on a server with a log too, a restart from the file with a
comparison of all keys (20,411) and an entry cut short; `redis-check-aof` accepts the
file as valid. `make smoke` runs `tests/aof_check.bend`: a batch's log, its reading and
replay, and each of the file's 806 cut pieces. The twelfth and thirteenth patches are
checked by their own tests (`tests/io/file_raw.bend`, `tests/io/chan_drain.bend`) on
the interpreter and the C and JS lanes; the whole Bend test suite on the C lane
(`bend-patches/tools/c_lane_tests.py`) gives with them the same results as with eleven
patches, plus these two tests.

### 7.20. Groups of requests without a log too; a writer by the number of cores

**Groups.** The actor without a log now works as the actor with a log does (7.19): on
getting a request, it also takes all those that came while it worked (`Chan.drain`, up
to 255), runs their batches in turn (`B.exec_batch`, with hints) and answers them all
with one `Chan.send_all`. The shards' actors work the same way. The laws do not change:
batches still run one at a time, in the channel's order. The generated C changed only
in the actor itself. `make perfcheck` (20 clients, pipeline 16, under callgrind) gives
3,781, 4,518 and 4,765 instructions on GET, SET and INCR — 1.4–1.8% fewer than before;
the baseline is updated.

**A writer by the number of cores.** For one shard the replies were sent by a writer
thread by default (`post`). It pays off when it has a core of its own, and on one core
it only takes time from the loop (busy-waiting, 7.16). A server pinned by `taskset` to
one core loaded a million keys at 590–656 thousand/s with a writer and 742–820 thousand
without one; GET without pipelining, 77–81 thousand against 107–108 thousand. Now
`post` is on by default only when the process may use at least two cores
(`IO.thread_count`, that is, `sched_getaffinity`), and `send` otherwise. An explicit
choice still takes precedence.

**Measurements.** Redis's specs through `memtier` (section 7.15): runs of 15 s, three
interleaved trials, the median of the ratio to Redis 7.0.15, before → after:

| spec | 1 core, with a writer | 1 core, without a writer | 2 cores, with a writer |
|---|---:|---:|---:|
| load 1M keys, 100 B, pipeline 10 | 1.14 → 1.26 | 1.39 → **1.48** | 2.04 → **2.19** |
| GET 100 B, pipeline 10 | 1.09 → 1.06 | 1.21 → 1.21 | 1.44 → **1.53** |
| GET 100 B, no pipeline | 0.59 → 0.60 | 0.78 → 0.77 | 1.21 → 1.27 |
| GET 10 B, pipeline 100 | 0.92 → 0.97 | 1.37 → **1.46** | 1.26 → 1.36 |
| INCR, pipeline 10 | 0.87 → 0.92 | 1.04 → 1.02 | 1.31 → 1.32 |

The tail latency of the load (p99, ms): on one core with a writer 13.0–14.0 → 6.0–11.0,
without a writer 9.6–11.7 → 4.3–7.2, on two cores 7.9–8.4 → 3.7–4.2. On the other specs
p99 did not change.

Under `redis-benchmark` (20 clients, pipeline 16, 2 million requests, five interleaved
pairs) SET grew by 8% and GET by 21% (the pairs are noisy: 0.91–1.30), and INCR did not
change. Without pipelining the difference is ±4%.

What follows from this:
- **Groups give a little, but almost everywhere:** on two cores +1…7% on everything
  but INCR, and on one core reads move by ±3…7%. On loading new keys +3…12%, and the
  tail of its latency is two to three times shorter. A request's time goes to the
  connection (`recv`, parsing, encoding, `send`), not to scheduling the actor. Under
  load the request channel is not empty, and `Chan.recv` did not park before either. A
  group also delays the answers to its first requests to its end, hence −3% on GET with
  pipeline 10 with clients that wait for a reply before the next command.
- **A writer on one core hurt more than the groups help:** −12…28% on the load and
  about −25% on GET without pipelining. With the choice by the number of cores BendKV on
  one core is back at the level of section 7.15 and above: the load at 1.48 of Redis,
  GET with pipeline 100 at 1.46.

### 7.21. The append-only file on shards

**What was done.** With N shards and a file, each shard has a log of its own:
`FILE.0`, …, `FILE.(N−1)`; with one shard, `FILE` itself, which Redis loads too. A
shard's actor runs its part of each batch through `log_batch`, writes the group's
effects in one write, with `always` does its own `fsync`, and answers: the shards write
and sync their files in parallel, each with its own group commit. At start all the
shards restore their files at once, each on its own loop, and the main thread waits for
their databases over channels.

**FLUSHALL on shards.** A server with shards cuts FLUSHALL into `FlushAt` pieces:
clearing the subtree of one digit of the root on the shard that holds it (section
7.18). These pieces had no entry in the log, so the log was only for one shard. Now a
piece is written as the entry `FLUSHAT <digit>` (a hex digit). Only the log's loader
reads it: `A.parse_cmd` parses the name `FLUSHAT` itself and hands everything else to
`R.parse`. Network parsing does not know such a command, and clients do not see it.
`redis-check-aof` accepts the shards' files as valid (it checks the format, not the
command names). A shard's file with `FLUSHAT` cannot be loaded into Redis, but a
shard's file is only part of the database anyway.

**The laws.** With an entry for `FlushAt` the effects of any batch parse back into
themselves, and the hypothesis "the batch is a client's" left `log_args`, `recover` and
`recover_cut`: the laws of the log now hold for any batches, including the parts of
batches on a shard. The new laws (~60 lines of proofs):
- `shard_recover`: after any history each shard restores from its file exactly the
  database it held. A shard's history is its part of each batch (`shard_hist`). The
  lemma `shard_single` shows that this history brings the shard to its trie in
  `shards(n, hist)`: after the parts of a batch, the trie of shard s is its part run on
  its trie (`at_after`). Then `recover` works for the shard's history;
- `shard_restore`: so each key reads in the database its shard restored as in the
  single-threaded server's database (`shard_recover` together with `shard_holds`);
- `shard_recover_cut`: a shard's file cut at any byte restores the shard's database
  after some prefix of its own commands (`recover_cut` for the shard's history).

All 41 laws check, including in the BendTT kernel. Five mutations break the proof
where they break the code. The digit `a` read as `b`, a FLUSHALL piece not written,
`FLUSHAT` read as FLUSHALL: `effect_args` catches all three. A shard writing its
neighbor's part: `shard_single` catches it. A key looked up in the file of shard 0:
`shard_restore` catches it.

**What the laws do not promise.** The shards' files are restored each on its own.
After a crash each shard keeps a prefix of its commands, but together the shards do not
necessarily hold a prefix of the server's commands. A command cut into pieces by shard
(MSET and DEL of several keys, FLUSHALL) can survive on one shard and be lost on
another, and with `everysec` each shard loses its own last second. In memory such a
command is atomic (`shard_replies`); on disk it is not. Redis Cluster at this point
just refuses commands on keys of different slots (CROSSSLOT). A consistent cut would
need a common order of entries on the disk, for example a batch number in each entry
and recovery up to the last batch that is whole on all shards.

**The layout.** Keys are spread over the shards by their number (digit d to shard
d·n/16), so the files of a server with another number of shards do not fit, and the
server checks this. With one shard it refuses to start if there is a `FILE.0`. With n
shards, if there is a `FILE` (a one-shard file) or a `FILE.n` (a shard past the last).
And having restored a shard's database, if it holds keys of other digits (`strays`):
that is how a start with more shards than wrote the files is caught. `make test` checks
both refusals. Changing the number of shards will be possible after the append-only
file is rewritten as a snapshot.

**Measurements.** `redis-benchmark`, 20 clients, 200 thousand requests, keys from 100
thousand, servers not pinned to cores on the 4-core VM; medians of three interleaved
rounds, thousands of requests per second. Two shards send replies from their loops
(`send`, the default for several shards; with writers, without pipelining, it comes to
82 thousand against 125):

| test | Redis everysec | Redis always | 1 shard everysec | 1 shard always | 2 shards, no log | 2 shards everysec | 2 shards always |
|---|---:|---:|---:|---:|---:|---:|---:|
| SET, no pipeline | 110 | 38 | 91 | 35 | 116 | 122 | 35 |
| SET, pipeline 16 | 552 | 198 | 1,162 | 340 | 1,010 | 784 | 277 |
| INCR, no pipeline | 111 | 39 | 92 | 37 | 126 | 121 | 35 |
| INCR, pipeline 16 | 689 | 237 | 775 | 369 | 990 | 778 | 316 |
| GET, no pipeline | 108 | 102 | 82 | 87 | 125 | 125 | 129 |
| GET, pipeline 16 | 892 | 826 | 1,398 | 1,680 | 1,142 | 1,117 | 990 |

- Without pipelining two shards with logs are faster than one: SET 1.34 times (122
  thousand against 91), INCR 1.32, GET 1.52; and faster than Redis with the same
  `everysec`: SET 1.11 times, INCR 1.09, GET 1.16. The log costs two shards nothing
  here (116–126 thousand without it).
- With pipeline 16 on this VM one shard leads, as without a log (7.17): SET 1,162
  thousand against 784 for two shards and 552 for Redis. Two shards are still 1.42
  times faster than Redis, and the log costs them 22% on SET (1,010 → 784): each batch
  on keys of both shards takes two writes to two files instead of one.
- With `always` and no pipelining everyone is bound by `fdatasync` (35–38 thousand).
  With a pipeline one shard is faster than two (340 against 277 thousand on SET): a
  batch on keys of both shards waits for two `fdatasync` calls to two files on one
  virtio disk, and they overlap poorly. Redis: 198.

Redis's specs through `memtier` (section 7.15): the server on two cores (`taskset`),
`memtier` on the other two, runs of 15 s, three interleaved trials, all with a log at
`everysec`; thousands of requests per second (medians) and the median of the ratio to
Redis 7.0.15:

| spec | Redis | 1 shard | 2 shards | 1 shard / Redis | 2 shards / Redis |
|---|---:|---:|---:|---:|---:|
| load 1M keys, 100 B, pipeline 10 | 356 | 632 | 604 | **1.87** | **1.71** |
| GET 100 B, pipeline 10 | 882 | 1,383 | 895 | **1.57** | 1.02 |
| GET 100 B, no pipeline | 166 | 222 | 231 | 1.33 | **1.38** |
| GET 10 B, pipeline 100 | 1,324 | 1,521 | 1,537 | 1.17 | 1.15 |
| INCR, pipeline 10 | 737 | 1,194 | 803 | **1.59** | 1.07 |

With a log BendKV is faster than Redis with a log on all five specs, and in both
layouts. On two server cores one shard with a writer is still better than two shards
with a pipeline: its writer has a core of its own, while with two shards each loop both
parses requests and runs its shard. Without pipelining two shards are slightly ahead.
The load's p99: Redis 11.8–13.7 ms, one shard 6.6–10.4, two shards 9.2–10.2.
`make perfcheck` without a log: 3,782, 4,519 and 4,766 instructions on GET, SET and
INCR, as before.

**Recovery.** A log of a million SETs (53 MB), for two shards spread over two files of
26 MB each; the time from the start to the first PONG, medians of five runs (three for
Redis):

| server | time, s | RSS after loading |
|---|---:|---:|
| Redis 7.0.15 | 1.38 (1.18–1.51) | 121 MB |
| BendKV, 1 shard | 1.05 (0.77–1.18) | 261 MB |
| BendKV, 2 shards in turn | 0.85 (0.64–0.94) | 180 MB |
| BendKV, 2 shards at once | **0.44** (0.38–0.77) | 263 MB |

Simultaneous recovery is twice as fast as sequential and three times as fast as Redis.
Its memory peak is that of one shard: both files are read at once, and the runtime's
heap does not give memory back to the OS.

**Checks.** `make test` runs the whole suite (robustness, the differential test
against Redis, concurrent clients) on two shards with logs too. Then a restart from the
files of two shards: a random stream with a FLUSHALL in the middle (in the shards'
files these are `FLUSHAT` entries) plus 20 thousand keys, a comparison of the whole
keyspace (20,411 keys), an entry cut short at the end of shard 1's file, which the
restart cuts off, and the refusals at a start with one shard and with four. The same
restart, with a FLUSHALL in the middle, for one shard too.

### 7.22. A key hashed once

**What it was.** The key was hashed twice. The connection hashed the first argument of
each request for the hints to the processor (7.14), and then `exec` hashed the key
again to walk the trie. On shards, instead of the hints, `split` hashes the key: it
chooses the shard by the hash and puts the hash into the part of the batch
(`Part{c, h}`), and `exec` on the shard hashes again. FNV-1a on a 16-byte key is 135
instructions, and a pipelined request spent 270.

**What was done.** `R.exec.at(c, h, db)` runs a command with a ready hash of its key:
a command on one key (GET, SET, SETNX, GETSET, INCRBY, APPEND, STRLEN) walks the trie
with this hash, and the others hash their keys themselves, as `exec` does.
`R.exec_all.at` runs a batch with a list of hashes, and a batch now goes to the actor
together with the hashes of its keys. On one shard the connection takes them from the
requests (`B.req_hashes`: the hash of the first argument per request, in the order of
the commands). On shards the hashes come in the parts of the batch (`unzip`).

**The laws** (now 45 of them):
- `fits(c, h)`: a hash fits a command if it is the hash of its key (for a command on
  one key); any hash fits the others. `exec_at`: with a fitting hash `exec.at` is
  `exec`;
- `batch_hints`: a batch with hints and fitting hashes is `exec_all`. Before, the law
  held for any hashes; now the hashes take part in the execution and must fit. The same
  for `log_hints` for the log;
- `req_hashes`: the hashes the connection computes from the requests fit the commands
  the requests parse into. The proof goes through all 24 cases of the parser `parse_id`
  (and the forms of the arguments in each): a command on one key always takes its key
  from the first argument, and the others need no hash;
- `shard_hashes`: the part of a batch on a shard comes with fitting hashes. The
  existing proof about shards already shows that the parts are built from pieces
  `Part{c, hint(c)}` (`push_pieces`), and `hint(c)` fits any piece;
- `unzip_parts`: `unzip` splits a part into its commands and hashes, as `part_req` in
  `server.bend` does.

Six mutations break the proof: SET with hash 0 instead of the given one (`exec_fit`),
the hash of the command's name instead of the key (`id_fit`), "any hash fits GET"
(`exec_fit`), the batch's hashes in reverse order (`batch_hints`), an MSET piece with
the hash of the value (`pairs_eq`), INCRBY with its arguments mixed up (`id_fit`).

**The unexpected: delivery costs half.** The first version took the hashes from the
commands already parsed (`key_hash` for each command) and gave **+3.3…+4.0%** of
instructions instead of the expected −3.5%. A callgrind profile by function (the C
built with `-g`):
- `str_hash`: 270 → 138 instructions per request; the second hash really went away;
- reading the keys from commands the batch still needs: +86 (`slot_keep` +48,
  `rfc_wrap` +38). A command taken apart by `match` is unpacked into words, and each
  kept field gets a reference count. That is exactly why the hints were computed from
  the requests' words, not from the commands, before too (a comment in `batch.bend`);
- the loop `exec_all.go.at` over two lists: 142 instructions per request against 73
  for `exec_all.go`: the cells of the list of hashes are taken and freed one at a time,
  and the continuation holds an extra slot.

Hashes from the requests, as with the earlier hints, removed the reference counts. But
then it had to be proved that the hash of the first argument fits the command after
parsing: that is the law `req_hashes`. The outcome by `make perfcheck` (one shard,
pipeline 16): GET 3,781 → **3,721** (−1.6%), SET 4,518 → 4,473 (−1.0%), INCR 4,765 →
4,727 (−0.8%). On two shards (callgrind) GET 5,570 → 5,501 (−1.2%), SET 6,262 → 6,222
(−0.6%), INCR 6,582 → 6,543 (−0.6%). Of the 135 instructions saved, about half is
eaten by the second list. It would be cheaper to keep the hash next to the command in
one node, but that needs another type of batch throughout the server.

**Throughput** (`tools/bench_pairs.sh`: 100 thousand keys, 20 clients, pipeline 16,
the server on one core, eight interleaved pairs), medians of the ratios to the previous
build: GET 0.98, SET 1.03, INCR 1.04. User CPU time per request: GET 365 → 375 ns, SET
422 → 378, INCR 492 → 440. All this is within the spread between two builds of the
same C (±5–10%, section 9.6), so the reliable outcome is the instructions. The hash
became half as expensive per request. The next step seemed to be making the hash itself
cheaper (a hardware CRC32C), but breakdown 9.7 showed that the whole hash is now
1.1–1.5% of the time and does not stand on the path of misses: the gain would be under
1%. `tools/perf_baseline.txt` is updated: 3,718, 4,473, 4,729.

### 7.23. Five steps after breakdown 9.7, each on its own

After breakdown 9.7 all five items of the plan of the time (section 11) were done.
Each was built on its own on top of HEAD after 7.22 (`head`, the variants `v1`…`v5`),
then all together. Four items went into the server, and the hints over the whole group
(item 4) were measured and taken out: on balance they do not pay off, and they win only
on GETs whose keys all exist, without a pipeline.

How it was measured. Instructions per request by callgrind
([`tools/callgrind_req.sh`](../tools/callgrind_req.sh), 100 thousand keys); they are
deterministic to ~0.1% (without a pipeline to ~1.5%: there the actor's groups depend
on how the scheduler interleaves the threads). Time by interleaved pairs on fresh
processes, and each variant built in three code layouts
([`tools/layouts.sh`](../tools/layouts.sh): the same C, the functions in a shuffled
order), because two builds of one C differ in time by 5–10% (9.6). `pair_ratios.py`
and `memtier_specs.py` now fold the builds `NAME_sK` into one themselves. Even so, on
this VM a single run of 1 million requests wanders by ±15%, and two series of 12 runs
per variant gave 0.98 and 1.07 of `head` on GET for one and the same "all five" build.
So in time only what is bigger than ~5–8% shows reliably; smaller effects show in the
instructions.

**Item 1: cheaper RESP parsing** (`resp.bend`). The number in a `*N` or `$N` line is
read a character at a time right up to the `'\r'`, without `memchr` (lengths have one
or two digits, and a call to `memchr` with its register saves cost ~110 instructions),
and the line is walked once. Requests of one, two and three arguments (PING, GET, SET
and almost all the others) are built at once in order, without the list that `bulks`
used to reverse afterwards. An empty request (`*0` or an empty line) became a separate
case `OneNone`, and a batch no longer has to rebuild each request (`a <> as`) to tell
it from an empty one. Not done from the plan: `U32` instead of `Nat` (string indices in
Base are `Nat`, and converting there and back would sit on every `code_at`) and parsing
straight into `Cmd` (it needs a new law `req_hashes` for the new parser). A
tail-recursive version of `batch.go` gave +9 instructions and did not go in. RESP
parsing on GET: 1,562 → 1,221 instructions, on SET 2,037 → 1,654.

**Item 2: long reads without slow paths.** Done not in the runtime, as 9.7 suggested,
but in BendKV, plus a small runtime patch. A read stays one `recv` of up to 64 KiB, but
is parsed in windows: a window is at most 2,048 bytes from the first unparsed one,
copied into one chunk (`String.slice`), so `code_at`, `find` and `slice` always take
the fast path; the requests of all windows are one batch. A request longer than a
window is parsed in the rest of the buffer as it is: this happens once, when all its
bytes have come. A fresh read of up to 2 KiB already lies in one chunk and is parsed in
place. Two earlier tries did not help: gluing the whole read into one string (a chunk
is no longer than 2 KiB anyway) and reading 2 KiB at a time (9.7, item 5: the kernel
spent more). The fourteenth patch to Bend (`string-imm-index.patch`) gives
`String.code_at` a fast path for strings of up to 6 bytes that live in the term: INCR
reads its number digit by digit, and before, each digit went to `str_code_at_far` (9.7,
item 2). Running INCR: 1,649 → 1,473 instructions.

**Item 3: the writer is woken less often** (the fifteenth patch,
`writer-share.patch`). The event loop itself sends part of what is posted to the
writer. The loop and the writer measure what share of the time they work (in windows of
200 µs: the loop counts everything but waiting for events, the writer its `send`
calls). A loop less busy than the writer by more than 10 points sends itself: that is
many connections without pipelining, where a `send` costs more than the request
itself. Otherwise it posts, and the writer's core pays for the `send` (with a pipeline
the bottleneck is the loop). While the writer sleeps, the loop sends itself too,
without a futex, but after four such sends in a row the next post wakes the writer. A
socket's bytes go in order: the loop sends itself only when the writer has already sent
everything posted to that socket before. Three earlier versions:
- "send yourself while the writer sleeps": without a pipeline 1.00–1.02 under memtier,
  with pipeline 10 0.89–0.90;
- "…and when the loop has nothing else to run": without a pipeline +13…16% under
  memtier and +41% under `redis-benchmark`, but with pipeline 10 −2…−9%: the loop itself
  made `send` calls that with a pipeline the writer's core would have paid for;
- "…and the writer has already sent everything": nothing.

io_uring was not tried: entering a system call costs 114 ns here, and a `send` over
loopback 5–6 µs, so it is the network stack itself that is expensive, not the
transition into the kernel.

**Item 4: hints over the actor's whole group, measured and taken out.** The actor takes
at once the batches waiting in its channel (7.20): without a pipeline that is on
average ~28 batches of one request, at pipeline 16 ~6.6 batches of 16. The variant
walked the key paths of all the group's batches level by level (`B.touch_group`) and
then ran each batch without its own hints (`B.exec_hinted` with the overall result of
the hints); the law `group_hints` proved that a batch run this way is `exec_all` for
any result of the hints. The cost turned out bigger than the gain:
- at pipeline 16, **−6…−7%** in time on all three commands at +1% of instructions. By
  callgrind, the L1 misses in the hints and in running GET doubled (7.8 → 15.8 per
  request): the group's ~100 keys push each other's lines out of L1 before the batch
  gets to them, while one batch's hints (16 keys) fit in L1;
- without a pipeline, +600 instructions per request (a hint pass that a batch of one
  request did not have before, and the group's two lists), and in time 1.02/0.98 under
  `redis-benchmark` and 1.00 in the spec of GET without pipelining, within the noise;
- a variant in which only batches of one request get the group's hints, and a
  pipelined batch takes its own, equals the build without item 4 at pipeline 16, and
  without a pipeline under `redis-benchmark` falls behind it (1.11 against 1.15 of
  `head` on GET).

It paid off only on GETs whose keys all exist, at a million keys and without a
pipeline ([`tools/memtier_hits.sh`](../tools/memtier_hits.sh)): there each GET walks
the path to the value, there are more misses, and the build with this variant gives
1.34 of Redis against 1.23 without it. But in Redis's specs 90% of GETs look for
missing keys, and memtier with a pipeline sends one more request for each reply, so
batches of one request occur there even with a pipeline: the load with the variant
gives 1.04 of `head` against 1.12 without it, GET with pipeline 10 0.93 against 1.02.
On balance it does not pay off. On this VM without a pipeline the bottleneck is the
system calls, not memory: overlapping ~2.5 misses per request (~200 ns) costs ~600
instructions (~200 ns). The variant's code and the law `group_hints` with its proof
remain in the history (commit 468a84a).

**Item 5: a cheaper event loop.** Not the translation of `IO` into direct
continuations in the compiler, but the sixteenth patch (`effect-pairs.patch`): two
effects, each of which does in one step of the loop what used to take two. `Chan.call`
hands a batch to the actor and waits for its answer (instead of `Chan.send` and
`Chan.recv`), `TCP.post_recv_raw` posts a reply and at once waits for the next request
(instead of `TCP.post` and `TCP.recv_raw`). Each effect is a separate step of the loop:
the `do` continuation is applied through a closure, and the next effect is taken apart
and dispatched. Without a pipeline there were four such steps per request, now two, and
the event loop costs 5,827 → 3,812 instructions per GET. In `server.bend` these are
`conn_run` and `conn_reply` (one shard, replies posted, a batch without a protocol
error); the other cases go the old way. Translating `do` into direct continuations in
the compiler would remove the other closures too, but that is a rework of how `IO`
compiles for all programs.

**Instructions per request** (callgrind, 100 thousand keys; with a pipeline, one shard,
sending from the loop, 20 clients; without a pipeline, 50 clients, replies posted to
the writer, and its instructions counted too):

| | GET, pipe. 16 | SET, pipe. 16 | INCR, pipe. 16 | GET, pipe. 100 | SET, pipe. 100 | GET, no pipe. |
|---|---:|---:|---:|---:|---:|---:|
| `head` (after 7.22) | 3,729 | 4,473 | 4,731 | 5,657 | 8,482 | 11,080 |
| 1. RESP parsing | 3,471 (−6.9%) | 4,144 (−7.4%) | 4,474 (−5.4%) | | | 10,830 (−2.3%) |
| 2. long reads, `code_at` | 3,709 (−0.5%) | 4,464 (−0.2%) | 4,547 (−3.9%) | 3,447 (−39%) | 4,212 (−50%) | 10,927 (−1.4%) |
| 3. the loop shares sends | 3,737 | 4,472 | 4,724 | | | 10,984 (−0.9%) |
| 4. group hints (taken out) | 3,765 (+1.0%) | 4,513 (+0.9%) | 4,763 (+0.7%) | | | 11,712 (+5.7%) |
| 5. effect pairs | 3,671 (−1.6%) | 4,438 (−0.8%) | 4,694 (−0.8%) | | | 9,191 (−17%) |
| **1, 2, 3 and 5: the new HEAD** | **3,418 (−8.3%)** | **4,112 (−8.1%)** | **4,284 (−9.4%)** | **3,196 (−44%)** | **3,891 (−54%)** | **8,962 (−19%)** |
| all five | 3,450 | 4,135 | 4,319 | 3,220 | 3,909 | 9,529 |

By phase (`tools/phases.py`, GET with pipeline 16): RESP parsing 1,562 → 1,221, the
event loop 390 → 308, execution 596 → 577. Without a pipeline: the event loop 5,827 →
3,871, RESP parsing 1,889 → 1,490.

**Time, pipeline 16, one core** (`tools/bench_pairs.sh`: 100 thousand keys, 20
clients, the server sends itself; 4 pairs × 3 layouts, medians of the ratios to
`head`):

| | GET | SET | INCR |
|---|---:|---:|---:|
| 1. RESP parsing | 1.06 | 0.99 | 1.03 |
| 2. long reads, `code_at` | 0.99 | 1.02 | 0.98 |
| 3. the loop shares sends | 1.05 | 1.01 | 0.98 |
| 4. group hints | **0.94** | **0.94** | **0.93** |
| 5. effect pairs | 0.96 | 0.97 | 1.04 |
| 1, 2, 3 and 5 (second series) | 1.06 | 1.13 | 1.09 |
| all five (two series) | 0.98 and 1.07 | 0.96 and 1.07 | 1.00 and 1.05 |
| Redis (first series) | 0.65 | 0.61 | 0.71 |

**Time without a pipeline, two cores** (`redis-benchmark`: 50 clients on one core, the
server on two, replies sent by the writer; 3 pairs × 3 layouts):

| | GET | SET |
|---|---:|---:|
| 1. RESP parsing | 1.00 | 1.00 |
| 2. long reads, `code_at` | 1.03 | 0.94 |
| 3. the loop shares sends | **1.20** | **1.16** |
| 4. group hints | 1.02 | 0.98 |
| 5. effect pairs | 1.00 | 1.01 |
| 1, 2, 3 and 5 | **1.15** | **1.08** |
| all five (two series) | 1.07 and 1.10 | 1.06 and 1.01 |
| 1, 2, 3, 5 and item 4 only for batches of one request | 1.11 | 1.07 |
| Redis | 1.42 | 1.32 |

Here Redis is faster: under `redis-benchmark` (one client thread) BendKV with a writer
gets 0.70–0.76 of Redis's speed, the new HEAD ~0.80. Item 5 by itself does not change
the time: the loop spends 17% fewer instructions per request, but the bottleneck is the
sends on the writer. With item 3 the loop takes part of the sends for itself, and the
build 1, 2, 3, 5 equals item 3 alone within the noise.

**Redis's specs** (`memtier_specs.py`: the server on two cores, memtier on the other
two; 2 series × 2 layouts of 10 s; the ratio of ops/s to `head`):

| spec | 1 | 2 | 3 | 4 | 5 | 1, 2, 3, 5 | Redis |
|---|---:|---:|---:|---:|---:|---:|---:|
| load, 100 bytes, pipeline 10 | 1.16 | 1.18 | 1.11 | 1.11 | 1.14 | 1.12 | 0.58 |
| GET, 100 bytes, pipeline 10 | 0.96 | 0.97 | 0.95 | 0.97 | 1.06 | 1.02 | 0.70 |
| GET, 100 bytes, no pipeline | 0.97 | 1.01 | **1.12** | 1.00 | 0.99 | **1.11** | 0.82 |
| GET, 10 bytes, pipeline 100 | 1.03 | **1.27** | 0.93 | **0.84** | 0.98 | **1.26** | 0.74 |
| INCR, pipeline 10 | 1.01 | 0.99 | 0.93 | 0.95 | 1.01 | 1.03 | 0.72 |

On the load all variants are 11–18% above `head`, including those that do not touch
its path: the ratios share one denominator, and the `head` runs in this series came out
slow (p99 13.8 ms against 6–7 ms for the others), so the items cannot be told apart
here. The new HEAD against Redis in the same series: the load **1.93** (`head` 1.73),
GET with pipeline 10 1.46 (1.43), GET without pipelining **1.37** (1.23), GET with
pipeline 100 **1.69** (1.35), INCR 1.43 (1.39). GETs whose keys all exist (1 million
keys, 100 bytes, memtier on two cores, 3 series × 2 layouts): without a pipeline the
new HEAD is at 1.23 of Redis (`head` 1.13), with pipeline 10 at 1.37 (1.39).

**The outcome by item.**
1. RESP parsing: −7% of instructions on GET and SET, −5% on INCR; in time at pipeline
   16 GET +6%, INCR +3%, SET unchanged (at the edge of the noise); without a pipeline
   and in the specs it does not show.
2. Long reads: at pipeline 100 GET and SET cost 39% and 50% fewer instructions, and
   the spec of GET with pipeline 100 is **27%** faster; INCR −4% of instructions from
   the fourteenth patch. At pipeline 16 reads are short, and the item changes nothing.
3. The loop shares sends: **+15…20%** without a pipeline under `redis-benchmark` and
   **+12%** in the spec of GET without pipelining; with a pipeline 0.93–1.05, within
   the noise.
4. Group hints: −6…−7% at pipeline 16 and −16% on GET with pipeline 100 in the specs;
   the variant only for batches of one request gives +10% on GETs that all hit, without
   a pipeline, but loses in Redis's specs. Taken out.
5. Effect pairs: −17% of instructions without a pipeline and −1…2% with one; in time
   +6% on GET with pipeline 10 in the specs, otherwise it does not show: without a
   pipeline the bottleneck is sending.

The new HEAD (1, 2, 3 and 5): −8…−9% of instructions at pipeline 16, −19% without a
pipeline, −44…−54% at pipeline 100; in time +6…13% at pipeline 16 (one series; "all
five" in two series 0.96–1.07), +8…15% without a pipeline and +2…26% in Redis's specs
(except the load, where the items cannot be told apart). Tests: `make test`
(differential against Redis, concurrency, the log), `make smoke`, the proofs and the
BendTT kernel's verdict; the C lane of Bend's own tests with sixteen patches gives the
same results as with thirteen, plus three new tests. `tools/perf_baseline.txt` is
updated: 3,414, 4,104 and 4,270 (`make perfcheck` counts the `make build` build, which
has 4–14 instructions fewer than in the table above, where all variants are built the
same way).

### 7.24. No pipeline, parsing straight into `Cmd`, `IO` in continuations

Three items of the plan from section 11 after 7.23: (A) the gap with Redis without a
pipeline under `redis-benchmark`, (B) parsing a request straight into a `Cmd`, and (C)
an event loop without closures at the compiler's level. A is the seventeenth patch to
Bend, B a rewritten BendKV parser and the eighteenth patch (reading a string in place),
C the nineteenth patch: the compiler translates `IO` into direct continuations. Each
item was built on its own (A on top of 16 patches and HEAD after 7.23, B and C on top
of A), then B and C together. Measured as in 7.23: instructions by callgrind, time by
interleaved pairs, each variant in three code layouts.

**Item A: whoever keeps up sends** (the seventeenth patch, `writer-demand.patch`). Why
did BendKV with a writer lose to Redis without a pipeline under `redis-benchmark` (0.80
of it, 7.23), although it won under memtier? The difference is in the client:
`redis-benchmark` has one thread for 50 connections, and requests come one or two at a
time, while memtier has two threads of 50 connections each, and the loop does not keep
up. This shows in the loop itself: per wait for events (`epoll_wait`) there are 1.4–2
ready sockets under `redis-benchmark`, and 9–65 under memtier without a pipeline and
with pipeline 10, while the loop and the writer together are busy ~40% of the time
against 90–130%. When the loop keeps up with its sockets, handing a reply to the writer
only lengthens the path: the ring, waking the writer through a futex, its `send` on
another core, while the client waits. When it does not keep up, sends by the writer
free the loop. The fifteenth patch decided by the busy shares of the loop and the
writer, and without a pipeline both are small, so the loop almost always posted.

The new rule goes by demand. Over a span of 32 windows of 200 µs the loop counts how
many times it waited for events and how many ready sockets it got. While there are on
average fewer than four ready sockets per wait, the loop sends itself and at once; when
there are more (or it did not wait at all) two spans in a row, it posts to the writer.
It goes back to its own sends when the loop and the writer together are busy less than
60% three spans in a row; while the loop posts, the rule of the fifteenth patch
applies. The first variant decided by the instant busy share and flipped back and forth:
the writer's busy share goes stale after a wakeup, and the loop's jumps from window to
window; sums over a span and different thresholds in the two directions removed this.

Without a pipeline on two cores (`redis-benchmark`, 50 clients, 100 thousand keys,
three pairs × three layouts) GET is at **1.21** and SET at **1.26** of the build without
the patch; Redis in the same series is at 1.20 and 1.37 of it, so BendKV is at 0.93 and
0.90 of Redis (median; geometric mean 0.99 and 0.93). Nothing is lost with a pipeline:
at pipeline 16 on two cores 1.03/1.13/1.15 on GET/SET/INCR, in Redis's specs 0.98–1.07
(the load 1.43, but the base build came out slow in this series, as in 7.23).
Instructions per request on one core do not change: the patch touches only who calls
`send`.

**Item B: a request is parsed straight into a command.** Before, the parser gave a
list of words per request (`List<String>`), `R.parse` turned it into a `Cmd`, and the
keys' hashes were computed separately by `req_hashes`, in a second pass over the same
lists; the law `req_hashes` proved that the hashes fit the commands. Now GET, SET and
INCR (almost everything the server sees) read their arguments straight into the
command, and the others go through a list of arguments and `R.parse_id`. Each request
is a `B.Fit{cmd, hash, ok}`: the command, the hash it will go with, and a proof
`ok: fits(cmd, hash)` that this is the hash of its key (or any hash for commands
without a key). So the type checker checks every place where the parser chooses a hash.
The key's hash is computed right on the buffer (`String.hash_at`, without a slice), and
the proof is `{==}`: the definition of `String.hash_at` in Base is the `String.hash` of
the slice. At run time the proof is a constant. The law `fit_hashes` is restated for the
new parser: the commands and hashes of a batch, which the server takes from the list of
`Fit` values (`B.fit_unzip`), fit each other. There are still 45 laws.

The first version was more expensive than the old one (GET 3,473 instructions against
3,414): the number in a `$N` line was read by two native functions (how many digits,
then their value) and two `code_at` calls for the `"\r\n"`, and each one unpacked the
buffer's term anew. This went away in three steps:
- `String.dec_line_at` (the eighteenth patch) reads a line of digits with its
  `"\r\n"` in one pass and gives back the pair "number, length" as one word; for this a
  native function of several C parts learned to borrow its arguments. A number line
  cost 212 instructions and now costs 89;
- `String.to_upper` of a short string in the term, a whole word at a time (SWAR): a
  command's name 62 → 27 instructions;
- a batch of requests is kept from newest to oldest, and the server splits it into
  commands and hashes in one tail loop that also restores the order (`B.fit_unzip`).
  Before, the parser built the batch in order by non-tail recursion, and a `Fit`
  (unfolded by the compiler into 8 words) was copied through the stack frames of the WL
  machine.
A tail-recursive `batch.go` with a reversal at the end did not pay off (−13
instructions in parsing, +19 in the reversal) and did not go in. Parsing, the command
and the hash on GET now cost ~1,370 instructions against ~1,750.

**Item C: `IO` in direct continuations** (the nineteenth patch, `io-cps.patch`). In
Bend `IO(A)` is a function of the answer type `R` and a continuation `k`, and a `do`
block unfolds into `IO.bind(m, x => ...)`. The compiled `IO.bind(m, f, k)` builds a
closure `{f, k}` and applies `m` to it; when the effect `m` finishes, the runtime
applies the continuation, which applies `f(x)` through a stack frame, and the result to
`k`: four `CLO_APPLY` and two or three allocations for each bind. Without a pipeline
that was 14.5 `CLO_APPLY` per request, 1,428 instructions.

The compiler now translates definitions whose type ends in `IO(A)`: such a definition
takes `R` and `k` as its parameters (`fun_of` raises the arity by the body's lambdas),
and its body is translated. `IO.bind(m, f)` is `m` run with the continuation
`x => f(x)`, run with `k`; `IO.pure(x)` is `k(x)` (for a continuation the compiler
built itself, just a `let`); `let` and a match pass `R` and `k` into the body and into
each arm; any other `IO` value is applied to `R` and `k`. A call of an effect or a
definition with `IO` in its result becomes a direct call with a continuation, and the
continuation is one closure holding the rest of the block. One closure and one
`CLO_APPLY` remain per bind, when the effect calls it; `IO.bind` in BendKV is called
only from `main`, which the runtime runs for its `IO` value and which is not
translated. The theory does not change: this is a translation in the compiler only, and
the checker sees the same terms as before.

Two traps, both about types the compiler reads from annotations. Applying an `IO` value
to `R` and `k` has to be annotated at every step: for a chain of applications to a
variable the compiler drops the erased arguments (`anf`) and finds the places of the
live ones by the head's type, and without the type of the intermediate `m(R)` the
continuation `k` took the place of `R` and was lost. And a variable in a position where
its type is known from context can come without an annotation: then the type `IO(A)` is
passed down through the translation (from the definition's type, `IO.bind`'s arguments
and the arms' annotations), and if there is none at all, the value is applied to `k`
alone: `R` is erased anyway. Bend's tests found the second trap: all the TCP and UDP
tests failed to build. With the fix, the C and JS lanes of Bend's tests with nineteen
patches pass exactly the same tests as with eighteen, plus the new
`tests/io/io_cps.bend`; for BendKV `make test`, `make smoke`, the proofs and the BendTT
kernel's verdict pass.

Without a pipeline, `CLO_APPLY` per request: 7.1 calls in `send` mode (it was 14.5)
and 2.3 in `post` mode (only the applications of continuations after effects); indirect
branch mispredictions: 4.8 per request against 22.4.

**Instructions per request** (callgrind; pipeline 16: one shard sends from the loop,
20 clients; without a pipeline: 50 clients, and in `post` mode the writer's
instructions are counted too):

| | GET, pipe. 16 | SET | INCR | GET, no pipe., `send` | SET | GET, no pipe., `post` | SET |
|---|---:|---:|---:|---:|---:|---:|---:|
| base (17 patches) | 3,414 | 4,103 | 4,271 | 8,460 | 9,102 | 9,044 | 9,220 |
| B: parsing into `Cmd` | 3,028 | 3,591 | 3,887 | 8,296 | 8,811 | 8,700 | 8,793 |
| C: `IO` in continuations | 3,337 | 4,027 | 4,177 | 7,766 | 8,402 | 8,325 | 8,595 |
| B and C | **2,969** | **3,534** | **3,830** | **7,459** | **7,970** | **7,820** | **7,911** |

Together that is −13% on GET and SET and −10% on INCR at pipeline 16, and −12…−14%
without a pipeline.

**Time.** At pipeline 16 on one core (`redis-benchmark`, 100 thousand keys, four
pairs × three layouts) B, C and BC gave on GET, SET and INCR 0.95/0.95/1.06,
1.01/0.96/1.04 and 1.03/0.94/1.02 of the base — within the noise, although BC's user
time per request is 5–10% lower: the kernel here is almost half of a request's CPU
(~450 ns against ~500 ns of user time), and 12–14% of instructions is ~5% of CPU.
Without a pipeline on two cores (50 clients, three pairs × three layouts), 0.95/1.03,
0.92/1.00 and 0.89/1.00 on GET/SET, and in a second series, only the base and BC (five
pairs × three layouts), BC at 0.95/0.97. They have equal system calls per request (one
`recv` and one `send` each and 0.54–0.61 `epoll_wait`,
[`tools/iocount.c`](../tools/iocount.c)), BC adds no memory and no page faults, and in
long runs of a million GETs the base and BC are equal (92 and 90 thousand requests per
second against 90 and 90 thousand). Yet in both series B, C and BC have 0.3–0.9 µs more
kernel time per request with less user time (the kernel 6.4–7.7 µs per request, user
code 3.3–3.9 µs); we did not find the cause, and the difference is at the edge of the
noise. In Redis's specs (memtier, two server cores, two series × two layouts) all three
are at 0.98–1.03 of the base on GET and INCR, with pipeline 100 B at 1.12; on the load
all three are at 1.11–1.12, but the base in this series again came out slow (p99 12 ms
against 5–6 ms), as in 7.23.

| spec, share of Redis | base (17 patches) | B | C | B and C |
|---|---:|---:|---:|---:|
| load 1M keys, 100-byte values, pipeline 10 | 2.04 | 2.28 | 2.26 | **2.25** |
| GET, 100-byte values, pipeline 10 | 1.64 | 1.63 | 1.62 | 1.62 |
| GET, 100-byte values, no pipeline | 1.41 | 1.38 | 1.44 | 1.37 |
| GET, 10-byte values, pipeline 100 | 1.98 | 2.21 | 2.07 | **1.95** |
| INCR, pipeline 10 | 1.35 | 1.33 | 1.36 | 1.39 |

The outcome: A closed the gap without pipelining under `redis-benchmark` — the server
is now at 0.93–1.05 of Redis on GET and 0.90–0.98 on SET (three series) — and B and C
cut 12–14% of instructions, which on these loads weigh less than the noise: a request's
time is now mostly system time, and BendKV's user time at pipeline 16 is 0.37–0.51 of
Redis's, without a pipeline 1.1–1.3 of it.

### 7.25. After the review: a value's bytes within reach of the hints, a GET without a counter cell

The three items the outside review added to the plan (section 13) were each built on
their own on top of HEAD after section 13, measured and put through the criterion of
section 12: if the code gets more complex, the gain must pay for it. Instructions and L2
misses (a model in which the hints do not show) by callgrind
(`tools/callgrind_req.sh`, now with the value size `DATA`). Time on three loads, each
variant in three code layouts: GET hits with 100-byte values at pipeline 10 on one core
(`tools/memtier_hits.sh`, 1 million and 10 million keys), Redis's specs on two cores
(`memtier_specs.py`) and `redis-benchmark` with 3-byte values at pipeline 16 on one
core. A caveat: this VM has a 260 MB L3, and at a million keys the values lie in it (an
L2 miss is ~40 ns); a colleague's i9 has a 24 MB L3, and the same misses go to memory
there.

**Item 1: a hint that reaches the value's bytes.** Two steps:
- 1a (the twentieth patch, the runtime): `Mem.prefetch` of a buffer loads its bytes
  from the position where they start to the end of the buffer (up to four cache lines),
  not the first 64 bytes;
- 1b: a value a GET has already read is sealed (section 13), and the hint touches only
  its cell. To reach the buffer, the cell has to be read: a fourth pass over the batch
  (`Mem.prefetch_in`) read the cell pulled in by the third pass and hinted its buffer.

1b cost ~200 instructions on any request of a batch, even with 3-byte values (+6.7% on
GET, +4.6% on INCR), and lost in time: 0.98 on GET hits at a million keys, 0.93 on SET
and INCR with 3-byte values. Not taken. 1a by itself changes almost nothing: after the
first GET the values are sealed. It went in together with item 2.

**Item 2: a GET without a counter cell.** The cell appeared because GET's reply held
the value itself, which also lies in the trie. The review suggested encoding the reply
while the database is lent; it is simpler to answer with a copy made right there. Then
the value is only read, and the compiler does not seal it. `KV.get_copy.at` is a walk
like `get.at`'s, but the bucket answers `String.take(v, String.length(v))` (the 16-way
walk is written by `tools/gen_trie.py`), and `exec.at` calls it for GET. In theory a
copy of the whole string is the string itself (`take_len`), so a lookup with a copy
answers as the ordinary one does (`bget_c_eq`, `tget_kc_eq`, induction on the depth),
and the law `exec_at` is proved with one rewrite more; the number of laws is still
45. The copy costs an allocation and a `memcpy`, but saves a `slot_keep`, two atomic
count operations and a read of the cell before the bytes, and the copy of a string in
the word (up to 6 bytes) with the twentieth patch is the word itself: without it,
building the copy cost 77 instructions per GET.

| per GET (callgrind) | base | 1b | 2 (with 1a) |
|---|---:|---:|---:|
| 100k keys, 100 bytes, pipeline 10: instructions | 3,458 | 3,689 | 3,577 |
| the same: L2 misses | 5.10 | 5.13 | **4.46** |
| 1M keys, 100 bytes, pipeline 10: instructions | 3,531 | | 3,639 |
| the same: L2 misses | 6.72 | | **5.85** |
| 100k keys, 3 bytes, pipeline 16: instructions GET / INCR | 2,957 / 3,832 | 3,156 / 4,009 | 2,976 / 3,845 |

| time, ratio to the base (in parentheses, the base's user CPU per request to the variant's) | 1b | 2 without 1a | 2 |
|---|---:|---:|---:|
| GET hits, 1M keys, 1 core (5 rounds × 3 layouts) | 0.98 (0.94) | 1.02 (1.02) | 1.02 (1.045) |
| the same, 10M keys (4 × 3) | 1.03 (1.01) | | 1.015 (1.024) |
| specs, 2 cores (2 × 2): load | 1.04 | | 1.02 |
| GET 100 bytes, pipeline 10 / no pipeline | 1.00 / 1.00 | | 1.00 / 1.00 |
| GET 10 bytes, pipeline 100 / INCR | 0.96 / 1.03 | | 1.05 / 1.02 |
| `redis-benchmark`, 3 bytes, pipeline 16 (4 × 3): GET / SET / INCR | 0.99 / 0.93 / 0.93 | | 1.03 / 1.00 / 0.99 |

The series at a million keys, the specs and `redis-benchmark` were taken with the build
of item 2 without the fast path of `String.take` of a string in the word (it changes
only values of up to 6 bytes), and the series at 10 million with it. Memory at a million
keys of 100 bytes: 183.1 MB after loading, 183.3 MB after a GET of each key (before
item 2, 183.0 and 191.1).

Item 2 is kept, but it is at the edge. The gain in time on this VM is small: +1.5…2% on
GET hits, +5% on one spec, otherwise within the noise, but in no series worse than the
base. Memory no longer grows from reads (−8 bytes per key read, −4% with 100-byte
values). On GET there are 0.6–0.9 fewer misses and two fewer atomic operations, which
will tell more where the values do not fit in L3. The cost: +16/−6 lines of the runtime
(97 tokens of `comp.ts`), in BendKV ~25 lines by hand and 40 generated, in the proofs
~25 by hand and 40 generated, and no new laws. `make perfcheck`: 2,974, 3,549 and
3,846 instructions on GET, SET and INCR (it was 2,970, 3,532 and 3,828; SET and INCR
pay for the hints on the buffer's lines).

**Item 3: part of the hash in the bucket entry.** At a million keys a bucket holds on
average 0.95 entries, and a GET passing someone else's entry reads the other key's
bytes to compare. An entry would also keep the 12 bits of the hash left after the path
(`h >> 20`), and keys would be compared only when these bits match. It costs no memory:
an entry of three fields takes a block of four words anyway. A prototype without
proofs, against item 2:

| | ratio to item 2 |
|---|---:|
| instructions per GET: 100k keys / 1M (callgrind) | +14 / −49 (misses −0.52) |
| GET hits, 1M keys, 1 core | 1.01 |
| specs: load / GET p10 / GET no p. / GET p100 / INCR | 1.05 / 0.99 / 0.99 / 1.00 / 1.00 |
| `redis-benchmark`, 3 bytes: GET / SET / INCR | 0.97 / 0.96 / 0.97 |
| GET hits, 10M keys, 1 core | **1.07** |

A gain appeared only at 10 million keys. There a bucket holds ~9.5 entries, the trie is
overloaded, and the cure is the number of buckets (a sixth level), not a filter in the
chain. The proofs would have to be redone in all 111 places where an entry is taken
apart, and `U32.is_eq(h, h)` proved for a 32-bit vector. Not taken.

The outcome of the round: of the three items one went in — GET answers with a copy of
the value (with the hint reaching the buffer's bytes in the twentieth patch). A fourth
hint pass and part of the hash were measured and rejected. Tests: `make test`,
`make smoke`, the proofs and the BendTT kernel's verdict. The C and JS lanes of Bend's
tests with twenty patches pass the same tests as with nineteen, plus the new
`tests/base/value_reads.bend` on both; `io_stack_fault_trap` under parallel load once
missed the runner's 5 s, and alone it passes in 1–6 s, as before (7.14).

## 8. Why strings in Bend are lists

- **That is how the theory is built.** The BendTT kernel has no built-in types except
  inductive ones: `Nat` is `Zero`/`Succ`, `U32` is `Word(32n)` of bits, `Char` is
  `Chr{U32}`, `String` is a list of `Char`. Properties of strings are proved by
  ordinary induction and pattern matching, and string literals in patterns
  (`case "GET":`) work on the same basis. The kernel needs no axioms about "built-in
  strings", and the trusted base stays small (the kernel is checked in Lean).
- **Speed is brought back by "native views" in the runtime**, and they are added
  selectively. `Nat`, `U32` and `F32` are machine words, `Array` is a flat block.
  `String` got such a view only in the JS backend: there it is a JS string, and
  `String.length` is a built-in operation (2.0.7). The C runtime had the reference form,
  a list, until now.
- **The project openly admits it is a limitation.** The README says: "Strings are
  linked lists of characters, so text processing is slow". Lists get in the way even of
  the checker: only in 2.0.24 did a string literal become one `Lit` node, and before
  that 50 definitions of 1,000 characters took 4 s to check and 2.6 GB of memory.
- **Priorities and resources.** The project puts its weight on fast proof checking and
  parallel execution on CPU and GPU. Its runtime benchmarks are numeric and tree tasks:
  of the 17, only `lexer` works with strings. The GPU lane (Metal/CUDA) makes
  variable-length buffers with in-place updates noticeably harder, which is why my
  patch too turns packing on only for CPU programs. `WONTFIX.txt` has a CAPACITY
  section: a small team keeps the language to a size it can maintain.

## 9. Where BendKV still loses to Redis: a detailed profile

This VM has no hardware counters (the kernel reports "no PMU driver"). So the caches
and the branch predictor are modeled by valgrind (callgrind `--cache-sim --branch-sim`):
L1d of 48 KB, and the last level set to this machine's L2, 2 MB
(`--LL=2097152,16,64`). An L2 miss here is a trip to the shared L3, dozens of times
more expensive than an L1 hit. The caches are warmed by filling the database under the
same model. Kernel and user time is taken from `/proc/<pid>/stat`, system calls from
`strace -c`.

### 9.1. I/O is the same; the difference is in user code

- **Both servers** make 2 system calls per batch of 16 requests (a read and a write)
  and are bound by one core (~98%).
- **Per GET:** BendKV spends 2.0 µs in user code and 0.47 µs in the kernel, Redis 0.52
  and 0.37 µs. The lag is almost entirely in user code, 3.8 times.
- **It splits evenly.** There are twice as many instructions (7,000 against 3,500), and
  they run twice as slowly: 1.7 instructions per cycle against 3.2 (at a nominal
  2.1 GHz).

### 9.2. Memory and branches per request

| per request | PING | GET | SET | INCR |
|---|---:|---:|---:|---:|
| instructions, BendKV / Redis | 4,619 / 2,453 | 7,380 / 3,648 | 10,740 / 4,892 | 9,780 / 4,228 |
| L1d misses, BendKV / Redis | 1.6 / 1.0 | 29.8 / 6.7 | 38.0 / 7.9 | 26.6 / 5.2 |
| L2 read misses, BendKV / Redis | 0 / 0 | 12.7 / 2.8 | 14.8 / 2.8 | 7.3 / 1.4 |
| mispredicted branches, BendKV / Redis | 18.9 / 2.8 | 40.7 / 20.4 | 67.2 / 26.2 | 65.8 / 22.8 |

Here the database is filled more densely than in section 6 (86% of the key space
against 63%), so there are slightly more instructions on GET and SET.

BendKV's L2 misses on GET (12.7 in all):

| where | misses | what is read |
|---|---:|---|
| the descent through the trie (`tget_k`) | 7.6 | the nodes of the binary trie's 20 levels |
| the key comparison (`str_eq`, `memcmp`) | 2.2 | the key's node and its buffer |
| the bucket (`bget`), keeping the value (`slot_keep`) | 1.4 | the bucket's cell, the value's field |
| the value's length and copy (`str_len`, `memcpy`) | 1.5 | the value's node and its buffer |

Redis has 2.8 misses per GET: the table slot, the `dictEntry`, the `sds` key, the value
object, and a short value lies in one block with the object. On SET the descent with
path copying (`tmod_h`) gives 7.6 misses of 14.8. The descent through the trie is 60%
of the L2 misses on GET, half the L1d misses (14.5 of 29.8), and 11 mispredicted
branches: each level branches on a random bit of the hash.

### 9.3. Instructions: where the 7,000 per GET go

The functions' own cost (without their callees), instructions per GET:

| function | instructions | what it does and why it is expensive |
|---|---:|---|
| `str_append`, `str_copy`, `str_chunk` | 1,479 | gluing the reply and copies of the request's arguments (`String.take`): the chunks have no room for the next parts of the reply, and almost every part goes into a new chunk |
| `num_line` | 789 | parsing RESP numbers a character at a time; the first character is taken off and put back (`SCon{c, t}`), and into a shared buffer that is a new chunk |
| `term_drop` | 603 | freeing parsed requests, argument lists, intermediate strings |
| `str_take_slow` | 478 | reading from a shared buffer: `batch.go` holds the request buffer as `+s`, and every match starts by the slow path |
| `tget_k` | 373 | the descent through the trie's 20 levels |
| natives: `str_len`, `str_eq`, `str_hash`, `str_take_n`, `str_drop_n`, `str_upper` | 863 | the fixed cost of a call and of a pass over the chunks; `str_upper` turns the command's name to upper case |

Together that is 4,585 of 7,000. On SET two more items were added, both removed
together with the binary trie (7.6). The strict `Bool.pick` in `bset` built both
branches and threw one away: ~800 instructions of `term_drop`. `mk` rebuilt each node
of the path: ~1,100.

### 9.4. The gap grows with the number of keys

GET, pipeline 16, 20 clients, the binary trie (ops/s; with the 16-child trie, in 7.6):

| keys | BendKV | Redis | lag |
|---:|---:|---:|---:|
| 100 | ~950,000 | ~1,330,000 | 1.4× |
| 100k | 346,000 | 895,000 | 2.6× |
| 1M | 177,000 | 635,000 | 3.6× |

At 100 keys everything lies in L1 and L2, and only the difference in instructions
remains. Further on the depth of the trie every request passes through grows, and with
it the cache misses. The main reserve is the shape of the data: a wider, shallower trie
(16 children per node: 5 levels instead of 20) and strings whose node and bytes lie in
one block. The second reserve is the instructions of table 9.3. The 16-child trie is
already done (7.6); the rest is in section 11.

### 9.5. A time profile: the instructions caught up, the memory latency remained

After section 7.7 there are almost as many instructions per GET as in Redis (3,930
against 3,648), and the speed is 0.74 of Redis (section 10). Callgrind counts
instructions and models the cache, but does not say what a miss costs on this machine.
Without the processor's counters, sampling on a timer helps:
[`tools/sprof.c`](../tools/sprof.c) is loaded through `LD_PRELOAD`, a `CLOCK_MONOTONIC`
timer interrupts the process every 500 µs, and the signal handler records the address
of the instruction. The server is loaded 100% and pinned to a core, so wall time is CPU
time. Kernel time then falls on libc's system call wrappers (`send`, `recv`). The run is
[`tools/sprof_run.sh`](../tools/sprof_run.sh), the report
[`tools/sprof_report.py`](../tools/sprof_report.py). At this rate the server does not
slow down noticeably; at 50 µs it is twice as slow, and the shares are almost the
same.

GET, pipeline 16, a filled database of 100 thousand keys, shares of the samples (~5
thousand and ~3.7 thousand):

| item | BendKV | Redis 7.0.15 |
|---|---:|---:|
| lookup in the database | 27.0% (`tget_k`) | 20.6% (`dictFind`) |
| key comparison | 12.5% (`str_eq` 6.7: the key's node, `memcmp` 5.8: its bytes) | 5.8% (`dictSdsKeyCompare`) |
| access to the value | 10.9% (`str_len` 5.0: the value's node, the copy 5.9: its bytes) | 6.4% (`lookupKey`: the value object) |
| `send`/`write` | 19.5% | 23.9% |
| `recv`/`read`, `select`/`epoll_wait` | 6.1% | 10.4% |
| the rest: parsing, commands, reply, actors, allocator | 24.0% | 32.9% |

Inside `tget_k` the samples fall on three loads: the child at level 4 (21%), the child
at level 5 (36%) and the bucket's first entry (33%). Each is a dependent L2 miss.

Converting the shares into CPU time per request (1.57 µs for BendKV, 1.1 µs for
Redis), everything except the accesses to the map costs the same: system calls ~0.4 µs
for both, the rest ~0.37 µs. The difference is in the map itself: ~0.79 µs against
~0.36 µs. On GET BendKV has seven dependent misses: the level-4 node, the level-5 node,
the bucket entry, the key's node, the key's bytes, the value's node, the value's bytes.
Redis has four: the table slot, the `dictEntry`, the `sds` key, the value object (a
short value lies in one block with it).

Before section 7.7 the same samples showed another 5% on `brk` and `_int_malloc`: the
64 KB read buffer was taken and freed on every read, and glibc kept giving back the top
of the heap and taking it again. Now the buffer is reused (section 6).

### 9.6. CPU features and the compiler

Bend builds the generated C with `clang -std=c11 -O3`: without `-march`, that is, for
baseline x86-64 (SSE2), and without a profile. The program runs in one thread:
`IO.spawn` multiplexes connections in the I/O loop, and the thread pool opens only when
pure code forks. The machine is a VM on a Sapphire Rapids-class Xeon at 2.1 GHz
(AVX-512, 2 MiB of L2 per core). All the builds below are made from the same C of the
final server. Instructions were counted by callgrind, as in 9.2. Time by paired runs,
as in 7.13: each build runs against the clang 19 build in the same run, and the table
gives the median of the ratios.

**What is already used.**
- Out-of-order execution and branch prediction: the hot path's IPC is about 2. Jumps
  through the segment table `wl_tab` are predicted, and the descent through the trie
  does without a jump table (7.11).
- SIMD, through libc: `memcpy`, `memchr` and `memcmp` choose their AVX2/EVEX versions
  at load time (`__memcpy_avx_unaligned_erms` in the profile).
- 2 MiB pages (7.10).
- The `preserve_none` calling convention of clang 19: the runtime's segments save no
  registers. clang 18 silently ignores it: +9.8% of instructions on GET and +8.5% on
  INCR, and GET falls from 1.06 to 0.95 of Redis. The Bend driver without `CC` takes
  plain `clang`, which on this machine is version 18; `make` in BendKV sets
  `clang-19`.

**Instructions per request** (100 thousand keys, pipeline 16):

| build | GET | SET | INCR | `.text` |
|---|---:|---:|---:|---:|
| `-O3`, clang 19 (as now) | 3,280 | 3,985 | 4,209 | 202 KB |
| `-march=x86-64-v3` (AVX2, BMI2) | 3,235 (−1.4%) | 3,914 (−1.8%) | 4,195 (−0.3%) | 204 KB |
| PGO | 2,581 (−21%) | 3,012 (−24%) | 3,406 (−19%) | 168 KB |
| every `INLINE` as `always_inline` | 2,749 (−16%) | 3,318 (−17%) | 3,657 (−13%) | 331 KB |
| CRC32C hash instead of FNV-1a | 3,246 (−1.0%) | 3,954 (−0.8%) | 4,196 (−0.3%) | 202 KB |

No build changes the L2 misses: 2.4 on GET, 2.8 on SET, 3.0 on INCR. The profile for
PGO was taken on the same load (SET, GET, INCR and PING from `redis-benchmark`), so
this is an upper estimate.

**Throughput against the clang 19 build** (GET / SET / INCR, the number of pairs in
parentheses):

| build | 1k keys | 100k keys | 1M keys |
|---|---|---|---|
| `-march=x86-64-v3` | | 0.91 / 0.96 / 0.96 (10) | |
| `-march=native` | | 0.99 / 0.98 / 0.99 (5) | |
| PGO | 1.04 / 0.99 / 1.12 (4) | 1.03 / 1.03 / 1.08 (14) | 1.11 / 1.07 / 1.04 (6) |
| PGO and `x86-64-v3` | | 1.01 / 1.00 / 1.04 (5) | |
| every `INLINE` as `always_inline` | | 0.95 / 1.01 / 1.06 (5) | |
| CRC32C hash | 1.09 / 1.14 / 1.19 (4) | 1.01 / 1.07 / 1.11 (9) | 1.14 / 1.04 / 1.02 (6) |
| Redis 7.0.15 | 0.94 / 0.90 / 0.97 (4) | 0.86 / 0.86 / 1.06 (14) | 0.98 / 0.92 / 0.98 (6) |

Over all 24 pairs PGO gives 1.05 / 1.05 / 1.08, and the CRC32C hash over 19 pairs
1.09 / 1.07 / 1.07.

**The server's CPU time per request, ns** (in user mode + in the kernel, medians of
the same series):

| keys | GET: BendKV | GET: Redis | SET: BendKV | SET: Redis | INCR: BendKV | INCR: Redis |
|---|---:|---:|---:|---:|---:|---:|
| 1k | 369 + 431 | 466 + 362 | 390 + 434 | 562 + 372 | 444 + 397 | 446 + 384 |
| 100k | 862 + 384 | 960 + 403 | 904 + 418 | 1,094 + 397 | 1,016 + 450 | 984 + 384 |
| 1M | 1,128 + 406 | 1,209 + 384 | 1,204 + 406 | 1,350 + 403 | 1,306 + 569 | 1,331 + 603 |

What follows from this:

1. **Vector extensions do not help.** The hot code is dependent loads, branches and
   copies of 2–5 words. There is nothing to vectorize here, and long strings already go
   through libc's SIMD functions. Even `-march=native` gave not a single 512-bit
   instruction, only 256-bit ones (some in the AVX-512 encoding): clang vectorized a
   few loops over bytes and fields, but the strings and nodes in requests are short.
   With `x86-64-v3` the server is even 4–9% slower, and the map benchmark
   (`bench/bench_map.bend`) 4–9% faster. This is the lottery of code layout: two builds
   of one C differ by ±5–10% even with almost the same instructions. So an effect under
   ~5% does not show in one series.
2. **PGO is the only flag with a steady gain:** −19…−24% of instructions and +5…+8% of
   throughput over all pairs. Most of it came from inlining. The `spin_*` loops are
   tail recursion folded into a loop: parsing a RESP line, the search in a bucket,
   taking fields. The hot ones have several call sites each, and without a profile
   clang does not inline them; an inline threshold four times the usual
   (`-inline-threshold=1000`) does not reduce the instructions. Then their results go
   through memory (`THR Term* o`), and the prologue saves registers. With a profile the
   hot calls are inlined, and the cold code shrinks (`.text` 168 KB against 202).
   Inlining everything (`always_inline`) gives three quarters of the same reduction
   (−16%), but the code grows 1.6 times, and the gain in time disappears. Which calls
   are hot the Bend compiler does not know without a profile. The realistic path is a
   driver mode: build with `-fprofile-instr-generate`, run a training load, merge the
   profile with `llvm-profdata merge` and rebuild with `-fprofile-instr-use`.
3. **A hardware hash.** `String.hash` (FNV-1a, added by the fourth patch) on a 16-byte
   key is a chain of 16 dependent multiplications, ~64 cycles right before the lookup's
   first miss. CRC32C with the `crc32` instruction (SSE4.2), 8 bytes at a time, takes
   ~13 cycles. The instructions are almost the same (99 against 135 per hash: walking
   the string's chunks costs more than the bytes themselves). In time, +7…+9% over all
   pairs (from +1 to +19% in separate series) and −8% per operation in the map
   benchmark. This is more than the ~50 cycles saved are worth (2–3% of CPU per
   request), so part of the gain is the same layout lottery. Both hashes spread keys
   over the buckets the same way: at 100 thousand and a million keys `key:%012d`, 1.04
   and 1.48 key comparisons per key found. The definition in Base can be replaced:
   CRC32C is defined byte by byte in Bend and gives the same value as the instruction 8
   bytes at a time. On other architectures the native implementation is a table.
4. **The main reserve is memory parallelism.** The trie always has five levels, so a
   request runs the same instructions at a thousand keys and at a million. So the
   difference in time is waiting for memory. It costs ~490–570 ns per request at 100
   thousand keys (56–57% of user time) and ~760–860 ns at a million (66–68%). Redis has
   as much. The processor can keep dozens of misses in flight at once, but a key lookup
   is a chain of dependent loads, and the misses go one at a time. Valkey 8 does this:
   before running a batch of up to 16 commands it prefetches the dictionary entries for
   all their keys (memory access amortization). By
   [their data](https://valkey.io/blog/unlock-one-million-rps-part2/), the time in
   `lookupKey` falls by 80%, and throughput grows by almost 50% (with I/O threads). For
   BendKV this is a batched pass over the batch's keys, and in Bend it needs a pure
   prefetch operation: in meaning the identity, in C a `__builtin_prefetch` on the
   term's node. This was done in section 7.14: +47…+69% at 100 thousand and a million
   keys.
5. **The rest is not the compiler.** Kernel time (~0.4 µs per request: from a quarter
   of the CPU at a million keys to half at a thousand) does not depend on the build: it
   is the runtime's `select`, `read` and `write`. The processor's other cores would need
   sharding: a heap and an I/O loop of its own for each core.

### 9.7. A breakdown after section 7.22: where the time goes now

**The machine.** From this section on, another VM: a Cascade Lake Xeon at 2.8 GHz, 4
vCPUs, 32 KiB of L1d and 1 MiB of L2 per core, 33 MiB of L3 (shared with other VMs),
Linux 6.18 under Firecracker; there are no processor counters here either. Absolute
numbers are not comparable with the earlier sections; the ratios to Redis were taken
anew, in the same series. The server is HEAD after 7.22, with Redis 7.0.15.

How it was counted. Instructions by function: callgrind on a build of the same C with
`-g` ([`tools/callgrind_req.sh`](../tools/callgrind_req.sh)); the `spin_N` loops are
named after the Bend definitions they run
([`tools/spin_names.sh`](../tools/spin_names.sh)), and the functions are summed into the
phases of a request ([`tools/phases.py`](../tools/phases.py); natives like
`str_code_at_far` and `term_drop` are counted in the phases of their callers). Time:
sprof sampling (9.5) and the server's CPU time from `/proc` in pairs with Redis
([`tools/bench_pairs.sh`](../tools/bench_pairs.sh)).

**1. CPU time per request** (pipeline 16, 20 clients, the server on one core, ns:
user + kernel, medians of 3–5 pairs):

| keys | GET: BendKV | GET: Redis | SET: BendKV | SET: Redis | INCR: BendKV | INCR: Redis |
|---|---:|---:|---:|---:|---:|---:|
| 1k | 510 + 440 | 510 + 430 | 600 + 430 | 770 + 420 | 660 + 500 | 660 + 480 |
| 100k | 520 + 370 | 1,070 + 450 | 620 + 470 | 1,220 + 490 | 630 + 460 | 1,140 + 480 |
| 1M | 720 + 430 | 1,460 + 480 | 720 + 450 | 1,520 + 500 | 820 + 730 | 1,680 + 590 |

Throughput against Redis: 0.84 / 1.03 / 0.96 at a thousand keys, 1.50 / 1.57 / 1.52 at
100 thousand, 1.68 / 1.55 / 1.57 at a million. Hence the main points:
- **When everything is in the cache, BendKV and Redis spend the same:** 510 ns of user
  time per GET for both. The instructions are about equal too: 3,717 for BendKV, 3,648
  for Redis (9.2).
- **At 100 thousand keys the hints (7.14) hide the memory waits entirely:** BendKV has
  the same 520 ns as at a thousand, while Redis loses 560 ns to memory. At a million
  BendKV has ~210 ns of waiting left (29% of user time), Redis ~950.
- **So BendKV's user time is now almost all instructions.** To make it smaller, fewer
  instructions must run; memory at 100 thousand keys no longer gets in the way.
- **The kernel costs both the same:** 0.37–0.50 µs per request, 42–46% of BendKV's
  CPU.

**2. Instructions per request by phase** (callgrind, the same conditions, 100 thousand
keys):

| phase | GET | SET | INCR |
|---|---:|---:|---:|
| RESP parsing: bytes → lists of words | 1,562 (41%) | 2,037 (45%) | 1,535 (32%) |
| command parsing: words → `Cmd` | 337 | 413 | 390 |
| hash and hints | 563 | 574 | 586 |
| execution: trie, key comparison, value | 596 | 785 | 1,650 |
| reply | 361 | 334 | 239 |
| actor and channels | 38 | 38 | 38 |
| event loop: I/O, `do` closures | 381 | 374 | 381 |
| total | 3,717 | 4,472 | 4,729 |

(The functions' own costs add up to ~3% more than the total: callgrind counts some
jumps between segments twice.) **RESP parsing is the largest: 41–45% of the
instructions.** On GET it is `num_at`, 683 instructions for three numbers (`*2`, `$3`,
`$16`), ~230 per number: the search for `'\r'` with a call to `memchr` (~110 with the
call and the register saves, although a number has one or two digits), a
`String.code_at` per digit, and `Nat` arithmetic with overflow checks (`nat_chk`). Then
`bulk_at` 304, the copies of the command's name and the key (`str_slice`) 230, `one`
and `batch.go` 247, the reversal of the list of words 63. Together with the command
parsing this is ~1,900 instructions per GET; in time RESP parsing is 13.7% for BendKV,
2.6% for Redis (item 3).
INCR's execution takes ~1,650: two passes over the trie, reading the number digit by
digit (`str_code_at` on a number of 1–6 digits goes to the slow `str_code_at_far`,
because the fast path does not know short strings in the term: 146 instructions), and
`Nat.show` of the new number (130).

**3. Shares of time** (sprof, GET, pipeline 16, 100 thousand keys; wall time, so the
kernel's share here is higher than by `/proc`: it also includes idling in
`epoll_wait`):

| phase | BendKV | Redis |
|---|---:|---:|
| kernel: `send`/`write`, `recv`/`read`, `epoll_wait` | 53.8% (`send` 41.1%) | 36.7% (`write` 24.7%) |
| RESP parsing | 13.7% | 2.6% |
| command parsing and lookup | 3.4% | 6.3% |
| hash and hints | 12.0% (`touch_if` 9.5%, `str_hash` 1.5%) | — |
| execution | 6.7% | 36.8% (`dictFind` 23.5%) |
| reply | 3.9% | 2.8% |
| actor, channels, event loop | 6.0% | — |
| allocator and reference counts | (inside the phases) | 7.6% |
| other | 0.4% | 7.2% |

On SET and INCR the picture is the same: RESP parsing 13–17%, hints 12%, the kernel
42–46%.

**4. Without a pipeline** (50 clients): `redis-benchmark` itself is bound at ~85
thousand ops/s, so only the CPU time per request can be compared: BendKV 2.9 + 6.6 µs,
Redis 2.5 + 7.3 µs. By samples of CPU time, system calls are 66–74% for BendKV and
74–80% for Redis, and one `send` alone 51–59%. The rest for BendKV: the event loop and
continuation closures 9–12%, the descent through the trie without hints 8–9% (a batch
of one request has nothing to overlap), parsing 3–5%. With a writer on the second core
(`post`) the same test gives 67 thousand instead of 86 thousand: the loop spends 17% of
its CPU on `pthread_cond_signal` (waking the sleeping writer through a futex), and the
writer 47% on waiting in its loop.

**5. Large reads: access to a string past its first chunk is a slow path.** A chunk of a
packed string holds at most 2 KiB: its position takes 11 bits of the term (section 4). A
longer read is several chunks, and `code_at`, `find`, `slice` past the first chunk go by
a slow path that walks the chunks from the start: an access costs O(number of chunks). At
pipeline 100 a batch of GETs is ~3.7 KB, and GET costs **5,649 instructions instead of
3,717**, 2,117 of them in the slow paths (`str_code_at_far` 1,421, `str_find_far` 480,
`str_slice_far` 216). Under memtier with pipeline 100 this is 20% of the loop's samples.
A try in BendKV alone: reading at most 2 KiB (together with the tail of the previous
read, glued into one chunk) makes GET at pipeline 100 cost 3,455 instructions. But then
the client's batch is cut into parts, and the kernel time per operation grows from ~100
to 245–270 ns: GET with pipeline 10 and 100 over three pairs at 0.94–1.08 of HEAD, with
no gain. The load with 100-byte values (pipeline 10) gains +9…+30% from it, and its p99
is 2.5–3 times shorter (18 → 6–9 ms): a read of 64 KiB was parsed in time quadratic in
the number of chunks. This should be fixed in the runtime, so that a read stays one
system call: a long chunk for the bytes received, or an access past the first chunk in
O(1).

**6. Redis's specs** (memtier, the server on two cores, memtier on the other two, two
pairs of 10 s each), the ratio of ops/s to Redis:

| spec | 1 shard and a writer | 2 shards |
|---|---:|---:|
| load, 100 bytes, pipeline 10 | 1.92 | 1.86 |
| GET, 100 bytes, pipeline 10 | 1.44 | 1.00 |
| GET, 100 bytes, no pipeline | 1.19 | 1.32 |
| GET, 10 bytes, pipeline 100 | 1.13 | 1.12 |
| INCR, pipeline 10 | 1.21 | 0.91 |

On two cores two shards lose to one with a writer wherever there is a pipeline: each
batch is cut across both shards and gathered back. On this machine the lead is smaller
than on the previous one (7.17: GET with pipeline 10 at 1.72–1.78), because system
calls are more expensive here (items 1, 4), and their price is the same for both.

**7. The hash.** `str_hash` is 135 instructions (3.6% on GET) and 1.1–1.5% of the
time. It is computed in the connection, long before the descent through the trie, so
its latency does not stand on the path of misses. CRC32C would save under 1%. The
speedup the hardware function gave in 9.6 (+7…+9% in pairs) has nothing to come from
now: then the hash was computed twice, the second time right before the lookup's first
miss.

What follows from this is in section 11.

## 10. The overall picture

**Allocations per request** (pipeline 16):

| request | original Bend | + lazy sealing | + packed strings and BendKV |
|---|---:|---:|---:|
| PING | 130 | 66 | 23.5 |
| SET | 392 | 187 | 62 |
| GET | 305 | 153 | 35 |
| INCR | 421 | 229 | 68 |

Of the 62 allocations per SET, 24 are the copy of the path in the trie (nodes of 32
bytes). This is the next large item of cost, and a directory array (7.5) would remove
it. The third patch (borrowed reads) does not change these numbers: GET 34.4, INCR
68.5. The same saving used to come from the hand-written `find`; now the compiler gives
it (section 5).

**Throughput, pipeline 16 (ops/s):**

| | PING | SET | GET | INCR |
|---|---:|---:|---:|---:|
| Redis 7.0.15 | 1,612,903 | 892,857 | 1,123,596 | 934,579 |
| BendKV, original Bend | 531,915 | 116,414 | 84,034 | 94,697 |
| BendKV, + lazy sealing | 574,713 | 166,667 | 129,702 | 130,719 |
| BendKV, + packed strings and BendKV | 1,282,051 | 374,532 | 374,532 | 290,698 |
| speedup over the original | ×2.4 | ×3.2 | ×4.5 | ×3.1 |
| lag behind Redis | 1.3× | 2.4× | 3.0× | 3.2× |

**Without pipelining (ops/s; here the numbers are bound by network latency):**

| | PING | SET | GET | INCR |
|---|---:|---:|---:|---:|
| Redis 7.0.15 | 98,328 | 103,199 | 109,170 | 102,459 |
| BendKV, original Bend | 117,096 | 63,980 | 61,312 | 58,140 |
| BendKV, + lazy sealing | 114,286 | 74,963 | 71,276 | 70,423 |
| BendKV, + packed strings and BendKV | 114,155 | 100,604 | 99,305 | 91,912 |

**Loading ~950 thousand keys (pipeline 64):**

| | loading, ops/s | RSS memory | bytes per key |
|---|---:|---:|---:|
| original Bend | 40,428 | 513 MB | ~570 |
| + lazy sealing | ~80,000 | 370–380 MB | ~410 |
| + packed strings and BendKV | ~250,000 | 156 MB | ~170 |
| Redis | ~885,000 | 116 MB | ~130 |
| BendKV after sections 7.6–7.12 | ~746,000 | 75 MB | ~78 |
| + a string of one chunk without a node (7.13) | ~862,000 | 60 MB | ~63 |
| Redis in the same series | ~729,000 | 122 MB | ~128 |

The last three rows are one series (server and client pinned to cores, medians of
three runs); in it Redis loads more slowly than in the first series without pinning.

A 1 MB value: SET ~20 ms, GET 18–20 ms (it was ~100 ms; Redis 1–2 ms). With `find`
instead of the third patch GET took ~25 ms: the value was copied (section 5).

The throughput tables were taken before the third patch. With it the speed is the same
within the noise (section 5): `find` already gave it by hand.

**With native strings** (section 6) there are 6,999 instructions per GET instead of
11,159, and 10,463 per SET instead of 14,054. In one run with Redis at pipeline 16: GET
420 thousand ops/s against 901 thousand, SET 418 thousand against 667 thousand, INCR
347 thousand against 952 thousand. A 1 MB value: SET 4.4 ms, GET 1.4 ms (Redis 1.1 and
1.0 ms).

**After section 7.7** (pipeline 16, a filled database of 100 thousand keys, 600
thousand requests per test; the server pinned to one core, `redis-benchmark` to
another; medians of five interleaved runs). In parentheses, the server's CPU time per
request: user + kernel, ns.

| | GET | SET | INCR |
|---|---:|---:|---:|
| Redis 7.0.15 | 888,889 (717 + 383) | 805,369 (900 + 350) | 816,326 (800 + 400) |
| BendKV, 16-way trie (section 7.6) | 497,100 (1,483 + 450) | 479,616 (1,633 + 433) | 419,287 (1,950 + 417) |
| BendKV, section 7.7 | 657,174 (1,183 + 383) | 654,308 (1,100 + 383) | 470,588 (1,700 + 433) |
| BendKV / Redis | 0.74 | 0.81 | 0.58 |

GET +32%, SET +36%, INCR +12%. The kernel time is the same for both. The difference is
in user time, and almost all of it is memory latency in accessing the map (section
9.5). INCR lags more: it reads the old value (the node and the bytes), parses it, writes
the new one and frees the old one.

With `make bench` (FLUSHALL before each test, so GET with random keys reads an empty
database) BendKV at pipeline 16 holds 0.98–1.23 of Redis on PING, GET and SET, and
INCR 0.65. Without pipelining, 1.18–1.32 (README).

**After sections 7.8–7.12** (the same conditions, interleaved pairs; detailed tables in
7.8, 7.9 and 7.12), the ratio to Redis:

| | GET | SET | INCR |
|---|---:|---:|---:|
| section 7.7 (above) | 0.74 | 0.81 | 0.58 |
| short strings in the term (7.8) | 0.86 | 1.01 | 0.74 |
| a node in place (7.9) | 0.96 | 0.97 | 0.74 |
| 2 MiB pages (7.10) | 1.02 | 1.02 | 0.80 |
| selection by digit, `int_read`, `str_eq` (7.11–7.12) | 1.05 | 1.09 | 0.87 |
| a string of one chunk without a node (7.13) | 1.21 | 1.10 | 0.96 |
| batch hints to the processor (7.14) | 1.62 | 1.82 | 1.45 |

The rows 7.9–7.12 were taken in one series (7 pairs), the row 7.13 in another (in it
7.12 gave 0.97, 1.01 and 0.90), the first two in their own. The row 7.14 is the median
over three series (13 pairs); two of them also had the 7.13 build, and there it gave
1.10, 1.12 and 0.95. The spread of the ratio between series is ±0.06–0.08: in the
series of section 7.9 the same state gave 0.92, 0.96 and 0.75.

**On several cores** (sections 7.16 and 7.17). Redis's specs on two server cores, with
a writer and `epoll`: the load at 1.98–2.07 of Redis, GET with pipeline 10 at
1.72–1.78, without pipelining at 1.27. On three server cores with `loadgen` on the
fourth:

| | GET, pipeline 10 | 50% SET, pipeline 10 |
|---|---:|---:|
| Redis, 3 io-threads | 436 | 403 |
| BendKV, 1 shard and a writer | 897 (2.06) | 841 (2.09) |
| BendKV, 1 shard and a writer, PGO | 939 | 893 |
| BendKV, 3 shards | 816 (1.87) | 802 (1.99) |

Thousands of ops/s, medians of three runs; the row with PGO is from a separate series,
where the same server without PGO gave 905 and 859.

**After section 7.23** (the VM of section 9.7; Redis's specs, the server on two cores,
memtier on the other two, the ratio of ops/s to Redis in the same series):

| | load, pipe. 10 | GET, pipe. 10 | GET, no pipe. | GET, pipe. 100 | INCR, pipe. 10 |
|---|---:|---:|---:|---:|---:|
| HEAD after 7.22 | 1.73 | 1.43 | 1.23 | 1.35 | 1.39 |
| after 7.23 | **1.93** | 1.46 | **1.37** | **1.69** | 1.43 |

At pipeline 16 on one core (`redis-benchmark`, 100 thousand keys) HEAD after 7.22 gave
1.55, 1.64 and 1.41 of Redis on GET, SET and INCR, the new one 6–13% more still (one
series). Without pipelining under `redis-benchmark` (one client thread, 50
connections), with a writer, Redis is faster: BendKV is at 0.70–0.76 of it, after 7.23
at ~0.80.

**After section 7.24** (the same VM, another series; the specs with the server on two
cores):

| | load, pipe. 10 | GET, pipe. 10 | GET, no pipe. | GET, pipe. 100 | INCR, pipe. 10 |
|---|---:|---:|---:|---:|---:|
| after 7.23 and the seventeenth patch | 2.04 | 1.64 | 1.41 | 1.98 | 1.35 |
| after 7.24 | **2.25** | 1.62 | 1.37 | 1.95 | 1.39 |

Ratios to Redis in one series; in this series the base ran the load slowly (p99 12 ms
against 5–6 ms for the variants), so the difference in the first column is noise. At
pipeline 16 on one core, **1.86, 1.83 and 1.54** of Redis on GET, SET and INCR (the
base 1.79, 1.84 and 1.50). Without pipelining under `redis-benchmark` with a writer,
0.93–1.05 of Redis on GET and 0.90–0.98 on SET in three series (~0.80 before the
seventeenth patch).

## 11. What else can be done

RESP parsing and building the reply are done (section 7.7), short strings live in the
term (7.8), a node is rebuilt in place (7.9), the heap is on 2 MiB pages (7.10), the
descent through the trie goes without a jump table (7.11), a string of one chunk has no
node (7.13), the misses of different keys of a batch overlap (7.14), sending runs on a
separate thread, and shards work, and for all commands it is proved that they answer as
a single-threaded server (7.16, 7.18). The event loop runs on `epoll`, shards return
replies as bytes, and the server is built with a profile (7.17), and the append-only file
is written in groups (7.19), including on shards (7.21); the actor takes groups of
requests without the append-only file too (7.20); a key is hashed once (7.22). Of the
plan after the breakdown in 9.7, four items of five are done (7.23); of the next plan,
the first three: the gap without a pipeline, parsing straight into `Cmd`, and `IO`
without closures (7.24). Of what the outside review added (section 13), GET with a copy
of the value, whose bytes the hints reach, went in (7.25); the fourth pass of hints and
part of the hash in the bucket entry were measured and not taken. In order of the
expected gain:

1. **The kernel is now most of a request's time.** Without a pipeline a request takes
   6.4–7.7 µs of kernel time (one `recv` and one `send` each and ~0.6 `epoll_wait`) and
   3.3–3.9 µs of user time, at pipeline 16 ~450 ns and ~500 ns; for Redis the kernel
   costs the same. Next is fewer calls per request: answering several connections with
   one system call is impossible (TCP has no `sendmmsg`), but one can avoid waking the
   loop on every request (`epoll_wait` that waits until several sockets come in, if the
   client keeps many requests in flight) and try `io_uring`: entering the kernel costs
   114 ns here, but batching the sends and receives of different sockets also removes
   the pass through the network stack on each call. Separately: explain the +0.3…0.9 µs
   of kernel time per request of the 7.24 builds with the same calls (7.24).
2. **Send buffers without `malloc`.** In `post` mode the `malloc`, `free` and `realloc`
   of the post buffers cost ~690 instructions per request without a pipeline
   (`tcp_post_recv_raw_run` copies the reply into a new buffer, the writer frees it),
   more than all closure applications after 7.24. A ring of buffers per writer or a pool
   per thread would remove almost all of it.
3. **The rest of the event loop.** Without a pipeline in `post` mode the loop is ~3,100
   instructions per request: the connection code (531), `recv` with a buffer (327),
   `io_run` (287), `io_cbuf_add` (227), `corpus_eval` (221), entering a task
   (`ENTER`, 162). The continuation after an effect still travels through a task node
   (`ENTER` → `CLO_APPLY`); it could be applied at once. The compiler could also
   translate lambdas that return `IO` into continuations (the explicit `next` in
   BendKV's slow path); that needs closures with more than one argument.
4. **RESP parsing is another ~1,370 instructions per GET** together with the hash:
   number lines (268), the slice and hash of the key (180 and 128), the headers and
   tails of `$N` strings (~300). Next is a native function for a string's whole header,
   or parsing a lent string in the compiler once into a pointer and a length, rather
   than in every native function.
5. **Access to a string past its first chunk in O(1) in the runtime.** BendKV gets
   around it with windows (7.23), but any other Bend program that reads a string longer
   than 2 KiB by index goes the slow way: the position in a chunk takes 11 bits of the
   term.
6. **Interleaving tasks in the runtime.** The batch hints are written by hand. The Bend
   runtime already runs code in segments with explicit continuations. On a load that
   will probably miss, it could issue a prefetch and switch to another pure task: the
   same gain without manual batching, for any program. Manual hints over the actor's
   whole group did not pay off here (7.23).
7. **PGO in the Bend driver, and clang 19 or newer.** BendKV already has a build with a
   profile (`make pgo`, 7.17); the Bend driver does not have it yet. Separately, a small
   fix to `cc_find`: take clang 19 or newer when there is one, because clang 18 silently
   ignores `preserve_none`.
8. **INCR in one pass.** INCR reads the value (`get.at`) and writes the new one
   (`set.at`): the second pass along the path comes from the cache, but costs ~400
   instructions and a second key comparison. One operation "change a key's value" would
   walk the path once. It needs the law `alter(t, k, f) = set(t, k, f(get(t, k)))` in
   `LAWS.bend`.
9. **Ownership where the caller no longer needs the value** (the compiler has a
   function borrow a parameter whenever it can keep the fields; a function that rebuilds
   a node is better off owning it, 7.6), and parsing a lent value with an unboxed
   layout: now each of its pointer fields gets a reference count (7.14).
10. **Propose the patches to `bendlang/bend`.** Three things stand in the way: the
   regression on the `lexer` benchmark (section 4), the cost of 2 MiB pages for short
   programs and programs with a large heap (section 7.10), and the size cap of
   `comp.ts` (`gates/repo.ts`): 64 thousand `ttok` tokens. The original `comp.ts` has
   62,940 of them, with our patches 101,094. The repository's rules require shrinking
   the file by simplification, not by moving code out, so the patches will have to be
   squeezed for upstream. The first to propose is lazy sealing: it has the best ratio of
   gain to cost, and it fits into the headroom below the cap (section 12). Then the
   nineteenth: it changes the compilation of `IO` for any program, and Bend's tests (C
   and JS) pass with it as they do without it, plus its own.
11. **More buckets on a large database.** The trie has five levels, 2^20 buckets: at a
   million keys a bucket holds ~1 entry on average, at 10 million ~9.5, and GET walks a
   long chain, reading other keys (7.25: part of the hash in the entry gave +7% there,
   and ~1% at a million). A sixth level (2^24 buckets) for databases of more than a few
   million keys. The map's laws are proved by induction on the depth of the walk, so the
   rework, by estimate, comes down to the root and the places where the depth is written
   as the number 5.

## 12. The gain and the cost of each change

All changes since the start of the project — twenty patches to Bend (p1…p20) and the
BendKV edits (sections 7.N) — on one scale: how much each gave and how much it cost. The
patch numbering here is the one from before section 14: there p16 was removed, and
p17…p20 became 16…19; there too, by this scale, the shards, the key hashed once, p16 and
`TCP.post_list` (iolist) were removed. The gain is the best reliable measurement on the
load the change was made for: time, and where time is in the noise (±5–15%, sections
7.23 and 9.6), instructions or memory. The cost is the growth of `comp.ts` in `ttok`
tokens (the Bend repository limits this file by them: a cap of 64 thousand, the original
has 62,940, with the patches 103,088), the lines of BendKV's code and proofs, and what
lines do not measure: a new data representation, threads, heuristics with tuned
thresholds, non-local effects.

The tokens are counted from the commits of the patch branch (the fourth patch is four
commits, the seventh two):

| patch | `comp.ts` tokens | `comp.ts` lines | outside `comp.ts` |
|---|---:|---:|---|
| 1. lazy sealing | 442 | +46/−3 | — |
| 2. packed strings | 3,232 | +334/−12 | TCP effects, `base.bend` |
| 3. borrowed reads | 1,648 | +168/−22 | — |
| 4a. native strings | 4,327 | +428/−6 | `base.bend` |
| 4b. reading by index, forms with literals | 4,129 | +382/−12 | `base.bend`, `tcp_recv.c` |
| 4c. a string of up to 6 bytes in a word | 1,728 | +168/−12 | — |
| 4d. comparing one-chunk strings | 372 | +36/−1 | — |
| 5. a node in place | 925 | +80/−17 | — |
| 6. 2 MiB pages | 108 | +11 | — |
| 7. selecting a field by digit | 3,209 | +298/−16 | — |
| 8. blobs | 1,618 | +189/−43 | — |
| 9. a hint to the processor | 248 | +19 | `base.bend` |
| 10. loops on threads, the writer | 3,350 | +408/−55 | ~270 lines of effects |
| 11. `epoll`, `TCP_NODELAY`, `post_list` | 3,625 | +368/−16 | ~80 lines of effects |
| 12. files as bytes, `fsync` | 0 | — | ~150 lines of effects |
| 13. `Chan.drain` | 0 | — | ~80 lines of effects |
| 14. `code_at` of a string in a word | 39 | +3 | — |
| 15. the loop shares the sends | 1,151 | +108/−4 | — |
| 16. effect pairs | 0 | — | ~100 lines of effects |
| 17. whoever keeps up sends | 536 | +95/−44 | — |
| 18. reading a string in place | 1,708 | +149/−11 | `base.bend` (+67) |
| 19. `IO` in continuations | 2,221 | +171/−1 | — |
| 20. a hint to a buffer's bytes, `take` of a string in a word | 97 | +16/−6 | — |
| 21. the process and the clock (now the twentieth) | 108 | +16/−2 | three effects, `base.bend` (+21) |
| 22. a node instead of a record wider than 32 words (now the twenty-first, section 16) | 67 | +9/−3 | — |
| 23. a native `String.order` (now the twenty-second, section 39) | 617 | +56/−1 | — |
| 24. a socket with no room holds up only its own posts (now the twenty-third, section 40) | 2,649 | +278/−49 | — |
| 25. the append-only file on the disk at any size (now the twenty-fourth) | 0 | — | `base.bend`, effects `file_sync.c/.js` |
| 26. waiting on a channel and a socket at once (now the twenty-fifth, section 41) | 0 | — | `base.bend` (+16), effects `chan.c/.js` |
| 27. a shared field of a spare node (now the twenty-sixth, section 41) | 193 | +15 | — |
| 28. a socket's addresses, killing it, channel marks (now the twenty-seventh, section 44) | 635 | +55 | `base.bend` (+32), effects `tcp_name.c/.js`, `tcp_kill.c/.js` |
| 29. a file in another's place, a name removed (now the twenty-eighth, section 47) | 0 | — | `base.bend` (+15), effects `file_rename.c/.js` |
| 30. the heap's account `IO.heap` (now the twenty-ninth, section 48) | 3 | ±3 | `base.bend` (+7), effects `heap.c/.js` |
| 31. words outside the heap `Mem.touch`, `Mem.cell` (now the thirtieth, section 48) | 341 | +33 | `base.bend` (+15) |
| 32. trees lent to the walkers that read them (now the thirty-first, section 51) | 822 | +69/−1 | — |
| total | 40,148 | | |

Tests for the patches are not in the table. A map (p is a patch, 7.N a section):

```
          cheap                                      expensive
manyfold  p1 sealing, p9 hints,                      p2 packed strings
          7.6 16-way trie, group commit, p23
+20…50%   7.7 parsing and reply, 7.23 windows, p17   p4a/p4b natives, p8 blobs, p10 writer
+5…20%    p6 2 MiB pages, 7.20 groups                p11 epoll, p4c string in a word, p7, p15
in noise  clang 19, PGO, p14, p4d, 7.23 RESP,        p5, p16, p18+7.24B, p19, 7.22, shards
          p20 + GET with a copy (7.25)               part of the hash in the entry (7.25, not taken)
minus     iolist                                     hints per group (removed),
                                                     a pass through the cell (7.25, not taken)
```

**1. A large gain at a small cost.**

| change | gain | cost |
|---|---|---|
| p1 lazy sealing (section 3) | +43…53% with pipelining, loading ×2, memory −28% | 0.44k tokens; the subtle spot is a CAS race for the field |
| p9 and the batch hints (7.14) | ×1.5–1.7 at 100k and 1M keys, +27…35% in the specs | 0.25k tokens; in BendKV ~200 lines and the law `batch_hints`; −5…11% at a thousand keys; they do not reach the bytes of values longer than 6 bytes (section 13) |
| the 16-way trie (7.6) | GET ×2.25, SET ×2.1, INCR ×1.6; memory −32% | +170 lines of code and +1,380 lines of proofs, but the matches over 16 and 256 cases are written by a script, and the laws are the same |
| group commit of the append-only file (7.19, p12–13) | `always` ×8.5, `everysec` ×2.7 without pipelining | 0 tokens, ~230 lines of effects |
| parsing, the reply, choosing the command (7.7) | GET +32%, SET +36%, INCR +12% | +96 lines of BendKV (on the forms of p4b) |
| windows for long reads (7.23, item 2) | pipeline 100: +27%, instructions −39…50% | an edit of `resp.bend` |
| p17 whoever keeps up sends (7.24) | without pipelining GET +21%, SET +26% | 0.54k tokens, but it is a second heuristic on top of p15 |
| p23 a native `String.order` (section 39) | ZRANK of a member among equal scores: 8.5 times fewer instructions, among their own scores 2.1 times | 0.62k tokens; ~50 lines of C that must match the definition in Base |

**2. A large gain at a high cost.**

| change | gain | cost |
|---|---|---|
| p2 packed strings, with 7.1–7.4 | ×2.2–2.9 with pipelining, loading ×3, memory −58% | 3.2k tokens; a second representation of `String` in the whole runtime; `lexer` 1.3–1.7 times slower |
| p4a native strings (section 6) | GET +17%, INCR +26%, instructions −26…37%; a 1 MB value 3.6–11 times faster | 4.3k tokens; ~340 lines of C that must match Bend's definitions (the trusted base) |
| p4b reading by index and the forms (`"lit" ++ s`, `Nat.show ++`, `eq` with a literal) | together with 7.7 +12…36%; the share of the forms and the share of the parser cannot be separated | 4.1k tokens; recognizing forms in the C generator |
| p8 blobs (7.13) | GET +25%, at a million keys +15…21%; memory −20% | 1.6k tokens; a fourth representation of a string |
| p10 the writer (7.16) | on two cores +8…36%, p99 of loading 2.5 times lower | 3.35k tokens and ~270 lines of effects; threads, futex, busy-waiting; on one core it hurt until 7.20 began to turn it on by the number of cores |

**3. A medium gain at a high cost.**

| change | gain | cost |
|---|---|---|
| p11 `epoll`, `TCP_NODELAY` (7.17) | without pipelining +10% (kernel −30%), with pipelining +18%, loading +14%, p99 three times lower | 3.6k tokens, three subtle bugs along the way; but `select` does not hold more than 1,024 descriptors and walks them all on every wait, so a server in Bend needs it |
| p4c a string of up to 6 bytes in a word (7.8) | GET +7%, SET +17%, INCR +19% — mostly on short values (`xxx` of `redis-benchmark`, counters); 100-byte values do not fall here | 1.7k tokens; a third representation of a string |
| p7 selecting a field by digit (7.11) | +3…9% together with 7.12 | 3.2k tokens; a narrow pattern that only the trie needs |
| p15 the loop shares the sends (7.23) | without pipelining +15…20% | 1.15k tokens, a heuristic; after p17 it acts only in post mode, and its contribution has not been remeasured since |

**4. A medium and small gain almost for free.**

| change | gain | cost |
|---|---|---|
| clang 19 (`preserve_none`, section 6) | −7…11% instructions | `CC=clang-19` |
| p6 2 MiB pages (7.10) | +5…19%, more at a million keys | 11 lines; the cost falls on other programs: start +0.4 ms, large heaps +0.4–0.9 s in the kernel |
| PGO (7.17) | +1…4% | a build script |
| p14 `code_at` of a string in a word (7.23) | INCR −4% instructions | 3 lines |
| p4d comparing one-chunk strings (7.12) | `str_eq` on GET 200 → 124 instructions | 0.37k tokens |
| groups and the writer by the number of cores (7.20) | +1…7%, loading +3…12%, p99 of loading 2–3 times lower; on one core the writer no longer takes away 12…28% | +36 lines |
| RESP parsing (7.23, item 1) | −7% instructions, GET +6% with pipelining | an edit of `resp.bend` |
| p20 and GET with a copy of the value (7.25) | GET hits +1.5…2%, user CPU −2…4%, memory does not grow from reads, −0.6…0.9 misses per GET | 97 tokens; ~50 lines by hand and ~80 generated in code and proofs, no new laws |

**5. Little or nothing at a noticeable cost.**

| change | gain | cost |
|---|---|---|
| the key hashed once (7.22) — removed in section 14 | −1…1.6% instructions, time in the noise | +4 laws and +500 lines of proofs — the worst ratio |
| shards (7.16–7.18, 7.21) — removed in section 14 | with pipelining down to −33% against one loop with a writer; without pipelining +7%, with the append-only file +32…52%; recovery 2.4 times faster | `shard.bend` and `wire.bend` (635 lines), ~2,900 lines of proofs |
| p5 a node in place (7.9) | −10% instructions on SET and INCR, time in the noise | 0.9k tokens; the one-word write of p7 rests on it |
| p16 effect pairs (7.23, item 5) — removed in section 14 | −17% instructions without pipelining; in time only +6% in one spec | 0 tokens, but ~100 lines of effects and a separate fast path in `server.bend` |
| p18 and parsing straight into `Cmd` (7.24) | −11…13% instructions, time in the noise | 1.7k tokens and +274 lines of BendKV (while the proofs got 197 lines shorter) |
| p19 `IO` in continuations (7.24) | −2…8% instructions, `CLO_APPLY` halved, time in the noise | 2.2k tokens — but it works for any program with `IO` |
| iolist, `TCP.post_list` (7.17) | down to −30%, except short replies without pipelining | stayed only for merging the shards' replies; removed in section 14 |
| hints per group (7.23, item 4) | −6…7% | removed |
| a pass of the hints through the cell (7.25) | 0.98 on GET hits, 0.93 on SET and INCR of short values | not taken: +200 instructions per request |
| part of the hash in the bucket entry (7.25) | ~1% at a million keys, +7% only at 10M (buckets of ~9.5 entries) | not taken: 111 places in the proofs and a lemma about `U32.is_eq` |

**6. The code became simpler.**
- P3 removed `find`, `tfind`, `bfind`, `copy` and five lemmas from BendKV (−32 lines of
  code and −30 lines of proofs), GET of a 1 MB value takes 18–20 ms instead of 25, the
  rest of the speed is the same. The complexity moved into the compiler: 1.6 thousand
  tokens, and a new call somewhere in the program can change whether a function borrows
  a parameter or owns it. Because of this the hot path got more expensive four times
  (7.6, 7.14, 7.17, 7.22), and every value read by GET gets a counter cell forever: +8
  bytes per key (section 13).
- `int_read` by index (7.12): shorter and faster.
- Parsing straight into `Cmd` (7.24): the proof `req_hashes` over 24 cases was replaced
  by the type `Fit`, and the type checker checks the condition at every place in the
  parser; the proofs are 197 lines shorter.
- The hints per group (7.23) were removed together with their law, −102 lines.
- What was dropped without complicating the code: a directory array (7.5), a two-pass
  parser (7.4), tail variants of the batch (7.7, 7.23, 7.24), `-march` (9.6), CRC32C
  (7.22), requests as bytes to the shards (7.17).

**Conclusions.**
1. The best ratio is with the changes that remove a whole class of work with memory or
   the disk: allocations (p1), the levels of the trie (7.6), waiting for misses (p9), an
   `fsync` per request (group commit). Each gave a gain of several times, and the
   compiler grew from them by 0.7 thousand tokens out of 38.2.
2. Strings are almost half of the growth of `comp.ts` (p2, 4, 8, 14, 18 and 23: 17.8
   thousand tokens) and the main contribution to the speed of one core. A string in the
   runtime is now cells, chunks, a word or a blob, and every string function in C is
   written for all four kinds. The core (p2, p4a, p8) is needed; p4c, the forms of p4b
   and p18 are worth squeezing.
3. From 7.22 on, cutting instructions almost stopped saving time: 7.22, p16, p18 and p19
   each removed from 1 to 17% of instructions, while the OS kernel is half of a request's
   CPU with pipelining and two thirds without it. What paid off were edits of the path
   through the kernel (p15, p17: +15…26%) and cutting almost half of the instructions
   (windows, +27%).
4. Heuristics are a hidden cost. Sending has two overlaid rules (p15 and p17) with eight
   constants tuned on one VM (a window of 200 µs, 10 points, four sends, a span of 32
   windows, four ready sockets, two and three spans, 60%), plus 30 and 50 µs of
   busy-waiting in p10. They are worth merging into one rule, and the contribution of
   p15 is worth remeasuring.
5. Proofs are a cost too. 7.22 added four laws for 1.5% of instructions, and 7.24 showed
   a cheaper way: an obligation in the type, not a separate theorem. Shards carry ~2,900
   lines of proofs, and on this VM they pay off only without pipelining and with the
   append-only file.
6. For upstream: p1 gives the best ratio, does not depend on the other patches and fits
   into the headroom below the cap (0.44 thousand tokens with a headroom of 1.06
   thousand), so it makes sense to propose it first, before p19 (2.2 thousand; it does
   not fit into the headroom without simplifications). The candidates to remove or
   squeeze are p5, p7, p15, p4c and p18 (8.7 thousand tokens together), but even without
   them ~29 thousand tokens remain with a headroom of one thousand, so there is no way
   around simplifying `comp.ts` itself.

## 13. An outside review: bugs in the append-only file, measurements on another machine, copying the reply

A colleague checked HEAD 641566c (after 7.23, before 7.24, sixteen patches) on a laptop
with an i9-11900H (Debian in WSL2): correctness (all 45 laws with the BendTT kernel,
`make smoke`, `make test`, disk failure scenarios) and speed (memtier, 100 connections,
100-byte values, keys `local-N`, all GETs are hits; `perf` and callgrind profiles).

**Bugs in the append-only file: confirmed and fixed.**
- *A file that could not be opened gave an empty database.* `restore_open` took any
  failure of `File.open` for a missing file: on `EACCES`, an I/O error or running out of
  descriptors the server started with an empty database and appended new records to the
  old file, and after the next restart the old values came back. Now an empty database
  comes only on `ENOENT`; otherwise the server refuses to start and gives the reason. The
  same was in the check of the shard layout (`is_file`): an unreadable file of another
  layout was taken as missing.
- *The background `fsync` with `everysec` was not checked.* Now a failure stops the
  server, as it already did with `always`: acknowledged writes might not have reached the
  disk, and after such an error the kernel may drop the dirty pages, so the next
  successful `fsync` will not show it. Redis (the unstable branch) in this case answers
  writes with a `MISCONF` error until `fsync` succeeds again; we chose to stop, as with
  `always`.
- *`tests/robust_test.py` returned 0 on failure*, and `make test` let it pass. Now the
  exit code is 1.

A new test [`tests/aof_fail_test.py`](../tests/aof_fail_test.py) with a shim
[`tests/fail_io.c`](../tests/fail_io.c) (`LD_PRELOAD`: reading the given file gives
`EACCES`, `fsync` and `fdatasync` give `EIO`) checks six cases: no file gives an empty
database; an unreadable file of one shard, the file of one of two shards and a file of
another layout give a refusal to start, the file is untouched, and once readable it is
recovered again; a failed `fsync` with `everysec` and with `always` gives a stop. The
build before the fix fails four cases of six, the new one passes all; `make test` now
runs it too.

**Speed on the i9 (medians of four pairs, thousands of ops/s and the ratio to Redis).**
On one core BendKV won all six loads in all pairs: 1.20–1.49 of Redis. On two cores (one
shard with a writer against the best of Redis and Redis with `io-threads 2`) with
pipelining 1.59–1.82, GET without pipelining 0.92 of Redis with `io-threads 2`; it was
the same for us in 7.16 (0.96). The spread on the laptop is large (the CV of absolute
speeds 4–31%), so small differences do not show there.

**Memory depends on the sizes of keys and values.** Our "half of Redis" (7.13) holds for
3-byte values. Our own measurement, 1 million keys `key:%012d` (16 bytes), loaded in
batches of 1,000 SETs, RSS after loading:

| values | BendKV | Redis | BendKV / Redis |
|---|---:|---:|---:|
| 3 bytes | 61 MB (64 bytes per key) | 123 MB (129) | 0.50 |
| 100 bytes | 183 MB (192) | 211 MB (221) | 0.87 |
| 100 bytes, after a GET of each key | 191 MB (200) | 211 MB (221) | 0.91 |
| the colleague's: 3 bytes, keys `local-N` | 60.4 MiB | 81.9 MiB | 0.74 |
| the colleague's: 100 bytes, after a GET run | 188.4 MiB | 182.1 MiB | 1.04 |

A 100-byte value costs both the same (in BendKV a blob of the 128-byte class, in Redis an
`robj` and an `sds`, 16 + 112); BendKV wins on the entry and the key. Short keys Redis
stores more cheaply than our 16-byte ones. And something new: **the first GET of a value
adds a counter cell to it forever**, +8 bytes per key (a second GET pass adds nothing
more). GET borrows the trie, and the value goes into the reply, so the entry's field is
sealed (`slot_keep`, section 5) and stays sealed.

**Copying the reply waits for memory.** In the colleague's profile, on GET with 100-byte
values at pipeline 10, ~17% of cycles are copying in libc: ~11.6% the value into the
reply when encoding RESP (`str_append`), ~5.1% the reply into the send buffer
(`io_cbuf_add`). Our callgrind on the same request (100 thousand keys, pipeline 10, a
cache model with a 2 MiB L2, a build with `-g`): 3,466 instructions and 5.1 L2 misses per
GET. The copying itself is 48 instructions, but `memcpy` gets 1.64 misses, and 1.41 of
them are in copying the value into the reply (`str_append`, 165 instructions with
callees). Copying into the send buffer (`tcp_send_raw_run`) is ~90 instructions and 0.24
misses. So what is expensive is not the copying but waiting for the value's bytes, and
the batch hints (7.14) do not cover them:
- the value's field is sealed after the first GET, and `Mem.prefetch` of a sealed field
  touches only its counter cell: to get to the buffer, the cell has to be read;
- for an unsealed buffer `Mem.prefetch` touches the first 64 bytes, and a 100-byte value
  with its header takes two lines.

On 3-byte values (`redis-benchmark`'s default, on which almost all our measurements were
taken) the value is a word in the term itself, with neither a cell nor a buffer, so we
did not see this. It also explains 7.15: in the spec "GET of 100 bytes, pipeline 10" the
hints gave nothing.

**The rest of the review.**
- *Turning off the hints*: GET −14…−16% on the i9 in all pairs. This agrees with 7.14
  and 7.15: on 100-byte values and memtier's uneven batches the gain is smaller than
  ×1.5.
- *PGO*: −10% instructions and −26% machine code, in time GET from −19% to +11%, INCR
  +6%. *`-march=x86-64-v3` and `native`*: −2% instructions, GET +9…10% (medians of three
  pairs). For us (9.6) `-march` did not win in time. Each variant there is one build, and
  two builds of the same C differ in time by 5–10% from the code layout (7.23), so such
  differences must be measured on several layouts (`tools/layouts.sh`).
- *RESP parsing is 31% of GET's instructions and 40% of SET's.* That is before 7.24:
  since then parsing together with the hash got 22% shorter on GET, and a request is
  parsed straight into a command, as the review suggests.
- *IPC* of BendKV is 1.81 against 0.94 for Redis, with fewer instructions for Redis
  (3,604 against 4,065): the hints hide waiting for memory, which Redis 7 does not do.
- *The trie at a million keys*: on average 0.95 entries per bucket (2^20 buckets), ~25%
  of buckets have a chain longer than one entry, and the share of the map and key
  comparison in the profile grows from 4.6% to 15.8%.

**What this adds to the plan** (section 11), by the expected gain on values longer than
6 bytes:
1. A hint that reaches the value's bytes: for a buffer, all its lines (by size class, up
   to four); for a sealed field, one more pass over the batch that reads the already
   fetched cell and hints its buffer. This removes up to 1.4 misses per GET of a 100-byte
   value; the cost is a few lines in `mem_prefetch` and a pass in `batch.bend`. *Half
   done (7.25):* all lines of the buffer are hinted in the twentieth patch, and the pass
   through the cell lost (0.93–0.98) and was not taken: item 2 removed the cell.
2. GET without sealing the value: if the reply is encoded while the trie is lent, the
   value does not go into the reply, and the cell is not needed (−8 bytes per key, fewer
   count operations and one jump less). It needs a law: the reply encoded at the read is
   the encoded reply of `exec`. *Done (7.25)* more simply: GET answers with a copy of the
   value made at the read, and no new law was needed; a lemma that a copy of the whole
   string is the string itself was enough.
3. Part of the hash in the bucket entry: at a million keys a comparison with another key
   in the chain costs a miss on its bytes, and a hash in the entry cuts it off without
   reading the key (+8 bytes per key). *Measured and not taken (7.25):* it costs no
   memory (the entry's block is four words anyway), but at a million keys it gave ~1%;
   +7% only at 10 million, where more buckets are needed more.
4. A shared buffer for encoding and sending: ~90 instructions and 0.24 misses per GET;
   less than it seemed from the cycles.

## 14. Rollback: shards, the key hashed once, effect pairs

By the scale of section 12, three changes gave the least at a noticeable cost: shards
(7.16–7.18, 7.21), the key hashed once (7.22, with the obligation in the type from 7.24)
and effect pairs with a separate fast path of the connection (7.23, item 5). We removed
them, making sure that no series of measurements dropped by more than 5%, and measured
the same way as before: pairs on three code layouts, callgrind, `make perfcheck`.
Everything removed is kept in the branch
[`archive/shards`](https://github.com/littleBro/BendKV/tree/archive/shards): shards can
be brought back into the finished project in the next optimization cycle. From here on,
work goes not on speed but on features (README, "What next").

**What was removed.**
- *Shards.* `shard.bend` and `wire.bend`; in `server.bend`, the link of a connection to
  N actors, splitting the batch and collecting the replies (`run_split`, `sends`,
  `collect`), the per-shard append-only files with the layout check (`layout_check`,
  `strays`) and recovery on the shards' loops; the commands `SizeAt`, `KeysAt`,
  `FlushAt` and the append-only file record `FLUSHAT`; the root of the trie in
  `map.bend` (`digits`, `child`, `with_child`, `size.at`, `keys.at`): FLUSHALL again
  gives back an empty trie, and DBSIZE and KEYS are folds over the whole trie, as before
  7.18. Of the laws: shards (4), bytes (3) and the append-only file on shards (3), with
  their proofs and the lemmas about the trie's root. The remaining laws needed a couple
  dozen lemmas from them (that the reply of a command on one key depends only on that
  key, about concatenating strings), and these were moved. `tests/concurrency_test.py`
  stayed: it checks the same properties for one actor.
- *The key hashed once.* `exec.at`, `exec_all.at`, the hashed variants of the
  append-only file (`log.*.at`), `fits` and the proof field in the parsed request: now it
  is `B.Req{cmd, hash}`, and the hash serves only the batch hints. The laws `exec_at` and
  `fit_hashes` are gone, `batch_hints` and `log_hints` no longer require anything of the
  hashes, and `exec` hashes the key itself, as before 7.22. GET with a copy of the value
  (7.25) stayed: the copy is now made by `exec` itself (`KV.get_copy`), and the proofs
  needed only the lemma `get_copy_eq`: the copy equals `KV.get` (from `tget_kc_eq`).
- *Effect pairs.* The separate path of the connection (`conn_run`, `conn_reply`): the
  connection hands the batch to the actor with `Chan.send`, waits for the reply with
  `Chan.recv`, answers with `TCP.post` or `TCP.send_raw` and reads on with
  `TCP.recv_raw`, by one path for all cases. The sixteenth patch (`Chan.call`,
  `TCP.post_recv_raw`) is no longer needed by anything and was removed together with its
  tests; the former patches 17–20 became 16–19.
- *In the runtime, also* `TCP.post_list` from the eleventh patch: posting chunks as one
  buffer was called only by the merging of the shards' replies. The patches after the
  eleventh were regenerated on the fork's branch: in three of them only the line numbers
  in `base.bend` moved, and `comp.ts` did not change (97,653 tokens). Both lanes of
  Bend's tests (C and JS) pass exactly the same tests as with twenty patches, except the
  six tests of what was removed (`chan_call`, `tcp_post_recv`, `tcp_post_list`).

Checked: `make check` and `make verdict` (33 laws), `make smoke` (the batch's replies are
byte for byte the same as before the rollback), `make test` (the differential test
against Redis, ~70 thousand commands, robustness, concurrency, the append-only file,
disk failures) and seven code mutations: an append-only file without APPEND, a GET copy
that answers with nothing or is truncated, hints that change the batch or the
append-only file, an append-only file record lost on reading, a FLUSHALL that leaves a
key; the proofs catch each one.

**How much this took off** (lines without comments and blank lines):

| | before | after |
|---|---:|---:|
| BendKV code | 3,387 (573 written by the generator) | 2,104 (357) |
| of it `server.bend` | 697 | 464 |
| laws | 45 (524 lines) | 33 (354) |
| proofs | 6,711 (2,028 written by the generator) | 4,102 (1,576) |
| the server's generated C | 1.10 MB | 0.72 MB |
| patches to Bend | 20 | 19 (−436 lines, 255 of them tests) |

Code and proofs are each 38% shorter.

**Measurements.** Three variants: `base`, the state before the rollback (the branch
`archive/shards`); `new`, after the rollback; `v16`, after the rollback, but with effect
pairs (`Chan.call` and the former fast path with `TCP.post_recv_raw`), to separate the
contribution of the sixteenth patch. Instructions per request (callgrind, 100 thousand
keys, 20 clients, 3-byte values):

| | GET | SET | INCR |
|---|---:|---:|---:|
| pipeline 16, sending from the loop: `base` | 2,979 | 3,552 | 3,847 |
| `new` | 2,971 | 3,571 | 3,835 |
| `v16` | 2,955 | 3,557 | 3,819 |
| pipeline 16, writer: `base` | 3,047 | 3,587 | 3,866 |
| `new` | 3,090 | 3,641 | 3,917 |
| `v16` | 2,974 | 3,565 | 3,857 |
| no pipeline, sending from the loop: `base` | 7,487 | 8,013 | 8,310 |
| `new` | 7,523 | 8,063 | 8,334 |
| `v16` | 7,262 | 7,801 | 8,069 |
| no pipeline, writer: `base` | 7,833 | 8,919 | 9,348 |
| `new` | 8,928 | 9,906 | 10,489 |
| `v16` | 7,589 | 8,659 | 9,026 |

Shards and the key hashed once are almost invisible in the instructions of one loop: at
pipeline 16 with sending from the loop `new` differs from `base` by −0.3…+0.5%. The
second hash of the key costs about as much as the pass over the list of hashes and the
parsing of the connection's link to the shards' lists cost. Effect pairs show where they
were made for (7.23), without a pipeline with a writer: without them a request takes
11–14% more instructions than in `base`, and 14–18% more than in `v16`.

Time, medians of the ratios to `base` in pairs (each pair is three code layouts):

| series | pairs | `new`: GET | SET | INCR | `v16`: GET | SET | INCR |
|---|---:|---:|---:|---:|---:|---:|---:|
| `redis-benchmark`, pipeline 16, 100k keys, server on one core | 12 | 1.019 | 1.012 | 0.983 | 1.004 | 1.061 | 1.006 |
| `redis-benchmark` without a pipeline, 50 connections, server on two cores (writer) | 8 | 0.968 | 0.996 | 1.010 | 0.986 | 0.985 | 1.029 |
| memtier, GET hits, 1M keys of 100 bytes, pipeline 10, one core | 4 | 1.006 | | | 0.963 | | |

Redis's specs (`memtier_specs.py`, server on two cores with a writer, two pairs; GET of
10 bytes with pipeline 100, five more pairs separately):

| spec | `new` | `v16` | Redis |
|---|---:|---:|---:|
| loading 1M keys of 100 bytes, pipeline 10 | 1.025 | 1.036 | 0.510 |
| GET 100 bytes, pipeline 10 | 0.971 | 0.996 | 0.582 |
| GET 100 bytes without a pipeline | 1.003 | 1.033 | 0.751 |
| GET 10 bytes, pipeline 100 | 0.940; 0.949 | 0.954; 0.980 | 0.473 |
| INCR, pipeline 10 | 1.027 | 1.039 | 0.794 |

Everything except two places is within ±3%, that is, noise. Without a pipeline GET loses
3% (user CPU per request +18%: this is the effect pairs), and GET of 10 bytes with
pipeline 100 loses 5% (seven pairs), right at the edge of the budget. All three variants
have the same instructions there: at pipeline 100 and 10-byte values GET costs
3,052–3,092 instructions (`redis-benchmark`, 50 connections), and there are no more
misses. The difference is in the loop's user time (430–455 ns per GET for `new` against
400–420 for `base`), not in the request's code: with a writer at pipeline 100 there are
many batches per step of the loop, and without effect pairs their sends are shared with
the writer differently. The sixteenth patch brings back three of these 5%, and two of
the 3% without a pipeline.

**Conclusion.** The rollback fit into the budget: code and proofs are 38% shorter, 33
laws, 19 patches, and the speed is the same, except GET without a pipeline (−3%) and GET
of short values with pipeline 100 (−5%); two thirds of the second and almost all of the
first is the sixteenth patch, and in the next optimization cycle it is worth solving
together with the sending rules (item 4 of the conclusions of section 12), not with a
separate path of the connection. The second hash of the key (for the hints and in `exec`)
does not show in time. `tools/perf_baseline.txt` was rewritten for the new build: GET
2,972, SET 3,566, INCR 3,833 instructions (it was 2,974, 3,549, 3,846).

## 15. Sessions: the connection's state on the request's path

The step toward replacing Redis with no changes to the client began with the commands of
a connection (README, section "Sessions"; docs/FINDINGS.md, section 3m): the
connection's state (`S.Conn`) travels to the actor with each batch and comes back with
the replies, the actor keeps the server's state (`S.Srv`) next to the database, and a
batch of database commands only, from a ready client, goes by the former fast path. The
first draft cost +10–11% instructions per request at pipeline 16, and the profile
(`phases.py`) named four causes:

| what | instructions per request (pipeline 16) | how it was removed |
|---|---:|---|
| classifying each command of the batch with a borrowing `match`: the command's fields get counts and are dropped right away (`term_drop` +84, `slot_keep` +32, `rfc_wrap` +41) | ~+160 | the commands of a connection are one constructor `Own` inside `Cmd`; the parser splits the batch by the tag that already lies in the flattened request (`B.unzip`, `B.job`) |
| a second constructor in the parser's request type (`B.Req` = `Req` or `Own`): an extra tag in the flattened request in the parser and in the split | ~+50 | the same: `B.Req` is one constructor again |
| a continuation with two arguments (the socket and the connection's state) | ~+10 | after the actor's answer the connection's steps are `@unsafe` definitions that call each other and the connection's loop directly, without closures |
| `String.is_empty` takes a packed string apart into a head and a tail, a copy of the tail (`str_take_slow`); on the received bytes and on the reply | ~+8 (+107 per packet without a pipeline) | emptiness is checked by `String.length`; "no replies" is a `Maybe` from the actor |

The result (callgrind, 100 thousand keys, 20 clients, 3-byte values):

| | GET | SET | INCR |
|---|---:|---:|---:|
| pipeline 16, the baseline (`tools/perf_baseline.txt`) | 2,972 | 3,566 | 3,833 |
| pipeline 16, with sessions (`make perfcheck`) | 2,966 | 3,547 | 3,842 |
| no pipeline, before sessions | 7,536 | 8,075 | |
| no pipeline, with sessions | 7,705 | 8,227 | |

At pipeline 16, from −0.5 to +0.2% against the baseline (there are fewer closures than
before sessions: `CLO_APPLY` 48 → 30 instructions per request, and indirect
mispredictions 2.4 → 1.7); without a pipeline, where a batch's cost falls on each
request, +2.2% on GET and +1.9% on SET (about 170 instructions per batch: the
connection's state in the request to the actor and in the answer, choosing the path,
splitting the batch, extra steps of the connection), but indirect mispredictions
23 → 15. The rows without a pipeline were taken before the last small fix (the
parser's errors on the general path go through `exec`), which added 0.2% at
pipeline 16. In time, four pairs, each over three code layouts, the server on one core:
at pipeline 16 GET and SET at 1.09 and 1.04 of the code before sessions, without a
pipeline 1.01 and 1.01; all within the noise. `tools/perf_baseline.txt` did not change.

## 16. INFO: state that cost a quarter of a request

INFO (README, section "Commands"; docs/FINDINGS.md, section 3p) keeps its own account
next to the server's state: the facts of the start, the shell's last facts, the counts of
commands and bytes, the instantaneous rates, the size of the append-only file. The first
version passed all tests but cost +28% instructions on GET and +24% on SET at
pipeline 16. INFO's own work has nothing to do with it: everything went into how its
state travels through the code. A profile by function (`phases.py` over builds of both
versions with `-g`) named the causes one by one; each row of the table is the next step
(callgrind, 100 thousand keys, 20 clients, pipeline 16, 3-byte values, builds with `-g`;
a dash means not measured):

| step | GET | SET | what it was and how it was removed |
|---|---:|---:|---|
| before INFO (starting as redis-server does) | 3,000 | 3,584 | |
| the first version | 3,842 | 4,454 | |
| patch 21: a type wider than 32 words is a node of its own | 3,611 | — | INFO's account (38 words) lay flat in the server's state (`Srv` 40 words, the actor's group 43, a batch's outcome 47), the actor's functions took 50–67 parameters each, and the widest result (48) and the widest parameter list of a function without a frame (67) are the signature of every segment: every jump passed 67 registers, every return copied 48 words (`WL_FID_EXIT` 9.6 → 109.5 instructions per request). With the patch the server without INFO compiles to the same C, byte for byte |
| requests are counted before `B.unzip`, with a borrowed walk | 3,133 | — | they were counted with `List.length` after `B.unzip` had taken the list (through `+rs`): the compiler copied the list, `List.length` dropped the copy request by request (`term_drop` +300 per request), and the executor read the fields of shared requests through counts (`rfc_wrap`, `slot_keep`) |
| `nopass` compares inside the `match`; the length of the replies is read before the answer goes into the list | 3,081 | — | `srv.pass` returned a field of a lent `Srv`, and the parameter became owned in `nopass`, `authed` and `ready`; `S.run` kept (`term_keep`) all the state's fields on every batch, and INFO's node, rebuilt by every batch, was wrapped in a count each time, and the next update copied all its words (`ctr_own_slow`) |
| facts as a separate message to the actor (`Facts`), the count of connections as one channel (`Tally`); the environment reads at the start in a definition of their own | 3,052 | 3,634 | the request variant with facts (`ReqLive`, the 9 words of `Live`) and three words of channels in `Link` inflated a request to 21 words, and the sending step to 33 parameters; the segments' signature is now 24 registers (25 before INFO) |
| sending and the answer in both arms, not as a common step; the count in `U32` | 3,043 | 3,627 | a definition called from two places is a segment of its own, entered through the work loop (22 instructions per request) |
| the parser counts the requests (`P.Batch.n`), not a separate walk | 3,032 | 3,614 | a walk over the list is ~7 instructions per request, an addition in the parser ~1 |

The remainder against the section before INFO: +1.1% on GET and +0.8% on SET. Of it, ~3
instructions per request are the counts themselves (an addition in the parser, sums of
two `Nat`s in the actor), ~1.5 the cron's ticks (under valgrind the clock runs slower,
and there are more ticks per request) and ~7 glibc: the facts of the start are read from
`/proc` through the runtime's helper threads, like any file, the first such thread makes
the process multi-threaded for good, and `recv` and `send` take glibc's long path of
cancellable system calls (~50 instructions per call). A start with a configuration file
did so before too, and a server with a writer is multi-threaded in any case.

Without a pipeline, where a batch's cost falls on each request, the difference is more
visible: GET 8,178 → 8,602 (+5.2%), SET 8,701 → 9,128 (+4.9%), ~425 instructions per
batch. Of them ~104 are multi-threaded glibc (`__pthread_enable_asynccancel` and
`disable` around `recv` and `send`), ~250 the connection's path (the answer is now taken
apart by a separate segment `conn_ans`, since both arms call it; counting bytes and
commands; `Link` a word wider), ~140 the account in the actor (taking apart three kinds
of `Req`, `srv.ran`: sums of two `Nat`s and updating INFO's node in place); the new
`nopass` brings back ~150.

Tried and not taken: joining the arms "with facts" and "without" into one `IO` step that
returns at once without facts: +12 instructions per GET, since the step's continuation is
a closure built on every batch.

`make perfcheck` (a build without `-g`): GET 3,031, SET 3,614, INCR 3,921, +2.0%, +1.3%
and +2.3% against the baseline (2,972, 3,566, 3,833); before INFO it was 3,002, 3,583 and
3,878. `tools/perf_baseline.txt` did not change. Bend's tests with patch 21 (C and JS):
exactly the same that pass with twenty, plus the new `flat_limit` on both lanes, 1,487
of 1,746.

## 17. COMMAND: one word in every command

COMMAND (README, section "Commands"; docs/FINDINGS.md, section 3q) answers with Redis's
descriptions, which lie in BendKV as ready data, and does not get onto the request's
path. But the first version cost +0.9% instructions per request: COMMAND's subcommands
went to the session as a parsed request of two words, and the width of a datatype is the
width of its widest variant. The session's operations, one word wide until then, became
two words, and every parsed command (`R.Cmd`, one of whose variants is a session
operation) became a word wider along the whole path: the parser, the batch, the
executor.

| | GET | SET | INCR |
|---|---:|---:|---:|
| before COMMAND (section 16) | 3,031 | 3,614 | 3,921 |
| a COMMAND request of two words in a session operation | 3,058 | 3,640 | 3,941 |
| the operation holds COMMAND's arguments as they are (one word) | 3,037 | 3,620 | 3,924 |

Now the operation holds COMMAND's arguments as they came, and `command.bend` recognizes
the subcommand by name once more (errors in the number of arguments and unknown
subcommands are still found by the parser, before the password check, as in Redis).
`tools/perf_baseline.txt` did not change.

## 18. Statistics per command: the request's code in the high byte of the hash

The statistics per command in INFO (README, section "Commands"; docs/FINDINGS.md,
section 3s) count as Redis 7.0.15 does: for each command and subcommand, the calls, the
calls refused before running, and the ones that failed while running; error replies by
code. The work is laid out so that the request's path hardly pays. What to count a
request as is known to the parser, and it writes the code (the command's key — a number
below 64 — times 4, plus the class: 0 runs, 1 refused, 2 failed while parsing) into the
high byte of the request's hash: the hints read only the low 20 bits. It also merges
(OR) the request's mark, the code and its complement, `code × 257 xor 0xFF00`, into the
word where the batch's requests were already counted. If all the requests of a batch
have one code, each of its bits stands in the marks once, directly or in the complement,
and the actor counts the batch (one command, as in almost all batches) by one word,
without looking at the requests; any other batch by the hashes. Errors are looked for
only where they are possible: in calls refused or failed while parsing, and in INCR,
DECR, INCRBY, DECRBY. In a batch of one code each reply is one line, an error begins with
`-`, and if there is no `-` at all in the reply's bytes (one `memchr`), there are no
errors; a batch of several codes looks through the replies before encoding. (Section
52: a batch of one code looks through its replies too, since the collections' commands
that may fail answer many lines.)

The first version cost +2.9% on GET and +2.8% on INCR. Each row is the next step
(callgrind, as in `make perfcheck`):

| step | GET | SET | INCR | what it was and how it was removed |
|---|---:|---:|---:|---|
| before the statistics (the section on Redis's suite, KEYS) | 3,039 | 3,619 | 3,926 | |
| the code in the parse result, the parser counts the runs, the actor updates the account on every batch | 3,126 | 3,699 | 4,037 | the code is an extra word in the result of every request (the parser's loop +39); the actor ~30 |
| the code in the high byte of the hash, the actor checks the batch with a walk over the hashes | 3,146 | 3,717 | 4,053 | a borrowed walk over the list is 34 instructions per request (`slot_keep`, `term_drop`) |
| the parser merges the marks into the word with the count of requests (at first as a separate field of the result and a parameter of the loop: 3,099, 3,672, 4,017) | 3,075 | 3,653 | 3,997 | each extra live value in the parser's loop is ~15 instructions per request |
| counting the batch by operations on the word, without calls to `Bool.pick` and `Nat.mod`; INCR's errors by the reply's bytes | 3,071 | 3,644 | 3,965 | a walk over INCR's replies cost 31 per request; the first check by bytes held the list of replies both for the encoder and for itself, so the list became shared, the encoder read it through counts, and the last drop walked it whole: INCR 4,647 |
| a batch's run is one number (`cur`), not a list | 3,067 | 3,639 | 3,959 | a list cell was taken and freed on every batch |
| the database is not shared on the general path | 3,055 | 3,639 | 3,957 | see below |
| the mark two operations shorter; INCR's check before the account | 3,053 | 3,637 | 3,947 | |

The least obvious trap is the shared database. Redis also counts errors the client did
not see (CLIENT REPLY OFF), and the first version, to learn the reply of such a call, ran
the command idly on a lent database before the real run. One such place made the
database a shared value for the whole program: the compiler's ownership analysis began
to take it owned in INFO's keyspace section and in `KV.size`, the session kept it
(`term_keep`) on every CONFIG GET, and the database's root stayed wrapped in a reference
count until the next write. In a series of GETs (redis-benchmark itself sends CONFIG GET
at its start) every hint and every lookup went through the redirect: +9 instructions per
GET in the hints, three each (`mov; mov; shr $24`) per hash and pass. It was found by
comparing callgrind's counts per instruction of the same machine code in two builds:
the code of `touch_if` matched byte for byte, but one block ran only in the new one. Now
a database command with replies off runs once, with replies on (the reply is counted
and thrown away, and the connection's state after it is `S.next_conn` by the real mode);
for the commands of a connection and of the server the reply is taken by `own_reply`,
which borrows the database and does not keep it (CLIENT REPLY ON and RESET answer even
with replies off, so running them with replies on would be wrong).

The remainder against the section before the statistics is about +0.5%: ~12
instructions per request in the parser's loop (the mark and the register it occupies),
~2 writing the code, ~10 the account in the actor (the batch's run and number of calls;
for INCR, the `memchr`). Without a pipeline, where a batch's cost falls on each request:
GET 8,605 → 8,699 (+1.1%), SET 9,133 → 9,273 (+1.5%), INCR 9,447 → 9,671 (+2.4%),
~95–140 instructions per batch: ~60 updating the account (the run, the calls; the
counts are of two `Nat`s), the rest the actor's frames, in which the batch's tally and
its word now travel; checking the bytes of INCR's reply is ~100 more.

`tools/perf_baseline.txt` was rewritten (`UPDATE=1`): the baseline 2,972, 3,566, 3,833
had stood since the repository was published, and sessions, INFO, COMMAND and the
statistics together added +2.7%, +2.0% and +3.0% to it; the next 3% are counted from
here.

## 19. SCAN and RANDOMKEY; the statistics codes as twelve-bit words

SCAN and RANDOMKEY (README, section "Commands"; docs/FINDINGS.md, section 3t) walk the
trie in the order of paths: the cursor is the number of the next bucket of 2^20, a call
reads buckets whole until it has COUNT keys, and skips a whole subtree before the cursor
without entering it. RANDOMKEY picks as `dictGetFairRandomKey` in Redis does: from a
random bucket, the keys of buckets until there are 16 of them (past the last bucket,
from the first up to the random one), and one of them, all equally likely. The first
version, a descent through the trie with a random non-empty subtree at each level, read
5 nodes but was unfair: of 1,000 keys over 20,000 picks (20 each on average) the most
frequent came up 102 times, the rarest once, and one key never. With the window the
rarest and the most frequent come up at 0.25 and 2.2 times the mean (Redis: 0.30 and
2.25); of 20,000 keys over 400,000 picks, 0.15 and 2.65 (Redis: 0.05 and 2.8). A window
of 32 keys was fairer still and twice as expensive. A pipeline of 20,000 RANDOMKEYs from
one client in Python: 7 µs per call for BendKV and 3.5–5 for Redis, with 2 µs per
CLIENT ID for both, that is, about 5 µs of its own: almost all of it is the walk, which
at each node counts the bounds of 16 children.

The statistics codes outgrew a byte. The keys of INFO commandstats are now numbered by
`tools/gen_commands.py` by the parser's own numbers: with SCAN and RANDOMKEY there are
58 of them and 236 codes, a byte has room for 256, and the data types will exceed it.
The code travels in the high twelve bits of the hash as a word with six ones (there are
924 such words, room for 231 keys): the OR of two different such words gives seven ones
or more, so the OR of a batch's words has exactly six only when all have the same word.
The parser merges the request's word into the low 12 bits of the batch's word (three
operations; the mark of the code and its complement cost five), and the high 20 bits
count the requests: a batch is counted by one word up to 1 MB of requests (it was up to
64 KB). The word of a code, the code of a word, and the set of commands whose calls can
fail while running (INCR, DECR, INCRBY, DECRBY) are written by the generator; the
tables compile into arrays.

The cost (callgrind, as in `make perfcheck`; before the step, a build of commit 47cfb51
in the same run):

| | GET | SET | INCR | MSET |
|---|---:|---:|---:|---:|
| before the step | 3,054 | 3,636 | 3,945 | 27,040 |
| after | 3,062 | 3,643 | 3,959 | 27,028 |

GET, SET and INCR +0.2–0.4%; MSET, whose name goes through `cmd_id` with one comparison
more, is 12 instructions cheaper: an extra comparison with a literal costs practically
nothing. `make perfcheck`: 3,059, 3,643 and 3,963, +0.2%, +0.2% and +0.4% against the
baseline 3,053, 3,637 and 3,949 (tolerance 3%); `tools/perf_baseline.txt` did not
change.

Found along the way: DBSIZE folds the whole trie, 15 µs at 40 keys, 256 µs at 1,000
(Redis 2 µs, a counter), and so does the keyspace line in INFO. The number of keys will
go into the database when it changes shape, for several databases and keys' time to
live.

## 20. The database as a record with a count of keys

Before this step the database was a trie: `exec` took a trie and gave back a trie. Keys'
times to live and several databases need more, so the database is now a record
`Db{t, n, x, now, rr}`: the trie; the number of keys in it; the number of keys with a
time to live; the time at which the batch runs; and a field that is always None (below).
x and now are zeros while keys cannot expire. The replies are the same, but DBSIZE and
the keyspace line in INFO read n rather than fold the trie. A pipeline of 2,000 DBSIZEs
from one client:

| keys | before the step | after | Redis |
|---:|---:|---:|---:|
| 40 | 13.9 µs | 0.15 µs | 0.30 µs |
| 1,000 | 214 µs | 0.15 µs | 0.30 µs |
| 10,000 | 1.8 ms | 0.18 µs | 0.30 µs |

The commands keep the count themselves. SETNX, GETSET, INCR and APPEND read the key
before writing and know whether it was there; if it was not, they add one. SET and MSET
do not read the key: now, before writing, they ask the trie whether the key is there, a
pass along the same path that answers a Bool and copies nothing (`KV.has.at`). Redis too
looks the key up before adding or overwriting it. DEL subtracts the deleted keys,
FLUSHALL sets 0.

The cost (callgrind, `make perfcheck`):

| | GET | SET | INCR |
|---|---:|---:|---:|
| before the step | 3,053 | 3,637 | 3,949 |
| after | 3,075 | 3,977 | 4,119 |
| difference | +22 (+0.7%) | +340 (+9.3%) | +170 (+4.3%) |

`tools/perf_baseline.txt` was rewritten to the new numbers. SET pays for the second pass
(120–150 instructions) and for rebuilding the record, INCR for the record and its
fields, which go through three helpers. Four other designs turned out more expensive:

- **A flat record.** The compiler passes a value of a non-recursive type whose fields
  fit in 32 words as separate registers. Five fields went through every call that passes
  the database, and GET cost 66 instructions more, not 22. A field of the record's own
  type (`rr: Maybe<Db>`, always None) makes the type recursive: the record is boxed and
  passed as one pointer.
- **The "is the key there" pass next to the write.** `KV.set.at(String, t, k, v, h)` and
  `KV.has.at(String, t, k, h)` as adjacent arguments share the trie between the calls,
  and the write copies its path: 12,500 instructions per SET. The pass must go first,
  over the lent trie, as a separate local variable.
- **One pass that answers both.** A write that also tells whether the key was there
  returns a pair at every level of the path: 211 instructions more expensive than two
  passes.
- **INCR through a type of its own.** A type `Inc` with `Bool.pick` over two outcomes
  cost 4,153 against 4,115–4,120 for three helpers that take apart the old value and
  whether the sum fits.

The proofs (docs/FINDINGS.md, section 3u): the former `exec` on the trie became a
specification (`proof/SPEC.bend`), the proofs of the laws about it did not change, and a
bridge (`bridge_go`) proves that the server's `exec` on a record with the trie t answers
as the specification does on t and leaves the same trie; the exception is DBSIZE, which
answers with the count. The laws about the whole database are proved on the record
together with the count. Not proved yet: that the count equals the trie's size; this
needs the invariant "a bucket has no repeated key" (`bdel` deletes all the entries of its
key) and the arithmetic of a sum over 16 children; it will come together with the count
of keys with a time to live. `make check` takes 4.0 s, `make verdict` 24 s on this
machine (before the step 3.6 and 23.7).

## 21. Keys' times to live

BendKV has Redis 7.0.15's times to live: EXPIRE, PEXPIRE, EXPIREAT and PEXPIREAT (with
NX, XX, GT, LT), TTL, PTTL, EXPIRETIME, PEXPIRETIME, PERSIST, SET with NX, XX, GET, EX,
PX, EXAT, PXAT and KEEPTTL, SETEX, PSETEX, GETEX and GETDEL. Arguments are read as Redis
reads them (`string2ll`, overflow of seconds in milliseconds, options and errors in the
same order). An entry of the trie holds the key, the value and the time when the key
expires (ms since 1970, 0 for never); the database's record holds the number of keys
with a time (the field `expires` in INFO) and the time at which the batch runs: the
database actor takes it from the clock (`IO.clock`) before each group of batches. An
expired key does not exist for any command, but reading it does not delete it: the entry
stays in the trie until a writing command sets the key again or deletes it, and until
then DBSIZE counts it. Redis deletes such a key when any command comes to it, and by a
walk from cron; the walk in BendKV came in the next step (section 22). A time from
10^14 ms (the year 5138) gives a key no time to live: a Nat holds at most 2^48 − 1, and
BendKV's integers are no longer than 14 digits.

The cost (callgrind, `make perfcheck`):

| | GET | SET | INCR |
|---|---:|---:|---:|
| before the step | 3,075 | 3,977 | 4,119 |
| after | 3,082 | 4,024 | 4,171 |
| difference | +7 (+0.2%) | +47 (+1.2%) | +52 (+1.3%) |

`tools/perf_baseline.txt` was rewritten to the new numbers. An entry of the trie has one
field more, and SET and INCR count the keys with a time. Two other designs turned out
more expensive:

- **INCR as an update.** The commands that read a key and write it (SETNX, APPEND, SET
  with options, GETSET, GETEX, GETDEL, EXPIRE and its kin, PERSIST) are one update
  `Upd`: it computes the reply and the change of the key, and the database makes the
  change where the key lies. INCRBY by the same path cost 4,482 instructions per INCR
  (+8.8%): the generalized path reads the entry, builds a reply with a change and takes
  it apart. INCRBY was left a command of its own; the append-only file runs it as the
  update `UIncr`, and the lemma `incr_upd_eq` proves that it is the same thing.
- **A flat type of updates.** `UGet` (the GET option of SET and GETSET) contains an
  update, so the type of updates is recursive: the compiler makes an update a node of its
  own. Otherwise a command would travel in registers as wide as the widest form of an
  update, and updates have many options (the same trick as the field `rr` of the
  database's record, section 20).

The append-only file writes the change, not the command: DEL, PEXPIREAT with the
absolute time, PERSIST, SET or SET with PXAT, SET with KEEPTTL, APPEND, everything that
repeats the change at time 0, when the file is loaded and no key has expired. A change
that keeps a key's time (KEEPTTL, INCR, APPEND of a key that is there) is written so that
the time is kept on replay too: this way the replay is exact for any database, even with
a time that no command gives. The proofs are 52 laws (docs/FINDINGS.md, section 3v): the
map's laws are now about entries with a time, new laws about commands (an expired key
does not exist, PTTL, KEEPTTL, PERSIST, GETDEL), histories with a time for each batch,
recovery of the database at time 0. `make check` takes 3.3 s, `make verdict` 28 s
(before the step 4.0 and 24).

Redis's test suite: 212 tests (it was 135); `unit/expire` 54 of 59, `unit/type/string`
41 of 77 (docs/COMPATIBILITY.md).

## 22. The sweep of expired keys

Redis deletes an expired key when a command comes to it, and by a sweep from cron ten
times a second: it takes a sample of keys with a time, deletes the expired ones and goes
on while more than a tenth of the sample has expired. BendKV's database actor sweeps at
every tick of its cron, also ten times a second, if some key has a time (the database's
record counts them, section 20). A round walks the trie from the place where the
previous one stopped, at most 400 entries, and collects the keys whose time has passed
(the same walk as for SCAN and RANDOMKEY, section 19, with one more mode). The keys found
are deleted with DEL at the group's time, like an ordinary batch: the append-only file
writes it as Redis writes a DEL for each expired key, so the laws of persistence cover
the sweep as they cover any batch. While a round finds more than a tenth of the entries
it read expired, the next one goes, ten at most. The field `expired_keys` in INFO counts
the keys the sweep deleted (CONFIG RESETSTAT starts the count anew).

The keys the walk found are checked once more before DEL: the filter `R.reap.keys` keeps
only those that are not there at the moment now. Hence the law `reap_keeps`: whatever
the walk found, the sweep deletes no key that is there. The proof is four lemmas;
nothing needs to be proved about the walk itself. There are now 53 laws.

The cost on the request's path is none: `make perfcheck` gives GET 3,086, SET 4,022 and
INCR 4,172 instructions (+0.1%, 0.0% and 0.0% against section 21). A sweep that finds
nothing reads at most 400 entries ten times a second. The first version swept at every
tick, whether there were keys with a time or not, and `make perfcheck` counted 14–19%
more instructions per request: under callgrind the server runs about fifty times slower,
while cron still ticks ten times a second, and each sweep's 400 entries were divided
among that many times fewer requests. In a database without keys with a time a tick now
reads nothing. Redis's test suite: 213 (the test "Redis should actively expire keys
incrementally" from `unit/expire` passes).

## 23. Several databases

BendKV holds Redis's databases: 16, or as many as `databases` says (the number is set at
the start, as in Redis). SELECT, MOVE, SWAPDB, FLUSHDB and FLUSHALL (with ASYNC and SYNC,
which empty at once) answer as Redis 7.0.15 does, with its errors: a number is read as
`getIntFromObjectOrReply` reads it, so `01`, `+1` and `1.5` are not integers, a long
long outside an int is "value is out of range" with Redis's bounds in the text, and
SWAPDB has its own errors. A connection starts on database 0, and RESET selects it again.
INFO keyspace has a line for each database with keys; the sweep of expired keys walks all
databases that have keys with a time, each with its own cursor.

**Design.** The databases are a zipper `R.Ds`: the database in focus, the databases
before it (the nearest first) and after it. A command of one database runs on the focus
exactly as it ran on the only database, and the actor, before a connection's batch,
moves the focus to the connection's database (one comparison if the focus is already
there). A batch runs at the focus's time: a database that leaves the focus keeps the
time at which it last ran, and one that comes into focus gets the focus's time.

**MOVE is two steps.** MOVE in Redis deletes the key's entry in the target database if
the key's time has passed there, and then moves the key if there is no entry for it
there. BendKV does this with two acts: a purge (it deletes such an entry) and the move
itself, which moves the entry (with the value and the time) only to a database where
there is no entry for the key at all. Each step is one effect in the append-only file and
reads the same whenever it runs, and a break between them restores the databases after
the first.

**The append-only file.** An effect is tied to a database (`A.Eff`): a command's to the
database it ran on, while SWAPDB, MOVE (from the database the key leaves) and FLUSHALL
have their own. The writer of the append-only file remembers which database the file
selected last, and before the records of another one writes a SELECT, as Redis does;
SWAPDB, MOVE and FLUSHALL are written as Redis writes them. On reading, SELECT moves the
replay's focus, and everything else does the same as the server did. `redis-check-aof`
accepts the file, Redis 7.0.15 loads it into the same databases, and BendKV loads
Redis's file.

**The proofs.** The laws of persistence are stated for several databases and proved
anew: after any history, each batch at its own time and on any database, the server
restores exactly the databases it held (at time 0), and a file cut anywhere restores the
databases after some prefix of the acts. The replay keeps an invariant with the server's
databases: each database reads the same at time 0, the replay's focus is the database
the file selected last, and its time is 0; an act without an effect changes nothing at
time 0, and an act with an effect does to the replay the same as to the server's
databases. The database numbers in the file read back, because there are 1 + n
databases, and n is shorter than 15 digits (a hypothesis of the laws: in Redis
`databases` is an int). Five new laws are about what SELECT, SWAPDB, FLUSHALL and MOVE
do: 58 laws, ~1,260 new lines of proofs (6,141 against 4,885); `make check` takes ~4 s,
`make verdict` ~38 s (before the step ~3 and ~30).

**What the tests found.** The differential test now goes over databases 0–3, moves keys
and swaps databases, with bad numbers among them, and found one difference: a number
outside an int (`SELECT 2147483648`) BendKV took as "not an integer", while Redis answers
"value is out of range, value must between -2147483648 and 2147483647". Now the numbers
are read by the long long reader of section 21.

The cost (callgrind, `make perfcheck`):

| | GET | SET | INCR |
|---|---:|---:|---:|
| before the step (section 22) | 3,086 | 4,022 | 4,172 |
| after | 3,141 | 4,070 | 4,226 |
| difference | +55 (+1.8%) | +48 (+1.2%) | +54 (+1.3%) |

This is the zipper around the focus and moving the focus to the connection's database
before each batch. `tools/perf_baseline.txt` was rewritten to the new numbers.

Redis's test suite now runs with all databases (without `--singledb`): BendKV passes 219
of the 1,673 tests that Redis passes (it was 213 of 1,656), and 195 of 325 in the units
of what it has. Of the 17 tests that need several databases and that Redis passes, 6;
10 of the others need COPY, MULTI, WATCH, Lua or lists, and MOVE's basic test passes
alone but in its unit counts a key that earlier tests left: the test that would have
emptied the database stops at XADD (docs/COMPATIBILITY.md).

## 24. Ranges and bits of strings

GETRANGE (and SUBSTR, its old name), SETRANGE, GETBIT, SETBIT, BITCOUNT and BITPOS answer
as Redis 7.0.15 does, with errors in the same places as Redis: GETRANGE reads the range
before it looks up the key, BITCOUNT and BITPOS only after finding the key (BITCOUNT of a
missing key answers 0, whatever stands in place of the numbers), BITPOS reads the bit
first. The numbers are long longs, as `string2ll` reads them; a range below zero counts
from the end and is clipped to the value, in bytes or (BIT) in bits. SETRANGE and SETBIT
pad the value with zero bytes and do not let it grow past 512 MB (the default
`proto-max-bulk-len`: a new value of this parameter BendKV, as before, stores but does
not apply).

**The command stays one word.** The compiler lays out a non-recursive type flat, and a
parsed command travels in registers as wide as its widest form (section 17). A range is
two long longs: keep them as numbers, and GETRANGE would make every command three words
wider. So GETRANGE, BITCOUNT and BITPOS keep their arguments as they came (one word), and
exec reads them again; the parser checks GETRANGE's arguments at once, as Redis does
before looking up the key. GETBIT's offset is one Nat, and SETRANGE and SETBIT travel in
an update, which is a separate node anyway. exec keeps a range number as a "place": 2^41
plus the number whose absolute value is clipped to 2^40 (more than the length of any
value in bits); this does not change the replies, once the case Redis answers at once
(both numbers below zero and the start after the end) is decided by the numbers
themselves. A Nat literal is no larger than a 32-bit word, so 2^40, 2^41 and SETBIT's
bound 2^32 are products.

**The append-only file.** SETRANGE writes to the append-only file a SETRANGE of the
written bytes, not the value (as APPEND writes APPEND), and SETBIT a SETRANGE of the byte
its bit is in: a SETBIT in a megabyte bitmap costs the append-only file a few bytes, as in
Redis (where it writes the SETBIT itself). This is a new change `R.CRange{off, s, v}`; it
is good (`GoodRange`) when SETRANGE of s at offset off changes the key (`R.range.go`: s
is not empty and the value does not go past 512 MB), and v is the old value with s at
offset off. Then its effect at time 0 gives v again (`range_replay`), and the record
reads back as itself, because an offset has at most 14 digits (`num14_show`, as for
times). SETBIT computes its change as the change of a SETRANGE of the new byte, so it is
good by the same lemma; a SETBIT whose bit is already set that way (in a long enough
value) changes nothing and writes nothing to the append-only file. A key that is not
there is created by a SET of the new value, so a key whose time has passed meanwhile
starts anew on replay, as in execution.

**The proofs.** The laws of persistence hold for the new updates with no changes in
their statements: the change of every update is good (`good_none`, `good_some`, a case
for each), and the lemmas about the change (it does not touch other keys, the bridge to
the specification, the time) got a case each, as for APPEND. One new law,
`setrange_effect`: SETRANGE of an existing key writes s at the offset, keeps the key's
time and answers with the new length. 59 laws; ~100 lines of proofs more (6,238 against
6,141); `make check` takes ~4 s, `make verdict` ~40 s.

**What the tests found.** There was nothing to fix: ~200 hand-written cases at Redis's
edges (numbers outside a long long, ranges both ways, units in any case, offsets near
2^32 and 512 MB) and the differential test, which now draws ranges, offsets and bits —
~138 thousand commands — matched Redis byte for byte, as did INFO's statistics for the
new commands (calls, failed calls, errors). The replies of the commands that read a range
while running (BITCOUNT, BITPOS), and of SETRANGE (the error past 512 MB), are looked
through for errors (`RISKY` in `tools/gen_commands.py`).

The cost (callgrind, `make perfcheck`):

| | GET | SET | INCR |
|---|---:|---:|---:|
| before the step (section 23) | 3,141 | 4,070 | 4,226 |
| after | 3,137 | 4,069 | 4,223 |

There is no cost: the new names lengthened the comparison chains only for names of 6 and
8 letters, and the session commands moved from number 40 to 100 to make room for the
database commands. `tools/perf_baseline.txt` is unchanged. There are now 80 keys of INFO
statistics, which is 324 codes of the 924 twelve-bit words with six ones: room for 230
keys, fewer than Redis's commands and subcommands, so the codes will need more bits
before all the types come.

Redis's test suite: BendKV passes 268 of the 1,673 tests that Redis passes (it was 219),
and 244 of 370 in the units of what it has: `unit/type/string` 60 of 77 (it was 41),
`unit/bitops` 30 of 45 (it was 0). The rest there need LCS, MSETNX, BITOP, BITFIELD,
other types or replication (docs/COMPATIBILITY.md).

## 25. TOUCH, TIME and OBJECT

TOUCH counts the keys that are there, as EXISTS does: in Redis TOUCH also updates the
key's last access time, which BendKV does not store. TIME answers with the time at which
the batch runs (the clock is read once per group of batches), in s and µs (accurate to
the ms). OBJECT answers about what Redis stores next to the value from the value itself:
BendKV stores neither encodings nor access times. ENCODING is how Redis 7.0.15 encodes a
value set whole (`int` for a long, `embstr` up to 44 bytes, `raw` for longer), and a
value made by APPEND, SETRANGE or SETBIT is `raw` in Redis, whatever it holds; REFCOUNT
is 2147483647 for integers from 0 to 9999, which Redis makes shared, unless `maxmemory`
is set with an LRU or LFU policy (BendKV judges by the current parameters, Redis by those
in force when the value was created); IDLETIME and FREQ are 0, with a refusal under the
policy under which Redis refuses, and with its error texts. TIME and OBJECT are session
commands (they read the clock, the parameters and the selected database), so they do not
change the databases, and the session proofs got a case for each, as for the other
session commands. OBJECT is counted in INFO's statistics by subcommand, as CLIENT and
CONFIG are, and the replies of FREQ and IDLETIME, which under one policy or another
refuse while running, are looked through for errors.

The cost (callgrind, `make perfcheck`): INCR 4,235 instructions per request (+9, +0.2%):
TIME lengthened the chain of four-letter names, where INCR is too; GET 3,138 and SET
4,068 are the same. Redis's test suite: BendKV passes 272 of the 1,673 tests that Redis
passes, and 248 of 370 in the units of what it has (two TOUCH tests, PEXPIREAT to a time
from TIME, and INCR's shared integers, seen through OBJECT REFCOUNT); one more test now
fails not on a missing command but on the last access time.

## 26. MSETNX and RENAME

MSETNX sets its pairs only if none of its keys is there (otherwise it answers 0); RENAME
moves the source key's entry — the value and the time — into the target, whatever was in
it; RENAMENX only if the target key is not there. The errors and replies for a key
renamed to itself are as in Redis 7.0.15 ("no such key"; OK, and 0 for RENAMENX).

These commands broke the lemma the commutativity laws stood on: "a command changes a key
only as a function of that key's own entry" (`point_cmd`). RENAME changes the target key
as a function of the source, and MSETNX's verdict for each key depends on all of its
keys, so a key that one command writes can read differently after the two orders: SET s
1, then RENAME s d leaves d = 1, while RENAME s d, then SET s 1 leaves d as s was. The
fix is a set of keys for each command, `deps` (the keys of MSETNX, both keys of RENAME),
on whose entries its writes depend: `point_cmd` now holds for two tries that agree on
`deps(c)`, `commute_reads` got the condition "no command writes a key that the other's
writes depend on" (`spoils`), and `clash`, which decides whether adjacent commands of a
batch can be swapped, includes it. For the earlier commands `deps` is empty, and their
proofs got one unused argument each. The induction that carries the agreement of keys
through the rest of a batch now proves agreement on a list of keys at once (`deps` of
each command, from the run before it): key by key would need mutual recursion, which
Bend does not accept. Agreement is a type built by recursion on the list, a pair of an
equality and agreement on the rest; the induction hands one agreement to each key of the
list, so it must be reusable (`+`), that is, of kind Data. `A & B` in Bend is
`Sigma<&1, &1, A, _ => B>`, of kind Type; the same pair of kind Data is
`Sigma<&2, &2, A, _ => B>`, and equalities are Data.

The append-only file: MSETNX writes an MSET of its pairs if it set them, otherwise
nothing; RENAME, and a RENAMENX that moved the entry, write `RENAME src dst`, and that
replays at time 0 the same way it ran: the entry RENAME found at the moment now is there
at time 0 too, and RENAME does not look at the target key. RENAMENX is written as RENAME
because on replay at time 0 a target key whose time has passed would be "there", and
RENAMENX would not fire. The replay goes by the same code path over the same trie, so
the key counts come out the same too. Three laws: `rename_effect` (the source key is
gone, the target holds its entry, the reply is OK), `msetnx_present` and
`msetnx_missing`; 62 in all.

The cost (callgrind, `make perfcheck`): GET 3,144, SET 4,070, INCR 4,229 instructions
per request (in the baseline 3,141, 4,070 and 4,226), the same. Redis's test suite:
BendKV passes 285 of the 1,673 tests that Redis passes (17.0%), and 261 of 370 in the
units of what it has: `unit/keyspace` 35 (it was 27), `unit/type/string` 65 (it was
60). The differential tests ran ~120 thousand commands with MSETNX and RENAME, and all
replies matched Redis.

## 27. COPY

COPY gives the target key the source's entry — the value and the time — in the selected
database or in the one named by DB, if the target key is not there or REPLACE is given,
and answers 1, otherwise 0. The options are read as Redis 7.0.15 reads them, word by
word: REPLACE and DB in any order and case, the DB number like SELECT's number (with
Redis's errors for a number out of range and not an integer), any other word is a syntax
error, and a key copied to itself in its own database is "source and destination objects
are the same".

COPY reads the selected database and writes another, so it is not a command of one
database (`exec` works only with the focus) but an act, like MOVE: `ds.copy` reads the
live entry of the source key in the focus and the target's entry in the target database,
and puts the target database back with this entry. The session parses the options and
checks that the source and target keys differ before the act, so the act itself has no
errors.

The append-only file: a COPY that copied is written after a SELECT of the database it
copies from, as `COPY src dst DB n REPLACE`, whatever the client sent: on replay at time
0 a target key whose time has passed would read as "there", and COPY without REPLACE
would not copy. The loader reads this form at once, and the recovery laws go through it
as through MOVE. Any other COPY, as Redis writes it (as the client sent it: without DB,
in lower case, REPLACE before DB), is read word by word, and without DB into the focus:
this is a separate act (`ACopyHere`), because the loader does not know which database the
file selected last. Its proofs are the proofs of COPY with the focus's number instead of
the target database's number. A new test (`tests/aof_redis_test.py`, in `make test`)
sends the same commands to BendKV and to a redis-server with its own append-only file,
then starts BendKV from Redis's file and Redis from BendKV's file: each holds the same
databases the other held.

The recovery laws on several databases got a COPY case: a COPY that copied does to the
replay the same as it did to the server's databases (the replay first moves the focus to
the source key's database, `post_copy`), and one that did not copy changes no database.
A new law `copy_key`: if the source key is there, and the target is not or REPLACE is
given, the databases after COPY read at time 0 the same as before it, except the target
database, where the target key holds the source's entry; 63 laws in all.

The cost (callgrind, `make perfcheck`): GET 3,143, SET 4,072, INCR 4,236 instructions
per request (it was 3,144, 4,070 and 4,229): INCR +7 (+0.2%), as COPY lengthened the
chain of four-letter names, as TIME did before. Redis's test suite: BendKV passes 292 of
the 1,673 tests that Redis passes (17.5%), and 268 of 370 in the units of what it has:
`unit/keyspace` 42 (it was 35), all seven COPY tests on strings, three of them among the
17 tests that need several databases (9 of those pass now). The differential tests ran
~165 thousand commands with COPY (into databases 0–3, with REPLACE and without, with bad
numbers and options), and all replies matched Redis.

## 28. A number above 2^48 stopped the server

A database number is read as Redis reads it (a long long, so that the error says "out of
range" where Redis's does), and was built as hi * 10^9 + lo inside `Bool.pick`, which
evaluates both arms: for a number from 2^48 on the product was built even when the other
arm was taken, and the runtime stops on a Nat above 2^48. `SELECT 9223372036854775807`
stopped the server, as did MOVE, SWAPDB and COPY with such a number. The other places
where long longs are read already built the product in a separate function that matches
on whether the number is small; now this one does too. HELLO read the protocol version as
BendKV's integers (14 digits) and called a longer long long "not an integer"; now it
reads a long long, as Redis does (`NOPROTO` for 9223372036854775807). A new test
`tests/numbers_test.py` (in `make test`) sends every command that takes a number the
numbers at the edges (above a long long, LLONG_MAX and LLONG_MIN, 2^48, 2^32, 2^31, and
the forms Redis rejects: `+5`, `1e5`, `0x10`, `" 5"`, `-0`, `00`, `3.5`): 741 commands,
each with Redis's reply, except INCRBY and DECRBY longer than 14 digits and SCAN with a
cursor that BendKV did not hand out; these differences are already described.

## 29. BITOP and LCS

BITOP AND, OR and XOR combine their sources byte by byte (a key that is not there has no
bytes, a shorter value is padded with zero bytes); NOT complements its single source. The
value is set on the target key as SET sets it (the time to live goes away), and an empty
value deletes the target key; the reply is the value's length. The operation's name is
in any case and up to the first zero byte, as `strcasecmp` reads it, and the errors are
as in Redis (a syntax error for another name; NOT with more than one source).

BITOP is the third command whose write depends on keys other than the one written: its
`deps` are its sources, so the commutativity laws hold for it, as for MSETNX and RENAME,
through three lemmas: the value is the same in two tries that agree on the sources
(induction over them), the write leaves a key with the same entry in two tries with the
same entry, and it changes no keys other than the target. BITOP's write is a SET or DEL
of the target key, and the append-only file is the same, so the laws of the append-only
file needed nothing that SET and DEL did not have. A new law `bitop_store`: after BITOP
the target key holds the value with no time to live (or is not there if the value is
empty), and the reply is the value's length; 64 laws in all.

LCS is the longest common subsequence of two values, as Redis 7.0.15's `lcsCommand`
finds it: a table of the LCS lengths of all pairs of prefixes, then a backward pass from
the last cell, which takes a byte when both prefixes end with it, and otherwise drops the
last byte of the first value if the cell above is greater than the cell to the left,
otherwise of the second (this tie rule decides which subsequence and which segments come
out). LEN answers with the length without the pass; IDX with the segments the pass took,
starting from the last, each as ranges in both values, with the length after
WITHMATCHLEN, without segments shorter than MINMATCHLEN; otherwise with the subsequence
itself. LCS is a session command, like OBJECT: it reads the selected database and
proto-max-bulk-len, which limits the table (4 bytes per cell, as in Redis). It does not
change the databases, so its proofs are a case each in the session proofs. The table is
lists of numbers, about 16 bytes per cell against 4 for Redis, and is computed slowly:
two values of 4,000 bytes (16 million cells) take 1.1–2.5 s against 0.06 s for Redis;
the largest table that proto-max-bulk-len lets through by default (134 million cells)
would take BendKV tens of seconds and gigabytes.

The cost (callgrind, `make perfcheck`): GET 3,146, SET 4,076, INCR 4,240 instructions
per request (it was 3,143, 4,072 and 4,236, +0.1%). Redis's test suite: BendKV passes
311 of the 1,673 tests that Redis passes (18.6%), and 287 of 370 in the units of what it
has: `unit/bitops` 43 of 45 (it was 30: twelve BITOP tests and a check of BITPOS and
BITCOUNT that BITOP NOT prepares), `unit/type/string` 70 of 77 (five LCS tests) and
COMMAND GETKEYS for LCS. The differential tests ran ~100 thousand commands with BITOP and
LCS (operations and options in any case, invalid ones, the target key among the
sources), and all replies matched Redis.

## 30. BITFIELD: 64-bit words where a Nat stops at 2^48

BITFIELD and BITFIELD_RO are like Redis 7.0.15's `bitfieldGeneric`: fields of 1 to 64
bits, signed (two's complement) and unsigned (up to 63 bits), at any offset in bits or
`#k` (k field widths); GET, SET (the reply is the old value), INCRBY (the new one) and
OVERFLOW WRAP, SAT or FAIL for the operations after it; an overflow under FAIL writes
nothing and answers null. The errors are as in Redis and in the same order in which
Redis checks the words: the subcommand with the words it needs, the type, the offset
(below 2^32, the bits of 512 MB), the value (a long long). A BITFIELD of GETs only is a
read (Peek), like BITFIELD_RO; with a write it is an update (Upd), like SETBIT. COMMAND
GETKEYS gives its key the flags that Redis's `bitfieldGetKeys` gives: read-only while its
words are GET and OVERFLOW.

**A 64-bit word.** A field's value reaches 2^63 in absolute value, and Redis's
arithmetic on it wraps around as in C, while a Nat stops at 2^48. A word is two U32
halves (U32 wraps around as `uint32_t` does in C): addition with carry, negation, signed
and unsigned comparison, masks, sign extension and decimal writing by division by 10^9
over 16-bit digits, so no Nat above 2^47 is built. Redis's overflow checks
(`checkSignedBitfieldOverflow`, `checkUnsignedBitfieldOverflow`) run on these words as
written, together with the wrapping intermediate sums:
`OVERFLOW SAT SET i8 0 -9223372036854775808` stores 127 both in Redis (its `maxincr`
wraps around) and in BendKV. Two Bend traps shaped the code: a U32 shift compiles to a C
shift, and a shift by 32 or more is undefined in C; `Bool.pick` evaluates both arms. So
every shift that can reach 32 stands in a def that matches on which half it belongs to.
The reply is the text of the word, a separate kind of reply (`RIntS`): an Int holds 48
bits.

**Writing.** Redis grows the value up to the last byte a write reaches (for a key that is
not there, it creates it), and runs the operations in order on it. BendKV runs them on
the segment of bytes the writes reach, from the first byte of the first write to the last
byte of the last: at the start these are the value's bytes, past its end zeros; a write
reads the field there and puts it back there, and a GET reads the segment where the field
lies on it, and the value elsewhere. The change is a SETRANGE of the segment, as SETBIT's
is a SETRANGE of its byte; it is made when the value grows or a write changes bits (that
is how Redis counts changes). So the append-only file has a SETRANGE, and the proofs
needed nothing that SETRANGE did not have: two lemmas per case (whether the change is
made and whether its range fits). If all writes failed (OVERFLOW FAIL) on a key the
command creates or grows, Redis keeps the key but does not write it to the append-only
file, since it counts only the writes made, so its file and its replicas lack a key that
is in memory. BendKV keeps the key too and writes it to the append-only file. For a field
across the 2^32nd bit Redis grows the value to 8 bytes over 512 MB; BendKV, whose value
is at most 512 MB, answers there with SETRANGE's error.

**Cost.** At pipeline 16 (`redis-benchmark`, medians of three rounds, each alternating
with Redis) BITFIELD INCRBY of a u8 field does 530 thousand requests per second against
1,050 thousand for Redis, GET of an i32 field through BITFIELD_RO 660 thousand against
1,110 thousand, a BITFIELD of eight operations (four INCRBY and four GET of a u63 field)
110 thousand against 340 thousand: its 34 words are parsed one by one into the states of
an automaton, the bits of each field pass through words of two halves, and the runtime
spends a fifth of its time freeing what is left of them. The first version, which read a
field bit by bit and every number as a long long word, was about 30% slower still; the
difference came from reading the field in parts of bytes, short numbers as Nat (`num14`;
the long long path only for long ones) and arms that are computed only on the chosen
side. Placed after RInt, `RIntS` made GET 1.5% more expensive (3,194 instructions per
request against 3,146): the tags of the replies after it moved, and the reply encoder
compiled differently. Placed last, it costs nothing: GET 3,147, SET 4,077, INCR 4,238
instructions (it was 3,146, 4,076 and 4,240). Redis's test suite: BendKV passes 327 of
the 1,673 tests that Redis passes (19.5%; it was 311), and 303 of 386 in the units of
what it has: `unit/bitfield` 16 of 16. One more `unit/bitops` test, which is now
reached, counts the changes since the last save (`rdb_changes_since_last_save`), and
BendKV does not count them. Tests: `tests/bitfield_test.py` in `make test` (3,000 random
commands on three keys; fields of all types at offsets up to 256 bits or `#k`, values at
the edges of fields and of long long; each reply and each value after it is checked
against Redis), BITFIELD in the differential test (with invalid types, offsets, values
and words), its offsets and values in `tests/numbers_test.py` (among them
`#288230376151711745` of an i64 field, which wraps around to 64) and BITFIELD in both
append-only files: Redis's, loaded by BendKV, and BendKV's, loaded by Redis.

## 31. A value with a type: strings and collections

A key held a string; now it holds a `KV.Val`: `VStr{s}`, a string, or `VColl{c}`, a
collection (`KV.Coll`). Hashes come first: `HSmall`, a list of field–value pairs in the
order of adding, like Redis's listpack, and `HBig`, a trie of fields, like its hashtable.
The trie is generic in its value, so the eleven map laws hold for `Trie<Val>` just as
for `Trie<String>`; the database, the specification, the bridge, the append-only file and
the sessions changed only the type. No command creates a collection yet (the next step
is hashes), so a client sees no difference: this is the groundwork for the types.

**What a command sees.** Redis answers
`WRONGTYPE Operation against a key holding the wrong kind of value` to a command of one
type on a key of another. A string command reads the key's entry through a view
(`peek.v` for reads, `upd.v` for updates): a string's entry goes to the string code as
before; a collection's entry is WRONGTYPE, and the key does not change, except for the
commands that act on a key of any type. SET (and SETEX, PSETEX) replaces it, SETNX finds
the key in place, EXPIRE and its kin and PERSIST set the time: for them it is a key with
its own time and an empty string, which none of them reads. TYPE names the collection's
type, TTL, PTTL, EXPIRETIME and PEXPIRETIME answer with its time. SET with GET and GETSET
read the old value and so give WRONGTYPE, as in Redis. The key commands (DEL, EXISTS,
RENAME, COPY, MOVE, KEYS, SCAN, TOUCH, the sweep) carry any value. MGET answers null for
a collection, as Redis does; BITOP gives WRONGTYPE if a collection is in even one source
(it checks all before computing); LCS answers Redis 7.0's
`ERR The specified keys must contain string values` before parsing the options. TYPE in
SCAN compares the type's name (`string`, `hash`, in any case), and OBJECT ENCODING of a
hash is `listpack` or `hashtable`. GET reads a copy made while the trie is lent (section
7.25); now it is a `Got`: a copy of the string, a mark that the key holds a collection,
or nothing, so a read does not build a `VStr` and does not copy a collection. INCRBY
reads the same way.

**The proofs.** The laws of the commands now say for which values they hold: APPEND's
for a key without a collection, GETDEL's and SETRANGE's for a key with a string, BITOP's
when no source holds a collection; SETNX, PTTL, PERSIST, SET with KEEPTTL, RENAME, MOVE,
COPY and the frame laws hold for a key of any type. BITOP's verdict on its sources' types
is the same in two tries that agree on the sources, which the commutativity laws need:
otherwise a write to another key could change it. The proof of the append-only file
replays each update's change at time 0 from the effect in the file and requires the
change to be "good" for the key's entry (`Good`); the changes of APPEND and SETRANGE are
good only for a string, whose value the replay reads again. An update that acts on a key
of any type sees a collection as an empty string (`any_v`:
`upd.v(op, now, Some{Item{w, e}})` is `upd(op, now, Some{Item{sview(w), e}})` for SET,
SETNX, EXPIRE and PERSIST), so a replay of PERSIST, PEXPIREAT or SET KEEPTTL on a
collection makes the same change. BITOP with a WRONGTYPE reply writes nothing to the
append-only file. Of the 928 definitions of the proof, 275 changed (mostly only the type
of values), and 27 appeared; the map laws did not change.

**The cost is a node per value.** A string now lies behind a node of its own, `VStr`,
while before it lay in the entry itself (a value of up to 6 bytes inside the entry's
word). Instructions per request (`make perfcheck`, 100 thousand keys): GET 3,272 (it was
3,141, +4.2%), SET 4,261 (4,070, +4.7%), INCR 4,499 (4,226, +6.5%); the baseline was
rewritten. With a million keys, where the node is a separate miss: GET 3,376
instructions and 5.69 last-level cache misses per request (it was 3,223 and 4.18), INCR
4,830 and 7.53 (it was 4,513 and 5.25); the batch hints reach the node only after the
entry has arrived, too late for the read behind it. In time (`tools/bench_pairs.sh`, a
million keys, pipeline 16, 20 clients, five pairs): GET and SET as before (1.00 of the
old build, medians of pairs), but with +11% and +6% of user CPU per request; INCR 0.89:
it reads the node, builds a new one and frees the old. Memory: a million keys with
3-byte values take 64 bytes per key against 56 (`VmRSS`), one word more. The way back is
in the compiler, not in BendKV: a type in which one variant holds a String and the rest
are constructors could keep that variant as the string's own word (a string's tag is not
a constructor's tag), without a node and without a single change in the proofs. This is
planned for after the types.

## 32. Hashes

HSET, HMSET, HSETNX, HGET, HMGET, HDEL, HLEN, HSTRLEN, HEXISTS, HKEYS, HVALS, HGETALL,
HINCRBY, HSCAN and HRANDFIELD, plus MEMORY USAGE. A hash is `HSmall`, pairs in the order
they came, while there are at most 512 fields and fields and values are no longer than
64 bytes (the default listpack limits in Redis 7.0), and past that `HBig`, a trie of
fields, for good, as Redis turns a listpack into a hashtable. BendKV converts a hash by
the default limits whatever the parameters say: this way the hash after a history of
writes depends only on the writes, and the append-only file builds it anew on any
server; OBJECT ENCODING reads the parameters as they are. A small hash gives HGETALL,
HKEYS, HVALS and HSCAN in the order the fields came, byte for byte as Redis; a large one
in the order of the trie (Redis in the order of its table; both orders are arbitrary),
and HSCAN walks its buckets with a cursor, as SCAN walks the keys. HRANDFIELD picks by
the server's random numbers, as RANDOMKEY does.

**The append-only file and an expired key.** A write of a hash goes into the append-only
file as what it did: an HSET of the pairs set (for HSETNX its pair, for HINCRBY the field
with the sum, HMSET as HSET), an HDEL of the fields taken, a DEL if the last one was
taken. One case did not fit: a write that makes a new hash where the trie still holds an
expired key. At time 0, when the append-only file loads, that entry is alive again, and
an HSET of the new pairs would add them to the old hash or run into a string. Redis 7.0
deletes the key when a write comes to it and writes `MULTI`, `DEL`, the write itself,
`EXEC`: two records between which the file can break off (Redis's loader drops an
unclosed MULTI). BendKV's law about a break rests on an act writing at most one record.
Considered: lazy deletion as a separate act (then the write itself would have to act on
the raw entry of the trie, and the fast path would have to go around it), MULTI/EXEC
groups in the file (the file's laws would have to be restated for groups), RESTORE (the
RDB encoding and CRC64) and one record, an EVAL of a fixed script:
`redis.call('del', KEYS[1])`, then HSET with a thousand arguments per call. EVAL was
chosen: one record, which Redis runs on loading (before 5.0 Redis itself wrote EVAL into
the append-only file), and which BendKV parses back as `HWNew`, a write that makes a new
hash whatever lay in the key. The laws keep their form. EVAL with another script answers
with an error (BendKV has no Lua). Checked both ways: Redis loads such a file (3,001
pairs in parts), and BendKV loads it the way Redis runs it.

**The proofs.** Of the 972 definitions of the proof, 42 changed and 44 were added; the
laws did not change: the hash commands are reads (`Peek`) and updates (`Upd`) of their
key, and the frame, commutativity, append-only file and session laws cover them. New:
`Good` for the two changes of a hash, the replays of HSET, HDEL and the script, the parse
back of each, one effect per change (the effect of a new hash depends on whether there
was an entry in the trie, so an effect now gets the entry's code). Laws of hashes of
their own (HSET, then HGET answers with the value) do not exist yet.

**The kernel's stack.** `make verdict` failed with a JavaScript stack overflow in the
translation to the kernel: the statistics table that returns a code by a 12-bit word
(`stat.code.cw`) matched numbers up to 2,095, and a match on a number unfolds one level
of recursion per unit; with the 76 codes of the new commands the largest number grew from
1,713 to 2,095 and broke through the stack. Now the table matches the word's high six
bits, then the low ones: numbers up to 63.

**Cost.** Instructions per request (`make perfcheck`): GET 3,291 (it was 3,272, +0.6%),
SET 4,287 (+0.6%), INCR 4,561 (+1.4%), within the guard's 3%; the baseline stays. The
hash itself costs as much as its form: HGET of a small hash walks a list (as Redis walks
a listpack), HRANDFIELD on a large hash builds a list of pairs on every call (O(n)
against O(1) for Redis). There is no benchmark of hashes yet.

**Redis's test suite and the tests.** BendKV passes 391 of the 1,673 tests that Redis
passes (23.4%; it was 327), and 365 of 458 in the units of what it has. Hashes brought
64: `unit/type/hash` 56 of 72 (the rest: twelve HINCRBYFLOAT tests, two that read a hash
back through DUMP, HRANDFIELD over RESP3, and the HINCRBY overflow test, which starts past
14 digits), three HSCAN tests in `unit/scan`, COPY of a hash in both encodings and
COMMAND GETKEYS for EVAL and MEMORY USAGE. Tests: `tests/hash_test.py` in `make test` (a
script of commands at the edges, hashes of 511, 512, 513 and 1,200 fields on both sides
of the listpack limit, keys with an expired time, then 3,000 random commands on several
keys; each reply is checked against Redis: HRANDFIELD by what the picks must be, MEMORY
USAGE by the kind of reply, a hashtable's fields as a set), hashes in the differential
test, in both append-only files (BendKV loads Redis's, Redis loads BendKV's, the script of
a new hash among them) and in restarts from its own append-only file, and also COMMAND
GETKEYS for EVAL and the hash commands in the COMMAND test.

## 33. Lists

LPUSH, RPUSH, LPUSHX, RPUSHX, LPOP and RPOP (with a count), LLEN, LINDEX, LRANGE, LSET,
LINSERT, LREM, LTRIM, LPOS, LMOVE, RPOPLPUSH and LMPOP. A list is a deque of two stacks
(`Deq`): the front elements in order, the back ones in reverse, so adding and removing at
either end puts or takes the head of one of them. When one part has more elements than
three times the other plus one, the elements are dealt anew, half and half: adding and
removing cost O(1) on average, and LINDEX, LSET and LRANGE go only from the end nearer to
the target. A key does not hold an empty list: a write that removed the last element
deletes the key, as in Redis. OBJECT ENCODING answers `quicklist`, as Redis 7.0 does for
any list. Arguments are read where Redis reads them: the counts of LPOP and LREM and the
ranges of LRANGE and LTRIM when the command is parsed, before the key is looked up; the
index of LINDEX and LSET when the list is found; LPOS's options in turn, the last of the
same ones wins, and a RANK equal to LLONG_MIN as in Redis 7.0.15 (its negation overflows
in C: the search goes from the last element and with COUNT takes all matches). A count
and an index can be any long long.

**A command travels in registers as wide as its widest form.** The first version of the
list commands raised the number of instructions on every request: GET +3.6%, SET +3.0%,
INCR +4.6%, though GET does not run them. Bend compiles a non-recursive nested type flat:
a value of `Cmd` travels in as many registers as the widest constructor needs with the
nested types unfolded, and the list reads inside `Peek` had forms with several fields of
their own. `Cmd` grew from 5 words to 11, and every call that passes a command (parsing,
hints, the dispatcher, execution) moved and dropped the extra words. Now the reads keep
their arguments as they came, as one word (a list of strings that the command reads
again when it runs; LRANGE and LPOS are first parsed by the parser, to answer with an
error as Redis does), and a list write holds at most two fields, so that a change with it
is no wider than a hash's. The cost fell to GET +0.8%, SET +0.7%, INCR +2.6%. INCR's
remainder is the dispatcher: there are more names with each type, and the chain of
comparisons for the length of INCR's name is longer; the next step is a dispatcher by
length, then by first letter.

**Moves between keys.** LMOVE (RPOPLPUSH is its RIGHT LEFT form) removes from one key and
puts onto another; LMPOP removes from the first of the keys that holds a list. Both are
commands whose writes depend on other keys (section 26): `deps` names LMOVE's two keys
and LMPOP's keys, and the commutativity laws, proved for any command with its
dependencies, cover them without a change to the laws. LMPOP is written to the
append-only file as a removal from the key it removed from (LPOP or RPOP with a count, or
DEL of the key if the last elements were removed): one record. Bend 2 has no mutual
recursion, so the search for the first key that holds a list computes the flag for the
first key before recursing and passes it down (`lmpop.first`).

**A destination with an expired time.** LMOVE onto a key whose entry still lies in the
trie with an expired time meets the same case as hashes (section 32): at time 0, when the
append-only file loads, the old entry is alive again, and a plain LMOVE would put the
element onto it. BendKV writes such a move as one record, an EVAL of a second fixed
script,
`redis.call('del',KEYS[2]) return redis.call('lmove',KEYS[1],KEYS[2],ARGV[1],ARGV[2])`:
Redis runs it on loading, and BendKV parses it back as `LMove` with the "new" form of the
ends, a move that takes the destination as empty whatever lies in it, and puts the new
list where its entry lies. The place matters: the proof of the append-only file compares
tries by structure, and a deletion followed by a set would move the key to the end of the
bucket. A list made by adding where an expired entry lay is written by the hashes' script
with the additions. (`tests/aof_redis_test.py` makes such keys with a time of 3 ms;
BendKV's sweep every 100 ms can remove them earlier, and then the file holds a plain move
onto an empty key.) In one case the servers differ, and it is in no file of BendKV's: the
move script with one and the same key as source and destination; Redis deletes the key
and moves nothing, BendKV moves the element within the list.

**A count the size of a long long.** `tests/numbers_test.py`, which now includes the list
commands, stopped the server: `LPOP key 9223372036854775807` on a list of five elements
removed an element per step for the whole count (a removal from an empty deque is also a
step, just one that changes nothing), 2^63 steps in all. Redis limits the count by the
list's length; now BendKV does too (`lpop.cap`), and the proof follows the code.
(`HRANDFIELD key -2147483649` asks both servers for 2^31 picks, and both start building
them; the test leaves it out.)

**The proofs.** Of the 1,053 definitions of the proof, the specification and the laws,
49 changed and 156 were added; the laws did not change. The one-key commands are reads
(`Peek`) and updates (`Upd`) of their key, as for hashes; LMOVE and LMPOP are separate
commands of the specification (`mv.find`, `mv.do`, `lmpop.first`) with their own lemmas
of frame, of the key's entry after them, of replies, of the bridge to the server's
records, and of time. New in the append-only file: `Good` for the two changes of a list
(a changed list: the write that the change keeps, replayed on the key's list, makes the
same change and is fit for the file: adding elements, removing a count that reads as a
number, LREM and LTRIM with readable numbers; a new list: its additions to an empty one),
proved for each write by its shape (`lw_shape`); the replay of LMOVE at time 0 (what it
finds then is what it found now: an entry alive now is alive at 0 too, and a dead
destination is taken as empty by the "new" form); the parse back of each write and of
both scripts; one record per command. Laws of lists of their own (LPUSH, then LPOP
answers with the element) do not exist yet.

**Cost.** Instructions per request (`make perfcheck`): GET 3,298 (+0.8%), SET 4,289
(+0.7%), INCR 4,614 (+2.6%), within the guard. Against Redis 7.0.15 (redis-benchmark,
pipeline 16, one key): LPUSH 1.08 million/s against 1.63, RPUSH 0.81 against 1.02, LPOP
0.60 against 1.15, RPOP 0.80 against 1.26, that is, 0.53–0.80 of Redis's throughput (GET
is 1.6 times). Adding a hundred elements per command to a list growing to 200,000: 33 µs
per command in a pipeline against 10 for Redis, 89 against 67 one at a time. Reading and
writing in the middle of a list of 200,000 go cell by cell: LINDEX 3.9 ms (Redis 0.06),
LSET 9.2 (0.05), LINSERT 19.9 (1.3), LREM 10.1 (2.5), LPOS 7.2 (1.5); near an end, 0.08
ms. Redis's quicklist hops over nodes of many elements; a deque of chunks would do the
same.

**Redis's test suite and the tests.** BendKV passes 424 of the 1,673 tests that Redis
passes (25.3%; it was 391), and 401 of 689 in the units of what it has. Lists brought 33:
all 11 in `unit/type/list-3`, both in `unit/type/list-2`, 15 of 218 in `unit/type/list`
(after that the unit switches to RESP3 and stops at HELLO 3) and 8 tests of other units
that need a list. Tests: `tests/list_test.py` in `make test` (a script of commands at the
edges, lists of 1 to 20,000 elements with reads and writes at both ends and in the
middle, a capped list and a queue, keys with an expired time as sources and destinations
of moves, then 3,000 random commands on several keys with moves between them; each reply
is checked against Redis), lists in the differential test, in the numbers test, in both
append-only files (both scripts among them) and in restarts, in `tests/aof_check.bend`,
and also COMMAND GETKEYS for LMPOP, LMOVE and the rest in the COMMAND test.

## 34. Choosing the command: by the name's length, then by the first letter

A request's name finds its command by a number (`cmd_id`), and each type of values adds
names: with lists, INCR's length (four letters) had 27 names, and each was compared with
the name (a chain of `Bool.pick` computes all; for a name of up to six bytes a comparison
is one comparison of words). Now `cmd_id` is written by `tools/gen_commands.py` from the
parser's own branches (each `case N:` in `parse_id` and `parse_sess` names its command in
a comment): a choice by the name's length, then by the first letter (by its place in the
alphabet, so that no match names a number above 26), then `String.eq` with the few
remaining names, at most eight of Redis's 241 commands. The numbers and the choice can
no longer diverge; a new command needs its branch in the parser and its name in the
generator's list.

**Cost** (callgrind, 20,000 requests of redis-benchmark with pipeline 16, as
`make perfcheck` counts): INCR 4,615 → 4,475 instructions (−3.0%, again 0.5% below the
guard's baseline), LPOP −1.6%, LPUSH −1.0%, HSET −0.7%, MSET −0.5%. GET and SET, whose
lengths had five names each, stayed where they were (3,295 and 4,289): a lookup by letter
costs about as much as four comparisons of words. The proofs check as before
(`make verdict`, 26.5 s): `R.parse` of a literal name passes the new matches by
computation.

## 35. Sets

SADD, SREM, SCARD, SISMEMBER, SMISMEMBER, SMEMBERS, SSCAN, SPOP and SRANDMEMBER (with a
count), SMOVE, SINTER, SUNION, SDIFF, their STORE forms and SINTERCARD with LIMIT. A set
is an intset or a hashtable, as in Redis 7.0 (which has no listpack sets yet). An intset
holds only canonical 64-bit integers (as Redis's `string2ll` reads them: of signs only a
minus, no leading zero, no `-0`), at most 512, as a list of their strings in numeric
order; any other member or a 513th turns the set into a hashtable for good, a trie of
members (`Trie<Unit>`, the same map as the keyspace's). An intset gives its members in
numeric order, as Redis does, and SSCAN gives it whole with cursor 0; a hashtable in the
order of its trie (Redis in the order of its table), so the tests compare a hashtable's
members as a set. A key does not hold an empty set. OBJECT ENCODING reads
set-max-intset-entries; the set itself turns into a hashtable after 512 members, whatever
the parameter says.

**Arguments where Redis reads them.** The counts of SPOP and SRANDMEMBER before the key
is looked up (SPOP: "must be positive", for a word too; SRANDMEMBER: any long long except
LLONG_MIN); numkeys and LIMIT in SINTERCARD with their own four errors; every key of an
operation on several sets is checked for its type, even after a missing one (SINTER then
answers with an empty set); SMOVE answers 0 for a missing source without looking at the
destination's type; SDIFF chooses between Redis's two ways by the same estimates, and
SDIFF of a set with itself is empty at once.

**Random picks.** SPOP and SRANDMEMBER take the server's random number (as HRANDFIELD
does) and the numbers of a Weyl sequence after it, each scrambled by `KV.mix`: a member
of an intset is picked by index, a member of a hashtable as RANDOMKEY picks a key. For k
different members of n, k less than n, BendKV follows Redis's ways: for an intset,
picking and dropping in turn; for a hashtable, if k is more than a third of n, dropping
n − k random members (Redis's third way), otherwise picking until there are k different
ones (the fourth). The picks pass Redis's own tests of them, including the chi-square
`SRANDMEMBER histogram distribution`. The proof of the append-only file needs acts that
do not depend on the data, so SPOP's act carries its random number, and its record in the
append-only file is an SREM of the members taken (that is how Redis propagates SPOP too)
or a DEL of the key if the last ones were taken.

**Operations on several sets.** STORE writes the destination with the update SWNew of
the resulting members, or deletes it if there are no members; SMOVE removes a member from
the source and adds it to the destination with the same updates that SREM and SADD make.
These are commands whose writes depend on other keys (section 26): `deps` names the
sources of STORE and both keys of SMOVE, and the commutativity laws cover them without a
change to the laws. STORE is written to the append-only file as the resulting members,
not as the command: an SADD of them if the trie had no entry for the destination,
otherwise the hashes' script with SADD (one record: the script first deletes the key).
The replay of the file then does not depend on the sources. SMOVE is written as is, and
onto a key with an expired time as one record, an EVAL of a third fixed script,
`redis.call('del',KEYS[2]) return redis.call('smove',KEYS[1],KEYS[2],ARGV[1])`, which
BendKV parses back as `SMv` with the "new" form of the member, as for LMOVE (section 33).

**Two changes the proofs required.** The replay of a new set made where there was no
entry runs an SADD of its members on a missing key, and this must make the same change
as the first time: a new set. SADD decided "no change" by the number of members added,
and the proof would have needed that adding one member or more to an empty set makes it
non-empty, a lemma about sizes in both encodings. Now SADD of a new set decides by
whether it has members at all (the reply is the same), and the lemma is not needed. SMOVE
read the values of its keys (`KV.read`); its replay at time 0 would then have had to
relate the values read at 0 and now. Now it reads the keys' entries in the trie and
checks their time against "now" (`db.ent`), as LMOVE does, and its replay works as
LMOVE's does: a source alive now is alive at 0 too; a destination with an expired time is
taken as missing by the "new" form; and the update of the destination makes at 0 the same
change as now, a new set of the member, whether SADD made it on a missing key or SWNew
where a dead entry lay.

**A bug the differential test found.** SET with GET on a key with a collection answered
WRONGTYPE at once; Redis checks the time first, so
`SET k v XX EX 9223370399119966 GET` answers "invalid expire time" there. With the set
commands such keys became frequent in the random stream. Now the order is Redis's, and
the proof that such a SET does not change the collection follows the code.

**The proofs.** Of the 1,212 definitions of the proof, the specification and the laws,
60 changed and 111 were added; the laws did not change. The set commands are reads
(`SOp`) and updates (`Upd`) of their key, and the STORE forms and SMOVE are separate
commands of the specification (`sstore`, `smv.find`, `smove.do`) with their own lemmas of
frame, of the key's entry after them, of replies, of the bridge to the server's records,
and of time. `Good` for the two changes of a set: a changed set, whose SADD or SREM,
replayed on the key's set, makes the same change, and which has members (SPOP's change is
an SREM of what was taken, so it needs no case of its own); a new set, its members
gathered into one. The replays of SMOVE and STORE at time 0, the parse back of each
record and of the third script, one effect per command. Laws of sets of their own (SADD,
then SISMEMBER answers 1) do not exist yet.

**Cost.** Instructions per request (`make perfcheck`): GET 3,296, SET 4,292, INCR 4,473,
as before sets (3,295, 4,289, 4,475): a set command holds at most two fields, and `Cmd`
did not get wider. Against Redis 7.0.15 (redis-benchmark, pipeline 16, 20 clients) the
commands on one member are about as fast: SISMEMBER on a small set 1.38 million/s
against 1.18 (on a set of 100,000, 0.72 against 0.78), SREM 1.23 against 1.06, SMOVE 1.34
against 1.18, SCARD 1.32 against 1.28, SRANDMEMBER on an intset 0.95 against 0.89; SADD
of random members up to 100,000, 0.65 against 0.80. A whole hashtable is read by walking
the trie, and the walk costs by the number of the trie's nodes: SMEMBERS of 10 members
0.22 against 0.53 (an intset 0.60 against 0.64), SINTER of two sets of 10 0.23 against
0.62, SUNION 0.09 against 0.21, SDIFF 0.19 against 0.38, SINTERSTORE 0.14 against 0.54.
A pick from a hashtable is slow: it looks through the trie's buckets from a random one
until it has 16 members, as RANDOMKEY does, and a deletion leaves the trie's nodes in
place, so a trie emptied by deletions is as expensive to look through as a full one:
SRANDMEMBER on a set of 100,000, 41,000/s against 714,000, on a set of 10, 111,000
against 1.1 million; SPOP of all 100,000 members, 7,240/s against 709,000, and the fewer
remain, the slower. The remedy is a deletion that gives back empty nodes and a pick that
descends the trie by counts; this is a change of the map and of its laws, and it is next
among the work on cost. (The deletion came in section 50: the last SPOPs of a set run as
fast as its first.)

**Where BendKV differs.** A hashtable's order; the picks themselves; MEMORY USAGE is an
estimate; set-max-intset-entries, which only OBJECT ENCODING reads; SRANDMEMBER with a
negative count larger than memory holds: both servers try to build the reply
(`SRANDMEMBER key -2147483649` stopped BendKV by running out of memory and fills Redis's
memory the same way; the tests leave it out); the move script with one key at both ends,
as for LMOVE (it is in no file of BendKV's).

**Redis's test suite and the tests.** BendKV passes 528 of the 1,673 tests that Redis
passes (31.6%; it was 424), and 512 of 800 in the units of what it has. Sets brought 104:
92 of 94 in `unit/type/set` (the other two need ZADD and WATCH), five in `unit/scan`
(four SSCAN tests and SCAN's regression test for issue #4906, which makes sets), two COPY
tests of sets in `unit/keyspace`, three in `unit/protocol` (raw protocol replies, which
are read from SRANDMEMBER), MGET on a set in `unit/type/string` and the last test of
`unit/sort`: the unit now goes past its SADD, and this test (named after SETRANGE, it
runs SORT_RO) catches any error. Tests: `tests/set_test.py` in `make test` (a script of
commands at the edges, intsets on both sides of 512 members and hashtables of up to
20,000, an intset grown past 512 one member at a time, keys with an expired time as
sources, destinations and operands, then 3,000 random commands on several keys; each
reply is checked against Redis: a hashtable's members as a set, each random pick against
the set it was taken from, the set after SPOP against the set without the members taken,
after which the key is made anew on both servers), sets in the differential test (SPOP
only where its pick is the whole set), in the numbers test, in both append-only files
(the third script and the script with SADD among them) and in restarts, in
`tests/aof_check.bend`, and also COMMAND GETKEYS for SINTERCARD, SMOVE and the STORE
forms in the COMMAND test.

## 36. Floating-point numbers in software: INCRBYFLOAT and HINCRBYFLOAT

Redis 7.0.15 on x86-64 keeps a sorted set's score in a double (53 bits of precision), and
adds INCRBYFLOAT and HINCRBYFLOAT in an x87 long double (64 bits). Bend has only a 32-bit
floating-point number, and a Nat stops at 2^48, so `src/float.bend` does both formats in
software: a number is a sign, a long integer m (limbs of 24 bits, so that the product of
two limbs with a carry stays below 2^48) and an exponent e, m * 2^e; each operation
rounds the exact result to the nearest number of the format, on a tie to the even one,
with subnormal numbers and overflow to infinity, as the FPU does in its default mode.
Text is read as glibc's strtod and strtold read it: decimal digits of any length (the
exact value is divided by a power of ten in limbs of 10^7, with a sticky bit for what the
division drops), hexadecimal ones with a binary exponent, `inf` and `infinity` in any
case, `nan`; an exponent without digits is not read, an exponent above 10^9 reads as
10^9, outside any range. Then Redis's string2d and string2ld reject a space as the first
character, a text not read to the end (including one with a NUL inside), NaN and a range
error (overflow to infinity or a non-zero number rounded to 0); string2ld also a text of
5,120 characters or more. A double is written as printf writes `"%.17g"`, a long double
as `"%.17Lf"`, from the number's exact decimal value (m times a power of five for a
negative exponent), rounding half to even; ld2string then removes the zeros at the end of
the fraction and writes `-0` as `0`. An integer of up to 14 digits is read at once, and a
double that is an integer below 2^47 is written at once too.

**Checked against glibc.** `tests/float_test.py` (in `make test`) writes random texts of
numbers: decimal and hexadecimal of up to 800 digits, exact midpoints between adjacent
doubles and between adjacent long doubles (and texts just above and just below), numbers
near the ends of both ranges, forms that strtod reads only partly; and also sums and
products of doubles and sums of long doubles. A Bend program answers each one, a C
program with glibc's strtod, strtold and printf (`tests/float_ref.c`: string2d,
string2ld and ld2string of Redis itself) answers as Redis would, and the answers must
match byte for byte: 2,308 lines in `make test` and about 9,500 while the library was
being written, not a single difference.

**INCRBYFLOAT and HINCRBYFLOAT** are as in Redis 7.0.15: INCRBYFLOAT finds the key
(WRONGTYPE for a collection), reads the value, then the increment
(`value is not a valid float` for either of them), adds, rejects an infinite sum
(`increment would produce NaN or Infinity`) and keeps the key's time; HINCRBYFLOAT reads
the increment before looking up the key (`value is NaN or Infinity` for infinity), then
the field's value (`hash value is not a float`). Both answer with the sum as ld2string
writes it for people; the append-only file gets a SET of the sum with KEEPTTL and an
HSET of the field, as Redis propagates them, so the file reads into the same strings on
any machine. After a million INCRBYFLOATs of 0.1 both BendKV and Redis hold
100000.00000000087324992.

**The proofs.** The changes are the same as INCRBY's and HINCRBY's (a SET of the value
with its time, an HSET of the field), so the laws needed nothing new: INCRBYFLOAT is an
update of its key (`UIncrF`), HINCRBYFLOAT a write of a hash (`HWIncrF`), and their
lemmas repeat the lemmas of INCRBY and HINCRBY (of 1,323 definitions, 8 changed and 8
were added). One trap: the proof checker runs a Nat as Base defines it, a step per unit,
and a lemma about writing a number stops where the writing meets a value it does not
know, having already computed the format. A format with the exponent biased by 2^40 (the
bias with which the library keeps exponents) overflowed the checker's stack there; now a
format keeps its bounds as small numbers, and the exponent of zero is 0.

**Command numbers.** The parser gives each command a number; the connection commands
(parse_sess) started at 100, and the commands of hashes, lists, sets and now floats
reached 99. `tools/gen_commands.py` now writes `cmd_own`, which recognizes parse_sess's
numbers by their ranges, so a new command of either parser takes the next free number.

**Cost.** Instructions per request (`make perfcheck`): GET 3,298, SET 4,290, INCR 4,478,
as before. INCRBYFLOAT is slower than Redis's hardware arithmetic: 207,000 requests per
second against 512,000 (redis-benchmark, pipeline 16, 20 clients, adding 1.5),
HINCRBYFLOAT 131,000 against 495,000 (adding 0.1): the long double has no fast path for
integers yet, and each sum is read from text and written back to text.

**Redis's test suite.** 552 of 1,673 (33.0%; it was 528): `unit/type/incr` passes all 24
of its tests (twelve INCRBYFLOAT tests were added), `unit/type/hash` 68 of 72 (twelve
HINCRBYFLOAT tests; the remaining four need DUMP, RESP3 and integers longer than 14
digits).

## 37. Sorted sets

ZADD (NX, XX, GT, LT, CH, INCR), ZINCRBY, ZREM, ZCARD, ZSCORE, ZMSCORE, ZRANK, ZREVRANK,
ZCOUNT, ZLEXCOUNT, ZRANGE (BYSCORE, BYLEX, REV, LIMIT, WITHSCORES) and its five old
forms, ZREMRANGEBYRANK, ZREMRANGEBYSCORE and ZREMRANGEBYLEX, ZPOPMIN and ZPOPMAX (with a
count), ZMPOP, ZRANDMEMBER (with a count, WITHSCORES), ZSCAN, ZUNION, ZINTER, ZDIFF,
their STORE forms, ZINTERCARD (LIMIT) and ZRANGESTORE: the 32 sorted-set commands of
Redis 7.0.15, except the three blocking ones. An element is a member and a score, a
double from `src/float.bend` (section 36): read as strtod reads it, written as Redis
writes a double, compared and added in double arithmetic. A sorted set is one
weight-balanced tree of its elements in Redis's order, by score, then by member (each
node remembers the size of its subtree, so a rank, an element by rank and a window of
ranks cost O(log n)), and past the listpack limits the same tree with a trie of members
with their scores next to it, for good: Redis's listpack and skiplist. The limits are
Redis's defaults (128 elements, members of up to 64 bytes); OBJECT ENCODING reads
zset-max-listpack-entries and -value at the moment of the reply, as for hashes. A key
does not hold an empty sorted set.

**Where the two encodings answer differently.** BendKV keeps Redis's encodings because
Redis's replies depend on them, in three places. A listpack stores a score that is an
integer of at most 2^62 in absolute value as an integer, so a small set never holds `-0`
(ZSCORE answers `0`), and ZSCAN, which gives a listpack's elements as they lie in it,
writes such a score as digits (`100000000000000000`, where ZRANGE writes `1e+17`);
BendKV writes `0` instead of `-0` in a small set and answers ZSCAN on it with Redis's
texts. A range by member (ZRANGEBYLEX, ZLEXCOUNT, ZREMRANGEBYLEX) is defined for elements
of one score; for others Redis walks a listpack from the first element and gives the
elements between the first that passed the lower bound and the first that passed the
upper one, and descends a skiplist by its random levels. BendKV answers on a small set
as the walk over a listpack does, and on a large one by a descent of the tree, which
answers as a skiplist does for elements of one score: the tests read ranges by member
only for those. ZRANDMEMBER with a count greater than the size gives the whole set from
the last element, as Redis's sorted-set iterator goes.

**Arguments where Redis reads them.** ZADD's options in any order and case, then its
errors in Redis's order (XX with NX, then GT, LT and NX together, then INCR with several
pairs, then a score that is not a double); the pairs from the first word that is not an
option, so a score `incr` is read as an option and leaves an odd number of words (a
syntax error). ZRANGE's loop of options with each of Redis's errors (LIMIT with fewer
than two numbers, REV, BYSCORE and BYLEX more than once, WITHSCORES with BYLEX, LIMIT
without BYSCORE or BYLEX, but not with a count of -1); the range's bounds before the key
is looked up, as zslParseRange and zslParseLexRange read them. ZUNION, ZINTER and ZDIFF
look up every key and check its type before reading WEIGHTS and AGGREGATE (so a key of
another type answers WRONGTYPE before an option's error), take a set as a sorted set with
scores 1, and walk the sources in Redis's order, sorted by size (with a stable sort,
which decides the sum of three scores like 1e16, 1 and -1e16): a weight times a score
that gives NaN (0 times infinity) counts as 0, as does a SUM of +inf and -inf. ZMPOP is
read as LMPOP is, and gives each element as a pair.

**The append-only file.** A write to a sorted set is written to the append-only file as
the command the client sent: ZADD with its options in one order (ZINCRBY as ZADD INCR),
ZREM, ZREMRANGEBY with the range as it came (the write reads it again when it runs, so
the file has what the client sent), ZPOPMIN or ZPOPMAX with the count (ZMPOP as such a
command for the key it took from); the removal of a key's last elements as its DEL. STORE
and ZRANGESTORE are written as the elements made, each score as Redis writes a double
(`%.17g`, which reads back into the same double): a ZADD of these pairs if the trie had
no entry for the destination, otherwise one record, an EVAL of a fourth fixed script that
deletes the destination and runs ZADD with the pairs, a thousand words of pairs per call,
each call with the options before it (a ZADD of part of the pairs does to each the same
as a ZADD of all), or a DEL of the destination if there are no pairs; the same script
writes a ZADD that makes a sorted set where a key with an expired time still lay. BendKV
parses the script back as the update ZWNew, with the number of options it writes after
the key, and rejects it with XX, which adds nothing to an empty set.

**A command again travels in registers as wide as its widest form.** The first version
of sorted sets raised the number of instructions on every request: GET +6.9%, SET +6.0%,
INCR +5.3% against the version with floats (3,529, 4,547 and 4,708 against 3,300, 4,290
and 4,472), the same trap the lists fell into (section 33). The parsed read of ZRANGE (a
range with bounds: two doubles and their flags, LIMIT's long integers and two flags) took
13 words and inside `Peek` made `Cmd` 17 words wide; ZUNION's options in ZStore took 5.
Now a read from the last element holds the read it reverses (`ZQRev`), and options with
WITHSCORES hold the options themselves (`ZAggScores`): a type that holds itself is a
separate node, one word, like an update (UGet). ZCOUNT and ZLEXCOUNT keep their bounds
as they came, like LRANGE, and ZRANK and ZREVRANK are two forms with one field. `Cmd` is
5 words wide again, and the cost went back to what it was (below); the proofs, which see
a range read only as a value, did not change.

**One change the proofs required.** A removal of a range and a POP on a missing key
answered after walking the empty set; the proof that they change nothing would then have
needed to know what a range of an empty tree contains, for every range. Now they answer
at once with the empty set's reply (the number 0, an empty array or the range's error),
the same bytes.

**The proofs.** Of the 1,331 definitions of the proof, the specification and the laws,
68 changed and 136 were added; the laws did not change. The commands of one sorted set
are reads (`ZOp`, through `Peek`) and updates (`Upd`) of their key, and the STORE forms,
ZRANGESTORE and ZMPOP are separate commands of the specification (`zstore`,
`zrangestore`, `zmpop`) whose writes depend on other keys (section 26), with their own
lemmas of frame, of the key's entry after them, of replies, of the bridge to the server's
records, and of time. `Good` for the two changes of a sorted set: a changed set, whose
write, replayed on the key's set, makes the same change and parses back from the file (a
ZADD whose options and pairs pass ZADD's checks, a ZREM of members, a range that reads, a
count that reads); a new set, a ZADD with options that pass the checks and contain no
XX: a lemma shows that ZADD with XX adds nothing to an empty set, so a new set never has
XX. ZADD's options parse back by a case for each of their 64 sets (written out by a
script and checked as written): each set, written in the file's order, is read back by
ZADD's loop of options, which stops at the first score, because the checks require that
it not be an option word.

**Cost.** Instructions per request (`make perfcheck`): GET 3,297, SET 4,290, INCR 4,476,
as before sorted sets (3,300, 4,290 and 4,472). Against Redis 7.0.15 (redis-benchmark,
pipeline 16, 20 clients) a read of one member is as fast: ZSCORE on a set of 100,000
members, 633,000 requests per second against 630,000 (on a set of 10, 904,000 against
950,000), ZCARD 1.40 million against 1.34 million. What descends the tree is slower: ZRANK
180,000 against 513,000, ZRANGE of 10 elements with scores 104,000 against 318,000,
ZRANGEBYSCORE with LIMIT 10 64,000 against 597,000, ZCOUNT 142,000 against 989,000,
ZRANDMEMBER 229,000 against 753,000; and a write to a large set is slower still: ZINCRBY
41,000 against 329,000, ZADD of random members up to 100,000, 38,000 against 272,000,
ZPOPMIN 70,000 against 694,000. A small set is closer (ZADD XX of a member 588,000
against 903,000, ZRANGE of all its 10 elements with scores 218,000 against 302,000,
ZRANDMEMBER 825,000 against 1.27 million, ZINTER of two of 10, 91,000 against 257,000),
except the STORE forms: ZUNIONSTORE of two of 10, 19,000 against 169,000, ZRANGESTORE of
10 elements 44,000 against 286,000. Where the time went (callgrind; these rates are from
before the change of section 38): ZINCRBY of a member of a set of 100,000 cost 147,000
instructions, and three fifths of them were copies of tree nodes that the reads owned
(of the 361 size reads per write, which every rebalancing asks for, 126 copied a node
that the tree shares with the previous version), and ZUNIONSTORE of two of 10 cost
583,000, mostly the same copies, the rest scores written as text and read back (STORE
builds the set with the ZADD that the append-only file would write). Why the reads owned
the nodes and how they stopped is section 38 (after it, 77,600 and 401,400
instructions). BendKV compared members character by character in Bend, where Redis's
memcmp compares words; section 39 makes `String.order` native (ZINCRBY 61,200
instructions).

**Where BendKV differs.** A STORE (or ZRANGESTORE) of more than 128 elements: Redis makes
a skiplist of them, and a score of `-0` stays `-0`, while BendKV builds them as a ZADD
from the append-only file would, and the elements of the first 128 lose the sign (ZSCORE
answers `0`), as they would with Redis's own ZADD too; a range by member over elements of
different scores in a large set (see above); the ZRANDMEMBER picks themselves; MEMORY
USAGE is an estimate; zset-max-listpack-entries and -value, which only OBJECT ENCODING
reads.

**Redis's test suite and the tests.** BendKV passes 733 of the 1,673 tests that Redis
passes (43.8%; it was 552), and 726 of 1,089 in the units of what it has. Sorted sets
brought 181: 170 more in `unit/type/zset`, 180 of 289 (after that the unit runs the
tests of the blocking commands over RESP3 first and stops at HELLO 3 without reaching 82
tests; without the RESP3 tests the unit runs to its end, and BendKV passes 238 of the 285
that Redis passes, and each of the other 47 needs the blocking commands, RESP3 within the
test, MULTI or replication), four ZSCAN tests in `unit/scan`, COPY of a sorted set in
both encodings in `unit/keyspace`, COMMAND GETKEYS for ZUNIONSTORE with more than 256
keys and the movablekeys mark of ZUNIONSTORE in `unit/introspection-2`, and three tests
of other units that make a sorted set along the way. Tests: `tests/zset_test.py` in
`make test` (a script of commands at the edges, sorted sets of up to 20,000 elements with
integer and fractional scores on both sides of 128 elements, a listpack grown past 128 one
element at a time, members of 64 and 65 bytes, keys with an expired time as sources,
destinations and operands, then 3,000 random commands on several keys; each reply is
checked against Redis, the whole ZSCAN walk by the pairs it gives, each ZRANDMEMBER pick
against the set it was taken from), sorted sets in the differential test, in the numbers
test, in both append-only files (the fourth script among them) and in restarts, in
`tests/aof_check.bend`, and also COMMAND GETKEYS for the STORE forms, ZRANGESTORE and
ZMPOP in the COMMAND test.

## 38. A read that owns what it reads

**What callgrind showed.** ZINCRBY of a member of a sorted set of 100,000 cost 147,000
instructions, and three fifths of them were copies of tree nodes and their drops
(`ctr_own_slow`, `term_drop`). The compiler decides once for each function whether it
borrows a parameter or owns it. A parameter is borrowed as long as no caller passes into
it a value the caller does not itself keep: a value computed for the call
(`zt.size(zset.tree(z))`), or the last use of its own value in a tail call; and as long
as the function itself does not read a field of the node after a call it makes, since
the compiler can keep a node across a call only by owning it. One such call anywhere is
enough for the parameter to become owned for all calls, and owning a shared node (and
all nodes of a set held by the keyspace are shared) means a copy before the read and its
drop after. `zt.size`, which every rebalancing asks for both sides, owned its node
because `zset.len` passed it a computed tree: 126 copies per ZINCRBY. The range tests
(`ZP`) were nodes (one test could hold another, ZNot) and were built on every call:
`zp.ok` owned them, and with it the descents through the tree that pass them.

**The change.** The reads of a sorted set take the tree as a field of the set itself
(`zset.len`, `zset.slice`, `zset.all`, `zset.rank`) and borrow it; a range test is a few
words (ZGtS and ZGtL instead of ZNot); a walk builds the element it keeps before the
recursive call; and a tree built for one use (STORE's) is taken apart by `zt.drain`,
which owns it. Instructions per request (callgrind): ZINCRBY of a member of a set of
100,000, 77,600 (it was 147,100), ZRANGE of 10 elements of 100,000 with scores 56,700
(89,200), ZRANK 15,900 (27,800), ZUNIONSTORE of two of 10, 401,400 (583,500); GET, SET
and INCR 3,298, 4,290 and 4,479, as before. The proofs did not change: they see these
reads only as values.

**What is left.** A walk that reads a field after a recursive call still owns the nodes
it visits and copies them: the in-order walks of a sorted set (`zt.slice.go`,
`zt.find.go`) and of the keyspace's trie (`tkeys` and `tscan`, under KEYS and SCAN, and
also under the reads of large hashes and sets): the sorted set reaches them through tail
calls from a value the command owns, and a value passed in a tail call for the last time
makes the callee own it. The remedy is in the compiler, and it is not a global rule: the
first attempt, counting as lent to the callee a value the caller keeps after the call,
made GET, SET and INCR 37%, 30% and 27% more expensive in instructions, so the rule stays
as it was, and the reads of sorted sets stay as this change leaves them until a narrower
one is found. A native `String.order` came first (section 39). The rest of the cost of a
write to a sorted set is mostly its path, copied because the keyspace still holds the old
path, and the drop of the old path: an update in place (take the value out, change it,
put it back) would save both. (The narrower rule is the thirty-first patch, section 51.)

## 39. Members are compared a chunk at a time

**What callgrind showed.** After section 38, ZRANK of a member of a set of 100,000 with
their own scores cost 15,900 instructions, and half of them went to one comparison: of
the member with the element at which the descent stops, which has the same score.
`String.order` is `String.cmp` from Base: at each step it takes a character from each
string and hands both strings back, and on a packed string each step makes a view of the
rest and drops it (`str_take_slow`, `str_cons_new`, `term_drop`), so two equal members
of 14 bytes cost about 8,000 instructions. Where the scores are equal (for example, a set
with score 0 that is read by member: ZRANGEBYLEX and its kin, a common case), every node
of the descent compares members: ZRANK of one of 100,000 cost 76,900.

**The change.** The twenty-second patch makes `String.order` native on the C lane, as
the fourth made `String.eq`. Two strings of one chunk each (a member kept in the tree and
a member where the request holds it) are one `memcmp` of the common length and then a
comparison of the lengths; the others are walked chunk by chunk (`memcmp` of bytes, a
cell's character by its code). A byte is a character below 256, and `memcmp` reads bytes
unsigned, so the order is the same as the definition's: by codes, a prefix first.
`String.is_lt` and its kin go through it. BendKV's code does not change, and the proofs
see `String.order` as Base defines it.

**The numbers.** Instructions per request (callgrind, pipelines of 16):

| command | before | after |
|---|---:|---:|
| ZRANK of 100,000 with score 0 | 76,861 | 9,028 |
| ZRANGEBYLEX of 100,000 with score 0, LIMIT 10 | 129,345 | 55,144 |
| ZLEXCOUNT of 100,000 with score 0 | 160,302 | 21,435 |
| ZINCRBY of 100,000 with score 0 | 186,381 | 61,449 |
| ZRANK of 100,000 with their own scores | 15,877 | 7,515 |
| ZINCRBY of 100,000 with their own scores | 77,674 | 61,168 |
| ZRANGE of 10 elements with scores | 56,715 | 56,708 |

A ZADD of a member with the score it already has does not descend the tree (12,368 and
12,361), and a range by rank compares no members. GET, SET and INCR 3,301, 4,306 and
4,491 (before, 3,301, 4,295 and 4,479, within ±15 between runs). The patch adds 617
tokens to `comp.ts`; with it the C and JS lanes of Bend's tests pass what they passed
before, plus the new `string_order` on both.

**What is left.** The 55,000 instructions of ZRANGEBYLEX are now mostly the walk that
owns the nodes it visits (section 38): `term_drop`, `span_fade`, `ctr_take` and
`ctr_own_slow` take two fifths of its instructions, `str_order` 3%.

## 40. A client that stopped reading

A review of the first commit (issue #3) traced how one client could stop the server when
replies are posted (`TCP.post`, the default with two cores or more), and it was so with
twenty-two patches too. The writer sent a post to the end: on `EAGAIN` it waited for the
same socket with `poll` for 100 ms at a time and tried again, without limit, and took the
next post from the ring only after sending this one. A client that stopped reading held
the writer, and all the replies and closes behind its own waited. The loop sends a post
itself only if the writer has already sent everything posted earlier to this socket (p15
and p17), so the clients that kept up got what the loop sent them itself, until one of
them needed the writer: a reply larger than the room in its socket, or the loop
switching to posts under load. And when the ring's 4,096 slots ran out, the loop spun on
it: neither requests nor `accept` nor timers went. Both cases were reproduced: while one
client did not read 32 MiB of replies, an 8 MiB reply to another stopped at the 5.1 MiB
that the loop sent itself; after 4,600 more requests from the stuck client, one per
batch, another client's PING and a new connection got no reply.

Redis keeps each client's output in its own buffer (ordinary clients have no limit by
default, `client-output-buffer-limit normal 0 0 0`), and one client's tail does not hold
up another. The twenty-third patch does the same in the writer, which no longer waits for
a socket. What a socket did not accept, and everything posted to it after, the writer
holds in order and moves on to the posts of other sockets, and it sends what it holds
when the socket has room. Its own `epoll` tells it so (on other systems `poll`): while
the writer has posts, it looks there once per window (200 µs), and while it holds
something, it sleeps there rather than on a condition variable, and the loop wakes it
with a byte in a pipe. A close posted behind held bytes closes the socket once the held
bytes are gone. The loop sends a post itself only if the writer also holds nothing for
this socket (`held[fd]`), so a socket's bytes go in order. And the ring became a chain
of blocks of 4,096 posts: having filled a block, the loop hangs on the next one (the one
the writer emptied last, or a new one), and a post never waits for room. A client that
stopped reading grows only its own tail, as in Redis; we introduced no limit.

`tests/writer_test.py` runs in `make test` against each mode of the server. A client asks
for 32 MiB of replies and does not read them; another then gets an 8 MiB reply (in 22–26
ms) and a PONG (in under a millisecond); the stuck client sends 4,600 more requests, one
per batch, more than the old ring held; a new connection is served and closed by QUIT;
the sweep from cron deletes a key with a passed time that nobody reads; a client that
asked for 4 MiB and QUIT and reads late gets the whole reply and then the close; finally
the stuck client reads its tail, sending 2,000 ECHOs along the way, and gets all the
bytes in order, the ECHO replies after the rest. A build without the patch fails on the
8 MiB reply; a build in which the loop sends a post itself without asking `held[fd]`
fails too: the ECHO replies come out of order, or the close after QUIT cuts the reply. In
the compiler, `tests/io/tcp_post_stall.bend` posts 8 MB and 5,000 short posts to a socket
whose reader stays silent for now, and 8 MB to another: the timer fires, the second
reader gets its bytes and the end, then the first gets its own, in order, and the end.
Without the patch the test hangs: its loop spins on the full ring, and with 100 short
posts instead of 5,000 the timer fires, but the second socket's bytes wait behind the
first; the test also fails with a writer that closes a socket at once although it holds
bytes for it.

The cost is 2,649 tokens of `comp.ts` (section 12). On the post path the loop also reads
`held[fd]` before its own send, and per post a pointer to its block, and no longer reads
the writer's head a second time when checking for room; the writer checks the count of
held sockets per post, and at the end of a block moves to the next. Under callgrind, when
replies are posted, a request costs as much as it did, within the spread between runs:
with pipeline 16 GET, SET and INCR take 3,434, 4,375 and 4,519 instructions against
3,390, 4,377 and 4,578 without the patch; without a pipeline 10,849–10,992, 12,355–12,812
and 12,350–13,113 against 10,976–11,592, 12,364–12,389 and 12,640–12,756 (how many
requests one wake-up finds moves a run by up to 6%). Throughput in pairs
(`tools/bench_pairs.sh`: three rounds, 100,000 keys, 20 clients) of the build with the
review branches merged (this patch, the next one and the protocol fixes) against the
build before them moved within the spread between rounds: with posts on two cores GET,
SET and INCR at 1.036, 1.023 and 0.928 of it with pipeline 16 and 1.113, 0.967 and 0.979
without a pipeline; with sending from the loop on one core, 0.972, 1.015 and 0.945, and
1.037, 0.973 and 1.035.

## 41. Clients that wait

**What there is.** BLPOP, BRPOP, BLMOVE, BRPOPLPUSH, BLMPOP, BZPOPMIN, BZPOPMAX and
BZMPOP, the blocking commands of Redis 7.0.15's lists and sorted sets, and CLIENT UNBLOCK
with TIMEOUT and ERROR (XREAD and WAIT wait for what BendKV does not have). A blocking
command is the removal it makes when a key it waits for holds what it removes: LMPOP of
its keys (BLPOP and BRPOP remove one element and answer with the key and the element),
LMOVE of its source (BRPOPLPUSH, BLMOVE) or ZMPOP (BZPOPMIN and BZPOPMAX answer with the
key, the member and the score). The timeout is read as Redis 7.0.15 reads it: a long
double of seconds, with Redis's errors and its oddities (`inf` and `1e400` are "timeout
is negative", which is what they become after Redis's cast to a long long); 0 means wait
forever, and a time that cannot be added to the clock waits the same way (in Redis the
sum overflows). A command that found something to remove answers at once; one that did
not makes the client wait. As in Redis: the call is counted when the client starts
waiting; a client whose time is up gets a null array (`*-1`) and counts nothing more;
CLIENT UNBLOCK reads the reason before the id, ends the wait with a null array (TIMEOUT)
or with the error `-UNBLOCKED client unblocked via CLIENT UNBLOCK` (ERROR), and in both
cases counts the waiting command's call as failed, with ERROR with its error, and its
own call as failed too (Redis counts an error that comes while a command runs against
that command: `incrCommandStatsOnError`); the commands the client sent after the
blocking one wait with it, since Redis does not read a blocked client's input; a client
that closed the connection while waiting is forgotten; INFO counts `blocked_clients` and
`clients_in_timeout_table`. A blocking command with replies off (CLIENT REPLY OFF or
SKIP) waits and removes the same way, and its reply is dropped.

**In the actor.** The waiting clients are one chain in the order they came (`Waits`):
each has its connection before and after the blocking command, its removal, its
database, its deadline and the rest of its batch. While at least one waits, every batch
goes by the general path, a command at a time (`bg.go`; every batch that cannot go by the
fast path now goes by it too: one with a command of the connection or the server, or
from a client without authentication or with replies off). After each command the actor
looks in the chain for the first client one of whose keys, in its own database, holds
what it waits for, makes its removal there, takes it out and looks again until no one is
ready. A served client goes on with the rest of its batch at the end of the group, after
its reply; a batch that waits again joins the end of the chain. At the end of each group
the clients whose time is up get null arrays; a cron tick (`hz`, 10 per second by
default) makes a group itself, so a timeout fires within a tick, as in Redis, which looks
at its timeouts before sleeping, at least once per tick of its cron. The removal for a
served client is written to the append-only file as the command that makes it: LPOP or
RPOP with a count, LMOVE, ZPOPMIN or ZPOPMAX (Redis writes the same). For the session and
for the proofs, a blocking command is its removal run once: a key holding what it
removes answers as the blocking command answers, and an empty one as Redis answers a
client that may not wait, inside MULTI (a null array, or null for BRPOPLPUSH and
BLMOVE); the actor, serving a client, makes the same removal, so what a served client
does to the databases is what the proved commands do. The waiting itself (who is served
and when) is outside the proofs; CLIENT UNBLOCK in them is a session command that changes
nothing (it answers 0), as for a session where no one waits.

**In the connection.** The answer to a batch whose client waits is `Hold` with the
replies before the blocking command. The connection sends them, sets a watch on its
socket (`TCP.watch`, the twenty-fifth patch), which puts `Ready` into its own channel when
bytes come or the client closes the connection, and waits on the channel: for the
actor's answer (the watch is taken back, a `Ready` it put is thrown away, the replies are
sent, and the bytes that came meanwhile are read on, as after any batch) or for `Ready`
(the bytes are put aside until the end of the batch; a close tells the actor that the
client is gone, and the connection ends when the actor answers that it holds nothing more
for it).

**A type travels as wide as its widest form, a third time.** The first version passed
the batch's state on the general path (replies, effects, connection, server, databases,
the chain and the served clients) as a flat record: the widest result in the program grew
from 17 words to 30, and the set of registers shared by all segments from 28 to 48, and
every request paid, though no one waited: GET 3,327 instructions, SET 4,252, INCR 4,512
against 3,256, 4,180 and 4,431 before (+2.2%, +1.7%, +1.8%; the same trap is in sections
16 and 37). Now this state is a separate node (a type with a variant that holds itself),
the chain of clients is one word (a type that holds itself), and the functions of the
general path pass less: the set of registers is 26, the widest result 17, and a request
costs GET 3,272, SET 4,194 and INCR 4,454 (+0.5%, +0.3%, +0.5%).

**Two bugs below BendKV.** Redis's suite stopped in `unit/introspection`: the server
crashed. A client with replies off sent a database command (CLIENT REPLY OFF, then PING),
and at the next tick the server read the command counters from freed memory (`SIGSEGV`).
The in-place node update (the fifth patch) kept the node of the batch's state across the
call to `S.run_log`, and after the call re-read from it the fields it had not saved. The
server's state was used twice, by the run and by the connection's next state after it,
so `term_keep` shared its words before the call, wrapping each raw word in a count of 2,
while the node kept the raw words. After the call the re-read raw word went to the second
use, which dropped it and freed the counters, while the run's answer held the wrapper.
The twenty-sixth patch writes the shared field back into the node where it is kept (one
store); in BendKV it added 27 stores, all in the functions of the general path; no other
function had this, and the instructions per request did not move. The second: under the
load of a build, a served client (by a push or a MOVE), whose removal was already made,
sometimes never got its reply. Its connection woke on `Ready` from a watch that fired for
nothing, read the socket, where there was nothing, and waited there for bytes, while the
actor's answer lay in the channel. The runtime keeps for each socket a flag of an edge
that came when no one waited on the socket, and a watch set with the flag raised fires at
the next poll; but an edge that the loop saw when a read had already taken its bytes
raises the flag over an empty socket (or wakes a watch set since then). A build that logs
such a firing recorded 4 per 3,200 wake-ups on an idle machine; the one whose path it
traced came from the flag. The twenty-fifth patch now first peeks into the socket
(`recv` with `MSG_PEEK`) and, if there is nothing to read, waits for the next edge.
Before that, 8 wake-ups of 1,200 after a MOVE were lost under load, and the test below
failed in 13 runs of 30; after, not one of 10,500, and all 60 runs passed.

**Tests.** `tests/blocking_test.py` runs in `make test` against each mode of the server:
18 scenarios on BendKV and on Redis, each with its own clients, whose transcripts are
compared line by line (61 lines: pushes that serve, timeouts, CLIENT UNBLOCK with its
errors, a client that closes the connection while waiting, fairness to a pipeline that
first pushes and then waits itself, BLMOVE chains and a BRPOPLPUSH circle, a move onto a
key of the wrong type, commands and bytes behind a blocking one, sorted sets, a list that
does not serve a client waiting for a sorted set, INFO statistics, a timeout with a
pipeline behind it, RENAME, MOVE and SWAPDB that make a key, CLIENT REPLY OFF, a served
client that waits again, SELECT and QUIT in the batch of a blocking command); then BendKV
under load: 300 clients served on 300 keys, 100 timeouts at once, 100 clients that leave
while waiting (no one is left waiting, the elements pushed after them are kept), and 50
consumers moving 1,000 elements with BRPOPLPUSH while some of them leave; each element is
moved once. Redis's suite: 746 of the 1,673 tests that Redis passes (44.6%; it was 733),
`unit/type/zset` 192 of 289 (it was 180), `unit/introspection-2` 28 of 43;
`unit/type/list` still stops at its HELLO 3 after 15. Without the tests of RESP3, MULTI,
DEBUG, SORT and replication, `unit/type/list` passes all 140 tests that Redis passes, and
`unit/type/zset` 260 of 276 (the other 16 need RESP3 within the test).

**Where BendKV differs.** Redis serves the clients of the keys a command added
(`signalKeyAsReady` from `dbAdd`, and SWAPDB's walk), key by key in the order of
readiness; BendKV looks at all waiting clients after each command, in the order they
came, so when one command makes several keys ready (SWAPDB), the clients of different
keys may be served in another order. Inside a transaction a blocking command answers at
once, as in Redis (section 42).

## 42. Transactions

**What there is.** MULTI, EXEC, DISCARD, WATCH and UNWATCH, as Redis 7.0.15 runs them
(`multi.c`). After MULTI a command is queued with the reply `+QUEUED`, except EXEC,
DISCARD, MULTI (`ERR MULTI calls can not be nested`), WATCH
(`ERR WATCH inside MULTI is not allowed`), QUIT and RESET, which run. A command refused
when queued (an unknown command, a wrong number of arguments, NOAUTH) answers with its
error and flags the transaction, and then EXEC answers
`-EXECABORT Transaction discarded because of previous errors.`; a refused EXEC itself
(its arguments, NOAUTH) aborts the transaction, in MULTI and outside it, with its own
reason
(`-EXECABORT Transaction discarded because of: wrong number of arguments for 'exec' command`),
as Redis's `rejectCommand` does. EXEC and DISCARD without MULTI are errors. EXEC runs the
queue as one whole: the commands' replies are its array, an error while running
(WRONGTYPE) one of them; waiting clients are not served between the commands, a blocking
command in the queue answers as a client that may not wait is answered (a null array),
and the waiting clients are served when EXEC is done. A watched key makes EXEC's reply a
null array (`*-1`) and the transaction discarded if some command changed it after WATCH
or if by EXEC it lies with its time passed (`isWatchedKeyExpired`). A change is what
Redis's `touchWatchedKey` counts: a write that changes the key, a DEL of a key that is
there (but not of one that is not, not an SADD of a member that is already there, and not
an SMOVE's destination that already held the member), FLUSHDB and FLUSHALL of a database
where the key is, SWAPDB of two databases where it is in at least one
(`touchAllWatchedKeysInDb`; a SWAPDB of a database with itself is not), MOVE (the key in
both databases), COPY (the destination), RENAME (both keys) and the sweep of expired
keys; a key taken under watch when its entry lay with its time passed (Redis 7.0's
`expired` flag) is not changed by the deletion of that entry, only by a write that sets it
again. EXEC, DISCARD, UNWATCH, RESET and a closed connection remove the watch. Calls are
counted as Redis counts them: a queued command when EXEC runs it, one refused when queued
as rejected, EXEC itself once, and as failed only if its own reply is an error. CLIENT
REPLY OFF and SKIP hold back a transaction's replies as Redis does, QUEUED and EXEC's
array too.

**In the actor.** The session answers these five commands as a client without a
transaction is answered (MULTI and WATCH `+OK`, EXEC and DISCARD their errors), so the
connection's state and its proofs did not change; the clients' transactions are held by
the actor, a chain of the clients that have a transaction or watched keys (`Tx`: in MULTI
or not, flagged or not, touched or not, the queue of commands and the watched keys, each
with its database and Redis's `expired` flag), which acts when commands run (`bg.cmd`).
While the chain is empty it costs nothing; while it is not, every batch goes by the
general path, a command at a time, so that after each command its effects (the commands
the append-only file writes for it) touch the keys they name: whether a key is there
before and after tells a change from none, and FLUSHDB, FLUSHALL and SWAPDB touch keys by
their own rules from Redis. EXEC also runs the queue by the general path, serving no one
between the commands, and its effects, if there are two or more, are one record of the
file between MULTI and EXEC, as Redis writes them (Redis 7.0 does not wrap a transaction
that propagates one command). A client that closed the connection tells the actor
(`Left`), and the actor forgets its transaction.

**In the file and in the laws.** A file cut off by a crash inside a transaction ends with
its MULTI and part of its effects. Redis reverts such a transaction ("Revert incomplete
MULTI/EXEC transaction in AOF file") and cuts the file back to its MULTI; BendKV does the
same (`A.untx`: reading from the end, the last mark decides; a MULTI before any EXEC cuts
there), and with `aof-load-truncated no` both stop the start ("Unexpected end of file
reading the append only file"), as with a cut record. The laws of the append-only file
now see a history whose batches are commands or the commands of a transaction (`RunTx`),
and a file whose records (`A.Ent`) are an effect or the effects of a transaction between
MULTI and EXEC. The statement of `recover` is unchanged: after any history the file
restores exactly the databases the server held. `recover_cut` now says that a file cut
anywhere restores the databases after some prefix of the history's steps, where a step is
an act or the acts of a transaction together: no act of a transaction is applied without
the rest. The proofs: on replay MULTI and EXEC are connection commands, errors that
change nothing, so a record replays as the effects it holds (`rpe_file`); no line an
effect writes is a mark (`mark_args`, a parse of the lines each logged command writes:
each is two words or more, or one word that is neither MULTI nor EXEC), so a whole file,
read from the end, meets each transaction's EXEC before its MULTI, and the start reverts
nothing (`untx_all`), while a file cut inside a transaction ends with its MULTI and lines
without marks, which the start reverts (`untx_open`); the first k lines of a file are the
history's first records whole and part of the next one: a SELECT that changes no
database, or the start of a transaction, which is reverted (`tk`); and these records
replay as the history's first steps (`sepe`: a step has at most one record). The proofs
of the append-only file grew from 930 lines to 1,670.

**Cost.** While no client has a transaction or watched keys, a request pays one check
more on the fast path (the chain is empty): GET 3,279 instructions, SET 4,200, INCR
4,463, against 3,272, 4,194 and 4,454 before (+0.2% at most, `make perfcheck`).

**Tests.** `tests/multi_test.py` runs in `make test` against each mode of the server: 12
scenarios on BendKV and on Redis, each with its own clients, whose transcripts are
compared line by line (57 lines: replies of all kinds and a SELECT inside, DISCARD, a
nested MULTI, WATCH inside MULTI, commands refused when queued and errors while running,
EXEC and DISCARD without MULTI, EXEC refused in MULTI and outside it, QUIT and RESET
inside a transaction, keys changed by another client or not, a DEL of a key that is not
there, an SADD of a member that is there, an SMOVE of a member already in the
destination, FLUSHALL, FLUSHDB and SWAPDB of keys that are there and that are not, MOVE,
COPY, RENAME, EXPIRE, a key of another database, keys expired by the sweep or found
expired by EXEC, UNWATCH, DISCARD and EXEC forgetting a change, a blocking command inside
EXEC and waiting clients served after it, CLIENT REPLY OFF and SKIP around a
transaction, INFO statistics as `info.tcl` reads them); then BendKV under load: 20
clients add 1,000 to a counter through WATCH, GET, MULTI, SET and EXEC (each lost race
is retried; the counter ends at 1,000), a reader never sees half a transaction (an MGET
of two keys that 500 transactions increment together), and 100 clients close their
connections in the middle of MULTI or with watched keys, after which writes and
transactions go as before. The differential test now and then sends whole transactions,
and also MULTI, EXEC, DISCARD, WATCH and UNWATCH alone and with wrong arguments; the
tests of the append-only file revert an unclosed transaction (also with a cut record
after it) and refuse it with `aof-load-truncated no`; BendKV restores a file that Redis
wrote with transactions, and Redis a file of BendKV's. Redis's suite: 759 of the 1,673
tests that Redis passes (45.4%; it was 746). `unit/multi` passes 25 of its 53 (the
others read the replication stream, require Lua, SORT, XGROUP or OOM from maxmemory, or
come after an OOM test that left its client in MULTI), `unit/other` the RESET test about
the MULTI state, `unit/protocol` the regression test of argument rewriting (issue 9598),
`unit/type/set` the test of SMOVE onto a set that already has the member and is watched
(it found the only difference the tests above had missed: the actor touched SMOVE's
destination); 14 tests that passed now fail: their client was left in MULTI by a test
that failed inside a transaction on a command BendKV does not have (GEOADD in
`unit/introspection-2`, after which 12 COMMAND tests get QUEUED; SORT; XADD), as it
would be on a Redis without these commands.

**Where BendKV differs.** An LTRIM that removed nothing does not change a watched key,
while Redis signals it anyway. BendKV writes every DEL to the append-only file, whether
the keys are there or not, and Redis only a DEL that deleted something, so a transaction
with such a DEL and one more effect is written between MULTI and EXEC where Redis writes
the other effect by itself (the file means the same).

## 43. Pub/Sub and keyspace notifications

**What there is.** SUBSCRIBE, UNSUBSCRIBE, PSUBSCRIBE, PUNSUBSCRIBE, SSUBSCRIBE,
SUNSUBSCRIBE, PUBLISH, SPUBLISH and PUBSUB (CHANNELS, NUMSUB, NUMPAT, SHARDCHANNELS,
SHARDNUMSUB, HELP), as Redis 7.0.15 runs them (`pubsub.c`). SUBSCRIBE and its kin answer
with a reply for each name, with the count of the client's channels and patterns (of its
shard channels for SSUBSCRIBE and SUNSUBSCRIBE); a name subscribed to twice counts once;
UNSUBSCRIBE without names unsubscribes from all, and if there are no subscriptions
answers with one reply with an empty name. A message goes to the subscribers of its
channel (`message`, for a shard channel `smessage`), then to the subscribers of each
matching pattern (`pmessage`, glob as in Redis), and PUBLISH answers how many clients got
it. A client with a subscription runs only (P|S)SUBSCRIBE, (P|S)UNSUBSCRIBE, PING (the
reply `[pong, its argument]`), QUIT and RESET, as a RESP2 client in Redis: any other
command is refused once the checks of its name and number of arguments pass (an unknown
command or GET without a key answer with their own error), with Redis's error
`Can't execute 'get': only (P|S)SUBSCRIBE / (P|S)UNSUBSCRIBE / PING / QUIT / RESET are allowed in this context`,
and is counted as rejected; an EXEC refused this way answers EXECABORT with that reason.
The replies of SUBSCRIBE and its kin go out even to a client whose replies are held back
(CLIENT REPLY OFF or SKIP), since Redis pushes them through. In a transaction SUBSCRIBE
and PSUBSCRIBE run, and after EXEC the client has a subscription, while SSUBSCRIBE is
refused (`SSUBSCRIBE isn't allowed for a DENY BLOCKING client`), as in Redis. RESET, QUIT
and a closed connection remove the client's subscriptions.

**Keyspace notifications.** When `notify-keyspace-events` is set (K, E, g, $, l, s, h, z,
x, n and A are read and shown as in Redis: A stands for the classes it covers, n next to
A is kept but not shown), each change a command makes is published as Redis's
`notifyKeyspaceEvent` publishes it: the event's name to `__keyspace@<db>__:<key>` (K),
the key to `__keyevent@<db>__:<name>` (E). Each command has Redis's events: `set`,
`expire` (after `set` for SET with a time), `del`, `persist`, `incrby`, `incrbyfloat`,
`append`, `setrange`, `setbit`, `rename_from` and `rename_to`, `move_from` and
`move_to`, `copy_to`, `lpush`, `rpush`, `lpop`, `rpop`, `linsert`, `lset`, `lrem`,
`ltrim` (also when LTRIM cut nothing), `sadd`, `srem`, `spop`, `sinterstore` and its
kin, `hset`, `hdel`, `hincrby`, `hincrbyfloat`, `zadd`, `zincr`, `zrem`,
`zremrangebyscore` and its kin, `zpopmin`, `zpopmax`, `zunionstore` and its kin,
`zrangestore`; a key the command created is `new` (n) before them, a collection it
emptied is `del` after them, and the sweep of expired keys sends `expired` (x) for each
deleted key. A served waiting client (BLPOP and its kin) sends the events of its removal
after the events of the write, as in Redis.

**In the actor.** The session keeps no subscriptions and knows no other clients: it
answers each Pub/Sub command as Redis answers a client alone on the server (the replies
of SUBSCRIBE and its kin gathered into one array), so the connection's state and its
proofs did not change. The actor holds the subscriptions: the subscribers of each channel
and shard channel (trees by name, as for keys), the subscribers of each pattern, and each
client's channels, patterns and shard channels. A message to a client is a push (`Push`)
into the channel its replies come by, after the replies already there; the connection
writes it as soon as it has come. A client with a subscription waits on its socket and
its channel at once (a watch, `TCP.watch`, as a waiting client does, section 41), with
steps of the loop of its own, so the loop of all other clients stayed as it was; its
batches go to the actor as `SubReq` and run a command at a time. When there are keyspace
events to send, every batch goes a command at a time, and a command's events come from
the command itself, from whether it changed anything (its effects, the commands the
append-only file writes for it), and from what each key it wrote was before it and
became after (there, not there, or lying with its time passed).

**What a word costs.** The first version made GET 70 instructions more expensive (3,349,
+2.1%) for three reasons, which a profile of the generated code by segment showed (a
build with DWARF 4, which valgrind 3.22 reads, and callgrind's lines summed by the
segment they lie in). A command travels in as many registers as its widest form has, and
the widest session command had two fields: a PubOp of three fields inside a session
command made every request carry an extra word through the parser and the batch (11
instructions in the parser's loop alone); now SPub carries a number and the arguments
and is no wider than the rest. The Pub/Sub state lay flat, as eight words, in the state
of each batch, which every function of the fast path passes on; now it is one word, a
type that holds itself (`PsOf`, which is never built), like the waiting clients and the
transactions. And a flag in the connection's link, read after each reply, gave three
steps of the loop a second caller, and the compiler stopped inlining them into their
callers; a client with a subscription now has steps of its own. GET, SET and INCR take
3,288, 4,209 and 4,471 instructions (3,279, 4,200 and 4,463 before, +0.3% at most,
`make perfcheck`).

**Tests.** `tests/pubsub_test.py` runs in `make test` against each mode of the server:
scenarios on BendKV and on Redis, whose transcripts are compared line by line (191
lines: PING of a client with a subscription, one client and two, UNSUBSCRIBE of some and
of all, a channel subscribed to more than once, names without a subscription, patterns
with classes, escaping, `?`, `*` and the empty channel, NUMSUB, NUMPAT of shared
patterns, message before pmessage, the commands a subscribed client may not run, and
those whose checks come first, RESET and QUIT of a subscribed client and a client that
closed the connection, CLIENT REPLY OFF and SKIP, SUBSCRIBE in a transaction and
SSUBSCRIBE refused there, batches that subscribe and unsubscribe at once, PUBSUB's
subcommands and their errors, shard channels apart from the rest, a message of 100 KB and
50 in a row, INFO statistics; then the events of 138 commands, of all kinds under `KEA`
and under masks, `n`, `x` from the sweep, a key replaced after its time expired, a
served waiting client, a transaction and `notify-keyspace-events` off) and two checks
under load: 20 subscribers of a channel and a pattern each get the 2,000 messages of 4
publishers in each publisher's order, and PUBLISH counts 40 receivers each time; 50
subscribers close their connections while messages are being published, after which
PUBLISH counts none, and a new subscriber gets what is published. Redis's suite: 785 of
the 1,673 tests that Redis passes (46.9%; it was 759). `unit/pubsub` passes 25 of the 27
tests it reaches (all but the RESP3 test and the streams test), `unit/other` the RESET
test about the Pub/Sub state; the test of `evicted` events waits for an eviction that
never comes (there is no maxmemory), so the two tests after it do not run: CONFIG GET and
SET of the flags, which the CONFIG tests compare with Redis on random flags, and `new`
events, which the scenarios above check; the tests of unit/pubsubshard are cluster
tests, and against a server it did not start the suite skips them.

**Where BendKV differs.** UNSUBSCRIBE and PUNSUBSCRIBE of all go in the order of
subscribing, patterns are matched in the order they appeared, and PUBSUB CHANNELS lists
in the order of the tree, while Redis goes in the order of its hash tables (the tests
compare these sorted). There is no RESP3, so there is no push type either. A slow
subscriber's messages wait in its channel without the `client-output-buffer-limit pubsub`
limit. Events of misses (`m`), evictions (`e`) and streams are not sent; a key that a
read found with its time passed sends `expired` when the sweep deletes it, and Redis at
the read. A message a client publishes to a channel it subscribed to in the same
transaction goes out before EXEC's array, while Redis puts it inside the array's bytes,
after its count.

## 44. CLIENT LIST, INFO and KILL

**What there is.** CLIENT LIST (all clients, the clients of one TYPE: normal, master,
replica or slave, pubsub; or the clients with the IDs given, in their order), CLIENT
INFO, and CLIENT KILL in the old form (an address; the reply OK or `ERR No such client`)
and in the new one (the filters ID, TYPE, ADDR, LADDR, USER and SKIPME; the reply is how
many clients were killed), as Redis 7.0.15 runs them (`networking.c`), with its errors
(`ERR Invalid client ID`, `ERR Unknown
client type '...'`, `ERR client-id should be greater than 0`, `ERR No such user '...'`,
the syntax errors). A client's line has Redis's 27 fields in Redis's order: the id; the
address and the local address as Redis writes them (`ip:port`, `[ip]:port` for IPv6),
and the socket's fd; the name (CLIENT SETNAME, HELLO's SETNAME; RESET clears it); the age
and idle time in whole seconds, as Redis subtracts its unix times; the flags in Redis's
order (P has a subscription, x in MULTI, b waits in a blocking command, d a watched key
was touched, e CLIENT NO-EVICT is on, N none); the database (SELECT, RESET); the counts
of channels, patterns and shard channels; multi, -1 or the number of commands in the
queue; for the asking client, the bytes of the batch its command came in (qbuf) and of
the command's arguments (argv-mem), for a waiting one, of the blocking command's
arguments; and the full name of the last command (`client|list`, `get`, NULL before the
first; while the client waits, the blocking one, and once it is served, the last of the
rest of its batch). While EXEC runs a transaction, the client's own line shows it in
MULTI with commands in the queue, EXEC as the last command, and the bytes of EXEC's batch
and argument, as in Redis. A killed client is cut off at once, wherever it waited (in a
read, in a blocking command, with a subscription): its transaction, waiting and
subscriptions are removed, what it waited for stays as it was, and connected_clients no
longer counts it. The old form with the client's own address, and SKIPME no, kill the
client itself too, after its reply (in a transaction, after its end), as Redis closes a
client after its reply.

**In the actor.** The actor keeps a registry of its clients in the Pub/Sub state (one
word in the state of each batch, next to the subscriptions): each client's id, its reply
channel, the socket's fd and addresses, the connection time, the name, the database and
NO-EVICT, in a trie by id. A connection sends the actor its fd and addresses
(`TCP.name`, the twenty-seventh patch) as its first message (Join) and leaves with the
last one (Left); the name and the database are written after a batch that had SETNAME,
HELLO, SELECT or RESET, which go by the general path. What changes with every batch (the
client's last command and the batch's time) would cost a write to the registry per
batch; instead it is a mark on the client's reply channel (`Chan.mark`: a runtime table
by the channel's row and generation, which only the actor writes and reads), one call per
batch, and the fast path takes the last command's code from the batch's tally (`Tally`),
which it keeps anyway. CLIENT KILL takes the client out of the registry, the waiting
clients, the transactions and the subscriptions, and remembers its id and fd; at the end
of the group, before its replies go out (with the append-only file, after the group's
records are written), the actor's loop shuts each fd down both ways (`TCP.kill`), so the
connection's read or the watch on the socket sees the end at once. Until the killed
client's connection has said Left, the fast path is off (a bit of the Pub/Sub state
word, which also turns it off when there are keyspace events), and a batch of this client
is answered Bye without running, as Redis frees a client together with its query buffer.
The socket shut down is still this client's: a connection closes its socket only after
the actor's answer to its Left, and the actor takes the fd out of the registry in the
same group where it kills the client.

**What a word costs.** The first version made GET 51 instructions more expensive
(3,337): the batch's last command was found by a walk over its hashes, one per request,
with a reference count at each step (`slot_keep`, +16 per request, and the walk itself,
+18, by a profile of segments as in section 43); now the code is taken from the batch's
tally, where the runs of commands lie newest first. And a connection wrote its addresses
through `inet_ntop` and `snprintf`, about 3,500 instructions of printf per connection;
now an IPv4 address is written by hand. GET, SET and INCR take 3,303, 4,224 and 4,482
instructions (3,286, 4,211 and 4,475 for the code before, built by the same compiler and
counted in turn: +0.5% at most, `make perfcheck`). The rest is smeared over entries into
segments (`WL_FID_ENTER`, +4) and the code layout clang chooses.

**Tests.** `tests/client_test.py` runs in `make test` against each mode of the server:
scenarios on BendKV and on Redis, whose transcripts are compared line by line, and a
client's line field by field, leaving out what differs between the two servers by nature
(ids, addresses and fds are compared as the client they belong to, age and idle time by
whether they reached two seconds, the sizes of buffers BendKV does not have): 41 lines (a
client's own line, including by an inline command and in a pipeline; LIST by ids and
types and their errors; another client's name, database, last command (an unknown one,
one refused for its arguments, a subcommand, the last in a pipeline) and idle time; the
flags P with the count of subscriptions, x with commands in the queue and the client's
line while EXEC runs its transaction, b with the blocking command's arguments, including
with commands after it, d and e; KILL's errors; KILL by id, address, local address, type
and user, of itself, of a waiting client, of a client in MULTI, inside a transaction and
of all at once). And two checks under load: 100 clients at once, all listed and
answering, half of them killed by id, the rest answering and listed alone; 200 clients
killed by address while four threads of clients connect and leave: no one is killed but
those named, and connected_clients is back to one afterwards. A connection now waits for
the actor's answer to its Left before closing its socket, and is counted a little longer
while it ends: `tests/conn_test.py`, which counts connections after 50 that ended each
way, read the count, then once more, and a connection the server accepted late (after
the client had reset it) could fall between them; now it waits for ten ones in a row.
Redis's test suite: 794 of the 1,677 tests that Redis passes (47.3%; it was 785):
`unit/introspection` passes 23 of 28 (the other five are MONITOR tests): CLIENT LIST, by
ids, with names and without, CLIENT INFO, KILL's errors, KILL SKIPME yes and no of all
clients, and a client with a name from SETNAME that closes its connection and disappears
from the list. Two `unit/querybuf` tests now get past CLIENT LIST and reach the size of a
client's query buffer, which BendKV does not have. And the suite's runner now starts a
server instance for each unit: the test of `evicted` events from `unit/pubsub`, which
never happen, left `maxmemory 1` and `allkeys-lru` behind, and `unit/type/incr`, which
came after it on the same instance, saw INCR's shared integers with a count of 1 (OBJECT
REFCOUNT 1, as Redis counts them under an LRU policy); on fresh instances 4 more stream
tests run and pass on Redis (1,677 of 1,757).

**Where BendKV differs.** BendKV has no buffers per client: the sizes Redis gives
(qbuf-free, rbs, rbp, obl, oll, omem, tot-mem) and multi-mem (commands in the queue are
the actor's, not the client's) are 0, as is qbuf of a client that is not the one asking
(a waiting client with commands after the blocking one holds them as commands, while in
Redis their bytes lie in the query buffer). Idle time is counted from the client's last
batch, while Redis also counts a written reply (to a subscriber getting messages, to a
client served after waiting). user is `default`, redir -1, resp 2 (no ACL, key tracking
or RESP3), events `r`. There is no CLIENT KILL MAXAGE (it is from Redis 7.4). A killed
client is cut off at the end of the actor's group, before any of its replies goes out,
while Redis frees it at once.

## 45. MONITOR

**What there is.** MONITOR as Redis 7.0.15 runs it (`monitorCommand`, `call()` and
`replicationFeedMonitors`): the client becomes a monitor and gets OK (a client already a
monitor is answered nothing, and the call is counted), and every call run after that by
any client sends every monitor a line: the time, the database after the call and the
client's address, `+<s>.<us> [<db> <ip:port>]`, then the call's arguments as the client
sent them (with their case; an inline request split as Redis splits it), each in quotes
as Redis's `sdscatrepr` puts them (`\"`, `\\`, `\n`, `\r`, `\t`, `\a`, `\b`, a byte
outside the printable ones as `\xhh`). A line is sent by a call that would go through
`call()`: a command the parser refused (unknown, with a wrong number of arguments), one
refused before the client authenticated, to a client with a subscription or to a
monitor, and one queued in a transaction send no lines; the queued ones send theirs when
EXEC runs them, before EXEC's own line, and a refused EXEC sends its line anyway, as
`execCommandAbort` does. A blocking command sends its line when it blocks, not when it is
served. The administrative commands (CONFIG, CLIENT LIST, KILL, NO-EVICT and UNBLOCK,
MONITOR) and EVAL send no lines (Redis's flags `admin` and `skip_monitor`, generated
together with the command table), and AUTH's password and HELLO's user and password are
replaced with `"(redacted)"`, as Redis hides them while reading: for AUTH when there are
at most two arguments, for HELLO after a version Redis accepts (2 or 3), up to the first
invalid option. A monitor reads and writes nothing: a command that reads or writes keys
or may be replicated (PUBLISH, SPUBLISH, EVAL; the flag `may_replicate`, which COMMAND
INFO hides) is refused with "ERR Replica can't interact with the keyspace" once the
parser's checks, authentication and the subscription's limits pass, as Redis refuses it
to a replica (in MULTI it flags the transaction); MONITOR in a transaction's queue
answers "ERR MONITOR isn't allowed for DENY BLOCKING client" when EXEC runs it. A
monitor's own call first gets its reply, then its line; with CLIENT REPLY OFF, or SKIP
before its next command, a monitor gets no lines, its own included, as Redis drops what
it writes to such a client, and after QUIT the line of its own QUIT does not reach it.
RESET makes it no longer a monitor (the other monitors get its RESET), as do the end of
the connection and CLIENT KILL. CLIENT LIST shows a monitor with the flag O, type normal.

**In the actor.** The monitors are a list in the registry of clients, in the order they
came: each with its id, its reply channel, and whether its replies were on at the end of
its last batch. While there is a monitor, the fast path is off, by a bit of the Pub/Sub
state word, as for a killed client; the classes of keyspace events, for which the actor
computes a command's events, are now only the low bits of this word, so neither of the
two bits makes it compute them. After each call of the general path the actor writes the
call's line once, sends it to every other monitor with replies on (Push, like a message
to a subscriber; a monitor's connection waits as a subscribed client's connection does)
and puts it among the client's own replies if the client is a monitor, after the reply to
the call (for the calls EXEC runs, after EXEC's array). The arguments as sent are taken
from the bytes the batch came in: every batch brings them to the actor (raw in Req), the
fast path throws them away, and the actor parses them into each request's arguments
(`P.argvs`, the same framing as the parser's) only when a line needs them, at the
batch's first line. The rest of a batch after a blocking command keeps its arguments with
it, as does each command in a transaction's queue, so a monitor started while a client
waits or queues a transaction sees their lines as Redis's monitor would.

**What a buffer costs.** The bytes of a batch belonged to the parser: it read them and
cut off the tail of an unfinished request (String.drop, which drops what comes before
it). Kept for the actor while the parser read them, they became shared, and a shared
buffer is expensive to make shared (`rfc_wrap`), it is read through a redirect at every
String.code_at, find and slice of the parse, and it is expensive to drop: GET became 25
instructions more expensive with 16 requests per batch, and 251 without a pipeline
(10,373, +2.5%). Now the parser takes the buffer and gives it back together with the
batch (raw in Batch), copies the tail of an unfinished request (a copy where String.drop
gave a view; there is one only when a read ended in the middle of a request), and parses
a request longer than a window where it lies: no one shares the buffer, and the actor
drops it where the connection did. GET, SET and INCR take 3,298, 4,223 and 4,485
instructions (3,299, 4,223 and 4,489 for the code before, built by the same compiler and
counted in turn), GET without a pipeline 10,100 (10,122).

**Tests.** `tests/monitor_test.py` runs in `make test` against each mode of the server:
scenarios on BendKV and on Redis with their own clients, whose transcripts are compared
line by line, a monitor's line without the time and the client's address: 41 lines (the
case of a command as sent, bytes in quotes, an inline request, numbers; what is not shown
and what is; MULTI, the queued commands at EXEC, errors, DISCARD, a nested MULTI, WATCH,
a refused EXEC, MONITOR in a transaction; the database after SELECT, SWAPDB and MOVE;
AUTH and HELLO hidden and not; a blocking command by timeout, served, and with a pipeline
after it; a monitor's own commands, refused ones, a repeated MONITOR, MULTI and EXEC of a
monitor; a client with a subscription, a monitor with a subscription; CLIENT REPLY OFF,
ON and SKIP of a monitor; a client without a password; monitors started while a
transaction is being queued and while a client waits with a pipeline; the flag O in
CLIENT LIST; RESET, QUIT and CLIENT KILL of a monitor; MONITOR in a pipeline; INFO
statistics). A monitor's lines are read up to a marker, a command of its own client whose
line comes after the lines of the commands before it. And a check under load: four
monitors and 20 clients, each sending 200 SETs in a pipeline; each monitor gets all the
lines, each client's lines in order. Redis's test suite: 797 of the 1,677 tests that
Redis passes (47.5%; it was 794): `unit/introspection` passes 25 of 28, a monitor's lines
for the commands run and for a transaction in order, with EXEC's line also when an error
in the queue aborted the transaction (the other three look in a monitor for the calls of
a Lua script and of a function, and for MIGRATE's hidden arguments), and `unit/other` the
test of RESET clearing a monitor's state.

**Where BendKV differs.** A line's time is the group's time (the actor runs a group at
one time), in ms: the microseconds end in 000, while Redis reads the clock for each call.
The calls EXEC runs for a monitor put their lines after EXEC's array, while Redis writes
them between the array's replies (and a client reading the array reads it wrongly). HELLO
3 is refused (BendKV speaks only RESP2), and the user and password in its line are hidden
all the same, as Redis hides them for a version it accepts.

## 46. Authentication as Redis decides it

Two rules of Redis that BendKV did not follow; they were found when the MONITOR tests
compared a client without a password.

**When a client is asked.** Redis requires AUTH (`processCommand`) after it has found the
command and checked its number of arguments against the command table, and before the
command runs. An unknown command or subcommand, and a number of arguments the table does
not allow, get their own error, whoever the client is; an error the command itself finds
while running (syntax, a value that is not an integer, a number of arguments the table
allows but the command does not, as with PING with two) is NOAUTH for a client that must
authenticate. BendKV's parser finds such errors itself, before running (Bad, for a
session command SBad), and the session answered with any error of the parser, whoever the
client was: `SET k v EX abc` from an unauthenticated client got "ERR value is not an
integer or out of range", and in Redis NOAUTH. INFO already told these two kinds apart (a
refused call and a failed call: `stat.class`), and now the server takes the error of a
failed call as a separate session command, SFail (`R.fail.if`, where the request's code
is computed), whose reply a client gets only when it may run commands; Bad and SBad are
what Redis refuses before asking for AUTH. A batch with a failed call goes by the general
path, as a batch with a connection command does; GET, SET and INCR are parsed without
this.

**Who is authenticated.** Redis authenticates a client on connecting if there is no
password then (`createClient`, `clientSetDefaultAuth`), and on RESET if there is none
then; AUTH and the AUTH in HELLO authenticate it; nothing else changes this. A password
set later asks nothing of an already authenticated client, and a client that did not
authenticate is asked again when a removed password is set again, whatever it ran without
the password. BendKV marked a connection authenticated after any command run without a
password (`step_conn`: a client that may run commands is authenticated), and so it asked
a client that came before the password and had sent nothing yet, and let through a
client that came while there was a password, ran a command without a password, and came
back when the password was set again. Now a connection keeps its authentication as Redis
does: the actor answers a connection's Join with its state on connecting, authenticated
if there is no password then (`S.conn_join`), and only AUTH, HELLO and RESET change it
(`step_conn` and the other steps of a connection keep it, the fast path leaves the
connection as it was). The connection waits for this answer before its first read: one
pass through the actor per connection, not per request.

**The proofs.** SFail is a session command that needs a client that may run commands, so
the law `noauth` (an unauthenticated client of a server with a password runs nothing on
the databases but the parser's errors) holds with three new cases, as for MONITOR. The
lemmas of the fast path (it runs a batch as the general path does) carry the client's
authentication through the batch instead of setting it, and the proof that an
unauthenticated client stays so takes it from the client's state (`or_false_l`).

**Tests.** `tests/auth_test.py` runs in `make test` against each mode of the server:
scenarios on BendKV and on Redis, whose transcripts are compared line by line, 72 lines
(27 commands, errors of each kind and commands that run, from a client that must
authenticate, one at a time and in a pipeline, and after it has done so; a failed AUTH;
HELLO with AUTH and without; RESET with a password and without; a password removed and
set again; a pipeline that sets the password and goes on; a transaction with errors of
each kind; the errors of a client with a subscription; commandstats and errorstats from
INFO). On the earlier code 17 of them differ. `tests/monitor_test.py` no longer
authenticates the clients that came before the password; only BendKV needed that.

**What it costs.** GET, SET and INCR take 3,303, 4,223 and 4,487 instructions (3,302,
4,222 and 4,485 for the code before, built by the same compiler and counted in turn): the
fast path's requests are parsed and run as before. A new connection waits for the actor
once more before its first read; against the ~90 µs in which a Python client connects,
sends PING and closes the connection (3,000 in a row, three runs per build), this does
not show.

## 47. The rewrite of the append-only file (BGREWRITEAOF)

**What there is.** BGREWRITEAOF answers as Redis 7.0.15 does (`bgrewriteaofCommand`):
"Background append only file rewriting started"; while a rewrite runs, the error
"Background append only file rewriting already in progress"; in EXEC, "Background append
only file rewriting scheduled", and cron starts the rewrite at its next look, as Redis's
`serverCron` starts a scheduled one. Cron also rewrites a file that has grown by itself,
as Redis does with `appendonly yes`: larger than `auto-aof-rewrite-min-size` and grown by
`auto-aof-rewrite-percentage` (not 0) of its size after the last rewrite (or at the
start; a base of 0 counts as 1), with the log line "Starting automatic rewriting of AOF
on N% growth"; after three failed rewrites in a row it puts its own rewrites off for a
minute, then two, four and so on up to an hour (`aofRewriteLimited`, with the same log
line as Redis's), and a rewrite requested in EXEC forgets the failures and starts all the
same. INFO's persistence section shows it as Redis does: `aof_rewrite_in_progress`,
`aof_rewrite_scheduled` (and `aof_pending_rewrite`), `aof_last_rewrite_time_sec` and
`aof_current_rewrite_time_sec` (whole seconds, -1 for none), `aof_last_bgrewrite_status`,
`aof_rewrites` and `aof_rewrites_consecutive_failures` (CONFIG RESETSTAT counts both
anew), and after a rewrite `aof_current_size` and `aof_base_size` are the size of the
new file. With `appendonly no` BGREWRITEAOF writes `appendfilename` all the same, as
Redis does, and a server started with `appendonly yes` reads it afterwards.

**What it writes.** The commands that make the databases as they are at the start of the
rewrite, as Redis's `rewriteAppendOnlyFileRio` writes a base without an RDB preamble: a
SELECT of each database with keys, then for each key its SET, RPUSH, SADD, HMSET or ZADD,
64 elements or pairs per command (`AOF_REWRITE_ITEMS_PER_CMD`), a score as `%.17g`
writes it (`F.f64.show`), and a PEXPIREAT of the time the key expires, if it has one;
then the records appended to the file since the start of the rewrite, the first after its
own SELECT (Redis's `aof_selected_db = -1`). Everything is written to a temporary file
next to the file (`temp-rewriteaof-bg-<pid>.aof`: a rename does not cross file systems),
which is synced every 4 MB as it is written if `aof-rewrite-incremental-fsync` is yes
(the default; this is how Redis's child syncs its file, `REDIS_AUTOSYNC_BYTES`) and at
the end, renamed into the file's place (`File.rename`, the twenty-eighth patch: whoever
opens the file finds the old one or the new one, whole), and the directory is synced;
after that the actor appends to the new file, and the `everysec` syncer opens the file
every second instead of keeping its own descriptor: a rewrite puts a new file at the
path. A failed rewrite (a temporary file that cannot be created, written, synced or
renamed) logs the reason and "Background AOF rewrite terminated with error", removes the
temporary file (`File.unlink`) and leaves the file as it was; a failure after the rename
(syncing the directory, opening the new file) stops the server, as a failed write to the
file does: the new file's name may not be on the disk, and with it the writes
acknowledged after it.

**Without fork.** Redis spawns a child that writes the memory as it was at the moment of
`fork`, while the parent works on. BendKV's databases are values: the actor keeps them as
they are at the start of the rewrite (a snapshot: nothing is copied, a write after it
makes new nodes where it changes nodes it shares with the snapshot, as the child's pages
are copied when the parent writes to them), and writes them slice by slice: the keys of a
few dozen entries of a database's trie (`A.rw.slice`, a scan from a cursor, as for SCAN),
encoded and accumulated until there are 64 KB of them for the temporary file; after each
slice, a turn of the event loop (`IO.sleep(0)`) for the connections. When a slice goes
and how large it is is a choice between the rewrite's time and the requests' wait: after
a group of requests, a slice of 64 entries, at most once per 4 ms, so a load that does
not let the actor wait gives the rewrite a small part of its time; while there are no
requests, slices of 32 entries one after another (a request that comes meanwhile waits
for one slice, about a tenth of a millisecond), and of 256 when there have been no groups
for 10 ms (`idle.step`: the server is idle, and the rewrite goes faster). The records the
actor appends to the file meanwhile are also accumulated in memory (Redis 6 accumulated
them in the rewrite buffer; Redis 7 writes them to a new file of its multi-part layout)
and are written after the snapshot, in the same step as the rename, so not a single group
passes between the last of them and the replacement of the file.

**What a rewrite costs the requests.** 950 thousand keys, a file of 42.7 MB, a four-core
machine with its own spread from measurement to measurement of about a fifth either way:
without load the rewrite takes 3–4 s (2.9–3.1 s with `aof-rewrite-incremental-fsync no`:
syncing every 4 MB costs a quarter of the time). Under redis-benchmark's GET at full
speed (20 clients, pipelines of 16), GET during a rewrite gives 414–460 thousand requests
per second against 513–788 thousand without one; p99 1.4–1.6 ms against 0.8–1.6 ms, the
longest wait 8.5–21 ms against 4–42 ms (without a rewrite these are the `everysec`
syncs). The first version wrote a slice of 256 entries after each group and slice after
slice while there were no requests: the rewrite took 3.3 s, but GET fell to about 220
thousand per second, and the last sync, of the whole file at once, held the actor for 90
ms; syncing every 4 MB brought this wait down to 30 ms, and the current slices gave the
numbers above.

**What it costs.** GET, SET and INCR take 3,301, 4,228 and 4,488 instructions (3,300,
4,226 and 4,489 for the code before, counted in turn). The first version cost 3,567,
4,549 and 4,811 (+8%), for two reasons. Cron's look every 100 ms of the actor's time read
two configuration parameters (a walk over its 178 items); under callgrind, whose slowness
stretches a measurement over many looks, this was 65 instructions per request, and now
the look reads them only with `appendonly yes`, and the second only if the first allows a
rewrite. And the rewrite's state, a record of plain fields with the running rewrite
inside, traveled flat, eighteen words in every frame of the actor's loop: the widest
frame or result sets the registers of all functions of the program (46 instead of 35,
the widest result 29 words instead of 17), and every call and return of every request
paid for them (+1.5%). Now the state is a type that holds itself (`RwOf`, never built),
and the compiler makes it a separate node, like the Pub/Sub state and the database; there
are 35 registers again.

**Tests.** `tests/rewrite_test.py` runs in make test: BGREWRITEAOF's replies and the INFO
fields against Redis line by line; the same databases on both, rewritten by both,
BendKV's file against Redis's base command by command (each key's commands and how many
elements each has, its elements and time), BendKV and Redis from BendKV's file; 150
thousand keys and pipelines of 200 writes of all kinds on five databases (SWAPDB, MOVE,
COPY, RENAME, transactions, FLUSHDB) to BendKV and to Redis during the rewrite (about 150
pipelines) and after, the databases compared, then BendKV and Redis from the new file;
BendKV killed (SIGKILL) during a rewrite, with acknowledged writes, and its start from
the old file; `appendonly no`; cron's rewrites (none under the minimum, none with a
percentage of 0 or while the file has not grown by the percentage, one when both hold);
failed rewrites (a directory in the temporary file's place), their accounting and log,
three in a row that hold cron back (with a log line), and a rewrite scheduled in EXEC
that starts all the same. The runtime test `tests/io/file_rename.bend` of the
twenty-eighth patch passes on C and on JS.

**The proofs.** BGREWRITEAOF is a session command (SRewrite) that needs a client that
may run commands, so the law `noauth` holds with three new cases, as for MONITOR. The
rewrite itself is checked by tests but not proved. Its law is that the rewritten file
replays into the databases it was written from, key by key; it needs a law that a scan
from the first bucket reads every key once (the invariant "a key is in a bucket once",
not yet proved), the laws of RPUSH, SADD, HMSET and ZADD of a key that is not there, and
that a number written as `%.17g` reads back as itself. The law `recover` speaks of a file
the server wrote as its log from an empty file; after a rewrite the head of the file is a
snapshot, and recovery rests on tests. For any file, a rewritten one too, it is still
proved that it reads exactly as the records written into it, and the start replays it
only if the check accepts every record.

**Where BendKV differs.** One file, Redis 6's layout, where Redis 7 keeps a base and
increments with a manifest (`appendonlydir`); Redis 7 reads BendKV's file as a Redis 6
file (and moves it into its own layout), and BendKV refuses to start on a manifest. No
RDB preamble: `aof-use-rdb-preamble` is stored, and the file is commands whatever it
says, as Redis writes it with `no`. A key whose time has passed is skipped, while Redis
writes it with its time, and it expires when the file is read. BGREWRITEAOF never answers
"Can't execute an AOF background rewriting": BendKV spawns nothing, and a temporary file
that cannot be created is a rewrite that ended with an error, as a child's failure is in
Redis. The temporary file's name has the pid of the server itself, and the log has the
Redis 6 lines that apply to one file (no "Successfully created the temporary AOF base
file").

## 48. maxmemory and eviction

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
holds the databases as they were (section 47): a key evicted while it runs frees nothing
until it ends, and an eviction that waited for the heap to come down would evict every
key. So, while a rewrite runs, an evicted key counts as freed by MEMORY USAGE's estimate
of it, the debt, which the heap is credited with until the rewrite ends.

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
Pruning the nodes a delete empties would end it (DIRECTIONS.md). (It came in section 50:
a delete takes the nodes it empties, and 200,000 keys evicted to a tenth of their memory
leave 10,208, in 1.6 s.)

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
FLUSHDB ASYNC give back. The runtime test `tests/io/heap.bend` of the twenty-ninth patch
passes on C and on JS, and `tests/run/mem_cells.bend` of the thirtieth on C, on JS and in
the interpreter.

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
any database, and no delete clears it: a new key may find an old key's word. A request
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

## 49. RESP3

**What there is.** RESP3 as Redis 7.0.15 speaks it (section 3zx of FINDINGS.md): `HELLO 3`
switches a connection, and its replies are written as Redis writes them in RESP3, typed
where Redis types them (nulls, doubles, maps, sets, pairs, verbatim texts, pushes). The
replies are typed where they are made (`R.Reply` has eight constructors more, after the
eight it had), and two encoders write them: RESP2's, which writes the new ones as it
wrote what they replace, and RESP3's. The connection's protocol is a field of `S.Conn`.

**What RESP2 costs.** A RESP2 client's replies are the bytes they were, written by the
encoder they had. The new constructors come after the old, so that the old keep their
tags and GET's encoder its code. GET, SET and INCR take 3,337, 4,259 and 4,546
instructions (3,328, 4,252 and 4,514 before, counted in turn, `tools/perf_guard.sh`): the
batch reads the connection's protocol to pick its encoder, and an answer that holds a
switch of protocol is cut at it.

**What RESP3 costs.** The same. With one client that pipelines 20,000 requests 16 at a
time (`CLIENTS=1 RB_FLAGS=-3 tools/callgrind_req.sh`), GET takes 3,550 instructions in
RESP3 and 3,548 in RESP2, SET 4,483 and 4,471, INCR 4,777 and 4,755. The two encoders
take the same instructions for a reply, about 32 for GET's bulk, within one: a build with
symbols (`-g`) counted by the line, under callgrind, gives RESP3's encoder 645,169
instructions for its 20,140 replies and RESP2's 634,152 for 20,000.

With redis-benchmark's 20 clients of 1,000 requests each, RESP3 takes 157 instructions
more per request (GET 3,489 against 3,332, the build with symbols). Each client sends
`HELLO 3` with its first 16 requests, and a batch with HELLO runs the general way, as a
batch with any command of the connection does: the session's general path ran 171 times
as often as with RESP2, whose only commands on it are redis-benchmark's two CONFIG GETs
(342 commands against 2). That is about 150,000 instructions for each client's first 17
commands, most of them taking apart and dropping the session's records; a client that
sends `HELLO 3` as it connects, as go-redis and Lettuce do, pays it once.

**The baseline.** `tools/perf_baseline.txt` held the counts written with values of a type
(section 31: GET 3,272, SET 4,261, INCR 4,499); each change since has added a few
instructions, measured in its section. CI's perfcheck counts on GitHub's runners, where
one build counts up to 0.7% apart from one run to the next (GET 3,317 and 3,331 for one
build of the log's rewrite, INCR 4,544 and 4,513 for one of maxmemory), and it counted
RESP3's GET at 3,371, 3.0% past that baseline and so past the guard's tolerance. The
baseline is now RESP3's counts in CI: GET 3,371, SET 4,268, INCR 4,543.

## 50. Deletes that take the nodes they empty

**The change.** A delete walked the trie as every write does (`tmod_h`, with `ODel`): it
rebuilt the nodes on the key's path and changed the bucket at its end, and a node it left
without entries stayed. A trie kept the nodes of every path a key had taken, up to 69,905
nodes over its 2^20 buckets (9 MB), and a delete of a key that was not there built the
nodes down to its bucket. Now a delete walks with `tdel_h` (`tools/gen_trie.py`): at each
level it looks at the subtrie it changed (`tis_tip`, a tag); when that is empty, it looks
at the node's 16 subtries from the first (`tnode_if`, `tnode`), and a node of 16 empty
subtries goes, and its parent looks at it in turn; a walk that meets an empty subtrie
returns it as it is. The 16 arms of the walk stay one under the digit select (patch 7):
each takes the subtrie of its digit and builds its node with the result there, and the
look at the result comes after, so the walk is one arm with its slot swapped. The other
writes keep `tmod_h`: none of them empties a bucket. The eviction's fresh trie for a
database it emptied (`evict.compact`) goes: the trie is empty.

**What a delete costs.** Under callgrind, one connection that pipelines 16 deep, after
100,000 keys set (`key:0` to `key:99999`), the instructions of each run of requests over
their number, as `tools/callgrind_req.sh` counts them:

| requests | before | now |
|---|---:|---:|
| DEL of 20,000 of the keys | 5,041 | 5,118 |
| DEL of the same 20,000, gone | 4,441 | 4,449 |
| SET of 20,000 new keys | 3,799 | 3,795 |
| DEL of those 20,000 | 5,054 | 5,125 |
| GET, SET, INCR (`tools/perf_guard.sh`) | 3,335, 4,260, 4,540 | 3,334, 4,255, 4,548 |

Of 100,000 keys, most are alone in their bucket and in their node at the last level (a
node of 16 buckets holds 1.5 keys): their DEL empties the bucket and the node, looks at
its 16 buckets, gives it back, and looks at the node above, whose first subtrie is seldom
empty, about 75 instructions. A first version looked at the 16 subtries of every node it
rebuilt, whatever the delete did to them: 5,157 for the first row, and 4,489 for a key not
there. A DEL that does not empty its bucket, and one of a key not there, pays the look at
each subtrie it changed, about 8.

**What it gives.** 200,000 keys (`key:N`, values of 7 or 8 bytes), INFO's `used_memory`:

| | before | now |
|---|---:|---:|
| the empty server | 35,048 | 35,048 |
| 200,000 keys set | 22,982,168 | 22,982,168 |
| half of them deleted | 15,783,928 | 14,411,256 |
| all of them deleted | 8,583,928 | 35,448 |

The eviction of the same 200,000 keys, from a CONFIG SET of maxmemory to a tenth or a
half of what they take, to the heap within the limit (`total_eviction_exceeded_time`, and
the keys left):

| policy, limit | before | now | Redis 7.0.15 |
|---|---:|---:|---:|
| allkeys-lru, a tenth | 2.89 s, none | 1.57 s, 10,208 | 0.16 s, 9,888 |
| allkeys-lru, a half | 1.62 s, 27,776 | 1.14 s, 65,648 | 0.09 s, 86,352 |
| allkeys-random, a tenth | 6.54 s, none | 2.21 s, 10,192 | 0.30 s, none |
| allkeys-random, a half | 2.09 s, 36,544 | 1.51 s, 70,176 | 0.07 s, 86,351 |

Before, the nodes alone of a trie that had held 200,000 keys were past a tenth of their
memory, and the eviction evicted every key; now it stops where Redis stops. To a half, it
keeps fewer keys than Redis: a node of the last level holds a key's 16 buckets, so the
nodes take a larger share of a smaller database (65,648 keys hold 11.5 MB, 175 bytes a
key, where 200,000 held 115). It is still ten times Redis's time: its samples walk empty
buckets, as they did.

The picks and scans of a trie that deletes drained, one client pipelining 100 deep: a
set of 100,000 members (SADD) popped to its end, and 100,000 keys of which the first
99,000 are deleted:

| | before | now | Redis 7.0.15 |
|---|---:|---:|---:|
| SPOP of a set of 100,000, the first 90,000 | 21,660/s | 27,756/s | 284,810/s |
| the last 10,000 | 1,334/s | 28,655/s | 420,507/s |
| RANDOMKEY, 1,000 keys left of 100,000 | 4,987/s | 56,844/s | 319,209/s |
| a whole SCAN COUNT 100 of those 1,000 | 21.3 ms | 2.3 ms | 39.6 ms |

A pick looks through the buckets from a random one, and a scan through the trie, so both
paid for the nodes of the keys that had gone; now they pay for those of the keys left.
(Redis's SCAN is slow here for its table, which keeps the buckets of 100,000 keys until
its cron shrinks it.)

**The proofs.** The laws of DEL (`Laws.entry_del_same`, `Laws.entry_del_other`) stood on
`tget_tmod_same` and `tget_tmod_other`, proved of `tmod_h`. `tdel_eq` says that the trie
`tdel_h` leaves and the one `tmod_h` leaves with `ODel` read the same at every bucket, so
each law takes one rewrite more and the rest as it was. Its induction on the depth needs
three facts: a node reads as the trie `tnode_if` makes of it (`tnode_read`, 35 cases: a
node of 16 empty subtries reads empty, as the empty trie does, and any other is kept; the
checker reduces `tnode` only on a node whose first subtrie that is not empty has a known
constructor, so the cases name it); two nodes whose children read alike read alike
(`node_same`); and the nodes `tmod_h` builds down to the bucket of an empty trie hold
empty buckets (`del_tip`, from `walk_same`, `tget_tmod_same` and `tget_tmod_other`).
`tools/gen_trie.py` writes `tdel_h` (and `tnode`) into `src/map.bend` and the 16-way
lemmas into `proof/PROOF.bend` (227 lines, and 26 by hand); `make check` takes 11 s and
the verdict 55 s.

## 51. Walks that borrow the trees their callers own

**What was left** (section 38). The compiler decides once for each function whether a
parameter is borrowed or owned, and one caller that gives a function a value it owns,
at its last use in a tail call, makes the parameter owned for every caller. `keys`
gives its trie to `tkeys` that way, `scan`, `reap` and `pick` theirs to `tscan`,
`zt.slice` and `zt.rslice` their trees to `zt.slice.go` and `zt.rslice.go`; and a walk
that owns its tree takes each node it reads (`ctr_own`), which copies a node the
keyspace shares, and drops the copy after.

**The thirty-first patch** (`walk-lend.patch`, `comp.ts` +69/−1, 822 `ttok` tokens). A
walker that reads is a def that calls itself, takes a tree (a datatype with a node of
two or more subtrees of its own type: a trie's node has sixteen, a sorted set's two)
and builds none of that datatype's nodes (`walk_reads`). A tail call that gives one a
value its caller owns, at its last use, is emitted as `r = f(t); r` (`tail_lends`): the
caller holds the value in its frame, the walker borrows it, and the caller drops it
after the call; a call that holds such a value registers a lend for the walker. A tail
call into the caller's own loop (`loop_of`) stays a jump, so a loop does not grow the
stack. A function that rebuilds what it is given, or takes a list or a record (a
request's command, whose fields its execution takes over), owns it as before. One
detail of the fixed point: a walker passed a word of a root that ends up owned is not
made owned at the end of that pass (its caller holds what it then owns in the next),
since an owned parameter stays owned. In BendKV eight functions borrow their trees now
(`tkeys`, `tscan`, `zt.slice.go`, `zt.rslice.go`, `zt.trie`, `zt.drain`, `zt.cutl` and
`zt.cutr`), and 34 of its 1,134 compile otherwise, their callers holding what they gave.

**Measured** (`tools/walks.sh`, instructions per command under callgrind, one client,
against the same build without the patch):

| command | before | with the patch | |
|---|---:|---:|---:|
| KEYS of 9,800 keys, a key | 2,779 | 1,961 | −29% |
| SCAN 0 COUNT 1000 | 4,869,617 | 4,306,006 | −12% |
| RANDOMKEY | 134,027 | 96,611 | −28% |
| ZRANGE of 10 of 100,000, WITHSCORES | 73,222 | 59,686 | −18% |
| ZREVRANGE of 10 of 100,000 | 58,777 | 45,745 | −22% |
| ZRANGE of all 100,000 | 139,487,197 | 111,135,782 | −20% |
| ZUNIONSTORE of two of 10 | 316,448 | 290,733 | −8% |
| ZUNIONSTORE of two of 1,000 | 41,177,280 | 39,459,267 | −4% |
| ZREMRANGEBYRANK of one of 1,000 | 56,795 | 50,907 | −10% |
| ZRANK, ZSCORE, ZINCRBY, ZADD of 100,000 | 25,496 … 31,851 | 25,088 … 31,655 | −1 to −2% |
| GET, SET, INCR (`make perfcheck`) | 3,332, 4,257, 4,543 | 3,332, 4,259, 4,542 | |

`zt.drain` takes apart a tree made for a STORE, which no one shares: borrowed, it keeps
the members it puts in its list and its caller drops the tree after, a little more
work than taking the nodes over, and the STOREs above still came out cheaper.

**The sweep's memory.** The sweep of expired keys (`reap`, ten times a second) reads the
trie with `tscan`, and took the nodes it read. 4,000 keys set with SETEX, then INFO's
`used_memory` once a second for twelve seconds:

| | growth after a second, and after twelve |
|---|---:|
| without the patch | 69,152 bytes, 69,152 |
| with the patch | 96 bytes, 96 |

The 69 KB are copies of the nodes the keyspace shares, held from one pass of the sweep
to the next. With the patch alone, a test of `tests/maxmemory_test.py` failed: a
volatile-lru eviction of the keys with a time could not get within its limit, since the
trie kept the nodes of the keys it evicted, where the sweep's copies, which went with
those keys, had made up for them. With the deletes of section 50 it passes.

## 52. Errors found among the replies, not in their bytes

**The change.** The actor counted the error replies of a batch of one command from its
encoded bytes: when they had a `-`, it read them a line at a time (`String.find` of the
next `\n`, `String.code_at` of the line's first byte) and took each line that began
with `-` for an error. The collections' commands that may fail (WRONGTYPE) answer many
lines, a bulk's line may begin with `-`, and an index into an answer of many chunks walks
it from its start. Now the replies are looked at before they are encoded (`R.errs.one`),
as those of a batch of several commands were (section 18), and the bytes are not read.

**Measured.** ZRANGE key 0 -1 WITHSCORES, one client, the time of the reply:

| sorted set | before | now |
|---|---:|---:|
| 20,000 members, scores from −100 to 100 with three decimals | 14.7 s | 0.145 s |
| 20,000 members, integer scores from −10^6 to 10^6 | 7.2 s | 0.029 s |
| the first 1,000 of the 20,000, with scores | 0.060 s | 0.004 s |

Under callgrind, one connection pipelining 16 deep (instructions a request):

| requests | before | now |
|---|---:|---:|
| ZRANGE 0 -1 WITHSCORES of 1,000 members, half the scores negative | 247,766,764 | 13,926,506 |
| DECR of 1,000 counters below zero | 6,751 | 6,679 |
| GET, SET, INCR (`tools/perf_guard.sh`) | 3,335, 4,257, 4,539 | 3,334, 4,257, 4,548 |

The answers of the batches of INCR in `make perfcheck` have no `-`: they paid one
`memchr` and now pay the look at each reply's tag, 9 instructions. A first version
looked at the bytes first and among the replies only when they had a `-`: the replies
were then held across their encoding, which every batch paid for, not only those it
looked at: GET 3,905 (+17%), SET 4,586 (+8%), INCR 5,193 (+14%). Looking at the replies
first, as the batches of several codes do, hands them to the encoder after.

## 53. Reads of the keyspace that borrow it

**What was left** (sections 38 and 51). The compiler makes a parameter owned for every
caller when one caller gives it a value it does not keep: a value made for the call, or
the last use of a value the caller owns passed in a tail call. Three callers did so to
the reads of a key's entry:

- `KV.entry` gave `bent` the bucket that `tget_h` answers (`bent(V, k, tget_h(..))`), so
  `bent` owned its bucket; `tget_ke`, the walk that reads a key's entry and gives it its
  bucket, owned the trie it walks; and `entry.at`, which gives it the trie, owned it
  too.
- OBJECT, HRANDFIELD, MEMORY USAGE, SRANDMEMBER and ZRANDMEMBER gave `R.db.ent` the
  database `R.ds.focused` answers, and the server's `ds.entry.at` gave `R.db.entry` the
  same: `db.ent` and `db.entry` owned their database.

Every command that reads a key's entry first (LLEN, HGET, SISMEMBER, ZSCORE, and the
writes of a collection: LPUSH, HSET, SADD, ZADD, ...) then took the database's record,
which the actor keeps, so a copy of it (`ctr_take` of a shared node), and walked the
trie owning it: a copy of each of the five nodes on the key's path (`ctr_own`), sixteen
counts raised and fifteen dropped at each, and the copies dropped after.

**The change.** `KV.entry` holds the bucket in a variable and calls `bent` before its
tail (`b = tget_h(..); m = bent(V, k, b); m`): it drops the bucket after the call, which
lends it to `bent`. The session reads the focus with `R.ds.ent`, and the server with
`R.ds.entry` (new): a match on the databases that lends the focus's record. A database
out of focus is read with `R.dbs.entry` (new) from the list of the databases, held while
it reads. 41 parameters that were owned are borrowed now: `db.ent`, `db.entry`,
`ds.ent`, `ds.has`, `entry.at`, `tget_ke` and `bent`; those of the eviction's reads of
the keyspace (24 of `evict.*`, `pool.pick`, `keys.has`) and of the sweep of expired keys
(`reap`, `reap.of`, `reap.keys`); and those of the reads of LMPOP, LMOVE, SMOVE and
RENAME (`lmpop.first`, `lmpop.head`, `mv.find`, `smv.of`, `ren.find`). The two new
functions own theirs: the server calls them, for WATCH and the clients that wait, with
databases it gives. The proofs see these reads as values, and `KV.entry`'s variables
reduce away: no proof changed.

**Measured** (`tools/colls.sh`, new: instructions per command under callgrind, one
client, one request at a time; a list, a hash, a set and a sorted set of 100,000 members
each):

| command | before | now | |
|---|---:|---:|---:|
| GET | 14,337 | 14,307 | |
| SET | 15,375 | 15,184 | |
| LLEN | 19,794 | 15,874 | −20% |
| LINDEX 0 | 21,972 | 18,055 | −18% |
| LPUSH | 23,523 | 18,264 | −22% |
| LPOP | 22,881 | 17,601 | −23% |
| HGET | 20,906 | 16,990 | −19% |
| HSET of a field there | 33,659 | 28,412 | −16% |
| HSET of a new field | 33,077 | 27,818 | −16% |
| HINCRBY | 34,471 | 29,219 | −15% |
| SISMEMBER | 21,002 | 17,105 | −19% |
| SADD of a new member | 31,615 | 26,341 | −17% |
| SPOP | 143,557 | 136,037 | −5% |
| ZSCORE | 21,698 | 17,751 | −18% |
| ZADD of a member there | 29,144 | 25,324 | −13% |
| ZINCRBY | 75,752 | 70,239 | −7% |
| GET, SET, INCR pipelined (`make perfcheck`) | 3,334, 4,257, 4,548 | 3,334, 4,259, 4,550 | |

The eviction reads the keyspace for each key it samples. 200,000 keys, then maxmemory
set as in section 50, the time until the memory is within the limit (runs of two or
three):

| | before | now |
|---|---:|---:|
| to a tenth, allkeys-lru | 1.62 s, 10,224 keys left | 1.03 s, 10,880 left |
| to a half, allkeys-lru | 1.0 s, 66,000 left | 0.6 s, 71,500 left |
| to a tenth, allkeys-random | 5.1 s, 10,200 left | 1.4 s, 10,250 left |

**What is left.** A read of a collection costs a GET and the read of the collection now,
1,600 to 3,700 instructions more. A write still copies the path of the collection it
changes, since the keyspace holds the old version while the command makes the new one,
and the keyspace drops the old version's path after: of HSET's 28,412 instructions,
5,290 are the drops of the old path (in `bkeep.go`, which puts the new hash in its
place) and 2,652 the copies of the path (`ctr_own` in `tmod_h` and `bset.go`). Taking
the value out of the keyspace before the change, and putting the new one back, would
save both (section 3zm).

## 54. HSET in place: the hash taken out of the keyspace

**What was left** (section 53). A write of a collection made its new version while the
keyspace still held the old one: it copied the path it changed (each node of it shared
by the two versions), and the keyspace dropped the old version's path when the new one
took its place. Of HSET's 28,412 instructions on a hash of 100,000 fields, 5,290 were
that drop and 2,652 the copies.

**The change.** An update whose operation is an HSET of pairs (HSET, HMSET) to a key
that holds a hash at now (`R.upd.takes`) takes the hash out of the keyspace before it
changes it: it writes a hole, an empty string, in the key's place (`KV.keep.at`), so
that the hash is held once and the write changes it in place, and the change then writes
the new hash over the hole (`R.db.upd.go`; `A.run.upd.go` with an append-only file). Two
orders of evaluation had to change for the hash to be held once:

- the update reads its entry's code before it gives the entry to `ent.live`, which would
  otherwise keep the entry, and the hash in it, for the read after;
- `KV.hash.put` and `hset.go` read whether a field is there before they write it: in a
  node built of both, the compiler ran the write first and held the trie for the read
  after it, so the write copied the path anyway.

Only HSET takes its value. A write that may leave its collection as it was (HSETNX of a
field there, HDEL of no field, HINCRBY of a field that is no integer, SADD of a member
there, ZADD of a score it has) answers CKeep and drops the collection it was given,
which a collection out of the keyspace cannot afford; and a list costs little to copy (a
push builds a node at one end).

**The proofs.** `db_upd_unfold` and `run_upd_unfold`: an update reads as the change made
where its key's entry lies, taken out or not; the proofs that unfolded `R.db.upd` and
`A.run.upd` rewrite through them (thirteen places). They rest on `upd_put_take`: a
change that writes its key's value over, keeping or setting it (`ch_over`), writes the
same trie over the hole as over the value, by `keep_keep` and `setx_keep` (a write after
a keep of the same key is as the write alone), by `tmod_twice` (two writes along the
same walk; `tools/gen_trie.py` writes its 16-way cases) and two lemmas of a bucket
(`bkeep2`, `bset_bkeep`); and on `takes_over`: an update that takes its value writes it
over (an HSET of pairs to a hash answers CHash). 390 lines of `PROOF.bend`, 104 of them
generated.

**Measured** (`tools/colls.sh`, instructions per command):

| command | before | now | |
|---|---:|---:|---:|
| HSET of a field there, hash of 100,000 | 28,412 | 21,178 | −25% |
| HSET of a new field | 27,818 | 21,311 | −23% |
| HSET of a field there, hash of 10 fields (a list of pairs) | 25,795 | 22,125 | −14% |
| HSET of a field there, hash of one field | 20,559 | 20,328 | −1% |
| GET, SET, LLEN, LPUSH, HGET, HINCRBY, SADD, ZADD | | as before (±0.3%) | |

**What is left.** A prototype took the value of every write of a collection, with no
care for the writes that leave it as it was: SADD of a new member took 25% fewer
instructions, ZADD of a new score 28% and ZINCRBY 34%. Each of those needs a test before
the take that the write changes its collection, and a proof of it.

## 55. SADD in place: the set taken out of the keyspace

**What was left** (section 54). SADD of a member new to a set copied the path it changed
in the set's trie and the keyspace dropped the old path after, as HSET did before
section 54: 26,284 instructions on a set of 100,000 members. The write could not take
every set it was given: SADD of members all there leaves the set as it was, answers
CKeep and drops the set.

**The change.** An SADD to a key that holds a set kept as a hashtable at now, whose
first member the set lacks, takes the set out of the keyspace as HSET does
(`R.upd.takes`): it adds that member for sure, so it writes the set over. An intset is
not taken: the test of its member walks its list, and SADD of a new integer to an intset
of 100 to 500 members took 511,928 instructions with the take against 449,438 without.

**The proofs.** `takes_over` covers the new case (`takes_mems`): an SADD whose first
member a hashtable lacks adds one or more members (`sadd_adds`), since the members added
to a set leave it no smaller (`le_add_mem`, `len_adds_ge`), the member it lacks makes it
one larger (`le_big_new`), and a size one or more larger, less the old size, is not 0
(`sub_pos`); so it answers CMems, which writes the set over. Two proofs that unfolded
the update (`mems_replay`, `snew_sadd`) rewrite through `db_upd_eq`, as thirteen did in
section 54, and `le`, `le_succ` and `le_refl` move before the take, which uses them. 120
lines of `PROOF.bend`.

**Measured** (`tools/colls.sh`, and SADD of 400 new members one at a time, instructions
per command):

| command | before | now | |
|---|---:|---:|---:|
| SADD of a new member, set of 100,000 | 26,284 | 20,273 | −23% |
| SADD of a new member, set of 10 to 410 strings | 22,555 | 19,959 | −12% |
| SADD of a new integer, intset of 100 to 500 | 449,438 | 449,545 | as before |
| GET, SET, LLEN, LPUSH, HGET, HSET, HINCRBY, ZADD | | as before (±0.6%) | |

**What is left.** SADD to an intset costs twenty times SADD to a hashtable. An intset is
the list of its members, as strings in increasing order, and `ints.at` compares a member
with each one it passes as integers, reading the digits of both strings again each time;
an add walks the list twice (the test of the member, then the put) and builds again the
part it passed. Redis keeps an intset as an array of integers of one width and finds a
member by binary search. ZADD of a new member and ZINCRBY (−28% and −34% in the
prototype) still need the test that their write changes the sorted set.
