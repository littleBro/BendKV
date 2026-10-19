#!/usr/bin/env python3
"""A diagnosis, for a throwaway branch: the floods of tests/obuf_test.py
(SETs from a client that must authenticate and does not read), many
times on BendKV posting and sending its replies, and on each flood that
stalls the sockets of its connection as the kernel has them
(/proc/net/tcp and ss), at once and after a while.

    python3 tests/obuf_diag.py --bin build/bendkv --port 6380 --dir build/diag
"""
import argparse
import os
import shutil
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import obuf_test as ob  # noqa: E402

STATES = {"01": "ESTABLISHED", "02": "SYN_SENT", "03": "SYN_RECV", "04": "FIN_WAIT1", "05": "FIN_WAIT2",
          "06": "TIME_WAIT", "07": "CLOSE", "08": "CLOSE_WAIT", "09": "LAST_ACK", "0A": "LISTEN", "0B": "CLOSING"}


def proc_lines(port):
    out = []
    for f in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            rows = open(f).read().splitlines()[1:]
        except OSError:
            continue
        for r in rows:
            p = r.split()
            lp = int(p[1].split(":")[1], 16)
            rp = int(p[2].split(":")[1], 16)
            if port in (lp, rp):
                out.append("  %s %s %d->%d tx:rx=%s timer=%s retr=%s inode=%s" % (
                    f[-4:], STATES.get(p[3], p[3]), lp, rp, p[4], p[5], p[6], p[9]))
    return out


def ss_lines(port):
    try:
        r = subprocess.run(["ss", "-tnoemi", "state", "all", "( sport = :%d or dport = :%d )" % (port, port)],
                           capture_output=True, text=True, timeout=5)
        return ["  ss: " + l for l in r.stdout.splitlines()]
    except Exception as e:
        return ["  ss: %r" % (e,)]


def dump(tag, port, lines):
    lines.append("   -- %s (%.3f)" % (tag, time.time()))
    lines.extend(proc_lines(port))
    lines.extend(ss_lines(port))


def flood(port, per, lines, limit=64 << 20, idle=2.0):
    s = ob.connect(port)
    me = s.getsockname()[1]
    s.setblocking(False)
    chunk = ob.enc("SET", "x", "5") * per
    t0 = time.time()
    sent, at, last, eagain = 0, 0, t0, 0
    while sent < limit:
        try:
            n = s.send(chunk[at:])
        except BlockingIOError:
            eagain += 1
            if time.time() - last > idle:
                lines.append(" flood %d port %d: stalled, sent %d bytes, last progress %.3f s after the start"
                             % (per, me, sent, last - t0))
                dump("at the stall", me, lines)
                time.sleep(1.0)
                dump("1 s later", me, lines)
                s.close()
                time.sleep(0.5)
                dump("0.5 s after the client closed", me, lines)
                return "stalled"
            time.sleep(0.01)
            continue
        except OSError as e:
            lines.append(" flood %d port %d: closed (%s) after %d bytes, %.3f s, last progress %.3f s"
                         % (per, me, type(e).__name__, sent, time.time() - t0, last - t0))
            s.close()
            return "closed"
        sent += n
        at = (at + n) % len(chunk)
        last = time.time()
    s.close()
    return "open after 64 MB"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--dir", required=True)
    ap.add_argument("--rounds", type=int, default=12)
    args = ap.parse_args()
    shutil.rmtree(args.dir, ignore_errors=True)
    for k in ("net/ipv4/tcp_rmem", "net/ipv4/tcp_wmem", "net/core/rmem_default", "net/core/wmem_default",
              "net/ipv4/tcp_moderate_rcvbuf", "net/ipv4/tcp_adv_win_scale"):
        try:
            print("%s = %s" % (k, open("/proc/sys/" + k).read().strip()))
        except OSError:
            pass
    print("kernel", os.uname().release, "cpus", os.cpu_count())
    stalls = 0
    for name, io in (("post", "2"), ("send", "1")):
        d = os.path.join(args.dir, name)
        os.makedirs(d)
        lg = os.path.join(args.dir, name + ".log")
        p = ob.up([args.bin, "--port", str(args.port), "--dir", d, "--save", "", "--requirepass", "pw",
                   "--io-threads", io], args.port, lg)
        lines = []
        tally = {}
        try:
            for r in range(args.rounds):
                for per in (4096, 1):
                    st = flood(args.port, per, lines)
                    tally[(per, st)] = tally.get((per, st), 0) + 1
                    stalls += st == "stalled"
        finally:
            time.sleep(0.3)
            p.terminate()
            p.wait()
        print("== %s: %s" % (name, sorted(tally.items())))
        for l in lines:
            print(l)
        print("   the server's lines:")
        for l in open(lg, errors="replace").read().splitlines():
            if "overcoming" in l:
                print("   " + l[:60] + " ... " + l[-90:])
    print("stalls: %d" % stalls)
    sys.exit(1 if stalls else 0)


if __name__ == "__main__":
    main()
