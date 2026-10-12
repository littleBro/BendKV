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
#   python3 tools/gen_commands.py              # JSON -> src/command.bend, src/redis.bend
#   python3 tools/gen_commands.py --check      # fails if out of date
#
# The third step writes INFO's keys into src/redis.bend (Step 3 below):
# a key for each command and subcommand, numbered from the parser's own
# numbers, its name, its arity from the same JSON (the statistics count a
# call with the wrong number of arguments as refused only when it fails
# Redis's own check of the arity), whether its calls may fail as they run,
# and the word each code rides in (twelve bits, six of them set).
#
# The descriptions are data from Redis 7.0.15 (src/commands/*.json, BSD
# 3-clause, Copyright (c) 2009-2012 Salvatore Sanfilippo and Redis
# contributors).
import json, os, re, socket, subprocess, sys, time, pathlib

HERE = pathlib.Path(__file__).resolve().parent.parent
JSON = HERE / "tools" / "data" / "redis-commands.json"
BEND = HERE / "src" / "command.bend"
REDIS = HERE / "src" / "redis.bend"

# BendKV's commands, and of a command with subcommands the ones BendKV has
COMMANDS = {
    "append": [], "auth": [], "client": ["caching", "getname", "getredir", "help", "id",
    "no-evict", "reply", "setname", "trackinginfo", "unblock"], "command": ["count", "docs",
    "getkeys", "getkeysandflags", "help", "info", "list"], "config": ["get", "help",
    "resetstat", "rewrite", "set"], "dbsize": [], "decr": [], "decrby": [], "del": [],
    "echo": [], "exists": [], "flushall": [], "flushdb": [], "function": ["flush", "help"],
    "get": [], "getset": [], "hello": [], "incr": [], "incrby": [], "info": [], "keys": [],
    "mget": [], "mset": [], "ping": [], "quit": [], "reset": [], "select": [], "set": [],
    "randomkey": [], "scan": [], "setnx": [], "strlen": [], "type": [], "unlink": [],
    "setex": [], "psetex": [], "getex": [], "getdel": [], "expire": [], "pexpire": [],
    "expireat": [], "pexpireat": [], "ttl": [], "pttl": [], "expiretime": [],
    "pexpiretime": [], "persist": [], "swapdb": [], "move": [], "getrange": [], "substr": [],
    "setrange": [], "getbit": [], "setbit": [], "bitcount": [], "bitpos": [], "touch": [],
    "time": [], "object": ["encoding", "freq", "help", "idletime", "refcount"], "msetnx": [],
    "rename": [], "renamenx": [], "copy": []}

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

# Step 3: facts -> INFO's keys
# ----------------------------
# INFO's statistics count each command and subcommand by a key: the
# commands in the order of their numbers in the parser (redis.bend:
# cmd_id), then the subcommands of each container in the order of their
# own (client_id, function_id, config_id, command_id); 0 is none. What a
# call counts as is a code, 4 times its key plus its class (0 runs, 1 is
# refused, 2 fails as it parses), and a request carries its code as a
# word of twelve bits with six of them set (the code-th such word, in
# increasing order): the words or-ed together over a batch have six bits
# set exactly when all of them are one word. The block between "# BEGIN
# gen_commands: stats" and "# END gen_commands: stats" in src/redis.bend
# holds the keys, their names and arities (from the JSON), the keys whose
# calls can fail as they run (RISKY), and the words.

SBEGIN, SEND = "# BEGIN gen_commands: stats\n", "# END gen_commands: stats\n"

# the commands whose calls can fail as they run, on what the database
# holds: INCR and its kin meet values that are not integers, and overflows;
# a time from now can overflow LLONG_MAX (EXPIRE, PEXPIRE, SETEX, PSETEX),
# GETEX reads its time only once it finds its key, as BITCOUNT and BITPOS
# read their ranges, SETRANGE can make a value past 512MB, OBJECT FREQ
# and IDLETIME depend on the policy of eviction, and RENAME and RENAMENX
# fail when their source key is not there. (SET's time
# can overflow too, past 9 * 10^18 ms only: SET is left out, so that a
# batch of SETs needs no look at its replies.)
RISKY = {"incr", "decr", "incrby", "decrby", "expire", "pexpire", "setex", "psetex", "getex",
         "setrange", "bitcount", "bitpos", "object|freq", "object|idletime", "rename", "renamenx"}

# the parser's commands with subcommands, by the function that numbers
# their subcommands
CONTAINERS = {"client": "client_id", "function": "function_id", "config": "config_id",
              "command": "command_id", "object": "object_id"}

# the names a numbering def of redis.bend gives its numbers
def numbering(src, fn):
    a = src.index("def %s(" % fn)
    b = src.index("\n\n", a)
    out = {}
    for name, n in re.findall(r'String\.eq\(n, "([^"]+)"\), (\d+)n', src[a:b]):
        if int(n) in out.values():
            raise SystemExit("gen_commands.py: %s gives %s twice" % (fn, n))
        out[name.lower()] = int(n)
    return out

def arities(facts):
    out = {}
    for name, c in facts["commands"].items():
        out[name] = c["info"][1]
        for sub in c["info"][9]:
            out[sub[0]] = sub[1]
    return out

# twelve-bit words with six bits set, in increasing order
WORDS = [w for w in range(1 << 12) if bin(w).count("1") == 6]

def stats_keys(src):
    tops = numbering(src, "cmd_id")
    keys = [(n, "top", i) for n, i in sorted(tops.items(), key=lambda x: x[1])]
    for cont, fn in CONTAINERS.items():
        if cont not in tops:
            raise SystemExit("gen_commands.py: no command " + cont)
        subs = numbering(src, fn)
        keys += [(cont + "|" + n, cont, i) for n, i in sorted(subs.items(), key=lambda x: x[1])]
    return tops, keys

def stats_block(src, facts):
    ar = arities(facts)
    tops, keys = stats_keys(src)
    if 4 * (len(keys) + 1) > len(WORDS):
        raise SystemExit("gen_commands.py: more codes than words")
    out = ["# a command's key, by its number in the parser (cmd_id); 0 for none",
           "def stat.top(+id: Nat) -> Nat:", "  match id:"]
    for k, (name, kind, i) in enumerate(keys, 1):
        if kind == "top":
            out += ["    case %dn:" % i, "      %dn" % k]
    out += ["    case _:", "      0n", ""]
    for cont in CONTAINERS:
        out += ["# a subcommand of %s's key, by its number; 0 for none" % cont.upper(),
                "def stat.sub.%s(+sub: Nat) -> Nat:" % cont, "  match sub:"]
        for k, (name, kind, i) in enumerate(keys, 1):
            if kind == cont:
                out += ["    case %dn:" % i, "      %dn" % k]
        out += ["    case _:", "      0n", ""]
    out += ["# the name INFO gives a key (as COMMAND names it); \"\" for none",
            "def stat.name(+key: Nat) -> String:", "  match key:"]
    for k, (name, kind, i) in enumerate(keys, 1):
        out += ["    case %dn:" % k, "      %s" % bstr(name)]
    out += ["    case _:", "      \"\"", ""]
    out += ["# Redis's arity of the command or subcommand of a key: 2a when it takes",
            "# exactly a arguments (its name included), 2a + 1 when it takes a or more",
            "def stat.arity(+key: Nat) -> Nat:", "  match key:"]
    for k, (name, kind, i) in enumerate(keys, 1):
        if name not in ar:
            raise SystemExit("gen_commands.py: no arity for " + name)
        a = ar[name]
        out += ["    case %dn:" % k, "      %dn" % (2 * a if a >= 0 else -2 * a + 1)]
    out += ["    case _:", "      1n", ""]
    out += ["# whether a call of the command of a key can fail as it runs",
            "def stat.risky(+key: Nat) -> Bool:", "  match key:"]
    for k, (name, kind, i) in enumerate(keys, 1):
        if name in RISKY:
            out += ["    case %dn:" % k, "      True{}"]
    out += ["    case _:", "      False{}", ""]
    ncodes = 4 * (len(keys) + 1)
    out += ["# a code's word", "def stat.cw(+code: Nat) -> U32:", "  match code:"]
    for c in range(ncodes):
        out += ["    case %dn:" % c, "      %d" % WORDS[c]]
    out += ["    case _:", "      %d" % WORDS[0], ""]
    out += ["# a word's code (0 for one no code has)", "def stat.code.cw(+w: Nat) -> Nat:", "  match w:"]
    for c in range(ncodes):
        out += ["    case %dn:" % WORDS[c], "      %dn" % c]
    out += ["    case _:", "      0n", ""]
    out += ["# the high twelve bits of the hash of a call of GET, SET and INCR that",
            "# runs, as the parser writes them"]
    for name in ("get", "set", "incr"):
        k = [x[0] for x in keys].index(name) + 1
        out += ["def stat.mark.%s() -> U32:" % name, "  %d" % (WORDS[4 * k] << 20), ""]
    return "\n".join(out[:-1]) + "\n"

def generate_stats():
    src = REDIS.read_text()
    a, b = src.index(SBEGIN) + len(SBEGIN), src.index(SEND)
    return src[:a] + stats_block(src, json.loads(JSON.read_text())) + src[b:]

if __name__ == "__main__":
    if sys.argv[1:] == ["--extract"]:
        extract()
    elif sys.argv[1:] == ["--check"]:
        if generate() != BEND.read_text():
            raise SystemExit("gen_commands.py: src/command.bend is out of date; run tools/gen_commands.py")
        if generate_stats() != REDIS.read_text():
            raise SystemExit("gen_commands.py: src/redis.bend is out of date; run tools/gen_commands.py")
    elif sys.argv[1:] == []:
        BEND.write_text(generate())
        REDIS.write_text(generate_stats())
    else:
        raise SystemExit("usage: gen_commands.py [--extract | --check]")
