#!/usr/bin/env python3
"""GEOADD, GEOPOS, GEOHASH, GEODIST, GEORADIUS, GEORADIUSBYMEMBER, their
_RO forms, GEOSEARCH and GEOSEARCHSTORE against Redis: the cases of
Redis's unit/geo and of geo.c (GEOADD's options and its errors, a
position's text, the searches' options, their errors and the order they
come in, a key not there and one of another kind, STORE and STOREDIST,
COUNT and ANY, ASC and DESC, points at the same distance, which pqsort
leaves in an order of its own, boxes across the antimeridian and toward
the poles), then random sets and random searches. Every reply is
compared, byte for byte, in RESP2 and in RESP3, and after each write the
sorted set it leaves (ZRANGE with its scores) and its time to live. Then
the keyspace events of the writes, MULTI, COMMAND GETKEYS and INFO's
statistics of the commands.

    python3 tests/geo_test.py --bendkv 6380 --redis 6390 [--rounds 300] [--seed 1]
"""
import argparse
import random
import sys

from diff_test import Conn

bad = 0
n = 0


def run(c, cmd):
    c.send([cmd])
    return c.reply()


def fail(cmd, x, y):
    global bad
    bad += 1
    if bad <= 25:
        print("FAIL: %r: BendKV %r, Redis %r" % (b" ".join(cmd)[:240], str(x)[:400], str(y)[:400]))


def same(b, r, cmd):
    global n
    n += 1
    x, y = run(b, cmd), run(r, cmd)
    if x != y:
        fail(cmd, x, y)
    return y


def both(b, r, cmd):
    run(b, cmd)
    run(r, cmd)


def ttl_of(rep):
    v = int(rep[1])
    return v if v < 0 else (v + 500) // 1000


# a write, then the sorted sets it may have changed read back
def write(b, r, cmd, keys):
    global n
    same(b, r, cmd)
    for k in keys:
        same(b, r, [b"TYPE", k])
        same(b, r, [b"ZRANGE", k, b"0", b"-1", b"WITHSCORES"])
        n += 1
        x, y = run(b, [b"PTTL", k]), run(r, [b"PTTL", k])
        if ttl_of(x) != ttl_of(y):
            fail([b"PTTL", k], x, y)


def cmd(*xs):
    return [x if isinstance(x, bytes) else str(x).encode() for x in xs]


NYC = cmd("GEOADD", "nyc", -73.9454966, 40.747533, "lic market", -73.9733487, 40.7648057,
          "central park n/q/r", -73.9903085, 40.7362513, "union square", -74.0131604, 40.7126674,
          "wtc one", -73.7858139, 40.6428986, "jfk", -73.9375699, 40.7498929, "q4",
          -73.9564142, 40.7480973, "4545")

SICILY = cmd("GEOADD", "Sicily", "13.361389", "38.115556", "Palermo", "15.087269", "37.502669", "Catania")


def geoadd(b, r):
    k = b"g"
    both(b, r, [b"DEL", k, b"s", b"l"])
    write(b, r, cmd("GEOADD", k, "-122.4194", "37.7749", "SF"), [k])
    write(b, r, cmd("GEOADD", k, "-122.4194", "37.7749", "SF"), [k])
    write(b, r, cmd("GEOADD", k, "-122.4194", "37.7748", "SF"), [k])
    write(b, r, cmd("GEOADD", k, "CH", "-122.4194", "37.7747", "SF", "-121", "37", "x"), [k])
    write(b, r, cmd("GEOADD", k, "NX", "-122.4194", "37.7746", "SF", "-121.5", "37", "y"), [k])
    write(b, r, cmd("GEOADD", k, "XX", "-122.4194", "37.7745", "SF", "-121.5", "37", "z"), [k])
    write(b, r, cmd("GEOADD", k, "CH", "NX", "-122.4194", "37.7744", "SF", "-121.6", "37", "w"), [k])
    write(b, r, cmd("GEOADD", k, "ch", "xx", "-122.4194", "37.7743", "SF", "-121.7", "37", "v"), [k])
    write(b, r, cmd("GEOADD", k, "xx", "ch", "XX", "-122.4194", "37.7743", "SF"), [k])
    write(b, r, cmd("GEOADD", k, "NX", "XX", "-122.4194", "37.7743", "SF"), [k])
    write(b, r, cmd("GEOADD", k, "XX", "NX", "CH", "-122.4194", "37.7743", "SF"), [k])
    write(b, r, cmd("GEOADD", k, "GT", "-122.4194", "37.7743", "SF"), [k])
    write(b, r, cmd("GEOADD", k, "LT", "1", "2", "3"), [k])
    write(b, r, cmd("GEOADD", k, "INCR", "1", "2", "3"), [k])
    write(b, r, cmd("GEOADD", k, "CH", "CH", "CH"), [k])
    write(b, r, cmd("GEOADD", k, "NX", "CH", "XX"), [k])
    write(b, r, cmd("GEOADD", k, "1", "2", "a", "3"), [k])
    write(b, r, cmd("GEOADD", k, "1", "2", "a", "3", "4"), [k])
    write(b, r, cmd("GEOADD", k, "1", "2"), [k])
    write(b, r, cmd("GEOADD", k), [k])
    write(b, r, cmd("GEOADD"), [k])
    # the positions' errors, the first one that does not read, %f's text
    for lon, lat in [("200", "100"), ("-200", "0"), ("0", "-86"), ("180.0000001", "0"),
                     ("-180.0000001", "-0"), ("1e300", "-1e-7"), ("-0.0000004", "91"),
                     ("0.0000005", "85.06"), ("inf", "0"), ("0", "-inf"), ("-inf", "inf"),
                     ("123.4567895", "86.0000015"), ("1e-320", "-90.0000025"),
                     ("4.9e-324", "100"), ("-1.7976931348623157e308", "1"), ("0x1p8", "0"),
                     ("1e400", "0"), ("1e-400", "0"), ("nan", "0"), ("0", "NaN"), (" 1", "0"),
                     ("1 ", "0"), ("", "0"), ("1\x00", "0"), ("abc", "0"), ("0", "x"),
                     ("+5", "+5"), ("-0", "-0"), ("0x10", "0x1p-2"), ("1e1", "1E1"),
                     ("180", "85.05112878"), ("-180", "-85.05112878"), ("85.05112879", "85.05112879")]:
        write(b, r, cmd("GEOADD", k, lon, lat, "p" + lon + lat), [k])
    write(b, r, cmd("GEOADD", k, "1", "2", "ok", "300", "2", "bad", "x", "2", "bad2"), [k])
    write(b, r, cmd("GEOADD", k, "1", "2", "ok", "x", "2", "bad", "300", "2", "bad2"), [k])
    write(b, r, cmd("GEOADD", k, "NX", "XX", "x", "2", "bad"), [k])
    write(b, r, cmd("GEOADD", k, "1", "2", "ok", "3"), [k])
    # members of every kind
    write(b, r, cmd("GEOADD", k, "1", "2", "", "1", "2", "123", "1", "2", "-0", "1", "2", "\x00\xff",
                    "1", "2", "x" * 70), [k])
    # the type
    both(b, r, cmd("SET", "s", "v"))
    both(b, r, cmd("RPUSH", "l", "a"))
    for key in (b"s", b"l"):
        write(b, r, cmd("GEOADD", key, "1", "2", "m"), [key])
        write(b, r, cmd("GEOADD", key, "1", "200", "m"), [key])
        write(b, r, cmd("GEOADD", key, "1", "2"), [key])
    # a time to live, kept by GEOADD
    both(b, r, cmd("PEXPIRE", k, "100000"))
    write(b, r, cmd("GEOADD", k, "1", "3", "ttl"), [k])
    # new keys made, and big ones
    both(b, r, cmd("DEL", "big"))
    xs = []
    rnd = random.Random(3)
    for i in range(300):
        xs += [repr(rnd.uniform(-180, 180)), repr(rnd.uniform(-85, 85)), "m%d" % i]
    write(b, r, cmd("GEOADD", "big", *xs), [b"big"])


def reads(b, r):
    both(b, r, cmd("DEL", "Sicily", "nyc", "s"))
    same(b, r, SICILY)
    same(b, r, NYC)
    both(b, r, cmd("SET", "s", "v"))
    same(b, r, cmd("GEODIST", "Sicily", "Palermo", "Catania"))
    for unit in ("m", "km", "KM", "Km", "ft", "FT", "mi", "MI", "mm", "", "k", "m\x00x", "m "):
        same(b, r, cmd("GEODIST", "Sicily", "Palermo", "Catania", unit))
        same(b, r, cmd("GEODIST", "nokey", "Palermo", "Catania", unit))
        same(b, r, cmd("GEODIST", "s", "Palermo", "Catania", unit))
    for c in (cmd("GEODIST", "Sicily", "Palermo", "nope"), cmd("GEODIST", "Sicily", "nope", "Catania"),
              cmd("GEODIST", "Sicily", "Palermo", "Palermo"), cmd("GEODIST", "Sicily", "Palermo", "Catania", "km", "x"),
              cmd("GEODIST", "Sicily", "Palermo", "Catania", "foo", "x"), cmd("GEODIST", "nokey", "a", "b", "km", "x"),
              cmd("GEODIST", "s", "a", "b", "km", "x"), cmd("GEODIST", "s", "a", "b"), cmd("GEODIST", "Sicily", "a"),
              cmd("GEODIST", "Sicily"), cmd("GEODIST", "nyc", "jfk", "wtc one"), cmd("GEODIST", "nyc", "4545", "q4", "ft"),
              cmd("GEOPOS", "Sicily", "Palermo", "Catania", "nope"), cmd("GEOPOS", "Sicily"), cmd("GEOPOS", "nokey", "a", "b"),
              cmd("GEOPOS", "s", "a"), cmd("GEOPOS", "s"), cmd("GEOPOS", "nokey"), cmd("GEOPOS"),
              cmd("GEOHASH", "Sicily", "Palermo", "Catania", "nope"), cmd("GEOHASH", "Sicily"),
              cmd("GEOHASH", "nokey", "a"), cmd("GEOHASH", "s", "a"), cmd("GEOHASH", "s"), cmd("GEOHASH"),
              cmd("GEOPOS", "nyc", "lic market", "central park n/q/r", "union square", "wtc one", "jfk", "q4", "4545"),
              cmd("GEOHASH", "nyc", "lic market", "central park n/q/r", "union square", "wtc one", "jfk", "q4", "4545")):
        same(b, r, c)
    # positions at the edges, and scores no GEOADD makes
    both(b, r, cmd("DEL", "e"))
    same(b, r, cmd("GEOADD", "e", "-180", "-85.05112878", "sw", "180", "85.05112878", "ne", "0", "0", "o",
                   "-0.0000001", "-0.0000001", "neg", "179.9999999", "-85.0511287", "x"))
    same(b, r, cmd("ZADD", "e", "0", "z0", "-1", "zneg", "1.5", "zf", "4503599627370495", "top", "4503599627370496", "past",
                   "9007199254740993", "far", "1e300", "huge", "-1e300", "nhuge", "inf", "pinf", "-inf", "ninf"))
    same(b, r, cmd("GEOPOS", "e", "sw", "ne", "o", "neg", "x", "z0", "zneg", "zf", "top", "past", "far", "huge",
                   "nhuge", "pinf", "ninf"))
    same(b, r, cmd("GEOHASH", "e", "sw", "ne", "o", "neg", "x", "z0", "zneg", "zf", "top", "past", "far", "huge",
                   "nhuge", "pinf", "ninf"))
    for a, c in (("sw", "ne"), ("o", "neg"), ("z0", "top"), ("past", "far"), ("huge", "nhuge"), ("pinf", "ninf"),
                 ("o", "huge")):
        same(b, r, cmd("GEODIST", "e", a, c))
        same(b, r, cmd("GEODIST", "e", a, c, "mi"))


SEARCHES = [b"GEORADIUS", b"GEORADIUS_RO", b"GEORADIUSBYMEMBER", b"GEORADIUSBYMEMBER_RO", b"GEOSEARCH"]


def searches(b, r):
    both(b, r, cmd("DEL", "Sicily", "nyc", "s", "points", "users", "dst"))
    same(b, r, SICILY)
    same(b, r, NYC)
    both(b, r, cmd("SET", "s", "v"))
    # unit/geo's searches
    for c in (cmd("GEORADIUS", "nyc", "-73.9798091", "40.7598464", "3", "km", "asc"),
              cmd("GEORADIUS_RO", "nyc", "-73.9798091", "40.7598464", "3", "km", "asc"),
              cmd("GEOSEARCH", "nyc", "fromlonlat", "-73.9798091", "40.7598464", "bybox", "6", "6", "km", "asc"),
              cmd("GEOSEARCH", "nyc", "fromlonlat", "-73.9798091", "40.7598464", "bybox", "6", "6", "km", "asc", "withdist"),
              cmd("GEORADIUS", "nyc", "-73.9798091", "40.7598464", "3", "km", "withdist", "asc"),
              cmd("GEORADIUS", "nyc", "-73.9798091", "40.7598464", "10", "km", "COUNT", "3"),
              cmd("GEORADIUS", "nyc", "-73.9798091", "40.7598464", "10", "km", "WITHDIST", "WITHHASH", "WITHCOORD",
                  "WITHDIST", "WITHHASH", "WITHCOORD", "COUNT", "3"),
              cmd("GEORADIUS", "nyc", "-73.9798091", "40.7598464", "10", "km", "COUNT", "3", "ANY"),
              cmd("GEORADIUS", "nyc", "-73.9798091", "40.7598464", "10", "km", "COUNT", "3", "ANY", "ASC"),
              cmd("GEORADIUS", "nyc", "-73.9798091", "40.7598464", "10", "km", "ANY"),
              cmd("GEORADIUS", "nyc", "-73.9798091", "40.7598464", "10", "km", "COUNT"),
              cmd("GEORADIUS", "nyc", "-73.9798091", "40.7598464", "10", "km", "COUNT", "2", "DESC"),
              cmd("GEORADIUS", "nyc", "-73.9798091", "40.7598464", "500", "km", "COUNT", "3", "DESC"),
              cmd("GEORADIUS", "nyc", "-73.9798091", "40.7598464", "10000", "km", "withdist", "count", "2"),
              cmd("GEORADIUSBYMEMBER", "nyc", "wtc one", "7", "km"),
              cmd("GEORADIUSBYMEMBER_RO", "nyc", "wtc one", "7", "km"),
              cmd("GEOSEARCH", "nyc", "frommember", "wtc one", "bybox", "14", "14", "km"),
              cmd("GEORADIUSBYMEMBER", "nyc", "wtc one", "7", "km", "withdist"),
              cmd("GEOSEARCH", "nyc", "frommember", "wtc one", "byradius", "7", "km", "withdist", "withcoord", "withhash"),
              cmd("GEOSEARCH", "nyc", "fromlonlat", "-73.9798091", "40.7598464", "bybox", "200", "200", "km", "asc"),
              cmd("GEOSEARCH", "nyc", "fromlonlat", "-73.9798091", "40.7598464", "byradius", "200", "km", "asc"),
              cmd("GEOSEARCH", "nyc", "fromlonlat", "-73.9798091", "40.7598464", "bybox", "2", "40", "km", "asc"),
              cmd("GEOSEARCH", "nyc", "fromlonlat", "-73.9798091", "40.7598464", "bybox", "40", "2", "km", "desc"),
              cmd("GEOSEARCH", "Sicily", "FROMLONLAT", "15", "37", "BYBOX", "400", "400", "km", "ASC", "WITHCOORD", "WITHDIST"),
              cmd("GEORADIUS", "Sicily", "15", "37", "200", "km", "WITHDIST", "WITHCOORD", "WITHHASH", "ASC")):
        same(b, r, c)
    # the box across the antimeridian, and small distances
    same(b, r, cmd("GEOADD", "points", "179.5", "36", "point1", "-179.5", "36", "point2"))
    for c in (cmd("GEOSEARCH", "points", "FROMLONLAT", "179", "36", "BYBOX", "400", "400", "km", "ASC"),
              cmd("GEOSEARCH", "points", "FROMLONLAT", "-179", "36", "BYBOX", "400", "400", "km", "ASC"),
              cmd("GEOSEARCH", "points", "FROMLONLAT", "180", "36", "BYRADIUS", "200", "km", "DESC", "WITHCOORD")):
        same(b, r, c)
    same(b, r, cmd("GEOADD", "users", "-47.271613776683807", "-54.534504198047678", "user1",
                   "-47.271613776683807", "-54.534504198047678", "user2"))
    for c in (cmd("GEOSEARCH", "users", "FROMMEMBER", "user1", "BYRADIUS", "0.0001", "m", "WITHDIST"),
              cmd("GEOSEARCH", "users", "FROMMEMBER", "user1", "BYBOX", "0", "0", "m", "WITHDIST", "WITHHASH"),
              cmd("GEORADIUS", "users", "-47.271613776683807", "-54.534504198047678", "0", "km")):
        same(b, r, c)
    # toward the poles, and huge radii
    both(b, r, cmd("DEL", "pole"))
    same(b, r, cmd("GEOADD", "pole", "0", "85", "a", "90", "85", "b", "180", "85", "c", "-90", "85", "d", "45", "84", "e",
                   "0", "-85", "s", "0", "67", "f", "10", "81", "g"))
    for c in (cmd("GEORADIUSBYMEMBER", "pole", "a", "1000", "km", "WITHDIST", "ASC"),
              cmd("GEORADIUS", "pole", "0", "85", "2000", "km", "WITHDIST", "DESC"),
              cmd("GEORADIUS", "pole", "0", "0", "20000", "km", "ASC", "WITHDIST"),
              cmd("GEORADIUS", "pole", "0", "0", "100000", "km", "COUNT", "3", "WITHDIST"),
              cmd("GEORADIUS", "pole", "0", "0", "1e300", "m", "ASC"),
              cmd("GEORADIUS", "pole", "0", "0", "inf", "m", "ASC"),
              cmd("GEORADIUS", "pole", "0", "0", "4.9e-324", "m", "ASC"),
              cmd("GEORADIUS", "pole", "0", "0", "0", "m", "ASC"),
              cmd("GEOSEARCH", "pole", "FROMLONLAT", "0", "0", "BYBOX", "inf", "1", "km", "ASC"),
              cmd("GEOSEARCH", "pole", "FROMLONLAT", "0", "84", "BYBOX", "5000", "5000", "km", "DESC", "WITHDIST"),
              cmd("GEOSEARCH", "pole", "FROMMEMBER", "s", "BYRADIUS", "20000", "km", "WITHDIST", "WITHHASH", "COUNT", "2")):
        same(b, r, c)
    # the errors, and their order: the key's type first, then the
    # center and the radius (GEORADIUSBYMEMBER's when the key is there),
    # then each option in turn, then the checks after them
    centers = {b"GEORADIUS": cmd("15", "37", "200", "km"), b"GEORADIUS_RO": cmd("15", "37", "200", "km"),
               b"GEORADIUSBYMEMBER": cmd("Palermo", "200", "km"), b"GEORADIUSBYMEMBER_RO": cmd("Palermo", "200", "km"),
               b"GEOSEARCH": cmd("FROMLONLAT", "15", "37", "BYRADIUS", "200", "km")}
    bads = [cmd("200", "37", "200", "km"), cmd("x", "37", "200", "km"), cmd("15", "x", "200", "km"),
            cmd("15", "37", "-1", "km"), cmd("15", "37", "x", "km"), cmd("15", "37", "200", "yd"),
            cmd("15", "37", "-0", "km"), cmd("15", "37", "1e400", "km"), cmd("15", "37", "nan", "km"),
            cmd("Nope", "200", "km"), cmd("Palermo", "-1", "km"), cmd("Palermo", "x", "x"), cmd("Palermo", "1", "x"),
            cmd("Nope", "x", "x"), cmd("FROMLONLAT", "200", "37", "BYRADIUS", "1", "km"),
            cmd("FROMMEMBER", "Nope", "BYRADIUS", "1", "km"), cmd("FROMMEMBER", "Palermo", "BYRADIUS", "-1", "km"),
            cmd("FROMMEMBER", "Palermo", "BYBOX", "-1", "1", "km"), cmd("FROMMEMBER", "Palermo", "BYBOX", "1", "-1", "km"),
            cmd("FROMMEMBER", "Palermo", "BYBOX", "x", "-1", "km"), cmd("FROMMEMBER", "Palermo", "BYBOX", "-1", "x", "km"),
            cmd("FROMMEMBER", "Palermo", "BYBOX", "1", "1", "x"), cmd("FROMMEMBER", "Palermo", "BYBOX", "1", "1"),
            cmd("FROMMEMBER", "Palermo", "FROMLONLAT", "15", "37", "BYRADIUS", "1", "km"),
            cmd("FROMLONLAT", "15", "37", "FROMMEMBER", "Palermo", "BYRADIUS", "1", "km"),
            cmd("FROMLONLAT", "15", "37", "FROMLONLAT", "15.1", "37.1", "BYRADIUS", "1", "km", "BYRADIUS", "200", "km"),
            cmd("FROMMEMBER", "Catania", "FROMMEMBER", "Palermo", "BYRADIUS", "200", "km"),
            cmd("FROMLONLAT", "15", "37", "BYRADIUS", "1", "km", "BYBOX", "1", "1", "km"),
            cmd("FROMLONLAT", "15", "37", "BYBOX", "1", "1", "km", "BYRADIUS", "1", "km"),
            cmd("FROMLONLAT", "15", "37"), cmd("BYRADIUS", "1", "km"), cmd("FROMLONLAT", "15"), cmd("BYRADIUS", "1"),
            cmd("FROMMEMBER"), cmd("x"), cmd("FROMLONLAT", "15", "37", "BYRADIUS", "200", "km", "WITHDIST", "STORE", "d")]
    opts = [cmd(), cmd("COUNT", "0"), cmd("COUNT", "-1"), cmd("COUNT", "x"), cmd("COUNT", "1.5"), cmd("COUNT"),
            cmd("COUNT", "9223372036854775807"), cmd("COUNT", "9223372036854775808"), cmd("COUNT", "-0"),
            cmd("ANY"), cmd("ANY", "COUNT", "1"), cmd("COUNT", "1", "ANY", "DESC"), cmd("ASC", "DESC"), cmd("DESC", "ASC"),
            cmd("WITHDIST", "STORE", "dst"), cmd("STORE", "dst", "WITHHASH"), cmd("WITHCOORD", "STOREDIST", "dst"),
            cmd("STORE"), cmd("STOREDIST"), cmd("STORE", "dst", "STOREDIST"), cmd("foo"), cmd("COUNT", "0", "foo"),
            cmd("foo", "COUNT", "0"), cmd("ANY", "foo"), cmd("STORE", "dst", "COUNT", "0"), cmd("COUNT", "0", "STORE", "dst"),
            cmd("withdist", "WithHash", "WITHCOORD", "aSc"), cmd("count", "1", "any"), cmd("WITHDIST\x00x"),
            cmd("FROMLONLAT", "15", "37"), cmd("BYRADIUS", "1", "km"), cmd("FROMMEMBER", "Palermo"),
            cmd("BYBOX", "1", "1", "km")]
    for name in SEARCHES:
        for key in (b"Sicily", b"nokey", b"s"):
            for o in opts:
                same(b, r, [name, key] + centers[name] + o)
        for x in bads:
            for key in (b"Sicily", b"nokey", b"s"):
                same(b, r, [name, key] + x)
        same(b, r, [name])
        same(b, r, [name, b"Sicily"])
        same(b, r, [name, b"Sicily"] + centers[name][:-1])
    for c in (cmd("geosearch", "Sicily", "FROMLONLAT", "15", "37"), cmd("GeoSearch", "Sicily", "BYRADIUS", "1", "km"),
              cmd("geosearchstore", "d", "Sicily", "BYRADIUS", "1", "km"),
              cmd("GEOSEARCHSTORE", "d", "Sicily", "FROMLONLAT", "15", "37")):
        same(b, r, c)


def stores(b, r):
    both(b, r, cmd("DEL", "Sicily", "nyc", "s", "dst", "d2"))
    same(b, r, SICILY)
    same(b, r, NYC)
    both(b, r, cmd("SET", "s", "v"))
    d = b"dst"
    for c in (cmd("GEORADIUS", "nyc", "-73.9798091", "40.7598464", "3", "km", "STORE", d),
              cmd("GEORADIUS", "nyc", "-73.9798091", "40.7598464", "3", "km", "STOREDIST", d),
              cmd("GEORADIUS", "nyc", "-73.9798091", "40.7598464", "3", "km", "STOREDIST", d, "COUNT", "2"),
              cmd("GEORADIUS", "nyc", "-73.9798091", "40.7598464", "3", "km", "STOREDIST", d, "COUNT", "2", "DESC"),
              cmd("GEORADIUS", "nyc", "-73.9798091", "40.7598464", "3", "mi", "STORE", b"x", "STOREDIST", d),
              cmd("GEORADIUS", "nyc", "-73.9798091", "40.7598464", "3", "ft", "STOREDIST", b"x", "STORE", d),
              cmd("GEORADIUS", "nyc", "-73.9798091", "40.7598464", "3", "km", "STORE", d, "ANY", "COUNT", "1"),
              cmd("GEORADIUSBYMEMBER", "nyc", "wtc one", "7", "km", "STORE", d),
              cmd("GEORADIUSBYMEMBER", "nyc", "wtc one", "7", "km", "STOREDIST", d),
              cmd("GEORADIUSBYMEMBER", "nyc", "wtc one", "7", "km", "STOREDIST", d, "COUNT", "1"),
              cmd("GEOSEARCHSTORE", d, "nyc", "FROMLONLAT", "-73.9798091", "40.7598464", "BYBOX", "6", "6", "km"),
              cmd("GEOSEARCHSTORE", d, "nyc", "FROMLONLAT", "-73.9798091", "40.7598464", "BYBOX", "6", "6", "km", "STOREDIST"),
              cmd("GEOSEARCHSTORE", d, "nyc", "FROMLONLAT", "-73.9798091", "40.7598464", "BYBOX", "6", "6", "mi",
                  "STOREDIST", "STOREDIST", "COUNT", "2", "DESC"),
              cmd("GEOSEARCHSTORE", d, "nyc", "FROMMEMBER", "jfk", "BYRADIUS", "1", "m"),
              cmd("GEOSEARCHSTORE", d, "nyc", "FROMMEMBER", "jfk", "BYRADIUS", "1", "m", "STOREDIST"),
              cmd("GEOSEARCHSTORE", d, "nyc", "FROMLONLAT", "0", "0", "BYRADIUS", "1", "m"),
              cmd("GEOSEARCHSTORE", d, "nokey", "FROMLONLAT", "0", "0", "BYRADIUS", "1", "m"),
              cmd("GEORADIUS", "nokey", "0", "0", "1", "m", "STORE", d),
              cmd("GEORADIUSBYMEMBER", "nokey", "x", "1", "m", "STORE", d),
              cmd("GEORADIUS", "nyc", "0", "0", "1", "m", "STORE", d)):
        same(b, r, SICILY)
        write(b, r, c, [d, b"x"])
        write(b, r, c, [d, b"x"])
    # the destination of another kind, with a time to live, the source itself
    for c in (cmd("GEORADIUS", "Sicily", "15", "37", "200", "km", "STORE", "s"),
              cmd("GEOSEARCHSTORE", "s", "Sicily", "FROMLONLAT", "15", "37", "BYRADIUS", "200", "km")):
        both(b, r, cmd("SET", "s", "v", "EX", "1000"))
        write(b, r, c, [b"s"])
    both(b, r, cmd("SET", "s", "v"))
    both(b, r, cmd("DEL", "Sicily2"))
    same(b, r, cmd("GEOADD", "Sicily2", "13.361389", "38.115556", "Palermo", "15.087269", "37.502669", "Catania"))
    both(b, r, cmd("PEXPIRE", "Sicily2", "1000000"))
    write(b, r, cmd("GEORADIUS", "Sicily2", "15", "37", "100", "km", "STORE", "Sicily2"), [b"Sicily2"])
    write(b, r, cmd("GEOSEARCHSTORE", "Sicily2", "Sicily2", "FROMLONLAT", "15", "37", "BYRADIUS", "1", "km"), [b"Sicily2"])
    # errors write nothing
    for c in (cmd("GEORADIUS", "s", "15", "37", "200", "km", "STORE", d), cmd("GEORADIUS", "Sicily", "15", "37", "x", "km", "STORE", d),
              cmd("GEORADIUS", "Sicily", "15", "37", "200", "km", "STORE", d, "WITHDIST"),
              cmd("GEORADIUS", "Sicily", "15", "37", "200", "km", "STORE", d, "COUNT", "0"),
              cmd("GEORADIUS_RO", "Sicily", "15", "37", "200", "km", "STORE", d),
              cmd("GEOSEARCH", "Sicily", "FROMLONLAT", "15", "37", "BYRADIUS", "200", "km", "STORE", d),
              cmd("GEOSEARCH", "Sicily", "FROMLONLAT", "15", "37", "BYRADIUS", "200", "km", "STOREDIST"),
              cmd("GEOSEARCHSTORE", d, "Sicily", "FROMLONLAT", "15", "37", "BYRADIUS", "200", "km", "STORE", "x"),
              cmd("GEOSEARCHSTORE", d, "Sicily", "FROMLONLAT", "15", "37", "BYRADIUS", "200", "km", "WITHCOORD"),
              cmd("GEOSEARCHSTORE", d, "s", "FROMLONLAT", "15", "37", "BYRADIUS", "200", "km"),
              cmd("GEOSEARCHSTORE", d, "Sicily", "FROMMEMBER", "Nope", "BYRADIUS", "200", "km"),
              cmd("GEOSEARCHSTORE", d, "Sicily", "FROMLONLAT", "15", "37", "BYRADIUS", "200", "km", "ANY"),
              cmd("GEOSEARCHSTORE", d), cmd("GEOSEARCHSTORE", d, "Sicily", "FROMLONLAT", "15", "37", "BYRADIUS")):
        same(b, r, cmd("GEORADIUS", "Sicily", "15", "37", "200", "km", "STORE", d))
        write(b, r, c, [d])


def ties(b, r):
    """points at the same distance: glibc's qsort keeps the order found,
    pqsort (COUNT under the points found) its own"""
    k = b"tie"
    both(b, r, cmd("DEL", k, "dst"))
    xs = []
    for i in range(60):
        xs += ["10", "10", "a%02d" % i]
    for i in range(30):
        xs += ["10.001", "10", "b%02d" % i]
    for i in range(45):
        xs += ["9.999", "10", "c%02d" % i]
    for i in range(10):
        xs += ["10", "10.002", "d%02d" % i]
    same(b, r, cmd("GEOADD", k, *xs))
    for order in ([], [b"ASC"], [b"DESC"]):
        for count in ([], [b"COUNT", b"1"], [b"COUNT", b"2"], [b"COUNT", b"7"], [b"COUNT", b"8"], [b"COUNT", b"40"],
                      [b"COUNT", b"41"], [b"COUNT", b"100"], [b"COUNT", b"144"], [b"COUNT", b"145"], [b"COUNT", b"500"],
                      [b"COUNT", b"10", b"ANY"]):
            same(b, r, cmd("GEORADIUS", k, "10", "10", "100", "km") + order + count)
            same(b, r, cmd("GEOSEARCH", k, "FROMLONLAT", "10.0005", "10", "BYBOX", "300", "300", "km", "WITHDIST")
                 + order + count)
            write(b, r, cmd("GEORADIUS", k, "10.0002", "10", "100", "km", "STOREDIST", "dst") + order + count, [b"dst"])


def events(b, r):
    """the keyspace events of the writes, as a subscriber of every channel
    gets them (up to a marker published after each)"""
    bs, rs = Conn(b.port, False), Conn(r.port, False)
    both(b, r, cmd("CONFIG", "SET", "notify-keyspace-events", "KEA"))
    for s in (bs, rs):
        s.send([cmd("PSUBSCRIBE", "*")])
        s.reply()

    def got(s):
        out = []
        while True:
            m = s.reply()
            items = [v for _, v in m[1]]
            if items[0] == b"pmessage" and items[2] == b"mark":
                return out
            out.append(tuple(items[2:]))

    def ev(c):
        global n
        n += 1
        x, y = run(b, c), run(r, c)
        run(b, cmd("PUBLISH", "mark", "m"))
        run(r, cmd("PUBLISH", "mark", "m"))
        ex, ey = got(bs), got(rs)
        if (x, ex) != (y, ey):
            fail(c, (x, ex), (y, ey))

    both(b, r, cmd("DEL", "Sicily", "dst", "s"))
    ev(SICILY)
    ev(SICILY)
    ev(cmd("GEOADD", "Sicily", "CH", "13.361389", "38.115557", "Palermo"))
    ev(cmd("GEOADD", "Sicily", "XX", "1", "1", "new"))
    ev(cmd("GEOADD", "Sicily", "1", "100", "bad"))
    ev(cmd("GEORADIUS", "Sicily", "15", "37", "200", "km", "STORE", "dst"))
    ev(cmd("GEORADIUS", "Sicily", "15", "37", "200", "km", "STOREDIST", "dst"))
    ev(cmd("GEOSEARCHSTORE", "dst", "Sicily", "FROMLONLAT", "15", "37", "BYRADIUS", "200", "km"))
    ev(cmd("GEOSEARCHSTORE", "dst", "Sicily", "FROMLONLAT", "15", "37", "BYRADIUS", "1", "km"))
    ev(cmd("GEOSEARCHSTORE", "dst", "Sicily", "FROMLONLAT", "15", "37", "BYRADIUS", "1", "km"))
    ev(cmd("GEORADIUS", "Sicily", "15", "37", "200", "km", "STORE", "dst"))
    ev(cmd("GEORADIUS", "nokey", "15", "37", "200", "km", "STORE", "dst"))
    ev(cmd("GEORADIUS", "nokey", "15", "37", "200", "km", "STORE", "dst"))
    ev(cmd("GEORADIUS", "Sicily", "15", "37", "200", "km", "STORE", "dst", "COUNT", "0"))
    ev(cmd("GEORADIUS", "Sicily", "15", "37", "200", "km"))
    ev(cmd("SET", "s", "v"))
    ev(cmd("GEOSEARCHSTORE", "s", "Sicily", "FROMLONLAT", "15", "37", "BYRADIUS", "200", "km"))
    ev(cmd("GEOSEARCHSTORE", "dst", "s", "FROMLONLAT", "15", "37", "BYRADIUS", "200", "km"))
    both(b, r, cmd("CONFIG", "SET", "notify-keyspace-events", ""))
    for s in (bs, rs):
        s.sock.close()


def multi(b, r):
    both(b, r, cmd("DEL", "Sicily", "dst"))
    for c in (cmd("MULTI"), SICILY, cmd("GEORADIUS", "Sicily", "15", "37", "200", "km", "STORE", "dst"),
              cmd("GEOSEARCHSTORE", "d2", "dst", "FROMMEMBER", "Palermo", "BYRADIUS", "500", "km", "STOREDIST"),
              cmd("GEOADD", "Sicily", "1", "200", "x"), cmd("GEODIST", "Sicily", "Palermo", "Catania"),
              cmd("GEOSEARCH", "Sicily", "FROMMEMBER", "Catania", "BYBOX", "1000", "1000", "km", "WITHCOORD"),
              cmd("EXEC"), cmd("ZRANGE", "d2", "0", "-1", "WITHSCORES")):
        same(b, r, c)
    for c in (cmd("MULTI"), cmd("GEOADD", "Sicily", "1"), cmd("EXEC")):
        same(b, r, c)


def getkeys(b, r):
    for c in (cmd("GEORADIUS", "k", "0", "0", "1", "m"), cmd("GEORADIUS", "k", "0", "0", "1", "m", "STORE", "a"),
              cmd("GEORADIUS", "k", "0", "0", "1", "m", "STORE", "a", "STOREDIST", "b"),
              cmd("GEORADIUS", "k", "0", "0", "1", "m", "STOREDIST", "b", "STORE", "a"),
              cmd("GEORADIUS", "k", "0", "0", "1", "m", "store", "a", "STORE", "c"),
              cmd("GEORADIUS", "k", "0", "0", "1", "m", "STORE"), cmd("GEORADIUS", "k", "0", "0", "1", "m", "x", "STORE", "a"),
              cmd("GEORADIUS", "k", "0", "0", "1", "STORE", "a"), cmd("GEORADIUS", "k", "0", "0", "STORE", "a"),
              cmd("GEORADIUS", "k", "0", "0", "1", "m", "COUNT", "STORE", "a"),
              cmd("GEORADIUS", "k", "0", "0", "1", "m", "STORE\x00", "a"),
              cmd("GEORADIUS_RO", "k", "0", "0", "1", "m", "STORE", "a"),
              cmd("GEORADIUSBYMEMBER", "k", "m", "1", "m", "STORE", "a"),
              cmd("GEORADIUSBYMEMBER", "k", "m", "1", "STORE", "a"),
              cmd("GEORADIUSBYMEMBER", "k", "m", "1", "m", "STOREDIST", "b"),
              cmd("GEORADIUSBYMEMBER_RO", "k", "m", "1", "m", "STORE", "a"),
              cmd("GEOSEARCH", "k", "FROMLONLAT", "0", "0", "BYRADIUS", "1", "m"),
              cmd("GEOSEARCHSTORE", "d", "s", "FROMLONLAT", "0", "0", "BYRADIUS", "1", "m"),
              cmd("GEOADD", "k", "0", "0", "m"), cmd("GEODIST", "k", "a", "b"), cmd("GEOHASH", "k", "a"),
              cmd("GEOPOS", "k", "a"), cmd("GEOHASH", "k"), cmd("GEORADIUS", "k", "0", "0", "1")):
        same(b, r, [b"COMMAND", b"GETKEYS"] + c)
        same(b, r, [b"COMMAND", b"GETKEYSANDFLAGS"] + c)
    for name in (b"geoadd", b"geodist", b"geohash", b"geopos", b"georadius", b"georadius_ro", b"georadiusbymember",
                 b"georadiusbymember_ro", b"geosearch", b"geosearchstore"):
        same(b, r, [b"COMMAND", b"INFO", name])
        same(b, r, [b"COMMAND", b"DOCS", name])


def stats(b, r):
    """INFO's statistics of the commands: calls and failed calls"""
    global n

    def lines(c):
        rep = run(c, cmd("INFO", "commandstats"))[1].decode()
        out = []
        for l in rep.split("\r\n"):
            if l.startswith("cmdstat_geo"):
                name, rest = l.split(":", 1)
                kv = dict(x.split("=") for x in rest.split(","))
                out.append((name, kv["calls"], kv["rejected_calls"], kv["failed_calls"]))
        return out

    both(b, r, cmd("CONFIG", "RESETSTAT"))
    both(b, r, cmd("DEL", "Sicily", "s"))
    both(b, r, cmd("SET", "s", "v"))
    for c in (SICILY, cmd("GEOADD", "Sicily", "1"), cmd("GEOADD", "Sicily", "1", "100", "x"), cmd("GEOADD", "s", "1", "1", "x"),
              cmd("GEODIST", "Sicily", "Palermo", "Catania", "x"), cmd("GEODIST", "Sicily", "Palermo", "Catania"),
              cmd("GEOPOS", "s", "x"), cmd("GEOHASH", "Sicily", "Palermo"), cmd("GEORADIUS", "Sicily", "15", "37", "1", "km"),
              cmd("GEORADIUS", "Sicily", "15", "37", "x", "km"), cmd("GEORADIUS", "s", "15", "37", "1", "km"),
              cmd("GEORADIUS", "Sicily", "15", "37", "200", "km", "STORE", "d"),
              cmd("GEORADIUS", "Sicily", "15", "37", "200", "km", "STORE", "d", "WITHDIST"),
              cmd("GEORADIUS_RO", "Sicily", "15", "37", "200", "km"), cmd("GEORADIUSBYMEMBER", "Sicily", "x", "1", "km"),
              cmd("GEORADIUSBYMEMBER_RO", "Sicily", "Palermo", "1", "km"),
              cmd("GEOSEARCH", "Sicily", "FROMLONLAT", "15", "37"),
              cmd("GEOSEARCHSTORE", "d", "Sicily", "FROMLONLAT", "15", "37", "BYRADIUS", "1", "km"),
              cmd("GEOSEARCHSTORE", "d", "s", "FROMLONLAT", "15", "37", "BYRADIUS", "1", "km")):
        run(b, c)
        run(r, c)
    n += 1
    x, y = lines(b), lines(r)
    if sorted(x) != sorted(y):
        fail(cmd("INFO", "commandstats"), sorted(x), sorted(y))


def rnd_num(rnd, lo, hi):
    w = rnd.random()
    if w < 0.8:
        return repr(rnd.uniform(lo, hi)).encode()
    if w < 0.9:
        return str(rnd.randint(int(lo), int(hi))).encode()
    return rnd.choice([b"x", b"-1", b"0", b"1e400", b"inf", b"200", b"-0", b"1e-7"])


UNITS = [b"m", b"km", b"ft", b"mi", b"KM", b"Mi"]


def rnd_search(rnd, key, dst):
    """a random search of key, a STORE to dst now and then"""
    kind = rnd.choice(SEARCHES + [b"GEOSEARCHSTORE"])
    lon, lat = rnd_num(rnd, -10, 10), rnd_num(rnd, -10, 10)
    radius = rnd.choice([rnd_num(rnd, 0, 50), rnd_num(rnd, 0, 2000), rnd_num(rnd, 0, 20000)])
    unit = rnd.choice(UNITS)
    member = b"m%d" % rnd.randrange(60)
    if kind in (b"GEORADIUS", b"GEORADIUS_RO"):
        c = [kind, key, lon, lat, radius, unit]
    elif kind in (b"GEORADIUSBYMEMBER", b"GEORADIUSBYMEMBER_RO"):
        c = [kind, key, member, radius, unit]
    else:
        c = [kind] + ([dst] if kind == b"GEOSEARCHSTORE" else []) + [key]
        if rnd.random() < 0.5:
            c += [b"FROMLONLAT", lon, lat]
        else:
            c += [b"FROMMEMBER", member]
        if rnd.random() < 0.5:
            c += [b"BYRADIUS", radius, unit]
        else:
            c += [b"BYBOX", rnd_num(rnd, 0, 3000), rnd_num(rnd, 0, 3000), unit]
    opts = []
    store = kind == b"GEOSEARCHSTORE" or (kind in (b"GEORADIUS", b"GEORADIUSBYMEMBER") and rnd.random() < 0.3)
    if store and kind != b"GEOSEARCHSTORE":
        opts.append([rnd.choice([b"STORE", b"STOREDIST"]), dst])
    if store and kind == b"GEOSEARCHSTORE" and rnd.random() < 0.5:
        opts.append([b"STOREDIST"])
    if not store:
        for w in (b"WITHDIST", b"WITHHASH", b"WITHCOORD"):
            if rnd.random() < 0.3:
                opts.append([w])
    if rnd.random() < 0.5:
        opts.append([b"COUNT", str(rnd.choice([1, 2, 3, 5, 10, 50, 100, 1000])).encode()])
        if rnd.random() < 0.3:
            opts.append([b"ANY"])
    if rnd.random() < 0.6:
        opts.append([rnd.choice([b"ASC", b"DESC"])])
    if rnd.random() < 0.03:
        opts.append([rnd.choice([b"x", b"COUNT", b"ANY", b"WITHDIST", b"STORE"])])
    rnd.shuffle(opts)
    for o in opts:
        c += o
    return c, store


def random_ops(b, r, rnd, rounds):
    keys = [b"r%d" % i for i in range(3)]
    both(b, r, cmd("DEL", "rd", *keys))
    for k in keys:
        size = rnd.choice([0, 1, 5, 60, 129, 300, 600])
        xs = []
        for i in range(size):
            w = rnd.random()
            if w < 0.6:
                lon, lat = rnd.uniform(-10, 10), rnd.uniform(-10, 10)
            elif w < 0.9:
                lon, lat = rnd.choice([(1, 1), (-3, 4), (5, -5)])
                lon, lat = lon + rnd.choice([0, 0, 1e-4, -1e-3]), lat + rnd.choice([0, 0, 1e-4])
            else:
                lon, lat = rnd.uniform(-180, 180), rnd.uniform(-85, 85)
            xs += [repr(lon).encode(), repr(lat).encode(), b"m%d" % rnd.randrange(max(1, size + 10))]
        if xs:
            same(b, r, [b"GEOADD", k] + xs)
    for j in range(rounds):
        k = rnd.choice(keys + [b"nokey"])
        w = rnd.random()
        if w < 0.75:
            c, store = rnd_search(rnd, k, b"rd")
            if store:
                write(b, r, c, [b"rd"])
            else:
                same(b, r, c)
        elif w < 0.85:
            same(b, r, [b"GEOPOS", k] + [b"m%d" % rnd.randrange(80) for _ in range(rnd.randrange(4))])
            same(b, r, [b"GEOHASH", k] + [b"m%d" % rnd.randrange(80) for _ in range(rnd.randrange(4))])
        elif w < 0.95:
            same(b, r, [b"GEODIST", k, b"m%d" % rnd.randrange(80), b"m%d" % rnd.randrange(80), rnd.choice(UNITS)])
        else:
            write(b, r, [b"GEOADD", k, rnd_num(rnd, -12, 12), rnd_num(rnd, -12, 12), b"m%d" % rnd.randrange(80)], [k])


def big(b, r, rnd):
    """a set of 20,000 points (unit/geo's fuzzy tests), searched"""
    both(b, r, cmd("DEL", "fz"))
    xs = []
    for i in range(20000):
        xs += [repr(rnd.uniform(-20, 20)).encode(), repr(rnd.uniform(-20, 20)).encode(), b"p%d" % i]
    same(b, r, [b"GEOADD", b"fz"] + xs)
    for i in range(20):
        lon, lat = repr(rnd.uniform(-20, 20)).encode(), repr(rnd.uniform(-20, 20)).encode()
        rad = str(rnd.randint(1, 800)).encode()
        same(b, r, [b"GEOSEARCH", b"fz", b"FROMLONLAT", lon, lat, b"BYRADIUS", rad, b"km"])
        same(b, r, [b"GEOSEARCH", b"fz", b"FROMLONLAT", lon, lat, b"BYBOX", rad, rad, b"km", b"COUNT", b"50", b"DESC",
                    b"WITHDIST"])
        same(b, r, [b"GEORADIUS", b"fz", lon, lat, rad, b"km", b"COUNT", b"10", b"ANY"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", type=int, default=6380)
    ap.add_argument("--redis", type=int, default=6390)
    ap.add_argument("--rounds", type=int, default=300)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    rnd = random.Random(a.seed)
    for resp3 in (False, True):
        b, r = Conn(a.bendkv, resp3), Conn(a.redis, resp3)
        b.port, r.port = a.bendkv, a.redis
        both(b, r, [b"FLUSHALL"])
        geoadd(b, r)
        reads(b, r)
        searches(b, r)
        stores(b, r)
        ties(b, r)
        multi(b, r)
        if not resp3:
            events(b, r)
            getkeys(b, r)
            stats(b, r)
            big(b, r, rnd)
            random_ops(b, r, rnd, a.rounds)
        else:
            random_ops(b, r, rnd, a.rounds // 3)
    print("geo: %d commands, %d differ" % (n, bad))
    sys.exit(1 if bad else 0)


main()
