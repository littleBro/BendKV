# smoke.bend: parses a pipelined buffer, runs it, prints the RESP replies,
# escaped one per line, and the bytes left unparsed, and checks each line
# against the one expected: a line that differs, and a reply too many or
# too few, makes the run exit with 1, naming the first. INCR of
# 99999999999999 overflows, as BendKV's integers stop at 14 digits (Redis
# answers 100000000000000). A number the parser refuses (INCRBY n x) is
# the session's to answer, after it checks the client's authentication,
# as Redis does: the database alone answers that the command is the
# connection's. With BENDKV_CHECK_BREAK=smoke the first line expected is
# a wrong one, to show that a difference fails the run.
# Run: bend tests/smoke.bend
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

def lines(rs: List<&2, R.Reply>, rest: String) -> List<&2, String>:
  match rs:
    case Nil{}:
      ["rest: " ++ escape(rest)]
    case Con{r, more}:
      escape(P.encode(r)) <> lines(more, rest)

def replies(r: List<&2, R.Reply> & R.Db) -> List<&2, R.Reply>:
  (rs, db) = r
  rs

def run(b: P.Batch) -> List<&2, String>:
  match b:
    case P.Batch{reqs, tl, rest, err, need, raw}:
      lines(replies(R.exec_all(B.cmds_of(reqs, Nil{}), R.db.empty())), rest)

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

# the lines expected, the first made wrong when the run breaks smoke
def want(+mode: String) -> List<&2, String>:
  [Bool.pick(String, String.eq(mode, "smoke"), "+NOTOK\\r\\n", "+OK\\r\\n"),
   "$3\\r\\nbar\\r\\n",
   "$-1\\r\\n",
   ":1\\r\\n",
   ":42\\r\\n",
   ":-58\\r\\n",
   "+OK\\r\\n",
   "-ERR increment or decrement would overflow\\r\\n",
   "-ERR value is not an integer or out of range\\r\\n",
   ":6\\r\\n",
   ":6\\r\\n",
   "+OK\\r\\n",
   "*3\\r\\n$1\\r\\n1\\r\\n$1\\r\\n2\\r\\n$-1\\r\\n",
   ":3\\r\\n",
   ":2\\r\\n",
   ":0\\r\\n",
   "$6\\r\\nbarbaz\\r\\n",
   ":3\\r\\n",
   "*3\\r\\n$1\\r\\nn\\r\\n$1\\r\\ns\\r\\n$3\\r\\nfoo\\r\\n",
   "*1\\r\\n$3\\r\\nfoo\\r\\n",
   "+PONG\\r\\n",
   "$2\\r\\nhi\\r\\n",
   "-ERR unknown command 'NOPE', with args beginning with: '1' '2' \\r\\n",
   "-ERR wrong number of arguments for 'set' command\\r\\n",
   "-ERR a command of the connection, not of the database\\r\\n",
   "rest: *2\\r\\n$3\\r\\nGET\\r\\n$3\\r\\nfo"]

# where each line got differs from the one wanted ("" where they agree),
# the lines numbered from i
def diff.line(+i: Nat, +got: String, +want: String) -> String:
  Bool.pick(String, String.eq(got, want), "", "line " ++ Nat.show(i) ++ ": got " ++ got ++ ", want " ++ want)

def diffs(gs: List<&2, String>, ws: List<&2, String>, +i: Nat) -> List<&2, String>:
  match gs ws:
    case Con{g, grest} Con{w, wrest}:
      diff.line(i, g, w) <> diffs(grest, wrest, 1n+i)
    case Con{g, grest} Nil{}:
      ["line " ++ Nat.show(i) ++ ": got " ++ g ++ ", want none"]
    case Nil{} Con{w, wrest}:
      ["line " ++ Nat.show(i) ++ ": got none, want " ++ w]
    case Nil{} Nil{}:
      Nil{}

def first(ds: List<&2, String>) -> String:
  match ds:
    case Nil{}:
      ""
    case Con{SNil{}, rest}:
      first(rest)
    case Con{d, rest}:
      d

def join(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{x, rest}:
      x ++ "\n" ++ join(rest)

def verdict(ok: Bool, d: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.print("ALL SMOKE REPLIES AS EXPECTED")
    case False{}:
      IO.die(Unit, 1, "FAIL " ++ d)

def check(+gs: List<&2, String>, ws: List<&2, String>) -> IO(Unit):
  +d = first(diffs(gs, ws, 1n))
  do IO<Unit>:
    Unit <- IO.write(join(gs))
    verdict(String.is_empty(d), d)

def env.or(r: Result<&1, &1, U32 & String, String>) -> String:
  match r:
    case Done{v}:
      v
    case Fail{e}:
      ""

def main() -> IO(Unit):
  do IO<Unit>:
    r : Result<&1, &1, U32 & String, String> <- IO.get_env("BENDKV_CHECK_BREAK")
    check(run(P.parse(buf())), want(env.or(r)))
