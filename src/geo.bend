# geo.bend: the positions of GEOADD and its kin, as Redis 7.0.15 keeps
# and searches them (geo.c, geohash.c, geohash_helper.c).
#
# A position is a member of a sorted set whose score is its geohash: its
# longitude and latitude, each as 26 bits of their place in their range
# (-180 to 180, and -85.05112878 to 85.05112878, as Redis takes them),
# interleaved into an integer of 52 bits. A search takes the cell of the
# geohash around its center whose size its radius picks, and the eight
# cells around that one, reads the members whose scores fall in each, and
# keeps those within its circle or its box, by the great-circle distance
# (haversine) on a sphere of Redis's radius.
#
# The numbers are C doubles, each operation as Redis's C code makes it,
# in its order: base's F64 natives run C's own double arithmetic and
# libm's sin, cos and asin, so that a distance is the double Redis
# computes on the same libm. A double travels as the two 32-bit halves of
# its bits (D), a 64-bit integer as its two halves too (W).

import Base
import ./float.bend as F
import ./map.bend as KV

# Doubles
# -------

type D is Data:
  D{h: U32, l: U32}

def d.of(r: U32 & U32) -> D:
  (h, l) = r
  D{h, l}

def d.add(a: D, b: D) -> D:
  match a b:
    case D{ah, al} D{bh, bl}:
      d.of(F64.add(ah, al, bh, bl))

def d.sub(a: D, b: D) -> D:
  match a b:
    case D{ah, al} D{bh, bl}:
      d.of(F64.sub(ah, al, bh, bl))

def d.mul(a: D, b: D) -> D:
  match a b:
    case D{ah, al} D{bh, bl}:
      d.of(F64.mul(ah, al, bh, bl))

def d.div(a: D, b: D) -> D:
  match a b:
    case D{ah, al} D{bh, bl}:
      d.of(F64.div(ah, al, bh, bl))

def d.sqrt(a: D) -> D:
  match a:
    case D{h, l}:
      d.of(F64.sqrt(h, l))

def d.sin(a: D) -> D:
  match a:
    case D{h, l}:
      d.of(F64.sin(h, l))

def d.cos(a: D) -> D:
  match a:
    case D{h, l}:
      d.of(F64.cos(h, l))

def d.asin(a: D) -> D:
  match a:
    case D{h, l}:
      d.of(F64.asin(h, l))

def d.abs(a: D) -> D:
  match a:
    case D{h, l}:
      d.of(F64.abs(h, l))

def d.lt(a: D, b: D) -> Bool:
  match a b:
    case D{ah, al} D{bh, bl}:
      F64.is_lt(ah, al, bh, bl)

def d.gt(a: D, b: D) -> Bool:
  match a b:
    case D{ah, al} D{bh, bl}:
      F64.is_gt(ah, al, bh, bl)

def d.ge(a: D, b: D) -> Bool:
  match a b:
    case D{ah, al} D{bh, bl}:
      F64.is_ge(ah, al, bh, bl)

def d.eq(a: D, b: D) -> Bool:
  match a b:
    case D{ah, al} D{bh, bl}:
      F64.is_eq(ah, al, bh, bl)

# a U32 as the double it is
def d.u32(x: U32) -> D:
  d.of(U32.to_f64(x))

# 2^n, n below 32, as a double: (double)(1ULL << n)
def d.pow2(+n: Nat) -> D:
  d.u32(U32.shln(1, n))

# the double that s reads as, as Redis's string2d reads one (a NaN when
# it does not read)
def d.read(s: String) -> D:
  d.of(F64.read(s))

def d.is_nan(+a: D) -> Bool:
  Bool.not(d.eq(a, a))

# a sorted set's score (float.bend keeps a double's bits as two Nats) as
# a D, and back
def d.of_score(+x: F.F64) -> D:
  match x:
    case F.F64{+hi, +lo}:
      D{U32.from_nat(hi), U32.from_nat(lo)}

def d.score(a: D) -> F.F64:
  match a:
    case D{h, l}:
      F.F64{U32.to_nat(h), U32.to_nat(l)}

# Redis's constants (geohash.h, geohash_helper.c)
def geo.lat_max() -> D:
  D{1079329605, 2980413184}

def geo.lat_min() -> D:
  D{3226813253, 2980413184}

def geo.lon_max() -> D:
  D{1080459264, 0}

def geo.lon_min() -> D:
  D{3227942912, 0}

# D_R, M_PI / 180.0
def geo.d_r() -> D:
  D{1066524486, 2723323193}

# EARTH_RADIUS_IN_METERS, 6372797.560856
def geo.earth() -> D:
  D{1096306543, 1675956368}

# 2.0 * EARTH_RADIUS_IN_METERS
def geo.earth2() -> D:
  D{1097355119, 1675956368}

# MERCATOR_MAX, 20037726.37
def geo.merc() -> D:
  D{1098062853, 3857417503}

def d.zero() -> D:
  D{0, 0}

def d.two() -> D:
  D{1073741824, 0}

# 2^63, where C's conversion of a double to uint64_t changes its way
def d.two63() -> D:
  D{1138753536, 0}

def deg_rad(a: D) -> D:
  d.mul(a, geo.d_r())

def rad_deg(a: D) -> D:
  d.div(a, geo.d_r())

# 64-bit words
# ------------

type W is Data:
  W{h: U32, l: U32}

def w.and(a: W, b: W) -> W:
  match a b:
    case W{ah, al} W{bh, bl}:
      W{U32.and(ah, bh), U32.and(al, bl)}

def w.or(a: W, b: W) -> W:
  match a b:
    case W{ah, al} W{bh, bl}:
      W{U32.or(ah, bh), U32.or(al, bl)}

def w.xor(a: W, b: W) -> W:
  match a b:
    case W{ah, al} W{bh, bl}:
      W{U32.xor(ah, bh), U32.xor(al, bl)}

# a + b and a - b, modulo 2^64
def w.add(a: W, b: W) -> W:
  match a b:
    case W{ah, +al} W{bh, bl}:
      +lo = U32.add(al, bl)
      W{U32.add(U32.add(ah, bh), Bool.pick(U32, U32.is_lt(lo, al), 1, 0)), lo}

def w.sub(a: W, b: W) -> W:
  match a b:
    case W{ah, +al} W{bh, +bl}:
      W{U32.sub(U32.sub(ah, bh), Bool.pick(U32, U32.is_lt(al, bl), 1, 0)), U32.sub(al, bl)}

def w.inc(a: W) -> W:
  w.add(a, W{0, 1})

# a shifted left or right by n bits, n below 64
def w.shl.of(big: Bool, +h: U32, +l: U32, +n: Nat) -> W:
  match big:
    case True{}:
      W{U32.shln(l, Nat.sub(n, 32n)), 0}
    case False{}:
      W{U32.or(U32.shln(h, n), U32.shrn(l, Nat.sub(32n, n))), U32.shln(l, n)}

def w.shl(a: W, +n: Nat) -> W:
  match a:
    case W{+h, +l}:
      w.shl.of(Nat.is_le(32n, n), h, l, n)

def w.shr.of(big: Bool, +h: U32, +l: U32, +n: Nat) -> W:
  match big:
    case True{}:
      W{0, U32.shrn(h, Nat.sub(n, 32n))}
    case False{}:
      W{U32.shrn(h, n), U32.or(U32.shrn(l, n), U32.shln(h, Nat.sub(32n, n)))}

def w.shr(a: W, +n: Nat) -> W:
  match a:
    case W{+h, +l}:
      w.shr.of(Nat.is_le(32n, n), h, l, n)

def w.is_eq(a: W, b: W) -> Bool:
  match a b:
    case W{ah, al} W{bh, bl}:
      Bool.and(U32.is_eq(ah, bh), U32.is_eq(al, bl))

def w.zero() -> W:
  W{0, 0}

# a 64-bit unsigned integer as the nearest double, as C converts it
def d.of_w(w: W) -> D:
  match w:
    case W{h, l}:
      d.of(F64.of_u64(h, l))

def w.of_pair(r: U32 & U32) -> W:
  (h, l) = r
  W{h, l}

def w.of_i64(a: D) -> W:
  match a:
    case D{h, l}:
      w.of_pair(F64.to_i64(h, l))

# C's conversion of a double to uint64_t, as gcc makes it on x86-64: below
# 2^63 (or NaN) cvttsd2si's integer, cut toward 0; else that of d - 2^63,
# with its top bit flipped (2^63 for NaN and for what passes the range of
# each, where C says nothing)
def w.of_d.big(big: Bool, a: D) -> W:
  match big:
    case True{}:
      w.xor(w.of_i64(d.sub(a, d.two63())), W{2147483648, 0})
    case False{}:
      w.of_i64(a)

def w.of_d(+a: D) -> W:
  w.of_d.big(d.ge(a, d.two63()), a)

# Interleaving
# ------------
# interleave64 and deinterleave64: x's bits at the even places, y's at
# the odd ones, sixteen at a time

def spread16(+v: U32) -> U32:
  +a = U32.and(U32.or(v, U32.shln(v, 8n)), 16711935)
  +b = U32.and(U32.or(a, U32.shln(a, 4n)), 252645135)
  +c = U32.and(U32.or(b, U32.shln(b, 2n)), 858993459)
  U32.and(U32.or(c, U32.shln(c, 1n)), 1431655765)

def interleave(+x: U32, +y: U32) -> W:
  +lo = U32.or(spread16(U32.and(x, 65535)), U32.shln(spread16(U32.and(y, 65535)), 1n))
  +hi = U32.or(spread16(U32.shrn(x, 16n)), U32.shln(spread16(U32.shrn(y, 16n)), 1n))
  W{hi, lo}

# the even bits of v, packed into its low 16
def compact16(+v: U32) -> U32:
  +a = U32.and(v, 1431655765)
  +b = U32.and(U32.or(a, U32.shrn(a, 1n)), 858993459)
  +c = U32.and(U32.or(b, U32.shrn(b, 2n)), 252645135)
  +e = U32.and(U32.or(c, U32.shrn(c, 4n)), 16711935)
  U32.and(U32.or(e, U32.shrn(e, 8n)), 65535)

# the bits at the even places of w (x, the latitude's) and at the odd
# ones (y, the longitude's)
def deint.x(+w: W) -> U32:
  match w:
    case W{+h, +l}:
      U32.or(compact16(l), U32.shln(compact16(h), 16n))

def deint.y(+w: W) -> U32:
  match w:
    case W{+h, +l}:
      U32.or(compact16(U32.shrn(l, 1n)), U32.shln(compact16(U32.shrn(h, 1n)), 16n))

# Geohashes
# ---------

# a geohash: its bits and its step (bits per coordinate); a step of 0 is
# a cell left out (GZERO)
type Hash is Data:
  Hash{bits: W, step: Nat}

# a cell: its latitudes and its longitudes, from min to max
type Area is Data:
  Area{lat0: D, lat1: D, lon0: D, lon1: D}

# a range of a coordinate
type Rng is Data:
  Rng{lo: D, hi: D}

def geo.lon_rng() -> Rng:
  Rng{geo.lon_min(), geo.lon_max()}

def geo.lat_rng() -> Rng:
  Rng{geo.lat_min(), geo.lat_max()}

def u32.low(r: U32 & U32) -> U32:
  (h, l) = r
  l

# (uint32_t)x for x in [0, 2^32): the integer part
def u32.of_d(a: D) -> U32:
  match a:
    case D{h, l}:
      u32.low(F64.to_i64(h, l))

def rng.offset(r: Rng, +x: D, +p: D) -> U32:
  match r:
    case Rng{+lo, +hi}:
      u32.of_d(d.mul(d.div(d.sub(x, lo), d.sub(hi, lo)), p))

def rng.out(+r: Rng, +x: D) -> Bool:
  match r:
    case Rng{+lo, +hi}:
      Bool.or(d.lt(x, lo), d.gt(x, hi))

# geohashEncode: the cell of the step that holds (lon, lat), in ranges ln
# and lt; bits 0 when the point is out of Redis's ranges or of these
def geo.encode.of(out: Bool, +ln: Rng, +lt: Rng, +lon: D, +lat: D, +step: Nat) -> Hash:
  match out:
    case True{}:
      Hash{w.zero(), step}
    case False{}:
      +p = d.pow2(step)
      Hash{interleave(rng.offset(lt, lat, p), rng.offset(ln, lon, p)), step}

def geo.encode(+ln: Rng, +lt: Rng, +lon: D, +lat: D, +step: Nat) -> Hash:
  +bad = Bool.or(rng.out(geo.lon_rng(), lon), rng.out(geo.lat_rng(), lat))
  geo.encode.of(Bool.or(bad, Bool.or(rng.out(ln, lon), rng.out(lt, lat))), ln, lt, lon, lat, step)

# the coordinate i (an integer from 0 to 2^step) of range r: r's low end
# plus i / 2^step of its width
def rng.at(+r: Rng, +i: U32, +p: D) -> D:
  match r:
    case Rng{+lo, +hi}:
      d.add(lo, d.mul(d.div(d.u32(i), p), d.sub(hi, lo)))

# geohashDecode: the cell a geohash stands for
def geo.decode(+ln: Rng, +lt: Rng, +h: Hash) -> Area:
  match h:
    case Hash{+bits, +step}:
      +p = d.pow2(step)
      +x = deint.x(bits)
      +y = deint.y(bits)
      Area{rng.at(lt, x, p), rng.at(lt, U32.add(x, 1), p), rng.at(ln, y, p), rng.at(ln, U32.add(y, 1), p)}

def d.clamp(+x: D, +lo: D, +hi: D) -> D:
  +a = Bool.pick(D, d.gt(x, hi), hi, x)
  Bool.pick(D, d.lt(a, lo), lo, a)

# geohashDecodeAreaToLongLat: a cell's middle, within Redis's ranges
def area.lon(+a: Area) -> D:
  match a:
    case Area{lat0, lat1, +lon0, +lon1}:
      d.clamp(d.div(d.add(lon0, lon1), d.two()), geo.lon_min(), geo.lon_max())

def area.lat(+a: Area) -> D:
  match a:
    case Area{+lat0, +lat1, lon0, lon1}:
      d.clamp(d.div(d.add(lat0, lat1), d.two()), geo.lat_min(), geo.lat_max())

# a position: its longitude and latitude
type Pos is Data:
  Pos{lon: D, lat: D}

# decodeGeohash: the position a score stands for (the score cut to an
# integer as C does, a geohash of step 26)
def geo.pos(+score: D) -> Pos:
  +a = geo.decode(geo.lon_rng(), geo.lat_rng(), Hash{w.of_d(score), 26n})
  Pos{area.lon(a), area.lat(a)}

# geohashAlign52Bits: a geohash's bits as a score's 52
def geo.align(+h: Hash) -> W:
  match h:
    case Hash{+bits, +step}:
      w.shl(bits, Nat.sub(52n, Nat.mul(step, 2n)))

# GEOADD's score of a position: its geohash of step 26
def geo.score(+lon: D, +lat: D) -> W:
  geo.align(geo.encode(geo.lon_rng(), geo.lat_rng(), lon, lat, 26n))

# Neighbors
# ---------
# geohash_move_x and geohash_move_y: the cell east (d 1) or west (0) of
# h, and north or south, wrapping around at the ends

def even64() -> W:
  W{1431655765, 1431655765}

def odd64() -> W:
  W{2863311530, 2863311530}

def geo.move.x(+h: Hash, east: Bool) -> Hash:
  match h:
    case Hash{+bits, +step}:
      +sh = Nat.sub(64n, Nat.mul(step, 2n))
      +x = w.and(bits, odd64())
      +y = w.and(bits, even64())
      +zz = w.shr(even64(), sh)
      +x2 = Bool.pick(W, east, w.add(x, w.inc(zz)), w.sub(w.or(x, zz), w.inc(zz)))
      Hash{w.or(w.and(x2, w.shr(odd64(), sh)), y), step}

def geo.move.y(+h: Hash, north: Bool) -> Hash:
  match h:
    case Hash{+bits, +step}:
      +sh = Nat.sub(64n, Nat.mul(step, 2n))
      +x = w.and(bits, odd64())
      +y = w.and(bits, even64())
      +zz = w.shr(odd64(), sh)
      +y2 = Bool.pick(W, north, w.add(y, w.inc(zz)), w.sub(w.or(y, zz), w.inc(zz)))
      Hash{w.or(x, w.and(y2, w.shr(even64(), sh))), step}

# Distances
# ---------

# geohashGetLatDistance
def geo.lat_dist(+lat1: D, +lat2: D) -> D:
  d.mul(geo.earth(), d.abs(d.sub(deg_rad(lat2), deg_rad(lat1))))

def geo.dist.of(zero: Bool, +lat1: D, +lat2: D, +v: D) -> D:
  match zero:
    case True{}:
      geo.lat_dist(lat1, lat2)
    case False{}:
      +lat1r = deg_rad(lat1)
      +lat2r = deg_rad(lat2)
      +u = d.sin(d.div(d.sub(lat2r, lat1r), d.two()))
      +a = d.add(d.mul(u, u), d.mul(d.mul(d.mul(d.cos(lat1r), d.cos(lat2r)), v), v))
      d.mul(geo.earth2(), d.asin(d.sqrt(a)))

# geohashGetDistance: the haversine distance from (lon1, lat1) to (lon2,
# lat2), in m; along a meridian when the longitudes' sine is 0
def geo.dist(+lon1: D, +lat1: D, +lon2: D, +lat2: D) -> D:
  +v = d.sin(d.div(d.sub(deg_rad(lon2), deg_rad(lon1)), d.two()))
  geo.dist.of(d.eq(v, d.zero()), lat1, lat2, v)

# Searches
# --------

# a search's shape, in units of conv meters: a circle of radius r
# (GEORADIUS, BYRADIUS) or a box w wide and h high (BYBOX)
type Shape is Data:
  Circle{r: D}
  Box{w: D, h: D}

# a search: around (lon, lat), of a shape, in a unit of conv meters
type Search is Data:
  Search{lon: D, lat: D, s: Shape, conv: D}

def d.half(+a: D) -> D:
  d.div(a, d.two())

# geohashEstimateStepsByRadius: how many times the range doubles before
# it reaches MERCATOR_MAX (fuel bounds them: a subnormal range takes some
# 1,100)
def steps.doublings(fuel: Nat, go: Bool, +r: D, +k: Nat) -> Nat:
  match fuel go:
    case 0n _:
      k
    case 1n+f False{}:
      k
    case 1n+f True{}:
      +r2 = d.mul(r, d.two())
      steps.doublings(f, d.lt(r2, geo.merc()), r2, Nat.add(k, 1n))

# steps fewer toward the poles: one past 66 degrees, two past 80
def steps.pole(+lat: D) -> Nat:
  +far = Bool.or(d.gt(lat, D{1079017472, 0}), d.lt(lat, D{3226501120, 0}))
  +farther = Bool.or(d.gt(lat, D{1079246848, 0}), d.lt(lat, D{3226730496, 0}))
  Bool.pick(Nat, far, Bool.pick(Nat, farther, 2n, 1n), 0n)

def geo.steps.of(zero: Bool, +r: D, +lat: D) -> Nat:
  match zero:
    case True{}:
      26n
    case False{}:
      +k = steps.doublings(2000n, d.lt(r, geo.merc()), r, 0n)
      +cut = Nat.add(1n, steps.pole(lat))
      Bool.pick(Nat, Nat.is_le(k, cut), 1n, Nat.min(Nat.sub(k, cut), 26n))

# the step whose cells a search of range r m at latitude lat reads: 1 +
# the doublings - 2, fewer toward the poles, from 1 to 26 (26 for 0)
def geo.steps(+r: D, +lat: D) -> Nat:
  geo.steps.of(d.eq(r, d.zero()), r, lat)

# the bounds of a search, as geohashBoundingBox finds them
type BBox is Data:
  BBox{lon0: D, lat0: D, lon1: D, lat1: D}

# half the height and half the width, in m (a circle's radius both)
def shape.half_h(+s: Shape, +conv: D) -> D:
  match s:
    case Circle{+r}:
      d.mul(conv, r)
    case Box{+w, +h}:
      d.mul(conv, d.half(h))

def shape.half_w(+s: Shape, +conv: D) -> D:
  match s:
    case Circle{+r}:
      d.mul(conv, r)
    case Box{+w, +h}:
      d.mul(conv, d.half(w))

# a longitude's delta at latitude lat for a width of w m
def bbox.dlon(+w: D, +lat: D) -> D:
  rad_deg(d.div(d.div(w, geo.earth()), d.cos(deg_rad(lat))))

def geo.bbox(+lon: D, +lat: D, +s: Shape, +conv: D) -> BBox:
  +dlat = rad_deg(d.div(shape.half_h(s, conv), geo.earth()))
  +w = shape.half_w(s, conv)
  +dl = Bool.pick(D, d.lt(lat, d.zero()), bbox.dlon(w, d.sub(lat, dlat)), bbox.dlon(w, d.add(lat, dlat)))
  BBox{d.sub(lon, dl), d.sub(lat, dlat), d.add(lon, dl), d.add(lat, dlat)}

# the range, in m, that picks a search's step: a circle's radius, a box's
# half diagonal
def shape.range(+s: Shape, +conv: D) -> D:
  match s:
    case Circle{+r}:
      d.mul(r, conv)
    case Box{+w, +h}:
      +hw = d.half(w)
      +hh = d.half(h)
      d.mul(d.sqrt(d.add(d.mul(hw, hw), d.mul(hh, hh))), conv)

# the nine cells a search reads, in Redis's order: its center's, then
# north, south, east, west, north-east, north-west, south-east and
# south-west of it; a cell left out has step 0
def hash.zero() -> Hash:
  Hash{w.zero(), 0n}

def hash.is_zero(+h: Hash) -> Bool:
  match h:
    case Hash{+bits, +step}:
      Bool.and(w.is_eq(bits, w.zero()), Nat.is_eq(step, 0n))

def hash.is_eq(+a: Hash, +b: Hash) -> Bool:
  match a b:
    case Hash{+ab, +as} Hash{+bb, +bs}:
      Bool.and(w.is_eq(ab, bb), Nat.is_eq(as, bs))

def hash.keep(out: Bool, +h: Hash) -> Hash:
  Bool.pick(Hash, out, hash.zero(), h)

# a cell's bounds
def area.lat0(+a: Area) -> D:
  match a:
    case Area{+lat0, lat1, lon0, lon1}:
      lat0

def area.lat1(+a: Area) -> D:
  match a:
    case Area{lat0, +lat1, lon0, lon1}:
      lat1

def area.lon0(+a: Area) -> D:
  match a:
    case Area{lat0, lat1, +lon0, lon1}:
      lon0

def area.lon1(+a: Area) -> D:
  match a:
    case Area{lat0, lat1, lon0, +lon1}:
      lon1

# whether a cell's next ones fall short of the bounds, so that the step
# is too small to cover them
def cells.short(+h: Hash, +b: BBox) -> Bool:
  match b:
    case BBox{+lon0, +lat0, +lon1, +lat1}:
      +ln = geo.lon_rng()
      +lt = geo.lat_rng()
      +n = geo.decode(ln, lt, geo.move.y(h, True{}))
      +s = geo.decode(ln, lt, geo.move.y(h, False{}))
      +e = geo.decode(ln, lt, geo.move.x(h, True{}))
      +w = geo.decode(ln, lt, geo.move.x(h, False{}))
      Bool.or(Bool.or(d.lt(area.lat1(n), lat1), d.gt(area.lat0(s), lat0)), Bool.or(d.lt(area.lon1(e), lon1), d.gt(area.lon0(w), lon0)))

# the nine cells around h, those that a cell of h's step past the bounds
# makes useless left out (a step of 2 at least, as Redis does)
def cells.of(+h: Hash, +b: BBox, +cut: Bool) -> List<&2, Hash>:
  match b:
    case BBox{+lon0, +lat0, +lon1, +lat1}:
      +a = geo.decode(geo.lon_rng(), geo.lat_rng(), h)
      +so = Bool.and(cut, d.lt(area.lat0(a), lat0))
      +no = Bool.and(cut, d.gt(area.lat1(a), lat1))
      +wo = Bool.and(cut, d.lt(area.lon0(a), lon0))
      +eo = Bool.and(cut, d.gt(area.lon1(a), lon1))
      +n = geo.move.y(h, True{})
      +s = geo.move.y(h, False{})
      [h, hash.keep(no, n), hash.keep(so, s), hash.keep(eo, geo.move.x(h, True{})), hash.keep(wo, geo.move.x(h, False{})), hash.keep(Bool.or(no, eo), geo.move.x(n, True{})), hash.keep(Bool.or(no, wo), geo.move.x(n, False{})), hash.keep(Bool.or(so, eo), geo.move.x(s, True{})), hash.keep(Bool.or(so, wo), geo.move.x(s, False{}))]

def cells.at(+lon: D, +lat: D, +b: BBox, +step: Nat) -> List<&2, Hash>:
  cells.of(geo.encode(geo.lon_rng(), geo.lat_rng(), lon, lat, step), b, Nat.is_le(2n, step))

# geohashCalculateAreasByShapeWGS84: the cells of the estimated step, or
# of one step fewer when the cells next to the center's fall short of the
# bounds
def geo.cells(+q: Search) -> List<&2, Hash>:
  match q:
    case Search{+lon, +lat, +s, +conv}:
      +b = geo.bbox(lon, lat, s, conv)
      +step = geo.steps(shape.range(s, conv), lat)
      +h = geo.encode(geo.lon_rng(), geo.lat_rng(), lon, lat, step)
      +less = Bool.and(Nat.is_lt(1n, step), cells.short(h, b))
      cells.at(lon, lat, b, Bool.pick(Nat, less, Nat.sub(step, 1n), step))

# The points a search finds
# -------------------------

# a point: its member, its position, its distance from the search's
# center (m) and its score
type GP is Data:
  GP{m: String, lon: D, lat: D, dist: D, score: D}

def within.box.fin(go: Bool, +clon: D, +clat: D, +lon: D, +lat: D) -> Maybe<&2, D>:
  match go:
    case False{}:
      None{}
    case True{}:
      Some{geo.dist(clon, clat, lon, lat)}

def within.box.lon(go: Bool, +clon: D, +clat: D, +w: D, +conv: D, +lon: D, +lat: D) -> Maybe<&2, D>:
  match go:
    case False{}:
      None{}
    case True{}:
      within.box.fin(Bool.not(d.gt(geo.dist(lon, lat, clon, lat), d.half(d.mul(w, conv)))), clon, clat, lon, lat)

def within.of(+s: Shape, +clon: D, +clat: D, +conv: D, +lon: D, +lat: D) -> Maybe<&2, D>:
  match s:
    case Circle{+r}:
      +dist = geo.dist(clon, clat, lon, lat)
      Bool.pick(Maybe<&2, D>, d.gt(dist, d.mul(r, conv)), None{}, Some{dist})
    case Box{+w, +h}:
      within.box.lon(Bool.not(d.gt(geo.lat_dist(lat, clat), d.half(d.mul(h, conv)))), clon, clat, w, conv, lon, lat)

# geoWithinShape: the distance of (lon, lat) from the search's center,
# when the point is within the search's circle (by its distance) or box
# (by its distances along the parallel and the meridian)
def geo.within(+q: Search, +lon: D, +lat: D) -> Maybe<&2, D>:
  match q:
    case Search{+clon, +clat, +s, +conv}:
      within.of(s, clon, clat, conv, lon, lat)

def pos.lon(+p: Pos) -> D:
  match p:
    case Pos{+lon, lat}:
      lon

def pos.lat(+p: Pos) -> D:
  match p:
    case Pos{lon, +lat}:
      lat

def geo.pt.of(m: Maybe<&2, D>, +x: String, +p: Pos, +s: D) -> Maybe<&2, GP>:
  match m:
    case None{}:
      None{}
    case Some{dist}:
      Some{GP{x, pos.lon(p), pos.lat(p), dist, s}}

# the point of member x of score sc, when the search takes it
def geo.pt(+q: Search, +x: String, +sc: F.F64) -> Maybe<&2, GP>:
  +s = d.of_score(sc)
  +p = geo.pos(s)
  geo.pt.of(geo.within(q, pos.lon(p), pos.lat(p)), x, p, s)

def gp.cons(m: Maybe<&2, GP>, ps: List<&2, GP>) -> List<&2, GP>:
  match m:
    case None{}:
      ps
    case Some{p}:
      p <> ps

# whether a search of a limit (ANY's count; 0 none) has found enough
def found.full(+n: Nat, +limit: Nat) -> Bool:
  Bool.and(Nat.is_lt(0n, limit), Nat.is_le(limit, n))

# a scan of the cells: the points found, last first, how many, and the
# last cell read past the first (Redis's last_processed, which 0 leaves
# unset)
type Scan is Data:
  Scan{ps: List<&2, GP>, n: Nat, last: Maybe<&2, Hash>}

# geoGetPointsInRange: the elements of a cell (scores from its lowest to
# below the next cell's), each taken as the search takes it, until the
# limit is reached
def geo.scan(xs: List<&2, KV.ZEl>, full: Bool, +q: Search, +limit: Nat, ps: List<&2, GP>, +n: Nat, last: Maybe<&2, Hash>) -> Scan:
  match xs full:
    case Nil{} _:
      Scan{ps, n, last}
    case _ True{}:
      Scan{ps, n, last}
    case Con{KV.ZEl{+x, +sc}, rest} False{}:
      +m = geo.pt(q, x, sc)
      +n2 = Nat.add(n, Bool.pick(Nat, Maybe.is_some(&2, GP, m), 1n, 0n))
      geo.scan(rest, found.full(n2, limit), q, limit, gp.cons(m, ps), n2, last)

# the elements of z whose scores are from lo to below hi, in order
def geo.range(+z: KV.Zset, +lo: D, +hi: D) -> List<&2, KV.ZEl>:
  +a = KV.zset.before(z, KV.ZGeS{KV.ZSB{d.score(lo), False{}}})
  +b = KV.zset.before(z, KV.ZGeS{KV.ZSB{d.score(hi), False{}}})
  KV.zset.slice(False{}, z, a, b)

# the next geohash of the same step
def hash.next(+h: Hash) -> Hash:
  match h:
    case Hash{+bits, +step}:
      Hash{w.inc(bits), step}

# membersOfGeoHashBox: the scores of a cell, scoresOfGeoHashBox's
def geo.cell(+z: KV.Zset, +h: Hash, +q: Search, +limit: Nat, ps: List<&2, GP>, +n: Nat, last: Maybe<&2, Hash>) -> Scan:
  geo.scan(geo.range(z, d.of_w(geo.align(h)), d.of_w(geo.align(hash.next(h)))), found.full(n, limit), q, limit, ps, n, last)

def last.same(+last: Maybe<&2, Hash>, +h: Hash) -> Bool:
  match last:
    case None{}:
      False{}
    case Some{+l}:
      hash.is_eq(l, h)

def scan.do(skip: Bool, +first: Bool, +h: Hash, +z: KV.Zset, +q: Search, +limit: Nat, ps: List<&2, GP>, +n: Nat, last: Maybe<&2, Hash>) -> Scan:
  match skip:
    case True{}:
      Scan{ps, n, last}
    case False{}:
      geo.cell(z, h, q, limit, ps, n, Bool.pick(Maybe<&2, Hash>, first, None{}, Some{h}))

# a cell is skipped when it is left out, when it is the last one read
# (huge searches have neighbors that are the same cell), and once the
# limit is reached (Redis stops there)
def scan.go(+first: Bool, +h: Hash, +z: KV.Zset, +q: Search, +limit: Nat, st: Scan) -> Scan:
  match st:
    case Scan{ps, +n, +last}:
      scan.do(Bool.or(Bool.or(hash.is_zero(h), last.same(last, h)), found.full(n, limit)), first, h, z, q, limit, ps, n, last)

def geo.cells.scan(cs: List<&2, Hash>, +first: Bool, +z: KV.Zset, +q: Search, +limit: Nat, st: Scan) -> Scan:
  match cs:
    case Nil{}:
      st
    case Con{+h, rest}:
      geo.cells.scan(rest, False{}, z, q, limit, scan.go(first, h, z, q, limit, st))

def scan.points(st: Scan) -> List<&2, GP>:
  match st:
    case Scan{ps, n, last}:
      List.reverse(&2, GP, ps)

# membersOfAllNeighbors: the points a search finds in the sorted set z,
# in the order Redis finds them; limit is ANY's count (0: none)
def geo.search(+z: KV.Zset, +q: Search, +limit: Nat) -> List<&2, GP>:
  scan.points(geo.cells.scan(geo.cells(q), True{}, z, q, limit, Scan{Nil{}, 0n, None{}}))

# Sorting
# -------
# ASC and DESC sort the points by distance with glibc's qsort, a stable
# merge sort (sort_gp_asc and sort_gp_desc compare the distances alone):
# its merge takes the left point unless the comparison answers 1, which
# sort_gp_asc answers when a's distance is greater than b's, and
# sort_gp_desc, its negation, when it is neither greater nor equal (a
# NaN distance, which a distance near the antipodes can be, is less than
# any for one and greater for the other)

# whether a goes no later than b
def gp.le(+desc: Bool, +a: GP, +b: GP) -> Bool:
  match a b:
    case GP{m1, o1, a1, +x, s1} GP{m2, o2, a2, +y, s2}:
      Bool.pick(Bool, desc, d.ge(x, y), Bool.not(d.gt(x, y)))

def gp.le.l(+desc: Bool, +xs: List<&2, GP>, +y: GP) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case Con{+x, +r}:
      gp.le(desc, x, y)

def gp.le.r(+desc: Bool, +x: GP, +ys: List<&2, GP>) -> Bool:
  match ys:
    case Nil{}:
      True{}
    case Con{+y, +r}:
      gp.le(desc, x, y)

def gp.le.ab(+desc: Bool, +xs: List<&2, GP>, +ys: List<&2, GP>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case Con{+x, +r}:
      gp.le.r(desc, x, ys)

# xs and ys, each in order, merged after acc (reversed), the first of xs
# first when le; fuel bounds the steps
def gp.merge(fuel: Nat, xs: List<&2, GP>, ys: List<&2, GP>, le: Bool, +desc: Bool, acc: List<&2, GP>) -> List<&2, GP>:
  match fuel xs ys le:
    case 0n a b _:
      List.reverse.go(&2, GP, acc, List.append(&2, GP, a, b))
    case _ Nil{} b _:
      List.reverse.go(&2, GP, acc, b)
    case _ a Nil{} _:
      List.reverse.go(&2, GP, acc, a)
    case 1n+f Con{x, +xt} Con{+y, +yt} True{}:
      gp.merge(f, xt, Con{y, yt}, gp.le.l(desc, xt, y), desc, x <> acc)
    case 1n+f Con{+x, +xt} Con{y, +yt} False{}:
      gp.merge(f, Con{x, xt}, yt, gp.le.r(desc, x, yt), desc, y <> acc)

def gp.two(+n: Nat, +desc: Bool, +a: List<&2, GP>, +b: List<&2, GP>) -> List<&2, GP>:
  gp.merge(n, a, b, gp.le.ab(desc, a, b), desc, Nil{})

# glibc's msort_with_tmp: of n points (small: 1 at most), the first n / 2
# sorted, then the others, then the two merged (fuel: the depth left).
# Its order of merges is glibc's own, so that the points come out in its
# order even where a NaN makes the comparison no order
def gp.msort(fuel: Nat, small: Bool, +xs: List<&2, GP>, +n: Nat, +desc: Bool) -> List<&2, GP>:
  match fuel small:
    case 1n+(+f) False{}:
      +n1 = Nat.div(n, 2n)
      +n2 = Nat.sub(n, n1)
      gp.two(n, desc, gp.msort(f, Nat.is_le(n1, 1n), List.take(&2, GP, xs, n1), n1, desc), gp.msort(f, Nat.is_le(n2, 1n), List.drop(&2, GP, xs, n1), n2, desc))
    case _ _:
      xs

# the n points ps sorted by distance, the nearest first (the farthest,
# desc), those at the same distance in the order found
def geo.sort(ps: List<&2, GP>, +n: Nat, +desc: Bool) -> List<&2, GP>:
  gp.msort(64n, Nat.is_le(n, 1n), ps, n, desc)

# Partial sorting
# ---------------
# When COUNT keeps fewer points than were found (and ANY is not given),
# Redis sorts them with its own pqsort (pqsort.c: NetBSD's qsort, Bentley
# and McIlroy's, which sorts only the parts that reach the places it
# keeps): a quicksort, which leaves points at the same distance in an
# order of its own. Its steps are made here as the C code makes them, on
# a vector of the points (a tree by the bits of an index, from the
# highest), each comparison, each swap: the points it keeps, and their
# order, are Redis's.

type PV is Data:
  PVLeaf{p: GP}
  PVNode{l: PV, r: PV}
  PVNone{}

# a point no index holds (never read)
def gp.none() -> GP:
  GP{"", d.zero(), d.zero(), d.zero(), d.zero()}

# whether index i is in the lower half of a node of depth k
def pv.lo(+k: Nat, +i: Nat) -> Bool:
  Nat.is_lt(i, Nat.pow(2n, Nat.sub(k, 1n)))

# the vector of the points xs, 2^dp places
def pv.of(dp: Nat, xs: List<&2, GP>) -> PV:
  match dp xs:
    case _ Nil{}:
      PVNone{}
    case 0n Con{x, rest}:
      PVLeaf{x}
    case 1n+(+k) Con{+x, +rest}:
      +h = Nat.pow(2n, k)
      PVNode{pv.of(k, List.take(&2, GP, Con{x, rest}, h)), pv.of(k, List.drop(&2, GP, Con{x, rest}, h))}

# the depth of a vector of n points: the least dp with 2^dp at least n
# (ok: whether dp is)
def pv.depth(fuel: Nat, ok: Bool, +n: Nat, +dp: Nat) -> Nat:
  match fuel ok:
    case 1n+f False{}:
      pv.depth(f, Nat.is_le(n, Nat.pow(2n, Nat.add(dp, 1n))), n, Nat.add(dp, 1n))
    case _ _:
      dp

def pv.get(dp: Nat, v: PV, lo: Bool, +i: Nat) -> GP:
  match dp v lo:
    case 1n+(+k) PVNode{l, r} True{}:
      pv.get(k, l, pv.lo(k, i), i)
    case 1n+(+k) PVNode{l, r} False{}:
      +j = Nat.sub(i, Nat.pow(2n, k))
      pv.get(k, r, pv.lo(k, j), j)
    case 0n PVLeaf{p} _:
      p
    case _ _ _:
      gp.none()

def pv.put(dp: Nat, v: PV, lo: Bool, +i: Nat, x: GP) -> PV:
  match dp v lo:
    case 1n+(+k) PVNode{l, r} True{}:
      PVNode{pv.put(k, l, pv.lo(k, i), i, x), r}
    case 1n+(+k) PVNode{l, r} False{}:
      +j = Nat.sub(i, Nat.pow(2n, k))
      PVNode{l, pv.put(k, r, pv.lo(k, j), j, x)}
    case 0n PVLeaf{p} _:
      PVLeaf{x}
    case _ w _:
      w

# the point at index i
def pv.at(+dp: Nat, +v: PV, +i: Nat) -> GP:
  pv.get(dp, v, pv.lo(dp, i), i)

def pv.set(+dp: Nat, v: PV, +i: Nat, x: GP) -> PV:
  pv.put(dp, v, pv.lo(dp, i), i, x)

def pv.swap(+dp: Nat, +v: PV, +i: Nat, +j: Nat) -> PV:
  +a = pv.at(dp, v, i)
  +b = pv.at(dp, v, j)
  pv.set(dp, pv.set(dp, v, i, b), j, a)

# vecswap: the n points from i swapped with the n from j, one by one
def pv.vswap(n: Nat, +dp: Nat, v: PV, +i: Nat, +j: Nat) -> PV:
  match n:
    case 0n:
      v
    case 1n+f:
      pv.vswap(f, dp, pv.swap(dp, v, i, j), Nat.add(i, 1n), Nat.add(j, 1n))

# the points, in the order of their indices
def pv.list(v: PV, acc: List<&2, GP>) -> List<&2, GP>:
  match v:
    case PVLeaf{p}:
      p <> acc
    case PVNode{l, r}:
      pv.list(l, pv.list(r, acc))
    case PVNone{}:
      acc

# sort_gp_asc on a's and b's distances: GT when a's is greater, EQ when
# they are equal, else LT (a NaN too); sort_gp_desc its opposite
def cmp.dir(desc: Bool, c: Cmp) -> Cmp:
  match desc c:
    case False{} x:
      x
    case True{} LT{}:
      GT{}
    case True{} EQ{}:
      EQ{}
    case True{} GT{}:
      LT{}

def gp.cmp(+desc: Bool, +a: GP, +b: GP) -> Cmp:
  match a b:
    case GP{m1, o1, a1, +x, s1} GP{m2, o2, a2, +y, s2}:
      cmp.dir(desc, Bool.pick(Cmp, d.gt(x, y), GT{}, Bool.pick(Cmp, d.eq(x, y), EQ{}, LT{})))

def cmp.lt(c: Cmp) -> Bool:
  match c:
    case LT{}:
      True{}
    case _:
      False{}

def cmp.gt(c: Cmp) -> Bool:
  match c:
    case GT{}:
      True{}
    case _:
      False{}

# med3: of the indices i, j and k, that of the median point
def med3.of(ab: Cmp, +bc: Cmp, +ac: Cmp, +i: Nat, +j: Nat, +k: Nat) -> Nat:
  match ab:
    case LT{}:
      Bool.pick(Nat, cmp.lt(bc), j, Bool.pick(Nat, cmp.lt(ac), k, i))
    case _:
      Bool.pick(Nat, cmp.gt(bc), j, Bool.pick(Nat, cmp.lt(ac), i, k))

def med3(+dp: Nat, +v: PV, +desc: Bool, +i: Nat, +j: Nat, +k: Nat) -> Nat:
  +a = pv.at(dp, v, i)
  +b = pv.at(dp, v, j)
  +c = pv.at(dp, v, k)
  med3.of(gp.cmp(desc, a, b), gp.cmp(desc, b, c), gp.cmp(desc, a, c), i, j, k)

# the pivot's index of the n points from a (n at least 7): the middle one,
# past 7 the median of the first, the middle and the last, past 40 each
# of those the median of three n / 8 apart
def pq.pivot.big(big: Bool, +dp: Nat, +v: PV, +desc: Bool, +a: Nat, +n: Nat) -> Nat:
  match big:
    case True{}:
      +pm = Nat.add(a, Nat.div(n, 2n))
      +pn = Nat.sub(Nat.add(a, n), 1n)
      +d = Nat.div(n, 8n)
      med3(dp, v, desc, med3(dp, v, desc, a, Nat.add(a, d), Nat.add(a, Nat.mul(2n, d))), med3(dp, v, desc, Nat.sub(pm, d), pm, Nat.add(pm, d)), med3(dp, v, desc, Nat.sub(pn, Nat.mul(2n, d)), Nat.sub(pn, d), pn))
    case False{}:
      med3(dp, v, desc, a, Nat.add(a, Nat.div(n, 2n)), Nat.sub(Nat.add(a, n), 1n))

def pq.pivot(seven: Bool, +dp: Nat, +v: PV, +desc: Bool, +a: Nat, +n: Nat) -> Nat:
  match seven:
    case True{}:
      Nat.add(a, Nat.div(n, 2n))
    case False{}:
      pq.pivot.big(Nat.is_lt(40n, n), dp, v, desc, a, n)

# a step of a scan: stop, go on, or go on past a point equal to the pivot
type Go is Data:
  GoStop{}
  GoOn{}
  GoEq{}

# the partition's state: the vector, and pa, pb, pc and pd
type PQ is Data:
  PQ{v: PV, pa: Nat, pb: Nat, pc: Nat, pd: Nat}

# while pb <= pc and the point at pb is no greater than the pivot: pb on,
# a point equal to it swapped to pa first, pa on
def pq.b.of(c: Cmp, +ok: Bool) -> Go:
  match c:
    case GT{}:
      GoStop{}
    case EQ{}:
      Bool.pick(Go, ok, GoEq{}, GoStop{})
    case LT{}:
      Bool.pick(Go, ok, GoOn{}, GoStop{})

def pq.b.go(+dp: Nat, +v: PV, +desc: Bool, +piv: GP, +pb: Nat, +pc: Nat) -> Go:
  pq.b.of(gp.cmp(desc, pv.at(dp, v, pb), piv), Nat.is_le(pb, pc))

def pq.b(fuel: Nat, g: Go, st: PQ, +dp: Nat, +desc: Bool, +piv: GP) -> PQ:
  match fuel g st:
    case 1n+f GoOn{} PQ{+v, +pa, +pb, +pc, +pd}:
      pq.b(f, pq.b.go(dp, v, desc, piv, Nat.add(pb, 1n), pc), PQ{v, pa, Nat.add(pb, 1n), pc, pd}, dp, desc, piv)
    case 1n+f GoEq{} PQ{+v, +pa, +pb, +pc, +pd}:
      +w = pv.swap(dp, v, pa, pb)
      pq.b(f, pq.b.go(dp, w, desc, piv, Nat.add(pb, 1n), pc), PQ{w, Nat.add(pa, 1n), Nat.add(pb, 1n), pc, pd}, dp, desc, piv)
    case _ _ x:
      x

# while pb <= pc and the point at pc is no less than the pivot: pc back,
# a point equal to it swapped to pd first, pd back
def pq.c.of(c: Cmp, +ok: Bool) -> Go:
  match c:
    case LT{}:
      GoStop{}
    case EQ{}:
      Bool.pick(Go, ok, GoEq{}, GoStop{})
    case GT{}:
      Bool.pick(Go, ok, GoOn{}, GoStop{})

def pq.c.go(+dp: Nat, +v: PV, +desc: Bool, +piv: GP, +pb: Nat, +pc: Nat) -> Go:
  pq.c.of(gp.cmp(desc, pv.at(dp, v, pc), piv), Nat.is_le(pb, pc))

def pq.c(fuel: Nat, g: Go, st: PQ, +dp: Nat, +desc: Bool, +piv: GP) -> PQ:
  match fuel g st:
    case 1n+f GoOn{} PQ{+v, +pa, +pb, +pc, +pd}:
      pq.c(f, pq.c.go(dp, v, desc, piv, pb, Nat.sub(pc, 1n)), PQ{v, pa, pb, Nat.sub(pc, 1n), pd}, dp, desc, piv)
    case 1n+f GoEq{} PQ{+v, +pa, +pb, +pc, +pd}:
      +w = pv.swap(dp, v, pc, pd)
      pq.c(f, pq.c.go(dp, w, desc, piv, pb, Nat.sub(pc, 1n)), PQ{w, pa, pb, Nat.sub(pc, 1n), Nat.sub(pd, 1n)}, dp, desc, piv)
    case _ _ x:
      x

def pq.b.first(+st: PQ, +dp: Nat, +desc: Bool, +piv: GP) -> Go:
  match st:
    case PQ{+v, pa, +pb, +pc, pd}:
      pq.b.go(dp, v, desc, piv, pb, pc)

def pq.c.first(+st: PQ, +dp: Nat, +desc: Bool, +piv: GP) -> Go:
  match st:
    case PQ{+v, pa, +pb, +pc, pd}:
      pq.c.go(dp, v, desc, piv, pb, pc)

# whether pb has passed pc
def pq.crossed(+st: PQ) -> Bool:
  match st:
    case PQ{v, pa, +pb, +pc, pd}:
      Nat.is_lt(pc, pb)

# the points at pb and pc swapped, pb on and pc back (unless crossed)
def pq.cross(cr: Bool, st: PQ, +dp: Nat) -> PQ:
  match cr st:
    case True{} x:
      x
    case False{} PQ{+v, +pa, +pb, +pc, +pd}:
      PQ{pv.swap(dp, v, pb, pc), pa, Nat.add(pb, 1n), Nat.sub(pc, 1n), pd}

# the partition's loop: both scans, then a swap, until pb passes pc
def pq.loop(fuel: Nat, go: Bool, +st: PQ, +dp: Nat, +desc: Bool, +piv: GP, +n: Nat) -> PQ:
  match fuel go:
    case 1n+f True{}:
      +s1 = pq.b(n, pq.b.first(st, dp, desc, piv), st, dp, desc, piv)
      +s2 = pq.c(n, pq.c.first(s1, dp, desc, piv), s1, dp, desc, piv)
      +cr = pq.crossed(s2)
      pq.loop(f, Bool.not(cr), pq.cross(cr, s2, dp), dp, desc, piv, n)
    case _ _:
      st

# a part of the vector to sort: its first index and its length
type Job is Data:
  Job{a: Nat, n: Nat}

# the vector, and the parts left to sort
type PRun is Data:
  PRun{v: PV, jobs: List<&2, Job>}

# a part pushed when it has two points at least and starts before k (the
# range's end: pqsort leaves a part that does not reach it)
def pq.push.if(go: Bool, +a: Nat, +n: Nat, js: List<&2, Job>) -> List<&2, Job>:
  match go:
    case True{}:
      Job{a, n} <> js
    case False{}:
      js

def pq.push(+a: Nat, +n: Nat, +k: Nat, js: List<&2, Job>) -> List<&2, Job>:
  pq.push.if(Bool.and(Nat.is_lt(1n, n), Nat.is_lt(a, k)), a, n, js)

# the partition's end: the points equal to the pivot moved between the
# lesser and the greater ones (vecswap), the lesser part and the greater
# part pushed
def pq.split(st: PQ, +dp: Nat, +a: Nat, +n: Nat, +k: Nat, js: List<&2, Job>) -> PRun:
  match st:
    case PQ{v, +pa, +pb, +pc, +pd}:
      +pn = Nat.add(a, n)
      +r1 = Nat.min(Nat.sub(pa, a), Nat.sub(pb, pa))
      +v1 = pv.vswap(r1, dp, v, a, Nat.sub(pb, r1))
      +r2 = Nat.min(Nat.sub(pd, pc), Nat.sub(Nat.sub(pn, pd), 1n))
      +v2 = pv.vswap(r2, dp, v1, pb, Nat.sub(pn, r2))
      PRun{v2, pq.push(a, Nat.sub(pb, pa), k, pq.push(Nat.sub(pn, Nat.sub(pd, pc)), Nat.sub(pd, pc), k, js))}

# a part of 7 points at least: its pivot swapped to its first place, and
# the partition from there
def pq.start(+w: PV, +a: Nat, +n: Nat) -> PQ:
  PQ{w, Nat.add(a, 1n), Nat.add(a, 1n), Nat.sub(Nat.add(a, n), 1n), Nat.sub(Nat.add(a, n), 1n)}

def pq.part(+v: PV, +dp: Nat, +desc: Bool, +a: Nat, +n: Nat, +k: Nat, js: List<&2, Job>) -> PRun:
  +w = pv.swap(dp, v, a, pq.pivot(Nat.is_eq(n, 7n), dp, v, desc, a, n))
  pq.split(pq.loop(n, True{}, pq.start(w, a, n), dp, desc, pv.at(dp, w, a), n), dp, a, n, k, js)

# insertion sort of a part of fewer than 7 points: each, from the second,
# swapped back while the point before it is greater
def pq.down.go(+dp: Nat, +v: PV, +desc: Bool, +a: Nat, +pl: Nat) -> Bool:
  Bool.and(Nat.is_lt(a, pl), cmp.gt(gp.cmp(desc, pv.at(dp, v, Nat.sub(pl, 1n)), pv.at(dp, v, pl))))

def pq.down(fuel: Nat, go: Bool, +v: PV, +dp: Nat, +desc: Bool, +a: Nat, +pl: Nat) -> PV:
  match fuel go:
    case 1n+f True{}:
      +w = pv.swap(dp, v, pl, Nat.sub(pl, 1n))
      pq.down(f, pq.down.go(dp, w, desc, a, Nat.sub(pl, 1n)), w, dp, desc, a, Nat.sub(pl, 1n))
    case _ _:
      v

def pq.ins(fuel: Nat, +v: PV, +dp: Nat, +desc: Bool, +a: Nat, +pm: Nat) -> PV:
  match fuel:
    case 0n:
      v
    case 1n+f:
      pq.ins(f, pq.down(Nat.sub(pm, a), pq.down.go(dp, v, desc, a, pm), v, dp, desc, a, pm), dp, desc, a, Nat.add(pm, 1n))

def pq.job(small: Bool, +v: PV, +dp: Nat, +desc: Bool, +a: Nat, +n: Nat, +k: Nat, js: List<&2, Job>) -> PRun:
  match small:
    case True{}:
      PRun{pq.ins(Nat.sub(n, 1n), v, dp, desc, a, Nat.add(a, 1n)), js}
    case False{}:
      pq.part(v, dp, desc, a, n, k, js)

def pq.run(fuel: Nat, st: PRun, +dp: Nat, +desc: Bool, +k: Nat) -> PV:
  match fuel st:
    case 1n+f PRun{v, Con{Job{+a, +n}, rest}}:
      pq.run(f, pq.job(Nat.is_lt(n, 7n), v, dp, desc, a, n, k, rest), dp, desc, k)
    case _ PRun{v, js}:
      v

# pqsort(ps, n, 0, k - 1): the n points ps, sorted by distance in their
# first k places (k from 1 to n - 1), as Redis's pqsort leaves them
def geo.psort(ps: List<&2, GP>, +n: Nat, +k: Nat, +desc: Bool) -> List<&2, GP>:
  +dp = pv.depth(47n, Nat.is_le(n, 1n), n, 0n)
  pv.list(pq.run(Nat.add(Nat.mul(n, 2n), 2n), PRun{pv.of(dp, ps), [Job{0n, n}]}, dp, desc, k), Nil{})

# Text
# ----

def w.of_d_bits(r: U32 & U32) -> W:
  (h, l) = r
  W{h, l}

# v's 64 bits as an unsigned decimal: v = q * 10^8 + r, through halves of
# 16 bits so that no Nat passes 2^48
def w.dec.of(+q: Nat, +r: Nat) -> String:
  +rs = Nat.show(r)
  Bool.pick(String, Nat.is_eq(q, 0n), rs, Nat.show(q) ++ String.repeat("0", Nat.sub(8n, String.length(rs))) ++ rs)

def w.dec(+v: W) -> String:
  match v:
    case W{+h, +l}:
      +t1 = Nat.add(Nat.mul(U32.to_nat(h), 65536n), U32.to_nat(U32.shrn(l, 16n)))
      +t2 = Nat.add(Nat.mul(Nat.mod(t1, 100000000n), 65536n), U32.to_nat(U32.and(l, 65535)))
      w.dec.of(Nat.add(Nat.mul(Nat.div(t1, 100000000n), 65536n), Nat.div(t2, 100000000n)), Nat.mod(t2, 100000000n))

# a 64-bit two's complement integer as a signed decimal
def w.neg(+v: W) -> Bool:
  match v:
    case W{+h, l}:
      U32.is_le(2147483648, h)

def w.sdec(+v: W) -> String:
  Bool.pick(String, w.neg(v), "-" ++ w.dec(w.sub(w.zero(), v)), w.dec(v))

# (long long)x, as C converts a double (WITHHASH's score)
def geo.hash_int(+x: D) -> String:
  w.sdec(w.of_i64(x))

def fix4(+ds: String) -> String:
  +k = String.length(ds)
  Bool.pick(String, Nat.is_le(k, 4n), "0." ++ String.repeat("0", Nat.sub(4n, k)) ++ ds, String.take(ds, Nat.sub(k, 4n)) ++ "." ++ String.drop(ds, Nat.sub(k, 4n)))

def geo.dist_text.of(zero: Bool, +a: D) -> String:
  match zero:
    case True{}:
      "0.0000"
    case False{}:
      match a:
        case D{+h, +l}:
          +v = w.of_d_bits(F64.rint_i64(h, l))
          Bool.pick(String, w.neg(v), "-" ++ fix4(w.dec(w.sub(w.zero(), v))), fix4(w.dec(v)))

# fixedpoint_d2string(d, 4): a distance with four decimals, as Redis
# answers one (llrint of d * 10^4, the even integer on a tie)
def geo.dist_text(+a: D) -> String:
  geo.dist_text.of(d.eq(a, d.zero()), d.mul(a, D{1086556160, 0}))

# a coordinate as addReplyHumanLongDouble writes it: "%.17Lf" of the
# double as a long double, the '0's that end it taken out
def geo.coord_text(+a: D) -> String:
  F.fl.show_human(F.f64.to(d.score(a)))

def w.low(+v: W) -> U32:
  match v:
    case W{h, +l}:
      l

# GEOHASH's 11 characters: the position's geohash in the standard ranges
# (latitudes from -90 to 90), five bits a character, the eleventh "0"
def geo.b32(+bits: W, +i: Nat) -> String:
  +idx = U32.to_nat(U32.and(w.low(w.shr(bits, Nat.sub(52n, Nat.mul(Nat.add(i, 1n), 5n)))), 31))
  String.slice("0123456789bcdefghjkmnpqrstuvwxyz", idx, 1n)

def geo.b32s(k: Nat, +bits: W, +i: Nat) -> String:
  match k:
    case 0n:
      "0"
    case 1n+r:
      geo.b32(bits, i) ++ geo.b32s(r, bits, Nat.add(i, 1n))

def geo.hash11.of(+h: Hash) -> String:
  match h:
    case Hash{+bits, step}:
      geo.b32s(10n, bits, 0n)

def geo.hash11.at(+p: Pos) -> String:
  geo.hash11.of(geo.encode(Rng{geo.lon_min(), geo.lon_max()}, Rng{D{3226894336, 0}, D{1079410688, 0}}, pos.lon(p), pos.lat(p), 26n))

def geo.hash11(+score: D) -> String:
  geo.hash11.at(geo.pos(score))

# GEOADD's score text: the 52 bits of the position's geohash as an
# integer, as Redis writes it for ZADD (sdsfromlonglong)
def geo.score_text(+lon: D, +lat: D) -> String:
  w.dec(geo.score(lon, lat))
