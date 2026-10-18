#!/usr/bin/env python3
"""CLIENT LIST, CLIENT INFO, CLIENT KILL, CLIENT NO-EVICT, CLIENT NO-TOUCH
and CLIENT SETINFO against Redis: scenarios run on BendKV and on Redis
with clients of their own,
the transcripts compared line by line; then checks of BendKV alone under
load.

A client's line is compared with what differs between two servers by
nature put aside: its id, its address and its socket's fd, read as the
client they are (each test client knows its own from CLIENT INFO), its
age and idle time (compared as whether they reach two seconds, as the
boundary of a second may fall between two steps), and the sizes of
Redis's buffers (qbuf-free, rbs, rbp, obl, tot-mem, multi-mem), which
BendKV does not keep. The rest is compared as it is: the name, the
flags, the database, the counts of subscriptions, multi, qbuf, argv-mem
(of the client that asks, without the lengths of the ids its command
carries, which differ), events and the last command.

The scenarios follow Redis's unit/introspection: a client's own line
(LIST and INFO, inline and in a pipeline), LIST of ids and of types, and
their errors; a client's name (SETNAME, HELLO SETNAME, RESET), database
(SELECT, RESET), last command (a command, an unknown one, one refused
for its arguments, a subcommand, the last of a pipeline) and idle time
as another client sees them; the flags (P with a subscription, and its
counts; x in MULTI, with the commands queued, and the client's own line
while EXEC runs them; b waiting, with its command's arguments; d with a
watched key touched; e with NO-EVICT on, T with NO-TOUCH on, and their
errors); NO-TOUCH's keys: a counter of access (OBJECT FREQ, with
lfu-log-factor 0, so that each access steps it) and an idle time (OBJECT
IDLETIME) left as they were by the commands of a client with NO-TOUCH
on, but TOUCH's, those of a pipeline after the CLIENT NO-TOUCH that turns
it on too, and by a script's calls, TOUCH's too, while its caller has it
on (a script's calls mark them otherwise); the library CLIENT SETINFO names (lib-name, lib-ver), its
errors, and RESET, which keeps it; KILL's errors; KILL of another
client by id, address, local address, type and user, of the client
itself (SKIPME no, the old form of its own address), of a client that
waits (what it waited for stays), of a client in MULTI, in a
transaction (of another client, and of the client itself, whose
transaction runs to its end) and of all; the statistics of INFO.

The checks under load: 100 clients connected at once are all listed and
answer; half of them killed by id, the other half still answer and
are listed alone; clients that connect and close while others are
killed by address, none killed but those named.

    python3 tests/client_test.py --bendkv 6380 --redis 6390
"""
import argparse
import re
import socket
import sys
import threading
import time

from blocking_test import Client, enc, info_lines

MASKED = ("qbuf-free", "rbs", "rbp", "obl", "tot-mem", "multi-mem")


class Named(Client):
    """A client that knows its own id, address and fd (CLIENT INFO)."""

    def __init__(self, port, tag, db="9"):
        super().__init__(port, db)
        self.tag = tag
        info = self.cmd("CLIENT", "INFO")
        self.id = re.search(r"\bid=(\d+)", info).group(1)
        self.addr = re.search(r"\baddr=(\S+)", info).group(1)
        self.laddr = re.search(r"\bladdr=(\S+)", info).group(1)
        self.fd = re.search(r"\bfd=(\d+)", info).group(1)


def norm_line(line, clients, me=None, ids=()):
    """A line with what differs between servers by nature put aside. The
    line of me, the client that asks, has its qbuf and argv-mem counted
    without the ids its command carries, whose lengths differ."""
    own = me is not None and re.search(r"\bid=(\d+)", line).group(1) == me.id
    out = []
    for f in line.split(" "):
        k, _, v = f.partition("=")
        if own and k == "qbuf":
            v = str(int(v) - sum(len(i) + len(str(len(i))) for i in ids))
        elif own and k == "argv-mem":
            v = str(int(v) - sum(len(i) for i in ids))
        elif k == "id":
            v = next((c.tag for c in clients if c.id == v), "?")
        elif k == "addr":
            v = next((c.tag for c in clients if c.addr == v), "?")
        elif k == "laddr":
            v = "L"
        elif k == "fd":
            v = next((c.tag for c in clients if c.fd == v), "F")
        elif k in ("age", "idle"):
            v = "<2" if int(v) < 2 else "2+"
        elif k in MASKED:
            v = "X"
        out.append(k + "=" + v)
    return " ".join(out)


def norm(reply, clients, me=None, ids=()):
    if not isinstance(reply, str) or "id=" not in reply:
        return reply
    return [norm_line(l, clients, me, ids) for l in reply.split("\n") if l]


def mine(reply, clients):
    """The lines of a CLIENT LIST of these clients alone, in the order of
    their tags (other connections, and Redis's order, put aside)."""
    if not isinstance(reply, str):
        return reply
    ids = {c.id: c.tag for c in clients}
    lines = [l for l in reply.split("\n") if l and re.search(r"\bid=(\d+)", l).group(1) in ids]
    return sorted(norm_line(l, clients) for l in lines)


def closed(c, timeout=2.0):
    """Whether the server closed c's connection (a read finds its end)."""
    try:
        x = c.read(timeout)
        return "OPEN %r" % (x,)
    except (EOFError, ConnectionResetError, OSError):
        return "CLOSED"


def stats(r, *names):
    lines = r.cmd("INFO", "commandstats").splitlines() + r.cmd("INFO", "errorstats").splitlines()
    out = []
    for l in lines:
        for n in names:
            if l.startswith(n + ":"):
                out.append(",".join(p for p in l.split(",") if not p.startswith(("usec=", "usec_per_call="))))
    return sorted(out)


def scenarios(port, log):
    r = Named(port, "r")
    r.cmd("FLUSHALL")
    r.cmd("CONFIG", "RESETSTAT")
    # 1. a client's own line, by LIST, by LIST ID and by INFO
    a = Named(port, "a")
    cs = [r, a]
    log("1 info", norm(a.cmd("CLIENT", "INFO"), cs))
    log("1 list id", norm(a.cmd("CLIENT", "LIST", "ID", a.id), cs, a, [a.id]))
    log("1 list", mine(a.cmd("CLIENT", "LIST"), cs))
    a.raw(b"PING\r\n")
    log("1 inline", a.read(), norm(a.cmd("client", "info"), cs))
    a.raw(enc(["PING"]) + enc(["CLIENT", "INFO"]))
    log("1 pipelined", a.read(), norm(a.read(), cs))
    # 2. LIST of ids and of types, and their errors
    b = Named(port, "b")
    cs.append(b)
    log("2 ids", norm(a.cmd("CLIENT", "LIST", "ID", b.id, a.id, b.id, "-5", "0", "123456789012345678"), cs, a,
                      [b.id, a.id, b.id]))
    log("2 bad id", a.cmd("CLIENT", "LIST", "ID", b.id, "abc"), a.cmd("CLIENT", "LIST", "ID", "99999999999999999999"),
        a.cmd("CLIENT", "LIST", "ID", "+1"), a.cmd("CLIENT", "LIST", "ID", "01"))
    log("2 types", mine(a.cmd("CLIENT", "LIST", "TYPE", "normal"), cs), mine(a.cmd("CLIENT", "LIST", "TYPE", "NORMAL"), cs),
        a.cmd("CLIENT", "LIST", "TYPE", "pubsub"), a.cmd("CLIENT", "LIST", "TYPE", "replica"),
        a.cmd("CLIENT", "LIST", "TYPE", "slave"), a.cmd("CLIENT", "LIST", "TYPE", "master"),
        a.cmd("CLIENT", "LIST", "TYPE", "junk"), a.cmd("CLIENT", "LIST", "TYPE"), a.cmd("CLIENT", "LIST", "ID"),
        a.cmd("CLIENT", "LIST", "TYPE", "normal", "x"), a.cmd("CLIENT", "LIST", "junk"),
        a.cmd("CLIENT", "LIST", "junk", "x"), a.cmd("CLIENT", "INFO", "x"))
    # 3. names, as another client sees them
    log("3 setname", a.cmd("CLIENT", "SETNAME", "alpha"), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs),
        a.cmd("CLIENT", "SETNAME", "bad name"), a.cmd("CLIENT", "SETNAME", ""), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs))
    log("3 hello", a.cmd("HELLO", "2", "SETNAME", "beta")[:2], norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs),
        a.cmd("RESET"), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs))
    # 4. databases and last commands, as another client sees them
    log("4 select", a.cmd("SELECT", "3"), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs),
        a.cmd("SELECT", "9"), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs))
    log("4 get", a.cmd("SET", "k", "v"), a.cmd("GET", "k"), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs))
    log("4 unknown", a.cmd("NOSUCH", "x"), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs))
    log("4 arity", a.cmd("GET"), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs))
    log("4 sub", a.cmd("CLIENT", "GETNAME"), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs),
        a.cmd("CLIENT", "NOSUCH"), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs))
    a.send("GET", "k")
    a.send("INCR", "n")
    a.send("LPUSH", "l", "x")
    log("4 pipelined", a.read(), a.read(), a.read(), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs))
    a.send("SET", "k", "v")
    a.send("SET", "k", "w")
    log("4 same", a.read(), a.read(), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs))
    # idle: the time since the client's last command, age since it came
    e = Named(port, "e")
    cs.append(e)
    e.cmd("GET", "k")
    time.sleep(2.1)
    log("4 idle", norm(b.cmd("CLIENT", "LIST", "ID", e.id), cs), e.cmd("PING"), norm(b.cmd("CLIENT", "LIST", "ID", e.id), cs))
    e.close()
    # 5. flags
    a.send("SUBSCRIBE", "c1", "c2")
    log("5 sub", a.read(), a.read(), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs),
        a.cmd("PSUBSCRIBE", "p*"), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs),
        mine(b.cmd("CLIENT", "LIST", "TYPE", "pubsub"), cs), mine(b.cmd("CLIENT", "LIST", "TYPE", "normal"), cs))
    # UNSUBSCRIBE of all goes in the order of Redis's hash table: the
    # names compared sorted, the counts in order
    a.send("UNSUBSCRIBE")
    u = [a.read(), a.read()]
    a.send("PUNSUBSCRIBE")
    log("5 unsub", sorted(x[1] for x in u), [x[2] for x in u], a.read(), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs))
    log("5 ssub", a.cmd("SSUBSCRIBE", "s1"), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs), a.cmd("SUNSUBSCRIBE"))
    log("5 multi", a.cmd("MULTI"), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs), a.cmd("SET", "k", "1"), a.cmd("GET", "k"),
        norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs), a.cmd("DISCARD"), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs))
    log("5 dirty", a.cmd("WATCH", "k"), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs), b.cmd("SET", "k", "2"),
        norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs), a.cmd("MULTI"), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs),
        a.cmd("EXEC"), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs))
    log("5 exec", a.cmd("MULTI"), a.cmd("SET", "k", "1"), a.cmd("CLIENT", "INFO"), a.cmd("CLIENT", "LIST", "ID", b.id),
        [norm(x, cs) for x in a.cmd("EXEC")], norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs))
    a.send("BLPOP", "nolist", "0")
    time.sleep(0.2)
    log("5 waits", norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs), b.cmd("CLIENT", "UNBLOCK", a.id), a.read(),
        norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs))
    # a client that waits shows its blocking command (its arguments as
    # argv-mem), and the last of the rest of its batch once served; the
    # rest waits in BendKV as commands, where Redis's query buffer holds
    # its bytes (qbuf), which is not compared
    a.raw(enc(["BLPOP", "nolist", "0"]) + enc(["GET", "k"]))
    time.sleep(0.2)
    log("5 waits pipelined", [re.sub(r"qbuf=\d+", "qbuf=Q", x) for x in norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs)],
        b.cmd("RPUSH", "nolist", "x"), a.read(), a.read(), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs))
    log("5 no-evict", a.cmd("CLIENT", "NO-EVICT", "on"), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs),
        a.cmd("CLIENT", "NO-EVICT", "maybe"), a.cmd("RESET"), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs),
        a.cmd("CLIENT", "NO-EVICT", "OFF"), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs), a.cmd("SELECT", "9"))
    log("5 no-touch", a.cmd("CLIENT", "NO-TOUCH", "on"), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs),
        a.cmd("CLIENT", "NO-TOUCH", "maybe"), a.cmd("CLIENT", "NO-TOUCH"), a.cmd("CLIENT", "NO-TOUCH", "on", "x"),
        a.cmd("CLIENT", "NO-EVICT", "on"), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs),
        a.cmd("RESET"), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs), a.cmd("CLIENT", "NO-TOUCH", "ON"),
        a.cmd("CLIENT", "NO-TOUCH", "Off"), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs), a.cmd("SELECT", "9"))
    # a key no other test uses: a key deleted and made again finds its word of
    # uses as the old key left it in BendKV (README, Memory), so that under
    # an LFU policy its counter would go on from another test's key
    log("5 no-touch freq", r.cmd("CONFIG", "SET", "maxmemory-policy", "allkeys-lfu"), r.cmd("CONFIG", "SET", "lfu-log-factor", "0"),
        a.cmd("SET", "ntf", "v"), r.cmd("OBJECT", "FREQ", "ntf"), a.cmd("CLIENT", "NO-TOUCH", "on"),
        [a.cmd("GET", "ntf") for _ in range(5)], a.cmd("STRLEN", "ntf"), r.cmd("OBJECT", "FREQ", "ntf"),
        a.cmd("TOUCH", "ntf"), r.cmd("OBJECT", "FREQ", "ntf"), b.cmd("GET", "ntf"), r.cmd("OBJECT", "FREQ", "ntf"),
        a.cmd("MULTI"), a.cmd("GET", "ntf"), a.cmd("TOUCH", "ntf"), a.cmd("EXEC"), r.cmd("OBJECT", "FREQ", "ntf"),
        a.cmd("CLIENT", "NO-TOUCH", "off"), a.cmd("GET", "ntf"), r.cmd("OBJECT", "FREQ", "ntf"))
    a.raw(enc(["CLIENT", "NO-TOUCH", "on"]) + enc(["GET", "ntf"]) + enc(["GET", "ntf"]))
    log("5 no-touch pipelined", a.read(), a.read(), a.read(), r.cmd("OBJECT", "FREQ", "ntf"))
    a.raw(enc(["CLIENT", "NO-TOUCH", "off"]) + enc(["GET", "ntf"]))
    log("5 no-touch off pipelined", a.read(), a.read(), r.cmd("OBJECT", "FREQ", "ntf"))
    get1, touch1 = "return redis.call('GET', KEYS[1])", "return redis.call('TOUCH', KEYS[1])"
    log("5 no-touch scripts", a.cmd("EVAL", get1, "1", "ntf"), r.cmd("OBJECT", "FREQ", "ntf"),
        a.cmd("EVAL", touch1, "1", "ntf"), r.cmd("OBJECT", "FREQ", "ntf"), a.cmd("CLIENT", "NO-TOUCH", "on"),
        a.cmd("EVAL", get1, "1", "ntf"), a.cmd("EVAL_RO", get1, "1", "ntf"), r.cmd("OBJECT", "FREQ", "ntf"),
        a.cmd("EVAL", touch1, "1", "ntf"), r.cmd("OBJECT", "FREQ", "ntf"),
        a.cmd("MULTI"), a.cmd("EVAL", get1, "1", "ntf"), a.cmd("EXEC"), r.cmd("OBJECT", "FREQ", "ntf"),
        b.cmd("EVAL", get1, "1", "ntf"), r.cmd("OBJECT", "FREQ", "ntf"), a.cmd("CLIENT", "NO-TOUCH", "off"),
        a.cmd("EVAL", get1, "1", "ntf"), r.cmd("OBJECT", "FREQ", "ntf"),
        r.cmd("CONFIG", "SET", "maxmemory-policy", "noeviction"), r.cmd("CONFIG", "SET", "lfu-log-factor", "10"))
    log("5 no-touch idle", a.cmd("SET", "g", "v"), a.cmd("CLIENT", "NO-TOUCH", "on"))
    time.sleep(2.1)
    log("5 no-touch idle after", a.cmd("GET", "g"), int(r.cmd("OBJECT", "IDLETIME", "g")[1:]) >= 2, a.cmd("TOUCH", "g"),
        int(r.cmd("OBJECT", "IDLETIME", "g")[1:]) < 2, a.cmd("CLIENT", "NO-TOUCH", "off"))
    log("5 setinfo", a.cmd("CLIENT", "SETINFO", "lib-name", "redis-py"), a.cmd("CLIENT", "SETINFO", "LIB-VER", "5.0.1"),
        norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs), norm(a.cmd("CLIENT", "INFO"), cs),
        a.cmd("CLIENT", "SETINFO", "lib-name", "bad name"), a.cmd("CLIENT", "SETINFO", "Lib-Ver", "x\ny"),
        a.cmd("CLIENT", "SETINFO", "lib-x", "v"), a.cmd("CLIENT", "SETINFO", "bad\nopt", "v"),
        a.cmd("CLIENT", "SETINFO", "lib-name"), a.cmd("CLIENT", "SETINFO", "lib-name", "a", "b"),
        a.cmd("RESET"), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs),
        a.cmd("CLIENT", "SETINFO", "lib-ver", ""), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs),
        a.cmd("CLIENT", "SETINFO", "lib-name", "x\x00 y"), norm(b.cmd("CLIENT", "LIST", "ID", a.id), cs),
        a.cmd("SELECT", "9"))
    # 6. KILL's errors
    log("6 errors", a.cmd("CLIENT", "KILL"), a.cmd("CLIENT", "KILL", "id", "10", "wrong_arg"),
        a.cmd("CLIENT", "KILL", "id", "str"), a.cmd("CLIENT", "KILL", "id", "-1"), a.cmd("CLIENT", "KILL", "id", "0"),
        a.cmd("CLIENT", "KILL", "type", "wrong_type"), a.cmd("CLIENT", "KILL", "user", "wrong_user"),
        a.cmd("CLIENT", "KILL", "skipme", "yes_or_no"), a.cmd("CLIENT", "KILL", "1.2.3.4:5"),
        a.cmd("CLIENT", "KILL", "id"), a.cmd("CLIENT", "KILL", "ID", "99999999999999999999"),
        a.cmd("CLIENT", "KILL", "ID", "123456789012345678"), a.cmd("CLIENT", "KILL", "user", "default", "id", "x"),
        a.cmd("CLIENT", "KILL", "id", "x", "type", "junk"), a.cmd("CLIENT", "KILL", "ADDR", "1.2.3.4:5", "LADDR", "x:1"),
        a.cmd("CLIENT", "KILL", "MAXAGE", "10"), a.cmd("CLIENT", "KILL", "ID", "1", "ID"))
    # 7. KILL of another client, by id, address, local address, type, user
    c = Named(port, "c")
    cs.append(c)
    log("7 id", a.cmd("CLIENT", "KILL", "ID", c.id), closed(c), a.cmd("CLIENT", "LIST", "ID", c.id))
    c = Named(port, "c2")
    cs.append(c)
    log("7 addr", a.cmd("CLIENT", "KILL", "ADDR", c.addr), closed(c))
    c = Named(port, "c3")
    cs.append(c)
    log("7 old form", a.cmd("CLIENT", "KILL", c.addr), closed(c), a.cmd("CLIENT", "KILL", c.addr))
    c = Named(port, "c4")
    cs.append(c)
    log("7 laddr", a.cmd("CLIENT", "KILL", "LADDR", c.laddr, "ID", c.id), closed(c),
        a.cmd("CLIENT", "KILL", "LADDR", "127.0.0.1:1", "ID", b.id))
    c = Named(port, "c5")
    cs.append(c)
    c.cmd("SUBSCRIBE", "x")
    log("7 type", a.cmd("CLIENT", "KILL", "TYPE", "normal", "ID", c.id), a.cmd("CLIENT", "KILL", "TYPE", "pubsub"), closed(c),
        r.cmd("PUBSUB", "NUMSUB", "x"))
    c = Named(port, "c6")
    cs.append(c)
    log("7 user", a.cmd("CLIENT", "KILL", "USER", "default", "ID", c.id), closed(c))
    # 8. the client itself
    log("8 skipme", a.cmd("CLIENT", "KILL", "ID", a.id), a.cmd("CLIENT", "KILL", "ID", a.id, "SKIPME", "yes"), a.cmd("PING"))
    d = Named(port, "d")
    cs.append(d)
    d.send("CLIENT", "KILL", "ID", d.id, "SKIPME", "no")
    d.send("PING")
    log("8 self", d.read(), closed(d))
    d = Named(port, "d2")
    cs.append(d)
    log("8 self old form", d.cmd("CLIENT", "KILL", d.addr), closed(d))
    # 9. a client that waits, killed: what it waited for stays
    w = Named(port, "w")
    cs.append(w)
    w.send("BLPOP", "wl", "0")
    time.sleep(0.2)
    log("9 waits", r.cmd("CLIENT", "KILL", "ID", w.id), closed(w), r.cmd("LPUSH", "wl", "x"), r.cmd("LLEN", "wl"),
        info_lines(r, "clients", "blocked_clients:"))
    # 10. a client in MULTI with a watched key, killed
    m = Named(port, "m")
    cs.append(m)
    log("10 multi", m.cmd("WATCH", "k"), m.cmd("MULTI"), m.cmd("SET", "k", "9"), r.cmd("CLIENT", "KILL", "ID", m.id),
        closed(m), r.cmd("GET", "k"))
    # KILL in a transaction: of another client, and of the client itself,
    # whose transaction runs to its end before its connection closes
    m = Named(port, "m2")
    k = Named(port, "k")
    cs += [m, k]
    log("10 exec kill", m.cmd("MULTI"), m.cmd("CLIENT", "KILL", "ID", k.id), m.cmd("EXEC"), closed(k))
    log("10 exec self", m.cmd("MULTI"), m.cmd("CLIENT", "KILL", "ID", m.id, "SKIPME", "no"), m.cmd("SET", "k", "10"),
        m.cmd("EXEC"), closed(m), r.cmd("GET", "k"))
    # 11. statistics
    log("11 stats", stats(r, "cmdstat_client|list", "cmdstat_client|info", "cmdstat_client|kill",
                          "cmdstat_client|no-evict", "cmdstat_client|no-touch", "cmdstat_client|setinfo",
                          "errorstat_ERR"))
    # 12. all of them, and the client itself (SKIPME no)
    x = Named(port, "x")
    y = Named(port, "y")
    cs += [x, y]
    n = int(r.cmd("INFO", "clients").split("connected_clients:")[1].split("\r\n")[0])
    log("12 skipme yes", r.cmd("CLIENT", "KILL", "SKIPME", "yes") == ":%d" % (n - 1), closed(a), closed(b), closed(x), closed(y))
    time.sleep(0.2)
    x = Named(port, "x2")
    y = Named(port, "y2")
    cs += [x, y]
    n = int(r.cmd("INFO", "clients").split("connected_clients:")[1].split("\r\n")[0])
    log("12 skipme no", n, r.cmd("CLIENT", "KILL", "SKIPME", "no") == ":%d" % n, closed(r), closed(x), closed(y))
    time.sleep(0.2)
    z = Named(port, "z")
    log("12 after", z.cmd("PING"), z.cmd("INFO", "clients").split("\r\n")[1])
    z.cmd("FLUSHALL")


def info_clients(c):
    return int(c.cmd("INFO", "clients").split("connected_clients:")[1].split("\r\n")[0])


def load(port):
    bad = []
    r = Named(port, "r")
    # 100 clients at once: all listed, all answer; half killed by id
    cs = [Named(port, "c%d" % i) for i in range(100)]
    lines = r.cmd("CLIENT", "LIST")
    listed = {re.search(r"\bid=(\d+)", l).group(1) for l in lines.split("\n") if l}
    if not all(c.id in listed for c in cs):
        bad.append("not every client listed")
    for c in cs[::2]:
        if r.cmd("CLIENT", "KILL", "ID", c.id) != ":1":
            bad.append("a kill by id missed")
    for i, c in enumerate(cs):
        if i % 2 == 0:
            if closed(c) != "CLOSED":
                bad.append("a killed client still open")
                break
        elif c.cmd("PING") != "+PONG":
            bad.append("a client not killed does not answer")
            break
    listed = {re.search(r"\bid=(\d+)", l).group(1) for l in r.cmd("CLIENT", "LIST").split("\n") if l}
    if any(c.id in listed for c in cs[::2]) or not all(c.id in listed for c in cs[1::2]):
        bad.append("the list after the kills is wrong")
    for c in cs[1::2]:
        c.close()
    # clients that connect and close while others are killed by address:
    # none killed but those named (no fd taken by another connection)
    stop = threading.Event()
    errs = []

    def churn():
        while not stop.is_set():
            try:
                c = Client(port, db=None)
                if c.cmd("PING") != "+PONG":
                    errs.append("a churning client got no PONG")
                c.close()
            except Exception as e:
                errs.append("churn: %r" % (e,))

    ts = [threading.Thread(target=churn) for _ in range(4)]
    for t in ts:
        t.start()
    keep = [Named(port, "k%d" % i) for i in range(20)]
    for i in range(200):
        v = Named(port, "v%d" % i)
        if r.cmd("CLIENT", "KILL", "ADDR", v.addr) != ":1":
            bad.append("a kill by address missed")
            break
        if closed(v) != "CLOSED":
            bad.append("a client killed by address still open")
            break
    stop.set()
    for t in ts:
        t.join()
    bad += errs[:3]
    for k in keep:
        if k.cmd("PING") != "+PONG":
            bad.append("a client not named was killed")
            break
    for k in keep:
        k.close()
    time.sleep(0.3)
    if info_clients(r) != 1:
        bad.append("connected_clients is %d after the others left, not 1" % info_clients(r))
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
    print("OK: %d lines of CLIENT scenarios as Redis answers them, and 2 checks under load" % len(outs[1]))


if __name__ == "__main__":
    main()
