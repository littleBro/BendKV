# wire.bend: the shards' answers in bytes. A shard's actor encodes the
# reply of each command of its part (RESP, resp.bend) itself, so a value
# leaves its shard as bytes, not as a String of the shard's trie that the
# connection would read and then let go of; the connection merges the
# answers in the batch's order, step for step as shard.bend's merge does
# with replies, into each command's reply in bytes, which go out together
# (server.bend). The requests still cross as commands (shard.bend's
# split): a command holds its value, which a shard stores without reading
# it. LAWS.bend (merge_bytes, shard_bytes) proves that the bytes are the
# replies shard.bend's merge gives, encoded, so the sharded server sends
# the very bytes the single one does.

import Base
import ./redis.bend as R
import ./resp.bend as P
import ./shard.bend as S

# one command's answer: a bulk reply's bytes (a value, which may become an
# item of an array: MGET's), any other reply's bytes, or an integer or the
# items of an array, which a merge may add up (DEL, EXISTS) or join (KEYS)
type Out is Data:
  OBulk{s: String}
  OBytes{s: String}
  OInt{i: R.Int}
  OItems{xs: List<&2, R.Item>}

def out_of(r: R.Reply) -> Out:
  match r:
    case R.RBulk{s}:
      OBulk{P.encode(R.RBulk{s})}
    case R.RInt{i}:
      OInt{i}
    case R.RArray{xs}:
      OItems{xs}
    case other:
      OBytes{P.encode(other)}

# each command's answer, in order
def outs(rs: List<&2, R.Reply>) -> List<&2, Out>:
  match rs:
    case Nil{}:
      Nil{}
    case Con{r, rest}:
      out_of(r) <> outs(rest)

# what each shard has left to answer, shard by shard
def Store() -> Data:
  List<&2, List<&2, Out>>

# the answers of shard.bend's store, shard by shard (the server collects
# each shard's outs from its actor)
def store_of(st: S.Store()) -> Store():
  match st:
    case Nil{}:
      Nil{}
    case Con{rs, rest}:
      outs(rs) <> store_of(rest)

def bytes_of(o: Out) -> String:
  match o:
    case OBulk{s}:
      s
    case OBytes{s}:
      s
    case OInt{i}:
      P.encode(R.RInt{i})
    case OItems{xs}:
      P.encode(R.RArray{xs})

# an answer as an item of an array: a bulk's bytes, else a nil, as
# S.item_of makes a reply an item
def item_bytes(o: Out) -> String:
  match o:
    case OBulk{s}:
      s
    case _:
      "$-1\r\n"

def count_of(o: Out) -> Nat:
  match o:
    case OInt{R.IPos{k}}:
      k
    case _:
      0n

def items_of(o: Out) -> List<&2, R.Item>:
  match o:
    case OItems{xs}:
      xs
    case _:
      Nil{}

# each reply encoded, in order
def encodes(rs: List<&2, R.Reply>) -> List<&2, String>:
  match rs:
    case Nil{}:
      Nil{}
    case Con{r, rest}:
      P.encode(r) <> encodes(rest)

# Merge
# -----
# shard.bend's merge, step for step, on answers in bytes: each command's
# reply comes out as one String.

def pop.back(x: List<&2, Out>, r: Out & Store()) -> Out & Store():
  (y, rest) = r
  (y, x <> rest)

# shard s's next answer, and what is left
def pop(s: Nat, st: Store()) -> Out & Store():
  match s st:
    case 0n Con{Con{o, os}, rest}:
      (o, os <> rest)
    case 1n+t Con{x, rest}:
      pop.back(x, pop(t, rest))
    case _ other:
      (out_of(R.RNull{}), other)

def one.fin(x: Out & Store()) -> String & Store():
  (o, st) = x
  (bytes_of(o), st)

def items.put(acc: List<&2, String>, x: Out & Store()) -> List<&2, String> & Store():
  (o, st) = x
  (item_bytes(o) <> acc, st)

def items.step(s: Nat, st: List<&2, String> & Store()) -> List<&2, String> & Store():
  (acc, store) = st
  items.put(acc, pop(s, store))

def items.go(ss: List<&2, Nat>, st: List<&2, String> & Store()) -> List<&2, String> & Store():
  match ss:
    case Nil{}:
      st
    case Con{s, rest}:
      items.go(rest, items.step(s, st))

# an array of items, in bytes: its header, then the items
def items.bytes(+xs: List<&2, String>) -> String:
  "*" ++ Nat.show(List.length(&2, String, xs)) ++ P.crlf() ++ String.concat(xs)

def items.fin(st: List<&2, String> & Store()) -> String & Store():
  (acc, store) = st
  (items.bytes(List.reverse(&2, String, acc)), store)

def sum.put(acc: Nat, x: Out & Store()) -> Nat & Store():
  (o, st) = x
  (Nat.add(acc, count_of(o)), st)

def sum.step(s: Nat, st: Nat & Store()) -> Nat & Store():
  (acc, store) = st
  sum.put(acc, pop(s, store))

def sum.go(ss: List<&2, Nat>, st: Nat & Store()) -> Nat & Store():
  match ss:
    case Nil{}:
      st
    case Con{s, rest}:
      sum.go(rest, sum.step(s, st))

def sum.fin(st: Nat & Store()) -> String & Store():
  (n, store) = st
  (P.encode(R.r_int(n)), store)

def ok.drop(x: Out & Store()) -> Store():
  (o, st) = x
  st

def ok.go(ss: List<&2, Nat>, st: Store()) -> Store():
  match ss:
    case Nil{}:
      st
    case Con{s, rest}:
      ok.go(rest, ok.drop(pop(s, st)))

def cat.put(acc: List<&2, R.Item>, x: Out & Store()) -> List<&2, R.Item> & Store():
  (o, st) = x
  (S.cat.rev(items_of(o), acc), st)

def cat.step(s: Nat, st: List<&2, R.Item> & Store()) -> List<&2, R.Item> & Store():
  (acc, store) = st
  cat.put(acc, pop(s, store))

def cat.go(ss: List<&2, Nat>, st: List<&2, R.Item> & Store()) -> List<&2, R.Item> & Store():
  match ss:
    case Nil{}:
      st
    case Con{s, rest}:
      cat.go(rest, cat.step(s, st))

def cat.fin(st: List<&2, R.Item> & Store()) -> String & Store():
  (xs, store) = st
  (P.encode(R.RArray{List.reverse(&2, R.Item, xs)}), store)

# a command's reply in bytes, from its route and the shards' answers
def answer(rt: S.Route, st: Store()) -> String & Store():
  match rt:
    case S.RHere{r}:
      (P.encode(r), st)
    case S.ROne{s}:
      one.fin(pop(s, st))
    case S.RItems{ss}:
      items.fin(items.go(ss, (Nil{}, st)))
    case S.RSum{ss}:
      sum.fin(sum.go(ss, (0n, st)))
    case S.ROk{ss}:
      (P.encode(R.r_ok()), ok.go(ss, st))
    case S.RCat{ss}:
      cat.fin(cat.go(ss, (Nil{}, st)))

def merge.put(acc: List<&2, String>, x: String & Store()) -> List<&2, String> & Store():
  (b, st) = x
  (b <> acc, st)

def merge.step(rt: S.Route, st: List<&2, String> & Store()) -> List<&2, String> & Store():
  (acc, store) = st
  merge.put(acc, answer(rt, store))

def merge.go(routes: List<&2, S.Route>, st: List<&2, String> & Store()) -> List<&2, String> & Store():
  match routes:
    case Nil{}:
      st
    case Con{rt, rest}:
      merge.go(rest, merge.step(rt, st))

def merge.fin(st: List<&2, String> & Store()) -> List<&2, String>:
  (acc, store) = st
  List.reverse(&2, String, acc)

# the batch's replies in bytes, a String for each command, in order, from
# its routes and the answers of each shard's part
def merge(routes: List<&2, S.Route>, st: Store()) -> List<&2, String>:
  merge.fin(merge.go(routes, (Nil{}, st)))
