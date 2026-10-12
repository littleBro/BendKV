#!/usr/bin/env python3
"""Restart test for the append-only file: a random command stream (the
differential test's, which moves between databases, moves keys between
them and swaps them) against BendKV, with one FLUSHALL halfway, then the
whole keyspace of each of the 16 databases saved, each key with its
value and the time it expires at; after the server restarts from its
file, every database must read back the same.

    python3 tests/aof_test.py --port 6380 --write build/aof_dump.txt --rounds 1000
    (restart BendKV with the same file)
    python3 tests/aof_test.py --port 6380 --check build/aof_dump.txt
"""
import argparse
import random
import sys

from diff_test import NOW_S, Conn, rnd_cmd


def keyspace(c, dbs=16):
    out = []
    for db in range(dbs):
        c.send([[b"SELECT", b"%d" % db], [b"KEYS", b"*"]])
        c.reply()
        kind, items = c.reply()
        keys = sorted(data for kind, data in items)
        vals = []
        times = []
        if keys:
            c.send([[b"MGET"] + keys])
            kind, vals = c.reply()
            c.send([[b"PEXPIRETIME", k] for k in keys])
            times = [c.reply()[1] for k in keys]
        out += [(db, k.hex(), v[1].hex(), t.decode()) for k, v, t in zip(keys, vals, times)]
    return out


def show(ks):
    return "\n".join("%d %s %s %s" % kv for kv in ks) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=6380)
    ap.add_argument("--rounds", type=int, default=1000)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--keys", type=int, default=20000)
    ap.add_argument("--write")
    ap.add_argument("--check")
    a = ap.parse_args()
    c = Conn(a.port)
    if a.write:
        r = random.Random(a.seed)
        n = 0
        for i in range(a.rounds):
            # FLUSHALL now and then would leave little to restore: one,
            # halfway, which the keys before it must not survive
            batch = [x for x in (rnd_cmd(r) for _ in range(r.choice([1, 1, 2, 5, 20])))
                     if x[0] != b"FLUSHALL"]
            if i == a.rounds // 2:
                batch.append([b"FLUSHALL"])
            c.send(batch)
            for _ in batch:
                c.reply()
            n += len(batch)
        # and many keys, so that the trie is deep: SETs and MSETs of
        # random bytes, 100 to a batch; a key in 5 with a time to expire
        # at, and then times changed, taken away, or in the past (which
        # deletes the key)
        for i in range(0, a.keys, 100):
            batch = [[b"SET", b"key:%d" % j, bytes(r.randrange(256) for _ in range(r.randint(0, 40)))] +
                     ([b"EX", b"%d" % r.randint(1000, 10**6)] if j % 5 == 0 else [])
                     for j in range(i, min(i + 100, a.keys))]
            batch.append([b"MSET", b"m:%d" % i, b"x" * r.randint(0, 9), b"m:%d:2" % i, b"%d" % i])
            batch.append([b"PEXPIREAT", b"key:%d" % (i + 3), b"%d" % (NOW_S * 1000 + r.randint(10**6, 10**9))])
            batch.append([b"EXPIRE", b"key:%d" % (i + 10), b"%d" % r.randint(10**6, 10**7), b"GT"])
            batch.append([b"PERSIST", b"key:%d" % (i + 20)])
            batch.append([b"EXPIREAT", b"key:%d" % (i + 7), b"%d" % r.randint(1, 10**6)])
            batch.append([b"GETEX", b"m:%d" % i, b"PX", b"%d" % r.randint(10**6, 10**9)])
            c.send(batch)
            for _ in batch:
                c.reply()
            n += len(batch)
        ks = keyspace(c)
        open(a.write, "w").write(show(ks))
        print("OK: %d commands, %d keys saved" % (n, len(ks)))
    if a.check:
        want = open(a.check).read()
        got = show(keyspace(c))
        if got != want:
            print("MISMATCH: the restored keyspace differs")
            print("  restored: %d keys, saved: %d keys" % (got.count("\n"), want.count("\n")))
            sys.exit(1)
        print("OK: the restored keyspace is the saved one (%d keys)" % got.count("\n"))


if __name__ == "__main__":
    main()
