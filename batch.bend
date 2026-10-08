# batch.bend: a batch of commands run with hints for the processor, its
# keys hashed once. The server runs each batch here (exec_batch) instead of
# with exec_all, given hashes that fit its commands (the hashes of their
# keys), and LAWS.bend (batch_hints) shows that nothing changes: the
# replies and the database after the batch are those of exec_all.

import Base
import ./map.bend as KV
import ./redis.bend as R

# Before a batch of two commands or more runs, the keys of its commands
# are looked up ahead of time, one level of the trie at a time for all of
# them, each step only starting to load the next level (KV.touch.node,
# KV.touch.entry): the cache misses of different keys overlap, where a
# lookup alone waits for one miss after another. Nothing here changes a
# value; the batch then runs as before, and finds its paths in the cache.
# The hashes are those the connection parsed its requests with (a Fit
# each, below), or that a shard's part came with (shard.bend), and the
# batch runs with them (R.exec_all.at), so exec does not hash its key again.

# Commands with their hashes
# --------------------------
# A hash fits a command when it is the hash of the key of a command on one
# key, which runs with it (R.exec.at); any hash fits the rest, which hash
# their keys themselves. LAWS.bend (exec_at, batch_hints) runs a batch with
# hashes that fit its commands.
def fits(c: R.Cmd, h: U32) -> Data:
  match c:
    case R.Get{k}:
      {h == KV.hash(k) : U32}
    case R.Set{k, v}:
      {h == KV.hash(k) : U32}
    case R.SetNX{k, v}:
      {h == KV.hash(k) : U32}
    case R.GetSet{k, v}:
      {h == KV.hash(k) : U32}
    case R.IncrBy{k, by}:
      {h == KV.hash(k) : U32}
    case R.Append{k, v}:
      {h == KV.hash(k) : U32}
    case R.Strlen{k}:
      {h == KV.hash(k) : U32}
    case _:
      Unit

# a parsed request: its command, the hash it runs with, and why the hash
# fits it. resp.bend builds each Fit where it parses the request, so the
# type checker checks every place a hash is chosen; at run time the proof
# is a constant (Unit{} or {==}), and only a command parsed by the
# general path (id_fit) computes it
type Fit is Data:
  Fit{cmd: R.Cmd, hash: U32, ok: fits(cmd, hash)}

# The parser keeps a batch's requests newest first (resp.bend: Batch):
# putting each one before those that came after it, in one pass, puts
# them in order.

# the commands of parsed requests, newest first, put in order before cs
def fit_cmds(fs: List<&2, Fit>, cs: List<&2, R.Cmd>) -> List<&2, R.Cmd>:
  match fs:
    case Nil{}:
      cs
    case Con{Fit{c, h, ok}, rest}:
      fit_cmds(rest, c <> cs)

# the commands and the hashes of parsed requests, newest first, put in
# order before cs and hs, in one pass
def fit_unzip(fs: List<&2, Fit>, cs: List<&2, R.Cmd>, hs: List<&2, U32>) -> List<&2, R.Cmd> & List<&2, U32>:
  match fs:
    case Nil{}:
      (cs, hs)
    case Con{Fit{c, h, ok}, rest}:
      fit_unzip(rest, c <> cs, h <> hs)

# the hash of a request's first argument after its name: the key of every
# command on keys (a hint that goes unused for the rest; 0 for none)
def args_hash(args: List<&2, String>) -> U32:
  match args:
    case Con{key, rest}:
      KV.hash(key)
    case Nil{}:
      0

# Why the first argument's hash fits the command R.parse_id makes of a
# request, by the parser's cases: each command on one key takes its key
# from the first argument. The proofs are only ever erased.

def incrby_fit(-k: String, m: Maybe<&2, R.Int>) -> fits(R.parse_incrby(k, m), KV.hash(k)):
  match m:
    case Some{n}:
      {==}
    case None{}:
      Unit{}

def decrby_fit(-k: String, m: Maybe<&2, R.Int>) -> fits(R.parse_decrby(k, m), KV.hash(k)):
  match m:
    case Some{n}:
      {==}
    case None{}:
      Unit{}

def mset_fit(x: Maybe<&2, List<&2, R.KVPair>>, -h: U32) -> fits(R.parse_mset(x), h):
  match x:
    case Some{ps}:
      match ps:
        case Nil{}:
          Unit{}
        case Con{q, qs}:
          Unit{}
    case None{}:
      Unit{}

def id_fit(id: Nat, -n: String, args: List<&2, String>) -> fits(R.parse_id(id, n, args), args_hash(args)):
  match id:
    case 0n:
      Unit{}
    case 1n:
      match args:
        case Nil{}:
          Unit{}
        case Con{x, Nil{}}:
          Unit{}
        case Con{x, Con{y, ys}}:
          Unit{}
    case 2n:
      match args:
        case Nil{}:
          Unit{}
        case Con{x, Nil{}}:
          Unit{}
        case Con{x, Con{y, ys}}:
          Unit{}
    case 3n:
      match args:
        case Nil{}:
          Unit{}
        case Con{k, Nil{}}:
          {==}
        case Con{k, Con{x, xs}}:
          Unit{}
    case 4n:
      match args:
        case Nil{}:
          Unit{}
        case Con{k, Nil{}}:
          Unit{}
        case Con{k, Con{v, Nil{}}}:
          {==}
        case Con{k, Con{v, Con{o, os}}}:
          Unit{}
    case 5n:
      match args:
        case Nil{}:
          Unit{}
        case Con{k, Nil{}}:
          Unit{}
        case Con{k, Con{v, Nil{}}}:
          {==}
        case Con{k, Con{v, Con{o, os}}}:
          Unit{}
    case 6n:
      match args:
        case Nil{}:
          Unit{}
        case Con{k, Nil{}}:
          Unit{}
        case Con{k, Con{v, Nil{}}}:
          {==}
        case Con{k, Con{v, Con{o, os}}}:
          Unit{}
    case 7n:
      match args:
        case Nil{}:
          Unit{}
        case Con{k, ks}:
          Unit{}
    case 8n:
      match args:
        case Nil{}:
          Unit{}
        case Con{k, ks}:
          Unit{}
    case 9n:
      match args:
        case Nil{}:
          Unit{}
        case Con{k, ks}:
          Unit{}
    case 10n:
      match args:
        case Nil{}:
          Unit{}
        case Con{k, Nil{}}:
          {==}
        case Con{k, Con{x, xs}}:
          Unit{}
    case 11n:
      match args:
        case Nil{}:
          Unit{}
        case Con{k, Nil{}}:
          {==}
        case Con{k, Con{x, xs}}:
          Unit{}
    case 12n:
      match args:
        case Nil{}:
          Unit{}
        case Con{k, Nil{}}:
          Unit{}
        case Con{k, Con{x, Nil{}}}:
          incrby_fit(k, R.int_read(x))
        case Con{k, Con{x, Con{y, ys}}}:
          Unit{}
    case 13n:
      match args:
        case Nil{}:
          Unit{}
        case Con{k, Nil{}}:
          Unit{}
        case Con{k, Con{x, Nil{}}}:
          decrby_fit(k, R.int_read(x))
        case Con{k, Con{x, Con{y, ys}}}:
          Unit{}
    case 14n:
      match args:
        case Nil{}:
          Unit{}
        case Con{k, Nil{}}:
          Unit{}
        case Con{k, Con{v, Nil{}}}:
          {==}
        case Con{k, Con{v, Con{o, os}}}:
          Unit{}
    case 15n:
      match args:
        case Nil{}:
          Unit{}
        case Con{k, Nil{}}:
          {==}
        case Con{k, Con{x, xs}}:
          Unit{}
    case 16n:
      match args:
        case Nil{}:
          Unit{}
        case Con{k, ks}:
          Unit{}
    case 17n:
      mset_fit(R.pairs(args), args_hash(args))
    case 18n:
      match args:
        case Nil{}:
          Unit{}
        case Con{k, ks}:
          Unit{}
    case 19n:
      Unit{}
    case 20n:
      Unit{}
    case 21n:
      match args:
        case Nil{}:
          Unit{}
        case Con{x, Nil{}}:
          Unit{}
        case Con{x, Con{y, ys}}:
          Unit{}
    case 22n:
      Unit{}
    case 23n:
      Unit{}
    case 24n:
      Unit{}
    case 25n+q:
      Unit{}

# whether there are two hashes or more: one has nothing to overlap with
def many(hs: List<&2, U32>) -> Bool:
  match hs:
    case Con{a, Con{b, rest}}:
      True{}
    case _:
      False{}

def touch_nodes(+hs: List<&2, U32>, +db: KV.Trie<String>, +d: Nat, acc: U32) -> U32:
  match hs:
    case Nil{}:
      acc
    case Con{+h, +rest}:
      touch_nodes(rest, db, d, KV.touch.node(String, db, h, d, acc))

def touch_entries(+hs: List<&2, U32>, +db: KV.Trie<String>, acc: U32) -> U32:
  match hs:
    case Nil{}:
      acc
    case Con{+h, +rest}:
      touch_entries(rest, db, KV.touch.entry(String, db, h, acc))

# the hints for a batch: the nodes at depth 4 (the top four levels stay in
# the cache), then the buckets, then their first keys and values
def touch_batch(hs: List<&2, U32>, +db: KV.Trie<String>) -> U32:
  +h = hs
  touch_entries(h, db, touch_nodes(h, db, 5n, touch_nodes(h, db, 4n, 0)))

# the hints of a batch of two commands or more
def touch_if(many: Bool, hs: List<&2, U32>, +db: KV.Trie<String>) -> U32:
  match many:
    case True{}:
      touch_batch(hs, db)
    case False{}:
      0

# the batch run once the hints are done: u is their result, and both arms
# run the batch alike, so the hints come first and change nothing
def exec_hinted(u: Bool, cmds: List<&2, R.Cmd>, hs: List<&2, U32>, db: KV.Trie<String>) -> List<&2, R.Reply> & KV.Trie<String>:
  match u:
    case True{}:
      R.exec_all.at(cmds, hs, db)
    case False{}:
      R.exec_all.at(cmds, hs, db)

def exec_batch(cmds: List<&2, R.Cmd>, hs: List<&2, U32>, db: KV.Trie<String>) -> List<&2, R.Reply> & KV.Trie<String>:
  +d = db
  +h = hs
  exec_hinted(U32.is_eq(touch_if(many(h), h, d), 0), cmds, h, d)

