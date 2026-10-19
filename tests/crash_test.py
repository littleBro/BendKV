#!/usr/bin/env python3
"""The append-only file under crashes: BendKV killed with SIGKILL at a
random moment while clients write to it, then started again from its
file, round after round on the same file.

What is checked. The server runs the batches of all its connections
through one actor, one batch at a time, and appends their effects to the
file in that order: there is one order O of every command it ran, which
keeps each connection's order. A unit is a command, or a transaction
(MULTI to EXEC) as a whole. After a kill and a start, the databases the
start restored must be those a prefix of O leaves: the prefix's units
applied whole and in order to the databases of the round's start, and
nothing else; and the prefix must hold every unit acknowledged, whose
replies the client read (those read from its socket after the kill
included). The test does not see O whole; the load is made so that the
check is exact all the same:
- With one connection, O is the order it sent its units in: the
  databases must be those after its first p units, for some p from the
  units acknowledged to the units sent. That connection uses every key,
  SWAPDB and FLUSHDB among its commands.
- With several, each connection writes keys of its own (connection 3 the
  keys c3:..., in databases 0 to 3), and commands on different keys
  commute: each connection's keys must be those after its own first p_c
  units, for some p_c from its units acknowledged to its units sent, and
  every other key must be as it was. The connections also push ids onto
  lists they share (journal, in each of databases 0 to 3), whose order is
  O's: after its entries of the round's start, a journal must hold the ids
  those p_c units pushed onto it, each connection's in its order, and
  each acknowledged push at the place its RPUSH answered (the length
  after it). Together: the databases are those after a prefix of an order
  that keeps each connection's order and agrees with every reply read.
Units: SET with its options, APPEND, GETDEL, INCRBY, MSET, MSETNX, DEL,
RENAME, RENAMENX, COPY (to another database too), MOVE, PEXPIREAT (in the
past too: a delete), PERSIST, pushes, pops, LMOVE, LTRIM, LSET, HSET,
HDEL, HINCRBY, SADD, SREM, SMOVE, the STOREs of sets, ZADD, ZINCRBY,
ZREM, the ZPOPs, SELECT, transactions (a SELECT inside now and then) and
transactions discarded; a value now and then of several kilobytes. Each
unit's replies must be those a model of the commands gives (an id pushed
onto a shared journal aside): the model is what the databases after a
prefix are computed with.

SIGKILL stops the process, not the machine: what the server wrote to its
file is in the kernel's page cache, and the next start reads it. The
server answers a group of batches only once their effects are written
(and, with always, synced), so under SIGKILL every acknowledged unit must
be restored whatever the policy (always, everysec, no). What tells always
from the others shows only when the machine stops and its page cache is
lost. With --lazyfs, the server's directory (--run) is on a LazyFS mount,
and after each kill LazyFS drops every write not synced, as a machine
that stops would; every round then runs with always, and the property
above must hold all the same. (everysec may lose then what was
acknowledged in the last second or so, and the test does not know when
the server's syncer last ran; no loses all that no rewrite synced, so
--policy no must fail.) LazyFS makes a file and renames one at once, and
never drops a name: it does not check the syncs of the directory.

--break lose (or hole) damages the file after each kill as a durability
bug would: its last whole entry dropped, as if the server had answered
before writing it (or one of the twenty before it, a hole). The test must
then fail. And before any server, the check is tried on simulated rounds
(--self-check, 100 of each kind): a model plays the server, every
connection's units in one order that keeps each one's, cut at random; the
check must accept the databases after the cut, and refuse them without
one acknowledged unit's effect (self_check).

A round: 1 connection (a quarter of the rounds) or 2, 4, 8 or 16, each
pipelining up to 1 to 128 units, against a server started with a policy
and a way to send replies (its writer thread, or its loop: send)
drawn for the round; in some rounds a BGREWRITEAOF sent as the load runs,
or the cron's rewrites made frequent (auto-aof-rewrite-percentage), so
that kills land while a rewrite runs; the kill after a random time; the
replies left in the sockets read; the server started again, and in some
rounds killed again while it loads its file, then started once more. A
start only cuts the file: what it holds after one must be the start of
what the kill left (an entry or a transaction cut short cut off, which
its log names). Before the first round, 20,000 keys of every type
(ballast) go to database 9, where no unit writes, so that a rewrite and a
start take a while, and the file is rewritten (and not killed) between
rounds when it passes --max-file.

The seed is random unless given, and printed. A failing round prints what
failed, how to run the same rounds again (the same commands and the same
draws; where a kill lands depends on the machine), and keeps the file as
the kill left it, the file now, the server's logs and the units of each
connection around the cut in build/crash/fail-SEED-rROUND/, with what the
check ran on (round.pickle: --recheck runs it again there).

    python3 tests/crash_test.py --bin build/bendkv --port 6380 --dir build/crash --rounds 20 [--seed N]
    python3 tests/crash_test.py ... --run MOUNT/crash --lazyfs FAULTS_FIFO --lazyfs-done DONE_FIFO
    python3 tests/crash_test.py --recheck build/crash/fail-SEED-rROUND
"""
import argparse
import os
import pickle
import random
import re
import select
import selectors
import shutil
import signal
import socket
import subprocess
import sys
import time
import traceback

DBS = 16                 # the server's databases (its default)
WORK = 4                 # the databases units write: 0 to 3
BALLAST_DB = 9           # the ballast's database, where no unit writes
SLOTS = 16               # the connections' keys: c0: to c15:
KINDS = {b"s": 8, b"n": 4, b"l": 4, b"h": 4, b"t": 4, b"z": 4}
FAR = int(time.time() * 1000) + 10**10   # times to expire at, long after the test
JOURNAL = b"journal"
AOF = "crash.aof"
OK = ("+", b"OK")
QUEUED = ("+", b"QUEUED")
ERR = ("-", None)
MEMBERS = [b"%d" % i for i in range(8)] + [b"w%d" % i for i in range(4)]
ZMEMBERS = [b"m%d" % i for i in range(10)]


def enc(cmds):
    out = []
    for c in cmds:
        out.append(b"*%d\r\n" % len(c))
        for x in c:
            out.append(b"$%d\r\n%s\r\n" % (len(x), x))
    return b"".join(out)


class Parser:
    """Replies read from a stream as it comes: ('+', text), ('-', text),
    (':', int), ('$', bytes or None), ('*', list or None)."""

    def __init__(self):
        self.buf = bytearray()
        self.pos = 0

    def feed(self, data):
        if self.pos > (1 << 20):
            del self.buf[:self.pos]
            self.pos = 0
        self.buf += data

    def get(self):
        r = self._at(self.pos)
        if r is None:
            return None
        self.pos = r[1]
        return r[0]

    def _at(self, i):
        buf = self.buf
        j = buf.find(b"\r\n", i)
        if j < 0:
            return None
        t = buf[i]
        if t == 43:
            return ("+", bytes(buf[i + 1:j])), j + 2
        if t == 45:
            return ("-", bytes(buf[i + 1:j])), j + 2
        if t == 58:
            return (":", int(buf[i + 1:j])), j + 2
        if t == 36:
            n = int(buf[i + 1:j])
            if n < 0:
                return ("$", None), j + 2
            if len(buf) < j + 4 + n:
                return None
            return ("$", bytes(buf[j + 2:j + 2 + n])), j + 4 + n
        if t == 42:
            n = int(buf[i + 1:j])
            if n < 0:
                return ("*", None), j + 2
            items = []
            k = j + 2
            for _ in range(n):
                r = self._at(k)
                if r is None:
                    return None
                items.append(r[0])
                k = r[1]
            return ("*", items), k
        raise ValueError("not a reply: %r" % bytes(buf[i:i + 40]))


class Conn:
    """A blocking connection: commands sent at once, then their replies."""

    def __init__(self, port, timeout=300):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=timeout)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.p = Parser()

    def call(self, cmds):
        self.sock.sendall(enc(cmds))
        out = []
        while len(out) < len(cmds):
            r = self.p.get()
            if r is None:
                data = self.sock.recv(1 << 20)
                if not data:
                    raise EOFError("the server closed the connection")
                self.p.feed(data)
            else:
                out.append(r)
        return out

    def close(self):
        self.sock.close()


def info(c, section=b"persistence"):
    text = c.call([[b"INFO", section]])[0][1].decode()
    return dict(line.split(":", 1) for line in text.split("\r\n") if ":" in line)


# The model
# ---------
# A database is a dict of its keys' entries: [kind, value, the time it
# expires at or None]; a value is the string's bytes, the list's elements,
# the hash's dict, the set's members or the sorted set's dict of scores.

def norm(e):
    """An entry as the dump reads it back, to compare."""
    if e is None:
        return None
    k, v, t = e
    if k == "string":
        return (k, v, t)
    if k == "list":
        return (k, tuple(v), t)
    if k == "hash":
        return (k, tuple(sorted(v.items())), t)
    if k == "set":
        return (k, tuple(sorted(v)), t)
    return (k, tuple(sorted(v.items(), key=lambda x: (x[1], x[0]))), t)


def entry(n):
    k, v, t = n
    if k == "string":
        return [k, v, t]
    if k == "list":
        return [k, list(v), t]
    if k in ("hash", "zset"):
        return [k, dict(v), t]
    return [k, set(v), t]


def copy_of(v):
    return v if isinstance(v, bytes) else type(v)(v)


class Model:
    """The databases as Redis 7.0.15 runs the commands of the load: each
    command gives the reply foreseen (an error as ERR, whatever its text),
    and records the keys it changes in touched while that is a set."""

    def __init__(self, dbs=None):
        self.dbs = dbs or [{} for _ in range(DBS)]
        self.touched = None
        self.shared = False   # several connections push onto the journals

    @classmethod
    def of(cls, dump):
        dbs = [{} for _ in range(DBS)]
        for (db, k), n in dump.items():
            dbs[db][k] = entry(n)
        return cls(dbs)

    def keys(self):
        return {(db, k) for db, d in enumerate(self.dbs) for k in d}

    def norm(self, dk):
        return norm(self.dbs[dk[0]].get(dk[1]))

    def get(self, db, k):
        return self.dbs[db].get(k)

    def mark(self, db, k):
        if self.touched is not None:
            self.touched.add((db, k))

    def put(self, db, k, e):
        self.dbs[db][k] = e
        self.mark(db, k)

    def drop(self, db, k):
        if k in self.dbs[db]:
            del self.dbs[db][k]
            self.mark(db, k)
            return True
        return False

    def coll(self, db, k, kind, new):
        e = self.get(db, k)
        if e is None:
            e = [kind, new(), None]
            self.put(db, k, e)
        else:
            self.mark(db, k)
        return e

    def emptied(self, db, k, e):
        self.mark(db, k)
        if not e[1]:
            self.drop(db, k)

    def apply(self, u, db, pushes):
        """Unit u run on database db: its replies foreseen (None for one
        another connection decides), the database after it; the ids it
        pushes onto a journal appended to pushes as (db, id, its command's
        place in the unit)."""
        if u.kind == "discard":
            return [OK] + [QUEUED] * len(u.cmds) + [OK], db
        reps = []
        for i, c in enumerate(u.cmds):
            if c[0] == b"RPUSH" and c[1] == JOURNAL:
                pushes.append((db, c[2], i))
            r, db = self.run(db, c)
            reps.append(r)
        if u.kind == "cmd":
            return reps, db
        return [OK] + [QUEUED] * len(u.cmds) + [("*", reps)], db

    def run(self, db, a):
        if a[0] == b"SELECT":
            return OK, int(a[1])
        r = getattr(self, "c_" + a[0].decode().lower())(db, a)
        if self.shared and len(a) > 1 and a[1] == JOURNAL:
            r = None
        return r, db

    def c_set(self, db, a):
        k, v = a[1], a[2]
        nx = xx = get = keep = False
        t = None
        i = 3
        while i < len(a):
            if a[i] == b"PXAT":
                t = int(a[i + 1])
                i += 1
            else:
                nx |= a[i] == b"NX"
                xx |= a[i] == b"XX"
                get |= a[i] == b"GET"
                keep |= a[i] == b"KEEPTTL"
            i += 1
        e = self.get(db, k)
        old = ("$", e[1] if e else None)
        if (nx and e) or (xx and not e):
            return old if get else ("$", None)
        if t is None and keep and e:
            t = e[2]
        self.put(db, k, ["string", v, t])
        return old if get else OK

    def c_append(self, db, a):
        e = self.get(db, a[1])
        if e:
            e[1] = e[1] + a[2]
            self.mark(db, a[1])
        else:
            e = ["string", a[2], None]
            self.put(db, a[1], e)
        return (":", len(e[1]))

    def c_getdel(self, db, a):
        e = self.get(db, a[1])
        if not e:
            return ("$", None)
        self.drop(db, a[1])
        return ("$", e[1])

    def c_incrby(self, db, a):
        e = self.get(db, a[1])
        v = (int(e[1]) if e else 0) + int(a[2])
        if e:
            e[1] = b"%d" % v
            self.mark(db, a[1])
        else:
            self.put(db, a[1], ["string", b"%d" % v, None])
        return (":", v)

    def c_decrby(self, db, a):
        return self.c_incrby(db, [a[0], a[1], b"%d" % -int(a[2])])

    def c_mset(self, db, a):
        for i in range(1, len(a), 2):
            self.put(db, a[i], ["string", a[i + 1], None])
        return OK

    def c_msetnx(self, db, a):
        if any(self.get(db, a[i]) for i in range(1, len(a), 2)):
            return (":", 0)
        self.c_mset(db, a)
        return (":", 1)

    def c_del(self, db, a):
        return (":", sum(1 for k in a[1:] if self.drop(db, k)))

    def c_rename(self, db, a, nx=False):
        s, d = a[1], a[2]
        e = self.get(db, s)
        if not e:
            return ERR
        if s == d:
            return (":", 0) if nx else OK
        if nx and self.get(db, d):
            return (":", 0)
        self.drop(db, s)
        self.put(db, d, e)
        return (":", 1) if nx else OK

    def c_renamenx(self, db, a):
        return self.c_rename(db, a, True)

    def c_copy(self, db, a):
        to, rep = db, False
        i = 3
        while i < len(a):
            if a[i] == b"DB":
                to = int(a[i + 1])
                i += 1
            rep |= a[i] == b"REPLACE"
            i += 1
        if a[1] == a[2] and to == db:
            return ERR
        e = self.get(db, a[1])
        if not e or (self.get(to, a[2]) and not rep):
            return (":", 0)
        self.put(to, a[2], [e[0], copy_of(e[1]), e[2]])
        return (":", 1)

    def c_move(self, db, a):
        to = int(a[2])
        if to == db:
            return ERR
        e = self.get(db, a[1])
        if not e or self.get(to, a[1]):
            return (":", 0)
        self.drop(db, a[1])
        self.put(to, a[1], e)
        return (":", 1)

    def c_pexpireat(self, db, a):
        e = self.get(db, a[1])
        if not e:
            return (":", 0)
        t = int(a[2])
        if t <= time.time() * 1000:
            self.drop(db, a[1])
        else:
            e[2] = t
            self.mark(db, a[1])
        return (":", 1)

    def c_persist(self, db, a):
        e = self.get(db, a[1])
        if not e or e[2] is None:
            return (":", 0)
        e[2] = None
        self.mark(db, a[1])
        return (":", 1)

    def c_rpush(self, db, a):
        e = self.coll(db, a[1], "list", list)
        e[1].extend(a[2:])
        return (":", len(e[1]))

    def c_lpush(self, db, a):
        e = self.coll(db, a[1], "list", list)
        for x in a[2:]:
            e[1].insert(0, x)
        return (":", len(e[1]))

    def pop(self, db, a, left):
        e = self.get(db, a[1])
        if len(a) > 2:
            if not e:
                return ("*", None)
            xs = []
            for _ in range(int(a[2])):
                if e[1]:
                    xs.append(("$", e[1].pop(0) if left else e[1].pop()))
            self.emptied(db, a[1], e)
            return ("*", xs)
        if not e:
            return ("$", None)
        x = e[1].pop(0) if left else e[1].pop()
        self.emptied(db, a[1], e)
        return ("$", x)

    def c_lpop(self, db, a):
        return self.pop(db, a, True)

    def c_rpop(self, db, a):
        return self.pop(db, a, False)

    def c_lmove(self, db, a):
        s, d = a[1], a[2]
        e = self.get(db, s)
        if not e:
            return ("$", None)
        x = e[1].pop(0) if a[3] == b"LEFT" else e[1].pop()
        self.mark(db, s)
        f = e if s == d else self.coll(db, d, "list", list)
        if a[4] == b"LEFT":
            f[1].insert(0, x)
        else:
            f[1].append(x)
        self.emptied(db, s, e)
        return ("$", x)

    def c_ltrim(self, db, a):
        e = self.get(db, a[1])
        if not e:
            return OK
        n, start, end = len(e[1]), int(a[2]), int(a[3])
        start = start + n if start < 0 else start
        end = end + n if end < 0 else end
        start = max(start, 0)
        e[1] = [] if start > end or start >= n else e[1][start:min(end, n - 1) + 1]
        self.emptied(db, a[1], e)
        return OK

    def c_lset(self, db, a):
        e = self.get(db, a[1])
        if not e:
            return ERR
        i = int(a[2])
        i = i + len(e[1]) if i < 0 else i
        if not 0 <= i < len(e[1]):
            return ERR
        e[1][i] = a[3]
        self.mark(db, a[1])
        return OK

    def c_hset(self, db, a):
        e = self.coll(db, a[1], "hash", dict)
        n = 0
        for i in range(2, len(a), 2):
            n += a[i] not in e[1]
            e[1][a[i]] = a[i + 1]
        return (":", n)

    def c_hdel(self, db, a):
        e = self.get(db, a[1])
        if not e:
            return (":", 0)
        n = 0
        for f in a[2:]:
            if f in e[1]:
                del e[1][f]
                n += 1
        self.emptied(db, a[1], e)
        return (":", n)

    def c_hincrby(self, db, a):
        e = self.coll(db, a[1], "hash", dict)
        v = int(e[1].get(a[2], b"0")) + int(a[3])
        e[1][a[2]] = b"%d" % v
        return (":", v)

    def c_sadd(self, db, a):
        e = self.coll(db, a[1], "set", set)
        n = len(e[1])
        e[1].update(a[2:])
        return (":", len(e[1]) - n)

    def c_srem(self, db, a):
        e = self.get(db, a[1])
        if not e:
            return (":", 0)
        n = 0
        for m in a[2:]:
            if m in e[1]:
                e[1].discard(m)
                n += 1
        self.emptied(db, a[1], e)
        return (":", n)

    def c_smove(self, db, a):
        s, d, m = a[1], a[2], a[3]
        e = self.get(db, s)
        if not e:
            return (":", 0)
        if s == d:
            return (":", int(m in e[1]))
        if m not in e[1]:
            return (":", 0)
        e[1].discard(m)
        self.emptied(db, s, e)
        self.coll(db, d, "set", set)[1].add(m)
        return (":", 1)

    def store(self, db, a, op):
        es = [self.get(db, k) for k in a[2:]]
        res = op([e[1] if e else set() for e in es], es)
        if res:
            self.put(db, a[1], ["set", set(res), None])
        else:
            self.drop(db, a[1])
        return (":", len(res))

    def c_sinterstore(self, db, a):
        return self.store(db, a, lambda xs, es: set.intersection(*xs) if all(es) else set())

    def c_sunionstore(self, db, a):
        return self.store(db, a, lambda xs, es: set().union(*xs))

    def c_sdiffstore(self, db, a):
        return self.store(db, a, lambda xs, es: xs[0] - set().union(*xs[1:]))

    def c_zadd(self, db, a):
        i, nx, xx = 2, False, False
        while a[i] in (b"NX", b"XX"):
            nx |= a[i] == b"NX"
            xx |= a[i] == b"XX"
            i += 1
        e = self.get(db, a[1])
        if not e and xx:
            return (":", 0)
        e = self.coll(db, a[1], "zset", dict)
        n = 0
        for j in range(i, len(a), 2):
            s, m = int(a[j]), a[j + 1]
            if m in e[1]:
                if not nx:
                    e[1][m] = s
            elif not xx:
                e[1][m] = s
                n += 1
        return (":", n)

    def c_zincrby(self, db, a):
        e = self.coll(db, a[1], "zset", dict)
        v = e[1].get(a[3], 0) + int(a[2])
        e[1][a[3]] = v
        return ("$", b"%d" % v)

    def c_zrem(self, db, a):
        e = self.get(db, a[1])
        if not e:
            return (":", 0)
        n = 0
        for m in a[2:]:
            if m in e[1]:
                del e[1][m]
                n += 1
        self.emptied(db, a[1], e)
        return (":", n)

    def zpop(self, db, a, top):
        e = self.get(db, a[1])
        if not e:
            return ("*", [])
        n = int(a[2]) if len(a) > 2 else 1
        out = []
        for m, s in sorted(e[1].items(), key=lambda x: (x[1], x[0]), reverse=top)[:n]:
            del e[1][m]
            out += [("$", m), ("$", b"%d" % s)]
        self.emptied(db, a[1], e)
        return ("*", out)

    def c_zpopmin(self, db, a):
        return self.zpop(db, a, False)

    def c_zpopmax(self, db, a):
        return self.zpop(db, a, True)

    def c_swapdb(self, db, a):
        x, y = int(a[1]), int(a[2])
        self.dbs[x], self.dbs[y] = self.dbs[y], self.dbs[x]
        if self.touched is not None:
            self.touched |= {("*", x), ("*", y)}
        return OK

    def c_flushdb(self, db, a):
        self.dbs[db] = {}
        if self.touched is not None:
            self.touched.add(("*", db))
        return OK


def same(want, got):
    """A reply foreseen and one read: an error as an error, whatever its text."""
    if want is None:
        return True
    if want[0] == "-":
        return got[0] == "-"
    if want[0] == "*" and want[1] is not None:
        return got[0] == "*" and got[1] is not None and len(got[1]) == len(want[1]) and \
            all(same(w, g) for w, g in zip(want[1], got[1]))
    return want == got


# The load
# --------

class Unit:
    """A command (kind cmd), a transaction (tx: MULTI, the commands, EXEC)
    or one discarded (discard); got: its replies, once all were read."""
    __slots__ = ("kind", "cmds", "got", "nrep")

    def __init__(self, kind, cmds):
        self.kind = kind
        self.cmds = cmds
        self.got = None
        self.nrep = len(cmds) if kind == "cmd" else len(cmds) + 2

    def wire(self):
        if self.kind == "cmd":
            return self.cmds
        return [[b"MULTI"]] + self.cmds + [[b"EXEC" if self.kind == "tx" else b"DISCARD"]]


class Gen:
    """The units of one connection in one round, from a seed of their own:
    on the keys of its slot (of every slot when it is alone), each value
    naming the round, the slot and the unit."""

    def __init__(self, seed, rnd, slot, alone, big=False, whole=False):
        self.r = random.Random("%d:%d:%d" % (seed, rnd, slot))
        self.tag = b"%x.%x." % (rnd, slot)
        self.slots = list(range(SLOTS)) if alone else [slot]
        self.alone = alone
        self.big = big
        self.seq = 0
        self.pushes = 0
        table = [(14, self.set), (3, self.append), (1, self.getdel), (5, self.incrby), (5, self.mset),
                 (2, self.msetnx), (3, self.delete), (4, self.rename), (3, self.copy), (3, self.move),
                 (3, self.pexpireat), (1, self.persist), (8, self.push), (4, self.pop), (3, self.lmove),
                 (1, self.ltrim), (1, self.lset), (5, self.hset), (2, self.hdel), (3, self.hincrby),
                 (4, self.sadd), (2, self.srem), (2, self.smove), (2, self.sstore), (4, self.zadd),
                 (2, self.zincrby), (2, self.zrem), (2, self.zpop), (3, self.select), (6, self.journal)]
        if alone:
            # whole: the commands that change a database whole, often (the
            # check's own test)
            table += [(6, self.swapdb), (6, self.flushdb)] if whole else [(0.3, self.swapdb), (0.02, self.flushdb)]
        self.makers = [f for _, f in table]
        self.weights = []
        acc = 0
        for w, _ in table:
            acc += w
            self.weights.append(acc)

    def unit(self):
        self.seq += 1
        x = self.r.random()
        if x < 0.10:
            return Unit("tx", [self.cmd() for _ in range(self.r.randint(2, 6))])
        if x < 0.11:
            return Unit("discard", [self.cmd() for _ in range(self.r.randint(1, 3))])
        return Unit("cmd", [self.cmd()])

    def cmd(self):
        return self.r.choices(self.makers, cum_weights=self.weights)[0]()

    def key(self, kind, slot=None):
        if slot is None:
            slot = self.r.choice(self.slots)
        return b"c%d:%s%d" % (slot, kind, self.r.randrange(KINDS[kind]))

    def pair(self, kind):
        slot = self.r.choice(self.slots)
        return self.key(kind, slot), self.key(kind, slot)

    def any_key(self):
        return self.key(self.r.choice(list(KINDS)))

    def val(self):
        v = self.tag + b"%x" % self.seq
        x = self.r.random()
        if x < 0.25:
            v += b"-" + self.r.randbytes(self.r.randrange(1, 40))
        elif x < 0.27:
            v += b"-" + self.r.randbytes(self.r.randrange(1024, 8192))
        elif x < 0.28 and self.big:
            # a write of a group long enough for a kill to stop it in its
            # middle (the kernel looks for a fatal signal between pages)
            v += b"-" + self.r.randbytes(self.r.randrange(65536, 524288))
        return v

    def num(self, n=1000):
        return b"%d" % self.r.randint(-n, n)

    def set(self):
        c = [b"SET", self.key(b"s"), self.val()]
        x = self.r.random()
        if x < 0.15:
            c += [b"PXAT", b"%d" % (FAR + self.r.randrange(10**9))]
        elif x < 0.25:
            c += [b"KEEPTTL"]
        elif x < 0.33:
            c += [b"NX"]
        elif x < 0.41:
            c += [b"XX"]
        elif x < 0.49:
            c += [b"GET"]
        return c

    def append(self):
        return [b"APPEND", self.key(b"s"), self.val()]

    def getdel(self):
        return [b"GETDEL", self.key(b"s")]

    def incrby(self):
        return [self.r.choice([b"INCRBY", b"DECRBY"]), self.key(b"n"), self.num()]

    def mset(self, name=b"MSET"):
        slot = self.r.choice(self.slots)
        c = [name]
        for _ in range(self.r.randint(1, 4)):
            if self.r.random() < 0.3:
                c += [self.key(b"n", slot), self.num()]
            else:
                c += [self.key(b"s", slot), self.val()]
        return c

    def msetnx(self):
        return self.mset(b"MSETNX")

    def delete(self):
        return [b"DEL"] + [self.any_key() for _ in range(self.r.randint(1, 3))]

    def rename(self):
        return [self.r.choice([b"RENAME", b"RENAMENX"])] + list(self.pair(self.r.choice(list(KINDS))))

    def copy(self):
        c = [b"COPY"] + list(self.pair(self.r.choice(list(KINDS))))
        if self.r.random() < 0.5:
            c += [b"DB", b"%d" % self.r.randrange(WORK)]
        if self.r.random() < 0.5:
            c += [b"REPLACE"]
        return c

    def move(self):
        return [b"MOVE", self.any_key(), b"%d" % self.r.randrange(WORK)]

    def pexpireat(self):
        t = FAR + self.r.randrange(10**9) if self.r.random() < 0.9 else self.r.randint(1, 10**6)
        return [b"PEXPIREAT", self.any_key(), b"%d" % t]

    def persist(self):
        return [b"PERSIST", self.any_key()]

    def push(self):
        return [self.r.choice([b"RPUSH", b"LPUSH"]), self.key(b"l")] + \
            [self.tag + b"%x.%d" % (self.seq, i) for i in range(self.r.randint(1, 4))]

    def pop(self):
        return [self.r.choice([b"LPOP", b"RPOP"]), self.key(b"l")] + \
            ([b"%d" % self.r.randint(1, 3)] if self.r.random() < 0.3 else [])

    def lmove(self):
        return [b"LMOVE"] + list(self.pair(b"l")) + [self.r.choice([b"LEFT", b"RIGHT"]), self.r.choice([b"LEFT", b"RIGHT"])]

    def ltrim(self):
        return [b"LTRIM", self.key(b"l"), b"%d" % self.r.randint(-5, 5), b"%d" % self.r.randint(-5, 5)]

    def lset(self):
        return [b"LSET", self.key(b"l"), b"%d" % self.r.randint(-4, 4), self.val()]

    def hset(self):
        c = [b"HSET", self.key(b"h")]
        for _ in range(self.r.randint(1, 3)):
            c += [b"f%d" % self.r.randrange(6), self.val()]
        return c

    def hdel(self):
        fields = [self.r.choice([b"f%d" % self.r.randrange(6), b"i%d" % self.r.randrange(3)])
                  for _ in range(self.r.randint(1, 2))]
        return [b"HDEL", self.key(b"h")] + fields

    def hincrby(self):
        return [b"HINCRBY", self.key(b"h"), b"i%d" % self.r.randrange(3), self.num(100)]

    def sadd(self):
        return [b"SADD", self.key(b"t")] + self.r.sample(MEMBERS, self.r.randint(1, 4))

    def srem(self):
        return [b"SREM", self.key(b"t")] + self.r.sample(MEMBERS, self.r.randint(1, 2))

    def smove(self):
        return [b"SMOVE"] + list(self.pair(b"t")) + [self.r.choice(MEMBERS)]

    def sstore(self):
        slot = self.r.choice(self.slots)
        return [self.r.choice([b"SINTERSTORE", b"SUNIONSTORE", b"SDIFFSTORE"])] + \
            [self.key(b"t", slot) for _ in range(3)]

    def zadd(self):
        c = [b"ZADD", self.key(b"z")] + self.r.choice([[], [], [b"NX"], [b"XX"]])
        for _ in range(self.r.randint(1, 3)):
            c += [b"%d" % self.r.randint(-20, 20), self.r.choice(ZMEMBERS)]
        return c

    def zincrby(self):
        return [b"ZINCRBY", self.key(b"z"), b"%d" % self.r.randint(-5, 5), self.r.choice(ZMEMBERS)]

    def zrem(self):
        return [b"ZREM", self.key(b"z")] + self.r.sample(ZMEMBERS, self.r.randint(1, 2))

    def zpop(self):
        return [self.r.choice([b"ZPOPMIN", b"ZPOPMAX"]), self.key(b"z")] + \
            ([b"%d" % self.r.randint(1, 3)] if self.r.random() < 0.5 else [])

    def select(self):
        return [b"SELECT", b"%d" % self.r.randrange(WORK)]

    def journal(self):
        self.pushes += 1
        return [b"RPUSH", JOURNAL, self.tag + b"j%x" % self.pushes]

    def swapdb(self):
        return [b"SWAPDB", b"%d" % self.r.randrange(WORK), b"%d" % self.r.randrange(WORK)]

    def flushdb(self):
        return [b"FLUSHDB"]


class Client:
    """A connection that pipelines its units, up to depth of them waiting
    for their replies; sent: the units written whole to the socket, acked:
    those whose replies were all read."""

    def __init__(self, port, slot, gen, depth):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=60)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.sock.setblocking(False)
        self.slot = slot
        self.gen = gen
        self.depth = depth
        self.units = []
        self.ends = []
        self.made = 0
        self.written = 0
        self.out = bytearray()
        self.sent = 0
        self.acked = 0
        self.cur = []
        self.p = Parser()
        self.alive = True
        self.db = 0
        self.pushed = []     # (db, id, place in its journal) of each push acknowledged

    def fill(self):
        if not self.alive or self.out:
            return
        n = self.depth - (len(self.units) - self.acked)
        if n < max(1, self.depth // 2):
            return
        parts = []
        for _ in range(n):
            u = self.gen.unit()
            b = enc(u.wire())
            self.units.append(u)
            self.made += len(b)
            self.ends.append(self.made)
            parts.append(b)
        self.out += b"".join(parts)
        self.flush()

    def flush(self):
        try:
            n = self.sock.send(self.out)
        except BlockingIOError:
            return
        except OSError:
            self.alive = False
            return
        del self.out[:n]
        self.written += n
        while self.sent < len(self.ends) and self.ends[self.sent] <= self.written:
            self.sent += 1

    def take(self, data):
        self.p.feed(data)
        while True:
            r = self.p.get()
            if r is None:
                return
            self.cur.append(r)
            u = self.units[self.acked]
            if len(self.cur) == u.nrep:
                u.got = self.cur
                self.cur = []
                self.acked += 1

    def read(self):
        try:
            data = self.sock.recv(1 << 18)
        except BlockingIOError:
            return
        except OSError:
            self.alive = False
            return
        if not data:
            self.alive = False
            return
        self.take(data)

    def drain(self):
        """The replies the server sent before it died, still in the socket."""
        self.sock.setblocking(True)
        self.sock.settimeout(10)
        while True:
            try:
                data = self.sock.recv(1 << 18)
            except OSError:
                break
            if not data:
                break
            self.take(data)
        self.alive = False
        self.sock.close()


# The server
# ----------

class Server:
    """A BendKV process on the file; every one started is in ALL, so that
    none outlives the test. It starts in BendKV's short form, which keeps
    the single file (one started with appendonly yes in the
    configuration's form makes Redis 7's directory): its port, its
    replies posted to its writer thread or sent from its loop, the file
    and the policy, in --run, its working directory and so its dir (on
    127.0.0.1, with no save points)."""
    ALL = []

    def __init__(self, a, policy, send, log):
        Server.ALL.append(self)
        self.log = log
        argv = [os.path.abspath(a.bin), str(a.port), "send" if send else "post", AOF, policy]
        self.t0 = time.monotonic()
        with open(log, "wb") as f:
            self.p = subprocess.Popen(argv, stdout=f, stderr=subprocess.STDOUT, cwd=os.path.abspath(a.run))

    def ready(self, port, timeout=300):
        """The seconds to the first PONG; None if the process ended first.
        The PONG must come from this process, not from another server on the
        port (one left by a run that was killed)."""
        end = self.t0 + timeout
        while time.monotonic() < end:
            if self.p.poll() is not None:
                return None
            try:
                s = socket.create_connection(("127.0.0.1", port), timeout=1)
            except OSError:
                time.sleep(0.005)
                continue
            try:
                s.sendall(b"PING\r\n")
                buf = b""
                while time.monotonic() < end and self.p.poll() is None:
                    try:
                        data = s.recv(64)
                    except socket.timeout:
                        continue
                    if not data:
                        break
                    buf += data
                    if buf.startswith(b"+PONG\r\n"):
                        t = time.monotonic() - self.t0
                        c = Conn(port)
                        pid = info(c, b"server").get("process_id")
                        c.close()
                        if pid != str(self.p.pid):
                            raise Failed(["port %d is another server's (pid %s)" % (port, pid)])
                        return t
            except (OSError, EOFError):
                pass
            finally:
                s.close()
        return None

    def alive(self):
        return self.p.poll() is None

    def kill(self):
        if self.p.poll() is None:
            os.kill(self.p.pid, signal.SIGKILL)
        self.p.wait()

    def text(self):
        with open(self.log, "rb") as f:
            return f.read().decode(errors="replace")


def stage(text):
    """How far a start's log goes: where a kill stopped it."""
    if "Ready to accept connections" in text:
        return "serving"
    if "BendKV restored" in text:
        return "after the load"
    if "Server initialized" in text:
        return "loading"
    return "before the load"


def cut_logged(text):
    """The bytes a start's log says it cut from the file's end."""
    return sum(int(n) for n in re.findall(r"BendKV cut (\d+) bytes of", text))


# The dump
# --------

READS = {b"string": lambda k: [b"GET", k], b"list": lambda k: [b"LRANGE", k, b"0", b"-1"],
         b"hash": lambda k: [b"HGETALL", k], b"set": lambda k: [b"SMEMBERS", k],
         b"zset": lambda k: [b"ZRANGE", k, b"0", b"-1", b"WITHSCORES"]}


def score(s):
    f = float(s)
    return int(f) if f.is_integer() else f


def read_back(t, rep, ttl):
    t = t.decode()
    pxat = None if ttl == -1 else ttl
    if t == "string":
        return (t, rep[1], pxat)
    xs = [x[1] for x in rep[1]]
    if t == "list":
        return (t, tuple(xs), pxat)
    if t == "hash":
        return (t, tuple(sorted(zip(xs[0::2], xs[1::2]))), pxat)
    if t == "set":
        return (t, tuple(sorted(xs)), pxat)
    return (t, tuple((m, score(s)) for m, s in zip(xs[0::2], xs[1::2])), pxat)


def dump(port):
    """The databases the server holds: (db, key) -> (kind, value, time)."""
    c = Conn(port)
    try:
        dbs = [int(k[2:]) for k in info(c, b"keyspace") if k.startswith("db")]
        out = {}
        for db in dbs:
            c.call([[b"SELECT", b"%d" % db]])
            names = [x[1] for x in c.call([[b"KEYS", b"*"]])[0][1]]
            for i in range(0, len(names), 2000):
                ks = names[i:i + 2000]
                types = [t[1] for t in c.call([[b"TYPE", k] for k in ks])]
                reps = c.call([x for k, t in zip(ks, types) for x in (READS[t](k), [b"PEXPIRETIME", k])])
                for j, (k, t) in enumerate(zip(ks, types)):
                    out[(db, k)] = read_back(t, reps[2 * j], reps[2 * j + 1][1])
        return out
    finally:
        c.close()


# The check
# ---------

def owner(k):
    """The slot whose keys k is among, or None."""
    if k[:1] == b"c":
        i = k.find(b":")
        if i > 1 and k[1:i].isdigit():
            return int(k[1:i])
    return None


def id_of(x):
    """The round and slot of a journal's id."""
    r, s, _ = x.split(b".", 2)
    return int(r, 16), int(s, 16)


def show(n, width=100):
    s = repr(n)
    return s if len(s) <= width else s[:width] + "..."


def differ(R, M, ks):
    return ["  %d %r: restored %s, model %s" % (db, k, show(R.get((db, k))), show(M.norm((db, k))))
            for db, k in sorted(ks)[:12]]


def expand(touched, R, M, rdb, D):
    """The keys a step may have changed: those it named; and for a database
    it changed whole (SWAPDB, FLUSHDB), every key the model or the restored
    databases hold there, and every key that differed there before it."""
    out = set()
    whole = set()
    for dk in touched:
        if dk[0] == "*":
            whole.add(dk[1])
        else:
            out.add(dk)
    for d in whole:
        out |= {(d, k) for k in M.dbs[d]} | rdb.get(d, set())
    if whole:
        out |= {dk for dk in D if dk[0] in whole}
    return out


def step_through(R, M, c, D, keep, rdb, ok=lambda p: True):
    """The counts p of the connection's units, from those acknowledged to
    those sent, after which the keys keep(k) holds read as the model's
    (D: those that differ after the acknowledged ones), and ok(p); when
    none, the closest count, with the keys that differ then. M is left
    after all of them."""
    found = [c.acked] if not D and ok(c.acked) else []
    best = (len(D), c.acked, differ(R, M, D))
    db = c.db
    for p in range(c.acked, c.sent):
        M.touched = set()
        _, db = M.apply(c.units[p], db, c.steps)
        touched = expand(M.touched, R, M, rdb, D)
        M.touched = None
        for dk in touched:
            if keep(dk):
                if R.get(dk) != M.norm(dk):
                    D.add(dk)
                else:
                    D.discard(dk)
        if not D and ok(p + 1):
            found.append(p + 1)
        if len(D) < best[0]:
            best = (len(D), p + 1, differ(R, M, D))
    return found, best


def check(R, M, clients, alone, jstart, rnd):
    """Whether the restored databases R are those after a prefix (the
    header's property), M the model after the acknowledged units; the
    failure's lines if not."""
    rdb = {}
    for db, k in R:
        rdb.setdefault(db, set()).add((db, k))
    diffs = {dk for dk in set(R) | M.keys() if R.get(dk) != M.norm(dk)}
    if alone:
        c = clients[0]
        c.steps = []
        found, best = step_through(R, M, c, diffs, lambda dk: True, rdb)
        if found:
            c.kept = found[0]
            return []
        return ["no prefix of the units gives the restored databases: %d acknowledged, %d sent;"
                " closest after %d units, %d keys differ:" % (c.acked, c.sent, best[1], best[0])] + \
            best[2]
    diffs -= {(d, JOURNAL) for d in range(WORK)}
    slots = {c.slot for c in clients}
    stray = {dk for dk in diffs if owner(dk[1]) not in slots}
    if stray:
        return ["keys that no connection of the round wrote differ:"] + differ(R, M, stray)
    full = {}
    for d in range(WORK):
        got = R.get((d, JOURNAL))
        if got is not None and got[0] != "list":
            return ["journal %d is a %s now" % (d, got[0])]
        full[d] = list(got[1]) if got else []
        if full[d][:len(jstart[d])] != jstart[d]:
            return ["journal %d lost entries of the rounds before: %d then, %d now" % (d, len(jstart[d]), len(full[d]))]
    mine = {s: {d: [] for d in range(WORK)} for s in slots}
    for d in range(WORK):
        for x in full[d][len(jstart[d]):]:
            r, s = id_of(x)
            if r != rnd or s not in slots:
                return ["journal %d holds %r, which no unit of the round pushed" % (d, x)]
            mine[s][d].append(x)
    out = []
    for i, c in enumerate(clients):
        c.steps = list(c.acked_steps)

        def ok(p, c=c):
            return all([x for dd, x, _ in c.steps if dd == d] == mine[c.slot][d] for d in range(WORK))
        D = {dk for dk in diffs if owner(dk[1]) == c.slot}
        found, best = step_through(R, M, c, D, lambda dk, s=c.slot: owner(dk[1]) == s, rdb, ok)
        if found:
            c.kept = found[0]
            continue
        out += ["connection %d (slot %d): no prefix of its units gives its keys and its ids in the journals:"
                " %d acknowledged, %d sent; its keys closest after %d units, %d differ:"
                % (i, c.slot, c.acked, c.sent, best[1], best[0])] + best[2]
        out += ["  its ids restored in journal %d: %d" % (d, len(mine[c.slot][d])) for d in range(WORK)]
    for i, c in enumerate(clients):
        for d, x, at in c.pushed:
            if not (len(jstart[d]) < at <= len(full[d]) and full[d][at - 1] == x):
                out.append("connection %d: its acknowledged push of %r is not at %d in journal %d, where RPUSH put it"
                           % (i, x, at, d))
    return out


# The rounds
# ----------

class Plan:
    """What a round does, drawn from the seed and the round's number."""

    def __init__(self, seed, rnd, policy=None):
        r = random.Random("%d:plan:%d" % (seed, rnd))
        self.alone = r.random() < 0.25
        self.conns = 1 if self.alone else r.choice([2, 4, 8, 16])
        self.depth = r.choice([1, 2, 8, 32, 128])
        self.policy = r.choice(["always", "always", "everysec", "everysec", "no"])
        self.policy = policy or self.policy
        self.send = r.random() < 0.5
        x = r.random()
        self.rewrite = "bgrewriteaof" if x < 0.35 else "auto" if x < 0.5 else None
        self.pct = r.randint(5, 50)
        self.u_rw = r.random()
        self.u_at = r.random()
        self.startup_kill = r.random() < 0.3
        self.u_start = r.random()
        self.big = r.random() < 0.15

    def describe(self):
        return "%s, %s, %d connection%s at depth %d%s" % (
            self.policy, "its loop" if self.send else "writer thread", self.conns,
            "" if self.conns == 1 else "s", self.depth, ", large values" if self.big else "")


class Stats:
    def __init__(self):
        self.rw_est = 1.0       # a rewrite's seconds under load, as last seen
        self.load_est = 0.2     # a start's seconds to its first PONG, as last seen
        self.kills_rw = 0
        self.rewrites = 0
        self.startup = {}
        self.cuts = 0
        self.acked = 0
        self.beyond = 0
        self.maint = 0


class Failed(Exception):
    pass


def fail_dir(a, seed, rnd):
    return os.path.join(a.dir, "fail-%d-r%d" % (seed, rnd))


def keep_failure(a, seed, rnd, lines, clients, saved):
    d = fail_dir(a, seed, rnd)
    os.makedirs(d, exist_ok=True)
    if saved.get("restored") is not None:
        # what the check ran on, to run it again: --recheck
        with open(os.path.join(d, "round.pickle"), "wb") as f:
            pickle.dump(saved, f)
    for f in [os.path.join(a.dir, "killed.aof"), os.path.join(a.run, AOF)] + \
            [os.path.join(a.logs, x) for x in os.listdir(a.logs) if x.startswith("r%d-" % rnd) or x.startswith("r%d-" % (rnd - 1))]:
        if os.path.exists(f):
            shutil.copy(f, os.path.join(d, os.path.basename(f) if not f.endswith(AOF) else "now.aof"))
    with open(os.path.join(d, "units.txt"), "w") as f:
        f.write("\n".join(lines) + "\n\n")
        for i, c in enumerate(clients or []):
            f.write("connection %d, slot %d: %d units made, %d sent, %d acknowledged\n"
                    % (i, c.slot, len(c.units), c.sent, c.acked))
            for j in range(max(0, c.acked - 100), min(len(c.units), c.sent + 1)):
                u = c.units[j]
                mark = "acked" if j < c.acked else "sent" if j < c.sent else "unsent"
                f.write("  %d %s %s %s\n" % (j, mark, u.kind, show([[x[:60] for x in cmd] for cmd in u.cmds], 2000)))
                if u.got is not None:
                    f.write("      replies %s\n" % show(u.got, 2000))
    return d


def settle(M, clients, alone):
    """The acknowledged units run on the model, connection by connection
    (each on keys of its own when there are several: their order across
    connections does not matter), each reply compared with the model's."""
    M.shared = not alone
    for i, c in enumerate(clients):
        db = 0
        c.acked_steps = []
        for j in range(c.acked):
            u = c.units[j]
            steps = []
            want, db = M.apply(u, db, steps)
            if len(want) != len(u.got) or not all(same(w, g) for w, g in zip(want, u.got)):
                raise Failed(["connection %d, unit %d: the replies are not the model's:" % (i, j),
                              "  unit:    %s %s" % (u.kind, show(u.cmds, 600)),
                              "  replies: %s" % show(u.got, 600),
                              "  model:   %s" % show(want, 600)])
            for d, x, at in steps:
                c.acked_steps.append((d, x, at))
                if not alone:
                    r = u.got[at] if u.kind == "cmd" else u.got[-1][1][at]
                    if r[0] != ":":
                        raise Failed(["connection %d, unit %d: RPUSH onto journal %d answered %s"
                                      % (i, j, d, show(r))])
                    c.pushed.append((d, x, r[1]))
        c.db = db


def run_load(a, srv, plan, seed, rnd, st):
    """The round's load, then the kill: the clients, with their units."""
    clients = [Client(a.port, s, Gen(seed, rnd, s, plan.alone, plan.big), plan.depth) for s in range(plan.conns)]
    admin = Conn(a.port, timeout=60)
    if plan.rewrite == "auto":
        admin.call([[b"CONFIG", b"SET", b"auto-aof-rewrite-percentage", b"%d" % plan.pct],
                    [b"CONFIG", b"SET", b"auto-aof-rewrite-min-size", b"1048576"]])
    t_rw = None
    if plan.rewrite == "bgrewriteaof":
        t_rw = 0.02 + 0.3 * plan.u_rw
        kill_at = t_rw + plan.u_at * 1.5 * min(st.rw_est, 3.0)
    else:
        kill_at = 0.05 + plan.u_at * a.secs
    sel = selectors.DefaultSelector()
    for c in clients:
        sel.register(c.sock, selectors.EVENT_READ, c)
    t0 = time.monotonic()
    rw_at = None
    rw_running = False      # a rewrite ran at the last look, at most 25 ms before the kill
    rewrites = 0
    rw_done = None
    next_look = t0
    looks = plan.rewrite is not None
    while True:
        now = time.monotonic()
        if not srv.alive():
            raise Failed(["the server stopped by itself during the load:"] + srv.text().splitlines()[-6:])
        if t_rw is not None and rw_at is None and now - t0 >= t_rw:
            try:
                admin.call([[b"BGREWRITEAOF"]])
            except (OSError, EOFError):
                looks = False
            rw_at = time.monotonic()
        if looks and now >= next_look:
            try:
                i = info(admin)
                rw_running = i["aof_rewrite_in_progress"] == "1"
                rewrites = int(i["aof_rewrites"])
                if rw_at is not None and rw_done is None and not rw_running and i["aof_rewrite_scheduled"] == "0":
                    rw_done = time.monotonic() - rw_at
            except (OSError, EOFError, KeyError):
                looks = False
            next_look = time.monotonic() + 0.025
        # each connection sends what its depth allows, and only then may
        # the kill come: with units in flight
        for c in clients:
            c.fill()
            if c.out:
                c.flush()
        if time.monotonic() - t0 >= kill_at:
            break
        for key, ev in sel.select(min(0.002, max(0.0, kill_at - (time.monotonic() - t0)))):
            key.data.read()
    if not srv.alive():
        raise Failed(["the server stopped by itself during the load:"] + srv.text().splitlines()[-6:])
    srv.kill()
    for c in clients:
        c.drain()
    admin.close()
    if rw_done is not None:
        st.rw_est = 0.5 * st.rw_est + 0.5 * max(0.05, rw_done)
    return clients, kill_at, rw_running, rewrites


def maintain(a, port, st):
    """The file rewritten, and not killed, once it passes --max-file."""
    if os.path.getsize(os.path.join(a.run, AOF)) <= a.max_file:
        return
    c = Conn(port)
    try:
        c.call([[b"CONFIG", b"SET", b"auto-aof-rewrite-percentage", b"0"], [b"BGREWRITEAOF"]])
        end = time.monotonic() + 300
        while time.monotonic() < end:
            i = info(c)
            if i["aof_rewrite_in_progress"] == "0" and i["aof_rewrite_scheduled"] == "0":
                if i["aof_last_bgrewrite_status"] != "ok":
                    raise Failed(["a rewrite between rounds failed: %r" % i])
                st.maint += 1
                return
            time.sleep(0.02)
        raise Failed(["a rewrite between rounds did not end in 300 s"])
    finally:
        c.close()


def restart(a, rnd, plan, nxt, st):
    """The server started again after the kill (and, as the plan says,
    killed once while it loads first): the server, what the start did."""
    path = os.path.join(a.run, AOF)
    with open(os.path.join(a.dir, "killed.aof"), "rb") as f:
        before = f.read()
    notes = []
    if plan.startup_kill:
        s = Server(a, nxt.policy, nxt.send, os.path.join(a.logs, "r%d-startkill.log" % rnd))
        d = plan.u_start * 1.3 * st.load_est
        time.sleep(d)
        s.kill()
        power_loss(a)
        where = stage(s.text())
        st.startup[where] = st.startup.get(where, 0) + 1
        notes.append("start killed after %.3f s (%s)" % (d, where))
        with open(path, "rb") as f:
            mid = f.read()
        if not before.startswith(mid):
            raise Failed(["a start killed %s changed the file other than by cutting its end" % where])
    else:
        mid = before
    s = Server(a, nxt.policy, nxt.send, os.path.join(a.logs, "r%d-start.log" % rnd))
    t = s.ready(a.port)
    with open(path, "rb") as f:
        now = f.read()
    bad = None
    if t is None:
        bad = ["the server did not start again:"] + s.text().splitlines()[-6:]
    elif not mid.startswith(now):
        bad = ["the start changed the file other than by cutting its end"]
    elif len(mid) - len(now) != cut_logged(s.text()):
        bad = ["the start cut %d bytes from the file, its log says %d" % (len(mid) - len(now), cut_logged(s.text()))]
    if bad:
        s.kill()
        raise Failed(bad)
    st.load_est = 0.5 * st.load_est + 0.5 * t
    if len(before) > len(now):
        st.cuts += 1
        what = "a transaction" if "Revert incomplete MULTI/EXEC" in s.text() else "an entry"
        notes.append("%d bytes cut (%s)" % (len(before) - len(now), what))
    for x in os.listdir(a.run):
        if x.startswith("temp-rewriteaof-bg-"):
            os.unlink(os.path.join(a.run, x))
    notes.append("started in %.2f s" % t)
    return s, notes


def power_loss(a):
    """With --lazyfs: LazyFS drops every write not synced, as a machine
    that stops loses its page cache; it says so on its second FIFO."""
    if not a.lazyfs:
        return
    done = os.open(a.lazyfs_done, os.O_RDWR)
    try:
        try:
            w = os.open(a.lazyfs, os.O_WRONLY | os.O_NONBLOCK)
        except OSError as e:
            raise Failed(["LazyFS does not read its FIFO %s: %s" % (a.lazyfs, e)])
        os.write(w, b"lazyfs::clear-cache\n")
        os.close(w)
        if not select.select([done], [], [], 120)[0]:
            raise Failed(["LazyFS did not clear its cache in 120 s"])
        said = os.read(done, 4096)
        if not said.startswith(b"finished::clear-cache"):
            raise Failed(["LazyFS answered %r to clear-cache" % said])
    finally:
        os.close(done)


def damage(path, how, r):
    """The file as a durability bug would leave it, so that a run shows the
    check fails then (--break): lose drops its last whole entry, as if the
    server had answered before writing it; hole drops one of the 20 whole
    entries before that, keeping those after it."""
    with open(path, "rb") as f:
        data = f.read()
    p = Parser()
    p.feed(data)
    ends = [0]
    while True:
        try:
            if p.get() is None:
                break
        except ValueError:
            break
        ends.append(p.pos)
    if len(ends) < 3:
        return
    i = len(ends) - 2 if how == "lose" else max(1, len(ends) - 2 - r.randint(1, 20))
    with open(path, "wb") as f:
        f.write(data[:ends[i]] + data[ends[i + 1]:ends[-1]])


class Sim:
    """A connection of a simulated round (self_check): its units, how many
    were sent, and how many acknowledged."""

    def __init__(self, slot, units, sent, acked):
        self.slot, self.units, self.sent, self.acked = slot, units, sent, acked
        self.pushed = []


def dump_of(M):
    return {dk: M.norm(dk) for dk in M.keys()}


def simulated(seed, alone, damage):
    """A round of self_check: check's lines (none: accepted); None when the
    damage asked for cannot be made, or leaves databases a prefix may
    leave all the same."""
    r = random.Random("%d:self:%s:%s" % (seed, alone, damage))
    T = Model()
    db = 0
    g = Gen(seed, 1, 0, True)
    for _ in range(r.randint(0, 300)):
        _, db = T.apply(g.unit(), db, [])
    start = dump_of(T)
    n = 1 if alone else r.randint(2, 4)
    units = [[x.unit() for _ in range(r.randint(5, 120))] for x in (Gen(seed, 2, s, alone, whole=True) for s in range(n))]
    # the server: every connection's units in one order that keeps each one's
    order = []
    nxt = [0] * n
    while len(order) < sum(map(len, units)):
        s = r.choice([s for s in range(n) if nxt[s] < len(units[s])])
        order.append((s, nxt[s]))
        nxt[s] += 1
    S = Model.of(start)
    dbs = [0] * n
    replies = {}
    for s, i in order:
        replies[(s, i)], dbs[s] = S.apply(units[s][i], dbs[s], [])
    j = r.randint(0, len(order))
    inpre = [0] * n
    for s, i in order[:j]:
        inpre[s] = i + 1
    sims = [Sim(s, units[s], r.randint(inpre[s], len(units[s])), r.randint(0, inpre[s])) for s in range(n)]
    for s, x in enumerate(sims):
        for i, u in enumerate(units[s]):
            u.got = replies[(s, i)] if i < x.acked else None

    def after(skip):
        P = Model.of(start)
        dbs = [0] * n
        for s, i in order[:j]:
            if (s, i) != skip:
                _, dbs[s] = P.apply(units[s][i], dbs[s], [])
        return dump_of(P)
    R = after(None)
    if damage:
        lost = [(s, i) for s, i in order[:j] if i < sims[s].acked]
        if not lost:
            return None
        s, k = r.choice(lost)
        R = after((s, k))
        # the connection's keys after none of the counts of its own units
        # it may have reached (a plain replay, not check's), or it is no
        # damage the check must refuse
        mine = (lambda d: d) if alone else (lambda d: {dk: v for dk, v in d.items() if owner(dk[1]) == s})
        P = Model.of(start)
        db = 0
        for p in range(sims[s].sent + 1):
            if p >= sims[s].acked and mine(dump_of(P)) == mine(R):
                return None
            if p < sims[s].sent:
                _, db = P.apply(units[s][p], db, [])
    M = Model.of(start)
    jstart = {d: list(start[(d, JOURNAL)][1]) if (d, JOURNAL) in start else [] for d in range(WORK)}
    try:
        settle(M, sims, alone)
    except Failed as e:
        return e.args[0]
    return check(R, M, sims, alone, jstart, 2)


def recheck(d):
    """The check again on what a failed round kept (round.pickle in d)."""
    with open(os.path.join(d, "round.pickle"), "rb") as f:
        s = pickle.load(f)
    sims = [Sim(slot, units, sent, acked) for slot, units, sent, acked in s["conns"]]
    M = Model.of(s["start"])
    settle(M, sims, s["alone"])
    return check(s["restored"], M, sims, s["alone"], s["jstart"], s["rnd"])


def self_check(n):
    """The check itself, before any server: n simulated rounds with one
    connection and n with several. A model plays the server (every
    connection's units in one order that keeps each one's, with the replies
    it gives, the journals' lengths among them), the order is cut after a
    random number of units, and each connection's units are acknowledged up
    to a random count below the cut and sent up to one past it. check must
    accept the databases after the cut, and refuse them without the effect
    of one acknowledged unit, as a lost write leaves them. With one
    connection, SWAPDB and FLUSHDB come often: they change a database
    whole. The counts of rounds accepted and refused."""
    accepted = refused = 0
    for seed in range(n):
        for alone in (True, False):
            how = "one connection" if alone else "several"
            out = simulated(seed, alone, False)
            if out:
                raise Failed(["the check refuses a simulated round it must accept (seed %d, %s):" % (seed, how)] + out[:8])
            accepted += 1
            out = simulated(seed, alone, True)
            if out == []:
                raise Failed(["the check accepts a simulated round without an acknowledged unit (seed %d, %s)" % (seed, how)])
            refused += out is not None
    return accepted, refused


def ballast(n, seed):
    r = random.Random("%d:ballast" % seed)
    cmds = []
    for i in range(n):
        k = b"b:%d" % i
        x = r.random()
        if x < 0.8:
            cmds.append([b"SET", k, b"%d:" % i + b"v" * r.randrange(40)])
        elif x < 0.85:
            cmds.append([b"RPUSH", k] + [b"e%d" % j for j in range(r.randint(1, 80))])
        elif x < 0.9:
            cmds.append([b"HSET", k] + [y for j in range(r.randint(1, 80)) for y in (b"f%d" % j, b"%d" % j)])
        elif x < 0.95:
            cmds.append([b"SADD", k] + [b"%d" % j for j in range(r.randint(1, 80))])
        else:
            cmds.append([b"ZADD", k] + [y for j in range(r.randint(1, 80)) for y in (b"%d" % (j % 7), b"m%d" % j)])
        if r.random() < 0.1:
            cmds.append([b"PEXPIREAT", k, b"%d" % (FAR + i)])
    return cmds


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default="build/bendkv")
    ap.add_argument("--port", type=int, default=6380)
    ap.add_argument("--dir", default="build/crash")
    ap.add_argument("--rounds", type=int, default=20)
    ap.add_argument("--seed", type=int)
    ap.add_argument("--secs", type=float, default=1.5, help="the longest load before a kill, in seconds")
    ap.add_argument("--ballast", type=int, default=20000)
    ap.add_argument("--max-file", type=int, default=24 << 20)
    ap.add_argument("--break", dest="damage", choices=["lose", "hole"],
                    help="damage the file after each kill as a durability bug would: the test must fail")
    ap.add_argument("--run", help="the server's directory (by default DIR/run): on LazyFS's mount with --lazyfs")
    ap.add_argument("--lazyfs", help="LazyFS's faults FIFO: every round with always, and what was not synced"
                    " dropped after each kill")
    ap.add_argument("--lazyfs-done", help="LazyFS's FIFO of the faults done (its fifo_path_completed)")
    ap.add_argument("--policy", choices=["always", "everysec", "no"],
                    help="every round with this appendfsync (with --lazyfs, always unless given)")
    ap.add_argument("--self-check", type=int, default=100,
                    help="simulated rounds of each kind the check is tried on first, without a server")
    ap.add_argument("--recheck", metavar="FAILDIR", help="run the check again on what a failed round kept")
    a = ap.parse_args()
    if a.recheck:
        bad = recheck(a.recheck)
        print("\n".join(["FAIL: " + bad[0]] + bad[1:]) if bad else "OK: the check accepts the round")
        sys.exit(1 if bad else 0)
    if bool(a.lazyfs) != bool(a.lazyfs_done) or (a.lazyfs and not a.run):
        ap.error("--lazyfs needs --lazyfs-done and --run")
    explicit = a.policy
    if a.lazyfs and not a.policy:
        a.policy = "always"
    seed = a.seed if a.seed is not None else random.SystemRandom().randrange(10**9)
    again = "python3 tests/crash_test.py --bin %s --port %d --dir %s --seed %d" % (a.bin, a.port, a.dir, seed)
    if a.secs != 1.5:
        again += " --secs %g" % a.secs
    if a.ballast != 20000:
        again += " --ballast %d" % a.ballast
    if a.max_file != 24 << 20:
        again += " --max-file %d" % a.max_file
    if a.run or a.lazyfs:
        again += " --run %s" % a.run
    if a.lazyfs:
        again += " --lazyfs %s --lazyfs-done %s" % (a.lazyfs, a.lazyfs_done)
    if explicit:
        again += " --policy %s" % explicit
    print("== crash test: seed %d, %d rounds%s%s" % (
        seed, a.rounds, ", every one with %s" % a.policy if a.policy else "",
        ", on LazyFS: what was not synced dropped after each kill" if a.lazyfs else ""))
    if a.self_check:
        try:
            accepted, refused = self_check(a.self_check)
        except Failed as e:
            print("\n".join(["FAIL: " + e.args[0][0]] + e.args[0][1:]))
            sys.exit(1)
        print("the check itself: %d simulated rounds accepted, %d without an acknowledged unit refused"
              % (accepted, refused))
    a.run = a.run or os.path.join(a.dir, "run")
    a.logs = os.path.join(a.dir, "logs")
    shutil.rmtree(a.run, ignore_errors=True)
    shutil.rmtree(a.logs, ignore_errors=True)
    os.makedirs(a.run)
    os.makedirs(a.logs)
    st = Stats()
    t_start = time.monotonic()
    plan = Plan(seed, 1, a.policy)
    srv = Server(a, plan.policy, plan.send, os.path.join(a.logs, "r0-start.log"))
    rnd = 0
    clients = None
    saved = {}
    try:
        if srv.ready(a.port) is None:
            raise Failed(["BendKV did not start:"] + srv.text().splitlines()[-6:])
        M = Model()
        c = Conn(a.port)
        db = 0
        cmds = [[b"SELECT", b"%d" % BALLAST_DB]] + ballast(a.ballast, seed)
        for i in range(0, len(cmds), 1000):
            for cmd, got in zip(cmds[i:i + 1000], c.call(cmds[i:i + 1000])):
                want, db = M.run(db, cmd)
                if not same(want, got):
                    raise Failed(["the ballast's %r answered %s, the model %s" % (cmd[:2], show(got), show(want))])
        c.close()
        R = dump(a.port)
        if R != {dk: M.norm(dk) for dk in M.keys()}:
            raise Failed(["the ballast does not read back as the model holds it"])
        print("ballast: %d keys in database %d" % (len(R), BALLAST_DB))
        for rnd in range(1, a.rounds + 1):
            clients = None
            t_round = time.monotonic()
            killed = os.path.join(a.dir, "killed.aof")
            if os.path.exists(killed):
                os.unlink(killed)
            maintain(a, a.port, st)
            nxt = Plan(seed, rnd + 1, a.policy)
            jstart = {d: list(R[(d, JOURNAL)][1]) if (d, JOURNAL) in R else [] for d in range(WORK)}
            clients, kill_at, rw_running, rewrites = run_load(a, srv, plan, seed, rnd, st)
            power_loss(a)
            if a.damage:
                damage(os.path.join(a.run, AOF), a.damage, random.Random("%d:break:%d" % (seed, rnd)))
            shutil.copyfile(os.path.join(a.run, AOF), killed)
            st.rewrites += rewrites
            st.kills_rw += rw_running
            saved = {"start": R, "jstart": jstart, "alone": plan.alone, "rnd": rnd,
                     "conns": [(c.slot, c.units, c.sent, c.acked) for c in clients]}
            M = Model.of(R)
            settle(M, clients, plan.alone)
            srv, notes = restart(a, rnd, plan, nxt, st)
            R = saved["restored"] = dump(a.port)
            bad = check(R, M, clients, plan.alone, jstart, rnd)
            if bad:
                raise Failed(bad)
            acked = sum(c.acked for c in clients)
            sent = sum(c.sent for c in clients)
            beyond = sum(c.kept - c.acked for c in clients)
            st.acked += acked
            st.beyond += beyond
            rw = {"bgrewriteaof": "BGREWRITEAOF", "auto": "rewrites at %d%% growth" % plan.pct, None: "no rewrite"}[plan.rewrite]
            if plan.rewrite:
                rw += ", %s at the kill" % ("one running" if rw_running else "none running")
            print("round %d: %s; %s; killed after %.3f s: %d units acknowledged, %d of the %d sent after them"
                  " restored; %s; %d keys: OK (%.1f s)"
                  % (rnd, plan.describe(), rw, kill_at, acked, beyond, sent - acked, "; ".join(notes), len(R),
                     time.monotonic() - t_round))
            sys.stdout.flush()
            for x in os.listdir(a.logs):
                if x.startswith("r%d-" % (rnd - 1)):
                    os.unlink(os.path.join(a.logs, x))
            plan = nxt
    except Exception as e:
        # a failure of the check, or anything unforeseen (a reply that
        # does not parse, more replies than requests): both keep the files
        why = e.args[0] if isinstance(e, Failed) else \
            ["%s: %s" % (type(e).__name__, e)] + traceback.format_exc().rstrip().splitlines()
        lines = ["FAIL: round %d (%s, %s): %s" % (rnd, plan.describe(), plan.rewrite or "no rewrite", why[0])] + why[1:]
        print("\n".join(lines))
        if srv.alive():
            srv.kill()
        d = keep_failure(a, seed, rnd, lines, clients, saved)
        print("kept in %s: the file as the kill left it (killed.aof), the file now (now.aof), the logs, the units" % d)
        if os.path.exists(os.path.join(d, "round.pickle")):
            print("the check again on what the round kept: python3 tests/crash_test.py --recheck %s" % d)
        if rnd:
            print("the same rounds again (the same commands and draws; where a kill lands depends on the machine):")
            print("  %s --rounds %d" % (again, rnd))
        sys.exit(1)
    finally:
        for s in Server.ALL:
            if s.alive():
                s.kill()
    print("OK: %d rounds in %.0f s (seed %d): %d units acknowledged, all restored, and %d more of those sent after them;"
          " %d kills while a rewrite ran (%d rewrites under load), %d starts killed (%s), %d files cut back on start,"
          " %d rewrites between rounds"
          % (a.rounds, time.monotonic() - t_start, seed, st.acked, st.beyond, st.kills_rw, st.rewrites,
             sum(st.startup.values()), ", ".join("%d %s" % (n, w) for w, n in sorted(st.startup.items())) or "none",
             st.cuts, st.maint))
    shutil.rmtree(a.run, ignore_errors=True)
    shutil.rmtree(a.logs, ignore_errors=True)
    if os.path.exists(os.path.join(a.dir, "killed.aof")):
        os.unlink(os.path.join(a.dir, "killed.aof"))


if __name__ == "__main__":
    main()
