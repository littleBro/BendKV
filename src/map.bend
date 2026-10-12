# map.bend: a persistent hash map from String keys to Data values.
#
# The map is a 16-way trie addressed by the hex digits of a key's hash:
# five digits, so up to 2^20 buckets, and a read walks five nodes. Where a
# path ends, the trie is the bucket itself, a chain of entries. It is
# shaped for proof rather than for cleverness: the trie never needs an
# ordering on keys (unlike a search tree), and two different paths address
# two different nodes (unlike a radix tree with prefix sharing), so the
# laws in LAWS.bend follow by induction on the depth of the walk.
#
# Nothing here depends on the hash being good: the laws hold for any
# function from keys to digits. A good hash only keeps buckets short.
#
# The 16-way parts, between "BEGIN gen_trie" and "END gen_trie", are
# written by tools/gen_trie.py.

import Base

# Types
# -----

# BEGIN gen_trie: types
# a hex digit of a hash: which of a node's 16 subtries a path takes
type Hex is Data:
  H0{}
  H1{}
  H2{}
  H3{}
  H4{}
  H5{}
  H6{}
  H7{}
  H8{}
  H9{}
  H10{}
  H11{}
  H12{}
  H13{}
  H14{}
  H15{}

# a 16-way trie: Tip is the empty trie, and a Node holds the subtries
# for the 16 values of the next digit. Where a path ends, the trie is
# the bucket of that path: a chain of Ent cells, each a key, its value,
# the time it expires at (ms since 1970; 0 when it does not) and the
# rest of the bucket, which ends in Tip. A Node inside a bucket and an
# Ent above the end of a path are never built; they read as empty. An
# Ent of four words fills its block, as one of three did (the
# allocator's blocks are powers of two).
type Trie<-V: Data> is Data:
  Tip{}
  Node{c0: Trie<V>, c1: Trie<V>, c2: Trie<V>, c3: Trie<V>, c4: Trie<V>, c5: Trie<V>, c6: Trie<V>, c7: Trie<V>, c8: Trie<V>, c9: Trie<V>, c10: Trie<V>, c11: Trie<V>, c12: Trie<V>, c13: Trie<V>, c14: Trie<V>, c15: Trie<V>}
  Ent{key: String, val: V, exp: Nat, rest: Trie<V>}
# END gen_trie: types

# what a key holds: its value and the time it expires at (0: never)
type Item<-V: Data> is Data:
  Item{val: V, exp: Nat}

# a change to one bucket: set a key's value and the time it expires at
# (OSet), set its value and keep its time (OKeep), set its time and keep
# its value (OExp), or delete it (ODel)
type Op<-V: Data> is Data:
  OSet{key: String, val: V, exp: Nat}
  OKeep{key: String, val: V}
  OExp{key: String, exp: Nat}
  ODel{key: String}

# What a key of the server holds (redis.bend: Db): a string, or a
# collection. The commands on strings see any collection as a value of
# another kind (WRONGTYPE), so a new kind of collection changes no
# command on strings and none of their proofs.
type Val is Data:
  VStr{s: String}
  VColl{c: Coll}

# a collection: a hash, its fields and their values (Hash), or a list,
# its elements in order (Deq)
type Coll is Data:
  CHash{h: Hash}
  CList{l: Deq}

# a hash: a field and its value
type HPair is Data:
  HP{f: String, v: String}

# A hash, as Redis 7.0 keeps one: a small one (n fields, each of at most
# hash-max-listpack-value bytes, n at most hash-max-listpack-entries) as
# a list of its pairs in the order they came (a listpack: HGETALL answers
# them so), a larger one as a trie of its fields (a hashtable, in no
# order), which it stays.
type Hash is Data:
  HSmall{n: Nat, ps: List<&2, HPair>}
  HBig{n: Nat, t: Trie<String>}

# A list, as a deque of two stacks: its first nf elements in order (f),
# then the other nb in reverse (b), so the list is f and then b reversed
# (Lists, below)
type Deq is Data:
  Deq{nf: Nat, f: List<&2, String>, nb: Nat, b: List<&2, String>}

# Keys
# ----

# string equality: String.eq, native on packed Strings (a memcmp a chunk
# at a time); PROOF.bend (str_spec) shows it is the comparison char by
# char, Char.is_eq comparing the code points
def str_eq(a: String, b: String) -> Bool:
  String.eq(a, b)

# FNV-1a over the code points of a string: String.hash, native on packed
# Strings. The laws hold for any hash; a good one keeps buckets short.
def hash(s: String) -> U32:
  String.hash(s)

# BEGIN gen_trie: hex
# the digit n, for n below 16 (a larger n reads as 15): a chain of
# matches that clang folds into the number itself
def hex.of(n: Nat) -> Hex:
  match n:
    case 0n:
      H0{}
    case 1n+n0:
      match n0:
        case 0n:
          H1{}
        case 1n+n1:
          match n1:
            case 0n:
              H2{}
            case 1n+n2:
              match n2:
                case 0n:
                  H3{}
                case 1n+n3:
                  match n3:
                    case 0n:
                      H4{}
                    case 1n+n4:
                      match n4:
                        case 0n:
                          H5{}
                        case 1n+n5:
                          match n5:
                            case 0n:
                              H6{}
                            case 1n+n6:
                              match n6:
                                case 0n:
                                  H7{}
                                case 1n+n7:
                                  match n7:
                                    case 0n:
                                      H8{}
                                    case 1n+n8:
                                      match n8:
                                        case 0n:
                                          H9{}
                                        case 1n+n9:
                                          match n9:
                                            case 0n:
                                              H10{}
                                            case 1n+n10:
                                              match n10:
                                                case 0n:
                                                  H11{}
                                                case 1n+n11:
                                                  match n11:
                                                    case 0n:
                                                      H12{}
                                                    case 1n+n12:
                                                      match n12:
                                                        case 0n:
                                                          H13{}
                                                        case 1n+n13:
                                                          match n13:
                                                            case 0n:
                                                              H14{}
                                                            case 1n+n14:
                                                              H15{}
# END gen_trie: hex

# the lowest hex digit of a word
def hex(+h: U32) -> Hex:
  hex.of(U32.to_nat(U32.and(h, 15)))

# a word without its lowest hex digit
def shr4(+h: U32) -> U32:
  U32.shrn(h, 4n)

# Buckets
# -------
# A bucket is a chain of Ent cells. Each step takes the comparison of k
# with the entry's key as a parameter (bhead), computed ahead, so that
# the step can match on it: a read stops at the first entry for k, and a
# write builds only the bucket it returns. An entry holds the time its key
# expires at, in ms since 1970, or 0 when it does not expire (exp).

# whether e has at most k decimal digits (e is below 10^k): k divisions
# by 10 leave 0
def digits.le(k: Nat, +e: Nat) -> Bool:
  match k:
    case 0n:
      Nat.is_eq(e, 0n)
    case 1n+j:
      digits.le(j, Nat.div(e, 10n))

# whether a time is below 10^14 ms (the year 5138): the times an entry
# keeps, which the append-only file writes in 14 digits or fewer (a Nat
# holds 2^48 - 1 at most). The test counts digits: the proofs never build
# 10^14, which the checker would unfold one by one.
def small(+e: Nat) -> Bool:
  digits.le(14n, e)

# the time a key keeps for e: e when it is small, else none (a key whose
# time is past the year 5138 does not expire). The map stores a time as
# it is given; redis.bend clamps every time a command gives a key.
def clamp.go(ok: Bool, +e: Nat) -> Nat:
  match ok:
    case True{}:
      e
    case False{}:
      0n

def clamp(+e: Nat) -> Nat:
  match e:
    case 0n:
      0n
    case 1n+p:
      clamp.go(small(1n+p), 1n+p)

# whether a bucket's first entry is for k
def bhead(-V: Data, +k: String, b: Trie<V>) -> Bool:
  match b:
    case Ent{key, v, e, rest}:
      str_eq(k, key)
    case other:
      False{}

# whether an entry that expires at e is there at now: a key expires once
# now is past its time (Redis's keyIsExpired), and at now 0, as while a
# file loads, every key is there
def live(+now: Nat, +e: Nat) -> Bool:
  Bool.or(Nat.is_eq(e, 0n), Nat.is_le(now, e))

# a key before acc when it is there (ok): the folds of KEYS, SCAN and
# RANDOMKEY skip the keys that expired
def kput(ok: Bool, +k: String, acc: List<&2, String>) -> List<&2, String>:
  match ok:
    case True{}:
      k <> acc
    case False{}:
      acc

# the value of the first entry for k; same is bhead(V, k, b), computed
# before b is passed on, so that b is not shared
def bget.go(-V: Data, +k: String, b: Trie<V>, same: Bool) -> Maybe<&2, V>:
  match b same:
    case Ent{key, v, e, rest} True{}:
      Some{v}
    case Ent{key, v, e, +rest} False{}:
      s = bhead(V, k, rest)
      bget.go(V, k, rest, s)
    case other _:
      None{}

def bget(-V: Data, +k: String, +b: Trie<V>) -> Maybe<&2, V>:
  s = bhead(V, k, b)
  bget.go(V, k, b, s)

# the first entry for k: its value and the time it expires at (the laws
# speak of it)
def bent.go(-V: Data, +k: String, b: Trie<V>, same: Bool) -> Maybe<&2, Item<V>>:
  match b same:
    case Ent{key, v, e, rest} True{}:
      Some{Item{v, e}}
    case Ent{key, v, e, +rest} False{}:
      s = bhead(V, k, rest)
      bent.go(V, k, rest, s)
    case other _:
      None{}

def bent(-V: Data, +k: String, +b: Trie<V>) -> Maybe<&2, Item<V>>:
  s = bhead(V, k, b)
  bent.go(V, k, b, s)

# the code of the first entry for k: 0 when there is none, else 1 plus the
# time it expires at, so that one walk tells whether the key is there,
# whether it expires and when (a write that counts the keys asks it)
def bcode.go(-V: Data, +k: String, +b: Trie<V>, same: Bool) -> Nat:
  match b same:
    case Ent{key, v, +e, rest} True{}:
      1n+e
    case Ent{key, v, e, +rest} False{}:
      s = bhead(V, k, rest)
      bcode.go(V, k, rest, s)
    case other _:
      0n

def bcode(-V: Data, +k: String, +b: Trie<V>) -> Nat:
  s = bhead(V, k, b)
  bcode.go(V, k, b, s)

# the value of the first entry for k, when it is there at now
def blive.ent(-V: Data, ok: Bool, v: V) -> Maybe<&2, V>:
  match ok:
    case True{}:
      Some{v}
    case False{}:
      None{}

def blive.go(-V: Data, +k: String, b: Trie<V>, same: Bool, +now: Nat) -> Maybe<&2, V>:
  match b same:
    case Ent{key, v, +e, rest} True{}:
      blive.ent(V, live(now, e), v)
    case Ent{key, v, e, +rest} False{}:
      s = bhead(V, k, rest)
      blive.go(V, k, rest, s, now)
    case other _:
      None{}

def blive(-V: Data, +k: String, +b: Trie<V>, +now: Nat) -> Maybe<&2, V>:
  s = bhead(V, k, b)
  blive.go(V, k, b, s, now)

# blive for the keys' values, answering a copy of a string made where it
# lies: the value is only read, so the trie never shares it (blive answers
# the value itself, which the trie and the answer then share, under a
# seal). A copy of the whole string is the string (PROOF.bend: take_len).
# Of a collection it answers only that there is one (GET and INCR tell it
# from a string, nothing more): got_of is what it answers, of what blive
# answers.
type Got is Data:
  GStr{s: String}
  GColl{}
  GNone{}

def got_of(m: Maybe<&2, Val>) -> Got:
  match m:
    case Some{VStr{s}}:
      GStr{s}
    case Some{VColl{c}}:
      GColl{}
    case None{}:
      GNone{}

def bget_c.val(+v: Val) -> Got:
  match v:
    case VStr{+s}:
      GStr{String.take(s, String.length(s))}
    case VColl{c}:
      GColl{}

def bget_c.ent(ok: Bool, +v: Val) -> Got:
  match ok:
    case True{}:
      bget_c.val(v)
    case False{}:
      GNone{}

def bget_c.go(+k: String, b: Trie<Val>, same: Bool, +now: Nat) -> Got:
  match b same:
    case Ent{key, +v, +e, rest} True{}:
      bget_c.ent(live(now, e), v)
    case Ent{key, v, e, +rest} False{}:
      s = bhead(Val, k, rest)
      bget_c.go(k, rest, s, now)
    case other _:
      GNone{}

def bget_c(+k: String, +b: Trie<Val>, +now: Nat) -> Got:
  s = bhead(Val, k, b)
  bget_c.go(k, b, s, now)

# the bucket with the first entry for k set to v, expiring at e, or k
# appended. The bucket's end goes back into the
# result (a Tip, or a Node that reads as empty), so that bset.go owns the
# bucket and rebuilds it in place.
def bset.go(-V: Data, +k: String, v: V, +e: Nat, b: Trie<V>, same: Bool) -> Trie<V>:
  match b same:
    case Ent{key, val, ex, rest} True{}:
      Ent{key, v, e, rest}
    case Ent{key, val, ex, +rest} False{}:
      s = bhead(V, k, rest)
      Ent{key, val, ex, bset.go(V, k, v, e, rest, s)}
    case other _:
      Ent{k, v, e, other}

def bset(-V: Data, +k: String, v: V, +e: Nat, +b: Trie<V>) -> Trie<V>:
  s = bhead(V, k, b)
  bset.go(V, k, v, e, b, s)

# the bucket with the first entry for k set to v, its time kept, or k
# appended with none (KEEPTTL, and a write of a key that is there)
def bkeep.go(-V: Data, +k: String, v: V, b: Trie<V>, same: Bool) -> Trie<V>:
  match b same:
    case Ent{key, val, ex, rest} True{}:
      Ent{key, v, ex, rest}
    case Ent{key, val, ex, +rest} False{}:
      s = bhead(V, k, rest)
      Ent{key, val, ex, bkeep.go(V, k, v, rest, s)}
    case other _:
      Ent{k, v, 0n, other}

def bkeep(-V: Data, +k: String, v: V, +b: Trie<V>) -> Trie<V>:
  s = bhead(V, k, b)
  bkeep.go(V, k, v, b, s)

# the bucket with the first entry for k expiring at e instead, its value
# kept; without an entry for k, the bucket as it was
def bexp.go(-V: Data, +k: String, +e: Nat, b: Trie<V>, same: Bool) -> Trie<V>:
  match b same:
    case Ent{key, val, ex, rest} True{}:
      Ent{key, val, e, rest}
    case Ent{key, val, ex, +rest} False{}:
      s = bhead(V, k, rest)
      Ent{key, val, ex, bexp.go(V, k, e, rest, s)}
    case other _:
      other

def bexp(-V: Data, +k: String, +e: Nat, +b: Trie<V>) -> Trie<V>:
  s = bhead(V, k, b)
  bexp.go(V, k, e, b, s)

# the bucket without any entry for k; its end goes back, as in bset.go
def bdel.go(-V: Data, +k: String, b: Trie<V>, same: Bool) -> Trie<V>:
  match b same:
    case Ent{key, val, ex, +rest} True{}:
      s = bhead(V, k, rest)
      bdel.go(V, k, rest, s)
    case Ent{key, val, ex, +rest} False{}:
      s = bhead(V, k, rest)
      Ent{key, val, ex, bdel.go(V, k, rest, s)}
    case other _:
      other

def bdel(-V: Data, +k: String, +b: Trie<V>) -> Trie<V>:
  s = bhead(V, k, b)
  bdel.go(V, k, b, s)

# a hint for a read of a bucket (Mem.prefetch): acc, after starting to
# load the key and the value of its first entry
def btouch(-V: Data, b: Trie<V>, acc: U32) -> U32:
  match b:
    case Ent{key, v, e, rest}:
      Mem.prefetch(String, key, Mem.prefetch(V, v, acc))
    case other:
      acc

def bapply(-V: Data, op: Op<V>, b: Trie<V>) -> Trie<V>:
  match op:
    case OSet{k, v, e}:
      bset(V, k, v, e, b)
    case OKeep{k, v}:
      bkeep(V, k, v, b)
    case OExp{k, e}:
      bexp(V, k, e, b)
    case ODel{k}:
      bdel(V, k, b)

# Tries
# -----

# BEGIN gen_trie: walks
# the bucket where a walk of depth d ends: x is the digit of h that it
# takes first. get walks with tget_k, which reads the bucket where it
# ends, so the walk only reads the trie; tget_h is its spec
# (PROOF.bend: tget_k_eq). A walk looks at the node before the digit,
# so an empty subtrie ends it whatever the digit.
def tget_h(-V: Data, d: Nat, t: Trie<V>, x: Hex, +h: U32) -> Trie<V>:
  match d t x:
    case 0n t0 _:
      t0
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H0{}:
      tget_h(V, p, c0, hex(shr4(h)), shr4(h))
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H1{}:
      tget_h(V, p, c1, hex(shr4(h)), shr4(h))
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H2{}:
      tget_h(V, p, c2, hex(shr4(h)), shr4(h))
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H3{}:
      tget_h(V, p, c3, hex(shr4(h)), shr4(h))
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H4{}:
      tget_h(V, p, c4, hex(shr4(h)), shr4(h))
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H5{}:
      tget_h(V, p, c5, hex(shr4(h)), shr4(h))
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H6{}:
      tget_h(V, p, c6, hex(shr4(h)), shr4(h))
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H7{}:
      tget_h(V, p, c7, hex(shr4(h)), shr4(h))
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H8{}:
      tget_h(V, p, c8, hex(shr4(h)), shr4(h))
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H9{}:
      tget_h(V, p, c9, hex(shr4(h)), shr4(h))
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H10{}:
      tget_h(V, p, c10, hex(shr4(h)), shr4(h))
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H11{}:
      tget_h(V, p, c11, hex(shr4(h)), shr4(h))
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H12{}:
      tget_h(V, p, c12, hex(shr4(h)), shr4(h))
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H13{}:
      tget_h(V, p, c13, hex(shr4(h)), shr4(h))
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H14{}:
      tget_h(V, p, c14, hex(shr4(h)), shr4(h))
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H15{}:
      tget_h(V, p, c15, hex(shr4(h)), shr4(h))
    case 1n+p other _:
      Tip{}

def tget_k(-V: Data, d: Nat, t: Trie<V>, x: Hex, +h: U32, +k: String) -> Maybe<&2, V>:
  match d t x:
    case 0n t0 _:
      bget(V, k, t0)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H0{}:
      tget_k(V, p, c0, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H1{}:
      tget_k(V, p, c1, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H2{}:
      tget_k(V, p, c2, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H3{}:
      tget_k(V, p, c3, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H4{}:
      tget_k(V, p, c4, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H5{}:
      tget_k(V, p, c5, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H6{}:
      tget_k(V, p, c6, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H7{}:
      tget_k(V, p, c7, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H8{}:
      tget_k(V, p, c8, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H9{}:
      tget_k(V, p, c9, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H10{}:
      tget_k(V, p, c10, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H11{}:
      tget_k(V, p, c11, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H12{}:
      tget_k(V, p, c12, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H13{}:
      tget_k(V, p, c13, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H14{}:
      tget_k(V, p, c14, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H15{}:
      tget_k(V, p, c15, hex(shr4(h)), shr4(h), k)
    case 1n+p other _:
      None{}

# tget_k answering the code of k's entry (bcode): 0 when there is none,
# else 1 plus the time it expires at (a write that counts the keys asks
# it first)
def tget_kx(-V: Data, d: Nat, +t: Trie<V>, x: Hex, +h: U32, +k: String) -> Nat:
  match d t x:
    case 0n t0 _:
      bcode(V, k, t0)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H0{}:
      tget_kx(V, p, c0, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H1{}:
      tget_kx(V, p, c1, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H2{}:
      tget_kx(V, p, c2, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H3{}:
      tget_kx(V, p, c3, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H4{}:
      tget_kx(V, p, c4, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H5{}:
      tget_kx(V, p, c5, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H6{}:
      tget_kx(V, p, c6, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H7{}:
      tget_kx(V, p, c7, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H8{}:
      tget_kx(V, p, c8, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H9{}:
      tget_kx(V, p, c9, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H10{}:
      tget_kx(V, p, c10, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H11{}:
      tget_kx(V, p, c11, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H12{}:
      tget_kx(V, p, c12, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H13{}:
      tget_kx(V, p, c13, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H14{}:
      tget_kx(V, p, c14, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H15{}:
      tget_kx(V, p, c15, hex(shr4(h)), shr4(h), k)
    case 1n+p other _:
      0n

# tget_k answering k's entry, its value and its time (bent)
def tget_ke(-V: Data, d: Nat, +t: Trie<V>, x: Hex, +h: U32, +k: String) -> Maybe<&2, Item<V>>:
  match d t x:
    case 0n t0 _:
      bent(V, k, t0)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H0{}:
      tget_ke(V, p, c0, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H1{}:
      tget_ke(V, p, c1, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H2{}:
      tget_ke(V, p, c2, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H3{}:
      tget_ke(V, p, c3, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H4{}:
      tget_ke(V, p, c4, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H5{}:
      tget_ke(V, p, c5, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H6{}:
      tget_ke(V, p, c6, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H7{}:
      tget_ke(V, p, c7, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H8{}:
      tget_ke(V, p, c8, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H9{}:
      tget_ke(V, p, c9, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H10{}:
      tget_ke(V, p, c10, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H11{}:
      tget_ke(V, p, c11, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H12{}:
      tget_ke(V, p, c12, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H13{}:
      tget_ke(V, p, c13, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H14{}:
      tget_ke(V, p, c14, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H15{}:
      tget_ke(V, p, c15, hex(shr4(h)), shr4(h), k)
    case 1n+p other _:
      None{}

# tget_k answering the value when the key is there at now (blive)
def tget_kl(-V: Data, d: Nat, +t: Trie<V>, x: Hex, +h: U32, +k: String, +now: Nat) -> Maybe<&2, V>:
  match d t x:
    case 0n t0 _:
      blive(V, k, t0, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H0{}:
      tget_kl(V, p, c0, hex(shr4(h)), shr4(h), k, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H1{}:
      tget_kl(V, p, c1, hex(shr4(h)), shr4(h), k, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H2{}:
      tget_kl(V, p, c2, hex(shr4(h)), shr4(h), k, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H3{}:
      tget_kl(V, p, c3, hex(shr4(h)), shr4(h), k, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H4{}:
      tget_kl(V, p, c4, hex(shr4(h)), shr4(h), k, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H5{}:
      tget_kl(V, p, c5, hex(shr4(h)), shr4(h), k, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H6{}:
      tget_kl(V, p, c6, hex(shr4(h)), shr4(h), k, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H7{}:
      tget_kl(V, p, c7, hex(shr4(h)), shr4(h), k, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H8{}:
      tget_kl(V, p, c8, hex(shr4(h)), shr4(h), k, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H9{}:
      tget_kl(V, p, c9, hex(shr4(h)), shr4(h), k, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H10{}:
      tget_kl(V, p, c10, hex(shr4(h)), shr4(h), k, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H11{}:
      tget_kl(V, p, c11, hex(shr4(h)), shr4(h), k, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H12{}:
      tget_kl(V, p, c12, hex(shr4(h)), shr4(h), k, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H13{}:
      tget_kl(V, p, c13, hex(shr4(h)), shr4(h), k, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H14{}:
      tget_kl(V, p, c14, hex(shr4(h)), shr4(h), k, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H15{}:
      tget_kl(V, p, c15, hex(shr4(h)), shr4(h), k, now)
    case 1n+p other _:
      None{}

# tget_kl for the keys' values, answering a copy of a string (bget_c)
def tget_kc(d: Nat, +t: Trie<Val>, x: Hex, +h: U32, +k: String, +now: Nat) -> Got:
  match d t x:
    case 0n t0 _:
      bget_c(k, t0, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H0{}:
      tget_kc(p, c0, hex(shr4(h)), shr4(h), k, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H1{}:
      tget_kc(p, c1, hex(shr4(h)), shr4(h), k, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H2{}:
      tget_kc(p, c2, hex(shr4(h)), shr4(h), k, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H3{}:
      tget_kc(p, c3, hex(shr4(h)), shr4(h), k, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H4{}:
      tget_kc(p, c4, hex(shr4(h)), shr4(h), k, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H5{}:
      tget_kc(p, c5, hex(shr4(h)), shr4(h), k, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H6{}:
      tget_kc(p, c6, hex(shr4(h)), shr4(h), k, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H7{}:
      tget_kc(p, c7, hex(shr4(h)), shr4(h), k, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H8{}:
      tget_kc(p, c8, hex(shr4(h)), shr4(h), k, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H9{}:
      tget_kc(p, c9, hex(shr4(h)), shr4(h), k, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H10{}:
      tget_kc(p, c10, hex(shr4(h)), shr4(h), k, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H11{}:
      tget_kc(p, c11, hex(shr4(h)), shr4(h), k, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H12{}:
      tget_kc(p, c12, hex(shr4(h)), shr4(h), k, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H13{}:
      tget_kc(p, c13, hex(shr4(h)), shr4(h), k, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H14{}:
      tget_kc(p, c14, hex(shr4(h)), shr4(h), k, now)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H15{}:
      tget_kc(p, c15, hex(shr4(h)), shr4(h), k, now)
    case 1n+p other _:
      GNone{}

# hints for a walk to come (Mem.prefetch): ttouch is acc, after starting
# to load the subtrie where a walk of depth d ends (a bucket at depth
# 5); tetouch is acc, after starting to load the key and the value of
# the first entry of that bucket. Each reads the nodes above, which a
# pass over many keys keeps in the cache, and changes nothing.
def ttouch(-V: Data, d: Nat, t: Trie<V>, x: Hex, +h: U32, acc: U32) -> U32:
  match d t x:
    case 0n t0 _:
      Mem.prefetch(Trie<V>, t0, acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H0{}:
      ttouch(V, p, c0, hex(shr4(h)), shr4(h), acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H1{}:
      ttouch(V, p, c1, hex(shr4(h)), shr4(h), acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H2{}:
      ttouch(V, p, c2, hex(shr4(h)), shr4(h), acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H3{}:
      ttouch(V, p, c3, hex(shr4(h)), shr4(h), acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H4{}:
      ttouch(V, p, c4, hex(shr4(h)), shr4(h), acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H5{}:
      ttouch(V, p, c5, hex(shr4(h)), shr4(h), acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H6{}:
      ttouch(V, p, c6, hex(shr4(h)), shr4(h), acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H7{}:
      ttouch(V, p, c7, hex(shr4(h)), shr4(h), acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H8{}:
      ttouch(V, p, c8, hex(shr4(h)), shr4(h), acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H9{}:
      ttouch(V, p, c9, hex(shr4(h)), shr4(h), acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H10{}:
      ttouch(V, p, c10, hex(shr4(h)), shr4(h), acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H11{}:
      ttouch(V, p, c11, hex(shr4(h)), shr4(h), acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H12{}:
      ttouch(V, p, c12, hex(shr4(h)), shr4(h), acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H13{}:
      ttouch(V, p, c13, hex(shr4(h)), shr4(h), acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H14{}:
      ttouch(V, p, c14, hex(shr4(h)), shr4(h), acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H15{}:
      ttouch(V, p, c15, hex(shr4(h)), shr4(h), acc)
    case 1n+p other _:
      acc

def tetouch(-V: Data, d: Nat, t: Trie<V>, x: Hex, +h: U32, acc: U32) -> U32:
  match d t x:
    case 0n t0 _:
      btouch(V, t0, acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H0{}:
      tetouch(V, p, c0, hex(shr4(h)), shr4(h), acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H1{}:
      tetouch(V, p, c1, hex(shr4(h)), shr4(h), acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H2{}:
      tetouch(V, p, c2, hex(shr4(h)), shr4(h), acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H3{}:
      tetouch(V, p, c3, hex(shr4(h)), shr4(h), acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H4{}:
      tetouch(V, p, c4, hex(shr4(h)), shr4(h), acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H5{}:
      tetouch(V, p, c5, hex(shr4(h)), shr4(h), acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H6{}:
      tetouch(V, p, c6, hex(shr4(h)), shr4(h), acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H7{}:
      tetouch(V, p, c7, hex(shr4(h)), shr4(h), acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H8{}:
      tetouch(V, p, c8, hex(shr4(h)), shr4(h), acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H9{}:
      tetouch(V, p, c9, hex(shr4(h)), shr4(h), acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H10{}:
      tetouch(V, p, c10, hex(shr4(h)), shr4(h), acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H11{}:
      tetouch(V, p, c11, hex(shr4(h)), shr4(h), acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H12{}:
      tetouch(V, p, c12, hex(shr4(h)), shr4(h), acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H13{}:
      tetouch(V, p, c13, hex(shr4(h)), shr4(h), acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H14{}:
      tetouch(V, p, c14, hex(shr4(h)), shr4(h), acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H15{}:
      tetouch(V, p, c15, hex(shr4(h)), shr4(h), acc)
    case 1n+p other _:
      acc

# the trie with op applied to the bucket where the walk ends. A node
# that a delete leaves without entries stays: at most 69905 of them,
# 9MB, for the 2^20 buckets.
def tmod_h(-V: Data, d: Nat, t: Trie<V>, x: Hex, +h: U32, op: Op<V>) -> Trie<V>:
  match d t x:
    case 0n t0 _:
      bapply(V, op, t0)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H0{}:
      Node{tmod_h(V, p, c0, hex(shr4(h)), shr4(h), op), c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H1{}:
      Node{c0, tmod_h(V, p, c1, hex(shr4(h)), shr4(h), op), c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H2{}:
      Node{c0, c1, tmod_h(V, p, c2, hex(shr4(h)), shr4(h), op), c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H3{}:
      Node{c0, c1, c2, tmod_h(V, p, c3, hex(shr4(h)), shr4(h), op), c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H4{}:
      Node{c0, c1, c2, c3, tmod_h(V, p, c4, hex(shr4(h)), shr4(h), op), c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H5{}:
      Node{c0, c1, c2, c3, c4, tmod_h(V, p, c5, hex(shr4(h)), shr4(h), op), c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H6{}:
      Node{c0, c1, c2, c3, c4, c5, tmod_h(V, p, c6, hex(shr4(h)), shr4(h), op), c7, c8, c9, c10, c11, c12, c13, c14, c15}
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H7{}:
      Node{c0, c1, c2, c3, c4, c5, c6, tmod_h(V, p, c7, hex(shr4(h)), shr4(h), op), c8, c9, c10, c11, c12, c13, c14, c15}
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H8{}:
      Node{c0, c1, c2, c3, c4, c5, c6, c7, tmod_h(V, p, c8, hex(shr4(h)), shr4(h), op), c9, c10, c11, c12, c13, c14, c15}
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H9{}:
      Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, tmod_h(V, p, c9, hex(shr4(h)), shr4(h), op), c10, c11, c12, c13, c14, c15}
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H10{}:
      Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, tmod_h(V, p, c10, hex(shr4(h)), shr4(h), op), c11, c12, c13, c14, c15}
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H11{}:
      Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, tmod_h(V, p, c11, hex(shr4(h)), shr4(h), op), c12, c13, c14, c15}
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H12{}:
      Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, tmod_h(V, p, c12, hex(shr4(h)), shr4(h), op), c13, c14, c15}
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H13{}:
      Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, tmod_h(V, p, c13, hex(shr4(h)), shr4(h), op), c14, c15}
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H14{}:
      Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, tmod_h(V, p, c14, hex(shr4(h)), shr4(h), op), c15}
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H15{}:
      Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, tmod_h(V, p, c15, hex(shr4(h)), shr4(h), op)}
    case 1n+p other H0{}:
      Node{tmod_h(V, p, Tip{}, hex(shr4(h)), shr4(h), op), Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}}
    case 1n+p other H1{}:
      Node{Tip{}, tmod_h(V, p, Tip{}, hex(shr4(h)), shr4(h), op), Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}}
    case 1n+p other H2{}:
      Node{Tip{}, Tip{}, tmod_h(V, p, Tip{}, hex(shr4(h)), shr4(h), op), Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}}
    case 1n+p other H3{}:
      Node{Tip{}, Tip{}, Tip{}, tmod_h(V, p, Tip{}, hex(shr4(h)), shr4(h), op), Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}}
    case 1n+p other H4{}:
      Node{Tip{}, Tip{}, Tip{}, Tip{}, tmod_h(V, p, Tip{}, hex(shr4(h)), shr4(h), op), Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}}
    case 1n+p other H5{}:
      Node{Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, tmod_h(V, p, Tip{}, hex(shr4(h)), shr4(h), op), Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}}
    case 1n+p other H6{}:
      Node{Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, tmod_h(V, p, Tip{}, hex(shr4(h)), shr4(h), op), Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}}
    case 1n+p other H7{}:
      Node{Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, tmod_h(V, p, Tip{}, hex(shr4(h)), shr4(h), op), Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}}
    case 1n+p other H8{}:
      Node{Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, tmod_h(V, p, Tip{}, hex(shr4(h)), shr4(h), op), Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}}
    case 1n+p other H9{}:
      Node{Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, tmod_h(V, p, Tip{}, hex(shr4(h)), shr4(h), op), Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}}
    case 1n+p other H10{}:
      Node{Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, tmod_h(V, p, Tip{}, hex(shr4(h)), shr4(h), op), Tip{}, Tip{}, Tip{}, Tip{}, Tip{}}
    case 1n+p other H11{}:
      Node{Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, tmod_h(V, p, Tip{}, hex(shr4(h)), shr4(h), op), Tip{}, Tip{}, Tip{}, Tip{}}
    case 1n+p other H12{}:
      Node{Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, tmod_h(V, p, Tip{}, hex(shr4(h)), shr4(h), op), Tip{}, Tip{}, Tip{}}
    case 1n+p other H13{}:
      Node{Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, tmod_h(V, p, Tip{}, hex(shr4(h)), shr4(h), op), Tip{}, Tip{}}
    case 1n+p other H14{}:
      Node{Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, tmod_h(V, p, Tip{}, hex(shr4(h)), shr4(h), op), Tip{}}
    case 1n+p other H15{}:
      Node{Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, tmod_h(V, p, Tip{}, hex(shr4(h)), shr4(h), op)}
# END gen_trie: walks

# Folds
# -----

# BEGIN gen_trie: folds
# the keys of t there at now, before acc; and how many entries t holds
def tkeys(-V: Data, t: Trie<V>, +now: Nat, acc: List<&2, String>) -> List<&2, String>:
  match t:
    case Tip{}:
      acc
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}:
      tkeys(V, c0, now, tkeys(V, c1, now, tkeys(V, c2, now, tkeys(V, c3, now, tkeys(V, c4, now, tkeys(V, c5, now, tkeys(V, c6, now, tkeys(V, c7, now, tkeys(V, c8, now, tkeys(V, c9, now, tkeys(V, c10, now, tkeys(V, c11, now, tkeys(V, c12, now, tkeys(V, c13, now, tkeys(V, c14, now, tkeys(V, c15, now, acc))))))))))))))))
    case Ent{k, v, +e, rest}:
      kput(live(now, e), k, tkeys(V, rest, now, acc))

def tsize(-V: Data, t: Trie<V>) -> Nat:
  match t:
    case Tip{}:
      0n
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}:
      Nat.add(tsize(V, c0), Nat.add(tsize(V, c1), Nat.add(tsize(V, c2), Nat.add(tsize(V, c3), Nat.add(tsize(V, c4), Nat.add(tsize(V, c5), Nat.add(tsize(V, c6), Nat.add(tsize(V, c7), Nat.add(tsize(V, c8), Nat.add(tsize(V, c9), Nat.add(tsize(V, c10), Nat.add(tsize(V, c11), Nat.add(tsize(V, c12), Nat.add(tsize(V, c13), Nat.add(tsize(V, c14), tsize(V, c15))))))))))))))))
    case Ent{k, v, e, rest}:
      1n+tsize(V, rest)
# END gen_trie: folds

# Scans
# -----
# SCAN and RANDOMKEY read the buckets in the order of their paths: a
# bucket's index is its path read as five hex digits, the first digit the
# highest, so the trie is buckets 0 to 2^20 - 1 in order (tkeys's order).
# A scan from index from reads the buckets from it on until it has found
# want keys (a bucket is read whole), and says where to go on: Stop with
# the index of the next bucket, or Scan when it read to the end. The trie
# never rehashes, so a key that stays in the map from the first scan of
# an iteration to its last is found by one of them. A subtrie that lies
# before the cursor, or at or past the bound to (RANDOMKEY's), is
# skipped whole. The sweep of expired keys (reap) scans the same way for
# the keys whose time has passed (dead).
type Scan is Data:
  Scan{want: Nat, acc: List<&2, String>}
  Stop{at: Nat, acc: List<&2, String>}

def bscan.end(done: Bool, +base: Nat, want: Nat, acc: List<&2, String>) -> Scan:
  match done:
    case True{}:
      Stop{Nat.add(base, 1n), acc}
    case False{}:
      Scan{want, acc}

# the keys of the bucket b of index base that are there at now (or, when
# dead, whose time has passed), before acc, counted off want: every entry
# when all (SCAN's COUNT bounds the entries it reads, as Redis's bounds
# the work; and so the sweep's), else the keys taken only (RANDOMKEY's
# window)
def bscan(-V: Data, +b: Trie<V>, +base: Nat, +want: Nat, acc: List<&2, String>, +now: Nat, +all: Bool, +dead: Bool) -> Scan:
  match b:
    case Ent{+k, v, +e, +rest}:
      +ok = Bool.xor(live(now, e), dead)
      bscan(V, rest, base, Nat.sub(want, Bool.pick(Nat, Bool.or(all, ok), 1n, 0n)), kput(ok, k, acc), now, all, dead)
    case _:
      bscan.end(Nat.is_eq(want, 0n), base, want, acc)

# BEGIN gen_trie: scan
def tscan(-V: Data, +d: Nat, +t: Trie<V>, skip: Bool, +base: Nat, +span: Nat, +from: Nat, +to: Nat, +now: Nat, +all: Bool, +dead: Bool, s: Scan) -> Scan:
  match d t skip s:
    case _ _ True{} s:
      s
    case _ _ False{} Stop{at, acc}:
      Stop{at, acc}
    case 0n b False{} Scan{want, acc}:
      bscan(V, b, base, want, acc, now, all, dead)
    case 1n+p Tip{} False{} s:
      s
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} False{} s:
      +q = Nat.div(span, 16n)
      tscan(V, p, c15, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(16n, q)), from), Nat.is_le(to, Nat.add(base, Nat.mul(15n, q)))), Nat.add(base, Nat.mul(15n, q)), q, from, to, now, all, dead, tscan(V, p, c14, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(15n, q)), from), Nat.is_le(to, Nat.add(base, Nat.mul(14n, q)))), Nat.add(base, Nat.mul(14n, q)), q, from, to, now, all, dead, tscan(V, p, c13, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(14n, q)), from), Nat.is_le(to, Nat.add(base, Nat.mul(13n, q)))), Nat.add(base, Nat.mul(13n, q)), q, from, to, now, all, dead, tscan(V, p, c12, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(13n, q)), from), Nat.is_le(to, Nat.add(base, Nat.mul(12n, q)))), Nat.add(base, Nat.mul(12n, q)), q, from, to, now, all, dead, tscan(V, p, c11, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(12n, q)), from), Nat.is_le(to, Nat.add(base, Nat.mul(11n, q)))), Nat.add(base, Nat.mul(11n, q)), q, from, to, now, all, dead, tscan(V, p, c10, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(11n, q)), from), Nat.is_le(to, Nat.add(base, Nat.mul(10n, q)))), Nat.add(base, Nat.mul(10n, q)), q, from, to, now, all, dead, tscan(V, p, c9, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(10n, q)), from), Nat.is_le(to, Nat.add(base, Nat.mul(9n, q)))), Nat.add(base, Nat.mul(9n, q)), q, from, to, now, all, dead, tscan(V, p, c8, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(9n, q)), from), Nat.is_le(to, Nat.add(base, Nat.mul(8n, q)))), Nat.add(base, Nat.mul(8n, q)), q, from, to, now, all, dead, tscan(V, p, c7, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(8n, q)), from), Nat.is_le(to, Nat.add(base, Nat.mul(7n, q)))), Nat.add(base, Nat.mul(7n, q)), q, from, to, now, all, dead, tscan(V, p, c6, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(7n, q)), from), Nat.is_le(to, Nat.add(base, Nat.mul(6n, q)))), Nat.add(base, Nat.mul(6n, q)), q, from, to, now, all, dead, tscan(V, p, c5, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(6n, q)), from), Nat.is_le(to, Nat.add(base, Nat.mul(5n, q)))), Nat.add(base, Nat.mul(5n, q)), q, from, to, now, all, dead, tscan(V, p, c4, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(5n, q)), from), Nat.is_le(to, Nat.add(base, Nat.mul(4n, q)))), Nat.add(base, Nat.mul(4n, q)), q, from, to, now, all, dead, tscan(V, p, c3, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(4n, q)), from), Nat.is_le(to, Nat.add(base, Nat.mul(3n, q)))), Nat.add(base, Nat.mul(3n, q)), q, from, to, now, all, dead, tscan(V, p, c2, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(3n, q)), from), Nat.is_le(to, Nat.add(base, Nat.mul(2n, q)))), Nat.add(base, Nat.mul(2n, q)), q, from, to, now, all, dead, tscan(V, p, c1, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(2n, q)), from), Nat.is_le(to, Nat.add(base, Nat.mul(1n, q)))), Nat.add(base, Nat.mul(1n, q)), q, from, to, now, all, dead, tscan(V, p, c0, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(1n, q)), from), Nat.is_le(to, base)), base, q, from, to, now, all, dead, s))))))))))))))))
    case 1n+p Ent{k, v, e, rest} False{} s:
      s
# END gen_trie: scan

# Random picks
# ------------
# RANDOMKEY's key, as Redis's dictGetFairRandomKey picks one: the keys of
# the buckets from a random one on, 16 of them at least (past the last
# bucket, from the first one up to the random one), and of those one, each
# as likely. A key is about as likely as another (as Redis's are): as
# likely as the buckets before it and the 15 keys before it are many.

# murmur3's finalizer: each bit of h changes each bit of the result
def mix(+h: U32) -> U32:
  +a = U32.mul(U32.xor(h, U32.shrn(h, 16n)), 2246822507)
  +b = U32.mul(U32.xor(a, U32.shrn(a, 13n)), 3266489909)
  U32.xor(b, U32.shrn(b, 16n))

def nth(+ks: List<&2, String>, i: Nat) -> Maybe<&2, String>:
  match ks i:
    case Con{+k, +rest} 0n:
      Some{k}
    case Con{+k, +rest} 1n+j:
      nth(rest, j)
    case Nil{} _:
      None{}

# one of the keys ks, by r
def pick.of(+ks: List<&2, String>, +r: U32) -> Maybe<&2, String>:
  nth(ks, Nat.mod(U32.to_nat(r), Nat.max(List.length(&2, String, ks), 1n)))

def scan.acc(s: Scan) -> List<&2, String>:
  match s:
    case Scan{want, acc}:
      acc
    case Stop{at, acc}:
      acc

# the keys a scan from bucket b found, with those from the first bucket
# up to b when it ran past the last one before it found enough
def pick.wrap(-V: Data, +t: Trie<V>, +b: Nat, +r: U32, +now: Nat, s: Scan) -> Maybe<&2, String>:
  match s:
    case Stop{at, acc}:
      pick.of(acc, r)
    case Scan{want, acc}:
      pick.of(scan.acc(tscan(V, 5n, t, False{}, 0n, 1048576n, 0n, b, now, False{}, False{}, Scan{want, acc})), r)

# API
# ---
# A key's entry is its value and the time it expires at (0: never); the
# laws of the map speak of entries (entry). A key is there at now when its
# entry is and has not expired (live): read, live.at and get_copy read
# only such keys, get any. Writes set the time (set.at: none; setx.at: e),
# keep it (keep.at) or change it alone (expire.at).

def empty(-V: Data) -> Trie<V>:
  Tip{}

# Hints for walks to come, for a pass over many keys before they are read
# or written: each is acc, and starts loading one more level of the path
# of h (Mem.prefetch): the node at depth d (touch.node; the bucket at depth
# 5), or the key and the value of the first entry of h's bucket
# (touch.entry). Run over all the keys of a batch, one level at a time,
# their cache misses overlap.
def touch.node(-V: Data, t: Trie<V>, +h: U32, d: Nat, acc: U32) -> U32:
  ttouch(V, d, t, hex(h), h, acc)

def touch.entry(-V: Data, t: Trie<V>, +h: U32, acc: U32) -> U32:
  tetouch(V, 5n, t, hex(h), h, acc)

def entry(-V: Data, t: Trie<V>, +k: String) -> Maybe<&2, Item<V>>:
  +h = hash(k)
  bent(V, k, tget_h(V, 5n, t, hex(h), h))

# k's entry, h being k's hash
def entry.at(-V: Data, +t: Trie<V>, +k: String, +h: U32) -> Maybe<&2, Item<V>>:
  tget_ke(V, 5n, t, hex(h), h, k)

def get.at(-V: Data, t: Trie<V>, +k: String, +h: U32) -> Maybe<&2, V>:
  tget_k(V, 5n, t, hex(h), h, k)

def get(-V: Data, t: Trie<V>, +k: String) -> Maybe<&2, V>:
  get.at(V, t, k, hash(k))

# whether t holds k, there at now or not
def has(-V: Data, t: Trie<V>, k: String) -> Bool:
  Maybe.is_some(&2, V, get(V, t, k))

# the code of k's entry, h being k's hash: 0 when t does not hold k, else
# 1 plus the time it expires at (a write that counts the keys asks it
# first)
def code.at(-V: Data, +t: Trie<V>, +k: String, +h: U32) -> Nat:
  tget_kx(V, 5n, t, hex(h), h, k)

# the value of k when it is there at now
def live.at(-V: Data, +t: Trie<V>, +k: String, +h: U32, +now: Nat) -> Maybe<&2, V>:
  tget_kl(V, 5n, t, hex(h), h, k, now)

def read(-V: Data, +t: Trie<V>, +k: String, +now: Nat) -> Maybe<&2, V>:
  live.at(V, t, k, hash(k), now)

# read for the keys' values, answering a copy of a string (bget_c): GET
# reads with it, so the value a read finds stays unshared in the trie
def get_copy.at(+t: Trie<Val>, +k: String, +h: U32, +now: Nat) -> Got:
  tget_kc(5n, t, hex(h), h, k, now)

def get_copy(+t: Trie<Val>, +k: String, +now: Nat) -> Got:
  get_copy.at(t, k, hash(k), now)

def set.at(-V: Data, t: Trie<V>, +k: String, v: V, +h: U32) -> Trie<V>:
  tmod_h(V, 5n, t, hex(h), h, OSet{k, v, 0n})

def set(-V: Data, t: Trie<V>, +k: String, v: V) -> Trie<V>:
  set.at(V, t, k, v, hash(k))

def setx.at(-V: Data, t: Trie<V>, +k: String, v: V, +e: Nat, +h: U32) -> Trie<V>:
  tmod_h(V, 5n, t, hex(h), h, OSet{k, v, e})

def setx(-V: Data, t: Trie<V>, +k: String, v: V, +e: Nat) -> Trie<V>:
  setx.at(V, t, k, v, e, hash(k))

def keep.at(-V: Data, t: Trie<V>, +k: String, v: V, +h: U32) -> Trie<V>:
  tmod_h(V, 5n, t, hex(h), h, OKeep{k, v})

def keep(-V: Data, t: Trie<V>, +k: String, v: V) -> Trie<V>:
  keep.at(V, t, k, v, hash(k))

def expire.at(-V: Data, t: Trie<V>, +k: String, +e: Nat, +h: U32) -> Trie<V>:
  tmod_h(V, 5n, t, hex(h), h, OExp{k, e})

def expire(-V: Data, t: Trie<V>, +k: String, +e: Nat) -> Trie<V>:
  expire.at(V, t, k, e, hash(k))

def del.at(-V: Data, t: Trie<V>, +k: String, +h: U32) -> Trie<V>:
  tmod_h(V, 5n, t, hex(h), h, ODel{k})

def del(-V: Data, t: Trie<V>, +k: String) -> Trie<V>:
  del.at(V, t, k, hash(k))

# the keys there at now
def keys(-V: Data, t: Trie<V>, +now: Nat) -> List<&2, String>:
  tkeys(V, t, now, Nil{})

# how many entries t holds, there at now or not
def size(-V: Data, t: Trie<V>) -> Nat:
  tsize(V, t)

# the keys there at now of the buckets from index from on, until want
# entries are read (Scans); the keys newest first
def scan(-V: Data, +t: Trie<V>, +from: Nat, want: Nat, +now: Nat) -> Scan:
  tscan(V, 5n, t, False{}, 0n, 1048576n, from, 1048576n, now, True{}, False{}, Scan{want, Nil{}})

# the keys whose time has passed at now of the buckets from index from
# on, until want entries are read (the sweep of expired keys)
def reap(-V: Data, +t: Trie<V>, +from: Nat, want: Nat, +now: Nat) -> Scan:
  tscan(V, 5n, t, False{}, 0n, 1048576n, from, 1048576n, now, True{}, True{}, Scan{want, Nil{}})

# a key of t there at now, by r (Random picks), None when there is none
def pick(-V: Data, +t: Trie<V>, +r: U32, +now: Nat) -> Maybe<&2, String>:
  +b = U32.to_nat(U32.and(r, 1048575))
  pick.wrap(V, t, b, mix(r), now, tscan(V, 5n, t, False{}, 0n, 1048576n, b, 1048576n, now, False{}, False{}, Scan{16n, Nil{}}))

# Hashes
# ------
# A hash's fields and values (Hash, above): a small one is a list of its
# pairs in the order they came, a large one a trie of its fields, each
# with no time. Redis 7.0 keeps a hash as a listpack while it holds at
# most hash-max-listpack-entries pairs (512), each of at most
# hash-max-listpack-value bytes (64), and as a hashtable from the first
# write that passes either, for good. BendKV turns a small hash into a
# large one at those defaults, whatever the parameters say, so that the
# hash a history of writes leaves depends on the writes alone (the
# append-only file makes it again on any server); OBJECT ENCODING reads
# the parameters as they are (session.bend).

# whether the first pair of ps is f's
def hps.head(+f: String, ps: List<&2, HPair>) -> Bool:
  match ps:
    case Con{HP{g, v}, rest}:
      str_eq(f, g)
    case Nil{}:
      False{}

# f's value; same is hps.head(f, ps), computed before ps is passed on
def hps.get.go(+f: String, ps: List<&2, HPair>, same: Bool) -> Maybe<&2, String>:
  match ps same:
    case Con{HP{g, v}, rest} True{}:
      Some{v}
    case Con{p, +rest} False{}:
      s = hps.head(f, rest)
      hps.get.go(f, rest, s)
    case Nil{} _:
      None{}

def hps.get(+f: String, +ps: List<&2, HPair>) -> Maybe<&2, String>:
  s = hps.head(f, ps)
  hps.get.go(f, ps, s)

# the pairs with f's value set to v: in its place when f is there, else
# last
def hps.put.go(+f: String, +v: String, ps: List<&2, HPair>, same: Bool) -> List<&2, HPair>:
  match ps same:
    case Con{HP{g, w}, rest} True{}:
      Con{HP{g, v}, rest}
    case Con{p, +rest} False{}:
      s = hps.head(f, rest)
      Con{p, hps.put.go(f, v, rest, s)}
    case Nil{} _:
      [HP{f, v}]

def hps.put(+f: String, +v: String, +ps: List<&2, HPair>) -> List<&2, HPair>:
  s = hps.head(f, ps)
  hps.put.go(f, v, ps, s)

# the pairs without f's
def hps.del.go(+f: String, ps: List<&2, HPair>, same: Bool) -> List<&2, HPair>:
  match ps same:
    case Con{p, rest} True{}:
      rest
    case Con{p, +rest} False{}:
      s = hps.head(f, rest)
      Con{p, hps.del.go(f, rest, s)}
    case Nil{} _:
      Nil{}

def hps.del(+f: String, +ps: List<&2, HPair>) -> List<&2, HPair>:
  s = hps.head(f, ps)
  hps.del.go(f, ps, s)

# the pairs ps added to the trie t
def hps.trie(ps: List<&2, HPair>, t: Trie<String>) -> Trie<String>:
  match ps:
    case Nil{}:
      t
    case Con{HP{f, v}, rest}:
      hps.trie(rest, set(String, t, f, v))

# the length of the longest field or value of ps, at least m
def hps.widest(ps: List<&2, HPair>, +m: Nat) -> Nat:
  match ps:
    case Nil{}:
      m
    case Con{HP{f, v}, rest}:
      hps.widest(rest, Nat.max(m, Nat.max(String.length(f), String.length(v))))

def hash.or(m: Maybe<&2, String>) -> String:
  match m:
    case Some{v}:
      v
    case None{}:
      ""

# the pairs of the fields ks of a large hash, in their order
def hash.kv(+t: Trie<String>, ks: List<&2, String>) -> List<&2, HPair>:
  match ks:
    case Nil{}:
      Nil{}
    case Con{+k, rest}:
      HP{k, hash.or(get(String, t, k))} <> hash.kv(t, rest)

def hash.empty() -> Hash:
  HSmall{0n, Nil{}}

def hash.len(+h: Hash) -> Nat:
  match h:
    case HSmall{+n, ps}:
      n
    case HBig{+n, t}:
      n

def hash.get(+f: String, +h: Hash) -> Maybe<&2, String>:
  match h:
    case HSmall{n, +ps}:
      hps.get(f, ps)
    case HBig{n, +t}:
      get(String, t, f)

def hash.has(+f: String, +h: Hash) -> Bool:
  Maybe.is_some(&2, String, hash.get(f, h))

# whether a small hash of m pairs, one of them f and v, stays small
def hash.fits(+m: Nat, +f: String, +v: String) -> Bool:
  Bool.and(Nat.is_le(m, 512n), Bool.and(Nat.is_le(String.length(f), 64n), Nat.is_le(String.length(v), 64n)))

def hash.small(fits: Bool, +m: Nat, ps: List<&2, HPair>) -> Hash:
  match fits:
    case True{}:
      HSmall{m, ps}
    case False{}:
      HBig{m, hps.trie(ps, empty(String))}

# h with f's value set to v
def hash.put(h: Hash, +f: String, +v: String) -> Hash:
  match h:
    case HSmall{+n, +ps}:
      +m = Bool.pick(Nat, Maybe.is_some(&2, String, hps.get(f, ps)), n, 1n+n)
      hash.small(hash.fits(m, f, v), m, hps.put(f, v, ps))
    case HBig{+n, +t}:
      HBig{Bool.pick(Nat, has(String, t, f), n, 1n+n), set(String, t, f, v)}

# h without f, which it holds
def hash.del(h: Hash, +f: String) -> Hash:
  match h:
    case HSmall{+n, ps}:
      HSmall{Nat.sub(n, 1n), hps.del(f, ps)}
    case HBig{+n, t}:
      HBig{Nat.sub(n, 1n), del(String, t, f)}

# the pairs of h, in its order (a small hash's, the order they came)
def hash.pairs(+h: Hash) -> List<&2, HPair>:
  match h:
    case HSmall{n, +ps}:
      ps
    case HBig{n, +t}:
      hash.kv(t, keys(String, t, 0n))

# the length of h's longest field or value
def hash.widest(+h: Hash) -> Nat:
  hps.widest(hash.pairs(h), 0n)

# Lists
# -----
# A list's elements, first to last, as Redis 7.0 keeps them in a
# quicklist (OBJECT ENCODING answers quicklist for every list). BendKV
# keeps them in two stacks (Deq): the front part in order, the back part
# reversed, so a push or a pop at either end adds or takes the head of
# one of them. When one part holds more than three times the other's
# elements and one more, the elements are dealt again, half to each
# (deq.fix): a push or a pop then costs O(1) amortized, and LINDEX and
# LRANGE walk only from the end nearer to what they read. A key never
# holds an empty list: a write that takes its last element deletes it.

def deq.empty() -> Deq:
  Deq{0n, Nil{}, 0n, Nil{}}

def deq.len(+d: Deq) -> Nat:
  match d:
    case Deq{+nf, f, +nb, b}:
      Nat.add(nf, nb)

# the elements, in order
def deq.all(+d: Deq) -> List<&2, String>:
  match d:
    case Deq{nf, +f, nb, +b}:
      List.append(&2, String, f, List.reverse(&2, String, b))

# the first n elements of xs reversed before acc, and the others
def deq.cut(n: Nat, xs: List<&2, String>, acc: List<&2, String>) -> List<&2, String> & List<&2, String>:
  match n xs:
    case 0n ys:
      (acc, ys)
    case 1n+m Con{x, rest}:
      deq.cut(m, rest, x <> acc)
    case 1n+m Nil{}:
      (acc, Nil{})

def deq.deal.of(+h: Nat, +n: Nat, p: List<&2, String> & List<&2, String>) -> Deq:
  (rf, rest) = p
  Deq{h, List.reverse(&2, String, rf), Nat.sub(n, h), List.reverse(&2, String, rest)}

# the n elements xs, in order, dealt half to each part
def deq.deal(+n: Nat, xs: List<&2, String>) -> Deq:
  +h = Nat.div(n, 2n)
  deq.deal.of(h, n, deq.cut(h, xs, Nil{}))

# whether one part holds more than three times the other's elements and
# one more
def deq.tilted(+nf: Nat, +nb: Nat) -> Bool:
  Bool.or(Nat.is_lt(Nat.add(Nat.mul(3n, nb), 1n), nf), Nat.is_lt(Nat.add(Nat.mul(3n, nf), 1n), nb))

def deq.fix.if(tilted: Bool, d: Deq) -> Deq:
  match tilted:
    case True{}:
      +x = d
      deq.deal(deq.len(x), deq.all(x))
    case False{}:
      d

def deq.fix(d: Deq) -> Deq:
  match d:
    case Deq{+nf, f, +nb, b}:
      deq.fix.if(deq.tilted(nf, nb), Deq{nf, f, nb, b})

# x put first (left) or last
def deq.push(+left: Bool, x: String, d: Deq) -> Deq:
  match left d:
    case True{} Deq{+nf, f, nb, b}:
      deq.fix(Deq{1n+nf, x <> f, nb, b})
    case False{} Deq{nf, f, +nb, b}:
      deq.fix(Deq{nf, f, 1n+nb, x <> b})

# the elements xs pushed in turn, each first (left) or last
def deq.pushes(+left: Bool, xs: List<&2, String>, d: Deq) -> Deq:
  match xs:
    case Nil{}:
      d
    case Con{x, rest}:
      deq.pushes(left, rest, deq.push(left, x, d))

# a list's first (or last) element and the others; none for an empty one
type Pop is Data:
  Pop{x: String, d: Deq}
  PopNone{}

# the first element of n elements xs, in order, and the rest
def deq.pop.all(+n: Nat, xs: List<&2, String>) -> Pop:
  match xs:
    case Con{x, rest}:
      Pop{x, deq.deal(Nat.sub(n, 1n), rest)}
    case Nil{}:
      PopNone{}

# the first element and the rest: the front part's first, else the
# back part's last (the back part then holds one element, while the
# parts are dealt as deq.fix keeps them)
def deq.popl(d: Deq) -> Pop:
  match d:
    case Deq{+nf, Con{x, f}, nb, b}:
      Pop{x, deq.fix(Deq{Nat.sub(nf, 1n), f, nb, b})}
    case Deq{nf, Nil{}, +nb, b}:
      deq.pop.all(nb, List.reverse(&2, String, b))

# the first element of n elements xs, in reverse, and the rest in order
def deq.pop.rev(+n: Nat, xs: List<&2, String>) -> Pop:
  match xs:
    case Con{x, rest}:
      Pop{x, deq.deal(Nat.sub(n, 1n), List.reverse(&2, String, rest))}
    case Nil{}:
      PopNone{}

# the last element and the rest
def deq.popr(d: Deq) -> Pop:
  match d:
    case Deq{nf, f, +nb, Con{x, b}}:
      Pop{x, deq.fix(Deq{nf, f, Nat.sub(nb, 1n), b})}
    case Deq{+nf, f, nb, Nil{}}:
      deq.pop.rev(nf, List.reverse(&2, String, f))

def deq.pop(+left: Bool, d: Deq) -> Pop:
  match left:
    case True{}:
      deq.popl(d)
    case False{}:
      deq.popr(d)

# elements popped so far, in reverse of the order they came off, and the
# list left
type Pops is Data:
  Pops{xs: List<&2, String>, d: Deq}

def deq.pop.into(p: Pop, acc: List<&2, String>) -> Pops:
  match p:
    case Pop{x, d}:
      Pops{x <> acc, d}
    case PopNone{}:
      Pops{acc, deq.empty()}

def deq.pop.step(+left: Bool, st: Pops) -> Pops:
  match st:
    case Pops{acc, d}:
      deq.pop.into(deq.pop(left, d), acc)

# up to c more elements popped from the first end (left) or the last
def deq.pops(c: Nat, +left: Bool, st: Pops) -> Pops:
  match c:
    case 0n:
      st
    case 1n+k:
      deq.pops(k, left, deq.pop.step(left, st))

# the i-th element of xs, read in place
def deq.nth(+xs: List<&2, String>, i: Nat) -> Maybe<&2, String>:
  match xs i:
    case Con{+x, +rest} 0n:
      Some{x}
    case Con{+x, +rest} 1n+j:
      deq.nth(rest, j)
    case Nil{} _:
      None{}

def deq.get.of(front: Bool, +i: Nat, +nf: Nat, +f: List<&2, String>, +nb: Nat, +b: List<&2, String>) -> Maybe<&2, String>:
  match front:
    case True{}:
      deq.nth(f, i)
    case False{}:
      deq.nth(b, Nat.sub(Nat.sub(nb, 1n), Nat.sub(i, nf)))

# the element at position i, below the list's length
def deq.get(+i: Nat, +d: Deq) -> Maybe<&2, String>:
  match d:
    case Deq{+nf, +f, +nb, +b}:
      deq.get.of(Nat.is_lt(i, nf), i, nf, f, nb, b)

def deq.set.of(front: Bool, +i: Nat, v: String, +nf: Nat, f: List<&2, String>, +nb: Nat, b: List<&2, String>) -> Deq:
  match front:
    case True{}:
      Deq{nf, List.set(&2, String, f, i, v), nb, b}
    case False{}:
      Deq{nf, f, nb, List.set(&2, String, b, Nat.sub(Nat.sub(nb, 1n), Nat.sub(i, nf)), v)}

# the list with the element at position i, below its length, set to v
def deq.set(+i: Nat, v: String, d: Deq) -> Deq:
  match d:
    case Deq{+nf, f, +nb, b}:
      deq.set.of(Nat.is_lt(i, nf), i, v, nf, f, nb, b)

# k elements of xs from the s-th on, read in place, reversed before acc
def deq.slice(+xs: List<&2, String>, s: Nat, k: Nat, acc: List<&2, String>) -> List<&2, String>:
  match xs s k:
    case Con{+x, +rest} 1n+t k:
      deq.slice(rest, t, k, acc)
    case Con{+x, +rest} 0n 1n+j:
      deq.slice(rest, 0n, j, x <> acc)
    case _ _ _:
      acc

def deq.range.f(ok: Bool, +s: Nat, +e: Nat, +f: List<&2, String>, acc: List<&2, String>) -> List<&2, String>:
  match ok:
    case True{}:
      List.reverse.go(&2, String, deq.slice(f, s, 1n+Nat.sub(e, s), Nil{}), acc)
    case False{}:
      acc

def deq.range.b(ok: Bool, +lo: Nat, +e: Nat, +n: Nat, +b: List<&2, String>) -> List<&2, String>:
  match ok:
    case True{}:
      deq.slice(b, Nat.sub(Nat.sub(n, 1n), e), 1n+Nat.sub(e, lo), Nil{})
    case False{}:
      Nil{}

# the elements at positions s to e, in order, s <= e below the length
def deq.range(+s: Nat, +e: Nat, +d: Deq) -> List<&2, String>:
  match d:
    case Deq{+nf, +f, +nb, +b}:
      deq.range.f(Nat.is_lt(s, nf), s, Nat.min(e, Nat.sub(nf, 1n)), f, deq.range.b(Nat.is_le(nf, e), Nat.max(s, nf), e, Nat.add(nf, nb), b))

# the list without its first k elements, k at most its length
def deq.dropl.of(front: Bool, +k: Nat, +nf: Nat, f: List<&2, String>, +nb: Nat, b: List<&2, String>) -> Deq:
  match front:
    case True{}:
      deq.fix(Deq{Nat.sub(nf, k), List.drop(&2, String, f, k), nb, b})
    case False{}:
      +m = Nat.sub(nb, Nat.sub(k, nf))
      deq.deal(m, List.reverse(&2, String, List.take(&2, String, b, m)))

def deq.dropl(+k: Nat, d: Deq) -> Deq:
  match d:
    case Deq{+nf, f, +nb, b}:
      deq.dropl.of(Nat.is_le(k, nf), k, nf, f, nb, b)

# the list without its last k elements, k at most its length
def deq.dropr.of(back: Bool, +k: Nat, +nf: Nat, f: List<&2, String>, +nb: Nat, b: List<&2, String>) -> Deq:
  match back:
    case True{}:
      deq.fix(Deq{nf, f, Nat.sub(nb, k), List.drop(&2, String, b, k)})
    case False{}:
      +m = Nat.sub(nf, Nat.sub(k, nb))
      deq.deal(m, List.take(&2, String, f, m))

def deq.dropr(+k: Nat, d: Deq) -> Deq:
  match d:
    case Deq{+nf, f, +nb, b}:
      deq.dropr.of(Nat.is_le(k, nb), k, nf, f, nb, b)

# the list of n elements xs, in order
def deq.of(+n: Nat, xs: List<&2, String>) -> Deq:
  deq.deal(n, xs)
