#!/usr/bin/env python3
"""Numbers at their edges in every argument that is one: past what a long
long holds, at LLONG_MAX and LLONG_MIN, at 2^48 (past which a Bend Nat does
not go), at 2^32 and 2^31, at 2^58 + 1 (64 times it, an i64's offset #k
in BITFIELD, wraps to 64), and in forms Redis refuses (+5, 1e5, 0x10,
" 5", -0, 00, 3.5). BITFIELD reads at the number as an offset, or writes
it at a small one (a write far out would make a value of up to 512MB).
BendKV must answer each command, and answer as Redis does,
but where BendKV is known to differ: INCRBY and DECRBY past 14 digits (its
integers), and SCAN with a cursor it did not give (the cursor is the place
in each server's own table). A full SCAN's keys are compared as a set:
each server lists them in the order of its own table.

    python3 tests/numbers_test.py --bendkv 6380 --redis 6390
"""
import argparse
import sys

from diff_test import Conn

NUMS = [b"9223372036854775807", b"9223372036854775808", b"-9223372036854775808", b"-9223372036854775809",
        b"18446744073709551615", b"99999999999999999999", b"281474976710656", b"281474976710655",
        b"4294967296", b"2147483648", b"-2147483649", b"1e5", b"+5", b"0x10", b" 5", b"5 ", b"-0", b"00", b"3.5",
        b"288230376151711745", b"-288230376151711745"]

# n: the number tried; the commands the known differences are in are
# checked for an answer only
TEMPL = [
    "SELECT n", "SWAPDB n 1", "SWAPDB 1 n", "MOVE k n", "COPY k k2 DB n", "COPY k k2 DB n REPLACE",
    "HELLO n", "EXPIRE k n", "PEXPIRE k n", "EXPIREAT k n", "PEXPIREAT k n", "SETEX k n v",
    "PSETEX k n v", "SET k v EX n", "SET k v PX n", "SET k v EXAT n", "SET k v PXAT n",
    "GETEX k EX n", "GETEX k PX n", "GETEX k EXAT n", "GETEX k PXAT n", "INCRBY i n", "DECRBY i n",
    "GETRANGE k n n", "GETRANGE k 0 n", "SUBSTR k n 1", "SETRANGE k n x", "GETBIT k n",
    "SETBIT k n 1", "BITCOUNT k n n", "BITCOUNT k 0 n BIT", "BITPOS k 1 n", "BITPOS k 1 0 n BIT",
    "SCAN n", "SCAN 0 COUNT n", "CONFIG SET hz n", "CONFIG SET proto-max-bulk-len n",
    "CONFIG SET maxmemory n", "CONFIG SET databases n", "BITFIELD k GET u8 n", "BITFIELD k GET i64 #n",
    "BITFIELD k GET u5 #n", "BITFIELD_RO k GET i3 n", "BITFIELD k GET Tn 0", "BITFIELD k GET Un 0",
    "BITFIELD k SET i64 0 n", "BITFIELD k SET u8 3 n", "BITFIELD k INCRBY i64 0 n", "BITFIELD k INCRBY u63 1 n",
    "BITFIELD k OVERFLOW SAT INCRBY i32 0 n", "BITFIELD k OVERFLOW SAT SET i8 0 n", "BITFIELD k OVERFLOW FAIL SET u7 0 n",
]
ANSWER_ONLY = ("INCRBY", "DECRBY", "SCAN n")


def norm(t, x):
    if t.startswith("SCAN") and x[0] == b"*":
        return (x[0], [x[1][0], (x[1][1][0], sorted(x[1][1][1]))])
    return x


# the state each command starts from on both servers
RESET = [[b"SELECT", b"0"], [b"SET", b"k", b"hello"], [b"SET", b"i", b"5"],
         [b"CONFIG", b"SET", b"proto-max-bulk-len", b"536870912"], [b"CONFIG", b"SET", b"hz", b"10"],
         [b"CONFIG", b"SET", b"maxmemory", b"0"]]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, default=6380)
    ap.add_argument("--redis", type=int, default=6390)
    a = ap.parse_args()
    b, r = Conn(a.bendkv), Conn(a.redis)
    bad = n = 0
    for c in (b, r):
        c.send([[b"FLUSHALL"], [b"SET", b"m", b"1"], [b"SET", b"z", b"2"]])
        for _ in range(3):
            c.reply()
    for t in TEMPL:
        for num in NUMS:
            args = [num if w == "n" else b"#" + num if w == "#n" else b"i" + num if w == "Tn" else
                    b"u" + num if w == "Un" else w.encode() for w in t.split(" ")]
            for c in (b, r):
                c.send(RESET)
                for _ in RESET:
                    c.reply()
                c.send([args])
            try:
                x = b.reply()
            except (OSError, EOFError) as e:
                print("FAIL: BendKV did not answer %r: %s" % (b" ".join(args), e))
                sys.exit(1)
            y = r.reply()
            n += 1
            if norm(t, x) != norm(t, y) and not t.startswith(ANSWER_ONLY):
                bad += 1
                print("FAIL: %r: BendKV %r, Redis %r" % (b" ".join(args), x, y))
    for c in (b, r):
        c.send([[b"FLUSHALL"]])
        c.reply()
    if bad:
        sys.exit("FAIL: %d of %d" % (bad, n))
    print("OK: %d commands with numbers at their edges, each answered as Redis answers it" % n)


if __name__ == "__main__":
    main()
