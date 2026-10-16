#!/usr/bin/env python3
"""CLIENT PAUSE and CLIENT UNPAUSE against Redis: scenarios run on BendKV
and on Redis with clients of their own, the transcripts compared line by
line; then checks of BendKV alone, and under load.

The scenarios: the commands' errors, in Redis's order; a pause of
writes (WRITE) that lets reads, PING and CLIENT run and holds back the
commands that write or may be replicated (PFCOUNT, PUBLISH, a blocking
command), the client held back as CLIENT LIST and INFO show it (flags b,
its command, its arguments' size, blocked_clients) and its call counted
only once it runs; a pause of every command (ALL) that ends at its
time, with a CLIENT UNPAUSE and a QUIT held back until then; MULTI under
a pause (a read queued, a write held back before it is queued, EXEC held
back when its transaction queued a write, DISCARD); a pause that a
transaction starts, whose writes after it run; a pause and a write in
one pipeline; keys whose time passes while a pause holds (read as gone,
not deleted, expired_keys unchanged until the pause ends); a client with
a subscription (a GET refused at once under ALL, its commands of
Pub/Sub held back, and what it sends after them), a PUBLISH held back
under WRITE; a monitor, which no
pause holds back; a pause of writes that a second pause makes one of
every command; a blocking command held back, then waiting once the pause
ends, and one that waited before it, whose time ends while it holds; the
order in which the clients held back go on; a client held back whose
connection closes, and one killed; errors of the parser, answered at
once.

A monitor made before a pause of every command ends it (Mon): no pause
holds a monitor back, while a client made during such a pause would have
its SELECT, and its MONITOR, held back with the rest. A monitor turns
BendKV's fast way off for every client, so one is connected only around
the three pauses of every command that no client of a scenario can end
(scenarios 8, 9 and 13): the other scenarios run the fast way.
A scenario that raises fails the test, on either server: one that raised
on both used to end both transcripts alike after the second scenario.

The checks of BendKV alone: CLIENT UNBLOCK of a client held back answers
0 and leaves it held back (Redis 7.0.15 crashes on it). The checks under
load: 100 clients held back, each with a write, all answered in order
once the pause ends, and 100 more released by the end of a pause's
time. Scripts under a pause are tests/script_test.py's (scenario 11).

    python3 tests/pause_test.py --bendkv 6380 --redis 6390
"""
import argparse
import re
import sys
import time

from blocking_test import Client, info_lines, wait_blocked
from client_test import Named, norm

STATS = ("cmdstat_set:", "cmdstat_get:", "cmdstat_client|pause:", "cmdstat_client|unpause:", "cmdstat_exec:")


def stats(r):
    return sorted(re.sub(r"usec=\d+,usec_per_call=[0-9.]+,", "", l) for l in info_lines(r, "commandstats", STATS))


def expired(r):
    return int(info_lines(r, "stats", "expired_keys:")[0].split(":")[1])


def listed(r, c, cs):
    """c's line of CLIENT LIST as client_test reads it, its age put aside:
    the scenarios before scenario 4 take about two seconds, so c's age falls
    on either side of client_test's mark of 2 on either server."""
    got = norm(r.cmd("CLIENT", "LIST", "ID", c.id), cs)
    return [re.sub(r"\bage=\S+", "age=X", l) for l in got] if isinstance(got, list) else got


# a line a monitor is fed: "+<time> [<db> <addr>] <command>"
FEED = re.compile(r"^\+\d+\.\d+ \[")


class Mon:
    """A monitor, made before a pause of every command: no pause holds a
    monitor back (Redis never pauses a replica), so its CLIENT UNPAUSE ends
    such a pause, which holds back a new client's MONITOR too. Its replies
    are read past the lines it is fed. It is used in a with statement: an
    exception in it ends the pause before the monitor closes."""

    def __init__(self, port):
        self.c = Client(port, None)
        self.first = self.c.cmd("MONITOR")

    def __enter__(self):
        return self

    def __exit__(self, kind, value, tb):
        if kind is not None:
            self.cmd("CLIENT", "UNPAUSE")
        self.close()
        return False

    def cmd(self, *args):
        while self.c.read(0.05) != "TIMEOUT":
            pass
        self.c.send(*args)
        while True:
            x = self.c.read()
            if not (isinstance(x, str) and FEED.match(x)):
                return x

    def close(self):
        self.c.close()


def scenarios(port, log):
    r = Client(port)
    r.cmd("FLUSHALL")
    r.cmd("CONFIG", "RESETSTAT")
    a, b = Named(port, "a"), Named(port, "b")
    # 1. errors, in Redis's order: the mode before the timeout
    for args in ([], ["abc", "foo"], ["abc"], ["-1"], ["-0"], ["1", "write", "x"],
                 ["99999999999999999999"], ["10", "WrItE"], ["0", "all"], ["1.5"], ["", "write"]):
        log("1 pause", args, r.cmd("CLIENT", "PAUSE", *args))
    log("1 unpause", r.cmd("CLIENT", "UNPAUSE"), r.cmd("CLIENT", "UNPAUSE", "x"))
    log("1 a timeout of 0 holds nothing", r.cmd("CLIENT", "PAUSE", "0", "WRITE"), a.cmd("SET", "z", "1"))
    # 2. a pause of writes
    log("2 pause", r.cmd("CLIENT", "PAUSE", "100000", "WRITE"))
    log("2 reads", a.cmd("GET", "z"), a.cmd("EXISTS", "z"), a.cmd("PING"), a.cmd("CLIENT", "GETNAME"))
    a.send("SET", "x", "1")
    log("2 held", wait_blocked(r, 1), a.read(0.2))
    log("2 list", listed(r, a, [a, b]))
    log("2 stats", stats(r))
    b.send("PFCOUNT", "h")
    log("2 pfcount", wait_blocked(r, 2))
    log("2 unpause", r.cmd("CLIENT", "UNPAUSE"))
    log("2 replies", a.read(), b.read(), wait_blocked(r, 0))
    log("2 stats", stats(r))
    r.cmd("CLIENT", "PAUSE", "100000", "WRITE")
    a.send("PUBLISH", "ch", "m")
    b.send("BLPOP", "bl", "0")
    log("2 publish and blpop", wait_blocked(r, 2))
    r.cmd("CLIENT", "UNPAUSE")
    log("2 publish", a.read(), wait_blocked(r, 1))
    log("2 push", r.cmd("RPUSH", "bl", "v"), b.read())
    # 3. a pause of every command, to its end (the client that QUITs made
    # before it, as the pause would hold its SELECT back)
    q = Client(port, None)
    t0 = time.time()
    log("3 pause", r.cmd("CLIENT", "PAUSE", "500", "ALL"))
    a.send("PING")
    b.send("CLIENT", "UNPAUSE")
    q.send("QUIT")
    log("3 held", a.read(0.1), b.read(0.1), q.read(0.1))
    log("3 ended", a.read(), b.read(), q.read(), 0.4 < time.time() - t0 < 2.0)
    try:
        log("3 quit closed", q.read(0.5))
    except EOFError:
        log("3 quit closed", "CLOSED")
    q.close()
    # 4. MULTI under a pause of writes
    r.cmd("CLIENT", "PAUSE", "100000", "WRITE")
    log("4 multi", a.cmd("MULTI"), a.cmd("GET", "x"))
    a.send("SET", "x", "2")
    log("4 set held", a.read(0.2), wait_blocked(r, 1))
    log("4 list", listed(r, a, [a, b]))
    r.cmd("CLIENT", "UNPAUSE")
    log("4 set queued", a.read())
    r.cmd("CLIENT", "PAUSE", "100000", "WRITE")
    a.send("EXEC")
    log("4 exec held", a.read(0.2), wait_blocked(r, 1))
    log("4 multi b", b.cmd("MULTI"), b.cmd("GET", "x"), b.cmd("EXEC"))
    b.send("MULTI")
    b.send("INCR", "x")
    log("4 incr held", b.read(), b.read(0.2))
    r.cmd("CLIENT", "UNPAUSE")
    log("4 exec", a.read(), b.read(), b.cmd("DISCARD"))
    # 5. a pause a transaction starts: its writes after it run
    log("5 tx", a.cmd("MULTI"), a.cmd("SET", "t1", "a"), a.cmd("CLIENT", "PAUSE", "100000", "WRITE"),
        a.cmd("SET", "t2", "b"), a.cmd("EXEC"))
    b.send("SET", "t3", "c")
    log("5 held", wait_blocked(r, 1), r.cmd("MGET", "t1", "t2", "t3"))
    r.cmd("CLIENT", "UNPAUSE")
    log("5 b", b.read(), r.cmd("GET", "t3"))
    # 6. a pause and a write in one pipeline
    a.raw(b"CLIENT PAUSE 300 WRITE\r\nSET p 1\r\nGET p\r\n")
    log("6 first", a.read(), a.read(0.1))
    log("6 later", a.read(), a.read())
    # 7. keys whose time passes while a pause holds
    e0 = expired(r)
    a.raw(b"MULTI\r\nSET foo bar PX 10\r\nSET bar foo PX 10\r\nCLIENT PAUSE 50000 WRITE\r\nEXEC\r\n")
    log("7 tx", [a.read() for _ in range(5)])
    time.sleep(0.4)
    log("7 gone", r.cmd("GET", "foo"), r.cmd("EXISTS", "bar"), r.cmd("DBSIZE"), expired(r) - e0)
    log("7 unpause", r.cmd("CLIENT", "UNPAUSE"), r.cmd("GET", "foo"), r.cmd("GET", "bar"))
    log("7 expired", expired(r) - e0, r.cmd("DBSIZE"))
    # 8. a client with a subscription; PUBLISH
    s = Client(port)
    log("8 subscribe", s.cmd("SUBSCRIBE", "ch"))
    with Mon(port) as mon:
        log("8 monitor", mon.first)
        r.cmd("CLIENT", "PAUSE", "100000", "ALL")
        log("8 get", s.cmd("GET", "x"))
        s.send("SUBSCRIBE", "ch2")
        log("8 held", s.read(0.2))
        s.send("PING")
        log("8 unpause", mon.cmd("CLIENT", "UNPAUSE"), s.read(), s.read())
        log("8 monitor get", mon.cmd("GET", "x"))
    r.cmd("CLIENT", "PAUSE", "100000", "WRITE")
    a.send("PUBLISH", "ch", "hello")
    log("8 publish held", a.read(0.2), s.read(0.2))
    r.cmd("CLIENT", "UNPAUSE")
    log("8 publish", a.read(), s.read())
    s.close()
    # 9. a pause of writes made one of every command
    r.cmd("CLIENT", "PAUSE", "100000", "WRITE")
    log("9 read", a.cmd("GET", "x"))
    with Mon(port) as mon:
        log("9 all", r.cmd("CLIENT", "PAUSE", "0", "ALL"))
        a.send("GET", "x")
        log("9 read held", a.read(0.2))
        log("9 unpause", mon.cmd("CLIENT", "UNPAUSE"), a.read())
    # 10. a blocking command that waited before the pause times out
    a.send("BLPOP", "nokey", "0.3")
    wait_blocked(r, 1)
    r.cmd("CLIENT", "PAUSE", "100000", "WRITE")
    log("10 timeout", a.read(), wait_blocked(r, 0))
    r.cmd("CLIENT", "UNPAUSE")
    # 11. the order in which the clients held back go on
    cs = [Client(port) for _ in range(3)]
    r.cmd("CLIENT", "PAUSE", "100000", "WRITE")
    for i, c in enumerate(cs):
        c.send("APPEND", "order", str(i))
        wait_blocked(r, i + 1)
    log("11 unpause", r.cmd("CLIENT", "UNPAUSE"), [c.read() for c in cs], r.cmd("GET", "order"))
    for c in cs:
        c.close()
    # 12. a client held back whose connection closes, and one killed
    r.cmd("CLIENT", "PAUSE", "100000", "WRITE")
    g = Client(port)
    g.send("SET", "gone", "1")
    log("12 held", wait_blocked(r, 1))
    g.close()
    log("12 closed", wait_blocked(r, 0))
    k = Named(port, "k")
    k.send("SET", "killed", "1")
    wait_blocked(r, 1)
    log("12 kill", r.cmd("CLIENT", "KILL", "ID", k.id), wait_blocked(r, 0))
    r.cmd("CLIENT", "UNPAUSE")
    log("12 never written", r.cmd("EXISTS", "gone", "killed"))
    k.close()
    # 13. errors of the parser are answered at once
    with Mon(port) as mon:
        r.cmd("CLIENT", "PAUSE", "100000", "ALL")
        log("13 errors", a.cmd("SET", "x"), a.cmd("NOSUCHCOMMAND"), a.cmd("CLIENT", "NOSUCH"))
        log("13 unpause", mon.cmd("CLIENT", "UNPAUSE"))
    log("13 info", info_lines(r, "clients", ("blocked_clients",)))
    r.cmd("FLUSHALL")
    for c in (r, a, b):
        c.close()


def alone(port):
    """Checks of BendKV alone: what Redis does differently, and load."""
    bad = []
    r = Client(port)
    r.cmd("FLUSHALL")
    a = Named(port, "a")
    r.cmd("CLIENT", "PAUSE", "100000", "WRITE")
    a.send("SET", "u", "1")
    wait_blocked(r, 1)
    if r.cmd("CLIENT", "UNBLOCK", a.id) != ":0" or r.cmd("CLIENT", "UNBLOCK", a.id, "ERROR") != ":0":
        bad.append("CLIENT UNBLOCK of a client held back did not answer 0")
    if a.read(0.2) != "TIMEOUT" or wait_blocked(r, 1) != 1:
        bad.append("CLIENT UNBLOCK let a client held back go")
    r.cmd("CLIENT", "UNPAUSE")
    if a.read() != "+OK":
        bad.append("the client held back was not answered")
    a.close()
    # 100 clients held back, answered in order once the pause ends
    cs = [Client(port) for _ in range(100)]
    r.cmd("CLIENT", "PAUSE", "100000", "WRITE")
    for i, c in enumerate(cs):
        c.send("RPUSH", "load", str(i))
    if wait_blocked(r, 100, 1000) != 100:
        bad.append("100 clients: %d held back" % wait_blocked(r, 100, 1))
    r.cmd("CLIENT", "UNPAUSE")
    got = [c.read() for c in cs]
    if got != [":%d" % (i + 1) for i in range(100)] or r.cmd("LRANGE", "load", "0", "-1") != [str(i) for i in range(100)]:
        bad.append("100 clients not answered in order: %r" % (got[:5],))
    # 100 more, released by the end of the pause's time
    r.cmd("CLIENT", "PAUSE", "300", "ALL")
    for i, c in enumerate(cs):
        c.send("INCR", "n")
    got = sorted(c.read() for c in cs)
    if got != sorted(":%d" % (i + 1) for i in range(100)) or wait_blocked(r, 0) != 0:
        bad.append("a pause's end released %r" % (got[:5],))
    for c in cs:
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
            # a pause of every command was ended on leaving its Mon; a
            # pause of writes holds no CLIENT UNPAUSE back
            c = Client(port, None)
            c.cmd("CLIENT", "UNPAUSE")
            c.close()
        outs.append(lines)
    # a scenario that raises on both servers ends both transcripts alike,
    # and the scenarios after it never run: that fails too
    stopped = 0
    for name, lines in zip(("BendKV", "Redis"), outs):
        for l in lines:
            if l.startswith("EXCEPTION"):
                stopped += 1
                print("FAIL: %s's scenarios stopped: %s" % (name, l))
    bad = 0
    for i in range(max(len(outs[0]), len(outs[1]))):
        x = outs[0][i] if i < len(outs[0]) else "<none>"
        y = outs[1][i] if i < len(outs[1]) else "<none>"
        if x != y:
            bad += 1
            if bad <= 20:
                print("FAIL: BendKV %s\n      Redis  %s" % (x, y))
    fails = alone(args.bendkv)
    for f in fails:
        print("FAIL: BendKV alone:", f)
    if bad or stopped or fails:
        print("FAIL: %d of %d lines of the scenarios differ, %d transcripts stopped, %d checks of BendKV alone fail"
              % (bad, len(outs[1]), stopped, len(fails)))
        sys.exit(1)
    print("OK: %d lines of pause scenarios as Redis answers them, and 3 checks of BendKV alone" % len(outs[1]))


if __name__ == "__main__":
    main()
