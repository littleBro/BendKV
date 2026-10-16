#!/usr/bin/env python3
"""Streams' DUMP and RESTORE against Redis 7.0.15. BendKV has no stream
command yet, so Redis makes the streams, with its commands, at several
node limits (stream-node-max-entries and -bytes). Redis runs with
rdbcompression no (BendKV writes no LZF) and sanitize-dump-payload yes;
all four are set back after.

- Streams of every shape: empty (MKSTREAM, and every entry deleted), one
  entry, entries of the master's fields and of fields of their own,
  fields and values that are integers (of each width, and the texts of
  numbers that are not one), empty and of 63, 64, 4,095, 4,096 and
  70,000 bytes; entries deleted (the first, the last, all of a node's),
  trimmed (MAXLEN and MINID, exact and ~, a node left with no live
  entry, an entry added after it below its master ID), IDs near 2^64 and
  sequences that go down from the master's, XSETID's ENTRIESADDED and
  MAXDELETEDID; groups (named by integers, and empty), their last IDs
  and entries read (-1 too), entries delivered, claimed (RETRYCOUNT up
  to 2^63 - 1, TIME), acknowledged, consumers with none pending; nodes of
  one entry, of no limit and of more than 65,535 elements; a stream of
  100,000 entries. Each payload Redis DUMPs is RESTOREd on BendKV and
  DUMPed back, byte for byte, and RESTOREd on both, each server's
  DUMPed by the other; TYPE, OBJECT ENCODING, EXISTS, SCAN's TYPE, COPY,
  RENAME, EXPIRE and other kinds' commands (WRONGTYPE) on both.
- The same streams as Redis 5 and 6 wrote them (type 15, made here from
  the payloads: no first ID, greatest deleted ID, count of entries
  added, nor any group's count of entries read): RESTOREd and DUMPed by
  both (type 19, with what 15 lacks estimated as Redis estimates it),
  byte for byte.
- Payloads cut, grown and changed at random (their checksum made
  right), each RESTOREd on both: what Redis refuses BendKV refuses, and
  what both take both DUMP the same. BendKV refuses more than Redis
  (src/rdb.bend, Streams): the test counts them.

    python3 tests/stream_dump_test.py --bendkv 6380 --redis 6390 [--seed 1] [--corrupt 2000]
"""
import argparse
import random
import struct
import sys
import time

from diff_test import Conn
from dump_test import cmd, crc64, flat, run

bad = 0
n = 0
stricter = 0


def fail(what, x, y):
    global bad
    bad += 1
    if bad <= 30:
        print("FAIL: %s: BendKV %s, Redis %s" % (str(what)[:200], str(x)[:300], str(y)[:300]))


def check(what, x, y):
    global n
    n += 1
    if x != y:
        fail(what, x, y)


def both(b, r, c):
    return run(b, c), run(r, c)


def pipe(c, cmds, step=1000):
    out = []
    for i in range(0, len(cmds), step):
        c.send(cmds[i:i + step])
        out += [c.reply() for _ in cmds[i:i + step]]
    return out


# Shapes
# ------
# Each shape is its name, the node limits Redis makes it at (entries,
# bytes), and the commands that make it at key s.

U64 = 2 ** 64 - 1


def ints():
    return ["0", "1", "127", "128", "-1", "-128", "4095", "4096", "-4096", "-4097", "32767", "32768",
            "-32768", "-32769", "8388607", "8388608", "-8388608", "-8388609", "2147483647", "2147483648",
            "-2147483648", "-2147483649", "9223372036854775807", "-9223372036854775808",
            "9223372036854775808", "18446744073709551615", "007", "-0", "+1", " 1", "1 ", "0x10", "1e3"]


def shapes(rnd):
    out = []

    def add(name, cmds, ent=100, byt=4096):
        out.append((name, ent, byt, cmds))

    def xadd(i, *fv):
        return cmd("XADD", "s", i, *fv)

    add("an empty stream, made by XGROUP CREATE MKSTREAM", [cmd("XGROUP", "CREATE", "s", "g", "$", "MKSTREAM")])
    add("an empty stream, its entry deleted", [xadd("1-1", "f", "v"), cmd("XDEL", "s", "1-1")])
    add("one entry, at the time", [xadd("*", "f", "v")])
    add("entries of the master's fields", [xadd("1-%d" % i, "a", str(i), "b", "x" * i) for i in range(1, 12)])
    add("entries of fields of their own", [xadd("2-%d" % i, *(["a", "1", "b", "2"] if i % 3 else ["c", "3"] * (1 + i % 2)))
                                           for i in range(1, 20)])
    vs = ints()
    add("integers and numbers' texts as fields and values",
        [xadd("3-%d" % i, v, v, "x", v) for i, v in enumerate(vs, 1)] + [xadd("3-100", *[w for v in vs for w in (v + "f", v)])])
    add("values of 0, 63, 64, 4,095, 4,096 and 70,000 bytes",
        [xadd("4-%d" % i, "f", "y" * k) for i, k in enumerate((0, 1, 63, 64, 4095, 4096, 70000), 1)])
    add("1,000 entries, 10 nodes", [xadd("5-%d" % i, "f", str(i), "g", "v") for i in range(1000)])
    add("nodes split by their bytes", [xadd("6-%d" % i, "f", "z" * (300 + i)) for i in range(60)])
    add("nodes of one entry", [xadd("7-%d" % i, "f", str(i)) for i in range(30)], 1, 0)
    add("nodes of 3 entries and 100 bytes", [xadd("8-%d" % i, "f", str(i) * (i % 7)) for i in range(90)], 3, 100)
    add("nodes of no limit", [xadd("9-%d" % i, "f", str(i)) for i in range(500)], 0, 0)
    dels = [cmd("XDEL", "s", "10-0"), cmd("XDEL", "s", "10-299"), cmd("XDEL", "s", "10-5", "10-7", "10-150")]
    dels += [cmd("XDEL", "s", *["10-%d" % i for i in range(100, 200)])]
    add("entries deleted: the first, the last, some, all of a node's",
        [xadd("10-%d" % i, "f", str(i)) for i in range(300)] + dels)
    add("trimmed by MAXLEN, exactly", [xadd("11-%d" % i, "f", str(i)) for i in range(250)] + [cmd("XTRIM", "s", "MAXLEN", "=", 130)])
    add("trimmed by MAXLEN ~ and LIMIT", [xadd("12-%d" % i, "f", str(i)) for i in range(450)] +
        [cmd("XTRIM", "s", "MAXLEN", "~", 220), cmd("XTRIM", "s", "MAXLEN", "~", 10, "LIMIT", 100)])
    add("trimmed by MINID", [xadd("13-%d" % i, "f", str(i)) for i in range(300)] + [cmd("XTRIM", "s", "MINID", "13-155")])
    add("a node with no live entry, and an entry after it below its master ID",
        [xadd("14-1", "a", "1"), xadd("14-2", "a", "2"), xadd("14-3", "a", "3"), cmd("XDEL", "s", "14-3"),
         cmd("XTRIM", "s", "MINID", "14-3")])
    add("an entry added below a node's master ID",
        [xadd("14-1", "a", "1"), xadd("14-2", "a", "2"), xadd("14-3", "a", "3"), cmd("XDEL", "s", "14-3"),
         cmd("XTRIM", "s", "MINID", "14-3"), cmd("XSETID", "s", "0-1"), xadd("0-2", "a", "4"), xadd("0-3", "b", "5")])
    add("an entry added after a deleted one with a greater ID",
        [xadd("15-1", "a", "1"), xadd("15-9", "a", "2"), cmd("XDEL", "s", "15-9"), cmd("XSETID", "s", "15-2"),
         xadd("15-3", "a", "3")])
    add("IDs near 2^64", [xadd("%d-%d" % (U64 - 1, U64 - 1), "f", "1"), xadd("%d-0" % U64, "f", "2"),
                          xadd("%d-%d" % (U64, U64 - 1), "f", "3"), xadd("%d-%d" % (U64, U64), "f", "4")])
    add("sequences that go down from the master's",
        [xadd("16-100", "f", "1"), xadd("17-0", "f", "2"), xadd("17-5", "f", "3"), xadd("%d-%d" % (2 ** 63, 2 ** 63), "f", "4"),
         xadd("%d-1" % (2 ** 63 + 1), "f", "5")])
    add("XSETID's last ID, ENTRIESADDED and MAXDELETEDID",
        [xadd("18-1", "f", "1"), xadd("18-2", "f", "2"), cmd("XDEL", "s", "18-1"),
         cmd("XSETID", "s", "100-5", "ENTRIESADDED", 1000, "MAXDELETEDID", "50-7")])
    add("ENTRIESADDED of 2^63 - 1", [xadd("19-1", "f", "1"), cmd("XSETID", "s", "%d-%d" % (U64, U64), "ENTRIESADDED", 2 ** 63 - 1)])
    t = int(time.time() * 1000)
    grp = [xadd("20-%d" % i, "f", str(i)) for i in range(1, 40)]
    grp += [cmd("XGROUP", "CREATE", "s", "g1", "0"), cmd("XGROUP", "CREATE", "s", "g2", "$"),
            cmd("XGROUP", "CREATE", "s", "123", "20-5", "ENTRIESREAD", 5), cmd("XGROUP", "CREATE", "s", "", "20-7"),
            cmd("XGROUP", "CREATE", "s", "-7", "0", "ENTRIESREAD", 9223372036854775807),
            cmd("XREADGROUP", "GROUP", "g1", "alice", "COUNT", 5, "STREAMS", "s", ">"),
            cmd("XREADGROUP", "GROUP", "g1", "bob", "COUNT", 3, "STREAMS", "s", ">"),
            cmd("XREADGROUP", "GROUP", "g1", "42", "COUNT", 2, "STREAMS", "s", ">"),
            cmd("XREADGROUP", "GROUP", "g1", "", "COUNT", 2, "STREAMS", "s", ">"),
            cmd("XACK", "s", "g1", "20-2", "20-7"),
            cmd("XCLAIM", "s", "g1", "carol", 0, "20-3", "20-4", "RETRYCOUNT", 2 ** 63 - 1, "TIME", t - 5000),
            cmd("XCLAIM", "s", "g1", "alice", 0, "20-6", "FORCE", "JUSTID"),
            cmd("XGROUP", "CREATECONSUMER", "s", "g1", "dave"), cmd("XGROUP", "CREATECONSUMER", "s", "g2", "erin"),
            cmd("XREADGROUP", "GROUP", "123", "frank", "STREAMS", "s", ">"),
            cmd("XREADGROUP", "GROUP", "123", "frank", "NOACK", "STREAMS", "s", ">"),
            cmd("XGROUP", "SETID", "s", "g2", "20-3", "ENTRIESREAD", -1),
            cmd("XDEL", "s", "20-3", "20-11")]
    add("groups: entries delivered, claimed, acknowledged; consumers with none pending", grp)
    add("groups of a stream with no entry", [cmd("XGROUP", "CREATE", "s", "g", "$", "MKSTREAM"), cmd("XGROUP", "CREATE", "s", "h", "5-5"),
                                            cmd("XGROUP", "CREATECONSUMER", "s", "g", "c")])
    many = [xadd("21-%d" % i, "f", str(i % 100)) for i in range(400)]
    many += [cmd("XGROUP", "CREATE", "s", "g%d" % i, "21-%d" % (i * 7)) for i in range(30)]
    many += [cmd("XREADGROUP", "GROUP", "g%d" % (i % 30), "c%d" % i, "COUNT", 3 + i % 4, "STREAMS", "s", ">") for i in range(120)]
    add("30 groups of 120 consumers", many)
    add("a node of more than 65,535 elements", [xadd("22-%d" % i, "f", str(i % 9)) for i in range(14000)], 0, 0)
    return out


def big_shape():
    return ("a stream of 100,000 entries, with a group", 100, 4096,
            [cmd("XADD", "s", "*", "field", "v%d" % i, "n", str(i)) for i in range(100000)] +
            [cmd("XGROUP", "CREATE", "s", "g", "0"),
             cmd("XREADGROUP", "GROUP", "g", "c", "COUNT", 5000, "STREAMS", "s", ">")])


def make(r, shape):
    name, ent, byt, cmds = shape
    run(r, cmd("CONFIG", "SET", "stream-node-max-entries", ent))
    run(r, cmd("CONFIG", "SET", "stream-node-max-bytes", byt))
    run(r, cmd("DEL", "s"))
    for c, x in zip(cmds, pipe(r, cmds)):
        if x[0] in (b"-", b"!"):
            fail("Redis makes the shape '%s': %s" % (name, b" ".join(c)[:120]), "", x)
    return run(r, cmd("DUMP", "s"))[1]


# Type 15: a payload of 19 without what 15 lacks

def rd_len(p, i):
    x = p[i]
    if x >> 6 == 0:
        return x & 63, i + 1
    if x >> 6 == 1:
        return ((x & 63) << 8) | p[i + 1], i + 2
    if x == 0x80:
        return struct.unpack(">I", p[i + 1:i + 5])[0], i + 5
    if x == 0x81:
        return struct.unpack(">Q", p[i + 1:i + 9])[0], i + 9
    raise ValueError("no length at %d" % i)


def str_end(p, i):
    x = p[i]
    if x >> 6 == 3:
        k = x & 63
        if k < 3:
            return i + 1 + (1, 2, 4)[k]
        c, j = rd_len(p, i + 1)
        u, j = rd_len(p, j)
        return j + c
    k, j = rd_len(p, i)
    return j + k


def to15(p):
    assert p[0] == 19
    out = bytearray([15])
    st = {"i": 1}

    def length(keep=True):
        v, j = rd_len(p, st["i"])
        if keep:
            out.extend(p[st["i"]:j])
        st["i"] = j
        return v

    def string():
        j = str_end(p, st["i"])
        out.extend(p[st["i"]:j])
        st["i"] = j

    def raw(k):
        out.extend(p[st["i"]:st["i"] + k])
        st["i"] += k
    for _ in range(length()):
        string()
        string()
    for _ in range(3):
        length()
    for _ in range(5):
        length(False)
    for _ in range(length()):
        string()
        length()
        length()
        length(False)
        for _ in range(length()):
            raw(16)
            raw(8)
            length()
        for _ in range(length()):
            string()
            raw(8)
            raw(16 * length())
    assert len(p) - st["i"] == 10, (len(p), st["i"])
    body = bytes(out) + b"\x09\x00"
    return body + struct.pack("<Q", crc64(body))


def fix(body):
    body = bytes(body) + b"\x0a\x00"
    return body + struct.pack("<Q", crc64(body))


# The checks
# ----------

WRONG = [cmd("GET", "g"), cmd("LPUSH", "g", "x"), cmd("HGET", "g", "f"), cmd("SADD", "g", "m"),
         cmd("ZADD", "g", 1, "m"), cmd("PFADD", "g", "x"), cmd("SORT", "g"), cmd("APPEND", "g", "x"),
         cmd("INCR", "g"), cmd("SMEMBERS", "g"), cmd("LRANGE", "g", 0, -1), cmd("GETRANGE", "g", 0, 1),
         cmd("SETRANGE", "g", 0, "x"), cmd("BITCOUNT", "g"), cmd("GEOADD", "g", 1, 1, "m"), cmd("HSCAN", "g", 0)]


def generic(b, r, name, p):
    """the generic commands on a stream restored from p on both"""
    check(name + ": RESTORE on both", both(b, r, cmd("RESTORE", "g", 0, p, "REPLACE")), ((b"+", b"OK"), (b"+", b"OK")))
    for c in (cmd("SCAN", 0, "TYPE", "stream", "COUNT", 1000), cmd("SCAN", 0, "TYPE", "string", "COUNT", 1000)):
        x, y = both(b, r, c)
        check(name + ": " + b" ".join(c).decode(), sorted(flat(x)), sorted(flat(y)))
    for c in [cmd("TYPE", "g"), cmd("OBJECT", "ENCODING", "g"), cmd("EXISTS", "g"), cmd("COPY", "g", "g2"), cmd("RENAME", "g2", "g3"),
              cmd("EXPIRE", "g3", 1000), cmd("TTL", "g3"), cmd("PERSIST", "g3"), cmd("COPY", "g", "g3")] + WRONG:
        x, y = both(b, r, c)
        check(name + ": " + b" ".join(c).decode(errors="replace"), x, y)
    x, y = both(b, r, cmd("DUMP", "g3"))
    check(name + ": DUMP of the copy", x, y)
    check(name + ": the copy's payload", x, (b"$", p))
    m = run(b, cmd("MEMORY", "USAGE", "g"))
    check(name + ": MEMORY USAGE is a count", m[0], b":")
    both(b, r, cmd("DEL", "g", "g3"))


def shape_checks(b, r, shape):
    name = shape[0]
    p = make(r, shape)
    if p is None:
        fail(name + ": Redis DUMPs it", "", None)
        return None
    x = run(b, cmd("RESTORE", "s", 0, p, "REPLACE"))
    check(name + ": RESTORE of Redis's payload", x, (b"+", b"OK"))
    x = run(b, cmd("DUMP", "s"))
    check(name + ": BendKV's DUMP of it, byte for byte", x, (b"$", p))
    generic(b, r, name, p)
    q = to15(p)
    x, y = both(b, r, cmd("RESTORE", "o", 0, q, "REPLACE"))
    check(name + ": RESTORE of type 15", x, y)
    x, y = both(b, r, cmd("DUMP", "o"))
    check(name + ": DUMP of type 15, byte for byte", x, y)
    both(b, r, cmd("DEL", "s", "o"))
    return p


def broken(b, r, rnd, ps, k):
    """payloads changed at random, their checksums right"""
    global stricter
    took = 0
    for _ in range(k):
        name, p = rnd.choice(ps)
        x = bytearray(p[:-10])
        m = rnd.random()
        i = rnd.randrange(1, len(x))
        if m < 0.5:
            x[i] = rnd.getrandbits(8)
        elif m < 0.65:
            x[i] ^= 1 << rnd.randrange(8)
        elif m < 0.75:
            del x[i]
        elif m < 0.85:
            x[i:i] = bytes([rnd.getrandbits(8)])
        elif m < 0.95:
            x = x[:i]
        else:
            ext = rnd.choice([b"\xff" * 8, b"\x81\xff\xff\xff\xff\xff\xff\xff\xff", b"\x80\xff\xff\xff\xff", b"\x00"])
            x[i:i + len(ext)] = ext
        q = fix(x)
        xb, xr = both(b, r, cmd("RESTORE", "k", 0, q, "REPLACE"))
        ok_b, ok_r = xb == (b"+", b"OK"), xr == (b"+", b"OK")
        what = "broken " + name + ": RESTORE " + q.hex()[:60]
        if not ok_r:
            check(what, xb, xr)
        elif not ok_b:
            stricter += 1
            check(what + " (BendKV's refusal)", xb, (b"-", b"ERR Bad data format"))
        else:
            took += 1
            check(what + ": DUMP", run(b, cmd("DUMP", "k")), run(r, cmd("DUMP", "k")))
        both(b, r, cmd("DEL", "k"))
    return took


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, default=6380)
    ap.add_argument("--redis", type=int, default=6390)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--corrupt", type=int, default=2000)
    a = ap.parse_args()
    rnd = random.Random(a.seed)
    b, r = Conn(a.bendkv, False), Conn(a.redis, False)
    conf = {}
    for k in ("rdbcompression", "sanitize-dump-payload", "stream-node-max-entries", "stream-node-max-bytes"):
        conf[k] = flat(run(r, cmd("CONFIG", "GET", k)))[1]
    run(r, cmd("CONFIG", "SET", "rdbcompression", "no"))
    run(r, cmd("CONFIG", "SET", "sanitize-dump-payload", "yes"))
    try:
        both(b, r, cmd("FLUSHALL"))
        ps = []
        for shape in shapes(rnd):
            p = shape_checks(b, r, shape)
            if p is not None and len(p) < 200000:
                ps.append((shape[0], p))
        t = time.time()
        shape_checks(b, r, big_shape())
        print("the stream of 100,000 entries: %.1f s" % (time.time() - t))
        took = broken(b, r, rnd, ps, a.corrupt)
        print("broken payloads: %d taken by both, %d refused by BendKV alone" % (took, stricter))
        both(b, r, cmd("FLUSHALL"))
    finally:
        for k, v in conf.items():
            run(r, cmd("CONFIG", "SET", k, v))
    print("stream dump: %d checks, %d differ" % (n, bad))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
