# hll.bend: HyperLogLog as Redis 7.0.15 keeps it (hyperloglog.c), on the
# bytes of a string value. A header of 16 bytes: "HYLL", the encoding (0
# dense, 1 sparse), 3 unused bytes, and the cardinality last counted, 8
# bytes little-endian, its top bit set when it is not valid; then the
# 16384 registers of 6 bits. Dense, they are 12288 bytes, register i at
# bit 6i, the low bits first; sparse, they are runs of opcodes: ZERO
# 00xxxxxx (1 to 64 registers at 0), XZERO 01xxxxxx yyyyyyyy (1 to 16384
# at 0), VAL 1vvvvvxx (1 to 4 registers at 1 to 32). An element counts in
# register h mod 2^14 of its hash h (MurmurHash64A, seed 0xadc83b19) as
# the place of the lowest 1 of h div 2^14, counted from 1 (51 at most).
#
# Every operation runs here as Redis's does, byte for byte, on any string
# Redis takes for a HyperLogLog (valid): one whose opcodes do not cover
# 16384 registers too, or end within an XZERO, which Redis reads as far
# as the byte after the string's end (pe): the NUL of its sds string, 0,
# when a command starts; a set that splits such an XZERO writes the last
# byte of the opcodes it makes there, which the sets after it in the
# same command read (sp.put.go).

import Base
import ./float.bend as F

# Bytes
# -----

# the byte at i of s, of n bytes: 0 at or past n
def hb(+s: String, +n: Nat, +i: Nat) -> U32:
  Bool.pick(U32, Nat.is_lt(i, n), String.code_at(s, i), 0)

def b1(+x: U32) -> String:
  SCon{Chr{x}, SNil{}}

# n zero bytes: the halves made once (f bounds the depth; 64 is more than
# any n needs)
def zeros.go(f: Nat, n: Nat) -> String:
  match f n:
    case _ 0n:
      ""
    case 0n _:
      ""
    case 1n+g 1n++p:
      +h = zeros.go(g, Nat.div(1n+p, 2n))
      Bool.pick(String, Nat.is_eq(Nat.mod(1n+p, 2n), 1n), b1(0), "") ++ h ++ h

def zeros(n: Nat) -> String:
  zeros.go(64n, n)

# 64-bit words
# ------------
# as two halves of 32 bits, which wrap as C's uint64_t does

type W is Data:
  W{hi: U32, lo: U32}

def w.xor(a: W, b: W) -> W:
  match a b:
    case W{+ah, +al} W{+bh, +bl}:
      W{U32.xor(ah, bh), U32.xor(al, bl)}

# the 64-bit product of two halves, by quarters of 16 bits
def w.mul32(+a: U32, +b: U32) -> W:
  +a0 = U32.and(a, 65535)
  +a1 = U32.shrn(a, 16n)
  +b0 = U32.and(b, 65535)
  +b1 = U32.shrn(b, 16n)
  +ll = U32.mul(a0, b0)
  +lh = U32.mul(a0, b1)
  +hl = U32.mul(a1, b0)
  +mid = U32.add(U32.add(U32.shrn(ll, 16n), U32.and(lh, 65535)), U32.and(hl, 65535))
  W{U32.add(U32.add(U32.add(U32.mul(a1, b1), U32.shrn(lh, 16n)), U32.shrn(hl, 16n)), U32.shrn(mid, 16n)), U32.mul(a, b)}

def w.mul.of(p: W, +c: U32) -> W:
  match p:
    case W{+h, +l}:
      W{U32.add(h, c), l}

# a * b, wrapping
def w.mul(a: W, b: W) -> W:
  match a b:
    case W{+ah, +al} W{+bh, +bl}:
      w.mul.of(w.mul32(al, bl), U32.add(U32.mul(ah, bl), U32.mul(al, bh)))

# a >> 47
def w.shr47(a: W) -> W:
  match a:
    case W{+h, l}:
      W{0, U32.shrn(h, 15n)}

# MurmurHash64A
# -------------

def mm.m() -> W:
  W{3332679571, 1540483477}

# the 4 bytes of s at i, the first the lowest
def mm.load32(+s: String, +i: Nat) -> U32:
  U32.or(U32.or(String.code_at(s, i), U32.shln(String.code_at(s, Nat.add(i, 1n)), 8n)), U32.or(U32.shln(String.code_at(s, Nat.add(i, 2n)), 16n), U32.shln(String.code_at(s, Nat.add(i, 3n)), 24n)))

# a block's word k mixed: k * m, k ^ k >> 47, times m
def mm.mix(k: W) -> W:
  +k1 = w.mul(k, mm.m())
  w.mul(w.xor(k1, w.shr47(k1)), mm.m())

# the n blocks of 8 bytes of s from i, into h
def mm.blocks(n: Nat, +s: String, +i: Nat, h: W) -> W:
  match n:
    case 0n:
      h
    case 1n+p:
      mm.blocks(p, s, Nat.add(i, 8n), w.mul(w.xor(h, mm.mix(W{mm.load32(s, Nat.add(i, 4n)), mm.load32(s, i)})), mm.m()))

# byte j of the t bytes left at i, 0 past them
def mm.tb(+s: String, +i: Nat, +t: Nat, +j: Nat) -> U32:
  Bool.pick(U32, Nat.is_lt(j, t), String.code_at(s, Nat.add(i, j)), 0)

def mm.tail.w(+s: String, +i: Nat, +t: Nat) -> W:
  W{U32.or(U32.or(mm.tb(s, i, t, 4n), U32.shln(mm.tb(s, i, t, 5n), 8n)), U32.shln(mm.tb(s, i, t, 6n), 16n)), U32.or(U32.or(mm.tb(s, i, t, 0n), U32.shln(mm.tb(s, i, t, 1n), 8n)), U32.or(U32.shln(mm.tb(s, i, t, 2n), 16n), U32.shln(mm.tb(s, i, t, 3n), 24n)))}

def mm.tail(none: Bool, +t: Nat, +s: String, +i: Nat, h: W) -> W:
  match none:
    case True{}:
      h
    case False{}:
      w.mul(w.xor(h, mm.tail.w(s, i, t)), mm.m())

def mm.fin(h: W) -> W:
  +h0 = h
  +h1 = w.mul(w.xor(h0, w.shr47(h0)), mm.m())
  w.xor(h1, w.shr47(h1))

# MurmurHash64A of s with Redis's seed, 0xadc83b19
def murmur(+s: String) -> W:
  +n = String.length(s)
  +t = Nat.mod(n, 8n)
  mm.fin(mm.tail(Nat.is_eq(t, 0n), t, s, Nat.sub(n, t), mm.blocks(Nat.div(n, 8n), s, 0n, w.xor(W{0, 2915580697}, w.mul(W{0, U32.from_nat(n)}, mm.m())))))

# Where an element counts
# ----------------------

# the register of an element and the run of 0 bits its hash shows, its 1
# counted
type Pat is Data:
  Pat{idx: Nat, cnt: Nat}

def ctz.go(fuel: Nat, odd: Bool, +x: U32, +n: Nat) -> Nat:
  match fuel:
    case 0n:
      n
    case 1n+f:
      match odd:
        case True{}:
          n
        case False{}:
          +y = U32.shrn(x, 1n)
          ctz.go(f, U32.is_ne(U32.and(y, 1), 0), y, Nat.add(n, 1n))

# the 0 bits of x (not 0) below its lowest 1
def ctz(+x: U32) -> Nat:
  ctz.go(32n, U32.is_ne(U32.and(x, 1), 0), x, 0n)

# the run of h div 2^14 with bit 50 set: in its low half a (the bits 14
# to 31 of h), its high half hi, or up to bit 50
def pat.cnt(la: Bool, lh: Bool, +a: U32, +hi: U32) -> Nat:
  match la:
    case True{}:
      Nat.add(ctz(a), 1n)
    case False{}:
      match lh:
        case True{}:
          Nat.add(ctz(hi), 19n)
        case False{}:
          51n

def pat.of(h: W) -> Pat:
  match h:
    case W{+hi, +lo}:
      +a = U32.shrn(lo, 14n)
      Pat{U32.to_nat(U32.and(lo, 16383)), pat.cnt(U32.is_ne(a, 0), U32.is_ne(hi, 0), a, hi)}

def pat(+e: String) -> Pat:
  pat.of(murmur(e))

# The header
# ----------

def magic(+v: String) -> Bool:
  Bool.and(Bool.and(U32.is_eq(String.code_at(v, 0n), 72), U32.is_eq(String.code_at(v, 1n), 89)), Bool.and(U32.is_eq(String.code_at(v, 2n), 76), U32.is_eq(String.code_at(v, 3n), 76)))

# whether Redis takes v for a HyperLogLog (isHLLObjectOrReply): 16 bytes
# at least, "HYLL", an encoding of 0 or 1, and 12304 bytes when dense
def valid(+v: String) -> Bool:
  +n = String.length(v)
  +e = String.code_at(v, 4n)
  Bool.and(Bool.and(Nat.is_le(16n, n), magic(v)), Bool.and(U32.is_le(e, 1), Bool.or(U32.is_eq(e, 1), Nat.is_eq(n, 12304n))))

def is_sparse(+v: String) -> Bool:
  U32.is_eq(String.code_at(v, 4n), 1)

# a new one (createHLLObject): sparse, one XZERO of 16384 registers
def fresh() -> String:
  "HYLL" ++ b1(1) ++ zeros(11n) ++ b1(127) ++ b1(255)

# v with its cardinality marked as not valid (HLL_INVALIDATE_CACHE)
def stale(+v: String) -> String:
  String.take(v, 15n) ++ b1(U32.or(String.code_at(v, 15n), 128)) ++ String.drop(v, 16n)

def card.ok(+v: String) -> Bool:
  U32.is_lt(String.code_at(v, 15n), 128)

def card.of(+v: String) -> W:
  W{mm.load32(v, 12n), mm.load32(v, 8n)}

# the 8 bytes of c, little-endian
def card.bytes(c: W) -> String:
  match c:
    case W{+hi, +lo}:
      SCon{Chr{U32.and(lo, 255)}, SCon{Chr{U32.and(U32.shrn(lo, 8n), 255)}, SCon{Chr{U32.and(U32.shrn(lo, 16n), 255)}, SCon{Chr{U32.shrn(lo, 24n)}, SCon{Chr{U32.and(hi, 255)}, SCon{Chr{U32.and(U32.shrn(hi, 8n), 255)}, SCon{Chr{U32.and(U32.shrn(hi, 16n), 255)}, SCon{Chr{U32.shrn(hi, 24n)}, SNil{}}}}}}}}}

# Registers in an array
# ---------------------
# 16384 registers (a merge's maxima), or 64 counts (a histogram), as an
# Array of Nats

def ra.put(up: Bool, a: Array<Nat>, +i: U32, +x: Nat) -> Array<Nat>:
  match up:
    case True{}:
      Array.set(Nat, a, i, x)
    case False{}:
      a

def ra.max.of(r: Array<Nat> & Nat, +i: U32, +x: Nat) -> Array<Nat>:
  (a, c) = r
  ra.put(Nat.is_lt(c, x), a, i, x)

# a with a[i] at least x
def ra.max(a: Array<Nat>, +i: U32, +x: Nat) -> Array<Nat>:
  ra.max.of(Array.get(Nat, a, i), i, x)

# a with a[i] to a[i + n - 1] at least x
def ra.maxn(n: Nat, a: Array<Nat>, +i: Nat, +x: Nat) -> Array<Nat>:
  match n:
    case 0n:
      a
    case 1n+p:
      ra.maxn(p, ra.max(a, U32.from_nat(i), x), Nat.add(i, 1n), x)

def hist.addn.of(r: Array<Nat> & Nat, +i: U32, +n: Nat) -> Array<Nat>:
  (a, c) = r
  Array.set(Nat, a, i, Nat.add(c, n))

# a histogram with n more registers of value i
def hist.addn(a: Array<Nat>, +i: U32, +n: Nat) -> Array<Nat>:
  hist.addn.of(Array.get(Nat, a, i), i, n)

def hist.new() -> Array<Nat>:
  Array.new(Nat, 6n, 0n)

def regs.new() -> Array<Nat>:
  Array.new(Nat, 14n, 0n)

# the histogram of the 16384 registers of an array, from register i on
# (k left): r is the array and its register i
def regs.hist(k: Nat, r: Array<Nat> & Nat, +i: Nat, h: Array<Nat>) -> Array<Nat>:
  match k:
    case 0n:
      h
    case 1n+q:
      (a, x) = r
      regs.hist(q, Array.get(Nat, a, U32.from_nat(Nat.min(Nat.add(i, 1n), 16383n))), Nat.add(i, 1n), hist.addn(h, U32.from_nat(x), 1n))

# four registers of an array from i, and the array
type R4 is Type:
  R4{a: Array<Nat>, x0: U32, x1: U32, x2: U32, x3: U32}

def ra.get4.d(r: Array<Nat> & Nat, +x0: U32, +x1: U32, +x2: U32) -> R4:
  (a, x3) = r
  R4{a, x0, x1, x2, U32.from_nat(x3)}

def ra.get4.c(r: Array<Nat> & Nat, +i: U32, +x0: U32, +x1: U32) -> R4:
  (a, x2) = r
  ra.get4.d(Array.get(Nat, a, U32.add(i, 3)), x0, x1, U32.from_nat(x2))

def ra.get4.b(r: Array<Nat> & Nat, +i: U32, +x0: U32) -> R4:
  (a, x1) = r
  ra.get4.c(Array.get(Nat, a, U32.add(i, 2)), i, x0, U32.from_nat(x1))

def ra.get4.a(r: Array<Nat> & Nat, +i: U32) -> R4:
  (a, x0) = r
  ra.get4.b(Array.get(Nat, a, U32.add(i, 1)), i, U32.from_nat(x0))

def ra.get4(a: Array<Nat>, +i: U32) -> R4:
  ra.get4.a(Array.get(Nat, a, i), i)

# Dense
# -----
# four registers in three bytes: x0 = r0 | r1 << 6, x1 = r1 >> 2 | r2 <<
# 4, x2 = r2 >> 4 | r3 << 2

def d.r0(+x0: U32) -> U32:
  U32.and(x0, 63)

def d.r1(+x0: U32, +x1: U32) -> U32:
  U32.and(U32.or(U32.shrn(x0, 6n), U32.shln(x1, 2n)), 63)

def d.r2(+x1: U32, +x2: U32) -> U32:
  U32.and(U32.or(U32.shrn(x1, 4n), U32.shln(x2, 4n)), 63)

def d.r3(+x2: U32) -> U32:
  U32.and(U32.shrn(x2, 2n), 63)

# register r of a dense v (HLL_DENSE_GET_REGISTER)
def d.get(+v: String, +r: Nat) -> Nat:
  +bit = Nat.mul(r, 6n)
  +b = Nat.add(16n, Nat.div(bit, 8n))
  +fb = Nat.mod(bit, 8n)
  U32.to_nat(U32.and(U32.or(U32.shrn(hb(v, 12304n, b), fb), U32.shln(hb(v, 12304n, Nat.add(b, 1n)), Nat.sub(8n, fb))), 63))

def d.set.of(one: Bool, +v: String, +b: Nat, +fb: Nat, +y0: U32, +x: U32) -> String:
  match one:
    case True{}:
      String.take(v, b) ++ b1(y0) ++ String.drop(v, Nat.add(b, 1n))
    case False{}:
      +y1 = U32.or(U32.and(String.code_at(v, Nat.add(b, 1n)), U32.not(U32.shrn(63, Nat.sub(8n, fb)))), U32.shrn(x, Nat.sub(8n, fb)))
      String.take(v, b) ++ b1(y0) ++ b1(y1) ++ String.drop(v, Nat.add(b, 2n))

# v with register r set to x (HLL_DENSE_SET_REGISTER): its second byte
# changes only when the register reaches into it
def d.set(+v: String, +r: Nat, +x: U32) -> String:
  +bit = Nat.mul(r, 6n)
  +b = Nat.add(16n, Nat.div(bit, 8n))
  +fb = Nat.mod(bit, 8n)
  d.set.of(Nat.is_le(fb, 2n), v, b, fb, U32.and(U32.or(U32.and(String.code_at(v, b), U32.not(U32.shln(63, fb))), U32.shln(x, fb)), 255), x)

# the histogram of the registers in s, the bytes of k blocks
def d.hist.go(k: Nat, +s: String, h: Array<Nat>) -> Array<Nat>:
  match k:
    case 0n:
      h
    case 1n+q:
      match s:
        case SCon{Chr{+x0}, SCon{Chr{+x1}, SCon{Chr{+x2}, r}}}:
          d.hist.go(q, r, hist.addn(hist.addn(hist.addn(hist.addn(h, d.r0(x0), 1n), d.r1(x0, x1), 1n), d.r2(x1, x2), 1n), d.r3(x2), 1n))
        case _:
          h

# the histogram of a dense v's registers (hllDenseRegHisto)
def d.hist(+v: String) -> Array<Nat>:
  d.hist.go(4096n, String.drop(v, 16n), hist.new())

# a with each register at least the dense one in s (k blocks, from
# register i)
def d.merge.go(k: Nat, +s: String, +i: Nat, a: Array<Nat>) -> Array<Nat>:
  match k:
    case 0n:
      a
    case 1n+q:
      match s:
        case SCon{Chr{+x0}, SCon{Chr{+x1}, SCon{Chr{+x2}, r}}}:
          +j = U32.from_nat(i)
          d.merge.go(q, r, Nat.add(i, 4n), ra.max(ra.max(ra.max(ra.max(a, j, U32.to_nat(d.r0(x0))), U32.add(j, 1), U32.to_nat(d.r1(x0, x1))), U32.add(j, 2), U32.to_nat(d.r2(x1, x2))), U32.add(j, 3), U32.to_nat(d.r3(x2))))
        case _:
          a

# a merged with a dense v (hllMerge)
def d.merge(+v: String, a: Array<Nat>) -> Array<Nat>:
  d.merge.go(4096n, String.drop(v, 16n), 0n, a)

# the 16384 registers of an array as the dense bytes: block k - 1 (its
# registers r) and those before it, before acc
def d.enc.go(k: Nat, r: R4, acc: String) -> String:
  match k:
    case 0n:
      acc
    case 1n++q:
      match r:
        case R4{a, +x0, +x1, +x2, +x3}:
          d.enc.go(q, ra.get4(a, U32.from_nat(Nat.mul(Nat.sub(q, 1n), 4n))), SCon{Chr{U32.and(U32.or(x0, U32.shln(x1, 6n)), 255)}, SCon{Chr{U32.and(U32.or(U32.shrn(x1, 2n), U32.shln(x2, 4n)), 255)}, SCon{Chr{U32.and(U32.or(U32.shrn(x2, 4n), U32.shln(x3, 2n)), 255)}, acc}}})

def d.enc(a: Array<Nat>) -> String:
  d.enc.go(4096n, ra.get4(a, 16380), "")

# the registers of s (k blocks), in order
def d.regs.go(k: Nat, +s: String) -> List<&2, Nat>:
  match k:
    case 0n:
      Nil{}
    case 1n+q:
      match s:
        case SCon{Chr{+x0}, SCon{Chr{+x1}, SCon{Chr{+x2}, r}}}:
          U32.to_nat(d.r0(x0)) <> U32.to_nat(d.r1(x0, x1)) <> U32.to_nat(d.r2(x1, x2)) <> U32.to_nat(d.r3(x2)) <> d.regs.go(q, r)
        case _:
          Nil{}

# a dense v's 16384 registers (PFDEBUG GETREG)
def d.regs(+v: String) -> List<&2, Nat>:
  d.regs.go(4096n, String.drop(v, 16n))

# Sparse
# ------
# An opcode is a VAL when its top bit is set, else an XZERO when the next
# is, else a ZERO.

def zlen(+c: U32) -> Nat:
  Nat.add(U32.to_nat(U32.and(c, 63)), 1n)

def xlen(+c: U32, +lo: U32) -> Nat:
  Nat.add(Nat.add(Nat.mul(U32.to_nat(U32.and(c, 63)), 256n), U32.to_nat(lo)), 1n)

def vval(+c: U32) -> Nat:
  Nat.add(U32.to_nat(U32.and(U32.shrn(c, 2n), 31)), 1n)

def vlen(+c: U32) -> Nat:
  Nat.add(U32.to_nat(U32.and(c, 3)), 1n)

# the opcodes, as bytes
def vset(+v: Nat, +len: Nat) -> U32:
  U32.or(U32.from_nat(Nat.add(Nat.mul(Nat.sub(v, 1n), 4n), Nat.sub(len, 1n))), 128)

def xset(+len: Nat) -> String:
  +l = Nat.sub(len, 1n)
  b1(U32.or(U32.from_nat(Nat.div(l, 256n)), 64)) ++ b1(U32.from_nat(Nat.mod(l, 256n)))

# a run of len zero registers: a ZERO, or an XZERO past 64
def zrun(+len: Nat) -> String:
  Bool.pick(String, Nat.is_lt(64n, len), xset(len), b1(U32.from_nat(Nat.sub(len, 1n))))

# the opcode at the head of s, as Redis reads it: whether there is one
# (more), whether it is an XZERO (two bytes: the second of an XZERO cut
# at the end is the byte past the end, pe), its bytes, the registers it
# holds and their value (0 for a run of zeros)
type Op is Data:
  Op{more: Bool, x: Bool, c: U32, lo: U32, len: Nat, val: Nat}

# byte 1 of s, or the byte past the end (a code past 255 is not a byte)
def op.lo(+s: String, +pe: U32) -> U32:
  +b = String.code_at(s, 1n)
  Bool.pick(U32, U32.is_lt(b, 256), b, pe)

def op.at(+s: String, +pe: U32) -> Op:
  +c0 = String.code_at(s, 0n)
  +more = U32.is_lt(c0, 256)
  +c = Bool.pick(U32, more, c0, 0)
  +isval = U32.is_ne(U32.and(c, 128), 0)
  +x = Bool.and(Bool.not(isval), U32.is_ne(U32.and(c, 64), 0))
  +lo = Bool.pick(U32, x, op.lo(s, pe), 0)
  Op{more, x, c, lo, Bool.pick(Nat, isval, vlen(c), Bool.pick(Nat, x, xlen(c, lo), zlen(c))), Bool.pick(Nat, isval, vval(c), 0n)}

def op.len(+o: Op) -> Nat:
  match o:
    case Op{more, x, c, lo, +len, val}:
      len

def op.more(+o: Op) -> Bool:
  match o:
    case Op{+more, x, c, lo, len, val}:
      more

# The walks of the opcodes s (the bytes after the header), o the one at
# its head. The histogram and DECODE walk a value as a command finds it,
# the byte past its end 0; the merge walks it as the sets before it in a
# command left it (pe).

# the histogram of the registers, and how many the opcodes hold
# (hllSparseRegHisto)
def sp.hist(k: Nat, o: Op, +s: String, +idx: Nat, h: Array<Nat>) -> Array<Nat> & Nat:
  match k:
    case 0n:
      (h, idx)
    case 1n+k1:
      match o:
        case Op{more, x, c, lo, +len, +val}:
          match more:
            case False{}:
              (h, idx)
            case True{}:
              match x:
                case True{}:
                  match s:
                    case SCon{a, SCon{b, r}}:
                      sp.hist(k1, op.at(r, 0), r, Nat.add(idx, len), hist.addn(h, 0, len))
                    case _:
                      (hist.addn(h, 0, len), Nat.add(idx, len))
                case False{}:
                  match s:
                    case SCon{a, r}:
                      sp.hist(k1, op.at(r, 0), r, Nat.add(idx, len), hist.addn(h, U32.from_nat(val), len))
                    case SNil{}:
                      (h, idx)

# a with each register at least the one the opcodes hold (hllMerge; and
# hllSparseToDense, on an array of zeros): an opcode that would pass the
# last register ends the walk, and makes them invalid, as the fix of
# CVE-2025-32023 has it (Redis 7.0.15 as Ubuntu ships it, which the
# tests compare with; before it, the zeros ran on, and a VAL past the
# last register ended the walk where the opcodes were valid if it ended
# at 16384); else they are valid if it ends at 16384
def sp.merge(k: Nat, o: Op, +s: String, +i: Nat, a: Array<Nat>, +pe: U32) -> Array<Nat> & Bool:
  match k:
    case 0n:
      (a, Nat.is_eq(i, 16384n))
    case 1n+k1:
      match o:
        case Op{more, x, c, lo, +len, +val}:
          match more:
            case False{}:
              (a, Nat.is_eq(i, 16384n))
            case True{}:
              match x:
                case True{}:
                  match s:
                    case SCon{p0, SCon{p1, r}}:
                      sp.merge(k1, op.at(r, pe), r, Nat.add(i, len), a, pe)
                    case _:
                      (a, Nat.is_eq(Nat.add(i, len), 16384n))
                case False{}:
                  match s:
                    case SCon{p0, r}:
                      +over = Nat.is_lt(16384n, Nat.add(i, len))
                      sp.merge(k1, Bool.pick(Op, over, Op{False{}, False{}, 0, 0, 0n, 0n}, op.at(r, pe)), r, Nat.add(i, len), ra.maxn(Bool.pick(Nat, Bool.or(over, Nat.is_eq(val, 0n)), 0n, len), a, i, val), pe)
                    case SNil{}:
                      (a, Nat.is_eq(i, 16384n))

def sp.dense.of(r: Array<Nat> & Bool, +v: String) -> Maybe<&2, String>:
  (a, ok) = r
  match ok:
    case True{}:
      Some{String.take(v, 4n) ++ b1(0) ++ String.slice(v, 5n, 11n) ++ d.enc(a)}
    case False{}:
      None{}

# a sparse v made dense (hllSparseToDense): its header, the encoding 0,
# then its registers; none when its opcodes do not hold 16384 (pe: the
# byte past its end)
def sp.dense(+v: String, +pe: U32) -> Maybe<&2, String>:
  +s = String.drop(v, 16n)
  sp.dense.of(sp.merge(Nat.add(String.length(s), 1n), op.at(s, pe), s, 0n, regs.new(), pe), v)

# PFDEBUG DECODE: each opcode as "z:len", "Z:len" or "v:value,len"
def sp.dec(k: Nat, o: Op, +s: String) -> String:
  match k:
    case 0n:
      ""
    case 1n+k1:
      match o:
        case Op{more, x, c, lo, +len, +val}:
          match more:
            case False{}:
              ""
            case True{}:
              match x:
                case True{}:
                  match s:
                    case SCon{a, SCon{b, r}}:
                      "Z:" ++ Nat.show(len) ++ " " ++ sp.dec(k1, op.at(r, 0), r)
                    case _:
                      "Z:" ++ Nat.show(len) ++ " "
                case False{}:
                  match s:
                    case SCon{a, r}:
                      Bool.pick(String, Nat.is_eq(val, 0n), "z:" ++ Nat.show(len), "v:" ++ Nat.show(val) ++ "," ++ Nat.show(len)) ++ " " ++ sp.dec(k1, op.at(r, 0), r)
                    case SNil{}:
                      ""

def sp.decode.of(+t: String) -> String:
  String.take(t, Nat.sub(String.length(t), 1n))

def sp.decode(+v: String) -> String:
  +s = String.drop(v, 16n)
  sp.decode.of(sp.dec(Nat.add(String.length(s), 1n), op.at(s, 0), s))

# Setting a register of a sparse HLL (hllSparseSet)
# --------------------------------------------------
# The walk finds the opcode that holds the register: where it starts
# (p), the first register it holds, the opcode before it (q, 0 for none)
# and the one before that (o, of first register f), from which a walk to
# a register further on may start again: a set changes nothing before q.
# c is the opcode's byte, lo the next one.
type At is Data:
  ANone{}
  At{p: Nat, first: Nat, q: Nat, o: Nat, f: Nat, c: U32, lo: U32}

# here: whether o, the opcode at p, holds idx
def sp.find(k: Nat, here: Bool, o: Op, +s: String, +p: Nat, +first: Nat, +q: Nat, +qf: Nat, +po: Nat, +pf: Nat, +idx: Nat, +pe: U32) -> At:
  match k:
    case 0n:
      ANone{}
    case 1n+k1:
      match here:
        case True{}:
          match o:
            case Op{more, x, +c, +lo, len, val}:
              At{p, first, q, po, pf, c, lo}
        case False{}:
          match o:
            case Op{more, x, c, lo, +len, val}:
              match more:
                case False{}:
                  ANone{}
                case True{}:
                  match x:
                    case True{}:
                      match s:
                        case SCon{a, SCon{b, r}}:
                          +o2 = op.at(r, pe)
                          +f2 = Nat.add(first, len)
                          sp.find(k1, Bool.and(op.more(o2), Nat.is_lt(idx, Nat.add(f2, op.len(o2)))), o2, r, Nat.add(p, 2n), f2, p, first, q, qf, idx, pe)
                        case _:
                          ANone{}
                    case False{}:
                      match s:
                        case SCon{a, r}:
                          +o2 = op.at(r, pe)
                          +f2 = Nat.add(first, len)
                          sp.find(k1, Bool.and(op.more(o2), Nat.is_lt(idx, Nat.add(f2, op.len(o2)))), o2, r, Nat.add(p, 1n), f2, p, first, q, qf, idx, pe)
                        case SNil{}:
                          ANone{}

# What a set did: nothing, as the opcodes do not hold the register (-1);
# nothing, as it holds as much already (0); the new opcodes (1), n bytes
# long, where a walk to a further register may start (o, of first
# register f), and the byte past their end; or nothing yet, as the HLL
# must turn dense first.
type SpSet is Data:
  SBad{}
  SSame{o: Nat, f: Nat}
  SNew{v: String, n: Nat, o: Nat, f: Nat, pe: U32}
  SProm{}

# Step 4's look at p: whether p is in the string, whether the VALs at p
# and p + 1 merge (of the same value, their lengths in one), into y, and
# how far the next opcode is
type Mg is Data:
  Mg{more: Bool, join: Bool, y: U32, step: Nat}

def mg.at(+v: String, +n: Nat, +p: Nat) -> Mg:
  +c = hb(v, n, p)
  +d = hb(v, n, Nat.add(p, 1n))
  +isval = U32.is_ne(U32.and(c, 128), 0)
  +two = Bool.and(Bool.and(isval, Nat.is_lt(Nat.add(p, 1n), n)), U32.is_ne(U32.and(d, 128), 0))
  +len = Nat.add(vlen(c), vlen(d))
  Mg{Nat.is_lt(p, n), Bool.and(Bool.and(two, Nat.is_eq(vval(c), vval(d))), Nat.is_le(len, 4n)), vset(vval(c), len), Bool.pick(Nat, Bool.and(Bool.not(isval), U32.is_ne(U32.and(c, 64), 0)), 2n, 1n)}

# Step 4: adjacent VALs of the same value merged, while their length
# fits, five opcodes at most from p (the opcode before the one set, or
# the first)
def sp.mg(k: Nat, m: Mg, +v: String, +n: Nat, +p: Nat) -> String & Nat:
  match k:
    case 0n:
      (v, n)
    case 1n+s:
      match m:
        case Mg{more, join, +y, +step}:
          match more:
            case False{}:
              (v, n)
            case True{}:
              match join:
                case True{}:
                  +w = String.take(v, p) ++ b1(y) ++ String.drop(v, Nat.add(p, 2n))
                  +n1 = Nat.sub(n, 1n)
                  sp.mg(s, mg.at(w, n1, p), w, n1, p)
                case False{}:
                  +p1 = Nat.add(p, step)
                  sp.mg(s, mg.at(v, n, p1), v, n, p1)

# a merge moves the string's end down a byte and writes its NUL there
# (sdsIncrLen): the byte past the end is 0 after one
def sp.updated.fin(v: String, +n: Nat, +o: Nat, +f: Nat, +n0: Nat, +pe: U32) -> SpSet:
  SNew{v, n, o, f, Bool.pick(U32, Nat.is_lt(n, n0), 0, pe)}

def sp.updated.of(r: String & Nat, +o: Nat, +f: Nat, +n0: Nat, +pe: U32) -> SpSet:
  (v, n) = r
  sp.updated.fin(v, n, o, f, n0, pe)

# the opcodes v (n bytes, pe past them) changed at the opcode after q:
# merged from q, or from the first
def sp.updated(+v: String, +n: Nat, +q: Nat, +o: Nat, +f: Nat, +pe: U32) -> SpSet:
  +p = Bool.pick(Nat, Nat.is_eq(q, 0n), 16n, q)
  sp.updated.of(sp.mg(5n, mg.at(v, n, p), v, n, p), o, f, n, pe)

def sp.put.cut(cut: Bool, w: String, +m: Nat) -> String:
  match cut:
    case True{}:
      String.take(w, m)
    case False{}:
      w

# Step 3: the opcode at p (old bytes long) replaced with seq, and the
# string's NUL written at its new end (sdsIncrLen). An XZERO cut at the
# end has one byte only: the new string is as many bytes fewer, and seq's
# last byte is written past its end, over the NUL (memcpy).
def sp.put.go(+v: String, +n: Nat, +p: Nat, +old: Nat, +seq: String, +m: Nat, +q: Nat, +o: Nat, +f: Nat) -> SpSet:
  +cut = Nat.is_lt(n, Nat.add(p, old))
  sp.updated(sp.put.cut(cut, String.take(v, p) ++ seq ++ String.drop(v, Nat.add(p, old)), m), m, q, o, f, Bool.pick(U32, cut, String.code_at(seq, Nat.sub(String.length(seq), 1n)), 0))

# unless it grows the string past mx bytes
def sp.put(prom: Bool, +v: String, +n: Nat, +p: Nat, +old: Nat, +seq: String, +q: Nat, +o: Nat, +f: Nat) -> SpSet:
  match prom:
    case True{}:
      SProm{}
    case False{}:
      sp.put.go(v, n, p, old, seq, Nat.sub(Nat.add(n, String.length(seq)), old), q, o, f)

def sp.split(+v: String, +n: Nat, +mx: Nat, +p: Nat, +old: Nat, +seq: String, +q: Nat, +o: Nat, +f: Nat) -> SpSet:
  +sl = String.length(seq)
  sp.put(Bool.and(Nat.is_lt(old, sl), Nat.is_lt(mx, Nat.sub(Nat.add(n, sl), old))), v, n, p, old, seq, q, o, f)

# Step 2: the opcode split around the register, the registers before it
# and after it in runs of the opcode's kind (zero: zeros; else VALs of
# value cur)
def sp.side(zero: Bool, +cur: Nat, +len: Nat) -> String:
  match zero:
    case True{}:
      zrun(len)
    case False{}:
      b1(vset(cur, len))

def sp.seq(+zero: Bool, +cur: Nat, +first: Nat, +last: Nat, +idx: Nat, +cnt: Nat) -> String:
  Bool.pick(String, Nat.is_eq(idx, first), "", sp.side(zero, cur, Nat.sub(idx, first))) ++ b1(vset(cnt, 1n)) ++ Bool.pick(String, Nat.is_eq(idx, last), "", sp.side(zero, cur, Nat.sub(last, idx)))

# the opcode at p written over with y, the byte past the end as it was
def sp.over(+v: String, +n: Nat, +p: Nat, +y: U32, +q: Nat, +o: Nat, +f: Nat, +pe: U32) -> SpSet:
  sp.updated(String.take(v, p) ++ b1(y) ++ String.drop(v, Nat.add(p, 1n)), n, q, o, f, pe)

def sp.set.val(same: Bool, one: Bool, +v: String, +n: Nat, +mx: Nat, +idx: Nat, +cnt: Nat, +p: Nat, +first: Nat, +q: Nat, +o: Nat, +f: Nat, +c: U32, +pe: U32) -> SpSet:
  match same:
    case True{}:
      SSame{o, f}
    case False{}:
      match one:
        case True{}:
          sp.over(v, n, p, vset(cnt, 1n), q, o, f, pe)
        case False{}:
          sp.split(v, n, mx, p, 1n, sp.seq(False{}, vval(c), first, Nat.sub(Nat.add(first, vlen(c)), 1n), idx, cnt), q, o, f)

def sp.set.zero(one: Bool, +v: String, +n: Nat, +mx: Nat, +idx: Nat, +cnt: Nat, +p: Nat, +first: Nat, +q: Nat, +o: Nat, +f: Nat, +len: Nat, +old: Nat, +pe: U32) -> SpSet:
  match one:
    case True{}:
      sp.over(v, n, p, vset(cnt, 1n), q, o, f, pe)
    case False{}:
      sp.split(v, n, mx, p, old, sp.seq(True{}, 0n, first, Nat.sub(Nat.add(first, len), 1n), idx, cnt), q, o, f)

def sp.set.op(val: Bool, x: Bool, +v: String, +n: Nat, +mx: Nat, +idx: Nat, +cnt: Nat, +p: Nat, +first: Nat, +q: Nat, +o: Nat, +f: Nat, +c: U32, +lo: U32, +pe: U32) -> SpSet:
  match val:
    case True{}:
      sp.set.val(Nat.is_le(cnt, vval(c)), Nat.is_eq(vlen(c), 1n), v, n, mx, idx, cnt, p, first, q, o, f, c, pe)
    case False{}:
      match x:
        case False{}:
          sp.set.zero(Nat.is_eq(zlen(c), 1n), v, n, mx, idx, cnt, p, first, q, o, f, zlen(c), 1n, pe)
        case True{}:
          sp.set.zero(False{}, v, n, mx, idx, cnt, p, first, q, o, f, xlen(c, lo), 2n, pe)

def sp.set.at(a: At, +v: String, +n: Nat, +mx: Nat, +idx: Nat, +cnt: Nat, +pe: U32) -> SpSet:
  match a:
    case ANone{}:
      SBad{}
    case At{+p, +first, +q, +o, +f, +c, +lo}:
      sp.set.op(U32.is_ne(U32.and(c, 128), 0), U32.is_ne(U32.and(c, 64), 0), v, n, mx, idx, cnt, p, first, q, o, f, c, lo, pe)

def sp.set.go(big: Bool, +v: String, +n: Nat, +mx: Nat, +idx: Nat, +cnt: Nat, +p0: Nat, +f0: Nat, +pe: U32) -> SpSet:
  match big:
    case True{}:
      SProm{}
    case False{}:
      +s = String.drop(v, p0)
      +o = op.at(s, pe)
      sp.set.at(sp.find(Nat.add(Nat.sub(n, p0), 1n), Bool.and(op.more(o), Nat.is_lt(idx, Nat.add(f0, op.len(o)))), o, s, p0, f0, 0n, 0n, 0n, 0n, idx, pe), v, n, mx, idx, cnt, pe)

# register idx of a sparse v (n bytes, pe the byte past its end) set to
# cnt if that is more, its opcodes walked from p0 (holding register f0
# first: 16 and 0 from the start), and mx the bytes it may grow to
# (hll-sparse-max-bytes): a count past 32, or a string past mx, makes it
# dense
def sp.set(+v: String, +n: Nat, +mx: Nat, +idx: Nat, +cnt: Nat, +p0: Nat, +f0: Nat, +pe: U32) -> SpSet:
  sp.set.go(Nat.is_lt(32n, cnt), v, n, mx, idx, cnt, p0, f0, pe)

# Counting
# --------

def fl.d() -> F.Fmt:
  F.fmt.d()

# the double of n (below 2^48)
def fl.num(+n: Nat) -> F.Fl:
  F.fl.round(F.fmt.d(), False{}, F.big.of(n), F.fl.eb(), False{})

def fl.half() -> F.Fl:
  F.fl.round(F.fmt.d(), False{}, [1n], Nat.sub(F.fl.eb(), 1n), False{})

def fl.neg(a: F.Fl) -> F.Fl:
  match a:
    case F.FNum{n, m, e}:
      F.FNum{Bool.not(n), m, e}
    case F.FInf{n}:
      F.FInf{Bool.not(n)}
    case F.FNaN{}:
      F.FNaN{}

def cmp.eq(c: Cmp) -> Bool:
  match c:
    case EQ{}:
      True{}
    case LT{}:
      False{}
    case GT{}:
      False{}

# whether two doubles are equal, as C's == compares them (a result is
# rounded the one way, F.fl.round: its m and e say which double it is)
def fl.eq(+a: F.Fl, +b: F.Fl) -> Bool:
  match a b:
    case F.FNum{+na, +ma, +ea} F.FNum{+nb, +mb, +eb}:
      Bool.or(Bool.and(F.big.is_zero(ma), F.big.is_zero(mb)), Bool.and(Bool.and(Bool.not(Bool.xor(na, nb)), Nat.is_eq(ea, eb)), cmp.eq(F.big.cmp(ma, mb))))
    case F.FInf{+na} F.FInf{+nb}:
      Bool.not(Bool.xor(na, nb))
    case _ _:
      False{}

def fl.is0(+a: F.Fl) -> Bool:
  match a:
    case F.FNum{n, +m, e}:
      F.big.is_zero(m)
    case _:
      False{}

# hllSigma (Ertl's sigma): z = x, then x squared, z + x * y, y doubled,
# until z stops changing (same)
def sigma.go(fuel: Nat, same: Bool, +x: F.Fl, +y: F.Fl, +z: F.Fl) -> F.Fl:
  match fuel:
    case 0n:
      z
    case 1n+f:
      match same:
        case True{}:
          z
        case False{}:
          +x2 = F.fl.mul(fl.d(), x, x)
          +z2 = F.fl.add(fl.d(), z, F.fl.mul(fl.d(), x2, y))
          sigma.go(f, fl.eq(z, z2), x2, F.fl.add(fl.d(), y, y), z2)

def sigma.of(one: Bool, +x: F.Fl) -> F.Fl:
  match one:
    case True{}:
      F.FInf{False{}}
    case False{}:
      sigma.go(4096n, False{}, x, fl.num(1n), x)

def sigma(+x: F.Fl) -> F.Fl:
  sigma.of(fl.eq(x, fl.num(1n)), x)

# hllTau (Ertl's tau): z = 1 - x, then x its root, y halved, z - (1 - x)^2
# * y, until z stops changing; z / 3. pow(1 - x, 2) is the product,
# rounded once, as glibc's pow gives it but for a result within a sliver
# of a tie between two doubles.
def tau.go(fuel: Nat, same: Bool, +x: F.Fl, +y: F.Fl, +z: F.Fl) -> F.Fl:
  match fuel:
    case 0n:
      z
    case 1n+f:
      match same:
        case True{}:
          z
        case False{}:
          +x2 = F.fl.sqrt(fl.d(), x)
          +y2 = F.fl.mul(fl.d(), y, fl.half())
          +u = F.fl.add(fl.d(), fl.num(1n), fl.neg(x2))
          +z2 = F.fl.add(fl.d(), z, fl.neg(F.fl.mul(fl.d(), F.fl.mul(fl.d(), u, u), y2)))
          tau.go(f, fl.eq(z, z2), x2, y2, z2)

def tau.of(none: Bool, +x: F.Fl) -> F.Fl:
  match none:
    case True{}:
      F.fl.zero(False{})
    case False{}:
      F.fl.div(fl.d(), tau.go(4096n, False{}, x, fl.num(1n), F.fl.add(fl.d(), fl.num(1n), fl.neg(x))), fl.num(3n))

def tau(+x: F.Fl) -> F.Fl:
  tau.of(Bool.or(fl.is0(x), fl.eq(x, fl.num(1n))), x)

# z after the registers of values j down to 1: z + count, halved, each
# (r: the histogram and the count of value j)
def est.loop(j: Nat, r: Array<Nat> & Nat, +z: F.Fl) -> F.Fl:
  match j:
    case 0n:
      z
    case 1n++i:
      (h, c) = r
      est.loop(i, Array.get(Nat, h, U32.from_nat(i)), F.fl.mul(fl.d(), F.fl.add(fl.d(), z, fl.num(c)), fl.half()))

# HLL_ALPHA_INF * m * m: 0.721347520444481703680 (as a double) * 2^28
def est.alpha() -> F.Fl:
  F.FNum{False{}, [2851582n, 1394533n, 23n], Nat.sub(F.fl.eb(), 25n)}

# the limbs of 24 bits of a number below 2^64 as a word
def w.of.limbs(xs: List<&2, Nat>) -> W:
  match xs:
    case Nil{}:
      W{0, 0}
    case Con{+l0, Nil{}}:
      W{0, U32.from_nat(l0)}
    case Con{+l0, Con{+l1, Nil{}}}:
      W{U32.from_nat(Nat.div(l1, 256n)), U32.from_nat(Nat.add(l0, Nat.mul(Nat.mod(l1, 256n), 16777216n)))}
    case Con{+l0, Con{+l1, Con{+l2, rest}}}:
      W{U32.from_nat(Nat.add(Nat.div(l1, 256n), Nat.mul(l2, 65536n))), U32.from_nat(Nat.add(l0, Nat.mul(Nat.mod(l1, 256n), 16777216n)))}

def llround.fit(+r: List<&2, Nat>) -> W:
  Bool.pick(W, Nat.is_lt(63n, F.big.bitlen(r)), W{2147483648, 0}, w.of.limbs(r))

def llround.frac(+m: List<&2, Nat>, +s: Nat) -> W:
  +i = F.big.shr(m, s)
  llround.fit(Bool.pick(List<&2, Nat>, F.big.bit(m, Nat.sub(s, 1n)), F.big.add(i, [1n]), i))

def llround.int(big: Bool, +m: List<&2, Nat>, +sh: Nat) -> W:
  match big:
    case True{}:
      W{2147483648, 0}
    case False{}:
      w.of.limbs(F.big.shl(m, sh))

def llround.num(int: Bool, +m: List<&2, Nat>, +e: Nat) -> W:
  match int:
    case True{}:
      +sh = Nat.sub(e, F.fl.eb())
      llround.int(Nat.is_lt(63n, Nat.add(F.big.bitlen(m), sh)), m, sh)
    case False{}:
      llround.frac(m, Nat.sub(F.fl.eb(), e))

# llroundl(q) as hllCount keeps it, a uint64_t: q rounded half away from
# 0, and 2^63 (LLONG_MIN, from x87's conversion) for one past what a long
# long holds, or no number
def llround(q: F.Fl) -> W:
  match q:
    case F.FNum{n, +m, +e}:
      llround.num(Nat.is_le(F.fl.eb(), e), m, e)
    case _:
      W{2147483648, 0}

def est.of(r: Array<Nat> & Nat, +r51: Nat) -> W:
  (h, r0) = r
  +m = fl.num(16384n)
  +z1 = est.loop(50n, Array.get(Nat, h, 50), F.fl.mul(fl.d(), m, tau(F.fl.div(fl.d(), fl.num(Nat.sub(16384n, r51)), m))))
  +z = F.fl.add(fl.d(), z1, F.fl.mul(fl.d(), m, sigma(F.fl.div(fl.d(), fl.num(r0), m))))
  llround(F.fl.div(fl.d(), est.alpha(), z))

def est.at(r: Array<Nat> & Nat) -> W:
  (h, r51) = r
  est.of(Array.get(Nat, h, 0), r51)

# the cardinality a histogram h of the registers gives (hllCount), as
# Ertl's new estimator takes it
def est(h: Array<Nat>) -> W:
  est.at(Array.get(Nat, h, 51))

# PFADD
# -----
# a PFADD's state: the value, sparse (n bytes, pe the byte past its end)
# or dense, and whether a register changed; or the value as a walk of
# its opcodes found them invalid, which stops the PFADD
type Add is Data:
  AddS{v: String, n: Nat, ch: Bool, pe: U32}
  AddD{v: String, ch: Bool}
  AddBad{v: String, ch: Bool}

def add.prom(m: Maybe<&2, String>, +v: String, +idx: Nat, +cnt: Nat, ch: Bool) -> Add:
  match m:
    case None{}:
      AddBad{v, ch}
    case Some{+w}:
      AddD{d.set(w, idx, U32.from_nat(cnt)), True{}}

def add.set(r: SpSet, +v: String, +n: Nat, +idx: Nat, +cnt: Nat, ch: Bool, +pe: U32) -> Add:
  match r:
    case SBad{}:
      AddBad{v, ch}
    case SSame{o, f}:
      AddS{v, n, ch, pe}
    case SNew{w, m, o, f, pe2}:
      AddS{w, m, True{}, pe2}
    case SProm{}:
      add.prom(sp.dense(v, pe), v, idx, cnt, ch)

def add.s(p: Pat, +v: String, +n: Nat, +mx: Nat, ch: Bool, +pe: U32) -> Add:
  match p:
    case Pat{+idx, +cnt}:
      add.set(sp.set(v, n, mx, idx, cnt, 16n, 0n, pe), v, n, idx, cnt, ch, pe)

def add.dense(up: Bool, +v: String, +idx: Nat, +cnt: Nat, ch: Bool) -> Add:
  match up:
    case True{}:
      AddD{d.set(v, idx, U32.from_nat(cnt)), True{}}
    case False{}:
      AddD{v, ch}

def add.d(p: Pat, +v: String, ch: Bool) -> Add:
  match p:
    case Pat{+idx, +cnt}:
      add.dense(Nat.is_lt(d.get(v, idx), cnt), v, idx, cnt, ch)

# an element added (hllSparseAdd, hllDenseAdd)
def add.one(st: Add, +mx: Nat, +e: String) -> Add:
  match st:
    case AddS{+v, +n, ch, +pe}:
      add.s(pat(e), v, n, mx, ch, pe)
    case AddD{+v, ch}:
      add.d(pat(e), v, ch)
    case AddBad{v, ch}:
      AddBad{v, ch}

def add.all(es: List<&2, String>, +mx: Nat, st: Add) -> Add:
  match es:
    case Nil{}:
      st
    case Con{+e, rest}:
      add.all(rest, mx, add.one(st, mx, e))

def add.start(sparse: Bool, +v: String) -> Add:
  match sparse:
    case True{}:
      AddS{v, String.length(v), False{}, 0}
    case False{}:
      AddD{v, False{}}

# what a PFADD did: the value, changed or not (an HLL made counts as
# changed), and a changed one with its cardinality marked as not valid;
# or the value as an invalid walk stopped it, changed by the elements
# before (hllSparseSet marks each change)
type AddOut is Data:
  AddDone{ch: Bool, v: String}
  AddErr{ch: Bool, v: String}

def add.done(ch: Bool, +v: String) -> AddOut:
  match ch:
    case True{}:
      AddDone{True{}, stale(v)}
    case False{}:
      AddDone{False{}, v}

def add.err(ch: Bool, +v: String) -> AddOut:
  match ch:
    case True{}:
      AddErr{True{}, stale(v)}
    case False{}:
      AddErr{False{}, v}

def add.fin(st: Add, made: Bool) -> AddOut:
  match st:
    case AddS{+v, n, ch, pe}:
      add.done(Bool.or(ch, made), v)
    case AddD{+v, ch}:
      add.done(Bool.or(ch, made), v)
    case AddBad{+v, ch}:
      add.err(ch, v)

# PFADD of es to a valid v (made: one PFADD made), mx the bytes a sparse
# one may grow to
def add(made: Bool, +v: String, +mx: Nat, es: List<&2, String>) -> AddOut:
  add.fin(add.all(es, mx, add.start(is_sparse(v), v)), made)

# PFCOUNT
# -------
# the cardinality of a valid v: the one kept (valid), or counted, which
# PFCOUNT keeps; or none, as the opcodes of a sparse one do not hold
# 16384 registers
type Count is Data:
  CntBad{}
  CntKept{c: W}
  CntNew{c: W}

def count.sp.of(ok: Bool, h: Array<Nat>) -> Count:
  match ok:
    case True{}:
      CntNew{est(h)}
    case False{}:
      CntBad{}

def count.sp(r: Array<Nat> & Nat) -> Count:
  (h, idx) = r
  count.sp.of(Nat.is_eq(idx, 16384n), h)

def count.new(sparse: Bool, +v: String) -> Count:
  match sparse:
    case True{}:
      +s = String.drop(v, 16n)
      count.sp(sp.hist(Nat.add(String.length(s), 1n), op.at(s, 0), s, 0n, hist.new()))
    case False{}:
      CntNew{est(d.hist(v))}

def count.of(ok: Bool, +v: String) -> Count:
  match ok:
    case True{}:
      CntKept{card.of(v)}
    case False{}:
      count.new(is_sparse(v), v)

def count(+v: String) -> Count:
  count.of(card.ok(v), v)

# The registers of several (PFCOUNT of several keys, PFMERGE)
# ----------------------------------------------------------
# the maxima of the registers so far, and whether one of the HLLs was
# dense; or an invalid sparse one came (hllMerge)
type Acc is Type:
  Acc{a: Array<Nat>, dense: Bool}
  AccBad{}

def acc.new() -> Acc:
  Acc{regs.new(), False{}}

def acc.sp(r: Array<Nat> & Bool, dense: Bool) -> Acc:
  (a, ok) = r
  match ok:
    case True{}:
      Acc{a, dense}
    case False{}:
      AccBad{}

def acc.of(sparse: Bool, +v: String, a: Array<Nat>, dense: Bool) -> Acc:
  match sparse:
    case True{}:
      +s = String.drop(v, 16n)
      acc.sp(sp.merge(Nat.add(String.length(s), 1n), op.at(s, 0), s, 0n, a, 0), dense)
    case False{}:
      Acc{d.merge(v, a), True{}}

# a valid v merged in
def acc.add(st: Acc, +v: String) -> Acc:
  match st:
    case Acc{a, dense}:
      acc.of(is_sparse(v), v, a, dense)
    case AccBad{}:
      AccBad{}

# the cardinality of the maxima (hllCount of HLL_RAW)
def acc.count(a: Array<Nat>) -> W:
  est(regs.hist(16384n, Array.get(Nat, a, 0), 0n, hist.new()))

# PFMERGE
# -------

# v made dense with the registers a (its header kept, the encoding 0)
def merge.dense.of(+v: String, a: Array<Nat>) -> String:
  String.take(v, 4n) ++ b1(0) ++ String.slice(v, 5n, 11n) ++ d.enc(a)

# the sparse value as the sets of the registers so far left it, n bytes
# (pe past them), a walk to the next starting at the opcode o (of first
# register f); or the value as a set made it turn dense
type MSt is Data:
  MS{v: String, n: Nat, o: Nat, f: Nat, pe: U32}
  MD{v: String}

# a set that must turn v dense: dense, or, when its opcodes do not hold
# 16384 registers, as it was (hllSparseSet fails, and PFMERGE goes on)
def merge.prom(m: Maybe<&2, String>, +v: String, +n: Nat, +pe: U32) -> MSt:
  match m:
    case Some{w}:
      MD{v}
    case None{}:
      MS{v, n, 16n, 0n, pe}

def merge.st(r: SpSet, +v: String, +n: Nat, +pe: U32) -> MSt:
  match r:
    case SBad{}:
      MS{v, n, 16n, 0n, pe}
    case SSame{+o, +f}:
      MS{v, n, Bool.pick(Nat, Nat.is_eq(o, 0n), 16n, o), f, pe}
    case SNew{w, +m, +o, +f, pe2}:
      MS{w, m, Bool.pick(Nat, Nat.is_eq(o, 0n), 16n, o), f, pe2}
    case SProm{}:
      merge.prom(sp.dense(v, pe), v, n, pe)

# the registers j on, k of them, set in turn where the maxima are more
# than 0 (r: the array and register j): hllSparseSet, then once one made
# the value turn dense, the value dense with the maxima, which are as
# much as every register in it (every set before it held, as a set that
# fails to find its register leaves the opcodes too short to turn dense)
def merge.sp(k: Nat, st: MSt, r: Array<Nat> & Nat, +j: Nat, +mx: Nat) -> String:
  match k:
    case 0n:
      match st:
        case MS{v, n, o, f, pe}:
          v
        case MD{+v}:
          (a, x) = r
          merge.dense.of(v, a)
    case 1n+q:
      match st:
        case MD{+v}:
          (a, x) = r
          merge.dense.of(v, a)
        case MS{+v, +n, +o, +f, +pe}:
          (a, x) = r
          match x:
            case 0n:
              merge.sp(q, MS{v, n, o, f, pe}, Array.get(Nat, a, U32.from_nat(Nat.min(Nat.add(j, 1n), 16383n))), Nat.add(j, 1n), mx)
            case 1n+y:
              merge.sp(q, merge.st(sp.set(v, n, mx, j, 1n+y, o, f, pe), v, n, pe), Array.get(Nat, a, U32.from_nat(Nat.min(Nat.add(j, 1n), 16383n))), Nat.add(j, 1n), mx)

def merge.dense(m: Maybe<&2, String>, a: Array<Nat>) -> Maybe<&2, String>:
  match m:
    case Some{+w}:
      Some{stale(merge.dense.of(w, a))}
    case None{}:
      None{}

def merge.to(sparse: Bool, +v: String) -> Maybe<&2, String>:
  match sparse:
    case True{}:
      sp.dense(v, 0)
    case False{}:
      Some{v}

# PFMERGE's value at its destination v (a new one where it was not
# there): its registers the maxima a, dense when one of the HLLs was
# (none when v does not turn dense), else set in turn; its cardinality
# marked as not valid
def merge(+v: String, a: Array<Nat>, dense: Bool, +mx: Nat) -> Maybe<&2, String>:
  match dense:
    case True{}:
      merge.dense(merge.to(is_sparse(v), v), a)
    case False{}:
      Some{stale(merge.sp(16384n, MS{v, String.length(v), 16n, 0n, 0}, Array.get(Nat, a, 0), 0n, mx))}

# PFSELFTEST
# ----------
# Redis's checks of its own implementation, on fewer cases: the dense
# registers of two arrays of random values (Redis: 1000), read back each;
# and 10,000 elements added to a dense HyperLogLog and to a sparse one
# (Redis: ten million), whose counts at 1, 10, 100, 1000 and 10,000 must
# agree, stay within 6 standard errors of the truth (1 at 10), and the
# sparse one sparse below 1500 elements (hll-sparse-max-bytes / 2).
# Random numbers come from xorshift with a fixed seed: Redis's rand()
# gives other ones, which the checks pass all the same.

def st.rand(+x: U32) -> U32:
  +a = U32.xor(x, U32.shln(x, 13n))
  +b = U32.xor(a, U32.shrn(a, 17n))
  U32.xor(b, U32.shln(b, 5n))

# a with registers i on, k of them, set to random values from x
def st.fill(k: Nat, a: Array<Nat>, +i: Nat, +x: U32) -> Array<Nat>:
  match k:
    case 0n:
      a
    case 1n+q:
      st.fill(q, Array.set(Nat, a, U32.from_nat(i), U32.to_nat(U32.and(x, 63))), Nat.add(i, 1n), st.rand(x))

# the registers read back, xs, against the random values from x they
# were set to: the first that differs (fi, which it should be fe, and is
# fg)
def st.cmp(xs: List<&2, Nat>, +x: U32, +i: Nat, +found: Bool, +fi: Nat, +fe: Nat, +fg: Nat) -> Maybe<&2, String>:
  match xs:
    case Nil{}:
      Bool.pick(Maybe<&2, String>, found, Some{"TESTFAILED Register " ++ Nat.show(fi) ++ " should be " ++ Nat.show(fe) ++ " but is " ++ Nat.show(fg)}, None{})
    case Con{+r, rest}:
      +y = U32.to_nat(U32.and(x, 63))
      +bad = Bool.and(Bool.not(found), Nat.is_ne(r, y))
      st.cmp(rest, st.rand(x), Nat.add(i, 1n), Bool.or(found, bad), Bool.pick(Nat, bad, i, fi), Bool.pick(Nat, bad, y, fe), Bool.pick(Nat, bad, r, fg))

def st.dense0() -> String:
  "HYLL" ++ b1(0) ++ zeros(11n)

# a cycle of the first check: the dense registers set to random values
# from x, then read back
def st.cycle(+x: U32) -> Maybe<&2, String>:
  st.cmp(d.regs(st.dense0() ++ d.enc(st.fill(16384n, regs.new(), 0n, x))), x, 0n, False{}, 0n, 0n, 0n)

def st.or(m: Maybe<&2, String>, n: Maybe<&2, String>) -> Maybe<&2, String>:
  match m:
    case Some{e}:
      Some{e}
    case None{}:
      n

# element j: the 8 bytes of j ^ the seed
def st.ele(+j: Nat) -> String:
  card.bytes(W{1374025911, U32.xor(4027432771, U32.from_nat(j))})

def st.v(o: AddOut) -> String:
  match o:
    case AddDone{ch, v}:
      v
    case AddErr{ch, v}:
      v

def st.add1(+v: String, +e: String) -> String:
  st.v(add(False{}, v, 3000n, [e]))

def count.w(c: Count) -> W:
  match c:
    case CntNew{x}:
      x
    case CntKept{x}:
      x
    case CntBad{}:
      W{0, 0}

def st.lo(c: W) -> Nat:
  match c:
    case W{hi, +lo}:
      U32.to_nat(lo)

# the count of v, made (hllCount), its low half (below 2^32)
def st.cnt(+v: String) -> Nat:
  st.lo(count.w(count.new(is_sparse(v), v)))

def st.diff(+a: Nat, +b: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_lt(a, b), Nat.sub(b, a), Nat.sub(a, b))

# the checks at checkpoint j: the sparse one sparse below 1500, the
# counts agreeing, the dense one's within ceil(1.04 / 128 * 6 * j) of j
# (1 at 10)
def st.check(+j: Nat, +d: String, +sv: String) -> Maybe<&2, String>:
  +cd = st.cnt(d)
  +err = st.diff(j, cd)
  +mx = Bool.pick(Nat, Nat.is_eq(j, 10n), 1n, Nat.div(Nat.add(Nat.mul(624n, j), 12799n), 12800n))
  Bool.pick(Maybe<&2, String>, Bool.and(Nat.is_lt(j, 1500n), Bool.not(is_sparse(sv))), Some{"TESTFAILED sparse encoding not used"},
  Bool.pick(Maybe<&2, String>, Nat.is_ne(cd, st.cnt(sv)), Some{"TESTFAILED dense/sparse disagree"},
  Bool.pick(Maybe<&2, String>, Nat.is_lt(mx, err), Some{"TESTFAILED Too big error. card:" ++ Nat.show(j) ++ " abserr:" ++ Nat.show(err)}, None{})))

# elements j on, k of them, added to the dense d and the sparse sv: err,
# what the last checkpoint found; chk, whether j is the next one (cp)
def st.add(k: Nat, err: Maybe<&2, String>, chk: Bool, +j: Nat, +d: String, +sv: String, +cp: Nat) -> Maybe<&2, String>:
  match k:
    case 0n:
      err
    case 1n+q:
      match err:
        case Some{e}:
          Some{e}
        case None{}:
          match chk:
            case False{}:
              +e = st.ele(j)
              st.add(q, None{}, Nat.is_eq(Nat.add(j, 1n), cp), Nat.add(j, 1n), st.add1(d, e), st.add1(sv, e), cp)
            case True{}:
              +e = st.ele(j)
              +d2 = st.add1(d, e)
              +s2 = st.add1(sv, e)
              +cp2 = Nat.mul(cp, 10n)
              st.add(q, st.check(j, d2, s2), Nat.is_eq(Nat.add(j, 1n), cp2), Nat.add(j, 1n), d2, s2, cp2)

# PFSELFTEST: none when every check passes, else what failed
def selftest() -> Maybe<&2, String>:
  st.or(st.or(st.cycle(2463534242), st.cycle(88675123)), st.add(10000n, None{}, True{}, 1n, st.dense0() ++ zeros(12288n), fresh(), 1n))
