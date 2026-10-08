# redis.bend: the semantics of the Redis commands BendKV serves, as one
# pure function exec(cmd, db) -> (reply, db'). The server (server.bend)
# only moves bytes and calls exec in order, as Redis's single command
# thread does, so every law about exec is a law about the running server.

import Base
import ./map.bend as KV

# Types
# -----

# the database: string keys to string values (Redis strings are bytes;
# BendKV keeps one byte per Char)
def DB() -> Data:
  KV.Trie<String>

# an integer: IPos{n} is n, INeg{n} is -(n+1), so each integer has one form
type Int is Data:
  IPos{n: Nat}
  INeg{n: Nat}

# an element of an array reply
type Item is Data:
  IBulk{s: String}
  INull{}

# a RESP2 reply
type Reply is Data:
  RStatus{s: String}
  RError{s: String}
  RInt{i: Int}
  RBulk{s: String}
  RNull{}
  RArray{xs: List<&2, Item>}

# a key and a value, for MSET
type KVPair is Data:
  KP{key: String, val: String}

# a parsed command. SizeAt, KeysAt and FlushAt are DBSIZE, KEYS and
# FLUSHALL on the root's subtrie at one digit: a server with several
# shards runs those three as one of these for each digit, each on the
# shard that holds the digit (shard.bend); no request parses into them.
type Cmd is Data:
  Ping{}
  Echo{msg: String}
  Get{key: String}
  Set{key: String, val: String}
  SetNX{key: String, val: String}
  GetSet{key: String, val: String}
  Del{keys: List<&2, String>}
  Exists{keys: List<&2, String>}
  IncrBy{key: String, by: Int}
  Append{key: String, val: String}
  Strlen{key: String}
  MGet{keys: List<&2, String>}
  MSet{pairs: List<&2, KVPair>}
  DbSize{}
  FlushAll{}
  Keys{pattern: String}
  Bad{reply: Reply}
  SizeAt{x: KV.Hex}
  KeysAt{pattern: String, x: KV.Hex}
  FlushAt{x: KV.Hex}

# Integers
# --------
# Redis integers are 64-bit; BendKV's are bounded by 14 decimal digits,
# so every sum of two stays below 2^48, where Bend's Nat must stay.

def int_sub_nat(+x: Nat, +y: Nat) -> Int:
  Bool.pick(Int, Nat.is_lt(x, y), INeg{Nat.sub(Nat.sub(y, x), 1n)}, IPos{Nat.sub(x, y)})

def int_add(a: Int, b: Int) -> Int:
  match a b:
    case IPos{x} IPos{y}:
      IPos{Nat.add(x, y)}
    case INeg{x} INeg{y}:
      INeg{1n+Nat.add(x, y)}
    case IPos{x} INeg{y}:
      int_sub_nat(x, 1n+y)
    case INeg{x} IPos{y}:
      int_sub_nat(y, 1n+x)

def int_neg(a: Int) -> Int:
  match a:
    case IPos{n}:
      match n:
        case 0n:
          IPos{0n}
        case 1n+p:
          INeg{p}
    case INeg{n}:
      IPos{1n+n}

def int_show(a: Int) -> String:
  match a:
    case IPos{n}:
      Nat.show(n)
    case INeg{n}:
      "-" ++ Nat.show(1n+n)

def int_mag(a: Int) -> Nat:
  match a:
    case IPos{n}:
      n
    case INeg{n}:
      1n+n

# the digit a code point stands for, when it is one
def int_digit.if(x: U32, ok: Bool) -> Maybe<&2, Nat>:
  match ok:
    case True{}:
      Some{U32.to_nat(U32.sub(x, 48))}
    case False{}:
      None{}

def int_digit(+x: U32) -> Maybe<&2, Nat>:
  int_digit.if(x, Bool.and(U32.is_ge(x, 48), U32.is_le(x, 57)))

def int_step(acc: Maybe<&2, Nat>, d: Maybe<&2, Nat>) -> Maybe<&2, Nat>:
  match acc d:
    case Some{a} Some{n}:
      Some{Nat.add(Nat.mul(a, 10n), n)}
    case _ _:
      None{}

# the k digits of s from index i, read left to right; None when one is not
# a digit. The string is read by index (String.code_at), not taken apart.
def int_digits(+s: String, k: Nat, +i: Nat, acc: Maybe<&2, Nat>) -> Maybe<&2, Nat>:
  match k:
    case 0n:
      acc
    case 1n+p:
      int_digits(s, p, Nat.add(i, 1n), int_step(acc, int_digit(String.code_at(s, i))))

# the n characters of s from index i as a magnitude: "0", or 1 to 14
# digits with no leading zero
def int_mag_read.gate(+s: String, +i: Nat, +n: Nat, ok: Bool) -> Maybe<&2, Nat>:
  match ok:
    case True{}:
      int_digits(s, n, i, Some{0n})
    case False{}:
      None{}

def int_mag_read(+s: String, +i: Nat, +n: Nat) -> Maybe<&2, Nat>:
  int_mag_read.gate(s, i, n, Bool.and(Bool.and(Nat.is_lt(0n, n), Nat.is_le(n, 14n)), Bool.or(Nat.is_eq(n, 1n), U32.is_ne(String.code_at(s, i), 48))))

def int_neg_of(m: Maybe<&2, Nat>) -> Maybe<&2, Int>:
  match m:
    case Some{n}:
      match n:
        case 0n:
          None{}
        case 1n+p:
          Some{INeg{p}}
    case None{}:
      None{}

def int_pos_of(m: Maybe<&2, Nat>) -> Maybe<&2, Int>:
  match m:
    case Some{n}:
      Some{IPos{n}}
    case None{}:
      None{}

def int_read.sign(+s: String, +n: Nat, neg: Bool) -> Maybe<&2, Int>:
  match neg:
    case True{}:
      int_neg_of(int_mag_read(s, 1n, Nat.sub(n, 1n)))
    case False{}:
      int_pos_of(int_mag_read(s, 0n, n))

# an integer in Redis's canonical form: an optional '-', no leading
# zeros, no '+', no spaces ("-0" is refused, as Redis does)
def int_read(+s: String) -> Maybe<&2, Int>:
  +n = String.length(s)
  int_read.sign(s, n, U32.is_eq(String.code_at(s, 0n), 45))

# an integer fits when its magnitude has at most 14 digits
def int_fits(a: Int) -> Bool:
  Nat.is_le(String.length(Nat.show(int_mag(a))), 14n)

# Replies
# -------

def r_ok() -> Reply:
  RStatus{"OK"}

def r_int(n: Nat) -> Reply:
  RInt{IPos{n}}

def r_get(m: Maybe<&2, String>) -> Reply:
  match m:
    case Some{s}:
      RBulk{s}
    case None{}:
      RNull{}

def i_get(m: Maybe<&2, String>) -> Item:
  match m:
    case Some{s}:
      IBulk{s}
    case None{}:
      INull{}

def e_arity(name: String) -> Cmd:
  Bad{RError{"ERR wrong number of arguments for '" ++ String.to_lower(name) ++ "' command"}}

def e_int() -> Reply:
  RError{"ERR value is not an integer or out of range"}

def e_syntax() -> Cmd:
  Bad{RError{"ERR syntax error"}}

# Parsing
# -------
# a command arrives as its argument strings; the name is not case
# sensitive

# the pairs of MSET, or None on an odd count
def pairs.put(k: String, v: String, m: Maybe<&2, List<&2, KVPair>>) -> Maybe<&2, List<&2, KVPair>>:
  match m:
    case Some{ps}:
      Some{KP{k, v} <> ps}
    case None{}:
      None{}

def pairs(xs: List<&2, String>) -> Maybe<&2, List<&2, KVPair>>:
  match xs:
    case Nil{}:
      Some{Nil{}}
    case Con{k, Nil{}}:
      None{}
    case Con{k, Con{v, rest}}:
      pairs.put(k, v, pairs(rest))

def parse_mset(ps: Maybe<&2, List<&2, KVPair>>) -> Cmd:
  match ps:
    case Some{Nil{}}:
      e_arity("mset")
    case Some{Con{p, rest}}:
      MSet{p <> rest}
    case None{}:
      e_arity("mset")

def parse_incrby(k: String, by: Maybe<&2, Int>) -> Cmd:
  match by:
    case Some{n}:
      IncrBy{k, n}
    case None{}:
      Bad{e_int()}

def parse_decrby(k: String, by: Maybe<&2, Int>) -> Cmd:
  match by:
    case Some{n}:
      IncrBy{k, int_neg(n)}
    case None{}:
      Bad{e_int()}

# A command's name, in upper case, picks how its arguments parse. The
# name's length narrows it down to a few names, which cmd_id compares with
# it whole: String.eq with a literal is one memcmp, cheap enough that
# Bool.pick computes all of them. parse_id goes by the name's number, 0
# for a name no command has.
def cmd_id(+n: String, len: Nat) -> Nat:
  match len:
    case 3n:
      Bool.pick(Nat, String.eq(n, "GET"), 3n,
      Bool.pick(Nat, String.eq(n, "SET"), 4n,
      Bool.pick(Nat, String.eq(n, "DEL"), 7n, 0n)))
    case 4n:
      Bool.pick(Nat, String.eq(n, "PING"), 1n,
      Bool.pick(Nat, String.eq(n, "ECHO"), 2n,
      Bool.pick(Nat, String.eq(n, "INCR"), 10n,
      Bool.pick(Nat, String.eq(n, "DECR"), 11n,
      Bool.pick(Nat, String.eq(n, "MGET"), 16n,
      Bool.pick(Nat, String.eq(n, "MSET"), 17n,
      Bool.pick(Nat, String.eq(n, "KEYS"), 21n, 0n)))))))
    case 5n:
      Bool.pick(Nat, String.eq(n, "SETNX"), 5n, 0n)
    case 6n:
      Bool.pick(Nat, String.eq(n, "GETSET"), 6n,
      Bool.pick(Nat, String.eq(n, "UNLINK"), 8n,
      Bool.pick(Nat, String.eq(n, "EXISTS"), 9n,
      Bool.pick(Nat, String.eq(n, "INCRBY"), 12n,
      Bool.pick(Nat, String.eq(n, "DECRBY"), 13n,
      Bool.pick(Nat, String.eq(n, "APPEND"), 14n,
      Bool.pick(Nat, String.eq(n, "STRLEN"), 15n,
      Bool.pick(Nat, String.eq(n, "DBSIZE"), 18n,
      Bool.pick(Nat, String.eq(n, "CONFIG"), 23n,
      Bool.pick(Nat, String.eq(n, "SELECT"), 24n, 0n))))))))))
    case 7n:
      Bool.pick(Nat, String.eq(n, "FLUSHDB"), 20n,
      Bool.pick(Nat, String.eq(n, "COMMAND"), 22n, 0n))
    case 8n:
      Bool.pick(Nat, String.eq(n, "FLUSHALL"), 19n, 0n)
    case _:
      0n

def parse_id(id: Nat, name: String, args: List<&2, String>) -> Cmd:
  match id:
    case 1n:  # PING
      match args:
        case Nil{}:
          Ping{}
        case Con{m, Nil{}}:
          Echo{m}
        case _:
          e_arity("ping")
    case 2n:  # ECHO
      match args:
        case Con{m, Nil{}}:
          Echo{m}
        case _:
          e_arity("echo")
    case 3n:  # GET
      match args:
        case Con{k, Nil{}}:
          Get{k}
        case _:
          e_arity("get")
    case 4n:  # SET
      match args:
        case Con{k, Con{v, Nil{}}}:
          Set{k, v}
        case Con{k, Con{v, Con{o, os}}}:
          e_syntax()
        case _:
          e_arity("set")
    case 5n:  # SETNX
      match args:
        case Con{k, Con{v, Nil{}}}:
          SetNX{k, v}
        case _:
          e_arity("setnx")
    case 6n:  # GETSET
      match args:
        case Con{k, Con{v, Nil{}}}:
          GetSet{k, v}
        case _:
          e_arity("getset")
    case 7n:  # DEL
      match args:
        case Nil{}:
          e_arity("del")
        case Con{k, ks}:
          Del{k <> ks}
    case 8n:  # UNLINK
      match args:
        case Nil{}:
          e_arity("unlink")
        case Con{k, ks}:
          Del{k <> ks}
    case 9n:  # EXISTS
      match args:
        case Nil{}:
          e_arity("exists")
        case Con{k, ks}:
          Exists{k <> ks}
    case 10n:  # INCR
      match args:
        case Con{k, Nil{}}:
          IncrBy{k, IPos{1n}}
        case _:
          e_arity("incr")
    case 11n:  # DECR
      match args:
        case Con{k, Nil{}}:
          IncrBy{k, INeg{0n}}
        case _:
          e_arity("decr")
    case 12n:  # INCRBY
      match args:
        case Con{k, Con{n, Nil{}}}:
          parse_incrby(k, int_read(n))
        case _:
          e_arity("incrby")
    case 13n:  # DECRBY
      match args:
        case Con{k, Con{n, Nil{}}}:
          parse_decrby(k, int_read(n))
        case _:
          e_arity("decrby")
    case 14n:  # APPEND
      match args:
        case Con{k, Con{v, Nil{}}}:
          Append{k, v}
        case _:
          e_arity("append")
    case 15n:  # STRLEN
      match args:
        case Con{k, Nil{}}:
          Strlen{k}
        case _:
          e_arity("strlen")
    case 16n:  # MGET
      match args:
        case Nil{}:
          e_arity("mget")
        case Con{k, ks}:
          MGet{k <> ks}
    case 17n:  # MSET
      parse_mset(pairs(args))
    case 18n:  # DBSIZE
      match args:
        case Nil{}:
          DbSize{}
        case _:
          e_arity("dbsize")
    case 19n:  # FLUSHALL
      FlushAll{}
    case 20n:  # FLUSHDB
      FlushAll{}
    case 21n:  # KEYS
      match args:
        case Con{p, Nil{}}:
          Keys{p}
        case _:
          e_arity("keys")
    case 22n:  # COMMAND
      Bad{RArray{Nil{}}}
    case 23n:  # CONFIG
      Bad{RArray{Nil{}}}
    case 24n:  # SELECT
      Bad{r_ok()}
    case _:
      Bad{RError{"ERR unknown command '" ++ String.to_lower(name) ++ "'"}}

def parse_named(name: String, args: List<&2, String>) -> Cmd:
  +n = name
  parse_id(cmd_id(n, String.length(n)), n, args)

def parse(args: List<&2, String>) -> Cmd:
  match args:
    case Nil{}:
      Bad{RError{"ERR empty command"}}
    case Con{name, rest}:
      parse_named(String.to_upper(name), rest)

# Glob patterns (KEYS)
# --------------------
# '*' matches any run, '?' any one byte; other bytes match themselves

def glob(+p: String, +s: String) -> Bool:
  match p:
    case SNil{}:
      String.is_empty(s)
    case SCon{'*', pt}:
      match s:
        case SNil{}:
          glob(pt, SNil{})
        case SCon{c, st}:
          Bool.or(glob(pt, SCon{c, st}), glob(p, st))
    case SCon{'?', pt}:
      match s:
        case SNil{}:
          False{}
        case SCon{c, st}:
          glob(pt, st)
    case SCon{c, pt}:
      match s:
        case SNil{}:
          False{}
        case SCon{d, st}:
          Bool.and(Char.is_eq(c, d), glob(pt, st))

def glob_keep(+k: String, ks: List<&2, Item>, hit: Bool) -> List<&2, Item>:
  match hit:
    case True{}:
      IBulk{k} <> ks
    case False{}:
      ks

def glob_filter(+p: String, ks: List<&2, String>) -> List<&2, Item>:
  match ks:
    case Nil{}:
      Nil{}
    case Con{+k, rest}:
      glob_keep(k, glob_filter(p, rest), glob(p, k))

# Execution
# ---------

def setnx.if(db: KV.Trie<String>, +k: String, v: String, +h: U32, had: Bool) -> Reply & KV.Trie<String>:
  match had:
    case True{}:
      (r_int(0n), db)
    case False{}:
      (r_int(1n), KV.set.at(String, db, k, v, h))

def del_keys.put(had: Bool, r: Nat & KV.Trie<String>) -> Nat & KV.Trie<String>:
  match had:
    case True{}:
      (n, db) = r
      (1n+n, db)
    case False{}:
      r

# DEL: the keys removed in order, and how many of them were present
def del_keys(ks: List<&2, String>, +db: KV.Trie<String>) -> Nat & KV.Trie<String>:
  match ks:
    case Nil{}:
      (0n, db)
    case Con{+k, rest}:
      del_keys.put(KV.has(String, db, k), del_keys(rest, KV.del(String, db, k)))


# EXISTS: how many of the keys are present (a repeated key counts again)
def exists_keys(ks: List<&2, String>, +db: KV.Trie<String>) -> Nat:
  match ks:
    case Nil{}:
      0n
    case Con{+k, rest}:
      Nat.add(Bool.pick(Nat, Maybe.is_some(&2, String, KV.get(String, db, k)), 1n, 0n), exists_keys(rest, db))

def mget_keys(ks: List<&2, String>, +db: KV.Trie<String>) -> List<&2, Item>:
  match ks:
    case Nil{}:
      Nil{}
    case Con{+k, rest}:
      i_get(KV.get(String, db, k)) <> mget_keys(rest, db)

def mset_pairs(ps: List<&2, KVPair>, db: KV.Trie<String>) -> KV.Trie<String>:
  match ps:
    case Nil{}:
      db
    case Con{KP{k, v}, rest}:
      mset_pairs(rest, KV.set(String, db, k, v))

# INCRBY: the stored value must read as an integer, and the sum must fit
def incr.fit(db: KV.Trie<String>, +k: String, +h: U32, +n: Int, ok: Bool) -> Reply & KV.Trie<String>:
  match ok:
    case True{}:
      (RInt{n}, KV.set.at(String, db, k, int_show(n), h))
    case False{}:
      (RError{"ERR increment or decrement would overflow"}, db)

def incr.got(db: KV.Trie<String>, +k: String, +h: U32, by: Int, cur: Maybe<&2, Int>) -> Reply & KV.Trie<String>:
  match cur:
    case Some{x}:
      +n = int_add(x, by)
      incr.fit(db, k, h, n, int_fits(n))
    case None{}:
      (e_int(), db)

def incr.old(m: Maybe<&2, String>) -> Maybe<&2, Int>:
  match m:
    case Some{s}:
      int_read(s)
    case None{}:
      Some{IPos{0n}}

def append_to(m: Maybe<&2, String>, v: String) -> String:
  match m:
    case Some{s}:
      s ++ v
    case None{}:
      v

def strlen_of(m: Maybe<&2, String>) -> Nat:
  match m:
    case Some{s}:
      String.length(s)
    case None{}:
      0n

def del_reply(r: Nat & KV.Trie<String>) -> Reply & KV.Trie<String>:
  (n, db) = r
  (r_int(n), db)

def reply_of(r: Reply & KV.Trie<String>) -> Reply:
  (x, db) = r
  x

def db_of(r: Reply & KV.Trie<String>) -> KV.Trie<String>:
  (x, db) = r
  db

# one command: its reply and the database after it. The database is
# passed on, not shared, so a write rebuilds only the path it changes.
# A key read only reads the trie: the compiler lends d to KV.get and then
# hands d back, and the value it answers is kept in place, shared with the
# trie (Bend with bend-patches/borrow-reads.patch). DBSIZE and KEYS fold
# the whole trie, so they share it; FLUSHALL empties the subtrie under
# every digit, as FlushAt does under one. A command that reads a key and then
# writes it hashes the key once (KV.get.at, KV.set.at: KV.get and KV.set
# with the hash given, as they compute it).
def exec(cmd: Cmd, db: KV.Trie<String>) -> Reply & KV.Trie<String>:
  match cmd:
    case Ping{}:
      (RStatus{"PONG"}, db)
    case Echo{m}:
      (RBulk{m}, db)
    case Get{+k}:
      +d = db
      (r_get(KV.get(String, d, k)), d)
    case Set{+k, v}:
      (r_ok(), KV.set(String, db, k, v))
    case SetNX{+k, v}:
      +d = db
      +h = KV.hash(k)
      setnx.if(d, k, v, h, Maybe.is_some(&2, String, KV.get.at(String, d, k, h)))
    case GetSet{+k, v}:
      +d = db
      +h = KV.hash(k)
      (r_get(KV.get.at(String, d, k, h)), KV.set.at(String, d, k, v, h))
    case Del{ks}:
      del_reply(del_keys(ks, db))
    case Exists{ks}:
      +d = db
      (r_int(exists_keys(ks, d)), d)
    case IncrBy{+k, by}:
      +d = db
      +h = KV.hash(k)
      incr.got(d, k, h, by, incr.old(KV.get.at(String, d, k, h)))
    case Append{+k, v}:
      +d = db
      +h = KV.hash(k)
      +s = append_to(KV.get.at(String, d, k, h), v)
      (r_int(String.length(s)), KV.set.at(String, d, k, s, h))
    case Strlen{+k}:
      +d = db
      (r_int(strlen_of(KV.get(String, d, k))), d)
    case MGet{ks}:
      +d = db
      (RArray{mget_keys(ks, d)}, d)
    case MSet{ps}:
      (r_ok(), mset_pairs(ps, db))
    case DbSize{}:
      +d = db
      (r_int(KV.size(String, d)), d)
    case FlushAll{}:
      (r_ok(), KV.clear(String, db))
    case Keys{p}:
      +d = db
      (RArray{glob_filter(p, KV.keys(String, d))}, d)
    case Bad{r}:
      (r, db)
    case SizeAt{x}:
      +d = db
      (r_int(KV.size.at(String, d, x)), d)
    case KeysAt{p, x}:
      +d = db
      (RArray{glob_filter(p, KV.keys.at(String, d, x, Nil{}))}, d)
    case FlushAt{+x}:
      (r_ok(), KV.with_child(String, db, x, KV.empty(String)))

# The key's hash, given
# ---------------------
# The server hashes a key before the command runs: for the hints of
# batch.bend, and to pick its shard (shard.bend). exec.at runs a command
# with that hash for its key, so the key is hashed once: a command on one
# key walks the trie with the hash given, and the rest hash their keys
# themselves, as exec does. GET answers a copy of the value, made while the
# trie is lent (KV.get_copy.at), so the trie keeps the value unshared: no
# seal is put on the entry, and the batch hints reach the value's bytes.
# LAWS.bend (exec_at): with a hash that fits the command (the hash of its
# key), exec.at is exec.
def exec.at(cmd: Cmd, +h: U32, db: KV.Trie<String>) -> Reply & KV.Trie<String>:
  match cmd:
    case Get{+k}:
      +d = db
      (r_get(KV.get_copy.at(d, k, h)), d)
    case Set{+k, v}:
      (r_ok(), KV.set.at(String, db, k, v, h))
    case SetNX{+k, v}:
      +d = db
      setnx.if(d, k, v, h, Maybe.is_some(&2, String, KV.get.at(String, d, k, h)))
    case GetSet{+k, v}:
      +d = db
      (r_get(KV.get.at(String, d, k, h)), KV.set.at(String, d, k, v, h))
    case IncrBy{+k, by}:
      +d = db
      incr.got(d, k, h, by, incr.old(KV.get.at(String, d, k, h)))
    case Append{+k, v}:
      +d = db
      +s = append_to(KV.get.at(String, d, k, h), v)
      (r_int(String.length(s)), KV.set.at(String, d, k, s, h))
    case Strlen{+k}:
      +d = db
      (r_int(strlen_of(KV.get.at(String, d, k, h))), d)
    case other:
      exec(other, db)

# a batch of commands, in order: the replies in order, and the database
# after the last
def exec_all.put(rs: List<&2, Reply>, r: Reply & KV.Trie<String>) -> List<&2, Reply> & KV.Trie<String>:
  (x, db) = r
  (x <> rs, db)

def exec_all.step(c: Cmd, st: List<&2, Reply> & KV.Trie<String>) -> List<&2, Reply> & KV.Trie<String>:
  (rs, db) = st
  exec_all.put(rs, exec(c, db))

def exec_all.go(cmds: List<&2, Cmd>, st: List<&2, Reply> & KV.Trie<String>) -> List<&2, Reply> & KV.Trie<String>:
  match cmds:
    case Nil{}:
      st
    case Con{c, rest}:
      exec_all.go(rest, exec_all.step(c, st))

def exec_all.fin(st: List<&2, Reply> & KV.Trie<String>) -> List<&2, Reply> & KV.Trie<String>:
  (rs, db) = st
  (List.reverse(&2, Reply, rs), db)

# a reply in front of a batch's replies (the spec of exec_all uses it)
def exec_all.cons(r: Reply, rest: List<&2, Reply> & KV.Trie<String>) -> List<&2, Reply> & KV.Trie<String>:
  (rs, db) = rest
  (r <> rs, db)

def exec_all(cmds: List<&2, Cmd>, db: KV.Trie<String>) -> List<&2, Reply> & KV.Trie<String>:
  exec_all.fin(exec_all.go(cmds, (Nil{}, db)))

# a batch with the hashes of its keys, as exec_all runs it (exec_all once
# the hashes run out)
def exec_all.step.at(c: Cmd, +h: U32, st: List<&2, Reply> & KV.Trie<String>) -> List<&2, Reply> & KV.Trie<String>:
  (rs, db) = st
  exec_all.put(rs, exec.at(c, h, db))

def exec_all.go.at(cmds: List<&2, Cmd>, hs: List<&2, U32>, st: List<&2, Reply> & KV.Trie<String>) -> List<&2, Reply> & KV.Trie<String>:
  match cmds hs:
    case Con{c, rest} Con{h, hrest}:
      exec_all.go.at(rest, hrest, exec_all.step.at(c, h, st))
    case Con{c, rest} Nil{}:
      exec_all.go(Con{c, rest}, st)
    case Nil{} _:
      st

def exec_all.at(cmds: List<&2, Cmd>, hs: List<&2, U32>, db: KV.Trie<String>) -> List<&2, Reply> & KV.Trie<String>:
  exec_all.fin(exec_all.go.at(cmds, hs, (Nil{}, db)))
