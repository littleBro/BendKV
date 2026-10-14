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

# the keys a command may write: its named keys, or every key for FLUSHDB
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
    case R.FlushDb{}:
      True{}
    case R.Upd{k, op}:
      KV.str_eq(j, k)
    case R.MSetNx{ps}:
      any_pair(j, ps)
    case R.Rename{src, dst, nx}:
      any_key(j, [src, dst])
    case R.BitOp{op, d, srcs}:
      KV.str_eq(j, d)
    case R.LMove{s, t, e}:
      any_key(j, [s, t])
    case R.LMPop{ks, left, c}:
      any_key(j, ks)
    case R.SStore{op, d, srcs}:
      KV.str_eq(j, d)
    case R.SMv{s, d, w}:
      any_key(j, [s, d])
    case R.ZStore{op, d, srcs}:
      KV.str_eq(j, d)
    case R.ZRangeStore{d, s, q}:
      KV.str_eq(j, d)
    case R.ZMPop{ks, max, c}:
      any_key(j, ks)
    case _:
      False{}

# the keys whose entries a command's writes depend on, besides the key
# each write is to: MSETNX sets its keys only when none of them is there,
# RENAME moves its source key's entry to its destination when the
# destination is not there for RENAMENX, BITOP sets its destination to
# what its sources make, LMOVE pushes onto its destination what it pops
# from its source, LMPOP pops from the first of its keys that is there,
# a STORE of a set operation sets its destination to what its sources
# make, SMOVE moves a member from its source to its destination, a STORE
# of a sorted-set operation (or of a range) sets its destination to what
# its sources (its source) make, and ZMPOP pops from the first of its
# keys that is there
def pair_keys(ps: List<&2, R.KVPair>) -> List<&2, String>:
  match ps:
    case Nil{}:
      Nil{}
    case Con{R.KP{k, v}, rest}:
      k <> pair_keys(rest)

def deps(c: R.Cmd) -> List<&2, String>:
  match c:
    case R.MSetNx{ps}:
      pair_keys(ps)
    case R.Rename{src, dst, nx}:
      [src, dst]
    case R.BitOp{op, d, srcs}:
      srcs
    case R.LMove{s, t, e}:
      [s, t]
    case R.LMPop{ks, left, c}:
      ks
    case R.SStore{op, d, srcs}:
      srcs
    case R.SMv{s, d, w}:
      [s, d]
    case R.ZStore{op, d, srcs}:
      srcs
    case R.ZRangeStore{d, s, q}:
      [s]
    case R.ZMPop{ks, max, c}:
      ks
    case _:
      Nil{}

# the commands that only read (a command of the connection or of the
# server, R.Own, never touches the database exec runs on: those that act
# on several databases are the acts of Several databases, below)
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
    case R.SOp{op, ks}:
      True{}
    case R.ZOp{op, ks}:
      True{}
    case R.Sort{k, o}:
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
  {KV.entry(KV.Val, R.db.t(R.db_of(R.exec(c, db))), j) == KV.entry(KV.Val, R.db.t(db), j) : Maybe<&2, KV.Item<KV.Val>>}

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
def there(+db: R.Db, +k: String) -> Maybe<&2, KV.Item<KV.Val>>:
  R.ent.live(R.db.now(db), KV.entry(KV.Val, R.db.t(db), k))

# LAW: a key whose time has passed is not there (so GET answers nil, DEL
# does not count it, SETNX sets it anew)
law expired:
  for +db: R.Db
  for +k: String
  for +v: KV.Val
  for +e: Nat
  for  h: {KV.entry(KV.Val, R.db.t(db), k) == Some{KV.Item{v, 1n+e}} : Maybe<&2, KV.Item<KV.Val>>}
  for  p: {Nat.is_lt(1n+e, R.db.now(db)) == True{} : Bool}
  {there(db, k) == None{} : Maybe<&2, KV.Item<KV.Val>>}

# LAW: GET of a key that is not there (never set, deleted, or expired)
# answers nil and changes nothing
law get_missing:
  for +db: R.Db
  for +k: String
  for  e: {there(db, k) == None{} : Maybe<&2, KV.Item<KV.Val>>}
  {R.exec(R.Get{k}, db) == (R.RNull{}, db) : R.Reply & R.Db}

# LAW: DEL removes every key it names, expired or not
law del_effect:
  for +ks: List<&2, String>
  for +db: R.Db
  for +j: String
  for  e: {any_key(j, ks) == True{} : Bool}
  {KV.entry(KV.Val, R.db.t(R.db_of(R.exec(R.Del{ks}, db))), j) == None{} : Maybe<&2, KV.Item<KV.Val>>}

# LAW: DEL of one key answers 1 when it was there, 0 when it was not
law del_one_count:
  for +db: R.Db
  for +k: String
  {R.reply_of(R.exec(R.Del{[k]}, db)) == R.r_int(Bool.pick(Nat, Maybe.is_some(&2, KV.Item<KV.Val>, there(db, k)), 1n, 0n)) : R.Reply}

# what a command answers, and what its key k holds after it
def at_key(r: R.Reply & R.Db, +k: String) -> R.Reply & Maybe<&2, KV.Item<KV.Val>>:
  (x, db) = r
  (x, KV.entry(KV.Val, R.db.t(db), k))

# the string a key there holds, and its time: nothing and none for a key
# that is not there
def old_val(m: Maybe<&2, KV.Item<KV.Val>>) -> String:
  match m:
    case Some{KV.Item{KV.VStr{v}, e}}:
      v
    case _:
      ""

# whether a key holds a collection (a command on strings answers it
# WRONGTYPE)
def holds_coll(m: Maybe<&2, KV.Item<KV.Val>>) -> Bool:
  match m:
    case Some{KV.Item{KV.VColl{c}, e}}:
      True{}
    case _:
      False{}

def old_exp(m: Maybe<&2, KV.Item<KV.Val>>) -> Nat:
  match m:
    case Some{KV.Item{v, e}}:
      e
    case None{}:
      0n

# LAW: APPEND stores the string the key held followed by the new bytes,
# keeping the key's time, and answers the new length
law append_effect:
  for +db: R.Db
  for +k: String
  for +s: String
  for  nc: {holds_coll(there(db, k)) == False{} : Bool}
  {at_key(R.exec(R.Upd{k, R.UAppend{s}}, db), k) == (R.r_int(String.length(old_val(there(db, k)) ++ s)), Some{KV.Item{KV.VStr{old_val(there(db, k)) ++ s}, old_exp(there(db, k))}}) : R.Reply & Maybe<&2, KV.Item<KV.Val>>}

# LAW: SETNX sets a key that is not there, with no time, and answers 1
law setnx_missing:
  for +db: R.Db
  for +k: String
  for +v: String
  for  e: {there(db, k) == None{} : Maybe<&2, KV.Item<KV.Val>>}
  {at_key(R.exec(R.Upd{k, R.USetNx{v}}, db), k) == (R.r_int(1n), Some{KV.Item{KV.VStr{v}, 0n}}) : R.Reply & Maybe<&2, KV.Item<KV.Val>>}

# LAW: SETNX leaves a key that is there alone and answers 0
law setnx_present:
  for +db: R.Db
  for +k: String
  for +v: String
  for +x: KV.Item<KV.Val>
  for  e: {there(db, k) == Some{x} : Maybe<&2, KV.Item<KV.Val>>}
  {R.exec(R.Upd{k, R.USetNx{v}}, db) == (R.r_int(0n), db) : R.Reply & R.Db}

# LAW: INCR of a key that is not there stores "1", with no time, and
# answers 1
law incr_missing:
  for +db: R.Db
  for +k: String
  for  e: {there(db, k) == None{} : Maybe<&2, KV.Item<KV.Val>>}
  {at_key(R.exec(R.IncrBy{k, R.IPos{1n}}, db), k) == (R.RInt{R.IPos{1n}}, Some{KV.Item{KV.VStr{"1"}, 0n}}) : R.Reply & Maybe<&2, KV.Item<KV.Val>>}

# LAW: PTTL of a key there with a time answers the time left, in ms
law pttl_left:
  for +db: R.Db
  for +k: String
  for +v: KV.Val
  for +e: Nat
  for  h: {there(db, k) == Some{KV.Item{v, 1n+e}} : Maybe<&2, KV.Item<KV.Val>>}
  {R.exec(R.Peek{k, R.PPttl{}}, db) == (R.RInt{R.IPos{Nat.sub(1n+e, R.db.now(db))}}, db) : R.Reply & R.Db}

# LAW: SET with KEEPTTL of a key there, of any kind, keeps its time
law set_keepttl:
  for +db: R.Db
  for +k: String
  for +v: String
  for +w: KV.Val
  for +e: Nat
  for  h: {there(db, k) == Some{KV.Item{w, e}} : Maybe<&2, KV.Item<KV.Val>>}
  {at_key(R.exec(R.Upd{k, R.USet{v, 0n, R.TKeep{}, "set"}}, db), k) == (R.r_ok(), Some{KV.Item{KV.VStr{v}, e}}) : R.Reply & Maybe<&2, KV.Item<KV.Val>>}

# LAW: PERSIST of a key there with a time takes the time away and answers 1
law persist_effect:
  for +db: R.Db
  for +k: String
  for +v: KV.Val
  for +e: Nat
  for  h: {there(db, k) == Some{KV.Item{v, 1n+e}} : Maybe<&2, KV.Item<KV.Val>>}
  {at_key(R.exec(R.Upd{k, R.UPersist{}}, db), k) == (R.r_int(1n), Some{KV.Item{v, 0n}}) : R.Reply & Maybe<&2, KV.Item<KV.Val>>}

# LAW: GETDEL of a key there that holds a string answers it and deletes it
law getdel_effect:
  for +db: R.Db
  for +k: String
  for +v: String
  for +e: Nat
  for  h: {there(db, k) == Some{KV.Item{KV.VStr{v}, e}} : Maybe<&2, KV.Item<KV.Val>>}
  {at_key(R.exec(R.Upd{k, R.UGetDel{}}, db), k) == (R.RBulk{v}, None{}) : R.Reply & Maybe<&2, KV.Item<KV.Val>>}

# LAW: SETRANGE of a key there writes s at offset o, the value padded
# with zero bytes when it is shorter, keeps the key's time and answers the
# new length, when it changes the key (R.range.go: s is not empty, and the
# value stays within 512MB; SETBIT's change is such a SETRANGE, of its
# byte)
law setrange_effect:
  for +db: R.Db
  for +k: String
  for +o: Nat
  for +s: String
  for +w: String
  for +e: Nat
  for  h: {there(db, k) == Some{KV.Item{KV.VStr{w}, e}} : Maybe<&2, KV.Item<KV.Val>>}
  for  ok: {R.range.go(o, s) == True{} : Bool}
  {at_key(R.exec(R.Upd{k, R.URange{o, s}}, db), k) == (R.r_int(String.length(R.range.put(w, o, s))), Some{KV.Item{KV.VStr{R.range.put(w, o, s)}, e}}) : R.Reply & Maybe<&2, KV.Item<KV.Val>>}

# what a command answers, and what two keys hold after it
def at_keys(r: R.Reply & R.Db, +s: String, +d: String) -> R.Reply & (Maybe<&2, KV.Item<KV.Val>> & Maybe<&2, KV.Item<KV.Val>>):
  (x, +db) = r
  (x, (KV.entry(KV.Val, R.db.t(db), s), KV.entry(KV.Val, R.db.t(db), d)))

# LAW: RENAME of a key there to another key moves the key's entry, its
# value and its time, and answers OK: the source is gone, and the
# destination holds what the source held, whatever it held before
law rename_effect:
  for +db: R.Db
  for +s: String
  for +d: String
  for +v: KV.Val
  for +e: Nat
  for  h: {there(db, s) == Some{KV.Item{v, e}} : Maybe<&2, KV.Item<KV.Val>>}
  for  ne: {KV.str_eq(s, d) == False{} : Bool}
  {at_keys(R.exec(R.Rename{s, d, False{}}, db), s, d) == (R.r_ok(), (None{}, Some{KV.Item{v, e}})) : R.Reply & (Maybe<&2, KV.Item<KV.Val>> & Maybe<&2, KV.Item<KV.Val>>)}

# whether a key of ks is there
def any_there(+db: R.Db, ks: List<&2, String>) -> Bool:
  match ks:
    case Nil{}:
      False{}
    case Con{+k, rest}:
      Bool.or(Maybe.is_some(&2, KV.Item<KV.Val>, there(db, k)), any_there(db, rest))

# LAW: MSETNX sets nothing when a key of its pairs is there, and answers 0
law msetnx_present:
  for +db: R.Db
  for +ps: List<&2, R.KVPair>
  for  e: {any_there(db, pair_keys(ps)) == True{} : Bool}
  {R.exec(R.MSetNx{ps}, db) == (R.r_int(0n), db) : R.Reply & R.Db}

# LAW: and when none is there it sets them all, as MSET does, and answers
# 1
law msetnx_missing:
  for +db: R.Db
  for +ps: List<&2, R.KVPair>
  for  e: {any_there(db, pair_keys(ps)) == False{} : Bool}
  {R.exec(R.MSetNx{ps}, db) == (R.r_int(1n), R.db_of(R.exec(R.MSet{ps}, db))) : R.Reply & R.Db}

# the value BITOP makes in a database, from its sources there at its now,
# and what its destination holds after it: nothing when the value is
# empty (e), else the value with no time
def bitop_val(+op: R.BitK, srcs: List<&2, String>, +db: R.Db) -> String:
  R.bitop.val(op, srcs, R.db.now(db), R.db.trie(db))

def stored(e: Bool, v: String) -> Maybe<&2, KV.Item<KV.Val>>:
  match e:
    case True{}:
      None{}
    case False{}:
      Some{KV.Item{KV.VStr{v}, 0n}}

# LAW: BITOP sets its destination to the value its sources make, with no
# time, and answers the value's length; an empty value deletes it (when
# no source holds a collection: that is WRONGTYPE)
law bitop_store:
  for +op: R.BitK
  for +d: String
  for +srcs: List<&2, String>
  for +db: R.Db
  for  nw: {R.bitop.wrong(srcs, R.db.now(db), R.db.trie(db)) == False{} : Bool}
  {at_key(R.exec(R.BitOp{op, d, srcs}, db), d) == (R.r_int(String.length(bitop_val(op, srcs, db))), stored(String.is_empty(bitop_val(op, srcs, db)), bitop_val(op, srcs, db))) : R.Reply & Maybe<&2, KV.Item<KV.Val>>}

# LAW: the sweep of expired keys deletes no key that is there: the
# server sweeps with DEL of the keys R.reap.keys keeps of those its scan
# found, whatever the scan found
law reap_keeps:
  for +ks: List<&2, String>
  for +db: R.Db
  for +j: String
  for +y: KV.Item<KV.Val>
  for  e: {there(db, j) == Some{y} : Maybe<&2, KV.Item<KV.Val>>}
  {KV.entry(KV.Val, R.db.t(R.db_of(R.exec(R.Del{R.reap.keys(ks, db)}, db))), j) == KV.entry(KV.Val, R.db.t(db), j) : Maybe<&2, KV.Item<KV.Val>>}

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
# only as that key read before it, and the keys its writes depend on
# (deps: RENAME moves a value from one key to another, MSETNX sets its
# keys when none of them is there), so for the database it is enough
# that no key is written by both, and that neither writes a key the
# other's writes depend on; for a reply, that the other command writes no
# key it reads. These laws speak of what keys read, not of the trie: two
# new keys of one bucket sit in the order they were set, so KEYS may list
# them in either order, as Redis's KEYS promises no order.

# whether c writes a key of ks
def writes_any(+c: R.Cmd, ks: List<&2, String>) -> Bool:
  match ks:
    case Nil{}:
      False{}
    case Con{+k, rest}:
      Bool.or(writes(c, k), writes_any(c, rest))

# whether c2 writes a key whose entry c1's writes depend on
def spoils(+c2: R.Cmd, c1: R.Cmd) -> Bool:
  writes_any(c2, deps(c1))

# whether c2, run first, may change what c1 answers: c2 writes a key c1
# reads, or c1 reads the whole database (DBSIZE, KEYS, SCAN), or keys
# that the values of others name (SORT, SORT_RO: its BY and GET
# patterns), and c2 writes at all
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
    case R.MSetNx{ps}:
      writes_any(c2, pair_keys(ps))
    case R.Rename{src, dst, nx}:
      writes_any(c2, [src, dst])
    case R.BitOp{op, d, srcs}:
      writes_any(c2, srcs)
    case R.LMove{s, t, e}:
      writes_any(c2, [s, t])
    case R.LMPop{ks, left, c}:
      writes_any(c2, ks)
    case R.SOp{op, ks}:
      writes_any(c2, ks)
    case R.SStore{op, d, srcs}:
      writes_any(c2, srcs)
    case R.SMv{s, d, w}:
      writes_any(c2, [s, d])
    case R.ZOp{op, ks}:
      writes_any(c2, ks)
    case R.ZStore{op, d, srcs}:
      writes_any(c2, srcs)
    case R.ZRangeStore{d, s, q}:
      writes_any(c2, [s])
    case R.ZMPop{ks, max, c}:
      writes_any(c2, ks)
    case R.DbSize{}:
      Bool.not(is_read(c2))
    case R.Keys{p}:
      Bool.not(is_read(c2))
    case R.Scan{a}:
      Bool.not(is_read(c2))
    case R.Sort{k, o}:
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
# them writes reading the same, when neither writes a key the other's
# writes depend on
law commute_reads:
  for +c1: R.Cmd
  for +c2: R.Cmd
  for +db: R.Db
  for +j: String
  for  e: {Bool.and(writes(c1, j), writes(c2, j)) == False{} : Bool}
  for  d: {Bool.or(spoils(c1, c2), spoils(c2, c1)) == False{} : Bool}
  {KV.entry(KV.Val, R.db.t(R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))), j) == KV.entry(KV.Val, R.db.t(R.db_of(R.exec(c1, R.db_of(R.exec(c2, db))))), j) : Maybe<&2, KV.Item<KV.Val>>}

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
# the other, they write no key in common and neither writes a key the
# other's writes depend on: the rest of the batch then runs on a database
# that reads the same at every key, so it answers the same, unless it
# holds DBSIZE or KEYS, which see the trie itself.

def writes_pairs(+c: R.Cmd, ps: List<&2, R.KVPair>) -> Bool:
  match ps:
    case Nil{}:
      False{}
    case Con{R.KP{+k, v}, rest}:
      Bool.or(writes(c, k), writes_pairs(c, rest))

# whether c2 may write a key c1 writes
def clash_w(+c2: R.Cmd, c1: R.Cmd) -> Bool:
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
    case R.FlushDb{}:
      Bool.not(is_read(c2))
    case R.MSetNx{ps}:
      writes_pairs(c2, ps)
    case R.Rename{src, dst, nx}:
      writes_any(c2, [src, dst])
    case R.BitOp{op, +d, srcs}:
      writes(c2, d)
    case R.LMove{s, t, e}:
      writes_any(c2, [s, t])
    case R.LMPop{ks, left, c}:
      writes_any(c2, ks)
    case R.SStore{op, +d, srcs}:
      writes(c2, d)
    case R.SMv{s, t, w}:
      writes_any(c2, [s, t])
    case R.ZStore{op, +d, srcs}:
      writes(c2, d)
    case R.ZRangeStore{+d, s, q}:
      writes(c2, d)
    case R.ZMPop{ks, max, c}:
      writes_any(c2, ks)
    case _:
      False{}

# whether c2 may write a key c1 writes, or either writes a key the
# other's writes depend on
def clash(+c2: R.Cmd, +c1: R.Cmd) -> Bool:
  Bool.or(clash_w(c2, c1), Bool.or(spoils(c1, c2), spoils(c2, c1)))

# whether two adjacent commands may not trade places: one disturbs the
# other, or they clash
def interferes(+c1: R.Cmd, +c2: R.Cmd) -> Bool:
  Bool.or(Bool.or(disturbs(c1, c2), disturbs(c2, c1)), clash(c2, c1))

# the commands whose replies depend only on what keys read, as the laws
# follow them: all but DBSIZE, KEYS and SCAN, which see the trie itself,
# and SORT, which reads keys that the values of others name
def keywise(c: R.Cmd) -> Bool:
  match c:
    case R.DbSize{}:
      False{}
    case R.Keys{p}:
      False{}
    case R.Scan{a}:
      False{}
    case R.Sort{k, o}:
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
  {KV.entry(KV.Val, R.db.t(final(R.exec_all(Con{c2, Con{c1, cs}}, db))), j) == KV.entry(KV.Val, R.db.t(final(R.exec_all(Con{c1, Con{c2, cs}}, db))), j) : Maybe<&2, KV.Item<KV.Val>>}

# Persistence
# ===========
# With an append-only file (server.bend: aof), the actor runs each batch
# with exec_log (aof.bend), which also gives what the batch did, as
# commands (its effects), and appends their entries to the file before it
# answers. At start the server loads the file and runs its entries from
# an empty database (restore). The laws of one database: exec_log answers
# as exec_all; a batch's effects, run on the database the batch ran on,
# leave the database the batch left; a client's effects, written as
# entries, parse back to themselves; a file loads as the entries written
# to it. The actor runs each batch after the hints of batch.bend
# (log_batch), which change nothing. On several databases an effect is
# located (A.Eff: the command's on the database it ran on, and SWAPDB,
# MOVE, FLUSHALL), and the file holds a SELECT before an effect on
# another database than the one it last selected; a transaction's effects
# (EXEC's, when they are two or more) are one entry of the file (A.Ent),
# written between a MULTI and an EXEC. So, after any history, the server
# restores from its file the databases it held; a file cut anywhere by a
# crash restores the databases the server held after some prefix of its
# acts in which every transaction is whole (the loader reverts a
# transaction the file ends inside), and the loader leaves exactly the
# part of an entry the cut left.

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
# first, each with the time it ran at (the server sets the focus's time
# before each group of batches) and what it did to the databases (its
# acts: those of its commands, S.plan, after the focus moved to its
# connection's database, R.AFocus), run from 1 + n empty databases; or
# the commands of a transaction (RunTx: what EXEC ran, its acts all
# together)
type Run is Data:
  Run{now: Nat, acts: List<&2, R.Act>}
  RunTx{now: Nat, acts: List<&2, R.Act>}

def batch_at(b: Run, ds: R.Ds) -> R.Ds:
  match b:
    case Run{now, as}:
      R.acts(as, R.ds.at(now, ds))
    case RunTx{now, as}:
      R.acts(as, R.ds.at(now, ds))

def single(hist: List<&2, Run>, +n: Nat) -> R.Ds:
  match hist:
    case Nil{}:
      R.ds.empty(n)
    case Con{b, older}:
      batch_at(b, single(older, n))

# acts run with their effects: the effects, in order
def act_effects(as: List<&2, R.Act>, ds: R.Ds) -> List<&2, A.Eff>:
  List.reverse(&2, A.Eff, Pair.fst(List<&2, A.Eff>, R.Ds, A.acts(as, (Nil{}, ds))))

# the effects of a batch, run at its time on ds, as entries of the
# file: each effect an entry of its own, and a transaction's effects one
# entry of them all when they are two or more (A.tx.wrap)
def batch_effs(b: Run, ds: R.Ds) -> List<&2, A.Ent>:
  match b:
    case Run{now, as}:
      A.ents.of(act_effects(as, R.ds.at(now, ds)))
    case RunTx{now, as}:
      A.tx.wrap(act_effects(as, R.ds.at(now, ds)))

# a file and the database its last SELECT selected, with the entries of
# more effects appended
def file.put(f: String & Nat, es: List<&2, A.Ent>) -> String & Nat:
  (s, +sel) = f
  +e = es
  (s ++ A.encode(A.ents.args(e, sel)), A.ents.sel(e, sel))

# the file after a history: the entries of each batch's effects, appended
# after those of the batches before it, a SELECT before an effect on
# another database than the file's (0 at first, as a file loads from
# database 0); and the database the file has selected
def file(hist: List<&2, Run>, +n: Nat) -> String & Nat:
  match hist:
    case Nil{}:
      ("", 0n)
    case Con{b, +older}:
      file.put(file(older, n), batch_effs(b, single(older, n)))

def aof(hist: List<&2, Run>, +n: Nat) -> String:
  Pair.fst(String, Nat, file(hist, n))

# the databases, each at time 0 (a database keeps the time it last ran at;
# at time 0 every key is there)
def zero.go(xs: List<&2, R.Db>) -> List<&2, R.Db>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{x, rest}:
      R.db.at(0n, x) <> zero.go(rest)

def zero(ds: R.Ds) -> List<&2, R.Db>:
  zero.go(R.ds.list(ds))

def zero.rest(p: R.Ds & String) -> List<&2, R.Db> & String:
  (ds, s) = p
  (zero(ds), s)

# LAW: after any history, the server restores from its file the databases
# it held (at time 0: the server sets the time before it runs a batch
# again), and nothing is left over. The number of databases has 14
# digits at most, so that each number the file names reads back as
# written (Redis's databases is an int).
law recover:
  for +hist: List<&2, Run>
  for +n: Nat
  for  sm: {KV.small(n) == True{} : Bool}
  {zero.rest(A.restore(aof(hist, n), n)) == (zero(single(hist, n)), "") : List<&2, R.Db> & String}

# A crash in the middle of a write leaves the file cut anywhere: c is
# what reached the disk, d what did not. The server loads what it can
# (whole entries, but for a transaction left open) and cuts the rest off
# (server.bend: restore).

# an act and the time it ran at; or a transaction's acts, together
type Step is Data:
  Step{now: Nat, a: R.Act}
  StepTx{now: Nat, acts: List<&2, R.Act>}

# the acts of a history, oldest first, each with its batch's time
def stamp(+now: Nat, as: List<&2, R.Act>) -> List<&2, Step>:
  match as:
    case Nil{}:
      Nil{}
    case Con{a, rest}:
      Step{now, a} <> stamp(now, rest)

def stamped(b: Run) -> List<&2, Step>:
  match b:
    case Run{+now, as}:
      stamp(now, as)
    case RunTx{now, as}:
      [StepTx{now, as}]

def commands(hist: List<&2, Run>) -> List<&2, Step>:
  match hist:
    case Nil{}:
      Nil{}
    case Con{b, older}:
      List.append(&2, Step, commands(older), stamped(b))

# acts run one after another, each at its time
def run_at(s: Step, ds: R.Ds) -> R.Ds:
  match s:
    case Step{now, a}:
      R.ds_of(R.act(a, R.ds.at(now, ds)))
    case StepTx{now, as}:
      R.acts(as, R.ds.at(now, ds))

def run_timed(ss: List<&2, Step>, ds: R.Ds) -> R.Ds:
  match ss:
    case Nil{}:
      ds
    case Con{s, rest}:
      run_timed(rest, run_at(s, ds))

# the databases after the first j steps of a history (an act, or a
# transaction whole)
def held(hist: List<&2, Run>, +n: Nat, j: Nat) -> R.Ds:
  run_timed(List.take(&2, Step, commands(hist), j), R.ds.empty(n))

# LAW: a file cut anywhere restores the databases the server held after
# some prefix of its acts in which every transaction is whole (at time
# 0): no act is applied in part, none is applied out of order, none after
# one that is lost, and none of a transaction's unless all of them are
law recover_cut:
  for +hist: List<&2, Run>
  for +n: Nat
  for  sm: {KV.small(n) == True{} : Bool}
  for +c: String
  for -d: String
  for  e: {c ++ d == aof(hist, n) : String}
  Exists(Nat, j => {zero(Pair.fst(R.Ds, String, A.restore(c, n))) == zero(held(hist, n, j)) : List<&2, R.Db>})

# LAW: and what the loader reads, written again, followed by what it
# leaves, is the cut file: cutting the leftover off leaves whole entries
law load_cut:
  for +hist: List<&2, Run>
  for +n: Nat
  for +c: String
  for -d: String
  for  e: {c ++ d == aof(hist, n) : String}
  {A.encode(Pair.fst(List<&2, List<&2, String>>, String, A.load(c))) ++ Pair.snd(List<&2, List<&2, String>>, String, A.load(c)) == c : String}

# LAW: the start replays its file with a check (A.checked), which refuses
# a file with an entry that would not replay as the file means it; when
# it refuses none, the start holds the databases replay gives, those the
# laws above restore
law checked_replay:
  for +reqs: List<&2, List<&2, String>>
  for +n: Nat
  for  e: {A.check(A.marks(reqs), A.file.acts(A.parse_all(reqs)), n) == None{} : Maybe<&1, Nat & Nat>}
  {A.checked(reqs, n) == A.Replayed{A.replay(reqs, n)} : A.Replay}

# Several databases
# =================
# The acts that change the databases as a whole (R.Act; session.bend:
# plan), seen at time 0 (zero): SELECT moves the focus and changes no
# database; SWAPDB of two databases that are there puts each in the
# other's place; FLUSHALL empties every database; MOVE of a key that is
# there, to another database that holds no entry for it, takes the key's
# entry out of the focus and puts it, its value and its time, in that
# database; COPY puts a copy of it in the database it names.

# LAW: SELECT changes no database
law focus_keeps:
  for +j: Nat
  for +ds: R.Ds
  {zero(R.ds_of(R.act(R.AFocus{j}, ds))) == zero(ds) : List<&2, R.Db>}

# LAW: and focuses the database it names when that one is there
law focus_on:
  for +j: Nat
  for +ds: R.Ds
  for -y: R.Db
  for  e: {R.ds.nth(j, R.ds.list(ds)) == Some{y} : Maybe<&2, R.Db>}
  {R.ds.index(R.ds_of(R.act(R.AFocus{j}, ds))) == j : Nat}

# LAW: SWAPDB puts each of two databases in the other's place
law swap_dbs:
  for +a: Nat
  for +b: Nat
  for +ds: R.Ds
  for +x: R.Db
  for +y: R.Db
  for  ea: {R.ds.nth(a, R.ds.list(ds)) == Some{x} : Maybe<&2, R.Db>}
  for  eb: {R.ds.nth(b, R.ds.list(ds)) == Some{y} : Maybe<&2, R.Db>}
  {zero(R.ds_of(R.act(R.ASwap{a, b}, ds))) == R.ds.put(a, R.db.at(0n, y), R.ds.put(b, R.db.at(0n, x), zero(ds))) : List<&2, R.Db>}

# LAW: FLUSHALL empties every database
law wipe_dbs:
  for +ds: R.Ds
  {zero(R.ds_of(R.act(R.AWipe{}, ds))) == R.ds.flush(zero(ds)) : List<&2, R.Db>}

# LAW: MOVE takes a key's entry out of the focus and sets it in the
# database it names
law move_key:
  for +k: String
  for +j: Nat
  for +ds: R.Ds
  for +y: R.Db
  for +v: KV.Val
  for +e: Nat
  for  ey: {R.ds.nth(j, R.ds.list(ds)) == Some{y} : Maybe<&2, R.Db>}
  for  ne: {Nat.is_ne(j, R.ds.index(ds)) == True{} : Bool}
  for  en: {R.db.entry(y, k) == None{} : Maybe<&2, KV.Item<KV.Val>>}
  for  ek: {R.ds.ent(ds, k) == Some{KV.Item{v, e}} : Maybe<&2, KV.Item<KV.Val>>}
  {zero(R.ds_of(R.act(R.AMove{k, j}, ds))) == R.ds.put(j, R.db.at(0n, R.db.setx(y, k, v, e)), zero(R.ds.unset(k, ds))) : List<&2, R.Db>}

# LAW: COPY of a key there, to a database that is there, when REPLACE is
# given or the destination key is not there in that database, sets the
# destination key there to the source's entry, its value and its time,
# and changes nothing else
law copy_key:
  for +s: String
  for +d: String
  for +j: Nat
  for +rep: Bool
  for +ds: R.Ds
  for +y: R.Db
  for +v: KV.Val
  for +e: Nat
  for  ey: {R.ds.nth(j, R.ds.list(ds)) == Some{y} : Maybe<&2, R.Db>}
  for  ek: {R.ds.ent(ds, s) == Some{KV.Item{v, e}} : Maybe<&2, KV.Item<KV.Val>>}
  for  ok: {Bool.or(rep, Bool.not(Maybe.is_some(&2, KV.Item<KV.Val>, R.ent.live(R.ds.now(ds), R.db.entry(y, d))))) == True{} : Bool}
  {zero(R.ds_of(R.act(R.ACopy{s, d, j, rep}, ds))) == R.ds.put(j, R.db.at(0n, R.db.setx(y, d, v, e)), zero(ds)) : List<&2, R.Db>}

# The key count
# =============
# A database keeps beside its trie how many keys it holds (R.db.n: what
# DBSIZE answers, and INFO's keyspace keys) and how many of them have a
# time (R.db.x: INFO's keyspace expires), so that neither is counted when
# it is read; each write changes them as it changes the trie (R.cnt.n,
# R.cnt.x). Both counts are sums over the trie's entries (tsum): of 1 for
# each entry, and of 1 for each entry with a time. Each key counts once:
# the trie is well formed (twf: nodes down to the buckets, and a key at
# most once in its bucket; a delete takes every entry of its key, so a
# key there twice would make the counts drift).

# what an entry weighs in a count: 1 (WAll: the keys), or 1 when it has a
# time and 0 when it has none (WTimed: the keys that can expire)
type Wt is Data:
  WAll{}
  WTimed{}

def wt(+w: Wt, +e: Nat) -> Nat:
  match w:
    case WAll{}:
      1n
    case WTimed{}:
      Bool.pick(Nat, Nat.is_eq(e, 0n), 0n, 1n)

# the weights of t's entries, summed
# BEGIN gen_trie: tsum
def tsum(-V: Data, +w: Wt, t: KV.Trie<V>) -> Nat:
  match t:
    case KV.Tip{}:
      0n
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}:
      Nat.add(tsum(V, w, c0), Nat.add(tsum(V, w, c1), Nat.add(tsum(V, w, c2), Nat.add(tsum(V, w, c3), Nat.add(tsum(V, w, c4), Nat.add(tsum(V, w, c5), Nat.add(tsum(V, w, c6), Nat.add(tsum(V, w, c7), Nat.add(tsum(V, w, c8), Nat.add(tsum(V, w, c9), Nat.add(tsum(V, w, c10), Nat.add(tsum(V, w, c11), Nat.add(tsum(V, w, c12), Nat.add(tsum(V, w, c13), Nat.add(tsum(V, w, c14), tsum(V, w, c15))))))))))))))))
    case KV.Ent{k, v, +e, rest}:
      Nat.add(wt(w, e), tsum(V, w, rest))
# END gen_trie: tsum

# a bucket holds a key at most once
def bwf(-V: Data, b: KV.Trie<V>) -> Bool:
  match b:
    case KV.Ent{+k, v, e, +rest}:
      Bool.and(Nat.is_eq(KV.bcode(V, k, rest), 0n), bwf(V, rest))
    case _:
      True{}

# a well-formed trie of depth d: nodes down to the buckets (an empty
# subtrie anywhere), each bucket as bwf says
# BEGIN gen_trie: twf
def twf(-V: Data, t: KV.Trie<V>, d: Nat) -> Bool:
  match t d:
    case KV.Tip{} _:
      True{}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} 0n:
      True{}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} 1n++p:
      Bool.and(twf(V, c0, p), Bool.and(twf(V, c1, p), Bool.and(twf(V, c2, p), Bool.and(twf(V, c3, p), Bool.and(twf(V, c4, p), Bool.and(twf(V, c5, p), Bool.and(twf(V, c6, p), Bool.and(twf(V, c7, p), Bool.and(twf(V, c8, p), Bool.and(twf(V, c9, p), Bool.and(twf(V, c10, p), Bool.and(twf(V, c11, p), Bool.and(twf(V, c12, p), Bool.and(twf(V, c13, p), Bool.and(twf(V, c14, p), twf(V, c15, p))))))))))))))))
    case KV.Ent{k, v, e, rest} 0n:
      bwf(V, KV.Ent{k, v, e, rest})
    case KV.Ent{k, v, e, rest} 1n+p:
      False{}
# END gen_trie: twf

# a database whose counts are its trie's own, its trie well formed (the
# keys' buckets lie 5 nodes deep)
def counted(+db: R.Db) -> Bool:
  match db:
    case R.Db{+t, +n, +x, now, rr}:
      Bool.and(twf(KV.Val, t, 5n), Bool.and(Nat.is_eq(n, tsum(KV.Val, WAll{}, t)), Nat.is_eq(x, tsum(KV.Val, WTimed{}, t))))

# every database of a list counted, and every one of the databases
def counted_list(xs: List<&2, R.Db>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case Con{+x, rest}:
      Bool.and(counted(x), counted_list(rest))

def counted_ds(+ds: R.Ds) -> Bool:
  match ds:
    case R.Ds{+d, +pre, +post}:
      Bool.and(counted(d), Bool.and(counted_list(pre), counted_list(post)))

# LAW: after any history, the counts of every database are its trie's
# own, and its trie is well formed
law counts_hold:
  for +hist: List<&2, Run>
  for +n: Nat
  {counted_ds(single(hist, n)) == True{} : Bool}

# LAW: so DBSIZE answers the number of keys of the database in focus: the
# entries of its trie (KV.size), those whose time has passed and that no
# command or sweep has deleted yet among them, as Redis counts them
law dbsize_size:
  for +hist: List<&2, Run>
  for +n: Nat
  {R.reply_of(R.exec(R.DbSize{}, R.ds.focused(single(hist, n)))) == R.r_int(KV.size(KV.Val, R.db.t(R.ds.focused(single(hist, n))))) : R.Reply}

# Sessions
# ========
# A batch runs with the state of its connection and of the server
# (session.bend): the server runs it as S.run, or S.run_log with an
# append-only file, which take a batch of database commands only, from a
# client that may run them and gets every reply, the fast way (exec_batch,
# log_batch, on the focus), and any other batch a command at a time
# (S.gen). The laws: the fast way is the general one; the general one
# changes the databases exactly as the acts of the commands that ran
# (S.plan) do, R.acts running them, and logs the effects A.acts gives
# them, so the laws of the commands, of the databases and of persistence
# hold for what ran; and a client that has not authenticated, to a server
# with a password, runs nothing but the errors the parser found, until it
# sends AUTH or HELLO.

# LAW: however the server takes a batch apart (B.unzip, B.job), it runs
# it as the general path runs its commands, in order
law run_gen:
  for  conn: S.Conn
  for  srv: S.Srv
  for +rs: List<&2, B.Req>
  for  ds: R.Ds
  {S.run(conn, srv, B.job(B.unzip(rs, Nil{}, Nil{})), ds) == S.done.gen(S.gen(conn, srv, B.cmds_of(rs, Nil{}), ds)) : S.Fin}

# LAW: and so with an append-only file
law run_log_gen:
  for  conn: S.Conn
  for  srv: S.Srv
  for +rs: List<&2, B.Req>
  for  ds: R.Ds
  {S.run_log(conn, srv, B.job(B.unzip(rs, Nil{}, Nil{})), ds) == S.logged.gen(S.gen(conn, srv, B.cmds_of(rs, Nil{}), ds)) : S.Logged}

def logged_es(l: S.Logged) -> List<&2, A.Eff>:
  match l:
    case S.Logged{rs, es, conn, srv, ds}:
      es

def logged_ds(l: S.Logged) -> R.Ds:
  match l:
    case S.Logged{rs, es, conn, srv, ds}:
      ds

# LAW: a batch leaves the databases the acts of the commands that ran in
# it leave
law gen_db:
  for +conn: S.Conn
  for +srv: S.Srv
  for +cmds: List<&2, R.Cmd>
  for +ds: R.Ds
  {logged_ds(S.logged.gen(S.gen(conn, srv, cmds, ds))) == R.acts(S.plan(cmds, conn, srv), ds) : R.Ds}

# LAW: and logs the effects A.acts gives them: the append-only file holds
# the history of what ran, as the Persistence laws have it
law gen_log:
  for +conn: S.Conn
  for +srv: S.Srv
  for +cmds: List<&2, R.Cmd>
  for +ds: R.Ds
  {logged_es(S.logged.gen(S.gen(conn, srv, cmds, ds))) == act_effects(S.plan(cmds, conn, srv), ds) : List<&2, A.Eff>}

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

# whether every act reads and changes no key: an error the parser found
# (R.Bad), which exec answers with the error and which changes nothing,
# or the focus moved (RESET moves it to database 0)
def all_bad(as: List<&2, R.Act>) -> Bool:
  match as:
    case Nil{}:
      True{}
    case Con{R.ARun{R.Bad{r}}, rest}:
      all_bad(rest)
    case Con{R.AFocus{j}, rest}:
      all_bad(rest)
    case Con{a, rest}:
      False{}

# LAW: a client that has not authenticated, to a server with a password,
# runs nothing on the databases but the errors the parser found, until it
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
# their requirepass is the password from then on (what INFO counts stays;
# what the server keeps for maxmemory reads their maxmemory parameters
# again, and keeps its random numbers)
law config_pass:
  for  args: List<&2, String>
  for  conn: S.Conn
  for +srv: S.Srv
  for  cfg: List<&2, C.CItem>
  for  e: {C.config.set(args, S.srv.cfg(srv)) == Done{cfg} : Result<&2, &2, R.Reply, List<&2, C.CItem>>}
  {S.own_srv(R.SConfigSet{args}, conn, srv) == S.Srv{C.config.get_value(cfg, "requirepass"), cfg, S.srv.info(srv), S.mm.cfg(S.srv.mm(srv), cfg)} : S.Srv}

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
