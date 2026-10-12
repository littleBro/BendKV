#!/usr/bin/env python3
"""Connections that end, every way one can: the client closes after a
request or before any, QUIT, a protocol error, the client resetting the
connection before the server reads its request, and while the server
sends it a reply of a megabyte. Each way is taken many times, on a
BendKV the test starts itself, with replies posted to the writer thread
and sent from the loop; then INFO must count no connection but the
test's own, the database must answer on a new connection, and the
runtime's table of channels must not have grown: each connection opens a
channel for its answers, and its end must close it. The table's size is
read in the server's memory (chan_len, found in the binary's symbol
table, read through /proc/<pid>/mem, which a parent may read); where it
cannot be read, that check is skipped and said so.

    python3 tests/conn_test.py --bin build/bendkv --port 6380
"""
import argparse
import os
import socket
import struct
import subprocess
import time


def resp(*args):
    out = b"*%d\r\n" % len(args)
    for a in args:
        out += b"$%d\r\n%s\r\n" % (len(a), a)
    return out


# the address of a symbol in an ELF64 file, and the lowest address its
# segments load at (a position-independent binary loads at a base the
# kernel picks, which /proc/<pid>/maps shows)
def elf_symbol(path, name):
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"\x7fELF" or data[4] != 2:
        return None
    phoff, shoff = struct.unpack_from("<QQ", data, 0x20)
    phentsize, phnum, shentsize, shnum = struct.unpack_from("<HHHH", data, 0x36)
    low = min((struct.unpack_from("<Q", data, phoff + i * phentsize + 0x10)[0]
               for i in range(phnum) if struct.unpack_from("<I", data, phoff + i * phentsize)[0] == 1),
              default=0)
    sections = [struct.unpack_from("<IIQQQQIIQQ", data, shoff + i * shentsize) for i in range(shnum)]
    for (_, kind, _, _, off, size, link, _, _, entsize) in sections:
        if kind != 2:  # SHT_SYMTAB
            continue
        stroff = sections[link][4]
        for k in range(size // entsize):
            st_name, _, _, _, st_value, _ = struct.unpack_from("<IBBHQQ", data, off + k * entsize)
            end = data.index(b"\0", stroff + st_name)
            if data[stroff + st_name:end] == name:
                return st_value, low & ~0xfff
    return None


class Table:
    """The runtime's count of channel rows ever handed out (a freed row is
    handed out again before a new one is made), read in the server's
    memory."""

    def __init__(self, path, pid):
        self.pid = pid
        self.addr = None
        self.why = ""
        sym = elf_symbol(path, b"chan_len")
        if sym is None:
            self.why = "no chan_len in the binary's symbol table"
            return
        value, low = sym
        real = os.path.realpath(path)
        try:
            with open("/proc/%d/maps" % pid) as f:
                for line in f:
                    parts = line.split()
                    if len(parts) >= 6 and os.path.realpath(parts[5]) == real and int(parts[2], 16) == 0:
                        self.addr = int(parts[0].split("-")[0], 16) - low + value
                        break
            self.read()
        except (OSError, ValueError) as e:
            self.addr, self.why = None, "cannot read the server's memory: %s" % e
        if self.addr is None and not self.why:
            self.why = "the binary is not in the server's maps"

    def read(self):
        with open("/proc/%d/mem" % self.pid, "rb") as f:
            f.seek(self.addr)
            return struct.unpack("<I", f.read(4))[0]


class Client:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=10)

    def ask(self, *args):
        self.s.sendall(resp(*args))
        got = b""
        while True:
            if b"\r\n" in got:
                head = got[:got.index(b"\r\n")]
                if not head.startswith(b"$") or int(head[1:]) < 0:
                    return got
                if len(got) >= len(head) + 4 + int(head[1:]):
                    return got
            chunk = self.s.recv(1 << 16)
            if not chunk:
                raise ConnectionError("closed")
            got += chunk

    def clients(self):
        for line in self.ask(b"INFO", b"clients").split(b"\r\n"):
            if line.startswith(b"connected_clients:"):
                return int(line.split(b":")[1])
        raise ValueError("no connected_clients")


def until_eof(s, limit=5.0):
    s.settimeout(limit)
    try:
        while s.recv(1 << 16):
            pass
        return True
    except OSError:
        return True


def reset(s):
    s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    s.close()


# the ways a connection ends, each a function of the port
def eof_after_request(port):
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    s.sendall(resp(b"PING"))
    s.recv(64)
    s.close()


def eof_at_once(port):
    socket.create_connection(("127.0.0.1", port), timeout=5).close()


def by_quit(port):
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    s.sendall(resp(b"SET", b"q", b"1") + resp(b"QUIT") + resp(b"PING"))
    until_eof(s)
    s.close()


def protocol_error(port):
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    s.sendall(resp(b"PING") + b"*1\r\nX\r\n")
    until_eof(s)
    s.close()


def reset_before_read(port):
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    s.sendall(resp(b"GET", b"big"))
    reset(s)


def reset_while_sending(port):
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    s.sendall(resp(b"GET", b"big") * 2)
    s.recv(1024)
    reset(s)


WAYS = [("the client closes after a request", eof_after_request),
        ("the client closes before any", eof_at_once),
        ("QUIT", by_quit),
        ("a protocol error", protocol_error),
        ("the client resets before the server reads", reset_before_read),
        ("the client resets while the server sends", reset_while_sending)]


def run(binary, port, mode, rounds):
    ok = True
    log = open("build/conn_test-%s.log" % mode, "w")
    p = subprocess.Popen([binary, str(port), mode], stdout=log, stderr=log)
    try:
        end = time.time() + 10
        while True:
            try:
                ctl = Client(port)
                break
            except OSError:
                if time.time() > end:
                    raise
                time.sleep(0.05)
        ctl.ask(b"SET", b"big", b"x" * (1 << 20))
        table = Table(binary, p.pid)
        before = table.read() if table.addr is not None else None
        for name, way in WAYS:
            for _ in range(rounds):
                way(port)
            # the server lets each go: INFO counts the test's own alone
            end = time.time() + 10
            while ctl.clients() != 1 and time.time() < end:
                time.sleep(0.02)
            n = ctl.clients()
            good = n == 1
            ok &= good
            print("%s %s: %s, %d times, every connection let go (%d counted)" %
                  ("ok  " if good else "FAIL", mode, name, rounds, n))
        c = Client(port)
        good = c.ask(b"PING") == b"+PONG\r\n" and c.ask(b"SET", b"k", b"v") == b"+OK\r\n" and \
            c.ask(b"GET", b"k") == b"$1\r\nv\r\n" and c.ask(b"GET", b"q") == b"$1\r\n1\r\n"
        ok &= good
        print("%s %s: the database answers a new connection" % ("ok  " if good else "FAIL", mode))
        c.s.close()
        if table.addr is None:
            print("skip %s: channels not counted (%s)" % (mode, table.why))
        else:
            after = table.read()
            n = rounds * len(WAYS)
            good = after - before <= 16
            ok &= good
            print("%s %s: %d connections, %d channel rows before and %d after" %
                  ("ok  " if good else "FAIL", mode, n, before, after))
        ctl.s.close()
    finally:
        p.terminate()
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
        log.close()
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default="build/bendkv")
    ap.add_argument("--port", type=int, default=6380)
    ap.add_argument("--rounds", type=int, default=50)
    a = ap.parse_args()
    ok = True
    for mode in ("post", "send"):
        ok &= run(a.bin, a.port, mode, a.rounds)
    print("ALL OK" if ok else "SOME CHECKS FAILED")
    return ok


if __name__ == "__main__":
    raise SystemExit(0 if main() else 1)
