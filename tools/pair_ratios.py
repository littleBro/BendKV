#!/usr/bin/env python3
# pair_ratios.py [--base NAME] [--cpu] FILE...: sums up the output of
# tools/bench_pairs.sh. In each trial every variant is compared with NAME
# (redis by default) from the same trial: its throughput over NAME's, and
# NAME's server CPU per request over its own, user time alone and user
# plus kernel (above 1: the variant is cheaper). Prints the median and the
# geometric mean of each ratio over the trials of all files, with the
# number of pairs. With --cpu it prints instead the median server CPU per
# request (ns, user + kernel) of each variant and test. Builds of one
# variant in several code layouts (tools/layouts.sh: NAME_s1, NAME_s2, ...)
# count as one variant NAME: in each trial, the geometric mean of their
# throughputs and the mean of their CPU times.
import collections
import math
import re
import statistics
import sys

args = sys.argv[1:]
base, cpu = "redis", False
while args and args[0].startswith("--"):
    flag = args.pop(0)
    if flag == "--base":
        base = args.pop(0)
    elif flag == "--cpu":
        cpu = True
    else:
        sys.exit(f"unknown flag {flag}")

tests = None
trials = collections.defaultdict(dict)   # (file, trial) -> variant -> cells
for path in args:
    for line in open(path):
        h = re.search(r"variant trial (.*?) \(rps", line)
        if h:
            tests = h.group(1).split()
            continue
        m = re.match(r"^(\S+) (t\d+) (.*)$", line)
        if m:
            cells = re.findall(r"(\d+)/\s*(\d+)\+\s*(\d+)", m.group(3))
            name = re.sub(r"_s\d+$", "", m.group(1))
            trials[(path, m.group(2))].setdefault(name, []).append(
                [tuple(map(int, c)) for c in cells])
tests = tests or ["get", "set", "incr"]

def gmean(xs):
    return math.exp(sum(map(math.log, xs)) / len(xs))

def pool(runs):
    # one variant's runs in a trial (one per layout) as one: per test, the
    # geometric mean of throughputs and the mean of user and kernel times
    out = []
    for cs in zip(*runs):
        ok = [c for c in cs if c[0] > 0] or cs
        out.append((gmean([max(c[0], 1) for c in ok]),
                    statistics.mean(c[1] for c in ok), statistics.mean(c[2] for c in ok)))
    return out

for vs in trials.values():
    for v in vs:
        vs[v] = pool(vs[v])

if cpu:
    per = collections.defaultdict(lambda: collections.defaultdict(list))
    for vs in trials.values():
        for v, cs in vs.items():
            for t, c in zip(tests, cs):
                per[v][t].append(c)
    for v, ts in per.items():
        cells = []
        for t, cs in ts.items():
            u = statistics.median(c[1] for c in cs)
            s = statistics.median(c[2] for c in cs)
            cells.append(f"{t} {u:5.0f} + {s:3.0f}")
        print(f"{v:8s}", " | ".join(cells), f"(n={len(next(iter(ts.values())))})")
    sys.exit(0)

rat = collections.defaultdict(lambda: collections.defaultdict(list))
for vs in trials.values():
    if base not in vs:
        continue
    b = vs[base]
    for v, cs in vs.items():
        if v == base:
            continue
        for t, c, r in zip(tests, cs, b):
            rat[v][t].append((c[0] / r[0], r[1] / c[1], (r[1] + r[2]) / (c[1] + c[2])))
print(f"against {base}: rps ratio median [geomean], user-CPU ratio, total-CPU ratio")
for v, ts in rat.items():
    cells = []
    for t, xs in ts.items():
        rps = [x[0] for x in xs]
        cells.append(f"{t}: {statistics.median(rps):.3f} [{gmean(rps):.3f}]"
                     f" u {statistics.median(x[1] for x in xs):.3f}"
                     f" c {statistics.median(x[2] for x in xs):.3f}")
    print(f"{v:8s}", " | ".join(cells), f"(n={len(xs)})")
