#!/usr/bin/env python3
"""The writes of a stream against Redis 7.0.15: XADD, XTRIM, XDEL and
XSETID. Both servers run the same writes, in RESP2 and in RESP3, each
reply compared whole, and after each write the stream's DUMP payload is
compared byte for byte (its nodes, their listpacks, the header and the
groups, as Redis makes them), with its XINFO STREAM.

- Random runs on a few keys: XADD with an ID, with <ms>-*, and with * on
  a stream whose last ID is past the clock (both servers then add the
  same ID); fields and values of every encoding, a node's master fields
  or others; values up to 5,000 bytes (a node full by its size) and
  runs of more than 100 entries (full by its count); MAXLEN and MINID
  with =, ~, LIMIT, NOMKSTREAM; XTRIM likewise; XDEL of IDs there,
  deleted and not there; XSETID with ENTRIESADDED and MAXDELETEDID.
- The errors, in the order Redis meets them.
- The keyspace events of class t, WATCH (XSETID touches no key), MULTI.

    python3 tests/stream_write_test.py --bendkv 6380 --redis 6390 [--seed 1] [--rounds 3000]
"""
import argparse
import random
import sys

from diff_test import Conn
from dump_test import cmd, flat, run
from stream_dump_test import pipe

bad = 0
n = 0
U64 = 2 ** 64 - 1
# a time past the clock, so that * and <ms>-* give both servers one ID
BASE = 10 ** 15


def fail(what, x, y):
    global bad
    bad += 1
    if bad <= 40:
        print("FAIL: %s: BendKV %s, Redis %s" % (str(what)[:300], str(x)[:600], str(y)[:600]))


def batch(b, r, cmds):
    global n
    xs, ys = pipe(b, cmds), pipe(r, cmds)
    for c, x, y in zip(cmds, xs, ys):
        n += 1
        if x != y:
            fail(b" ".join(c)[:200], x, y)
    return ys


def same_dump(b, r, k, why):
    global n
    n += 1
    x, y = run(b, cmd("DUMP", k)), run(r, cmd("DUMP", k))
    if x != y:
        fail("DUMP %s after %s" % (k, why), x, y)
        return False
    n += 1
    x, y = run(b, cmd("XINFO", "STREAM", k)), run(r, cmd("XINFO", "STREAM", k))
    if x != y and y[0] != b"-":
        fail("XINFO STREAM %s after %s" % (k, why), x, y)
    return True


# The stream as Redis holds it: its live IDs and its last ID
# ---------------------------------------------------------

def live_ids(r, k):
    rep = run(r, cmd("XRANGE", k, "-", "+"))
    if rep[0] != b"*" or not rep[1]:
        return []
    return [e[1][0][1].decode() for e in rep[1]]


def last_id(r, k):
    rep = run(r, cmd("XINFO", "STREAM", k))
    if rep[0] not in (b"*", b"%") or not rep[1]:
        return None
    kv = rep[1]
    for i in range(0, len(kv) - 1, 2):
        if kv[i][1] == b"last-generated-id":
            return kv[i + 1][1].decode()
    return None


def parts(i):
    ms, sq = i.split("-")
    return int(ms), int(sq)


# Random writes
# -------------

FIELDS = [["f"], ["f", "g"], ["g", "f"], ["f", "g", "h"], ["a"], ["0"], ["123"], ["-7"],
          ["x" * 70], ["f", "f"], [""], ["9223372036854775807"]]
SMALL = ["", "v", "0", "1", "127", "128", "-1", "4095", "4096", "-4097", "32768", "8388608",
         "2147483648", "9223372036854775807", "-9223372036854775808", "18446744073709551615",
         "007", "+1", " 1", "1e3", "abc"]


def rnd_value(rnd, big):
    x = rnd.random()
    if big and x < 0.3:
        return "v" * rnd.choice([500, 1000, 2000, 3000, 4000, 5000])
    if x < 0.6:
        return rnd.choice(SMALL)
    return "w" * rnd.randint(0, 80)


def rnd_fv(rnd, big):
    fs = rnd.choice(FIELDS)
    if rnd.random() < 0.1:
        fs = ["k%d" % rnd.randint(0, 5) for _ in range(rnd.randint(1, 4))]
    out = []
    for f in fs:
        out += [f, rnd_value(rnd, big)]
    return out


def rnd_after(rnd, last):
    if last is None:
        return "%d-%d" % (BASE, rnd.randint(0, 3))
    ms, sq = parts(last)
    x = rnd.random()
    if x < 0.4:
        return "%d-%d" % (ms, sq + 1) if sq < U64 else "%d-0" % (ms + 1)
    if x < 0.6:
        return "%d-%d" % (ms + rnd.randint(1, 3), rnd.randint(0, 5))
    if x < 0.7:
        return "%d-*" % (ms + rnd.randint(0, 2))
    if x < 0.8:
        return "*"
    if x < 0.85:
        return "%d" % (ms + rnd.randint(0, 2))
    if x < 0.9:
        return "%d-%d" % (ms, max(0, sq - 1))
    return "%d-*" % max(0, ms - 1)


def rnd_trim(rnd, n, ids, xadd):
    x = rnd.random()
    if xadd and x < 0.55:
        return []
    out = []
    if rnd.random() < 0.6:
        out += ["MAXLEN"]
        thr = str(max(0, n + rnd.randint(-120, 20)))
    else:
        out += ["MINID"]
        thr = rnd.choice(ids) if ids and rnd.random() < 0.7 else "%d-%d" % (BASE + rnd.randint(0, 40), rnd.randint(0, 3))
    op = rnd.choice(["", "=", "~", "~", "~"])
    if op:
        out += [op]
    out += [thr]
    if op == "~" and rnd.random() < 0.4:
        out += ["LIMIT", str(rnd.choice([0, 1, 50, 99, 100, 101, 150, 1000]))]
    return out


def rnd_xadd(rnd, r, k, big):
    ids = live_ids(r, k)
    last = last_id(r, k)
    opts = []
    if rnd.random() < 0.1:
        opts += ["NOMKSTREAM"]
    opts += rnd_trim(rnd, len(ids), ids, True)
    return cmd("XADD", k, *(opts + [rnd_after(rnd, last)] + rnd_fv(rnd, big)))


def rnd_xtrim(rnd, r, k):
    ids = live_ids(r, k)
    t = rnd_trim(rnd, len(ids), ids, False) or ["MAXLEN", str(max(0, len(ids) - 5))]
    return cmd("XTRIM", k, *t)


def rnd_xdel(rnd, r, k):
    ids = live_ids(r, k)
    out = []
    for _ in range(rnd.randint(1, 4)):
        if ids and rnd.random() < 0.8:
            out.append(rnd.choice(ids))
        else:
            out.append("%d-%d" % (BASE + rnd.randint(0, 40), rnd.randint(0, 5)))
    return cmd("XDEL", k, *out)


def rnd_xsetid(rnd, r, k):
    ids = live_ids(r, k)
    last = last_id(r, k)
    top = parts(ids[-1]) if ids else (parts(last) if last else (BASE, 0))
    ms, sq = top
    x = rnd.random()
    if x < 0.5:
        i = "%d-%d" % (ms + rnd.randint(0, 3), sq + rnd.randint(0, 3))
    elif x < 0.7:
        i = "%d-%d" % (ms, sq)
    elif x < 0.85:
        i = "%d-%d" % (ms, max(0, sq - 1))
    else:
        i = "%d-%d" % (ms + 100, 0)
    out = [i]
    if rnd.random() < 0.4:
        out += ["ENTRIESADDED", str(max(0, len(ids) + rnd.randint(-2, 50)))]
    if rnd.random() < 0.3:
        ims, isq = parts(i)
        out += ["MAXDELETEDID", "%d-%d" % (max(0, ims - rnd.randint(0, 3)), isq)]
    return cmd("XSETID", k, *out)


def rnd_round(rnd, b, r, keys):
    k = rnd.choice(keys)
    x = rnd.random()
    if x < 0.55:
        c = rnd_xadd(rnd, r, k, rnd.random() < 0.2)
    elif x < 0.67:
        c = rnd_xtrim(rnd, r, k)
    elif x < 0.85:
        c = rnd_xdel(rnd, r, k)
    elif x < 0.93:
        c = rnd_xsetid(rnd, r, k)
    elif x < 0.95:
        c = cmd("DEL", k)
    else:
        burst(rnd, b, r, k)
        return
    batch(b, r, [c])
    same_dump(b, r, k, b" ".join(c)[:120].decode(errors="replace"))


# a run of XADDs to one key: past a node's 100 entries, or with values
# that fill its 4096 bytes
def burst(rnd, b, r, k):
    big = rnd.random() < 0.5
    cs = [] if last_id(r, k) else [cmd("XADD", k, "%d-0" % BASE, "f", "v")]
    for i in range(rnd.randint(90, 230)):
        fv = ["f", rnd_value(rnd, big)] if rnd.random() < 0.8 else rnd_fv(rnd, big)
        cs.append(cmd("XADD", k, "*", *fv))
    batch(b, r, cs)
    same_dump(b, r, k, "a run of XADD")


# Errors
# ------

def errors(b, r):
    batch(b, r, [cmd("DEL", "e", "es", "em"), cmd("SET", "es", "x"),
                 cmd("XADD", "e", "%d-1" % BASE, "f", "v")])
    cs = [
        cmd("XADD", "e"), cmd("XADD", "e", "*"), cmd("XADD", "e", "*", "f"),
        cmd("XADD", "e", "*", "f", "v", "g"), cmd("XADD", "e", "0-0", "f", "v"),
        cmd("XADD", "e", "0", "f", "v"), cmd("XADD", "e", "0-*", "f", "v"),
        cmd("XADD", "e", "bad", "f", "v"), cmd("XADD", "e", "-", "f", "v"),
        cmd("XADD", "e", "+", "f", "v"), cmd("XADD", "e", "1-x", "f", "v"),
        cmd("XADD", "e", "1-2-3", "f", "v"), cmd("XADD", "e", "-*", "f", "v"),
        cmd("XADD", "e", "%d-0" % BASE, "f", "v"), cmd("XADD", "e", "%d-1" % BASE, "f", "v"),
        cmd("XADD", "e", "%d-*" % (BASE - 1), "f", "v"), cmd("XADD", "e", "MAXLEN", "f", "v"),
        cmd("XADD", "em", "%d-18446744073709551615" % BASE, "f", "v"),
        cmd("XADD", "em", "%d-*" % BASE, "f", "v"), cmd("XADD", "em", "*", "f", "v"),
        cmd("XADD", "e", "MAXLEN", "-1", "*", "f", "v"), cmd("XADD", "e", "MAXLEN", "x", "*", "f", "v"),
        cmd("XADD", "e", "MAXLEN", "~", "*", "f", "v"), cmd("XADD", "e", "MAXLEN", "=", "*", "f", "v"),
        cmd("XADD", "e", "MAXLEN", "1", "MINID", "1", "*", "f", "v"),
        cmd("XADD", "e", "MAXLEN", "1", "MAXLEN", "1", "*", "f", "v"),
        cmd("XADD", "e", "MINID", "bad", "*", "f", "v"), cmd("XADD", "e", "MINID", "-", "*", "f", "v"),
        cmd("XADD", "e", "LIMIT", "5", "*", "f", "v"), cmd("XADD", "e", "LIMIT", "0", "*", "f", "v"),
        cmd("XADD", "e", "MAXLEN", "5", "LIMIT", "5", "*", "f", "v"),
        cmd("XADD", "e", "MAXLEN", "=", "5", "LIMIT", "5", "*", "f", "v"),
        cmd("XADD", "e", "MAXLEN", "~", "5", "LIMIT", "-1", "*", "f", "v"),
        cmd("XADD", "e", "MAXLEN", "~", "5", "LIMIT", "x", "*", "f", "v"),
        cmd("XADD", "e", "LIMIT", "5", "MAXLEN", "~", "5", "*", "f", "v"),
        cmd("XADD", "e", "NOMKSTREAM", "NOMKSTREAM", "*", "f", "v"),
        cmd("XADD", "e", "nomkstream", "maxlen", "~", "0", "limit", "0", "*", "f", "v"),
        cmd("XADD", "e", "MAXLEN", "1", "LIMIT"),
        cmd("XADD", "missing", "NOMKSTREAM", "*", "f", "v"),
        cmd("XADD", "es", "*", "f", "v"), cmd("XADD", "es", "bad", "f", "v"),
        cmd("XADD", "es", "NOMKSTREAM", "*", "f", "v"),
        cmd("XTRIM", "e"), cmd("XTRIM", "e", "MAXLEN"), cmd("XTRIM", "e", "x", "1"),
        cmd("XTRIM", "e", "MAXLEN", "-1"), cmd("XTRIM", "e", "MAXLEN", "1", "x"),
        cmd("XTRIM", "e", "LIMIT", "5"), cmd("XTRIM", "e", "LIMIT", "0", "MAXLEN", "1"),
        cmd("XTRIM", "e", "MAXLEN", "1", "LIMIT", "1"), cmd("XTRIM", "e", "MINID", "x"),
        cmd("XTRIM", "e", "MAXLEN", "~"), cmd("XTRIM", "missing", "MAXLEN", "0"),
        cmd("XTRIM", "es", "MAXLEN", "0"), cmd("XTRIM", "es", "MAXLEN", "x"),
        cmd("XDEL", "e"), cmd("XDEL", "e", "bad"), cmd("XDEL", "e", "%d-1" % BASE, "bad"),
        cmd("XDEL", "e", "-"), cmd("XDEL", "missing", "bad"), cmd("XDEL", "es", "bad"),
        cmd("XDEL", "e", "1-1"),
        cmd("XSETID", "e"), cmd("XSETID", "e", "bad"), cmd("XSETID", "e", "-"),
        cmd("XSETID", "e", "%d-5" % BASE, "ENTRIESADDED"),
        cmd("XSETID", "e", "%d-5" % BASE, "ENTRIESADDED", "-1"),
        cmd("XSETID", "e", "%d-5" % BASE, "ENTRIESADDED", "x"),
        cmd("XSETID", "e", "%d-5" % BASE, "MAXDELETEDID", "bad"),
        cmd("XSETID", "e", "%d-5" % BASE, "MAXDELETEDID", "%d-6" % BASE),
        cmd("XSETID", "e", "%d-5" % BASE, "FOO", "1"),
        cmd("XSETID", "e", "%d-0" % BASE), cmd("XSETID", "e", "%d-5" % BASE, "ENTRIESADDED", "0"),
        cmd("XSETID", "missing", "1-1"), cmd("XSETID", "missing", "bad"),
        cmd("XSETID", "es", "1-1"), cmd("XSETID", "es", "1-1", "FOO"),
        cmd("XSETID", "e", "%d-5" % BASE, "ENTRIESADDED", "3", "MAXDELETEDID", "%d-1" % BASE),
        cmd("XSETID", "e", "%d-4" % BASE),
        cmd("XDEL", "e", "%d-1" % BASE),
        cmd("XSETID", "e", "%d-0" % BASE),
        cmd("XADD", "e", "%d-1" % BASE, "f", "v"),
    ]
    batch(b, r, cs)
    same_dump(b, r, "e", "the errors")
    # the stream's last possible ID
    batch(b, r, [cmd("XSETID", "e", "%d-%d" % (U64, U64)), cmd("XADD", "e", "*", "f", "v"),
                 cmd("XADD", "e", "%d-%d" % (U64, U64), "f", "v"), cmd("XADD", "e", "5-*", "f", "v"),
                 cmd("DEL", "e"), cmd("XADD", "e", "%d-%d" % (U64, U64 - 1), "f", "v"),
                 cmd("XADD", "e", "%d-*" % U64, "f", "v"), cmd("XADD", "e", "*", "f", "v"),
                 cmd("DEL", "e"), cmd("XADD", "e", "%d-%d" % (U64 - 1, U64), "f", "v"),
                 cmd("XADD", "e", "*", "f", "v"), cmd("XADD", "e", "%d-*" % (U64 - 1), "f", "v")])
    same_dump(b, r, "e", "the last IDs")


# Events, WATCH and MULTI
# -----------------------

def events(port_b, port_r):
    b0, r0 = Conn(port_b, False), Conn(port_r, False)
    batch(b0, r0, [cmd("CONFIG", "SET", "notify-keyspace-events", "KEA"), cmd("DEL", "v", "vs")])
    bs, rs = Conn(port_b, False), Conn(port_r, False)
    for c in (bs, rs):
        c.send([cmd("PSUBSCRIBE", "__key*__:*", "end")])
        c.reply()
        c.reply()
    batch(b0, r0, [cmd("XADD", "v", "%d-1" % BASE, "f", "1"), cmd("XADD", "v", "MAXLEN", "1", "*", "f", "2"),
                   cmd("XADD", "v", "MAXLEN", "5", "*", "f", "3"), cmd("XTRIM", "v", "MAXLEN", "1"),
                   cmd("XTRIM", "v", "MAXLEN", "1"), cmd("XDEL", "v", "1-1"), cmd("XDEL", "v", "%d-3" % BASE),
                   cmd("XSETID", "v", "%d-9" % BASE), cmd("XADD", "v", "NOMKSTREAM", "MAXLEN", "0", "*", "f", "4"),
                   cmd("XADD", "vs", "NOMKSTREAM", "*", "f", "5"), cmd("XADD", "vs", "MAXLEN", "0", "%d-1" % BASE, "f", "5"),
                   cmd("XSETID", "vs", "%d-1" % BASE), cmd("XDEL", "vs", "%d-1" % BASE), cmd("PUBLISH", "end", "1")])
    xs, ys = [], []
    for c, out in ((bs, xs), (rs, ys)):
        while len(out) < 60:
            m = c.reply()
            out.append(m)
            if m[1] and len(m[1]) == 4 and m[1][2][1] == b"end":
                break
    global n
    n += 1
    if xs != ys:
        fail("the keyspace events", xs, ys)
    batch(b0, r0, [cmd("CONFIG", "SET", "notify-keyspace-events", "")])


def watch(port_b, port_r):
    out = []
    for port in (port_b, port_r):
        a, o = Conn(port, False), Conn(port, False)
        seq = []
        for c, x in ((a, cmd("DEL", "w")), (a, cmd("XADD", "w", "%d-1" % BASE, "f", "v")),
                     (a, cmd("WATCH", "w")), (o, cmd("XSETID", "w", "%d-5" % BASE)),
                     (a, cmd("MULTI")), (a, cmd("XLEN", "w")), (a, cmd("EXEC")),
                     (a, cmd("WATCH", "w")), (o, cmd("XADD", "w", "*", "f", "v")),
                     (a, cmd("MULTI")), (a, cmd("XLEN", "w")), (a, cmd("EXEC")),
                     (a, cmd("WATCH", "w")), (o, cmd("XDEL", "w", "1-1")), (o, cmd("XTRIM", "w", "MAXLEN", "5")),
                     (a, cmd("MULTI")), (a, cmd("XLEN", "w")), (a, cmd("EXEC")),
                     (a, cmd("WATCH", "w")), (o, cmd("XTRIM", "w", "MAXLEN", "0")),
                     (a, cmd("MULTI")), (a, cmd("XLEN", "w")), (a, cmd("EXEC")),
                     (a, cmd("MULTI")), (a, cmd("XADD", "w", "*", "f", "v")), (a, cmd("XADD", "w", "0-1", "f", "v")),
                     (a, cmd("XSETID", "w", "bad")), (a, cmd("XTRIM", "w", "MINID", "~", "0")),
                     (a, cmd("EXEC")), (a, cmd("XLEN", "w"))):
            seq.append(run(c, x))
        out.append(seq)
    global n
    n += 1
    if out[0] != out[1]:
        fail("WATCH and MULTI", out[0], out[1])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, default=6380)
    ap.add_argument("--redis", type=int, default=6390)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--rounds", type=int, default=3000)
    a = ap.parse_args()
    rnd = random.Random(a.seed)
    r0 = Conn(a.redis, False)
    conf = {}
    for k in ("rdbcompression", "stream-node-max-entries", "stream-node-max-bytes"):
        conf[k] = flat(run(r0, cmd("CONFIG", "GET", k)))[1]
    # BendKV writes no LZF, and its nodes hold Redis's default limits
    run(r0, cmd("CONFIG", "SET", "rdbcompression", "no"))
    run(r0, cmd("CONFIG", "SET", "stream-node-max-entries", "100"))
    run(r0, cmd("CONFIG", "SET", "stream-node-max-bytes", "4096"))
    try:
        for resp3 in (False, True):
            b, r = Conn(a.bendkv, resp3), Conn(a.redis, resp3)
            keys = ["s1", "s2", "s3"]
            batch(b, r, [cmd("DEL", *keys)])
            for _ in range(a.rounds // 2):
                rnd_round(rnd, b, r, keys)
            errors(b, r)
        events(a.bendkv, a.redis)
        watch(a.bendkv, a.redis)
    finally:
        for k, v in conf.items():
            run(r0, cmd("CONFIG", "SET", k, v))
    print("stream writes: %d checks, %d differ" % (n, bad))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
