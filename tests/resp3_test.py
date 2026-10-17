#!/usr/bin/env python3
"""RESP3 against Redis: HELLO and the switch of protocol (in the middle of
a pipeline too, and back with RESET), the replies RESP3 types (nulls,
doubles, maps, sets, pairs, verbatim texts, pushes) on their own and in
EXEC, blocking commands served and timing out, Pub/Sub's pushes (a RESP3
client with a subscription runs any command, and gets its own messages
and keyspace events after the reply of the command that made them, after
EXEC's and a script's for theirs, as Redis 7.2 sends them), CLIENT
INFO's resp=, and COMMAND's maps and sets (of commands without
subcommands: BendKV lists them by name, Redis in the order of a hash
table). Each scenario runs on both
servers on fresh connections; their replies are compared as they are,
but for what is the server's own: a client's id (HELLO, CLIENT INFO's
line, which is compared by its kind and its resp=).

    python3 tests/resp3_test.py --bendkv 6380 --redis 6390
"""
import argparse
import socket
import sys
import time

from diff_test import Conn

bad = 0
n = 0


def drain(c, wait=0.25):
    """every reply that comes within wait seconds of the last"""
    out = []
    c.sock.settimeout(wait)
    try:
        while True:
            while b"\r\n" not in c.buf:
                c._fill()
            out.append(c.reply())
    except (socket.timeout, TimeoutError):
        pass
    c.sock.settimeout(None)
    return out


def words(line):
    return [w.encode() for w in line.split(" ")]


def norm(x):
    """a reply with the server's own facts taken out"""
    kind, v = x
    if kind in (b"%", b"*") and v and len(v) >= 8 and v[0] == (b"$", b"server"):
        # HELLO: the client's id is the server's
        v = list(v)
        v[7] = (b":", b"<id>")
        return (kind, v)
    if kind in (b"=", b"$") and v is not None and v.startswith((b"txt:id=", b"id=")):
        # a client's line: its kind and its protocol
        return (kind, b"resp=" + v.split(b" resp=")[1][:1])
    if kind in (b"*", b"~", b">", b"%") and v is not None:
        return (kind, [norm(y) for y in v])
    return x


def run(port, steps):
    conns, out = {}, []
    for who, lines in steps:
        if who not in conns:
            conns[who] = Conn(port, resp3=False)
        c = conns[who]
        if lines:
            c.send([words(l) for l in lines])
        if who.endswith("!"):
            continue  # sent, its replies read with the next step's
        time.sleep(0.05)
        out.append((who, [norm(x) for x in drain(c)]))
    for c in conns.values():
        c.sock.close()
    return out


def check(name, steps, a):
    global bad, n
    n += 1
    for c in (Conn(a.bendkv, resp3=False), Conn(a.redis, resp3=False)):
        c.send([[b"FLUSHALL"], [b"CONFIG", b"SET", b"notify-keyspace-events", b""]])
        c.reply()
        c.reply()
        c.sock.close()
    got, want = run(a.bendkv, steps), run(a.redis, steps)
    if got != want:
        bad += 1
        print("FAIL: %s" % name)
        for (w1, x), (w2, y) in zip(got, want):
            if x != y:
                i = next((i for i, (p, q) in enumerate(zip(x, y)) if p != q), min(len(x), len(y)))
                print("  %s, reply %d: BendKV %r\n  %s  Redis  %r" % (w1, i, x[i:i + 2], " " * len(w1), y[i:i + 2]))
                if len(x) != len(y):
                    print("  %s: %d replies, Redis %d" % (w1, len(x), len(y)))


SCENARIOS = [
    ("HELLO and its errors", [
        ("a", ["HELLO 3", "HELLO", "HELLO 2", "HELLO", "HELLO 4", "HELLO 1", "HELLO x", "HELLO 3 SETNAME a\x01b",
               "HELLO 3 SETNAME", "HELLO 3 FOO", "PING"]),
        ("a", ["HELLO 3 AUTH default any SETNAME me", "CLIENT GETNAME", "GET nokey"]),
    ]),
    ("the protocol switched in a pipeline", [
        ("a", ["SET k v", "GET nokey", "HELLO 3", "GET nokey", "LPOP nokey 2", "HELLO 2", "GET nokey",
               "LPOP nokey 2", "HELLO 3", "RESET", "GET nokey", "HELLO 3", "CLIENT REPLY OFF", "HELLO 2",
               "CLIENT REPLY ON", "GET nokey"]),
    ]),
    ("nulls and doubles", [
        ("a", ["HELLO 3", "GET nokey", "MGET k nokey", "LPOP nokey", "LPOP nokey 3", "RPOPLPUSH nokey x",
               "LINDEX nokey 0", "HGET nokey f", "HMGET nokey f g", "ZSCORE nokey m", "ZRANK nokey m",
               "SRANDMEMBER nokey", "SPOP nokey", "OBJECT ENCODING nokey", "RANDOMKEY", "GETDEL nokey",
               "ZADD z 1.5 a 2 b 0.1 c inf d", "ZADD z -inf e", "ZSCORE z a", "ZSCORE z c", "ZSCORE z d",
               "ZSCORE z e", "ZMSCORE z a nokey d", "ZINCRBY z 1 a", "ZADD z INCR 2.25 b",
               "ZADD z NX INCR 1 a", "INCRBYFLOAT f 1.5", "HINCRBYFLOAT h f 0.1", "LPOS nokey a",
               "BITFIELD bf SET u8 0 255 GET u8 0 INCRBY u8 0 10 OVERFLOW FAIL INCRBY u8 0 300"]),
    ]),
    ("maps, sets and pairs", [
        ("a", ["HELLO 3", "HSET h a 1 b 2 c 3", "HGETALL h", "HGETALL nokey", "HKEYS h", "HVALS h",
               "HRANDFIELD h 3 WITHVALUES", "HRANDFIELD h 0 WITHVALUES",
               "SADD s 5 3 1 8 2", "SMEMBERS s", "SMEMBERS nokey", "SINTER s s", "SUNION s nokey",
               "SDIFF s nokey", "SPOP nokey 2", "SPOP s 0", "SINTERCARD 1 s", "SMISMEMBER s 3 x",
               "SADD t x", "SPOP t 5",
               "ZADD z 1 a 2 b 3 c", "ZRANGE z 0 -1 WITHSCORES", "ZRANGE z 0 -1", "ZREVRANGE z 0 1 WITHSCORES",
               "ZRANGEBYSCORE z -inf +inf WITHSCORES LIMIT 1 1", "ZRANGEBYLEX z - +", "ZRANGE z 0 -1 REV WITHSCORES",
               "ZUNION 2 z z WITHSCORES", "ZINTER 1 z WITHSCORES", "ZDIFF 1 z WITHSCORES", "ZDIFF 1 z",
               "ZRANDMEMBER z 3 WITHSCORES",
               "ZPOPMIN z", "ZPOPMIN z 1", "ZPOPMAX z 0", "ZPOPMAX z 9", "ZPOPMIN nokey", "ZPOPMIN nokey 2",
               "ZADD z 1 a 2 b", "ZMPOP 1 z MIN", "ZMPOP 1 z MAX COUNT 5", "ZMPOP 1 nokey MIN",
               "RPUSH l a b c", "LMPOP 1 l LEFT COUNT 2", "LMPOP 1 nokey LEFT", "LPOS l c COUNT 0",
               "SET s1 ohmytext", "SET s2 mynewtext", "LCS s1 s2 IDX", "LCS s1 s2 IDX MINMATCHLEN 4 WITHMATCHLEN",
               "LCS s1 s2 LEN", "SCAN 0 COUNT 100 MATCH s1"]),
    ]),
    ("server replies", [
        ("a", ["HELLO 3", "CONFIG GET maxmemory", "CONFIG GET nosuchparam", "CONFIG GET maxmemory-policy",
               "CLIENT TRACKINGINFO", "CLIENT GETREDIR", "CLIENT INFO", "CLIENT LIST ID 999999",
               "OBJECT HELP", "MEMORY USAGE nokey", "COMMAND INFO get set zadd hello", "COMMAND INFO nosuch",
               "COMMAND DOCS get zadd", "COMMAND DOCS nosuch", "COMMAND GETKEYSANDFLAGS set k v",
               "COMMAND GETKEYSANDFLAGS lmove a b left right"]),
        ("a", ["HELLO 2", "CONFIG GET maxmemory", "CLIENT TRACKINGINFO", "CLIENT INFO", "COMMAND DOCS get",
               "COMMAND INFO hello"]),
    ]),
    ("EXEC's replies", [
        ("a", ["HELLO 3", "ZADD z 1.5 a", "HSET h f v", "MULTI", "ZSCORE z a", "HGETALL h", "SMEMBERS nokey",
               "GET nokey", "LPOP nokey 2", "ZRANGE z 0 -1 WITHSCORES", "EXEC"]),
        ("b", ["WATCH k"]),
        ("c", ["SET k changed"]),
        ("b", ["HELLO 3", "MULTI", "GET k", "EXEC", "MULTI", "BLPOP nokey 0", "EXEC"]),
    ]),
    ("blocking commands", [
        ("a", ["HELLO 3", "BLPOP nokey 0.1", "BRPOPLPUSH nokey x 0.1", "BLMOVE nokey x LEFT LEFT 0.1",
               "BLMPOP 0.1 1 nokey LEFT", "BZPOPMIN nokey 0.1", "BZMPOP 0.1 1 nokey MIN"]),
        ("w!", ["HELLO 3", "BZPOPMIN z 5"]),
        ("p", ["ZADD z 7.5 m"]),
        ("w", []),
        ("w!", ["BZMPOP 5 1 z MAX COUNT 2"]),
        ("p", ["ZADD z 1 a 2.5 b 3 c"]),
        ("w", []),
        ("w!", ["BLMPOP 5 1 l LEFT COUNT 2"]),
        ("p", ["RPUSH l x y z"]),
        ("w", []),
    ]),
    ("Pub/Sub's pushes", [
        ("a", ["HELLO 3", "SUBSCRIBE ch1 ch2", "PSUBSCRIBE c*", "SSUBSCRIBE sh"]),
        ("b", ["SUBSCRIBE ch1"]),
        ("p", ["PUBLISH ch1 hello", "SPUBLISH sh shard", "PUBSUB NUMSUB ch1 ch2 none", "PUBSUB CHANNELS ch1"]),
        ("a", []),
        ("b", []),
        ("a", ["SET k v", "GET k", "PING", "PING x", "PUBLISH ch2 self", "GET k", "ECHO e"]),
        ("b", ["GET k", "PING", "PING x"]),
        ("a", ["UNSUBSCRIBE ch2", "PUNSUBSCRIBE", "SUNSUBSCRIBE", "UNSUBSCRIBE", "UNSUBSCRIBE", "PING"]),
        ("a", ["SUBSCRIBE x", "RESET", "PING", "CLIENT INFO"]),
    ]),
    ("a client with a subscription that switches its protocol", [
        ("a", ["HELLO 3", "SUBSCRIBE ch", "PSUBSCRIBE c*"]),
        ("p", ["PUBLISH ch one"]),
        ("a", ["HELLO 2", "PING"]),
        ("p", ["PUBLISH ch two"]),
        ("a", ["GET k"]),
        ("a", ["HELLO 3"]),
        ("p", ["PUBLISH ch three"]),
        ("a", ["GET k"]),
    ]),
    ("keyspace events of a RESP3 client's own commands", [
        ("a", ["HELLO 3", "CONFIG SET notify-keyspace-events KEA", "SUBSCRIBE __keyspace@0__:k __keyevent@0__:del"]),
        ("a", ["GET k", "SET k v", "INCR n", "DEL k", "GET k", "EXPIRE nokey 10"]),
        ("o", ["SET k w"]),
        ("a", []),
    ]),
    ("own pushes in a transaction and a script", [
        ("a", ["HELLO 3", "CONFIG SET notify-keyspace-events KEA", "SUBSCRIBE ch __keyspace@0__:k", "PSUBSCRIBE c*"]),
        ("a", ["MULTI", "PUBLISH ch x", "SET k 1", "PING", "PUBLISH ch y", "EXEC", "PING"]),
        ("a", ["EVAL redis.call('PUBLISH','ch','z');return(redis.call('INCR','k')) 0", "PING"]),
        ("a", ["MULTI", "EVAL redis.call('PUBLISH','ch','w');return(1) 0", "PUBLISH ch v", "INCR k", "EXEC", "PING"]),
        ("b", ["PUBLISH ch other"]),
        ("a", ["PING"]),
    ]),
    ("own pushes of a pop served", [
        ("a", ["HELLO 3", "CONFIG SET notify-keyspace-events KEA", "SUBSCRIBE __keyspace@0__:l"]),
        ("w!", ["HELLO 3", "BLPOP l 5"]),
        ("a", ["RPUSH l x y", "PING"]),
        ("w", []),
        ("v!", ["HELLO 3", "SUBSCRIBE __keyspace@0__:m", "BLMOVE m n LEFT RIGHT 5"]),
        ("a", ["RPUSH m z"]),
        ("v", ["PING"]),
    ]),
    ("pipelines of the fast way in RESP3", [
        ("a", ["HELLO 3"] + ["SET k%d %d" % (i, i) for i in range(20)] + ["GET k%d" % i for i in range(25)]
              + ["INCR k3", "INCR nokey", "MGET k1 nokey k2", "DEL k1 k2", "EXISTS k1 k3"]),
    ]),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, default=6380)
    ap.add_argument("--redis", type=int, default=6390)
    a = ap.parse_args()
    for name, steps in SCENARIOS:
        check(name, steps, a)
    if bad:
        sys.exit("FAIL: %d of %d scenarios" % (bad, n))
    print("OK: %d RESP3 scenarios, each answered as Redis answers it" % n)


if __name__ == "__main__":
    main()
