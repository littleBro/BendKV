#!/usr/bin/env python3
"""Redis 7's multi-part append-only file against Redis 7.0.15: BendKV and
a redis-server each start on a copy of the same directory, and their
databases, their manifests and the lines they log about the files are
compared. Each scenario has fresh directories of its own.

1. Redis writes, rewrites (BGREWRITEAOF) and writes more, with
   aof-use-rdb-preamble yes (its base an RDB file) and no (its base
   commands); both start on its directory: the same databases, the same
   lines for the base and each incremental file.
2. Both start on an empty appendonlydir (BendKV makes no directory: the
   runtime cannot): each makes an empty base, an incremental file and the
   manifest, the same ones (preamble no; BendKV writes its bases as
   commands, which Redis writes with preamble no). Both write, rewrite
   and write more: the same manifests, and the same entries in each
   incremental file. Redis then starts on BendKV's directory, and BendKV
   on Redis's: the same databases.
3. An old single file in dir, with an empty appendonlydir, and with a
   manifest of that base alone that the directory does not hold (an
   upgrade stopped half way): both move it in, with the same manifest
   and lines, and the same databases.
4. Manifests Redis refuses: both refuse them, with the same lines, and
   end with code 1.
5. Files that end cut short: the last incremental file (both cut it back
   and start, with the same databases); one before the last (both cut
   it, then stop with Redis's line).
6. A file the manifest names that is not there: both stop.
7. History files in the manifest: both remove them at the start, and
   write the manifest without them.
8. appendonly no, with the directory: BGREWRITEAOF writes a new base
   into it and makes the incremental files history; the same manifests.
9. Functions: Redis loads libraries, rewrites (its base an RDB file, or
   commands) and changes them after, in the new incremental file; both
   start on its directory, with the same libraries and FCALL's replies.
   BendKV then rewrites (a base of commands) and loads one more; both
   start on its directory, with the same libraries.

    python3 tests/aofdir_test.py --bin build/bendkv --bendkv 6380 --redis 6391 --dir build/aofdir
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import time

from aof_redis_test import start, stop
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


def cmd(c, *args):
    c.send([[a if isinstance(a, bytes) else str(a).encode() for a in args]])
    return c.reply()


# the lines a server logs about its append-only files, without their
# prefix (pid, role, time, level), a load's seconds as S, and the pid in
# a temporary file's name as PID
KEEP = ("DB loaded from", "Reading RDB", "Done loading RDB", "Opening AOF", "Creating AOF",
        "Successfully migrated", "Removing the history file", "Fatal error", "Unable to obtain",
        "*** FATAL AOF MANIFEST FILE ERROR ***", "Reading the manifest file", ">>> '",
        "Invalid AOF manifest", "Found ", "File can't be a path", "Unknown AOF file type",
        "The AOF manifest file contains", "Background AOF rewrite terminated with success",
        "Successfully renamed the temporary AOF base file", "Background AOF rewrite finished",
        "Error trying to", "Can't open the append-only file", "Read AOF manifest failed")
PREFIX = re.compile(r"^\d+:[MCXS] \d+ \w+ \d+ [\d:.]+ [.\-*#] ?")


def lines(text):
    out = []
    for l in text.splitlines():
        l = PREFIX.sub("", l)
        if l.startswith(KEEP):
            l = re.sub(r"\d+\.\d+ seconds", "S seconds", l)
            l = re.sub(r"temp-rewriteaof-bg-\d+\.aof", "temp-rewriteaof-bg-PID.aof", l)
            out.append(l)
    return out


def logged(path):
    with open(path, errors="replace") as f:
        return lines(f.read())


def manifest(d):
    p = os.path.join(d, "appendonlydir", "appendonly.aof.manifest")
    if not os.path.exists(p):
        return None
    with open(p) as f:
        return f.read()


def files(d):
    p = os.path.join(d, "appendonlydir")
    return sorted(os.listdir(p)) if os.path.isdir(p) else None


def incr(d, n):
    p = os.path.join(d, "appendonlydir", "appendonly.aof.%d.incr.aof" % n)
    if not os.path.exists(p):
        return None
    with open(p, "rb") as f:
        return f.read()


# the entries of a file of commands, each a tuple of its arguments; BendKV
# logs a write's effect, so fill's INCR is the SET of its value there
# (FINDINGS.md, section 10: effects logged instead of commands), which is
# the one entry put as the same on both sides
def entries(b):
    if b is None:
        return None
    out, i = [], 0
    while i < len(b):
        j = b.index(b"\r\n", i)
        n, i, e = int(b[i + 1:j]), j + 2, []
        for _ in range(n):
            j = b.index(b"\r\n", i)
            m = int(b[i + 1:j])
            e.append(b[j + 2:j + 2 + m])
            i = j + 2 + m + 2
        if e[0].upper() == b"INCR" or (e[0] == b"SET" and e[1].startswith(b"n:") and len(e) == 3):
            e = [b"SET", e[1], b"(its value)"]
        out.append(tuple(e))
    return out


class Pair:
    """BendKV and Redis, each on a directory of its own"""

    def __init__(self, a, root, name):
        self.a = a
        self.b = os.path.join(root, name, "bendkv")
        self.r = os.path.join(root, name, "redis")
        for d in (self.b, self.r):
            shutil.rmtree(d, ignore_errors=True)
            os.makedirs(d)
        self.n = 0

    def argv(self, which, *more):
        if which == "b":
            return [self.a.bin, "--port", str(self.a.bendkv), "--dir", self.b, "--save", ""] + list(more)
        return ["redis-server", "--port", str(self.a.redis), "--bind", "127.0.0.1", "--dir", self.r,
                "--save", ""] + list(more)

    def log(self, which):
        self.n += 1
        return os.path.join(self.b if which == "b" else self.r, "..", "%s-%d.log" % (which, self.n))

    # both started; their processes, connections and logs
    def start(self, *more):
        lb, lr = self.log("b"), self.log("r")
        pb, cb = start(self.argv("b", *more), self.a.bendkv, lb)
        pr, cr = start(self.argv("r", *more), self.a.redis, lr)
        return (pb, cb, lb), (pr, cr, lr)

    # both run, as they would start, until they end (they refuse to start)
    def refused(self, *more):
        out = []
        for which, port in (("b", self.a.bendkv), ("r", self.a.redis)):
            lg = self.log(which)
            p = subprocess.Popen(self.argv(which, *more), stdout=open(lg, "w"), stderr=subprocess.STDOUT)
            try:
                code = p.wait(timeout=20)
            except subprocess.TimeoutExpired:
                p.kill()
                code = "still running"
            out.append((code, logged(lg)))
        return out


def both(c1, c2, *args):
    x, y = cmd(c1, *args), cmd(c2, *args)
    return x, y


T = int(time.time() * 1000) + 10 ** 9


# writes of each kind, in several databases
def fill(c, tag, n=50):
    for db in (0, 3):
        cmd(c, "SELECT", db)
        for i in range(n):
            cmd(c, "SET", "s:%s:%d" % (tag, i), "v%d" % i)
        cmd(c, "RPUSH", "l:%s" % tag, *["e%d" % i for i in range(20)])
        cmd(c, "HSET", "h:%s" % tag, *sum((["f%d" % i, "w%d" % i] for i in range(10)), []))
        cmd(c, "SADD", "set:%s" % tag, *["m%d" % i for i in range(10)])
        cmd(c, "ZADD", "z:%s" % tag, *sum((["%d.5" % i, "z%d" % i] for i in range(10)), []))
        cmd(c, "SET", "x:%s" % tag, "1", "PXAT", T)
        cmd(c, "INCR", "n:%s" % tag)
        cmd(c, "DEL", "s:%s:0" % tag)
    cmd(c, "SELECT", 0)


def rewrite(c):
    r = cmd(c, "BGREWRITEAOF")
    settle(c)
    return r


def down(p, c):
    try:
        cmd(c, "SHUTDOWN", "NOSAVE")
    except (OSError, EOFError):
        pass
    try:
        p.wait(timeout=20)
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait()


def copy(src, dst):
    shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(src, dst)


# 1. Redis writes; both start on its directory
def from_redis(a, root, preamble):
    print("== Redis's directory, aof-use-rdb-preamble %s" % preamble)
    p = Pair(a, root, "redis-" + preamble)
    pr, cr = start(p.argv("r", "--appendonly", "yes", "--aof-use-rdb-preamble", preamble), a.redis, p.log("r"))
    fill(cr, "a")
    rewrite(cr)
    fill(cr, "b", 30)
    cmd(cr, "FLUSHDB")
    fill(cr, "c", 20)
    want = keyspace(a.redis)
    down(pr, cr)
    copy(p.r, p.b)
    (pb, cb, lb), (pr, cr, lr) = p.start("--appendonly", "yes")
    same("the databases after the start", keyspace(a.bendkv), keyspace(a.redis))
    same("they are the ones Redis wrote", keyspace(a.bendkv), want)
    same("the lines of the start", logged(lb), logged(lr))
    down(pb, cb)
    down(pr, cr)
    same("the manifests after the start", manifest(p.b), manifest(p.r))
    same("the files after the start", files(p.b), files(p.r))


# 2. A fresh start on an empty directory, then writes and a rewrite on
# both; each starts on the other's directory
def fresh(a, root):
    print("== an empty appendonlydir: both make their files, write and rewrite")
    p = Pair(a, root, "fresh")
    for d in (p.b, p.r):
        os.makedirs(os.path.join(d, "appendonlydir"))
    more = ("--appendonly", "yes", "--aof-use-rdb-preamble", "no")
    (pb, cb, lb), (pr, cr, lr) = p.start(*more)
    same("the lines of the start", logged(lb), logged(lr))
    same("the manifests of the start", manifest(p.b), manifest(p.r))
    same("the files of the start", files(p.b), files(p.r))
    for c in (cb, cr):
        fill(c, "a")
    # the entries appended, a SELECT first (Redis's aof_selected_db
    # starts at -1, after the start as after a rewrite's)
    same("the incremental file's entries", entries(incr(p.b, 1)), entries(incr(p.r, 1)))
    same("BGREWRITEAOF's reply", *both(cb, cr, "BGREWRITEAOF"))
    settle(cb)
    settle(cr)
    for c in (cb, cr):
        fill(c, "b", 30)
    same("the databases after the writes", keyspace(a.bendkv), keyspace(a.redis))
    same("the entries of the incremental file the rewrite began", entries(incr(p.b, 2)), entries(incr(p.r, 2)))
    same("the manifests after the rewrite", manifest(p.b), manifest(p.r))
    same("the files after the rewrite", files(p.b), files(p.r))
    rw = lambda ls: [l for l in ls if "rewrite" in l or "history" in l]
    same("the lines of the rewrite", rw(logged(lb)), rw(logged(lr)))
    want = keyspace(a.redis)
    down(pb, cb)
    down(pr, cr)
    # each on the other's directory
    swap = os.path.join(root, "fresh", "swap")
    copy(p.b, swap)
    copy(p.r, p.b)
    copy(swap, p.r)
    (pb, cb, lb), (pr, cr, lr) = p.start(*more)
    same("BendKV on Redis's directory", keyspace(a.bendkv), want)
    same("Redis on BendKV's directory", keyspace(a.redis), want)
    same("the lines of the starts", logged(lb), logged(lr))
    down(pb, cb)
    down(pr, cr)


# 3. An old single file moved into the directory
OLD = (b"*2\r\n$6\r\nSELECT\r\n$1\r\n0\r\n*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$1\r\nv\r\n"
       b"*3\r\n$5\r\nRPUSH\r\n$1\r\nl\r\n$1\r\na\r\n")


def upgrade(a, root):
    for case, mf in (("an empty directory", None), ("a manifest of the base alone", "file appendonly.aof seq 1 type b\n")):
        print("== an old single file, and %s" % case)
        p = Pair(a, root, "upgrade-" + ("empty" if mf is None else "half"))
        for d in (p.b, p.r):
            os.makedirs(os.path.join(d, "appendonlydir"))
            with open(os.path.join(d, "appendonly.aof"), "wb") as f:
                f.write(OLD)
            if mf is not None:
                with open(os.path.join(d, "appendonlydir", "appendonly.aof.manifest"), "w") as f:
                    f.write(mf)
        (pb, cb, lb), (pr, cr, lr) = p.start("--appendonly", "yes")
        same("the databases", keyspace(a.bendkv), keyspace(a.redis))
        same("the lines of the start", logged(lb), logged(lr))
        down(pb, cb)
        down(pr, cr)
        same("the manifests", manifest(p.b), manifest(p.r))
        same("the files", files(p.b), files(p.r))
        same("the old file gone from dir", os.path.exists(os.path.join(p.b, "appendonly.aof")),
             os.path.exists(os.path.join(p.r, "appendonly.aof")))


# 4. Manifests Redis refuses
BAD = [
    ("empty", ""),
    ("four words", "file a seq 1\n"),
    ("seven words", "file a seq 1 type b x\n"),
    ("a path", "file d/a seq 1 type b\n"),
    ("a path with a backslash", "file d\\\\a seq 1 type b\n"),
    ("seq 0", "file a seq 0 type b\n"),
    ("seq not a number", "file a seq x type b\n"),
    ("seq below 0 for an incremental file", "file a seq -2 type i\n"),
    ("no type", "file a seq 1 kind b\n"),
    ("an unknown type", "file a seq 1 type x\n"),
    ("two bases", "file a seq 1 type b\nfile b seq 2 type b\n"),
    ("incremental files out of order", "file a seq 2 type i\nfile b seq 1 type i\n"),
    ("the same incremental file twice", "file a seq 1 type i\nfile a seq 1 type i\n"),
    ("no newline at the end", "file a seq 1 type b"),
    ("a line too long", "file %s seq 1 type b\n" % ("a" * 1100)),
    ("a blank line", "# a comment\n\n"),
    ("blanks alone", "   \t \n"),
    ("a quote left open", "file \"a seq 1 type b\n"),
    ("a quote not followed by a blank", "file \"a\"b seq 1 type b\n"),
    ("a file not there, its keys in upper case", "FILE a SEQ 1 TYPE b\n"),
    ("a quoted name with a blank, not there", "file \"a b\" seq 1 type b\n"),
    ("a comment longer than a line", "#%s\nfile a seq 1 type b\n" % ("x" * 1100)),
]


def refusals(a, root):
    print("== manifests that stop the start")
    for name, text in BAD:
        p = Pair(a, root, "bad")
        for d in (p.b, p.r):
            os.makedirs(os.path.join(d, "appendonlydir"))
            with open(os.path.join(d, "appendonlydir", "appendonly.aof.manifest"), "w") as f:
                f.write(text)
        (cb, lb), (cr, lr) = p.refused("--appendonly", "yes")
        same("%s: the end" % name, cb, cr)
        same("%s: the lines" % name, lb, lr)
    # the same manifest stops a start with appendonly no too
    p = Pair(a, root, "bad")
    for d in (p.b, p.r):
        os.makedirs(os.path.join(d, "appendonlydir"))
        with open(os.path.join(d, "appendonlydir", "appendonly.aof.manifest"), "w") as f:
            f.write("file a seq 1 type x\n")
    (cb, lb), (cr, lr) = p.refused("--appendonly", "no")
    same("appendonly no, an unknown type: the end", cb, cr)
    same("appendonly no, an unknown type: the lines", lb, lr)


# a directory of Redis's: a base, then incremental files of commands
def made(d, base, incrs, extra=""):
    os.makedirs(os.path.join(d, "appendonlydir"), exist_ok=True)
    mf = "file appendonly.aof.1.base.aof seq 1 type b\n" + extra
    with open(os.path.join(d, "appendonlydir", "appendonly.aof.1.base.aof"), "wb") as f:
        f.write(base)
    for i, body in enumerate(incrs, 1):
        name = "appendonly.aof.%d.incr.aof" % i
        with open(os.path.join(d, "appendonlydir", name), "wb") as f:
            f.write(body)
        mf += "file %s seq %d type i\n" % (name, i)
    with open(os.path.join(d, "appendonlydir", "appendonly.aof.manifest"), "w") as f:
        f.write(mf)


def ent(*xs):
    out = b"*%d\r\n" % len(xs)
    for x in xs:
        x = x if isinstance(x, bytes) else str(x).encode()
        out += b"$%d\r\n%s\r\n" % (len(x), x)
    return out


# 5. and 6. Files cut short, and one not there
def cut(a, root):
    base = ent("SELECT", 0) + ent("SET", "a", "1")
    one = ent("SELECT", 0) + ent("SET", "b", "2") + ent("RPUSH", "l", "x", "y")
    two = ent("SELECT", 2) + ent("SET", "c", "3") + ent("SET", "d", "4")[:-5]
    print("== the last incremental file cut short")
    p = Pair(a, root, "cut-last")
    for d in (p.b, p.r):
        made(d, base, [one, two])
    (pb, cb, lb), (pr, cr, lr) = p.start("--appendonly", "yes", "--aof-load-truncated", "yes")
    same("the databases", keyspace(a.bendkv), keyspace(a.redis))
    keep = lambda ls: [l for l in ls if l.startswith(("DB loaded", "Opening", "Creating", "Fatal"))]
    same("the lines of the start", keep(logged(lb)), keep(logged(lr)))
    down(pb, cb)
    down(pr, cr)
    same("the file's size after the cut",
         os.path.getsize(os.path.join(p.b, "appendonlydir", "appendonly.aof.2.incr.aof")),
         os.path.getsize(os.path.join(p.r, "appendonlydir", "appendonly.aof.2.incr.aof")))
    print("== an incremental file before the last cut short")
    p = Pair(a, root, "cut-first")
    for d in (p.b, p.r):
        made(d, base, [two, one])
    (cb, lb), (cr, lr) = p.refused("--appendonly", "yes", "--aof-load-truncated", "yes")
    same("the end", cb, cr)
    same("the last line", keep(lb)[-1:], keep(lr)[-1:])
    same("the file's size after the cut",
         os.path.getsize(os.path.join(p.b, "appendonlydir", "appendonly.aof.1.incr.aof")),
         os.path.getsize(os.path.join(p.r, "appendonlydir", "appendonly.aof.1.incr.aof")))
    print("== a file the manifest names, not there")
    p = Pair(a, root, "missing")
    for d in (p.b, p.r):
        made(d, base, [one], "file appendonly.aof.9.incr.aof seq 9 type i\n")
        os.rename(os.path.join(d, "appendonlydir", "appendonly.aof.manifest"), os.path.join(d, "mf"))
        with open(os.path.join(d, "mf")) as f:
            t = f.read()
        # the missing file last, past the one there
        t = t.replace("file appendonly.aof.9.incr.aof seq 9 type i\n", "") + "file appendonly.aof.9.incr.aof seq 9 type i\n"
        with open(os.path.join(d, "appendonlydir", "appendonly.aof.manifest"), "w") as f:
            f.write(t)
    (cb, lb), (cr, lr) = p.refused("--appendonly", "yes")
    same("the end", cb, cr)
    same("the lines", lb, lr)


# 7. History files removed at the start
def history(a, root):
    print("== history files in the manifest")
    p = Pair(a, root, "history")
    base = ent("SELECT", 0) + ent("SET", "a", "1")
    for d in (p.b, p.r):
        made(d, base, [ent("SET", "b", "2")], "file appendonly.aof.7.incr.aof seq 7 type h\nfile old.base.aof seq 3 type h\n")
        for h in ("appendonly.aof.7.incr.aof", "old.base.aof"):
            with open(os.path.join(d, "appendonlydir", h), "wb") as f:
                f.write(ent("SET", "gone", "1"))
    (pb, cb, lb), (pr, cr, lr) = p.start("--appendonly", "yes")
    same("the databases", keyspace(a.bendkv), keyspace(a.redis))
    same("the lines of the start", logged(lb), logged(lr))
    down(pb, cb)
    down(pr, cr)
    same("the manifests", manifest(p.b), manifest(p.r))
    same("the files", files(p.b), files(p.r))
    print("== history kept with aof-disable-auto-gc yes")
    p = Pair(a, root, "history-kept")
    for d in (p.b, p.r):
        made(d, base, [ent("SET", "b", "2")], "file appendonly.aof.7.incr.aof seq 7 type h\n")
        with open(os.path.join(d, "appendonlydir", "appendonly.aof.7.incr.aof"), "wb") as f:
            f.write(ent("SET", "gone", "1"))
    (pb, cb, lb), (pr, cr, lr) = p.start("--appendonly", "yes", "--aof-disable-auto-gc", "yes")
    same("the lines of the start", logged(lb), logged(lr))
    down(pb, cb)
    down(pr, cr)
    same("the manifests", manifest(p.b), manifest(p.r))
    same("the files", files(p.b), files(p.r))


# 8. appendonly no with the directory: BGREWRITEAOF writes its base there
def off(a, root):
    print("== appendonly no, with the directory")
    p = Pair(a, root, "off")
    base = ent("SELECT", 0) + ent("SET", "a", "1")
    for d in (p.b, p.r):
        made(d, base, [ent("SET", "b", "2"), ent("SET", "c", "3")])
    (pb, cb, lb), (pr, cr, lr) = p.start("--appendonly", "no", "--aof-use-rdb-preamble", "no")
    for c in (cb, cr):
        cmd(c, "SET", "k", "v")
        cmd(c, "RPUSH", "l", "a", "b")
    same("BGREWRITEAOF's reply", *both(cb, cr, "BGREWRITEAOF"))
    settle(cb)
    settle(cr)
    same("the lines", [l for l in logged(lb) if "rewrite" in l or "history" in l],
         [l for l in logged(lr) if "rewrite" in l or "history" in l])
    down(pb, cb)
    down(pr, cr)
    same("the manifests", manifest(p.b), manifest(p.r))
    same("the files", files(p.b), files(p.r))
    with open(os.path.join(p.b, "appendonlydir", "appendonly.aof.2.base.aof"), "rb") as f:
        b = f.read()
    with open(os.path.join(p.r, "appendonlydir", "appendonly.aof.2.base.aof"), "rb") as f:
        r = f.read()
    same("the new base's commands", sorted(b.split(b"*")), sorted(r.split(b"*")))


# 9. Functions: libraries in a base, an RDB file or commands, and FUNCTION
# commands in the incremental files
LIB = "#!lua name=%s\nredis.register_function('%s', function(keys, args) return '%s' end)"


# FUNCTION LIST's libraries, in the order of their reprs: each server
# lists them in its own order (Redis's is its dict's)
def libraries(c):
    r = cmd(c, "FUNCTION", "LIST", "WITHCODE")
    if isinstance(r, tuple) and r[0] == b"*":
        return sorted(r[1], key=repr)
    return r


def calls(c):
    return [cmd(c, "FCALL", f, 0) for f in ("fa", "fb", "fc")]


def functions(a, root):
    for preamble in ("yes", "no"):
        print("== functions in Redis's directory, aof-use-rdb-preamble %s" % preamble)
        p = Pair(a, root, "fn-" + preamble)
        pr, cr = start(p.argv("r", "--appendonly", "yes", "--aof-use-rdb-preamble", preamble), a.redis, p.log("r"))
        cmd(cr, "FUNCTION", "LOAD", LIB % ("a", "fa", "a1"))
        cmd(cr, "FUNCTION", "LOAD", LIB % ("b", "fb", "b1"))
        cmd(cr, "SET", "k", "v")
        rewrite(cr)
        cmd(cr, "FUNCTION", "DELETE", "a")
        cmd(cr, "FUNCTION", "LOAD", "REPLACE", LIB % ("b", "fb", "b2"))
        cmd(cr, "FUNCTION", "LOAD", LIB % ("c", "fc", "c1"))
        want = libraries(cr), calls(cr)
        down(pr, cr)
        copy(p.r, p.b)
        (pb, cb, lb), (pr, cr, lr) = p.start("--appendonly", "yes")
        same("the libraries after the start", libraries(cb), libraries(cr))
        same("they are the ones Redis made", libraries(cb), want[0])
        same("FCALL of each function", calls(cb), calls(cr))
        same("they answer as before the start", calls(cb), want[1])
        same("the databases", keyspace(a.bendkv), keyspace(a.redis))
        same("the lines of the start", logged(lb), logged(lr))
        # BendKV's rewrite: its base of commands, a FUNCTION LOAD of each
        # library first
        rewrite(cb)
        cmd(cb, "FUNCTION", "LOAD", LIB % ("d", "fd", "d1"))
        want = libraries(cb)
        down(pb, cb)
        down(pr, cr)
        copy(p.b, p.r)
        (pb, cb, lb), (pr, cr, lr) = p.start("--appendonly", "yes")
        same("the libraries on BendKV's directory", libraries(cb), libraries(cr))
        same("they are the ones BendKV made", libraries(cb), want)
        same("the lines of that start", logged(lb), logged(lr))
        down(pb, cb)
        down(pr, cr)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default="build/bendkv")
    ap.add_argument("--bendkv", type=int, default=6380)
    ap.add_argument("--redis", type=int, default=6391)
    ap.add_argument("--dir", default="build/aofdir")
    a = ap.parse_args()
    a.bin = os.path.abspath(a.bin)
    root = os.path.abspath(a.dir)
    shutil.rmtree(root, ignore_errors=True)
    os.makedirs(root)
    from_redis(a, root, "yes")
    from_redis(a, root, "no")
    fresh(a, root)
    upgrade(a, root)
    refusals(a, root)
    cut(a, root)
    history(a, root)
    off(a, root)
    functions(a, root)
    if FAILS:
        print("FAILED: %d checks" % len(FAILS))
        sys.exit(1)
    print("ALL OK: Redis 7's append-only directory, as Redis reads and writes it")


if __name__ == "__main__":
    main()
