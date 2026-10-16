#!/usr/bin/env python3
"""What the RDB file costs, on BendKV and on Redis: each server, in a fresh
directory of its own, is filled with the same keys (KEYS strings of SIZE
random bytes, which LZF does not make shorter, so that Redis's file and
BendKV's, which has no LZF, are of a size; or as many hashes of 10 fields
of SIZE random bytes with --hashes), then answers a SAVE
(its time, as the client waits for it), and the file's size is read;
then the server stops and starts again from its file: the time until it
answers PING, the time its log gives ("DB loaded from disk"), and its
resident memory before and after. Each step runs ROUNDS times, the
servers in turn, and the medians are printed (section 67 of
PERFORMANCE.md).

With --bgsave, each server filled so answers a BGSAVE instead, while a
client sends it SETs of the keys one at a time, each awaited (a value of
SIZE random bytes for a random key): the time until INFO says the save
has ended, the SETs served meanwhile and their latency (median, 99th
percentile, highest), the server's resident memory before the save and
its highest during it, and the copy on write Redis reports
(rdb_last_cow_size; BendKV has no fork: section 72 of PERFORMANCE.md).

    python3 tools/rdb_cost.py [--bin build/bendkv] [--redis redis-server] [--keys 1000000] [--size 100] [--hashes] [--rounds 3] [--bgsave]
"""
import argparse
import os
import random
import re
import shutil
import socket
import statistics
import subprocess
import tempfile
import time


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def enc(*xs):
    out = b"*%d\r\n" % len(xs)
    for x in xs:
        x = x if isinstance(x, bytes) else str(x).encode()
        out += b"$%d\r\n%s\r\n" % (len(x), x)
    return out


class Conn:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port))
        self.buf = b""

    def lines(self, n):
        """reads n replies of one line each (+OK, :1, -ERR)"""
        out = []
        while len(out) < n:
            i = self.buf.find(b"\r\n")
            if i < 0:
                data = self.s.recv(1 << 20)
                if not data:
                    raise EOFError("closed")
                self.buf += data
                continue
            out.append(self.buf[:i])
            self.buf = self.buf[i + 2:]
        return out

    def ask(self, *xs):
        self.s.sendall(enc(*xs))
        return self.lines(1)[0]

    def bulk(self, *xs):
        """sends a command whose reply is one bulk string, and reads it"""
        self.s.sendall(enc(*xs))
        n = int(self.lines(1)[0][1:])
        while len(self.buf) < n + 2:
            data = self.s.recv(1 << 20)
            if not data:
                raise EOFError("closed")
            self.buf += data
        out, self.buf = self.buf[:n], self.buf[n + 2:]
        return out


def up(port, p, limit=600):
    t0 = time.time()
    while time.time() - t0 < limit:
        if p.poll() is not None:
            raise RuntimeError("the server exited (%s)" % p.returncode)
        try:
            c = Conn(port)
            if c.ask("PING") == b"+PONG":
                c.s.close()
                return time.time() - t0
        except OSError:
            pass
        time.sleep(0.01)
    raise RuntimeError("no answer")


def rss(pid):
    with open("/proc/%d/status" % pid) as f:
        for line in f:
            if line.startswith("VmRSS:"):
                return int(line.split()[1]) * 1024
    return 0


def start(exe, d, port):
    out = open(os.path.join(d, "out.log"), "a")
    p = subprocess.Popen([exe, "--port", str(port), "--dir", d, "--bind", "127.0.0.1", "--save", ""], cwd=d,
                         stdout=out, stderr=subprocess.STDOUT)
    return p, up(port, p)


def fill(port, keys, size, hashes):
    c = Conn(port)
    batch = 1000
    rnd = random.Random(1)
    for i in range(0, keys, batch):
        n = min(batch, keys - i)
        if hashes:
            data = b"".join(enc("HSET", "h:%d" % j, *[x for f in range(10) for x in (b"f%d" % f, rnd.randbytes(size))])
                            for j in range(i, i + n))
        else:
            data = b"".join(enc("SET", "key:%d" % j, rnd.randbytes(size)) for j in range(i, i + n))
        c.s.sendall(data)
        c.lines(n)
    c.s.close()


def stop(port, p):
    c = Conn(port)
    c.s.sendall(enc("SHUTDOWN", "NOSAVE"))
    p.wait(timeout=600)


def persistence(c, name):
    m = re.search(rb"\r\n%s:([^\r]*)" % name.encode(), c.bulk("INFO", "persistence"))
    return m.group(1) if m else b""


def bgsave(port, pid, keys, size):
    """BGSAVE, while a client sends SETs one at a time"""
    c, w = Conn(port), Conn(port)
    rnd = random.Random(2)
    before = peak = rss(pid)
    lat = []
    t0 = time.time()
    r = c.ask("BGSAVE")
    if r != b"+Background saving started":
        raise RuntimeError("BGSAVE answered %r" % r)
    while True:
        for _ in range(50):
            x = enc("SET", "key:%d" % rnd.randrange(keys), rnd.randbytes(size))
            t1 = time.perf_counter()
            w.s.sendall(x)
            if w.lines(1)[0] != b"+OK":
                raise RuntimeError("SET failed")
            lat.append(time.perf_counter() - t1)
        peak = max(peak, rss(pid))
        if persistence(c, "rdb_bgsave_in_progress") == b"0":
            break
    took = time.time() - t0
    ok = persistence(c, "rdb_last_bgsave_status")
    cow = int(persistence(c, "rdb_last_cow_size") or b"0")
    c.s.close()
    w.s.close()
    if ok != b"ok":
        raise RuntimeError("the background save failed")
    lat.sort()
    return {"bgsave": took, "sets": len(lat), "p50": lat[len(lat) // 2], "p99": lat[len(lat) * 99 // 100],
            "max": lat[-1], "rss": before, "peak": peak, "cow": cow}


def one(exe, root, keys, size, hashes, bg=False):
    d = tempfile.mkdtemp(dir=root)
    port = free_port()
    p, _ = start(exe, d, port)
    fill(port, keys, size, hashes)
    if bg:
        res = bgsave(port, p.pid, keys, size)
        stop(port, p)
        shutil.rmtree(d, ignore_errors=True)
        return res
    before = rss(p.pid)
    c = Conn(port)
    t0 = time.time()
    r = c.ask("SAVE")
    save = time.time() - t0
    if r != b"+OK":
        raise RuntimeError("SAVE answered %r" % r)
    c.s.close()
    size_f = os.path.getsize(os.path.join(d, "dump.rdb"))
    stop(port, p)
    port = free_port()
    p, ready = start(exe, d, port)
    after = rss(p.pid)
    c = Conn(port)
    n = c.ask("DBSIZE")
    c.s.close()
    stop(port, p)
    with open(os.path.join(d, "out.log")) as f:
        m = re.findall(r"DB loaded from disk: ([0-9.]+) seconds", f.read())
    shutil.rmtree(d, ignore_errors=True)
    if n != b":%d" % keys:
        raise RuntimeError("DBSIZE answered %r after the start" % n)
    return {"save": save, "size": size_f, "ready": ready, "load": float(m[-1]) if m else float("nan"),
            "rss": before, "rss2": after}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default="build/bendkv")
    ap.add_argument("--redis", default="redis-server")
    ap.add_argument("--keys", type=int, default=1000000)
    ap.add_argument("--size", type=int, default=100)
    ap.add_argument("--hashes", action="store_true")
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--bgsave", action="store_true")
    a = ap.parse_args()
    if a.bgsave and a.hashes:
        ap.error("--bgsave writes strings: no --hashes")
    root = tempfile.mkdtemp(prefix="rdb_cost.")
    res = {"bendkv": [], "redis": []}
    try:
        for _ in range(a.rounds):
            for name, exe in (("bendkv", os.path.abspath(a.bin)), ("redis", a.redis)):
                res[name].append(one(exe, root, a.keys, a.size, a.hashes, a.bgsave))
    finally:
        shutil.rmtree(root, ignore_errors=True)
    what = "%d hashes of 10 fields of %d bytes" % (a.keys, a.size) if a.hashes else "%d keys of %d bytes" % (a.keys, a.size)
    print("%s, medians of %d rounds" % (what, a.rounds))
    if a.bgsave:
        print("%-8s %10s %8s %9s %9s %9s %8s %8s %8s" % ("server", "BGSAVE s", "SETs", "p50 us", "p99 us", "max us",
                                                         "RSS MB", "peak MB", "CoW MB"))
        for name in ("bendkv", "redis"):
            xs = res[name]

            def med(k):
                return statistics.median(x[k] for x in xs)
            print("%-8s %10.3f %8d %9.0f %9.0f %9.0f %8.1f %8.1f %8.1f" % (
                name, med("bgsave"), med("sets"), med("p50") * 1e6, med("p99") * 1e6, med("max") * 1e6,
                med("rss") / 1e6, med("peak") / 1e6, med("cow") / 1e6))
        return
    print("%-8s %10s %14s %12s %12s %10s %10s" % ("server", "SAVE s", "file bytes", "start s", "load s", "RSS MB", "RSS2 MB"))
    for name in ("bendkv", "redis"):
        xs = res[name]

        def med(k):
            return statistics.median(x[k] for x in xs)
        print("%-8s %10.3f %14d %12.3f %12.3f %10.1f %10.1f" % (name, med("save"), med("size"), med("ready"), med("load"),
                                                                 med("rss") / 1e6, med("rss2") / 1e6))


if __name__ == "__main__":
    main()
