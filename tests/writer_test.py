#!/usr/bin/env python3
"""A client that stops reading holds up only itself (issue #3). Its replies
wait for it, as a Redis client's output buffer does, while another client
gets an 8 MiB reply and quick ones, new connections are taken, and the
cron's sweep deletes an expired key; a client that asked for a QUIT
behind a large reply gets the reply whole before the close; then the
stalled client reads all it was owed, in order, with the replies to what
it asks while it reads after them. With replies posted (TCP.post), the
writer thread used to wait on the full socket and stall every reply
queued after it, and the loop waited for room in the writer's ring once
4,096 posts were queued.

    python3 tests/writer_test.py --port 6380
"""
import argparse
import socket
import sys
import threading
import time

MB = 1 << 20


def resp(*args):
    out = b"*%d\r\n" % len(args)
    for a in args:
        out += b"$%d\r\n%s\r\n" % (len(a), a)
    return out


def read_exactly(sock, n, timeout):
    """n bytes, or what came before the deadline or the end"""
    end = time.time() + timeout
    buf = bytearray()
    while len(buf) < n:
        left = end - time.time()
        if left <= 0:
            break
        sock.settimeout(left)
        try:
            chunk = sock.recv(min(n - len(buf), MB))
        except socket.timeout:
            break
        if not chunk:
            break
        buf += chunk
    return bytes(buf)


def read_line(sock, timeout):
    end = time.time() + timeout
    buf = b""
    while not buf.endswith(b"\r\n"):
        left = end - time.time()
        if left <= 0:
            break
        sock.settimeout(left)
        try:
            chunk = sock.recv(1)
        except socket.timeout:
            break
        if not chunk:
            break
        buf += chunk
    return buf


def ask(sock, req, timeout=2):
    sock.sendall(req)
    return read_line(sock, timeout)


def at_end(sock, timeout):
    sock.settimeout(timeout)
    try:
        return sock.recv(1) == b""
    except socket.timeout:
        return False


def info_field(sock, name):
    sock.sendall(resp(b"INFO", b"stats"))
    head = read_line(sock, 2)
    if not head.startswith(b"$"):
        return None
    body = read_exactly(sock, int(head[1:]) + 2, 2)
    for line in body.split(b"\r\n"):
        if line.startswith(name + b":"):
            return int(line.split(b":")[1])
    return None


def check(name, ok, detail=""):
    print("%s %s" % ("ok  " if ok else "FAIL", name))
    if not ok:
        if detail:
            print("     " + detail)
        sys.exit(1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=6380)
    ap.add_argument("--stalls", type=int, default=4600,
                    help="one-request batches the stalled client sends (more than the old ring's 4,096 posts)")
    a = ap.parse_args()
    addr = ("127.0.0.1", a.port)
    big = bytes((i * 7 + 3) % 251 for i in range(MB))
    bulk = b"$%d\r\n" % len(big) + big + b"\r\n"

    b = socket.create_connection(addr)
    check("SET a 1 MiB value", ask(b, resp(b"SET", b"writer:big", big), 10) == b"+OK\r\n")

    # the stalled client: 32 MiB of replies, and it does not read them, so
    # its socket fills and the rest waits for it at the server
    s = socket.create_connection(addr)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 64 * 1024)
    s.sendall(resp(b"GET", b"writer:big") * 32)
    time.sleep(0.5)

    # another client's large reply is not queued behind the stalled one
    t0 = time.time()
    b.sendall(resp(b"GET", b"writer:big") * 8)
    got = read_exactly(b, 8 * len(bulk), 10)
    check("another client's 8 MiB reply (%.0f ms)" % ((time.time() - t0) * 1000), got == bulk * 8,
          "got %d of %d bytes" % (len(got), 8 * len(bulk)))

    # many more replies for the stalled client, one request a batch: each
    # is a post of its own while its socket is full
    for _ in range(a.stalls):
        s.sendall(b"PING\r\n")
        time.sleep(0.0002)
    time.sleep(0.2)

    t0 = time.time()
    got = ask(b, resp(b"PING"))
    check("PING from another client (%.1f ms)" % ((time.time() - t0) * 1000), got == b"+PONG\r\n", repr(got))

    # new connections are taken and served, and a QUIT closes one
    t0 = time.time()
    c = socket.create_connection(addr, timeout=5)
    got = ask(c, resp(b"PING"))
    check("PING on a new connection (%.1f ms)" % ((time.time() - t0) * 1000), got == b"+PONG\r\n", repr(got))
    check("QUIT on the new connection", ask(c, resp(b"QUIT")) == b"+OK\r\n" and at_end(c, 5))
    c.close()

    # the cron's ticks go on: its sweep deletes a key whose time passed
    # (nothing reads the key, which would delete it on the way)
    before = info_field(b, b"expired_keys")
    check("SET with PX", ask(b, resp(b"SET", b"writer:tmp", b"1", b"PX", b"20")) == b"+OK\r\n")
    t0 = time.time()
    after = before
    while time.time() - t0 < 5 and after == before:
        time.sleep(0.05)
        after = info_field(b, b"expired_keys")
    check("the sweep runs (%.0f ms)" % ((time.time() - t0) * 1000), before is not None and after == before + 1,
          "expired_keys %r -> %r" % (before, after))

    # a QUIT after a large reply: the close comes after the whole reply,
    # also when the client reads it late
    e = socket.create_connection(addr)
    e.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 64 * 1024)
    e.sendall(resp(b"GET", b"writer:big") * 4 + resp(b"QUIT"))
    time.sleep(0.5)
    want = bulk * 4 + b"+OK\r\n"
    got = read_exactly(e, len(want), 10)
    check("4 MiB, then QUIT's +OK, then the close", got == want and at_end(e, 5),
          "got %d of %d bytes" % (len(got), len(want)))
    e.close()

    # the stalled client reads at last, and asks for more as it reads: the
    # replies that come while it drains its backlog go out after it
    t0 = time.time()
    echoes = [b"e%d" % i for i in range(2000)]
    want = bulk * 32 + b"+PONG\r\n" * a.stalls + b"".join(b"$%d\r\n%s\r\n" % (len(x), x) for x in echoes)
    got = []
    reader = threading.Thread(target=lambda: got.append(read_exactly(s, len(want), 30)))
    reader.start()
    for x in echoes:
        s.sendall(resp(b"ECHO", x))
        time.sleep(0.0001)
    reader.join(40)
    got = got[0] if got else b""
    check("the stalled client's 32 MiB, %d PONGs and 2000 ECHOs, in order (%.0f ms)" % (a.stalls, (time.time() - t0) * 1000),
          got == want, "got %d of %d bytes%s" % (len(got), len(want), "" if want.startswith(got) else ", out of order"))
    check("QUIT on the stalled client", ask(s, resp(b"QUIT")) == b"+OK\r\n" and at_end(s, 5))
    s.close()

    check("DEL", ask(b, resp(b"DEL", b"writer:big")) == b":1\r\n")
    b.close()


if __name__ == "__main__":
    main()
