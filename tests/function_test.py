#!/usr/bin/env python3
"""Functions against Redis: FUNCTION and FCALL, scenarios run on BendKV and
on Redis with clients of their own, each reply logged as the bytes the
server sent, the transcripts compared line by line, scenario by scenario
(as tests/script_test.py compares scripts). Redis walks its dictionaries
of libraries and functions in orders of their own (their hashes are
seeded at random), so a reply that lists more than one library or
function is compared as a set: FUNCTION LIST's libraries and their
functions, FUNCTION STATS's engines. Each scenario starts with FLUSHALL
and FUNCTION FLUSH, and its keys carry a tag new to each run.

The scenarios:

1. FUNCTION LOAD: a library, its name answered; REPLACE (the old one's
   functions gone, a failure leaving it as it was); the metadata's errors
   (none, no name, a name twice, an unknown field, a bad name, an engine
   not there, a name with quotes); a library there already (in another
   case too); a function in another library; no function registered;
   code that does not compile, or fails as it runs; the code missing,
   an unknown option; the library API at load time: register_function
   with positional and named arguments and each of their errors (a name
   that is no string or has a character Redis refuses, a callback that is
   no function, flags that are no table or name an unknown flag, a
   description that is no string, an unknown argument, too many or too
   few), redis.log, redis.call and redis.setresp refused, the globals
   protected, math.random, getmetatable, redis.REDIS_VERSION.
2. FCALL and FCALL_RO: each type a function returns, on a RESP2 and a
   RESP3 connection; KEYS and ARGV; numkeys's errors (not a number,
   negative, more than the arguments); a function not there; names in
   any case; FCALL_RO of a function that writes, of one declared
   no-writes, and a no-writes function's write; a function's runtime
   error; the arities.
3. FUNCTION LIST (LIBRARYNAME and its pattern, WITHCODE, each twice, a
   wrong argument), on RESP2 and RESP3; FUNCTION DELETE; FUNCTION FLUSH
   (SYNC, ASYNC, a bad option); FUNCTION STATS with nothing running;
   FUNCTION KILL with nothing running; FUNCTION HELP; an unknown
   subcommand; the arities; FLUSHALL and FLUSHDB leave the libraries.
4. FUNCTION DUMP and RESTORE: the payload's bytes (rdbcompression no on
   both: BendKV writes no LZF), RESTORE with APPEND, REPLACE and FLUSH,
   the collisions of a library and of a function, a payload whose
   checksum or version is wrong, a policy not there, too many arguments;
   payloads made here: two libraries, a library of FUNCTION (7.0's
   release candidates), a type that is no function, a library that does
   not compile after one that does, one cut short.
5. Functions in transactions (FCALL, FUNCTION LOAD and RESTORE in MULTI,
   EXEC's array), WATCH, FUNCTION refused in a script, and INFO's
   number_of_functions and number_of_libraries as libraries come and go.
6. INFO's statistics after functions: commandstats (FCALL's, FUNCTION's
   subcommands', and the calls functions make), errorstats and the
   totals, compared as maps, usec left out.
7. A function past busy-reply-threshold (100 ms on both): another
   client's commands answered BUSY, FUNCTION STATS while it runs (its
   name and command; its time by whether it is past the threshold),
   SCRIPT KILL refused for a function, FUNCTION KILL answered OK and the
   function's client the error of a killed function; FUNCTION KILL
   refused for an EVAL; a function that wrote first: UNKILLABLE, its loop
   awaited. --no-busy leaves this one out.
8. Functions and ACL: a function's calls checked with its caller's user
   (a command and a key not allowed), redis.acl_check_cmd in a function,
   FUNCTION's subcommands by what the user may run; EXEC of FCALLs that
   the user lost since they were queued (NOPERM in EXEC's array), and of
   a function whose call is refused; ACL LOG's entries (context lua with
   the caller's line, its command FCALL or EXEC), and INFO's statistics
   before the transactions (as in tests/script_test.py's scenario 13).

Then the payloads both ways (when --redis-check is given or always: the
two servers' clients together): Redis's FUNCTION DUMP with LZF
(rdbcompression yes) restored on BendKV, BendKV's restored on Redis, each
then listing the same libraries.

    python3 tests/function_test.py --bendkv 6380 --redis 6390 [--no-busy]
"""
import argparse
import struct
import sys
import time

from dump_test import crc64
from script_test import TAG, Client, acl_log, enc, info, k, parse, stats

LIB = "#!lua name=lib\nredis.register_function('f', function(keys, args) return 'hello' end)\n"


def lib(name, *fns, extra=""):
    """a library's code: its functions each returning their own name"""
    body = "".join("redis.register_function('%s', function(keys, args) return '%s' end)\n" % (f, f) for f in fns)
    return "#!lua name=%s\n%s%s" % (name, body, extra)


def value(data):
    """a RESP2 or RESP3 reply's value: bytes, ints, lists, and a map as
    a sorted list of its pairs; errors and statuses as they came"""
    v, _ = value_at(data, 0)
    return v


def value_at(data, i):
    j = data.index(b"\r\n", i)
    kind, head = data[i:i + 1], data[i + 1:j]
    if kind in (b"$", b"=", b"!"):
        n = int(head)
        return (None, j + 2) if n < 0 else (data[j + 2:j + 2 + n], j + 4 + n)
    if kind in (b"*", b"~", b">", b"%"):
        n = int(head)
        out, at = [], j + 2
        for _ in range(max(n, 0) * (2 if kind == b"%" else 1)):
            v, at = value_at(data, at)
            out.append(v)
        if kind == b"%":
            out = ("map", sorted(zip(out[0::2], out[1::2]), key=repr))
        elif kind == b"~":
            out = ("set", sorted(out, key=repr))
        return (None if n < 0 else out), at
    if kind == b"_":
        return None, j + 2
    if kind == b":":
        return int(head), j + 2
    return kind + head, j + 2


def norm_lib(x):
    """a library of FUNCTION LIST, its functions in the order of their
    names"""
    if isinstance(x, tuple):
        pairs = [(a, norm_fns(b) if a == b"functions" else b) for a, b in x[1]]
        return ("map", pairs)
    if isinstance(x, list):
        out = list(x)
        for i in range(0, len(out) - 1, 2):
            if out[i] == b"functions":
                out[i + 1] = norm_fns(out[i + 1])
        return out
    return x


def norm_fns(fs):
    if isinstance(fs, list):
        return sorted(fs, key=repr)
    return fs


def listing(c, *args):
    """FUNCTION LIST's reply as a set of libraries (each with its
    functions sorted), or an error's bytes"""
    rep = c.cmd("FUNCTION", "LIST", *args)
    if not isinstance(rep, bytes) or rep[:1] not in (b"*", b"~"):
        return rep
    return sorted((norm_lib(x) for x in value(rep)), key=repr)


def statsof(c):
    """FUNCTION STATS as a value (its engines' map sorted)"""
    rep = c.cmd("FUNCTION", "STATS")
    if not isinstance(rep, bytes) or rep[:1] not in (b"*", b"%"):
        return rep
    return value(rep)


def fresh(port, log, n):
    """a client of the scenario n, on a server emptied of its keys and
    its libraries"""
    r = Client(port)
    log(n + " flush", r.cmd("FLUSHALL"), r.cmd("FUNCTION", "FLUSH"))
    return r


def fcall(c, name, keys=(), args=(), cmd="FCALL"):
    return c.cmd(cmd, name, str(len(keys)), *keys, *args)


def counts(c):
    return [x for x in info(c, "memory") if x.startswith(("number_of_functions:", "number_of_libraries:"))]


# 1. FUNCTION LOAD
BAD_LOADS = [
    "", "redis.register_function('f', function() return 1 end)", "#!lua\nreturn 1", "#!lua name=a name=b\n",
    "#!lua name=a foo=bar\n", "#!lua name=bad-name\n", "#!lua name=\n", "#!nosuch name=x\n",
    "#!lua name=\"q x\"\nredis.register_function('f', function() return 1 end)",
    "#!lua name='q'\nredis.register_function('f', function() return 1 end)",
    "#!lua name=x", "#!lua name=x\n", "#!lua name=x\nreturn 1", "#!lua name=x\nthis is not lua",
    "#!lua name=x\nerror('at load')", "#!lua name=x\nerror({err='ERR from a table'})",
    "#!lua name=x\nlocal a = nil + 1",
]

REGISTERS = [
    "redis.register_function()", "redis.register_function('f')", "redis.register_function('f', 1)",
    "redis.register_function(1, function() end)", "redis.register_function('f', function() end, 3)",
    "redis.register_function('bad name', function() end)", "redis.register_function('', function() end)",
    "redis.register_function('t\\0t', function() end)", "redis.register_function{}",
    "redis.register_function{function_name='f'}", "redis.register_function{callback=function() end}",
    "redis.register_function{function_name=1, callback=function() end}",
    "redis.register_function{function_name='f', callback=1}",
    "redis.register_function{function_name='f', callback=function() end, flags='no-writes'}",
    "redis.register_function{function_name='f', callback=function() end, flags={'nosuch'}}",
    "redis.register_function{function_name='f', callback=function() end, flags={1}}",
    "redis.register_function{function_name='f', callback=function() end, description=1}",
    "redis.register_function{function_name='f', callback=function() end, nosuch=1}",
    "redis.register_function{function_name='f', callback=function() end, flags={'no-writes', 'allow-oom', 'allow-stale', 'no-cluster', 'allow-cross-slot-keys'}, description='all'}",
    "redis.register_function('f', function() end) redis.register_function('f', function() end)",
    "redis.register_function('F', function() end)",
    "redis.log(redis.LOG_NOTICE, 'loading') redis.register_function('f', function() end)",
    "redis.call('ping')", "redis.pcall('ping')", "redis.setresp(3)", "redis.set_repl(redis.REPL_ALL)",
    "x = 1", "local t = getmetatable(_G) redis.register_function('f', function() return 1 end)",
    "math.random() redis.register_function('f', function() return math.random() end)",
    "redis.register_function('v', function() return redis.REDIS_VERSION .. ' ' .. redis.REDIS_VERSION_NUM end)",
    "redis.register_function('g', function() return {type(redis.call), type(redis.register_function), type(cjson), type(bit)} end)",
    "redis.register_function('h', function() return redis.register_function('i', function() end) end)",
    "local r = redis redis.register_function('j', function() return r.call('ping') end)",
]


def loads(port, log):
    r = fresh(port, log, "1")
    log("1 load", r.cmd("FUNCTION", "LOAD", LIB), fcall(r, "f"), r.cmd("FUNCTION", "LOAD", LIB),
        r.cmd("FUNCTION", "LOAD", LIB.replace("name=lib", "name=LIB")))
    log("1 replace", r.cmd("FUNCTION", "LOAD", "REPLACE", lib("lib", "g")), fcall(r, "f"), fcall(r, "g"),
        r.cmd("FUNCTION", "LOAD", "replace", lib("lib", "g", extra="error('no')")), fcall(r, "g"),
        r.cmd("FUNCTION", "LOAD", "REPLACE", lib("lib", "g", "f", extra="this is not lua")), fcall(r, "g"))
    log("1 function elsewhere", r.cmd("FUNCTION", "LOAD", lib("other", "g")), r.cmd("FUNCTION", "LOAD", lib("other", "G")),
        r.cmd("FUNCTION", "LOAD", "REPLACE", lib("lib", "h")), r.cmd("FUNCTION", "LOAD", lib("other", "g")))
    for i, code in enumerate(BAD_LOADS):
        log("1 bad load %d" % i, r.cmd("FUNCTION", "LOAD", code))
    for i, body in enumerate(REGISTERS):
        name = "reg%d" % i
        log("1 register %d" % i, r.cmd("FUNCTION", "LOAD", "#!lua name=%s\n%s" % (name, body)))
    log("1 registered", fcall(r, "v"), fcall(r, "g"), fcall(r, "h"), fcall(r, "j"), fcall(r, "f", (), ()),
        listing(r, "LIBRARYNAME", "reg"))
    log("1 arity", r.cmd("FUNCTION", "LOAD"), r.cmd("FUNCTION", "LOAD", "REPLACE"), r.cmd("FUNCTION", "LOAD", "nosuch", LIB),
        r.cmd("FUNCTION", "LOAD", "REPLACE", "REPLACE", LIB), r.cmd("FUNCTION", "LOAD", LIB, "extra"))
    r.close()


# 2. FCALL
RETURNS = [
    "return nil", "return true", "return false", "return 42", "return 1.5", "return 'hello'", "return ''",
    "return {1, 'two', {3}}", "return {}", "return {ok='fine'}", "return {err='MY error'}",
    "return redis.error_reply('My Error')", "return redis.status_reply('PONGISH')",
    "return {double=1.5}", "return {map={a=1}}", "return {set={x=true}}",
    "redis.setresp(3) return redis.call('hgetall', KEYS[1])", "return {KEYS, ARGV}",
    "return redis.call('set', KEYS[1], ARGV[1])", "return redis.call('get', KEYS[1])",
    "return redis.pcall('nosuch')", "error('my error')", "error({err='CODE code'})", "local x = nil + 1",
    "return redis.call('incr', 'notanumber') ", "return redis.setresp(2)",
]


def calls(port, log):
    r = fresh(port, log, "2")
    code = "#!lua name=calls\n"
    for i, body in enumerate(RETURNS):
        code += "redis.register_function('r%d', function(KEYS, ARGV) %s end)\n" % (i, body)
    code += ("redis.register_function{function_name='ro', callback=function(KEYS, ARGV) return redis.call('get', KEYS[1]) end, flags={'no-writes'}}\n"
             "redis.register_function{function_name='rw', callback=function(KEYS, ARGV) return redis.call('set', KEYS[1], 'x') end, flags={'no-writes'}}\n"
             "redis.register_function('Mixed', function() return 'mixed' end)\n")
    log("2 load", r.cmd("FUNCTION", "LOAD", code), r.cmd("SET", k("s"), "v"), r.cmd("HSET", k("h"), "a", "1"),
        r.cmd("SET", k("n"), "x"))
    r3 = Client(port, resp3=True)
    for i in range(len(RETURNS)):
        keys = [k("h")] if "hgetall" in RETURNS[i] else [k("w%d" % i)]
        log("2 return %d" % i, fcall(r, "r%d" % i, keys, ["arg", ""]), fcall(r3, "r%d" % i, keys, ["arg", ""]),
            fcall(r, "r%d" % i, keys, ["arg"], cmd="FCALL_RO"))
    log("2 keys", fcall(r, "r17", [k("a"), b"", b"\x00\xff"], ["x", b"\r\n"]), fcall(r, "r17"),
        r.cmd("FCALL", "r17", "1"), r.cmd("FCALL", "r17", "2", "a"), r.cmd("FCALL", "r17", "-1"),
        r.cmd("FCALL", "r17", "x"), r.cmd("FCALL", "r17", "1.5"), r.cmd("FCALL", "r17", "99999999999999999999"),
        r.cmd("FCALL", "nosuch", "0"), r.cmd("FCALL", "nosuch", "x"), r.cmd("FCALL", "R17", "0"),
        r.cmd("FCALL", "mixed", "0"), r.cmd("FCALL", "MIXED", "0"), r.cmd("FCALL_RO", "nosuch", "-1"))
    log("2 ro", fcall(r, "ro", [k("s")], cmd="FCALL_RO"), fcall(r, "ro", [k("s")]), fcall(r, "rw", [k("s")]),
        fcall(r, "rw", [k("s")], cmd="FCALL_RO"), fcall(r, "r18", [k("s")], ["y"], cmd="FCALL_RO"), r.cmd("GET", k("s")))
    log("2 arity", r.cmd("FCALL"), r.cmd("FCALL", "r0"), r.cmd("FCALL_RO"), r.cmd("FCALL_RO", "r0"))
    r3.close()
    r.close()


# 3. LIST, DELETE, FLUSH, STATS, KILL, HELP
def lists(port, log):
    r = fresh(port, log, "3")
    log("3 empty", r.cmd("FUNCTION", "LIST"), r.cmd("FUNCTION", "STATS"), r.cmd("FUNCTION", "DUMP") != b"",
        r.cmd("FUNCTION", "KILL"), r.cmd("FUNCTION", "DELETE", "nosuch"))
    one = ("#!lua name=one\nredis.register_function{function_name='f1', callback=function() return 1 end, "
           "description='the first', flags={'no-writes', 'allow-oom'}}\n")
    log("3 one", r.cmd("FUNCTION", "LOAD", one), r.cmd("FUNCTION", "LIST"), r.cmd("FUNCTION", "LIST", "WITHCODE"),
        r.cmd("FUNCTION", "LIST", "LIBRARYNAME", "on*"), r.cmd("FUNCTION", "LIST", "WITHCODE", "LIBRARYNAME", "ONE"),
        r.cmd("FUNCTION", "LIST", "LIBRARYNAME", "x*"))
    r3 = Client(port, resp3=True)
    log("3 one resp3", r3.cmd("FUNCTION", "LIST"), r3.cmd("FUNCTION", "LIST", "WITHCODE"), r3.cmd("FUNCTION", "STATS"))
    log("3 more", r.cmd("FUNCTION", "LOAD", lib("two", "f2", "f3")), r.cmd("FUNCTION", "LOAD", lib("three", "f4")),
        listing(r), listing(r, "WITHCODE"), listing(r, "LIBRARYNAME", "t*"), listing(r3), statsof(r), statsof(r3))
    log("3 list errors", r.cmd("FUNCTION", "LIST", "WITHCODE", "WITHCODE"),
        r.cmd("FUNCTION", "LIST", "LIBRARYNAME", "a", "LIBRARYNAME", "b"), r.cmd("FUNCTION", "LIST", "LIBRARYNAME"),
        r.cmd("FUNCTION", "LIST", "nosuch"), r.cmd("FUNCTION", "LIST", "LIBRARYNAME", "a", "x"))
    log("3 delete", r.cmd("FUNCTION", "DELETE", "two"), fcall(r, "f2"), listing(r), r.cmd("FUNCTION", "DELETE", "two"),
        r.cmd("FUNCTION", "DELETE", "THREE"), r.cmd("FUNCTION", "DELETE"), r.cmd("FUNCTION", "DELETE", "a", "b"))
    log("3 flushall", r.cmd("FLUSHALL"), r.cmd("FLUSHDB"), listing(r), counts(r))
    log("3 flush", r.cmd("FUNCTION", "FLUSH", "SYNC"), listing(r), r.cmd("FUNCTION", "LOAD", LIB),
        r.cmd("FUNCTION", "FLUSH", "ASYNC"), listing(r), r.cmd("FUNCTION", "FLUSH", "nosuch"),
        r.cmd("FUNCTION", "FLUSH", "SYNC", "ASYNC"), r.cmd("FUNCTION", "LOAD", LIB), r.cmd("FUNCTION", "FLUSH"),
        listing(r), counts(r))
    log("3 kill and stats", r.cmd("FUNCTION", "KILL"), r.cmd("FUNCTION", "KILL", "x"), r.cmd("FUNCTION", "STATS", "x"),
        r.cmd("SCRIPT", "KILL"))
    log("3 help", r.cmd("FUNCTION", "HELP"), r.cmd("FUNCTION", "HELP", "x"), r.cmd("FUNCTION"), r.cmd("FUNCTION", "NOSUCH"),
        r.cmd("FUNCTION", "DUMP", "x"), r.cmd("FUNCTION", "RESTORE"))
    r3.close()
    r.close()


# 4. DUMP and RESTORE
def payload(*parts, version=10, sum=True):
    """a payload made here: its parts, the version and the CRC64"""
    body = b"".join(parts) + struct.pack("<H", version)
    return body + struct.pack("<Q", crc64(body) if sum else 0)


def rstr(b):
    b = b.encode() if isinstance(b, str) else b
    assert len(b) < 16384
    return (bytes([len(b)]) if len(b) < 64 else struct.pack(">H", 0x4000 | len(b))) + b


def dumps(port, log):
    r = fresh(port, log, "4")
    was = r.cmd("CONFIG", "GET", "rdbcompression")
    try:
        log("4 no compression", r.cmd("CONFIG", "SET", "rdbcompression", "no"))
        log("4 load", r.cmd("FUNCTION", "LOAD", LIB))
        d = r.cmd("FUNCTION", "DUMP")
        p = value(d)
        log("4 dump", d)
        log("4 restore", r.cmd("FUNCTION", "RESTORE", p), r.cmd("FUNCTION", "RESTORE", p, "APPEND"),
            r.cmd("FUNCTION", "RESTORE", p, "replace"), fcall(r, "f"), r.cmd("FUNCTION", "DELETE", "lib"),
            r.cmd("FUNCTION", "RESTORE", p), fcall(r, "f"))
        log("4 flush policy", r.cmd("FUNCTION", "LOAD", lib("other", "g")), r.cmd("FUNCTION", "RESTORE", p, "FLUSH"),
            listing(r), fcall(r, "g"))
        log("4 function collision", r.cmd("FUNCTION", "FLUSH"), r.cmd("FUNCTION", "LOAD", lib("other", "f")),
            r.cmd("FUNCTION", "RESTORE", p), r.cmd("FUNCTION", "RESTORE", p, "REPLACE"), listing(r))
        log("4 bad", r.cmd("FUNCTION", "RESTORE", b"bad payload"), r.cmd("FUNCTION", "RESTORE", p[:-1] + bytes([p[-1] ^ 1])),
            r.cmd("FUNCTION", "RESTORE", p, "nosuch"), r.cmd("FUNCTION", "RESTORE", p, "APPEND", "x"),
            r.cmd("FUNCTION", "RESTORE", b""), r.cmd("FUNCTION", "RESTORE", p[:9]), listing(r))
        log("4 two", r.cmd("FUNCTION", "FLUSH"), r.cmd("FUNCTION", "LOAD", lib("a1", "fa")), r.cmd("FUNCTION", "LOAD", lib("a2", "fb")))
        two = value(r.cmd("FUNCTION", "DUMP"))
        log("4 two restored", r.cmd("FUNCTION", "FLUSH"), r.cmd("FUNCTION", "RESTORE", two), listing(r))
        made = [
            ("two made here", payload(b"\xf5" + rstr(lib("m1", "m1f")), b"\xf5" + rstr(lib("m2", "m2f")))),
            ("FUNCTION", payload(b"\xf6" + rstr("old") + rstr("LUA") + b"\x01" + rstr("desc") +
                                 rstr("\nredis.register_function('oldf', function() return 'o' end)\n"))),
            ("FUNCTION without a description", payload(b"\xf6" + rstr("old2") + rstr("lua") + b"\x00" +
                                                        rstr("\nredis.register_function('old2f', function() return 'o' end)\n"))),
            ("a type that is no function", payload(b"\x00" + rstr("k") + rstr("v"))),
            ("one that does not compile after one that does", payload(b"\xf5" + rstr(lib("g1", "g1f")), b"\xf5" + rstr("#!lua name=g2\nnot lua"))),
            ("one that compiles after a bad type", payload(b"\xf5" + rstr(lib("h1", "h1f")), b"\x07")),
            ("one cut short", payload(b"\xf5" + b"\x3f" + b"#!lua name=c\n")),
            ("a library twice", payload(b"\xf5" + rstr(lib("t1", "t1f")), b"\xf5" + rstr(lib("t1", "t2f")))),
            ("a function twice", payload(b"\xf5" + rstr(lib("u1", "uf")), b"\xf5" + rstr(lib("u2", "uf")))),
            ("version 11", payload(b"\xf5" + rstr(lib("v1", "vf")), version=11)),
            ("version 9", payload(b"\xf5" + rstr(lib("v9", "v9f")), version=9)),
            ("nothing", payload()),
            ("no metadata", payload(b"\xf5" + rstr("redis.register_function('nm', function() return 1 end)"))),
        ]
        for name, data in made:
            log("4 made: " + name, r.cmd("FUNCTION", "FLUSH"), r.cmd("FUNCTION", "RESTORE", data), listing(r, "WITHCODE"))
    finally:
        old = was.split(b"\r\n")[4] if isinstance(was, bytes) and was.startswith(b"*2\r\n") else b"yes"
        r.cmd("CONFIG", "SET", "rdbcompression", old or b"yes")
        r.close()


# 5. transactions, scripts, INFO's counts
def transactions(port, log):
    r = fresh(port, log, "5")
    log("5 counts", counts(r), r.cmd("FUNCTION", "LOAD", lib("x1", "a", "b")), counts(r),
        r.cmd("FUNCTION", "LOAD", lib("x2", "c")), counts(r), r.cmd("FUNCTION", "DELETE", "x1"), counts(r))
    p = value(r.cmd("FUNCTION", "DUMP"))
    log("5 multi", r.cmd("MULTI"), r.cmd("FUNCTION", "LOAD", lib("t1", "tf")), fcall(r, "tf"),
        r.cmd("FUNCTION", "LOAD", lib("t1", "tf")), r.cmd("FUNCTION", "RESTORE", p, "REPLACE"), fcall(r, "c"),
        r.cmd("FUNCTION", "LIST", "LIBRARYNAME", "t1"), r.cmd("FUNCTION", "DELETE", "t1"), fcall(r, "tf"),
        r.cmd("EXEC"), counts(r))
    log("5 multi errors", r.cmd("MULTI"), r.cmd("FCALL", "c"), r.cmd("FUNCTION", "LOAD"), fcall(r, "c"), r.cmd("EXEC"))
    w = Client(port)
    code = "#!lua name=wr\nredis.register_function('setk', function(keys, args) return redis.call('set', keys[1], args[1]) end)\n"
    log("5 watch", r.cmd("FUNCTION", "LOAD", code), r.cmd("WATCH", k("w")), fcall(w, "setk", [k("w")], ["1"]),
        r.cmd("MULTI"), r.cmd("GET", k("w")), r.cmd("EXEC"))
    log("5 watch a load", r.cmd("WATCH", k("w")), w.cmd("FUNCTION", "LOAD", lib("y", "yf")), r.cmd("MULTI"),
        r.cmd("GET", k("w")), r.cmd("EXEC"))
    log("5 in a script", r.cmd("EVAL", "return redis.call('FUNCTION', 'LIST')", "0"),
        r.cmd("EVAL", "return redis.call('FCALL', 'c', 0)", "0"), fcall(r, "c"),
        r.cmd("FUNCTION", "LOAD", "#!lua name=z\nredis.register_function('zf', function() return redis.call('FUNCTION', 'FLUSH') end)\n"),
        fcall(r, "zf"), r.cmd("FUNCTION", "LOAD", "#!lua name=z2\nredis.register_function('zf2', function() return redis.call('EVAL', 'return 1', 0) end)\n"),
        fcall(r, "zf2"), r.cmd("FUNCTION", "LOAD", "#!lua name=z3\nredis.register_function('zf3', function() return redis.call('FCALL', 'c', 0) end)\n"),
        fcall(r, "zf3"))
    w.close()
    r.close()


# 6. statistics
def statistics(port, log):
    r = fresh(port, log, "6")
    log("6 resetstat", r.cmd("CONFIG", "RESETSTAT"))
    code = ("#!lua name=st\nredis.register_function('s', function(keys, args) redis.call('set', keys[1], 'v') return redis.call('get', keys[1]) end)\n"
            "redis.register_function('e', function(keys, args) return redis.call('nosuch') end)\n"
            "redis.register_function('p', function(keys, args) return redis.pcall('incr', keys[1]) end)\n")
    log("6 calls", r.cmd("FUNCTION", "LOAD", code), fcall(r, "s", [k("a")]), fcall(r, "e"), fcall(r, "p", [k("a")]),
        fcall(r, "nosuch"), r.cmd("FCALL", "s", "x"), fcall(r, "s", [k("a")], cmd="FCALL_RO"), listing(r),
        r.cmd("FUNCTION", "LOAD", code), r.cmd("FUNCTION", "DELETE", "nosuch"), r.cmd("FUNCTION", "STATS"),
        r.cmd("FUNCTION", "RESTORE", b"x"))
    log("6 stats", *stats(r))
    r.close()


# 7. BUSY and FUNCTION KILL
LOOP = 300000000


def stats_busy(c):
    """FUNCTION STATS while a function runs: its running script's name
    and command as they came, and whether its time is past 100 ms"""
    rep = c.cmd("FUNCTION", "STATS")
    if not isinstance(rep, bytes) or rep[:1] not in (b"*", b"%"):
        return rep
    v = value(rep)
    if isinstance(v, list) and len(v) == 4 and isinstance(v[1], list):
        run = dict(zip(v[1][0::2], v[1][1::2]))
        return (run.get(b"name"), run.get(b"command"), (run.get(b"duration_ms") or 0) >= 100, v[3])
    return v


def busy(port, log):
    r = fresh(port, log, "7")
    was = r.cmd("CONFIG", "GET", "busy-reply-threshold")
    try:
        log("7 threshold", r.cmd("CONFIG", "SET", "busy-reply-threshold", "100"), r.cmd("CONFIG", "RESETSTAT"))
        code = ("#!lua name=busy\nredis.register_function('loop', function() while true do end end)\n"
                "redis.register_function('wloop', function(keys) redis.call('set', keys[1], 'w') local i = 0 "
                "while i < %d do i = i + 1 end return i end)\n"
                "redis.register_function{function_name='roloop', callback=function() while true do end end, flags={'no-writes'}}\n" % LOOP)
        log("7 load", r.cmd("FUNCTION", "LOAD", code))
        a, b = Client(port), Client(port)
        a.send("FCALL", "loop", "1", k("x"), "an argument")
        time.sleep(0.2)
        first = b.cmd("PING")
        if first == "TIMEOUT":
            log("7 busy", first)
            return
        log("7 busy", first, b.cmd("GET", k("x")), b.cmd("FCALL", "loop", "0"), b.cmd("FUNCTION", "LIST"),
            b.cmd("FUNCTION", "LOAD", LIB), b.cmd("FUNCTION", "DELETE", "busy"), stats_busy(b), b.cmd("SCRIPT", "KILL"))
        kill, killed = b.cmd("FUNCTION", "KILL"), a.read()
        if killed == "TIMEOUT":
            log("7 kill", kill, killed)
            return
        log("7 kill", kill, killed, b.cmd("PING"), b.cmd("FUNCTION", "KILL"), a.cmd("PING"), stats_busy(b))
        a.send("FCALL_RO", "roloop", "0")
        time.sleep(0.2)
        log("7 kill ro", b.cmd("PING"), stats_busy(b), b.cmd("FUNCTION", "KILL"), a.read(), b.cmd("PING"))
        a.send("EVAL", "while true do end", "0")
        time.sleep(0.2)
        log("7 kill an eval", b.cmd("PING"), b.cmd("FUNCTION", "KILL"), stats_busy(b), b.cmd("SCRIPT", "KILL"), a.read(),
            b.cmd("PING"))
        a.send("FCALL", "wloop", "1", k("w"))
        time.sleep(0.2)
        log("7 unkillable", b.cmd("PING"), b.cmd("FUNCTION", "KILL"), b.cmd("GET", k("w")), stats_busy(b))
        log("7 loop ends", a.read(120.0), b.cmd("GET", k("w")), b.cmd("FUNCTION", "KILL"), a.cmd("PING"))
        log("7 stats", *stats(r))
        a.close()
        b.close()
    finally:
        old = was.split(b"\r\n")[4] if isinstance(was, bytes) and was.startswith(b"*2\r\n") else b""
        r.cmd("CONFIG", "SET", "busy-reply-threshold", old if old.isdigit() else b"5000")
        r.close()


# 8. functions and ACL
def acl(port, log):
    r = fresh(port, log, "8")
    u = "f" + TAG
    log("8 reset", r.cmd("CONFIG", "RESETSTAT"), r.cmd("ACL", "LOG", "RESET"))
    code = ("#!lua name=al\n"
            "redis.register_function('g', function(keys, args) return redis.call('get', keys[1]) end)\n"
            "redis.register_function('s', function(keys, args) return redis.call('set', keys[1], args[1]) end)\n"
            "redis.register_function('sa', function(keys, args) return redis.call('set', args[1], args[2]) end)\n"
            "redis.register_function('c', function(keys, args) if #args == 2 then "
            "return redis.acl_check_cmd(args[1], args[2]) end return redis.acl_check_cmd(args[1], args[2], args[3]) end)\n")
    log("8 load", r.cmd("FUNCTION", "LOAD", code))
    log("8 user", r.cmd("ACL", "SETUSER", u, "on", ">p", "+fcall", "+set", "+multi", "+exec", "+function|list", "~x*"))
    c = Client(port)
    log("8 auth", c.cmd("AUTH", u, "p"))
    # a function's calls: allowed, a command and a key not allowed;
    # redis.acl_check_cmd; FUNCTION's subcommands
    log("8 calls", fcall(c, "s", [k("xa")], ["1"]), fcall(c, "g", [k("xa")]), fcall(c, "sa", [], [k("ya"), "1"]),
        fcall(c, "c", [], ["set", k("xa"), "1"]), fcall(c, "c", [], ["get", k("xa")]),
        fcall(c, "c", [], ["set", k("ya"), "1"]), fcall(c, "c", [], ["nosuch", "x"]))
    log("8 function", c.cmd("FUNCTION", "LIST", "LIBRARYNAME", "nosuch"), c.cmd("FUNCTION", "DELETE", "al"),
        fcall(c, "g", [k("ya")]))
    log("8 stats", *stats(r))
    # EXEC of FCALLs that the user lost since they were queued (the
    # transaction ends with a command that runs, as in script_test's 13)
    log("8 multi", c.cmd("MULTI"), fcall(c, "s", [k("xb")], ["2"]), c.cmd("SET", k("xc"), "3"),
        fcall(c, "s", [k("xd")], ["4"]), c.cmd("SET", k("xe"), "5"))
    log("8 fcall lost", r.cmd("ACL", "SETUSER", u, "-fcall"))
    log("8 exec", c.cmd("EXEC"), r.cmd("GET", k("xb")), r.cmd("GET", k("xc")))
    log("8 fcall back", r.cmd("ACL", "SETUSER", u, "+fcall"))
    log("8 exec call", c.cmd("MULTI"), fcall(c, "g", [k("xb")]), c.cmd("SET", k("xf"), "6"), c.cmd("EXEC"))
    log("8 log", *acl_log(r))
    c.close()
    log("8 deluser", r.cmd("ACL", "DELUSER", u), r.cmd("ACL", "LOG", "RESET"))
    r.close()


SCENARIOS = [("1 FUNCTION LOAD", loads), ("2 FCALL", calls), ("3 LIST and the rest", lists), ("4 DUMP and RESTORE", dumps),
             ("5 transactions", transactions), ("6 statistics", statistics), ("7 BUSY", busy), ("8 ACL", acl)]


def transcript(port, scenario):
    """the lines of a scenario on one server; an exception ends them"""
    lines = []
    try:
        scenario(port, lambda *x: lines.append(" ".join(repr(v) for v in x)))
    except Exception as e:
        lines.append("EXCEPTION %r" % (e,))
    return lines


def both_ways(bport, rport):
    """Redis's FUNCTION DUMP (with LZF) restored on BendKV, and BendKV's
    on Redis: the same libraries on both. The errors found, as lines"""
    out = []
    b, r = Client(bport), Client(rport)
    try:
        code = lib("cross", "cf", extra="-- " + "words the same, words the same, " * 20 + "\n")
        for c in (b, r):
            c.cmd("FUNCTION", "FLUSH")
            c.cmd("FUNCTION", "LOAD", code)
            c.cmd("FUNCTION", "LOAD", lib("cross2", "cg"))
        was = r.cmd("CONFIG", "GET", "rdbcompression")
        r.cmd("CONFIG", "SET", "rdbcompression", "yes")
        theirs = value(r.cmd("FUNCTION", "DUMP"))
        old = was.split(b"\r\n")[4] if isinstance(was, bytes) and was.startswith(b"*2\r\n") else b"yes"
        r.cmd("CONFIG", "SET", "rdbcompression", old or b"yes")
        mine = value(b.cmd("FUNCTION", "DUMP"))
        want = listing(r, "WITHCODE")
        for name, c, p in (("BendKV restores Redis's payload (LZF)", b, theirs), ("Redis restores BendKV's payload", r, mine)):
            got = (c.cmd("FUNCTION", "FLUSH"), c.cmd("FUNCTION", "RESTORE", p), listing(c, "WITHCODE"), fcall(c, "cf"))
            if got != (b"+OK\r\n", b"+OK\r\n", want, b"$2\r\ncf\r\n"):
                out.append("FAIL: %s:\n      got  %r\n      want %r" % (name, got, want))
    finally:
        for c in (b, r):
            c.cmd("FUNCTION", "FLUSH")
            c.close()
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, required=True)
    ap.add_argument("--redis", type=int, required=True)
    ap.add_argument("--no-busy", action="store_true", help="leave out the scenario of a function past busy-reply-threshold")
    args = ap.parse_args()
    bad = total = shown = 0
    for name, scenario in SCENARIOS:
        if args.no_busy and scenario is busy:
            continue
        x, y = transcript(args.bendkv, scenario), transcript(args.redis, scenario)
        x += ["<none>"] * (len(y) - len(x))
        y += ["<none>"] * (len(x) - len(y))
        diff = [i for i in range(len(y)) if x[i] != y[i]]
        total += len(y)
        bad += len(diff)
        for i in diff[:3]:
            if shown < 30:
                shown += 1
                print("FAIL: %s, line %d:\n      BendKV %s\n      Redis  %s" % (name, i + 1, x[i][:600], y[i][:600]))
        if diff:
            print("FAIL: %s: %d of %d lines differ" % (name, len(diff), len(y)))
    cross = both_ways(args.bendkv, args.redis)
    for line in cross:
        print(line)
    bad += len(cross)
    total += 2
    if bad:
        print("FAIL: %d of %d lines of the function scenarios differ" % (bad, total))
        sys.exit(1)
    print("OK: %d lines of function scenarios as Redis answers them, and payloads both ways%s" %
          (total, " (BUSY left out)" if args.no_busy else ""))


if __name__ == "__main__":
    main()
