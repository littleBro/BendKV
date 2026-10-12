#!/usr/bin/env python3
"""Restart test for the append-only file: a random command stream (the
differential test's, which moves between databases, moves keys between
them and swaps them, and writes strings, hashes, lists and sets)
against BendKV, with one FLUSHALL halfway, then the whole keyspace of
each of the 16 databases saved, each key with its value (a hash's
pairs, a list's elements, a set's members) and the time it expires at;
after the server restarts from its file, every database must read back
the same.

    python3 tests/aof_test.py --port 6380 --write build/aof_dump.txt --rounds 1000
    (restart BendKV with the same file)
    python3 tests/aof_test.py --port 6380 --check build/aof_dump.txt
"""
import argparse
import random
import sys

from diff_test import NOW_S, Conn, rnd_cmd


# a key's value as the dump shows it: a string's bytes (MGET's), a hash's
# pairs in order of their fields, a list's elements in order, or a set's
# members in order with its encoding (MGET answers nil for a key of
# another type)
def value(c, k, v):
    if v[1] is not None:
        return v[1].hex()
    c.send([[b"TYPE", k]])
    t = c.reply()[1]
    if t == b"list":
        c.send([[b"LRANGE", k, b"0", b"-1"]])
        kind, xs = c.reply()
        return "list:" + ",".join(x.hex() for _, x in xs)
    if t == b"set":
        c.send([[b"SMEMBERS", k], [b"OBJECT", b"ENCODING", k]])
        kind, xs = c.reply()
        enc = c.reply()[1].decode()
        return "set:" + enc + ":" + ",".join(sorted(x.hex() for _, x in xs))
    c.send([[b"HGETALL", k]])
    kind, xs = c.reply()
    xs = [x for _, x in xs]
    return "hash:" + ",".join(f.hex() + "=" + w.hex() for f, w in sorted(zip(xs[0::2], xs[1::2])))


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
        out += [(db, k.hex(), value(c, k, v), t.decode()) for k, v, t in zip(keys, vals, times)]
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
            # hashes: small ones, and now and then one past a listpack
            # (600 fields, or a long value), changed by HDEL, HINCRBY and
            # HINCRBYFLOAT
            nf = 600 if i % 2000 == 0 else r.randint(1, 5)
            batch.append([b"HSET", b"h:%d" % i] + [x for j in range(nf) for x in (b"f%d" % j, b"%d" % j)])
            batch.append([b"HSET", b"h:%d" % i, b"long", b"v" * r.choice([3, 70])])
            batch.append([b"HDEL", b"h:%d" % i, b"f0", b"nope"])
            batch.append([b"HINCRBY", b"h:%d" % i, b"f1", b"%d" % r.randint(-100, 100)])
            batch.append([b"HINCRBYFLOAT", b"h:%d" % i, b"f2", b"%.3f" % r.uniform(-100, 100)])
            # a float made, given a time, and added to (its time kept)
            batch.append([b"INCRBYFLOAT", b"f:%d" % i, b"%.6e" % r.uniform(-1e6, 1e6)])
            if i % 300 == 0:
                batch.append([b"PEXPIREAT", b"f:%d" % i, b"%d" % (NOW_S * 1000 + r.randint(10**6, 10**9))])
            batch.append([b"INCRBYFLOAT", b"f:%d" % i, b"%.17g" % r.uniform(-1, 1)])
            if i % 500 == 0:
                batch.append([b"EXPIRE", b"h:%d" % i, b"%d" % r.randint(10**6, 10**7)])
            # lists: pushes at both ends, now and then a long one (3000
            # elements), popped, set, cut, and moved onto the next one
            ne = 3000 if i % 4000 == 0 else r.randint(1, 6)
            batch.append([b"RPUSH", b"l:%d" % i] + [b"e%d" % j for j in range(ne)])
            batch.append([b"LPUSH", b"l:%d" % i, b"h", b"g"])
            batch.append([b"LPOP", b"l:%d" % i] + ([b"2"] if i % 300 == 0 else []))
            batch.append([b"LSET", b"l:%d" % i, b"-1", b"last"])
            batch.append([b"LMOVE", b"l:%d" % i, b"l:%d" % (i + 100), b"LEFT", b"RIGHT"])
            if i % 700 == 0:
                batch.append([b"LTRIM", b"l:%d" % i, b"1", b"-2"])
                batch.append([b"PEXPIREAT", b"l:%d" % i, b"%d" % (NOW_S * 1000 + r.randint(10**6, 10**9))])
            # sets: integers (an intset, now and then one past 512 members)
            # and words, taken from (SREM, SPOP), moved onto the next one,
            # and combined into a third
            ns = 600 if i % 5000 == 0 else r.randint(1, 6)
            batch.append([b"SADD", b"s:%d" % i] + [b"%d" % r.randint(-50, 50) for _ in range(ns)])
            batch.append([b"SADD", b"t:%d" % i] + [b"w%d" % r.randint(0, 9) for _ in range(r.randint(1, 4))])
            batch.append([b"SREM", b"s:%d" % i, b"%d" % r.randint(-50, 50), b"nope"])
            batch.append([b"SPOP", b"t:%d" % i] + ([b"2"] if i % 300 == 0 else []))
            batch.append([b"SMOVE", b"s:%d" % i, b"s:%d" % (i + 100), b"%d" % r.randint(-50, 50)])
            batch.append([r.choice([b"SINTERSTORE", b"SUNIONSTORE", b"SDIFFSTORE"]), b"u:%d" % i, b"s:%d" % i, b"t:%d" % i])
            if i % 900 == 0:
                batch.append([b"PEXPIREAT", b"s:%d" % i, b"%d" % (NOW_S * 1000 + r.randint(10**6, 10**9))])
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
