# Bugs found in Redis and Valkey

BendKV is tested against Redis by comparing replies, so the comparisons find bugs in Redis
too. This file keeps the ones found, until they are reported upstream. BendKV does not copy
them: where it follows a version that has one, it answers as the versions without it do
(`docs/COMPATIBILITY.md`).

None of them is reported yet. The owner decides when and where.

## How they were found

In October 2026, BendKV's differential tests were run against Redis 7.2.16, and each
difference was replayed by hand on four servers:

- Redis 7.0.15, as Ubuntu 24.04 ships it (package `5:7.0.15-1ubuntu0.24.04.4`);
- Redis 7.2.16, built from its tarball (sha256 `960a8ec1…a323a18e`, as redis-hashes lists it);
- Redis 8.10.2, built from its tarball with `make -C src`;
- Valkey 9.1.2, built from its tag (commit `7f1dffed`).

The causes below are read from the sources of Redis 7.2.16 and Valkey 9.1.2, which are
BSD-3. Redis 8.10.2 was only run; its sources were not read (AGENTS.md, rule 10).

Bug 5 turned up later, when RDB 11 came in on the branch of 7.2.16, and was replayed on
7.0.15 and 7.2.16 only. Bug 6 turned up as the last difference of HyperLogLog's test, and
was replayed on all four. Bugs 7 and 8 were differences from 7.0.15 that BendKV already
kept (`docs/FINDINGS.md`, sections 3zzk and 3zzzb), replayed on all four as the documents
moved to 7.2.16. Bug 9 turned up when WAITAOF came in, and was replayed on all four (7.0.15
through WAIT alone, as it has no WAITAOF).

| bug | 7.0.15 | 7.2.16 | 8.10.2 | Valkey 9.1.2 |
|---|---|---|---|---|
| 1. LSET takes its index modulo 2^32 | refuses | **bug** | refuses | **bug** |
| 2. A failed AUTH in a pipeline gets no reply | replies | **bug** | **bug** | replies |
| 3. CONFIG SET tls-port crashes a server built without TLS | refuses | **bug** | refuses | **bug** |
| 4. CLIENT UNBLOCK with ERROR counts a WAIT twice | counts once | **bug** | **bug** | **bug** |
| 5. RESTORE with a time to live near 2^63 ms makes a key | no key | **bug** | not run | not run |
| 6. PFADD reads the byte after a sparse HyperLogLog's end | **bug** | **bug** | **bug** | **bug** |
| 7. CLIENT UNBLOCK of a client CLIENT PAUSE holds crashes the server | **bug** | **bug** | answers 0 | answers 0 |
| 8. CLIENT TRACKING answers an overlap of its prefixes twice | **bug** | **bug** | answers once | answers once |
| 9. A client served by a blocking pop does not wait for the pop in WAIT or WAITAOF | **bug** | **bug** | **bug** | **bug** |

## 1. LSET takes its index modulo 2^32

**What happens.** LSET with an index of 2^32 or more, or of −2^32 − 1 or less, answers OK.
It sets the element at the index cut to 32 bits. `LSET l 4294967297 v` sets element 1,
`LSET l 9223372036854775807 v` sets the last one, and `LSET l -9223372036854775808 v` sets
the first. Such an index is past any list, so the reply should be
`ERR index out of range`, as 7.0.15 and 8.10.2 answer.

**How to see it.** This holds for small lists (listpack) and large ones (quicklist) alike:

```
> RPUSH l a b c
(integer) 3
> LSET l 4294967297 v
OK
> LRANGE l 0 -1
1) "a"
2) "v"
3) "c"
```

**Where.** `lsetCommand` reads the index as a `long`. It hands the index to
`listTypeReplaceAtIndex(robj *o, int index, robj *value)`, whose `int` cuts it:
- Redis 7.2.16: `src/t_list.c`, line 384;
- Valkey 9.1.2: `src/t_list.c`, line 368.

Redis 7.0's LSET passed the `long` to `quicklistReplaceAtIndex`.

**To report to:** Valkey, and Redis for its 7.2 branch.

## 2. A failed AUTH in a pipeline gets no reply

**What happens.** A client may still have replies pending, from earlier commands of its
pipeline that are not written yet. An AUTH that fails then adds no reply at all. Each later
reply of the pipeline is taken for the command before it. A client that matches replies to
commands in order reads, for example, the `+OK` of a later AUTH as the failed one's reply,
and then waits for its last reply forever.

**How to see it.** With `requirepass secret`, send four commands in one write:

```
python3 -c "
import socket
s = socket.create_connection(('127.0.0.1', 6379)); s.settimeout(1)
s.sendall(b'PING\r\nAUTH wrong\r\nAUTH secret\r\nGET k\r\n')
out = b''
try:
    while True: out += s.recv(4096)
except OSError: pass
print(out)"
```

- **7.2.16 and 8.10.2** give three replies for the four commands: `-NOAUTH`, `+OK` and `$-1`.
- **7.0.15 and Valkey 9.1.2** answer the second command with
  `-WRONGPASS invalid username-password pair or user is disabled.`

**Where.** In Redis 7.2.16, `addAuthErrReply` (`src/acl.c`, line 1455) returns at once
`if (clientHasPendingReplies(c))`. The check is meant for a module's authentication
callback that has replied already, but the pending replies of earlier commands meet it as
well. Valkey 9.1.2 checks a flag of the AUTH's own reply instead (`c->flag.buffered_reply`,
`src/acl.c`, line 1600).

**To report to:** Redis, for 7.2 and 8.

## 3. CONFIG SET tls-port crashes a server built without TLS

**What happens.** A server built without TLS (`BUILD_TLS=no`, the default of `make`) dies
on `CONFIG SET tls-port 6390`: a segmentation fault under `configSetCommand`.
- 7.0.15 refuses: `Unable to update TLS configuration. Check server logs.`
- 8.10.2 refuses: `TLS support is not compiled in, cannot set a TLS port.`

**How to see it.** Build with `make -C src`, start the server, then run
`redis-cli config set tls-port 6390`. The connection closes, and the server's log ends with
its crash report.

**Where.** `applyTLSPort` calls `connTypeConfigure(connectionTypeTls(), ...)`:
- Redis 7.2.16: `src/config.c`, line 2683;
- Valkey 9.1.2: `src/config.c`, line 2819.

Without TLS, `connectionTypeTls()` returns NULL. `connTypeConfigure` calls
`ct->configure(...)` on it (`src/connection.h`).

**To report to:** Valkey, and Redis for its 7.2 branch. Only a client allowed CONFIG SET
(an @admin and @dangerous command) can cause it. Even so, a crash may be better sent
through the projects' security channels than as a public issue.

## 4. CLIENT UNBLOCK with ERROR counts a WAIT twice

**What happens.** `CLIENT UNBLOCK <id> ERROR` unblocks a client that waits in WAIT, and the client
gets one error reply. The server counts two calls of WAIT:
- two calls in INFO commandstats, one of them failed;
- two in `total_commands_processed`;
- two entries in the slow log, and two samples in the latency histogram.

Any other blocking command unblocked this way counts one call, and so does a WAIT unblocked with
`TIMEOUT`.

**How to see it.** Run each line in its own shell, against a server with no replica:

```
$ redis-cli config resetstat
$ redis-cli wait 1 0                  # blocks: no replica will acknowledge
$ redis-cli client list               # the waiting client's id
$ redis-cli client unblock <id> error
$ redis-cli info commandstats | grep wait
```

- **7.0.15** counts `calls=1`, `failed_calls=1`.
- **7.2.16 and 8.10.2** count `calls=2`, `failed_calls=1`.
- **Valkey 9.1.2** counts `calls=2`, `rejected_calls=1`, `failed_calls=0`.

WAITAOF is unblocked through the same path.

**Where.** The call is counted twice on its way out:
- Redis 7.2.16: `unblockClientOnError` (`src/blocked.c`, line 735) counts it, failed
  (`updateStatsOnUnblock`). Then `unblockClient` calls `unblockClientWaitingReplicas`
  (`src/replication.c`, line 3615), which counts it again.
- Valkey 9.1.2: `unblockClientOnError` (`src/blocked.c`, line 820) counts it, as rejected. Then
  `unblockClientWaitingReplicas` (`src/replication.c`, line 5105) counts it again.

The second count is meant for a WAIT whose time is up: `replyToBlockedClientTimedOut` counts nothing
for one.

**To report to:** Redis, for 7.2 and 8, and Valkey.

## 5. RESTORE with a time to live near 2^63 ms makes a key

**What happens.** RESTORE takes a time to live in milliseconds and adds the clock's time to
it. For a time to live past 2^63 − 1 less the clock's time, `9223372036854775807` for one,
the sum overflows 64 bits. 7.0.15 takes the sum for a time past and makes no key, as for any
time past: it answers OK and the key is not there. 7.2.16 answers OK and makes the key: GET
reads its value, and PTTL answers about 2^63, until the next cycle of expiries deletes the
key, within a tenth of a second at the default `hz`. The append-only file and the replicas
get `RESTORE k <a negative time> ... ABSTTL`, which they refuse
(`Invalid TTL value, must be >= 0`), then a DEL of the key.

**How to see it.** The GET has to come before the cycle of expiries, so in the same write:

```
python3 -c '
import socket, time
def req(*a):
    return b"*%d\r\n" % len(a) + b"".join(b"$%d\r\n%s\r\n" % (len(x), x) for x in a)
s = socket.create_connection(("127.0.0.1", 6379))
s.sendall(req(b"SET", b"s", b"hello") + req(b"DUMP", b"s")); time.sleep(0.1)
p = s.recv(4096).split(b"\r\n", 2)[2][:-2]
s.sendall(req(b"RESTORE", b"k", b"9223372036854775807", p) + req(b"GET", b"k"))
time.sleep(0.5); print(s.recv(4096))
s.sendall(req(b"EXISTS", b"k")); time.sleep(0.1); print(s.recv(4096))'
```

- **7.2.16** prints `+OK`, then `$5 hello`; half a second later, `EXISTS k` answers 0.
- **7.0.15** prints `+OK`, then `$-1`.

**Where.** `restoreCommand` (Redis 7.2.16: `src/cluster.c`, line 6785) adds
`commandTimeSnapshot()` to the time to live with no check for overflow, then asks
`checkAlreadyExpired` (`src/expire.c`, line 478) whether the sum is past. C leaves a signed
overflow undefined, so what the check makes of the sum is the compiler's: built from the
tarball with gcc 13.3, the server takes it for not past and keeps the key with the wrapped,
negative time, which `keyIsExpired` reads as no time to live and the cycle of expiries as a
time past. 7.0.15 added `mstime()` where 7.2.16 adds `commandTimeSnapshot()`. SET, EXPIRE
and their kin check the sum for overflow first (`invalid expire time`); RESTORE does not.

**To report to:** Redis, for its 7.2 branch; 8.10.2 and Valkey 9.1.2 are not checked yet.

## 6. PFADD reads the byte after a sparse HyperLogLog's end

**What happens.** A string can pass for a sparse HyperLogLog whose opcodes end within an
XZERO, an opcode of two bytes cut after its first. PFADD then reads the byte after the
value's end as the XZERO's second, so the run it reads, and the value it writes, turn on
memory outside the value:
- the string's NUL, 0, when nothing else wrote there;
- the last byte of the opcodes a split of that XZERO made, which PFADD writes there, over
  the NUL;
- the NUL again, once Redis 7.2 grows the value's buffer (which it does when fewer than 3
  bytes are left), that is, by the sizes of the allocator's classes.

So the versions leave different values for the same commands, though none checks the
value's last opcode, and a split leaves a string without its NUL. Every opcode of 7.2.16's
and Valkey's own values is whole; such a value comes from a SET, a SETRANGE, a RESTORE or a
file. PFCOUNT and PFMERGE read the byte too.

**How to see it.** A 40-byte value: the header, 23 ZEROs of one register each, then an
XZERO's first byte, `7f` (with a 0 after it, 16,129 registers). Two elements land in the
cut XZERO:

```
python3 -c '
import socket, time
def req(*a):
    return b"*%d\r\n" % len(a) + b"".join(b"$%d\r\n%s\r\n" % (len(x), x) for x in a)
v = b"HYLL\x01" + b"\x00" * 10 + b"\x80" + b"\x00" * 23 + b"\x7f"
s = socket.create_connection(("127.0.0.1", 6379))
s.sendall(req(b"SET", b"h", v) + req(b"PFADD", b"h", b"a3", b"b3") + req(b"GET", b"h"))
time.sleep(0.2); print(s.recv(4096).split(b"\r\n")[-2][-7:].hex())'
```

The value ends `4827846b4f884b` on 7.0.15, and `4827846b4f884a` on 7.2.16, 8.10.2 and
Valkey 9.1.2: XZERO, VAL, XZERO, VAL, and an XZERO's first byte.
- a3 splits the XZERO into XZERO, VAL, XZERO. The last XZERO, of 14,040 registers (`76 d7`),
  is cut in turn: its `d7` lies past the value's end, over the NUL.
- b3 lands in that XZERO. 7.0.15 reads `76 d7`, and leaves an XZERO of 2,951 registers
  (`4b 86`, cut after `4b`). 7.2.16 grows the buffer first, which writes a NUL over `d7`.
  It reads `76 00`, 13,825 registers, and leaves 2,736 (`4a af`, cut after `4a`).

The same two elements in two PFADDs, one each, leave `4b` on 7.0.15 again: its buffer
keeps the byte between commands.

**Where.** `hllSparseSet` reads an XZERO's run with `HLL_SPARSE_XZERO_LEN(p)`, `p[1]`
included, whether or not `p + 1` is still within the value:
- Redis 7.2.16: `src/hyperloglog.c`, line 717. A split copies its opcodes with
  `memcpy(p,seq,seqlen)` (line 859), one byte past the end for a cut XZERO, after
  `sdsIncrLen` (line 858) wrote the NUL there. Growing the buffer, `sdsResize`
  (line 691) writes the NUL again (`src/sds.c`, line 382). 7.0.15's `sdsMakeRoomFor`
  copies the byte past the end with the string.
- Valkey 9.1.2: `src/hyperloglog.c`, lines 750, 891 and 724.

`hllSparseSum` and `hllMerge` read the run the same way.

**What BendKV does.** It reads the byte as 0 when a command starts, and as the last byte of
the split it made, within the same command (7.0.15 within one PFADD), which does not turn
on an allocator. tests/hll_test.py checks that alone, and does not fail on a command that
reads such a value and is answered otherwise.

**To report to:** Redis, for 7.2 and 8, and Valkey.

## 7. CLIENT UNBLOCK of a client CLIENT PAUSE holds crashes the server

**What happens.** While CLIENT PAUSE holds a client's command back, `CLIENT UNBLOCK <id>`
of that client stops the server, with a "Guru Meditation: Unknown btype in
replyToBlockedClientTimedOut()". `CLIENT UNBLOCK <id> ERROR` answers 1 and fails the held
command with `-UNBLOCKED client unblocked via CLIENT UNBLOCK`, though it never ran. 8.10.2
and Valkey 9.1.2 answer 0 to both, and the command runs once the pause ends.

**How to see it.** Run each line in its own shell:

```
$ redis-cli client pause 10000 write
$ redis-cli set k v                   # held back by the pause
$ redis-cli client list               # the held client's id
$ redis-cli client unblock <id>       # 7.0.15 and 7.2.16 stop here
```

**Where.** CLIENT UNBLOCK asks whether its client may time out, and a client that the pause
holds may not:
- Redis 7.2.16: `clientCommand` (`src/networking.c`, line 3271) asks
  `moduleBlockedClientMayTimeout` (`src/module.c`, line 8353), which says yes for every
  kind of block but a module's, so for `BLOCKED_POSTPONE`, the pause's
  (`blockPostponeClient`, `src/blocked.c`, line 633), too.
  - Without ERROR, `unblockClientOnTimeout` (`src/blocked.c`, line 726) calls
    `replyToBlockedClientTimedOut` (line 229), which has no reply for that kind and
    panics (line 244).
  - With ERROR, `unblockClientOnError` (line 735) replies the error and unblocks the client.
- Valkey 9.1.2: `blockedClientMayTimeout` (`src/blocked.c`, line 260) says yes for lists,
  sorted sets, streams and WAIT, and for a module's block with a timeout callback, so the
  pause's gets 0.

**What BendKV does.** It answers 0, as 8.10.2 and Valkey do, and the command runs once the
pause ends (`tests/pause_test.py`).

**To report to:** Redis, for its 7.2 branch.

## 8. CLIENT TRACKING answers an overlap of its prefixes twice

**What happens.** `CLIENT TRACKING ON BCAST` with prefixes that overlap answers an error.
When the overlap is found past the first prefix, it then answers OK as well, and turns
tracking on with all the prefixes. So the client gets two replies to one command, and
every reply after it is one command late. 8.10.2 and Valkey 9.1.2 answer the error alone.

**How to see it.**

```
python3 -c '
import socket, time
def req(*a):
    return b"*%d\r\n" % len(a) + b"".join(b"$%d\r\n%s\r\n" % (len(x), x) for x in a)
s = socket.create_connection(("127.0.0.1", 6379))
s.sendall(req(b"HELLO", b"3"))
time.sleep(0.2); s.recv(4096)
s.sendall(req(b"CLIENT", b"TRACKING", b"on", b"BCAST", b"PREFIX", b"x", b"PREFIX", b"a", b"PREFIX", b"ab"))
time.sleep(0.2); print(s.recv(4096))'
```

7.0.15 and 7.2.16 print the error, then `+OK`. With the overlap between the first two
prefixes (`PREFIX a PREFIX ab`), they answer the error alone.

**Where.**
- Redis 7.2.16: `checkPrefixCollisionsOrReply` (`src/tracking.c`, line 112) replies the
  error for two given prefixes that overlap, then returns `i`, the index of the first of
  the two (line 146). Its caller (`src/networking.c`, line 3424) takes only 0 as the
  error, so past the first prefix it goes on to `enableTracking` and OK.
- Valkey 9.1.2: the same check returns 0 (`src/tracking.c`, line 146).

**What BendKV does.** It answers the error alone, and leaves the tracking as it was
(`tests/tracking_test.py`).

**To report to:** Redis, for its 7.2 branch.

## 9. A client served by a blocking pop does not wait for the pop in WAIT or WAITAOF

**What happens.** WAIT and WAITAOF wait for the client's last write: the replication offset
right after its last command that propagated something (`c->woff`). A client that waits in
BLPOP, BLMOVE, BZPOPMIN or another blocking pop, and is served by another client's write,
pops what it waited for, and its pop is propagated, as LPOP, LMOVE or ZPOPMIN, to the
append-only file and the replicas. Its offset stays where its writes before the BLPOP left
it. So a WAIT or a WAITAOF it sends next does not wait for its pop: WAITAOF answers that
the file has synced the pop when it has not, and WAIT counts replicas that never got it.

**How to see it.** Against a server started with `--appendonly yes --appendfsync no`, which
syncs nothing after its start:

```
python3 -c '
import socket, time
def req(*a):
    return b"*%d\r\n" % len(a) + b"".join(b"$%d\r\n%s\r\n" % (len(x), x) for x in a)
a = socket.create_connection(("127.0.0.1", 6379))
b = socket.create_connection(("127.0.0.1", 6379))
a.sendall(req(b"BLPOP", b"l", b"0")); time.sleep(0.2)
b.sendall(req(b"RPUSH", b"l", b"x")); time.sleep(0.2)
a.recv(4096), b.recv(4096)
a.sendall(req(b"WAITAOF", b"1", b"0", b"100")); print(a.recv(4096))
b.sendall(req(b"WAITAOF", b"1", b"0", b"100")); print(b.recv(4096))'
```

- **7.2.16, 8.10.2 and Valkey 9.1.2:** the BLPOP's client gets `*2 :1 :0` at once, though
  nothing was synced; the RPUSH's client gets `*2 :0 :0` once its 100 ms are up.
- **With a replica** (`--replicaof`) stopped by `kill -STOP` before the RPUSH, the BLPOP's
  client's `WAIT 1 300` answers 1 at once, and the RPUSH's client's answers 0 after
  300 ms, on all four servers, 7.0.15 among them.

**Where.** `call()` sets `c->woff` when the offset moved during the command, and the served
client's command does not move it there:
- Redis 7.2.16: `call()` (`src/server.c`, line 3693) compares the offset with the one
  before the command (line 3506). A served client's command runs again in
  `unblockClientOnKey` (`src/blocked.c`, line 651), inside an execution unit it enters
  before (line 677) and leaves after (line 692), so that the command and its unblock
  handler run atomically. Inside the unit, `postExecutionUnitOperations` propagates
  nothing (`src/server.c`, line 3400): the pop is propagated at `afterCommand`
  (`src/blocked.c`, line 693), once `call()` has compared the offsets.
- Valkey 9.1.2: the same, `call()` at `src/server.c`, line 4088, and the unit at
  `src/blocked.c`, lines 757 to 773.
- Redis 7.0.15 serves the client without a `call()` (`serveClientsBlockedOnListKey`,
  `src/blocked.c`, line 285), and the pop is propagated with the command that served it
  (line 682); `c->woff` is set only in `call()` (`src/server.c`, line 4021).

**What BendKV does.** A client's woff counts its served pop, so that its WAIT or WAITAOF
after it waits for the pop (`tests/admin_test.py`).

**To report to:** Redis, for 7.2 and 8, and Valkey.
