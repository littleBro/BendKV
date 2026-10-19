# Patches to Bend

Thirty-nine patches to the Bend compiler (`bendlang/bend` @ `1cce499`, Bend 2.0.35).
They apply in order, each on top of the one before:

1. **`lazy-seal.patch`** — lazy sealing of reference counts: `bend2/comp.ts`, +46/−3.
2. **`packed-strings.patch`** — packed strings in the C runtime and byte TCP I/O
   (`TCP.recv_raw`/`TCP.send_raw`, twins in C and JS). Touches `bend2/comp.ts` (+334/−12),
   `bend2/base.bend` and `bend2/effs/tcp_*`, plus a new test `tests/io/tcp_raw.bend`.
3. **`borrow-reads.patch`** — borrowed reads: a field read from a lent value and passed on
   as owned is kept in place (`slot_keep`) instead of taking ownership of the whole
   value. `bend2/comp.ts` (+168/−22), a new test `tests/rfc/borrow_field.bend` and
   updated comments in three borrow witness tests (`tests/reg/brw_*`): they described
   the old rule.
4. **`string-natives.patch`** — native string operations: `String.append`, `length`, `eq`,
   `take`, `drop`, `to_upper`, `hash`, `code_at`, `find`, `slice` and `Nat.show` on packed
   strings run as functions of the C runtime, a chunk at a time, and those that read from
   them only borrow the string. The compiler recognizes three forms: a literal before `++`
   and `Nat.show` before `++` are written straight into the spare room of the chunk on
   the right, and `String.eq` with a literal is one `memcmp` or a comparison of words. A
   string of up to 6 bytes is stored right in the term word. Two strings of one chunk
   each are compared with one `memcmp`. The `TCP.recv_raw` buffer is reused between
   reads. `bend2/comp.ts` (+992/−9),
   `bend2/base.bend` (+36: the new `String.hash` — FNV-1a over character codes —
   `code_at`, `find` and `slice`), `bend2/effs/tcp_recv.c` (+28/−2) and the test
   `tests/base/string_index.bend`.

5. **`node-update.patch`** — a node is rebuilt in place: a match on a node the function
   owns keeps it as a spare block and reads the fields straight from it (`ctr_own` copies
   a shared node). Across one non-tail call the pointer to the node is kept, not its
   fields, and building the same constructor writes only the fields that changed.
   `bend2/comp.ts` (+80/−17) and the test `tests/rfc/node_update.bend`.
6. **`huge-pages.patch`** — the runtime's heap (the corpus) asks the kernel for 2 MiB pages
   (`madvise(MADV_HUGEPAGE)`): random reads over a large heap miss the TLB less often. It
   works when transparent huge pages are in `madvise` or `always` mode. `bend2/comp.ts`
   (+11).
7. **`digit-select.patch`** — field selection by digit: a match on an enumeration without
   fields ("digits") whose arms each take a different field of one node and differ in
   nothing else compiles to one arm. It reads the field whose number is the digit, builds
   the node with its slots permuted, and its continuation keeps the digit in the frame.
   The descent through the trie goes without an indirect jump at each level, and the
   rebuild of the path returns to one continuation instead of sixteen. `bend2/comp.ts`
   (+298/−16) and the test `tests/rfc/digit_select.bend`.
8. **`string-blobs.patch`** — a string of one chunk with nothing after it is the term of
   its buffer itself, with no node (a "blob"). An owning match shifts the position right
   in the term word; a non-owning match reads the blob through a view with the buffer's
   class in bits 51–54. Blobs are made by `slice`, `take`, copies, `Nat.show` and reads
   from a socket; every string function of the runtime, printing and I/O understand
   them. A key comparison costs one miss instead of two. `bend2/comp.ts` (+189/−43) and
   the test `tests/base/string_blob.bend`.
9. **`mem-prefetch.patch`** — a hint to the processor: `Mem.prefetch(A, x, k)` equals `k`,
   and on the C lane it also starts loading the node of `x` into the cache
   (`__builtin_prefetch` on every line of the constructor's fields, on the first 64 bytes
   of a buffer, on the seal of a shared node) and waits for nothing. It changes no value,
   so in theory it is just `k`; on the JS lane that is how it runs. Its result must be
   used: the compiler drops pure computations whose result is not needed.
   `bend2/base.bend` (+10), `bend2/comp.ts` (+19) and the test
   `tests/base/mem_prefetch.bend`.
10. **`io-loops.patch`** — several event loops, and sending on a separate thread.
   `IO.spawn_on(A, i, act)` runs a computation on loop `i`: loop 0 is the main thread, and
   each next one is a thread of its own, with its own allocator row, its own computation
   root and its own queues. Computations on different loops talk through channels: the
   channel effects take a shared spin lock, and a waiter is woken on its own loop
   (through the loop's mailbox, and a NULL in its pipe if the loop sleeps in `select`;
   before it sleeps, the loop waits ~30 µs for a handoff, spinning).
   `Chan.send_all(A, [(c1, x1), ...])` puts several values on several channels in one
   step: two such sends order their values the same way in every channel they share —
   the atomicity of a batch in sharded BendKV rested on this (the shards were taken out,
   section 14 of PERFORMANCE.md), and BendKV's actor answers a group of batches this way.
   `TCP.post(sock, data)` hands bytes to its loop's writer thread and gives the socket
   back at once; the writer sends them in order, and `Socket.close` closes the socket
   after them. Along the way, a waiting `recv` gives its buffer back to the thread
   (before, each waiting connection held 64 KiB, and glibc kept giving memory back and
   taking it again: `brk`, `madvise`), and `send_raw` writes into the thread's buffer
   instead of `malloc` with doublings. On the JS lane and in the interpreter there is one
   loop: `spawn_on` is `spawn`, and `post` is `send_raw`. `bend2/comp.ts` (+408/−55),
   `bend2/effs/chan.c` (+150), `chan.js`, `tcp_send.c`, `tcp_recv.c`, `socket_close.c`,
   the new `spawn_on.c/.js`, `tcp_post.c/.js`, `bend2/base.bend` (+27) and the tests
   `tests/io/spawn_on_loops.bend`, `tests/io/chan_send_all.bend`, `tests/io/tcp_post.bend`.
11. **`io-epoll.patch`** — `epoll` instead of `select`, and `TCP_NODELAY`. On Linux the
   event loop waits for descriptors through `epoll`. A socket the runtime made itself
   (`accept`, `connect`, `listen`, a UDP bind) is registered in its loop's epoll once,
   edge-triggered (`EPOLLET`), and the loop remembers for it whether it is ready to read
   and to write, and who waits for each. A `recv` that got less than it asked for marks
   the socket drained, and the next `recv` waits for an edge at once, without spending a
   system call on `EAGAIN`. The end of the stream (`RDHUP`, `HUP`, `ERR`) is remembered
   apart, and after it the socket does not count as drained: otherwise a FIN that came
   with the last bytes was lost, and the read waited forever (that is how `io_tcp_post`
   hung in 7 runs of 30). Other descriptors (files, pipes, sockets of user effects) join
   epoll with `EPOLLONESHOT` for each wait: code may close them behind the runtime's
   back, and the number would go to a new file. `accept`, UDP's `recv_from` and
   `TCP.poll` still park first, so that timers do not fall behind a steady stream of
   connections. Other systems keep `select`. Accepted connections get `TCP_NODELAY`: a
   reply of several writes no longer waits 40 ms for a delayed acknowledgment (a batch of
   1,000 SETs took 45 ms that way). `bend2/comp.ts` (+368/−16), the `tcp_*` effects,
   `udp_bind.c`, `udp_recv_from.c`, `file_close.c` and `listener_close.c`.
   (`TCP.post_list` was here too, a post of chunks as one buffer to merge the shards'
   replies; it was taken out together with the shards.)
12. **`file-raw.patch`** — byte file I/O for the append-only file (AOF). `File.write_raw`
   writes a string's bytes as they are, one `Char` (0..255) per byte, without UTF-8 (as
   `TCP.send_raw` does); a `Char` above 255 gives `EINVAL` before the write.
   `File.read_raw` reads bytes back as a string (as `TCP.recv_raw` does): on the C lane
   it is a packed buffer. `File.sync` answers once what was written is on the disk
   (`fdatasync` where there is one, `fsync` otherwise), and `File.truncate` cuts a file
   to a given size (`ftruncate`). `File.write_raw` writes straight from its loop's
   thread, as Redis appends to its log: a write to the page cache almost never waits,
   and the hop to a helper thread and back cost ~20 µs per batch. The other three go
   through the runtime's pool of helper threads, as other file effects do: the event
   loop does not wait for the disk and runs other computations meanwhile. The JS twins
   go through `fs`. `bend2/base.bend` (+30), `bend2/effs/file_read.c/.js`,
   `file_write.c/.js`, the new `file_sync.c/.js` and the test `tests/io/file_raw.bend`.
13. **`chan-drain.patch`** — `Chan.drain(A, chan, max)` takes the values a channel holds
   now, in order and no more than `max`, without waiting (an empty list if there are
   none) — as that many `Chan.recv` calls would, each finding a value; a sender that
   waited for room enters the buffer as values leave. So an actor that gets a request
   also takes those that came while it worked, and answers them all after one write to
   the disk (group commit, as Redis does in `beforeSleep`). `bend2/effs/chan.c` (+57),
   `chan.js` (+19), `bend2/base.bend` (+9) and the test `tests/io/chan_drain.bend`.
14. **`string-imm-index.patch`** — a fast path of `String.code_at` for short strings that
   live right in the term (up to 6 bytes, section 7.8): the byte is taken from the term
   itself by a shift. Before, such a string went to the slow path `str_code_at_far` (~146
   instructions for INCR, which reads its number digit by digit). `bend2/comp.ts` (+3)
   and the test `tests/base/string_imm_index.bend`.
15. **`writer-share.patch`** — the event loop itself sends part of what is posted to the
   writer (`TCP.post`). The loop and the writer measure what share of the time they work
   (in windows of 200 µs): the loop, everything but waiting for events; the writer, its
   `send` calls. If the loop is less busy than the writer by more than 10 points (many
   connections without pipelining: sending costs more than the request itself), the loop
   sends itself; otherwise it posts, and the sends run on the writer's core. While the
   writer sleeps, the loop sends itself too (waking the writer is a futex call, and it
   does not wake at once), but after four such sends in a row the next post wakes the
   writer: the load is back. The order of a socket's bytes is kept: the loop sends
   itself only when the writer has already sent everything posted to that socket before,
   and what the socket did not take at once goes to the writer. `bend2/comp.ts`
   (+104/−4).
16. **`writer-demand.patch`** — the loop decides who sends by whether it keeps up with its
   sockets. While fewer than four sockets are ready per wait for events
   (`IO_POST_BACKLOG`, on average over a span of 32 windows of 200 µs), the loop sends
   posts itself, at once, without the writer's ring: without a pipeline under one client
   thread, handing them to the writer only added latency and wakeups. When more sockets
   are ready (the loop falls behind) two spans in a row, the loop posts to the writer
   until the loop and the writer together are busy less than 60% of the time
   (`IO_POST_LOW`) three spans in a row; while it posts, the rule of the fifteenth patch
   applies. The writer starts with direct sends. `bend2/comp.ts` (+95/−44).
17. **`string-scan.patch`** — reading a string in place, for parsers.
   `String.hash_at(s, i, n)` is the hash of `n` characters from index `i`, without a
   slice; `String.digits_at(s, i)` is how many digits run from `i`;
   `String.dec_at(s, i, n)` is the number of `n` digits; `String.dec_line_at(s, i)` is a
   line of digits closed by `"\r\n"`: its number and length, in one pass over the bytes
   (in C this is one word: the number and 4 bits of length; length 0 means there is no
   such line here, 1 that the line is not read to its end yet). A native function of
   several C parts may now borrow its arguments and return its last parts as words of
   its own (that is how `dec_line_at` returns a pair), and `String.to_upper` of a short
   string in the term converts its bytes a whole word at a time. `bend2/base.bend` (+67),
   `bend2/comp.ts` (+149/−11) and the test `tests/base/string_scan.bend`.
18. **`io-cps.patch`** — `IO` compiles to direct continuations. A definition whose type
   ends in `IO(A)` (a function of `R` and a continuation `k`) takes `R` and `k` as its
   parameters, and its body is translated: `IO.bind(m, f)` is `m` run with the
   continuation `x => f(x)`, which is run with `k`; `IO.pure(x)` is `k(x)`; `let` and a
   match pass `R` and `k` into the body and into the arms; any other `IO` value is
   applied to them. A `do` block then calls the effects and definitions it binds
   directly, with a continuation that holds the rest of the block, instead of building
   `IO` values that `IO.bind` applies through closures: a bind took a closure `{f, k}`
   and four `CLO_APPLY` (apply `m`, the continuation of `IO.bind`, `f(x)`, and the
   result to `k`) with a stack frame between them; now it takes one continuation closure
   and one `CLO_APPLY`, when the effect calls it. `main` is not translated: the runtime
   runs it for its `IO` value. The theory does not change: this is a translation in the
   compiler only, and the checker sees the same terms as before. `bend2/comp.ts`
   (+171/−1) and the test `tests/io/io_cps.bend`.

19. **`value-reads.patch`** — a hint that reaches a buffer's bytes, and a copy of a short
   string for free. `Mem.prefetch` of a buffer starts loading its bytes — from the
   position where they start to the end of the buffer, four cache lines at most — and
   not only its first 64 bytes: a value of 100 bytes takes two cache lines.
   `String.take` of a string that lives in the term word, at its whole length, gives
   back the word itself, without building a new string. So BendKV answers a GET with a
   copy of the value made where it lies (section 7.25 of PERFORMANCE.md), and the batch
   hints reach its bytes. `bend2/comp.ts` (+16/−6) and the test
   `tests/base/value_reads.bend`.

20. **`proc.patch`** — the process and the clock. `IO.pid()` is the process's id;
   `IO.cwd()` and `IO.chdir(path)` are the process's working directory and its change
   (for all threads: relative paths then count from the new one); `IO.clock()` is the
   wall clock, seconds since the start of the Unix epoch and the microseconds beyond
   them (`IO.now` is the monotonic clock, for intervals). `IO.die` with an empty message
   ends the process without printing anything. So BendKV starts as `redis-server` does:
   a `dir` line changes the directory at once (and `include`, `logfile` and the
   append-only file after it are looked up from there), `CONFIG GET dir` answers
   `getcwd`, the log has the process's id and the time, and the server writes the line
   "Failed listening on port" to its log and exits silently, as Redis does. Three new
   effects (`bend2/effs/pid.*`, `cwd.*`, `clock.*`), `bend2/base.bend` (+21),
   `bend2/comp.ts` (+16/−2) and the test `tests/io/proc.bend`.

21. **`flat-limit.patch`** — a node instead of a wide record. The compiler lays out a
   non-recursive datatype flat, up to 247 words: a function that takes or returns such a
   record takes and returns each of its words — in registers and stack frames — and the
   widest result and the widest parameter list of a function without a frame are the
   signature of every segment of the program. Now a type wider than 32 words is a node
   of its own (`BOX`), as a recursive one is: in calls, results and frames it is one
   word. So INFO's account (38 words) in BendKV's server state stopped inflating the
   actor's calls to 50–67 words, and the segments' signature to 67 registers (section 3p
   of FINDINGS.md, section 16 of PERFORMANCE.md). BendKV's widest flat record without
   INFO is exactly 32 words, and the server without INFO compiles with the patch to the
   same C, byte for byte. `bend2/comp.ts` (+9/−3) and the test
   `tests/rfc/flat_limit.bend`.

22. **`string-order.patch`** — a native `String.order`. Two strings are compared a chunk
   at a time — byte chunks by `memcmp` over their common length, a cell's character by
   its code, a prefix first — and not a character at a time through `String.cmp`, which
   also gives both strings back (on a packed string each of its steps made a view of the
   rest and dropped it). Two strings of one chunk each take one `memcmp` and a comparison
   of lengths. A byte is a character below 256, and `memcmp` reads bytes as unsigned, so
   the order is the same as the definition's. `String.is_lt`, `is_le`, `is_gt` and
   `is_ge` go through `String.order` too. So BendKV compares the members of a sorted set:
   ZRANK of a member among 100,000 with equal scores costs 9,000 instructions instead of
   76,900 (section 39 of PERFORMANCE.md). `bend2/comp.ts` (+56/−1) and the test
   `tests/base/string_order.bend`.

23. **`writer-hold.patch`** — a socket with no room holds up only its own posts. Before,
   the writer (`TCP.post`) waited for a socket that took no bytes: it repeated `send`,
   polling the socket with `poll` 100 ms at a time without limit, and the head of its
   ring stood still, and with it all the posts behind that socket, the replies and
   closes of other sockets. Once 4,096 posts gathered in the ring, the event loop spun
   waiting for room, and its timers, `accept` and all connections stood still
   (issue #3). Now the writer does not wait for a socket: what the socket did not take, and
   everything posted to it after, it holds in order (`IoHeld`) and moves on to the posts
   of other sockets, and it sends what it holds once the socket has room. Its own
   `epoll` tells it so (`poll` on other systems): while the writer has posts, it looks
   there once a window (200 µs), and while it holds something, it sleeps there rather
   than on a condition variable, and the loop wakes it with a byte in a pipe. A close
   that came after held bytes closes the socket once they are gone. The queue of posts
   is a chain of blocks of 4,096: having filled a block, the loop hangs on the next one
   (the spare — the one the writer emptied last — or a new one), so a post never waits
   for room. The loop sends a post itself only if the writer holds nothing for that
   socket (`held[fd]`), so a socket's bytes go in order. A client that stopped reading
   grows only its own tail, as a Redis client's output buffer does (ordinary clients
   have no limit by default), while the replies to others, the timers and `accept` go on
   as usual. `bend2/comp.ts` (+278/−49) and the test `tests/io/tcp_post_stall.bend`: a
   socket whose reader is silent gets 8 MB and 5,000 short posts, another one 8 MB; the
   timer fires, the second reader gets its bytes and the end, then the first gets its
   own, in order, and the end (without the patch the test hangs).

24. **`file-durable.patch`** — the append-only file on the disk at any size and after a
   crash. `File.truncate` takes its size as a `Nat` (on the C lane, a 64-bit word), not a
   `U32`: a cut to 4 GiB and beyond keeps all the bytes up to that size, not the size
   modulo 2^32 (BendKV's append-only file, with its last entry cut short and a whole part
   of 4 GiB or more, would have lost almost everything in the cut); a size that `off_t`
   cannot hold gives `EOVERFLOW` before the file is touched. `File.sync_dir(path)` syncs
   the directory that holds `path` (an `fsync` of the directory, as Redis's
   `fsyncFileDir`): a file just made keeps its name after a crash, which an `fsync` of
   the file itself does not promise; a system that does not open a directory (`EISDIR`)
   or does not sync it (`EINVAL`, `EBADF`) answers with success, as in Redis. So BendKV,
   at start, syncs the directory of its append-only file before it acknowledges the
   first write. `bend2/base.bend` (+15/−2), `bend2/effs/file_sync.c` (+49/−2),
   `file_sync.js` (+33/−1), the fixed `tests/io/file_raw.bend` (the size of the cut is
   `100n`) and a new test `tests/io/file_durable.bend` with its own effect `file.length`
   (a file's size by `stat`, `.c` and `.js`): a file of ten bytes, cut (sparsely) to
   2^32 + 1, 2^32 and 2^32 − 1 bytes, is exactly that long and starts with the same
   bytes; the file's directory in `/tmp` and the working directory sync, and a directory
   that does not exist gives `ENOENT`.

25. **`tcp-watch.patch`** — waiting on a channel and a socket at once.
   `TCP.watch(sock, chan, msg)` puts `msg` on the channel as soon as the socket has bytes
   or its peer has closed it (as `Chan.send_all` does: at once, and past the channel's
   capacity if need be), and until then waits in the socket's slot, as `recv` waits, so
   while a watch is set, no `recv` may wait on that socket (two waits on one fd). A
   socket that is ready already fires at the next poll. `TCP.unwatch` takes the watch
   back and answers `True` if it had not fired. So a computation waits on its channel
   both for answers and for its socket: a BendKV connection whose client waits (BLPOP
   and the other blocking commands, section 41 of PERFORMANCE.md) waits both for the
   actor's answer and for whatever the client sends, or for it to close the connection.
   A watch woken by a stale edge or readiness flag (a `recv` took the edge's bytes before
   the loop saw it, or read exactly as much as it asked for, and the flag stayed up on an
   empty socket) looks into the socket (`recv` with `MSG_PEEK`) and, if there is nothing
   to read, waits for the next edge: otherwise the computation that woke on its message
   would wait for bytes in `recv`, not seeing the channel, and the actor's answer would
   lie in the channel until the client sent something. `bend2/base.bend` (+16),
   `bend2/effs/chan.c` (+124/−1), `chan.js` (+43) and the test `tests/io/tcp_watch.bend`:
   an accepted socket is watched after the peer has sent bytes (it fires at the next
   poll) and before (it fires when the bytes come); a watch taken back before the bytes
   answers `True` and puts nothing on the channel, one taken back after it fired answers
   `False`, with its message on the channel; a watch set after a `recv` that read exactly
   all the bytes that came fires at no poll (without the check of the socket it fired); a
   close by the peer wakes it too.

26. **`spare-share.patch`** — a shared field of a node kept as a spare. The fifth patch
   reads the fields of a node the function owns straight from the node, keeps the node
   across a call, rereads from it after the call the fields it did not save, and building
   the same constructor does not write the fields that did not change. But a field used
   twice is shared before the call: `term_keep` of a raw (not yet shared) word wraps it
   in a cell with a count of 2 and gives that cell away, while the node kept the raw
   word. After the call the raw word was reread, and its consumer freed the value the
   cell from the first copy still pointed to; a rebuild that skipped the slot left the
   raw word in the node, and the cell was lost. Now the shared word is written back to
   the node's slot (the one the seventh patch's permutation assigns, if it applies). In
   BendKV this crashed the server (`SIGSEGV` on reading the command counters) when a
   database command ran with replies withheld (CLIENT REPLY OFF or SKIP) and with
   clients waiting: the pass over the commands keeps the batch's state (`LRun`, a node)
   across the call `S.run_log`. Nothing of the kind turned up in the rest of BendKV's
   code: all 27 stores the patch added are in the functions of that pass, and the
   instructions per request did not change. `bend2/comp.ts` (+15) and the test
   `tests/rfc/spare_share.bend`: a function keeps a node across a call to which it gives
   the shared field (the call returns it as the tail of a new list), then rereads the
   field for a call that consumes it, and builds the node with the first call's answer;
   without the patch the list's cells are freed, the next list takes them, and the sum
   comes out 206 instead of 46.

27. **`tcp-clients.patch`** — a socket's addresses and fd, killing a socket, and channel
   marks: what CLIENT LIST, INFO and KILL stand on. `TCP.name(sock)` gives back the
   socket with its fd, its peer's address and its own, as Redis prints them
   (`anetFormatAddr`: "ip:port", "[ip]:port" for IPv6, "?:0" if the call failed or the
   family is another); an IPv4 address is written by hand, because `inet_ntop` and
   `snprintf` format through printf, several thousand instructions per connection.
   `TCP.kill(fd)` shuts down an open socket of the runtime both ways
   (`shutdown(fd, SHUT_RDWR)`), so that everything that waits on it (`recv`, a
   `TCP.watch` watch) sees the end at once, and answers `True`; an fd that is not a
   socket of the runtime it leaves alone and answers `False`.
   `Chan.mark(A, chan, word, time)` remembers a word and a time for the channel's row and
   its generation and gives the channel back, and `Chan.marked(A, chan)` reads them:
   `(0, 0)` for a channel with no mark and for a row a new channel has taken since. This
   is a table in the runtime's core, owned by one computation (the actor, which marks
   the reply channels of its clients), with no locks: marking a batch costs one call,
   not an update of a map in Bend. The bodies of `Chan.mark` and `Chan.marked` in Bend
   are stubs (`chan` and `(0, 0n)`): the meaning of these intrinsics is not in their
   bodies, and no law reads them. `bend2/base.bend` (+32), `bend2/comp.ts` (+55: two
   operations, the table of marks, `getpeername`, `getsockname` and `shutdown` in the JS
   FFI), `bend2/effs/tcp_name.c` (+65), `tcp_name.js` (+53), `tcp_kill.c` (+19),
   `tcp_kill.js` (+9) and the test `tests/io/tcp_name.bend`, in C and in JS: for an
   accepted socket the peer is the address of the connected one, and its own is the
   listener's address on its port ("127.0.0.1:port"), and the fds of the two ends
   differ; a channel with no mark reads `0 0`, a marked one its mark, a new channel on a
   closed one's row (a generation up) `0 0`, and the old one's handle its own mark;
   `TCP.kill` of an accepted socket answers `T`, and the connected one reads the end, and
   of an fd that is not a socket, `F`.
28. **`file-rename.patch`** — a file in place of another, and a name taken away: what the
   rewrite of the append-only file (BGREWRITEAOF) stands on. `File.rename(from, to)` puts
   a file in place of another in one step (`rename`): whoever opens `to` finds the old
   file or the new one, whole, never part of either — that is how Redis puts a rewritten
   append-only file in place. `File.unlink(path)` removes a name (`unlink`): the file
   goes once no one holds it open any more — that is how the temporary file of a failed
   rewrite is removed. Both run on a helper thread, as `File.sync` does, and on failure
   give back the errno (`ENOENT` for a name that is not there, `EXDEV` for a move across
   file systems, `EILSEQ` for a NUL in the path). `bend2/base.bend` (+15),
   `bend2/effs/file_rename.c` (+61), `file_rename.js` (+34) and the test
   `tests/io/file_rename.bend`, in C and in JS: a file renamed in place of another
   replaces it, the new name reads its bytes, the old one is gone (`ENOENT`), a handle
   opened before the rename goes on writing to the file under its new name; a rename and
   an unlink of a name that is not there give `ENOENT`.
29. **`heap.patch`** — the heap's account: what `used_memory` and eviction by `maxmemory`
   rest on. `IO.heap()` gives two numbers in bytes: what the heap's live values hold
   (what it has taken from the corpus, the pointer it grows by, less the free chains of
   the allocator's rows in use: the main loop's, the pool's while it is open, and those of
   the other open event loops, their parked generations and the bank's generations) and
   what the heap has taken from the corpus (which it never gives back), as an allocator's
   `allocated` and `active` bytes. The rows of other threads are read as they are: the
   account may be off by the nodes they move meanwhile. The account is a walk of the 32
   classes of a row and of the bank, not of the nodes, so it can be asked for at each
   group of requests. The flag of an open pool (`pool_up`) moves out of `pool_open` into
   the file. Under JS, JavaScriptCore's account after a collection (`bun:jsc`,
   `heapStats`; Bun's `process.memoryUsage` is updated only now and then), and where there
   is none, `process.memoryUsage`. `bend2/base.bend` (+7), `bend2/comp.ts` (±3),
   `bend2/effs/heap.c` (+43), `heap.js` (+28) and the test `tests/io/heap.bend`, on C and
   on JS: the live bytes are no more than those taken, and a list of a hundred thousand
   cells raises them by more than a megabyte (the test does not ask that a dropped list
   gives them back: the JS collector may keep it, finding it on its stack).
30. **`mem-cells.patch`** — words outside the heap: what the table of when each key was
   last used rests on, for LRU and LFU eviction and `OBJECT IDLETIME`/`OBJECT FREQ`.
   `Mem.touch(k, i, v)` puts `v` in the word of the low 20 bits of `i` and gives `k` back,
   `Mem.cell(i)` reads the word (0 for a word never written). There are 2^20 words of 32
   bits, outside the heap, made at the first write (zero pages until they are written).
   The words belong to the one computation that writes and reads them (the actor: when
   each of its keys was last used, a word per key's hash), so they need no locks: marking
   a key costs one store, not a value that would have to be threaded through every call
   (a `Data` type cannot hold an `Array`). Their bodies in Bend are stubs (`k` and `0`),
   as `Chan.mark`'s are: no law reads these words. `bend2/base.bend` (+15),
   `bend2/comp.ts` (+33: two operations and the words in C) and the test
   `tests/run/mem_cells.bend`, on C, on JS and in the interpreter: a word touched reads
   back, one never touched is 0, and an index past 2^20 falls in the word of its low 20
   bits.
31. **`walk-lend.patch`** — walkers of trees borrow what their callers own: what KEYS,
   SCAN, RANDOMKEY and the ranges of a sorted set stand on. The compiler decides once for
   each def whether a parameter is borrowed or owned, and one caller that gave a def a
   value it owned, at its last use in a tail call, made the parameter owned for every
   caller; a walk that owns its tree takes each node it reads (`ctr_own`) and copies each
   one another value shares. A walker that reads is a def that calls itself, takes a tree
   (a datatype with a node of two or more subtrees of its own type) and builds none of
   that datatype's nodes (`walk_reads`). A tail call that gives one a value its caller
   owns, at its last use, is emitted as `r = f(t); r` (`tail_lends`): the caller holds
   the value in its frame and drops it after the call, and the walker borrows it; a held
   call registers a lend there too. A tail call into the caller's own loop (`loop_of`)
   stays a jump, and a def that rebuilds what it is given, or takes a list or a record,
   owns it as before. At the end of a pass, a walker passed a word of a root that ended
   up owned is not made owned (an owned parameter stays owned): in the next pass its
   caller holds what it then owns. `bend2/comp.ts` (+69/−1) and the test
   `tests/compile/walk_lend_tree.bend`, in C, in JS and in the interpreter: a walk of a
   tree that three callers read, through a caller that owns its tree because another
   gives it a tree made for it, borrows it (without the patch it takes each node), and
   gives the same keys; a rebuilt (mirrored) tree and one made for the call give theirs
   too. Bend's tests on the C lane pass with it as they pass without it, test by test
   (739 of 870), and the new one with them.
32. **`string-variant.patch`** — a value that is a string or else something else keeps
   its string as the string itself, with no node: what BendKV's values stand on
   (`KV.Val`: `VStr{s}` or `VColl{c}`), whose string lay in the keyspace behind a node
   of its own. A datatype with one constructor whose one field is a `String`
   (`str_var`) boxes that constructor as the String's own term. A box is how a value
   lies in a field of a generic datatype (a trie's entry) or of a recursive one, and a
   box of such a datatype that is no node or packed word of its other constructors
   (`term_is`: the tag of a node or of a packed word, and the constructor's id) is that
   String: no String is a constructor's node or packed word (a chunk has a constructor
   id of its own, the empty String is `SNil`'s packed word, and blobs, immediates and
   views have other tags). Building the constructor where a box goes, boxing a flat
   value, unboxing a box and matching a box take the String for the box; a match tests
   the other constructors first, so the String's arm is its chain's else. Main's printer
   finds the variant in its descriptor. Only on the C lane of a program whose Strings
   are packed (no GPU calls). `bend2/comp.ts` (+96/−14) and the test
   `tests/rfc/str_variant.bend`, on C and on JS: values of a datatype with a String
   variant, two packed words and a node, with empty, immediate, one-chunk and
   several-chunk strings, in a list, matched owned and lent, unboxed into a record and
   back, and a recursive datatype with a String variant matched as a box, all printed
   by main. Bend's tests on the C lane pass with it as they pass without it, test by
   test (740 of 871), and the new one with them.
33. **`f64-natives.patch`** — C's doubles: `F64`, IEEE 754's binary64 as the two 32-bit
   halves of its bits, the high one first (a term holds no 64-bit word), for what has to
   compute as Redis's C code does, GEO's sines and square roots first among it. Base
   gains `F64.read` (the double that the whole of a String reads as by strtod, a NaN
   when it does not read so: an empty string, a blank first, bytes left over, an
   overflow, an underflow to 0), the four operations, `neg`, `abs`, `sqrt`, `exp`,
   `log`, `log2`, `log10`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `sinh`,
   `cosh`, `tanh`, `pow`, `mod` (fmod), `floor`, `ceil`, `trunc`, the comparisons
   (`is_lt`, `is_le`, `is_eq`, `is_ne`, `is_gt`, `is_ge`), and the conversions
   `U32.to_f64`, `F64.of_u64`, `F64.to_i64` (cut, 2^63 for a NaN and past the range) and
   `F64.rint_i64` (llrint, to the even integer on a tie), each a law of base, which the
   checker knows by its type alone. The C lane runs each as C does (`f64_of` and
   `f64_bits` move a double in and out of its halves; Bend's C already turns off the
   fusing of a product into a sum, `fp contract(off)`): C's own double arithmetic,
   glibc's strtod and the libm the program links, so a program reads, computes and
   rounds as a C program built with the same libm does. The JS lane runs Number and
   Math, and reads what glibc's strtod reads: decimal numbers (Number's correct
   rounding), hex numbers (rounded to the nearest, ties to even, subnormals and
   overflow as glibc rounds them), `inf` and `infinity`. A program that calls none of
   them compiles to the C it compiled to before, but for the runtime's helpers of
   doubles (BendKV before GEO: 56 lines added, the rest byte for byte).
   `bend2/base.bend` (+229),
   `bend2/comp.ts` (+179) and the test `tests/base/f64_ops.bend`, on C and on JS: reads
   and refusals (decimal and hex, ties, subnormals, overflow, underflow), the
   arithmetic, libm, the conversions and the comparisons, each result printed as its
   halves. Bend's tests on the C and JS lanes pass with it as they pass without it, test
   by test (742 of 873 on C, 769 of 897 on JS, where the test of files, which shares its
   temporary file with its C twin, failed once in a parallel run and passes alone), and
   the new one with them.
34. **`heap-asan.patch`** — a heap that AddressSanitizer can check. To ASan alone the
   runtime's heap is one mapping (the corpus), all of it addressable, and a free chain is
   LIFO: a node read or written after its free is no error, and the next allocation of
   its class takes the node over at once, so a bug of the kind the twenty-sixth fixed
   reads another value's words in silence. In a build with `-fsanitize=address` (the
   host only; `__has_feature(address_sanitizer)` or `__SANITIZE_ADDRESS__` defines
   `HEAP_ASAN`) the allocator poisons a free node's words, its chain's link among them
   (it lifts the poison off the link for its own read and write), and lifts the poison
   off a node it hands out; a free first puts the node in a quarantine of its thread and
   class, a ring that lets it go to its chain once `HEAP_HOLD_WORDS` more words of its
   class have come in (2^22 by default, settable with `-D`; a node bigger than that is
   not held, and 0 holds nothing). A stale pointer meanwhile finds poison, and ASan
   reports a use-after-poison where it reads or writes, with the stack. Under ASan the
   heap's account (`IO.heap`) counts the nodes held as live. A build without ASan
   compiles none of it: the patch adds comments and code under `#if`s on ASan's macros
   only, and BendKV's C, preprocessed as `make build` compiles it, is the same byte for
   byte with the patch and without, and so is the server built from it.
   `bend2/comp.ts` (+84). Bend's own test of the twenty-sixth,
   `tests/rfc/spare_share.bend`, built from a compiler without the twenty-sixth: plain,
   it prints a wrong sum (206 for 46); with ASan alone, and with the poison but no
   quarantine, the same, in silence; with this patch, ASan reports the read of a freed
   cell of the list (`ctr_take`, from `sum`). BendKV's `tools/sanitize.sh` builds the
   server this way (FINDINGS.md, section 3zzp).
35. **`clock-us.patch`** — the monotonic clock without an effect: `Clock.us(k)` is `0` in
   Bend, and on the C and JS lanes the microseconds of the host's monotonic clock, mod
   2^32, read once `k` is known (C: `clock_gettime(CLOCK_MONOTONIC)`, which the vDSO
   answers without a system call; JS: `performance.now()`). `k` orders the reading: a
   computation that gives each reading a word of what its last step made reads the clock
   after that step, so a pure loop can time its own steps. An effect (`IO.clock`) costs
   a round trip through the event loop each (about 620 instructions in BendKV's actor)
   and makes the loop one of effects. No law reads the clock: it is `@unsafe`, as
   `Mem.touch` and `Mem.cell` are. `bend2/base.bend` (+11), `bend2/comp.ts` (+14: an
   operation and the C function) and the test `tests/run/clock_us.bend`, on C, on JS and
   in the interpreter: two readings around a walk of a list of 100,000 numbers, the
   second given a word of its sum, are less than a second apart. A program that does
   not call it compiles to the C it compiled to before, but for the twelve lines of the
   C function. BendKV's actor times each window of its group with it (FINDINGS.md,
   section 3zzz).
36. **`unix-v6.patch`** — IPv6 and unix sockets, and systemd's notification, as effects.
   `TCP.listen` takes an IPv6 address (a host with a `:`, read by `inet_pton`), its
   socket IPv6 alone (`IPV6_V6ONLY`, as Redis's `anetV6Only` sets it, so that `0.0.0.0`
   and `::` can both be bound); it took IPv4 alone. `TCP.listen_unix(path, perm)` is a
   listener on a unix socket, made as Redis's `anetUnixServer` makes one: bound, given
   `perm`'s mode when `perm` is not 0, listening and non-blocking; a path that is there
   already fails as `bind` fails (EADDRINUSE), so the program removes a socket an
   earlier run left with `File.unlink` (patch 28), as Redis's `initServer` removes it
   before it listens, and the effect deletes nothing; a path with a NUL, empty, or
   longer than `sun_path` fails (EINVAL). `TCP.accept` takes its connections, and `TCP.name` names either end
   of a unix socket `/unixsocket:0`, as Redis's `anetFdToString` does (it was `?:0`).
   `IO.notify(msg)` sends `msg` as one datagram to the unix socket the environment's
   `NOTIFY_SOCKET` names (a path, or an abstract name after `@`), as systemd's
   `sd_notify` does: `True` when it went out whole, `False` when the variable is not
   set or the send failed. On C and on JS (whose `io_sys` gets `unlink` and `chmod`):
   `bend2/base.bend` (+17), `bend2/comp.ts` (+1), `bend2/effs/` (`tcp_listen.c` and
   `.js` changed, `tcp_name.c` and `.js` changed, `tcp_listen_unix.c` and `.js` and
   `io_notify.c` and `.js` new), and the tests `tests/io/tcp_listen_unix.bend` (a unix
   listener on a path of the process's own, a second one there refused until the path
   is removed, its refusals, a malformed IPv6 address refused, `::1` listened on, on a
   port of the system's choice, or let go where the host has no IPv6; the path removed
   at the end), `tests/io/io_notify.bend` (`False` with no `NOTIFY_SOCKET`, both
   lanes) and `tests/io/io_notify_peer.bend` (the datagram read whole by a socket of
   the test's own, at a path and at an abstract name, then `False` once the variable is
   unset; C alone, through an effect of the test's own, `io_notify_peer.c`; the JS
   lane's datagram was read the same way once, by hand). Bend's 24 tests of TCP and
   UDP pass on C and on JS with it, the new one among them. A program that calls none
   of the new effects compiles to the C it compiled to before, but for the effects'
   code it links. BendKV listens on `bind`'s IPv6 addresses and on `unixsocket`, and
   tells systemd it loads, is ready and stops (FINDINGS.md, section 3zzze).
37. **`signal.patch`** — SIGTERM and SIGINT, as Redis's `sigShutdownHandler` takes
   them, as an effect. `IO.signal(log, done)` puts the handlers in at its first call
   (`sigaction` with `SA_RESTART`; SIGHUP ignored, as Redis's `main` ignores it), and
   with `done` 0 gives the signal taken since the last such call (15, 2, or 0 for none).
   The handler calls async-signal-safe functions alone: it logs the signal at once as
   Redis's `serverLogFromHandler` does (`<pid>:signal-handler (<secs>) Received SIGTERM
   scheduling shutdown...`, appended to `log`, kept from the first call, or on the
   standard output for `""`), and keeps it for the next call. A SIGINT while a shutdown
   is asked for (a signal taken since the last call with `done` not 0) ends the process
   with code 1 after `You insist... exiting now.` and the removal of `temp-<pid>.rdb`
   from the working directory, as Redis's handler does for a second ^C; `done` not 0
   says the shutdown failed (Redis's `cancelShutdown`), gives 0, and leaves a signal
   taken for the next call. The runtime's waits already take `EINTR` (`epoll_wait`,
   `select`, `poll`). The JS lane traps nothing: its loop runs to the end without going
   back to bun's event loop, where a handler of `process.on` would run, and such a
   handler would take SIGTERM's default away; there `IO.signal` gives 0 and the signals
   end the program as before. `bend2/base.bend` (+16), `bend2/effs/io_signal.c` and
   `.js` (new), and the tests `tests/io/io_signal.bend` (a SIGTERM the program sends
   itself given once, then 0; one left by a call with `done` 1 for the next; a SIGINT
   after it given rather than fatal; the handler's lines in the log),
   `tests/io/io_signal_insist.bend` (the second SIGINT ends the program with code 1),
   both in C alone through an effect of the test's own (`io_signal_raise.c`, `raise`),
   and `tests/io/io_signal_none.bend` (0 on both lanes with no signal). Bend's lane
   tests give the same results on C and JS with it as without it. BendKV shuts down
   on SIGTERM and SIGINT as Redis does, with `shutdown-on-sigterm` and
   `shutdown-on-sigint` (FINDINGS.md, section 3zzzf).
38. **`file-mkdir.patch`** — a directory made and removed, as effects.
   `File.mkdir(path, mode)` makes the directory at `path` (`mkdir`, its mode `mode`
   less the process's umask), as Redis's `dirCreateIfMissing` makes the append-only
   file's directory: a name that is there already, a directory or not, fails
   (EEXIST), and so does a path whose parent is not there (ENOENT).
   `File.rmdir(path)` removes the directory at `path` (`rmdir`): one that holds a name
   fails (ENOTEMPTY). Both run on a helper thread, as `File.rename` and `File.unlink`
   (patch 28) do, and a path with a NUL fails (EILSEQ). On C and on JS:
   `bend2/base.bend` (+16), `bend2/effs/file_mkdir.c` and `.js` (new), and the test
   `tests/io/file_mkdir.bend` (a directory made, a file made inside it read back, a
   directory made again and one at a file's name refused with EEXIST, one whose parent
   is not there with ENOENT, a directory that holds a file not removed, then the file
   and the empty directory removed, and the directory removed again refused with
   ENOENT; on both lanes). A program that calls neither compiles to the C it compiled
   to before. BendKV makes `appenddirname` at a start with `appendonly yes` where it is
   not there, as Redis 7 does (FINDINGS.md, section 3zzzzzf).
39. **`tcp-held.patch`** — what a socket's writer holds, as an effect. `TCP.held(sock)`
   gives the bytes posted to `sock` (`TCP.post`) that its loop's writer holds, the
   socket having had no room for them: what its peer has not read past the socket's
   buffers, as a Redis client's output buffer holds it. The writer counts them as it
   holds a post and as it sends what it held (a count for each fd beside the writer's
   `held`, which the loop reads with an atomic load); 0 when it holds none of `sock`'s,
   before the loop has a writer, and on JS, whose post waits for its bytes to go.
   `bend2/base.bend` (+9), `bend2/comp.ts` (+35/−3), `bend2/effs/tcp_held.c` and `.js`
   (new), and the test `tests/io/tcp_held.bend` (nothing held before a post; a post of
   1 MiB to a socket whose peer reads nothing, its send buffer made small by an effect
   of the test's own, `tcp_held_buf.c`, leaves the writer holding part of it, no more
   than was posted; nothing once the peer has read it all; on C alone). The writer
   counts in every program that calls `TCP.post`, on the path a post takes only when
   its socket has no room. BendKV closes a client that must authenticate whose replies
   would pass 16 KB with what its socket holds, as Redis 7.2.16 does (FINDINGS.md,
   section 3zzzzze).

What the patches do and what they give is worked through in
[../PERFORMANCE.md](../docs/PERFORMANCE.md), sections 3–6, 7.7–7.17, 7.23–7.25, 16, 39,
40, 41, 44, 47, 48, 51 and 56, and what each costs in tokens and what it gave, in section 12.
There, and in the sections before 14, the patches are numbered the old way: the sixteenth was
`effect-pairs.patch` (`Chan.call` and `TCP.post_recv_raw`, one step of the event loop
each where there had been two), and their 17–20 are today's 16–19. The sixteenth, and
`TCP.post_list` of the eleventh, were taken out together with the paths of BendKV they
served (section 14); they remain in the branch
[`archive/shards`](https://github.com/littleBro/BendKV/tree/archive/shards). With the
patches `comp.ts` takes 104,155 `ttok` tokens against the Bend repository's cap of 64
thousand (the original takes 62,940): to upstream them, they will have to be made
smaller.

From the `bendkv/` directory:

```bash
git clone https://github.com/bendlang/bend ../bend-patched
sh bend-patches/apply.sh ../bend-patched   # the bendkv-patches branch from 1cce499 with thirty-nine patches
bun ../bend-patched/bend2/main.ts server.bend -o build/bendkv
```

Patches 1–5, 7 and 8 switch on by themselves if the program has no GPU calls `!`;
programs with `!` compile as before. The sixth always acts on the CPU heap, and never on
the GPU. The ninth works only where a program calls `Mem.prefetch`, the tenth where it
calls `IO.spawn_on`, `Chan.send_all` or `TCP.post` (the buffers of `recv` and
`send_raw`, everywhere). The eleventh changes every program's event loop on Linux, the
twelfth and thirteenth only add effects. The fourteenth speeds up `String.code_at`
everywhere, the fifteenth and sixteenth act where a program calls `TCP.post`, the
seventeenth adds string functions and speeds up `String.to_upper` of short strings, the
eighteenth changes how every program's `IO` compiles (except `main`), and the nineteenth
speeds up `Mem.prefetch` of buffers and `String.take` of short strings everywhere. The
twentieth only adds effects and a silent `IO.die`, the twenty-first changes the layout
of types wider than 32 words in every program, the twenty-second speeds up
`String.order` (and the string comparisons through it) everywhere, the twenty-third acts
where a program calls `TCP.post`, the twenty-fourth changes the type of the size in
`File.truncate` (`Nat` instead of `U32`) and adds the effect `File.sync_dir`, the
twenty-fifth only adds the effects `TCP.watch` and `TCP.unwatch`, and the twenty-sixth
fixes the fifth where the fifth acts, the twenty-seventh only adds the effects
`TCP.name` and `TCP.kill` and the channel marks `Chan.mark` and `Chan.marked`, the
twenty-eighth the effects `File.rename` and `File.unlink`, the twenty-ninth the effect
`IO.heap`, the thirtieth the words `Mem.touch` and `Mem.cell`, the thirty-first
changes how a tail call gives a tree its caller owns to a walker that reads it, in
every program, the thirty-second boxes a datatype's String variant as the String
itself, in a program without GPU calls, the thirty-third only adds natives (`F64`), and
the thirty-fourth changes only a build with AddressSanitizer, the thirty-fifth
only adds a native (`Clock.us`), and the thirty-sixth changes `TCP.listen` (IPv6) and
`TCP.name` (unix sockets) and adds the effects `TCP.listen_unix` and `IO.notify`, and
the thirty-seventh only adds the effect `IO.signal`, the thirty-eighth only adds
the effects `File.mkdir` and `File.rmdir`, and the thirty-ninth adds the effect
`TCP.held` and has the writer of a program that calls `TCP.post` count what it holds.
The theory does not change:
`String` in the proofs is still a list, and `IO` a function of `R` and `k`.

## How to reproduce the measurements

- `tools/count_allocs.py x.c x_counted.c` adds to a C file made by `bend x.bend -o x.c`
  counters of allocations and of reference-count operations: `kill -USR1` prints them,
  `kill -USR2` resets them, and with `CNT_ATEXIT=1` the program prints them on exit.
- `tools/c_lane_tests.py <bend clone> <work dir> [threads]` — a local counterpart of
  `gates/test.ts` for the lanes that build: C, and with `LANES=c,js` JS too. It builds
  each runnable test, runs it with a timeout of 5 s and checks its output against the
  `#|` lines. To compare two clones (with a patch and without), compare their
  `summary.txt`.
- A time profile without the processor's counters: `../tools/sprof.c` (sampling on a
  timer through `LD_PRELOAD`), `../tools/sprof_run.sh` and `../tools/sprof_report.py`.
- The server's benchmarks: `make bench` in `bendkv/` (BendKV against Redis). To run the
  Bend runtime's benchmarks on the CPU, remove `!` from `bench/runtime/*/main.bend`.
  Compare interleaved runs: in runs one after another, the machine's drift gives ±10%.
