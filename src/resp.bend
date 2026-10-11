# resp.bend: the RESP2 wire format. Requests are arrays of bulk strings
# (what redis-cli and every client library send) or inline lines (what a
# human types into nc); replies are encoded per their kind. A buffer may
# hold several pipelined requests and end in the middle of one: parse
# returns the complete ones and keeps the rest for the next read.
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
# (String.slice), and drops the parsed bytes once, at the end. The buffer
# is only lent to it, so nothing is shared and nothing is rebuilt char by
# char.

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

# the arguments of a request after its name
type Args is Data:
  ArgsOk{args: List<&2, String>, next: Nat}
  ArgsMore{need: Nat}
  ArgsBad{msg: String}

# one request: its command, with the hash of its key for the hints (B.Req),
# or none for an empty one (*0, or a blank inline line), which Redis skips
# without a reply
type One is Data:
  OneOk{req: B.Req, next: Nat}
  OneNone{next: Nat}
  OneMore{need: Nat}
  OneBad{msg: String}

# a buffer's worth of requests: the complete ones, newest first (as the
# parser meets them, each put before the ones it read already; the server
# puts them in order in the same pass that takes their commands and
# hashes apart, B.unzip), and how many they are (for INFO), the unparsed
# tail, a protocol error that ends the connection, if any, and how many
# bytes the tail needs at least before a parse can make progress
type Batch is Data:
  Batch{reqs: List<&2, B.Req>, n: U32, rest: String, err: Maybe<&2, String>, need: Nat}

# Lexing
# ------

# the number line at index i, its number and its length with the "\r\n"
# (String.dec_line_at: a length of 0 when it is bad, of 1 when the buffer
# ends first and the line waits for the rest)
def num.of(+i: Nat, vr: Nat & Nat) -> NumLine:
  match vr:
    case (v, 0n):
      NumBad{}
    case (v, 1n):
      NumMore{}
    case (v, 2n+n):
      NumOk{v, 2n+Nat.add(i, n)}

# the number line of s at index i: 1 to 10 digits (the lengths Redis takes
# have at most 9), then "\r\n", read in place
def num_at(+s: String, +i: Nat) -> NumLine:
  num.of(i, String.dec_line_at(s, i))

# the n bytes of a bulk at index j: copied out (String.slice) when the
# buffer holds them and their "\r\n"; short is how many bytes it lacks
def bulk.fin(+s: String, +n: Nat, +j: Nat, ok: Bool, short: Nat, crlf: Bool) -> Bulk:
  match ok short crlf:
    case False{} _ _:
      BulkBad{"Protocol error: invalid bulk length"}
    case True{} 0n True{}:
      BulkOk{String.slice(s, j, n), 2n+Nat.add(j, n)}
    case True{} 0n False{}:
      BulkBad{"Protocol error: expected '\r\n' after bulk data"}
    case True{} 1n+k _:
      BulkMore{1n+k}

# a bulk of at most 512MB, as Redis allows
def bulk.body(+s: String, +l: Nat, nl: NumLine) -> Bulk:
  match nl:
    case NumOk{+n, +j}:
      +e = Nat.add(j, n)
      +crlf = Bool.and(U32.is_eq(String.code_at(s, e), 13), U32.is_eq(String.code_at(s, 1n+e), 10))
      bulk.fin(s, n, j, Nat.is_le(n, 536870912n), Nat.sub(2n+e, l), crlf)
    case NumMore{}:
      BulkMore{1n}
    case NumBad{}:
      BulkBad{"Protocol error: invalid bulk length"}

def bulk.head(+s: String, +i: Nat, +l: Nat, +c: U32, dollar: Bool, end: Bool) -> Bulk:
  match dollar end:
    case True{} _:
      bulk.body(s, l, num_at(s, 1n+i))
    case False{} True{}:
      BulkMore{1n}
    case False{} False{}:
      BulkBad{"Protocol error: expected '$', got '" ++ SCon{Chr{c}, SNil{}} ++ "'"}

# the bulk of s at index i, l the length of s
def bulk_at(+s: String, +i: Nat, +l: Nat) -> Bulk:
  +c = String.code_at(s, i)
  bulk.head(s, i, l, c, U32.is_eq(c, 36), U32.is_eq(c, 4294967295))

# one key: the bulk of a command's key, with its hash read off the buffer
# (String.hash_at, which is KV.hash of the key)
type Key is Data:
  KeyOk{key: String, hash: U32, next: Nat}
  KeyMore{need: Nat}
  KeyBad{msg: String}

def key.fin(+s: String, +n: Nat, +j: Nat, ok: Bool, short: Nat, crlf: Bool) -> Key:
  match ok short crlf:
    case False{} _ _:
      KeyBad{"Protocol error: invalid bulk length"}
    case True{} 0n True{}:
      KeyOk{String.slice(s, j, n), String.hash_at(s, j, n), 2n+Nat.add(j, n)}
    case True{} 0n False{}:
      KeyBad{"Protocol error: expected '\r\n' after bulk data"}
    case True{} 1n+k _:
      KeyMore{1n+k}

def key.body(+s: String, +l: Nat, nl: NumLine) -> Key:
  match nl:
    case NumOk{+n, +j}:
      +e = Nat.add(j, n)
      +crlf = Bool.and(U32.is_eq(String.code_at(s, e), 13), U32.is_eq(String.code_at(s, 1n+e), 10))
      key.fin(s, n, j, Nat.is_le(n, 536870912n), Nat.sub(2n+e, l), crlf)
    case NumMore{}:
      KeyMore{1n}
    case NumBad{}:
      KeyBad{"Protocol error: invalid bulk length"}

def key.head(+s: String, +i: Nat, +l: Nat, +c: U32, dollar: Bool, end: Bool) -> Key:
  match dollar end:
    case True{} _:
      key.body(s, l, num_at(s, 1n+i))
    case False{} True{}:
      KeyMore{1n}
    case False{} False{}:
      KeyBad{"Protocol error: expected '$', got '" ++ SCon{Chr{c}, SNil{}} ++ "'"}

# the key bulk of s at index i, l the length of s
def key_at(+s: String, +i: Nat, +l: Nat) -> Key:
  +c = String.code_at(s, i)
  key.head(s, i, l, c, U32.is_eq(c, 36), U32.is_eq(c, 4294967295))

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

# the m bulks of a request's arguments at index j
def args.at(m: Nat, +s: String, +l: Nat, +j: Nat) -> Args:
  match m:
    case 0n:
      ArgsOk{Nil{}, j}
    case 1n+k:
      bulks(k, s, l, bulk_at(s, j, l), Nil{})

# a command of number id named nm (as the client spelled it, for an
# unknown one), from its arguments: from id 40 on, a command of the
# connection or of the server (R.parse_sess)
def req.mk(own: Bool, +id: Nat, +nm: String, +args: List<&2, String>) -> B.Req:
  match own:
    case True{}:
      B.Req{R.Own{R.parse_sess(id, nm, args)}, 0}
    case False{}:
      B.Req{R.parse_id(id, nm, args), B.args_hash(args)}

def req.of(+id: Nat, +nm: String, a: Args) -> One:
  match a:
    case ArgsOk{+args, j}:
      OneOk{req.mk(Nat.is_le(40n, id), id, nm, args), j}
    case ArgsMore{k}:
      OneMore{k}
    case ArgsBad{msg}:
      OneBad{msg}

# GET k
def get.of(b: Key) -> One:
  match b:
    case KeyOk{k, h, j}:
      OneOk{B.Req{R.Get{k}, h}, j}
    case KeyMore{n}:
      OneMore{n}
    case KeyBad{msg}:
      OneBad{msg}

# SET k v
def set.val(k: String, h: U32, b: Bulk) -> One:
  match b:
    case BulkOk{v, j}:
      OneOk{B.Req{R.Set{k, v}, h}, j}
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
      OneOk{B.Req{R.IncrBy{k, R.IPos{1n}}, h}, j}
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

# a multibulk count below zero: Redis skips the request, as it skips *0
def array.neg(nl: NumLine) -> One:
  match nl:
    case NumOk{n, j}:
      OneNone{j}
    case NumMore{}:
      OneMore{1n}
    case NumBad{}:
      OneBad{"Protocol error: invalid multibulk length"}

def array.bad(+s: String, +i: Nat, neg: Bool) -> One:
  match neg:
    case True{}:
      array.neg(num_at(s, 2n+i))
    case False{}:
      OneBad{"Protocol error: invalid multibulk length"}

def array(+s: String, +i: Nat, +l: Nat, nl: NumLine) -> One:
  match nl:
    case NumOk{+n, +j}:
      array.if(n, s, l, j, Nat.is_le(n, 2147483647n))
    case NumMore{}:
      OneMore{1n}
    case NumBad{}:
      array.bad(s, i, U32.is_eq(String.code_at(s, 1n+i), 45))

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

# a batch's requests before its tail is cut off, newest first, and how
# many they are: at is the index where the tail starts, the first request
# not parsed on
type Cut is Data:
  Cut{reqs: List<&2, B.Req>, n: U32, at: Nat, err: Maybe<&2, String>, need: Nat}

# every complete request of s from index i on, put before acc (n of
# them): o is the parse of the one at i; each request takes at least one
# byte, so the length of the buffer is enough fuel
def batch.go(fuel: Nat, +s: String, +l: Nat, +i: Nat, o: One, acc: List<&2, B.Req>, n: U32) -> Cut:
  match fuel o:
    case 0n _:
      Cut{acc, n, i, None{}, 1n}
    case 1n+f OneNone{+j}:
      batch.go(f, s, l, j, one(s, j, l), acc, n)
    case 1n+f OneOk{req, +j}:
      batch.go(f, s, l, j, one(s, j, l), req <> acc, U32.add(n, 1))
    case 1n+f OneMore{k}:
      Cut{acc, n, i, None{}, k}
    case 1n+f OneBad{m}:
      Cut{acc, n, l, Some{m}, 0n}

# the tail is what follows the parsed requests: s is dropped up to it
def batch.fin(c: Cut, s: String) -> Batch:
  match c:
    case Cut{reqs, n, at, err, need}:
      Batch{reqs, n, String.drop(s, at), err, need}

# the requests of s put before acc (n requests read before them, newest
# first): fuel must be at least the number of requests in s, which a
# reader that knows how many bytes it has passes; parse counts them itself
def parse_onto(fuel: Nat, +s: String, acc: List<&2, B.Req>, n: U32) -> Batch:
  +l = String.length(s)
  batch.fin(batch.go(fuel, s, l, 0n, one(s, 0n, l), acc, n), s)

def parse(+s: String) -> Batch:
  parse_onto(1n+String.length(s), s, Nil{}, 0)

# Long buffers
# ------------
# A packed String keeps at most 2048 bytes in a run, and reading it by
# index past its first run walks the runs from its start: String.code_at,
# find and slice are fast on one run only. A buffer longer than a run is
# parsed a window of at most 2048 bytes at a time, each window a copy of
# its own in one run (String.slice), from the first byte the window before
# did not parse; the requests of all the windows make one batch. A request
# longer than a window is parsed in the rest of the buffer as it is: that
# happens once, when all its bytes have come.

def win.max() -> Nat:
  2048n

# a window's parse, judged: the last one (the buffer's end, or a protocol
# error), one that parsed nothing (a request longer than a window: the
# rest of the buffer is parsed whole from at), or one to go on after; the
# requests of the windows so far, newest first, and how many they are,
# are in each
type Win is Data:
  WinLast{b: Batch}
  WinBig{reqs: List<&2, B.Req>, n: U32, at: Nat}
  WinOn{reqs: List<&2, B.Req>, n: U32, next: Nat}

def win.on(reqs: List<&2, B.Req>, n: U32, +at: Nat, +done: Nat, stuck: Bool) -> Win:
  match stuck:
    case True{}:
      WinBig{reqs, n, at}
    case False{}:
      WinOn{reqs, n, Nat.add(at, done)}

def win.judge(reqs: List<&2, B.Req>, n: U32, rest: String, err: Maybe<&2, String>, need: Nat, +at: Nat, +done: Nat, last: Bool) -> Win:
  match err last:
    case Some{m} _:
      WinLast{Batch{reqs, n, rest, Some{m}, need}}
    case None{} True{}:
      WinLast{Batch{reqs, n, rest, None{}, need}}
    case None{} False{}:
      win.on(reqs, n, at, done, Nat.is_eq(done, 0n))

# the window of w bytes at index at, of a buffer of l bytes, and its parse
def win.of(b: Batch, +at: Nat, +w: Nat, +l: Nat) -> Win:
  match b:
    case Batch{reqs, n, +rest, err, need}:
      win.judge(reqs, n, rest, err, need, at, Nat.sub(w, String.length(rest)), Nat.is_le(l, Nat.add(at, w)))

# the window at index at, its requests put before acc, the n of the
# windows before it
def win.at(+s: String, +at: Nat, +l: Nat, acc: List<&2, B.Req>, n: U32) -> Win:
  +w = Nat.min(win.max(), Nat.sub(l, at))
  win.of(parse_onto(1n+w, String.slice(s, at, w), acc, n), at, w, l)

# the windows of s from the one judged in w on; each window parses one
# byte or more, so the length of s is enough fuel
def win.go(n: Nat, +s: String, +l: Nat, w: Win) -> Batch:
  match n w:
    case _ WinLast{b}:
      b
    case _ WinBig{reqs, c, +at}:
      parse_onto(1n+Nat.sub(l, at), String.drop(s, at), reqs, c)
    case 0n WinOn{reqs, c, +at}:
      parse_onto(1n+Nat.sub(l, at), String.drop(s, at), reqs, c)
    case 1n+m WinOn{reqs, c, +at}:
      win.go(m, s, l, win.at(s, at, l, reqs, c))

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

# Replies
# -------
# A batch's replies are written from its end: each part goes before what
# follows it (out), into the room of the chunk that holds it, so a batch
# of short replies builds one chunk.

def crlf() -> String:
  "\r\n"

def bulk_into(+s: String, out: String) -> String:
  "$" ++ Nat.show(String.length(s)) ++ crlf() ++ s ++ crlf() ++ out

def int_into(i: R.Int, out: String) -> String:
  match i:
    case R.IPos{n}:
      ":" ++ Nat.show(n) ++ crlf() ++ out
    case R.INeg{n}:
      ":-" ++ Nat.show(1n+n) ++ crlf() ++ out

# replies before out; an array's items come before the replies after it
def encode_onto(rs: List<&2, R.Reply>, out: String) -> String:
  match rs:
    case Nil{}:
      out
    case Con{R.RStatus{s}, rest}:
      "+" ++ s ++ crlf() ++ encode_onto(rest, out)
    case Con{R.RError{s}, rest}:
      "-" ++ s ++ crlf() ++ encode_onto(rest, out)
    case Con{R.RInt{i}, rest}:
      int_into(i, encode_onto(rest, out))
    case Con{R.RBulk{s}, rest}:
      bulk_into(s, encode_onto(rest, out))
    case Con{R.RNull{}, rest}:
      "$-1\r\n" ++ encode_onto(rest, out)
    case Con{R.RArray{+xs}, rest}:
      "*" ++ Nat.show(List.length(&2, R.Reply, xs)) ++ crlf() ++ encode_onto(xs, encode_onto(rest, out))

def encode(r: R.Reply) -> String:
  encode_onto([r], SNil{})

def encode_all(rs: List<&2, R.Reply>) -> String:
  encode_onto(rs, SNil{})
