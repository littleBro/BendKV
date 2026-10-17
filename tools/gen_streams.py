#!/usr/bin/env python3
# gen_streams.py: writes the trees of a stream in src/map.bend (Streams),
# between its "# BEGIN gen_streams: trees" and "# END gen_streams: trees"
# lines: one weight-balanced tree, as an intset's ITree, for each kind of
# element of a stream and its key (nodes and pending entries by ID, a
# consumer's IDs, consumers and groups by name), with its insertion,
# replacement and deletion by key.
#
#   python3 tools/gen_streams.py          # rewrites the block in place
#   python3 tools/gen_streams.py --check  # fails if it is out of date
import re, sys, pathlib

HERE = pathlib.Path(__file__).resolve().parent.parent
T = """
def {p}.size(+t: {T}) -> Nat:
  match t:
    case {Tip}{{}}:
      0n
    case {Bin}{{n, x, l, r}}:
      n

def {p}.bin(+x: {P}, +l: {T}, +r: {T}) -> {T}:
  {Bin}{{Nat.add(Nat.add({p}.size(l), {p}.size(r)), 1n), x, l, r}}

# how the key k compares with t's root's (GT for a tip)
def {p}.at(+t: {T}, +k: {K}) -> Cmp:
  match t:
    case {Tip}{{}}:
      GT{{}}
    case {Bin}{{n, +x, l, r}}:
      {cmp}(k, {key}(x))

def {p}.dbll(+x: {P}, l: {T}, +rx: {P}, rr: {T}, rl: {T}) -> {T}:
  match rl:
    case {Tip}{{}}:
      {p}.bin(rx, {p}.bin(x, l, {Tip}{{}}), rr)
    case {Bin}{{n, +y, +yl, +yr}}:
      {p}.bin(y, {p}.bin(x, l, yl), {p}.bin(rx, yr, rr))

def {p}.rotl.of(single: Bool, +x: {P}, l: {T}, +rx: {P}, rl: {T}, rr: {T}) -> {T}:
  match single:
    case True{{}}:
      {p}.bin(rx, {p}.bin(x, l, rl), rr)
    case False{{}}:
      {p}.dbll(x, l, rx, rr, rl)

def {p}.rotl(+x: {P}, l: {T}, r: {T}) -> {T}:
  match r:
    case {Tip}{{}}:
      {p}.bin(x, l, {Tip}{{}})
    case {Bin}{{n, +rx, +rl, +rr}}:
      {p}.rotl.of(Nat.is_lt({p}.size(rl), Nat.mul(2n, {p}.size(rr))), x, l, rx, rl, rr)

def {p}.dblr(+x: {P}, r: {T}, +lx: {P}, ll: {T}, lr: {T}) -> {T}:
  match lr:
    case {Tip}{{}}:
      {p}.bin(lx, ll, {p}.bin(x, {Tip}{{}}, r))
    case {Bin}{{n, +y, +yl, +yr}}:
      {p}.bin(y, {p}.bin(lx, ll, yl), {p}.bin(x, yr, r))

def {p}.rotr.of(single: Bool, +x: {P}, r: {T}, +lx: {P}, ll: {T}, lr: {T}) -> {T}:
  match single:
    case True{{}}:
      {p}.bin(lx, ll, {p}.bin(x, lr, r))
    case False{{}}:
      {p}.dblr(x, r, lx, ll, lr)

def {p}.rotr(+x: {P}, l: {T}, r: {T}) -> {T}:
  match l:
    case {Tip}{{}}:
      {p}.bin(x, {Tip}{{}}, r)
    case {Bin}{{n, +lx, +ll, +lr}}:
      {p}.rotr.of(Nat.is_lt({p}.size(lr), Nat.mul(2n, {p}.size(ll))), x, r, lx, ll, lr)

def {p}.bal.of(few: Bool, rh: Bool, lh: Bool, +x: {P}, l: {T}, r: {T}) -> {T}:
  match few rh lh:
    case True{{}} _ _:
      {p}.bin(x, l, r)
    case False{{}} True{{}} _:
      {p}.rotl(x, l, r)
    case False{{}} False{{}} True{{}}:
      {p}.rotr(x, l, r)
    case False{{}} False{{}} False{{}}:
      {p}.bin(x, l, r)

def {p}.balance(+x: {P}, +l: {T}, +r: {T}) -> {T}:
  +sl = {p}.size(l)
  +sr = {p}.size(r)
  {p}.bal.of(Nat.is_le(Nat.add(sl, sr), 1n), Nat.is_lt(Nat.mul(3n, sl), sr), Nat.is_lt(Nat.mul(3n, sr), sl), x, l, r)

# the element of key k in t; c is how k compares with t's root's
def {p}.find(+t: {T}, c: Cmp, +k: {K}) -> Maybe<&2, {P}>:
  match t c:
    case {Tip}{{}} _:
      None{{}}
    case {Bin}{{n, x, +l, r}} LT{{}}:
      {p}.find(l, {p}.at(l, k), k)
    case {Bin}{{n, x, l, +r}} GT{{}}:
      {p}.find(r, {p}.at(r, k), k)
    case {Bin}{{n, +x, l, r}} EQ{{}}:
      Some{{x}}

# t with x in its place (t holds no element of x's key); c is how x's key
# compares with t's root's
def {p}.ins(t: {T}, c: Cmp, +x: {P}) -> {T}:
  match t c:
    case {Tip}{{}} _:
      {Bin}{{1n, x, {Tip}{{}}, {Tip}{{}}}}
    case {Bin}{{n, +y, +l, +r}} LT{{}}:
      {p}.balance(y, {p}.ins(l, {p}.at(l, {key}(x)), x), r)
    case {Bin}{{n, +y, +l, +r}} _:
      {p}.balance(y, l, {p}.ins(r, {p}.at(r, {key}(x)), x))

def {p}.put(+x: {P}, +t: {T}) -> {T}:
  {p}.ins(t, {p}.at(t, {key}(x)), x)

# t with x in the place of the element of x's key, which t holds; c is
# how x's key compares with t's root's
def {p}.rep(t: {T}, c: Cmp, +x: {P}) -> {T}:
  match t c:
    case {Tip}{{}} _:
      {Tip}{{}}
    case {Bin}{{+n, +y, +l, +r}} LT{{}}:
      {Bin}{{n, y, {p}.rep(l, {p}.at(l, {key}(x)), x), r}}
    case {Bin}{{+n, +y, +l, +r}} GT{{}}:
      {Bin}{{n, y, l, {p}.rep(r, {p}.at(r, {key}(x)), x)}}
    case {Bin}{{+n, y, +l, +r}} EQ{{}}:
      {Bin}{{n, x, l, r}}

def {p}.set(+x: {P}, +t: {T}) -> {T}:
  {p}.rep(t, {p}.at(t, {key}(x)), x)

# a node's element cut from the end of a tree, and the tree left
type {Cut} is Data:
  {Cut}{{x: {P}, t: {T}}}

def {p}.cutl.fix(c: {Cut}, +x: {P}, r: {T}) -> {Cut}:
  match c:
    case {Cut}{{+cx, +ct}}:
      {Cut}{{cx, {p}.balance(x, ct, r)}}

# the first element of the node of x between l and r, cut from it
def {p}.cutl(l: {T}, +x: {P}, r: {T}) -> {Cut}:
  match l:
    case {Tip}{{}}:
      {Cut}{{x, r}}
    case {Bin}{{n, +lx, ll, lr}}:
      {p}.cutl.fix({p}.cutl(ll, lx, lr), x, r)

def {p}.cutr.fix(c: {Cut}, +x: {P}, l: {T}) -> {Cut}:
  match c:
    case {Cut}{{+cx, +ct}}:
      {Cut}{{cx, {p}.balance(x, l, ct)}}

# the last element of the node of x between l and r, cut from it
def {p}.cutr(r: {T}, +x: {P}, l: {T}) -> {Cut}:
  match r:
    case {Tip}{{}}:
      {Cut}{{x, l}}
    case {Bin}{{n, +rx, rl, rr}}:
      {p}.cutr.fix({p}.cutr(rr, rx, rl), x, l)

def {p}.glue.lfix(c: {Cut}, r: {T}) -> {T}:
  match c:
    case {Cut}{{+x, +l}}:
      {p}.balance(x, l, r)

def {p}.glue.rfix(l: {T}, c: {Cut}) -> {T}:
  match c:
    case {Cut}{{+x, +r}}:
      {p}.balance(x, l, r)

# the larger side l's last element takes the place of the one taken out
def {p}.glue.l(l: {T}, r: {T}) -> {T}:
  match l:
    case {Tip}{{}}:
      r
    case {Bin}{{n, +lx, ll, lr}}:
      {p}.glue.lfix({p}.cutr(lr, lx, ll), r)

# or r's first element (r a tip: both sides are)
def {p}.glue.r(l: {T}, r: {T}) -> {T}:
  match r:
    case {Tip}{{}}:
      l
    case {Bin}{{n, +rx, rl, rr}}:
      {p}.glue.rfix(l, {p}.cutl(rl, rx, rr))

def {p}.glue.of(lbig: Bool, l: {T}, r: {T}) -> {T}:
  match lbig:
    case True{{}}:
      {p}.glue.l(l, r)
    case False{{}}:
      {p}.glue.r(l, r)

# the elements of l and then those of r, the sides of a node whose
# element is taken out
def {p}.glue(+l: {T}, +r: {T}) -> {T}:
  {p}.glue.of(Nat.is_lt({p}.size(r), {p}.size(l)), l, r)

# t without the element of key k (t as it was when it holds none); c is
# how k compares with t's root's
def {p}.rm(t: {T}, c: Cmp, +k: {K}) -> {T}:
  match t c:
    case {Tip}{{}} _:
      {Tip}{{}}
    case {Bin}{{n, +y, +l, +r}} LT{{}}:
      {p}.balance(y, {p}.rm(l, {p}.at(l, k), k), r)
    case {Bin}{{n, +y, +l, +r}} GT{{}}:
      {p}.balance(y, l, {p}.rm(r, {p}.at(r, k), k))
    case {Bin}{{n, y, +l, +r}} EQ{{}}:
      {p}.glue(l, r)

def {p}.del(+k: {K}, +t: {T}) -> {T}:
  {p}.rm(t, {p}.at(t, k), k)

# a node's element, made before the walk goes on (as it.el)
def {p}.el(+x: {P}) -> {P}:
  x

# the elements of t in order, before acc
def {p}.list(+t: {T}, acc: List<&2, {P}>) -> List<&2, {P}>:
  match t:
    case {Tip}{{}}:
      acc
    case {Bin}{{n, +x, +l, +r}}:
      y = {p}.el(x)
      acc2 = {p}.list(r, acc)
      {p}.list(l, y <> acc2)
"""
kinds = [
  dict(p="xns", Cut="XNCut", T="XNodes", Tip="XNTip", Bin="XNBin", P="XNode", K="XId", cmp="xid.cmp", key="xnode.mid"),
  dict(p="xpl", Cut="XPCut", T="XPel", Tip="XPTip", Bin="XPBin", P="XNack", K="XId", cmp="xid.cmp", key="xnack.id"),
  dict(p="xis", Cut="XICut", T="XIds", Tip="XITip", Bin="XIBin", P="XId", K="XId", cmp="xid.cmp", key="xid.self"),
  dict(p="xcs", Cut="XCCut", T="XCons", Tip="XCTip", Bin="XCBin", P="XCon", K="String", cmp="String.order", key="xcon.name"),
  dict(p="xgs", Cut="XGCut", T="XGroups", Tip="XGTip", Bin="XGBin", P="XGroup", K="String", cmp="String.order", key="xgroup.name"),
]

def block_trees():
    out = []
    for k in kinds:
        out.append("")
        out.append("# %s, by %s (%s)" % (k["T"], "ID" if k["K"] == "XId" else "name", k["p"]))
        out.append(T.format(**k).rstrip())
    return out[1:]

def fill(path, check):
    text = path.read_text()
    pat = re.compile(r"(?ms)^(# BEGIN gen_streams: trees\n).*?^(# END gen_streams: trees\n)")
    if not pat.search(text):
        sys.exit(f"{path.name}: no block trees")
    body = "\n".join(block_trees()) + "\n"
    new = pat.sub(lambda m: m.group(1) + body + m.group(2), text)
    if check:
        if new != text:
            sys.exit(f"{path.name} is out of date: run tools/gen_streams.py")
    else:
        path.write_text(new)

if __name__ == "__main__":
    fill(HERE / "src/map.bend", "--check" in sys.argv)
