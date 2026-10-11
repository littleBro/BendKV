#!/usr/bin/env python3
"""INFO, BendKV against Redis: for each way of picking sections (none,
default, all, everything, each section, several, case aside, unknown
ones, repeats), the same sections in the same order, with the same fields
in the same order; the values that do not depend on the machine or the
moment (versions, modes, parameters, replication, the keyspace) the same;
and the counts after CONFIG RESETSTAT (connections taken, commands run)
the same for the same commands on the same connections.

Left out until BendKV counts per command (the COMMAND table): the lines
of commandstats, errorstats and latencystats, which Redis fills and
BendKV leaves empty.

    python3 tests/info_test.py --bendkv 6380 --redis 6390
"""
import argparse
import socket


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
    b.close()
    r.close()
    print("ALL OK" if ok else "SOME CHECKS FAILED")
    return ok


if __name__ == "__main__":
    raise SystemExit(0 if main() else 1)
