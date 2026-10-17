#!/usr/bin/env python3
"""Pub/Sub against Redis: scenarios of SUBSCRIBE, PSUBSCRIBE, SSUBSCRIBE,
their UNSUBSCRIBEs, PUBLISH, SPUBLISH and PUBSUB, each run on BendKV and
on Redis with clients of their own, the transcripts compared line by
line; then checks of BendKV alone under load.

The scenarios follow Redis's unit/pubsub and unit/pubsubshard: PING of a
subscribed client, messages to one client and to two, UNSUBSCRIBE of
some channels and of all, a channel subscribed to more than once, names
not subscribed to, patterns (globs with classes, escapes, ? and *, the
empty channel), NUMSUB, NUMPAT of patterns shared by clients, SUBSCRIBE
and PSUBSCRIBE mixed (message before pmessage), UNSUBSCRIBE and
PUNSUBSCRIBE of a client with no subscription, shard channels apart from
the others; the commands a subscribed client may not run (refused once
the checks of their name and arguments pass; EXEC aborted), RESET and
QUIT of a subscribed client, a client that closes its connection, CLIENT
REPLY OFF and SKIP (the replies of SUBSCRIBE and its kin sent all the
same), SUBSCRIBE inside a transaction (and SSUBSCRIBE refused there),
batches that subscribe and unsubscribe at once, PUBSUB's subcommands and
their errors, a large message, and the statistics of INFO; then keyspace
events, each class and mask, and a CONFIG SET of the classes that counts
for the commands after it in its pipeline and in its transaction. Replies
Redis sends in the order of a hash table (UNSUBSCRIBE of all, PUBSUB
CHANNELS) are compared sorted.

The checks under load: 20 subscribers of a channel and a pattern each get
1000 messages in order from 4 publishers; 50 subscribers close their
connections while messages are published, after which PUBLISH counts
none of them and a new subscriber gets what is published.

    python3 tests/pubsub_test.py --bendkv 6380 --redis 6390
"""
import argparse
import sys
import threading
import time

from blocking_test import Client, enc


def stats(r, *names):
    lines = r.cmd("INFO", "commandstats").splitlines() + r.cmd("INFO", "errorstats").splitlines()
    out = []
    for l in lines:
        for n in names:
            if l.startswith(n + ":"):
                out.append(",".join(p for p in l.split(",") if not p.startswith(("usec=", "usec_per_call="))))
    return sorted(out)


def reads(c, n, timeout=3.0):
    return [c.read(timeout) for _ in range(n)]


def quiet(c):
    """Nothing more comes: what came within a moment, or NONE."""
    x = c.read(0.15)
    return "NONE" if x == "TIMEOUT" else ("MORE", x)


def sorted_replies(xs):
    return sorted(xs, key=repr)


def unsub_all(xs):
    """Replies of UNSUBSCRIBE (or its kin) of all, which Redis sends in the
    order of a hash table: their words and names sorted, their counts as
    they came (one less each time, whatever the order)."""
    return sorted((x[0], x[1]) for x in xs), [x[2] for x in xs]


def scenarios(port, log):
    r = Client(port)
    r.cmd("FLUSHALL")
    # 1. PING of a subscribed client
    a = Client(port)
    log("1", a.cmd("SUBSCRIBE", "somechannel"), a.cmd("PING"), a.cmd("PING", "foo"),
        a.cmd("UNSUBSCRIBE", "somechannel"), a.cmd("PING"))
    # 2. basics: two channels, unsubscribe one, then the other
    a.send("SUBSCRIBE", "chan1", "chan2")
    log("2 sub", reads(a, 2), r.cmd("PUBLISH", "chan1", "hello"), r.cmd("PUBLISH", "chan2", "world"), reads(a, 2))
    log("2 unsub", a.cmd("UNSUBSCRIBE", "chan1"), r.cmd("PUBLISH", "chan1", "hello"), r.cmd("PUBLISH", "chan2", "world"),
        a.read(), a.cmd("UNSUBSCRIBE", "chan2"), r.cmd("PUBLISH", "chan1", "hello"), r.cmd("PUBLISH", "chan2", "world"),
        quiet(a))
    # 3. two clients
    b = Client(port)
    log("3", a.cmd("SUBSCRIBE", "chan1"), b.cmd("SUBSCRIBE", "chan1"), r.cmd("PUBLISH", "chan1", "hello"), a.read(),
        b.read(), a.cmd("UNSUBSCRIBE"), b.cmd("UNSUBSCRIBE"))
    # 4. UNSUBSCRIBE of all
    a.send("SUBSCRIBE", "chan1", "chan2", "chan3")
    log("4 sub", reads(a, 3))
    a.send("UNSUBSCRIBE")
    log("4 unsub", unsub_all(reads(a, 3)), r.cmd("PUBLISH", "chan1", "hello"), r.cmd("PUBLISH", "chan2", "hello"),
        r.cmd("PUBLISH", "chan3", "hello"), a.cmd("PING"))
    # 5. one channel more than once, names not subscribed to
    a.send("SUBSCRIBE", "chan1", "chan1", "chan1")
    log("5 more than once", reads(a, 3), r.cmd("PUBLISH", "chan1", "hello"), a.read(), a.cmd("UNSUBSCRIBE", "chan1"))
    a.send("UNSUBSCRIBE", "foo", "bar", "quux")
    log("5 not subscribed", reads(a, 3))
    # 6. patterns
    a.send("PSUBSCRIBE", "foo.*", "bar.*")
    log("6 psub", reads(a, 2), r.cmd("PUBLISH", "foo.1", "hello"), r.cmd("PUBLISH", "bar.1", "hello"),
        r.cmd("PUBLISH", "foo1", "hello"), r.cmd("PUBLISH", "barfoo.1", "hello"), r.cmd("PUBLISH", "qux.1", "hello"),
        reads(a, 2))
    log("6 punsub", a.cmd("PUNSUBSCRIBE", "foo.*"), r.cmd("PUBLISH", "foo.1", "hello"), r.cmd("PUBLISH", "bar.1", "hello"),
        a.read(), a.cmd("PUNSUBSCRIBE", "bar.*"), r.cmd("PUBLISH", "foo.1", "hello"), r.cmd("PUBLISH", "bar.1", "hello"),
        quiet(a))
    log("6 two clients", a.cmd("PSUBSCRIBE", "chan.*"), b.cmd("PSUBSCRIBE", "chan.*"), r.cmd("PUBLISH", "chan.foo", "hello"),
        a.read(), b.read(), a.cmd("PUNSUBSCRIBE"), b.cmd("PUNSUBSCRIBE"))
    a.send("PSUBSCRIBE", "chan1.*", "chan2.*", "chan3.*")
    log("6 all", reads(a, 3))
    a.send("PUNSUBSCRIBE")
    log("6 punsub all", unsub_all(reads(a, 3)), r.cmd("PUBLISH", "chan1.hi", "hello"),
        r.cmd("PUBLISH", "chan2.hi", "hello"), r.cmd("PUBLISH", "chan3.hi", "hello"))
    a.send("PUNSUBSCRIBE", "foo.*", "bar.*", "quux.*")
    log("6 not subscribed", reads(a, 3))
    a.send("PSUBSCRIBE", "h[ae]llo", "h?llo", "*", "x\\*y", "[^a]bc", "[a-c]z")
    log("6 globs", reads(a, 6), r.cmd("PUBLISH", "hallo", "1"), r.cmd("PUBLISH", "hxllo", "2"), r.cmd("PUBLISH", "", "3"),
        r.cmd("PUBLISH", "x*y", "4"), r.cmd("PUBLISH", "xay", "5"), r.cmd("PUBLISH", "zbc", "6"),
        r.cmd("PUBLISH", "bz", "7"))
    log("6 globs got", sorted_replies(reads(a, 12)), quiet(a))
    a.send("PUNSUBSCRIBE")
    log("6 globs gone", unsub_all(reads(a, 6)))
    # 7. NUMSUB, NUMPAT
    log("7 numsub none", r.cmd("PUBSUB", "NUMSUB", "abc", "def"), r.cmd("PUBSUB", "NUMSUB"))
    log("7 numsub", a.cmd("SUBSCRIBE", "n1"), b.cmd("SUBSCRIBE", "n1"), r.cmd("PUBSUB", "NUMSUB", "n1", "n2", "n1"),
        a.cmd("UNSUBSCRIBE"), b.cmd("UNSUBSCRIBE"), r.cmd("PUBSUB", "NUMSUB", "n1"))
    log("7 numpat", a.cmd("PSUBSCRIBE", "foo*"), b.cmd("PSUBSCRIBE", "foo*"), a.cmd("PSUBSCRIBE", "bar*"),
        b.cmd("PSUBSCRIBE", "baz*"), r.cmd("PUBSUB", "NUMPAT"))
    a.send("PUNSUBSCRIBE")
    b.send("PUNSUBSCRIBE")
    log("7 numpat after", unsub_all(reads(a, 2)), unsub_all(reads(b, 2)), r.cmd("PUBSUB", "NUMPAT"))
    # 8. SUBSCRIBE and PSUBSCRIBE mixed
    log("8", a.cmd("SUBSCRIBE", "foo.bar"), a.cmd("PSUBSCRIBE", "foo.*"), r.cmd("PUBLISH", "foo.bar", "hello"),
        reads(a, 2), a.cmd("UNSUBSCRIBE"), a.cmd("PUNSUBSCRIBE"))
    # 9. UNSUBSCRIBE and PUNSUBSCRIBE of a client with no subscription
    log("9", r.cmd("PUNSUBSCRIBE"), r.cmd("UNSUBSCRIBE"), r.cmd("SUNSUBSCRIBE"), r.cmd("PUNSUBSCRIBE"),
        r.cmd("UNSUBSCRIBE"), r.cmd("GET", "x"))
    # 10. what a subscribed client may not run
    r.cmd("SET", "k", "v")
    log("10", a.cmd("SUBSCRIBE", "c10"), a.cmd("GET", "k"), a.cmd("SET", "k", "w"), a.cmd("PUBLISH", "c10", "x"),
        a.cmd("CLIENT", "ID"), a.cmd("CONFIG", "GET", "maxmemory"), a.cmd("PUBSUB", "NUMPAT"), a.cmd("ECHO", "e"),
        a.cmd("SELECT", "1"), a.cmd("MULTI"), a.cmd("EXEC"), a.cmd("DISCARD"), a.cmd("WATCH", "k"),
        a.cmd("SET", "k", "v", "BAD"), a.cmd("BLPOP", "k", "0"))
    log("10 checks first", a.cmd("FOO"), a.cmd("GET"), a.cmd("PING", "a", "b"), a.cmd("SUBSCRIBE"),
        a.cmd("CLIENT", "NOSUCH"), a.cmd("CONFIG"), a.cmd("PUBSUB", "NOSUCH"), r.cmd("GET", "k"))
    log("10 reset", a.cmd("RESET"), r.cmd("PUBLISH", "c10", "x"), a.cmd("PING"), a.cmd("SELECT", "9"), a.cmd("GET", "k"))
    # 11. QUIT of a subscribed client, a client that closes its connection
    c = Client(port)
    log("11 quit", c.cmd("SUBSCRIBE", "c11"), c.cmd("QUIT"), r.cmd("PUBLISH", "c11", "x"))
    c.close()
    c = Client(port)
    log("11 close", c.cmd("SUBSCRIBE", "c11"), c.cmd("PSUBSCRIBE", "c1*"), r.cmd("PUBLISH", "c11", "x"))
    c.close()
    time.sleep(0.2)
    log("11 gone", r.cmd("PUBLISH", "c11", "x"), r.cmd("PUBSUB", "NUMSUB", "c11"), r.cmd("PUBSUB", "NUMPAT"))
    # 12. CLIENT REPLY OFF and SKIP
    a.send("CLIENT", "REPLY", "OFF")
    log("12 off", a.cmd("SUBSCRIBE", "channel"), a.cmd("PSUBSCRIBE", "ch*"), r.cmd("PUBLISH", "channel", "hello"),
        reads(a, 2))
    a.send("PING")
    log("12 off quiet", quiet(a), a.cmd("UNSUBSCRIBE", "channel"), a.cmd("PUNSUBSCRIBE", "ch*"))
    a.send("GET", "k")
    log("12 off on", quiet(a), a.cmd("CLIENT", "REPLY", "ON"), a.cmd("GET", "k"))
    a.send("CLIENT", "REPLY", "SKIP")
    log("12 skip", a.cmd("PSUBSCRIBE", "*"), a.cmd("PING"), a.cmd("PUNSUBSCRIBE"))
    # 13. inside a transaction
    log("13 multi", a.cmd("MULTI"), a.cmd("SUBSCRIBE", "t13"), a.cmd("PING"), a.cmd("GET", "k"), a.cmd("EXEC"),
        r.cmd("PUBLISH", "t13", "m"), a.read(), a.cmd("PING"), a.cmd("UNSUBSCRIBE"))
    log("13 ssubscribe", a.cmd("MULTI"), a.cmd("SSUBSCRIBE", "t13"), a.cmd("PSUBSCRIBE", "t1*"), a.cmd("EXEC"),
        r.cmd("SPUBLISH", "t13", "s"), r.cmd("PUBLISH", "t13", "p"), a.read(), a.cmd("PUNSUBSCRIBE"))
    log("13 discard", a.cmd("MULTI"), a.cmd("SUBSCRIBE", "t13"), a.cmd("DISCARD"), r.cmd("PUBLISH", "t13", "x"),
        a.cmd("PING"))
    # 14. a batch that subscribes and unsubscribes at once
    a.raw(b"SUBSCRIBE b14\r\nPING\r\nUNSUBSCRIBE b14\r\nPING\r\nGET k\r\n")
    log("14", reads(a, 5))
    a.raw(b"SUBSCRIBE b14\r\nGET k\r\nPING x\r\nUNSUBSCRIBE\r\nGET k\r\n")
    log("14 refused", reads(a, 5))
    # 15. PUBSUB
    log("15 channels", a.cmd("SUBSCRIBE", "ab", "ac", "bc"), reads(a, 2), b.cmd("SUBSCRIBE", "ab", "zz"), b.read(),
        sorted(r.cmd("PUBSUB", "CHANNELS")), sorted(r.cmd("PUBSUB", "CHANNELS", "a*")),
        r.cmd("PUBSUB", "CHANNELS", "q*"), r.cmd("PUBSUB", "NUMSUB", "ab", "ac", "zz", "no"))
    a.send("UNSUBSCRIBE")
    b.send("UNSUBSCRIBE")
    log("15 after", unsub_all(reads(a, 3)), unsub_all(reads(b, 2)), r.cmd("PUBSUB", "CHANNELS"))
    log("15 help", r.cmd("PUBSUB", "HELP"), r.cmd("PUBSUB", "help"), r.cmd("PUBSUB", "HELP", "x"))
    log("15 errors", r.cmd("PUBSUB"), r.cmd("PUBSUB", "FOO"), r.cmd("PUBSUB", "CHANNELS", "a", "b"),
        r.cmd("PUBSUB", "NUMPAT", "x"), r.cmd("PUBSUB", "SHARDCHANNELS", "a", "b"), r.cmd("PUBLISH", "x"),
        r.cmd("PUBLISH", "x", "y", "z"), r.cmd("SPUBLISH", "x"), r.cmd("SUBSCRIBE"), r.cmd("PSUBSCRIBE"),
        r.cmd("SSUBSCRIBE"))
    # 16. shard channels
    log("16 basics", a.cmd("SSUBSCRIBE", "s1", "s2"), a.read(), r.cmd("SPUBLISH", "s1", "hello"),
        r.cmd("SPUBLISH", "s2", "world"), reads(a, 2), r.cmd("PUBLISH", "s1", "no"),
        r.cmd("PUBSUB", "SHARDNUMSUB", "s1", "s3"), sorted(r.cmd("PUBSUB", "SHARDCHANNELS")),
        r.cmd("PUBSUB", "SHARDCHANNELS", "*2"), r.cmd("PUBSUB", "CHANNELS"))
    log("16 mixed", a.cmd("SUBSCRIBE", "s1"), a.cmd("PSUBSCRIBE", "s*"), r.cmd("SPUBLISH", "s1", "x"),
        r.cmd("PUBLISH", "s1", "y"), reads(a, 3), a.cmd("SUNSUBSCRIBE", "s1"), a.cmd("PING"))
    a.send("SUNSUBSCRIBE")
    log("16 sunsub all", a.read(), a.cmd("SUNSUBSCRIBE"), a.cmd("UNSUBSCRIBE"), a.cmd("PUNSUBSCRIBE"), a.cmd("PING"),
        r.cmd("PUBSUB", "SHARDCHANNELS"))
    log("16 more than once", a.cmd("SSUBSCRIBE", "x", "x"), a.read(), a.cmd("SUNSUBSCRIBE", "y", "x"), a.read())
    # 17. a large message, and many
    big = "x" * 100000
    log("17 big", a.cmd("SUBSCRIBE", "big"), r.cmd("PUBLISH", "big", big), a.read() == ["message", "big", big])
    for i in range(50):
        r.send("PUBLISH", "big", str(i))
    log("17 many", reads(r, 50), [m[2] for m in reads(a, 50)], a.cmd("UNSUBSCRIBE"))
    # 18. INFO's statistics
    r.cmd("CONFIG", "RESETSTAT")
    log("18", a.cmd("SUBSCRIBE", "st"), a.cmd("GET", "k"), a.cmd("PING"), a.cmd("UNSUBSCRIBE"),
        r.cmd("PUBLISH", "st", "x"), r.cmd("PUBSUB", "NUMSUB", "st"),
        stats(r, "cmdstat_subscribe", "cmdstat_unsubscribe", "cmdstat_get", "cmdstat_ping", "cmdstat_publish",
              "cmdstat_pubsub|numsub", "errorstat_ERR"))
    r.cmd("CONFIG", "RESETSTAT")
    for c in (a, b, r):
        c.close()
    keyspace(port, log)


def events(r, sub, *cmd):
    """A command's reply and the events it published, as the subscriber
    of every channel got them (up to a marker published after it)."""
    reply = r.cmd(*cmd)
    r.cmd("PUBLISH", "mark", "m")
    got = []
    while True:
        m = sub.read()
        if m == "TIMEOUT" or (m[0] == "pmessage" and m[2] == "mark"):
            return reply, got
        got.append(tuple(m[2:]))


def keyspace(port, log):
    r = Client(port)
    r.cmd("FLUSHALL")
    sub = Client(port)
    sub.cmd("PSUBSCRIBE", "*")

    def ev(tag, *cmd):
        log("19 " + tag, *events(r, sub, *cmd))

    r.cmd("CONFIG", "SET", "notify-keyspace-events", "KEA")
    # strings
    ev("set", "SET", "s", "1")
    ev("set again", "SET", "s", "1")
    ev("set nx no", "SET", "s", "2", "NX")
    ev("set xx", "SET", "s", "2", "XX")
    ev("set ex", "SET", "s", "3", "EX", "100")
    ev("set keepttl", "SET", "s", "4", "KEEPTTL")
    ev("set get", "SET", "s", "5", "GET")
    ev("setex", "SETEX", "se", "100", "v")
    ev("psetex", "PSETEX", "se", "100000", "v")
    ev("setnx", "SETNX", "sn", "v")
    ev("setnx no", "SETNX", "sn", "v")
    ev("getset", "GETSET", "sn", "w")
    ev("append new", "APPEND", "ap", "x")
    ev("append", "APPEND", "ap", "y")
    ev("append empty", "APPEND", "ap", "")
    ev("setrange new", "SETRANGE", "sr", "2", "ab")
    ev("setrange", "SETRANGE", "sr", "0", "z")
    ev("setrange same", "SETRANGE", "sr", "0", "z")
    ev("setrange empty", "SETRANGE", "sr", "1", "")
    ev("setrange none", "SETRANGE", "nosr", "0", "")
    ev("incr", "INCR", "n")
    ev("decr", "DECR", "n")
    ev("incrby", "INCRBY", "n", "5")
    ev("decrby", "DECRBY", "n", "2")
    ev("incrbyfloat", "INCRBYFLOAT", "f", "1.5")
    ev("incr bad", "INCR", "s")
    ev("setbit", "SETBIT", "b", "3", "1")
    ev("setbit same", "SETBIT", "b", "3", "1")
    ev("setbit clear", "SETBIT", "b", "3", "0")
    ev("bitfield", "BITFIELD", "bf", "SET", "u8", "0", "255", "GET", "u8", "0")
    ev("bitfield get", "BITFIELD", "bf", "GET", "u8", "0")
    ev("bitop", "BITOP", "OR", "bo", "b", "bf")
    ev("bitop empty", "BITOP", "AND", "bo", "nokey1", "nokey2")
    ev("mset", "MSET", "m1", "1", "m2", "2", "m1", "3")
    ev("msetnx", "MSETNX", "m3", "1", "m4", "2")
    ev("msetnx no", "MSETNX", "m3", "1", "m5", "2")
    ev("getex ex", "GETEX", "m1", "EX", "100")
    ev("getex persist", "GETEX", "m1", "PERSIST")
    ev("getex persist none", "GETEX", "m1", "PERSIST")
    ev("getex exat past", "GETEX", "m2", "EXAT", "1")
    ev("getdel", "GETDEL", "m3")
    ev("getdel none", "GETDEL", "m3")
    ev("del", "DEL", "m4", "nokey", "sn")
    ev("unlink", "UNLINK", "ap", "sr")
    ev("expire", "EXPIRE", "n", "100")
    ev("expire nx no", "EXPIRE", "n", "100", "NX")
    ev("pexpire", "PEXPIRE", "n", "100000")
    ev("expireat", "EXPIREAT", "n", "9999999999")
    ev("persist", "PERSIST", "n")
    ev("persist none", "PERSIST", "n")
    ev("expire past", "EXPIRE", "n", "-1")
    ev("rename", "RENAME", "f", "f2")
    r.cmd("SET", "f3", "x")
    ev("rename over", "RENAME", "f2", "f3")
    ev("renamenx no", "RENAMENX", "f3", "s")
    ev("renamenx", "RENAMENX", "f3", "f4")
    ev("rename same", "RENAME", "f4", "f4")
    ev("move", "MOVE", "f4", "2")
    ev("copy", "COPY", "s", "s2")
    ev("copy no", "COPY", "s", "s2")
    ev("copy replace", "COPY", "s", "s2", "REPLACE")
    ev("copy db", "COPY", "s", "s2", "DB", "3")
    ev("swapdb", "SWAPDB", "2", "3")
    # hashes
    ev("hset", "HSET", "h", "a", "1", "b", "2")
    ev("hset same", "HSET", "h", "a", "1")
    ev("hmset", "HMSET", "h", "c", "3")
    ev("hsetnx", "HSETNX", "h", "d", "4")
    ev("hsetnx no", "HSETNX", "h", "d", "4")
    ev("hincrby", "HINCRBY", "h", "a", "10")
    ev("hincrbyfloat", "HINCRBYFLOAT", "h", "a", "0.5")
    ev("hdel", "HDEL", "h", "a", "zz")
    ev("hdel none", "HDEL", "h", "zz")
    ev("hdel all", "HDEL", "h", "b", "c", "d")
    # lists
    ev("lpush", "LPUSH", "l", "a", "b")
    ev("rpush", "RPUSH", "l", "c")
    ev("lpushx none", "LPUSHX", "nol", "a")
    ev("rpushx", "RPUSHX", "l", "d")
    ev("linsert", "LINSERT", "l", "BEFORE", "a", "x")
    ev("linsert no", "LINSERT", "l", "BEFORE", "zz", "x")
    ev("lset", "LSET", "l", "0", "q")
    ev("lset same", "LSET", "l", "0", "q")
    ev("lrem", "LREM", "l", "0", "x")
    ev("lrem none", "LREM", "l", "0", "zz")
    ev("ltrim noop", "LTRIM", "l", "0", "-1")
    ev("ltrim", "LTRIM", "l", "0", "3")
    ev("lpop", "LPOP", "l")
    ev("rpop count", "RPOP", "l", "2")
    ev("lmove", "LMOVE", "l", "l2", "LEFT", "RIGHT")
    ev("lmove same", "LMOVE", "l2", "l2", "LEFT", "RIGHT")
    ev("rpoplpush", "RPOPLPUSH", "l2", "l3")
    ev("lmpop", "LMPOP", "2", "nol", "l3", "LEFT")
    r.cmd("RPUSH", "l4", "a", "b")
    ev("ltrim empty", "LTRIM", "l4", "5", "10")
    ev("lpop none", "LPOP", "nol")
    # sets
    ev("sadd", "SADD", "st", "a", "b", "c")
    ev("sadd same", "SADD", "st", "a")
    ev("srem", "SREM", "st", "a", "zz")
    ev("srem none", "SREM", "st", "zz")
    ev("smove", "SMOVE", "st", "st2", "b")
    ev("smove there", "SADD", "st2", "c")
    ev("smove had", "SMOVE", "st", "st2", "c")
    ev("smove same", "SMOVE", "st2", "st2", "b")
    r.cmd("SADD", "sp", "a", "b", "c")
    log("19 spop", *[(len(x) if i == 0 else x) for i, x in enumerate(events(r, sub, "SPOP", "sp", "2"))])
    log("19 spop last", *[(len(x) if i == 0 else x) for i, x in enumerate(events(r, sub, "SPOP", "sp"))])
    r.cmd("SADD", "sx", "a", "b")
    r.cmd("SADD", "sy", "b", "c")
    ev("sinterstore", "SINTERSTORE", "si", "sx", "sy")
    ev("sunionstore", "SUNIONSTORE", "si", "sx", "sy")
    ev("sdiffstore", "SDIFFSTORE", "sd", "sx", "sy")
    ev("sinterstore empty", "SINTERSTORE", "si", "sx", "nos")
    ev("sinterstore empty none", "SINTERSTORE", "si", "sx", "nos")
    # sorted sets
    ev("zadd", "ZADD", "z", "1", "a", "2", "b")
    ev("zadd same", "ZADD", "z", "1", "a")
    ev("zadd update", "ZADD", "z", "5", "a")
    ev("zadd ch", "ZADD", "z", "CH", "6", "a")
    ev("zadd incr", "ZADD", "z", "INCR", "1", "a")
    ev("zadd xx none", "ZADD", "z", "XX", "1", "zz")
    ev("zincrby", "ZINCRBY", "z", "2", "b")
    ev("zrem", "ZREM", "z", "b", "zz")
    r.cmd("ZADD", "z", "1", "c", "2", "d", "3", "e", "4", "f")
    ev("zremrangebyscore", "ZREMRANGEBYSCORE", "z", "1", "1")
    ev("zremrangebyrank", "ZREMRANGEBYRANK", "z", "0", "0")
    ev("zremrangebylex", "ZREMRANGEBYLEX", "z", "[e", "[e")
    ev("zremrangebyscore none", "ZREMRANGEBYSCORE", "z", "100", "200")
    ev("zpopmin", "ZPOPMIN", "z")
    ev("zpopmax", "ZPOPMAX", "z", "5")
    r.cmd("ZADD", "za", "1", "a", "2", "b")
    r.cmd("ZADD", "zb", "1", "b")
    ev("zunionstore", "ZUNIONSTORE", "zu", "2", "za", "zb")
    ev("zinterstore", "ZINTERSTORE", "zu", "2", "za", "zb")
    ev("zdiffstore", "ZDIFFSTORE", "zd", "2", "za", "zb")
    ev("zrangestore", "ZRANGESTORE", "zr", "za", "0", "0")
    ev("zinterstore empty", "ZINTERSTORE", "zu", "2", "za", "noz")
    ev("zmpop", "ZMPOP", "2", "noz", "za", "MIN", "COUNT", "5")
    # SORT ... STORE
    r.cmd("RPUSH", "sl", "2", "1")
    ev("sort store", "SORT", "sl", "STORE", "sod")
    ev("sort store again", "SORT", "sl", "DESC", "STORE", "sod")
    r.cmd("SET", "sostr", "x", "EX", "100")
    ev("sort store over", "SORT", "sl", "STORE", "sostr")
    log("19 sort store ttl", r.cmd("TTL", "sostr"), r.cmd("TYPE", "sostr"))
    ev("sort store empty", "SORT", "nosl", "STORE", "sod")
    ev("sort store empty none", "SORT", "nosl", "STORE", "sod")
    ev("sort store limit", "SORT", "sl", "LIMIT", "5", "5", "STORE", "sostr")
    ev("sort read", "SORT", "sl")
    ev("sort ro", "SORT_RO", "sl", "DESC")
    r.cmd("SET", "sostr", "x")
    ev("sort wrongtype", "SORT", "sostr", "STORE", "sod")
    ev("sort bad", "SORT", "sl", "LIMIT", "x", "1", "STORE", "sod")
    # HyperLogLogs: pfadd when a register changes (or the key is made),
    # PFMERGE as pfadd, none of PFCOUNT and PFDEBUG
    ev("pfadd new", "PFADD", "pf", "a")
    ev("pfadd same", "PFADD", "pf", "a")
    ev("pfadd none", "PFADD", "pf")
    ev("pfadd more", "PFADD", "pf", "b", "c")
    ev("pfcount", "PFCOUNT", "pf")
    ev("pfcount several", "PFCOUNT", "pf", "nopf")
    ev("pfmerge", "PFMERGE", "pfd", "pf")
    ev("pfmerge again", "PFMERGE", "pfd", "pf")
    ev("pfmerge new", "PFMERGE", "pfe")
    ev("pfdebug", "PFDEBUG", "TODENSE", "pfd")
    r.cmd("SET", "pfstr", "x", "PX", "1")
    time.sleep(0.01)
    ev("pfadd expired", "PFADD", "pfstr", "a")
    ev("pfadd wrongtype", "PFADD", "sl", "a")
    r.cmd("SET", "pfstr", "x")
    ev("pfadd not one", "PFADD", "pfstr", "a")
    ev("pfmerge not one", "PFMERGE", "pfd", "pfstr")
    # a transaction, a client that waits
    ev("exec", "EVAL", "return 1", "0") if False else None
    w = Client(port)
    w.send("BLPOP", "bl", "0")
    time.sleep(0.2)
    log("19 blpop", *events(r, sub, "LPUSH", "bl", "x"), w.read())
    w.close()
    r.cmd("MULTI")
    r.cmd("SET", "t1", "1")
    r.cmd("INCR", "t1")
    r.cmd("DEL", "t1")
    ev("exec", "EXEC")
    # masks and flags
    r.cmd("CONFIG", "SET", "notify-keyspace-events", "Kl")
    ev("mask set", "SET", "ms", "1")
    ev("mask lpush", "LPUSH", "ml", "a")
    r.cmd("CONFIG", "SET", "notify-keyspace-events", "Eg$")
    ev("mask event", "SET", "ms", "2")
    ev("mask del", "DEL", "ms", "ml")
    r.cmd("CONFIG", "SET", "notify-keyspace-events", "En")
    ev("new", "SET", "nk", "1")
    ev("new again", "SET", "nk", "2")
    ev("new hset", "HSET", "nh", "f", "v")
    r.cmd("CONFIG", "SET", "notify-keyspace-events", "KEnA")
    ev("all", "LPUSH", "nl", "a")
    r.cmd("CONFIG", "SET", "notify-keyspace-events", "K")
    ev("no class", "SET", "nc", "1")
    r.cmd("CONFIG", "SET", "notify-keyspace-events", "Ex")
    r.cmd("SET", "ex1", "v", "PX", "50")
    log("19 expired", sub.read(5.0))
    r.cmd("CONFIG", "SET", "notify-keyspace-events", "KEA")
    r.cmd("SET", "ex2", "v", "PX", "1")
    time.sleep(0.05)
    ev("expired replaced", "SET", "ex2", "w")
    r.cmd("CONFIG", "SET", "notify-keyspace-events", "")
    ev("off", "SET", "off", "1")
    log("19 get", r.cmd("CONFIG", "GET", "notify-keyspace-events"))
    # a CONFIG SET of the classes counts for the commands after it in its
    # pipeline and in its transaction: pl's first SET is heard, and tx's
    # second
    r.raw(enc(["CONFIG", "SET", "notify-keyspace-events", "KEA"]) + enc(["SET", "pl", "1"])
          + enc(["CONFIG", "SET", "notify-keyspace-events", ""]) + enc(["SET", "pl", "2"]))
    log("19 pipeline", reads(r, 4), *events(r, sub, "PING"))
    r.raw(enc(["MULTI"]) + enc(["SET", "tx", "1"]) + enc(["CONFIG", "SET", "notify-keyspace-events", "KEA"])
          + enc(["SET", "tx", "2"]) + enc(["CONFIG", "SET", "notify-keyspace-events", ""]) + enc(["EXEC"]))
    log("19 transaction", reads(r, 6), *events(r, sub, "PING"))
    sub.close()
    r.cmd("FLUSHALL")
    r.close()


def load(port):
    bad = []
    r = Client(port)
    # 20 subscribers of a channel and a pattern; 4 publishers of 250 each
    subs = [Client(port) for _ in range(20)]
    for s in subs:
        s.cmd("SUBSCRIBE", "load")
        s.cmd("PSUBSCRIBE", "lo*")
    got = [[] for _ in subs]

    def reader(i):
        for _ in range(2000):
            m = subs[i].read(10.0)
            if m == "TIMEOUT":
                break
            got[i].append(m)

    ths = [threading.Thread(target=reader, args=(i,)) for i in range(len(subs))]
    for t in ths:
        t.start()
    counts = []

    def publisher(p):
        c = Client(port)
        for j in range(250):
            counts.append(c.cmd("PUBLISH", "load", "%d.%d" % (p, j)))
        c.close()

    pubs = [threading.Thread(target=publisher, args=(p,)) for p in range(4)]
    for t in pubs:
        t.start()
    for t in pubs:
        t.join()
    for t in ths:
        t.join()
    if set(counts) != {":40"}:
        bad.append("PUBLISH counted %r receivers" % (sorted(set(counts)),))
    for i, ms in enumerate(got):
        if len(ms) != 2000:
            bad.append("subscriber %d got %d messages of 2000" % (i, len(ms)))
            continue
        plain = [m[2] for m in ms if m[0] == "message"]
        pat = [m[3] for m in ms if m[0] == "pmessage"]
        for p in range(4):
            seq = [x for x in plain if x.startswith("%d." % p)]
            if seq != ["%d.%d" % (p, j) for j in range(250)]:
                bad.append("subscriber %d got publisher %d's messages out of order" % (i, p))
        if plain != pat:
            bad.append("subscriber %d: the pmessages differ from the messages" % i)
    for s in subs:
        s.close()
    # 50 subscribers leave while messages are published
    gone = [Client(port) for _ in range(50)]
    for s in gone:
        s.cmd("SUBSCRIBE", "leave")
    stop = []

    def spam():
        c = Client(port)
        while not stop:
            c.cmd("PUBLISH", "leave", "m")
        c.close()

    sp = threading.Thread(target=spam)
    sp.start()
    for s in gone:
        s.close()
        time.sleep(0.005)
    stop.append(True)
    sp.join()
    time.sleep(0.3)
    if r.cmd("PUBLISH", "leave", "m") != ":0" or r.cmd("PUBSUB", "NUMSUB", "leave") != ["leave", ":0"]:
        bad.append("the subscribers gone are still counted")
    c = Client(port)
    c.cmd("SUBSCRIBE", "leave")
    if r.cmd("PUBLISH", "leave", "after") != ":1" or c.read() != ["message", "leave", "after"]:
        bad.append("a subscriber after the others left gets nothing")
    c.close()
    r.close()
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, required=True)
    ap.add_argument("--redis", type=int, required=True)
    args = ap.parse_args()
    outs = []
    for port in (args.bendkv, args.redis):
        lines = []
        try:
            scenarios(port, lambda *x: lines.append(" ".join(repr(v) for v in x)))
        except Exception as e:
            lines.append("EXCEPTION %r" % (e,))
        outs.append(lines)
    bad = 0
    for i in range(max(len(outs[0]), len(outs[1]))):
        x = outs[0][i] if i < len(outs[0]) else "<none>"
        y = outs[1][i] if i < len(outs[1]) else "<none>"
        if x != y:
            bad += 1
            if bad <= 20:
                print("FAIL: BendKV %s\n      Redis  %s" % (x, y))
    fails = load(args.bendkv)
    for f in fails:
        print("FAIL: under load:", f)
    if bad or fails:
        print("FAIL: %d of %d lines of the scenarios differ, %d checks under load fail" % (bad, len(outs[1]), len(fails)))
        sys.exit(1)
    print("OK: %d lines of Pub/Sub scenarios as Redis answers them, and 2 checks under load" % len(outs[1]))


if __name__ == "__main__":
    main()
