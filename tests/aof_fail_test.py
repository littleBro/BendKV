#!/usr/bin/env python3
"""Failures of the append-only file's disk, injected by tests/fail_io.c (an
LD_PRELOAD shim). A file that is there but cannot be read stops the start
(an empty database would be served, and the next writes appended to the
file that holds the old one). A failed fsync stops the server with
everysec as it does with always. A file that is not there is still an
empty database; the start makes it and syncs the directory that holds
it before it serves (the shim's trace shows the order: the file made,
its directory synced, and only then a write synced and answered), and a
failed sync of the directory stops the start before any reply. Then the
files the start cannot replay as they were written: an unknown command,
a wrong number of arguments, an argument that does not read, a database
not there, a command of the server, a transaction left open; each stops
the start with the entry's number and the byte it starts at, the file
left byte for byte as it was (an entry cut short after one is not cut),
while a file as Redis writes it (SELECT, MULTI and EXEC, lowercase
names) restores.

    cc -shared -fPIC -o build/fail_io.so tests/fail_io.c -ldl
    python3 tests/aof_fail_test.py --port 6380 --shim build/fail_io.so
"""
import argparse
import os
import socket
import subprocess
import time


def resp(*args):
    out = b"*%d\r\n" % len(args)
    for a in args:
        out += b"$%d\r\n%s\r\n" % (len(a), a)
    return out


class Server:
    """A BendKV process on a port, with the shim's variables if any."""

    def __init__(self, a, args, env=None):
        self.a = a
        e = dict(os.environ)
        if env:
            e["LD_PRELOAD"] = os.path.abspath(a.shim)
            e.update(env)
        self.log = open(a.log, "wb")
        self.p = subprocess.Popen([a.bin, str(a.port)] + args, env=e,
                                  stdout=self.log, stderr=subprocess.STDOUT)

    def connect(self, timeout=5):
        """A connection, or None once the process has exited."""
        t = time.time() + timeout
        while time.time() < t:
            if self.p.poll() is not None:
                return None
            try:
                return socket.create_connection(("127.0.0.1", self.a.port), timeout=5)
            except OSError:
                time.sleep(0.05)
        return None

    def exited(self, timeout):
        """The exit code within timeout seconds, or None if still running."""
        try:
            return self.p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            return None

    def stop(self):
        if self.p.poll() is None:
            self.p.kill()
            self.p.wait()
        self.log.close()
        return open(self.a.log, "rb").read().decode(errors="replace").strip()


def whole(buf):
    """Whether buf holds a whole reply: a line, or a bulk string."""
    if b"\r\n" not in buf:
        return False
    head = buf[:buf.index(b"\r\n")]
    if not head.startswith(b"$") or int(head[1:]) < 0:
        return True
    return len(buf) >= len(head) + 2 + int(head[1:]) + 2


def ask(c, *cmd):
    """The reply to cmd, or the bytes so far if the server closes."""
    try:
        c.sendall(resp(*cmd))
        c.settimeout(5)
        buf = b""
        while not whole(buf):
            chunk = c.recv(1 << 16)
            if not chunk:
                return buf
            buf += chunk
        return buf
    except OSError:
        return b""


def check(name, ok, detail=""):
    print("%s %s" % ("ok  " if ok else "FAIL", name))
    if not ok and detail:
        print("     " + detail.replace("\n", "\n     "))
    return ok


def write_file(a, args, keys):
    """Starts a server on its files, SETs the keys, stops it."""
    s = Server(a, args)
    c = s.connect()
    assert c is not None, "the server did not start: " + s.stop()
    for k in keys:
        assert ask(c, b"SET", k, b"before-restart") == b"+OK\r\n"
    c.close()
    s.stop()


def refused(a, name, args, env, want):
    """The server, started with env, exits with 1 and says want."""
    s = Server(a, args, env)
    code = s.exited(10)
    log = s.stop()
    return check(name, code == 1 and want in log,
                 "exit %s, log: %s" % (code, log[-300:]))


def entry(*args):
    return resp(*args)


def unreplayable(a, path, name, data, want):
    """A file of data stops the start with want, and is left as it was."""
    with open(path, "wb") as f:
        f.write(data)
    ok = refused(a, name, ["send", path, "always"], None,
                 "Bad command reading the append only file %s: %s" % (path, want))
    with open(path, "rb") as f:
        same = f.read() == data
    return check(name + ": the file is left as it was", same) and ok


def traced(path):
    """The shim's trace: its lines, as (what, path)."""
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [tuple(l.rstrip("\n").split(" ", 1)) for l in f if " " in l]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=6380)
    ap.add_argument("--bin", default="build/bendkv")
    ap.add_argument("--shim", default="build/fail_io.so")
    ap.add_argument("--dir", default="build")
    ap.add_argument("--log", default="build/fail_server.log")
    a = ap.parse_args()
    one = os.path.join(a.dir, "fail.aof")
    if os.path.exists(one):
        os.remove(one)
    ok = True

    # a file not there: an empty database, as before
    s = Server(a, ["send", one, "always"])
    c = s.connect()
    ok &= check("a file not there is an empty database",
                c is not None and ask(c, b"DBSIZE") == b":0\r\n", s.stop() if c is None else "")
    if c is not None:
        c.close()
        s.stop()
    os.remove(one)

    # the file there but not readable
    write_file(a, ["send", one, "always"], [b"persisted"])
    size = os.path.getsize(one)
    ok &= refused(a, "an unreadable file stops the start",
                  ["send", one, "always"], {"BENDKV_FAIL_OPEN": one},
                  "Can't open the append-only file %s: Permission denied" % one)
    ok &= check("the unreadable file is left as it was", os.path.getsize(one) == size)
    s = Server(a, ["send", one, "always"])
    c = s.connect()
    got = ask(c, b"GET", b"persisted") if c is not None else b""
    ok &= check("readable again, it restores its keys",
                got == b"$14\r\nbefore-restart\r\n", "GET persisted: %r" % got)
    if c is not None:
        c.close()
    s.stop()

    # everysec: a failed fsync stops the server
    s = Server(a, ["send", one, "everysec"], {"BENDKV_FAIL_SYNC": "1"})
    c = s.connect()
    got = ask(c, b"SET", b"after", b"x") if c is not None else b""
    code = s.exited(5)
    log = s.stop()
    ok &= check("everysec: a failed fsync stops the server",
                code == 1 and "the append-only file failed: Input/output error" in log,
                "SET: %r, exit %s, log: %s" % (got, code, log[-300:]))
    if c is not None:
        c.close()

    # always: the same, at the first write (as before)
    s = Server(a, ["send", one, "always"], {"BENDKV_FAIL_SYNC": "1"})
    c = s.connect()
    got = ask(c, b"SET", b"after", b"x") if c is not None else b""
    code = s.exited(5)
    log = s.stop()
    ok &= check("always: a failed fsync stops the server before the reply",
                code == 1 and got == b"" and "Input/output error" in log,
                "SET: %r, exit %s, log: %s" % (got, code, log[-300:]))
    if c is not None:
        c.close()

    # a new file: made, its directory synced, then served (the trace of
    # the shim, in the order the calls came), and a write in always
    # synced after that; then the same start where the sync of the
    # directory fails: it stops before it answers anything
    fresh = os.path.abspath(os.path.join(a.dir, "fail_new.aof"))
    trace = os.path.abspath(os.path.join(a.dir, "fail_trace.txt"))
    for p in [fresh, trace]:
        if os.path.exists(p):
            os.remove(p)
    s = Server(a, ["send", fresh, "always"], {"BENDKV_TRACE": trace})
    c = s.connect()
    pong = ask(c, b"PING") if c is not None else b""
    at_pong = traced(trace)
    got = ask(c, b"SET", b"k", b"v") if c is not None else b""
    after = traced(trace)
    if c is not None:
        c.close()
    log = s.stop()
    made = ("create", fresh)
    dsync = ("fsync", os.path.dirname(fresh))
    fsync = ("fdatasync", fresh)
    ok &= check("a new file is made and its directory synced before the server answers",
                pong == b"+PONG\r\n" and made in at_pong and dsync in at_pong
                and at_pong.index(made) < at_pong.index(dsync),
                "PING: %r, trace: %s, log: %s" % (pong, at_pong, log[-300:]))
    ok &= check("the first write's sync comes after the directory's",
                got == b"+OK\r\n" and fsync in after and after.index(dsync) < after.index(fsync)
                and fsync not in at_pong, "SET: %r, trace: %s" % (got, after))
    os.remove(fresh)
    s = Server(a, ["send", fresh, "always"], {"BENDKV_FAIL_DIRSYNC": "1"})
    c = s.connect()
    got = ask(c, b"SET", b"k", b"v") if c is not None else b""
    code = s.exited(5)
    log = s.stop()
    ok &= check("a failed sync of the directory stops the start before any reply",
                code == 1 and got == b"" and
                "Can't sync the directory of the append-only file %s: Input/output error" % fresh in log,
                "SET: %r, exit %s, log: %s" % (got, code, log[-300:]))
    if c is not None:
        c.close()
    os.remove(trace)
    s = Server(a, ["send", fresh, "always"], {"BENDKV_TRACE": trace})
    c = s.connect()
    pong = ask(c, b"PING") if c is not None else b""
    at_pong = traced(trace)
    if c is not None:
        c.close()
    s.stop()
    ok &= check("the next start finds the file and syncs its directory again",
                pong == b"+PONG\r\n" and dsync in at_pong, "PING: %r, trace: %s" % (pong, at_pong))
    for p in [fresh, trace]:
        os.remove(p)

    # files the start cannot replay as they were written: each stops it,
    # naming the entry (from 1) and its first byte, and leaves the file
    # as it was; the first entry, SET a 1, is 27 bytes
    bad = os.path.join(a.dir, "fail_bad.aof")
    one = entry(b"SET", b"a", b"1")
    for name, data, want in [
            ("an unknown command stops the start",
             one + entry(b"SXT", b"lost", b"v") + entry(b"SET", b"after", b"ok"),
             "entry 2, at byte 27: ERR unknown command 'SXT', with args beginning with: 'lost' 'v'"),
            ("a wrong number of arguments stops the start",
             one + entry(b"SET", b"k"), "entry 2, at byte 27: ERR wrong number of arguments for 'set' command"),
            ("an argument that does not read stops the start",
             one + entry(b"SET", b"k", b"v", b"EX", b"abc"),
             "entry 2, at byte 27: ERR value is not an integer or out of range"),
            ("a database not there stops the start",
             one + entry(b"SELECT", b"16") + entry(b"SET", b"k", b"v"),
             "entry 2, at byte 27: ERR DB index is out of range"),
            ("a database number that does not read stops the start",
             one + entry(b"SELECT", b"x") + entry(b"SET", b"k", b"v"),
             "entry 2, at byte 27: ERR SELECT of a database number that does not read"),
            ("a command of the server stops the start",
             one + entry(b"CONFIG", b"SET", b"maxmemory", b"1"),
             "entry 2, at byte 27: ERR a command of a connection or of the server, which no file holds"),
            ("a bad entry before an entry cut short stops the start, and nothing is cut",
             one + entry(b"SXT", b"x") + b"*3\r\n$3\r\nSET\r\n$1\r\nk",
             "entry 2, at byte 27: ERR unknown command 'SXT', with args beginning with: 'x'")]:
        ok &= unreplayable(a, bad, name, data, want)
    os.remove(bad)

    # a transaction left open (a crash cut the file while it was written)
    # is reverted, as Redis reverts it: none of its commands is applied,
    # and the file is cut back to before its MULTI
    opened = os.path.join(a.dir, "fail_open.aof")
    for name, data in [
            ("a transaction left open is reverted, and the file cut back to before it",
             one + entry(b"MULTI") + entry(b"SET", b"b", b"2")),
            ("a transaction left open, then an entry cut short, is reverted too",
             one + entry(b"MULTI") + entry(b"SET", b"b", b"2") + b"*3\r\n$3\r\nSET\r\n$1\r\nc")]:
        with open(opened, "wb") as f:
            f.write(data)
        s = Server(a, ["send", opened, "always"])
        c = s.connect()
        got = [ask(c, b"GET", b"a"), ask(c, b"GET", b"b")] if c is not None else []
        if c is not None:
            c.close()
        log = s.stop()
        with open(opened, "rb") as f:
            left = f.read()
        ok &= check(name, got == [b"$1\r\n1\r\n", b"$-1\r\n"] and left == one and
                    "Revert incomplete MULTI/EXEC transaction" in log,
                    "replies: %r, file: %r, log: %s" % (got, left, log[-300:]))
    os.remove(opened)

    # a file as Redis writes it: SELECT, a MULTI and EXEC around a DEL and
    # a SET (a key whose time passed, deleted as a write meets it), names
    # in lowercase, a time from 1970
    redis_file = os.path.join(a.dir, "fail_redis.aof")
    with open(redis_file, "wb") as f:
        f.write(entry(b"SELECT", b"0") + entry(b"set", b"k", b"v") + entry(b"MULTI") +
                entry(b"del", b"k") + entry(b"set", b"k", b"w") + entry(b"EXEC") +
                entry(b"SELECT", b"3") + entry(b"SET", b"x", b"y") +
                entry(b"PEXPIREAT", b"x", b"99999999999999"))
    s = Server(a, ["send", redis_file, "always"])
    c = s.connect()
    got = [ask(c, b"GET", b"k"), ask(c, b"SELECT", b"3"), ask(c, b"GET", b"x"),
           ask(c, b"PEXPIRETIME", b"x")] if c is not None else []
    if c is not None:
        c.close()
    log = s.stop()
    ok &= check("a file as Redis writes it, with MULTI and EXEC, restores",
                got == [b"$1\r\nw\r\n", b"+OK\r\n", b"$1\r\ny\r\n", b":99999999999999\r\n"],
                "replies: %r, log: %s" % (got, log[-300:]))
    os.remove(redis_file)

    print("ALL OK" if ok else "SOME CHECKS FAILED")
    return ok


if __name__ == "__main__":
    raise SystemExit(0 if main() else 1)
