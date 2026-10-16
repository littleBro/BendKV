#!/usr/bin/env python3
"""Blocking commands against Redis: scenarios of clients that wait, each
run on BendKV and on Redis with clients of their own, the transcripts
compared line by line; then checks of BendKV alone under load.

The scenarios: a client served by a push, one that times out, CLIENT
UNBLOCK with TIMEOUT and with ERROR (and its errors), a client whose
connection closes while it waits, the fairness of a pipeline that pushes
and then waits itself, moves that serve each other (BLMOVE chains, a
circle of BRPOPLPUSH), a move to a key of the wrong kind, commands
pipelined behind a blocking one and bytes that come while it waits,
sorted sets (BZPOPMIN, BZMPOP), a list key that does not serve a client
waiting for a sorted set, the statistics of INFO (calls counted once,
failed calls, UNBLOCKED errors), a timeout with a pipeline behind it,
RENAME, MOVE and SWAPDB, CLIENT REPLY OFF, a client served then waiting
again in the rest of its batch, blocked_clients and
clients_in_timeout_table, a SELECT in the batch of a blocking command, a
QUIT behind one, a pipeline that pushes to a key a client waits on and
then pops (the client is served between them), and pipelines that write
other keys while 100 clients wait (the fast way, server.bend's Heeded
keys; one of GETs, SETs and INCRs alone), then a key among theirs.

The checks under load: 300 clients waiting on 300 keys, each served; 100
timeouts at once; 100 clients that close their connections while they
wait (none left waiting, the elements pushed after them kept); and 50
consumers moving 1000 items with BRPOPLPUSH while some of them leave,
every item moved once.

    python3 tests/blocking_test.py --bendkv 6380 --redis 6390
"""
import argparse
import re
import socket
import sys
import threading
import time


def enc(args):
    out = [b"*%d\r\n" % len(args)]
    for a in args:
        a = a.encode() if isinstance(a, str) else a
        out.append(b"$%d\r\n%s\r\n" % (len(a), a))
    return b"".join(out)


class Client:
    """A connection whose reads time out: a reply that does not come in
    time reads as TIMEOUT."""

    def __init__(self, port, db="9"):
        self.port = port
        self.sock = socket.create_connection(("127.0.0.1", port))
        self.buf = b""
        if db is not None:
            self.cmd("SELECT", db)

    def send(self, *args):
        self.sock.sendall(enc(args))

    def raw(self, data):
        self.sock.sendall(data)

    def _fill(self, timeout):
        self.sock.settimeout(timeout)
        try:
            data = self.sock.recv(1 << 16)
        except socket.timeout:
            return False
        if not data:
            raise EOFError("connection closed")
        self.buf += data
        return True

    def _line(self, timeout):
        while b"\r\n" not in self.buf:
            if not self._fill(timeout):
                return None
        line, self.buf = self.buf.split(b"\r\n", 1)
        return line

    def read(self, timeout=3.0):
        line = self._line(timeout)
        if line is None:
            return "TIMEOUT"
        kind, rest = line[:1], line[1:]
        if kind in (b"+", b"-", b":"):
            return (kind + rest).decode()
        if kind == b"$":
            n = int(rest)
            if n < 0:
                return None
            while len(self.buf) < n + 2:
                if not self._fill(timeout):
                    return "TIMEOUT"
            data, self.buf = self.buf[:n], self.buf[n + 2:]
            return data.decode(errors="replace")
        if kind == b"*":
            n = int(rest)
            return "NULLA" if n < 0 else [self.read(timeout) for _ in range(n)]
        return "?" + line.decode()

    def cmd(self, *args):
        self.send(*args)
        return self.read()

    def close(self):
        self.sock.close()


def info_lines(r, section, prefixes):
    return [l for l in r.cmd("INFO", section).splitlines() if l.startswith(prefixes)]


def blocked(r):
    return int(info_lines(r, "clients", "blocked_clients:")[0].split(":")[1])


def wait_blocked(r, n, tries=300):
    for _ in range(tries):
        if blocked(r) == n:
            return n
        time.sleep(0.01)
    return blocked(r)


def scenarios(port, log):
    r = Client(port)
    r.cmd("FLUSHALL")
    r.cmd("CONFIG", "RESETSTAT")
    a, b = Client(port), Client(port)
    # 1. a client served by a push
    a.send("BLPOP", "k", "0")
    log("1 blocked", wait_blocked(r, 1))
    log("1 push", r.cmd("RPUSH", "k", "x", "y"))
    log("1 a", a.read())
    log("1 left", r.cmd("LRANGE", "k", "0", "-1"), wait_blocked(r, 0))
    # 2. a timeout
    t0 = time.time()
    a.send("BLPOP", "nokey", "0.3")
    log("2 timeout", a.read(), 0.25 < time.time() - t0 < 1.5)
    # 3. CLIENT UNBLOCK
    aid = a.cmd("CLIENT", "ID")[1:]
    a.send("BLMPOP", "0", "1", "l", "LEFT", "COUNT", "1")
    log("3 blocked", wait_blocked(r, 1))
    log("3 unblock", r.cmd("CLIENT", "UNBLOCK", aid))
    log("3 a", a.read())
    a.send("BRPOP", "l", "0")
    wait_blocked(r, 1)
    log("3 unblock error", r.cmd("CLIENT", "UNBLOCK", aid, "ERROR"))
    log("3 a", a.read())
    log("3 none", r.cmd("CLIENT", "UNBLOCK", aid))
    log("3 bad reason", r.cmd("CLIENT", "UNBLOCK", aid, "WHY"))
    log("3 bad id", r.cmd("CLIENT", "UNBLOCK", "x"))
    log("3 negative id", r.cmd("CLIENT", "UNBLOCK", "-1"))
    # 4. a connection closed while it waits
    c = Client(port)
    c.send("BLPOP", "q", "0")
    log("4 blocked", wait_blocked(r, 1))
    c.close()
    log("4 gone", wait_blocked(r, 0))
    log("4 push", r.cmd("RPUSH", "q", "1"), r.cmd("LRANGE", "q", "0", "-1"))
    r.cmd("DEL", "q")
    # 5. fairness: a pipeline that pushes, then waits itself
    a.send("BLPOP", "ml", "0")
    wait_blocked(r, 1)
    b.raw(b"LPUSH ml 1\r\nBLPOP ml 0\r\n")
    log("5 a", a.read())
    log("5 b", b.read())
    log("5 still", wait_blocked(r, 1))
    log("5 push", r.cmd("LPUSH", "ml", "2"))
    log("5 b", b.read(), wait_blocked(r, 0))
    # 6. moves that serve each other
    a.send("BLMOVE", "l1", "l2", "RIGHT", "LEFT", "0")
    wait_blocked(r, 1)
    b.send("BLMOVE", "l2", "l3", "LEFT", "RIGHT", "0")
    log("6 blocked", wait_blocked(r, 2))
    log("6 push", r.cmd("RPUSH", "l1", "foo"))
    log("6 a b", a.read(), b.read())
    log("6 lists", r.cmd("LRANGE", "l1", "0", "-1"), r.cmd("LRANGE", "l2", "0", "-1"), r.cmd("LRANGE", "l3", "0", "-1"))
    r.cmd("DEL", "l3")
    a.send("BRPOPLPUSH", "c1", "c2", "0")
    wait_blocked(r, 1)
    b.send("BRPOPLPUSH", "c2", "c1", "0")
    wait_blocked(r, 2)
    log("6 circle", r.cmd("RPUSH", "c1", "foo"), a.read(), b.read())
    log("6 circle lists", r.cmd("LRANGE", "c1", "0", "-1"), r.cmd("LRANGE", "c2", "0", "-1"))
    r.cmd("DEL", "c1")
    # 7. a move to a key of the wrong kind
    r.cmd("SET", "tgt", "nolist")
    a.send("BRPOPLPUSH", "bl", "tgt", "0")
    wait_blocked(r, 1)
    log("7 push", r.cmd("RPUSH", "bl", "a", "b", "c"))
    log("7 a", a.read(), r.cmd("LRANGE", "bl", "0", "-1"))
    r.cmd("DEL", "bl", "tgt")
    # 8. commands pipelined behind a blocking one, and bytes that come
    # while it waits
    a.raw(b"SET p1 v1\r\nBLPOP pl 0\r\nGET p1\r\nINCR n\r\n")
    log("8 first", a.read())
    log("8 blocked", wait_blocked(r, 1))
    a.raw(b"INCR n\r\nGET n\r\n")
    log("8 nothing yet", a.read(0.3))
    log("8 push", r.cmd("RPUSH", "pl", "z"))
    log("8 a", a.read(), a.read(), a.read(), a.read(), a.read())
    # 9. sorted sets
    a.send("BZPOPMIN", "z1", "z2", "0")
    wait_blocked(r, 1)
    b.send("BZMPOP", "0", "1", "z2", "MAX", "COUNT", "5")
    log("9 blocked", wait_blocked(r, 2))
    log("9 zadd", r.cmd("ZADD", "z2", "1", "a", "2", "b", "3", "c"))
    log("9 a b", a.read(), b.read(), r.cmd("ZRANGE", "z2", "0", "-1"))
    # 10. a list does not serve a client that waits for a sorted set
    a.send("BZPOPMAX", "zz", "0")
    wait_blocked(r, 1)
    log("10 push", r.cmd("RPUSH", "zz", "x"))
    log("10 still", a.read(0.3), wait_blocked(r, 1))
    r.cmd("DEL", "zz")
    log("10 zadd", r.cmd("ZADD", "zz", "5", "m"), a.read())
    # 11. statistics
    log("11 commandstats", sorted(re.sub(r"usec=\d+,usec_per_call=[0-9.]+,", "", l)
                                  for l in info_lines(r, "commandstats", ("cmdstat_b", "cmdstat_client|unblock"))))
    log("11 errorstats", info_lines(r, "errorstats", "errorstat_UNBLOCKED"))
    # 12. a timeout with a pipeline behind it
    a.raw(b"BLPOP t1 0.2\r\nPING\r\n")
    log("12 a", a.read(), a.read())
    # 13. RENAME, MOVE and SWAPDB make a key a client waits on
    a.send("BLPOP", "mv", "0")
    wait_blocked(r, 1)
    r.cmd("RPUSH", "src", "s1")
    log("13 rename", r.cmd("RENAME", "src", "mv"), a.read())
    a0 = Client(port, "0")
    a0.send("BLPOP", "dk", "0")
    wait_blocked(r, 1)
    log("13 push in 9", r.cmd("RPUSH", "dk", "x"), a0.read(0.3))
    log("13 move", r.cmd("MOVE", "dk", "0"), a0.read())
    a0.send("BLPOP", "sk", "0")
    wait_blocked(r, 1)
    r.cmd("RPUSH", "sk", "v")
    log("13 swapdb", a0.read(0.2), r.cmd("SWAPDB", "0", "9"), a0.read(), r.cmd("SWAPDB", "0", "9"))
    a0.close()
    # 14. CLIENT REPLY OFF: no reply, but the pop is made
    a.raw(b"CLIENT REPLY OFF\r\nBLPOP ro 0\r\nCLIENT REPLY ON\r\nPING\r\n")
    wait_blocked(r, 1)
    log("14 push", r.cmd("RPUSH", "ro", "1", "2"))
    log("14 a", a.read(), a.read(), r.cmd("LRANGE", "ro", "0", "-1"))
    r.cmd("DEL", "ro")
    # 15. served, then waiting again in the rest of the batch
    a.raw(b"BLPOP k1 0\r\nBLPOP k2 0\r\nPING\r\n")
    wait_blocked(r, 1)
    log("15 push", r.cmd("RPUSH", "k1", "x"), a.read(), wait_blocked(r, 1))
    log("15 push", r.cmd("RPUSH", "k2", "y"), a.read(), a.read())
    # 16. blocked_clients and clients_in_timeout_table
    a.send("BLPOP", "t16", "5")
    b.send("BLPOP", "t16", "0")
    wait_blocked(r, 2)
    log("16 info", info_lines(r, "clients", ("blocked_clients", "clients_in_timeout")))
    log("16 push", r.cmd("RPUSH", "t16", "1", "2"), a.read(), b.read())
    log("16 info", info_lines(r, "clients", ("blocked_clients", "clients_in_timeout")))
    # 17. a SELECT in the batch of a blocking command
    a.raw(b"SELECT 3\r\nBLPOP sel 0\r\n")
    log("17 select", a.read())
    wait_blocked(r, 1)
    log("17 push in 9", r.cmd("RPUSH", "sel", "no"), a.read(0.2))
    r3 = Client(port, "3")
    log("17 push in 3", r3.cmd("RPUSH", "sel", "yes"), a.read())
    r3.close()
    # 18. a QUIT behind a blocking command
    a.raw(b"SELECT 9\r\nBLPOP qk 0\r\nQUIT\r\nPING\r\n")
    log("18 select", a.read())
    wait_blocked(r, 1)
    r.cmd("RPUSH", "qk", "1")
    log("18 a", a.read(), a.read())
    try:
        x = a.read(1)
    except EOFError:
        x = "EOF"
    log("18 closed", x)
    # 19. a pipeline that pushes to a key a client waits on, then pops:
    # the client is served right after the push, the pop finds nothing
    a = Client(port)
    a.send("BLPOP", "p19", "0")
    wait_blocked(r, 1)
    r.raw(enc(["RPUSH", "p19", "x"]) + enc(["LPOP", "p19"]) + enc(["LLEN", "p19"]))
    log("19 pipeline", r.read(), r.read(), r.read(), a.read())
    # 20. pipelines that write other keys while 100 clients wait, then
    # one that writes a key among theirs in the middle
    ws = [Client(port) for _ in range(100)]
    for i, w in enumerate(ws):
        w.send("BLPOP", "w20:%d" % i, "0")
    log("20 blocked", wait_blocked(r, 100, 1000))
    other = [["SET", "o20", "1"], ["INCR", "o20"], ["MSET", "o20a", "x", "o20b", "y"], ["RPUSH", "l20", "a", "b"],
             ["LPOP", "l20"], ["SADD", "s20", "m"], ["HSET", "h20", "f", "v"], ["ZADD", "z20", "1", "m"],
             ["RENAME", "o20a", "o20c"], ["DEL", "o20b", "nokey"], ["GET", "o20"], ["MGET", "o20", "o20c"]]
    r.raw(b"".join(enc(c) for c in other))
    log("20 others", [r.read() for _ in other], wait_blocked(r, 100))
    # GETs, SETs and INCRs alone (read by their hashes, not command by
    # command), on other keys
    quick = [["SET", "q20", "1"], ["INCR", "q20"], ["GET", "q20"], ["SET", "q20b", "x"], ["GET", "w20:3"]]
    r.raw(b"".join(enc(c) for c in quick))
    log("20 quick", [r.read() for _ in quick], wait_blocked(r, 100))
    r.raw(enc(["SET", "o20", "2"]) + enc(["RPUSH", "w20:7", "v"]) + enc(["LLEN", "w20:7"]) + enc(["GET", "o20"]))
    log("20 one", [r.read() for _ in range(4)], ws[7].read(), wait_blocked(r, 99))
    r.raw(enc(["LMOVE", "l20", "w20:9", "LEFT", "RIGHT"]) + enc(["LLEN", "w20:9"]))
    log("20 move", r.read(), r.read(), ws[9].read(), wait_blocked(r, 98))
    for w in ws:
        w.close()
    log("20 gone", wait_blocked(r, 0, 1000))
    a.close()
    b.close()
    r.cmd("FLUSHALL")
    r.close()


def load(port):
    """Checks of one server under load; a list of failures."""
    bad = []
    r = Client(port)
    r.cmd("FLUSHALL")
    cs = [Client(port) for _ in range(300)]
    for i, c in enumerate(cs):
        c.send("BLPOP", "s:%d" % i, "0")
    if wait_blocked(r, 300, 1000) != 300:
        bad.append("300 clients do not wait")
    r.raw(b"".join(enc(["RPUSH", "s:%d" % i, "v"]) for i in range(300)))
    for _ in range(300):
        r.read()
    if not all(c.read(10) == ["s:%d" % i, "v"] for i, c in enumerate(cs)):
        bad.append("a client of 300 not served")
    for c in cs[:100]:
        c.send("BLPOP", "nokey", "0.1")
    t0 = time.time()
    if not all(c.read(10) == "NULLA" for c in cs[:100]) or time.time() - t0 > 3:
        bad.append("100 timeouts at once")
    for c in cs[100:200]:
        c.send("BLPOP", "dk", "0")
    wait_blocked(r, 100, 1000)
    for c in cs[100:200]:
        c.close()
    if wait_blocked(r, 0, 1000) != 0:
        bad.append("clients gone still wait")
    r.cmd("RPUSH", "dk", "a", "b")
    if r.cmd("LRANGE", "dk", "0", "-1") != ["a", "b"]:
        bad.append("a push after the clients left lost elements")
    for c in cs[:100] + cs[200:]:
        c.close()
    # 50 consumers move 1000 items while some leave
    cons = [Client(port) for _ in range(50)]
    moved = []
    lock = threading.Lock()
    stop = []

    def consumer(c, leave):
        n = 0
        try:
            while not stop:
                c.send("BRPOPLPUSH", "q", "done", "0.2")
                v = c.read(10)
                if isinstance(v, str) and v not in ("NULLA", "TIMEOUT"):
                    with lock:
                        moved.append(v)
                    n += 1
                    if leave and n >= leave:
                        c.close()
                        return
        except (EOFError, OSError):
            pass

    ths = [threading.Thread(target=consumer, args=(c, 5 if i % 10 == 0 else 0)) for i, c in enumerate(cons)]
    for t in ths:
        t.start()
    p = Client(port)
    for i in range(1000):
        p.cmd("LPUSH", "q", "item%d" % i)
    time.sleep(1.0)
    stop.append(True)
    for t in ths:
        t.join()
    done = int(r.cmd("LLEN", "done")[1:])
    left = int(r.cmd("LLEN", "q")[1:])
    if done + left != 1000 or len(moved) > done or len(set(moved)) != len(moved):
        bad.append("1000 items: %d moved, %d left, %d answered" % (done, left, len(moved)))
    if wait_blocked(r, 0, 1000) != 0:
        bad.append("consumers still wait")
    for c in cons:
        c.close()
    p.close()
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
    print("OK: %d lines of blocking scenarios as Redis answers them, and 4 checks under load" % len(outs[1]))


if __name__ == "__main__":
    main()
