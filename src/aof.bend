# aof.bend: the append-only file. After each batch the server appends what
# its commands did (effects), each entry written as Redis writes its AOF:
# a RESP array of bulk strings, a SELECT before the entries of another
# database than the one the file last selected, and SWAPDB, MOVE and
# FLUSHALL as Redis writes them. At start it reads the file back (load),
# parses each entry (R.parse) and runs the entries from 1 + n empty
# databases (restore): a SELECT moves the focus, and every other entry
# acts as the server acted. LAWS.bend (Persistence) proves that this gives
# back exactly the databases the server had: the file reads back as the
# entries written to it, each entry parses back to its command, the
# effects of a batch leave the database the batch left, and a file cut
# anywhere by a crash restores the databases after some prefix of the
# server's acts. The start runs that replay after a check that refuses a
# file with an entry it would not replay as the file means it (checked,
# below), and the law checked_replay makes it the same replay.

import Base
import ./map.bend as KV
import ./redis.bend as R
import ./resp.bend as P
import ./batch.bend as B
import ./float.bend as F

# Effects
# -------
# What a command did, as commands that do it again on the database it ran
# on, at time 0 (a file loads at time 0, when no key has expired): none
# for one that only reads or fails, the command itself for SET, DEL, MSET
# and FLUSHDB, the MSET of its pairs for an MSETNX that set them, RENAME
# for a RENAME or RENAMENX that moved its entry, the SET of BITOP's value
# (the DEL of its destination when the value is empty), and for an update (R.Upd,
# and INCRBY, run here as one) what its change left of its key: SET of
# the value it holds (with PXAT and the time it expires at, when it
# does), PEXPIREAT for a time alone, PERSIST for none, DEL for a key
# gone, SET with KEEPTTL for a value set with the time kept (an INCRBY
# logs the SET of the sum, as Redis logs INCRBYFLOAT), and APPEND or
# SETRANGE again for an APPEND or a SETRANGE (or a SETBIT: the SETRANGE
# of its byte) to a key that was there, so that the file does not hold
# the whole value again; a write of a hash as the HSET of the pairs it
# set (HSETNX's pair, HINCRBY's field with its sum) or the HDEL of the
# fields it took, and a new hash where a key whose time had passed still
# lay as one entry that deletes the key and sets the pairs (hnew.effect,
# below). Every time is from 1970, so the effects mean the
# same whenever they run, and a time, or an offset, is of 14 digits at
# most (KV.small): no number but such a time or offset, or a database's
# number, is ever read back from text.

# a key left with v and time e (0: none)
def put.effect(+k: String, v: String, +e: Nat) -> List<&2, R.Cmd>:
  match e:
    case 0n:
      [R.Set{k, v}]
    case 1n+p:
      [R.Upd{k, R.USet{v, 0n, R.TAt{R.TmN{True{}, 1n+p}}, "set"}}]

# a key left with its value and time e
def exp.effect(+k: String, +e: Nat) -> List<&2, R.Cmd>:
  match e:
    case 0n:
      [R.Upd{k, R.UPersist{}}]
    case 1n+p:
      [R.Upd{k, R.UExpire{R.TmN{True{}, 1n+p}, R.ExpIf{False{}, False{}, False{}, False{}}, "pexpireat"}}]

# the effects of a command but an update
def effect(c: R.Cmd) -> List<&2, R.Cmd>:
  match c:
    case R.Set{k, v}:
      [R.Set{k, v}]
    case R.Del{Con{k, ks}}:
      [R.Del{k <> ks}]
    case R.MSet{Con{p, ps}}:
      [R.MSet{p <> ps}]
    case R.FlushDb{}:
      [R.FlushDb{}]
    case _:
      Nil{}

# a new hash, its pairs set where the key was not there at now: an HSET
# of them where the trie held no entry for the key (gone), else the
# script that deletes the key and runs the HSET (R.HWNew), one entry: the
# entry whose time had passed is in the file, there again when the file
# loads, and Redis's MULTI with a DEL and the HSET is two, which a crash
# could part
def hnew.effect(gone: Bool, +k: String, ps: List<&2, KV.HPair>) -> List<&2, R.Cmd>:
  match gone:
    case True{}:
      [R.Upd{k, R.UHash{R.HWSet{ps, False{}}}}]
    case False{}:
      [R.Upd{k, R.UHash{R.HWNew{ps}}}]

# a new list, its elements xs pushed at its first end (left) or its
# last: the push where the trie held no entry for the key (gone), else
# the script that deletes the key and runs the pushes (R.LWNew), one
# entry, as for a new hash
def lnew.effect(gone: Bool, +k: String, +left: Bool, xs: List<&2, String>) -> List<&2, R.Cmd>:
  match gone:
    case True{}:
      [R.Upd{k, R.UList{R.LWPush{left, xs}}}]
    case False{}:
      [R.Upd{k, R.UList{R.LWNew{left, xs}}}]

# a new set, its members ms added in turn: the SADD of them where the
# trie held no entry for the key (gone), else the script that deletes the
# key and runs the SADD (R.SWNew), one entry, as for a new hash
def snew.effect(gone: Bool, +k: String, ms: List<&2, String>) -> List<&2, R.Cmd>:
  match gone:
    case True{}:
      [R.Upd{k, R.UMems{R.SWAdd{ms}}}]
    case False{}:
      [R.Upd{k, R.UMems{R.SWNew{ms}}}]

# a new sorted set, made by a ZADD of options o and pairs ps: the ZADD
# where the trie held no entry for the key (gone), else the script that
# deletes the key and runs the ZADD (R.ZWNew), one entry, as for a new
# hash
def znew.effect(gone: Bool, +k: String, o: R.ZOpts, ps: List<&2, R.ZPair>) -> List<&2, R.Cmd>:
  match gone:
    case True{}:
      [R.Upd{k, R.UZset{R.ZWAdd{o, ps}}}]
    case False{}:
      [R.Upd{k, R.UZset{R.ZWNew{o, ps}}}]

# the effects of an update, from the change it made to its key, whose
# code was c (R.ent.code)
def ch.effect(+k: String, +c: Nat, +ch: R.Change) -> List<&2, R.Cmd>:
  match ch:
    case R.CKeep{}:
      Nil{}
    case R.CDel{}:
      [R.Del{[k]}]
    case R.CExp{+e}:
      exp.effect(k, e)
    case R.CPut{+v, +e}:
      put.effect(k, v, e)
    case R.CKeepT{+v}:
      [R.Upd{k, R.USet{v, 0n, R.TKeep{}, "set"}}]
    case R.CApp{+a, v}:
      [R.Upd{k, R.UAppend{a}}]
    case R.CRange{+o, +a, v}:
      [R.Upd{k, R.URange{o, a}}]
    case R.CHash{op, h}:
      [R.Upd{k, R.UHash{op}}]
    case R.CHashNew{ps, h}:
      hnew.effect(Nat.is_eq(c, 0n), k, ps)
    case R.CList{op, l}:
      [R.Upd{k, R.UList{op}}]
    case R.CListNew{+left, xs, l}:
      lnew.effect(Nat.is_eq(c, 0n), k, left, xs)
    case R.CMems{op, s}:
      [R.Upd{k, R.UMems{op}}]
    case R.CMemsNew{ms, s}:
      snew.effect(Nat.is_eq(c, 0n), k, ms)
    case R.CZset{op, z}:
      [R.Upd{k, R.UZset{op}}]
    case R.CZsetNew{o, ps, z}:
      znew.effect(Nat.is_eq(c, 0n), k, o, ps)

def upd.effect(+k: String, +c: Nat, +o: R.Out) -> List<&2, R.Cmd>:
  match o:
    case R.Out{r, +ch}:
      ch.effect(k, c, ch)

# A command run with its effects: its reply, what it did (effects) and
# the database after it. An update reads its key's entry, makes its
# change (R.upd, as R.db.upd does) and gives the change's effects; so
# does INCRBY, as the update UIncr (which R.db.incr runs the same way);
# any other command runs as R.exec runs it.
def run.out(r: R.Reply & R.Db, es: List<&2, R.Cmd>) -> R.Reply & (List<&2, R.Cmd> & R.Db):
  (x, db) = r
  (x, (es, db))

# an update of k from the code c of k's entry and the entry there at now
# (lm), its value taken out of the keyspace while it changes as
# R.db.upd.go takes it
def run.upd.go(take: Bool, t: KV.Trie<KV.Val>, +k: String, +h: U32, +n: Nat, +x: Nat, +now: Nat, rr: Maybe<&2, R.Db>, op: R.UpdOp, +c: Nat, lm: Maybe<&2, KV.Item<KV.Val>>) -> R.Reply & (List<&2, R.Cmd> & R.Db):
  match take:
    case True{}:
      u = KV.keep.at(KV.Val, t, k, R.upd.hole(), h)
      +o = R.upd.v(op, now, lm)
      run.out(R.upd.put(u, k, h, n, x, now, rr, c, o), upd.effect(k, c, o))
    case False{}:
      +o = R.upd.v(op, now, lm)
      run.out(R.upd.put(t, k, h, n, x, now, rr, c, o), upd.effect(k, c, o))

def run.upd(db: R.Db, +k: String, +op: R.UpdOp) -> R.Reply & (List<&2, R.Cmd> & R.Db):
  match db:
    case R.Db{+t, +n, +x, +now, rr}:
      +h = KV.hash(k)
      +m = KV.entry.at(KV.Val, t, k, h)
      +c = R.ent.code(m)
      +lm = R.ent.live(now, m)
      run.upd.go(R.upd.takes(op, lm), t, k, h, n, x, now, rr, op, c, lm)

def run.put(c: R.Cmd, r: R.Reply & R.Db) -> R.Reply & (List<&2, R.Cmd> & R.Db):
  (x, db) = r
  (x, (effect(c), db))

# MSETNX's effect: the MSET of its pairs, when it set them
def msetnx.effect(any: Bool, ps: List<&2, R.KVPair>) -> List<&2, R.Cmd>:
  match any:
    case True{}:
      Nil{}
    case False{}:
      effect(R.MSet{ps})

def run.msetnx(+ps: List<&2, R.KVPair>, db: R.Db) -> R.Reply & (List<&2, R.Cmd> & R.Db):
  +d = db
  es = msetnx.effect(R.pairs.live(ps, R.db.now(d), R.db.trie(d)), ps)
  run.out(R.exec(R.MSetNx{ps}, d), es)

# RENAME's and RENAMENX's effect: the RENAME of src to dst, when the
# entry moved
def ren.effect(r: R.Ren, +src: String, +dst: String) -> List<&2, R.Cmd>:
  match r:
    case R.RnMove{v, e}:
      [R.Rename{src, dst, False{}}]
    case _:
      Nil{}

def run.rename(+src: String, +dst: String, +nx: Bool, db: R.Db) -> R.Reply & (List<&2, R.Cmd> & R.Db):
  +d = db
  es = ren.effect(R.ren.find(d, src, dst, nx), src, dst)
  run.out(R.exec(R.Rename{src, dst, nx}, d), es)

# BITOP's effect: the SET of its value, or the DEL of its destination
# when the value is empty
def bitop.effect(e: Bool, +v: String, +d: String) -> List<&2, R.Cmd>:
  match e:
    case True{}:
      [R.Del{[d]}]
    case False{}:
      [R.Set{d, v}]

# none when a source holds a collection (WRONGTYPE)
def bitop.eff(wrong: Bool, +op: R.BitK, +d: String, +srcs: List<&2, String>, +x: R.Db) -> List<&2, R.Cmd>:
  match wrong:
    case True{}:
      Nil{}
    case False{}:
      +v = R.bitop.val(op, srcs, R.db.now(x), R.db.trie(x))
      bitop.effect(String.is_empty(v), v, d)

def run.bitop(+op: R.BitK, +d: String, +srcs: List<&2, String>, db: R.Db) -> R.Reply & (List<&2, R.Cmd> & R.Db):
  +x = db
  run.out(R.exec(R.BitOp{op, d, srcs}, x), bitop.eff(R.bitop.wrong(srcs, R.db.now(x), R.db.trie(x)), op, d, srcs, x))

# LMOVE's effect: the LMOVE when it moved an element, in its New form
# (the script that deletes the destination first) when the destination
# held an entry whose time had passed (a New form logs itself again)
def lmove.moved(m: R.Mv) -> Bool:
  match m:
    case R.MvNone{}:
      False{}
    case R.MvWrong{}:
      False{}
    case _:
      True{}

def lmove.effect(moved: Bool, dead: Bool, +s: String, +t: String, +e: R.LEnds) -> List<&2, R.Cmd>:
  match moved dead:
    case True{} True{}:
      [R.LMove{s, t, R.ends.new(e)}]
    case True{} False{}:
      [R.LMove{s, t, e}]
    case False{} _:
      Nil{}

def run.lmove(+s: String, +t: String, +e: R.LEnds, db: R.Db) -> R.Reply & (List<&2, R.Cmd> & R.Db):
  +d = db
  es = lmove.effect(lmove.moved(R.mv.find(d, s, t, e)), R.ent.dead(R.db.now(d), R.db.entry(d, t)), s, t, e)
  run.out(R.exec(R.LMove{s, t, e}, d), es)

# LMPOP's effect: the update of the key it pops from (an LPOP or RPOP of
# the count, or the DEL of its last elements), as run.upd gives it
def lmpop.out(+k: String, r: R.Reply & (List<&2, R.Cmd> & R.Db)) -> R.Reply & (List<&2, R.Cmd> & R.Db):
  (x, q) = r
  (R.lmpop.reply(k, x), q)

def lmpop.at(m: Maybe<&2, String>, +left: Bool, c: String, db: R.Db) -> R.Reply & (List<&2, R.Cmd> & R.Db):
  match m:
    case Some{+k}:
      lmpop.out(k, run.upd(db, k, R.UList{R.LWPopN{left, c}}))
    case None{}:
      (R.RNullA{}, (Nil{}, db))

def run.lmpop(ks: List<&2, String>, +left: Bool, c: String, db: R.Db) -> R.Reply & (List<&2, R.Cmd> & R.Db):
  +x = db
  +k = ks
  lmpop.at(R.lmpop.first(k, R.lmpop.head(k, x), x), left, c, x)

# SINTERSTORE's, SUNIONSTORE's and SDIFFSTORE's effects: those of the
# write the STORE makes of its destination (the DEL of it when the
# operation makes no member, else the update SWNew of the members, as
# run.upd gives its effects), with the STORE's reply
def sstore.ans(+n: Nat, r: R.Reply & (List<&2, R.Cmd> & R.Db)) -> R.Reply & (List<&2, R.Cmd> & R.Db):
  (x, q) = r
  (R.r_int(n), q)

def sstore.put(+ms: List<&2, String>, +d: String, db: R.Db) -> R.Reply & (List<&2, R.Cmd> & R.Db):
  sstore.ans(List.length(&2, String, ms), run.upd(db, d, R.UMems{R.SWNew{ms}}))

def sstore.eff(xs: List<&2, String>, +d: String, db: R.Db) -> R.Reply & (List<&2, R.Cmd> & R.Db):
  match xs:
    case Nil{}:
      sstore.ans(0n, run.put(R.Del{[d]}, R.exec(R.Del{[d]}, db)))
    case Con{x, rest}:
      sstore.put(x <> rest, d, db)

def sstore.run(g: R.SGot, op: R.SetK, ks: List<&2, String>, +d: String, db: R.Db) -> R.Reply & (List<&2, R.Cmd> & R.Db):
  match g:
    case R.SGot{ss}:
      sstore.eff(R.sop.members(op, ks, ss), d, db)
    case R.SGotWrong{}:
      (R.e_wrongtype(), (Nil{}, db))

def run.sstore(op: R.SetK, +d: String, ks: List<&2, String>, db: R.Db) -> R.Reply & (List<&2, R.Cmd> & R.Db):
  +x = db
  +k = ks
  sstore.run(R.sets.at(k, R.db.now(x), R.db.trie(x)), op, k, d, x)

# ZUNIONSTORE's, ZINTERSTORE's, ZDIFFSTORE's and ZRANGESTORE's effects:
# those of the write the STORE makes of its destination (the DEL of it
# when the operation makes no member, else the update ZWNew of the
# pairs, as run.upd gives its effects), with the STORE's reply
def zstore.eff(+xs: List<&2, KV.ZEl>, +d: String, db: R.Db) -> R.Reply & (List<&2, R.Cmd> & R.Db):
  match xs:
    case Nil{}:
      sstore.ans(0n, run.put(R.Del{[d]}, R.exec(R.Del{[d]}, db)))
    case Con{x, rest}:
      sstore.ans(List.length(&2, KV.ZEl, xs), run.upd(db, d, R.UZset{R.ZWNew{R.zopts.none(), R.zstore.pairs(xs)}}))

def zstore.ok(bad: Maybe<&2, R.Reply>, +op: R.ZSetK, ss: List<&2, R.ZSrc>, +d: String, db: R.Db) -> R.Reply & (List<&2, R.Cmd> & R.Db):
  match bad:
    case Some{r}:
      (r, (Nil{}, db))
    case None{}:
      zstore.eff(R.zop.els(op, ss), d, db)

def zstore.run(g: R.ZGot, +op: R.ZSetK, +d: String, db: R.Db) -> R.Reply & (List<&2, R.Cmd> & R.Db):
  match g:
    case R.ZGot{ss}:
      zstore.ok(R.zop.bad(op), op, ss, d, db)
    case R.ZGotWrong{}:
      (R.e_wrongtype(), (Nil{}, db))

def run.zstore(+op: R.ZSetK, +d: String, ks: List<&2, String>, db: R.Db) -> R.Reply & (List<&2, R.Cmd> & R.Db):
  +x = db
  zstore.run(R.zsrcs.at(ks, R.db.now(x), R.db.trie(x)), op, d, x)

def zrs.run(m: Maybe<&2, KV.Val>, q: R.ZQ, +d: String, db: R.Db) -> R.Reply & (List<&2, R.Cmd> & R.Db):
  match m:
    case None{}:
      zstore.eff(Nil{}, d, db)
    case Some{KV.VColl{KV.CZset{+z}}}:
      zstore.eff(R.zq.run(q, z), d, db)
    case Some{v}:
      (R.e_wrongtype(), (Nil{}, db))

def run.zrangestore(+d: String, +s: String, q: R.ZQ, db: R.Db) -> R.Reply & (List<&2, R.Cmd> & R.Db):
  +x = db
  zrs.run(R.db.read(x, s), q, d, x)

# ZMPOP's effect: the update of the key it pops from (a ZPOPMIN or
# ZPOPMAX of the count, or the DEL of its last elements), as run.upd
# gives it
def zmpop.out(+k: String, r: R.Reply & (List<&2, R.Cmd> & R.Db)) -> R.Reply & (List<&2, R.Cmd> & R.Db):
  (x, q) = r
  (R.zmpop.reply(k, x), q)

def zmpop.at(m: Maybe<&2, String>, +max: Bool, c: String, db: R.Db) -> R.Reply & (List<&2, R.Cmd> & R.Db):
  match m:
    case Some{+k}:
      zmpop.out(k, run.upd(db, k, R.UZset{R.ZWPopN{max, c}}))
    case None{}:
      (R.RNullA{}, (Nil{}, db))

def run.zmpop(ks: List<&2, String>, +max: Bool, c: String, db: R.Db) -> R.Reply & (List<&2, R.Cmd> & R.Db):
  +x = db
  +k = ks
  zmpop.at(R.lmpop.first(k, R.lmpop.head(k, x), x), max, c, x)

# SMOVE's effect: the SMOVE when it moved its member, in its New form (the
# script that deletes the destination first) when the destination held
# an entry whose time had passed (a New form logs itself again)
def smove.moved(f: R.Smv) -> Bool:
  match f:
    case R.SmvGo{}:
      True{}
    case _:
      False{}

def smove.effect(moved: Bool, dead: Bool, +s: String, +d: String, +w: R.SMem) -> List<&2, R.Cmd>:
  match moved dead:
    case True{} True{}:
      [R.SMv{s, d, R.SMemNew{R.smv.member(w)}}]
    case True{} False{}:
      [R.SMv{s, d, w}]
    case False{} _:
      Nil{}

def run.smove(+s: String, +d: String, +w: R.SMem, db: R.Db) -> R.Reply & (List<&2, R.Cmd> & R.Db):
  +x = db
  es = smove.effect(smove.moved(R.smv.of(x, s, d, w)), R.ent.dead(R.db.now(x), R.db.entry(x, d)), s, d, w)
  run.out(R.exec(R.SMv{s, d, w}, x), es)

def run(+c: R.Cmd, db: R.Db) -> R.Reply & (List<&2, R.Cmd> & R.Db):
  match c:
    case R.Upd{+k, +op}:
      run.upd(db, k, op)
    case R.IncrBy{+k, +by}:
      run.upd(db, k, R.UIncr{by})
    case R.MSetNx{+ps}:
      run.msetnx(ps, db)
    case R.Rename{+src, +dst, +nx}:
      run.rename(src, dst, nx, db)
    case R.BitOp{+op, +d, +srcs}:
      run.bitop(op, d, srcs, db)
    case R.LMove{+s, +t, +e}:
      run.lmove(s, t, e, db)
    case R.LMPop{+ks, +left, +n}:
      run.lmpop(ks, left, n, db)
    case R.SStore{+op, +d, +ks}:
      run.sstore(op, d, ks, db)
    case R.SMv{+s, +d, +w}:
      run.smove(s, d, w, db)
    case R.ZStore{+op, +d, ks}:
      run.zstore(op, d, ks, db)
    case R.ZRangeStore{+d, +s, q}:
      run.zrangestore(d, s, q, db)
    case R.ZMPop{ks, +max, c}:
      run.zmpop(ks, max, c, db)
    case _:
      run.put(c, R.exec(c, db))

# a batch run with its effects: the replies, what the batch did, in
# order, and the database after it, as exec_all runs it
def log.put(rs: List<&2, R.Reply>, es: List<&2, R.Cmd>, r: R.Reply & (List<&2, R.Cmd> & R.Db)) -> List<&2, R.Reply> & (List<&2, R.Cmd> & R.Db):
  (x, q) = r
  (e, d) = q
  (x <> rs, (List.reverse.go(&2, R.Cmd, e, es), d))

def log.run(rs: List<&2, R.Reply>, c: R.Cmd, q: List<&2, R.Cmd> & R.Db) -> List<&2, R.Reply> & (List<&2, R.Cmd> & R.Db):
  (es, db) = q
  log.put(rs, es, run(c, db))

def log.step(c: R.Cmd, st: List<&2, R.Reply> & (List<&2, R.Cmd> & R.Db)) -> List<&2, R.Reply> & (List<&2, R.Cmd> & R.Db):
  (rs, q) = st
  log.run(rs, c, q)

def log.go(cs: List<&2, R.Cmd>, st: List<&2, R.Reply> & (List<&2, R.Cmd> & R.Db)) -> List<&2, R.Reply> & (List<&2, R.Cmd> & R.Db):
  match cs:
    case Nil{}:
      st
    case Con{c, rest}:
      log.go(rest, log.step(c, st))

def log.fin2(q: List<&2, R.Cmd> & R.Db) -> List<&2, R.Cmd> & R.Db:
  (es, db) = q
  (List.reverse(&2, R.Cmd, es), db)

def log.fin(st: List<&2, R.Reply> & (List<&2, R.Cmd> & R.Db)) -> List<&2, R.Reply> & (List<&2, R.Cmd> & R.Db):
  (rs, q) = st
  (List.reverse(&2, R.Reply, rs), log.fin2(q))

def exec_log(cs: List<&2, R.Cmd>, db: R.Db) -> List<&2, R.Reply> & (List<&2, R.Cmd> & R.Db):
  log.fin(log.go(cs, (Nil{}, (Nil{}, db))))

# a batch run with its effects after the hints of batch.bend (the trie
# paths of its keys start loading into the cache first), as exec_batch
# runs one; LAWS.bend (log_hints) makes it exec_log
def log_hinted(u: Bool, cs: List<&2, R.Cmd>, db: R.Db) -> List<&2, R.Reply> & (List<&2, R.Cmd> & R.Db):
  match u:
    case True{}:
      exec_log(cs, db)
    case False{}:
      exec_log(cs, db)

def log_batch(cs: List<&2, R.Cmd>, hs: List<&2, U32>, db: R.Db) -> List<&2, R.Reply> & (List<&2, R.Cmd> & R.Db):
  +d = db
  +h = hs
  log_hinted(U32.is_eq(B.touch_db(B.many(h), h, d), 0), cs, d)

# Several databases
# -----------------
# An effect on several databases is located: a command's effect is on
# the database the command ran on (EDb), and SWAPDB, MOVE, COPY and
# FLUSHALL are effects of their own, MOVE's the key moved from database
# src to dst, COPY's the key src of database from copied to dst of
# database to. An act (R.Act) has at most one effect: a command of one
# database has its command's (A.run), a focus moved none, MOVE's first
# step the DEL of the key's entry in the other database, its second step
# the move, a COPY that copied the copy.

type Eff is Data:
  EDb{db: Nat, c: R.Cmd}
  ESwap{a: Nat, b: Nat}
  EMove{key: String, src: Nat, dst: Nat}
  ECopy{src: String, dst: String, from: Nat, to: Nat}
  EWipe{}

# a database's effects, located at its number
def at_db(+i: Nat, es: List<&2, R.Cmd>) -> List<&2, Eff>:
  match es:
    case Nil{}:
      Nil{}
    case Con{e, rest}:
      EDb{i, e} <> at_db(i, rest)

def act.run(+i: Nat, r: R.Reply & (List<&2, R.Cmd> & R.Db), pre: List<&2, R.Db>, post: List<&2, R.Db>) -> R.Reply & (List<&2, Eff> & R.Ds):
  (x, q) = r
  (es, d) = q
  (x, (at_db(i, es), R.Ds{d, pre, post}))

# an act's effect, when the act did what it does (b)
def act.if(b: Bool, e: Eff) -> List<&2, Eff>:
  match b:
    case True{}:
      [e]
    case False{}:
      Nil{}

def act.swap(+a: Nat, +b: Nat, r: Bool & R.Ds) -> R.Reply & (List<&2, Eff> & R.Ds):
  (ok, ds) = r
  (R.r_ok(), (act.if(ok, ESwap{a, b}), ds))

def act.purge(+k: String, +j: Nat, r: Bool & R.Ds) -> R.Reply & (List<&2, Eff> & R.Ds):
  (ok, ds) = r
  (R.r_ok(), (act.if(ok, EDb{j, R.Del{[k]}}), ds))

def act.move(+k: String, +i: Nat, +j: Nat, r: Bool & R.Ds) -> R.Reply & (List<&2, Eff> & R.Ds):
  (+ok, ds) = r
  (R.r_int(Bool.pick(Nat, ok, 1n, 0n)), (act.if(ok, EMove{k, i, j}), ds))

def act.copy(+s: String, +d: String, +i: Nat, +j: Nat, r: Bool & R.Ds) -> R.Reply & (List<&2, Eff> & R.Ds):
  (+ok, ds) = r
  (R.r_int(Bool.pick(Nat, ok, 1n, 0n)), (act.if(ok, ECopy{s, d, i, j}), ds))

# a command of one database run on the focus, with its effects
def act.cmd(+c: R.Cmd, ds: R.Ds) -> R.Reply & (List<&2, Eff> & R.Ds):
  match ds:
    case R.Ds{d, +pre, post}:
      act.run(List.length(&2, R.Db, pre), run(c, d), pre, post)

# an act run with its effect: its reply, its effects, and the databases
# after it, as R.act runs it
def act(a: R.Act, ds: R.Ds) -> R.Reply & (List<&2, Eff> & R.Ds):
  match a ds:
    case R.ARun{+c} x:
      act.cmd(c, x)
    case R.AFocus{+j} x:
      (R.r_ok(), (Nil{}, R.ds.focus(j, x)))
    case R.ASwap{+a, +b} x:
      act.swap(a, b, R.ds.swap(a, b, x))
    case R.APurge{+k, +j} x:
      act.purge(k, j, R.ds.purge(k, j, x))
    case R.AMove{+k, +j} x:
      +y = x
      act.move(k, R.ds.index(y), j, R.ds.move(k, j, y))
    case R.ACopy{+s, +d, +j, rep} x:
      +y = x
      act.copy(s, d, R.ds.index(y), j, R.ds.copy(s, d, j, rep, y))
    case R.ACopyHere{+s, +d, rep} x:
      +y = x
      act.copy(s, d, R.ds.index(y), R.ds.index(y), R.ds.copy(s, d, R.ds.index(y), rep, y))
    case R.AWipe{} x:
      (R.r_ok(), ([EWipe{}], R.ds.wipe(x)))
    case R.ASort{+k, o} x:
      +y = x
      act.cmd(R.sort.write.ds(y, k, o), y)

def acts.put(es: List<&2, Eff>, r: R.Reply & (List<&2, Eff> & R.Ds)) -> List<&2, Eff> & R.Ds:
  (x, q) = r
  (e, ds) = q
  (List.reverse.go(&2, Eff, e, es), ds)

def acts.step(a: R.Act, q: List<&2, Eff> & R.Ds) -> List<&2, Eff> & R.Ds:
  (es, ds) = q
  acts.put(es, act(a, ds))

# acts run with their effects: the effects, newest first, in front of
# those of q, and the databases after the last
def acts(as: List<&2, R.Act>, q: List<&2, Eff> & R.Ds) -> List<&2, Eff> & R.Ds:
  match as:
    case Nil{}:
      q
    case Con{a, rest}:
      acts(rest, acts.step(a, q))

# Entries
# -------

def pair_args(ps: List<&2, R.KVPair>) -> List<&2, String>:
  match ps:
    case Nil{}:
      Nil{}
    case Con{R.KP{k, v}, rest}:
      k <> v <> pair_args(rest)

# the strings of an Upd an effect is: SET with PXAT or KEEPTTL,
# PEXPIREAT, PERSIST, APPEND, SETRANGE (a time is a TmN from 1970, written
# as Nat.show writes it, as an offset is)
def tm.arg(t: R.Tm) -> String:
  match t:
    case R.TmN{at, ms}:
      Nat.show(ms)
    case R.TmB{at, neg, hi, lo}:
      ""

def ttl.args(+k: String, v: String, ttl: R.SetTtl) -> List<&2, String>:
  match ttl:
    case R.TAt{t}:
      ["SET", k, v, "PXAT", tm.arg(t)]
    case R.TKeep{}:
      ["SET", k, v, "KEEPTTL"]
    case R.TNone{}:
      ["SET", k, v]

# a hash's write as the file logs it: HSET of pairs, HDEL of fields, or
# the script of a new hash (R.hnew.script)
def hpairs.args(ps: List<&2, KV.HPair>) -> List<&2, String>:
  match ps:
    case Nil{}:
      Nil{}
    case Con{KV.HP{f, v}, rest}:
      f <> v <> hpairs.args(rest)

def hash.args(+k: String, op: R.HWrite) -> List<&2, String>:
  match op:
    case R.HWSet{ps, mset}:
      "HSET" <> k <> hpairs.args(ps)
    case R.HWDel{fs}:
      "HDEL" <> k <> fs
    case R.HWNew{ps}:
      "EVAL" <> R.hnew.script() <> "1" <> k <> "HSET" <> hpairs.args(ps)
    case _:
      Nil{}

# a list's write as the file logs it: the command as the client sent it,
# or the script of a new list (R.hnew.script)
def push.name(left: Bool, x: Bool) -> String:
  match left x:
    case True{} False{}:
      "LPUSH"
    case False{} False{}:
      "RPUSH"
    case True{} True{}:
      "LPUSHX"
    case False{} True{}:
      "RPUSHX"

def pop.name(left: Bool) -> String:
  match left:
    case True{}:
      "LPOP"
    case False{}:
      "RPOP"

def list.args(+k: String, op: R.LWrite) -> List<&2, String>:
  match op:
    case R.LWPush{left, xs}:
      push.name(left, False{}) <> k <> xs
    case R.LWPushX{left, xs}:
      push.name(left, True{}) <> k <> xs
    case R.LWPop{left}:
      [pop.name(left), k]
    case R.LWPopN{left, c}:
      [pop.name(left), k, c]
    case R.LWSet{i, v}:
      ["LSET", k, i, v]
    case R.LWBefore{p, v}:
      ["LINSERT", k, "BEFORE", p, v]
    case R.LWAfter{p, v}:
      ["LINSERT", k, "AFTER", p, v]
    case R.LWRem{c, v}:
      ["LREM", k, c, v]
    case R.LWTrim{a, b}:
      ["LTRIM", k, a, b]
    case R.LWNew{left, xs}:
      "EVAL" <> R.hnew.script() <> "1" <> k <> push.name(left, False{}) <> xs

# a set's write as the file logs it: SADD or SREM of members, or the
# script of a new set (R.hnew.script); SPOP is logged as the SREM of what
# it took
def mems.args(+k: String, op: R.SWrite) -> List<&2, String>:
  match op:
    case R.SWAdd{ms}:
      "SADD" <> k <> ms
    case R.SWRem{ms}:
      "SREM" <> k <> ms
    case R.SWNew{ms}:
      "EVAL" <> R.hnew.script() <> "1" <> k <> "SADD" <> ms
    case _:
      Nil{}

# a sorted set's write as the file logs it: the command as the client
# sent it (ZINCRBY as ZADD with INCR; ZADD's options in one order), or
# the script of a new sorted set (R.znew.script)
def zopt.w(b: Bool, w: String, rest: List<&2, String>) -> List<&2, String>:
  match b:
    case True{}:
      w <> rest
    case False{}:
      rest

def zopts.on(o: R.ZOpts, rest: List<&2, String>) -> List<&2, String>:
  match o:
    case R.ZOpts{nx, xx, gt, lt, ch, incr}:
      zopt.w(nx, "NX", zopt.w(xx, "XX", zopt.w(gt, "GT", zopt.w(lt, "LT", zopt.w(ch, "CH", zopt.w(incr, "INCR", rest))))))

def zpairs.args(ps: List<&2, R.ZPair>) -> List<&2, String>:
  match ps:
    case Nil{}:
      Nil{}
    case Con{R.ZPair{s, m}, rest}:
      s <> m <> zpairs.args(rest)

def zpop.name(max: Bool) -> String:
  match max:
    case True{}:
      "ZPOPMAX"
    case False{}:
      "ZPOPMIN"

def zset.args(+k: String, op: R.ZWrite) -> List<&2, String>:
  match op:
    case R.ZWAdd{o, ps}:
      "ZADD" <> k <> zopts.on(o, zpairs.args(ps))
    case R.ZWRem{ms}:
      "ZREM" <> k <> ms
    case R.ZWNew{+o, ps}:
      "EVAL" <> R.znew.script() <> "1" <> k <> Nat.show(R.zopts.count(o)) <> zopts.on(o, zpairs.args(ps))
    case R.ZWRemRank{a, b}:
      ["ZREMRANGEBYRANK", k, a, b]
    case R.ZWRemScore{a, b}:
      ["ZREMRANGEBYSCORE", k, a, b]
    case R.ZWRemLex{a, b}:
      ["ZREMRANGEBYLEX", k, a, b]
    case R.ZWPop{max}:
      [zpop.name(max), k]
    case R.ZWPopN{max, c}:
      [zpop.name(max), k, c]

def upd.args(+k: String, op: R.UpdOp) -> List<&2, String>:
  match op:
    case R.USet{v, cond, ttl, name}:
      ttl.args(k, v, ttl)
    case R.UExpire{t, c, name}:
      ["PEXPIREAT", k, tm.arg(t)]
    case R.UPersist{}:
      ["PERSIST", k]
    case R.UAppend{v}:
      ["APPEND", k, v]
    case R.URange{o, s}:
      ["SETRANGE", k, Nat.show(o), s]
    case R.UHash{op}:
      hash.args(k, op)
    case R.UList{op}:
      list.args(k, op)
    case R.UMems{op}:
      mems.args(k, op)
    case R.UZset{op}:
      zset.args(k, op)
    case _:
      Nil{}

# LMOVE as the file logs it, or the script of its New form
def end.word(left: Bool) -> String:
  match left:
    case True{}:
      "LEFT"
    case False{}:
      "RIGHT"

def lmove.args.of(fresh: Bool, s: String, t: String, +e: R.LEnds) -> List<&2, String>:
  match fresh:
    case True{}:
      ["EVAL", R.lmove.script(), "2", s, t, end.word(R.ends.from(e)), end.word(R.ends.to(e))]
    case False{}:
      ["LMOVE", s, t, end.word(R.ends.from(e)), end.word(R.ends.to(e))]

# SMOVE as the file logs it, or the script of its New form
def smove.args.of(fresh: Bool, s: String, d: String, m: String) -> List<&2, String>:
  match fresh:
    case True{}:
      ["EVAL", R.smove.script(), "2", s, d, m]
    case False{}:
      ["SMOVE", s, d, m]

# a logged command as the strings of a request that parses back to it
# (none for a command no effect is: they are never logged)
def args(c: R.Cmd) -> List<&2, String>:
  match c:
    case R.Set{k, v}:
      ["SET", k, v]
    case R.Upd{+k, op}:
      upd.args(k, op)
    case R.Del{ks}:
      "DEL" <> ks
    case R.MSet{ps}:
      "MSET" <> pair_args(ps)
    case R.FlushDb{}:
      ["FLUSHDB"]
    case R.Rename{src, dst, nx}:
      ["RENAME", src, dst]
    case R.LMove{s, t, +e}:
      lmove.args.of(R.ends.fresh(e), s, t, e)
    case R.SMv{s, d, +w}:
      smove.args.of(R.smv.fresh(w), s, d, R.smv.member(w))
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

# A located effect's entries: a command of one database after a SELECT
# of its database when the file has another one selected (sel: the last
# SELECT in the file, else 0, as Redis loads a file from database 0);
# SWAPDB, MOVE (after a SELECT of the database it moves from) and FLUSHALL
# as Redis writes them, and COPY (after a SELECT of the database it copies
# from) always with DB and REPLACE: replayed at time 0, the destination
# may be there where its time had passed when COPY ran
def sel.put(same: Bool, +j: Nat, xs: List<&2, List<&2, String>>) -> List<&2, List<&2, String>>:
  match same:
    case True{}:
      xs
    case False{}:
      ["SELECT", Nat.show(j)] <> xs

def eff.args(+e: Eff, +sel: Nat) -> List<&2, List<&2, String>>:
  match e:
    case EDb{+j, c}:
      sel.put(Nat.is_eq(j, sel), j, [args(c)])
    case ESwap{a, b}:
      [["SWAPDB", Nat.show(a), Nat.show(b)]]
    case EMove{k, +src, dst}:
      sel.put(Nat.is_eq(src, sel), src, [["MOVE", k, Nat.show(dst)]])
    case ECopy{s, d, +from, to}:
      sel.put(Nat.is_eq(from, sel), from, [["COPY", s, d, "DB", Nat.show(to), "REPLACE"]])
    case EWipe{}:
      [["FLUSHALL"]]

# the database the file has selected after an effect's entries
def eff.sel(+e: Eff, +sel: Nat) -> Nat:
  match e:
    case EDb{+j, c}:
      j
    case EMove{k, +src, dst}:
      src
    case ECopy{s, d, +from, to}:
      from
    case _:
      sel

def effs.args(es: List<&2, Eff>, +sel: Nat) -> List<&2, List<&2, String>>:
  match es:
    case Nil{}:
      Nil{}
    case Con{+e, rest}:
      List.append(&2, List<&2, String>, eff.args(e, sel), effs.args(rest, eff.sel(e, sel)))

def effs.sel(es: List<&2, Eff>, +sel: Nat) -> Nat:
  match es:
    case Nil{}:
      sel
    case Con{+e, rest}:
      effs.sel(rest, eff.sel(e, sel))

# The file's entries: an effect, or the effects of a transaction (EXEC's,
# when they are two or more), written between a MULTI and an EXEC as
# Redis writes them, so that a crash that cuts the file inside them
# leaves a transaction the start reverts (below: untx)
type Ent is Data:
  EOne{e: Eff}
  ETx{es: List<&2, Eff>}

def ent.args(+x: Ent, +sel: Nat) -> List<&2, List<&2, String>>:
  match x:
    case EOne{+e}:
      eff.args(e, sel)
    case ETx{+es}:
      ["MULTI"] <> List.append(&2, List<&2, String>, effs.args(es, sel), [["EXEC"]])

def ent.sel(+x: Ent, +sel: Nat) -> Nat:
  match x:
    case EOne{+e}:
      eff.sel(e, sel)
    case ETx{+es}:
      effs.sel(es, sel)

def ents.args(xs: List<&2, Ent>, +sel: Nat) -> List<&2, List<&2, String>>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{+x, rest}:
      List.append(&2, List<&2, String>, ent.args(x, sel), ents.args(rest, ent.sel(x, sel)))

def ents.sel(xs: List<&2, Ent>, +sel: Nat) -> Nat:
  match xs:
    case Nil{}:
      sel
    case Con{+x, rest}:
      ents.sel(rest, ent.sel(x, sel))

# effects each an entry of its own
def ents.of(es: List<&2, Eff>) -> List<&2, Ent>:
  match es:
    case Nil{}:
      Nil{}
    case Con{e, rest}:
      EOne{e} <> ents.of(rest)

# effects (newest first) put before entries (newest first), each an
# entry of its own
def ents.onto(es: List<&2, Eff>, xs: List<&2, Ent>) -> List<&2, Ent>:
  match es:
    case Nil{}:
      xs
    case Con{e, rest}:
      ents.onto(rest, EOne{e} <> xs)

# a transaction's effects, in order, as entries: one entry of them all
# when they are two or more, as Redis wraps them in MULTI and EXEC
def tx.wrap(es: List<&2, Eff>) -> List<&2, Ent>:
  match es:
    case Con{a, Con{b, rest}}:
      [ETx{a <> b <> rest}]
    case Con{a, Nil{}}:
      [EOne{a}]
    case Nil{}:
      Nil{}

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

# a number of a SELECT, SWAPDB or MOVE in a file, as a short number reads
# (R.num14): every one BendKV writes is
def file.num(+s: String) -> Maybe<&2, Nat>:
  R.num14(s, 0n, 0n, False{}, R.nch(s))

def file.focus(m: Maybe<&2, Nat>, c: R.Cmd) -> R.Act:
  match m:
    case Some{j}:
      R.AFocus{j}
    case None{}:
      R.ARun{c}

def file.swap(ma: Maybe<&2, Nat>, mb: Maybe<&2, Nat>, c: R.Cmd) -> R.Act:
  match ma mb:
    case Some{a} Some{b}:
      R.ASwap{a, b}
    case _ _:
      R.ARun{c}

def file.move(k: String, m: Maybe<&2, Nat>, c: R.Cmd) -> R.Act:
  match m:
    case Some{j}:
      R.AMove{k, j}
    case None{}:
      R.ARun{c}

# COPY as Redis writes it, the arguments a client sent: DB and REPLACE in
# any order and case, read word by word as session.bend's copy.go reads
# them (Redis writes only a COPY that ran, so a number that does not read
# is a file BendKV cannot read; that COPY runs as an error)
type FileCopy is Data:
  FcOpt{db: Maybe<&2, Nat>, rep: Bool}
  FcDb{rep: Bool}
  FcBad{}

def file.copy.word(isrep: Bool, isdb: Bool, db: Maybe<&2, Nat>, rep: Bool) -> FileCopy:
  match isrep isdb:
    case True{} _:
      FcOpt{db, True{}}
    case False{} True{}:
      FcDb{rep}
    case False{} False{}:
      FcBad{}

def file.copy.db(m: Maybe<&2, Nat>, rep: Bool) -> FileCopy:
  match m:
    case Some{j}:
      FcOpt{Some{j}, rep}
    case None{}:
      FcBad{}

def file.copy.go(args: List<&2, String>, st: FileCopy) -> FileCopy:
  match args st:
    case _ FcBad{}:
      FcBad{}
    case Nil{} FcOpt{db, rep}:
      FcOpt{db, rep}
    case Nil{} FcDb{rep}:
      FcBad{}
    case Con{+a, rest} FcOpt{db, rep}:
      +up = String.to_upper(a)
      file.copy.go(rest, file.copy.word(String.eq(up, "REPLACE"), String.eq(up, "DB"), db, rep))
    case Con{+a, rest} FcDb{rep}:
      file.copy.go(rest, file.copy.db(file.num(a), rep))

# the act of a COPY read: to the database it names, or within the focus
def file.copy.to(st: FileCopy, s: String, d: String, c: R.Cmd) -> R.Act:
  match st:
    case FcOpt{Some{j}, rep}:
      R.ACopy{s, d, j, rep}
    case FcOpt{None{}, rep}:
      R.ACopyHere{s, d, rep}
    case _:
      R.ARun{c}

def file.copy.any(+c: R.Cmd) -> R.Act:
  match c:
    case R.Own{R.SCopy{Con{s, Con{d, rest}}}}:
      file.copy.to(file.copy.go(rest, FcOpt{None{}, False{}}), s, d, c)
    case _:
      R.ARun{c}

# COPY as BendKV writes it, with DB and REPLACE, read at once (the laws
# read it so); any other COPY as Redis writes it
def file.copy.of(isdb: Bool, isrep: Bool, s: String, d: String, m: Maybe<&2, Nat>, c: R.Cmd) -> R.Act:
  match isdb isrep m:
    case True{} True{} Some{j}:
      R.ACopy{s, d, j, True{}}
    case _ _ _:
      file.copy.any(c)

def file.copy(args: List<&2, String>, c: R.Cmd) -> R.Act:
  match args:
    case Con{s, Con{d, Con{+w, Con{+n, Con{+r, Nil{}}}}}}:
      file.copy.of(String.eq(w, "DB"), String.eq(r, "REPLACE"), s, d, file.num(n), c)
    case _:
      file.copy.any(c)

# a command of a file as an act: SELECT moves the focus, SWAPDB, MOVE,
# COPY and FLUSHALL act on the databases, SORT with STORE (as Redis
# writes it, the command that ran) writes its destination, and any other
# command runs on the focus (a SELECT, SWAPDB, MOVE or COPY whose numbers or options do
# not read too: exec answers it with an error and changes nothing, as
# Redis's load ignores a command that fails)
def file.act(+c: R.Cmd) -> R.Act:
  match c:
    case R.Own{R.SSelect{+s}}:
      file.focus(file.num(s), c)
    case R.Own{R.SSwapDb{+a, +b}}:
      file.swap(file.num(a), file.num(b), c)
    case R.Own{R.SMove{k, +d}}:
      file.move(k, file.num(d), c)
    case R.Own{R.SCopy{+args}}:
      file.copy(args, c)
    case R.Own{R.SFlushAll{}}:
      R.AWipe{}
    case R.Own{R.SSortStore{k, o}}:
      R.ASort{k, o}
    case _:
      R.ARun{c}

def file.acts(cs: List<&2, R.Cmd>) -> List<&2, R.Act>:
  match cs:
    case Nil{}:
      Nil{}
    case Con{+c, rest}:
      file.act(c) <> file.acts(rest)

# the databases the entries leave, run from 1 + n empty ones
def replay(reqs: List<&2, List<&2, String>>, n: Nat) -> R.Ds:
  R.acts(file.acts(parse_all(reqs)), R.ds.empty(n))

# Checking
# --------
# At start the server replays a file only when each entry replays as the
# file means it (checked), and else names the first that does not and
# stops, the file as it was. One that does not is an entry the parser
# refuses (R.Bad, and a session command's R.SBad: an unknown command or
# subcommand, a wrong number of arguments, an argument that does not
# read), a command of a connection or of the server (an R.Own file.act
# leaves as a command, as it leaves a SELECT, SWAPDB, MOVE or COPY whose
# numbers or options do not read), and a SELECT, SWAPDB, MOVE or COPY of
# a database not there: replay answers each with an error and goes on,
# and the databases after it are not those the file describes. Redis
# 7.0.15 stops its load at an unknown command too, and the files it
# writes and BendKV's hold none of these: both log only commands that
# ran, on databases that are there (a start with fewer databases than
# the file names is refused). The replies of the commands that replay
# are not looked at, as Redis does not look at them. MULTI and EXEC,
# which Redis writes around a transaction, a script's effects, and the
# DEL of a key whose time had passed with the write that met it, are
# marks: the commands between them replay one after another; a MULTI
# inside another, an EXEC without one, and a file that ends inside one
# are refused (the start first reverts a transaction the file ends
# inside, as Redis does: untx, below, so that the check meets none).

# The check only reads: its walks borrow the requests (marks, before
# parse_all takes them over) and the acts (before replay runs them), and
# give small values, so that neither list is shared and copied, and the
# text of why an entry is refused is found only once one is.

# what an entry is to the check: MULTI, EXEC, an act that replays as the
# file means it, or one that does not, with its code (act.code)
type Chk is Data:
  ChkMulti{}
  ChkExec{}
  ChkRuns{}
  ChkBad{code: Nat}

# an entry that is the one word MULTI (1) or EXEC (2), in any case, as
# Redis looks a command up (R.is_word); 0 for any other
def mark.of(+w: String) -> Nat:
  Bool.pick(Nat, R.is_word(w, "MULTI"), 1n, Bool.pick(Nat, R.is_word(w, "EXEC"), 2n, 0n))

def mark(+req: List<&2, String>) -> Nat:
  match req:
    case Con{+w, Nil{}}:
      mark.of(w)
    case _:
      0n

# each entry's mark
def marks(+reqs: List<&2, List<&2, String>>) -> List<&2, Nat>:
  match reqs:
    case Nil{}:
      Nil{}
    case Con{+r, rest}:
      mark(r) <> marks(rest)

# A transaction cut short
# -----------------------
# A file that ends inside a transaction (a MULTI with no EXEC after it:
# a crash cut the file while a transaction was written) restores the
# entries before its MULTI, as Redis reverts such a transaction ("Revert
# incomplete MULTI/EXEC transaction") and cuts the file back to before
# it: none of a transaction's commands is applied unless all are. The
# last mark decides: read from the end, an EXEC first (or no mark)
# keeps every entry, a MULTI first keeps those before it (cut.go: the
# entries before it, newest first; m: the mark of the entry just read).
def cut.go(rev: List<&2, List<&2, String>>, m: Nat) -> Maybe<&2, List<&2, List<&2, String>>>:
  match rev m:
    case r 1n:
      Some{r}
    case r 2n:
      None{}
    case Nil{} _:
      None{}
    case Con{+x, rest} _:
      cut.go(rest, mark(x))

def untx.of(m: Maybe<&2, List<&2, List<&2, String>>>, reqs: List<&2, List<&2, String>>) -> List<&2, List<&2, String>>:
  match m:
    case Some{rest}:
      List.reverse(&2, List<&2, String>, rest)
    case None{}:
      reqs

# the entries a file restores: all of them, or those before a
# transaction it ends inside
def untx(+reqs: List<&2, List<&2, String>>) -> List<&2, List<&2, String>>:
  untx.of(cut.go(List.reverse(&2, List<&2, String>, reqs), 0n), reqs)

# the databases the entries a file restores leave, run from 1 + n empty
# ones, and what is left after them: the entries of a transaction cut
# short, then what follows the last whole entry
def restore.of(l: List<&2, List<&2, String>> & String, n: Nat) -> R.Ds & String:
  (+reqs, rest) = l
  +kept = untx(reqs)
  (replay(kept, n), encode(List.drop(&2, List<&2, String>, reqs, List.length(&2, List<&2, String>, kept))) ++ rest)

# the databases a file holds, from 1 + n empty ones, and what is left
# after the entries it restores
def restore(s: String, n: Nat) -> R.Ds & String:
  restore.of(load(s), n)

def db.code(out: Bool) -> Nat:
  Bool.pick(Nat, out, 7n, 0n)

# what an act of a file is, with 1 + n databases there: 0 one that
# replays as the file means it; 1 one the parser refuses; 2 a command of
# a connection or of the server; 3, 4, 5 and 6 a SELECT, SWAPDB, MOVE or
# COPY whose numbers or options do not read; 7 a SELECT, SWAPDB, MOVE or
# COPY of a database not there
def act.code(+a: R.Act, +n: Nat) -> Nat:
  match a:
    case R.ARun{R.Bad{r}}:
      1n
    case R.ARun{R.Own{R.SBad{r}}}:
      1n
    case R.ARun{R.Own{R.SSelect{s}}}:
      3n
    case R.ARun{R.Own{R.SSwapDb{x, y}}}:
      4n
    case R.ARun{R.Own{R.SMove{k, d}}}:
      5n
    case R.ARun{R.Own{R.SCopy{xs}}}:
      6n
    case R.ARun{R.Own{o}}:
      2n
    case R.AFocus{+j}:
      db.code(Nat.is_lt(n, j))
    case R.ASwap{+x, +y}:
      db.code(Bool.or(Nat.is_lt(n, x), Nat.is_lt(n, y)))
    case R.AMove{k, +j}:
      db.code(Nat.is_lt(n, j))
    case R.ACopy{s, d, +j, rep}:
      db.code(Nat.is_lt(n, j))
    case _:
      0n

def entry.chk(m: Nat, c: Nat) -> Chk:
  match m c:
    case 1n _:
      ChkMulti{}
    case 2n _:
      ChkExec{}
    case _ 0n:
      ChkRuns{}
    case _ 1n+k:
      ChkBad{1n+k}

# each entry to the check, from its mark and its act
def chks(ms: List<&2, Nat>, +as: List<&2, R.Act>, +n: Nat) -> List<&2, Chk>:
  match ms as:
    case Con{m, mr} Con{+a, ar}:
      entry.chk(m, act.code(a, n)) <> chks(mr, ar, n)
    case _ _:
      Nil{}

# the first entry that does not replay as the file means it, by its
# number (from 0), and why: its act's code, or 8 for a file that ends
# inside a transaction, 9 a MULTI inside another, 10 an EXEC without
# one; i is the number of the first of ks, open 1 + the number of the
# MULTI whose EXEC is still to come, 0 for none
def check.go(ks: List<&2, Chk>, +i: Nat, open: Nat) -> Maybe<&1, Nat & Nat>:
  match ks open:
    case Nil{} 0n:
      None{}
    case Nil{} 1n+m:
      Some{(m, 8n)}
    case Con{ChkBad{c}, rest} _:
      Some{(i, c)}
    case Con{ChkMulti{}, rest} 0n:
      check.go(rest, 1n+i, 1n+i)
    case Con{ChkMulti{}, rest} 1n+m:
      Some{(i, 9n)}
    case Con{ChkExec{}, rest} 0n:
      Some{(i, 10n)}
    case Con{ChkExec{}, rest} 1n+m:
      check.go(rest, 1n+i, 0n)
    case Con{ChkRuns{}, rest} o:
      check.go(rest, 1n+i, o)

# the first entry of a file, of marks ms and acts as, that does not
# replay as the file means it, with 1 + n databases there
def check(ms: List<&2, Nat>, +as: List<&2, R.Act>, +n: Nat) -> Maybe<&1, Nat & Nat>:
  check.go(chks(ms, as, n), 0n, 0n)

# the parser's error, for an act it refused
def why.parser(a: R.Act) -> String:
  match a:
    case R.ARun{R.Bad{R.RError{m}}}:
      m
    case R.ARun{R.Own{R.SBad{R.RError{m}}}}:
      m
    case _:
      "ERR the parser refuses it"

def why.at(i: Nat, as: List<&2, R.Act>) -> String:
  match i as:
    case 0n Con{a, rest}:
      why.parser(a)
    case 1n+j Con{a, rest}:
      why.at(j, rest)
    case _ Nil{}:
      "ERR the parser refuses it"

# why entry i, of code k, is refused (as, the file's acts)
def why(k: Nat, i: Nat, as: List<&2, R.Act>) -> String:
  match k:
    case 1n:
      why.at(i, as)
    case 2n:
      "ERR a command of a connection or of the server, which no file holds"
    case 3n:
      "ERR SELECT of a database number that does not read"
    case 4n:
      "ERR SWAPDB of a database number that does not read"
    case 5n:
      "ERR MOVE to a database number that does not read"
    case 6n:
      "ERR COPY with a database number or an option that does not read"
    case 7n:
      "ERR DB index is out of range"
    case 8n:
      "ERR MULTI without EXEC: the file ends inside a transaction"
    case 9n:
      "ERR MULTI calls can not be nested"
    case _:
      "ERR EXEC without MULTI"

# A file replayed at the start: the databases it holds, from 1 + n empty
# ones, when each entry replays as the file means it; else the first
# that does not, by its number (from 0), and why
type Replay is Data:
  Replayed{ds: R.Ds}
  Refused{at: Nat, why: String}

def checked.of(m: Maybe<&1, Nat & Nat>, as: List<&2, R.Act>, n: Nat) -> Replay:
  match m:
    case None{}:
      Replayed{R.acts(as, R.ds.empty(n))}
    case Some{p}:
      (+i, k) = p
      Refused{i, why(k, i, as)}

# the start's replay: replay's, when the check refuses no entry
# (LAWS.bend: checked_replay)
def checked(+reqs: List<&2, List<&2, String>>, +n: Nat) -> Replay:
  ms = marks(reqs)
  +as = file.acts(parse_all(reqs))
  checked.of(check(ms, as, n), as, n)

# s from its entry i on, as load reads its entries
def skip(i: Nat, +s: String, m: Maybe<&1, List<&2, String> & String>) -> String:
  match i m:
    case 1n+j Some{p}:
      (x, +rest) = p
      skip(j, rest, entry(rest))
    case _ _:
      s

# the byte of s its entry i starts at (where the server says a refused
# entry is)
def offset(+s: String, i: Nat) -> Nat:
  Nat.sub(String.length(s), String.length(skip(i, s, entry(s))))

# The rewrite
# -----------
# BGREWRITEAOF writes the file again from a snapshot of the databases,
# as Redis 7.0.15's rewriteAppendOnlyFileRio writes a base: for each
# database that holds keys a SELECT of it, then each key as the commands
# that make it again: the SET of a string, the RPUSH of a list's
# elements, the SADD of a set's members, the ZADD of a sorted set's
# scores (as Redis writes a double, %.17g) and members, the HMSET of a
# hash's fields and values, 64 elements or pairs to a command
# (AOF_REWRITE_ITEMS_PER_CMD), and the PEXPIREAT of the time it expires
# at when it does. A key whose time has passed at the snapshot's time is
# left out. The snapshot is a value (the databases at a time), so the
# server writes it a slice at a time (rw.slice: the keys of the buckets a
# scan of a few dozen entries reads, KV.scan, from a cursor), between the
# groups of requests it serves meanwhile.

# a command's words, its name and key first
def rw.cmd(+name: String, +k: String, ws: List<&2, String>) -> List<&2, String>:
  name <> k <> List.reverse(&2, String, ws)

def rw.flush(+name: String, +k: String, cur: List<&2, String>, acc: List<&2, List<&2, String>>) -> List<&2, List<&2, String>>:
  match cur:
    case Nil{}:
      acc
    case Con{w, ws}:
      rw.cmd(name, k, w <> ws) <> acc

# xs as commands name k and w of its words each (cur: the words of the one
# being filled, newest first; left: how many more it takes), newest
# first before acc
def rw.fill(+name: String, +k: String, +w: Nat, xs: List<&2, String>, +left: Nat, cur: List<&2, String>, acc: List<&2, List<&2, String>>) -> List<&2, List<&2, String>>:
  match xs left:
    case Nil{} _:
      rw.flush(name, k, cur, acc)
    case Con{x, rest} 0n:
      rw.fill(name, k, w, rest, Nat.sub(w, 1n), [x], rw.flush(name, k, cur, acc))
    case Con{x, rest} 1n+l:
      rw.fill(name, k, w, rest, l, x <> cur, acc)

def rw.chunks(+name: String, +k: String, +w: Nat, xs: List<&2, String>, acc: List<&2, List<&2, String>>) -> List<&2, List<&2, String>>:
  rw.fill(name, k, w, xs, w, Nil{}, acc)

# a hash's pairs as words: field, value, ...
def rw.hwords(ps: List<&2, KV.HPair>) -> List<&2, String>:
  match ps:
    case Nil{}:
      Nil{}
    case Con{KV.HP{f, v}, rest}:
      f <> v <> rw.hwords(rest)

# a sorted set's elements as words: score, member, ...
def rw.zwords(es: List<&2, KV.ZEl>) -> List<&2, String>:
  match es:
    case Nil{}:
      Nil{}
    case Con{KV.ZEl{m, +d}, rest}:
      F.f64.show(d) <> m <> rw.zwords(rest)

# the commands that make a key's value again, newest first before acc
def rw.val(+k: String, v: KV.Val, acc: List<&2, List<&2, String>>) -> List<&2, List<&2, String>>:
  match v:
    case KV.VStr{s}:
      ["SET", k, s] <> acc
    case KV.VColl{KV.CHash{+h}}:
      rw.chunks("HMSET", k, 128n, rw.hwords(KV.hash.pairs(h)), acc)
    case KV.VColl{KV.CList{+l}}:
      rw.chunks("RPUSH", k, 64n, KV.deq.all(l), acc)
    case KV.VColl{KV.CMems{+m}}:
      rw.chunks("SADD", k, 64n, KV.mems.all(m), acc)
    case KV.VColl{KV.CZset{+z}}:
      rw.chunks("ZADD", k, 128n, rw.zwords(KV.zset.all(z)), acc)

# and the time it expires at, when it does
def rw.exp(+k: String, +e: Nat, acc: List<&2, List<&2, String>>) -> List<&2, List<&2, String>>:
  match e:
    case 0n:
      acc
    case 1n+p:
      ["PEXPIREAT", k, Nat.show(1n+p)] <> acc

def rw.item(+k: String, m: Maybe<&2, KV.Item<KV.Val>>, acc: List<&2, List<&2, String>>) -> List<&2, List<&2, String>>:
  match m:
    case Some{KV.Item{v, +e}}:
      rw.exp(k, e, rw.val(k, v, acc))
    case None{}:
      acc

# the commands of the keys ks of trie t, newest first before acc
def rw.keys(+t: KV.Trie<KV.Val>, ks: List<&2, String>, acc: List<&2, List<&2, String>>) -> List<&2, List<&2, String>>:
  match ks:
    case Nil{}:
      acc
    case Con{+k, rest}:
      rw.keys(t, rest, rw.item(k, KV.entry(KV.Val, t, k), acc))

# A snapshot being written: the databases yet to write (the current one
# first), its number, the bucket its scan goes on from, whether its
# SELECT is written, and the snapshot's time
type Snap is Data:
  Snap{dbs: List<&2, R.Db>, i: Nat, at: Nat, sel: Bool, now: Nat}

# a slice written: its requests, and the snapshot after it (None: all of
# it is written)
type Slice is Data:
  Slice{reqs: List<&2, List<&2, String>>, more: Maybe<&2, Snap>}

def snap.of(+ds: R.Ds) -> Snap:
  Snap{R.ds.list(ds), 0n, 0n, False{}, R.ds.now(ds)}

def rw.trie(+db: R.Db) -> KV.Trie<KV.Val>:
  match db:
    case R.Db{t, n, x, now, rr}:
      t

# the keys a scan found, with the database's SELECT first when it is the
# first of them
def rw.sel(sel: Bool, +i: Nat, +ks: List<&2, String>, acc: List<&2, List<&2, String>>) -> List<&2, List<&2, String>>:
  match sel ks:
    case False{} Con{k, rest}:
      ["SELECT", Nat.show(i)] <> acc
    case _ _:
      acc

def rw.any(+ks: List<&2, String>) -> Bool:
  match ks:
    case Nil{}:
      False{}
    case Con{+k, +rest}:
      True{}

# the requests of the keys ks of database i, in order
def rw.reqs(+db: R.Db, +i: Nat, +sel: Bool, +ks: List<&2, String>) -> List<&2, List<&2, String>>:
  List.reverse(&2, List<&2, String>, rw.keys(rw.trie(db), ks, rw.sel(sel, i, ks, Nil{})))

# the database's last keys: the next one's from its first bucket on
def rw.last(rest: List<&2, R.Db>, +i: Nat, +now: Nat, reqs: List<&2, List<&2, String>>) -> Slice:
  match rest:
    case Nil{}:
      Slice{reqs, None{}}
    case Con{d, ds}:
      Slice{reqs, Some{Snap{d <> ds, 1n+i, 0n, False{}, now}}}

def rw.found(sc: KV.Scan, +db: R.Db, rest: List<&2, R.Db>, +i: Nat, +sel: Bool, +now: Nat) -> Slice:
  match sc:
    case KV.Stop{at, +ks}:
      Slice{rw.reqs(db, i, sel, ks), Some{Snap{db <> rest, i, at, Bool.or(sel, rw.any(ks)), now}}}
    case KV.Scan{w, +ks}:
      rw.last(rest, i, now, rw.reqs(db, i, sel, ks))

# the next slice of a snapshot: the keys of the buckets from its cursor
# on, until a scan has read want entries, or the database's end
def rw.slice(s: Snap, +want: Nat) -> Slice:
  match s:
    case Snap{Nil{}, i, at, sel, now}:
      Slice{Nil{}, None{}}
    case Snap{Con{+db, rest}, +i, +at, +sel, +now}:
      rw.found(KV.scan(KV.Val, rw.trie(db), at, want, now), db, rest, i, sel, now)
