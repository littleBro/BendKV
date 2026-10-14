# BendKV

A Redis-compatible key-value server written in [Bend2](https://github.com/bendlang/bend),
whose core is formally verified: the command semantics, the hash trie behind them, the
append-only file, the databases, the connection state and the configuration are proved
against 67 laws,
checked by Bend
and rechecked by the BendTT kernel, whose soundness is proved in Lean.

BendKV speaks RESP2 and RESP3 (HELLO 3), so `redis-cli`, `redis-benchmark`,
`memtier_benchmark` and clients that speak RESP3 by default (go-redis v9, Lettuce) work
with it. Under pipelined load it serves GET at 1.6×, SET at 1.8× and INCR at 1.45× the
throughput of Redis 7.0.15 on the same machine, with half its memory for small values.

> **Status: research prototype.** BendKV implements a subset of Redis (strings, hashes,
> lists, sets, sorted sets and their times to live, the blocking commands, transactions,
> pub/sub and keyspace notifications, the keyspace, several databases, connection
> commands, CLIENT LIST, INFO and KILL, MONITOR, an append-only file and its rewrite,
> maxmemory and its eviction, RESP3). The goal now is a drop-in replacement for a single
> Redis node, measured by Redis's own test suite: of the 1,677 tests Redis 7.0.15 passes
> against a server it did not start, BendKV passes 1,097, and 1,090 of the 1,172 in what
> it implements
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
(31 patches to the Bend compiler, in [`bend-patches/`](bend-patches/): most speed up its
data representation and its runtime, and the others add what a server needs from the
system, from the process's directory, id and clock to the files it cuts and the heap's
account).

## What is proved

The laws are stated by hand in [`proof/LAWS.bend`](proof/LAWS.bend) and proved in
[`proof/PROOF.bend`](proof/PROOF.bend). A database is a record: the trie, whose
entries hold each key's value (a string, or a collection) and the time it expires at; how many keys it holds (which
DBSIZE answers) and how many of them have a time; and the time its batch runs at. The
server holds several (16, as Redis), with the one a connection selected in focus while
its batch runs. A key whose time has passed is there for no command. The laws about what keys read and what
commands answer are proved of a specification, the commands on the trie alone at a time
([`proof/SPEC.bend`](proof/SPEC.bend)), and a bridge proves that the server's commands
answer as it does (DBSIZE answers the count) and leave the trie it leaves; the counts are
proved to be the trie's own.

| group | laws | what they say |
|---|---:|---|
| Map | 11 | the trie is a finite map from keys to a value and a time: after any sequence of writes (a value with a time, a value with its time kept, a time alone, a deletion), every key holds what was last written to it, with no stale, lost or foreign entries; a read sees a key only until its time |
| Keys | 2 | key comparison is exactly string equality, down to the bits of `U32` |
| Commands | 24 | no command changes a key it does not write, neither its value nor its time (`frame`); reads keep the database (the commands of hashes, lists, sets and sorted sets are reads and updates of their key, LMOVE, LMPOP, SMOVE, ZMPOP and the operations of several sets and sorted sets of their keys, so these laws and those below hold of them); a key whose time has passed is there for no command, and the sweep of expired keys deletes no key that is there; GET, DEL, APPEND, SETRANGE, SETNX, INCR, GETDEL, PERSIST, PTTL, SET with KEEPTTL, RENAME, MSETNX and BITOP behave as specified, on keys of the types they take (SET, SETNX, the times and the key commands take any), a key they add counted; a pipelined batch runs exactly as its commands in order; the cache hints before a batch change nothing |
| Commuting | 5 | commands on different keys commute: replies and key contents are the same in either order, and adjacent independent commands in a batch can be swapped, when neither writes a key the other's writes depend on (RENAME moves a value from one key to another, MSETNX sets its keys only when none is there, BITOP sets its destination from its sources, LMOVE pushes onto its destination what it pops from its source, LMPOP pops from the first of its keys that is there, a STORE of a set operation sets its destination to what its sources make, SMOVE moves a member from its source to its destination, a STORE of a sorted-set operation or of a range sets its destination to what its sources or its source make, ZMPOP pops from the first of its keys that is there) |
| Persistence | 9 | logging changes no reply; the file reads back as written, times included; after any history, each batch at its own time, on any of the databases, the server restores exactly the databases it held; a file cut by a crash at any byte restores the databases after some prefix of its acts in which every transaction is whole, never a partial act or transaction; the start's replay, which first checks that each entry replays as written, is that replay whenever the check refuses none |
| Databases | 6 | SELECT changes no database and focuses the one it names; SWAPDB puts each of two databases in the other's place; FLUSHALL empties them all; MOVE takes a key's entry, its value and its time, out of the selected database and sets it in the other; COPY sets a key's entry at another key, in the selected database or another, when that key is not there or REPLACE is given |
| Key count | 2 | after any history, the counts every database keeps are its trie's own, how many keys it holds and how many of them have a time, and its trie holds each key once; so DBSIZE answers the number of keys in its trie |
| Sessions | 5 | however the server dispatches a batch, it runs as its commands in order; a batch changes the databases and the log as its executed commands do; a client that has not authenticated against a password cannot read or change any key |
| Configuration | 3 | a CONFIG SET that fails changes nothing; one that succeeds makes the new requirepass the password; after a CONFIG SET of a parameter, CONFIG GET finds the value its check gave |

`make check` takes about 15 s; `make verdict` rechecks every proof in the BendTT kernel
in about a minute.

**Trust boundary.** The proofs cover `src/map.bend`, `src/redis.bend`, `src/batch.bend`,
`src/aof.bend`, `src/session.bend` and `src/config.bend`. Trusted without proof: the Bend
compiler and its C runtime (with the patches), the RESP parser and the network shell
(`src/resp.bend`, `src/server.bend`, tested only), the start (`src/startup.bend`, tested
against `redis-server`), clang, libc and the OS. This is not
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
  used (Memory, below), each refused under the policy Redis refuses it under.
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
  long). A list is a deque of two stacks, so a push or a pop at either end costs O(1)
  amortized, and LINDEX and LRANGE walk from the nearer end; a key never holds an empty
  list. OBJECT ENCODING answers `quicklist`, as Redis 7.0 does for every list, and
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
  integers, at most 512 of them, and a trie of its own past that, for good, as Redis
  turns an intset into a hashtable: an intset answers its members in numeric order and
  scans whole with cursor 0, as Redis's does. OBJECT ENCODING answers `intset` or
  `hashtable`, MEMORY USAGE estimates a set's bytes, and a key never holds an empty set.
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
  with Redis's rules for infinities. A sorted set is one weight-balanced tree of its
  elements in Redis's order, by score and then member, and past a listpack's limits (128
  elements, members of 64 bytes) the same tree with a trie of its members, for good, as
  Redis turns a listpack into a skiplist: a small one answers as Redis's listpack does
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
  `dbAdd`), key by key in the order they became ready, where BendKV looks at every client
  after every command, in the order they came; WAIT and XREAD are not there. In a
  transaction a blocking command does not wait, as in Redis (below).
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
  connection unwatch. The calls are counted as Redis counts them (a queued command when
  EXEC runs it, EXEC once). The append-only file has a transaction's effects between a
  MULTI and an EXEC when they are two or more, as Redis writes them. Where BendKV
  differs: an LTRIM that removes nothing changes no watched key (Redis signals the key
  anyway), and a DEL of a key not there is logged (BendKV logs every DEL), so a
  transaction with one may be wrapped in MULTI and EXEC where Redis writes its one other
  effect alone.
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
  with AUTH and SETNAME), AUTH, SELECT, QUIT, RESET (which selects database 0 again, and
  RESP2),
  CLIENT (ID, GETNAME, SETNAME, REPLY ON/OFF/SKIP, NO-EVICT, GETREDIR, TRACKINGINFO,
  CACHING, UNBLOCK (TIMEOUT or ERROR), LIST, INFO, KILL, HELP), FUNCTION FLUSH. A client
  must authenticate where Redis asks it to: once a command's name and number of arguments
  are checked, before it runs (a syntax error is NOAUTH for a client that has not
  authenticated); a client is authenticated as it connects, and at RESET, when there is
  no password then, and by AUTH and HELLO's AUTH, and nothing else changes it.
- **Clients:** CLIENT LIST (all, of a TYPE, of IDs), CLIENT INFO and CLIENT KILL (the old
  form of an address, and the filters ID, TYPE, ADDR, LADDR, USER and SKIPME), as Redis
  7.0.15 runs them, with its errors. A client's line has Redis's fields in Redis's order:
  its id, address and local address, its socket's fd, its name, age and idle time, its
  flags (P subscribed, x in MULTI, b waiting, d a watched key touched, e NO-EVICT on, N
  none), database, counts of subscriptions, its queued commands, the bytes of the batch
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
  that gets messages, to a client that waited); user is `default`, redir -1, resp 2.
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
- **Configuration:** CONFIG GET (names, aliases and glob patterns), SET (several
  parameters at once, all or none), RESETSTAT, REWRITE, HELP, over all 178 parameters of
  Redis 7.0.15, taken from Redis's own table by `tools/gen_config.py`: every value is
  checked as Redis checks it and read back as Redis prints it. requirepass is the
  password, hz is capped as in Redis and notify-keyspace-events picks the events
  published (above); the port, the addresses, TLS and the append-only
  file cannot change while BendKV runs (a new value fails as it does when Redis cannot
  apply it); maxmemory and its policy, samples, tenacity and LFU parameters limit the
  memory and choose what is evicted (below); the other parameters are kept and read
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
  (CLIENT REPLY OFF); BendKV does not time its commands, so their usec is 0 and
  latencystats is empty. CONFIG RESETSTAT starts the counts again. COMMAND (with INFO, DOCS, COUNT, LIST and its
  filters, GETKEYS, GETKEYSANDFLAGS, HELP) describes each command BendKV has, and each
  subcommand it has, as Redis 7.0.15 describes it: `tools/gen_commands.py` takes the
  descriptions from Redis itself.
- **Memory:** maxmemory and its eviction, as Redis 7.0.15 runs them. With maxmemory set,
  BendKV reads what its heap's live values hold before each group of requests, as Redis
  measures before each command, and while that is past maxmemory it evicts keys by
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
  BendKV's heap (with its share of the trie's nodes) than in Redis's allocator; the uses
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
  `pidfile` act; what BendKV cannot do (modules, ACL users, renamed commands, the
  background, a cluster, a replica, TLS, a supervisor to signal, an RDB file or Redis 7's
  multi-part append-only file to load) stops the start with a line saying so.
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
  the start instead). A file with an entry the start cannot replay as it was written (an
  unknown command, a wrong number of arguments, an argument that does not read, a
  database not there, a MULTI inside another, an EXEC without one) stops the start,
  naming the entry and the byte it starts at, the file left as it was, where Redis stops
  at an unknown command. BGREWRITEAOF, and the cron's rewrites as the file grows
  (`auto-aof-rewrite-percentage`, `auto-aof-rewrite-min-size`), write the file again
  as Redis writes its base: the commands that make the databases as they are when it
  starts, then the entries appended meanwhile, into a temporary file renamed onto the
  file; without a fork, the databases being values, a slice at a time between the
  groups of requests the server answers meanwhile; with INFO's fields of a rewrite
  (FINDINGS.md, section 3zv).

Not yet: streams and the other types (HyperLogLog, geo), Lua
scripts, CLIENT PAUSE and TRACKING, timing of commands
(usec in INFO commandstats, latencystats), CONFIG REWRITE (it answers as Redis does without a configuration file),
RDB files. Integers, and times in ms, are limited to 14 digits.

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
sh bend-patches/apply.sh ../bend-patched      # Bend 2.0.35 + 31 patches
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
`send` picks how replies go out, `FILE` (any path) turns on the append-only file.

## Testing

```bash
make smoke     BEND="$B"   # the pure path end to end and the append-only file, no network; fails on any mismatch
make test      BEND="$B"   # needs redis-server, redis-cli and a C compiler
make perfcheck BEND="$B"   # instructions per request against a baseline (needs valgrind)
make gencheck              # the generated parts (trie, its proofs, the parameter and command tables) are up to date
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
refused, failed, held-back and protocol errors, compared as maps), COMMAND (each
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
edges, intsets on both sides of 512 members and hashtables of up to 20,000, moves and
STOREs onto keys whose time has passed, and at random, the members of a hashtable
compared as sets and each random pick checked against the set it came from), sorted sets
(each command at its edges, sorted sets of up to 20,000 elements on both sides of a
listpack's limits, STOREs and pops of keys whose time has passed, and at random, ZSCAN's
walk compared by its pairs and each random pick checked against the sorted set it came
from),
robustness and concurrency checks, a client that stops reading while the others are
served (`tests/writer_test.py`), clients that wait (`tests/blocking_test.py`: 18 scenarios
of the blocking commands on BendKV and on Redis, their transcripts compared line by line,
then 300 clients served at once, 100 timeouts at once, clients that leave while they wait,
and 50 consumers moving 1,000 items while some leave), transactions (`tests/multi_test.py`:
12 scenarios of MULTI, EXEC, DISCARD, WATCH and UNWATCH on BendKV and on Redis, their
transcripts compared line by line, then a counter raised by 20 clients with WATCH, each
lost race retried, a reader that never sees half of a transaction, and 100 clients that
leave in MULTI or with keys watched; random transactions in the differential test too),
Pub/Sub (`tests/pubsub_test.py`: scenarios of Pub/Sub and the events of 138 commands
on BendKV and on Redis, their transcripts compared line by line, then 20 subscribers that
each get the 2,000 messages of 4 publishers in order, and 50 subscribers that leave while
messages are published), CLIENT LIST, INFO and KILL (`tests/client_test.py`: scenarios on
BendKV and on Redis, their lines compared field by field with what differs by nature put
aside, then 100 clients listed and half of them killed by id, and 200 killed by address
while other clients connect and close, none killed but those named), MONITOR
(`tests/monitor_test.py`: scenarios on BendKV and on Redis, a monitor's lines compared
with their time and address put aside, then 4 monitors that each get every line of 20
clients that pipeline 200 SETs each, each client's lines in order), AUTH
(`tests/auth_test.py`: scenarios on BendKV and on Redis of when a client must
authenticate and what it is answered before it does), RESP3 (`tests/resp3_test.py`: 11
scenarios on BendKV and on Redis compared byte for byte, of HELLO and the switch of
protocol in a pipeline, the replies RESP3 types, EXEC, blocking commands and Pub/Sub's
pushes; and the differential tests of keys, numbers, BITFIELD and the types again with
every connection in RESP3, `RESP=3`),
connections that end every way one can, many times
(the client closing or resetting, QUIT, a protocol error), on a BendKV of their own whose
table of channels is read to show that each closed the channel it opened,
restarts from the append-only file (every database read back, including after a
truncated tail or a transaction left open), disk failures
under the file, injected with an `LD_PRELOAD` shim (the order of the file's creation,
its directory's sync and the first reply traced through it), files the start must
refuse, each left as it was, and the files both ways: BendKV
started from a file Redis wrote and Redis from one BendKV wrote, each holding the
databases the other held, and the rewrite of the file (`tests/rewrite_test.py`:
BGREWRITEAOF's replies and INFO's account against Redis's, the rewritten file against
Redis's base command for command, writes during a rewrite and a kill during one, the
cron's rewrites, rewrites that fail, BendKV and Redis started from the new file), and
maxmemory (`tests/maxmemory_test.py`: the refusals past it, OBJECT IDLETIME and FREQ
and the `evicted` event against Redis's, Redis's own tests of the policies on both, an
eviction that goes on alone, with the append-only file on and while a rewrite runs).
`make suite` runs Redis's own test suite in its mode for a server already started, on
Redis and on BendKV, and counts the tests Redis passes that BendKV passes
([docs/COMPATIBILITY.md](docs/COMPATIBILITY.md)). `make clients` runs the test suites of
two client libraries the same way, redis-py's in RESP2 and in RESP3 and go-redis's
(`tools/client_suite.py`); CI runs them on every pull request, and fails on a test Redis
passes that BendKV fails and that is not among the known failures of
`tools/data/clients.json`.

## Layout

```
src/        the server
  map.bend      hash trie with string keys                         verified
  float.bend    doubles and long doubles in software               tested
  redis.bend    command semantics: exec(cmd, db) -> (reply, db')   verified
  batch.bend    a pipelined batch with cache hints                 verified
  aof.bend      append-only file: effects, encoding, loading       verified
  session.bend  connection and server state, whole batches         verified
  config.bend   the parameters, CONFIG GET and SET                 verified
  resp.bend     RESP parser, RESP2 and RESP3 reply encoders         tested
  info.bend     INFO's sections and fields                         tested
  command.bend  COMMAND, with Redis's table of BendKV's commands     tested
  startup.bend  the command line and the configuration file        tested
  server.bend   TCP, connections, the database actor, the log      tested
proof/      LAWS.bend (the laws), PROOF.bend (their proofs), SPEC.bend (the commands on the trie alone)
tests/      float, start, differential, expiry, protocol, session, CONFIG, INFO, COMMAND, SCAN, BITFIELD, hash, list, set, sorted set, blocking, transaction, Pub/Sub, CLIENT, MONITOR, AUTH, RESP3, maxmemory, robustness, stalled reader, concurrency, AOF and AOF rewrite tests
bench/      in-process benchmarks of the map, the core and channels
tools/      measurement scripts, the runner of Redis's test suite, and the generators of
            the trie, of the parameter table and of the command table, with the facts
            they take from Redis (tools/data/)
bend-patches/  the 31 patches to the Bend compiler and runtime
docs/       FINDINGS.md, DIRECTIONS.md, COMPATIBILITY.md, PERFORMANCE.md
```

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
