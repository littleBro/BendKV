#!/usr/bin/env python3
"""MONITOR against Redis: scenarios run on BendKV and on Redis with
clients of their own, the transcripts compared line by line; then checks
of BendKV alone under load.

A monitor's line is compared with what differs between two servers by
nature put aside: its time (BendKV's is the time its actor runs the
group at, in ms, where Redis reads its clock for each call: only the
form is compared) and the client's address, read as the client it is
(each test client knows its own from CLIENT INFO). The database and the
arguments, as the client sent them and as Redis quotes them, are
compared as they are. A monitor's lines are read up to a marker: a
command of a client of its own (ECHO with a word of its own) whose line
comes after those of the commands before it.

The scenarios follow Redis's unit/introspection and what monitorCommand,
call() and replicationFeedMonitors do: the lines of commands as sent
(their case, quoted bytes, an inline request split, numbers, a long
request in three reads), what is not shown (unknown commands, the wrong
number of arguments, CONFIG, CLIENT LIST, KILL and NO-EVICT, MONITOR),
transactions (MULTI, the queued commands at EXEC, before EXEC; errors,
DISCARD, a nested MULTI, WATCH, an EXEC refused), the database after
SELECT and SWAPDB, the redaction of AUTH and HELLO, blocking commands
(shown when they block, not when served; the rest of a pipeline after
one), the monitor's own commands (its reply first, then its line; a
command that reads or writes keys refused; MONITOR again answered
nothing; MULTI), a subscribed client, a subscribed monitor, CLIENT REPLY
OFF and SKIP of a monitor, RESET and QUIT of a monitor, a client without
a password, a monitor started while a transaction is queued or a client
waits with a pipeline after its blocking command, CLIENT LIST's flag O,
CLIENT KILL of a monitor, and the statistics of INFO.

The checks under load: four monitors and 20 clients that each pipeline
200 commands: each monitor gets every line, each client's in its order.

    python3 tests/monitor_test.py --bendkv 6380 --redis 6390
"""
import argparse
import re
import sys
import threading
import time

from blocking_test import Client, enc
from client_test import Named, closed, norm, stats

LINE = re.compile(r"^\+(\d+)\.(\d{6}) \[(\d+) (\S+)\] (.*)$")
MARK = re.compile(r'"ECHO" "__mark\d+__"$')


def nm(x, cs):
    """A reply, a monitor's line with its time and the client's address
    put aside, a client's line (CLIENT INFO) as client_test reads it."""
    if isinstance(x, list):
        return [nm(y, cs) for y in x]
    m = LINE.match(x) if isinstance(x, str) else None
    if m:
        tag = next((c.tag for c in cs if c.addr == m.group(4)), "?")
        return "+T [%s %s] %s" % (m.group(3), tag, m.group(5))
    return norm(x, cs)


def skip(x, cs):
    """Lines of no scenario's: an earlier marker's, the waiting client's."""
    m = LINE.match(x) if isinstance(x, str) else None
    return bool(m) and (MARK.search(m.group(5)) is not None or
                        any(c.tag == "w" and c.addr == m.group(4) for c in cs))


class Marks:
    """What a monitor gets up to a marker (a command of z's)."""

    def __init__(self, z):
        self.z = z
        self.n = 0

    def lines(self, m, cs):
        self.n += 1
        tok = "__mark%d__" % self.n
        if self.z.cmd("ECHO", tok) != tok:
            return ["MARK FAILED"]
        out = []
        while True:
            x = m.read(3.0)
            if x == "TIMEOUT":
                out.append("TIMEOUT")
                return out
            if isinstance(x, str) and x.endswith('"ECHO" "%s"' % tok):
                return out
            if not skip(x, cs):
                out.append(nm(x, cs))


    def own(self, m, cs):
        """What a monitor gets of its own commands, then up to a marker. The
        marker is sent once the monitor's first reply or line has come: a
        server runs a client's batch through before it reads another's
        bytes, but the monitor's batch and the marker reach it from two
        sockets, and it may read the marker first (seen on Redis under
        load), so the marker waits until the monitor's batch has run."""
        first = m.read(3.0)
        head = [] if first == "TIMEOUT" or skip(first, cs) else [nm(first, cs)]
        return head + self.lines(m, cs)


def ran(r, c, name):
    """Waits until the server has run c's command name (CLIENT LIST's
    cmd=, which no monitor is shown): a command that answers nothing gives
    no reply to wait on, and the next client's command could overtake it."""
    for _ in range(500):
        if "cmd=%s " % name in r.cmd("CLIENT", "LIST", "ID", c.id):
            return
        time.sleep(0.01)


def drain(m, cs, t=0.4):
    """What a monitor gets in a while (when a marker's line would not come)."""
    out = []
    while True:
        x = m.read(t)
        if x == "TIMEOUT":
            return out
        if not skip(x, cs):
            out.append(nm(x, cs))


def waiting(w, n):
    """Waits until n clients wait (w's lines are no scenario's)."""
    for _ in range(300):
        if "blocked_clients:%d\r" % n in w.cmd("INFO", "clients") + "\r":
            return
        time.sleep(0.01)


def scenarios(port, log):
    r = Named(port, "r")
    r.cmd("FLUSHALL")
    r.cmd("CONFIG", "RESETSTAT")
    a = Named(port, "a")
    b = Named(port, "b")
    z = Named(port, "z")
    w = Named(port, "w")
    m = Named(port, "m")
    cs = [r, a, b, z, w, m]
    mk = Marks(z)
    # 1. the lines of commands as sent: their case, then not before MONITOR
    a.cmd("SET", "before", "1")
    log("1 monitor", m.cmd("MONITOR"), a.cmd("set", "foo", "bar"), a.cmd("Get", "foo"), mk.lines(m, cs))
    # 2. quoted bytes, an inline request, numbers
    log("2 bytes", a.cmd("SET", b"k\x00\x01\x7f", b'a"b\\c\td\xff\xc3\r\n\x07\x08 '), mk.lines(m, cs))
    a.raw(b'set "x y" \'p\\\'q\'\r\nset   sp   "\\x41\\n"  \r\n')
    log("2 inline", a.read(), a.read(), mk.lines(m, cs))
    a.raw(enc(["SET", "n", "12345"]) + enc(["INCR", "n"]) + enc(["SET", "n", "-0"]) + enc(["SET", "n", "007"]))
    log("2 numbers", [a.read() for _ in range(4)], mk.lines(m, cs))
    log("2 empty", a.cmd("SET", "", ""), a.cmd("GET", ""), mk.lines(m, cs))
    # a long request in three reads: the parse goes on from the bulk each
    # read stopped in (issue #85), and its line shows all its arguments
    big = enc(["RPUSH", "L"] + ["e%011d" % i for i in range(400)])
    k1, k2 = big.index(b"\r\n$", 2100) + 9, big.index(b"\r\n$", 5000) + 5
    a.raw(big[:k1])
    time.sleep(0.2)
    a.raw(big[k1:k2])
    time.sleep(0.2)
    a.raw(big[k2:] + enc(["SET", "after", "1"]))
    log("2 long", a.read(), a.read(), mk.lines(m, cs))
    # 3. what is not shown, and what is
    log("3 unseen", a.cmd("NOSUCH", "x"), a.cmd("GET"), a.cmd("CONFIG", "GET", "maxmemory"), a.cmd("CONFIG", "NOSUCH"),
        a.cmd("CLIENT", "NOSUCH"), a.cmd("CLIENT", "INFO", "x"), a.cmd("CLIENT", "KILL", "ID", "999999"),
        a.cmd("CLIENT", "NO-EVICT", "off"), a.cmd("CONFIG", "SET", "maxmemory", "0"), a.cmd("MONITOR", "x"),
        mk.lines(m, cs))
    log("3 seen", a.cmd("CLIENT", "GETNAME"), a.cmd("CONFIG", "HELP")[:1], a.cmd("CLIENT", "HELP")[:1],
        a.cmd("SET", "k", "v", "EX", "abc"), a.cmd("LPUSH", "k", "x"), mk.lines(m, cs))
    # 4. transactions
    log("4 multi", a.cmd("MULTI"), a.cmd("SET", "foo", "bar"), mk.lines(m, cs), a.cmd("EXEC"), mk.lines(m, cs))
    log("4 multi error", a.cmd("MULTI"), a.cmd("syntax", "error"), a.cmd("EXEC"), mk.lines(m, cs))
    a.raw(enc(["MULTI"]) + enc(["DISCARD"]) + enc(["DISCARD"]) + enc(["MULTI"]) + enc(["MULTI"]) + enc(["WATCH", "x"]) +
          enc(["EXEC"]) + enc(["WATCH", "x"]) + enc(["UNWATCH"]) + enc(["EXEC", "foo"]))
    log("4 multi kin", [a.read() for _ in range(10)], mk.lines(m, cs))
    log("4 multi monitor", a.cmd("MULTI"), a.cmd("MONITOR"), a.cmd("EXEC"), mk.lines(m, cs))
    # 5. the database after the command
    log("5 db", a.cmd("SELECT", "3"), a.cmd("SET", "x", "1"), a.cmd("SELECT", "9"), a.cmd("SWAPDB", "3", "4"),
        a.cmd("SWAPDB", "3", "4"), a.cmd("MOVE", "k", "3"), mk.lines(m, cs))
    # 6. AUTH and HELLO redacted as Redis reads them
    log("6 auth", a.cmd("AUTH", "pw"), a.cmd("AUTH", "user", "pw"), a.cmd("AUTH", "a", "b", "c"), mk.lines(m, cs))
    log("6 hello", a.cmd("HELLO", "4", "AUTH", "u", "p"), a.cmd("HELLO", "2", "FOO", "AUTH", "u", "p"),
        a.cmd("HELLO", "2", "AUTH", "u", "p", "FOO"), a.cmd("HELLO", "2", "AUTH", "u"),
        a.cmd("HELLO", "x", "AUTH", "u", "p"), a.cmd("HELLO", "2", "AUTH", "default", "x")[:2],
        a.cmd("HELLO", "2", "SETNAME", "foo", "AUTH", "default", "x")[:2],
        a.cmd("HELLO", "2", "auth", "default", "x", "auth"), a.cmd("HELLO")[:2], mk.lines(m, cs))
    # 7. blocking commands: shown as they block, not as they are served
    log("7 timeout", a.cmd("BLPOP", "nolist", "0.1"), mk.lines(m, cs))
    a.send("BLPOP", "somelist", "0")
    waiting(w, 1)
    log("7 served", b.cmd("RPUSH", "somelist", "x"), a.read(), mk.lines(m, cs))
    a.raw(enc(["BLPOP", "bl", "0"]) + enc(["SET", "after", "1"]))
    waiting(w, 1)
    log("7 pipeline", b.cmd("RPUSH", "bl", "x"), a.read(), a.read(), mk.lines(m, cs))
    # 8. the monitor's own commands: the reply, then the line (each step's
    # commands in one write, so that they are one batch, read at once as
    # Redis reads them)
    m.raw(b"".join(enc(c) for c in (["PING"], ["GET", "x"], ["PUBLISH", "c", "msg"], ["ECHO", "hi"], ["DBSIZE"],
                                    ["CLIENT", "INFO"], ["SELECT", "2"], ["SELECT", "9"])))
    log("8 own", mk.own(m, cs))
    m.raw(enc(["MONITOR"]) + enc(["PING", "again"]))
    log("8 again", mk.own(m, cs))
    m.raw(enc(["MULTI"]) + enc(["PING"]) + enc(["GET", "x"]) + enc(["EXEC"]))
    log("8 multi", mk.own(m, cs))
    m.raw(enc(["MULTI"]) + enc(["PING"]) + enc(["EXEC"]))
    log("8 exec", mk.own(m, cs))
    # 9. a subscribed client, and a subscribed monitor
    a.send("SUBSCRIBE", "ch")
    log("9 sub", a.read(), mk.lines(m, cs))
    a.raw(enc(["MONITOR"]) + enc(["PING"]) + enc(["UNSUBSCRIBE"]))
    log("9 sub monitor", a.read(), a.read(), a.read(), mk.lines(m, cs))
    m.send("SUBSCRIBE", "c2")
    log("9 monitor sub", m.read(), b.cmd("PUBLISH", "c2", "hello"), mk.lines(m, cs))
    m.raw(enc(["PING"]) + enc(["CLIENT", "INFO"]))
    log("9 monitor sub ping", mk.own(m, cs))
    m.send("UNSUBSCRIBE")
    log("9 monitor unsub", mk.own(m, cs))
    # 10. CLIENT REPLY OFF and SKIP of a monitor
    m.send("CLIENT", "REPLY", "OFF")
    ran(r, m, "client|reply")
    log("10 off", a.cmd("SET", "k1", "v1"), drain(m, cs))
    log("10 on", m.cmd("CLIENT", "REPLY", "ON"), a.cmd("SET", "k2", "v2"), mk.lines(m, cs))
    m.send("CLIENT", "REPLY", "SKIP")
    log("10 skip", drain(m, cs), a.cmd("SET", "k3", "v3"), drain(m, cs))
    m.send("PING")
    log("10 skipped", drain(m, cs), a.cmd("SET", "k4", "v4"), mk.lines(m, cs))
    # 11. a client without a password (the others came before it, and
    # stay authenticated)
    log("11 pass", r.cmd("CONFIG", "SET", "requirepass", "pw"), mk.lines(m, cs))
    n = Client(port, db=None)
    log("11 noauth", n.cmd("GET", "x"), n.cmd("EXEC"), n.cmd("MULTI"), n.cmd("AUTH", "bad"), n.cmd("AUTH", "pw"),
        n.cmd("PING"), mk.lines(m, cs))
    n.close()
    log("11 nopass", r.cmd("CONFIG", "SET", "requirepass", ""), mk.lines(m, cs))
    # 12. monitors started while a transaction is queued, and while a
    # client waits with a pipeline after its blocking command
    m2 = Named(port, "m2")
    cs.append(m2)
    log("12 queued", a.cmd("MULTI"), a.cmd("SET", "q", "1"), m2.cmd("MONITOR"), a.cmd("EXEC"), mk.lines(m2, cs),
        mk.lines(m, cs))
    a.raw(enc(["BLPOP", "bl2", "0"]) + enc(["SET", "r", "1"]))
    waiting(w, 1)
    m3 = Named(port, "m3")
    cs.append(m3)
    log("12 waiting", m3.cmd("MONITOR"), b.cmd("RPUSH", "bl2", "x"), a.read(), a.read(), mk.lines(m3, cs),
        mk.lines(m2, cs))
    # 13. CLIENT LIST shows a monitor (O), a normal client
    lines = [l for l in r.cmd("CLIENT", "LIST", "TYPE", "normal").split("\n") if "addr=%s " % m.addr in l]
    log("13 list", [re.sub(r"\b(id|addr|laddr|fd|age|idle|qbuf-free|rbs|rbp|obl|tot-mem|multi-mem|qbuf|argv-mem)=\S*", "",
                           x) for x in lines], mk.lines(m, cs))
    # 14. RESET and QUIT of a monitor; CLIENT KILL of one
    log("14 reset", mk.lines(m3, cs), m3.cmd("RESET"), a.cmd("SET", "y", "2"), drain(m3, cs), mk.lines(m2, cs))
    m3.raw(enc(["MONITOR"]) + enc(["QUIT"]))
    log("14 quit", m3.read(), m3.read(), closed(m3), mk.lines(m2, cs))
    log("14 kill", r.cmd("CLIENT", "KILL", "ID", m2.id), closed(m2), a.cmd("SET", "z", "3"), mk.lines(m, cs))
    # 15. a pipeline with MONITOR in it
    m4 = Named(port, "m4")
    cs.append(m4)
    m4.raw(enc(["MONITOR"]) + enc(["PING"]) + enc(["MONITOR"]) + enc(["PING", "x"]))
    log("15 pipelined", mk.own(m4, cs))
    # 16. the statistics
    log("16 stats", stats(r, "cmdstat_monitor", "cmdstat_get", "cmdstat_publish", "cmdstat_dbsize", "cmdstat_exec",
                          "errorstat_ERR", "errorstat_EXECABORT", "errorstat_NOAUTH", "errorstat_WRONGPASS"))


def load(port):
    """Four monitors, 20 clients that each pipeline 200 commands: each
    monitor gets every line, each client's in its order."""
    bad = []
    r = Client(port, db=None)
    r.cmd("FLUSHALL")
    ms = [Client(port, db=None) for _ in range(4)]
    for m in ms:
        if m.cmd("MONITOR") != "+OK":
            bad.append("MONITOR answered not OK")
    cs = [Named(port, "c%d" % i) for i in range(20)]
    errs = []

    def run(c):
        try:
            c.raw(b"".join(enc(["SET", "%s:%d" % (c.tag, i), str(i)]) for i in range(200)))
            for _ in range(200):
                if c.read() != "+OK":
                    errs.append("a SET answered not OK")
                    return
        except Exception as e:
            errs.append("client: %r" % (e,))

    ts = [threading.Thread(target=run, args=(c,)) for c in cs]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    bad += errs[:3]
    for i, m in enumerate(ms):
        seen = {c.tag: [] for c in cs}
        n = 0
        while n < 4000:
            x = m.read(3.0)
            if x == "TIMEOUT":
                bad.append("monitor %d got %d lines of 4000" % (i, n))
                break
            g = LINE.match(x)
            if not g:
                continue
            k = re.match(r'"SET" "(c\d+):(\d+)"', g.group(5))
            if k:
                seen[k.group(1)].append(int(k.group(2)))
                n += 1
        for t, xs in seen.items():
            if xs != list(range(200)) and n == 4000:
                bad.append("monitor %d got %s's lines out of order" % (i, t))
                break
    for c in cs + ms:
        c.close()
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
    print("OK: %d lines of MONITOR scenarios as Redis answers them, and a check under load" % len(outs[1]))


if __name__ == "__main__":
    main()
