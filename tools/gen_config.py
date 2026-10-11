#!/usr/bin/env python3
# gen_config.py: the table of server parameters that CONFIG GET and CONFIG
# SET serve (src/config.bend), taken from Redis 7.0.15's own table, so that
# BendKV knows every parameter Redis knows, with its type, bounds, flags and
# default.
#
# Two steps. --extract reads static_configs[] in Redis's src/config.c (and
# the constants its enums use) and writes the facts to
# tools/data/redis-configs.json; that file is kept in the repository, so
# the second step needs no Redis source. The second step writes the block
# between "# BEGIN gen_config: table" and "# END gen_config: table" in
# src/config.bend from the JSON, with BendKV's own defaults where they
# differ from Redis's (DEFAULTS below).
#
#   python3 tools/gen_config.py --extract ../redis   # Redis source -> JSON
#   python3 tools/gen_config.py                      # JSON -> src/config.bend
#   python3 tools/gen_config.py --check              # fails if out of date
#
# The table is data from Redis 7.0.15 (src/config.c, BSD 3-clause,
# Copyright (c) 2009-2012 Salvatore Sanfilippo and Redis contributors).
import json, re, sys, pathlib

HERE = pathlib.Path(__file__).resolve().parent.parent
JSON = HERE / "tools" / "data" / "redis-configs.json"
BEND = HERE / "src" / "config.bend"

# Where BendKV's default is not Redis's: one database, no RDB snapshots,
# and the loopback address it listens on.
DEFAULTS = {"databases": "1", "save": "", "bind": "127.0.0.1"}

# What a change does in BendKV, by Redis's apply function: hz is capped as
# Redis caps it, repl-backlog-size is raised to Redis's least backlog,
# requirepass sets the password; the port, the addresses and
# the append-only file cannot change while BendKV runs, so a new value fails
# with the error Redis gives when it cannot apply one. Other parameters are
# kept and read back, and change nothing else (BendKV has no eviction, no
# replication, no encodings to tune).
APPLY = {"updateHZ": "AppHz{}", "updateRequirePass": "AppPass{}",
         "updatePort": 'AppFixed{"Unable to listen on this port. Check server logs."}',
         "applyBind": 'AppFixed{"Failed to bind to specified addresses."}',
         "updateAppendonly": 'AppFixed{"Unable to turn on AOF. Check server logs."}',
         "updateReplBacklogSize": 'AppMin{"16384"}'}
# BendKV speaks no TLS: its port and the TLS of replication and of the
# cluster cannot be turned on, which fails as in a Redis with no
# certificates; the other TLS parameters are kept, as they are in Redis
# while TLS is off.
TLS = 'AppFixed{"Unable to update TLS configuration. Check server logs."}'
APPLY_BY_NAME = {"tls-port": TLS, "tls-replication": TLS, "tls-cluster": TLS}

# Step 1: Redis source -> facts
# -----------------------------

LIMITS = {"INT_MAX": 2**31 - 1, "INT_MIN": -2**31, "UINT_MAX": 2**32 - 1,
          "LONG_MAX": 2**63 - 1, "LLONG_MAX": 2**63 - 1, "SSIZE_MAX": 2**63 - 1,
          "ULLONG_MAX": 2**64 - 1, "NULL": 0}
# <syslog.h>, which is not in Redis's source
SYSLOG = {"LOG_USER": 1 << 3, **{f"LOG_LOCAL{i}": (16 + i) << 3 for i in range(8)}}

def c_eval(expr, names):
    e = re.sub(r"\b(0x[0-9a-fA-F]+|\d+)(?:ULL|ull|LL|ll|UL|ul|L|l|U|u)\b", r"\1", expr.strip())
    e = re.sub(r"\b0([0-7]+)\b", r"0o\1", e)
    e = re.sub(r"\(\s*(?:long long|unsigned long long|long|int)\s*\)", "", e)
    return int(eval(e, {"__builtins__": {}}, names))

def constants(src):
    names = dict(LIMITS, **SYSLOG)
    texts = [(src / "src" / f).read_text() for f in ("server.h", "config.c")]
    for t in texts:
        for m in re.finditer(r"^#define\s+(\w+)\s+(.+?)(?:/\*.*)?$", t, re.M):
            names.setdefault(m.group(1), m.group(2).strip())
        for m in re.finditer(r"\benum\b[^{;]*\{([^}]*)\}", t):
            v = -1
            for item in m.group(1).split(","):
                item = re.sub(r"/\*.*?\*/|//.*", "", item, flags=re.S).strip()
                if not item:
                    continue
                if "=" in item:
                    k, x = item.split("=", 1)
                    k = k.strip()
                    names[k] = x.strip()
                    try:
                        v = c_eval(x, {})
                    except Exception:
                        v = None
                else:
                    k = item
                    v = None if v is None else v + 1
                    names.setdefault(k, v)
    resolved = {}
    def val(k, depth=0):
        if k in resolved:
            return resolved[k]
        x = names[k]
        if isinstance(x, int):
            resolved[k] = x
            return x
        if depth > 20:
            raise ValueError(k)
        expr = re.sub(r"\b[A-Za-z_]\w*\b", lambda m: str(val(m.group(0), depth + 1)) if m.group(0) in names else m.group(0), x)
        resolved[k] = c_eval(expr, {})
        return resolved[k]
    return lambda expr: c_eval(re.sub(r"\b[A-Za-z_]\w*\b", lambda m: str(val(m.group(0))) if m.group(0) in names else m.group(0), expr), {})

def split_args(s):
    out, depth, cur, q = [], 0, "", None
    i = 0
    while i < len(s):
        c = s[i]
        if q:
            cur += c
            if c == "\\":
                cur += s[i + 1]
                i += 1
            elif c == q:
                q = None
        elif c in "\"'":
            q = c
            cur += c
        elif c in "({[":
            depth += 1
            cur += c
        elif c in ")}]":
            depth -= 1
            cur += c
        elif c == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
        else:
            cur += c
        i += 1
    if cur.strip():
        out.append(cur.strip())
    return out

def calls(body):
    i = 0
    while True:
        m = re.compile(r"create(\w+)Config\(").search(body, i)
        if not m:
            return
        j, depth = m.end(), 1
        while depth:
            depth += {"(": 1, ")": -1}.get(body[j], 0)
            j += 1
        yield m.group(1), split_args(body[m.end():j - 1])
        i = j

def c_str(x):
    return None if x == "NULL" else json.loads(x)

def flag_set(expr):
    return sorted({w.removesuffix("_CONFIG").lower() for w in re.findall(r"\b(\w+_CONFIG)\b", expr)} - {"modifiable"})

def enum_table(text, name, ev):
    m = re.search(r"configEnum\s+%s\[\]\s*=\s*\{(.*?)\n\};" % name, text, re.S)
    return [(n, ev(v)) for n, v in re.findall(r'\{\s*"([^"]+)"\s*,\s*([^}]+?)\s*\}', m.group(1))]

def enum_name(entries, value, bits):
    names, unmatched = [], value
    for n, v in entries:
        if value == v:
            return n
        if bits and v and v == (unmatched & v):
            names.append(n)
            unmatched &= ~v
    return " ".join(names) if names and not unmatched else "unknown"

NUMERIC = {"Int": True, "UInt": False, "LongLong": True, "ULong": False, "ULongLong": False,
           "SizeT": False, "SSizeT": True, "TimeT": True, "OffT": True}
SPECIAL = {"dir": ("dir", ""), "save": ("save", "3600 1 300 100 60 10000"),
           "client-output-buffer-limit": ("obuf", "normal 0 0 0 slave 268435456 67108864 60 pubsub 33554432 8388608 60"),
           "oom-score-adj-values": ("oom", "0 200 800"), "notify-keyspace-events": ("notify", ""),
           "bind": ("bind", "* -::*"), "replicaof": ("replicaof", ""),
           "latency-tracking-info-percentiles": ("pct", "50 99 99.9")}

def extract(src):
    text = (src / "src" / "config.c").read_text()
    ev = constants(src)
    start = text.index("standardConfig static_configs[] = {")
    end = text.index("{NULL}", start)
    out = []
    for kind, a in calls(text[start:end]):
        e = {"name": c_str(a[0]), "alias": c_str(a[1]) or "", "flags": flag_set(a[2])}
        if kind == "Bool":
            e.update(type="bool", default="yes" if ev(a[4]) else "no", check=a[5], apply=a[6])
        elif kind in ("String", "SDS"):
            e.update(type="string", null=a[3] == "EMPTY_STRING_IS_NULL",
                     default=c_str(a[5]) if a[5] != "NULL" and not a[5].startswith("CONFIG_") else
                     (json.loads(re.search(r'#define\s+%s\s+(".*")' % a[5], (src / "src" / "server.h").read_text()).group(1)) if a[5] != "NULL" else ""),
                     check=a[6], apply=a[7])
        elif kind == "Enum":
            entries = enum_table(text, a[3], ev)
            bits = "multi_arg" in e["flags"]
            e.update(type="enum", names=[n for n, _ in entries], values=[v for _, v in entries], bits=bits,
                     default=enum_name(entries, ev(a[5]), bits), check=a[6], apply=a[7])
        elif kind in NUMERIC:
            nflags = {w.removesuffix("_CONFIG").lower() for w in re.findall(r"\b(\w+_CONFIG)\b", a[7])} - {"integer"}
            d = ev(a[6])
            if "percent" in nflags and d < 0:
                shown = f"{-d}%"
            elif "octal" in nflags:
                shown = format(d, "o")
            else:
                shown = str(d)
            e.update(type="num", signed=NUMERIC[kind], lo=str(ev(a[3])), hi=str(ev(a[4])),
                     fmt=sorted(nflags), default=shown, check=a[8], apply=a[9])
        elif kind == "Special":
            sk, d = SPECIAL[e["name"]]
            e.update(type="special", special=sk, default=d, apply=a[6])
        else:
            raise SystemExit(f"unknown config kind {kind}")
        out.append(e)
    return out

# Step 2: facts -> Bend
# ---------------------

def bstr(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

def bbool(b):
    return "True{}" if b else "False{}"

def blist(xs):
    return "[" + ", ".join(xs) + "]"

FMT = {(): "NPlain{}", ("memory",): "NMem{}", ("memory", "percent"): "NMemPct{}", ("octal",): "NOct{}"}
CHECK = {"NULL": "VNone{}", "isValidDBfilename": "VFile{}", "isValidAOFfilename": "VAofFile{}",
         "isValidAOFdirname": "VAofDir{}", "isValidAnnouncedHostname": "VHost{}",
         "isValidProcTitleTemplate": "VTitle{}", "isValidShutdownOnSigFlags": "VSig{}",
         "isValidActiveDefrag": "VDefrag{}"}
SPEC = {"dir": "XDir{}", "save": "XSave{}", "obuf": "XObuf{}", "oom": "XOom{}", "notify": "XNotify{}",
        "bind": "XBind{}", "replicaof": "XReplicaof{}", "pct": "XPct{}"}

def ty(e):
    t = e["type"]
    if t == "bool":
        return f"CBool{{{CHECK[e['check']]}}}"
    if t == "string":
        return f"CStr{{{bbool(e['null'])}, {CHECK[e['check']]}}}"
    if t == "enum":
        return (f"CEnum{{{blist(bstr(n) for n in e['names'])}, {blist(str(v) for v in e['values'])}, "
                f"{bbool(e['bits'])}, {CHECK[e['check']]}}}")
    if t == "num":
        return f"CNum{{{bbool(e['signed'])}, {bstr(e['lo'])}, {bstr(e['hi'])}, {FMT[tuple(e['fmt'])]}}}"
    return f"CSpec{{{SPEC[e['special']]}}}"

def block(facts):
    out = ["# every parameter of Redis 7.0.15 (built with TLS, as distributions build it), in the order of",
           "# Redis's table, each with its value when the server starts (written by",
           "# tools/gen_config.py from tools/data/redis-configs.json)",
           "def config.table() -> List<&2, CItem>:",
           "  ["]
    rows = []
    for e in facts:
        f = set(e["flags"])
        p = (f"CParam{{{bstr(e['name'])}, {bstr(e['alias'])}, {bbool('immutable' in f)}, {bbool('hidden' in f)}, "
             f"{bbool('protected' in f)}, {bbool('multi_arg' in f)}, {ty(e)}, {APPLY_BY_NAME.get(e['name'], APPLY.get(e['apply'], 'AppNone{}'))}}}")
        rows.append(f"    CItem{{{p}, {bstr(DEFAULTS.get(e['name'], e['default']))}}}")
    return out + [",\n".join(rows), "  ]"]

def fill(check):
    facts = json.loads(JSON.read_text())
    text = BEND.read_text()
    pat = re.compile(r"(?ms)^(# BEGIN gen_config: table\n).*?^(# END gen_config: table\n)")
    if not pat.search(text):
        sys.exit(f"{BEND.name}: no block table")
    new = pat.sub(lambda m: m.group(1) + "\n".join(block(facts)) + "\n" + m.group(2), text)
    if check:
        if new != text:
            sys.exit(f"{BEND.name} is out of date: run tools/gen_config.py")
    else:
        BEND.write_text(new)

if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "--extract":
        JSON.parent.mkdir(exist_ok=True)
        JSON.write_text(json.dumps(extract(pathlib.Path(sys.argv[2])), indent=1) + "\n")
    else:
        fill("--check" in sys.argv)
