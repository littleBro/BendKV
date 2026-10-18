#!/usr/bin/env python3
"""The commands of a connection, BendKV against Redis byte for byte: each
case sends its requests on a fresh connection to both servers and compares
what comes back before the server goes quiet, and whether it closed the
connection. Both servers have Redis's 16 databases. Client ids differ between the servers (Redis gives
some to clients of its own), so a case that shows one has its integers
masked; TIME's value is compared within a second. HELLO 3 and RESP3 have
their own test (tests/resp3_test.py). One difference is left out: a QUIT
while CLIENT REPLY is off, after which Redis keeps the connection open but
reads nothing more from it (the close waits for a reply that never goes
out), where BendKV closes it.

    python3 tests/session_test.py --bendkv 6380 --redis 6390
"""
import argparse
import re

from protocol_test import exchange, resp


def lines(*reqs):
    return b"".join(r + b"\r\n" for r in reqs)


CASES = [
    # HELLO
    ("hello", lines(b"HELLO"), True),
    ("hello 2", lines(b"HELLO 2"), True),
    ("hello setname", lines(b"HELLO 2 SETNAME foo", b"CLIENT GETNAME"), True),
    ("hello: versions", lines(b"HELLO 4", b"HELLO 1", b"HELLO x", b"HELLO -2", b"HELLO 281474976710656",
                              b"HELLO 9223372036854775807", b"HELLO 9223372036854775808", b"HELLO -9223372036854775808",
                              b"HELLO 02"), False),
    ("hello: options", lines(b"HELLO 2 BAR", b"HELLO 2 AUTH default", b"HELLO 2 SETNAME"), False),
    ("hello: auth", lines(b"HELLO 2 AUTH bob pw", b"HELLO 2 AUTH default any"), True),
    ("hello: a name with a space", lines(b'HELLO 2 SETNAME "a b"', b"CLIENT GETNAME"), False),
    ("hello: setname then a bad option", lines(b"HELLO 2 SETNAME n1 NOPE", b"CLIENT GETNAME"), False),
    # AUTH, with no password
    ("auth", lines(b"AUTH x", b"AUTH default y"), False),
    # a failed AUTH first in its pipeline: Redis 7.2.16 drops the reply of
    # one that comes after replies not yet written (docs/UPSTREAM.md, 2),
    # where BendKV answers it, as 7.0.15 does (failed_auth, below)
    ("auth: no such user", lines(b"AUTH bob y", b"AUTH a b c", b"AUTH"), False),
    # SELECT
    ("select", lines(b"SELECT 0", b"SELECT 1", b"SELECT x", b"SELECT -1", b"SELECT", b"SELECT 0 1"), False),
    # TYPE
    ("type", lines(b"TYPE k", b"SET k v", b"TYPE k", b"TYPE", b"TYPE a b"), False),
    # CLIENT
    ("client: help, arity and unknown", lines(b"CLIENT HELP", b"CLIENT", b"CLIENT FOO", b"CLIENT ID x", b"CLIENT GETNAME x", b"CLIENT SETNAME", b"CLIENT HELP x"), False),
    ("client: unknown subcommand with a newline", resp(b"CLIENT", b"a\r\nb"), False),
    ("client id", lines(b"CLIENT ID"), True),
    ("client names", lines(b"CLIENT GETNAME", b"CLIENT SETNAME foo", b"CLIENT GETNAME",
                           b'CLIENT SETNAME "a b"', b"CLIENT GETNAME", b'CLIENT SETNAME ""', b"CLIENT GETNAME"), False),
    ("client: a name with a byte past '~'", resp(b"CLIENT", b"SETNAME", b"a\x7fb") + resp(b"CLIENT", b"GETNAME"), False),
    ("client: tracking off", lines(b"CLIENT GETREDIR", b"CLIENT TRACKINGINFO", b"CLIENT CACHING yes", b"CLIENT CACHING x"), False),
    ("client no-evict", lines(b"CLIENT NO-EVICT on", b"CLIENT NO-EVICT OFF", b"CLIENT NO-EVICT x"), False),
    ("client unblock", lines(b"CLIENT UNBLOCK 5", b"CLIENT UNBLOCK 5 error", b"CLIENT UNBLOCK 5 x",
                             b"CLIENT UNBLOCK x", b"CLIENT UNBLOCK 5 timeout extra"), False),
    # CLIENT REPLY
    ("client reply off and on", lines(b"CLIENT REPLY OFF", b"PING", b"SET a 1", b"CLIENT REPLY ON", b"GET a"), False),
    ("client reply skip", lines(b"CLIENT REPLY SKIP", b"PING", b"PING", b"CLIENT REPLY SKIP", b"CLIENT REPLY SKIP", b"PING", b"ECHO x"), False),
    ("client reply: skip while off", lines(b"CLIENT REPLY OFF", b"CLIENT REPLY SKIP", b"PING", b"CLIENT REPLY ON", b"PING"), False),
    ("client reply: a bad mode", lines(b"CLIENT REPLY BAD", b"CLIENT REPLY SKIP", b"CLIENT REPLY BAD", b"PING"), False),
    ("client reply: errors held back", lines(b"CLIENT REPLY OFF", b"NOPE", b"GET", b"CLIENT REPLY ON", b"NOPE"), False),
    # RESET
    ("reset", lines(b"CLIENT SETNAME foo", b"RESET", b"CLIENT GETNAME", b"RESET x"), False),
    ("reset while replies are off", lines(b"CLIENT REPLY OFF", b"RESET", b"PING"), False),
    ("reset when skipped", lines(b"CLIENT REPLY SKIP", b"RESET", b"PING"), False),
    # QUIT
    ("quit", lines(b"QUIT"), False),
    ("quit with arguments", lines(b"QUIT now please"), False),
    ("quit drops what follows", lines(b"SET q 1", b"QUIT", b"SET q 2", b"GET q"), False),
    ("quit, then the key", lines(b"GET q"), False),
    # FUNCTION
    ("function flush", lines(b"FUNCTION FLUSH", b"FUNCTION FLUSH async", b"FUNCTION FLUSH SYNC",
                             b"FUNCTION FLUSH x", b"FUNCTION FLUSH a b", b"FUNCTION", b"FUNCTION NOPE", b"FUNCTION HELP x"), False),
    # FLUSHALL and FLUSHDB
    ("flush options", lines(b"SET f 1", b"FLUSHALL ASYNC", b"GET f", b"FLUSHALL X", b"FLUSHDB sync", b"FLUSHDB a b", b"FLUSHALL"), False),
    # several databases: numbers, keys apart, MOVE, SWAPDB, RESET
    ("select: numbers", lines(b"SELECT 15", b"SELECT 16", b"SELECT 01", b"SELECT +1", b"SELECT 1.5", b"SELECT 2147483647",
                              b"SELECT 2147483648", b"SELECT -2147483649", b"SELECT 99999999999999999999",
                              b"SELECT 281474976710656", b"SELECT 9223372036854775807", b"SELECT -9223372036854775808",
                              b"MOVE k 9223372036854775807", b"SWAPDB 9223372036854775807 0", b"SWAPDB 0 -9223372036854775808",
                              b"COPY k k2 DB 9223372036854775807", b"PING"), False),
    ("databases apart", lines(b"SELECT 1", b"SET d 1", b"SELECT 2", b"GET d", b"SET d 2", b"SELECT 1", b"GET d",
                              b"DBSIZE", b"FLUSHDB", b"DBSIZE", b"SELECT 2", b"GET d", b"FLUSHALL", b"GET d"), False),
    ("move", lines(b"SET mv 1", b"MOVE mv 1", b"GET mv", b"SELECT 1", b"GET mv", b"MOVE mv 1", b"MOVE mv 0",
                   b"MOVE nope 0", b"SET mv 2", b"SELECT 0", b"SET mv 3", b"SELECT 1", b"MOVE mv 0", b"GET mv",
                   b"MOVE mv 16", b"MOVE mv x", b"MOVE mv -1", b"MOVE mv", b"MOVE a b c", b"FLUSHALL"), False),
    ("move keeps the time", lines(b"SET mt 1 EXAT 4000000000", b"MOVE mt 3", b"SELECT 3", b"EXPIRETIME mt", b"FLUSHALL"), False),
    ("swapdb", lines(b"SET s0 a", b"SELECT 1", b"SET s1 b", b"SWAPDB 0 1", b"GET s0", b"GET s1", b"SELECT 0", b"GET s1",
                     b"SWAPDB 0 0", b"SWAPDB 0 16", b"SWAPDB x 0", b"SWAPDB 0 x", b"SWAPDB -1 0", b"SWAPDB 0",
                     b"SWAPDB 1 2 3", b"FLUSHALL"), False),
    ("reset selects 0", lines(b"SELECT 5", b"SET r5 x", b"RESET", b"GET r5", b"SELECT 5", b"GET r5", b"FLUSHALL"), False),
    # TOUCH, OBJECT and TIME's arity (TIME's value: time_close, below;
    # OBJECT IDLETIME of a key reads Redis's clock of seconds, which may
    # tick between two commands, and BendKV answers 0)
    ("touch", lines(b"SET t1 1", b"TOUCH t1 t2 t1", b"TOUCH nope", b"TOUCH", b"FLUSHALL"), False),
    ("object", lines(b"SET o1 1", b"SET o2 hello", b"SET o3 10000", b"SET o4 -5", b"SET o5 " + b"x" * 45,
                     b"OBJECT ENCODING o1", b"OBJECT ENCODING o2", b"OBJECT ENCODING o4", b"OBJECT ENCODING o5",
                     b"OBJECT REFCOUNT o1", b"OBJECT REFCOUNT o3", b"OBJECT REFCOUNT o2", b"OBJECT IDLETIME nope",
                     b"OBJECT FREQ o1", b"OBJECT encoding nope", b"OBJECT REFCOUNT nope", b"OBJECT FREQ nope",
                     b"FLUSHALL"), False),
    ("object: help, arity and unknown", lines(b"OBJECT HELP", b"OBJECT", b"OBJECT FOO x", b"OBJECT ENCODING",
                                              b"OBJECT ENCODING a b", b"OBJECT HELP x"), False),
    ("object under an LFU policy", lines(b"SET o1 1", b"CONFIG SET maxmemory-policy allkeys-lfu", b"OBJECT FREQ o1",
                                         b"OBJECT IDLETIME o1", b"OBJECT IDLETIME nope",
                                         b"CONFIG SET maxmemory-policy noeviction", b"FLUSHALL"), False),
    ("time: arity", lines(b"TIME x", b"TIME a b"), False),
    ("msetnx", lines(b"MSETNX m1 a m2 b", b"MSETNX m2 c m3 d", b"MGET m1 m2 m3", b"MSETNX m4 x m4 y", b"GET m4",
                     b"MSETNX", b"MSETNX m5", b"MSETNX m5 a m6", b"FLUSHALL"), False),
    ("copy", lines(b"SET c1 a", b"PEXPIRE c1 100000", b"COPY c1 c2", b"TTL c2", b"GET c2", b"COPY c1 c2",
                   b"COPY c1 c2 REPLACE", b"COPY c1 c1", b"COPY c1 c1 DB 0", b"COPY c1 c1 DB 1", b"SELECT 1",
                   b"TTL c1", b"SELECT 0", b"COPY c1 c3 DB 2", b"COPY c1 c3 DB 2", b"COPY c1 c3 db 2 replace",
                   b"COPY nope x", b"COPY c1 x DB 16", b"COPY c1 x DB -1", b"COPY c1 x DB y", b"COPY c1 x DB",
                   b"COPY c1 x FOO", b"COPY c1 x DB 99999999999", b"COPY", b"COPY c1", b"FLUSHALL"), False),
    ("bitop", lines(b"SET b1 abc", b"SET b2 x", b"PEXPIRE b2 100000", b"BITOP AND b2 b1 nope", b"TTL b2", b"GET b2",
                    b"BITOP OR b3 b1 b2", b"GET b3", b"BITOP XOR b1 b1", b"GET b1", b"BITOP NOT b4 nope", b"EXISTS b4",
                    b"SET b4 q", b"BITOP not b4 nope", b"EXISTS b4", b"BITOP nand b5 b1", b"BITOP NOT b5 b1 b2",
                    b"BITOP NOT b5", b"BITOP", b"FLUSHALL"), False),
    ("lcs", lines(b"SET l1 ohmytext", b"SET l2 mynewtext", b"LCS l1 l2", b"LCS l1 l2 LEN", b"LCS l1 l2 IDX",
                  b"LCS l1 l2 IDX MINMATCHLEN 4 WITHMATCHLEN", b"LCS l1 l2 LEN IDX", b"LCS l1 l2 FOO",
                  b"LCS l1 l2 MINMATCHLEN", b"LCS l1 l2 MINMATCHLEN x", b"LCS nope l2 IDX", b"LCS l1",
                  b"CONFIG SET proto-max-bulk-len 1048576", b"SET l3 " + b"a" * 600, b"SET l4 " + b"b" * 600,
                  b"LCS l3 l4 LEN", b"LCS l3 l1 LEN", b"CONFIG SET proto-max-bulk-len 536870912", b"LCS l3 l4 LEN",
                  b"FLUSHALL"), False),
    ("bitfield", lines(b"SET f1 ab", b"PEXPIRE f1 100000", b"BITFIELD f1 SET u8 8 99 GET u8 8 INCRBY i4 0 9", b"TTL f1",
                       b"GET f1", b"BITFIELD f2 OVERFLOW FAIL INCRBY u2 30 7", b"GET f2", b"BITFIELD f2 SET i64 #1 -1 GET u63 64",
                       b"GET f2", b"BITFIELD f2 SET i64 #1 -1", b"BITFIELD_RO f1 GET u8 8 GET i64 #0", b"BITFIELD_RO f1 SET u8 0 1",
                       b"BITFIELD_RO nope GET i8 0", b"EXISTS nope", b"BITFIELD f1 GET u64 0", b"BITFIELD f1 GET i8 -1",
                       b"BITFIELD f1 SET i8 0 x", b"BITFIELD f1 OVERFLOW x", b"BITFIELD f1 FOO", b"BITFIELD f1 GET i8",
                       b"BITFIELD", b"BITFIELD_RO", b"BITFIELD f1", b"BITFIELD_RO f1 OVERFLOW SAT", b"FLUSHALL"), False),
    ("rename", lines(b"SET r1 a", b"PEXPIRE r1 100000", b"RENAME r1 r2", b"EXISTS r1", b"GET r2", b"TTL r2",
                     b"SET r3 b", b"RENAME r3 r2", b"TTL r2", b"GET r2", b"RENAME r2 r2", b"RENAMENX r2 r2",
                     b"RENAME nope x", b"RENAME nope nope", b"RENAMENX nope x", b"SET r4 c", b"RENAMENX r2 r4",
                     b"RENAMENX r2 r5", b"MGET r2 r4 r5", b"RENAME", b"RENAME a", b"RENAMENX a b c", b"FLUSHALL"), False),
    # a pipeline of both kinds
    ("mixed pipeline", lines(b"SET m 1", b"CLIENT SETNAME pipe", b"INCR m", b"CLIENT GETNAME", b"GET m", b"TYPE m"), False),
]


# a failed AUTH after replies not yet written: BendKV answers it, as Redis
# 7.0.15 and Valkey do, where Redis 7.2.16 and 8 give it no reply
# (docs/UPSTREAM.md, 2), so this checks BendKV alone
def failed_auth(bendkv):
    data, closed = exchange(bendkv, lines(b"PING", b"AUTH bob y", b"PING"))
    want = b"+PONG\r\n-WRONGPASS invalid username-password pair or user is disabled.\r\n+PONG\r\n"
    return data == want and not closed


# TIME: two bulk strings, s and us since 1970, within a second of Redis's
def time_close(bendkv, redis):
    def seconds(port):
        data, closed = exchange(port, resp(b"TIME"))
        parts = data.split(b"\r\n")
        if len(parts) < 5 or parts[0] != b"*2" or not parts[1].startswith(b"$") or not parts[3].startswith(b"$"):
            return None
        sec, usec = int(parts[2]), int(parts[4])
        return sec + usec / 1e6 if usec < 10**6 else None
    a, b = seconds(bendkv), seconds(redis)
    return a is not None and b is not None and abs(a - b) <= 1.0


def mask(got):
    data, closed = got
    return re.sub(rb":\d+\r\n", b":ID\r\n", data), closed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, default=6380)
    ap.add_argument("--redis", type=int, default=6390)
    a = ap.parse_args()
    for port in (a.bendkv, a.redis):
        exchange(port, resp(b"FLUSHALL"))
    ok = True
    for name, data, ids in CASES:
        mine = exchange(a.bendkv, data)
        theirs = exchange(a.redis, data)
        if ids:
            mine, theirs = mask(mine), mask(theirs)
        same = mine == theirs
        ok &= same
        print("%s %s" % ("ok  " if same else "FAIL", name))
        if not same:
            print("     bendkv: %r" % (mine,))
            print("     redis:  %r" % (theirs,))
    same = time_close(a.bendkv, a.redis)
    ok &= same
    print("%s %s" % ("ok  " if same else "FAIL", "time: within a second of Redis's"))
    same = failed_auth(a.bendkv)
    ok &= same
    print("%s %s" % ("ok  " if same else "FAIL", "auth: a failed AUTH in a pipeline is answered (BendKV alone)"))
    print("ALL OK" if ok else "SOME CHECKS FAILED")
    return ok


if __name__ == "__main__":
    raise SystemExit(0 if main() else 1)
