#!/usr/bin/env python3
"""Keys that expire, on BendKV and on a real Redis: each case sets keys
with short times on both servers, waits for them to pass, then sends the
same commands to both and compares the replies one by one. TTL, PTTL,
EXPIRETIME and PEXPIRETIME read each server's clock, and are compared
within a second; KEYS and SCAN answer in their own order.

    python3 tests/ttl_test.py --bendkv 6380 --redis 6390

DBSIZE is not compared once a key has expired: Redis deletes an expired
key when a command comes to it, BendKV only when a write comes to it.
"""
import argparse
import sys
import time

from diff_test import Conn, normalize, close

# (keys and times set, ms to wait, commands then compared)
CASES = [
    ("reads", [
        [b"SET", b"a", b"1", b"PX", b"150"],
        [b"SETEX", b"b", b"100", b"x"],
        [b"PSETEX", b"c", b"150", b"y"],
        [b"SET", b"d", b"1", b"EX", b"100"],
        [b"SET", b"e", b"1", b"PXAT", b"1"],
        [b"SET", b"f", b"1", b"EXAT", b"1"],
    ], 400, [
        [b"GET", b"a"], [b"GET", b"b"], [b"GET", b"c"], [b"GET", b"e"],
        [b"EXISTS", b"a", b"b", b"c", b"d", b"e", b"f", b"a"],
        [b"MGET", b"a", b"b", b"c", b"d", b"e"],
        [b"STRLEN", b"a"], [b"STRLEN", b"b"],
        [b"TTL", b"a"], [b"PTTL", b"c"], [b"TTL", b"b"], [b"PTTL", b"d"],
        [b"EXPIRETIME", b"a"], [b"PEXPIRETIME", b"e"], [b"PEXPIRETIME", b"f"],
        [b"KEYS", b"*"], [b"SCAN", b"0", b"COUNT", b"1000"], [b"KEYS", b"?"],
    ]),
    ("expired keys only", [
        [b"SET", b"a", b"1", b"PX", b"100"],
        [b"PSETEX", b"b", b"100", b"y"],
        [b"SET", b"c", b"1", b"PXAT", b"1"],
    ], 300, [
        [b"RANDOMKEY"], [b"KEYS", b"*"], [b"SCAN", b"0"], [b"EXISTS", b"a", b"b", b"c"],
    ]),
    ("writes over expired keys", [
        [b"SET", b"a", b"1", b"PX", b"100"],
        [b"SET", b"b", b"1", b"PX", b"100"],
        [b"SET", b"c", b"1", b"PX", b"100"],
        [b"SET", b"d", b"old", b"PX", b"100"],
        [b"SET", b"e", b"5", b"PX", b"100"],
        [b"SET", b"f", b"5", b"PX", b"100"],
        [b"SET", b"g", b"5", b"PX", b"100"],
        [b"SET", b"h", b"5", b"PX", b"100"],
        [b"SET", b"i", b"5", b"PX", b"100"],
        [b"SET", b"j", b"5", b"PX", b"100"],
        [b"SET", b"k", b"5", b"PX", b"100"],
    ], 300, [
        [b"SETNX", b"a", b"2"], [b"TTL", b"a"], [b"GET", b"a"],
        [b"SET", b"b", b"x", b"XX"], [b"GET", b"b"],
        [b"SET", b"b", b"x", b"NX", b"GET"], [b"GET", b"b"], [b"TTL", b"b"],
        [b"GETSET", b"c", b"z"], [b"TTL", b"c"],
        [b"APPEND", b"d", b"new"], [b"GET", b"d"], [b"TTL", b"d"],
        [b"INCR", b"e"], [b"INCRBY", b"f", b"7"], [b"DECR", b"g"], [b"TTL", b"e"],
        [b"DEL", b"h", b"h"], [b"MSET", b"i", b"m"], [b"GET", b"i"], [b"TTL", b"i"],
        [b"SET", b"j", b"v", b"KEEPTTL"], [b"TTL", b"j"],
        [b"SET", b"k", b"v", b"GET"],
    ]),
    ("TTL commands over expired keys", [
        [b"SET", b"a", b"1", b"PX", b"100"],
        [b"SET", b"b", b"1", b"PX", b"100"],
        [b"SET", b"c", b"1", b"PX", b"100"],
        [b"SET", b"d", b"1", b"PX", b"100"],
        [b"SET", b"e", b"1", b"PX", b"100"],
        [b"SET", b"f", b"1", b"PX", b"100"],
    ], 300, [
        [b"EXPIRE", b"a", b"100"], [b"PERSIST", b"b"], [b"GETEX", b"c", b"PERSIST"],
        [b"GETDEL", b"d"], [b"GETEX", b"e", b"EX", b"100"], [b"EXPIRE", b"f", b"100", b"LT"],
        [b"TTL", b"a"], [b"TTL", b"b"], [b"TTL", b"c"], [b"TTL", b"e"],
        [b"PEXPIREAT", b"f", b"1"], [b"EXPIRE", b"f", b"-1"],
    ]),
    ("times kept and changed", [
        [b"SET", b"a", b"1", b"PX", b"200"],
        [b"SET", b"a", b"2", b"KEEPTTL"],
        [b"SET", b"b", b"1", b"PX", b"200"],
        [b"INCR", b"b"],
        [b"SET", b"c", b"x", b"PX", b"200"],
        [b"APPEND", b"c", b"y"],
        [b"SET", b"d", b"x", b"PX", b"200"],
        [b"SET", b"d", b"y"],
        [b"SET", b"e", b"x", b"PX", b"200"],
        [b"PERSIST", b"e"],
        [b"SET", b"f", b"x"],
        [b"PEXPIRE", b"f", b"200"],
        [b"SET", b"g", b"x", b"EX", b"100"],
        [b"PEXPIRE", b"g", b"200", b"LT"],
        [b"SET", b"h", b"x", b"PX", b"200"],
        [b"EXPIRE", b"h", b"100", b"GT"],
        [b"SET", b"i", b"x", b"PX", b"200"],
        [b"GETEX", b"i", b"PERSIST"],
        [b"SET", b"j", b"x"],
        [b"GETEX", b"j", b"PX", b"200"],
        [b"SET", b"k", b"x", b"PX", b"200"],
        [b"GETSET", b"k", b"y"],
        [b"SET", b"l", b"x", b"PX", b"200"],
        [b"EXPIRE", b"l", b"100", b"NX"],
        [b"SET", b"m", b"x"],
        [b"PEXPIRE", b"m", b"200", b"XX"],
        [b"MSET", b"n", b"x"],
        [b"PEXPIRE", b"n", b"200"],
        [b"MSET", b"n", b"y"],
    ], 400, [
        [b"MGET", b"a", b"b", b"c", b"d", b"e", b"f", b"g", b"h", b"i", b"j", b"k", b"l", b"m", b"n"],
        [b"KEYS", b"*"],
    ]),
    ("times in the past", [
        [b"SET", b"a", b"1"], [b"EXPIREAT", b"a", b"1"],
        [b"SET", b"b", b"1"], [b"PEXPIRE", b"b", b"-5"],
        [b"SET", b"c", b"1"], [b"EXPIRE", b"c", b"0"],
        [b"SET", b"d", b"1"], [b"GETEX", b"d", b"PXAT", b"5"],
        [b"SET", b"e", b"1"], [b"GETEX", b"e", b"EXAT", b"5"],
        [b"SET", b"f", b"1"], [b"PEXPIREAT", b"f", b"-9223372036854770000"],
        [b"SET", b"g", b"1", b"EX", b"100"], [b"EXPIRE", b"g", b"0", b"GT"],
        [b"SET", b"h", b"1", b"EX", b"100"], [b"EXPIRE", b"h", b"0", b"LT"],
    ], 0, [
        [b"EXISTS", b"a", b"b", b"c", b"d", b"e", b"f", b"g", b"h"], [b"DBSIZE"], [b"KEYS", b"*"],
        [b"TTL", b"g"],
    ]),
]


def run(conns, cmds):
    for c in conns:
        c.send(cmds)
    return [[c.reply() for _ in cmds] for c in conns]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, default=6380)
    ap.add_argument("--redis", type=int, default=6390)
    a = ap.parse_args()
    b, s = Conn(a.bendkv), Conn(a.redis)
    n = 0
    for name, setup, wait, check in CASES:
        run((b, s), [[b"FLUSHALL"]])
        got, want = run((b, s), setup)
        for cmd, x, y in zip(setup, got, want):
            if normalize(cmd, x) != normalize(cmd, y) and not close(cmd, x, y):
                print("MISMATCH in %r, setting up:" % name, cmd)
                print("  bendkv: ", x)
                print("  redis:  ", y)
                sys.exit(1)
        time.sleep(wait / 1000)
        got, want = run((b, s), check)
        for cmd, x, y in zip(check, got, want):
            if normalize(cmd, x) != normalize(cmd, y) and not close(cmd, x, y):
                print("MISMATCH in %r:" % name, cmd)
                print("  bendkv: ", x)
                print("  redis:  ", y)
                sys.exit(1)
            n += 1
    print("OK: %d cases of keys that expire, %d replies identical" % (len(CASES), n))


if __name__ == "__main__":
    main()
