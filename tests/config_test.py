#!/usr/bin/env python3
"""CONFIG, BendKV against Redis: the same commands go to both servers, and
the replies must be the same, byte for byte, except that CONFIG GET's
reply is compared as a map (Redis sends its keys in the order of a hash
table). First every parameter as the servers start (but the port); then
a list of cases, each type of parameter and each error; then random
values for every parameter that changes, each set and read back on both;
then every parameter is put back as it was.

The reference Redis runs as run_tests.sh starts it: one database, no
snapshots, on the loopback (--databases 1 --save '' --bind 127.0.0.1).
Parameters whose new value Redis would act on in a way that disturbs the
test or the machine (the port, the addresses, the append-only file, the
password, the client limits, the snapshots) are left out of the random
part; Redis's maxclients also depends on the open-file limit of the
machine, which BendKV does not check.

    python3 tests/config_test.py --bendkv 6380 --redis 6390 [--rounds 3000]
"""
import argparse
import json
import pathlib
import random
import socket

HERE = pathlib.Path(__file__).resolve().parent.parent


class Client:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=5)
        self.buf = b""

    def send(self, *args):
        out = b"*%d\r\n" % len(args)
        for a in args:
            a = a if isinstance(a, bytes) else a.encode()
            out += b"$%d\r\n%s\r\n" % (len(a), a)
        self.s.sendall(out)
        raw = self.read_raw()
        return raw

    def fill(self):
        chunk = self.s.recv(1 << 16)
        if not chunk:
            raise ConnectionError("closed")
        self.buf += chunk

    def line(self):
        while b"\r\n" not in self.buf:
            self.fill()
        i = self.buf.index(b"\r\n")
        line, self.buf = self.buf[:i + 2], self.buf[i + 2:]
        return line

    def read_raw(self):
        line = self.line()
        if line[:1] == b"$":
            n = int(line[1:-2])
            if n < 0:
                return line
            while len(self.buf) < n + 2:
                self.fill()
            data, self.buf = self.buf[:n + 2], self.buf[n + 2:]
            return line + data
        if line[:1] == b"*":
            n = int(line[1:-2])
            return line + b"".join(self.read_raw() for _ in range(max(n, 0)))
        return line


def parse(raw):
    """A reply as Python values, for CONFIG GET's map."""
    def go(i):
        t, j = raw[i:i + 1], raw.index(b"\r\n", i)
        head = raw[i + 1:j]
        if t == b"$":
            n = int(head)
            if n < 0:
                return None, j + 2
            return raw[j + 2:j + 2 + n], j + 4 + n
        if t == b"*":
            out, k = [], j + 2
            for _ in range(int(head)):
                x, k = go(k)
                out.append(x)
            return out, k
        return raw[i:j], j + 2
    return go(0)[0]


def as_map(raw):
    xs = parse(raw)
    if not isinstance(xs, list):
        return raw
    keys = xs[0::2]
    if len(set(k.lower() for k in keys)) != len(keys):
        return ("duplicate keys", raw)
    return dict(zip(keys, xs[1::2]))


def same(cmd, a, b):
    if cmd[0].upper() == "CONFIG" and len(cmd) > 1 and cmd[1].upper() == "GET":
        return as_map(a) == as_map(b)
    return a == b


# A parameter is left out of the random part when Redis would act on its new
# value in a way that changes what the test sees or the machine (or when it
# is hidden); the cases cover the errors these give.
SKIP = {"port", "bind", "appendonly", "requirepass", "save", "client-output-buffer-limit",
        "maxmemory-clients", "timeout", "maxclients", "dir", "dbfilename", "maxmemory",
        "replicaof", "slaveof", "tls-port", "tls-replication", "tls-cluster", "oom-score-adj",
        "oom-score-adj-values"}

CASES = [
    ["CONFIG", "GET", "maxmemory"],
    ["CONFIG", "GET", "MAXMEMORY"],
    ["CONFIG", "GET", "maxmemory", "MAXMEMORY", "maxmemory*"],
    ["CONFIG", "GET", "maxmemory", "maxmemory*", "bind", "*of"],
    ["CONFIG", "GET", "*of", "slaveof"],
    ["CONFIG", "GET", "slaveof", "*of"],
    ["CONFIG", "GET", "key-load-delay"],
    ["CONFIG", "GET", "*load-delay*"],
    ["CONFIG", "GET", "nosuch"],
    ["CONFIG", "GET", "[a-c]*"],
    ["CONFIG", "GET", "[^a-z]*"],
    ["CONFIG", "GET", "?z"],
    ["CONFIG", "GET", "*max*", "*MAX*"],
    ["CONFIG", "GET", "list-max-ziplist-size"],
    ["CONFIG", "GET", "LIST-MAX-ZIPLIST-SIZE", "list-max-listpack-size"],
    ["CONFIG", "GET"],
    ["CONFIG"],
    ["CONFIG", "NOPE"],
    ["CONFIG", "HELP"],
    ["CONFIG", "HELP", "x"],
    ["CONFIG", "RESETSTAT"],
    ["CONFIG", "RESETSTAT", "x"],
    ["CONFIG", "REWRITE"],
    ["CONFIG", "SET", "maxmemory"],
    ["CONFIG", "SET", "maxmemory", "1", "hz"],
    ["CONFIG", "SET", "nosuch", "1"],
    ["CONFIG", "SET", "maxmemory", "10000001", "nosuch", "1"],
    ["CONFIG", "SET", "daemonize", "yes"],
    ["CONFIG", "SET", "nosuch", "1", "daemonize", "yes"],
    ["CONFIG", "SET", "daemonize", "yes", "nosuch", "1"],
    ["CONFIG", "SET", "maxmemory", "1", "maxmemory", "2"],
    ["CONFIG", "SET", "maxmemory", "1", "MAXMEMORY", "2"],
    ["CONFIG", "SET", "dir", "/tmp"],
    ["CONFIG", "SET", "dbfilename", "a.rdb"],
    ["CONFIG", "SET", "maxmemory", "10000002"],
    ["CONFIG", "SET", "maxmemory", "10000001", "maxmemory-clients", "200%", "client-query-buffer-limit", "invalid"],
    ["CONFIG", "GET", "maxmemory", "maxmemory-clients", "client-query-buffer-limit"],
    ["CONFIG", "SET", "maxmemory", "10000001", "repl-backlog-size", "10000002", "save", "3000 5"],
    ["CONFIG", "GET", "maxmemory", "repl-backlog-size", "save"],
    ["CONFIG", "SET", "save", ""],
    ["CONFIG", "SET", "save", "3600 1 300 100 60 10000"],
    ["CONFIG", "SET", "save", "3600 1 300"],
    ["CONFIG", "SET", "save", "0 1"],
    ["CONFIG", "SET", "save", "1 -1"],
    ["CONFIG", "SET", "save", "+0100 007"],
    ["CONFIG", "GET", "save"],
    ["CONFIG", "SET", "save", "3600 "],
    ["CONFIG", "GET", "save"],
    ["CONFIG", "SET", "save", "3600  1"],
    ["CONFIG", "SET", "save", ""],
    ["CONFIG", "SET", "maxmemory", "0"],
    ["CONFIG", "SET", "maxmemory", "1kb"],
    ["CONFIG", "GET", "maxmemory"],
    ["CONFIG", "SET", "maxmemory", "18446744073709551615"],
    ["CONFIG", "GET", "maxmemory"],
    ["CONFIG", "SET", "maxmemory", "18446744073709551616"],
    ["CONFIG", "GET", "maxmemory"],
    ["CONFIG", "SET", "maxmemory", "-1"],
    ["CONFIG", "SET", "maxmemory", "1.5"],
    ["CONFIG", "SET", "maxmemory", "0"],
    ["CONFIG", "SET", "maxmemory-clients", "0%"],
    ["CONFIG", "GET", "maxmemory-clients"],
    ["CONFIG", "SET", "maxmemory-clients", "100%"],
    ["CONFIG", "GET", "maxmemory-clients"],
    ["CONFIG", "SET", "maxmemory-clients", "101%"],
    ["CONFIG", "SET", "maxmemory-clients", "18446744073709551615"],
    ["CONFIG", "GET", "maxmemory-clients"],
    ["CONFIG", "SET", "maxmemory-clients", "9223372036854775808"],
    ["CONFIG", "SET", "maxmemory-clients", "-5"],
    ["CONFIG", "SET", "maxmemory-clients", "0"],
    ["CONFIG", "SET", "port", "BUSY_PORT"],
    ["CONFIG", "SET", "bind", "1.2.3.4"],
    ["CONFIG", "SET", "appendonly", "maybe"],
    ["CONFIG", "SET", "timeout", "0"],
    ["CONFIG", "SET", "client-output-buffer-limit", "normal 1 2"],
    ["CONFIG", "SET", "client-output-buffer-limit", "master 1 2 3"],
    ["CONFIG", "SET", "client-output-buffer-limit", "pubsub 1x 2 3"],
    ["CONFIG", "SET", "client-output-buffer-limit", "pubsub 1mb 2kb 3 REPLICA 4 5 6"],
    ["CONFIG", "GET", "client-output-buffer-limit"],
    ["CONFIG", "SET", "client-output-buffer-limit", "pubsub 1 2 -3"],
    ["CONFIG", "SET", "client-output-buffer-limit", "normal 0 0 0 slave 268435456 67108864 60 pubsub 33554432 8388608 60"],
    ["CONFIG", "SET", "hz", "0"],
    ["CONFIG", "GET", "hz"],
    ["CONFIG", "SET", "hz", "100000"],
    ["CONFIG", "GET", "hz"],
    ["CONFIG", "SET", "hz", "10"],
    ["CONFIG", "SET", "tls-port", "6390"],
    ["CONFIG", "SET", "maxclients", "0"],
    ["CONFIG", "SET", "unixsocketperm", "777"],
    ["CONFIG", "SET", "list-max-ziplist-size", "-3"],
    ["CONFIG", "GET", "list-max-listpack-size", "list-max-ziplist-size"],
    ["CONFIG", "SET", "cluster-announce-hostname", "a" * 256],
    ["CONFIG", "SET", "cluster-announce-hostname", "a_b"],
    ["CONFIG", "SET", "cluster-announce-hostname", "a-b.c"],
    ["CONFIG", "SET", "proc-title-template", "{title}"],
    ["CONFIG", "SET", "proc-title-template", "{nope} x"],
    ["CONFIG", "SET", "proc-title-template", "{{ {port}"],
    ["CONFIG", "SET", "proc-title-template", "{title} {listen-addr} {server-mode}"],
    ["CONFIG", "SET", "notify-keyspace-events", "Kx$"],
    ["CONFIG", "GET", "notify-keyspace-events"],
    ["CONFIG", "SET", "notify-keyspace-events", "Anm"],
    ["CONFIG", "GET", "notify-keyspace-events"],
    ["CONFIG", "SET", "notify-keyspace-events", "Q"],
    ["CONFIG", "SET", "notify-keyspace-events", ""],
    ["CONFIG", "SET", "oom-score-adj-values", "0 200"],
    ["CONFIG", "SET", "oom-score-adj-values", "0 200 2001"],
    ["CONFIG", "SET", "oom-score-adj-values", "-0 +200 0800"],
    ["CONFIG", "GET", "oom-score-adj-values"],
    ["CONFIG", "SET", "oom-score-adj-values", "0 200 800"],
    ["CONFIG", "SET", "latency-tracking-info-percentiles", "0 50.25 99.9999995 100"],
    ["CONFIG", "GET", "latency-tracking-info-percentiles"],
    ["CONFIG", "SET", "latency-tracking-info-percentiles", "1e2 .5 5. -0"],
    ["CONFIG", "GET", "latency-tracking-info-percentiles"],
    ["CONFIG", "SET", "latency-tracking-info-percentiles", "101"],
    ["CONFIG", "SET", "latency-tracking-info-percentiles", "-1"],
    ["CONFIG", "SET", "latency-tracking-info-percentiles", "inf"],
    ["CONFIG", "SET", "latency-tracking-info-percentiles", "nan"],
    ["CONFIG", "SET", "latency-tracking-info-percentiles", "x"],
    ["CONFIG", "SET", "latency-tracking-info-percentiles", ""],
    ["CONFIG", "GET", "latency-tracking-info-percentiles"],
    ["CONFIG", "SET", "latency-tracking-info-percentiles", "50 99 99.9"],
    ["CONFIG", "SET", "shutdown-on-sigterm", "save nosave"],
    ["CONFIG", "SET", "shutdown-on-sigterm", "NOW force"],
    ["CONFIG", "GET", "shutdown-on-sigterm"],
    ["CONFIG", "SET", "shutdown-on-sigterm", "now  force"],
    ["CONFIG", "SET", "shutdown-on-sigterm", ""],
    ["CONFIG", "SET", "shutdown-on-sigterm", "default"],
    ["CONFIG", "SET", "oom-score-adj", "relative"],
    ["CONFIG", "GET", "oom-score-adj"],
    ["CONFIG", "SET", "oom-score-adj", "no"],
    ["CONFIG", "SET", "maxmemory-policy", "allkeys lru"],
    ["CONFIG", "SET", "maxmemory-policy", "ALLKEYS-LRU"],
    ["CONFIG", "GET", "maxmemory-policy"],
    ["CONFIG", "SET", "maxmemory-policy", "noeviction"],
    ["CONFIG", "SET", "activerehashing", "maybe"],
    ["CONFIG", "SET", "activerehashing", "NO"],
    ["CONFIG", "GET", "activerehashing"],
    ["CONFIG", "SET", "activerehashing", "yes"],
    ["CONFIG", "SET", "list-max-listpack-size", "007"],
    ["CONFIG", "SET", "list-max-listpack-size", "-2147483649"],
    ["CONFIG", "SET", "list-max-listpack-size", "-2147483648"],
    ["CONFIG", "GET", "list-max-listpack-size"],
    ["CONFIG", "SET", "list-max-listpack-size", "-2"],
    ["CONFIG", "SET", "requirepass", "", "masterauth", "x"],
    ["CONFIG", "GET", "requirepass", "masterauth"],
    ["CONFIG", "SET", "masterauth", ""],
]


def rand_num(e, rnd):
    lo, hi = int(e["lo"]), int(e["hi"])
    fmt = set(e["fmt"])
    picks = [str(lo), str(hi), str(lo - 1), str(hi + 1), str(rnd.randint(lo, min(hi, lo + 1000))),
             str(rnd.randint(lo, hi)), "0" + str(rnd.randint(0, 99)), "-" + str(rnd.randint(0, 99)),
             "", "x", "1.5", "+1", " 1", str(rnd.randint(0, 10 ** 25)), "9223372036854775807",
             "9223372036854775808", "-9223372036854775808", "18446744073709551615", "18446744073709551616"]
    if "memory" in fmt:
        for _ in range(6):
            picks.append(str(rnd.choice([0, 1, 7, 1000, 1024, rnd.randint(0, 10 ** 12), rnd.randint(0, 10 ** 20)]))
                         + rnd.choice(["", "b", "k", "kb", "m", "mb", "g", "gb", "KB", "Gb", "x", "kbb"]))
        picks += ["k", "kb", "0kb", "-1kb", "18014398509481983kb", "18014398509481984kb"]
    if "percent" in fmt:
        picks += ["0%", "5%", "100%", "101%", "05%", "%", "-5%", "18446744073709551515", "18446744073709551516",
                  "18446744073709551600"]
    if "octal" in fmt:
        picks += ["0777", "777", "1000", "8", "0"]
    return rnd.choice(picks)


def rand_case(w, rnd):
    return "".join(c.upper() if rnd.random() < 0.3 else c for c in w)


def rand_value(e, rnd):
    t = e["type"]
    if t == "bool":
        return rnd.choice(["yes", "no", "YES", "No", "y", "1", "", "maybe"])
    if t == "enum":
        names = e["names"]
        if e["bits"]:
            ws = [rand_case(rnd.choice(names + ["bad"]), rnd) for _ in range(rnd.randint(0, 3))]
            return " ".join(ws)
        return rnd.choice([rand_case(rnd.choice(names), rnd), rand_case(rnd.choice(names), rnd), "nope", "",
                           names[0] + " " + names[-1]])
    if t == "num":
        return rand_num(e, rnd)
    if t == "string":
        return rnd.choice(["", "abc", "a/b", "a\\b", "x" * rnd.randint(250, 260), "a_b", "a-b.c",
                           "{title}", "{port} {title}", "{{x", "{x", "{", "}", "redis {listen-addr}",
                           "  {server-mode} ", "\t{title}"])
    sk = e["special"]
    if sk == "oom":
        return " ".join(str(rnd.randint(-2500, 2500)) for _ in range(rnd.choice([3, 3, 3, 2, 4])))
    if sk == "notify":
        return "".join(rnd.choice("Ag$lshzxeKEtmdnQ") for _ in range(rnd.randint(0, 5)))
    if sk == "pct":
        def one():
            return rnd.choice([str(rnd.randint(0, 100)), "%d.%d" % (rnd.randint(0, 100), rnd.randint(0, 999999)),
                               "%de%d" % (rnd.randint(0, 20), rnd.randint(-3, 2)), "-0", "0.00000051", "100.0000001",
                               "inf", "nan", "x", "", ".5", "5.", "1e", "+3"])
        return " ".join(one() for _ in range(rnd.randint(0, 3)))
    return "x"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, default=6380)
    ap.add_argument("--redis", type=int, default=6390)
    ap.add_argument("--rounds", type=int, default=3000)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    mine, theirs = Client(a.bendkv), Client(a.redis)
    ok = True

    def both(cmd, show=True):
        nonlocal ok
        x, y = mine.send(*cmd), theirs.send(*cmd)
        good = same(cmd, x, y)
        ok &= good
        if not good and show:
            print("FAIL %r" % (cmd,))
            print("     bendkv: %r" % (x[:300],))
            print("     redis:  %r" % (y[:300],))
        return good

    # every parameter as the servers start, but the port
    start_m = as_map(mine.send("CONFIG", "GET", "*"))
    start_t = as_map(theirs.send("CONFIG", "GET", "*"))
    start_m.pop(b"port", None)
    start_t.pop(b"port", None)
    if start_m == start_t:
        print("ok   CONFIG GET *: %d parameters, the same values" % len(start_t))
    else:
        ok = False
        for k in sorted(set(start_m) | set(start_t)):
            if start_m.get(k) != start_t.get(k):
                print("FAIL CONFIG GET * %r: bendkv %r, redis %r" % (k, start_m.get(k), start_t.get(k)))

    # a port in use, which neither server can move to
    busy = socket.socket()
    busy.bind(("127.0.0.1", 0))
    busy.listen(1)
    good = sum(both([w.replace("BUSY_PORT", str(busy.getsockname()[1])) for w in c]) for c in CASES)
    busy.close()
    print("%s %d of %d cases" % ("ok  " if good == len(CASES) else "FAIL", good, len(CASES)))

    # random values for the parameters that change
    facts = json.loads((HERE / "tools" / "data" / "redis-configs.json").read_text())
    params = [e for e in facts if "immutable" not in e["flags"] and "hidden" not in e["flags"]
              and e["name"] not in SKIP]
    rnd = random.Random(a.seed)
    bad = 0
    for _ in range(a.rounds):
        e = rnd.choice(params)
        name = rnd.choice([e["name"], e["alias"] or e["name"], e["name"].upper()])
        v = rand_value(e, rnd)
        if not (both(["CONFIG", "SET", name, v], bad < 20) and both(["CONFIG", "GET", e["name"]], bad < 20)):
            bad += 1
    print("%s %d random CONFIG SET and GET, %d differ" % ("ok  " if bad == 0 else "FAIL", a.rounds, bad))

    # every parameter back as it was
    for k, v in start_t.items():
        name = k.decode()
        if name in ("port", "slaveof", "replicaof") or name in SKIP and name not in ("maxmemory", "maxmemory-clients", "timeout", "save"):
            continue
        mine.send("CONFIG", "SET", name, v)
        theirs.send("CONFIG", "SET", name, v)
    print("ALL OK" if ok else "SOME CHECKS FAILED")
    return ok


if __name__ == "__main__":
    raise SystemExit(0 if main() else 1)
