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
# most 6)
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
# does a string that ends shorter than len. Out are the pieces made
# (newest first) and a window of the last 8 to 16 KB of them, which a
# reference reads (a distance is 8192 at most).

type Lzf is Data:
  Lzf{inp: String, ci: Nat, out: List<&2, String>, w: String, wl: Nat, op: Nat}

def lzf.win(cut: Bool, +w: String, +wl: Nat) -> String:
  match cut:
    case True{}:
      String.drop(w, Nat.sub(wl, 8192n))
    case False{}:
      w

# the k bytes p out
def lzf.put(+p: String, +k: Nat, rest: String, +ci: Nat, out: List<&2, String>, w: String, +wl: Nat, +op: Nat) -> Lzf:
  +w2 = w ++ p
  +wl2 = Nat.add(wl, k)
  +cut = Nat.is_lt(16384n, wl2)
  Lzf{rest, ci, p <> out, lzf.win(cut, w2, wl2), Bool.pick(Nat, cut, 8192n, wl2), Nat.add(op, k)}

def lzf.lit(ok: Bool, +k: Nat, +inp: String, +ci: Nat, out: List<&2, String>, w: String, +wl: Nat, +op: Nat) -> Maybe<&2, Lzf>:
  match ok:
    case True{}:
      +r1 = String.drop(inp, 1n)
      Some{lzf.put(String.take(r1, k), k, String.drop(r1, k), Nat.sub(ci, Nat.add(k, 1n)), out, w, wl, op)}
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

def lzf.ref(ok: Bool, +k: Nat, +d: Nat, rest: String, +ci: Nat, out: List<&2, String>, +w: String, +wl: Nat, +op: Nat) -> Maybe<&2, Lzf>:
  match ok:
    case True{}:
      +m = Nat.min(k, d)
      Some{lzf.put(lzf.rep(10n, Nat.is_le(k, m), String.slice(w, Nat.sub(wl, d), m), m, k), k, rest, ci, out, w, wl, op)}
    case False{}:
      None{}

def lzf.op(lit: Bool, +n: Nat, +c: Nat, +h: String, +inp: String, +ci: Nat, out: List<&2, String>, w: String, +wl: Nat, +op: Nat) -> Maybe<&2, Lzf>:
  match lit:
    case True{}:
      +k = Nat.add(c, 1n)
      lzf.lit(Bool.and(Nat.is_le(Nat.add(k, 1n), ci), Nat.is_le(Nat.add(op, k), n)), k, inp, ci, out, w, wl, op)
    case False{}:
      +l0 = Nat.div(c, 32n)
      +long = Nat.is_eq(l0, 7n)
      +used = Bool.pick(Nat, long, 3n, 2n)
      +len = Bool.pick(Nat, long, Nat.add(7n, U32.to_nat(String.code_at(h, 1n))), l0)
      +lo = U32.to_nat(String.code_at(h, Bool.pick(Nat, long, 2n, 1n)))
      +d = Nat.add(Nat.add(Nat.mul(Nat.mod(c, 32n), 256n), lo), 1n)
      +k = Nat.add(len, 2n)
      lzf.ref(Bool.and(Bool.and(Nat.is_le(used, ci), Nat.is_le(Nat.add(op, k), n)), Nat.is_le(d, op)), k, d, String.drop(inp, used), Nat.sub(ci, used), out, w, wl, op)

def lzf.step(+n: Nat, st: Lzf) -> Maybe<&2, Lzf>:
  match st:
    case Lzf{+inp, +ci, out, w, +wl, +op}:
      +h = String.take(inp, 3n)
      +c = U32.to_nat(String.code_at(h, 0n))
      lzf.op(Nat.is_lt(c, 32n), n, c, h, inp, ci, out, w, wl, op)

# the pieces out, oldest first, before acc
def lzf.cat(out: List<&2, String>, acc: String) -> String:
  match out:
    case Nil{}:
      acc
    case Con{p, rest}:
      lzf.cat(rest, p ++ acc)

def lzf.fin(ok: Bool, out: List<&2, String>) -> Maybe<&2, String>:
  match ok:
    case True{}:
      Some{lzf.cat(out, "")}
    case False{}:
      None{}

def lzf.go(f: Nat, +n: Nat, m: Maybe<&2, Lzf>) -> Maybe<&2, String>:
  match f m:
    case 1n+g Some{Lzf{inp, ci, out, w, wl, +op}}:
      match ci:
        case 0n:
          lzf.fin(Nat.is_eq(op, n), out)
        case 1n+c:
          lzf.go(g, n, lzf.step(n, Lzf{inp, 1n+c, out, w, wl, op}))
    case _ _:
      None{}

# len bytes from the clen bytes c (a string of len 0 is "", whatever c
# holds: lzf_decompress then answers 0, which is len)
def lzf.dec(+c: String, +clen: Nat, +len: Nat) -> Maybe<&2, String>:
  match len:
    case 0n:
      Some{""}
    case _:
      lzf.go(Nat.add(clen, 1n), len, Some{Lzf{c, clen, Nil{}, "", 0n, 0n}})

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
# holds at most 512 members, all integers as Redis writes them; a sorted
# set small (ZSmall) when it came as a listpack or ziplist of at most 128
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

# the tree of the integers xs, each added in its place
def ints.tree(xs: List<&2, String>, t: KV.ITree) -> KV.ITree:
  match xs:
    case Nil{}:
      t
    case Con{x, rest}:
      ints.tree(rest, KV.ints.put(x, t))

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

def val.set.of(ints: Bool, +n: Nat, xs: List<&2, String>, t: KV.Trie<Unit>) -> KV.Val:
  match ints:
    case True{}:
      KV.VColl{KV.CMems{KV.MInts{n, ints.tree(xs, KV.ITip{})}}}
    case False{}:
      KV.VColl{KV.CMems{KV.MBig{n, t}}}

# a set of the n members xs, the trie of which finds a member twice
def val.set.any(+n: Nat, +xs: List<&2, String>) -> Maybe<&2, KV.Val>:
  +t = mems.trie(xs, KV.empty(Unit))
  Bool.pick(Maybe<&2, KV.Val>, Bool.and(Nat.is_lt(0n, n), Nat.is_eq(KV.size(Unit, t), n)), Some{val.set.of(Bool.and(Nat.is_le(n, 512n), all.ints(xs)), n, xs, t)}, None{})

def val.set.go(ints: Bool, +n: Nat, +xs: List<&2, String>) -> Maybe<&2, KV.Val>:
  match ints:
    case True{}:
      Some{KV.VColl{KV.CMems{KV.MInts{n, KV.ints.build(n, xs)}}}}
    case False{}:
      val.set.any(n, xs)

# a set of the members xs (sorted: integers in increasing order, from an
# intset, which are an intset at once when they are 512 at most: each is
# there once, so no trie of them is made)
def val.set(+sorted: Bool, +xs: List<&2, String>) -> Maybe<&2, KV.Val>:
  +n = List.length(&2, String, xs)
  val.set.go(Bool.and(sorted, Bool.and(Nat.is_lt(0n, n), Nat.is_le(n, 512n))), n, xs)

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
# node skipped. A stream (15, 19) and a module's value (6, 7) are no
# value BendKV holds, and any other type no value at all.

# the strings after r, the one just read, k more after it
def rd.strs(k: Nat, r: Maybe<&1, String & String>, acc: List<&2, String>) -> Maybe<&2, List<&2, String>>:
  match k r:
    case 0n Some{p}:
      (x, t) = p
      Some{List.reverse(&2, String, x <> acc)}
    case 1n+j Some{p}:
      (x, t) = p
      rd.strs(j, rd.str(t), x <> acc)
    case _ None{}:
      None{}

# n strings
def rd.strs.n(n: Nat, t: String) -> Maybe<&2, List<&2, String>>:
  match n:
    case 0n:
      Some{Nil{}}
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

def z.els(k: Nat, +two: Bool, r: Maybe<&1, KV.ZEl & String>, acc: List<&2, KV.ZEl>) -> Maybe<&2, List<&2, KV.ZEl>>:
  match k r:
    case 0n Some{p}:
      (e, t) = p
      Some{List.reverse(&2, KV.ZEl, e <> acc)}
    case 1n+j Some{p}:
      (e, t) = p
      z.els(j, two, z.el(two, t), e <> acc)
    case _ None{}:
      None{}

def z.els.n(n: Nat, +two: Bool, t: String) -> Maybe<&2, List<&2, KV.ZEl>>:
  match n:
    case 0n:
      Some{Nil{}}
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
# before acc, the newest first
def ql.nodes(k: Nat, +two: Bool, r: Maybe<&1, List<&2, String> & String>, acc: List<&2, String>) -> Maybe<&2, List<&2, String>>:
  match k r:
    case 0n Some{p}:
      (xs, t) = p
      Some{List.reverse(&2, String, List.reverse.go(&2, String, xs, acc))}
    case 1n+j Some{p}:
      (xs, t) = p
      ql.nodes(j, two, ql.node(two, t), List.reverse.go(&2, String, xs, acc))
    case _ None{}:
      None{}

def ql.nodes.n(n: Nat, +two: Bool, t: String) -> Maybe<&2, List<&2, String>>:
  match n:
    case 0n:
      Some{Nil{}}
    case 1n+k:
      ql.nodes(k, two, ql.node(two, t), Nil{})

def obj.str(m: Maybe<&1, String & String>) -> Maybe<&2, KV.Val>:
  match m:
    case Some{p}:
      (x, t) = p
      Some{KV.VStr{x}}
    case None{}:
      None{}

def obj.list(m: Maybe<&2, List<&2, String>>) -> Maybe<&2, KV.Val>:
  match m:
    case Some{xs}:
      val.list(xs)
    case None{}:
      None{}

def obj.set(+sorted: Bool, m: Maybe<&2, List<&2, String>>) -> Maybe<&2, KV.Val>:
  match m:
    case Some{xs}:
      val.set(sorted, xs)
    case None{}:
      None{}

# a hash of pairs ps (lp: as a listpack, ziplist or zipmap kept them,
# whose fields and values are not checked: zm: as a zipmap's, which are)
def obj.hps(+lp: Bool, m: Maybe<&2, List<&2, KV.HPair>>) -> Maybe<&2, KV.Val>:
  match m:
    case Some{+ps}:
      +n = List.length(&2, KV.HPair, ps)
      val.hash(Bool.and(Nat.is_le(n, 512n), Bool.or(lp, Bool.not(hps.gt(ps, 64n)))), n, ps)
    case None{}:
      None{}

def obj.hlp(m: Maybe<&2, List<&2, String>>) -> Maybe<&2, KV.Val>:
  match m:
    case Some{xs}:
      obj.hps(True{}, pairs.of(xs, Nil{}))
    case None{}:
      None{}

def obj.hash(m: Maybe<&2, List<&2, String>>) -> Maybe<&2, KV.Val>:
  match m:
    case Some{xs}:
      obj.hps(False{}, pairs.of(xs, Nil{}))
    case None{}:
      None{}

def obj.zels(+lp: Bool, m: Maybe<&2, List<&2, KV.ZEl>>) -> Maybe<&2, KV.Val>:
  match m:
    case Some{+es}:
      val.zset(lp, Bool.or(lp, Bool.not(zel.gt(es, 64n))), es)
    case None{}:
      None{}

def obj.zlp(m: Maybe<&2, List<&2, String>>) -> Maybe<&2, KV.Val>:
  match m:
    case Some{xs}:
      obj.zels(True{}, zels.of(xs, Nil{}))
    case None{}:
      None{}

def obj.blob.of(k: Nat, +b: String) -> Maybe<&2, KV.Val>:
  match k:
    case 9n:
      obj.hps(False{}, zm.read(b))
    case 10n:
      obj.list(zl.read(b))
    case 11n:
      obj.set(True{}, is.read(b))
    case 12n:
      obj.zlp(zl.read(b))
    case 13n:
      obj.hlp(zl.read(b))
    case 16n:
      obj.hlp(lp.read(b))
    case 17n:
      obj.zlp(lp.read(b))
    case _:
      None{}

def obj.blob(k: Nat, m: Maybe<&1, String & String>) -> Maybe<&2, KV.Val>:
  match m:
    case Some{p}:
      (b, t) = p
      obj.blob.of(k, b)
    case None{}:
      None{}

# the value of type k, of n elements, in t (a hash's 2n strings: no more
# than t's bytes are asked for, as each string takes one at least, so
# that a count past them, up to 2^48, makes no product past 2^48)
def obj.n.at(k: Nat, +n: Nat, +t: String) -> Maybe<&2, KV.Val>:
  match k:
    case 1n:
      obj.list(rd.strs.n(n, t))
    case 2n:
      obj.set(False{}, rd.strs.n(n, t))
    case 3n:
      obj.zels(False{}, z.els.n(n, False{}, t))
    case 4n:
      obj.hash(rd.strs.n(Nat.mul(2n, Nat.min(n, String.length(t))), t))
    case 5n:
      obj.zels(False{}, z.els.n(n, True{}, t))
    case 14n:
      obj.list(ql.nodes.n(n, False{}, t))
    case _:
      obj.list(ql.nodes.n(n, True{}, t))

def obj.n(k: Nat, m: Maybe<&1, Nat & String>) -> Maybe<&2, KV.Val>:
  match m:
    case Some{p}:
      (+n, t) = p
      obj.n.at(k, n, t)
    case None{}:
      None{}

# the value of type k in s
def obj(+k: Nat, s: String) -> Maybe<&2, KV.Val>:
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
    case _:
      Bool.pick(Maybe<&2, KV.Val>, Bool.or(Bool.and(Nat.is_le(9n, k), Nat.is_le(k, 13n)), Bool.or(Nat.is_eq(k, 16n), Nat.is_eq(k, 17n))), obj.blob(k, rd.str(s)), None{})

# Writing a value
# ---------------
# rdbSaveObject, with rdbcompression no: a string; a small hash as one
# listpack (HASH_LISTPACK) and a large one as its count and its fields
# and values (HASH, in the order of its trie, where Redis's are in the
# order of its table); a list as a quicklist (LIST_QUICKLIST_2) of the
# nodes RPUSH makes of its elements (at list-max-listpack-size -2: a node
# takes an element while its listpack's bytes, the element's and 8 stay
# within 8192), each packed (2) as a listpack; an intset (SET_INTSET) of
# the narrowest width that holds its members, a large set as its count and
# members (SET); a small sorted set as one listpack (ZSET_LISTPACK) of its
# members and scores (a score as a listpack keeps it: F.f64.show_lp), a
# large one as its count, then its members and their scores' bits from
# the greatest down (ZSET_2).

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
      b1(16) ++ put.blob(lp.blob(hps.words(KV.hb.pairs(n, b, 0n)), Nat.mul(2n, n)), rest)
    case KV.HLong{+n, +ps}:
      b1(16) ++ put.blob(lp.blob(hps.words(KV.hl.pairs(ps)), Nat.mul(2n, n)), rest)
    case KV.HBig{+n, +t}:
      b1(4) ++ len.put(n, put.strs(hps.words(KV.hash.kv(t, KV.keys(String, t, 0n))), rest))

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
  b1(18) ++ len.put(List.length(&2, List<&2, String>, ns), put.nodes(ns, rest))

# Sets: an intset's width (2, 4 or 8 bytes) is the widest its members need
def is.w.of(v: IV) -> Nat:
  match v:
    case IN{+neg, +m}:
      +b = Bool.pick(Nat, neg, 1n, 0n)
      Bool.pick(Nat, Nat.is_lt(m, Nat.add(32768n, b)), 2n, Bool.pick(Nat, Nat.is_lt(m, Nat.add(2147483648n, b)), 4n, 8n))
    case _:
      8n

def is.w(xs: List<&2, String>, +w: Nat) -> Nat:
  match xs:
    case Nil{}:
      w
    case Con{+x, rest}:
      is.w(rest, Nat.max(w, is.w.of(iv(x))))

def is.put.of(w: Nat, v: IV, rest: String) -> String:
  match w v:
    case 2n IN{+neg, +m}:
      le(2n, twos(neg, 65536n, m), rest)
    case 4n IN{+neg, +m}:
      le(4n, twos(neg, two32(), m), rest)
    case _ IN{+neg, +m}:
      q.le(q.of_nat(neg, m), rest)
    case _ IQ{q}:
      q.le(q, rest)
    case _ INo{}:
      le(8n, 0n, rest)

def is.puts(+w: Nat, xs: List<&2, String>, rest: String) -> String:
  match xs:
    case Nil{}:
      rest
    case Con{+x, more}:
      is.put.of(w, iv(x), is.puts(w, more, rest))

def is.blob(+n: Nat, +xs: List<&2, String>) -> String:
  +w = is.w(xs, 2n)
  le(4n, w, le(4n, n, is.puts(w, xs, "")))

def put.mems(m: KV.Mems, rest: String) -> String:
  match m:
    case KV.MInts{+n, xs}:
      b1(11) ++ put.blob(is.blob(n, KV.ints.list(xs)), rest)
    case KV.MBig{+n, +t}:
      b1(2) ++ len.put(n, put.strs(KV.keys(Unit, t, 0n), rest))

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
      b1(17) ++ put.blob(lp.blob(zel.words(KV.zb.all(n, b)), Nat.mul(2n, n)), rest)
    case KV.ZWide{+tr}:
      b1(17) ++ put.blob(lp.blob(zel.words(KV.zt.all(tr)), Nat.mul(2n, KV.zt.size(tr))), rest)
    case KV.ZBig{+tr, t}:
      b1(5) ++ len.put(KV.zt.size(tr), put.z2(List.reverse(&2, KV.ZEl, KV.zt.all(tr)), rest))

def put.val(v: KV.Val, rest: String) -> String:
  match v:
    case KV.VStr{+s}:
      b1(0) ++ str.put(s, rest)
    case KV.VColl{KV.CHash{h}}:
      put.hash(h, rest)
    case KV.VColl{KV.CList{d}}:
      put.list(d, rest)
    case KV.VColl{KV.CMems{m}}:
      put.mems(m, rest)
    case KV.VColl{KV.CZset{z}}:
      put.zset(z, rest)

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
