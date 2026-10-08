#!/usr/bin/env python3
"""The commands of a connection, BendKV against Redis byte for byte: each
case sends its requests on a fresh connection to both servers and compares
what comes back before the server goes quiet, and whether it closed the
connection. The reference Redis runs with one database (--databases 1),
as BendKV has one. Client ids differ between the servers (Redis gives
some to clients of its own), so a case that shows one has its integers
masked. Two differences are left out: HELLO 3, which BendKV refuses (it
speaks RESP2 alone), and a QUIT while CLIENT REPLY is off, after which
Redis keeps the connection open but reads nothing more from it (the close
waits for a reply that never goes out), where BendKV closes it.

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
    ("hello: versions", lines(b"HELLO 4", b"HELLO 1", b"HELLO x", b"HELLO -2"), False),
    ("hello: options", lines(b"HELLO 2 BAR", b"HELLO 2 AUTH default", b"HELLO 2 SETNAME"), False),
    ("hello: auth", lines(b"HELLO 2 AUTH bob pw", b"HELLO 2 AUTH default any"), True),
    ("hello: a name with a space", lines(b'HELLO 2 SETNAME "a b"', b"CLIENT GETNAME"), False),
    ("hello: setname then a bad option", lines(b"HELLO 2 SETNAME n1 NOPE", b"CLIENT GETNAME"), False),
    # AUTH, with no password
    ("auth", lines(b"AUTH x", b"AUTH default y", b"AUTH bob y", b"AUTH a b c", b"AUTH"), False),
    # SELECT
    ("select", lines(b"SELECT 0", b"SELECT 1", b"SELECT x", b"SELECT -1", b"SELECT", b"SELECT 0 1"), False),
    # TYPE
    ("type", lines(b"TYPE k", b"SET k v", b"TYPE k", b"TYPE", b"TYPE a b"), False),
    # CLIENT
    ("client: arity and unknown", lines(b"CLIENT", b"CLIENT FOO", b"CLIENT ID x", b"CLIENT GETNAME x", b"CLIENT SETNAME", b"CLIENT HELP x"), False),
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
    # a pipeline of both kinds
    ("mixed pipeline", lines(b"SET m 1", b"CLIENT SETNAME pipe", b"INCR m", b"CLIENT GETNAME", b"GET m", b"TYPE m"), False),
]


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
    print("ALL OK" if ok else "SOME CHECKS FAILED")
    return ok


if __name__ == "__main__":
    raise SystemExit(0 if main() else 1)
