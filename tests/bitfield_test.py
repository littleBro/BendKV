#!/usr/bin/env python3
"""BITFIELD and BITFIELD_RO against Redis: random commands of up to six
operations on three keys (fields of every type at bit offsets below 256
or #k, values at the edges of the fields and of a long long, under each
kind of overflow), with a SETBIT, a DEL or a SET of random bytes now and
then; after each, the key's value read back, and the changes the command
counted (INFO's rdb_changes_since_last_save: as Redis 7.2.16 counts
them, each write that changed the value, or each when the value grows).
Replies, values and counts must be the same.

    python3 tests/bitfield_test.py --bendkv 6380 --redis 6390 [--rounds 3000] [--seed 1]
"""
import argparse
import random
import sys

from diff_test import Conn


def val(r, bits):
    k = r.random()
    if k < 0.3:
        return r.randint(-(1 << 63), (1 << 63) - 1)
    if k < 0.6:
        return r.randint(-(1 << bits), 1 << bits)
    return r.choice([0, 1, -1, (1 << 63) - 1, -(1 << 63), (1 << (bits - 1)) - 1, -(1 << (bits - 1)),
                     (1 << bits) - 1, 1 << bits])


def op(r):
    sign = r.random() < 0.5
    bits = r.randint(1, 64 if sign else 63)
    t = b"%s%d" % (b"i" if sign else b"u", bits)
    off = r.choice([b"%d" % r.randint(0, 200), b"%d" % r.randint(0, 40), b"#%d" % r.randint(0, 20)])
    k = r.random()
    if k < 0.3:
        return [b"GET", t, off]
    if k < 0.6:
        return [b"SET", t, off, b"%d" % val(r, bits)]
    if k < 0.9:
        return [b"INCRBY", t, off, b"%d" % val(r, bits)]
    return [b"OVERFLOW", r.choice([b"WRAP", b"SAT", b"FAIL"])]


# rdb_changes_since_last_save of INFO's reply (a bulk string, or in RESP3
# a verbatim one, after its txt:)
def changes(rep):
    info = rep[1]
    if info.startswith(b"txt:"):
        info = info[4:]
    for line in info.split(b"\r\n"):
        if line.startswith(b"rdb_changes_since_last_save:"):
            return int(line.split(b":")[1])
    raise SystemExit("FAIL: no rdb_changes_since_last_save in INFO")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, default=6380)
    ap.add_argument("--redis", type=int, default=6390)
    ap.add_argument("--rounds", type=int, default=3000)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    b, rd = Conn(a.bendkv), Conn(a.redis)
    r = random.Random(a.seed)
    for c in (b, rd):
        c.send([[b"FLUSHALL"]])
        c.reply()
    bad = 0
    last = {}
    for c in (b, rd):
        c.send([[b"INFO", b"persistence"]])
        last[c] = changes(c.reply())
    for _ in range(a.rounds):
        key = r.choice([b"bf:a", b"bf:b", b"bf:c"])
        if r.random() < 0.02:
            cmd = [b"DEL", key]
        elif r.random() < 0.05:
            cmd = [b"SET", key, bytes(r.randrange(256) for _ in range(r.randint(0, 20)))]
        elif r.random() < 0.1:
            cmd = [b"SETBIT", key, b"%d" % r.randint(0, 200), r.choice([b"0", b"1", b"1", b"0", b"2"])]
        else:
            cmd = [r.choice([b"BITFIELD"] * 5 + [b"BITFIELD_RO"]), key] + sum((op(r) for _ in range(r.randint(1, 6))), [])
        for c in (b, rd):
            c.send([cmd, [b"GET", key], [b"INFO", b"persistence"]])
        x = (b.reply(), b.reply())
        y = (rd.reply(), rd.reply())
        d = {}
        for c in (b, rd):
            n = changes(c.reply())
            d[c] = n - last[c]
            last[c] = n
        x += (d[b],)
        y += (d[rd],)
        if x != y:
            bad += 1
            if bad <= 5:
                print("FAIL: %r\n  BendKV %r\n  Redis  %r" % (b" ".join(cmd), x, y))
    for c in (b, rd):
        c.send([[b"FLUSHALL"]])
        c.reply()
    if bad:
        sys.exit("FAIL: %d of %d" % (bad, a.rounds))
    print("OK: %d BITFIELD commands, each answered as Redis answers it, each value as Redis leaves it, "
          "each counted as Redis counts it" % a.rounds)


if __name__ == "__main__":
    main()
