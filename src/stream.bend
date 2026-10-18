# stream.bend: what the stream commands read of a stream, as Redis 7.0.15
# reads it (t_stream.c): the IDs a command names, a stream's entries in a
# range as its iterator walks them, its radix tree's count of nodes, and
# a group's lag. redis.bend makes the replies.
#
# A stream's numbers are 64 bits, each an XN (map.bend), whose arithmetic
# wraps as a uint64_t's. A count Redis keeps as a long long prints as one:
# its 64 bits as two's complement (xn.show.ll).

import Base
import ./map.bend as KV
import ./rdb.bend as D

# Numbers
# -------

def xn.zero() -> KV.XN:
  KV.XS{0n}

def xn.one() -> KV.XN:
  KV.XS{1n}

# a - b mod 2^64
def xn.sub(+a: KV.XN, +b: KV.XN) -> KV.XN:
  KV.xn.add(a, KV.xn.neg(b))

# whether a is 2^64 - 1 (-1 as a long long). An XS is not: the match
# comes first, so that a proof's comparison of a number it does not know
# never reaches 2^64 - 1, which the checker would compute in unary
def xn.is_max(+a: KV.XN) -> Bool:
  match a:
    case KV.XS{n}:
      False{}
    case KV.XL{+h, +l}:
      KV.xn.is_eq(KV.XL{h, l}, D.xn.max())

# a's 64 bits as a long long's digits (%lld)
def xn.show.ll(+a: KV.XN) -> String:
  Bool.pick(String, Cmp.is_lt(KV.xn.cmp(a, D.xn.p63())), KV.xn.show(a), "-" ++ KV.xn.show(KV.xn.neg(a)))

# Reading a number as string2ull does (util.c): string2ll's form first
# (a "-" or none, then "0" alone or digits from 1 to 9 on, fewer than 21
# bytes), which must not be below 0; else strtoull's, in base 10: spaces
# (isspace), then a "+" or a "-" or none, then digits up to the end, at
# least one, the number below 2^64, negated mod 2^64 after a "-". The
# text ends at its first NUL (a C string).

def su.digit(+x: U32) -> Bool:
  U32.is_le(U32.sub(x, 48), 9)

def su.space(+x: U32) -> Bool:
  Bool.or(U32.is_eq(x, 32), U32.is_le(U32.sub(x, 9), 4))

# the index of the first char of s from i on that is no space (k chars
# left to look at; sp: whether the one at i is)
def su.ws.at(k: Nat, sp: Bool, +s: String, +i: Nat) -> Nat:
  match k sp:
    case 1n+j True{}:
      +n = Nat.add(i, 1n)
      su.ws.at(j, su.space(String.code_at(s, n)), s, n)
    case _ _:
      i

# s without the spaces it starts with
def su.ws(+s: String) -> String:
  String.drop(s, su.ws.at(String.length(s), su.space(String.code_at(s, 0n)), s, 0n))

# how many zeros s starts with (k chars left to look at; z: whether the
# char at i is one)
def su.zeros.at(k: Nat, z: Bool, +s: String, +i: Nat) -> Nat:
  match k z:
    case 1n+j True{}:
      +n = Nat.add(i, 1n)
      su.zeros.at(j, U32.is_eq(String.code_at(s, n), 48), s, n)
    case _ _:
      i

def su.zeros(+s: String) -> Nat:
  su.zeros.at(String.length(s), U32.is_eq(String.code_at(s, 0n), 48), s, 0n)

# the number of the digits of s (all of it, at least one; z zeros first,
# then m more), when it is below 2^64. Each is a match, not a Bool.pick,
# whose arms are both computed: xn.dec of more than 20 digits, or of
# text that is no digits, passes 2^48.
def su.mag.if(fits: Bool, +s: String, +z: Nat, +m: Nat) -> Maybe<&2, KV.XN>:
  match fits:
    case True{}:
      Some{KV.xn.dec(s, z, m)}
    case False{}:
      None{}

def su.mag.of(digits: Bool, +s: String, +z: Nat, +m: Nat) -> Maybe<&2, KV.XN>:
  match digits:
    case True{}:
      su.mag.if(Bool.or(Nat.is_lt(m, 20n), Bool.and(Nat.is_eq(m, 20n), Bool.not(Cmp.is_gt(String.order(String.drop(s, z), "18446744073709551615"))))), s, z, m)
    case False{}:
      None{}

def su.mag(+s: String) -> Maybe<&2, KV.XN>:
  +n = String.length(s)
  +z = su.zeros(s)
  su.mag.of(Bool.and(Nat.is_lt(0n, n), Nat.is_eq(String.digits_at(s, 0n), n)), s, z, Nat.sub(n, z))

def su.neg(m: Maybe<&2, KV.XN>) -> Maybe<&2, KV.XN>:
  match m:
    case Some{+v}:
      Some{KV.xn.neg(v)}
    case None{}:
      None{}

# strtoull's number of s, its spaces gone
def su.strtoull(+s: String) -> Maybe<&2, KV.XN>:
  +c = String.code_at(s, 0n)
  Bool.pick(Maybe<&2, KV.XN>, U32.is_eq(c, 45), su.neg(su.mag(String.drop(s, 1n))), Bool.pick(Maybe<&2, KV.XN>, U32.is_eq(c, 43), su.mag(String.drop(s, 1n)), su.mag(s)))

# whether s is string2ll's form of a number below 0: "-", a digit from 1
# to 9, digits, 20 bytes at most, the number at most 2^63
def su.llneg(+s: String) -> Bool:
  +n = String.length(s)
  +d = Nat.sub(n, 1n)
  +form = Bool.and(Bool.and(U32.is_eq(String.code_at(s, 0n), 45), Bool.and(Nat.is_le(2n, n), Nat.is_le(n, 20n))), Bool.and(U32.is_le(U32.sub(String.code_at(s, 1n), 49), 8), Nat.is_eq(String.digits_at(s, 1n), d)))
  Bool.and(form, Bool.or(Nat.is_lt(d, 19n), Bool.not(Cmp.is_gt(String.order(String.drop(s, 1n), "9223372036854775808")))))

def su.ull.if(neg: Bool, +s: String) -> Maybe<&2, KV.XN>:
  match neg:
    case True{}:
      None{}
    case False{}:
      su.strtoull(su.ws(s))

def su.ull(+s: String) -> Maybe<&2, KV.XN>:
  su.ull.if(su.llneg(s), s)

# IDs
# ---

def xid.zero() -> KV.XId:
  KV.XId{xn.zero(), xn.zero()}

def xid.max() -> KV.XId:
  KV.XId{D.xn.max(), D.xn.max()}

def xid.show(+id: KV.XId) -> String:
  match id:
    case KV.XId{+ms, +sq}:
      KV.xn.show(ms) ++ "-" ++ KV.xn.show(sq)

def xid.is_eq(+a: KV.XId, +b: KV.XId) -> Bool:
  Cmp.is_eq(KV.xid.cmp(a, b))

def xid.is_zero(+a: KV.XId) -> Bool:
  xid.is_eq(a, xid.zero())

# the ID after id (streamIncrID), none after the last one
def xid.incr(+id: KV.XId) -> Maybe<&2, KV.XId>:
  match id:
    case KV.XId{+ms, +sq}:
      Bool.pick(Maybe<&2, KV.XId>, xn.is_max(sq), Bool.pick(Maybe<&2, KV.XId>, xn.is_max(ms), None{}, Some{KV.XId{KV.xn.add(ms, xn.one()), xn.zero()}}), Some{KV.XId{ms, KV.xn.add(sq, xn.one())}})

# the ID before id (streamDecrID), none before 0-0
def xid.decr(+id: KV.XId) -> Maybe<&2, KV.XId>:
  match id:
    case KV.XId{+ms, +sq}:
      Bool.pick(Maybe<&2, KV.XId>, KV.xn.is_eq(sq, xn.zero()), Bool.pick(Maybe<&2, KV.XId>, KV.xn.is_eq(ms, xn.zero()), None{}, Some{KV.XId{xn.sub(ms, xn.one()), D.xn.max()}}), Some{KV.XId{ms, xn.sub(sq, xn.one())}})

def xid.of(a: Maybe<&2, KV.XN>, b: Maybe<&2, KV.XN>) -> Maybe<&2, KV.XId>:
  match a b:
    case Some{ms} Some{sq}:
      Some{KV.XId{ms, sq}}
    case _ _:
      None{}

# <ms>-<seq>, cut at the first "-", or <ms> alone, its sequence miss
def xid.parts(dash: Bool, +b: String, +dot: Nat, +miss: KV.XN) -> Maybe<&2, KV.XId>:
  match dash:
    case True{}:
      xid.of(su.ull(String.take(b, dot)), su.ull(String.drop(b, Nat.add(dot, 1n))))
    case False{}:
      xid.of(su.ull(b), Some{miss})

# the text b of an ID, a lone "-" or "+" first
def xid.lone(k: Nat, strict: Bool, +b: String, +miss: KV.XN) -> Maybe<&2, KV.XId>:
  match k:
    case 1n:
      Bool.pick(Maybe<&2, KV.XId>, strict, None{}, Some{xid.zero()})
    case 2n:
      Bool.pick(Maybe<&2, KV.XId>, strict, None{}, Some{xid.max()})
    case _:
      +dot = String.find(b, Chr{45}, 0n)
      xid.parts(Nat.is_lt(dot, String.length(b)), b, dot, miss)

def xid.text(+b: String, strict: Bool, +miss: KV.XN) -> Maybe<&2, KV.XId>:
  +lone = Nat.is_eq(String.length(b), 1n)
  +c = String.code_at(b, 0n)
  +k = Bool.pick(Nat, Bool.and(lone, U32.is_eq(c, 45)), 1n, Bool.pick(Nat, Bool.and(lone, U32.is_eq(c, 43)), 2n, 0n))
  xid.lone(k, strict, b, miss)

def xid.parse.if(long: Bool, +s: String, strict: Bool, +miss: KV.XN) -> Maybe<&2, KV.XId>:
  match long:
    case True{}:
      None{}
    case False{}:
      xid.text(String.take(s, String.find(s, Chr{0}, 0n)), strict, miss)

# The ID a command names (streamGenericParseIDOrReply): none for text of
# 128 bytes or more; it ends at its first NUL; "-" is 0-0 and "+" the
# last ID, but for a strict parse, which takes neither; else <ms>-<seq>,
# or <ms> with miss as its sequence
def xid.parse(+s: String, strict: Bool, +miss: KV.XN) -> Maybe<&2, KV.XId>:
  xid.parse.if(Nat.is_lt(127n, String.length(s)), s, strict, miss)

# A bound of a range (streamParseIntervalIDOrReply): "(" before an ID (in
# a text of more than one byte) leaves the ID out, which a strict parse
# reads; a start left out is the ID after it, an end left out the one
# before it (streamIncrID, streamDecrID), and there is none past the last
# ID or before 0-0
type XB is Data:
  XB{id: KV.XId}
  XBBad{}
  XBOver{}

def xb.of(m: Maybe<&2, KV.XId>) -> XB:
  match m:
    case Some{id}:
      XB{id}
    case None{}:
      XBBad{}

def xb.step(m: Maybe<&2, KV.XId>, start: Bool) -> XB:
  match m:
    case Some{+id}:
      xb.of(Bool.pick(Maybe<&2, KV.XId>, start, xid.incr(id), xid.decr(id)))
    case None{}:
      XBBad{}

def xb.over(b: XB) -> XB:
  match b:
    case XB{id}:
      XB{id}
    case XBBad{}:
      XBOver{}
    case XBOver{}:
      XBOver{}

def xb.ex(m: Maybe<&2, KV.XId>, start: Bool) -> XB:
  match m:
    case Some{+id}:
      xb.over(xb.step(Some{id}, start))
    case None{}:
      XBBad{}

def xb.parse.if(ex: Bool, +s: String, start: Bool, +miss: KV.XN) -> XB:
  match ex:
    case True{}:
      xb.ex(xid.parse(String.drop(s, 1n), True{}, miss), start)
    case False{}:
      xb.of(xid.parse(s, False{}, miss))

def xb.parse(+s: String, +start: Bool) -> XB:
  +miss = Bool.pick(KV.XN, start, xn.zero(), D.xn.max())
  xb.parse.if(Bool.and(Nat.is_lt(1n, String.length(s)), U32.is_eq(String.code_at(s, 0n), 40)), s, start, miss)

# Entries
# -------
# A node keeps each entry as its listpack bytes (map.bend): flags, the
# differences of its ID from the node's master ID, then its fields and
# values in turn after their count, or, with SAMEFIELDS (flags' bit 2),
# the values of the master's fields; then its count of elements. Bit 1 of
# the flags marks an entry deleted. The bytes were checked when the
# stream was read (rdb.bend), so a read here finds what it expects.

# an entry as a command answers it: its ID and its fields and values in
# turn
type XE is Data:
  XE{id: KV.XId, fv: List<&2, String>}

# an entry's head: its flags, its ID and where the bytes after them start
type XEh is Data:
  XEh{fl: Nat, id: KV.XId, off: Nat}
  XEhBad{}

# The slow way: each element of a copy of the entry (a walk lends the
# entry) read as its text (D.lp.next), and the bytes after it taken (n:
# the entry's length)
def xh.seq(+fl: Nat, +ms: KV.XN, r: D.LpR, +n: Nat, +mid: KV.XId) -> XEh:
  match r:
    case D.LpOk{+v, +t}:
      XEh{fl, D.xid.plus(mid, ms, KV.xn.of_int(v)), Nat.sub(n, String.length(t))}
    case _:
      XEhBad{}

def xh.ms(+fl: Nat, r: D.LpR, +n: Nat, +mid: KV.XId) -> XEh:
  match r:
    case D.LpOk{+v, t}:
      xh.seq(fl, KV.xn.of_int(v), D.lp.next(t), n, mid)
    case _:
      XEhBad{}

def xh.flags(r: D.LpR, +n: Nat, +mid: KV.XId) -> XEh:
  match r:
    case D.LpOk{+v, t}:
      xh.ms(String.dec_at(v, 0n, String.length(v)), D.lp.next(t), n, mid)
    case _:
      XEhBad{}

def xh.slow(+e: String, +n: Nat, +mid: KV.XId) -> XEh:
  xh.flags(D.lp.next(String.slice(e, 0n, n)), n, mid)

# The fast way: the three integers read where they lie, as lpGetInteger
# reads them, with no text made and no bytes taken. An element that is
# no integer of 32 bits at most, its backlen right (a string, a 64-bit
# integer, flags below 0), sends the entry the slow way, which reads it
# as Redis's listpack holds it. An integer: its sign, its magnitude, and
# the bytes it takes with its backlen (one byte: its size)
type XHi is Data:
  XHi{neg: Bool, m: Nat, n: Nat}
  XHiNo{}

def xh.at(+e: String, +i: Nat) -> Nat:
  U32.to_nat(String.code_at(e, i))

# k bytes from i on, little-endian (k at most 4)
def xh.le(k: Nat, +e: String, +i: Nat, +m: Nat, +acc: Nat) -> Nat:
  match k:
    case 0n:
      acc
    case 1n+j:
      xh.le(j, e, Nat.add(i, 1n), Nat.mul(m, 256n), Nat.add(acc, Nat.mul(xh.at(e, i), m)))

# the integer read as u, of sz bytes and signed below full (2^bits, or 0:
# unsigned), when its backlen is right
def xh.int.val(ok: Bool, +u: Nat, +full: Nat, +sz: Nat) -> XHi:
  match ok:
    case True{}:
      +neg = Bool.and(Nat.is_lt(0n, full), Nat.is_le(Nat.div(full, 2n), u))
      XHi{neg, Bool.pick(Nat, neg, Nat.sub(full, u), u), Nat.add(sz, 1n)}
    case False{}:
      XHiNo{}

# 2^bits of an integer of 16, 24 or 32 bits, by its size
def xh.int.full(sz: Nat) -> Nat:
  match sz:
    case 3n:
      65536n
    case 4n:
      16777216n
    case _:
      Nat.mul(65536n, 65536n)

# by its kind (D.lp.kind): 7 bits in its first byte; 13, the first
# byte's low 5 and the next; 16, 24 or 32 after its first byte
def xh.int.kind(k: Nat, ok: Bool, +x: Nat, +e: String, +i: Nat, +sz: Nat) -> XHi:
  match k:
    case 0n:
      xh.int.val(ok, x, 0n, sz)
    case 2n:
      xh.int.val(ok, Nat.add(Nat.mul(Nat.sub(x, 192n), 256n), xh.at(e, Nat.add(i, 1n))), 8192n, sz)
    case _:
      xh.int.val(ok, xh.le(Nat.sub(sz, 1n), e, Nat.add(i, 1n), 1n, 0n), xh.int.full(sz), sz)

# its bytes when it fits within e's
def xh.int.in(in: Bool, +k: Nat, +x: Nat, +e: String, +i: Nat, +sz: Nat) -> XHi:
  match in:
    case True{}:
      xh.int.kind(k, Nat.is_eq(xh.at(e, Nat.add(i, sz)), sz), x, e, i, sz)
    case False{}:
      XHiNo{}

# the size of an integer of the kind, or 0 for the others
def xh.int.size(k: Nat) -> Nat:
  match k:
    case 0n:
      1n
    case 2n:
      2n
    case 4n:
      3n
    case 5n:
      4n
    case 6n:
      5n
    case _:
      0n

# the integer at byte i of e (n bytes)
def xh.int(+e: String, +i: Nat, +n: Nat) -> XHi:
  +x = xh.at(e, i)
  +k = D.lp.kind(x)
  +sz = xh.int.size(k)
  xh.int.in(Bool.and(Nat.is_lt(0n, sz), Nat.is_lt(Nat.add(i, sz), n)), k, x, e, i, sz)

def xh.xn(neg: Bool, +m: Nat) -> KV.XN:
  match neg:
    case True{}:
      KV.xn.neg(KV.XS{m})
    case False{}:
      KV.XS{m}

def xh.fast.seq(h: XHi, +fl: Nat, +ms: KV.XN, +i: Nat, +e: String, +n: Nat, +mid: KV.XId) -> XEh:
  match h:
    case XHi{neg, +m, +k}:
      XEh{fl, D.xid.plus(mid, ms, xh.xn(neg, m)), Nat.add(i, k)}
    case XHiNo{}:
      xh.slow(e, n, mid)

def xh.fast.ms(h: XHi, +fl: Nat, +i: Nat, +e: String, +n: Nat, +mid: KV.XId) -> XEh:
  match h:
    case XHi{neg, +m, +k}:
      +j = Nat.add(i, k)
      xh.fast.seq(xh.int(e, j, n), fl, xh.xn(neg, m), j, e, n, mid)
    case XHiNo{}:
      xh.slow(e, n, mid)

def xh.fast(h: XHi, +e: String, +n: Nat, +mid: KV.XId) -> XEh:
  match h:
    case XHi{False{}, +m, +k}:
      xh.fast.ms(xh.int(e, k, n), m, k, e, n, mid)
    case _:
      xh.slow(e, n, mid)

# The fastest way, most entries' heads: each integer of 7 bits, in one
# byte below 128 with its backlen (1) after it, the three in the entry's
# first six bytes (b0, b2 and b4 the integers; past the entry's end a
# byte reads as 2^32 - 1, which is no such integer)
def xh.small(ok: Bool, +b0: Nat, +b2: Nat, +b4: Nat, +e: String, +n: Nat, +mid: KV.XId) -> XEh:
  match ok:
    case True{}:
      XEh{b0, D.xid.plus(mid, KV.XS{b2}, KV.XS{b4}), 6n}
    case False{}:
      xh.fast(xh.int(e, 0n, n), e, n, mid)

# whether b is an integer of 7 bits and c its backlen
def xh.small.at(+b: Nat, +c: Nat) -> Bool:
  Bool.and(Nat.is_lt(b, 128n), Nat.is_eq(c, 1n))

# whether the head of e (n bytes; b0, b2 and b4 its bytes 0, 2 and 4)
# reads small
def xh.small.ok(+e: String, +n: Nat, +b0: Nat, +b2: Nat, +b4: Nat) -> Bool:
  Bool.and(Bool.and(Nat.is_lt(6n, n), xh.small.at(b0, xh.at(e, 1n))), Bool.and(xh.small.at(b2, xh.at(e, 3n)), xh.small.at(b4, xh.at(e, 5n))))

def xh.read(+e: String, +mid: KV.XId) -> XEh:
  +n = String.length(e)
  +b0 = xh.at(e, 0n)
  +b2 = xh.at(e, 2n)
  +b4 = xh.at(e, 4n)
  xh.small(xh.small.ok(e, n, b0, b2, b4), b0, b2, b4, e, n, mid)

def xh.deleted(+fl: Nat) -> Bool:
  Nat.is_eq(Nat.mod(fl, 2n), 1n)

def xh.same(+fl: Nat) -> Bool:
  Nat.is_eq(Nat.mod(Nat.div(fl, 2n), 2n), 1n)

# how many fields fs holds, the list lent
def xe.nfs(+fs: List<&2, String>, +n: Nat) -> Nat:
  match fs:
    case Con{f, +rest}:
      xe.nfs(rest, Nat.add(n, 1n))
    case Nil{}:
      n

# k more elements from r on, after acc (the last first)
def xe.els(k: Nat, r: D.LpR, acc: List<&2, String>) -> List<&2, String>:
  match k r:
    case 1n+j D.LpOk{v, t}:
      xe.els(j, D.lp.next(t), v <> acc)
    case _ _:
      acc

# the master's fields fs (lent) and the values vs (the last first) in
# turn
def xe.zip(+fs: List<&2, String>, vs: List<&2, String>, acc: List<&2, String>) -> List<&2, String>:
  match fs vs:
    case Con{+f, +fr} Con{v, vr}:
      xe.zip(fr, vr, v <> (f <> acc))
    case _ _:
      List.reverse(&2, String, acc)

def xe.own(r: D.LpR) -> List<&2, String>:
  match r:
    case D.LpOk{+v, t}:
      List.reverse(&2, String, xe.els(Nat.mul(String.dec_at(v, 0n, String.length(v)), 2n), D.lp.next(t), Nil{}))
    case _:
      Nil{}

# an entry's fields and values, from the bytes t after its head (mfs:
# its node's master fields, lent)
def xe.body(same: Bool, t: String, +mfs: List<&2, String>) -> List<&2, String>:
  match same:
    case True{}:
      xe.zip(mfs, List.reverse(&2, String, xe.els(xe.nfs(mfs, 0n), D.lp.next(t), Nil{})), Nil{})
    case False{}:
      xe.own(D.lp.next(t))

# Nodes
# -----

def xns.lsize(+t: KV.XNodes) -> Nat:
  match t:
    case KV.XNTip{}:
      0n
    case KV.XNBin{n, x, +l, r}:
      KV.xns.size(l)

def xnode.none() -> KV.XNode:
  KV.XNd{xid.zero(), Nil{}, 0n, 0n, 0n, 0n, Nil{}}

# the node at place i of t (c: how i compares with the size of t's left
# side)
def xns.nth.go(+t: KV.XNodes, c: Cmp, +i: Nat) -> KV.XNode:
  match t c:
    case KV.XNTip{} _:
      xnode.none()
    case KV.XNBin{n, x, +l, r} LT{}:
      xns.nth.go(l, Nat.cmp(i, xns.lsize(l)), i)
    case KV.XNBin{n, +x, l, r} EQ{}:
      x
    case KV.XNBin{n, x, +l, +r} GT{}:
      +j = Nat.sub(i, Nat.add(KV.xns.size(l), 1n))
      xns.nth.go(r, Nat.cmp(j, xns.lsize(r)), j)

def xns.nth(+t: KV.XNodes, +i: Nat) -> KV.XNode:
  xns.nth.go(t, Nat.cmp(i, xns.lsize(t)), i)

# the place of the last node whose master ID is at most k, as raxSeek's
# "<=" finds it, or none (c: how k compares with t's root's master ID;
# b: the nodes before t)
def xns.floor.go(+t: KV.XNodes, c: Cmp, +k: KV.XId, +b: Nat, best: Maybe<&2, Nat>) -> Maybe<&2, Nat>:
  match t c:
    case KV.XNTip{} _:
      best
    case KV.XNBin{n, x, +l, r} LT{}:
      xns.floor.go(l, KV.xns.at(l, k), k, b, best)
    case KV.XNBin{n, x, +l, +r} _:
      +p = Nat.add(b, KV.xns.size(l))
      xns.floor.go(r, KV.xns.at(r, k), k, Nat.add(p, 1n), Some{p})

def xns.floor(+t: KV.XNodes, +k: KV.XId) -> Maybe<&2, Nat>:
  xns.floor.go(t, KV.xns.at(t, k), k, 0n, None{})

# Ranges
# ------
# streamIteratorGetID's walk: from the node raxSeek finds (the last whose
# master ID is at most the start, else the first; backwards, the last at
# most the end, else the last of all), through each node's entries in
# turn. Forwards, an entry deleted or before the start is passed; the
# first other one past the end ends the walk. Backwards, an entry deleted
# or past the end is passed; the first other one before the start ends
# it. A node may hold an entry before its master ID (XSETID below a
# deleted top, then XADD), which a walk finds where raxSeek puts it.

# A bound of a walk seen from the master ID of the node it is in, for the
# entries whose heads read small (xh.small: most of them). Such an
# entry's ID is the master ID's time plus its time's difference, and the
# master ID's sequence plus its sequence's, each difference below 128, so
# that it compares with the bound by its two differences alone, and no
# ID is made for an entry the walk passes. The bound is below every such
# entry (XRbLo), above every one (XRbHi), or at the time of the master
# ID's plus ms (XRbAt), its sequence below, above or at the master ID's
# plus n. A node whose master ID passes 10^14 - 128 in either part has
# no such bounds (XWrNo), and its heads are read as IDs.
type XRs is Data:
  XRsLo{}
  XRsHi{}
  XRsAt{n: Nat}

type XRb is Data:
  XRbLo{}
  XRbHi{}
  XRbAt{ms: Nat, sq: XRs}

type XWr is Data:
  XWr{lo: XRb, hi: XRb}
  XWrNo{}

# A walk's bounds: from lo to hi, backwards (rev), whether it wants IDs
# alone (ids), and the bounds seen from its node's master ID (r). XWqOf
# is never built: it makes XWq a node of its own, one word.
type XWq is Data:
  XWq{lo: KV.XId, hi: KV.XId, rev: Bool, ids: Bool, r: XWr}
  XWqOf{q: XWq}

# the bound b seen from a master ID of parts v and w (each at most 10^14
# - 128): its sequence (s), then its time (b's)
def xrs.at(near: Bool, +d: Nat) -> XRs:
  match near:
    case True{}:
      XRsAt{d}
    case False{}:
      XRsHi{}

def xrs.of(below: Bool, +z: Nat, +w: Nat) -> XRs:
  match below:
    case True{}:
      XRsLo{}
    case False{}:
      +d = Nat.sub(z, w)
      xrs.at(Nat.is_lt(d, 128n), d)

def xrs.from(+s: KV.XN, +w: Nat) -> XRs:
  match s:
    case KV.XS{+z}:
      xrs.of(Nat.is_lt(z, w), z, w)
    case KV.XL{h, l}:
      XRsHi{}

def xrb.at(near: Bool, +d: Nat, +s: KV.XN, +w: Nat) -> XRb:
  match near:
    case True{}:
      XRbAt{d, xrs.from(s, w)}
    case False{}:
      XRbHi{}

def xrb.of(below: Bool, +u: Nat, +s: KV.XN, +v: Nat, +w: Nat) -> XRb:
  match below:
    case True{}:
      XRbLo{}
    case False{}:
      +d = Nat.sub(u, v)
      xrb.at(Nat.is_lt(d, 128n), d, s, w)

def xrb.from.ms(+m: KV.XN, +s: KV.XN, +v: Nat, +w: Nat) -> XRb:
  match m:
    case KV.XS{+u}:
      xrb.of(Nat.is_lt(u, v), u, s, v, w)
    case KV.XL{h, l}:
      XRbHi{}

def xrb.from(+b: KV.XId, +v: Nat, +w: Nat) -> XRb:
  match b:
    case KV.XId{+m, +s}:
      xrb.from.ms(m, s, v, w)

def xwr.if(ok: Bool, +lo: KV.XId, +hi: KV.XId, +v: Nat, +w: Nat) -> XWr:
  match ok:
    case True{}:
      XWr{xrb.from(lo, v, w), xrb.from(hi, v, w)}
    case False{}:
      XWrNo{}

def xwr.seq(+lo: KV.XId, +hi: KV.XId, +v: Nat, +s: KV.XN) -> XWr:
  match s:
    case KV.XS{+w}:
      +top = Nat.sub(KV.xn.e14(), 128n)
      xwr.if(Bool.and(Nat.is_le(v, top), Nat.is_le(w, top)), lo, hi, v, w)
    case KV.XL{h, l}:
      XWrNo{}

# the bounds lo and hi seen from the master ID mid
def xwr.of(+lo: KV.XId, +hi: KV.XId, +mid: KV.XId) -> XWr:
  match mid:
    case KV.XId{KV.XS{+v}, +s}:
      xwr.seq(lo, hi, v, s)
    case KV.XId{KV.XL{h, l}, s}:
      XWrNo{}

# the walk's bounds in the node of master ID mid
def xwq.at(+q: XWq, +mid: KV.XId) -> XWq:
  match q:
    case XWq{+lo, +hi, +rev, +ids, r}:
      +r2 = xwr.of(lo, hi, mid)
      XWq{lo, hi, rev, ids, r2}
    case XWqOf{+y}:
      xwq.at(y, mid)

# how an entry whose head reads small (ms and sq: its differences)
# compares with a bound
def xrs.cmp(+sq: Nat, +s: XRs) -> Cmp:
  match s:
    case XRsLo{}:
      GT{}
    case XRsHi{}:
      LT{}
    case XRsAt{+n}:
      Nat.cmp(sq, n)

def xrb.cmp.at(c: Cmp, +sq: Nat, +s: XRs) -> Cmp:
  match c:
    case EQ{}:
      xrs.cmp(sq, s)
    case LT{}:
      LT{}
    case GT{}:
      GT{}

def xrb.cmp(+ms: Nat, +sq: Nat, +b: XRb) -> Cmp:
  match b:
    case XRbLo{}:
      GT{}
    case XRbHi{}:
      LT{}
    case XRbAt{+d, +s}:
      xrb.cmp.at(Nat.cmp(ms, d), sq, s)

# A walk: the entries taken (the newest first), how many more it may
# take, whether it is over, its bounds and the node it is in. A node's
# entries are kept the newest first, and a walk reads them where they
# lie, the node lent to it: backwards from the first on, forwards by a
# recursion down the list that visits each entry once the older ones are
# visited. The bounds and the node travel with the walk, which the
# recursion passes down and back up, so that it holds nothing but the
# entry it is at, and no entry is turned around, copied or dropped.
type XWk is Data:
  XWk{acc: List<&2, XE>, c: Nat, end: Bool, q: XWq, x: KV.XNode}

# what a walk does with an entry (pass 0, end 1, take 2) and the entry's
# head: read as an ID, read small (XWhS: its ID the node's master ID's
# parts plus ms and sq, its body six bytes on), or not read
type XWh is Data:
  XWh{k: Nat, fl: Nat, id: KV.XId, off: Nat}
  XWhS{k: Nat, fl: Nat, ms: Nat, sq: Nat}
  XWhBad{}

# what a forward walk does with an entry: pass one deleted or before lo,
# end at one past hi, take the others; backwards, pass one deleted or
# past hi, end at one before lo
def xw.what(rev: Bool, +fl: Nat, +id: KV.XId, +lo: KV.XId, +hi: KV.XId) -> Nat:
  match rev:
    case False{}:
      Bool.pick(Nat, Bool.or(xh.deleted(fl), Cmp.is_lt(KV.xid.cmp(id, lo))), 0n, Bool.pick(Nat, Cmp.is_gt(KV.xid.cmp(id, hi)), 1n, 2n))
    case True{}:
      Bool.pick(Nat, Bool.or(xh.deleted(fl), Cmp.is_gt(KV.xid.cmp(id, hi))), 0n, Bool.pick(Nat, Cmp.is_lt(KV.xid.cmp(id, lo)), 1n, 2n))

# the same of an entry whose head reads small, by its flags fl and its
# differences ms and sq, the bounds seen from its node's master ID (rl,
# rh)
def xw.what.s(rev: Bool, +fl: Nat, +ms: Nat, +sq: Nat, +rl: XRb, +rh: XRb) -> Nat:
  match rev:
    case False{}:
      Bool.pick(Nat, Bool.or(xh.deleted(fl), Cmp.is_lt(xrb.cmp(ms, sq, rl))), 0n, Bool.pick(Nat, Cmp.is_gt(xrb.cmp(ms, sq, rh)), 1n, 2n))
    case True{}:
      Bool.pick(Nat, Bool.or(xh.deleted(fl), Cmp.is_gt(xrb.cmp(ms, sq, rh))), 0n, Bool.pick(Nat, Cmp.is_lt(xrb.cmp(ms, sq, rl)), 1n, 2n))

def xw.k.of(h: XEh, +rev: Bool, +lo: KV.XId, +hi: KV.XId) -> XWh:
  match h:
    case XEh{+fl, +id, +off}:
      XWh{xw.what(rev, fl, id, lo, hi), fl, id, off}
    case XEhBad{}:
      XWhBad{}

def xw.k.h(h: XEh, +q: XWq) -> XWh:
  match q:
    case XWq{+lo, +hi, +rev, ids, r}:
      xw.k.of(h, rev, lo, hi)
    case XWqOf{+y}:
      xw.k.h(h, y)

# a head that reads small (flags b0, differences b2 and b4) of an entry of
# the node x: compared with the bounds seen from x's master ID, or, x
# having none, read as an ID
def xw.k.s(+q: XWq, +b0: Nat, +b2: Nat, +b4: Nat, +x: KV.XNode) -> XWh:
  match q:
    case XWq{lo, hi, +rev, ids, XWr{+rl, +rh}}:
      XWhS{xw.what.s(rev, b0, b2, b4, rl, rh), b0, b2, b4}
    case XWq{+lo, +hi, +rev, ids, XWrNo{}}:
      +id = D.xid.plus(KV.xnode.mid(x), KV.XS{b2}, KV.XS{b4})
      XWh{xw.what(rev, b0, id, lo, hi), b0, id, 6n}
    case XWqOf{+y}:
      xw.k.s(y, b0, b2, b4, x)

def xw.k.small(ok: Bool, +b0: Nat, +b2: Nat, +b4: Nat, +e: String, +n: Nat, +x: KV.XNode, +q: XWq) -> XWh:
  match ok:
    case True{}:
      xw.k.s(q, b0, b2, b4, x)
    case False{}:
      xw.k.h(xh.fast(xh.int(e, 0n, n), e, n, KV.xnode.mid(x)), q)

# the entry e of the node x read, and what the walk does with it
def xw.k(+e: String, +x: KV.XNode, +q: XWq) -> XWh:
  +n = String.length(e)
  +b0 = xh.at(e, 0n)
  +b2 = xh.at(e, 2n)
  +b4 = xh.at(e, 4n)
  xw.k.small(xh.small.ok(e, n, b0, b2, b4), b0, b2, b4, e, n, x, q)

# an entry's body, read from a copy of its bytes past its head (off on),
# its node x's master fields lent
def xw.body.of(+fl: Nat, +e: String, +off: Nat, +x: KV.XNode) -> List<&2, String>:
  match x:
    case KV.XNd{mid, +mfs, live, dead, bytes, nel, es}:
      xe.body(xh.same(fl), String.slice(e, off, Nat.sub(String.length(e), off)), mfs)
    case KV.XNdOf{+y}:
      xw.body.of(fl, e, off, y)

def xw.body.ids(ids: Bool, +fl: Nat, +e: String, +off: Nat, +x: KV.XNode) -> List<&2, String>:
  match ids:
    case True{}:
      Nil{}
    case False{}:
      xw.body.of(fl, e, off, x)

# an entry's body, or none for a walk that wants IDs alone
def xw.body(+fl: Nat, +e: String, +off: Nat, +q: XWq, +x: KV.XNode) -> List<&2, String>:
  match q:
    case XWq{lo, hi, rev, +ids, r}:
      xw.body.ids(ids, fl, e, off, x)
    case XWqOf{+y}:
      xw.body(fl, e, off, y, x)

# pass (0), end (1), or take (2)
def xw.do(k: Nat, +fl: Nat, +id: KV.XId, +e: String, +off: Nat, acc: List<&2, XE>, +c: Nat, +q: XWq, +x: KV.XNode) -> XWk:
  match k:
    case 0n:
      XWk{acc, c, False{}, q, x}
    case 1n:
      XWk{acc, c, True{}, q, x}
    case _:
      XWk{XE{id, xw.body(fl, e, off, q, x)} <> acc, Nat.sub(c, 1n), Nat.is_eq(c, 1n), q, x}

# the same of an entry whose head reads small, its ID made for a take
# alone
def xw.do.s(k: Nat, +fl: Nat, +ms: Nat, +sq: Nat, +e: String, acc: List<&2, XE>, +c: Nat, +q: XWq, +x: KV.XNode) -> XWk:
  match k:
    case 0n:
      XWk{acc, c, False{}, q, x}
    case 1n:
      XWk{acc, c, True{}, q, x}
    case _:
      XWk{XE{D.xid.plus(KV.xnode.mid(x), KV.XS{ms}, KV.XS{sq}), xw.body(fl, e, 6n, q, x)} <> acc, Nat.sub(c, 1n), Nat.is_eq(c, 1n), q, x}

def xw.step(h: XWh, +e: String, acc: List<&2, XE>, +c: Nat, q: XWq, x: KV.XNode) -> XWk:
  match h:
    case XWh{+k, +fl, +id, +off}:
      xw.do(k, fl, id, e, off, acc, c, q, x)
    case XWhS{+k, +fl, +ms, +sq}:
      xw.do.s(k, fl, ms, sq, e, acc, c, q, x)
    case XWhBad{}:
      XWk{acc, c, True{}, q, x}

# the walk at the entry e of its node, unless it is over
def xw.ent(+e: String, w: XWk) -> XWk:
  match w:
    case XWk{acc, +c, False{}, +q, +x}:
      xw.step(xw.k(e, x, q), e, acc, c, q, x)
    case other:
      other

# a walk backwards through a node's entries es
def xw.back(+es: List<&2, String>, w: XWk) -> XWk:
  match es w:
    case Con{+e, +rest} XWk{acc, +c, False{}, +q, +x}:
      xw.back(rest, xw.step(xw.k(e, x, q), e, acc, c, q, x))
    case _ other:
      other

# a walk forwards through a node's entries es: the older ones, then e
def xw.fwd(+es: List<&2, String>, w: XWk) -> XWk:
  match es:
    case Con{+e, +rest}:
      xw.ent(e, xw.fwd(rest, w))
    case Nil{}:
      w

# A walk forwards from lo past a node's master ID mid. A node's live
# entries' IDs grow, the oldest first (XADD and XSETID keep them so, and
# rdb.bend checks a node it reads), so that every live entry older than
# one before lo is before lo too. The walk reads the node's newest entry
# first: when it is live and before lo, the node holds nothing the walk
# takes, and the walk passes it whole; when lo seems nearer the newest
# entry than mid, the walk goes down from the newest, reading each
# entry's head, to the first live one before lo, which it passes with the
# older ones, and takes or passes the entries above it, the oldest first;
# else it goes from the oldest, as from a start at mid. The walk takes the
# same entries in each way; the guess decides how many heads it reads.

# whether b is nearer c than a, for a <= b <= c: by their times when a's
# and c's differ, else by their sequences
def xw.nearer.of(same: Bool, +ma: KV.XN, +sa: KV.XN, +mb: KV.XN, +sb: KV.XN, +mc: KV.XN, +sc: KV.XN) -> Bool:
  match same:
    case True{}:
      Cmp.is_lt(KV.xn.cmp(xn.sub(sc, sb), xn.sub(sb, sa)))
    case False{}:
      Cmp.is_lt(KV.xn.cmp(xn.sub(mc, mb), xn.sub(mb, ma)))

def xw.nearer(+a: KV.XId, +b: KV.XId, +c: KV.XId) -> Bool:
  match a b c:
    case KV.XId{+ma, +sa} KV.XId{+mb, +sb} KV.XId{+mc, +sc}:
      xw.nearer.of(KV.xn.is_eq(ma, mc), ma, sa, mb, sb, mc, sc)

# What a walk down a node does at an entry, its head h read: it stops,
# passing the entry and the older ones (XCStop); it takes or passes the
# entry once the older ones are walked down (XCGo); it walks the older
# ones from the oldest, then the entry (XCAll); or, the head not read, it
# walks the older ones from the oldest and ends at the entry, as a walk
# from the oldest ends at it (XCBad)
type XCut is Data:
  XCStop{}
  XCGo{h: XWh}
  XCAll{h: XWh}
  XCBad{}

def xw.cut.pick(m: Nat, h: XWh) -> XCut:
  match m:
    case 0n:
      XCStop{}
    case 1n:
      XCGo{h}
    case _:
      XCAll{h}

# whether an entry is live and before lo: one the walk passes (k: 0, as
# it passes one deleted or before lo) not deleted
def xw.before(+k: Nat, +fl: Nat) -> Bool:
  Bool.and(Nat.is_eq(k, 0n), Bool.not(xh.deleted(fl)))

# at the newest entry: the node passed whole when the entry is live and
# before lo (0), down from it when lo seems nearer it than mid (1), else
# from the oldest (2)
def xw.cut.top(h: XWh, +lo: KV.XId, +mid: KV.XId) -> XCut:
  match h:
    case XWh{+k, +fl, +id, +off}:
      xw.cut.pick(Bool.pick(Nat, xw.before(k, fl), 0n, Bool.pick(Nat, xw.nearer(mid, lo, id), 1n, 2n)), XWh{k, fl, id, off})
    case XWhS{+k, +fl, +ms, +sq}:
      xw.cut.pick(Bool.pick(Nat, xw.before(k, fl), 0n, Bool.pick(Nat, xw.nearer(mid, lo, D.xid.plus(mid, KV.XS{ms}, KV.XS{sq})), 1n, 2n)), XWhS{k, fl, ms, sq})
    case XWhBad{}:
      XCBad{}

# at an older one on the way down: stop at a live one before lo
def xw.cut.at(h: XWh) -> XCut:
  match h:
    case XWh{+k, +fl, +id, +off}:
      xw.cut.pick(Bool.pick(Nat, xw.before(k, fl), 0n, 1n), XWh{k, fl, id, off})
    case XWhS{+k, +fl, +ms, +sq}:
      xw.cut.pick(Bool.pick(Nat, xw.before(k, fl), 0n, 1n), XWhS{k, fl, ms, sq})
    case XWhBad{}:
      XCBad{}

# the walk at the entry e of its node, its head h read, unless it is over
def xw.ent.h(h: XWh, +e: String, w: XWk) -> XWk:
  match w:
    case XWk{acc, +c, False{}, +q, +x}:
      xw.step(h, e, acc, c, q, x)
    case other:
      other

# what the walk down does at the head of es, the newest of them (at its
# end, nothing more: it stops)
def xw.cut.next(+es: List<&2, String>, +x: KV.XNode, +q: XWq) -> XCut:
  match es:
    case Con{+e, +rest}:
      xw.cut.at(xw.k(e, x, q))
    case Nil{}:
      XCStop{}

# the walk down a node's entries es from their head (d: what it does
# there). The entry at the head is a field of es, which the node lends, so
# that keeping it for the way back up takes nothing (a parameter kept
# across the call down would be taken, and every walk's entries with it)
def xw.cut(+es: List<&2, String>, d: XCut, w: XWk) -> XWk:
  match es d w:
    case Con{+e, +t} XCGo{+h} XWk{acc, +c, False{}, +q, +x}:
      xw.ent.h(h, e, xw.cut(t, xw.cut.next(t, x, q), XWk{acc, c, False{}, q, x}))
    case Con{+e, +t} XCAll{+h} w0:
      xw.ent.h(h, e, xw.fwd(t, w0))
    case Con{+e, +t} XCBad{} w0:
      xw.ent(e, xw.fwd(t, w0))
    case _ _ w0:
      w0

def xwq.lo(+q: XWq) -> KV.XId:
  match q:
    case XWq{+lo, hi, rev, ids, r}:
      lo
    case XWqOf{+y}:
      xwq.lo(y)

# what the walk down does at the newest entry, the head of es
def xw.cut.first(+es: List<&2, String>, +lo: KV.XId, +mid: KV.XId, +x: KV.XNode, +q: XWq) -> XCut:
  match es:
    case Con{+e, +rest}:
      xw.cut.top(xw.k(e, x, q), lo, mid)
    case Nil{}:
      XCStop{}

# a walk forwards through a node's entries es: from the oldest when lo is
# at most mid, else from the newest entry's head (xw.cut.top)
def xw.fwd.of(past: Bool, +es: List<&2, String>, +mid: KV.XId, w: XWk) -> XWk:
  match past w:
    case True{} XWk{acc, +c, False{}, +q, +x}:
      +lo = xwq.lo(q)
      xw.cut(es, xw.cut.first(es, lo, mid, x, q), XWk{acc, c, False{}, q, x})
    case False{} w0:
      xw.fwd(es, w0)
    case _ w0:
      w0

def xw.fwd.top(+es: List<&2, String>, +mid: KV.XId, w: XWk) -> XWk:
  match w:
    case XWk{acc, +c, end, +q, +x}:
      xw.fwd.of(Cmp.is_gt(KV.xid.cmp(xwq.lo(q), mid)), es, mid, XWk{acc, c, end, q, x})

def xw.node.go(rev: Bool, +mid: KV.XId, +es: List<&2, String>, w: XWk) -> XWk:
  match rev:
    case True{}:
      xw.back(es, w)
    case False{}:
      xw.fwd.top(es, mid, w)

# a walk through the node x, the walk's node
def xw.node(+x: KV.XNode, +rev: Bool, w: XWk) -> XWk:
  match x:
    case KV.XNd{+mid, mfs, live, dead, bytes, nel, +es}:
      xw.node.go(rev, mid, es, w)
    case KV.XNdOf{+y}:
      xw.node(y, rev, w)

# the walk with y as its node, its bounds seen from y's master ID
def xw.in(+y: KV.XNode, w: XWk) -> XWk:
  match w:
    case XWk{acc, c, end, q, x}:
      XWk{acc, c, end, xwq.at(q, KV.xnode.mid(y)), y}

# the walk through the node at place i of t (c: how i compares with the
# size of t's left side), found in place and lent to the walk
def xw.nth(+t: KV.XNodes, c: Cmp, +i: Nat, +rev: Bool, w: XWk) -> XWk:
  match t c:
    case KV.XNTip{} _:
      w
    case KV.XNBin{n, y, +l, r} LT{}:
      xw.nth(l, Nat.cmp(i, xns.lsize(l)), i, rev, w)
    case KV.XNBin{n, +y, l, r} EQ{}:
      xw.node(y, rev, xw.in(y, w))
    case KV.XNBin{n, y, +l, +r} GT{}:
      +j = Nat.sub(i, Nat.add(KV.xns.size(l), 1n))
      xw.nth(r, Nat.cmp(j, xns.lsize(r)), j, rev, w)

# a walk through k nodes of t from place i on, forwards or backwards
def xw.nodes(k: Nat, w: XWk, +t: KV.XNodes, +i: Nat, +rev: Bool) -> XWk:
  match k w:
    case 1n+j XWk{acc, +c, False{}, q, x}:
      xw.nodes(j, xw.nth(t, Nat.cmp(i, xns.lsize(t)), i, rev, XWk{acc, c, False{}, q, x}), t, Bool.pick(Nat, rev, Nat.sub(i, 1n), Nat.add(i, 1n)), rev)
    case _ other:
      other

# where a walk starts: forwards, at the last node whose master ID is at
# most lo (lo not 0-0), else at the first; backwards, at the last whose
# master ID is at most hi (hi not 0-0), else at the last
def xw.start(m: Maybe<&2, Nat>, +dflt: Nat) -> Nat:
  match m:
    case Some{+p}:
      p
    case None{}:
      dflt

# the bound a walk starts from: hi backwards, else lo (a match, as an ID
# picked by Bool.pick is made a node of its own)
def xw.key(rev: Bool, +lo: KV.XId, +hi: KV.XId) -> KV.XId:
  match rev:
    case True{}:
      hi
    case False{}:
      lo

def xw.at(+t: KV.XNodes, +rev: Bool, +lo: KV.XId, +hi: KV.XId) -> Nat:
  +n = KV.xns.size(t)
  +k = xw.key(rev, lo, hi)
  +dflt = Bool.pick(Nat, rev, Nat.sub(n, 1n), 0n)
  Bool.pick(Nat, xid.is_zero(k), dflt, xw.start(xns.floor(t, k), dflt))

def xstream.nodes(+x: KV.XStream) -> KV.XNodes:
  match x:
    case KV.XStr{n, last, first, maxdel, added, +nodes, groups}:
      nodes
    case KV.XStrOf{+y}:
      xstream.nodes(y)

# The sizes of a stream's trees, read in place. A size passed a tree that
# a call made (xstream.nodes's) would take the tree it is passed, and so
# take every tree it is given: a tree kept in the keyspace would then be
# copied, each time its size is read, and its copy dropped.

# how many nodes x holds
def xs.nnodes(+x: KV.XStream) -> Nat:
  match x:
    case KV.XStr{n, last, first, maxdel, added, nodes, groups}:
      KV.xns.size(nodes)
    case KV.XStrOf{+y}:
      xs.nnodes(y)

# how many groups x has
def xs.ngroups(+x: KV.XStream) -> Nat:
  match x:
    case KV.XStr{n, last, first, maxdel, added, nodes, groups}:
      KV.xgs.size(groups)
    case KV.XStrOf{+y}:
      xs.ngroups(y)

# a walk's entries in the order it took them
def xw.taken(w: XWk) -> List<&2, XE>:
  match w:
    case XWk{acc, c, e, q, x}:
      List.reverse(&2, XE, acc)

# the entries of x from lo to hi, at most c of them (c at least 1), in
# the order of the walk (rev: from hi down); with ids, their IDs alone
# (their fields and values none)
def xs.walk(+x: KV.XStream, +lo: KV.XId, +hi: KV.XId, +c: Nat, +rev: Bool, +ids: Bool) -> List<&2, XE>:
  +t = xstream.nodes(x)
  +i = xw.at(t, rev, lo, hi)
  +n = KV.xns.size(t)
  +k = Bool.pick(Nat, rev, Nat.add(i, 1n), Nat.sub(n, i))
  xw.taken(xw.nodes(Bool.pick(Nat, Nat.is_eq(n, 0n), 0n, k), XWk{Nil{}, c, False{}, XWq{lo, hi, rev, ids, XWrNo{}}, xnode.none()}, t, i, rev))

def xs.range(+x: KV.XStream, +lo: KV.XId, +hi: KV.XId, +c: Nat, +rev: Bool) -> List<&2, XE>:
  xs.walk(x, lo, hi, c, rev, False{})

# A stream's header
# -----------------

def xstream.last(+x: KV.XStream) -> KV.XId:
  match x:
    case KV.XStr{n, +last, first, maxdel, added, nodes, groups}:
      last
    case KV.XStrOf{+y}:
      xstream.last(y)

def xstream.first(+x: KV.XStream) -> KV.XId:
  match x:
    case KV.XStr{n, last, +first, maxdel, added, nodes, groups}:
      first
    case KV.XStrOf{+y}:
      xstream.first(y)

def xstream.maxdel(+x: KV.XStream) -> KV.XId:
  match x:
    case KV.XStr{n, last, first, +maxdel, added, nodes, groups}:
      maxdel
    case KV.XStrOf{+y}:
      xstream.maxdel(y)

def xstream.added(+x: KV.XStream) -> KV.XN:
  match x:
    case KV.XStr{n, last, first, maxdel, +added, nodes, groups}:
      added
    case KV.XStrOf{+y}:
      xstream.added(y)

def xstream.groups(+x: KV.XStream) -> KV.XGroups:
  match x:
    case KV.XStr{n, last, first, maxdel, added, nodes, +groups}:
      groups
    case KV.XStrOf{+y}:
      xstream.groups(y)

def xs.top.of(es: List<&2, XE>) -> Maybe<&2, KV.XId>:
  match es:
    case Con{XE{id, fv}, rest}:
      Some{id}
    case Nil{}:
      None{}

# the last live entry's ID (streamLastValidID), none in an empty stream
# (x matched first, as in xn.is_max)
def xs.top(+x: KV.XStream) -> Maybe<&2, KV.XId>:
  match x:
    case KV.XStr{+n, +last, +first, +maxdel, +added, +nodes, +groups}:
      xs.top.of(xs.walk(KV.XStr{n, last, first, maxdel, added, nodes, groups}, xid.zero(), xid.max(), 1n, True{}, True{}))
    case KV.XStrOf{+y}:
      xs.top(y)

# The radix tree's nodes
# ----------------------
# XINFO STREAM's radix-tree-nodes: the nodes of a rax whose keys are the
# nodes' master IDs (16 bytes each, big-endian), in its compressed form (a
# model, which matched Redis's count on 1,244 states that XADD, XDEL and
# XTRIM made, a node an entry, IDs small, huge and near powers of two;
# tests/stream_read_test.py compares it on each of its shapes): a head;
# for each group of keys that branches, a node, and before it a
# compressed node for the bytes its keys share past their parent's; for
# each key, a leaf, and before it a compressed node for the bytes left
# after its parent's branch. Over the keys in order, with h each
# pair's count of bytes in common, plus 1 (0 stands for none): the groups
# are the intervals of h a stack finds, each with its parent's h; a key's
# parent branches at the larger h of its neighbours.

# how many of their first k bytes a and b share from i on (same: whether
# the bytes at i are the same)
def rax.lcp(k: Nat, same: Bool, +a: String, +b: String, +i: Nat) -> Nat:
  match k same:
    case 1n+j True{}:
      +n = Nat.add(i, 1n)
      rax.lcp(j, U32.is_eq(String.code_at(a, n), String.code_at(b, n)), a, b, n)
    case _ _:
      i

def rax.key(+x: KV.XNode) -> String:
  D.put.id16(KV.xnode.mid(x), "")

# the h of each pair of keys in turn, the first's key prev
def rax.hs(xs: List<&2, KV.XNode>, +prev: String, acc: List<&2, Nat>) -> List<&2, Nat>:
  match xs:
    case Con{+x, rest}:
      +k = rax.key(x)
      rax.hs(rest, k, Nat.add(rax.lcp(16n, U32.is_eq(String.code_at(prev, 0n), String.code_at(k, 0n)), prev, k, 0n), 1n) <> acc)
    case Nil{}:
      List.reverse(&2, Nat, acc)

def rax.top(+st: List<&2, Nat>) -> Nat:
  match st:
    case Con{+v, rest}:
      v
    case Nil{}:
      0n

# a group's nodes: its branch, and a compressed node when its keys share
# bytes past their parent's branch (p: the parent's h, 0 for the root)
def rax.inner(+v: Nat, +p: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_eq(p, 0n), Bool.pick(Nat, Nat.is_lt(1n, v), 2n, 1n), Bool.pick(Nat, Nat.is_lt(Nat.add(p, 1n), v), 2n, 1n))

# the stack of groups (the top first) and the nodes counted so far
type RaxS is Data:
  RaxS{st: List<&2, Nat>, acc: Nat}

# the stack without the groups above x (gt: whether its top is), each
# group's nodes added to acc
def rax.pop(st: List<&2, Nat>, gt: Bool, +x: Nat, +acc: Nat) -> RaxS:
  match st gt:
    case Con{+v, +rest} True{}:
      rax.pop(rest, Nat.is_lt(x, rax.top(rest)), x, Nat.add(acc, rax.inner(v, Nat.max(rax.top(rest), x))))
    case other _:
      RaxS{other, acc}

# x on the stack, unless its top is x already (or x stands for none)
def rax.push(s: RaxS, +x: Nat) -> RaxS:
  match s:
    case RaxS{+st, acc}:
      RaxS{Bool.pick(List<&2, Nat>, Bool.and(Nat.is_lt(0n, x), Nat.is_lt(rax.top(st), x)), x <> st, st), acc}

def rax.acc(s: RaxS) -> Nat:
  match s:
    case RaxS{st, acc}:
      acc

def rax.go(hs: List<&2, Nat>, s: RaxS) -> Nat:
  match hs s:
    case Con{+h, rest} RaxS{+st, +acc}:
      rax.go(rest, rax.push(rax.pop(st, Nat.is_lt(h, rax.top(st)), h, acc), h))
    case Nil{} RaxS{+st, +acc}:
      rax.acc(rax.pop(st, Nat.is_lt(0n, rax.top(st)), 0n, acc))

# a leaf, and a compressed node before it unless its parent branches at
# the last byte
def rax.leaf(+q: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_lt(q, 16n), 2n, 1n)

def rax.leaves(hs: List<&2, Nat>, +prev: Nat, +acc: Nat) -> Nat:
  match hs:
    case Con{+h, rest}:
      rax.leaves(rest, h, Nat.add(acc, rax.leaf(Nat.max(prev, h))))
    case Nil{}:
      Nat.add(acc, rax.leaf(prev))

def rax.of(xs: List<&2, KV.XNode>) -> Nat:
  match xs:
    case Nil{}:
      1n
    case Con{+x, Nil{}}:
      2n
    case Con{+x, +rest}:
      +hs = rax.hs(rest, rax.key(x), Nil{})
      Nat.add(rax.go(hs, RaxS{Nil{}, 0n}), rax.leaves(hs, 0n, 0n))

def xs.rax(+x: KV.XStream) -> Nat:
  rax.of(KV.xns.list(xstream.nodes(x), Nil{}))

# Groups
# ------

def xgroup.last(+g: KV.XGroup) -> KV.XId:
  match g:
    case KV.XGrp{name, +last, rd, pel, cons}:
      last
    case KV.XGrpOf{+y}:
      xgroup.last(y)

def xgroup.read(+g: KV.XGroup) -> KV.XRd:
  match g:
    case KV.XGrp{name, last, +rd, pel, cons}:
      rd
    case KV.XGrpOf{+y}:
      xgroup.read(y)

def xgroup.pel(+g: KV.XGroup) -> KV.XPel:
  match g:
    case KV.XGrp{name, last, rd, +pel, cons}:
      pel
    case KV.XGrpOf{+y}:
      xgroup.pel(y)

def xgroup.cons(+g: KV.XGroup) -> KV.XCons:
  match g:
    case KV.XGrp{name, last, rd, pel, +cons}:
      cons
    case KV.XGrpOf{+y}:
      xgroup.cons(y)

# how many entries are pending in g, and how many consumers it has, read
# in place (xs.nnodes)
def xgroup.npel(+g: KV.XGroup) -> Nat:
  match g:
    case KV.XGrp{name, last, rd, pel, cons}:
      KV.xpl.size(pel)
    case KV.XGrpOf{+y}:
      xgroup.npel(y)

def xgroup.ncons(+g: KV.XGroup) -> Nat:
  match g:
    case KV.XGrp{name, last, rd, pel, cons}:
      KV.xcs.size(cons)
    case KV.XGrpOf{+y}:
      xgroup.ncons(y)

def xs.group(+x: KV.XStream, +name: String) -> Maybe<&2, KV.XGroup>:
  +t = xstream.groups(x)
  KV.xgs.find(t, KV.xgs.at(t, name), name)

def xgroup.con(+g: KV.XGroup, +name: String) -> Maybe<&2, KV.XCon>:
  +t = xgroup.cons(g)
  KV.xcs.find(t, KV.xcs.at(t, name), name)

def xcon.seen(+c: KV.XCon) -> Nat:
  match c:
    case KV.XCon{name, +seen, active, ids}:
      seen

def xcon.ids(+c: KV.XCon) -> KV.XIds:
  match c:
    case KV.XCon{name, seen, active, +ids}:
      ids

# how many entries are pending for c, read in place (xs.nnodes)
def xcon.nids(+c: KV.XCon) -> Nat:
  match c:
    case KV.XCon{name, seen, active, ids}:
      KV.xis.size(ids)

def xcon.active(+c: KV.XCon) -> KV.XAct:
  match c:
    case KV.XCon{name, seen, +active, ids}:
      active

def xnack.owner(+x: KV.XNack) -> String:
  match x:
    case KV.XNk{id, +owner, time, count}:
      owner
    case KV.XNkOf{+y}:
      xnack.owner(y)

def xnack.time(+x: KV.XNack) -> Nat:
  match x:
    case KV.XNk{id, owner, +time, count}:
      time
    case KV.XNkOf{+y}:
      xnack.time(y)

def xnack.count(+x: KV.XNack) -> KV.XN:
  match x:
    case KV.XNk{id, owner, time, +count}:
      count
    case KV.XNkOf{+y}:
      xnack.count(y)

# The count of entries read and the lag
# -------------------------------------

# streamEstimateDistanceFromFirstEverEntry, as Redis 7.2.16 reckons it:
# id's count of entries read, as a long long's 64 bits, 2^64 - 1 (-1) for
# none: 0 in a stream no entry was ever added to; the count of entries
# added at any ID up to the last in an empty stream; none for an ID (but
# 0-0) before the greatest one deleted; the count of entries added at the
# last ID; none past it; with no entry deleted after the first live one,
# the entries added less the live ones before the first live entry, one
# more at it; else none
def xs.est.first(c: Cmp, +added: KV.XN, +n: Nat) -> KV.XN:
  match c:
    case LT{}:
      xn.sub(added, KV.xn.of(n))
    case EQ{}:
      KV.xn.add(xn.sub(added, KV.xn.of(n)), xn.one())
    case GT{}:
      D.xn.max()

def xs.est.last(c: Cmp, +added: KV.XN, +n: Nat, +first: KV.XId, +maxdel: KV.XId, +id: KV.XId) -> KV.XN:
  match c:
    case EQ{}:
      added
    case GT{}:
      D.xn.max()
    case LT{}:
      Bool.pick(KV.XN, Bool.or(xid.is_zero(maxdel), Cmp.is_lt(KV.xid.cmp(maxdel, first))), xs.est.first(KV.xid.cmp(id, first), added, n), D.xn.max())

def xs.est(+x: KV.XStream, +id: KV.XId) -> KV.XN:
  +added = xstream.added(x)
  +n = KV.xstream.len(x)
  +last = xstream.last(x)
  +c = KV.xid.cmp(id, last)
  +maxdel = xstream.maxdel(x)
  +frag = Bool.and(Bool.not(xid.is_zero(id)), Cmp.is_lt(KV.xid.cmp(id, maxdel)))
  Bool.pick(KV.XN, KV.xn.is_eq(added, xn.zero()), xn.zero(), Bool.pick(KV.XN, Bool.and(Nat.is_eq(n, 0n), Bool.not(Cmp.is_gt(c))), added, Bool.pick(KV.XN, frag, D.xn.max(), xs.est.last(c, added, n, xstream.first(x), maxdel, id))))

# streamRangeHasTombstones from start to the last ID, as Redis 7.2.16
# reckons it: whether the stream holds entries and an entry was deleted at
# or after start (7.0 also asked that the deletion be past the first live
# entry)
def xs.tomb(+x: KV.XStream, +start: KV.XId) -> Bool:
  +maxdel = xstream.maxdel(x)
  +live = Bool.and(Nat.is_lt(0n, KV.xstream.len(x)), Bool.not(xid.is_zero(maxdel)))
  Bool.and(live, Bool.not(Cmp.is_gt(KV.xid.cmp(start, maxdel))))

def xs.lag.est(+added: KV.XN, +e: KV.XN) -> Maybe<&2, KV.XN>:
  Bool.pick(Maybe<&2, KV.XN>, xn.is_max(e), None{}, Some{xn.sub(added, e)})

def xs.lag.of(rd: KV.XRd, +x: KV.XStream, +last: KV.XId, +added: KV.XN) -> Maybe<&2, KV.XN>:
  match rd:
    case KV.XRdN{+r}:
      Bool.pick(Maybe<&2, KV.XN>, xs.tomb(x, last), xs.lag.est(added, xs.est(x, last)), Some{xn.sub(added, r)})
    case KV.XRdNone{}:
      xs.lag.est(added, xs.est(x, last))

# streamReplyWithCGLag, as Redis 7.2.16 reckons it: a group's lag, as a
# long long's 64 bits, or none: 0 for a stream no entry was ever added
# to, and for one whose entries are all gone; the stream's length when
# both the group's last ID and the greatest ID deleted are before its
# first entry; else from the group's count of entries read, when it has
# one and no entry was deleted at or after its last ID, or from the
# estimate of the count at its last ID
def xs.lag(+x: KV.XStream, +g: KV.XGroup) -> Maybe<&2, KV.XN>:
  +added = xstream.added(x)
  +n = KV.xstream.len(x)
  +last = xgroup.last(g)
  +first = xstream.first(x)
  +behind = Bool.and(Cmp.is_lt(KV.xid.cmp(last, first)), Cmp.is_lt(KV.xid.cmp(xstream.maxdel(x), first)))
  Bool.pick(Maybe<&2, KV.XN>, Bool.or(KV.xn.is_eq(added, xn.zero()), Nat.is_eq(n, 0n)), Some{xn.zero()}, Bool.pick(Maybe<&2, KV.XN>, behind, Some{KV.xn.of(n)}, xs.lag.of(xgroup.read(g), x, last, added)))

# Pending entries
# ---------------
# XPENDING's walk of a group's pending entries, or a consumer's, from an
# ID on (raxSeek's ">="): each up to the end, at most c of them, those
# idle less than IDLE's time passed

# IDLE's time: none (or 0), or a long long (neg: below 0; n its
# magnitude, at most 2^47, past any time's)
type XIdle is Data:
  XINone{}
  XIMin{neg: Bool, n: Nat}

# whether an entry delivered at time passes at now: Redis's now - time,
# a long long, not below IDLE's time
def xidle.ok(+i: XIdle, +time: Nat, +now: Nat) -> Bool:
  match i:
    case XINone{}:
      True{}
    case XIMin{+neg, +n}:
      Bool.pick(Bool, neg, Bool.or(Nat.is_le(time, now), Nat.is_le(Nat.sub(time, now), n)), Bool.and(Nat.is_le(time, now), Nat.is_le(n, Nat.sub(now, time))))

# A walk: the entries taken (the newest first), how many more it may
# take, and whether it is over
type XPw is Data:
  XPw{acc: List<&2, KV.XNack>, c: Nat, end: Bool}

def xp.take(ok: Bool, +x: KV.XNack, acc: List<&2, KV.XNack>, +c: Nat) -> XPw:
  match ok:
    case True{}:
      XPw{x <> acc, Nat.sub(c, 1n), Nat.is_eq(c, 1n)}
    case False{}:
      XPw{acc, c, False{}}

def xp.visit.at(past: Bool, +x: KV.XNack, acc: List<&2, KV.XNack>, +c: Nat, +idle: XIdle, +now: Nat) -> XPw:
  match past:
    case True{}:
      XPw{acc, c, True{}}
    case False{}:
      xp.take(xidle.ok(idle, xnack.time(x), now), x, acc, c)

def xp.visit(+x: KV.XNack, w: XPw, +hi: KV.XId, +idle: XIdle, +now: Nat) -> XPw:
  match w:
    case XPw{acc, +c, False{}}:
      xp.visit.at(Cmp.is_gt(KV.xid.cmp(KV.xnack.id(x), hi)), x, acc, c, idle, now)
    case other:
      other

# a walk of the group's pending entries t from lo on (c: how lo compares
# with t's root's ID)
def xpl.walk(+t: KV.XPel, c: Cmp, w: XPw, +lo: KV.XId, +hi: KV.XId, +idle: XIdle, +now: Nat) -> XPw:
  match t c w:
    case _ _ XPw{acc, k, True{}}:
      XPw{acc, k, True{}}
    case KV.XPTip{} _ other:
      other
    case KV.XPBin{n, x, l, +r} GT{} other:
      xpl.walk(r, KV.xpl.at(r, lo), other, lo, hi, idle, now)
    case KV.XPBin{n, +x, +l, +r} _ other:
      xpl.walk(r, KV.xpl.at(r, lo), xp.visit(x, xpl.walk(l, KV.xpl.at(l, lo), other, lo, hi, idle, now), hi, idle, now), lo, hi, idle, now)

# a consumer's pending ID, its entry in the group's pending entries
def xp.visit.id(m: Maybe<&2, KV.XNack>, w: XPw, +hi: KV.XId, +idle: XIdle, +now: Nat) -> XPw:
  match m:
    case Some{+x}:
      xp.visit(x, w, hi, idle, now)
    case None{}:
      w

# a walk of a consumer's pending IDs t from lo on, each found in the
# group's pending entries pel
def xis.walk(+t: KV.XIds, c: Cmp, w: XPw, +lo: KV.XId, +hi: KV.XId, +idle: XIdle, +now: Nat, +pel: KV.XPel) -> XPw:
  match t c w:
    case _ _ XPw{acc, k, True{}}:
      XPw{acc, k, True{}}
    case KV.XITip{} _ other:
      other
    case KV.XIBin{n, x, l, +r} GT{} other:
      xis.walk(r, KV.xis.at(r, lo), other, lo, hi, idle, now, pel)
    case KV.XIBin{n, +x, +l, +r} _ other:
      xis.walk(r, KV.xis.at(r, lo), xp.visit.id(KV.xpl.find(pel, KV.xpl.at(pel, x), x), xis.walk(l, KV.xis.at(l, lo), other, lo, hi, idle, now, pel), hi, idle, now), lo, hi, idle, now, pel)

def xp.taken(w: XPw) -> List<&2, KV.XNack>:
  match w:
    case XPw{acc, c, e}:
      List.reverse(&2, KV.XNack, acc)

# the pending entries of a group, or of one of its consumers' (ids), from
# lo to hi, at most c of them (none for 0), passing those idle less than
# idle's time at now
def xs.pending(+pel: KV.XPel, m: Maybe<&2, KV.XIds>, +lo: KV.XId, +hi: KV.XId, +c: Nat, +idle: XIdle, +now: Nat) -> List<&2, KV.XNack>:
  match m:
    case Some{+ids}:
      xp.taken(xis.walk(ids, KV.xis.at(ids, lo), XPw{Nil{}, c, Nat.is_eq(c, 0n)}, lo, hi, idle, now, pel))
    case None{}:
      xp.taken(xpl.walk(pel, KV.xpl.at(pel, lo), XPw{Nil{}, c, Nat.is_eq(c, 0n)}, lo, hi, idle, now))

# the first and the last pending ID
def xpl.first(+t: KV.XPel, best: Maybe<&2, KV.XId>) -> Maybe<&2, KV.XId>:
  match t:
    case KV.XPTip{}:
      best
    case KV.XPBin{n, +x, +l, r}:
      xpl.first(l, Some{KV.xnack.id(x)})

def xpl.last(+t: KV.XPel, best: Maybe<&2, KV.XId>) -> Maybe<&2, KV.XId>:
  match t:
    case KV.XPTip{}:
      best
    case KV.XPBin{n, +x, l, +r}:
      xpl.last(r, Some{KV.xnack.id(x)})

def xcs.keep(none: Bool, +x: KV.XCon, acc: List<&2, KV.XCon>) -> List<&2, KV.XCon>:
  match none:
    case True{}:
      acc
    case False{}:
      x <> acc

# a group's consumers with pending entries, in name order
def xcs.pending(cs: List<&2, KV.XCon>, acc: List<&2, KV.XCon>) -> List<&2, KV.XCon>:
  match cs:
    case Con{+x, rest}:
      xcs.pending(rest, xcs.keep(Nat.is_eq(xcon.nids(x), 0n), x, acc))
    case Nil{}:
      List.reverse(&2, KV.XCon, acc)

# Writes
# ------
# XADD, XTRIM, XDEL and XSETID change a stream as Redis 7.0.15 changes it
# (t_stream.c: streamAppendItem, streamTrim, streamDeleteItem and
# streamIteratorRemoveEntry), node for node and byte for byte: an entry
# is made as lpAppendInteger and lpAppend make its elements, and each
# node's counts and sizes follow. The node limits are Redis's defaults,
# 4096 bytes and 100 entries: stream-node-max-bytes and
# stream-node-max-entries are not read, as a write of one key runs on
# its database alone (and a file replays alike whatever they are).

def xs.empty() -> KV.XStream:
  KV.XStr{0n, xid.zero(), xid.zero(), xid.zero(), xn.zero(), KV.XNTip{}, KV.XGTip{}}

# whether the stream holds the last ID there is, past which XADD adds
# none
# (x matched first, as in xn.is_max)
def xs.exhausted(+x: KV.XStream) -> Bool:
  match x:
    case KV.XStr{n, +last, first, maxdel, added, nodes, groups}:
      match last:
        case KV.XId{+ms, +sq}:
          Bool.and(xn.is_max(ms), xn.is_max(sq))
    case KV.XStrOf{+y}:
      xs.exhausted(y)

# the char at i ends a C string: a NUL, or the end
def su.cend(+s: String, +i: Nat) -> Bool:
  +c = String.code_at(s, i)
  Bool.or(U32.is_eq(c, 0), U32.is_eq(c, 4294967295))

# XADD's ID word (streamParseStrictIDOrReply with seq_given): an ID, or
# <ms>-*, whose sequence the stream gives, or none ("*" alone is XADD's
# option loop's)
type XIdP is Data:
  XIdPBad{}
  XIdPSeq{ms: KV.XN}
  XIdPAt{id: KV.XId}

def xid.seq.of(m: Maybe<&2, KV.XN>) -> XIdP:
  match m:
    case Some{ms}:
      XIdPSeq{ms}
    case None{}:
      XIdPBad{}

def xid.at.of(m: Maybe<&2, KV.XId>) -> XIdP:
  match m:
    case Some{id}:
      XIdPAt{id}
    case None{}:
      XIdPBad{}

def xid.add.text(star: Bool, +b: String, +dot: Nat, +s: String) -> XIdP:
  match star:
    case True{}:
      xid.seq.of(su.ull(String.take(b, dot)))
    case False{}:
      xid.at.of(xid.parse(s, True{}, xn.zero()))

def xid.parse.add.if(long: Bool, +s: String) -> XIdP:
  match long:
    case True{}:
      XIdPBad{}
    case False{}:
      +b = String.take(s, String.find(s, Chr{0}, 0n))
      +n = String.length(b)
      +dot = String.find(b, Chr{45}, 0n)
      +lone = Bool.and(Nat.is_eq(n, 1n), Bool.or(U32.is_eq(String.code_at(b, 0n), 45), U32.is_eq(String.code_at(b, 0n), 43)))
      xid.add.text(Bool.and(Bool.not(lone), Bool.and(Nat.is_lt(dot, n), String.eq(String.drop(b, Nat.add(dot, 1n)), "*"))), b, dot, s)

def xid.parse.add(+s: String) -> XIdP:
  xid.parse.add.if(Nat.is_lt(127n, String.length(s)), s)

# Entries
# -------

# an integer's listpack entry, with its backlen, before rest
def xe.int(+n: Nat, rest: String) -> String:
  +k = D.lp.icls(False{}, n)
  D.lp.int(k, False{}, n, D.lp.back(D.lp.isize(k), rest))

# its size
def xe.isz(+n: Nat) -> Nat:
  Nat.add(D.lp.isize(D.lp.icls(False{}, n)), 1n)

# the values of fields and values fv, in turn, before rest
def xe.vals(fv: List<&2, String>, rest: String) -> String:
  match fv:
    case Con{f, Con{+v, more}}:
      D.lp.ent(v, xe.vals(more, rest))
    case _:
      rest

def xe.put.body(same: Bool, +nf: Nat, fv: List<&2, String>, rest: String) -> String:
  match same:
    case True{}:
      xe.vals(fv, rest)
    case False{}:
      xe.int(nf, D.lp.ents(fv, rest))

# an entry's count of elements before its last (lp-count)
def xe.lpc(+same: Bool, +nf: Nat) -> Nat:
  Bool.pick(Nat, same, Nat.add(nf, 3n), Nat.add(Nat.mul(2n, nf), 4n))

# the bytes of the entry of ID id, of the nf pairs of fields and values
# fv, in a node of master ID mid: its flags (SAMEFIELDS, 2, when same),
# its ID's differences from mid (id - mid, each a long long), its fields
# and values after their count, or with same its values alone, then its
# lp-count
def xe.make(+same: Bool, +id: KV.XId, +mid: KV.XId, +nf: Nat, fv: List<&2, String>) -> String:
  match id mid:
    case KV.XId{+ms, +sq} KV.XId{+mms, +msq}:
      xe.int(Bool.pick(Nat, same, 2n, 0n), D.lp.ent(xn.show.ll(xn.sub(ms, mms)), D.lp.ent(xn.show.ll(xn.sub(sq, msq)), xe.put.body(same, nf, fv, xe.int(xe.lpc(same, nf), "")))))

# the fields of fields and values fv
def xe.fields(fv: List<&2, String>) -> List<&2, String>:
  match fv:
    case Con{+f, Con{v, more}}:
      f <> xe.fields(more)
    case _:
      Nil{}

# whether the fields of fv are the master's, mfs, in order, byte for byte
def xe.same(mfs: List<&2, String>, fv: List<&2, String>) -> Bool:
  match mfs fv:
    case Nil{} Nil{}:
      True{}
    case Con{+m, mr} Con{+f, Con{v, fr}}:
      Bool.and(String.eq(m, f), xe.same(mr, fr))
    case _ _:
      False{}

# the bytes of fields and values fv, as streamAppendItem counts them
def xe.tot(fv: List<&2, String>, +acc: Nat) -> Nat:
  match fv:
    case Con{+s, rest}:
      xe.tot(rest, Nat.add(acc, String.length(s)))
    case Nil{}:
      acc

def xe.fsz(fs: List<&2, String>, +acc: Nat) -> Nat:
  match fs:
    case Con{+f, rest}:
      xe.fsz(rest, Nat.add(acc, D.lp.esize(f)))
    case Nil{}:
      acc

# the size of a node's master entry: its counts of live and deleted
# entries, its fields after their count, and its 0
def xm.size(+live: Nat, +dead: Nat, +nf: Nat, mfs: List<&2, String>) -> Nat:
  Nat.add(Nat.add(xe.isz(live), xe.isz(dead)), Nat.add(Nat.add(xe.isz(nf), xe.fsz(mfs, 0n)), 2n))

# a node's listpack once its counts of live and deleted entries go from
# live and dead to l2 and d2, each written again in its own size
def xnd.resize(+bytes: Nat, +live: Nat, +dead: Nat, +l2: Nat, +d2: Nat) -> Nat:
  Nat.sub(Nat.add(Nat.add(bytes, xe.isz(l2)), xe.isz(d2)), Nat.add(xe.isz(live), xe.isz(dead)))

# an entry marked deleted: its flags (one byte below 128, not deleted)
# with bit 1 set
def xe.mark(+e: String) -> String:
  D.b1(U32.add(String.code_at(e, 0n), 1)) ++ String.drop(e, 1n)

# Nodes written
# -------------

def xnode.live(+x: KV.XNode) -> Nat:
  match x:
    case KV.XNd{mid, mfs, +live, dead, bytes, nel, es}:
      live
    case KV.XNdOf{+y}:
      xnode.live(y)

def xh.id.or(h: XEh, +d: KV.XId) -> KV.XId:
  match h:
    case XEh{fl, +id, off}:
      id
    case XEhBad{}:
      d

def xnode.last.of(es: List<&2, String>, +mid: KV.XId) -> KV.XId:
  match es:
    case Con{+e, rest}:
      xh.id.or(xh.read(e, mid), mid)
    case Nil{}:
      mid

# a node's last entry's ID, a deleted one too (lpGetEdgeStreamID)
def xnode.last(+x: KV.XNode) -> KV.XId:
  match x:
    case KV.XNd{+mid, mfs, live, dead, bytes, nel, es}:
      xnode.last.of(es, mid)
    case KV.XNdOf{+y}:
      xnode.last(y)

def xnode.oldest.of(es: List<&2, String>, +mid: KV.XId) -> KV.XId:
  match es:
    case Con{+e, Nil{}}:
      xh.id.or(xh.read(e, mid), mid)
    case Con{e, rest}:
      xnode.oldest.of(rest, mid)
    case Nil{}:
      mid

# a node's first entry's ID, a deleted one too
def xnode.oldest(+x: KV.XNode) -> KV.XId:
  match x:
    case KV.XNd{+mid, mfs, live, dead, bytes, nel, es}:
      xnode.oldest.of(es, mid)
    case KV.XNdOf{+y}:
      xnode.oldest(y)

# a new node for the entry of ID id (its master ID), of the nf pairs fv:
# its master entry of fv's fields, the entry with SAMEFIELDS
def xnode.new(+id: KV.XId, +fv: List<&2, String>, +nf: Nat) -> KV.XNode:
  +mfs = xe.fields(fv)
  +e = xe.make(True{}, id, id, nf, fv)
  KV.XNd{id, mfs, 1n, 0n, Nat.add(Nat.add(xm.size(1n, 0n, nf, mfs), String.length(e)), 7n), Nat.mul(2n, Nat.add(nf, 4n)), [e]}

# the node x with the entry of ID id after its others
def xnode.add(+x: KV.XNode, +id: KV.XId, +fv: List<&2, String>, +nf: Nat) -> KV.XNode:
  match x:
    case KV.XNd{+mid, +mfs, +live, dead, bytes, nel, es}:
      +same = xe.same(mfs, fv)
      +e = xe.make(same, id, mid, nf, fv)
      +l2 = Nat.add(live, 1n)
      KV.XNd{mid, mfs, l2, dead, Nat.add(Nat.sub(Nat.add(bytes, xe.isz(l2)), xe.isz(live)), String.length(e)), Nat.add(nel, Nat.add(xe.lpc(same, nf), 1n)), e <> es}
    case KV.XNdOf{+y}:
      xnode.add(y, id, fv, nf)

# whether XADD puts its entry in a new node after the last one x: x's
# listpack and the entry's fields and values reach 4096 bytes, or x
# holds 100 entries, live and deleted
def xnode.full(+x: KV.XNode, +tot: Nat) -> Bool:
  match x:
    case KV.XNd{mid, mfs, +live, +dead, +bytes, nel, es}:
      Bool.or(Nat.is_le(4096n, Nat.add(bytes, tot)), Nat.is_le(100n, Nat.add(live, dead)))
    case KV.XNdOf{+y}:
      xnode.full(y, tot)

# a new node put in the tree, in the place of one of its master ID if the
# tree has one (raxInsert replaces it)
def xns.add.new.of(m: Maybe<&2, KV.XNode>, +x: KV.XNode, +t: KV.XNodes) -> KV.XNodes:
  match m:
    case Some{y}:
      KV.xns.set(x, t)
    case None{}:
      KV.xns.put(x, t)

def xns.add.new(+t: KV.XNodes, +id: KV.XId, +fv: List<&2, String>, +nf: Nat) -> KV.XNodes:
  xns.add.new.of(KV.xns.find(t, KV.xns.at(t, id), id), xnode.new(id, fv, nf), t)

def xns.add.to(full: Bool, +last: KV.XNode, +t: KV.XNodes, +id: KV.XId, +fv: List<&2, String>, +nf: Nat) -> KV.XNodes:
  match full:
    case True{}:
      xns.add.new(t, id, fv, nf)
    case False{}:
      KV.xns.set(xnode.add(last, id, fv, nf), t)

def xns.add.at(none: Bool, +t: KV.XNodes, +n: Nat, +id: KV.XId, +fv: List<&2, String>, +nf: Nat, +tot: Nat) -> KV.XNodes:
  match none:
    case True{}:
      xns.add.new(t, id, fv, nf)
    case False{}:
      +last = xns.nth(t, Nat.sub(n, 1n))
      xns.add.to(xnode.full(last, tot), last, t, id, fv, nf)

# the nodes with the entry of ID id added to the last (the one of the
# greatest master ID), or to a new one after it
def xns.add(+t: KV.XNodes, +id: KV.XId, +fv: List<&2, String>, +nf: Nat, +tot: Nat) -> KV.XNodes:
  +n = KV.xns.size(t)
  xns.add.at(Nat.is_eq(n, 0n), t, n, id, fv, nf, tot)

# the stream with the entry of ID id (past its last) of the nf pairs fv
# (tot bytes) added (streamAppendItem, its checks made)
def xs.add(+x: KV.XStream, +id: KV.XId, +fv: List<&2, String>, +nf: Nat, +tot: Nat) -> KV.XStream:
  match x:
    case KV.XStr{+n, last, +first, maxdel, +added, +nodes, groups}:
      KV.XStr{Nat.add(n, 1n), id, Bool.pick(KV.XId, Nat.is_eq(n, 0n), id, first), maxdel, KV.xn.add(added, xn.one()), xns.add(nodes, id, fv, nf, tot), groups}
    case KV.XStrOf{+y}:
      xs.add(y, id, fv, nf, tot)

def xs.with.first(+x: KV.XStream, +f: KV.XId) -> KV.XStream:
  match x:
    case KV.XStr{n, last, first, maxdel, added, nodes, groups}:
      KV.XStr{n, last, f, maxdel, added, nodes, groups}
    case KV.XStrOf{+y}:
      xs.with.first(y, f)

def xs.head.of(es: List<&2, XE>) -> KV.XId:
  match es:
    case Con{XE{id, fv}, rest}:
      id
    case Nil{}:
      xid.zero()

# the first live entry's ID (streamGetEdgeID, its tombstones passed), 0-0
# for none (x matched first, as in xn.is_max)
def xs.head(+x: KV.XStream) -> KV.XId:
  match x:
    case KV.XStr{+n, +last, +first, +maxdel, +added, +nodes, +groups}:
      xs.head.of(xs.walk(KV.XStr{n, last, first, maxdel, added, nodes, groups}, xid.zero(), xid.max(), 1n, False{}, True{}))
    case KV.XStrOf{+y}:
      xs.head(y)

# a stream's first ID after a write that deleted (changed) entries: 0-0
# when none is left (empty), the first live entry's
def xs.first.fix(empty: Bool, changed: Bool, +x: KV.XStream) -> KV.XStream:
  match empty changed:
    case True{} _:
      xs.with.first(x, xid.zero())
    case False{} True{}:
      xs.with.first(x, xs.head(x))
    case False{} False{}:
      x

# Trims
# -----
# streamTrim: from the first node, a node is taken out whole while the
# stream keeps maxlen entries without its live ones (MAXLEN), or while
# its last entry, a deleted one too, is below minid (MINID); MAXLEN stops
# once the stream is at maxlen. ~ stops at the first node it cannot take
# out whole, and also once a node's live entries would take it past its
# limit; else the first node left has its entries from its oldest marked
# deleted while the stream is past maxlen, or up to the first at or past
# minid. The first ID is then the first live entry's, 0-0 for none.

# a trim's strategy: MAXLEN of n, or MINID of id
type XTs is Data:
  XTMax{n: Nat}
  XTMin{id: KV.XId}

# a trim's walk: the nodes left, the stream's length, the entries deleted
type XTw is Data:
  XTw{t: KV.XNodes, len: Nat, del: Nat}

# a step of it: the walk goes on, or is done
type XTn is Data:
  XTMore{w: XTw}
  XTDone{w: XTw}

def xt.done(+s: XTs, +len: Nat) -> Bool:
  match s:
    case XTMax{+n}:
      Nat.is_le(len, n)
    case XTMin{id}:
      False{}

def xt.whole(+s: XTs, +x: KV.XNode, +len: Nat, +e: Nat) -> Bool:
  match s:
    case XTMax{+n}:
      Nat.is_le(n, Nat.sub(len, e))
    case XTMin{+id}:
      Cmp.is_lt(KV.xid.cmp(xnode.last(x), id))

# what the trim does with the node x (e live entries): stop (0), take it
# out (1), or mark its entries (2)
def xt.what(+s: XTs, +ap: Bool, +lim: Nat, +x: KV.XNode, +len: Nat, +del: Nat, +e: Nat) -> Nat:
  Bool.pick(Nat, Bool.or(xt.done(s, len), Bool.and(Nat.is_lt(0n, lim), Nat.is_lt(lim, Nat.add(del, e)))), 0n, Bool.pick(Nat, xt.whole(s, x, len, e), 1n, Bool.pick(Nat, ap, 0n, 2n)))

# the partial trim's walk of a node's entries from its oldest: those
# walked (the newest first), the stream's length, how many it marked,
# whether it stopped
type XMk is Data:
  XMk{acc: List<&2, String>, len: Nat, n: Nat, stop: Bool}

# whether the partial trim stops at the entry of ID id
def xt.stop(+s: XTs, +len: Nat, +id: KV.XId) -> Bool:
  match s:
    case XTMax{+n}:
      Nat.is_le(len, n)
    case XTMin{+m}:
      Bool.not(Cmp.is_lt(KV.xid.cmp(id, m)))

def xt.mark.if(del: Bool, +e: String, +len: Nat, +n: Nat, acc: List<&2, String>) -> XMk:
  match del:
    case True{}:
      XMk{e <> acc, len, n, False{}}
    case False{}:
      XMk{xe.mark(e) <> acc, Nat.sub(len, 1n), Nat.add(n, 1n), False{}}

def xt.part.at(stop: Bool, +e: String, +fl: Nat, +len: Nat, +n: Nat, acc: List<&2, String>) -> XMk:
  match stop:
    case True{}:
      XMk{e <> acc, len, n, True{}}
    case False{}:
      xt.mark.if(xh.deleted(fl), e, len, n, acc)

def xt.part.one(h: XEh, +e: String, +s: XTs, +len: Nat, +n: Nat, acc: List<&2, String>) -> XMk:
  match h:
    case XEh{+fl, +id, off}:
      xt.part.at(xt.stop(s, len, id), e, fl, len, n, acc)
    case XEhBad{}:
      XMk{e <> acc, len, n, True{}}

# the walk through es (the oldest first); once stopped, the rest as it is
def xt.part.go(es: List<&2, String>, +s: XTs, +mid: KV.XId, w: XMk) -> XMk:
  match es w:
    case Con{+e, rest} XMk{acc, +len, +n, False{}}:
      xt.part.go(rest, s, mid, xt.part.one(xh.read(e, mid), e, s, len, n, acc))
    case more XMk{acc, len, n, True{}}:
      XMk{List.reverse.go(&2, String, more, acc), len, n, True{}}
    case Nil{} w0:
      w0

def xt.part.fin(m: XMk, +mid: KV.XId, mfs: List<&2, String>, +live: Nat, +dead: Nat, +bytes: Nat, +nel: Nat, +t: KV.XNodes, +del: Nat) -> XTw:
  match m:
    case XMk{acc, +len, +n, stop}:
      +l2 = Nat.sub(live, n)
      +d2 = Nat.add(dead, n)
      XTw{KV.xns.set(KV.XNd{mid, mfs, l2, d2, xnd.resize(bytes, live, dead, l2, d2), nel, acc}, t), len, Nat.add(del, n)}

# the first node x left, its entries marked from its oldest
def xt.part(+s: XTs, +x: KV.XNode, +t: KV.XNodes, +len: Nat, +del: Nat) -> XTw:
  match x:
    case KV.XNd{+mid, mfs, +live, +dead, +bytes, +nel, es}:
      xt.part.fin(xt.part.go(List.reverse(&2, String, es), s, mid, XMk{Nil{}, len, 0n, False{}}), mid, mfs, live, dead, bytes, nel, t, del)
    case KV.XNdOf{+y}:
      xt.part(s, y, t, len, del)

def xt.step.of(c: Nat, +s: XTs, +x: KV.XNode, +t: KV.XNodes, +len: Nat, +del: Nat, +e: Nat) -> XTn:
  match c:
    case 1n:
      XTMore{XTw{KV.xns.del(KV.xnode.mid(x), t), Nat.sub(len, e), Nat.add(del, e)}}
    case 2n:
      XTDone{xt.part(s, x, t, len, del)}
    case _:
      XTDone{XTw{t, len, del}}

def xt.step(+s: XTs, +ap: Bool, +lim: Nat, +x: KV.XNode, +t: KV.XNodes, +len: Nat, +del: Nat) -> XTn:
  +e = xnode.live(x)
  xt.step.of(xt.what(s, ap, lim, x, len, del, e), s, x, t, len, del, e)

# k more nodes at most
def xt.go(k: Nat, w: XTn, +s: XTs, +ap: Bool, +lim: Nat) -> XTw:
  match k w:
    case 1n+j XTMore{XTw{+t, +len, +del}}:
      xt.go(j, xt.step(s, ap, lim, xns.nth(t, 0n), t, len, del), s, ap, lim)
    case _ XTMore{w0}:
      w0
    case _ XTDone{w0}:
      w0

# a stream trimmed, and how many entries it deleted
type XTrd is Data:
  XTrd{x: KV.XStream, del: Nat}

def xs.trim.fin(w: XTw, +last: KV.XId, +first: KV.XId, +maxdel: KV.XId, +added: KV.XN, +groups: KV.XGroups) -> XTrd:
  match w:
    case XTw{t, +len, +del}:
      XTrd{xs.first.fix(Nat.is_eq(len, 0n), Nat.is_lt(0n, del), KV.XStr{len, last, first, maxdel, added, t, groups}), del}

# the stream x trimmed (ap: by whole nodes, at most lim entries, 0 for
# no limit)
def xs.trim(+x: KV.XStream, +s: XTs, +ap: Bool, +lim: Nat) -> XTrd:
  match x:
    case KV.XStr{+n, +last, +first, +maxdel, +added, +nodes, +groups}:
      xs.trim.fin(xt.go(KV.xns.size(nodes), XTMore{XTw{nodes, n, 0n}}, s, ap, lim), last, first, maxdel, added, groups)
    case KV.XStrOf{+y}:
      xs.trim(y, s, ap, lim)

# An approximate trim (~) as an exact one. Redis propagates it as the
# exact trim at the threshold it reached (MAXLEN: the stream's length
# after it; MINID: the first entry of the first node it kept, a deleted
# one too, or the last ID there is when it kept none), which a replica
# runs. BendKV runs it as that exact trim, which takes out the same
# nodes but in two cases: a stream whose entries are out of order across
# its nodes (after XSETID below them) for MINID, and one whose last node
# taken out holds no live entry for MAXLEN. There the other kind's
# threshold is taken when it takes out the same nodes, else Redis's.

# the approximate trim's walk: the nodes it takes out (the first i), the
# stream's length after them, the entries they held
type XAp is Data:
  XAp{i: Nat, len: Nat, del: Nat}

def xa.next(ok: Bool, +i: Nat, +len: Nat, +del: Nat, +e: Nat) -> XAp:
  match ok:
    case True{}:
      XAp{Nat.add(i, 1n), Nat.sub(len, e), Nat.add(del, e)}
    case False{}:
      XAp{i, len, del}

def xa.ok(+s: XTs, +lim: Nat, +x: KV.XNode, +len: Nat, +del: Nat, +e: Nat) -> Bool:
  Bool.and(Bool.not(Bool.or(xt.done(s, len), Bool.and(Nat.is_lt(0n, lim), Nat.is_lt(lim, Nat.add(del, e))))), xt.whole(s, x, len, e))

def xa.go(k: Nat, go: Bool, +t: KV.XNodes, +s: XTs, +lim: Nat, w: XAp) -> XAp:
  match k go w:
    case 1n+j True{} XAp{+i, +len, +del}:
      +x = xns.nth(t, i)
      +e = xnode.live(x)
      +ok = xa.ok(s, lim, x, len, del, e)
      xa.go(j, ok, t, s, lim, xa.next(ok, i, len, del, e))
    case _ _ other:
      other

# whether the first k nodes from place i each end below f
def xa.below(k: Nat, +t: KV.XNodes, +i: Nat, +f: KV.XId) -> Bool:
  match k:
    case 0n:
      True{}
    case 1n+j:
      Bool.and(Cmp.is_lt(KV.xid.cmp(xnode.last(xns.nth(t, i)), f)), xa.below(j, t, Nat.add(i, 1n), f))

def xs.approx.pick(s: XTs, +mx: Bool, +mn: Bool, +len: Nat, +f: KV.XId) -> XTs:
  match s:
    case XTMax{n}:
      Bool.pick(XTs, Bool.or(mx, Bool.not(mn)), XTMax{len}, XTMin{f})
    case XTMin{m}:
      Bool.pick(XTs, Bool.or(mn, Bool.not(mx)), XTMin{f}, XTMax{len})

def xs.approx.of(a: XAp, +s: XTs, +t: KV.XNodes, +c: Nat) -> XTs:
  match a:
    case XAp{+k, +len, del}:
      +f = Bool.pick(KV.XId, Nat.is_lt(k, c), xnode.oldest(xns.nth(t, k)), xid.max())
      +mx = Bool.or(Nat.is_eq(k, 0n), Nat.is_lt(0n, xnode.live(xns.nth(t, Nat.sub(k, 1n)))))
      +mn = Bool.and(xa.below(k, t, 0n, f), Bool.or(Nat.is_eq(k, c), Bool.not(Cmp.is_lt(KV.xid.cmp(xnode.last(xns.nth(t, k)), f)))))
      xs.approx.pick(s, mx, mn, len, f)

# the exact trim that runs the approximate one of strategy s and limit
# lim on x
def xs.approx(+x: KV.XStream, +s: XTs, +lim: Nat) -> XTs:
  +t = xstream.nodes(x)
  +c = KV.xns.size(t)
  xs.approx.of(xa.go(c, True{}, t, s, lim, XAp{0n, KV.xstream.len(x), 0n}), s, t, c)

# Deletes
# -------
# XDEL of an ID: the live entry of that ID, as streamIteratorGetID's walk
# from it to it finds it (from the last node whose master ID is at most
# it, else the first, through the nodes after it: entries deleted or
# below it passed, the walk over at one past it), marked deleted; its
# node taken out instead when it was the node's last live entry (with
# its deleted ones). XDEL then raises the greatest ID deleted, and the
# first ID is the first live entry's when the first went.

# a node's walk: the entry found and marked (its node's entries, the
# newest first), passed (none in the node), or stopped (none there)
type XDn is Data:
  XDnHit{es: List<&2, String>}
  XDnPass{}
  XDnStop{}

def xd.what.h(h: XEh, +id: KV.XId) -> Nat:
  match h:
    case XEh{+fl, +eid, off}:
      +c = KV.xid.cmp(eid, id)
      Bool.pick(Nat, Bool.or(xh.deleted(fl), Cmp.is_lt(c)), 0n, Bool.pick(Nat, Cmp.is_eq(c), 1n, 2n))
    case XEhBad{}:
      2n

# what the walk does with the first of es (the oldest first): pass it
# (0), mark it (1), or stop (2)
def xd.what(+es: List<&2, String>, +mid: KV.XId, +id: KV.XId) -> Nat:
  match es:
    case Con{+e, rest}:
      xd.what.h(xh.read(e, mid), id)
    case Nil{}:
      0n

def xd.go(es: List<&2, String>, c: Nat, +mid: KV.XId, +id: KV.XId, acc: List<&2, String>) -> XDn:
  match es c:
    case Con{+e, +rest} 0n:
      xd.go(rest, xd.what(rest, mid, id), mid, id, e <> acc)
    case Con{+e, rest} 1n:
      XDnHit{List.reverse.go(&2, String, rest, xe.mark(e) <> acc)}
    case Con{e, rest} _:
      XDnStop{}
    case Nil{} _:
      XDnPass{}

def xd.node(+x: KV.XNode, +id: KV.XId) -> XDn:
  match x:
    case KV.XNd{+mid, mfs, live, dead, bytes, nel, es}:
      +old = List.reverse(&2, String, es)
      xd.go(old, xd.what(old, mid, id), mid, id, Nil{})
    case KV.XNdOf{+y}:
      xd.node(y, id)

# where XDEL finds an ID: the node's place and its entries after the
# mark, or none
type XDf is Data:
  XDfHit{i: Nat, es: List<&2, String>}
  XDfMiss{}

def xd.find(k: Nat, r: XDn, +t: KV.XNodes, +i: Nat, +id: KV.XId) -> XDf:
  match k r:
    case 1n+j XDnPass{}:
      xd.find(j, xd.node(xns.nth(t, i), id), t, Nat.add(i, 1n), id)
    case _ XDnHit{es}:
      XDfHit{Nat.sub(i, 1n), es}
    case _ _:
      XDfMiss{}

# the nodes with the entry marked in the node x, or x taken out when the
# entry was its last live one
def xd.mark.of(one: Bool, +x: KV.XNode, es: List<&2, String>, +t: KV.XNodes) -> KV.XNodes:
  match one x:
    case True{} y:
      KV.xns.del(KV.xnode.mid(y), t)
    case False{} KV.XNd{+mid, mfs, +live, +dead, +bytes, nel, old}:
      +l2 = Nat.sub(live, 1n)
      +d2 = Nat.add(dead, 1n)
      KV.xns.set(KV.XNd{mid, mfs, l2, d2, xnd.resize(bytes, live, dead, l2, d2), nel, es}, t)
    case False{} KV.XNdOf{y}:
      t

# XDEL's walk of its IDs: the stream, how many it deleted, whether the
# stream's first entry went
type XDs is Data:
  XDs{x: KV.XStream, n: Nat, first: Bool}

def xd.hit(f: XDf, +id: KV.XId, +x: KV.XStream, +n: Nat, +first: Bool) -> XDs:
  match f x:
    case XDfHit{+i, es} KV.XStr{+len, last, +fid, +maxdel, added, +nodes, groups}:
      +y = xns.nth(nodes, i)
      XDs{KV.XStr{Nat.sub(len, 1n), last, fid, Bool.pick(KV.XId, Cmp.is_gt(KV.xid.cmp(id, maxdel)), id, maxdel), added, xd.mark.of(Nat.is_eq(xnode.live(y), 1n), y, es, nodes), groups}, Nat.add(n, 1n), Bool.or(first, xid.is_eq(id, fid))}
    case _ y:
      XDs{y, n, first}

# the live entry of ID id in x, where XDEL finds it
def xd.one(+x: KV.XStream, +id: KV.XId) -> XDf:
  +t = xstream.nodes(x)
  +i = xw.at(t, False{}, id, id)
  xd.find(Nat.sub(KV.xns.size(t), i), XDnPass{}, t, i, id)

def xd.all(ids: List<&2, KV.XId>, s: XDs) -> XDs:
  match ids s:
    case Con{+id, rest} XDs{+x, +n, +first}:
      xd.all(rest, xd.hit(xd.one(x, id), id, x, n, first))
    case Nil{} s0:
      s0

# XDEL's stream after it, and how many entries it deleted
type XDr is Data:
  XDr{x: KV.XStream, n: Nat}

def xs.del.fin(s: XDs) -> XDr:
  match s:
    case XDs{+x, +n, first}:
      +some = Nat.is_lt(0n, n)
      XDr{xs.first.fix(Bool.and(some, Nat.is_eq(KV.xstream.len(x), 0n)), Bool.and(some, first), x), n}

# XDEL of the IDs ids, in turn
def xs.del(+x: KV.XStream, ids: List<&2, KV.XId>) -> XDr:
  xs.del.fin(xd.all(ids, XDs{x, 0n, False{}}))

# the IDs ws name, each read as a strict ID, or none when one is not one
def xids.head(+ws: List<&2, String>) -> Maybe<&2, KV.XId>:
  match ws:
    case Con{+w, rest}:
      xid.parse(w, True{}, xn.zero())
    case Nil{}:
      Some{xid.zero()}

def xids.go(ws: List<&2, String>, m: Maybe<&2, KV.XId>, acc: List<&2, KV.XId>) -> Maybe<&2, List<&2, KV.XId>>:
  match ws m:
    case Nil{} _:
      Some{List.reverse(&2, KV.XId, acc)}
    case Con{w, +rest} Some{+id}:
      xids.go(rest, xids.head(rest), id <> acc)
    case Con{w, rest} None{}:
      None{}

def xids.parse(+ws: List<&2, String>) -> Maybe<&2, List<&2, KV.XId>>:
  xids.go(ws, xids.head(ws), Nil{})

# Groups' writes
# --------------
# What XGROUP, XACK, XCLAIM, XAUTOCLAIM and XREADGROUP do to a stream's
# groups, as Redis 7.2.16's t_stream.c does it (streamCreateCG,
# streamCreateConsumer, streamDelConsumer, xackCommand, xclaimCommand,
# xautoclaimCommand, streamReplyWithRange,
# streamReplyWithRangeFromConsumerPEL): a group's pending entries and the
# IDs each consumer holds of them change together, an entry given to a
# consumer leaving the IDs of the one that held it.

def xs.groups.set(+x: KV.XStream, gs: KV.XGroups) -> KV.XStream:
  match x:
    case KV.XStr{n, last, first, maxdel, added, nodes, groups}:
      KV.XStr{n, last, first, maxdel, added, nodes, gs}
    case KV.XStrOf{+y}:
      xs.groups.set(y, gs)

def xs.gput.of(m: Maybe<&2, KV.XGroup>, +g: KV.XGroup, +gs: KV.XGroups) -> KV.XGroups:
  match m:
    case Some{h}:
      KV.xgs.set(g, gs)
    case None{}:
      KV.xgs.put(g, gs)

# x with the group g in place of its group of g's name, or added
def xs.group.put(+x: KV.XStream, +g: KV.XGroup) -> KV.XStream:
  +gs = xstream.groups(x)
  +name = KV.xgroup.name(g)
  xs.groups.set(x, xs.gput.of(KV.xgs.find(gs, KV.xgs.at(gs, name), name), g, gs))

def xgroup.mk(+g: KV.XGroup, +last: KV.XId, rd: KV.XRd, pel: KV.XPel, cons: KV.XCons) -> KV.XGroup:
  KV.XGrp{KV.xgroup.name(g), last, rd, pel, cons}

def xcon.ids.set(+c: KV.XCon, ids: KV.XIds) -> KV.XCon:
  match c:
    case KV.XCon{+name, +seen, active, x}:
      KV.XCon{name, seen, active, ids}

def xcon.times(+c: KV.XCon, +seen: Nat, act: KV.XAct) -> KV.XCon:
  match c:
    case KV.XCon{+name, s, a, +ids}:
      KV.XCon{name, seen, act, ids}

# whether the stream holds a live entry of the ID (streamEntryExists)
def xs.has.of(es: List<&2, XE>) -> Bool:
  match es:
    case Con{e, rest}:
      True{}
    case Nil{}:
      False{}

def xs.has(+x: KV.XStream, +id: KV.XId) -> Bool:
  xs.has.of(xs.walk(x, id, id, 1n, False{}, True{}))

# a consumer's IDs with id among them
def xis.add.of(m: Maybe<&2, KV.XId>, +id: KV.XId, +ids: KV.XIds) -> KV.XIds:
  match m:
    case Some{y}:
      ids
    case None{}:
      KV.xis.put(id, ids)

def xis.add(+id: KV.XId, +ids: KV.XIds) -> KV.XIds:
  xis.add.of(KV.xis.find(ids, KV.xis.at(ids, id), id), id, ids)

# the consumers cs with id taken from (put in) the IDs of the one of the
# name, as they were when it is not there
def xcs.unown.of(m: Maybe<&2, KV.XCon>, +cs: KV.XCons, +id: KV.XId) -> KV.XCons:
  match m:
    case Some{+c}:
      KV.xcs.set(xcon.ids.set(c, KV.xis.del(id, xcon.ids(c))), cs)
    case None{}:
      cs

def xcs.unown(+cs: KV.XCons, +name: String, +id: KV.XId) -> KV.XCons:
  xcs.unown.of(KV.xcs.find(cs, KV.xcs.at(cs, name), name), cs, id)

def xcs.own.of(m: Maybe<&2, KV.XCon>, +cs: KV.XCons, +id: KV.XId) -> KV.XCons:
  match m:
    case Some{+c}:
      KV.xcs.set(xcon.ids.set(c, xis.add(id, xcon.ids(c))), cs)
    case None{}:
      cs

def xcs.own(+cs: KV.XCons, +name: String, +id: KV.XId) -> KV.XCons:
  xcs.own.of(KV.xcs.find(cs, KV.xcs.at(cs, name), name), cs, id)

def xpl.of(+g: KV.XGroup, +id: KV.XId) -> Maybe<&2, KV.XNack>:
  +pel = xgroup.pel(g)
  KV.xpl.find(pel, KV.xpl.at(pel, id), id)

# A group's writes below match the group's node once, its fields moved
# into the group they make: a group that a write made (the steps of
# XWSet's words, of XCLAIM's and of XAUTOCLAIM's) changes in place, its
# trees with it, where reading each field apart (xgroup.pel) would keep
# the trees shared with the group it read them from, and so copy each
# path a change takes, and drop the old one with the group. A group the
# stream holds is copied at its first change.

# the group without the pending entry of id, which o owns
def xg.unack.at(+g: KV.XGroup, +o: String, +id: KV.XId) -> KV.XGroup:
  match g:
    case KV.XGrp{+name, +last, rd, +pel, +cons}:
      KV.XGrp{name, last, rd, KV.xpl.del(id, pel), xcs.unown(cons, o, id)}
    case KV.XGrpOf{+y}:
      xg.unack.at(y, o, id)

# the group without the pending entry of id (an XACK, or an entry gone
# from the stream), as it was when it has none
def xg.unack.of(m: Maybe<&2, KV.XNack>, +g: KV.XGroup, +id: KV.XId) -> KV.XGroup:
  match m:
    case Some{+nk}:
      xg.unack.at(g, xnack.owner(nk), id)
    case None{}:
      g

def xg.unack(+g: KV.XGroup, +id: KV.XId) -> KV.XGroup:
  xg.unack.of(xpl.of(g, id), g, id)

# the consumers once the entry of id goes from o's IDs to c's (none
# moves when o is c)
def xcs.move(same: Bool, +cs: KV.XCons, +o: String, +c: String, +id: KV.XId) -> KV.XCons:
  match same:
    case True{}:
      cs
    case False{}:
      xcs.own(xcs.unown(cs, o, id), c, id)

# the group with the entry of id pending for consumer c (who is there),
# delivered at t, n times: moved from its owner (m: some), or made
def xg.give.at(+g: KV.XGroup, m: Maybe<&2, String>, +c: String, +id: KV.XId, +t: Nat, +n: KV.XN) -> KV.XGroup:
  match g m:
    case KV.XGrp{+name, +last, rd, +pel, +cons} Some{+o}:
      KV.XGrp{name, last, rd, KV.xpl.set(KV.XNk{id, c, t, n}, pel), xcs.move(String.eq(o, c), cons, o, c, id)}
    case KV.XGrp{+name, +last, rd, +pel, +cons} None{}:
      KV.XGrp{name, last, rd, KV.xpl.put(KV.XNk{id, c, t, n}, pel), xcs.own(cons, c, id)}
    case KV.XGrpOf{+y} m0:
      xg.give.at(y, m0, c, id, t, n)

def xg.give.of(m: Maybe<&2, KV.XNack>, +g: KV.XGroup, +c: String, +id: KV.XId, +t: Nat, +n: KV.XN) -> KV.XGroup:
  match m:
    case Some{+nk}:
      xg.give.at(g, Some{xnack.owner(nk)}, c, id, t, n)
    case None{}:
      xg.give.at(g, None{}, c, id, t, n)

def xg.give(+g: KV.XGroup, +c: String, +id: KV.XId, +t: Nat, +n: KV.XN) -> KV.XGroup:
  xg.give.of(xpl.of(g, id), g, c, id, t, n)

# The write the file logs for a group (redis.bend's XWSet): consumer c
# made, or kept, with its seen and active times; then each pending entry
# it names (id, time, count): given to c when the stream holds the
# entry, else taken away (as XCLAIM with TIME, RETRYCOUNT, FORCE and
# JUSTID does it); then the group's last ID and count of entries read
type XSn is Data:
  XSn{id: KV.XId, time: Nat, count: KV.XN}

def xg.set1.if(has: Bool, +g: KV.XGroup, +c: String, +id: KV.XId, +t: Nat, +n: KV.XN) -> KV.XGroup:
  match has:
    case True{}:
      xg.give(g, c, id, t, n)
    case False{}:
      xg.unack(g, id)

def xg.sets(ns: List<&2, XSn>, +g: KV.XGroup, +c: String, +x: KV.XStream) -> KV.XGroup:
  match ns:
    case Con{XSn{+id, +t, +n}, rest}:
      xg.sets(rest, xg.set1.if(xs.has(x, id), g, c, id, t, n), c, x)
    case Nil{}:
      g

# the group with the consumer k set (there) or put (not there)
def xg.cons.at(+g: KV.XGroup, there: Bool, +k: KV.XCon) -> KV.XGroup:
  match g there:
    case KV.XGrp{+name, +last, rd, +pel, +cons} True{}:
      KV.XGrp{name, last, rd, pel, KV.xcs.set(k, cons)}
    case KV.XGrp{+name, +last, rd, +pel, +cons} False{}:
      KV.XGrp{name, last, rd, pel, KV.xcs.put(k, cons)}
    case KV.XGrpOf{+y} t:
      xg.cons.at(y, t, k)

def xg.con.of(m: Maybe<&2, KV.XCon>, +g: KV.XGroup, +c: String, +seen: Nat, act: KV.XAct) -> KV.XGroup:
  match m:
    case Some{+k}:
      xg.cons.at(g, True{}, xcon.times(k, seen, act))
    case None{}:
      xg.cons.at(g, False{}, KV.XCon{c, seen, act, KV.XITip{}})

# the group with consumer c's times (c made when it is not there)
def xg.con(+g: KV.XGroup, +c: String, +seen: Nat, act: KV.XAct) -> KV.XGroup:
  xg.con.of(xgroup.con(g, c), g, c, seen, act)

# the group with its last ID and count of entries read
def xg.last.at(+g: KV.XGroup, +last: KV.XId, rd: KV.XRd) -> KV.XGroup:
  match g:
    case KV.XGrp{+name, l, r, +pel, +cons}:
      KV.XGrp{name, last, rd, pel, cons}
    case KV.XGrpOf{+y}:
      xg.last.at(y, last, rd)

def xg.set(+g: KV.XGroup, +c: String, +seen: Nat, act: KV.XAct, ns: List<&2, XSn>, +x: KV.XStream, +last: KV.XId, rd: KV.XRd) -> KV.XGroup:
  xg.last.at(xg.sets(ns, xg.con(g, c, seen, act), c, x), last, rd)

def xs.gset.of(m: Maybe<&2, KV.XGroup>, +x: KV.XStream, +c: String, +seen: Nat, act: KV.XAct, ns: List<&2, XSn>, +last: KV.XId, rd: KV.XRd) -> Maybe<&2, KV.XStream>:
  match m:
    case Some{+g}:
      Some{xs.group.put(x, xg.set(g, c, seen, act, ns, x, last, rd))}
    case None{}:
      None{}

# the stream after the write, none when the group is not there
def xs.gset(+x: KV.XStream, +gname: String, +c: String, +seen: Nat, act: KV.XAct, ns: List<&2, XSn>, +last: KV.XId, rd: KV.XRd) -> Maybe<&2, KV.XStream>:
  xs.gset.of(xs.group(x, gname), x, c, seen, act, ns, last, rd)

# XGROUP CREATE: a group of the name at the ID with the count of entries
# read, none when one of the name is there (BUSYGROUP)
def xs.gcreate.of(m: Maybe<&2, KV.XGroup>, +x: KV.XStream, +name: String, +id: KV.XId, rd: KV.XRd) -> Maybe<&2, KV.XStream>:
  match m:
    case Some{g}:
      None{}
    case None{}:
      Some{xs.groups.set(x, KV.xgs.put(KV.XGrp{name, id, rd, KV.XPTip{}, KV.XCTip{}}, xstream.groups(x)))}

def xs.gcreate(+x: KV.XStream, +name: String, +id: KV.XId, rd: KV.XRd) -> Maybe<&2, KV.XStream>:
  xs.gcreate.of(xs.group(x, name), x, name, id, rd)

# XGROUP SETID of the group g, which is there
def xs.gsetid(+x: KV.XStream, +g: KV.XGroup, +id: KV.XId, rd: KV.XRd) -> KV.XStream:
  xs.group.put(x, xgroup.mk(g, id, rd, xgroup.pel(g), xgroup.cons(g)))

# XGROUP DESTROY of the group of the name
def xs.gdestroy(+x: KV.XStream, +name: String) -> KV.XStream:
  xs.groups.set(x, KV.xgs.del(name, xstream.groups(x)))

def xpl.dels(ids: List<&2, KV.XId>, +pel: KV.XPel) -> KV.XPel:
  match ids:
    case Con{+id, rest}:
      xpl.dels(rest, KV.xpl.del(id, pel))
    case Nil{}:
      pel

# XGROUP DELCONSUMER of the consumer c of the group g: c gone, and its
# pending entries from the group's
def xs.gdelcon(+x: KV.XStream, +g: KV.XGroup, +c: KV.XCon) -> KV.XStream:
  xs.group.put(x, xgroup.mk(g, xgroup.last(g), xgroup.read(g), xpl.dels(KV.xis.list(xcon.ids(c), Nil{}), xgroup.pel(g)), KV.xcs.del(KV.xcon.name(c), xgroup.cons(g))))

# XACK of the IDs in turn: how many were pending, and the group after
type XAk is Data:
  XAk{n: Nat, g: KV.XGroup}

def xg.ack1.of(m: Maybe<&2, KV.XNack>, +id: KV.XId, +n: Nat, +g: KV.XGroup) -> XAk:
  match m:
    case Some{nk}:
      XAk{Nat.add(n, 1n), xg.unack(g, id)}
    case None{}:
      XAk{n, g}

def xg.ack(ids: List<&2, KV.XId>, a: XAk) -> XAk:
  match ids a:
    case Con{+id, rest} XAk{+n, +g}:
      xg.ack(rest, xg.ack1.of(xpl.of(g, id), id, n, g))
    case Nil{} a0:
      a0

# XREADGROUP's delivery of new entries (streamReplyWithRange with a
# group): each entry past the group's last ID becomes its last, its count
# of entries read one more when it has one, its last ID is not before the
# first entry and no entry was deleted at or after it, else the estimate
# at the entry (xs.est; none past it); each is pending for the consumer
# (delivered now, once), but with NOACK
def xrd.of(+e: KV.XN) -> KV.XRd:
  Bool.pick(KV.XRd, xn.is_max(e), KV.XRdNone{}, KV.XRdN{e})

def xg.read.next(rd: KV.XRd, +x: KV.XStream, +last: KV.XId, +id: KV.XId) -> KV.XRd:
  match rd:
    case KV.XRdN{+n}:
      Bool.pick(KV.XRd, Bool.and(Bool.not(Cmp.is_lt(KV.xid.cmp(last, xstream.first(x)))), Bool.not(xs.tomb(x, last))), KV.XRdN{KV.xn.add(n, xn.one())}, xrd.of(xs.est(x, id)))
    case KV.XRdNone{}:
      xrd.of(xs.est(x, id))

def xsn.add(noack: Bool, +id: KV.XId, +now: Nat, ns: List<&2, XSn>) -> List<&2, XSn>:
  match noack:
    case True{}:
      ns
    case False{}:
      XSn{id, now, xn.one()} <> ns

# a delivery so far: the group's last ID and count of entries read, and
# the pending entries made (the newest first)
type XDv is Data:
  XDv{last: KV.XId, rd: KV.XRd, ns: List<&2, XSn>}

def xg.deliver(es: List<&2, XE>, +x: KV.XStream, +noack: Bool, +now: Nat, d: XDv) -> XDv:
  match es d:
    case Con{XE{+id, fv}, rest} XDv{+last, rd, ns}:
      xg.deliver(rest, x, noack, now, XDv{id, xg.read.next(rd, x, last, id), xsn.add(noack, id, now, ns)})
    case Nil{} d0:
      d0

# XREADGROUP of history (an ID but ">"): the consumer's pending entries
# past it, at most c of them, each with its entry, or none when the
# stream no longer holds it; those it holds delivered again now, their
# count one more
type XHe is Data:
  XHe{id: KV.XId, e: Maybe<&2, XE>}

def xs.entry.of(es: List<&2, XE>) -> Maybe<&2, XE>:
  match es:
    case Con{e, rest}:
      Some{e}
    case Nil{}:
      None{}

def xs.entry(+x: KV.XStream, +id: KV.XId) -> Maybe<&2, XE>:
  xs.entry.of(xs.range(x, id, id, 1n, False{}))

# the entry of id, its ID alone with bare (its fields and values none)
def xs.entry.w(+x: KV.XStream, +id: KV.XId, +bare: Bool) -> Maybe<&2, XE>:
  xs.entry.of(xs.walk(x, id, id, 1n, False{}, bare))

def xhe.sn(m: Maybe<&2, XE>, +nk: KV.XNack, +now: Nat, ns: List<&2, XSn>) -> List<&2, XSn>:
  match m:
    case Some{e}:
      XSn{KV.xnack.id(nk), now, KV.xn.add(xnack.count(nk), xn.one())} <> ns
    case None{}:
      ns

type XHs is Data:
  XHs{hs: List<&2, XHe>, ns: List<&2, XSn>}

# (bare: the entries' IDs alone, for the words of the write alone)
def xg.history(nks: List<&2, KV.XNack>, +x: KV.XStream, +now: Nat, +bare: Bool, h: XHs) -> XHs:
  match nks h:
    case Con{+nk, rest} XHs{hs, ns}:
      +m = xs.entry.w(x, KV.xnack.id(nk), bare)
      xg.history(rest, x, now, bare, XHs{XHe{KV.xnack.id(nk), m} <> hs, xhe.sn(m, nk, now, ns)})
    case Nil{} h0:
      h0

# the pending entries of consumer c of g from lo on, at most n
def xg.of.con(m: Maybe<&2, KV.XCon>, +g: KV.XGroup, +lo: KV.XId, +n: Nat, +now: Nat) -> List<&2, KV.XNack>:
  match m:
    case Some{+k}:
      xs.pending(xgroup.pel(g), Some{xcon.ids(k)}, lo, xid.max(), n, XINone{}, now)
    case None{}:
      Nil{}

# XCLAIM of the IDs in turn (xclaimCommand), consumer c there: an entry
# the stream no longer holds loses its pending entry; one pending (or,
# with FORCE, one not pending yet, which counts from 1) passes when it is
# idle at least minidle (one made by FORCE always does); it is c's, at dt,
# its count RETRYCOUNT's, or one more but with JUSTID. The group so far,
# the pending entries the write names (the newest first) and the IDs c
# got (the newest first)
type XCs is Data:
  XCs{g: KV.XGroup, ns: List<&2, XSn>, got: List<&2, KV.XId>}

def xcl.count(r: Maybe<&2, KV.XN>, +justid: Bool, +n: KV.XN) -> KV.XN:
  match r:
    case Some{c}:
      c
    case None{}:
      Bool.pick(KV.XN, justid, n, KV.xn.add(n, xn.one()))

def xcl.take(+c: String, +id: KV.XId, +dt: Nat, +n: KV.XN, s: XCs) -> XCs:
  match s:
    case XCs{+g, ns, got}:
      XCs{xg.give(g, c, id, dt, n), XSn{id, dt, n} <> ns, id <> got}

def xcl.idle(ok: Bool, +c: String, +id: KV.XId, +dt: Nat, +n: KV.XN, s: XCs) -> XCs:
  match ok:
    case True{}:
      xcl.take(c, id, dt, n, s)
    case False{}:
      s

def xcl.held(m: Maybe<&2, KV.XNack>, +force: Bool, +c: String, +id: KV.XId, +minidle: Nat, +dt: Nat, r: Maybe<&2, KV.XN>, +justid: Bool, +now: Nat, s: XCs) -> XCs:
  match m:
    case Some{+nk}:
      xcl.idle(Bool.not(Nat.is_lt(Nat.sub(now, xnack.time(nk)), minidle)), c, id, dt, xcl.count(r, justid, xnack.count(nk)), s)
    case None{}:
      xcl.idle(force, c, id, dt, xcl.count(r, justid, xn.one()), s)

def xcl.gone(m: Maybe<&2, KV.XNack>, +id: KV.XId, s: XCs) -> XCs:
  match m s:
    case Some{+nk} XCs{+g, ns, got}:
      XCs{xg.unack(g, id), XSn{id, xnack.time(nk), xnack.count(nk)} <> ns, got}
    case None{} s0:
      s0

def xcl.one(has: Bool, m: Maybe<&2, KV.XNack>, +force: Bool, +c: String, +id: KV.XId, +minidle: Nat, +dt: Nat, r: Maybe<&2, KV.XN>, +justid: Bool, +now: Nat, s: XCs) -> XCs:
  match has:
    case True{}:
      xcl.held(m, force, c, id, minidle, dt, r, justid, now, s)
    case False{}:
      xcl.gone(m, id, s)

def xg.claim(ids: List<&2, KV.XId>, +x: KV.XStream, +force: Bool, +c: String, +minidle: Nat, +dt: Nat, +r: Maybe<&2, KV.XN>, +justid: Bool, +now: Nat, s: XCs) -> XCs:
  match ids s:
    case Con{+id, rest} XCs{+g, ns, got}:
      xg.claim(rest, x, force, c, minidle, dt, r, justid, now, xcl.one(xs.has(x, id), xpl.of(g, id), force, c, id, minidle, dt, r, justid, now, XCs{g, ns, got}))
    case Nil{} s0:
      s0

# XAUTOCLAIM's walk of the group's pending entries from its start
# (xautoclaimCommand): it looks at one more while it has tries left and
# fewer than its count claimed or gone (end once it has not); an entry
# the stream no longer holds loses its pending entry (gone); one idle at
# least minidle is c's, delivered now, its count one more but with
# JUSTID. The walk so far: the group, the pending entries the write
# names, the IDs claimed and those gone (each the newest first), how many
# more it may claim or find gone, and whether it ends; then the next
# pending entry's ID once it ends (its cursor, 0-0 for none)
type XAc is Data:
  XAc{g: KV.XGroup, ns: List<&2, XSn>, got: List<&2, KV.XId>, gone: List<&2, KV.XId>, left: Nat, end: Bool}

type XAw is Data:
  XAw{a: XAc, next: KV.XId}

def xac.claim(ok: Bool, +nk: KV.XNack, +c: String, +justid: Bool, +now: Nat, +tries: Nat, a: XAc) -> XAc:
  match ok a:
    case True{} XAc{+g, ns, got, gone, +left, e}:
      +id = KV.xnack.id(nk)
      +n = Bool.pick(KV.XN, justid, xnack.count(nk), KV.xn.add(xnack.count(nk), xn.one()))
      +l2 = Nat.sub(left, 1n)
      XAc{xg.give(g, c, id, now, n), XSn{id, now, n} <> ns, id <> got, gone, l2, Bool.or(Nat.is_eq(tries, 0n), Nat.is_eq(l2, 0n))}
    case False{} XAc{g, ns, got, gone, +left, e}:
      XAc{g, ns, got, gone, left, Bool.or(Nat.is_eq(tries, 0n), Nat.is_eq(left, 0n))}

# a pending entry looked at, tries left after it
def xac.one(has: Bool, +nk: KV.XNack, +c: String, +minidle: Nat, +justid: Bool, +now: Nat, +tries: Nat, a: XAc) -> XAc:
  match has a:
    case True{} a0:
      xac.claim(Bool.not(Nat.is_lt(Nat.sub(now, xnack.time(nk)), minidle)), nk, c, justid, now, tries, a0)
    case False{} XAc{+g, ns, got, gone, +left, e}:
      +id = KV.xnack.id(nk)
      +l2 = Nat.sub(left, 1n)
      XAc{xg.unack(g, id), XSn{id, xnack.time(nk), xnack.count(nk)} <> ns, got, id <> gone, l2, Bool.or(Nat.is_eq(tries, 0n), Nat.is_eq(l2, 0n))}

def xg.auto(nks: List<&2, KV.XNack>, +tries: Nat, +x: KV.XStream, +c: String, +minidle: Nat, +justid: Bool, +now: Nat, a: XAc) -> XAw:
  match nks a:
    case Con{+nk, rest} XAc{g, ns, got, gone, left, True{}}:
      XAw{XAc{g, ns, got, gone, left, True{}}, KV.xnack.id(nk)}
    case Con{+nk, rest} XAc{g, ns, got, gone, left, False{}}:
      +t2 = Nat.sub(tries, 1n)
      xg.auto(rest, t2, x, c, minidle, justid, now, xac.one(xs.has(x, KV.xnack.id(nk)), nk, c, minidle, justid, now, t2, XAc{g, ns, got, gone, left, False{}}))
    case Nil{} a0:
      XAw{a0, xid.zero()}
