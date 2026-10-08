#!/usr/bin/env python3
"""Local twin of bend's gates/test.ts for the compiled lanes: builds every
runnable test with a given bend checkout, runs it under a 5 s alarm, and
compares its tidied stdout+stderr (plus "exit N" / "timeout") with its #|
lines. LANES picks the lanes, "c" (the default) or "c,js": the C lane
builds with clang -O1, the JS lane runs the built JS under bun.

    c_lane_tests.py <bend checkout> <work dir> [jobs]

The tests are the checkout's own tests/; compare two checkouts by diffing
the <work dir>/summary.txt files they write (a JS run's names end in .js).
"""
import os, re, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

ROOT, WORK = sys.argv[1], sys.argv[2]
JOBS = int(sys.argv[3]) if len(sys.argv) > 3 else 4
TESTS = os.path.join(ROOT, "tests")
os.makedirs(WORK, exist_ok=True)

def tidy(t):
    return re.sub(r"[ \t]+$", "", t, flags=re.M).strip()

def tests():
    for d in sorted(os.listdir(TESTS)):
        p = os.path.join(TESTS, d)
        if not os.path.isdir(p):
            continue
        for f in sorted(os.listdir(p)):
            if not f.endswith(".bend"):
                continue
            src = open(os.path.join(p, f)).read()
            want = tidy("\n".join(l[2:] for l in src.split("\n") if l.startswith("#|")))
            effs = re.findall(r'^\s*import "\./[a-z0-9_]+\.(c|js)"$', src, re.M)
            lanes = [l for l in ["js", "c"] if re.search(r"^import Base$", src, re.M) and (not effs or l in effs)]
            main = re.search(r"^(def|law) main(\(|:)", src, re.M) is not None
            fails = re.match(r"^(SOME PROOFS FAIL|Error:)", want) is not None
            for lane in os.environ.get("LANES", "c").split(","):
                if main and lane in lanes and not fails:
                    yield d, f, want, src, lane

def run(t):
    d, f, want, src, lane = t
    name = d + "_" + f[:-5] + ("" if lane == "c" else ".js")
    if lane == "js":
        j = os.path.join(WORK, name)
        g = subprocess.run(["bun", os.path.join(ROOT, "bend2/main.ts"), os.path.join("tests", d, f), "-o", j],
                           cwd=ROOT, capture_output=True, text=True, timeout=600)
        if g.returncode != 0 or not os.path.exists(j):
            return name, "build", tidy(g.stdout + g.stderr)[:300], want
        try:
            r = subprocess.run(["bun", j], cwd=ROOT, capture_output=True, timeout=5)
            out = tidy((r.stdout + r.stderr).decode("utf8", "replace"))
            if r.returncode != 0:
                out = (out + "\n" if out else "") + "exit %d" % r.returncode
        except subprocess.TimeoutExpired:
            out = "timeout"
        try:
            os.remove(j)
        except OSError:
            pass
        return name, ("pass" if out == want else "fail"), out[:300], want[:300]
    c = os.path.join(WORK, name + ".c")
    b = os.path.join(WORK, name)
    g = subprocess.run(["bun", os.path.join(ROOT, "bend2/main.ts"), os.path.join("tests", d, f), "-o", c],
                       cwd=ROOT, capture_output=True, text=True, timeout=600)
    if g.returncode != 0 or not os.path.exists(c):
        return name, "build", tidy(g.stdout + g.stderr)[:300], want
    libs = []
    csrc = open(c).read()
    if "#include <X11/" in csrc:
        libs.append("-lX11")
    if "#include <alsa/" in csrc:
        libs.append("-lasound")
    k = subprocess.run(["clang", "-std=c11", "-O1", "-w", c, "-lpthread", "-lm", *libs, "-o", b],
                       capture_output=True, text=True, timeout=600)
    if k.returncode != 0:
        return name, "cc", tidy(k.stderr)[:300], want
    try:
        r = subprocess.run([b], cwd=ROOT, capture_output=True, timeout=5)
        out = tidy((r.stdout + r.stderr).decode("utf8", "replace"))
        if r.returncode != 0:
            out = (out + "\n" if out else "") + "exit %d" % r.returncode
    except subprocess.TimeoutExpired:
        out = "timeout"
    for p in (c, b):
        try:
            os.remove(p)
        except OSError:
            pass
    return name, ("pass" if out == want else "fail"), out[:300], want[:300]

ts = list(tests())
res = {}
with ThreadPoolExecutor(JOBS) as ex:
    for name, st, got, want in ex.map(run, ts):
        res[name] = st
        if st != "pass":
            print("%s %s\n  got:  %r\n  want: %r" % (st.upper(), name, got, want), flush=True)
n = sum(1 for v in res.values() if v == "pass")
print("PASS %d / %d" % (n, len(res)))
with open(os.path.join(WORK, "summary.txt"), "w") as fh:
    for k in sorted(res):
        fh.write("%s %s\n" % (res[k], k))
