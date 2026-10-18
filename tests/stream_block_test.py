#!/usr/bin/env python3
"""XREAD and XREADGROUP with BLOCK against Redis: scenarios of clients
that wait on streams, each run on BendKV and on Redis with clients of
their own, the transcripts compared line by line (the times XINFO shows
left out).

XREAD: a client served by an XADD, one served at once (old entries), a
timeout, an empty stream and one that ran dry (Redis's #5299), "$" as
the last ID of a key there and of a key not there, the same key three
times, COUNT, XADDs in MULTI, an XADD and a DEL in MULTI that leave no
entry to serve (and with an LPUSH after them), a key made of another
kind (SET, LPUSH) that serves no one until it is a stream again, a key
of another kind among the keys of a read run again (WRONGTYPE), an ID
whose sequence is the largest, XDEL, XTRIM and XSETID, which signal no
one, RESTORE, RENAME, COPY, MOVE and SWAPDB, which make a stream there,
FLUSHALL, a pipeline behind the read, a read in MULTI, a key of another
database, and the tracking of the keys of a read that waits.

XREADGROUP: a client served by an XADD, and its pending entries; a
timeout, after which its consumer is there; DESTROY, DEL, SET, a DEL
and an SADD in MULTI, FLUSHALL, FLUSHDB, SWAPDB (no key, a list, a
stream with the group), RENAME (with the group, without), which answer
it an error or serve it; two consumers of a group, the first served
first; a consumer deleted while its client waits, made again when the
client is run again; XGROUP SETID, which signals no one; NOACK; an ID
that is not ">", which never waits; a key of a list's client (Redis's
"stream key that has clients blocked on list"); a client run again that
waits again, its time as it was; a stream whose time passes (the sweep
of expired keys deletes it); CLIENT KILL of a client that waits.

Both: CLIENT UNBLOCK with TIMEOUT and ERROR; INFO's blocked_clients,
total_blocking_keys and total_blocking_keys_on_nokey; CLIENT LIST's
flags, cmd and argv-mem of a client that waits (XREAD's "$" rewritten);
the calls, failed calls and errors INFO counts; the changes counted
(rdb_changes_since_last_save); the keyspace events; RESP3's replies.

    python3 tests/stream_block_test.py --bendkv 6380 --redis 6390
"""
import argparse
import re
import socket
import sys
import time


def enc(args):
    out = [b"*%d\r\n" % len(args)]
    for a in args:
        a = a if isinstance(a, bytes) else str(a).encode()
        out.append(b"$%d\r\n%s\r\n" % (len(a), a))
    return b"".join(out)


class Client:
    """A connection whose reads time out: a reply that does not come in
    time reads as TIMEOUT. RESP3's kinds read as tagged tuples."""

    def __init__(self, port, db="9", resp3=False):
        self.port = port
        self.sock = socket.create_connection(("127.0.0.1", port))
        self.buf = b""
        if resp3:
            self.cmd("HELLO", "3")
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

    def _bulk(self, n, timeout):
        while len(self.buf) < n + 2:
            if not self._fill(timeout):
                return None
        data, self.buf = self.buf[:n], self.buf[n + 2:]
        return data.decode(errors="replace")

    def read(self, timeout=3.0):
        line = self._line(timeout)
        if line is None:
            return "TIMEOUT"
        kind, rest = line[:1], line[1:]
        if kind in (b"+", b"-", b":", b",", b"#", b"("):
            return (kind + rest).decode()
        if kind == b"_":
            return "NULL"
        if kind in (b"$", b"="):
            n = int(rest)
            if n < 0:
                return None
            d = self._bulk(n, timeout)
            return "TIMEOUT" if d is None else d
        if kind in (b"*", b"~", b">"):
            n = int(rest)
            if n < 0:
                return "NULLA"
            xs = [self.read(timeout) for _ in range(n)]
            return xs if kind == b"*" else (kind.decode(), xs)
        if kind == b"%":
            n = int(rest)
            return ("%", [[self.read(timeout), self.read(timeout)] for _ in range(n)])
        return "?" + line.decode()

    def cmd(self, *args):
        self.send(*args)
        return self.read()

    # a command whose reply is one bulk of bytes (DUMP)
    def bulk(self, *args):
        self.send(*args)
        line = self._line(3.0)
        n = int(line[1:])
        while len(self.buf) < n + 2:
            self._fill(3.0)
        data, self.buf = self.buf[:n], self.buf[n + 2:]
        return data

    def close(self):
        self.sock.close()


def info(r, section, name):
    for l in r.cmd("INFO", section).splitlines():
        if l.startswith(name + ":"):
            return l.split(":", 1)[1]
    return None


def blocked(r):
    return int(info(r, "clients", "blocked_clients"))


def wait_blocked(r, n, tries=300):
    for _ in range(tries):
        if blocked(r) == n:
            return n
        time.sleep(0.01)
    return blocked(r)


def bkeys(r):
    return info(r, "clients", "total_blocking_keys"), info(r, "clients", "total_blocking_keys_on_nokey")


def dirty(r):
    return int(info(r, "persistence", "rdb_changes_since_last_save"))


def stat(r, name):
    """a command's calls, rejected and failed calls (its time left out)"""
    v = info(r, "commandstats", "cmdstat_" + name)
    if v is None:
        return None
    return re.sub(r"usec=\d+,usec_per_call=[\d.]+,", "", v)


def errstat(r, name):
    return info(r, "errorstats", "errorstat_" + name)


# XINFO CONSUMERS without the times: each consumer's name and pending
def consumers(r, k, g):
    x = r.cmd("XINFO", "CONSUMERS", k, g)
    if not isinstance(x, list):
        return x
    out = []
    for c in x:
        d = dict(zip(c[0::2], c[1::2]))
        out.append((d.get("name"), d.get("pending")))
    return out


def client_line(r, cid):
    for l in r.cmd("CLIENT", "LIST").splitlines():
        f = dict(x.split("=", 1) for x in l.split(" ") if "=" in x)
        if f.get("id") == cid:
            return f.get("flags"), f.get("cmd"), f.get("argv-mem")
    return None


def xread_scenarios(r, a, b, log):
    # 1. a client served by an XADD; another key's XADD serves no one
    r.cmd("DEL", "s1", "s2", "s3")
    r.cmd("XADD", "s2", "1-1", "old", "x")
    a.send("XREAD", "BLOCK", "0", "STREAMS", "s1", "s2", "s3", "$", "$", "$")
    log("1 blocked", wait_blocked(r, 1), bkeys(r))
    r.cmd("XADD", "s9", "1-1", "f", "v")
    log("1 other", a.read(0.2), wait_blocked(r, 1))
    log("1 xadd", r.cmd("XADD", "s2", "2-1", "new", "y"))
    log("1 a", a.read(), wait_blocked(r, 0), bkeys(r))
    # 2. old entries: served at once
    log("2 old", a.cmd("XREAD", "BLOCK", "20000", "STREAMS", "s1", "s2", "s3", "$", "0-0", "$"))
    # 3. a timeout
    a.send("XREAD", "BLOCK", "100", "STREAMS", "s1", "666")
    log("3 timeout", a.read(), wait_blocked(r, 0))
    # 4. no entry past the ID: no empty array
    r.cmd("DEL", "s1")
    r.cmd("XADD", "s1", "666", "f", "v")
    r.cmd("XADD", "s1", "667", "f2", "v2")
    r.cmd("XDEL", "s1", "667")
    log("4 empty", a.cmd("XREAD", "BLOCK", "10", "STREAMS", "s1", "666"))
    # 5. a stream that ran dry
    r.cmd("DEL", "m")
    r.cmd("XADD", "m", "666", "key", "value")
    r.cmd("XDEL", "m", "666")
    log("5 dry", a.cmd("XREAD", "BLOCK", "10", "STREAMS", "m", "665"))
    log("5 errors", r.cmd("XADD", "m", "665", "key", "value"), r.cmd("XADD", "m", "666", "key", "value"))
    a.send("XREAD", "BLOCK", "0", "STREAMS", "m", "665")
    log("5 blocked", wait_blocked(r, 1))
    r.cmd("XADD", "m", "667", "key", "value")
    log("5 a", a.read(), wait_blocked(r, 0))
    # 6. an XADD and a DEL in MULTI serve no one; then an XADD does
    r.cmd("DEL", "s1")
    a.send("XREAD", "BLOCK", "20000", "STREAMS", "s1", "$")
    wait_blocked(r, 1)
    r.cmd("MULTI")
    r.cmd("XADD", "s1", "1-1", "old", "x")
    r.cmd("DEL", "s1")
    log("6 exec", r.cmd("EXEC"))
    log("6 a", a.read(0.2), wait_blocked(r, 1))
    r.cmd("XADD", "s1", "2-1", "new", "y")
    log("6 new", a.read(), wait_blocked(r, 0))
    # 7. and an LPUSH after them
    r.cmd("DEL", "s1")
    a.send("XREAD", "BLOCK", "20000", "STREAMS", "s1", "$")
    wait_blocked(r, 1)
    r.cmd("MULTI")
    r.cmd("XADD", "s1", "1-1", "old", "x")
    r.cmd("DEL", "s1")
    r.cmd("LPUSH", "s1", "foo", "bar")
    log("7 exec", r.cmd("EXEC"))
    log("7 a", a.read(0.2), wait_blocked(r, 1))
    r.cmd("DEL", "s1")
    r.cmd("XADD", "s1", "2-1", "new", "y")
    log("7 new", a.read(), wait_blocked(r, 0))
    # 8. the same key three times
    r.cmd("DEL", "s2")
    r.cmd("XADD", "s2", "1-1", "old", "x")
    a.send("XREAD", "BLOCK", "20000", "STREAMS", "s2", "s2", "s2", "$", "$", "$")
    wait_blocked(r, 1)
    r.cmd("XADD", "s2", "2-1", "new", "y")
    log("8 a", a.read(), wait_blocked(r, 0))
    # 9. XADDs in MULTI, and COUNT
    a.send("XREAD", "COUNT", "2", "BLOCK", "20000", "STREAMS", "s2", "$")
    wait_blocked(r, 1)
    r.cmd("MULTI")
    for i in (3, 4, 5):
        r.cmd("XADD", "s2", "%d-1" % i, "field", str(i))
    log("9 exec", r.cmd("EXEC"))
    log("9 a", a.read(), wait_blocked(r, 0))
    # 10. the largest sequence
    r.cmd("DEL", "x")
    a.send("XREAD", "BLOCK", "0", "STREAMS", "x", "1-18446744073709551615")
    wait_blocked(r, 1)
    r.cmd("XADD", "x", "1-1", "f", "v")
    log("10 1-1", a.read(0.2), wait_blocked(r, 1))
    r.cmd("XADD", "x", "1-18446744073709551615", "f", "v")
    log("10 1-max", a.read(0.2), wait_blocked(r, 1))
    r.cmd("XADD", "x", "2-1", "f", "v")
    log("10 2-1", a.read(), wait_blocked(r, 0))
    # 11. a key made of another kind serves no one; DEL and XADD do
    r.cmd("DEL", "k")
    a.send("XREAD", "BLOCK", "0", "STREAMS", "k", "$")
    wait_blocked(r, 1)
    r.cmd("SET", "k", "v")
    log("11 set", a.read(0.2), wait_blocked(r, 1))
    r.cmd("DEL", "k")
    r.cmd("LPUSH", "k", "v")
    log("11 lpush", a.read(0.2), wait_blocked(r, 1))
    r.cmd("DEL", "k")
    r.cmd("XADD", "k", "667", "f", "v")
    log("11 xadd", a.read(), wait_blocked(r, 0))
    # 12. a read run again finds a key of another kind among its keys
    r.cmd("DEL", "k1", "k2")
    r.cmd("XADD", "k2", "1-1", "f", "v")
    a.send("XREAD", "BLOCK", "0", "STREAMS", "k1", "k2", "$", "$")
    wait_blocked(r, 1)
    r.cmd("SET", "k1", "v")
    log("12 set", a.read(0.2), wait_blocked(r, 1))
    r.cmd("XADD", "k2", "2-1", "f", "v")
    log("12 xadd", a.read(), wait_blocked(r, 0))
    # 13. XDEL, XTRIM and XSETID signal no one
    r.cmd("DEL", "t")
    r.cmd("XADD", "t", "1-1", "f", "v")
    r.cmd("XADD", "t", "2-1", "f", "v")
    a.send("XREAD", "BLOCK", "0", "STREAMS", "t", "$")
    wait_blocked(r, 1)
    r.cmd("XDEL", "t", "1-1")
    r.cmd("XTRIM", "t", "MAXLEN", "0")
    r.cmd("XSETID", "t", "5-0")
    log("13 quiet", a.read(0.2), wait_blocked(r, 1))
    r.cmd("XADD", "t", "6-1", "f", "v")
    log("13 xadd", a.read(), wait_blocked(r, 0))
    # 14. RESTORE, RENAME, COPY and MOVE make a stream where a client waits
    r.cmd("DEL", "src", "w14")
    r.cmd("XADD", "src", "7-1", "f", "v")
    payload = r.bulk("DUMP", "src")
    a.send("XREAD", "BLOCK", "0", "STREAMS", "w14", "$")
    wait_blocked(r, 1)
    r.cmd("RESTORE", "w14", "0", payload)
    log("14 restore", a.read(), wait_blocked(r, 0))
    r.cmd("DEL", "w14")
    a.send("XREAD", "BLOCK", "0", "STREAMS", "w14", "$")
    wait_blocked(r, 1)
    r.cmd("RENAME", "src", "w14")
    log("14 rename", a.read(), wait_blocked(r, 0))
    r.cmd("DEL", "w14", "src")
    r.cmd("XADD", "src", "8-1", "f", "v")
    a.send("XREAD", "BLOCK", "0", "STREAMS", "w14", "$")
    wait_blocked(r, 1)
    r.cmd("COPY", "src", "w14")
    log("14 copy", a.read(), wait_blocked(r, 0))
    r.cmd("DEL", "w14")
    r.cmd("SELECT", "8")
    r.cmd("DEL", "w14")
    r.cmd("XADD", "w14", "9-1", "f", "v")
    a.send("XREAD", "BLOCK", "0", "STREAMS", "w14", "$")
    wait_blocked(r, 1)
    r.cmd("MOVE", "w14", "9")
    r.cmd("SELECT", "9")
    log("14 move", a.read(), wait_blocked(r, 0))
    # 15. SWAPDB brings a stream; FLUSHALL serves no XREAD
    r.cmd("DEL", "w15")
    r.cmd("SELECT", "8")
    r.cmd("DEL", "w15")
    r.cmd("XADD", "w15", "3-1", "f", "v")
    r.cmd("SELECT", "9")
    a.send("XREAD", "BLOCK", "0", "STREAMS", "w15", "$")
    wait_blocked(r, 1)
    log("15 swap", r.cmd("SWAPDB", "8", "9"), a.read(), wait_blocked(r, 0))
    r.cmd("SWAPDB", "8", "9")
    a.send("XREAD", "BLOCK", "0", "STREAMS", "w15", "$")
    wait_blocked(r, 1)
    r.cmd("FLUSHALL")
    log("15 flush", a.read(0.2), wait_blocked(r, 1))
    r.cmd("XADD", "w15", "1-1", "f", "v")
    log("15 xadd", a.read(), wait_blocked(r, 0))
    # 16. a pipeline behind the read
    r.cmd("DEL", "p")
    a.raw(enc(["XREAD", "BLOCK", "0", "STREAMS", "p", "$"]) + enc(["PING"]) + enc(["XLEN", "p"]))
    wait_blocked(r, 1)
    r.cmd("XADD", "p", "1-1", "f", "v")
    log("16 a", a.read(), a.read(), a.read(), wait_blocked(r, 0))
    # 17. in MULTI it does not wait
    a.cmd("MULTI")
    a.cmd("XREAD", "BLOCK", "0", "STREAMS", "p", "$")
    log("17 exec", a.cmd("EXEC"), wait_blocked(r, 0))
    # 18. errors before it waits
    log("18 errors", a.cmd("XREAD", "BLOCK", "-1", "STREAMS", "p", "$"),
        a.cmd("XREAD", "BLOCK", "x", "STREAMS", "p", "$"),
        a.cmd("XREAD", "BLOCK", "9223372036854775807", "STREAMS", "p", "$"),
        a.cmd("XREAD", "BLOCK", "0", "STREAMS", "p", ">"),
        a.cmd("SET", "str", "v"),
        a.cmd("XREAD", "BLOCK", "0", "STREAMS", "p", "str", "$", "$"), wait_blocked(r, 0))


def unblock_scenarios(r, a, b, log):
    aid = a.cmd("CLIENT", "ID")
    r.cmd("DEL", "u")
    # 19. CLIENT UNBLOCK, TIMEOUT and ERROR; CLIENT LIST while it waits
    a.send("XREAD", "BLOCK", "0", "STREAMS", "u", "u", "$", "$")
    wait_blocked(r, 1)
    log("19 list", client_line(r, aid[1:]), bkeys(r))
    log("19 unblock", r.cmd("CLIENT", "UNBLOCK", aid[1:]), a.read(), wait_blocked(r, 0))
    r.cmd("XADD", "u", "5-1", "f", "v")
    a.send("XREAD", "BLOCK", "0", "STREAMS", "u", "$")
    wait_blocked(r, 1)
    log("19 list $", client_line(r, aid[1:]))
    log("19 error", r.cmd("CLIENT", "UNBLOCK", aid[1:], "ERROR"), a.read(), wait_blocked(r, 0))
    r.cmd("XGROUP", "CREATE", "u", "g", "$")
    a.send("XREADGROUP", "GROUP", "g", "c", "BLOCK", "0", "STREAMS", "u", ">")
    wait_blocked(r, 1)
    log("19 group list", client_line(r, aid[1:]), bkeys(r))
    log("19 group unblock", r.cmd("CLIENT", "UNBLOCK", aid[1:], "TIMEOUT"), a.read(), wait_blocked(r, 0), bkeys(r))


def group_scenarios(r, a, b, log):
    # 20. a client served by an XADD, and its pending entry
    r.cmd("DEL", "ms")
    r.cmd("XGROUP", "CREATE", "ms", "mg", "$", "MKSTREAM")
    d0 = dirty(r)
    a.send("XREADGROUP", "GROUP", "mg", "Alice", "BLOCK", "0", "STREAMS", "ms", ">")
    log("20 blocked", wait_blocked(r, 1), bkeys(r), consumers(r, "ms", "mg"), dirty(r) - d0)
    r.cmd("XADD", "ms", "1-1", "f", "v")
    log("20 a", a.read(), wait_blocked(r, 0), dirty(r) - d0)
    log("20 pending", r.cmd("XPENDING", "ms", "mg", "-", "+", "10")[0][:2], consumers(r, "ms", "mg"))
    # 21. a timeout; its consumer is there
    a.send("XREADGROUP", "GROUP", "mg", "Bob", "BLOCK", "10", "STREAMS", "ms", ">")
    log("21 timeout", a.read(), wait_blocked(r, 0), consumers(r, "ms", "mg"))
    # 22. no entry served: no empty array
    r.cmd("XADD", "ms", "2-1", "f2", "v2")
    r.cmd("XDEL", "ms", "2-1")
    log("22 empty", a.cmd("XREADGROUP", "GROUP", "mg", "Alice", "BLOCK", "10", "STREAMS", "ms", ">"))
    # 23. errors that end the wait
    for name, setup, act in (
            ("destroy", None, ["XGROUP", "DESTROY", "ms", "mg"]),
            ("del", None, ["DEL", "ms"]),
            ("set", None, ["SET", "ms", "val1"]),
            ("flushall", None, ["FLUSHALL"]),
            ("flushdb", None, ["FLUSHDB"]),
            ("rename nogroup", ["XADD", "ms2", "100", "f1", "v1"], ["RENAME", "ms2", "ms"])):
        r.cmd("DEL", "ms", "ms2")
        r.cmd("XADD", "ms", "666", "f", "v")
        r.cmd("XGROUP", "CREATE", "ms", "mg", "$")
        r.cmd("CONFIG", "RESETSTAT")
        if setup:
            r.cmd(*setup)
        a.send("XREADGROUP", "GROUP", "mg", "Alice", "BLOCK", "0", "STREAMS", "ms", ">")
        wait_blocked(r, 1)
        log("23 " + name, r.cmd(*act), a.read(), wait_blocked(r, 0), bkeys(r), stat(r, "xreadgroup"),
            errstat(r, "NOGROUP"), errstat(r, "WRONGTYPE"), info(r, "stats", "total_error_replies"))
    # 24. a DEL and an SADD in MULTI
    r.cmd("DEL", "ms")
    r.cmd("XADD", "ms", "666", "f", "v")
    r.cmd("XGROUP", "CREATE", "ms", "mg", "$")
    a.send("XREADGROUP", "GROUP", "mg", "Alice", "BLOCK", "0", "STREAMS", "ms", ">")
    wait_blocked(r, 1)
    r.cmd("MULTI")
    r.cmd("DEL", "ms")
    r.cmd("SADD", "ms", "e1")
    log("24 exec", r.cmd("EXEC"), a.read(), wait_blocked(r, 0))
    # 25. SWAPDB: no key there, a list there, a stream with the group
    for name, other in (("none", None), ("list", ["LPUSH", "ms", "e1"]),
                        ("stream", "group")):
        r.cmd("SELECT", "4")
        r.cmd("FLUSHDB")
        if other == "group":
            r.cmd("XADD", "ms", "5-1", "f", "v")
            r.cmd("XGROUP", "CREATE", "ms", "mg", "0")
        elif other:
            r.cmd(*other)
        r.cmd("SELECT", "9")
        r.cmd("DEL", "ms")
        r.cmd("XADD", "ms", "666", "f", "v")
        r.cmd("XGROUP", "CREATE", "ms", "mg", "$")
        a.send("XREADGROUP", "GROUP", "mg", "Alice", "BLOCK", "0", "STREAMS", "ms", ">")
        wait_blocked(r, 1)
        log("25 swap " + name, r.cmd("SWAPDB", "4", "9"), a.read(), wait_blocked(r, 0))
        r.cmd("SWAPDB", "4", "9")
    # 26. RENAME with the group serves it
    r.cmd("DEL", "ms", "ms2")
    r.cmd("XGROUP", "CREATE", "ms", "mg", "$", "MKSTREAM")
    a.send("XREADGROUP", "GROUP", "mg", "Alice", "BLOCK", "0", "STREAMS", "ms", ">")
    wait_blocked(r, 1)
    r.cmd("XGROUP", "CREATE", "ms2", "mg", "$", "MKSTREAM")
    r.cmd("XADD", "ms2", "100", "f1", "v1")
    log("26 rename", r.cmd("RENAME", "ms2", "ms"), a.read(), wait_blocked(r, 0))
    # 27. two consumers: the first served first, the second waits again
    r.cmd("DEL", "ms")
    r.cmd("XGROUP", "CREATE", "ms", "mg", "$", "MKSTREAM")
    a.send("XREADGROUP", "GROUP", "mg", "c1", "BLOCK", "0", "STREAMS", "ms", ">")
    wait_blocked(r, 1)
    b.send("XREADGROUP", "GROUP", "mg", "c2", "BLOCK", "0", "STREAMS", "ms", ">")
    wait_blocked(r, 2)
    r.cmd("XADD", "ms", "1-1", "f", "v")
    log("27 first", a.read(), b.read(0.2), wait_blocked(r, 1))
    r.cmd("XADD", "ms", "2-1", "f", "v")
    log("27 second", b.read(), wait_blocked(r, 0), consumers(r, "ms", "mg"))
    # 28. a consumer deleted while its client waits is made again
    a.send("XREADGROUP", "GROUP", "mg", "c3", "BLOCK", "0", "STREAMS", "ms", ">")
    wait_blocked(r, 1)
    log("28 delconsumer", r.cmd("XGROUP", "DELCONSUMER", "ms", "mg", "c3"), consumers(r, "ms", "mg"))
    r.cmd("XADD", "ms", "3-1", "f", "v")
    log("28 a", a.read(), wait_blocked(r, 0), consumers(r, "ms", "mg"))
    # 29. XGROUP SETID signals no one; the next XADD serves what it left
    a.send("XREADGROUP", "GROUP", "mg", "c1", "BLOCK", "0", "STREAMS", "ms", ">")
    wait_blocked(r, 1)
    r.cmd("XGROUP", "SETID", "ms", "mg", "0")
    log("29 setid", a.read(0.2), wait_blocked(r, 1))
    r.cmd("XADD", "ms", "4-1", "f", "v")
    log("29 xadd", a.read(), wait_blocked(r, 0))
    # 30. a client run again that waits again keeps its time
    r.cmd("XGROUP", "SETID", "ms", "mg", "$")
    a.send("XREADGROUP", "GROUP", "mg", "c1", "BLOCK", "0", "STREAMS", "ms", ">")
    wait_blocked(r, 1)
    t0 = time.time()
    b.send("XREADGROUP", "GROUP", "mg", "c2", "BLOCK", "600", "STREAMS", "ms", ">")
    wait_blocked(r, 2)
    time.sleep(0.2)
    r.cmd("XADD", "ms", "5-1", "f", "v")
    got = b.read()
    log("30 again", a.read(), got, round(time.time() - t0, 1) <= 0.8, wait_blocked(r, 0))
    # 31. NOACK
    r.cmd("DEL", "ms")
    r.cmd("XGROUP", "CREATE", "ms", "mg", "$", "MKSTREAM")
    r.cmd("XADD", "ms", "1-1", "f1", "v1")
    r.cmd("XREADGROUP", "GROUP", "mg", "Alice", "NOACK", "STREAMS", "ms", ">")
    a.send("XREADGROUP", "GROUP", "mg", "Bob", "BLOCK", "0", "NOACK", "STREAMS", "ms", ">")
    wait_blocked(r, 1)
    log("31 consumers", consumers(r, "ms", "mg"))
    r.cmd("XADD", "ms", "2-1", "f2", "v2")
    log("31 a", a.read(), wait_blocked(r, 0), consumers(r, "ms", "mg"), r.cmd("XPENDING", "ms", "mg"))
    # 32. an ID that is not ">" never waits
    r.cmd("DEL", "ms")
    r.cmd("XGROUP", "CREATE", "ms", "mg", "$", "MKSTREAM")
    r.cmd("XADD", "ms", "666", "key", "value")
    r.cmd("XDEL", "ms", "666")
    log("32 history", [a.cmd("XREADGROUP", "GROUP", "mg", "mc", "BLOCK", "0", "STREAMS", "ms", i) for i in ("0", "600", "666", "700")])
    # 33. a key a list's client waits on (Redis's endless loop test too)
    r.cmd("DEL", "ms")
    b.send("BLPOP", "ms", "0")
    wait_blocked(r, 1)
    log("33 list", bkeys(r))
    r.cmd("XADD", "ms", "666", "key", "value")
    r.cmd("XGROUP", "CREATE", "ms", "mg", "$", "MKSTREAM")
    a.send("XREADGROUP", "GROUP", "mg", "mc", "BLOCK", "0", "STREAMS", "ms", ">")
    log("33 both", wait_blocked(r, 2), bkeys(r))
    r.cmd("DEL", "ms")
    log("33 del", a.read(), wait_blocked(r, 1), bkeys(r))
    r.cmd("LPUSH", "ms", "x")
    log("33 pop", b.read(), wait_blocked(r, 0), bkeys(r))
    # 34. two keys, the second served
    r.cmd("DEL", "g1", "g2")
    r.cmd("XGROUP", "CREATE", "g1", "mg", "$", "MKSTREAM")
    r.cmd("XGROUP", "CREATE", "g2", "mg", "$", "MKSTREAM")
    a.send("XREADGROUP", "GROUP", "mg", "c", "COUNT", "5", "BLOCK", "0", "STREAMS", "g1", "g2", ">", ">")
    log("34 blocked", wait_blocked(r, 1), bkeys(r))
    r.cmd("XADD", "g2", "1-1", "f", "v")
    log("34 a", a.read(), wait_blocked(r, 0))
    # 35. the counts of a client served, and of one whose time is up
    r.cmd("CONFIG", "RESETSTAT")
    a.send("XREADGROUP", "GROUP", "mg", "c", "BLOCK", "0", "STREAMS", "g1", ">")
    wait_blocked(r, 1)
    log("35 waiting", stat(r, "xreadgroup"))
    r.cmd("XADD", "g1", "2-1", "f", "v")
    log("35 served", a.read(), wait_blocked(r, 0), stat(r, "xreadgroup"))
    a.send("XREAD", "BLOCK", "20", "STREAMS", "g1", "$")
    log("35 late", a.read(), wait_blocked(r, 0), stat(r, "xread"), info(r, "stats", "total_error_replies"))


def more_scenarios(r, a, b, port, log):
    # 38. a key of another database serves no one
    r.cmd("DEL", "d38")
    a.send("XREAD", "BLOCK", "0", "STREAMS", "d38", "$")
    wait_blocked(r, 1)
    r.cmd("SELECT", "8")
    r.cmd("XADD", "d38", "1-1", "f", "v")
    r.cmd("SELECT", "9")
    log("38 other db", a.read(0.2), wait_blocked(r, 1))
    r.cmd("XADD", "d38", "2-1", "f", "v")
    log("38 own db", a.read(), wait_blocked(r, 0))
    # 39. a stream whose time passes: the sweep of expired keys deletes it,
    # which answers XREADGROUP NOGROUP and leaves XREAD waiting
    r.cmd("DEL", "e39")
    r.cmd("XGROUP", "CREATE", "e39", "mg", "$", "MKSTREAM")
    r.cmd("PEXPIRE", "e39", "150")
    a.send("XREADGROUP", "GROUP", "mg", "c", "BLOCK", "0", "STREAMS", "e39", ">")
    b.send("XREAD", "BLOCK", "1500", "STREAMS", "e39", "$")
    wait_blocked(r, 2)
    log("39 expired", a.read(5.0), b.read(5.0), r.cmd("EXISTS", "e39"), wait_blocked(r, 0))
    # 40. CLIENT KILL of a client that waits: its call never counted
    r.cmd("CONFIG", "RESETSTAT")
    c = Client(port)
    cid = c.cmd("CLIENT", "ID")[1:]
    r.cmd("XGROUP", "CREATE", "k40", "mg", "$", "MKSTREAM")
    c.send("XREADGROUP", "GROUP", "mg", "c40", "BLOCK", "0", "STREAMS", "k40", ">")
    wait_blocked(r, 1)
    log("40 kill", r.cmd("CLIENT", "KILL", "ID", cid), wait_blocked(r, 0), stat(r, "xreadgroup"), consumers(r, "k40", "mg"), bkeys(r))
    c.close()
    # 41. the keys of an XREAD that waits go to the tracking table: an XADD
    # invalidates them before the read is served
    t = Client(port, resp3=True)
    t.cmd("CLIENT", "TRACKING", "on")
    r.cmd("DEL", "t41")
    r.cmd("XADD", "t41", "1-1", "f", "v")
    t.send("XREAD", "BLOCK", "0", "STREAMS", "t41", "$")
    wait_blocked(r, 1)
    r.cmd("XADD", "t41", "2-1", "f", "v")
    log("41 tracking", t.read(), t.read(), wait_blocked(r, 0))
    r.cmd("XADD", "t41", "3-1", "f", "v")
    log("41 again", t.read(), t.read(0.2))
    t.close()


def events_scenarios(r, a, b, port, log):
    # 36. the keyspace events of a client that waits in XREADGROUP
    r.cmd("CONFIG", "SET", "notify-keyspace-events", "KEA")
    s = Client(port, None)
    s.cmd("PSUBSCRIBE", "__keyspace@9__:ev*")
    r.cmd("DEL", "ev")
    r.cmd("XGROUP", "CREATE", "ev", "mg", "$", "MKSTREAM")
    a.send("XREADGROUP", "GROUP", "mg", "c", "BLOCK", "0", "STREAMS", "ev", ">")
    wait_blocked(r, 1)
    r.cmd("XADD", "ev", "1-1", "f", "v")
    a.read()
    r.cmd("XGROUP", "DESTROY", "ev", "mg")
    msgs = []
    while True:
        m = s.read(0.3)
        if m == "TIMEOUT":
            break
        msgs.append(m[3] if isinstance(m, list) and len(m) == 4 else m)
    log("36 events", msgs)
    s.close()
    r.cmd("CONFIG", "SET", "notify-keyspace-events", "")


def resp3_scenarios(port, log):
    r = Client(port)
    a = Client(port, resp3=True)
    # 37. RESP3's replies: a map of the keys served, a null
    r.cmd("DEL", "r3", "r3b")
    r.cmd("XADD", "r3b", "1-1", "f", "v")
    a.send("XREAD", "BLOCK", "0", "STREAMS", "r3", "r3b", "$", "$")
    wait_blocked(r, 1)
    r.cmd("XADD", "r3b", "2-1", "f", "v")
    log("37 map", a.read(), wait_blocked(r, 0))
    a.send("XREAD", "BLOCK", "10", "STREAMS", "r3", "$")
    log("37 null", a.read())
    r.cmd("XGROUP", "CREATE", "r3", "g", "$", "MKSTREAM")
    a.send("XREADGROUP", "GROUP", "g", "c", "BLOCK", "0", "STREAMS", "r3", ">")
    wait_blocked(r, 1)
    r.cmd("XADD", "r3", "1-1", "a", "b")
    log("37 group", a.read(), wait_blocked(r, 0))
    a.close()
    r.close()


def scenarios(port, log):
    r = Client(port)
    r.cmd("FLUSHALL")
    r.cmd("CONFIG", "RESETSTAT")
    a, b = Client(port), Client(port)
    xread_scenarios(r, a, b, log)
    unblock_scenarios(r, a, b, log)
    group_scenarios(r, a, b, log)
    more_scenarios(r, a, b, port, log)
    events_scenarios(r, a, b, port, log)
    a.close()
    b.close()
    resp3_scenarios(port, log)
    r.cmd("FLUSHALL")
    r.close()


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
            if bad <= 30:
                print("FAIL: BendKV %s\n      Redis  %s" % (x, y))
    if bad:
        print("FAIL: %d of %d lines of the scenarios differ" % (bad, len(outs[1])))
        sys.exit(1)
    print("OK: %d lines of stream waits as Redis answers them" % len(outs[1]))


if __name__ == "__main__":
    main()
