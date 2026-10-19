#!/usr/bin/env python3
"""CONFIG SET appendonly yes and no at run time, against Redis 7.2.16:
BendKV and a redis-server each start with the file off on a directory of
their own, and their replies, INFO's fields, files, manifests, the lines
they log about the files and their databases after a restart are
compared. Each scenario has fresh directories of its own.

1. In the directory (appendonlydir there for both, aof-use-rdb-preamble
   no): writes, the file turned on (its rewrite's base and the temporary
   incremental file renamed in), writes, off, writes, on again (the
   files of the first time made history and removed), writes; both
   started again on their directories hold the same databases, those of
   before the second time off.
2. The single file (BendKV without appendonlydir keeps Redis 6's file;
   Redis makes its directory): the same writes; the databases after a
   restart alike, and no temporary file left next to BendKV's.
3. WAITAOF: refused with the file off (after a BGREWRITEAOF too, which
   leaves it off), [1, 0] once it is on, and a client waiting in it
   (appendfsync no: no sync serves it) answered the error when the file
   is turned off; a write made while the rewrite that turns the file on
   waits for a background save is acknowledged once that rewrite ends.
4. Writes while the rewrite that turns the file on runs (slowed by
   rdb-key-save-delay), in the directory: the base holds the databases of
   its start, the new incremental file the writes after it, once each;
   the databases after a restart alike.
5. The file turned on while a BGREWRITEAOF of appendonly no runs (it is
   stopped and a rewrite started), and turned off while the rewrite that
   turns it on runs (it is stopped); the lines logged, INFO, the files.
6. The file turned on while a background save runs: its rewrite
   scheduled (aof_rewrite_scheduled 1), then run once the save ends.
7. A temporary incremental file that cannot be made (a directory has its
   name): the file stays off, and appendonly reads no again, with Redis's
   lines. Redis answers CONFIG SET with an error; BendKV has answered OK
   by then (README: Persistence).
8. Writes while a BGREWRITEAOF runs with the file on from the start, in
   the directory: the new incremental file holds them once each, and the
   databases after a restart are alike (none of them applied twice).
9. The rewrite that turns the file on fails as it ends (a directory has
   the new incremental file's name): scheduled again and run again by the
   cron, its failures counted in a row, until the third holds the cron's
   tries back (aofRewriteLimited); then the file turned off.
10. SHUTDOWN (without FORCE, with NOSAVE, with SAVE, in a batch) and
   SIGTERM while the rewrite that turns the file on runs: refused, the
   server going on, with Redis's error, counts and lines; then SHUTDOWN
   FORCE stops it, the rewrite stopped.

    python3 tests/aof_switch_test.py --bin build/bendkv --bendkv 6380 --redis 6391 --dir build/aofswitch
"""
import argparse
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time

from aof_redis_test import start
from aofdir_test import entries, files, manifest
from diff_test import Conn
from rewrite_test import keyspace, settle

FAILS = []


def fail(what, x="", y=""):
    FAILS.append(what)
    print("FAIL: %s" % what)
    if x != "" or y != "":
        print("  BendKV: %r" % (x,))
        print("  Redis:  %r" % (y,))


def same(what, x, y):
    if x != y:
        fail(what, x, y)
    else:
        print("ok   %s" % what)


def check(what, ok, x=""):
    if ok:
        print("ok   %s" % what)
    else:
        fail(what, x)


def cmd(c, *args):
    c.send([[a if isinstance(a, bytes) else str(a).encode() for a in args]])
    return c.reply()


def info(c):
    kind, text = cmd(c, "INFO", "persistence")
    return dict(l.split(":", 1) for l in text.decode().split("\r\n") if ":" in l)


FIELDS = ["aof_enabled", "aof_rewrite_in_progress", "aof_rewrite_scheduled", "aof_last_bgrewrite_status",
          "aof_rewrites", "aof_rewrites_consecutive_failures", "aof_last_write_status", "aof_pending_rewrite"]


def fields(c):
    i = info(c)
    return {k: i.get(k) for k in FIELDS}


# the lines a server logs about turning its file on and off and about its
# files, without their prefix, a temporary file's pid as PID and a child's
# (Redis's) or the server's (BendKV's) pid as PID
KEEP = ("Creating AOF", "Successfully renamed", "Background AOF rewrite", "Background append only file",
        "Removing the history file", "AOF was enabled", "Killing running AOF rewrite child",
        "Redis needs to enable the AOF", "Can't open the append-only file", "Error trying to",
        "Fail to fsync the AOF file", "Removing the temp incr aof file", "User requested shutdown",
        "Writing initial AOF", "Errors trying to shut down", "There is a child rewriting",
        "Calling fsync() on the AOF file")
PREFIX = re.compile(r"^\d+:[MCXS] \d+ \w+ \d+ [\d:.]+ [.\-*#] ?")


def lines(path, since=0):
    out = []
    with open(path, errors="replace") as f:
        text = f.read().splitlines()[since:]
    for l in text:
        l = PREFIX.sub("", l)
        if l.startswith(KEEP):
            l = re.sub(r"temp-rewriteaof-bg-\d+\.aof", "temp-rewriteaof-bg-PID.aof", l)
            l = re.sub(r"by pid \d+", "by pid PID", l)
            l = re.sub(r"child: \d+", "child: PID", l)
            out.append(l)
    return out


def count(path):
    with open(path, errors="replace") as f:
        return len(f.read().splitlines())


class Pair:
    """BendKV and Redis, each on a directory of its own, with appendonly
    no (or on); dirs: whether both have appendonlydir (BendKV keeps the
    single file without it)"""

    def __init__(self, a, name, dirs, *more, on="no"):
        self.a = a
        self.b = os.path.join(a.dir, name, "bendkv")
        self.r = os.path.join(a.dir, name, "redis")
        for d in (self.b, self.r):
            shutil.rmtree(d, ignore_errors=True)
            os.makedirs(d)
            if dirs:
                os.makedirs(os.path.join(d, "appendonlydir"))
        self.n = 0
        self.more = more
        self.start("--appendonly", on, *more)

    def argv(self, which, *more):
        if which == "b":
            return [self.a.bin, "--port", str(self.a.bendkv), "--dir", self.b, "--save", ""] + list(more)
        return ["redis-server", "--port", str(self.a.redis), "--bind", "127.0.0.1", "--dir", self.r,
                "--save", ""] + list(more)

    def start(self, *more):
        self.n += 1
        self.lb = os.path.join(self.b, "..", "b-%d.log" % self.n)
        self.lr = os.path.join(self.r, "..", "r-%d.log" % self.n)
        self.pb, self.cb = start(self.argv("b", *more), self.a.bendkv, self.lb)
        self.pr, self.cr = start(self.argv("r", *more), self.a.redis, self.lr)

    def both(self, *args):
        return cmd(self.cb, *args), cmd(self.cr, *args)

    def same(self, what, *args):
        x, y = self.both(*args)
        same(what, x, y)
        return x

    def settle(self):
        return settle(self.cb), settle(self.cr)

    def stop(self):
        for p, c in ((self.pb, self.cb), (self.pr, self.cr)):
            try:
                cmd(c, "SHUTDOWN", "NOSAVE")
            except (OSError, EOFError):
                pass
            try:
                p.wait(timeout=30)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()

    def fields(self, what):
        same(what, fields(self.cb), fields(self.cr))

    def logs(self, what, since=(0, 0)):
        same(what, lines(self.lb, since[0]), lines(self.lr, since[1]))

    def marks(self):
        return (count(self.lb), count(self.lr))

    def dir_files(self, what):
        same(what, files(self.b), files(self.r))

    def manifests(self, what):
        same(what, manifest(self.b), manifest(self.r))

    def spaces(self, what):
        x, y = keyspace(self.a.bendkv), keyspace(self.a.redis)
        same(what + " (%d keys)" % len(x), x, y)
        return x


T = int(time.time() * 1000) + 10 ** 9


# writes of each kind, in two databases, through one pipeline each
def fill(c, tag, n=40):
    for db in (0, 3):
        reqs = [["SELECT", db]]
        reqs += [["SET", "s:%s:%d" % (tag, i), "v%d" % i] for i in range(n)]
        reqs += [["RPUSH", "l:%s" % tag] + ["e%d" % i for i in range(20)],
                 ["HSET", "h:%s" % tag] + sum((["f%d" % i, "w%d" % i] for i in range(10)), []),
                 ["SADD", "set:%s" % tag] + ["m%d" % i for i in range(10)],
                 ["ZADD", "z:%s" % tag] + sum((["%d.5" % i, "z%d" % i] for i in range(10)), []),
                 ["SET", "x:%s" % tag, "1", "PXAT", T], ["INCR", "n:%s" % tag], ["DEL", "s:%s:0" % tag],
                 ["RPUSH", "log", tag]]
        c.send([[str(a).encode() for a in r] for r in reqs])
        for _ in reqs:
            c.reply()
    cmd(c, "SELECT", 0)


def fill_both(p, tag, n=40):
    fill(p.cb, tag, n)
    fill(p.cr, tag, n)


# the incremental file's entries: SELECT and the writes, each a tuple of
# its arguments (aofdir_test's entries: an INCR is the SET of its value)
def incr_entries(d):
    mf = manifest(d)
    if mf is None:
        return None
    name = [l.split()[1] for l in mf.splitlines() if l.endswith("type i")]
    if not name:
        return None
    with open(os.path.join(d, "appendonlydir", name[-1]), "rb") as f:
        return entries(f.read())


# 1. In the directory
def in_dir(a):
    print("== on and off in the directory")
    p = Pair(a, "dir", True, "--aof-use-rdb-preamble", "no")
    fill_both(p, "a")
    m = p.marks()
    p.same("CONFIG SET appendonly yes", "CONFIG", "SET", "appendonly", "yes")
    p.settle()
    p.fields("INFO once on")
    p.same("CONFIG GET appendonly", "CONFIG", "GET", "appendonly")
    p.manifests("the manifest once on")
    p.dir_files("the files once on")
    fill_both(p, "b")
    same("the incremental file's entries", incr_entries(p.b), incr_entries(p.r))
    p.same("CONFIG SET appendonly no", "CONFIG", "SET", "appendonly", "no")
    p.fields("INFO once off")
    before = p.spaces("the databases once off")
    fill_both(p, "c")
    p.same("CONFIG SET appendonly yes again", "CONFIG", "SET", "appendonly", "yes")
    p.settle()
    p.fields("INFO once on again")
    p.manifests("the manifest once on again")
    p.dir_files("the files once on again (the first ones history, removed)")
    fill_both(p, "d")
    p.logs("the lines logged", m)
    now = p.spaces("the databases")
    p.stop()
    p.start("--appendonly", "yes", "--aof-use-rdb-preamble", "no")
    same("the databases after a restart", p.spaces("the databases after a restart"), now)
    check("the restart holds more than the first time on", len(now) > len(before))
    p.stop()


# 2. The single file
def single(a):
    print("== on and off with the single file (BendKV) and the directory (Redis)")
    p = Pair(a, "single", False)
    fill_both(p, "a")
    p.same("CONFIG SET appendonly yes", "CONFIG", "SET", "appendonly", "yes")
    p.settle()
    p.fields("INFO once on")
    fill_both(p, "b")
    check("BendKV's single file is there", os.path.exists(os.path.join(p.b, "appendonly.aof")))
    check("no temporary file next to it", not os.path.exists(os.path.join(p.b, "temp-appendonly.aof.incr")),
          sorted(os.listdir(p.b)))
    now = p.spaces("the databases")
    p.same("CONFIG SET appendonly no", "CONFIG", "SET", "appendonly", "no")
    fill_both(p, "c")
    p.stop()
    p.start("--appendonly", "yes")
    same("the databases after a restart (those of before the file was turned off)",
         p.spaces("the databases after a restart"), now)
    p.stop()


def blocked(port, *args):
    s = socket.create_connection(("127.0.0.1", port))
    s.sendall(b"".join([b"*%d\r\n" % len(args)] + [b"$%d\r\n%s\r\n" % (len(str(x)), str(x).encode()) for x in args]))
    return s


def blocked_clients(c):
    kind, text = cmd(c, "INFO", "clients")
    return int(re.search(rb"blocked_clients:(\d+)", text).group(1))


def wait_blocked(c, n=1):
    for _ in range(400):
        if blocked_clients(c) >= n:
            return True
        time.sleep(0.01)
    return False


def read_reply(s):
    s.settimeout(10)
    data = b""
    while b"\r\n" not in data:
        more = s.recv(4096)
        if not more:
            break
        data += more
    return data


# 3. WAITAOF
def waitaof(a):
    print("== WAITAOF")
    p = Pair(a, "waitaof", False)
    p.same("SET with the file off", "SET", "k", "1")
    p.same("WAITAOF 1 0 0 with the file off", "WAITAOF", "1", "0", "0")
    p.same("WAITAOF 0 0 0 with the file off", "WAITAOF", "0", "0", "0")
    p.same("BGREWRITEAOF with the file off", "BGREWRITEAOF")
    p.settle()
    p.same("SET after it", "SET", "k", "2")
    p.same("WAITAOF 1 0 0 after it (the file still off)", "WAITAOF", "1", "0", "0")
    p.same("WAITAOF 0 0 0 after it", "WAITAOF", "0", "0", "0")
    p.fields("INFO after it")
    p.same("CONFIG SET appendonly yes", "CONFIG", "SET", "appendonly", "yes")
    p.settle()
    p.same("INCR", "INCR", "k")
    p.same("WAITAOF 1 0 0 with the file on", "WAITAOF", "1", "0", "0")
    p.same("CONFIG SET appendfsync no", "CONFIG", "SET", "appendfsync", "no")
    # no sync serves a client in WAITAOF once its write is past the last
    # sync: turning the file off answers it the error
    p.same("CONFIG SET appendonly no", "CONFIG", "SET", "appendonly", "no")
    p.same("CONFIG SET appendonly yes, appendfsync no", "CONFIG", "SET", "appendonly", "yes")
    p.settle()
    socks = []
    for port in (a.bendkv, a.redis):
        s = blocked(port, "INCR", "foo")
        read_reply(s)
        s.sendall(b"*4\r\n$7\r\nWAITAOF\r\n$1\r\n1\r\n$1\r\n0\r\n$1\r\n0\r\n")
        socks.append(s)
    check("BendKV's client waits", wait_blocked(p.cb))
    check("Redis's client waits", wait_blocked(p.cr))
    p.same("CONFIG SET appendonly no (the waiting clients answered)", "CONFIG", "SET", "appendonly", "no")
    same("the waiting client's answer", read_reply(socks[0]), read_reply(socks[1]))
    for s in socks:
        s.close()
    p.same("WAITAOF 1 0 0 once off", "WAITAOF", "1", "0", "0")
    p.same("WAITAOF 0 0 0 once off", "WAITAOF", "0", "0", "0")
    # the rewrite that turns the file on waits for a background save: a
    # write before it ends is acknowledged once it ends
    p.same("CONFIG SET appendfsync everysec", "CONFIG", "SET", "appendfsync", "everysec")
    p.same("SET x y", "SET", "x", "y")
    p.same("CONFIG SET rdb-key-save-delay", "CONFIG", "SET", "rdb-key-save-delay", "1500000")
    p.same("BGSAVE", "BGSAVE")
    p.same("CONFIG SET appendonly yes while the save runs", "CONFIG", "SET", "appendonly", "yes")
    same("aof_rewrite_scheduled while the save runs", info(p.cb)["aof_rewrite_scheduled"], info(p.cr)["aof_rewrite_scheduled"])
    p.same("SET x y again", "SET", "x", "y")
    p.same("CONFIG SET rdb-key-save-delay 0", "CONFIG", "SET", "rdb-key-save-delay", "0")
    p.same("WAITAOF 1 0 10000 (once the rewrite ends)", "WAITAOF", "1", "0", "10000")
    p.settle()
    p.fields("INFO after it")
    p.stop()


# 4. Writes while the rewrite that turns the file on runs
def during(a):
    print("== writes while the file turns on, in the directory")
    p = Pair(a, "during", True, "--aof-use-rdb-preamble", "no")
    for c in (p.cb, p.cr):
        c.send([[b"SET", b"k:%d" % i, b"v"] for i in range(300)])
        for _ in range(300):
            c.reply()
    p.same("CONFIG SET rdb-key-save-delay", "CONFIG", "SET", "rdb-key-save-delay", "3000")
    p.same("CONFIG SET appendonly yes", "CONFIG", "SET", "appendonly", "yes")
    same("aof_rewrite_in_progress as it runs", info(p.cb)["aof_rewrite_in_progress"], info(p.cr)["aof_rewrite_in_progress"])
    for i in range(30):
        p.both("RPUSH", "during", "x%d" % i)
    p.same("CONFIG SET rdb-key-save-delay 0", "CONFIG", "SET", "rdb-key-save-delay", "0")
    p.settle()
    p.fields("INFO once on")
    p.manifests("the manifest")
    same("the incremental file's entries (the writes while it ran, once each)", incr_entries(p.b), incr_entries(p.r))
    now = p.spaces("the databases")
    p.stop()
    p.start("--appendonly", "yes", "--aof-use-rdb-preamble", "no")
    same("the databases after a restart", p.spaces("the databases after a restart"), now)
    p.same("LLEN of the writes while it ran", "LLEN", "during")
    p.stop()


# 5. Turned on while a rewrite runs; turned off while it turns on
def stopped(a):
    print("== a rewrite stopped by the file turned on, and by the file turned off")
    p = Pair(a, "stopped", True, "--aof-use-rdb-preamble", "no")
    for c in (p.cb, p.cr):
        c.send([[b"SET", b"k:%d" % i, b"v"] for i in range(200)])
        for _ in range(200):
            c.reply()
    m = p.marks()
    p.same("CONFIG SET rdb-key-save-delay", "CONFIG", "SET", "rdb-key-save-delay", "20000")
    p.same("BGREWRITEAOF with the file off", "BGREWRITEAOF")
    p.same("CONFIG SET appendonly yes while it runs", "CONFIG", "SET", "appendonly", "yes")
    p.same("CONFIG SET appendonly no while the rewrite that turns it on runs", "CONFIG", "SET", "appendonly", "no")
    p.fields("INFO once off")
    p.same("CONFIG SET rdb-key-save-delay 0", "CONFIG", "SET", "rdb-key-save-delay", "0")
    p.manifests("the manifest (as it was)")
    p.dir_files("the files (the temporary incremental file stays)")
    p.logs("the lines logged", m)
    p.stop()


# 6. Turned on while a background save runs
def saving(a):
    print("== the file turned on while a background save runs")
    p = Pair(a, "saving", True, "--aof-use-rdb-preamble", "no")
    p.same("SET", "SET", "x", "y")
    m = p.marks()
    p.same("CONFIG SET rdb-key-save-delay", "CONFIG", "SET", "rdb-key-save-delay", "1000000")
    p.same("BGSAVE", "BGSAVE")
    p.same("CONFIG SET appendonly yes", "CONFIG", "SET", "appendonly", "yes")
    p.fields("INFO while the save runs (the rewrite scheduled)")
    p.same("CONFIG SET rdb-key-save-delay 0", "CONFIG", "SET", "rdb-key-save-delay", "0")
    p.settle()
    p.fields("INFO once on")
    p.manifests("the manifest once on")
    p.logs("the lines logged", m)
    p.stop()


# 7. A temporary incremental file that cannot be made
def refused(a):
    print("== a temporary incremental file that cannot be made")
    p = Pair(a, "refused", True, "--aof-use-rdb-preamble", "no")
    for d in (p.b, p.r):
        os.makedirs(os.path.join(d, "appendonlydir", "temp-appendonly.aof.incr"))
    m = p.marks()
    x, y = p.both("CONFIG", "SET", "appendonly", "yes")
    same("CONFIG SET appendonly yes (BendKV answered OK by then)", x, (b"+", b"OK"))
    same("Redis's answer", y[0], b"-")
    time.sleep(0.2)
    p.same("CONFIG GET appendonly", "CONFIG", "GET", "appendonly")
    p.fields("INFO")
    p.manifests("the manifest")
    p.logs("the lines logged", m)
    p.stop()


# 8. Writes while a BGREWRITEAOF runs with the file on from the start
def rewrite(a):
    print("== writes while a rewrite runs with the file on, in the directory")
    p = Pair(a, "rewrite", True, "--aof-use-rdb-preamble", "no", on="yes")
    fill_both(p, "a")
    p.same("CONFIG SET rdb-key-save-delay", "CONFIG", "SET", "rdb-key-save-delay", "3000")
    p.same("BGREWRITEAOF", "BGREWRITEAOF")
    same("aof_rewrite_in_progress as it runs", info(p.cb)["aof_rewrite_in_progress"], info(p.cr)["aof_rewrite_in_progress"])
    for i in range(30):
        p.both("RPUSH", "during", "x%d" % i)
    p.same("CONFIG SET rdb-key-save-delay 0", "CONFIG", "SET", "rdb-key-save-delay", "0")
    p.settle()
    p.fields("INFO once it ends")
    p.manifests("the manifest")
    same("the incremental file's entries (the writes while it ran, once each)", incr_entries(p.b), incr_entries(p.r))
    now = p.spaces("the databases")
    p.stop()
    p.start("--appendonly", "yes", "--aof-use-rdb-preamble", "no")
    same("the databases after a restart", p.spaces("the databases after a restart"), now)
    p.same("LLEN of the writes while it ran", "LLEN", "during")
    p.stop()


# 9. The rewrite that turns the file on fails as it ends
def limited(a):
    print("== the rewrite that turns the file on fails, again and again")
    p = Pair(a, "limited", True, "--aof-use-rdb-preamble", "no")
    for d in (p.b, p.r):
        os.makedirs(os.path.join(d, "appendonlydir", "appendonly.aof.1.incr.aof", "x"))
    p.same("SET", "SET", "k", "v")
    m = p.marks()
    p.same("CONFIG SET appendonly yes", "CONFIG", "SET", "appendonly", "yes")
    for c, who in ((p.cb, "BendKV"), (p.cr, "Redis")):
        for _ in range(400):
            i = info(c)
            if int(i["aof_rewrites_consecutive_failures"]) >= 3 and i["aof_rewrite_in_progress"] == "0":
                break
            time.sleep(0.025)
        else:
            fail("%s's rewrite failed three times" % who)
    time.sleep(0.5)
    p.fields("INFO after three failures (the cron's tries held back)")
    p.logs("the lines logged", m)
    p.same("CONFIG SET appendonly no", "CONFIG", "SET", "appendonly", "no")
    p.fields("INFO once off")
    p.manifests("the manifest (none)")
    p.dir_files("the files")
    p.stop()


def section(c, name):
    kind, text = cmd(c, "INFO", name)
    return dict(l.split(":", 1) for l in text.decode().split("\r\n") if ":" in l)


# a command's counts in INFO commandstats, without its times
def calls(c, name):
    v = section(c, "commandstats").get("cmdstat_" + name, "")
    return {k: x for k, x in (f.split("=") for f in v.split(",") if f) if not k.startswith("usec")}


# 10. SHUTDOWN while the rewrite that turns the file on runs
def downs(a):
    print("== SHUTDOWN and SIGTERM while the file turns on")
    p = Pair(a, "downs", True, "--aof-use-rdb-preamble", "no")
    for c in (p.cb, p.cr):
        c.send([[b"SET", b"k:%d" % i, b"v"] for i in range(300)])
        for _ in range(300):
            c.reply()
    p.same("CONFIG SET rdb-key-save-delay", "CONFIG", "SET", "rdb-key-save-delay", "20000")
    m = p.marks()
    p.same("CONFIG SET appendonly yes", "CONFIG", "SET", "appendonly", "yes")
    p.same("CONFIG RESETSTAT", "CONFIG", "RESETSTAT")
    p.same("SHUTDOWN while it runs (refused)", "SHUTDOWN")
    p.same("SHUTDOWN NOSAVE", "SHUTDOWN", "NOSAVE")
    p.same("SHUTDOWN SAVE", "SHUTDOWN", "SAVE")
    x = []
    for c in (p.cb, p.cr):
        c.send([[b"SHUTDOWN"], [b"PING"]])
        x.append((c.reply(), c.reply()))
    same("SHUTDOWN and PING in one batch", x[0], x[1])
    for proc in (p.pb, p.pr):
        os.kill(proc.pid, signal.SIGTERM)
    time.sleep(0.5)
    check("BendKV goes on after SIGTERM", p.pb.poll() is None)
    check("Redis goes on after SIGTERM", p.pr.poll() is None)
    p.same("PING after it", "PING")
    same("SHUTDOWN's counts", calls(p.cb, "shutdown"), calls(p.cr, "shutdown"))
    same("the errors", section(p.cb, "errorstats"), section(p.cr, "errorstats"))
    p.fields("INFO while it runs")
    p.logs("the lines logged", m)
    m = p.marks()
    for c in (p.cb, p.cr):
        try:
            c.send([[b"SHUTDOWN", b"FORCE"]])
            c.reply()
        except (OSError, EOFError):
            pass
    for proc in (p.pb, p.pr):
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            fail("SHUTDOWN FORCE stops the server")
            proc.kill()
            proc.wait()
    p.logs("the lines logged at SHUTDOWN FORCE", m)
    p.dir_files("the files (the temporary incremental file, no manifest)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default="build/bendkv")
    ap.add_argument("--bendkv", type=int, default=6380)
    ap.add_argument("--redis", type=int, default=6391)
    ap.add_argument("--dir", default="build/aofswitch")
    ap.add_argument("--only", default="")
    a = ap.parse_args()
    a.dir = os.path.abspath(a.dir)
    for name, f in (("dir", in_dir), ("single", single), ("waitaof", waitaof), ("during", during),
                    ("stopped", stopped), ("saving", saving), ("refused", refused), ("rewrite", rewrite),
                    ("limited", limited), ("downs", downs)):
        if not a.only or name in a.only.split(","):
            f(a)
    if FAILS:
        print("%d FAILED" % len(FAILS))
        sys.exit(1)
    print("ALL OK")


if __name__ == "__main__":
    main()
