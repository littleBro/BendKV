#!/usr/bin/env python3
"""redis_suite.py: Redis's own test suite against BendKV, and against Redis
itself, the same way: each unit of tests/unit (and tests/unit/type) of a
Redis 7.0.15 source tree runs in Redis's external mode, against a server
already started, with the options Redis has for compatible servers: no
checks of object encodings or of DEBUG DIGEST (--ignore-encoding,
--ignore-digest), and every test run even after one fails with an error
(--durable); with --singledb, the suite uses database 0 alone (for a
server with one database), else database 9 for its keys and the others
for the tests of SELECT, MOVE and SWAPDB. Tests that need to start their
own servers are marked external:skip and do not run in this mode.

Each server under test runs as several instances, one unit at a time on
each, restarted when a unit kills it. The results go to a JSON file:
for each unit and test, ok or err, with the error's first line.

    tools/redis_suite.py --redis-src ../redis --server build/bendkv --out bendkv.json
    tools/redis_suite.py --redis-src ../redis --server redis-server --out redis.json
    tools/redis_suite.py --report redis.json bendkv.json      # the table

The report counts, for each unit, the tests Redis passes in this mode and
how many of them BendKV passes; of the others, why each fails: a command
BendKV does not have (named, by the tests it stops), a unit stopped
before the test ran, or another error (listed).
"""
import argparse, collections, json, os, re, signal, socket, subprocess, threading, time

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def units(src):
    out = []
    for d in ("tests/unit", "tests/unit/type"):
        for f in sorted(os.listdir(os.path.join(src, d))):
            if f.endswith(".tcl"):
                out.append(os.path.join(d, f)[len("tests/"):-len(".tcl")])
    return out

def up(port, timeout=20):
    end = time.time() + timeout
    while time.time() < end:
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=1)
            s.sendall(b"PING\r\n")
            ok = s.recv(64).startswith(b"+PONG")
            s.close()
            if ok:
                return True
        except OSError:
            pass
        time.sleep(0.1)
    return False

# a server under test, in a directory of its own: tests turn on the
# append-only file and save snapshots, into the server's directory
class Server:
    def __init__(self, cmd, port, log, home):
        self.cmd, self.port, self.log, self.home, self.p = cmd, port, log, home, None

    def start(self):
        if self.cmd == "redis-server":
            args = ["redis-server", "--port", str(self.port), "--save", "", "--appendonly", "no",
                    "--bind", "127.0.0.1"]
        else:
            args = [self.cmd, str(self.port)]
        os.makedirs(self.home, exist_ok=True)
        self.p = subprocess.Popen(args, cwd=self.home, stdout=open(self.log, "ab"), stderr=subprocess.STDOUT)
        if up(self.port):
            return True
        print("redis_suite.py: %s did not start on port %d (%s)" % (self.cmd, self.port, self.log), flush=True)
        self.stop()
        return False

    def alive(self):
        return self.p.poll() is None and up(self.port, 2)

    def stop(self):
        if self.p and self.p.poll() is None:
            self.p.send_signal(signal.SIGTERM)
            try:
                self.p.wait(10)
            except subprocess.TimeoutExpired:
                self.p.kill()
                self.p.wait()

LINE = re.compile(r"^\[(ok|err|skip|ignore|exception)\]: (.*?)(?: \((\d+) ms\))?(?: in tests/\S+)?$")

# the tests of one run of runtest, and the first line of each error. With
# --durable, an error that is not an assertion comes as its message less
# its first ten bytes, then the whole message: the whole one is kept.
def parse(text):
    tests, last, lines = collections.OrderedDict(), None, []
    def done():
        if last and lines:
            why = lines[1] if len(lines) > 1 and lines[1].endswith(lines[0]) else lines[0]
            tests[last]["why"] = why[:300]
    for line in text.splitlines():
        m = LINE.match(line.strip())
        if m:
            done()
            kind, name = m.group(1), m.group(2)
            last, lines = None, []
            if kind in ("ok", "err", "exception"):
                tests[name] = {"st": "ok" if kind == "ok" else "err", "why": ""}
                last = name if kind != "ok" else None
            continue
        if last and line.strip() and len(lines) < 2:
            lines.append(line.strip())
    done()
    return tests

def run_unit(src, unit, port, baseport, timeout, singledb):
    cmd = ["./runtest", "--host", "127.0.0.1", "--port", str(port)] + (["--singledb"] if singledb else []) + [
           "--ignore-encoding", "--ignore-digest", "--durable", "--timeout", str(timeout), "--baseport", str(baseport),
           "--single", unit]
    try:
        r = subprocess.run(cmd, cwd=src, capture_output=True, text=True, errors="replace",
                           timeout=timeout * 20)
        text = r.stdout + r.stderr
    except subprocess.TimeoutExpired as e:
        text = (e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        text += "\n[unit timed out]"
    return text

def main_run(a):
    todo = list(a.units or units(a.redis_src))
    results, lock = {}, threading.Lock()
    queue = collections.deque(todo)

    def worker(i):
        port = a.port + i
        srv = Server(a.server, port, os.path.join(a.logs, "server-%d.log" % port),
                     os.path.join(a.logs, "server-%d" % port))
        if not srv.start():
            return
        while True:
            with lock:
                if not queue:
                    break
                unit = queue.popleft()
            t0 = time.time()
            text = run_unit(a.redis_src, unit, port, 21000 + 100 * i, a.timeout, a.singledb)
            died = not srv.alive()
            tests = parse(text)
            with open(os.path.join(a.logs, unit.replace("/", "_") + ".txt"), "w") as f:
                f.write(text)
            with lock:
                results[unit] = {"tests": tests, "died": died, "secs": round(time.time() - t0, 1),
                                 "aborted": "[unit timed out]" in text or ("Cleanup" not in text)}
                n = sum(1 for t in tests.values() if t["st"] == "ok")
                print("%-28s %3d/%-3d ok  %5.1fs%s" % (unit, n, len(tests), time.time() - t0,
                      "  (server died)" if died else ""), flush=True)
            if died:
                srv.stop()
                if not srv.start():
                    return
        srv.stop()

    os.makedirs(a.logs, exist_ok=True)
    ths = [threading.Thread(target=worker, args=(i,)) for i in range(a.jobs)]
    for t in ths:
        t.start()
    for t in ths:
        t.join()
    json.dump({"server": a.server, "units": results}, open(a.out, "w"), indent=1, sort_keys=True)
    if len(results) < len(todo):
        raise SystemExit("redis_suite.py: units not run: " + ", ".join(u for u in todo if u not in results))

# why a test Redis passes fails on the server under test: the command or
# subcommand it does not know, or None
def missing(why):
    m = re.search(r"unknown subcommand '([^']*)'\. Try (\S+) HELP", why)
    if m:
        return (m.group(2) + " " + m.group(1)).lower()
    # the error's start may be cut off (a message of random bytes splits
    # into lines): its tail names the command still
    m = re.search(r"command '([^']*)', with args beginning with", why)
    return m.group(1).lower() if m else None

def main_report(a):
    ref = json.load(open(a.report[0]))["units"]
    got = json.load(open(a.report[1]))["units"]
    rows, empty, kinds = [], [], collections.Counter()
    blockers, others, hung = collections.Counter(), [], []
    for unit in sorted(ref):
        if not ref[unit]["tests"]:
            empty.append(unit)
            continue
        rt = [n for n, t in ref[unit]["tests"].items() if t["st"] == "ok"]
        gt = got.get(unit, {"tests": {}})["tests"]
        passed = 0
        for n in rt:
            g = gt.get(n)
            if g is None:
                kinds["not run: the unit stopped before it"] += 1
            elif g["st"] == "ok":
                passed += 1
            elif missing(g["why"]):
                kinds["a missing command"] += 1
                blockers[missing(g["why"])] += 1
            else:
                kinds["another error"] += 1
                others.append((unit, n, g["why"]))
        if got.get(unit, {}).get("died"):
            hung.append(unit)
        rows.append((unit, len(ref[unit]["tests"]), len(rt), passed))
    tot = [sum(r[i] for r in rows) for i in (1, 2, 3)]
    print("| unit | tests | Redis passes | %s passes |" % a.name)
    print("|---|---:|---:|---:|")
    for unit, n, r, b in rows:
        print("| %s | %d | %d | %d |" % (unit, n, r, b))
    print("| **all** | **%d** | **%d** | **%d (%.1f%%)** |" % (tot[0], tot[1], tot[2], 100.0 * tot[2] / max(tot[1], 1)))
    print()
    print("Units with no test in this mode: " + ", ".join(empty) + ".")
    if hung:
        print("Units after which the server did not answer: " + ", ".join(hung) + ".")
    print()
    print("Why %s fails the other %d tests Redis passes:" % (a.name, tot[1] - tot[2]))
    for k, n in kinds.most_common():
        print("  %-40s %d" % (k, n))
    print()
    print("Missing commands, by the tests they stop:")
    for c, n in blockers.most_common(a.top):
        print("  %-24s %d" % (c, n))
    print()
    print("Tests that fail with another error:")
    for unit, n, why in others:
        print("  %s | %s | %s" % (unit, n[:70], why[:120]))

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--redis-src", default=os.environ.get("REDIS_SRC", "../redis"))
    ap.add_argument("--server", default=os.path.join(HERE, "build", "bendkv"))
    ap.add_argument("--out", default="suite.json")
    ap.add_argument("--logs", default="suite-logs")
    ap.add_argument("--jobs", type=int, default=3)
    ap.add_argument("--port", type=int, default=6600)
    ap.add_argument("--timeout", type=int, default=60)
    ap.add_argument("--units", nargs="*")
    ap.add_argument("--singledb", action="store_true")
    ap.add_argument("--report", nargs=2)
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--name", default="BendKV")
    a = ap.parse_args()
    if a.report:
        main_report(a)
    else:
        a.server = a.server if a.server == "redis-server" else os.path.abspath(a.server)
        main_run(a)
