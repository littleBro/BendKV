#!/usr/bin/env python3
"""sprof_report.py OUT [top] [exe]: the samples sprof.so wrote to OUT, by
function. Symbols come from nm, or from the separate debug file of a
build id when the system has one (libc6-dbg). exe names the profiled
executable when it was linked -no-pie, so that its PCs are its symbols'
addresses; a WL segment's continuations (_K123, _C123) count as their def.
"""
import bisect, collections, re, subprocess, sys

out = sys.argv[1]
top = int(sys.argv[2]) if len(sys.argv) > 2 else 40
exe = sys.argv[3] if len(sys.argv) > 3 else None

maps = []
for l in open(out + ".maps"):
    f = l.split()
    if len(f) >= 6 and "x" in f[1]:
        a, b = (int(x, 16) for x in f[0].split("-"))
        maps.append((a, b, int(f[2], 16), f[5]))

def debug_of(path):
    r = subprocess.run(["readelf", "-n", path], capture_output=True, text=True).stdout
    m = re.search(r"Build ID: ([0-9a-f]+)", r)
    if m:
        d = f"/usr/lib/debug/.build-id/{m.group(1)[:2]}/{m.group(1)[2:]}.debug"
        try:
            open(d).close()
            return d
        except OSError:
            pass
    return path

syms = {}
def symtab(path):
    if path not in syms:
        tab = []
        for flags in (["-n", "--defined-only"], ["-D", "-n", "--defined-only"]):
            r = subprocess.run(["nm"] + flags + [debug_of(path)], capture_output=True, text=True).stdout
            for l in r.splitlines():
                p = l.split()
                if len(p) >= 3 and p[1] in "tTwWiI":
                    tab.append((int(p[0], 16), p[2]))
            if tab:
                break
        syms[path] = sorted(tab)
    return syms[path]

cnt = collections.Counter()
# a line is a PC, or a PC and a thread id (SPROF_CPU); with --thread T
# only thread T's samples count (threads are numbered in order of their
# first sample, from 0)
want = None
if "--thread" in sys.argv:
    want = int(sys.argv[sys.argv.index("--thread") + 1])
order = {}
pcs = []
for l in open(out):
    f = l.split()
    if not f:
        continue
    t = order.setdefault(f[1] if len(f) > 1 else "0", len(order))
    if want is None or t == want:
        pcs.append(int(f[0], 16))
for pc in pcs:
    name = "?"
    for a, b, off, path in maps:
        if a <= pc < b:
            tab = symtab(path)
            addr = pc if exe and path.endswith(exe) else pc - a + off
            i = bisect.bisect_right(tab, (addr, "\xff")) - 1
            lib = path.split("/")[-1]
            name = (tab[i][1] if i >= 0 else "?") + (" [" + lib + "]" if "lib" in lib else "")
            break
    cnt[re.sub(r"_[KC]\d+$", "", name)] += 1

print(f"{len(pcs)} samples")
for k, v in cnt.most_common(top):
    print(f"{100 * v / len(pcs):6.2f}%  {v:7d}  {k}")
