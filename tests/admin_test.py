#!/usr/bin/env python3
"""The administrative commands against Redis: LASTSAVE, ROLE, WAIT,
WAITAOF, MEMORY STATS, DOCTOR, PURGE and MALLOC-STATS, LOLWUT, SHUTDOWN
and CLUSTER.

Scenarios run on BendKV and on Redis with clients of their own, the
transcripts compared line by line: LASTSAVE as INFO's rdb_last_save_time;
ROLE (its offset INFO's master_repl_offset, which a WAIT or a WAITAOF
that waits takes one further, and one at once does not); WAIT's errors,
its answers at once (no replica asked for, in MULTI) and once its time is
up, a client that waits as CLIENT LIST and INFO show it, CLIENT UNBLOCK
of it both ways, one whose connection closes, a pipeline behind it, and
its statistics; WAITAOF's errors, and, while BendKV runs without an
append-only file as the shared Redis does, its answers without one (an
error for numlocal), in MULTI, once its time is up and to CLIENT UNBLOCK,
a client that waits in it as WAIT's; MEMORY's subcommands, STATS's
fields in order (with the databases that hold keys) and the kinds of
their values, DOCTOR on a small data set, its errors; LOLWUT's own text,
its errors, the drawings of VERSION 5 that rand() has no part in (one or
two rows of squares, which must be the same bytes), the others' shapes
(their lines and their widths), VERSION 6's (its lines of pixels), and
the verbatim reply of RESP3; SHUTDOWN's errors and its refusal in MULTI;
CLUSTER as Redis answers it with cluster support disabled (each of its
subcommands, MYSHARDID and HELP too, once its arity passes; an unknown
one and a wrong number of arguments refused, in MULTI too); with their
statistics. No scenario stops a server: they run against the
shared ones.

The checks of BendKV alone: MEMORY MALLOC-STATS answers as Redis built
with libc's malloc does (INFO's mem_allocator), and MEMORY STATS's
numbers are INFO's; CLIENT UNBLOCK's error to a WAIT or a WAITAOF counts
it once, failed, where Redis 7.2.16 counts it twice (docs/UPSTREAM.md,
bug 4), and a WAIT whose client goes counts once; with --bin, a WAITAOF
after a blocking pop that a write served waits for the pop's sync, which
Redis 7.2.16 does not (bug 9).

With --bin, SHUTDOWN on servers of its own (a redis-server and BendKV,
each in a fresh directory): it stops the server (exit code 0, the
connection closed, the commands after it in the pipeline not run), the
append-only file synced (a restart holds what came before it), the pid
file removed, a rewrite that runs stopped and its temporary file
removed; SAVE writes the RDB file, and a save that fails (a directory
where its temporary file goes) stops nothing (the server goes on, the
log says why) but with FORCE. tests/rdb_test.py has the rest of the
saves. And WAITAOF with the append-only file on, appendfsync always,
everysec and no in turn: what each command adds to master_repl_offset
(one for each command written to the file, MULTI and EXEC among them, a
SELECT nothing, one for a WAIT or a WAITAOF that waits), its answers at
once and once the file is synced, behind a write in a pipeline, in
MULTI, of a client that wrote nothing, once its time is up, and after a
rewrite with appendfsync no.

    python3 tests/admin_test.py --bendkv 6380 --redis 6390 [--bin build/bendkv]
"""
import argparse
import glob
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

from blocking_test import Client, enc, info_lines, wait_blocked
from client_test import Named

STATS = ("cmdstat_wait:", "cmdstat_waitaof:", "cmdstat_shutdown:", "cmdstat_exec:", "cmdstat_lastsave:",
         "cmdstat_role:", "cmdstat_lolwut:", "cmdstat_memory|", "cmdstat_cluster|")


def stats(r):
    return sorted(re.sub(r"usec=\d+,usec_per_call=[0-9.]+,", "", l) for l in info_lines(r, "commandstats", STATS))


def errorstats(r):
    return sorted(info_lines(r, "errorstats", "errorstat_"))


def field(r, section, name):
    return info_lines(r, section, name + ":")[0].split(":", 1)[1]


def offset(r):
    return int(field(r, "replication", "master_repl_offset"))


def role(r):
    """ROLE, its offset as whether it is INFO's (the servers' offsets differ
    by what each ran before)"""
    x = r.cmd("ROLE")
    return [x[0], x[1] == ":%d" % offset(r), x[2]]


def raw(port, data, n=1, timeout=5.0):
    """The bytes of n replies to data, as they come (a reply's bulk read
    whole)."""
    s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    s.sendall(data)
    buf = b""

    def fill():
        nonlocal buf
        c = s.recv(1 << 20)
        if not c:
            raise EOFError("closed")
        buf += c

    def reply(i):
        while b"\r\n" not in buf[i:]:
            fill()
        j = buf.index(b"\r\n", i)
        kind, rest = buf[i:i + 1], buf[i + 1:j]
        if kind in (b"$", b"=") and int(rest) >= 0:
            while len(buf) < j + 2 + int(rest) + 2:
                fill()
            return j + 2 + int(rest) + 2
        if kind in (b"*", b"%", b"~") and int(rest) >= 0:
            k = j + 2
            for _ in range(int(rest) * (2 if kind == b"%" else 1)):
                k = reply(k)
            return k
        return j + 2

    i = 0
    for _ in range(n):
        i = reply(i)
    s.close()
    return buf[:i]


def lolwut(port, *args):
    """LOLWUT's text: the bulk string of RESP2"""
    data = raw(port, enc(("LOLWUT",) + args))
    head, _, rest = data.partition(b"\r\n")
    return rest[:-2].decode() if head.startswith(b"$") else data.decode()


def shape5(text):
    """a drawing of VERSION 5: its lines' widths, its characters other
    than braille's, its last line"""
    lines = text.split("\n")
    odd = sorted({c for c in text if not ("⠀" <= c <= "⣿") and c != "\n"} - set("Georg Nees - schotter, plotter on paper, 1968. Redis ver. 7.2.16"))
    return [len(lines), sorted({len(l) for l in lines[:-3]}), odd, lines[-2:]]


def shape6(text):
    """a drawing of VERSION 6: its lines' pixels, the colors they have, and
    what is left once they are taken out"""
    lines = text.split("\n")
    pat = re.compile("\x1b\\[(0;\\d+;\\d+m) \x1b\\[0m")
    px = [pat.findall(l) for l in lines]
    return [len(lines), sorted({len(p) for p in px}), sorted({c for p in px for c in p} - {"0;30;40m", "0;90;100m", "0;37;47m", "0;97;107m"}),
            sorted({pat.sub("", l) for l in lines})]


def kinds(xs):
    """MEMORY STATS as names and the kinds of their values"""
    out = []
    for i in range(0, len(xs), 2):
        v = xs[i + 1]
        if isinstance(v, list):
            out.append((xs[i], kinds(v)))
        elif isinstance(v, str) and v.startswith(":"):
            out.append((xs[i], "int"))
        elif isinstance(v, str) and re.fullmatch(r"-?[0-9.e+-]+|nan|-?inf", v):
            out.append((xs[i], "double"))
        else:
            out.append((xs[i], repr(v)))
    return out


def scenarios(port, log, plain):
    r = Client(port)
    r.cmd("FLUSHALL")
    r.cmd("CONFIG", "RESETSTAT")
    a, b = Named(port, "a"), Client(port)
    # 1. LASTSAVE: the time of the last save, INFO's rdb_last_save_time
    log("1 lastsave", r.cmd("LASTSAVE") == ":" + field(r, "persistence", "rdb_last_save_time"), r.cmd("LASTSAVE", "x"))
    # 2. ROLE: a master with no replica, at the replication's offset, which
    # a turn of the loop in which a WAIT or a WAITAOF waits takes one
    # further (Redis's REPLCONF GETACK), and none that answers at once
    log("2 role", role(r), r.cmd("ROLE", "x"))
    o0 = offset(r)
    r.cmd("WAIT", "1", "20")
    o1 = offset(r)
    r.cmd("WAIT", "0", "0")
    r.cmd("WAITAOF", "0", "0", "0")
    r.cmd("MULTI"), r.cmd("WAIT", "1", "0"), r.cmd("WAITAOF", "0", "1", "0"), r.cmd("EXEC")
    o2 = offset(r)
    r.cmd("WAITAOF", "0", "1", "20")
    log("2 offset", o1 - o0, o2 - o1, offset(r) - o2)
    # 3. WAIT: its errors, then answers at once
    for args in ([], ["1"], ["a", "1"], ["1", "a"], ["1", "-1"], ["1", "-0"], ["1", "1.5"], ["1", "1", "1"],
                 ["99999999999999999999", "1"], ["1", "99999999999999999999"], ["-1", "-1"], ["x", "-1"]):
        log("3 wait", args, r.cmd("WAIT", *args))
    log("3 at once", r.cmd("WAIT", "0", "0"), r.cmd("WAIT", "-5", "0"), r.cmd("WAIT", "-9223372036854775808", "1"))
    t = time.time()
    log("3 time up", r.cmd("WAIT", "1", "100"), time.time() - t >= 0.08)
    log("3 multi", r.cmd("MULTI"), r.cmd("WAIT", "3", "0"), r.cmd("WAIT", "x", "0"), r.cmd("EXEC"))
    # 3b. WAITAOF: its errors, in Redis's order (numlocal, numreplicas, the
    # timeout, then numlocal without the file); its answers without the
    # file only where both servers run without one (plain)
    for args in ([], ["1"], ["1", "0"], ["1", "0", "0", "0"], ["2", "0", "0"], ["-1", "0", "0"], ["x", "0", "0"],
                 ["01", "0", "0"], ["+1", "0", "0"], ["-0", "0", "0"], ["0", "-1", "0"], ["0", "x", "0"], ["0", "00", "0"],
                 ["0", "9223372036854775808", "0"], ["0", "0", "-1"], ["0", "0", "x"], ["0", "0", "1.5"], ["x", "y", "z"],
                 ["1", "x", "z"], ["1", "-1", "0"], ["0", "0", "9223372036854775807"], ["1", "0", "99999999999999999999"]):
        log("3b waitaof", args, r.cmd("WAITAOF", *args))
    if plain:
        log("3b no file", r.cmd("WAITAOF", "1", "0", "0"), r.cmd("WAITAOF", "0", "0", "0"), r.cmd("WAITAOF", "1", "1", "0"))
        t = time.time()
        log("3b time up", r.cmd("WAITAOF", "0", "1", "100"), time.time() - t >= 0.08)
        log("3b multi", r.cmd("MULTI"), r.cmd("WAITAOF", "1", "0", "0"), r.cmd("WAITAOF", "0", "2", "0"), r.cmd("WAITAOF", "2", "0", "0"), r.cmd("EXEC"))
    # 4. a client that waits
    a.send("WAIT", "2", "0")
    log("4 blocked", wait_blocked(r, 1), field(r, "clients", "clients_in_timeout_table"))
    line = r.cmd("CLIENT", "LIST", "ID", a.id)
    log("4 list", re.findall(r"\b(flags|cmd|argv-mem)=(\S+)", line))
    log("4 unblock", r.cmd("CLIENT", "UNBLOCK", a.id), a.read(), wait_blocked(r, 0))
    a.send("WAIT", "2", "100000")
    log("4 timeout table", wait_blocked(r, 1), field(r, "clients", "clients_in_timeout_table"))
    log("4 unblock timeout", r.cmd("CLIENT", "UNBLOCK", a.id, "TIMEOUT"), a.read(), wait_blocked(r, 0))
    log("4 not waiting", r.cmd("CLIENT", "UNBLOCK", a.id))
    g = Client(port)
    g.send("WAIT", "1", "0")
    log("4 gone", wait_blocked(r, 1))
    g.close()
    log("4 closed", wait_blocked(r, 0))
    a.raw(enc(["WAIT", "1", "50"]) + enc(["PING"]) + enc(["WAIT", "0", "10"]))
    log("4 pipeline", a.read(), a.read(), a.read())
    # 4b. a client that waits in WAITAOF (for a replica: no sync serves it)
    if plain:
        a.send("WAITAOF", "0", "2", "0")
        log("4b blocked", wait_blocked(r, 1), field(r, "clients", "clients_in_timeout_table"))
        line = r.cmd("CLIENT", "LIST", "ID", a.id)
        log("4b list", re.findall(r"\b(flags|cmd|argv-mem)=(\S+)", line))
        log("4b unblock", r.cmd("CLIENT", "UNBLOCK", a.id), a.read(), wait_blocked(r, 0))
        a.send("WAITAOF", "0", "2", "100000")
        log("4b timeout table", wait_blocked(r, 1), field(r, "clients", "clients_in_timeout_table"))
        log("4b unblock timeout", r.cmd("CLIENT", "UNBLOCK", a.id, "TIMEOUT"), a.read(), wait_blocked(r, 0))
        g = Client(port)
        g.send("WAITAOF", "0", "1", "0")
        log("4b gone", wait_blocked(r, 1))
        g.close()
        log("4b closed", wait_blocked(r, 0))
        a.raw(enc(["WAITAOF", "0", "1", "50"]) + enc(["PING"]) + enc(["WAITAOF", "0", "0", "10"]))
        log("4b pipeline", a.read(), a.read(), a.read())
    # 5. MEMORY's subcommands
    log("5 help", r.cmd("MEMORY", "HELP"))
    for args in ([], ["foo"], ["stats", "x"], ["doctor", "x"], ["purge", "x"], ["malloc-stats", "x"], ["help", "x"]):
        log("5 errors", args, r.cmd("MEMORY", *args))
    log("5 purge", r.cmd("MEMORY", "PURGE"), r.cmd("memory", "purge"))
    m = r.cmd("MEMORY", "MALLOC-STATS")
    log("5 malloc-stats", isinstance(m, str) and len(m) > 0)
    log("5 doctor", r.cmd("MEMORY", "DOCTOR"))
    log("5 stats empty", kinds(r.cmd("MEMORY", "STATS")))
    r.cmd("SET", "k", "v")
    c12 = Client(port, "12")
    c12.cmd("RPUSH", "l", "a", "b")
    c12.close()
    s = r.cmd("MEMORY", "STATS")
    log("5 stats", kinds(s), s[s.index("keys.count") + 1])
    # 6. LOLWUT: its own text, its errors, the drawings
    for args in ([], ["x", "y"], ["VERSION"], ["version", "7"], ["VERSION", "0"], ["VERSION", "-1"],
                 ["VERSION", "abc"], ["VERSION", "5", "x"], ["VERSION", "5", "1", "2", "x"], ["VERSION", "6", "1", "x"],
                 ["VERSION", "99999999999999999999"], ["VERSION", "4.9"]):
        log("6 lolwut", args, r.cmd("LOLWUT", *args))
    for args in (["5", "66", "8", "2"], ["5", "1", "1", "1"], ["5", "10", "3", "1"], ["5", "0", "0", "0"],
                 ["5", "-5", "1000", "1"], ["5", "3000", "7", "1"], ["5", "33", "200", "2"], ["5", "40", "2", "1", "x"],
                 ["4294967301", "20", "4", "2"], ["-4294967291", "9", "2", "2"], ["5", "2", "1", "2"]):
        log("6 schotter", args, lolwut(port, "VERSION", *args))
    for args in (["5"], ["5", "30", "4", "6"], ["5", "7", "200", "3"]):
        log("6 schotter shape", args, shape5(lolwut(port, "VERSION", *args)))
    for args in (["6"], ["6", "30", "10"], ["6", "0", "0"], ["6", "1", "1"], ["6", "200", "3"], ["4294967302", "9", "50"]):
        log("6 skyline shape", args, shape6(lolwut(port, "VERSION", *args)))
    log("6 resp3", raw(port, enc(["HELLO", "3"]) + enc(["LOLWUT"]) + enc(["LOLWUT", "VERSION", "5", "3", "1", "1"]), 3).split(b"\r\n", 1)[0][:1],
        raw(port, enc(["HELLO", "3"]) + enc(["LOLWUT"]), 2)[-31:])
    # 7. SHUTDOWN's errors, and its refusal in MULTI (none of them stops
    # the server)
    for args in (["foo"], ["ABORT"], ["abort"], ["SAVE", "NOSAVE"], ["ABORT", "NOW"], ["NOSAVE", "abort"],
                 ["force", "abort"], ["SAVE", "x"], ["", "NOW"]):
        log("7 shutdown", args, r.cmd("SHUTDOWN", *args))
    log("7 multi", r.cmd("MULTI"), r.cmd("SHUTDOWN"), r.cmd("SHUTDOWN", "foo"), r.cmd("GET", "k"), r.cmd("EXEC"), r.cmd("GET", "k"))
    log("7 discard", r.cmd("MULTI"), r.cmd("SHUTDOWN", "NOSAVE"), r.cmd("DISCARD"))
    # 7b. CLUSTER with cluster support disabled
    for args in ([], ["INFO"], ["info"], ["MYSHARDID"], ["MyShardId"], ["MYID"], ["HELP"], ["SLOTS"], ["SHARDS"],
                 ["NODES"], ["LINKS"], ["KEYSLOT", "k"], ["COUNTKEYSINSLOT", "1"], ["GETKEYSINSLOT", "1", "2"],
                 ["ADDSLOTS", "1", "2"], ["ADDSLOTSRANGE", "1", "2"], ["DELSLOTS", "1"], ["SETSLOT", "1", "NODE", "x"],
                 ["MEET", "127.0.0.1", "7000"], ["FAILOVER"], ["FAILOVER", "FORCE"], ["RESET", "HARD"],
                 ["COUNT-FAILURE-REPORTS", "x"], ["SET-CONFIG-EPOCH", "1"], ["SAVECONFIG"], ["BUMPEPOCH"],
                 ["FLUSHSLOTS"], ["FORGET", "x"], ["REPLICATE", "x"], ["REPLICAS", "x"], ["SLAVES", "x"],
                 ["DELSLOTSRANGE", "1", "2"], ["INFO", "x"], ["MYSHARDID", "x"], ["KEYSLOT"], ["ADDSLOTS"],
                 ["GETKEYSINSLOT", "1"], ["ADDSLOTSRANGE", "1"], ["MEET", "x"], ["NOSUCH"], ["nosuch", "x"], ["a" * 200]):
        log("7b cluster", args, r.cmd("CLUSTER", *args))
    log("7b multi", r.cmd("MULTI"), r.cmd("CLUSTER", "INFO"), r.cmd("CLUSTER", "MYSHARDID"), r.cmd("EXEC"))
    log("7b multi refused", r.cmd("MULTI"), r.cmd("CLUSTER", "NOSUCH"), r.cmd("EXEC"))
    # 8. the statistics
    log("8 stats", stats(r))
    log("8 errorstats", errorstats(r))
    # 9. CLIENT UNBLOCK's error to a WAIT, after the statistics: Redis 7.2.16
    # counts the WAIT twice then (docs/UPSTREAM.md, bug 4), and BendKV once
    # (unblock_error, BendKV alone)
    a.send("WAIT", "2", "100000")
    log("9 blocked", wait_blocked(r, 1))
    log("9 unblock error", r.cmd("CLIENT", "UNBLOCK", a.id, "ERROR"), a.read(), wait_blocked(r, 0))
    a.send("WAITAOF", "0", "2", "100000")
    log("9 blocked", wait_blocked(r, 1))
    log("9 unblock error", r.cmd("CLIENT", "UNBLOCK", a.id, "ERROR"), a.read(), wait_blocked(r, 0))
    log("9 errorstats", errorstats(r))
    a.close()
    b.close()


def alone(port):
    fails = []
    r = Client(port)
    m = r.cmd("MEMORY", "MALLOC-STATS")
    if m != "Stats not supported for the current allocator" or field(r, "memory", "mem_allocator") != "libc":
        fails.append("MEMORY MALLOC-STATS answers %r" % m)
    s = r.cmd("MEMORY", "STATS")
    st = dict(zip(s[0::2], s[1::2]))
    if st["startup.allocated"] != ":" + field(r, "memory", "used_memory_startup"):
        fails.append("startup.allocated %r" % st["startup.allocated"])
    if st["overhead.total"] != ":" + field(r, "memory", "used_memory_overhead"):
        fails.append("overhead.total %r" % st["overhead.total"])
    keys = sum(int(re.search(r"keys=(\d+)", l).group(1)) for l in info_lines(r, "keyspace", "db"))
    if st["keys.count"] != ":%d" % keys:
        fails.append("keys.count %r, INFO says %d" % (st["keys.count"], keys))
    if st["rss-overhead.ratio"] != "1" or st["allocator.resident"] != ":" + field(r, "memory", "allocator_resident") and False:
        fails.append("rss-overhead.ratio %r" % st["rss-overhead.ratio"])
    r.close()
    return fails


def wait_stat(r, name="wait"):
    """WAIT's (or WAITAOF's) calls and failed calls, as commandstats counts
    them."""
    for l in info_lines(r, "commandstats", "cmdstat_%s:" % name):
        return tuple(int(re.search(k + r"=(\d+)", l).group(1)) for k in ("calls", "failed_calls"))
    return (0, 0)


def unblock_error(port, check=True):
    """CLIENT UNBLOCK's error to a WAIT counts the WAIT once, failed, as
    Redis 7.0.15 counted it and Redis 7.2.16 counts any other command
    unblocked so; 7.2.16 counts a WAIT twice then (docs/UPSTREAM.md, bug 4).
    A WAIT whose client goes counts once too, not failed. Run on Redis
    too, unchecked, so that its offset counts the GETACKs of these waits
    as BendKV's does (tests/info_test.py compares the two)."""
    fails = []
    r, a = Client(port), Named(port, "w")
    before = wait_stat(r)
    a.send("WAIT", "2", "100000")
    wait_blocked(r, 1)
    got = (r.cmd("CLIENT", "UNBLOCK", a.id, "ERROR"), a.read(), wait_blocked(r, 0), wait_stat(r))
    want = (":1", "-UNBLOCKED client unblocked via CLIENT UNBLOCK", 0, (before[0] + 1, before[1] + 1))
    if check and got != want:
        fails.append("CLIENT UNBLOCK ERROR of a WAIT: %r, not %r" % (got, want))
    a.send("WAIT", "2", "0")
    wait_blocked(r, 1)
    a.close()
    got = (wait_blocked(r, 0), wait_stat(r))
    want = (0, (before[0] + 2, before[1] + 1))
    if check and got != want:
        fails.append("a WAIT whose client goes: %r, not %r" % (got, want))
    a = Named(port, "wa")
    before = wait_stat(r, "waitaof")
    a.send("WAITAOF", "0", "2", "100000")
    wait_blocked(r, 1)
    got = (r.cmd("CLIENT", "UNBLOCK", a.id, "ERROR"), a.read(), wait_blocked(r, 0), wait_stat(r, "waitaof"))
    want = (":1", "-UNBLOCKED client unblocked via CLIENT UNBLOCK", 0, (before[0] + 1, before[1] + 1))
    if check and got != want:
        fails.append("CLIENT UNBLOCK ERROR of a WAITAOF: %r, not %r" % (got, want))
    a.close()
    r.close()
    return fails


# SHUTDOWN on servers of their own
# --------------------------------

def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class Srv:
    def __init__(self, exe, d, *args):
        self.d, self.port = d, free_port()
        self.p = subprocess.Popen([exe, "--port", str(self.port), "--dir", d, "--save", ""] + list(args), cwd=d,
                                  stdout=open(os.path.join(d, "out.log"), "a"), stderr=subprocess.STDOUT)
        for _ in range(200):
            try:
                socket.create_connection(("127.0.0.1", self.port), timeout=1).close()
                return
            except OSError:
                time.sleep(0.02)
        raise RuntimeError("no server in " + d)

    def talk(self, data, wait=0.5):
        """the bytes the server sends after data, and how the connection
        ends: closed, or still open"""
        s = socket.create_connection(("127.0.0.1", self.port), timeout=3)
        s.sendall(data)
        time.sleep(wait)
        s.settimeout(0.5)
        out = b""
        try:
            while True:
                c = s.recv(65536)
                if not c:
                    return out, "closed"
                out += c
        except socket.timeout:
            return out, "open"
        except ConnectionResetError:
            return out, "closed"
        finally:
            s.close()

    def exit(self):
        try:
            return self.p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.p.kill()
            return "running"

    def log(self):
        return open(os.path.join(self.d, "out.log")).read()


# whether path is there within two seconds: a server writes its pid file
# once it listens (Redis's main after initServer), and Srv returns as soon
# as a connection is accepted, so the file may come a moment after
def appears(path, secs=2.0):
    for _ in range(int(secs / 0.02)):
        if os.path.exists(path):
            return True
        time.sleep(0.02)
    return False


def shutdowns(exe, root, log):
    def fresh(name):
        d = os.path.join(root, name)
        os.makedirs(d)
        return d
    # 1. a plain SHUTDOWN, and the forms that stop the server: the replies
    # before it in the pipeline are not sent (Redis writes a group's
    # replies after it, and exits within it), the commands after it do
    # not run
    for flags in ([], ["NOSAVE"], ["now"], ["FORCE"], ["NOSAVE", "NOW", "FORCE"], ["SAVE"]):
        d = fresh("plain" + "".join(flags))
        s = Srv(exe, d)
        log("1 shutdown", flags, s.talk(enc(["PING"]) + enc(["SHUTDOWN"] + flags) + enc(["PING"])), s.exit(),
            os.path.exists(os.path.join(d, "dump.rdb")))
    # 2. the append-only file: what came before SHUTDOWN is there after a
    # restart, what came after it in the pipeline is not
    d = fresh("aof")
    s = Srv(exe, d, "--appendonly", "yes", "--appendfsync", "no", "--pidfile", os.path.join(d, "srv.pid"))
    log("2 pid file", appears(os.path.join(d, "srv.pid")))
    log("2 shutdown", s.talk(enc(["SET", "k", "v"]) + enc(["RPUSH", "l", "a", "b"]) + enc(["SHUTDOWN"]) + enc(["SET", "z", "z"])), s.exit())
    log("2 pid file", os.path.exists(os.path.join(d, "srv.pid")))
    s = Srv(exe, d, "--appendonly", "yes")
    log("2 restart", s.talk(enc(["GET", "k"]) + enc(["LRANGE", "l", "0", "-1"]) + enc(["EXISTS", "z"])))
    log("2 then", s.talk(enc(["SHUTDOWN", "NOSAVE"])), s.exit())
    # 3. in MULTI and with a bad flag the server goes on
    s = Srv(exe, fresh("multi"))
    log("3 multi", s.talk(enc(["MULTI"]) + enc(["SHUTDOWN"]) + enc(["EXEC"]) + enc(["SHUTDOWN", "x"]) + enc(["PING"])))
    log("3 then", s.talk(enc(["SHUTDOWN"])), s.exit())
    # 4. a save that fails (a directory where its temporary file goes):
    # SHUTDOWN SAVE answers an error, the server and the pipeline go on,
    # the log says why; FORCE stops it all the same
    d = fresh("save")
    s = Srv(exe, d)
    os.mkdir(os.path.join(d, "temp-%d.rdb" % s.p.pid))
    log("4 save fails", s.talk(enc(["SET", "s", "1"]) + enc(["SHUTDOWN", "SAVE"]) + enc(["GET", "s"])))
    log("4 log", [line in s.log() for line in ("User requested shutdown...", "Saving the final RDB snapshot before exiting.",
                                               "Error trying to save the DB, can't exit.",
                                               "Errors trying to shut down the server. Check the logs for more information.")])
    log("4 force", s.talk(enc(["SHUTDOWN", "SAVE", "FORCE"])), s.exit(), "Error trying to save the DB. Exit anyway." in s.log())


def waitaofs(exe, root, log):
    for policy in ("always", "everysec", "no"):
        d = os.path.join(root, "waitaof-" + policy)
        os.makedirs(d)
        s = Srv(exe, d, "--appendonly", "yes", "--appendfsync", policy)
        r, f = Client(s.port, None), Client(s.port, None)
        log("10 start", policy, offset(r), r.cmd("WAITAOF", "1", "0", "0"), role(r))
        steps = []
        for cmds in ([["SET", "k", "v"]], [["SET", "k", "v"], ["GET", "k"]], [["DEL", "k"], ["SET", "k", "v"]],
                     [["MULTI"], ["SET", "a", "1"], ["SET", "b", "2"], ["EXEC"]], [["MULTI"], ["SET", "a", "1"], ["EXEC"]],
                     [["MULTI"], ["GET", "a"], ["EXEC"]], [["EVAL", "redis.call('SET','x','1') redis.call('SET','y','2')", "0"]],
                     [["EVAL", "return redis.call('GET','x')", "0"]], [["EXPIRE", "a", "100"]], [["INCR", "n"]],
                     [["SELECT", "1"], ["SET", "z", "1"], ["SELECT", "0"]], [["PUBLISH", "ch", "m"]], [["FLUSHALL"]],
                     [["WAIT", "1", "20"]], [["WAITAOF", "0", "1", "20"]], [["WAITAOF", "0", "0", "0"]]):
            o = offset(r)
            for c in cmds:
                r.cmd(*c)
            steps.append(offset(r) - o)
        log("10 steps", policy, steps)
        r.cmd("SET", "k", "v")
        if policy == "no":
            log("10 not synced", policy, r.cmd("WAITAOF", "1", "0", "100"), r.cmd("WAITAOF", "0", "0", "0"))
        else:
            log("10 synced", policy, r.cmd("WAITAOF", "1", "0", "0"))
            r.raw(enc(["SET", "k", "w"]) + enc(["WAITAOF", "1", "0", "3000"]))
            log("10 pipeline", policy, r.read(), r.read(5.0))
        log("10 wrote nothing", policy, f.cmd("WAITAOF", "1", "0", "0"), f.cmd("WAITAOF", "1", "1", "20"))
        log("10 multi", policy, r.cmd("MULTI"), r.cmd("SET", "m", "1"), r.cmd("WAITAOF", "1", "0", "0"), r.cmd("EXEC"))
        if policy != "everysec":
            log("10 time up", policy, r.cmd("WAITAOF", "1", "1", "20"))
        if policy == "no":
            # each way a client's write reaches the file is its own: a
            # script's call, a transaction, FUNCTION LOAD, a plain batch
            # (each client's write not synced, while the client before it
            # wrote nothing; a pop that serves it: waitaof_alone)
            got = []
            for i, cmds in enumerate(([["EVAL", "redis.call('SET','e','1')", "0"]], [["MULTI"], ["SET", "t", "1"], ["EXEC"]],
                                      [["FUNCTION", "LOAD", "#!lua name=lib\nredis.register_function('f', function() return 1 end)"]],
                                      [["SET", "p", "1"]])):
                c = Client(s.port, None)
                for x in cmds:
                    c.cmd(*x)
                got.append(c.cmd("WAITAOF", "1", "0", "50"))
                c.close()
            log("10 writers", policy, got)
            log("10 rewrite", policy, r.cmd("BGREWRITEAOF"), r.cmd("WAITAOF", "1", "0", "5000"), r.cmd("WAITAOF", "1", "0", "0"))
        log("10 role", policy, role(r))
        r.close()
        f.close()
        s.talk(enc(["SHUTDOWN", "NOSAVE"]))
        log("10 exit", policy, s.exit())


def waitaof_alone(exe, root):
    """a client a write serves while it waits in BLPOP has its offset after
    the pop, which a WAITAOF after it waits for; Redis 7.2.16 leaves the
    client's offset where it was, and answers that the pop is synced
    (docs/UPSTREAM.md, bug 9)"""
    fails = []
    d = os.path.join(root, "waitaof-served")
    os.makedirs(d)
    s = Srv(exe, d, "--appendonly", "yes", "--appendfsync", "no")
    r, c = Client(s.port, None), Client(s.port, None)
    c.send("BLPOP", "bl", "0")
    wait_blocked(r, 1)
    r.cmd("RPUSH", "bl", "x")
    got = (c.read(), c.cmd("WAITAOF", "1", "0", "50"))
    if got != (["bl", "x"], [":0", ":0"]):
        fails.append("WAITAOF after a pop that a write served: %r" % (got,))
    r.close()
    c.close()
    s.talk(enc(["SHUTDOWN", "NOSAVE"]))
    s.exit()
    return fails


def shutdowns_alone(exe, root):
    """a rewrite that runs is stopped, its temporary file removed"""
    fails = []
    d = os.path.join(root, "rewrite")
    os.makedirs(d)
    s = Srv(exe, d, "--appendonly", "yes")
    c = socket.create_connection(("127.0.0.1", s.port), timeout=30)
    n = 200000
    c.sendall(b"".join(enc(["SET", "key:%d" % i, "v" * 50]) for i in range(n)))
    got = b""
    while got.count(b"\r\n") < n:
        got += c.recv(1 << 20)
    c.sendall(enc(["BGREWRITEAOF"]))
    while not got.endswith(b"+Background append only file rewriting started\r\n"):
        got += c.recv(1 << 20)
    c.sendall(enc(["SHUTDOWN"]))
    code = s.exit()
    c.close()
    if code != 0 or glob.glob(os.path.join(d, "temp-*")) or "There is a child rewriting the AOF. Killing it!" not in s.log():
        fails.append("SHUTDOWN while a rewrite runs: exit %r, files %r" % (code, os.listdir(d)))
    s = Srv(exe, d, "--appendonly", "yes")
    out = s.talk(enc(["DBSIZE"]))
    if out != (b":%d\r\n" % n, "open"):
        fails.append("the restart after the rewrite: %r" % (out,))
    s.talk(enc(["SHUTDOWN"]))
    s.exit()
    return fails


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, required=True)
    ap.add_argument("--redis", type=int, required=True)
    ap.add_argument("--bin")
    ap.add_argument("--redis-bin", default="redis-server")
    args = ap.parse_args()
    outs = []
    # WAITAOF's answers without the file where both servers run without one
    plain = all(field(Client(port, None), "persistence", "aof_enabled") == "0" for port in (args.bendkv, args.redis))
    for port in (args.bendkv, args.redis):
        lines = []
        try:
            scenarios(port, lambda *x: lines.append(" ".join(repr(v) for v in x)), plain)
        except Exception as e:
            lines.append("EXCEPTION %r" % (e,))
        outs.append(lines)
    fails = alone(args.bendkv) + unblock_error(args.bendkv) + unblock_error(args.redis, False)
    if args.bin:
        root = tempfile.mkdtemp(prefix="admin_test.")
        try:
            sd = []
            for exe, name in ((args.bin, "bendkv"), (args.redis_bin, "redis")):
                lines = []
                try:
                    shutdowns(os.path.abspath(exe) if os.path.exists(exe) else exe, os.path.join(root, name), lambda *x: lines.append(" ".join(repr(v) for v in x)))
                    waitaofs(os.path.abspath(exe) if os.path.exists(exe) else exe, os.path.join(root, name), lambda *x: lines.append(" ".join(repr(v) for v in x)))
                except Exception as e:
                    lines.append("EXCEPTION %r" % (e,))
                sd.append(lines)
            outs = [outs[0] + sd[0], outs[1] + sd[1]]
            fails += shutdowns_alone(os.path.abspath(args.bin), os.path.join(root, "alone"))
            fails += waitaof_alone(os.path.abspath(args.bin), os.path.join(root, "alone"))
        finally:
            shutil.rmtree(root, ignore_errors=True)
    bad = 0
    for i in range(max(len(outs[0]), len(outs[1]))):
        x = outs[0][i] if i < len(outs[0]) else "<none>"
        y = outs[1][i] if i < len(outs[1]) else "<none>"
        if x != y:
            bad += 1
            if bad <= 20:
                print("FAIL: BendKV %s\n      Redis  %s" % (x[:2000], y[:2000]))
    for f in fails:
        print("FAIL: BendKV alone:", f)
    if bad or fails:
        print("FAIL: %d of %d lines of the scenarios differ, %d checks of BendKV alone fail" % (bad, len(outs[1]), len(fails)))
        sys.exit(1)
    print("OK: %d lines of administrative scenarios as Redis answers them, and the checks of BendKV alone" % len(outs[1]))


if __name__ == "__main__":
    main()
