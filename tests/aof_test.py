#!/usr/bin/env python3
"""Restart test for the append-only file: a random command stream (the
differential test's) against BendKV, with one FLUSHALL halfway, then the
whole keyspace saved; after the server restarts from its file (or its
shards from theirs), the keyspace must read back the same.

    python3 tests/aof_test.py --port 6380 --write build/aof_dump.txt --rounds 1000
    (restart BendKV with the same file)
    python3 tests/aof_test.py --port 6380 --check build/aof_dump.txt
"""
import argparse
import random
import sys

from diff_test import Conn, rnd_cmd


def keyspace(c):
    c.send([[b"KEYS", b"*"]])
    kind, items = c.reply()
    keys = sorted(data for kind, data in items)
    vals = []
    if keys:
        c.send([[b"MGET"] + keys])
        kind, vals = c.reply()
    return [(k.hex(), v[1].hex()) for k, v in zip(keys, vals)]


def show(ks):
    return "\n".join("%s %s" % kv for kv in ks) + "\n"


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
            # halfway, which the keys before it must not survive (with
            # shards it is a FLUSHAT entry for each digit)
            batch = [x for x in (rnd_cmd(r) for _ in range(r.choice([1, 1, 2, 5, 20])))
                     if x[0] != b"FLUSHALL"]
            if i == a.rounds // 2:
                batch.append([b"FLUSHALL"])
            c.send(batch)
            for _ in batch:
                c.reply()
            n += len(batch)
        # and many keys, so that the trie is deep: SETs and MSETs of
        # random bytes, 100 to a batch
        for i in range(0, a.keys, 100):
            batch = [[b"SET", b"key:%d" % j, bytes(r.randrange(256) for _ in range(r.randint(0, 40)))]
                     for j in range(i, min(i + 100, a.keys))]
            batch.append([b"MSET", b"m:%d" % i, b"x" * r.randint(0, 9), b"m:%d:2" % i, b"%d" % i])
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
