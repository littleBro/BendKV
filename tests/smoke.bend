# smoke.bend: parses a pipelined buffer, runs it, prints the RESP replies,
# escaped one per line, and the bytes left unparsed, and checks each line
# against the one expected: a line that differs, and a reply too many or
# too few, makes the run exit with 1, naming the first. INCR adds long
# longs, as Redis does: 99999999999999 becomes 100000000000000, and
# LLONG_MAX overflows. A number the parser refuses (INCRBY n x) is
# the session's to answer, after it checks the client's authentication,
# as Redis does: the database alone answers that the command is the
# connection's. With BENDKV_CHECK_BREAK=smoke the first line expected is
# a wrong one, to show that a difference fails the run. Then replies
# typed as RESP3 types them, written in RESP2 and in RESP3. Then the
# calls of one command counted past 2^32 (src/info.bend, stats.fold).
# Run: bend tests/smoke.bend
import Base
import ../src/map.bend as KV
import ../src/redis.bend as R
import ../src/resp.bend as P
import ../src/batch.bend as B
import ../src/info.bend as I

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
      lines(replies(R.exec_all(B.cmds_of(reqs, Nil{}), R.db.empty())), P.tail.bytes(rest))

def buf() -> String:
  "*3\r\n$3\r\nSET\r\n$3\r\nfoo\r\n$3\r\nbar\r\n" ++
  "*2\r\n$3\r\nGET\r\n$3\r\nfoo\r\n" ++
  "get missing\r\n" ++
  "INCR n\r\nINCRBY n 41\r\nDECRBY n 100\r\n" ++
  "set s 99999999999999\r\nincr s\r\nset s 9223372036854775807\r\nincr s\r\nincr foo\r\n" ++
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
   ":100000000000000\\r\\n",
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

# Replies typed as RESP3 types them, each written in RESP2 then in RESP3
# (resp.bend, Replies), and switches of the protocol in a batch's replies
def typed() -> List<&2, R.Reply>:
  [R.RNull{}, R.RNullA{}, R.RDbl{"1.5"}, R.RMap{[R.RBulk{"a"}, R.r_int(1n)]}, R.RSet{[R.RBulk{"a"}]},
   R.RPairs{[R.RPair{[R.RBulk{"m"}, R.RDbl{"2"}]}]}, R.RVerb{"x"}, R.RPush{[R.RBulk{"m"}]}]

def typed.lines(rs: List<&2, R.Reply>) -> List<&2, String>:
  match rs:
    case Nil{}:
      [escape(P.encode_as(False{}, [R.RNull{}, R.RSw{True{}, [R.RNull{}]}, R.RNull{}])),
       escape(P.encode_as(True{}, [R.RNull{}, R.RSw{False{}, [R.RNull{}]}, R.RNull{}])),
       escape(P.encode_as(False{}, [R.RSw{True{}, Nil{}}, R.RNull{}]))]
    case Con{+r, more}:
      escape(P.encode_as(False{}, [r])) <> (escape(P.encode_as(True{}, [r])) <> typed.lines(more))

def typed.want() -> List<&2, String>:
  ["$-1\\r\\n", "_\\r\\n",
   "*-1\\r\\n", "_\\r\\n",
   "$3\\r\\n1.5\\r\\n", ",1.5\\r\\n",
   "*2\\r\\n$1\\r\\na\\r\\n:1\\r\\n", "%1\\r\\n$1\\r\\na\\r\\n:1\\r\\n",
   "*1\\r\\n$1\\r\\na\\r\\n", "~1\\r\\n$1\\r\\na\\r\\n",
   "*2\\r\\n$1\\r\\nm\\r\\n$1\\r\\n2\\r\\n", "*1\\r\\n*2\\r\\n$1\\r\\nm\\r\\n,2\\r\\n",
   "$1\\r\\nx\\r\\n", "=5\\r\\ntxt:x\\r\\n",
   "*1\\r\\n$1\\r\\nm\\r\\n", ">1\\r\\n$1\\r\\nm\\r\\n",
   "$-1\\r\\n_\\r\\n_\\r\\n",
   "_\\r\\n$-1\\r\\n$-1\\r\\n",
   "_\\r\\n"]

# The calls of a command counted past 2^32: a run is the command's code
# times 2^32 plus its count (R.run.of), and the newest run timed (cur)
# takes the runs of its code until a tick counts it. 2^31 + 5 GETs, a
# tick, 2^31 more GETs and a tick must count 2^32 + 5 GETs and nothing
# else; had cur gone on taking them, its count would have carried into its
# code, the code of GET's refused calls.
def timing.get() -> Nat:
  R.stat.code(R.stat.key(R.cmd_id("GET", 3n), Nil{}), 0n)

def timing.half() -> Nat:
  Nat.mul(32768n, 65536n)

# run r timed, as taking no time, with latency-tracking off (the window
# is empty here)
def timing.run(st: I.Stats, +r: Nat) -> I.Stats:
  match st:
    case I.Stats{es, fresh, cur, pend, errs, total}:
      I.stats.one.of(I.timed.run(r, 0n, False{}, 0n, 0n, 0n, (cur, pend)), es, errs, total)

def timing.ents(es: List<&2, I.Ent>) -> List<&2, String>:
  match es:
    case Nil{}:
      Nil{}
    case Con{I.Ent{k, calls, rej, fail, us, h}, rest}:
      ("timing: " ++ R.stat.name(k) ++ " calls " ++ I.big.show(calls) ++ " rejected " ++ I.big.show(rej) ++ " failed " ++ I.big.show(fail)) <> timing.ents(rest)

def timing.lines() -> List<&2, String>:
  +g = timing.get()
  +h = timing.half()
  st = I.stats.fold(timing.run(I.stats.fold(timing.run(I.stats.zero(), R.run.of(g, Nat.add(h, 5n)))), R.run.of(g, h)))
  timing.ents(I.stats.view(st))

def timing.want() -> List<&2, String>:
  ["timing: get calls 4294967301 rejected 0 failed 0"]

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
    check(List.append(&2, String, run(P.parse(buf())), List.append(&2, String, typed.lines(typed()), timing.lines())), List.append(&2, String, want(env.or(r)), List.append(&2, String, typed.want(), timing.want())))
