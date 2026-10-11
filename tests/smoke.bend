# smoke.bend: parses a pipelined buffer, runs it and prints the RESP
# replies, escaped one per line. Run: bend tests/smoke.bend
import Base
import ../src/map.bend as KV
import ../src/redis.bend as R
import ../src/resp.bend as P
import ../src/batch.bend as B

def show_char(c: Char) -> String:
  match c:
    case '\r':
      "\\r"
    case '\n':
      "\\n"
    case c0:
      SCon{c0, SNil{}}

def escape(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{c, t}:
      show_char(c) ++ escape(t)

def lines(rs: List<&2, R.Reply>) -> String:
  match rs:
    case Nil{}:
      SNil{}
    case Con{r, rest}:
      escape(P.encode(r)) ++ "\n" ++ lines(rest)

def replies(r: List<&2, R.Reply> & KV.Trie<String>) -> List<&2, R.Reply>:
  (rs, db) = r
  rs

def run(b: P.Batch) -> String:
  match b:
    case P.Batch{reqs, n, rest, err, need}:
      lines(replies(R.exec_all(B.cmds_of(reqs, Nil{}), KV.empty(String)))) ++ "rest: " ++ escape(rest)

def buf() -> String:
  "*3\r\n$3\r\nSET\r\n$3\r\nfoo\r\n$3\r\nbar\r\n" ++
  "*2\r\n$3\r\nGET\r\n$3\r\nfoo\r\n" ++
  "get missing\r\n" ++
  "INCR n\r\nINCRBY n 41\r\nDECRBY n 100\r\n" ++
  "set s 99999999999999\r\nincr s\r\nincr foo\r\n" ++
  "APPEND foo baz\r\nSTRLEN foo\r\nMSET a 1 b 2\r\nMGET a b c\r\n" ++
  "EXISTS a b c a\r\nDEL a b c\r\nSETNX foo x\r\nGETSET foo y\r\nDBSIZE\r\n" ++
  "KEYS *\r\nKEYS f?o\r\nPING\r\nECHO hi\r\nNOPE 1 2\r\nSET k\r\nINCRBY n x\r\n" ++
  "*2\r\n$3\r\nGET\r\n$3\r\nfo"

def main() -> IO(Unit):
  IO.print(run(P.parse(buf())))
