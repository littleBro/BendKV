#!/usr/bin/env python3
# gen_commands.py: what COMMAND says of each command BendKV has
# (src/command.bend), taken from Redis 7.2.16 itself, so that COMMAND INFO
# and COMMAND DOCS answer with Redis's own description of each.
#
# Redis builds that description at its start, from src/commands/*.json and
# rules of its own (ACL categories implied by flags, movable keys, the
# first, last and step of the keys, flags hidden from the reply). So the
# facts are read where they come out: --extract starts a redis-server
# (7.2.16, from the PATH: tools/redis_ref.sh) on a spare port, asks it COMMAND INFO and
# COMMAND DOCS of BendKV's commands and ACL CAT in RESP3 (HELLO 3), whose
# replies say which arrays are maps and sets, and writes the replies to
# tools/data/redis-commands.json, kept in the repository, so the second
# step needs no Redis. The table holds them typed (R.RMap, R.RSet), as
# BendKV answers them in RESP3; RESP2 writes them as the arrays Redis
# writes in RESP2. Only the subcommands BendKV has are kept (BendKV's
# CLIENT has sixteen of Redis's eighteen), in the order of their names: Redis
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
# whether MONITOR sees its calls, whether a monitor may run it, whether
# CLIENT PAUSE WRITE holds it back, whether MULTI may queue it, whether
# Redis flags it fast and whether the slow log skips it (from its flags),
# and the word a call of each key that runs rides in (twelve bits, six of
# them set). The fourth writes there how a request's name finds its
# command (Step 4 below), from the same numbers.
#
# The descriptions are data from Redis 7.2.16 (src/commands/*.json, BSD
# 3-clause, Copyright (c) 2009-2012 Salvatore Sanfilippo and Redis
# contributors).
import json, os, re, socket, subprocess, sys, time, pathlib

HERE = pathlib.Path(__file__).resolve().parent.parent
JSON = HERE / "tools" / "data" / "redis-commands.json"
BEND = HERE / "src" / "command.bend"
REDIS = HERE / "src" / "redis.bend"
# the Redis whose descriptions the table copies (--extract asks it)
VERSION = "7.2.16"

# BendKV's commands, and of a command with subcommands the ones BendKV has
COMMANDS = {
    "append": [], "auth": [], "client": ["caching", "getname", "getredir", "help", "id",
    "info", "kill", "list", "no-evict", "pause", "reply", "setname", "tracking", "trackinginfo",
    "unblock", "unpause"], "command": ["count", "docs",
    "getkeys", "getkeysandflags", "help", "info", "list"], "config": ["get", "help",
    "resetstat", "rewrite", "set"], "dbsize": [], "decr": [], "decrby": [], "del": [],
    "echo": [], "exists": [], "flushall": [], "flushdb": [], "function": ["delete", "dump",
    "flush", "help", "kill", "list", "load", "restore", "stats"],
    "get": [], "getset": [], "hello": [], "incr": [], "incrby": [], "info": [], "keys": [],
    "mget": [], "mset": [], "ping": [], "quit": [], "reset": [], "select": [], "set": [],
    "randomkey": [], "scan": [], "setnx": [], "strlen": [], "type": [], "unlink": [],
    "setex": [], "psetex": [], "getex": [], "getdel": [], "expire": [], "pexpire": [],
    "expireat": [], "pexpireat": [], "ttl": [], "pttl": [], "expiretime": [],
    "pexpiretime": [], "persist": [], "swapdb": [], "move": [], "getrange": [], "substr": [],
    "setrange": [], "getbit": [], "setbit": [], "bitcount": [], "bitpos": [], "touch": [],
    "time": [], "object": ["encoding", "freq", "help", "idletime", "refcount"], "msetnx": [],
    "rename": [], "renamenx": [], "copy": [], "bitop": [], "lcs": [], "bitfield": [],
    "bitfield_ro": [], "hset": [], "hsetnx": [], "hget": [], "hmget": [], "hmset": [],
    "hdel": [], "hlen": [], "hstrlen": [], "hexists": [], "hkeys": [], "hvals": [],
    "hgetall": [], "hincrby": [], "hscan": [], "hrandfield": [], "eval": [],
    "evalsha": [], "eval_ro": [], "evalsha_ro": [], "script": ["exists", "flush", "help", "kill", "load"],
    "fcall": [], "fcall_ro": [],
    "memory": ["doctor", "help", "malloc-stats", "purge", "stats", "usage"], "lpush": [], "rpush": [], "lpushx": [], "rpushx": [],
    "lpop": [], "rpop": [], "llen": [], "lindex": [], "lrange": [], "lset": [],
    "linsert": [], "lrem": [], "ltrim": [], "lpos": [], "lmove": [], "rpoplpush": [],
    "lmpop": [], "sadd": [], "srem": [], "scard": [], "sismember": [], "smismember": [],
    "smembers": [], "sscan": [], "smove": [], "sinter": [], "sintercard": [],
    "sinterstore": [], "sunion": [], "sunionstore": [], "sdiff": [], "sdiffstore": [],
    "spop": [], "srandmember": [], "incrbyfloat": [], "hincrbyfloat": [], "zadd": [],
    "zincrby": [], "zrem": [], "zcard": [], "zscore": [], "zmscore": [], "zrank": [],
    "zrevrank": [], "zcount": [], "zlexcount": [], "zrange": [], "zrangebyscore": [],
    "zrevrangebyscore": [], "zrangebylex": [], "zrevrangebylex": [], "zrevrange": [],
    "zremrangebyrank": [], "zremrangebyscore": [], "zremrangebylex": [], "zpopmin": [],
    "zpopmax": [], "zscan": [], "zunion": [], "zinter": [], "zdiff": [], "zintercard": [],
    "zunionstore": [], "zinterstore": [], "zdiffstore": [], "zrangestore": [], "zmpop": [],
    "zrandmember": [], "blpop": [], "brpop": [], "brpoplpush": [], "blmove": [],
    "blmpop": [], "bzpopmin": [], "bzpopmax": [], "bzmpop": [], "multi": [], "exec": [],
    "discard": [], "watch": [], "unwatch": [], "subscribe": [], "unsubscribe": [],
    "psubscribe": [], "punsubscribe": [], "ssubscribe": [], "sunsubscribe": [],
    "publish": [], "spublish": [], "pubsub": ["channels", "help", "numpat", "numsub",
    "shardchannels", "shardnumsub"], "monitor": [], "bgrewriteaof": [], "sort": [],
    "sort_ro": [], "pfadd": [], "pfcount": [], "pfmerge": [], "pfdebug": [], "pfselftest": [],
    "lastsave": [], "role": [], "wait": [], "shutdown": [], "lolwut": [], "geoadd": [],
    "geodist": [], "geohash": [], "geopos": [], "georadius": [], "georadius_ro": [],
    "georadiusbymember": [], "georadiusbymember_ro": [], "geosearch": [], "geosearchstore": [],
    "dump": [], "restore": [], "slowlog": ["get", "help", "len", "reset"],
    "latency": ["doctor", "graph", "help", "histogram", "history", "latest", "reset"], "save": [],
    "acl": ["cat", "deluser", "dryrun", "genpass", "getuser", "help", "list", "load", "log",
            "save", "setuser", "users", "whoami"], "bgsave": [], "xlen": [], "xrange": [],
    "xrevrange": [], "xread": [], "xinfo": ["consumers", "groups", "help", "stream"],
    "xpending": [], "xadd": [], "xtrim": [], "xdel": [], "xsetid": []}

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
    # string, a null None, an integer an int, an array a list, a map
    # {"%": its keys and values in turn}, a set {"~": its items}
    def read(self):
        line = self.line()
        kind, rest = line[:1], line[1:].decode()
        if kind == b"+":
            return {"+": rest}
        if kind == b"_":
            return None
        if kind == b"%":
            return {"%": [self.read() for _ in range(2 * int(rest))]}
        if kind == b"~":
            return {"~": [self.read() for _ in range(int(rest))]}
        if kind == b"-":
            raise SystemExit("gen_commands.py: Redis answered an error: " + rest)
        if kind == b":":
            return int(rest)
        if kind in (b"$", b"="):
            n = int(rest)
            if n < 0:
                return None
            while len(self.buf) < n + 2:
                self.buf += self.s.recv(1 << 16)
            v, self.buf = self.buf[:n], self.buf[n + 2:]
            return v.decode()[4:] if kind == b"=" else v.decode()
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

# a reply as RESP2 has it: a map's keys and values, a set's items, as an
# array
def down(v):
    if isinstance(v, dict) and "%" in v:
        return [down(x) for x in v["%"]]
    if isinstance(v, dict) and "~" in v:
        return [down(x) for x in v["~"]]
    if isinstance(v, list):
        return [down(x) for x in v]
    return v

# the facts as RESP2 has them (each command's "info" and "docs"), with
# the replies as RESP3 types them kept beside (its "info3" and "docs3")
def load():
    facts = json.loads(JSON.read_text())
    for c in facts["commands"].values():
        c["info3"], c["docs3"] = c["info"], c["docs"]
        c["info"], c["docs"] = down(c["info"]), down(c["docs"])
    return facts

# a command's COMMAND INFO with only BendKV's subcommands, by name (in
# RESP3 a command without subcommands has an empty set of them)
def keep_info(info, subs):
    if isinstance(info[9], dict):
        if subs or info[9]["~"]:
            raise SystemExit("gen_commands.py: unexpected subcommands of " + info[0])
        return info
    kept = [x for x in info[9] if x[0].split("|")[1] in subs]
    if len(kept) != len(subs):
        raise SystemExit("gen_commands.py: Redis lacks a subcommand of " + info[0])
    return info[:9] + [sorted(kept, key=lambda x: x[0])]

def keep_docs(docs, subs):
    out = []
    for k, v in pairs(docs["%"]):
        if k == "subcommands":
            kept = sorted((p for p in pairs(v["%"]) if p[0].split("|")[1] in subs), key=lambda p: p[0])
            v = {"%": [x for p in kept for x in p]}
        out += [k, v]
    return {"%": out}

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
        if c.ask("HELLO", "3")["%"][5] != 3:
            raise SystemExit("gen_commands.py: Redis did not switch to RESP3")
        version = [l for l in c.ask("INFO", "server").split("\r\n") if l.startswith("redis_version:")][0]
        if version != "redis_version:" + VERSION:
            raise SystemExit("gen_commands.py: needs Redis " + VERSION + ", found " + version)
        cats = c.ask("ACL", "CAT")
        acl = {cat: sorted(c.ask("ACL", "CAT", cat)) for cat in cats}
        cmds = {}
        for name, subs in sorted(COMMANDS.items()):
            info = c.ask("COMMAND", "INFO", name)[0]
            docs = c.ask("COMMAND", "DOCS", name)["%"]
            cmds[name] = {"info": keep_info(info, subs), "docs": keep_docs(docs[1], subs)}
    finally:
        srv.terminate()
        srv.wait()
    JSON.write_text(json.dumps({"redis": VERSION, "categories": cats, "acl": acl, "commands": cmds},
                               indent=1, sort_keys=True) + "\n")

# Step 2: facts -> Bend
# ---------------------

# Commands whose keys Redis finds with a function of its own rather than
# their key specs (it does when a spec's flags vary): COMMAND GETKEYS
# runs BendKV's copy of that function
GETKEYS = {"set": "KBySet{}", "bitfield": "KByBitfield{}"}

# Commands whose key spec counts its keys with an argument (keynum):
# COMMAND GETKEYS runs BendKV's copy of what Redis does for them (the
# spec, then the command's own function when the spec does not read):
# ZUNION and its kin find their keys as SINTERCARD does, ZMPOP as LMPOP,
# BLMPOP and BZMPOP as LMPOP after their timeout, and the STOREs their
# destination first (OW, update) and then the keys, or, by their function,
# the keys and then the destination
KEYNUM = {"eval": "KByEval{}", "evalsha": "KByEval{}", "eval_ro": "KByEval{}", "evalsha_ro": "KByEval{}",
          "fcall": "KByEval{}", "fcall_ro": "KByEval{}",
          "lmpop": "KByLmpop{}", "sintercard": "KBySintercard{}",
          "zunion": "KBySintercard{}", "zinter": "KBySintercard{}", "zdiff": "KBySintercard{}",
          "zintercard": "KBySintercard{}", "zmpop": "KByLmpop{}", "zunionstore": "KByZstore{}",
          "zinterstore": "KByZstore{}", "zdiffstore": "KByZstore{}", "blmpop": "KByBlmpop{}",
          "bzmpop": "KByBlmpop{}"}

# Commands with key specs Redis cannot read (of kind "unknown": the keys
# SORT's BY and GET patterns name, and its STORE, which may come anywhere
# among its options): COMMAND GETKEYS runs BendKV's copy of the
# command's own function (sortGetKeys, sortROGetKeys)
UNKNOWN = {"sort": "KBySort{}", "sort_ro": "KBySortRo{}"}

# Commands with a key spec Redis 7.2 marks incomplete: COMMAND GETKEYS
# reads their specs, then runs BendKV's copy of the command's own
# function (georadiusGetKeys, xreadGetKeys) when an incomplete spec's
# keyword is there or a spec fails, as getKeysFromCommandWithSpecs does
INCOMPLETE = {"georadius": "KByGeo{}", "georadiusbymember": "KByGeo{}", "xread": "KByXread{}",
              "xreadgroup": "KByXread{}"}

def bstr(s):
    if any(ord(ch) > 126 or ord(ch) < 32 for ch in s):
        raise SystemExit("gen_commands.py: a string BendKV would send as other bytes: " + repr(s))
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

def bint(n):
    return f"R.IPos{{{n}n}}" if n >= 0 else f"R.INeg{{{-n - 1}n}}"

def blist(xs):
    return "[" + ", ".join(xs) + "]"

# a reply as Redis wrote it in RESP3
def reply(v):
    if isinstance(v, dict) and "%" in v:
        return f"R.RMap{{{blist([reply(x) for x in v['%']])}}}"
    if isinstance(v, dict) and "~" in v:
        return f"R.RSet{{{blist([reply(x) for x in v['~']])}}}"
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

# a key specification of a range from an index, or from the word after a
# keyword searched from an index on (GEORADIUS's STORE and STOREDIST),
# the only kinds BendKV's commands have
def kspec(name, ks):
    m = dict(pairs(ks))
    bs, fk = dict(pairs(m["begin_search"])), dict(pairs(m["find_keys"]))
    if bs["type"] not in ("index", "keyword") or fk["type"] != "range":
        raise SystemExit(f"gen_commands.py: {name} has a key spec other than a range")
    b, f = dict(pairs(bs["spec"])), dict(pairs(fk["spec"]))
    flags = blist([bstr(x) for x in statuses(m['flags'])])
    rng = f"{bint(f['lastkey'])}, {f['keystep']}n, {f['limit']}n"
    if bs["type"] == "keyword":
        if b["startfrom"] <= 0:
            raise SystemExit(f"gen_commands.py: {name} searches a keyword from the end")
        return f"KSpecKw{{{flags}, {bstr(b['keyword'])}, {b['startfrom']}n, {rng}}}"
    return f"KSpec{{{flags}, {b['index']}n, {rng}}}"

# a command's description and documentation, as RESP2 has them (for
# what they say) and as RESP3 types them (info3, docs3: for its replies)
def desc(info, docs, info3, docs3):
    name, flags = info[0], statuses(info[2])
    cats = [c[1:] for c in statuses(info[6])]
    if name in KEYNUM:
        specs, way = [], KEYNUM[name]
    elif name in UNKNOWN:
        specs, way = [], UNKNOWN[name]
    else:
        specs = [kspec(name, ks) for ks in info[8]]
        varies = any("variable_flags" in statuses(dict(pairs(ks))["flags"]) for ks in info[8])
        if varies != (name in GETKEYS):
            raise SystemExit(f"gen_commands.py: how does Redis find the keys of {name}?")
        incomplete = any("incomplete" in statuses(dict(pairs(ks))["flags"]) for ks in info[8])
        if incomplete != (name in INCOMPLETE):
            raise SystemExit(f"gen_commands.py: how does Redis find the keys of {name}?")
        way = GETKEYS.get(name, INCOMPLETE.get(name, "KBySpecs{}"))
    nokeys = "True{}" if "no_mandatory_keys" in flags else "False{}"
    fields = [reply(x) for x in info3[:9]]
    doc = [reply(x) for k, v in pairs(docs3["%"]) if k != "subcommands" for x in (k, v)]
    return (f"Desc{{{bstr(name)}, {bint(info[1])}, {blist([bstr(c) for c in cats])}, "
            f"{blist(specs)}, {way}, {nokeys},\n    {blist(fields)},\n    {blist(doc)}}}")

def block(facts):
    out = []
    names = sorted(facts["commands"])
    for name in names:
        c = facts["commands"][name]
        subs, subs3 = c["info"][9], c["info3"][9]
        subdocs = dict(pairs(dict(pairs(c["docs"])).get("subcommands", [])))
        subdocs3 = dict(pairs(dict(pairs(c["docs3"]["%"])).get("subcommands", {"%": []})["%"]))
        if sorted(subdocs) != [x[0] for x in subs]:
            raise SystemExit(f"gen_commands.py: the subcommands of {name} differ in INFO and DOCS")
        sd = [desc(x, subdocs[x[0]], x3, subdocs3[x[0]]) for x, x3 in zip(subs, subs3)]
        out.append(f"def cmd.{name}() -> Top:")
        out.append(f"  Top{{{desc(c['info'], c['docs'], c['info3'], c['docs3'])},\n  {blist(sd)}}}")
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

# The key specs of the commands, by INFO's keys (Step 3 below): the block
# between "# BEGIN gen_commands: by key" and "# END gen_commands: by key"
# in src/command.bend holds ro.key, the arity and the key specs (and how
# they are read, as in desc) of a command that only reads, which name the
# keys a call of it read (CLIENT TRACKING remembers them), spec.key, the
# same of every command, which name the keys ACL checks a call's user
# against, and acl.kind.key, the commands whose channels, user or patterns
# that check reads, each with no walk of the table and none of its
# documentation built.
KBEGIN, KEND = "# BEGIN gen_commands: by key\n", "# END gen_commands: by key\n"

def ro(info):
    name = info[0]
    if name in KEYNUM:
        specs, way = [], KEYNUM[name]
    elif name in UNKNOWN:
        specs, way = [], UNKNOWN[name]
    else:
        specs, way = [kspec(name, ks) for ks in info[8]], GETKEYS.get(name, INCOMPLETE.get(name, "KBySpecs{}"))
    return f"Ro{{{bint(info[1])}, {blist(specs)}, {way}}}"

def by_key_block(facts):
    fl = flag_sets(facts)
    tops, keys = stats_keys(REDIS.read_text())
    def info_of(name, kind):
        if kind == "top":
            return facts["commands"][name]["info"]
        return next(x for x in facts["commands"][kind]["info"][9] if x[0] == name)
    out = ["# the arity and key specs of the command or subcommand of a key that",
           "# only reads (readonly); none for any other",
           "def ro.key(+key: Nat) -> Maybe<&2, Ro>:", "  match key:"]
    for k, (name, kind, i) in enumerate(keys, 1):
        if "readonly" not in fl[name]:
            continue
        out += ["    case %dn:" % k, "      Some{%s}" % ro(info_of(name, kind))]
    out += ["    case _:", "      None{}", "",
            "# the same of the command or subcommand of any key, for ACL's check of",
            "# a call (acl.bend); none for key 0",
            "def spec.key(+key: Nat) -> Maybe<&2, Ro>:", "  match key:"]
    for k, (name, kind, i) in enumerate(keys, 1):
        out += ["    case %dn:" % k, "      Some{%s}" % ro(info_of(name, kind))]
    out += ["    case _:", "      None{}", "",
            "# what else ACL's check of a call reads of its command, by its key: 1",
            "# PUBLISH and SPUBLISH, 2 SUBSCRIBE and SSUBSCRIBE, 3 PSUBSCRIBE (the",
            "# channels it names), 4 AUTH, HELLO, QUIT and RESET (which every user",
            "# may run: Redis's CMD_NO_AUTH), 5 SORT, 6 SORT_RO (whose patterns name",
            "# keys); 0 any other",
            "def acl.kind.key(+key: Nat) -> Nat:", "  match key:"]
    for k, (name, kind, i) in enumerate(keys, 1):
        if name in ACL_KIND:
            out += ["    case %dn:" % k, "      %dn" % ACL_KIND[name]]
    out += ["    case _:", "      0n"]
    return "\n".join(out) + "\n"

# the commands acl.kind.key names (by_key_block)
ACL_KIND = {"publish": 1, "spublish": 1, "subscribe": 2, "ssubscribe": 2, "psubscribe": 3,
            "auth": 4, "hello": 4, "quit": 4, "reset": 4, "sort": 5, "sort_ro": 6}

def generate():
    src = BEND.read_text()
    a, b = src.index(BEGIN) + len(BEGIN), src.index(END)
    src = src[:a] + block(load()) + src[b:]
    a, b = src.index(KBEGIN) + len(KBEGIN), src.index(KEND)
    return src[:a] + by_key_block(load()) + src[b:]

# Step 3: facts -> INFO's keys
# ----------------------------
# INFO's statistics count each command and subcommand by a key: the
# commands in the order of their numbers in the parser (redis.bend:
# parse_id, parse_sess), then the subcommands of each container in the
# order of their own (client_id, function_id, config_id, command_id); 0 is
# none. What a
# call counts as is a code, 3 times its key plus its class (0 runs, 1 is
# refused, 2 fails as it parses). A request that runs carries its key as a
# word of twelve bits with six of them set (the key-th such word, in
# increasing order): the words or-ed together over a batch have six bits
# set exactly when all of them are one word. One that does not run carries
# the word of all twelve bits, and its code in the hint's bits, which it
# leaves unused (redis.bend: stat.hash): its batch is never one of one word.
# So 924 words hold 923 keys (one is none's), where a word for each code,
# three a key, held 307: functions and the writes of a stream came to 308.
# The block between "# BEGIN
# gen_commands: stats" and "# END gen_commands: stats" in src/redis.bend
# holds the keys, their names and arities (from the JSON), the keys whose
# calls can fail as they run (RISKY), and the words.

SBEGIN, SEND = "# BEGIN gen_commands: stats\n", "# END gen_commands: stats\n"

# the commands whose calls can fail as they run, on what the database
# holds: INCR and its kin meet values that are not integers, and overflows;
# a time from now can overflow LLONG_MAX (EXPIRE, PEXPIRE, SETEX, PSETEX),
# GETEX reads its time only once it finds its key, as BITCOUNT and BITPOS
# read their ranges, SETRANGE can make a value past 512MB, OBJECT FREQ
# and IDLETIME depend on the policy of eviction, RENAME and RENAMENX
# fail when their source key is not there, LCS when its table would
# pass proto-max-bulk-len, BITFIELD when its writes reach past 512MB
# (bitfield.of), a command of a hash on a key that holds a string
# (WRONGTYPE), HINCRBY on a value that is not an integer, HSCAN,
# HRANDFIELD and MEMORY USAGE on options read once the key is found, a
# command of a list on a key of another kind (WRONGTYPE), LINDEX and
# LSET on an index read once the list is found, a command of a set on a
# key of another kind (WRONGTYPE), SSCAN on options read once the set is
# found, INCRBYFLOAT and HINCRBYFLOAT on values that are not floats and
# sums that are not finite, a command of a sorted set on a key of another
# kind (WRONGTYPE, and ZINCRBY's sums that are not a number), ZSCAN on
# options read once the sorted set is found, SORT and SORT_RO on a key of
# another kind (WRONGTYPE) and on values that are no scores, the commands
# of HyperLogLogs on a value that is none (WRONGTYPE) or whose opcodes
# are invalid (INVALIDOBJ), PFDEBUG on a key not there or on a
# subcommand read once the key is found, PFSELFTEST on a check it fails,
# the commands of GEO on a key of another kind (WRONGTYPE), the
# searches on arguments read once their key is found, RESTORE on a key
# there (BUSYKEY), a time or a payload read once the key is found, and
# the reads of a stream on a key of another kind (WRONGTYPE), XREAD's IDs
# read once their key is found, XINFO on a key not there and on options
# read once it is found, XPENDING on a group not there (NOGROUP), and the
# writes of a stream on a key of another kind (WRONGTYPE), XADD on IDs
# not past the stream's last or on elements too large, XDEL on IDs read
# once the key is found, and XSETID on a key not there or below the
# stream's entries.
# (SET's time
# can overflow too, past 9 * 10^18 ms only: SET is left out, so that a
# batch of SETs needs no look at its replies.)
RISKY = {"incr", "decr", "incrby", "decrby", "expire", "pexpire", "setex", "psetex", "getex",
         "setrange", "bitcount", "bitpos", "object|freq", "object|idletime", "rename", "renamenx",
         "lcs", "bitfield", "hset", "hsetnx", "hget", "hmget", "hmset", "hdel", "hlen", "hstrlen",
         "hexists", "hkeys", "hvals", "hgetall", "hincrby", "hscan", "hrandfield", "memory|usage",
         "lpush", "rpush", "lpushx", "rpushx", "lpop", "rpop", "llen", "lindex", "lrange", "lset",
         "linsert", "lrem", "ltrim", "lpos", "lmove", "rpoplpush", "lmpop", "sadd", "srem", "scard",
         "sismember", "smismember", "smembers", "sscan", "smove", "sinter", "sintercard",
         "sinterstore", "sunion", "sunionstore", "sdiff", "sdiffstore", "spop", "srandmember",
         "incrbyfloat", "hincrbyfloat", "zadd", "zincrby", "zrem", "zcard", "zscore", "zmscore",
         "zrank", "zrevrank", "zcount", "zlexcount", "zrange", "zrangebyscore", "zrevrangebyscore",
         "zrangebylex", "zrevrangebylex", "zrevrange", "zremrangebyrank", "zremrangebyscore",
         "zremrangebylex", "zpopmin", "zpopmax", "zscan", "zunion", "zinter", "zdiff",
         "zintercard", "zunionstore", "zinterstore", "zdiffstore", "zrangestore", "zmpop",
         "zrandmember", "sort", "sort_ro", "pfadd", "pfcount", "pfmerge", "pfdebug", "pfselftest",
         "geoadd", "geodist", "geohash", "geopos", "georadius", "georadius_ro", "georadiusbymember",
         "georadiusbymember_ro", "geosearch", "geosearchstore", "restore", "xlen", "xrange",
         "xrevrange", "xread", "xinfo|consumers", "xinfo|groups", "xinfo|stream", "xpending",
         "xadd", "xtrim", "xdel", "xsetid"}

# BendKV's commands that may be replicated (MAY_REPLICATE in Redis's
# src/commands/*.json), a flag COMMAND INFO hides: a monitor may not run
# them, as it may not run a command that reads or writes a key, and
# CLIENT PAUSE WRITE holds them back, as it holds back those that write
MAY_REPLICATE = {"publish", "spublish", "eval", "evalsha", "fcall", "pfcount"}
# the commands of scripts and functions, which feed the monitors
# themselves (stat.unseen)
EVALS = {"eval", "evalsha", "eval_ro", "evalsha_ro", "fcall", "fcall_ro"}
# the commands that need the engine of scripts (stat.engine): the server
# runs them once the group is run (server.bend, Scripts), EXEC with one
# queued too; FUNCTION KILL and HELP alone of FUNCTION's do not
ENGINE = EVALS | {"script|load", "script|exists", "script|flush", "function|load",
                  "function|delete", "function|list", "function|stats", "function|dump",
                  "function|restore", "function|flush"}

# How a call of each command counts its changes, for INFO's
# rdb_changes_since_last_save and the save points (Redis's server.dirty,
# which each command adds to as it changes the data): a rule of
# server.bend (The count of changes) that reads the call's reply, and the
# weight the shell reads in its arguments, and in the state of a key it
# names before it runs, for the rules that take one. 0 none (a read, or a
# command that changes no data); 1 one for a reply that is no error; 2 an
# integer reply; 3 one for OK or a bulk string (SET, with or without GET);
# 4 one for a bulk string; 5 one for a bulk string, or the length of an
# array or a set (the pops of a list or a set); 6 the length of the second
# item of [key, elements] (LMPOP and ZMPOP); 7 half the length of a flat
# array, or the pairs of an array of them (ZPOPMIN and ZPOPMAX); 8 one for
# an array (BLPOP and BZPOPMIN at once); 9 one for a positive integer
# (LINSERT); 10 the weight for a reply that is no error; 11 the weight for
# a positive integer; 12 one for a positive integer, the weight (the
# destination was there) for 0 (the STOREs of sets and sorted sets,
# BITOP); 13 a positive integer, the weight for 0 (SORT's and GEO's
# STORE); 14 the weight for an integer reply, or the integer when the
# weight is 0, the weight for a score (ZADD and GEOADD; with INCR, and
# ZINCRBY, the weight is whether the score changes); 15 the weight less
# the nulls of an array (BITFIELD); 16 the weight, whatever the reply
# (EVAL of BendKV's own scripts: the DEL they start with, then what the
# command they run changes, which an error of that command does not undo)
DIRTY_RULES = {"none": 0, "one": 1, "int": 2, "set": 3, "bulk": 4, "pop": 5, "mpop": 6, "zpop": 7,
               "bpop": 8, "pos": 9, "wok": 10, "wpos": 11, "store": 12, "nstore": 13, "zadd": 14,
               "bitfield": 15, "w": 16}
DIRTY = {
    "set": "set", "setnx": "int", "setex": "one", "psetex": "one", "getset": "one", "getdel": "bulk",
    "getex": "wok", "setrange": "wok", "mset": "wok", "msetnx": "wpos", "incr": "one", "decr": "one",
    "incrby": "one", "decrby": "one", "incrbyfloat": "one", "append": "one", "setbit": "wok",
    "bitop": "store", "bitfield": "bitfield", "del": "int", "unlink": "int", "expire": "int",
    "pexpire": "int", "expireat": "int", "pexpireat": "int", "persist": "int", "rename": "wok",
    "renamenx": "int", "move": "int", "copy": "int", "swapdb": "one", "flushdb": "wok",
    "flushall": "wok", "restore": "wok", "hset": "wok", "hmset": "wok", "hsetnx": "int",
    "hincrby": "one", "hincrbyfloat": "one", "hdel": "int", "lpush": "wok", "rpush": "wok",
    "lpushx": "wpos", "rpushx": "wpos", "linsert": "pos", "lset": "one", "lpop": "pop", "rpop": "pop",
    "ltrim": "wok", "lrem": "int", "lmove": "bulk", "rpoplpush": "bulk", "lmpop": "mpop",
    "blpop": "bpop", "brpop": "bpop", "blmove": "bulk", "brpoplpush": "bulk", "blmpop": "mpop",
    "sadd": "int", "srem": "int", "smove": "wok", "spop": "pop", "sinterstore": "store",
    "sunionstore": "store", "sdiffstore": "store", "zadd": "zadd", "zincrby": "zadd", "zrem": "int",
    "zremrangebyscore": "int", "zremrangebyrank": "int", "zremrangebylex": "int", "zpopmin": "zpop",
    "zpopmax": "zpop", "zmpop": "mpop", "bzpopmin": "bpop", "bzpopmax": "bpop", "bzmpop": "mpop",
    "zunionstore": "store", "zinterstore": "store", "zdiffstore": "store", "zrangestore": "store",
    "pfadd": "int", "pfmerge": "one", "pfdebug": "wok", "geoadd": "zadd", "georadius": "nstore",
    "georadiusbymember": "nstore", "geosearchstore": "nstore", "sort": "nstore",
    "function|flush": "one", "function|load": "one", "function|delete": "one",
    "function|restore": "one", "eval": "w", "xadd": "bulk", "xtrim": "int", "xdel": "int",
    "xsetid": "one"}

# the parser's commands with subcommands, by the function that numbers
# their subcommands
CONTAINERS = {"client": "client_id", "function": "function_id", "config": "config_id",
              "command": "command_id", "object": "object_id", "memory": "memory_id",
              "pubsub": "pubsub_id", "slowlog": "slowlog_id", "latency": "latency_id",
              "script": "script_id", "acl": "acl_id", "xinfo": "xinfo_id"}

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

# the parser's numbers of its commands: each case of parse_id, and of
# parse_sess, is the number of the command its comment names
def parser_numbers(src):
    out = {}
    for fn in ("parse_id", "parse_sess"):
        a = src.index("\ndef %s(" % fn)
        b = src.index("\ndef ", a + 1)
        for n, name in re.findall(r"\n    case (\d+)n:  # ([A-Z][A-Z_]*)", src[a:b]):
            if name.lower() in out or int(n) in out.values():
                raise SystemExit("gen_commands.py: %s numbers %s twice" % (fn, name))
            out[name.lower()] = int(n)
    if set(out) != set(COMMANDS):
        raise SystemExit("gen_commands.py: the parser and COMMANDS differ on "
                         + ", ".join(sorted(set(out) ^ set(COMMANDS))))
    return out

# the numbers of parse_sess's commands
def own_numbers(src):
    a = src.index("\ndef parse_sess(")
    b = src.index("\ndef ", a + 1)
    return sorted(int(n) for n in re.findall(r"\n    case (\d+)n:  # [A-Z][A-Z_]*", src[a:b]))

# the flags COMMAND INFO gives each command and subcommand, by name
def flag_sets(facts):
    out = {}
    for name, c in facts["commands"].items():
        out[name] = {f["+"] for f in c["info"][2]}
        for sub in c["info"][9]:
            out[sub[0]] = {f["+"] for f in sub[2]}
    return out

# the commands that look their key up without touching it (Redis's
# LOOKUP_NOTOUCH): EXISTS, TYPE, and the TTLs (ttlGenericCommand); OBJECT's
# key is not its first argument
NOTOUCH = {"exists", "type", "ttl", "pttl", "expiretime", "pexpiretime"}

# the position of each command's first key (COMMAND's first key; 0 for none)
def first_keys(facts):
    out = {}
    for name, c in facts["commands"].items():
        out[name] = c["info"][3]
        for sub in c["info"][9]:
            out[sub[0]] = sub[3]
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
    tops = parser_numbers(src)
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
    if len(keys) + 1 > len(WORDS):
        raise SystemExit("gen_commands.py: more keys than words")
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
    fl = flag_sets(facts)
    out += ["# whether a call of the command of a key needs the engine of scripts:",
            "# EVAL and its kin, SCRIPT LOAD, EXISTS and FLUSH (server.bend, Scripts)",
            "def stat.engine(+key: Nat) -> Bool:", "  match key:"]
    for k, (name, kind, i) in enumerate(keys, 1):
        if name in ENGINE:
            out += ["    case %dn:" % k, "      True{}"]
    out += ["    case _:", "      False{}", ""]
    out += ["# whether a call of the command of a key goes unseen by MONITOR: an",
            "# administrative command (admin), or one that feeds the monitors",
            "# itself (skip_monitor), as Redis's call() leaves them out; EVAL and",
            "# its kin feed them before they run (evalCommand), as the server",
            "# feeds them when their script starts (server.bend, Scripts)",
            "def stat.unseen(+key: Nat) -> Bool:", "  match key:"]
    for k, (name, kind, i) in enumerate(keys, 1):
        if fl[name] & {"admin", "skip_monitor"} and name not in EVALS:
            out += ["    case %dn:" % k, "      True{}"]
    out += ["    case _:", "      False{}", ""]
    out += ["# whether the command of a key reads or writes keys, or may be",
            "# replicated (write, readonly, may_replicate): a monitor may not run it",
            "def stat.keyspace(+key: Nat) -> Bool:", "  match key:"]
    for k, (name, kind, i) in enumerate(keys, 1):
        if fl[name] & {"write", "readonly"} or name in MAY_REPLICATE:
            out += ["    case %dn:" % k, "      True{}"]
    out += ["    case _:", "      False{}", ""]
    out += ["# whether CLIENT PAUSE WRITE holds a call of the command of a key back:",
            "# one that writes or may be replicated (write, may_replicate)",
            "def stat.pausable(+key: Nat) -> Bool:", "  match key:"]
    for k, (name, kind, i) in enumerate(keys, 1):
        if "write" in fl[name] or name in MAY_REPLICATE:
            out += ["    case %dn:" % k, "      True{}"]
    out += ["    case _:", "      False{}", ""]
    out += ["# whether the command of a key writes (write): a script that may not",
            "# write is refused it, and a script that ran one cannot be killed;",
            "# while a background save that failed stops writes (MISCONF), Redis",
            "# refuses it",
            "def stat.write(+key: Nat) -> Bool:", "  match key:"]
    for k, (name, kind, i) in enumerate(keys, 1):
        if "write" in fl[name]:
            out += ["    case %dn:" % k, "      True{}"]
    out += ["    case _:", "      False{}", ""]
    out += ["# whether a script may not call the command of a key (noscript)",
            "def stat.noscript(+key: Nat) -> Bool:", "  match key:"]
    for k, (name, kind, i) in enumerate(keys, 1):
        if "noscript" in fl[name]:
            out += ["    case %dn:" % k, "      True{}"]
    out += ["    case _:", "      False{}", ""]
    out += ["# whether the command of a key runs while a script is busy (allow_busy):",
            "# every other answers BUSY then",
            "def stat.allow_busy(+key: Nat) -> Bool:", "  match key:"]
    for k, (name, kind, i) in enumerate(keys, 1):
        if "allow_busy" in fl[name]:
            out += ["    case %dn:" % k, "      True{}"]
    out += ["    case _:", "      False{}", ""]
    out += ["# whether the command of a key may take memory (denyoom): past",
            "# maxmemory with nothing left to evict, Redis refuses it",
            "def stat.denyoom(+key: Nat) -> Bool:", "  match key:"]
    for k, (name, kind, i) in enumerate(keys, 1):
        if "denyoom" in fl[name]:
            out += ["    case %dn:" % k, "      True{}"]
    out += ["    case _:", "      False{}", ""]
    for name in DIRTY:
        if name not in [x[0] for x in keys]:
            raise SystemExit("gen_commands.py: DIRTY names no command " + name)
    for name, kind, i in keys:
        if "write" in fl[name] and name not in DIRTY:
            raise SystemExit("gen_commands.py: DIRTY lacks the command " + name + ", which writes")
    out += ["# how a call of the command of a key counts its changes (DIRTY_RULES in",
            "# tools/gen_commands.py; server.bend, The count of changes)",
            "def stat.dirty(+key: Nat) -> Nat:", "  match key:"]
    for k, (name, kind, i) in enumerate(keys, 1):
        rule = DIRTY_RULES[DIRTY.get(name, "none")]
        if rule:
            out += ["    case %dn:" % k, "      %dn" % rule]
    out += ["    case _:", "      0n", ""]
    out += ["# whether the command of a key may not run in a transaction (no_multi:",
            "# SHUTDOWN, SAVE): in MULTI, Redis refuses it before it is queued",
            "def stat.nomulti(+key: Nat) -> Bool:", "  match key:"]
    for k, (name, kind, i) in enumerate(keys, 1):
        if "no_multi" in fl[name]:
            out += ["    case %dn:" % k, "      True{}"]
    out += ["    case _:", "      False{}", ""]
    out += ["# whether Redis flags the command of a key fast: the latency monitor",
            "# names a slow call of it fast-command, of any other command",
            "def stat.fast(+key: Nat) -> Bool:", "  match key:"]
    for k, (name, kind, i) in enumerate(keys, 1):
        if "fast" in fl[name]:
            out += ["    case %dn:" % k, "      True{}"]
    out += ["    case _:", "      False{}", ""]
    out += ["# whether the slow log skips the calls of the command of a key",
            "# (skip_slowlog: EXEC, whose commands are logged on their own)",
            "def stat.noslow(+key: Nat) -> Bool:", "  match key:"]
    for k, (name, kind, i) in enumerate(keys, 1):
        if "skip_slowlog" in fl[name]:
            out += ["    case %dn:" % k, "      True{}"]
    out += ["    case _:", "      False{}", ""]
    out += ["# whether the command of a key only reads (readonly): a client that",
            "# tracks keys (CLIENT TRACKING) has the keys of its calls remembered",
            "def stat.ro(+key: Nat) -> Bool:", "  match key:"]
    for k, (name, kind, i) in enumerate(keys, 1):
        if "readonly" in fl[name]:
            out += ["    case %dn:" % k, "      True{}"]
    out += ["    case _:", "      False{}", ""]
    fk = first_keys(facts)
    out += ["# whether the command of a key touches the key of its first argument",
            "# (its first key is there), as Redis's lookups set a key's access time:",
            "# all but those that look a key up without touching it (LOOKUP_NOTOUCH)",
            "def stat.touch(+key: Nat) -> Bool:", "  match key:"]
    for k, (name, kind, i) in enumerate(keys, 1):
        if fk[name] == 1 and name not in NOTOUCH:
            out += ["    case %dn:" % k, "      True{}"]
    out += ["    case _:", "      False{}", ""]
    nkeys = len(keys) + 1
    out += ["# the word of a call of a key that runs", "def stat.kw(+key: Nat) -> U32:", "  match key:"]
    for k in range(nkeys):
        out += ["    case %dn:" % k, "      %d" % WORDS[k]]
    out += ["    case _:", "      %d" % WORDS[0], ""]
    # by the word's high six bits, then its low six, so that no match
    # names a number past 63 (a match on a number unfolds it, and the
    # proof kernel's elaboration goes as deep as the largest one)
    his = sorted({WORDS[k] >> 6 for k in range(nkeys)})
    for hi in his:
        out += ["def stat.key.lo%d(+lo: Nat) -> Nat:" % hi, "  match lo:"]
        for k in range(nkeys):
            if WORDS[k] >> 6 == hi:
                out += ["    case %dn:" % (WORDS[k] & 63), "      %dn" % k]
        out += ["    case _:", "      0n", ""]
    out += ["def stat.key.hl(+hi: Nat, +lo: Nat) -> Nat:", "  match hi:"]
    for hi in his:
        out += ["    case %dn:" % hi, "      stat.key.lo%d(lo)" % hi]
    out += ["    case _:", "      0n", ""]
    out += ["# a word's key (0 for one no key has)", "def stat.key.cw(+w: Nat) -> Nat:",
            "  stat.key.hl(Nat.div(w, 64n), Nat.mod(w, 64n))", ""]
    out += ["# the high twelve bits of the hash of a call of GET, SET, INCR and",
            "# RESTORE that runs, as the parser writes them"]
    for name in ("get", "set", "incr", "restore"):
        k = [x[0] for x in keys].index(name) + 1
        out += ["def stat.mark.%s() -> U32:" % name, "  %d" % (WORDS[k] << 20), ""]
    return "\n".join(out[:-1]) + "\n"

# Step 4: the parser's numbers -> dispatch
# ----------------------------------------
# A request's name, in upper case, finds its command's number in the
# parser with cmd_id: by the name's length, then by its first letter, then
# with String.eq against the few names left (eight at most of Redis's 241
# commands). The letter goes by its place in the alphabet, A as 1, so that
# no match names a number past 26 (a match on a number tests each one from
# 0 up to its largest case). The block between "# BEGIN gen_commands:
# dispatch" and "# END gen_commands: dispatch" in src/redis.bend holds
# cmd_id and a function for each length (cmd_id.lN), and cmd_own, which
# tells parse_sess's numbers from parse_id's: each runs of them a range,
# so that a new command of either takes the next number free.

DBEGIN, DEND = "# BEGIN gen_commands: dispatch\n", "# END gen_commands: dispatch\n"

def own_block(own):
    runs = []
    for n in own:
        if runs and runs[-1][1] + 1 == n:
            runs[-1][1] = n
        else:
            runs.append([n, n])
    terms = ["Bool.and(Nat.is_le(%dn, id), Nat.is_le(id, %dn))" % (a, b) for a, b in runs]
    e = terms[-1]
    for t in reversed(terms[:-1]):
        e = "Bool.or(%s, %s)" % (t, e)
    return ["", "# whether a command's number is parse_sess's (a command of the",
            "# connection, of the server or of several databases)",
            "def cmd_own(+id: Nat) -> Bool:", "  " + e]

def dispatch_block(nums, own):
    lens = {}
    for name, n in nums.items():
        up = name.upper()
        if not "A" <= up[0] <= "Z":
            raise SystemExit("gen_commands.py: a name that starts with no letter: " + up)
        lens.setdefault(len(up), {}).setdefault(ord(up[0]) - 64, []).append((n, up))
    out = []
    for l in sorted(lens):
        out += ["def cmd_id.l%d(+n: String, c: Nat) -> Nat:" % l, "  match c:"]
        for c in sorted(lens[l]):
            ns = sorted(lens[l][c])
            out.append("    case %dn:  # %s" % (c, chr(64 + c)))
            out += ["      Bool.pick(Nat, String.eq(n, %s), %dn," % (bstr(up), n) for n, up in ns]
            out[-1] += " 0n" + ")" * len(ns)
        out += ["    case _:", "      0n", ""]
    out += ["def cmd_id(+n: String, len: Nat) -> Nat:", "  match len:"]
    for l in sorted(lens):
        out += ["    case %dn:" % l,
                "      cmd_id.l%d(n, Nat.sub(U32.to_nat(String.code_at(n, 0n)), 64n))" % l]
    out += ["    case _:", "      0n"]
    out += own_block(own)
    return "\n".join(out) + "\n"

# Step 5: facts -> ACL's ids
# --------------------------
# ACL's ids number Redis 7.2.16's commands and subcommands, every one that
# ACL CAT lists under its categories (each is in @fast or @slow), in the
# byte order of their names, so that a rule may name a command BendKV
# lacks, as in Redis. The block between "# BEGIN gen_commands: acl" and
# "# END gen_commands: acl" in src/acl.bend holds their names, the ids of
# each category, and the id of each of INFO's keys (Step 3), which a call
# carries in its code.

ABEGIN, AEND = "# BEGIN gen_commands: acl\n", "# END gen_commands: acl\n"
ACLSRC = HERE / "src" / "acl.bend"

def acl_block(src, facts):
    names = sorted({n for ns in facts["acl"].values() for n in ns})
    ids = {n: i for i, n in enumerate(names)}
    tops, keys = stats_keys(src)
    out = ["# Redis " + VERSION + "'s commands and subcommands, by ACL id: their full names",
           "# in byte order",
           "def acl.names() -> List<&2, String>:",
           "  " + blist([bstr(n) for n in names]), "",
           "# how many there are",
           "def acl.count() -> Nat:", "  %dn" % len(names), "",
           "# the categories, in ACL CAT's order",
           "def acl.cats() -> List<&2, String>:",
           "  " + blist([bstr(c) for c in facts["categories"]]), "",
           "# the ids of each category, by its place in ACL CAT's list",
           "def acl.cat.ids(+c: Nat) -> List<&2, Nat>:", "  match c:"]
    for i, cat in enumerate(facts["categories"]):
        out += ["    case %dn:" % i, "      " + blist(["%dn" % ids[n] for n in facts["acl"][cat]])]
    out += ["    case _:", "      []", "",
            "# the id of a call of BendKV, by its INFO key (redis.bend); acl.count()",
            "# for none",
            "def acl.of.key(+k: Nat) -> Nat:", "  match k:"]
    for k, (name, kind, i) in enumerate(keys, 1):
        if name not in ids:
            raise SystemExit("gen_commands.py: ACL CAT does not list " + name)
        out += ["    case %dn:" % k, "      %dn" % ids[name]]
    out += ["    case _:", "      %dn" % len(names)]
    return "\n".join(out) + "\n"

def generate_acl():
    src = ACLSRC.read_text()
    a, b = src.index(ABEGIN) + len(ABEGIN), src.index(AEND)
    return src[:a] + acl_block(REDIS.read_text(), load()) + src[b:]

def generate_redis():
    src = REDIS.read_text()
    a, b = src.index(DBEGIN) + len(DBEGIN), src.index(DEND)
    src = src[:a] + dispatch_block(parser_numbers(src), own_numbers(src)) + src[b:]
    a, b = src.index(SBEGIN) + len(SBEGIN), src.index(SEND)
    return src[:a] + stats_block(src, load()) + src[b:]

if __name__ == "__main__":
    if sys.argv[1:] == ["--extract"]:
        extract()
    elif sys.argv[1:] == ["--check"]:
        if generate() != BEND.read_text():
            raise SystemExit("gen_commands.py: src/command.bend is out of date; run tools/gen_commands.py")
        if generate_redis() != REDIS.read_text():
            raise SystemExit("gen_commands.py: src/redis.bend is out of date; run tools/gen_commands.py")
        if generate_acl() != ACLSRC.read_text():
            raise SystemExit("gen_commands.py: src/acl.bend is out of date; run tools/gen_commands.py")
    elif sys.argv[1:] == []:
        BEND.write_text(generate())
        REDIS.write_text(generate_redis())
        ACLSRC.write_text(generate_acl())
    else:
        raise SystemExit("usage: gen_commands.py [--extract | --check]")
