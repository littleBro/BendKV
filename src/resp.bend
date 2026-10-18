# resp.bend: the RESP wire format. Requests are arrays of bulk strings
# (what redis-cli and every client library send) or inline lines (what a
# human types into nc); replies are encoded per their kind, in RESP2 or,
# for a client that asked for it (HELLO 3), RESP3. A buffer may hold
# several pipelined requests and end in the middle of one: parse returns
# the complete ones and keeps the rest for the next read.
#
# Strings here are byte strings: each Char holds one byte (0..255), so a
# bulk's length in bytes is its String.length.

import Base
import ./redis.bend as R
import ./batch.bend as B

# Types
# -----
# A batch is parsed where it lies: the parser reads the buffer by index
# (String.code_at, String.find, and String.dec_line_at for a number line),
# hashes a key where it lies (String.hash_at), copies out only the bulks
# (String.slice) and the tail of an unfinished request, and leaves the
# buffer to its reader whole (the server sends it to the actor with the
# batch, for MONITOR). The buffer is only lent to it, so nothing is shared
# and nothing is rebuilt char by char.

# a number line: "<digits>\r\n", its number and the index after it
type NumLine is Data:
  NumOk{n: Nat, next: Nat}
  NumMore{}
  NumBad{}

# one bulk string: "$<len>\r\n<bytes>\r\n". An incomplete one says how
# many more bytes it needs at least, so a reader can wait for them
# instead of parsing a growing buffer again and again
type Bulk is Data:
  BulkOk{arg: String, next: Nat}
  BulkMore{need: Nat}
  BulkBad{msg: String}

# A long request read in part (issue #85): a request longer than a read
# comes in several reads, and parsed again from its start after each one
# it took time in proportion to the square of its size. When the
# arguments of a request read through windows (wbulks) stop at a bulk not
# whole yet, the parse keeps those it has read, as Redis keeps multibulklen
# and bulklen, and the next parse goes on from that bulk (parse_part).
# The request's number and name (once req.of knows them), how many bulks
# come after the one not whole yet, the arguments read before it (newest
# first), its index, how many more bytes it needs at least, and the bytes
# the request was read from so far, newest piece first (the batch it ends
# in holds them all, for MONITOR). PartOf, a part that holds a part, is
# never built: it makes Part a node of its own, one word.
type Part is Data:
  Part{id: Nat, nm: String, more: Nat, acc: List<&2, String>, at: Nat, need: Nat, raw: List<&2, String>}
  PartOf{p: Part}

# the arguments of a request after its name; or those of a long request
# read in part
type Args is Data:
  ArgsOk{args: List<&2, String>, next: Nat}
  ArgsMore{need: Nat}
  ArgsBad{msg: String}
  ArgsPart{p: Part}

# one request: its command, with the hash of its key for the hints and
# its code for INFO's statistics in the hash's high twelve bits (B.Req,
# R.stat.hash); or none for an empty one (*0, or a blank inline line),
# which Redis skips without a reply; or a long request read in part
type One is Data:
  OneOk{req: B.Req, next: Nat}
  OneNone{next: Nat}
  OneMore{need: Nat}
  OneBad{msg: String}
  OnePart{p: Part}

# what a parse leaves for the next read: nothing; the bytes from the first
# request not whole yet; or a long request read in part, with the bytes
# from its bulk not whole yet. The tail of a client that has not
# authenticated is TailAuth, whose next parse walks what comes for a
# request past Redis's limits first; the bytes from the first such
# request are held in TailHeld until the requests before them have run
# (Clients that must authenticate, below). A tail that holds a tail makes
# Tail a node of its own, one word, as a String is, in every step of a
# connection's loop that carries it.
type Tail is Data:
  TailNone{}
  TailBytes{s: String}
  TailPart{p: Part, s: String}
  TailAuth{t: Tail}
  TailHeld{t: Tail, msg: String}

# a buffer's worth of requests: the complete ones, newest first (as the
# parser meets them, each put before the ones it read already; the server
# puts them in order in the same pass that takes their commands and
# hashes apart, B.unzip), how many they are and the words of their codes
# together (R.tl.add: whether they all have one code, and which), the
# unparsed tail (Tail), a protocol error that ends the connection, if
# any, how many bytes the tail needs at least before a parse can make
# progress, and the buffer itself, whole (the server sends it to the
# actor with the batch, for MONITOR: the parser takes the buffer and gives
# it back, so that nothing shares it)
type Batch is Data:
  Batch{reqs: List<&2, B.Req>, tl: U32, rest: Tail, err: Maybe<&2, String>, need: Nat, raw: String}

# Lexing
# ------
# A length is read as Redis 7.0.15 reads it (processMultibulkBuffer): its
# line runs from the '*' or '$' to the first '\r', and its number is
# string2ll's, with no 0 before its first digit. The quick way reads the
# lines clients send, 1 to 10 digits and "\r\n", where they lie
# (String.dec_line_at); any other line goes Redis's own way (line_at,
# len.read), which waits for its '\r' and reads any number string2ll
# takes, so that both ways give Redis's answer.

# the least number of n + 2 digits, 10^(n + 1) (a line has 10 at most)
def num.least(n: Nat) -> Nat:
  match n:
    case 0n:
      10n
    case 1n:
      100n
    case 2n:
      1000n
    case 3n:
      10000n
    case 4n:
      100000n
    case 5n:
      1000000n
    case 6n:
      10000000n
    case 7n:
      100000000n
    case _:
      1000000000n

def num.wide(canon: Bool, v: Nat, next: Nat) -> NumLine:
  match canon:
    case True{}:
      NumOk{v, next}
    case False{}:
      NumBad{}

# the number line at index i, its number and its length with the "\r\n"
# (String.dec_line_at: a length of 0 when it is bad, of 1 when the buffer
# ends first and the line waits for the rest); a line of two digits or
# more whose number is below 10^(digits - 1) starts with a 0, which
# string2ll does not take, and goes Redis's way
def num.of(+i: Nat, vr: Nat & Nat) -> NumLine:
  match vr:
    case (v, 0n):
      NumBad{}
    case (v, 1n):
      NumMore{}
    case (v, 2n):
      NumBad{}
    case (v, 3n):
      NumOk{v, 3n+i}
    case (+v, 4n++n):
      num.wide(Nat.is_le(num.least(n), v), v, 4n+Nat.add(i, n))

# the number line of s at index i: 1 to 10 digits (the lengths Redis takes
# have at most 10), then "\r\n", read in place
def num_at(+s: String, +i: Nat) -> NumLine:
  num.of(i, String.dec_line_at(s, i))

# A line as Redis finds one: from index i to the first '\r' (strchr), which
# a NUL before it hides, as Redis reads its buffer as a C string; the line
# is there once a byte follows its '\r', whatever that byte is, as Redis
# skips it unread. Without its '\r', more than 64 KB from i is an error.
type Line is Data:
  LineAt{cr: Nat}
  LineWait{}
  LineBig{}

def line.wait(big: Bool) -> Line:
  match big:
    case True{}:
      LineBig{}
    case False{}:
      LineWait{}

def line.of(+r: Nat, found: Bool, room: Bool, big: Bool) -> Line:
  match found room:
    case True{} True{}:
      LineAt{r}
    case True{} False{}:
      LineWait{}
    case False{} _:
      line.wait(big)

def line_at(+s: String, +i: Nat, +l: Nat) -> Line:
  +r = String.find(s, '\r', i)
  line.of(r, Nat.is_lt(r, String.find(s, Chr{0}, i)), Nat.is_lt(1n+r, l), Nat.is_lt(65536n, Nat.sub(l, i)))

# the number of the line from index a to its '\r' at r, as string2ll reads
# it (R.ll.of): a '-' or not, then digits with no 0 before the first, from
# -2^63 to 2^63 - 1; a line of 21 bytes or more is none, as string2ll
# finds before it reads one
def len.read.if(short: Bool, +s: String, +a: Nat, +r: Nat) -> R.LL:
  match short:
    case True{}:
      +neg = U32.is_eq(String.code_at(s, a), 45)
      R.ll.of(R.dec.of(s, Bool.pick(Nat, neg, 1n+a, a), r), neg)
    case False{}:
      R.LLBad{}

def len.read(+s: String, +a: Nat, +r: Nat) -> R.LL:
  len.read.if(Nat.is_lt(Nat.sub(r, a), 21n), s, a, r)

# A bulk's header read Redis's way: its line from where the bulk starts,
# then the '$' it must start with, then its length: none, one below 0 or
# one past 512MB is an error. Where its data starts and how long it is.
type Head is Data:
  HeadOk{n: Nat, j: Nat}
  HeadMore{}
  HeadBad{msg: String}

def head.size(ok: Bool, n: Nat, j: Nat) -> Head:
  match ok:
    case True{}:
      HeadOk{n, j}
    case False{}:
      HeadBad{"Protocol error: invalid bulk length"}

def head.len(ll: R.LL, j: Nat) -> Head:
  match ll:
    case R.LL{neg, +hi, +lo}:
      head.size(Bool.and(Bool.not(neg), R.ll.le(hi, lo, 0n, 536870912n)), lo, j)
    case R.LLBad{}:
      HeadBad{"Protocol error: invalid bulk length"}

def head.dollar(dollar: Bool, c: U32, +s: String, +i: Nat, +r: Nat) -> Head:
  match dollar:
    case True{}:
      head.len(len.read(s, 1n+i, r), 2n+r)
    case False{}:
      HeadBad{"Protocol error: expected '$', got '" ++ SCon{Chr{c}, SNil{}} ++ "'"}

def head.of(+s: String, +i: Nat, ln: Line) -> Head:
  match ln:
    case LineAt{+r}:
      +c = String.code_at(s, i)
      head.dollar(U32.is_eq(c, 36), c, s, i, r)
    case LineWait{}:
      HeadMore{}
    case LineBig{}:
      HeadBad{"Protocol error: too big bulk count string"}

def head_at(+s: String, +i: Nat, +l: Nat) -> Head:
  head.of(s, i, line_at(s, i, l))

# the n bytes of a bulk at index j, copied out (String.slice) once the
# buffer holds them and the two bytes after them, which Redis skips
# unread, as it skips the byte after a line's '\r'; short is how many
# bytes it lacks
def bulk.fin(+s: String, +n: Nat, +j: Nat, ok: Bool, short: Nat) -> Bulk:
  match ok short:
    case False{} _:
      BulkBad{"Protocol error: invalid bulk length"}
    case True{} 0n:
      BulkOk{String.slice(s, j, n), 2n+Nat.add(j, n)}
    case True{} 1n+k:
      BulkMore{1n+k}

# a bulk whose header went Redis's way
def bulk.slow(+s: String, +l: Nat, h: Head) -> Bulk:
  match h:
    case HeadOk{+n, +j}:
      bulk.fin(s, n, j, True{}, Nat.sub(2n+Nat.add(j, n), l))
    case HeadMore{}:
      BulkMore{1n}
    case HeadBad{msg}:
      BulkBad{msg}

# a bulk of at most 512MB, as Redis allows; a header the quick way does
# not read goes Redis's way, from i
def bulk.body(+s: String, +i: Nat, +l: Nat, nl: NumLine) -> Bulk:
  match nl:
    case NumOk{+n, +j}:
      bulk.fin(s, n, j, Nat.is_le(n, 536870912n), Nat.sub(2n+Nat.add(j, n), l))
    case NumMore{}:
      BulkMore{1n}
    case NumBad{}:
      bulk.slow(s, l, head_at(s, i, l))

# a bulk that does not start with '$' is an error once its line has come
def bulk.head(+s: String, +i: Nat, +l: Nat, dollar: Bool, end: Bool) -> Bulk:
  match dollar end:
    case True{} _:
      bulk.body(s, i, l, num_at(s, 1n+i))
    case False{} True{}:
      BulkMore{1n}
    case False{} False{}:
      bulk.slow(s, l, head_at(s, i, l))

# the bulk of s at index i, l the length of s
def bulk_at(+s: String, +i: Nat, +l: Nat) -> Bulk:
  +c = String.code_at(s, i)
  bulk.head(s, i, l, U32.is_eq(c, 36), U32.is_eq(c, 4294967295))

# one key: the bulk of a command's key, with its hash read off the buffer
# (String.hash_at, which is KV.hash of the key)
type Key is Data:
  KeyOk{key: String, hash: U32, next: Nat}
  KeyMore{need: Nat}
  KeyBad{msg: String}

def key.fin(+s: String, +n: Nat, +j: Nat, ok: Bool, short: Nat) -> Key:
  match ok short:
    case False{} _:
      KeyBad{"Protocol error: invalid bulk length"}
    case True{} 0n:
      KeyOk{String.slice(s, j, n), String.hash_at(s, j, n), 2n+Nat.add(j, n)}
    case True{} 1n+k:
      KeyMore{1n+k}

def key.slow(+s: String, +l: Nat, h: Head) -> Key:
  match h:
    case HeadOk{+n, +j}:
      key.fin(s, n, j, True{}, Nat.sub(2n+Nat.add(j, n), l))
    case HeadMore{}:
      KeyMore{1n}
    case HeadBad{msg}:
      KeyBad{msg}

def key.body(+s: String, +i: Nat, +l: Nat, nl: NumLine) -> Key:
  match nl:
    case NumOk{+n, +j}:
      key.fin(s, n, j, Nat.is_le(n, 536870912n), Nat.sub(2n+Nat.add(j, n), l))
    case NumMore{}:
      KeyMore{1n}
    case NumBad{}:
      key.slow(s, l, head_at(s, i, l))

def key.head(+s: String, +i: Nat, +l: Nat, dollar: Bool, end: Bool) -> Key:
  match dollar end:
    case True{} _:
      key.body(s, i, l, num_at(s, 1n+i))
    case False{} True{}:
      KeyMore{1n}
    case False{} False{}:
      key.slow(s, l, head_at(s, i, l))

# the key bulk of s at index i, l the length of s
def key_at(+s: String, +i: Nat, +l: Nat) -> Key:
  +c = String.code_at(s, i)
  key.head(s, i, l, U32.is_eq(c, 36), U32.is_eq(c, 4294967295))

# Requests
# --------
# A request is parsed straight into its command: the name's bulk picks the
# command (R.cmd_id), and GET, SET and INCR, most of what a server sees,
# read their arguments' bulks into the command itself; the rest go through
# a list of their arguments and R.parse_id, as R.parse would. Each comes
# with the hash of its key, for the hints (B.Req).

# the remaining n bulks of a request, b the one just read: the recursion
# happens inside the case that read a bulk, so a request stops at its
# first incomplete or malformed bulk
def bulks(n: Nat, +s: String, +l: Nat, b: Bulk, acc: List<&2, String>) -> Args:
  match n b:
    case 0n BulkOk{arg, j}:
      ArgsOk{List.reverse(&2, String, arg <> acc), j}
    case 1n+m BulkOk{arg, +j}:
      bulks(m, s, l, bulk_at(s, j, l), arg <> acc)
    case _ BulkMore{k}:
      ArgsMore{k}
    case _ BulkBad{msg}:
      ArgsBad{msg}

# The arguments of a long request. A request longer than a window
# (Long buffers, below) is parsed in the buffer where it lies, and a read
# of a packed String by index walks its runs from its start: its
# arguments are read through a window of their own, a copy of one run of
# the buffer (2048 bytes), moved on (sliced again at the next bulk) once
# fewer than 1024 of its bytes are left, so that each read walks one run
# and the parse takes time in proportion to the request, not to its
# square. A bulk that runs past the window, with more of the buffer after
# the window, is read from the buffer itself.

def run.max() -> Nat:
  2048n

# the window of s at index j: up to a run of its bytes, a copy
def wnd.from(+s: String, +j: Nat, +l: Nat) -> String:
  String.slice(s, j, Nat.min(run.max(), Nat.sub(l, j)))

# a bulk read in the window w, whose first byte is at index base of s,
# its next index back in s; one that runs past w (s goes on past w) is
# read from s itself, at j
def wnd.bulk.of(b: Bulk, +base: Nat, past: Bool, +s: String, +j: Nat, +l: Nat) -> Bulk:
  match b past:
    case BulkOk{arg, +nj} _:
      BulkOk{arg, Nat.add(nj, base)}
    case BulkMore{k} True{}:
      bulk_at(s, j, l)
    case BulkMore{k} False{}:
      BulkMore{k}
    case BulkBad{m} _:
      BulkBad{m}

def wnd.bulk(+w: String, +base: Nat, +s: String, +j: Nat, +l: Nat) -> Bulk:
  +wl = String.length(w)
  wnd.bulk.of(bulk_at(w, Nat.sub(j, base), wl), base, Nat.is_lt(Nat.add(base, wl), l), s, j, l)

# the window for the bulk at j: w (at base) while 1024 of its bytes are
# left or it reaches the end of s, else the window at j
def wnd.next(re: Bool, +w: String, +s: String, +j: Nat, +l: Nat) -> String:
  match re:
    case True{}:
      wnd.from(s, j, l)
    case False{}:
      w

def wnd.re(+w: String, +base: Nat, +j: Nat, +l: Nat) -> Bool:
  +end = Nat.add(base, String.length(w))
  Bool.and(Nat.is_lt(end, Nat.add(j, 1024n)), Nat.is_lt(end, l))

# bulks's loop through a window: w at index base of s, b the bulk at
# index jb; one not whole yet leaves the request read in part (Part)
def wbulks(n: Nat, +s: String, +l: Nat, +w: String, +base: Nat, +jb: Nat, b: Bulk, acc: List<&2, String>) -> Args:
  match n b:
    case 0n BulkOk{arg, j}:
      ArgsOk{List.reverse(&2, String, arg <> acc), j}
    case 1n+m BulkOk{arg, +j}:
      +re = wnd.re(w, base, j, l)
      +w2 = wnd.next(re, w, s, j, l)
      +b2 = Bool.pick(Nat, re, j, base)
      wbulks(m, s, l, w2, b2, j, wnd.bulk(w2, b2, s, j, l), arg <> acc)
    case m BulkMore{k}:
      ArgsPart{Part{0n, SNil{}, m, acc, jb, k, Nil{}}}
    case _ BulkBad{msg}:
      ArgsBad{msg}

# the k bulks after the first of a request's arguments at index j: in
# place in a buffer of one run, through a window in a longer one
def args.from(long: Bool, +k: Nat, +s: String, +l: Nat, +j: Nat) -> Args:
  match long:
    case False{}:
      bulks(k, s, l, bulk_at(s, j, l), Nil{})
    case True{}:
      +w = wnd.from(s, j, l)
      wbulks(k, s, l, w, j, j, wnd.bulk(w, j, s, j, l), Nil{})

# the m bulks of a request's arguments at index j
def args.at(m: Nat, +s: String, +l: Nat, +j: Nat) -> Args:
  match m:
    case 0n:
      ArgsOk{Nil{}, j}
    case 1n+k:
      args.from(Nat.is_lt(run.max(), l), k, s, l, j)

# a request, its hash marked with its code: its key and what its
# command counts as; a failed call's error as the server runs it
# (R.fail.if: SFail, answered once the client may run commands). The
# hash is also the mark of its key's use (server.bend, Access): a call
# the parser refused or failed has none (0), as it reads no key.
def req.ok(+c: R.Cmd, h: U32, +key: Nat, +args: List<&2, String>, j: Nat) -> One:
  +class = R.stat.class(c, key, args)
  OneOk{B.Req{R.fail.if(class, c), R.stat.hash(Bool.pick(U32, Nat.is_eq(class, 0n), h, 0), R.stat.code(key, class))}, j}

# the hash of a request's key: that of its first argument, for a command
# whose first key it is and that touches it as it reads it (R.stat.touch:
# not EXISTS, TYPE and the TTLs, which Redis looks up without marking
# their use); else none (0)
def req.hash(touch: Bool, +args: List<&2, String>) -> U32:
  match touch:
    case True{}:
      B.args_hash(args)
    case False{}:
      0

# a command of number id named nm (as the client spelled it, for an
# unknown one), from its arguments: a command of the connection or of
# the server (R.parse_sess) for a number R.cmd_own names
def req.mk(own: Bool, +id: Nat, +nm: String, +args: List<&2, String>, +key: Nat, j: Nat) -> One:
  match own:
    case True{}:
      req.ok(R.Own{R.parse_sess(id, nm, args)}, 0, key, args, j)
    case False{}:
      req.ok(R.parse_id(id, nm, args), req.hash(R.stat.touch(key), args), key, args, j)

# a long request read in part, with its command's number and name
def part.named(p: Part, +id: Nat, nm: String) -> Part:
  match p:
    case Part{i, x, more, acc, at, need, raw}:
      Part{id, nm, more, acc, at, need, raw}
    case PartOf{q}:
      part.named(q, id, nm)

def req.of(+id: Nat, +nm: String, a: Args) -> One:
  match a:
    case ArgsOk{+args, j}:
      req.mk(R.cmd_own(id), id, nm, args, R.stat.key(id, args), j)
    case ArgsMore{k}:
      OneMore{k}
    case ArgsBad{msg}:
      OneBad{msg}
    case ArgsPart{p}:
      OnePart{part.named(p, id, nm)}

# GET k
def get.of(b: Key) -> One:
  match b:
    case KeyOk{k, h, j}:
      OneOk{B.Req{R.Get{k}, U32.or(U32.and(h, 1048575), R.stat.mark.get())}, j}
    case KeyMore{n}:
      OneMore{n}
    case KeyBad{msg}:
      OneBad{msg}

# SET k v
def set.val(k: String, h: U32, b: Bulk) -> One:
  match b:
    case BulkOk{v, j}:
      OneOk{B.Req{R.Set{k, v}, U32.or(U32.and(h, 1048575), R.stat.mark.set())}, j}
    case BulkMore{n}:
      OneMore{n}
    case BulkBad{msg}:
      OneBad{msg}

def set.of(+s: String, +l: Nat, b: Key) -> One:
  match b:
    case KeyOk{k, h, +j}:
      set.val(k, h, bulk_at(s, j, l))
    case KeyMore{n}:
      OneMore{n}
    case KeyBad{msg}:
      OneBad{msg}

# INCR k
def incr.of(b: Key) -> One:
  match b:
    case KeyOk{k, h, j}:
      OneOk{B.Req{R.IncrBy{k, R.ByPos{0n, 1n}}, U32.or(U32.and(h, 1048575), R.stat.mark.incr())}, j}
    case KeyMore{n}:
      OneMore{n}
    case KeyBad{msg}:
      OneBad{msg}

# the name of an unknown command as the client sent it: the bytes of the
# name's bulk, which ends 2 bytes before j
def unknown_name(+s: String, +j: Nat, +up: String) -> String:
  +n = String.length(up)
  String.slice(s, Nat.sub(Nat.sub(j, 2n), n), n)

# the command of number id with m arguments at index j, named up (in
# upper case)
def cmd.of(+id: Nat, m: Nat, +up: String, +s: String, +l: Nat, +j: Nat) -> One:
  match id m:
    case 3n 1n:
      get.of(key_at(s, j, l))
    case 4n 2n:
      set.of(s, l, key_at(s, j, l))
    case 10n 1n:
      incr.of(key_at(s, j, l))
    case 0n _:
      req.of(0n, unknown_name(s, j, up), args.at(m, s, l, j))
    case _ _:
      req.of(id, up, args.at(m, s, l, j))

# a request of m arguments after its name, b the name's bulk
def name.of(m: Nat, +s: String, +l: Nat, b: Bulk) -> One:
  match b:
    case BulkOk{nm, +j}:
      +up = String.to_upper(nm)
      cmd.of(R.cmd_id(up, String.length(up)), m, up, s, l, j)
    case BulkMore{k}:
      OneMore{k}
    case BulkBad{msg}:
      OneBad{msg}

def array.if(n: Nat, +s: String, +l: Nat, +j: Nat, ok: Bool) -> One:
  match n ok:
    case 0n True{}:
      OneNone{j}
    case 1n+m True{}:
      name.of(m, s, l, bulk_at(s, j, l))
    case _ False{}:
      OneBad{"Protocol error: invalid multibulk length"}

# A count read Redis's way (line_at, len.read): none, or one past
# INT_MAX, is an error; one of 0 or less is skipped, the request with
# it, as Redis skips *0 (an empty request), down to -2^63.
def array.small(ok: Bool, +hi: Nat, +lo: Nat, +s: String, +l: Nat, +j: Nat) -> One:
  match ok:
    case True{}:
      array.if(Nat.add(Nat.mul(hi, 1000000000n), lo), s, l, j, True{})
    case False{}:
      OneBad{"Protocol error: invalid multibulk length"}

def array.signed(neg: Bool, +hi: Nat, +lo: Nat, +s: String, +l: Nat, +j: Nat) -> One:
  match neg:
    case True{}:
      OneNone{j}
    case False{}:
      array.small(R.ll.le(hi, lo, 2n, 147483647n), hi, lo, s, l, j)

def array.count(ll: R.LL, +s: String, +l: Nat, +j: Nat) -> One:
  match ll:
    case R.LL{neg, +hi, +lo}:
      array.signed(neg, hi, lo, s, l, j)
    case R.LLBad{}:
      OneBad{"Protocol error: invalid multibulk length"}

def array.line(+s: String, +i: Nat, +l: Nat, ln: Line) -> One:
  match ln:
    case LineAt{+r}:
      array.count(len.read(s, 1n+i, r), s, l, 2n+r)
    case LineWait{}:
      OneMore{1n}
    case LineBig{}:
      OneBad{"Protocol error: too big mbulk count string"}

# a count the quick way does not read goes Redis's way, from the '*'
def array(+s: String, +i: Nat, +l: Nat, nl: NumLine) -> One:
  match nl:
    case NumOk{+n, +j}:
      array.if(n, s, l, j, Nat.is_le(n, 2147483647n))
    case NumMore{}:
      OneMore{1n}
    case NumBad{}:
      array.line(s, i, l, line_at(s, i, l))

# An inline request
# -----------------
# The line up to its '\n', without a '\r' before it, split into arguments
# as Redis splits it (sdssplitargs): words between blanks; a "..." part
# with C escapes (\n \r \t \b \a and \xHH; a \ before any other char gives
# that char); a '...' part where \' is the only escape. A quote may open
# in the middle of a word, but a closing quote must be followed by a blank
# or the end of the line, and a quote left open is a protocol error.
# Redis finds the '\n' with strchr, which stops at a NUL byte: a line with
# a NUL before its '\n' waits for more, as a line without '\n' does, and
# either is a protocol error once more than 64 KB wait.

# the value of a hex digit, or 16 for another char
def sp.hex(+x: U32) -> U32:
  Bool.pick(U32, Bool.and(U32.is_ge(x, 48), U32.is_le(x, 57)), U32.sub(x, 48),
  Bool.pick(U32, Bool.and(U32.is_ge(x, 97), U32.is_le(x, 102)), U32.sub(x, 87),
  Bool.pick(U32, Bool.and(U32.is_ge(x, 65), U32.is_le(x, 70)), U32.sub(x, 55), 16)))

# the char a \ escape gives in a "..." part
def sp.esc(+x: U32) -> U32:
  Bool.pick(U32, U32.is_eq(x, 110), 10,
  Bool.pick(U32, U32.is_eq(x, 114), 13,
  Bool.pick(U32, U32.is_eq(x, 116), 9,
  Bool.pick(U32, U32.is_eq(x, 98), 8,
  Bool.pick(U32, U32.is_eq(x, 97), 7, x)))))

# the chars that end a word outside quotes (and a NUL, which never gets
# here)
def sp.ends(+x: U32) -> Bool:
  Bool.or(Bool.or(U32.is_eq(x, 32), U32.is_eq(x, 10)), Bool.or(U32.is_eq(x, 13), U32.is_eq(x, 9)))

# The splitter is a machine over the line's chars: between words (Blank),
# in a word (Word), in "..." (Dq), in '...' (Sq), or just after a closing
# quote (Close). A step takes a char or more and goes on with the rest of
# the line, the word so far (its last char first) and the words so far
# (newest first); at the end of the line it gives the words; a quote left
# open, or closed before anything but a blank, is an error.
type Mode is Data:
  MBlank{}
  MWord{}
  MDq{}
  MSq{}
  MClose{}

type Step is Data:
  Go{m: Mode, s: String, w: String, acc: List<&2, String>}
  End{acc: List<&2, String>}
  SpBad{}

def sp.put(w: String, acc: List<&2, String>) -> List<&2, String>:
  String.reverse(w) <> acc

def sp.blank(blank: Bool, c: Char, t: String, acc: List<&2, String>) -> Step:
  match blank:
    case True{}:
      Go{MBlank{}, t, SNil{}, acc}
    case False{}:
      Go{MWord{}, SCon{c, t}, SNil{}, acc}

def sp.word(end: Bool, x: U32, t: String, w: String, acc: List<&2, String>) -> Step:
  match end:
    case True{}:
      Go{MBlank{}, t, SNil{}, sp.put(w, acc)}
    case False{}:
      Go{MWord{}, t, SCon{Chr{x}, w}, acc}

def sp.close(blank: Bool, t: String, w: String, acc: List<&2, String>) -> Step:
  match blank:
    case True{}:
      Go{MBlank{}, t, SNil{}, sp.put(w, acc)}
    case False{}:
      SpBad{}

# inside "...": \x and two hex digits is their byte, else \x gives an x
def sp.hex2.if(ok: Bool, ha: U32, hb: U32, a: U32, b: U32, t: String, w: String, acc: List<&2, String>) -> Step:
  match ok:
    case True{}:
      Go{MDq{}, t, SCon{Chr{U32.add(U32.mul(ha, 16), hb)}, w}, acc}
    case False{}:
      Go{MDq{}, SCon{Chr{a}, SCon{Chr{b}, t}}, SCon{'x', w}, acc}

def sp.hex2(s: String, w: String, acc: List<&2, String>) -> Step:
  match s:
    case SCon{Chr{+a}, SCon{Chr{+b}, t}}:
      +ha = sp.hex(a)
      +hb = sp.hex(b)
      sp.hex2.if(Bool.and(U32.is_lt(ha, 16), U32.is_lt(hb, 16)), ha, hb, a, b, t, w, acc)
    case other:
      Go{MDq{}, other, SCon{'x', w}, acc}

def sp.step(m: Mode, s: String, w: String, acc: List<&2, String>) -> Step:
  match m s:
    case MBlank{} SNil{}:
      End{acc}
    case MBlank{} SCon{+c, t}:
      sp.blank(Char.is_space(c), c, t, acc)
    case MWord{} SNil{}:
      End{sp.put(w, acc)}
    case MWord{} SCon{'"', t}:
      Go{MDq{}, t, w, acc}
    case MWord{} SCon{'\'', t}:
      Go{MSq{}, t, w, acc}
    case MWord{} SCon{Chr{+x}, t}:
      sp.word(sp.ends(x), x, t, w, acc)
    case MDq{} SNil{}:
      SpBad{}
    case MDq{} SCon{'"', t}:
      Go{MClose{}, t, w, acc}
    case MDq{} SCon{'\\', SCon{'x', t}}:
      sp.hex2(t, w, acc)
    case MDq{} SCon{'\\', SCon{Chr{+x}, t}}:
      Go{MDq{}, t, SCon{Chr{sp.esc(x)}, w}, acc}
    case MDq{} SCon{c, t}:
      Go{MDq{}, t, SCon{c, w}, acc}
    case MSq{} SNil{}:
      SpBad{}
    case MSq{} SCon{'\\', SCon{'\'', t}}:
      Go{MSq{}, t, SCon{'\'', w}, acc}
    case MSq{} SCon{'\'', t}:
      Go{MClose{}, t, w, acc}
    case MSq{} SCon{c, t}:
      Go{MSq{}, t, SCon{c, w}, acc}
    case MClose{} SNil{}:
      End{sp.put(w, acc)}
    case MClose{} SCon{c, t}:
      sp.close(Char.is_space(c), t, w, acc)

# a step takes a char or more, but the step that starts a word, which
# takes none: twice one more than the line's length is enough fuel
def sp.run(fuel: Nat, st: Step) -> Maybe<&2, List<&2, String>>:
  match fuel st:
    case 1n+f Go{m, s, w, acc}:
      sp.run(f, sp.step(m, s, w, acc))
    case _ End{acc}:
      Some{acc}
    case _ other:
      None{}

def split.rev(m: Maybe<&2, List<&2, String>>) -> Maybe<&2, List<&2, String>>:
  match m:
    case Some{ws}:
      Some{List.reverse(&2, String, ws)}
    case None{}:
      None{}

# s split into words as Redis's sdssplitargs splits a line (ACL's
# selectors read theirs so), or none when a quote is left open
def split.args(+s: String) -> Maybe<&2, List<&2, String>>:
  split.rev(sp.run(Nat.mul(2n, 1n+String.length(s)), Go{MBlank{}, s, SNil{}, Nil{}}))

def inline.words(ws: List<&2, String>, +next: Nat) -> One:
  match ws:
    case Nil{}:
      OneNone{next}
    case Con{+w, rest}:
      +up = String.to_upper(w)
      req.of(R.cmd_id(up, String.length(up)), w, ArgsOk{rest, next})

def inline.of(m: Maybe<&2, List<&2, String>>, +next: Nat) -> One:
  match m:
    case Some{ws}:
      inline.words(List.reverse(&2, String, ws), next)
    case None{}:
      OneBad{"Protocol error: unbalanced quotes in request"}

# a request with no '\n' yet: more than 64 KB of it is an error
def inline.wait(big: Bool) -> One:
  match big:
    case True{}:
      OneBad{"Protocol error: too big inline request"}
    case False{}:
      OneMore{1n}

# the line without the '\r' before its '\n'
def inline.text(+line: String, +n: Nat, cr: Bool) -> String:
  match cr:
    case True{}:
      String.take(line, Nat.sub(n, 1n))
    case False{}:
      line

# the line of s at index i, up to the '\n' at k, copied out (a NUL in it
# stops Redis's search for the '\n')
def inline.line(+line: String, +n: Nat, nul: Bool, +next: Nat, big: Bool) -> One:
  match nul:
    case True{}:
      inline.wait(big)
    case False{}:
      inline.of(sp.run(Nat.mul(2n, 1n+n), Go{MBlank{}, inline.text(line, n, U32.is_eq(String.code_at(line, Nat.sub(n, 1n)), 13)), SNil{}, Nil{}}), next)

def inline.at(+s: String, +i: Nat, +k: Nat, +l: Nat, found: Bool) -> One:
  match found:
    case True{}:
      +n = Nat.sub(k, i)
      +line = String.slice(s, i, n)
      inline.line(line, n, Nat.is_lt(String.find(line, Chr{0}, 0n), n), 1n+k, Nat.is_lt(65536n, Nat.sub(l, i)))
    case False{}:
      inline.wait(Nat.is_lt(65536n, Nat.sub(l, i)))

def one.head(+s: String, +i: Nat, +l: Nat, star: Bool, end: Bool) -> One:
  match star end:
    case True{} _:
      array(s, i, l, num_at(s, 1n+i))
    case False{} True{}:
      OneMore{1n}
    case False{} False{}:
      +k = String.find(s, '\n', i)
      inline.at(s, i, k, l, Nat.is_lt(k, l))

# the request of s at index i, l the length of s
def one(+s: String, +i: Nat, +l: Nat) -> One:
  +c = String.code_at(s, i)
  one.head(s, i, l, U32.is_eq(c, 42), U32.is_eq(c, 4294967295))

# a batch's requests before its tail is cut off, newest first, how many
# they are and the words of their codes (R.tl.add): at is the index where
# the tail starts, the first request not parsed on; or the requests
# before a long request read in part, which starts at index start
type Cut is Data:
  Cut{reqs: List<&2, B.Req>, tl: U32, at: Nat, err: Maybe<&2, String>, need: Nat}
  CutPart{reqs: List<&2, B.Req>, tl: U32, start: Nat, p: Part}

# every complete request of s from index i on, put before acc, and
# counted with its code's word in tl: o is the parse of the one at i;
# each request takes at least one byte, so the length of the buffer is
# enough fuel. The request is taken apart for its hash, whose high twelve
# bits are its code's word: its words are in registers already.
def batch.go(fuel: Nat, +s: String, +l: Nat, +i: Nat, o: One, acc: List<&2, B.Req>, tl: U32) -> Cut:
  match fuel o:
    case 0n _:
      Cut{acc, tl, i, None{}, 1n}
    case 1n+f OneNone{+j}:
      batch.go(f, s, l, j, one(s, j, l), acc, tl)
    case 1n+f OneOk{B.Req{c, +h}, +j}:
      batch.go(f, s, l, j, one(s, j, l), B.Req{c, h} <> acc, R.tl.add(tl, h))
    case 1n+f OneMore{k}:
      Cut{acc, tl, i, None{}, k}
    case 1n+f OneBad{m}:
      Cut{acc, tl, l, Some{m}, 0n}
    case 1n+f OnePart{p}:
      CutPart{acc, tl, i, p}

# the tail is what follows the parsed requests, from index at of s (of
# length l): none when they took all of s, as they mostly do, else a copy
# of the rest of s; s goes back whole with the batch
def batch.tail(none: Bool, +s: String, +at: Nat, +l: Nat) -> Tail:
  match none:
    case True{}:
      TailNone{}
    case False{}:
      TailBytes{String.slice(s, at, Nat.sub(l, at))}

# a long request read in part, from index start of s, leaves as the tail
# the bytes from its bulk not whole yet, and keeps those before it (from
# start) with the bytes of the reads before
def part.batch(reqs: List<&2, B.Req>, tl: U32, +start: Nat, p: Part, +s: String, +l: Nat) -> Batch:
  match p:
    case Part{id, nm, more, acc, +at, +need, raw}:
      Batch{reqs, tl, TailPart{Part{id, nm, more, acc, 0n, need, String.slice(s, start, Nat.sub(at, start)) <> raw}, String.slice(s, at, Nat.sub(l, at))}, None{}, need, s}
    case PartOf{q}:
      part.batch(reqs, tl, start, q, s, l)

def batch.fin(c: Cut, +s: String, +l: Nat) -> Batch:
  match c:
    case Cut{reqs, tl, +at, err, need}:
      Batch{reqs, tl, batch.tail(Nat.is_le(l, at), s, at, l), err, need, s}
    case CutPart{reqs, tl, +start, p}:
      part.batch(reqs, tl, start, p, s, l)

# the requests of s from index at on, put before acc, counted in tl with
# those read before them: fuel must be at least the number of requests in
# s, which a reader that knows how many bytes it has passes; parse counts
# them itself
def parse_from(fuel: Nat, +s: String, +at: Nat, +l: Nat, acc: List<&2, B.Req>, tl: U32) -> Batch:
  batch.fin(batch.go(fuel, s, l, at, one(s, at, l), acc, tl), s, l)

def parse_onto(fuel: Nat, +s: String, acc: List<&2, B.Req>, tl: U32) -> Batch:
  +l = String.length(s)
  parse_from(fuel, s, 0n, l, acc, tl)

def parse(+s: String) -> Batch:
  +l = String.length(s)
  parse_onto(1n+l, s, Nil{}, 0)

# Long buffers
# ------------
# A packed String keeps at most 2048 bytes in a run, and reading it by
# index past its first run walks the runs from its start: String.code_at,
# find and slice are fast on one run only. A buffer longer than a run is
# parsed a window of at most 2048 bytes at a time, each window a copy of
# its own in one run (String.slice), from the first byte the window before
# did not parse; the requests of all the windows make one batch. A request
# longer than a window is parsed in the rest of the buffer where it lies:
# that happens once, when all its bytes have come.

def win.max() -> Nat:
  2048n

# a window's parse, judged: the last one (the buffer's end, or a protocol
# error), one that parsed nothing (a request longer than a window: the
# rest of the buffer is parsed whole from at), or one to go on after; the
# requests of the windows so far, newest first, and their count and the
# words of their codes (R.tl.add), are in each
type Win is Data:
  WinLast{b: Batch}
  WinBig{reqs: List<&2, B.Req>, tl: U32, at: Nat}
  WinOn{reqs: List<&2, B.Req>, tl: U32, next: Nat}

def win.on(reqs: List<&2, B.Req>, tl: U32, +at: Nat, +done: Nat, stuck: Bool) -> Win:
  match stuck:
    case True{}:
      WinBig{reqs, tl, at}
    case False{}:
      WinOn{reqs, tl, Nat.add(at, done)}

def win.judge(reqs: List<&2, B.Req>, tl: U32, rest: Tail, err: Maybe<&2, String>, need: Nat, +at: Nat, +done: Nat, last: Bool) -> Win:
  match err last:
    case Some{m} _:
      WinLast{Batch{reqs, tl, rest, Some{m}, need, SNil{}}}
    case None{} True{}:
      WinLast{Batch{reqs, tl, rest, None{}, need, SNil{}}}
    case None{} False{}:
      win.on(reqs, tl, at, done, Nat.is_eq(done, 0n))

# the bytes of a tail (a window's holds no request read in part: a
# window is parsed where it lies, as one run)
def tail.len(+t: Tail) -> Nat:
  match t:
    case TailNone{}:
      0n
    case TailBytes{+r}:
      String.length(r)
    case TailPart{p, +r}:
      String.length(r)
    case TailAuth{+u}:
      tail.len(u)
    case TailHeld{+u, m}:
      tail.len(u)

# the bytes a tail holds: none, those of a request not whole yet, or
# those of a long request's bulk not whole yet
def tail.bytes(t: Tail) -> String:
  match t:
    case TailNone{}:
      SNil{}
    case TailBytes{r}:
      r
    case TailPart{p, r}:
      r
    case TailAuth{u}:
      tail.bytes(u)
    case TailHeld{u, m}:
      tail.bytes(u)

# the window of w bytes at index at, of a buffer of l bytes, and its parse
# (the window, a copy, dropped)
def win.of(b: Batch, +at: Nat, +w: Nat, +l: Nat) -> Win:
  match b:
    case Batch{reqs, tl, +rest, err, need, win}:
      win.judge(reqs, tl, rest, err, need, at, Nat.sub(w, tail.len(rest)), Nat.is_le(l, Nat.add(at, w)))

# the window at index at, its requests put before acc, counted with
# those of the windows before it (tl)
def win.at(+s: String, +at: Nat, +l: Nat, acc: List<&2, B.Req>, tl: U32) -> Win:
  +w = Nat.min(win.max(), Nat.sub(l, at))
  win.of(parse_onto(1n+w, String.slice(s, at, w), acc, tl), at, w, l)

# the last window's batch, with the buffer whole
def win.last(b: Batch, s: String) -> Batch:
  match b:
    case Batch{reqs, tl, rest, err, need, x}:
      Batch{reqs, tl, rest, err, need, s}

# the windows of s from the one judged in w on; each window parses one
# byte or more, so the length of s is enough fuel
def win.go(n: Nat, +s: String, +l: Nat, w: Win) -> Batch:
  match n w:
    case _ WinLast{b}:
      win.last(b, s)
    case _ WinBig{reqs, tl, +at}:
      parse_from(1n+Nat.sub(l, at), s, at, l, reqs, tl)
    case 0n WinOn{reqs, tl, +at}:
      parse_from(1n+Nat.sub(l, at), s, at, l, reqs, tl)
    case 1n+m WinOn{reqs, tl, +at}:
      win.go(m, s, l, win.at(s, at, l, reqs, tl))

# the requests of s, which may be made of several runs (a long read, or
# the tail of the last read and a new one), in windows of one run each
def parse_runs(+s: String) -> Batch:
  +l = String.length(s)
  win.go(1n+l, s, l, win.at(s, 0n, l, Nil{}, 0))

# the requests of a fresh read: up to 2048 bytes it is one run, parsed
# where it lies
def parse_read.if(short: Bool, +s: String, +l: Nat) -> Batch:
  match short:
    case True{}:
      parse_onto(1n+l, s, Nil{}, 0)
    case False{}:
      win.go(1n+l, s, l, win.at(s, 0n, l, Nil{}, 0))

def parse_read(+s: String) -> Batch:
  +l = String.length(s)
  parse_read.if(Nat.is_le(l, win.max()), s, l)

# Long requests in part
# ---------------------
# The parse of a long request read in part goes on from its bulk not
# whole yet, at index 0 of what came since, through a window (wbulks),
# with the arguments it read before: each read is parsed once, and the
# request takes time in proportion to its size (issue #85). Once it is
# whole, the requests after it are parsed in windows, as in any buffer,
# and the batch holds the request's bytes from the reads before too,
# before its own (for MONITOR, which reads a batch's arguments again).

# the pieces, newest first, before s
def pieces.onto(xs: List<&2, String>, s: String) -> String:
  match xs:
    case Nil{}:
      s
    case Con{x, rest}:
      pieces.onto(rest, x ++ s)

# the batch a long request read in part ends in, with the request's
# bytes from the reads before
def part.raw(b: Batch, raw: List<&2, String>) -> Batch:
  match b:
    case Batch{reqs, tl, rest, err, need, x}:
      Batch{reqs, tl, rest, err, need, pieces.onto(raw, x)}

# a long request still in part: the bytes of s before its bulk not whole
# yet (at) go with those of the reads before
def part.more(p: Part, raw: List<&2, String>, +s: String, +l: Nat) -> Batch:
  match p:
    case Part{id, nm, more, acc, +at, +need, x}:
      Batch{Nil{}, 0, TailPart{Part{id, nm, more, acc, 0n, need, String.slice(s, 0n, at) <> raw}, String.slice(s, at, Nat.sub(l, at))}, None{}, need, s}
    case PartOf{q}:
      part.more(q, raw, s, l)

# the rest of a long request read in part, parsed: whole, it is the
# batch's first request; or still in part; or a protocol error (wbulks
# leaves no other)
def part.fin(o: One, raw: List<&2, String>, +s: String, +l: Nat) -> Batch:
  match o:
    case OneOk{B.Req{c, +h}, +j}:
      part.raw(win.go(1n+l, s, l, win.at(s, j, l, B.Req{c, h} <> Nil{}, R.tl.add(0, h))), raw)
    case OnePart{p}:
      part.more(p, raw, s, l)
    case OneBad{m}:
      Batch{Nil{}, 0, TailNone{}, Some{m}, 0n, s}
    case _:
      Batch{Nil{}, 0, TailNone{}, Some{"Protocol error: invalid bulk length"}, 0n, s}

def part.on(p: Part, +s: String, +l: Nat) -> Batch:
  match p:
    case Part{+id, nm, more, acc, at, need, raw}:
      +w = wnd.from(s, 0n, l)
      part.fin(req.of(id, nm, wbulks(more, s, l, w, 0n, 0n, wnd.bulk(w, 0n, s, 0n, l), acc)), raw, s, l)
    case PartOf{q}:
      part.on(q, s, l)

# the requests of s, a long request read in part first
def parse_part(p: Part, +s: String) -> Batch:
  +l = String.length(s)
  part.on(p, s, l)

# the requests of what the last parse left (t) and what came since (s)
def parse_tail(t: Tail, s: String) -> Batch:
  match t:
    case TailNone{}:
      parse_runs(s)
    case TailBytes{r}:
      parse_runs(r ++ s)
    case TailPart{p, r}:
      parse_part(p, r ++ s)
    case TailAuth{u}:
      parse_tail(u, s)
    case TailHeld{u, m}:
      parse_tail(u, s)

# Clients that must authenticate
# ------------------------------
# While a client must authenticate first (its server asks for a password,
# and it has not given one), Redis 7.2.16 reads its requests with two
# limits more (networking.c, processMultibulkBuffer, while authRequired):
# a count past 10 arguments, or a bulk's length past 16384 bytes, is a
# protocol error as soon as its line has come, before the bytes it
# announces, and the connection closes after the error. Inline requests
# have no such limits. What a client that has not authenticated sends is
# walked for the first request that breaks a limit, through the lines
# that have come, read as the parser reads them (line_at, len.read): a
# line not whole, or not right, ends the walk, as the parser waits for it
# or refuses it itself. Redis looks at each line once, when it has come:
# the walk passes over the lines whole in a kept tail's bytes, looked at
# (or let in) with them. The requests before that one are parsed as any
# client's, and the tail kept as such a client's (TailAuth); the bytes
# from it are held (TailHeld) until they have run, since an AUTH among
# them may let it in, and the actor says whether the client must still
# authenticate (server.bend, Clients that must authenticate): its server
# may ask for no password now. Bytes let in are parsed at once, the tail
# kept as such a client's still.

# the first request a client that must authenticate may not send: none,
# or the index where it starts, and its error
type Lim is Data:
  LimOk{}
  LimBad{at: Nat, msg: String}

# the walk's place: index j, in the request that starts at start, k of
# whose bulks are left (none at a request's start, where start is j); or
# its end
type LimAt is Data:
  LimAt{start: Nat, k: Nat, j: Nat}
  LimEnd{r: Lim}

def lim.mbulk() -> String:
  "Protocol error: unauthenticated multibulk length"

def lim.bulk() -> String:
  "Protocol error: unauthenticated bulk length"

# a count of n at the line from j to its '\r' at r: past 10 it breaks the
# limit; 0 is an empty request, which the parser skips
def lim.count.n(big: Bool, none: Bool, +n: Nat, +j: Nat, +r: Nat) -> LimAt:
  match big none:
    case True{} _:
      LimEnd{LimBad{j, lim.mbulk()}}
    case False{} True{}:
      LimAt{2n+r, 0n, 2n+r}
    case False{} False{}:
      LimAt{j, n, 2n+r}

# a count as array.count reads it: below 0 skipped, as Redis skips it;
# none, or one past INT_MAX, the parser refuses; one whose line is not
# new was looked at when it came
def lim.count.of(neg: Bool, ok: Bool, new: Bool, +n: Nat, +j: Nat, +r: Nat) -> LimAt:
  match neg ok:
    case True{} _:
      LimAt{2n+r, 0n, 2n+r}
    case False{} False{}:
      LimEnd{LimOk{}}
    case False{} True{}:
      lim.count.n(Bool.and(new, Nat.is_lt(10n, n)), Nat.is_eq(n, 0n), n, j, r)

def lim.count(ll: R.LL, +j: Nat, +r: Nat, +old: Nat) -> LimAt:
  match ll:
    case R.LL{neg, +hi, +lo}:
      lim.count.of(neg, R.ll.le(hi, lo, 2n, 147483647n), Nat.is_lt(old, 2n+r), Nat.add(Nat.mul(hi, 1000000000n), lo), j, r)
    case R.LLBad{}:
      LimEnd{LimOk{}}

def lim.line.at(+s: String, +j: Nat, +old: Nat, ln: Line) -> LimAt:
  match ln:
    case LineAt{+r}:
      lim.count(len.read(s, 1n+j, r), j, r, old)
    case _:
      LimEnd{LimOk{}}

# after an inline request whose '\n' is at k: the next request, unless
# none has come, or a NUL comes before it (inline.at)
def lim.inline.at(found: Bool, nul: Bool, +k: Nat) -> LimAt:
  match found nul:
    case True{} False{}:
      LimAt{1n+k, 0n, 1n+k}
    case _ _:
      LimEnd{LimOk{}}

# a request at index j: its count's line ('*'), or an inline request,
# which the limits leave alone, up to its '\n'
def lim.req(star: Bool, +s: String, +j: Nat, +l: Nat, +old: Nat) -> LimAt:
  match star:
    case True{}:
      lim.line.at(s, j, old, line_at(s, j, l))
    case False{}:
      +k = String.find(s, '\n', j)
      lim.inline.at(Nat.is_lt(k, l), Nat.is_lt(String.find(s, Chr{0}, j), k), k)

# the place after a bulk of the request at start, with m of its bulks
# left after it: the next bulk, or the next request
def lim.next(+m: Nat, +start: Nat, +next: Nat) -> LimAt:
  match m:
    case 0n:
      LimAt{next, 0n, next}
    case 1n+q:
      LimAt{start, 1n+q, next}

# after a bulk whose bytes and their "\r\n" end at next: a bulk not whole
# yet ends the walk, as the parser waits for it
def lim.after(whole: Bool, +start: Nat, +k: Nat, +next: Nat) -> LimAt:
  match whole k:
    case True{} 1n+m:
      lim.next(m, start, next)
    case _ _:
      LimEnd{LimOk{}}

# a bulk's length as head.len reads it (none, or one below 0 or past 512
# MB, the parser refuses): past 16384 bytes it breaks the limit, when its
# line is new
def lim.len.of(ok: Bool, big: Bool, +start: Nat, +k: Nat, +next: Nat, +l: Nat) -> LimAt:
  match ok big:
    case False{} _:
      LimEnd{LimOk{}}
    case True{} True{}:
      LimEnd{LimBad{start, lim.bulk()}}
    case True{} False{}:
      lim.after(Nat.is_le(next, l), start, k, next)

def lim.len(ll: R.LL, +start: Nat, +k: Nat, +r: Nat, +l: Nat, +old: Nat) -> LimAt:
  match ll:
    case R.LL{neg, +hi, +lo}:
      lim.len.of(Bool.and(Bool.not(neg), R.ll.le(hi, lo, 0n, 536870912n)), Bool.and(Nat.is_lt(old, 2n+r), Nat.is_lt(16384n, lo)), start, k, 4n+Nat.add(r, lo), l)
    case R.LLBad{}:
      LimEnd{LimOk{}}

# a bulk's line at index j, in the request at start, k of whose bulks
# are left: its '$' and its length, once the line has come
def lim.bulk.at(dollar: Bool, +s: String, +start: Nat, +k: Nat, +j: Nat, +l: Nat, +old: Nat, ln: Line) -> LimAt:
  match dollar ln:
    case True{} LineAt{+r}:
      lim.len(len.read(s, 1n+j, r), start, k, r, l, old)
    case _ _:
      LimEnd{LimOk{}}

# a step of the walk at index j: the end of what has come, a request's
# start, or one of its bulks
def lim.step(more: Bool, +s: String, +l: Nat, +old: Nat, +start: Nat, +k: Nat, +j: Nat) -> LimAt:
  match more k:
    case False{} _:
      LimEnd{LimOk{}}
    case True{} 0n:
      lim.req(U32.is_eq(String.code_at(s, j), 42), s, j, l, old)
    case True{} 1n+m:
      lim.bulk.at(U32.is_eq(String.code_at(s, j), 36), s, start, 1n+m, j, l, old, line_at(s, j, l))

# the walk from a place on: each step goes a byte on at least, so the
# bytes of s are enough fuel
def lim.go(fuel: Nat, +s: String, +l: Nat, +old: Nat, a: LimAt) -> Lim:
  match fuel a:
    case _ LimEnd{r}:
      r
    case 0n LimAt{start, k, j}:
      LimOk{}
    case 1n+f LimAt{+start, +k, +j}:
      lim.go(f, s, l, old, lim.step(Nat.is_lt(j, l), s, l, old, start, k, j))

# the first request of s a client that must authenticate may not send,
# the lines whole in its first old bytes looked at before
def lim.of(+s: String, +old: Nat) -> Lim:
  +l = String.length(s)
  lim.go(1n+l, s, l, old, LimAt{0n, 0n, 0n})

# whether an argument of a long request read in part is past 16384
# bytes (it was read before its client had to authenticate: a RESET came
# before it)
def lim.args(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Con{+x, rest}:
      Bool.or(Nat.is_lt(16384n, String.length(x)), lim.args(rest))

# a long request read in part, its bulk not whole yet at index 0 of s:
# its count (its name, the arguments before, that bulk and more after
# it), the arguments it has, then the walk from that bulk on
def lim.part.of(over: Bool, long: Bool, +more: Nat, +s: String) -> Lim:
  match over long:
    case True{} _:
      LimBad{0n, lim.mbulk()}
    case False{} True{}:
      LimBad{0n, lim.bulk()}
    case False{} False{}:
      +l = String.length(s)
      lim.go(1n+l, s, l, 0n, LimAt{0n, 1n+more, 0n})

def lim.part(p: Part, +s: String) -> Lim:
  match p:
    case Part{id, nm, +more, +acc, at, need, raw}:
      lim.part.of(Nat.is_lt(10n, 2n+Nat.add(List.length(&2, String, acc), more)), lim.args(nm <> acc), more, s)
    case PartOf{q}:
      lim.part(q, s)

# the walk of a long request read in part kept as such a client's, from
# its bulk not whole yet at index 0 of s on: its count and arguments, and
# the lines whole in the first old bytes, were looked at when they came
def lim.part.from(p: Part, +s: String, +old: Nat) -> Lim:
  match p:
    case Part{id, nm, +more, acc, at, need, raw}:
      +l = String.length(s)
      lim.go(1n+l, s, l, old, LimAt{0n, 1n+more, 0n})
    case PartOf{q}:
      lim.part.from(q, s, old)

# the request a tail holds, as a client that must authenticate may send
# it: one its lines came for before the client had to (a RESET before
# them), or held bytes it may not send
def lim.held(t: Tail) -> Lim:
  match t:
    case TailBytes{+r}:
      lim.of(r, 0n)
    case TailPart{p, +r}:
      lim.part(p, r)
    case TailHeld{u, m}:
      LimBad{0n, m}
    case _:
      LimOk{}

# a parse for a client that must authenticate: the requests before the
# first it may not send, and the bytes from it, held with its error
def auth.held(b: Batch, h: Tail, msg: String) -> Batch:
  match b:
    case Batch{reqs, tl, r, err, need, raw}:
      Batch{reqs, tl, TailHeld{h, msg}, err, 0n, raw}

# all the requests, the tail kept as such a client's
def auth.kept(b: Batch) -> Batch:
  match b:
    case Batch{reqs, tl, rest, err, need, raw}:
      Batch{reqs, tl, TailAuth{rest}, err, need, raw}

def auth.cut(lim: Lim, +s: String) -> Batch:
  match lim:
    case LimOk{}:
      auth.kept(parse_runs(s))
    case LimBad{+at, msg}:
      +l = String.length(s)
      auth.held(parse_runs(String.slice(s, 0n, at)), TailBytes{String.slice(s, at, Nat.sub(l, at))}, msg)

# a long request read in part that breaks a limit is held whole, as the
# first request of what came; one after it is held from where it starts
def auth.part.cut(first: Bool, +p: Part, +s: String, +at: Nat, msg: String) -> Batch:
  match first:
    case True{}:
      Batch{Nil{}, 0, TailHeld{TailPart{p, s}, msg}, None{}, 0n, SNil{}}
    case False{}:
      +l = String.length(s)
      auth.held(parse_part(p, String.slice(s, 0n, at)), TailBytes{String.slice(s, at, Nat.sub(l, at))}, msg)

def auth.part(lim: Lim, +p: Part, +s: String) -> Batch:
  match lim:
    case LimOk{}:
      auth.kept(parse_part(p, s))
    case LimBad{+at, msg}:
      auth.part.cut(Nat.is_eq(at, 0n), p, s, at, msg)

# the requests of what the last parse left (t) and what came since (s),
# for a client that has not authenticated
def parse_auth(t: Tail, s: String) -> Batch:
  match t:
    case TailNone{}:
      +x = s
      auth.cut(lim.of(x, 0n), x)
    case TailBytes{+r}:
      +x = r ++ s
      auth.cut(lim.of(x, String.length(r)), x)
    case TailPart{+p, +r}:
      +x = r ++ s
      auth.part(lim.part.from(p, x, String.length(r)), p, x)
    case TailAuth{u}:
      parse_auth(u, s)
    case TailHeld{u, m}:
      auth.kept(parse_tail(u, s))

# the tail of a client that must authenticate: the request it holds,
# held with its error when it breaks a limit
def tail.must(lim: Lim, t: Tail) -> Tail:
  match lim:
    case LimOk{}:
      TailAuth{t}
    case LimBad{at, msg}:
      TailAuth{TailHeld{t, msg}}

def tail.must.of(+t: Tail) -> Tail:
  tail.must(lim.held(t), t)

# a tail after an answer to a client that has not authenticated
# (AnsAuth), kept as such a client's: the bytes it held, let in when the
# client need not authenticate, else held still; and when it must, the
# request a tail holds looked at (one its lines came for before the
# client had to: a RESET before them)
def tail.auth(must: Bool, t: Tail) -> Tail:
  match must t:
    case False{} TailHeld{u, m}:
      TailHeld{u, m}
    case False{} TailAuth{u}:
      TailAuth{u}
    case False{} u:
      TailAuth{u}
    case True{} TailHeld{u, m}:
      TailAuth{TailHeld{u, m}}
    case True{} TailAuth{u}:
      tail.must.of(u)
    case True{} u:
      tail.must.of(u)

# Arguments as sent
# ------------------
# MONITOR shows each command with its arguments as its client sent them
# (server.bend, MONITOR): the bytes of a batch are read again, the actor
# reading them only while a client monitors, into the arguments of each
# request, its name first, as the requests were read (one, above): the
# same requests, an empty one skipped, up to the first that is not whole
# or not right, which the batch did not hold either.

# one request's arguments; none for an empty request; or the end
type Av1 is Data:
  AvOk{args: List<&2, String>, next: Nat}
  AvSkip{next: Nat}
  AvEnd{}

def av.args(a: Args) -> Av1:
  match a:
    case ArgsOk{args, j}:
      AvOk{args, j}
    case _:
      AvEnd{}

def av.array.if(n: Nat, +s: String, +l: Nat, +j: Nat, ok: Bool) -> Av1:
  match n ok:
    case 0n True{}:
      AvSkip{j}
    case 1n+m True{}:
      av.args(args.at(1n+m, s, l, j))
    case _ False{}:
      AvEnd{}

def av.array.small(ok: Bool, +hi: Nat, +lo: Nat, +s: String, +l: Nat, +j: Nat) -> Av1:
  match ok:
    case True{}:
      av.array.if(Nat.add(Nat.mul(hi, 1000000000n), lo), s, l, j, True{})
    case False{}:
      AvEnd{}

def av.array.signed(neg: Bool, +hi: Nat, +lo: Nat, +s: String, +l: Nat, +j: Nat) -> Av1:
  match neg:
    case True{}:
      AvSkip{j}
    case False{}:
      av.array.small(R.ll.le(hi, lo, 2n, 147483647n), hi, lo, s, l, j)

def av.array.count(ll: R.LL, +s: String, +l: Nat, +j: Nat) -> Av1:
  match ll:
    case R.LL{neg, +hi, +lo}:
      av.array.signed(neg, hi, lo, s, l, j)
    case R.LLBad{}:
      AvEnd{}

def av.array.line(+s: String, +i: Nat, +l: Nat, ln: Line) -> Av1:
  match ln:
    case LineAt{+r}:
      av.array.count(len.read(s, 1n+i, r), s, l, 2n+r)
    case _:
      AvEnd{}

def av.array(+s: String, +i: Nat, +l: Nat, nl: NumLine) -> Av1:
  match nl:
    case NumOk{+n, +j}:
      av.array.if(n, s, l, j, Nat.is_le(n, 2147483647n))
    case NumMore{}:
      AvEnd{}
    case NumBad{}:
      av.array.line(s, i, l, line_at(s, i, l))

def av.words(ws: List<&2, String>, +next: Nat) -> Av1:
  match ws:
    case Nil{}:
      AvSkip{next}
    case Con{w, rest}:
      AvOk{w <> rest, next}

def av.inline.of(m: Maybe<&2, List<&2, String>>, +next: Nat) -> Av1:
  match m:
    case Some{ws}:
      av.words(List.reverse(&2, String, ws), next)
    case None{}:
      AvEnd{}

def av.inline.line(+line: String, +n: Nat, nul: Bool, +next: Nat) -> Av1:
  match nul:
    case True{}:
      AvEnd{}
    case False{}:
      av.inline.of(sp.run(Nat.mul(2n, 1n+n), Go{MBlank{}, inline.text(line, n, U32.is_eq(String.code_at(line, Nat.sub(n, 1n)), 13)), SNil{}, Nil{}}), next)

def av.inline.at(+s: String, +i: Nat, +k: Nat, +l: Nat, found: Bool) -> Av1:
  match found:
    case True{}:
      +n = Nat.sub(k, i)
      +line = String.slice(s, i, n)
      av.inline.line(line, n, Nat.is_lt(String.find(line, Chr{0}, 0n), n), 1n+k)
    case False{}:
      AvEnd{}

def av.head(+s: String, +i: Nat, +l: Nat, star: Bool, end: Bool) -> Av1:
  match star end:
    case True{} _:
      av.array(s, i, l, num_at(s, 1n+i))
    case False{} True{}:
      AvEnd{}
    case False{} False{}:
      +k = String.find(s, '\n', i)
      av.inline.at(s, i, k, l, Nat.is_lt(k, l))

# the arguments of the request of s at index i, l the length of s
def av.one(+s: String, +i: Nat, +l: Nat) -> Av1:
  +c = String.code_at(s, i)
  av.head(s, i, l, U32.is_eq(c, 42), U32.is_eq(c, 4294967295))

def av.go(fuel: Nat, +s: String, +l: Nat, a: Av1, acc: List<&2, List<&2, String>>) -> List<&2, List<&2, String>>:
  match fuel a:
    case 1n+f AvOk{args, +j}:
      av.go(f, s, l, av.one(s, j, l), args <> acc)
    case 1n+f AvSkip{+j}:
      av.go(f, s, l, av.one(s, j, l), acc)
    case _ _:
      List.reverse(&2, List<&2, String>, acc)

# the arguments of each request of s, in order; each request takes a byte
# or more, so the length of s is enough fuel
def argvs(+s: String) -> List<&2, List<&2, String>>:
  +l = String.length(s)
  av.go(1n+l, s, l, av.one(s, 0n, l), Nil{})

# An argument as Redis quotes it (sdscatrepr): in double quotes, a \ or "
# with a \ before it, a newline, return, tab, bell or backspace as \n,
# \r, \t, \a or \b, a printable byte as it is, and any other as \x and
# two hex digits. The quoted argument is built backwards, a byte at a
# time, then turned around.
def repr.hex(+d: U32) -> Char:
  Chr{Bool.pick(U32, U32.is_lt(d, 10), U32.add(d, 48), U32.add(d, 87))}

def repr.other(print: Bool, +x: U32, acc: String) -> String:
  match print:
    case True{}:
      SCon{Chr{x}, acc}
    case False{}:
      SCon{repr.hex(U32.and(x, 15)), SCon{repr.hex(U32.shrn(x, 4n)), SCon{'x', SCon{'\\', acc}}}}

def repr.esc(none: Bool, +e: U32, +x: U32, acc: String) -> String:
  match none:
    case True{}:
      repr.other(Bool.and(U32.is_le(32, x), U32.is_le(x, 126)), x, acc)
    case False{}:
      SCon{Chr{e}, SCon{'\\', acc}}

# the letter after the \ that a byte goes out as, or 0 for none
def repr.code(+x: U32) -> U32:
  Bool.pick(U32, Bool.or(U32.is_eq(x, 92), U32.is_eq(x, 34)), x,
  Bool.pick(U32, U32.is_eq(x, 10), 110,
  Bool.pick(U32, U32.is_eq(x, 13), 114,
  Bool.pick(U32, U32.is_eq(x, 9), 116,
  Bool.pick(U32, U32.is_eq(x, 7), 97,
  Bool.pick(U32, U32.is_eq(x, 8), 98, 0))))))

def repr.go(s: String, acc: String) -> String:
  match s:
    case SNil{}:
      String.reverse(SCon{'"', acc})
    case SCon{Chr{+x}, t}:
      +e = repr.code(x)
      repr.go(t, repr.esc(U32.is_eq(e, 0), e, x, acc))

def repr(s: String) -> String:
  repr.go(s, "\"")

# arguments quoted, a space between two: each goes before those after it
# (xs, last first)
def reprs.go(xs: List<&2, String>, out: String) -> String:
  match xs:
    case Nil{}:
      out
    case Con{x, Nil{}}:
      repr(x) ++ out
    case Con{x, rest}:
      reprs.go(rest, " " ++ repr(x) ++ out)

def reprs(xs: List<&2, String>) -> String:
  reprs.go(List.reverse(&2, String, xs), "")

# Replies
# -------
# A batch's replies are written from its end: each part goes before what
# follows it (out), into the room of the chunk that holds it, so a batch
# of short replies builds one chunk.

def crlf() -> String:
  "\r\n"

# An error goes out on one line, as Redis's error formatting sends it: a
# CR or LF in its text (an argument it quotes, a byte the parser did not
# expect) goes out as a space (R.no_newlines). Nearly every text has
# neither, and goes out as it is.
def err_line.if(nl: Bool, s: String) -> String:
  match nl:
    case True{}:
      R.no_newlines(s)
    case False{}:
      s

def err_line(+s: String) -> String:
  +l = String.length(s)
  err_line.if(Bool.or(Nat.is_lt(String.find(s, '\r', 0n), l), Nat.is_lt(String.find(s, '\n', 0n), l)), s)

def bulk_into(+s: String, out: String) -> String:
  "$" ++ Nat.show(String.length(s)) ++ crlf() ++ s ++ crlf() ++ out

def int_into(i: R.Int, out: String) -> String:
  match i:
    case R.IPos{n}:
      ":" ++ Nat.show(n) ++ crlf() ++ out
    case R.INeg{n}:
      ":-" ++ Nat.show(1n+n) ++ crlf() ++ out

# an aggregate's header: its mark and its count
def agg_into(+m: String, +n: Nat, out: String) -> String:
  m ++ Nat.show(n) ++ crlf() ++ out

# RESP2: replies before out; an array's items come before the replies
# after it. A double and a verbatim text go out as bulks, a map, a set,
# pairs and a push as arrays (pairs with their items flat), a map of keys
# as an array of its pairs, each an array of two. A switch of protocol
# goes out as its reply: the switch itself is the batch's (encode_as).
def encode_onto(rs: List<&2, R.Reply>, out: String) -> String:
  match rs:
    case Nil{}:
      out
    case Con{R.RStatus{s}, rest}:
      "+" ++ s ++ crlf() ++ encode_onto(rest, out)
    case Con{R.RError{s}, rest}:
      "-" ++ err_line(s) ++ crlf() ++ encode_onto(rest, out)
    case Con{R.RInt{i}, rest}:
      int_into(i, encode_onto(rest, out))
    case Con{R.RBulk{s}, rest}:
      bulk_into(s, encode_onto(rest, out))
    case Con{R.RNull{}, rest}:
      "$-1\r\n" ++ encode_onto(rest, out)
    case Con{R.RArray{+xs}, rest}:
      "*" ++ Nat.show(List.length(&2, R.Reply, xs)) ++ crlf() ++ encode_onto(xs, encode_onto(rest, out))
    case Con{R.RIntS{s}, rest}:
      ":" ++ s ++ crlf() ++ encode_onto(rest, out)
    case Con{R.RNullA{}, rest}:
      "*-1\r\n" ++ encode_onto(rest, out)
    case Con{R.RDbl{s}, rest}:
      bulk_into(s, encode_onto(rest, out))
    case Con{R.RMap{+xs}, rest}:
      agg_into("*", List.length(&2, R.Reply, xs), encode_onto(xs, encode_onto(rest, out)))
    case Con{R.RSet{+xs}, rest}:
      agg_into("*", List.length(&2, R.Reply, xs), encode_onto(xs, encode_onto(rest, out)))
    case Con{R.RPairs{+xs}, rest}:
      agg_into("*", Nat.mul(List.length(&2, R.Reply, xs), 2n), encode_onto(xs, encode_onto(rest, out)))
    case Con{R.RPair{xs}, rest}:
      encode_onto(xs, encode_onto(rest, out))
    case Con{R.RVerb{s}, rest}:
      bulk_into(s, encode_onto(rest, out))
    case Con{R.RPush{+xs}, rest}:
      agg_into("*", List.length(&2, R.Reply, xs), encode_onto(xs, encode_onto(rest, out)))
    case Con{R.RSw{r3, xs}, rest}:
      encode_onto(xs, encode_onto(rest, out))
    case Con{R.RKMap{+xs}, rest}:
      agg_into("*", List.length(&2, R.Reply, xs), encode_onto(xs, encode_onto(rest, out)))
    case Con{R.RKPair{+xs}, rest}:
      agg_into("*", List.length(&2, R.Reply, xs), encode_onto(xs, encode_onto(rest, out)))
    case Con{R.RRaw{s}, rest}:
      s ++ encode_onto(rest, out)
    case Con{R.RArrayN{+n, xs}, rest}:
      agg_into("*", n, encode_onto(xs, encode_onto(rest, out)))

# RESP3 (Redis's networking.c): a null, and a null array, as _; a double
# after a comma; a map's pairs counted after %, a set's items after ~, a
# push's after >; pairs as an array of arrays of two; a verbatim text as
# = with its length and txt: before it; a map of keys as a map, its
# pairs counted after % and each pair's two items flat. The rest as
# RESP2.
def encode3_onto(rs: List<&2, R.Reply>, out: String) -> String:
  match rs:
    case Nil{}:
      out
    case Con{R.RStatus{s}, rest}:
      "+" ++ s ++ crlf() ++ encode3_onto(rest, out)
    case Con{R.RError{s}, rest}:
      "-" ++ err_line(s) ++ crlf() ++ encode3_onto(rest, out)
    case Con{R.RInt{i}, rest}:
      int_into(i, encode3_onto(rest, out))
    case Con{R.RBulk{s}, rest}:
      bulk_into(s, encode3_onto(rest, out))
    case Con{R.RNull{}, rest}:
      "_\r\n" ++ encode3_onto(rest, out)
    case Con{R.RArray{+xs}, rest}:
      agg_into("*", List.length(&2, R.Reply, xs), encode3_onto(xs, encode3_onto(rest, out)))
    case Con{R.RIntS{s}, rest}:
      ":" ++ s ++ crlf() ++ encode3_onto(rest, out)
    case Con{R.RNullA{}, rest}:
      "_\r\n" ++ encode3_onto(rest, out)
    case Con{R.RDbl{s}, rest}:
      "," ++ s ++ crlf() ++ encode3_onto(rest, out)
    case Con{R.RMap{+xs}, rest}:
      agg_into("%", Nat.div(List.length(&2, R.Reply, xs), 2n), encode3_onto(xs, encode3_onto(rest, out)))
    case Con{R.RSet{+xs}, rest}:
      agg_into("~", List.length(&2, R.Reply, xs), encode3_onto(xs, encode3_onto(rest, out)))
    case Con{R.RPairs{+xs}, rest}:
      agg_into("*", List.length(&2, R.Reply, xs), encode3_onto(xs, encode3_onto(rest, out)))
    case Con{R.RPair{+xs}, rest}:
      agg_into("*", List.length(&2, R.Reply, xs), encode3_onto(xs, encode3_onto(rest, out)))
    case Con{R.RVerb{+s}, rest}:
      "=" ++ Nat.show(Nat.add(String.length(s), 4n)) ++ crlf() ++ "txt:" ++ s ++ crlf() ++ encode3_onto(rest, out)
    case Con{R.RPush{+xs}, rest}:
      agg_into(">", List.length(&2, R.Reply, xs), encode3_onto(xs, encode3_onto(rest, out)))
    case Con{R.RSw{r3, xs}, rest}:
      encode3_onto(xs, encode3_onto(rest, out))
    case Con{R.RKMap{+xs}, rest}:
      agg_into("%", List.length(&2, R.Reply, xs), encode3_onto(xs, encode3_onto(rest, out)))
    case Con{R.RKPair{xs}, rest}:
      encode3_onto(xs, encode3_onto(rest, out))
    case Con{R.RRaw{s}, rest}:
      s ++ encode3_onto(rest, out)
    case Con{R.RArrayN{+n, xs}, rest}:
      agg_into("*", n, encode3_onto(xs, encode3_onto(rest, out)))

def encode(r: R.Reply) -> String:
  encode_onto([r], SNil{})

def encode_all(rs: List<&2, R.Reply>) -> String:
  encode_onto(rs, SNil{})

def encode3_all(rs: List<&2, R.Reply>) -> String:
  encode3_onto(rs, SNil{})

# replies before out, in RESP3 (r3) or RESP2
def encode_in(r3: Bool, rs: List<&2, R.Reply>, out: String) -> String:
  match r3:
    case True{}:
      encode3_onto(rs, out)
    case False{}:
      encode_onto(rs, out)

# A batch's replies up to its first switch of protocol (newest first),
# then the switch's protocol and the replies from it on (its own first).
# HELLO's reply and RESET's switch: Redis writes each in the protocol it
# switches to, and the replies after it too. A switch inside an array
# (HELLO queued in MULTI) holds for its reply alone.
type SwCut is Data:
  SwNone{pre: List<&2, R.Reply>}
  SwAt{pre: List<&2, R.Reply>, r3: Bool, post: List<&2, R.Reply>}

def sw.cut(rs: List<&2, R.Reply>, acc: List<&2, R.Reply>) -> SwCut:
  match rs:
    case Nil{}:
      SwNone{acc}
    case Con{R.RSw{p, xs}, rest}:
      SwAt{acc, p, List.append(&2, R.Reply, xs, rest)}
    case Con{x, rest}:
      sw.cut(rest, x <> acc)

# replies before out, starting in RESP3 (r3) or RESP2, each switch taken
# for the replies from it on; each switch takes one, so the number of
# replies is enough fuel
def encode_as.go(fuel: Nat, r3: Bool, c: SwCut, out: String) -> String:
  match fuel c:
    case _ SwNone{pre}:
      encode_in(r3, List.reverse(&2, R.Reply, pre), out)
    case 0n SwAt{pre, p, post}:
      encode_in(r3, List.reverse(&2, R.Reply, pre), encode_in(p, post, out))
    case 1n+f SwAt{pre, p, post}:
      encode_in(r3, List.reverse(&2, R.Reply, pre), encode_as.go(f, p, sw.cut(post, Nil{}), out))

# a batch's replies, its client in RESP3 (r3) or RESP2 as it began
def encode_as(r3: Bool, +rs: List<&2, R.Reply>) -> String:
  encode_as.go(List.length(&2, R.Reply, rs), r3, sw.cut(rs, Nil{}), SNil{})
