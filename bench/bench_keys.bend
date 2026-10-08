# bench_keys.bend: the server's pure path (bytes in, bytes out) for SET
# over key spaces of different sizes, as redis-benchmark -r spreads them
import Base
import ../src/map.bend as KV
import ../src/redis.bend as R
import ../src/resp.bend as P
import ../src/batch.bend as B

def pad12(+s: String) -> String:
  String.repeat("0", Nat.sub(12n, String.length(s))) ++ s

def key(i: Nat) -> String:
  "key:" ++ pad12(Nat.show(i))

def set_req(+k: String) -> String:
  "*3\r\n$3\r\nSET\r\n$" ++ Nat.show(String.length(k)) ++ "\r\n" ++ k ++ "\r\n$3\r\nxxx\r\n"

def batch16.go(i: Nat, +base: Nat, +space: Nat, acc: String) -> String:
  match i:
    case 0n:
      acc
    case 1n++j:
      batch16.go(j, base, space, set_req(key(Nat.mod(Nat.add(Nat.mul(base, 16n), j), space))) ++ acc)

def batch_cmds(b: P.Batch) -> List<&2, R.Cmd>:
  match b:
    case P.Batch{rs, rest, err, need}:
      B.cmds_of(rs, Nil{})

def serve.out(r: List<&2, R.Reply> & KV.Trie<String>, acc: Nat) -> Nat & KV.Trie<String>:
  (rs, db) = r
  (Nat.add(acc, String.length(P.encode_all(rs))), db)

def serve.step(+j: Nat, +space: Nat, st: Nat & KV.Trie<String>) -> Nat & KV.Trie<String>:
  (acc, db) = st
  serve.out(R.exec_all(batch_cmds(P.parse(batch16.go(16n, j, space, ""))), db), acc)

def serve(i: Nat, +space: Nat, st: Nat & KV.Trie<String>) -> Nat & KV.Trie<String>:
  match i:
    case 0n:
      st
    case 1n++j:
      serve(j, space, serve.step(j, space, st))

def fst(r: Nat & KV.Trie<String>) -> Nat:
  (n, db) = r
  n

def run(+space: Nat) -> IO(Unit):
  do IO<Unit>:
    +t0 : Nat <- IO.now()
    +b : Nat = fst(serve(6250n, space, (0n, KV.empty(String))))
    +t1 : Nat <- IO.now()
    IO.print("keys " ++ Nat.show(space) ++ ": 100k SET in " ++ Nat.show(Nat.sub(t1, t0)) ++ " ms (" ++ Nat.show(b) ++ " reply bytes)")

def main() -> IO(Unit):
  do IO<Unit>:
    run(1n)
    run(100n)
    run(10000n)
    run(100000n)
