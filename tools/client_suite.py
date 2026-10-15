#!/usr/bin/env python3
"""client_suite.py: the test suites of Redis's client libraries against
BendKV, and against Redis itself, the same way: redis-py's (sync and
asyncio, in RESP2 or RESP3) and go-redis's (RESP3, with its specs of
RESP2), each at a fixed version taken from the language's registry (PyPI,
the Go module proxy), each run against a server started for it, in a
directory of its own. A client's suite is written for the newest Redis:
what counts is what Redis 7.0.15 passes, and of that, what BendKV passes.

    tools/client_suite.py run --client redis-py --protocol 2 --server build/bendkv --out bendkv.xml
    tools/client_suite.py run --client redis-py --protocol 2 --server redis-server --out redis.xml
    tools/client_suite.py report redis.xml bendkv.xml
    tools/client_suite.py ci --client redis-py --protocol 2 --server build/bendkv --out build/clients

`run` writes the suite's results as JUnit XML. `report` counts the tests
Redis passes and how many of them BendKV passes, and says why each other
one fails: a command BendKV does not have (named, by the tests it stops),
or another error (listed). `ci` runs both servers and reports, against the
known failures of tools/data/clients.json, each kept with the reason it
fails for (`reason`: the command BendKV does not have, as "unknown command
'XADD'", a skip's reason, or the line of another error): a test Redis
passes, that BendKV fails and that is not a known failure, or a known
failure whose failure no longer holds its reason, is a regression, and the
run fails; a known failure that passes is reported, to be taken off the
list (`--write-known` writes the list, and the reasons, as the run found
them).

redis-py leaves out its tests of modules (JSON, search, time series,
probabilistic structures, vector sets), of clusters, sentinels, TLS and
the services of Redis Enterprise. go-redis runs as against one Redis
Enterprise database (RE_CLUSTER, an endpoints file naming the server), so
that it starts no ring, sentinel or cluster of its own, and leaves out the
specs of those and of modules. A failing test runs again up to twice
before it counts as failed, in both suites (in redis-py, but one that
fails on an unknown command). A test that passes on BendKV only after a
rerun, where it passes at its first attempt on Redis, is reported (a race
in BendKV passes so); from RERUN_GRACE on (RERUN_GRACE in the environment
gives another day), it counts as failed.
"""
import argparse, collections, datetime, json, os, re, shutil, signal, socket, subprocess, sys, tempfile, time
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KNOWN = os.path.join(HERE, "tools", "data", "clients.json")

REDIS_PY = "8.1.0"
GO_REDIS = "v9.23.0"
PY_DEPS = ["pytest", "pytest-asyncio", "pytest-timeout", "pytest-rerunfailures", "packaging", "ujson",
           "numpy", "pybreaker"]

PY_MARKS = ("not redismod and not onlycluster and not ssl and not replica and not experimental"
            " and not cp_integration and not multidb_integration")
PY_SKIP = ["bloom", "json", "search", "search_aggregation", "search_querystring", "search_result", "timeseries",
           "vsets", "cluster", "cluster_transaction", "ssl", "sentinel", "sentinel_managed_connection",
           "himport_integration", "credentials"]
PY_SKIP_DIRS = ["maint_notifications", "test_auth", "test_http", "test_multidb", "test_observability",
                "test_scenario", "test_asyncio/test_scenario"]

GO_LABELS = "!json && !search && !timeseries && !probabilistic && !vectorset && !array && !NonRedisEnterprise"
GO_SKIP = ("Ring|Sentinel|Failover|ClusterClient|cluster|Cluster|UniversalClient|TLS|newClusterState|"
           "isLoopback|Command Tips|HIMPORT|HotKeys|RediSearch|FT\\.|JSON|TS\\.|NewScriptServerSHA")

# the day from which a test that passes on BendKV only after a rerun (and
# at its first attempt on Redis) counts as failed; until then it is only
# reported, so that the races it shows can be fixed first
RERUN_GRACE = "2026-11-15"

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

def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port

# a server under test, in a directory of its own (tests save snapshots
# and turn the append-only file on, in the server's directory)
class Server:
    def __init__(self, cmd, home):
        self.cmd, self.home, self.p, self.port = cmd, home, None, free_port()

    def __enter__(self):
        os.makedirs(self.home, exist_ok=True)
        if os.path.basename(self.cmd) == "redis-server":
            args = [self.cmd, "--port", str(self.port), "--save", "", "--appendonly", "no", "--bind", "127.0.0.1"]
        else:
            args = [os.path.abspath(self.cmd), "--port", str(self.port)]
        self.p = subprocess.Popen(args, cwd=self.home, stdout=open(os.path.join(self.home, "server.log"), "ab"),
                                  stderr=subprocess.STDOUT)
        if not up(self.port):
            self.__exit__()
            sys.exit("client_suite.py: %s did not start (%s)" % (self.cmd, self.home))
        return self

    def __exit__(self, *_):
        if self.p and self.p.poll() is None:
            self.p.send_signal(signal.SIGTERM)
            try:
                self.p.wait(10)
            except subprocess.TimeoutExpired:
                self.p.kill()
                self.p.wait()

def sh(args, **kw):
    print("+ " + " ".join(args), flush=True)
    subprocess.run(args, check=True, **kw)

# The clients, fetched once into WORK (kept from one run to the next)

def fetch_redis_py(work):
    src = os.path.join(work, "redis-" + REDIS_PY)
    venv = os.path.join(work, "venv")
    if os.path.exists(os.path.join(src, ".ready")):
        return src, venv
    os.makedirs(work, exist_ok=True)
    sh([sys.executable, "-m", "venv", venv])
    pip = os.path.join(venv, "bin", "pip")
    sh([pip, "install", "-q"] + PY_DEPS)
    sh([pip, "download", "-q", "redis==" + REDIS_PY, "--no-binary", ":all:", "--no-deps", "-d", work])
    sh(["tar", "xzf", os.path.join(work, "redis-%s.tar.gz" % REDIS_PY), "-C", work])
    sh([pip, "install", "-q", "-e", src])
    open(os.path.join(src, ".ready"), "w").close()
    return src, venv

def fetch_go_redis(work):
    src = os.path.join(work, "go-redis")
    binary = os.path.join(work, "go-redis.test")
    if os.path.exists(binary):
        return src, binary
    os.makedirs(work, exist_ok=True)
    env = dict(os.environ, GOPATH=os.path.join(work, "gopath"), GOFLAGS="-modcacherw")
    out = subprocess.run(["go", "mod", "download", "-json", "github.com/redis/go-redis/v9@" + GO_REDIS],
                         check=True, capture_output=True, text=True, env=env).stdout
    shutil.rmtree(src, ignore_errors=True)
    shutil.copytree(json.loads(out)["Dir"], src)
    for root, dirs, files in os.walk(src):
        for f in dirs + files:
            os.chmod(os.path.join(root, f), 0o755 if f in dirs else 0o644)
    sh(["go", "test", "-c", "-o", binary, "."], cwd=src, env=env)
    return src, binary

# One run of a client's suite against a server started for it

def run_redis_py(work, server, protocol, out, focus):
    src, venv = fetch_redis_py(work)
    with Server(server, os.path.join(os.path.dirname(os.path.abspath(out)), "server-" + os.path.basename(out))) as s:
        args = [os.path.join(venv, "bin", "python"), "-m", "pytest", "tests", "-q", "-p", "no:cacheprovider",
                "-W", "ignore", "-rN", "-m", PY_MARKS, "--reruns", "2",
                "--rerun-except", "unknown command|unknown subcommand",
                "--redis-url=redis://127.0.0.1:%d/9" % s.port, "--protocol=%d" % protocol,
                "--junitxml=" + os.path.abspath(out)]
        for name in PY_SKIP:
            args += ["--ignore=tests/test_%s.py" % name, "--ignore=tests/test_asyncio/test_%s.py" % name]
        for d in PY_SKIP_DIRS:
            args += ["--ignore=tests/" + d]
        if focus:
            args += ["-k", focus]
        log = open(os.path.abspath(out) + ".log", "w")
        r = subprocess.run(args, cwd=src, stdout=log, stderr=subprocess.STDOUT, timeout=3 * 3600)
        print("client_suite.py: redis-py against %s, RESP%d: pytest exit %d" % (server, protocol, r.returncode),
              flush=True)

def run_go_redis(work, server, out, focus):
    src, binary = fetch_go_redis(work)
    with Server(server, os.path.join(os.path.dirname(os.path.abspath(out)), "server-" + os.path.basename(out))) as s:
        ends = os.path.abspath(out) + ".endpoints.json"
        json.dump({"standalone": {"endpoints": ["redis://127.0.0.1:%d" % s.port]}}, open(ends, "w"))
        env = dict(os.environ, RE_CLUSTER="true", REDIS_ENDPOINTS_CONFIG_PATH=ends, REDIS_VERSION="7.0")
        args = [binary, "-test.run", "^TestGinkgoSuite$", "-test.timeout", "3h",
                "-ginkgo.junit-report=" + os.path.abspath(out), "-ginkgo.label-filter=" + GO_LABELS,
                "-ginkgo.skip=" + GO_SKIP, "-ginkgo.flake-attempts=3", "-ginkgo.no-color"]
        if focus:
            args += ["-ginkgo.focus=" + focus]
        log = open(os.path.abspath(out) + ".log", "w")
        r = subprocess.run(args, cwd=src, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=3 * 3600)
        print("client_suite.py: go-redis against %s: exit %d" % (server, r.returncode), flush=True)

def run(client, work, server, protocol, out, focus=None):
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    if client == "redis-py":
        run_redis_py(work, server, protocol, out, focus)
    else:
        run_go_redis(work, server, out, focus)

# The results: for each test, passed, failed (with why) or skipped

def load(path):
    tests = {}
    for tc in ET.parse(path).getroot().iter("testcase"):
        name = "%s::%s" % (tc.get("classname") or "", tc.get("name") or "")
        st, why = "ok", ""
        for ch in tc:
            if ch.tag in ("failure", "error"):
                st, why = "err", ((ch.get("message") or "") + "\n" + (ch.text or "")).strip()
            elif ch.tag == "skipped" and st == "ok":
                st, why = "skip", (ch.get("message") or "skipped").strip()
        if st == "err" or name not in tests:
            tests[name] = (st, why)
    return tests

UNKNOWN = re.compile(r"unknown command '([^']+)'|unknown subcommand '([^']+)'(?:\. Try (\S+) HELP)?", re.I)

def missing(why):
    m = UNKNOWN.search(why)
    if not m:
        return None
    if m.group(1):
        return m.group(1).upper()
    return ("%s %s" % (m.group(3), m.group(2))).upper() if m.group(3) else m.group(2).upper()

def first_line(why):
    for line in why.splitlines():
        line = line.strip()
        if line:
            return line[:240]
    return ""

# The reason a test fails for, as data/clients.json keeps it with a known
# failure: the command BendKV does not have ("unknown command 'XADD'"), or
# else the line of a Redis error (go-redis shows its ERR line under a line
# of its own) or the first line of the failure or skip, numbers and
# addresses as # (a count, a port or an id changes from run to run). A
# failure has its known reason when its text, numbers so put, holds it.
NUMBERS = re.compile(r"0x[0-9a-fA-F]+|\d+")
REDIS_ERR = re.compile(r"\bERR [^\n]+")

def reason(why):
    m = UNKNOWN.search(why) or REDIS_ERR.search(why)
    return NUMBERS.sub("#", m.group(0).strip() if m else first_line(why))[:120]

def has_reason(why, known):
    return NUMBERS.sub("#", known) in NUMBERS.sub("#", why)

def compare(redis_xml, bendkv_xml):
    a, b = load(redis_xml), load(bendkv_xml)
    ok = sorted(k for k, v in a.items() if v[0] == "ok")
    fails = {k: b.get(k, ("err", "did not run"))[1] for k in ok if b.get(k, ("err",))[0] != "ok"}
    return a, b, ok, fails

# How many attempts each test took in a suite's results. pytest writes each
# attempt of a test it reruns as a case of its own, those before the last
# with no child (and an error in the teardown after a failed call as one
# more case, which is no attempt); ginkgo writes one case, whose timeline
# names each "Attempt #N Failed.  Retrying" (and two specs of one name
# are two cases).
RETRY = re.compile(r"Attempt #\d+ Failed\.\s+Retrying")

def attempts(path):
    root = ET.parse(path).getroot()
    pytest = any(s.get("name") == "pytest" for s in root.iter("testsuite"))
    tries, failed = {}, {}
    for tc in root.iter("testcase"):
        name = "%s::%s" % (tc.get("classname") or "", tc.get("name") or "")
        kids = [ch for ch in tc if ch.tag in ("failure", "error", "skipped")]
        if not pytest:
            tries[name] = max(tries.get(name, 0), 1 + len(RETRY.findall("".join(ch.text or "" for ch in tc))))
            continue
        teardown = (len(kids) == 1 and kids[0].tag == "error" and failed.get(name)
                    and (kids[0].get("message") or "").startswith("failed on teardown"))
        if not teardown:
            tries[name] = tries.get(name, 0) + 1
        failed[name] = any(ch.tag == "failure" for ch in kids)
    return tries

# the tests BendKV passes only after a rerun and Redis passes at their
# first attempt, with BendKV's attempts
def reruns(redis_xml, bendkv_xml):
    a, b = load(redis_xml), load(bendkv_xml)
    ta, tb = attempts(redis_xml), attempts(bendkv_xml)
    return {k: n for k, n in sorted(tb.items()) if n > 1 and b.get(k, ("",))[0] == "ok"
            and a.get(k, ("",))[0] == "ok" and ta.get(k, 1) == 1}

def report(redis_xml, bendkv_xml, title):
    a, b, ok, fails = compare(redis_xml, bendkv_xml)
    flaky = reruns(redis_xml, bendkv_xml)
    grace = os.environ.get("RERUN_GRACE") or RERUN_GRACE
    late = datetime.date.today() >= datetime.date.fromisoformat(grace)
    if late:
        for k, n in flaky.items():
            fails[k] = "passed only after %d attempts on BendKV, at its first on Redis" % n
    lines = ["### %s" % title, "",
             "Redis 7.0.15 passes %d of the %d tests that run; BendKV passes **%d** of those (%.1f%%)." % (
                 len(ok), sum(1 for v in a.values() if v[0] != "skip"), len(ok) - len(fails),
                 100.0 * (len(ok) - len(fails)) / max(1, len(ok)))]
    cmds, other = collections.Counter(), []
    for k, why in fails.items():
        c = missing(why)
        if c:
            cmds[c] += 1
        else:
            other.append((k, first_line(why)))
    if cmds:
        lines += ["", "A command BendKV does not have (%d tests): %s." % (
            sum(cmds.values()), ", ".join("%s %d" % (c, n) for c, n in cmds.most_common()))]
    if other:
        lines += ["", "Another error (%d tests):" % len(other), ""]
        lines += ["- `%s`: %s" % (k, why) for k, why in sorted(other)]
    if flaky:
        lines += ["", "Passed on BendKV only after a rerun, at the first attempt on Redis (%d tests; %s):" % (
            len(flaky), ("failures since %s" if late else "failures from %s on") % grace), ""]
        lines += ["- `%s`: %d attempts" % (k, n) for k, n in flaky.items()]
    return "\n".join(lines) + "\n", fails

def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--client", choices=["redis-py", "go-redis"], required=True)
    r.add_argument("--protocol", type=int, choices=[2, 3], default=3)
    r.add_argument("--server", required=True)
    r.add_argument("--work", default=os.path.join(HERE, "build", "clients-src"))
    r.add_argument("--out", required=True)
    r.add_argument("--focus", help="only the tests that match (pytest's -k, ginkgo's focus)")
    rp = sub.add_parser("report")
    rp.add_argument("redis_xml")
    rp.add_argument("bendkv_xml")
    c = sub.add_parser("ci")
    c.add_argument("--client", choices=["redis-py", "go-redis"], required=True)
    c.add_argument("--protocol", type=int, choices=[2, 3], default=3)
    c.add_argument("--server", required=True)
    c.add_argument("--redis", default="redis-server")
    c.add_argument("--work", default=os.path.join(HERE, "build", "clients-src"))
    c.add_argument("--out", required=True)
    c.add_argument("--known", default=KNOWN)
    c.add_argument("--write-known", action="store_true")
    a = p.parse_args()
    if a.cmd == "run":
        run(a.client, a.work, a.server, a.protocol, a.out, a.focus)
        return
    if a.cmd == "report":
        print(report(a.redis_xml, a.bendkv_xml, "%s against %s" % (a.bendkv_xml, a.redis_xml))[0])
        return
    key = "%s-resp%d" % (a.client, a.protocol if a.client == "redis-py" else 3)
    redis_xml = os.path.join(a.out, key + "-redis.xml")
    bendkv_xml = os.path.join(a.out, key + "-bendkv.xml")
    run(a.client, a.work, a.redis, a.protocol, redis_xml)
    run(a.client, a.work, a.server, a.protocol, bendkv_xml)
    text, fails = report(redis_xml, bendkv_xml, "%s %s, RESP%s" % (
        a.client, REDIS_PY if a.client == "redis-py" else GO_REDIS, key[-1]))
    known = json.load(open(a.known)) if os.path.exists(a.known) else {}
    if a.write_known:
        known[key] = {k: reason(fails[k]) for k in fails}
        with open(a.known, "w") as f:
            json.dump(known, f, indent=1, sort_keys=True)
            f.write("\n")
    listed = known.get(key, {})
    if not isinstance(listed, dict):
        sys.exit("client_suite.py: the known failures of %s in %s have no reasons (--write-known writes them)" % (
            key, a.known))
    new = sorted(k for k in fails if k not in listed)
    other = sorted(k for k in fails if k in listed and not has_reason(fails[k], listed[k]))
    fixed = sorted(k for k in listed if k not in fails)
    if fixed:
        text += "\n%d known failures pass now (take them off %s):\n\n" % (len(fixed), os.path.relpath(a.known, HERE))
        text += "".join("- `%s`\n" % k for k in fixed)
    if other:
        text += "\n**%d known failures fail for another reason** than the one %s gives:\n\n" % (
            len(other), os.path.relpath(a.known, HERE))
        text += "".join("- `%s`: %s (known: %s)\n" % (k, reason(fails[k]), listed[k]) for k in other)
    if new:
        text += "\n**%d regressions**: tests Redis passes that BendKV fails, not known before:\n\n" % len(new)
        text += "".join("- `%s`: %s\n" % (k, first_line(fails[k])) for k in new)
    print(text)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write(text + "\n")
    with open(os.path.join(a.out, key + ".md"), "w") as f:
        f.write(text)
    sys.exit(1 if new or other else 0)

if __name__ == "__main__":
    main()
