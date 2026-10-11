# SPEC.bend: BendKV's commands on the trie alone, as exec ran them before
# the database became a record that counts its keys (redis.bend: Db). The
# proofs of the laws about what keys read and what commands answer are
# about this exec; PROOF.bend proves that the server's exec answers each
# command as this one does, DBSIZE but, and leaves the trie this one
# leaves (bridge_go, bt), so that those laws hold of the server's exec.

import Base
import ../src/map.bend as KV
import ../src/redis.bend as R

def setnx.if(db: KV.Trie<String>, +k: String, v: String, +h: U32, had: Bool) -> R.Reply & KV.Trie<String>:
  match had:
    case True{}:
      (R.r_int(0n), db)
    case False{}:
      (R.r_int(1n), KV.set.at(String, db, k, v, h))

def mset_pairs(ps: List<&2, R.KVPair>, db: KV.Trie<String>) -> KV.Trie<String>:
  match ps:
    case Nil{}:
      db
    case Con{R.KP{k, v}, rest}:
      mset_pairs(rest, KV.set(String, db, k, v))

def incr.fit(db: KV.Trie<String>, +k: String, +h: U32, +n: R.Int, ok: Bool) -> R.Reply & KV.Trie<String>:
  match ok:
    case True{}:
      (R.RInt{n}, KV.set.at(String, db, k, R.int_show(n), h))
    case False{}:
      (R.RError{"ERR increment or decrement would overflow"}, db)

def incr.got(db: KV.Trie<String>, +k: String, +h: U32, by: R.Int, cur: Maybe<&2, R.Int>) -> R.Reply & KV.Trie<String>:
  match cur:
    case Some{x}:
      +n = R.int_add(x, by)
      incr.fit(db, k, h, n, R.int_fits(n))
    case None{}:
      (R.e_int(), db)

def incr.old(m: Maybe<&2, String>) -> Maybe<&2, R.Int>:
  match m:
    case Some{s}:
      R.int_read(s)
    case None{}:
      Some{R.IPos{0n}}

def del_reply(r: Nat & KV.Trie<String>) -> R.Reply & KV.Trie<String>:
  (n, db) = r
  (R.r_int(n), db)

def reply_of(r: R.Reply & KV.Trie<String>) -> R.Reply:
  (x, db) = r
  x

def db_of(r: R.Reply & KV.Trie<String>) -> KV.Trie<String>:
  (x, db) = r
  db

def exec(cmd: R.Cmd, db: KV.Trie<String>) -> R.Reply & KV.Trie<String>:
  match cmd:
    case R.Ping{}:
      (R.RStatus{"PONG"}, db)
    case R.Echo{m}:
      (R.RBulk{m}, db)
    case R.Get{+k}:
      +d = db
      (R.r_get(KV.get_copy(d, k)), d)
    case R.Set{+k, v}:
      (R.r_ok(), KV.set(String, db, k, v))
    case R.SetNX{+k, v}:
      +d = db
      +h = KV.hash(k)
      setnx.if(d, k, v, h, Maybe.is_some(&2, String, KV.get.at(String, d, k, h)))
    case R.GetSet{+k, v}:
      +d = db
      +h = KV.hash(k)
      (R.r_get(KV.get.at(String, d, k, h)), KV.set.at(String, d, k, v, h))
    case R.Del{ks}:
      del_reply(R.del_keys(ks, db))
    case R.Exists{ks}:
      +d = db
      (R.r_int(R.exists_keys(ks, d)), d)
    case R.IncrBy{+k, by}:
      +d = db
      +h = KV.hash(k)
      incr.got(d, k, h, by, incr.old(KV.get.at(String, d, k, h)))
    case R.Append{+k, v}:
      +d = db
      +h = KV.hash(k)
      +s = R.append_to(KV.get.at(String, d, k, h), v)
      (R.r_int(String.length(s)), KV.set.at(String, d, k, s, h))
    case R.Strlen{+k}:
      +d = db
      (R.r_int(R.strlen_of(KV.get(String, d, k))), d)
    case R.MGet{ks}:
      +d = db
      (R.RArray{R.mget_keys(ks, d)}, d)
    case R.MSet{ps}:
      (R.r_ok(), mset_pairs(ps, db))
    case R.DbSize{}:
      +d = db
      (R.r_int(KV.size(String, d)), d)
    case R.FlushAll{}:
      (R.r_ok(), KV.empty(String))
    case R.Keys{p}:
      +d = db
      (R.RArray{R.glob_filter(p, KV.keys(String, d))}, d)
    case R.Scan{args}:
      +d = db
      (R.scan.reply(R.scan.args(args), d), d)
    case R.Peek{+k, c}:
      +d = db
      (R.peek(c, KV.get(String, d, k)), d)
    case R.Own{o}:
      (R.RError{"ERR a command of the connection, not of the database"}, db)
    case R.Bad{r}:
      (r, db)

# a batch's replies, and the trie after it
def replies(r: List<&2, R.Reply> & KV.Trie<String>) -> List<&2, R.Reply>:
  (rs, db) = r
  rs

def final(r: List<&2, R.Reply> & KV.Trie<String>) -> KV.Trie<String>:
  (rs, db) = r
  db

def exec_all.put(rs: List<&2, R.Reply>, r: R.Reply & KV.Trie<String>) -> List<&2, R.Reply> & KV.Trie<String>:
  (x, db) = r
  (x <> rs, db)

def exec_all.step(c: R.Cmd, st: List<&2, R.Reply> & KV.Trie<String>) -> List<&2, R.Reply> & KV.Trie<String>:
  (rs, db) = st
  exec_all.put(rs, exec(c, db))

def exec_all.go(cmds: List<&2, R.Cmd>, st: List<&2, R.Reply> & KV.Trie<String>) -> List<&2, R.Reply> & KV.Trie<String>:
  match cmds:
    case Nil{}:
      st
    case Con{c, rest}:
      exec_all.go(rest, exec_all.step(c, st))

def exec_all.fin(st: List<&2, R.Reply> & KV.Trie<String>) -> List<&2, R.Reply> & KV.Trie<String>:
  (rs, db) = st
  (List.reverse(&2, R.Reply, rs), db)

def exec_all.cons(r: R.Reply, rest: List<&2, R.Reply> & KV.Trie<String>) -> List<&2, R.Reply> & KV.Trie<String>:
  (rs, db) = rest
  (r <> rs, db)

def exec_all(cmds: List<&2, R.Cmd>, db: KV.Trie<String>) -> List<&2, R.Reply> & KV.Trie<String>:
  exec_all.fin(exec_all.go(cmds, (Nil{}, db)))
