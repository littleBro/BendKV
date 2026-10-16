#!/usr/bin/env python3
"""maxmemory and eviction against Redis 7.0.15.

Transcripts, on BendKV and on a redis-server, compared line by line: the
commands that may take memory refused past maxmemory with noeviction
(OOM), in MULTI too (the transaction flagged, EXEC aborted, a transaction
of reads let run, DISCARD let run), with INFO's counts of the refused
calls and of the error; OBJECT IDLETIME as keys are read, written,
touched (TOUCH) and looked at without being touched (TTL, TYPE, EXISTS),
and OBJECT FREQ under an LFU policy (5 for a key made, 6 after a read,
the counter's steps with lfu-log-factor 0; a key last used under an LRU
policy, whose bits Redis reads as LFU's, 0, then 1 after a read), each
refused under the other kind of policy, and OBJECT REFCOUNT of a small
integer with an LRU policy, with maxmemory (1) and without (shared);
INFO's maxmemory and maxmemory_human up to the largest maxmemory; and
the "evicted" event of a key evicted at once by a
CONFIG SET of maxmemory (unit/pubsub.tcl).

Then Redis's own tests of the policies (unit/maxmemory.tcl, which its
suite runs only against a server it starts itself), on both: for each
policy, keys added past a limit of the memory used and 100 KB more, then
as many again, the memory stays within the limit and 4 KB; with keys
without a time, the volatile policies refuse writes (OOM) where the
allkeys ones evict; and the volatile policies evict only keys with a
time.

And BendKV alone: its log's warnings, Redis's (a maxmemory below 1 MB at
the start; a CONFIG SET below the memory used); an eviction that runs out
of time going on with no request to drive it (the memory back within the
limit, evicted_keys and the time past maxmemory counted); keys evicted
with the append-only file on, gone from the file too (a restart holds
what was left); and an eviction while a rewrite of the file runs, which
counts the keys it evicts as freed (the rewrite's snapshot holds them)
rather than evicting every key.

    python3 tests/maxmemory_test.py --bin build/bendkv --bendkv 6380 --redis 6391 --dir build/maxmemory
"""
import argparse
import os
import random
import shutil
import sys
import time

from aof_redis_test import start, stop
from diff_test import Conn


def cmd(c, *args):
    c.send([[a if isinstance(a, bytes) else str(a).encode() for a in args]])
    return c.reply()


def info(c, section=b"all"):
    kind, text = cmd(c, b"INFO", section)
    return dict(l.split(":", 1) for l in text.decode().split("\r\n") if ":" in l)


def used(c):
    return int(info(c, b"memory")["used_memory"])


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


def ok(msg):
    print("OK: " + msg)


# a transcript of steps on each server, compared line by line; a step is
# (client, args) or ("sleep", s). With phase, each server's transcript
# starts that far into a second: times of use are whole seconds (Redis's
# LRU clock, which its cron also caches for 100 ms), so that a key made
# late in a second and read 2.2 s later is 3 s idle, early in one 2
def compare(what, servers, steps, phase=None):
    outs = []
    for port in servers:
        cs = [Conn(port), Conn(port)]
        out = []
        if phase is not None:
            time.sleep((phase - time.time() % 1.0) % 1.0)
        for st in steps:
            if st[0] == "sleep":
                time.sleep(st[1])
                continue
            who, args = st
            out.append((" ".join(str(a) for a in args), cmd(cs[who], *args)))
        outs.append(out)
    a, b = outs
    for (sa, ra), (sb, rb) in zip(a, b):
        if ra != rb:
            fail("%s: %s: BendKV %r, Redis %r" % (what, sa, ra, rb))
    ok("%s (%d replies the same)" % (what, len(a)))


OOM = [
    (0, ["CONFIG", "SET", "maxmemory-policy", "noeviction"]),
    (0, ["CONFIG", "RESETSTAT"]),
    (0, ["SET", "a", "1"]),
    (0, ["CONFIG", "SET", "maxmemory", "1"]),
    (0, ["SET", "b", "2"]),
    (0, ["GET", "a"]),
    (0, ["DEL", "a"]),
    (0, ["INCR", "a"]),
    (0, ["LPUSH", "l", "x"]),
    (0, ["EXISTS", "a"]),
    (0, ["MULTI"]),
    (0, ["SET", "c", "3"]),
    (0, ["GET", "c"]),
    (0, ["EXEC"]),
    (0, ["MULTI"]),
    (0, ["GET", "c"]),
    (0, ["EXEC"]),
    (0, ["CONFIG", "SET", "maxmemory", "0"]),
    (0, ["MULTI"]),
    (0, ["SET", "c", "3"]),
    (1, ["CONFIG", "SET", "maxmemory", "1"]),
    (0, ["EXEC"]),
    (0, ["MULTI"]),
    (0, ["GET", "c"]),
    (0, ["DISCARD"]),
    (0, ["MULTI"]),
    (1, ["CONFIG", "SET", "maxmemory", "0"]),
    (0, ["PING"]),
    (1, ["CONFIG", "SET", "maxmemory", "1"]),
    (0, ["EXEC"]),
    (0, ["CONFIG", "SET", "maxmemory", "0"]),
    (0, ["DEL", "a", "l", "c"]),
]

ACCESS = [
    (0, ["FLUSHALL"]),
    (0, ["CONFIG", "SET", "maxmemory-policy", "noeviction"]),
    (0, ["SET", "foo", "bar"]),
    (0, ["OBJECT", "IDLETIME", "foo"]),
    (0, ["OBJECT", "FREQ", "foo"]),
    ("sleep", 2.2),
    (0, ["TTL", "foo"]),
    (0, ["TYPE", "foo"]),
    (0, ["EXISTS", "foo"]),
    (0, ["OBJECT", "IDLETIME", "foo"]),
    (0, ["GET", "foo"]),
    (0, ["OBJECT", "IDLETIME", "foo"]),
    ("sleep", 1.1),
    (0, ["TOUCH", "foo"]),
    (0, ["OBJECT", "IDLETIME", "foo"]),
    (0, ["OBJECT", "IDLETIME", "nokey"]),
    (0, ["CONFIG", "SET", "maxmemory-policy", "allkeys-lfu"]),
    (0, ["OBJECT", "IDLETIME", "foo"]),
    (0, ["OBJECT", "FREQ", "foo"]),
    (0, ["GET", "foo"]),
    (0, ["OBJECT", "FREQ", "foo"]),
    (0, ["SET", "bar", "x"]),
    (0, ["OBJECT", "FREQ", "bar"]),
    (0, ["GET", "bar"]),
    (0, ["OBJECT", "FREQ", "bar"]),
    (0, ["OBJECT", "FREQ", "nokey"]),
    (0, ["CONFIG", "SET", "lfu-log-factor", "0"]),
    (0, ["GET", "bar"]),
    (0, ["GET", "bar"]),
    (0, ["GET", "bar"]),
    (0, ["OBJECT", "FREQ", "bar"]),
    (0, ["CONFIG", "SET", "lfu-log-factor", "10"]),
    (0, ["CONFIG", "SET", "maxmemory-policy", "allkeys-lru"]),
    (0, ["OBJECT", "FREQ", "bar"]),
    (0, ["CONFIG", "SET", "maxmemory", "1000000000"]),
    (0, ["SET", "n", "100"]),
    (0, ["OBJECT", "REFCOUNT", "n"]),
    (0, ["OBJECT", "ENCODING", "n"]),
    (0, ["CONFIG", "SET", "maxmemory", "0"]),
    (0, ["SET", "n", "100"]),
    (0, ["OBJECT", "REFCOUNT", "n"]),
    (0, ["OBJECT", "REFCOUNT", "foo"]),
    (0, ["CONFIG", "SET", "maxmemory-policy", "noeviction"]),
    (0, ["FLUSHALL"]),
]


def evicted_event(port):
    r, sub = Conn(port), Conn(port)
    cmd(r, "CONFIG", "SET", "notify-keyspace-events", "Ee")
    cmd(r, "CONFIG", "SET", "maxmemory-policy", "allkeys-lru")
    cmd(r, "SELECT", "9")
    cmd(r, "FLUSHDB")
    cmd(sub, "PSUBSCRIBE", "*")
    cmd(r, "SET", "foo", "bar")
    cmd(r, "CONFIG", "SET", "maxmemory", "1")
    got = sub.reply()
    cmd(r, "CONFIG", "SET", "maxmemory", "0")
    cmd(r, "CONFIG", "SET", "maxmemory-policy", "noeviction")
    cmd(r, "CONFIG", "SET", "notify-keyspace-events", "")
    return got


def rk():
    return "key:%d" % random.randrange(10 ** 9)


# unit/maxmemory.tcl's three tests of the policies
def policies(c):
    out = []
    for pol in "allkeys-random allkeys-lru allkeys-lfu volatile-lru volatile-lfu volatile-random volatile-ttl".split():
        cmd(c, "FLUSHALL")
        limit = used(c) + 100 * 1024
        cmd(c, "CONFIG", "SET", "maxmemory", limit)
        cmd(c, "CONFIG", "SET", "maxmemory-policy", pol)
        n = 0
        while True:
            cmd(c, "SETEX", rk(), 10000, "x")
            n += 1
            if used(c) + 4096 > limit:
                break
        for _ in range(n):
            cmd(c, "SETEX", rk(), 10000, "x")
        out.append(("the limit honoured (%s)" % pol, n > 10 and used(c) < limit + 4096))
    for pol in "allkeys-random allkeys-lru volatile-lru volatile-random volatile-ttl".split():
        cmd(c, "FLUSHALL")
        limit = used(c) + 100 * 1024
        cmd(c, "CONFIG", "SET", "maxmemory", limit)
        cmd(c, "CONFIG", "SET", "maxmemory-policy", pol)
        n = 0
        while True:
            cmd(c, "SET", rk(), "x")
            n += 1
            if used(c) + 4096 > limit:
                break
        err = False
        for _ in range(n):
            kind, r = cmd(c, "SET", rk(), "x")
            err = err or (kind == b"-" and b"used memory" in r)
        good = used(c) < limit + 4096 if pol.startswith("allkeys-") else err
        out.append(("keys without a time evicted by allkeys-* alone (%s)" % pol, good))
    for pol in "volatile-lru volatile-lfu volatile-random volatile-ttl".split():
        cmd(c, "FLUSHALL")
        limit = used(c) + 100 * 1024
        cmd(c, "CONFIG", "SET", "maxmemory", limit)
        cmd(c, "CONFIG", "SET", "maxmemory-policy", pol)
        n = 0
        while True:
            if n % 2:
                cmd(c, "SETEX", "key:%d" % n, 10000, "x")
            else:
                cmd(c, "SET", "key:%d" % n, "x")
            if used(c) + 4096 > limit:
                break
            n += 1
        for j in range(n):
            cmd(c, "SETEX", "foo:%d" % j, 10000, "x")
        kept = all(cmd(c, "EXISTS", "key:%d" % j) == (b":", b"1") for j in range(0, n, 2))
        out.append(("%s evicts keys with a time alone" % pol, used(c) < limit + 4096 and kept))
    cmd(c, "CONFIG", "SET", "maxmemory", 0)
    cmd(c, "CONFIG", "SET", "maxmemory-policy", "noeviction")
    cmd(c, "FLUSHALL")
    return out


def fill(c, n, prefix=b"key:", size=8):
    for b in range(0, n, 1000):
        c.send([[b"SET", prefix + str(i).encode(), b"v" * size] for i in range(b, min(n, b + 1000))])
        for _ in range(b, min(n, b + 1000)):
            c.reply()


def wait_for(cond, secs=20):
    end = time.time() + secs
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.05)
    return False


# INFO's maxmemory and maxmemory_human as maxmemory goes up to its largest
# value: the bytes in each unit, and past them (bytesToHuman)
MAXES = ["0", "1023", "1kb", "1048575", "1mb", "1gb", "1099511627776", "1125899906842624",
         "1152921504606846975", "1152921504606846976", "9223372036854775807",
         "9223372036854775808", "18446744073709551615"]


def info_max(c):
    out = []
    for v in MAXES:
        cmd(c, "CONFIG", "SET", "maxmemory", v)
        i = info(c, b"memory")
        out.append((v, i.get("maxmemory"), i.get("maxmemory_human")))
    cmd(c, "CONFIG", "SET", "maxmemory", "0")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default="build/bendkv")
    ap.add_argument("--bendkv", type=int, default=6380)
    ap.add_argument("--redis", type=int, default=6391)
    ap.add_argument("--dir", default="build/maxmemory")
    args = ap.parse_args()
    shutil.rmtree(args.dir, ignore_errors=True)
    os.makedirs(args.dir)
    kd, rd = os.path.join(args.dir, "bendkv"), os.path.join(args.dir, "redis")
    os.makedirs(kd)
    os.makedirs(rd)
    klog, rlog = os.path.join(args.dir, "bendkv.log"), os.path.join(args.dir, "redis.log")
    kp, kc = start([args.bin, "--port", str(args.bendkv), "--dir", kd, "--save", "", "--maxmemory", "100"], args.bendkv, klog)
    rp, rc = start(["redis-server", "--port", str(args.redis), "--bind", "127.0.0.1", "--save", "",
                    "--appendonly", "no", "--dir", rd, "--maxmemory", "100"], args.redis, rlog)
    try:
        for c in (kc, rc):
            cmd(c, "CONFIG", "SET", "maxmemory", "0")
        warn = "You specified a maxmemory value that is less than 1MB (current value is 100 bytes)"
        for log in (klog, rlog):
            if warn not in open(log).read():
                fail("no warning of maxmemory below 1 MB in " + log)
        ok("the warning of a maxmemory below 1 MB at the start")
        servers = [args.bendkv, args.redis]
        compare("OOM past maxmemory, in MULTI too", servers, OOM)
        stats = []
        for c in (kc, rc):
            i = info(c)
            # the calls' times aside: BendKV does not measure them
            calls = lambda v: ",".join(f for f in (v or "").split(",") if not f.startswith("usec"))
            stats.append((i.get("errorstat_OOM"), calls(i.get("cmdstat_set")), calls(i.get("cmdstat_exec")), i.get("total_error_replies")))
        if stats[0] != stats[1]:
            fail("INFO's counts after OOM: BendKV %r, Redis %r" % (stats[0], stats[1]))
        ok("INFO's counts of the calls refused and of OOM: %r" % (stats[0],))
        compare("OBJECT IDLETIME, FREQ and REFCOUNT", servers, ACCESS, phase=0.3)
        maxes = [info_max(c) for c in (kc, rc)]
        if maxes[0] != maxes[1]:
            fail("INFO's maxmemory: BendKV %r, Redis %r" % tuple(maxes))
        ok("INFO's maxmemory and maxmemory_human, up to 2^64-1 (%d values the same)" % len(MAXES))
        evs = [evicted_event(p) for p in servers]
        if evs[0] != evs[1] or evs[0][1][2][1] != b"__keyevent@9__:evicted":
            fail("the evicted event: BendKV %r, Redis %r" % tuple(evs))
        ok("the evicted event of a key evicted by CONFIG SET maxmemory")
        for c, name in ((kc, "BendKV"), (rc, "Redis")):
            for what, good in policies(c):
                if not good:
                    fail("%s: %s" % (name, what))
            ok("%s: unit/maxmemory.tcl's tests of the policies" % name)
        # BendKV alone: the warning of a CONFIG SET below the memory used
        fill(kc, 20000)
        cmd(kc, "CONFIG", "SET", "maxmemory-policy", "allkeys-lru")
        cmd(kc, "CONFIG", "SET", "maxmemory", "1000")
        if not wait_for(lambda: "the new maxmemory value set via CONFIG SET (1000) is smaller than the current memory usage" in open(klog).read()):
            fail("no warning of a CONFIG SET of maxmemory below the memory used")
        ok("the warning of a CONFIG SET below the memory used")
        if not wait_for(lambda: cmd(kc, "DBSIZE") == (b":", b"0")):
            fail("the keys are not evicted")
        cmd(kc, "CONFIG", "SET", "maxmemory", "0")
        # an eviction that runs out of time goes on with no request. The
        # connection that watches the memory opens, and asks once, before
        # base is measured: the server keeps what a client takes (about 1 KB
        # for the first one past those it held before) after the client has
        # gone, so a connection opened later would put that above the limit,
        # and once the eviction had stopped within that much of it, INFO
        # would never set another going
        cmd(kc, "FLUSHALL")
        cmd(kc, "CONFIG", "RESETSTAT")
        quiet = Conn(args.bendkv)
        used(quiet)
        base = used(kc)
        fill(kc, 200000)
        full = used(kc)
        limit = base + (full - base) // 2
        cmd(kc, "CONFIG", "SET", "maxmemory", limit)
        t0 = time.time()
        time.sleep(0.5)
        # the memory, the keys left and the eviction's counts of one moment:
        # DBSIZE and INFO in one transaction, as a request after another
        # may set the eviction going again for a few keys (the heap moves
        # between the cron's ticks by more than the eviction leaves under
        # the limit: the calls' timing held until the tick, issue #79)
        seen = []
        def within():
            cmd(quiet, "MULTI")
            cmd(quiet, "DBSIZE")
            cmd(quiet, "INFO", "all")
            size, text = cmd(quiet, "EXEC")[1]
            seen[:] = [int(size[1]), dict(l.split(":", 1) for l in text[1].decode().split("\r\n") if ":" in l)]
            return int(seen[1]["used_memory"]) <= limit
        if not wait_for(within, 30):
            fail("the eviction does not bring the memory within maxmemory (%s > %d)" % (seen[1]["used_memory"], limit))
        n, i = seen
        if not (0 < n < 200000 and int(i["evicted_keys"]) == 200000 - n and i["current_eviction_exceeded_time"] == "0"
                and int(i["total_eviction_exceeded_time"]) > 0):
            fail("after the eviction: %d keys, %r" % (n, {k: i[k] for k in ("evicted_keys", "total_eviction_exceeded_time", "current_eviction_exceeded_time")}))
        ok("an eviction that runs out of time goes on alone: %d of 200000 keys left in %.1f s, used_memory %d <= %d" % (n, time.time() - t0, used(kc), limit))
        cmd(kc, "CONFIG", "SET", "maxmemory", "0")
        cmd(kc, "CONFIG", "SET", "maxmemory-policy", "noeviction")
    finally:
        stop(kp)
        stop(rp)
    # with the append-only file: the evicted keys gone from it too
    ad = os.path.join(args.dir, "aof")
    os.makedirs(ad)
    alog = os.path.join(args.dir, "bendkv-aof.log")
    kp, kc = start([args.bin, "--port", str(args.bendkv), "--dir", ad, "--save", "", "--appendonly", "yes"], args.bendkv, alog)
    try:
        base = used(kc)
        fill(kc, 50000)
        full = used(kc)
        cmd(kc, "CONFIG", "SET", "maxmemory-policy", "allkeys-random")
        cmd(kc, "CONFIG", "SET", "maxmemory", base + (full - base) * 2 // 3)
        wait_for(lambda: used(kc) <= base + (full - base) * 2 // 3, 30)
        cmd(kc, "CONFIG", "SET", "maxmemory", "0")
        left = cmd(kc, "DBSIZE")
        keys = sorted(cmd(kc, "KEYS", "*")[1])
        if not (0 < int(left[1]) < 50000):
            fail("with the file: %r keys left" % (left,))
    finally:
        stop(kp)
    kp, kc = start([args.bin, "--port", str(args.bendkv), "--dir", ad, "--save", "", "--appendonly", "yes"], args.bendkv, alog + ".2")
    try:
        if cmd(kc, "DBSIZE") != left or sorted(cmd(kc, "KEYS", "*")[1]) != keys:
            fail("started again from the file: %r keys, %r before" % (cmd(kc, "DBSIZE"), left))
        ok("keys evicted with the append-only file on: %d left, and as many started again from the file" % int(left[1]))
        # an eviction while a rewrite runs counts the evicted keys as freed
        cmd(kc, "FLUSHALL")
        base = used(kc)
        fill(kc, 300000)
        full = used(kc)
        cmd(kc, "BGREWRITEAOF")
        cmd(kc, "CONFIG", "SET", "maxmemory-policy", "allkeys-lru")
        cmd(kc, "CONFIG", "SET", "maxmemory", full - (full - base) // 10)
        time.sleep(0.5)
        n = int(cmd(kc, "DBSIZE")[1])
        cmd(kc, "CONFIG", "SET", "maxmemory", "0")
        wait_for(lambda: info(kc, b"persistence")["aof_rewrite_in_progress"] == "0", 60)
        if not (150000 < n < 300000):
            fail("an eviction while a rewrite runs left %d of 300000 keys" % n)
        ok("an eviction while a rewrite runs: %d of 300000 keys left" % n)
    finally:
        stop(kp)
    print("maxmemory: all OK")


if __name__ == "__main__":
    main()
