#!/usr/bin/env python3
# gen_commands.py: what COMMAND says of each command BendKV has
# (src/command.bend), taken from Redis 7.0.15 itself, so that COMMAND INFO
# and COMMAND DOCS answer with Redis's own description of each.
#
# Redis builds that description at its start, from src/commands/*.json and
# rules of its own (ACL categories implied by flags, movable keys, the
# first, last and step of the keys, flags hidden from the reply). So the
# facts are read where they come out: --extract starts a redis-server
# (7.0.15, from the PATH) on a spare port, asks it COMMAND INFO and
# COMMAND DOCS of BendKV's commands and ACL CAT, and writes the replies
# to tools/data/redis-commands.json, kept in the repository, so the second
# step needs no Redis. Only the subcommands BendKV has are kept (BendKV's
# CLIENT has ten of Redis's sixteen), in the order of their names: Redis
# lists commands in the order of a hash table with a random seed, so no
# order is Redis's own. The second step writes the block between
# "# BEGIN gen_commands: table" and "# END gen_commands: table" in
# src/command.bend from the JSON.
#
#   python3 tools/gen_commands.py --extract    # redis-server -> JSON
#   python3 tools/gen_commands.py              # JSON -> src/command.bend
#   python3 tools/gen_commands.py --check      # fails if out of date
#
# The descriptions are data from Redis 7.0.15 (src/commands/*.json, BSD
# 3-clause, Copyright (c) 2009-2012 Salvatore Sanfilippo and Redis
# contributors).
import json, os, socket, subprocess, sys, time, pathlib

HERE = pathlib.Path(__file__).resolve().parent.parent
JSON = HERE / "tools" / "data" / "redis-commands.json"
BEND = HERE / "src" / "command.bend"

# BendKV's commands, and of a command with subcommands the ones BendKV has
COMMANDS = {
    "append": [], "auth": [], "client": ["caching", "getname", "getredir", "help", "id",
    "no-evict", "reply", "setname", "trackinginfo", "unblock"], "command": ["count", "docs",
    "getkeys", "getkeysandflags", "help", "info", "list"], "config": ["get", "help",
    "resetstat", "rewrite", "set"], "dbsize": [], "decr": [], "decrby": [], "del": [],
    "echo": [], "exists": [], "flushall": [], "flushdb": [], "function": ["flush", "help"],
    "get": [], "getset": [], "hello": [], "incr": [], "incrby": [], "info": [], "keys": [],
    "mget": [], "mset": [], "ping": [], "quit": [], "reset": [], "select": [], "set": [],
    "setnx": [], "strlen": [], "type": [], "unlink": []}

# Step 1: redis-server -> facts
# -----------------------------

class Conn:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=10)
        self.buf = b""

    def line(self):
        while b"\r\n" not in self.buf:
            chunk = self.s.recv(1 << 16)
            if not chunk:
                raise ConnectionError("closed")
            self.buf += chunk
        i = self.buf.index(b"\r\n")
        line, self.buf = self.buf[:i], self.buf[i + 2:]
        return line

    # a reply, with its kind kept: a status is {"+": s}, a bulk string a
    # string, a null bulk None, an integer an int, an array a list
    def read(self):
        line = self.line()
        kind, rest = line[:1], line[1:].decode()
        if kind == b"+":
            return {"+": rest}
        if kind == b"-":
            raise SystemExit("gen_commands.py: Redis answered an error: " + rest)
        if kind == b":":
            return int(rest)
        if kind == b"$":
            n = int(rest)
            if n < 0:
                return None
            while len(self.buf) < n + 2:
                self.buf += self.s.recv(1 << 16)
            v, self.buf = self.buf[:n], self.buf[n + 2:]
            return v.decode()
        if kind == b"*":
            n = int(rest)
            return None if n < 0 else [self.read() for _ in range(n)]
        raise SystemExit("gen_commands.py: unexpected reply " + repr(line))

    def ask(self, *args):
        out = b"*%d\r\n" % len(args)
        for a in args:
            a = a.encode()
            out += b"$%d\r\n%s\r\n" % (len(a), a)
        self.s.sendall(out)
        return self.read()

def pairs(m):
    return list(zip(m[0::2], m[1::2]))

# a command's COMMAND INFO with only BendKV's subcommands, by name
def keep_info(info, subs):
    kept = [x for x in info[9] if x[0].split("|")[1] in subs]
    if len(kept) != len(subs):
        raise SystemExit("gen_commands.py: Redis lacks a subcommand of " + info[0])
    return info[:9] + [sorted(kept, key=lambda x: x[0])]

def keep_docs(docs, subs):
    out = []
    for k, v in pairs(docs):
        if k == "subcommands":
            kept = sorted((p for p in pairs(v) if p[0].split("|")[1] in subs), key=lambda p: p[0])
            v = [x for p in kept for x in p]
        out += [k, v]
    return out

def extract():
    port = int(os.environ.get("GEN_PORT", "6499"))
    srv = subprocess.Popen(["redis-server", "--port", str(port), "--save", "", "--appendonly", "no",
                            "--bind", "127.0.0.1"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            try:
                c = Conn(port)
                break
            except OSError:
                time.sleep(0.05)
        version = [l for l in c.ask("INFO", "server").split("\r\n") if l.startswith("redis_version:")][0]
        if version != "redis_version:7.0.15":
            raise SystemExit("gen_commands.py: needs Redis 7.0.15, found " + version)
        cats = c.ask("ACL", "CAT")
        cmds = {}
        for name, subs in sorted(COMMANDS.items()):
            info = c.ask("COMMAND", "INFO", name)[0]
            docs = c.ask("COMMAND", "DOCS", name)
            cmds[name] = {"info": keep_info(info, subs), "docs": keep_docs(docs[1], subs)}
    finally:
        srv.terminate()
        srv.wait()
    JSON.write_text(json.dumps({"redis": "7.0.15", "categories": cats, "commands": cmds},
                               indent=1, sort_keys=True) + "\n")

# Step 2: facts -> Bend
# ---------------------

# Commands whose keys Redis finds with a function of its own rather than
# their key specs (it does when a spec's flags vary): COMMAND GETKEYS
# runs BendKV's copy of that function
GETKEYS = {"set": "KBySet{}"}

def bstr(s):
    if any(ord(ch) > 126 or ord(ch) < 32 for ch in s):
        raise SystemExit("gen_commands.py: a string BendKV would send as other bytes: " + repr(s))
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

def bint(n):
    return f"R.IPos{{{n}n}}" if n >= 0 else f"R.INeg{{{-n - 1}n}}"

def blist(xs):
    return "[" + ", ".join(xs) + "]"

# a reply as Redis wrote it
def reply(v):
    if isinstance(v, dict):
        return f"R.RStatus{{{bstr(v['+'])}}}"
    if isinstance(v, str):
        return f"R.RBulk{{{bstr(v)}}}"
    if isinstance(v, bool) or v is None:
        raise SystemExit("gen_commands.py: unexpected reply " + repr(v))
    if isinstance(v, int):
        return f"R.RInt{{{bint(v)}}}"
    return f"R.RArray{{{blist([reply(x) for x in v])}}}"

def statuses(xs):
    return [x["+"] for x in xs]

# a key specification of an index and a range, the only kind BendKV's
# commands have
def kspec(name, ks):
    m = dict(pairs(ks))
    bs, fk = dict(pairs(m["begin_search"])), dict(pairs(m["find_keys"]))
    if bs["type"] != "index" or fk["type"] != "range":
        raise SystemExit(f"gen_commands.py: {name} has a key spec other than an index and a range")
    b, f = dict(pairs(bs["spec"])), dict(pairs(fk["spec"]))
    return (f"KSpec{{{blist([bstr(x) for x in statuses(m['flags'])])}, {b['index']}n, "
            f"{bint(f['lastkey'])}, {f['keystep']}n, {f['limit']}n}}")

def desc(info, docs):
    name, flags = info[0], statuses(info[2])
    cats = [c[1:] for c in statuses(info[6])]
    specs = [kspec(name, ks) for ks in info[8]]
    varies = any("variable_flags" in statuses(dict(pairs(ks))["flags"]) for ks in info[8])
    if varies != (name in GETKEYS):
        raise SystemExit(f"gen_commands.py: how does Redis find the keys of {name}?")
    way = GETKEYS.get(name, "KBySpecs{}")
    nokeys = "True{}" if "no_mandatory_keys" in flags else "False{}"
    fields = [reply(x) for x in info[:9]]
    doc = [reply(x) for k, v in pairs(docs) if k != "subcommands" for x in (k, v)]
    return (f"Desc{{{bstr(name)}, {bint(info[1])}, {blist([bstr(c) for c in cats])}, "
            f"{blist(specs)}, {way}, {nokeys},\n    {blist(fields)},\n    {blist(doc)}}}")

def block(facts):
    out = []
    names = sorted(facts["commands"])
    for name in names:
        c = facts["commands"][name]
        subs = c["info"][9]
        subdocs = dict(pairs(dict(pairs(c["docs"])).get("subcommands", [])))
        if sorted(subdocs) != [x[0] for x in subs]:
            raise SystemExit(f"gen_commands.py: the subcommands of {name} differ in INFO and DOCS")
        sd = [desc(x, subdocs[x[0]]) for x in subs]
        out.append(f"def cmd.{name}() -> Top:")
        out.append(f"  Top{{{desc(c['info'], c['docs'])},\n  {blist(sd)}}}")
        out.append("")
    out.append("# the commands, by name")
    out.append("def table() -> List<&2, Top>:")
    out.append("  " + blist([f"cmd.{n}()" for n in names]))
    out.append("")
    out.append("# Redis's ACL categories (ACL CAT)")
    out.append("def categories() -> List<&2, String>:")
    out.append("  " + blist([bstr(c) for c in facts["categories"]]))
    return "\n".join(out) + "\n"

BEGIN, END = "# BEGIN gen_commands: table\n", "# END gen_commands: table\n"

def generate():
    src = BEND.read_text()
    a, b = src.index(BEGIN) + len(BEGIN), src.index(END)
    return src[:a] + block(json.loads(JSON.read_text())) + src[b:]

if __name__ == "__main__":
    if sys.argv[1:] == ["--extract"]:
        extract()
    elif sys.argv[1:] == ["--check"]:
        if generate() != BEND.read_text():
            raise SystemExit("gen_commands.py: src/command.bend is out of date; run tools/gen_commands.py")
    elif sys.argv[1:] == []:
        BEND.write_text(generate())
    else:
        raise SystemExit("usage: gen_commands.py [--extract | --check]")
