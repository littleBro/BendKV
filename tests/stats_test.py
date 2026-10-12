#!/usr/bin/env python3
"""INFO's statistics per command, BendKV against Redis: the same requests
on both, after CONFIG RESETSTAT, then commandstats (each command's and
subcommand's calls, rejected calls and failed calls), errorstats (the
error replies by their first word), total_error_replies and
total_commands_processed the same. Lines are compared as maps: Redis
lists commandstats in the order of a hash table with a random seed, and
BendKV, which does not time its commands, writes usec=0.

The cases: commands one at a time; pipelines of one command (counted by
BendKV without a look at each request) and of several, with errors among
them; a pipeline over 64 KB (counted a request at a time); calls refused
before they run (a wrong number of arguments by the command's arity,
NOAUTH), unknown commands and subcommands (errorstats only), calls that
fail as they run (INCR of a string; PING with two arguments and MSET with
a key and no value, which pass the arity and fail in the command;
SETRANGE past 512MB, BITCOUNT and BITPOS reading their ranges, RENAME of
a key that is not there, LCS's options) or as
they parse (a syntax error, SCAN's invalid cursor, GETRANGE's range, BITOP's
operation); errors with codes
other than ERR (WRONGPASS, NOAUTH); calls while CLIENT REPLY holds
replies back (counted all the same); commands after a QUIT (dropped); a
protocol error (counted, then the connection closes); and random
pipelines mixing all of these. SCAN and RANDOMKEY answer keys of their
own choice: their replies are compared by their kind.

    python3 tests/stats_test.py --bendkv 6380 --redis 6390 [--rounds 200]
"""
import argparse
import random
import socket


class Client:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=10)
        self.buf = b""

    def fill(self):
        chunk = self.s.recv(1 << 16)
        if not chunk:
            raise ConnectionError("closed")
        self.buf += chunk

    def line(self):
        while b"\r\n" not in self.buf:
            self.fill()
        i = self.buf.index(b"\r\n")
        line, self.buf = self.buf[:i], self.buf[i + 2:]
        return line

    # a reply: a status or an error as its line, a bulk string as bytes
    def read(self):
        line = self.line()
        kind = line[:1]
        if kind == b"$":
            n = int(line[1:])
            if n < 0:
                return None
            while len(self.buf) < n + 2:
                self.fill()
            v, self.buf = self.buf[:n], self.buf[n + 2:]
            return v
        if kind == b"*":
            n = int(line[1:])
            return None if n < 0 else [self.read() for _ in range(n)]
        return line

    def send(self, cmds):
        out = b""
        for args in cmds:
            out += b"*%d\r\n" % len(args)
            for a in args:
                a = a if isinstance(a, bytes) else a.encode()
                out += b"$%d\r\n%s\r\n" % (len(a), a)
        self.s.sendall(out)

    # the requests at once, and the replies of those that give one
    def pipe(self, cmds, replies=None):
        self.send(cmds)
        return [self.read() for _ in range(len(cmds) if replies is None else replies)]

    def ask(self, *args):
        return self.pipe([args])[0]

    def close(self):
        self.s.close()


def stats(c):
    """commandstats and errorstats as maps, and the totals"""
    text = c.ask("INFO", "commandstats", "errorstats", "stats").decode()
    cmds, errs, tot = {}, {}, {}
    for line in text.split("\r\n"):
        if line.startswith("cmdstat_"):
            name, rest = line[len("cmdstat_"):].split(":", 1)
            f = dict(kv.split("=") for kv in rest.split(","))
            cmds[name] = (int(f["calls"]), int(f["rejected_calls"]), int(f["failed_calls"]))
        elif line.startswith("errorstat_"):
            name, rest = line[len("errorstat_"):].split(":", 1)
            errs[name] = int(rest.split("=")[1])
        elif line.startswith(("total_error_replies:", "total_commands_processed:")):
            k, v = line.split(":")
            tot[k] = int(v)
    return cmds, errs, tot


ok = True
checks = 0


def check(name, good, why=""):
    global ok, checks
    ok &= good
    checks += 1
    if not good:
        print("FAIL: " + name + "\n      " + why[:3000])


def diff(a, b):
    keys = sorted(set(a) | set(b))
    return "; ".join("%s: bendkv %r, redis %r" % (k, a.get(k), b.get(k)) for k in keys if a.get(k) != b.get(k))


# a case: what it does on a server, given a connection to it and its port
def same(name, b, r, ports, case):
    for c in (b, r):
        c.ask("CONFIG", "RESETSTAT")
    replies = [case(c, port) for c, port in ((b, ports[0]), (r, ports[1]))]
    check(name + ": replies", replies[0] == replies[1], "bendkv %r\n      redis  %r" % tuple(x for x in replies))
    (bc, be, bt), (rc, re_, rt) = stats(b), stats(r)
    check(name + ": commandstats", bc == rc, diff(bc, rc))
    check(name + ": errorstats", be == re_, diff(be, re_))
    check(name + ": totals", bt == rt, diff(bt, rt))


def one_at_a_time(c, port):
    out = []
    for args in (["SET", "k", "v"], ["GET", "k"], ["GET", "nokey"], ["INCR", "n"], ["INCRBY", "n", "5"],
                 ["DECR", "n"], ["DECRBY", "n", "2"], ["APPEND", "k", "w"], ["STRLEN", "k"], ["EXISTS", "k", "x"],
                 ["DEL", "x"], ["UNLINK", "y"], ["MSET", "a", "1", "b", "2"], ["MGET", "a", "b", "c"],
                 ["SETNX", "a", "3"], ["GETSET", "a", "4"], ["TYPE", "a"], ["DBSIZE"], ["KEYS", "*"],
                 ["PING"], ["PING", "x"], ["ECHO", "e"], ["CLIENT", "ID"], ["CLIENT", "SETNAME", "nm"],
                 ["CLIENT", "GETNAME"], ["CONFIG", "GET", "maxmemory"], ["COMMAND", "COUNT"], ["SELECT", "0"],
                 ["SCAN", "0"], ["SCAN", "0", "MATCH", "a*", "COUNT", "5", "TYPE", "string"], ["RANDOMKEY"],
                 ["GETRANGE", "k", "0", "-1"], ["SUBSTR", "k", "1", "2"], ["SETRANGE", "k", "2", "xy"],
                 ["GETBIT", "k", "3"], ["SETBIT", "k", "3", "1"], ["BITCOUNT", "k"], ["BITCOUNT", "k", "0", "-1", "BIT"],
                 ["BITPOS", "k", "1"], ["BITPOS", "k", "0", "1", "-1"], ["TOUCH", "k", "x", "k"], ["TIME"],
                 ["SET", "oe", "12"], ["OBJECT", "ENCODING", "oe"], ["OBJECT", "REFCOUNT", "oe"], ["OBJECT", "HELP"],
                 ["MSETNX", "m1", "1", "m2", "2"], ["MSETNX", "m1", "3"], ["RENAME", "m1", "m3"],
                 ["RENAMENX", "m3", "m2"], ["RENAMENX", "m3", "m4"], ["RENAME", "m4", "m4"],
                 ["COPY", "m4", "m5"], ["COPY", "m4", "m5"], ["COPY", "m4", "m5", "DB", "1", "REPLACE"],
                 ["BITOP", "AND", "m6", "m4", "m5"], ["BITOP", "not", "m6", "nope"], ["LCS", "m4", "m5"],
                 ["LCS", "m4", "m5", "IDX", "WITHMATCHLEN"],
                 ["FLUSHDB"], ["RANDOMKEY"], ["FLUSHALL"]):
        r = c.ask(*args)
        out.append(r if args[0] not in ("CLIENT", "COMMAND", "CONFIG", "DBSIZE", "KEYS", "SCAN", "RANDOMKEY", "TIME")
                   else type(r))
    return out


def errors_at_a_time(c, port):
    out = []
    for args in (["GET"], ["GET", "a", "b"], ["SET", "k"], ["NOSUCH"], ["nosuch", "x", "y"],
                 ["CLIENT", "NOSUCH"], ["CONFIG", "NOSUCH"], ["COMMAND", "NOSUCH"], ["CONFIG"], ["CONFIG", "GET"],
                 ["CLIENT", "SETNAME"], ["SET", "s", "abc"], ["INCR", "s"], ["INCRBY", "s", "1"],
                 ["DECRBY", "n", "x"], ["MSET", "a", "1", "b"], ["PING", "a", "b"],
                 ["SET", "k", "v", "foo"], ["SELECT", "1"], ["SELECT", "x"], ["AUTH", "pw"],
                 ["AUTH", "u", "pw"], ["ECHO"], ["PING", "a", "b"], ["MSET", "a"], ["MGET"], ["DEL"],
                 ["CLIENT", "REPLY", "MAYBE"], ["FUNCTION", "FLUSH", "NOW"], ["HELLO", "4"], ["SCAN"],
                 ["SCAN", "x"], ["SCAN", "0", "COUNT", "0"], ["SCAN", "0", "COUNT", "x"], ["SCAN", "0", "FOO"],
                 ["SCAN", "0", "MATCH"], ["RANDOMKEY", "x"], ["GETRANGE", "s", "x", "1"], ["GETRANGE", "s"],
                 ["SETRANGE", "s", "-1", "a"], ["SETRANGE", "s", "536870912", "a"], ["SETRANGE", "s", "x", "a"],
                 ["GETBIT", "s", "-1"], ["SETBIT", "s", "1", "2"], ["SETBIT", "s", "x", "1"], ["BITCOUNT", "s", "0"],
                 ["BITCOUNT", "s", "x", "1"], ["BITCOUNT", "s", "0", "1", "foo"], ["BITCOUNT", "nokey", "x", "y"],
                 ["BITPOS", "s", "2"], ["BITPOS", "s", "x"], ["BITPOS", "s", "1", "x"], ["BITPOS", "s", "1", "0", "1", "foo"],
                 ["BITPOS", "nokey", "1", "x"], ["BITPOS", "s"], ["TOUCH"], ["TIME", "x"], ["OBJECT"],
                 ["OBJECT", "FOO"], ["OBJECT", "FREQ", "s"], ["OBJECT", "ENCODING"], ["OBJECT", "HELP", "x"],
                 ["MSETNX", "a"], ["MSETNX", "a", "1", "b"], ["RENAME", "nokey", "x"], ["RENAMENX", "nokey", "x"],
                 ["RENAME", "a"], ["RENAMENX", "a", "b", "c"], ["COPY", "a"], ["COPY", "a", "a"],
                 ["COPY", "a", "b", "DB", "x"], ["COPY", "a", "b", "DB", "99"], ["COPY", "a", "b", "FOO"],
                 ["BITOP", "FOO", "a", "b"], ["BITOP", "NOT", "a", "b", "c"], ["BITOP", "AND", "a"],
                 ["LCS", "a"], ["LCS", "a", "b", "FOO"], ["LCS", "a", "b", "LEN", "IDX"],
                 ["LCS", "a", "b", "MINMATCHLEN", "x"]):
        out.append(c.ask(*args))
    return out


def pipelines(c, port):
    out = []
    out += c.pipe([["GET", "p%d" % i] for i in range(16)])
    out += c.pipe([["SET", "p%d" % i, "v"] for i in range(16)])
    out += c.pipe([["INCR", "q%d" % i] for i in range(16)])
    out += c.pipe([["INCR", "p%d" % i] for i in range(16)])          # every one fails
    out += c.pipe([["INCR", "p%d" % (i % 2)] if i % 3 else ["INCR", "q%d" % i] for i in range(16)])
    out += c.pipe([["GET"] for i in range(16)])                       # every one refused
    out += c.pipe([["SET", "k", "v", "foo"] for i in range(16)])      # every one failed as it parsed
    out += c.pipe([["NOSUCH", "%d" % i] for i in range(8)])
    out += c.pipe([["GET", "p1"], ["INCR", "p1"], ["GET"], ["NOSUCH"], ["PING"], ["INCR", "q1"],
                   ["CLIENT", "NOSUCH"], ["MGET", "p1", "p2"], ["DECR", "p2"], ["ECHO", "x"]])
    out += c.pipe([["INCR", "q1"], ["INCR", "q1"], ["GET", "q1"], ["INCR", "p3"]])
    out += c.pipe([["SCAN", "0", "COUNT", "1000", "MATCH", "nomatch*"] for i in range(16)])
    out += c.pipe([["SCAN", "x"] for i in range(16)])                 # every one failed as it parsed
    out += c.pipe([["RANDOMKEY", "x"] for i in range(16)])            # every one refused
    out += c.pipe([["SCAN", "0", "COUNT", "0"], ["RANDOMKEY", "x"], ["SCAN"], ["GET", "p1"],
                   ["SCAN", "0", "COUNT", "1000", "TYPE", "list"]])
    out += [type(x) for x in c.pipe([["RANDOMKEY"] for i in range(16)])]
    return out


def big_pipeline(c, port):
    # a batch of one command over 64 KB: tl does not count it all
    cmds = [["SET", "big%d" % i, "x" * 64] for i in range(1200)] + [["INCR", "big%d" % i] for i in range(3)]
    return c.pipe(cmds)


def held_replies(c, port):
    out = []
    c.ask("SET", "s", "abc")
    out += c.pipe([["CLIENT", "REPLY", "OFF"], ["INCR", "s"], ["GET"], ["NOSUCH"], ["PING"], ["GET", "s"],
                   ["CLIENT", "NOSUCH"], ["CLIENT", "REPLY", "ON"]], 1)
    out += c.pipe([["CLIENT", "REPLY", "SKIP"], ["INCR", "s"], ["INCR", "s"], ["CLIENT", "REPLY", "SKIP"],
                   ["CLIENT", "REPLY", "SKIP"], ["GET"], ["PING"]], 2)
    return out


def noauth(c, port):
    out = [c.ask("CONFIG", "SET", "requirepass", "secret")]
    o = Client(port)
    out += o.pipe([["GET", "k"], ["SET", "k", "v"], ["PING"], ["CLIENT", "ID"], ["NOSUCH"], ["AUTH", "wrong"],
                   ["AUTH", "secret"], ["GET", "k"]])
    o.close()
    out.append(c.ask("CONFIG", "SET", "requirepass", ""))
    return [x if not (isinstance(x, bytes) and x.isdigit()) else "id" for x in out]


def quit_drops(c, port):
    o = Client(port)
    out = o.pipe([["PING"], ["INCR", "s"], ["QUIT"], ["GET", "k"], ["NOSUCH"]], 3)
    o.close()
    return out


def protocol_error(c, port):
    out = []
    for bad in (b"*1\r\n$abc\r\n", b"*x\r\n", b"PING\r\n*1\r\n$-5\r\n"):
        o = Client(port)
        o.s.sendall(bad)
        got = []
        try:
            while True:
                got.append(o.read())
        except (ConnectionError, OSError):
            pass
        o.close()
        out.append(got)
    return out


def random_pipelines(rounds, seed):
    pool = [["GET", "k"], ["SET", "k", "v"], ["INCR", "n"], ["INCR", "k"], ["DECRBY", "n", "x"], ["GET"],
            ["SET", "k"], ["NOSUCH"], ["PING"], ["ECHO", "e"], ["MGET", "k", "n"], ["DEL", "z"],
            ["CLIENT", "NOSUCH"], ["CONFIG", "GET"], ["SET", "k", "v", "foo"], ["APPEND", "k", "x"],
            ["SELECT", "1"], ["EXISTS", "k"], ["STRLEN", "k"], ["SET", "n", "1"], ["TYPE", "k"],
            ["SCAN", "0", "COUNT", "1000", "MATCH", "nomatch"], ["SCAN", "x"], ["SCAN", "0", "COUNT", "0"],
            ["RANDOMKEY"], ["RANDOMKEY", "x"], ["SETRANGE", "k", "1", "z"], ["SETRANGE", "k", "536870912", "z"],
            ["BITCOUNT", "k", "x", "1"], ["BITCOUNT", "k"], ["BITPOS", "k", "1", "0", "-1", "x"], ["GETBIT", "k", "1"],
            ["SETBIT", "n", "0", "1"], ["GETRANGE", "k", "x", "0"], ["MSETNX", "k", "v", "z", "w"],
            ["RENAME", "k", "z"], ["RENAMENX", "z", "k"], ["RENAME", "nokey", "k"], ["COPY", "k", "c"],
            ["COPY", "k", "c", "DB", "2", "REPLACE"], ["COPY", "k", "k"], ["COPY", "k", "c", "DB", "x"],
            ["BITOP", "OR", "z", "k", "c"], ["BITOP", "XOR", "k"], ["LCS", "k", "c", "LEN"], ["LCS", "k", "c", "IDX", "LEN"]]

    def case(c, port):
        rnd = random.Random(seed)
        out = []
        for _ in range(rounds):
            n = rnd.choice([1, 2, 4, 16, 30])
            if rnd.random() < 0.5:
                cmds = [rnd.choice(pool)] * n
            else:
                cmds = [rnd.choice(pool) for _ in range(n)]
            # RANDOMKEY's pick is its own: a key, or nil
            out += [type(x) if cmd == ["RANDOMKEY"] else x for cmd, x in zip(cmds, c.pipe(cmds))]
        return out
    return case


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, default=6380)
    ap.add_argument("--redis", type=int, default=6390)
    ap.add_argument("--rounds", type=int, default=200)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    ports = (a.bendkv, a.redis)
    b, r = Client(a.bendkv), Client(a.redis)
    for c in (b, r):
        c.ask("FLUSHALL")
        c.ask("CONFIG", "SET", "requirepass", "")
    same("one command at a time", b, r, ports, one_at_a_time)
    same("errors one at a time", b, r, ports, errors_at_a_time)
    same("pipelines", b, r, ports, pipelines)
    same("a pipeline over 64 KB", b, r, ports, big_pipeline)
    same("replies held back", b, r, ports, held_replies)
    same("NOAUTH and WRONGPASS", b, r, ports, noauth)
    same("commands after QUIT", b, r, ports, quit_drops)
    same("protocol errors", b, r, ports, protocol_error)
    for seed in (a.seed, a.seed + 1):
        for c in (b, r):
            c.ask("FLUSHALL")
        same("random pipelines (seed %d)" % seed, b, r, ports, random_pipelines(a.rounds, seed))
    b.close()
    r.close()
    print("%d checks; " % checks + ("ALL OK" if ok else "SOME CHECKS FAILED"))
    return ok


if __name__ == "__main__":
    raise SystemExit(0 if main() else 1)
