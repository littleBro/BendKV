# aof_check.bend: runs smoke.bend's batch with its effects (aof.bend:
# exec_log), writes the effects as the server appends them, reads the
# file back, runs it from an empty database and prints whether that gives
# the batch's database; then cuts the file at every length and prints
# whether each cut loads as whole entries and a leftover that together
# are the cut, the leftover holding no whole entry.
# Run: bend tests/aof_check.bend
import Base
import ../map.bend as KV
import ../redis.bend as R
import ../resp.bend as P
import ../batch.bend as B
import ../aof.bend as A

def batch_of(b: P.Batch) -> List<&2, R.Cmd>:
  match b:
    case P.Batch{reqs, rest, err, need}:
      B.fit_cmds(reqs, Nil{})

def buf() -> String:
  "*3\r\n$3\r\nSET\r\n$3\r\nfoo\r\n$3\r\nbar\r\n" ++
  "*2\r\n$3\r\nGET\r\n$3\r\nfoo\r\n" ++
  "get missing\r\n" ++
  "INCR n\r\nINCRBY n 41\r\nDECRBY n 100\r\n" ++
  "set s 99999999999999\r\nincr s\r\nincr foo\r\n" ++
  "APPEND foo baz\r\nSTRLEN foo\r\nMSET a 1 b 2 c 3 d 4 e 5 f 6\r\nMGET a b c x d e f\r\n" ++
  "EXISTS a b c a z\r\nDEL a b c z\r\nSETNX foo x\r\nSETNX g x\r\nGETSET foo y\r\nDBSIZE\r\n" ++
  "KEYS *\r\nKEYS f?o\r\nPING\r\nECHO hi\r\nNOPE 1 2\r\nSET k\r\nINCRBY n x\r\n" ++
  "SET big 9223372036854775807\r\nINCR big\r\nINCRBY m -5\r\nSET e \"\"\r\n" ++
  "FLUSHALL\r\nDBSIZE\r\nSET q 1\r\nMGET q q\r\nDEL q q\r\nKEYS *\r\n" ++
  "SET a 1\r\nINCRBY a 99\r\nAPPEND a 0\r\nMSET x 1 y 2\r\nDEL y\r\nSETNX z 3\r\nGETSET z 4\r\n"

# a database as its keys and values, in its own order
def dump.go(+db: KV.Trie<String>, ks: List<&2, String>) -> String:
  match ks:
    case Nil{}:
      SNil{}
    case Con{+k, rest}:
      k ++ "=" ++ Maybe.default(&2, String, KV.get(String, db, k), "?") ++ " " ++ dump.go(db, rest)

def dump(+db: KV.Trie<String>) -> String:
  dump.go(db, KV.keys(String, db))

def db_of(r: List<&2, R.Reply> & KV.Trie<String>) -> KV.Trie<String>:
  (rs, db) = r
  db

# the database the entries of a file leave, from an empty one
def replay(f: List<&2, List<&2, String>> & String) -> KV.Trie<String>:
  (reqs, rest) = f
  db_of(R.exec_all(A.parse_all(reqs), KV.empty(String)))

def same(+got: String, +want: String) -> String:
  Bool.pick(String, String.eq(got, want), "same", "differ: " ++ got ++ " vs " ++ want)

def is_none(m: Maybe<&1, List<&2, String> & String>) -> Bool:
  match m:
    case None{}:
      True{}
    case Some{p}:
      False{}

# a cut loads as whole entries and a leftover that make the cut, and the
# leftover holds no whole entry
def cut_ok(+cut: String, l: List<&2, List<&2, String>> & String) -> Bool:
  (reqs, +rest) = l
  Bool.and(String.eq(A.encode(reqs) ++ rest, cut), is_none(A.entry(rest)))

def cuts(+f: String, k: Nat, +n: Nat) -> String:
  match k:
    case 0n:
      "all " ++ Nat.show(n) ++ " cuts load"
    case 1n+m:
      +c = String.take(f, n)
      Bool.pick(String, cut_ok(c, A.load(c)), cuts(f, m, 1n+n), "cut at " ++ Nat.show(n) ++ " fails")

def report.of(+cs: List<&2, R.Cmd>, q: List<&2, R.Cmd> & KV.Trie<String>) -> IO(Unit):
  (es, +db) = q
  +f = A.encode(A.args_all(es))
  +want = dump(db)
  +one = dump(db_of(R.exec_all(cs, KV.empty(String))))
  do IO<Unit>:
    Unit <- IO.print("file: " ++ Nat.show(String.length(f)) ++ " bytes, " ++ Nat.show(List.length(&2, List<&2, String>, Pair.fst(List<&2, List<&2, String>>, String, A.load(f)))) ++ " entries")
    Unit <- IO.print("exec_log's database is exec_all's: " ++ same(want, one))
    Unit <- IO.print("replayed database: " ++ same(dump(replay(A.load(f))), want))
    Unit <- IO.print("database: " ++ want)
    IO.print(cuts(f, 1n+String.length(f), 0n))

def report(+cs: List<&2, R.Cmd>, r: List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>)) -> IO(Unit):
  (rs, q) = r
  report.of(cs, q)

def main() -> IO(Unit):
  +cs = batch_of(P.parse(buf()))
  report(cs, A.exec_log(cs, KV.empty(String)))
