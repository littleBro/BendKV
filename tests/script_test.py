#!/usr/bin/env python3
"""Lua scripts against Redis: EVAL, EVALSHA, EVAL_RO, EVALSHA_RO and
SCRIPT, scenarios run on BendKV and on Redis with clients of their own,
each reply logged as the bytes the server sent, the transcripts compared
line by line, scenario by scenario. What is the server's own is left
out: of INFO, only the fields compared are kept (the statistics, the
count of scripts cached), HELLO's reply is not logged, and a time to
live is compared by its range. Each scenario starts with FLUSHALL and
SCRIPT FLUSH, and its keys carry a tag new to each run.

The scenarios:

1. EVAL's replies: each Lua type a script returns (nil, the booleans,
   numbers cut to integers, 1.5, negative ones and ones past a long
   long, strings, binary ones, nested tables, tables with holes, the
   status and error tables, redis.status_reply and redis.error_reply,
   RESP3's types as tables), on a RESP2 connection and on a RESP3 one;
   KEYS and ARGV (binary values, empty strings); numkeys's errors (more
   keys than arguments, negative, not an integer) and the arities.
2. redis.call and redis.pcall: each kind of reply made a Lua value and
   back (a key not there is false, integers, statuses, bulks, arrays,
   nested arrays, HGETALL), the errors of commands (WRONGTYPE, an
   unknown command, a wrong number of arguments, no arguments at all, an
   argument that is a table, a boolean or nil), numbers as arguments
   (%.17g), pcall's error table and pcall(redis.call, ...)'s plain
   message, the commands a script may not call (EVAL, MULTI, SUBSCRIBE),
   the blocking ones, which run as in MULTI, without waiting (BLPOP,
   BRPOPLPUSH, BZPOPMIN, BLMPOP, BZMPOP, WAIT), XREAD's BLOCK, which
   Redis refuses a script,
   SELECT in a script, which leaves the caller's database as it was, and
   SORT of a set by a constant, which Redis sorts with ALPHA for a script.
3. Error texts: runtime errors, compile errors, a global not there, a
   write to a global (the globals are read only), error() with a table,
   with a number, a boolean or nothing, the suffix "script: <sha>,
   on @user_script:N." with the line it names, and a CR or an LF in an
   error's text, sent as a space.
4. The script cache: SCRIPT LOAD, EVALSHA (with the sha in upper case
   too), SCRIPT EXISTS of several shas, NOSCRIPT, SCRIPT FLUSH (SYNC,
   ASYNC, a bad option), SCRIPT HELP, SCRIPT KILL with no script
   running, the cache shared by clients; EVAL_RO and EVALSHA_RO refusing
   writes, the shebang (#!lua and its flags) and the errors of bad ones.
5. The libraries: cjson (and its errors), cmsgpack, bit, struct,
   string.format, table.sort, tostring of numbers (%.14g), math.random
   after math.randomseed (Redis's own generator: the same numbers on
   both), redis.sha1hex, redis.REDIS_VERSION, redis.setresp(3) (maps,
   sets, doubles, nulls, booleans) on a RESP2 and a RESP3 connection,
   and redis.log.
6. Scripts in MULTI and EXEC (their replies in EXEC's array, errors
   among them, EXECABORT), scripts and WATCH (a script that writes the
   key watched, or reads it, or writes another, or fails to write it),
   what a script wrote as another client reads it, and INFO's
   number_of_cached_scripts as scripts are loaded and flushed.
7. INFO's statistics after scripts: commandstats (each command's calls,
   rejected calls and failed calls: EVAL's, EVALSHA's, SCRIPT's
   subcommands' and those of the commands scripts call), errorstats,
   total_error_replies and total_commands_processed, compared as maps,
   usec left out.
8. A script past lua-time-limit (set to 100 ms on both): the commands of
   another client answered BUSY, PING too, and a client that connects
   then; MULTI and DISCARD let through and EXEC aborted; SCRIPT KILL
   answered OK and the script's client the error of a killed script (a
   script that loops inside pcall too); a script that wrote before it
   loops: SCRIPT KILL answered UNKILLABLE, and the end of its loop (of a
   fixed count, one to two seconds on Redis) awaited rather than a
   SHUTDOWN NOSAVE; another client's command run with a script (a pause
   of everything held both): its reply while the script runs; then INFO's
   statistics. A server that answers no
   one while a script loops, or does not kill it, ends the scenario
   there. --no-busy leaves this one out.
9. The slow log and the latency monitor of scripts (thresholds of 50 ms
   on both): a slow script logged with its arguments, its fast call of
   SET not; in a pipeline, a GET after a slow script not logged; in a
   transaction, the slow script logged and EXEC not; the latency
   monitor's event of the script ("command"). Entries are compared by
   their arguments and whether they took the threshold.
10. Scripts in pipelines: scripts among other commands of one pipeline,
   each reply in its place; a RESP3 client with a subscription whose
   script publishes to its own channel, its pushes and replies in
   Redis's order.
11. Scripts under a pause of writes, by their flags as Redis reads them:
   a script that declares no-writes, EVAL_RO without a shebang and an
   EXEC of scripts that declare no-writes run at once; EVAL without a
   shebang, EVALSHA, EVAL_RO whose shebang does not declare no-writes
   and an EXEC that queued one are held back, then run.
12. Scripts and CLIENT TRACKING (RESP3), as Redis 7.2.16 runs them, a
   script's calls its caller's (current_client): the caller's own
   invalidation after its script's reply, after its replies before the
   script in a pipeline, and none in NOLOOP mode; in BCAST mode after the
   reply, NOLOOP or not (Redis keeps the script's own client as the key's
   changer); a client that a tracking client redirects to, which runs the
   script, told before the script's reply; the keys a script's read-only
   calls read, remembered for its caller (a key read without declaring it
   too, a key declared and not read not; under OPTIN only with CLIENT
   CACHING yes; EVAL_RO's own keys none); a FLUSHALL in a script, its
   null after the reply.
13. Scripts and ACL, as Redis 7.2.16 runs them, a script's calls checked
   with its caller's user (scriptVerifyACL): redis.acl_check_cmd of a
   command allowed, of one not allowed, of a key not allowed and of a
   command not known; calls of a command, a key and a channel not
   allowed (redis.call's error and redis.pcall's error table); EXEC of a
   script whose command its user lost since it was queued (NOPERM in
   EXEC's array, the commands after it run), and of a script whose call
   is refused; ACL LOG's entries (context lua, the caller's line, its
   command EVAL or EXEC; the volatile fields of the line left out), and
   INFO's statistics before and after the transactions.

Not tested: error() with a table that has no 'err' field (error({}))
makes Redis 7.2.16 crash (sdscatfmt reads the message it does not have).

    python3 tests/script_test.py --bendkv 6380 --redis 6390 [--no-busy]
"""
import argparse
import hashlib
import os
import socket
import sys
import time

# the tag in the keys' names: new to each run, the same on both servers
TAG = os.urandom(4).hex()


def k(name):
    return "%s.%s" % (name, TAG)


def sha(body):
    return hashlib.sha1(body.encode() if isinstance(body, str) else body).hexdigest()


def enc(args):
    out = b"*%d\r\n" % len(args)
    for a in args:
        a = a.encode() if isinstance(a, str) else a
        out += b"$%d\r\n%s\r\n" % (len(a), a)
    return out


class Short(Exception):
    """A reply that has not all come yet."""


class Client:
    """A connection whose replies are read whole, as the bytes the server
    sent, and whose reads time out: a reply that does not come in time
    reads as TIMEOUT, and one from a connection the server closed as
    CLOSED. In database 9 (db), and in RESP3 when resp3 is set."""

    def __init__(self, port, db="9", resp3=False):
        self.sock = socket.create_connection(("127.0.0.1", port))
        self.buf = b""
        if resp3:
            # HELLO's map names the server's version and the client's id,
            # which are the server's own: it is not logged
            self.cmd("HELLO", "3")
        if db is not None:
            self.cmd("SELECT", db)

    def send(self, *args):
        self.sock.sendall(enc(args))

    def _end(self, i):
        """where the reply that starts at i in the buffer ends"""
        j = self.buf.find(b"\r\n", i)
        if j < 0:
            raise Short
        kind = self.buf[i:i + 1]
        if kind in (b"$", b"=", b"!"):
            n = int(self.buf[i + 1:j])
            end = j + 2 if n < 0 else j + 4 + n
            if len(self.buf) < end:
                raise Short
            return end
        if kind in (b"*", b"~", b">", b"%", b"|"):
            # a null array (*-1) has no items; a map and an attribute two
            # per entry, and an attribute the reply it comes with after it
            n = int(self.buf[i + 1:j]) * (2 if kind in (b"%", b"|") else 1)
            end = j + 2
            for _ in range(n):
                end = self._end(end)
            return self._end(end) if kind == b"|" else end
        return j + 2

    def read(self, timeout=5.0):
        deadline = time.time() + timeout
        while True:
            try:
                end = self._end(0)
                data, self.buf = self.buf[:end], self.buf[end:]
                return data
            except Short:
                pass
            left = deadline - time.time()
            if left <= 0:
                return "TIMEOUT"
            self.sock.settimeout(left)
            try:
                data = self.sock.recv(1 << 16)
            except socket.timeout:
                return "TIMEOUT"
            except OSError:
                return "CLOSED"
            if not data:
                return "CLOSED"
            self.buf += data

    def cmd(self, *args, timeout=5.0):
        self.send(*args)
        return self.read(timeout)

    def close(self):
        self.sock.close()


def ev(c, body, keys=(), args=(), cmd="EVAL"):
    """a script run with its keys and its arguments: its reply"""
    return c.cmd(cmd, body, str(len(keys)), *keys, *args)


def fresh(port, log, n):
    """a client of the scenario n, on a server emptied of its keys and
    its scripts"""
    r = Client(port)
    log(n + " flush", r.cmd("FLUSHALL"), r.cmd("SCRIPT", "FLUSH"))
    return r


def info(c, section):
    """INFO's lines of a section, as text"""
    rep = c.cmd("INFO", section)
    if not isinstance(rep, bytes) or rep[:1] not in (b"$", b"="):
        return [repr(rep)]
    return rep.split(b"\r\n", 1)[1].decode(errors="replace").split("\r\n")


def stats(c):
    """commandstats, errorstats and the totals, as maps: each command's
    calls, rejected calls and failed calls (not its time), each error
    code's count"""
    cmds, errs, tot = {}, {}, {}
    for line in info(c, "commandstats") + info(c, "errorstats") + info(c, "stats"):
        if line.startswith("cmdstat_"):
            name, rest = line[len("cmdstat_"):].split(":", 1)
            f = dict(kv.split("=") for kv in rest.split(","))
            cmds[name] = (int(f["calls"]), int(f["rejected_calls"]), int(f["failed_calls"]))
        elif line.startswith("errorstat_"):
            name, rest = line[len("errorstat_"):].split(":", 1)
            errs[name] = int(rest.split("=")[1])
        elif line.startswith(("total_error_replies:", "total_commands_processed:")):
            name, v = line.split(":")
            tot[name] = int(v)
    return sorted(cmds.items()), sorted(errs.items()), sorted(tot.items())


# 1. what a script returns, as the caller gets it
RETURNS = [
    # nil, the booleans; numbers, cut to integers (Lua's are doubles; past
    # a long long, C's conversion gives the least one on x86-64)
    "return nil", "return true", "return false", "return 42", "return -42", "return 0", "return 1.5",
    "return -1.5", "return 0.9999", "return 2^53", "return 2^53 + 1", "return -2^63", "return 2^63",
    "return 1e20", "return -1e20", "return 0/0", "return 1/0",
    # strings, binary ones
    "return 'hello'", "return ''", "return 'a\\0b\\r\\n\\255'", "return string.rep('x', 1000)",
    # tables: nested, empty, with holes (an array ends at its first nil),
    # with values of every kind (false is a null, a function too)
    "return {1, 'two', {3, {4, 'five', {}}}, {}}", "return {}", "return {1, 2, nil, 4}", "return {nil, 1}",
    "return {1.5, -2.5, 'x', true, false, 3}", "return {function() end, 1}", "return function() end",
    # the status and error tables, and their helpers
    "return {ok='fine'}", "return {ok=''}", "return {ok='a\\r\\nb'}", "return {ok=42}", "return {ok='x', 1, 2}",
    "return {err='MYCODE my message'}", "return {err='nocode'}", "return {err='a\\r\\nb'}", "return {err=42}",
    "return {err='first', ok='second'}",
    "return redis.error_reply('My Error')", "return redis.error_reply('-CODE with a dash')",
    "return redis.error_reply('nocode')", "return redis.error_reply('')", "return redis.error_reply(42)",
    "return redis.error_reply()", "return redis.status_reply('PONGISH')", "return redis.status_reply('')",
    "return redis.status_reply({})", "return redis.status_reply()",
    # RESP3's types as tables, each in the caller's protocol
    "return {double=1.5}", "return {double=0.1}", "return {double=-1/0}", "return {double='x'}",
    "return {map={a=1, b='two', c={1, 2}}}", "return {map={}}", "return {set={x=true, y=true}}",
    "return {big_number='123456789012345678901234567890'}", "return {big_number='1\\r\\n2'}",
    "return {verbatim_string={format='txt', string='hello'}}", "return {verbatim_string={format='txt'}}",
]

KEYS_ARGV = [
    "return {KEYS, ARGV}", "return {#KEYS, #ARGV}", "return KEYS[1] .. ARGV[3]",
    "KEYS[1] = 'changed' return KEYS",
    "return {type(KEYS), type(ARGV), tostring(KEYS[4]), tostring(ARGV[7])}",
    "return tonumber(ARGV[6]) * 2 + tonumber(ARGV[5])",
]


def replies(port, log):
    fresh(port, log, "1").close()
    keys = [k("a"), b"", b"\x00\xff\r\n"]
    args = [b"", b"\x00\xff\r\n", "\u043a\u043b\u044e\u0447".encode(), b"x" * 600, b"-1", b"3.5"]
    for proto in ("2", "3"):
        c = Client(port, resp3=proto == "3")
        for body in RETURNS:
            log("1 resp" + proto, body, ev(c, body))
        for body in KEYS_ARGV:
            log("1 keys resp" + proto, body, ev(c, body, keys, args))
        c.close()
    c = Client(port)
    # numkeys: what fits, and its errors (before the script compiles)
    for nk, rest in (("0", []), ("0", ["a", "b"]), ("2", ["a", "b"]), ("1", ["a", "b"])):
        log("1 numkeys", nk, rest, c.cmd("EVAL", "return {KEYS, ARGV}", nk, *rest))
    for nk in ("2", "-1", "1.5", "abc", "", " 1", "+1", "01", "-0", "99999999999999999999",
               "-99999999999999999999", "9223372036854775807", "-9223372036854775808"):
        log("1 numkeys error", nk, c.cmd("EVAL", "return {KEYS, ARGV}", nk, "a"))
    log("1 numkeys first", c.cmd("EVAL", "return (", "5"), c.cmd("EVALSHA", "f" * 40, "2", "a"),
        c.cmd("EVALSHA", "f" * 40, "-1"), c.cmd("EVAL_RO", "return 1", "3"))
    # the arities
    for args in (["EVAL"], ["EVAL", "return 1"], ["eval", "return 1"], ["EVALSHA"], ["EVALSHA", sha("return 1")],
                 ["EVAL_RO"], ["EVAL_RO", "return 1"], ["EVALSHA_RO"], ["EVALSHA_RO", sha("return 1")]):
        log("1 arity", args, c.cmd(*args))
    c.close()


# 2. redis.call and redis.pcall: (script, names of its keys, its arguments)
CALLS = [
    # each kind of reply, and what it is in Lua
    ("return redis.call('GET', KEYS[1])", ["none"], []),
    ("local v = redis.call('GET', KEYS[1]) return {type(v), tostring(v)}", ["none"], []),
    ("return redis.call('GET', KEYS[1])", ["str"], []),
    ("return redis.call('INCR', KEYS[1])", ["num"], []),
    ("local v = redis.call('INCRBY', KEYS[1], 5) return {type(v), v}", ["num"], []),
    ("return redis.call('SET', KEYS[1], ARGV[1])", ["new"], [b"\x00bin\r\n\xff"]),
    ("local r = redis.call('SET', KEYS[1], ARGV[1]) return {type(r), r.ok}", ["new"], [b"\x00bin\r\n\xff"]),
    ("return redis.call('GET', KEYS[1])", ["new"], []),
    ("return redis.call('set', KEYS[1], 'lower')", ["low"], []),
    ("return redis.call('gEt', KEYS[1])", ["low"], []),
    ("return redis.call('LRANGE', KEYS[1], 0, -1)", ["list"], []),
    ("return redis.call('LRANGE', KEYS[1], 0, -1)", ["none"], []),
    ("return redis.call('ZRANGE', KEYS[1], 0, -1, 'WITHSCORES')", ["zset"], []),
    ("return redis.call('ZSCORE', KEYS[1], 'b')", ["zset"], []),
    ("return redis.call('HGETALL', KEYS[1])", ["hash"], []),
    ("return redis.call('HGETALL', KEYS[1])", ["none"], []),
    ("return redis.call('SMEMBERS', KEYS[1])", ["iset"], []),
    ("return redis.call('MGET', KEYS[1], KEYS[2], KEYS[3])", ["str", "none", "num"], []),
    ("return redis.call('TYPE', KEYS[1])", ["hash"], []),
    ("return redis.call('PING')", [], []),
    ("return redis.call('PING', ARGV[1])", [], [b"echo\x00"]),
    ("return redis.call('EXISTS', KEYS[1], KEYS[2], KEYS[1])", ["str", "none"], []),
    ("return redis.call('LPOP', KEYS[1], 2)", ["none"], []),
    ("return {redis.call('LPOP', KEYS[1], 2), redis.call('LLEN', KEYS[1])}", ["list"], []),
    ("return redis.call('SCAN', 0, 'MATCH', 'nomatch*', 'COUNT', 1000)", [], []),
    ("return redis.call('INCRBYFLOAT', KEYS[1], '0.5')", ["num"], []),
    ("return redis.call('SCRIPT', 'HELP')", [], []),
    ("return redis.call('DEL', KEYS[1], KEYS[2])", ["low", "none"], []),
    ("return redis.pcall('GET', KEYS[1])", ["str"], []),
    # the blocking commands that a script may call do not wait
    ("return redis.call('BLMPOP', 0, 1, KEYS[1], 'LEFT')", ["none"], []),
    ("return redis.call('BZMPOP', 0, 1, KEYS[1], 'MIN')", ["none"], []),
    ("return redis.call('BLMPOP', 0, 1, KEYS[1], 'RIGHT', 'COUNT', 5)", ["list"], []),
    ("return redis.call('BZMPOP', 0, 1, KEYS[1], 'MAX')", ["zset"], []),
    ("return redis.call('BLMPOP', 'x', 1, KEYS[1], 'LEFT')", ["none"], []),
    # XREAD's BLOCK, which a script may not use (its name as the script wrote it)
    ("return redis.call('XREAD', 'BLOCK', 0, 'STREAMS', KEYS[1], '0')", ["none"], []),
    ("return redis.pcall('XREAD', 'COUNT', 1, 'BLOCK', 100, 'STREAMS', KEYS[1], KEYS[2], '0', '$')", ["none", "str"], []),
    ("return redis.pcall('xread', 'count', 2, 'block', -1, 'streams', KEYS[1])", ["none"], []),
    ("return redis.pcall('XREAD', 'COUNT', 'x', 'BLOCK', 0, 'STREAMS', KEYS[1], '0')", ["none"], []),
    ("return redis.pcall('XREAD', 'STREAMS', KEYS[1], 'BLOCK', '0', '0')", ["none"], []),
    ("return redis.pcall('XREAD', 'NOACK', 'BLOCK', 0, 'STREAMS', KEYS[1], '0')", ["none"], []),
    # errors of commands, raised by call, returned by pcall
    ("return redis.call('LPUSH', KEYS[1], 'x')", ["str"], []),
    ("return redis.pcall('LPUSH', KEYS[1], 'x')", ["str"], []),
    ("local e = redis.pcall('LPUSH', KEYS[1], 'x') return {type(e), e.err}", ["str"], []),
    ("return {redis.pcall('INCR', KEYS[1])}", ["str"], []),
    ("return redis.call('NOSUCH', 'x')", [], []),
    ("return redis.pcall('NOSUCH')", [], []),
    ("return redis.call('GET')", [], []),
    ("return redis.call('GET', KEYS[1], 'extra')", ["str"], []),
    ("return redis.pcall('SET', KEYS[1])", ["str"], []),
    ("return redis.call()", [], []),
    ("return redis.pcall()", [], []),
    ("return redis.call('SET', KEYS[1], {})", ["str"], []),
    ("return redis.call('SET', KEYS[1], true)", ["str"], []),
    ("return redis.call('SET', KEYS[1], nil)", ["str"], []),
    ("return redis.pcall('SET', KEYS[1], false)", ["str"], []),
    ("return redis.call({})", [], []),
    ("return redis.call('SET', KEYS[1], 'v', 'EX', 0)", ["str"], []),
    ("return redis.call('SET', KEYS[1], 'v', 'XX', 'NX')", ["str"], []),
    # numbers as arguments: %.17g (and -0, inf, nan made at run time)
    ("local out = {} for i, v in ipairs({3.14, 0.1, 1/3, 100, -7, 2^63, 1e100, 1e-300, 5e-324, 2^53 + 1}) do "
     "redis.call('SET', KEYS[1], v) out[i] = redis.call('GET', KEYS[1]) end return out", ["n"], []),
    ("local z = tonumber(ARGV[1]) local out = {} for i, v in ipairs({-z, 1/z, -1/z, z/z}) do "
     "redis.call('SET', KEYS[1], v) out[i] = redis.call('GET', KEYS[1]) end return out", ["n"], ["0"]),
    ("return redis.call('INCRBY', KEYS[1], 2.5)", ["int"], []),
    ("return redis.call('INCRBY', KEYS[1], 2.0)", ["int"], []),
    ("return redis.call('EXPIRE', KEYS[1], 100.0)", ["str"], []),
    ("return redis.call('LRANGE', KEYS[1], 0.0, -1.0)", ["flist"], []),
    # Lua's pcall: the message of redis.call's error, not its table
    ("local ok, err = pcall(redis.call, 'NOSUCH') return {tostring(ok), err}", [], []),
    ("local ok, err = pcall(redis.call, 'LPUSH', KEYS[1], 'x') return {tostring(ok), err}", ["str"], []),
    ("local ok, err = pcall(function() return redis.call('INCR', KEYS[1]) end) return {tostring(ok), err}", ["str"], []),
    ("local ok, v = pcall(redis.call, 'GET', KEYS[1]) return {tostring(ok), v}", ["str"], []),
    ("return {pcall(redis.call, 'GET', KEYS[1])}", ["str"], []),
    ("local ok, err = pcall(error, 'plain') return {tostring(ok), err}", [], []),
    ("local ok, err = pcall(function() error({err='CODE inside'}) end) return {tostring(ok), err}", [], []),
    ("local ok, err = pcall(function() error({err='CODE inside'}) end) return {tostring(ok), type(err)}", [], []),
    ("return {xpcall(function() return redis.call('NOSUCH') end, function(e) return type(e) end)}", [], []),
    ("return {xpcall(function() return redis.call('NOSUCH') end, function(e) return e.err end)}", [], []),
    # the commands a script may not call, and the blocking ones, which run
    # as in MULTI, without waiting
    ("return redis.call('EVAL', 'return 1', 0)", [], []),
    ("return redis.pcall('EVAL', 'return 1', 0)", [], []),
    ("return redis.call('EVALSHA', ARGV[1], 0)", [], [sha("return 1")]),
    ("return redis.call('MULTI')", [], []),
    ("return redis.call('EXEC')", [], []),
    ("return redis.call('DISCARD')", [], []),
    ("return redis.call('WATCH', KEYS[1])", ["str"], []),
    ("return redis.call('SUBSCRIBE', 'ch')", [], []),
    ("return redis.call('PSUBSCRIBE', 'ch*')", [], []),
    ("return redis.call('BLPOP', KEYS[1], 0)", ["none"], []),
    ("return redis.call('BLPOP', KEYS[1], 0)", ["list"], []),
    ("return redis.call('BRPOPLPUSH', KEYS[1], KEYS[2], 0)", ["none", "dst"], []),
    ("return redis.call('BZPOPMIN', KEYS[1], 0)", ["none"], []),
    ("return redis.call('SCRIPT', 'LOAD', 'return 1')", [], []),
    ("return redis.call('SCRIPT', 'FLUSH')", [], []),
    ("return redis.call('CLIENT', 'ID')", [], []),
    ("return redis.call('CONFIG', 'GET', 'maxmemory')", [], []),
    ("return redis.call('AUTH', 'pw')", [], []),
    ("return redis.call('HELLO')", [], []),
    ("return redis.call('QUIT')", [], []),
    ("return redis.call('RESET')", [], []),
    ("return redis.call('MONITOR')", [], []),
    ("return redis.call('WAIT', 0, 0)", [], []),
]


def calls(port, log):
    r = fresh(port, log, "2")
    log("2 keys", r.cmd("SET", k("str"), "v"), r.cmd("SET", k("num"), "10"), r.cmd("RPUSH", k("list"), "a", "b", "c", "d"),
        r.cmd("HSET", k("hash"), "f1", "v1", "f2", "v2"), r.cmd("ZADD", k("zset"), "1", "a", "2.5", "b", "-3", "c"),
        r.cmd("SADD", k("iset"), "3", "1", "2"), r.cmd("RPUSH", k("flist"), "x", "y"))
    c = Client(port)
    for body, keys, args in CALLS:
        log("2 call", body, keys, ev(c, body, [k(x) for x in keys], args))
    log("2 left", r.cmd("GET", k("str")), r.cmd("GET", k("num")), r.cmd("LRANGE", k("list"), "0", "-1"),
        r.cmd("GET", k("n")), r.cmd("GET", k("int")), r.cmd("ZRANGE", k("zset"), "0", "-1", "WITHSCORES"),
        r.cmd("PERSIST", k("str")))
    # SELECT in a script: the script's database, not the caller's
    sel = "redis.call('SELECT', 5) redis.call('SET', KEYS[1], 'in 5') return redis.call('GET', KEYS[1])"
    log("2 select", ev(c, sel, [k("sel")]), c.cmd("GET", k("sel")), ev(c, "return redis.call('GET', KEYS[1])", [k("sel")]),
        c.cmd("SELECT", "5"), c.cmd("GET", k("sel")), ev(c, "return redis.call('GET', KEYS[1])", [k("sel")]),
        c.cmd("SELECT", "9"))
    log("2 select fails", ev(c, "redis.call('SELECT', 3) error('after select')"),
        ev(c, "return redis.call('GET', KEYS[1])", [k("str")]), ev(c, "return redis.call('SELECT', 99)"),
        ev(c, "return redis.pcall('SELECT', 'x')"), ev(c, "redis.call('SELECT', '0') return redis.call('SELECT', 9)"),
        c.cmd("GET", k("str")))
    # SORT of a set by a constant from a script: sorted with ALPHA, as
    # Redis sorts it then (a list keeps its order)
    sset = [k("sset")]
    log("2 sort keys", r.cmd("SADD", k("sset"), "pear", "apple", "fig", "10", "2", "banana"))
    log("2 sort", ev(c, "return redis.call('SORT', KEYS[1], 'BY', 'nosort')", sset),
        ev(c, "return redis.call('SORT', KEYS[1], 'BY', 'nosort', 'DESC', 'LIMIT', '1', '3')", sset),
        ev(c, "return redis.call('SORT_RO', KEYS[1], 'BY', 'nosort', 'ALPHA')", sset),
        ev(c, "return redis.call('SORT', KEYS[1], 'BY', 'nosort', 'GET', '#')", sset),
        ev(c, "return redis.call('SORT', KEYS[1], 'BY', 'nosort')", [k("list")]))
    c.close()
    r.close()


# 3. errors as the caller gets them, with the script's sha and line
ERRORS = [
    # at run time
    "return 1 + nil", "local t = nil\nreturn t.x", "local t = {} return t.foo()",
    "local function f() return nil .. 'x' end\nreturn f()", "local a = 1\nlocal b = 2\nreturn a + nil",
    "return string.rep()", "local t = {3, 'a'} table.sort(t) return t", "local function f() return f() + 1 end return f()",
    "\n\n\nreturn redis.call('LPUSH', KEYS[1], 'x')", "redis.call('SET', KEYS[2], 'x')\nredis.call('NOSUCH')",
    # in compiling
    "return (", "x = = 1", "return 'unterminated", "end", "local a = 1\nlocal b = 2\nreturn a +", "return 1\0",
    "return 1\0 + +", b"\xff",
    # globals: not there, and read only
    "return undefined_var", "undefined_function()", "return redis.nosuch", "return type(os)", "return type(debug)",
    "x = 5", "_G.x = 1", "rawset(_G, 'x', 1)", "setmetatable(_G, nil)", "redis.call = nil", "string.foo = 'x'",
    "local x = 5 return x", "KEYS[1] = 'changed' return KEYS[1]",
    # error() with a table (one with an 'err' field: error({}) crashes Redis)
    "error({err='MYERR custom message'})", "error({err='ERR plain'})", "error({err='nocode'})", "error({err=42})",
    "error({err='X', source='mine', line=99})", "error(redis.error_reply('MY err'))",
    "error(redis.error_reply('no code'))",
    # a CR or an LF in an error's text: a space each, the last ones cut
    "error('a\\r\\nb')", "return redis.error_reply('x\\r\\ny')", "return {err='p\\nq'}",
    "error({err='t\\r\\nu'})", "return {err='ERR z\\r\\n'}",
    # error() with a string, at levels, and with what is not a string
    "error('boom')", "error('boom', 0)", "error('boom', 2)", "local function f() error('deep', 2) end\nf()",
    "error(42)", "error(1.5)", "error(true)", "error()", "error(nil)", "local ok, e = pcall(error, 'x') error(e)",
    "assert(false, 'assertion text')", "assert(false)", "assert(nil, 42)", "assert(1 == 1, 'fine') return 'ok'",
]


def errors(port, log):
    r = fresh(port, log, "3")
    log("3 keys", r.cmd("SET", k("str"), "v"))
    c = Client(port)
    for body in ERRORS:
        log("3 error", body, ev(c, body, [k("str"), k("other")]))
    log("3 after", r.cmd("GET", k("str")), r.cmd("GET", k("other")))
    c.close()
    r.close()


SHEBANGS = [
    ("#!lua flags=no-writes\nreturn redis.call('SET', KEYS[1], 'x')", "EVAL"),
    ("#!lua flags=no-writes\nreturn redis.pcall('SET', KEYS[1], 'x')", "EVAL"),
    ("#!lua flags=no-writes\nreturn redis.call('INCR', KEYS[1])", "EVAL"),
    ("#!lua flags=no-writes\nreturn redis.call('GET', KEYS[1])", "EVAL"),
    ("#!lua flags=no-writes\nreturn redis.call('GET', KEYS[1])", "EVAL_RO"),
    ("#!lua\nreturn redis.call('SET', KEYS[1], 'shebang')", "EVAL"),
    ("#!lua\nreturn redis.call('GET', KEYS[1])", "EVAL"),
    ("#!lua\nreturn redis.call('GET', KEYS[1])", "EVAL_RO"),
    ("#!lua flags=no-writes,allow-oom\nreturn 1", "EVAL"),
    ("#!lua flags=allow-stale,no-cluster,allow-cross-slot-keys\nreturn 2", "EVAL"),
    ("#!lua flags=\nreturn 3", "EVAL"),
    ("#!lua\nerror('on line two')", "EVAL"),
    ("#!lua\n\nreturn x_undefined", "EVAL"),
    ("#!lua flags=no-writes\nreturn 4", "EVAL_RO"),
    ("#!lua flags=bogus\nreturn 1", "EVAL"),
    ("#!lua flags=no-writes,bogus\nreturn 1", "EVAL"),
    ("#!lua flags=NO-WRITES\nreturn 1", "EVAL"),
    ("#!lua flags=bogus\nreturn 1", "EVAL_RO"),
    ("#!python\nreturn 1", "EVAL"),
    ("#!LUA\nreturn 1", "EVAL"),
    ("#!lua foo=bar\nreturn 1", "EVAL"),
    ("#!lua name=mylib\nreturn 1", "EVAL"),
    ("#!lua", "EVAL"),
    ("#!\nreturn 1", "EVAL"),
    ("#! lua\nreturn 1", "EVAL"),
    ("#!lua \"unterminated\nreturn 1", "EVAL"),
    (" #!lua\nreturn 1", "EVAL"),
]


def cache(port, log):
    fresh(port, log, "4").close()
    a = Client(port)
    s1, s2, s3 = "return 'one'", "return redis.call('GET', KEYS[1])", "return 'three'"
    log("4 load", a.cmd("SCRIPT", "LOAD", s1), a.cmd("SCRIPT", "LOAD", s1), a.cmd("SCRIPT", "LOAD", s2),
        a.cmd("SET", k("x"), "x value"))
    log("4 evalsha", a.cmd("EVALSHA", sha(s1), "0"), a.cmd("EVALSHA", sha(s1).upper(), "0"),
        a.cmd("EVALSHA", sha(s2), "1", k("x")), a.cmd("evalsha", sha(s2), "1", k("none")))
    log("4 exists", a.cmd("SCRIPT", "EXISTS", sha(s1), sha(s1).upper(), "f" * 40, sha(s2), "", "abc", sha(s1) + "0"))
    log("4 noscript", a.cmd("EVALSHA", "f" * 40, "0"), a.cmd("EVALSHA", "abc", "0"), a.cmd("EVALSHA", sha(s1)[:39], "0"),
        a.cmd("EVALSHA", sha(s1) + "0", "0"), a.cmd("EVALSHA", "", "0"), a.cmd("EVALSHA", "abc", "-1"))
    # EVAL caches its script; one that does not compile is not cached
    log("4 eval caches", a.cmd("SCRIPT", "EXISTS", sha(s3)), ev(a, s3), a.cmd("SCRIPT", "EXISTS", sha(s3)),
        a.cmd("EVALSHA", sha(s3), "0"))
    log("4 not compiled", ev(a, "return ("), a.cmd("SCRIPT", "EXISTS", sha("return (")),
        a.cmd("SCRIPT", "LOAD", "return ("), a.cmd("EVALSHA", sha("return ("), "0"),
        a.cmd("SCRIPT", "LOAD", "#!lua flags=bogus\nreturn 1"), a.cmd("SCRIPT", "EXISTS", sha("#!lua flags=bogus\nreturn 1")))
    log("4 binary", a.cmd("SCRIPT", "LOAD", b"return '\xff\x00'"), a.cmd("EVALSHA", sha(b"return '\xff\x00'"), "0"))
    # the cache is the server's: another client finds it, after the first is gone
    b = Client(port)
    log("4 other client", b.cmd("EVALSHA", sha(s1), "0"), b.cmd("SCRIPT", "EXISTS", sha(s1), sha(s3)))
    a.close()
    c = Client(port)
    log("4 after close", c.cmd("EVALSHA", sha(s2), "1", k("x")), c.cmd("SCRIPT", "EXISTS", sha(s1), sha(s2), sha(s3)))
    # SCRIPT FLUSH and its options
    log("4 flush sync", c.cmd("SCRIPT", "FLUSH", "SYNC"), c.cmd("SCRIPT", "EXISTS", sha(s1), sha(s2), sha(s3)),
        b.cmd("EVALSHA", sha(s1), "0"))
    log("4 flush async", c.cmd("SCRIPT", "LOAD", s1), c.cmd("SCRIPT", "FLUSH", "ASYNC"), c.cmd("SCRIPT", "EXISTS", sha(s1)))
    log("4 flush", c.cmd("SCRIPT", "LOAD", s1), c.cmd("SCRIPT", "FLUSH"), c.cmd("SCRIPT", "EXISTS", sha(s1)),
        c.cmd("SCRIPT", "flush", "async"), c.cmd("script", "Flush", "Sync"))
    log("4 flush bad", c.cmd("SCRIPT", "FLUSH", "bad"), c.cmd("SCRIPT", "FLUSH", "SYNC", "ASYNC"),
        c.cmd("SCRIPT", "FLUSH", ""))
    # SCRIPT's other subcommands, and its errors
    for args in (["HELP"], ["help"], ["HELP", "x"], ["KILL"], ["kill"], ["KILL", "x"], ["EXISTS"], ["LOAD"],
                 ["LOAD", "a", "b"], ["FOO"], ["FOO", "bar"], []):
        log("4 script", args, c.cmd("SCRIPT", *args))
    # read-only scripts: EVAL_RO and EVALSHA_RO refuse writes
    w, rd = "return redis.call('SET', KEYS[1], ARGV[1])", "return redis.call('GET', KEYS[1])"
    log("4 eval_ro", ev(c, w, [k("ro")], ["x"], "EVAL_RO"), ev(c, rd, [k("ro")], [], "EVAL_RO"),
        ev(c, "return redis.pcall('SET', KEYS[1], 'x')", [k("ro")], [], "EVAL_RO"),
        ev(c, "return redis.call('DEL', KEYS[1])", [k("ro")], [], "EVAL_RO"),
        ev(c, "return redis.call('PUBLISH', 'ch', 'm')", [], [], "EVAL_RO"),
        ev(c, "return redis.call('PING')", [], [], "EVAL_RO"), c.cmd("EXISTS", k("ro")))
    log("4 evalsha_ro", c.cmd("SCRIPT", "LOAD", w), c.cmd("SCRIPT", "LOAD", rd),
        c.cmd("EVALSHA_RO", sha(w), "1", k("ro"), "y"), c.cmd("EVALSHA_RO", sha(rd), "1", k("ro")),
        c.cmd("EVALSHA", sha(w), "1", k("ro"), "z"), c.cmd("EVALSHA_RO", sha(rd), "1", k("ro")),
        c.cmd("EVALSHA_RO", sha(rd).upper(), "1", k("ro")), c.cmd("EVALSHA_RO", "f" * 40, "0"))
    # the shebang: its flags, and bad ones
    for body, name in SHEBANGS:
        log("4 shebang", name, body, ev(c, body, [k("sb")], [], name))
    nw = "#!lua flags=no-writes\nreturn redis.call('GET', KEYS[1])"
    log("4 shebang loaded", c.cmd("SCRIPT", "LOAD", nw), c.cmd("EVALSHA_RO", sha(nw), "1", k("sb")),
        c.cmd("SCRIPT", "LOAD", "#!lua\nreturn 5"), c.cmd("EVALSHA_RO", sha("#!lua\nreturn 5"), "0"),
        c.cmd("EVALSHA", sha("#!lua\nreturn 5"), "0"))
    b.close()
    c.close()


# 5. the libraries, and redis.* (script, its arguments)
LIBS = [
    ("return {type(cjson), type(cmsgpack), type(bit), type(struct), type(loadstring), type(coroutine), "
     "type(newproxy), _VERSION}", []),
    # cjson
    ("return cjson.encode({1, 2, 'three', {a=1}, true, false})", []),
    ("return cjson.encode({a=1, b='x', c={1, 2}, d={e=false}})", []),
    ("return cjson.encode({1/3, 1e300, -0.5, 100, 2^53})", []),
    ("return cjson.encode('a\"b\\\\c\\n\\0d\\1')", []),
    ("return {cjson.encode({}), cjson.encode(cjson.null), cjson.encode({[1]=1, [5]=5})}", []),
    ("return cjson.encode({[1]=1, [20]=5})", []),
    ("return cjson.encode(function() end)", []),
    ("return cjson.encode(0/0)", []),
    ("local t = {} local c = t for i = 1, 1100 do c[1] = {} c = c[1] end return cjson.encode(t)", []),
    ("local t = cjson.decode(ARGV[1]) return {t.a[1], t.a[2], t.a[3].b == cjson.null, t.s, tostring(t.f), type(t.n)}",
     [b'{"a":[1,2,{"b":null}],"s":"str\\u00e9\\n","f":1.25,"n":null}']),
    ("return cjson.decode(ARGV[1])", [b'[1,2,3,"x",true,false]']),
    ("return tostring(cjson.decode(ARGV[1]))", [b"123456789012345678901"]),
    ("return cjson.decode(ARGV[1])", [b"1e400"]),
    ("return cjson.encode(cjson.decode(ARGV[1]))", [b' { "k" : [ 1 , 2.5e1 , "\\t" ] } ']),
    ("return cjson.decode(ARGV[1])", [b"{bad"]),
    ("return cjson.decode(ARGV[1])", [b"[1,2"]),
    ("return cjson.decode(ARGV[1])", [b""]),
    ("return cjson.decode(ARGV[1])", [b"[1] x"]),
    ("return cjson.decode(ARGV[1])", [b'"\\uD800"']),
    ("return cjson.decode(ARGV[1])", [b"[" * 2000]),
    ("local ok, e = pcall(cjson.decode, ARGV[1]) return {tostring(ok), e}", [b"{bad"]),
    # cmsgpack
    ("return cmsgpack.pack({1, 2, 3})", []),
    ("return cmsgpack.pack(1.5, -1, 'str', true, {a=1}, 2^40, -2^40, 300, -300, 0.1)", []),
    ("return cmsgpack.pack({a=1, b=2, c={x=1}})", []),
    ("return {cmsgpack.unpack(ARGV[1])}", [b"\x93\x01\x02\x03"]),
    ("local t = {cmsgpack.unpack(cmsgpack.pack(1.5, 'x', {7, 8}, 12345678901))} "
     "return {tostring(t[1]), t[2], t[3], tostring(t[4])}", []),
    ("return {cmsgpack.unpack_one(cmsgpack.pack(1, 2))}", []),
    ("return {cmsgpack.unpack_limit(cmsgpack.pack(1, 2, 3), 2)}", []),
    ("return {cmsgpack.unpack(ARGV[1])}", [b"\xc1"]),
    ("return {cmsgpack.unpack(ARGV[1])}", [b"\x93\x01"]),
    ("return cmsgpack.unpack()", []),
    ("return cmsgpack.pack()", []),
    # bit
    ("return {bit.band(0xff, 0x0f), bit.bor(1, 2, 4), bit.bxor(5, 3), bit.bnot(0), bit.lshift(1, 40), "
     "bit.rshift(-1, 28), bit.arshift(-256, 4), bit.tobit(2^32 + 1), bit.tohex(65535), bit.tohex(-1, 4), "
     "bit.rol(1, 33), bit.ror(1, 1), bit.bswap(0x12345678)}", []),
    ("return bit.band()", []),
    # the smallest width, which C cannot negate: the reference's 7.0.15
    # carries the fix of CVE-2024-31449 (and its test in scripting.tcl); the
    # vendored Lua without it answered 8 bytes of its stack
    ("return {bit.tohex(65535, -2147483648), bit.tohex(-1, -2147483647), bit.tohex(255, -3), bit.tohex(1, 0)}", []),
    # struct
    ("return {struct.pack('>I2', 258), struct.pack('<i4', -2), struct.pack('>d', 1.5), struct.size('>I4i2'), "
     "struct.pack('s', 'ab'), struct.pack('>Bc0', 3, 'xyz'), struct.pack('!')}", []),
    ("return {struct.unpack('>I2', ARGV[1])}", [b"\x01\x02"]),
    ("return {struct.unpack('<i4i2', struct.pack('<i4i2', -7, 300))}", []),
    ("return struct.pack('>q', 1)", []),
    ("return struct.unpack('>I4', 'ab')", []),
    # numbers past an integer's range, converted as Redis's x86-64 builds
    # (gcc) convert them; clang's code gave other bytes from 2^64
    ("return {struct.pack('>L', 2^70), struct.pack('<I8', 2^64), struct.pack('>l', 2^65), "
     "struct.pack('>l', -2^70), struct.pack('<i8', 2^63), struct.pack('>T', 1/0), struct.pack('>L', 0/0)}", []),
    ("return {string.format('%x|%o|%u|%X', 2^65, 2^64, 2^64, 1/0), string.format('%x|%u', -1, -2^70), "
     "string.format('%d|%i', 2^70, 0/0), string.format('%5.2x', 2^66), string.format('%c', 2^40)}", []),
    ("return {cjson.encode({[2^40]=1}), cjson.encode({[3e9]='a', [1]='b'}), cmsgpack.pack(1e30, -1e30, 2^63, 0/0), "
     "cmsgpack.pack({[2^40]=1})}", []),
    # string, table, math and tostring (%.14g)
    ("return {string.format('%5.2f|%d|%s|%q|%x|%g|%e|%05d|%-4s|', 3.14159, 42, 'hi', 'a\\nb\\0', 255, 1e20, "
     "12345.678, -42, 'ab'), string.format('%c%c', 72, 105), string.format('%q', '\\r\\0\\255'), "
     "string.format('%5s|%-5d|%+.3e', 'ab', 7, 12345.6789), string.format('%%'), string.format('%o %X %i', 8, 255, -3), "
     "string.format('%.20f', 0.1), string.format('%g', 1e-5), string.format('%.3g', 2/3)}", []),
    ("return string.format('%d', 'x')", []),
    ("return string.format('%s %s', 1)", []),
    ("return {string.rep('ab', 3), string.sub('hello', 2, -2), string.upper('abc'), string.byte('A'), "
     "string.char(66, 67), string.len('\\0\\0'), string.find('hello', 'l+'), string.gsub('hello', 'l', 'L'), "
     "string.match('key:42', '(%a+):(%d+)'), string.reverse('abc'), ('x'):rep(2)}", []),
    ("local t = {5, 3, 9, 1, 7} table.sort(t) local u = {'b', 'a', 'C', 'c', ''} table.sort(u) "
     "local w = {3, 1, 2} table.sort(w, function(a, b) return a > b end) "
     "local v = {} table.insert(v, 'x') table.insert(v, 1, 'y') table.remove(v) "
     "return {t, u, w, table.concat(t, ','), #t, v, table.getn(t), table.maxn({1, 2, [10]=3})}", []),
    ("return {tostring(1/3), tostring(1e300), tostring(-0), tostring(2^53), tostring(0.1), tostring(100), "
     "tostring(1e15), tostring(1e16), tostring(-1.5e-7), tostring(2^63), tostring(123456789012345), "
     "tostring(math.pi), tostring(math.huge), tostring(-math.huge), 1e15 .. '', 0.1 + 0.2 .. ''}", []),
    ("return {tonumber('0x10'), tonumber('  12  '), tonumber('1e2'), tostring(tonumber('abc')), tonumber('10', 2), "
     "tonumber('zz', 36), tostring(tonumber(''))}", []),
    ("return {math.floor(3.7), math.ceil(-3.7), math.max(1, 5, 3), math.min(2, -1), math.fmod(7, 3), math.abs(-2), "
     "tostring(math.sqrt(2)), tostring(math.exp(1)), tostring(math.log(10)), tostring(math.sin(1)), "
     "math.modf(5.25), tostring(select(2, math.modf(5.25))), math.pow(2, 10), tostring(math.frexp(8))}", []),
    ("return {select('#', 1, nil, 3), unpack({1, 2, 3})}", []),
    ("return coroutine.wrap(function() coroutine.yield(5) end)()", []),
    ("return loadstring('return 1 + 1')()", []),
    ("return {loadstring('return 1 +')}", []),
    ("local t = setmetatable({}, {__index = function(t, k) return k .. '!' end}) return t.x", []),
    # math.random: Redis's own generator, seeded by a script, whose
    # sequence goes on in the next script (the server's, not the script's)
    ("math.randomseed(42) local r = {} for i = 1, 5 do r[i] = tostring(math.random()) end "
     "r[6] = math.random(100) r[7] = math.random(5, 9) return r", []),
    ("return tostring(math.random())", []),
    ("math.randomseed(-7) return {math.random(1000000), math.random(1000000), math.random(10, 20)}", []),
    ("math.randomseed(42) return tostring(math.random())", []),
    ("math.randomseed(0) local r = {} for i = 1, 3 do r[i] = math.random(1, 2^31 - 1) end return r", []),
    ("return math.random(0)", []),
    ("return math.random(5, 1)", []),
    ("return math.random(1, 2, 3)", []),
    ("math.randomseed() return 1", []),
    # redis.sha1hex, the version, redis.log
    ("return {redis.sha1hex(''), redis.sha1hex('abc'), redis.sha1hex(123), redis.sha1hex(ARGV[1])}", [b"\x00\xff"]),
    ("return redis.sha1hex()", []),
    ("return redis.sha1hex('a', 'b')", []),
    ("return {redis.REDIS_VERSION, redis.REDIS_VERSION_NUM, type(redis.REDIS_VERSION_NUM)}", []),
    ("return redis.log(redis.LOG_NOTICE, 'script_test: a line from a script', 42)", []),
    ("return redis.log(redis.LOG_DEBUG, 'script_test: a line not written')", []),
    ("return {redis.LOG_DEBUG, redis.LOG_VERBOSE, redis.LOG_NOTICE, redis.LOG_WARNING}", []),
    ("return redis.log()", []),
    ("return redis.log(redis.LOG_NOTICE)", []),
    ("return redis.log('x', 'y')", []),
    ("return redis.log(99, 'y')", []),
    ("return redis.log(2^40, 'y')", []),
    ("return {redis.REPL_NONE, redis.REPL_AOF, redis.REPL_REPLICA, redis.REPL_SLAVE, redis.REPL_ALL}", []),
    ("redis.set_repl(redis.REPL_ALL) return redis.call('SET', KEYS[1], 'repl')", []),
    ("return redis.set_repl(99)", []),
    ("return redis.set_repl(2^40)", []),
    ("return redis.set_repl()", []),
    ("return redis.replicate_commands()", []),
]

# redis.setresp(3): what commands reply in RESP3, as Lua values, then
# back to the caller in its protocol; each script starts in RESP2
SETRESP = [
    "redis.setresp(3) return redis.call('HGETALL', KEYS[1])",
    "redis.setresp(3) return redis.call('HGETALL', KEYS[4])",
    "redis.setresp(3) return redis.call('ZRANGE', KEYS[2], 0, -1, 'WITHSCORES')",
    "redis.setresp(3) return redis.call('ZSCORE', KEYS[2], 'b')",
    "redis.setresp(3) local d = redis.call('ZSCORE', KEYS[2], 'b') return {type(d), tostring(d.double)}",
    "redis.setresp(3) return redis.call('ZINCRBY', KEYS[2], 0.25, 'a')",
    "redis.setresp(3) return redis.call('SMEMBERS', KEYS[3])",
    "redis.setresp(3) return redis.call('GET', KEYS[4])",
    "redis.setresp(3) return {type(redis.call('GET', KEYS[4])), redis.call('GET', KEYS[4]) == nil}",
    "redis.setresp(3) return redis.call('LPOP', KEYS[4], 2)",
    "redis.setresp(3) return redis.call('MGET', KEYS[4], KEYS[1])",
    "redis.setresp(3) return redis.call('PING')",
    "redis.setresp(3) return true",
    "redis.setresp(3) return false",
    "redis.setresp(3) return nil",
    "redis.setresp(3) return {true, false, 1, 'x'}",
    "redis.setresp(3) return {double=2.5}",
    "redis.setresp(3) return {map={k='v'}}",
    "redis.setresp(3) return {set={m=true}}",
    "redis.setresp(3) return redis.pcall('NOSUCH')",
    "redis.setresp(3) redis.setresp(2) return redis.call('HGETALL', KEYS[1])",
    "redis.setresp(3) redis.setresp(2) return true",
    "return redis.call('HGETALL', KEYS[1])",
    "redis.setresp('3') return redis.call('ZSCORE', KEYS[2], 'b')",
    "redis.setresp(4)",
    "redis.setresp(2^40)",
    "redis.setresp(0/0)",
    "redis.setresp()",
]


def libraries(port, log):
    r = fresh(port, log, "5")
    log("5 keys", r.cmd("HSET", k("hash"), "f1", "v1", "f2", "v2", "f3", "3"),
        r.cmd("ZADD", k("zset"), "1.5", "a", "2", "b", "-0.25", "c"), r.cmd("SADD", k("iset"), "30", "10", "20"))
    c = Client(port)
    for body, args in LIBS:
        log("5 lib", body, ev(c, body, [k("repl")], args))
    c.close()
    for proto in ("2", "3"):
        c = Client(port, resp3=proto == "3")
        for body in SETRESP:
            log("5 setresp resp" + proto, body, ev(c, body, [k("hash"), k("zset"), k("iset"), k("none")]))
        c.close()
    r.close()


def transactions(port, log):
    r = fresh(port, log, "6")
    a, b = Client(port), Client(port)
    # scripts queued in MULTI, their replies in EXEC's array, errors among them
    s = "return 'in multi'"
    log("6 multi", a.cmd("MULTI"), ev(a, "return redis.call('INCR', KEYS[1])", [k("c")]), ev(a, "return {1, {2, 'x'}}"),
        ev(a, "return redis.call('NOSUCH')"), ev(a, "error('boom')"), a.cmd("EVAL", "return 1", "5"),
        a.cmd("EVALSHA", "f" * 40, "0"), a.cmd("SCRIPT", "LOAD", s), a.cmd("EVALSHA", sha(s), "0"),
        ev(a, "return redis.call('GET', KEYS[1])", [k("c")], [], "EVAL_RO"),
        ev(a, "return redis.call('SET', KEYS[1], 'x')", [k("c")], [], "EVAL_RO"), a.cmd("SET", k("k"), "v"), a.cmd("EXEC"))
    log("6 multi after", a.cmd("GET", k("c")), a.cmd("GET", k("k")), a.cmd("SCRIPT", "EXISTS", sha(s)))
    log("6 multi refused", a.cmd("MULTI"), a.cmd("EVAL", "return 1"), a.cmd("EVALSHA"), a.cmd("EXEC"))
    log("6 multi in script", a.cmd("MULTI"),
        ev(a, "redis.call('SET', KEYS[1], 'in tx') return redis.call('MULTI')", [k("k")]), a.cmd("GET", k("k")),
        a.cmd("EXEC"))
    log("6 multi select", a.cmd("MULTI"), ev(a, "redis.call('SELECT', 2) return redis.call('SET', KEYS[1], 'db2')", [k("m")]),
        a.cmd("GET", k("m")), a.cmd("SELECT", "2"), a.cmd("GET", k("m")), a.cmd("EXEC"), a.cmd("GET", k("m")),
        a.cmd("SELECT", "9"))
    # WATCH: a script that writes the key watched makes EXEC fail; one
    # that reads it, writes another key or fails to write it does not
    log("6 watch set", a.cmd("SET", k("w"), "1"), a.cmd("WATCH", k("w")),
        ev(b, "return redis.call('SET', KEYS[1], 'b')", [k("w")]), a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"))
    log("6 watch read", a.cmd("WATCH", k("w")), ev(b, "return redis.call('GET', KEYS[1])", [k("w")]), a.cmd("MULTI"),
        a.cmd("PING"), a.cmd("EXEC"))
    log("6 watch other key", a.cmd("WATCH", k("w")), ev(b, "return redis.call('SET', KEYS[1], 'x')", [k("other")]),
        a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"))
    log("6 watch failed write", a.cmd("WATCH", k("w")), ev(b, "return redis.pcall('INCR', KEYS[1])", [k("w")]),
        a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"))
    log("6 watch del none", a.cmd("WATCH", k("nokey")), ev(b, "return redis.call('DEL', KEYS[1])", [k("nokey")]),
        a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"))
    log("6 watch error after write", a.cmd("WATCH", k("w")),
        ev(b, "redis.call('SET', KEYS[1], 'c') error('after the write')", [k("w")]), a.cmd("MULTI"), a.cmd("PING"),
        a.cmd("EXEC"), a.cmd("GET", k("w")))
    log("6 watch expire", a.cmd("WATCH", k("w")), ev(b, "return redis.call('EXPIRE', KEYS[1], 1000)", [k("w")]),
        a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"))
    log("6 watch own script", a.cmd("WATCH", k("w")), ev(a, "return redis.call('SET', KEYS[1], 'self')", [k("w")]),
        a.cmd("MULTI"), a.cmd("PING"), a.cmd("EXEC"))
    log("6 watch script queued", a.cmd("WATCH", k("w")), a.cmd("MULTI"),
        ev(a, "return redis.call('SET', KEYS[1], 'queued')", [k("w")]), a.cmd("EXEC"), a.cmd("GET", k("w")))
    log("6 watch other db", a.cmd("WATCH", k("w")),
        ev(b, "redis.call('SELECT', 4) return redis.call('SET', KEYS[1], 'db4')", [k("w")]), a.cmd("MULTI"),
        a.cmd("PING"), a.cmd("EXEC"))
    # what a script wrote, as another client reads it
    body = ("redis.call('SET', KEYS[1], ARGV[1]) redis.call('RPUSH', KEYS[2], 'a', 'b') "
            "redis.call('HSET', KEYS[3], 'f', ARGV[1]) redis.call('SADD', KEYS[4], 3, 1, 2) "
            "redis.call('ZADD', KEYS[5], 1.5, 'm', -2, 'n') redis.call('INCRBY', KEYS[6], 7) "
            "redis.call('EXPIRE', KEYS[1], 1000) redis.call('DEL', KEYS[7]) return 'done'")
    keys = [k(x) for x in ("s", "l", "h", "set", "z", "n", "gone")]
    log("6 effects", r.cmd("SET", keys[6], "here"), ev(a, body, keys, [b"v\x00\xff"]))
    log("6 seen", b.cmd("GET", keys[0]), b.cmd("LRANGE", keys[1], "0", "-1"), b.cmd("HGETALL", keys[2]),
        b.cmd("SMEMBERS", keys[3]), b.cmd("ZRANGE", keys[4], "0", "-1", "WITHSCORES"), b.cmd("GET", keys[5]),
        b.cmd("EXISTS", keys[6]), [b.cmd("TYPE", x) for x in keys])
    ttl = b.cmd("TTL", keys[0])
    log("6 seen ttl", 990 <= int(ttl[1:-2]) <= 1000 if isinstance(ttl, bytes) and ttl[:1] == b":" else ttl)
    log("6 seen other db", b.cmd("SELECT", "4"), b.cmd("GET", k("w")), b.cmd("SELECT", "9"))
    # INFO's count of the scripts cached
    c = Client(port)

    def cached():
        return [x for x in info(c, "memory") if x.startswith("number_of_cached_scripts:")]

    log("6 cached", c.cmd("SCRIPT", "FLUSH"), cached(), c.cmd("SCRIPT", "LOAD", "return 'a'"), cached(),
        c.cmd("SCRIPT", "LOAD", "return 'a'"), cached(), c.cmd("SCRIPT", "LOAD", "return 'b'"), cached(),
        ev(c, "return 'c'"), cached(), ev(c, "return 'c'"), cached(), ev(c, "return ("), cached(),
        ev(c, "#!lua flags=bogus\nreturn 1"), cached(), c.cmd("EVALSHA", sha("return 'a'"), "0"), cached(),
        c.cmd("EVAL", "return 'd'", "1"), cached())
    log("6 cached flushed", c.cmd("SCRIPT", "FLUSH", "ASYNC"), cached(), ev(c, "return 'e'"), cached(),
        c.cmd("SCRIPT", "FLUSH", "SYNC"), cached(), c.cmd("SCRIPT", "LOAD", "return 'f'"), c.cmd("SCRIPT", "FLUSH"), cached())
    for x in (a, b, c, r):
        x.close()


def statistics(port, log):
    r = fresh(port, log, "7")
    log("7 keys", r.cmd("SET", k("str"), "v"), r.cmd("SCRIPT", "LOAD", "return 'loaded'"))
    c = Client(port)
    log("7 resetstat", r.cmd("CONFIG", "RESETSTAT"))
    for body, keys in (("return redis.call('SET', KEYS[1], 'x')", ["k"]),
                       ("return redis.call('GET', KEYS[1])", ["k"]),
                       ("return redis.call('LPUSH', KEYS[1], 'x')", ["str"]),
                       ("return redis.pcall('LPUSH', KEYS[1], 'x')", ["str"]),
                       ("local e = redis.pcall('LPUSH', KEYS[1], 'x') return 'caught'", ["str"]),
                       ("local ok = pcall(redis.call, 'INCR', KEYS[1]) return 'caught'", ["str"]),
                       ("return redis.call('NOSUCH')", []), ("return redis.pcall('GET')", []),
                       ("return redis.call('MULTI')", []), ("return redis.call('SET', KEYS[1], {})", ["k"]),
                       ("return redis.error_reply('MYERR my error')", []), ("return {err='OWN code'}", []),
                       ("error({err='CUSTOM table'})", []), ("error('boom')", []), ("return 1 + nil", []),
                       ("return (", []), ("#!lua flags=bogus\nreturn 1", []),
                       ("#!lua flags=no-writes\nreturn redis.call('SET', KEYS[1], 'x')", ["k"]),
                       ("return redis.call('INCR', KEYS[1])", ["n"]), ("return redis.call('SELECT', 99)", [])):
        log("7 eval", body, ev(c, body, [k(x) for x in keys]))
    for args in (["EVAL", "return 1", "5"], ["EVAL", "return 1", "x"], ["EVAL"], ["EVALSHA", sha("return 'loaded'"), "0"],
                 ["EVALSHA", "f" * 40, "0"], ["EVALSHA", "abc", "0"], ["EVALSHA"],
                 ["EVAL_RO", "return redis.call('SET', KEYS[1], 'x')", "1", k("k")],
                 ["EVAL_RO", "return redis.call('GET', KEYS[1])", "1", k("k")],
                 ["EVALSHA_RO", sha("return 'loaded'"), "0"], ["EVAL_RO", "#!lua\nreturn 1", "0"],
                 ["SCRIPT", "LOAD", "return 2"], ["SCRIPT", "LOAD", "return ("], ["SCRIPT", "EXISTS", "f" * 40],
                 ["SCRIPT", "FLUSH", "bad"], ["SCRIPT", "HELP"], ["SCRIPT", "KILL"], ["SCRIPT", "NOSUCH"],
                 ["SCRIPT", "LOAD"], ["SCRIPT"], ["SCRIPT", "FLUSH", "SYNC"]):
        log("7 command", args, c.cmd(*args))
    log("7 multi", c.cmd("MULTI"), ev(c, "return redis.call('INCR', KEYS[1])", [k("n")]),
        ev(c, "return redis.call('NOSUCH')"), c.cmd("EVAL", "return 1"), c.cmd("EXEC"))
    log("7 multi run", c.cmd("MULTI"), ev(c, "return redis.call('INCR', KEYS[1])", [k("n")]),
        ev(c, "return redis.call('LPUSH', KEYS[1], 'x')", [k("str")]), c.cmd("EXEC"))
    log("7 stats", *stats(r))
    c.close()
    r.close()


# the count of a loop that runs one to two seconds in Redis's Lua
LOOP = 100000000


def busy(port, log):
    r = fresh(port, log, "8")
    was = r.cmd("CONFIG", "GET", "lua-time-limit")
    try:
        log("8 time limit", r.cmd("CONFIG", "SET", "lua-time-limit", "100"), r.cmd("CONFIG", "GET", "lua-time-limit"),
            r.cmd("CONFIG", "GET", "busy-reply-threshold"))
        log("8 resetstat", r.cmd("CONFIG", "RESETSTAT"), r.cmd("SET", k("x"), "1"))
        a, b, q = Client(port), Client(port), Client(port)
        # a script that loops and writes nothing: answered BUSY, then killed
        a.send("EVAL", "while true do end", "0")
        time.sleep(0.1)
        first = b.cmd("PING")
        if first == "TIMEOUT":
            # a server that answers no one while a script loops: the rest
            # would only wait out its timeouts
            log("8 busy", first)
            return
        log("8 busy", first, b.cmd("GET", k("x")), b.cmd("SET", k("x"), "2"), b.cmd("EVAL", "return 1", "0"),
            b.cmd("SCRIPT", "LOAD", "return 1"), b.cmd("SCRIPT", "EXISTS", "f" * 40), b.cmd("INFO", "server"),
            b.cmd("CLIENT", "ID"), b.cmd("SELECT", "9"), b.cmd("NOSUCH"), b.cmd("GET"))
        n = Client(port, db=None)
        log("8 busy new client", n.cmd("PING"), n.cmd("SELECT", "9"))
        log("8 busy multi", b.cmd("MULTI"), b.cmd("SET", k("x"), "3"), b.cmd("EXEC"), b.cmd("MULTI"), b.cmd("DISCARD"),
            b.cmd("UNWATCH"), b.cmd("WATCH", k("x")), b.cmd("UNWATCH"))
        log("8 busy quit", q.cmd("QUIT"), q.read(0.5))
        kill, killed = b.cmd("SCRIPT", "KILL"), a.read()
        if killed == "TIMEOUT":
            # the script was not killed, and still runs
            log("8 kill", kill, killed)
            return
        log("8 kill", kill, killed, b.cmd("PING"), b.cmd("SCRIPT", "KILL"), a.cmd("PING"), b.cmd("GET", k("x")),
            n.cmd("PING"))
        # a script that catches errors as it loops cannot catch the kill
        a.send("EVAL", "while true do pcall(function() while true do end end) end", "0")
        time.sleep(0.1)
        log("8 kill in pcall", b.cmd("PING"), b.cmd("SCRIPT", "KILL"), a.read(), b.cmd("PING"))
        # a script that wrote first cannot be killed: its loop ends alone
        a.send("EVAL", "redis.call('SET', KEYS[1], 'written') local i = 0 while i < %d do i = i + 1 end return i" % LOOP,
               "1", k("w"))
        time.sleep(0.1)
        log("8 unkillable", b.cmd("PING"), b.cmd("SCRIPT", "KILL"), b.cmd("GET", k("w")), b.cmd("SCRIPT", "KILL"),
            b.cmd("MULTI"), b.cmd("DISCARD"))
        log("8 loop ends", a.read(120.0), b.cmd("GET", k("w")), b.cmd("SCRIPT", "KILL"), a.cmd("PING"))
        # another client's command run with the script's (a pause of
        # everything holds both, and both go on as it ends): its reply goes
        # out while the script runs, as Redis writes the replies of the
        # commands it ran before a script once the script is busy
        log("8 one group", r.cmd("CLIENT", "PAUSE", "300", "ALL"))
        b.send("PING")
        time.sleep(0.05)
        a.send("EVAL", "while true do end", "0")
        time.sleep(0.6)
        log("8 one group's reply", b.read(1.0), b.cmd("PING"), b.cmd("SCRIPT", "KILL"), a.read(), b.cmd("PING"))
        log("8 stats", *stats(r))
        for x in (a, b, n, q):
            x.close()
    finally:
        # the time limit the server had (Redis's default when it did not say)
        old = was.split(b"\r\n")[4] if isinstance(was, bytes) and was.startswith(b"*2\r\n") else b""
        r.cmd("CONFIG", "SET", "lua-time-limit", old if old.isdigit() else b"5000")
        r.close()


def parse(data, i=0):
    """a RESP2 reply's value (bytes, ints, lists) and where it ends"""
    j = data.index(b"\r\n", i)
    kind, head = data[i:i + 1], data[i + 1:j]
    if kind == b"$":
        n = int(head)
        return (None, j + 2) if n < 0 else (data[j + 2:j + 2 + n], j + 4 + n)
    if kind == b"*":
        out, at = [], j + 2
        for _ in range(max(int(head), 0)):
            v, at = parse(data, at)
            out.append(v)
        return out, at
    return (int(head) if kind == b":" else head), j + 2


def slowlog(c):
    """the slow log's entries, newest first: each one's arguments, and
    whether it took its threshold or more (its time is the server's)"""
    rep = c.cmd("SLOWLOG", "GET", "10")
    if not isinstance(rep, bytes) or rep[:1] != b"*":
        return [repr(rep)]
    return [(e[3], e[2] >= 50000) for e in parse(rep)[0]]


def latest(c):
    """the latency monitor's events (LATENCY LATEST), by name, each with
    whether its latest sample took the threshold or more"""
    rep = c.cmd("LATENCY", "LATEST")
    if not isinstance(rep, bytes) or rep[:1] != b"*":
        return [repr(rep)]
    return sorted((e[0], e[2] >= 50) for e in parse(rep)[0])


# the count of a loop that runs 0.1 to 0.3 s in Redis's Lua
SLOW = 15000000


def slow(port, log):
    r = fresh(port, log, "9")
    was = [r.cmd("CONFIG", "GET", x) for x in ("slowlog-log-slower-than", "latency-monitor-threshold")]
    try:
        log("9 thresholds", r.cmd("CONFIG", "SET", "slowlog-log-slower-than", "50000"),
            r.cmd("CONFIG", "SET", "latency-monitor-threshold", "50"), r.cmd("SLOWLOG", "RESET"),
            r.cmd("LATENCY", "RESET"))
        c = Client(port)
        body = "redis.call('SET', KEYS[1], 'v') local i = 0 while i < %d do i = i + 1 end return i" % SLOW
        # a slow script: in the slow log with its arguments, its call of
        # SET not (each call is timed on its own); then a slow script and
        # a GET in one pipeline, the GET not in it either
        log("9 slow script", ev(c, body, [k("s")]))
        log("9 slow log", slowlog(r), latest(r))
        log("9 reset", r.cmd("SLOWLOG", "RESET"), r.cmd("LATENCY", "RESET"))
        c.sock.sendall(enc(["EVAL", body, "1", k("s")]) + enc(["GET", k("s")]) + enc(["EVAL", "return 1", "0"]))
        log("9 pipeline", c.read(10.0), c.read(), c.read())
        log("9 slow log after the pipeline", slowlog(r))
        # a slow script in a transaction: in the slow log, EXEC not
        log("9 reset", r.cmd("SLOWLOG", "RESET"))
        log("9 multi", c.cmd("MULTI"), ev(c, body, [k("s")]), c.cmd("GET", k("s")), c.cmd("EXEC", timeout=10.0))
        log("9 slow log after EXEC", slowlog(r))
        c.close()
    finally:
        for name, rep in zip(("slowlog-log-slower-than", "latency-monitor-threshold"), was):
            old = rep.split(b"\r\n")[4] if isinstance(rep, bytes) and rep.startswith(b"*2\r\n") else b""
            r.cmd("CONFIG", "SET", name, old if old.lstrip(b"-").isdigit() else (b"10000" if name.startswith("slow") else b"0"))
        r.cmd("SLOWLOG", "RESET")
        r.cmd("LATENCY", "RESET")
        r.close()


def pipelines(port, log):
    r = fresh(port, log, "10")
    c = Client(port)
    # scripts among other commands in one pipeline: each reply in its place
    body = "return redis.call('INCR', KEYS[1])"
    c.sock.sendall(enc(["SET", k("p"), "1"]) + enc(["EVAL", body, "1", k("p")]) + enc(["GET", k("p")]) +
                   enc(["EVAL", body, "1", k("p")]) + enc(["EVAL", "return {1, 2}", "0"]) + enc(["PING"]) +
                   enc(["EVALSHA", sha(body), "1", k("p")]) + enc(["EVAL", "return (", "0"]) + enc(["GET", k("p")]))
    log("10 pipeline", *[c.read() for _ in range(9)])
    # a client with a subscription (RESP3), whose script publishes to its
    # own channel: the pushes and the replies in Redis's order
    s3 = Client(port, resp3=True)
    log("10 subscribe", s3.cmd("SUBSCRIBE", k("ch")))
    s3.sock.sendall(enc(["PUBLISH", k("ch"), "a"]) + enc(["EVAL", "redis.call('PUBLISH', KEYS[1], 'b') return 1", "1", k("ch")]) +
                    enc(["PUBLISH", k("ch"), "c"]) + enc(["EVAL", "return 2", "0"]))
    log("10 subscribed pipeline", *[s3.read() for _ in range(7)])
    for x in (c, s3):
        x.close()
    r.close()


def blocked(c, n):
    """INFO's blocked_clients once it is n (or after 2 s), as a number"""
    deadline = time.time() + 2.0
    while True:
        lines = [x for x in info(c, "clients") if x.startswith("blocked_clients:")]
        got = int(lines[0].split(":")[1]) if lines else -1
        if got == n or time.time() > deadline:
            return got
        time.sleep(0.02)


def paused(port, log):
    r = fresh(port, log, "11")
    a, b = Client(port), Client(port)
    try:
        body = "return redis.call('INCR', KEYS[1])"
        log("11 load", r.cmd("SCRIPT", "LOAD", body), r.cmd("CLIENT", "PAUSE", "100000", "WRITE"))
        # a script that declares no-writes, and EVAL_RO without a
        # shebang, run at once
        log("11 run at once", ev(a, "#!lua flags=no-writes\nreturn redis.call('GET', KEYS[1])", [k("sc")]),
            ev(a, "return redis.call('GET', KEYS[1])", [k("sc")], cmd="EVAL_RO"), a.cmd("SCRIPT", "EXISTS", sha(body)))
        # a script that may write is held back, then runs: EVAL without a
        # shebang, EVALSHA (by its script's flags)
        a.send("EVAL", body, "1", k("sc"))
        log("11 eval held", a.read(0.2), blocked(r, 1))
        b.send("EVALSHA", sha(body), "1", k("sc"))
        log("11 evalsha held", b.read(0.2), blocked(r, 2))
        log("11 unpause", r.cmd("CLIENT", "UNPAUSE"), a.read(), b.read(), blocked(r, 0), r.cmd("GET", k("sc")))
        # EVAL_RO whose shebang does not declare no-writes is held back
        r.cmd("CLIENT", "PAUSE", "100000", "WRITE")
        a.send("EVAL_RO", "#!lua\nreturn 1", "0")
        log("11 eval_ro held", a.read(0.2), blocked(r, 1))
        log("11 eval_ro", r.cmd("CLIENT", "UNPAUSE"), a.read())
        # a transaction of scripts that declare no-writes runs at once
        r.cmd("CLIENT", "PAUSE", "100000", "WRITE")
        log("11 multi of no-writes", a.cmd("MULTI"), ev(a, "#!lua flags=no-writes\nreturn 12"),
            ev(a, "#!lua flags=no-writes\nreturn 13"), a.cmd("EXEC"), blocked(r, 0))
        r.cmd("CLIENT", "UNPAUSE")
        # one that queued a script that may write before the pause has its
        # EXEC held back; a script that may write, queued under the pause,
        # is held back as it comes, and the transaction after it
        log("11 multi of a write", a.cmd("MULTI"), ev(a, "#!lua flags=no-writes\nreturn 12"),
            ev(a, "#!lua\nreturn 13"), r.cmd("CLIENT", "PAUSE", "100000", "WRITE"))
        a.send("EXEC")
        log("11 exec held", a.read(0.2), blocked(r, 1))
        log("11 exec", r.cmd("CLIENT", "UNPAUSE"), a.read())
        r.cmd("CLIENT", "PAUSE", "100000", "WRITE")
        a.send("MULTI")
        a.send("EVAL", "#!lua\nreturn 14", "0")
        a.send("EXEC")
        log("11 queued held", a.read(), a.read(0.2), blocked(r, 1))
        log("11 queued", r.cmd("CLIENT", "UNPAUSE"), a.read(), a.read())
    finally:
        r.cmd("CLIENT", "UNPAUSE")
        for x in (a, b, r):
            x.close()


def drain(c, n=6):
    """the replies and pushes of c up to a PING's reply"""
    c.send("PING")
    out = []
    for _ in range(n):
        x = c.read(timeout=2.0)
        out.append(x)
        if x in (b"+PONG\r\n", "TIMEOUT", "CLOSED"):
            break
    return out


def tracking(port, log):
    r = fresh(port, log, "12")
    w = "redis.call('SET', KEYS[1], 'v') return 1"
    # the caller's own key, written by its script: its invalidation after
    # the script's reply, after the replies before it in the pipeline
    for mode in ([], ["NOLOOP"], ["BCAST"], ["BCAST", "NOLOOP"]):
        c = Client(port, resp3=True)
        log("12 on", mode, c.cmd("CLIENT", "TRACKING", "ON", *mode))
        log("12 read", c.cmd("GET", k("t")))
        if "BCAST" in mode:
            log("12 script", mode, ev(c, w, [k("t")]), *drain(c))
        else:
            c.sock.sendall(enc(["PING"]) + enc(["EVAL", w, "1", k("t")]))
            log("12 pipeline", mode, c.read(), c.read(), *drain(c))
        c.close()
    # a tracking client a that redirects to b, which runs the script: b
    # told before the script's reply, after its replies before it
    b = Client(port, resp3=True)
    bid = b.cmd("CLIENT", "ID")
    a = Client(port, resp3=True)
    log("12 redirect", a.cmd("CLIENT", "TRACKING", "ON", "REDIRECT", bid[1:-2].decode()), a.cmd("GET", k("u")))
    b.sock.sendall(enc(["PING"]) + enc(["EVAL", w, "1", k("u")]))
    log("12 redirected", b.read(), b.read(), b.read(), *drain(b))
    a.close()
    b.close()
    # the keys a script's read-only calls read, remembered for its caller:
    # a key read undeclared too, a key declared and not read not, EVAL_RO's
    # own keys none; OPTIN with and without CLIENT CACHING yes
    c = Client(port, resp3=True)
    log("12 on", c.cmd("CLIENT", "TRACKING", "ON"))
    log("12 reads", ev(c, "return redis.call('GET', KEYS[1])", [k("d")]), ev(c, "return redis.call('GET', ARGV[1])", [], [k("x")]),
        ev(c, "return 1", [k("n")], cmd="EVAL_RO"), ev(c, "return redis.call('GET', KEYS[1])", [k("ro")], cmd="EVAL_RO"))
    log("12 writes", r.cmd("SET", k("d"), "1"), r.cmd("SET", k("x"), "1"), r.cmd("SET", k("n"), "1"), r.cmd("SET", k("ro"), "1"))
    log("12 heard", *drain(c))
    c.close()
    c = Client(port, resp3=True)
    log("12 optin", c.cmd("CLIENT", "TRACKING", "ON", "OPTIN"), ev(c, "return redis.call('GET', KEYS[1])", [k("o1")]),
        c.cmd("CLIENT", "CACHING", "YES"), ev(c, "return redis.call('GET', KEYS[1])", [k("o2")]))
    log("12 optin writes", r.cmd("SET", k("o1"), "1"), r.cmd("SET", k("o2"), "1"))
    log("12 optin heard", *drain(c))
    # a FLUSHALL in a script: the caller's null after the script's reply
    log("12 flush read", c.cmd("CLIENT", "CACHING", "YES"), c.cmd("GET", k("f")))
    log("12 flush", ev(c, "redis.call('FLUSHALL') return 1"), *drain(c))
    c.close()
    r.close()


# the fields of a client's line that differ from one server to the other,
# or from one run to the next (as acl_test.py's)
VOLATILE = (b"id", b"addr", b"laddr", b"fd", b"age", b"idle", b"qbuf", b"qbuf-free", b"argv-mem", b"multi-mem",
            b"rbs", b"rbp", b"obl", b"oll", b"omem", b"tot-mem", b"events")


def acl_log(c):
    """ACL LOG's entries, newest first, each as its fields: its age left
    out, its client's line without the volatile fields, its times (ms since
    1970) as whether they are such, the last update not before the
    creation, and its entry-id less the least of the reply's (the servers
    other tests used have made entries before)"""
    rep = c.cmd("ACL", "LOG")
    if not isinstance(rep, bytes) or rep[:1] != b"*":
        return [repr(rep)]
    es = parse(rep)[0]
    ids = [v for e in es for name, v in zip(e[0::2], e[1::2]) if name == b"entry-id"]
    base = min(ids, default=0)
    out = []
    for e in es:
        f = []
        made = None
        for i in range(0, len(e), 2):
            name, v = e[i], e[i + 1]
            if name == b"age-seconds":
                continue
            if name == b"client-info":
                v = b" ".join(x for x in v.split() if x.split(b"=", 1)[0] not in VOLATILE)
            elif name == b"entry-id":
                v = v - base
            elif name == b"timestamp-created":
                made = v
                v = isinstance(v, int) and v > 10 ** 12
            elif name == b"timestamp-last-updated":
                v = isinstance(v, int) and v > 10 ** 12 and made is not None and v >= made
            f.append((name, v))
        out.append(f)
    return out


def acl(port, log):
    r = fresh(port, log, "13")
    u = "u" + TAG
    log("13 reset", r.cmd("CONFIG", "RESETSTAT"), r.cmd("ACL", "LOG", "RESET"))
    log("13 user", r.cmd("ACL", "SETUSER", u, "on", ">p", "+@scripting", "+set", "+multi", "+exec", "+publish",
                         "resetchannels", "&ch*", "~x*"))
    c = Client(port)
    log("13 auth", c.cmd("AUTH", u, "p"))
    # redis.acl_check_cmd: allowed, a command not allowed, a key not
    # allowed (not one of the script's KEYS, which EVAL's own check reads),
    # a command not known
    log("13 check", ev(c, "return redis.acl_check_cmd('set', KEYS[1], 1)", [k("xa")]),
        ev(c, "return redis.acl_check_cmd('hset', KEYS[1], 'f', 1)", [k("xa")]),
        ev(c, "return redis.acl_check_cmd('set', ARGV[1], 1)", [], [k("ya")]),
        ev(c, "return redis.acl_check_cmd('no-such-command', 'arg')"))
    # a script's calls: allowed, a command, a key and a channel not allowed
    log("13 calls", ev(c, "return redis.call('set', KEYS[1], '1')", [k("xa")]),
        ev(c, "return redis.call('get', KEYS[1])", [k("xa")]),
        ev(c, "return redis.call('set', ARGV[1], '1')", [], [k("ya")]),
        ev(c, "return redis.pcall('set', ARGV[1], '1')", [], [k("ya")]),
        ev(c, "local e = redis.pcall('get', KEYS[1]) return e['err']", [k("xa")]),
        ev(c, "return redis.call('publish', 'chan', 'm')"),
        ev(c, "return redis.call('publish', 'other', 'm')"))
    log("13 stats", *stats(r))
    # EXEC of a script whose command its user lost since it was queued:
    # NOPERM in EXEC's array, the commands after it run; a command refused
    # so is no call, and EXEC fails when one comes after its last call
    # (#117)
    log("13 multi", c.cmd("MULTI"), ev(c, "return redis.call('set', KEYS[1], '2')", [k("xb")]),
        c.cmd("SET", k("xc"), "3"), ev(c, "return 1"), c.cmd("SET", k("xe"), "5"))
    log("13 eval lost", r.cmd("ACL", "SETUSER", u, "-eval"))
    log("13 exec", c.cmd("EXEC"), r.cmd("GET", k("xb")), r.cmd("GET", k("xc")))
    # EXEC of a script whose call is refused
    log("13 eval back", r.cmd("ACL", "SETUSER", u, "+eval"))
    log("13 exec call", c.cmd("MULTI"), ev(c, "return redis.call('get', KEYS[1])", [k("xb")]), c.cmd("SET", k("xd"), "4"),
        c.cmd("EXEC"))
    # and EXEC whose last queued command, a script's, its user lost: a
    # failed EXEC
    log("13 exec last", c.cmd("MULTI"), c.cmd("SET", k("xf"), "6"), ev(c, "return 1"),
        r.cmd("ACL", "SETUSER", u, "-eval"), c.cmd("EXEC"), r.cmd("ACL", "SETUSER", u, "+eval"))
    log("13 stats after", *stats(r))
    log("13 log", *acl_log(r))
    c.close()
    log("13 deluser", r.cmd("ACL", "DELUSER", u), r.cmd("ACL", "LOG", "RESET"))
    r.close()


SCENARIOS = [("1 replies", replies), ("2 redis.call", calls), ("3 errors", errors), ("4 the cache", cache),
             ("5 libraries", libraries), ("6 transactions", transactions), ("7 statistics", statistics),
             ("8 BUSY", busy), ("9 the slow log", slow), ("10 pipelines", pipelines), ("11 paused", paused),
             ("12 tracking", tracking), ("13 ACL", acl)]


def transcript(port, scenario):
    """the lines of a scenario on one server; an exception ends them"""
    lines = []
    try:
        scenario(port, lambda *x: lines.append(" ".join(repr(v) for v in x)))
    except Exception as e:
        lines.append("EXCEPTION %r" % (e,))
    return lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, required=True)
    ap.add_argument("--redis", type=int, required=True)
    ap.add_argument("--no-busy", action="store_true", help="leave out the scenario of a script past lua-time-limit")
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
                print("FAIL: %s, line %d:\n      BendKV %s\n      Redis  %s" % (name, i + 1, x[i][:400], y[i][:400]))
        if diff:
            print("FAIL: %s: %d of %d lines differ" % (name, len(diff), len(y)))
    if bad:
        print("FAIL: %d of %d lines of the script scenarios differ" % (bad, total))
        sys.exit(1)
    print("OK: %d lines of script scenarios as Redis answers them%s" % (total, " (BUSY left out)" if args.no_busy else ""))


if __name__ == "__main__":
    main()
