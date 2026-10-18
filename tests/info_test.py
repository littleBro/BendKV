#!/usr/bin/env python3
"""INFO, BendKV against Redis: for each way of picking sections (none,
default, all, everything, each section, several, case aside, unknown
ones, repeats), the same sections in the same order, with the same fields
in the same order; the values that do not depend on the machine or the
moment (versions, modes, parameters, replication, the keyspace) the same;
the counts after CONFIG RESETSTAT (connections taken, commands run)
the same for the same commands on the same connections; and on each, the
event loop's fields as Redis 7.2.16's own tests check them (eventloop).

Left out: the lines of commandstats, errorstats and latencystats, which
Redis lists in the order of a hash table with a random seed
(tests/stats_test.py and tests/timing_test.py compare them as maps).

    python3 tests/info_test.py --bendkv 6380 --redis 6390
"""
import argparse
import socket
import time


class Client:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=5)
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

    def read(self):
        line = self.line()
        if line[:1] == b"$":
            n = int(line[1:])
            if n < 0:
                return None
            while len(self.buf) < n + 2:
                self.buf += self.s.recv(1 << 16)
            v, self.buf = self.buf[:n], self.buf[n + 2:]
            return v
        if line[:1] == b"*":
            return [self.read() for _ in range(int(line[1:]))]
        return line

    def ask(self, *args):
        out = b"*%d\r\n" % len(args)
        for a in args:
            a = a if isinstance(a, bytes) else a.encode()
            out += b"$%d\r\n%s\r\n" % (len(a), a)
        self.s.sendall(out)
        return self.read()

    def close(self):
        self.s.close()


PER_COMMAND = ("cmdstat_", "errorstat_", "latency_percentiles_usec_")


def shape(text):
    """the sections and the names of their fields, in order"""
    out = []
    for line in text.decode().split("\r\n"):
        if line.startswith("#") or line == "":
            out.append(line)
        elif not line.startswith(PER_COMMAND):
            out.append(line.split(":", 1)[0])
    return out


def fields(text):
    out = {}
    for line in text.decode().split("\r\n"):
        if ":" in line and not line.startswith("#"):
            k, v = line.split(":", 1)
            out[k] = v
    return out


# values that do not depend on the machine or the moment
STEADY = ["redis_version", "redis_git_sha1", "redis_git_dirty", "redis_mode", "arch_bits",
          "monotonic_clock", "multiplexing_api", "atomicvar_api", "process_supervised", "hz",
          "configured_hz", "config_file", "io_threads_active", "cluster_connections", "maxclients",
          "blocked_clients", "tracking_clients", "clients_in_timeout_table", "maxmemory",
          "maxmemory_human", "maxmemory_policy", "loading", "async_loading", "rdb_bgsave_in_progress",
          "rdb_last_bgsave_status", "aof_enabled", "aof_rewrite_in_progress", "aof_last_write_status",
          "expired_keys", "evicted_keys", "pubsub_channels", "pubsub_patterns", "role",
          "connected_slaves", "master_failover_state", "master_replid2", "master_repl_offset",
          "second_repl_offset", "repl_backlog_active", "repl_backlog_size", "cluster_enabled",
          "used_cpu_sys_children", "used_cpu_user_children", "mem_replication_backlog",
          "mem_clients_slaves", "active_defrag_running", "lazyfree_pending_objects"]

PICKS = [[], ["default"], ["all"], ["everything"], ["server"], ["clients"], ["memory"],
         ["persistence"], ["stats"], ["replication"], ["cpu"], ["modules"], ["module_list"],
         ["commandstats"], ["errorstats"], ["latencystats"], ["cluster"], ["keyspace"],
         ["CPU"], ["Server", "KEYSPACE"], ["cpu", "cpu"], ["cpu", "all"], ["cpu", "default"],
         ["default", "all"], ["everything", "cpu"], ["nosuch"], ["nosuch", "cpu"],
         ["keyspace", "server"], ["sentinel"], ["cpu", "sentinel"], ["commandSTATS"]]


def check(name, ok, why=""):
    print(("OK:   " if ok else "FAIL: ") + name + ("" if ok else "\n      " + why))
    return ok


def ints(c, section):
    return {k: int(v) for k, v in fields(c.ask("INFO", section)).items()
            if k.startswith(("eventloop", "instantaneous_eventloop"))}


def eventloop(name, c):
    """the event loop's fields of one server, as Redis 7.2.16's
    tests/unit/info.tcl checks them (stats: eventloop metrics,
    instantaneous metrics and debug metrics), and after CONFIG RESETSTAT,
    a pipeline of 100 commands and a script"""
    ok = True
    c.ask("PING")
    s1 = ints(c, "stats")
    time.sleep(0.11)  # a tick of the cron at hz 10
    s2 = ints(c, "stats")
    for k, most in (("eventloop_cycles", 10), ("eventloop_duration_sum", 30000), ("eventloop_duration_cmd_sum", 15000)):
        ok &= check("%s: %s grows by 1 to %d over a tick" % (name, k, most - 1),
                    s1[k] > 0 and s1[k] < s2[k] < s1[k] + most, "%d, then %d" % (s1[k], s2[k]))
    c.ask("CONFIG", "RESETSTAT")
    s0, d0 = ints(c, "stats"), ints(c, "debug")
    ok &= check("%s: CONFIG RESETSTAT starts the cycles again" % name,
                s0["eventloop_cycles"] <= 2 and d0["eventloop_cmd_per_cycle_max"] <= 1, "%r %r" % (s0, d0))
    for tries in range(1, 4):
        time.sleep(1.6)  # 16 samples of the cron
        s = ints(c, "stats")
        if s["instantaneous_eventloop_cycles_per_sec"] > 0:
            break
    ok &= check("%s: instantaneous_eventloop_cycles_per_sec of an idle server" % name,
                0 < s["instantaneous_eventloop_cycles_per_sec"] < tries * 15, "%r, after %d tries" % (s, tries))
    ok &= check("%s: instantaneous_eventloop_duration_usec of an idle server" % name,
                0 < s["instantaneous_eventloop_duration_usec"] < tries * 22000, "%r" % s)
    ok &= check("%s: the debug fields only in INFO debug" % name,
                not any(b"eventloop_duration_aof_sum" in c.ask("INFO", *p) for p in ([], ["all"], ["everything"])))
    d1 = ints(c, "debug")
    time.sleep(0.11)
    d2 = ints(c, "debug")
    ok &= check("%s: the debug fields grow" % name,
                0 <= d1["eventloop_duration_aof_sum"] <= d2["eventloop_duration_aof_sum"]
                and 0 < d1["eventloop_duration_cron_sum"] < d2["eventloop_duration_cron_sum"]
                and 0 < d1["eventloop_cmd_per_cycle_max"] <= d2["eventloop_cmd_per_cycle_max"]
                and 0 < d1["eventloop_duration_max"] <= d2["eventloop_duration_max"], "%r, then %r" % (d1, d2))
    c.s.sendall(b"*1\r\n$4\r\nPING\r\n" * 100)
    for _ in range(100):
        c.read()
    d3 = ints(c, "debug")
    ok &= check("%s: a pipeline of 100 commands runs in one cycle" % name,
                d3["eventloop_cmd_per_cycle_max"] >= 100, "%r" % d3)
    # a script's run, and its calls, are its cycle's
    c.ask("CONFIG", "RESETSTAT")
    c.ask("EVAL", "local i = 0 while i < 3000000 do i = i + 1 end "
                  "for j = 1, 200 do redis.call('PING') end return 1", "0")
    usec = int(fields(c.ask("INFO", "commandstats"))["cmdstat_eval"].split("usec=")[1].split(",")[0])
    d4 = ints(c, "debug")
    ok &= check("%s: a script's run and its calls are its cycle's" % name,
                usec >= 1000 and d4["eventloop_duration_max"] >= usec and d4["eventloop_cmd_per_cycle_max"] >= 201,
                "EVAL took %d us; %r" % (usec, d4))
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, default=6380)
    ap.add_argument("--redis", type=int, default=6390)
    a = ap.parse_args()
    b, r = Client(a.bendkv), Client(a.redis)
    ok = True
    for c in (b, r):
        c.ask("FLUSHALL")
    for pick in PICKS:
        bi, ri = b.ask("INFO", *pick), r.ask("INFO", *pick)
        ok &= check("INFO %s: sections and fields" % " ".join(pick or ["(none)"]),
                    shape(bi) == shape(ri), "\n      ".join(
                        "%-40s %s" % x for x in zip(shape(bi), shape(ri)) if x[0] != x[1])[:3000])
    bi, ri = fields(b.ask("INFO", "everything")), fields(r.ask("INFO", "everything"))
    for k in STEADY:
        ok &= check("%s the same" % k, bi.get(k) == ri.get(k), "bendkv %r, redis %r" % (bi.get(k), ri.get(k)))
    for k in ("run_id", "master_replid"):
        v = bi.get(k, "")
        ok &= check("%s is 40 hex digits" % k, len(v) == 40 and all(ch in "0123456789abcdef" for ch in v), v)
    ok &= check("process_id is BendKV's", bi.get("process_id", "").isdigit())
    ok &= check("tcp_port is its port", bi.get("tcp_port") == str(a.bendkv), bi.get("tcp_port"))

    # the keyspace
    for c in (b, r):
        for k in ("a", "b", "c"):
            c.ask("SET", k, "1")
    bk, rk = b.ask("INFO", "keyspace"), r.ask("INFO", "keyspace")
    ok &= check("keyspace after three keys", bk == rk, "%r %r" % (bk, rk))
    for c in (b, r):
        c.ask("FLUSHALL")
    bk, rk = b.ask("INFO", "keyspace"), r.ask("INFO", "keyspace")
    ok &= check("keyspace when empty", bk == rk, "%r %r" % (bk, rk))

    # the counts after CONFIG RESETSTAT: the same commands, one at a time,
    # and two more connections, on both
    got = []
    for c, port in ((b, a.bendkv), (r, a.redis)):
        c.ask("CONFIG", "RESETSTAT")
        c.ask("SET", "x", "1")
        c.ask("GET", "x")
        c.ask("PING")
        more = [Client(port), Client(port)]
        for m in more:
            m.ask("PING")
        f = fields(c.ask("INFO", "stats", "clients"))
        got.append({k: f.get(k) for k in ("total_commands_processed", "total_connections_received", "connected_clients")})
        for m in more:
            m.close()
    ok &= check("counts after CONFIG RESETSTAT", got[0] == got[1], "bendkv %r, redis %r" % tuple(got))
    for name, c in (("bendkv", b), ("redis", r)):
        ok &= eventloop(name, c)
    b.close()
    r.close()
    print("ALL OK" if ok else "SOME CHECKS FAILED")
    return ok


if __name__ == "__main__":
    raise SystemExit(0 if main() else 1)
