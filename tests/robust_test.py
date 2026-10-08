#!/usr/bin/env python3
"""Robustness checks for a RESP server: requests split into single bytes,
a large value, protocol garbage, many connections at once.

    python3 tests/robust_test.py --port 6380
"""
import argparse
import socket
import threading
import time


def resp(*args):
    out = b"*%d\r\n" % len(args)
    for a in args:
        out += b"$%d\r\n%s\r\n" % (len(a), a)
    return out


def read_until(sock, n_bytes=None, end=None, timeout=10):
    sock.settimeout(timeout)
    buf = b""
    while True:
        if n_bytes is not None and len(buf) >= n_bytes:
            return buf
        if end is not None and buf.endswith(end):
            return buf
        chunk = sock.recv(1 << 20)
        if not chunk:
            return buf
        buf += chunk


def check(name, got, want):
    status = "ok  " if got == want else "FAIL"
    print("%s %s" % (status, name))
    if got != want:
        print("     got: %r\n    want: %r" % (got[:200], want[:200]))
    return got == want


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=6380)
    a = ap.parse_args()
    ok = True
    s = socket.create_connection(("127.0.0.1", a.port))

    # one byte per write: the parser must resume across reads
    req = resp(b"SET", b"split", b"value-split") + resp(b"GET", b"split")
    for b in req:
        s.sendall(bytes([b]))
        time.sleep(0.0005)
    ok &= check("byte-by-byte request", read_until(s, end=b"value-split\r\n"), b"+OK\r\n$11\r\nvalue-split\r\n")

    # a 1MB value round-trips
    big = bytes(i % 251 for i in range(1 << 20))
    t0 = time.time()
    s.sendall(resp(b"SET", b"big", big))
    got = read_until(s, end=b"\r\n")
    ok &= check("SET 1MB (%.0f ms)" % ((time.time() - t0) * 1000), got, b"+OK\r\n")
    t0 = time.time()
    s.sendall(resp(b"GET", b"big"))
    want = b"$%d\r\n" % len(big) + big + b"\r\n"
    got = read_until(s, n_bytes=len(want))
    ok &= check("GET 1MB (%.0f ms)" % ((time.time() - t0) * 1000), got, want)
    s.sendall(resp(b"STRLEN", b"big"))
    ok &= check("STRLEN 1MB", read_until(s, end=b"\r\n"), b":%d\r\n" % len(big))

    # a malformed request gets an error and the connection closes
    g = socket.create_connection(("127.0.0.1", a.port))
    g.sendall(b"*2\r\n$3\r\nGET\r\n#oops\r\n")
    got = read_until(g, end=b"\r\n")
    ok &= check("protocol error answered", got.startswith(b"-ERR Protocol error"), True)
    ok &= check("protocol error closes", read_until(g, timeout=5), b"")

    # many clients at once, each with its own keys
    errors = []

    def client(i):
        try:
            c = socket.create_connection(("127.0.0.1", a.port))
            for j in range(200):
                k, v = b"c%d:%d" % (i, j), b"v%d" % (i * 1000 + j)
                c.sendall(resp(b"SET", k, v) + resp(b"GET", k))
                want = b"+OK\r\n$%d\r\n%s\r\n" % (len(v), v)
                got = read_until(c, n_bytes=len(want))
                if got != want:
                    errors.append((i, j, got))
                    return
            c.close()
        except Exception as e:  # noqa
            errors.append((i, repr(e)))

    ts = [threading.Thread(target=client, args=(i,)) for i in range(50)]
    t0 = time.time()
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    ok &= check("50 concurrent clients x 200 SET+GET (%.2f s)" % (time.time() - t0), errors, [])
    s.sendall(resp(b"DBSIZE"))
    print("     dbsize now:", read_until(s, end=b"\r\n").strip())
    print("ALL OK" if ok else "SOME CHECKS FAILED")
    return ok


if __name__ == "__main__":
    raise SystemExit(0 if main() else 1)
