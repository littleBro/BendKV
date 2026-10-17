#!/usr/bin/env python3
"""DUMP and RESTORE against Redis. Redis runs with rdbcompression no (BendKV
writes no LZF) and sanitize-dump-payload yes (BendKV checks every payload
as deep as Redis does then); both are set back after.

- Values of every kind and encoding, made on both servers by the same
  commands: DUMP's payloads compared byte for byte where both servers
  hold the value the same way (a string, a list pushed at its last end, a
  hash or a sorted set in a listpack, an intset, a sorted set in a skip
  list); every payload restored on both servers, each server's on the
  other, and Redis's compressed ones (LZF) on BendKV, the values read
  back with their encodings and compared.
- RESTORE's options and errors, in the order Redis checks them, its
  times (relative, ABSTTL, past, 0, LLONG_MAX), REPLACE over each kind,
  in RESP2 and RESP3.
- Payloads of encodings Redis no longer writes (ziplists, zipmaps,
  quicklists of ziplists, lists and sorted sets of type 1 and 3), then
  payloads cut, grown and changed at random (their checksum made right):
  each restored on both, the replies and the values compared.
- The keyspace events of RESTORE, IDLETIME and FREQ under LRU and LFU
  policies (OBJECT IDLETIME and FREQ), in MULTI, on a key there and on
  keys deleted and made again, WATCH, COMMAND GETKEYS and INFO's
  statistics of both commands, and big values.

    python3 tests/dump_test.py --bendkv 6380 --redis 6390 [--seed 1] [--corrupt 1500]
"""
import argparse
import os
import random
import struct
import sys
import time

from diff_test import Conn

bad = 0
n = 0


def run(c, xs):
    c.send([xs])
    return c.reply()


def cmd(*xs):
    return [x if isinstance(x, bytes) else str(x).encode() for x in xs]


def fail(what, x, y):
    global bad
    bad += 1
    if bad <= 30:
        print("FAIL: %s: BendKV %s, Redis %s" % (str(what)[:200], str(x)[:300], str(y)[:300]))


def same(b, r, c):
    global n
    n += 1
    x, y = run(b, c), run(r, c)
    if x != y:
        fail(b" ".join(c)[:200], x, y)
    return x, y


def both(b, r, c):
    return run(b, c), run(r, c)


def flat(rep):
    """the bytes of a reply's items, a nested reply's in turn"""
    kind, v = rep
    if isinstance(v, list):
        out = []
        for x in v:
            out += flat(x)
        return out
    return [v]


# a key's value as a server holds it: its type, its encoding, and its
# value (a hash's pairs and a set's members sorted, as the servers walk
# their tables in orders of their own; a sorted set's pairs as ZRANGE
# gives them, or sorted, loose)
def content(c, k, loose=False):
    t = run(c, cmd("TYPE", k))[1]
    enc = run(c, cmd("OBJECT", "ENCODING", k))
    if t == b"string":
        v = run(c, cmd("GET", k))
    elif t == b"list":
        v = flat(run(c, cmd("LRANGE", k, 0, -1)))
    elif t == b"hash":
        xs = flat(run(c, cmd("HGETALL", k)))
        v = sorted(zip(xs[0::2], xs[1::2]))
    elif t == b"set":
        v = sorted(flat(run(c, cmd("SMEMBERS", k))))
    elif t == b"zset":
        xs = flat(run(c, cmd("ZRANGE", k, 0, -1, "WITHSCORES")))
        v = list(zip(xs[0::2], xs[1::2]))
        if loose:
            v = sorted(v)
    else:
        v = None
    return (t, enc, v)


def unenc(c):
    return (c[0], c[2])


def check_same(what, x, y):
    global n
    n += 1
    if x != y:
        fail(what, x, y)


# Values
# ------

def cases(rnd):
    def rb(k):
        return bytes(rnd.getrandbits(8) for _ in range(k))
    out = []

    def add(name, canon, cmds):
        out.append((name, canon, cmds))
    for v in [b"", b"bar", b"123", b"-129", b"0", b"-0", b"01", b"2147483647", b"-2147483648",
              b"2147483648", b"12345678901", b"-1234567890", b"9223372036854775807",
              b"-9223372036854775808", b"9223372036854775808", b"1e5", b" 1", b"abc" * 30,
              b"x" * 44, b"x" * 45, rb(300), rb(20000)]:
        add("string %r" % v[:12], True, [cmd("SET", "k", v)])
    els = ["1", "-1", "0", "127", "128", "-4096", "4095", "4096", "-4097", "-32768", "32767", "32768",
           "8388607", "-8388608", "8388608", "2147483647", "-2147483648", "2147483648",
           "9223372036854775807", "-9223372036854775808", "9223372036854775808", "abc", "01", "-0",
           "x" * 63, "x" * 64, "y" * 4095, "z" * 4096, ""]
    add("list of every entry", True, [cmd("RPUSH", "k", *els)])
    add("list small", True, [cmd("RPUSH", "k", "a", "b", "c")])
    add("list 3000", True, [cmd("RPUSH", "k", *["e%d" % i for i in range(3000)])])
    add("list of big elements", True, [cmd("RPUSH", "k", *[rb(rnd.choice([10, 3000, 9000])) for i in range(8)])])
    add("list pushed first", False, [cmd("LPUSH", "k", *["e%d" % i for i in range(2000)])])
    add("list trimmed", False, [cmd("RPUSH", "k", *["e%d" % i for i in range(500)]), cmd("LTRIM", "k", 7, 300)])
    add("hash small", True, [cmd("HSET", "k", "f1", "v1", "f2", "123", "n", "-5", "big", "9223372036854775807")])
    add("hash at its limits", True, [cmd("HSET", "k", *[x for i in range(512) for x in ("f%d" % i, "v" * 64)])])
    add("hash of a long value", False, [cmd("HSET", "k", "f", "v" * 65, "g", "1")])
    add("hash 600", False, [cmd("HSET", "k", *[x for i in range(600) for x in ("f%d" % i, "v%d" % i)])])
    add("hash shrunk", False, [cmd("HSET", "k", *[x for i in range(600) for x in ("f%d" % i, "v%d" % i)]),
                               cmd("HDEL", "k", *["f%d" % i for i in range(590)])])
    add("hash with a field deleted", True, [cmd("HSET", "k", "a", "1", "b", "2", "c", "3"), cmd("HDEL", "k", "b")])
    add("set of small integers", True, [cmd("SADD", "k", "1", "2", "3", "-5")])
    add("set of 32-bit integers", True, [cmd("SADD", "k", "1", "100000", "-70000")])
    add("set of 64-bit integers", True, [cmd("SADD", "k", "1", "9223372036854775807", "-9223372036854775808", "5000000000")])
    add("set of 512 integers", True, [cmd("SADD", "k", *[str(i * 7) for i in range(512)])])
    add("set of 513 integers", False, [cmd("SADD", "k", *[str(i * 7) for i in range(513)])])
    add("set of strings", False, [cmd("SADD", "k", "a", "b", "1")])
    add("set shrunk from 64 bits", True, [cmd("SADD", "k", "1", "2", "5000000000"), cmd("SREM", "k", "5000000000")])
    add("set grown from 16 to 32 bits, a negative", True, [cmd("SADD", "k", "1", "-2", "300"), cmd("SADD", "k", "-70000")])
    add("set grown from 16 to 64 bits, a positive", True, [cmd("SADD", "k", "1", "-2", "300"), cmd("SADD", "k", "9223372036854775807")])
    add("set of 512 integers of 64 bits", True, [cmd("SADD", "k", *[str(i * 36028797018963 - 9223372036854775808) for i in range(512)])])
    add("set of 512 integers emptied but one", True, [cmd("SADD", "k", *[str(i * 1000003 - 256000000) for i in range(512)]),
                                                      cmd("SREM", "k", *[str(i * 1000003 - 256000000) for i in range(511)])])
    add("set of 10 strings", False, [cmd("SADD", "k", *["m%07d" % i for i in range(10)])])
    add("set of 128 strings of 64 bytes", False, [cmd("SADD", "k", *[("m%07d" % i) * 8 for i in range(128)])])
    add("set of 129 strings", False, [cmd("SADD", "k", *["m%07d" % i for i in range(129)])])
    add("set of a 65-byte member", False, [cmd("SADD", "k", "a", "x" * 65, "1")])
    add("set of 127 integers and a string", False, [cmd("SADD", "k", *[str(i) for i in range(127)]), cmd("SADD", "k", "s")])
    add("set of 128 integers and a string", False, [cmd("SADD", "k", *[str(i) for i in range(128)]), cmd("SADD", "k", "s")])
    add("set of strings with members taken out", False, [cmd("SADD", "k", *["m%07d" % i for i in range(50)]),
                                                         cmd("SREM", "k", *["m%07d" % i for i in range(0, 50, 3)])])
    add("set of the bytes of members", False, [cmd("SADD", "k", b"", b"\x00", b"\xff", b"\r\n", b"\x00" * 64)])
    add("sorted set small", True, [cmd("ZADD", "k", "1", "a", "1.5", "b", "-2", "c", "inf", "d", "-inf", "e", "-0", "f",
                                       "9007199254740993", "g", "4611686018427387904", "h", "4611686018427387905", "i",
                                       "1e300", "j", "0.1", "k", "123", "12", "5e-324", "l", "-1.7976931348623157e308", "m")])
    add("sorted set at its limits", True, [cmd("ZADD", "k", *[x for i in range(128) for x in (str(i), "m" * 63 + "%03d" % i)])])
    add("sorted set 200", True, [cmd("ZADD", "k", *[x for i in range(200) for x in (repr(rnd.uniform(-1e6, 1e6)), "m%d" % i)])])
    add("sorted set of a long member", True, [cmd("ZADD", "k", "1", "x" * 65, "-0", "z", "2", "y")])
    add("sorted set with ties", True, [cmd("ZADD", "k", *[x for i in range(300) for x in (str(i % 3), "t%d" % i)])])
    add("sorted set changed", True, [cmd("ZADD", "k", "1", "a", "2", "b", "3", "c"), cmd("ZINCRBY", "k", "5", "a"),
                                     cmd("ZREM", "k", "b")])
    return out


def build(c, cmds):
    run(c, cmd("DEL", "k"))
    for x in cmds:
        rep = run(c, x)
        if rep[0] == b"-":
            raise SystemExit("dump_test.py: %r answered %r" % (x[:3], rep))


def values(b, r, rnd):
    for name, canon, cmds in cases(rnd):
        build(b, cmds)
        build(r, cmds)
        cb, cr = content(b, b"k"), content(r, b"k")
        check_same(name + ": the value made", cb, cr)
        pb, pr = run(b, cmd("DUMP", "k")), run(r, cmd("DUMP", "k"))
        if canon:
            check_same(name + ": DUMP", pb, pr)
        # each server's payload restored on each
        for src, p in (("BendKV's", pb[1]), ("Redis's", pr[1])):
            xb = run(b, cmd("RESTORE", "x", 0, p, "REPLACE"))
            xr = run(r, cmd("RESTORE", "x", 0, p, "REPLACE"))
            check_same("%s: RESTORE of %s payload" % (name, src), xb, xr)
            check_same("%s: the value of %s payload" % (name, src), content(b, b"x"), content(r, b"x"))
            # (its encoding may be another than the value's: Redis makes
            # one from a payload by its own rules)
            check_same("%s: %s payload holds the value" % (name, src), unenc(content(r, b"x")), unenc(cr))
        # Redis's payload compressed (LZF), restored on both
        run(r, cmd("CONFIG", "SET", "rdbcompression", "yes"))
        pz = run(r, cmd("DUMP", "k"))
        run(r, cmd("CONFIG", "SET", "rdbcompression", "no"))
        same(b, r, cmd("RESTORE", "z", 0, pz[1], "REPLACE"))
        check_same(name + ": the value of a compressed payload", content(b, b"z"), content(r, b"z"))
        both(b, r, cmd("DEL", "k", "x", "z"))


# RESTORE
# -------

def restores(b, r):
    both(b, r, cmd("FLUSHALL"))
    both(b, r, cmd("SET", "s", "hello"))
    both(b, r, cmd("RPUSH", "l", "a", "b"))
    p = run(r, cmd("DUMP", "s"))[1]
    pl = run(r, cmd("DUMP", "l"))[1]
    same(b, r, cmd("DUMP", "nokey"))
    same(b, r, cmd("DUMP", "s"))
    same(b, r, cmd("DUMP"))
    same(b, r, cmd("DUMP", "s", "x"))
    for c in [cmd("RESTORE"), cmd("RESTORE", "k"), cmd("RESTORE", "k", "0"),
              cmd("RESTORE", "k", 0, p), cmd("GET", "k"), cmd("RESTORE", "k", 0, p),
              cmd("RESTORE", "k", 0, p, "REPLACE"), cmd("RESTORE", "k", 0, p, "replace"),
              cmd("RESTORE", "k", 0, pl, "REPLACE"), cmd("TYPE", "k"), cmd("LRANGE", "k", 0, -1),
              cmd("RESTORE", "k", "abc", p), cmd("RESTORE", "k2", "abc", p), cmd("RESTORE", "k2", "-5", p),
              cmd("RESTORE", "k2", "-0", p), cmd("RESTORE", "k2", "+5", p), cmd("RESTORE", "k2", " 5", p),
              cmd("RESTORE", "k2", "05", p), cmd("RESTORE", "k2", "1.5", p),
              cmd("RESTORE", "k2", "99999999999999999999", p), cmd("RESTORE", "k2", "-9223372036854775808", p),
              cmd("RESTORE", "k2", 0, "garbage"), cmd("RESTORE", "k2", 0, ""), cmd("RESTORE", "k2", 0, p[:-1]),
              cmd("RESTORE", "k2", 0, p + b"x"), cmd("RESTORE", "k2", 0, b"\x00" * 10), cmd("GET", "k2"),
              cmd("RESTORE", "k2", 0, b"\x00" * 10, "REPLACE"), cmd("DEL", "k2"),
              cmd("RESTORE", "k", 0, "garbage"), cmd("RESTORE", "k", "x", "garbage", "BOGUS"),
              cmd("RESTORE", "k3", 0, p, "IDLETIME"), cmd("RESTORE", "k3", 0, p, "IDLETIME", "-1"),
              cmd("RESTORE", "k3", 0, p, "IDLETIME", "x"), cmd("RESTORE", "k3", 0, p, "FREQ"),
              cmd("RESTORE", "k3", 0, p, "FREQ", "256"), cmd("RESTORE", "k3", 0, p, "FREQ", "-1"),
              cmd("RESTORE", "k3", 0, p, "FREQ", "x"), cmd("RESTORE", "k3", 0, p, "FREQ", "3", "IDLETIME", "5"),
              cmd("RESTORE", "k3", 0, p, "IDLETIME", "5", "FREQ", "3"), cmd("RESTORE", "k3", 0, p, "BOGUS"),
              cmd("RESTORE", "k3", 0, p, "REPLACE", "BOGUS"), cmd("RESTORE", "k3", 0, p, "IDLETIME", "1", "IDLETIME", "2"),
              cmd("RESTORE", "k3", 0, p, "FREQ", "1", "FREQ", "2", "REPLACE"), cmd("GET", "k3"),
              cmd("RESTORE", "s", "x", p, "FREQ", "300"), cmd("RESTORE", "s", "x", p, "IDLETIME"),
              cmd("RESTORE", "k4", 1, p, "ABSTTL"), cmd("EXISTS", "k4"), cmd("RESTORE", "k4", 1, p, "absttl", "REPLACE"),
              cmd("RESTORE", "s", 1, p, "ABSTTL", "REPLACE"), cmd("EXISTS", "s"),
              cmd("RESTORE", "k5", "9223372036854775807", p, "ABSTTL"), cmd("EXISTS", "k5"),
              cmd("RESTORE", "k6", "4102444800000", p, "ABSTTL"), cmd("PEXPIRETIME", "k6"),
              cmd("RESTORE", "l", "0", p, "REPLACE"), cmd("TYPE", "l"),
              cmd("RESTORE", "k7", 0, p, "ABSTTL"), cmd("TTL", "k7")]:
        same(b, r, c)
    # a time to live that the clock's time added to overflows 64 bits: 7.0.15
    # takes the sum for a time past and makes no key, 7.2.16 makes a key that
    # lives until its cycle of expiries comes (docs/UPSTREAM.md, bug 4), so
    # BendKV is held to 7.0.15's replies
    for c, want in ((cmd("RESTORE", "k8", "9223372036854775807", p), (b"+", b"OK")),
                    (cmd("EXISTS", "k8"), (b":", b"0"))):
        check_same(b" ".join(c)[:200], run(b, c), want)
    # relative times, read within a second
    for t in ("100000", "1"):
        x, y = both(b, r, cmd("RESTORE", "t" + t, t, p))
        check_same("RESTORE with a time of " + t, x, y)
        x, y = both(b, r, cmd("PTTL", "t" + t))
        if abs(int(x[1]) - int(y[1])) > 1000:
            fail("PTTL after RESTORE " + t, x, y)
    time.sleep(0.05)
    same(b, r, cmd("EXISTS", "t1"))
    # a key of each kind replaced
    for k, mk in (("h", cmd("HSET", "h", "f", "v")), ("st", cmd("SADD", "st", "1")), ("z", cmd("ZADD", "z", "1", "a"))):
        both(b, r, mk)
        same(b, r, cmd("RESTORE", k, 0, p))
        same(b, r, cmd("RESTORE", k, 0, p, "REPLACE"))
        same(b, r, cmd("GET", k))
    # a key with a time replaced by one without
    both(b, r, cmd("SET", "e", "v", "EX", "1000"))
    same(b, r, cmd("RESTORE", "e", 0, pl, "REPLACE"))
    same(b, r, cmd("TTL", "e"))
    # REPLACE with a time already past deletes the key
    same(b, r, cmd("RESTORE", "e", 1, p, "ABSTTL", "REPLACE"))
    same(b, r, cmd("EXISTS", "e"))


# Old encodings and broken payloads
# ---------------------------------

POLY = 0x95ac9329ac4bc9b5
CRC = []
for i in range(256):
    c = i
    for _ in range(8):
        c = (c >> 1) ^ (POLY if c & 1 else 0)
    CRC.append(c)


def crc64(bs):
    c = 0
    for x in bs:
        c = CRC[(c ^ x) & 0xff] ^ (c >> 8)
    return c


def payload(body):
    body = body + b"\x0b\x00"
    return body + struct.pack("<Q", crc64(body))


def rlen(k):
    if k < 64:
        return bytes([k])
    if k < 16384:
        return bytes([0x40 | (k >> 8), k & 0xff])
    return b"\x80" + struct.pack(">I", k)


def rstr(s):
    return rlen(len(s)) + s


def canon_int(s):
    try:
        v = int(s)
    except ValueError:
        return None
    if str(v).encode() != s or not (-2 ** 63 <= v < 2 ** 63):
        return None
    return v


def zl_entry(prevlen, s):
    pl = bytes([prevlen]) if prevlen < 254 else b"\xfe" + struct.pack("<I", prevlen)
    v = canon_int(s)
    if v is not None:
        if 0 <= v <= 12:
            enc = bytes([0xf1 + v])
        elif -128 <= v < 128:
            enc = b"\xfe" + struct.pack("<b", v)
        elif -2 ** 15 <= v < 2 ** 15:
            enc = b"\xc0" + struct.pack("<h", v)
        elif -2 ** 23 <= v < 2 ** 23:
            enc = b"\xf0" + struct.pack("<i", v)[:3]
        elif -2 ** 31 <= v < 2 ** 31:
            enc = b"\xd0" + struct.pack("<i", v)
        else:
            enc = b"\xe0" + struct.pack("<q", v)
    else:
        k = len(s)
        if k < 64:
            enc = bytes([k]) + s
        elif k < 16384:
            enc = bytes([0x40 | (k >> 8), k & 0xff]) + s
        else:
            enc = b"\x80" + struct.pack(">I", k) + s
    return pl + enc


def ziplist(els):
    body = b""
    prev = 0
    tail = 10
    for e in els:
        ent = zl_entry(prev, e)
        tail = 10 + len(body)
        body += ent
        prev = len(ent)
    total = 10 + len(body) + 1
    return struct.pack("<IIH", total, tail if els else 10, min(len(els), 65535)) + body + b"\xff"


def zipmap(rnd, pairs):
    out = bytes([min(len(pairs), 254)])

    def zl(k):
        return bytes([k]) if k < 254 else b"\xfe" + struct.pack("<I", k)
    for f, v in pairs:
        free = rnd.choice([0, 0, 1, 3])
        out += zl(len(f)) + f + zl(len(v)) + bytes([free]) + v + b"\x00" * free
    return out + b"\xff"


def mixed(rnd, k):
    out = []
    for _ in range(k):
        x = rnd.random()
        if x < 0.3:
            out.append(str(rnd.randint(-20, 20)).encode())
        elif x < 0.5:
            out.append(str(rnd.choice([1, -1]) * rnd.randint(0, 2 ** rnd.randint(1, 63))).encode())
        elif x < 0.6:
            out.append(b"x" * rnd.choice([0, 1, 63, 64, 300, 16383, 16384]))
        else:
            out.append(bytes(rnd.getrandbits(8) for _ in range(rnd.randint(0, 20))))
    return out


def uniq(xs):
    seen = set()
    out = []
    for x in xs:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out


def old_bodies(rnd):
    out = []
    for _ in range(6):
        els = mixed(rnd, rnd.randint(1, 30))
        out.append(("a list in a ziplist", b"\x0a" + rstr(ziplist(els))))
        out.append(("a list of type 1", b"\x01" + rlen(len(els)) + b"".join(rstr(e) for e in els)))
        nodes = [mixed(rnd, rnd.randint(0, 5)) for _ in range(rnd.randint(1, 4))]
        out.append(("a quicklist of ziplists", b"\x0e" + rlen(len(nodes)) + b"".join(rstr(ziplist(x)) for x in nodes)))
        fs = uniq(mixed(rnd, rnd.randint(1, 20)))
        pairs = list(zip(fs, mixed(rnd, len(fs))))
        out.append(("a hash in a ziplist", b"\x0d" + rstr(ziplist([x for p in pairs for x in p]))))
        out.append(("a hash in a zipmap", b"\x09" + rstr(zipmap(rnd, pairs))))
        out.append(("a hash of type 4", b"\x04" + rlen(len(pairs)) + b"".join(rstr(f) + rstr(v) for f, v in pairs)))
        ms = uniq(mixed(rnd, rnd.randint(1, 20)))
        out.append(("a set of type 2", b"\x02" + rlen(len(ms)) + b"".join(rstr(m) for m in ms)))
        sc = [rnd.choice(["1", "-2.5", "0", "inf", "-inf", "3.1415899999999999", "1.0000000000000001e+300",
                          "123456789012", "-0"]) for _ in ms]
        zs = sorted(zip(ms, sc), key=lambda q: (float(q[1]), q[0]))
        out.append(("a sorted set in a ziplist", b"\x0c" + rstr(ziplist([x for m, s in zs for x in (m, s.encode())]))))

        def dtext(s):
            if s == "inf":
                return b"\xfe"
            if s == "-inf":
                return b"\xff"
            return rstr(s.encode())
        out.append(("a sorted set of type 3", b"\x03" + rlen(len(zs)) + b"".join(rstr(m) + dtext(s) for m, s in zs)))
    out.append(("a hash of 600 in a ziplist", b"\x0d" + rstr(ziplist([x for i in range(600) for x in (b"f%d" % i, b"v%d" % i)]))))
    out.append(("a sorted set of 200 in a ziplist", b"\x0c" + rstr(ziplist([x for i in range(200) for x in (b"m%d" % i, b"%d" % i)]))))
    out.append(("a hash of a long value in a zipmap", b"\x09" + rstr(zipmap(rnd, [(b"f", b"v" * 100), (b"g", b"1")]))))
    return out


def new_bodies(r, rnd):
    out = []
    for comp in ("no", "yes"):
        run(r, cmd("CONFIG", "SET", "rdbcompression", comp))
        for c in (cmd("RPUSH", "m", *mixed(rnd, rnd.randint(1, 40))),
                  cmd("HSET", "m", *[x for i in range(rnd.randint(1, 20)) for x in (b"f%d" % i, rnd.choice(mixed(rnd, 3)))]),
                  cmd("SADD", "m", *[str(rnd.randint(-10 ** rnd.randint(1, 18), 10 ** rnd.randint(1, 18))) for i in range(rnd.randint(1, 20))]),
                  cmd("SADD", "m", *[b"s%d" % i for i in range(rnd.randint(1, 20))]),
                  cmd("ZADD", "m", *[x for i in range(rnd.randint(1, 20)) for x in (repr(rnd.uniform(-100, 100)), "m%d" % i)]),
                  cmd("SET", "m", b"abc" * rnd.randint(1, 50)),
                  cmd("ZADD", "m", *[x for i in range(200) for x in (repr(rnd.uniform(-100, 100)), "m%d" % i)])):
            run(r, cmd("DEL", "m"))
            run(r, c)
            out.append(("a payload of " + c[0].decode(), run(r, cmd("DUMP", "m"))[1][:-10]))
    run(r, cmd("CONFIG", "SET", "rdbcompression", "no"))
    run(r, cmd("DEL", "m"))
    return out


def restore_both(b, r, name, p, loose):
    xb, xr = both(b, r, cmd("RESTORE", "kk", 0, p, "REPLACE"))
    check_same(name + ": RESTORE " + p.hex()[:80], xb, xr)
    if xb == (b"+", b"OK") and xr == (b"+", b"OK"):
        check_same(name + ": the value of " + p.hex()[:80], content(b, b"kk", loose), content(r, b"kk", loose))


def payloads(b, r, rnd, ncorrupt):
    bodies = old_bodies(rnd) + new_bodies(r, rnd)
    for name, body in bodies:
        restore_both(b, r, name, payload(body), False)
    # each body with the bytes from each of its first 16 on overwritten
    # by numbers at their extremes, so that the lengths, counts and widths
    # of its headers pass 2^32 and 2^48 (an intset of width 0x03000008 and
    # 0x27000000 values made BendKV's product of the two pass a Nat's
    # 2^48, and the server stop)
    for name, body in bodies:
        for i in range(1, min(16, len(body))):
            for ext in (b"\xff" * 8, b"\xff\xff\xff\xff", b"\x08\x00\x00\x03\x00\x00\x00\x27", b"\x81\xff\xff"):
                x = body[:i] + ext + body[i + len(ext):]
                restore_both(b, r, "extreme " + name, payload(x), True)
    # broken payloads, their checksums right: Redis accepts a sorted set
    # in a listpack out of order, which BendKV keeps sorted, so sorted sets
    # are compared as sets of pairs
    for _ in range(ncorrupt):
        name, body = rnd.choice(bodies)
        x = bytearray(body)
        k = rnd.random()
        i = rnd.randrange(len(x))
        if k < 0.6:
            x[i] = rnd.getrandbits(8)
        elif k < 0.8:
            del x[i]
        else:
            x[i:i] = bytes([rnd.getrandbits(8)])
        restore_both(b, r, "broken " + name, payload(bytes(x)), True)
    # versions and checksums
    p = payload(b"\x00\x03abc")
    for q in (p[:-10] + b"\x0c\x00" + p[-8:], p[:-10] + b"\x09\x00" + struct.pack("<Q", crc64(p[:-10] + b"\x09\x00")),
              p[:-10] + b"\x0a\x00" + struct.pack("<Q", crc64(p[:-10] + b"\x0a\x00")),
              p[:-10] + b"\x0c\x00" + struct.pack("<Q", crc64(p[:-10] + b"\x0c\x00")),
              p[:-1] + bytes([p[-1] ^ 1]), p + b"\x00", b"\x00" * 10, b"\x00" * 9, p[:-10] + b"\x00\x01" + struct.pack("<Q", crc64(p[:-10] + b"\x00\x01"))):
        restore_both(b, r, "a payload's version or checksum", q, False)
    for t in (6, 7, 15, 19, 20, 21, 22, 255):
        restore_both(b, r, "a payload of type %d" % t, payload(bytes([t]) + b"\x00"), False)


# Keyspace events, access, transactions, statistics, big values
# --------------------------------------------------------------

def events(b, r):
    bs, rs = Conn(b.port, False), Conn(r.port, False)
    both(b, r, cmd("CONFIG", "SET", "notify-keyspace-events", "KEA"))
    for s in (bs, rs):
        s.send([cmd("PSUBSCRIBE", "*")])
        s.reply()

    def got(s):
        out = []
        while True:
            m = s.reply()
            items = [v for _, v in m[1]]
            if items[0] == b"pmessage" and items[2] == b"mark":
                return out
            out.append(tuple(items[2:]))

    def ev(c):
        global n
        n += 1
        x, y = run(b, c), run(r, c)
        run(b, cmd("PUBLISH", "mark", "m"))
        run(r, cmd("PUBLISH", "mark", "m"))
        ex, ey = got(bs), got(rs)
        if (x, ex) != (y, ey):
            fail(c[:3], (x, ex), (y, ey))

    both(b, r, cmd("DEL", "e1", "e2"))
    both(b, r, cmd("SET", "src", "v"))
    p = run(r, cmd("DUMP", "src"))[1]
    ev(cmd("RESTORE", "e1", 0, p))
    ev(cmd("RESTORE", "e1", 0, p))
    ev(cmd("RESTORE", "e1", 0, p, "REPLACE"))
    ev(cmd("RESTORE", "e1", 100000, p, "REPLACE"))
    ev(cmd("RESTORE", "e1", 1, p, "ABSTTL", "REPLACE"))
    ev(cmd("RESTORE", "e2", 1, p, "ABSTTL", "REPLACE"))
    ev(cmd("RESTORE", "e2", 1, p, "ABSTTL"))
    ev(cmd("RESTORE", "e2", 0, "bad"))
    ev(cmd("RESTORE", "e2", 0, p, "IDLETIME", "10"))
    ev(cmd("RESTORE", "e2", 0, p, "REPLACE", "FREQ", "10"))
    ev(cmd("DUMP", "e2"))
    both(b, r, cmd("CONFIG", "SET", "notify-keyspace-events", ""))
    for s in (bs, rs):
        s.sock.close()


def access(b, r):
    # keys of names new to the server, which no earlier run left there
    tag = os.urandom(4).hex()
    both(b, r, cmd("SET", "src", "v"))
    p = run(r, cmd("DUMP", "src"))[1]

    def near(what, x, y, d):
        global n
        n += 1
        if x[0] != y[0] or (x[0] == b":" and abs(int(x[1]) - int(y[1])) > d) or (x[0] != b":" and x != y):
            fail(what, x, y)
    both(b, r, cmd("CONFIG", "SET", "maxmemory-policy", "allkeys-lru"))
    for i, opts in enumerate((["IDLETIME", "1000"], ["IDLETIME", "0"], ["IDLETIME", "16777215"],
                              ["IDLETIME", "16777216"], ["IDLETIME", "100000000"], ["IDLETIME", "1000000000000"],
                              ["IDLETIME", "9223372036854775"], ["FREQ", "100"], [])):
        k = "lru%d.%s" % (i, tag)
        same(b, r, cmd("RESTORE", k, 0, p, *opts))
        near("OBJECT IDLETIME after RESTORE %s" % opts, *both(b, r, cmd("OBJECT", "IDLETIME", k)), 2)
        same(b, r, cmd("OBJECT", "FREQ", k))
    # a RESTORE that fails leaves the key's time of use as it was
    both(b, r, cmd("SET", "there", "v"))
    same(b, r, cmd("RESTORE", "there", 0, p, "IDLETIME", "5000"))
    near("OBJECT IDLETIME after BUSYKEY", *both(b, r, cmd("OBJECT", "IDLETIME", "there")), 2)
    # in a transaction
    for c in (cmd("MULTI"), cmd("RESTORE", "inmulti", 0, p, "IDLETIME", "700"), cmd("EXEC")):
        same(b, r, c)
    near("OBJECT IDLETIME after RESTORE in MULTI", *both(b, r, cmd("OBJECT", "IDLETIME", "inmulti")), 2)
    # each key RESTORE makes under an LFU policy below was there before,
    # and a word of use outlives its key in BendKV (keys whose hashes have
    # the same low twenty bits share one, which no delete clears): RESTORE
    # makes its key anew, with a counter of 5 unless FREQ says otherwise,
    # as Redis makes a new value, whatever word it finds
    for i in range(5):
        k = "lfu%d.%s" % (i, tag)
        both(b, r, cmd("SET", k, "v"))
        both(b, r, cmd("DEL", k))
    both(b, r, cmd("CONFIG", "SET", "maxmemory-policy", "allkeys-lfu"))
    for i, opts in enumerate((["FREQ", "100"], ["FREQ", "0"], ["FREQ", "255"], ["IDLETIME", "1000"], [])):
        k = "lfu%d.%s" % (i, tag)
        same(b, r, cmd("RESTORE", k, 0, p, *opts))
        same(b, r, cmd("OBJECT", "FREQ", k))
        same(b, r, cmd("OBJECT", "IDLETIME", k))
    both(b, r, cmd("CONFIG", "SET", "maxmemory-policy", "noeviction"))


def watch(b, r):
    both(b, r, cmd("SET", "src", "v"))
    p = run(r, cmd("DUMP", "src"))[1]
    b2, r2 = Conn(b.port, False), Conn(r.port, False)
    for k, opts in (("w1", []), ("w2", ["IDLETIME", "5"]), ("w3", ["REPLACE"])):
        both(b, r, cmd("WATCH", k))
        both(b, r, cmd("MULTI"))
        both(b, r, cmd("GET", k))
        same(b2, r2, cmd("RESTORE", k, 0, p, *opts))
        same(b, r, cmd("EXEC"))
    both(b, r, cmd("SET", "w4", "x"))
    both(b, r, cmd("WATCH", "w4"))
    both(b, r, cmd("MULTI"))
    both(b, r, cmd("GET", "w4"))
    same(b2, r2, cmd("RESTORE", "w4", 0, p))
    same(b, r, cmd("EXEC"))
    b2.sock.close()
    r2.sock.close()


def getkeys_stats(b, r):
    both(b, r, cmd("SET", "src", "v"))
    p = run(r, cmd("DUMP", "src"))[1]
    for c in (cmd("COMMAND", "GETKEYS", "DUMP", "a"), cmd("COMMAND", "GETKEYS", "RESTORE", "a", 0, p),
              cmd("COMMAND", "GETKEYS", "RESTORE", "a", 0, p, "REPLACE", "IDLETIME", "5")):
        same(b, r, c)
    both(b, r, cmd("CONFIG", "RESETSTAT"))
    for c in (cmd("DUMP", "src"), cmd("DUMP", "none"), cmd("DUMP"), cmd("RESTORE", "st", 0, p),
              cmd("RESTORE", "st", 0, p), cmd("RESTORE", "st", 0, "bad", "REPLACE"), cmd("RESTORE", "st2", "x", p),
              cmd("RESTORE", "st2", 0, p, "FREQ", "500"), cmd("RESTORE", "st2", 0, p, "IDLETIME", "3"),
              cmd("RESTORE", "st3")):
        same(b, r, c)
    x, y = both(b, r, cmd("INFO", "commandstats"))
    pick = lambda rep: sorted(l.split(b"usec=")[0] + b"|" + l.split(b"rejected_calls=")[1]
                              for l in rep[1].split(b"\r\n") if l.startswith((b"cmdstat_dump", b"cmdstat_restore")))
    check_same("INFO commandstats of DUMP and RESTORE", pick(x), pick(y))
    x, y = both(b, r, cmd("INFO", "errorstats"))
    errs = lambda rep: sorted(l for l in rep[1].split(b"\r\n") if l.startswith(b"errorstat_"))
    check_same("INFO errorstats", errs(x), errs(y))


def big(b, r, rnd):
    for name, cmds, canon in (
            ("a string of 5 MB", [cmd("SET", "big", bytes(rnd.getrandbits(8) for _ in range(5 << 20)))], True),
            ("a list of 100,000", [cmd("RPUSH", "big", *["e%d" % i for i in range(100000)])], True),
            ("a hash of 20,000", [cmd("HSET", "big", *[x for i in range(20000) for x in ("f%d" % i, "v%d" % i)])], False),
            ("a set of 20,000 integers", [cmd("SADD", "big", *[str(i * 3) for i in range(20000)])], False),
            ("a sorted set of 20,000", [cmd("ZADD", "big", *[x for i in range(20000) for x in (repr(rnd.uniform(-1e9, 1e9)), "m%d" % i)])], True)):
        for c in (b, r):
            run(c, cmd("DEL", "big"))
            for x in cmds:
                run(c, x)
        pb, pr = both(b, r, cmd("DUMP", "big"))
        if canon:
            check_same(name + ": DUMP", len(pb[1] or b""), len(pr[1] or b""))
            check_same(name + ": DUMP", pb == pr, True)
        cr = content(r, b"big")
        for src, p in (("BendKV's", pb[1]), ("Redis's", pr[1])):
            check_same(name + ": RESTORE of " + src, both(b, r, cmd("RESTORE", "big2", 0, p, "REPLACE")), ((b"+", b"OK"), (b"+", b"OK")))
            check_same(name + ": the value of " + src, content(b, b"big2"), content(r, b"big2"))
            check_same(name + ": the value kept", content(r, b"big2"), cr)
        both(b, r, cmd("DEL", "big", "big2"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, default=6380)
    ap.add_argument("--redis", type=int, default=6390)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--corrupt", type=int, default=1500)
    a = ap.parse_args()
    rnd = random.Random(a.seed)
    b, r = Conn(a.bendkv, False), Conn(a.redis, False)
    b.port, r.port = a.bendkv, a.redis
    conf = {}
    for k in ("rdbcompression", "sanitize-dump-payload"):
        conf[k] = flat(run(r, cmd("CONFIG", "GET", k)))[1]
    run(r, cmd("CONFIG", "SET", "rdbcompression", "no"))
    run(r, cmd("CONFIG", "SET", "sanitize-dump-payload", "yes"))
    try:
        both(b, r, cmd("FLUSHALL"))
        values(b, r, rnd)
        restores(b, r)
        payloads(b, r, rnd, a.corrupt)
        events(b, r)
        access(b, r)
        watch(b, r)
        getkeys_stats(b, r)
        big(b, r, rnd)
        b3, r3 = Conn(a.bendkv, True), Conn(a.redis, True)
        b3.port, r3.port = a.bendkv, a.redis
        restores(b3, r3)
        both(b, r, cmd("FLUSHALL"))
    finally:
        for k, v in conf.items():
            run(r, cmd("CONFIG", "SET", k, v))
    print("dump: %d checks, %d differ" % (n, bad))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
