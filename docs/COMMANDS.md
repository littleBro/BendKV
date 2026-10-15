# BendKV's commands in detail

This page describes what BendKV's commands do, area by area: their options and edge cases,
how a write is logged in the append-only file, and where a command is much slower than in
Redis. The [README](../README.md#what-works) has the overview.

**The rule.** A command takes the arguments Redis 7.0.15 takes, refuses what Redis refuses
with the same error at the same point, and answers byte for byte as Redis does. Everything
on this page is within that rule. The exceptions are listed in the README, under
[Where BendKV differs](../README.md#where-bendkv-differs), grouped under the same headings
as here. `make test` holds BendKV to the rule against a real `redis-server`
([tests/README.md](../tests/README.md)).

**Encodings.** BendKV keeps its own data structures, not Redis's listpacks, intsets and
skiplists, but OBJECT ENCODING answers what Redis would for the same value (each type's
section says how).

**Logging.** The append-only file holds what a write did, which is not always what the
client sent: Redis does the same for many commands (INCRBYFLOAT is logged as a SET, for
example). The file stays one that Redis loads, and BendKV loads Redis's
([The append-only file](#the-append-only-file)).

**Contents**

- Data: [Strings and keys](#strings-and-keys) · [Times to live](#times-to-live) ·
  [Floats](#floats) · [Ranges and bits](#ranges-and-bits) · [Hashes](#hashes) ·
  [Lists](#lists) · [Sets](#sets) · [Sorted sets](#sorted-sets) · [SORT](#sort) ·
  [HyperLogLogs](#hyperloglogs) · [GEO](#geo) · [DUMP and RESTORE](#dump-and-restore) ·
  [Databases](#databases)
- Waiting, transactions and messages: [Clients that wait](#clients-that-wait) ·
  [Transactions](#transactions) ·
  [Pub/Sub and keyspace notifications](#pubsub-and-keyspace-notifications)
- Connections and clients: [Connections](#connections) ·
  [CLIENT LIST, INFO and KILL](#client-list-info-and-kill) ·
  [CLIENT PAUSE and UNPAUSE](#client-pause-and-unpause) · [MONITOR](#monitor)
- The server: [Server commands](#server-commands) · [Configuration](#configuration) ·
  [INFO and COMMAND](#info-and-command) · [SLOWLOG and LATENCY](#slowlog-and-latency) ·
  [Memory and eviction](#memory-and-eviction)
- Starting and persistence: [Starting](#starting) · [Protocol](#protocol) ·
  [The append-only file](#the-append-only-file)
- [Not yet](#not-yet)

## Strings and keys

GET, SET, SETNX, GETSET, MGET, MSET, MSETNX, APPEND, STRLEN, INCR, DECR, INCRBY, DECRBY;
DEL, UNLINK, EXISTS, TYPE, TOUCH, RENAME, RENAMENX, COPY, DBSIZE, KEYS, SCAN, RANDOMKEY,
OBJECT. SET's options and the other commands of times are under
[Times to live](#times-to-live).

- **Integers.** INCR, DECR, INCRBY and DECRBY work on Redis's long longs (64-bit signed
  integers), and refuse a result that overflows one, as Redis does.
- **Renames and copies.** RENAME and RENAMENX move the key's time with it. COPY takes DB
  and REPLACE, and copies the key's time too.
- **KEYS** takes Redis's patterns (`*`, `?`, `[...]` classes, `\` escapes) and matches
  them as Redis's `stringmatchlen` does, with its cut-offs, which keep a pattern's cost
  polynomial, and its limit of 1000 nested stars, past which nothing matches.
- **SCAN** takes MATCH, COUNT and TYPE, and keeps Redis's guarantee: a key that is there
  for the whole iteration is found, however the database changes meanwhile. Its cursors
  are BendKV's own.
- **RANDOMKEY** picks a key the way Redis picks one.
- **OBJECT** takes ENCODING, REFCOUNT, IDLETIME, FREQ and HELP.
  - ENCODING and REFCOUNT answer from the value. ENCODING answers as Redis encodes a
    value set whole: `int` for an integer, `embstr` up to 44 bytes, `raw` past that.
    REFCOUNT follows Redis's shared integers under the current eviction policy.
  - IDLETIME and FREQ answer from when the key was last used
    ([Memory and eviction](#memory-and-eviction)). Each is refused under the eviction
    policies Redis refuses it under.

## Times to live

EXPIRE, PEXPIRE, EXPIREAT and PEXPIREAT (with NX, XX, GT and LT), TTL, PTTL, EXPIRETIME,
PEXPIRETIME, PERSIST; SET with NX, XX, GET, EX, PX, EXAT, PXAT and KEEPTTL; SETEX, PSETEX,
GETEX (EX, PX, EXAT, PXAT, PERSIST) and GETDEL.

- Times are read as Redis reads them, with its errors, and a key expires at its time for
  every command.
- A key whose time has passed is deleted when a write comes to it, or by the sweep of
  expired keys, which runs ten times a second and logs a DEL, as Redis logs it. Until
  then DBSIZE and INFO's keyspace still count it.
- Times are kept in milliseconds, to 14 digits: a time at or past 10^14 ms (the year
  5138) gives a key no time at all.

## Floats

INCRBYFLOAT and HINCRBYFLOAT compute as Redis 7.0.15 does on x86-64:

1. the value and the increment are read as glibc's `strtold` reads them;
2. they are added as x87 long doubles;
3. the sum is written with `"%.17Lf"`, the trailing zeros of its fraction removed.

A sum that is not finite is refused.

Bend has only a 32-bit float, so `src/float.bend` implements C's `double` and x87's
`long double` in software: reading them as `strtod` and `strtold` do, writing them as
`"%.17g"` and `"%.17Lf"` do, and adding and multiplying them, each result rounded to
nearest as the FPU rounds it. `make test` checks it against glibc on random numbers.

**Append-only file:** INCRBYFLOAT is logged as a SET of the sum with KEEPTTL, and
HINCRBYFLOAT as an HSET of the field, as Redis propagates them.

## Ranges and bits

GETRANGE (and SUBSTR), SETRANGE, GETBIT, SETBIT, BITCOUNT and BITPOS (with BYTE and BIT
ranges), BITOP (AND, OR, XOR, NOT), LCS, BITFIELD and BITFIELD_RO.

- Numbers are read, and errors given, where and as Redis reads and gives them. A value
  grows to 512 MB at most (`proto-max-bulk-len` at its default).
- **LCS** takes LEN, IDX, MINMATCHLEN and WITHMATCHLEN. Its table is bounded by
  `proto-max-bulk-len`, as in Redis. It is slow: about twenty times Redis's time.
- **BITFIELD and BITFIELD_RO** take fields of up to 64 bits, signed or unsigned, at a
  bit offset or at `#k`, with GET, SET, INCRBY and OVERFLOW WRAP, SAT or FAIL, in C's
  wrapping arithmetic, as Redis's. A field that crosses bit 2^32 is refused with
  SETRANGE's error.

**Append-only file:** SETRANGE and SETBIT are logged as a SETRANGE of the bytes they
wrote, not of the whole value; BITOP as a SET of its result; BITFIELD as a SETRANGE of the
bytes its writes reach.

## Hashes

HSET, HMSET, HSETNX, HGET, HMGET, HDEL, HLEN, HSTRLEN, HEXISTS, HKEYS, HVALS, HGETALL,
HINCRBY, HINCRBYFLOAT, HSCAN (MATCH, COUNT) and HRANDFIELD (a count, which repeats fields
when negative, and WITHVALUES).

- HRANDFIELD picks with the server's random numbers.
- **Small and large hashes.** A hash keeps its fields in the order they came while it is
  small: at most 512 fields, and values of at most 64 bytes, Redis's listpack defaults.
  Past that it moves to a trie of its own, for good, as Redis turns a listpack into a
  hash table. A small hash is scanned whole with cursor 0, a large one bucket by bucket.
  OBJECT ENCODING answers `listpack` or `hashtable`, as Redis would under the current
  parameters.
- Every command of strings answers WRONGTYPE for a hash, and every command of hashes for
  a string.
- MEMORY USAGE (with SAMPLES) estimates a hash's bytes.

**Append-only file:** a write is logged as an HSET of the pairs it set or an HDEL of the
fields it removed; HINCRBY and HINCRBYFLOAT as an HSET of the result. A hash created on a
key whose time had passed, while that key's old entry was still there, is logged as one
EVAL of a fixed script that deletes the key and sets the pairs. Redis runs the script
when it loads the file, and BendKV reads it back. (Redis itself logs a MULTI with a DEL
and the HSET: two entries that a crash could separate.) BendKV runs no other Lua than
this script and the similar ones of lists, sets and sorted sets below.

## Lists

LPUSH, RPUSH, LPUSHX, RPUSHX, LPOP and RPOP (with a count), LLEN, LINDEX, LRANGE, LSET,
LINSERT, LREM, LTRIM, LPOS (RANK, COUNT, MAXLEN), LMOVE, RPOPLPUSH and LMPOP. The blocking
forms are under [Clients that wait](#clients-that-wait).

- Arguments and errors are read where and as Redis 7.0.15 reads them: a count or an index
  may be any long long, and LPOS takes a RANK of LLONG_MIN as Redis 7.0.15 does.
- A list is a deque of two stacks: a push or a pop at either end costs O(1) amortized,
  and LINDEX and LRANGE walk from the nearer end.
- A key never holds an empty list.
- OBJECT ENCODING answers `quicklist`, as Redis 7.0 does for every list. MEMORY USAGE
  estimates a list's bytes.

**Append-only file:** a write is logged as itself, except that LMPOP is logged as the
LPOP or RPOP (with its count) of the key it took from, and a pop of the last elements as
a DEL of the key. A list created on a key whose time had passed is logged as an EVAL of
the hash's script with the pushes, and a move onto such a key as one EVAL of a fixed
script that deletes the destination and runs the LMOVE. Redis runs these scripts when it
loads the file, and BendKV reads them back.

## Sets

SADD, SREM, SCARD, SISMEMBER, SMISMEMBER, SMEMBERS, SSCAN (MATCH, COUNT), SPOP and
SRANDMEMBER (with a count, which repeats members when negative), SMOVE, SINTER, SUNION,
SDIFF, SINTERSTORE, SUNIONSTORE, SDIFFSTORE and SINTERCARD (LIMIT).

- SPOP and SRANDMEMBER pick with the server's random numbers, in Redis's ways of
  picking.
- **Small and large sets.** A set is an intset while its members are canonical 64-bit
  integers, at most 512 of them. Past that it moves to a trie of its own, for good, as
  Redis turns an intset into a hash table. An intset answers its members in numeric
  order and is scanned whole with cursor 0, as Redis's is. OBJECT ENCODING answers
  `intset` or `hashtable`, and MEMORY USAGE estimates a set's bytes.
- A key never holds an empty set.

**Append-only file:** a write is logged as the SADD or SREM it made. SPOP is logged as
an SREM of the members it took, or a DEL of the key when it took the last ones; a STORE as
an SADD of the members it made, or a DEL of its destination when there are none. A set
created where a key held an entry (a STORE's destination, or a key whose time had
passed) is logged as an EVAL of the hash's script with the SADD, and an SMOVE onto a key
whose time had passed as one EVAL of a third fixed script, which deletes the destination
and runs the SMOVE.

## Sorted sets

ZADD (NX, XX, GT, LT, CH, INCR), ZINCRBY, ZREM, ZCARD, ZSCORE, ZMSCORE, ZRANK, ZREVRANK,
ZCOUNT, ZLEXCOUNT, ZRANGE (BYSCORE, BYLEX, REV, LIMIT, WITHSCORES), ZRANGEBYSCORE,
ZREVRANGEBYSCORE, ZRANGEBYLEX, ZREVRANGEBYLEX, ZREVRANGE, ZREMRANGEBYRANK,
ZREMRANGEBYSCORE, ZREMRANGEBYLEX, ZPOPMIN and ZPOPMAX (with a count), ZMPOP, ZRANDMEMBER
(a count, which repeats members when negative, and WITHSCORES), ZSCAN, ZUNION, ZINTER,
ZDIFF, ZUNIONSTORE, ZINTERSTORE, ZDIFFSTORE, ZINTERCARD (LIMIT) and ZRANGESTORE. The
blocking forms are under [Clients that wait](#clients-that-wait).

- ZRANDMEMBER picks with the server's random numbers.
- Scores are doubles, read, written, compared and added as C does it (`src/float.bend`),
  with Redis's rules for infinities.
- **Small and large sorted sets.** A sorted set is one weight-balanced tree of its
  elements, in Redis's order: by score, then by member. Past a listpack's limits (128
  elements, members of 64 bytes) it also gets a trie of its members, for good, as Redis
  turns a listpack into a skiplist. A small one answers as Redis's listpack does: it
  keeps no `-0` score, walks a range by member from its first element, answers ZSCAN
  whole with cursor 0, and writes integer scores as digits. OBJECT ENCODING answers
  `listpack` or `skiplist`, and MEMORY USAGE estimates a sorted set's bytes.
- A key never holds an empty sorted set.

**Append-only file:** a write is logged as the command the client sent, in a normal
form: ZINCRBY as ZADD INCR, ZADD's options in one order, ZMPOP as the ZPOPMIN or ZPOPMAX
of the key it took from, and the removal of the last elements as a DEL. A sorted set
created where a key held an entry (a STORE's destination, or a key whose time had
passed) is logged as one EVAL of a fourth fixed script, which deletes the key and runs
the ZADD of its elements.

## SORT

SORT and SORT_RO, with BY, LIMIT, GET, ASC, DESC, ALPHA and, for SORT, STORE.

- Options are read in order, and errors are given where and as Redis gives them, all
  before WRONGTYPE.
- SORT sorts a list, a set or a sorted set; a key that is not there sorts as an empty
  list.
- **Numbers** (the default): elements are read as doubles, as Redis reads them with
  `strtod` (blanks before the number, nothing after it, no overflow, no NaN), and ties
  are broken by the elements' bytes.
- **ALPHA**: elements are compared by their bytes up to the first NUL, as `strcoll`
  compares in the C locale; with STORE, by all their bytes, as Redis then compares.
- **BY** with a pattern weighs each element by the string at the key its first `*`
  names, or by a hash's field after `->`; a weight that is not there counts as 0 (or
  comes first, with ALPHA). BY without a `*` leaves a list or a sorted set in its order
  (reversed by DESC), and a set in its own order, which a STORE sorts ALPHA, as Redis
  does.
- **GET** answers the element itself (`#`) or what a pattern names, and a null where
  nothing is there (an empty string, in a STORE).
- The sort is a merge sort, stable as glibc's `qsort`, which Redis calls. It takes two to
  six times Redis's instructions for 1,000 elements
  ([PERFORMANCE.md](PERFORMANCE.md), section 57).
- **STORE** writes the result over its destination as a new list (the `sortstore`
  event), or deletes the destination when there is nothing to store (`del`), and answers
  the count.

**Append-only file:** SORT with STORE is logged as the list it wrote: an RPUSH of its
elements, or the EVAL of the lists' script onto a key that is there. A file that Redis
wrote holds the SORT itself, and BendKV runs it again when it loads the file.

## HyperLogLogs

PFADD, PFCOUNT, PFMERGE, PFDEBUG (GETREG, DECODE, ENCODING, TODENSE) and PFSELFTEST, as
Redis 7.0.15's `hyperloglog.c` runs them, on the bytes of a string:

- Redis's header and registers, dense or sparse, every value written byte for byte as
  Redis writes it: the sparse opcodes split and merged as `hllSparseSet` does, the switch
  to dense past 3,000 bytes or for a register past 32, PFMERGE's sparse result, and the
  count kept in the header and made stale by a change.
- The count is Ertl's estimator as Redis computes it, on doubles in software.
- A string that is not a HyperLogLog answers Redis's WRONGTYPE, and a corrupt sparse one
  INVALIDOBJ, as Redis 7.0.15 judges it with the fix for CVE-2025-32023 (as Ubuntu ships
  it).
- They cost more than in Redis: PFADD takes four to six times Redis's instructions, a
  PFCOUNT that has to count 13 to 18 times (2.6 times on two dense HyperLogLogs), and
  PFMERGE 1.2 to 2.4 times ([PERFORMANCE.md](PERFORMANCE.md), section 59).

**Append-only file:** PFADD, PFCOUNT of one key and PFDEBUG are logged as the changes
they make (a SET, a SET with KEEPTTL, or a SETRANGE of the count kept in the header), and
PFMERGE as a SET of its destination. A file that Redis wrote holds the PF commands
themselves, and BendKV runs them again when it loads the file.

## GEO

GEOADD, GEOPOS, GEOHASH, GEODIST, GEORADIUS and GEORADIUSBYMEMBER with their `_RO`
forms, GEOSEARCH and GEOSEARCHSTORE, as Redis 7.0.15's `geo.c` runs them:

- A position is a member of a sorted set whose score is its 52-bit geohash, and GEOADD
  is the ZADD of those scores (it is logged as that ZADD).
- A search reads the cells Redis reads, keeps the points within its circle or box by
  their haversine distances, and sorts them as glibc's `qsort` does, or step by step as
  Redis's `pqsort` does when COUNT keeps fewer than it found, so that points at the same
  distance come in Redis's order.
- Each point is written with Redis's text: a distance with four decimals, a coordinate
  with `%.17Lf`.
- The doubles are C's: Bend's base runs them natively (patch 33), on the C library's
  libm, so a distance is the double Redis computes with the same libm.
- The options, their errors and the order they come in are those of Redis's
  `georadiusGeneric`. STORE, STOREDIST and GEOSEARCHSTORE write their destination as a
  sorted set, or delete it when they find nothing, with Redis's keyspace events.
- A search takes 2.5 to 4 times Redis's time, 7 times with WITHCOORD (the software float
  library writes each coordinate), and 13 times with COUNT's partial sort
  ([PERFORMANCE.md](PERFORMANCE.md), section 60).

## DUMP and RESTORE

- **DUMP** writes a value's payload as Redis 7.0.15 writes it with `rdbcompression no`:
  the value as RDB encodes it (a listpack, an intset or a quicklist of listpacks where
  Redis keeps one), then version 10 of the format and the CRC64. Where both servers hold
  a value the same way, the payload is Redis's byte for byte.
- **RESTORE** reads every type Redis 7.0.15 reads except streams and modules' types,
  including the encodings Redis no longer writes: LZF-compressed strings, ziplists,
  zipmaps and quicklists of ziplists. It checks a payload as deeply as Redis does with
  `sanitize-dump-payload yes`, and takes REPLACE, ABSTTL, IDLETIME and FREQ, with Redis's
  errors in Redis's order and its keyspace events.
- A value of 100,000 elements takes 3 to 38 times Redis's time to dump or restore, less
  than the commands that make it ([FINDINGS.md](FINDINGS.md), section 3zzu;
  [PERFORMANCE.md](PERFORMANCE.md), section 62).

**Append-only file:** RESTORE is logged with REPLACE and ABSTTL.

## Databases

16 databases, or as many as `databases` says, as in Redis: SELECT, MOVE (the key with
its time), SWAPDB, FLUSHDB and FLUSHALL (with ASYNC or SYNC; both empty at once), with
Redis's errors for a bad number.

- INFO's keyspace has a line for each database that holds keys.
- The sweep of expired keys goes over every database.

## Clients that wait

BLPOP, BRPOP, BLMOVE, BRPOPLPUSH, BLMPOP, BZPOPMIN, BZPOPMAX and BZMPOP.

- **Timeouts** are in seconds, as a double, and 0 waits for ever. They are read as Redis
  reads them, with its errors.
- A command that finds nothing to pop makes its client wait, and its call is counted
  then, as in Redis. The commands the client sent after it wait with it, and run once it
  is served.
- After each command, the waiting clients are served in the order they came, as long as
  a key one of them waits on holds what it waits for. The pop is made on that key and
  logged as the command that makes it: LPOP or RPOP with its count, LMOVE, ZPOPMIN or
  ZPOPMAX.
- A client whose time is up gets a null array at the next tick of the cron (Redis's
  precision too). CLIENT UNBLOCK ends a wait with a null array (TIMEOUT) or an UNBLOCKED
  error (ERROR). A client that closes its connection while it waits is forgotten.
- INFO's `blocked_clients` and `clients_in_timeout_table` count the waiting clients, and
  failed calls and errors are counted as Redis counts them.
- A command run while replies are off (CLIENT REPLY OFF or SKIP) pops as it does with
  them on.
- In a transaction a blocking command does not wait, as in Redis
  ([Transactions](#transactions)).
- A waiting client costs nothing to the commands on other keys
  ([PERFORMANCE.md](PERFORMANCE.md), section 61).
- XREAD is missing, as there are no streams, and WAIT's wait ends only at its timeout or
  by CLIENT UNBLOCK ([Server commands](#server-commands)).

## Transactions

MULTI, EXEC, DISCARD, WATCH and UNWATCH, as Redis 7.0.15 runs them.

- **Queuing.** After MULTI a command is queued (QUEUED), except EXEC, DISCARD, MULTI (an
  error: transactions do not nest), WATCH (an error inside MULTI), QUIT and RESET, which
  run. A command refused as it is queued (an unknown command, a wrong number of
  arguments, NOAUTH) makes EXEC answer EXECABORT, and an EXEC that is itself refused
  aborts the transaction, with its reason.
- **EXEC** runs the queued commands as one: their replies are its array (with any error a
  command meets as it runs), no waiting client is served between them, and a blocking
  command among them answers at once.
- **WATCH.** A watched key that any command changes, or that is there with its time
  passed when EXEC comes, makes EXEC answer a null array. A change is what Redis counts
  as one: a write that changes the key, a DEL of a key that is there, FLUSHDB, FLUSHALL
  and SWAPDB of a database that holds it, MOVE, COPY, RENAME, and the sweep of expired
  keys. A key watched after its time passed changes only when it is set again; its
  deletion is no change. EXEC, DISCARD, UNWATCH, RESET and a closed connection unwatch
  every key.
- A watched key costs nothing to the commands on other keys
  ([PERFORMANCE.md](PERFORMANCE.md), section 61).
- Calls are counted as Redis counts them: a queued command when EXEC runs it, and EXEC
  once.

**Append-only file:** a transaction's effects go between a MULTI and an EXEC when there
are two or more, as Redis writes them.

## Pub/Sub and keyspace notifications

SUBSCRIBE, UNSUBSCRIBE, PSUBSCRIBE, PUNSUBSCRIBE, SSUBSCRIBE, SUNSUBSCRIBE, PUBLISH,
SPUBLISH and PUBSUB (CHANNELS, NUMSUB, NUMPAT, SHARDCHANNELS, SHARDNUMSUB, HELP), as
Redis 7.0.15 runs them.

- Each name subscribed or unsubscribed is answered with the client's count of channels
  and patterns (of shard channels, for SSUBSCRIBE and SUNSUBSCRIBE).
- A message goes to its channel's subscribers (as `message`, or `smessage` for a shard
  channel), then to the subscribers of each pattern it matches (`pmessage`). PUBLISH
  answers how many clients got it.
- **RESP2 and RESP3.** A subscribed client of RESP2 may run only (P|S)SUBSCRIBE,
  (P|S)UNSUBSCRIBE, PING, QUIT and RESET, as in Redis; any other command is refused with
  Redis's error. A client of RESP3 may run any command, and gets its messages as pushes
  among its replies: its own messages and keyspace events come before the reply of the
  command that made them, as Redis writes them.
- The replies of SUBSCRIBE and its kin go out even with replies off.
- In a transaction, SUBSCRIBE and PSUBSCRIBE run and SSUBSCRIBE is refused.
- RESET, QUIT and a closed connection drop the client's subscriptions.
- **Keyspace notifications.** With `notify-keyspace-events` set, each change a command
  makes is published to `__keyspace@<db>__:<key>` and `__keyevent@<db>__:<event>`, with
  Redis's names of the events: `new` for a key created, `del` for a collection emptied,
  `expired` from the sweep, `evicted` from an eviction, and the pop of a waiting client
  after the write that served it.

## Connections

PING, ECHO, TIME, HELLO (2 or 3, with AUTH and SETNAME), AUTH, SELECT, QUIT, RESET, CLIENT
(ID, GETNAME, SETNAME, REPLY ON/OFF/SKIP, NO-EVICT, GETREDIR, TRACKINGINFO, CACHING,
UNBLOCK with TIMEOUT or ERROR, LIST, INFO, KILL, PAUSE, UNPAUSE, HELP) and FUNCTION FLUSH.

- TIME answers the time the batch runs at, to the millisecond.
- RESET selects database 0 again, and goes back to RESP2.
- FUNCTION FLUSH answers OK: BendKV has no functions to flush, and Redis's test suite
  sends it to empty a server.
- **Authentication.** A client must authenticate where Redis asks it to: after the
  command's name and number of arguments are checked, before it runs. So a syntax error
  is NOAUTH for a client that has not authenticated. A client is authenticated when it
  connects and at RESET, if there is no password then, and by AUTH and HELLO's AUTH;
  nothing else changes it.

## CLIENT LIST, INFO and KILL

CLIENT LIST (all, of a TYPE, of IDs), CLIENT INFO and CLIENT KILL (the old form with an
address, and the filters ID, TYPE, ADDR, LADDR, USER and SKIPME), as Redis 7.0.15 runs
them, with its errors.

- A client's line has Redis's fields in Redis's order: its id, address and local address,
  its socket's fd, its name, age and idle time, its flags, its database, its counts of
  subscriptions, its queued commands, the bytes of its batch and of the arguments of the
  command that runs (of the blocking command, for a client that waits), the full name of
  its last command (the blocking one while it waits; EXEC, for a client in MULTI, while
  EXEC runs), and its protocol (`resp=2` or `resp=3`).
- The flags: `P` subscribed, `x` in MULTI, `b` waiting, `d` a watched key touched, `e`
  NO-EVICT on, `O` a monitor, `N` none.
- A killed client is cut off at once, wherever it waits: its socket is shut down, its
  transaction, wait and subscriptions are dropped, and what it waited for is left as it
  was. The old form, and SKIPME no, kill the client that asks too, after its reply (in a
  transaction, after the rest of the transaction).

## CLIENT PAUSE and UNPAUSE

As Redis 7.0.15 runs them.

- A pause holds back the commands that write or may be replicated (WRITE: PFCOUNT and
  PUBLISH too, and an EXEC whose transaction queued one), or every command (ALL), for a
  timeout in milliseconds. A second pause keeps the more restrictive kind and the later
  end.
- A command the pause holds back, once Redis's checks before it have passed and before
  MULTI queues it, waits with the rest of its client's batch (flag `b` in CLIENT LIST,
  counted in INFO's `blocked_clients`). It runs when the pause ends, at CLIENT UNPAUSE or
  at its timeout, with the clients going on in the order they came. A monitor is never
  held back.
- While the pause holds, keys are neither swept as they expire nor evicted, as Redis
  keeps the data set still.

## MONITOR

As Redis 7.0.15 runs it.

- Each call that runs after MONITOR, from any client, sends every monitor a line:
  `+<seconds>.<microseconds> [<db> <ip:port>]` and the call's arguments as the client
  sent them, quoted as Redis quotes them.
- As in Redis, no line is sent for a command refused before it runs (unknown, a wrong
  number of arguments, before AUTH, to a subscribed client), for the administrative
  commands (CONFIG, CLIENT LIST, KILL, NO-EVICT and UNBLOCK), or for EVAL. A queued
  command sends its line as EXEC runs it, and a blocking command as it blocks. AUTH's
  password and HELLO's user and password show as `"(redacted)"`.
- A monitor is refused the commands that read or write keys ("ERR Replica can't interact
  with the keyspace"). It gets its own line after its reply, and no line with CLIENT
  REPLY OFF or SKIP. RESET, QUIT and CLIENT KILL end it, and CLIENT LIST shows it with
  the flag `O`.

## SLOWLOG and LATENCY

As Redis 7.0.15 keeps them.

- **Timing.** The server reads the clock around each batch of requests it runs (Redis
  reads it around each call), and the calls of a batch share its time.
- **The slow log** (SLOWLOG GET, LEN, RESET, HELP; `slowlog-max-len` entries). A call
  that takes `slowlog-log-slower-than` µs or more is logged with its arguments as its
  client sent them, cut as Redis cuts them, with the secrets of AUTH, HELLO and CONFIG SET
  redacted. EXEC's commands are logged, but not EXEC; a blocking command is logged when
  it is served.
- **The latency monitor** (LATENCY LATEST, HISTORY, RESET, GRAPH, DOCTOR, HELP). With
  `latency-monitor-threshold` set, a call that takes that many milliseconds is a sample
  of the event `command` (or `fast-command`), and a sweep of expired keys by the cron one
  of `expire-cycle`. LATENCY HISTOGRAM shows each command's histogram.

## Server commands

- **LASTSAVE** answers the time the server started, as BendKV writes no RDB snapshot.
- **ROLE** answers a master with no replica.
- **WAIT** answers 0, as no replica acknowledges: at once when it asks for none, and
  otherwise when its timeout ends, its client waiting meanwhile as a blocking command's
  does.
- **MEMORY** STATS, DOCTOR, PURGE and MALLOC-STATS answer with Redis's fields and advice,
  from the numbers INFO's memory section shows. MEMORY USAGE (with SAMPLES) estimates a
  key's bytes.
- **LOLWUT** prints Redis 7.0.15's line and the drawings of VERSION 5 and 6; those that
  take no random number are Redis's byte for byte. Its large drawings take up to a
  hundred times Redis's time ([FINDINGS.md](FINDINGS.md), section 3zzl).
- **SHUTDOWN** [NOSAVE|SAVE] [NOW] [FORCE] [ABORT], read as Redis 7.0.15 reads it, writes
  and syncs the append-only file, stops a rewrite that runs, removes the pid file, and
  ends the process with code 0.
- **BGREWRITEAOF** is under [The append-only file](#the-append-only-file).

## Configuration

CONFIG GET (names, aliases and glob patterns), CONFIG SET (several parameters at once,
all or none), CONFIG RESETSTAT, CONFIG REWRITE and CONFIG HELP, over every parameter of
Redis 7.0.15 (counted in the README's [In numbers](../README.md#in-numbers)).
`tools/gen_config.py` takes the parameters from Redis's own table: every value is checked
as Redis checks it and read back as Redis prints it.

- `requirepass` is the password, `hz` is capped as in Redis, and `notify-keyspace-events`
  picks the events published.
- `maxmemory` and its policy, samples, tenacity and LFU parameters limit the memory and
  choose what is evicted ([Memory and eviction](#memory-and-eviction)).
- The port, the addresses, TLS and the append-only file cannot change while BendKV runs:
  a new value fails as it does when Redis cannot apply one.
- The other parameters are kept and read back, but tune nothing, since BendKV has no
  replication or encodings for them to tune.
- CONFIG REWRITE answers as Redis does when it runs without a configuration file.

## INFO and COMMAND

- **INFO** has Redis 7.0.15's sections and fields, in Redis's order, picked as Redis
  picks them (none, `default`, `all`, `everything`, any names in any case): server,
  clients, memory, persistence, stats, replication, CPU, modules, errorstats, cluster,
  keyspace.
  - The values are BendKV's own where it has them: its process, its parameters, its
    connections, commands and bytes (the instantaneous rates sampled every 100 ms, as
    Redis's cron samples them), its memory, its keys, its evictions, its append-only file.
    `used_memory` is what the live values of BendKV's heap hold, as Redis's is what its
    allocator handed out ([Memory and eviction](#memory-and-eviction)).
  - For what BendKV does not have (replication, forks, scripts), the values are those
    Redis shows when it has none.
- **Statistics per command** count as Redis counts them: each command's and subcommand's
  calls; the calls refused before they run (a wrong number of arguments by Redis's arity,
  a client that must authenticate first, a command refused for memory); the calls that
  fail as they run; and the error replies by their code, held-back replies included
  (CLIENT REPLY OFF). What each call took goes to its command's `usec` and, with
  `latency-tracking`, to its histogram (`latencystats`, at the percentiles of
  `latency-tracking-info-percentiles`), as Redis keeps them
  ([SLOWLOG and LATENCY](#slowlog-and-latency)). CONFIG RESETSTAT starts the counts again.
- **COMMAND** (INFO, DOCS, COUNT, LIST and its filters, GETKEYS, GETKEYSANDFLAGS, HELP)
  describes each command and subcommand BendKV has, as Redis 7.0.15 describes it:
  `tools/gen_commands.py` takes the descriptions from Redis itself.

## Memory and eviction

`maxmemory` and its eviction, as Redis 7.0.15 runs them.

- **Measuring.** With `maxmemory` set, BendKV reads what the live values of its heap hold
  before each group of requests, as Redis measures before each command.
- **Evicting.** While that is past `maxmemory`, BendKV evicts keys by
  `maxmemory-policy`:
  - the LRU, LFU and `volatile-ttl` policies take them from a pool of the 16 best
    candidates of their samples (`maxmemory-samples` keys of each database), kept from
    one eviction to the next;
  - the random policies take a key of each database in turn;
  - the volatile policies take only keys with a time.
- An evicted key is deleted as an expired one is: a DEL in the append-only file, its
  WATCHes touched, an `evicted` keyspace event, and a count in INFO's `evicted_keys`.
- Past the time `maxmemory-eviction-tenacity` allows, the eviction goes on between groups
  of requests, as Redis's goes on from its event loop. Evicting many keys at once is
  about ten times slower than in Redis.
- **Out of memory.** With nothing it may evict, the commands that may take memory get
  Redis's OOM error, and so does any command a client queues in MULTI; EXEC aborts a
  transaction that queued one.
- A CONFIG SET of `maxmemory` evicts at once, with Redis's warning when the memory is
  past the new value. INFO shows how long the memory has been past it
  (`total_eviction_exceeded_time`, `current_eviction_exceeded_time`).
- **Last use.** A key's use is kept as Redis keeps it: by its LRU clock (in seconds) or
  its LFU counter (logarithmic, with `lfu-log-factor`, decayed by `lfu-decay-time`).
  OBJECT IDLETIME and FREQ answer from it.

## Starting

BendKV starts as `redis-server` starts.

- It reads a configuration file, `--name value` options, and `-` for the standard input,
  line by line as Redis reads them: includes, `dir` changing the directory at once, save
  points that add up, and the same errors at the same lines.
- It logs in Redis's form, to the standard output or to `logfile`.
- These parameters act: the port, `bind` (IPv4), `requirepass`, `protected-mode`, the
  append-only file (`appendonly`, `appendfilename`, `appendfsync`,
  `aof-load-truncated`), `logfile`, `loglevel` and `pidfile`.
- What BendKV cannot do stops the start, with a line saying so: modules, ACL users,
  renamed commands, running in the background, a cluster, a replica, TLS, a supervisor
  to signal, and loading an RDB file or Redis 7's multi-part append-only file.

The README's [Building and running](../README.md#building-and-running) shows the command
line.

## Protocol

- RESP2 and RESP3 (HELLO 3), pipelining, partial packets, inline commands with quoting,
  and binary-safe values.
- Requests are framed as Redis 7.0.15 frames them: a length is read as `string2ll` reads
  it, with no `0` before its first digit; a count of 0 or less is skipped, down to
  -2^63; a line ends at its `\r` and whatever byte follows it, and is 64 KB at most
  without one; the two bytes after a bulk's data are skipped unread. The protocol errors
  are Redis's.
- An error goes out on one line, as Redis's error formatting sends it: a CR or LF in its
  text becomes a space, and an argument it quotes is cut at its first NUL.
- Under CLIENT REPLY OFF, or SKIP for the request it is in, a protocol error goes
  unanswered, as in Redis, and the connection stays open, reading nothing more, until
  the client closes it.

## The append-only file

- **Format.** Redis's own: a SELECT before the entries of another database; SWAPDB, MOVE
  and FLUSHALL as Redis writes them; COPY with its DB and REPLACE spelled out; a
  transaction's effects between MULTI and EXEC. `redis-check-aof` accepts the file and
  Redis loads it, and BendKV loads Redis's files (COPY as the client sent it). How each
  write is logged is in its section above.
- **Syncing:** `appendfsync always`, `everysec` or `no`. The start syncs the file's
  directory before it serves, so that a new file's name is on the disk before the first
  write is acknowledged.
- **A file cut short.** A file that ends in an entry cut short is cut back to its last
  whole entry, whatever its size. A file that ends inside a transaction (a crash cut it
  as it was written) has the transaction reverted and is cut back to before its MULTI, as
  Redis does ("Revert incomplete MULTI/EXEC transaction"). With
  `aof-load-truncated no`, both stop the start instead.
- **A file that does not replay.** A file with an entry the start cannot replay as it
  was written (an unknown command, a wrong number of arguments, an argument that does
  not read, a database that is not there, a MULTI inside another, an EXEC without one)
  stops the start, naming the entry and the byte it starts at, and the file is left as
  it was.
- **Rewrite.** BGREWRITEAOF, and the cron's rewrites as the file grows
  (`auto-aof-rewrite-percentage`, `auto-aof-rewrite-min-size`), write the file again as
  Redis writes its base: the commands that make the databases as they are when the
  rewrite starts, then the entries appended meanwhile, into a temporary file renamed
  onto the file. There is no fork: the databases are immutable values, so the rewrite
  writes them a slice at a time, between the groups of requests the server answers
  meanwhile. INFO shows a rewrite's fields ([FINDINGS.md](FINDINGS.md), section 3zv).
- **What is proved.** The persistence laws of the README's
  [What is proved](../README.md#what-is-proved) are about the file as the server appends
  it, not about a rewritten one.

## Not yet

- Streams.
- Lua scripts and functions (EVAL, EVALSHA, SCRIPT, FUNCTION LOAD and the rest).
- CLIENT TRACKING.
- RDB files: SAVE, BGSAVE, and loading one at the start.
- CONFIG REWRITE, which answers as Redis does without a configuration file.
- Replication, cluster, ACL users, modules and TLS ([Starting](#starting)).
