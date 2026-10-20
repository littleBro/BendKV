#!/usr/bin/env python3
"""The output buffer of a client that must authenticate, against Redis
7.2.16: BendKV (its replies posted, io-threads 2, then sent from its
loop, io-threads 1) and a redis-server, each started with requirepass in
a directory of its own, the scenarios run on each with clients of their
own, their transcripts compared line by line, and the lines each logs.

Redis writes a client's replies once its event loop's round has run what
it read: they go to the client's buffer of 16 KB, then to a list, and a
client that must authenticate is closed at the list's first block
(checkClientOutputBufferLimits), the round's replies not written, with a
line in the log (closeClientOnOutputBufferLimitReached). The scenarios:

1. 481 PINGs in one write, answered NOAUTH (16,354 bytes), the
   connection open, and a PING after; then 482 on another: closed, no
   reply.
2. 400 PINGs, the replies read, then 400 more: all answered.
3. AUTH and an ECHO of 20,000 bytes in one write: answered.
4. RESET and 600 PINGs from a client that has authenticated: closed, no
   reply (after RESET it must authenticate again).
5. A client that came while the password was set, once it is removed:
   an ECHO of 20,000 bytes answered (it need not authenticate now).
6. A client that does not read and sends SETs 4,096 to a write: closed
   at once (a read's replies pass 16 KB).
7. A client that does not read and sends a SET to a write, as Redis's
   own test (unit/auth, "For unauthenticated clients output buffer is
   limited") sends them: closed once the socket's buffers are full (a
   kernel may let the client's own grow to 32 MB), within 64 MB. Not
   always with BendKV's replies sent from its loop: its connection
   sends a batch's replies before it reads more, so the client stalls
   its own connection (its replies wait in the socket), which stays
   open, unless a read of the connection brings more than 481 SETs,
   whose replies close it as above. Either is checked (and, stalled,
   that another client is served meanwhile, and that no line is logged
   for it).
8. The lines logged: one for each client closed, at WARNING, Redis's
   ("Client <its line in CLIENT LIST> scheduled to be closed ASAP for
   overcoming of output buffer limits."): the fields of the line in
   Redis's order, and those of them that tell the client (flags, db,
   name, sub, psub, ssub, multi, cmd, user, redir, resp).

    python3 tests/obuf_test.py --bin build/bendkv --bendkv 6380 --redis 6391 --dir build/obuf
"""
import argparse
import os
import re
import shutil
import socket
import subprocess
import sys
import time

PING = b"*1\r\n$4\r\nPING\r\n"


def enc(*args):
    out = b"*%d\r\n" % len(args)
    for a in args:
        a = a if isinstance(a, bytes) else str(a).encode()
        out += b"$%d\r\n%s\r\n" % (len(a), a)
    return out


def connect(port):
    s = socket.create_connection(("127.0.0.1", port))
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return s


def until(s, n, quiet=0.5):
    """The replies read until n came, the connection closed, or none came
    for a while: their count (lines), the bytes, and whether it is open"""
    got = b""
    s.settimeout(quiet)
    while True:
        if got.count(b"\r\n") >= n and n > 0:
            return (got.count(b"\r\n"), len(got), "open")
        try:
            b = s.recv(1 << 20)
        except socket.timeout:
            return (got.count(b"\r\n"), len(got), "open")
        except (ConnectionResetError, BrokenPipeError):
            return (got.count(b"\r\n"), len(got), "closed")
        if not b:
            return (got.count(b"\r\n"), len(got), "closed")
        got += b


def bulk(s, quiet=0.5):
    """an answer of +OK and a bulk, or what came of it"""
    got = b""
    s.settimeout(quiet)
    while True:
        m = re.match(rb"^(\+OK\r\n)?\$(\d+)\r\n", got)
        if m and len(got) >= m.end() + int(m.group(2)) + 2:
            return ("bulk", int(m.group(2)), "open")
        try:
            b = s.recv(1 << 20)
        except socket.timeout:
            return ("partial", len(got), "open")
        except (ConnectionResetError, BrokenPipeError):
            return ("partial", len(got), "closed")
        if not b:
            return ("partial", len(got), "closed")
        got += b


# the kernel's view of each connection that stalled (/proc/net/tcp: its
# state, queues and inode), printed when a comparison fails
STALLS = []
STATES = {"01": "ESTABLISHED", "04": "FIN_WAIT1", "05": "FIN_WAIT2", "06": "TIME_WAIT", "07": "CLOSE",
          "08": "CLOSE_WAIT", "09": "LAST_ACK", "0B": "CLOSING"}


def sockets(port):
    out = []
    try:
        rows = open("/proc/net/tcp").read().splitlines()[1:]
    except OSError:
        return out
    for r in rows:
        p = r.split()
        a, b = int(p[1].split(":")[1], 16), int(p[2].split(":")[1], 16)
        if port in (a, b):
            out.append("%d->%d %s tx:rx=%s inode=%s" % (a, b, STATES.get(p[3], p[3]), p[4], p[9]))
    return out


def flood(port, per, limit=64 << 20, idle=5.0):
    """SETs sent, per to a write, and no reply read, until the connection
    breaks ("closed"), 64 MB went, or the socket took nothing for 5 s
    ("stalled": a reset the client takes only as it sends again comes
    within its retransmission's timeout, a second or more once it backs
    off)"""
    s = connect(port)
    s.setblocking(False)
    me = s.getsockname()[1]
    chunk = enc("SET", "x", "5") * per
    sent, at, last = 0, 0, time.time()
    while sent < limit:
        try:
            n = s.send(chunk[at:])
        except BlockingIOError:
            if time.time() - last > idle:
                STALLS.append("flood %d, %d bytes sent: %s" % (per, sent, "; ".join(sockets(me))))
                return "stalled", s
            time.sleep(0.01)
            continue
        except OSError:
            s.close()
            return "closed", None
        sent += n
        at = (at + n) % len(chunk)
        last = time.time()
    return "open after 64 MB", s


def scenarios(port, log, send):
    a = connect(port)
    a.sendall(enc("AUTH", "pw"))
    log("0 admin", until(a, 1))
    # 1. 481 replies fit the 16 KB buffer, 482 do not
    s = connect(port)
    s.sendall(PING * 481)
    log("1 481 PINGs", until(s, 481))
    s.sendall(PING)
    log("1 one more", until(s, 1))
    s.close()
    s = connect(port)
    s.sendall(PING * 482)
    log("1 482 PINGs", until(s, 482))
    s.close()
    # 2. each round's replies fit
    s = connect(port)
    s.sendall(PING * 400)
    log("2 400 PINGs", until(s, 400))
    s.sendall(PING * 400)
    log("2 400 more", until(s, 400))
    s.close()
    # 3. a client that authenticates in the write
    s = connect(port)
    s.sendall(enc("AUTH", "pw") + enc("ECHO", "x" * 20000))
    log("3 AUTH and ECHO", bulk(s))
    s.close()
    # 4. RESET makes a client one that must authenticate again
    s = connect(port)
    s.sendall(enc("AUTH", "pw"))
    log("4 AUTH", until(s, 1))
    s.sendall(enc("RESET") + PING * 600)
    log("4 RESET and 600 PINGs", until(s, 601))
    s.close()
    # 5. a client that need not authenticate now
    s = connect(port)
    s.sendall(PING)
    log("5 before", until(s, 1))
    a.sendall(enc("CONFIG", "SET", "requirepass", ""))
    log("5 no password", until(a, 1))
    s.sendall(enc("ECHO", "x" * 20000))
    log("5 ECHO", bulk(s))
    a.sendall(enc("CONFIG", "SET", "requirepass", "pw"))
    log("5 password", until(a, 1))
    s.close()
    # 6. a client that does not read, its SETs 4,096 to a write
    state, f = flood(port, 4096)
    log("6 flood", state)
    if f is not None:
        f.close()
    # 7. and a SET to a write
    state, f = flood(port, 1)
    if send:
        a.sendall(PING)
        log("7 flood, sent from the loop", state, until(a, 1))
    else:
        log("7 flood", state)
    if f is not None:
        f.close()
    a.close()


KEYS = ("flags", "db", "name", "sub", "psub", "ssub", "multi", "cmd", "user", "redir", "resp")
LINE = re.compile(r"^\d+:[MCXS] \d+ \w+ \d+ [\d:.]+ ([.\-*#]) Client (.*) scheduled to be closed ASAP "
                  r"for overcoming of output buffer limits\.$")


def closed_lines(path):
    """the lines of clients closed for their output buffer: the level, the
    fields of the client's line in order, and those that tell the client"""
    out = []
    with open(path, errors="replace") as f:
        for l in f.read().splitlines():
            m = LINE.match(l)
            if m:
                fields = [p.split("=", 1) for p in m.group(2).split(" ")]
                out.append((m.group(1), [k for k, v in fields], [(k, v) for k, v in fields if k in KEYS]))
    return out


def up(argv, port, lg):
    """the server started, once it answers a PING (NOAUTH)"""
    p = subprocess.Popen(argv, stdout=open(lg, "w"), stderr=subprocess.STDOUT)
    for _ in range(200):
        try:
            s = connect(port)
            s.sendall(PING)
            n = until(s, 1)[0]
            s.close()
            if n == 1:
                return p
        except OSError:
            pass
        time.sleep(0.05)
    p.kill()
    sys.exit("FAIL: no server on port %d (%s)" % (port, lg))


def run(argv, port, lg, send):
    p = up(argv, port, lg)
    lines = []
    try:
        scenarios(port, lambda *x: lines.append(" ".join(repr(v) for v in x)), send)
    except Exception as e:
        lines.append("EXCEPTION %r" % (e,))
    # the lines are logged as the sockets are shut down: give the server a
    # moment, then stop it
    time.sleep(0.3)
    p.terminate()
    p.wait()
    return lines, closed_lines(lg)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True)
    ap.add_argument("--bendkv", type=int, required=True)
    ap.add_argument("--redis", type=int, required=True)
    ap.add_argument("--dir", required=True)
    args = ap.parse_args()
    shutil.rmtree(args.dir, ignore_errors=True)
    runs = {}
    for name, io, send in (("redis", None, False), ("post", "2", False), ("send", "1", True)):
        d = os.path.join(args.dir, name)
        os.makedirs(d)
        if io is None:
            argv = ["redis-server", "--port", str(args.redis), "--bind", "127.0.0.1", "--dir", d, "--save", "",
                    "--requirepass", "pw"]
            port = args.redis
        else:
            argv = [args.bin, "--port", str(args.bendkv), "--dir", d, "--save", "", "--requirepass", "pw",
                    "--io-threads", io]
            port = args.bendkv
        runs[name] = run(argv, port, os.path.join(args.dir, name + ".log"), send)
    bad = 0
    want, rl = runs["redis"]
    for name in ("post", "send"):
        got, bl = runs[name]
        for i in range(max(len(got), len(want))):
            x = got[i] if i < len(got) else "<none>"
            y = want[i] if i < len(want) else "<none>"
            if name == "send" and x.startswith("'7 flood") and y.startswith("'7 flood"):
                # the client stalls its own connection, open, and another
                # client is served meanwhile; or a read's replies closed it
                stalled = x == "'7 flood, sent from the loop' 'stalled' (1, 7, 'open')"
                ok = stalled or x == "'7 flood, sent from the loop' 'closed' (1, 7, 'open')"
                print("%s  %s: %s" % ("ok  " if ok else "FAIL", name, x))
                bad += 0 if ok else 1
                continue
            if x != y:
                bad += 1
                print("FAIL: BendKV (%s) %s\n      Redis  %s" % (name, x, y))
        # Redis's lines, but the stalled flood's with replies sent from
        # the loop
        exp = rl[:-1] if name == "send" and "'7 flood, sent from the loop' 'stalled' (1, 7, 'open')" in got else rl
        if bl != exp:
            bad += 1
            print("FAIL: the lines BendKV (%s) logged\n  BendKV: %r\n  Redis:  %r" % (name, bl, exp))
        else:
            print("ok    %s: %d lines logged, as Redis logs them" % (name, len(bl)))
    if len(rl) != 4:
        bad += 1
        print("FAIL: Redis logged %d lines, not 4: %r" % (len(rl), rl))
    if bad:
        for l in STALLS:
            print("  stalled: %s" % l)
        print("FAIL: %d differences" % bad)
        sys.exit(1)
    print("OK: %d lines of scenarios, with replies posted and sent, as Redis answers them" % len(want))


if __name__ == "__main__":
    main()
