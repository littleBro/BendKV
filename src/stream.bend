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

# whether a is 2^64 - 1 (-1 as a long long)
def xn.is_max(+a: KV.XN) -> Bool:
  KV.xn.is_eq(a, D.xn.max())

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

# an entry's head: its flags, its ID and the bytes after them
type XEh is Data:
  XEh{fl: Nat, id: KV.XId, t: String}
  XEhBad{}

def xh.seq(+fl: Nat, +ms: KV.XN, r: D.LpR, +mid: KV.XId) -> XEh:
  match r:
    case D.LpOk{+v, t}:
      XEh{fl, D.xid.plus(mid, ms, KV.xn.of_int(v)), t}
    case _:
      XEhBad{}

def xh.ms(+fl: Nat, r: D.LpR, +mid: KV.XId) -> XEh:
  match r:
    case D.LpOk{+v, t}:
      xh.seq(fl, KV.xn.of_int(v), D.lp.next(t), mid)
    case _:
      XEhBad{}

def xh.flags(r: D.LpR, +mid: KV.XId) -> XEh:
  match r:
    case D.LpOk{+v, t}:
      xh.ms(String.dec_at(v, 0n, String.length(v)), D.lp.next(t), mid)
    case _:
      XEhBad{}

def xh.read(+e: String, +mid: KV.XId) -> XEh:
  xh.flags(D.lp.next(e), mid)

def xh.deleted(+fl: Nat) -> Bool:
  Nat.is_eq(Nat.mod(fl, 2n), 1n)

def xh.same(+fl: Nat) -> Bool:
  Nat.is_eq(Nat.mod(Nat.div(fl, 2n), 2n), 1n)

# k more elements from r on, after acc (the last first)
def xe.els(k: Nat, r: D.LpR, acc: List<&2, String>) -> List<&2, String>:
  match k r:
    case 1n+j D.LpOk{v, t}:
      xe.els(j, D.lp.next(t), v <> acc)
    case _ _:
      acc

# the master's fields fs and the values vs (the last first) in turn
def xe.zip(fs: List<&2, String>, vs: List<&2, String>, acc: List<&2, String>) -> List<&2, String>:
  match fs vs:
    case Con{f, fr} Con{v, vr}:
      xe.zip(fr, vr, v <> (f <> acc))
    case _ _:
      List.reverse(&2, String, acc)

def xe.own(r: D.LpR) -> List<&2, String>:
  match r:
    case D.LpOk{+v, t}:
      List.reverse(&2, String, xe.els(Nat.mul(String.dec_at(v, 0n, String.length(v)), 2n), D.lp.next(t), Nil{}))
    case _:
      Nil{}

# an entry's fields and values, from the bytes t after its head
def xe.body(same: Bool, t: String, +mfs: List<&2, String>, +nmf: Nat) -> List<&2, String>:
  match same:
    case True{}:
      xe.zip(mfs, List.reverse(&2, String, xe.els(nmf, D.lp.next(t), Nil{})), Nil{})
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

# A walk: the entries taken (the newest first), how many more it may
# take, and whether it is over
type XWk is Data:
  XWk{acc: List<&2, XE>, c: Nat, end: Bool}

# take (2), pass (0), or end (1)
def xw.do(k: Nat, +fl: Nat, +id: KV.XId, t: String, acc: List<&2, XE>, +c: Nat, +mfs: List<&2, String>, +nmf: Nat) -> XWk:
  match k:
    case 0n:
      XWk{acc, c, False{}}
    case 1n:
      XWk{acc, c, True{}}
    case _:
      XWk{XE{id, xe.body(xh.same(fl), t, mfs, nmf)} <> acc, Nat.sub(c, 1n), Nat.is_eq(c, 1n)}

# what a forward walk does with an entry: pass one deleted or before lo,
# end at one past hi, take the others; backwards, pass one deleted or
# past hi, end at one before lo
def xw.what(rev: Bool, +fl: Nat, +id: KV.XId, +lo: KV.XId, +hi: KV.XId) -> Nat:
  match rev:
    case False{}:
      Bool.pick(Nat, Bool.or(xh.deleted(fl), Cmp.is_lt(KV.xid.cmp(id, lo))), 0n, Bool.pick(Nat, Cmp.is_gt(KV.xid.cmp(id, hi)), 1n, 2n))
    case True{}:
      Bool.pick(Nat, Bool.or(xh.deleted(fl), Cmp.is_gt(KV.xid.cmp(id, hi))), 0n, Bool.pick(Nat, Cmp.is_lt(KV.xid.cmp(id, lo)), 1n, 2n))

def xw.one(h: XEh, +rev: Bool, acc: List<&2, XE>, +c: Nat, +mfs: List<&2, String>, +nmf: Nat, +lo: KV.XId, +hi: KV.XId) -> XWk:
  match h:
    case XEh{+fl, +id, t}:
      xw.do(xw.what(rev, fl, id, lo, hi), fl, id, t, acc, c, mfs, nmf)
    case XEhBad{}:
      XWk{acc, c, True{}}

# a walk through a node's entries es, in the walk's order
def xw.ents(es: List<&2, String>, w: XWk, +rev: Bool, +mid: KV.XId, +mfs: List<&2, String>, +nmf: Nat, +lo: KV.XId, +hi: KV.XId) -> XWk:
  match es w:
    case Con{+e, rest} XWk{acc, +c, False{}}:
      xw.ents(rest, xw.one(xh.read(e, mid), rev, acc, c, mfs, nmf, lo, hi), rev, mid, mfs, nmf, lo, hi)
    case _ other:
      other

# a node's entries es (kept the newest first) in a walk's order: a match,
# so that a walk backwards reverses none
def xw.order(rev: Bool, +es: List<&2, String>) -> List<&2, String>:
  match rev:
    case True{}:
      es
    case False{}:
      List.reverse(&2, String, es)

# a walk through a node
def xw.node(+x: KV.XNode, w: XWk, +rev: Bool, +lo: KV.XId, +hi: KV.XId) -> XWk:
  match x:
    case KV.XNd{+mid, +mfs, live, dead, bytes, nel, +es}:
      xw.ents(xw.order(rev, es), w, rev, mid, mfs, List.length(&2, String, mfs), lo, hi)
    case KV.XNdOf{+y}:
      xw.node(y, w, rev, lo, hi)

# a walk through k nodes of t from place i on, forwards or backwards
def xw.nodes(k: Nat, w: XWk, +t: KV.XNodes, +i: Nat, +rev: Bool, +lo: KV.XId, +hi: KV.XId) -> XWk:
  match k w:
    case 1n+j XWk{acc, +c, False{}}:
      xw.nodes(j, xw.node(xns.nth(t, i), XWk{acc, c, False{}}, rev, lo, hi), t, Bool.pick(Nat, rev, Nat.sub(i, 1n), Nat.add(i, 1n)), rev, lo, hi)
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

def xw.at(+t: KV.XNodes, +rev: Bool, +lo: KV.XId, +hi: KV.XId) -> Nat:
  +n = KV.xns.size(t)
  +k = Bool.pick(KV.XId, rev, hi, lo)
  +dflt = Bool.pick(Nat, rev, Nat.sub(n, 1n), 0n)
  Bool.pick(Nat, xid.is_zero(k), dflt, xw.start(xns.floor(t, k), dflt))

def xstream.nodes(+x: KV.XStream) -> KV.XNodes:
  match x:
    case KV.XStr{n, last, first, maxdel, added, +nodes, groups}:
      nodes
    case KV.XStrOf{+y}:
      xstream.nodes(y)

# a walk's entries in the order it took them
def xw.taken(w: XWk) -> List<&2, XE>:
  match w:
    case XWk{acc, c, e}:
      List.reverse(&2, XE, acc)

# the entries of x from lo to hi, at most c of them (c at least 1), in
# the order of the walk (rev: from hi down)
def xs.range(+x: KV.XStream, +lo: KV.XId, +hi: KV.XId, +c: Nat, +rev: Bool) -> List<&2, XE>:
  +t = xstream.nodes(x)
  +i = xw.at(t, rev, lo, hi)
  +n = KV.xns.size(t)
  +k = Bool.pick(Nat, rev, Nat.add(i, 1n), Nat.sub(n, i))
  xw.taken(xw.nodes(Bool.pick(Nat, Nat.is_eq(n, 0n), 0n, k), XWk{Nil{}, c, False{}}, t, i, rev, lo, hi))

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
def xs.top(+x: KV.XStream) -> Maybe<&2, KV.XId>:
  xs.top.of(xs.range(x, xid.zero(), xid.max(), 1n, True{}))

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

def xs.group(+x: KV.XStream, +name: String) -> Maybe<&2, KV.XGroup>:
  +t = xstream.groups(x)
  KV.xgs.find(t, KV.xgs.at(t, name), name)

def xgroup.con(+g: KV.XGroup, +name: String) -> Maybe<&2, KV.XCon>:
  +t = xgroup.cons(g)
  KV.xcs.find(t, KV.xcs.at(t, name), name)

def xcon.seen(+c: KV.XCon) -> Nat:
  match c:
    case KV.XCon{name, +seen, ids}:
      seen

def xcon.ids(+c: KV.XCon) -> KV.XIds:
  match c:
    case KV.XCon{name, seen, +ids}:
      ids

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

# streamEstimateDistanceFromFirstEverEntry: id's count of entries read,
# as a long long's 64 bits, 2^64 - 1 (-1) for none: 0 in a stream no
# entry was ever added to; the count of entries added at the last ID,
# and at any ID up to it in an empty stream; none past it; with no entry
# deleted after the first live one, the entries added less the live ones
# before the first live entry, one more at it; else none
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
  Bool.pick(KV.XN, KV.xn.is_eq(added, xn.zero()), xn.zero(), Bool.pick(KV.XN, Bool.and(Nat.is_eq(n, 0n), Bool.not(Cmp.is_gt(c))), added, xs.est.last(c, added, n, xstream.first(x), xstream.maxdel(x), id)))

# streamRangeHasTombstones from start to the last ID: whether an entry
# was deleted at or after start, past the first live entry
def xs.tomb(+x: KV.XStream, +start: KV.XId) -> Bool:
  +maxdel = xstream.maxdel(x)
  +live = Bool.and(Nat.is_lt(0n, KV.xstream.len(x)), Bool.not(xid.is_zero(maxdel)))
  Bool.and(live, Bool.and(Bool.not(Cmp.is_gt(KV.xid.cmp(xstream.first(x), maxdel))), Bool.not(Cmp.is_gt(KV.xid.cmp(start, maxdel)))))

def xs.lag.est(+added: KV.XN, +e: KV.XN) -> Maybe<&2, KV.XN>:
  Bool.pick(Maybe<&2, KV.XN>, xn.is_max(e), None{}, Some{xn.sub(added, e)})

def xs.lag.of(rd: KV.XRd, +x: KV.XStream, +last: KV.XId, +added: KV.XN) -> Maybe<&2, KV.XN>:
  match rd:
    case KV.XRdN{+r}:
      Bool.pick(Maybe<&2, KV.XN>, xs.tomb(x, last), xs.lag.est(added, xs.est(x, last)), Some{xn.sub(added, r)})
    case KV.XRdNone{}:
      xs.lag.est(added, xs.est(x, last))

# streamReplyWithCGLag: a group's lag, as a long long's 64 bits, or none
def xs.lag(+x: KV.XStream, +g: KV.XGroup) -> Maybe<&2, KV.XN>:
  +added = xstream.added(x)
  Bool.pick(Maybe<&2, KV.XN>, KV.xn.is_eq(added, xn.zero()), Some{xn.zero()}, xs.lag.of(xgroup.read(g), x, xgroup.last(g), added))

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
      xcs.pending(rest, xcs.keep(Nat.is_eq(KV.xis.size(xcon.ids(x)), 0n), x, acc))
    case Nil{}:
      List.reverse(&2, KV.XCon, acc)
