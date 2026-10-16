#!/usr/bin/env python3
"""BGREWRITEAOF against Redis 7.0.15: what it answers and what it writes.

The replies and INFO's account, as scenarios on BendKV and on a
redis-server with its append-only file on, their transcripts compared
line by line: a rewrite started and one refused while it runs, in one
pipeline; one asked for in EXEC, which Redis schedules (the cron starts
it) and INFO shows scheduled; one started and another asked for in EXEC
while it runs; the arguments it refuses, alone and in MULTI; CONFIG
RESETSTAT; the call's statistics and its errors.

The file: the same databases on both (strings, lists, sets of numbers and
of words, hashes, sorted sets with scores of each form, small and past 64
elements, times to expire at, keys in several databases), both rewrite
their files, and BendKV's holds what Redis's base holds, command for
command: a SELECT of each database with keys, a key's SET, RPUSH, SADD,
HMSET or ZADD (64 elements or pairs to a command, scores as %.17g
writes them) and its PEXPIREAT; the elements of a set, a hash and a
sorted set in any order. BendKV started from its rewritten file, and
Redis from it, hold the databases.

Writes while a rewrite runs: many keys, so that it takes a while, a
rewrite, and then writes of each kind on several databases (SWAPDB,
MOVE, COPY, RENAME, transactions, FLUSHDB) sent to BendKV and to Redis
while it runs, more once it ended; BendKV's databases are Redis's, and so
are those of BendKV started from the new file, and of Redis started from
it. Then the same with BendKV killed (SIGKILL) while a rewrite runs, the
writes acknowledged: started again, from its file as it was, it holds
them all.

And BendKV alone: with appendonly no, BGREWRITEAOF writes appendfilename
all the same (with streams RESTOREd from Redis's payloads, which it
writes as RESTOREs), which a server with appendonly yes then reads; the cron's
rewrites as the file grows (auto-aof-rewrite-percentage,
auto-aof-rewrite-min-size), with the size after a rewrite as the base
the growth is measured from; and a rewrite that fails (its temporary
file cannot be made: a directory has its name), counted and logged, the
file as it was, three failures in a row holding the cron's rewrites back
a minute (logged), a rewrite scheduled in EXEC starting all the same.

    python3 tests/rewrite_test.py --bin build/bendkv --bendkv 6380 --redis 6391 --dir build/rewrite
"""
import argparse
import os
import random
import shutil
import signal
import subprocess
import sys
import time

from aof_redis_test import redis, same, start, stop
from aof_test import value
from diff_test import Conn

# times far away and absolute, so that both servers set the same ones
T = int(time.time() * 1000) + 10**9

# the DEL that the sweep of expired keys appends for the key gone (fill)
# after a rewrite started, which selects the database again
GONE = b"*2\r\n$6\r\nSELECT\r\n$2\r\n15\r\n*2\r\n$3\r\nDEL\r\n$4\r\ngone\r\n"


def cmd(c, *args):
    c.send([list(args)])
    return c.reply()


def info(c, section=b"persistence"):
    kind, text = cmd(c, b"INFO", section)
    return dict(l.split(":", 1) for l in text.decode().split("\r\n") if ":" in l)


# the rewrite over, and none scheduled
def settle(c, tries=1200):
    for _ in range(tries):
        i = info(c)
        if i["aof_rewrite_in_progress"] == "0" and i["aof_rewrite_scheduled"] == "0":
            return i
        time.sleep(0.025)
    sys.exit("FAIL: the rewrite does not end")


class Fast(Conn):
    """A connection that reads its replies where they lie in its buffer
    (Conn's split copies the rest of the buffer at each line: a reply of
    a hundred thousand keys would take minutes)."""

    def __init__(self, port):
        super().__init__(port)
        self.buf = bytearray()
        self.pos = 0

    def _fill(self):
        data = self.sock.recv(1 << 20)
        if not data:
            raise EOFError("connection closed")
        if self.pos > (1 << 20):
            del self.buf[:self.pos]
            self.pos = 0
        self.buf += data

    def _line(self):
        while True:
            j = self.buf.find(b"\r\n", self.pos)
            if j >= 0:
                break
            self._fill()
        line = bytes(self.buf[self.pos:j])
        self.pos = j + 2
        return line

    def _exact(self, n):
        while len(self.buf) - self.pos < n + 2:
            self._fill()
        data = bytes(self.buf[self.pos:self.pos + n])
        self.pos += n + 2
        return data


# the keys of 16 databases, each with its value and the time it expires
# at, read a thousand at a time; a set's and a sorted set's encoding left
# out (a rewrite makes them again as their sizes say, as Redis does)
def keyspace(port, dbs=16):
    c = Fast(port)
    out = []
    for db in range(dbs):
        c.send([[b"SELECT", b"%d" % db], [b"KEYS", b"*"]])
        c.reply()
        kind, items = c.reply()
        keys = sorted(data for kind, data in items)
        for i in range(0, len(keys), 1000):
            ks = keys[i:i + 1000]
            c.send([[b"MGET"] + ks])
            kind, vals = c.reply()
            c.send([[b"PEXPIRETIME", k] for k in ks])
            times = [c.reply()[1] for k in ks]
            for k, v, t in zip(ks, vals, times):
                x = value(c, k, v)
                if x.startswith("set:") or x.startswith("zset:"):
                    kind, enc, rest = x.split(":", 2)
                    x = kind + ":" + rest
                out.append((db, k.hex(), x, t.decode()))
    c.sock.close()
    return out


# Replies and INFO
# ----------------

FIELDS = ["aof_rewrite_in_progress", "aof_rewrite_scheduled", "aof_last_rewrite_time_sec",
          "aof_current_rewrite_time_sec", "aof_last_bgrewrite_status", "aof_rewrites",
          "aof_rewrites_consecutive_failures", "aof_pending_rewrite"]


# INFO's fields of the rewrite (the seconds a rewrite took, or has run, 0
# or 1 as a second's edge falls), the call's statistics without its
# times, and the count of ERR
def show_info(text):
    d = dict(l.split(":", 1) for l in text.decode().split("\r\n") if ":" in l)
    out = []
    for f in FIELDS:
        if f in d:
            v = d[f]
            if f in ("aof_last_rewrite_time_sec", "aof_current_rewrite_time_sec") and v in ("0", "1"):
                v = "0|1"
            out.append("%s:%s" % (f, v))
    if "cmdstat_bgrewriteaof" in d:
        out.append("cmdstat_bgrewriteaof:" + ",".join(x for x in d["cmdstat_bgrewriteaof"].split(",") if "usec" not in x))
    if "errorstat_ERR" in d:
        out.append("errorstat_ERR:" + d["errorstat_ERR"])
    return " ".join(out)


def show(r):
    kind, data = r
    if kind == b"*":
        return "[" + ", ".join(show(x) for x in data) + "]" if data is not None else "*nil"
    if kind == b"$" and data is not None and data.startswith(b"# "):
        return show_info(data)
    return (kind + (data if data is not None else b"nil")).decode()


INFO = [b"INFO", b"persistence"]
STATS = [b"INFO", b"commandstats", b"errorstats"]

# each a pipeline, then a wait until no rewrite runs or is scheduled
SCENARIOS = [
    ("started, then refused while it runs", [[b"BGREWRITEAOF"], [b"BGREWRITEAOF"], INFO]),
    ("once it ended", [INFO]),
    ("asked for in EXEC: scheduled", [[b"MULTI"], [b"BGREWRITEAOF"], [b"BGREWRITEAOF"], [b"EXEC"], INFO]),
    ("the scheduled one ran", [INFO]),
    ("in EXEC while one runs", [[b"BGREWRITEAOF"], [b"MULTI"], [b"BGREWRITEAOF"], [b"EXEC"], INFO]),
    ("once it ended", [INFO]),
    ("arguments refused", [[b"BGREWRITEAOF", b"now"], [b"bgrewriteaof", b"x", b"y"], INFO]),
    ("arguments refused in MULTI", [[b"MULTI"], [b"BGREWRITEAOF", b"x"], [b"EXEC"]]),
    ("lower case", [[b"bgrewriteaof"], INFO]),
    ("CONFIG RESETSTAT", [[b"CONFIG", b"RESETSTAT"], INFO]),
    ("after RESETSTAT", [[b"BGREWRITEAOF"], [b"BGREWRITEAOF"], [b"MULTI"], [b"BGREWRITEAOF"], [b"EXEC"]]),
    ("the statistics", [STATS, INFO]),
]


def scenarios(c):
    lines = []
    for name, pipe in SCENARIOS:
        c.send(pipe)
        lines.append("== " + name)
        for x in pipe:
            lines.append("%s -> %s" % (b" ".join(x).decode(), show(c.reply())))
        settle(c)
    return lines


def compare(what, a, b):
    bad = [(x, y) for x, y in zip(a, b) if x != y]
    if bad or len(a) != len(b):
        print("FAIL: %s" % what)
        for x, y in bad[:10]:
            print("  Redis:  %s\n  BendKV: %s" % (x, y))
        sys.exit(1)
    print("OK: %s (%d lines)" % (what, len(a)))


# The file
# --------

SCORES = [b"0", b"1", b"-1", b"1.5", b"0.1", b"-0.25", b"1e-300", b"3.14159e100", b"inf", b"-inf",
          b"123456789012", b"0.30000000000000004", b"-2.5e-5", b"7"]


# the databases both get: each kind of value, small and past 64 elements,
# some with times to expire at, on databases 0, 3 and 15
def fill(r):
    out = []
    out.append([b"SELECT", b"0"])
    for i in range(30):
        out.append([b"SET", b"s%d" % i, b"v%d" % i] + ([b"PXAT", b"%d" % (T + i)] if i % 4 == 0 else []))
    out.append([b"SET", b"empty", b""])
    out.append([b"SET", b"bin", bytes(range(256))])
    out.append([b"SET", b"big", b"x" * 100000])
    out.append([b"RPUSH", b"l1", b"a", b"b", b"c"])
    out.append([b"RPUSH", b"l2"] + [b"%d" % i if i % 3 else b"e%d" % i for i in range(150)])
    out.append([b"LPUSH", b"l3"] + [b"%d" % i for i in range(64)])
    out.append([b"PEXPIREAT", b"l2", b"%d" % (T + 100)])
    out.append([b"SADD", b"si", b"1", b"2", b"3"])
    out.append([b"SADD", b"si2"] + [b"%d" % (i * 7) for i in range(200)])
    out.append([b"SADD", b"ss"] + [b"m%d" % i for i in range(130)])
    out.append([b"SADD", b"ss64"] + [b"w%d" % i for i in range(64)])
    out.append([b"HSET", b"h1", b"f", b"v", b"g", b""])
    out.append([b"HSET", b"h2"] + [x for i in range(65) for x in (b"f%d" % i, b"v%d" % i)])
    out.append([b"HSET", b"h3"] + [x for i in range(300) for x in (b"k%d" % i, b"%d" % (i * i))])
    out.append([b"PEXPIREAT", b"h3", b"%d" % (T + 200)])
    out.append([b"ZADD", b"z1"] + [x for i, s in enumerate(SCORES) for x in (s, b"m%d" % i)])
    out.append([b"ZADD", b"z2"] + [x for i in range(200) for x in (b"%d.%d" % (i % 13, i), b"n%d" % i)])
    out.append([b"ZADD", b"z3"] + [x for i in range(64) for x in (b"0", b"same%d" % i)])
    out.append([b"ZINCRBY", b"z1", b"0.1", b"m4"])
    out.append([b"PEXPIREAT", b"z2", b"%d" % (T + 300)])
    out.append([b"SELECT", b"3"])
    out.append([b"SET", b"k3", b"v3"])
    out.append([b"RPUSH", b"l", b"x"])
    out.append([b"SELECT", b"15"])
    out.append([b"HSET", b"h15", b"a", b"b"])
    out.append([b"SET", b"gone", b"x", b"PX", b"1"])
    out.append([b"SELECT", b"0"])
    r.send(out)
    for _ in out:
        rep = r.reply()
        if rep[0] == b"-":
            sys.exit("FAIL: the fill was refused: %r" % (rep,))


def entries(data):
    i, out = 0, []
    while i < len(data):
        if data[i:i + 1] != b"*":
            sys.exit("FAIL: not an entry at byte %d of a rewritten file" % i)
        j = data.index(b"\r\n", i)
        n = int(data[i + 1:j])
        i = j + 2
        args = []
        for _ in range(n):
            j = data.index(b"\r\n", i)
            ln = int(data[i + 1:j])
            i = j + 2
            args.append(data[i:i + ln])
            i += ln + 2
        out.append(args)
    return out


# a rewritten file, command for command, as one description per key: its
# commands (their names and how many elements or pairs each holds), its
# elements (a list's in order, a set's, a hash's and a sorted set's
# sorted), its time; and the databases selected
def describe(es):
    db, keys, sels = None, {}, []
    for e in es:
        name = e[0].upper()
        if name == b"SELECT":
            db = int(e[1])
            sels.append(db)
            continue
        k = (db, e[1])
        d = keys.setdefault(k, {"cmds": [], "items": [], "exp": None})
        if name == b"PEXPIREAT":
            d["exp"] = e[2]
            continue
        args = e[2:]
        if name in (b"HMSET", b"ZADD"):
            pairs = list(zip(args[0::2], args[1::2]))
            d["cmds"].append((name, len(pairs)))
            d["items"] += pairs
        else:
            d["cmds"].append((name, len(args)))
            d["items"] += args
    for k, d in keys.items():
        if d["cmds"] and d["cmds"][0][0] in (b"SADD", b"HMSET", b"ZADD"):
            d["items"] = sorted(d["items"])
    return keys, sels


def redis_base(rdir):
    parts = os.path.join(rdir, "appendonlydir")
    with open(os.path.join(parts, "appendonly.aof.manifest")) as f:
        for line in f:
            w = line.split()
            if w[-1] == "b":
                with open(os.path.join(parts, w[1]), "rb") as g:
                    return g.read()
    sys.exit("FAIL: no base in Redis's manifest")


# Redis writes a key whose time has passed and that it has not yet
# deleted, with its time; BendKV leaves it out: such keys are taken out of
# Redis's file
def same_files(redis_file, bendkv_file):
    kr, sr = describe(entries(redis_file))
    kb, sb = describe(entries(bendkv_file))
    now = int(time.time() * 1000)
    kr = {k: d for k, d in kr.items() if d["exp"] is None or int(d["exp"]) > now}
    sr = [j for j in sr if any(k[0] == j for k in kr)]
    if sorted(set(sr)) != sorted(set(sb)) or len(sr) != len(set(sr)) or len(sb) != len(set(sb)):
        sys.exit("FAIL: the databases selected: Redis %r, BendKV %r" % (sr, sb))
    if kr != kb:
        print("FAIL: the rewritten files differ")
        for k in sorted(set(kr) | set(kb), key=repr):
            if kr.get(k) != kb.get(k):
                print("  %r\n    Redis:  %r\n    BendKV: %r" % (k, kr.get(k), kb.get(k)))
                break
        sys.exit(1)
    n = sum(len(d["cmds"]) + (d["exp"] is not None) for d in kb.values())
    print("OK: BendKV's rewritten file holds Redis's base, command for command (%d keys, %d commands)" % (len(kb), n))


# Writes while a rewrite runs
# ---------------------------

def bulk(r, n, prefix=b"key"):
    for i in range(0, n, 1000):
        args = [b"MSET"]
        for j in range(i, min(i + 1000, n)):
            args += [b"%s:%d" % (prefix, j), b"value-%d-%s" % (j, b"x" * (j % 17))]
        r.send([args])
    for i in range(0, n, 1000):
        r.reply()


# a pipeline of writes of each kind, the same for both servers (seeded),
# on databases 0 to 3 and 7
def writes(rnd, n, nkeys):
    out = []
    for _ in range(n):
        x = rnd.random()
        k = b"key:%d" % rnd.randrange(nkeys)
        c = rnd.randrange(50)
        if x < 0.2:
            out.append([b"SET", k, b"new-%d" % rnd.randrange(10**6)])
        elif x < 0.3:
            out.append([b"DEL", k])
        elif x < 0.38:
            out.append([b"INCR", b"cnt:%d" % c])
        elif x < 0.45:
            out.append([b"RPUSH", b"list:%d" % c, b"%d" % rnd.randrange(1000)])
        elif x < 0.5:
            out.append([b"LPOP", b"list:%d" % c])
        elif x < 0.57:
            out.append([b"HSET", b"hash:%d" % c, b"f%d" % rnd.randrange(100), b"v%d" % rnd.randrange(100)])
        elif x < 0.62:
            out.append([b"SADD", b"set:%d" % c, b"%d" % rnd.randrange(300)])
        elif x < 0.66:
            out.append([b"SREM", b"set:%d" % c, b"%d" % rnd.randrange(300)])
        elif x < 0.72:
            out.append([b"ZADD", b"zset:%d" % c, b"%d.5" % rnd.randrange(100), b"m%d" % rnd.randrange(100)])
        elif x < 0.76:
            out.append([b"PEXPIREAT", k, b"%d" % (T + rnd.randrange(10**6))])
        elif x < 0.78:
            out.append([b"PERSIST", k])
        elif x < 0.81:
            out.append([b"APPEND", k, b"+"])
        elif x < 0.84:
            j = b"%d" % rnd.randrange(1, 4)
            out += [[b"SELECT", j], [b"SET", b"db:%d" % c, j], [b"RPUSH", b"dl:%d" % c, j], [b"SELECT", b"0"]]
        elif x < 0.86:
            out.append([b"SWAPDB", b"%d" % rnd.randrange(1, 4), b"%d" % rnd.randrange(1, 4)])
        elif x < 0.88:
            out.append([b"MOVE", k, b"%d" % rnd.randrange(1, 4)])
        elif x < 0.9:
            out.append([b"COPY", k, b"copy:%d" % c, b"DB", b"%d" % rnd.randrange(0, 4), b"REPLACE"])
        elif x < 0.92:
            out.append([b"RENAME", b"cnt:%d" % c, b"cnt:%d" % rnd.randrange(50)])
        elif x < 0.96:
            out += [[b"MULTI"], [b"INCRBY", b"cnt:%d" % c, b"10"], [b"SET", k, b"tx"],
                    [b"HINCRBY", b"hash:%d" % c, b"n", b"1"], [b"EXEC"]]
        elif x < 0.98:
            out += [[b"SELECT", b"7"], [b"SET", b"w%d" % c, b"x"], [b"SELECT", b"0"]]
        else:
            out += [[b"SELECT", b"7"], [b"FLUSHDB"], [b"SELECT", b"0"]]
    return out


def both(rs, cmds):
    for r in rs:
        r.send(cmds)
    reps = [[r.reply() for _ in cmds] for r in rs]
    if len(rs) == 2:
        for x, a, b in zip(cmds, reps[0], reps[1]):
            if a != b:
                sys.exit("FAIL: %r answered %r by Redis, %r by BendKV" % (x, a, b))
    return reps


def bendkv(a, f, sync, log, cwd=None):
    argv = [os.path.abspath(a.bin), str(a.bendkv), "send"] + ([f, sync] if f else [])
    p = subprocess.Popen(argv, stdout=open(log, "w"), stderr=subprocess.STDOUT, cwd=cwd)
    for _ in range(200):
        try:
            c = Conn(a.bendkv)
            c.send([[b"PING"]])
            if c.reply() == (b"+", b"PONG"):
                return p, c
        except (OSError, EOFError):
            pass
        time.sleep(0.05)
    p.kill()
    sys.exit("FAIL: no BendKV on port %d (%s)" % (a.bendkv, log))


def logged(log, text):
    with open(log) as f:
        return text in f.read()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default="build/bendkv")
    ap.add_argument("--bendkv", type=int, default=6380)
    ap.add_argument("--redis", type=int, default=6391)
    ap.add_argument("--dir", default="build/rewrite")
    ap.add_argument("--keys", type=int, default=150000)
    a = ap.parse_args()
    d = os.path.abspath(a.dir)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    sub = lambda *p: os.path.join(d, *p)

    # the replies and INFO's account, and the files of the same databases
    for x in ["redis", "bendkv", "rload"]:
        os.makedirs(sub(x))
    pr, cr = start(redis(a.redis, sub("redis"), "--aof-use-rdb-preamble", "no", "--auto-aof-rewrite-percentage", "0"),
                   a.redis, sub("redis.log"))
    pb, cb = bendkv(a, sub("bendkv", "bendkv.aof"), "always", sub("bendkv.log"))
    try:
        cmd(cb, b"CONFIG", b"SET", b"auto-aof-rewrite-percentage", b"0")
        compare("BGREWRITEAOF's replies and INFO's account as Redis's", scenarios(cr), scenarios(cb))
        cr.send([[b"FLUSHALL"]])
        cb.send([[b"FLUSHALL"]])
        cr.reply(), cb.reply()
        expired = int(info(cb, b"stats")["expired_keys"])
        fill(cr)
        fill(cb)
        time.sleep(0.01)
        kr, kb = keyspace(a.redis), keyspace(a.bendkv)
        same("the same databases on both", kr, kb)
        for c in (cr, cb):
            if cmd(c, b"BGREWRITEAOF") != (b"+", b"Background append only file rewriting started"):
                sys.exit("FAIL: BGREWRITEAOF did not start")
            settle(c)
        # the key gone, whose time passed as it was set, is deleted by the
        # sweep of expired keys when it comes to it: before the rewrite,
        # while it runs (its DEL is then the last entry the rewrite writes,
        # after the databases) or after it (its DEL follows the rewritten
        # file); nothing more is appended once it is counted
        for _ in range(400):
            if int(info(cb, b"stats")["expired_keys"]) > expired:
                break
            time.sleep(0.025)
        else:
            sys.exit("FAIL: the sweep does not delete the key gone")
        i = info(cb)
        with open(sub("bendkv", "bendkv.aof"), "rb") as f:
            data = f.read()
        base = int(i["aof_base_size"])
        if i["aof_last_bgrewrite_status"] != "ok" or int(i["aof_current_size"]) != len(data) or data[base:] not in (b"", GONE):
            sys.exit("FAIL: after the rewrite, %r: the file has %d bytes, after its base %r"
                     % (i, len(data), data[base:base + 200]))
        print("OK: after the rewrite INFO's aof_base_size is the size of the file it wrote (%d bytes) "
              "and aof_current_size the file's" % base)
        rewritten = data[:base]
        if rewritten.endswith(GONE):
            rewritten = rewritten[:-len(GONE)]
        same_files(redis_base(sub("redis")), rewritten)
    finally:
        stop(pr)
        stop(pb)
    pb, cb = bendkv(a, sub("bendkv", "bendkv.aof"), "always", sub("bendkv2.log"))
    try:
        k = keyspace(a.bendkv)
    finally:
        stop(pb)
    same("BendKV restores the databases from its rewritten file", k, kb)
    shutil.copy(sub("bendkv", "bendkv.aof"), sub("rload", "appendonly.aof"))
    p, c = start(redis(a.redis, sub("rload"), "--appendfilename", "appendonly.aof"), a.redis, sub("rload.log"))
    try:
        k = keyspace(a.redis)
    finally:
        stop(p)
    same("Redis restores the databases from BendKV's rewritten file", k, kb)

    # writes while a rewrite runs, then more after it
    for x in ["redis2", "bendkv2", "rload2"]:
        os.makedirs(sub(x))
    pr, cr = start(redis(a.redis, sub("redis2"), "--appendfsync", "no"), a.redis, sub("redis2.log"))
    pb, cb = bendkv(a, sub("bendkv2", "bendkv.aof"), "everysec", sub("bendkv3.log"))
    rnd = random.Random(11)
    try:
        cmd(cb, b"CONFIG", b"SET", b"auto-aof-rewrite-percentage", b"0")
        both([cr, cb], [[b"FLUSHALL"]])
        bulk(cr, a.keys)
        bulk(cb, a.keys)
        both([cr, cb], writes(rnd, 2000, a.keys))
        cb.send([[b"BGREWRITEAOF"], INFO])
        cb.reply()
        if info_of(cb.reply())["aof_rewrite_in_progress"] != "1":
            sys.exit("FAIL: no rewrite in progress after BGREWRITEAOF")
        rounds = 0
        while True:
            both([cr, cb], writes(rnd, 200, a.keys))
            rounds += 1
            if info(cb)["aof_rewrite_in_progress"] == "0":
                break
        i = settle(cb)
        if i["aof_last_bgrewrite_status"] != "ok":
            sys.exit("FAIL: the rewrite failed: %r" % i)
        print("OK: %d pipelines of 200 writes while the rewrite ran" % rounds)
        if rounds < 3:
            sys.exit("FAIL: the rewrite ended before the writes could reach it (%d pipelines)" % rounds)
        both([cr, cb], writes(rnd, 2000, a.keys))
        kr, kb = keyspace(a.redis), keyspace(a.bendkv)
        same("BendKV's databases are Redis's after writes during and after a rewrite", kr, kb)
    finally:
        stop(pr)
        stop(pb)
    pb, cb = bendkv(a, sub("bendkv2", "bendkv.aof"), "everysec", sub("bendkv4.log"))
    try:
        k = keyspace(a.bendkv)
    finally:
        stop(pb)
    same("BendKV restores them from the rewritten file", k, kr)
    shutil.copy(sub("bendkv2", "bendkv.aof"), sub("rload2", "appendonly.aof"))
    p, c = start(redis(a.redis, sub("rload2"), "--appendfilename", "appendonly.aof"), a.redis, sub("rload2.log"))
    try:
        k = keyspace(a.redis)
    finally:
        stop(p)
    same("Redis restores them from BendKV's rewritten file", k, kr)

    # killed while a rewrite runs: the file as it was holds every write
    # acknowledged
    for x in ["redis3", "bendkv3"]:
        os.makedirs(sub(x))
    pr, cr = start(redis(a.redis, sub("redis3"), "--appendfsync", "no"), a.redis, sub("redis3.log"))
    pb, cb = bendkv(a, sub("bendkv3", "bendkv.aof"), "always", sub("bendkv5.log"))
    try:
        cmd(cb, b"CONFIG", b"SET", b"auto-aof-rewrite-percentage", b"0")
        bulk(cr, a.keys)
        bulk(cb, a.keys)
        cb.send([[b"BGREWRITEAOF"]])
        cb.reply()
        both([cr, cb], writes(rnd, 300, a.keys))
        running = info(cb)["aof_rewrite_in_progress"] == "1"
        pid = info(cb, b"server")["process_id"]
        pb.send_signal(signal.SIGKILL)
        pb.wait()
        kr = keyspace(a.redis)
    finally:
        stop(pr)
        if pb.poll() is None:
            stop(pb)
    if not running:
        sys.exit("FAIL: the rewrite ended before the kill")
    tmp = sub("bendkv3", "temp-rewriteaof-bg-%s.aof" % pid)
    print("OK: killed while the rewrite ran (the temporary file %s)" % ("left" if os.path.exists(tmp) else "gone"))
    pb, cb = bendkv(a, sub("bendkv3", "bendkv.aof"), "always", sub("bendkv6.log"))
    try:
        k = keyspace(a.bendkv)
        if cmd(cb, b"BGREWRITEAOF")[0] != b"+" or settle(cb)["aof_last_bgrewrite_status"] != "ok":
            sys.exit("FAIL: no rewrite after the restart")
    finally:
        stop(pb)
    same("BendKV killed while a rewrite ran restores every write acknowledged", k, kr)

    # a stream, which BendKV, having no stream command yet, RESTOREs from
    # Redis's payload, its rewrite writing it as that RESTORE
    os.makedirs(sub("rstream"))
    pr, cr = start(redis(a.redis, sub("rstream"), "--rdbcompression", "no"), a.redis, sub("rstream.log"))
    try:
        for x in ([b"XADD", b"st", b"1-1", b"f", b"v"], [b"XADD", b"st", b"1-2", b"f", b"w", b"g", b"x"],
                  [b"XGROUP", b"CREATE", b"st", b"g", b"0"], [b"XREADGROUP", b"GROUP", b"g", b"c", b"STREAMS", b"st", b">"],
                  [b"XDEL", b"st", b"1-1"]):
            cmd(cr, *x)
        stp = cmd(cr, b"DUMP", b"st")[1]
    finally:
        stop(pr)

    # appendonly no: the rewrite writes appendfilename all the same
    os.makedirs(sub("off"))
    pb, cb = bendkv(a, None, None, sub("off.log"), cwd=sub("off"))
    try:
        fill(cb)
        for x in ([b"SELECT", b"3"], [b"RESTORE", b"st", b"0", stp], [b"RESTORE", b"st2", b"%d" % T, stp, b"ABSTTL"], [b"SELECT", b"0"]):
            if cmd(cb, *x)[0] != b"+":
                sys.exit("FAIL: %r on BendKV" % (x[:2],))
        time.sleep(0.01)
        kb = keyspace(a.bendkv)
        if cmd(cb, b"BGREWRITEAOF") != (b"+", b"Background append only file rewriting started"):
            sys.exit("FAIL: BGREWRITEAOF with appendonly no did not start")
        i = settle(cb)
        if i["aof_rewrites"] != "1" or i["aof_last_bgrewrite_status"] != "ok" or "aof_current_size" in i:
            sys.exit("FAIL: with appendonly no, INFO says %r" % i)
    finally:
        stop(pb)
    if not os.path.exists(sub("off", "appendonly.aof")):
        sys.exit("FAIL: with appendonly no, no appendonly.aof")
    pb, cb = bendkv(a, sub("off", "appendonly.aof"), "always", sub("off2.log"))
    try:
        k = keyspace(a.bendkv)
    finally:
        stop(pb)
    same("with appendonly no, BGREWRITEAOF writes appendonly.aof, which a start then reads", k, kb)

    # the cron's rewrites as the file grows: past auto-aof-rewrite-min-size
    # and grown by auto-aof-rewrite-percentage (not 0) of its size after
    # its last rewrite
    os.makedirs(sub("auto"))
    f = sub("auto", "bendkv.aof")
    pb, cb = bendkv(a, f, "everysec", sub("auto.log"))

    def rewrites(n, what):
        for _ in range(40):
            i = settle(cb)
            if i["aof_rewrites"] == "%d" % n:
                return i
            time.sleep(0.05)
        sys.exit("FAIL: %s: %r" % (what, i))

    def none(n, what):
        time.sleep(0.4)
        i = settle(cb)
        if i["aof_rewrites"] != "%d" % n:
            sys.exit("FAIL: %s: %r" % (what, i))

    try:
        # writes under a minimum the file does not reach, then the minimum
        # lowered under the file's size: the cron rewrites the file at its
        # next look, and nothing is appended after the rewrite
        cmd(cb, b"CONFIG", b"SET", b"auto-aof-rewrite-min-size", b"1000000")
        cmd(cb, b"CONFIG", b"SET", b"auto-aof-rewrite-percentage", b"100")
        cb.send([[b"SET", b"a", b"%d" % j + b"x" * 40] for j in range(100)])
        for _ in range(100):
            cb.reply()
        cmd(cb, b"CONFIG", b"SET", b"auto-aof-rewrite-min-size", b"4096")
        i = rewrites(1, "no rewrite of a file grown past its minimum")
        if i["aof_current_size"] != i["aof_base_size"]:
            sys.exit("FAIL: after the cron's rewrite, %r" % i)
        if not logged(sub("auto.log"), "Starting automatic rewriting of AOF on"):
            sys.exit("FAIL: the cron's rewrite is not logged")
        base = int(i["aof_base_size"])
        cmd(cb, b"CONFIG", b"SET", b"auto-aof-rewrite-percentage", b"0")
        n = 0
        while int(info(cb)["aof_current_size"]) < max(5000, 3 * base):
            cmd(cb, b"SET", b"b%d" % n, b"y" * 40)
            n += 1
        none(1, "a rewrite with auto-aof-rewrite-percentage 0")
        size = int(info(cb)["aof_current_size"])
        grow = size * 100 // base - 100
        cmd(cb, b"CONFIG", b"SET", b"auto-aof-rewrite-percentage", b"%d" % (grow + 50))
        none(1, "a rewrite of a file grown by less than the percentage")
        # the minimum raised before the percentage is lowered: the other way
        # round, a tick of the cron between the two would find the file
        # grown past the percentage over the old minimum, and rewrite it
        cmd(cb, b"CONFIG", b"SET", b"auto-aof-rewrite-min-size", b"%d" % (size + 1000))
        cmd(cb, b"CONFIG", b"SET", b"auto-aof-rewrite-percentage", b"1")
        none(1, "a rewrite of a file under its minimum")
        cmd(cb, b"CONFIG", b"SET", b"auto-aof-rewrite-min-size", b"0")
        rewrites(2, "no rewrite of a file grown by the percentage past its minimum")
        print("OK: the cron rewrites a file past its minimum and grown by the percentage, and no other")
        k = keyspace(a.bendkv)
    finally:
        stop(pb)
    pb, cb = bendkv(a, f, "everysec", sub("auto2.log"))
    try:
        k2 = keyspace(a.bendkv)
    finally:
        stop(pb)
    same("the file the cron rewrote", k2, k)

    # a rewrite that fails: its temporary file cannot be made
    os.makedirs(sub("fail"))
    f = sub("fail", "bendkv.aof")
    pb, cb = bendkv(a, f, "always", sub("fail.log"))
    try:
        cmd(cb, b"CONFIG", b"SET", b"auto-aof-rewrite-percentage", b"0")
        fill(cb)
        pid = info(cb, b"server")["process_id"]
        block = sub("fail", "temp-rewriteaof-bg-%s.aof" % pid)
        os.makedirs(block)
        for n in range(1, 4):
            if cmd(cb, b"BGREWRITEAOF") != (b"+", b"Background append only file rewriting started"):
                sys.exit("FAIL: BGREWRITEAOF did not start")
            i = settle(cb)
            if i["aof_last_bgrewrite_status"] != "err" or i["aof_rewrites_consecutive_failures"] != "%d" % n:
                sys.exit("FAIL: after a failed rewrite, %r" % i)
            cmd(cb, b"SET", b"after%d" % n, b"x")
        if not logged(sub("fail.log"), "Background AOF rewrite terminated with error"):
            sys.exit("FAIL: the failure is not logged")
        print("OK: three rewrites that fail, counted, aof_last_bgrewrite_status:err")
        cmd(cb, b"CONFIG", b"SET", b"auto-aof-rewrite-min-size", b"0")
        cmd(cb, b"CONFIG", b"SET", b"auto-aof-rewrite-percentage", b"1")
        for _ in range(40):
            if logged(sub("fail.log"), "triggered the limit, will retry in 1 minutes"):
                break
            time.sleep(0.05)
        else:
            sys.exit("FAIL: the cron's limit after three failures is not logged")
        time.sleep(0.3)
        i = settle(cb)
        if i["aof_rewrites"] != "3":
            sys.exit("FAIL: the cron rewrote while its limit held: %r" % i)
        print("OK: three failures in a row hold the cron's rewrites back (logged)")
        cmd(cb, b"CONFIG", b"SET", b"auto-aof-rewrite-percentage", b"0")
        os.rmdir(block)
        cb.send([[b"MULTI"], [b"BGREWRITEAOF"], [b"EXEC"]])
        cb.reply(), cb.reply()
        if cb.reply() != (b"*", [(b"+", b"Background append only file rewriting scheduled")]):
            sys.exit("FAIL: BGREWRITEAOF in EXEC is not scheduled")
        for _ in range(40):
            i = settle(cb)
            if i["aof_rewrites"] == "4":
                break
            time.sleep(0.05)
        if i["aof_rewrites"] != "4" or i["aof_last_bgrewrite_status"] != "ok" or i["aof_rewrites_consecutive_failures"] != "0":
            sys.exit("FAIL: the scheduled rewrite after the failures: %r" % i)
        print("OK: a rewrite scheduled in EXEC starts despite the limit, and ends well")
        k = keyspace(a.bendkv)
    finally:
        stop(pb)
    pb, cb = bendkv(a, f, "always", sub("fail2.log"))
    try:
        k2 = keyspace(a.bendkv)
    finally:
        stop(pb)
    same("the file after rewrites that failed and one that did not", k2, k)
    print("ALL OK")


def info_of(r):
    kind, text = r
    return dict(l.split(":", 1) for l in text.decode().split("\r\n") if ":" in l)


if __name__ == "__main__":
    main()
