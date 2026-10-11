# bench_core.bend: times the pure core in-process, without sockets: the
# map alone, then the server's whole path from request bytes to reply
# bytes, on batches of 16 pipelined requests.
#   bend bench/bench_core.bend -o build/bench_core && ./build/bench_core
import Base
import ../src/map.bend as KV
import ../src/redis.bend as R
import ../src/resp.bend as P
import ../src/batch.bend as B

def key(i: Nat) -> String:
  "key:" ++ Nat.show(i)

def fill(n: Nat, db: KV.Trie<String>) -> KV.Trie<String>:
  match n:
    case 0n:
      db
    case 1n++p:
      fill(p, KV.set(String, db, key(p), "xxx"))

def reads(n: Nat, +db: KV.Trie<String>, acc: Nat) -> Nat:
  match n:
    case 0n:
      acc
    case 1n++p:
      reads(p, db, Nat.add(acc, Bool.pick(Nat, KV.has(String, db, key(p)), 1n, 0n)))

def set_req(+k: String) -> String:
  "*3\r\n$3\r\nSET\r\n$" ++ Nat.show(String.length(k)) ++ "\r\n" ++ k ++ "\r\n$3\r\nxxx\r\n"

def get_req(+k: String) -> String:
  "*2\r\n$3\r\nGET\r\n$" ++ Nat.show(String.length(k)) ++ "\r\n" ++ k ++ "\r\n"

# 16 requests for keys base*16 .. base*16+15, as one buffer
def batch16.go(i: Nat, +base: Nat, +get: Bool, acc: String) -> String:
  match i:
    case 0n:
      acc
    case 1n++j:
      +k = key(Nat.add(Nat.mul(base, 16n), j))
      batch16.go(j, base, get, Bool.pick(String, get, get_req(k), set_req(k)) ++ acc)

def batch16(+base: Nat, get: Bool) -> String:
  batch16.go(16n, base, get, "")

def batch_cmds(b: P.Batch) -> List<&2, R.Cmd>:
  match b:
    case P.Batch{rs, k, rest, err, need}:
      B.cmds_of(rs, Nil{})

# what the server does with one read: bytes in, bytes out, db threaded
def serve.out(r: List<&2, R.Reply> & KV.Trie<String>, acc: Nat) -> Nat & KV.Trie<String>:
  (rs, db) = r
  (Nat.add(acc, String.length(P.encode_all(rs))), db)

def serve(bytes: String, db: KV.Trie<String>, acc: Nat) -> Nat & KV.Trie<String>:
  serve.out(R.exec_all(batch_cmds(P.parse(bytes)), db), acc)

def serve_all.step(+j: Nat, +get: Bool, st: Nat & KV.Trie<String>) -> Nat & KV.Trie<String>:
  (acc, db) = st
  serve(batch16(j, get), db, acc)

def serve_all.go(i: Nat, +get: Bool, st: Nat & KV.Trie<String>) -> Nat & KV.Trie<String>:
  match i:
    case 0n:
      st
    case 1n++j:
      serve_all.go(j, get, serve_all.step(j, get, st))

def build_only(i: Nat, +get: Bool, acc: Nat) -> Nat:
  match i:
    case 0n:
      acc
    case 1n++j:
      build_only(j, get, Nat.add(acc, String.length(batch16(j, get))))

def n_reqs(b: P.Batch) -> Nat:
  match b:
    case P.Batch{rs, k, rest, err, need}:
      List.length(&2, B.Req, rs)

def parse_only(i: Nat, +get: Bool, acc: Nat) -> Nat:
  match i:
    case 0n:
      acc
    case 1n++j:
      parse_only(j, get, Nat.add(acc, n_reqs(P.parse(batch16(j, get)))))

def n_cmds(i: Nat, +get: Bool, acc: Nat) -> Nat:
  match i:
    case 0n:
      acc
    case 1n++j:
      n_cmds(j, get, Nat.add(acc, List.length(&2, R.Cmd, batch_cmds(P.parse(batch16(j, get))))))

def fst(r: Nat & KV.Trie<String>) -> Nat:
  (n, db) = r
  n

def report(name: String, n: Nat, t0: Nat, t1: Nat) -> IO(Unit):
  IO.print(name ++ ": " ++ Nat.show(Nat.sub(t1, t0)) ++ " ms (" ++ Nat.show(n) ++ ")")

def main() -> IO(Unit):
  do IO<Unit>:
    +n : Nat = 100000n
    +t0 : Nat <- IO.now()
    +db : KV.Trie<String> = fill(n, KV.empty(String))
    +t1 : Nat <- IO.now()
    report("map set x100k        ", KV.size(String, db), t0, t1)
    +hits : Nat = reads(n, db, 0n)
    +t2 : Nat <- IO.now()
    report("map get x100k        ", hits, t1, t2)
    +c1 : Nat = build_only(6250n, False{}, 0n)
    +u1 : Nat <- IO.now()
    report("build SET reqs x100k ", c1, t2, u1)
    +c2 : Nat = parse_only(6250n, False{}, 0n)
    +u2 : Nat <- IO.now()
    report("build+parse x100k    ", c2, u1, u2)
    +c3 : Nat = n_cmds(6250n, False{}, 0n)
    +u3 : Nat <- IO.now()
    report("build+parse+cmd x100k", c3, u2, u3)
    +b1 : Nat = fst(serve_all.go(6250n, False{}, (0n, KV.empty(String))))
    +t3 : Nat <- IO.now()
    report("serve SET x100k (P16)", b1, u3, t3)
    +b2 : Nat = fst(serve_all.go(6250n, True{}, (0n, fill(n, KV.empty(String)))))
    +t4 : Nat <- IO.now()
    report("fill+serve GET x100k ", b2, t3, t4)
