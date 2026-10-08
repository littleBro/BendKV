# shard.bend: a batch of commands cut among n shards, and the replies of
# the parts put back together in the batch's order.
#
# Shard s of n holds the keys whose hash has a lowest hex digit d with
# d * n / 16 = s. That is the digit the trie's root branches on, so the
# shards together are one trie, each child of the root taken from the
# shard that owns its digit. Each shard runs its commands with exec_all
# (batch.bend's exec_batch), as the whole database did, on a core of its
# own. A connection cuts each batch into a part per shard (split), hands
# the parts to the shards all at once (Chan.send_all, so every shard
# takes the batches of all the connections in one same order) and puts
# the replies back in the batch's order (merge).
#
# A command on one key goes whole to its key's shard. A command on
# several keys goes in parts, one command per key: a GET for each key of
# MGET, a DEL of one key for each of DEL, an EXISTS of one key for each
# of EXISTS, a SET for each pair of MSET. DBSIZE, KEYS and FLUSHALL go in
# parts too, one command for each digit of the root, on that digit's
# subtrie, to the shard that holds it: its size (SizeAt), its keys that
# match (KeysAt), its clearing (FlushAt). A shard runs the whole part of
# a batch at once, so a command in parts still runs as one step. PING,
# ECHO and a bad command go to no shard, as the connection answers them.

import Base
import ./map.bend as KV
import ./redis.bend as R

# one command for a shard, and the hash of its key (0 for none): the
# shard's batch hints come from these
type Part is Data:
  Part{c: R.Cmd, h: U32}

# how a command's reply comes from its parts' replies: its own reply
# (RHere), one shard's reply (ROne), or one reply from each shard of a
# list, in its order: the values of GETs as an array (RItems), the sum
# of counts (RSum), OK (ROk), the arrays one after another (RCat)
type Route is Data:
  RHere{r: R.Reply}
  ROne{s: Nat}
  RItems{ss: List<&2, Nat>}
  RSum{ss: List<&2, Nat>}
  ROk{ss: List<&2, Nat>}
  RCat{ss: List<&2, Nat>}

# a command of one key for each key of a command on several
type Each is Data:
  EGet{}
  EDel{}
  EExists{}

# a command on one digit's subtrie for each digit, for DBSIZE, KEYS and
# FLUSHALL
type Fan is Data:
  FSize{}
  FKeys{p: String}
  FFlush{}

# what each shard has left to answer, shard by shard
def Store() -> Data:
  List<&2, List<&2, R.Reply>>

# Shards
# ------

# the shard among n that holds the root's subtrie under digit x: digit d
# goes to shard d * n / 16
def owner(+n: U32, x: KV.Hex) -> Nat:
  U32.to_nat(U32.shrn(U32.mul(KV.hex_val(x), n), 4n))

# the shard among n of a key's hash: the owner of its lowest hex digit
def shard_of(+n: U32, +h: U32) -> Nat:
  owner(n, KV.hex(h))

# Split
# -----
# A batch is walked back to front, each command's parts pushed in front
# of the parts of the commands after it, so each shard's list ends up in
# the batch's order. The lists grow as shards get parts: shard s's list is
# the s-th, and one past the end is empty, so no part is ever dropped,
# whatever shard a key goes to (shard_of keeps every key below n).

def push_at(s: Nat, x: Part, ps: List<&2, List<&2, Part>>) -> List<&2, List<&2, Part>>:
  match s ps:
    case 0n Con{p, rest}:
      Con{x <> p, rest}
    case 0n Nil{}:
      Con{[x], Nil{}}
    case 1n+t Con{p, rest}:
      Con{p, push_at(t, x, rest)}
    case 1n+t Nil{}:
      Con{Nil{}, push_at(t, x, Nil{})}

def one.at(+s: Nat, +h: U32, c: R.Cmd, ps: List<&2, List<&2, Part>>) -> Route & List<&2, List<&2, Part>>:
  (ROne{s}, push_at(s, Part{c, h}, ps))

# c, on the key with hash h, to its shard
def one(+n: U32, +h: U32, c: R.Cmd, ps: List<&2, List<&2, Part>>) -> Route & List<&2, List<&2, Part>>:
  one.at(shard_of(n, h), h, c, ps)

def each.cmd(e: Each, k: String) -> R.Cmd:
  match e:
    case EGet{}:
      R.Get{k}
    case EDel{}:
      R.Del{[k]}
    case EExists{}:
      R.Exists{[k]}

def each.at(+s: Nat, +h: U32, c: R.Cmd, r: List<&2, Nat> & List<&2, List<&2, Part>>) -> List<&2, Nat> & List<&2, List<&2, Part>>:
  (ss, ps) = r
  (s <> ss, push_at(s, Part{c, h}, ps))

def each.put(+n: U32, +e: Each, +k: String, r: List<&2, Nat> & List<&2, List<&2, Part>>) -> List<&2, Nat> & List<&2, List<&2, Part>>:
  +h = KV.hash(k)
  each.at(shard_of(n, h), h, each.cmd(e, k), r)

# a command of kind e for each of the keys ks, to their shards: the
# shards in the keys' order
def each(+n: U32, +e: Each, ks: List<&2, String>, ps: List<&2, List<&2, Part>>) -> List<&2, Nat> & List<&2, List<&2, Part>>:
  match ks:
    case Nil{}:
      (Nil{}, ps)
    case Con{k, rest}:
      each.put(n, e, k, each(n, e, rest, ps))

def pairs.put(+n: U32, +k: String, v: String, r: List<&2, Nat> & List<&2, List<&2, Part>>) -> List<&2, Nat> & List<&2, List<&2, Part>>:
  +h = KV.hash(k)
  each.at(shard_of(n, h), h, R.Set{k, v}, r)

# a SET for each pair, to their keys' shards
def pairs(+n: U32, kvs: List<&2, R.KVPair>, ps: List<&2, List<&2, Part>>) -> List<&2, Nat> & List<&2, List<&2, Part>>:
  match kvs:
    case Nil{}:
      (Nil{}, ps)
    case Con{R.KP{k, v}, rest}:
      pairs.put(n, k, v, pairs(n, rest, ps))

def fan.cmd(f: Fan, x: KV.Hex) -> R.Cmd:
  match f:
    case FSize{}:
      R.SizeAt{x}
    case FKeys{p}:
      R.KeysAt{p, x}
    case FFlush{}:
      R.FlushAt{x}

def fan.put(+n: U32, +f: Fan, +x: KV.Hex, r: List<&2, Nat> & List<&2, List<&2, Part>>) -> List<&2, Nat> & List<&2, List<&2, Part>>:
  each.at(owner(n, x), 0, fan.cmd(f, x), r)

# a command of kind f for each digit of xs, to the digits' shards: the
# shards in the digits' order
def fan(+n: U32, +f: Fan, xs: List<&2, KV.Hex>, ps: List<&2, List<&2, Part>>) -> List<&2, Nat> & List<&2, List<&2, Part>>:
  match xs:
    case Nil{}:
      (Nil{}, ps)
    case Con{x, rest}:
      fan.put(n, f, x, fan(n, f, rest, ps))

def as_items(r: List<&2, Nat> & List<&2, List<&2, Part>>) -> Route & List<&2, List<&2, Part>>:
  (ss, ps) = r
  (RItems{ss}, ps)

def as_sum(r: List<&2, Nat> & List<&2, List<&2, Part>>) -> Route & List<&2, List<&2, Part>>:
  (ss, ps) = r
  (RSum{ss}, ps)

def as_ok(r: List<&2, Nat> & List<&2, List<&2, Part>>) -> Route & List<&2, List<&2, Part>>:
  (ss, ps) = r
  (ROk{ss}, ps)

def as_cat(r: List<&2, Nat> & List<&2, List<&2, Part>>) -> Route & List<&2, List<&2, Part>>:
  (ss, ps) = r
  (RCat{ss}, ps)

# c's route, and its parts pushed on the shards' lists
def route(+n: U32, c: R.Cmd, ps: List<&2, List<&2, Part>>) -> Route & List<&2, List<&2, Part>>:
  match c:
    case R.Ping{}:
      (RHere{R.RStatus{"PONG"}}, ps)
    case R.Echo{m}:
      (RHere{R.RBulk{m}}, ps)
    case R.Bad{r}:
      (RHere{r}, ps)
    case R.Get{+k}:
      one(n, KV.hash(k), R.Get{k}, ps)
    case R.Set{+k, v}:
      one(n, KV.hash(k), R.Set{k, v}, ps)
    case R.SetNX{+k, v}:
      one(n, KV.hash(k), R.SetNX{k, v}, ps)
    case R.GetSet{+k, v}:
      one(n, KV.hash(k), R.GetSet{k, v}, ps)
    case R.IncrBy{+k, by}:
      one(n, KV.hash(k), R.IncrBy{k, by}, ps)
    case R.Append{+k, v}:
      one(n, KV.hash(k), R.Append{k, v}, ps)
    case R.Strlen{+k}:
      one(n, KV.hash(k), R.Strlen{k}, ps)
    case R.MGet{ks}:
      as_items(each(n, EGet{}, ks, ps))
    case R.Del{ks}:
      as_sum(each(n, EDel{}, ks, ps))
    case R.Exists{ks}:
      as_sum(each(n, EExists{}, ks, ps))
    case R.MSet{kvs}:
      as_ok(pairs(n, kvs, ps))
    case R.DbSize{}:
      as_sum(fan(n, FSize{}, KV.digits(), ps))
    case R.FlushAll{}:
      as_ok(fan(n, FFlush{}, KV.digits(), ps))
    case R.Keys{p}:
      as_cat(fan(n, FKeys{p}, KV.digits(), ps))
    case R.SizeAt{+x}:
      one.at(owner(n, x), 0, R.SizeAt{x}, ps)
    case R.KeysAt{p, +x}:
      one.at(owner(n, x), 0, R.KeysAt{p, x}, ps)
    case R.FlushAt{+x}:
      one.at(owner(n, x), 0, R.FlushAt{x}, ps)

def split.cons(rs: List<&2, Route>, x: Route & List<&2, List<&2, Part>>) -> List<&2, Route> & List<&2, List<&2, Part>>:
  (rt, ps) = x
  (rt <> rs, ps)

def split.put(+n: U32, c: R.Cmd, r: List<&2, Route> & List<&2, List<&2, Part>>) -> List<&2, Route> & List<&2, List<&2, Part>>:
  (rs, ps) = r
  split.cons(rs, route(n, c, ps))

# a batch cut among n shards: each command's route, and each shard's part
# of the batch, in order
def split(+n: U32, cmds: List<&2, R.Cmd>) -> List<&2, Route> & List<&2, List<&2, Part>>:
  match cmds:
    case Nil{}:
      (Nil{}, Nil{})
    case Con{c, rest}:
      split.put(n, c, split(n, rest))

# Merge
# -----

def pop.back(x: List<&2, R.Reply>, r: R.Reply & Store()) -> R.Reply & Store():
  (y, rest) = r
  (y, x <> rest)

# shard s's next reply, and what is left
def pop(s: Nat, st: Store()) -> R.Reply & Store():
  match s st:
    case 0n Con{Con{r, rs}, rest}:
      (r, rs <> rest)
    case 1n+t Con{x, rest}:
      pop.back(x, pop(t, rest))
    case _ other:
      (R.RNull{}, other)

def item_of(r: R.Reply) -> R.Item:
  match r:
    case R.RBulk{s}:
      R.IBulk{s}
    case _:
      R.INull{}

def count_of(r: R.Reply) -> Nat:
  match r:
    case R.RInt{R.IPos{k}}:
      k
    case _:
      0n

def array_of(r: R.Reply) -> List<&2, R.Item>:
  match r:
    case R.RArray{xs}:
      xs
    case _:
      Nil{}

def items.put(acc: List<&2, R.Item>, x: R.Reply & Store()) -> List<&2, R.Item> & Store():
  (r, st) = x
  (item_of(r) <> acc, st)

def items.step(s: Nat, st: List<&2, R.Item> & Store()) -> List<&2, R.Item> & Store():
  (acc, store) = st
  items.put(acc, pop(s, store))

def items.go(ss: List<&2, Nat>, st: List<&2, R.Item> & Store()) -> List<&2, R.Item> & Store():
  match ss:
    case Nil{}:
      st
    case Con{s, rest}:
      items.go(rest, items.step(s, st))

def items.fin(st: List<&2, R.Item> & Store()) -> R.Reply & Store():
  (acc, store) = st
  (R.RArray{List.reverse(&2, R.Item, acc)}, store)

def sum.put(acc: Nat, x: R.Reply & Store()) -> Nat & Store():
  (r, st) = x
  (Nat.add(acc, count_of(r)), st)

def sum.step(s: Nat, st: Nat & Store()) -> Nat & Store():
  (acc, store) = st
  sum.put(acc, pop(s, store))

def sum.go(ss: List<&2, Nat>, st: Nat & Store()) -> Nat & Store():
  match ss:
    case Nil{}:
      st
    case Con{s, rest}:
      sum.go(rest, sum.step(s, st))

def sum.fin(st: Nat & Store()) -> R.Reply & Store():
  (acc, store) = st
  (R.r_int(acc), store)

def ok.drop(x: R.Reply & Store()) -> Store():
  (r, st) = x
  st

def ok.go(ss: List<&2, Nat>, st: Store()) -> Store():
  match ss:
    case Nil{}:
      st
    case Con{s, rest}:
      ok.go(rest, ok.drop(pop(s, st)))

# the items of xs in reverse in front of acc
def cat.rev(xs: List<&2, R.Item>, acc: List<&2, R.Item>) -> List<&2, R.Item>:
  match xs:
    case Nil{}:
      acc
    case Con{x, rest}:
      cat.rev(rest, x <> acc)

def cat.put(acc: List<&2, R.Item>, x: R.Reply & Store()) -> List<&2, R.Item> & Store():
  (r, st) = x
  (cat.rev(array_of(r), acc), st)

def cat.step(s: Nat, st: List<&2, R.Item> & Store()) -> List<&2, R.Item> & Store():
  (acc, store) = st
  cat.put(acc, pop(s, store))

def cat.go(ss: List<&2, Nat>, st: List<&2, R.Item> & Store()) -> List<&2, R.Item> & Store():
  match ss:
    case Nil{}:
      st
    case Con{s, rest}:
      cat.go(rest, cat.step(s, st))

# a command's reply from its route and the shards' replies
def answer(rt: Route, st: Store()) -> R.Reply & Store():
  match rt:
    case RHere{r}:
      (r, st)
    case ROne{s}:
      pop(s, st)
    case RItems{ss}:
      items.fin(items.go(ss, (Nil{}, st)))
    case RSum{ss}:
      sum.fin(sum.go(ss, (0n, st)))
    case ROk{ss}:
      (R.r_ok(), ok.go(ss, st))
    case RCat{ss}:
      items.fin(cat.go(ss, (Nil{}, st)))

def merge.put(rs: List<&2, R.Reply>, x: R.Reply & Store()) -> List<&2, R.Reply> & Store():
  (r, st) = x
  (r <> rs, st)

def merge.step(rt: Route, st: List<&2, R.Reply> & Store()) -> List<&2, R.Reply> & Store():
  (rs, store) = st
  merge.put(rs, answer(rt, store))

def merge.go(routes: List<&2, Route>, st: List<&2, R.Reply> & Store()) -> List<&2, R.Reply> & Store():
  match routes:
    case Nil{}:
      st
    case Con{rt, rest}:
      merge.go(rest, merge.step(rt, st))

def merge.fin(st: List<&2, R.Reply> & Store()) -> List<&2, R.Reply>:
  (rs, store) = st
  List.reverse(&2, R.Reply, rs)

# the batch's replies, in order, from its routes and the replies of each
# shard's part
def merge(routes: List<&2, Route>, st: Store()) -> List<&2, R.Reply>:
  merge.fin(merge.go(routes, (Nil{}, st)))

# Parts
# -----

def unzip.put(x: Part, r: List<&2, R.Cmd> & List<&2, U32>) -> List<&2, R.Cmd> & List<&2, U32>:
  match x:
    case Part{c, h}:
      (cs, hs) = r
      (c <> cs, h <> hs)

# a part's commands, and their hashes
def unzip(ps: List<&2, Part>) -> List<&2, R.Cmd> & List<&2, U32>:
  match ps:
    case Nil{}:
      (Nil{}, Nil{})
    case Con{p, rest}:
      unzip.put(p, unzip(rest))
