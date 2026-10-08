# bench_map.bend: the map alone over 100k keys, the keys of each phase in a
# pseudo-random order prepared ahead: a walk of the key list (what each
# phase pays besides the map), 1M GETs, 1M SETs of present keys, 1M
# GET+SETs with the hash once (as INCR does); milliseconds by IO.now
import Base
import ../map.bend as KV

def pad12(+s: String) -> String:
  String.repeat("0", Nat.sub(12n, String.length(s))) ++ s

def key(i: Nat) -> String:
  "key:" ++ pad12(Nat.show(i))

def fill(n: Nat, db: KV.Trie<String>) -> KV.Trie<String>:
  match n:
    case 0n:
      db
    case 1n++p:
      fill(p, KV.set(String, db, key(p), "xxx"))

def next(+x: Nat) -> Nat:
  Nat.mod(Nat.mul(x, 48271n), 2147483647n)

def keys(n: Nat, +x: Nat, acc: List<&2, String>) -> List<&2, String>:
  match n:
    case 0n:
      acc
    case 1n++j:
      keys(j, next(x), Con{key(Nat.mod(Nat.div(x, 16n), 100000n)), acc})

def gets(ks: List<&2, String>, +db: KV.Trie<String>, acc: Nat) -> Nat:
  match ks:
    case Nil{}:
      acc
    case Con{k, rest}:
      gets(rest, db, Nat.add(acc, Bool.pick(Nat, Maybe.is_some(&2, String, KV.get(String, db, k)), 1n, 0n)))

def sets(ks: List<&2, String>, db: KV.Trie<String>) -> KV.Trie<String>:
  match ks:
    case Nil{}:
      db
    case Con{k, rest}:
      sets(rest, KV.set(String, db, k, "yyy"))

def val_of(m: Maybe<&2, String>) -> String:
  match m:
    case Some{s}:
      "zzz"
    case None{}:
      "aaa"

def upd(+k: String, +h: U32, db: KV.Trie<String>) -> KV.Trie<String>:
  +d = db
  KV.set.at(String, d, k, val_of(KV.get.at(String, d, k, h)), h)

def upds(ks: List<&2, String>, db: KV.Trie<String>) -> KV.Trie<String>:
  match ks:
    case Nil{}:
      db
    case Con{+k, rest}:
      upds(rest, upd(k, KV.hash(k), db))

def ms(name: String, t0: Nat, t1: Nat, n: Nat) -> IO(Unit):
  IO.print(name ++ Nat.show(Nat.sub(t1, t0)) ++ " ms (" ++ Nat.show(n) ++ ")")

def main() -> IO(Unit):
  do IO<Unit>:
    +db0 : KV.Trie<String> = fill(100000n, KV.empty(String))
    +ks0 : List<&2, String> = keys(1000000n, 5n, Nil{})
    +ta : Nat <- IO.now()
    n0 : Nat = List.length(&2, String, ks0)
    +tb : Nat <- IO.now()
    ms("len    : ", ta, tb, n0)
    ks1 : List<&2, String> = keys(1000000n, 7n, Nil{})
    +t0 : Nat <- IO.now()
    n1 : Nat = gets(ks1, db0, 0n)
    +t1 : Nat <- IO.now()
    ms("get    : ", t0, t1, n1)
    ks2 : List<&2, String> = keys(1000000n, 11n, Nil{})
    +t2 : Nat <- IO.now()
    +db1 : KV.Trie<String> = sets(ks2, db0)
    +t3 : Nat <- IO.now()
    ms("set    : ", t2, t3, Bool.pick(Nat, KV.has(String, db1, key(5n)), 1n, 0n))
    ks3 : List<&2, String> = keys(1000000n, 13n, Nil{})
    +t4 : Nat <- IO.now()
    +db2 : KV.Trie<String> = upds(ks3, db1)
    +t5 : Nat <- IO.now()
    ms("getset : ", t4, t5, Bool.pick(Nat, KV.has(String, db2, key(6n)), 1n, 0n))
