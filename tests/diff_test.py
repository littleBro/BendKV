#!/usr/bin/env python3
"""Differential test: random command streams against BendKV and a real
Redis, replies compared one by one. Commands are pipelined in random
batch sizes, and arguments are random bytes, so framing, binary safety
and command semantics are all exercised.

    python3 tests/diff_test.py --bendkv 6380 --redis 6390 --rounds 2000

The stream moves between databases 0 to 3 (SELECT), moves keys between
them (MOVE), swaps them (SWAPDB) and empties one (FLUSHDB) or all
(FLUSHALL), with bad numbers among them. Ranges and bits (GETRANGE,
SETRANGE, GETBIT, SETBIT, BITCOUNT, BITPOS) take small offsets, and now
and then wrong or huge ones, but never one that would make a value near
512MB. TOUCH counts keys as EXISTS does; OBJECT's subcommands come
with errors and FREQ, refused under the default policy (an encoding or a
count of references BendKV derives from the value, where Redis keeps how
the value was made, and the idle time reads a clock), and TIME with
arguments. MSETNX, RENAME and RENAMENX move and set keys of the same
few names, so they often find one there; COPY copies within the
database and to the others, with REPLACE or not, and bad numbers and
options among them. BITOP combines keys of those names (one of them its
own destination now and then), with names of operations in any case and
wrong ones; LCS compares two of them with its options in any order, and
wrong ones (its table stays far below proto-max-bulk-len: values are
short). BITFIELD and BITFIELD_RO read and write fields of random types
at small bit offsets (or #k), with values at the edges of the fields and
of a long long, under each kind of overflow, and wrong types, offsets,
values and words among them; a read may go far, a write never does.

Known, documented divergences that the generator avoids: BendKV's
integers have at most 14 digits (Redis allows int64), and so have its
times: a time at or past 10^14 ms (the year 5138) gives a key no time at
all, as it would never come, where Redis keeps any int64 time. Times are
relative ones of 100 s and more, or absolute
ones far in the past or the future, so no key expires while the test
runs; TTL, PTTL, EXPIRETIME and PEXPIRETIME, which read the clock of each
server, are compared within a second.
"""
import argparse
import random
import socket
import sys
import time


class Conn:
    def __init__(self, port):
        self.sock = socket.create_connection(("127.0.0.1", port))
        self.buf = b""

    def send(self, cmds):
        out = b""
        for args in cmds:
            out += b"*%d\r\n" % len(args)
            for a in args:
                out += b"$%d\r\n%s\r\n" % (len(a), a)
        self.sock.sendall(out)

    def _fill(self):
        data = self.sock.recv(1 << 16)
        if not data:
            raise EOFError("connection closed")
        self.buf += data

    def _line(self):
        while b"\r\n" not in self.buf:
            self._fill()
        line, self.buf = self.buf.split(b"\r\n", 1)
        return line

    def _exact(self, n):
        while len(self.buf) < n + 2:
            self._fill()
        data, self.buf = self.buf[:n], self.buf[n + 2:]
        return data

    def reply(self):
        line = self._line()
        kind, rest = line[:1], line[1:]
        if kind in (b"+", b"-", b":"):
            return (kind, rest)
        if kind == b"$":
            n = int(rest)
            return (kind, None if n < 0 else self._exact(n))
        if kind == b"*":
            n = int(rest)
            return (kind, None if n < 0 else [self.reply() for _ in range(n)])
        raise ValueError("bad reply line %r" % line)


KEYS = [b"k%d" % i for i in range(8)] + [b"", b"user:1", b"user:2", "ключ".encode(), b"\x00\xff\r\n"]


def rnd_value(r):
    c = r.random()
    if c < 0.35:
        return str(r.randint(-10**6, 10**6)).encode()
    if c < 0.45:
        return r.choice([b"0", b"-0", b"007", b"+5", b" 1", b"1 ", b"", b"99999999999998", b"-99999999999998"])
    if c < 0.7:
        return bytes(r.randrange(256) for _ in range(r.randint(0, 12)))
    return r.choice([b"a", b"bar", b"hello world", "мир".encode(), b"x" * r.randint(0, 300)])


NOW_S = int(time.time())


LLONG_MAX = 2**63 - 1
EMAX = 10**14 - 1


def string2ll(v):
    # Redis's string2ll: an optional '-', then digits with no leading zero
    t = v[1:] if v[:1] == b"-" else v
    if not t.isdigit() or (t[:1] == b"0" and len(t) > 1) or (v[:1] == b"-" and t == b"0"):
        return None
    n = int(v)
    return n if -2**63 <= n <= LLONG_MAX else None


# the time Redis keys a value of SET or GETEX (set) or of EXPIRE (not set)
# to, in ms from 1970, or None for an error
def redis_when(v, ms, absolute, set):
    n = string2ll(v)
    if n is None:
        return None
    base = 0 if absolute else NOW_S * 1000
    if set:
        if n <= 0 or (not ms and n > LLONG_MAX // 1000):
            return None
        n = n if ms else n * 1000
        return n + base if n + base <= LLONG_MAX else None
    if not ms:
        if n > LLONG_MAX // 1000 or n < -(2**63 // 1000):
            return None
        n *= 1000
    return n + base if n <= LLONG_MAX - base else None


# a time of an option or a command: relative (s or ms), or absolute (from
# 1970, in s or ms), or a bad one: 0 or less, not a number, or past int64
# once in ms. Not one Redis takes past 10^14 - 1 ms, where BendKV keeps its
# times; and for SET (not past), not one in the past, which leaves an
# expired key that Redis deletes when it comes to it (GETEX and EXPIRE
# delete the key then)
def rnd_time(r, ms, absolute, set=False, past=True):
    while True:
        v = rnd_time1(r, ms, absolute)
        w = redis_when(v, ms, absolute, set)
        if w is None or (w <= EMAX and (past or w > NOW_S * 1000 + 10**8)):
            return v


def rnd_time1(r, ms, absolute):
    c = r.random()
    if c < 0.12:
        return r.choice([b"0", b"-1", b"-100", b"x", b"1.5", b"", b" 5", b"+5", b"007", b"-0",
                         b"9223372036854775807", b"9223370399119966", b"-9223372036854776",
                         b"10000000000000000", b"18446744073709561", b"9223372036854770000",
                         b"-9223372036854770000", b"-9223372036854775808"])
    if absolute:
        if c < 0.3:
            return str(r.randint(1, 10**6)).encode()
        t = NOW_S + r.randint(10**5, 10**8)
        return str(t * 1000 + r.randint(0, 999) if ms else t).encode()
    t = r.randint(100, 10**6)
    return str(t * 1000 + r.randint(0, 999) if ms else t).encode()


# SET's options: a condition, GET, and a time or KEEPTTL; now and then in
# another case, twice, clashing, or another word
def rnd_set_opts(r):
    os = []
    if r.random() < 0.3:
        os.append(r.choice([b"NX", b"XX", b"nx", b"xx"]))
    if r.random() < 0.2:
        os.append(r.choice([b"GET", b"get"]))
    c = r.random()
    if c < 0.5:
        w = r.choice([b"EX", b"PX", b"EXAT", b"PXAT", b"ex", b"pxat"])
        os += [w, rnd_time(r, w.upper() in (b"PX", b"PXAT"), w.upper() in (b"EXAT", b"PXAT"), True, False)]
    elif c < 0.6:
        os.append(r.choice([b"KEEPTTL", b"keepttl"]))
    if r.random() < 0.08:
        os.append(r.choice([b"NX", b"XX", b"KEEPTTL", b"EX", b"PX", b"FOO", b"PERSIST", b"GET"]))
    if r.random() < 0.05:
        r.shuffle(os)
    return os


def rnd_getex_opts(r):
    c = r.random()
    if c < 0.3:
        return []
    if c < 0.45:
        return [r.choice([b"PERSIST", b"persist"])]
    if c < 0.9:
        w = r.choice([b"EX", b"PX", b"EXAT", b"PXAT", b"px"])
        return [w, rnd_time(r, w.upper() in (b"PX", b"PXAT"), w.upper() in (b"EXAT", b"PXAT"), True)]
    return r.choice([[b"EX"], [b"PERSIST", b"EX", b"100"], [b"EX", b"100", b"PX", b"100"],
                     [b"KEEPTTL"], [b"NX"], [b"FOO"], [b"EX", b"100", b"EX", b"200"]])


def rnd_expire(r):
    name = r.choice([b"EXPIRE", b"PEXPIRE", b"EXPIREAT", b"PEXPIREAT"])
    os = [r.choice([b"NX", b"XX", b"GT", b"LT", b"nx", b"gt"]) for _ in range(r.choice([0, 0, 1, 1, 2]))]
    if r.random() < 0.03:
        os.append(r.choice([b"FOO", b"KEEPTTL"]))
    return [name, None, rnd_time(r, name.startswith(b"P"), name.endswith(b"AT"))] + os


# patterns of Redis's glob: stars, '?', classes with ranges, '^' and
# escapes, unclosed classes, escapes; and random ones of those bytes
def rnd_pattern(r):
    if r.random() < 0.5:
        return r.choice([b"*", b"k*", b"k?", b"user:*", b"*1", b"?", b"", b"k[", b"*:*", b"k[0-3]",
                         b"k[^0-3]", b"k[3-0]", b"[ku]*", b"\\k*", b"k\\*", b"user:[12]", b"*[",
                         b"k[\\]]", b"k[a-]", b"**", b"*?*", b"[^k]*", b"k[0-9", b"\\", b"k[^]"])
    return bytes(r.choice(b"k01u:*?[]^-\\\xd0") for _ in range(r.randint(0, 6)))


def rnd_db(r):
    if r.random() < 0.85:
        return str(r.randint(0, 3)).encode()
    return r.choice([b"15", b"16", b"-1", b"x", b"", b" 1", b"01", b"1.0", b"+1", b"2147483647",
                     b"2147483648", b"-2147483649", b"99999999999999999999"])


# a number of a range (GETRANGE, BITCOUNT, BITPOS): mostly small, about
# the values' lengths, below 0 too; now and then a big one or no number
def rnd_index(r):
    if r.random() < 0.85:
        return str(r.randint(-25, 25)).encode()
    return r.choice([b"x", b"", b"1.5", b"+1", b"01", b"-0", b"9223372036854775807", b"-9223372036854775808",
                     b"9223372036854775808", b"99999999999999999999", b"1099511627777", b"-1099511627777",
                     b"4294967296", b"-4294967296"])


# BITCOUNT's and BITPOS's range, with a unit now and then, or too many
# arguments
def rnd_range(r):
    c = r.random()
    if c < 0.25:
        return []
    if c < 0.35:
        return [rnd_index(r)]
    if c < 0.65:
        return [rnd_index(r), rnd_index(r)]
    if c < 0.95:
        return [rnd_index(r), rnd_index(r), r.choice([b"BIT", b"BYTE", b"bit", b"Byte", b"bits", b""])]
    return [rnd_index(r), rnd_index(r), b"BIT", b"x"]


# SETRANGE's offset: small, so that no value grows big (an offset near
# 512MB with a value would make one that size in both servers); now and
# then one past 512MB, below 0, or no number
def rnd_offset(r):
    if r.random() < 0.9:
        return str(r.randint(0, 40)).encode()
    return r.choice([b"-1", b"x", b"", b"536870912", b"100000000000000", b"9223372036854775807",
                     b"99999999999999999999", b"01", b"+3", b"-0"])


# a bit's offset, small for the same reason (a read may go far)
def rnd_bitoff(r, read=False):
    if r.random() < 0.9:
        return str(r.randint(0, 200)).encode()
    return r.choice([b"-1", b"x", b"4294967296", b"", b"01", b"99999999999999999999"] +
                    ([b"4294967295", b"100000"] if read else []))


# BITFIELD's operations: a type, an offset, a value, as rnd_bitoff takes
# them, and now and then a wrong one
BF_TYPES_BAD = [b"u64", b"i65", b"i0", b"x8", b"i", b"", b"I8", b"i08", b"u+3", b"i-1", b"i8\x00x"]
BF_VALS_BAD = [b"x", b"", b"1.5", b"9223372036854775808", b"-0", b"+1", b"-9223372036854775809", b"-", b"01"]


def rnd_bf_type(r):
    if r.random() < 0.97:
        sign = r.random() < 0.5
        return (b"i%d" if sign else b"u%d") % r.randint(1, 64 if sign else 63)
    return r.choice(BF_TYPES_BAD)


def rnd_bf_off(r, read):
    c = r.random()
    if c < 0.75:
        return b"%d" % r.randint(0, 255)
    if c < 0.95:
        return b"#%d" % r.randint(0, 30)
    return r.choice([b"-1", b"x", b"", b"4294967296", b"#", b"#-1", b"01", b"#99999999999999999999"] +
                    ([b"4294967295", b"4294967232", b"#67108863", b"#288230376151711745"] if read else []))


def rnd_bf_val(r):
    c = r.random()
    if c < 0.3:
        return b"%d" % r.randint(-(1 << 63), (1 << 63) - 1)
    if c < 0.6:
        return b"%d" % r.randint(-300, 300)
    if c < 0.97:
        n = r.randint(1, 64)
        return b"%d" % r.choice([0, 1, -1, (1 << 63) - 1, -(1 << 63), (1 << (n - 1)) - 1, -(1 << (n - 1)),
                                 (1 << n) - 1, 1 << n])
    return r.choice(BF_VALS_BAD)


def rnd_bitfield(r, ro):
    ops = []
    for _ in range(r.randint(0, 5)):
        c = r.random()
        if c < (0.9 if ro else 0.35):
            ops += [r.choice([b"GET", b"get", b"Get"]), rnd_bf_type(r), rnd_bf_off(r, True)]
        elif c < (0.93 if ro else 0.6):
            ops += [r.choice([b"SET", b"set"]), rnd_bf_type(r), rnd_bf_off(r, False), rnd_bf_val(r)]
        elif c < (0.95 if ro else 0.85):
            ops += [r.choice([b"INCRBY", b"incrby"]), rnd_bf_type(r), rnd_bf_off(r, False), rnd_bf_val(r)]
        elif c < 0.98:
            ops += [r.choice([b"OVERFLOW", b"overflow"]), r.choice([b"WRAP", b"SAT", b"FAIL", b"sat", b"fail"])]
        else:
            ops += r.choice([[b"FOO"], [b"OVERFLOW", b"x"], [b"GET", b"i8"], [b"SET", b"u8", b"0"], [b"OVERFLOW"]])
    return ops


# a hash's fields: a few names, so that commands meet the ones set, and
# random bytes now and then
HFIELDS = [b"f1", b"f2", b"f3", b"", "поле".encode(), b"\x00\r\n"]


def rnd_field(r):
    return r.choice(HFIELDS) if r.random() < 0.9 else rnd_value(r)


def rnd_hpairs(r):
    return sum(([rnd_field(r), rnd_value(r)] for _ in range(r.randint(1, 3))), [])


def rnd_cmd(r):
    k = lambda: r.choice(KEYS)
    ks = lambda: [k() for _ in range(r.randint(1, 4))]
    c = r.random()
    table = [
        (0.14, lambda: [b"SET", k(), rnd_value(r)]),
        (0.14, lambda: [b"GET", k()]),
        (0.06, lambda: [b"DEL"] + ks()),
        (0.05, lambda: [b"EXISTS"] + ks()),
        (0.07, lambda: [b"INCR", k()]),
        (0.04, lambda: [b"DECR", k()]),
        (0.05, lambda: [b"INCRBY", k(), rnd_value(r)]),
        (0.03, lambda: [b"DECRBY", k(), rnd_value(r)]),
        (0.06, lambda: [b"APPEND", k(), rnd_value(r)]),
        (0.04, lambda: [b"STRLEN", k()]),
        (0.05, lambda: [b"MGET"] + ks()),
        (0.04, lambda: [b"MSET"] + sum(([k(), rnd_value(r)] for _ in range(r.randint(1, 3))), [])),
        (0.04, lambda: [b"SETNX", k(), rnd_value(r)]),
        (0.04, lambda: [b"GETSET", k(), rnd_value(r)]),
        (0.03, lambda: [b"DBSIZE"]),
        (0.03, lambda: [b"KEYS", rnd_pattern(r)]),
        (0.02, lambda: [b"SCAN", b"0", b"COUNT", b"1000"] + ([b"MATCH", rnd_pattern(r)] if r.random() < 0.7 else []) +
                       ([b"TYPE", r.choice([b"string", b"STRING", b"list", b"none"])] if r.random() < 0.3 else [])),
        (0.01, lambda: [b"SCAN"] + r.choice([[], [b"x"], [b"-"], [b" 0"], [b"0", b"COUNT"], [b"0", b"COUNT", b"0"],
                                             [b"0", b"COUNT", b"x"], [b"0", b"MATCH"], [b"0", b"TYPE"],
                                             [b"0", b"FOO", b"bar"], [b"", b"COUNT", b"-1"],
                                             [b"0", b"COUNT", b"1", b"x"], [b"18446744073709551616"]])),
        (0.02, lambda: [b"RANDOMKEY"] + ([rnd_value(r)] if r.random() < 0.2 else [])),
        (0.02, lambda: [b"PING"]),
        (0.02, lambda: [b"ECHO", rnd_value(r)]),
        (0.02, lambda: [r.choice([b"get", b"Get", b"sEt", b"incr"]), k()] + ([rnd_value(r)] if r.random() < 0.5 else [])),
        (0.02, lambda: [r.choice([b"GET", b"SET", b"INCR", b"STRLEN", b"GETSET"])] + [k() for _ in range(r.choice([0, 3]))]),
        (0.01, lambda: [b"FLUSHALL"]),
        (0.03, lambda: [b"SELECT", rnd_db(r)]),
        (0.03, lambda: [b"MOVE", k(), rnd_db(r)]),
        (0.02, lambda: [b"SWAPDB", rnd_db(r), rnd_db(r)]),
        (0.01, lambda: [b"FLUSHDB"] + r.choice([[], [], [b"ASYNC"], [b"sync"], [b"x"]])),
        (0.005, lambda: [b"FLUSHALL"] + r.choice([[b"ASYNC"], [b"SYNC"], [b"y"]])),
        (0.005, lambda: [r.choice([b"SELECT", b"MOVE", b"SWAPDB", b"FLUSHDB"])] + [k() for _ in range(r.choice([0, 3]))]),
        (0.05, lambda: [b"SET", k(), rnd_value(r)] + rnd_set_opts(r)),
        (0.02, lambda: [b"SETEX", k(), rnd_time(r, False, False, True, False), rnd_value(r)]),
        (0.02, lambda: [b"PSETEX", k(), rnd_time(r, True, False, True, False), rnd_value(r)]),
        (0.03, lambda: [b"GETEX", k()] + rnd_getex_opts(r)),
        (0.02, lambda: [b"GETDEL", k()]),
        (0.05, lambda: [x if x is not None else k() for x in rnd_expire(r)]),
        (0.04, lambda: [r.choice([b"TTL", b"PTTL", b"EXPIRETIME", b"PEXPIRETIME"]), k()]),
        (0.02, lambda: [b"PERSIST", k()]),
        (0.01, lambda: [r.choice([b"SETEX", b"PSETEX", b"GETEX", b"GETDEL", b"EXPIRE", b"TTL", b"PERSIST"])] +
                       [k() for _ in range(r.choice([0, 3, 4]))]),
        (0.03, lambda: [r.choice([b"GETRANGE", b"SUBSTR", b"getrange"]), k(), rnd_index(r), rnd_index(r)]),
        (0.03, lambda: [b"SETRANGE", k(), rnd_offset(r), rnd_value(r)]),
        (0.02, lambda: [b"GETBIT", k(), rnd_bitoff(r, True)]),
        (0.03, lambda: [b"SETBIT", k(), rnd_bitoff(r), r.choice([b"0", b"1", b"1", b"0", b"2", b"x", b"-1", b"01"])]),
        (0.03, lambda: [b"BITCOUNT", k()] + rnd_range(r)),
        (0.03, lambda: [b"BITPOS", k(), r.choice([b"0", b"1", b"1", b"0", b"2", b"x", b"-1"])] + rnd_range(r)),
        (0.005, lambda: [r.choice([b"GETRANGE", b"SUBSTR", b"SETRANGE", b"GETBIT", b"SETBIT", b"BITCOUNT", b"BITPOS"])] +
                        [k() for _ in range(r.choice([0, 1, 2]))]),
        (0.02, lambda: [b"TOUCH"] + ks()),
        (0.01, lambda: [b"OBJECT"] + r.choice([[b"FREQ", k()], [b"help"], [b"FOO"], [], [b"ENCODING"],
                                               [b"REFCOUNT", k(), k()], [b"IDLETIME"]])),
        (0.005, lambda: [b"TIME"] + [k() for _ in range(r.choice([1, 2]))]),
        (0.02, lambda: [b"MSETNX"] + sum(([k(), rnd_value(r)] for _ in range(r.randint(1, 3))), [])),
        (0.03, lambda: [r.choice([b"RENAME", b"RENAMENX", b"rename"]), k(), k()]),
        (0.005, lambda: [r.choice([b"MSETNX", b"RENAME", b"RENAMENX"])] + [k() for _ in range(r.choice([0, 1, 3]))]),
        (0.03, lambda: [r.choice([b"COPY", b"copy"]), k(), k()] +
                       r.choice([[], [], [b"REPLACE"], [b"DB", rnd_db(r)], [b"db", rnd_db(r), b"replace"],
                                 [b"REPLACE", b"DB", rnd_db(r)], [b"DB"], [b"FOO"], [b"DB", rnd_db(r), b"DB", rnd_db(r)],
                                 [b"REPLACE", b"REPLACE"]])),
        (0.003, lambda: [b"COPY"] + [k() for _ in range(r.choice([0, 1]))]),
        (0.03, lambda: [b"BITOP", r.choice([b"AND", b"or", b"Xor", b"OR", b"xor", b"and"]), k()] + ks()),
        (0.01, lambda: [b"BITOP", r.choice([b"NOT", b"not"]), k(), k()]),
        (0.005, lambda: [b"BITOP"] + r.choice([[b"NOT", k(), k(), k()], [b"FOO", k(), k()], [b"AND", k()], [b"NOT", k()],
                                               [b"AND"], [], [b"and\x00x", k(), k()]])),
        (0.03, lambda: [b"LCS", k(), k()] + r.sample([b"LEN", b"IDX", b"WITHMATCHLEN", b"withmatchlen", b"idx"], r.randint(0, 2)) +
                       r.choice([[], [], [b"MINMATCHLEN", r.choice([b"0", b"1", b"2", b"3", b"-1", b"x", b"99999999999999999999"])]])),
        (0.005, lambda: [b"LCS"] + r.choice([[], [k()], [k(), k(), b"FOO"], [k(), k(), b"MINMATCHLEN"], [k(), k(), b"LEN", b"IDX"]])),
        (0.04, lambda: [r.choice([b"BITFIELD", b"bitfield"]), k()] + rnd_bitfield(r, False)),
        (0.01, lambda: [r.choice([b"BITFIELD_RO", b"bitfield_ro"]), k()] + rnd_bitfield(r, True)),
        (0.003, lambda: [r.choice([b"BITFIELD", b"BITFIELD_RO"])]),
        (0.05, lambda: [r.choice([b"HSET", b"hset"]), k()] + rnd_hpairs(r)),
        (0.01, lambda: [b"HMSET", k()] + rnd_hpairs(r)),
        (0.02, lambda: [b"HSETNX", k(), rnd_field(r), rnd_value(r)]),
        (0.03, lambda: [b"HGET", k(), rnd_field(r)]),
        (0.02, lambda: [b"HMGET", k()] + [rnd_field(r) for _ in range(r.randint(1, 3))]),
        (0.03, lambda: [b"HDEL", k()] + [rnd_field(r) for _ in range(r.randint(1, 3))]),
        (0.02, lambda: [r.choice([b"HLEN", b"HKEYS", b"HVALS", b"HGETALL", b"TYPE"]), k()]),
        (0.01, lambda: [r.choice([b"HSTRLEN", b"HEXISTS"]), k(), rnd_field(r)]),
        (0.02, lambda: [b"HINCRBY", k(), rnd_field(r), rnd_value(r)]),
        (0.01, lambda: [b"HSCAN", k(), b"0", b"COUNT", b"1000"] + ([b"MATCH", rnd_pattern(r)] if r.random() < 0.5 else [])),
        (0.01, lambda: [b"HRANDFIELD", k()] + r.choice([[], [b"2"], [b"-3"], [b"5", b"WITHVALUES"], [b"x"], [b"0"]])),
        (0.005, lambda: [r.choice([b"HSET", b"HGET", b"HDEL", b"HINCRBY", b"HSCAN", b"HMGET", b"HSETNX"])] +
                        [k() for _ in range(r.choice([0, 1]))]),
    ]
    c *= sum(p for p, f in table)
    acc = 0.0
    for p, f in table:
        acc += p
        if c < acc:
            return f()
    return [b"PING"]


def pairs_of(xs):
    return sorted(zip(xs[0::2], xs[1::2]))


def normalize(cmd, rep):
    # KEYS answers in an unspecified order, and so does SCAN, whose COUNT
    # of 1000 here is past every key: the whole database in one call
    name = cmd[0].upper()
    if name == b"KEYS" and rep[0] == b"*":
        return (rep[0], sorted(rep[1]))
    if name == b"SCAN" and rep[0] == b"*":
        return (rep[0], [rep[1][0], (rep[1][1][0], sorted(rep[1][1][1]))])
    # a hash of long values is a hashtable, in the order of each server's
    # table (tests/hash_test.py checks the order of a listpack's); HSCAN's
    # COUNT of 1000 is past every field
    if name in (b"HKEYS", b"HVALS") and rep[0] == b"*":
        return (rep[0], sorted(rep[1]))
    if name == b"HGETALL" and rep[0] == b"*":
        return (rep[0], pairs_of(rep[1]))
    if name == b"HSCAN" and rep[0] == b"*":
        return (rep[0], [rep[1][0], (rep[1][1][0], pairs_of(rep[1][1][1]))])
    # HRANDFIELD picks at random: how many, or nil or not, is compared
    if name == b"HRANDFIELD" and rep[0] in (b"*", b"$"):
        return (rep[0], len(rep[1]) if rep[0] == b"*" else rep[1] is not None)
    # RANDOMKEY picks a key of its own choice: nil or not is compared
    if cmd[0].upper() == b"RANDOMKEY" and rep[0] == b"$":
        return (rep[0], rep[1] is not None)
    return rep


# replies that read the clock: within a second (or 2 s, as TTL rounds)
CLOCK = {b"TTL": 2, b"EXPIRETIME": 2, b"PTTL": 1000, b"PEXPIRETIME": 1000}


def close(cmd, got, want):
    tol = CLOCK.get(cmd[0].upper())
    if tol is None or got[0] != b":" or want[0] != b":":
        return False
    g, w = int(got[1]), int(want[1])
    return g >= 0 and w >= 0 and abs(g - w) <= tol


def known_divergence(got, want):
    # BendKV refuses integers past 14 digits, where Redis goes on to int64
    if got == (b"-", b"ERR increment or decrement would overflow") and want[0] == b":":
        return len(want[1].lstrip(b"-")) >= 15
    # a stored value of 15+ digits is no integer to BendKV; Redis then
    # answers a 15+ digit sum, or its own int64 overflow
    if got == (b"-", b"ERR value is not an integer or out of range"):
        if want[0] == b":":
            return len(want[1].lstrip(b"-")) >= 15
        return want == (b"-", b"ERR increment or decrement would overflow")
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, default=6380)
    ap.add_argument("--redis", type=int, default=6390)
    ap.add_argument("--rounds", type=int, default=1000)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    r = random.Random(a.seed)
    b, s = Conn(a.bendkv), Conn(a.redis)
    for c in (b, s):
        c.send([[b"FLUSHALL"]])
        c.reply()
    total = 0
    known = 0
    for rnd in range(a.rounds):
        batch = [rnd_cmd(r) for _ in range(r.choice([1, 1, 2, 5, 20]))]
        b.send(batch)
        s.send(batch)
        diverged = False
        for cmd in batch:
            got, want = normalize(cmd, b.reply()), normalize(cmd, s.reply())
            if diverged:
                continue
            total += 1
            if got != want and not close(cmd, got, want):
                if known_divergence(got, want):
                    # the states now differ on one key: compare no more of
                    # this batch, and start the next from empty databases
                    known += 1
                    diverged = True
                    continue
                print("MISMATCH after %d commands (round %d)" % (total, rnd))
                print("  command:", cmd)
                print("  bendkv: ", got)
                print("  redis:  ", want)
                sys.exit(1)
        if diverged:
            for c in (b, s):
                c.send([[b"FLUSHALL"]])
                c.reply()
    print("OK: %d commands in %d pipelined batches, all replies identical"
          " (%d known 64-bit integer divergences skipped)" % (total, a.rounds, known))


if __name__ == "__main__":
    main()
