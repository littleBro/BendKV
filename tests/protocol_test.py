#!/usr/bin/env python3
"""Protocol edge cases, BendKV against Redis byte for byte: each case sends
raw bytes on a fresh connection to both servers and compares what comes
back before the server goes quiet, and whether the server closed the
connection. The cases follow Redis's own tests/unit/protocol.tcl: empty
and negative multibulk counts, bad lengths, inline requests with quotes
and escapes, unbalanced quotes, an inline request over 64 KB, unknown
commands; and processMultibulkBuffer, as Redis 7.0.15 reads a request:
lengths read by string2ll (no 0 before a number's first digit, no -0, a
count from -2^63 up), a count of 0 or less skipped, a line ended by its
'\\r' and whatever byte follows it, no line until its '\\r' comes (a NUL
before it hides it), 64 KB at most without one, a bulk's two bytes after
its data skipped unread; errors on one line, a CR or LF in them sent as
a space, an argument quoted in them up to its first NUL; a protocol
error under CLIENT REPLY OFF or SKIP, which Redis does not answer, nor
close the connection after, nor read on; and a long request in several
reads, cut at each place a bulk can be cut, with requests after it and
protocol errors in it. Then, on BendKV alone, one MSET of 200,000 keys
is timed against a pipeline of as many SETs, each sent at once and then
in pieces.

Whether the server closed a connection is not taken from a quiet
socket: a server that keeps one open shows it in INFO's
connected_clients, asked on a connection of the test's own, and one that
closes it sends an end of file; each case checks that the server lets
the connection go once the client closes it. Every reply BendKV sends
must also parse as RESP, each error a line of its own.

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


def reply_off(mode):
    return resp(b"CLIENT", b"REPLY", mode)


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
    # lengths as string2ll reads them
    ("count with a leading zero", b"*01\r\n$4\r\nPING\r\n"),
    ("count of 00", b"*00\r\nPING\r\n"),
    ("count of -0", b"*-0\r\nPING\r\n"),
    ("negative count with a leading zero", b"*-01\r\nPING\r\n"),
    ("negative count of eleven digits is skipped", b"*-10000000000\r\nPING\r\n"),
    ("count of -2^63 is skipped", b"*-9223372036854775808\r\nPING\r\n"),
    ("count below -2^63", b"*-9223372036854775809\r\nPING\r\n"),
    ("count of a lone minus", b"*-\r\nPING\r\n"),
    ("count with a plus", b"*+1\r\n$4\r\nPING\r\n"),
    ("count of INT_MAX waits", b"*2147483647\r\n"),
    ("count past INT_MAX", b"*2147483648\r\n"),
    ("count of 2^63 - 1", b"*9223372036854775807\r\n"),
    ("bulk length with a leading zero", b"*1\r\n$04\r\nPING\r\n"),
    ("bulk length of 00", b"*2\r\n$4\r\nECHO\r\n$00\r\n\r\n"),
    ("bulk length of 0", b"*2\r\n$4\r\nECHO\r\n$0\r\n\r\n"),
    ("bulk length of -0", b"*1\r\n$-0\r\n"),
    ("bulk length with a plus", b"*1\r\n$+4\r\nPING\r\n"),
    ("bulk length of 512 MB waits", b"*1\r\n$536870912\r\n"),
    ("bulk length past 512 MB", b"*1\r\n$536870913\r\n"),
    ("bulk length of eleven digits", b"*1\r\n$99999999999\r\n"),
    ("GET's key with a leading zero", b"*2\r\n$3\r\nGET\r\n$01\r\nk\r\n"),
    ("SET's value with a leading zero", b"*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$01\r\nv\r\n"),
    # lines as Redis finds them
    ("count line ended by CR and another byte", b"*1\rX$4\r\nPING\r\n"),
    ("bulk length ended by CR and another byte", b"*1\r\n$4\rXPING\r\n"),
    ("count of eleven digits waits for its CR", b"*12345678901"),
    ("bulk length of eleven digits waits for its CR", b"*1\r\n$12345678901"),
    ("NUL in the count line waits", b"*1\x00\r\n$4\r\nPING\r\n"),
    ("NUL in the bulk length waits", b"*1\r\n$4\x00\r\nPING\r\n"),
    ("NUL where a bulk starts waits", b"*1\r\n\x00$4\r\nPING\r\n"),
    ("not a bulk, waits for its line", b"*1\r\nX"),
    ("not a bulk, once its line is there", b"*1\r\nX\r\n"),
    ("count line over 64 KB", b"*" + b"1" * 70000),
    ("count line of 64 KB waits", b"*" + b"1" * 65535),
    ("bulk length line over 64 KB", b"*1\r\n$" + b"1" * 70000),
    ("bulk header over 64 KB", b"*1\r\n" + b"a" * 65537),
    ("bulk header of 64 KB waits", b"*1\r\n" + b"a" * 65536),
    ("NUL in the count line, past 64 KB", b"*1\x00" + b"1" * 70000 + b"\r\n"),
    # the two bytes after a bulk's data
    ("bulk trailer not CRLF", b"*1\r\n$4\r\nPINGxx"),
    ("bulk trailer not CRLF, then a request", b"*1\r\n$4\r\nPINGabPING\r\n"),
    ("bulk trailer CR CR", b"*1\r\n$4\r\nPING\r\r*1\r\n$4\r\nPING\r\n"),
    ("GET's key trailer", b"*2\r\n$3\r\nGET\r\nkxy" + b"*2\r\n$3\r\nGET\r\n$1\r\nk\r\n"),
    ("SET's trailers", b"*3\r\n$3\r\nSET\r\n$1\r\nkxy$1\r\nvzz" + resp(b"GET", b"k")),
    ("INCR's key trailer", b"*2\r\n$4\r\nINCR\r\n$1\r\nnab" + resp(b"GET", b"n")),
    ("a bulk length one short", resp(b"CONFIG", b"SET", b"maxmemory", b"0").replace(b"$9", b"$7")),
    # errors on one line
    ("CR and LF in HELLO's option", resp(b"HELLO", b"2", b"a\r\nb") + resp(b"PING")),
    ("CR and LF around HELLO's option", resp(b"HELLO", b"2", b"\r\nb\r\n") + resp(b"PING")),
    ("NUL in HELLO's option", resp(b"HELLO", b"2", b"a\x00b") + resp(b"PING")),
    ("CR where a bulk starts", b"*1\r\n\r\n"),
    ("LF where a bulk starts", b"*1\r\n\n$4\r\nPING\r\n"),
    ("NUL in an unknown command", resp(b"no\x00pe", b"x\x00y", b"zz")),
    ("NUL in an unknown subcommand", resp(b"CLIENT", b"x\x00y", b"z")),
    ("CR in an unknown subcommand", resp(b"OBJECT", b"a\rb", b"z")),
    ("NUL in a subcommand's syntax error", resp(b"CONFIG", b"x\x00y")),
    ("NUL in CONFIG SET's option", resp(b"CONFIG", b"SET", b"a\x00b", b"1")),
    # a protocol error while replies are held back
    ("protocol error after CLIENT REPLY OFF", reply_off(b"OFF") + b"*x\r\n"),
    ("protocol error after CLIENT REPLY SKIP", reply_off(b"SKIP") + b"*x\r\n"),
    ("protocol error after a skipped reply", reply_off(b"SKIP") + resp(b"PING") + b"*x\r\n"),
    ("protocol error after CLIENT REPLY OFF, in a later read", [reply_off(b"OFF"), b"*1\r\n$-1\r\n"]),
    ("requests after an unanswered protocol error", [reply_off(b"OFF") + b"*1\r\nX\r\n", resp(b"SET", b"after", b"1"),
                                                    reply_off(b"ON") + resp(b"PING")]),
    ("CLIENT REPLY ON, then a protocol error", [reply_off(b"OFF") + reply_off(b"ON"), b"*x\r\n"]),
]


# A long request in several reads (issue #85): the parse of a request
# longer than a run (2,048 bytes) goes on from the bulk the last read
# stopped in, with the arguments it read before. Each case sends its
# pieces with a pause between them, so that the server reads them one at
# a time, and then reads back what the request wrote. A bulk of LONG is
# 19 bytes: "$12\r\n", 12 bytes of data, "\r\n".
def long_req(cmd, key, n):
    return resp(cmd, key, *[b"e" + str(i).zfill(11).encode() for i in range(n)])


# the index of the first bulk of data that starts past index at
def bulk_past(data, at):
    return data.index(b"\r\n$", at) + 2


LONG = long_req(b"RPUSH", b"L", 400)
LONG2 = long_req(b"RPUSH", b"M", 300)
B0, B1, B2 = bulk_past(LONG, 2100), bulk_past(LONG, 5000), bulk_past(LONG2, 2500)
READ, READ2 = resp(b"LRANGE", b"L", b"0", b"-1"), resp(b"LRANGE", b"M", b"0", b"-1")
NOPE = long_req(b"NOPE", b"x", 300)
PAIRS = [b"key:%04d" % (i // 2) if i % 2 == 0 else b"value-%07d" % i for i in range(400)]
MSET, ODD = resp(b"MSET", *PAIRS), resp(b"MSET", *PAIRS[:399])
VALUE = resp(b"SET", b"k", b"v" * 5000)
CASES += [("long request split %s" % what, [LONG[:B0 + d], LONG[B0 + d:] + READ]) for what, d in [
    ("at a bulk's $", 0),
    ("after a bulk's $", 1),
    ("inside a bulk's length", 2),
    ("at a bulk length's CR", 3),
    ("at a bulk length's LF", 4),
    ("at a bulk's data", 5),
    ("inside a bulk's data", 10),
    ("at the CR after a bulk's data", 17),
    ("at the LF after a bulk's data", 18),
]] + [
    ("long request in its last bulk", [LONG[:-5], LONG[-5:] + READ]),
    ("long request in three pieces", [LONG[:B0 + 7], LONG[B0 + 7:B1 + 3], LONG[B1 + 3:] + READ]),
    ("long request, first piece within a run", [LONG[:1500], LONG[1500:B0 + 7], LONG[B0 + 7:] + READ]),
    ("requests after a long request split", [LONG[:B0 + 7], LONG[B0 + 7:] + resp(b"SET", b"after", b"1") + b"PING\r\n" + READ]),
    ("two long requests split", [LONG[:B0 + 7], LONG[B0 + 7:] + LONG2[:B2 + 9], LONG2[B2 + 9:] + READ + READ2]),
    ("long request split, then not a bulk", [LONG[:B0], b"x\r\n" + resp(b"SET", b"after", b"1")]),
    ("long request split, then a bad bulk length", [LONG[:B0], b"$abc\r\n" + resp(b"SET", b"after", b"1")]),
    ("long request split, then a bulk past 512 MB", [LONG[:B0], b"$536870913\r\n" + resp(b"SET", b"after", b"1")]),
    ("long request split, its bulk's trailer not CRLF", [LONG[:B0 + 17], b"xy" + LONG[B0 + 19:] + READ]),
    ("unknown command, long, split", [NOPE[:bulk_past(NOPE, 2100) + 7], NOPE[bulk_past(NOPE, 2100) + 7:] + b"PING\r\n"]),
    ("MSET split", [MSET[:bulk_past(MSET, 2100) + 3], MSET[bulk_past(MSET, 2100) + 3:] +
                    resp(b"MGET", b"key:0000", b"key:0105", b"key:0199", b"key:0200")]),
    ("MSET of an odd count, split", [ODD[:bulk_past(ODD, 2100) + 3], ODD[bulk_past(ODD, 2100) + 3:] + b"PING\r\n"]),
    ("SET of a long value, split", [VALUE[:3000], VALUE[3000:] + resp(b"STRLEN", b"k")]),
]


class Ctl:
    """A connection of the test's own: FLUSHALL, and the count of the
    server's connections."""

    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=10)

    # one reply: a line, or a bulk string whole
    def ask(self, data):
        self.s.sendall(data)
        got = b""
        while True:
            if b"\r\n" in got:
                head = got[:got.index(b"\r\n")]
                if not head.startswith(b"$") or int(head[1:]) < 0:
                    return got
                if len(got) >= len(head) + 2 + int(head[1:]) + 2:
                    return got
            chunk = self.s.recv(1 << 16)
            if not chunk:
                raise ConnectionError("control connection closed")
            got += chunk

    def clients(self):
        for line in self.ask(resp(b"INFO", b"clients")).split(b"\r\n"):
            if line.startswith(b"connected_clients:"):
                return int(line.split(b":")[1])
        raise ValueError("no connected_clients")

    # the count back to this connection alone, once the server has let
    # go of the case's
    def settle(self, limit=5.0):
        end = time.time() + limit
        while time.time() < end:
            if self.clients() == 1:
                return True
            time.sleep(0.02)
        return False


def exchange(port, data, quiet=0.3, limit=5.0):
    """What the server sends back before it goes quiet, and whether it
    closed the connection (session_test.py compares its cases this
    way)."""
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


def observe(port, ctl, data, quiet=0.3, limit=5.0):
    """What the server sends back before it goes quiet; whether it closed
    the connection (an end of file seen) or holds it open (counted in
    connected_clients); and whether it let it go once the client closed
    it."""
    s = socket.create_connection(("127.0.0.1", port), timeout=limit)
    chunks = data if isinstance(data, list) else [data]
    got = b""
    closed = False
    for i, chunk in enumerate(chunks):
        try:
            s.sendall(chunk)
        except OSError:
            closed = True
            break
        s.settimeout(quiet)
        end = time.time() + limit
        while time.time() < end:
            try:
                part = s.recv(1 << 16)
            except socket.timeout:
                break
            except OSError:
                closed = True
                break
            if not part:
                closed = True
                break
            got += part
        if closed:
            break
    state = "closed" if closed else ("open" if ctl.clients() == 2 else "not counted, no end of file")
    s.close()
    return got, state, ctl.settle()


# the replies of a byte string, if it is whole RESP: each error a line
def parses(data):
    def one(i):
        j = data.index(b"\r\n", i)
        kind, line = data[i:i + 1], data[i + 1:j]
        if kind in (b"+", b"-"):
            if b"\r" in line or b"\n" in line:
                raise ValueError("a CR or LF in a line")
            return j + 2
        if kind == b":":
            int(line)
            return j + 2
        if kind == b"$":
            n = int(line)
            if n < 0:
                return j + 2
            if data[j + 2 + n:j + 4 + n] != b"\r\n":
                raise ValueError("a bulk without its CRLF")
            return j + 4 + n
        if kind == b"*":
            n, k = int(line), j + 2
            for _ in range(max(n, 0)):
                k = one(k)
            return k
        raise ValueError("no reply starts with %r" % kind)

    i = 0
    try:
        while i < len(data):
            i = one(i)
    except (ValueError, IndexError) as e:
        return str(e)
    return None


def timed(port, data, replies, piece=None):
    """Seconds from sending data at once, or in pieces of piece bytes a
    millisecond apart, to its replies' end (each reply here is one line:
    its LF is counted, which a read never splits)."""
    s = socket.create_connection(("127.0.0.1", port), timeout=60)
    t0 = time.time()
    if piece is None:
        s.sendall(data)
    else:
        for i in range(0, len(data), piece):
            s.sendall(data[i:i + piece])
            time.sleep(0.001)
    got = 0
    while got < replies:
        chunk = s.recv(1 << 20)
        if not chunk:
            break
        got += chunk.count(b"\n")
    s.close()
    return time.time() - t0


def long_time(port, ctl, n=200000):
    """BendKV alone: one MSET of n keys, sent at once, takes about as long
    as a pipeline of n SETs of the same keys (Redis: 0.13 s and 0.10 s
    for 200,000 here). Parsed again from its start after each read of 64
    KB, the MSET took time in proportion to the square of its size: 4.9
    s, against 0.13 s for the SETs (issue #85). Then both again, sent in
    pieces of 60 KB a millisecond apart, which BendKV reads as a String
    of many runs: the query buffer's walk of the MSET's elements, each
    read by index from the String's start, took 15 s (issue #146). Each
    is timed twice, the better time kept."""
    keys = [b"key:%d" % i for i in range(n)]
    mset = b"*%d\r\n$4\r\nMSET\r\n" % (1 + 2 * n) + b"".join(b"$%d\r\n%s\r\n$1\r\nv\r\n" % (len(k), k) for k in keys)
    sets = b"".join(resp(b"SET", k, b"v") for k in keys)
    ok = True
    for piece, how in ((None, "at once"), (61440, "in pieces of 60 KB")):
        best = []
        for data, replies in ((mset, 1), (sets, n)):
            t = []
            for _ in range(2):
                ctl.ask(resp(b"FLUSHALL"))
                t.append(timed(port, data, replies, piece))
            best.append(min(t))
        ctl.ask(resp(b"FLUSHALL"))
        good = best[0] <= 5 * best[1] + 0.5
        print("%s one MSET of %d keys %s: %.2f s, a pipeline of as many SETs: %.2f s" %
              ("ok  " if good else "FAIL", n, how, best[0], best[1]))
        ok &= good
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, default=6380)
    ap.add_argument("--redis", type=int, default=6390)
    a = ap.parse_args()
    ok = True
    ctls = {a.bendkv: Ctl(a.bendkv), a.redis: Ctl(a.redis)}
    for name, data in CASES:
        got = []
        for port in (a.bendkv, a.redis):
            ctl = ctls[port]
            ctl.ask(resp(b"FLUSHALL"))
            ctl.settle()
            # what came back, the connection's state, and whether the
            # requests after an error ran (the key they would set)
            got.append(observe(port, ctl, data) + (ctl.ask(resp(b"EXISTS", b"after")),))
        mine, theirs = got
        bad = parses(mine[0])
        same = mine == theirs and bad is None
        ok &= same
        print("%s %s" % ("ok  " if same else "FAIL", name))
        if not same:
            print("     bendkv: %r" % (mine,))
            print("     redis:  %r" % (theirs,))
            if bad:
                print("     BendKV's reply is not RESP: %s" % bad)
    ok &= long_time(a.bendkv, ctls[a.bendkv])
    print("ALL OK" if ok else "SOME CHECKS FAILED")
    return ok


if __name__ == "__main__":
    raise SystemExit(0 if main() else 1)
