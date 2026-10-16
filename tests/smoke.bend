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
# typed as RESP3 types them, written in RESP2 and in RESP3. Then SHA-256
# of messages at the edges of its blocks (src/sha.bend, the passwords'
# hashes).
# Run: bend tests/smoke.bend
import Base
import ../src/map.bend as KV
import ../src/redis.bend as R
import ../src/resp.bend as P
import ../src/batch.bend as B
import ../src/sha.bend as Sha

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

# SHA-256 of messages of n bytes, the i-th (7 i + 3) mod 256: lengths at
# the edges of a block (the padding takes one block or two) and of a
# window of 2,048 bytes, and a message of 5,000 made of two strings
# (the k bytes up to the j-th, before rest)
def sha.msg(k: Nat, +j: Nat, rest: String) -> String:
  match k:
    case 0n:
      rest
    case 1n+p:
      sha.msg(p, Nat.sub(j, 1n), SCon{Chr{U32.from_nat(Nat.mod(Nat.add(Nat.mul(j, 7n), 3n), 256n))}, rest})

def sha.lines(ns: List<&2, Nat>) -> List<&2, String>:
  match ns:
    case Nil{}:
      ["sha256 5000 in two: " ++ Sha.sha256(sha.msg(1000n, 999n, "") ++ sha.msg(4000n, 4999n, ""))]
    case Con{+n, more}:
      ("sha256 " ++ Nat.show(n) ++ ": " ++ Sha.sha256(sha.msg(n, Nat.sub(n, 1n), ""))) <> sha.lines(more)

def sha.want() -> List<&2, String>:
  ["sha256 0: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
   "sha256 1: 084fed08b978af4d7d196a7446a86b58009e636b611db16211b65a9aadff29c5",
   "sha256 55: e7313d333c272e639f790978283f9eb392e843d0f29b7016828bb1daa4aac70b",
   "sha256 56: 4324d65f3c103567f5589c710bc08f8523f929a9272e3af36fc968e52abc6c27",
   "sha256 63: 81c80242132f230c3bd41b3e63bbcff16107339549214a99614ff26664625055",
   "sha256 64: 39e3d7b6b5d075d37d053ad89b24b41bef4f3c29760c84447cab3f3be1882241",
   "sha256 119: 9ce7368e4daf32341631b492e80359dc9f594b48453cd0dd5bf0b19279cc177e",
   "sha256 120: 7836b787757e95e58b3ca5aec90b1b004e8deba1e50e9675af9cabf1a13a04b5",
   "sha256 2047: 39f7319d9294a57ba5bd0c668bf67290e6710d5c676fb862bf6c305ab06ac961",
   "sha256 2048: dfff795a6b8cdf421e2e0815987ba9eed246a3474ee26aeff7e70f0f2e5cc16b",
   "sha256 2049: 50b50e74886763936dbd000db7879e648fa84d5e56780e233f52026f0f5328b3",
   "sha256 5000: 34398b85297bf7d9dfb59b8d511d8bbb44ab23e891570e4395e7871475fc8afb",
   "sha256 5000 in two: 34398b85297bf7d9dfb59b8d511d8bbb44ab23e891570e4395e7871475fc8afb"]

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
    check(List.append(&2, String, run(P.parse(buf())), List.append(&2, String, typed.lines(typed()), sha.lines([0n, 1n, 55n, 56n, 63n, 64n, 119n, 120n, 2047n, 2048n, 2049n, 5000n]))), List.append(&2, String, want(env.or(r)), List.append(&2, String, typed.want(), sha.want())))
