# float.bend: binary floating point in software, as Redis 7.0.15 computes
# it on x86-64: C's double (53 bits of precision) for the scores of sorted
# sets, and x87's long double (64 bits) for INCRBYFLOAT and HINCRBYFLOAT.
# Bend has no 64-bit float, and a Nat stops at 2^48, so a number is a sign,
# a big integer m and an exponent e (m * 2^e), and each operation rounds
# its exact result to the nearest number of the format, to the even one on
# a tie, as the FPU does in its default mode. Text comes in as glibc's
# strtod and strtold read it (decimal, hex, inf and infinity, nan) and goes
# out as its printf writes "%.17g" and "%.17Lf": exactly, from the exact
# decimal value of the number.

import Base

# Big integers
# ------------
# a nonnegative integer as its limbs of 24 bits, the least significant
# first and the last one not 0 (0 is Nil): a product of two limbs, plus a
# limb, stays below 2^48, where a Nat stops

# rest with l below it, the last limb kept nonzero (0 below 0 is 0)
def big.con.if(z: Bool, +l: Nat, rest: List<&2, Nat>) -> List<&2, Nat>:
  match z rest:
    case True{} Nil{}:
      Nil{}
    case False{} Nil{}:
      [l]
    case _ Con{h, t}:
      Con{l, Con{h, t}}

def big.con(+l: Nat, rest: List<&2, Nat>) -> List<&2, Nat>:
  big.con.if(Nat.is_eq(l, 0n), l, rest)

# n, below 2^48
def big.of(+n: Nat) -> List<&2, Nat>:
  big.con(Nat.mod(n, 16777216n), big.con(Nat.div(n, 16777216n), Nil{}))

def big.is_zero(a: List<&2, Nat>) -> Bool:
  match a:
    case Nil{}:
      True{}
    case Con{h, t}:
      False{}

def big.add.go(a: List<&2, Nat>, b: List<&2, Nat>, +c: Nat) -> List<&2, Nat>:
  match a b:
    case Nil{} Nil{}:
      big.of(c)
    case Con{+x, xs} Nil{}:
      +s = Nat.add(x, c)
      big.con(Nat.mod(s, 16777216n), big.add.go(xs, Nil{}, Nat.div(s, 16777216n)))
    case Nil{} Con{+y, ys}:
      +s = Nat.add(y, c)
      big.con(Nat.mod(s, 16777216n), big.add.go(Nil{}, ys, Nat.div(s, 16777216n)))
    case Con{+x, xs} Con{+y, ys}:
      +s = Nat.add(Nat.add(x, y), c)
      big.con(Nat.mod(s, 16777216n), big.add.go(xs, ys, Nat.div(s, 16777216n)))

def big.add(a: List<&2, Nat>, b: List<&2, Nat>) -> List<&2, Nat>:
  big.add.go(a, b, 0n)

# a - b, for a at least b
def big.sub.go(a: List<&2, Nat>, b: List<&2, Nat>, +br: Nat) -> List<&2, Nat>:
  match a b:
    case Con{+x, xs} Con{+y, ys}:
      +d = Nat.add(y, br)
      +ok = Nat.is_le(d, x)
      big.con(Bool.pick(Nat, ok, Nat.sub(x, d), Nat.sub(Nat.add(x, 16777216n), d)), big.sub.go(xs, ys, Bool.pick(Nat, ok, 0n, 1n)))
    case Con{+x, xs} Nil{}:
      +ok = Nat.is_le(br, x)
      big.con(Bool.pick(Nat, ok, Nat.sub(x, br), Nat.sub(Nat.add(x, 16777216n), br)), big.sub.go(xs, Nil{}, Bool.pick(Nat, ok, 0n, 1n)))
    case Nil{} _:
      Nil{}

def big.sub(a: List<&2, Nat>, b: List<&2, Nat>) -> List<&2, Nat>:
  big.sub.go(a, b, 0n)

# c, unless it is EQ: then acc
def big.cmp.limb(c: Cmp, acc: Cmp) -> Cmp:
  match c:
    case LT{}:
      LT{}
    case EQ{}:
      acc
    case GT{}:
      GT{}

def big.cmp.go(a: List<&2, Nat>, b: List<&2, Nat>, acc: Cmp) -> Cmp:
  match a b:
    case Nil{} Nil{}:
      acc
    case Nil{} Con{y, ys}:
      LT{}
    case Con{x, xs} Nil{}:
      GT{}
    case Con{+x, xs} Con{+y, ys}:
      big.cmp.go(xs, ys, big.cmp.limb(Nat.cmp(x, y), acc))

def big.cmp(a: List<&2, Nat>, b: List<&2, Nat>) -> Cmp:
  big.cmp.go(a, b, EQ{})

# 2^b of bit b of k (1 when the bit is 0)
def nat.pow2.bit(+k: Nat, +b: Nat, +v: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_eq(Nat.mod(Nat.div(k, b), 2n), 1n), v, 1n)

def nat.pow2.of(few: Bool, +k: Nat) -> Nat:
  match few:
    case True{}:
      Nat.pow(2n, k)
    case False{}:
      Nat.mul(Nat.mul(Nat.mul(nat.pow2.bit(k, 1n, 2n), nat.pow2.bit(k, 2n, 4n)), Nat.mul(nat.pow2.bit(k, 4n, 16n), nat.pow2.bit(k, 8n, 256n))), Nat.mul(nat.pow2.bit(k, 16n, 65536n), nat.pow2.bit(k, 32n, Nat.mul(65536n, 65536n))))

# 2^k, k below 64: Nat.pow multiplies k times, which is the cheaper way
# below 12; past it, the six bits of k at once
def nat.pow2(+k: Nat) -> Nat:
  nat.pow2.of(Nat.is_lt(k, 12n), k)

# a * k + c, for k and c below 2^24
def big.mul_small(a: List<&2, Nat>, +k: Nat, +c: Nat) -> List<&2, Nat>:
  match a:
    case Nil{}:
      big.of(c)
    case Con{+x, xs}:
      +t = Nat.add(Nat.mul(x, k), c)
      big.con(Nat.mod(t, 16777216n), big.mul_small(xs, k, Nat.div(t, 16777216n)))

def big.mul(a: List<&2, Nat>, +b: List<&2, Nat>) -> List<&2, Nat>:
  match a:
    case Nil{}:
      Nil{}
    case Con{+x, xs}:
      big.add(big.mul_small(b, x, 0n), big.con(0n, big.mul(xs, b)))

# n zero limbs below a (a not 0)
def big.zeros(n: Nat, a: List<&2, Nat>) -> List<&2, Nat>:
  match n:
    case 0n:
      a
    case 1n+p:
      Con{0n, big.zeros(p, a)}

def big.shl.if(z: Bool, +a: List<&2, Nat>, +n: Nat) -> List<&2, Nat>:
  match z:
    case True{}:
      Nil{}
    case False{}:
      big.zeros(Nat.div(n, 24n), big.mul_small(a, nat.pow2(Nat.mod(n, 24n)), 0n))

# a * 2^n
def big.shl(+a: List<&2, Nat>, +n: Nat) -> List<&2, Nat>:
  big.shl.if(big.is_zero(a), a, n)

# a's quotient and remainder by k (k from 1 to 2^24): the limbs from the
# most significant, each with the remainder so far above it (below 2^48)
def big.dm.go(rev: List<&2, Nat>, +k: Nat, +r: Nat, acc: List<&2, Nat>) -> List<&2, Nat> & Nat:
  match rev:
    case Nil{}:
      (acc, r)
    case Con{+x, xs}:
      +t = Nat.add(Nat.mul(r, 16777216n), x)
      big.dm.go(xs, k, Nat.mod(t, k), big.con(Nat.div(t, k), acc))

def big.divmod_small(a: List<&2, Nat>, +k: Nat) -> List<&2, Nat> & Nat:
  big.dm.go(List.reverse(&2, Nat, a), k, 0n, Nil{})

def big.fst(qr: List<&2, Nat> & Nat) -> List<&2, Nat>:
  (q, r) = qr
  q

# the bits of n, below 2^24 (0 for 0)
def nat.bl6(+n: Nat) -> Nat:
  Nat.add(Nat.add(Bool.pick(Nat, Nat.is_le(1n, n), 1n, 0n), Bool.pick(Nat, Nat.is_le(2n, n), 1n, 0n)),
    Nat.add(Nat.add(Bool.pick(Nat, Nat.is_le(4n, n), 1n, 0n), Bool.pick(Nat, Nat.is_le(8n, n), 1n, 0n)),
      Nat.add(Bool.pick(Nat, Nat.is_le(16n, n), 1n, 0n), Bool.pick(Nat, Nat.is_le(32n, n), 1n, 0n))))

def nat.bl12.if(lo: Bool, +n: Nat) -> Nat:
  match lo:
    case True{}:
      nat.bl6(n)
    case False{}:
      Nat.add(6n, nat.bl6(Nat.div(n, 64n)))

def nat.bl12(+n: Nat) -> Nat:
  nat.bl12.if(Nat.is_lt(n, 64n), n)

def nat.bl.if(lo: Bool, +n: Nat) -> Nat:
  match lo:
    case True{}:
      nat.bl12(n)
    case False{}:
      Nat.add(12n, nat.bl12(Nat.div(n, 4096n)))

def nat.bl(+n: Nat) -> Nat:
  nat.bl.if(Nat.is_lt(n, 4096n), n)

def big.bitlen.go(xs: List<&2, Nat>, +x: Nat, +k: Nat) -> Nat:
  match xs:
    case Nil{}:
      Nat.add(Nat.mul(k, 24n), nat.bl(x))
    case Con{+y, ys}:
      big.bitlen.go(ys, y, Nat.add(k, 1n))

# the bits of a (0 for 0)
def big.bitlen(a: List<&2, Nat>) -> Nat:
  match a:
    case Nil{}:
      0n
    case Con{+x, xs}:
      big.bitlen.go(xs, x, 0n)

# bit i of a: bit r of its limb q
def big.bit.go(a: List<&2, Nat>, +q: Nat, +r: Nat) -> Bool:
  match a:
    case Nil{}:
      False{}
    case Con{+x, xs}:
      match q:
        case 0n:
          Nat.is_eq(Nat.mod(Nat.div(x, nat.pow2(r)), 2n), 1n)
        case 1n+p:
          big.bit.go(xs, p, r)

def big.bit(a: List<&2, Nat>, +i: Nat) -> Bool:
  big.bit.go(a, Nat.div(i, 24n), Nat.mod(i, 24n))

# whether a's lowest q * 24 + r bits are not all 0
def big.low.go(a: List<&2, Nat>, +q: Nat, +r: Nat) -> Bool:
  match a:
    case Nil{}:
      False{}
    case Con{+x, xs}:
      match q:
        case 0n:
          Nat.is_ne(Nat.mod(x, nat.pow2(r)), 0n)
        case 1n+p:
          Bool.or(Nat.is_ne(x, 0n), big.low.go(xs, p, r))

def big.low_nz(a: List<&2, Nat>, +n: Nat) -> Bool:
  big.low.go(a, Nat.div(n, 24n), Nat.mod(n, 24n))

# a divided by 2^n, rounded down
def big.shr(a: List<&2, Nat>, +n: Nat) -> List<&2, Nat>:
  big.fst(big.divmod_small(List.drop(&2, Nat, a, Nat.div(n, 24n)), nat.pow2(Nat.mod(n, 24n))))

def big.is_odd(a: List<&2, Nat>) -> Bool:
  match a:
    case Nil{}:
      False{}
    case Con{+x, xs}:
      Nat.is_eq(Nat.mod(x, 2n), 1n)

# the bits of x below its lowest 1 (x not 0, below 2^24)
def nat.tz(fuel: Nat, +x: Nat, +n: Nat) -> Nat:
  match fuel:
    case 0n:
      n
    case 1n+f:
      Bool.pick(Nat, Nat.is_eq(Nat.mod(x, 2n), 0n), nat.tz(f, Nat.div(x, 2n), Nat.add(n, 1n)), n)

# the bits of a below its lowest 1 (0 for 0)
def big.tz.go(a: List<&2, Nat>, +k: Nat) -> Nat:
  match a:
    case Nil{}:
      0n
    case Con{+x, xs}:
      Bool.pick(Nat, Nat.is_eq(x, 0n), big.tz.go(xs, Nat.add(k, 24n)), Nat.add(k, nat.tz(24n, x, 0n)))

def big.tz(a: List<&2, Nat>) -> Nat:
  big.tz.go(a, 0n)

# a * k^n, k^7 below 2^24 (k at most 10): k^7 at a time
def big.mul_pow.go(q: Nat, a: List<&2, Nat>, +k7: Nat, +k: Nat, +r: Nat) -> List<&2, Nat>:
  match q:
    case 0n:
      big.mul_small(a, Nat.pow(k, r), 0n)
    case 1n+p:
      big.mul_pow.go(p, big.mul_small(a, k7, 0n), k7, k, r)

def big.mul_pow(a: List<&2, Nat>, +k: Nat, +n: Nat) -> List<&2, Nat>:
  big.mul_pow.go(Nat.div(n, 7n), a, Nat.pow(k, 7n), k, Nat.mod(n, 7n))

def big.div10.fin(qr: List<&2, Nat> & Nat, +st: Bool) -> List<&2, Nat> & Bool:
  (a, rem) = qr
  (a, Bool.or(st, Nat.is_ne(rem, 0n)))

# a divided by 10^n, rounded down, and whether it lost anything (st):
# 10^7 at a time, each a limb
def big.div10.go(q: Nat, qr: List<&2, Nat> & Nat, +st: Bool, +r: Nat) -> List<&2, Nat> & Bool:
  match q:
    case 0n:
      (a, rem) = qr
      big.div10.fin(big.divmod_small(a, Nat.pow(10n, r)), Bool.or(st, Nat.is_ne(rem, 0n)))
    case 1n+p:
      (a, rem) = qr
      big.div10.go(p, big.divmod_small(a, 10000000n), Bool.or(st, Nat.is_ne(rem, 0n)), r)

def big.div10(a: List<&2, Nat>, +n: Nat) -> List<&2, Nat> & Bool:
  big.div10.go(Nat.div(n, 7n), (a, 0n), False{}, Nat.mod(n, 7n))

# a's decimal digits ("0" for 0): 10^7 at a time, from the lowest
def big.dec.go(fuel: Nat, qr: List<&2, Nat> & Nat, acc: String) -> String:
  match fuel:
    case 0n:
      (q, r) = qr
      Nat.show(r) ++ acc
    case 1n+f:
      (q, +r) = qr
      match q:
        case Nil{}:
          Nat.show(r) ++ acc
        case Con{h, t}:
          +d = Nat.show(r)
          big.dec.go(f, big.divmod_small(Con{h, t}, 10000000n), String.repeat("0", Nat.sub(7n, String.length(d))) ++ d ++ acc)

def big.to_dec(+a: List<&2, Nat>) -> String:
  big.dec.go(Nat.add(Nat.mul(List.length(&2, Nat, a), 2n), 2n), big.divmod_small(a, 10000000n), "")

# a's hex digits, lowercase ("0" for 0): a limb is six of them
def hex.digit(+d: Nat) -> String:
  Bool.pick(String, Nat.is_lt(d, 10n), Nat.show(d), String.from_list([Chr{U32.from_nat(Nat.add(d, 87n))}]))

def hex.of(fuel: Nat, +n: Nat, acc: String) -> String:
  match fuel:
    case 0n:
      acc
    case 1n+f:
      +a2 = hex.digit(Nat.mod(n, 16n)) ++ acc
      Bool.pick(String, Nat.is_lt(n, 16n), a2, hex.of(f, Nat.div(n, 16n), a2))

def hex.limbs(xs: List<&2, Nat>, +x: Nat, acc: String) -> String:
  match xs:
    case Nil{}:
      hex.of(6n, x, "") ++ acc
    case Con{+y, ys}:
      +h = hex.of(6n, x, "")
      hex.limbs(ys, y, String.repeat("0", Nat.sub(6n, String.length(h))) ++ h ++ acc)

def big.to_hex(a: List<&2, Nat>) -> String:
  match a:
    case Nil{}:
      "0"
    case Con{+x, xs}:
      hex.limbs(xs, x, "")

# Numbers
# -------

# a finite number m * 2^(e - 2^40) (m Nil: a zero, with its sign, its e
# 0), an infinity, or no number. A number of a format (Fmt) has m below
# 2^p.
type Fl is Data:
  FNum{neg: Bool, m: List<&2, Nat>, e: Nat}
  FInf{neg: Bool}
  FNaN{}

# a format: p bits of precision, a leading bit's exponent from -emin
# (with fewer bits below it, down to -emin - p + 1: the subnormal
# numbers) to emax. A format holds small numbers only, and a zero's e is
# 0: the proofs (PROOF.bend) meet these where a write of a float stops on
# a value they do not know, and a Nat there runs as Base defines it, one
# step per unit.
type Fmt is Data:
  Fmt{p: Nat, emin: Nat, emax: Nat}

def fl.eb() -> Nat:
  Nat.mul(1048576n, 1048576n)

# C's double on x86-64
def fmt.d() -> Fmt:
  Fmt{53n, 1022n, 1023n}

# x87's long double: 64 bits, its exponents of 15 bits
def fmt.ld() -> Fmt:
  Fmt{64n, 16382n, 16383n}

# C's float on x86-64 (MEMORY STATS's ratios)
def fmt.f() -> Fmt:
  Fmt{24n, 126n, 127n}

def fmt.p(f: Fmt) -> Nat:
  match f:
    case Fmt{p, emin, emax}:
      p

def fl.zero(+neg: Bool) -> Fl:
  FNum{neg, Nil{}, 0n}

def fl.fin.if(z: Bool, over: Bool, +neg: Bool, q: List<&2, Nat>, +lsb: Nat) -> Fl:
  match z:
    case True{}:
      fl.zero(neg)
    case False{}:
      match over:
        case True{}:
          FInf{neg}
        case False{}:
          FNum{neg, q, lsb}

# q * 2^lsb, already rounded: an infinity past emax, a zero for 0
def fl.fin(+f: Fmt, +neg: Bool, +q: List<&2, Nat>, +lsb: Nat) -> Fl:
  match f:
    case Fmt{p, emin, +emax}:
      fl.fin.if(big.is_zero(q), Nat.is_lt(Nat.add(fl.eb(), emax), Nat.sub(Nat.add(lsb, big.bitlen(q)), 1n)), neg, q, lsb)

def fl.round.carry(c: Bool, +f: Fmt, +neg: Bool, +q: List<&2, Nat>, +lsb: Nat) -> Fl:
  match c:
    case True{}:
      fl.fin(f, neg, big.shr(q, 1n), Nat.add(lsb, 1n))
    case False{}:
      fl.fin(f, neg, q, lsb)

def fl.round.up(up: Bool, +f: Fmt, +neg: Bool, +q: List<&2, Nat>, +lsb: Nat) -> Fl:
  match up:
    case False{}:
      fl.fin(f, neg, q, lsb)
    case True{}:
      +q1 = big.add(q, [1n])
      fl.round.carry(Nat.is_lt(fmt.p(f), big.bitlen(q1)), f, neg, q1, lsb)

def fl.round.go(exact: Bool, +f: Fmt, +neg: Bool, +m: List<&2, Nat>, +e: Nat, +lsb: Nat, +sticky: Bool) -> Fl:
  match exact:
    case True{}:
      fl.fin(f, neg, big.shl(m, Nat.sub(e, lsb)), lsb)
    case False{}:
      +s = Nat.sub(lsb, e)
      +q = big.shr(m, s)
      +half = big.bit(m, Nat.sub(s, 1n))
      +rest = Bool.or(sticky, big.low_nz(m, Nat.sub(s, 1n)))
      fl.round.up(Bool.and(half, Bool.or(rest, big.is_odd(q))), f, neg, q, lsb)

def fl.round.of(+f: Fmt, +neg: Bool, +m: List<&2, Nat>, +e: Nat, +sticky: Bool, +lead: Nat) -> Fl:
  match f:
    case Fmt{+p, +emin, emax}:
      +lsb = Nat.sub(Nat.add(Nat.max(lead, Nat.sub(fl.eb(), emin)), 1n), p)
      fl.round.go(Nat.is_le(lsb, e), f, neg, m, e, lsb, sticky)

# m * 2^e, and below it something more than 0 when sticky, rounded to
# the nearest number of f, to the even one on a tie
def fl.round(+f: Fmt, +neg: Bool, +m: List<&2, Nat>, +e: Nat, +sticky: Bool) -> Fl:
  fl.round.of(f, neg, m, e, sticky, Nat.sub(Nat.add(e, big.bitlen(m)), 1n))

# x as a number of f, rounded to the nearest one (exact when f holds x:
# a float as the double it is)
def fl.to.num(z: Bool, +f: Fmt, +neg: Bool, +m: List<&2, Nat>, +e: Nat) -> Fl:
  match z:
    case True{}:
      fl.zero(neg)
    case False{}:
      fl.round(f, neg, m, e, False{})

def fl.to(+f: Fmt, x: Fl) -> Fl:
  match x:
    case FNum{+neg, +m, +e}:
      fl.to.num(big.is_zero(m), f, neg, m, e)
    case FInf{neg}:
      FInf{neg}
    case FNaN{}:
      FNaN{}

# Arithmetic
# ----------

def fl.add.diff(c: Cmp, +f: Fmt, +na: Bool, +a: List<&2, Nat>, +nb: Bool, +b: List<&2, Nat>, +e: Nat) -> Fl:
  match c:
    case EQ{}:
      fl.zero(False{})
    case GT{}:
      fl.round(f, na, big.sub(a, b), e, False{})
    case LT{}:
      fl.round(f, nb, big.sub(b, a), e, False{})

def fl.add.same(same: Bool, +f: Fmt, +na: Bool, +a: List<&2, Nat>, +nb: Bool, +b: List<&2, Nat>, +e: Nat) -> Fl:
  match same:
    case True{}:
      fl.round(f, na, big.add(a, b), e, False{})
    case False{}:
      fl.add.diff(big.cmp(a, b), f, na, a, nb, b, e)

# m * 2^e plus (or, when opp, minus) a number below a unit of m's lowest
# bit p + 3 places further down: only a sticky bit of it is left
def fl.add.tiny(opp: Bool, +f: Fmt, +n: Bool, +m: List<&2, Nat>, +e: Nat) -> Fl:
  match opp:
    case True{}:
      +k = Nat.add(fmt.p(f), 3n)
      fl.round(f, n, big.sub(big.shl(m, k), [1n]), Nat.sub(e, k), True{})
    case False{}:
      +k = Nat.add(fmt.p(f), 3n)
      fl.round(f, n, big.shl(m, k), Nat.sub(e, k), True{})

def fl.add.num.if(bsmall: Bool, asmall: Bool, +f: Fmt, +na: Bool, +ma: List<&2, Nat>, +ea: Nat, +nb: Bool, +mb: List<&2, Nat>, +eb: Nat) -> Fl:
  match bsmall:
    case True{}:
      fl.add.tiny(Bool.xor(na, nb), f, na, ma, ea)
    case False{}:
      match asmall:
        case True{}:
          fl.add.tiny(Bool.xor(na, nb), f, nb, mb, eb)
        case False{}:
          +e = Nat.min(ea, eb)
          fl.add.same(Bool.not(Bool.xor(na, nb)), f, na, big.shl(ma, Nat.sub(ea, e)), nb, big.shl(mb, Nat.sub(eb, e)), e)

# two numbers, neither 0: one of them far below the other's lowest bit
# is a sticky bit, else both are put on the lower exponent and added
def fl.add.num(+f: Fmt, +na: Bool, +ma: List<&2, Nat>, +ea: Nat, +nb: Bool, +mb: List<&2, Nat>, +eb: Nat) -> Fl:
  +k = Nat.add(fmt.p(f), 3n)
  fl.add.num.if(Nat.is_le(Nat.add(Nat.add(eb, big.bitlen(mb)), k), ea), Nat.is_le(Nat.add(Nat.add(ea, big.bitlen(ma)), k), eb), f, na, ma, ea, nb, mb, eb)

def fl.add.z(za: Bool, zb: Bool, +f: Fmt, +na: Bool, +ma: List<&2, Nat>, +ea: Nat, +nb: Bool, +mb: List<&2, Nat>, +eb: Nat) -> Fl:
  match za zb:
    case True{} True{}:
      fl.zero(Bool.and(na, nb))
    case True{} False{}:
      FNum{nb, mb, eb}
    case False{} True{}:
      FNum{na, ma, ea}
    case False{} False{}:
      fl.add.num(f, na, ma, ea, nb, mb, eb)

# a + b in f, as IEEE 754 adds: inf - inf and NaN give NaN, x - x gives +0
def fl.add(+f: Fmt, a: Fl, b: Fl) -> Fl:
  match a b:
    case FNaN{} _:
      FNaN{}
    case _ FNaN{}:
      FNaN{}
    case FInf{+na} FInf{+nb}:
      Bool.pick(Fl, Bool.xor(na, nb), FNaN{}, FInf{na})
    case FInf{+na} FNum{nb, mb, eb}:
      FInf{na}
    case FNum{na, ma, ea} FInf{+nb}:
      FInf{nb}
    case FNum{+na, +ma, +ea} FNum{+nb, +mb, +eb}:
      fl.add.z(big.is_zero(ma), big.is_zero(mb), f, na, ma, ea, nb, mb, eb)

def fl.mul.z(z: Bool, +f: Fmt, +n: Bool, +ma: List<&2, Nat>, +ea: Nat, +mb: List<&2, Nat>, +eb: Nat) -> Fl:
  match z:
    case True{}:
      fl.zero(n)
    case False{}:
      fl.round(f, n, big.mul(ma, mb), Nat.sub(Nat.add(ea, eb), fl.eb()), False{})

# a * b in f: inf * 0 and NaN give NaN
def fl.mul(+f: Fmt, a: Fl, b: Fl) -> Fl:
  match a b:
    case FNaN{} _:
      FNaN{}
    case _ FNaN{}:
      FNaN{}
    case FInf{+na} FInf{+nb}:
      FInf{Bool.xor(na, nb)}
    case FInf{+na} FNum{+nb, +mb, eb}:
      Bool.pick(Fl, big.is_zero(mb), FNaN{}, FInf{Bool.xor(na, nb)})
    case FNum{+na, +ma, ea} FInf{+nb}:
      Bool.pick(Fl, big.is_zero(ma), FNaN{}, FInf{Bool.xor(na, nb)})
    case FNum{+na, +ma, +ea} FNum{+nb, +mb, +eb}:
      fl.mul.z(Bool.or(big.is_zero(ma), big.is_zero(mb)), f, Bool.xor(na, nb), ma, ea, mb, eb)

# Division and square roots, as HyperLogLog's estimate takes them
# (hll.bend): the exact quotient or root of the numbers' big integers,
# with p + 3 bits at least, rounded with what is left below it as a
# sticky bit.

def cmp.ge(c: Cmp) -> Bool:
  match c:
    case LT{}:
      False{}
    case EQ{}:
      True{}
    case GT{}:
      True{}

# a's quotient q and remainder r by b (b not 0), a bit of a at a time
# from its top (k bits of a left to bring down), after the step the last
# one took: ge, whether r with the last bit brought down is at least b
def big.dm.bits(k: Nat, +ge: Bool, +a: List<&2, Nat>, +b: List<&2, Nat>, +q: List<&2, Nat>, +r: List<&2, Nat>) -> List<&2, Nat> & List<&2, Nat>:
  match k:
    case 0n:
      (Bool.pick(List<&2, Nat>, ge, big.add(big.shl(q, 1n), [1n]), big.shl(q, 1n)), Bool.pick(List<&2, Nat>, ge, big.sub(r, b), r))
    case 1n++i:
      +q1 = Bool.pick(List<&2, Nat>, ge, big.add(big.shl(q, 1n), [1n]), big.shl(q, 1n))
      +r1 = big.add(big.shl(Bool.pick(List<&2, Nat>, ge, big.sub(r, b), r), 1n), Bool.pick(List<&2, Nat>, big.bit(a, i), [1n], Nil{}))
      big.dm.bits(i, cmp.ge(big.cmp(r1, b)), a, b, q1, r1)

def big.divmod(+a: List<&2, Nat>, +b: List<&2, Nat>) -> List<&2, Nat> & List<&2, Nat>:
  big.dm.bits(big.bitlen(a), False{}, a, b, Nil{}, Nil{})

# a's square root s, rounded down, and the remainder a - s^2: two bits of
# a at a time from its top (j pairs left), after the step the last one
# took: ge, whether r is at least t (4s + 1)
def big.sq.bits(j: Nat, +ge: Bool, +a: List<&2, Nat>, +s: List<&2, Nat>, +r: List<&2, Nat>, +t: List<&2, Nat>) -> List<&2, Nat> & List<&2, Nat>:
  match j:
    case 0n:
      (Bool.pick(List<&2, Nat>, ge, big.add(big.shl(s, 1n), [1n]), big.shl(s, 1n)), Bool.pick(List<&2, Nat>, ge, big.sub(r, t), r))
    case 1n++i:
      +s1 = Bool.pick(List<&2, Nat>, ge, big.add(big.shl(s, 1n), [1n]), big.shl(s, 1n))
      +two = Nat.add(Bool.pick(Nat, big.bit(a, Nat.add(Nat.mul(i, 2n), 1n)), 2n, 0n), Bool.pick(Nat, big.bit(a, Nat.mul(i, 2n)), 1n, 0n))
      +r1 = big.add(big.shl(Bool.pick(List<&2, Nat>, ge, big.sub(r, t), r), 2n), big.of(two))
      +t1 = big.add(big.shl(s1, 2n), [1n])
      big.sq.bits(i, cmp.ge(big.cmp(r1, t1)), a, s1, r1, t1)

def big.isqrt(+a: List<&2, Nat>) -> List<&2, Nat> & List<&2, Nat>:
  big.sq.bits(Nat.div(Nat.add(big.bitlen(a), 1n), 2n), False{}, a, Nil{}, Nil{}, Nil{})

# (ma * 2^ea) / (mb * 2^eb), neither 0: ma shifted up by k so that the
# quotient has p + 3 bits at least
def fl.div.qr(qr: List<&2, Nat> & List<&2, Nat>, +f: Fmt, +n: Bool, +e: Nat) -> Fl:
  (q, r) = qr
  fl.round(f, n, q, e, Bool.not(big.is_zero(r)))

def fl.div.num(+f: Fmt, +n: Bool, +ma: List<&2, Nat>, +ea: Nat, +mb: List<&2, Nat>, +eb: Nat) -> Fl:
  +k = Nat.add(Nat.add(fmt.p(f), 3n), Nat.sub(big.bitlen(mb), big.bitlen(ma)))
  fl.div.qr(big.divmod(big.shl(ma, k), mb), f, n, Nat.sub(Nat.add(ea, fl.eb()), Nat.add(eb, k)))

def fl.div.z(za: Bool, zb: Bool, +f: Fmt, +n: Bool, +ma: List<&2, Nat>, +ea: Nat, +mb: List<&2, Nat>, +eb: Nat) -> Fl:
  match za zb:
    case True{} True{}:
      FNaN{}
    case True{} False{}:
      fl.zero(n)
    case False{} True{}:
      FInf{n}
    case False{} False{}:
      fl.div.num(f, n, ma, ea, mb, eb)

# a / b in f, as IEEE 754 divides: a number but 0 over 0 is an infinity,
# 0 / 0 and inf / inf are NaN
def fl.div(+f: Fmt, a: Fl, b: Fl) -> Fl:
  match a b:
    case FNaN{} _:
      FNaN{}
    case _ FNaN{}:
      FNaN{}
    case FInf{na} FInf{nb}:
      FNaN{}
    case FInf{+na} FNum{+nb, mb, eb}:
      FInf{Bool.xor(na, nb)}
    case FNum{+na, ma, ea} FInf{+nb}:
      fl.zero(Bool.xor(na, nb))
    case FNum{+na, +ma, +ea} FNum{+nb, +mb, +eb}:
      fl.div.z(big.is_zero(ma), big.is_zero(mb), f, Bool.xor(na, nb), ma, ea, mb, eb)

# the root of m * 2^e, not 0: m shifted up by k so that its root has p +
# 2 bits at least, and e - k even
def fl.sqrt.num(+f: Fmt, +m: List<&2, Nat>, +e: Nat) -> Fl:
  +k0 = Nat.sub(Nat.add(Nat.mul(fmt.p(f), 2n), 4n), big.bitlen(m))
  +k = Nat.add(k0, Nat.mod(Nat.add(e, k0), 2n))
  fl.div.qr(big.isqrt(big.shl(m, k)), f, False{}, Nat.div(Nat.sub(Nat.add(e, fl.eb()), k), 2n))

def fl.sqrt.neg(neg: Bool, +f: Fmt, +m: List<&2, Nat>, +e: Nat) -> Fl:
  match neg:
    case True{}:
      FNaN{}
    case False{}:
      fl.sqrt.num(f, m, e)

def fl.sqrt.z(z: Bool, neg: Bool, +f: Fmt, +m: List<&2, Nat>, +e: Nat) -> Fl:
  match z:
    case True{}:
      fl.zero(neg)
    case False{}:
      fl.sqrt.neg(neg, f, m, e)

# the square root of a in f, as IEEE 754 takes it: -0 for -0, NaN below
# 0
def fl.sqrt(+f: Fmt, a: Fl) -> Fl:
  match a:
    case FNaN{}:
      FNaN{}
    case FInf{+n}:
      Bool.pick(Fl, n, FNaN{}, FInf{False{}})
    case FNum{+n, +m, +e}:
      fl.sqrt.z(big.is_zero(m), n, f, m, e)

def fl.is_nan(x: Fl) -> Bool:
  match x:
    case FNaN{}:
      True{}
    case FInf{neg}:
      False{}
    case FNum{neg, m, e}:
      False{}

def fl.is_inf(x: Fl) -> Bool:
  match x:
    case FNaN{}:
      False{}
    case FInf{neg}:
      True{}
    case FNum{neg, m, e}:
      False{}

# Reading text
# ------------
# as glibc's strtod reads the start of a string: blanks, a sign, then
# "inf" or "infinity", "nan", hex digits after "0x" with an optional point
# and binary exponent ("p", in decimal), or decimal digits with an
# optional point and exponent ("e"); an exponent with no digit is not
# read. The digits of an exponent past 10^9 read as 10^9, which puts any
# number past every format's range.

def ch.is_digit(+c: U32) -> Bool:
  U32.is_lt(U32.sub(c, 48), 10)

def ch.is_hex(+c: U32) -> Bool:
  Bool.or(ch.is_digit(c), U32.is_lt(U32.sub(U32.or(c, 32), 97), 6))

def ch.hexval(+c: U32) -> Nat:
  Bool.pick(Nat, ch.is_digit(c), U32.to_nat(U32.sub(c, 48)), U32.to_nat(U32.sub(U32.or(c, 32), 87)))

# the blanks of C's isspace
def ch.is_blank(+c: U32) -> Bool:
  Bool.or(U32.is_eq(c, 32), U32.is_lt(U32.sub(c, 9), 5))

# how many hex digits run at the start of s, after n of them (go: the last
# was one)
def hex.count.go(s: String, go: Bool, +n: Nat) -> Nat:
  match s:
    case SNil{}:
      n
    case SCon{Chr{+x}, t}:
      match go:
        case False{}:
          n
        case True{}:
          +h = ch.is_hex(x)
          hex.count.go(t, h, Bool.pick(Nat, h, Nat.add(n, 1n), n))

def hex.count(+s: String, +i: Nat) -> Nat:
  hex.count.go(String.drop(s, i), True{}, 0n)

# how many chars c run at the start of s
def run.go(s: String, go: Bool, +c: U32, +n: Nat) -> Nat:
  match s:
    case SNil{}:
      n
    case SCon{Chr{+x}, t}:
      match go:
        case False{}:
          n
        case True{}:
          +h = U32.is_eq(x, c)
          run.go(t, h, c, Bool.pick(Nat, h, Nat.add(n, 1n), n))

def run.count(+s: String, +i: Nat, +c: U32) -> Nat:
  run.go(String.drop(s, i), True{}, c, 0n)

# how many blanks run at the start of s
def blank.go(s: String, go: Bool, +n: Nat) -> Nat:
  match s:
    case SNil{}:
      n
    case SCon{Chr{+x}, t}:
      match go:
        case False{}:
          n
        case True{}:
          +h = ch.is_blank(x)
          blank.go(t, h, Bool.pick(Nat, h, Nat.add(n, 1n), n))

def blank.count(+s: String) -> Nat:
  blank.go(s, True{}, 0n)

# the value of s's k hex digits from index i on, after v
def hex.val(k: Nat, +s: String, +i: Nat, +v: Nat) -> Nat:
  match k:
    case 0n:
      v
    case 1n+p:
      hex.val(p, s, Nat.add(i, 1n), Nat.add(Nat.mul(v, 16n), ch.hexval(String.code_at(s, i))))

# a with the n decimal digits of s from index i on after it, 7 at a time
def big.digits.go(fuel: Nat, a: List<&2, Nat>, +s: String, +i: Nat, +n: Nat) -> List<&2, Nat>:
  match fuel:
    case 0n:
      a
    case 1n+f:
      +k = Nat.min(n, 7n)
      big.digits.go(f, big.mul_small(a, Nat.pow(10n, k), String.dec_at(s, i, k)), s, Nat.add(i, k), Nat.sub(n, k))

def big.digits(a: List<&2, Nat>, +s: String, +i: Nat, +n: Nat) -> List<&2, Nat>:
  big.digits.go(Nat.add(Nat.div(n, 7n), 1n), a, s, i, n)

# a with the n hex digits of s from index i on after it, 6 at a time
def big.hexes.go(fuel: Nat, a: List<&2, Nat>, +s: String, +i: Nat, +n: Nat) -> List<&2, Nat>:
  match fuel:
    case 0n:
      a
    case 1n+f:
      +k = Nat.min(n, 6n)
      big.hexes.go(f, big.mul_small(a, Nat.pow(16n, k), hex.val(k, s, i, 0n)), s, Nat.add(i, k), Nat.sub(n, k))

def big.hexes(a: List<&2, Nat>, +s: String, +i: Nat, +n: Nat) -> List<&2, Nat>:
  big.hexes.go(Nat.add(Nat.div(n, 6n), 1n), a, s, i, n)

# an exponent: its sign, its digits' value (10^9 at most) and where it ends
type Ex is Data:
  Ex{xn: Bool, x: Nat, end: Nat}

def scan.exp.val(small: Bool, +s: String, +j: Nat, +sig: Nat) -> Nat:
  match small:
    case True{}:
      String.dec_at(s, j, sig)
    case False{}:
      1000000000n

def scan.exp.of(none: Bool, +s: String, +j: Nat, +nd: Nat, +xn: Bool, +q: Nat) -> Ex:
  match none:
    case True{}:
      Ex{False{}, 0n, q}
    case False{}:
      +z = Nat.min(run.count(s, j, 48), nd)
      +sig = Nat.sub(nd, z)
      Ex{xn, scan.exp.val(Nat.is_le(sig, 9n), s, Nat.add(j, z), sig), Nat.add(j, nd)}

# the exponent after the letter at q: a sign, then at least one digit
def scan.exp(+s: String, +q: Nat) -> Ex:
  +c = String.code_at(s, Nat.add(q, 1n))
  +j = Nat.add(q, Bool.pick(Nat, Bool.or(U32.is_eq(c, 43), U32.is_eq(c, 45)), 2n, 1n))
  +nd = String.digits_at(s, j)
  scan.exp.of(Nat.is_eq(nd, 0n), s, j, nd, U32.is_eq(c, 45), q)

def scan.exp.if(has: Bool, +s: String, +q: Nat) -> Ex:
  match has:
    case True{}:
      scan.exp(s, q)
    case False{}:
      Ex{False{}, 0n, q}

# what strtod finds: a decimal or hex number (its sign; n0 digits at i0
# before the point, n1 at i1 after it; its exponent; where it ends), an
# infinity, a NaN, or nothing
type Scan is Data:
  SDec{neg: Bool, i0: Nat, n0: Nat, i1: Nat, n1: Nat, xn: Bool, x: Nat, end: Nat}
  SHex{neg: Bool, i0: Nat, n0: Nat, i1: Nat, n1: Nat, xn: Bool, x: Nat, end: Nat}
  SInf{neg: Bool, end: Nat}
  SNaN{end: Nat}
  SNone{}

def scan.dec.ex(x: Ex, +neg: Bool, +p: Nat, +n0: Nat, +i1: Nat, +n1: Nat) -> Scan:
  match x:
    case Ex{+xn, +xv, +end}:
      SDec{neg, p, n0, i1, n1, xn, xv, end}

def scan.dec.of(none: Bool, +s: String, +neg: Bool, +p: Nat, +n0: Nat, +i1: Nat, +n1: Nat, +q2: Nat) -> Scan:
  match none:
    case True{}:
      SNone{}
    case False{}:
      scan.dec.ex(scan.exp.if(U32.is_eq(U32.or(String.code_at(s, q2), 32), 101), s, q2), neg, p, n0, i1, n1)

def scan.dec(+s: String, +neg: Bool, +p: Nat) -> Scan:
  +n0 = String.digits_at(s, p)
  +q = Nat.add(p, n0)
  +dot = U32.is_eq(String.code_at(s, q), 46)
  +i1 = Nat.add(q, 1n)
  +n1 = Bool.pick(Nat, dot, String.digits_at(s, i1), 0n)
  scan.dec.of(Nat.is_eq(Nat.add(n0, n1), 0n), s, neg, p, n0, i1, n1, Bool.pick(Nat, dot, Nat.add(i1, n1), q))

def scan.hex.ex(x: Ex, +neg: Bool, +h: Nat, +n0: Nat, +i1: Nat, +n1: Nat) -> Scan:
  match x:
    case Ex{+xn, +xv, +end}:
      SHex{neg, h, n0, i1, n1, xn, xv, end}

# after "0x", with a hex digit before or after a point
def scan.hex(+s: String, +neg: Bool, +p: Nat) -> Scan:
  +h = Nat.add(p, 2n)
  +n0 = hex.count(s, h)
  +q = Nat.add(h, n0)
  +dot = U32.is_eq(String.code_at(s, q), 46)
  +i1 = Nat.add(q, 1n)
  +n1 = Bool.pick(Nat, dot, hex.count(s, i1), 0n)
  +q2 = Bool.pick(Nat, dot, Nat.add(i1, n1), q)
  scan.hex.ex(scan.exp.if(U32.is_eq(U32.or(String.code_at(s, q2), 32), 112), s, q2), neg, h, n0, i1, n1)

# whether s has the word w (upper case) at index p, in any case
def scan.word(+s: String, +p: Nat, +w: String) -> Bool:
  String.eq(String.to_upper(String.slice(s, p, String.length(w))), w)

def scan.at.if(inf: Bool, nan: Bool, hex: Bool, +s: String, +neg: Bool, +p: Nat) -> Scan:
  match inf:
    case True{}:
      SInf{neg, Nat.add(p, Bool.pick(Nat, scan.word(s, Nat.add(p, 3n), "INITY"), 8n, 3n))}
    case False{}:
      match nan:
        case True{}:
          SNaN{Nat.add(p, 3n)}
        case False{}:
          match hex:
            case True{}:
              scan.hex(s, neg, p)
            case False{}:
              scan.dec(s, neg, p)

def scan.at(+s: String, +neg: Bool, +p: Nat) -> Scan:
  +c0 = String.code_at(s, p)
  +c1 = String.code_at(s, Nat.add(p, 1n))
  +c2 = String.code_at(s, Nat.add(p, 2n))
  +c3 = String.code_at(s, Nat.add(p, 3n))
  +hex = Bool.and(Bool.and(U32.is_eq(c0, 48), U32.is_eq(U32.or(c1, 32), 120)), Bool.or(ch.is_hex(c2), Bool.and(U32.is_eq(c2, 46), ch.is_hex(c3))))
  scan.at.if(scan.word(s, p, "INF"), scan.word(s, p, "NAN"), hex, s, neg, p)

# strtod's number at index i of s (past any blanks)
def scan(+s: String, +i: Nat) -> Scan:
  +c = String.code_at(s, i)
  scan.at(s, U32.is_eq(c, 45), Nat.add(i, Bool.pick(Nat, Bool.or(U32.is_eq(c, 43), U32.is_eq(c, 45)), 1n, 0n)))

# a value read, and whether strtod reports a range error for it (ERANGE
# with an infinity or a zero: a finite number past the format's range, or
# one that is not 0 rounding to 0), and whether it is tiny: subnormal (or
# 0) and inexact, for which glibc's strtod reports ERANGE too (with the
# number it rounds to, which the readers of doubles of Redis take; SORT
# takes it for an error)
type Rv is Data:
  Rv{v: Fl, er: Bool, tiny: Bool}

# whether m * 2^e, and below it something more than 0 when sticky, loses
# bits rounded to f (as fl.round rounds it)
def fl.inexact(+f: Fmt, +m: List<&2, Nat>, +e: Nat, +sticky: Bool) -> Bool:
  match f:
    case Fmt{+p, +emin, emax}:
      +lead = Nat.sub(Nat.add(e, big.bitlen(m)), 1n)
      +lsb = Nat.sub(Nat.add(Nat.max(lead, Nat.sub(fl.eb(), emin)), 1n), p)
      Bool.or(sticky, Bool.and(Nat.is_lt(e, lsb), big.low_nz(m, Nat.sub(lsb, e))))

# whether a value rounded to fewer bits than f's (small: subnormal, or 0)
# is tiny, from what was rounded (m0 * 2^e0, sticky): the bits it lost,
# which only such a value is asked for
def fl.tiny(small: Bool, +f: Fmt, +m0: List<&2, Nat>, +e0: Nat, +sticky: Bool) -> Bool:
  match small:
    case False{}:
      False{}
    case True{}:
      fl.inexact(f, m0, e0, sticky)

# v, the value m0 * 2^e0 (sticky) rounded to f, as strtod reads it: a
# range error for an infinity, or for a 0 that a number not 0 rounds to
# (nonzero), and whether it is tiny
def fl.rv(v: Fl, +nonzero: Bool, +f: Fmt, +m0: List<&2, Nat>, +e0: Nat, +sticky: Bool) -> Rv:
  match v:
    case FNaN{}:
      Rv{FNaN{}, False{}, False{}}
    case FInf{+neg}:
      Rv{FInf{neg}, True{}, False{}}
    case FNum{+neg, +m, +e}:
      Rv{FNum{neg, m, e}, Bool.and(nonzero, big.is_zero(m)), fl.tiny(Nat.is_lt(big.bitlen(m), fmt.p(f)), f, m0, e0, sticky)}

def fl.dec.q(qs: List<&2, Nat> & Bool, +f: Fmt, +neg: Bool, +s: Nat) -> Rv:
  (+q, +st) = qs
  +e = Nat.sub(fl.eb(), s)
  fl.rv(fl.round(f, neg, q, e, st), True{}, f, q, e, st)

def fl.dec.neg(under: Bool, +f: Fmt, +neg: Bool, +d: List<&2, Nat>, +bl: Nat, +k: Nat) -> Rv:
  match under:
    case True{}:
      Rv{fl.zero(neg), True{}, True{}}
    case False{}:
      +s = Nat.sub(Nat.add(Nat.add(fmt.p(f), 6n), Nat.div(Nat.mul(k, 3322n), 1000n)), bl)
      fl.dec.q(big.div10(big.shl(d, s), k), f, neg, s)

def fl.dec.pos(over: Bool, +f: Fmt, +neg: Bool, +d: List<&2, Nat>, +k: Nat) -> Rv:
  match over:
    case True{}:
      Rv{FInf{neg}, True{}, False{}}
    case False{}:
      +m = big.mul_pow(d, 10n, k)
      fl.rv(fl.round(f, neg, m, fl.eb(), False{}), True{}, f, m, fl.eb(), False{})

def fl.dec.up(up: Bool, +p: Nat, +emin: Nat, +emax: Nat, +neg: Bool, +d: List<&2, Nat>, +e10: Nat, +bl: Nat) -> Rv:
  match up:
    case True{}:
      +k = Nat.sub(e10, fl.eb())
      fl.dec.pos(Nat.is_lt(emax, Nat.add(Nat.sub(bl, 1n), Nat.div(Nat.mul(k, 33219n), 10000n))), Fmt{p, emin, emax}, neg, d, k)
    case False{}:
      +k = Nat.sub(fl.eb(), e10)
      fl.dec.neg(Nat.is_le(Nat.add(Nat.add(bl, emin), p), Nat.div(Nat.mul(k, 33219n), 10000n)), Fmt{p, emin, emax}, neg, d, bl, k)

def fl.dec.of(z: Bool, up: Bool, f: Fmt, +neg: Bool, +d: List<&2, Nat>, +e10: Nat) -> Rv:
  match z:
    case True{}:
      Rv{fl.zero(neg), False{}, False{}}
    case False{}:
      match f:
        case Fmt{+p, +emin, +emax}:
          fl.dec.up(up, p, emin, emax, neg, d, e10, big.bitlen(d))

# d * 10^(e10 - 2^40), rounded to f
def fl.dec(+f: Fmt, +neg: Bool, +d: List<&2, Nat>, +e10: Nat) -> Rv:
  fl.dec.of(big.is_zero(d), Nat.is_le(fl.eb(), e10), f, neg, d, e10)

def fl.hex.go(over: Bool, under: Bool, +f: Fmt, +neg: Bool, +h: List<&2, Nat>, +e2: Nat) -> Rv:
  match over:
    case True{}:
      Rv{FInf{neg}, True{}, False{}}
    case False{}:
      match under:
        case True{}:
          Rv{fl.zero(neg), True{}, True{}}
        case False{}:
          fl.rv(fl.round(f, neg, h, e2, False{}), True{}, f, h, e2, False{})

def fl.hex.bl(+p: Nat, +emin: Nat, +emax: Nat, +neg: Bool, +h: List<&2, Nat>, +e2: Nat, +bl: Nat) -> Rv:
  fl.hex.go(Nat.is_lt(Nat.add(fl.eb(), emax), Nat.sub(Nat.add(e2, bl), 1n)), Nat.is_le(Nat.add(Nat.add(Nat.add(e2, bl), p), emin), fl.eb()), Fmt{p, emin, emax}, neg, h, e2)

def fl.hex.of(z: Bool, f: Fmt, +neg: Bool, +h: List<&2, Nat>, +e2: Nat) -> Rv:
  match z:
    case True{}:
      Rv{fl.zero(neg), False{}, False{}}
    case False{}:
      match f:
        case Fmt{+p, +emin, +emax}:
          fl.hex.bl(p, emin, emax, neg, h, e2, big.bitlen(h))

def fl.hex(+f: Fmt, +neg: Bool, +h: List<&2, Nat>, +e2: Nat) -> Rv:
  fl.hex.of(big.is_zero(h), f, neg, h, e2)

# what strtod reads at index p of s (start: where it began, past which it
# skipped blanks): the value, where it ends (start when it reads nothing),
# whether it reports a range error, and whether the value is tiny (Rv)
type Rd is Data:
  Rd{v: Fl, end: Nat, er: Bool, tiny: Bool}

def fl.rd(r: Rv, +end: Nat) -> Rd:
  match r:
    case Rv{v, +er, +tiny}:
      Rd{v, end, er, tiny}

# a number's exponent: x with its sign, less k (biased by 2^40)
def fl.exp(+xn: Bool, +x: Nat, +k: Nat) -> Nat:
  Nat.sub(Bool.pick(Nat, xn, Nat.sub(fl.eb(), x), Nat.add(fl.eb(), x)), k)

def fl.strtod.of(+f: Fmt, +s: String, +start: Nat, sc: Scan) -> Rd:
  match sc:
    case SNone{}:
      Rd{fl.zero(False{}), start, False{}, False{}}
    case SNaN{+end}:
      Rd{FNaN{}, end, False{}, False{}}
    case SInf{+neg, +end}:
      Rd{FInf{neg}, end, False{}, False{}}
    case SDec{+neg, +i0, +n0, +i1, +n1, +xn, +x, +end}:
      fl.rd(fl.dec(f, neg, big.digits(big.digits(Nil{}, s, i0, n0), s, i1, n1), fl.exp(xn, x, n1)), end)
    case SHex{+neg, +i0, +n0, +i1, +n1, +xn, +x, +end}:
      fl.rd(fl.hex(f, neg, big.hexes(big.hexes(Nil{}, s, i0, n0), s, i1, n1), fl.exp(xn, x, Nat.mul(n1, 4n))), end)

def fl.strtod(+f: Fmt, +s: String, +start: Nat, +p: Nat) -> Rd:
  fl.strtod.of(f, s, start, scan(s, p))

# Doubles
# -------

# a double as its 64 bits: the sign, the 11 bits of the exponent and the
# top 20 bits of the fraction (hi), the low 32 bits of the fraction (lo)
type F64 is Data:
  F64{hi: Nat, lo: Nat}

def f64.sign(neg: Bool) -> Nat:
  match neg:
    case True{}:
      2147483648n
    case False{}:
      0n

# limb i of a (0 past its end)
def big.limb(a: List<&2, Nat>, i: Nat) -> Nat:
  match a:
    case Nil{}:
      0n
    case Con{+x, xs}:
      match i:
        case 0n:
          x
        case 1n+p:
          big.limb(xs, p)

# a double of fmt.d: m below 2^53; a normal one has its bit 52 set
def f64.of.num(+neg: Bool, +m: List<&2, Nat>, +e: Nat) -> F64:
  +l1 = big.limb(m, 1n)
  +top = Nat.add(Nat.mul(big.limb(m, 2n), 65536n), Nat.div(l1, 256n))
  +ex = Bool.pick(Nat, Nat.is_le(1048576n, top), Nat.sub(Nat.add(e, 1075n), fl.eb()), 0n)
  F64{Nat.add(Nat.add(f64.sign(neg), Nat.mul(ex, 1048576n)), Nat.mod(top, 1048576n)), Nat.add(Nat.mul(Nat.mod(l1, 256n), 16777216n), big.limb(m, 0n))}

def f64.of(x: Fl) -> F64:
  match x:
    case FNaN{}:
      F64{2146959360n, 0n}
    case FInf{+neg}:
      F64{Nat.add(f64.sign(neg), 2146435072n), 0n}
    case FNum{+neg, +m, +e}:
      f64.of.num(neg, m, e)

def f64.to.of(special: Bool, +sub: Bool, +neg: Bool, +ex: Nat, +fh: Nat, +lo: Nat) -> Fl:
  match special:
    case True{}:
      Bool.pick(Fl, Bool.and(Nat.is_eq(fh, 0n), Nat.is_eq(lo, 0n)), FInf{neg}, FNaN{})
    case False{}:
      +top = Bool.pick(Nat, sub, fh, Nat.add(fh, 1048576n))
      +m = big.con(Nat.mod(lo, 16777216n), big.con(Nat.add(Nat.div(lo, 16777216n), Nat.mul(Nat.mod(top, 65536n), 256n)), big.con(Nat.div(top, 65536n), Nil{})))
      FNum{neg, m, Bool.pick(Nat, sub, Nat.sub(fl.eb(), 1074n), Nat.sub(Nat.add(fl.eb(), ex), 1075n))}

def f64.to(d: F64) -> Fl:
  match d:
    case F64{+hi, +lo}:
      +ex = Nat.mod(Nat.div(hi, 1048576n), 2048n)
      f64.to.of(Nat.is_eq(ex, 2047n), Nat.is_eq(ex, 0n), Nat.is_le(2147483648n, hi), ex, Nat.mod(hi, 1048576n), lo)

def f64.is_nan(d: F64) -> Bool:
  match d:
    case F64{+hi, +lo}:
      Bool.and(Nat.is_eq(Nat.mod(Nat.div(hi, 1048576n), 2048n), 2047n), Bool.or(Nat.is_ne(Nat.mod(hi, 1048576n), 0n), Nat.is_ne(lo, 0n)))

def f64.cmp.mag(+ha: Nat, +la: Nat, +hb: Nat, +lb: Nat) -> Cmp:
  big.cmp.limb(Nat.cmp(ha, hb), Nat.cmp(la, lb))

def f64.cmp.of(zz: Bool, na: Bool, nb: Bool, +ha: Nat, +la: Nat, +hb: Nat, +lb: Nat) -> Cmp:
  match zz:
    case True{}:
      EQ{}
    case False{}:
      match na nb:
        case True{} False{}:
          LT{}
        case False{} True{}:
          GT{}
        case False{} False{}:
          f64.cmp.mag(ha, la, hb, lb)
        case True{} True{}:
          f64.cmp.mag(hb, lb, ha, la)

# whether two doubles have the same bits
def f64.same(+a: F64, +b: F64) -> Bool:
  match a b:
    case F64{+ha, +la} F64{+hb, +lb}:
      Bool.and(Nat.is_eq(ha, hb), Nat.is_eq(la, lb))

# how two doubles compare, neither a NaN: -0 equals +0
def f64.cmp(+a: F64, +b: F64) -> Cmp:
  match a b:
    case F64{+ha, +la} F64{+hb, +lb}:
      +ma = Nat.mod(ha, 2147483648n)
      +mb = Nat.mod(hb, 2147483648n)
      +za = Bool.and(Nat.is_eq(ma, 0n), Nat.is_eq(la, 0n))
      +zb = Bool.and(Nat.is_eq(mb, 0n), Nat.is_eq(lb, 0n))
      f64.cmp.of(Bool.and(za, zb), Bool.and(Nat.is_le(2147483648n, ha), Bool.not(za)), Bool.and(Nat.is_le(2147483648n, hb), Bool.not(zb)), ma, la, mb, lb)

def f64.parse.ok(ok: Bool, v: Fl) -> Maybe<&2, F64>:
  match ok:
    case False{}:
      None{}
    case True{}:
      match v:
        case FNaN{}:
          None{}
        case FInf{neg}:
          Some{f64.of(FInf{neg})}
        case FNum{neg, m, e}:
          Some{f64.of(FNum{neg, m, e})}

# the double whose bits F64.read gives (base's native: glibc's strtod, as
# Redis's string2d calls it), None when it gives a NaN: s does not read
def f64.read.pick(+x: F64) -> Maybe<&2, F64>:
  Bool.pick(Maybe<&2, F64>, f64.is_nan(x), None{}, Some{x})

def f64.read.of(r: U32 & U32) -> Maybe<&2, F64>:
  (h, l) = r
  f64.read.pick(F64{U32.to_nat(h), U32.to_nat(l)})

def f64.parse.of(bad: Bool, +s: String, +n: Nat) -> Maybe<&2, F64>:
  match bad:
    case True{}:
      None{}
    case False{}:
      f64.read.of(F64.read(s))

# the bits of n, below 2^48
def nat.bl48.if(lo: Bool, +n: Nat) -> Nat:
  match lo:
    case True{}:
      nat.bl(n)
    case False{}:
      Nat.add(24n, nat.bl(Nat.div(n, 16777216n)))

def nat.bl48(+n: Nat) -> Nat:
  nat.bl48.if(Nat.is_lt(n, 16777216n), n)

# the double of an integer n (not 0) below 2^48: its leading bit at e (p
# is 2^e, the one power of two it takes), the r below it put on the top
# of the 52 bits of the fraction
def f64.of.int.e(big: Bool, +neg: Bool, +e: Nat, +p: Nat, +r: Nat) -> F64:
  match big:
    case True{}:
      +sh = Nat.div(p, 1048576n)
      F64{Nat.add(Nat.add(f64.sign(neg), Nat.mul(Nat.add(e, 1023n), 1048576n)), Nat.div(r, sh)), Nat.mul(Nat.mod(r, sh), Nat.div(Nat.mul(65536n, 65536n), sh))}
    case False{}:
      F64{Nat.add(Nat.add(f64.sign(neg), Nat.mul(Nat.add(e, 1023n), 1048576n)), Nat.mul(r, Nat.div(1048576n, p))), 0n}

def f64.of.int.p(+neg: Bool, +n: Nat, +e: Nat, +p: Nat) -> F64:
  f64.of.int.e(Nat.is_le(20n, e), neg, e, p, Nat.sub(n, p))

def f64.of.int.z(z: Bool, +neg: Bool, +n: Nat) -> F64:
  match z:
    case True{}:
      F64{f64.sign(neg), 0n}
    case False{}:
      +e = Nat.sub(nat.bl48(n), 1n)
      f64.of.int.p(neg, n, e, nat.pow2(e))

# the double of -n (neg) or n, n below 2^48
def f64.of_int(+neg: Bool, +n: Nat) -> F64:
  f64.of.int.z(Nat.is_eq(n, 0n), neg, n)

def f64.parse.int(int: Bool, +s: String, +n: Nat, +a: Nat) -> Maybe<&2, F64>:
  match int:
    case True{}:
      Some{f64.of_int(Nat.is_eq(a, 1n), String.dec_at(s, a, Nat.sub(n, a)))}
    case False{}:
      f64.parse.of(Bool.or(Nat.is_eq(n, 0n), ch.is_blank(String.code_at(s, 0n))), s, n)

# a double as Redis's string2d reads one (getDoubleFromObject): all of s,
# no blank first; None for no number, a NaN, or a range error. An integer
# of up to 14 digits is read at once, any other text by glibc's strtod
# (F64.read), which fl.strtod reads as it does.
def f64.parse(+s: String) -> Maybe<&2, F64>:
  +n = String.length(s)
  +a = Bool.pick(Nat, U32.is_eq(String.code_at(s, 0n), 45), 1n, 0n)
  +d = Nat.sub(n, a)
  f64.parse.int(Bool.and(Bool.and(Nat.is_lt(0n, d), Nat.is_le(d, 14n)), Nat.is_eq(String.digits_at(s, a), d)), s, n, a)

def f64.range.ok(ok: Bool, v: Fl) -> Maybe<&2, F64>:
  match ok:
    case False{}:
      None{}
    case True{}:
      match v:
        case FNaN{}:
          None{}
        case FInf{neg}:
          Some{f64.of(FInf{neg})}
        case FNum{neg, m, e}:
          Some{f64.of(FNum{neg, m, e})}

def f64.range.rd(r: Rd, +s: String, +n: Nat) -> Maybe<&2, F64>:
  match r:
    case Rd{v, +end, er, tiny}:
      f64.range.ok(Bool.or(Nat.is_eq(end, n), U32.is_eq(String.code_at(s, end), 0)), v)

# a score as SORT reads one (sort.c), with strtod: blanks first, up to the
# end or a NUL, with no range error (errno's ERANGE: an infinity or a 0
# that a finite number rounds to, or a tiny number), and no NaN ("" reads
# as 0)
def f64.sort.rd(r: Rd, +s: String) -> Maybe<&2, F64>:
  match r:
    case Rd{v, +end, +er, +tiny}:
      +x = String.code_at(s, end)
      f64.parse.ok(Bool.and(Bool.or(U32.is_eq(x, 0), U32.is_eq(x, 4294967295)), Bool.not(Bool.or(er, tiny))), v)

def f64.parse_sort.of(int: Bool, +s: String, +n: Nat, +a: Nat) -> Maybe<&2, F64>:
  match int:
    case True{}:
      Some{f64.of_int(Nat.is_eq(a, 1n), String.dec_at(s, a, Nat.sub(n, a)))}
    case False{}:
      f64.sort.rd(fl.strtod(fmt.d(), s, 0n, blank.count(s)), s)

# a score as SORT reads one; an integer of up to 14 digits (no blank, no
# NUL) at once, as f64.parse reads one
def f64.parse_sort(+s: String) -> Maybe<&2, F64>:
  +n = String.length(s)
  +a = Bool.pick(Nat, U32.is_eq(String.code_at(s, 0n), 45), 1n, 0n)
  +d = Nat.sub(n, a)
  f64.parse_sort.of(Bool.and(Bool.and(Nat.is_lt(0n, d), Nat.is_le(d, 14n)), Nat.is_eq(String.digits_at(s, a), d)), s, n, a)

# a bound of a score range, as zslParseRange reads one with strtod:
# blanks first, up to the end or a NUL, an overflow or underflow taken
# as it rounds; None for no number or a NaN ("" reads as 0)
def f64.parse_range(+s: String) -> Maybe<&2, F64>:
  f64.range.rd(fl.strtod(fmt.d(), s, 0n, blank.count(s)), s, String.length(s))

def ld.parse.ok(ok: Bool, v: Fl) -> Maybe<&2, Fl>:
  match ok:
    case False{}:
      None{}
    case True{}:
      match v:
        case FNaN{}:
          None{}
        case FInf{neg}:
          Some{FInf{neg}}
        case FNum{neg, m, e}:
          Some{FNum{neg, m, e}}

def ld.parse.rd(r: Rd, +n: Nat) -> Maybe<&2, Fl>:
  match r:
    case Rd{v, +end, +er, tiny}:
      ld.parse.ok(Bool.and(Nat.is_eq(end, n), Bool.not(er)), v)

def ld.parse.of(bad: Bool, +s: String, +n: Nat) -> Maybe<&2, Fl>:
  match bad:
    case True{}:
      None{}
    case False{}:
      ld.parse.rd(fl.strtod(fmt.ld(), s, 0n, 0n), n)

# a long double as Redis's string2ld reads one: all of s, shorter than
# 5120 chars, no blank first; None for no number, a NaN, a range error
def ld.parse(+s: String) -> Maybe<&2, Fl>:
  +n = String.length(s)
  ld.parse.of(Bool.or(Bool.or(Nat.is_eq(n, 0n), Nat.is_le(5120n, n)), ch.is_blank(String.code_at(s, 0n))), s, n)

# Writing text
# ------------

# m * 2^e with the 0 bits below m's lowest 1 taken out (m not 0)
def fl.trim(+neg: Bool, +m: List<&2, Nat>, +e: Nat) -> Fl:
  +z = big.tz(m)
  FNum{neg, big.shr(m, z), Nat.add(e, z)}

def str.zeros(+n: Nat) -> String:
  String.repeat("0", n)

# how many '0' end s's first n chars
def trail.go(+s: String, i: Nat, +n: Nat) -> Nat:
  match i:
    case 0n:
      n
    case 1n+(+p):
      Bool.pick(Nat, U32.is_eq(String.code_at(s, p), 48), trail.go(s, p, Nat.add(n, 1n)), n)

def trail.count(+s: String) -> Nat:
  trail.go(s, String.length(s), 0n)

# s without the '0' that end it, one char at least
def str.trim0(+s: String) -> String:
  String.take(s, Nat.max(1n, Nat.sub(String.length(s), trail.count(s))))

# x, a biased decimal exponent (100000 is 10^0), for "%g": e+NN at least
def g.exp(+x: Nat) -> String:
  +neg = Nat.is_lt(x, 100000n)
  +a = Bool.pick(Nat, neg, Nat.sub(100000n, x), Nat.sub(x, 100000n))
  +d = Nat.show(a)
  "e" ++ Bool.pick(String, neg, "-", "+") ++ Bool.pick(String, Nat.is_lt(a, 10n), "0", "") ++ d

def g.fmt.of(sci: Bool, pos: Bool, +ds: String, +n: Nat, +x: Nat) -> String:
  match sci:
    case True{}:
      String.take(ds, 1n) ++ Bool.pick(String, Nat.is_lt(1n, n), "." ++ String.drop(ds, 1n), "") ++ g.exp(x)
    case False{}:
      match pos:
        case True{}:
          +k = Nat.add(Nat.sub(x, 100000n), 1n)
          Bool.pick(String, Nat.is_le(n, k), ds ++ str.zeros(Nat.sub(k, n)), String.take(ds, k) ++ "." ++ String.drop(ds, k))
        case False{}:
          "0." ++ str.zeros(Nat.sub(Nat.sub(100000n, x), 1n)) ++ ds

# 17 significant digits ds (at most 17, the first not 0, no '0' last) of
# a number whose first digit is at 10^(x - 100000): as "%.17g" writes them
def g.fmt(+ds: String, +x: Nat) -> String:
  +n = String.length(ds)
  +sci = Bool.or(Nat.is_lt(x, 99996n), Nat.is_le(100017n, x))
  g.fmt.of(sci, Nat.is_le(100000n, x), ds, n, x)

def g.pad(+n: Nat, +w: Nat) -> String:
  +d = Nat.show(n)
  str.zeros(Nat.sub(w, String.length(d))) ++ d

# a number's exact digits ds, its first at 10^(x - 100000), rounded to 17
# significant digits, to the even one on a tie (then '0's trimmed)
def g.round.up(up: Bool, +hi: Nat, +lo: Nat, +x: Nat) -> String:
  match up:
    case False{}:
      g.fmt(str.trim0(g.pad(hi, 9n) ++ g.pad(lo, 8n)), x)
    case True{}:
      +lo1 = Nat.add(lo, 1n)
      +carry = Nat.is_eq(lo1, 100000000n)
      +hi1 = Bool.pick(Nat, carry, Nat.add(hi, 1n), hi)
      +lo2 = Bool.pick(Nat, carry, 0n, lo1)
      Bool.pick(String, Nat.is_eq(hi1, 1000000000n), g.fmt("1", Nat.add(x, 1n)), g.fmt(str.trim0(g.pad(hi1, 9n) ++ g.pad(lo2, 8n)), x))

def g.round(long: Bool, +ds: String, +x: Nat) -> String:
  match long:
    case False{}:
      g.fmt(str.trim0(ds), x)
    case True{}:
      +lo = String.dec_at(ds, 9n, 8n)
      +nx = U32.to_nat(U32.sub(String.code_at(ds, 17n), 48))
      +rest = Nat.is_lt(run.count(ds, 18n, 48), Nat.sub(String.length(ds), 18n))
      +odd = Nat.is_eq(Nat.mod(lo, 2n), 1n)
      g.round.up(Bool.or(Nat.is_lt(5n, nx), Bool.and(Nat.is_eq(nx, 5n), Bool.or(rest, odd))), String.dec_at(ds, 0n, 9n), lo, x)

# a number's exact digits, the last at 10^-k
def g.digits(+ds: String, +k: Nat) -> String:
  +n = String.length(ds)
  g.round(Nat.is_lt(17n, n), ds, Nat.sub(Nat.add(100000n, Nat.sub(n, 1n)), k))

def g.num.of(int: Bool, +m: List<&2, Nat>, +e: Nat) -> String:
  match int:
    case True{}:
      g.digits(big.to_dec(big.shl(m, Nat.sub(e, fl.eb()))), 0n)
    case False{}:
      +k = Nat.sub(fl.eb(), e)
      g.digits(big.to_dec(big.mul_pow(m, 5n, k)), k)

def g.num(x: Fl) -> String:
  match x:
    case FNum{neg, +m, +e}:
      g.num.of(Nat.is_le(fl.eb(), e), m, e)
    case FInf{neg}:
      "inf"
    case FNaN{}:
      "nan"

def g.fin(z: Bool, +neg: Bool, +m: List<&2, Nat>, +e: Nat) -> String:
  match z:
    case True{}:
      Bool.pick(String, neg, "-0", "0")
    case False{}:
      Bool.pick(String, neg, "-", "") ++ g.num(fl.trim(neg, m, e))

# a number as printf's "%.17g" writes it (as Redis writes a double:
# "inf" and "-inf" for the infinities)
def fl.show_g(x: Fl) -> String:
  match x:
    case FNaN{}:
      "nan"
    case FInf{+neg}:
      Bool.pick(String, neg, "-inf", "inf")
    case FNum{+neg, +m, +e}:
      g.fin(big.is_zero(m), neg, m, e)

def f64.int.go(hi: Bool, +neg: Bool, +s: Nat, +m: Nat, +lo: Nat) -> Maybe<&2, String>:
  match hi:
    case True{}:
      +k = nat.pow2(Nat.sub(s, 32n))
      Bool.pick(Maybe<&2, String>, Bool.and(Nat.is_eq(lo, 0n), Nat.is_eq(Nat.mod(m, k), 0n)), Some{Bool.pick(String, neg, "-", "") ++ Nat.show(Nat.div(m, k))}, None{})
    case False{}:
      +k = nat.pow2(s)
      Bool.pick(Maybe<&2, String>, Nat.is_eq(Nat.mod(lo, k), 0n), Some{Bool.pick(String, neg, "-", "") ++ Nat.show(Nat.add(Nat.mul(m, Nat.div(Nat.mul(65536n, 65536n), k)), Nat.div(lo, k)))}, None{})

# a double of exponent field ex (1023 to 1069: an integer part below 2^47
# when the bits below its point are 0), as an integer's text, or None
def f64.int.of(+neg: Bool, +ex: Nat, +fh: Nat, +lo: Nat) -> Maybe<&2, String>:
  +s = Nat.sub(1075n, ex)
  +m = Nat.add(fh, 1048576n)
  f64.int.go(Nat.is_le(32n, s), neg, s, m, lo)

def f64.show.int(m: Maybe<&2, String>, d: F64) -> String:
  match m:
    case Some{s}:
      s
    case None{}:
      fl.show_g(f64.to(d))

def f64.show.of(small: Bool, zero: Bool, +d: F64) -> String:
  match small:
    case True{}:
      match d:
        case F64{+hi, +lo}:
          f64.show.int(f64.int.of(Nat.is_le(2147483648n, hi), Nat.mod(Nat.div(hi, 1048576n), 2048n), Nat.mod(hi, 1048576n), lo), d)
    case False{}:
      match zero:
        case True{}:
          match d:
            case F64{+hi, lo}:
              Bool.pick(String, Nat.is_le(2147483648n, hi), "-0", "0")
        case False{}:
          fl.show_g(f64.to(d))

# a double as Redis writes one ("%.17g"; "inf" and "-inf"): an integer
# below 2^47 at once
def f64.show(+d: F64) -> String:
  match d:
    case F64{+hi, +lo}:
      +ex = Nat.mod(Nat.div(hi, 1048576n), 2048n)
      f64.show.of(Bool.and(Nat.is_le(1023n, ex), Nat.is_le(ex, 1069n)), Bool.and(Bool.and(Nat.is_eq(ex, 0n), Nat.is_eq(Nat.mod(hi, 1048576n), 0n)), Nat.is_eq(lo, 0n)), F64{hi, lo})

# A double as a listpack keeps a sorted set's score (zzlInsertAt): an
# integral one of magnitude at most 2^62 as its integer's digits (Redis's
# double2ll, then ll2string), any other as Redis writes a double
# (d2string: %.17g, inf, -inf). Below 2^47 the two are the same
# (f64.show), so only the exponent fields from 1070 to 1085 are read here:
# the 53 bits of the significand (m) are shifted by the exponent, the
# bits shifted out below the point all 0 for an integer.
def f64.lp.of(int: Bool, +neg: Bool, +v: List<&2, Nat>, +d: F64) -> String:
  match int:
    case True{}:
      Bool.pick(String, neg, "-", "") ++ big.to_dec(v)
    case False{}:
      f64.show(d)

def f64.lp.big(+hi: Nat, +lo: Nat, +ex: Nat) -> String:
  +fh = Nat.mod(hi, 1048576n)
  +m = big.add(big.shl(big.of(Nat.add(fh, 1048576n)), 32n), big.of(lo))
  +up = Nat.is_le(1075n, ex)
  +sh = Bool.pick(Nat, up, Nat.sub(ex, 1075n), Nat.sub(1075n, ex))
  +fits = Bool.or(Nat.is_lt(ex, 1085n), Bool.and(Nat.is_eq(fh, 0n), Nat.is_eq(lo, 0n)))
  f64.lp.of(Bool.and(fits, Bool.or(up, Bool.not(big.low_nz(m, sh)))), Nat.is_le(2147483648n, hi), Bool.pick(List<&2, Nat>, up, big.shl(m, sh), big.shr(m, sh)), F64{hi, lo})

def f64.lp.if(big: Bool, +hi: Nat, +lo: Nat, +ex: Nat) -> String:
  match big:
    case True{}:
      f64.lp.big(hi, lo, ex)
    case False{}:
      f64.show(F64{hi, lo})

def f64.show_lp(+d: F64) -> String:
  match d:
    case F64{+hi, +lo}:
      +ex = Nat.mod(Nat.div(hi, 1048576n), 2048n)
      f64.lp.if(Bool.and(Nat.is_le(1070n, ex), Nat.is_le(ex, 1085n)), hi, lo, ex)

# the digits of n, a number times 10^17, with the point 17 digits from
# the right, the '0's that end it and a point left last taken out
def f.point(+ds: String) -> String:
  +d18 = str.zeros(Nat.sub(18n, String.length(ds))) ++ ds
  +k = Nat.sub(String.length(d18), 17n)
  +frac = String.drop(d18, k)
  +fn = Nat.sub(17n, trail.count(frac))
  String.take(d18, k) ++ Bool.pick(String, Nat.is_eq(fn, 0n), "", "." ++ String.take(frac, fn))

def f.out(+neg: Bool, n: List<&2, Nat>) -> String:
  match n:
    case Nil{}:
      "0"
    case Con{+h, +t}:
      Bool.pick(String, neg, "-", "") ++ f.point(big.to_dec(Con{h, t}))

def f.round.up(up: Bool, +neg: Bool, +q: List<&2, Nat>) -> String:
  match up:
    case True{}:
      f.out(neg, big.add(q, [1n]))
    case False{}:
      f.out(neg, q)

# t * 2^-r, rounded to an integer, to the even one on a tie
def f.round(+neg: Bool, +t: List<&2, Nat>, +r: Nat) -> String:
  +q = big.shr(t, r)
  f.round.up(Bool.and(big.bit(t, Nat.sub(r, 1n)), Bool.or(big.low_nz(t, Nat.sub(r, 1n)), big.is_odd(q))), neg, q)

def f.num.of(int: Bool, +neg: Bool, +m: List<&2, Nat>, +e: Nat) -> String:
  match int:
    case True{}:
      f.out(neg, big.mul_pow(big.shl(m, Nat.sub(e, fl.eb())), 10n, 17n))
    case False{}:
      +s = Nat.sub(fl.eb(), e)
      +t = big.mul_pow(m, 5n, 17n)
      Bool.pick(String, Nat.is_le(s, 17n), f.out(neg, big.shl(t, Nat.sub(17n, s))), f.round(neg, t, Nat.sub(s, 17n)))

def f.num(x: Fl) -> String:
  match x:
    case FNum{+neg, +m, +e}:
      f.num.of(Nat.is_le(fl.eb(), e), neg, m, e)
    case FInf{neg}:
      "inf"
    case FNaN{}:
      "nan"

def f.fin(z: Bool, +neg: Bool, +m: List<&2, Nat>, +e: Nat) -> String:
  match z:
    case True{}:
      "0"
    case False{}:
      f.num(fl.trim(neg, m, e))

# a number as Redis's ld2string writes one for people (LD_STR_HUMAN):
# printf's "%.17Lf", then the '0's that end its fraction and a point left
# last taken out, and "-0" written "0"
def fl.show_human(x: Fl) -> String:
  match x:
    case FNaN{}:
      "nan"
    case FInf{+neg}:
      Bool.pick(String, neg, "-inf", "inf")
    case FNum{+neg, +m, +e}:
      f.fin(big.is_zero(m), neg, m, e)

# the digits of n, a number times 10^6, with the point 6 digits from the
# right, as printf's "%f" writes them (a 0 before the point at least)
def f6.point(+ds: String) -> String:
  +d7 = str.zeros(Nat.sub(7n, String.length(ds))) ++ ds
  +k = Nat.sub(String.length(d7), 6n)
  String.take(d7, k) ++ "." ++ String.drop(d7, k)

def f6.out(+neg: Bool, n: List<&2, Nat>) -> String:
  Bool.pick(String, neg, "-", "") ++ f6.point(big.to_dec(n))

def f6.round.up(up: Bool, +neg: Bool, +q: List<&2, Nat>) -> String:
  match up:
    case True{}:
      f6.out(neg, big.add(q, [1n]))
    case False{}:
      f6.out(neg, q)

# t * 2^-r, rounded to an integer, to the even one on a tie (r past 0)
def f6.round(+neg: Bool, +t: List<&2, Nat>, +r: Nat) -> String:
  +q = big.shr(t, r)
  f6.round.up(Bool.and(big.bit(t, Nat.sub(r, 1n)), Bool.or(big.low_nz(t, Nat.sub(r, 1n)), big.is_odd(q))), neg, q)

# m * 2^-s times 10^6 = m * 5^6 * 2^(6 - s): exact for s up to 6
def f6.frac(small: Bool, +neg: Bool, +t: List<&2, Nat>, +s: Nat) -> String:
  match small:
    case True{}:
      f6.out(neg, big.shl(t, Nat.sub(6n, s)))
    case False{}:
      f6.round(neg, t, Nat.sub(s, 6n))

def f6.num(int: Bool, +neg: Bool, +m: List<&2, Nat>, +e: Nat) -> String:
  match int:
    case True{}:
      f6.out(neg, big.mul_pow(big.shl(m, Nat.sub(e, fl.eb())), 10n, 6n))
    case False{}:
      +s = Nat.sub(fl.eb(), e)
      f6.frac(Nat.is_le(s, 6n), neg, big.mul_pow(m, 5n, 6n), s)

def f6.fin(z: Bool, +neg: Bool, +m: List<&2, Nat>, +e: Nat) -> String:
  match z:
    case True{}:
      Bool.pick(String, neg, "-0.000000", "0.000000")
    case False{}:
      f6.num(Nat.is_le(fl.eb(), e), neg, m, e)

# a number as printf's "%f" writes it: its exact value rounded to six
# decimals, to the even one on a tie, with its sign (a negative zero, and
# a negative number that rounds to 0, are "-0.000000"); "inf", "-inf",
# "nan"
def fl.show_f(x: Fl) -> String:
  match x:
    case FNaN{}:
      "nan"
    case FInf{+neg}:
      Bool.pick(String, neg, "-inf", "inf")
    case FNum{+neg, +m, +e}:
      f6.fin(big.is_zero(m), neg, m, e)
