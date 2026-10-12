#!/usr/bin/env python3
"""The append-only file both ways: the same commands against BendKV and a
redis-server with its append-only file on, each writing its own file; then
BendKV started from Redis's file and Redis from BendKV's, and every database
must read back as the server that wrote the file held it, each key with its
value and the time it expires at. Redis writes a command as the client sent
it (COPY with its options in any order and case, into the selected database
without DB; BITOP and BITFIELD, which BendKV's load runs again), BendKV as
it acted (COPY with DB and REPLACE, BITOP as the SET of its value,
BITFIELD as the SETRANGE of the bytes its writes reach). A BITFIELD
whose writes all fail (OVERFLOW FAIL) on a key it makes or grows is left
out: Redis makes the key and does not log it. Redis 7 keeps its
file in parts, a base and increments (appendonlydir): BendKV reads them
joined, the base written without an RDB preamble.

    python3 tests/aof_redis_test.py --bin build/bendkv --bendkv 6380 --redis 6391 --dir build/aofio
"""
import argparse
import os
import shutil
import subprocess
import sys
import time

from aof_test import keyspace
from diff_test import Conn

# times far away and absolute, so that both servers set the same ones
T = int(time.time() * 1000) + 10**9

CMDS = [
    [b"SET", b"a", b"1"], [b"SET", b"b", b"2", b"PXAT", b"%d" % T], [b"set", b"c", b"3"],
    [b"MSET", b"m1", b"x", b"m2", b"y"], [b"INCR", b"n"], [b"incrby", b"n", b"41"],
    [b"APPEND", b"s", b"hello"], [b"SETRANGE", b"s", b"7", b"world"], [b"SETBIT", b"bits", b"9", b"1"],
    [b"GETSET", b"m1", b"z"], [b"GETDEL", b"m2"], [b"PEXPIREAT", b"c", b"%d" % (T + 1)],
    [b"PERSIST", b"c"], [b"GETEX", b"a", b"EXAT", b"%d" % (T // 1000)], [b"SETNX", b"a", b"9"],
    [b"RENAME", b"s", b"s2"], [b"RENAMENX", b"s2", b"a"], [b"MSETNX", b"x1", b"1", b"x2", b"2"],
    [b"COPY", b"a", b"a2"], [b"copy", b"b", b"b2"], [b"COPY", b"a", b"b2"],
    [b"COPY", b"a", b"b2", b"REPLACE"], [b"copy", b"c", b"c9", b"db", b"3"],
    [b"COPY", b"c", b"c9", b"DB", b"3"], [b"COPY", b"c", b"c9", b"replace", b"DB", b"3"],
    [b"COPY", b"b", b"b3", b"DB", b"5", b"REPLACE"], [b"SELECT", b"3"],
    [b"COPY", b"c9", b"x", b"DB", b"0"], [b"COPY", b"c9", b"c9", b"DB", b"4"], [b"SELECT", b"0"],
    [b"COPY", b"nope", b"z"], [b"COPY", b"a", b"a"], [b"COPY", b"a", b"q", b"DB", b"16"],
    [b"COPY", b"a", b"q", b"DB", b"-1"], [b"COPY", b"a", b"q", b"FOO"],
    [b"COPY", b"a", b"q", b"DB", b"1", b"REPLACE", b"REPLACE"],
    [b"SET", b"e", b"5", b"PXAT", b"%d" % (T + 7)], [b"COPY", b"e", b"e2", b"DB", b"2"],
    [b"SELECT", b"2"], [b"COPY", b"e2", b"e3"], [b"SWAPDB", b"2", b"7"], [b"SELECT", b"7"],
    [b"COPY", b"e3", b"e4", b"REPLACE"], [b"COPY", b"e3", b"b", b"DB", b"0"],
    [b"COPY", b"e3", b"b", b"DB", b"0", b"REPLACE"], [b"MOVE", b"e4", b"9"], [b"SELECT", b"9"],
    [b"COPY", b"e4", b"e4", b"REPLACE", b"DB", b"8"], [b"SELECT", b"6"], [b"SET", b"k", b"1"],
    [b"FLUSHDB"], [b"SET", b"k2", b"2"], [b"DEL", b"nothing"], [b"SELECT", b"0"], [b"UNLINK", b"x1"],
    [b"BITOP", b"AND", b"bo1", b"a", b"b"], [b"bitop", b"not", b"bo2", b"a"], [b"BITOP", b"OR", b"e", b"a", b"nope"],
    [b"BITOP", b"XOR", b"bo3", b"nope"], [b"BITOP", b"NOT", b"bo2", b"nope"], [b"LCS", b"a", b"b"],
    [b"BITFIELD", b"bf", b"SET", b"u8", b"0", b"255", b"INCRBY", b"i5", b"100", b"1", b"GET", b"u4", b"0"],
    [b"bitfield", b"bf", b"overflow", b"fail", b"incrby", b"u2", b"0", b"9", b"incrby", b"u2", b"0", b"1"],
    [b"BITFIELD", b"b", b"SET", b"i64", b"#1", b"-1"], [b"BITFIELD", b"b", b"SET", b"i64", b"#1", b"-1"],
    [b"BITFIELD_RO", b"bf", b"GET", b"u8", b"0"], [b"BITFIELD", b"bf", b"SET", b"u8", b"0", b"x"],
]


# a server started, once it answers PONG (Redis answers LOADING while it
# reads its file)
def start(argv, port, log):
    p = subprocess.Popen(argv, stdout=open(log, "w"), stderr=subprocess.STDOUT)
    for _ in range(200):
        try:
            c = Conn(port)
            c.send([[b"PING"]])
            if c.reply() == (b"+", b"PONG"):
                return p, c
        except (OSError, EOFError):
            pass
        time.sleep(0.05)
    p.kill()
    sys.exit("FAIL: no server on port %d (%s)" % (port, log))


def stop(p):
    p.terminate()
    p.wait()


def redis(port, d, *more):
    return ["redis-server", "--port", str(port), "--bind", "127.0.0.1", "--save", "",
            "--appendonly", "yes", "--appendfsync", "always", "--dir", d] + list(more)


def same(what, x, y):
    if x != y:
        print("FAIL: %s" % what)
        print("  only in the first:", sorted(set(x) - set(y)))
        print("  only in the second:", sorted(set(y) - set(x)))
        sys.exit(1)
    print("OK: %s (%d keys)" % (what, len(x)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default="build/bendkv")
    ap.add_argument("--bendkv", type=int, default=6380)
    ap.add_argument("--redis", type=int, default=6391)
    ap.add_argument("--dir", default="build/aofio")
    a = ap.parse_args()
    d = os.path.abspath(a.dir)
    shutil.rmtree(d, ignore_errors=True)
    for sub in ["redis", "bendkv", "load"]:
        os.makedirs(os.path.join(d, sub))
    rdir, bfile = os.path.join(d, "redis"), os.path.join(d, "bendkv", "bendkv.aof")
    pr, cr = start(redis(a.redis, rdir, "--aof-use-rdb-preamble", "no"), a.redis, os.path.join(d, "redis.log"))
    pb, cb = start([a.bin, str(a.bendkv), "send", bfile, "always"], a.bendkv, os.path.join(d, "bendkv.log"))
    try:
        for x in CMDS:
            cr.send([x])
            cb.send([x])
            r, b = cr.reply(), cb.reply()
            if r != b:
                sys.exit("FAIL: %r answered %r by Redis, %r by BendKV" % (x, r, b))
        print("OK: %d commands, the same replies" % len(CMDS))
        kr, kb = keyspace(cr), keyspace(cb)
    finally:
        stop(pr)
        stop(pb)
    same("the same databases on both", kr, kb)
    # BendKV from Redis's file: its base, then its increments
    parts = os.path.join(rdir, "appendonlydir")
    rfile = os.path.join(d, "load", "redis.aof")
    with open(rfile, "wb") as o:
        for n in sorted(os.listdir(parts), key=lambda n: (".incr." in n, n)):
            if n.endswith(".aof"):
                with open(os.path.join(parts, n), "rb") as f:
                    o.write(f.read())
    p, c = start([a.bin, str(a.bendkv), "send", rfile, "always"], a.bendkv, os.path.join(d, "load.log"))
    try:
        k = keyspace(c)
    finally:
        stop(p)
    same("BendKV restores the databases from Redis's file", k, kr)
    # Redis from BendKV's file, which it reads as a file of Redis 6
    if shutil.which("redis-check-aof"):
        print(subprocess.run(["redis-check-aof", bfile], capture_output=True, text=True).stdout.strip().splitlines()[-1])
    ldir = os.path.join(d, "rload")
    os.makedirs(ldir)
    shutil.copy(bfile, os.path.join(ldir, "appendonly.aof"))
    p, c = start(redis(a.redis, ldir, "--appendfilename", "appendonly.aof"), a.redis, os.path.join(d, "rload.log"))
    try:
        k = keyspace(c)
    finally:
        stop(p)
    same("Redis restores the databases from BendKV's file", k, kb)
    print("ALL OK")


if __name__ == "__main__":
    main()
