# SPEC.bend: BendKV's commands on the trie alone, at a time now, as
# R.exec runs them on the database record (redis.bend: Db) but without
# the counts the record keeps. The proofs of the laws about what keys hold
# and what commands answer are about this exec; PROOF.bend proves that
# the server's exec answers each command as this one does, DBSIZE but,
# and leaves the trie this one leaves (the bridge), so that those laws
# hold of the server's exec. A command never changes the time.

import Base
import ../src/map.bend as KV
import ../src/redis.bend as R

def mset_pairs(ps: List<&2, R.KVPair>, db: KV.Trie<KV.Val>) -> KV.Trie<KV.Val>:
  match ps:
    case Nil{}:
      db
    case Con{R.KP{k, v}, rest}:
      mset_pairs(rest, KV.set(KV.Val, db, k, KV.VStr{v}))

# INCRBY: the sum (none past a long long) stored with the key's time kept
# (keep: the key was there) or with none
def incr.fit(db: KV.Trie<KV.Val>, +k: String, +h: U32, s: R.LL, keep: Bool) -> R.Reply & KV.Trie<KV.Val>:
  match s:
    case R.LL{+neg, +hi, +lo}:
      +v = R.ll.show(neg, hi, lo)
      (R.RIntS{v}, R.incr.put(keep, db, k, v, h))
    case R.LLBad{}:
      (R.RError{"ERR increment or decrement would overflow"}, db)

def incr.num(db: KV.Trie<KV.Val>, +k: String, +h: U32, by: R.By, cur: R.LL) -> R.Reply & KV.Trie<KV.Val>:
  match cur:
    case R.LL{+neg, +hi, +lo}:
      incr.fit(db, k, h, R.ll.add(neg, hi, lo, by), True{})
    case R.LLBad{}:
      (R.e_int(), db)

def incr.got(db: KV.Trie<KV.Val>, +k: String, +h: U32, by: R.By, old: KV.Got) -> R.Reply & KV.Trie<KV.Val>:
  match old:
    case KV.GStr{s}:
      incr.num(db, k, h, by, R.ll.read(s))
    case KV.GColl{}:
      (R.e_wrongtype(), db)
    case KV.GNone{}:
      incr.fit(db, k, h, R.by.ll(by), False{})

# DEL's reply and the trie without the keys
def del_reply(r: R.Dels) -> R.Reply & KV.Trie<KV.Val>:
  match r:
    case R.Dels{live, gone, gonex, t}:
      (R.r_int(live), t)

# an update's change made to its key
def upd.ch(t: KV.Trie<KV.Val>, +k: String, +h: U32, r: R.Reply, ch: R.Change) -> R.Reply & KV.Trie<KV.Val>:
  match ch:
    case R.CKeep{}:
      (r, t)
    case R.CDel{}:
      (r, KV.del.at(KV.Val, t, k, h))
    case R.CExp{+e}:
      (r, KV.expire.at(KV.Val, t, k, e, h))
    case R.CPut{v, +e}:
      (r, KV.setx.at(KV.Val, t, k, KV.VStr{v}, e, h))
    case R.CKeepT{v}:
      (r, KV.keep.at(KV.Val, t, k, KV.VStr{v}, h))
    case R.CApp{a, v}:
      (r, KV.keep.at(KV.Val, t, k, KV.VStr{v}, h))
    case R.CRange{o, a, v}:
      (r, KV.keep.at(KV.Val, t, k, KV.VStr{v}, h))
    case R.CHash{op, hv}:
      (r, KV.keep.at(KV.Val, t, k, KV.VColl{KV.CHash{hv}}, h))
    case R.CHashNew{ps, hv}:
      (r, KV.setx.at(KV.Val, t, k, KV.VColl{KV.CHash{hv}}, 0n, h))
    case R.CList{op, lv}:
      (r, KV.keep.at(KV.Val, t, k, KV.VColl{KV.CList{lv}}, h))
    case R.CListNew{left, xs, lv}:
      (r, KV.setx.at(KV.Val, t, k, KV.VColl{KV.CList{lv}}, 0n, h))
    case R.CMems{op, sv}:
      (r, KV.keep.at(KV.Val, t, k, KV.VColl{KV.CMems{sv}}, h))
    case R.CMemsNew{ms, sv}:
      (r, KV.setx.at(KV.Val, t, k, KV.VColl{KV.CMems{sv}}, 0n, h))
    case R.CZset{op, zv}:
      (r, KV.keep.at(KV.Val, t, k, KV.VColl{KV.CZset{zv}}, h))
    case R.CZsetNew{o, ps, zv}:
      (r, KV.setx.at(KV.Val, t, k, KV.VColl{KV.CZset{zv}}, 0n, h))
    case R.CRestore{p, v, +e}:
      (r, KV.setx.at(KV.Val, t, k, v, e, h))
    case R.CStream{op, xv}:
      (r, KV.keep.at(KV.Val, t, k, KV.VColl{KV.CStream{xv}}, h))
    case R.CStreamNew{op, xv}:
      (r, KV.setx.at(KV.Val, t, k, KV.VColl{KV.CStream{xv}}, 0n, h))

def upd.put(t: KV.Trie<KV.Val>, +k: String, +h: U32, o: R.Out) -> R.Reply & KV.Trie<KV.Val>:
  match o:
    case R.Out{r, ch}:
      upd.ch(t, k, h, r, ch)

# MSETNX: none set when a key of the pairs is there at now (0), else all
# set as MSET sets them (1)
def msetnx(any: Bool, ps: List<&2, R.KVPair>, db: KV.Trie<KV.Val>) -> R.Reply & KV.Trie<KV.Val>:
  match any:
    case True{}:
      (R.r_int(0n), db)
    case False{}:
      (R.r_int(1n), mset_pairs(ps, db))

# what RENAME finds, from the entries of its keys, ms and md
def ren.pick(ms: Maybe<&2, KV.Item<KV.Val>>, md: Maybe<&2, KV.Item<KV.Val>>, +src: String, +dst: String, nx: Bool, +now: Nat) -> R.Ren:
  R.ren.of(R.ent.live(now, ms), KV.str_eq(src, dst), Bool.and(nx, Maybe.is_some(&2, KV.Item<KV.Val>, R.ent.live(now, md))))

def ren.find(+t: KV.Trie<KV.Val>, +src: String, +dst: String, nx: Bool, +now: Nat) -> R.Ren:
  ren.pick(KV.entry.at(KV.Val, t, src, KV.hash(src)), KV.entry.at(KV.Val, t, dst, KV.hash(dst)), src, dst, nx, now)

# RENAME's reply, and the trie with src's entry moved to dst when it moves
def ren(r: R.Ren, nx: Bool, +src: String, +dst: String, db: KV.Trie<KV.Val>) -> R.Reply & KV.Trie<KV.Val>:
  match r:
    case R.RnNone{}:
      (R.RError{"ERR no such key"}, db)
    case R.RnSame{}:
      (R.ren.ok(nx, 0n), db)
    case R.RnHeld{}:
      (R.r_int(0n), db)
    case R.RnMove{v, +e}:
      (R.ren.ok(nx, 1n), KV.del(KV.Val, KV.setx(KV.Val, db, dst, v, e), src))

# BITOP: the value its sources make set at dst as SET sets it, or dst
# deleted when the value is empty; the reply is the value's length. A
# source that holds a collection makes it WRONGTYPE.
def bitop.t(e: Bool, +v: String, +d: String, db: KV.Trie<KV.Val>) -> KV.Trie<KV.Val>:
  match e:
    case True{}:
      KV.del(KV.Val, db, d)
    case False{}:
      KV.set(KV.Val, db, d, KV.VStr{v})

def bitop(+v: String, +d: String, db: KV.Trie<KV.Val>) -> R.Reply & KV.Trie<KV.Val>:
  (R.r_int(String.length(v)), bitop.t(String.is_empty(v), v, d, db))

def bitop.go(wrong: Bool, +op: R.BitK, srcs: List<&2, String>, +dst: String, db: KV.Trie<KV.Val>, +now: Nat) -> R.Reply & KV.Trie<KV.Val>:
  match wrong:
    case True{}:
      (R.e_wrongtype(), db)
    case False{}:
      +d = db
      bitop(R.bitop.val(op, srcs, now, d), dst, d)

# LMOVE: what it finds, from its keys' entries (dst none for a New
# form); the element popped from src's list and pushed onto dst's
def mv.find(+db: KV.Trie<KV.Val>, +s: String, +t: String, +e: R.LEnds, +now: Nat) -> R.Mv:
  R.mv.of(R.ent.live(now, KV.entry.at(KV.Val, db, s, KV.hash(s))), KV.str_eq(s, t), R.mv.dst.ent(R.ends.fresh(e), R.ent.live(now, KV.entry.at(KV.Val, db, t, KV.hash(t)))))

# src left with the list l: deleted when l is empty
def mv.src(empty: Bool, +k: String, l: KV.Deq, db: KV.Trie<KV.Val>) -> KV.Trie<KV.Val>:
  match empty:
    case True{}:
      KV.del(KV.Val, db, k)
    case False{}:
      KV.keep(KV.Val, db, k, KV.VColl{KV.CList{l}})

def mv.put(+s: String, l: KV.Deq, db: KV.Trie<KV.Val>) -> KV.Trie<KV.Val>:
  +m = l
  mv.src(Nat.is_eq(KV.deq.len(m), 0n), s, m, db)

def mv.go(p: KV.Pop, +e: R.LEnds, +s: String, +t: String, dl: Maybe<&2, KV.Deq>, db: KV.Trie<KV.Val>) -> R.Reply & KV.Trie<KV.Val>:
  match p dl:
    case KV.Pop{+x, l} Some{d}:
      (R.RBulk{x}, KV.keep(KV.Val, mv.put(s, l, db), t, KV.VColl{KV.CList{KV.deq.push(R.ends.to(e), x, d)}}))
    case KV.Pop{+x, l} None{}:
      (R.RBulk{x}, KV.setx(KV.Val, mv.put(s, l, db), t, KV.VColl{KV.CList{KV.deq.push(R.ends.to(e), x, KV.deq.empty())}}, 0n))
    case KV.PopNone{} _:
      (R.RNull{}, db)

def mv.self(p: KV.Pop, +e: R.LEnds, +s: String, db: KV.Trie<KV.Val>) -> R.Reply & KV.Trie<KV.Val>:
  match p:
    case KV.Pop{+x, l}:
      (R.RBulk{x}, KV.keep(KV.Val, db, s, KV.VColl{KV.CList{KV.deq.push(R.ends.to(e), x, l)}}))
    case KV.PopNone{}:
      (R.RNull{}, db)

def mv.do(m: R.Mv, +e: R.LEnds, +s: String, +t: String, db: KV.Trie<KV.Val>) -> R.Reply & KV.Trie<KV.Val>:
  match m:
    case R.MvNone{}:
      (R.RNull{}, db)
    case R.MvWrong{}:
      (R.e_wrongtype(), db)
    case R.MvSelf{l, se}:
      mv.self(KV.deq.pop(R.ends.from(e), l), e, s, db)
    case R.MvOnto{l, se, dl}:
      mv.go(KV.deq.pop(R.ends.from(e), l), e, s, t, Some{dl}, db)
    case R.MvNew{l, se}:
      mv.go(KV.deq.pop(R.ends.from(e), l), e, s, t, None{}, db)

def lmove(db: KV.Trie<KV.Val>, +s: String, +t: String, +e: R.LEnds, +now: Nat) -> R.Reply & KV.Trie<KV.Val>:
  +x = db
  mv.do(mv.find(x, s, t, e, now), e, s, t, x)

# an update of k, as exec runs Upd
def upd.run(db: KV.Trie<KV.Val>, +k: String, op: R.UpdOp, +now: Nat) -> R.Reply & KV.Trie<KV.Val>:
  +d = db
  +h = KV.hash(k)
  +m = KV.entry.at(KV.Val, d, k, h)
  upd.put(d, k, h, R.upd.v(op, now, R.ent.live(now, m)))

# LMPOP: the first of the keys there at now (there: whether the first of
# ks is), and the pop of its list (LWPopN) as Upd runs it
def lmpop.head(+ks: List<&2, String>, +db: KV.Trie<KV.Val>, +now: Nat) -> Bool:
  match ks:
    case Con{+k, +rest}:
      Maybe.is_some(&2, KV.Item<KV.Val>, R.ent.live(now, KV.entry.at(KV.Val, db, k, KV.hash(k))))
    case Nil{}:
      False{}

def lmpop.first(ks: List<&2, String>, there: Bool, +db: KV.Trie<KV.Val>, +now: Nat) -> Maybe<&2, String>:
  match ks there:
    case Con{k, rest} True{}:
      Some{k}
    case Con{k, +rest} False{}:
      +h = lmpop.head(rest, db, now)
      lmpop.first(rest, h, db, now)
    case Nil{} _:
      None{}

def lmpop.out(+k: String, r: R.Reply & KV.Trie<KV.Val>) -> R.Reply & KV.Trie<KV.Val>:
  (x, d) = r
  (R.lmpop.reply(k, x), d)

def lmpop.at(m: Maybe<&2, String>, +left: Bool, c: String, db: KV.Trie<KV.Val>, +now: Nat) -> R.Reply & KV.Trie<KV.Val>:
  match m:
    case Some{+k}:
      lmpop.out(k, upd.run(db, k, R.UList{R.LWPopN{left, c}}, now))
    case None{}:
      (R.RNullA{}, db)

def lmpop(db: KV.Trie<KV.Val>, ks: List<&2, String>, +left: Bool, c: String, +now: Nat) -> R.Reply & KV.Trie<KV.Val>:
  +x = db
  +k = ks
  lmpop.at(lmpop.first(k, lmpop.head(k, x, now), x, now), left, c, x, now)

def reply_of(r: R.Reply & KV.Trie<KV.Val>) -> R.Reply:
  (x, db) = r
  x

def db_of(r: R.Reply & KV.Trie<KV.Val>) -> KV.Trie<KV.Val>:
  (x, db) = r
  db

# SINTERSTORE, SUNIONSTORE, SDIFFSTORE: the members the operation makes
# of the sets at the keys there at now set at dst as the update SWNew
# sets them, or dst deleted as DEL deletes it when there are none; the
# reply counts them. A key of another kind makes it WRONGTYPE.
def sstore.put(+ms: List<&2, String>, +d: String, db: KV.Trie<KV.Val>, +now: Nat) -> R.Reply & KV.Trie<KV.Val>:
  (R.r_int(List.length(&2, String, ms)), db_of(upd.run(db, d, R.UMems{R.SWNew{ms}}, now)))

def sstore.of(xs: List<&2, String>, +d: String, db: KV.Trie<KV.Val>, +now: Nat) -> R.Reply & KV.Trie<KV.Val>:
  match xs:
    case Nil{}:
      (R.r_int(0n), db_of(del_reply(R.del_keys([d], now, db))))
    case Con{x, rest}:
      sstore.put(x <> rest, d, db, now)

def sstore.do(g: R.SGot, op: R.SetK, ks: List<&2, String>, +d: String, db: KV.Trie<KV.Val>, +now: Nat) -> R.Reply & KV.Trie<KV.Val>:
  match g:
    case R.SGot{ss}:
      sstore.of(R.sop.members(op, ks, ss), d, db, now)
    case R.SGotWrong{}:
      (R.e_wrongtype(), db)

def sstore(db: KV.Trie<KV.Val>, op: R.SetK, +d: String, ks: List<&2, String>, +now: Nat) -> R.Reply & KV.Trie<KV.Val>:
  +x = db
  +k = ks
  sstore.do(R.sets.at(k, now, x), op, k, d, x, now)

# SMOVE: what it finds, from its keys' entries there at now (dst none for
# a New form); then the member taken out of src and added to dst, by the
# updates SREM and SADD (or SWNew) make
def smv.find(+db: KV.Trie<KV.Val>, +s: String, +d: String, +w: R.SMem, +now: Nat) -> R.Smv:
  R.smv.find(R.ent.live(now, KV.entry.at(KV.Val, db, s, KV.hash(s))), R.mv.dst.ent(R.smv.fresh(w), R.ent.live(now, KV.entry.at(KV.Val, db, d, KV.hash(d)))), KV.str_eq(s, d), R.smv.member(w))

def smove.do(f: R.Smv, +s: String, +d: String, +w: R.SMem, db: KV.Trie<KV.Val>, +now: Nat) -> R.Reply & KV.Trie<KV.Val>:
  match f:
    case R.SmvZero{}:
      (R.r_int(0n), db)
    case R.SmvWrong{}:
      (R.e_wrongtype(), db)
    case R.SmvSame{had}:
      (R.r_int(Bool.pick(Nat, had, 1n, 0n)), db)
    case R.SmvGo{}:
      (R.r_int(1n), db_of(upd.run(db_of(upd.run(db, s, R.UMems{R.SWRem{[R.smv.member(w)]}}, now)), d, R.UMems{R.smv.add(w)}, now)))

def smove(db: KV.Trie<KV.Val>, +s: String, +d: String, +w: R.SMem, +now: Nat) -> R.Reply & KV.Trie<KV.Val>:
  +x = db
  smove.do(smv.find(x, s, d, w, now), s, d, w, x, now)

# ZUNIONSTORE, ZINTERSTORE, ZDIFFSTORE: the elements the operation makes
# of the sorted sets (and sets) at the keys there at now (as
# R.zop.stored orders them) set at dst as the update ZWNew sets them, or
# dst deleted as DEL deletes it when there are none; the reply counts
# them. A key of another kind makes it WRONGTYPE, options that do not
# read their error. ZRANGESTORE: the same, of the range of the sorted set
# at src, as R.zq.stored gives it.
def zstore.put(+n: Nat, ps: List<&2, R.ZPair>, +d: String, db: KV.Trie<KV.Val>, +now: Nat) -> R.Reply & KV.Trie<KV.Val>:
  (R.r_int(n), db_of(upd.run(db, d, R.UZset{R.ZWNew{R.zopts.none(), ps}}, now)))

def zstore.of(+xs: List<&2, KV.ZEl>, +d: String, db: KV.Trie<KV.Val>, +now: Nat) -> R.Reply & KV.Trie<KV.Val>:
  match xs:
    case Nil{}:
      (R.r_int(0n), db_of(del_reply(R.del_keys([d], now, db))))
    case Con{x, rest}:
      zstore.put(List.length(&2, KV.ZEl, xs), R.zstore.pairs(xs), d, db, now)

def zstore.ok(bad: Maybe<&2, R.Reply>, +op: R.ZSetK, ss: List<&2, R.ZSrc>, +d: String, db: KV.Trie<KV.Val>, +now: Nat) -> R.Reply & KV.Trie<KV.Val>:
  match bad:
    case Some{r}:
      (r, db)
    case None{}:
      zstore.of(R.zop.stored(op, ss), d, db, now)

def zstore.do(g: R.ZGot, +op: R.ZSetK, +d: String, db: KV.Trie<KV.Val>, +now: Nat) -> R.Reply & KV.Trie<KV.Val>:
  match g:
    case R.ZGot{ss}:
      zstore.ok(R.zop.bad(op), op, ss, d, db, now)
    case R.ZGotWrong{}:
      (R.e_wrongtype(), db)

def zstore(db: KV.Trie<KV.Val>, +op: R.ZSetK, +d: String, ks: List<&2, String>, +now: Nat) -> R.Reply & KV.Trie<KV.Val>:
  +x = db
  zstore.do(R.zsrcs.at(ks, now, x), op, d, x, now)

def zrs.of(m: Maybe<&2, KV.Val>, q: R.ZQ, +d: String, db: KV.Trie<KV.Val>, +now: Nat) -> R.Reply & KV.Trie<KV.Val>:
  match m:
    case None{}:
      zstore.of(Nil{}, d, db, now)
    case Some{KV.VColl{KV.CZset{+z}}}:
      zstore.of(R.zq.stored(q, z), d, db, now)
    case Some{v}:
      (R.e_wrongtype(), db)

def zrangestore(db: KV.Trie<KV.Val>, +d: String, +s: String, q: R.ZQ, +now: Nat) -> R.Reply & KV.Trie<KV.Val>:
  +x = db
  zrs.of(KV.read(KV.Val, x, s, now), q, d, x, now)

# ZMPOP: as LMPOP, from the first of its keys there at now, by the update
# ZWPopN
def zmpop.out(+k: String, r: R.Reply & KV.Trie<KV.Val>) -> R.Reply & KV.Trie<KV.Val>:
  (x, d) = r
  (R.zmpop.reply(k, x), d)

def zmpop.at(m: Maybe<&2, String>, +max: Bool, c: String, db: KV.Trie<KV.Val>, +now: Nat) -> R.Reply & KV.Trie<KV.Val>:
  match m:
    case Some{+k}:
      zmpop.out(k, upd.run(db, k, R.UZset{R.ZWPopN{max, c}}, now))
    case None{}:
      (R.RNullA{}, db)

def zmpop(db: KV.Trie<KV.Val>, ks: List<&2, String>, +max: Bool, c: String, +now: Nat) -> R.Reply & KV.Trie<KV.Val>:
  +x = db
  +k = ks
  zmpop.at(lmpop.first(k, lmpop.head(k, x, now), x, now), max, c, x, now)

def exec(cmd: R.Cmd, db: KV.Trie<KV.Val>, +now: Nat) -> R.Reply & KV.Trie<KV.Val>:
  match cmd:
    case R.Ping{}:
      (R.RStatus{"PONG"}, db)
    case R.Echo{m}:
      (R.RBulk{m}, db)
    case R.Get{+k}:
      +d = db
      (R.r_getv(KV.get_copy(d, k, now)), d)
    case R.Set{+k, v}:
      (R.r_ok(), KV.set(KV.Val, db, k, KV.VStr{v}))
    case R.Del{ks}:
      del_reply(R.del_keys(ks, now, db))
    case R.Exists{ks}:
      +d = db
      (R.r_int(R.exists_keys(ks, now, d)), d)
    case R.IncrBy{+k, by}:
      +d = db
      +h = KV.hash(k)
      incr.got(d, k, h, by, KV.get_copy.at(d, k, h, now))
    case R.MGet{ks}:
      +d = db
      (R.RArray{R.mget_keys(ks, now, d)}, d)
    case R.MSet{ps}:
      (R.r_ok(), mset_pairs(ps, db))
    case R.DbSize{}:
      +d = db
      (R.r_int(KV.size(KV.Val, d)), d)
    case R.FlushDb{}:
      (R.r_ok(), KV.empty(KV.Val))
    case R.Keys{p}:
      +d = db
      (R.RArray{R.glob_filter(p, KV.keys(KV.Val, d, now))}, d)
    case R.Scan{args}:
      +d = db
      (R.scan.reply(R.scan.args(args), d, now), d)
    case R.Peek{+k, c}:
      +d = db
      (R.peek.v(c, now, R.ent.live(now, KV.entry.at(KV.Val, d, k, KV.hash(k)))), d)
    case R.Upd{+k, op}:
      +d = db
      +h = KV.hash(k)
      +m = KV.entry.at(KV.Val, d, k, h)
      upd.put(d, k, h, R.upd.v(op, now, R.ent.live(now, m)))
    case R.MSetNx{+ps}:
      +d = db
      msetnx(R.pairs.live(ps, now, d), ps, d)
    case R.Rename{+src, +dst, +nx}:
      +d = db
      ren(ren.find(d, src, dst, nx, now), nx, src, dst, d)
    case R.BitOp{+op, +dst, srcs}:
      +d = db
      +ss = srcs
      bitop.go(R.bitop.wrong(ss, now, d), op, ss, dst, d, now)
    case R.Own{o}:
      (R.RError{"ERR a command of the connection, not of the database"}, db)
    case R.Bad{r}:
      (r, db)
    case R.LMove{+s, +t, +e}:
      lmove(db, s, t, e, now)
    case R.LMPop{ks, +left, c}:
      lmpop(db, ks, left, c, now)
    case R.SOp{op, +ks}:
      +d = db
      (R.sop.reply(op, ks, R.sets.at(ks, now, d)), d)
    case R.SStore{op, +d, ks}:
      sstore(db, op, d, ks, now)
    case R.SMv{+s, +d, +w}:
      smove(db, s, d, w, now)
    case R.ZOp{+op, +ks}:
      +d = db
      (R.zop.reply(op, R.zsrcs.at(ks, now, d)), d)
    case R.ZStore{+op, +d, ks}:
      zstore(db, op, d, ks, now)
    case R.ZRangeStore{+d, +s, q}:
      zrangestore(db, d, s, q, now)
    case R.ZMPop{ks, +max, c}:
      zmpop(db, ks, max, c, now)
    case R.Sort{+k, o}:
      +d = db
      (R.sort.reply(R.sort.run(d, now, k, o, False{})), d)

# a batch's replies, and the trie after it
def replies(r: List<&2, R.Reply> & KV.Trie<KV.Val>) -> List<&2, R.Reply>:
  (rs, db) = r
  rs

def final(r: List<&2, R.Reply> & KV.Trie<KV.Val>) -> KV.Trie<KV.Val>:
  (rs, db) = r
  db

def exec_all.put(rs: List<&2, R.Reply>, r: R.Reply & KV.Trie<KV.Val>) -> List<&2, R.Reply> & KV.Trie<KV.Val>:
  (x, db) = r
  (x <> rs, db)

def exec_all.step(c: R.Cmd, +now: Nat, st: List<&2, R.Reply> & KV.Trie<KV.Val>) -> List<&2, R.Reply> & KV.Trie<KV.Val>:
  (rs, db) = st
  exec_all.put(rs, exec(c, db, now))

def exec_all.go(cmds: List<&2, R.Cmd>, +now: Nat, st: List<&2, R.Reply> & KV.Trie<KV.Val>) -> List<&2, R.Reply> & KV.Trie<KV.Val>:
  match cmds:
    case Nil{}:
      st
    case Con{c, rest}:
      exec_all.go(rest, now, exec_all.step(c, now, st))

def exec_all.fin(st: List<&2, R.Reply> & KV.Trie<KV.Val>) -> List<&2, R.Reply> & KV.Trie<KV.Val>:
  (rs, db) = st
  (List.reverse(&2, R.Reply, rs), db)

def exec_all.cons(r: R.Reply, rest: List<&2, R.Reply> & KV.Trie<KV.Val>) -> List<&2, R.Reply> & KV.Trie<KV.Val>:
  (rs, db) = rest
  (r <> rs, db)

def exec_all(cmds: List<&2, R.Cmd>, db: KV.Trie<KV.Val>, +now: Nat) -> List<&2, R.Reply> & KV.Trie<KV.Val>:
  exec_all.fin(exec_all.go(cmds, now, (Nil{}, db)))
