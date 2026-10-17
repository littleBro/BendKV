#!/usr/bin/env python3
"""The start reads its append-only file a window at a time (src/server.bend:
restore; a read of 1 MiB, or as long as what the last window left), so
files whose entries, transactions and values straddle the windows' ends,
started on by BendKV and by redis-server 7.0.15 alike: a file of several
windows that ends inside one, with a transaction across the first
window's end, an entry whose count's line the second window's end cuts,
a value the third's end cuts, values of 1.5 MiB and of 5 MiB (five
windows long), a transaction that holds one of 1.25 MiB, and SELECTs;
then that file with its last entry cut short inside a long value, with a
transaction left open (a MULTI, then entries, one longer than a window,
and no EXEC), and with a transaction left open and then an entry cut
short. Each file is started on with aof-load-truncated yes and no: both
servers must start, or both refuse to (and say that the file ends
unexpectedly); when both start, every database must read back the same
on both, and the file must be cut to the same length (a transaction
left open and then an entry cut short excepted, which BendKV cuts back
to before its MULTI and Redis to after its last whole entry, the MULTI
and the entries it queued left in the file for its next start to
revert: README.md, "Where BendKV differs"). Then the file with an
unknown command after it, which both refuse: BendKV names the entry and
the byte it starts at, which it finds reading the file again a window at
a time. Last, two small files whose transaction left open holds entries
Redis reads but does not write (bulks with no length, a MULTI written
*01), which both cut at the byte the MULTI starts at, and a file whose
entry ends exactly at the first window's end.

    python3 tests/aof_window_test.py --bin build/bendkv --bendkv 6380 --redis 6391 --dir build/aofwin
"""
import argparse
import os
import shutil
import subprocess
import sys
import time

from aof_test import keyspace
from diff_test import Conn

MIB = 1 << 20


def entry(*a):
    return b"*%d\r\n" % len(a) + b"".join(b"$%d\r\n%s\r\n" % (len(x), x) for x in a)


class File:
    """A file being written, entry by entry, and its length."""

    def __init__(self):
        self.parts = []
        self.n = 0
        self.i = 0
        self.entries = 0

    def put(self, b):
        self.parts.append(b)
        self.n += len(b)
        self.entries += 1

    def bytes(self):
        return b"".join(self.parts)

    def pad(self, at):
        """small SETs, then one long enough that the next entry starts at
        byte at"""
        while self.n < at - 2000:
            self.i += 1
            self.put(entry(b"SET", b"pad:%d" % self.i, b"%d" % (self.i * 7919) * (self.i % 200)))
        need = at - self.n
        for m in range(need):
            e = entry(b"SET", b"fill:%d" % self.i, b"f" * m)
            if len(e) == need:
                self.put(e)
                return
        raise ValueError("no SET of %d bytes" % need)


def base():
    """the file of several windows, ending inside one"""
    f = File()
    f.put(entry(b"SELECT", b"0"))
    # a transaction across the first window's end: its MULTI, a SET, a
    # SELECT and a SET before the end, its EXEC after it
    f.pad(MIB - 60)
    f.put(entry(b"MULTI"))
    f.put(entry(b"SET", b"tx:a", b"1"))
    f.put(entry(b"SELECT", b"3"))
    f.put(entry(b"SET", b"tx:b", b"b" * 40))
    f.put(entry(b"EXEC"))
    f.put(entry(b"SELECT", b"0"))
    # an entry whose count's line the second window's end cuts ("*3\r|\n")
    f.pad(2 * MIB - 3)
    f.put(entry(b"SET", b"cut:count", b"c"))
    # a value whose bytes the third window's end cuts
    f.pad(3 * MIB - 100)
    f.put(entry(b"SET", b"cut:value", bytes(range(256)) * 2))
    f.put(entry(b"RPUSH", b"list", b"a", b"b", b"c"))
    f.put(entry(b"HSET", b"hash", b"f", b"v", b"g", b"w"))
    f.put(entry(b"PEXPIREAT", b"hash", b"%d" % (int(time.time() * 1000) + 10 ** 9)))
    # a value of 1.5 MiB, then one of 5 MiB, five windows long
    f.put(entry(b"SET", b"long:1", b"L" * (MIB + MIB // 2)))
    f.put(entry(b"SELECT", b"5"))
    f.put(entry(b"SET", b"long:5", b"0123456789abcdef" * (5 * MIB // 16)))
    f.put(entry(b"APPEND", b"long:5", b"!"))
    # a transaction that holds a value of 1.25 MiB, across windows
    f.put(entry(b"MULTI"))
    f.put(entry(b"SET", b"tx:long", b"T" * (MIB + MIB // 4)))
    f.put(entry(b"SADD", b"set", b"x", b"y"))
    f.put(entry(b"EXEC"))
    for i in range(2000):
        f.put(entry(b"SET", b"tail:%d" % i, b"t" * (i % 50)))
    f.put(entry(b"DEL", b"tail:7", b"pad:5"))
    return f.bytes(), f.entries


# why each server refuses a file that ends unexpectedly
EOF_WHY = ("Unexpected end of file reading the append only file",) * 2


def cases():
    """each case: its name, the file, the length of its whole entries
    both cut it to (None: they cut it to different lengths), and what
    Redis and BendKV say when they refuse it"""
    b, n = base()
    cut = entry(b"SET", b"lost", b"y" * (3 * MIB))[:-(MIB + 7)]
    opened = entry(b"MULTI") + entry(b"SET", b"open:a", b"1") + entry(b"SET", b"open:long", b"o" * (2 * MIB)) + \
        entry(b"SET", b"open:b", b"2")
    bad = entry(b"SXT", b"lost", b"v") + entry(b"SET", b"after", b"x")
    # entries written as Redis reads them but not as it writes them, in a
    # transaction left open: the file is cut at the byte its MULTI starts
    # at, whatever the entries' lengths written again would be. Empty
    # bulks with no length ("$" alone: strtol reads 0), and a MULTI whose
    # count has a leading 0 (atoi)
    loose = entry(b"SET", b"k1", b"v") + entry(b"SET", b"k2", b"v")
    loose_tx = entry(b"MULTI") + b"*30\r\n$5\r\nRPUSH\r\n$1\r\nl\r\n" + b"$\r\n\r\n" * 28
    zero = entry(b"SET", b"k", b"v")
    zero_tx = b"*01\r\n$5\r\nMULTI\r\n" + entry(b"SET", b"x", b"y")
    # an entry that ends exactly at the first window's end
    e = File()
    e.pad(MIB)
    e.put(entry(b"SET", b"edge", b"e"))
    edge = e.bytes()
    return [("a file of several windows, ending inside one", b, len(b), EOF_WHY),
            ("its last entry cut short inside a long value", b + cut, len(b), EOF_WHY),
            ("a transaction left open, an entry longer than a window in it", b + opened, len(b), EOF_WHY),
            ("a transaction left open, then an entry cut short", b + opened + cut, None, EOF_WHY),
            ("an unknown command after it", b + bad, None,
             ("Unknown command 'SXT' reading the append only file",
              "Bad command reading the append only file appendonly.aof: entry %d, at byte %d: ERR unknown command 'SXT'"
              % (n + 1, len(b)))),
            ("bulks with no length in a transaction left open", loose + loose_tx, len(loose), EOF_WHY),
            ("a MULTI written *01 left open", zero + zero_tx, len(zero), EOF_WHY),
            ("an entry that ends at the first window's end", edge, len(edge), EOF_WHY)]


def up(port, p, log, timeout=60):
    """a connection once the server answers PONG (Redis answers LOADING
    while it reads its file), or None once it has exited"""
    t = time.time() + timeout
    while time.time() < t:
        if p.poll() is not None:
            return None
        try:
            c = Conn(port)
            c.send([[b"PING"]])
            if c.reply() == (b"+", b"PONG"):
                return c
        except (OSError, EOFError):
            pass
        time.sleep(0.05)
    p.kill()
    sys.exit("FAIL: no server on port %d (%s)" % (port, log))


def size(path):
    """the file's length, where the server keeps it: Redis 7 takes an old
    file in as the base of a directory of files of its own"""
    moved = os.path.join(os.path.dirname(path), "appendonlydir", os.path.basename(path))
    return os.path.getsize(moved if os.path.exists(moved) else path)


def run(argv, port, log, path, dbs):
    """a start on the file at path: (whether it started, its databases,
    the file's length after it, its log)"""
    with open(log, "w") as out:
        p = subprocess.Popen(argv, stdout=out, stderr=subprocess.STDOUT)
    c = up(port, p, log)
    ks = None
    if c is not None:
        ks = keyspace(c, dbs)
        c.sock.close()
    if p.poll() is None:
        p.terminate()
    p.wait()
    with open(log, errors="replace") as f:
        text = f.read()
    return c is not None, ks, size(path), text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default="build/bendkv")
    ap.add_argument("--bendkv", type=int, default=6380)
    ap.add_argument("--redis", type=int, default=6391)
    ap.add_argument("--dir", default="build/aofwin")
    a = ap.parse_args()
    d = os.path.abspath(a.dir)
    ok = True
    for i, (name, data, keep, why) in enumerate(cases()):
        for trunc in ["yes", "no"]:
            got = {}
            for who in ["redis", "bendkv"]:
                w = os.path.join(d, "%d-%s-%s" % (i, trunc, who))
                shutil.rmtree(w, ignore_errors=True)
                os.makedirs(w)
                path = os.path.join(w, "appendonly.aof")
                with open(path, "wb") as f:
                    f.write(data)
                if who == "redis":
                    argv = ["redis-server", "--port", str(a.redis), "--bind", "127.0.0.1", "--save", "",
                            "--dir", w, "--appendonly", "yes", "--appendfilename", "appendonly.aof",
                            "--aof-load-truncated", trunc]
                    got[who] = run(argv, a.redis, os.path.join(w, "log"), path, 16)
                else:
                    argv = [a.bin, "--port", str(a.bendkv), "--dir", w, "--appendonly", "yes",
                            "--appendfilename", "appendonly.aof", "--aof-load-truncated", trunc]
                    got[who] = run(argv, a.bendkv, os.path.join(w, "log"), path, 16)
            (rs, rk, rz, rt), (bs, bk, bz, bt) = got["redis"], got["bendkv"]
            what = "%s, aof-load-truncated %s" % (name, trunc)
            if rs != bs:
                print("FAIL: %s: Redis %s, BendKV %s" % (what, "starts" if rs else "refuses", "starts" if bs else "refuses"))
                print("  Redis: %s\n  BendKV: %s" % (rt.strip().splitlines()[-1:], bt.strip().splitlines()[-1:]))
                ok = False
            elif not rs:
                said = why[0] in rt and why[1] in bt
                print("%s: %s: both refuse%s" % ("OK" if said else "FAIL", what, "" if said else
                      ", not saying why: %r, %r" % (rt.strip().splitlines()[-1:], bt.strip().splitlines()[-1:])))
                ok &= said
            elif rk != bk:
                print("FAIL: %s: the databases differ (%d keys on Redis, %d on BendKV)" % (what, len(rk), len(bk)))
                ok = False
            elif keep is not None and not rz == bz == keep:
                print("FAIL: %s: the file is cut to %d bytes by Redis, %d by BendKV, of %d whole" % (what, rz, bz, keep))
                ok = False
            else:
                print("OK: %s: the same databases (%d keys), the file %s" % (
                    what, len(bk), "cut to %d bytes on both" % bz if keep is not None and bz < len(data)
                    else "kept whole" if bz == len(data) else "cut to %d bytes by BendKV, %d by Redis" % (bz, rz)))
    print("ALL OK" if ok else "SOME CHECKS FAILED")
    return ok


if __name__ == "__main__":
    raise SystemExit(0 if main() else 1)
