# aof.bend: the append-only file. After each batch the server appends what
# its commands did (effects), each entry written as Redis writes its AOF:
# a RESP array of bulk strings. At start it reads the file back (load),
# parses each entry (R.parse) and runs the entries from an empty database
# (restore). LAWS.bend (Persistence) proves that this gives back exactly
# the database the server had: the file reads back as the entries written
# to it, each entry parses back to its command, and the effects of a batch
# leave the database the batch left.

import Base
import ./map.bend as KV
import ./redis.bend as R
import ./resp.bend as P
import ./batch.bend as B

# Effects
# -------
# What a command did, as commands that do it again on the database it ran
# on: none for one that only reads or fails, the command itself for the
# other writes, and for an INCRBY that stored n the SET of n (as Redis logs
# INCRBYFLOAT), so that no number is ever read back from text. The reply
# tells which: an effect needs no second look at the database, which the
# command alone owns.

def incr.effect(k: String, r: R.Reply) -> List<&2, R.Cmd>:
  match r:
    case R.RInt{n}:
      [R.Set{k, R.int_show(n)}]
    case _:
      Nil{}

def effect(c: R.Cmd, r: R.Reply) -> List<&2, R.Cmd>:
  match c:
    case R.Set{k, v}:
      [R.Set{k, v}]
    case R.SetNX{k, v}:
      [R.SetNX{k, v}]
    case R.GetSet{k, v}:
      [R.GetSet{k, v}]
    case R.IncrBy{k, by}:
      incr.effect(k, r)
    case R.Append{k, v}:
      [R.Append{k, v}]
    case R.Del{Con{k, ks}}:
      [R.Del{k <> ks}]
    case R.MSet{Con{p, ps}}:
      [R.MSet{p <> ps}]
    case R.FlushAll{}:
      [R.FlushAll{}]
    case _:
      Nil{}

# a batch run with its effects: the replies, what the batch did, in
# order, and the database after it, as exec_all runs it
def log.put(rs: List<&2, R.Reply>, es: List<&2, R.Cmd>, c: R.Cmd, r: R.Reply & KV.Trie<String>) -> List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>):
  (+x, db) = r
  (x <> rs, (List.reverse.go(&2, R.Cmd, effect(c, x), es), db))

def log.run(rs: List<&2, R.Reply>, +c: R.Cmd, q: List<&2, R.Cmd> & KV.Trie<String>) -> List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>):
  (es, db) = q
  log.put(rs, es, c, R.exec(c, db))

def log.step(c: R.Cmd, st: List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>)) -> List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>):
  (rs, q) = st
  log.run(rs, c, q)

def log.go(cs: List<&2, R.Cmd>, st: List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>)) -> List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>):
  match cs:
    case Nil{}:
      st
    case Con{c, rest}:
      log.go(rest, log.step(c, st))

def log.fin2(q: List<&2, R.Cmd> & KV.Trie<String>) -> List<&2, R.Cmd> & KV.Trie<String>:
  (es, db) = q
  (List.reverse(&2, R.Cmd, es), db)

def log.fin(st: List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>)) -> List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>):
  (rs, q) = st
  (List.reverse(&2, R.Reply, rs), log.fin2(q))

def exec_log(cs: List<&2, R.Cmd>, db: KV.Trie<String>) -> List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>):
  log.fin(log.go(cs, (Nil{}, (Nil{}, db))))

# a batch run with its effects after the hints of batch.bend (the trie
# paths of its keys start loading into the cache first), as exec_batch
# runs one; LAWS.bend (log_hints) makes it exec_log
def log_hinted(u: Bool, cs: List<&2, R.Cmd>, db: KV.Trie<String>) -> List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>):
  match u:
    case True{}:
      exec_log(cs, db)
    case False{}:
      exec_log(cs, db)

def log_batch(cs: List<&2, R.Cmd>, hs: List<&2, U32>, db: KV.Trie<String>) -> List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>):
  +d = db
  +h = hs
  log_hinted(U32.is_eq(B.touch_if(B.many(h), h, d), 0), cs, d)

# Entries
# -------

def pair_args(ps: List<&2, R.KVPair>) -> List<&2, String>:
  match ps:
    case Nil{}:
      Nil{}
    case Con{R.KP{k, v}, rest}:
      k <> v <> pair_args(rest)

# a logged command as the strings of a request that parses back to it
# (none for a command no effect is: they are never logged)
def args(c: R.Cmd) -> List<&2, String>:
  match c:
    case R.Set{k, v}:
      ["SET", k, v]
    case R.SetNX{k, v}:
      ["SETNX", k, v]
    case R.GetSet{k, v}:
      ["GETSET", k, v]
    case R.Append{k, v}:
      ["APPEND", k, v]
    case R.Del{ks}:
      "DEL" <> ks
    case R.MSet{ps}:
      "MSET" <> pair_args(ps)
    case R.FlushAll{}:
      ["FLUSHALL"]
    case _:
      Nil{}

def args_all(cs: List<&2, R.Cmd>) -> List<&2, List<&2, String>>:
  match cs:
    case Nil{}:
      Nil{}
    case Con{c, rest}:
      args(c) <> args_all(rest)

def parse_all(reqs: List<&2, List<&2, String>>) -> List<&2, R.Cmd>:
  match reqs:
    case Nil{}:
      Nil{}
    case Con{r, rest}:
      R.parse(r) <> parse_all(rest)

# Writing
# -------
# An entry is "*<count>\r\n", then each string as "$<length>\r\n<bytes>\r\n"
# (resp.bend's bulk_into, as a reply writes a bulk). Each piece is written
# in front of what follows it, so a batch's entries are one String,
# appended to the file at once.

def bulks.onto(xs: List<&2, String>, rest: String) -> String:
  match xs:
    case Nil{}:
      rest
    case Con{x, more}:
      P.bulk_into(x, bulks.onto(more, rest))

def entry.onto(+xs: List<&2, String>, rest: String) -> String:
  "*" ++ Nat.show(List.length(&2, String, xs)) ++ P.crlf() ++ bulks.onto(xs, rest)

def encode.onto(reqs: List<&2, List<&2, String>>, rest: String) -> String:
  match reqs:
    case Nil{}:
      rest
    case Con{r, more}:
      entry.onto(r, encode.onto(more, rest))

def encode(reqs: List<&2, List<&2, String>>) -> String:
  encode.onto(reqs, "")

# Reading
# -------
# A plain parser, one char at a time, over the whole file: each step
# looks at the next char (ch) before it is taken, so that it can match on
# it. A file that ends inside an entry (a crash during a write) loads up
# to that entry, and load says what is left.

# what a char is to a number line: a digit and its value, the '\r' that
# ends the line, or anything else
type Ch is Data:
  CDigit{d: Nat}
  CEnd{}
  COther{}

def ch.of(+x: U32, dig: Bool, cr: Bool) -> Ch:
  match dig cr:
    case True{} _:
      CDigit{U32.to_nat(U32.sub(x, 48))}
    case False{} True{}:
      CEnd{}
    case False{} False{}:
      COther{}

def ch(s: String) -> Ch:
  match s:
    case SCon{Chr{+x}, t}:
      ch.of(x, U32.is_lt(U32.sub(x, 48), 10), U32.is_eq(x, 13))
    case SNil{}:
      COther{}

def num.lf(acc: Nat, s: String) -> Maybe<&1, Nat & String>:
  match s:
    case SCon{'\n', t}:
      Some{(acc, t)}
    case _:
      None{}

# the number a line of digits spells, read on after acc, and what follows
# its "\r\n"; c is what s's first char is
def num(s: String, acc: Nat, c: Ch) -> Maybe<&1, Nat & String>:
  match s c:
    case SCon{h, +t} CDigit{d}:
      num(t, Nat.add(Nat.mul(acc, 10n), d), ch(t))
    case SCon{h, t} CEnd{}:
      num.lf(acc, t)
    case _ _:
      None{}

def bulk.lf(arg: String, s: String) -> Maybe<&1, String & String>:
  match s:
    case SCon{'\n', t}:
      Some{(arg, t)}
    case _:
      None{}

def bulk.end(arg: String, s: String) -> Maybe<&1, String & String>:
  match s:
    case SCon{'\r', t}:
      bulk.lf(arg, t)
    case _:
      None{}

def bulk.body(m: Maybe<&1, Nat & String>) -> Maybe<&1, String & String>:
  match m:
    case Some{p}:
      (+n, +r) = p
      bulk.end(String.take(r, n), String.drop(r, n))
    case None{}:
      None{}

# a bulk string, and what follows it
def bulk(s: String) -> Maybe<&1, String & String>:
  match s:
    case SCon{'$', +t}:
      bulk.body(num(t, 0n, ch(t)))
    case _:
      None{}

# the k more bulks of an entry after b, the one just read
def bulks(k: Nat, b: Maybe<&1, String & String>, acc: List<&2, String>) -> Maybe<&1, List<&2, String> & String>:
  match k b:
    case 0n Some{p}:
      (x, rest) = p
      Some{(List.reverse(&2, String, x <> acc), rest)}
    case 1n+m Some{p}:
      (x, rest) = p
      bulks(m, bulk(rest), x <> acc)
    case _ None{}:
      None{}

def entry.args(n: Nat, r: String) -> Maybe<&1, List<&2, String> & String>:
  match n:
    case 0n:
      Some{(Nil{}, r)}
    case 1n+m:
      bulks(m, bulk(r), Nil{})

def entry.head(m: Maybe<&1, Nat & String>) -> Maybe<&1, List<&2, String> & String>:
  match m:
    case Some{p}:
      (n, r) = p
      entry.args(n, r)
    case None{}:
      None{}

# an entry, and what follows it
def entry(s: String) -> Maybe<&1, List<&2, String> & String>:
  match s:
    case SCon{'*', +t}:
      entry.head(num(t, 0n, ch(t)))
    case _:
      None{}

# the entries of s, m the next one read, at most f of them; and what is
# left after the last whole one
def load.go(f: Nat, s: String, m: Maybe<&1, List<&2, String> & String>, acc: List<&2, List<&2, String>>) -> List<&2, List<&2, String>> & String:
  match f m:
    case 1n+g Some{p}:
      (x, +rest) = p
      load.go(g, rest, entry(rest), x <> acc)
    case _ _:
      (List.reverse(&2, List<&2, String>, acc), s)

# the entries of a file, and what is left after the last whole one (an
# entry cut short by a crash)
def load(+s: String) -> List<&2, List<&2, String>> & String:
  load.go(String.length(s), s, entry(s), Nil{})

# Restoring
# ---------

def db_after(r: List<&2, R.Reply> & KV.Trie<String>) -> KV.Trie<String>:
  (rs, db) = r
  db

# the database the entries leave, run from an empty one
def replay(reqs: List<&2, List<&2, String>>) -> KV.Trie<String>:
  db_after(R.exec_all(parse_all(reqs), KV.empty(String)))

def restore.of(l: List<&2, List<&2, String>> & String) -> KV.Trie<String> & String:
  (reqs, rest) = l
  (replay(reqs), rest)

# the database a file holds, and what is left after its last whole entry
def restore(s: String) -> KV.Trie<String> & String:
  restore.of(load(s))
