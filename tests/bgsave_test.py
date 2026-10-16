#!/usr/bin/env python3
"""Background saves against Redis 7.0.15: BGSAVE, the save points,
stop-writes-on-bgsave-error (MISCONF) and the count of changes since the
last save (rdb_changes_since_last_save). Every server runs in a fresh
directory of its own, on a port of its own (rdb_test.Srv), and each part
compares a redis-server's transcript with BendKV's, line by line. A line
that depends on time (seconds, the progress of a save that runs) holds
what both must agree on, as the part's comment says.

- The count of changes: each write command of every kind, alone, in one
  pipeline and in MULTI, on both servers, and the count each adds; where
  BendKV counts otherwise (README, "Where BendKV differs"), the line holds
  the count each server must give, Redis's checked too.
- BGSAVE: its replies (started, SCHEDULE, already in progress, a syntax
  error, in MULTI), INFO's fields while it runs (slowed down by
  rdb-key-save-delay, which both servers honor) and after it, LASTSAVE,
  the file it writes (the databases as they were when it started, not
  the writes made while it ran), its temporary file gone, its log's
  lines, and SAVE refused while it runs; the count of changes after it
  (those made while it ran).
- BGSAVE and BGREWRITEAOF: one waits for the other, scheduled.
- The save points: a short schedule fires ("1 changes in 1 seconds.
  Saving...").
- A background save that fails (dump.rdb is a directory, so the rename
  fails): MISCONF for writes and PING, not for reads, in MULTI and at
  EXEC; errorstats and rejected calls; a save that ends well, or
  stop-writes-on-bgsave-error no, lifts it, for the commands after it in
  the same pipeline too (a CONFIG SET alone or in MULTI). The cron tries
  again 5 seconds after the failure, not before.
- The parameters a save keeps from its start, as Redis's child keeps
  them from its fork: dbfilename changed in BGSAVE's own pipeline, and
  rdb-key-save-delay while it runs.
- A temporary file removed while the save runs: the save writes on, its
  rename fails, the status is err, and no dump.rdb is put in place.
- SHUTDOWN and FLUSHALL while a background save runs: it is dropped, its
  temporary file removed; SHUTDOWN saves, and so does FLUSHALL with save
  points.
- The defaults: CONFIG GET save, and a server started with them.

    python3 tests/bgsave_test.py --bendkv build/bendkv [--redis redis-server] [--dir build/bgsave]
"""
import argparse
import datetime
import os
import re
import shutil
import sys
import time
import traceback

import rdb_test
from rdb_test import Srv, file_keys, info, read, run, talk, temps
from dump_test import cmd


def fail(what, x="", y=""):
    rdb_test.fail(what, x, y)


def same(what, x, y):
    rdb_test.same(what, x, y)


def check(what, ok, why=""):
    rdb_test.check(what, ok, why)


def dirty(c):
    return int(info(c, "persistence", "rdb_changes_since_last_save"))


# The count of changes
# --------------------
# Each case: its name, the commands before it, the command whose count is
# measured, and the count each server gives (Redis's, then BendKV's: None
# when it is Redis's). A count that differs is one of README's "Where
# BendKV differs": BendKV counts from a command's reply and its arguments,
# and from the state of a key it names before the command (before the
# pipeline, on the fast way), where Redis counts as its command changes
# the data.

FAR = 10 ** 12
# BendKV's own scripts (redis.bend: hnew.script, znew.script, lmove.script,
# smove.script)
HNEW = ("redis.call('del',KEYS[1]) local n=#ARGV for i=2,n,1000 do redis.call(ARGV[1],KEYS[1],"
        "unpack(ARGV,i,math.min(i+999,n))) end return 0")
ZNEW = ("redis.call('del',KEYS[1]) local o=tonumber(ARGV[1]) local n=#ARGV for i=o+2,n,1000 do local a={} "
        "for j=2,o+1 do a[#a+1]=ARGV[j] end for j=i,math.min(i+999,n) do a[#a+1]=ARGV[j] end "
        "redis.call('zadd',KEYS[1],unpack(a)) end return 0")
LMOVE = "redis.call('del',KEYS[2]) return redis.call('lmove',KEYS[1],KEYS[2],ARGV[1],ARGV[2])"
SMOVE = "redis.call('del',KEYS[2]) return redis.call('smove',KEYS[1],KEYS[2],ARGV[1])"
CASES = [
    # strings
    ("set", [], ["SET", "a", "1"], 1, None),
    ("set over", [["SET", "a", "1"]], ["SET", "a", "2"], 1, None),
    ("set nx missing", [], ["SET", "a", "1", "NX"], 1, None),
    ("set nx there", [["SET", "a", "1"]], ["SET", "a", "2", "NX"], 0, None),
    ("set xx missing", [], ["SET", "a", "1", "XX"], 0, None),
    ("set xx there", [["SET", "a", "1"]], ["SET", "a", "2", "XX"], 1, None),
    ("set ex", [], ["SET", "a", "1", "EX", "100"], 1, None),
    ("set keepttl", [["SET", "a", "1", "EX", "100"]], ["SET", "a", "2", "KEEPTTL"], 1, None),
    ("set get there", [["SET", "a", "1"]], ["SET", "a", "2", "GET"], 1, None),
    ("set get missing", [], ["SET", "a", "2", "GET"], 1, 0),
    ("set nx get there", [["SET", "a", "1"]], ["SET", "a", "2", "NX", "GET"], 0, 1),
    ("set nx get missing", [], ["SET", "a", "2", "NX", "GET"], 1, 0),
    ("set xx get there", [["SET", "a", "1"]], ["SET", "a", "2", "XX", "GET"], 1, None),
    ("set xx get missing", [], ["SET", "a", "2", "XX", "GET"], 0, None),
    ("set over a list", [["RPUSH", "l", "x"]], ["SET", "l", "1"], 1, None),
    ("set bad", [], ["SET", "a", "1", "EX", "0"], 0, None),
    ("setnx missing", [], ["SETNX", "a", "1"], 1, None),
    ("setnx there", [["SET", "a", "1"]], ["SETNX", "a", "2"], 0, None),
    ("setex", [], ["SETEX", "a", "100", "1"], 1, None),
    ("psetex", [], ["PSETEX", "a", "100000", "1"], 1, None),
    ("getset missing", [], ["GETSET", "a", "1"], 1, None),
    ("getset there", [["SET", "a", "1"]], ["GETSET", "a", "2"], 1, None),
    ("getset wrongtype", [["RPUSH", "l", "x"]], ["GETSET", "l", "2"], 0, None),
    ("getdel there", [["SET", "a", "1"]], ["GETDEL", "a"], 1, None),
    ("getdel missing", [], ["GETDEL", "a"], 0, None),
    ("getex", [["SET", "a", "1"]], ["GETEX", "a"], 0, None),
    ("getex ex", [["SET", "a", "1"]], ["GETEX", "a", "EX", "100"], 1, None),
    ("getex pxat past", [["SET", "a", "1"]], ["GETEX", "a", "PXAT", "1000"], 1, None),
    ("getex persist with a time", [["SET", "a", "1", "EX", "100"]], ["GETEX", "a", "PERSIST"], 1, None),
    ("getex persist without", [["SET", "a", "1"]], ["GETEX", "a", "PERSIST"], 0, None),
    ("getex missing", [], ["GETEX", "a", "EX", "100"], 0, None),
    ("setrange", [["SET", "a", "hello"]], ["SETRANGE", "a", "2", "xy"], 1, None),
    ("setrange new", [], ["SETRANGE", "a", "2", "xy"], 1, None),
    ("setrange empty", [["SET", "a", "hello"]], ["SETRANGE", "a", "2", ""], 0, None),
    ("setrange empty missing", [], ["SETRANGE", "a", "2", ""], 0, None),
    ("mset", [], ["MSET", "a", "1", "b", "2", "c", "3"], 3, None),
    ("msetnx", [], ["MSETNX", "a", "1", "b", "2"], 2, None),
    ("msetnx there", [["SET", "b", "1"]], ["MSETNX", "a", "1", "b", "2"], 0, None),
    ("incr", [], ["INCR", "n"], 1, None),
    ("incr bad", [["SET", "a", "x"]], ["INCR", "a"], 0, None),
    ("decr", [], ["DECR", "n"], 1, None),
    ("incrby", [], ["INCRBY", "n", "5"], 1, None),
    ("decrby", [], ["DECRBY", "n", "5"], 1, None),
    ("incrbyfloat", [], ["INCRBYFLOAT", "n", "1.5"], 1, None),
    ("append", [["SET", "a", "x"]], ["APPEND", "a", "yz"], 1, None),
    ("append empty", [["SET", "a", "x"]], ["APPEND", "a", ""], 1, None),
    ("setbit new", [], ["SETBIT", "b", "7", "1"], 1, None),
    ("setbit new 0", [], ["SETBIT", "b", "7", "0"], 1, None),
    ("setbit same", [["SETBIT", "b", "7", "1"]], ["SETBIT", "b", "7", "1"], 0, None),
    ("setbit changes", [["SETBIT", "b", "7", "1"]], ["SETBIT", "b", "7", "0"], 1, None),
    ("setbit grows", [["SETBIT", "b", "7", "1"]], ["SETBIT", "b", "100", "0"], 1, None),
    ("bitop", [["SET", "a", "x"], ["SET", "b", "y"]], ["BITOP", "AND", "d", "a", "b"], 1, None),
    ("bitop empty over a key", [["SET", "d", "x"]], ["BITOP", "AND", "d", "m1", "m2"], 1, None),
    ("bitop empty", [], ["BITOP", "AND", "d", "m1", "m2"], 0, None),
    ("bitfield", [], ["BITFIELD", "f", "SET", "u8", "0", "255", "GET", "u8", "0", "INCRBY", "u8", "8", "1"], 2, None),
    ("bitfield fail", [], ["BITFIELD", "f", "OVERFLOW", "FAIL", "INCRBY", "u2", "0", "5", "SET", "u8", "8", "1"], 1, None),
    ("bitfield_ro", [["SET", "f", "x"]], ["BITFIELD_RO", "f", "GET", "u8", "0"], 0, None),
    # keys
    ("del", [["SET", "a", "1"], ["SET", "b", "1"]], ["DEL", "a", "b", "c"], 2, None),
    ("unlink", [["SET", "a", "1"]], ["UNLINK", "a", "b"], 1, None),
    ("expire", [["SET", "a", "1"]], ["EXPIRE", "a", "100"], 1, None),
    ("expire missing", [], ["EXPIRE", "a", "100"], 0, None),
    ("expire nx refused", [["SET", "a", "1", "EX", "100"]], ["EXPIRE", "a", "100", "NX"], 0, None),
    ("expire past", [["SET", "a", "1"]], ["EXPIRE", "a", "-1"], 1, None),
    ("pexpire", [["SET", "a", "1"]], ["PEXPIRE", "a", "100000"], 1, None),
    ("expireat", [["SET", "a", "1"]], ["EXPIREAT", "a", str(FAR)], 1, None),
    ("pexpireat", [["SET", "a", "1"]], ["PEXPIREAT", "a", str(FAR * 1000)], 1, None),
    ("persist", [["SET", "a", "1", "EX", "100"]], ["PERSIST", "a"], 1, None),
    ("persist none", [["SET", "a", "1"]], ["PERSIST", "a"], 0, None),
    ("rename", [["SET", "a", "1"]], ["RENAME", "a", "b"], 1, None),
    ("rename to itself", [["SET", "a", "1"]], ["RENAME", "a", "a"], 0, None),
    ("rename missing", [], ["RENAME", "a", "b"], 0, None),
    ("renamenx", [["SET", "a", "1"]], ["RENAMENX", "a", "b"], 1, None),
    ("renamenx there", [["SET", "a", "1"], ["SET", "b", "1"]], ["RENAMENX", "a", "b"], 0, None),
    ("move", [["SET", "a", "1"]], ["MOVE", "a", "1"], 1, None),
    ("move missing", [], ["MOVE", "a", "1"], 0, None),
    ("copy", [["SET", "a", "1"]], ["COPY", "a", "b"], 1, None),
    ("copy missing", [], ["COPY", "a", "b"], 0, None),
    ("swapdb", [], ["SWAPDB", "0", "1"], 1, None),
    ("flushdb", [["SET", "a", "1"], ["SET", "b", "1"], ["RPUSH", "l", "x"]], ["FLUSHDB"], 3, None),
    ("flushdb empty", [], ["FLUSHDB"], 0, None),
    ("flushall", [["SET", "a", "1"], ["SELECT", "2"], ["SET", "a", "1"], ["SET", "b", "1"], ["SELECT", "0"]], ["FLUSHALL"], 3, None),
    ("restore", [["SET", "src", "v"]], [], 1, None),
    ("restore replace", [["SET", "src", "v"], ["SET", "dst", "x"]], ["REPLACE"], 1, None),
    ("restore busy", [["SET", "src", "v"], ["SET", "dst", "x"]], ["0"], 0, None),
    ("restore abs past", [["SET", "src", "v"]], ["1000", "ABSTTL"], 0, None),
    ("restore abs past replace", [["SET", "src", "v"], ["SET", "dst", "x"]], ["1000", "ABSTTL", "REPLACE"], 1, None),
    ("restore abs past replace missing", [["SET", "src", "v"]], ["1000", "ABSTTL", "REPLACE"], 0, None),
    ("restore abs far", [["SET", "src", "v"]], [str(FAR * 1000), "ABSTTL"], 1, None),
    ("touch", [["SET", "a", "1"]], ["TOUCH", "a"], 0, None),
    # hashes
    ("hset", [], ["HSET", "h", "a", "1", "b", "2"], 2, None),
    ("hset over", [["HSET", "h", "a", "1", "b", "2"]], ["HSET", "h", "a", "1", "b", "3"], 2, None),
    ("hmset", [], ["HMSET", "h", "a", "1", "b", "2", "c", "3"], 3, None),
    ("hset wrongtype", [["SET", "a", "1"]], ["HSET", "a", "f", "v"], 0, None),
    ("hsetnx", [], ["HSETNX", "h", "a", "1"], 1, None),
    ("hsetnx there", [["HSET", "h", "a", "1"]], ["HSETNX", "h", "a", "2"], 0, None),
    ("hincrby", [], ["HINCRBY", "h", "a", "1"], 1, None),
    ("hincrbyfloat", [], ["HINCRBYFLOAT", "h", "a", "1.5"], 1, None),
    ("hdel", [["HSET", "h", "a", "1", "b", "2", "c", "3"]], ["HDEL", "h", "a", "b", "z"], 2, None),
    # lists
    ("lpush", [], ["LPUSH", "l", "a", "b", "c"], 3, None),
    ("rpush", [["RPUSH", "l", "x"]], ["RPUSH", "l", "a", "b"], 2, None),
    ("lpush wrongtype", [["SET", "a", "1"]], ["LPUSH", "a", "x"], 0, None),
    ("lpushx missing", [], ["LPUSHX", "l", "a", "b"], 0, None),
    ("lpushx", [["RPUSH", "l", "x"]], ["LPUSHX", "l", "a", "b"], 2, None),
    ("rpushx", [["RPUSH", "l", "x"]], ["RPUSHX", "l", "a"], 1, None),
    ("linsert", [["RPUSH", "l", "a", "b"]], ["LINSERT", "l", "BEFORE", "b", "x"], 1, None),
    ("linsert no pivot", [["RPUSH", "l", "a", "b"]], ["LINSERT", "l", "BEFORE", "z", "x"], 0, None),
    ("lset", [["RPUSH", "l", "a", "b"]], ["LSET", "l", "0", "x"], 1, None),
    ("lpop", [["RPUSH", "l", "a", "b", "c"]], ["LPOP", "l"], 1, None),
    ("lpop count", [["RPUSH", "l", "a", "b", "c"]], ["LPOP", "l", "2"], 2, None),
    ("lpop count 0", [["RPUSH", "l", "a", "b", "c"]], ["LPOP", "l", "0"], 0, None),
    ("rpop missing", [], ["RPOP", "l"], 0, None),
    ("ltrim", [["RPUSH", "l", "a", "b", "c", "d"]], ["LTRIM", "l", "1", "2"], 2, None),
    ("ltrim nothing", [["RPUSH", "l", "a", "b", "c", "d"]], ["LTRIM", "l", "0", "-1"], 0, None),
    ("ltrim all", [["RPUSH", "l", "a", "b", "c", "d"]], ["LTRIM", "l", "5", "9"], 4, None),
    ("lrem", [["RPUSH", "l", "a", "b", "a", "a"]], ["LREM", "l", "0", "a"], 3, None),
    ("lmove", [["RPUSH", "l", "a", "b"]], ["LMOVE", "l", "m", "LEFT", "RIGHT"], 1, None),
    ("rpoplpush", [["RPUSH", "l", "a", "b"]], ["RPOPLPUSH", "l", "l"], 1, None),
    ("lmpop", [["RPUSH", "l", "a", "b", "c"]], ["LMPOP", "2", "x", "l", "LEFT", "COUNT", "2"], 2, None),
    ("blpop", [["RPUSH", "l", "a", "b"]], ["BLPOP", "l", "0"], 1, None),
    ("brpop", [["RPUSH", "l", "a", "b"]], ["BRPOP", "x", "l", "0"], 1, None),
    ("blmove", [["RPUSH", "l", "a", "b"]], ["BLMOVE", "l", "m", "LEFT", "LEFT", "0"], 1, None),
    ("brpoplpush", [["RPUSH", "l", "a", "b"]], ["BRPOPLPUSH", "l", "m", "0"], 1, None),
    ("blmpop", [["RPUSH", "l", "a", "b", "c"]], ["BLMPOP", "0", "1", "l", "RIGHT", "COUNT", "2"], 2, None),
    # sets
    ("sadd", [], ["SADD", "s", "a", "b", "c"], 3, None),
    ("sadd some", [["SADD", "s", "a"]], ["SADD", "s", "a", "b"], 1, None),
    ("srem", [["SADD", "s", "a", "b", "c"]], ["SREM", "s", "a", "b", "z"], 2, None),
    ("smove", [["SADD", "s", "a", "b"]], ["SMOVE", "s", "t", "a"], 2, None),
    ("smove there", [["SADD", "s", "a", "b"], ["SADD", "t", "a"]], ["SMOVE", "s", "t", "a"], 1, None),
    ("smove to itself", [["SADD", "s", "a", "b"]], ["SMOVE", "s", "s", "a"], 0, None),
    ("smove missing", [["SADD", "s", "a", "b"]], ["SMOVE", "s", "t", "z"], 0, None),
    ("spop", [["SADD", "s", "a", "b", "c"]], ["SPOP", "s"], 1, None),
    ("spop count", [["SADD", "s", "a", "b", "c"]], ["SPOP", "s", "2"], 2, None),
    ("sinterstore", [["SADD", "s", "a", "b"], ["SADD", "t", "b"]], ["SINTERSTORE", "d", "s", "t"], 1, None),
    ("sinterstore empty over a key", [["SADD", "s", "a"], ["SADD", "t", "b"], ["SET", "d", "x"]], ["SINTERSTORE", "d", "s", "t"], 1, None),
    ("sinterstore empty", [["SADD", "s", "a"], ["SADD", "t", "b"]], ["SINTERSTORE", "d", "s", "t"], 0, None),
    ("sunionstore", [["SADD", "s", "a", "b"], ["SADD", "t", "b"]], ["SUNIONSTORE", "d", "s", "t"], 1, None),
    ("sdiffstore", [["SADD", "s", "a", "b"], ["SADD", "t", "b"]], ["SDIFFSTORE", "d", "s", "t"], 1, None),
    # sorted sets
    ("zadd", [], ["ZADD", "z", "1", "a", "2", "b"], 2, None),
    ("zadd same", [["ZADD", "z", "1", "a", "2", "b"]], ["ZADD", "z", "1", "a", "3", "b"], 1, 2),
    ("zadd ch", [["ZADD", "z", "1", "a", "2", "b"]], ["ZADD", "z", "CH", "1", "a", "3", "b", "4", "c"], 2, None),
    ("zadd nx", [["ZADD", "z", "1", "a"]], ["ZADD", "z", "NX", "5", "a", "2", "b"], 1, None),
    ("zadd xx", [["ZADD", "z", "1", "a"]], ["ZADD", "z", "XX", "5", "a", "2", "b"], 1, 2),
    ("zadd incr", [["ZADD", "z", "1", "a"]], ["ZADD", "z", "INCR", "5", "a"], 1, None),
    ("zadd incr nx refused", [["ZADD", "z", "1", "a"]], ["ZADD", "z", "NX", "INCR", "5", "a"], 0, None),
    ("zadd incr 0", [["ZADD", "z", "1", "a"]], ["ZADD", "z", "INCR", "0", "a"], 0, None),
    ("zadd incr new", [["ZADD", "z", "1", "a"]], ["ZADD", "z", "INCR", "0", "b"], 1, None),
    ("zincrby", [], ["ZINCRBY", "z", "2", "a"], 1, None),
    ("zincrby there", [["ZADD", "z", "1", "a"]], ["ZINCRBY", "z", "2", "a"], 1, None),
    ("zincrby 0", [["ZADD", "z", "1", "a"]], ["ZINCRBY", "z", "0", "a"], 0, None),
    ("zincrby too small", [["ZADD", "z", "1", "a"]], ["ZINCRBY", "z", "1e-30", "a"], 0, None),
    ("zincrby past 2^53", [["ZADD", "z", "9007199254740992", "a"]], ["ZINCRBY", "z", "1", "a"], 0, None),
    ("zincrby ulp past 2^53", [["ZADD", "z", "9007199254740992", "a"]], ["ZINCRBY", "z", "2", "a"], 1, None),
    ("zincrby below 1", [["ZADD", "z", "1", "a"]], ["ZINCRBY", "z", "-1.1102230246251565e-16", "a"], 1, None),
    ("zincrby subnormal", [["ZADD", "z", "0", "a"]], ["ZINCRBY", "z", "5e-324", "a"], 1, None),
    ("zincrby inf", [["ZADD", "z", "inf", "a"]], ["ZINCRBY", "z", "1", "a"], 0, None),
    ("zincrby inf inf", [["ZADD", "z", "inf", "a"]], ["ZINCRBY", "z", "inf", "a"], 0, None),
    ("zincrby to inf", [["ZADD", "z", "1", "a"]], ["ZINCRBY", "z", "inf", "a"], 1, None),
    ("zincrby nan", [["ZADD", "z", "inf", "a"]], ["ZINCRBY", "z", "-inf", "a"], 0, None),
    ("zincrby 0 new", [], ["ZINCRBY", "z", "0", "a"], 1, None),
    ("zincrby wrongtype", [["SET", "z", "1"]], ["ZINCRBY", "z", "1", "a"], 0, None),
    ("zrem", [["ZADD", "z", "1", "a", "2", "b"]], ["ZREM", "z", "a", "x"], 1, None),
    ("zremrangebyscore", [["ZADD", "z", "1", "a", "2", "b", "3", "c"]], ["ZREMRANGEBYSCORE", "z", "1", "2"], 2, None),
    ("zremrangebyrank", [["ZADD", "z", "1", "a", "2", "b", "3", "c"]], ["ZREMRANGEBYRANK", "z", "0", "0"], 1, None),
    ("zremrangebylex", [["ZADD", "z", "0", "a", "0", "b", "0", "c"]], ["ZREMRANGEBYLEX", "z", "[a", "[b"], 2, None),
    ("zpopmin", [["ZADD", "z", "1", "a", "2", "b", "3", "c"]], ["ZPOPMIN", "z"], 1, None),
    ("zpopmax count", [["ZADD", "z", "1", "a", "2", "b", "3", "c"]], ["ZPOPMAX", "z", "2"], 2, None),
    ("zmpop", [["ZADD", "z", "1", "a", "2", "b", "3", "c"]], ["ZMPOP", "1", "z", "MIN", "COUNT", "2"], 2, None),
    ("bzpopmin", [["ZADD", "z", "1", "a", "2", "b"]], ["BZPOPMIN", "z", "0"], 1, None),
    ("bzmpop", [["ZADD", "z", "1", "a", "2", "b"]], ["BZMPOP", "0", "1", "z", "MAX", "COUNT", "5"], 2, None),
    ("zunionstore", [["ZADD", "z", "1", "a"], ["ZADD", "y", "1", "b"]], ["ZUNIONSTORE", "d", "2", "z", "y"], 1, None),
    ("zinterstore empty over a key", [["ZADD", "z", "1", "a"], ["ZADD", "y", "1", "b"], ["SET", "d", "x"]], ["ZINTERSTORE", "d", "2", "z", "y"], 1, None),
    ("zdiffstore", [["ZADD", "z", "1", "a"], ["ZADD", "y", "1", "b"]], ["ZDIFFSTORE", "d", "2", "z", "y"], 1, None),
    ("zrangestore", [["ZADD", "z", "1", "a", "2", "b"]], ["ZRANGESTORE", "d", "z", "0", "-1"], 1, None),
    # HyperLogLogs, GEO, SORT
    ("pfadd new", [], ["PFADD", "p", "a", "b", "c"], 4, 1),
    ("pfadd nothing new", [["PFADD", "p", "a"]], ["PFADD", "p", "a"], 0, None),
    ("pfcount", [["PFADD", "p", "a", "b"]], ["PFCOUNT", "p"], 1, 0),
    ("pfmerge", [["PFADD", "p", "a"], ["PFADD", "q", "b"]], ["PFMERGE", "r", "p", "q"], 1, None),
    ("pfdebug todense", [["PFADD", "p", "a", "b"]], ["PFDEBUG", "TODENSE", "p"], 1, None),
    ("pfdebug todense dense", [["PFADD", "p", "a"], ["PFDEBUG", "TODENSE", "p"]], ["PFDEBUG", "TODENSE", "p"], 0, None),
    ("pfdebug getreg", [["PFADD", "p", "a"]], ["PFDEBUG", "GETREG", "p"], 1, None),
    ("pfdebug encoding", [["PFADD", "p", "a"]], ["PFDEBUG", "ENCODING", "p"], 0, None),
    ("pfdebug missing", [], ["PFDEBUG", "TODENSE", "p"], 0, None),
    ("geoadd", [], ["GEOADD", "g", "13.361389", "38.115556", "Palermo", "15.087269", "37.502669", "Catania"], 2, None),
    ("geoadd same", [["GEOADD", "g", "13.361389", "38.115556", "Palermo"]], ["GEOADD", "g", "13.361389", "38.115556", "Palermo"], 0, 1),
    ("geosearchstore", [["GEOADD", "g", "13.361389", "38.115556", "Palermo", "15.087269", "37.502669", "Catania"]],
     ["GEOSEARCHSTORE", "d", "g", "FROMLONLAT", "15", "37", "BYRADIUS", "200", "km", "ASC"], 2, None),
    ("georadius store", [["GEOADD", "g", "13.361389", "38.115556", "Palermo", "15.087269", "37.502669", "Catania"]],
     ["GEORADIUS", "g", "15", "37", "200", "km", "STORE", "d"], 2, None),
    ("geosearchstore empty over a key", [["GEOADD", "g", "13.361389", "38.115556", "Palermo"], ["SET", "d", "x"]],
     ["GEOSEARCHSTORE", "d", "g", "FROMLONLAT", "100", "0", "BYRADIUS", "1", "km"], 1, None),
    ("sort store", [["RPUSH", "l", "3", "1", "2"]], ["SORT", "l", "STORE", "d"], 3, None),
    ("sort store empty over a key", [["SET", "d", "x"]], ["SORT", "l", "STORE", "d"], 1, None),
    ("sort", [["RPUSH", "l", "3", "1", "2"]], ["SORT", "l"], 0, None),
    # BendKV's own scripts (the append-only file's: a new collection
    # where a key whose time had passed lay, a move to one), which Redis
    # runs as Lua: the DEL, then the command's changes
    ("eval new hash", [["SET", "h", "old"]], ["EVAL", HNEW, "1", "h", "HSET", "f1", "v1", "f2", "v2", "f3", "v3"], 4, None),
    ("eval new hash missing", [], ["EVAL", HNEW, "1", "h", "HSET", "f1", "v1", "f1", "v2"], 2, None),
    ("eval new list", [["SET", "l", "old"]], ["EVAL", HNEW, "1", "l", "RPUSH", "a", "b"], 3, None),
    ("eval new set", [["SET", "s", "old"]], ["EVAL", HNEW, "1", "s", "SADD", "a", "b", "a"], 3, None),
    ("eval new zset", [["SET", "z", "old"]], ["EVAL", ZNEW, "1", "z", "0", "1", "a", "2", "b", "3", "a"], 4, None),
    ("eval new zset nx", [], ["EVAL", ZNEW, "1", "z", "1", "NX", "1", "a", "3", "a"], 1, None),
    ("eval lmove", [["RPUSH", "l", "a", "b"], ["SET", "m", "x"]], ["EVAL", LMOVE, "2", "l", "m", "LEFT", "RIGHT"], 2, None),
    ("eval lmove to itself", [["RPUSH", "l", "a", "b"]], ["EVAL", LMOVE, "2", "l", "l", "LEFT", "RIGHT"], 1, None),
    ("eval smove", [["SADD", "s", "a", "b"], ["SET", "t", "x"]], ["EVAL", SMOVE, "2", "s", "t", "a"], 3, None),
    ("eval smove missing", [["SADD", "s", "a", "b"]], ["EVAL", SMOVE, "2", "s", "t", "z"], 0, None),
    # others
    ("function flush", [], ["FUNCTION", "FLUSH"], 1, None),
    ("publish", [], ["PUBLISH", "c", "m"], 0, None),
    ("get", [["SET", "a", "1"]], ["GET", "a"], 0, None),
]


def restore_cmd(c, more):
    """RESTORE of a DUMP's payload (each server's own) onto dst, its time
    0 but when more starts with one, with the options of more"""
    p = run(c, "DUMP", "src")[1]
    if more and not more[0].isalpha():
        return ["RESTORE", "dst", more[0], p] + more[1:]
    return ["RESTORE", "dst", "0", p] + more


def counts_on(exe, root, mode):
    """each case's count on a server of exe: alone (each command a
    request of its own), in one pipeline, or in MULTI"""
    s = Srv(exe, root, "--save", "")
    out = []
    try:
        c = s.conn()
        for name, setup, x, rv, bv in CASES:
            run(c, "FLUSHALL")
            for y in setup:
                run(c, *y)
            if name.startswith("restore"):
                x = restore_cmd(c, x)
            before = dirty(c)
            if mode == "alone":
                run(c, *x)
            elif mode == "pipeline":
                c.send([cmd("PING"), cmd(*x), cmd("PING")])
                for _ in range(3):
                    c.reply()
            else:
                c.send([cmd("MULTI"), cmd(*x), cmd("EXEC")])
                for _ in range(3):
                    c.reply()
            out.append((name, dirty(c) - before))
        run(c, "FLUSHALL")
        out.append(("ping", ping_count(c)))
    finally:
        s.kill()
    return out


def ping_count(c):
    before = dirty(c)
    run(c, "PING")
    return dirty(c) - before


def counts(a, root):
    """each write's count of changes, alone, in a pipeline and in MULTI"""
    for mode in ("alone", "pipeline", "multi"):
        got = {}
        for name, exe in (("bendkv", a.bin), ("redis", a.redis)):
            try:
                got[name] = dict(counts_on(exe, os.path.join(root, "counts-" + mode, name), mode))
            except Exception as e:
                fail("the counts (%s) on %s: %r" % (mode, name, e), traceback.format_exc()[-800:])
                got[name] = {}
        for name, setup, x, rv, bv in CASES:
            r, b = got["redis"].get(name), got["bendkv"].get(name)
            same("Redis counts %s (%s) as the table says" % (name, mode), r, rv)
            same("BendKV counts %s (%s)" % (name, mode), b, rv if bv is None else bv)


# The parts on both servers
# -------------------------
# Each runs a transcript on a server of its own (log: a line of it), on
# BendKV and on Redis, and the two are compared line by line.

def both(a, root, name, on):
    outs = []
    for who, exe in (("bendkv", a.bin), ("redis", a.redis)):
        lines = []
        try:
            on(exe, os.path.join(root, name, who), lambda *x: lines.append(" ".join(repr(v) for v in x)))
        except Exception as e:
            fail("%s on %s: %r" % (name, who, e), traceback.format_exc()[-1200:])
            lines.append("EXCEPTION %r" % (e,))
        outs.append(lines)
    for i in range(max(len(outs[0]), len(outs[1]))):
        x = outs[0][i] if i < len(outs[0]) else "<none>"
        y = outs[1][i] if i < len(outs[1]) else "<none>"
        same("%s line %d" % (name, i), x, y)


def until(f, timeout=15.0, step=0.02):
    """f's value once it is true, or its last one after timeout seconds"""
    end = time.time() + timeout
    while True:
        x = f()
        if x or time.time() > end:
            return x
        time.sleep(step)


def field(c, name, section="persistence"):
    return info(c, section, name)


def running(c):
    return field(c, "rdb_bgsave_in_progress") == "1"


def idle(c):
    return field(c, "rdb_bgsave_in_progress") == "0" and field(c, "aof_rewrite_in_progress") == "0"


def keys_in(d, name="dump.rdb"):
    p = os.path.join(d, name)
    return os.path.exists(p) and sorted(k for _, k, _ in file_keys(read(p)))


def fill_n(c, n, prefix="k"):
    c.send([cmd("SET", "%s%d" % (prefix, i), i) for i in range(n)])
    for _ in range(n):
        c.reply()


def pipe(c, cmds):
    """the replies to cmds sent at once"""
    c.send([cmd(*x) for x in cmds])
    return [c.reply() for _ in cmds]


def lines_in(s, *xs):
    lg = s.log()
    return [x in lg for x in xs]


def count_in(s, x):
    return s.log().count(x)


MISCONF = (b"-", b"MISCONF Redis is configured to save RDB snapshots, but it's currently unable to persist to disk. "
           b"Commands that may modify the data set are disabled, because this instance is configured to report "
           b"errors during writes if RDB snapshotting fails (stop-writes-on-bgsave-error option). Please check the "
           b"Redis logs for details about the RDB error.")


def bgsave_on(exe, d, log):
    """BGSAVE: replies, INFO's fields, the file and the log"""
    s = Srv(exe, d, "--save", "")
    c = s.conn()
    fill_n(c, 50)
    log("1 dirty", dirty(c))
    t0 = int(run(c, "LASTSAVE")[1])
    log("1 arguments", run(c, "BGSAVE", "x"), run(c, "BGSAVE", "SCHEDULE", "x"), run(c, "BGSAVE", "schedul"))
    log("1 fields", [field(c, x) for x in ("rdb_bgsave_in_progress", "rdb_last_bgsave_time_sec",
                                           "rdb_current_bgsave_time_sec", "rdb_saves", "current_save_keys_total")])
    # 50 keys, 20 ms each: a save of a second
    run(c, "CONFIG", "SET", "rdb-key-save-delay", "20000")
    log("2 bgsave", run(c, "BGSAVE"))
    log("2 while it runs", run(c, "BGSAVE"), run(c, "BGSAVE", "SCHEDULE"), run(c, "SAVE"), run(c, "BGSAVE", "x"))
    f = [field(c, x) for x in ("rdb_bgsave_in_progress", "rdb_current_bgsave_time_sec", "current_save_keys_total",
                               "current_save_keys_processed", "current_fork_perc", "rdb_saves", "rdb_changes_since_last_save")]
    log("2 fields", f[0], f[1] in ("0", "1"), f[2], int(f[3]) <= 50, float(f[4]) <= 100, f[5], f[6])
    # writes while it runs: not in the file, still counted after it
    log("2 writes", run(c, "SET", "during", "1"), run(c, "DEL", "k0"))
    log("2 ends", until(lambda: not running(c)))
    log("2 after", [field(c, x) for x in ("rdb_bgsave_in_progress", "rdb_last_bgsave_status", "rdb_current_bgsave_time_sec",
                                          "rdb_saves", "rdb_changes_since_last_save", "current_save_keys_total",
                                          "current_save_keys_processed", "current_fork_perc")],
        0 <= int(field(c, "rdb_last_bgsave_time_sec")) <= 3)
    t1 = int(run(c, "LASTSAVE")[1])
    log("2 lastsave", t1 >= t0, t1 == int(field(c, "rdb_last_save_time")))
    log("2 file", keys_in(d) == sorted(b"k%d" % i for i in range(50)), temps(d))
    log("2 log", lines_in(s, "Background saving started by pid ", "DB saved on disk",
                          "Background saving terminated with success"))
    # in MULTI: scheduled, and the cron starts it
    run(c, "CONFIG", "SET", "rdb-key-save-delay", "0")
    log("3 multi", run(c, "MULTI"), run(c, "BGSAVE"), run(c, "EXEC"))
    log("3 scheduled", until(lambda: field(c, "rdb_saves") == "2" and not running(c)), field(c, "rdb_changes_since_last_save"))
    log("3 schedule alone", run(c, "BGSAVE", "SCHEDULE"))
    log("3 ends", until(lambda: field(c, "rdb_saves") == "3" and not running(c)), keys_in(d) == sorted(
        [b"during"] + [b"k%d" % i for i in range(1, 50)]), temps(d))
    # CONFIG RESETSTAT counts the saves again
    run(c, "CONFIG", "RESETSTAT")
    log("4 resetstat", field(c, "rdb_saves"), field(c, "rdb_last_bgsave_status"))
    talk(s.port, [["SHUTDOWN", "NOSAVE"]])
    log("4 exit", s.exit())


def bgsave(a, root):
    """BGSAVE's replies, INFO's fields while it runs and after it, LASTSAVE,
    the file and the log"""
    both(a, root, "bgsave", bgsave_on)


def rewrite_on(exe, d, log):
    """BGSAVE and BGREWRITEAOF, one scheduled while the other runs"""
    s = Srv(exe, d, "--save", "")
    c = s.conn()
    fill_n(c, 40)
    run(c, "CONFIG", "SET", "rdb-key-save-delay", "20000")
    log("1 rewrite", run(c, "BGREWRITEAOF"))
    log("1 bgsave", run(c, "BGSAVE"), run(c, "BGSAVE", "SCHEDULE"), run(c, "BGSAVE", "SCHEDULE"))
    log("1 fields", [field(c, x) for x in ("aof_rewrite_in_progress", "rdb_bgsave_in_progress", "aof_rewrite_scheduled")])
    log("1 the save starts", until(lambda: running(c)), field(c, "aof_rewrite_in_progress"), field(c, "aof_rewrites"))
    log("1 rewrite again", run(c, "BGREWRITEAOF"), field(c, "aof_rewrite_scheduled"))
    log("1 the rewrite starts", until(lambda: field(c, "aof_rewrite_in_progress") == "1"),
        field(c, "rdb_bgsave_in_progress"), field(c, "rdb_saves"), field(c, "aof_rewrite_scheduled"))
    log("1 all done", until(lambda: idle(c)), field(c, "aof_rewrites"), field(c, "rdb_saves"), field(c, "rdb_last_bgsave_status"),
        field(c, "aof_last_bgrewrite_status"))
    talk(s.port, [["SHUTDOWN", "NOSAVE"]])
    log("1 exit", s.exit())


def rewrite(a, root):
    """BGSAVE and BGREWRITEAOF: one is scheduled while the other runs, and
    runs once it ends"""
    both(a, root, "rewrite", rewrite_on)


def points_on(exe, d, log):
    """the save points: "1 1" saves within seconds of a change; none
    without a change, nor without save points"""
    s = Srv(exe, d, "--save", "1 1")
    c = s.conn()
    time.sleep(2.5)
    log("1 no change, no save", field(c, "rdb_saves"), keys_in(d))
    run(c, "SET", "a", "1")
    log("1 a change", until(lambda: field(c, "rdb_saves") == "1" and not running(c), timeout=5),
        field(c, "rdb_changes_since_last_save"), field(c, "rdb_last_bgsave_status"), keys_in(d))
    log("1 log", count_in(s, "1 changes in 1 seconds. Saving..."), count_in(s, "Background saving started by pid"))
    run(c, "SET", "b", "1")
    run(c, "SET", "c", "1")
    log("2 two changes", until(lambda: field(c, "rdb_saves") == "2" and not running(c), timeout=5),
        field(c, "rdb_changes_since_last_save"), keys_in(d))
    log("2 log", count_in(s, "2 changes in 1 seconds. Saving..."))
    run(c, "CONFIG", "SET", "save", "")
    run(c, "SET", "d", "1")
    time.sleep(2.5)
    log("3 no save points", field(c, "rdb_saves"), field(c, "rdb_changes_since_last_save"))
    talk(s.port, [["SHUTDOWN", "NOSAVE"]])
    log("3 exit", s.exit())


def points(a, root):
    """the save points: a short schedule saves after a change, not before"""
    both(a, root, "points", points_on)


def misconf_on(exe, d, log):
    """a background save that fails, and the writes refused after it"""
    s = Srv(exe, d, "--save", "3600 1")
    c, held, sub, mon = s.conn(), s.conn(), s.conn(), s.conn()
    run(c, "SET", "a", "1")
    log("1 queued before", run(held, "MULTI"), run(held, "SET", "q", "1"), run(held, "GET", "a"))
    # the rename onto dump.rdb fails: a directory, not empty, is there
    os.makedirs(os.path.join(d, "dump.rdb", "x"))
    log("1 bgsave", run(c, "BGSAVE"), until(lambda: not running(c)))
    log("1 fields", [field(c, x) for x in ("rdb_last_bgsave_status", "rdb_changes_since_last_save", "rdb_saves")],
        temps(d), lines_in(s, "Error moving temp DB file temp-", "Background saving error"))
    log("2 writes", run(c, "SET", "b", "2"), run(c, "INCR", "n"), run(c, "DEL", "a"), run(c, "FLUSHALL"),
        run(c, "PING"), run(c, "PING", "hi"))
    log("2 reads", run(c, "GET", "a"), run(c, "EXISTS", "a"), run(c, "PUBLISH", "c", "m"), run(c, "ECHO", "e"),
        run(c, "DBSIZE"))
    log("2 refused first", run(c, "NOSUCH"), run(c, "SET", "x"), run(c, "MULTI"), run(c, "SAVE"), run(c, "SET", "y", "1"),
        run(c, "GET", "a"), run(c, "EXEC"))
    log("2 exec", run(held, "EXEC"), run(c, "MULTI"), run(c, "GET", "a"), run(c, "EXEC"))
    log("2 subscriber", run(sub, "SUBSCRIBE", "ch"), run(sub, "PING"), run(sub, "SET", "x", "1"), run(sub, "GET", "x"))
    log("2 monitor", run(mon, "MONITOR"), run(mon, "SET", "x", "1"), run(mon, "GET", "x"))
    log("2 stats", info(c, "errorstats", "errorstat_MISCONF"),
        re.sub(r"usec=\d+,usec_per_call=[0-9.]+,", "", info(c, "commandstats", "cmdstat_set") or ""),
        re.sub(r"usec=\d+,usec_per_call=[0-9.]+,", "", info(c, "commandstats", "cmdstat_ping") or ""))
    # a CONFIG SET that lifts it or sets it again counts for the commands
    # after it in its own pipeline, alone or in MULTI, as Redis checks
    # each command (writeCommandsDeniedByDiskError in processCommand); and
    # for a pipeline of writes of another client after it
    other = s.conn()
    log("2 pipelines", pipe(c, [["MULTI"], ["CONFIG", "SET", "save", ""], ["EXEC"], ["SET", "a", "2"]]),
        pipe(c, [["MULTI"], ["CONFIG", "SET", "save", "3600 1"], ["EXEC"], ["SET", "a", "3"]]),
        pipe(c, [["CONFIG", "SET", "stop-writes-on-bgsave-error", "no"], ["SET", "a", "4"],
                 ["CONFIG", "SET", "stop-writes-on-bgsave-error", "yes"], ["SET", "a", "5"], ["PING"]]),
        pipe(c, [["CONFIG", "SET", "save", ""], ["INCR", "n"], ["MULTI"], ["SET", "a", "6"], ["EXEC"]]),
        pipe(c, [["CONFIG", "SET", "save", "3600 1"], ["MULTI"], ["SET", "a", "7"], ["EXEC"], ["GET", "a"]]))
    log("2 another client", run(other, "CONFIG", "SET", "save", ""), pipe(c, [["SET", "a", "8"], ["INCR", "n"]]),
        run(other, "CONFIG", "SET", "save", "3600 1"), pipe(c, [["SET", "a", "9"], ["INCR", "n"]]), run(c, "GET", "a"))
    other.sock.close()
    # what lifts it: stop-writes-on-bgsave-error no, no save points, a
    # save that ends well
    log("3 stop-writes no", run(c, "CONFIG", "SET", "stop-writes-on-bgsave-error", "no"), run(c, "SET", "b", "2"),
        run(c, "CONFIG", "SET", "stop-writes-on-bgsave-error", "yes"), run(c, "SET", "b", "3"))
    log("3 no save points", run(c, "CONFIG", "SET", "save", ""), run(c, "SET", "b", "4"),
        run(c, "CONFIG", "SET", "save", "3600 1"), run(c, "SET", "b", "5"))
    log("3 fails again", run(c, "BGSAVE"), until(lambda: not running(c)), field(c, "rdb_last_bgsave_status"), run(c, "SET", "b", "6"))
    shutil.rmtree(os.path.join(d, "dump.rdb"))
    log("3 a save that ends well", run(c, "BGSAVE"), until(lambda: not running(c)), field(c, "rdb_last_bgsave_status"),
        run(c, "SET", "b", "7"), keys_in(d))
    os.remove(os.path.join(d, "dump.rdb"))
    os.makedirs(os.path.join(d, "dump.rdb", "x"))
    log("4 fails", run(c, "BGSAVE"), until(lambda: not running(c)), run(c, "SET", "b", "8"))
    shutil.rmtree(os.path.join(d, "dump.rdb"))
    log("4 SAVE ends well", run(c, "SAVE"), field(c, "rdb_last_bgsave_status"), run(c, "SET", "b", "9"))
    for x in (c, held, sub, mon):
        x.sock.close()
    talk(s.port, [["SHUTDOWN", "NOSAVE"]])
    log("4 exit", s.exit())


def misconf(a, root):
    """a background save that fails: MISCONF for writes and PING, until a
    save ends well or no save point or stop-writes-on-bgsave-error holds"""
    both(a, root, "misconf", misconf_on)


SAVING = "1 changes in 1 seconds. Saving..."


def tries_at(s):
    """the times of the log's lines of the save points' tries (SAVING), in
    seconds"""
    at = []
    for l in s.log().splitlines():
        m = re.match(r"\d+:[A-Z] (\d+ \w+ \d+ \d+:\d+:\d+\.\d+) \S (.*)$", l)
        if m and m.group(2) == SAVING:
            at.append(datetime.datetime.strptime(m.group(1), "%d %b %Y %H:%M:%S.%f").timestamp())
    return at


def retry_on(exe, d, log):
    """the cron tries again 5 seconds after a background save that failed:
    the time between the two tries' lines, as Redis's cron spaces them
    (server.unixtime less lastbgsave_try past CONFIG_BGSAVE_RETRY_DELAY, in
    whole seconds), not from when the test sees the failure, which comes
    after the try (Redis's second try came 4.92 s after it); 0.1 s less
    than 5 for Redis's time(NULL) of lastbgsave_try, which may be a few ms
    behind its log's clock"""
    s = Srv(exe, d, "--save", "1 1")
    c = s.conn()
    os.makedirs(os.path.join(d, "dump.rdb", "x"))
    run(c, "SET", "a", "1")
    log("1 the first try", until(lambda: field(c, "rdb_last_bgsave_status") == "err", timeout=5),
        count_in(s, SAVING))
    time.sleep(3)
    log("1 none within 5 s", count_in(s, SAVING))
    got = until(lambda: count_in(s, SAVING) == 2, timeout=6)
    at = tries_at(s)
    log("1 the next", got, len(at) == 2 and 4.9 <= at[1] - at[0] <= 8)
    shutil.rmtree(os.path.join(d, "dump.rdb"))
    log("2 then one that ends well", until(lambda: field(c, "rdb_last_bgsave_status") == "ok", timeout=10),
        until(lambda: not running(c)), keys_in(d))
    talk(s.port, [["SHUTDOWN", "NOSAVE"]])
    log("2 exit", s.exit())


def retry(a, root):
    """the cron tries again 5 seconds after a save that failed, not before"""
    both(a, root, "retry", retry_on)


def kept_on(exe, d, log):
    """the parameters a save keeps from its start: dbfilename changed in
    BGSAVE's own pipeline, rdb-key-save-delay while it runs, as Redis's
    child keeps them from its fork (rdbchecksum no CONFIG SET changes)"""
    s = Srv(exe, d, "--save", "", "--enable-protected-configs", "yes")
    c = s.conn()
    fill_n(c, 20)
    log("1 pipeline", pipe(c, [["BGSAVE"], ["CONFIG", "SET", "dbfilename", "other.rdb"], ["SET", "late", "1"],
                               ["CONFIG", "SET", "rdbchecksum", "no"]]))
    log("1 ends", until(lambda: not running(c)), field(c, "rdb_last_bgsave_status"))
    log("1 files", keys_in(d) == sorted(b"k%d" % i for i in range(20)), keys_in(d, "other.rdb"), temps(d))
    run(c, "CONFIG", "SET", "dbfilename", "dump.rdb")
    # 20 keys, 50 ms each: the save takes a second though the delay is
    # taken away at once
    run(c, "CONFIG", "SET", "rdb-key-save-delay", "50000")
    t = time.time()
    log("2 bgsave", pipe(c, [["BGSAVE"], ["CONFIG", "SET", "rdb-key-save-delay", "0"]]))
    log("2 ends", until(lambda: not running(c)), 0.8 <= time.time() - t <= 5, field(c, "rdb_last_bgsave_status"))
    talk(s.port, [["SHUTDOWN", "NOSAVE"]])
    log("2 exit", s.exit())


def kept(a, root):
    """the parameters a background save keeps from its start: dbfilename
    and rdb-key-save-delay"""
    both(a, root, "kept", kept_on)


def gone_on(exe, d, log):
    """the temporary file removed while the save runs: the save writes on
    (Redis's child keeps its descriptor), its rename fails, and no
    dump.rdb is put in place"""
    s = Srv(exe, d, "--save", "")
    c = s.conn()
    fill_n(c, 40)
    # 40 keys, 25 ms each: a second
    run(c, "CONFIG", "SET", "rdb-key-save-delay", "25000")
    log("1 bgsave", run(c, "BGSAVE"), until(lambda: running(c)))
    time.sleep(0.3)
    ts = until(lambda: temps(d), timeout=5)
    for f in ts:
        os.remove(os.path.join(d, f))
    log("1 removed", len(ts), running(c))
    log("1 ends", until(lambda: not running(c)), field(c, "rdb_last_bgsave_status"), keys_in(d), temps(d),
        lines_in(s, "Error moving temp DB file temp-", "on the final destination dump.rdb", "No such file or directory",
                 "Background saving error"), count_in(s, "DB saved on disk"))
    log("1 misconf none", run(c, "SET", "a", "1"))
    run(c, "CONFIG", "SET", "rdb-key-save-delay", "0")
    log("2 then", run(c, "BGSAVE"), until(lambda: not running(c)), field(c, "rdb_last_bgsave_status"),
        keys_in(d) == sorted([b"a"] + [b"k%d" % i for i in range(40)]), temps(d))
    talk(s.port, [["SHUTDOWN", "NOSAVE"]])
    log("2 exit", s.exit())


def gone(a, root):
    """a temporary file removed while the save runs: the save fails at its
    rename, and no file is put in place"""
    both(a, root, "gone", gone_on)


def kills_on(exe, d, log):
    """SHUTDOWN and FLUSHALL while a background save runs"""
    def slow(name, *args):
        s = Srv(exe, os.path.join(d, name), *args)
        c = s.conn()
        fill_n(c, 50)
        run(c, "CONFIG", "SET", "rdb-key-save-delay", "50000")
        log(name, "bgsave", run(c, "BGSAVE"), until(lambda: running(c)))
        time.sleep(0.2)
        return s, c
    # SHUTDOWN with save points: the save dropped, the final save made
    s, c = slow("shutdown", "--save", "3600 1")
    log("1 shutdown", talk(s.port, [["SHUTDOWN"]]), s.exit(), keys_in(s.d) == sorted(b"k%d" % i for i in range(50)),
        temps(s.d), lines_in(s, "There is a child saving an .rdb. Killing it!", "Saving the final RDB snapshot before exiting.",
                             "DB saved on disk"))
    # SHUTDOWN NOSAVE: dropped, no file
    s, c = slow("nosave", "--save", "")
    log("2 nosave", talk(s.port, [["SHUTDOWN", "NOSAVE"]]), s.exit(), keys_in(s.d), temps(s.d),
        lines_in(s, "There is a child saving an .rdb. Killing it!"))
    # a SHUTDOWN whose save fails: the server goes on, the background
    # save dropped all the same. The delay is taken away first: the save
    # that runs keeps its own (Redis's child, and BendKV's save, from their
    # start), and Redis's SHUTDOWN, whose save honors the delay, would
    # otherwise take 2.5 s over these 50 keys, its dropped save 2 or 3 s
    # by the second's phase (BendKV's ignores the delay: README.md)
    s, c = slow("cannot", "--save", "3600 1")
    os.makedirs(os.path.join(s.d, "dump.rdb", "x"))
    run(c, "CONFIG", "SET", "rdb-key-save-delay", "0")
    log("3 cannot", run(c, "SHUTDOWN"), until(lambda: not running(c)), field(c, "rdb_last_bgsave_status"),
        0 <= int(field(c, "rdb_last_bgsave_time_sec")) <= 2, temps(s.d),
        lines_in(s, "There is a child saving an .rdb. Killing it!", "Error trying to save the DB, can't exit.",
                 "Background saving terminated by signal 10"))
    log("3 then", run(c, "BGSAVE"), until(lambda: not running(c)), field(c, "rdb_last_bgsave_status"))
    shutil.rmtree(os.path.join(s.d, "dump.rdb"))
    talk(s.port, [["SHUTDOWN", "NOSAVE"]])
    log("3 exit", s.exit())
    # FLUSHALL without save points: dropped, no file
    s, c = slow("flushall", "--save", "")
    log("4 flushall", run(c, "FLUSHALL"), until(lambda: not running(c)), keys_in(s.d), temps(s.d),
        field(c, "rdb_last_bgsave_status"), lines_in(s, "Background saving terminated by signal 10"),
        field(c, "rdb_changes_since_last_save"))
    talk(s.port, [["SHUTDOWN", "NOSAVE"]])
    log("4 exit", s.exit())
    # FLUSHALL with save points: dropped, and the empty databases saved
    s, c = slow("flushall-points", "--save", "3600 1")
    log("5 flushall", run(c, "FLUSHALL"), until(lambda: not running(c)), keys_in(s.d), temps(s.d),
        field(c, "rdb_last_bgsave_status"), lines_in(s, "Background saving terminated by signal 10", "DB saved on disk"),
        field(c, "rdb_changes_since_last_save"))
    talk(s.port, [["SHUTDOWN", "NOSAVE"]])
    log("5 exit", s.exit())


def kills(a, root):
    """SHUTDOWN and FLUSHALL while a background save runs: it is dropped,
    its temporary file removed"""
    both(a, root, "kills", kills_on)


def defaults_on(exe, d, log):
    """the default save points, and SHUTDOWN's save with them"""
    s = Srv(exe, d)
    c = s.conn()
    log("1 save", run(c, "CONFIG", "GET", "save"), run(c, "CONFIG", "GET", "stop-writes-on-bgsave-error"))
    run(c, "SET", "a", "1")
    log("1 shutdown", talk(s.port, [["SHUTDOWN"]]), s.exit(), keys_in(d))


def defaults(a, root):
    """the default save points: Redis's, and SHUTDOWN saves with them"""
    both(a, root, "defaults", defaults_on)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bendkv", "--bin", dest="bin", default="build/bendkv")
    ap.add_argument("--redis", default="redis-server")
    ap.add_argument("--dir", default="build/bgsave")
    ap.add_argument("--only", default="")
    a = ap.parse_args()
    a.bin = os.path.abspath(a.bin)
    root = os.path.abspath(a.dir)
    shutil.rmtree(root, ignore_errors=True)
    os.makedirs(root)
    parts = [counts, bgsave, rewrite, points, misconf, retry, kept, gone, kills, defaults]
    try:
        for part in parts:
            if a.only and part.__name__ not in a.only.split(","):
                continue
            b0 = rdb_test.bad
            part(a, root)
            print("%s %s" % ("OK:  " if rdb_test.bad == b0 else "FAIL:", " ".join(part.__doc__.split())))
    finally:
        for s in rdb_test.SERVERS:
            s.kill()
    if rdb_test.bad:
        print("FAIL: %d of %d checks" % (rdb_test.bad, rdb_test.n))
        sys.exit(1)
    print("ALL OK: %d checks of background saves" % rdb_test.n)


if __name__ == "__main__":
    main()
