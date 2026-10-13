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
out: Redis makes the key and does not log it. A hash is logged as the
HSET of the pairs a write set and the HDEL of the fields it took (an
HINCRBY and an HINCRBYFLOAT as the HSET of its sum, as INCRBYFLOAT is
the SET of its sum with KEEPTTL), and a hash made where a key whose time
had passed still lay as a script that deletes the key and runs the HSET
(Redis logs a MULTI with a DEL and the HSET): a file of such scripts is
read by both alike. A list is logged as the writes that changed it
(LMPOP as the LPOP or RPOP of the key it took from, with its count; a
pop of the last elements as the DEL of the key), a list made where a
key whose time had passed still lay as the like script of its pushes,
and a move onto such a key as a script that deletes the destination and
runs the LMOVE; the commands run both ways, with a few keys whose time
passes before a move onto them or a push, and a file of the scripts is
read by both alike. A set is logged as the SADD and SREM that changed it
(SPOP as the SREM of what it took, or the DEL of the key when it took the
last members, as Redis logs it), a set made where a key whose time had
passed still lay as the like script of its SADD (SINTERSTORE and its kin
too, as the script of the members they make), and SMOVE onto such a key
as a script that deletes the destination and runs the SMOVE; SPOP runs
both ways only where its picks are the whole set. Redis 7 keeps its
file in parts, a base and increments (appendonlydir): BendKV reads them
joined, the base written without an RDB preamble. A sorted set is
logged as the commands that changed it (ZINCRBY as ZADD with INCR, ZMPOP
as the ZPOPMIN or ZPOPMAX of the key it took from), and a sorted set a
STORE makes, or a ZADD where a key whose time had passed still lay, as a
script that deletes the key and runs ZADD with the options before each
thousand words of pairs; a file of the scripts is read by both alike. A
transaction is logged by both as the effects of its commands between a
MULTI and an EXEC (one of a single effect, as that effect alone), and read
by both.

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
    [b"HSET", b"h", b"a", b"1", b"b", b"2", b"a", b"3"], [b"hmset", b"h", b"c", b"4"], [b"HSETNX", b"h", b"d", b"5"],
    [b"HSETNX", b"h", b"a", b"9"], [b"HINCRBY", b"h", b"a", b"10"], [b"HINCRBY", b"h2", b"n", b"-7"],
    [b"INCRBYFLOAT", b"fl", b"10.5"], [b"PEXPIREAT", b"fl", b"%d" % (T + 9)], [b"INCRBYFLOAT", b"fl", b"0.1"],
    [b"incrbyfloat", b"fl2", b"-1.5e-3"], [b"HINCRBYFLOAT", b"h", b"fl", b"2.5"], [b"HINCRBYFLOAT", b"h", b"fl", b"1e2"],
    [b"hincrbyfloat", b"h5", b"x", b"3.0e5"],
    [b"HDEL", b"h", b"b", b"nope"], [b"HDEL", b"h2", b"n"], [b"HSET", b"h3", b"long", b"v" * 70],
    [b"HSET", b"h4"] + [x for j in range(600) for x in (b"f%d" % j, b"%d" % j)], [b"HDEL", b"h4", b"f1", b"f2"],
    [b"PEXPIREAT", b"h", b"%d" % (T + 9)], [b"COPY", b"h", b"h5", b"DB", b"2"], [b"RENAME", b"h3", b"h6"],
    [b"MOVE", b"h6", b"3"], [b"HSET", b"a", b"f", b"v"], [b"SET", b"h", b"str"], [b"HSET", b"h", b"x", b"y"],
    [b"RPUSH", b"l", b"a", b"b", b"c"], [b"lpush", b"l", b"x", b"y"], [b"LPUSHX", b"l", b"z"], [b"RPUSHX", b"nope", b"z"],
    [b"LPOP", b"l"], [b"RPOP", b"l", b"2"], [b"LSET", b"l", b"0", b"q"], [b"LINSERT", b"l", b"BEFORE", b"q", b"p"],
    [b"LINSERT", b"l", b"after", b"nope", b"p"], [b"LREM", b"l", b"0", b"p"], [b"RPUSH", b"l2"] + [b"%d" % i for i in range(300)],
    [b"LTRIM", b"l2", b"1", b"-2"], [b"LMOVE", b"l2", b"l", b"LEFT", b"RIGHT"], [b"LMOVE", b"l2", b"l2", b"RIGHT", b"LEFT"],
    [b"RPOPLPUSH", b"l2", b"l3"], [b"LMPOP", b"2", b"nope", b"l2", b"RIGHT", b"COUNT", b"5"], [b"LMPOP", b"1", b"l3", b"LEFT"],
    [b"RPUSH", b"l4", b"a"], [b"PEXPIREAT", b"l4", b"%d" % (T + 11)], [b"LPOP", b"l4"], [b"RPUSH", b"l5", b"a", b"b"],
    [b"PEXPIREAT", b"l5", b"%d" % (T + 12)], [b"COPY", b"l5", b"l6", b"DB", b"2"], [b"RENAME", b"l5", b"l7"],
    [b"MOVE", b"l7", b"4"], [b"LPUSH", b"a", b"x"], [b"SET", b"l", b"str"], [b"RPUSH", b"l", b"y"],
    [b"LMOVE", b"l2", b"h", b"LEFT", b"LEFT"], [b"LREM", b"l2", b"-2", b"7"], [b"LPOP", b"l2", b"0"],
    [b"SET", b"ex1", b"v", b"PX", b"3"], [b"RPUSH", b"ex2", b"a"], [b"PEXPIRE", b"ex2", b"3"],
    [b"HSET", b"ex3", b"f", b"v"], [b"PEXPIRE", b"ex3", b"3"], [b"SET", b"ex4", b"v", b"PX", b"3"], [b"SLEEP"],
    [b"RPUSH", b"src", b"1", b"2", b"3"], [b"LMOVE", b"src", b"ex1", b"LEFT", b"RIGHT"], [b"RPOPLPUSH", b"src", b"ex2"],
    [b"LPUSH", b"ex3", b"n"], [b"RPUSH", b"ex4", b"m", b"n"],
    [b"SADD", b"st", b"1", b"2", b"3"], [b"sadd", b"st", b"a"], [b"SREM", b"st", b"2", b"nope"],
    [b"SADD", b"st2"] + [b"%d" % j for j in range(600)], [b"SREM", b"st2", b"5", b"6"], [b"SMOVE", b"st", b"st3", b"1"],
    [b"SMOVE", b"st", b"st", b"3"], [b"SMOVE", b"st2", b"st3", b"7"], [b"SMOVE", b"st2", b"nope", b"9999"],
    [b"SINTERSTORE", b"st4", b"st", b"st3"], [b"SUNIONSTORE", b"st5", b"st", b"st2"], [b"SDIFFSTORE", b"st6", b"st2", b"st3"],
    [b"SINTERSTORE", b"st6", b"st", b"nope"], [b"SINTERCARD", b"2", b"st2", b"st5", b"LIMIT", b"10"],
    [b"SADD", b"sp", b"9"], [b"SPOP", b"sp"], [b"SADD", b"sp2", b"1", b"2", b"3"], [b"SPOP", b"sp2", b"10"],
    [b"SADD", b"sp3", b"4", b"5"], [b"SPOP", b"sp3", b"0"], [b"PEXPIREAT", b"st", b"%d" % (T + 13)],
    [b"COPY", b"st", b"st7", b"DB", b"2"], [b"RENAME", b"st5", b"st8"], [b"MOVE", b"st8", b"5"], [b"SADD", b"a", b"x"],
    [b"SET", b"st3", b"str"], [b"SADD", b"st3", b"y"], [b"SUNIONSTORE", b"st3", b"st4"],
    [b"SADD", b"ex5", b"a"], [b"PEXPIRE", b"ex5", b"3"], [b"SET", b"ex6", b"v", b"PX", b"3"], [b"SADD", b"ex7", b"q"],
    [b"PEXPIRE", b"ex7", b"3"], [b"HSET", b"ex8", b"f", b"v"], [b"PEXPIRE", b"ex8", b"3"], [b"SLEEP"],
    [b"SADD", b"ex5", b"n"], [b"SADD", b"srcs", b"1", b"2", b"3"], [b"SMOVE", b"srcs", b"ex6", b"1"],
    [b"SUNIONSTORE", b"ex7", b"srcs"], [b"SMOVE", b"srcs", b"ex8", b"2"],
    [b"ZADD", b"zs", b"1", b"a", b"2", b"b", b"3", b"c"], [b"zadd", b"zs", b"NX", b"CH", b"5", b"a", b"4", b"d"],
    [b"ZADD", b"zs", b"XX", b"GT", b"10", b"b"], [b"ZADD", b"zs", b"INCR", b"2.5", b"c"], [b"ZINCRBY", b"zs", b"-1", b"d"],
    [b"ZADD", b"zs", b"LT", b"0", b"e", b"-1", b"a"], [b"ZREM", b"zs", b"b", b"nope"], [b"ZADD", b"zs", b"-0", b"z"],
    [b"ZADD", b"zs2"] + [x for j in range(300) for x in (b"%d" % (j % 7), b"m%d" % j)],
    [b"ZREMRANGEBYRANK", b"zs2", b"0", b"9"], [b"ZREMRANGEBYSCORE", b"zs2", b"(5", b"+inf"],
    [b"ZADD", b"zl", b"0", b"a", b"0", b"b", b"0", b"c", b"0", b"d"], [b"ZREMRANGEBYLEX", b"zl", b"[b", b"(d"],
    [b"ZPOPMIN", b"zs"], [b"ZPOPMAX", b"zs2", b"3"], [b"ZUNIONSTORE", b"zu", b"2", b"zs", b"zs2", b"WEIGHTS", b"2", b"1"],
    [b"ZINTERSTORE", b"zi", b"2", b"zs2", b"zl"], [b"ZDIFFSTORE", b"zd", b"2", b"zs2", b"zs"],
    [b"ZRANGESTORE", b"zr", b"zs2", b"0", b"4", b"REV"], [b"ZMPOP", b"2", b"nope", b"zl", b"MIN", b"COUNT", b"10"],
    [b"ZADD", b"zlong", b"1", b"z" * 70, b"-0", b"y"], [b"PEXPIREAT", b"zs", b"%d" % (T + 14)],
    [b"COPY", b"zs", b"zs3", b"DB", b"2"], [b"RENAME", b"zu", b"zu2"], [b"SET", b"zstr", b"x"],
    [b"ZUNIONSTORE", b"zstr", b"1", b"zs"], [b"SADD", b"zsrc", b"a", b"q"], [b"ZINTERSTORE", b"zi2", b"2", b"zs", b"zsrc"],
    [b"ZINTERSTORE", b"zi2", b"2", b"zs", b"nope"], [b"ZRANGESTORE", b"zr", b"nope", b"0", b"-1"],
    [b"ZADD", b"ex9", b"1", b"a"], [b"PEXPIRE", b"ex9", b"3"], [b"ZADD", b"ex10", b"1", b"a"], [b"PEXPIRE", b"ex10", b"3"],
    [b"SLEEP"], [b"ZADD", b"ex9", b"NX", b"2", b"b", b"3", b"b"], [b"ZUNIONSTORE", b"ex10", b"1", b"zsrc"],
    [b"MULTI"], [b"SET", b"tx1", b"a"], [b"INCR", b"txn"], [b"RPUSH", b"txl", b"1", b"2"], [b"SELECT", b"4"],
    [b"SET", b"tx4", b"b"], [b"EXEC"], [b"SELECT", b"0"], [b"MULTI"], [b"SET", b"tx2", b"c"], [b"EXEC"],
    [b"MULTI"], [b"SET", b"tx3", b"d"], [b"DISCARD"], [b"MULTI"], [b"GET", b"tx1"], [b"EXEC"],
]

# a file with the entries BendKV logs for a hash, a list or a set made
# where a key whose time had passed still lay: the script that deletes the
# key and runs the HSET (the pushes, the SADD; a thousand arguments a
# call), and for a move onto such a key, the script that deletes it and
# runs the LMOVE or the SMOVE; Redis runs them and BendKV reads them back
SCRIPT = (b"redis.call('del',KEYS[1]) local n=#ARGV for i=2,n,1000 do redis.call(ARGV[1],KEYS[1],"
          b"unpack(ARGV,i,math.min(i+999,n))) end return 0")
MOVE = b"redis.call('del',KEYS[2]) return redis.call('lmove',KEYS[1],KEYS[2],ARGV[1],ARGV[2])"
SMOVE = b"redis.call('del',KEYS[2]) return redis.call('smove',KEYS[1],KEYS[2],ARGV[1])"
ZSCRIPT = (b"redis.call('del',KEYS[1]) local o=tonumber(ARGV[1]) local n=#ARGV for i=o+2,n,1000 do local a={} "
           b"for j=2,o+1 do a[#a+1]=ARGV[j] end for j=i,math.min(i+999,n) do a[#a+1]=ARGV[j] end "
           b"redis.call('zadd',KEYS[1],unpack(a)) end return 0")


def entry(*a):
    return b"*%d\r\n" % len(a) + b"".join(b"$%d\r\n%s\r\n" % (len(x), x) for x in a)


def eval_file(path):
    big = [x for j in range(3001) for x in (b"f%d" % j, b"v%d" % j)]
    with open(path, "wb") as f:
        f.write(entry(b"SELECT", b"0") + entry(b"SET", b"k", b"str") + entry(b"HSET", b"h", b"x", b"y") +
                entry(b"PEXPIREAT", b"h", b"%d" % T) + entry(b"EVAL", SCRIPT, b"1", b"k", b"HSET", b"f1", b"v1", b"f2", b"v2") +
                entry(b"EVAL", SCRIPT, b"1", b"big", b"HSET", *big) + entry(b"EVAL", SCRIPT, b"1", b"h", b"HSET", b"a", b"1") +
                entry(b"EVAL", SCRIPT, b"1", b"new", b"HSET", b"a", b"1", b"a", b"2") +
                entry(b"SET", b"lk", b"str") + entry(b"EVAL", SCRIPT, b"1", b"lk", b"LPUSH", b"a", b"b") +
                entry(b"EVAL", SCRIPT, b"1", b"lbig", b"RPUSH", *[b"e%d" % j for j in range(2500)]) +
                entry(b"EVAL", SCRIPT, b"1", b"h", b"RPUSH", b"c") + entry(b"RPUSH", b"src", b"1", b"2", b"3") +
                entry(b"EVAL", MOVE, b"2", b"src", b"lk", b"LEFT", b"RIGHT") +
                entry(b"EVAL", MOVE, b"2", b"src", b"k", b"RIGHT", b"LEFT") +
                entry(b"SET", b"sk", b"str") + entry(b"EVAL", SCRIPT, b"1", b"sk", b"SADD", b"a", b"b", b"1") +
                entry(b"EVAL", SCRIPT, b"1", b"sbig", b"SADD", *[b"m%d" % j for j in range(2500)]) +
                entry(b"EVAL", SCRIPT, b"1", b"sint", b"SADD", *[b"%d" % j for j in range(300)]) +
                entry(b"EVAL", SCRIPT, b"1", b"h", b"SADD", b"c") + entry(b"SADD", b"ssrc", b"1", b"2", b"3") +
                entry(b"EVAL", SMOVE, b"2", b"ssrc", b"sk", b"1") + entry(b"EVAL", SMOVE, b"2", b"ssrc", b"k", b"2") +
                entry(b"SET", b"zk", b"str") + entry(b"EVAL", ZSCRIPT, b"1", b"zk", b"0", b"1", b"a", b"2", b"b") +
                entry(b"EVAL", ZSCRIPT, b"1", b"zbig", b"0", *[x for j in range(1500) for x in (b"%d" % (j % 9), b"m%d" % j)]) +
                entry(b"EVAL", ZSCRIPT, b"1", b"zopt", b"2", b"NX", b"CH", b"1", b"a", b"2", b"a", b"-0", b"b") +
                entry(b"EVAL", ZSCRIPT, b"1", b"h", b"1", b"INCR", b"5", b"x") +
                entry(b"EVAL", ZSCRIPT, b"1", b"zgt", b"1", b"GT", *[x for j in range(1200) for x in (b"%d" % j, b"m%d" % (j % 700))]))


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
            # a pause, for the keys of a short time to pass (BendKV's
            # sweep, every 100 ms, may take them first: the file then
            # holds a plain move onto a key not there)
            if x == [b"SLEEP"]:
                time.sleep(0.01)
                continue
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
    # the script of a new hash, read by both
    edir = os.path.join(d, "eval")
    os.makedirs(edir)
    eval_file(os.path.join(edir, "appendonly.aof"))
    p, c = start(redis(a.redis, edir, "--appendfilename", "appendonly.aof"), a.redis, os.path.join(d, "eval-redis.log"))
    try:
        kr = keyspace(c)
    finally:
        stop(p)
    eval_file(os.path.join(edir, "bendkv.aof"))
    p, c = start([a.bin, str(a.bendkv), "send", os.path.join(edir, "bendkv.aof"), "always"], a.bendkv,
                 os.path.join(d, "eval-bendkv.log"))
    try:
        kb = keyspace(c)
    finally:
        stop(p)
    same("BendKV reads the scripts of a new hash, list, set and sorted set and of the moves as Redis runs them", kb, kr)
    print("ALL OK")


if __name__ == "__main__":
    main()
