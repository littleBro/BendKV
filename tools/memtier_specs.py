#!/usr/bin/env python3
"""memtier_specs.py [options] SERVER...: runs benchmark specs from Redis's own
performance suite (github.com/redis/redis-benchmarks-specification) with
memtier_benchmark against each SERVER, interleaved: in every trial, every
spec runs once against every server, each on a fresh process.

A SERVER is "redis" (redis-server with the spec's settings) or a server
binary that takes its port as its argument, either followed by extra
arguments after commas: "redis,io-threads=2" adds --io-threads 2 to
redis-server's, "build/bendkv,2" runs build/bendkv PORT 2. The spec's client arguments are
used as written, except that the client threads become --threads (their
total connections kept: -c is scaled) and --test-time becomes --seconds; a
spec's preload, if any, runs first, untimed. The server runs pinned to
--server-cpu, memtier to --client-cpus. For each run it prints ops/s, p50
and p99 latency (ms) and the server's CPU time per operation (user and
kernel, ns), then, by spec, the median ratio of each server's ops/s to
the first server's, and of the first server's CPU time per operation to
its own. Builds of one server in several code layouts (tools/layouts.sh:
NAME_s1, NAME_s2, ...) count as one server NAME in the ratios: in each
trial, the geometric mean of their ops/s and the mean of their CPU times.

  python3 tools/memtier_specs.py --specs-dir ../redis-benchmarks-specification \\
      --trials 3 --seconds 15 redis build/bendkv
"""
import argparse
import json
import math
import os
import re
import shlex
import socket
import statistics
import subprocess
import sys
import tempfile
import time

import yaml

DEFAULT_SPECS = [
    "memtier_benchmark-1Mkeys-load-string-with-100B-values-pipeline-10",
    "memtier_benchmark-1Mkeys-string-get-100B-pipeline-10",
    "memtier_benchmark-1Mkeys-string-get-100B",
    "memtier_benchmark-1Mkeys-string-get-10B-pipeline-100",
    "memtier_benchmark-1Mkeys-string-incr-pipeline-10",
]


def args_of(cfg):
    return shlex.split(cfg["arguments"]) if cfg and cfg.get("arguments") else None


def adapt(argv, threads, seconds):
    """the spec's memtier arguments with threads and test time replaced"""
    out, t, c, i = [], None, None, 0
    while i < len(argv):
        a = argv[i]
        key, eq, val = a.partition("=")
        if key in ("-t", "--threads"):
            t = int(val if eq else argv[i + 1])
            i += 1 if eq else 2
            continue
        if key in ("-c", "--clients"):
            c = int(val if eq else argv[i + 1])
            i += 1 if eq else 2
            continue
        if key == "--test-time":
            if seconds:
                out += ["--test-time", str(seconds)]
            else:
                out += [a] if eq else [a, argv[i + 1]]
            i += 1 if eq else 2
            continue
        out.append(a)
        i += 1
    t, c = t or 4, c or 50
    out += ["-t", str(threads), "-c", str(max(1, round(c * t / threads)))]
    return out


def tag_of(spec):
    """a server's name in the output: its binary's name and any extras"""
    server, *extra = spec.split(",")
    return ",".join([os.path.basename(server)] + extra)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def start(spec, port, cpu, conf):
    server, *extra = spec.split(",")
    if server == "redis":
        cmd = ["redis-server", "--port", str(port), "--appendonly", "no", "--save", ""]
        for k, v in (conf or {}).items():
            if k != "save":
                cmd += ["--" + k, str(v).strip('"')]
        for kv in extra:
            k, _, v = kv.partition("=")
            cmd += ["--" + k, v]
    else:
        cmd = [server, str(port)] + extra
    p = subprocess.Popen(["taskset", "-c", cpu] + cmd,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2) as s:
                s.sendall(b"PING\r\n")
                if s.recv(16).startswith(b"+PONG"):
                    return p
        except OSError:
            pass
        time.sleep(0.1)
    p.kill()
    sys.exit(f"{server} did not start")


def cpu_ticks(pid):
    # utime and stime of the process: fields 14 and 15 of /proc/PID/stat;
    # the server runs under taskset, which execs it, so the pid is the same
    f = open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()
    return int(f[11]), int(f[12])


def memtier(mt, cpus, port, argv, out):
    cmd = ["taskset", "-c", cpus, mt, "-s", "127.0.0.1", "-p", str(port),
           "--json-out-file", out] + argv
    r = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    if r.returncode != 0:
        sys.exit("memtier failed: " + " ".join(cmd) + "\n" + r.stderr[-2000:])
    t = json.load(open(out))["ALL STATS"]["Totals"]
    pl = t.get("Percentile Latencies", {})
    return t["Ops/sec"], t["Count"], pl.get("p50.00"), pl.get("p99.00")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("servers", nargs="+")
    ap.add_argument("--specs-dir", required=True,
                    help="a checkout of redis/redis-benchmarks-specification")
    ap.add_argument("--specs", default=",".join(DEFAULT_SPECS))
    ap.add_argument("--trials", type=int, default=3)
    ap.add_argument("--seconds", type=int, default=15)
    ap.add_argument("--threads", type=int, default=3)
    ap.add_argument("--server-cpu", default="3")
    ap.add_argument("--client-cpus", default="0-2")
    ap.add_argument("--memtier", default=os.environ.get("MEMTIER", "memtier_benchmark"))
    ap.add_argument("--out", help="append one tab-separated line per run here")
    o = ap.parse_args()
    suite = os.path.join(o.specs_dir, "redis_benchmarks_specification", "test-suites")
    specs = []
    for name in o.specs.split(","):
        y = yaml.safe_load(open(os.path.join(suite, name + ".yml")))
        db = y.get("dbconfig", {})
        specs.append((name, args_of(db.get("preload_tool")), args_of(y["clientconfig"]),
                      db.get("configuration-parameters")))
    tick = os.sysconf("SC_CLK_TCK")
    res = {}
    tmp = tempfile.mkdtemp()
    for trial in range(1, o.trials + 1):
        for name, pre, cli, conf in specs:
            for srv in o.servers:
                port = free_port()
                p = start(srv, port, o.server_cpu, conf)
                try:
                    if pre:
                        memtier(o.memtier, o.client_cpus, port, adapt(pre, o.threads, 0),
                                os.path.join(tmp, "pre.json"))
                    u0, s0 = cpu_ticks(p.pid)
                    ops, n, p50, p99 = memtier(o.memtier, o.client_cpus, port,
                                               adapt(cli, o.threads, o.seconds),
                                               os.path.join(tmp, "run.json"))
                    u1, s1 = cpu_ticks(p.pid)
                finally:
                    p.kill()
                    p.wait()
                un = (u1 - u0) * 1e9 / tick / max(n, 1)
                sn = (s1 - s0) * 1e9 / tick / max(n, 1)
                short = re.sub(r"^memtier_benchmark-", "", name)
                tag = tag_of(srv)
                print(f"t{trial} {short:42s} {tag:10s} {ops:10.0f} ops/s  p50 {p50:6.3f}"
                      f"  p99 {p99:6.3f}  cpu {un:5.0f} + {sn:4.0f} ns/op", flush=True)
                pooled = re.sub(r"_s\d+$", "", tag)
                res.setdefault((short, trial), {}).setdefault(pooled, []).append((ops, un + sn))
                if o.out:
                    with open(o.out, "a") as f:
                        f.write(f"{trial}\t{short}\t{tag}\t{ops:.0f}\t{p50}\t{p99}\t{un:.0f}\t{sn:.0f}\n")
    def ops(runs):
        return math.exp(statistics.mean(math.log(max(r[0], 1)) for r in runs))

    def cpu(runs):
        return statistics.mean(r[1] for r in runs)
    tags = list(dict.fromkeys(re.sub(r"_s\d+$", "", tag_of(srv)) for srv in o.servers))
    base = tags[0]
    print(f"\nmedian ratios to {base} by spec: ops/s, and (cpu) {base}'s CPU per operation to the server's:")
    for name, *_ in specs:
        short = re.sub(r"^memtier_benchmark-", "", name)
        cells = []
        for tag in tags[1:]:
            rs = [(ops(r[tag]) / ops(r[base]), cpu(r[base]) / max(cpu(r[tag]), 1))
                  for (s, t), r in res.items() if s == short and base in r and tag in r]
            cells.append(f"{tag} {statistics.median(x[0] for x in rs):.3f} (cpu"
                         f" {statistics.median(x[1] for x in rs):.2f})" if rs else f"{tag} -")
        print(f"  {short:42s} " + "  ".join(cells))


if __name__ == "__main__":
    main()
