# rdb.bend: the payloads of DUMP and RESTORE, as Redis 7.0.15 makes and
# reads them (rdb.c: rdbSaveObject and rdbLoadObject; cluster.c:
# createDumpPayload and verifyDumpPayload). A payload is a value's type
# (a byte), the value, the version of the RDB format that wrote it (10,
# two bytes, the low first) and the CRC64 of all that (crc64.c: Jones's
# polynomial, reflected, from 0), eight bytes, the low first.

import Base
import ./map.bend as KV
import ./float.bend as F

# Bytes
# -----

def b1(+x: U32) -> String:
  SCon{Chr{x}, SNil{}}

# the byte n (below 256)
def bn(+n: Nat) -> String:
  b1(U32.from_nat(n))

# 2^32, a Nat (a literal stops at 2^32-1)
def two32() -> Nat:
  Nat.mul(65536n, 65536n)

# the k bytes of n, the low first, before rest
def le(k: Nat, +n: Nat, rest: String) -> String:
  match k:
    case 0n:
      rest
    case 1n+j:
      bn(Nat.mod(n, 256n)) ++ le(j, Nat.div(n, 256n), rest)

# the k bytes of n, the high first, before rest
def be(k: Nat, +n: Nat, rest: String) -> String:
  match k:
    case 0n:
      rest
    case 1n+j:
      be(j, Nat.div(n, 256n), bn(Nat.mod(n, 256n)) ++ rest)

# 64 bits as two halves of 32, the high first
type Q is Data:
  Q{hi: Nat, lo: Nat}

def q.le(q: Q, rest: String) -> String:
  match q:
    case Q{+hi, +lo}:
      le(4n, lo, le(4n, hi, rest))

# the halves of a number below 2^64 of limbs of 24 bits (float.bend's big)
def q.of_big(+a: List<&2, Nat>) -> Q:
  +l1 = F.big.limb(a, 1n)
  Q{Nat.add(Nat.div(l1, 256n), Nat.mul(F.big.limb(a, 2n), 65536n)), Nat.add(F.big.limb(a, 0n), Nat.mul(Nat.mod(l1, 256n), 16777216n))}

def q.big(+hi: Nat, +lo: Nat) -> List<&2, Nat>:
  F.big.add(F.big.shl(F.big.of(hi), 32n), F.big.of(lo))

# 2^64 - x, of x not 0: the two's complement of a negative number's
# magnitude
def q.neg(q: Q) -> Q:
  match q:
    case Q{+hi, +lo}:
      +z = Nat.is_eq(lo, 0n)
      Q{Nat.mod(Nat.sub(Bool.pick(Nat, z, two32(), 4294967295n), hi), two32()), Nat.mod(Nat.sub(two32(), lo), two32())}

# the 64 bits of the integer whose sign is neg and magnitude m (below 2^48)
def q.of_nat(neg: Bool, +m: Nat) -> Q:
  match neg:
    case True{}:
      q.neg(Q{Nat.div(m, two32()), Nat.mod(m, two32())})
    case False{}:
      Q{Nat.div(m, two32()), Nat.mod(m, two32())}

# Integers as text
# ----------------
# An integer is written as ll2string writes a long long: '-' and the
# digits of its magnitude, no leading zero

def int.text(+neg: Bool, +m: Nat) -> String:
  Bool.pick(String, neg, "-", "") ++ Nat.show(m)

def q.dec(small: Bool, +hi: Nat, +lo: Nat) -> String:
  match small:
    case True{}:
      Nat.show(Nat.add(Nat.mul(hi, two32()), lo))
    case False{}:
      F.big.to_dec(q.big(hi, lo))

# the text of the 64 bits q read as a signed integer (two's complement)
def q.text.of(+neg: Bool, q: Q) -> String:
  match q:
    case Q{+hi, +lo}:
      Bool.pick(String, neg, "-", "") ++ q.dec(Nat.is_lt(hi, 65536n), hi, lo)

def q.text(q: Q) -> String:
  match q:
    case Q{+hi, +lo}:
      +neg = Nat.is_le(2147483648n, hi)
      q.text.of(neg, Bool.pick(Q, neg, q.neg(Q{hi, lo}), Q{hi, lo}))

# the text of the k bytes u (below 2^48) read as a signed integer of
# 8k bits (two's complement)
def sint.text(+k: Nat, +u: Nat) -> String:
  +full = Nat.pow(2n, Nat.mul(8n, k))
  +neg = Nat.is_le(Nat.div(full, 2n), u)
  int.text(neg, Bool.pick(Nat, neg, Nat.sub(full, u), u))

# What an integer's text is: its sign and its magnitude, below 2^48 when
# it has 14 digits at most (IN), any other a 64-bit integer's two's
# complement (IQ); not an integer as Redis writes one (INo: string2ll and
# lpStringToInt64 read only those)
type IV is Data:
  IN{neg: Bool, m: Nat}
  IQ{q: Q}
  INo{}

def iv.signed(neg: Bool, q: Q) -> IV:
  match neg:
    case True{}:
      IQ{q.neg(q)}
    case False{}:
      IQ{q}

def iv.big(+neg: Bool, +s: String, +a: Nat, +d: Nat) -> IV:
  iv.signed(neg, q.of_big(F.big.digits(Nil{}, s, a, d)))

def iv.pick(small: Bool, +neg: Bool, +s: String, +a: Nat, +d: Nat) -> IV:
  match small:
    case True{}:
      IN{neg, String.dec_at(s, a, d)}
    case False{}:
      iv.big(neg, s, a, d)

def iv.of(ok: Bool, +s: String, +n: Nat) -> IV:
  match ok:
    case False{}:
      INo{}
    case True{}:
      +neg = U32.is_eq(String.code_at(s, 0n), 45)
      +a = Bool.pick(Nat, neg, 1n, 0n)
      +d = Nat.sub(n, a)
      iv.pick(Nat.is_le(d, 14n), neg, s, a, d)

def iv(+s: String) -> IV:
  iv.of(KV.ints.ok(s), s, String.length(s))

# CRC64
# -----
# a byte at a time, as two steps of four bits through the table of the
# remainders of the 16 nibbles (Redis's crc64 of "123456789" is
# 0xe9c6d914c4b8d9ca)

type C is Data:
  C{hi: U32, lo: U32}

def crc.t(h: KV.Hex) -> C:
  match h:
    case KV.H0{}:
      C{0, 0}
    case KV.H1{}:
      C{2097741627, 2294181761}
    case KV.H2{}:
      C{4195483255, 293396226}
    case KV.H3{}:
      C{2266562892, 2579673219}
    case KV.H4{}:
      C{3749370557, 2054040943}
    case KV.H5{}:
      C{2725389702, 4073734894}
    case KV.H6{}:
      C{627778762, 1796403821}
    case KV.H7{}:
      C{1482939377, 3819740652}
    case KV.H8{}:
      C{2511115049, 2890647989}
    case KV.H9{}:
      C{3903089682, 620078644}
    case KV.H10{}:
      C{1874685278, 3174504119}
    case KV.H11{}:
      C{313889381, 898201910}
    case KV.H12{}:
      C{1255557524, 3592807642}
    case KV.H13{}:
      C{937342639, 1587252059}
    case KV.H14{}:
      C{2965878755, 3344514008}
    case KV.H15{}:
      C{3452913880, 1340560473}

def crc.xor(a: C, +hi: U32, +lo: U32) -> C:
  match a:
    case C{+ah, +al}:
      C{U32.xor(ah, hi), U32.xor(al, lo)}

# a step: the low nibble out, through the table
def crc.nib(c: C) -> C:
  match c:
    case C{+hi, +lo}:
      crc.xor(crc.t(KV.hex(lo)), U32.shrn(hi, 4n), U32.or(U32.shrn(lo, 4n), U32.shln(hi, 28n)))

def crc.byte(c: C, +x: U32) -> C:
  match c:
    case C{hi, +lo}:
      crc.nib(crc.nib(C{hi, U32.xor(lo, x)}))

# the CRC of the bytes of w from its j-th, f of them, after c: w is a
# window of one chunk, which String.code_at reads at once
def crc.in(f: Nat, +w: String, +j: Nat, c: C) -> C:
  match f:
    case 0n:
      c
    case 1n+g:
      crc.in(g, w, Nat.add(j, 1n), crc.byte(c, String.code_at(w, j)))

# the CRC of the first n bytes of s after c, a window of 2,048 bytes at
# a time (a walk of s by its characters makes a view of each; f bounds
# the windows)
def crc.run(f: Nat, +s: String, +n: Nat, c: C) -> C:
  match f:
    case 0n:
      c
    case 1n+g:
      +k = Nat.min(n, 2048n)
      crc.run(g, String.drop(s, k), Nat.sub(n, k), crc.in(k, String.take(s, k), 0n, c))

# the CRC of the k bytes of s after c
def crc.k(+k: Nat, +s: String, c: C) -> C:
  crc.run(Nat.div(Nat.add(k, 2047n), 2048n), s, k, c)

# its eight bytes, the low first, before rest
def crc.le(c: C, rest: String) -> String:
  match c:
    case C{+hi, +lo}:
      le(4n, U32.to_nat(lo), le(4n, U32.to_nat(hi), rest))

# Writing
# -------
# rdbSaveLen: a length below 64 in a byte (00 and its 6 bits), below
# 16384 in two (01 and its 14 bits, the high first), else 0x80 and 32
# bits, the high byte first (0x81 and 64 bits past 2^32-1)

def len.put.of(k: Nat, +n: Nat, rest: String) -> String:
  match k:
    case 0n:
      bn(n) ++ rest
    case 1n:
      bn(Nat.add(64n, Nat.div(n, 256n))) ++ (bn(Nat.mod(n, 256n)) ++ rest)
    case 2n:
      b1(128) ++ be(4n, n, rest)
    case _:
      b1(129) ++ be(8n, n, rest)

def len.put(+n: Nat, rest: String) -> String:
  len.put.of(Bool.pick(Nat, Nat.is_lt(n, 64n), 0n, Bool.pick(Nat, Nat.is_lt(n, 16384n), 1n, Bool.pick(Nat, Nat.is_le(n, 4294967295n), 2n, 3n))), n, rest)

# A string as rdbSaveRawString writes one with rdbcompression no: the
# text of an integer of 8, 16 or 32 bits (rdbTryIntegerEncoding: at most
# 11 bytes, read by string2ll and written back the same) as that integer
# (ENCVAL 0, 1, 2: 0xC0, 0xC1, 0xC2, then its bytes, the low first); any
# other as its length and its bytes

# the class of an integer: 8, 16, 32 bits (0, 1, 2), or wider (3)
def int.cls(+neg: Bool, +m: Nat) -> Nat:
  +b = Bool.pick(Nat, neg, 1n, 0n)
  Bool.pick(Nat, Nat.is_lt(m, Nat.add(128n, b)), 0n, Bool.pick(Nat, Nat.is_lt(m, Nat.add(32768n, b)), 1n, Bool.pick(Nat, Nat.is_lt(m, Nat.add(2147483648n, b)), 2n, 3n)))

# m's two's complement in w (m below w; m itself when not negative)
def twos(+neg: Bool, +w: Nat, +m: Nat) -> Nat:
  Bool.pick(Nat, neg, Nat.mod(Nat.sub(w, m), w), m)

def str.int(k: Nat, +neg: Bool, +m: Nat, +s: String, rest: String) -> String:
  match k:
    case 0n:
      b1(192) ++ le(1n, twos(neg, 256n, m), rest)
    case 1n:
      b1(193) ++ le(2n, twos(neg, 65536n, m), rest)
    case 2n:
      b1(194) ++ le(4n, twos(neg, two32(), m), rest)
    case _:
      len.put(String.length(s), s ++ rest)

def str.put.of(v: IV, +s: String, rest: String) -> String:
  match v:
    case IN{+neg, +m}:
      str.int(int.cls(neg, m), neg, m, s, rest)
    case _:
      len.put(String.length(s), s ++ rest)

def str.put.n(short: Bool, +s: String, rest: String) -> String:
  match short:
    case True{}:
      str.put.of(iv(s), s, rest)
    case False{}:
      len.put(String.length(s), s ++ rest)

def str.put(+s: String, rest: String) -> String:
  str.put.n(Nat.is_le(String.length(s), 11n), s, rest)

# Reading
# -------
# A payload is read from its first byte on: each read takes what it reads
# from the front of what is left and gives it back with the rest, or None
# when the bytes run out (Redis's rioRead past the payload's end) or are
# not what they must be.

def rd.u8(s: String) -> Maybe<&1, Nat & String>:
  match s:
    case SCon{Chr{+x}, t}:
      Some{(U32.to_nat(x), t)}
    case SNil{}:
      None{}

def rd.take.of(ok: Bool, x: String, rest: String) -> Maybe<&1, String & String>:
  match ok:
    case True{}:
      Some{(x, rest)}
    case False{}:
      None{}

# the n bytes at the front of s, all there
def rd.take(+s: String, +n: Nat) -> Maybe<&1, String & String>:
  +x = String.take(s, n)
  rd.take.of(Nat.is_eq(String.length(x), n), x, String.drop(s, n))

# k bytes, the low first, after acc (m the weight of the next one; k at
# most 5: after a sixth, m would be 2^48, past a Nat)
def rd.le(k: Nat, s: String, +m: Nat, +acc: Nat) -> Maybe<&1, Nat & String>:
  match k s:
    case 0n t:
      Some{(acc, t)}
    case 1n+j SCon{Chr{+x}, t}:
      rd.le(j, t, Nat.mul(m, 256n), Nat.add(acc, Nat.mul(U32.to_nat(x), m)))
    case 1n+j SNil{}:
      None{}

# 2^40 - 1: below 2^48 times 256
def be.cap() -> Nat:
  Nat.sub(Nat.mul(1048576n, 1048576n), 1n)

# k bytes, the high first, after acc: a number past 2^48, which no
# length is, reads as one that never fits what is left
def rd.be(k: Nat, s: String, +acc: Nat) -> Maybe<&1, Nat & String>:
  match k s:
    case 0n t:
      Some{(acc, t)}
    case 1n+j SCon{Chr{+x}, t}:
      rd.be(j, t, Nat.add(Nat.mul(Nat.min(acc, be.cap()), 256n), U32.to_nat(x)))
    case 1n+j SNil{}:
      None{}

# a length (rdbLoadLenByRef): a number, or the kind of an encoded string
# (ENCVAL)
type Len is Data:
  LNum{n: Nat}
  LEnc{k: Nat}

def rd.len.num(m: Maybe<&1, Nat & String>) -> Maybe<&1, Len & String>:
  match m:
    case Some{p}:
      (n, t) = p
      Some{(LNum{n}, t)}
    case None{}:
      None{}

def rd.len.big(x: Nat, t: String) -> Maybe<&1, Len & String>:
  match x:
    case 128n:
      rd.len.num(rd.be(4n, t, 0n))
    case 129n:
      rd.len.num(rd.be(8n, t, 0n))
    case _:
      None{}

def rd.len.of(k: Nat, +x: Nat, t: String) -> Maybe<&1, Len & String>:
  match k:
    case 0n:
      Some{(LNum{Nat.mod(x, 64n)}, t)}
    case 1n:
      rd.len.num(rd.be(1n, t, Nat.mod(x, 64n)))
    case 2n:
      rd.len.big(x, t)
    case _:
      Some{(LEnc{Nat.mod(x, 64n)}, t)}

def rd.len(s: String) -> Maybe<&1, Len & String>:
  match s:
    case SCon{Chr{+x}, t}:
      rd.len.of(U32.to_nat(U32.shrn(x, 6n)), U32.to_nat(x), t)
    case SNil{}:
      None{}

def rd.num.l(l: Len, t: String) -> Maybe<&1, Nat & String>:
  match l:
    case LNum{n}:
      Some{(n, t)}
    case LEnc{k}:
      Some{(k, t)}

# a length that is a number (rdbLoadLen without isencoded: a byte whose
# two high bits mark an encoded string reads as its other six, a count)
def rd.num.of(m: Maybe<&1, Len & String>) -> Maybe<&1, Nat & String>:
  match m:
    case Some{p}:
      (l, t) = p
      rd.num.l(l, t)
    case None{}:
      None{}

def rd.num(s: String) -> Maybe<&1, Nat & String>:
  rd.num.of(rd.len(s))

# LZF
# ---
# lzf_decompress: the compressed bytes (clen of them, read whole first, as
# rioRead reads them) as steps, each a control byte: below 32, a run of
# that many bytes plus one, as they are; else a reference back to bytes
# already out: its high 3 bits a length (7: plus the next byte), plus 2,
# its low 5 bits and the next byte the distance back, less 1. A run or a
# reference that passes the length the string says (len), or a reference
# before its start, or a step past the compressed bytes, fails, and so
# does a string that ends shorter than len. The bytes out so far (op of
# them) are kept reversed, the newest first: a piece goes in front, into
# the room of the first chunk (str_cons), so they stay a few chunks
# however many pieces make them, a reference reads near the front (a
# distance is 8192 at most), and the end reverses them once. (The bytes
# out in order, with a window of the last of them, took each piece at
# the window's end, a node more each time, and each reference and each
# piece walked them all: a quicklist's node of 8 KB, as Redis compresses
# it with rdbcompression yes, took milliseconds.)

type Lzf is Data:
  Lzf{inp: String, ci: Nat, w: String, op: Nat}

# the k bytes p out
def lzf.put(p: String, +k: Nat, rest: String, +ci: Nat, w: String, +op: Nat) -> Lzf:
  Lzf{rest, ci, String.reverse.go(p, w), Nat.add(op, k)}

def lzf.lit(ok: Bool, +k: Nat, +inp: String, +ci: Nat, w: String, +op: Nat) -> Maybe<&2, Lzf>:
  match ok:
    case True{}:
      +r1 = String.drop(inp, 1n)
      Some{lzf.put(String.take(r1, k), k, String.drop(r1, k), Nat.sub(ci, Nat.add(k, 1n)), w, op)}
    case False{}:
      None{}

# the n bytes that p (of m bytes) makes repeated
def lzf.rep(f: Nat, done: Bool, +p: String, +m: Nat, +n: Nat) -> String:
  match f done:
    case 0n _:
      String.take(p, n)
    case _ True{}:
      String.take(p, n)
    case 1n+g False{}:
      +m2 = Nat.mul(m, 2n)
      lzf.rep(g, Nat.is_le(n, m2), p ++ p, m2, n)

# a reference: its first m bytes are the m bytes from d back, which the
# bytes out, reversed, hold from index d - m on, newest first
def lzf.ref(ok: Bool, +k: Nat, +d: Nat, rest: String, +ci: Nat, +w: String, +op: Nat) -> Maybe<&2, Lzf>:
  match ok:
    case True{}:
      +m = Nat.min(k, d)
      Some{lzf.put(lzf.rep(10n, Nat.is_le(k, m), String.reverse(String.slice(w, Nat.sub(d, m), m)), m, k), k, rest, ci, w, op)}
    case False{}:
      None{}

def lzf.op(lit: Bool, +n: Nat, +c: Nat, +h: String, +inp: String, +ci: Nat, w: String, +op: Nat) -> Maybe<&2, Lzf>:
  match lit:
    case True{}:
      +k = Nat.add(c, 1n)
      lzf.lit(Bool.and(Nat.is_le(Nat.add(k, 1n), ci), Nat.is_le(Nat.add(op, k), n)), k, inp, ci, w, op)
    case False{}:
      +l0 = Nat.div(c, 32n)
      +long = Nat.is_eq(l0, 7n)
      +used = Bool.pick(Nat, long, 3n, 2n)
      +len = Bool.pick(Nat, long, Nat.add(7n, U32.to_nat(String.code_at(h, 1n))), l0)
      +lo = U32.to_nat(String.code_at(h, Bool.pick(Nat, long, 2n, 1n)))
      +d = Nat.add(Nat.add(Nat.mul(Nat.mod(c, 32n), 256n), lo), 1n)
      +k = Nat.add(len, 2n)
      lzf.ref(Bool.and(Bool.and(Nat.is_le(used, ci), Nat.is_le(Nat.add(op, k), n)), Nat.is_le(d, op)), k, d, String.drop(inp, used), Nat.sub(ci, used), w, op)

def lzf.step(+n: Nat, st: Lzf) -> Maybe<&2, Lzf>:
  match st:
    case Lzf{+inp, +ci, w, +op}:
      +h = String.take(inp, 3n)
      +c = U32.to_nat(String.code_at(h, 0n))
      lzf.op(Nat.is_lt(c, 32n), n, c, h, inp, ci, w, op)

def lzf.fin(ok: Bool, w: String) -> Maybe<&2, String>:
  match ok:
    case True{}:
      Some{String.reverse(w)}
    case False{}:
      None{}

def lzf.go(f: Nat, +n: Nat, m: Maybe<&2, Lzf>) -> Maybe<&2, String>:
  match f m:
    case 1n+g Some{Lzf{inp, ci, w, +op}}:
      match ci:
        case 0n:
          lzf.fin(Nat.is_eq(op, n), w)
        case 1n+c:
          lzf.go(g, n, lzf.step(n, Lzf{inp, 1n+c, w, op}))
    case _ _:
      None{}

# len bytes from the clen bytes c (a string of len 0 is "", whatever c
# holds: lzf_decompress then answers 0, which is len)
def lzf.dec(+c: String, +clen: Nat, +len: Nat) -> Maybe<&2, String>:
  match len:
    case 0n:
      Some{""}
    case _:
      lzf.go(Nat.add(clen, 1n), len, Some{Lzf{c, clen, "", 0n}})

def lzf.got(m: Maybe<&2, String>, rest: String) -> Maybe<&1, String & String>:
  match m:
    case Some{x}:
      Some{(x, rest)}
    case None{}:
      None{}

def lzf.data(+clen: Nat, +len: Nat, m: Maybe<&1, String & String>) -> Maybe<&1, String & String>:
  match m:
    case Some{p}:
      (+c, rest) = p
      lzf.got(lzf.dec(c, clen, len), rest)
    case None{}:
      None{}

def lzf.len(+clen: Nat, m: Maybe<&1, Nat & String>) -> Maybe<&1, String & String>:
  match m:
    case Some{p}:
      (+len, +t) = p
      lzf.data(clen, len, rd.take(t, clen))
    case None{}:
      None{}

def lzf.clen(m: Maybe<&1, Nat & String>) -> Maybe<&1, String & String>:
  match m:
    case Some{p}:
      (+clen, t) = p
      lzf.len(clen, rd.num(t))
    case None{}:
      None{}

# A string (rdbGenericLoadStringObject): its length and its bytes, or an
# integer of 8, 16 or 32 bits (its text), or LZF's compressed bytes

def rd.int.of(+k: Nat, m: Maybe<&1, Nat & String>) -> Maybe<&1, String & String>:
  match m:
    case Some{p}:
      (+u, t) = p
      Some{(sint.text(k, u), t)}
    case None{}:
      None{}

def rd.int(+k: Nat, s: String) -> Maybe<&1, String & String>:
  rd.int.of(k, rd.le(k, s, 1n, 0n))

def rd.str.enc(k: Nat, t: String) -> Maybe<&1, String & String>:
  match k:
    case 0n:
      rd.int(1n, t)
    case 1n:
      rd.int(2n, t)
    case 2n:
      rd.int(4n, t)
    case 3n:
      lzf.clen(rd.num(t))
    case _:
      None{}

def rd.str.len(l: Len, t: String) -> Maybe<&1, String & String>:
  match l:
    case LNum{+n}:
      rd.take(t, n)
    case LEnc{k}:
      rd.str.enc(k, t)

def rd.str.of(m: Maybe<&1, Len & String>) -> Maybe<&1, String & String>:
  match m:
    case Some{p}:
      (l, t) = p
      rd.str.len(l, t)
    case None{}:
      None{}

def rd.str(s: String) -> Maybe<&1, String & String>:
  rd.str.of(rd.len(s))

# Listpacks
# ---------
# A listpack (listpack.c): its size in bytes (4, the low first), how many
# entries it holds (2; 65535 when that many or more), the entries, and
# 0xFF. An entry is an integer when the element is the text Redis writes
# of a 64-bit one (lpStringToInt64): of 7 bits (0 to 127, its byte), of
# 13 bits (0xC0 and its 5 high bits, then its low byte), or of 16, 24, 32
# or 64 bits (0xF1 to 0xF4, then its bytes, the low first), the narrowest
# that holds it, a negative one as its two's complement; any other a
# string: below 64 bytes 0x80 and its length, below 4096 0xE0 and its 12
# bits (the high first), else 0xF0 and its 32 bits (the low first), then
# its bytes. Each entry ends with its size, of its encoding and its data
# (backlen: 7 bits a byte, the highest first, every byte but the first
# with bit 7 set).

# the kind of an integer's entry: 7, 13, 16, 24, 32 or 64 bits (0 to 5)
def lp.icls(+neg: Bool, +m: Nat) -> Nat:
  +b = Bool.pick(Nat, neg, 1n, 0n)
  Bool.pick(Nat, Bool.and(Bool.not(neg), Nat.is_le(m, 127n)), 0n, Bool.pick(Nat, Nat.is_lt(m, Nat.add(4096n, b)), 1n, Bool.pick(Nat, Nat.is_lt(m, Nat.add(32768n, b)), 2n, Bool.pick(Nat, Nat.is_lt(m, Nat.add(8388608n, b)), 3n, Bool.pick(Nat, Nat.is_lt(m, Nat.add(2147483648n, b)), 4n, 5n)))))

def lp.isize(k: Nat) -> Nat:
  match k:
    case 0n:
      1n
    case 1n:
      2n
    case 2n:
      3n
    case 3n:
      4n
    case 4n:
      5n
    case _:
      9n

def lp.ssize(+l: Nat) -> Nat:
  Nat.add(l, Bool.pick(Nat, Nat.is_lt(l, 64n), 1n, Bool.pick(Nat, Nat.is_lt(l, 4096n), 2n, 5n)))

# the size of an element's entry, without its backlen
def lp.size.of(v: IV, +l: Nat) -> Nat:
  match v:
    case IN{+neg, +m}:
      lp.isize(lp.icls(neg, m))
    case IQ{q}:
      9n
    case INo{}:
      lp.ssize(l)

def lp.size(+x: String) -> Nat:
  lp.size.of(iv(x), String.length(x))

# how many bytes the backlen of l takes
def lp.back.n(+l: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_le(l, 127n), 1n, Bool.pick(Nat, Nat.is_lt(l, 16383n), 2n, Bool.pick(Nat, Nat.is_lt(l, 2097151n), 3n, Bool.pick(Nat, Nat.is_lt(l, 268435455n), 4n, 5n))))

# the k bytes of l's backlen, before rest
def lp.back.go(k: Nat, +l: Nat, rest: String) -> String:
  match k:
    case 0n:
      rest
    case 1n+j:
      match j:
        case 0n:
          bn(Nat.mod(l, 128n)) ++ rest
        case 1n+i:
          lp.back.go(1n+i, Nat.div(l, 128n), bn(Nat.add(Nat.mod(l, 128n), 128n)) ++ rest)

def lp.back(+l: Nat, rest: String) -> String:
  lp.back.go(lp.back.n(l), l, rest)

# an entry's size with its backlen
def lp.esize(+x: String) -> Nat:
  +l = lp.size(x)
  Nat.add(l, lp.back.n(l))

# an integer's entry of kind k
def lp.int(k: Nat, +neg: Bool, +m: Nat, rest: String) -> String:
  match k:
    case 0n:
      bn(m) ++ rest
    case 1n:
      +v = twos(neg, 8192n, m)
      bn(Nat.add(192n, Nat.div(v, 256n))) ++ (bn(Nat.mod(v, 256n)) ++ rest)
    case 2n:
      b1(241) ++ le(2n, twos(neg, 65536n, m), rest)
    case 3n:
      b1(242) ++ le(3n, twos(neg, 16777216n, m), rest)
    case 4n:
      b1(243) ++ le(4n, twos(neg, two32(), m), rest)
    case _:
      b1(244) ++ q.le(q.of_nat(neg, m), rest)

def lp.str(+l: Nat, +x: String, rest: String) -> String:
  Bool.pick(String, Nat.is_lt(l, 64n), bn(Nat.add(128n, l)), Bool.pick(String, Nat.is_lt(l, 4096n), bn(Nat.add(224n, Nat.div(l, 256n))) ++ bn(Nat.mod(l, 256n)), b1(240) ++ le(4n, l, ""))) ++ (x ++ rest)

def lp.ent.of(v: IV, +x: String, rest: String) -> String:
  match v:
    case IN{+neg, +m}:
      +k = lp.icls(neg, m)
      lp.int(k, neg, m, lp.back(lp.isize(k), rest))
    case IQ{q}:
      b1(244) ++ q.le(q, lp.back(9n, rest))
    case INo{}:
      +l = String.length(x)
      lp.str(l, x, lp.back(lp.ssize(l), rest))

# an element's entry, with its backlen, before rest
def lp.ent(+x: String, rest: String) -> String:
  lp.ent.of(iv(x), x, rest)

def lp.ents(xs: List<&2, String>, rest: String) -> String:
  match xs:
    case Nil{}:
      rest
    case Con{+x, more}:
      lp.ent(x, lp.ents(more, rest))

# the listpack of the n elements xs
def lp.blob(xs: List<&2, String>, +n: Nat) -> String:
  +es = lp.ents(xs, b1(255))
  le(4n, Nat.add(String.length(es), 6n), le(2n, Nat.min(n, 65535n), es))

# Reading a listpack: each entry an element (its text, an integer's as
# ll2string writes it) and its size, or the end (0xFF); the entries end
# at the listpack's last byte, every backlen is its entry's size, and the
# count is the header's (65535: any). lpValidateIntegrity reads them so
# when sanitize-dump-payload asks it to (deep); BendKV always reads them so.

type LpE is Data:
  LpE{v: String, size: Nat}
  LpEnd{}

# an entry read: an element and what follows it, or the end and what
# follows it, or bytes that are no entry
type LpR is Data:
  LpOk{v: String, t: String}
  LpFin{t: String}
  LpBad{}

def lp.kind(+x: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_lt(x, 128n), 0n, Bool.pick(Nat, Nat.is_lt(x, 192n), 1n, Bool.pick(Nat, Nat.is_lt(x, 224n), 2n, Bool.pick(Nat, Nat.is_lt(x, 240n), 3n, Bool.pick(Nat, Nat.is_eq(x, 240n), 8n, Bool.pick(Nat, Nat.is_le(x, 244n), Nat.sub(x, 237n), Bool.pick(Nat, Nat.is_eq(x, 255n), 9n, 10n)))))))

def lp.val(+k: Nat, +sz: Nat, m: Maybe<&1, Nat & String>) -> Maybe<&1, LpE & String>:
  match m:
    case Some{p}:
      (+u, t) = p
      Some{(LpE{sint.text(k, u), sz}, t)}
    case None{}:
      None{}

def lp.sdata(+sz: Nat, m: Maybe<&1, String & String>) -> Maybe<&1, LpE & String>:
  match m:
    case Some{p}:
      (x, t) = p
      Some{(LpE{x, sz}, t)}
    case None{}:
      None{}

# a string's data, its length read first
def lp.slen(+h: Nat, m: Maybe<&1, Nat & String>) -> Maybe<&1, LpE & String>:
  match m:
    case Some{p}:
      (+l, +t) = p
      lp.sdata(Nat.add(h, l), rd.take(t, l))
    case None{}:
      None{}

def lp.i13(m: Maybe<&1, Nat & String>) -> Maybe<&1, LpE & String>:
  match m:
    case Some{p}:
      (+u, t) = p
      +neg = Nat.is_le(4096n, u)
      Some{(LpE{int.text(neg, Bool.pick(Nat, neg, Nat.sub(8192n, u), u)), 2n}, t)}
    case None{}:
      None{}

def lp.i64.hi(+lo: Nat, m: Maybe<&1, Nat & String>) -> Maybe<&1, LpE & String>:
  match m:
    case Some{p}:
      (+hi, t) = p
      Some{(LpE{q.text(Q{hi, lo}), 9n}, t)}
    case None{}:
      None{}

def lp.i64(m: Maybe<&1, Nat & String>) -> Maybe<&1, LpE & String>:
  match m:
    case Some{p}:
      (+lo, t) = p
      lp.i64.hi(lo, rd.le(4n, t, 1n, 0n))
    case None{}:
      None{}

def lp.head(k: Nat, +x: Nat, t: String) -> Maybe<&1, LpE & String>:
  match k:
    case 0n:
      Some{(LpE{Nat.show(x), 1n}, t)}
    case 1n:
      +l = Nat.sub(x, 128n)
      lp.sdata(Nat.add(l, 1n), rd.take(t, l))
    case 2n:
      lp.i13(rd.be(1n, t, Nat.sub(x, 192n)))
    case 3n:
      lp.slen(2n, rd.be(1n, t, Nat.sub(x, 224n)))
    case 4n:
      lp.val(2n, 3n, rd.le(2n, t, 1n, 0n))
    case 5n:
      lp.val(3n, 4n, rd.le(3n, t, 1n, 0n))
    case 6n:
      lp.val(4n, 5n, rd.le(4n, t, 1n, 0n))
    case 7n:
      lp.i64(rd.le(4n, t, 1n, 0n))
    case 8n:
      lp.slen(5n, rd.le(4n, t, 1n, 0n))
    case 9n:
      Some{(LpEnd{}, t)}
    case _:
      None{}

def lp.back.ok(same: Bool, v: String, t: String) -> LpR:
  match same:
    case True{}:
      LpOk{v, t}
    case False{}:
      LpBad{}

def lp.back.of(+sz: Nat, v: String, m: Maybe<&1, String & String>) -> LpR:
  match m:
    case Some{p}:
      (b, t) = p
      lp.back.ok(String.eq(b, lp.back(sz, "")), v, t)
    case None{}:
      LpBad{}

def lp.tail.of(e: LpE, +t: String) -> LpR:
  match e:
    case LpE{v, +sz}:
      lp.back.of(sz, v, rd.take(t, lp.back.n(sz)))
    case LpEnd{}:
      LpFin{t}

# an entry's backlen, read and checked
def lp.tail(m: Maybe<&1, LpE & String>) -> LpR:
  match m:
    case Some{p}:
      (e, +t) = p
      lp.tail.of(e, t)
    case None{}:
      LpBad{}

# the next entry
def lp.next(s: String) -> LpR:
  match s:
    case SCon{Chr{+x}, t}:
      +n = U32.to_nat(x)
      lp.tail(lp.head(lp.kind(n), n, t))
    case SNil{}:
      LpBad{}

# the elements, when the end was the last byte and the header's count
# (65535: any) is theirs
def lp.end(+n: Nat, +want: Nat, acc: List<&2, String>, t: String) -> Maybe<&2, List<&2, String>>:
  match t:
    case SNil{}:
      Bool.pick(Maybe<&2, List<&2, String>>, Bool.or(Nat.is_eq(want, 65535n), Nat.is_eq(want, n)), Some{List.reverse(&2, String, acc)}, None{})
    case _:
      None{}

# the entries after the first n (acc, newest first), r the one just read
def lp.ents.go(f: Nat, +n: Nat, +want: Nat, r: LpR, acc: List<&2, String>) -> Maybe<&2, List<&2, String>>:
  match f r:
    case 1n+g LpOk{v, t}:
      lp.ents.go(g, Nat.add(n, 1n), want, lp.next(t), v <> acc)
    case _ LpFin{t}:
      lp.end(n, want, acc, t)
    case _ _:
      None{}

def lp.hdr.n(+l: Nat, m: Maybe<&1, Nat & String>) -> Maybe<&2, List<&2, String>>:
  match m:
    case Some{p}:
      (+want, t) = p
      lp.ents.go(l, 0n, want, lp.next(t), Nil{})
    case None{}:
      None{}

def lp.hdr.if(same: Bool, +l: Nat, t: String) -> Maybe<&2, List<&2, String>>:
  match same:
    case True{}:
      lp.hdr.n(l, rd.le(2n, t, 1n, 0n))
    case False{}:
      None{}

def lp.hdr(+l: Nat, m: Maybe<&1, Nat & String>) -> Maybe<&2, List<&2, String>>:
  match m:
    case Some{p}:
      (+total, t) = p
      lp.hdr.if(Nat.is_eq(total, l), l, t)
    case None{}:
      None{}


# the elements of the listpack b
def lp.read(+b: String) -> Maybe<&2, List<&2, String>>:
  lp.hdr(String.length(b), rd.le(4n, b, 1n, 0n))

# Ziplists
# --------
# A ziplist (ziplist.c: the lists, hashes and sorted sets of Redis 3.2 to
# 6.2): its size in bytes (4, the low first), the offset of its last entry
# (4), how many entries it holds (2; 65535: that many or more), the
# entries, and 0xFF. An entry is the size of the entry before it (a byte
# below 254, else 0xFE and 4 bytes), then a string (00 and its 6-bit
# length, 01 and 14 bits, the high first, or 10 and 4 bytes, the high
# first, then its bytes) or an integer (0xFE: 8 bits; 0xC0: 16; 0xF0: 24;
# 0xD0: 32; 0xE0: 64, its bytes the low first; 0xF1 to 0xFD: 0 to 12 in
# the byte itself). ziplistValidateIntegrity reads them so: each entry's
# size of the one before it right, the last entry where the header says,
# the end at the last byte, the count the header's (65535: any).

# an entry read: the size of the entry before it as it says, its element,
# its own size, and what follows it; or the end and what follows it; or
# bytes that are no entry
type ZlR is Data:
  ZlOk{pl: Nat, v: String, size: Nat, t: String}
  ZlFin{t: String}
  ZlBad{}

def zl.got(+pl: Nat, +h: Nat, m: Maybe<&1, String & String>) -> ZlR:
  match m:
    case Some{p}:
      (+x, t) = p
      ZlOk{pl, x, Nat.add(h, String.length(x)), t}
    case None{}:
      ZlBad{}

def zl.int(+pl: Nat, +k: Nat, +h: Nat, m: Maybe<&1, Nat & String>) -> ZlR:
  match m:
    case Some{p}:
      (+u, t) = p
      ZlOk{pl, sint.text(k, u), Nat.add(h, k), t}
    case None{}:
      ZlBad{}

def zl.i64.hi(+pl: Nat, +h: Nat, +lo: Nat, m: Maybe<&1, Nat & String>) -> ZlR:
  match m:
    case Some{p}:
      (+hi, t) = p
      ZlOk{pl, q.text(Q{hi, lo}), Nat.add(h, 8n), t}
    case None{}:
      ZlBad{}

def zl.i64(+pl: Nat, +h: Nat, m: Maybe<&1, Nat & String>) -> ZlR:
  match m:
    case Some{p}:
      (+lo, t) = p
      zl.i64.hi(pl, h, lo, rd.le(4n, t, 1n, 0n))
    case None{}:
      ZlBad{}

def zl.slen(+pl: Nat, +h: Nat, m: Maybe<&1, Nat & String>) -> ZlR:
  match m:
    case Some{p}:
      (+l, +t) = p
      zl.got(pl, h, rd.take(t, l))
    case None{}:
      ZlBad{}

# the kind of an encoding byte: strings of 6, 14, 32-bit lengths (0 to
# 2), integers of 8, 16, 24, 32, 64 bits (3 to 7), an integer in the byte
# (8), none (9)
def zl.kind(+e: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_lt(e, 192n), Nat.div(e, 64n), Bool.pick(Nat, Nat.is_eq(e, 254n), 3n, Bool.pick(Nat, Nat.is_eq(e, 192n), 4n, Bool.pick(Nat, Nat.is_eq(e, 240n), 5n, Bool.pick(Nat, Nat.is_eq(e, 208n), 6n, Bool.pick(Nat, Nat.is_eq(e, 224n), 7n, Bool.pick(Nat, Bool.and(Nat.is_le(241n, e), Nat.is_le(e, 253n)), 8n, 9n)))))))

# an entry's encoding e and data, its header h bytes before them
def zl.enc(k: Nat, +pl: Nat, +e: Nat, +h: Nat, t: String) -> ZlR:
  match k:
    case 0n:
      zl.got(pl, Nat.add(h, 1n), rd.take(t, Nat.mod(e, 64n)))
    case 1n:
      zl.slen(pl, Nat.add(h, 2n), rd.be(1n, t, Nat.mod(e, 64n)))
    case 2n:
      zl.slen(pl, Nat.add(h, 5n), rd.be(4n, t, 0n))
    case 3n:
      zl.int(pl, 1n, Nat.add(h, 1n), rd.le(1n, t, 1n, 0n))
    case 4n:
      zl.int(pl, 2n, Nat.add(h, 1n), rd.le(2n, t, 1n, 0n))
    case 5n:
      zl.int(pl, 3n, Nat.add(h, 1n), rd.le(3n, t, 1n, 0n))
    case 6n:
      zl.int(pl, 4n, Nat.add(h, 1n), rd.le(4n, t, 1n, 0n))
    case 7n:
      zl.i64(pl, Nat.add(h, 1n), rd.le(4n, t, 1n, 0n))
    case 8n:
      ZlOk{pl, Nat.show(Nat.sub(e, 241n)), Nat.add(h, 1n), t}
    case _:
      ZlBad{}

def zl.body(+pl: Nat, +h: Nat, s: String) -> ZlR:
  match s:
    case SCon{Chr{+x}, t}:
      +e = U32.to_nat(x)
      zl.enc(zl.kind(e), pl, e, h, t)
    case SNil{}:
      ZlBad{}

def zl.prev4(m: Maybe<&1, Nat & String>) -> ZlR:
  match m:
    case Some{p}:
      (+pl, t) = p
      zl.body(pl, 5n, t)
    case None{}:
      ZlBad{}

def zl.next.of(k: Nat, +b: Nat, t: String) -> ZlR:
  match k:
    case 0n:
      ZlFin{t}
    case 1n:
      zl.body(b, 1n, t)
    case _:
      zl.prev4(rd.le(4n, t, 1n, 0n))

# the next entry, or the end (0xFF where an entry starts)
def zl.next(s: String) -> ZlR:
  match s:
    case SCon{Chr{+x}, t}:
      +b = U32.to_nat(x)
      zl.next.of(Bool.pick(Nat, Nat.is_eq(b, 255n), 0n, Bool.pick(Nat, Nat.is_lt(b, 254n), 1n, 2n)), b, t)
    case SNil{}:
      ZlBad{}

# the elements, when the end was the last byte, the last entry starts at
# the header's offset of it, and the header's count (65535: any) is theirs
def zl.end(+n: Nat, +want: Nat, +tail: Nat, +last: Nat, acc: List<&2, String>, t: String) -> Maybe<&2, List<&2, String>>:
  match t:
    case SNil{}:
      Bool.pick(Maybe<&2, List<&2, String>>, Bool.and(Bool.or(Nat.is_eq(n, 0n), Nat.is_eq(tail, last)), Bool.or(Nat.is_eq(want, 65535n), Nat.is_eq(want, n))), Some{List.reverse(&2, String, acc)}, None{})
    case _:
      None{}

# the entries after the first n (acc, newest first): r the one just read,
# at offset at; prev the size of the one before it, last where it starts
def zl.ents.go(f: Nat, +n: Nat, +want: Nat, +tail: Nat, +at: Nat, +prev: Nat, +last: Nat, r: ZlR, acc: List<&2, String>) -> Maybe<&2, List<&2, String>>:
  match f r:
    case 1n+g ZlOk{+pl, v, +sz, t}:
      zl.ents.go(g, Nat.add(n, 1n), want, tail, Nat.add(at, sz), sz, at, Bool.pick(ZlR, Nat.is_eq(pl, prev), zl.next(t), ZlBad{}), v <> acc)
    case _ ZlFin{t}:
      zl.end(n, want, tail, last, acc, t)
    case _ _:
      None{}

def zl.hdr.n(+l: Nat, +tail: Nat, m: Maybe<&1, Nat & String>) -> Maybe<&2, List<&2, String>>:
  match m:
    case Some{p}:
      (+want, t) = p
      zl.ents.go(l, 0n, want, tail, 10n, 0n, 0n, zl.next(t), Nil{})
    case None{}:
      None{}

def zl.hdr.tail(ok: Bool, +l: Nat, +tail: Nat, t: String) -> Maybe<&2, List<&2, String>>:
  match ok:
    case True{}:
      zl.hdr.n(l, tail, rd.le(2n, t, 1n, 0n))
    case False{}:
      None{}

# the offset of the last entry, within the ziplist
def zl.hdr.t(+l: Nat, m: Maybe<&1, Nat & String>) -> Maybe<&2, List<&2, String>>:
  match m:
    case Some{p}:
      (+tail, t) = p
      zl.hdr.tail(Nat.is_lt(tail, l), l, tail, t)
    case None{}:
      None{}

def zl.hdr.if(same: Bool, +l: Nat, t: String) -> Maybe<&2, List<&2, String>>:
  match same:
    case True{}:
      zl.hdr.t(l, rd.le(4n, t, 1n, 0n))
    case False{}:
      None{}

def zl.hdr(+l: Nat, m: Maybe<&1, Nat & String>) -> Maybe<&2, List<&2, String>>:
  match m:
    case Some{p}:
      (+total, t) = p
      zl.hdr.if(Nat.is_eq(total, l), l, t)
    case None{}:
      None{}

# the elements of the ziplist b
def zl.read(+b: String) -> Maybe<&2, List<&2, String>>:
  zl.hdr(String.length(b), rd.le(4n, b, 1n, 0n))

# Zipmaps
# -------
# A zipmap (zipmap.c, the small hashes of Redis 2.4 and before): how many
# pairs it holds (a byte; 254: that many or more), then each pair: the
# field's length (a byte below 254, else 254 and 4 bytes, the low first),
# the field, the value's length, a byte of free room, the value and that
# room; and 0xFF where a field would start, the last byte a 0xFF too.
# zipmapValidateIntegrity reads it so, with at least one pair, and the
# count the header's (254: any).

type ZmR is Data:
  ZmOk{f: String, v: String, t: String}
  ZmFin{}
  ZmBad{}

def zm.len.of(k: Nat, +b: Nat, t: String) -> Maybe<&1, Nat & String>:
  match k:
    case 0n:
      Some{(b, t)}
    case _:
      rd.le(4n, t, 1n, 0n)

# a length: a byte below 254, else 4 bytes after it
def zm.len(s: String) -> Maybe<&1, Nat & String>:
  match s:
    case SCon{Chr{+x}, t}:
      +b = U32.to_nat(x)
      zm.len.of(Bool.pick(Nat, Nat.is_lt(b, 254n), 0n, 1n), b, t)
    case SNil{}:
      None{}

def zm.room(f: String, v: String, m: Maybe<&1, String & String>) -> ZmR:
  match m:
    case Some{p}:
      (r, t) = p
      ZmOk{f, v, t}
    case None{}:
      ZmBad{}

def zm.val(f: String, +free: Nat, m: Maybe<&1, String & String>) -> ZmR:
  match m:
    case Some{p}:
      (v, +t) = p
      zm.room(f, v, rd.take(t, free))
    case None{}:
      ZmBad{}

def zm.free(f: String, +vl: Nat, m: Maybe<&1, Nat & String>) -> ZmR:
  match m:
    case Some{p}:
      (+free, +t) = p
      zm.val(f, free, rd.take(t, vl))
    case None{}:
      ZmBad{}

def zm.vlen(f: String, m: Maybe<&1, Nat & String>) -> ZmR:
  match m:
    case Some{p}:
      (+vl, t) = p
      zm.free(f, vl, rd.u8(t))
    case None{}:
      ZmBad{}

def zm.field(m: Maybe<&1, String & String>) -> ZmR:
  match m:
    case Some{p}:
      (f, t) = p
      zm.vlen(f, zm.len(t))
    case None{}:
      ZmBad{}

def zm.flen(m: Maybe<&1, Nat & String>) -> ZmR:
  match m:
    case Some{p}:
      (+fl, +t) = p
      zm.field(rd.take(t, fl))
    case None{}:
      ZmBad{}

# the next pair, or the end (0xFF where a field starts)
def zm.next(+s: String) -> ZmR:
  Bool.pick(ZmR, U32.is_eq(String.code_at(s, 0n), 255), ZmFin{}, zm.flen(zm.len(s)))

def zm.pairs(f: Nat, +n: Nat, r: ZmR, acc: List<&2, KV.HPair>) -> Maybe<&1, Nat & List<&2, KV.HPair>>:
  match f r:
    case 1n+g ZmOk{x, v, t}:
      zm.pairs(g, Nat.add(n, 1n), zm.next(t), KV.HP{x, v} <> acc)
    case _ ZmFin{}:
      Some{(n, List.reverse(&2, KV.HPair, acc))}
    case _ _:
      None{}

def zm.count(+head: Nat, m: Maybe<&1, Nat & List<&2, KV.HPair>>) -> Maybe<&2, List<&2, KV.HPair>>:
  match m:
    case Some{p}:
      (+n, ps) = p
      Bool.pick(Maybe<&2, List<&2, KV.HPair>>, Bool.and(Nat.is_lt(0n, n), Bool.or(Nat.is_eq(head, 254n), Nat.is_eq(head, n))), Some{ps}, None{})
    case None{}:
      None{}

def zm.read.of(ok: Bool, +l: Nat, +b: String) -> Maybe<&2, List<&2, KV.HPair>>:
  match ok:
    case True{}:
      zm.count(U32.to_nat(String.code_at(b, 0n)), zm.pairs(l, 0n, zm.next(String.drop(b, 1n)), Nil{}))
    case False{}:
      None{}

# the pairs of the zipmap b
def zm.read(+b: String) -> Maybe<&2, List<&2, KV.HPair>>:
  +l = String.length(b)
  zm.read.of(Bool.and(Nat.is_le(2n, l), U32.is_eq(String.code_at(b, Nat.sub(l, 1n)), 255)), l, b)

# Intsets
# -------
# An intset (intset.c): the width of its integers in bytes (4 bytes, the
# low first: 2, 4 or 8), how many (4), then each, of that width, the low
# byte first, in increasing order, none twice, at least one
# (intsetValidateIntegrity, deep). Here each is read as the 64 bits of
# its value, sign extended.

def q.flip(+hi: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_le(2147483648n, hi), Nat.sub(hi, 2147483648n), Nat.add(hi, 2147483648n))

# whether a is below b, both signed
def q.lt(a: Q, b: Q) -> Bool:
  match a b:
    case Q{+ah, +al} Q{+bh, +bl}:
      +fa = q.flip(ah)
      +fb = q.flip(bh)
      Bool.or(Nat.is_lt(fa, fb), Bool.and(Nat.is_eq(fa, fb), Nat.is_lt(al, bl)))

# the 64 bits of the w-byte (2 or 4) integer whose bytes, read unsigned,
# are u
def q.ext(+w: Nat, +u: Nat) -> Q:
  +full = Nat.pow(2n, Nat.mul(8n, w))
  +neg = Nat.is_le(Nat.div(full, 2n), u)
  Bool.pick(Q, neg, Q{4294967295n, Nat.sub(Nat.add(u, two32()), full)}, Q{0n, u})

def is.q(+w: Nat, m: Maybe<&1, Nat & String>) -> Maybe<&1, Q & String>:
  match m:
    case Some{p}:
      (+u, t) = p
      Some{(q.ext(w, u), t)}
    case None{}:
      None{}

def is.q8.hi(+lo: Nat, m: Maybe<&1, Nat & String>) -> Maybe<&1, Q & String>:
  match m:
    case Some{p}:
      (+hi, t) = p
      Some{(Q{hi, lo}, t)}
    case None{}:
      None{}

def is.q8(m: Maybe<&1, Nat & String>) -> Maybe<&1, Q & String>:
  match m:
    case Some{p}:
      (+lo, t) = p
      is.q8.hi(lo, rd.le(4n, t, 1n, 0n))
    case None{}:
      None{}

def is.val(+w: Nat, s: String) -> Maybe<&1, Q & String>:
  match w:
    case 8n:
      is.q8(rd.le(4n, s, 1n, 0n))
    case _:
      is.q(w, rd.le(w, s, 1n, 0n))

# the k values left, r the next one read, prev the one before it (first:
# none), each above the one before it (ok so far)
def is.go(k: Nat, +w: Nat, +ok: Bool, +first: Bool, +prev: Q, r: Maybe<&1, Q & String>, acc: List<&2, String>) -> Maybe<&2, List<&2, String>>:
  match k r:
    case 0n _:
      Bool.pick(Maybe<&2, List<&2, String>>, ok, Some{List.reverse(&2, String, acc)}, None{})
    case 1n+j Some{p}:
      (+q, t) = p
      is.go(j, w, Bool.and(ok, Bool.or(first, q.lt(prev, q))), False{}, q, is.val(w, t), q.text(q) <> acc)
    case _ None{}:
      None{}

def is.vals(ok: Bool, +w: Nat, +n: Nat, t: String) -> Maybe<&2, List<&2, String>>:
  match ok:
    case True{}:
      is.go(n, w, True{}, True{}, Q{0n, 0n}, is.val(w, t), Nil{})
    case False{}:
      None{}

# n values of w bytes in l bytes, w 2, 4 or 8 (the product taken of w
# cut to 8, as w and n are each any 32 bits until checked)
def is.count(+l: Nat, +w: Nat, m: Maybe<&1, Nat & String>) -> Maybe<&2, List<&2, String>>:
  match m:
    case Some{p}:
      (+n, t) = p
      is.vals(Bool.and(Bool.and(Bool.or(Nat.is_eq(w, 2n), Bool.or(Nat.is_eq(w, 4n), Nat.is_eq(w, 8n))), Nat.is_lt(0n, n)), Nat.is_eq(Nat.add(8n, Nat.mul(n, Nat.min(w, 8n))), l)), w, n, t)
    case None{}:
      None{}

def is.enc(+l: Nat, m: Maybe<&1, Nat & String>) -> Maybe<&2, List<&2, String>>:
  match m:
    case Some{p}:
      (+w, t) = p
      is.count(l, w, rd.le(4n, t, 1n, 0n))
    case None{}:
      None{}

# the members of the intset b, in increasing order, as their texts
def is.read(+b: String) -> Maybe<&2, List<&2, String>>:
  is.enc(String.length(b), rd.le(4n, b, 1n, 0n))

# Values
# ------
# A value read takes the form Redis 7.0.15 gives it on RESTORE, at the
# limits BendKV keeps whatever the parameters say (map.bend): a hash
# small (a listpack, HSmall, its pairs in the payload's order) when it
# came as a listpack, ziplist or zipmap of at most 512 pairs (a zipmap's
# fields and values of at most 64 bytes too), or as a hashtable of at
# most 512 pairs of at most 64 bytes; a set an intset (MInts) when it
# holds at most 512 members, all integers as Redis writes them, else a
# hashtable, small (MSmall or MLong, its members in the payload's order)
# when it holds at most 128 members of at most 64 bytes; a sorted set
# small (ZSmall) when it came as a listpack or ziplist of at most 128
# elements, or as a skiplist of at most 128 whose members are of at most
# 64 bytes. A collection with no element, or a member, field or element
# of a sorted set twice, or a score that is no number (a NaN), is no
# value Redis takes ("Bad data format").

def len.gt(xs: List<&2, String>, +m: Nat) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Con{+x, rest}:
      Bool.or(Nat.is_lt(m, String.length(x)), len.gt(rest, m))

def hps.gt(ps: List<&2, KV.HPair>, +m: Nat) -> Bool:
  match ps:
    case Nil{}:
      False{}
    case Con{KV.HP{+f, +v}, rest}:
      Bool.or(Bool.or(Nat.is_lt(m, String.length(f)), Nat.is_lt(m, String.length(v))), hps.gt(rest, m))

def mems.trie(xs: List<&2, String>, t: KV.Trie<Unit>) -> KV.Trie<Unit>:
  match xs:
    case Nil{}:
      t
    case Con{x, rest}:
      mems.trie(rest, KV.set(Unit, t, x, Unit{}))

def all.ints(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case Con{+x, rest}:
      Bool.and(KV.ints.ok(x), all.ints(rest))

def val.hash.of(small: Bool, +n: Nat, ps: List<&2, KV.HPair>, t: KV.Trie<String>) -> KV.Val:
  match small:
    case True{}:
      KV.VColl{KV.CHash{KV.hash.of(n, ps)}}
    case False{}:
      KV.VColl{KV.CHash{KV.HBig{n, t}}}

# a hash of the n pairs ps (small: small with them)
def val.hash(+small: Bool, +n: Nat, +ps: List<&2, KV.HPair>) -> Maybe<&2, KV.Val>:
  +t = KV.hps.trie(ps, KV.empty(String))
  Bool.pick(Maybe<&2, KV.Val>, Bool.and(Nat.is_lt(0n, n), Nat.is_eq(KV.size(String, t), n)), Some{val.hash.of(small, n, ps, t)}, None{})

def val.list(+xs: List<&2, String>) -> Maybe<&2, KV.Val>:
  +n = List.length(&2, String, xs)
  Bool.pick(Maybe<&2, KV.Val>, Nat.is_lt(0n, n), Some{KV.VColl{KV.CList{KV.deq.of(n, xs)}}}, None{})

# a hashtable of the n members xs (small: as a small one, in their order)
def val.set.table(small: Bool, +n: Nat, xs: List<&2, String>, t: KV.Trie<Unit>) -> KV.Val:
  match small:
    case True{}:
      KV.VColl{KV.CMems{KV.ms.make(n, xs)}}
    case False{}:
      KV.VColl{KV.CMems{KV.MBig{n, t}}}

def val.set.of(ints: Bool, +n: Nat, +xs: List<&2, String>, t: KV.Trie<Unit>) -> KV.Val:
  match ints:
    case True{}:
      KV.VColl{KV.CMems{KV.MInts{n, KV.ints.of(xs, "", 0n)}}}
    case False{}:
      val.set.table(Bool.and(Nat.is_le(n, 128n), Bool.not(len.gt(xs, 64n))), n, xs, t)

# a set of the n members xs, the trie of which finds a member twice
def val.set.any(+n: Nat, +xs: List<&2, String>) -> Maybe<&2, KV.Val>:
  +t = mems.trie(xs, KV.empty(Unit))
  Bool.pick(Maybe<&2, KV.Val>, Bool.and(Nat.is_lt(0n, n), Nat.is_eq(KV.size(Unit, t), n)), Some{val.set.of(Bool.and(Nat.is_le(n, 512n), all.ints(xs)), n, xs, t)}, None{})

def val.set.go(ints: Bool, +n: Nat, +xs: List<&2, String>, +b: String) -> Maybe<&2, KV.Val>:
  match ints:
    case True{}:
      Some{KV.VColl{KV.CMems{KV.MInts{n, KV.pk.flat(String.drop(b, 8n), Nat.sub(String.length(b), 8n))}}}}
    case False{}:
      val.set.any(n, xs)

# a set of the members xs (sorted: integers in increasing order, from the
# intset b, which are an intset at once when they are 512 at most, its
# string as Redis wrote it, whatever its width: each is there once, so no
# trie of them is made)
def val.set(+sorted: Bool, +xs: List<&2, String>, +b: String) -> Maybe<&2, KV.Val>:
  +n = List.length(&2, String, xs)
  val.set.go(Bool.and(sorted, Bool.and(Nat.is_lt(0n, n), Nat.is_le(n, 512n))), n, xs, b)

def zel.trie(es: List<&2, KV.ZEl>, t: KV.Trie<F.F64>) -> KV.Trie<F.F64>:
  match es:
    case Nil{}:
      t
    case Con{KV.ZEl{m, d}, rest}:
      zel.trie(rest, KV.set(F.F64, t, m, d))

# the elements in a tree, each score as a listpack keeps it when norm
def zel.tree(+norm: Bool, es: List<&2, KV.ZEl>, tr: KV.ZTree) -> KV.ZTree:
  match es:
    case Nil{}:
      tr
    case Con{KV.ZEl{m, +d}, rest}:
      zel.tree(norm, rest, KV.zt.add(tr, m, Bool.pick(F.F64, norm, KV.zset.norm(d), d)))

# 1 for LT, 2 for GT, 0 for EQ
def zel.cmp.n(c: Cmp) -> Nat:
  match c:
    case LT{}:
      1n
    case GT{}:
      2n
    case EQ{}:
      0n

# how the elements (d, m) and es come, c the way the ones before came (3:
# none yet), while ok: 1 each before the next (as a listpack keeps them),
# 2 each after it (as a skiplist is dumped, from the greatest), 0 other
def zel.order.go(es: List<&2, KV.ZEl>, ok: Bool, +c: Nat, +d: F.F64, +m: String) -> Nat:
  match es ok:
    case _ False{}:
      0n
    case Nil{} True{}:
      Bool.pick(Nat, Nat.is_eq(c, 3n), 1n, c)
    case Con{KV.ZEl{+k, +e}, rest} True{}:
      +o = zel.cmp.n(KV.zel.cmp(d, m, e, k))
      zel.order.go(rest, Bool.and(Nat.is_lt(0n, o), Bool.or(Nat.is_eq(c, 3n), Nat.is_eq(o, c))), o, e, k)

def zel.order(es: List<&2, KV.ZEl>) -> Nat:
  match es:
    case Nil{}:
      1n
    case Con{KV.ZEl{+m, +d}, rest}:
      zel.order.go(rest, True{}, 3n, d, m)

def zel.nan(es: List<&2, KV.ZEl>) -> Bool:
  match es:
    case Nil{}:
      False{}
    case Con{KV.ZEl{m, +d}, rest}:
      Bool.or(F.f64.is_nan(d), zel.nan(rest))

def zel.gt(es: List<&2, KV.ZEl>, +l: Nat) -> Bool:
  match es:
    case Nil{}:
      False{}
    case Con{KV.ZEl{+m, d}, rest}:
      Bool.or(Nat.is_lt(l, String.length(m)), zel.gt(rest, l))

# the tree of the n elements es, made at once when they come in order
# (o 1: from a listpack; o 2: from the greatest, as a skiplist is dumped,
# KV.zt.build), else an element at a time
def zel.tree.of(+o: Nat, +n: Nat, es: List<&2, KV.ZEl>) -> KV.ZTree:
  match o:
    case 1n:
      KV.zt.build(n, es)
    case 2n:
      KV.zt.build(n, List.reverse(&2, KV.ZEl, es))
    case _:
      zel.tree(False{}, es, KV.ZTip{})

# the elements es, each score as a listpack keeps it when norm
def zel.norms(+norm: Bool, es: List<&2, KV.ZEl>) -> List<&2, KV.ZEl>:
  match es:
    case Nil{}:
      Nil{}
    case Con{KV.ZEl{m, +d}, rest}:
      KV.ZEl{m, Bool.pick(F.F64, norm, KV.zset.norm(d), d)} <> zel.norms(norm, rest)

# the elements es in order, each score as a listpack keeps it when norm
# (o as for zel.tree.of: those that do not come in order are put in
# order through a tree)
def zel.sorted(+o: Nat, +norm: Bool, es: List<&2, KV.ZEl>) -> List<&2, KV.ZEl>:
  match o:
    case 1n:
      zel.norms(norm, es)
    case 2n:
      zel.norms(norm, List.reverse(&2, KV.ZEl, es))
    case _:
      KV.zt.drain(zel.tree(norm, es, KV.ZTip{}), Nil{})

def val.zset.of(small: Bool, +norm: Bool, +n: Nat, +es: List<&2, KV.ZEl>, t: KV.Trie<F.F64>) -> KV.Val:
  match small:
    case True{}:
      KV.VColl{KV.CZset{KV.zset.of(n, zel.sorted(zel.order(es), norm, es))}}
    case False{}:
      KV.VColl{KV.CZset{KV.ZBig{zel.tree.of(zel.order(es), n, es), t}}}

# a sorted set of the elements es (small: small with them, at most 128;
# lp: as a listpack or ziplist kept them, each score as its text reads, a
# -0 too; a skiplist made small writes a listpack's 0 for a -0)
def val.zset(+lp: Bool, +small: Bool, +es: List<&2, KV.ZEl>) -> Maybe<&2, KV.Val>:
  +n = List.length(&2, KV.ZEl, es)
  +t = zel.trie(es, KV.empty(F.F64))
  Bool.pick(Maybe<&2, KV.Val>, Bool.and(Bool.and(Nat.is_lt(0n, n), Bool.not(zel.nan(es))), Nat.is_eq(KV.size(F.F64, t), n)), Some{val.zset.of(Bool.and(small, Nat.is_le(n, 128n)), Bool.not(lp), n, es, t)}, None{})

# the pairs of a flat list of fields and values (None for an odd one out)
def pairs.of(xs: List<&2, String>, acc: List<&2, KV.HPair>) -> Maybe<&2, List<&2, KV.HPair>>:
  match xs:
    case Nil{}:
      Some{List.reverse(&2, KV.HPair, acc)}
    case Con{f, Con{v, rest}}:
      pairs.of(rest, KV.HP{f, v} <> acc)
    case _:
      None{}

# A listpack's score as zzlStrtod reads its text: strtod of its first 127
# bytes, blanks first, as far as a number goes (0 when none does, a NaN
# for "nan": no value takes one, val.zset); the text Redis writes of a
# double at once (F.f64.parse: glibc's strtod)
def zz.rd(r: F.Rd) -> F.F64:
  match r:
    case F.Rd{v, end, er, tiny}:
      F.f64.of(v)

def zz.prefix(+s: String) -> F.F64:
  +t = String.take(s, 127n)
  zz.rd(F.fl.strtod(F.fmt.d(), t, 0n, F.blank.count(t)))

def zz.or(m: Maybe<&2, F.F64>, +s: String) -> F.F64:
  match m:
    case Some{d}:
      d
    case None{}:
      zz.prefix(s)

def zz.score(+s: String) -> F.F64:
  zz.or(F.f64.parse(s), s)

# the elements of a flat list of members and scores' texts
def zels.of(xs: List<&2, String>, acc: List<&2, KV.ZEl>) -> Maybe<&2, List<&2, KV.ZEl>>:
  match xs:
    case Nil{}:
      Some{List.reverse(&2, KV.ZEl, acc)}
    case Con{m, Con{+s, rest}}:
      zels.of(rest, KV.ZEl{m, zz.score(s)} <> acc)
    case _:
      None{}

# A ZSET's score text as rdbLoadDoubleValue reads it (sscanf's %lg:
# blanks first, as far as a number goes; none is no value)
def z3.rd(r: F.Rd, +b: Nat) -> Maybe<&2, F.F64>:
  match r:
    case F.Rd{v, +end, er, tiny}:
      Bool.pick(Maybe<&2, F.F64>, Nat.is_lt(b, end), Some{F.f64.of(v)}, None{})

def z3.score(+s: String) -> Maybe<&2, F.F64>:
  +b = F.blank.count(s)
  z3.rd(F.fl.strtod(F.fmt.d(), s, 0n, b), b)

# Streams
# -------
# A stream (19, STREAM_LISTPACKS_2; 15, STREAM_LISTPACKS, before Redis
# 7.0, lacks what is marked 19): its count of nodes and the nodes, each
# its master ID (a string of 16 bytes: the time, then the sequence, each
# of 8 bytes, the high first) and its listpack (a string); its count of
# entries; its last ID (the time, then the sequence, each a length); its
# first ID, its greatest deleted ID and its count of entries ever added
# (19); its count of groups and the groups, each its name, its last ID,
# its count of entries read (19; -1 as 0x81 and eight 0xFF), its pending
# entries (a count, then each its ID's 16 bytes, the time of its last
# delivery in ms, 8 bytes the low first, and its count of deliveries)
# and its consumers (a count, then each its name, the time it was last
# seen, 8 bytes, and its pending IDs, a count and 16 bytes each), the
# groups and consumers in their names' order, the IDs in theirs (rdb.c:
# rdbSaveObject, rdbSaveStreamPEL, rdbSaveStreamConsumers).
#
# A node's listpack (t_stream.c: streamAppendItem) holds its master
# entry, its count of live entries, of deleted ones, its number of
# fields, the fields and 0, then its entries: each its flags (1 deleted,
# 2 of the master's fields), its ID as differences from the master ID
# (two integers, the differences of uint64_t's), its number of fields
# and each field and its value (or, of the master's fields, its values
# alone), and lp-count, its count of elements but the first (3 and the
# number of fields, or 4 and twice it). Redis checks that much with
# sanitize-dump-payload yes (streamValidateListpackIntegrity); BendKV
# reads every node so, and refuses also what Redis never writes: a node
# with no entry, a master entry other than the one Redis writes for it
# (its integers the narrowest, lp.ent), counts of live and deleted
# entries other than its entries', a count of elements other than its
# elements' (65535: that many or more), flags other than these, an entry
# of no field, nodes whose master IDs do not increase, live entries whose
# IDs do not, a count of entries other than the live entries', a last ID
# below the last live entry's, a count of entries read past 2^63 - 1 (but
# -1), a time past 2^47 (Redis's are mstime() at most) and an entry of a
# group's pending entries that none or two of its consumers hold.

def xn.of_q.of(small: Bool, +hi: Nat, +lo: Nat) -> KV.XN:
  match small:
    case True{}:
      KV.xn.of(Nat.add(Nat.mul(hi, two32()), lo))
    case False{}:
      +s = F.big.to_dec(q.big(hi, lo))
      KV.xn.dec(s, 0n, String.length(s))

# the number of the 64 bits whose halves are hi and lo
def xn.of_q(+hi: Nat, +lo: Nat) -> KV.XN:
  xn.of_q.of(Nat.is_lt(hi, 65536n), hi, lo)

# the halves of a's 64 bits
def xn.q(+a: KV.XN) -> Q:
  match a:
    case KV.XS{+n}:
      Q{Nat.div(n, two32()), Nat.mod(n, two32())}
    case KV.XL{+h, +l}:
      +s = KV.xn.show(KV.XL{h, l})
      q.of_big(F.big.digits(Nil{}, s, 0n, String.length(s)))

# 8 bytes, the high first
def rd.q8.lo(+hi: Nat, m: Maybe<&1, Nat & String>) -> Maybe<&1, KV.XN & String>:
  match m:
    case Some{p}:
      (+lo, t) = p
      Some{(xn.of_q(hi, lo), t)}
    case None{}:
      None{}

def rd.q8.hi(m: Maybe<&1, Nat & String>) -> Maybe<&1, KV.XN & String>:
  match m:
    case Some{p}:
      (+hi, t) = p
      rd.q8.lo(hi, rd.be(4n, t, 0n))
    case None{}:
      None{}

def rd.q8(s: String) -> Maybe<&1, KV.XN & String>:
  rd.q8.hi(rd.be(4n, s, 0n))

# an ID's 16 bytes
def rd.id.seq(+ms: KV.XN, m: Maybe<&1, KV.XN & String>) -> Maybe<&1, KV.XId & String>:
  match m:
    case Some{p}:
      (+sq, t) = p
      Some{(KV.XId{ms, sq}, t)}
    case None{}:
      None{}

def rd.id.ms(m: Maybe<&1, KV.XN & String>) -> Maybe<&1, KV.XId & String>:
  match m:
    case Some{p}:
      (+ms, t) = p
      rd.id.seq(ms, rd.q8(t))
    case None{}:
      None{}

def rd.id(s: String) -> Maybe<&1, KV.XId & String>:
  rd.id.ms(rd.q8(s))

# a length (rdbLoadLen) of any 64 bits
def rd.xn.big(x: Nat, t: String) -> Maybe<&1, KV.XN & String>:
  match x:
    case 128n:
      rd.q8.lo(0n, rd.be(4n, t, 0n))
    case 129n:
      rd.q8(t)
    case _:
      None{}

def rd.xn.of(k: Nat, +x: Nat, t: String) -> Maybe<&1, KV.XN & String>:
  match k:
    case 1n:
      rd.q8.lo(0n, rd.be(1n, t, Nat.mod(x, 64n)))
    case 2n:
      rd.xn.big(x, t)
    case _:
      Some{(KV.XS{Nat.mod(x, 64n)}, t)}

def rd.xn(s: String) -> Maybe<&1, KV.XN & String>:
  match s:
    case SCon{Chr{+x}, t}:
      rd.xn.of(U32.to_nat(U32.shrn(x, 6n)), U32.to_nat(x), t)
    case SNil{}:
      None{}

# two lengths: an ID's time and sequence
def rd.xid.seq(+ms: KV.XN, m: Maybe<&1, KV.XN & String>) -> Maybe<&1, KV.XId & String>:
  match m:
    case Some{p}:
      (+sq, t) = p
      Some{(KV.XId{ms, sq}, t)}
    case None{}:
      None{}

def rd.xid.ms(m: Maybe<&1, KV.XN & String>) -> Maybe<&1, KV.XId & String>:
  match m:
    case Some{p}:
      (+ms, t) = p
      rd.xid.seq(ms, rd.xn(t))
    case None{}:
      None{}

def rd.xid(s: String) -> Maybe<&1, KV.XId & String>:
  rd.xid.ms(rd.xn(s))

# a time in ms (rdbLoadMillisecondTime: 8 bytes, the low first, a long
# long), from 0 to below 2^47: its low 4 bytes, then its high 4, below
# 2^15 (6 bytes read as one would take rd.le's weight to 2^48)
def rd.ms.of(ok: Bool, +hi: Nat, +lo: Nat, t: String) -> Maybe<&1, Nat & String>:
  match ok:
    case True{}:
      Some{(Nat.add(Nat.mul(hi, two32()), lo), t)}
    case False{}:
      None{}

def rd.ms.hi(+lo: Nat, m: Maybe<&1, Nat & String>) -> Maybe<&1, Nat & String>:
  match m:
    case Some{p}:
      (+hi, t) = p
      rd.ms.of(Nat.is_lt(hi, 32768n), hi, lo, t)
    case None{}:
      None{}

def rd.ms.lo(m: Maybe<&1, Nat & String>) -> Maybe<&1, Nat & String>:
  match m:
    case Some{p}:
      (+lo, t) = p
      rd.ms.hi(lo, rd.le(4n, t, 1n, 0n))
    case None{}:
      None{}

def rd.ms(s: String) -> Maybe<&1, Nat & String>:
  rd.ms.lo(rd.le(4n, s, 1n, 0n))

# A listpack's element read with its size (lp.next, which drops it): its
# text, the bytes of its encoding, data and backlen, and what follows it;
# or the end and what follows it; or bytes that are no element
type LpS is Data:
  LpSOk{v: String, n: Nat, t: String}
  LpSFin{t: String}
  LpSBad{}

def lps.ok(same: Bool, v: String, +n: Nat, t: String) -> LpS:
  match same:
    case True{}:
      LpSOk{v, n, t}
    case False{}:
      LpSBad{}

def lps.back(+sz: Nat, v: String, m: Maybe<&1, String & String>) -> LpS:
  match m:
    case Some{p}:
      (b, t) = p
      lps.ok(String.eq(b, lp.back(sz, "")), v, Nat.add(sz, lp.back.n(sz)), t)
    case None{}:
      LpSBad{}

def lps.tail.of(e: LpE, +t: String) -> LpS:
  match e:
    case LpE{v, +sz}:
      lps.back(sz, v, rd.take(t, lp.back.n(sz)))
    case LpEnd{}:
      LpSFin{t}

def lps.tail(m: Maybe<&1, LpE & String>) -> LpS:
  match m:
    case Some{p}:
      (e, +t) = p
      lps.tail.of(e, t)
    case None{}:
      LpSBad{}

def lp.step(s: String) -> LpS:
  match s:
    case SCon{Chr{+x}, t}:
      +n = U32.to_nat(x)
      lps.tail(lp.head(lp.kind(n), n, t))
    case SNil{}:
      LpSBad{}

# an element's integer, when it is one from 0 to below 10^14 (an integer's
# text, or a string's that is one: lpGetIntegerIfValid)
def xe.small.of(i: IV) -> Maybe<&2, Nat>:
  match i:
    case IN{False{}, +m}:
      Some{m}
    case _:
      None{}

def xe.small(+v: String) -> Maybe<&2, Nat>:
  xe.small.of(iv(v))

def xe.is(m: Maybe<&2, Nat>, +n: Nat) -> Bool:
  match m:
    case Some{+k}:
      Nat.is_eq(k, n)
    case None{}:
      False{}

# an ID's difference from the master ID: the integer's 64 bits
def xe.delta.of(ok: Bool, +v: String) -> Maybe<&2, KV.XN>:
  match ok:
    case True{}:
      Some{KV.xn.of_int(v)}
    case False{}:
      None{}

def xe.delta(+v: String) -> Maybe<&2, KV.XN>:
  xe.delta.of(KV.ints.ok(v), v)

# An entry read: its flags, its ID's differences from the master ID, its
# size in bytes and its count of elements
type XEnt is Data:
  XEnt{fl: Nat, ms: KV.XN, seq: KV.XN, size: Nat, nel: Nat}

# the sizes of r, the element just read, and of k more after it, after
# acc, and the bytes after them
def xe.skip(k: Nat, r: LpS, +acc: Nat) -> Maybe<&1, Nat & String>:
  match k r:
    case 0n LpSOk{v, +n, t}:
      Some{(Nat.add(acc, n), t)}
    case 1n+j LpSOk{v, +n, t}:
      xe.skip(j, lp.step(t), Nat.add(acc, n))
    case _ _:
      None{}

def xe.done(ok: Bool, e: XEnt, t: String) -> Maybe<&1, XEnt & String>:
  match ok:
    case True{}:
      Some{(e, t)}
    case False{}:
      None{}

# lp-count, want
def xe.cnt(r: LpS, +want: Nat, +f: Nat, +ms: KV.XN, +sq: KV.XN, +sz: Nat) -> Maybe<&1, XEnt & String>:
  match r:
    case LpSOk{+v, +n, t}:
      xe.done(xe.is(xe.small(v), want), XEnt{f, ms, sq, Nat.add(sz, n), Nat.add(want, 1n)}, t)
    case _:
      None{}

def xe.vals(m: Maybe<&1, Nat & String>, +want: Nat, +f: Nat, +ms: KV.XN, +sq: KV.XN) -> Maybe<&1, XEnt & String>:
  match m:
    case Some{p}:
      (+sz, t) = p
      xe.cnt(lp.step(t), want, f, ms, sq, sz)
    case None{}:
      None{}

# the fields and values of an entry of nf fields of its own
def xe.own(nf: Maybe<&2, Nat>, +f: Nat, +ms: KV.XN, +sq: KV.XN, +sz: Nat, t: String) -> Maybe<&1, XEnt & String>:
  match nf:
    case Some{+k}:
      match k:
        case 0n:
          None{}
        case 1n+j:
          +w = Nat.add(Nat.mul(2n, j), 2n)
          xe.vals(xe.skip(Nat.sub(w, 1n), lp.step(t), sz), Nat.add(w, 4n), f, ms, sq)
    case None{}:
      None{}

def xe.nf(r: LpS, +f: Nat, +ms: KV.XN, +sq: KV.XN, +sz: Nat) -> Maybe<&1, XEnt & String>:
  match r:
    case LpSOk{+v, +n, t}:
      xe.own(xe.small(v), f, ms, sq, Nat.add(sz, n), t)
    case _:
      None{}

# after the ID: the values of the master's mf fields, or the entry's own
def xe.body(same: Bool, +f: Nat, +ms: KV.XN, +sq: KV.XN, +sz: Nat, t: String, +mf: Nat) -> Maybe<&1, XEnt & String>:
  match same:
    case True{}:
      xe.vals(xe.skip(Nat.sub(mf, 1n), lp.step(t), sz), Nat.add(mf, 3n), f, ms, sq)
    case False{}:
      xe.nf(lp.step(t), f, ms, sq, sz)

def xe.id(+f: Nat, +ms: KV.XN, q: Maybe<&2, KV.XN>, +sz: Nat, t: String, +mf: Nat) -> Maybe<&1, XEnt & String>:
  match q:
    case Some{+sq}:
      xe.body(Nat.is_eq(Nat.mod(Nat.div(f, 2n), 2n), 1n), f, ms, sq, sz, t, mf)
    case None{}:
      None{}

def xe.seq(fl: Maybe<&2, Nat>, ms: Maybe<&2, KV.XN>, +sz: Nat, r: LpS, +mf: Nat) -> Maybe<&1, XEnt & String>:
  match fl ms r:
    case Some{+f} Some{+m} LpSOk{+v, +n, t}:
      xe.id(f, m, xe.delta(v), Nat.add(sz, n), t, mf)
    case _ _ _:
      None{}

def xe.ms(fl: Maybe<&2, Nat>, +sz: Nat, r: LpS, +mf: Nat) -> Maybe<&1, XEnt & String>:
  match fl r:
    case Some{+f} LpSOk{+v, +n, t}:
      xe.seq(Bool.pick(Maybe<&2, Nat>, Nat.is_le(f, 3n), Some{f}, None{}), xe.delta(v), Nat.add(sz, n), lp.step(t), mf)
    case _ _:
      None{}

def xe.flags(r: LpS, +mf: Nat) -> Maybe<&1, XEnt & String>:
  match r:
    case LpSOk{+v, +n, t}:
      xe.ms(xe.small(v), n, lp.step(t), mf)
    case _:
      None{}

# the entry at the front of s, of a node of mf master fields
def xe.ent(s: String, +mf: Nat) -> Maybe<&1, XEnt & String>:
  xe.flags(lp.step(s), mf)

# A walk of a stream's nodes: the node's live entries, deleted entries,
# elements and entries' bytes so far (the newest first); the first live
# entry's ID and the last's so far, the stream's live entries so far, and
# whether all is as it must be so far. XWOf is never built: it makes XW a
# node of its own.
type XW is Data:
  XW{live: Nat, dead: Nat, nel: Nat, es: List<&2, String>, first: Maybe<&2, KV.XId>, last: Maybe<&2, KV.XId>, tot: Nat, ok: Bool}
  XWOf{x: XW}

def xw.start() -> XW:
  XW{0n, 0n, 0n, Nil{}, None{}, None{}, 0n, True{}}

# the walk at a node's start
def xw.node(w: XW) -> XW:
  match w:
    case XW{live, dead, nel, es, first, last, tot, ok}:
      XW{0n, 0n, 0n, Nil{}, first, last, tot, ok}
    case XWOf{x}:
      xw.node(x)

def xw.first(m: Maybe<&2, KV.XId>, +id: KV.XId) -> Maybe<&2, KV.XId>:
  match m:
    case Some{x}:
      Some{x}
    case None{}:
      Some{id}

def xw.after(+m: Maybe<&2, KV.XId>, +id: KV.XId) -> Bool:
  match m:
    case Some{+x}:
      Cmp.is_lt(KV.xid.cmp(x, id))
    case None{}:
      True{}

def xw.put(del: Bool, +id: KV.XId, x: String, +n: Nat, +live: Nat, +dead: Nat, +nel: Nat, es: List<&2, String>, first: Maybe<&2, KV.XId>, +last: Maybe<&2, KV.XId>, +tot: Nat, +ok: Bool) -> XW:
  match del:
    case True{}:
      XW{live, Nat.add(dead, 1n), Nat.add(nel, n), x <> es, first, last, tot, ok}
    case False{}:
      XW{Nat.add(live, 1n), dead, Nat.add(nel, n), x <> es, xw.first(first, id), Some{id}, Nat.add(tot, 1n), Bool.and(ok, xw.after(last, id))}

# the ID whose differences from mid are ms and sq (as uint64_t's add)
def xid.plus(+mid: KV.XId, +ms: KV.XN, +sq: KV.XN) -> KV.XId:
  match mid:
    case KV.XId{+mm, +mq}:
      KV.XId{KV.xn.add(mm, ms), KV.xn.add(mq, sq)}

# the walk with e, the entry at the front of s, of the node of master ID
# mid
def xw.add(w: XW, +mid: KV.XId, e: XEnt, +s: String) -> XW:
  match w e:
    case XW{+live, +dead, +nel, es, first, +last, +tot, +ok} XEnt{+fl, +ms, +sq, +sz, +n}:
      xw.put(Nat.is_eq(Nat.mod(fl, 2n), 1n), xid.plus(mid, ms, sq), String.take(s, sz), n, live, dead, nel, es, first, last, tot, ok)
    case XWOf{x} _:
      xw.add(x, mid, e, s)

# the walk with the entry of m, read from the front of s, and k more
# after it, and the bytes after them
def xw.go(k: Nat, m: Maybe<&1, XEnt & String>, +s: String, +mid: KV.XId, +mf: Nat, w: XW) -> Maybe<&1, XW & String>:
  match k m:
    case 0n Some{p}:
      (e, +t) = p
      Some{(xw.add(w, mid, e, s), t)}
    case 1n+j Some{p}:
      (e, +t) = p
      xw.go(j, xe.ent(t, mf), t, mid, mf, xw.add(w, mid, e, s))
    case _ None{}:
      None{}

# A node read: its node, the walk after it and the bytes after it
type XNRd is Data:
  XNOk{x: KV.XNode, w: XW, t: String}
  XNBad{}

def xnd.ok(ok: Bool, x: KV.XNode, w: XW, t: String) -> XNRd:
  match ok:
    case True{}:
      XNOk{x, w, t}
    case False{}:
      XNBad{}

def xnd.fin(w: XW, +mid: KV.XId, mfs: List<&2, String>, +live: Nat, +dead: Nat, +bytes: Nat, +ne: Nat, +nf: Nat, +ok: Bool, t: String) -> XNRd:
  match w:
    case XW{+l, +d, +nel, es, first, last, tot, wok}:
      +all = Nat.add(Nat.add(nf, 4n), nel)
      xnd.ok(Bool.and(Bool.and(ok, Bool.and(Nat.is_eq(l, live), Nat.is_eq(d, dead))), Nat.is_eq(ne, Nat.min(all, 65535n))), KV.XNd{mid, mfs, live, dead, bytes, all, es}, XW{l, d, nel, Nil{}, first, last, tot, wok}, t)
    case XWOf{x}:
      xnd.fin(x, mid, mfs, live, dead, bytes, ne, nf, ok, t)

# the end of the listpack: 0xFF, its last byte
def xnd.end(r: LpS) -> Bool:
  match r:
    case LpSFin{SNil{}}:
      True{}
    case _:
      False{}

def xnd.walked(m: Maybe<&1, XW & String>, +mid: KV.XId, mfs: List<&2, String>, +live: Nat, +dead: Nat, +bytes: Nat, +ne: Nat, +nf: Nat, +ok: Bool, t: String) -> XNRd:
  match m:
    case Some{p}:
      (w, u) = p
      xnd.fin(w, mid, mfs, live, dead, bytes, ne, nf, Bool.and(ok, xnd.end(lp.step(u))), t)
    case None{}:
      XNBad{}

# the master entry Redis writes for these counts and fields
def xnd.master(+live: Nat, +dead: Nat, +nf: Nat, +mfs: List<&2, String>, rest: String) -> String:
  lp.ent(Nat.show(live), lp.ent(Nat.show(dead), lp.ent(Nat.show(nf), lp.ents(mfs, lp.ent("0", rest)))))

# the entries after the master entry (at the front of u), its own bytes at
# the front of h
def xnd.ents(+mid: KV.XId, +mfs: List<&2, String>, +live: Nat, +dead: Nat, +nf: Nat, +bytes: Nat, +ne: Nat, +h: String, +u: String, w: XW, t: String) -> XNRd:
  +m = xnd.master(live, dead, nf, mfs, "")
  +k = Nat.add(live, dead)
  +same = String.eq(String.take(h, String.length(m)), m)
  xnd.walked(xw.go(Nat.sub(k, 1n), xe.ent(u, nf), u, mid, nf, xw.node(w)), mid, mfs, live, dead, bytes, ne, nf, Bool.and(same, Nat.is_lt(0n, k)), t)

def xnd.zero(r: LpS, +mid: KV.XId, +mfs: List<&2, String>, +live: Nat, +dead: Nat, +nf: Nat, +bytes: Nat, +ne: Nat, +h: String, w: XW, t: String) -> XNRd:
  match r:
    case LpSOk{+v, n, +u}:
      xnd.ents(mid, mfs, live, dead, nf, bytes, ne, h, u, w, t)
    case _:
      XNBad{}

# the master's fields after r, the one just read, k more after it (acc
# the newest first)
def xm.fields(k: Nat, r: LpS, acc: List<&2, String>) -> Maybe<&1, List<&2, String> & String>:
  match k r:
    case 0n LpSOk{v, n, t}:
      Some{(List.reverse(&2, String, v <> acc), t)}
    case 1n+j LpSOk{v, n, t}:
      xm.fields(j, lp.step(t), v <> acc)
    case _ _:
      None{}

def xnd.fields(m: Maybe<&1, List<&2, String> & String>, +mid: KV.XId, +live: Nat, +dead: Nat, +nf: Nat, +bytes: Nat, +ne: Nat, +h: String, w: XW, t: String) -> XNRd:
  match m:
    case Some{p}:
      (+mfs, u) = p
      xnd.zero(lp.step(u), mid, mfs, live, dead, nf, bytes, ne, h, w, t)
    case None{}:
      XNBad{}

def xnd.nf(nf: Maybe<&2, Nat>, +mid: KV.XId, +live: Nat, +dead: Nat, +bytes: Nat, +ne: Nat, +h: String, u: String, w: XW, t: String) -> XNRd:
  match nf:
    case Some{+k}:
      match k:
        case 0n:
          XNBad{}
        case 1n+j:
          xnd.fields(xm.fields(j, lp.step(u), Nil{}), mid, live, dead, Nat.add(j, 1n), bytes, ne, h, w, t)
    case None{}:
      XNBad{}

def xnd.counts(live: Maybe<&2, Nat>, dead: Maybe<&2, Nat>, r: LpS, +mid: KV.XId, +bytes: Nat, +ne: Nat, +h: String, w: XW, t: String) -> XNRd:
  match live dead r:
    case Some{+l} Some{+d} LpSOk{+v, n, u}:
      xnd.nf(xe.small(v), mid, l, d, bytes, ne, h, u, w, t)
    case _ _ _:
      XNBad{}

def xnd.dead(live: Maybe<&2, Nat>, r: LpS, +mid: KV.XId, +bytes: Nat, +ne: Nat, +h: String, w: XW, t: String) -> XNRd:
  match r:
    case LpSOk{+v, n, u}:
      xnd.counts(live, xe.small(v), lp.step(u), mid, bytes, ne, h, w, t)
    case _:
      XNBad{}

def xnd.live(r: LpS, +mid: KV.XId, +bytes: Nat, +ne: Nat, +h: String, w: XW, t: String) -> XNRd:
  match r:
    case LpSOk{+v, n, u}:
      xnd.dead(xe.small(v), lp.step(u), mid, bytes, ne, h, w, t)
    case _:
      XNBad{}

def xnd.count(m: Maybe<&1, Nat & String>, +mid: KV.XId, +bytes: Nat, w: XW, t: String) -> XNRd:
  match m:
    case Some{p}:
      (+ne, +h) = p
      xnd.live(lp.step(h), mid, bytes, ne, h, w, t)
    case None{}:
      XNBad{}

def xnd.size(ok: Bool, +mid: KV.XId, +bytes: Nat, u: String, w: XW, t: String) -> XNRd:
  match ok:
    case True{}:
      xnd.count(rd.le(2n, u, 1n, 0n), mid, bytes, w, t)
    case False{}:
      XNBad{}

def xnd.total(m: Maybe<&1, Nat & String>, +mid: KV.XId, +bytes: Nat, w: XW, t: String) -> XNRd:
  match m:
    case Some{p}:
      (+total, u) = p
      xnd.size(Nat.is_eq(total, bytes), mid, bytes, u, w, t)
    case None{}:
      XNBad{}

# the node of master ID mid and listpack b (t the bytes after it)
def xnd.of(+mid: KV.XId, +b: String, w: XW, t: String) -> XNRd:
  xnd.total(rd.le(4n, b, 1n, 0n), mid, String.length(b), w, t)

def xnd.lp(+mid: KV.XId, m: Maybe<&1, String & String>, w: XW) -> XNRd:
  match m:
    case Some{p}:
      (+b, t) = p
      xnd.of(mid, b, w, t)
    case None{}:
      XNBad{}

# a node's key: 16 bytes, its master ID
def xnd.mid.of(m: Maybe<&1, KV.XId & String>) -> Maybe<&2, KV.XId>:
  match m:
    case Some{p}:
      (id, t) = p
      Some{id}
    case None{}:
      None{}

def xnd.key(+k: String) -> Maybe<&2, KV.XId>:
  Bool.pick(Maybe<&2, KV.XId>, Nat.is_eq(String.length(k), 16n), xnd.mid.of(rd.id(k)), None{})

def xnd.at(mid: Maybe<&2, KV.XId>, t: String, w: XW) -> XNRd:
  match mid:
    case Some{+id}:
      xnd.lp(id, rd.str(t), w)
    case None{}:
      XNBad{}

def xnd.rd.of(m: Maybe<&1, String & String>, w: XW) -> XNRd:
  match m:
    case Some{p}:
      (+k, t) = p
      xnd.at(xnd.key(k), t, w)
    case None{}:
      XNBad{}

# the node at the front of s
def xnd.rd(s: String, w: XW) -> XNRd:
  xnd.rd.of(rd.str(s), w)

# The nodes read: their tree, the walk after them and the bytes after
# them
type XSRd is Data:
  XSOk{ns: KV.XNodes, w: XW, t: String}
  XSBad{}

def xns.after(+m: Maybe<&2, KV.XId>, +x: KV.XNode) -> Bool:
  xw.after(m, KV.xnode.mid(x))

def xns.done(ok: Bool, ns: KV.XNodes, w: XW, t: String) -> XSRd:
  match ok:
    case True{}:
      XSOk{ns, w, t}
    case False{}:
      XSBad{}

# the nodes with r, the one just read, and k more after it; prev the
# last one's master ID
def xns.go(k: Nat, r: XNRd, +prev: Maybe<&2, KV.XId>, +ok: Bool, ns: KV.XNodes) -> XSRd:
  match k r:
    case 0n XNOk{+x, w, t}:
      xns.done(Bool.and(ok, xns.after(prev, x)), KV.xns.put(x, ns), w, t)
    case 1n+j XNOk{+x, w, t}:
      xns.go(j, xnd.rd(t, w), Some{KV.xnode.mid(x)}, Bool.and(ok, xns.after(prev, x)), KV.xns.put(x, ns))
    case _ _:
      XSBad{}

def xns.rd.n(n: Nat, t: String) -> XSRd:
  match n:
    case 0n:
      XSOk{KV.XNTip{}, xw.start(), t}
    case 1n+j:
      xns.go(j, xnd.rd(t, xw.start()), None{}, True{}, KV.XNTip{})

def xns.rd.of(m: Maybe<&1, Nat & String>) -> XSRd:
  match m:
    case Some{p}:
      (n, t) = p
      xns.rd.n(n, t)
    case None{}:
      XSBad{}

# Groups, read after the nodes

# a pending entry: its ID, the time of its last delivery and its count
# of deliveries (its owner set when its consumer is read)
def xnk.cnt(+id: KV.XId, +tm: Nat, m: Maybe<&1, KV.XN & String>) -> Maybe<&1, KV.XNack & String>:
  match m:
    case Some{p}:
      (+c, t) = p
      Some{(KV.XNk{id, "", tm, c}, t)}
    case None{}:
      None{}

def xnk.time(+id: KV.XId, m: Maybe<&1, Nat & String>) -> Maybe<&1, KV.XNack & String>:
  match m:
    case Some{p}:
      (+tm, t) = p
      xnk.cnt(id, tm, rd.xn(t))
    case None{}:
      None{}

def xnk.id(m: Maybe<&1, KV.XId & String>) -> Maybe<&1, KV.XNack & String>:
  match m:
    case Some{p}:
      (+id, t) = p
      xnk.time(id, rd.ms(t))
    case None{}:
      None{}

def xnk.rd(s: String) -> Maybe<&1, KV.XNack & String>:
  xnk.id(rd.id(s))

def xpl.new(+p: KV.XPel, +x: KV.XNack) -> Bool:
  +k = KV.xnack.id(x)
  Bool.not(Maybe.is_some(&2, KV.XNack, KV.xpl.find(p, KV.xpl.at(p, k), k)))

def xpl.done(ok: Bool, p: KV.XPel, t: String) -> Maybe<&1, KV.XPel & String>:
  match ok:
    case True{}:
      Some{(p, t)}
    case False{}:
      None{}

# the pending entries with r, the one just read, and k more after it
def xpl.go(k: Nat, r: Maybe<&1, KV.XNack & String>, +ok: Bool, +p: KV.XPel) -> Maybe<&1, KV.XPel & String>:
  match k r:
    case 0n Some{q}:
      (+x, t) = q
      xpl.done(Bool.and(ok, xpl.new(p, x)), KV.xpl.put(x, p), t)
    case 1n+j Some{q}:
      (+x, t) = q
      xpl.go(j, xnk.rd(t), Bool.and(ok, xpl.new(p, x)), KV.xpl.put(x, p))
    case _ None{}:
      None{}

def xpl.rd(+n: Nat, t: String) -> Maybe<&1, KV.XPel & String>:
  match n:
    case 0n:
      Some{(KV.XPTip{}, t)}
    case 1n+j:
      xpl.go(j, xnk.rd(t), True{}, KV.XPTip{})

# a pending entry delivered to the consumer name
def xnk.owned(x: KV.XNack, +name: String) -> KV.XNack:
  match x:
    case KV.XNk{+id, o, +tm, +c}:
      KV.XNk{id, name, tm, c}
    case KV.XNkOf{y}:
      xnk.owned(y, name)

def xpl.own.of(m: Maybe<&2, KV.XNack>, +name: String, p: KV.XPel) -> KV.XPel:
  match m:
    case Some{x}:
      KV.xpl.set(xnk.owned(x, name), p)
    case None{}:
      p

# p with the entry of ID id (when it holds one) delivered to name
def xpl.own(+p: KV.XPel, +id: KV.XId, +name: String) -> KV.XPel:
  xpl.own.of(KV.xpl.find(p, KV.xpl.at(p, id), id), name, p)

def xpl.has(+p: KV.XPel, +id: KV.XId) -> Bool:
  Maybe.is_some(&2, KV.XNack, KV.xpl.find(p, KV.xpl.at(p, id), id))

def xis.has(+t: KV.XIds, +id: KV.XId) -> Bool:
  Maybe.is_some(&2, KV.XId, KV.xis.find(t, KV.xis.at(t, id), id))

# A consumer's pending IDs read: whether all is as it must be, its IDs,
# the IDs of the group's consumers so far, the group's pending entries
# with their owners so far, and the bytes after them
type XIRd is Data:
  XIOk{ok: Bool, ids: KV.XIds, held: KV.XIds, pel: KV.XPel, t: String}
  XIBad{}

# a consumer's IDs with the one of m and k more after it: each pending in
# the group, and held by no consumer before
def xids.go(k: Nat, m: Maybe<&1, KV.XId & String>, +name: String, +ok: Bool, ids: KV.XIds, +held: KV.XIds, +pel: KV.XPel) -> XIRd:
  match k m:
    case 0n Some{p}:
      (+id, t) = p
      XIOk{Bool.and(ok, Bool.and(xpl.has(pel, id), Bool.not(xis.has(held, id)))), KV.xis.put(id, ids), KV.xis.put(id, held), xpl.own(pel, id, name), t}
    case 1n+j Some{p}:
      (+id, t) = p
      xids.go(j, rd.id(t), name, Bool.and(ok, Bool.and(xpl.has(pel, id), Bool.not(xis.has(held, id)))), KV.xis.put(id, ids), KV.xis.put(id, held), xpl.own(pel, id, name))
    case _ None{}:
      XIBad{}

def xids.rd.n(n: Nat, t: String, +name: String, held: KV.XIds, pel: KV.XPel) -> XIRd:
  match n:
    case 0n:
      XIOk{True{}, KV.XITip{}, held, pel, t}
    case 1n+j:
      xids.go(j, rd.id(t), name, True{}, KV.XITip{}, held, pel)

def xids.rd(m: Maybe<&1, Nat & String>, +name: String, held: KV.XIds, pel: KV.XPel) -> XIRd:
  match m:
    case Some{p}:
      (n, t) = p
      xids.rd.n(n, t, name, held, pel)
    case None{}:
      XIBad{}

# A consumer read: it, whether all is as it must be, the IDs held and
# the pending entries after it, and the bytes after it
type XCRd is Data:
  XCOk{c: KV.XCon, ok: Bool, held: KV.XIds, pel: KV.XPel, t: String}
  XCBad{}

def xc.ids(r: XIRd, +name: String, +seen: Nat) -> XCRd:
  match r:
    case XIOk{ok, ids, held, pel, t}:
      XCOk{KV.XCon{name, seen, ids}, ok, held, pel, t}
    case XIBad{}:
      XCBad{}

def xc.seen(m: Maybe<&1, Nat & String>, +name: String, held: KV.XIds, pel: KV.XPel) -> XCRd:
  match m:
    case Some{p}:
      (+seen, t) = p
      xc.ids(xids.rd(rd.num(t), name, held, pel), name, seen)
    case None{}:
      XCBad{}

def xc.name(m: Maybe<&1, String & String>, held: KV.XIds, pel: KV.XPel) -> XCRd:
  match m:
    case Some{p}:
      (+name, t) = p
      xc.seen(rd.ms(t), name, held, pel)
    case None{}:
      XCBad{}

def xc.rd(s: String, held: KV.XIds, pel: KV.XPel) -> XCRd:
  xc.name(rd.str(s), held, pel)

def xcs.new(+cs: KV.XCons, +c: KV.XCon) -> Bool:
  +k = KV.xcon.name(c)
  Bool.not(Maybe.is_some(&2, KV.XCon, KV.xcs.find(cs, KV.xcs.at(cs, k), k)))

# A group's consumers read: them, whether all is as it must be, the IDs
# held, the pending entries with their owners, and the bytes after them
type XKRd is Data:
  XKOk{cs: KV.XCons, ok: Bool, held: KV.XIds, pel: KV.XPel, t: String}
  XKBad{}

# the consumers with r, the one just read, and k more after it
def xcs.go(k: Nat, r: XCRd, +ok: Bool, +cs: KV.XCons) -> XKRd:
  match k r:
    case 0n XCOk{+c, +cok, held, pel, t}:
      XKOk{KV.xcs.put(c, cs), Bool.and(Bool.and(ok, cok), xcs.new(cs, c)), held, pel, t}
    case 1n+j XCOk{+c, +cok, held, pel, t}:
      xcs.go(j, xc.rd(t, held, pel), Bool.and(Bool.and(ok, cok), xcs.new(cs, c)), KV.xcs.put(c, cs))
    case _ _:
      XKBad{}

def xcs.rd.n(n: Nat, t: String, pel: KV.XPel) -> XKRd:
  match n:
    case 0n:
      XKOk{KV.XCTip{}, True{}, KV.XITip{}, pel, t}
    case 1n+j:
      xcs.go(j, xc.rd(t, KV.XITip{}, pel), True{}, KV.XCTip{})

def xcs.rd(m: Maybe<&1, Nat & String>, pel: KV.XPel) -> XKRd:
  match m:
    case Some{p}:
      (n, t) = p
      xcs.rd.n(n, t, pel)
    case None{}:
      XKBad{}

# What a stream's groups are read against: its count of entries, its
# last ID and its first live entry's ID (the count of a group's entries
# read, of a stream of type 15, is estimated from them)
type XAt is Data:
  XAt{len: Nat, last: KV.XId, first: KV.XId}

# 2^63 and 2^64 - 1
def xn.p63() -> KV.XN:
  KV.XL{92233n, Nat.add(Nat.mul(7203685n, 10000000n), 4775808n)}

def xn.max() -> KV.XN:
  KV.XL{184467n, Nat.sub(KV.xn.top.lo(), 1n)}

# a count of entries read, of 19: -1, or one below 2^63
def xrd.of(+n: KV.XN) -> Maybe<&2, KV.XRd>:
  Bool.pick(Maybe<&2, KV.XRd>, KV.xn.is_eq(n, xn.max()), Some{KV.XRdNone{}}, Bool.pick(Maybe<&2, KV.XRd>, Cmp.is_lt(KV.xn.cmp(n, xn.p63())), Some{KV.XRdN{n}}, None{}))

# of 15 (streamEstimateDistanceFromFirstEverEntry, with entries_added the
# count of entries and max_deleted_entry_id 0-0): 0 for an empty stream;
# the count for the last ID, none past it; else 0 before the first live
# entry, 1 at it, none after it
def xrd.est.first(c: Cmp) -> KV.XRd:
  match c:
    case LT{}:
      KV.XRdN{KV.XS{0n}}
    case EQ{}:
      KV.XRdN{KV.XS{1n}}
    case GT{}:
      KV.XRdNone{}

def xrd.est.last(c: Cmp, +n: Nat, +id: KV.XId, +first: KV.XId) -> KV.XRd:
  match c:
    case EQ{}:
      KV.XRdN{KV.xn.of(n)}
    case GT{}:
      KV.XRdNone{}
    case LT{}:
      xrd.est.first(KV.xid.cmp(id, first))

def xrd.est(+a: XAt, +id: KV.XId) -> KV.XRd:
  match a:
    case XAt{+n, +last, +first}:
      Bool.pick(KV.XRd, Nat.is_eq(n, 0n), KV.XRdN{KV.XS{0n}}, xrd.est.last(KV.xid.cmp(id, last), n, id, first))

# A group read: it, whether all is as it must be, and the bytes after it
type XGRd is Data:
  XGOk{g: KV.XGroup, ok: Bool, t: String}
  XGBad{}

def xg.cons(r: XKRd, +name: String, +last: KV.XId, +rd: KV.XRd) -> XGRd:
  match r:
    case XKOk{cs, ok, +held, +pel, t}:
      XGOk{KV.XGrp{name, last, rd, pel, cs}, Bool.and(ok, Nat.is_eq(KV.xis.size(held), KV.xpl.size(pel))), t}
    case XKBad{}:
      XGBad{}

def xg.pel(m: Maybe<&1, KV.XPel & String>, +name: String, +last: KV.XId, +rd: KV.XRd) -> XGRd:
  match m:
    case Some{p}:
      (pel, t) = p
      xg.cons(xcs.rd(rd.num(t), pel), name, last, rd)
    case None{}:
      XGBad{}

def xg.pels(m: Maybe<&1, Nat & String>, +name: String, +last: KV.XId, +rd: KV.XRd) -> XGRd:
  match m:
    case Some{p}:
      (+n, t) = p
      xg.pel(xpl.rd(n, t), name, last, rd)
    case None{}:
      XGBad{}

def xg.read(rd: Maybe<&2, KV.XRd>, +name: String, +last: KV.XId, t: String) -> XGRd:
  match rd:
    case Some{+r}:
      xg.pels(rd.num(t), name, last, r)
    case None{}:
      XGBad{}

def xg.read19(m: Maybe<&1, KV.XN & String>, +name: String, +last: KV.XId) -> XGRd:
  match m:
    case Some{p}:
      (+n, t) = p
      xg.read(xrd.of(n), name, last, t)
    case None{}:
      XGBad{}

def xg.last(two: Bool, m: Maybe<&1, KV.XId & String>, +name: String, +a: XAt) -> XGRd:
  match two m:
    case True{} Some{p}:
      (+last, t) = p
      xg.read19(rd.xn(t), name, last)
    case False{} Some{p}:
      (+last, t) = p
      xg.read(Some{xrd.est(a, last)}, name, last, t)
    case _ None{}:
      XGBad{}

def xg.name(+two: Bool, m: Maybe<&1, String & String>, +a: XAt) -> XGRd:
  match m:
    case Some{p}:
      (+name, t) = p
      xg.last(two, rd.xid(t), name, a)
    case None{}:
      XGBad{}

# the group at the front of s (two: of type 19)
def xg.rd(s: String, +two: Bool, +a: XAt) -> XGRd:
  xg.name(two, rd.str(s), a)

def xgs.new(+gs: KV.XGroups, +g: KV.XGroup) -> Bool:
  +k = KV.xgroup.name(g)
  Bool.not(Maybe.is_some(&2, KV.XGroup, KV.xgs.find(gs, KV.xgs.at(gs, k), k)))

def xgs.done(ok: Bool, gs: KV.XGroups, t: String) -> Maybe<&1, KV.XGroups & String>:
  match ok:
    case True{}:
      Some{(gs, t)}
    case False{}:
      None{}

# the groups with r, the one just read, and k more after it
def xgs.go(k: Nat, r: XGRd, +two: Bool, +a: XAt, +ok: Bool, +gs: KV.XGroups) -> Maybe<&1, KV.XGroups & String>:
  match k r:
    case 0n XGOk{+g, +gok, t}:
      xgs.done(Bool.and(Bool.and(ok, gok), xgs.new(gs, g)), KV.xgs.put(g, gs), t)
    case 1n+j XGOk{+g, +gok, t}:
      xgs.go(j, xg.rd(t, two, a), two, a, Bool.and(Bool.and(ok, gok), xgs.new(gs, g)), KV.xgs.put(g, gs))
    case _ _:
      None{}

def xgs.rd.n(n: Nat, t: String, +two: Bool, +a: XAt) -> Maybe<&1, KV.XGroups & String>:
  match n:
    case 0n:
      Some{(KV.XGTip{}, t)}
    case 1n+j:
      xgs.go(j, xg.rd(t, two, a), two, a, True{}, KV.XGTip{})

def xgs.rd(m: Maybe<&1, Nat & String>, +two: Bool, +a: XAt) -> Maybe<&1, KV.XGroups & String>:
  match m:
    case Some{p}:
      (n, t) = p
      xgs.rd.n(n, t, two, a)
    case None{}:
      None{}

# A stream's head after its nodes: its count of entries, its last ID,
# its first ID, its greatest deleted ID and its count of entries ever
# added (type 15: none of the last three, which its entries give)
type XHd is Data:
  XHd{len: Nat, last: KV.XId, first: KV.XId, maxdel: KV.XId, added: KV.XN}

def xid.zero() -> KV.XId:
  KV.XId{KV.XS{0n}, KV.XS{0n}}

def xid.max() -> KV.XId:
  KV.XId{xn.max(), xn.max()}

def xhd.added(+n: Nat, +last: KV.XId, +first: KV.XId, +maxdel: KV.XId, m: Maybe<&1, KV.XN & String>) -> Maybe<&1, XHd & String>:
  match m:
    case Some{p}:
      (+a, t) = p
      Some{(XHd{n, last, first, maxdel, a}, t)}
    case None{}:
      None{}

def xhd.maxdel(+n: Nat, +last: KV.XId, +first: KV.XId, m: Maybe<&1, KV.XId & String>) -> Maybe<&1, XHd & String>:
  match m:
    case Some{p}:
      (+d, t) = p
      xhd.added(n, last, first, d, rd.xn(t))
    case None{}:
      None{}

def xhd.first(+n: Nat, +last: KV.XId, m: Maybe<&1, KV.XId & String>) -> Maybe<&1, XHd & String>:
  match m:
    case Some{p}:
      (+f, t) = p
      xhd.maxdel(n, last, f, rd.xid(t))
    case None{}:
      None{}

# of 15: the first ID the first live entry's (max-max for none, as
# streamGetEdgeID gives it), no ID deleted, the entries ever added the
# entries there
def xhd.last(two: Bool, +n: Nat, +first: Maybe<&2, KV.XId>, m: Maybe<&1, KV.XId & String>) -> Maybe<&1, XHd & String>:
  match two m:
    case True{} Some{p}:
      (+last, t) = p
      xhd.first(n, last, rd.xid(t))
    case False{} Some{p}:
      (+last, t) = p
      Some{(XHd{n, last, Maybe.default(&2, KV.XId, first, xid.max()), xid.zero(), KV.xn.of(n)}, t)}
    case _ None{}:
      None{}

def xhd.len(m: Maybe<&1, Nat & String>, +two: Bool, +first: Maybe<&2, KV.XId>) -> Maybe<&1, XHd & String>:
  match m:
    case Some{p}:
      (+n, t) = p
      xhd.last(two, n, first, rd.xid(t))
    case None{}:
      None{}

# the stream, once its groups are read
def xst.make(h: XHd, ns: KV.XNodes, gs: KV.XGroups, t: String) -> Vr:
  match h:
    case XHd{n, last, first, maxdel, added}:
      VrVal{KV.VColl{KV.CStream{KV.XStr{n, last, first, maxdel, added, ns, gs}}}, t}

def xst.groups(m: Maybe<&1, KV.XGroups & String>, h: XHd, ns: KV.XNodes) -> Vr:
  match m:
    case Some{p}:
      (gs, t) = p
      xst.make(h, ns, gs, t)
    case None{}:
      VrBad{}

def xst.head.ok(ok: Bool, +h: XHd, ns: KV.XNodes, +two: Bool, t: String) -> Vr:
  match ok h:
    case True{} XHd{+n, +last, +first, maxdel, added}:
      xst.groups(xgs.rd(rd.num(t), two, XAt{n, last, first}), h, ns)
    case False{} _:
      VrBad{}

def xhd.n(+h: XHd) -> Nat:
  match h:
    case XHd{+n, last, first, maxdel, added}:
      n

def xhd.lastid(+h: XHd) -> KV.XId:
  match h:
    case XHd{n, +last, first, maxdel, added}:
      last

def xst.below(+m: Maybe<&2, KV.XId>, +last: KV.XId) -> Bool:
  match m:
    case Some{+x}:
      Bool.not(Cmp.is_gt(KV.xid.cmp(x, last)))
    case None{}:
      True{}

# the head read: the count of entries that of the live entries, the last
# ID at least the last live entry's
def xst.head(m: Maybe<&1, XHd & String>, ns: KV.XNodes, +tot: Nat, +lastlive: Maybe<&2, KV.XId>, +two: Bool) -> Vr:
  match m:
    case Some{p}:
      (+h, t) = p
      xst.head.ok(Bool.and(Nat.is_eq(xhd.n(h), tot), xst.below(lastlive, xhd.lastid(h))), h, ns, two, t)
    case None{}:
      VrBad{}

def xst.walked(w: XW, ns: KV.XNodes, +two: Bool, t: String) -> Vr:
  match w:
    case XW{live, dead, nel, es, +first, +last, +tot, ok}:
      match ok:
        case True{}:
          xst.head(xhd.len(rd.num(t), two, first), ns, tot, last, two)
        case False{}:
          VrBad{}
    case XWOf{x}:
      xst.walked(x, ns, two, t)

def xst.nodes(r: XSRd, +two: Bool) -> Vr:
  match r:
    case XSOk{ns, w, t}:
      xst.walked(w, ns, two, t)
    case XSBad{}:
      VrBad{}

# a stream of type 19 (two) or 15
def obj.stream(+two: Bool, s: String) -> Vr:
  xst.nodes(xns.rd.of(rd.num(s)), two)

# Reading a value
# ---------------
# rdbLoadObject: a value's type, then the value. A string; a list of
# strings (LIST), a set of them (SET), a hash of their pairs (HASH), each
# its count first; a sorted set of members and scores (ZSET: a score's
# text after its length, or 253, 254, 255 for nan, inf, -inf; ZSET_2: its
# bits, the low byte first); one blob, a string of their encoding:
# HASH_ZIPMAP, LIST_ZIPLIST, SET_INTSET, ZSET_ZIPLIST, HASH_ZIPLIST,
# HASH_LISTPACK, ZSET_LISTPACK; or a quicklist, its count of nodes, then
# each a ziplist (LIST_QUICKLIST) or a container (1, plain: the element
# alone; 2, packed: a listpack) and its blob (LIST_QUICKLIST_2), an empty
# node skipped; or a stream (STREAM_LISTPACKS, STREAM_LISTPACKS_2:
# Streams, above). A module's value (6, 7) is no value BendKV holds, and
# any other type no value at all. Each read gives
# the bytes after what it read, so that an RDB file reads its keys one
# after another (The file, below).

# A value read, and the bytes after it: a value; a collection with no
# element, which an RDB file may hold (Redis's rdbLoadObject skips it as
# an empty key: RESTORE takes none); or bytes that are no value
type Vr is Data:
  VrVal{v: KV.Val, t: String}
  VrEmpty{t: String}
  VrBad{}

def vr.of(m: Maybe<&2, KV.Val>, t: String) -> Vr:
  match m:
    case Some{v}:
      VrVal{v, t}
    case None{}:
      VrBad{}

# the value read, without the bytes after it
def vr.val(r: Vr) -> Maybe<&2, KV.Val>:
  match r:
    case VrVal{v, t}:
      Some{v}
    case _:
      None{}

# the strings after r, the one just read, k more after it, and the bytes
# after them
def rd.strs(k: Nat, r: Maybe<&1, String & String>, acc: List<&2, String>) -> Maybe<&1, List<&2, String> & String>:
  match k r:
    case 0n Some{p}:
      (x, t) = p
      Some{(List.reverse(&2, String, x <> acc), t)}
    case 1n+j Some{p}:
      (x, t) = p
      rd.strs(j, rd.str(t), x <> acc)
    case _ None{}:
      None{}

# n strings
def rd.strs.n(n: Nat, t: String) -> Maybe<&1, List<&2, String> & String>:
  match n:
    case 0n:
      Some{(Nil{}, t)}
    case 1n+k:
      rd.strs(k, rd.str(t), Nil{})

def z.hi(m: String, +lo: Nat, r: Maybe<&1, Nat & String>) -> Maybe<&1, KV.ZEl & String>:
  match r:
    case Some{p}:
      (+hi, t) = p
      Some{(KV.ZEl{m, F.F64{hi, lo}}, t)}
    case None{}:
      None{}

def z.lo(m: String, r: Maybe<&1, Nat & String>) -> Maybe<&1, KV.ZEl & String>:
  match r:
    case Some{p}:
      (+lo, t) = p
      z.hi(m, lo, rd.le(4n, t, 1n, 0n))
    case None{}:
      None{}

def z.txt.got(m: String, d: Maybe<&2, F.F64>, t: String) -> Maybe<&1, KV.ZEl & String>:
  match d:
    case Some{x}:
      Some{(KV.ZEl{m, x}, t)}
    case None{}:
      None{}

def z.txt.of(m: String, r: Maybe<&1, String & String>) -> Maybe<&1, KV.ZEl & String>:
  match r:
    case Some{p}:
      (+s, t) = p
      z.txt.got(m, z3.score(s), t)
    case None{}:
      None{}

def z.txt.l(m: String, +l: Nat, t: String) -> Maybe<&1, KV.ZEl & String>:
  match l:
    case 255n:
      Some{(KV.ZEl{m, F.F64{4293918720n, 0n}}, t)}
    case 254n:
      Some{(KV.ZEl{m, F.F64{2146435072n, 0n}}, t)}
    case 253n:
      Some{(KV.ZEl{m, F.F64{2146959360n, 0n}}, t)}
    case _:
      z.txt.of(m, rd.take(t, l))

# a score's text (rdbLoadDoubleValue): 253, 254, 255 are nan, inf, -inf
def z.txt(m: String, r: Maybe<&1, Nat & String>) -> Maybe<&1, KV.ZEl & String>:
  match r:
    case Some{p}:
      (+l, t) = p
      z.txt.l(m, l, t)
    case None{}:
      None{}

def z.el.of(two: Bool, r: Maybe<&1, String & String>) -> Maybe<&1, KV.ZEl & String>:
  match two r:
    case True{} Some{p}:
      (m, t) = p
      z.lo(m, rd.le(4n, t, 1n, 0n))
    case False{} Some{p}:
      (m, t) = p
      z.txt(m, rd.u8(t))
    case _ None{}:
      None{}

# a member and its score (two: as ZSET_2 writes it, its bits)
def z.el(+two: Bool, t: String) -> Maybe<&1, KV.ZEl & String>:
  z.el.of(two, rd.str(t))

def z.els(k: Nat, +two: Bool, r: Maybe<&1, KV.ZEl & String>, acc: List<&2, KV.ZEl>) -> Maybe<&1, List<&2, KV.ZEl> & String>:
  match k r:
    case 0n Some{p}:
      (e, t) = p
      Some{(List.reverse(&2, KV.ZEl, e <> acc), t)}
    case 1n+j Some{p}:
      (e, t) = p
      z.els(j, two, z.el(two, t), e <> acc)
    case _ None{}:
      None{}

def z.els.n(n: Nat, +two: Bool, t: String) -> Maybe<&1, List<&2, KV.ZEl> & String>:
  match n:
    case 0n:
      Some{(Nil{}, t)}
    case 1n+k:
      z.els(k, two, z.el(two, t), Nil{})

# a quicklist's node: its elements, and what follows it
def ql.got(m: Maybe<&2, List<&2, String>>, t: String) -> Maybe<&1, List<&2, String> & String>:
  match m:
    case Some{xs}:
      Some{(xs, t)}
    case None{}:
      None{}

def ql.data(two: Bool, c: Nat, +b: String) -> Maybe<&2, List<&2, String>>:
  match two c:
    case True{} 1n:
      Some{[b]}
    case True{} 2n:
      lp.read(b)
    case True{} _:
      None{}
    case False{} _:
      zl.read(b)

def ql.blob(+two: Bool, +c: Nat, m: Maybe<&1, String & String>) -> Maybe<&1, List<&2, String> & String>:
  match m:
    case Some{p}:
      (+b, t) = p
      Bool.pick(Maybe<&1, List<&2, String> & String>, Nat.is_eq(String.length(b), 0n), None{}, ql.got(ql.data(two, c, b), t))
    case None{}:
      None{}

def ql.cont(m: Maybe<&1, Nat & String>) -> Maybe<&1, List<&2, String> & String>:
  match m:
    case Some{p}:
      (+c, t) = p
      ql.blob(True{}, c, rd.str(t))
    case None{}:
      None{}

def ql.node(two: Bool, t: String) -> Maybe<&1, List<&2, String> & String>:
  match two:
    case True{}:
      ql.cont(rd.num(t))
    case False{}:
      ql.blob(False{}, 2n, rd.str(t))

# the nodes after r, the one just read, k more after it: their elements
# before acc, the newest first; and the bytes after them
def ql.nodes(k: Nat, +two: Bool, r: Maybe<&1, List<&2, String> & String>, acc: List<&2, String>) -> Maybe<&1, List<&2, String> & String>:
  match k r:
    case 0n Some{p}:
      (xs, t) = p
      Some{(List.reverse(&2, String, List.reverse.go(&2, String, xs, acc)), t)}
    case 1n+j Some{p}:
      (xs, t) = p
      ql.nodes(j, two, ql.node(two, t), List.reverse.go(&2, String, xs, acc))
    case _ None{}:
      None{}

def ql.nodes.n(n: Nat, +two: Bool, t: String) -> Maybe<&1, List<&2, String> & String>:
  match n:
    case 0n:
      Some{(Nil{}, t)}
    case 1n+k:
      ql.nodes(k, two, ql.node(two, t), Nil{})

def obj.str(m: Maybe<&1, String & String>) -> Vr:
  match m:
    case Some{p}:
      (x, t) = p
      VrVal{KV.VStr{x}, t}
    case None{}:
      VrBad{}

# a list of the elements xs, the bytes t after it
def obj.list.of(xs: List<&2, String>, t: String) -> Vr:
  match xs:
    case Nil{}:
      VrEmpty{t}
    case Con{x, more}:
      vr.of(val.list(x <> more), t)

def obj.list(m: Maybe<&1, List<&2, String> & String>) -> Vr:
  match m:
    case Some{p}:
      (xs, t) = p
      obj.list.of(xs, t)
    case None{}:
      VrBad{}

def obj.list.b(m: Maybe<&2, List<&2, String>>, t: String) -> Vr:
  match m:
    case Some{xs}:
      obj.list.of(xs, t)
    case None{}:
      VrBad{}

def obj.set.of(+sorted: Bool, xs: List<&2, String>, +b: String, t: String) -> Vr:
  match xs:
    case Nil{}:
      VrEmpty{t}
    case Con{x, more}:
      vr.of(val.set(sorted, x <> more, b), t)

def obj.set(m: Maybe<&1, List<&2, String> & String>) -> Vr:
  match m:
    case Some{p}:
      (xs, t) = p
      obj.set.of(False{}, xs, "", t)
    case None{}:
      VrBad{}

# the intset b, its members xs (is.read)
def obj.set.b(m: Maybe<&2, List<&2, String>>, +b: String, t: String) -> Vr:
  match m:
    case Some{xs}:
      obj.set.of(True{}, xs, b, t)
    case None{}:
      VrBad{}

# a hash of pairs ps (lp: as a listpack, ziplist or zipmap kept them,
# whose fields and values are not checked: zm: as a zipmap's, which are)
def obj.hps.go(+lp: Bool, +qs: List<&2, KV.HPair>, t: String) -> Vr:
  +n = List.length(&2, KV.HPair, qs)
  vr.of(val.hash(Bool.and(Nat.is_le(n, 512n), Bool.or(lp, Bool.not(hps.gt(qs, 64n)))), n, qs), t)

def obj.hps.of(+lp: Bool, ps: List<&2, KV.HPair>, t: String) -> Vr:
  match ps:
    case Nil{}:
      VrEmpty{t}
    case Con{x, more}:
      obj.hps.go(lp, x <> more, t)

def obj.hps(+lp: Bool, m: Maybe<&2, List<&2, KV.HPair>>, t: String) -> Vr:
  match m:
    case Some{ps}:
      obj.hps.of(lp, ps, t)
    case None{}:
      VrBad{}

def obj.hlp(m: Maybe<&2, List<&2, String>>, t: String) -> Vr:
  match m:
    case Some{xs}:
      obj.hps(True{}, pairs.of(xs, Nil{}), t)
    case None{}:
      VrBad{}

def obj.hash(m: Maybe<&1, List<&2, String> & String>) -> Vr:
  match m:
    case Some{p}:
      (xs, t) = p
      obj.hps(False{}, pairs.of(xs, Nil{}), t)
    case None{}:
      VrBad{}

def obj.zels.go(+lp: Bool, +fs: List<&2, KV.ZEl>, t: String) -> Vr:
  vr.of(val.zset(lp, Bool.or(lp, Bool.not(zel.gt(fs, 64n))), fs), t)

def obj.zels.of(+lp: Bool, es: List<&2, KV.ZEl>, t: String) -> Vr:
  match es:
    case Nil{}:
      VrEmpty{t}
    case Con{e, more}:
      obj.zels.go(lp, e <> more, t)

def obj.zels(m: Maybe<&1, List<&2, KV.ZEl> & String>) -> Vr:
  match m:
    case Some{p}:
      (es, t) = p
      obj.zels.of(False{}, es, t)
    case None{}:
      VrBad{}

def obj.zels.b(m: Maybe<&2, List<&2, KV.ZEl>>, t: String) -> Vr:
  match m:
    case Some{es}:
      obj.zels.of(True{}, es, t)
    case None{}:
      VrBad{}

def obj.zlp(m: Maybe<&2, List<&2, String>>, t: String) -> Vr:
  match m:
    case Some{xs}:
      obj.zels.b(zels.of(xs, Nil{}), t)
    case None{}:
      VrBad{}

def obj.blob.of(k: Nat, +b: String, t: String) -> Vr:
  match k:
    case 9n:
      obj.hps(False{}, zm.read(b), t)
    case 10n:
      obj.list.b(zl.read(b), t)
    case 11n:
      obj.set.b(is.read(b), b, t)
    case 12n:
      obj.zlp(zl.read(b), t)
    case 13n:
      obj.hlp(zl.read(b), t)
    case 16n:
      obj.hlp(lp.read(b), t)
    case 17n:
      obj.zlp(lp.read(b), t)
    case _:
      VrBad{}

def obj.blob(k: Nat, m: Maybe<&1, String & String>) -> Vr:
  match m:
    case Some{p}:
      (b, t) = p
      obj.blob.of(k, b, t)
    case None{}:
      VrBad{}

# the value of type k, of n elements, in t (a hash's 2n strings: no more
# than 2^46 pairs are asked for, so that a count up to 2^48 makes no
# product past 2^48; a count past what t holds fails at t's end either
# way, as each string takes a byte at least; not t's length, which is a
# walk of its chunks, and t is the rest of a whole file at the start)
def obj.n.at(k: Nat, +n: Nat, +t: String) -> Vr:
  match k:
    case 1n:
      obj.list(rd.strs.n(n, t))
    case 2n:
      obj.set(rd.strs.n(n, t))
    case 3n:
      obj.zels(z.els.n(n, False{}, t))
    case 4n:
      obj.hash(rd.strs.n(Nat.mul(2n, Nat.min(n, Nat.mul(16384n, two32()))), t))
    case 5n:
      obj.zels(z.els.n(n, True{}, t))
    case 14n:
      obj.list(ql.nodes.n(n, False{}, t))
    case _:
      obj.list(ql.nodes.n(n, True{}, t))

def obj.n(k: Nat, m: Maybe<&1, Nat & String>) -> Vr:
  match m:
    case Some{p}:
      (+n, t) = p
      obj.n.at(k, n, t)
    case None{}:
      VrBad{}

# the value of type k in s, and the bytes after it
def obj.rest(+k: Nat, s: String) -> Vr:
  match k:
    case 0n:
      obj.str(rd.str(s))
    case 1n:
      obj.n(1n, rd.num(s))
    case 2n:
      obj.n(2n, rd.num(s))
    case 3n:
      obj.n(3n, rd.num(s))
    case 4n:
      obj.n(4n, rd.num(s))
    case 5n:
      obj.n(5n, rd.num(s))
    case 14n:
      obj.n(14n, rd.num(s))
    case 18n:
      obj.n(18n, rd.num(s))
    case 15n:
      obj.stream(False{}, s)
    case 19n:
      obj.stream(True{}, s)
    case _:
      Bool.pick(Vr, Bool.or(Bool.and(Nat.is_le(9n, k), Nat.is_le(k, 13n)), Bool.or(Nat.is_eq(k, 16n), Nat.is_eq(k, 17n))), obj.blob(k, rd.str(s)), VrBad{})

# the value of type k in s (RESTORE: an empty collection is no value)
def obj(+k: Nat, s: String) -> Maybe<&2, KV.Val>:
  vr.val(obj.rest(k, s))

# Writing a value
# ---------------
# rdbSaveObject, with rdbcompression no: a string; a small hash as one
# listpack (HASH_LISTPACK) and a large one as its count and its fields
# and values (HASH, in the order of its trie, where Redis's are in the
# order of its table); a list as a quicklist (LIST_QUICKLIST_2) of the
# nodes RPUSH makes of its elements (at list-max-listpack-size -2: a node
# takes an element while its listpack's bytes, the element's and 8 stay
# within 8192), each packed (2) as a listpack; an intset (SET_INTSET) of
# the narrowest width that holds its members, any other set as its count
# and members (SET: Redis 7.0 has no listpack of a set, and cannot read
# Redis 7.2's, SET_LISTPACK); a small sorted set as one listpack
# (ZSET_LISTPACK) of its members and scores (a score as a listpack keeps
# it: F.f64.show_lp), a large one as its count, then its members and
# their scores' bits from the greatest down (ZSET_2). The value's type
# (rdbSaveObjectType) comes before it: in a payload right before it
# (put.val), in a file before the key (The file, below).

def put.blob(+b: String, rest: String) -> String:
  len.put(String.length(b), b ++ rest)

def put.strs(xs: List<&2, String>, rest: String) -> String:
  match xs:
    case Nil{}:
      rest
    case Con{+x, more}:
      str.put(x, put.strs(more, rest))

def hps.words(ps: List<&2, KV.HPair>) -> List<&2, String>:
  match ps:
    case Nil{}:
      Nil{}
    case Con{KV.HP{f, v}, rest}:
      f <> (v <> hps.words(rest))

def put.hash(h: KV.Hash, rest: String) -> String:
  match h:
    case KV.HSmall{+n, +b}:
      put.blob(lp.blob(hps.words(KV.hb.pairs(n, b, 0n)), Nat.mul(2n, n)), rest)
    case KV.HLong{+n, +ps}:
      put.blob(lp.blob(hps.words(KV.hl.pairs(ps)), Nat.mul(2n, n)), rest)
    case KV.HBig{+n, +t}:
      len.put(n, put.strs(hps.words(KV.hash.kv(t, KV.keys(String, t, 0n))), rest))

# Lists as quicklist nodes
type QlS is Data:
  QlS{cur: List<&2, String>, cn: Nat, cb: Nat, acc: List<&2, List<&2, String>>}

def ql.step(fits: Bool, +x: String, +e: Nat, st: QlS) -> QlS:
  match fits st:
    case True{} QlS{cur, +cn, +cb, acc}:
      QlS{x <> cur, Nat.add(cn, 1n), Nat.add(cb, e), acc}
    case False{} QlS{cur, cn, cb, acc}:
      QlS{[x], 1n, Nat.add(7n, e), List.reverse(&2, String, cur) <> acc}

def ql.at(+x: String, st: QlS) -> QlS:
  match st:
    case QlS{cur, +cn, +cb, acc}:
      ql.step(Bool.or(Nat.is_eq(cn, 0n), Nat.is_le(Nat.add(Nat.add(cb, String.length(x)), 8n), 8192n)), x, lp.esize(x), QlS{cur, cn, cb, acc})

def ql.done(st: QlS) -> List<&2, List<&2, String>>:
  match st:
    case QlS{cur, cn, cb, acc}:
      List.reverse(&2, List<&2, String>, List.reverse(&2, String, cur) <> acc)

# the nodes, in order, each its elements in order
def ql.part(xs: List<&2, String>, st: QlS) -> List<&2, List<&2, String>>:
  match xs:
    case Nil{}:
      ql.done(st)
    case Con{+x, rest}:
      ql.part(rest, ql.at(x, st))

def put.nodes(ns: List<&2, List<&2, String>>, rest: String) -> String:
  match ns:
    case Nil{}:
      rest
    case Con{+xs, more}:
      b1(2) ++ put.blob(lp.blob(xs, List.length(&2, String, xs)), put.nodes(more, rest))

def put.list(+d: KV.Deq, rest: String) -> String:
  +ns = ql.part(KV.deq.all(d), QlS{Nil{}, 0n, 7n, Nil{}})
  len.put(List.length(&2, List<&2, String>, ns), put.nodes(ns, rest))

# Sets: an intset as Redis writes one, its header (its members' width
# and their count, 4 bytes each, the low first) before its string
# (map.bend: the same bytes)
def put.mems(m: KV.Mems, rest: String) -> String:
  match m:
    case KV.MInts{+n, +b}:
      put.blob(le(4n, KV.ints.w(b, n), le(4n, n, b)), rest)
    case KV.MBig{+n, +t}:
      len.put(n, put.strs(KV.keys(Unit, t, 0n), rest))
    case KV.MSmall{+n, +b}:
      len.put(n, put.strs(KV.ms.all(n, b), rest))
    case KV.MLong{+n, +ps}:
      len.put(n, put.strs(KV.ml.all(ps), rest))

# Sorted sets
def zel.words(es: List<&2, KV.ZEl>) -> List<&2, String>:
  match es:
    case Nil{}:
      Nil{}
    case Con{KV.ZEl{m, +d}, rest}:
      m <> (F.f64.show_lp(d) <> zel.words(rest))

def put.z2(es: List<&2, KV.ZEl>, rest: String) -> String:
  match es:
    case Nil{}:
      rest
    case Con{KV.ZEl{+m, F.F64{+hi, +lo}}, more}:
      str.put(m, le(4n, lo, le(4n, hi, put.z2(more, rest))))

def put.zset(z: KV.Zset, rest: String) -> String:
  match z:
    case KV.ZSmall{+n, +b}:
      put.blob(lp.blob(zel.words(KV.zb.all(n, b)), Nat.mul(2n, n)), rest)
    case KV.ZWide{+tr}:
      put.blob(lp.blob(zel.words(KV.zt.all(tr)), Nat.mul(2n, KV.zt.size(tr))), rest)
    case KV.ZBig{+tr, t}:
      len.put(KV.zt.size(tr), put.z2(List.reverse(&2, KV.ZEl, KV.zt.all(tr)), rest))

# Streams: a stream as rdbSaveObject writes one (19), its nodes from
# their bytes

def be.q(q: Q, rest: String) -> String:
  match q:
    case Q{+hi, +lo}:
      be(4n, hi, be(4n, lo, rest))

# a's 64 bits, the high byte first
def be.xn(+a: KV.XN, rest: String) -> String:
  be.q(xn.q(a), rest)

# a length of 64 bits (rdbSaveLen)
def len.xn(+a: KV.XN, rest: String) -> String:
  match a:
    case KV.XS{+n}:
      len.put(n, rest)
    case KV.XL{+h, +l}:
      b1(129) ++ be.xn(KV.XL{h, l}, rest)

# an ID as two lengths
def put.xid(+id: KV.XId, rest: String) -> String:
  match id:
    case KV.XId{+ms, +sq}:
      len.xn(ms, len.xn(sq, rest))

# an ID's 16 bytes (a radix tree's key)
def put.id16(+id: KV.XId, rest: String) -> String:
  match id:
    case KV.XId{+ms, +sq}:
      be.xn(ms, be.xn(sq, rest))

# the entries es (the newest first) in their order, before acc
def put.es(es: List<&2, String>, acc: String) -> String:
  match es:
    case Nil{}:
      acc
    case Con{e, more}:
      put.es(more, e ++ acc)

# a node's listpack: its size in bytes, its count of elements (65535
# past 65534), its master entry, its entries and 0xFF
def put.lp(+x: KV.XNode) -> String:
  match x:
    case KV.XNd{mid, +mfs, +live, +dead, +bytes, +nel, +es}:
      le(4n, bytes, le(2n, Nat.min(nel, 65535n), xnd.master(live, dead, List.length(&2, String, mfs), mfs, put.es(es, b1(255)))))
    case KV.XNdOf{+y}:
      put.lp(y)

def put.xnodes(ns: List<&2, KV.XNode>, rest: String) -> String:
  match ns:
    case Nil{}:
      rest
    case Con{+x, more}:
      str.put(put.id16(KV.xnode.mid(x), ""), str.put(put.lp(x), put.xnodes(more, rest)))

# a count of entries read (-1 as 2^64 - 1)
def put.xrd(+r: KV.XRd, rest: String) -> String:
  match r:
    case KV.XRdNone{}:
      len.xn(xn.max(), rest)
    case KV.XRdN{+n}:
      len.xn(n, rest)

def put.xnack(+x: KV.XNack, rest: String) -> String:
  match x:
    case KV.XNk{+id, o, +tm, +c}:
      put.id16(id, le(8n, tm, len.xn(c, rest)))
    case KV.XNkOf{+y}:
      put.xnack(y, rest)

def put.xpel(xs: List<&2, KV.XNack>, rest: String) -> String:
  match xs:
    case Nil{}:
      rest
    case Con{+x, more}:
      put.xnack(x, put.xpel(more, rest))

def put.ids(xs: List<&2, KV.XId>, rest: String) -> String:
  match xs:
    case Nil{}:
      rest
    case Con{+x, more}:
      put.id16(x, put.ids(more, rest))

def put.xcons(cs: List<&2, KV.XCon>, rest: String) -> String:
  match cs:
    case Nil{}:
      rest
    case Con{KV.XCon{+name, +seen, +ids}, more}:
      str.put(name, le(8n, seen, len.put(KV.xis.size(ids), put.ids(KV.xis.list(ids, Nil{}), put.xcons(more, rest)))))

def put.xgroup(+g: KV.XGroup, rest: String) -> String:
  match g:
    case KV.XGrp{+name, +last, +read, +pel, +cons}:
      str.put(name, put.xid(last, put.xrd(read, len.put(KV.xpl.size(pel), put.xpel(KV.xpl.list(pel, Nil{}), len.put(KV.xcs.size(cons), put.xcons(KV.xcs.list(cons, Nil{}), rest)))))))
    case KV.XGrpOf{+y}:
      put.xgroup(y, rest)

def put.xgroups(gs: List<&2, KV.XGroup>, rest: String) -> String:
  match gs:
    case Nil{}:
      rest
    case Con{+g, more}:
      put.xgroup(g, put.xgroups(more, rest))

def put.stream(+x: KV.XStream, rest: String) -> String:
  match x:
    case KV.XStr{+n, +last, +first, +maxdel, +added, +nodes, +groups}:
      len.put(KV.xns.size(nodes), put.xnodes(KV.xns.list(nodes, Nil{}), len.put(n, put.xid(last, put.xid(first, put.xid(maxdel, len.xn(added, len.put(KV.xgs.size(groups), put.xgroups(KV.xgs.list(groups, Nil{}), rest)))))))))
    case KV.XStrOf{+y}:
      put.stream(y, rest)

# the value as put.val writes it, without its type
def put.body(v: KV.Val, rest: String) -> String:
  match v:
    case KV.VStr{+s}:
      str.put(s, rest)
    case KV.VColl{KV.CHash{h}}:
      put.hash(h, rest)
    case KV.VColl{KV.CList{d}}:
      put.list(d, rest)
    case KV.VColl{KV.CMems{m}}:
      put.mems(m, rest)
    case KV.VColl{KV.CZset{z}}:
      put.zset(z, rest)
    case KV.VColl{KV.CStream{x}}:
      put.stream(x, rest)

# its type: a string (0), a hash in a listpack (16) or in a table (4), a
# list as a quicklist of listpacks (18), an intset (11), a set in a table
# (2), a sorted set in a listpack (17) or in a skiplist (5), a stream
# (19)
def put.hash.kind(+h: KV.Hash) -> U32:
  match h:
    case KV.HSmall{n, b}:
      16
    case KV.HBig{n, t}:
      4
    case KV.HLong{n, ps}:
      16

def put.mems.kind(+m: KV.Mems) -> U32:
  match m:
    case KV.MInts{n, xs}:
      11
    case KV.MBig{n, t}:
      2
    case KV.MSmall{n, b}:
      2
    case KV.MLong{n, ps}:
      2

def put.zset.kind(+z: KV.Zset) -> U32:
  match z:
    case KV.ZSmall{n, b}:
      17
    case KV.ZWide{tr}:
      17
    case KV.ZBig{tr, t}:
      5

def put.kind(+v: KV.Val) -> U32:
  match v:
    case KV.VStr{s}:
      0
    case KV.VColl{KV.CHash{+h}}:
      put.hash.kind(h)
    case KV.VColl{KV.CList{d}}:
      18
    case KV.VColl{KV.CMems{+m}}:
      put.mems.kind(m)
    case KV.VColl{KV.CZset{+z}}:
      put.zset.kind(z)
    case KV.VColl{KV.CStream{x}}:
      19

def put.val(+v: KV.Val, rest: String) -> String:
  b1(put.kind(v)) ++ put.body(v, rest)

# Payloads
# --------

# DUMP's payload of v (createDumpPayload): the value, version 10 of the
# format, and the CRC64 of both
def dump(v: KV.Val) -> String:
  +body = put.val(v, b1(10) ++ b1(0))
  body ++ crc.le(crc.k(String.length(body), body, C{0, 0}), "")

def verify.of(ok: Bool, +p: String, +n: Nat) -> Bool:
  match ok:
    case True{}:
      +ver = Nat.add(U32.to_nat(String.code_at(p, Nat.sub(n, 10n))), Nat.mul(256n, U32.to_nat(String.code_at(p, Nat.sub(n, 9n)))))
      Bool.and(Nat.is_le(ver, 10n), String.eq(String.slice(p, Nat.sub(n, 8n), 8n), crc.le(crc.k(Nat.sub(n, 8n), p, C{0, 0}), "")))
    case False{}:
      False{}

# whether RESTORE takes p's version and checksum (verifyDumpPayload): ten
# bytes at least, the version at most 10, the CRC64 of all but the last
# eight bytes those bytes
def verify(+p: String) -> Bool:
  +n = String.length(p)
  verify.of(Nat.is_le(10n, n), p, n)

# the value of a payload (rdbLoadObjectType and rdbLoadObject, on all of
# it: Redis reads from the payload's first byte to as far as the value
# goes, its version and checksum included, and no further)
def load(p: String) -> Maybe<&2, KV.Val>:
  match p:
    case SCon{Chr{+x}, t}:
      obj(U32.to_nat(x), t)
    case SNil{}:
      None{}

# The file
# --------
# An RDB file as Redis 7.0.15's rdbSaveRio writes it with rdbcompression
# no (rdb.c): "REDIS0010"; the AUX fields of rdbSaveInfoAuxFields (250,
# then a name and a value, each a string: redis-ver 7.0.15, redis-bits 64,
# ctime, used-mem and aof-base 0; a master with no replica writes no
# replication fields); for each database that holds keys, SELECTDB (254
# and its number) and RESIZEDB (251, then how many keys it holds and how
# many of them have a time); then each key: its time (252, then its ms
# since 1970 in eight bytes, the low first) when it has one, its value's
# type, the key as a string, and the value as a payload holds it
# (put.body); then EOF (255) and the CRC64 of every byte before the CRC,
# eight bytes, the low first (eight zero bytes with rdbchecksum no). As
# Redis's rdbSaveDb, it writes every key a database holds, one whose time
# has passed but that no command has deleted yet with its time (a load
# drops it). It leaves out LRU's idle time and LFU's counter (IDLE and
# FREQ, which Redis writes under an LRU or LFU maxmemory policy: a file
# loads without them), and LZF (its strings are written as they are, as
# DUMP writes them).

def file.aux(+k: String, +v: String, rest: String) -> String:
  b1(250) ++ str.put(k, str.put(v, rest))

# the file's first bytes, at ctime (s since 1970) with mem bytes in use
def file.head(+ctime: Nat, +mem: Nat) -> String:
  "REDIS0010" ++ file.aux("redis-ver", "7.0.15", file.aux("redis-bits", "64", file.aux("ctime", Nat.show(ctime), file.aux("used-mem", Nat.show(mem), file.aux("aof-base", "0", "")))))

# a database's head: SELECTDB of its number i, RESIZEDB of its n keys, x
# of them with a time
def file.db(+i: Nat, +n: Nat, +x: Nat, rest: String) -> String:
  b1(254) ++ len.put(i, b1(251) ++ len.put(n, len.put(x, rest)))

# a key's time e (ms since 1970), when it has one (0: none)
def file.exp(+e: Nat, rest: String) -> String:
  match e:
    case 0n:
      rest
    case _:
      b1(252) ++ le(8n, e, rest)

def file.key(+k: String, +v: KV.Val, +e: Nat, rest: String) -> String:
  file.exp(e, b1(put.kind(v)) ++ str.put(k, put.body(v, rest)))

def file.item(+k: String, m: Maybe<&2, KV.Item<KV.Val>>, rest: String) -> String:
  match m:
    case Some{KV.Item{+v, +e}}:
      file.key(k, v, e, rest)
    case None{}:
      rest

# the keys ks of trie t, before rest
def file.keys(+t: KV.Trie<KV.Val>, ks: List<&2, String>, rest: String) -> String:
  match ks:
    case Nil{}:
      rest
    case Con{+k, more}:
      file.item(k, KV.entry(KV.Val, t, k), file.keys(t, more, rest))

# a database to write, or one loaded: its trie, its keys and those of
# them with a time
type FDb is Data:
  FDb{t: KV.Trie<KV.Val>, n: Nat, x: Nat}

# A file written a slice at a time, as the rewrite of the append-only file
# writes the databases (aof.bend): the databases yet to write (the current
# one first), its number, and the bucket its keys go on from (None: its
# head is not written yet)
type FW is Data:
  FW{dbs: List<&2, FDb>, i: Nat, at: Maybe<&2, Nat>}

# a slice: its bytes, and what is left to write (None: every database is
# written, and the end, file.tail, is next)
type FSl is Data:
  FSl{b: String, more: Maybe<&2, FW>}

def fw.next(rest: List<&2, FDb>, +i: Nat) -> Maybe<&2, FW>:
  match rest:
    case Nil{}:
      None{}
    case Con{d, ds}:
      Some{FW{d <> ds, 1n+i, None{}}}

def fw.head(first: Bool, +i: Nat, +n: Nat, +x: Nat, rest: String) -> String:
  match first:
    case True{}:
      file.db(i, n, x, rest)
    case False{}:
      rest

def fw.scanned(sc: KV.Scan, +t: KV.Trie<KV.Val>, +n: Nat, +x: Nat, rest: List<&2, FDb>, +i: Nat, +first: Bool) -> FSl:
  match sc:
    case KV.Stop{+at, ks}:
      FSl{fw.head(first, i, n, x, file.keys(t, ks, "")), Some{FW{FDb{t, n, x} <> rest, i, Some{at}}}}
    case KV.Scan{w, ks}:
      FSl{fw.head(first, i, n, x, file.keys(t, ks, "")), fw.next(rest, i)}

def fw.at(none: Bool, at: Maybe<&2, Nat>, +t: KV.Trie<KV.Val>, +n: Nat, +x: Nat, rest: List<&2, FDb>, +i: Nat, +want: Nat) -> FSl:
  match none at:
    case True{} _:
      FSl{"", fw.next(rest, i)}
    case False{} None{}:
      fw.scanned(KV.scan(KV.Val, t, 0n, want, 0n), t, n, x, rest, i, True{})
    case False{} Some{+a}:
      fw.scanned(KV.scan(KV.Val, t, a, want, 0n), t, n, x, rest, i, False{})

# the next slice: the keys of the buckets from the current database's
# cursor on, until want entries are read (KV.scan at time 0, which takes
# every entry), its head first; a database with no key is left out
def file.slice(w: FW, +want: Nat) -> FSl:
  match w:
    case FW{Nil{}, i, at}:
      FSl{"", None{}}
    case FW{Con{FDb{+t, +n, +x}, rest}, +i, at}:
      fw.at(Nat.is_eq(n, 0n), at, t, n, x, rest, i, want)

# the file's end: EOF, and the CRC64 c of the bytes before it, with EOF
# (sum: rdbchecksum yes), or eight zero bytes
def file.tail(+sum: Bool, c: C) -> String:
  match sum:
    case True{}:
      b1(255) ++ crc.le(crc.byte(c, 255), "")
    case False{}:
      b1(255) ++ le(8n, 0n, "")

# Reading a file
# --------------
# rdbLoadRio, as a master loads a file at its start: the magic ("REDIS")
# and the version (the next four bytes, as atoi reads them: 1 to 10);
# then the opcodes, until EOF: AUX (two strings: redis-ver, ctime,
# used-mem, aof-preamble, aof-base and the names that begin with '%' are
# logged as Redis logs them, any other is skipped), SELECTDB (a database
# past the server's last stops the load), RESIZEDB (two lengths, a hint),
# EXPIRETIME (seconds, four bytes) and EXPIRETIME_MS (ms, eight bytes) for
# the next key, IDLE and FREQ (skipped: a file sets no key's word of use,
# as RESTORE's options in an append-only file do not), and a key: its
# value's type, the key, then the value (obj.rest). A key whose time has
# passed is dropped and counted (rdb_last_load_keys_expired), a
# collection with no element skipped as an empty key (Redis's emptykey),
# a key twice in a database stops the load (Redis panics). After EOF, from
# version 5 on, the CRC64 of every byte up to it, eight bytes, the low
# first, checked with rdbchecksum yes unless it is 0 (a file written with
# rdbchecksum no). A module's data or value or a library of functions
# stops the load with a line that says why: BendKV has none of them. Every read takes its bytes from the front of what is left, so the
# offset of a failure is the file's length less what is left.

# a line to log, at its level (2 notice, 3 warning)
type FLine is Data:
  FLine{level: U32, msg: String}

# the databases a load fills, the selected one in focus: those before it
# (nearest first) and those after it
type FDs is Data:
  FDs{d: FDb, pre: List<&2, FDb>, post: List<&2, FDb>}

# the time of the next key: none; one before the load's (the key is
# dropped); or the time it keeps (ms since 1970; 0 when it is past 10^14,
# as for every time BendKV keeps)
type FT is Data:
  FTNone{}
  FTPast{}
  FTAt{e: Nat}

# the CRC64 to check once the load is done: none (a version before 5, or
# rdbchecksum no), one written as 0 (rdbchecksum no when it was written),
# or the one stored for the first n bytes
type FSum is Data:
  FSumNone{}
  FSumZero{}
  FSumAt{n: Nat, hi: Nat, lo: Nat}

# what a load came to: the databases, in order, the keys loaded, those
# dropped as their time had passed and those skipped as empty, the lines
# to log (newest first), the CRC64 to check; or the lines that say why it
# stopped (newest first)
type FLd is Data:
  FOk{dbs: List<&2, FDb>, loaded: Nat, expired: Nat, empty: Nat, logs: List<&2, FLine>, sum: FSum}
  FFail{logs: List<&2, FLine>}

# The text of numbers in a file's lines
# a hex digit, and the k lowest hex digits of n, before rest
def hex.dig(+d: Nat) -> String:
  String.slice("0123456789abcdef", d, 1n)

def hex.k(k: Nat, +n: Nat, rest: String) -> String:
  match k:
    case 0n:
      rest
    case 1n+j:
      hex.k(j, Nat.div(n, 16n), hex.dig(Nat.mod(n, 16n)) ++ rest)

# how many hex digits n has (one at least, f more at most)
def hex.cnt(f: Nat, +n: Nat) -> Nat:
  match f:
    case 0n:
      1n
    case 1n+g:
      Bool.pick(Nat, Nat.is_lt(n, 16n), 1n, 1n+hex.cnt(g, Nat.div(n, 16n)))

# a 64-bit number of two halves as %llx writes it
def hex.q(+hi: Nat, +lo: Nat) -> String:
  Bool.pick(String, Nat.is_eq(hi, 0n), hex.k(hex.cnt(7n, lo), lo, ""), hex.k(hex.cnt(7n, hi), hi, hex.k(8n, lo, "")))

# a number as strtol and atoi read one: blanks (isspace), a sign, then
# digits as far as they go; its sign and its magnitude. At most 14 digits
# are read, of the first 64 bytes, so that no number past 2^48 is made
# (each step's product is made whether it is taken or not: go says
# whether the digits still run)
def num.blank(+x: U32) -> Bool:
  Bool.or(U32.is_eq(x, 32), Bool.and(U32.is_le(9, x), U32.is_le(x, 13)))

def num.digits(f: Nat, s: String, +go: Bool, +acc: Nat) -> Nat:
  match f s:
    case 1n+g SCon{Chr{+x}, t}:
      +dig = Bool.and(go, Bool.and(U32.is_le(48, x), U32.is_le(x, 57)))
      num.digits(g, t, dig, Bool.pick(Nat, dig, Nat.add(Nat.mul(acc, 10n), U32.to_nat(U32.and(U32.sub(x, 48), 15))), acc))
    case _ _:
      acc

def num.signed(+neg: Bool, +s: String) -> Bool & Nat:
  (neg, num.digits(14n, s, True{}, 0n))

def num.sign(+s: String) -> Bool & Nat:
  +x = String.code_at(s, 0n)
  Bool.pick(Bool & Nat, U32.is_eq(x, 45), num.signed(True{}, String.drop(s, 1n)), Bool.pick(Bool & Nat, U32.is_eq(x, 43), num.signed(False{}, String.drop(s, 1n)), num.signed(False{}, s)))

def num.skip(f: Nat, +s: String) -> String:
  match f:
    case 0n:
      s
    case 1n+g:
      Bool.pick(String, Bool.and(Nat.is_lt(0n, String.length(s)), num.blank(String.code_at(s, 0n))), num.skip(g, String.drop(s, 1n)), s)

def num.of(+s: String) -> Bool & Nat:
  num.sign(num.skip(64n, String.take(s, 64n)))

# a signed number's text, as %d writes it
def num.show(p: Bool & Nat) -> String:
  (+neg, +m) = p
  Bool.pick(String, Bool.and(neg, Nat.is_lt(0n, m)), "-", "") ++ Nat.show(m)

# what %.2f writes of m / 2^20 (m bytes in MB), rounded to the nearest,
# half to even, as glibc's printf rounds the exact value
def mb.round(+ip: Nat, +d: Nat, +r: Nat) -> String:
  +up = Bool.or(Nat.is_lt(524288n, r), Bool.and(Nat.is_eq(r, 524288n), Nat.is_eq(Nat.mod(d, 2n), 1n)))
  +d2 = Bool.pick(Nat, up, 1n+d, d)
  +ip2 = Bool.pick(Nat, Nat.is_eq(d2, 100n), 1n+ip, ip)
  +dd = Nat.mod(d2, 100n)
  Nat.show(ip2) ++ "." ++ Bool.pick(String, Nat.is_lt(dd, 10n), "0", "") ++ Nat.show(dd)

def mb.text(p: Bool & Nat) -> String:
  (+neg, +m) = p
  +fr = Nat.mul(Nat.mod(m, 1048576n), 100n)
  Bool.pick(String, Bool.and(neg, Nat.is_lt(0n, m)), "-", "") ++ mb.round(Nat.div(m, 1048576n), Nat.div(fr, 1048576n), Nat.mod(fr, 1048576n))


# The lines a load logs
def fl.line(+level: U32, +msg: String, ls: List<&2, FLine>) -> List<&2, FLine>:
  FLine{level, msg} <> ls

# the file's age in seconds, its ctime as strtol reads it, at the second
# secs: none below 0
def fl.age(p: Bool & Nat, +secs: Nat) -> String:
  (+neg, +m) = p
  Nat.show(Bool.pick(Nat, neg, Nat.add(secs, m), Nat.sub(secs, m)))

def fl.nonzero(p: Bool & Nat) -> Bool:
  (neg, +m) = p
  Nat.is_lt(0n, m)

# what an AUX field logs (rdbLoadRioWithLoadingCtx), at the load's time
# now (ms since 1970)
def fl.aux.log(+k: String, +v: String, +now: Nat, +ls: List<&2, FLine>) -> List<&2, FLine>:
  +l = String.to_lower(k)
  Bool.pick(List<&2, FLine>, U32.is_eq(String.code_at(k, 0n), 37), fl.line(2, "RDB '" ++ k ++ "': " ++ v, ls),
    Bool.pick(List<&2, FLine>, String.eq(l, "redis-ver"), fl.line(2, "Loading RDB produced by version " ++ v, ls),
      Bool.pick(List<&2, FLine>, String.eq(l, "ctime"), fl.line(2, "RDB age " ++ fl.age(num.of(v), Nat.div(now, 1000n)) ++ " seconds", ls),
        Bool.pick(List<&2, FLine>, String.eq(l, "used-mem"), fl.line(2, "RDB memory usage when created " ++ mb.text(num.of(v)) ++ " Mb", ls),
          Bool.pick(List<&2, FLine>, Bool.and(String.eq(l, "aof-preamble"), fl.nonzero(num.of(v))), fl.line(2, "RDB has an AOF tail", ls),
            Bool.pick(List<&2, FLine>, Bool.and(String.eq(l, "aof-base"), fl.nonzero(num.of(v))), fl.line(2, "RDB is base AOF", ls), ls))))))

# a read that came short (rdbLoadRio's eoferr), at offset at
def fl.short(+at: Nat, ls: List<&2, FLine>) -> FLd:
  FFail{fl.line(3, "Internal error in RDB reading offset " ++ Nat.show(at) ++ " -> Unexpected EOF reading RDB file", fl.line(3, "Short read or OOM loading DB. Unrecoverable error, aborting now.", ls))}

def fl.stop(+msg: String, ls: List<&2, FLine>) -> FLd:
  FFail{fl.line(3, msg, ls)}

def fl.nofn() -> String:
  "BendKV runs no functions: the RDB file holds a library of functions, which it cannot load"

# The databases a load fills
def fdb.empty() -> FDb:
  FDb{KV.empty(KV.Val), 0n, 0n}

def fds.empties(n: Nat) -> List<&2, FDb>:
  match n:
    case 0n:
      Nil{}
    case 1n+m:
      fdb.empty() <> fds.empties(m)

def fds.list(ds: FDs) -> List<&2, FDb>:
  match ds:
    case FDs{d, pre, post}:
      List.reverse.go(&2, FDb, pre, d <> post)

def fds.count(+ds: FDs) -> Nat:
  match ds:
    case FDs{d, +pre, +post}:
      1n+Nat.add(List.length(&2, FDb, pre), List.length(&2, FDb, post))

def fds.index(+ds: FDs) -> Nat:
  match ds:
    case FDs{d, +pre, post}:
      List.length(&2, FDb, pre)

# the databases xs with the j-th in focus, those before it being acc's
# (nearest first); none when there are not j + 1
def fds.pick(j: Nat, acc: List<&2, FDb>, xs: List<&2, FDb>) -> Maybe<&2, FDs>:
  match j xs:
    case 0n Con{x, rest}:
      Some{FDs{x, acc, rest}}
    case 1n+i Con{x, rest}:
      fds.pick(i, x <> acc, rest)
    case _ Nil{}:
      None{}

# k set to v with the time e (0: none) in the database in focus, counted,
# and whether the database held k already (the code of k's entry is asked
# first, while the trie is lent, as redis.bend's db.setx asks it)
def fdb.put(d: FDb, +k: String, v: KV.Val, +e: Nat) -> Bool & FDb:
  match d:
    case FDb{t, +n, +x}:
      +u = t
      +h = KV.hash(k)
      +c = KV.code.at(KV.Val, u, k, h)
      (Bool.not(Nat.is_eq(c, 0n)), FDb{KV.setx.at(KV.Val, u, k, v, e, h), 1n+n, Bool.pick(Nat, Nat.is_eq(e, 0n), x, 1n+x)})

def fds.put.of(p: Bool & FDb, pre: List<&2, FDb>, post: List<&2, FDb>) -> Bool & FDs:
  (dup, d) = p
  (dup, FDs{d, pre, post})

def fds.put(ds: FDs, +k: String, v: KV.Val, +e: Nat) -> Bool & FDs:
  match ds:
    case FDs{d, pre, post}:
      fds.put.of(fdb.put(d, k, v, e), pre, post)

# The counts of a load (keys loaded, expired, empty), and what it keeps
# (the file's length, its version, the load's time, whether the CRC64 is
# checked)
type FN is Data:
  FN{ld: Nat, ex: Nat, em: Nat}

type FK is Data:
  FK{len: Nat, ver: Nat, now: Nat, sum: Bool}

def fn.loaded(n: FN) -> FN:
  match n:
    case FN{+ld, ex, em}:
      FN{1n+ld, ex, em}

def fn.expired(n: FN) -> FN:
  match n:
    case FN{ld, +ex, em}:
      FN{ld, 1n+ex, em}

def fn.empty(n: FN) -> FN:
  match n:
    case FN{ld, ex, +em}:
      FN{ld, ex, 1n+em}

def fn.em(+n: FN) -> Nat:
  match n:
    case FN{ld, ex, +em}:
      em

def fk.now(+k: FK) -> Nat:
  match k:
    case FK{len, ver, +now, sum}:
      now

# The time of a key: EXPIRETIME_MS's eight bytes (hi and lo, a long long
# in two's complement: -1 is none, as Redis's -1; any other below 0 is
# past; 2^48 and more is none, as a time past the year 5138 is in BendKV),
# EXPIRETIME's four (u, an int of seconds)
def ft.at(+e: Nat, +now: Nat) -> FT:
  Bool.pick(FT, Nat.is_lt(e, now), FTPast{}, FTAt{KV.clamp(e)})

def ft.ms(+hi: Nat, +lo: Nat, +now: Nat) -> FT:
  Bool.pick(FT, Bool.and(Nat.is_eq(hi, 4294967295n), Nat.is_eq(lo, 4294967295n)), FTNone{},
    Bool.pick(FT, Nat.is_le(2147483648n, hi), FTPast{},
      Bool.pick(FT, Nat.is_le(65536n, hi), FTNone{}, ft.at(Nat.add(Nat.mul(Nat.min(hi, 65535n), two32()), lo), now))))

def ft.secs(+u: Nat, +now: Nat) -> FT:
  Bool.pick(FT, Nat.is_le(2147483648n, u), FTPast{}, ft.at(Nat.mul(u, 1000n), now))

# a load under way: the bytes left, what it keeps, the databases, the
# time of the next key, the counts, the lines
type FR is Data:
  FR{left: String, k: FK, dbs: FDs, exp: FT, n: FN, ls: List<&2, FLine>}

# a step of a load: on, or done, or out of bytes: the load as it was
# before the step, to run again once more of the file is there (the
# start reads it in windows: file.next), and fail, what the load comes
# to when the file has no more
type FS is Data:
  FGo{r: FR}
  FEnd{d: FLd}
  FMore{r: FR, fail: FLd}

# The offset of a step's first byte: the file's length less what is left
# of it, worked out only for a line that names it (a load that fails) or
# for the checksum at the end, as the length of a String of many chunks
# is a walk of them (2 KB each: a step that measured what is left made a
# load of a million keys a walk of 10^10 chunks)
type FAt is Data:
  FAt{len: Nat, left: String}

def fat.n(a: FAt) -> Nat:
  match a:
    case FAt{+len, +left}:
      Nat.sub(len, String.length(left))

def fat.left(+a: FAt) -> String:
  match a:
    case FAt{len, +left}:
      left

# a step at at that ran out of bytes: the load as it was before it, and
# fail
def fl.more(+at: FAt, k: FK, dbs: FDs, exp: FT, n: FN, ls: List<&2, FLine>, fail: FLd) -> FS:
  FMore{FR{fat.left(at), k, dbs, exp, n, ls}, fail}

# the same, its read come short (fl.short) at the step's first byte
def fl.short.at(+at: FAt, k: FK, dbs: FDs, exp: FT, n: FN, +ls: List<&2, FLine>) -> FS:
  fl.more(at, k, dbs, exp, n, ls, fl.short(fat.n(at), ls))

# The steps of a load: each reads an opcode and what follows it

# an opcode's bytes skipped (IDLE, FREQ, RESIZEDB's second length)
def fl.skip(m: Maybe<&1, Nat & String>, +at: FAt, k: FK, dbs: FDs, exp: FT, n: FN, ls: List<&2, FLine>) -> FS:
  match m:
    case Some{p}:
      (x, t) = p
      FGo{FR{t, k, dbs, exp, n, ls}}
    case None{}:
      fl.short.at(at, k, dbs, exp, n, ls)

def fl.resize(m: Maybe<&1, Nat & String>, +at: FAt, k: FK, dbs: FDs, exp: FT, n: FN, ls: List<&2, FLine>) -> FS:
  match m:
    case Some{p}:
      (x, t) = p
      fl.skip(rd.num(t), at, k, dbs, exp, n, ls)
    case None{}:
      fl.short.at(at, k, dbs, exp, n, ls)

def fl.aux.v(+name: String, m: Maybe<&1, String & String>, +at: FAt, +k: FK, dbs: FDs, exp: FT, n: FN, ls: List<&2, FLine>) -> FS:
  match m:
    case Some{p}:
      (+v, t) = p
      FGo{FR{t, k, dbs, exp, n, fl.aux.log(name, v, fk.now(k), ls)}}
    case None{}:
      fl.short.at(at, k, dbs, exp, n, ls)

def fl.aux(m: Maybe<&1, String & String>, +at: FAt, k: FK, dbs: FDs, exp: FT, n: FN, ls: List<&2, FLine>) -> FS:
  match m:
    case Some{p}:
      (+name, t) = p
      fl.aux.v(name, rd.str(t), at, k, dbs, exp, n, ls)
    case None{}:
      fl.short.at(at, k, dbs, exp, n, ls)

def fl.ms.hi(+lo: Nat, m: Maybe<&1, Nat & String>, +at: FAt, +k: FK, dbs: FDs, exp: FT, n: FN, ls: List<&2, FLine>) -> FS:
  match m:
    case Some{p}:
      (+hi, t) = p
      FGo{FR{t, k, dbs, ft.ms(hi, lo, fk.now(k)), n, ls}}
    case None{}:
      fl.short.at(at, k, dbs, exp, n, ls)

def fl.ms(m: Maybe<&1, Nat & String>, +at: FAt, k: FK, dbs: FDs, exp: FT, n: FN, ls: List<&2, FLine>) -> FS:
  match m:
    case Some{p}:
      (+lo, t) = p
      fl.ms.hi(lo, rd.le(4n, t, 1n, 0n), at, k, dbs, exp, n, ls)
    case None{}:
      fl.short.at(at, k, dbs, exp, n, ls)

def fl.secs(m: Maybe<&1, Nat & String>, +at: FAt, +k: FK, dbs: FDs, exp: FT, n: FN, ls: List<&2, FLine>) -> FS:
  match m:
    case Some{p}:
      (+u, t) = p
      FGo{FR{t, k, dbs, ft.secs(u, fk.now(k)), n, ls}}
    case None{}:
      fl.short.at(at, k, dbs, exp, n, ls)

# SELECTDB: a database past the server's stops the load, as Redis exits
def fl.focus(m: Maybe<&2, FDs>, +count: Nat, t: String, k: FK, exp: FT, n: FN, ls: List<&2, FLine>) -> FS:
  match m:
    case Some{d}:
      FGo{FR{t, k, d, exp, n, ls}}
    case None{}:
      FEnd{fl.stop("FATAL: Data file was created with a Redis server configured to handle more than " ++ Nat.show(count) ++ " databases. Exiting", ls)}

def fl.select(m: Maybe<&1, Nat & String>, +at: FAt, k: FK, +dbs: FDs, exp: FT, n: FN, ls: List<&2, FLine>) -> FS:
  match m:
    case Some{p}:
      (+j, t) = p
      fl.focus(fds.pick(j, Nil{}, fds.list(dbs)), fds.count(dbs), t, k, exp, n, ls)
    case None{}:
      fl.short.at(at, k, dbs, exp, n, ls)

# A key read with its value: kept, the time it has (exp) given, unless
# that time has passed; a key a database holds already stops the load
def fl.dup(dup: Bool, d: FDs, +key: String, t: String, k: FK, n: FN, ls: List<&2, FLine>) -> FS:
  match dup:
    case False{}:
      FGo{FR{t, k, d, FTNone{}, fn.loaded(n), ls}}
    case True{}:
      +x = d
      FEnd{fl.stop("RDB has duplicated key '" ++ key ++ "' in DB " ++ Nat.show(fds.index(x)), ls)}

def fl.added(p: Bool & FDs, +key: String, t: String, k: FK, n: FN, ls: List<&2, FLine>) -> FS:
  (dup, d) = p
  fl.dup(dup, d, key, t, k, n, ls)

def fl.put(exp: FT, +key: String, v: KV.Val, t: String, k: FK, dbs: FDs, n: FN, ls: List<&2, FLine>) -> FS:
  match exp:
    case FTPast{}:
      FGo{FR{t, k, dbs, FTNone{}, fn.expired(n), ls}}
    case FTNone{}:
      fl.added(fds.put(dbs, key, v, 0n), key, t, k, n, ls)
    case FTAt{+e}:
      fl.added(fds.put(dbs, key, v, e), key, t, k, n, ls)

# an empty key skipped, the first ten logged (rdbLoadObject skipping
# empty key)
def fl.empty.log(+key: String, +em: Nat, +ls: List<&2, FLine>) -> List<&2, FLine>:
  Bool.pick(List<&2, FLine>, Nat.is_lt(em, 10n), fl.line(3, "rdbLoadObject skipping empty key: " ++ key, ls), ls)

def fl.val(r: Vr, +op: Nat, +key: String, +at: FAt, k: FK, dbs: FDs, exp: FT, +n: FN, +ls: List<&2, FLine>) -> FS:
  match r:
    case VrVal{v, t}:
      fl.put(exp, key, v, t, k, dbs, n, ls)
    case VrEmpty{t}:
      FGo{FR{t, k, dbs, FTNone{}, fn.empty(n), fl.empty.log(key, fn.em(n), ls)}}
    case VrBad{}:
      fl.more(at, k, dbs, exp, n, ls, FFail{fl.line(3, "Internal error in RDB reading offset " ++ Nat.show(fat.n(at)) ++ " -> the value of key '" ++ key ++ "' (type " ++ Nat.show(op) ++ ") is cut short, or not one Redis writes", fl.line(3, "Short read or OOM loading DB. Unrecoverable error, aborting now.", ls))})

# what BendKV makes of a value's type: 0 one it reads (0 to 5, 9 to 19),
# 1 a module's value (6, 7), 2 none
def fl.tk(+t: Nat) -> Nat:
  Bool.pick(Nat, Bool.or(Nat.is_le(t, 5n), Bool.and(Nat.is_le(9n, t), Nat.is_le(t, 19n))), 0n, Bool.pick(Nat, Bool.or(Nat.is_eq(t, 6n), Nat.is_eq(t, 7n)), 1n, 2n))

def fl.kind(c: Nat, +op: Nat, +key: String, t: String, +at: FAt, k: FK, dbs: FDs, exp: FT, n: FN, ls: List<&2, FLine>) -> FS:
  match c:
    case 0n:
      fl.val(obj.rest(op, t), op, key, at, k, dbs, exp, n, ls)
    case 1n:
      FEnd{fl.stop("BendKV has no modules: the RDB file holds a module's value (key '" ++ key ++ "'), which it cannot load", ls)}
    case _:
      FEnd{fl.stop("Internal error in RDB reading offset " ++ Nat.show(fat.n(at)) ++ " -> Unknown RDB encoding type " ++ Nat.show(op), ls)}

def fl.key(m: Maybe<&1, String & String>, +op: Nat, +at: FAt, k: FK, dbs: FDs, exp: FT, n: FN, ls: List<&2, FLine>) -> FS:
  match m:
    case Some{p}:
      (+key, t) = p
      fl.kind(fl.tk(op), op, key, t, at, k, dbs, exp, n, ls)
    case None{}:
      fl.short.at(at, k, dbs, exp, n, ls)

# EOF: the load is done; from version 5 on, the CRC64 after it is read,
# to be checked (fl.checked) over the bytes up to EOF, with it
def fl.done(dbs: FDs, n: FN, ls: List<&2, FLine>, sm: FSum) -> FLd:
  match n:
    case FN{ld, ex, em}:
      FOk{fds.list(dbs), ld, ex, em, ls, sm}

def fl.sum(sum: Bool, +n: Nat, +hi: Nat, +lo: Nat) -> FSum:
  match sum:
    case False{}:
      FSumNone{}
    case True{}:
      Bool.pick(FSum, Bool.and(Nat.is_eq(hi, 0n), Nat.is_eq(lo, 0n)), FSumZero{}, FSumAt{n, hi, lo})

def fk.ver(+k: FK) -> Nat:
  match k:
    case FK{len, +ver, now, sum}:
      ver

def fk.sum(+k: FK) -> Bool:
  match k:
    case FK{len, ver, now, +sum}:
      sum

def fl.crc.hi(+lo: Nat, m: Maybe<&1, Nat & String>, +at: FAt, +k: FK, dbs: FDs, exp: FT, n: FN, +ls: List<&2, FLine>) -> FS:
  match m:
    case Some{p}:
      (+hi, t) = p
      FEnd{fl.done(dbs, n, ls, fl.sum(fk.sum(k), Nat.add(fat.n(at), 1n), hi, lo))}
    case None{}:
      fl.more(at, k, dbs, exp, n, ls, fl.short(Nat.add(fat.n(at), 1n), ls))

def fl.crc(m: Maybe<&1, Nat & String>, +at: FAt, k: FK, dbs: FDs, exp: FT, n: FN, +ls: List<&2, FLine>) -> FS:
  match m:
    case Some{p}:
      (+lo, t) = p
      fl.crc.hi(lo, rd.le(4n, t, 1n, 0n), at, k, dbs, exp, n, ls)
    case None{}:
      fl.more(at, k, dbs, exp, n, ls, fl.short(Nat.add(fat.n(at), 1n), ls))

def fl.eof.v(old: Bool, t: String, +at: FAt, k: FK, dbs: FDs, exp: FT, n: FN, ls: List<&2, FLine>) -> FS:
  match old:
    case True{}:
      FEnd{fl.done(dbs, n, ls, FSumNone{})}
    case False{}:
      fl.crc(rd.le(4n, t, 1n, 0n), at, k, dbs, exp, n, ls)

def fl.eof(t: String, +at: FAt, +k: FK, dbs: FDs, exp: FT, n: FN, ls: List<&2, FLine>) -> FS:
  fl.eof.v(Nat.is_lt(fk.ver(k), 5n), t, at, k, dbs, exp, n, ls)

# an opcode (op, of code c: 0 a value's type, 1 FUNCTION2, 2 FUNCTION, 3
# MODULE_AUX, 4 IDLE, 5 FREQ, 6 AUX, 7 RESIZEDB, 8 EXPIRETIME_MS, 9
# EXPIRETIME, 10 SELECTDB, 11 EOF) at offset at, and the bytes after it
def fl.code(c: Nat, +op: Nat, t: String, +at: FAt, k: FK, dbs: FDs, exp: FT, n: FN, ls: List<&2, FLine>) -> FS:
  match c:
    case 0n:
      fl.key(rd.str(t), op, at, k, dbs, exp, n, ls)
    case 1n:
      FEnd{fl.stop(fl.nofn(), ls)}
    case 2n:
      FEnd{fl.stop(fl.nofn(), ls)}
    case 3n:
      FEnd{fl.stop("BendKV has no modules: the RDB file holds a module's data (MODULE_AUX), which it cannot load", ls)}
    case 4n:
      fl.skip(rd.num(t), at, k, dbs, exp, n, ls)
    case 5n:
      fl.skip(rd.u8(t), at, k, dbs, exp, n, ls)
    case 6n:
      fl.aux(rd.str(t), at, k, dbs, exp, n, ls)
    case 7n:
      fl.resize(rd.num(t), at, k, dbs, exp, n, ls)
    case 8n:
      fl.ms(rd.le(4n, t, 1n, 0n), at, k, dbs, exp, n, ls)
    case 9n:
      fl.secs(rd.le(4n, t, 1n, 0n), at, k, dbs, exp, n, ls)
    case 10n:
      fl.select(rd.num(t), at, k, dbs, exp, n, ls)
    case _:
      fl.eof(t, at, k, dbs, exp, n, ls)

def fl.op(m: Maybe<&1, Nat & String>, +at: FAt, k: FK, dbs: FDs, exp: FT, n: FN, ls: List<&2, FLine>) -> FS:
  match m:
    case Some{p}:
      (+op, t) = p
      fl.code(Bool.pick(Nat, Nat.is_lt(op, 245n), 0n, Nat.sub(op, 244n)), op, t, at, k, dbs, exp, n, ls)
    case None{}:
      fl.short.at(at, k, dbs, exp, n, ls)

def fk.len(+k: FK) -> Nat:
  match k:
    case FK{+len, ver, now, sum}:
      len

def fl.step(r: FR) -> FS:
  match r:
    case FR{+left, +k, dbs, exp, n, ls}:
      fl.op(rd.u8(left), FAt{fk.len(k), left}, k, dbs, exp, n, ls)

# each step reads a byte at least: the bytes there and one are fuel enough
# for the steps they hold; the run ends, or stops for more bytes
def fl.run(f: Nat, s: FS) -> FS:
  match f s:
    case 1n+g FGo{r}:
      fl.run(g, fl.step(r))
    case _ FEnd{d}:
      FEnd{d}
    case _ FMore{r, fail}:
      FMore{r, fail}
    case 0n FGo{r}:
      FEnd{FFail{[FLine{3, "Short read or OOM loading DB. Unrecoverable error, aborting now."}]}}

# The start of a file: "REDIS" and the version
def fl.version.ok(ok: Bool, +neg: Bool, +v: Nat, s: String, +len: Nat, dbs: FDs, +now: Nat, +sum: Bool) -> FS:
  match ok:
    case True{}:
      FGo{FR{String.drop(s, 9n), FK{len, v, now, sum}, dbs, FTNone{}, FN{0n, 0n, 0n}, Nil{}}}
    case False{}:
      FEnd{FFail{[FLine{3, "Fatal error loading the DB: Invalid argument. Exiting."}, FLine{3, "Can't handle RDB format version " ++ num.show((neg, v))}]}}

def fl.version(p: Bool & Nat, s: String, +len: Nat, dbs: FDs, +now: Nat, +sum: Bool) -> FS:
  (+neg, +v) = p
  fl.version.ok(Bool.and(Bool.not(neg), Bool.and(Nat.is_le(1n, v), Nat.is_le(v, 10n))), neg, v, s, len, dbs, now, sum)

# c: 0 shorter than nine bytes, 1 no "REDIS", 2 the version next
def fl.magic(c: Nat, +s: String, +len: Nat, dbs: FDs, +now: Nat, +sum: Bool) -> FS:
  match c:
    case 0n:
      FEnd{fl.short(0n, Nil{})}
    case 1n:
      FEnd{FFail{[FLine{3, "Fatal error loading the DB: Invalid argument. Exiting."}, FLine{3, "Wrong signature trying to load DB from file"}]}}
    case _:
      fl.version(num.of(String.slice(s, 5n, 4n)), s, len, dbs, now, sum)

# the end of a load: its last line (Done loading RDB), or the CRC64 found
# wrong
def fl.fin(dbs: List<&2, FDb>, +ld: Nat, +ex: Nat, +em: Nat, ls: List<&2, FLine>) -> FLd:
  FOk{dbs, ld, ex, em, fl.line(Bool.pick(U32, Nat.is_eq(em, 0n), 2, 3), "Done loading RDB, keys loaded: " ++ Nat.show(ld) ++ ", keys expired: " ++ Nat.show(ex) ++ Bool.pick(String, Nat.is_eq(em, 0n), ".", ", empty keys skipped: " ++ Nat.show(em) ++ "."), ls), FSumNone{}}

def fl.crc.ok(same: Bool, +want: String, +got: String, +n: Nat, dbs: List<&2, FDb>, +ld: Nat, +ex: Nat, +em: Nat, ls: List<&2, FLine>) -> FLd:
  match same:
    case True{}:
      fl.fin(dbs, ld, ex, em, ls)
    case False{}:
      FFail{fl.line(3, "Internal error in RDB reading offset " ++ Nat.show(n) ++ " -> RDB CRC error", fl.line(3, "Wrong RDB checksum expected: (" ++ want ++ ") but got (" ++ got ++ "). Aborting now.", ls))}

def fl.crc.cmp(c: C, +n: Nat, +hi: Nat, +lo: Nat, dbs: List<&2, FDb>, +ld: Nat, +ex: Nat, +em: Nat, ls: List<&2, FLine>) -> FLd:
  match c:
    case C{+ch, +cl}:
      fl.crc.ok(Bool.and(Nat.is_eq(U32.to_nat(ch), hi), Nat.is_eq(U32.to_nat(cl), lo)), hex.q(U32.to_nat(ch), U32.to_nat(cl)), hex.q(hi, lo), n, dbs, ld, ex, em, ls)

# a load's end checked against its CRC64: c the CRC of the bytes before w,
# which starts at the file's offset base (0 for a whole file, as SAVE's
# reads it; the start's last window otherwise)
def file.checked(d: FLd, c: C, +w: String, +base: Nat) -> FLd:
  match d:
    case FOk{dbs, +ld, +ex, +em, ls, FSumAt{+n, +hi, +lo}}:
      fl.crc.cmp(crc.k(Nat.sub(n, base), w, c), n, hi, lo, dbs, ld, ex, em, ls)
    case FOk{dbs, +ld, +ex, +em, ls, FSumZero{}}:
      fl.fin(dbs, ld, ex, em, fl.line(3, "RDB file was saved with checksum disabled: no check performed.", ls))
    case FOk{dbs, +ld, +ex, +em, ls, FSumNone{}}:
      fl.fin(dbs, ld, ex, em, ls)
    case FFail{ls}:
      FFail{ls}

# what a run of the whole file comes to: its end, or what the load fails
# with when a step needs bytes the file has not
def file.end(s: FS) -> FLd:
  match s:
    case FEnd{d}:
      d
    case FMore{r, fail}:
      fail
    case FGo{r}:
      FFail{[FLine{3, "Short read or OOM loading DB. Unrecoverable error, aborting now."}]}

# the first bytes w (wlen of them) of a file loaded into ndb databases (one
# at least), at now (ms since 1970), its CRC64 checked when sum
# (rdbchecksum yes), run as far as they go
def file.first(+w: String, +wlen: Nat, +ndb: Nat, +now: Nat, +sum: Bool) -> FS:
  fl.run(Nat.add(wlen, 1n), fl.magic(Bool.pick(Nat, Nat.is_lt(wlen, 9n), 0n, Bool.pick(Nat, String.eq(String.take(w, 5n), "REDIS"), 2n, 1n)), w, wlen, FDs{fdb.empty(), Nil{}, fds.empties(Nat.sub(ndb, 1n))}, now, sum))

# The load of a file in windows (the start's): the bytes a load stopped
# for more left (file.left), and the load run again on w, those bytes then
# the next window's xlen (wlen in all), its file's length so far grown by
# xlen
def file.left(+r: FR) -> String:
  match r:
    case FR{+left, k, dbs, exp, n, ls}:
      left

def fk.grow(k: FK, +x: Nat) -> FK:
  match k:
    case FK{+len, ver, now, sum}:
      FK{Nat.add(len, x), ver, now, sum}

def file.next(r: FR, +w: String, +wlen: Nat, +xlen: Nat) -> FS:
  match r:
    case FR{left, k, dbs, exp, n, ls}:
      fl.run(Nat.add(wlen, 1n), FGo{FR{w, fk.grow(k, xlen), dbs, exp, n, ls}})

# the file s, read whole, loaded
def file.load(+s: String, +ndb: Nat, +now: Nat, +sum: Bool) -> FLd:
  +len = String.length(s)
  file.checked(file.end(file.first(s, len, ndb, now, sum)), C{0, 0}, s, 0n)
