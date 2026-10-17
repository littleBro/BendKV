#!/usr/bin/env python3
"""The RDB file against Redis 7.0.15: SAVE, the save of SHUTDOWN and of
FLUSHALL, and the file loaded at the start. Every server runs in a fresh
directory of its own (its dir), on a port of its own, and every
comparison is between a redis-server and BendKV given the same file or
the same commands.

- Redis writes strings and lists that LZF compresses (runs, repeats at
  every distance, noise; up to 70,000 bytes): both start from the file
  and hold the same values.
- Redis writes the file (rdbcompression yes, with LZF, and no) of keys of
  every kind and encoding in several databases (strings of each length
  and integer encoding, lists of one node and of many, sets in an intset
  and in a table, hashes and sorted sets in a listpack and in a table or
  a skiplist, values at their encodings' limits, HyperLogLogs, GEO,
  streams with entries deleted and groups, keys with times, a key whose
  time passed before the save, databases left empty between full ones);
  BendKV and Redis each start from it, and every key of every database
  reads back the same from both (its type, encoding, value, a stream's
  as its DUMP, and the time it expires at), with DBSIZE and INFO's
  rdb_last_load_keys_loaded and _expired, and the log's lines.
- A file written here, as Redis 6 and before wrote them (version 9, the
  encodings Redis no longer writes: ziplists, zipmaps, quicklists of
  ziplists, lists, sets, hashes and sorted sets of types 1 to 4,
  EXPIRETIME in seconds, IDLE and FREQ), with keys whose time has passed
  (dropped and counted), empty keys (skipped), AUX fields of every kind,
  and a checksum of 0: both start from it alike, logging the same lines.
- The other way: BendKV runs the same commands (and RESTOREs the streams
  Redis made, BendKV having no stream command yet), SAVEs, and Redis
  starts from its file (redis-check-rdb finds it whole), and so does
  BendKV.
- Both ways again with a database of 10,000 keys (more than a slice of
  BendKV's writer, 4,096) and a file past 16 MB (more than one read of
  BendKV's start), and collections of 10,000 members.
- SAVE, LASTSAVE and INFO's persistence fields (rdb_changes_since_last_save
  among them: tests/bgsave_test.py counts each write's), SAVE
  refused in MULTI and with arguments, COMMAND INFO and DOCS, a SAVE that
  fails (a directory where its temporary file goes), its statistics and
  CONFIG RESETSTAT; a SAVE in a pipeline saves what came before it and
  not what came after; FLUSHALL saves an empty file with save points and
  none without, whatever follows it; dbfilename and rdbchecksum no (eight
  zero bytes for the checksum), both servers starting from either file.
- SHUTDOWN: without save points it saves nothing, with SAVE or with save
  points it saves, NOSAVE saves nothing, a restart holds what was saved;
  a save that fails stops nothing but with FORCE (Redis's error, the
  batch going on, other clients served, the log's lines); with the
  append-only file both files are written, and the start reads the
  append-only file and leaves the RDB file aside; a SAVE with the
  append-only file, what comes after it in its pipeline and in another
  client's requests reaching the append-only file; another client's
  FLUSHALL in the group of a SHUTDOWN that saves, which never runs (the
  files keep the key) unless the save fails.
- Files that do not load: cut short, a wrong checksum, version 11, 0 and
  -1, a wrong signature, a database past the server's, a type that is
  none, an empty file, a directory, a module's data and a module's value:
  both servers refuse to start, with the same reason in their logs. A
  file of a stream loads on both. A checksum of 0, and a wrong one with
  rdbchecksum no, load on both.
- Libraries of functions in the file: Redis's (with LZF and without) and
  BendKV's, both ways, and one of 7.0's release candidates (FUNCTION):
  both start from each with the same libraries (FUNCTION LIST WITHCODE,
  FCALL, INFO's counts); files whose library does not load (Lua that does
  not compile, a library twice, a function twice, a library cut short, a
  library with no metadata): both stop, with the same lines.
- BendKV alone: the short form loads no RDB file.

    python3 tests/rdb_test.py --bendkv build/bendkv [--redis redis-server] [--dir build/rdb]
"""
import argparse
import os
import random
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import time
import traceback

from diff_test import Conn
from dump_test import cases, cmd, crc64, flat, old_bodies, rlen, rstr

bad = 0
n = 0


def fail(what, x="", y=""):
    global bad
    bad += 1
    if bad <= 40:
        print("FAIL: %s\n      BendKV %s\n      Redis  %s" % (what, str(x)[:600], str(y)[:600]))


def check(what, ok, why=""):
    global n
    n += 1
    if not ok:
        fail(what, why)


def same(what, x, y):
    global n
    n += 1
    if x != y:
        fail(what, x, y)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def run(c, *xs):
    c.send([cmd(*xs)])
    return c.reply()


def shut(c, *xs):
    """a SHUTDOWN that stops the server: the connection closes, unanswered"""
    c.send([cmd(*xs)])
    try:
        return c.reply()
    except (EOFError, ConnectionResetError):
        return "closed"


# every server started, killed at the end whatever stopped the test
SERVERS = []


class Srv:
    """A server started in directory d (its dir, and its working
    directory), its log in d/out.log: up once it answers PING, or exited
    (code: its exit code, None while it runs)."""

    def __init__(self, exe, d, *args):
        self.exe, self.d, self.port = exe, d, free_port()
        SERVERS.append(self)
        os.makedirs(d, exist_ok=True)
        self.p = subprocess.Popen([exe, "--port", str(self.port), "--dir", d, "--bind", "127.0.0.1"] + list(args), cwd=d,
                                  stdout=open(os.path.join(d, "out.log"), "a"), stderr=subprocess.STDOUT)
        self.code = None
        for _ in range(600):
            if self.p.poll() is not None:
                self.code = self.p.returncode
                return
            try:
                c = Conn(self.port)
                c.send([[b"PING"]])
                if c.reply() == (b"+", b"PONG"):
                    c.sock.close()
                    return
            except (OSError, EOFError):
                pass
            time.sleep(0.05)
        self.p.kill()
        raise RuntimeError("no server in " + d)

    def conn(self):
        return Conn(self.port)

    def pid(self):
        c = self.conn()
        x = info(c, "server", "process_id")
        c.sock.close()
        return x

    def exit(self, timeout=20):
        try:
            return self.p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.p.kill()
            self.p.wait()
            return "running"

    def kill(self):
        if self.p.poll() is None:
            self.p.kill()
            self.p.wait()

    def log(self):
        with open(os.path.join(self.d, "out.log"), errors="replace") as f:
            return f.read()

    def has(self, line):
        return line in self.log()


def info(c, section, name):
    text = run(c, "INFO", section)[1].decode()
    for l in text.split("\r\n"):
        if l.startswith(name + ":"):
            return l.split(":", 1)[1]
    return None


def talk(port, cmds, wait=0.5):
    """the replies to a pipeline, and whether the connection was then
    closed"""
    c = Conn(port)
    c.send([cmd(*x) for x in cmds])
    out = []
    try:
        for _ in cmds:
            out.append(c.reply())
    except (EOFError, ConnectionResetError):
        return out, "closed"
    c.sock.settimeout(wait)
    try:
        data = c.sock.recv(1)
        state = "closed" if not data else "more"
    except socket.timeout:
        state = "open"
    except ConnectionResetError:
        state = "closed"
    c.sock.close()
    return out, state


# Reading every database
# ----------------------

def dump_all(c, dbs=16):
    """every key of every database: its type, encoding, the time it expires
    at (PEXPIRETIME: both read the same file), and its value (a hash's
    pairs and a set's members sorted, as the servers walk their tables in
    orders of their own); and each database's size"""
    out = []
    for db in range(dbs):
        run(c, "SELECT", db)
        size = run(c, "DBSIZE")
        keys = sorted(flat(run(c, "KEYS", "*")))
        for k in keys:
            t = run(c, "TYPE", k)[1]
            enc = run(c, "OBJECT", "ENCODING", k)
            exp = run(c, "PEXPIRETIME", k)
            if t == b"string":
                v = run(c, "GET", k)
            elif t == b"list":
                v = flat(run(c, "LRANGE", k, 0, -1))
            elif t == b"set":
                v = sorted(flat(run(c, "SMEMBERS", k)))
            elif t == b"hash":
                xs = flat(run(c, "HGETALL", k))
                v = sorted(zip(xs[0::2], xs[1::2]))
            elif t == b"zset":
                xs = flat(run(c, "ZRANGE", k, 0, -1, "WITHSCORES"))
                v = list(zip(xs[0::2], xs[1::2]))
            elif t == b"stream":
                comp = flat(run(c, "CONFIG", "GET", "rdbcompression"))[1]
                run(c, "CONFIG", "SET", "rdbcompression", "no")
                v = run(c, "DUMP", k)
                run(c, "CONFIG", "SET", "rdbcompression", comp)
            else:
                v = None
            out.append((db, k, t, enc, exp, v))
        out.append((db, "dbsize", size))
    run(c, "SELECT", 0)
    return out


def unenc(xs):
    """a dump without the encodings: a value the commands made keeps the
    encoding they gave it (a hash shrunk below its listpack's limits stays
    a table), where one loaded from a file takes the encoding its size
    gives (rdbLoadObject)"""
    return [x[:3] + x[4:] if len(x) == 6 else x for x in xs]


def same_dbs(what, x, y):
    global n
    n += 1
    if x != y:
        xs, ys = set(map(repr, x)), set(map(repr, y))
        fail(what, sorted(xs - ys)[:5], sorted(ys - xs)[:5])


def loads(c):
    return (info(c, "persistence", "rdb_last_load_keys_loaded"), info(c, "persistence", "rdb_last_load_keys_expired"))


# Keys of every kind
# ------------------

def fill_cmds(seed):
    """the commands that make keys of every kind and encoding in several
    databases (dump_test's values, each a key of its own), with times"""
    rnd = random.Random(seed)
    out = []
    for i, (name, canon, cmds) in enumerate(cases(rnd)):
        db = [0, 0, 0, 1, 3, 15][i % 6]
        for c in cmds:
            out.append((db, [c[0], b"key:%d" % i] + c[2:]))
    far = int(time.time() * 1000) + 10 ** 9
    for db in (0, 3):
        out += [(db, cmd("SET", "ttl:s", "v", "PXAT", far)), (db, cmd("RPUSH", "ttl:l", "a", "b")),
                (db, cmd("PEXPIREAT", "ttl:l", far + 1)), (db, cmd("HSET", "ttl:h", "f", "v")),
                (db, cmd("PEXPIREAT", "ttl:h", far + 2)), (db, cmd("SADD", "ttl:z", "1", "2")),
                (db, cmd("EXPIREAT", "ttl:z", far // 1000))]
    out += [(0, cmd("PFADD", "hll", *["e%d" % i for i in range(50)])),
            (0, cmd("PFADD", "hll2", *["e%d" % i for i in range(5000)])),
            (1, cmd("GEOADD", "geo", "13.361389", "38.115556", "Palermo", "15.087269", "37.502669", "Catania")),
            (7, cmd("SET", "", "empty key")), (7, cmd("SET", b"\x00\xff\r\n", b"\x00\xff"))]
    return out


def stream_cmds():
    """the commands that make streams on Redis (BendKV has none of them
    yet): entries of the master's fields and of their own, deleted and
    trimmed, nodes of every size, groups with pending entries and
    consumers, a stream with no entry, and one with a time"""
    far = int(time.time() * 1000) + 10 ** 9
    out = [(0, cmd("XADD", "st:a", "1-%d" % i, "f", str(i), "g", "v" * (i % 50))) for i in range(1, 400)]
    out += [(0, cmd("XADD", "st:a", "2-%d" % i, "h", str(i))) for i in range(1, 50)]
    out += [(0, cmd("XDEL", "st:a", "1-1", "1-7", "2-49", *["1-%d" % i for i in range(200, 300)])),
            (0, cmd("XTRIM", "st:a", "MAXLEN", "=", 300)),
            (0, cmd("XGROUP", "CREATE", "st:a", "g1", "0")), (0, cmd("XGROUP", "CREATE", "st:a", "7", "$")),
            (0, cmd("XREADGROUP", "GROUP", "g1", "alice", "COUNT", 20, "STREAMS", "st:a", ">")),
            (0, cmd("XREADGROUP", "GROUP", "g1", "bob", "COUNT", 5, "STREAMS", "st:a", ">")),
            (0, cmd("XACK", "st:a", "g1", "1-110", "1-111")), (0, cmd("XGROUP", "CREATECONSUMER", "st:a", "7", "carol")),
            (2, cmd("XGROUP", "CREATE", "st:empty", "g", "$", "MKSTREAM")),
            (2, cmd("XADD", "st:ttl", "%d-%d" % (2 ** 64 - 1, 2 ** 64 - 2), "f", "v")),
            (2, cmd("PEXPIREAT", "st:ttl", far))]
    return out


def stream_payloads(a, root):
    """the streams of stream_cmds, as Redis DUMPs them with rdbcompression
    no, and the times they expire at"""
    r = Srv(a.redis, os.path.join(root, "streams"), "--save", "", "--rdbcompression", "no")
    c = r.conn()
    out = []
    for db, x in stream_cmds():
        run(c, "SELECT", db)
        run(c, *x)
    for db in (0, 2):
        run(c, "SELECT", db)
        for k in sorted(flat(run(c, "KEYS", "*"))):
            out.append((db, k, run(c, "DUMP", k)[1], int(run(c, "PEXPIRETIME", k)[1])))
    shut(c, "SHUTDOWN", "NOSAVE")
    r.exit()
    return out


def fill(c, seed):
    for db, x in fill_cmds(seed):
        run(c, "SELECT", db)
        r = run(c, *x)
        if r[0] == b"-":
            raise SystemExit("rdb_test.py: %r answered %r" % (x[:3], r))
    run(c, "SELECT", 0)


def big_cmds(seed):
    """a database of 10,000 keys, more than the 4,096 a slice of BendKV's
    writer holds (the slices after the first, without the header, the
    checksum carried from one to the next), of 1,700 random bytes each,
    which LZF leaves as they are, so that the file passes 16 MB (BendKV's
    start reads it in several reads and joins them), some with times; and
    collections of 10,000 members"""
    rnd = random.Random(seed)
    far = int(time.time() * 1000) + 10 ** 9
    out = []
    for i in range(10000):
        out.append((0, cmd("SET", "big:%d" % i, rnd.randbytes(1700))))
        if i % 97 == 0:
            out.append((0, cmd("PEXPIREAT", "big:%d" % i, far + i)))
    out += [(1, cmd("HSET", "h", *[x for j in range(10000) for x in ("f%d" % j, "v%d" % rnd.randrange(10 ** 6))])),
            (1, cmd("SADD", "s", *["m%d" % j for j in range(10000)])),
            (1, cmd("ZADD", "z", *[x for j in range(10000) for x in (rnd.randrange(10 ** 6) / 8, "z%d" % j)])),
            (1, cmd("RPUSH", "l", *[rnd.randbytes(rnd.randrange(1, 40)) for _ in range(10000)])),
            (2, cmd("SET", "after", "the big database"))]
    return out


def fill_big(c, seed):
    """big_cmds, 500 at a time in a pipeline"""
    xs, db = big_cmds(seed), None
    for i in range(0, len(xs), 500):
        cmds = []
        for d, x in xs[i:i + 500]:
            if d != db:
                cmds.append(cmd("SELECT", d))
                db = d
            cmds.append(x)
        c.send(cmds)
        for x in cmds:
            r = c.reply()
            if r[0] == b"-":
                raise SystemExit("rdb_test.py: %r answered %r" % (x[:2], r))
    run(c, "SELECT", 0)


# Files written here
# ------------------

def file(entries, version=10, aux=(), checksum=True):
    out = b"REDIS%04d" % version
    for k, v in aux:
        out += b"\xfa" + rstr(k) + rstr(v)
    out += b"".join(entries) + b"\xff"
    if version >= 5:
        out += struct.pack("<Q", crc64(out) if checksum else 0)
    return out


def select(db):
    return b"\xfe" + rlen(db)


def key(k, body, ms=None, secs=None):
    """a key: its time (ms or s since 1970), then a payload's body with
    the key between its type and its value"""
    t = b""
    if ms is not None:
        t = b"\xfc" + struct.pack("<q", ms)
    if secs is not None:
        t = b"\xfd" + struct.pack("<i", secs)
    return t + body[:1] + rstr(k) + body[1:]


def old_file():
    rnd = random.Random(5)
    now = int(time.time())
    ents = [select(0), b"\xfb" + rlen(100) + rlen(3)]
    for i, (name, body) in enumerate(old_bodies(rnd)):
        ents.append(key(b"old:%d" % i, body))
    ents += [key(b"past:ms", b"\x00" + rstr(b"gone"), ms=1000),
             key(b"past:0", b"\x00" + rstr(b"gone"), ms=0),
             key(b"past:s", b"\x00" + rstr(b"gone"), secs=1000),
             key(b"past:neg", b"\x00" + rstr(b"gone"), ms=-5),
             key(b"none:-1", b"\x00" + rstr(b"kept"), ms=-1),
             key(b"future:s", b"\x00" + rstr(b"v"), secs=now + 10 ** 6),
             key(b"future:ms", b"\x01\x02" + rstr(b"a") + rstr(b"b"), ms=(now + 10 ** 6) * 1000),
             b"\xf8" + rlen(100) + key(b"idle", b"\x00" + rstr(b"i")),
             b"\xf9\x07" + key(b"freq", b"\x00" + rstr(b"f")),
             key(b"empty:list", b"\x01\x00"), key(b"empty:set", b"\x02\x00"), key(b"empty:hash", b"\x04\x00"),
             key(b"empty:zset", b"\x03\x00"), key(b"empty:ql", b"\x0e\x00"),
             select(9), key(b"nine", b"\x00\xc0\x09"), key(b"int16", b"\x00\xc1\x39\x30"),
             key(b"int32", b"\x00\xc2\x00\x00\x00\x80"), b"\xfa" + rstr(b"late") + rstr(b"aux")]
    aux = [(b"redis-ver", b"6.2.14"), (b"redis-bits", b"\xc0\x40"[0:0] + b"64"), (b"ctime", b"%d" % (now - 50)),
           (b"used-mem", b"123456789"), (b"aof-preamble", b"0"), (b"repl-stream-db", b"0"),
           (b"repl-id", b"x" * 40), (b"repl-offset", b"0"), (b"%info", b"anything"), (b"lua", b"x"),
           (b"unknown-field", b"value")]
    return file(ents, version=9, aux=aux, checksum=False)


# a minimal reader of a file's keys of strings: [(db, key, value)]
def file_keys(data):
    i = 9
    db = 0
    out = []

    def rlenat(i):
        b = data[i]
        if b >> 6 == 0:
            return b & 63, i + 1, None
        if b >> 6 == 1:
            return ((b & 63) << 8) | data[i + 1], i + 2, None
        if b == 0x80:
            return struct.unpack(">I", data[i + 1:i + 5])[0], i + 5, None
        if b == 0x81:
            return struct.unpack(">Q", data[i + 1:i + 9])[0], i + 9, None
        return b & 63, i + 1, "enc"

    def rstrat(i):
        k, i, enc = rlenat(i)
        if enc and k == 3:
            # LZF (Redis's library code): skipped, its bytes not read
            clen, i, _ = rlenat(i)
            _, i, _ = rlenat(i)
            return b"<lzf>", i + clen
        if enc:
            w = [1, 2, 4][k]
            return str(int.from_bytes(data[i:i + w], "little", signed=True)).encode(), i + w
        return data[i:i + k], i + k

    while True:
        op = data[i]
        i += 1
        if op == 0xff:
            return out
        if op == 0xfa:
            _, i = rstrat(i)
            _, i = rstrat(i)
        elif op == 0xfe:
            db, i, _ = rlenat(i)
        elif op == 0xfb:
            _, i, _ = rlenat(i)
            _, i, _ = rlenat(i)
        elif op == 0xfc:
            i += 8
        elif op == 0xf5:
            # a library of functions (RDB_OPCODE_FUNCTION2): its code
            _, i = rstrat(i)
        elif op == 0:
            k, i = rstrat(i)
            v, i = rstrat(i)
            out.append((db, k, v))
        else:
            raise ValueError("rdb_test.py: a value of type %d" % op)


def read(path):
    with open(path, "rb") as f:
        return f.read()


# The parts
# ---------

def redis_writes(a, root):
    """Redis writes the file (with LZF and without); both start from it"""
    for comp in ("yes", "no"):
        d = os.path.join(root, "rw-" + comp)
        r = Srv(a.redis, os.path.join(d, "redis"), "--save", "", "--rdbcompression", comp)
        c = r.conn()
        fill(c, 1)
        for db, x in stream_cmds():
            run(c, "SELECT", db)
            run(c, *x)
        run(c, "SELECT", 0)
        # a key whose time passes before the save, which the server may
        # still hold (its sweep has not run) and then writes with its time;
        # deleted after the save (DEL: BendKV's reads do not delete it)
        run(c, "SET", "soon", "x", "PX", "1")
        time.sleep(0.05)
        same("SAVE (Redis, rdbcompression %s)" % comp, run(c, "SAVE"), (b"+", b"OK"))
        run(c, "DEL", "soon")
        live = unenc(dump_all(c))
        shut(c, "SHUTDOWN", "NOSAVE")
        r.exit()
        f = os.path.join(d, "redis", "dump.rdb")
        for name in ("bendkv", "redis2"):
            os.makedirs(os.path.join(d, name))
            shutil.copy(f, os.path.join(d, name, "dump.rdb"))
        b = Srv(a.bin, os.path.join(d, "bendkv"), "--save", "")
        r2 = Srv(a.redis, os.path.join(d, "redis2"), "--save", "")
        try:
            if b.code is not None:
                fail("BendKV starts from Redis's file (rdbcompression %s): exit %s" % (comp, b.code), b.log()[-2000:])
                continue
            cb, cr = b.conn(), r2.conn()
            xb, xr = dump_all(cb), dump_all(cr)
            same_dbs("BendKV and Redis from Redis's file (rdbcompression %s)" % comp, xb, xr)
            same_dbs("Redis from its file holds what it saved (rdbcompression %s)" % comp, unenc(xr), live)
            same("the keys loaded and expired (rdbcompression %s)" % comp, loads(cb), loads(cr))
            for line in ("Loading RDB produced by version 7.0.15", "Done loading RDB, keys loaded: ",
                         "DB loaded from disk: "):
                check("BendKV's log: %s" % line, b.has(line), b.log()[-1500:])
        finally:
            b.kill()
            r2.kill()


def lzf_value(rnd):
    """a value LZF compresses as Redis does: runs, repeats of what came
    before at distances up to 9,000 (past LZF's 8,192, and overlapping
    their own start), and noise, of up to 70,000 bytes"""
    n = rnd.choice([30, 100, 1000, 8000, 20000, 70000])
    alphabet = bytes(rnd.sample(range(256), rnd.randint(1, 40)))
    cur = b""
    while len(cur) < n:
        x = rnd.random()
        if x < 0.3 and cur:
            d = rnd.randint(1, min(len(cur), 9000))
            k = rnd.randint(1, 300)
            src = cur[-d:]
            cur += (src * (k // len(src) + 1))[:k]
        elif x < 0.5:
            cur += bytes([rnd.choice(alphabet)]) * rnd.randint(1, 500)
        else:
            cur += bytes(rnd.choice(alphabet) for _ in range(rnd.randint(1, 60)))
    return cur[:n]


def lzf_values(a, root):
    """Redis writes strings and lists that LZF compresses (rdbcompression
    yes: a string, or a list's node, of more than 20 bytes that LZF makes
    shorter); both start from the file and hold the same values"""
    d = os.path.join(root, "lzf")
    r = Srv(a.redis, os.path.join(d, "redis"), "--save", "", "--rdbcompression", "yes")
    c = r.conn()
    rnd = random.Random(7)
    for i in range(300):
        v = lzf_value(rnd)
        if i % 3 == 0:
            run(c, "RPUSH", "l:%d" % i, *[v[j:j + 50] for j in range(0, min(len(v), 20000), 50)])
        else:
            run(c, "SET", "s:%d" % i, v)
    same("SAVE (Redis, LZF)", run(c, "SAVE"), (b"+", b"OK"))
    shut(c, "SHUTDOWN", "NOSAVE")
    r.exit()
    srvs = []
    for name, exe in (("bendkv", a.bin), ("redis2", a.redis)):
        os.makedirs(os.path.join(d, name))
        shutil.copy(os.path.join(d, "redis", "dump.rdb"), os.path.join(d, name, "dump.rdb"))
        srvs.append(Srv(exe, os.path.join(d, name), "--save", ""))
    b, r2 = srvs
    try:
        if b.code is not None:
            fail("BendKV starts from Redis's file of LZF values: exit %s" % b.code, b.log()[-1500:])
            return
        same_dbs("BendKV and Redis from Redis's file of LZF values", dump_all(b.conn(), 1), dump_all(r2.conn(), 1))
    finally:
        b.kill()
        r2.kill()


def written_here(a, root):
    """a file written here as Redis 6 and before wrote them; both start from it"""
    d = os.path.join(root, "old")
    data = old_file()
    srvs = []
    for name, exe in (("bendkv", a.bin), ("redis", a.redis)):
        os.makedirs(os.path.join(d, name))
        with open(os.path.join(d, name, "dump.rdb"), "wb") as f:
            f.write(data)
        srvs.append(Srv(exe, os.path.join(d, name), "--save", ""))
    b, r = srvs
    try:
        if b.code is not None or r.code is not None:
            fail("both start from a file of the old encodings: BendKV %s, Redis %s" % (b.code, r.code),
                 b.log()[-1500:], r.log()[-1500:])
            return
        cb, cr = b.conn(), r.conn()
        same_dbs("BendKV and Redis from a file of the old encodings", dump_all(cb), dump_all(cr))
        same("the keys loaded and expired (old encodings)", loads(cb), loads(cr))
        for line in ("Loading RDB produced by version 6.2.14", "RDB memory usage when created 117.74 Mb",
                     "RDB '%info': anything", "rdbLoadObject skipping empty key: empty:list",
                     "RDB file was saved with checksum disabled: no check performed.",
                     "Done loading RDB, keys loaded: ", "keys expired: 4, empty keys skipped: 5."):
            same("the log has %r" % line, b.has(line), r.has(line))
    finally:
        b.kill()
        r.kill()


def bendkv_writes(a, root):
    """BendKV runs the commands and SAVEs; Redis starts from its file, and
    BendKV too"""
    d = os.path.join(root, "bw")
    sts = stream_payloads(a, d)
    b = Srv(a.bin, os.path.join(d, "bendkv"), "--save", "")
    c = b.conn()
    fill(c, 2)
    for db, k, p, at in sts:
        run(c, "SELECT", db)
        same("RESTORE of Redis's stream %s" % k, run(c, "RESTORE", k, at if at > 0 else 0, p, *(["ABSTTL"] if at > 0 else [])), (b"+", b"OK"))
    run(c, "SELECT", 0)
    run(c, "SET", "soon", "x", "PX", "1")
    time.sleep(0.05)
    same("SAVE (BendKV)", run(c, "SAVE"), (b"+", b"OK"))
    run(c, "DEL", "soon")
    live = unenc(dump_all(c))
    lives = loads(c)
    shut(c, "SHUTDOWN", "NOSAVE")
    b.exit()
    f = os.path.join(d, "bendkv", "dump.rdb")
    if shutil.which("redis-check-rdb"):
        out = subprocess.run(["redis-check-rdb", f], capture_output=True, text=True).stdout
        check("redis-check-rdb finds BendKV's file whole", "RDB looks OK!" in out and "Checksum OK" in out, out[-800:])
    for name in ("redis", "bendkv2"):
        os.makedirs(os.path.join(d, name))
        shutil.copy(f, os.path.join(d, name, "dump.rdb"))
    r = Srv(a.redis, os.path.join(d, "redis"), "--save", "")
    b2 = Srv(a.bin, os.path.join(d, "bendkv2"), "--save", "")
    try:
        if r.code is not None or b2.code is not None:
            fail("both start from BendKV's file: BendKV %s, Redis %s" % (b2.code, r.code), b2.log()[-1500:], r.log()[-1500:])
            return
        cr, cb = r.conn(), b2.conn()
        xr = dump_all(cr)
        xb = dump_all(cb)
        same_dbs("Redis from BendKV's file holds what BendKV saved", unenc(xr), live)
        same_dbs("BendKV from its own file holds what it saved", unenc(xb), live)
        same_dbs("BendKV and Redis from BendKV's file", xb, xr)
        same("the keys loaded and expired from BendKV's file", loads(cb), loads(cr))
        check("BendKV counted no load before", lives == ("0", "0"), lives)
        for line in ("Loading RDB produced by version 7.0.15", "RDB age ", "Done loading RDB, keys loaded: "):
            check("Redis's log of BendKV's file: %s" % line, r.has(line), r.log()[-1500:])
    finally:
        r.kill()
        b2.kill()


def big(a, root):
    """a database of 10,000 keys and a file past 16 MB, both ways: Redis's
    file read by both, and BendKV's read by Redis and by BendKV"""
    d = os.path.join(root, "big")
    for writer, exe, seed in (("redis", a.redis, 3), ("bendkv", a.bin, 4)):
        w = Srv(exe, os.path.join(d, writer), "--save", "")
        c = w.conn()
        fill_big(c, seed)
        same("SAVE (%s, a big file)" % writer, run(c, "SAVE"), (b"+", b"OK"))
        live = unenc(dump_all(c, 3))
        shut(c, "SHUTDOWN", "NOSAVE")
        w.exit()
        f = os.path.join(d, writer, "dump.rdb")
        check("%s's big file is past 16 MB" % writer, os.path.getsize(f) > 16 << 20, os.path.getsize(f))
        if writer == "bendkv" and shutil.which("redis-check-rdb"):
            out = subprocess.run(["redis-check-rdb", f], capture_output=True, text=True).stdout
            check("redis-check-rdb finds BendKV's big file whole", "RDB looks OK!" in out and "Checksum OK" in out, out[-800:])
        for name in ("from-%s-b" % writer, "from-%s-r" % writer):
            os.makedirs(os.path.join(d, name))
            shutil.copy(f, os.path.join(d, name, "dump.rdb"))
        b = Srv(a.bin, os.path.join(d, "from-%s-b" % writer), "--save", "")
        r = Srv(a.redis, os.path.join(d, "from-%s-r" % writer), "--save", "")
        try:
            if b.code is not None or r.code is not None:
                fail("both start from %s's big file: BendKV %s, Redis %s" % (writer, b.code, r.code),
                     b.log()[-1500:], r.log()[-1500:])
                continue
            cb, cr = b.conn(), r.conn()
            xb, xr = dump_all(cb, 3), dump_all(cr, 3)
            same_dbs("BendKV and Redis from %s's big file" % writer, xb, xr)
            same_dbs("BendKV from %s's big file holds what was saved" % writer, unenc(xb), live)
            same("the keys loaded and expired from %s's big file" % writer, loads(cb), loads(cr))
        finally:
            b.kill()
            r.kill()


def windows(a, root):
    """a file read in windows of 1 MiB: values longer than a window, and
    cuts and a wrong checksum past the first window, alike on both; and
    BendKV's resident memory after a start from a file of 300,000 keys,
    at most 1.3 times that of the same keys written by commands"""
    d = os.path.join(root, "windows")
    rnd = random.Random(11)
    w = Srv(a.redis, os.path.join(d, "src"), "--save", "")
    c = w.conn()
    run(c, "SET", "a:first", "a key before the long values")
    run(c, "SET", "s:long", rnd.randbytes(3 << 20))
    for i in range(0, 60000, 1000):
        run(c, "RPUSH", "l:long", *[rnd.randbytes(40) for _ in range(1000)])
    for i in range(0, 120000, 2000):
        run(c, "SADD", "set:long", *["member:%d" % j for j in range(i, i + 2000)])
    for i in range(0, 30000, 1000):
        run(c, "HSET", "h:long", *[x for j in range(i, i + 1000) for x in ("f%d" % j, rnd.randbytes(30))])
    for i in range(0, 20000, 1000):
        c.send([cmd("SET", "k:%d" % j, rnd.randbytes(rnd.randrange(1, 200))) for j in range(i, i + 1000)])
        for _ in range(1000):
            c.reply()
    same("SAVE (the long values)", run(c, "SAVE"), (b"+", b"OK"))
    live = unenc(dump_all(c, 1))
    shut(c, "SHUTDOWN", "NOSAVE")
    w.exit()
    good = read(os.path.join(d, "src", "dump.rdb"))
    check("the file of the long values runs past six windows", len(good) > 6 << 20, len(good))
    got = []
    for who, exe in (("bendkv", a.bin), ("redis", a.redis)):
        dd = os.path.join(d, "whole", who)
        os.makedirs(dd)
        with open(os.path.join(dd, "dump.rdb"), "wb") as f:
            f.write(good)
        s = Srv(exe, dd, "--save", "")
        got.append(s.code is None and dump_all(s.conn(), 1))
        s.kill()
    if got[0] is False or got[1] is False:
        fail("both start from the file of the long values", got[0] is not False, got[1] is not False)
    else:
        same_dbs("BendKV and Redis from the file of the long values", got[0], got[1])
        same_dbs("BendKV from it holds what was saved", unenc(got[0]), live)
    at = good.index(b"s:long") + 1000000
    short = ["Short read or OOM loading DB. Unrecoverable error, aborting now."]
    for name, data, lines in (
            ("cut a byte past the first window, in a long value", good[:(1 << 20) + 1], short),
            ("cut half way", good[:len(good) // 2], short),
            ("cut in its checksum", good[:-4], short),
            ("a byte of a long value changed", good[:at] + bytes([good[at] ^ 0x5a]) + good[at + 1:],
             ["Wrong RDB checksum expected: (", ") but got (", "). Aborting now."])):
        res = []
        for who, exe in (("bendkv", a.bin), ("redis", a.redis)):
            dd = os.path.join(d, name.replace(" ", "-").replace(",", ""), who)
            os.makedirs(dd)
            with open(os.path.join(dd, "dump.rdb"), "wb") as f:
                f.write(data)
            s = Srv(exe, dd, "--save", "")
            code = s.code if s.code is not None else "running"
            log = s.log()
            s.kill()
            res.append((code, [l for l in lines if l in log], re.findall(r"Wrong RDB checksum expected: \(\w+\) but got \(\w+\)", log)))
        same("a file %s: exit and log" % name, res[0], res[1])
        check("a file %s: exit 1" % name, res[1][0] == 1, res[1])
    # resident memory: the same keys written by commands, then loaded
    dm = os.path.join(d, "memory")
    m = Srv(a.bin, dm, "--save", "")
    c = m.conn()
    for i in range(0, 300000, 1000):
        c.send([cmd("SET", "key:%d" % j, b"%0100d" % j) for j in range(i, i + 1000)])
        for _ in range(1000):
            c.reply()
    written = int(info(c, "memory", "used_memory_rss"))
    same("SAVE (300,000 keys)", run(c, "SAVE"), (b"+", b"OK"))
    shut(c, "SHUTDOWN", "NOSAVE")
    m.exit()
    m = Srv(a.bin, dm, "--save", "")
    c = m.conn()
    started = int(info(c, "memory", "used_memory_rss"))
    keys = run(c, "DBSIZE")
    m.kill()
    same("the 300,000 keys loaded", keys, (b":", b"300000"))
    check("BendKV's resident memory after the start from the file: %.1f MB, against %.1f MB written" % (started / 2 ** 20, written / 2 ** 20),
          started <= written * 1.3, (started, written))


def temps(d):
    return sorted(f for f in os.listdir(d) if f.startswith("temp-"))


def scenario(c, log, d, pid):
    """SAVE and its kin, as each server answers them"""
    def fields():
        return [info(c, "persistence", x) for x in ("rdb_saves", "rdb_last_bgsave_status", "rdb_bgsave_in_progress",
                                                    "rdb_last_bgsave_time_sec", "rdb_current_bgsave_time_sec",
                                                    "rdb_last_cow_size", "rdb_changes_since_last_save")]
    dump = os.path.join(d, "dump.rdb")
    t0 = int(run(c, "LASTSAVE")[1])
    log("1 lastsave", t0 == int(info(c, "persistence", "rdb_last_save_time")), abs(t0 - time.time()) < 60, fields())
    log("1 no file", os.path.exists(dump))
    run(c, "SET", "a", "1")
    log("2 save", run(c, "SAVE"), os.path.exists(dump), file_keys(read(dump)), fields(), temps(d))
    t1 = int(run(c, "LASTSAVE")[1])
    log("2 lastsave", t1 >= t0, t1 == int(info(c, "persistence", "rdb_last_save_time")))
    log("2 arity", run(c, "SAVE", "x"), run(c, "save"))
    log("2 multi", run(c, "MULTI"), run(c, "SAVE"), run(c, "SET", "b", "2"), run(c, "EXEC"), run(c, "EXISTS", "b"))
    log("2 info", run(c, "COMMAND", "INFO", "save"), run(c, "COMMAND", "DOCS", "save"))
    # a pipeline: SAVE saves what came before it, not what came after
    c.send([cmd("SET", "p1", "1"), cmd("SAVE"), cmd("SET", "p2", "2"), cmd("DBSIZE")])
    log("3 pipeline", [c.reply() for _ in range(4)], sorted(file_keys(read(dump))))
    # a SAVE that fails: a directory where its temporary file goes
    tmp = os.path.join(d, "temp-%s.rdb" % pid)
    os.mkdir(tmp)
    log("4 failed", run(c, "SAVE"), fields(), run(c, "PING"))
    os.rmdir(tmp)
    log("4 then", run(c, "SAVE"), fields())
    stats = info(c, "commandstats", "cmdstat_save")
    log("4 stats", re.sub(r"usec=\d+,usec_per_call=[0-9.]+,", "", stats or ""), info(c, "errorstats", "errorstat_ERR"))
    run(c, "CONFIG", "RESETSTAT")
    log("5 resetstat", fields())
    # FLUSHALL: no file without save points, an empty one with them,
    # whatever follows it
    os.remove(dump)
    log("6 flushall", run(c, "FLUSHALL"), os.path.exists(dump))
    log("6 save points", run(c, "CONFIG", "SET", "save", "3600 1 300 100"))
    run(c, "SET", "f", "1")
    c.send([cmd("FLUSHALL"), cmd("SET", "after", "1")])
    log("6 flushall", [c.reply() for _ in range(2)], os.path.exists(dump) and file_keys(read(dump)), fields())
    run(c, "CONFIG", "SET", "save", "")
    run(c, "FLUSHALL")
    # the checksum (rdbchecksum and dbfilename are set at the start only)
    run(c, "SET", "x", "1")
    log("7 checksum", run(c, "CONFIG", "SET", "rdbchecksum", "no"), run(c, "CONFIG", "SET", "dbfilename", "x.rdb"),
        run(c, "SAVE"), read(dump)[-8:] == struct.pack("<Q", crc64(read(dump)[:-8])), file_keys(read(dump)), temps(d))


def scenarios(a, root):
    """SAVE, LASTSAVE, INFO's fields and FLUSHALL's save, on both"""
    outs = []
    for name, exe in (("bendkv", a.bin), ("redis", a.redis)):
        d = os.path.join(root, "sc", name)
        s = Srv(exe, d, "--save", "")
        lines = []
        try:
            scenario(s.conn(), lambda *x: lines.append(" ".join(repr(v) for v in x)), d, s.pid())
            log = s.log()
            lines.append(repr(["Failed opening the temp RDB file temp-%s.rdb (in server root dir %s) for saving: Is a directory"
                               % (s.pid(), d) in log, "DB saved on disk" in log]))
        except Exception as e:
            fail("the scenario on %s: %r" % (name, e), traceback.format_exc()[-800:])
            lines.append("EXCEPTION %r" % (e,))
        finally:
            s.kill()
        outs.append(lines)
    for i in range(max(len(outs[0]), len(outs[1]))):
        x = outs[0][i] if i < len(outs[0]) else "<none>"
        y = outs[1][i] if i < len(outs[1]) else "<none>"
        same("scenario line %d" % i, x, y)


def unchecked(a, root):
    """dbfilename x.rdb and rdbchecksum no: SAVE writes x.rdb, 8 zero bytes
    where its checksum goes, on both; both start from either file"""
    got = []
    for name, exe in (("bendkv", a.bin), ("redis", a.redis)):
        d = os.path.join(root, "unchecked", name)
        s = Srv(exe, d, "--save", "", "--rdbchecksum", "no", "--dbfilename", "x.rdb")
        c = s.conn()
        run(c, "SET", "a", "1")
        got.append((run(c, "SAVE"), read(os.path.join(d, "x.rdb"))[-9:], file_keys(read(os.path.join(d, "x.rdb"))),
                    sorted(f for f in os.listdir(d) if f != "out.log")))
        s.kill()
    same("SAVE with dbfilename x.rdb and rdbchecksum no", got[0], got[1])
    for src in ("bendkv", "redis"):
        loaded = []
        for name, exe in (("bendkv", a.bin), ("redis", a.redis)):
            d = os.path.join(root, "unchecked", "%s-from-%s" % (name, src))
            os.makedirs(d)
            shutil.copy(os.path.join(root, "unchecked", src, "x.rdb"), os.path.join(d, "x.rdb"))
            s = Srv(exe, d, "--save", "", "--dbfilename", "x.rdb")
            loaded.append((s.code, s.code is None and dump_all(s.conn(), 1),
                           s.has("RDB file was saved with checksum disabled: no check performed.")))
            s.kill()
        same("both start from %s's x.rdb of no checksum" % src, loaded[0], loaded[1])
        check("%s's x.rdb loads" % src, loaded[1][0] is None and loaded[1][2], loaded[1])


def pause(s, ms=400):
    """CLIENT PAUSE ALL for ms, from a connection of its own: the requests
    that come meanwhile are held back, and at the first tick past its end
    their clients go on in the order they came. BendKV runs them at the
    end of one group of requests, so that what they do meets there; Redis
    runs them one client after another, in that order too"""
    c = s.conn()
    run(c, "CLIENT", "PAUSE", ms, "ALL")
    return c


def shutdowns_on(exe, root, log):
    """the transcript of SHUTDOWN's cases on one server. A SHUTDOWN that
    stops the server sends no reply of its group (the commands before it
    in the pipeline run, their replies are not sent: admin_test.py), so
    each read goes in a pipeline of its own"""
    def fresh(name, *args):
        return Srv(exe, os.path.join(root, name), *args)

    def dump(name):
        p = os.path.join(root, name, "dump.rdb")
        return os.path.exists(p) and sorted(file_keys(read(p)))
    # without save points, SHUTDOWN saves nothing; SAVE saves
    s = fresh("plain", "--save", "")
    log("1 plain", talk(s.port, [["SET", "a", "1"], ["SHUTDOWN"]]), s.exit(), dump("plain"))
    s = fresh("save", "--save", "")
    log("2 save", talk(s.port, [["SET", "a", "1"], ["SET", "l", "xy"], ["SHUTDOWN", "SAVE"], ["SET", "z", "1"]]),
        s.exit(), dump("save"))
    s = fresh("save", "--save", "")
    log("2 restart", talk(s.port, [["GET", "a"], ["GET", "l"], ["EXISTS", "z"], ["DBSIZE"]]),
        loads(s.conn()), talk(s.port, [["SHUTDOWN", "NOSAVE", "NOW"]]), s.exit())
    # with save points, SHUTDOWN saves, NOSAVE does not
    s = fresh("points", "--save", "3600 1")
    log("3 points", talk(s.port, [["SET", "a", "1"], ["SET", "t", "2", "EX", "1000"], ["SHUTDOWN"]]), s.exit(), dump("points"))
    s = fresh("points", "--save", "3600 1")
    out, state = talk(s.port, [["GET", "a"], ["TTL", "t"], ["SET", "b", "2"]])
    log("3 restart", out[0], out[1][0] == b":" and 990 <= int(out[1][1]) <= 1000, out[2:], state,
        talk(s.port, [["SHUTDOWN", "NOSAVE"]]), s.exit())
    s = fresh("points", "--save", "3600 1")
    log("3 nosave kept nothing", talk(s.port, [["EXISTS", "a", "b"]]), talk(s.port, [["SHUTDOWN", "FORCE", "NOW"]]), s.exit())
    # a save that fails: the server goes on, SHUTDOWN answered Redis's
    # error and the batch going on; FORCE stops it all the same
    s = fresh("fails", "--save", "3600 1")
    os.mkdir(os.path.join(root, "fails", "temp-%s.rdb" % s.pid()))
    log("4 fails", talk(s.port, [["SET", "a", "1"], ["SHUTDOWN"], ["GET", "a"]]), s.p.poll())
    log("4 save fails", talk(s.port, [["SHUTDOWN", "SAVE"], ["PING"]]), s.p.poll())
    # another client's requests that come right after such a SHUTDOWN are
    # served as if it had not come: a pause holds both back, so that
    # BendKV runs them in one group
    for r in range(3):
        cc = pause(s)
        ca, cb = s.conn(), s.conn()
        ca.send([cmd("SHUTDOWN")])
        time.sleep(0.05)
        cb.send([cmd("SET", "k%d" % i, i) for i in range(50)] + [cmd("DBSIZE")])
        try:
            rb = [cb.reply() for _ in range(51)]
            got = (rb[-1], all(x == (b"+", b"OK") for x in rb[:-1]))
        except (EOFError, ConnectionResetError) as e:
            got = "closed"
        log("4 others go on", r, ca.reply(), got, s.p.poll())
        for c in (ca, cb, cc):
            c.sock.close()
    log("4 stats", re.sub(r"usec=\d+,usec_per_call=[0-9.]+,", "", info(s.conn(), "commandstats", "cmdstat_shutdown") or ""))
    log("4 force", talk(s.port, [["SHUTDOWN", "FORCE"]]), s.exit(), dump("fails"))
    lg = s.log()
    log("4 log", [x in lg for x in ("Saving the final RDB snapshot before exiting.", "Failed opening the temp RDB file",
                                     "Error trying to save the DB, can't exit.",
                                     "Errors trying to shut down the server. Check the logs for more information.",
                                     "Error trying to save the DB. Exit anyway.")])
    # with the append-only file, both are written; a start with it
    # loads it, not the RDB file
    s = fresh("aof", "--save", "", "--appendonly", "yes")
    log("5 aof", talk(s.port, [["SET", "a", "1"], ["SHUTDOWN", "SAVE"]]), s.exit(), dump("aof"))
    s = fresh("aof", "--save", "", "--appendonly", "yes")
    log("5 restart", talk(s.port, [["GET", "a"], ["SET", "b", "1"]]), talk(s.port, [["SHUTDOWN", "NOSAVE"]]), s.exit())
    s = fresh("aof", "--save", "", "--appendonly", "no")
    log("5 the RDB file", talk(s.port, [["GET", "a"], ["EXISTS", "b"]]), talk(s.port, [["SHUTDOWN", "NOSAVE"]]), s.exit())
    shutil.copy(os.path.join(root, "points", "dump.rdb"), os.path.join(root, "aof", "dump.rdb"))
    s = fresh("aof", "--save", "", "--appendonly", "yes")
    log("5 the RDB file left out", talk(s.port, [["GET", "a"], ["EXISTS", "t", "b"]]), talk(s.port, [["SHUTDOWN", "NOSAVE"]]),
        s.exit())
    # SAVE with the append-only file: what comes after it, in its pipeline
    # and in another client's requests of its group, reaches the
    # append-only file after the save. A pause holds both back, so that
    # BendKV runs them in one group (where the other client's APPEND runs
    # between SAVE and the APPEND after it, and Redis runs it after both);
    # the two APPENDs to s, in whichever order they ran, must come back
    # from the file in that order
    s = fresh("aofsave", "--save", "", "--appendonly", "yes")
    hold = pause(s)
    ca, cb = s.conn(), s.conn()
    ca.send([cmd("SET", "a", "1"), cmd("SAVE"), cmd("SET", "b", "2"), cmd("APPEND", "s", "x")])
    time.sleep(0.05)
    cb.send([cmd("SET", "c", "3"), cmd("APPEND", "s", "y")])
    ra, rb = [ca.reply() for _ in range(4)], [cb.reply() for _ in range(2)]
    before = run(s.conn(), "MGET", "a", "b", "c", "s")
    log("5 save", ra[:3], rb[0], sorted([ra[3], rb[1]]), os.path.exists(os.path.join(root, "aofsave", "dump.rdb")))
    for c in (hold, ca, cb):
        c.sock.close()
    log("5 save stop", talk(s.port, [["SHUTDOWN", "NOSAVE"]]), s.exit())
    s = fresh("aofsave", "--save", "", "--appendonly", "yes")
    after = run(s.conn(), "MGET", "a", "b", "c", "s")
    log("5 save restart", after == before, after[1][:3], talk(s.port, [["SHUTDOWN", "NOSAVE"]]), s.exit())
    # a SHUTDOWN that saves and another client's FLUSHALL in one group (a
    # pause holds both back): Redis saves and exits within SHUTDOWN, so the
    # FLUSHALL never runs, and both files keep the key; with save points,
    # with the append-only file too, and with SHUTDOWN SAVE
    for name, args, down in (("hold", ("--save", "3600 1"), ["SHUTDOWN"]),
                             ("hold-aof", ("--save", "3600 1", "--appendonly", "yes"), ["SHUTDOWN"]),
                             ("hold-save", ("--save", ""), ["SHUTDOWN", "SAVE"])):
        s = fresh(name, *args)
        run(s.conn(), "SET", "k", "v")
        ca, cb = s.conn(), s.conn()
        hold = pause(s)
        ca.send([cmd(*down)])
        time.sleep(0.05)
        cb.send([cmd("FLUSHALL")])
        try:
            rb = cb.reply()
        except (EOFError, ConnectionResetError):
            rb = "closed"
        log("7 %s" % name, rb, s.exit())
        s = fresh(name, *args)
        log("7 %s restart" % name, talk(s.port, [["DBSIZE"]]), talk(s.port, [["SHUTDOWN", "NOSAVE"]]), s.exit())
    # the same with a save that fails: SHUTDOWN answers its error, then the
    # FLUSHALL runs and is answered
    s = fresh("hold-fails", "--save", "3600 1")
    os.mkdir(os.path.join(root, "hold-fails", "temp-%s.rdb" % s.pid()))
    run(s.conn(), "SET", "k", "v")
    ca, cb = s.conn(), s.conn()
    hold = pause(s)
    ca.send([cmd("SHUTDOWN")])
    time.sleep(0.05)
    cb.send([cmd("FLUSHALL")])
    log("7 hold-fails", ca.reply(), cb.reply(), talk(s.port, [["DBSIZE"]]), s.p.poll())
    for c in (hold, ca, cb):
        c.sock.close()
    log("7 hold-fails stop", talk(s.port, [["SHUTDOWN", "NOSAVE"]]), s.exit())


def shutdowns(a, root):
    """SHUTDOWN and its saves, on both"""
    outs = []
    for name, exe in (("bendkv", a.bin), ("redis", a.redis)):
        lines = []
        try:
            shutdowns_on(exe, os.path.join(root, "sd", name), lambda *x: lines.append(" ".join(repr(v) for v in x)))
        except Exception as e:
            fail("the shutdowns on %s: %r" % (name, e), traceback.format_exc()[-800:])
            lines.append("EXCEPTION %r" % (e,))
        outs.append(lines)
    for i in range(max(len(outs[0]), len(outs[1]))):
        x = outs[0][i] if i < len(outs[0]) else "<none>"
        y = outs[1][i] if i < len(outs[1]) else "<none>"
        same("shutdown line %d" % i, x, y)


def races_on(exe, root, log):
    """the transcript of another client's CLIENT UNBLOCK or CLIENT KILL of
    a client whose SAVE (or failing SHUTDOWN SAVE) has run, in the same
    group of requests: a pause holds both back, so that BendKV runs them
    in one group (pause). Redis saves within the command: its client is
    never blocked, UNBLOCK answers 0, and the save is made before a KILL
    can reach it"""
    for action in ("unblock", "kill"):
        name = "race-" + action
        s = Srv(exe, os.path.join(root, name), "--save", "")
        a, b = s.conn(), s.conn()
        ida = run(a, "CLIENT", "ID")[1]
        c = pause(s)
        a.send([cmd("SET", "newkey", 1), cmd("SAVE")])
        time.sleep(0.05)
        b.send([cmd("CLIENT", "UNBLOCK", ida) if action == "unblock" else cmd("CLIENT", "KILL", "ID", ida)])
        got = []
        for _ in range(2):
            try:
                got.append(a.reply())
            except (EOFError, ConnectionResetError):
                got.append("closed")
        log("6 %s" % action, got, b.reply(), talk(s.port, [["SHUTDOWN", "NOSAVE"]]), s.exit())
        c.sock.close()
        s = Srv(exe, os.path.join(root, name), "--save", "")
        log("6 %s restart" % action, talk(s.port, [["GET", "newkey"]]), talk(s.port, [["SHUTDOWN", "NOSAVE"]]), s.exit())
    # a SHUTDOWN SAVE whose save fails, its client unblocked by another
    s = Srv(exe, os.path.join(root, "race-shut"), "--save", "")
    os.mkdir(os.path.join(root, "race-shut", "temp-%s.rdb" % s.pid()))
    a, b = s.conn(), s.conn()
    ida = run(a, "CLIENT", "ID")[1]
    c = pause(s)
    a.send([cmd("SHUTDOWN", "SAVE")])
    time.sleep(0.05)
    b.send([cmd("CLIENT", "UNBLOCK", ida)])
    log("6 shutdown unblock", a.reply(), b.reply(), s.p.poll(), talk(s.port, [["SHUTDOWN", "NOSAVE"]]), s.exit())


def races(a, root):
    """CLIENT UNBLOCK and CLIENT KILL of a client whose SAVE ran, on both"""
    outs = []
    for name, exe in (("bendkv", a.bin), ("redis", a.redis)):
        lines = []
        try:
            races_on(exe, os.path.join(root, "race", name), lambda *x: lines.append(" ".join(repr(v) for v in x)))
        except Exception as e:
            fail("the races on %s: %r" % (name, e), traceback.format_exc()[-800:])
            lines.append("EXCEPTION %r" % (e,))
        outs.append(lines)
    for i in range(max(len(outs[0]), len(outs[1]))):
        x = outs[0][i] if i < len(outs[0]) else "<none>"
        y = outs[1][i] if i < len(outs[1]) else "<none>"
        same("race line %d" % i, x, y)


# the lines of a shutdown, in order, as both servers log them: the
# signal's line from its handler ("<pid>:signal-handler (<secs>) <msg>"),
# then the others without their pid, time and level
SHUT_LINES = (("signal", re.compile(r"^\d+:signal-handler \(\d+\) (Received SIG(TERM|INT) scheduling shutdown\.\.\.|You insist\.\.\. exiting now\.)$")),
              ("user", re.compile(r"User requested shutdown\.\.\.$")),
              ("fsync", re.compile(r"Calling fsync\(\) on the AOF file\.$")),
              ("saving", re.compile(r"Saving the final RDB snapshot before exiting\.$")),
              ("saved", re.compile(r"DB saved on disk$")),
              ("open failed", re.compile(r"Failed opening the temp RDB file temp-\d+\.rdb \(in server root dir .*\) for saving: Is a directory$")),
              ("cant", re.compile(r"Error trying to save the DB, can't exit\.$")),
              ("anyway", re.compile(r"Error trying to save the DB\. Exit anyway\.$")),
              ("errors", re.compile(r"Errors trying to shut down the server\. Check the logs for more information\.$")),
              ("bye", re.compile(r"(Redis|BendKV) is now ready to exit, bye bye\.\.\.$")))


def shut_lines(text):
    out = []
    for l in text.splitlines():
        for name, pat in SHUT_LINES:
            m = pat.search(l)
            if m:
                out.append(m.group(1) if name == "signal" else name)
    return out


def signals_on(exe, root, log):
    """the transcript of the signals' cases on one server: what it logs
    (shut_lines), how it ends, what the RDB file holds, and a restart"""
    def fresh(name, *args):
        return Srv(exe, os.path.join(root, name), *args)

    def dump(name):
        p = os.path.join(root, name, "dump.rdb")
        return os.path.exists(p) and sorted(file_keys(read(p)))

    def wait_down(s, sig):
        s.p.send_signal(sig)
        return s.exit()
    # SIGTERM with save points: the shutdown of SHUTDOWN, its save made;
    # a restart holds it
    s = fresh("term", "--save", "3600 1")
    log("1 term", talk(s.port, [["SET", "a", "1"], ["SET", "t", "2", "EX", "1000"]]), wait_down(s, signal.SIGTERM),
        dump("term"), shut_lines(s.log()))
    s = fresh("term", "--save", "3600 1")
    log("1 restart", talk(s.port, [["GET", "a"], ["EXISTS", "t"]]), talk(s.port, [["SHUTDOWN", "NOSAVE"]]), s.exit())
    # SIGINT without save points: no save
    s = fresh("int", "--save", "")
    log("2 int", talk(s.port, [["SET", "a", "1"]]), wait_down(s, signal.SIGINT), dump("int"), shut_lines(s.log()))
    # shutdown-on-sigterm: nosave with save points, save without them,
    # force through a save that fails
    s = fresh("nosave", "--save", "3600 1", "--shutdown-on-sigterm", "nosave")
    log("3 nosave", talk(s.port, [["SET", "a", "1"]]), wait_down(s, signal.SIGTERM), dump("nosave"), shut_lines(s.log()))
    s = fresh("save", "--save", "", "--shutdown-on-sigint", "save")
    log("3 save", talk(s.port, [["SET", "a", "1"]]), wait_down(s, signal.SIGINT), dump("save"), shut_lines(s.log()))
    s = fresh("force", "--save", "3600 1", "--shutdown-on-sigterm", "force now")
    os.mkdir(os.path.join(root, "force", "temp-%s.rdb" % s.pid()))
    log("3 force", talk(s.port, [["SET", "a", "1"]]), wait_down(s, signal.SIGTERM), dump("force"), shut_lines(s.log()))
    # a save that fails: the server goes on, and a later signal, once the
    # save can be made, stops it
    s = fresh("fails", "--save", "3600 1")
    tmp = os.path.join(root, "fails", "temp-%s.rdb" % s.pid())
    os.mkdir(tmp)
    talk(s.port, [["SET", "a", "1"]])
    s.p.send_signal(signal.SIGTERM)
    time.sleep(1)
    log("4 fails", s.p.poll(), talk(s.port, [["PING"], ["GET", "a"]]), shut_lines(s.log()))
    s.p.send_signal(signal.SIGINT)
    time.sleep(1)
    log("4 fails again", s.p.poll(), talk(s.port, [["PING"]]), shut_lines(s.log()))
    os.rmdir(tmp)
    log("4 stops", wait_down(s, signal.SIGTERM), dump("fails"), shut_lines(s.log()))
    # with the append-only file: synced, and read at the restart
    s = fresh("aof", "--save", "", "--appendonly", "yes")
    log("5 aof", talk(s.port, [["SET", "a", "1"]]), wait_down(s, signal.SIGTERM), dump("aof"), shut_lines(s.log()))
    s = fresh("aof", "--save", "", "--appendonly", "yes")
    log("5 restart", talk(s.port, [["GET", "a"]]), talk(s.port, [["SHUTDOWN", "NOSAVE"]]), s.exit())


def signals(a, root):
    """SIGTERM and SIGINT: the shutdown Redis runs for them, on both"""
    outs = []
    for name, exe in (("bendkv", a.bin), ("redis", a.redis)):
        lines = []
        try:
            signals_on(exe, os.path.join(root, "sig", name), lambda *x: lines.append(" ".join(repr(v) for v in x)))
        except Exception as e:
            fail("the signals on %s: %r" % (name, e), traceback.format_exc()[-800:])
            lines.append("EXCEPTION %r" % (e,))
        outs.append(lines)
    for i in range(max(len(outs[0]), len(outs[1]))):
        x = outs[0][i] if i < len(outs[0]) else "<none>"
        y = outs[1][i] if i < len(outs[1]) else "<none>"
        same("signal line %d" % i, x, y)


def corrupt(a, root):
    """files that do not load, one that loads on Redis alone, and one of a
    stream, which loads on both"""
    d = os.path.join(root, "bad", "src")
    r = Srv(a.redis, d, "--save", "")
    c = r.conn()
    run(c, "SET", "a", "1")
    run(c, "RPUSH", "l", *["e%d" % i for i in range(100)])
    run(c, "SAVE")
    good = read(os.path.join(d, "dump.rdb"))
    run(c, "XADD", "st", "1-1", "f", "v")
    run(c, "SAVE")
    stream = read(os.path.join(d, "dump.rdb"))
    shut(c, "SHUTDOWN", "NOSAVE")
    r.exit()
    sel = good.index(b"\xfe")
    cases = [
        ("cut short", good[:-12], 1, ["Short read or OOM loading DB. Unrecoverable error, aborting now."]),
        ("cut in its magic", good[:7], 1, ["Short read or OOM loading DB. Unrecoverable error, aborting now."]),
        ("empty", b"", 1, ["Short read or OOM loading DB. Unrecoverable error, aborting now."]),
        ("a wrong checksum", good[:-1] + bytes([good[-1] ^ 0x10]), 1, ["Wrong RDB checksum expected: (", ") but got (", "). Aborting now."]),
        ("version 11", b"REDIS0011" + good[9:], 1, ["Can't handle RDB format version 11", "Fatal error loading the DB: Invalid argument. Exiting."]),
        ("version 0", b"REDIS0000" + good[9:], 1, ["Can't handle RDB format version 0"]),
        ("version -1", b"REDIS-001" + good[9:], 1, ["Can't handle RDB format version -1"]),
        ("a wrong signature", b"RODIS" + good[5:], 1, ["Wrong signature trying to load DB from file", "Fatal error loading the DB: Invalid argument. Exiting."]),
        ("database 16", good[:sel + 1] + b"\x10" + good[sel + 2:], 1, ["FATAL: Data file was created with a Redis server configured to handle more than 16 databases. Exiting"]),
        ("a type that is none", good[:sel + 5] + b"\x16" + good[sel + 6:], 1, ["Unknown RDB encoding type 22"]),
        ("a checksum of 0", good[:-8] + bytes(8), "running", ["RDB file was saved with checksum disabled: no check performed."]),
    ]
    for name, data, code, lines in cases:
        got = []
        for who, exe in (("bendkv", a.bin), ("redis", a.redis)):
            dd = os.path.join(root, "bad", name.replace(" ", "-"), who)
            os.makedirs(dd)
            with open(os.path.join(dd, "dump.rdb"), "wb") as f:
                f.write(data)
            s = Srv(exe, dd, "--save", "")
            res = s.code if s.code is not None else "running"
            log = s.log()
            s.kill()
            got.append((res, [l for l in lines if l in log], re.findall(r"Wrong RDB checksum expected: \(\w+\) but got \(\w+\)", log)))
        same("a file %s: exit and log" % name, got[0], got[1])
        check("a file %s: exit %s" % (name, code), got[1][0] == code, got[1])
    # a checksum that is wrong, with rdbchecksum no: both load it
    got = []
    for who, exe in (("bendkv", a.bin), ("redis", a.redis)):
        dd = os.path.join(root, "bad", "unchecked", who)
        os.makedirs(dd)
        with open(os.path.join(dd, "dump.rdb"), "wb") as f:
            f.write(good[:-1] + bytes([good[-1] ^ 0x10]))
        s = Srv(exe, dd, "--save", "", "--rdbchecksum", "no")
        got.append(s.code is None and dump_all(s.conn()))
        s.kill()
    same("a wrong checksum with rdbchecksum no loads", got[0], got[1])
    # a directory where the file is: both stop
    got = []
    for who, exe in (("bendkv", a.bin), ("redis", a.redis)):
        dd = os.path.join(root, "bad", "directory", who)
        os.makedirs(os.path.join(dd, "dump.rdb"))
        s = Srv(exe, dd, "--save", "")
        got.append(s.code)
        s.kill()
    same("a directory where the file is", got[0], got[1])
    # a module's data (MODULE_AUX) and a module's value (of types 6 and
    # 7): neither server has the module, both stop, saying why. Redis
    # then checks the file (redis-check-rdb), and exits 0 when the check
    # finds it whole: so it does for a value of type 7, which the check
    # can skip; BendKV exits 1
    mid = b"\x81" + struct.pack(">Q", 0x0123456789abcdef)
    for name, data, rline, bline, codes in (
            ("a module's data", file([b"\xf7" + mid + b"\x02\x02", select(0), key(b"a", b"\x00" + rstr(b"1"))]),
             "The RDB file contains AUX module data I can't load: no matching module",
             "BendKV has no modules: the RDB file holds a module's data (MODULE_AUX), which it cannot load", (1, 1)),
            ("a module's value of type 6", file([select(0), key(b"m", b"\x06" + mid + b"\x00")]),
             "The RDB file contains module data I can't load: no matching module type",
             "BendKV has no modules: the RDB file holds a module's value (key 'm'), which it cannot load", (1, 1)),
            ("a module's value of type 7", file([select(0), key(b"m", b"\x07" + mid + b"\x00")]),
             "The RDB file contains module data I can't load: no matching module type",
             "BendKV has no modules: the RDB file holds a module's value (key 'm'), which it cannot load", (1, 0))):
        got = []
        for who, exe, line in (("bendkv", a.bin, bline), ("redis", a.redis, rline)):
            dd = os.path.join(root, "bad", name.replace(" ", "-").replace("'", ""), who)
            os.makedirs(dd)
            with open(os.path.join(dd, "dump.rdb"), "wb") as f:
                f.write(data)
            s = Srv(exe, dd, "--save", "")
            got.append((s.code, s.has(line)))
            s.kill()
        same("%s: both stop, saying why" % name, got, [(codes[0], True), (codes[1], True)])
    # a stream: both load it, and hold the same
    xs = []
    for who, exe in (("bendkv", a.bin), ("redis", a.redis)):
        dd = os.path.join(root, "bad", "a-stream", who)
        os.makedirs(dd)
        with open(os.path.join(dd, "dump.rdb"), "wb") as f:
            f.write(stream)
        s = Srv(exe, dd, "--save", "", "--rdbcompression", "no")
        xs.append((s.code, None if s.code is not None else run(s.conn(), "DUMP", "st")))
        s.kill()
    same("a file of a stream: both load it, and DUMP the same", xs[0], xs[1])


# Libraries of functions
# ----------------------

LIB_A = ("#!lua name=liba\n"
         "redis.register_function('fa', function(keys, args) return 'a' .. #args end)\n"
         "-- " + "the same words again and again " * 8 + "\n")
LIB_B = ("#!lua name=libb\n"
         "redis.register_function{function_name='fb', callback=function(keys, args) return redis.call('get', keys[1]) end,"
         " flags={'no-writes'}, description='reads a key'}\n")
OLD_CODE = b"\nredis.register_function('fo', function() return 'o' end)\n"


def flist(c):
    """FUNCTION LIST WITHCODE, its libraries in the order of their names
    (each server walks its dictionary in an order of its own)"""
    r = run(c, "FUNCTION", "LIST", "WITHCODE")
    return sorted(r[1], key=repr) if r[0] == b"*" else r


def fn_state(c):
    """what a server holds of functions: the list, each function run, and
    INFO's counts"""
    return (flist(c), run(c, "FCALL", "fa", 0, "x"), run(c, "FCALL", "fb", 1, "k"), run(c, "FCALL", "fo", 0),
            info(c, "memory", "number_of_functions"), info(c, "memory", "number_of_libraries"), run(c, "GET", "k"))


def last_line(log, part):
    """the text of the log's last line that holds part (after Redis's
    pid, role, time and level)"""
    xs = [l for l in log.splitlines() if part in l]
    return xs[-1][xs[-1].index(part):] if xs else None


def functions(a, root):
    """libraries of functions in the file: Redis's (with LZF and without)
    and BendKV's, both ways, and one of 7.0's release candidates
    (FUNCTION): both start from each with the same libraries; files whose
    library does not load (Lua that does not compile, a library twice, a
    function twice, a library cut short): both stop, with the same lines
    and exit codes (Redis's check of the file, which it runs then, exits
    0 for a file whose library only fails to be made)"""
    d = os.path.join(root, "fn")
    cmds = [("FUNCTION", "LOAD", LIB_A), ("FUNCTION", "LOAD", LIB_B), ("SET", "k", "v")]
    files = {}
    want = None
    for comp in ("yes", "no"):
        r = Srv(a.redis, os.path.join(d, "redis-" + comp), "--save", "", "--rdbcompression", comp)
        c = r.conn()
        for x in cmds:
            run(c, *x)
        same("SAVE (Redis, with functions, rdbcompression %s)" % comp, run(c, "SAVE"), (b"+", b"OK"))
        want = flist(c)
        shut(c, "SHUTDOWN", "NOSAVE")
        r.exit()
        files["Redis's (rdbcompression %s)" % comp] = read(os.path.join(d, "redis-" + comp, "dump.rdb"))
    b = Srv(a.bin, os.path.join(d, "bendkv"), "--save", "")
    c = b.conn()
    for x in cmds:
        run(c, *x)
    same("FUNCTION LIST WITHCODE before the save", flist(c), want)
    same("SAVE (BendKV, with functions)", run(c, "SAVE"), (b"+", b"OK"))
    shut(c, "SHUTDOWN", "NOSAVE")
    b.exit()
    mine = os.path.join(d, "bendkv", "dump.rdb")
    files["BendKV's"] = read(mine)
    if shutil.which("redis-check-rdb"):
        out = subprocess.run(["redis-check-rdb", mine], capture_output=True, text=True).stdout
        check("redis-check-rdb finds BendKV's file with functions whole", "RDB looks OK!" in out and "Checksum OK" in out, out[-800:])
    files["7.0's release candidates' (FUNCTION)"] = file(
        [b"\xf6" + rstr(b"libo") + rstr(b"LUA") + rlen(1) + rstr(b"a description") + rstr(OLD_CODE),
         b"\xf5" + rstr(LIB_A.encode()), select(0), key(b"k", b"\x00" + rstr(b"v"))])
    for i, (name, data) in enumerate(sorted(files.items())):
        got = []
        for who, exe in (("bendkv", a.bin), ("redis", a.redis)):
            dd = os.path.join(d, "from-%d" % i, who)
            os.makedirs(dd)
            with open(os.path.join(dd, "dump.rdb"), "wb") as f:
                f.write(data)
            s = Srv(exe, dd, "--save", "")
            if s.code is not None:
                got.append(("exited", s.code, s.log()[-1500:]))
                continue
            got.append(fn_state(s.conn()))
            s.kill()
        same("%s file: both start from it with the same libraries" % name, got[0], got[1])
    bad_files = [
        ("Lua that does not compile", file([b"\xf5" + rstr(b"#!lua name=bad\nthis is not Lua\n")])),
        ("a library twice", file([b"\xf5" + rstr(LIB_A.encode()), b"\xf5" + rstr(LIB_A.encode())])),
        ("a function twice", file([b"\xf5" + rstr(LIB_A.encode()),
                                   b"\xf5" + rstr(b"#!lua name=other\nredis.register_function('fa', function() return 1 end)\n")])),
        ("a library cut short", file([b"\xf5" + rlen(4000) + b"#!lua name=cut\n"])),
        ("a library of FUNCTION cut short", file([b"\xf6" + rstr(b"libo") + rstr(b"LUA") + rlen(1) + rlen(5000) + b"short"])),
        ("a library with no metadata", file([b"\xf5" + rstr(b"redis.register_function('f', function() return 1 end)")])),
    ]
    for i, (name, data) in enumerate(bad_files):
        got = []
        for who, exe in (("bendkv", a.bin), ("redis", a.redis)):
            dd = os.path.join(d, "bad-%d" % i, who)
            os.makedirs(dd)
            with open(os.path.join(dd, "dump.rdb"), "wb") as f:
                f.write(data)
            s = Srv(exe, dd, "--save", "")
            got.append((s.code, last_line(s.log(), "Failed loading library"), s.has("Short read or OOM loading DB. Unrecoverable error, aborting now.")))
            s.kill()
        same("a file with %s: both stop, saying why" % name, got[0], got[1])
        check("a file with %s: the line names the library's error" % name, got[0][1] is not None, got[0])


def short_form(a, root):
    """the short form starts on no RDB file"""
    d = os.path.join(root, "short")
    os.makedirs(d)
    with open(os.path.join(d, "dump.rdb"), "wb") as f:
        f.write(file([select(0), key(b"k", b"\x00" + rstr(b"v"))]))
    port = free_port()
    p = subprocess.Popen([a.bin, str(port)], cwd=d, stdout=open(os.path.join(d, "out.log"), "w"), stderr=subprocess.STDOUT)
    try:
        for _ in range(200):
            try:
                c = Conn(port)
                break
            except OSError:
                time.sleep(0.05)
        same("the short form loads no RDB file", run(c, "DBSIZE"), (b":", b"0"))
    finally:
        p.kill()
        p.wait()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", "--bin", dest="bin", default="build/bendkv")
    ap.add_argument("--redis", default="redis-server")
    ap.add_argument("--dir", default="build/rdb")
    a = ap.parse_args()
    a.bin = os.path.abspath(a.bin)
    root = os.path.abspath(a.dir)
    shutil.rmtree(root, ignore_errors=True)
    os.makedirs(root)
    try:
        for part in (redis_writes, lzf_values, written_here, bendkv_writes, big, windows, scenarios, unchecked, shutdowns, races, signals, corrupt, functions, short_form):
            b0 = bad
            part(a, root)
            print("%s %s" % ("OK:  " if bad == b0 else "FAIL:", " ".join(part.__doc__.split())))
    finally:
        for s in SERVERS:
            s.kill()
    if bad:
        print("FAIL: %d of %d checks" % (bad, n))
        sys.exit(1)
    print("ALL OK: %d checks of the RDB file, as Redis writes and reads it" % n)


if __name__ == "__main__":
    main()
