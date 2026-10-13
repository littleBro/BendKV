#!/usr/bin/env python3
"""AUTH against Redis: when a client must authenticate, and what it is
answered before it does, as scenarios on BendKV and on Redis with clients
of their own, their transcripts compared line by line.

Redis 7.0.15 asks a client for AUTH (processCommand) after it looked the
command up and checked its number of arguments, and before the command
runs: an unknown command, an unknown subcommand and a number of
arguments the command's table does not allow are answered as they are,
whoever the client is; an error the command finds as it runs (a syntax
error, a value that is not an integer, a number of arguments the table
allows and the command does not) is NOAUTH for a client that must
authenticate. A client is authenticated as it connects when there is no
password then (createClient), at RESET when there is none then, and by
AUTH and HELLO's AUTH; nothing else changes it: a password set later
asks nothing of it, and a password removed and set again asks again a
client that never authenticated, whatever it ran in between.

The scenarios: a client that came before the password; the commands of
each kind of error from a client that must authenticate, one at a time
and pipelined, then once it has; a failed AUTH; HELLO without AUTH;
RESET with a password and without; a password removed and set again; a
pipeline that sets the password and goes on; a transaction with errors
of each kind; a subscribed client's errors; and the counts of INFO.

    python3 tests/auth_test.py --bendkv 6380 --redis 6390
"""
import argparse
import sys

from blocking_test import Client, enc

# an error of each kind, in the order Redis finds them, and commands that
# run: refused before AUTH (an unknown command or subcommand, a number of
# arguments the table refuses), the command's own (the rest), and the
# commands a client may send before it authenticates (HELLO, AUTH)
ERRS = [
    ["SET", "k", "v", "EX", "abc"],
    ["SET", "k", "v", "XX", "NX"],
    ["SET", "k"],
    ["NOSUCH", "x"],
    ["CLIENT", "NOSUCH"],
    ["CLIENT"],
    ["CONFIG", "GET"],
    ["CONFIG", "NOSUCH"],
    ["OBJECT", "NOSUCH", "k"],
    ["INCRBY", "k", "x"],
    ["EXPIRE", "k", "10", "XX", "NX"],
    ["GETEX", "k", "PX", "-1"],
    ["ZADD", "z", "x", "m"],
    ["LPOS", "l", "x", "RANK", "0"],
    ["HELLO", "x"],
    ["HELLO", "2", "AUTH", "default"],
    ["AUTH"],
    ["SELECT", "x"],
    ["CLIENT", "REPLY", "BAD"],
    ["CLIENT", "SETNAME", "a b"],
    ["PING", "a", "b"],
    ["MONITOR", "x"],
    ["SCAN", "x"],
    ["BITFIELD", "k", "GET", "x", "0"],
    ["PUBSUB", "CHANNELS", "a", "b"],
    ["GET", "k"],
    ["PING"],
]


def kind(x):
    """HELLO's reply as whether it is one (its id and version put aside)."""
    return "HELLO" if isinstance(x, list) else x


def counts(r):
    """INFO's commandstats and errorstats, without the times."""
    lines = r.cmd("INFO", "commandstats").splitlines() + r.cmd("INFO", "errorstats").splitlines()
    return sorted(",".join(p for p in l.split(",") if not p.startswith(("usec=", "usec_per_call=")))
                  for l in lines if l.startswith(("cmdstat_", "errorstat_")))


def scenarios(port, log):
    r = Client(port)
    r.cmd("CONFIG", "SET", "requirepass", "")
    r.cmd("FLUSHALL")
    r.cmd("CONFIG", "RESETSTAT")
    a = Client(port)
    log("0 set", r.cmd("CONFIG", "SET", "requirepass", "pw"))
    # 1. a client that came with no password stays authenticated, and so
    # does the one that set it
    log("1 came before", a.cmd("SET", "k", "v"), a.cmd("GET", "k"), r.cmd("GET", "k"))
    # 2. a client that comes now must authenticate
    n = Client(port, db=None)
    for c in ERRS:
        log("2 noauth", c, kind(n.cmd(*c)))
    # 3. the same, pipelined
    n.raw(b"".join(enc(c) for c in ERRS))
    log("3 pipelined", [kind(n.read()) for _ in ERRS])
    # 4. once it has
    log("4 auth", n.cmd("AUTH", "bad"), n.cmd("GET", "k"), n.cmd("AUTH", "pw"), n.cmd("SELECT", "9"))
    for c in ERRS:
        log("4 authed", c, kind(n.cmd(*c)))
    # 5. a failed AUTH leaves a client authenticated
    log("5 bad auth", n.cmd("AUTH", "bad"), n.cmd("GET", "k"), a.cmd("AUTH", "bad"), a.cmd("GET", "k"),
        a.cmd("AUTH", "default", "bad"), a.cmd("GET", "k"))
    # 6. HELLO without AUTH leaves a client as it was
    m = Client(port, db=None)
    log("6 hello", kind(m.cmd("HELLO", "2")), m.cmd("GET", "k"), kind(m.cmd("HELLO", "2", "SETNAME", "x")),
        m.cmd("GET", "k"), kind(a.cmd("HELLO", "2")), a.cmd("GET", "k"))
    log("6 hello auth", kind(m.cmd("HELLO", "2", "AUTH", "default", "pw")), m.cmd("SELECT", "9"), m.cmd("GET", "k"))
    # 7. RESET with a password: the client must authenticate again
    log("7 reset", a.cmd("RESET"), a.cmd("GET", "k"), a.cmd("PING"), a.cmd("AUTH", "pw"), a.cmd("SELECT", "9"),
        a.cmd("GET", "k"))
    # 8. a password removed, then set again, asks again a client that
    # never authenticated, whatever it ran in between
    u = Client(port, db=None)
    log("8 before", u.cmd("GET", "k"))
    log("8 nopass", r.cmd("CONFIG", "SET", "requirepass", ""), u.cmd("SELECT", "9"), u.cmd("GET", "k"),
        u.cmd("SET", "k2", "v2"), u.cmd("INCRBY", "k3", "x"))
    w = Client(port)
    log("8 again", r.cmd("CONFIG", "SET", "requirepass", "pw"), u.cmd("GET", "k"), u.cmd("SET", "k", "x"),
        w.cmd("GET", "k"), u.cmd("AUTH", "pw"), u.cmd("GET", "k"))
    # 9. RESET with no password authenticates a client
    x = Client(port, db=None)
    log("9 reset nopass", x.cmd("GET", "k"), r.cmd("CONFIG", "SET", "requirepass", ""), x.cmd("RESET"),
        r.cmd("CONFIG", "SET", "requirepass", "pw"), x.cmd("SELECT", "9"), x.cmd("GET", "k"))
    # 10. a pipeline that sets a password and goes on, and one that removes it
    r.raw(enc(["CONFIG", "SET", "requirepass", "pw2"]) + enc(["GET", "k"]) + enc(["CONFIG", "SET", "requirepass", "pw"]))
    log("10 pipeline", r.read(), r.read(), r.read())
    y = Client(port, db=None)
    y.raw(enc(["GET", "k"]) + enc(["AUTH", "pw"]) + enc(["SELECT", "9"]) + enc(["GET", "k"]) + enc(["RESET"]) +
          enc(["GET", "k"]))
    log("10 pipeline auth", [y.read() for _ in range(6)])
    # 11. a transaction with errors of each kind
    log("11 multi", a.cmd("MULTI"), a.cmd("SET", "k", "v", "EX", "abc"), a.cmd("INCRBY", "k", "x"), a.cmd("PING", "a", "b"),
        a.cmd("GET", "k"), a.cmd("EXEC"))
    log("11 multi abort", a.cmd("MULTI"), a.cmd("SET", "k"), a.cmd("GET", "k"), a.cmd("EXEC"))
    # 12. a subscribed client's errors
    s = Client(port, db=None)
    log("12 sub", s.cmd("AUTH", "pw"), s.cmd("SUBSCRIBE", "ch"), s.cmd("PING", "a", "b"), s.cmd("SET", "k", "v", "EX", "abc"), s.cmd("SET", "k"),
        s.cmd("NOSUCH"), s.cmd("PING"), s.cmd("RESET"), s.cmd("GET", "k"))
    # 13. the counts of INFO
    log("13 counts", counts(r))
    r.cmd("CONFIG", "SET", "requirepass", "")
    for c in (r, a, n, m, u, w, x, y, s):
        c.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, required=True)
    ap.add_argument("--redis", type=int, required=True)
    args = ap.parse_args()
    outs = []
    for port in (args.bendkv, args.redis):
        lines = []
        try:
            scenarios(port, lambda *x: lines.append(" ".join(repr(v) for v in x)))
        except Exception as e:
            lines.append("EXCEPTION %r" % (e,))
            try:
                c = Client(port, db=None)
                c.cmd("AUTH", "pw")
                c.cmd("CONFIG", "SET", "requirepass", "")
                c.close()
            except Exception:
                pass
        outs.append(lines)
    bad = 0
    for i in range(max(len(outs[0]), len(outs[1]))):
        x = outs[0][i] if i < len(outs[0]) else "<none>"
        y = outs[1][i] if i < len(outs[1]) else "<none>"
        if x != y:
            bad += 1
            if bad <= 20:
                print("FAIL: BendKV %s\n      Redis  %s" % (x, y))
    if bad:
        print("FAIL: %d of %d lines of the scenarios differ" % (bad, len(outs[1])))
        sys.exit(1)
    print("OK: %d lines of AUTH scenarios as Redis answers them" % len(outs[1]))


if __name__ == "__main__":
    main()
