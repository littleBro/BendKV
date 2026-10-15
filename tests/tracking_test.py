#!/usr/bin/env python3
"""CLIENT TRACKING against Redis: the same scenarios on BendKV and on
Redis, each with clients of its own, the bytes every client received
after each step compared (client ids named by their clients; CLIENT
LIST's lines cut to their ids, flags and redirects).

- CLIENT TRACKING's options and errors in Redis's order, CLIENT CACHING,
  GETREDIR and TRACKINGINFO, in RESP2 and RESP3.
- Invalidations of the keys a client read (RESP3, no redirect): by the
  writes of another client, of its own (after its reply, after EXEC's),
  NOLOOP; a key of another database (the table has none); the keys of
  the commands that only read, by their key specs; writes that change
  nothing (no invalidation).
- Redirects: to a RESP2 client subscribed to __redis__:invalidate (a
  message), to a RESP3 client (a push), to a RESP2 client without a
  subscription (nothing); a redirect's own write (the push before its
  reply); a redirect gone (tracking-redir-broken, the R flag).
- OPTIN and OPTOUT with CLIENT CACHING, in MULTI, after a CLIENT command.
- BCAST: prefixes, NOLOOP, the empty prefix, keys sorted, one push for
  the writes of a batch.
- FLUSHDB and FLUSHALL (a null, in each client's protocol; after EXEC's
  reply for the client that flushes), SWAPDB (nothing), MOVE, COPY,
  RENAME.
- INFO's counts; tracking off, RESET, a client gone (its ids stay in the
  table); CLIENT REPLY OFF (pushes still go out).
- Keys expired by the server's sweep, keys evicted past maxmemory, and
  the table's limit (tracking-table-max-keys: which keys go is random,
  so their number).
- A client served by BLMOVE: its destination's invalidation after its
  reply.

    python3 tests/tracking_test.py --bendkv 6380 --redis 6390
"""
import argparse
import re
import select
import socket
import sys
import time


def enc(args):
    out = b"*%d\r\n" % len(args)
    for a in args:
        a = a.encode() if isinstance(a, str) else a
        out += b"$%d\r\n%s\r\n" % (len(a), a)
    return out


class Conn:
    """A connection whose bytes are read as they come, without parsing"""

    def __init__(self, port, name, names):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=10)
        self.name = name
        self.sock.sendall(enc(["CLIENT", "ID"]))
        self.id = int(self.wait_line()[1:])
        names[self.id] = name

    def wait_line(self):
        buf = b""
        while not buf.endswith(b"\r\n"):
            buf += self.sock.recv(1)
        return buf[:-2]

    def send(self, *args):
        self.sock.sendall(enc(args))

    def sendmany(self, cmds):
        self.sock.sendall(b"".join(enc(c) for c in cmds))

    def drain(self):
        self.sock.setblocking(False)
        out = b""
        try:
            while True:
                d = self.sock.recv(1 << 16)
                if not d:
                    out += b"<closed>"
                    break
                out += d
        except BlockingIOError:
            pass
        self.sock.setblocking(True)
        return out

    def close(self):
        self.sock.close()


class Run:
    """a scenario's transcript: after each step, what each client got"""

    def __init__(self, port):
        self.port = port
        self.names = {}
        self.conns = []
        self.out = []
        self.step = 0

    def conn(self, name, resp=2):
        c = Conn(self.port, name, self.names)
        self.conns.append(c)
        if resp == 3:
            c.send("HELLO", "3")
            self.settle()
            c.drain()
        return c

    def norm(self, data, ids):
        data = data.decode(errors="replace")
        # CLIENT LIST's lines: id, flags and redirect
        if "flags=" in data:
            data = re.sub(r"^\$\d+\r\n", "", data)
            data = re.sub(r"id=(\d+) .*? flags=(\S+) .*? redir=(-?\d+) resp=\d",
                          lambda m: "id=%s flags=%s redir=%s" % (self.named(m.group(1)), m.group(2), self.named(m.group(3))), data)
        # an id as an integer reply (GETREDIR, TRACKINGINFO's redirect,
        # tracking-redir-broken's)
        if ids or "tracking-redir-broken" in data:
            data = re.sub(r":(\d+)\r\n", lambda m: ":%s\r\n" % self.named(m.group(1)), data)
        return data

    def named(self, s):
        n = int(s)
        return "<%s>" % self.names[n] if n in self.names and n > 0 else s

    def settle(self, secs=0.05):
        time.sleep(secs)

    # a step's bytes: what each client got within secs, and with sender
    # (a client whose command has a reply) its reply's first bytes too,
    # however late they come (up to 2 s)
    def take(self, label, secs=0.05, ids=False, sender=None):
        self.settle(secs)
        if sender is not None:
            select.select([sender.sock], [], [], 2)
        self.step += 1
        for c in self.conns:
            got = c.drain()
            if got:
                self.out.append("%d %s %s: %r" % (self.step, label, c.name, self.norm(got, ids)))

    def do(self, c, *args, secs=0.05, reply=False):
        c.send(*args)
        words = [self.named(a) if re.fullmatch(r"\d+", str(a)) and int(a) in self.names else str(a) for a in args]
        ids = len(args) > 1 and str(args[0]).upper() == "CLIENT" and str(args[1]).upper() in ("GETREDIR", "TRACKINGINFO", "ID")
        self.take(c.name + " " + " ".join(words), secs, ids, c if reply else None)

    def close(self):
        for c in self.conns:
            c.close()


def tid(c):
    return str(c.id)


def errors(r):
    for proto in (2, 3):
        c = r.conn("c%d" % proto, proto)
        t = r.conn("t%d" % proto)
        for args in (["CLIENT", "TRACKING"], ["CLIENT", "TRACKING", "foo"], ["CLIENT", "TRACKING", "on", "foo"],
                     ["CLIENT", "TRACKING", "on", "REDIRECT"], ["CLIENT", "TRACKING", "on", "REDIRECT", "abc"],
                     ["CLIENT", "TRACKING", "on", "REDIRECT", "99999999"], ["CLIENT", "TRACKING", "on", "REDIRECT", "0"],
                     ["CLIENT", "TRACKING", "on", "REDIRECT", "-1"],
                     ["CLIENT", "TRACKING", "on", "REDIRECT", tid(t), "REDIRECT", tid(t)],
                     ["CLIENT", "TRACKING", "on", "foo", "REDIRECT", "abc"],
                     ["CLIENT", "TRACKING", "on", "REDIRECT", "abc", "foo"],
                     ["CLIENT", "TRACKING", "on", "PREFIX", "a"], ["CLIENT", "TRACKING", "on", "PREFIX"],
                     ["CLIENT", "TRACKING", "on", "BCAST", "OPTIN"], ["CLIENT", "TRACKING", "on", "OPTIN", "OPTOUT"],
                     ["CLIENT", "TRACKING", "on", "BCAST", "PREFIX", "a", "PREFIX", "ab"],
                     ["CLIENT", "TRACKING", "on", "BCAST", "PREFIX", "ab", "PREFIX", "a"],
                     ["CLIENT", "TRACKING", "maybe", "BCAST"], ["CLIENT", "TRACKING", "off", "REDIRECT", "99999999"],
                     ["CLIENT", "TRACKING", "off", "foo"], ["CLIENT", "TRACKING", "off"],
                     ["CLIENT", "CACHING"], ["CLIENT", "CACHING", "yes"], ["CLIENT", "CACHING", "yes", "no"],
                     ["CLIENT", "GETREDIR"], ["CLIENT", "GETREDIR", "x"], ["CLIENT", "TRACKINGINFO"],
                     ["CLIENT", "TRACKINGINFO", "x"], ["CLIENT", "tracking", "ON"], ["CLIENT", "CACHING", "yes"],
                     ["CLIENT", "CACHING", "no"], ["CLIENT", "TRACKING", "on", "BCAST"],
                     ["CLIENT", "TRACKING", "on", "OPTIN"], ["CLIENT", "TRACKINGINFO"], ["CLIENT", "CACHING", "maybe"],
                     ["CLIENT", "CACHING", "no"], ["CLIENT", "CACHING", "YES"], ["CLIENT", "TRACKINGINFO"],
                     ["CLIENT", "TRACKING", "on", "OPTOUT"],
                     ["CLIENT", "TRACKING", "on", "redirect", tid(t), "noloop", "optin"], ["CLIENT", "TRACKINGINFO"],
                     ["CLIENT", "GETREDIR"], ["CLIENT", "TRACKING", "off"], ["CLIENT", "TRACKINGINFO"],
                     ["CLIENT", "TRACKING", "on", "OPTOUT"], ["CLIENT", "CACHING", "no"], ["CLIENT", "TRACKINGINFO"],
                     ["CLIENT", "TRACKING", "off"],
                     ["CLIENT", "TRACKING", "on", "BCAST", "PREFIX", "b", "PREFIX", "a"], ["CLIENT", "TRACKINGINFO"],
                     ["CLIENT", "TRACKING", "on", "BCAST", "PREFIX", "ab"], ["CLIENT", "TRACKING", "on", "BCAST", "PREFIX", "c"],
                     ["CLIENT", "TRACKING", "on", "BCAST"], ["CLIENT", "TRACKINGINFO"], ["CLIENT", "TRACKING", "on"],
                     ["CLIENT", "GETREDIR"], ["CLIENT", "TRACKING", "off"], ["CLIENT", "TRACKINGINFO"]):
            r.do(c, *args, secs=0.01, reply=True)


def self_resp3(r):
    a, b = r.conn("a", 3), r.conn("b")
    r.do(b, "FLUSHALL")
    r.do(a, "CLIENT", "TRACKING", "on")
    r.do(b, "MSET", "k1", "1", "k2", "2", "k3", "3")
    r.do(b, "HSET", "h", "f", "v")
    r.do(b, "SADD", "s", "m")
    r.do(a, "GET", "k1")
    r.do(a, "MGET", "k2", "k3", "k4")
    r.do(a, "HGET", "h", "f")
    r.do(a, "EXISTS", "s")
    r.do(a, "LLEN", "k1")
    r.do(b, "SET", "k1", "x")
    r.do(b, "DEL", "k2", "k3", "nokey")
    r.do(b, "SET", "k4", "v")
    r.do(b, "HSET", "h", "f", "v")
    r.do(b, "SADD", "s", "m")
    r.do(b, "SADD", "s", "m2")
    r.do(a, "GET", "k1")
    r.do(a, "SET", "k1", "y")
    r.do(a, "GET", "k1")
    for args in (["MULTI"], ["GET", "k1"], ["SET", "k1", "z"], ["GET", "k1"], ["EXEC"]):
        r.do(a, *args)
    r.do(b, "SET", "k1", "w")
    r.do(a, "GET", "k1")
    r.do(a, "CLIENT", "TRACKING", "on", "NOLOOP")
    r.do(a, "SET", "k1", "w2")
    r.do(b, "SET", "k1", "w3")
    r.do(a, "GET", "k1")
    r.do(b, "SET", "k1", "w4")
    # the table has no database
    r.do(a, "SELECT", "3")
    r.do(a, "GET", "k5")
    r.do(b, "SET", "k5", "v")
    r.do(a, "SELECT", "0")
    # writes that change nothing
    r.do(b, "MSET", "n1", "1")
    r.do(b, "SADD", "n2", "m")
    r.do(b, "HSET", "n3", "f", "v")
    r.do(a, "MGET", "n1", "n2", "n3", "n4")
    r.do(a, "SMEMBERS", "n2")
    r.do(a, "HGETALL", "n3")
    r.do(b, "SADD", "n2", "m")
    r.do(b, "HDEL", "n3", "nof")
    r.do(b, "EXPIRE", "n4", "100")
    r.do(b, "DEL", "n4")
    r.do(b, "PERSIST", "n1")
    r.do(b, "SREM", "n2", "nom")
    r.do(b, "INCR", "n1")
    r.do(b, "APPEND", "n1", "x")


def reads(r):
    a, b = r.conn("a", 3), r.conn("b")
    r.do(b, "FLUSHALL")
    r.do(a, "CLIENT", "TRACKING", "on")
    for args in (["SET", "r:s1", "abc"], ["SET", "r:s2", "abd"], ["RPUSH", "r:l", "3", "1", "2"],
                 ["SADD", "r:a", "1", "2"], ["SADD", "r:b", "2", "3"], ["ZADD", "r:z1", "1", "a"],
                 ["ZADD", "r:z2", "2", "b"], ["HSET", "r:h", "f", "v"], ["PFADD", "r:p1", "x"],
                 ["PFADD", "r:p2", "y"], ["GEOADD", "r:g", "13.36", "38.11", "m"], ["SET", "r:bits", "\x0f"],
                 ["SET", "r:t", "1"], ["SET", "r:o", "1"], ["SET", "r:du", "v"]):
        b.send(*args)
    r.take("setup")
    for args in (["SINTER", "r:a", "r:b"], ["SUNION", "r:a", "r:b"], ["SINTERCARD", "2", "r:a", "r:b"],
                 ["ZUNION", "2", "r:z1", "r:z2"], ["ZINTERCARD", "2", "r:z1", "r:z2"], ["SORT_RO", "r:l"],
                 ["LCS", "r:s1", "r:s2"], ["GEOPOS", "r:g", "m"], ["GEOSEARCH", "r:g", "FROMMEMBER", "m", "BYRADIUS", "1", "km"],
                 ["PFCOUNT", "r:p1", "r:p2"], ["BITCOUNT", "r:bits"], ["BITFIELD_RO", "r:bits", "GET", "u4", "0"],
                 ["TYPE", "r:t"], ["TTL", "r:t"], ["OBJECT", "ENCODING", "r:o"], ["OBJECT", "FREQ", "r:o"],
                 ["DUMP", "r:du"], ["HRANDFIELD", "r:h"], ["ZSCORE", "r:z1", "a"], ["LINDEX", "r:l", "0"],
                 ["GETRANGE", "r:s1", "0", "1"], ["STRLEN", "r:s2"], ["TOUCH", "r:t"], ["KEYS", "r:none*"],
                 ["DBSIZE"]):
        r.do(a, *args, secs=0.01)
    tracking_info(r)
    keys = ["r:s1", "r:s2", "r:l", "r:a", "r:b", "r:z1", "r:z2", "r:h", "r:p1", "r:p2", "r:g", "r:bits", "r:t", "r:o", "r:du"]
    r.do(b, "DEL", *keys)


def tracking_info(r):
    b = r.conn("b")
    got = b.drain()
    b.send("INFO")
    time.sleep(0.05)
    raw = b.drain().decode(errors="replace")
    out = {k: v for k, v in re.findall(r"(tracking_\w+):(\d+)", raw)}
    r.out.append("info %r" % sorted(out.items()))
    b.close()
    r.conns.remove(b)


def redirects(r):
    s = r.conn("s")
    q = r.conn("q")
    t = r.conn("t")
    b = r.conn("b")
    r3 = r.conn("r3", 3)
    r.do(b, "FLUSHALL")
    r.do(s, "SUBSCRIBE", "__redis__:invalidate")
    r.do(t, "CLIENT", "TRACKING", "on", "REDIRECT", tid(s))
    r.do(t, "GET", "a")
    r.do(t, "MGET", "b", "c")
    r.do(b, "SET", "a", "1")
    r.do(b, "MSET", "a", "1", "b", "2")
    r.do(b, "FLUSHALL")
    r.do(t, "GET", "c")
    r.do(t, "CLIENT", "GETREDIR")
    # to a client of RESP2 without a subscription: nothing
    r.do(t, "CLIENT", "TRACKING", "on", "REDIRECT", tid(q))
    r.do(t, "GET", "d")
    r.do(b, "SET", "d", "1")
    r.do(q, "PING")
    # to a client of RESP3 (its pushes come by its next reply at latest)
    r.do(t, "CLIENT", "TRACKING", "on", "REDIRECT", tid(r3))
    r.do(t, "GET", "e")
    b.send("SET", "e", "1")
    r.settle()
    b.drain()
    r.do(r3, "PING")
    # the redirect's own write: the push before its reply
    r.do(t, "GET", "f")
    r.do(r3, "SET", "f", "1")
    r.do(t, "GET", "f")
    r.do(t, "GET", "g")
    r.do(r3, "MSET", "f", "2", "g", "2")
    r.do(b, "FLUSHDB")
    r.do(r3, "PING")
    tracking_info(r)


def broken(r):
    for proto in (3, 2):
        t = r.conn("t%d" % proto, proto)
        x = r.conn("x%d" % proto)
        b = r.conn("b%d" % proto)
        r.do(b, "FLUSHALL")
        r.do(t, "CLIENT", "TRACKING", "on", "REDIRECT", tid(x))
        r.do(t, "GET", "br")
        x.close()
        r.conns.remove(x)
        r.settle(0.1)
        r.do(b, "SET", "br", "1")
        r.do(t, "CLIENT", "TRACKINGINFO")
        r.do(t, "GET", "br")
        r.do(b, "SET", "br", "2")
        r.do(b, "CLIENT", "LIST", "ID", tid(t))
        r.do(t, "CLIENT", "TRACKING", "on")
        r.do(t, "CLIENT", "TRACKINGINFO")
        r.do(b, "FLUSHALL")
        r.do(t, "CLIENT", "TRACKING", "off")


def optin(r):
    a, b = r.conn("a", 3), r.conn("b")
    r.do(b, "FLUSHALL")
    r.do(a, "CLIENT", "TRACKING", "on", "OPTIN")
    r.do(a, "GET", "o1")
    r.do(a, "CLIENT", "CACHING", "yes")
    r.do(a, "GET", "o2")
    r.do(a, "GET", "o3")
    r.do(a, "CLIENT", "CACHING", "yes")
    for args in (["MULTI"], ["GET", "o4"], ["GET", "o5"], ["EXEC"]):
        r.do(a, *args)
    r.do(a, "GET", "o6")
    r.do(a, "CLIENT", "CACHING", "yes")
    r.do(a, "CLIENT", "ID")
    r.do(a, "GET", "o7")
    r.do(a, "CLIENT", "CACHING", "yes")
    r.do(a, "NOSUCHCOMMAND")
    r.do(a, "GET", "o8")
    r.do(b, "MSET", "o1", "x", "o2", "x", "o3", "x", "o4", "x", "o5", "x", "o6", "x", "o7", "x", "o8", "x")
    r.do(a, "CLIENT", "TRACKING", "off")
    r.do(a, "CLIENT", "TRACKING", "on", "OPTOUT")
    r.do(a, "GET", "p1")
    r.do(a, "CLIENT", "CACHING", "no")
    r.do(a, "GET", "p2")
    r.do(a, "GET", "p3")
    r.do(a, "CLIENT", "CACHING", "no")
    r.do(a, "CLIENT", "TRACKINGINFO")
    r.do(a, "PING")
    r.do(a, "GET", "p4")
    r.do(b, "MSET", "p1", "x", "p2", "x", "p3", "x", "p4", "x")


def bcast(r):
    a, n, e, b = r.conn("a", 3), r.conn("n", 3), r.conn("e", 3), r.conn("b")
    s = r.conn("s")
    t = r.conn("t")
    r.do(b, "FLUSHALL")
    r.do(a, "CLIENT", "TRACKING", "on", "BCAST", "PREFIX", "bc:", "PREFIX", "zz")
    r.do(n, "CLIENT", "TRACKING", "on", "BCAST", "NOLOOP", "PREFIX", "bc:")
    r.do(e, "CLIENT", "TRACKING", "on", "BCAST")
    r.do(s, "SUBSCRIBE", "__redis__:invalidate")
    r.do(t, "CLIENT", "TRACKING", "on", "BCAST", "REDIRECT", tid(s), "PREFIX", "zz")
    b.sendmany([["SET", "bc:2", "x"], ["SET", "bc:1", "y"], ["SET", "other", "z"], ["SET", "zz1", "w"],
                ["SET", "bc:2", "again"], ["GET", "bc:1"]])
    r.take("batch")
    r.do(n, "SET", "bc:3", "v")
    r.do(n, "MSET", "bc:4", "v", "zz2", "v")
    r.do(a, "GET", "bc:4")
    r.do(b, "DEL", "bc:1", "nokey")
    r.do(b, "FLUSHDB")
    r.do(b, "RENAME", "bc:3", "zz3")
    r.do(b, "SET", "bc:3", "v")
    r.do(b, "RENAME", "bc:3", "zz3")
    r.do(b, "EXPIRE", "zz3", "100")
    tracking_info(r)
    r.do(a, "CLIENT", "TRACKING", "off")
    r.do(n, "CLIENT", "TRACKING", "off")
    tracking_info(r)


def flushes(r):
    a, s, t, b = r.conn("a", 3), r.conn("s"), r.conn("t"), r.conn("b")
    r.do(b, "FLUSHALL")
    r.do(s, "SUBSCRIBE", "__redis__:invalidate")
    r.do(t, "CLIENT", "TRACKING", "on", "REDIRECT", tid(s))
    r.do(a, "CLIENT", "TRACKING", "on")
    r.do(a, "GET", "x")
    r.do(t, "GET", "x")
    r.do(b, "FLUSHDB")
    r.do(b, "FLUSHDB")
    r.do(a, "FLUSHALL")
    for args in (["MULTI"], ["SET", "y", "1"], ["FLUSHDB"], ["GET", "y"], ["EXEC"]):
        r.do(a, *args)
    r.do(a, "GET", "y")
    r.do(b, "SET", "y", "1")
    r.do(a, "GET", "y")
    r.do(b, "SWAPDB", "0", "1")
    r.do(b, "SWAPDB", "0", "1")
    r.do(b, "MOVE", "y", "2")
    r.do(a, "GET", "y")
    r.do(b, "SELECT", "2")
    r.do(b, "MOVE", "y", "0")
    r.do(b, "SELECT", "0")
    r.do(a, "GET", "z")
    r.do(b, "COPY", "y", "z")
    r.do(a, "MGET", "y", "z")
    r.do(b, "RENAME", "y", "w")
    r.do(b, "FLUSHALL", "ASYNC")
    tracking_info(r)


def states(r):
    a, b, s = r.conn("a", 3), r.conn("b"), r.conn("s")
    r.do(b, "FLUSHALL")
    r.do(s, "SUBSCRIBE", "__redis__:invalidate")
    tracking_info(r)
    r.do(a, "CLIENT", "TRACKING", "on")
    r.do(a, "MGET", "m1", "m2", "m3")
    t = r.conn("t")
    r.do(t, "CLIENT", "TRACKING", "on", "REDIRECT", tid(s))
    r.do(t, "MGET", "m2", "m3", "m4")
    tracking_info(r)
    r.do(a, "CLIENT", "TRACKING", "off")
    tracking_info(r)
    r.do(b, "SET", "m1", "x")
    tracking_info(r)
    r.do(a, "CLIENT", "TRACKING", "on")
    r.do(b, "SET", "m2", "x")
    tracking_info(r)
    r.do(a, "GET", "m5")
    r.do(a, "CLIENT", "REPLY", "OFF")
    r.do(b, "SET", "m5", "x")
    r.do(a, "GET", "m5")
    r.do(b, "SET", "m5", "y")
    r.do(a, "CLIENT", "REPLY", "ON")
    r.do(a, "RESET")
    r.do(a, "CLIENT", "TRACKINGINFO")
    tracking_info(r)
    t.close()
    r.conns.remove(t)
    r.settle(0.1)
    tracking_info(r)
    r.do(b, "MSET", "m3", "x", "m4", "x")
    tracking_info(r)


def expiry(r):
    a, b = r.conn("a", 3), r.conn("b")
    r.do(b, "FLUSHALL")
    r.do(a, "CLIENT", "TRACKING", "on")
    r.do(b, "SET", "ex", "v", "PX", "400")
    r.do(a, "GET", "ex")
    r.take("expired", 0.8)
    tracking_info(r)


def evicted(r):
    a, b = r.conn("a", 3), r.conn("b")
    r.do(b, "FLUSHALL")
    r.do(a, "CLIENT", "TRACKING", "on")
    r.do(b, "SET", "ev", "v")
    r.do(a, "GET", "ev")
    r.do(b, "CONFIG", "SET", "maxmemory-policy", "allkeys-random")
    # Redis evicts within CONFIG SET, BendKV at its next group or tick
    r.do(b, "CONFIG", "SET", "maxmemory", "1", secs=0.3)
    r.do(b, "SET", "ev2", "v")
    r.do(b, "CONFIG", "SET", "maxmemory", "0")
    r.do(b, "CONFIG", "SET", "maxmemory-policy", "noeviction")
    r.do(b, "DBSIZE")
    tracking_info(r)


def limit(r):
    s, t, b = r.conn("s"), r.conn("t"), r.conn("b")
    r.do(b, "FLUSHALL")
    r.do(s, "SUBSCRIBE", "__redis__:invalidate")
    r.do(t, "CLIENT", "TRACKING", "on", "REDIRECT", tid(s))
    r.do(t, "MGET", "l1", "l2", "l3", "l4", "l5")
    tracking_info(r)
    b.send("CONFIG", "SET", "tracking-table-max-keys", "2")
    time.sleep(0.6)
    got = s.drain().decode(errors="replace")
    keys = sorted(re.findall(r"\$2\r\n(l\d)\r\n", got))
    r.out.append("evicted %d %s" % (len(keys), all(k in ("l1", "l2", "l3", "l4", "l5") for k in keys)))
    b.drain()
    tracking_info(r)
    r.do(b, "CONFIG", "SET", "tracking-table-max-keys", "1000000")


def blocked(r):
    t, u, b = r.conn("t", 3), r.conn("u", 3), r.conn("b")
    r.do(b, "FLUSHALL")
    r.do(t, "CLIENT", "TRACKING", "on")
    r.do(u, "CLIENT", "TRACKING", "on")
    r.do(t, "MGET", "dst", "src")
    r.do(u, "GET", "dst")
    r.do(t, "BLMOVE", "src", "dst", "LEFT", "RIGHT", "0")
    r.do(b, "LPUSH", "src", "v")
    r.do(t, "GET", "dst")
    r.do(t, "CLIENT", "TRACKING", "on", "NOLOOP")
    r.do(t, "BLMOVE", "src", "dst", "LEFT", "RIGHT", "0")
    r.do(b, "LPUSH", "src", "w")


SCENARIOS = [("errors", errors), ("self, RESP3", self_resp3), ("keys of reads", reads), ("redirects", redirects),
             ("broken redirects", broken), ("optin and optout", optin), ("bcast", bcast), ("flushes", flushes),
             ("states", states), ("expiry", expiry), ("eviction", evicted), ("table limit", limit),
             ("blocked", blocked)]


def run(port, scenario):
    r = Run(port)
    try:
        scenario(r)
    finally:
        r.close()
    time.sleep(0.1)
    return r.out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, required=True)
    ap.add_argument("--redis", type=int, required=True)
    ap.add_argument("--only", default="")
    a = ap.parse_args()
    fails = 0
    for name, scenario in SCENARIOS:
        if a.only and a.only not in name:
            continue
        got, want = run(a.bendkv, scenario), run(a.redis, scenario)
        diff = [(i, g, w) for i, (g, w) in enumerate(zip(got, want)) if g != w]
        if len(got) != len(want):
            diff.append((min(len(got), len(want)), "%d lines" % len(got), "%d lines" % len(want)))
        if diff:
            fails += 1
            print("FAIL %s: %d of %d lines differ" % (name, len(diff), len(want)))
            for i, g, w in diff[:6]:
                print("  line %d\n    bendkv: %s\n    redis:  %s" % (i, g[:400], w[:400]))
        else:
            print("ok   %s: %d lines" % (name, len(want)))
    if fails:
        sys.exit(1)
    print("TRACKING TESTS PASSED")


if __name__ == "__main__":
    main()
