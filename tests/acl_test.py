#!/usr/bin/env python3
"""ACL against Redis: users, what they may run, and the ACL LOG, as
scenarios on BendKV and on Redis with clients of their own, their
transcripts compared line by line.

Redis 7.0.15 checks a call against its client's user (processCommand)
after NOAUTH and after refusing a command MULTI may not queue, and
before the rest: a call refused answers NOPERM with the reason (the
command, a key, a channel), counts as a refused call and an error, and
goes to the ACL LOG with its context (toplevel, multi), its object, the
user and the client's CLIENT LIST line; in MULTI it flags the
transaction, and EXEC refused aborts it. EXEC checks each command again
as it runs it, in case the rules changed since it was queued. AUTH and
HELLO's AUTH log a client in as a user, and one that fails goes to the
log; RESET logs it out to the default user. ACL SETUSER that takes a
channel away closes the user's clients subscribed to one; ACL DELUSER
closes the clients of the users it removes, the client itself after its
reply. CLIENT LIST shows each client's user, CLIENT KILL picks them by
user, and ACL WHOAMI answers the client's own.

The scenarios: a user's calls allowed and refused, one at a time and
pipelined behind its AUTH; the log (grouping, its length, RESET); the
counts of INFO; MULTI with a call refused, and EXEC with one refused
since it was queued; HELLO's AUTH; RESET; a blocking command refused;
SUBSCRIBE and PUBLISH refused, and subscribers closed by SETUSER;
DELUSER of another client's user and of the client's own; CLIENT KILL
USER and its errors; CLIENT LIST's user; the default user restricted,
whose plain batches are checked too; and the slow log's SETUSER. Then
a check of BendKV alone: AUTH and HELLO's AUTH with a password of 1 MB
answer within a second (a SHA-256 linear in the password's length; one
that was not took a minute).

    python3 tests/acl_test.py --bendkv 6380 --redis 6390
"""
import argparse
import re
import sys
import time

from blocking_test import Client, enc

# the fields of a client's line that differ from one server to the other,
# or from one run to the next
VOLATILE = ("id", "addr", "laddr", "fd", "age", "idle", "qbuf", "qbuf-free", "argv-mem", "multi-mem",
            "rbs", "rbp", "obl", "oll", "omem", "tot-mem", "events")


def line(s):
    """A CLIENT LIST line without its volatile fields."""
    return " ".join(f for f in s.split() if f.split("=", 1)[0] not in VOLATILE)


def entry(e):
    """An ACL LOG entry as a sorted list of its fields, its age dropped and
    its client's line without the volatile fields."""
    out = []
    for i in range(0, len(e), 2):
        k, v = e[i], e[i + 1]
        if k == "age-seconds":
            continue
        out.append((k, line(v) if k == "client-info" else v))
    return out


def log_of(r, *args):
    x = r.cmd("ACL", "LOG", *args)
    return [entry(e) for e in x] if isinstance(x, list) else x


def counts(r):
    """INFO's commandstats and errorstats, without the times."""
    lines = r.cmd("INFO", "commandstats").splitlines() + r.cmd("INFO", "errorstats").splitlines()
    return sorted(",".join(p for p in l.split(",") if not p.startswith(("usec=", "usec_per_call=")))
                  for l in lines if l.startswith(("cmdstat_", "errorstat_")))


def closed(c, timeout=2.0):
    """Whether the server closed c's connection (what it sent before kept)."""
    end = time.time() + timeout
    while time.time() < end:
        try:
            if not c._fill(0.1):
                continue
        except (EOFError, ConnectionError):
            return True
    return False


def reads(c, n, timeout=1.0):
    """n replies, or EOF for each that the closed connection did not send."""
    out = []
    for _ in range(n):
        try:
            out.append(c.read(timeout))
        except (EOFError, ConnectionError):
            out.append("EOF")
    return out


def users(r, *names):
    for n in names:
        r.cmd("ACL", "DELUSER", n)


def scenarios(port, log):
    r = Client(port)
    r.cmd("ACL", "SETUSER", "default", "reset", "on", "nopass", "~*", "&*", "+@all")
    users(r, "alice", "bob", "carol", "dave", "erin", "fred")
    r.cmd("FLUSHALL")
    r.cmd("CONFIG", "SET", "acllog-max-len", "128")
    r.cmd("ACL", "LOG", "RESET")
    r.cmd("CONFIG", "RESETSTAT")
    log("0 setuser", r.cmd("ACL", "SETUSER", "alice", "on", ">pa", "~k*", "&ch*", "+get", "+set", "+multi",
                           "+exec", "+discard", "+blpop", "+subscribe", "+publish", "+client|info", "+acl|whoami"))
    r.cmd("SET", "k1", "v1")
    r.cmd("SET", "other", "x")
    # 1. a user's calls, allowed and refused
    a = Client(port, db=None)
    log("1 auth", a.cmd("AUTH", "alice", "pa"), a.cmd("ACL", "WHOAMI"))
    log("1 calls", a.cmd("GET", "k1"), a.cmd("GET", "other"), a.cmd("INCR", "k1"), a.cmd("SET", "k2", "v"),
        a.cmd("PUBLISH", "nope", "m"), a.cmd("PUBLISH", "ch1", "m"), a.cmd("SELECT", "1"),
        a.cmd("ACL", "WHOAMI"), a.cmd("PING"))
    log("1 info", line(a.cmd("CLIENT", "INFO")))
    # 2. pipelined behind AUTH: the user's rules hold from the next call on
    b = Client(port, db=None)
    b.raw(b"".join(enc(c) for c in [["GET", "other"], ["AUTH", "alice", "pa"], ["GET", "other"],
                                    ["GET", "k1"], ["INCR", "k1"], ["AUTH", "default", "x"], ["GET", "other"]]))
    log("2 pipelined", [b.read() for _ in range(7)])
    # 3. the log: grouped, newest first
    log("3 log", log_of(r))
    log("3 count", log_of(r, "2"), log_of(r, "0"), log_of(r, "-1"), r.cmd("ACL", "LOG", "x"))
    # 4. AUTH that fails, with a user and without
    log("4 bad auth", a.cmd("AUTH", "alice", "bad"), a.cmd("auth", "nouser", "x"), a.cmd("ACL", "WHOAMI"),
        log_of(r, "2"))
    # 5. the counts
    log("5 counts", counts(r))
    r.cmd("ACL", "LOG", "RESET")
    # 6. MULTI with a call refused, and EXEC with one refused since it was
    # queued (SETUSER from another client in between)
    log("6 multi", a.cmd("MULTI"), a.cmd("INCR", "k1"), a.cmd("SET", "k1", "a"), a.cmd("EXEC"), a.cmd("GET", "k1"))
    log("6 exec", a.cmd("MULTI"), a.cmd("GET", "k1"), a.cmd("SET", "k1", "b"), a.cmd("GET", "k1"),
        r.cmd("ACL", "SETUSER", "alice", "-set"), a.cmd("EXEC"), r.cmd("GET", "k1"))
    log("6 exec info", line(a.cmd("CLIENT", "INFO")))
    log("6 log", log_of(r))
    log("6 counts", counts(r))
    r.cmd("ACL", "SETUSER", "alice", "+set")
    r.cmd("ACL", "LOG", "RESET")
    # 7. EXEC itself refused aborts the transaction
    r.cmd("ACL", "SETUSER", "bob", "on", ">pb", "~*", "+@all", "-exec")
    c = Client(port, db=None)
    log("7 exec refused", c.cmd("AUTH", "bob", "pb"), c.cmd("MULTI"), c.cmd("SET", "k3", "x"), c.cmd("EXEC"),
        c.cmd("GET", "k3"), c.cmd("EXEC"), c.cmd("DISCARD"))
    log("7 log", log_of(r))
    r.cmd("ACL", "LOG", "RESET")
    # 8. HELLO's AUTH, and RESET back to the default user
    d = Client(port, db=None)
    h = d.cmd("HELLO", "2", "AUTH", "alice", "pa")
    log("8 hello", isinstance(h, list), d.cmd("ACL", "WHOAMI"), d.cmd("GET", "other"))
    log("8 hello bad", d.cmd("HELLO", "2", "AUTH", "alice", "x"), d.cmd("ACL", "WHOAMI"))
    log("8 reset", d.cmd("RESET"), d.cmd("ACL", "WHOAMI"), d.cmd("GET", "other"))
    log("8 log", log_of(r))
    r.cmd("ACL", "LOG", "RESET")
    # 9. a blocking command refused does not wait
    log("9 blpop", a.cmd("BLPOP", "other", "0"), a.cmd("BLPOP", "klist", "0.1"))
    # 10. channels: SUBSCRIBE refused, then a subscriber closed when
    # SETUSER takes its channel away (and one that keeps its channels left)
    s1 = Client(port, db=None)
    s2 = Client(port, db=None)
    log("10 auth", s1.cmd("AUTH", "alice", "pa"), s2.cmd("AUTH", "alice", "pa"))
    log("10 subscribe", s1.cmd("SUBSCRIBE", "nope"), s1.cmd("SUBSCRIBE", "ch1"), s2.cmd("SUBSCRIBE", "ch2x"))
    log("10 setuser", r.cmd("ACL", "SETUSER", "alice", "resetchannels", "&ch2*"))
    log("10 closed", closed(s1), closed(s2, 0.5), r.cmd("PUBLISH", "ch2x", "m"), s2.read())
    log("10 log", log_of(r))
    r.cmd("ACL", "LOG", "RESET")
    s2.close()
    # 11. DELUSER: another client's user, then the client's own
    r.cmd("ACL", "SETUSER", "carol", "on", ">pc", "~*", "+@all")
    e = Client(port, db=None)
    f = Client(port, db=None)
    log("11 auth", e.cmd("AUTH", "carol", "pc"), f.cmd("AUTH", "carol", "pc"))
    log("11 deluser", r.cmd("ACL", "DELUSER", "carol", "nobody"), closed(e), closed(f))
    r.cmd("ACL", "SETUSER", "dave", "on", ">pd", "~*", "+@all")
    g = Client(port, db=None)
    g.raw(b"".join(enc(c) for c in [["AUTH", "dave", "pd"], ["ACL", "DELUSER", "dave"], ["PING"]]))
    log("11 own", reads(g, 3), closed(g))
    # 12. CLIENT LIST's user, and CLIENT KILL by user
    m = Client(port, db=None)
    log("12 list", m.cmd("AUTH", "alice", "pa"),
        sorted(line(x) for x in r.cmd("CLIENT", "LIST").splitlines() if "user=alice" in x))
    log("12 kill errors", r.cmd("CLIENT", "KILL", "USER", "nosuch"), r.cmd("CLIENT", "KILL", "USER", "nosuch", "BAD", "x"),
        r.cmd("CLIENT", "KILL", "BAD", "x", "USER", "nosuch"), r.cmd("CLIENT", "KILL", "USER", "nosuch", "ID"),
        r.cmd("CLIENT", "KILL", "USER", "alice", "USER", "nosuch"), r.cmd("CLIENT", "KILL", "USER", "nosuch", "USER", "alice", "ID", "0"))
    log("12 kill", r.cmd("CLIENT", "KILL", "USER", "alice"), closed(m), closed(a))
    log("12 kill default", r.cmd("CLIENT", "KILL", "USER", "default", "SKIPME", "yes", "ID", "999999"))
    # 13. the default user restricted: plain batches of its clients are
    # checked too, and AUTH as alice in a batch changes its rules
    log("13 setuser", r.cmd("ACL", "SETUSER", "default", "resetkeys", "~k*"))
    n = Client(port, db=None)
    n.raw(b"".join(enc(c) for c in [["GET", "k1"], ["GET", "other"], ["SET", "k5", "x"], ["SET", "o5", "x"]]))
    log("13 batch", [n.read() for _ in range(4)])
    log("13 mget", n.cmd("MGET", "k1", "other"), sorted(n.cmd("KEYS", "*")), n.cmd("DEL", "k5"))
    log("13 restore", r.cmd("ACL", "SETUSER", "default", "~*"), n.cmd("GET", "other"))
    log("13 log", log_of(r))
    r.cmd("ACL", "LOG", "RESET")
    # 14. the log's length, and RESET
    log("14 maxlen", r.cmd("CONFIG", "SET", "acllog-max-len", "2"))
    o = Client(port, db=None)
    o.cmd("AUTH", "alice", "pa")
    log("14 refused", o.cmd("GET", "a1"), o.cmd("GET", "a2"), o.cmd("GET", "a3"), o.cmd("GET", "a3"))
    log("14 log", log_of(r))
    log("14 reset", r.cmd("ACL", "LOG", "RESET"), log_of(r), r.cmd("CONFIG", "SET", "acllog-max-len", "128"))
    # 15. the slow log keeps SETUSER's arguments redacted
    r.cmd("CONFIG", "SET", "slowlog-log-slower-than", "0")
    r.cmd("SLOWLOG", "RESET")
    r.cmd("ACL", "SETUSER", "alice", "on", ">secret")
    r.cmd("ACL", "WHOAMI")
    slow = r.cmd("SLOWLOG", "GET", "10")
    log("15 slowlog", [x[3] for x in slow if isinstance(x, list) and str(x[3][0]).lower() == "acl"])
    r.cmd("CONFIG", "SET", "slowlog-log-slower-than", "10000")
    # 16. AUTH in a transaction: the commands after it in EXEC are checked
    # against its user
    t = Client(port, db=None)
    log("16 exec auth", t.cmd("MULTI"), t.cmd("AUTH", "alice", "secret"), t.cmd("GET", "other"), t.cmd("GET", "k1"),
        t.cmd("EXEC"), t.cmd("ACL", "WHOAMI"))
    log("16 log", log_of(r, "1"))
    r.cmd("ACL", "LOG", "RESET")
    # 17. a pattern subscriber closed when its pattern is taken away; a
    # client that waits in BLPOP closed when its user is removed
    r.cmd("ACL", "SETUSER", "bob", "reset", "on", ">pb", "~*", "&news.*", "+@all")
    p1 = Client(port, db=None)
    w = Client(port, db=None)
    log("17 auth", p1.cmd("AUTH", "bob", "pb"), w.cmd("AUTH", "bob", "pb"))
    log("17 psubscribe", p1.cmd("PSUBSCRIBE", "news.*"), p1.cmd("PSUBSCRIBE", "other.*"))
    w.send("BLPOP", "q1", "0")
    time.sleep(0.2)
    log("17 setuser", r.cmd("ACL", "SETUSER", "bob", "resetchannels", "&news.a"), closed(p1), closed(w, 0.5))
    log("17 deluser", r.cmd("ACL", "DELUSER", "bob"), closed(w), r.cmd("RPUSH", "q1", "x"), r.cmd("LLEN", "q1"))
    r.cmd("DEL", "q1")
    # 18. SORT's BY with a pattern and its GET, for a user that may not read
    # every key, and for one that may
    r.cmd("ACL", "SETUSER", "erin", "on", ">pe", "~s*", "+@all")
    r.cmd("ACL", "SETUSER", "fred", "on", ">pf", "%R~*", "~s*", "+@all")
    u = Client(port, db=None)
    v = Client(port, db=None)
    log("18 auth", u.cmd("AUTH", "erin", "pe"), v.cmd("AUTH", "fred", "pf"), u.cmd("RPUSH", "slist", "3", "1", "2"))
    log("18 sort", u.cmd("SORT", "slist"), u.cmd("SORT", "slist", "BY", "nosort"), u.cmd("SORT", "slist", "BY", "w_*"),
        u.cmd("SORT", "slist", "GET", "#"), u.cmd("SORT", "slist", "LIMIT", "x", "1", "GET", "#"),
        u.cmd("SORT", "slist", "GET", "#", "LIMIT", "x"), u.cmd("SORT_RO", "slist", "BY", "w_*"),
        u.cmd("SORT", "slist", "BADOPT", "GET", "#"), u.cmd("SORT", "slist", "BY", "w_*", "STORE", "s2"),
        u.cmd("SORT_RO", "slist", "STORE", "s2", "GET", "#"), u.cmd("SORT", "slist", "ALPHA", "DESC", "GET"))
    log("18 multi", u.cmd("MULTI"), u.cmd("SORT", "slist", "GET", "#"), u.cmd("SORT", "slist"), u.cmd("EXEC"))
    log("18 full", v.cmd("SORT", "slist", "BY", "w_*", "GET", "#"), v.cmd("SORT", "slist", "GET", "#", "STORE", "s3"))
    log("18 counts", [x for x in counts(r) if x.startswith(("cmdstat_sort", "errorstat_ERR"))], log_of(r))
    r.cmd("DEL", "slist", "s3")
    users(r, "alice", "bob", "carol", "dave", "erin", "fred")
    r.cmd("ACL", "LOG", "RESET")


def auth_time(port):
    """How long the slowest of AUTH and HELLO's AUTH with a password of
    1 MB took, and their replies."""
    c = Client(port, db=None)
    c.cmd("ACL", "SETUSER", "tbig", "on", ">pw", "+@all", "~*")
    big = "x" * (1 << 20)
    worst = 0.0
    replies = []
    for args in (("AUTH", "tbig", big), ("AUTH", "default", big), ("HELLO", "2", "AUTH", "tbig", big)):
        t = time.time()
        replies.append(c.cmd(*args))
        worst = max(worst, time.time() - t)
    c.cmd("ACL", "DELUSER", "tbig")
    c.close()
    return worst, replies


def cleanup(port):
    """The users and the default user as a fresh server has them, after a
    scenario that failed half way."""
    try:
        c = Client(port, db=None)
        c.cmd("ACL", "SETUSER", "default", "reset", "on", "nopass", "~*", "&*", "+@all")
        users(c, "alice", "bob", "carol", "dave", "erin", "fred")
        c.cmd("CONFIG", "SET", "acllog-max-len", "128")
        c.cmd("CONFIG", "SET", "slowlog-log-slower-than", "10000")
        c.close()
    except Exception:
        pass


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
            cleanup(port)
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
    worst, replies = auth_time(args.bendkv)
    want = ["-WRONGPASS invalid username-password pair or user is disabled.", "+OK",
            "-WRONGPASS invalid username-password pair or user is disabled."]
    if replies != want or worst > 1.0:
        print("FAIL: AUTH of 1 MB took %.3f s (at most 1 s), answering %r" % (worst, replies))
        sys.exit(1)
    print("OK: %d lines of ACL scenarios as Redis answers them, and AUTH of 1 MB in %.3f s" % (len(outs[1]), worst))


if __name__ == "__main__":
    main()
