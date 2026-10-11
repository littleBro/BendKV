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
# What a key holds is its entry: its value and the time it expires at (0:
# never), or none (KV.entry). Nine laws pin the map down completely:
# whatever sequence of writes built a map, the entry of any key is
# determined by them (the axioms of the theory of finite maps, for each of
# the four writes: set a value and a time, set a value and keep the time,
# set the time alone, delete), so no lookup can ever see a stale, lost or
# foreign entry. The map keeps a time as it is given (the commands give
# a key only times below 10^14 ms, KV.clamp). The reads are the entry
# seen through: get its value, read its value when the key is there at
# now (it has not expired), code.at its code.

# an entry's value
def item_val(-V: Data, m: Maybe<&2, KV.Item<V>>) -> Maybe<&2, V>:
  match m:
    case Some{KV.Item{v, e}}:
      Some{v}
    case None{}:
      None{}

# an entry's value when the key is there at now
def live_val(-V: Data, m: Maybe<&2, KV.Item<V>>, +now: Nat) -> Maybe<&2, V>:
  match m:
    case Some{KV.Item{v, +e}}:
      KV.blive.ent(V, KV.live(now, e), v)
    case None{}:
      None{}

# an entry's code: 0 for none, else 1 plus its time
def item_code(-V: Data, m: Maybe<&2, KV.Item<V>>) -> Nat:
  match m:
    case Some{KV.Item{v, e}}:
      1n+e
    case None{}:
      0n

# the time a key keeps when its value is set and its time kept: the time
# it had, or none for a new key
def keep_exp(-V: Data, m: Maybe<&2, KV.Item<V>>) -> Nat:
  match m:
    case Some{KV.Item{v, e}}:
      e
    case None{}:
      0n

# an entry with its time set to e, and no entry still none
def with_exp(-V: Data, m: Maybe<&2, KV.Item<V>>, e: Nat) -> Maybe<&2, KV.Item<V>>:
  match m:
    case Some{KV.Item{v, x}}:
      Some{KV.Item{v, e}}
    case None{}:
      None{}

# LAW: the empty map holds no key
law entry_empty:
  for -V: Data
  for +k: String
  {KV.entry(V, KV.empty(V), k) == None{} : Maybe<&2, KV.Item<V>>}

# LAW: a key holds the value and the time just set for it
law entry_setx_same:
  for -V: Data
  for +t: KV.Trie<V>
  for +k: String
  for +v: V
  for +e: Nat
  {KV.entry(V, KV.setx(V, t, k, v, e), k) == Some{KV.Item{v, e}} : Maybe<&2, KV.Item<V>>}

# LAW: setting a key leaves every other key as it was
law entry_setx_other:
  for -V: Data
  for +t: KV.Trie<V>
  for +k: String
  for +j: String
  for +v: V
  for +e: Nat
  for ne: {j != k : String}
  {KV.entry(V, KV.setx(V, t, k, v, e), j) == KV.entry(V, t, j) : Maybe<&2, KV.Item<V>>}

# LAW: a key set with its time kept holds the value and the time it had
law entry_keep_same:
  for -V: Data
  for +t: KV.Trie<V>
  for +k: String
  for +v: V
  {KV.entry(V, KV.keep(V, t, k, v), k) == Some{KV.Item{v, keep_exp(V, KV.entry(V, t, k))}} : Maybe<&2, KV.Item<V>>}

law entry_keep_other:
  for -V: Data
  for +t: KV.Trie<V>
  for +k: String
  for +j: String
  for +v: V
  for ne: {j != k : String}
  {KV.entry(V, KV.keep(V, t, k, v), j) == KV.entry(V, t, j) : Maybe<&2, KV.Item<V>>}

# LAW: a key's time set alone: the key keeps its value, and a key that is
# not held stays so
law entry_expire_same:
  for -V: Data
  for +t: KV.Trie<V>
  for +k: String
  for +e: Nat
  {KV.entry(V, KV.expire(V, t, k, e), k) == with_exp(V, KV.entry(V, t, k), e) : Maybe<&2, KV.Item<V>>}

law entry_expire_other:
  for -V: Data
  for +t: KV.Trie<V>
  for +k: String
  for +j: String
  for +e: Nat
  for ne: {j != k : String}
  {KV.entry(V, KV.expire(V, t, k, e), j) == KV.entry(V, t, j) : Maybe<&2, KV.Item<V>>}

# LAW: a deleted key is gone
law entry_del_same:
  for -V: Data
  for +t: KV.Trie<V>
  for +k: String
  {KV.entry(V, KV.del(V, t, k), k) == None{} : Maybe<&2, KV.Item<V>>}

# LAW: deleting a key leaves every other key as it was
law entry_del_other:
  for -V: Data
  for +t: KV.Trie<V>
  for +k: String
  for +j: String
  for ne: {j != k : String}
  {KV.entry(V, KV.del(V, t, k), j) == KV.entry(V, t, j) : Maybe<&2, KV.Item<V>>}

# LAW: get reads an entry's value, there at now or not
law get_entry:
  for -V: Data
  for +t: KV.Trie<V>
  for +k: String
  {KV.get(V, t, k) == item_val(V, KV.entry(V, t, k)) : Maybe<&2, V>}

# LAW: read reads an entry's value when the key is there at now
law read_entry:
  for -V: Data
  for +t: KV.Trie<V>
  for +k: String
  for +now: Nat
  {KV.read(V, t, k, now) == live_val(V, KV.entry(V, t, k), now) : Maybe<&2, V>}

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
# server runs exactly exec, one command after another, those of a group
# of batches at the time the group came (the database's now). A key whose
# time has passed is not there for any command, but its entry stays until
# a write puts the key anew or deletes it.

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
    case R.Del{ks}:
      any_key(j, ks)
    case R.IncrBy{k, by}:
      KV.str_eq(j, k)
    case R.MSet{ps}:
      any_pair(j, ps)
    case R.FlushAll{}:
      True{}
    case R.Upd{k, op}:
      KV.str_eq(j, k)
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
    case R.MGet{ks}:
      True{}
    case R.DbSize{}:
      True{}
    case R.Keys{p}:
      True{}
    case R.Scan{a}:
      True{}
    case R.Peek{k, o}:
      True{}
    case R.Own{o}:
      True{}
    case R.Bad{r}:
      True{}
    case _:
      False{}

# LAW: a command never changes a key it does not write, neither its value
# nor its time (no command can corrupt an unrelated key)
law frame:
  for  c: R.Cmd
  for +db: R.Db
  for +j: String
  for  e: {writes(c, j) == False{} : Bool}
  {KV.entry(String, R.db.t(R.db_of(R.exec(c, db))), j) == KV.entry(String, R.db.t(db), j) : Maybe<&2, KV.Item<String>>}

# LAW: reads leave the whole database as it was
law reads_keep_db:
  for  c: R.Cmd
  for +db: R.Db
  for  e: {is_read(c) == True{} : Bool}
  {R.db_of(R.exec(c, db)) == db : R.Db}

# LAW: GET after SET answers the value set
law get_after_set:
  for +db: R.Db
  for +k: String
  for +v: String
  {R.reply_of(R.exec(R.Get{k}, R.db_of(R.exec(R.Set{k, v}, db)))) == R.RBulk{v} : R.Reply}

# k's entry in a database, when the key is there at the database's now
def there(+db: R.Db, +k: String) -> Maybe<&2, KV.Item<String>>:
  R.ent.live(R.db.now(db), KV.entry(String, R.db.t(db), k))

# LAW: a key whose time has passed is not there (so GET answers nil, DEL
# does not count it, SETNX sets it anew)
law expired:
  for +db: R.Db
  for +k: String
  for +v: String
  for +e: Nat
  for  h: {KV.entry(String, R.db.t(db), k) == Some{KV.Item{v, 1n+e}} : Maybe<&2, KV.Item<String>>}
  for  p: {Nat.is_lt(1n+e, R.db.now(db)) == True{} : Bool}
  {there(db, k) == None{} : Maybe<&2, KV.Item<String>>}

# LAW: GET of a key that is not there (never set, deleted, or expired)
# answers nil and changes nothing
law get_missing:
  for +db: R.Db
  for +k: String
  for  e: {there(db, k) == None{} : Maybe<&2, KV.Item<String>>}
  {R.exec(R.Get{k}, db) == (R.RNull{}, db) : R.Reply & R.Db}

# LAW: DEL removes every key it names, expired or not
law del_effect:
  for +ks: List<&2, String>
  for +db: R.Db
  for +j: String
  for  e: {any_key(j, ks) == True{} : Bool}
  {KV.entry(String, R.db.t(R.db_of(R.exec(R.Del{ks}, db))), j) == None{} : Maybe<&2, KV.Item<String>>}

# LAW: DEL of one key answers 1 when it was there, 0 when it was not
law del_one_count:
  for +db: R.Db
  for +k: String
  {R.reply_of(R.exec(R.Del{[k]}, db)) == R.r_int(Bool.pick(Nat, Maybe.is_some(&2, KV.Item<String>, there(db, k)), 1n, 0n)) : R.Reply}

# what a command answers, and what its key k holds after it
def at_key(r: R.Reply & R.Db, +k: String) -> R.Reply & Maybe<&2, KV.Item<String>>:
  (x, db) = r
  (x, KV.entry(String, R.db.t(db), k))

# the value a key there holds, and its time: nothing and none for a key
# that is not there
def old_val(m: Maybe<&2, KV.Item<String>>) -> String:
  match m:
    case Some{KV.Item{v, e}}:
      v
    case None{}:
      ""

def old_exp(m: Maybe<&2, KV.Item<String>>) -> Nat:
  match m:
    case Some{KV.Item{v, e}}:
      e
    case None{}:
      0n

# LAW: APPEND stores the value the key held followed by the new bytes,
# keeping the key's time, and answers the new length
law append_effect:
  for +db: R.Db
  for +k: String
  for +s: String
  {at_key(R.exec(R.Upd{k, R.UAppend{s}}, db), k) == (R.r_int(String.length(old_val(there(db, k)) ++ s)), Some{KV.Item{old_val(there(db, k)) ++ s, old_exp(there(db, k))}}) : R.Reply & Maybe<&2, KV.Item<String>>}

# LAW: SETNX sets a key that is not there, with no time, and answers 1
law setnx_missing:
  for +db: R.Db
  for +k: String
  for +v: String
  for  e: {there(db, k) == None{} : Maybe<&2, KV.Item<String>>}
  {at_key(R.exec(R.Upd{k, R.USetNx{v}}, db), k) == (R.r_int(1n), Some{KV.Item{v, 0n}}) : R.Reply & Maybe<&2, KV.Item<String>>}

# LAW: SETNX leaves a key that is there alone and answers 0
law setnx_present:
  for +db: R.Db
  for +k: String
  for +v: String
  for +x: KV.Item<String>
  for  e: {there(db, k) == Some{x} : Maybe<&2, KV.Item<String>>}
  {R.exec(R.Upd{k, R.USetNx{v}}, db) == (R.r_int(0n), db) : R.Reply & R.Db}

# LAW: INCR of a key that is not there stores "1", with no time, and
# answers 1
law incr_missing:
  for +db: R.Db
  for +k: String
  for  e: {there(db, k) == None{} : Maybe<&2, KV.Item<String>>}
  {at_key(R.exec(R.IncrBy{k, R.IPos{1n}}, db), k) == (R.RInt{R.IPos{1n}}, Some{KV.Item{"1", 0n}}) : R.Reply & Maybe<&2, KV.Item<String>>}

# LAW: PTTL of a key there with a time answers the time left, in ms
law pttl_left:
  for +db: R.Db
  for +k: String
  for +v: String
  for +e: Nat
  for  h: {there(db, k) == Some{KV.Item{v, 1n+e}} : Maybe<&2, KV.Item<String>>}
  {R.exec(R.Peek{k, R.PPttl{}}, db) == (R.RInt{R.IPos{Nat.sub(1n+e, R.db.now(db))}}, db) : R.Reply & R.Db}

# LAW: SET with KEEPTTL of a key there keeps its time
law set_keepttl:
  for +db: R.Db
  for +k: String
  for +v: String
  for +w: String
  for +e: Nat
  for  h: {there(db, k) == Some{KV.Item{w, e}} : Maybe<&2, KV.Item<String>>}
  {at_key(R.exec(R.Upd{k, R.USet{v, 0n, R.TKeep{}, "set"}}, db), k) == (R.r_ok(), Some{KV.Item{v, e}}) : R.Reply & Maybe<&2, KV.Item<String>>}

# LAW: PERSIST of a key there with a time takes the time away and answers 1
law persist_effect:
  for +db: R.Db
  for +k: String
  for +v: String
  for +e: Nat
  for  h: {there(db, k) == Some{KV.Item{v, 1n+e}} : Maybe<&2, KV.Item<String>>}
  {at_key(R.exec(R.Upd{k, R.UPersist{}}, db), k) == (R.r_int(1n), Some{KV.Item{v, 0n}}) : R.Reply & Maybe<&2, KV.Item<String>>}

# LAW: GETDEL of a key there answers its value and deletes it
law getdel_effect:
  for +db: R.Db
  for +k: String
  for +v: String
  for +e: Nat
  for  h: {there(db, k) == Some{KV.Item{v, e}} : Maybe<&2, KV.Item<String>>}
  {at_key(R.exec(R.Upd{k, R.UGetDel{}}, db), k) == (R.RBulk{v}, None{}) : R.Reply & Maybe<&2, KV.Item<String>>}

# LAW: a batch runs as its commands one after another: the server runs
# pipelined requests through exec_all, and this law makes that the same
# as running them one by one
law batch_step:
  for +c: R.Cmd
  for +cs: List<&2, R.Cmd>
  for +db: R.Db
  {R.exec_all(c <> cs, db) == R.exec_all.cons(R.reply_of(R.exec(c, db)), R.exec_all(cs, R.db_of(R.exec(c, db)))) : List<&2, R.Reply> & R.Db}

# LAW: an empty batch answers nothing and changes nothing
law batch_nil:
  for +db: R.Db
  {R.exec_all(Nil{}, db) == (Nil{}, db) : List<&2, R.Reply> & R.Db}

# LAW: hints change nothing: the server runs each batch through
# batch.bend, which first starts loading the trie paths of its keys into
# the cache, and this law makes that exec_all, whatever the hashes
law batch_hints:
  for +cs: List<&2, R.Cmd>
  for +hs: List<&2, U32>
  for +db: R.Db
  {B.exec_batch(cs, hs, db) == R.exec_all(cs, db) : List<&2, R.Reply> & R.Db}

# a batch's replies, and the database after it
def replies(r: List<&2, R.Reply> & R.Db) -> List<&2, R.Reply>:
  (rs, db) = r
  rs

def final(r: List<&2, R.Reply> & R.Db) -> R.Db:
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
# reads, or c1 reads the whole database (DBSIZE, KEYS, SCAN) and c2 writes
# at all
def disturbs(+c2: R.Cmd, c1: R.Cmd) -> Bool:
  match c1:
    case R.Get{+k}:
      writes(c2, k)
    case R.IncrBy{+k, by}:
      writes(c2, k)
    case R.Upd{+k, op}:
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
    case R.Scan{a}:
      Bool.not(is_read(c2))
    case _:
      False{}

# LAW: a command answers the same after another one that does not
# disturb it
law commute_reply:
  for  c1: R.Cmd
  for +c2: R.Cmd
  for +db: R.Db
  for  e: {disturbs(c2, c1) == False{} : Bool}
  {R.reply_of(R.exec(c1, R.db_of(R.exec(c2, db)))) == R.reply_of(R.exec(c1, db)) : R.Reply}

# LAW: run in either order, two commands leave a key that at most one of
# them writes reading the same
law commute_reads:
  for +c1: R.Cmd
  for +c2: R.Cmd
  for +db: R.Db
  for +j: String
  for  e: {Bool.and(writes(c1, j), writes(c2, j)) == False{} : Bool}
  {KV.entry(String, R.db.t(R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))), j) == KV.entry(String, R.db.t(R.db_of(R.exec(c1, R.db_of(R.exec(c2, db))))), j) : Maybe<&2, KV.Item<String>>}

# LAW: two commands that do not disturb each other answer the same in
# either order
law commute:
  for +c1: R.Cmd
  for +c2: R.Cmd
  for +db: R.Db
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
    case R.IncrBy{+k, by}:
      writes(c2, k)
    case R.Upd{+k, op}:
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
# DBSIZE, KEYS and SCAN, which see the trie itself
def keywise(c: R.Cmd) -> Bool:
  match c:
    case R.DbSize{}:
      False{}
    case R.Keys{p}:
      False{}
    case R.Scan{a}:
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
  for +db: R.Db
  for  e1: {interferes(c1, c2) == False{} : Bool}
  for  e2: {keywise_all(cs) == True{} : Bool}
  {replies(R.exec_all(Con{c2, Con{c1, cs}}, db)) == swap2(replies(R.exec_all(Con{c1, Con{c2, cs}}, db))) : List<&2, R.Reply>}

# LAW: and after the whole batch, whatever it holds, every key reads the
# same
law swap_reads:
  for +c1: R.Cmd
  for +c2: R.Cmd
  for +cs: List<&2, R.Cmd>
  for +db: R.Db
  for +j: String
  for  e: {clash(c2, c1) == False{} : Bool}
  {KV.entry(String, R.db.t(final(R.exec_all(Con{c2, Con{c1, cs}}, db))), j) == KV.entry(String, R.db.t(final(R.exec_all(Con{c1, Con{c2, cs}}, db))), j) : Maybe<&2, KV.Item<String>>}

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
def log_out(r: List<&2, R.Reply> & (List<&2, R.Cmd> & R.Db)) -> List<&2, R.Reply> & R.Db:
  (rs, q) = r
  (rs, Pair.snd(List<&2, R.Cmd>, R.Db, q))

def effects(r: List<&2, R.Reply> & (List<&2, R.Cmd> & R.Db)) -> List<&2, R.Cmd>:
  (rs, q) = r
  Pair.fst(List<&2, R.Cmd>, R.Db, q)

# LAW: exec_log answers and leaves the database as exec_all does
law log_exec:
  for +cs: List<&2, R.Cmd>
  for +db: R.Db
  {log_out(A.exec_log(cs, db)) == R.exec_all(cs, db) : List<&2, R.Reply> & R.Db}

# LAW: hints change nothing here either: the actor runs each batch with
# log_batch, which first starts loading the trie paths of its keys into
# the cache, as exec_batch does, and this law makes that exec_log
law log_hints:
  for +cs: List<&2, R.Cmd>
  for +hs: List<&2, U32>
  for +db: R.Db
  {A.log_batch(cs, hs, db) == A.exec_log(cs, db) : List<&2, R.Reply> & (List<&2, R.Cmd> & R.Db)}

# LAW: a batch's effects, run at time 0 on the database the batch ran on,
# leave the database the batch left (at time 0: a file loads at time 0,
# when no key has expired, and the effects name every time from 1970)
law log_replay:
  for +cs: List<&2, R.Cmd>
  for +db: R.Db
  {final(R.exec_all(effects(A.exec_log(cs, db)), R.db.at(0n, db))) == R.db.at(0n, final(R.exec_all(cs, db))) : R.Db}

# LAW: a batch's effects, written as entries, parse back to them
law log_args:
  for +cs: List<&2, R.Cmd>
  for +db: R.Db
  {A.parse_all(A.args_all(effects(A.exec_log(cs, db)))) == effects(A.exec_log(cs, db)) : List<&2, R.Cmd>}

# LAW: a file loads as the entries written to it, with nothing left over
law aof_load:
  for +reqs: List<&2, List<&2, String>>
  {A.load(A.encode(reqs)) == (reqs, "") : List<&2, List<&2, String>> & String}

# a history: the batches the server has run since it started, newest
# first, each with the time it ran at (the server sets the database's
# time before each group of batches), run from an empty database
type Run is Data:
  Run{now: Nat, cs: List<&2, R.Cmd>}

def batch_at(b: Run, db: R.Db) -> R.Db:
  match b:
    case Run{now, cs}:
      final(R.exec_all(cs, R.db.at(now, db)))

def single(hist: List<&2, Run>) -> R.Db:
  match hist:
    case Nil{}:
      R.db.empty()
    case Con{b, older}:
      batch_at(b, single(older))

# the entries of a batch's effects, the batch run at its time on db
def logged(b: Run, db: R.Db) -> String:
  match b:
    case Run{now, cs}:
      A.encode(A.args_all(effects(A.exec_log(cs, R.db.at(now, db)))))

# the file after a history: the entries of each batch's effects, appended
# after those of the batches before it
def aof(hist: List<&2, Run>) -> String:
  match hist:
    case Nil{}:
      ""
    case Con{b, +older}:
      aof(older) ++ logged(b, single(older))

# LAW: after any history, the server restores from its file the database
# it held (at time 0: the server sets the time before it runs a batch
# again), and nothing is left over
law recover:
  for +hist: List<&2, Run>
  {A.restore(aof(hist)) == (R.db.at(0n, single(hist)), "") : R.Db & String}

# A crash in the middle of a write leaves the file cut anywhere: c is
# what reached the disk, d what did not. The server loads what it can
# (whole entries) and cuts the rest off (server.bend: restore).

# a command and the time it ran at
type Step is Data:
  Step{now: Nat, c: R.Cmd}

# the commands of a history, oldest first, each with its batch's time
def stamp(+now: Nat, cs: List<&2, R.Cmd>) -> List<&2, Step>:
  match cs:
    case Nil{}:
      Nil{}
    case Con{c, rest}:
      Step{now, c} <> stamp(now, rest)

def stamped(b: Run) -> List<&2, Step>:
  match b:
    case Run{+now, cs}:
      stamp(now, cs)

def commands(hist: List<&2, Run>) -> List<&2, Step>:
  match hist:
    case Nil{}:
      Nil{}
    case Con{b, older}:
      List.append(&2, Step, commands(older), stamped(b))

# commands run one after another, each at its time
def run_at(s: Step, db: R.Db) -> R.Db:
  match s:
    case Step{now, c}:
      R.db_of(R.exec(c, R.db.at(now, db)))

def run_timed(ss: List<&2, Step>, db: R.Db) -> R.Db:
  match ss:
    case Nil{}:
      db
    case Con{s, rest}:
      run_timed(rest, run_at(s, db))

# the database after the first j commands of a history
def held(hist: List<&2, Run>, j: Nat) -> R.Db:
  run_timed(List.take(&2, Step, commands(hist), j), R.db.empty())

# LAW: a file cut anywhere restores the database the server held after
# some prefix of its commands (at time 0): no command is applied in part,
# none is applied out of order, and none after one that is lost
law recover_cut:
  for +hist: List<&2, Run>
  for +c: String
  for -d: String
  for  e: {c ++ d == aof(hist) : String}
  Exists(Nat, j => {Pair.fst(R.Db, String, A.restore(c)) == R.db.at(0n, held(hist, j)) : R.Db})

# LAW: and what the loader reads, written again, followed by what it
# leaves, is the cut file: cutting the leftover off leaves whole entries
law load_cut:
  for +hist: List<&2, Run>
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
  for  db: R.Db
  {S.run(conn, srv, B.job(B.unzip(rs, Nil{}, Nil{})), db) == S.done.gen(S.gen(conn, srv, B.cmds_of(rs, Nil{}), db)) : S.Fin}

# LAW: and so with an append-only file
law run_log_gen:
  for  conn: S.Conn
  for  srv: S.Srv
  for +rs: List<&2, B.Req>
  for  db: R.Db
  {S.run_log(conn, srv, B.job(B.unzip(rs, Nil{}, Nil{})), db) == S.logged.gen(S.gen(conn, srv, B.cmds_of(rs, Nil{}), db)) : S.Logged}

def logged_es(l: S.Logged) -> List<&2, R.Cmd>:
  match l:
    case S.Logged{rs, es, conn, srv, db}:
      es

def logged_db(l: S.Logged) -> R.Db:
  match l:
    case S.Logged{rs, es, conn, srv, db}:
      db

# LAW: a batch leaves the database exec_all leaves by the commands that
# ran in it
law gen_db:
  for +conn: S.Conn
  for +srv: S.Srv
  for +cmds: List<&2, R.Cmd>
  for +db: R.Db
  {logged_db(S.logged.gen(S.gen(conn, srv, cmds, db))) == final(R.exec_all(S.plan(cmds, conn, srv), db)) : R.Db}

# LAW: and logs the effects exec_log gives them: the append-only file
# holds the history of the commands that ran, as the Persistence laws
# have it
law gen_log:
  for +conn: S.Conn
  for +srv: S.Srv
  for +cmds: List<&2, R.Cmd>
  for +db: R.Db
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
# their requirepass is the password from then on (what INFO counts stays,
# and so do the random numbers)
law config_pass:
  for  args: List<&2, String>
  for  conn: S.Conn
  for +srv: S.Srv
  for  cfg: List<&2, C.CItem>
  for  e: {C.config.set(args, S.srv.cfg(srv)) == Done{cfg} : Result<&2, &2, R.Reply, List<&2, C.CItem>>}
  {S.own_srv(R.SConfigSet{args}, conn, srv) == S.Srv{C.config.get_value(cfg, "requirepass"), cfg, S.srv.info(srv), S.srv.rng(srv)} : S.Srv}

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
