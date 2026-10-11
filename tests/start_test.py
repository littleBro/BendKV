#!/usr/bin/env python3
"""How BendKV starts, against redis-server 7.0.15: the command line, the
configuration file, its includes and the standard input, read as Redis
reads them. Each case starts both servers with the same arguments, each
in a fresh directory of its own that holds the case's files:

- a case Redis refuses must be refused by BendKV with the same exit code
  and the same report: the fatal error of the configuration on stderr (but
  its first line, which names the server), or the last line of the log on
  stdout (but the pid and the date);
- a case both start must give the same CONFIG GET for the parameters it
  names (a server's own port and directory read as {port} and {dir}).

Then what BendKV refuses although Redis starts (what it cannot do: modules,
ACL users, renamed commands, the background, a cluster, a replica, TLS,
data it cannot read, a supervisor it cannot signal), each with its line;
and what is BendKV's own: --version, --help, the short form, the log file,
the pid file, protected mode and several addresses.

    python3 tests/start_test.py [--bin build/bendkv] [--redis redis-server]
"""
import argparse
import os
import re
import shutil
import signal
import socket
import subprocess
import tempfile
import time


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def resp(*args):
    out = b"*%d\r\n" % len(args)
    for a in args:
        a = a if isinstance(a, bytes) else a.encode()
        out += b"$%d\r\n%s\r\n" % (len(a), a)
    return out


class Client:
    def __init__(self, port, host="127.0.0.1"):
        self.s = socket.create_connection((host, port), timeout=5)
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
        self.s.sendall(resp(*args))
        return self.read()

    def close(self):
        self.s.close()


def answers(port, host="127.0.0.1"):
    try:
        c = Client(port, host)
        c.s.sendall(b"PING\r\n")
        c.line()
        c.close()
        return True
    except OSError:
        return False


class Server:
    """A server started in a fresh directory with the case's files: it
    exits (refused), or answers on its port."""

    def __init__(self, a, cmd, args, files, stdin, env):
        self.dir = tempfile.mkdtemp(dir=a.tmp)
        self.port = free_port()
        for name, text in files.items():
            path = os.path.join(self.dir, name)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as f:
                f.write(self.fill(text).encode() if isinstance(text, str) else text)
        self.out = os.path.join(self.dir, "_out")
        self.err = os.path.join(self.dir, "_err")
        e = dict(os.environ)
        e.pop("NOTIFY_SOCKET", None)
        e.pop("UPSTART_JOB", None)
        e.update(env)
        with open(self.out, "wb") as o, open(self.err, "wb") as r:
            self.p = subprocess.Popen([cmd] + [self.fill(x) for x in args], cwd=self.dir,
                                      stdin=subprocess.PIPE, stdout=o, stderr=r, env=e)
        self.p.stdin.write(self.fill(stdin or "").encode())
        self.p.stdin.close()

    def fill(self, s):
        return s.replace("{port}", str(self.port)).replace("{busy}", str(BUSY[0]))

    def up(self, timeout=10):
        """None once it answers, else its exit code"""
        end = time.time() + timeout
        while time.time() < end:
            code = self.p.poll()
            if code is not None:
                return code
            if answers(self.port):
                return None
            time.sleep(0.02)
        raise RuntimeError("the server neither exited nor answered")

    def text(self, which):
        with open(self.out if which == "out" else self.err, "rb") as f:
            return f.read().decode(errors="replace").replace(self.dir, "{dir}").replace(str(self.port), "{port}")

    def report(self):
        """the fatal error on stderr without the line naming the server,
        and the log's last line without pid and date"""
        err = re.sub(r"\*\*\* FATAL CONFIG FILE ERROR \([^)]*\) \*\*\*", "*** FATAL CONFIG FILE ERROR ***", self.text("err"))
        log = [l for l in self.text("out").splitlines() if l.strip()]
        last = re.sub(r"^\d+:[CMSX] \d\d \w{3} \d{4} [\d:.]+ [.*#-] ", "", log[-1]) if log else ""
        return err, last

    def get(self, names, auth):
        c = Client(self.port)
        if auth is not None:
            c.ask("AUTH", auth)
        out = {}
        for n in names:
            r = c.ask("CONFIG", "GET", n)
            for k, v in zip(r[0::2], r[1::2]):
                v = v.decode(errors="replace").replace(self.dir, "{dir}")
                out[k.decode()] = v.replace(str(self.port), "{port}") if v == str(self.port) else v
        c.close()
        return out

    def stop(self):
        if self.p.poll() is None:
            self.p.send_signal(signal.SIGTERM)
            try:
                self.p.wait(10)
            except subprocess.TimeoutExpired:
                self.p.kill()
                self.p.wait()
        shutil.rmtree(self.dir, ignore_errors=True)


# a port held busy, for the case of a port in use
BUSY = [0]

# Cases Redis refuses: name, arguments, files, standard input
REFUSED = [
    ("a bad directive", ["c.conf"], {"c.conf": "port {port}\nfoo bar\n"}, None),
    ("a wrong number of arguments", ["c.conf"], {"c.conf": "port {port} 1\n"}, None),
    ("not an integer", ["--port", "abc"], {}, None),
    ("an unknown option", ["--port", "{port}", "--nosuch", "1"], {}, None),
    ("quotes left open", ["c.conf"], {"c.conf": 'port "{port}\n'}, None),
    ("a closing quote, then a char", ["c.conf"], {"c.conf": 'port "{port}"x\n'}, None),
    ("yes or no", ["--port", "{port}", "--appendonly", "maybe"], {}, None),
    ("an enum", ["--loglevel", "loud"], {}, None),
    ("bit flags at odds", ["--shutdown-on-sigterm", "save nosave"], {}, None),
    ("bit flags unknown", ["--shutdown-on-sigint", "now later"], {}, None),
    ("a memory value", ["--maxmemory", "1zb"], {}, None),
    ("out of bounds", ["--hz", "-1"], {}, None),
    ("a percent where none goes", ["--maxmemory", "10%"], {}, None),
    ("dbfilename as a path", ["--dbfilename", "a/b"], {}, None),
    ("appendfilename empty", ["--appendfilename", ""], {}, None),
    ("appenddirname as a path", ["--appenddirname", "a/b"], {}, None),
    ("save points odd", ["--save", "900"], {}, None),
    ("save seconds below 1", ["--save", "0 1"], {}, None),
    ("buffer limits short", ["--client-output-buffer-limit", "normal 1 2"], {}, None),
    ("buffer limits of no class", ["--client-output-buffer-limit", "master 1 2 3"], {}, None),
    ("buffer limits one empty word", ["c.conf"], {"c.conf": 'client-output-buffer-limit ""\n'}, None),
    ("oom values short", ["--oom-score-adj-values", "1 2"], {}, None),
    ("oom values out of range", ["--oom-score-adj-values", "0 1 3000"], {}, None),
    ("keyspace events", ["--notify-keyspace-events", "Q"], {}, None),
    ("too many addresses", ["--bind"] + ["127.0.0.%d" % i for i in range(1, 18)], {}, None),
    ("a master port", ["--replicaof", "h", "70000"], {}, None),
    ("replicaof's arguments", ["--replicaof", "h"], {}, None),
    ("percentiles past 100", ["--latency-tracking-info-percentiles", "101"], {}, None),
    ("percentiles not numbers", ["--latency-tracking-info-percentiles", "x"], {}, None),
    ("a title template", ["--proc-title-template", "{nope}"], {}, None),
    ("a hostname", ["--cluster-announce-hostname", "a_b"], {}, None),
    ("activedefrag", ["--activedefrag", "yes"], {}, None),
    ("a directory not there", ["--dir", "/nonexistent/x"], {}, None),
    ("a directory that is a file", ["--dir", "f"], {"f": "x"}, None),
    ("a log file that cannot open", ["--logfile", "/nonexistent/x.log"], {}, None),
    ("an include not there", ["c.conf"], {"c.conf": "include nope.conf\n"}, None),
    ("a configuration file not there", ["nope.conf"], {}, None),
    ("a sentinel directive", ["c.conf"], {"c.conf": "sentinel monitor a 1.2.3.4 1 1\n"}, None),
    ("a module's parameter with no value", ["c.conf"], {"c.conf": "a.b\n"}, None),
    ("replicaof in a cluster", ["c.conf"], {"c.conf": "cluster-enabled yes\nreplicaof 1.2.3.4 6379\n"}, None),
    ("an error in an include, at its line", ["c.conf"], {"c.conf": "port {port}\ninclude i.conf\n", "i.conf": "# x\n\nhz abc\n"}, None),
    ("an error after an include", ["c.conf"], {"c.conf": "include i.conf\nhz abc\n", "i.conf": "hz 5\n"}, None),
    ("an option after a file with no last newline", ["c.conf", "--hz", "x"], {"c.conf": "port {port}"}, None),
    ("an option after a file with one", ["c.conf", "--hz", "x"], {"c.conf": "port {port}\n"}, None),
    ("a dir, then an error", ["c.conf"], {"c.conf": "dir sub\nhz x\n", "sub/k": ""}, None),
    ("an error on the standard input", ["-"], {}, "port 1\nhz x\n"),
    ("a port in use", ["--port", "{busy}"], {}, None),
    ("port 0", ["--port", "0"], {}, None),
    ("no address", ["--port", "{port}", "--bind", ""], {}, None),
]

# Cases both start: name, arguments, files, standard input, the
# parameters compared, the password
STARTED = [
    ("options after the file win", ["c.conf", "--port", "{port}", "--hz", "20"], {"c.conf": "port 1\nhz 5\n"}, None, ["port", "hz"], None),
    ("save points add up", ["--port", "{port}", "--save", "900 1", "--save", "300 10"], {}, None, ["save"], None),
    ("an empty save takes them away", ["c.conf", "--port", "{port}"], {"c.conf": 'save 900 1\nsave ""\nsave 60 5\n'}, None, ["save"], None),
    ("after an include, save starts again", ["c.conf", "--port", "{port}"], {"c.conf": "save 900 1\ninclude i.conf\nsave 60 5\n", "i.conf": "hz 20\n"}, None, ["save", "hz"], None),
    ("--save then an option", ["--save", "--port", "{port}"], {}, None, ["save"], None),
    ("--save last", ["--port", "{port}", "--save"], {}, None, ["save"], None),
    ("an option in one argument", ["--port {port}", "--hz", "20"], {}, None, ["hz"], None),
    ("a value starting with --", ["--port", "{port}", "--masterauth", "--x"], {}, None, ["masterauth"], None),
    ("other names", ["c.conf"], {"c.conf": "port {port}\nslaveof no one\nslave-read-only no\nhash-max-ziplist-entries 77\n"}, None, ["replica-read-only", "hash-max-listpack-entries", "replicaof"], None),
    ("names in any case", ["c.conf"], {"c.conf": "PORT {port}\nHz 30\n"}, None, ["hz"], None),
    ("quotes and escapes", ["c.conf"], {"c.conf": "port {port}\nmasterauth \"a\\x41 b\\tc\\\\\"\nreplica-announce-ip 'it\\'s'\n  \t# a comment\n"}, None, ["masterauth", "replica-announce-ip"], None),
    ("old names let go", ["c.conf"], {"c.conf": "port {port}\nlist-max-ziplist-entries 5\nlua-replicate-commands yes\nsentinel\n"}, None, ["port"], None),
    ("hz capped", ["--port", "{port}", "--hz", "1000"], {}, None, ["hz"], None),
    ("hz raised", ["--port", "{port}", "--hz", "0"], {}, None, ["hz"], None),
    ("a backlog as given", ["--port", "{port}", "--repl-backlog-size", "100"], {}, None, ["repl-backlog-size"], None),
    ("memory units and percents", ["--port", "{port}", "--maxmemory", "1gb", "--maxmemory-clients", "10%"], {}, None, ["maxmemory", "maxmemory-clients"], None),
    ("buffer limits", ["--port", "{port}", "--client-output-buffer-limit", "normal 1mb 2mb 60 replica 3 4 5"], {}, None, ["client-output-buffer-limit"], None),
    ("a quoted word of words", ["c.conf"], {"c.conf": "port {port}\noom-score-adj-values \"0 200 800\"\n"}, None, ["oom-score-adj-values"], None),
    ("words as they are", ["c.conf"], {"c.conf": "port {port}\nsave 900   1\n"}, None, ["save"], None),
    ("a relative directory", ["--port", "{port}", "--dir", "sub"], {"sub/x": ""}, None, ["dir"], None),
    ("a directory, then a relative include", ["c.conf"], {"c.conf": "port {port}\ndir sub\ninclude i.conf\n", "sub/i.conf": "hz 40\n"}, None, ["hz", "dir"], None),
    ("the standard input", ["-", "--port", "{port}"], {}, "hz 33\ntimeout 7\n", ["hz", "timeout"], None),
    ("the file, then the standard input", ["c.conf", "-"], {"c.conf": "port {port}\nhz 5\n"}, "hz 6\n", ["hz"], None),
    ("a password", ["--port", "{port}", "--requirepass", "p w"], {}, None, ["requirepass"], "p w"),
    ("events", ["--port", "{port}", "--notify-keyspace-events", "KEA"], {}, None, ["notify-keyspace-events"], None),
    ("percentiles", ["--port", "{port}", "--latency-tracking-info-percentiles", "50 99.9 1e1"], {}, None, ["latency-tracking-info-percentiles"], None),
    ("bit flags", ["--port", "{port}", "--shutdown-on-sigint", "nosave now"], {}, None, ["shutdown-on-sigint"], None),
    ("immutable ones", ["--port", "{port}", "--io-threads", "2", "--daemonize", "no", "--tcp-backlog", "100"], {}, None, ["io-threads", "daemonize", "tcp-backlog"], None),
    ("an empty file", ["c.conf", "--port", "{port}"], {"c.conf": ""}, None, ["port"], None),
    ("a directory as the file", ["d", "--port", "{port}"], {"d/x": ""}, None, ["port"], None),
    ("an include of an empty file", ["c.conf"], {"c.conf": "port {port}\ninclude e.conf\nhz 9\n", "e.conf": ""}, None, ["hz"], None),
    ("protected configs", ["--port", "{port}", "--enable-protected-configs", "yes", "--dbfilename", "x.rdb"], {}, None, ["enable-protected-configs", "dbfilename"], None),
]

# What BendKV refuses although Redis starts: name, arguments, files,
# environment, and the line said (on stderr, or as the log's last line)
BENDKV_REFUSES = [
    ("renamed commands", ["c.conf"], {"c.conf": 'rename-command FLUSHALL ""\n'}, {}, "BendKV cannot rename commands yet"),
    ("ACL users", ["c.conf"], {"c.conf": "user default on nopass ~* +@all\n"}, {}, "BendKV has no ACL users yet"),
    ("an include by a pattern", ["c.conf"], {"c.conf": "include *.inc\n"}, {}, "BendKV cannot include files by a pattern yet"),
    ("sentinel mode", ["--sentinel"], {}, {}, "BendKV has no sentinel mode"),
    ("a module", ["--port", "{port}", "--loadmodule", "/x.so"], {}, {}, "Can't load module from /x.so: server aborting"),
    ("a module's parameter", ["--port", "{port}", "--a.b", "1"], {}, {}, "Module Configuration detected without loadmodule directive or no ApplyConfig call: aborting"),
    ("the background", ["--port", "{port}", "--daemonize", "yes"], {}, {}, "BendKV cannot run in the background (daemonize yes): run it in the foreground, or under a supervisor"),
    ("a cluster", ["--port", "{port}", "--cluster-enabled", "yes"], {}, {}, "BendKV has no cluster mode: set cluster-enabled no"),
    ("a replica", ["--port", "{port}", "--replicaof", "127.0.0.1", "1"], {}, {}, "BendKV cannot be a replica: replicaof must be no one"),
    ("TLS", ["--port", "{port}", "--tls-port", "1"], {}, {}, "BendKV has no TLS: set tls-port 0"),
    ("systemd", ["--port", "{port}", "--supervised", "systemd"], {}, {"NOTIFY_SOCKET": "/run/x"}, "supervised by systemd, which BendKV cannot notify (READY=1): run it as a Type=simple service with supervised no"),
    ("upstart", ["--port", "{port}", "--supervised", "auto"], {}, {"UPSTART_JOB": "x"}, "supervised by upstart, which BendKV cannot signal (it cannot stop itself): run it unsupervised"),
    ("an RDB file", ["--port", "{port}"], {"dump.rdb": "REDIS0009"}, {}, "BendKV cannot load RDB files yet: {dir}/dump.rdb would be left out; move it away, or keep the data in an append-only file (appendonly yes)"),
    ("a multi-part append-only file", ["--port", "{port}", "--appendonly", "yes"], {"appendonlydir/appendonly.aof.manifest": "file appendonly.aof.1.incr.aof seq 1 type i\n"}, {}, "BendKV cannot read Redis 7's multi-part append-only files yet: {dir}/appendonlydir holds one"),
    ("a cut file, with aof-load-truncated no", ["--port", "{port}", "--appendonly", "yes", "--aof-load-truncated", "no"], {"appendonly.aof": "*3\r\n$3\r\nSET\r\n$1\r\na\r\n$1"}, {}, "Unexpected end of file reading the append only file appendonly.aof. You can: 1) Make a backup of your AOF file, then use ./redis-check-aof --fix <filename>. 2) Alternatively you can set the 'aof-load-truncated' configuration option to yes and restart the server."),
]


def check(name, ok, why=""):
    print(("OK:   " if ok else "FAIL: ") + name + ("" if ok else "\n      " + why))
    return ok


def refused(a, case):
    name, args, files, stdin = case
    if "{busy}" in " ".join(args):
        held = socket.socket()
        held.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        held.bind(("0.0.0.0", 0))
        held.listen(1)
        BUSY[0] = held.getsockname()[1]
    else:
        held = None
    r = Server(a, a.redis, args, files, stdin, {})
    b = Server(a, a.bin, args, files, stdin, {})
    try:
        rc, bc = r.up(), b.up()
        if rc is None or bc is None:
            return check("refused: " + name, False, "redis exit %s, bendkv exit %s" % (rc, bc))
        rr, br = r.report(), b.report()
        return check("refused: " + name, rc == bc and rr == br,
                     "redis %s %r\n      bendkv %s %r" % (rc, rr, bc, br))
    finally:
        r.stop()
        b.stop()
        if held is not None:
            held.close()


def started(a, case):
    name, args, files, stdin, names, auth = case
    r = Server(a, a.redis, args, files, stdin, {})
    b = Server(a, a.bin, args, files, stdin, {})
    try:
        rc, bc = r.up(), b.up()
        if rc is not None or bc is not None:
            return check("started: " + name, False, "redis exit %s %r, bendkv exit %s %r" % (rc, r.report(), bc, b.report()))
        rg, bg = r.get(names, auth), b.get(names, auth)
        return check("started: " + name, rg == bg, "redis %r\n      bendkv %r" % (rg, bg))
    finally:
        r.stop()
        b.stop()


def bendkv_refuses(a, case):
    name, args, files, env, line = case
    b = Server(a, a.bin, args, files, None, env)
    try:
        code = b.up()
        err, last = b.report()
        said = line in (err.strip().splitlines() or [""])[-1:] or last == line.replace("{dir}", "{dir}")
        return check("BendKV refuses: " + name, code == 1 and said, "exit %s, stderr %r, log %r" % (code, err, last))
    finally:
        b.stop()


def own(a):
    ok = True
    v = subprocess.run([a.bin, "--version"], capture_output=True, text=True)
    ok &= check("--version", v.returncode == 0 and v.stdout.startswith("BendKV server v="), repr(v))
    h = subprocess.run([a.bin, "-h"], capture_output=True, text=True)
    ok &= check("--help", h.returncode == 1 and h.stderr.startswith("Usage: ./bendkv"), repr(h))

    # the short form
    b = Server(a, a.bin, ["{port}", "send"], {}, None, {})
    ok &= check("the short form", b.up() is None and b.get(["port"], None) == {"port": "{port}"})
    b.stop()

    # the log in a file, the pid in another
    b = Server(a, a.bin, ["--port", "{port}", "--logfile", "l.log", "--pidfile", "p.pid", "--loglevel", "verbose"], {}, None, {})
    up = b.up() is None
    with open(os.path.join(b.dir, "l.log")) as f:
        log = f.read()
    with open(os.path.join(b.dir, "p.pid")) as f:
        pid = f.read()
    ok &= check("the log in logfile, the pid in pidfile",
                up and "Ready to accept connections" in log and b.text("out") == "" and pid == "%d\n" % b.p.pid,
                "log %r, stdout %r, pid %r" % (log[-200:], b.text("out"), pid))
    b.stop()

    # protected mode: 0.0.0.0 is the loopback, with a warning
    b = Server(a, a.bin, ["--port", "{port}", "--bind", "0.0.0.0"], {}, None, {})
    up = b.up() is None
    ok &= check("protected mode listens on the loopback",
                up and "listens on 127.0.0.1 for 0.0.0.0" in b.text("out"), b.text("out")[-300:])
    b.stop()

    # several addresses, one numbering of clients
    b = Server(a, a.bin, ["--port", "{port}", "--bind", "127.0.0.1 127.0.0.2"], {}, None, {})
    up = b.up() is None
    ids = []
    if up:
        for host in ("127.0.0.1", "127.0.0.2", "127.0.0.1"):
            c = Client(b.port, host)
            ids.append(c.ask("CLIENT", "ID"))
            c.close()
    ok &= check("two addresses, one count of clients", up and len(set(ids)) == 3, repr(ids))
    b.stop()

    # the log's level: warnings only leaves out the notices
    b = Server(a, a.bin, ["--port", "{port}", "--loglevel", "warning"], {}, None, {})
    up = b.up() is None
    out = b.text("out")
    ok &= check("loglevel warning leaves out the notices",
                up and "Server initialized" in out and "Ready to accept" not in out, out)
    b.stop()
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default="build/bendkv")
    ap.add_argument("--redis", default="redis-server")
    a = ap.parse_args()
    a.bin = os.path.abspath(a.bin)
    a.tmp = tempfile.mkdtemp(prefix="bendkv_start_")
    ok = True
    try:
        for case in REFUSED:
            ok &= refused(a, case)
        for case in STARTED:
            ok &= started(a, case)
        for case in BENDKV_REFUSES:
            ok &= bendkv_refuses(a, case)
        ok &= own(a)
    finally:
        shutil.rmtree(a.tmp, ignore_errors=True)
    print("ALL OK" if ok else "SOME CHECKS FAILED")
    return ok


if __name__ == "__main__":
    raise SystemExit(0 if main() else 1)
