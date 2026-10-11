#!/usr/bin/env python3
"""COMMAND, BendKV against Redis. BendKV describes the commands it has,
and of a command with subcommands the subcommands it has; Redis describes
all of its own, in the order of a hash table with a random seed. So each
of BendKV's answers is checked against Redis's answer restricted to
BendKV's commands, with commands and subcommands in order of their names:

- COMMAND INFO and COMMAND DOCS of each command and subcommand, alone,
  several at once, with other cases of their names, unknown ones, and
  names Redis cannot look up (get|key, config|get|key, ...); COMMAND,
  COMMAND INFO and COMMAND DOCS of all of them;
- COMMAND LIST: whole, and filtered by every ACL category, by patterns
  and by a module; its syntax errors;
- COMMAND GETKEYS and GETKEYSANDFLAGS of command lines of every command
  with keys (random ones too), of commands without keys, of unknown
  commands and subcommands, with too few or too many arguments;
- the errors of COMMAND itself: an unknown subcommand, the wrong number
  of arguments; COMMAND HELP; COMMAND COUNT, the number of BendKV's
  commands.

Byte for byte, where Redis's order is not the hash table's.

    python3 tests/command_test.py --bendkv 6380 --redis 6390 [--rounds 300]
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

    # a reply, and the bytes it came in; a status is ("+", s) and an error
    # ("-", s), so that neither reads as a bulk string
    def read(self):
        raw = []
        def one():
            line = self.line()
            raw.append(line + b"\r\n")
            kind, rest = line[:1], line[1:]
            if kind == b"+":
                return ("+", rest)
            if kind == b"-":
                return ("-", rest)
            if kind == b":":
                return int(rest)
            if kind == b"$":
                n = int(rest)
                if n < 0:
                    return None
                while len(self.buf) < n + 2:
                    self.fill()
                v, self.buf = self.buf[:n], self.buf[n + 2:]
                raw.append(v + b"\r\n")
                return v
            if kind == b"*":
                n = int(rest)
                return None if n < 0 else [one() for _ in range(n)]
            raise ValueError(line)
        v = one()
        return v, b"".join(raw)

    def ask(self, *args):
        out = b"*%d\r\n" % len(args)
        for a in args:
            a = a if isinstance(a, bytes) else a.encode()
            out += b"$%d\r\n%s\r\n" % (len(a), a)
        self.s.sendall(out)
        return self.read()


def pairs(m):
    return list(zip(m[0::2], m[1::2]))


# Redis's description of a command, with only the subcommands BendKV has,
# by name
def keep_info(info, names):
    if info is None:
        return None
    subs = sorted((s for s in info[9] if s[0] in names), key=lambda s: s[0])
    return info[:9] + [subs]


def keep_docs(docs, names):
    out = []
    for k, v in pairs(docs):
        if k == b"subcommands":
            v = [x for p in sorted((p for p in pairs(v) if p[0] in names), key=lambda p: p[0]) for x in p]
        out += [k, v]
    return out


# documentation of several commands, BendKV's ones only, each with its
# subcommands by name; all of them by name too
def keep_map(m, names, by_name=False):
    ps = [p for p in pairs(m) if p[0] in names]
    return [x for p in (sorted(ps, key=lambda p: p[0]) if by_name else ps)
            for x in (p[0], keep_docs(p[1], names))]


ok = True


def check(name, good, why=""):
    global ok
    ok &= good
    if not good:
        print("FAIL: " + name + "\n      " + why[:3000])
    return good


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, default=6380)
    ap.add_argument("--redis", type=int, default=6390)
    ap.add_argument("--rounds", type=int, default=300)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    rnd = random.Random(a.seed)
    b, r = Client(a.bendkv), Client(a.redis)
    passed = 0

    def same(name, *args, fix=lambda v: v):
        nonlocal passed
        (bv, braw), (rv, rraw) = b.ask(*args), r.ask(*args)
        if fix is None:
            good = braw == rraw
            why = "bendkv %r\n      redis  %r" % (braw[:600], rraw[:600])
        else:
            good = bv == fix(rv)
            why = "bendkv %r\n      redis  %r" % (bv, fix(rv))
        passed += check(name, good, why)

    # BendKV's commands and subcommands
    names, _ = b.ask("COMMAND", "LIST")
    names = set(names)
    tops = sorted(n for n in names if b"|" not in n)
    subs = sorted(n for n in names if b"|" in n)
    rnames, _ = r.ask("COMMAND", "LIST")
    passed += check("BendKV's commands are Redis's", names <= set(rnames), repr(names - set(rnames)))
    count, _ = b.ask("COMMAND", "COUNT")
    passed += check("COMMAND COUNT is the number of commands", count == len(tops), "%r %d" % (count, len(tops)))
    passed += check("COMMAND Count", b.ask("COMMAND", "Count")[0] == count)

    # descriptions and documentation, one at a time, byte for byte where
    # there are no subcommands to order
    for n in tops + subs:
        has_subs = any(s.startswith(n + b"|") for s in subs)
        fix = None if not has_subs else (lambda v: [keep_info(x, names) for x in v])
        same("COMMAND INFO " + n.decode(), "COMMAND", "INFO", n, fix=fix)
        fixd = None if not has_subs else (lambda v: keep_map(v, names))
        same("COMMAND DOCS " + n.decode(), "COMMAND", "DOCS", n, fix=fixd)
    # several at once, other cases, unknown and impossible names
    lists = [[b"get", b"set", b"nosuch"], [b"GET", b"Config|Get", b"CLIENT|ID"],
             [b"get|key"], [b"config|get|key"], [b"config|nosuch"], [b"|get"], [b"config|"],
             [b""], [b"|"], [b"nosuch|get"], [b"ping", b"ping"], [b"config"]]
    for ns in lists:
        same("COMMAND INFO " + b" ".join(ns).decode(), "COMMAND", "INFO", *ns,
             fix=lambda v: [keep_info(x, names) for x in v])
        same("COMMAND DOCS " + b" ".join(ns).decode(), "COMMAND", "DOCS", *ns,
             fix=lambda v: keep_map(v, names))
    # all of them
    for args in (["COMMAND"], ["COMMAND", "INFO"]):
        (bv, _), (rv, _) = b.ask(*args), r.ask(*args)
        want = sorted((keep_info(x, names) for x in rv if x[0] in names), key=lambda x: x[0])
        passed += check(" ".join(args) + " of all commands", bv == want, "%r" % [x[0] for x in bv])
    (bv, _), (rv, _) = b.ask("COMMAND", "DOCS"), r.ask("COMMAND", "DOCS")
    passed += check("COMMAND DOCS of all commands", bv == keep_map(rv, names, True))

    # names: whole, and filtered
    def kept(v):
        return sorted(x for x in v if x in names)

    def in_order():
        out = []
        for t in tops:
            out += [t] + [s for s in subs if s.split(b"|")[0] == t]
        return out

    passed += check("COMMAND LIST is in order of names", b.ask("COMMAND", "LIST")[0] == in_order())
    cats, _ = r.ask("ACL", "CAT")
    for c in cats + [c.upper() for c in cats[:3]] + [b"nosuch", b"", b"@read"]:
        same("COMMAND LIST FILTERBY ACLCAT " + c.decode(), "COMMAND", "LIST", "FILTERBY", "ACLCAT", c,
             fix=kept)
    pats = [b"*", b"set", b"get", b"config*", b"config|*re*", b"cl*help", b"non_exists", b"non_exists*",
            b"*|*", b"C*", b"[cg]et", b"client|?d", b"*\\|*", b"[^a-f]*", b"?????", b"*e*e*", b"",
            b"CLIENT|*", b"*[", b"\\*", b"[a-]*"]
    for p in pats:
        same("COMMAND LIST FILTERBY PATTERN " + p.decode(), "COMMAND", "LIST", "FILTERBY", "PATTERN", p,
             fix=kept)
    same("COMMAND LIST FILTERBY MODULE", "COMMAND", "LIST", "FILTERBY", "MODULE", "nosuch", fix=None)
    same("COMMAND LIST filterby pattern", "COMMAND", "list", "filterby", "pattern", "get", fix=None)
    for args in (["bad_arg"], ["filterby", "bad_arg"], ["filterby", "bad_arg", "bad_arg2"],
                 ["filterby", "pattern"], ["filterby", "pattern", "a", "b"], ["filterby", "pattern", "a", "filterby"],
                 ["x", "filterby", "pattern", "a"]):
        same("COMMAND LIST " + " ".join(args), "COMMAND", "LIST", *args, fix=None)

    # keys of command lines
    lines = [["get", "k"], ["GET", "k"], ["get"], ["get", "a", "b"], ["set", "k", "v"],
             ["set", "k", "v", "get"], ["set", "k", "v", "GeT"], ["set", "k", "v", "ex", "10", "get"],
             ["set", "k", "v", "nx"], ["set", "k", "v", "getx"], ["set", "k", "get"], ["set", "k"],
             ["set", "get", "v"], ["mset", "a", "1", "b", "2"], ["mset", "a", "1", "b"], ["mset", "a"],
             ["del", "a", "b", "c"], ["del"], ["exists", "a"], ["unlink", "a", "b"], ["mget", "a", "b"],
             ["keys", "*"], ["ping"], ["ping", "x"], ["dbsize"], ["config", "get", "x"], ["config"],
             ["config", "nosuch"], ["client", "id"], ["client"], ["command"], ["command", "getkeys"],
             ["nosuch"], ["nosuch", "k"], ["incrby", "k", "1"], ["incrby", "k"], ["append", "k", "v"],
             ["getset", "k", "v"], ["strlen", "k"], ["type", "k"], ["setnx", "k", "v"], ["decr", "k"],
             ["select", "0"], ["flushall"], ["echo", "x"], ["Config", "GET", "x"]]
    for argv in lines:
        for sub in ("GETKEYS", "GETKEYSANDFLAGS"):
            same("COMMAND %s %s" % (sub, " ".join(argv)), "COMMAND", sub, *argv, fix=None)
    keyed = [n.decode() for n in tops if b.ask("COMMAND", "INFO", n)[0][0][3] > 0]
    for _ in range(a.rounds):
        argv = [rnd.choice(keyed)] + [rnd.choice(["k", "v", "1", "get", "GET", "ex", "x" * rnd.randint(0, 3)])
                                     for _ in range(rnd.randint(0, 6))]
        sub = rnd.choice(["GETKEYS", "GETKEYSANDFLAGS"])
        same("COMMAND %s %s" % (sub, " ".join(argv)), "COMMAND", sub, *argv, fix=None)

    # COMMAND's own errors, and its help
    for args in (["nosuch"], ["count", "x"], ["help", "x"], ["getkeys"], ["getkeys", "get"],
                 ["getkeysandflags"], ["getkeysandflags", "get"], ["HELP"], ["info", "INFO"]):
        same("COMMAND " + " ".join(args), "COMMAND", *args,
             fix=None if args[0].lower() != "info" else (lambda v: [keep_info(x, names) for x in v]))

    b.s.close()
    r.s.close()
    print("%d checks; " % passed + ("ALL OK" if ok else "SOME CHECKS FAILED"))
    return ok


if __name__ == "__main__":
    raise SystemExit(0 if main() else 1)
