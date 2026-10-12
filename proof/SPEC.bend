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

# INCRBY: the sum stored with the key's time kept (keep: the key was there)
# or with none
def incr.fit(db: KV.Trie<KV.Val>, +k: String, +h: U32, +n: R.Int, ok: Bool, keep: Bool) -> R.Reply & KV.Trie<KV.Val>:
  match ok:
    case True{}:
      (R.RInt{n}, R.incr.put(keep, db, k, R.int_show(n), h))
    case False{}:
      (R.RError{"ERR increment or decrement would overflow"}, db)

def incr.num(db: KV.Trie<KV.Val>, +k: String, +h: U32, by: R.Int, cur: Maybe<&2, R.Int>) -> R.Reply & KV.Trie<KV.Val>:
  match cur:
    case Some{i}:
      +s = R.int_add(i, by)
      incr.fit(db, k, h, s, R.int_fits(s), True{})
    case None{}:
      (R.e_int(), db)

def incr.got(db: KV.Trie<KV.Val>, +k: String, +h: U32, +by: R.Int, old: KV.Got) -> R.Reply & KV.Trie<KV.Val>:
  match old:
    case KV.GStr{s}:
      incr.num(db, k, h, by, R.int_read(s))
    case KV.GColl{}:
      (R.e_wrongtype(), db)
    case KV.GNone{}:
      incr.fit(db, k, h, by, R.int_fits(by), False{})

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

def reply_of(r: R.Reply & KV.Trie<KV.Val>) -> R.Reply:
  (x, db) = r
  x

def db_of(r: R.Reply & KV.Trie<KV.Val>) -> KV.Trie<KV.Val>:
  (x, db) = r
  db

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
