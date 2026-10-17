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
7.0.15 and 7.2.16 only.

| bug | 7.0.15 | 7.2.16 | 8.10.2 | Valkey 9.1.2 |
|---|---|---|---|---|
| 1. LSET takes its index modulo 2^32 | refuses | **bug** | refuses | **bug** |
| 2. A failed AUTH in a pipeline gets no reply | replies | **bug** | **bug** | replies |
| 3. CONFIG SET tls-port crashes a server built without TLS | refuses | **bug** | refuses | **bug** |
| 4. CLIENT UNBLOCK with ERROR counts a WAIT twice | counts once | **bug** | **bug** | **bug** |
| 5. RESTORE with a time to live near 2^63 ms makes a key | no key | **bug** | not run | not run |

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
