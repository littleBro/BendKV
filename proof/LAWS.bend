# LAWS.bend: what BendKV promises. A human states these; PROOF.bend
# must prove every one of them, and `bend proof/PROOF.bend` checks it.

import Base
import ../src/map.bend as KV
import ../src/redis.bend as R
import ../src/batch.bend as B
import ../src/aof.bend as A
import ../src/session.bend as S
import ../src/config.bend as C

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

# the keys a command may write: its named keys, or every key for FLUSHALL
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
    case _:
      False{}

# the commands that only read (a command of the connection or of the
# server, R.Own, never touches the database)
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
    case R.Peek{k, o}:
      True{}
    case R.Own{o}:
      True{}
    case R.Bad{r}:
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

# LAW: hints change nothing: the server runs each batch through
# batch.bend, which first starts loading the trie paths of its keys into
# the cache, and this law makes that exec_all, whatever the hashes
law batch_hints:
  for +cs: List<&2, R.Cmd>
  for +hs: List<&2, U32>
  for +db: KV.Trie<String>
  {B.exec_batch(cs, hs, db) == R.exec_all(cs, db) : List<&2, R.Reply> & KV.Trie<String>}

# a batch's replies, and the database after it
def replies(r: List<&2, R.Reply> & KV.Trie<String>) -> List<&2, R.Reply>:
  (rs, db) = r
  rs

def final(r: List<&2, R.Reply> & KV.Trie<String>) -> KV.Trie<String>:
  (rs, db) = r
  db

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
    case R.Peek{+k, o}:
      writes(c2, k)
    case R.DbSize{}:
      Bool.not(is_read(c2))
    case R.Keys{p}:
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
    case _:
      False{}

# whether two adjacent commands may not trade places: one disturbs the
# other, or they may write a key in common
def interferes(+c1: R.Cmd, +c2: R.Cmd) -> Bool:
  Bool.or(Bool.or(disturbs(c1, c2), disturbs(c2, c1)), clash(c2, c1))

# the commands whose replies depend only on what keys read: all but
# DBSIZE and KEYS, which see the trie itself
def keywise(c: R.Cmd) -> Bool:
  match c:
    case R.DbSize{}:
      False{}
    case R.Keys{p}:
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
# With an append-only file (server.bend: aof), the actor runs each batch
# with exec_log (aof.bend), which also gives what the batch did, as
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
  {A.log_batch(cs, hs, db) == A.exec_log(cs, db) : List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>)}

# LAW: a batch's effects, run on the database the batch ran on, leave the
# database the batch left
law log_replay:
  for +cs: List<&2, R.Cmd>
  for +db: KV.Trie<String>
  {final(R.exec_all(effects(A.exec_log(cs, db)), db)) == final(R.exec_all(cs, db)) : KV.Trie<String>}

# LAW: a batch's effects, written as entries, parse back to them
law log_args:
  for +cs: List<&2, R.Cmd>
  for +db: KV.Trie<String>
  {A.parse_all(A.args_all(effects(A.exec_log(cs, db)))) == effects(A.exec_log(cs, db)) : List<&2, R.Cmd>}

# LAW: a file loads as the entries written to it, with nothing left over
law aof_load:
  for +reqs: List<&2, List<&2, String>>
  {A.load(A.encode(reqs)) == (reqs, "") : List<&2, List<&2, String>> & String}

# a history, the batches the server has run since it started, newest
# first, run from an empty database
def single(hist: List<&2, List<&2, R.Cmd>>) -> KV.Trie<String>:
  match hist:
    case Nil{}:
      KV.empty(String)
    case Con{cs, older}:
      final(R.exec_all(cs, single(older)))

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

# Sessions
# ========
# A batch runs with the state of its connection and of the server
# (session.bend): the server runs it as S.run, or S.run_log with an
# append-only file, which take a batch of database commands only, from a
# client that may run them and gets every reply, the fast way (exec_batch,
# log_batch), and any other batch a command at a time (S.gen). The laws:
# the fast way is the general one; the general one changes the database
# exactly as exec_all runs the commands that ran (S.plan), and logs the
# effects exec_log gives them, so the laws of the commands and of
# persistence hold for the commands that ran; and a client that has not
# authenticated, to a server with a password, runs nothing but the
# errors the parser found, until it sends AUTH or HELLO.

# LAW: however the server takes a batch apart (B.unzip, B.job), it runs
# it as the general path runs its commands, in order
law run_gen:
  for  conn: S.Conn
  for  srv: S.Srv
  for +rs: List<&2, B.Req>
  for  db: KV.Trie<String>
  {S.run(conn, srv, B.job(B.unzip(rs, Nil{}, Nil{})), db) == S.done.gen(S.gen(conn, srv, B.cmds_of(rs, Nil{}), db)) : S.Fin}

# LAW: and so with an append-only file
law run_log_gen:
  for  conn: S.Conn
  for  srv: S.Srv
  for +rs: List<&2, B.Req>
  for  db: KV.Trie<String>
  {S.run_log(conn, srv, B.job(B.unzip(rs, Nil{}, Nil{})), db) == S.logged.gen(S.gen(conn, srv, B.cmds_of(rs, Nil{}), db)) : S.Logged}

def logged_es(l: S.Logged) -> List<&2, R.Cmd>:
  match l:
    case S.Logged{rs, es, conn, srv, db}:
      es

def logged_db(l: S.Logged) -> KV.Trie<String>:
  match l:
    case S.Logged{rs, es, conn, srv, db}:
      db

# LAW: a batch leaves the database exec_all leaves by the commands that
# ran in it
law gen_db:
  for +conn: S.Conn
  for +srv: S.Srv
  for +cmds: List<&2, R.Cmd>
  for +db: KV.Trie<String>
  {logged_db(S.logged.gen(S.gen(conn, srv, cmds, db))) == final(R.exec_all(S.plan(cmds, conn, srv), db)) : KV.Trie<String>}

# LAW: and logs the effects exec_log gives them: the append-only file
# holds the history of the commands that ran, as the Persistence laws
# have it
law gen_log:
  for +conn: S.Conn
  for +srv: S.Srv
  for +cmds: List<&2, R.Cmd>
  for +db: KV.Trie<String>
  {logged_es(S.logged.gen(S.gen(conn, srv, cmds, db))) == effects(A.exec_log(S.plan(cmds, conn, srv), db)) : List<&2, R.Cmd>}

# whether a command logs a client in: AUTH, or HELLO, which may carry an
# AUTH
def logs_in(c: R.Cmd) -> Bool:
  match c:
    case R.Own{R.SAuth{a}}:
      True{}
    case R.Own{R.SHello{a}}:
      True{}
    case _:
      False{}

def no_login(cs: List<&2, R.Cmd>) -> Bool:
  match cs:
    case Nil{}:
      True{}
    case Con{c, rest}:
      Bool.and(Bool.not(logs_in(c)), no_login(rest))

# whether every command is an error the parser found (R.Bad): exec
# answers it with the error, and it changes nothing
def all_bad(cs: List<&2, R.Cmd>) -> Bool:
  match cs:
    case Nil{}:
      True{}
    case Con{R.Bad{r}, rest}:
      all_bad(rest)
    case Con{c, rest}:
      False{}

# LAW: a client that has not authenticated, to a server with a password,
# runs nothing on the database but the errors the parser found, until it
# sends AUTH or HELLO: it can neither read nor change a key
law noauth:
  for  conn: S.Conn
  for +srv: S.Srv
  for  cmds: List<&2, R.Cmd>
  for  e1: {S.conn.auth(conn) == False{} : Bool}
  for  e2: {S.nopass(srv) == False{} : Bool}
  for  e3: {no_login(cmds) == True{} : Bool}
  {all_bad(S.plan(cmds, conn, srv)) == True{} : Bool}

# Configuration
# =============
# CONFIG GET and CONFIG SET (config.bend). A CONFIG SET that fails leaves
# the server as it was; one that succeeds leaves it with the new
# parameters, whose requirepass is the password; and after a CONFIG SET
# of a parameter that succeeds, the parameter holds the value its check
# gave, which CONFIG GET reads back by the same name.

# LAW: a CONFIG SET that fails leaves the server as it was (Redis sets the
# parameters before the failing one and puts them back; BendKV sets none)
law config_fail:
  for  args: List<&2, String>
  for  conn: S.Conn
  for +srv: S.Srv
  for  r: R.Reply
  for  e: {C.config.set(args, S.srv.cfg(srv)) == Fail{r} : Result<&2, &2, R.Reply, List<&2, C.CItem>>}
  {S.own_srv(R.SConfigSet{args}, conn, srv) == srv : S.Srv}

# LAW: one that succeeds leaves the server with the new parameters, and
# their requirepass is the password from then on (what INFO counts stays)
law config_pass:
  for  args: List<&2, String>
  for  conn: S.Conn
  for +srv: S.Srv
  for  cfg: List<&2, C.CItem>
  for  e: {C.config.set(args, S.srv.cfg(srv)) == Done{cfg} : Result<&2, &2, R.Reply, List<&2, C.CItem>>}
  {S.own_srv(R.SConfigSet{args}, conn, srv) == S.Srv{C.config.get_value(cfg, "requirepass"), cfg, S.srv.info(srv)} : S.Srv}

# a parameter with another value
def with(it: C.CItem, v: String) -> C.CItem:
  match it:
    case C.CItem{p, old}:
      C.CItem{p, v}

# LAW: after a CONFIG SET of one parameter that succeeds, the parameter
# holds the value its check gave (C.item.set), and a CONFIG GET of the
# same name finds it there
law config_set_get:
  for +n: String
  for +v: String
  for +items: List<&2, C.CItem>
  for +it: C.CItem
  for  nv: String
  for  items2: List<&2, C.CItem>
  for  e1: {C.item.find(items, String.to_lower(n)) == Some{it} : Maybe<&2, C.CItem>}
  for  e2: {C.item.set(it, v) == Done{nv} : Result<&2, &2, String, String>}
  for  e3: {C.config.set([n, v], items) == Done{items2} : Result<&2, &2, R.Reply, List<&2, C.CItem>>}
  {C.item.find(items2, String.to_lower(n)) == Some{with(it, nv)} : Maybe<&2, C.CItem>}
