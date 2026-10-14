# lolwut.bend: the drawings of LOLWUT VERSION 5 and VERSION 6, as Redis
# 7.0.15 draws them (lolwut.c, lolwut5.c, lolwut6.c).
#
# VERSION 5 is Georg Nees's Schotter: rows of squares, turned and moved a
# little more at random from the third row down, drawn with Bresenham's
# lines on a canvas of pixels that is written in braille, a character for
# each 2x4 pixels. Its numbers are Redis's C floats and doubles, each
# operation rounded as the C code rounds it (float.bend), so that a
# square that is not turned lands on the pixels Redis's lands on: the
# sines and cosines of its corners' angles are glibc's, kept here. A
# turned square's angle comes from rand(), whose numbers no client can
# know, and its sines and cosines are a series in fixed point, within a
# hundred-thousandth of glibc's. So a drawing of one or two rows is the
# bytes Redis sends, and one of more rows one that Redis could draw.
#
# VERSION 6 is a skyline of skyscrapers in two grays on white, and black
# ones in front with windows of the two grays, their places, sizes and
# window colors at random, written with the terminal's colors, a
# character for each pixel.
#
# Both take their random numbers from the server's (session.bend): a
# stream of 31-bit numbers, as glibc's rand() gives, from the seed it
# passes. The canvas is no array (an Array anywhere makes the compiler
# pass every loop's boxed arguments with their location): VERSION 5's
# lit pixels are a sorted list of codes of the cells they light, VERSION
# 6's colors are found a pixel at a time, from the last skyscraper drawn
# over it. The text is built from its end, a character at a time.

import Base
import ./float.bend as F
import ./map.bend as KV

# Random numbers
# --------------

# rand() at the stream's state st: 31 bits, as glibc's RAND_MAX is
# 2^31 - 1; and the stream's next state
def rnd(+st: U32) -> Nat:
  U32.to_nat(U32.shrn(KV.mix(st), 1n))

def rnd.next(+st: U32) -> U32:
  U32.add(st, 2654435769)

# Numbers
# -------
# Integers that may be negative (coordinates on or off a canvas,
# Bresenham's error) are kept biased: v + bias(), a Nat, as no drawing
# goes a million pixels past its canvas.

def bias() -> Nat:
  1048576n

# n as a C float (fmt.f), and a biased v as a float and as a double
def f32(+n: Nat) -> F.Fl:
  F.fl.to(F.fmt.f(), F.FNum{False{}, F.big.of(n), F.fl.eb()})

def f32.biased(+v: Nat) -> F.Fl:
  Bool.pick(F.Fl, Nat.is_le(bias(), v), f32(Nat.sub(v, bias())), F.fl.to(F.fmt.f(), F.FNum{True{}, F.big.of(Nat.sub(bias(), v)), F.fl.eb()}))

def d64(+v: Nat) -> F.Fl:
  Bool.pick(F.Fl, Nat.is_le(bias(), v), F.fl.to(F.fmt.d(), F.FNum{False{}, F.big.of(Nat.sub(v, bias())), F.fl.eb()}), F.fl.to(F.fmt.d(), F.FNum{True{}, F.big.of(Nat.sub(bias(), v)), F.fl.eb()}))

# float operations, each rounded to a float
def fadd(a: F.Fl, b: F.Fl) -> F.Fl:
  F.fl.add(F.fmt.f(), a, b)

def fmul(a: F.Fl, b: F.Fl) -> F.Fl:
  F.fl.mul(F.fmt.f(), a, b)

def fdiv(a: F.Fl, b: F.Fl) -> F.Fl:
  F.fl.div(F.fmt.f(), a, b)

def fneg(x: F.Fl) -> F.Fl:
  match x:
    case F.FNum{+neg, m, e}:
      F.FNum{Bool.not(neg), m, e}
    case F.FInf{+neg}:
      F.FInf{Bool.not(neg)}
    case F.FNaN{}:
      F.FNaN{}

def fzero(+x: F.Fl) -> Bool:
  match x:
    case F.FNum{neg, +m, e}:
      F.big.is_zero(m)
    case _:
      False{}

# a big integer below 2^48 (two limbs at most) as a Nat
def big.nat(xs: List<&2, Nat>) -> Nat:
  match xs:
    case Con{+l, Con{+h, rest}}:
      Nat.add(l, Nat.mul(h, 16777216n))
    case Con{+l, Nil{}}:
      l
    case Nil{}:
      0n

# a number m * 2^(e - eb)'s magnitude: its integer part, and whether its
# fraction is a half or more
def mag.int(+m: List<&2, Nat>, +e: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_le(F.fl.eb(), e), big.nat(F.big.shl(m, Nat.sub(e, F.fl.eb()))), big.nat(F.big.shr(m, Nat.sub(F.fl.eb(), e))))

def mag.half(+m: List<&2, Nat>, +e: Nat) -> Bool:
  Bool.and(Nat.is_lt(e, F.fl.eb()), F.big.bit(m, Nat.sub(Nat.sub(F.fl.eb(), e), 1n)))

# (int)x, cut toward 0, and round(x), a half away from 0; both biased
def trunc(x: F.Fl) -> Nat:
  match x:
    case F.FNum{+neg, +m, +e}:
      +q = mag.int(m, e)
      Bool.pick(Nat, neg, Nat.sub(bias(), q), Nat.add(bias(), q))
    case _:
      bias()

def rnd.int(x: F.Fl) -> Nat:
  match x:
    case F.FNum{+neg, +m, +e}:
      +r = Nat.add(mag.int(m, e), Bool.pick(Nat, mag.half(m, e), 1n, 0n))
      Bool.pick(Nat, neg, Nat.sub(bias(), r), Nat.add(bias(), r))
    case _:
      bias()

# the doubles Redis's code holds: 1.4142135623, M_PI/4 and M_PI/2
def lw.sqrt2() -> F.Fl:
  F.f64.to(F.F64{1073127582n, 1719285222n})

def lw.pi4() -> F.Fl:
  F.f64.to(F.F64{1072243195n, 1413754136n})

def lw.pi2() -> F.Fl:
  F.f64.to(F.F64{1073291771n, 1413754136n})

# Sines and cosines
# -----------------
# A square that is not turned has its corners at the float k0 = M_PI/4,
# then at k1, k2 and k3, each M_PI/2 more (in double, rounded to a
# float): glibc's sines and cosines of the four, as doubles' bits.
def sc.fixed(+j: Nat) -> F.Fl & F.Fl:
  match j:
    case 0n:
      (F.f64.to(F.F64{1072079006n, 1858814462n}), F.f64.to(F.F64{1072079006n, 1580414360n}))
    case 1n:
      (F.f64.to(F.F64{1072079006n, 1681639323n}), F.f64.to(F.F64{3219562654n, 1757589502n}))
    case 2n:
      (F.f64.to(F.F64{3219562654n, 1276739464n}), F.f64.to(F.F64{3219562654n, 2162489331n}))
    case _:
      (F.f64.to(F.F64{3219562654n, 2643339302n}), F.f64.to(F.F64{1072079006n, 795889389n}))

# A turned square's: k in fixed point (k * 2^20; k from -1 to 7, plus
# 2 pi, so that it is not negative), r its rest past its quarters of pi
# (the quarter q), the sine and cosine of r by their series to the 13th
# power (each term the one before times r^2 over (n + 1)(n + 2); each
# product below 2^44), which a sum biased by 2^22 adds up.
def sc.one() -> Nat:
  1048576n

def sc.pi2() -> Nat:
  1647099n

def sc.series(f: Nat, +n: Nat, +term: Nat, +r2: Nat, +odd: Bool, +acc: Nat) -> Nat:
  match f:
    case 0n:
      acc
    case 1n+g:
      +next = Nat.div(Nat.div(Nat.mul(term, r2), sc.one()), Nat.mul(Nat.add(n, 1n), Nat.add(n, 2n)))
      sc.series(g, Nat.add(n, 2n), next, r2, Bool.not(odd), Bool.pick(Nat, odd, Nat.sub(acc, term), Nat.add(acc, term)))

def sc.sin(+r: Nat) -> Nat:
  Nat.sub(sc.series(7n, 1n, r, Nat.div(Nat.mul(r, r), sc.one()), False{}, 4194304n), 4194304n)

def sc.cos(+r: Nat) -> Nat:
  Nat.sub(sc.series(7n, 0n, sc.one(), Nat.div(Nat.mul(r, r), sc.one()), False{}, 4194304n), 4194304n)

# v * 2^-20, negated or not, as a double
def sc.dbl(+neg: Bool, +v: Nat) -> F.Fl:
  Bool.pick(F.Fl, Nat.is_eq(v, 0n), F.fl.zero(neg), F.fl.to(F.fmt.d(), F.FNum{neg, F.big.of(v), Nat.sub(F.fl.eb(), 20n)}))

def sc.quarter(+q: Nat, +s: Nat, +c: Nat) -> F.Fl & F.Fl:
  match q:
    case 0n:
      (sc.dbl(False{}, s), sc.dbl(False{}, c))
    case 1n:
      (sc.dbl(False{}, c), sc.dbl(True{}, s))
    case 2n:
      (sc.dbl(True{}, s), sc.dbl(True{}, c))
    case _:
      (sc.dbl(True{}, c), sc.dbl(False{}, s))

def sc.of(+kb: Nat) -> F.Fl & F.Fl:
  +r = Nat.mod(kb, sc.pi2())
  sc.quarter(Nat.mod(Nat.div(kb, sc.pi2()), 4n), sc.sin(r), sc.cos(r))

def sc.fix(x: F.Fl) -> Nat:
  match x:
    case F.FNum{+neg, +m, +e}:
      +v = big.nat(F.big.shr(F.big.shl(m, 20n), Nat.sub(F.fl.eb(), e)))
      Bool.pick(Nat, neg, Nat.sub(Nat.mul(sc.pi2(), 4n), v), Nat.add(Nat.mul(sc.pi2(), 4n), v))
    case _:
      0n

# sin k and cos k at corner j: glibc's for a square not turned (still),
# the series' for one that is
def sc.at(still: Bool, +j: Nat, k: F.Fl) -> F.Fl & F.Fl:
  match still:
    case True{}:
      sc.fixed(j)
    case False{}:
      sc.of(sc.fix(k))

# Schotter (LOLWUT VERSION 5)
# ---------------------------

# a lit pixel (x, y, unbiased) as the code of its cell (index times 256,
# with wc cells a row) and its bit, as lwTranslatePixelsGroup lays the
# 2x4 pixels out: 0 1 2 6 down the left column, 3 4 5 7 down the right
def px.bit(+dx: Nat, +dy: Nat) -> Nat:
  match dy:
    case 3n:
      Bool.pick(Nat, Nat.is_eq(dx, 0n), 64n, 128n)
    case _:
      Bool.pick(Nat, Nat.is_eq(dx, 0n), Nat.pow(2n, dy), Nat.pow(2n, Nat.add(dy, 3n)))

def px.code(+x: Nat, +y: Nat, +wc: Nat) -> Nat:
  Nat.add(Nat.mul(Nat.add(Nat.mul(Nat.div(y, 4n), wc), Nat.div(x, 2n)), 256n), px.bit(Nat.mod(x, 2n), Nat.mod(y, 4n)))

def px.put(on: Bool, +x: Nat, +y: Nat, +wc: Nat, acc: List<&2, Nat>) -> List<&2, Nat>:
  match on:
    case True{}:
      px.code(Nat.sub(x, bias()), Nat.sub(y, bias()), wc) <> acc
    case False{}:
      acc

# a pixel (biased) lit on the canvas of w by h pixels, before acc: none
# off the canvas, as lwDrawPixel leaves it out
def px.add(+x: Nat, +y: Nat, +w: Nat, +h: Nat, acc: List<&2, Nat>) -> List<&2, Nat>:
  +inx = Bool.and(Nat.is_le(bias(), x), Nat.is_lt(x, Nat.add(bias(), w)))
  +iny = Bool.and(Nat.is_le(bias(), y), Nat.is_lt(y, Nat.add(bias(), h)))
  px.put(Bool.and(inx, iny), x, y, Nat.div(w, 2n), acc)

# twice the bias of Bresenham's error
def ln.b2() -> Nat:
  33554432n

# lwDrawLine: Bresenham's line from (x1, y1) to (x2, y2) (biased), its
# error biased by 2^24, its pixels before acc, until the pixel drawn is
# (x2, y2) (stop); fuel: one step for each pixel, and one more
def ln.go(f: Nat, stop: Bool, +x1: Nat, +y1: Nat, +x2: Nat, +y2: Nat, +dx: Nat, +dy: Nat, +sx: Bool, +sy: Bool, +err: Nat, +w: Nat, +h: Nat, acc: List<&2, Nat>) -> List<&2, Nat>:
  match f stop:
    case 0n _:
      acc
    case _ True{}:
      acc
    case 1n+g False{}:
      +acc2 = px.add(x1, y1, w, h, acc)
      +done = Bool.and(Nat.is_eq(x1, x2), Nat.is_eq(y1, y2))
      +e2 = Nat.mul(err, 2n)
      +mx = Nat.is_lt(ln.b2(), Nat.add(e2, dy))
      +my = Nat.is_lt(e2, Nat.add(ln.b2(), dx))
      +err1 = Bool.pick(Nat, mx, Nat.sub(err, dy), err)
      +x3 = Bool.pick(Nat, mx, Bool.pick(Nat, sx, Nat.add(x1, 1n), Nat.sub(x1, 1n)), x1)
      +y3 = Bool.pick(Nat, my, Bool.pick(Nat, sy, Nat.add(y1, 1n), Nat.sub(y1, 1n)), y1)
      ln.go(g, done, x3, y3, x2, y2, dx, dy, sx, sy, Bool.pick(Nat, my, Nat.add(err1, dx), err1), w, h, acc2)

def ad(+a: Nat, +b: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_le(a, b), Nat.sub(b, a), Nat.sub(a, b))

def ln(+x1: Nat, +y1: Nat, +x2: Nat, +y2: Nat, +w: Nat, +h: Nat, acc: List<&2, Nat>) -> List<&2, Nat>:
  +dx = ad(x1, x2)
  +dy = ad(y1, y2)
  ln.go(Nat.add(Nat.add(dx, dy), 2n), False{}, x1, y1, x2, y2, dx, dy, Nat.is_lt(x1, x2), Nat.is_lt(y1, y2), Nat.sub(Nat.add(16777216n, dx), dy), w, h, acc)

# a corner (x, y biased) as one Nat: x * 2^22 + y
def pt(+x: Nat, +y: Nat) -> Nat:
  Nat.add(Nat.mul(x, 4194304n), y)

def pt.x(+p: Nat) -> Nat:
  Nat.div(p, 4194304n)

def pt.y(+p: Nat) -> Nat:
  Nat.mod(p, 4194304n)

# a square's corner: round(sin(k) * size + x), round(cos(k) * size + y),
# in double (x, y biased)
def sq.corner(p: F.Fl & F.Fl, size: F.Fl, +x: Nat, +y: Nat) -> Nat:
  (s, c) = p
  +sz = size
  pt(rnd.int(F.fl.add(F.fmt.d(), F.fl.mul(F.fmt.d(), s, sz), d64(x))), rnd.int(F.fl.add(F.fmt.d(), F.fl.mul(F.fmt.d(), c, sz), d64(y))))

# k + M_PI/2, in double, rounded to a float
def sq.turn(k: F.Fl) -> F.Fl:
  F.fl.to(F.fmt.f(), F.fl.add(F.fmt.d(), k, lw.pi2()))

# the n corners from the j-th on, at k, as lwDrawSquare finds them
def sq.corners(n: Nat, still: Bool, +j: Nat, k: F.Fl, size: F.Fl, +x: Nat, +y: Nat) -> List<&2, Nat>:
  match n:
    case 0n:
      Nil{}
    case 1n+m:
      +kk = k
      +sz = size
      +st = still
      sq.corner(sc.at(st, j, kk), sz, x, y) <> sq.corners(m, st, Nat.add(j, 1n), sq.turn(kk), sz, x, y)

# the lines from each corner to the next, the last's to the first
def sq.lines(cs: List<&2, Nat>, +first: Nat, +w: Nat, +h: Nat, acc: List<&2, Nat>) -> List<&2, Nat>:
  match cs:
    case Con{+a, Con{+b, rest}}:
      sq.lines(b <> rest, first, w, h, ln(pt.x(a), pt.y(a), pt.x(b), pt.y(b), w, h, acc))
    case Con{+a, Nil{}}:
      ln(pt.x(a), pt.y(a), pt.x(first), pt.y(first), w, h, acc)
    case Nil{}:
      acc

def sq.first(+cs: List<&2, Nat>) -> Nat:
  match cs:
    case Con{+a, rest}:
      a
    case Nil{}:
      0n

def sq.draw.cs(+cs: List<&2, Nat>, +w: Nat, +h: Nat, acc: List<&2, Nat>) -> List<&2, Nat>:
  sq.lines(cs, sq.first(cs), w, h, acc)

# lwDrawSquare: the square of side `side` (a float) at (x, y) (biased),
# turned by angle (a float; still: 0), its lit pixels before acc. The
# side over 1.4142135623 (in double, to a float), rounded, is how far
# its corners are from its center.
def sq.draw(+x: Nat, +y: Nat, side: F.Fl, angle: F.Fl, still: Bool, +w: Nat, +h: Nat, acc: List<&2, Nat>) -> List<&2, Nat>:
  +size = F.fl.to(F.fmt.f(), F.fl.div(F.fmt.d(), F.fl.to(F.fmt.d(), side), lw.sqrt2()))
  +whole = d64(rnd.int(size))
  +k = F.fl.to(F.fmt.f(), F.fl.add(F.fmt.d(), lw.pi4(), F.fl.to(F.fmt.d(), angle)))
  sq.draw.cs(sq.corners(4n, still, 0n, k, whole, x, y), w, h, acc)

# (float)rand() / (float)RAND_MAX / rows * y, negated when sign (the
# rand() for it) is odd
def sch.r(+u: Nat, +rows: Nat, +y: Nat, +sign: Nat) -> F.Fl:
  +r = fmul(fdiv(fdiv(f32(u), f32(2147483647n)), f32(rows)), f32(y))
  Bool.pick(F.Fl, Nat.is_eq(Nat.mod(sign, 2n), 1n), fneg(r), r)

# a square's move: s += r * side / 3 (in float, cut to an int)
def sch.move(+s: Nat, r: F.Fl, side: F.Fl) -> Nat:
  trunc(fadd(f32.biased(s), fdiv(fmul(r, side), f32(3n))))

# a square past the second row: turned by r1, moved by r2 and r3, of six
# rand()s from st (three numbers, then their signs)
def sch.turned(+sx: Nat, +sy: Nat, side: F.Fl, +rows: Nat, +y: Nat, +w: Nat, +h: Nat, +st: U32, acc: List<&2, Nat>) -> List<&2, Nat> & U32:
  +sd = side
  +s2 = rnd.next(st)
  +s3 = rnd.next(s2)
  +s4 = rnd.next(s3)
  +s5 = rnd.next(s4)
  +s6 = rnd.next(s5)
  +r1 = sch.r(rnd(st), rows, y, rnd(s4))
  (sq.draw(sch.move(sx, sch.r(rnd(s2), rows, y, rnd(s5)), sd), sch.move(sy, sch.r(rnd(s3), rows, y, rnd(s6)), sd), sd, r1, fzero(r1), w, h, acc), rnd.next(s6))

def sch.at(turn: Bool, +sx: Nat, +sy: Nat, side: F.Fl, +rows: Nat, +y: Nat, +w: Nat, +h: Nat, +st: U32, acc: List<&2, Nat>) -> List<&2, Nat> & U32:
  match turn:
    case False{}:
      (sq.draw(sx, sy, side, F.fl.zero(False{}), True{}, w, h, acc), st)
    case True{}:
      sch.turned(sx, sy, side, rows, y, w, h, st, acc)

# the square at column x of row y: at x * side + side/2 + padding (in
# float, cut to an int), and y's likewise
def sch.square(+x: Nat, +y: Nat, side: F.Fl, +pad: Nat, +rows: Nat, +w: Nat, +h: Nat, +st: U32, acc: List<&2, Nat>) -> List<&2, Nat> & U32:
  +sd = side
  +half = fdiv(sd, f32(2n))
  +sx = trunc(fadd(fadd(fmul(f32(x), sd), half), f32(pad)))
  +sy = trunc(fadd(fadd(fmul(f32(y), sd), half), f32(pad)))
  sch.at(Nat.is_lt(1n, y), sx, sy, sd, rows, y, w, h, st, acc)

# Schotter's squares, row by row (y), each row's columns from x
type Sch is Data:
  Sch{px: List<&2, Nat>, st: U32}

def sch.px(s: Sch) -> List<&2, Nat>:
  match s:
    case Sch{px, st}:
      px

def sch.put(p: List<&2, Nat> & U32) -> Sch:
  (px, st) = p
  Sch{px, st}

def sch.row(f: Nat, s: Sch, +x: Nat, +per: Nat, +y: Nat, side: F.Fl, +pad: Nat, +rows: Nat, +w: Nat, +h: Nat) -> Sch:
  match f s:
    case 0n s0:
      s0
    case 1n+g Sch{acc, +st}:
      +sd = side
      sch.row(g, sch.put(sch.square(x, y, sd, pad, rows, w, h, st, acc)), Nat.add(x, 1n), per, y, sd, pad, rows, w, h)

def sch.rows(f: Nat, s: Sch, +y: Nat, +per: Nat, side: F.Fl, +pad: Nat, +rows: Nat, +w: Nat, +h: Nat) -> Sch:
  match f:
    case 0n:
      s
    case 1n+g:
      +sd = side
      sch.rows(g, sch.row(per, s, 0n, per, y, sd, pad, rows, w, h), Nat.add(y, 1n), per, sd, pad, rows, w, h)

# The lit pixels' codes sorted, largest first: a merge sort, its merges
# a step at a time after acc (reversed), as SORT's (redis.bend)
def srt.ge.l(+xs: List<&2, Nat>, +y: Nat) -> Bool:
  match xs:
    case Con{+x, r}:
      Nat.is_le(y, x)
    case Nil{}:
      True{}

def srt.ge.r(+x: Nat, +ys: List<&2, Nat>) -> Bool:
  match ys:
    case Con{+y, r}:
      Nat.is_le(y, x)
    case Nil{}:
      True{}

def srt.merge(f: Nat, xs: List<&2, Nat>, ys: List<&2, Nat>, ge: Bool, acc: List<&2, Nat>) -> List<&2, Nat>:
  match f xs ys ge:
    case 0n a b _:
      List.reverse.go(&2, Nat, acc, List.append(&2, Nat, a, b))
    case _ Nil{} b _:
      List.reverse.go(&2, Nat, acc, b)
    case _ a Nil{} _:
      List.reverse.go(&2, Nat, acc, a)
    case 1n+g Con{x, +xt} Con{+y, +yt} True{}:
      srt.merge(g, xt, Con{y, yt}, srt.ge.l(xt, y), x <> acc)
    case 1n+g Con{+x, +xt} Con{y, +yt} False{}:
      srt.merge(g, Con{x, xt}, yt, srt.ge.r(x, yt), y <> acc)

def srt.two(+n: Nat, +a: List<&2, Nat>, +b: List<&2, Nat>) -> List<&2, Nat>:
  match a:
    case Con{+x, r}:
      srt.merge(n, a, b, srt.ge.r(x, b), Nil{})
    case Nil{}:
      b

# each code a run of its own; the runs merged two by two, pass after
# pass, until one is left (fuel: a pass for each code, more than enough)
def srt.runs(xs: List<&2, Nat>, acc: List<&2, List<&2, Nat>>) -> List<&2, List<&2, Nat>>:
  match xs:
    case Nil{}:
      acc
    case Con{x, rest}:
      srt.runs(rest, [x] <> acc)

def srt.pass(rs: List<&2, List<&2, Nat>>, +n: Nat, acc: List<&2, List<&2, Nat>>) -> List<&2, List<&2, Nat>>:
  match rs:
    case Con{+a, Con{+b, rest}}:
      srt.pass(rest, n, srt.two(n, a, b) <> acc)
    case Con{a, Nil{}}:
      a <> acc
    case Nil{}:
      acc

def srt.passes(f: Nat, rs: List<&2, List<&2, Nat>>, +n: Nat) -> List<&2, Nat>:
  match f rs:
    case _ Nil{}:
      Nil{}
    case _ Con{r, Nil{}}:
      r
    case 0n other:
      List.concat(&2, Nat, other)
    case 1n+g other:
      srt.passes(g, srt.pass(other, n, Nil{}), n)

def srt(xs: List<&2, Nat>) -> List<&2, Nat>:
  +ys = xs
  +n = List.length(&2, Nat, ys)
  srt.passes(n, srt.runs(ys, Nil{}), n)

# The braille text (renderCanvas): a row of wc cells for each 4 rows of
# pixels, each cell U+2800 plus its bits in UTF-8, each row followed by a
# newline but for a row of cells that starts on the canvas's last row of
# pixels; built from its end, the codes largest first.

# the bits of cell c at the head of the codes, or-ed, and the codes after
def rd.hit(+cs: List<&2, Nat>, +c: Nat) -> Bool:
  match cs:
    case Con{+x, r}:
      Nat.is_eq(Nat.div(x, 256n), c)
    case Nil{}:
      False{}

def rd.take(cs: List<&2, Nat>, hit: Bool, +c: Nat, +acc: U32) -> U32 & List<&2, Nat>:
  match cs hit:
    case Con{+x, +rest} True{}:
      rd.take(rest, rd.hit(rest, c), c, U32.or(acc, U32.from_nat(Nat.mod(x, 256n))))
    case other _:
      (acc, other)

def rd.char(+b: U32, acc: String) -> String:
  SCon{Chr{226}, SCon{Chr{U32.add(160, U32.shrn(b, 6n))}, SCon{Chr{U32.add(128, U32.and(b, 63))}, acc}}}

def rd.cell(p: U32 & List<&2, Nat>, acc: String) -> List<&2, Nat> & String:
  (b, rest) = p
  (rest, rd.char(b, acc))

# a row's cx cells, the last of them cell c, before acc
def rd.row(cx: Nat, +c: Nat, p: List<&2, Nat> & String) -> List<&2, Nat> & String:
  match cx:
    case 0n:
      p
    case 1n+i:
      (cs, acc) = p
      +ks = cs
      rd.row(i, Nat.sub(c, 1n), rd.cell(rd.take(ks, rd.hit(ks, c), c, 0), acc))

def nl.if(on: Bool, acc: String) -> String:
  match on:
    case True{}:
      SCon{'\n', acc}
    case False{}:
      acc

# cy rows of cells, before acc: the last of them starts at the canvas's
# row of pixels top, and its last cell is cell last
def rd.rows(cy: Nat, +last: Nat, +top: Nat, +wc: Nat, +h: Nat, p: List<&2, Nat> & String) -> String:
  match cy:
    case 0n:
      (cs, acc) = p
      acc
    case 1n+r:
      (cs, acc) = p
      rd.rows(r, Nat.sub(last, wc), Nat.sub(top, 4n), wc, h, rd.row(wc, last, (cs, nl.if(Nat.is_ne(top, Nat.sub(h, 1n)), acc))))

# LOLWUT VERSION 5 of cols columns, per squares a row, rows rows (all
# clamped by the parser): the canvas is 2 * cols pixels wide, with a
# padding of 2 past 4 of them, the squares' side (width - 2 * padding) /
# per, its height side * rows + 2 * padding (in float, cut to an int)
def num(+s: String) -> Nat:
  String.dec_at(s, 0n, String.length(s))

def five.go(+cols: Nat, +per: Nat, +rows: Nat, +st: U32) -> String:
  +w = Nat.mul(cols, 2n)
  +pad = Bool.pick(Nat, Nat.is_lt(4n, w), 2n, 0n)
  +side = fdiv(f32(Nat.sub(w, Nat.mul(pad, 2n))), f32(per))
  +h = Nat.sub(trunc(fadd(fmul(side, f32(rows)), f32(Nat.mul(pad, 2n)))), bias())
  +s = sch.rows(rows, Sch{Nil{}, st}, 0n, per, side, pad, rows, w, h)
  +hc = Nat.div(Nat.add(h, 3n), 4n)
  +wc = Nat.div(w, 2n)
  rd.rows(hc, Nat.sub(Nat.mul(hc, wc), 1n), Nat.mul(Nat.sub(hc, 1n), 4n), wc, h, (srt(sch.px(s)), "\nGeorg Nees - schotter, plotter on paper, 1968. Redis ver. 7.0.15\n"))

def five(+args: List<&2, String>, +seed: U32) -> String:
  match args:
    case Con{+c, Con{+p, Con{+r, rest}}}:
      five.go(num(c), num(p), num(r), seed)
    case _:
      ""

# Skyscrapers (LOLWUT VERSION 6)
# ------------------------------
# A skyscraper: its left edge (biased by 16: the first is at -10 or a
# little more), its width and height, whether it has windows, its color
# (2 and 1 the grays behind, 0 the black of those in front), and the seed
# of its windows' colors
type Sky is Data:
  Sky{x: Nat, w: Nat, h: Nat, win: Bool, color: Nat, seed: U32}

# generateSkyline's numbers: a width (5 + rand() % 14 in front, made a
# multiple of 4 plus its rest by 3 when it is none; 10 + rand() % 9
# behind), a height (h/2 + (rand() % h)/2 for the lighter gray, h/2 +
# (rand() % h)/3 for the darker, h/3 + (rand() % h)/2 in front), and how
# far the next one starts (half the width, the width and 1, the width
# and 5)
def sky.width(+color: Nat, +r: Nat) -> Nat:
  +w0 = Nat.add(5n, Nat.mod(r, 14n))
  Bool.pick(Nat, Nat.is_eq(color, 0n), Bool.pick(Nat, Nat.is_eq(Nat.mod(w0, 4n), 0n), w0, Nat.add(w0, Nat.mod(w0, 3n))), Nat.add(10n, Nat.mod(r, 9n)))

def sky.height(+color: Nat, +ch: Nat, +r: Nat) -> Nat:
  +m = Nat.mod(r, ch)
  Bool.pick(Nat, Nat.is_eq(color, 2n), Nat.add(Nat.div(ch, 2n), Nat.div(m, 2n)), Bool.pick(Nat, Nat.is_eq(color, 1n), Nat.add(Nat.div(ch, 2n), Nat.div(m, 3n)), Nat.add(Nat.div(ch, 3n), Nat.div(m, 2n))))

def sky.after(+color: Nat, +x: Nat, +w: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_eq(color, 2n), Nat.add(x, Nat.div(w, 2n)), Bool.pick(Nat, Nat.is_eq(color, 1n), Nat.add(x, Nat.add(w, 1n)), Nat.add(x, Nat.add(w, 5n))))

# a pass of skyscrapers of a color, from off (biased) while off is left
# of the canvas's right edge (go), each before acc (the newest first);
# four rand()s each: its move (rand() % 8), width, height, windows
def sky.pass(f: Nat, go: Bool, +color: Nat, +off: Nat, +cw: Nat, +ch: Nat, +st: U32, acc: List<&2, Sky>) -> List<&2, Sky> & U32:
  match f go:
    case 1n+g True{}:
      +s1 = rnd.next(st)
      +s2 = rnd.next(s1)
      +s3 = rnd.next(s2)
      +x = Nat.add(off, Nat.mod(rnd(st), 8n))
      +w = sky.width(color, rnd(s1))
      +next = sky.after(color, x, w)
      sky.pass(g, Nat.is_lt(next, Nat.add(cw, 16n)), color, next, cw, ch, rnd.next(s3), Sky{x, w, sky.height(color, ch, rnd(s2)), Nat.is_eq(color, 0n), color, s3} <> acc)
    case _ _:
      (acc, st)

# whether a skyscraper is over pixel (x, y) of a canvas ch high (x
# biased): its rows from the canvas's last up, its roof two pixels
# narrower each side
def sky.over(+b: Sky, +x: Nat, +y: Nat, +ch: Nat) -> Bool:
  match b:
    case Sky{+bx, +bw, +bh, win, color, seed}:
      +endy = Nat.sub(ch, bh)
      +roof = Bool.and(Nat.is_eq(y, endy), Bool.or(Nat.is_le(x, Nat.add(bx, 1n)), Nat.is_le(Nat.sub(Nat.add(bx, bw), 2n), x)))
      Bool.and(Bool.and(Bool.and(Nat.is_lt(0n, bh), Nat.is_le(endy, y)), Bool.and(Nat.is_le(bx, x), Nat.is_lt(x, Nat.add(bx, bw)))), Bool.not(roof))

# a window's color: one of the two grays, at random
def sky.wc(+seed: U32, +relx: Nat, +rely: Nat) -> Nat:
  Nat.add(1n, Nat.mod(rnd(U32.xor(seed, U32.from_nat(Nat.add(Nat.mul(rely, 4096n), relx)))), 2n))

# a skyscraper's color at a pixel of it: a window's, inside its border
# (a pixel each side, two above and below), on every other row, in pairs
# of columns every four; the second of a pair the first's color, which is
# the canvas's black when the first is left of the canvas
def sky.win(+seed: U32, +relx: Nat, +rely: Nat, +x: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_eq(Nat.mod(relx, 2n), 1n), Bool.pick(Nat, Nat.is_lt(16n, x), sky.wc(seed, Nat.sub(relx, 1n), rely), 0n), sky.wc(seed, relx, rely))

def sky.paint(+b: Sky, +x: Nat, +y: Nat, +ch: Nat) -> Nat:
  match b:
    case Sky{+bx, +bw, +bh, +win, +color, +seed}:
      +endy = Nat.sub(ch, bh)
      +inner = Bool.and(Bool.and(Nat.is_lt(Nat.add(bx, 1n), x), Nat.is_lt(Nat.add(x, 2n), Nat.add(bx, bw))), Bool.and(Nat.is_lt(Nat.add(endy, 1n), y), Nat.is_lt(Nat.add(y, 2n), ch)))
      +relx = Nat.sub(x, Nat.add(bx, 1n))
      +rely = Nat.sub(y, Nat.add(endy, 1n))
      +lit = Bool.and(Bool.and(win, inner), Bool.and(Nat.is_eq(Nat.mod(Nat.div(relx, 2n), 2n), 1n), Nat.is_eq(Nat.mod(rely, 2n), 1n)))
      Bool.pick(Nat, lit, sky.win(seed, relx, rely, x), color)

def sky.paint.if(on: Bool, +b: Sky, +x: Nat, +y: Nat, +ch: Nat) -> Nat:
  match on:
    case True{}:
      sky.paint(b, x, y, ch)
    case False{}:
      3n

# the color of pixel (x, y): the last skyscraper drawn over it (bs, the
# newest first; done: found), else the canvas's white
def sky.at(bs: List<&2, Sky>, done: Bool, +x: Nat, +y: Nat, +ch: Nat, +acc: Nat) -> Nat:
  match bs done:
    case _ True{}:
      acc
    case Nil{} False{}:
      3n
    case Con{+b, rest} False{}:
      +on = sky.over(b, x, y, ch)
      sky.at(rest, on, x, y, ch, sky.paint.if(on, b, x, y, ch))

# a pixel as renderCanvas writes it: a space with the color as both its
# foreground and its background, then the colors reset
def sky.code(+c: Nat) -> String:
  match c:
    case 0n:
      "0;30;40m"
    case 1n:
      "0;90;100m"
    case 2n:
      "0;37;47m"
    case _:
      "0;97;107m"

def sky.put(+c: Nat, acc: String) -> String:
  SCon{Chr{27}, SCon{'[', sky.code(c) ++ SCon{' ', SCon{Chr{27}, SCon{'[', SCon{'0', SCon{'m', acc}}}}}}}

# a row's cx pixels, the last of them at x (biased by 16), before acc
def sky.row(cx: Nat, +x: Nat, +y: Nat, +ch: Nat, +bs: List<&2, Sky>, acc: String) -> String:
  match cx:
    case 0n:
      acc
    case 1n+i:
      sky.row(i, Nat.sub(x, 1n), y, ch, bs, sky.put(sky.at(bs, False{}, x, y, ch, 3n), acc))

# cy rows of pixels, the last of them row y, before acc
def sky.rows(cy: Nat, +y: Nat, +cw: Nat, +ch: Nat, +bs: List<&2, Sky>, acc: String) -> String:
  match cy:
    case 0n:
      acc
    case 1n+r:
      sky.rows(r, Nat.sub(y, 1n), cw, ch, bs, sky.row(cw, Nat.add(cw, 15n), y, ch, bs, nl.if(Nat.is_ne(Nat.add(y, 1n), ch), acc)))

def six.end() -> String:
  "\nDedicated to the 8 bit game developers of past and present.\nOriginal 8 bit image from Plaguemon by hikikomori. Redis ver. 7.0.15\n"

def six.front(p: List<&2, Sky> & U32, +cw: Nat, +ch: Nat) -> String:
  (bs, st) = p
  +b = bs
  sky.rows(ch, Nat.sub(ch, 1n), cw, ch, b, six.end())

def six.mid(p: List<&2, Sky> & U32, +cw: Nat, +ch: Nat) -> String:
  (bs, st) = p
  six.front(sky.pass(Nat.add(cw, 32n), True{}, 0n, 6n, cw, ch, st, bs), cw, ch)

def six.back(p: List<&2, Sky> & U32, +cw: Nat, +ch: Nat) -> String:
  (bs, st) = p
  six.mid(sky.pass(Nat.add(cw, 32n), True{}, 1n, 6n, cw, ch, st, bs), cw, ch)

# LOLWUT VERSION 6 of cw columns and ch rows (clamped by the parser): the
# lighter gray skyscrapers, the darker ones, then those in front
def six.go(+cw: Nat, +ch: Nat, +st: U32) -> String:
  six.back(sky.pass(Nat.add(cw, 32n), True{}, 2n, 6n, cw, ch, st, Nil{}), cw, ch)

def six(+args: List<&2, String>, +seed: U32) -> String:
  match args:
    case Con{+c, Con{+r, rest}}:
      six.go(num(c), num(r), seed)
    case _:
      ""
