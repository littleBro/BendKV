# BendKV

A Redis-compatible key-value server written in [Bend2](https://github.com/bendlang/bend),
whose core is formally verified: the command semantics, the hash trie behind them, the
append-only file, the databases, the connection state and the configuration are proved
against 68 laws,
checked by Bend
and rechecked by the BendTT kernel, whose soundness is proved in Lean.

BendKV speaks RESP2 and RESP3 (HELLO 3), so `redis-cli`, `redis-benchmark`,
`memtier_benchmark` and clients that speak RESP3 by default (go-redis v9, Lettuce) work
with it. Under pipelined load it serves GET at 1.6×, SET at 1.8× and INCR at 1.45× the
throughput of Redis 7.0.15 on the same machine, with half its memory for small values.

> **Status: research prototype.** BendKV implements a subset of Redis (strings, hashes,
> lists, sets, sorted sets, HyperLogLogs, GEO and their times to live, DUMP and RESTORE, the
> blocking commands, transactions, pub/sub and keyspace notifications, the keyspace, several databases,
> connection commands, CLIENT LIST, INFO, KILL, PAUSE and UNPAUSE, MONITOR, the slow log
> and the latency monitor, ACL users, the server's administrative commands, an append-only file and
> its rewrite, maxmemory and its eviction, RESP3). The goal now is a
> drop-in replacement for a single Redis node, measured by Redis's own test suite: of the
> 1,677 tests Redis 7.0.15 passes against a server it did not start, BendKV passes 1,348,
> and 1,306 of the 1,365 in what it implements
> ([docs/COMPATIBILITY.md](docs/COMPATIBILITY.md)). Do not use it for data you cannot
> lose.

BendKV is an independent project. It is not affiliated with Higher Order Company or the
Bend project, nor with Redis Ltd. Redis is a trademark of Redis Ltd.

## Why

Most of a key-value server's semantics is a pure function
`exec(command, db) -> (reply, db')`, which is exactly what a proof assistant handles
well. BendKV asks how far one can get writing a real, fast server in a language where
the code that runs is the code that is proved, without a separate model and a
refinement proof. The answer so far: the verified core is not what makes it slow;
the data representation of the runtime was, and most of the work went into fixing it
(the patches to the Bend compiler in [`bend-patches/`](bend-patches/), counted in
[In numbers](#in-numbers): most speed up its data representation and its runtime, and
the others add what a server needs from the system, from the process's directory, id
and clock to the files it cuts, the heap's account and C's doubles, and one lets
AddressSanitizer check the heap).

## What is proved

The laws are stated by hand in [`proof/LAWS.bend`](proof/LAWS.bend) and proved in
[`proof/PROOF.bend`](proof/PROOF.bend). A database is a record: the trie, whose
entries hold each key's value (a string, or a collection) and the time it expires at; how many keys it holds (which
DBSIZE answers) and how many of them have a time; and the time its batch runs at. The
server holds several (16, as Redis), with the one a connection selected in focus while
its batch runs. A key whose time has passed is there for no command. The laws about what keys read and what
commands answer are stated of the server's commands and proved through a specification,
the commands on the trie alone at a time ([`proof/SPEC.bend`](proof/SPEC.bend)), which a
bridge in the proofs ties to the server's commands (DBSIZE answers the count); the
counts are proved to be the trie's own.

| group | laws | what they say |
|---|---:|---|
| Map | 11 | the trie is a finite map from keys to a value and a time: after any sequence of writes (a value with a time, a value with its time kept, a time alone, a deletion), every key holds what was last written to it, with no stale, lost or foreign entries; a read sees a key only until its time |
| Keys | 2 | key comparison is exactly string equality, down to the bits of `U32` |
| Commands | 24 | no command changes a key it does not write, neither its value nor its time (`frame`); reads keep the database (the commands of hashes, lists, sets and sorted sets, PFADD, PFCOUNT of one key and PFDEBUG are reads and updates of their key, LMOVE, LMPOP, SMOVE, ZMPOP and the operations of several sets and sorted sets of their keys, so these laws and those below hold of them); a key whose time has passed is there for no command, and the sweep of expired keys deletes no key that is there; GET, DEL, APPEND, SETRANGE, SETNX, INCR, GETDEL, PERSIST, PTTL, SET with KEEPTTL, RENAME, MSETNX and BITOP behave as specified, on keys of the types they take (SET, SETNX, the times and the key commands take any), a key they add counted; a pipelined batch runs exactly as its commands in order; the cache hints before a batch change nothing |
| Commuting | 5 | commands on different keys commute: replies and key contents are the same in either order, and adjacent independent commands in a batch can be swapped, when neither writes a key the other's writes depend on (RENAME moves a value from one key to another, MSETNX sets its keys only when none is there, BITOP sets its destination from its sources, LMOVE pushes onto its destination what it pops from its source, LMPOP pops from the first of its keys that is there, a STORE of a set operation sets its destination to what its sources make, SMOVE moves a member from its source to its destination, a STORE of a sorted-set operation or of a range sets its destination to what its sources or its source make, ZMPOP pops from the first of its keys that is there); SORT, whose patterns may read any key, swaps with reads alone |
| Persistence | 10 | logging changes no reply; the file reads back as written, times included; after any history, each batch at its own time, on any of the databases, the server restores exactly the databases it held; a file cut by a crash at any byte restores the databases after some prefix of its acts in which every transaction is whole, never a partial act or transaction; the start's replay, which first checks that each entry replays as written, is that replay whenever the check refuses none; the start, which reads its file a window at a time, makes of any windows what it makes of the whole file |
| Databases | 6 | SELECT changes no database and focuses the one it names; SWAPDB puts each of two databases in the other's place; FLUSHALL empties them all; MOVE takes a key's entry, its value and its time, out of the selected database and sets it in the other; COPY sets a key's entry at another key, in the selected database or another, when that key is not there or REPLACE is given |
| Key count | 2 | after any history, the counts every database keeps are its trie's own, how many keys it holds and how many of them have a time, and its trie holds each key once; so DBSIZE answers the number of keys in its trie |
| Sessions | 5 | however the server dispatches a batch, it runs as its commands in order; a batch changes the databases and the log as its executed commands do; a client that has not authenticated against a password cannot read or change any key |
| Configuration | 3 | a CONFIG SET that fails changes nothing; one that succeeds makes the new requirepass the password; after a CONFIG SET of a parameter, CONFIG GET finds the value its check gave |

`make check` takes about 15 s; `make verdict` rechecks every proof in the BendTT kernel
in about a minute.

**Trust boundary.** The proofs cover `src/map.bend`, `src/redis.bend`, `src/batch.bend`,
`src/aof.bend`, `src/session.bend` and `src/config.bend`, the files the laws import
([In numbers](#in-numbers)). Trusted without proof: the Bend compiler and its C runtime
(with the patches); the RESP parser and the network shell (`src/resp.bend`,
`src/server.bend`), the start (`src/startup.bend`), INFO and COMMAND (`src/info.bend`,
`src/command.bend`), the doubles in software (`src/float.bend`, tested against glibc as
well), what HyperLogLogs, GEO and LOLWUT compute (`src/hll.bend`, `src/geo.bend`,
`src/lolwut.bend`) and DUMP's payloads (`src/rdb.bend`), all tested against
`redis-server`; clang, libc and the OS. This is not
end-to-end verification in the sense of CompCert or seL4; see
[docs/FINDINGS.md](docs/FINDINGS.md), section 1.

The BendTT kernel is proved sound in Lean, but the translation from Bend to the kernel
is not, and since Bend 2's release several bugs were reported in which `--verdict`
passes while the kernel checked something other than the source says
([#1186](https://github.com/bendlang/bend/issues/1186),
[#1236](https://github.com/bendlang/bend/issues/1236),
[#1247](https://github.com/bendlang/bend/issues/1247), open as of October 2026). None
of their triggers occurs in BendKV's proofs (no specialized parameters over empty types,
no law helpers named like Base constructors, no colon/dot name clashes), but the
translation stays in the trusted base.

## Commands

- **Strings and keys:** GET, SET, SETNX, GETSET, DEL, UNLINK, EXISTS, INCR, DECR, INCRBY,
  DECRBY, APPEND, STRLEN, MGET, MSET, MSETNX, RENAME, RENAMENX (the key's time moves with
  it), COPY (DB and REPLACE; the key's time is copied with it), DBSIZE, KEYS
  (Redis's patterns: `*`, `?`, `[...]` classes, `\` escapes, matched as Redis's
  `stringmatchlen` matches them, with its cut-offs, which keep a pattern's cost polynomial,
  and its limit of 1000 nested stars, past which nothing matches), TYPE, TOUCH, SCAN (MATCH,
  COUNT, TYPE, with Redis's guarantee: a key there for a whole iteration is found, however
  the database changes meanwhile) and RANDOMKEY (picked as Redis picks one). OBJECT
  (ENCODING, REFCOUNT, IDLETIME, FREQ, HELP): ENCODING and REFCOUNT answer from the value,
  since BendKV keeps no encodings, ENCODING as Redis encodes a value set whole (where Redis
  answers `raw` for one made by APPEND, SETRANGE or SETBIT), REFCOUNT by Redis's shared
  integers under the current eviction policy; IDLETIME and FREQ from when the key was last
  used (Memory, below), each refused under the policy Redis refuses it under. INCR and
  its kin add Redis's long longs, and refuse a sum past one as Redis does.
- **Floats:** INCRBYFLOAT and HINCRBYFLOAT, as Redis 7.0.15 computes them on x86-64: the
  value and the increment read as glibc's strtold reads them, added as an x87 long double
  adds them, and the sum written as `"%.17Lf"` writes it, the zeros that end its fraction
  taken out; a sum that is not finite refused. `src/float.bend` does C's double and
  x87's long double in software (Bend has a 32-bit float alone): reading as strtod and
  strtold, writing as `"%.17g"` and `"%.17Lf"`, adding and multiplying, each rounded to
  the nearest number as the FPU rounds, and checked against glibc on random numbers in
  `make test`. INCRBYFLOAT is logged as the SET of its sum with KEEPTTL and HINCRBYFLOAT
  as the HSET of its field, as Redis propagates them.
- **Ranges and bits:** GETRANGE (and SUBSTR), SETRANGE, GETBIT, SETBIT, BITCOUNT and
  BITPOS (with BYTE and BIT ranges), their numbers read as Redis reads them and their
  errors where Redis gives them; a value grows to 512MB at most (proto-max-bulk-len at
  its default). SETRANGE and SETBIT are logged as a SETRANGE of the bytes they wrote, not
  the whole value. BITOP (AND, OR, XOR, NOT; logged as the SET of its value) and LCS (LEN,
  IDX, MINMATCHLEN, WITHMATCHLEN, its table bounded by proto-max-bulk-len as in Redis, and
  slow: about twenty times Redis's time). BITFIELD and BITFIELD_RO: fields of up to 64
  bits, signed or not, at a bit offset or `#k`, with GET, SET, INCRBY and OVERFLOW WRAP,
  SAT or FAIL, in C's wrapping arithmetic as Redis's; logged as the SETRANGE of the bytes
  its writes reach. A field across the 2^32-th bit, for which Redis grows a value past
  512MB, is refused with SETRANGE's error.
- **Hashes:** HSET, HMSET, HSETNX, HGET, HMGET, HDEL, HLEN, HSTRLEN, HEXISTS, HKEYS,
  HVALS, HGETALL, HINCRBY, HINCRBYFLOAT, HSCAN (MATCH, COUNT) and HRANDFIELD (a count, repeating when
  negative, WITHVALUES; picked with the server's random numbers), their arguments and
  errors read as Redis reads them. A hash keeps its fields in the order they came while it
  is small (at most 512 fields and values of at most 64 bytes, Redis's listpack defaults)
  and in a trie of its own past that, for good, as Redis turns a listpack into a
  hashtable: a small hash scans whole with cursor 0, a large one bucket by bucket. OBJECT
  ENCODING answers `listpack` or `hashtable` as Redis would under the current
  parameters; every command of strings answers WRONGTYPE for a hash, and every command of
  hashes for a string. MEMORY USAGE (SAMPLES) estimates a key's bytes. A hash write is
  logged as the HSET of the pairs it set or the HDEL of the fields it took (HINCRBY and
  HINCRBYFLOAT as the HSET of the sum); a hash made where a key whose time had passed still lay is logged as
  one EVAL of a fixed script that deletes the key and sets the pairs, which Redis runs as
  it loads the file and BendKV reads back (Redis itself logs a MULTI with a DEL and the
  HSET, two entries a crash could part). BendKV runs no other Lua but the like scripts of
  lists, sets and sorted sets, below.
- **Lists:** LPUSH, RPUSH, LPUSHX, RPUSHX, LPOP and RPOP (with a count), LLEN, LINDEX,
  LRANGE, LSET, LINSERT, LREM, LTRIM, LPOS (RANK, COUNT, MAXLEN, read as Redis 7.0.15
  reads them, a RANK of LLONG_MIN included), LMOVE, RPOPLPUSH and LMPOP, their arguments
  and errors read where and as Redis reads them (a count or an index may be any long
  long). A list is a deque of two stacks of pieces of up to 2,048 bytes, each its
  elements one after another, as Redis's quicklist is a chain of listpacks (a small
  element takes its length's byte more than its bytes), so a push or a pop at either end
  costs O(1) amortized, and LINDEX, LSET and LRANGE go from the nearer end a piece at a
  time. LPOS, LINSERT and LREM compare the elements where they lie, a piece at a time,
  stop at the matches they want, and write anew only the pieces they change; a key never
  holds an empty list. OBJECT ENCODING answers `quicklist`, as Redis 7.0 does for every list, and
  MEMORY USAGE estimates its bytes. A list write is logged as the write itself (LMPOP as
  the LPOP or RPOP of the key it took from, with its count; a pop of the last elements as
  the DEL of the key); a list made where a key whose time had passed still lay is logged
  as the EVAL of the hash's script with the pushes, and a move onto such a key as one
  EVAL of a fixed script that deletes the destination and runs the LMOVE, which Redis
  runs as it loads the file and BendKV reads back. The blocking BLPOP, BRPOP, BLMOVE,
  BRPOPLPUSH and BLMPOP are below (clients that wait).
- **Sets:** SADD, SREM, SCARD, SISMEMBER, SMISMEMBER, SMEMBERS, SSCAN (MATCH, COUNT),
  SPOP and SRANDMEMBER (with a count, repeating when negative; picked with the server's
  random numbers in Redis's ways of picking), SMOVE, SINTER, SUNION, SDIFF, SINTERSTORE,
  SUNIONSTORE, SDIFFSTORE and SINTERCARD (LIMIT), their arguments and errors read where
  and as Redis reads them. A set is an intset while its members are canonical 64-bit
  integers, at most 512 of them, and a hashtable past that, for good, as Redis turns an
  intset into a hashtable: an intset answers its members in numeric order and scans
  whole with cursor 0, as Redis's does. A hashtable keeps its members in one string, in
  the order they came, while it holds at most 128 of at most 64 bytes (Redis 7.2's
  listpack limits), and in a trie of its own past that, for good. OBJECT ENCODING
  answers `intset` or `hashtable`, MEMORY USAGE estimates a set's bytes, and a key never
  holds an empty set.
  A set write is logged as the SADD or SREM it makes (SPOP as the SREM of the members it
  took, or the DEL of the key when it took the last; a STORE as the SADD of the members
  it made, or the DEL of its destination when there are none); a set made where a key
  held an entry (a STORE's destination, a key whose time had passed) is logged as the
  EVAL of the hash's script with the SADD, and SMOVE onto a key whose time had passed as
  one EVAL of a third fixed script that deletes the destination and runs the SMOVE.
- **Sorted sets:** ZADD (NX, XX, GT, LT, CH, INCR), ZINCRBY, ZREM, ZCARD, ZSCORE, ZMSCORE,
  ZRANK, ZREVRANK, ZCOUNT, ZLEXCOUNT, ZRANGE (BYSCORE, BYLEX, REV, LIMIT, WITHSCORES),
  ZRANGEBYSCORE, ZREVRANGEBYSCORE, ZRANGEBYLEX, ZREVRANGEBYLEX, ZREVRANGE,
  ZREMRANGEBYRANK, ZREMRANGEBYSCORE, ZREMRANGEBYLEX, ZPOPMIN and ZPOPMAX (with a count),
  ZMPOP, ZRANDMEMBER (a count, repeating when negative, WITHSCORES; picked with the
  server's random numbers), ZSCAN, ZUNION, ZINTER, ZDIFF, their STOREs, ZINTERCARD
  (LIMIT) and ZRANGESTORE, their arguments and errors read where and as Redis reads them.
  Scores are doubles, read, written, compared and added as C's are (`src/float.bend`),
  with Redis's rules for infinities. A sorted set keeps its elements in Redis's order, by
  score and then member: while it is small (at most 128 elements, members of at most 64
  bytes, Redis's listpack defaults) in one string, each element its member and its
  score's 8 bytes, as a listpack keeps them in one allocation (in a weight-balanced tree
  once that string would pass one buffer of the runtime, 2,048 bytes), and past the
  limits in the tree with a trie of its members, for good, as Redis turns a listpack
  into a skiplist: a small one answers as Redis's listpack does
  (no `-0` score, a range by member walked from its first element, ZSCAN whole with
  cursor 0, its integer scores as digits). OBJECT ENCODING answers `listpack` or
  `skiplist`, MEMORY USAGE estimates a sorted set's bytes, and a key never holds an
  empty one. A sorted-set write is logged as the command the client sent (ZINCRBY as
  ZADD INCR, ZADD's options in one order, ZMPOP as the ZPOPMIN or ZPOPMAX of the key it
  took from; the removal of the last elements as a DEL); a sorted set made where a key
  held an entry (a STORE's destination, a key whose time had passed) is logged as one
  EVAL of a fourth fixed script that deletes the key and runs the ZADD of its elements. A
  STORE of more than 128 elements loses the sign of a `-0` score where Redis keeps it.
  The blocking BZPOPMIN, BZPOPMAX and BZMPOP are below (clients that wait).
- **Sorting:** SORT and SORT_RO (BY, LIMIT, GET, ASC, DESC, ALPHA and, for SORT, STORE),
  their options read in order and their errors given where and as Redis gives them, all
  before WRONGTYPE. A list, a set or a sorted set is sorted, a key not there as an empty
  list: its elements read as doubles, as Redis reads them with strtod (blanks first,
  nothing after, no overflow, no NaN), ties broken by their bytes, or with ALPHA compared
  by their bytes up to the first NUL, as strcoll compares in the C locale (all of them
  with STORE, as Redis then compares). BY with a pattern weighs each element by the string
  at the key its first `*` names, or a hash's field after `->`, a weight not there
  counting as 0 (or first, with ALPHA); BY without a `*` leaves a list or a sorted set in
  its order (reversed by DESC) and a set in its own, which a STORE sorts ALPHA, as Redis
  sorts it. GET answers the element (`#`) or what a pattern names, a null where nothing is
  (an empty string in a STORE). The sort is a merge sort, stable as glibc's qsort, which
  Redis calls, and takes two to six times Redis's instructions for 1,000 elements (section
  57 of [docs/PERFORMANCE.md](docs/PERFORMANCE.md)). STORE writes the result over its
  destination as a new list (the `sortstore` event), or deletes it when there is nothing
  (`del`), and answers the count; it is logged as the list it wrote (the RPUSH of its
  elements, or the EVAL of the lists' script onto a key there), and a file of Redis's,
  which holds the SORT, is read by running it again. Where BendKV differs: a set kept as a
  hashtable comes in BendKV's order where Redis's is its hashtable's (BY a constant
  without STORE, and elements whose weights tie under ALPHA by a pattern); a sort BY a
  pattern under a LIMIT that does not take all leaves elements whose weights tie in a
  stable sort's order, where Redis's pqsort may not; Redis compares ALPHA in the locale it
  started in; Redis reads a range error from errno without clearing it, so that a SORT
  after one that met a weight too large or too small fails on weights that are not
  integers, until a command clears errno; and SORT of a small sorted set leaves it a
  listpack, where Redis makes it a skiplist for good.
- **HyperLogLogs:** PFADD, PFCOUNT, PFMERGE, PFDEBUG (GETREG, DECODE, ENCODING, TODENSE)
  and PFSELFTEST, as Redis 7.0.15's `hyperloglog.c` runs them, on the bytes of a string:
  Redis's header and registers, dense or sparse, and every value written byte for byte as
  Redis writes it (the sparse opcodes split and merged as `hllSparseSet` does it, the turn
  to dense past 3,000 bytes or for a register past 32, PFMERGE's sparse result, the count
  kept in the header and made stale by a change). The count is Ertl's estimator as Redis
  takes it, on doubles in software. A string that is not a HyperLogLog answers Redis's
  WRONGTYPE, a corrupt sparse one INVALIDOBJ, as Redis 7.0.15 with the fix of
  CVE-2025-32023 judges it (as Ubuntu ships it). PFADD, PFCOUNT of one key and PFDEBUG
  are logged as the changes they make (a SET, a SET with KEEPTTL, the SETRANGE of the
  count), PFMERGE as the SET of its destination; a file of Redis's, which holds the PF
  commands, is read by running them. PFADD takes four to six times Redis's instructions,
  a PFCOUNT that counts 13 to 18 times (2.6 times on two dense HyperLogLogs), PFMERGE 1.2
  to 2.4 times (section 59 of [docs/PERFORMANCE.md](docs/PERFORMANCE.md)). Where BendKV
  differs: `hll-sparse-max-bytes` is not read (3,000); PFSELFTEST checks fewer cases; the
  byte past a sparse string's end, which an XZERO cut at its end reads, is 0 as each
  command starts, where Redis keeps what a set wrote there; a PFADD that a corrupt value
  stops keeps its change with an event and a log, where Redis keeps it silently; and
  OBJECT ENCODING answers `embstr` for a HyperLogLog of up to 44 bytes, where Redis's is
  `raw`.
- **GEO:** GEOADD, GEOPOS, GEOHASH, GEODIST, GEORADIUS and GEORADIUSBYMEMBER with their
  `_RO` forms, GEOSEARCH and GEOSEARCHSTORE, as Redis 7.0.15's `geo.c` runs them: a
  position is a member of a sorted set whose score is its 52-bit geohash, GEOADD the ZADD
  of its scores (logged as that ZADD), and a search reads the cells Redis reads, keeps
  the points within its circle or box by their haversine distances, and sorts them as
  glibc's qsort does, or as Redis's pqsort does, step by step, when COUNT keeps fewer
  than it found, so that points at the same distance come in Redis's order; each point
  answers with Redis's text (a distance's four decimals, a coordinate's `%.17Lf`). The
  doubles are C's: Bend's base runs them natively (patch 33), on the C library's libm,
  so that a distance is the double Redis computes with the same libm. The options, their
  errors and the order they come in are `georadiusGeneric`'s; STORE, STOREDIST and
  GEOSEARCHSTORE write their destination as a sorted set, or delete it when they find
  nothing, with Redis's keyspace events. A search takes 2.5 to 4 times Redis's time, 7
  times with WITHCOORD (a coordinate is written by the float library in software) and 13
  times with COUNT's partial sort (PERFORMANCE.md, section 60).
- **DUMP and RESTORE:** a value's payload as Redis 7.0.15 writes it with `rdbcompression
  no` (the value as RDB encodes it, a listpack, an intset or a quicklist of listpacks
  where Redis keeps one, then version 10 of the format and the CRC64), so that a payload
  is Redis's byte for byte where both hold the value alike; RESTORE reads every type
  Redis 7.0.15 reads but modules' (LZF's strings, ziplists, zipmaps, quicklists of
  ziplists and streams too), checks a payload as deep as Redis does with
  `sanitize-dump-payload yes`, and takes REPLACE, ABSTTL, IDLETIME and FREQ, with
  Redis's errors in Redis's order and its keyspace events. The append-only file logs a
  RESTORE with REPLACE and ABSTTL. Where BendKV differs: DUMP writes no LZF; a hashtable's
  pairs or members come in BendKV's order (its trie's, or a small set's own, the order its
  members came in); RESTORE checks every payload in depth, as Redis does only with
  `sanitize-dump-payload yes`. A value of 100,000 elements takes 3 to 38 times Redis's
  time to dump or restore, less than the commands that make it (section 3zzu of
  [docs/FINDINGS.md](docs/FINDINGS.md), section 62 of
  [docs/PERFORMANCE.md](docs/PERFORMANCE.md)).
- **Streams:** a stream as Redis 7.0.15 keeps one, its entries in nodes that are
  Redis's listpacks byte for byte, its groups with their pending entries and their
  consumers, from RESTORE and the RDB file (types 19 and 15, what 15 lacks estimated as
  Redis estimates it); DUMP and SAVE write it as Redis does, a stream Redis made
  byte for byte; TYPE, OBJECT ENCODING, SCAN's TYPE, COPY, RENAME, the times to live
  and MEMORY USAGE take it, and the other kinds' commands answer WRONGTYPE. The
  commands that read a stream answer as Redis's: XLEN; XRANGE and XREVRANGE, their IDs
  read as Redis reads them (`-`, `+`, an ID without its sequence, `(` for an end left
  out), with COUNT; XREAD of one key or several, with COUNT and `$`, and with BLOCK when
  an entry is there to serve; XINFO STREAM (FULL, with COUNT), GROUPS, CONSUMERS and
  HELP, their lag, entries read and count of the radix tree's nodes as Redis counts
  them; XPENDING, its summary and its entries (IDLE, a consumer). XADD, XTRIM, XDEL and
  XSETID write one as Redis does, node for node and byte for byte: XADD with an ID,
  `<ms>-*` or `*`, NOMKSTREAM, MAXLEN and MINID with `=` or `~` and LIMIT, XSETID with
  ENTRIESADDED and MAXDELETEDID, their errors in Redis's order and their keyspace
  events; the append-only file logs each as the write it made (XADD with the ID it
  added, a trim by `~` as the exact trim it made), which Redis loads too. The commands
  of groups (XGROUP, XREADGROUP, XACK, XCLAIM, XAUTOCLAIM) are not there yet. Where
  BendKV differs: XREAD with BLOCK answers an error where Redis would make its client
  wait (in MULTI, where Redis does not wait, it answers a null array, as Redis does);
  RESTORE and the start refuse payloads Redis takes but never writes (a node with no
  entry, or whose counts or master entry are not its
  entries', live entries out of order, a pending entry no consumer holds or two hold,
  a time past 2^47, ...); the rewrite of the append-only file writes a stream as a
  RESTORE of its payload, where Redis writes XADD, XSETID, XGROUP and XCLAIM; MEMORY
  USAGE estimates otherwise; a node is full at Redis's defaults, 4096 bytes or 100
  entries, whatever `stream-node-max-bytes` and `stream-node-max-entries` say; an XADD
  whose fields and values pass 1 GiB leaves no key where there was none, where Redis
  leaves an empty stream; a trim by `~` takes out the nodes Redis's takes out but in
  two rare cases, where the stream is what a Redis replica holds; the start refuses a
  Redis file that holds a trim by `~` with LIMIT, which Redis writes as `=` with LIMIT
  (sections 3zzzu, 3zzzy and 3zzzza of [docs/FINDINGS.md](docs/FINDINGS.md)); XINFO
  STREAM takes time with the stream's nodes, as it counts the radix tree's nodes where
  Redis keeps the count, the ranges take 3 to 7 times Redis's time, and the writes 3 to
  12 times (sections 82 and 84 of [docs/PERFORMANCE.md](docs/PERFORMANCE.md)).
- **Clients that wait:** BLPOP, BRPOP, BLMOVE, BRPOPLPUSH, BLMPOP, BZPOPMIN, BZPOPMAX
  and BZMPOP, their timeouts (seconds, a double; 0 waits for ever) read as Redis reads
  them, with its errors. A command that finds nothing to pop makes its client wait, and
  its call is counted then, as in Redis; the commands the client sent after it wait with
  it, run once it is served. After each command the clients that wait are served in the
  order they came, as long as a key of one holds what it waits for, its pop made on that
  key and logged as the command that makes it (LPOP or RPOP with its count, LMOVE,
  ZPOPMIN or ZPOPMAX); a client whose time is up gets a null array at the next tick of
  the cron (Redis's precision too); CLIENT UNBLOCK ends a wait with a null array
  (TIMEOUT) or an UNBLOCKED error (ERROR); a client that closes its connection while it
  waits is forgotten. INFO's `blocked_clients` and `clients_in_timeout_table` count them,
  and the failed calls and errors are counted as Redis counts them. A command run while
  replies are off (CLIENT REPLY OFF or SKIP) pops as it does with them on. Where BendKV
  differs: Redis serves the clients of the keys a command added (`signalKeyAsReady`, from
  `dbAdd`), key by key in the order they became ready, where BendKV looks at every client,
  in the order they came, after every command that may make one ready (one that may write
  a key a client waits on, or a command of the connection or of the server). A client that
  waits costs nothing to the commands on other keys (PERFORMANCE.md, section 61). XREAD
  is not there, and WAIT's wait ends only by its time or CLIENT UNBLOCK (The server,
  below). In a transaction a blocking command does not wait, as in Redis (below).
- **Transactions:** MULTI, EXEC, DISCARD, WATCH and UNWATCH, as Redis 7.0.15 runs them.
  After MULTI a command is queued (QUEUED), but for EXEC, DISCARD, MULTI (an error:
  transactions do not nest), WATCH (an error inside MULTI), QUIT and RESET, which run; a
  command refused as it is queued (an unknown command, a wrong number of arguments,
  NOAUTH) makes EXEC answer EXECABORT, and an EXEC refused itself aborts the transaction,
  with its reason. EXEC runs the queued commands as one: their replies are its array (an
  error as a command runs is in it), no client that waits is served between them, and a
  blocking command among them answers at once. A watched key that any command changes,
  or that is there with its time passed when EXEC comes, makes EXEC answer a null array.
  A change is what Redis counts as one: a write that changes the key, a DEL of a key that
  is there, FLUSHDB, FLUSHALL and SWAPDB of a database that holds it, MOVE, COPY, RENAME,
  the sweep of expired keys; a key watched after its time passed changes only when it is
  set again (its deletion is no change). EXEC, DISCARD, UNWATCH, RESET and a closed
  connection unwatch. A watched key costs nothing to the commands on other keys
  (PERFORMANCE.md, section 61). The calls are counted as Redis counts them (a queued
  command when EXEC runs it, EXEC once). The append-only file has a transaction's
  effects between a MULTI and an EXEC when they are two or more, as Redis writes them.
  Where BendKV differs: an LTRIM that removes nothing changes no watched key (Redis
  signals the key anyway), and a DEL of a key not there is logged (BendKV logs every
  DEL), so a transaction with one may be wrapped in MULTI and EXEC where Redis writes its
  one other effect alone.
- **Pub/Sub:** SUBSCRIBE, UNSUBSCRIBE, PSUBSCRIBE, PUNSUBSCRIBE, SSUBSCRIBE, SUNSUBSCRIBE,
  PUBLISH, SPUBLISH and PUBSUB (CHANNELS, NUMSUB, NUMPAT, SHARDCHANNELS, SHARDNUMSUB,
  HELP), as Redis 7.0.15 runs them. Each name is answered with the client's count of
  channels and patterns (of shard channels for SSUBSCRIBE and SUNSUBSCRIBE); a message
  goes to its channel's subscribers (`message`, `smessage` for a shard channel), then to
  those of each pattern it matches (`pmessage`), and PUBLISH answers how many got it. A
  subscribed client of RESP2 runs (P|S)SUBSCRIBE, (P|S)UNSUBSCRIBE, PING, QUIT and RESET
  alone, as in Redis, any other command refused with Redis's error; one of RESP3 runs any
  command, its messages pushes among its replies (its own messages and keyspace events
  before the reply of the command that made them, as Redis writes them); the replies of
  SUBSCRIBE and its kin go out even with replies off; in a transaction
  SUBSCRIBE and PSUBSCRIBE run and SSUBSCRIBE is refused; RESET, QUIT and a closed
  connection drop the client's subscriptions. Keyspace notifications: with
  `notify-keyspace-events` set, each change a command makes is published to
  `__keyspace@<db>__:<key>` and `__keyevent@<db>__:<event>` with Redis's names of the
  events (`new` for a key made, `del` for a collection emptied, `expired` from the sweep,
  `evicted` from an eviction, the pop of a client that waits after the write that served
  it). Where BendKV differs: UNSUBSCRIBE of all goes in the order the client subscribed
  and PUBSUB CHANNELS in the trie's, where Redis goes in its hash tables'; a slow
  subscriber has no `client-output-buffer-limit pubsub`; no
  events of misses (`m`) or streams; and a key a read finds expired sends `expired` when
  the sweep deletes it, where Redis sends it at the read.
- **Times to live:** EXPIRE, PEXPIRE, EXPIREAT and PEXPIREAT (with NX, XX, GT, LT), TTL,
  PTTL, EXPIRETIME, PEXPIRETIME, PERSIST; SET with NX, XX, GET, EX, PX, EXAT, PXAT and
  KEEPTTL; SETEX, PSETEX, GETEX (EX, PX, EXAT, PXAT, PERSIST) and GETDEL. Times are read
  as Redis reads them, with its errors, and a key expires at its time for every command.
  A key whose time has passed is deleted by a write that comes to it, or by the sweep of
  expired keys ten times a second (logged as DEL, as Redis logs it); until then DBSIZE
  and INFO's keyspace count it, where Redis also deletes it when a read comes to it. A
  time at or past 10^14 ms (the year 5138) gives a key no time at all.
- **Databases:** 16 of them, or as many as `databases` says, as in Redis: SELECT, MOVE
  (the key with its time), SWAPDB, FLUSHDB and FLUSHALL (with ASYNC/SYNC, which empty at
  once), with Redis's errors for a bad number; INFO's keyspace has a line for each
  database that holds keys, and the sweep of expired keys goes over every database.
- **Connection:** PING, ECHO, TIME (the time the batch runs at, to the ms), HELLO (2 or 3,
  with AUTH and SETNAME), AUTH (a password, or a user and its password), SELECT, QUIT,
  RESET (which selects database 0 again, RESP2 and the default user),
  CLIENT (ID, GETNAME, SETNAME, REPLY ON/OFF/SKIP, NO-EVICT, TRACKING, CACHING, GETREDIR,
  TRACKINGINFO, UNBLOCK (TIMEOUT or ERROR), LIST, INFO, KILL, PAUSE, UNPAUSE, HELP),
  FUNCTION FLUSH. A client
  must authenticate where Redis asks it to: once a command's name and number of arguments
  are checked, before it runs (a syntax error is NOAUTH for a client that has not
  authenticated); a client is authenticated as it connects, and at RESET, when the
  default user is on and takes no password then, and by AUTH and HELLO's AUTH, and
  nothing else changes it.
- **Clients:** CLIENT LIST (all, of a TYPE, of IDs), CLIENT INFO and CLIENT KILL (the old
  form of an address, and the filters ID, TYPE, ADDR, LADDR, USER and SKIPME), as Redis
  7.0.15 runs them, with its errors. A client's line has Redis's fields in Redis's order:
  its id, address and local address, its socket's fd, its name, age and idle time, its
  flags (P subscribed, x in MULTI, b waiting, d a watched key touched, e NO-EVICT on, t
  tracking keys, R its redirect gone, B in BCAST mode, N none), database, counts of subscriptions, its queued commands, the bytes of the batch
  and of the arguments of the command that runs (of the blocking command, for a client
  that waits), and the full name of its last command (the blocking one while it waits;
  EXEC, with the client in MULTI, while EXEC runs). A client killed is cut off at once,
  wherever it waits (its socket shut down), its transaction, wait and subscriptions
  dropped, what it waited for left as it was; the old form, and SKIPME no, kill the client
  itself after its reply, and in a transaction after the rest of it. Where BendKV
  differs: it keeps no buffers per client, so their sizes are 0 (qbuf-free, multi-mem,
  rbs, rbp, obl, oll, omem, tot-mem) and so is qbuf of another client (Redis's query buffer
  holds the commands after a blocking one; BendKV holds them as commands); idle counts
  from the client's last batch, where Redis also counts a reply written (to a subscriber
  that gets messages, to a client that waited); user is the client's (ACL), redir the
  client its invalidations go to (0 itself, -1 when it does not track), resp 2 or 3.
- **ACL:** users as Redis 7.0.15 keeps them (ACL SETUSER with selectors, key patterns
  with what each may do, channels, passwords as SHA-256, and Redis's errors; GETUSER,
  LIST, USERS, WHOAMI, CAT, DELUSER, DRYRUN, GENPASS, LOG, HELP), AUTH and HELLO's AUTH
  as any user, and `requirepass` as the default user's password. A call of a client whose
  user may not run every command is checked as Redis checks it, after NOAUTH and before
  the rest: NOPERM for its command, a key or a channel, a refused call and an entry in ACL
  LOG; EXEC checks its commands again; ACL DELUSER closes the users' clients, and ACL
  SETUSER that takes a channel away closes the subscribers that had it. While no client's
  user is restricted, nothing is checked (section 3zzzh of
  [docs/FINDINGS.md](docs/FINDINGS.md)). Where BendKV differs: GETUSER and LIST describe
  commands as Redis 7.2 does, the rules as they were given; users come from ACL SETUSER
  only, not from the configuration or an ACL file; `%~pattern`, which 7.0.15 accepts and
  then crashes on at the next GETUSER, is a syntax error; ACL CAT of a category lists its
  commands by name, where Redis lists them in its table's hash order.
- **CLIENT PAUSE and CLIENT UNPAUSE**, as Redis 7.0.15 runs them: a pause of the
  commands that write or may be replicated (WRITE: PFCOUNT and PUBLISH too, and an EXEC
  whose transaction queued one) or of every command (ALL), for a timeout in ms; a second
  pause keeps the more restrictive kind and the later end. A command the pause holds
  back, once Redis's checks before it passed and before MULTI queues it, waits with the
  rest of its client's batch (CLIENT LIST's flag b, INFO's blocked_clients) and runs when
  the pause ends, at CLIENT UNPAUSE or at its time, in the order the clients came; a
  monitor is never held back. While the pause holds, keys are not swept as they expire,
  nor evicted, as Redis keeps the data set still. Where BendKV differs: CLIENT UNBLOCK of
  a client held back answers 0 (Redis 7.0.15 crashes on it), and EVAL of a script BendKV
  does not run is answered at once (FINDINGS.md, section 3zzk).
- **MONITOR**, as Redis 7.0.15 runs it: each call that runs after it, of any client,
  sends every monitor a line, `+<s>.<us> [<db> <ip:port>]` and the call's arguments as
  the client sent them, quoted as Redis quotes them. As in Redis, a command refused
  before it runs (unknown, the wrong number of arguments, before AUTH, to a subscribed
  client) sends no line, nor do the administrative commands (CONFIG, CLIENT LIST, KILL,
  NO-EVICT and UNBLOCK) and EVAL; a queued command sends its line as EXEC runs it, a
  blocking command as it blocks, and AUTH's password and HELLO's user and password are
  `"(redacted)"`. A monitor is refused the commands that read or write keys ("ERR Replica
  can't interact with the keyspace"), gets its own line after its reply and no line with
  CLIENT REPLY OFF or SKIP; RESET, QUIT and CLIENT KILL end it, and CLIENT LIST shows it
  with the flag O. Where BendKV differs: a line's time is that of the actor's group, in
  ms (its microseconds end in 000), and a monitor's own lines for the calls EXEC runs
  come after EXEC's array, where Redis writes them between its replies.
- **SLOWLOG and LATENCY**, as Redis 7.0.15 keeps them: the actor reads the clock around
  each batch of requests it runs, as Redis around each call, and a batch's calls share
  its time. A call that takes `slowlog-log-slower-than` µs or more goes to the slow log
  (SLOWLOG GET, LEN, RESET, HELP; `slowlog-max-len` entries) with its arguments as its
  client sent them, cut as Redis cuts them, AUTH's, HELLO's and CONFIG SET's secrets
  redacted, EXEC's commands but not EXEC, a blocking command when it is served. With
  `latency-monitor-threshold` set, a call that takes that many ms is a sample of the
  event "command" (or "fast-command"), and a cron's sweep of expired keys one of
  "expire-cycle" (LATENCY LATEST, HISTORY, RESET, GRAPH, DOCTOR, HELP); LATENCY
  HISTOGRAM shows each command's histogram. Where BendKV differs: a pipeline's calls
  share its time, so a slow command lends it to the others; a batch's entries go to the
  slow log when it ends, so a SLOWLOG GET in the same pipeline does not see them; there
  are no events of the append-only file, of eviction or of fork (FINDINGS.md, section
  3zzz).
- **CLIENT TRACKING**, as Redis 7.0.15 runs it (server-assisted client-side caching):
  after a call that only reads, its keys (by the command's key specs) are kept for its
  client, and a command that changes one, as WATCH counts a change, sends each client
  that read it an invalidation, and the key is forgotten; FLUSHDB and FLUSHALL send
  every tracking client a null, and keys the sweep deletes or eviction takes are
  invalidated too. REDIRECT sends the invalidations to another client (a push in RESP3,
  a message of `__redis__:invalidate` to a client of RESP2 subscribed to it), BCAST
  sends after each group of requests the actor runs every key changed under the
  client's prefixes, OPTIN and OPTOUT with CLIENT CACHING choose the reads that count,
  NOLOOP leaves out the client's own changes, and `tracking-table-max-keys` bounds the
  keys kept. CLIENT CACHING, GETREDIR and TRACKINGINFO, CLIENT LIST's flags and redir,
  and INFO's tracking fields answer as Redis's. Batches on keys no client tracks keep the
  fast way; a client that tracks runs its own commands one at a time, as a subscribed
  client does, and while a client is in BCAST mode every command runs so (PERFORMANCE.md,
  section 66). Where BendKV differs: an expired key is invalidated when the sweep deletes
  it, not when a read finds it; the table's limit is applied at each tick of the cron, not
  before each command; an overlap of two given prefixes past the first gets the error
  alone (Redis 7.0.15 answers the error, then OK, and tracks with all the prefixes); a
  client of RESP3 that others redirect to, with no subscription and whose batches all run
  the fast way, gets its invalidations with its next reply, where Redis pushes them at
  once; a command's invalidations go out before all its keyspace events, where Redis
  sends them key by key, each next to its event; an LTRIM that removes nothing
  invalidates nothing, where Redis invalidates its key; a client that others redirect to
  gets the invalidation of a key its own command writes before that command's reply,
  where Redis writes it after the reply for the commands that reply before they signal
  the key (ZADD, ZINCRBY, HSET, HINCRBY, LPUSH, RPUSH, a served BLMPOP), and inside the
  reply of a served BZPOPMIN, BZPOPMAX or BZMPOP (FINDINGS.md, section 3zzzb).
- **The server:** LASTSAVE (the last save that ended well, the start until one does), ROLE (a master
  with no replica), WAIT (0, as no replica acknowledges: at once when it asks for none,
  otherwise once its timeout ends, its client waiting as a blocking command's does),
  MEMORY STATS, DOCTOR, PURGE and MALLOC-STATS (Redis's fields and advice, from the
  numbers INFO's memory section shows), LOLWUT (Redis 7.0.15's line, and the drawings of
  VERSION 5 and 6, those that take no random number byte for byte as Redis draws them),
  and SHUTDOWN [NOSAVE|SAVE] [NOW] [FORCE] [ABORT], read as Redis 7.0.15 reads it: the
  append-only file written and synced, a rewrite or a background save that runs
  stopped, the RDB file saved with save points or SAVE and not with NOSAVE (a save that
  fails stops nothing, Redis's error answered, but with FORCE; other clients' commands
  after a SHUTDOWN that saves wait for its save, and run only if it fails), the pid file
  removed, the process ended with code 0.
  Where BendKV differs: SIGTERM and SIGINT end the process at once, without the shutdown
  Redis runs for them (`shutdown-on-sigterm`, `shutdown-on-sigint`: its save with save
  points among it, and the removal of a background save's temporary file), as the
  runtime has no handler for them; MEMORY MALLOC-STATS has no allocator's statistics;
  LOLWUT's large drawings take up to a hundred times Redis's time (FINDINGS.md, sections
  3zzl and 3zzzc).
- **Configuration:** CONFIG GET (names, aliases and glob patterns), SET (several
  parameters at once, all or none), RESETSTAT, REWRITE, HELP, over every parameter of
  Redis 7.0.15 (counted in [In numbers](#in-numbers)), taken from Redis's own table by
  `tools/gen_config.py`: every value is
  checked as Redis checks it and read back as Redis prints it. requirepass is the
  default user's password, hz is capped as in Redis and notify-keyspace-events picks the events
  published (above); the port, the addresses, TLS and the append-only
  file cannot change while BendKV runs (a new value fails as it does when Redis cannot
  apply it); maxmemory and its policy, samples, tenacity and LFU parameters limit the
  memory and choose what is evicted (below); `save`, `dbfilename` and `rdbchecksum`
  act on the RDB file (Persistence, below); the other parameters are kept and read
  back but tune nothing, since BendKV has no replication or encodings for them to tune.
- **Introspection:** INFO with Redis 7.0.15's sections and fields, in Redis's order,
  picked as Redis picks them (none, `default`, `all`, `everything`, any names in any
  case): server, clients, memory, persistence, stats, replication, CPU, modules,
  errorstats, cluster, keyspace. The values are BendKV's own where it has them: its
  process, its parameters, its connections, commands and bytes (with the instantaneous
  rates sampled every 100 ms, as Redis's cron samples them), its memory (`used_memory` is
  what its heap's live values hold, as Redis's is what its allocator handed out; Memory,
  below), its keys, its evictions, its append-only file; for what BendKV does not have
  (replication, forks, scripts) they are what Redis shows when it has none. The
  statistics per command count as Redis counts them: each command's and subcommand's
  calls, the calls refused before they run (a wrong number of arguments by Redis's arity,
  a client that must authenticate first, a command refused for memory) and the calls
  that fail as they run, and the error replies by their code, held-back replies included
  (CLIENT REPLY OFF); what each call took goes to its command's usec and, with
  `latency-tracking`, its histogram (latencystats, at the percentiles of
  `latency-tracking-info-percentiles`), as Redis keeps them (below). CONFIG RESETSTAT
  starts the counts again. COMMAND (with INFO, DOCS, COUNT, LIST and its
  filters, GETKEYS, GETKEYSANDFLAGS, HELP) describes each command BendKV has, and each
  subcommand it has, as Redis 7.0.15 describes it: `tools/gen_commands.py` takes the
  descriptions from Redis itself.
- **Memory:** maxmemory and its eviction, as Redis 7.0.15 runs them. With maxmemory set,
  BendKV reads what its heap's live values hold before each group of requests, as Redis
  measures before each command, and INFO's `used_memory` is that reading, the one the
  eviction goes by (section 3zzzi of [docs/FINDINGS.md](docs/FINDINGS.md)); while it is
  past maxmemory, BendKV evicts keys by
  `maxmemory-policy`: the LRU, LFU and volatile-ttl policies from a pool of the 16 best
  candidates of their samples (`maxmemory-samples` keys of each database), kept from one
  eviction to the next, the random ones a key of each database in turn, the volatile ones
  among keys with a time alone. An evicted key is deleted as an expired one is: a DEL in
  the append-only file, its WATCHes touched, an `evicted` keyspace event, a count in
  INFO's `evicted_keys`. Past the time `maxmemory-eviction-tenacity` allows, the eviction
  goes on between groups, as Redis's goes on from its event loop; with nothing it may
  evict, the commands that may take memory get Redis's OOM error, so does any command a
  client queues in MULTI, and EXEC aborts a transaction that queued one. A CONFIG SET of
  maxmemory evicts at once, with Redis's warning when the memory is past the new value;
  INFO shows how long the memory was past it (`total_eviction_exceeded_time`,
  `current_eviction_exceeded_time`). A key's use is kept as Redis keeps it, by its LRU
  clock (seconds) or its LFU counter (logarithmic, with `lfu-log-factor`, decayed by
  `lfu-decay-time`), and OBJECT IDLETIME and FREQ answer from it. Where BendKV differs:
  the same maxmemory holds another number of keys, since a key takes other bytes in
  BendKV's heap (with its share of the trie's nodes) than in Redis's allocator, and
  about 8% fewer after a rewrite of the append-only file, until they are set again
  (issue #102); while a rewrite of the append-only file or a background save runs, the
  eviction and the refusal past maxmemory count the dataset's change by its number of
  keys, each at the average size when the job started (a value grown in place counts
  when the job ends), where Redis's parent counts what it allocates and not the pages
  its child's snapshot keeps; BendKV's snapshot holds the values the writes replace,
  and INFO's `used_memory` with it (FINDINGS.md, section 3zzzk); the uses
  are kept in a table of 2^20 words by the key's hash, which keys whose hashes share
  their low 20 bits share, and a request marks its first key alone, before it runs
  (MGET's others are not marked); and evicting many keys at once is about ten times
  slower than in Redis.
- **Start:** as `redis-server` starts: a configuration file, `--name value` options and
  `-` for the standard input, read line by line as Redis reads them (includes, `dir`
  changing the directory at once, save points that add up, the same errors at the same
  lines), and a log in Redis's form, on the standard output or in `logfile`. The port,
  `bind` (IPv4), `requirepass`, `protected-mode`, the append-only file (`appendonly`,
  `appendfilename`, `appendfsync`, `aof-load-truncated`), `logfile`, `loglevel` and
  `pidfile` act. With `appendonly no` the RDB file (`dbfilename` in `dir`) is loaded
  when it is there, as Redis loads it, with its log's lines; a file that does not load
  stops the start with Redis's reason. With `appendonly yes` the append-only file is
  loaded and the RDB file left aside, as in Redis. What BendKV cannot do (modules, ACL
  users from the configuration or a file, renamed commands, the background, a cluster, a
  replica, TLS, a supervisor to signal, Redis 7's multi-part append-only file, or an RDB
  file that holds a module's data or functions, to load) stops the start with a line
  saying so.
- **Protocol:** pipelining, partial packets, inline commands with quoting,
  binary-safe values; requests framed as Redis 7.0.15 frames them (a length as `string2ll`
  reads it, with no `0` before its first digit, a count of 0 or less skipped down to
  -2^63, a line ended by its `\r` and whatever byte follows it, 64 KB at most without
  one, the two bytes after a bulk's data skipped unread), and Redis's protocol errors.
  An error goes out on one line, as Redis's error formatting sends it: a CR or LF in its
  text as a space, an argument it quotes up to its first NUL. Under CLIENT REPLY OFF, or
  SKIP for the request it is in, a protocol error goes unanswered, as in Redis, and the
  connection stays open, reading nothing more, until the client closes it. Not the
  tighter limits Redis puts on a client that must still authenticate (10 arguments, a
  bulk of 16 KB), nor a new proto-max-bulk-len.
- **Persistence:** an append-only file in Redis's own format, a SELECT before the
  entries of another database, SWAPDB, MOVE and FLUSHALL as Redis writes them, and COPY
  with its DB and REPLACE spelled out, a transaction's effects between MULTI and EXEC
  (`redis-check-aof` accepts it, and Redis loads it; BendKV loads Redis's, COPY as the
  client sent it), fsync `always`, `everysec` or `no`. The start syncs the file's
  directory before it serves, so that a new file's name is on the disk before the first
  write is acknowledged, and cuts a file that ends in an entry cut short back to its last
  whole entry at any size; a file that ends inside a transaction (a crash cut it as it
  was written) has the transaction reverted and is cut back to before its MULTI, as Redis
  does ("Revert incomplete MULTI/EXEC transaction"; with `aof-load-truncated no` both stop
  the start instead). Where BendKV differs: a file that ends inside a transaction, then in
  an entry cut short, BendKV cuts back to before the MULTI, where Redis cuts it after the
  transaction's last whole entry and leaves the MULTI and the entries it queued for its
  next start to revert; the databases are the same. The start reads the file a window
  at a time (1 MiB, or as long as an entry that runs past the window), so that what it
  holds at once is a window, a transaction until its EXEC and the databases it builds,
  not the whole file (section 3zzzg of [docs/FINDINGS.md](docs/FINDINGS.md)). A file
  with an entry the start cannot replay as it was written (an
  unknown command, a wrong number of arguments, an argument that does not read, a
  database not there, a MULTI inside another, an EXEC without one) stops the start,
  naming the entry and the byte it starts at, the file left as it was, where Redis stops
  at an unknown command. BGREWRITEAOF, and the cron's rewrites as the file grows
  (`auto-aof-rewrite-percentage`, `auto-aof-rewrite-min-size`), write the file again
  as Redis writes its base: the commands that make the databases as they are when it
  starts, then the entries appended meanwhile, into a temporary file renamed onto the
  file; without a fork, the databases being values, a slice at a time between the
  groups of requests the server answers meanwhile; with INFO's fields of a rewrite
  (FINDINGS.md, section 3zv). The RDB file as Redis 7.0.15 writes it (`REDIS0010` and
  its AUX fields, each database's SELECTDB and RESIZEDB, each key's EXPIRETIME_MS and
  value as DUMP writes it, EOF and the CRC64, or eight zero bytes with `rdbchecksum
  no`): SAVE writes it into `temp-<pid>.rdb`, syncs it, renames it onto `dbfilename` and
  syncs the directory, as Redis's `rdbSave` does, with its replies and log lines;
  SHUTDOWN saves it (above), and FLUSHALL with save points saves the emptied databases,
  as Redis 7.0's does; BGSAVE [SCHEDULE] writes it in the background from a snapshot of
  the databases at the command (the databases being values, without a fork, a slice at a
  time between the groups of requests the server answers meanwhile; `dbfilename` and the
  save's pace as they were then, its temporary file held open to its end, as Redis's
  child keeps them), with Redis's replies, log lines and INFO fields, and so does the
  cron at Redis's default save points (`save 3600 1 300 100 60 10000`), five seconds
  apart after a save that failed; one background job runs at a time (BGSAVE while a
  rewrite runs is refused, or scheduled with SCHEDULE, BGREWRITEAOF while a save runs is
  scheduled, SAVE is refused, and FLUSHALL and SHUTDOWN drop the save that runs); after
  a background save that failed, with save points and `stop-writes-on-bgsave-error yes`,
  the writes and PING are refused with Redis's MISCONF until a save ends well; INFO's
  `rdb_changes_since_last_save` counts the changes since the last save, as Redis counts
  them, for the save points; LASTSAVE and INFO's `rdb_last_save_time`, `rdb_saves`,
  `rdb_last_bgsave_status` and `rdb_last_load_keys_loaded` and `_expired` follow it
  (FINDINGS.md, section 3zzzk). The start reads every version from 1 to 10, every
  encoding Redis 7.0.15 reads but a module's, AUX fields it does not know, and drops
  the keys whose time has passed, counting them; it reads the file a window at a time
  (1 MiB, or as long as a value that runs past the window), so that
  what it holds at once is a window and the databases it builds (FINDINGS.md, section
  3zzzt). Where BendKV differs: no save on SIGTERM or SIGINT (above; the start warns of
  it when save points are set), and the short form (`bendkv PORT`) has no save points;
  `rdb_changes_since_last_save` counts some writes otherwise (SET with GET by its reply,
  ZADD and GEOADD each pair, BITFIELD each write that OVERFLOW FAIL let through, PFADD
  one, PFCOUNT none; FLUSHDB and FLUSHALL a key whose time has passed until the sweep
  deletes it, also after a read found it missing, which Redis's read deletes, and so
  does `current_save_keys_total`; a pipeline's weights read as the batch found the
  databases; an INFO after a FLUSHALL with save points in its pipeline as if that
  FLUSHALL's save ended well; 0 after a start from the append-only file); no fork, so no
  fork's fields or lines, and the progress of a save in INFO follows each slice written
  (a rewrite's shows none); the line of a background save's start comes once its group
  is answered; SAVE and the saves of SHUTDOWN and FLUSHALL ignore `rdb-key-save-delay`;
  no LZF written; no IDLE or FREQ written, and those read set no word of use; SAVE's
  client waits through the rest of its group, so that the others in it see it blocked,
  the commands after SAVE in its pipeline run in a group of their own (a client in BCAST
  tracking mode gets the keys they change in an invalidation push after the one of the
  keys changed before SAVE, where Redis sends one; BGSAVE splits nothing), the file
  holds the databases as the group left them, and SAVE's call time leaves the save out;
  after a start from the file, INFO's replication section and ROLE give an offset of 0,
  where Redis counts into `master_repl_offset` a DEL for each key whose time had passed,
  and keeps the file's `repl-id` and `repl-offset` as its `master_replid2` and offset,
  which its next save writes again (BendKV drops them); the log of a file that does not
  load gives the byte where the reading failed, where Redis gives what it had read at
  its last report of progress, and leaves out Redis's `function at rdb.c:N`; a
  background save takes longer than Redis's, and so does the start from a large file
  (PERFORMANCE.md, sections 72 and 78; FINDINGS.md, sections 3zzzk and 3zzzt).

Not yet: the commands of a stream's groups and XREAD's wait, Lua
scripts, CONFIG REWRITE (it answers as Redis does without a configuration file).
Times in ms are limited to 14 digits.

## Performance

Pipeline depth 16, 20 clients, filled database, 3-byte values, Redis 7.0.15 on the same
VM (medians over 8–13 interleaved pairs):

| share of Redis throughput | GET | SET | INCR |
|---|---:|---:|---:|
| BendKV on unpatched Bend | 0.08–0.14 | 0.08–0.14 | 0.08–0.14 |
| BendKV, 100k keys | **1.62** | **1.82** | **1.45** |
| BendKV, 1M keys | **1.65** | **1.80** | **1.17** |

With Redis's own benchmark specs run by `memtier_benchmark`, BendKV reaches 1.26–1.39×
Redis. Without pipelining both are bound by network latency and stay within noise of each
other. About 950 thousand keys with 3-byte values take 60 MB RSS against Redis's 121 MB.
The full record, with every measurement and method, is in
[docs/PERFORMANCE.md](docs/PERFORMANCE.md) and
[docs/FINDINGS.md](docs/FINDINGS.md).

## Building

You need [Bun](https://bun.sh), clang 19 (clang 18 works, about 8% slower), Python 3,
and Bend with the patches in [`bend-patches/`](bend-patches/) applied; `make verdict`
also needs Lean 4.34.0 (through elan).

```bash
git clone https://github.com/bendlang/bend ../bend-patched
sh bend-patches/apply.sh ../bend-patched      # Bend 2.0.35 and the patches
B="bun ../bend-patched/bend2/main.ts"

make check   BEND="$B"   # check the proofs
make verdict BEND="$B"   # ... and recheck them in the BendTT kernel
make build   BEND="$B"   # build/bendkv
make run                 # ./build/bendkv 6380
redis-cli -p 6380 set foo bar
```

`./build/bendkv [/path/to/redis.conf] [--name value ...] [-]` starts as `redis-server`
does (`./build/bendkv --port 7777 --appendonly yes`, `./build/bendkv /etc/redis/redis.conf`);
replies go out from a writer thread when the process has two cores or more (a client that
stops reading holds up only its own replies), and from the event loop with
`io-threads 1`. `./build/bendkv --help` lists the forms. The short form
`./build/bendkv PORT [post|send [FILE [always|everysec|no]]]` is BendKV's own: `post` or
`send` picks how replies go out, `FILE` (any path) turns on the append-only file; it
loads no RDB file.

## Testing

```bash
make smoke     BEND="$B"   # the pure path end to end and the append-only file, no network; fails on any mismatch
make test      BEND="$B"   # needs redis-server, redis-cli, redis-benchmark and a C compiler
make perfcheck BEND="$B"   # instructions, misses and prefetches per request against a baseline (needs valgrind)
make gencheck              # the generated parts (trie, its proofs, the parameter and command tables, the counts) are up to date
make bench     BEND="$B"   # redis-benchmark: BendKV against Redis
make suite     BEND="$B" REDIS_SRC=../redis   # Redis's own test suite, on Redis and on BendKV (needs tclsh)
make clients   BEND="$B"   # redis-py's and go-redis's test suites, on Redis and on BendKV (needs go)
```

`make test` runs, against a reference `redis-server`: the start (about a hundred command
lines and configuration files, each on both servers, with the same errors and the same
parameters after them), a differential test of random
command streams compared byte for byte (times to live, SET's options and several
databases among them),
keys that expire (set with short times on both servers, then read once the times have
passed), the protocol edge cases of Redis's
`tests/unit/protocol.tcl` and of the lengths and lines of its `processMultibulkBuffer`
and of the replies CLIENT REPLY holds back (each server's closing of a connection seen in
its count of connections, not in a quiet socket), the float library against glibc
(random texts of numbers,
read, written and added, the answers compared byte for byte with C's), the connection
commands, CONFIG (every parameter, a list of
cases and thousands of random values, set and read back on both servers), INFO (the
sections and fields for 31 ways of picking them, the values that do not depend on the
machine, the counts after CONFIG RESETSTAT), the statistics per command (commandstats,
errorstats and the totals after the same requests, one at a time and pipelined, with
refused, failed, held-back and protocol errors, compared as maps), the timing of calls
(SLOWLOG and LATENCY's replies, the slow log's entries with every call logged, the
histograms and latencystats, with what depends on how long a call took put aside),
COMMAND (each
command's description and
documentation, the lists and their filters, the keys of command lines, random ones
too), SCAN and RANDOMKEY (their arguments, full iterations with COUNT, MATCH and TYPE
finding Redis's keys, each once, an iteration while other clients write, RANDOMKEY's
picks), KEYS and SCAN's MATCH on patterns that only a matcher with Redis's cut-offs
answers at once (adjacent stars, alternatives matching at once or nowhere, stars nested
past 1000), numbers at their edges in every argument that takes one (past a long long, at
2^48, in forms Redis refuses), BITFIELD's fields at random (each reply and each value
after it compared), hashes (each command at its edges, past a listpack's limits, on keys
whose time has passed, and at random, the fields of a hashtable compared as sets), lists
(each command at its edges, lists of up to 20,000 elements, moves onto keys whose time
has passed, and at random, with moves between a few keys), sets (each command at its
edges, intsets on both sides of 512 members, small sets on both sides of 128 members of
64 bytes and hashtables of up to 20,000, moves and
STOREs onto keys whose time has passed, and at random, the members of a hashtable
compared as sets and each random pick checked against the set it came from), sorted sets
(each command at its edges, sorted sets of up to 20,000 elements on both sides of a
listpack's limits, STOREs and pops of keys whose time has passed, and at random, ZSCAN's
walk compared by its pairs and each random pick checked against the sorted set it came
from), SORT and SORT_RO (`tests/sort_test.py`: the cases of Redis's tests and of its
`sort.c`, lists, sets and sorted sets of up to 10,000 elements sorted every way, and
random SORTs with BY and GET patterns over strings and hashes, each STORE's destination
read back), HyperLogLogs (`tests/hll_test.py`: the cases of Redis's tests and of its
`hyperloglog.c`, values made by hand and corrupted at random, and random sequences of the
PF commands, each reply compared and each value written read back byte for byte), GEO
(`tests/geo_test.py`: the cases of Redis's tests and of its `geo.c`, random sets and
searches, each reply compared byte for byte in RESP2 and RESP3, and each write's sorted
set read back), DUMP and RESTORE (`tests/dump_test.py`: values of every kind and
encoding, their payloads compared byte for byte and restored on both servers, payloads of
the encodings Redis no longer writes, 1,500 payloads cut, grown and changed at random,
RESTORE's options, errors, times and keyspace events, IDLETIME and FREQ), streams
(`tests/stream_dump_test.py`: streams of 27 shapes Redis made, restored and dumped back
byte for byte, and 2,000 payloads changed at random; `tests/stream_read_test.py`: the
reads of those streams, each reply compared whole in RESP2 and RESP3, over the
streams' IDs, their neighbours and the edges, counts, groups, consumers and errors;
`tests/stream_write_test.py`: random XADD, XTRIM, XDEL and XSETID, each reply compared
and each stream's DUMP and XINFO after each write, the errors, the events, WATCH and
MULTI; `tests/stream_aof_test.py`: the writes in both servers' append-only files, each
server started from its own and from the other's),
robustness and concurrency checks, a client that stops reading while the others are
served (`tests/writer_test.py`), clients that wait (`tests/blocking_test.py`: 18 scenarios
of the blocking commands on BendKV and on Redis, their transcripts compared line by line,
then 300 clients served at once, 100 timeouts at once, clients that leave while they wait,
and 50 consumers moving 1,000 items while some leave), transactions (`tests/multi_test.py`:
12 scenarios of MULTI, EXEC, DISCARD, WATCH and UNWATCH on BendKV and on Redis, their
transcripts compared line by line, then a counter raised by 20 clients with WATCH, each
lost race retried, a reader that never sees half of a transaction, and 100 clients that
leave in MULTI or with keys watched; random transactions in the differential test too),
Pub/Sub (`tests/pubsub_test.py`: scenarios of Pub/Sub and the events of 162 commands
on BendKV and on Redis, their transcripts compared line by line, then 20 subscribers that
each get the 2,000 messages of 4 publishers in order, and 50 subscribers that leave while
messages are published), CLIENT LIST, INFO and KILL (`tests/client_test.py`: scenarios on
BendKV and on Redis, their lines compared field by field with what differs by nature put
aside, then 100 clients listed and half of them killed by id, and 200 killed by address
while other clients connect and close, none killed but those named), MONITOR
(`tests/monitor_test.py`: scenarios on BendKV and on Redis, a monitor's lines compared
with their time and address put aside, then 4 monitors that each get every line of 20
clients that pipeline 200 SETs each, each client's lines in order), CLIENT PAUSE and
UNPAUSE (`tests/pause_test.py`: scenarios on BendKV and on Redis of what a pause holds
back and lets run, its end and the order the clients go on in, their transcripts compared
line by line, then 100 clients held back and let go in order), the administrative
commands (`tests/admin_test.py`: LASTSAVE, ROLE, WAIT, MEMORY, LOLWUT's drawings byte for
byte and SHUTDOWN's errors on BendKV and on Redis, then SHUTDOWN on servers of their own,
the append-only file and the pid file after it, and a SHUTDOWN while a rewrite runs), AUTH
(`tests/auth_test.py`: scenarios on BendKV and on Redis of when a client must
authenticate and what it is answered before it does), ACL (`tests/acl_test.py`:
scenarios on BendKV and on Redis of a user's calls allowed and refused, alone and
pipelined behind AUTH, ACL LOG, MULTI and EXEC, the clients ACL SETUSER and DELUSER
close, CLIENT LIST and CLIENT KILL USER, SORT's BY and GET, and the slow log), RESP3 (`tests/resp3_test.py`: 11
scenarios on BendKV and on Redis compared byte for byte, of HELLO and the switch of
protocol in a pipeline, the replies RESP3 types, EXEC, blocking commands and Pub/Sub's
pushes; and the differential tests of keys, numbers, BITFIELD and the types again with
every connection in RESP3, `RESP=3`),
connections that end every way one can, many times
(the client closing or resetting, QUIT, a protocol error), on a BendKV of their own whose
table of channels is read to show that each closed the channel it opened,
restarts from the append-only file (every database read back, including after a
truncated tail or a transaction left open; files whose entries, transactions and values
straddle the windows the start reads them in, started on by BendKV and by Redis alike,
`tests/aof_window_test.py`; and the resident memory after a restart from a file of a
million SETs, `tools/restore_mem.sh`), kills at random moments while clients write
(`tests/crash_test.py`: rounds of a SIGKILL under load, some while a rewrite runs, some
starts killed as they load the file, each start holding the databases after a prefix of
the commands sent, every one acknowledged among them), disk failures
under the file, injected with an `LD_PRELOAD` shim (the order of the file's creation,
its directory's sync and the first reply traced through it), files the start must
refuse, each left as it was, and the files both ways: BendKV
started from a file Redis wrote and Redis from one BendKV wrote, each holding the
databases the other held, and the rewrite of the file (`tests/rewrite_test.py`:
BGREWRITEAOF's replies and INFO's account against Redis's, the rewritten file against
Redis's base command for command, writes during a rewrite and a kill during one, the
cron's rewrites, rewrites that fail, BendKV and Redis started from the new file),
maxmemory (`tests/maxmemory_test.py`: the refusals past it, OBJECT IDLETIME and FREQ
and the `evicted` event against Redis's, Redis's own tests of the policies on both, an
eviction that goes on alone, with the append-only file on and while a rewrite runs), and
the RDB file (`tests/rdb_test.py`: files Redis wrote, with LZF and without, and files of
the encodings Redis no longer writes, BendKV and Redis started from each and every key
of every database compared; BendKV's SAVE, Redis started from its file; both ways with a
database of 10,000 keys and a file past 16 MB; a file of values longer than the start's
window, cut or with a byte changed past the first window, on both, and the resident
memory after a start from a file of 300,000 keys; SAVE, LASTSAVE, INFO and the saves of
FLUSHALL and SHUTDOWN against Redis's, with the append-only file and with another
client's requests in the same group; files that do not load).
`make suite` runs Redis's own test suite in its mode for a server already started, on
Redis and on BendKV, and counts the tests Redis passes that BendKV passes
([docs/COMPATIBILITY.md](docs/COMPATIBILITY.md)). `make clients` runs the test suites of
two client libraries the same way, redis-py's in RESP2 and in RESP3 and go-redis's
(`tools/client_suite.py`); CI runs them on every pull request, and fails on a test Redis
passes that BendKV fails and that is not among the known failures of
`tools/data/clients.json`. `tools/sanitize.sh` builds the server with AddressSanitizer
and UndefinedBehaviorSanitizer (the Bend heap's free nodes poisoned, patch 34) and with
ThreadSanitizer, and runs under each the tests that stress its memory and its writer
thread most; CI runs it on every pull request too, and fails on any report
([docs/FINDINGS.md](docs/FINDINGS.md), section 3zzp).

## Layout

```
src/        the server
  map.bend      hash trie with string keys                         verified
  float.bend    doubles and long doubles in software               tested
  hll.bend      HyperLogLogs on a string's bytes, as Redis's       tested
  geo.bend      geohashes, cells, distances and sorts, as Redis's  tested
  lolwut.bend   LOLWUT's drawings, as Redis draws them             tested
  rdb.bend      the RDB format: DUMP, RESTORE and the file         tested
  redis.bend    command semantics: exec(cmd, db) -> (reply, db')   verified
  batch.bend    a pipelined batch with cache hints                 verified
  aof.bend      append-only file: effects, encoding, loading       verified
  session.bend  connection and server state, whole batches         verified
  config.bend   the parameters, CONFIG GET and SET                 verified
  resp.bend     RESP parser, RESP2 and RESP3 reply encoders         tested
  info.bend     INFO's sections and fields, SLOWLOG, LATENCY        tested
  command.bend  COMMAND, with Redis's table of BendKV's commands     tested
  sha.bend      SHA-256, as Redis keeps a password's               tested
  acl.bend      ACL users: rules, checks and the log, as Redis's   tested
  startup.bend  the command line and the configuration file        tested
  server.bend   TCP, connections, the database actor, the log      tested
proof/      LAWS.bend (the laws), PROOF.bend (their proofs), SPEC.bend (the commands on the trie alone)
tests/      smoke (the pure checks), float, start, differential, expiry, protocol, session, the end of a connection, CONFIG, INFO, statistics per command, COMMAND, SCAN, numbers at their edges, BITFIELD, hash, list, set, sorted set, SORT, HyperLogLog, GEO, DUMP and RESTORE, blocking, transaction, Pub/Sub, CLIENT, MONITOR, timing of calls, CLIENT PAUSE, administrative commands, AUTH, ACL, RESP3, maxmemory, robustness, stalled reader, concurrency, AOF, AOF crash, AOF rewrite and RDB file tests
bench/      in-process benchmarks of the map, the core and channels, and `make bench` against Redis
tools/      measurement scripts, the runners of Redis's test suite and of the client libraries'
            suites, and the generators of the trie, of the parameter table, of the command
            table and of the counts, with the facts they take from Redis (tools/data/)
bend-patches/  the patches to the Bend compiler and runtime
docs/       FINDINGS.md, DIRECTIONS.md, COMPATIBILITY.md, PERFORMANCE.md
```

## In numbers

The counts the other documents link to, written by
[`tools/gen_counts.py`](tools/gen_counts.py) from the files they count; `make gencheck`
fails when one is out of date. Lines of code leave out comments and blank lines and are
rounded to two significant figures; they are out of date once a file's count is a tenth
away.

<!-- BEGIN gen_counts: numbers -->
| what | how many | counted in |
|---|---:|---|
| laws | 68 | `proof/LAWS.bend` (by group: [What is proved](#what-is-proved)) |
| patches to the Bend compiler | 35 | `bend-patches/apply.sh` |
| constructors of `Cmd`, a parsed command | 30 | `src/redis.bend` |
| Redis 7.0.15's parameters, all of which CONFIG serves | 178 | `tools/data/redis-configs.json` |

| file | lines of code | of them written by a generator | the laws import it |
|---|---:|---:|---|
| `src/map.bend` | 5,000 | 1,500 | yes |
| `src/redis.bend` | 20,000 | 8,200 | yes |
| `src/batch.bend` | 84 |  | yes |
| `src/aof.bend` | 1,300 |  | yes |
| `src/session.bend` | 2,700 |  | yes |
| `src/config.bend` | 1,200 | 180 | yes |
| `src/acl.bend` | 2,100 | 600 | no |
| `src/command.bend` | 2,500 | 1,900 | no |
| `src/float.bend` | 1,200 |  | no |
| `src/geo.bend` | 870 |  | no |
| `src/hll.bend` | 1,400 |  | no |
| `src/info.bend` | 2,600 |  | no |
| `src/lolwut.bend` | 470 |  | no |
| `src/rdb.bend` | 3,100 |  | no |
| `src/resp.bend` | 980 |  | no |
| `src/server.bend` | 11,000 |  | no |
| `src/sha.bend` | 120 |  | no |
| `src/startup.bend` | 460 |  | no |
| `src/stream.bend` | 1,100 |  | no |
| `proof/LAWS.bend` | 920 | 20 |  |
| `proof/SPEC.bend` | 370 |  |  |
| `proof/PROOF.bend` | 18,000 | 2,800 |  |
| `src/`, the 6 files the laws import | 28,000 | 9,100 |  |
| `src/`, the 13 others | 28,000 | 2,600 |  |
| `proof/` | 18,000 | 2,800 |  |
<!-- END gen_counts: numbers -->

## Documentation

- [docs/FINDINGS.md](docs/FINDINGS.md): what building BendKV and making it fast showed.
- [docs/DIRECTIONS.md](docs/DIRECTIONS.md): verified databases, compilers, parallelism,
  and where the work goes next.
- [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md): Redis's own test suite against BendKV,
  unit by unit, and why the tests it fails fail; the test suites of redis-py and go-redis.
- [docs/PERFORMANCE.md](docs/PERFORMANCE.md): every optimization, section by
  section, with measurements.
- [OVERVIEW.md](OVERVIEW.md): the full project report, including the
  feasibility study (SQLite, Redis, memcached, LMDB in Bend2) and Bend2's limitations
  met in practice.
- [tools/README.md](tools/README.md): how it was measured.
- [bend-patches/README.md](bend-patches/README.md): the compiler patches.

## History

BendKV began as a proof of concept inside a fork of HVM4 and moved here once it grew
into a project of its own. Sharding across cores was built, proved and later taken out
because it paid too little for its cost ([docs/FINDINGS.md](docs/FINDINGS.md), section
3l); that version is kept on the [`archive/shards`](https://github.com/littleBro/BendKV/tree/archive/shards) branch.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Not decided yet. Until a license is added, all rights are reserved by the authors.
