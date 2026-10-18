#!/usr/bin/env python3
"""stream_waits.py: rounds of a stream's wait, on one server. Each
round, each of N consumers (--clients, 1) sends XREAD with BLOCK 0 after
the last ID it read (or, with --group, XREADGROUP at ">" in a group of
its own, as a group gives an entry to one consumer alone), the producer
waits until INFO counts them all blocked, XADDs one entry, and each
consumer reads it: one wait, one XADD and N clients served. With
--noblock, the same commands without the wait: the XADD, one INFO, then
each consumer's read without BLOCK, which the entry serves at once. W
rounds (--warm, 200) first, then ROUNDS timed; prints the rounds a
second, and the INFOs a round (section 88 of PERFORMANCE.md).

    python3 tools/stream_waits.py PORT ROUNDS [--group] [--noblock] [--clients N] [--warm W]
"""
import argparse
import socket
import time


def enc(*args):
    out = [b"*%d\r\n" % len(args)]
    for a in args:
        a = a if isinstance(a, bytes) else str(a).encode()
        out.append(b"$%d\r\n%s\r\n" % (len(a), a))
    return b"".join(out)


class Conn:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port))
        self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.buf = b""

    def send(self, *args):
        self.s.sendall(enc(*args))

    def line(self):
        while b"\r\n" not in self.buf:
            self.buf += self.s.recv(1 << 16)
        l, self.buf = self.buf.split(b"\r\n", 1)
        return l

    def reply(self):
        l = self.line()
        t, rest = l[:1], l[1:]
        if t in b"+-:":
            return rest
        if t == b"$":
            n = int(rest)
            if n < 0:
                return None
            while len(self.buf) < n + 2:
                self.buf += self.s.recv(1 << 16)
            v, self.buf = self.buf[:n], self.buf[n + 2:]
            return v
        if t == b"*":
            n = int(rest)
            return None if n < 0 else [self.reply() for _ in range(n)]
        raise ValueError(l)

    def cmd(self, *args):
        self.send(*args)
        return self.reply()


def blocked(c):
    info = c.cmd("INFO", "clients").decode()
    for l in info.split("\r\n"):
        if l.startswith("blocked_clients:"):
            return int(l.split(":")[1])
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("port", type=int)
    ap.add_argument("rounds", type=int)
    ap.add_argument("--group", action="store_true")
    ap.add_argument("--noblock", action="store_true")
    ap.add_argument("--clients", type=int, default=1)
    ap.add_argument("--warm", type=int, default=200)
    a = ap.parse_args()
    p = Conn(a.port)
    p.cmd("DEL", "xw")
    if a.group:
        for i in range(a.clients):
            p.cmd("XGROUP", "CREATE", "xw", "g%d" % i, "$", "MKSTREAM")
    cs = [Conn(a.port) for _ in range(a.clients)]
    last = ["0-0"] * a.clients
    n = 0
    polls = 0

    def read(i, c):
        b = [] if a.noblock else ["BLOCK", "0"]
        if a.group:
            c.send("XREADGROUP", "GROUP", "g%d" % i, "c", *b, "STREAMS", "xw", ">")
        else:
            c.send("XREAD", *b, "STREAMS", "xw", last[i])

    def round_():
        nonlocal n, polls
        if a.noblock:
            n += 1
            p.cmd("XADD", "xw", "%d-1" % n, "f", "v")
            polls += 1
            blocked(p)
            for i, c in enumerate(cs):
                read(i, c)
        else:
            for i, c in enumerate(cs):
                read(i, c)
            polls += 1
            while blocked(p) < a.clients:
                polls += 1
            n += 1
            p.cmd("XADD", "xw", "%d-1" % n, "f", "v")
        for i, c in enumerate(cs):
            r = c.reply()
            last[i] = r[0][1][-1][0].decode()

    for _ in range(a.warm):
        round_()
    polls = 0
    t = time.time()
    for _ in range(a.rounds):
        round_()
    dt = time.time() - t
    print("%d rounds in %.2f s: %.0f rounds a second, %.2f INFOs a round" % (a.rounds, dt, a.rounds / dt, polls / a.rounds), flush=True)


if __name__ == "__main__":
    main()
