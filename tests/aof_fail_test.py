#!/usr/bin/env python3
"""Failures of the append-only file's disk, injected by tests/fail_io.c (an
LD_PRELOAD shim). A file that is there but cannot be read stops the start
(an empty database would be served, and the next writes appended to the
file that holds the old one). A failed fsync stops the server with
everysec as it does with always. A file that is not there is still an
empty database.

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

    print("ALL OK" if ok else "SOME CHECKS FAILED")
    return ok


if __name__ == "__main__":
    raise SystemExit(0 if main() else 1)
