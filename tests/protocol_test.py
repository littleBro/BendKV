#!/usr/bin/env python3
"""Protocol edge cases, BendKV against Redis byte for byte: each case sends
raw bytes on a fresh connection to both servers and compares what comes
back before the server goes quiet, and whether it closed the connection.
The cases follow Redis's own tests/unit/protocol.tcl: empty and negative
multibulk counts, bad lengths, inline requests with quotes and escapes,
unbalanced quotes, an inline request over 64 KB, unknown commands.

    python3 tests/protocol_test.py --bendkv 6380 --redis 6390
"""
import argparse
import socket
import time


def resp(*args):
    out = b"*%d\r\n" % len(args)
    for a in args:
        out += b"$%d\r\n%s\r\n" % (len(a), a)
    return out


CASES = [
    ("empty inline line", b"\r\nPING\r\n"),
    ("bare LF ends an inline line", b"PING\nPING\r\n"),
    ("negative multibulk count", b"*-10\r\nPING\r\n"),
    ("zero multibulk count", b"*0\r\nPING\r\n"),
    ("multibulk count out of range", b"*3000000000\r\n"),
    ("wrong multibulk payload header", b"*3\r\n$3\r\nSET\r\n$1\r\nx\r\nfooz\r\n"),
    ("negative bulk length", b"*3\r\n$3\r\nSET\r\n$1\r\nx\r\n$-10\r\n"),
    ("bulk length out of range", b"*3\r\n$3\r\nSET\r\n$1\r\nx\r\n$2000000000\r\n"),
    ("bulk length not a number", b"*3\r\n$3\r\nSET\r\n$1\r\nx\r\n$blabla\r\n"),
    ("multibulk without bulks", b"*1\r\nfoo\r\n"),
    ("unbalanced quotes", b'set """test-key""" test-value\r\nping\r\n'),
    ("open double quote", b'set "abc def\r\n'),
    ("open single quote", b"set 'abc def\r\n"),
    ("quotes and escapes", b'set "a b" "c\\x41d\\n\\t\\"e"\r\nget "a b"\r\n'),
    ("single quotes", b"set 'x\\'y' 'p\\nq'\r\nget 'x\\'y'\r\n"),
    ("quote inside a word", b'set ab"c d"e x\r\nset ab"c d" x\r\nget "abc d"\r\n'),
    ("bad hex escape", b'set k "\\xZZ\\x4"\r\nget k\r\n'),
    ("tabs and runs of blanks", b"set \t  k2 \t v2  \r\nget k2\r\n"),
    ("unknown command", b"NOPE 1 2\r\n"),
    ("unknown command, long args", b"nope " + b"x" * 100 + b" " + b"y" * 100 + b" z\r\n"),
    ("unknown command, newline in an argument", resp(b"Nope", b"a\r\nb", b"c")),
    ("wrong arity", b"ping x y z\r\n"),
    ("inline request over 64 KB", b"A" * 70000),
    ("NUL before the newline waits", b"\x00" + b"payload" * 10000 + b"\r\n"),
]


def exchange(port, data, quiet=0.3, limit=5.0):
    """What the server sends back before it goes quiet, and whether it
    closed the connection."""
    s = socket.create_connection(("127.0.0.1", port), timeout=limit)
    try:
        s.sendall(data)
    except OSError:
        pass
    s.settimeout(quiet)
    got = b""
    closed = False
    end = time.time() + limit
    while time.time() < end:
        try:
            chunk = s.recv(1 << 16)
        except socket.timeout:
            break
        except OSError:
            closed = True
            break
        if not chunk:
            closed = True
            break
        got += chunk
    s.close()
    return got, closed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, default=6380)
    ap.add_argument("--redis", type=int, default=6390)
    a = ap.parse_args()
    ok = True
    for name, data in CASES:
        for port in (a.bendkv, a.redis):
            exchange(port, resp(b"FLUSHALL"))
        mine = exchange(a.bendkv, data)
        theirs = exchange(a.redis, data)
        same = mine == theirs
        ok &= same
        print("%s %s" % ("ok  " if same else "FAIL", name))
        if not same:
            print("     bendkv: %r" % (mine,))
            print("     redis:  %r" % (theirs,))
    print("ALL OK" if ok else "SOME CHECKS FAILED")
    return ok


if __name__ == "__main__":
    raise SystemExit(0 if main() else 1)
