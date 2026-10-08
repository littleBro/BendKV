# shard_check.bend: runs smoke.bend's batch on one trie and cut among n
# shards (shard.bend: split, each part with exec_all on an empty trie,
# merge), for several n, and prints whether the replies are the same:
# merged as replies (shard.bend's merge, as the laws have it) and merged
# as the shards' encoded answers (wire.bend, as the server does).
# Run: bend tests/shard_check.bend
import Base
import ../map.bend as KV
import ../redis.bend as R
import ../resp.bend as P
import ../batch.bend as B
import ../shard.bend as S
import ../wire.bend as W

def replies(r: List<&2, R.Reply> & KV.Trie<String>) -> List<&2, R.Reply>:
  (rs, db) = r
  rs

def part_replies(x: List<&2, R.Cmd> & List<&2, U32>) -> List<&2, R.Reply>:
  (cs, hs) = x
  replies(R.exec_all(cs, KV.empty(String)))

def run_parts(ps: List<&2, List<&2, S.Part>>) -> List<&2, List<&2, R.Reply>>:
  match ps:
    case Nil{}:
      Nil{}
    case Con{p, rest}:
      part_replies(S.unzip(p)) <> run_parts(rest)

def sharded.fin(r: List<&2, S.Route> & List<&2, List<&2, S.Part>>) -> List<&2, R.Reply>:
  (routes, parts) = r
  S.merge(routes, run_parts(parts))

def sharded(+n: U32, cs: List<&2, R.Cmd>) -> List<&2, R.Reply>:
  sharded.fin(S.split(n, cs))

def part_outs(x: List<&2, R.Cmd> & List<&2, U32>) -> List<&2, W.Out>:
  (cs, hs) = x
  W.outs(replies(R.exec_all(cs, KV.empty(String))))

def run_outs(ps: List<&2, List<&2, S.Part>>) -> W.Store():
  match ps:
    case Nil{}:
      Nil{}
    case Con{p, rest}:
      part_outs(S.unzip(p)) <> run_outs(rest)

def join(ps: List<&2, String>) -> String:
  match ps:
    case Nil{}:
      SNil{}
    case Con{p, rest}:
      p ++ join(rest)

def bytes.fin(r: List<&2, S.Route> & List<&2, List<&2, S.Part>>) -> String:
  (routes, parts) = r
  join(W.merge(routes, run_outs(parts)))

# the batch's reply as the server sends it: each shard's answers encoded,
# merged in bytes
def bytes(+n: U32, cs: List<&2, R.Cmd>) -> String:
  bytes.fin(S.split(n, cs))

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
  "EXISTS a b c a z\r\nDEL a b c z\r\nSETNX foo x\r\nGETSET foo y\r\nDBSIZE\r\n" ++
  "KEYS *\r\nKEYS f?o\r\nPING\r\nECHO hi\r\nNOPE 1 2\r\nSET k\r\nINCRBY n x\r\n" ++
  "FLUSHALL\r\nDBSIZE\r\nSET q 1\r\nMGET q q\r\nDEL q q\r\nKEYS *\r\n"

def same(+got: String, +one: String) -> String:
  Bool.pick(String, String.eq(got, one), "same", "differ: " ++ got)

def verdict(+n: U32, +one: String) -> String:
  +cs = batch_of(P.parse(buf()))
  U32.show(n) ++ " shards: " ++ same(P.encode_all(sharded(n, cs)), one) ++ ", in bytes " ++ same(bytes(n, cs), one)

def main() -> IO(Unit):
  +one = P.encode_all(replies(R.exec_all(batch_of(P.parse(buf())), KV.empty(String))))
  do IO<Unit>:
    Unit <- IO.print(verdict(1, one))
    Unit <- IO.print(verdict(2, one))
    Unit <- IO.print(verdict(3, one))
    Unit <- IO.print(verdict(4, one))
    IO.print(verdict(16, one))
