#!/usr/bin/env python3
"""The timing of calls against Redis: SLOWLOG, LATENCY, INFO's usec and
latencystats.

Scenarios run on BendKV and on Redis with clients of their own, the
transcripts compared line by line. What a call took differs from one
server to the other, so a transcript keeps what does not depend on it:
an entry of the slow log is its id (from the first's), its time (within
the scenario's seconds), its arguments, its client's address (the
client's own, by its port) and name, and its duration only as a number;
a command's histogram its calls and its levels' order; a percentile only
as a number.

- SLOWLOG's and LATENCY's errors, arities and HELP, in RESP2 and RESP3.
- The slow log with slowlog-log-slower-than 0: every call logged, with
  its arguments as sent (32 at most, 128 bytes each), the passwords of
  AUTH, HELLO's AUTH and CONFIG SET's sensitive parameters redacted, a
  command rewritten for the file logged as it came (SPOP, GETSET, a
  served BLPOP), EXEC's commands but not EXEC; SLOWLOG GET of counts,
  LEN, RESET (whose own entry comes after), slowlog-max-len cutting the
  oldest, and a threshold no call reaches.
- LATENCY with no event: LATEST, HISTORY, RESET, GRAPH's error, DOCTOR's
  two texts (the monitor off; on with nothing seen), its advice about
  transparent huge pages aside, which depends on each process.
- LATENCY HISTOGRAM after CONFIG RESETSTAT (which it shows, as Redis
  times a call after it ran), of all commands, of some, of a container
  and of one of its subcommands, of names unknown.
- INFO latencystats with latency-tracking on and off, with
  latency-tracking-info-percentiles' labels, and after CONFIG RESETSTAT;
  commandstats' usec and usec_per_call ((float)usec / calls, "%.2f").

    python3 tests/timing_test.py --bendkv 6380 --redis 6390
"""
import argparse
import re
import socket
import struct
import sys
import time


def enc(args):
    out = b"*%d\r\n" % len(args)
    for a in args:
        a = a.encode() if isinstance(a, str) else a
        out += b"$%d\r\n%s\r\n" % (len(a), a)
    return out


class Client:
    """A connection that reads RESP2 and RESP3: a map as a dict, a set
    and a push as a list, a verbatim string as its text."""

    def __init__(self, port):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=10)
        self.buf = b""

    def port(self):
        return self.sock.getsockname()[1]

    def _line(self):
        while b"\r\n" not in self.buf:
            data = self.sock.recv(1 << 16)
            if not data:
                raise EOFError("connection closed")
            self.buf += data
        line, self.buf = self.buf.split(b"\r\n", 1)
        return line

    def _bulk(self, n):
        while len(self.buf) < n + 2:
            data = self.sock.recv(1 << 16)
            if not data:
                raise EOFError("connection closed")
            self.buf += data
        data, self.buf = self.buf[:n], self.buf[n + 2:]
        return data.decode(errors="replace")

    def read(self):
        line = self._line()
        kind, rest = line[:1], line[1:].decode()
        if kind in (b"+", b"-"):
            return kind.decode() + rest
        if kind == b":":
            return int(rest)
        if kind in (b"$", b"="):
            n = int(rest)
            if n < 0:
                return None
            s = self._bulk(n)
            return s[4:] if kind == b"=" else s
        if kind in (b"*", b"~", b">"):
            n = int(rest)
            return None if n < 0 else [self.read() for _ in range(n)]
        if kind == b"%":
            items = [self.read() for _ in range(2 * int(rest))]
            return {"%": items}
        if kind == b"_":
            return None
        return "?" + line.decode()

    def cmd(self, *args):
        self.sock.sendall(enc(args))
        return self.read()

    def close(self):
        self.sock.close()


def pairs(r):
    """a map's keys and values in turn (RESP3), or an array's (RESP2)"""
    return r["%"] if isinstance(r, dict) else r


def info(c, section):
    out = {}
    for line in c.cmd("INFO", section).split("\r\n"):
        if ":" in line and not line.startswith("#"):
            k, v = line.split(":", 1)
            out[k] = v
    return out


def entries(c, t0, t1):
    """the slow log, oldest first, each entry as the transcript keeps it
    (its id from the first's)"""
    log = c.cmd("SLOWLOG", "GET", "-1")
    out = []
    first = None
    for e in reversed(log):
        eid, at, us, args, peer, name = e
        first = eid if first is None else first
        ok = isinstance(us, int) and us >= 0 and t0 - 1 <= at <= t1 + 1
        out.append([eid - first, "ok" if ok else "BAD %r %r" % (at, us), args, peer.rsplit(":", 1)[1], name])
    return out


def peer_port(e, ports):
    """an entry's client named by which of the scenario's clients it is"""
    return [ports.get(e[3], "other:" + e[3]) if i == 3 else x for i, x in enumerate(e)]


def errors_help(port, log):
    c = Client(port)
    for proto in ("2", "3"):
        c.cmd("HELLO", proto)
        for args in (["SLOWLOG"], ["SLOWLOG", "foo"], ["SLOWLOG", "GET", "-2"], ["SLOWLOG", "GET", "abc"],
                     ["SLOWLOG", "GET", "-0"], ["SLOWLOG", "GET", "007"], ["SLOWLOG", "GET", "1", "2"],
                     ["SLOWLOG", "GET", "9223372036854775808"], ["SLOWLOG", "LEN", "x"],
                     ["SLOWLOG", "RESET", "x"], ["SLOWLOG", "HELP", "x"], ["SLOWLOG", "help"],
                     ["slowlog", "Get", "0"], ["LATENCY"], ["LATENCY", "foo"], ["LATENCY", "HELP"],
                     ["LATENCY", "help", "xxx"], ["LATENCY", "LATEST", "x"], ["LATENCY", "DOCTOR", "x"],
                     ["LATENCY", "HISTORY"], ["LATENCY", "HISTORY", "a", "b"], ["LATENCY", "GRAPH"],
                     ["LATENCY", "GRAPH", "command"], ["LATENCY", "GRAPH", "x\r\ny"],
                     ["LATENCY", "HISTORY", "command"], ["LATENCY", "RESET", "a", "b"]):
            log("help " + proto, args, c.cmd(*args))
    c.close()


def slowlog(port, log):
    c, d, e = Client(port), Client(port), Client(port)
    ports = {str(c.port()): "c", str(d.port()): "d", str(e.port()): "e"}
    c.cmd("CONFIG", "SET", "slowlog-max-len", "128")
    c.cmd("CONFIG", "SET", "slowlog-log-slower-than", "0")
    c.cmd("SLOWLOG", "RESET")
    t0 = time.time()
    c.cmd("SET", "tm:a", "1")
    c.cmd("CLIENT", "SETNAME", "foobar")
    c.cmd("GET", "tm:a")
    c.cmd("SADD", "tm:set", *[str(i) for i in range(3, 34)])
    c.cmd("SADD", "tm:set", "foo", "A" * 129)
    c.cmd("SADD", "tm:set2", *[str(i) for i in range(30)])
    c.cmd("SPOP", "tm:set", "100")
    c.cmd("SET", "tm:A", "5")
    c.cmd("GETSET", "tm:A", "6")
    c.cmd("AUTH", "pw")
    c.cmd("AUTH", "user", "pw")
    c.cmd("AUTH", "a", "b", "c")
    c.cmd("HELLO", "2", "AUTH", "default", "pw")
    c.cmd("HELLO", "2", "SETNAME", "foobar")
    c.cmd("CONFIG", "SET", "masterauth", "")
    c.cmd("CONFIG", "SET", "masteruser", "")
    c.cmd("CONFIG", "SET", "requirepass", "")
    c.cmd("CONFIG", "SET", "maxmemory-samples", "5", "MASTERAUTH", "")
    c.cmd("CONFIG", "SET", "nosuch", "x", "masterauth", "")
    c.cmd("MULTI")
    c.cmd("SET", "tm:b", "2")
    c.cmd("GET", "tm:b")
    c.cmd("EXEC")
    c.cmd("DEL", "tm:l")
    d.sock.sendall(enc(["BLPOP", "tm:l", "0"]))
    for _ in range(300):
        if info(e, "clients").get("blocked_clients") == "1":
            break
        time.sleep(0.01)
    c.cmd("LPUSH", "tm:l", "foo")
    log("blpop", d.read())
    c.cmd("CONFIG", "SET", "slowlog-log-slower-than", "-1")
    t1 = time.time()
    for x in entries(c, t0, t1):
        if ports.get(x[3]) != "e":
            log("slowlog", peer_port(x, ports))
    log("len", c.cmd("SLOWLOG", "LEN"))
    log("get 0", len(c.cmd("SLOWLOG", "GET", "0")), "get 1", len(c.cmd("SLOWLOG", "GET", "1")),
        "get", len(c.cmd("SLOWLOG", "GET")), "get 5", len(c.cmd("SLOWLOG", "GET", "5")))
    # RESET, its own entry after it, and max-len cutting the oldest
    c.cmd("CONFIG", "SET", "slowlog-log-slower-than", "0")
    c.cmd("SLOWLOG", "RESET")
    c.cmd("CONFIG", "SET", "slowlog-max-len", "3")
    for k in ("x", "y", "z", "w"):
        c.cmd("SET", "tm:" + k, k)
    c.cmd("CONFIG", "SET", "slowlog-log-slower-than", "-1")
    for x in entries(c, t0, time.time()):
        log("cut", peer_port(x, ports))
    # a threshold no call of the scenario reaches, then none
    c.cmd("CONFIG", "SET", "slowlog-max-len", "128")
    c.cmd("SLOWLOG", "RESET")
    c.cmd("CONFIG", "SET", "slowlog-log-slower-than", "10000000")
    c.cmd("SET", "tm:x", "1")
    log("high", c.cmd("SLOWLOG", "LEN"))
    c.cmd("CONFIG", "SET", "slowlog-log-slower-than", "10000")
    c.cmd("CLIENT", "SETNAME", "")
    c.cmd("DEL", "tm:a", "tm:set", "tm:set2", "tm:A", "tm:b", "tm:l", "tm:x", "tm:y", "tm:z", "tm:w")
    c.close()
    d.close()
    e.close()


DOCTOR_THP = re.compile(r"- I detected a non zero amount of anonymous huge pages[^\n]*\n")


def latency(port, log):
    c = Client(port)
    c.cmd("CONFIG", "SET", "latency-monitor-threshold", "0")
    log("reset", c.cmd("LATENCY", "RESET"))
    log("latest", c.cmd("LATENCY", "LATEST"))
    log("history", c.cmd("LATENCY", "HISTORY", "command"))
    log("graph", c.cmd("LATENCY", "GRAPH", "command"))
    log("doctor off", c.cmd("LATENCY", "DOCTOR"))
    c.cmd("CONFIG", "SET", "latency-monitor-threshold", "100000")
    doc = DOCTOR_THP.sub("", c.cmd("LATENCY", "DOCTOR"))
    log("doctor on", doc.replace("\nI have a few advices for you:\n\n", "") if doc.endswith("advices for you:\n\n") else doc)
    log("reset", c.cmd("LATENCY", "RESET", "command", "fast-command"))
    c.cmd("CONFIG", "SET", "latency-monitor-threshold", "0")
    c.close()


LEVELS = {1, 2, 4, 8, 16, 33, 66, 132, 264, 528, 1056, 2113, 4227, 8454, 16908, 33816, 67633, 135266,
          270532, 541065, 1073741}


def histogram(r):
    """LATENCY HISTOGRAM's reply: each command's calls, and whether its
    levels are Redis's, growing, and end at its calls"""
    out = []
    xs = pairs(r)
    for name, h in zip(xs[0::2], xs[1::2]):
        h = pairs(h)
        calls, levels = h[1], pairs(h[3])
        keys, counts = levels[0::2], levels[1::2]
        ok = (h[0] == "calls" and h[2] == "histogram_usec" and set(keys) <= LEVELS and keys == sorted(keys)
              and counts == sorted(counts) and counts[-1:] == [calls])
        out.append((name, calls, "ok" if ok else "BAD %r" % (h,)))
    return sorted(out)


def histograms(port, log):
    c = Client(port)
    for proto in ("2", "3"):
        c.cmd("HELLO", proto)
        c.cmd("CONFIG", "SET", "latency-tracking", "yes")
        c.cmd("CONFIG", "RESETSTAT")
        log("empty", proto, histogram(c.cmd("LATENCY", "HISTOGRAM")))
        c.cmd("CONFIG", "RESETSTAT")
        c.cmd("SET", "tm:a", "b")
        c.cmd("SET", "tm:c", "d")
        c.cmd("GET", "tm:a")
        c.cmd("CLIENT", "ID")
        c.cmd("CLIENT", "GETNAME")
        c.cmd("HSET", "tm:h", "k", "v")
        c.cmd("HGETALL", "tm:h")
        c.cmd("GET", "tm:a", "x")
        c.cmd("NOSUCH")
        log("all", proto, histogram(c.cmd("LATENCY", "HISTOGRAM")))
        for names in (["set", "hset"], ["hgetall", "get", "zadd"], ["client"], ["client|id"], ["CLIENT|GETNAME"],
                      ["blabla"], ["blabla", "set", "get"], ["set|x"], ["client|"], ["set", "set"], ["config"]):
            log("some", proto, names, histogram(c.cmd("LATENCY", "HISTOGRAM", *names)))
        c.cmd("DEL", "tm:a", "tm:c", "tm:h")
    c.cmd("HELLO", "2")
    c.close()


def float32(x):
    return struct.unpack("f", struct.pack("f", x))[0]


def latencystats(port, log):
    c = Client(port)
    c.cmd("CONFIG", "RESETSTAT")
    c.cmd("CONFIG", "SET", "latency-tracking", "no")
    c.cmd("SET", "tm:a", "b")
    log("off", sorted(k for k in info(c, "latencystats")))
    c.cmd("CONFIG", "SET", "latency-tracking", "yes")
    for pcts in ("50 99 99.9", "0 50 100", "", "12.5 99.99", "100"):
        c.cmd("CONFIG", "RESETSTAT")
        c.cmd("CONFIG", "SET", "latency-tracking-info-percentiles", pcts)
        c.cmd("SET", "tm:a", "b")
        c.cmd("GET", "tm:a")
        c.cmd("CLIENT", "ID")
        stats = info(c, "latencystats")
        log("pcts", pcts, sorted((k, re.sub(r"=\d+\.\d{3}", "=N", v)) for k, v in stats.items()))
    c.cmd("CONFIG", "SET", "latency-tracking-info-percentiles", "50 99 99.9")
    c.cmd("CONFIG", "RESETSTAT")
    log("reset", sorted(info(c, "latencystats")))
    # commandstats' usec and usec_per_call
    for _ in range(7):
        c.cmd("GET", "tm:a")
    bad = []
    for k, v in info(c, "commandstats").items():
        f = dict(x.split("=") for x in v.split(","))
        calls, usec = int(f["calls"]), int(f["usec"])
        want = "%.2f" % (float32(float32(usec) / float32(calls)) if calls else 0)
        if f["usec_per_call"] != want:
            bad.append((k, v, want))
    log("usec_per_call", bad)
    c.cmd("DEL", "tm:a")
    c.close()


SCENARIOS = [("errors and help", errors_help), ("slow log", slowlog), ("latency events", latency),
             ("histograms", histograms), ("latencystats", latencystats)]


def run(port, scenario):
    out = []
    scenario(port, lambda *xs: out.append(" ".join(repr(x) for x in xs)))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, required=True)
    ap.add_argument("--redis", type=int, required=True)
    a = ap.parse_args()
    fails = 0
    for name, scenario in SCENARIOS:
        got, want = run(a.bendkv, scenario), run(a.redis, scenario)
        diff = [(i, g, w) for i, (g, w) in enumerate(zip(got, want)) if g != w]
        if len(got) != len(want):
            diff.append((min(len(got), len(want)), "%d lines" % len(got), "%d lines" % len(want)))
        if diff:
            fails += 1
            print("FAIL %s: %d of %d lines differ" % (name, len(diff), len(want)))
            for i, g, w in diff[:5]:
                print("  line %d\n    bendkv: %s\n    redis:  %s" % (i, g[:400], w[:400]))
        else:
            print("ok   %s: %d lines" % (name, len(want)))
    if fails:
        sys.exit(1)
    print("TIMING TESTS PASSED")


if __name__ == "__main__":
    main()
