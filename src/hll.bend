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

# Registers in words
# ------------------
# 16384 registers (a merge's maxima) as 4096 words of 32 bits, register
# 4w + j in byte j of word w, and words of 0 past the end of a list. A
# register is below 64, so each byte's top bit is free: the larger of two
# words' bytes takes a subtraction (w4.max). An Array would hold them,
# but a program that holds an Array makes the compiler pass each boxed
# argument of every loop with its location and read shared blocks through
# their counts: some 4% more instructions on each GET and SET.

# each byte of a and b, the larger (bytes below 128: 128 + x - y keeps to
# its byte, and its top bit says whether x is the larger)
def w4.max(+a: U32, +b: U32) -> U32:
  +d = U32.sub(U32.or(a, 2155905152), b)
  +m = U32.mul(U32.and(U32.shrn(d, 7n), 16843009), 255)
  U32.or(U32.and(a, m), U32.and(b, U32.not(m)))

def w4.of(+r0: U32, +r1: U32, +r2: U32, +r3: U32) -> U32:
  U32.or(U32.or(r0, U32.shln(r1, 8n)), U32.or(U32.shln(r2, 16n), U32.shln(r3, 24n)))

def w4.r0(+w: U32) -> U32:
  U32.and(w, 255)

def w4.r1(+w: U32) -> U32:
  U32.and(U32.shrn(w, 8n), 255)

def w4.r2(+w: U32) -> U32:
  U32.and(U32.shrn(w, 16n), 255)

def w4.r3(+w: U32) -> U32:
  U32.shrn(w, 24n)

# a register (i) and its value, above 0
type RV is Data:
  RV{i: Nat, v: U32}

# whether register p, or the one at the head of ps, is in word w
def ws.in.rv(+p: RV, +w: Nat) -> Bool:
  match p:
    case RV{+i, v}:
      Nat.is_lt(i, Nat.mul(Nat.add(w, 1n), 4n))

def ws.in(+ps: List<&2, RV>, +w: Nat) -> Bool:
  match ps:
    case Con{+p, r}:
      ws.in.rv(p, w)
    case Nil{}:
      False{}

# the words of rev, the last first, before rest
def ws.onto(rev: List<&2, U32>, rest: List<&2, U32>) -> List<&2, U32>:
  match rev:
    case Nil{}:
      rest
    case Con{+x, r}:
      ws.onto(r, x <> rest)

# a with its first word's bytes at least those of y
def ws.lane(a: List<&2, U32>, +y: U32) -> List<&2, U32>:
  match a:
    case Con{+x, r}:
      w4.max(x, y) <> r
    case Nil{}:
      [y]

# a, words w on, with each register of ps at least its value (ps in order
# from word w; here: whether its first is in word w; k bounds the steps,
# a word or a register each), after the words before w (done, the last
# first): the words after ps's last kept as they are
def ws.put(k: Nat, here: Bool, ps: List<&2, RV>, a: List<&2, U32>, done: List<&2, U32>, +w: Nat) -> List<&2, U32>:
  match k:
    case 0n:
      ws.onto(done, a)
    case 1n+q:
      match here:
        case True{}:
          match ps:
            case Con{RV{+i, +v}, +rest}:
              +y = U32.shln(v, Nat.mul(Nat.sub(i, Nat.mul(w, 4n)), 8n))
              ws.put(q, ws.in(rest, w), rest, ws.lane(a, y), done, w)
            case Nil{}:
              ws.onto(done, a)
        case False{}:
          match ps:
            case Nil{}:
              ws.onto(done, a)
            case Con{+p, rest}:
              match a:
                case Con{+x, ra}:
                  +w1 = Nat.add(w, 1n)
                  ws.put(q, ws.in.rv(p, w1), Con{p, rest}, ra, x <> done, w1)
                case Nil{}:
                  +w1 = Nat.add(w, 1n)
                  ws.put(q, ws.in.rv(p, w1), Con{p, rest}, Nil{}, 0 <> done, w1)

# a with the registers of ps
def ws.add(a: List<&2, U32>, +ps: List<&2, RV>) -> List<&2, U32>:
  ws.put(20481n, ws.in(ps, 0n), ps, a, Nil{}, 0n)

# four registers in three bytes, as the dense encoding has them: x0 = r0
# | r1 << 6, x1 = r1 >> 2 | r2 << 4, x2 = r2 >> 4 | r3 << 2
def ws.x0(+w: U32) -> U32:
  U32.and(U32.or(w4.r0(w), U32.shln(w4.r1(w), 6n)), 255)

def ws.x1(+w: U32) -> U32:
  U32.and(U32.or(U32.shrn(w4.r1(w), 2n), U32.shln(w4.r2(w), 4n)), 255)

def ws.x2(+w: U32) -> U32:
  U32.and(U32.or(U32.shrn(w4.r2(w), 4n), U32.shln(w4.r3(w), 2n)), 255)

# the words of a, the last first, before r, and n more than a has
def ws.rev(a: List<&2, U32>, r: List<&2, U32>, +n: Nat) -> List<&2, U32> & Nat:
  match a:
    case Nil{}:
      (r, n)
    case Con{+x, t}:
      ws.rev(t, x <> r, Nat.add(n, 1n))

# the dense bytes of the words of rev (the last first), before acc
def ws.enc.go(rev: List<&2, U32>, acc: String) -> String:
  match rev:
    case Nil{}:
      acc
    case Con{+w, r}:
      ws.enc.go(r, SCon{Chr{ws.x0(w)}, SCon{Chr{ws.x1(w)}, SCon{Chr{ws.x2(w)}, acc}}})

def ws.enc.of(r: List<&2, U32> & Nat) -> String:
  (rev, n) = r
  ws.enc.go(rev, zeros(Nat.mul(Nat.sub(4096n, n), 3n)))

# the dense bytes of a's registers (4096 words)
def ws.enc(a: List<&2, U32>) -> String:
  ws.enc.of(ws.rev(a, Nil{}, 0n))

# A histogram of the registers: how many hold each value from 0 to 51,
# the ones Ertl's estimator reads (hllCount counts 52 to 63 too, and
# reads them not), two counts of 16 bits to a word: count v at bits 16
# (v mod 2) of word v div 2. Its loops keep the 26 words in their own
# parameters, and count a register in two steps: one finds its value,
# its word (g) and what it adds there (d), the next adds it (a record of
# the words, given to a function and taken back, would cost a copy of
# all of them for each register).
type Hist is Data:
  Hist{h0: U32, h1: U32, h2: U32, h3: U32, h4: U32, h5: U32, h6: U32, h7: U32, h8: U32, h9: U32, h10: U32, h11: U32, h12: U32, h13: U32, h14: U32, h15: U32, h16: U32, h17: U32, h18: U32, h19: U32, h20: U32, h21: U32, h22: U32, h23: U32, h24: U32, h25: U32}

# one register of value r: its word, and what it adds there
def hist.g(+r: U32) -> Nat:
  U32.to_nat(U32.shrn(r, 1n))

def hist.d(+r: U32, +n: U32) -> U32:
  U32.shln(n, Nat.mul(U32.to_nat(U32.and(r, 1)), 16n))

# the histogram of the registers of the words a, and of left more words
# of 0 past them; w the registers of the word at hand not yet counted, n
# of them; at = 0: count the register of word g, d, then go on
def hist.ws(k: Nat, at: Nat, g: Nat, +d: U32, n: Nat, a: List<&2, U32>, +w: U32, +left: Nat, +h0: U32, +h1: U32, +h2: U32, +h3: U32, +h4: U32, +h5: U32, +h6: U32, +h7: U32, +h8: U32, +h9: U32, +h10: U32, +h11: U32, +h12: U32, +h13: U32, +h14: U32, +h15: U32, +h16: U32, +h17: U32, +h18: U32, +h19: U32, +h20: U32, +h21: U32, +h22: U32, +h23: U32, +h24: U32, +h25: U32) -> Hist:
  match k:
    case 0n:
      Hist{h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25}
    case 1n+q:
      match at:
        case 0n:
          match g:
            case 0n:
              hist.ws(q, 1n, 0n, d, n, a, w, left, U32.add(h0, d), h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 1n:
              hist.ws(q, 1n, 0n, d, n, a, w, left, h0, U32.add(h1, d), h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 2n:
              hist.ws(q, 1n, 0n, d, n, a, w, left, h0, h1, U32.add(h2, d), h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 3n:
              hist.ws(q, 1n, 0n, d, n, a, w, left, h0, h1, h2, U32.add(h3, d), h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 4n:
              hist.ws(q, 1n, 0n, d, n, a, w, left, h0, h1, h2, h3, U32.add(h4, d), h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 5n:
              hist.ws(q, 1n, 0n, d, n, a, w, left, h0, h1, h2, h3, h4, U32.add(h5, d), h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 6n:
              hist.ws(q, 1n, 0n, d, n, a, w, left, h0, h1, h2, h3, h4, h5, U32.add(h6, d), h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 7n:
              hist.ws(q, 1n, 0n, d, n, a, w, left, h0, h1, h2, h3, h4, h5, h6, U32.add(h7, d), h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 8n:
              hist.ws(q, 1n, 0n, d, n, a, w, left, h0, h1, h2, h3, h4, h5, h6, h7, U32.add(h8, d), h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 9n:
              hist.ws(q, 1n, 0n, d, n, a, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, U32.add(h9, d), h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 10n:
              hist.ws(q, 1n, 0n, d, n, a, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, U32.add(h10, d), h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 11n:
              hist.ws(q, 1n, 0n, d, n, a, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, U32.add(h11, d), h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 12n:
              hist.ws(q, 1n, 0n, d, n, a, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, U32.add(h12, d), h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 13n:
              hist.ws(q, 1n, 0n, d, n, a, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, U32.add(h13, d), h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 14n:
              hist.ws(q, 1n, 0n, d, n, a, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, U32.add(h14, d), h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 15n:
              hist.ws(q, 1n, 0n, d, n, a, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, U32.add(h15, d), h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 16n:
              hist.ws(q, 1n, 0n, d, n, a, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, U32.add(h16, d), h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 17n:
              hist.ws(q, 1n, 0n, d, n, a, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, U32.add(h17, d), h18, h19, h20, h21, h22, h23, h24, h25)
            case 18n:
              hist.ws(q, 1n, 0n, d, n, a, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, U32.add(h18, d), h19, h20, h21, h22, h23, h24, h25)
            case 19n:
              hist.ws(q, 1n, 0n, d, n, a, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, U32.add(h19, d), h20, h21, h22, h23, h24, h25)
            case 20n:
              hist.ws(q, 1n, 0n, d, n, a, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, U32.add(h20, d), h21, h22, h23, h24, h25)
            case 21n:
              hist.ws(q, 1n, 0n, d, n, a, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, U32.add(h21, d), h22, h23, h24, h25)
            case 22n:
              hist.ws(q, 1n, 0n, d, n, a, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, U32.add(h22, d), h23, h24, h25)
            case 23n:
              hist.ws(q, 1n, 0n, d, n, a, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, U32.add(h23, d), h24, h25)
            case 24n:
              hist.ws(q, 1n, 0n, d, n, a, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, U32.add(h24, d), h25)
            case 25n:
              hist.ws(q, 1n, 0n, d, n, a, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, U32.add(h25, d))
            case _:
              hist.ws(q, 1n, 0n, d, n, a, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
        case _:
          match n:
            case 0n:
              match a:
                case Con{+x, r}:
                  hist.ws(q, 0n, hist.g(w4.r0(x)), hist.d(w4.r0(x), 1), 3n, r, U32.shrn(x, 8n), Nat.sub(left, 1n), h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
                case Nil{}:
                  Hist{U32.add(h0, U32.from_nat(Nat.mul(left, 4n))), h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25}
            case 1n+m:
              hist.ws(q, 0n, hist.g(U32.and(w, 255)), hist.d(U32.and(w, 255), 1), m, a, U32.shrn(w, 8n), left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)

def hist.word(+h: Hist, +g: Nat) -> U32:
  match h:
    case Hist{+h0, +h1, +h2, +h3, +h4, +h5, +h6, +h7, +h8, +h9, +h10, +h11, +h12, +h13, +h14, +h15, +h16, +h17, +h18, +h19, +h20, +h21, +h22, +h23, +h24, +h25}:
      match g:
        case 0n:
          h0
        case 1n:
          h1
        case 2n:
          h2
        case 3n:
          h3
        case 4n:
          h4
        case 5n:
          h5
        case 6n:
          h6
        case 7n:
          h7
        case 8n:
          h8
        case 9n:
          h9
        case 10n:
          h10
        case 11n:
          h11
        case 12n:
          h12
        case 13n:
          h13
        case 14n:
          h14
        case 15n:
          h15
        case 16n:
          h16
        case 17n:
          h17
        case 18n:
          h18
        case 19n:
          h19
        case 20n:
          h20
        case 21n:
          h21
        case 22n:
          h22
        case 23n:
          h23
        case 24n:
          h24
        case 25n:
          h25
        case _:
          0

# how many registers of value x (up to 51) h counts
def hist.get(+h: Hist, +x: Nat) -> Nat:
  U32.to_nat(U32.and(U32.shrn(hist.word(h, Nat.div(x, 2n)), Nat.mul(Nat.mod(x, 2n), 16n)), 65535))

# the histogram of the words a (4096 registers)
def ws.hist(a: List<&2, U32>) -> Hist:
  hist.ws(32800n, 1n, 0n, 0, 0n, a, 0, 4096n, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

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

# The dense bytes are read a piece of 1536 at a time, a String of one
# chunk whose bytes String.code_at reads where they lie (a match of a
# long String takes each byte apart from the rest).

# the registers of the dense bytes of the piece c (k blocks of three from
# byte i) as words, after done (the last first)
def d.words.c(k: Nat, +c: String, +i: Nat, done: List<&2, U32>) -> List<&2, U32>:
  match k:
    case 0n:
      done
    case 1n+q:
      +x0 = String.code_at(c, i)
      +x1 = String.code_at(c, Nat.add(i, 1n))
      +x2 = String.code_at(c, Nat.add(i, 2n))
      d.words.c(q, c, Nat.add(i, 3n), w4.of(d.r0(x0), d.r1(x0, x1), d.r2(x1, x2), d.r3(x2)) <> done)

# the four registers of the block of three bytes at i of c, as a word
def d.word(+c: String, +i: Nat) -> U32:
  +x0 = String.code_at(c, i)
  +x1 = String.code_at(c, Nat.add(i, 1n))
  +x2 = String.code_at(c, Nat.add(i, 2n))
  w4.of(d.r0(x0), d.r1(x0, x1), d.r2(x1, x2), d.r3(x2))

# the histogram of the registers of the dense bytes of the piece c, left
# blocks of three from byte i, as hist.ws counts the registers of words
def hist.dn(k: Nat, at: Nat, g: Nat, +d: U32, n: Nat, +c: String, +i: Nat, +w: U32, +left: Nat, +h0: U32, +h1: U32, +h2: U32, +h3: U32, +h4: U32, +h5: U32, +h6: U32, +h7: U32, +h8: U32, +h9: U32, +h10: U32, +h11: U32, +h12: U32, +h13: U32, +h14: U32, +h15: U32, +h16: U32, +h17: U32, +h18: U32, +h19: U32, +h20: U32, +h21: U32, +h22: U32, +h23: U32, +h24: U32, +h25: U32) -> Hist:
  match k:
    case 0n:
      Hist{h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25}
    case 1n+q:
      match at:
        case 0n:
          match g:
            case 0n:
              hist.dn(q, 1n, 0n, d, n, c, i, w, left, U32.add(h0, d), h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 1n:
              hist.dn(q, 1n, 0n, d, n, c, i, w, left, h0, U32.add(h1, d), h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 2n:
              hist.dn(q, 1n, 0n, d, n, c, i, w, left, h0, h1, U32.add(h2, d), h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 3n:
              hist.dn(q, 1n, 0n, d, n, c, i, w, left, h0, h1, h2, U32.add(h3, d), h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 4n:
              hist.dn(q, 1n, 0n, d, n, c, i, w, left, h0, h1, h2, h3, U32.add(h4, d), h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 5n:
              hist.dn(q, 1n, 0n, d, n, c, i, w, left, h0, h1, h2, h3, h4, U32.add(h5, d), h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 6n:
              hist.dn(q, 1n, 0n, d, n, c, i, w, left, h0, h1, h2, h3, h4, h5, U32.add(h6, d), h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 7n:
              hist.dn(q, 1n, 0n, d, n, c, i, w, left, h0, h1, h2, h3, h4, h5, h6, U32.add(h7, d), h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 8n:
              hist.dn(q, 1n, 0n, d, n, c, i, w, left, h0, h1, h2, h3, h4, h5, h6, h7, U32.add(h8, d), h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 9n:
              hist.dn(q, 1n, 0n, d, n, c, i, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, U32.add(h9, d), h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 10n:
              hist.dn(q, 1n, 0n, d, n, c, i, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, U32.add(h10, d), h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 11n:
              hist.dn(q, 1n, 0n, d, n, c, i, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, U32.add(h11, d), h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 12n:
              hist.dn(q, 1n, 0n, d, n, c, i, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, U32.add(h12, d), h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 13n:
              hist.dn(q, 1n, 0n, d, n, c, i, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, U32.add(h13, d), h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 14n:
              hist.dn(q, 1n, 0n, d, n, c, i, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, U32.add(h14, d), h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 15n:
              hist.dn(q, 1n, 0n, d, n, c, i, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, U32.add(h15, d), h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 16n:
              hist.dn(q, 1n, 0n, d, n, c, i, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, U32.add(h16, d), h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 17n:
              hist.dn(q, 1n, 0n, d, n, c, i, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, U32.add(h17, d), h18, h19, h20, h21, h22, h23, h24, h25)
            case 18n:
              hist.dn(q, 1n, 0n, d, n, c, i, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, U32.add(h18, d), h19, h20, h21, h22, h23, h24, h25)
            case 19n:
              hist.dn(q, 1n, 0n, d, n, c, i, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, U32.add(h19, d), h20, h21, h22, h23, h24, h25)
            case 20n:
              hist.dn(q, 1n, 0n, d, n, c, i, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, U32.add(h20, d), h21, h22, h23, h24, h25)
            case 21n:
              hist.dn(q, 1n, 0n, d, n, c, i, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, U32.add(h21, d), h22, h23, h24, h25)
            case 22n:
              hist.dn(q, 1n, 0n, d, n, c, i, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, U32.add(h22, d), h23, h24, h25)
            case 23n:
              hist.dn(q, 1n, 0n, d, n, c, i, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, U32.add(h23, d), h24, h25)
            case 24n:
              hist.dn(q, 1n, 0n, d, n, c, i, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, U32.add(h24, d), h25)
            case 25n:
              hist.dn(q, 1n, 0n, d, n, c, i, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, U32.add(h25, d))
            case _:
              hist.dn(q, 1n, 0n, d, n, c, i, w, left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
        case _:
          match n:
            case 0n:
              match left:
                case 0n:
                  Hist{h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25}
                case 1n+l:
                  +x = d.word(c, i)
                  hist.dn(q, 0n, hist.g(w4.r0(x)), hist.d(w4.r0(x), 1), 3n, c, Nat.add(i, 3n), U32.shrn(x, 8n), l, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 1n+m:
              hist.dn(q, 0n, hist.g(U32.and(w, 255)), hist.d(U32.and(w, 255), 1), m, c, i, U32.shrn(w, 8n), left, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
def d.hist.c(h: Hist, +c: String) -> Hist:
  match h:
    case Hist{h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25}:
      hist.dn(4100n, 1n, 0n, 0, 0n, c, 0n, 0, Nat.div(String.length(c), 3n), h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)

# h with the registers of the dense bytes s, from byte j on (k pieces)
def d.hist.go(k: Nat, h: Hist, +s: String, +j: Nat) -> Hist:
  match k:
    case 0n:
      h
    case 1n+q:
      +c = String.take(String.drop(s, j), 1536n)
      d.hist.go(q, d.hist.c(h, c), s, Nat.add(j, 1536n))

# the histogram of a dense v's registers (hllDenseRegHisto)
def d.hist(+v: String) -> Hist:
  d.hist.go(8n, Hist{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}, String.drop(v, 16n), 0n)

# a with each register at least the dense one of the piece c (k blocks
# from byte i), after done (the last first): the words of a after the
# piece's, and the new ones
def d.merge.c(k: Nat, a: List<&2, U32>, +c: String, +i: Nat, done: List<&2, U32>) -> List<&2, U32> & List<&2, U32>:
  match k:
    case 0n:
      (a, done)
    case 1n+q:
      match a:
        case Con{+x, ra}:
          +x0 = String.code_at(c, i)
          +x1 = String.code_at(c, Nat.add(i, 1n))
          +x2 = String.code_at(c, Nat.add(i, 2n))
          d.merge.c(q, ra, c, Nat.add(i, 3n), w4.max(x, w4.of(d.r0(x0), d.r1(x0, x1), d.r2(x1, x2), d.r3(x2))) <> done)
        case Nil{}:
          (Nil{}, d.words.c(Nat.add(q, 1n), c, i, done))

def d.merge.fin(r: List<&2, U32> & List<&2, U32>) -> List<&2, U32>:
  (a, done) = r
  ws.onto(done, a)

# r's words with each register at least the dense one in s, from byte j
# on (k pieces)
def d.merge.go(k: Nat, r: List<&2, U32> & List<&2, U32>, +s: String, +j: Nat) -> List<&2, U32>:
  match k:
    case 0n:
      d.merge.fin(r)
    case 1n+q:
      (a, done) = r
      +c = String.take(String.drop(s, j), 1536n)
      d.merge.go(q, d.merge.c(Nat.div(String.length(c), 3n), a, c, 0n, done), s, Nat.add(j, 1536n))

# a merged with a dense v (hllMerge)
def d.merge(+v: String, a: List<&2, U32>) -> List<&2, U32>:
  d.merge.go(8n, (a, Nil{}), String.drop(v, 16n), 0n)

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

# the opcode at p of a value, as Redis reads it: whether there is one
# (more), whether it is an XZERO (two bytes: the second of an XZERO cut
# at the end is the byte past the end, pe), its byte c and the next, lo,
# the registers it holds and their value (0 for a run of zeros)
type Op is Data:
  Op{more: Bool, x: Bool, c: U32, lo: U32, len: Nat, val: Nat}

# The walks read the value by index, String.code_at, which reads a String
# of one chunk where its bytes lie (a match takes a byte apart from the
# rest, and String.code_at reads a view or a String of several chunks a
# run at a time): a value is one chunk when a command has copied it
# (flat) and it is at most 2048 bytes. Past the end, String.code_at gives
# 2^32 - 1. Of an opcode's byte c, t = c >> 6 & 3 is 0 for a ZERO, 1 for
# an XZERO, 2 or 3 for a VAL: c >> 7 is 1 for a VAL alone, t & (t >> 1 ^
# 1) for an XZERO alone; sums of these take the place of choices between
# the kinds (a Bool.pick is a call).

# v as one String of one chunk, up to 2048 bytes (String.take copies)
def flat(+v: String) -> String:
  String.take(v, String.length(v))

# byte i of v, or pe past the end: there String.code_at's 2^32 - 1 has a
# low byte of 255, which its top byte, 255, turns into pe
def op.lo(+v: String, +i: Nat, +pe: U32) -> U32:
  +b = String.code_at(v, i)
  U32.xor(U32.and(b, 255), U32.and(U32.shrn(b, 24n), U32.xor(pe, 255)))

# 1 for an XZERO's byte c, else 0
def op.xz(+c: U32) -> U32:
  +t = U32.and(U32.shrn(c, 6n), 3)
  U32.and(t, U32.xor(U32.shrn(t, 1n), 1))

# the registers of the opcode c, lo: a VAL's c & 3, a ZERO's c & 63, an
# XZERO's (c & 63) * 256 + lo, plus 1
def op.n(+c: U32, +lo: U32) -> Nat:
  +x = op.xz(c)
  U32.to_nat(U32.add(U32.add(U32.mul(U32.and(c, U32.sub(63, U32.mul(U32.and(U32.shrn(c, 7n), 1), 60))), U32.add(U32.mul(x, 255), 1)), U32.mul(lo, x)), 1))

# a VAL's value, c >> 2 & 31 plus 1; 0 for a run of zeros
def op.val(+c: U32) -> Nat:
  U32.to_nat(U32.mul(U32.and(U32.shrn(c, 7n), 1), U32.add(U32.and(U32.shrn(c, 2n), 31), 1)))

# the bytes of the opcode c: 2 for an XZERO, else 1
def op.step(+c: U32) -> Nat:
  U32.to_nat(U32.add(op.xz(c), 1))

def op.at(+v: String, +p: Nat, +pe: U32) -> Op:
  +c = String.code_at(v, p)
  +lo = op.lo(v, Nat.add(p, 1n), pe)
  Op{U32.is_lt(c, 256), U32.is_eq(op.xz(c), 1), c, lo, op.n(c, lo), op.val(c)}

def op.len(+o: Op) -> Nat:
  match o:
    case Op{more, x, c, lo, +len, val}:
      len

def op.more(+o: Op) -> Bool:
  match o:
    case Op{+more, x, c, lo, len, val}:
      more

# The walks of the opcodes of v (the bytes after the header), o the one
# at p. The histogram and DECODE walk a value as a command finds it, the
# byte past its end 0; the merge walks it as the sets before it in a
# command left it (pe).

# the histogram of the registers the opcodes hold (hllSparseRegHisto),
# and how many they hold: o the opcode at p, the registers before it idx;
# at = 0: count the run of g, d, then go on
def hist.sp(k: Nat, at: Nat, g: Nat, +d: U32, o: Op, +v: String, +p: Nat, +idx: Nat, +h0: U32, +h1: U32, +h2: U32, +h3: U32, +h4: U32, +h5: U32, +h6: U32, +h7: U32, +h8: U32, +h9: U32, +h10: U32, +h11: U32, +h12: U32, +h13: U32, +h14: U32, +h15: U32, +h16: U32, +h17: U32, +h18: U32, +h19: U32, +h20: U32, +h21: U32, +h22: U32, +h23: U32, +h24: U32, +h25: U32) -> Hist & Nat:
  match k:
    case 0n:
      (Hist{h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25}, idx)
    case 1n+q:
      match at:
        case 0n:
          match g:
            case 0n:
              hist.sp(q, 1n, 0n, d, o, v, p, idx, U32.add(h0, d), h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 1n:
              hist.sp(q, 1n, 0n, d, o, v, p, idx, h0, U32.add(h1, d), h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 2n:
              hist.sp(q, 1n, 0n, d, o, v, p, idx, h0, h1, U32.add(h2, d), h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 3n:
              hist.sp(q, 1n, 0n, d, o, v, p, idx, h0, h1, h2, U32.add(h3, d), h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 4n:
              hist.sp(q, 1n, 0n, d, o, v, p, idx, h0, h1, h2, h3, U32.add(h4, d), h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 5n:
              hist.sp(q, 1n, 0n, d, o, v, p, idx, h0, h1, h2, h3, h4, U32.add(h5, d), h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 6n:
              hist.sp(q, 1n, 0n, d, o, v, p, idx, h0, h1, h2, h3, h4, h5, U32.add(h6, d), h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 7n:
              hist.sp(q, 1n, 0n, d, o, v, p, idx, h0, h1, h2, h3, h4, h5, h6, U32.add(h7, d), h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 8n:
              hist.sp(q, 1n, 0n, d, o, v, p, idx, h0, h1, h2, h3, h4, h5, h6, h7, U32.add(h8, d), h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 9n:
              hist.sp(q, 1n, 0n, d, o, v, p, idx, h0, h1, h2, h3, h4, h5, h6, h7, h8, U32.add(h9, d), h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 10n:
              hist.sp(q, 1n, 0n, d, o, v, p, idx, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, U32.add(h10, d), h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 11n:
              hist.sp(q, 1n, 0n, d, o, v, p, idx, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, U32.add(h11, d), h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 12n:
              hist.sp(q, 1n, 0n, d, o, v, p, idx, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, U32.add(h12, d), h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 13n:
              hist.sp(q, 1n, 0n, d, o, v, p, idx, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, U32.add(h13, d), h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 14n:
              hist.sp(q, 1n, 0n, d, o, v, p, idx, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, U32.add(h14, d), h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 15n:
              hist.sp(q, 1n, 0n, d, o, v, p, idx, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, U32.add(h15, d), h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 16n:
              hist.sp(q, 1n, 0n, d, o, v, p, idx, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, U32.add(h16, d), h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 17n:
              hist.sp(q, 1n, 0n, d, o, v, p, idx, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, U32.add(h17, d), h18, h19, h20, h21, h22, h23, h24, h25)
            case 18n:
              hist.sp(q, 1n, 0n, d, o, v, p, idx, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, U32.add(h18, d), h19, h20, h21, h22, h23, h24, h25)
            case 19n:
              hist.sp(q, 1n, 0n, d, o, v, p, idx, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, U32.add(h19, d), h20, h21, h22, h23, h24, h25)
            case 20n:
              hist.sp(q, 1n, 0n, d, o, v, p, idx, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, U32.add(h20, d), h21, h22, h23, h24, h25)
            case 21n:
              hist.sp(q, 1n, 0n, d, o, v, p, idx, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, U32.add(h21, d), h22, h23, h24, h25)
            case 22n:
              hist.sp(q, 1n, 0n, d, o, v, p, idx, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, U32.add(h22, d), h23, h24, h25)
            case 23n:
              hist.sp(q, 1n, 0n, d, o, v, p, idx, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, U32.add(h23, d), h24, h25)
            case 24n:
              hist.sp(q, 1n, 0n, d, o, v, p, idx, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, U32.add(h24, d), h25)
            case 25n:
              hist.sp(q, 1n, 0n, d, o, v, p, idx, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, U32.add(h25, d))
            case _:
              hist.sp(q, 1n, 0n, d, o, v, p, idx, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
        case _:
          match o:
            case Op{more, x, +c, lo, +len, +val}:
              match more:
                case False{}:
                  (Hist{h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25}, idx)
                case True{}:
                  +p2 = Nat.add(p, op.step(c))
                  hist.sp(q, 0n, hist.g(U32.from_nat(val)), hist.d(U32.from_nat(val), U32.from_nat(len)), op.at(v, p2, 0), v, p2, Nat.add(idx, len), h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)

# the opcodes a walk of v reads at most: each holds a register or more,
# so that of opcodes that hold 16384 there are 16384 at most, and the
# 16385th, if any, passes the last register, where the fix of
# CVE-2025-32023 ends Redis's walks (7.2.16's, and 7.0.15's as Ubuntu
# ships it); a walk that read on would find the same, as the registers
# only add up, but in time that grows with the square of v's length, as
# String.code_at finds a byte of a String of several chunks by walking
# its chunks from the first (1 MB of zeros took 1.5 s, and the 32 MB of
# a test of Redis 7.2.16 would take half an hour a walk)
def sp.most(+v: String) -> Nat:
  Nat.min(Nat.add(String.length(v), 1n), 16385n)

# whether the opcodes hold 16384 registers (hllMerge, hllSparseToDense),
# i the registers before p: an opcode that would pass the last register
# ends the walk, and makes them invalid, as the fix of CVE-2025-32023 has
# it (Redis 7.2.16, and 7.0.15 as Ubuntu ships it; before it, the zeros
# ran on, and a VAL past the last register ended the walk where the
# opcodes were valid if it ended at 16384); so they are valid when their
# runs add up to 16384, which k = sp.most(v) steps find
def sp.valid(k: Nat, o: Op, +v: String, +p: Nat, +i: Nat, +pe: U32) -> Bool:
  match k:
    case 0n:
      Nat.is_eq(i, 16384n)
    case 1n+k1:
      match o:
        case Op{more, x, +c, lo, +len, val}:
          match more:
            case False{}:
              Nat.is_eq(i, 16384n)
            case True{}:
              +p2 = Nat.add(p, op.step(c))
              sp.valid(k1, op.at(v, p2, pe), v, p2, Nat.add(i, len), pe)

# registers i on, n of them, of value v, before rest
def sp.run(n: Nat, +i: Nat, +v: U32, rest: List<&2, RV>) -> List<&2, RV>:
  match n:
    case 0n:
      rest
    case 1n+p:
      RV{i, v} <> sp.run(p, Nat.add(i, 1n), v, rest)

def sp.vals(zero: Bool, +n: Nat, +i: Nat, +v: U32, rest: List<&2, RV>) -> List<&2, RV>:
  match zero:
    case True{}:
      rest
    case False{}:
      sp.run(n, i, v, rest)

# the registers the VALs hold, from register i, with their values, in
# order (of opcodes that hold 16384)
def sp.pairs(k: Nat, o: Op, +v: String, +p: Nat, +i: Nat, +pe: U32) -> List<&2, RV>:
  match k:
    case 0n:
      Nil{}
    case 1n+k1:
      match o:
        case Op{more, x, +c, lo, +len, +val}:
          match more:
            case False{}:
              Nil{}
            case True{}:
              +p2 = Nat.add(p, op.step(c))
              sp.vals(Nat.is_eq(val, 0n), len, i, U32.from_nat(val), sp.pairs(k1, op.at(v, p2, pe), v, p2, Nat.add(i, len), pe))

# the registers of a valid sparse v, as words
def sp.words(+v: String, a: List<&2, U32>, +pe: U32) -> List<&2, U32>:
  ws.add(a, sp.pairs(sp.most(v), op.at(v, 16n, pe), v, 16n, 0n, pe))

# whether the opcodes of a sparse v hold 16384 registers
def sp.ok(+v: String, +pe: U32) -> Bool:
  sp.valid(sp.most(v), op.at(v, 16n, pe), v, 16n, 0n, pe)

def sp.dense.of(ok: Bool, +v: String, +pe: U32) -> Maybe<&2, String>:
  match ok:
    case True{}:
      Some{String.take(v, 4n) ++ b1(0) ++ String.slice(v, 5n, 11n) ++ ws.enc(sp.words(v, Nil{}, pe))}
    case False{}:
      None{}

# a sparse v made dense (hllSparseToDense): its header, the encoding 0,
# then its registers; none when its opcodes do not hold 16384 (pe: the
# byte past its end)
def sp.dense(+v: String, +pe: U32) -> Maybe<&2, String>:
  sp.dense.of(sp.ok(v, pe), v, pe)

# PFDEBUG DECODE: each opcode as "z:len", "Z:len" or "v:value,len"
def sp.dec(k: Nat, o: Op, +v: String, +p: Nat) -> String:
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
                  "Z:" ++ Nat.show(len) ++ " " ++ sp.dec(k1, op.at(v, Nat.add(p, 2n), 0), v, Nat.add(p, 2n))
                case False{}:
                  Bool.pick(String, Nat.is_eq(val, 0n), "z:" ++ Nat.show(len), "v:" ++ Nat.show(val) ++ "," ++ Nat.show(len)) ++ " " ++ sp.dec(k1, op.at(v, Nat.add(p, 1n), 0), v, Nat.add(p, 1n))

def sp.decode.of(+t: String) -> String:
  String.take(t, Nat.sub(String.length(t), 1n))

def sp.decode(+v: String) -> String:
  sp.decode.of(sp.dec(Nat.add(String.length(v), 1n), op.at(v, 16n, 0), v, 16n))

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

# here: whether o, the opcode at p of v, holds idx
def sp.find(k: Nat, here: Bool, o: Op, +v: String, +p: Nat, +first: Nat, +q: Nat, +qf: Nat, +po: Nat, +pf: Nat, +idx: Nat, +pe: U32) -> At:
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
            case Op{more, x, +c, lo, +len, val}:
              match more:
                case False{}:
                  ANone{}
                case True{}:
                  +p2 = Nat.add(p, op.step(c))
                  +o2 = op.at(v, p2, pe)
                  +f2 = Nat.add(first, len)
                  sp.find(k1, Bool.and(op.more(o2), Nat.is_lt(idx, Nat.add(f2, op.len(o2)))), o2, v, p2, f2, p, first, q, qf, idx, pe)

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
# (sdsIncrLen): the byte past the end is 0 after one. The new value is
# copied into one chunk (flat) for the walks of the sets after it.
def sp.updated.fin(+v: String, +n: Nat, +o: Nat, +f: Nat, +n0: Nat, +pe: U32) -> SpSet:
  SNew{flat(v), n, o, f, Bool.pick(U32, Nat.is_lt(n, n0), 0, pe)}

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
      +o = op.at(v, p0, pe)
      sp.set.at(sp.find(Nat.add(Nat.sub(n, p0), 1n), Bool.and(op.more(o), Nat.is_lt(idx, Nat.add(f0, op.len(o)))), o, v, p0, f0, 0n, 0n, 0n, 0n, idx, pe), v, n, mx, idx, cnt, pe)

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

# a * 2^k and a / 2, exactly, a number's exponent moved (a zero's stays 0):
# the estimate's numbers stay far from where a double's range ends, where
# this would have to round. The operations take any m and e, and round
# what they make; only fl.eq needs its numbers as they round them.
def fl.scale(a: F.Fl, +k: Nat) -> F.Fl:
  match a:
    case F.FNum{n, +m, +e}:
      F.FNum{n, m, Bool.pick(Nat, F.big.is_zero(m), 0n, Nat.add(e, k))}
    case F.FInf{n}:
      F.FInf{n}
    case F.FNaN{}:
      F.FNaN{}

def fl.halve(a: F.Fl) -> F.Fl:
  match a:
    case F.FNum{n, m, +e}:
      F.FNum{n, m, Nat.sub(e, 1n)}
    case F.FInf{n}:
      F.FInf{n}
    case F.FNaN{}:
      F.FNaN{}

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
# until z stops changing (same); y is 2^k, which x * y takes exactly
def sigma.go(fuel: Nat, same: Bool, +x: F.Fl, +k: Nat, +z: F.Fl) -> F.Fl:
  match fuel:
    case 0n:
      z
    case 1n+f:
      match same:
        case True{}:
          z
        case False{}:
          +x2 = F.fl.mul(fl.d(), x, x)
          +z2 = F.fl.add(fl.d(), z, fl.scale(x2, k))
          sigma.go(f, fl.eq(z, z2), x2, Nat.add(k, 1n), z2)

def sigma.of(one: Bool, +x: F.Fl) -> F.Fl:
  match one:
    case True{}:
      F.FInf{False{}}
    case False{}:
      sigma.go(4096n, False{}, x, 0n, x)

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

# z + c, c a count: a double as it is (the sum rounds), nothing for 0
def est.add(zero: Bool, +c: Nat, z: F.Fl) -> F.Fl:
  match zero:
    case True{}:
      z
    case False{}:
      F.fl.add(fl.d(), z, F.FNum{False{}, F.big.of(c), F.fl.eb()})

# z after the registers of values j down to 1: z + count, halved, each
def est.loop(j: Nat, +h: Hist, z: F.Fl) -> F.Fl:
  match j:
    case 0n:
      z
    case 1n++i:
      +c = hist.get(h, Nat.add(i, 1n))
      est.loop(i, h, fl.halve(est.add(Nat.is_eq(c, 0n), c, z)))

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

# n / m as a double, m = 2^14 registers (n below 2^48): exact
def fl.reg(+n: Nat) -> F.Fl:
  F.fl.round(F.fmt.d(), False{}, F.big.of(n), Nat.sub(F.fl.eb(), 14n), False{})

# the cardinality a histogram h of the registers gives (hllCount), as
# Ertl's new estimator takes it: x / m and m * x, m = 2^14, move x's
# exponent
def est(+h: Hist) -> W:
  +z1 = est.loop(50n, h, fl.scale(tau(fl.reg(Nat.sub(16384n, hist.get(h, 51n)))), 14n))
  +z = F.fl.add(fl.d(), z1, fl.scale(sigma(fl.reg(hist.get(h, 0n))), 14n))
  llround(F.fl.div(fl.d(), est.alpha(), z))

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
      AddS{flat(v), String.length(v), False{}, 0}
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

def count.sp.of(ok: Bool, h: Hist) -> Count:
  match ok:
    case True{}:
      CntNew{est(h)}
    case False{}:
      CntBad{}

def count.sp(r: Hist & Nat) -> Count:
  (h, idx) = r
  count.sp.of(Nat.is_eq(idx, 16384n), h)

def count.new(sparse: Bool, +v: String) -> Count:
  match sparse:
    case True{}:
      +f = flat(v)
      count.sp(hist.sp(Nat.mul(sp.most(f), 2n), 1n, 0n, 0, op.at(f, 16n, 0), f, 16n, 0n, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
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
# the maxima of the registers so far: while every HyperLogLog was sparse,
# the registers above 0, in order (as few as their VALs hold); once one
# was dense, all of them, as words; or an invalid sparse one came
# (hllMerge)
type Acc is Data:
  AccS{ps: List<&2, RV>}
  AccD{a: List<&2, U32>}
  AccBad{}

def acc.new() -> Acc:
  AccS{Nil{}}

# the registers of rev, the last first, before rest
def ps.onto(rev: List<&2, RV>, rest: List<&2, RV>) -> List<&2, RV>:
  match rev:
    case Nil{}:
      rest
    case Con{+x, r}:
      ps.onto(r, x <> rest)

# which of the first registers of a and b comes first: 0 a's (or b has
# none), 1 b's (or a has none), 2 both the same, 3 neither has one
def ps.at(+a: List<&2, RV>, +b: List<&2, RV>) -> Nat:
  match a b:
    case Con{RV{+i, v}, ra} Con{RV{+j, w}, rb}:
      Bool.pick(Nat, Nat.is_lt(i, j), 0n, Bool.pick(Nat, Nat.is_lt(j, i), 1n, 2n))
    case Con{x, ra} Nil{}:
      0n
    case Nil{} Con{y, rb}:
      1n
    case Nil{} Nil{}:
      3n

def rv.max(+x: RV, +y: RV) -> RV:
  match x y:
    case RV{+i, +v} RV{j, +w}:
      RV{i, Bool.pick(U32, U32.is_lt(v, w), w, v)}

# a and b merged in order of register, one in both at the larger value,
# after done (the last first); at: ps.at of a and b
def ps.max.go(k: Nat, at: Nat, +a: List<&2, RV>, +b: List<&2, RV>, done: List<&2, RV>) -> List<&2, RV>:
  match k:
    case 0n:
      ps.onto(done, Nil{})
    case 1n+q:
      match at:
        case 0n:
          match a:
            case Con{+x, ra}:
              ps.max.go(q, ps.at(ra, b), ra, b, x <> done)
            case Nil{}:
              ps.onto(done, b)
        case 1n:
          match b:
            case Con{+y, rb}:
              ps.max.go(q, ps.at(a, rb), a, rb, y <> done)
            case Nil{}:
              ps.onto(done, a)
        case 2n:
          match a b:
            case Con{+x, ra} Con{+y, rb}:
              ps.max.go(q, ps.at(ra, rb), ra, rb, rv.max(x, y) <> done)
            case _ _:
              ps.onto(done, Nil{})
        case _:
          ps.onto(done, Nil{})

def ps.max(+a: List<&2, RV>, +b: List<&2, RV>) -> List<&2, RV>:
  ps.max.go(32769n, ps.at(a, b), a, b, Nil{})

# the histogram of the registers of ps (in order, each above 0; n of
# them before ps), the others 0; at = 0: count the register of word g, d,
# then go on
def hist.ps(k: Nat, at: Nat, g: Nat, +d: U32, +ps: List<&2, RV>, +n: Nat, +h0: U32, +h1: U32, +h2: U32, +h3: U32, +h4: U32, +h5: U32, +h6: U32, +h7: U32, +h8: U32, +h9: U32, +h10: U32, +h11: U32, +h12: U32, +h13: U32, +h14: U32, +h15: U32, +h16: U32, +h17: U32, +h18: U32, +h19: U32, +h20: U32, +h21: U32, +h22: U32, +h23: U32, +h24: U32, +h25: U32) -> Hist:
  match k:
    case 0n:
      Hist{h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25}
    case 1n+q:
      match at:
        case 0n:
          match g:
            case 0n:
              hist.ps(q, 1n, 0n, d, ps, n, U32.add(h0, d), h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 1n:
              hist.ps(q, 1n, 0n, d, ps, n, h0, U32.add(h1, d), h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 2n:
              hist.ps(q, 1n, 0n, d, ps, n, h0, h1, U32.add(h2, d), h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 3n:
              hist.ps(q, 1n, 0n, d, ps, n, h0, h1, h2, U32.add(h3, d), h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 4n:
              hist.ps(q, 1n, 0n, d, ps, n, h0, h1, h2, h3, U32.add(h4, d), h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 5n:
              hist.ps(q, 1n, 0n, d, ps, n, h0, h1, h2, h3, h4, U32.add(h5, d), h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 6n:
              hist.ps(q, 1n, 0n, d, ps, n, h0, h1, h2, h3, h4, h5, U32.add(h6, d), h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 7n:
              hist.ps(q, 1n, 0n, d, ps, n, h0, h1, h2, h3, h4, h5, h6, U32.add(h7, d), h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 8n:
              hist.ps(q, 1n, 0n, d, ps, n, h0, h1, h2, h3, h4, h5, h6, h7, U32.add(h8, d), h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 9n:
              hist.ps(q, 1n, 0n, d, ps, n, h0, h1, h2, h3, h4, h5, h6, h7, h8, U32.add(h9, d), h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 10n:
              hist.ps(q, 1n, 0n, d, ps, n, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, U32.add(h10, d), h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 11n:
              hist.ps(q, 1n, 0n, d, ps, n, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, U32.add(h11, d), h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 12n:
              hist.ps(q, 1n, 0n, d, ps, n, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, U32.add(h12, d), h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 13n:
              hist.ps(q, 1n, 0n, d, ps, n, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, U32.add(h13, d), h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 14n:
              hist.ps(q, 1n, 0n, d, ps, n, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, U32.add(h14, d), h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 15n:
              hist.ps(q, 1n, 0n, d, ps, n, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, U32.add(h15, d), h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 16n:
              hist.ps(q, 1n, 0n, d, ps, n, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, U32.add(h16, d), h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case 17n:
              hist.ps(q, 1n, 0n, d, ps, n, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, U32.add(h17, d), h18, h19, h20, h21, h22, h23, h24, h25)
            case 18n:
              hist.ps(q, 1n, 0n, d, ps, n, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, U32.add(h18, d), h19, h20, h21, h22, h23, h24, h25)
            case 19n:
              hist.ps(q, 1n, 0n, d, ps, n, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, U32.add(h19, d), h20, h21, h22, h23, h24, h25)
            case 20n:
              hist.ps(q, 1n, 0n, d, ps, n, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, U32.add(h20, d), h21, h22, h23, h24, h25)
            case 21n:
              hist.ps(q, 1n, 0n, d, ps, n, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, U32.add(h21, d), h22, h23, h24, h25)
            case 22n:
              hist.ps(q, 1n, 0n, d, ps, n, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, U32.add(h22, d), h23, h24, h25)
            case 23n:
              hist.ps(q, 1n, 0n, d, ps, n, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, U32.add(h23, d), h24, h25)
            case 24n:
              hist.ps(q, 1n, 0n, d, ps, n, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, U32.add(h24, d), h25)
            case 25n:
              hist.ps(q, 1n, 0n, d, ps, n, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, U32.add(h25, d))
            case _:
              hist.ps(q, 1n, 0n, d, ps, n, h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
        case _:
          match ps:
            case Con{RV{i, +v}, r}:
              hist.ps(q, 0n, hist.g(v), hist.d(v, 1), r, Nat.add(n, 1n), h0, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25)
            case Nil{}:
              Hist{U32.add(h0, U32.from_nat(Nat.sub(16384n, n))), h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13, h14, h15, h16, h17, h18, h19, h20, h21, h22, h23, h24, h25}

def acc.sp.s(ok: Bool, +v: String, +ps: List<&2, RV>) -> Acc:
  match ok:
    case True{}:
      AccS{ps.max(ps, sp.pairs(sp.most(v), op.at(v, 16n, 0), v, 16n, 0n, 0))}
    case False{}:
      AccBad{}

def acc.sp.d(ok: Bool, +v: String, a: List<&2, U32>) -> Acc:
  match ok:
    case True{}:
      AccD{sp.words(v, a, 0)}
    case False{}:
      AccBad{}

def acc.of.s(sparse: Bool, +v: String, +ps: List<&2, RV>) -> Acc:
  match sparse:
    case True{}:
      +f = flat(v)
      acc.sp.s(sp.ok(f, 0), f, ps)
    case False{}:
      AccD{d.merge(v, ws.add(Nil{}, ps))}

def acc.of.d(sparse: Bool, +v: String, a: List<&2, U32>) -> Acc:
  match sparse:
    case True{}:
      +f = flat(v)
      acc.sp.d(sp.ok(f, 0), f, a)
    case False{}:
      AccD{d.merge(v, a)}

# a valid v merged in
def acc.add(st: Acc, +v: String) -> Acc:
  match st:
    case AccS{+ps}:
      acc.of.s(is_sparse(v), v, ps)
    case AccD{a}:
      acc.of.d(is_sparse(v), v, a)
    case AccBad{}:
      AccBad{}

# the cardinality of the maxima (hllCount of HLL_RAW)
def acc.count(a: Acc) -> W:
  match a:
    case AccS{+ps}:
      est(hist.ps(32770n, 1n, 0n, 0, ps, 0n, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    case AccD{w}:
      est(ws.hist(w))
    case AccBad{}:
      W{0, 0}

# PFMERGE
# -------

# v made dense with the registers a (its header kept, the encoding 0)
def merge.dense.of(+v: String, a: List<&2, U32>) -> String:
  String.take(v, 4n) ++ b1(0) ++ String.slice(v, 5n, 11n) ++ ws.enc(a)

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

# st after register j is set to x, where x is more than 0
def merge.lane.of(zero: Bool, +v: String, +n: Nat, +o: Nat, +f: Nat, +pe: U32, +j: Nat, +x: U32, +mx: Nat) -> MSt:
  match zero:
    case True{}:
      MS{v, n, o, f, pe}
    case False{}:
      merge.st(sp.set(v, n, mx, j, U32.to_nat(x), o, f, pe), v, n, pe)

def merge.lane(st: MSt, +j: Nat, +x: U32, +mx: Nat) -> MSt:
  match st:
    case MS{+v, +n, +o, +f, +pe}:
      merge.lane.of(U32.is_eq(x, 0), v, n, o, f, pe, j, x, mx)
    case MD{v}:
      MD{v}

# the value as the sets left it, dense with the maxima all when one made
# it turn dense, which are as much as every register in it (every set
# before it held, as a set that fails to find its register leaves the
# opcodes too short to turn dense)
def merge.fin(st: MSt, +all: List<&2, RV>) -> String:
  match st:
    case MS{v, n, o, f, pe}:
      v
    case MD{+v}:
      merge.dense.of(v, ws.add(Nil{}, all))

# the registers of ps (in order, each above 0; all of them: all) set in
# turn, hllSparseSet
def merge.ps(k: Nat, st: MSt, +ps: List<&2, RV>, +all: List<&2, RV>, +mx: Nat) -> String:
  match k:
    case 0n:
      merge.fin(st, all)
    case 1n+q:
      match ps:
        case Nil{}:
          merge.fin(st, all)
        case Con{RV{+i, +x}, r}:
          merge.ps(q, merge.lane(st, i, x, mx), r, all, mx)

def merge.dense(m: Maybe<&2, String>, a: List<&2, U32>) -> Maybe<&2, String>:
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
def merge(+v: String, a: Acc, +mx: Nat) -> Maybe<&2, String>:
  match a:
    case AccD{w}:
      merge.dense(merge.to(is_sparse(v), v), w)
    case AccS{+ps}:
      Some{stale(merge.ps(16385n, MS{flat(v), String.length(v), 16n, 0n, 0}, ps, ps, mx))}
    case AccBad{}:
      None{}

# PFSELFTEST
# ----------
# Redis's checks of its own implementation, on fewer cases: the dense
# registers of two sets of random values (Redis: 1000), read back each;
# and 10,000 elements added to a dense HyperLogLog and to a sparse one
# (Redis: ten million), whose counts at 1, 10, 100, 1000 and 10,000 must
# agree, stay within 6 standard errors of the truth (1 at 10), and the
# sparse one sparse below hm / 2 elements, hm the bytes it may grow to
# (hll-sparse-max-bytes, as Redis's sparse one grows to it).
# Random numbers come from xorshift with a fixed seed: Redis's rand()
# gives other ones, which the checks pass all the same.

def st.rand(+x: U32) -> U32:
  +a = U32.xor(x, U32.shln(x, 13n))
  +b = U32.xor(a, U32.shrn(a, 17n))
  U32.xor(b, U32.shln(b, 5n))

# k words of registers set to random values from x, each the low six
# bits of the next, after the words of done (the last first)
def st.words(k: Nat, +x: U32, done: List<&2, U32>) -> List<&2, U32>:
  match k:
    case 0n:
      ws.onto(done, Nil{})
    case 1n+q:
      +x1 = st.rand(x)
      +x2 = st.rand(x1)
      +x3 = st.rand(x2)
      st.words(q, st.rand(x3), w4.of(U32.and(x, 63), U32.and(x1, 63), U32.and(x2, 63), U32.and(x3, 63)) <> done)

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
  st.cmp(d.regs(st.dense0() ++ ws.enc(st.words(4096n, x, Nil{}))), x, 0n, False{}, 0n, 0n, 0n)

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

def st.add1(+v: String, +e: String, +hm: Nat) -> String:
  st.v(add(False{}, v, hm, [e]))

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

# the checks at checkpoint j: the sparse one sparse below hm / 2, the
# counts agreeing, the dense one's within ceil(1.04 / 128 * 6 * j) of j
# (1 at 10)
def st.check(+j: Nat, +d: String, +sv: String, +hm: Nat) -> Maybe<&2, String>:
  +cd = st.cnt(d)
  +err = st.diff(j, cd)
  +mx = Bool.pick(Nat, Nat.is_eq(j, 10n), 1n, Nat.div(Nat.add(Nat.mul(624n, j), 12799n), 12800n))
  Bool.pick(Maybe<&2, String>, Bool.and(Nat.is_lt(j, Nat.div(hm, 2n)), Bool.not(is_sparse(sv))), Some{"TESTFAILED sparse encoding not used"},
  Bool.pick(Maybe<&2, String>, Nat.is_ne(cd, st.cnt(sv)), Some{"TESTFAILED dense/sparse disagree"},
  Bool.pick(Maybe<&2, String>, Nat.is_lt(mx, err), Some{"TESTFAILED Too big error. card:" ++ Nat.show(j) ++ " abserr:" ++ Nat.show(err)}, None{})))

# elements j on, k of them, added to the dense d and the sparse sv: err,
# what the last checkpoint found; chk, whether j is the next one (cp)
def st.add(k: Nat, err: Maybe<&2, String>, chk: Bool, +j: Nat, +d: String, +sv: String, +cp: Nat, +hm: Nat) -> Maybe<&2, String>:
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
              st.add(q, None{}, Nat.is_eq(Nat.add(j, 1n), cp), Nat.add(j, 1n), st.add1(d, e, hm), st.add1(sv, e, hm), cp, hm)
            case True{}:
              +e = st.ele(j)
              +d2 = st.add1(d, e, hm)
              +s2 = st.add1(sv, e, hm)
              +cp2 = Nat.mul(cp, 10n)
              st.add(q, st.check(j, d2, s2, hm), Nat.is_eq(Nat.add(j, 1n), cp2), Nat.add(j, 1n), d2, s2, cp2, hm)

# PFSELFTEST with hll-sparse-max-bytes at hm: none when every check
# passes, else what failed
def selftest(+hm: Nat) -> Maybe<&2, String>:
  st.or(st.or(st.cycle(2463534242), st.cycle(88675123)), st.add(10000n, None{}, True{}, 1n, st.dense0() ++ zeros(12288n), fresh(), 1n, hm))
