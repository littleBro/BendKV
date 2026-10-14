#!/usr/bin/env python3
"""Transactions against Redis: scenarios of MULTI, EXEC, DISCARD, WATCH
and UNWATCH, each run on BendKV and on Redis with clients of their own,
the transcripts compared line by line; then checks of BendKV alone under
load.

The scenarios: a transaction's replies (of every kind, SELECT inside
it), DISCARD, a nested MULTI, WATCH inside MULTI, commands refused while
queued (unknown, a wrong number of arguments) and EXECABORT, errors as a
command runs (in EXEC's array), EXEC and DISCARD without MULTI, EXEC
refused (its arity) in MULTI and out of it, a QUIT and a RESET inside a
transaction; WATCH of keys another client changes or does not change, a
DEL of a key not there (no change), SADD of a member there (no change),
SMOVE of a member the destination holds (no change to it), SORT with
STORE (a change even when it stores the list there, none when it
deletes a key not there), SORT without it (no change),
FLUSHALL, FLUSHDB and SWAPDB of keys there and not there, MOVE, COPY,
RENAME, EXPIRE, a key that expires (active expiry, or found expired at
EXEC), a key of another database, a transaction of another client, UNWATCH
and DISCARD forgetting a touch, EXEC unwatching; a blocking command inside
EXEC (it does not wait), clients that wait served after EXEC (not between
its commands), CLIENT REPLY OFF and SKIP around a transaction, and the
statistics of INFO (commandstats, errorstats) as info.tcl checks them.

The checks under load: 20 clients adding 1000 to a counter with WATCH,
GET, MULTI, SET and EXEC (each lost race retried), the counter ending at
1000; a reader that never sees half of a transaction (MGET of two keys a
transaction increments together, while it runs 500 times); and 100
clients that close their connections in MULTI or with keys watched,
after which a write and a transaction run as before.

    python3 tests/multi_test.py --bendkv 6380 --redis 6390
"""
import argparse
import sys
import threading
import time

from blocking_test import Client, wait_blocked


def stats(r, *names):
    lines = r.cmd("INFO", "commandstats").splitlines() + r.cmd("INFO", "errorstats").splitlines()
    out = []
    for l in lines:
        for n in names:
            if l.startswith(n + ":"):
                out.append(",".join(p for p in l.split(",") if not p.startswith(("usec=", "usec_per_call="))))
    return sorted(out)


def scenarios(port, log):
    r = Client(port)
    r.cmd("FLUSHALL")
    a, b = Client(port), Client(port)
    # 1. a transaction's replies, of every kind, SELECT inside it
    log("1", a.cmd("MULTI"), a.cmd("SET", "s", "1"), a.cmd("INCR", "s"), a.cmd("GET", "s"), a.cmd("GET", "none"),
        a.cmd("RPUSH", "l", "x", "y"), a.cmd("LRANGE", "l", "0", "-1"), a.cmd("HSET", "h", "f", "v"),
        a.cmd("HGETALL", "h"), a.cmd("ZADD", "z", "1.5", "m"), a.cmd("ZRANGE", "z", "0", "-1", "WITHSCORES"),
        a.cmd("SELECT", "3"), a.cmd("SET", "s3", "x"), a.cmd("EXEC"))
    log("1 after", a.cmd("GET", "s3"), a.cmd("SELECT", "9"), a.cmd("GET", "s3"), a.cmd("GET", "s"))
    # 2. DISCARD, nested MULTI, WATCH inside MULTI
    log("2", a.cmd("MULTI"), a.cmd("SET", "d", "1"), a.cmd("DISCARD"), a.cmd("EXISTS", "d"), a.cmd("DISCARD"))
    log("2 nested", a.cmd("MULTI"), a.cmd("MULTI"), a.cmd("SET", "n", "1"), a.cmd("EXEC"), a.cmd("GET", "n"))
    log("2 watch", a.cmd("MULTI"), a.cmd("WATCH", "x"), a.cmd("SET", "w", "1"), a.cmd("EXEC"))
    # 3. refused while queued, errors as they run
    log("3 unknown", a.cmd("MULTI"), a.cmd("FOO", "x"), a.cmd("SET", "u", "1"), a.cmd("EXEC"), a.cmd("EXISTS", "u"))
    log("3 arity", a.cmd("MULTI"), a.cmd("SET", "u"), a.cmd("EXEC"))
    log("3 run", a.cmd("MULTI"), a.cmd("SET", "e", "1", "XX", "NX"), a.cmd("SET", "e", "x"), a.cmd("INCR", "e"),
        a.cmd("LPUSH", "e", "y"), a.cmd("EXEC"))
    log("3 without", a.cmd("EXEC"), a.cmd("DISCARD"), a.cmd("EXEC", "x"), a.cmd("DISCARD", "x"))
    log("3 exec refused", a.cmd("MULTI"), a.cmd("SET", "q", "1"), a.cmd("EXEC", "x"), a.cmd("EXEC"), a.cmd("EXISTS", "q"))
    log("3 multi refused", a.cmd("MULTI"), a.cmd("MULTI", "x"), a.cmd("PING"), a.cmd("EXEC"))
    log("3 unwatch queued", a.cmd("MULTI"), a.cmd("UNWATCH"), a.cmd("EXEC"))
    log("3 empty", a.cmd("MULTI"), a.cmd("EXEC"))
    # 4. QUIT and RESET inside a transaction
    c = Client(port)
    log("4 quit", c.cmd("MULTI"), c.cmd("SET", "qq", "1"), c.cmd("QUIT"), r.cmd("EXISTS", "qq"))
    c.close()
    c = Client(port)
    log("4 reset", c.cmd("MULTI"), c.cmd("SET", "rr", "1"), c.cmd("RESET"), c.cmd("EXEC"), c.cmd("SELECT", "9"),
        c.cmd("EXISTS", "rr"))
    c.close()
    # 5. WATCH: changed by another client, or not
    r.cmd("SET", "x", "30")
    log("5 other", a.cmd("WATCH", "x"), b.cmd("SET", "x", "40"), a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"))
    log("5 untouched", a.cmd("WATCH", "x", "y"), b.cmd("SET", "other", "1"), a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"))
    log("5 self", a.cmd("WATCH", "x"), a.cmd("SET", "x", "41"), a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"))
    log("5 del none", a.cmd("WATCH", "nokey"), b.cmd("DEL", "nokey"), a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"))
    log("5 del", a.cmd("WATCH", "x"), b.cmd("DEL", "x"), a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"))
    r.cmd("SADD", "st", "m")
    log("5 sadd there", a.cmd("WATCH", "st"), b.cmd("SADD", "st", "m"), a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"))
    log("5 sadd new", a.cmd("WATCH", "st"), b.cmd("SADD", "st", "n"), a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"))
    r.cmd("SADD", "sm", "m", "q")
    log("5 smove there", a.cmd("WATCH", "st"), b.cmd("SMOVE", "sm", "st", "m"), a.cmd("MULTI"), a.cmd("PING"),
        a.cmd("EXEC"))
    log("5 smove new", a.cmd("WATCH", "st"), b.cmd("SMOVE", "sm", "st", "q"), a.cmd("MULTI"), a.cmd("PING"),
        a.cmd("EXEC"))
    r.cmd("RPUSH", "sol", "2", "1")
    log("5 sort store", a.cmd("WATCH", "sod"), b.cmd("SORT", "sol", "STORE", "sod"), a.cmd("MULTI"), a.cmd("PING"),
        a.cmd("EXEC"))
    log("5 sort store same", a.cmd("WATCH", "sod"), b.cmd("SORT", "sol", "STORE", "sod"), a.cmd("MULTI"),
        a.cmd("PING"), a.cmd("EXEC"))
    log("5 sort store empty", a.cmd("WATCH", "sod"), b.cmd("SORT", "nosol", "STORE", "sod"), a.cmd("MULTI"),
        a.cmd("PING"), a.cmd("EXEC"))
    log("5 sort store empty none", a.cmd("WATCH", "sod"), b.cmd("SORT", "nosol", "STORE", "sod"), a.cmd("MULTI"),
        a.cmd("PING"), a.cmd("EXEC"))
    log("5 sort read", a.cmd("WATCH", "sol"), b.cmd("SORT", "sol", "BY", "nosort"), b.cmd("SORT_RO", "sol", "ALPHA"),
        a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"))
    log("5 sort in multi", a.cmd("MULTI"), a.cmd("SORT", "sol", "DESC", "STORE", "sod"), a.cmd("LRANGE", "sod", "0", "-1"),
        a.cmd("SORT", "sol", "LIMIT", "x", "1"), a.cmd("SORT_RO", "sod", "ALPHA"), a.cmd("EXEC"))
    log("5 tx of another", a.cmd("WATCH", "t"), b.cmd("MULTI"), b.cmd("SET", "t", "1"), b.cmd("EXEC"), a.cmd("MULTI"),
        a.cmd("PING"), a.cmd("EXEC"))
    # 6. FLUSHALL, FLUSHDB and SWAPDB
    r.cmd("SET", "x", "30")
    log("6 flushall", a.cmd("WATCH", "x"), b.cmd("FLUSHALL"), a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"))
    log("6 flushall none", a.cmd("WATCH", "x"), b.cmd("FLUSHALL"), a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"))
    r.cmd("SET", "x", "30")
    log("6 flushdb", a.cmd("WATCH", "x"), b.cmd("FLUSHDB"), a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"))
    log("6 flushdb none", a.cmd("WATCH", "x"), b.cmd("FLUSHDB"), a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"))
    log("6 flushdb other db", a.cmd("SET", "x", "1"), a.cmd("WATCH", "x"), b.cmd("SELECT", "5"), b.cmd("FLUSHDB"),
        a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"), b.cmd("SELECT", "9"))
    r.cmd("FLUSHALL")
    r.cmd("SET", "x", "30")
    log("6 swapdb there", a.cmd("WATCH", "x"), b.cmd("SWAPDB", "9", "8"), a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"))
    log("6 swapdb comes", a.cmd("WATCH", "x"), b.cmd("SWAPDB", "9", "8"), a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"))
    log("6 swapdb none", a.cmd("WATCH", "zz"), b.cmd("SWAPDB", "9", "8"), a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"))
    log("6 swapdb same", a.cmd("WATCH", "x"), b.cmd("SWAPDB", "9", "9"), a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"))
    r.cmd("FLUSHALL")
    # 7. MOVE, COPY, RENAME, EXPIRE, a key of another database
    r.cmd("SET", "mv", "1")
    log("7 move", a.cmd("SELECT", "2"), a.cmd("WATCH", "mv"), a.cmd("SELECT", "9"), b.cmd("MOVE", "mv", "2"),
        a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"))
    r.cmd("SET", "cp", "1")
    log("7 copy dst", a.cmd("WATCH", "cp2"), b.cmd("COPY", "cp", "cp2"), a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"))
    log("7 copy src", a.cmd("WATCH", "cp"), b.cmd("COPY", "cp", "cp3"), a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"))
    log("7 rename", a.cmd("WATCH", "rn2"), b.cmd("RENAME", "cp", "rn2"), a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"))
    log("7 expire", a.cmd("WATCH", "rn2"), b.cmd("EXPIRE", "rn2", "100"), a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"))
    log("7 other db", a.cmd("SELECT", "5"), a.cmd("SET", "x", "30"), a.cmd("WATCH", "x"), a.cmd("SELECT", "1"),
        a.cmd("SET", "x", "10"), a.cmd("SELECT", "5"), a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"), a.cmd("SELECT", "9"))
    # 8. keys that expire
    log("8 expired", a.cmd("SET", "ex", "1", "PX", "100"), a.cmd("WATCH", "ex"))
    time.sleep(0.25)
    log("8 exec", a.cmd("MULTI"), a.cmd("INCR", "ex"), a.cmd("EXEC"))
    log("8 stale", a.cmd("SET", "st2", "foo", "PX", "1"))
    time.sleep(0.05)
    log("8 stale exec", a.cmd("WATCH", "st2"), a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"))
    # 9. UNWATCH, DISCARD and EXEC forget a touch
    r.cmd("SET", "x", "30")
    log("9 unwatch", a.cmd("WATCH", "x"), b.cmd("SET", "x", "40"), a.cmd("UNWATCH"), a.cmd("MULTI"), a.cmd("PING"),
        a.cmd("EXEC"))
    log("9 discard", a.cmd("WATCH", "x"), b.cmd("SET", "x", "41"), a.cmd("MULTI"), a.cmd("DISCARD"), a.cmd("MULTI"),
        a.cmd("INCR", "x"), a.cmd("EXEC"))
    log("9 after exec", a.cmd("WATCH", "x"), a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"), b.cmd("SET", "x", "1"),
        a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"))
    log("9 after failed exec", a.cmd("WATCH", "x"), b.cmd("SET", "x", "2"), a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"),
        b.cmd("SET", "x", "3"), a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"))
    # 10. blocking commands inside EXEC, and clients that wait served after it
    log("10 no wait", a.cmd("MULTI"), a.cmd("BLPOP", "nolist", "0"), a.cmd("BLMOVE", "nolist", "x2", "LEFT", "LEFT", "0"),
        a.cmd("BZPOPMIN", "nozset", "0"), a.cmd("EXEC"))
    b.send("BLPOP", "bq", "0")
    log("10 blocked", wait_blocked(r, 1))
    log("10 exec", a.cmd("MULTI"), a.cmd("RPUSH", "bq", "1"), a.cmd("LPOP", "bq"), a.cmd("RPUSH", "bq", "2", "3"),
        a.cmd("LLEN", "bq"), a.cmd("EXEC"))
    log("10 served", b.read(), wait_blocked(r, 0), r.cmd("LRANGE", "bq", "0", "-1"))
    # 11. CLIENT REPLY OFF and SKIP around a transaction
    a.send("CLIENT", "REPLY", "OFF")
    a.send("MULTI")
    a.send("SET", "ro", "1")
    a.send("EXEC")
    log("11 off", a.cmd("CLIENT", "REPLY", "ON"), a.cmd("GET", "ro"))
    a.send("CLIENT", "REPLY", "SKIP")
    a.send("MULTI")
    log("11 skip", a.cmd("SET", "sk", "1"), a.cmd("EXEC"), a.cmd("GET", "sk"))
    # 12. INFO's statistics (info.tcl)
    r.cmd("CONFIG", "RESETSTAT")
    log("12 failed in exec", a.cmd("MULTI"), a.cmd("SET", "a", "b"), a.cmd("AUTH", "a"), a.cmd("EXEC"), a.cmd("EXEC"),
        stats(r, "cmdstat_set", "cmdstat_auth", "cmdstat_exec", "cmdstat_multi", "errorstat_ERR"))
    r.cmd("CONFIG", "RESETSTAT")
    log("12 rejected in multi", a.cmd("MULTI"), a.cmd("SET"), a.cmd("EXEC"),
        stats(r, "cmdstat_set", "cmdstat_multi", "cmdstat_exec", "errorstat_ERR", "errorstat_EXECABORT"))
    r.cmd("CONFIG", "RESETSTAT")
    log("12 the others", a.cmd("WATCH", "k"), a.cmd("UNWATCH"), a.cmd("MULTI"), a.cmd("MULTI"), a.cmd("WATCH", "k"),
        a.cmd("DISCARD"), a.cmd("DISCARD"), a.cmd("EXEC", "x"),
        stats(r, "cmdstat_watch", "cmdstat_unwatch", "cmdstat_multi", "cmdstat_discard", "cmdstat_exec",
              "errorstat_ERR", "errorstat_EXECABORT"))
    r.cmd("CONFIG", "RESETSTAT")
    for c in (a, b, r):
        c.close()


def load(port):
    bad = []
    r = Client(port)
    r.cmd("FLUSHALL")
    # 20 clients add 1000 to a counter, each race lost retried
    r.cmd("SET", "ctr", "0")
    retries = []

    def adder(n):
        c = Client(port)
        lost = 0
        for _ in range(n):
            while True:
                c.cmd("WATCH", "ctr")
                v = int(c.cmd("GET", "ctr"))
                c.cmd("MULTI")
                c.cmd("SET", "ctr", str(v + 1))
                if c.cmd("EXEC") != "NULLA":
                    break
                lost += 1
        retries.append(lost)
        c.close()

    ths = [threading.Thread(target=adder, args=(50,)) for _ in range(20)]
    for t in ths:
        t.start()
    for t in ths:
        t.join()
    if r.cmd("GET", "ctr") != "1000":
        bad.append("the counter is %s, not 1000" % r.cmd("GET", "ctr"))
    # a reader never sees half of a transaction
    r.cmd("MSET", "ta", "0", "tb", "0")
    torn = []
    stop = []

    def reader():
        c = Client(port)
        while not stop:
            x, y = c.cmd("MGET", "ta", "tb")
            if x != y:
                torn.append((x, y))
        c.close()

    rd = threading.Thread(target=reader)
    rd.start()
    w = Client(port)
    for _ in range(500):
        w.send("MULTI")
        w.send("INCR", "ta")
        w.send("INCR", "tb")
        w.send("EXEC")
        w.read(), w.read(), w.read(), w.read()
    stop.append(True)
    rd.join()
    if torn:
        bad.append("a reader saw half of a transaction: %r" % (torn[:3],))
    if r.cmd("MGET", "ta", "tb") != ["500", "500"]:
        bad.append("500 transactions left %r" % (r.cmd("MGET", "ta", "tb"),))
    w.close()
    # 100 clients close in MULTI or watching keys; then all runs as before
    cs = [Client(port) for _ in range(100)]
    for i, c in enumerate(cs):
        c.cmd("WATCH", "gone%d" % i, "shared")
        if i % 2:
            c.cmd("MULTI")
            c.cmd("SET", "gone%d" % i, "1")
    for c in cs:
        c.close()
    time.sleep(0.2)
    if r.cmd("SET", "shared", "1") != "+OK" or r.cmd("EXISTS", *["gone%d" % i for i in range(100)]) != ":0":
        bad.append("the clients gone left something behind")
    c = Client(port)
    got = [c.cmd("WATCH", "shared"), c.cmd("MULTI"), c.cmd("INCR", "shared"), c.cmd("EXEC")]
    if got != ["+OK", "+OK", "+QUEUED", [":2"]]:
        bad.append("a transaction after the clients left: %r" % (got,))
    c.close()
    r.cmd("FLUSHALL")
    r.close()
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, required=True)
    ap.add_argument("--redis", type=int, required=True)
    args = ap.parse_args()
    outs = []
    for port in (args.bendkv, args.redis):
        lines = []
        try:
            scenarios(port, lambda *x: lines.append(" ".join(repr(v) for v in x)))
        except Exception as e:
            lines.append("EXCEPTION %r" % (e,))
        outs.append(lines)
    bad = 0
    for i in range(max(len(outs[0]), len(outs[1]))):
        x = outs[0][i] if i < len(outs[0]) else "<none>"
        y = outs[1][i] if i < len(outs[1]) else "<none>"
        if x != y:
            bad += 1
            if bad <= 20:
                print("FAIL: BendKV %s\n      Redis  %s" % (x, y))
    fails = load(args.bendkv)
    for f in fails:
        print("FAIL: under load:", f)
    if bad or fails:
        print("FAIL: %d of %d lines of the scenarios differ, %d checks under load fail" % (bad, len(outs[1]), len(fails)))
        sys.exit(1)
    print("OK: %d lines of transaction scenarios as Redis answers them, and 3 checks under load" % len(outs[1]))


if __name__ == "__main__":
    main()
