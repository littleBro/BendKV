# LAWS.bend: what BendKV promises. A human states these; PROOF.bend
# must prove every one of them, and `bend PROOF.bend` checks it.

import Base
import ./map.bend as KV
import ./redis.bend as R
import ./batch.bend as B
import ./shard.bend as S
import ./resp.bend as P
import ./wire.bend as W
import ./aof.bend as A

# The map
# =======
# Five laws pin the map down completely: whatever sequence of sets and
# deletes built a map, a read of any key is determined by them (they are
# the axioms of the theory of finite maps), so no lookup can ever see a
# stale, lost or foreign value.

# LAW: the empty map holds no key
law get_empty:
  for -V: Data
  for +k: String
  {KV.get(V, KV.empty(V), k) == None{} : Maybe<&2, V>}

# LAW: a key reads back the value just set for it
law get_set_same:
  for -V: Data
  for +t: KV.Trie<V>
  for +k: String
  for +v: V
  {KV.get(V, KV.set(V, t, k, v), k) == Some{v} : Maybe<&2, V>}

# LAW: setting a key leaves every other key as it was
law get_set_other:
  for -V: Data
  for +t: KV.Trie<V>
  for +k: String
  for +j: String
  for +v: V
  for ne: {j != k : String}
  {KV.get(V, KV.set(V, t, k, v), j) == KV.get(V, t, j) : Maybe<&2, V>}

# LAW: a deleted key is gone
law get_del_same:
  for -V: Data
  for +t: KV.Trie<V>
  for +k: String
  {KV.get(V, KV.del(V, t, k), k) == None{} : Maybe<&2, V>}

# LAW: deleting a key leaves every other key as it was
law get_del_other:
  for -V: Data
  for +t: KV.Trie<V>
  for +k: String
  for +j: String
  for ne: {j != k : String}
  {KV.get(V, KV.del(V, t, k), j) == KV.get(V, t, j) : Maybe<&2, V>}

# Keys
# ====
# Key comparison is the one primitive the map trusts: these laws say it
# is exactly String equality, so predicates built on it mean what they say.

# LAW: keys that compare equal are equal
law key_eq_true:
  for +a: String
  for +b: String
  for e: {KV.str_eq(a, b) == True{} : Bool}
  {a == b : String}

# LAW: keys that compare unequal are different
law key_eq_false:
  for +a: String
  for +b: String
  for e: {KV.str_eq(a, b) == False{} : Bool}
  {a != b : String}

# The commands
# ============
# exec(cmd, db) is a command's reply and the database after it; the
# server runs exactly exec, one command after another.

# the keys a command may write: its named keys, every key for FLUSHALL,
# or for FlushAt every key under its digit
def any_key(+j: String, ks: List<&2, String>) -> Bool:
  match ks:
    case Nil{}:
      False{}
    case Con{k, rest}:
      Bool.or(KV.str_eq(j, k), any_key(j, rest))

def any_pair(+j: String, ps: List<&2, R.KVPair>) -> Bool:
  match ps:
    case Nil{}:
      False{}
    case Con{R.KP{k, v}, rest}:
      Bool.or(KV.str_eq(j, k), any_pair(j, rest))

def writes(c: R.Cmd, +j: String) -> Bool:
  match c:
    case R.Set{k, v}:
      KV.str_eq(j, k)
    case R.SetNX{k, v}:
      KV.str_eq(j, k)
    case R.GetSet{k, v}:
      KV.str_eq(j, k)
    case R.Del{ks}:
      any_key(j, ks)
    case R.IncrBy{k, by}:
      KV.str_eq(j, k)
    case R.Append{k, v}:
      KV.str_eq(j, k)
    case R.MSet{ps}:
      any_pair(j, ps)
    case R.FlushAll{}:
      True{}
    case R.FlushAt{x}:
      KV.hex_eq(KV.hex(KV.hash(j)), x)
    case _:
      False{}

# the commands that only read
def is_read(c: R.Cmd) -> Bool:
  match c:
    case R.Ping{}:
      True{}
    case R.Echo{m}:
      True{}
    case R.Get{k}:
      True{}
    case R.Exists{ks}:
      True{}
    case R.Strlen{k}:
      True{}
    case R.MGet{ks}:
      True{}
    case R.DbSize{}:
      True{}
    case R.Keys{p}:
      True{}
    case R.Bad{r}:
      True{}
    case R.SizeAt{x}:
      True{}
    case R.KeysAt{p, x}:
      True{}
    case _:
      False{}

# LAW: a command never changes a key it does not write (no command can
# corrupt an unrelated key)
law frame:
  for  c: R.Cmd
  for +db: KV.Trie<String>
  for +j: String
  for  e: {writes(c, j) == False{} : Bool}
  {KV.get(String, R.db_of(R.exec(c, db)), j) == KV.get(String, db, j) : Maybe<&2, String>}

# LAW: reads leave the whole database as it was
law reads_keep_db:
  for  c: R.Cmd
  for +db: KV.Trie<String>
  for  e: {is_read(c) == True{} : Bool}
  {R.db_of(R.exec(c, db)) == db : KV.Trie<String>}

# LAW: GET after SET answers the value set
law get_after_set:
  for +db: KV.Trie<String>
  for +k: String
  for +v: String
  {R.reply_of(R.exec(R.Get{k}, R.db_of(R.exec(R.Set{k, v}, db)))) == R.RBulk{v} : R.Reply}

# LAW: GET of a missing key answers nil
law get_missing:
  for +db: KV.Trie<String>
  for +k: String
  for  e: {KV.get(String, db, k) == None{} : Maybe<&2, String>}
  {R.exec(R.Get{k}, db) == (R.RNull{}, db) : R.Reply & KV.Trie<String>}

# LAW: DEL removes every key it names
law del_effect:
  for +ks: List<&2, String>
  for +db: KV.Trie<String>
  for +j: String
  for  e: {any_key(j, ks) == True{} : Bool}
  {KV.get(String, R.db_of(R.exec(R.Del{ks}, db)), j) == None{} : Maybe<&2, String>}

# LAW: DEL of one key answers 1 when it was there, 0 when it was not
law del_one_count:
  for +db: KV.Trie<String>
  for +k: String
  {R.reply_of(R.exec(R.Del{[k]}, db)) == R.r_int(Bool.pick(Nat, KV.has(String, db, k), 1n, 0n)) : R.Reply}

# the value APPEND extends: the old one, or nothing
def old_or_empty(m: Maybe<&2, String>) -> String:
  match m:
    case Some{s}:
      s
    case None{}:
      ""

# LAW: APPEND stores the old value followed by the new bytes, and
# answers the new length
law append_effect:
  for +db: KV.Trie<String>
  for +k: String
  for +s: String
  {R.exec(R.Append{k, s}, db) == (R.r_int(String.length(old_or_empty(KV.get(String, db, k)) ++ s)), KV.set(String, db, k, old_or_empty(KV.get(String, db, k)) ++ s)) : R.Reply & KV.Trie<String>}

# LAW: SETNX sets a missing key and answers 1
law setnx_missing:
  for +db: KV.Trie<String>
  for +k: String
  for +v: String
  for  e: {KV.get(String, db, k) == None{} : Maybe<&2, String>}
  {R.exec(R.SetNX{k, v}, db) == (R.r_int(1n), KV.set(String, db, k, v)) : R.Reply & KV.Trie<String>}

# LAW: SETNX leaves a present key alone and answers 0
law setnx_present:
  for +db: KV.Trie<String>
  for +k: String
  for +v: String
  for +x: String
  for  e: {KV.get(String, db, k) == Some{x} : Maybe<&2, String>}
  {R.exec(R.SetNX{k, v}, db) == (R.r_int(0n), db) : R.Reply & KV.Trie<String>}

# LAW: INCR of a missing key stores "1" and answers 1
law incr_missing:
  for +db: KV.Trie<String>
  for +k: String
  for  e: {KV.get(String, db, k) == None{} : Maybe<&2, String>}
  {R.exec(R.IncrBy{k, R.IPos{1n}}, db) == (R.RInt{R.IPos{1n}}, KV.set(String, db, k, "1")) : R.Reply & KV.Trie<String>}

# LAW: a batch runs as its commands one after another: the server runs
# pipelined requests through exec_all, and this law makes that the same
# as running them one by one
law batch_step:
  for +c: R.Cmd
  for +cs: List<&2, R.Cmd>
  for +db: KV.Trie<String>
  {R.exec_all(c <> cs, db) == R.exec_all.cons(R.reply_of(R.exec(c, db)), R.exec_all(cs, R.db_of(R.exec(c, db)))) : List<&2, R.Reply> & KV.Trie<String>}

# LAW: an empty batch answers nothing and changes nothing
law batch_nil:
  for +db: KV.Trie<String>
  {R.exec_all(Nil{}, db) == (Nil{}, db) : List<&2, R.Reply> & KV.Trie<String>}

# a hash fits a command when it is the hash of the key of a command on one
# key, which runs with it (R.exec.at); any hash fits the rest, which hash
# their keys themselves (batch.bend: fits, by the command's case)
def fits(c: R.Cmd, h: U32) -> Type:
  B.fits(c, h)

# each hash fits its command, in order
def all_fit(cs: List<&2, R.Cmd>, hs: List<&2, U32>) -> Type:
  match cs hs:
    case Con{c, crest} Con{h, hrest}:
      fits(c, h) & all_fit(crest, hrest)
    case _ _:
      Unit

# the commands and hashes of a pair fit
def pair_fit(p: List<&2, R.Cmd> & List<&2, U32>) -> Type:
  (cs, hs) = p
  all_fit(cs, hs)

# LAW: a command run with a hash that fits it (R.exec.at), as the server
# runs it, its key hashed once, is the command run alone
law exec_at:
  for  c: R.Cmd
  for +h: U32
  for +db: KV.Trie<String>
  for  e: fits(c, h)
  {R.exec.at(c, h, db) == R.exec(c, db) : R.Reply & KV.Trie<String>}

# LAW: hints change nothing: the server runs each batch through
# batch.bend, which first starts loading the trie paths of its keys into
# the cache and then runs the batch with the hashes of its keys, and this
# law makes that exec_all, whatever hashes fit
law batch_hints:
  for +cs: List<&2, R.Cmd>
  for +hs: List<&2, U32>
  for +db: KV.Trie<String>
  for  e: all_fit(cs, hs)
  {B.exec_batch(cs, hs, db) == R.exec_all(cs, db) : List<&2, R.Reply> & KV.Trie<String>}

# LAW: and the hashes the connection parses its requests with fit their
# commands: resp.bend parses each request into a B.Fit, which holds the
# command, its hash and why the hash fits it (erased from the server), so
# the type checker checks every place the parser picks a hash; the server
# takes a batch's commands and hashes apart, in order, with B.fit_unzip
law fit_hashes:
  for +fs: List<&2, B.Fit>
  pair_fit(B.fit_unzip(fs, Nil{}, Nil{}))

# Shards
# ======
# With n shards (server.bend), the database is n tries, each owned by an
# actor on a core of its own; a connection cuts each batch among them
# (shard.bend: split), hands each its part, and puts their replies back
# in order (merge). A command on several keys goes in pieces, one command
# of one key for each of its keys, each to its key's shard; DBSIZE, KEYS
# and FLUSHALL go in pieces too, one for each digit of the trie's root,
# each to the shard that holds the subtrie under that digit. These laws
# see the shards as one list: shard s's trie is at(ts, s), an empty one
# past the end, and key k lives in shard shard(n, k). A history is the
# batches the server has run since it started, newest first; the single
# server runs it on one database, the sharded one on its shards. The laws
# say that, after any history, the sharded server answers the next batch
# as the single one does, and every key reads in its shard as it reads in
# the single database, whatever commands the history and the batch hold.

def at(ts: List<&2, KV.Trie<String>>, s: Nat) -> KV.Trie<String>:
  match ts s:
    case Con{t, rest} 0n:
      t
    case Con{t, rest} 1n+p:
      at(rest, p)
    case Nil{} _:
      KV.empty(String)

def shard(+n: U32, +k: String) -> Nat:
  S.shard_of(n, KV.hash(k))

def replies(r: List<&2, R.Reply> & KV.Trie<String>) -> List<&2, R.Reply>:
  (rs, db) = r
  rs

def final(r: List<&2, R.Reply> & KV.Trie<String>) -> KV.Trie<String>:
  (rs, db) = r
  db

# the commands a shard's actor runs for its part
def part_cmds(p: List<&2, S.Part>) -> List<&2, R.Cmd>:
  match p:
    case Nil{}:
      Nil{}
    case Con{S.Part{c, h}, rest}:
      c <> part_cmds(rest)

# each shard's replies to its part (none from a shard without one)
def answers(ps: List<&2, List<&2, S.Part>>, ts: List<&2, KV.Trie<String>>) -> S.Store():
  match ps ts:
    case Nil{} Nil{}:
      Nil{}
    case Nil{} Con{t, trest}:
      Nil{} <> answers(Nil{}, trest)
    case Con{p, prest} Nil{}:
      replies(R.exec_all(part_cmds(p), KV.empty(String))) <> answers(prest, Nil{})
    case Con{p, prest} Con{t, trest}:
      replies(R.exec_all(part_cmds(p), t)) <> answers(prest, trest)

# each shard's trie after its part
def after(ps: List<&2, List<&2, S.Part>>, ts: List<&2, KV.Trie<String>>) -> List<&2, KV.Trie<String>>:
  match ps ts:
    case Nil{} other:
      other
    case Con{p, prest} Nil{}:
      final(R.exec_all(part_cmds(p), KV.empty(String))) <> after(prest, Nil{})
    case Con{p, prest} Con{t, trest}:
      final(R.exec_all(part_cmds(p), t)) <> after(prest, trest)

def sharded.go(ts: List<&2, KV.Trie<String>>, x: List<&2, S.Route> & List<&2, List<&2, S.Part>>) -> List<&2, R.Reply> & List<&2, KV.Trie<String>>:
  (routes, ps) = x
  +p = ps
  +t = ts
  (S.merge(routes, answers(p, t)), after(p, t))

# a batch as the server with n shards runs it on the shards ts: its
# replies, and the shards after it
def sharded(+n: U32, cs: List<&2, R.Cmd>, ts: List<&2, KV.Trie<String>>) -> List<&2, R.Reply> & List<&2, KV.Trie<String>>:
  sharded.go(ts, S.split(n, cs))

def sh_replies(r: List<&2, R.Reply> & List<&2, KV.Trie<String>>) -> List<&2, R.Reply>:
  (rs, ts) = r
  rs

def sh_tries(r: List<&2, R.Reply> & List<&2, KV.Trie<String>>) -> List<&2, KV.Trie<String>>:
  (rs, ts) = r
  ts

# a history, newest batch first, run from an empty database: by the single
# server, and by the server with n shards
def single(hist: List<&2, List<&2, R.Cmd>>) -> KV.Trie<String>:
  match hist:
    case Nil{}:
      KV.empty(String)
    case Con{cs, older}:
      final(R.exec_all(cs, single(older)))

def shards(+n: U32, hist: List<&2, List<&2, R.Cmd>>) -> List<&2, KV.Trie<String>>:
  match hist:
    case Nil{}:
      Nil{}
    case Con{cs, older}:
      sh_tries(sharded(n, cs, shards(n, older)))

# LAW: after any history, the sharded server answers a batch as the single
# server does
law shard_replies:
  for +n: U32
  for +hist: List<&2, List<&2, R.Cmd>>
  for +cs: List<&2, R.Cmd>
  {sh_replies(sharded(n, cs, shards(n, hist))) == replies(R.exec_all(cs, single(hist))) : List<&2, R.Reply>}

# the s-th of the parts a batch is cut into (none past the last)
def part_at(ps: List<&2, List<&2, S.Part>>, s: Nat) -> List<&2, S.Part>:
  match ps s:
    case Con{p, rest} 0n:
      p
    case Con{p, rest} 1n+t:
      part_at(rest, t)
    case Nil{} _:
      Nil{}

def sh_parts(r: List<&2, S.Route> & List<&2, List<&2, S.Part>>) -> List<&2, List<&2, S.Part>>:
  (routes, ps) = r
  ps

# the hashes a part carries
def part_hashes(p: List<&2, S.Part>) -> List<&2, U32>:
  match p:
    case Nil{}:
      Nil{}
    case Con{S.Part{c, h}, rest}:
      h <> part_hashes(rest)

# LAW: a shard's part comes with hashes that fit its commands: those of
# their keys, which split computed to pick their shards; the shard runs
# its part with them (batch_hints)
law shard_hashes:
  for +n: U32
  for +cs: List<&2, R.Cmd>
  for +s: Nat
  all_fit(part_cmds(part_at(sh_parts(S.split(n, cs)), s)), part_hashes(part_at(sh_parts(S.split(n, cs)), s)))

# LAW: a part unzips into its commands and their hashes, as the server
# hands it to its shard (server.bend: part_req)
law unzip_parts:
  for  p: List<&2, S.Part>
  {S.unzip(p) == (part_cmds(p), part_hashes(p)) : List<&2, R.Cmd> & List<&2, U32>}

# LAW: and every key reads in its shard as it reads in the single database
law shard_holds:
  for +n: U32
  for +hist: List<&2, List<&2, R.Cmd>>
  for +k: String
  {KV.get(String, at(shards(n, hist), shard(n, k)), k) == KV.get(String, single(hist), k) : Maybe<&2, String>}

# Bytes
# =====
# With several shards, a connection merges the shards' answers in bytes
# (wire.bend): each shard encodes its replies itself, and the merge works
# on the bytes. These laws say that the merge in bytes gives shard.bend's
# replies, each encoded; that replies encoded one by one and glued are the
# replies encoded at once, as the single server sends them; and so that,
# after any history, the sharded server sends for a batch the very bytes
# the single server sends.

# LAW: the merge in bytes is the merge of replies, each reply encoded
law merge_bytes:
  for +routes: List<&2, S.Route>
  for +st: S.Store()
  {W.merge(routes, W.store_of(st)) == W.encodes(S.merge(routes, st)) : List<&2, String>}

# LAW: replies encoded one by one and glued are the replies encoded at once
law encodes_glue:
  for +rs: List<&2, R.Reply>
  {String.concat(W.encodes(rs)) == P.encode_all(rs) : String}

def sh_bytes.go(ts: List<&2, KV.Trie<String>>, x: List<&2, S.Route> & List<&2, List<&2, S.Part>>) -> List<&2, String>:
  (routes, ps) = x
  W.merge(routes, W.store_of(answers(ps, ts)))

# a batch as the server with n shards answers it on the shards ts, in
# bytes: a String for each command, glued into one buffer as they go out
def sh_bytes(+n: U32, cs: List<&2, R.Cmd>, ts: List<&2, KV.Trie<String>>) -> List<&2, String>:
  sh_bytes.go(ts, S.split(n, cs))

# LAW: after any history, the sharded server sends for a batch the bytes
# the single server sends
law shard_bytes:
  for +n: U32
  for +hist: List<&2, List<&2, R.Cmd>>
  for +cs: List<&2, R.Cmd>
  {String.concat(sh_bytes(n, cs, shards(n, hist))) == P.encode_all(replies(R.exec_all(cs, single(hist)))) : String}

# Commuting commands
# ==================
# Commands on different keys may run in either order: each answers the
# same, and every key reads the same after both. A command changes a key
# only as that key read before it (no command moves a value from one key
# to another), so for the database it is enough that no key is written by
# both; for a reply, that the other command writes no key it reads. These
# laws speak of what keys read, not of the trie: two new keys of one
# bucket sit in the order they were set, so KEYS may list them in either
# order, as Redis's KEYS promises no order.

# whether c writes a key of ks
def writes_any(+c: R.Cmd, ks: List<&2, String>) -> Bool:
  match ks:
    case Nil{}:
      False{}
    case Con{+k, rest}:
      Bool.or(writes(c, k), writes_any(c, rest))

# whether c2, run first, may change what c1 answers: c2 writes a key c1
# reads, or c1 reads the whole database (DBSIZE, KEYS) and c2 writes at all
def disturbs(+c2: R.Cmd, c1: R.Cmd) -> Bool:
  match c1:
    case R.Get{+k}:
      writes(c2, k)
    case R.Strlen{+k}:
      writes(c2, k)
    case R.SetNX{+k, v}:
      writes(c2, k)
    case R.GetSet{+k, v}:
      writes(c2, k)
    case R.IncrBy{+k, by}:
      writes(c2, k)
    case R.Append{+k, v}:
      writes(c2, k)
    case R.Del{ks}:
      writes_any(c2, ks)
    case R.Exists{ks}:
      writes_any(c2, ks)
    case R.MGet{ks}:
      writes_any(c2, ks)
    case R.DbSize{}:
      Bool.not(is_read(c2))
    case R.Keys{p}:
      Bool.not(is_read(c2))
    case R.SizeAt{x}:
      Bool.not(is_read(c2))
    case R.KeysAt{p, x}:
      Bool.not(is_read(c2))
    case _:
      False{}

# LAW: a command answers the same after another one that does not
# disturb it
law commute_reply:
  for  c1: R.Cmd
  for +c2: R.Cmd
  for +db: KV.Trie<String>
  for  e: {disturbs(c2, c1) == False{} : Bool}
  {R.reply_of(R.exec(c1, R.db_of(R.exec(c2, db)))) == R.reply_of(R.exec(c1, db)) : R.Reply}

# LAW: run in either order, two commands leave a key that at most one of
# them writes reading the same
law commute_reads:
  for +c1: R.Cmd
  for +c2: R.Cmd
  for +db: KV.Trie<String>
  for +j: String
  for  e: {Bool.and(writes(c1, j), writes(c2, j)) == False{} : Bool}
  {KV.get(String, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))), j) == KV.get(String, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))), j) : Maybe<&2, String>}

# LAW: two commands that do not disturb each other answer the same in
# either order
law commute:
  for +c1: R.Cmd
  for +c2: R.Cmd
  for +db: KV.Trie<String>
  for  e: {Bool.or(disturbs(c1, c2), disturbs(c2, c1)) == False{} : Bool}
  {replies(R.exec_all([c2, c1], db)) == List.reverse(&2, R.Reply, replies(R.exec_all([c1, c2], db))) : List<&2, R.Reply>}

# A swap inside a batch
# ---------------------
# Two adjacent commands of a batch may trade places when neither disturbs
# the other and they write no key in common: the rest of the batch then
# runs on a database that reads the same at every key, so it answers the
# same, unless it holds DBSIZE or KEYS, which see the trie itself.

def writes_pairs(+c: R.Cmd, ps: List<&2, R.KVPair>) -> Bool:
  match ps:
    case Nil{}:
      False{}
    case Con{R.KP{+k, v}, rest}:
      Bool.or(writes(c, k), writes_pairs(c, rest))

# whether c2 may write a key c1 writes
def clash(+c2: R.Cmd, c1: R.Cmd) -> Bool:
  match c1:
    case R.Set{+k, v}:
      writes(c2, k)
    case R.SetNX{+k, v}:
      writes(c2, k)
    case R.GetSet{+k, v}:
      writes(c2, k)
    case R.IncrBy{+k, by}:
      writes(c2, k)
    case R.Append{+k, v}:
      writes(c2, k)
    case R.Del{ks}:
      writes_any(c2, ks)
    case R.MSet{ps}:
      writes_pairs(c2, ps)
    case R.FlushAll{}:
      Bool.not(is_read(c2))
    case R.FlushAt{x}:
      Bool.not(is_read(c2))
    case _:
      False{}

# whether two adjacent commands may not trade places: one disturbs the
# other, or they may write a key in common
def interferes(+c1: R.Cmd, +c2: R.Cmd) -> Bool:
  Bool.or(Bool.or(disturbs(c1, c2), disturbs(c2, c1)), clash(c2, c1))

# the commands whose replies depend only on what keys read: all but
# DBSIZE and KEYS (and SizeAt and KeysAt), which see the trie itself
def keywise(c: R.Cmd) -> Bool:
  match c:
    case R.DbSize{}:
      False{}
    case R.Keys{p}:
      False{}
    case R.SizeAt{x}:
      False{}
    case R.KeysAt{p, x}:
      False{}
    case _:
      True{}

def keywise_all(cs: List<&2, R.Cmd>) -> Bool:
  match cs:
    case Nil{}:
      True{}
    case Con{c, rest}:
      Bool.and(keywise(c), keywise_all(rest))

# replies with the first two swapped
def swap2(rs: List<&2, R.Reply>) -> List<&2, R.Reply>:
  match rs:
    case Con{a, Con{b, rest}}:
      Con{b, Con{a, rest}}
    case other:
      other

# LAW: two commands that do not interfere may trade places at the head of
# a batch: their replies trade places, and the rest of the batch answers
# the same when it holds no DBSIZE or KEYS
law swap_replies:
  for +c1: R.Cmd
  for +c2: R.Cmd
  for +cs: List<&2, R.Cmd>
  for +db: KV.Trie<String>
  for  e1: {interferes(c1, c2) == False{} : Bool}
  for  e2: {keywise_all(cs) == True{} : Bool}
  {replies(R.exec_all(Con{c2, Con{c1, cs}}, db)) == swap2(replies(R.exec_all(Con{c1, Con{c2, cs}}, db))) : List<&2, R.Reply>}

# LAW: and after the whole batch, whatever it holds, every key reads the
# same
law swap_reads:
  for +c1: R.Cmd
  for +c2: R.Cmd
  for +cs: List<&2, R.Cmd>
  for +db: KV.Trie<String>
  for +j: String
  for  e: {clash(c2, c1) == False{} : Bool}
  {KV.get(String, final(R.exec_all(Con{c2, Con{c1, cs}}, db)), j) == KV.get(String, final(R.exec_all(Con{c1, Con{c2, cs}}, db)), j) : Maybe<&2, String>}

# Persistence
# ===========
# With an append-only file (server.bend: aof), a shard's actor runs each
# batch with exec_log (aof.bend), which also gives what the batch did, as
# commands (its effects), and appends their entries to the file before it
# answers. At start the server loads the file and runs its entries from
# an empty database (restore). The laws: exec_log answers as exec_all; a
# batch's effects, run on the database the batch ran on, leave the
# database the batch left; a client's effects, written as entries, parse
# back to themselves; a file loads as the entries written to it; and so,
# after any history, the server restores from its file the database it
# held. A file cut anywhere by a crash restores the database the server
# held after some prefix of its commands, and the loader leaves exactly
# the part of an entry the cut left. The actor runs each batch after the
# hints of batch.bend (log_batch), which change nothing.

# a batch run with its effects, without them; and the effects
def log_out(r: List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>)) -> List<&2, R.Reply> & KV.Trie<String>:
  (rs, q) = r
  (rs, Pair.snd(List<&2, R.Cmd>, KV.Trie<String>, q))

def effects(r: List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>)) -> List<&2, R.Cmd>:
  (rs, q) = r
  Pair.fst(List<&2, R.Cmd>, KV.Trie<String>, q)

# LAW: exec_log answers and leaves the database as exec_all does
law log_exec:
  for +cs: List<&2, R.Cmd>
  for +db: KV.Trie<String>
  {log_out(A.exec_log(cs, db)) == R.exec_all(cs, db) : List<&2, R.Reply> & KV.Trie<String>}

# LAW: hints change nothing here either: the actor runs each batch with
# log_batch, which first starts loading the trie paths of its keys into
# the cache, as exec_batch does, and this law makes that exec_log
law log_hints:
  for +cs: List<&2, R.Cmd>
  for +hs: List<&2, U32>
  for +db: KV.Trie<String>
  for  e: all_fit(cs, hs)
  {A.log_batch(cs, hs, db) == A.exec_log(cs, db) : List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>)}

# LAW: a batch's effects, run on the database the batch ran on, leave the
# database the batch left
law log_replay:
  for +cs: List<&2, R.Cmd>
  for +db: KV.Trie<String>
  {final(R.exec_all(effects(A.exec_log(cs, db)), db)) == final(R.exec_all(cs, db)) : KV.Trie<String>}

# LAW: a batch's effects, written as entries, parse back to them: any
# batch, a shard's part too, whose FlushAt pieces log as FLUSHAT entries
law log_args:
  for +cs: List<&2, R.Cmd>
  for +db: KV.Trie<String>
  {A.parse_all(A.args_all(effects(A.exec_log(cs, db)))) == effects(A.exec_log(cs, db)) : List<&2, R.Cmd>}

# LAW: a file loads as the entries written to it, with nothing left over
law aof_load:
  for +reqs: List<&2, List<&2, String>>
  {A.load(A.encode(reqs)) == (reqs, "") : List<&2, List<&2, String>> & String}

# the file after a history, newest batch first: the entries of each
# batch's effects, appended after those of the batches before it
def aof(hist: List<&2, List<&2, R.Cmd>>) -> String:
  match hist:
    case Nil{}:
      ""
    case Con{cs, +older}:
      aof(older) ++ A.encode(A.args_all(effects(A.exec_log(cs, single(older)))))

# LAW: after any history, the server restores from its file the database
# it held, and nothing is left over
law recover:
  for +hist: List<&2, List<&2, R.Cmd>>
  {A.restore(aof(hist)) == (single(hist), "") : KV.Trie<String> & String}

# A crash in the middle of a write leaves the file cut anywhere: c is
# what reached the disk, d what did not. The server loads what it can
# (whole entries) and cuts the rest off (server.bend: restore).

# the commands of a history, oldest first
def commands(hist: List<&2, List<&2, R.Cmd>>) -> List<&2, R.Cmd>:
  match hist:
    case Nil{}:
      Nil{}
    case Con{cs, older}:
      List.append(&2, R.Cmd, commands(older), cs)

# the database after the first j commands of a history
def held(hist: List<&2, List<&2, R.Cmd>>, j: Nat) -> KV.Trie<String>:
  final(R.exec_all(List.take(&2, R.Cmd, commands(hist), j), KV.empty(String)))

# LAW: a file cut anywhere restores the database the server held after
# some prefix of its commands: no command is applied in part, none is
# applied out of order, and none after one that is lost
law recover_cut:
  for +hist: List<&2, List<&2, R.Cmd>>
  for +c: String
  for -d: String
  for  e: {c ++ d == aof(hist) : String}
  Exists(Nat, j => {Pair.fst(KV.Trie<String>, String, A.restore(c)) == held(hist, j) : KV.Trie<String>})

# LAW: and what the loader reads, written again, followed by what it
# leaves, is the cut file: cutting the leftover off leaves whole entries
law load_cut:
  for +hist: List<&2, List<&2, R.Cmd>>
  for +c: String
  for -d: String
  for  e: {c ++ d == aof(hist) : String}
  {A.encode(Pair.fst(List<&2, List<&2, String>>, String, A.load(c))) ++ Pair.snd(List<&2, List<&2, String>>, String, A.load(c)) == c : String}

# Persistence on shards
# =====================
# With n shards and a file, each shard's actor logs its part of each
# batch to a file of its own (server.bend), as the lone actor logs whole
# batches, and at start each shard restores its own file. A shard's
# history is its part of each batch of the server's history; a part may
# hold FlushAt pieces, which log as FLUSHAT entries (log_args holds for
# every batch). Each file is replayed on its own, so after a crash each
# shard keeps a prefix of its own commands: a command in pieces on several
# shards (MSET, DEL of several keys, FLUSHALL) may keep its pieces on some
# shards and lose them on others.

# the batches shard s of n runs in a history: its part of each batch,
# newest first (none for a batch it has no part of)
def shard_hist(+n: U32, +s: Nat, hist: List<&2, List<&2, R.Cmd>>) -> List<&2, List<&2, R.Cmd>>:
  match hist:
    case Nil{}:
      Nil{}
    case Con{cs, older}:
      part_cmds(part_at(sh_parts(S.split(n, cs)), s)) <> shard_hist(n, s, older)

# LAW: after any history, each shard restores from its file the database
# it held, and nothing is left over
law shard_recover:
  for +n: U32
  for +s: Nat
  for +hist: List<&2, List<&2, R.Cmd>>
  {A.restore(aof(shard_hist(n, s, hist))) == (at(shards(n, hist), s), "") : KV.Trie<String> & String}

# LAW: so every key reads, in the database its shard restores, as it reads
# in the single database
law shard_restore:
  for +n: U32
  for +hist: List<&2, List<&2, R.Cmd>>
  for +k: String
  {KV.get(String, Pair.fst(KV.Trie<String>, String, A.restore(aof(shard_hist(n, shard(n, k), hist)))), k) == KV.get(String, single(hist), k) : Maybe<&2, String>}

# LAW: a shard's file cut anywhere restores the database the shard held
# after some prefix of its own commands
law shard_recover_cut:
  for +n: U32
  for +s: Nat
  for +hist: List<&2, List<&2, R.Cmd>>
  for +c: String
  for -d: String
  for  e: {c ++ d == aof(shard_hist(n, s, hist)) : String}
  Exists(Nat, j => {Pair.fst(KV.Trie<String>, String, A.restore(c)) == held(shard_hist(n, s, hist), j) : KV.Trie<String>})
