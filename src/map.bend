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
import ./float.bend as F

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

# a collection: a hash, its fields and their values (Hash), a list, its
# elements in order (Deq), a set, its members (Mems), or a sorted set,
# its members and their scores (Zset)
type Coll is Data:
  CHash{h: Hash}
  CList{l: Deq}
  CMems{s: Mems}
  CZset{z: Zset}

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

# An intset's members (Mems, below) in increasing order, as a
# weight-balanced tree: a tip, or a node of n members, its member x after
# those of l and before those of r (Sets, below)
type ITree is Data:
  ITip{}
  IBin{n: Nat, x: String, l: ITree, r: ITree}

# A set, as Redis 7.0 keeps one: one whose members all read as 64-bit
# integers in the form Redis writes them (ints.ok), at most
# set-max-intset-entries of them (512), as the tree of its n members in
# increasing order (an intset: SMEMBERS answers them so); any other as a
# trie of its members (a hashtable, in no order), which it stays (Sets,
# below)
type Mems is Data:
  MInts{n: Nat, tr: ITree}
  MBig{n: Nat, t: Trie<Unit>}

# A sorted set's elements in order (Sorted sets, below), as a
# weight-balanced tree: a tip, or a node of n elements, its element (a
# member m and its score d) after those of l and before those of r
type ZTree is Data:
  ZTip{}
  ZBin{n: Nat, m: String, d: F.F64, l: ZTree, r: ZTree}

# A sorted set, as Redis 7.0 keeps one: a small one (at most 128
# elements, each member of at most 64 bytes) as a listpack, its tree
# alone; any other as a skiplist with a hashtable of its members, its
# tree and a trie of its members' scores, which it stays (Sorted sets,
# below)
type Zset is Data:
  ZSmall{tr: ZTree}
  ZBig{tr: ZTree, t: Trie<F.F64>}

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

# whether a scan of mode takes an entry of time e at now: 0 when it is
# there, 1 when its time has passed, 2 when it is there and has a time
def scan.ok(+mode: Nat, +now: Nat, +e: Nat) -> Bool:
  match mode:
    case 0n:
      live(now, e)
    case 1n:
      Bool.not(live(now, e))
    case _:
      Bool.and(live(now, e), Nat.is_lt(0n, e))

# the keys of bucket b that a scan of mode takes at now (scan.ok), before
# acc (eviction's samples: tget_kb)
def bkeys(-V: Data, +b: Trie<V>, +now: Nat, +mode: Nat, acc: List<&2, String>) -> List<&2, String>:
  match b:
    case Ent{+k, +v, +e, +rest}:
      bkeys(V, rest, now, mode, kput(scan.ok(mode, now, e), k, acc))
    case _:
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

# the keys of the bucket a walk ends at that a scan of mode takes at now
# (bkeys), before acc: eviction's samples read buckets one walk each,
# which reads the trie lent, as get's do
def tget_kb(-V: Data, d: Nat, +t: Trie<V>, x: Hex, +h: U32, +now: Nat, +mode: Nat, acc: List<&2, String>) -> List<&2, String>:
  match d t x:
    case 0n t0 _:
      bkeys(V, t0, now, mode, acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H0{}:
      tget_kb(V, p, c0, hex(shr4(h)), shr4(h), now, mode, acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H1{}:
      tget_kb(V, p, c1, hex(shr4(h)), shr4(h), now, mode, acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H2{}:
      tget_kb(V, p, c2, hex(shr4(h)), shr4(h), now, mode, acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H3{}:
      tget_kb(V, p, c3, hex(shr4(h)), shr4(h), now, mode, acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H4{}:
      tget_kb(V, p, c4, hex(shr4(h)), shr4(h), now, mode, acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H5{}:
      tget_kb(V, p, c5, hex(shr4(h)), shr4(h), now, mode, acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H6{}:
      tget_kb(V, p, c6, hex(shr4(h)), shr4(h), now, mode, acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H7{}:
      tget_kb(V, p, c7, hex(shr4(h)), shr4(h), now, mode, acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H8{}:
      tget_kb(V, p, c8, hex(shr4(h)), shr4(h), now, mode, acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H9{}:
      tget_kb(V, p, c9, hex(shr4(h)), shr4(h), now, mode, acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H10{}:
      tget_kb(V, p, c10, hex(shr4(h)), shr4(h), now, mode, acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H11{}:
      tget_kb(V, p, c11, hex(shr4(h)), shr4(h), now, mode, acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H12{}:
      tget_kb(V, p, c12, hex(shr4(h)), shr4(h), now, mode, acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H13{}:
      tget_kb(V, p, c13, hex(shr4(h)), shr4(h), now, mode, acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H14{}:
      tget_kb(V, p, c14, hex(shr4(h)), shr4(h), now, mode, acc)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H15{}:
      tget_kb(V, p, c15, hex(shr4(h)), shr4(h), now, mode, acc)
    case 1n+p other _:
      acc

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

# the trie with op applied to the bucket where the walk ends; a walk
# into an empty subtrie builds the nodes down to the bucket. A delete
# walks with tdel_h, which reads as this walk with ODel.
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

# t, but the empty trie for a node of 16 empty subtries
def tnode(-V: Data, t: Trie<V>) -> Trie<V>:
  match t:
    case Node{Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}, Tip{}}:
      Tip{}
    case other:
      other

# whether t is the empty trie
def tis_tip(-V: Data, +t: Trie<V>) -> Bool:
  match t:
    case Tip{}:
      True{}
    case other:
      False{}

# tnode of t when e says so (a delete emptied one of its subtries),
# else t: a node with a subtrie that is not empty is kept unread
def tnode_if(-V: Data, e: Bool, t: Trie<V>) -> Trie<V>:
  match e:
    case True{}:
      tnode(V, t)
    case False{}:
      t

# the trie without k's entries in the bucket where the walk ends
# (bdel). A node that this leaves empty goes too (tnode_if), so a
# trie keeps no more nodes than its keys take, and a walk into an
# empty subtrie changes nothing. It reads as tmod_h with ODel{k},
# bucket by bucket (PROOF.bend: tdel_eq).
def tdel_h(-V: Data, d: Nat, t: Trie<V>, x: Hex, +h: U32, +k: String) -> Trie<V>:
  match d t x:
    case 0n t0 _:
      bdel(V, k, t0)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H0{}:
      +a = tdel_h(V, p, c0, hex(shr4(h)), shr4(h), k)
      tnode_if(V, tis_tip(V, a), Node{a, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15})
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H1{}:
      +a = tdel_h(V, p, c1, hex(shr4(h)), shr4(h), k)
      tnode_if(V, tis_tip(V, a), Node{c0, a, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15})
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H2{}:
      +a = tdel_h(V, p, c2, hex(shr4(h)), shr4(h), k)
      tnode_if(V, tis_tip(V, a), Node{c0, c1, a, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15})
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H3{}:
      +a = tdel_h(V, p, c3, hex(shr4(h)), shr4(h), k)
      tnode_if(V, tis_tip(V, a), Node{c0, c1, c2, a, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15})
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H4{}:
      +a = tdel_h(V, p, c4, hex(shr4(h)), shr4(h), k)
      tnode_if(V, tis_tip(V, a), Node{c0, c1, c2, c3, a, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15})
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H5{}:
      +a = tdel_h(V, p, c5, hex(shr4(h)), shr4(h), k)
      tnode_if(V, tis_tip(V, a), Node{c0, c1, c2, c3, c4, a, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15})
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H6{}:
      +a = tdel_h(V, p, c6, hex(shr4(h)), shr4(h), k)
      tnode_if(V, tis_tip(V, a), Node{c0, c1, c2, c3, c4, c5, a, c7, c8, c9, c10, c11, c12, c13, c14, c15})
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H7{}:
      +a = tdel_h(V, p, c7, hex(shr4(h)), shr4(h), k)
      tnode_if(V, tis_tip(V, a), Node{c0, c1, c2, c3, c4, c5, c6, a, c8, c9, c10, c11, c12, c13, c14, c15})
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H8{}:
      +a = tdel_h(V, p, c8, hex(shr4(h)), shr4(h), k)
      tnode_if(V, tis_tip(V, a), Node{c0, c1, c2, c3, c4, c5, c6, c7, a, c9, c10, c11, c12, c13, c14, c15})
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H9{}:
      +a = tdel_h(V, p, c9, hex(shr4(h)), shr4(h), k)
      tnode_if(V, tis_tip(V, a), Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, a, c10, c11, c12, c13, c14, c15})
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H10{}:
      +a = tdel_h(V, p, c10, hex(shr4(h)), shr4(h), k)
      tnode_if(V, tis_tip(V, a), Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, a, c11, c12, c13, c14, c15})
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H11{}:
      +a = tdel_h(V, p, c11, hex(shr4(h)), shr4(h), k)
      tnode_if(V, tis_tip(V, a), Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, a, c12, c13, c14, c15})
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H12{}:
      +a = tdel_h(V, p, c12, hex(shr4(h)), shr4(h), k)
      tnode_if(V, tis_tip(V, a), Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, a, c13, c14, c15})
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H13{}:
      +a = tdel_h(V, p, c13, hex(shr4(h)), shr4(h), k)
      tnode_if(V, tis_tip(V, a), Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, a, c14, c15})
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H14{}:
      +a = tdel_h(V, p, c14, hex(shr4(h)), shr4(h), k)
      tnode_if(V, tis_tip(V, a), Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, a, c15})
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H15{}:
      +a = tdel_h(V, p, c15, hex(shr4(h)), shr4(h), k)
      tnode_if(V, tis_tip(V, a), Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, a})
    case 1n+p other _:
      other
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
# the keys whose time has passed, and eviction's samples for the keys
# there, or those there with a time (the scan's mode: scan.ok).
type Scan is Data:
  Scan{want: Nat, acc: List<&2, String>}
  Stop{at: Nat, acc: List<&2, String>}

def bscan.end(done: Bool, +base: Nat, want: Nat, acc: List<&2, String>) -> Scan:
  match done:
    case True{}:
      Stop{Nat.add(base, 1n), acc}
    case False{}:
      Scan{want, acc}

# the keys of the bucket b of index base that the scan's mode takes at
# now (scan.ok), before acc, counted off want: every entry when all
# (SCAN's COUNT bounds the entries it reads, as Redis's bounds the work;
# and so the sweep's), else the keys taken only (RANDOMKEY's window,
# eviction's samples)
def bscan(-V: Data, +b: Trie<V>, +base: Nat, +want: Nat, acc: List<&2, String>, +now: Nat, +all: Bool, +mode: Nat) -> Scan:
  match b:
    case Ent{+k, +v, +e, +rest}:
      +ok = scan.ok(mode, now, e)
      bscan(V, rest, base, Nat.sub(want, Bool.pick(Nat, Bool.or(all, ok), 1n, 0n)), kput(ok, k, acc), now, all, mode)
    case _:
      bscan.end(Nat.is_eq(want, 0n), base, want, acc)

# BEGIN gen_trie: scan
def tscan(-V: Data, +d: Nat, skip: Bool, +t: Trie<V>, +base: Nat, +span: Nat, +from: Nat, +to: Nat, +now: Nat, +all: Bool, +mode: Nat, s: Scan) -> Scan:
  match d skip t s:
    case _ True{} _ s:
      s
    case _ False{} _ Stop{at, acc}:
      Stop{at, acc}
    case 0n False{} b Scan{want, acc}:
      bscan(V, b, base, want, acc, now, all, mode)
    case 1n+p False{} Tip{} s:
      s
    case 1n+p False{} Node{+c0, +c1, +c2, +c3, +c4, +c5, +c6, +c7, +c8, +c9, +c10, +c11, +c12, +c13, +c14, +c15} s:
      +q = Nat.div(span, 16n)
      tscan(V, p, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(16n, q)), from), Nat.is_le(to, Nat.add(base, Nat.mul(15n, q)))), c15, Nat.add(base, Nat.mul(15n, q)), q, from, to, now, all, mode, tscan(V, p, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(15n, q)), from), Nat.is_le(to, Nat.add(base, Nat.mul(14n, q)))), c14, Nat.add(base, Nat.mul(14n, q)), q, from, to, now, all, mode, tscan(V, p, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(14n, q)), from), Nat.is_le(to, Nat.add(base, Nat.mul(13n, q)))), c13, Nat.add(base, Nat.mul(13n, q)), q, from, to, now, all, mode, tscan(V, p, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(13n, q)), from), Nat.is_le(to, Nat.add(base, Nat.mul(12n, q)))), c12, Nat.add(base, Nat.mul(12n, q)), q, from, to, now, all, mode, tscan(V, p, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(12n, q)), from), Nat.is_le(to, Nat.add(base, Nat.mul(11n, q)))), c11, Nat.add(base, Nat.mul(11n, q)), q, from, to, now, all, mode, tscan(V, p, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(11n, q)), from), Nat.is_le(to, Nat.add(base, Nat.mul(10n, q)))), c10, Nat.add(base, Nat.mul(10n, q)), q, from, to, now, all, mode, tscan(V, p, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(10n, q)), from), Nat.is_le(to, Nat.add(base, Nat.mul(9n, q)))), c9, Nat.add(base, Nat.mul(9n, q)), q, from, to, now, all, mode, tscan(V, p, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(9n, q)), from), Nat.is_le(to, Nat.add(base, Nat.mul(8n, q)))), c8, Nat.add(base, Nat.mul(8n, q)), q, from, to, now, all, mode, tscan(V, p, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(8n, q)), from), Nat.is_le(to, Nat.add(base, Nat.mul(7n, q)))), c7, Nat.add(base, Nat.mul(7n, q)), q, from, to, now, all, mode, tscan(V, p, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(7n, q)), from), Nat.is_le(to, Nat.add(base, Nat.mul(6n, q)))), c6, Nat.add(base, Nat.mul(6n, q)), q, from, to, now, all, mode, tscan(V, p, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(6n, q)), from), Nat.is_le(to, Nat.add(base, Nat.mul(5n, q)))), c5, Nat.add(base, Nat.mul(5n, q)), q, from, to, now, all, mode, tscan(V, p, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(5n, q)), from), Nat.is_le(to, Nat.add(base, Nat.mul(4n, q)))), c4, Nat.add(base, Nat.mul(4n, q)), q, from, to, now, all, mode, tscan(V, p, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(4n, q)), from), Nat.is_le(to, Nat.add(base, Nat.mul(3n, q)))), c3, Nat.add(base, Nat.mul(3n, q)), q, from, to, now, all, mode, tscan(V, p, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(3n, q)), from), Nat.is_le(to, Nat.add(base, Nat.mul(2n, q)))), c2, Nat.add(base, Nat.mul(2n, q)), q, from, to, now, all, mode, tscan(V, p, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(2n, q)), from), Nat.is_le(to, Nat.add(base, Nat.mul(1n, q)))), c1, Nat.add(base, Nat.mul(1n, q)), q, from, to, now, all, mode, tscan(V, p, Bool.or(Nat.is_le(Nat.add(base, Nat.mul(1n, q)), from), Nat.is_le(to, base)), c0, base, q, from, to, now, all, mode, s))))))))))))))))
    case 1n+p False{} Ent{+k, +v, +e, +rest} s:
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
      pick.of(scan.acc(tscan(V, 5n, False{}, t, 0n, 1048576n, 0n, b, now, False{}, 0n, Scan{want, acc})), r)

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

# k's entry. The bucket is held while bent reads it, and dropped after:
# Bend makes a parameter owned for every caller when one caller gives it
# a value it does not keep, as bent(V, k, tget_h(..)) would give the
# bucket, and bent owning its bucket would make the walk that reads the
# keyspace for it (tget_ke) own, and copy, every node it passes.
def entry(-V: Data, t: Trie<V>, +k: String) -> Maybe<&2, Item<V>>:
  +h = hash(k)
  b = tget_h(V, 5n, t, hex(h), h)
  m = bent(V, k, b)
  m

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
  tdel_h(V, 5n, t, hex(h), h, k)

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
  tscan(V, 5n, False{}, t, 0n, 1048576n, from, 1048576n, now, True{}, 0n, Scan{want, Nil{}})

# the keys whose time has passed at now of the buckets from index from
# on, until want entries are read (the sweep of expired keys)
def reap(-V: Data, +t: Trie<V>, +from: Nat, want: Nat, +now: Nat) -> Scan:
  tscan(V, 5n, False{}, t, 0n, 1048576n, from, 1048576n, now, True{}, 1n, Scan{want, Nil{}})

# a key of t there at now, by r (Random picks), None when there is none
def pick(-V: Data, +t: Trie<V>, +r: U32, +now: Nat) -> Maybe<&2, String>:
  +b = U32.to_nat(U32.and(r, 1048575))
  pick.wrap(V, t, b, mix(r), now, tscan(V, 5n, False{}, t, 0n, 1048576n, b, 1048576n, now, False{}, 0n, Scan{16n, Nil{}}))

# Eviction's samples read the buckets one walk each (tget_kb), which reads
# the trie lent: a scan's walk (tscan) takes each node it reads, which
# shares it with the trie and costs a copy of it.

# the walk's hash of bucket index b: the index's five hex digits, the
# highest first (Scans), as the hash's digits from its lowest, which the
# walks take first
def bucket.h(+b: Nat) -> U32:
  +x = U32.from_nat(b)
  U32.or(U32.or(U32.or(U32.and(U32.shrn(x, 16n), 15), U32.shln(U32.and(U32.shrn(x, 12n), 15), 4n)), U32.or(U32.shln(U32.and(U32.shrn(x, 8n), 15), 8n), U32.shln(U32.and(U32.shrn(x, 4n), 15), 12n))), U32.shln(U32.and(x, 15), 16n))

def keys.len.go(+xs: List<&2, String>, +n: Nat) -> Nat:
  match xs:
    case Nil{}:
      n
    case Con{k, +rest}:
      keys.len.go(rest, 1n+n)

# eviction's sample: the keys of left buckets from b on (past the last
# bucket, from the first), that a scan of mode takes at now, until want
# of them are found (done)
def sample.go(-V: Data, +t: Trie<V>, left: Nat, done: Bool, +b: Nat, +now: Nat, +mode: Nat, +want: Nat, acc: List<&2, String>) -> List<&2, String>:
  match left done:
    case _ True{}:
      acc
    case 0n False{}:
      acc
    case 1n+l False{}:
      +h = bucket.h(b)
      +ks = tget_kb(V, 5n, t, hex(h), h, now, mode, acc)
      sample.go(V, t, l, Nat.is_le(want, keys.len.go(ks, 0n)), Nat.mod(1n+b, 1048576n), now, mode, want, ks)

# the keys (mode 0: there at now; 2: there with a time) of win buckets
# from a random one (r) on, until want of them are found; whole buckets,
# so that a sample may hold a few more; win 2^20: all of them
def sample(-V: Data, +t: Trie<V>, +r: U32, +want: Nat, +now: Nat, +mode: Nat, win: Nat) -> List<&2, String>:
  sample.go(V, t, win, False{}, U32.to_nat(U32.and(r, 1048575)), now, mode, want, Nil{})

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

# h with f's value set to v. The read of f comes before the write: in a
# node built of both the write would run first, the trie held for the
# read after it, and a held trie is shared, so the write would copy the
# path it changes
def hash.put(h: Hash, +f: String, +v: String) -> Hash:
  match h:
    case HSmall{+n, +ps}:
      +m = Bool.pick(Nat, Maybe.is_some(&2, String, hps.get(f, ps)), n, 1n+n)
      hash.small(hash.fits(m, f, v), m, hps.put(f, v, ps))
    case HBig{+n, +t}:
      +had = has(String, t, f)
      HBig{Bool.pick(Nat, had, n, 1n+n), set(String, t, f, v)}

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

# Sets
# ----
# A set's members (Mems, above): a small set of integers is a tree of
# its members in increasing order, any other a trie of its members, each
# with no time. Redis 7.0 keeps a set as an intset while its members all
# read as 64-bit integers and they are at most set-max-intset-entries
# (512), as a hashtable from the first write that passes either, for
# good. BendKV turns an intset into a hashtable at that default, whatever
# the parameter says, as it does a hash (Hashes, above); OBJECT ENCODING
# reads the parameter as it is (session.bend). A key never holds an empty
# set: a write that takes its last member deletes it.

# whether s's d chars from index a on, all digits and the first not 0,
# are at most 9223372036854775807 (with a = 1, after a '-': at most
# 9223372036854775808); 19 digits pass 2^48, where a Nat stops, so the
# number is read in two parts, the first ten digits and the other nine
# the first ten digits of 9223372036854775807 (a literal stops at 2^32)
def ints.max.hi() -> Nat:
  Nat.add(Nat.mul(92233n, 100000n), 72036n)

def ints.fits(ok: Bool, +s: String, +a: Nat, +d: Nat) -> Bool:
  match ok:
    case True{}:
      +hi = String.dec_at(s, a, 10n)
      +top = ints.max.hi()
      +last = Bool.pick(Nat, Nat.is_eq(a, 1n), 854775808n, 854775807n)
      Bool.or(Nat.is_lt(d, 19n), Bool.or(Nat.is_lt(hi, top), Bool.and(Nat.is_eq(hi, top), Nat.is_le(String.dec_at(s, Nat.add(a, 10n), 9n), last))))
    case False{}:
      False{}

def ints.ok.of(+s: String, +n: Nat, +a: Nat) -> Bool:
  +d = Nat.sub(n, a)
  +digits = Bool.and(Nat.is_eq(String.digits_at(s, a), d), U32.is_ne(String.code_at(s, a), 48))
  Bool.or(String.eq(s, "0"), ints.fits(Bool.and(Bool.and(Nat.is_lt(0n, d), Nat.is_le(d, 19n)), digits), s, a, d))

# whether s reads as a 64-bit integer in the form Redis writes one (as
# its string2ll reads it): an optional '-', then digits with no leading
# zero, or 0 alone ("-0" is not one)
def ints.ok(+s: String) -> Bool:
  ints.ok.of(s, String.length(s), Bool.pick(Nat, U32.is_eq(String.code_at(s, 0n), 45), 1n, 0n))

# An intset's tree (ITree, above) is weight-balanced, as a sorted set's
# is (Sorted sets, below): a member is found, added or taken out in
# O(log n) steps, each a compare of two integers (ints.cmp), and the
# member at a rank is found as well (SRANDMEMBER, SPOP). Redis's intset
# finds a member by binary search, and moves the ones after it to add or
# take out one.

# how integers a and b (of ints.ok) compare, c how their numbers of
# digits do: by their bytes when as many (as memcmp orders them,
# String.order: a digit's byte is in the digit's order)
def ints.cmp.of(c: Cmp, +a: String, +b: String) -> Cmp:
  match c:
    case EQ{}:
      String.order(a, b)
    case LT{}:
      LT{}
    case GT{}:
      GT{}

# na and nb whether a and b are negative: one that is comes first; two
# that are not by their numbers of digits (no leading zero) and then
# bytes, two that are the other way
def ints.cmp.sign(na: Bool, nb: Bool, +a: String, +b: String) -> Cmp:
  match na nb:
    case True{} False{}:
      LT{}
    case False{} True{}:
      GT{}
    case False{} False{}:
      ints.cmp.of(Nat.cmp(String.length(a), String.length(b)), a, b)
    case True{} True{}:
      ints.cmp.of(Nat.cmp(String.length(b), String.length(a)), b, a)

# how integer a compares with integer b (both of ints.ok)
def ints.cmp(+a: String, +b: String) -> Cmp:
  ints.cmp.sign(U32.is_eq(String.code_at(a, 0n), 45), U32.is_eq(String.code_at(b, 0n), 45), a, b)

def it.size(+t: ITree) -> Nat:
  match t:
    case ITip{}:
      0n
    case IBin{n, x, l, r}:
      n

# the size of t's left side (0 for a tip)
def it.lsize(+t: ITree) -> Nat:
  match t:
    case ITip{}:
      0n
    case IBin{n, x, +l, r}:
      it.size(l)

def it.bin(+x: String, +l: ITree, +r: ITree) -> ITree:
  IBin{Nat.add(Nat.add(it.size(l), it.size(r)), 1n), x, l, r}

# how integer m compares with t's root (GT for a tip)
def it.at(+t: ITree, +m: String) -> Cmp:
  match t:
    case ITip{}:
      GT{}
    case IBin{n, +x, l, r}:
      ints.cmp(m, x)

# A node of x between l and r, rebalanced after an insertion or a
# deletion on one side, as a sorted set's (zt.balance, below).

# r is the larger side
def it.dbll(+x: String, l: ITree, +rx: String, rr: ITree, rl: ITree) -> ITree:
  match rl:
    case ITip{}:
      it.bin(rx, it.bin(x, l, ITip{}), rr)
    case IBin{n, +y, +yl, +yr}:
      it.bin(y, it.bin(x, l, yl), it.bin(rx, yr, rr))

def it.rotl.of(single: Bool, +x: String, l: ITree, +rx: String, rl: ITree, rr: ITree) -> ITree:
  match single:
    case True{}:
      it.bin(rx, it.bin(x, l, rl), rr)
    case False{}:
      it.dbll(x, l, rx, rr, rl)

def it.rotl(+x: String, l: ITree, r: ITree) -> ITree:
  match r:
    case ITip{}:
      it.bin(x, l, ITip{})
    case IBin{n, +rx, +rl, +rr}:
      it.rotl.of(Nat.is_lt(it.size(rl), Nat.mul(2n, it.size(rr))), x, l, rx, rl, rr)

# l is the larger side
def it.dblr(+x: String, r: ITree, +lx: String, ll: ITree, lr: ITree) -> ITree:
  match lr:
    case ITip{}:
      it.bin(lx, ll, it.bin(x, ITip{}, r))
    case IBin{n, +y, +yl, +yr}:
      it.bin(y, it.bin(lx, ll, yl), it.bin(x, yr, r))

def it.rotr.of(single: Bool, +x: String, r: ITree, +lx: String, ll: ITree, lr: ITree) -> ITree:
  match single:
    case True{}:
      it.bin(lx, ll, it.bin(x, lr, r))
    case False{}:
      it.dblr(x, r, lx, ll, lr)

def it.rotr(+x: String, l: ITree, r: ITree) -> ITree:
  match l:
    case ITip{}:
      it.bin(x, ITip{}, r)
    case IBin{n, +lx, +ll, +lr}:
      it.rotr.of(Nat.is_lt(it.size(lr), Nat.mul(2n, it.size(ll))), x, r, lx, ll, lr)

def it.bal.of(few: Bool, rh: Bool, lh: Bool, +x: String, l: ITree, r: ITree) -> ITree:
  match few rh lh:
    case True{} _ _:
      it.bin(x, l, r)
    case False{} True{} _:
      it.rotl(x, l, r)
    case False{} False{} True{}:
      it.rotr(x, l, r)
    case False{} False{} False{}:
      it.bin(x, l, r)

def it.balance(+x: String, +l: ITree, +r: ITree) -> ITree:
  +sl = it.size(l)
  +sr = it.size(r)
  it.bal.of(Nat.is_le(Nat.add(sl, sr), 1n), Nat.is_lt(Nat.mul(3n, sl), sr), Nat.is_lt(Nat.mul(3n, sr), sl), x, l, r)

# whether t holds integer m; c is how m compares with t's root
def it.has(+t: ITree, c: Cmp, +m: String) -> Bool:
  match t c:
    case ITip{} _:
      False{}
    case IBin{n, x, +l, r} LT{}:
      it.has(l, it.at(l, m), m)
    case IBin{n, x, l, +r} GT{}:
      it.has(r, it.at(r, m), m)
    case IBin{n, x, l, r} EQ{}:
      True{}

def ints.has(+m: String, +t: ITree) -> Bool:
  it.has(t, it.at(t, m), m)

# t with integer m in its place (t does not hold it); c is how m
# compares with t's root
def it.ins(t: ITree, c: Cmp, +m: String) -> ITree:
  match t c:
    case ITip{} _:
      IBin{1n, m, ITip{}, ITip{}}
    case IBin{n, +x, +l, +r} LT{}:
      it.balance(x, it.ins(l, it.at(l, m), m), r)
    case IBin{n, +x, +l, +r} _:
      it.balance(x, l, it.ins(r, it.at(r, m), m))

def ints.put(+m: String, +t: ITree) -> ITree:
  it.ins(t, it.at(t, m), m)

# a member cut from the end of a tree, and the tree left
type ICut is Data:
  ICut{x: String, t: ITree}

def it.cutl.fix(c: ICut, +x: String, r: ITree) -> ICut:
  match c:
    case ICut{+cx, +ct}:
      ICut{cx, it.balance(x, ct, r)}

# the first member of the node of x between l and r, cut from it
def it.cutl(l: ITree, +x: String, r: ITree) -> ICut:
  match l:
    case ITip{}:
      ICut{x, r}
    case IBin{n, +lx, ll, lr}:
      it.cutl.fix(it.cutl(ll, lx, lr), x, r)

def it.cutr.fix(c: ICut, +x: String, l: ITree) -> ICut:
  match c:
    case ICut{+cx, +ct}:
      ICut{cx, it.balance(x, l, ct)}

# the last member of the node of x between l and r, cut from it
def it.cutr(r: ITree, +x: String, l: ITree) -> ICut:
  match r:
    case ITip{}:
      ICut{x, l}
    case IBin{n, +rx, rl, rr}:
      it.cutr.fix(it.cutr(rr, rx, rl), x, l)

def it.glue.lfix(c: ICut, r: ITree) -> ITree:
  match c:
    case ICut{+x, +l}:
      it.balance(x, l, r)

def it.glue.rfix(l: ITree, c: ICut) -> ITree:
  match c:
    case ICut{+x, +r}:
      it.balance(x, l, r)

# the larger side l's last member takes the place of the one taken out
def it.glue.l(l: ITree, r: ITree) -> ITree:
  match l:
    case ITip{}:
      r
    case IBin{n, +lx, ll, lr}:
      it.glue.lfix(it.cutr(lr, lx, ll), r)

# or r's first member (r a tip: both sides are)
def it.glue.r(l: ITree, r: ITree) -> ITree:
  match r:
    case ITip{}:
      l
    case IBin{n, +rx, rl, rr}:
      it.glue.rfix(l, it.cutl(rl, rx, rr))

def it.glue.of(lbig: Bool, l: ITree, r: ITree) -> ITree:
  match lbig:
    case True{}:
      it.glue.l(l, r)
    case False{}:
      it.glue.r(l, r)

# the members of l and then those of r, the sides of a node whose member
# is taken out
def it.glue(+l: ITree, +r: ITree) -> ITree:
  it.glue.of(Nat.is_lt(it.size(r), it.size(l)), l, r)

# t without integer m, which it holds; c is how m compares with t's root
def it.rm(t: ITree, c: Cmp, +m: String) -> ITree:
  match t c:
    case ITip{} _:
      ITip{}
    case IBin{n, +x, +l, +r} LT{}:
      it.balance(x, it.rm(l, it.at(l, m), m), r)
    case IBin{n, +x, +l, +r} GT{}:
      it.balance(x, l, it.rm(r, it.at(r, m), m))
    case IBin{n, x, +l, +r} EQ{}:
      it.glue(l, r)

def ints.del(+m: String, +t: ITree) -> ITree:
  it.rm(t, it.at(t, m), m)

# the member at rank i of t (none when i is not below its size); c is
# how i compares with the size of t's left side
def it.nth(+t: ITree, c: Cmp, +i: Nat) -> Maybe<&2, String>:
  match t c:
    case ITip{} _:
      None{}
    case IBin{n, x, +l, r} LT{}:
      it.nth(l, Nat.cmp(i, it.lsize(l)), i)
    case IBin{n, +x, l, r} EQ{}:
      Some{x}
    case IBin{n, x, +l, +r} GT{}:
      +j = Nat.sub(i, Nat.add(it.size(l), 1n))
      it.nth(r, Nat.cmp(j, it.lsize(r)), j)

def ints.nth(+t: ITree, +i: Nat) -> Maybe<&2, String>:
  it.nth(t, Nat.cmp(i, it.lsize(t)), i)

# a node's member, made before the walk goes on (as zt.el, below)
def it.el(+x: String) -> String:
  x

# the members of t in increasing order, before acc
def it.list(+t: ITree, acc: List<&2, String>) -> List<&2, String>:
  match t:
    case ITip{}:
      acc
    case IBin{n, +x, +l, +r}:
      y = it.el(x)
      acc2 = it.list(r, acc)
      it.list(l, y <> acc2)

def ints.list(+t: ITree) -> List<&2, String>:
  it.list(t, Nil{})

# the members of t added to the trie s
def it.trie(+t: ITree, s: Trie<Unit>) -> Trie<Unit>:
  match t:
    case ITip{}:
      s
    case IBin{n, +x, +l, +r}:
      it.trie(r, set(Unit, it.trie(l, s), x, Unit{}))

# The tree of n members that come in increasing order, made at once (as
# a sorted set's is, zel.build in rdb.bend): a walk with a list of jobs:
# build a tree of n members (its left side first); take the next member
# as the root of a node of n whose left side is the tree just made (a its
# size), then build its right side; join that node.
type IJob is Data:
  IJBuild{n: Nat}
  IJRoot{n: Nat, a: Nat}
  IJJoin{n: Nat, x: String, l: ITree}

# the jobs js run on the members xs, t the tree last made (f bounds the
# steps: four for each member and one)
def it.mach(f: Nat, js: List<&2, IJob>, xs: List<&2, String>, t: ITree) -> ITree:
  match f js:
    case 1n+g Con{IJBuild{n}, rest}:
      match n:
        case 0n:
          it.mach(g, rest, xs, t)
        case 1n+(+k):
          +a = Nat.div(k, 2n)
          it.mach(g, IJBuild{a} <> (IJRoot{1n+k, a} <> rest), xs, t)
    case 1n+g Con{IJRoot{+n, +a}, rest}:
      match xs:
        case Con{x, more}:
          it.mach(g, IJBuild{Nat.sub(Nat.sub(n, 1n), a)} <> (IJJoin{n, x, t} <> rest), more, ITip{})
        case Nil{}:
          t
    case 1n+g Con{IJJoin{+n, x, l}, rest}:
      it.mach(g, rest, xs, IBin{n, x, l, t})
    case _ _:
      t

def ints.build(+n: Nat, xs: List<&2, String>) -> ITree:
  it.mach(Nat.add(Nat.mul(4n, n), 4n), [IJBuild{n}], xs, ITip{})

def mems.empty() -> Mems:
  MInts{0n, ITip{}}

def mems.len(+s: Mems) -> Nat:
  match s:
    case MInts{+n, xs}:
      n
    case MBig{+n, t}:
      n

def mems.ints.has(int: Bool, +m: String, +xs: ITree) -> Bool:
  match int:
    case True{}:
      ints.has(m, xs)
    case False{}:
      False{}

# whether s holds m
def mems.has(+m: String, +s: Mems) -> Bool:
  match s:
    case MInts{n, +xs}:
      mems.ints.has(ints.ok(m), m, xs)
    case MBig{n, +t}:
      has(Unit, t, m)

# n members xs of an intset, and m, which they do not hold, as a
# hashtable
def mems.grow(+n: Nat, xs: ITree, +m: String) -> Mems:
  MBig{1n+n, set(Unit, it.trie(xs, empty(Unit)), m, Unit{})}

def mems.ints.put(fits: Bool, +n: Nat, xs: ITree, +m: String) -> Mems:
  match fits:
    case True{}:
      MInts{1n+n, ints.put(m, xs)}
    case False{}:
      mems.grow(n, xs, m)

def mems.ints.add(had: Bool, int: Bool, +n: Nat, xs: ITree, +m: String) -> Mems:
  match had int:
    case True{} _:
      MInts{n, xs}
    case False{} True{}:
      mems.ints.put(Nat.is_lt(n, 512n), n, xs, m)
    case False{} False{}:
      mems.grow(n, xs, m)

def mems.big.add(had: Bool, +n: Nat, t: Trie<Unit>, +m: String) -> Mems:
  match had:
    case True{}:
      MBig{n, t}
    case False{}:
      MBig{1n+n, set(Unit, t, m, Unit{})}

# s with m added (s may hold it already): an integer joins an intset in
# its place, while it holds at most 512; any other member makes it a
# hashtable
def mems.add(s: Mems, +m: String) -> Mems:
  match s:
    case MInts{+n, +xs}:
      +int = ints.ok(m)
      mems.ints.add(mems.ints.has(int, m, xs), int, n, xs, m)
    case MBig{+n, +t}:
      +had = has(Unit, t, m)
      mems.big.add(had, n, t, m)

# the members xs added in turn to s
def mems.adds(xs: List<&2, String>, s: Mems) -> Mems:
  match xs:
    case Nil{}:
      s
    case Con{+x, rest}:
      mems.adds(rest, mems.add(s, x))

# the set of the members xs (a member may come twice)
def mems.of(xs: List<&2, String>) -> Mems:
  mems.adds(xs, mems.empty())

# s without m, which it holds
def mems.del(s: Mems, +m: String) -> Mems:
  match s:
    case MInts{+n, xs}:
      MInts{Nat.sub(n, 1n), ints.del(m, xs)}
    case MBig{+n, t}:
      MBig{Nat.sub(n, 1n), del(Unit, t, m)}

# the members of s, in its order (an intset's, increasing)
def mems.all(+s: Mems) -> List<&2, String>:
  match s:
    case MInts{n, +xs}:
      ints.list(xs)
    case MBig{n, +t}:
      keys(Unit, t, 0n)

# Sorted sets
# -----------
# A sorted set's elements (Zset, above), each a member and its score (a
# double, never a NaN), in order of score (-0 the same as +0), then of
# member (bytes, as memcmp orders them, a prefix first: String.order), in
# a weight-balanced tree: each node keeps how many elements it holds, so
# that the element at a rank, and the rank of an element, are found in
# O(log n), and no side of a node holds more than 3 times the other (as
# Adams's trees, and Haskell's Data.Map, keep them). Redis 7.0 keeps a
# sorted set as a listpack while it holds at most
# zset-max-listpack-entries elements (128), each member of at most
# zset-max-listpack-value bytes (64), and as a skiplist with a hashtable
# of its members from the first write that passes either, for good.
# BendKV keeps a small one as its tree alone (a member is looked for along
# it, as along a listpack) and a large one with a trie of its members'
# scores as well, turning one into the other at those defaults, whatever
# the parameters say, as it does a hash (Hashes, above); OBJECT ENCODING
# reads the parameters as they are (session.bend). A listpack keeps an
# integral score as an integer, so -0 reads back from it as 0: a small
# sorted set keeps 0 for a score of -0, as Redis does. A key never holds
# an empty sorted set: a write that takes its last element deletes it.

# an element of a sorted set: its member and its score
type ZEl is Data:
  ZEl{m: String, d: F.F64}

def zt.size(+t: ZTree) -> Nat:
  match t:
    case ZTip{}:
      0n
    case ZBin{n, m, d, l, r}:
      n

# the size of t's left side (0 for a tip)
def zt.lsize(+t: ZTree) -> Nat:
  match t:
    case ZTip{}:
      0n
    case ZBin{n, m, d, +l, r}:
      zt.size(l)

def zt.bin(+m: String, +d: F.F64, +l: ZTree, +r: ZTree) -> ZTree:
  ZBin{Nat.add(Nat.add(zt.size(l), zt.size(r)), 1n), m, d, l, r}

# how the element (d, m) compares with (e, k): by score, then by member
def zel.cmp.of(c: Cmp, +m: String, +k: String) -> Cmp:
  match c:
    case EQ{}:
      String.order(m, k)
    case LT{}:
      LT{}
    case GT{}:
      GT{}

def zel.cmp(+d: F.F64, +m: String, +e: F.F64, +k: String) -> Cmp:
  zel.cmp.of(F.f64.cmp(d, e), m, k)

# how (d, m) compares with t's root (GT for a tip)
def zt.at(+t: ZTree, +d: F.F64, +m: String) -> Cmp:
  match t:
    case ZTip{}:
      GT{}
    case ZBin{n, +k, +e, l, r}:
      zel.cmp(d, m, e, k)

# A node of m and d between l and r, rebalanced after an insertion or a
# deletion on one side: when the two sides hold two or more elements and
# one holds more than 3 times the other, a single rotation, or a double
# one when the larger side's inner part holds at least 2 times its outer
# part, moves elements to the smaller side.

# r is the larger side
def zt.dbll(+m: String, +d: F.F64, l: ZTree, +rm: String, +rd: F.F64, rr: ZTree, rl: ZTree) -> ZTree:
  match rl:
    case ZTip{}:
      zt.bin(rm, rd, zt.bin(m, d, l, ZTip{}), rr)
    case ZBin{n, +xm, +xd, +xl, +xr}:
      zt.bin(xm, xd, zt.bin(m, d, l, xl), zt.bin(rm, rd, xr, rr))

def zt.rotl.of(single: Bool, +m: String, +d: F.F64, l: ZTree, +rm: String, +rd: F.F64, rl: ZTree, rr: ZTree) -> ZTree:
  match single:
    case True{}:
      zt.bin(rm, rd, zt.bin(m, d, l, rl), rr)
    case False{}:
      zt.dbll(m, d, l, rm, rd, rr, rl)

def zt.rotl(+m: String, +d: F.F64, l: ZTree, r: ZTree) -> ZTree:
  match r:
    case ZTip{}:
      zt.bin(m, d, l, ZTip{})
    case ZBin{n, +rm, +rd, +rl, +rr}:
      zt.rotl.of(Nat.is_lt(zt.size(rl), Nat.mul(2n, zt.size(rr))), m, d, l, rm, rd, rl, rr)

# l is the larger side
def zt.dblr(+m: String, +d: F.F64, r: ZTree, +lm: String, +ld: F.F64, ll: ZTree, lr: ZTree) -> ZTree:
  match lr:
    case ZTip{}:
      zt.bin(lm, ld, ll, zt.bin(m, d, ZTip{}, r))
    case ZBin{n, +xm, +xd, +xl, +xr}:
      zt.bin(xm, xd, zt.bin(lm, ld, ll, xl), zt.bin(m, d, xr, r))

def zt.rotr.of(single: Bool, +m: String, +d: F.F64, r: ZTree, +lm: String, +ld: F.F64, ll: ZTree, lr: ZTree) -> ZTree:
  match single:
    case True{}:
      zt.bin(lm, ld, ll, zt.bin(m, d, lr, r))
    case False{}:
      zt.dblr(m, d, r, lm, ld, ll, lr)

def zt.rotr(+m: String, +d: F.F64, l: ZTree, r: ZTree) -> ZTree:
  match l:
    case ZTip{}:
      zt.bin(m, d, ZTip{}, r)
    case ZBin{n, +lm, +ld, +ll, +lr}:
      zt.rotr.of(Nat.is_lt(zt.size(lr), Nat.mul(2n, zt.size(ll))), m, d, r, lm, ld, ll, lr)

def zt.bal.of(few: Bool, rh: Bool, lh: Bool, +m: String, +d: F.F64, l: ZTree, r: ZTree) -> ZTree:
  match few rh lh:
    case True{} _ _:
      zt.bin(m, d, l, r)
    case False{} True{} _:
      zt.rotl(m, d, l, r)
    case False{} False{} True{}:
      zt.rotr(m, d, l, r)
    case False{} False{} False{}:
      zt.bin(m, d, l, r)

def zt.balance(+m: String, +d: F.F64, +l: ZTree, +r: ZTree) -> ZTree:
  +sl = zt.size(l)
  +sr = zt.size(r)
  zt.bal.of(Nat.is_le(Nat.add(sl, sr), 1n), Nat.is_lt(Nat.mul(3n, sl), sr), Nat.is_lt(Nat.mul(3n, sr), sl), m, d, l, r)

# t with the element (m, d) in its place (t does not hold m); c is how
# (d, m) compares with t's root
def zt.ins(t: ZTree, c: Cmp, +m: String, +d: F.F64) -> ZTree:
  match t c:
    case ZTip{} _:
      ZBin{1n, m, d, ZTip{}, ZTip{}}
    case ZBin{n, +k, +e, +l, +r} LT{}:
      zt.balance(k, e, zt.ins(l, zt.at(l, d, m), m, d), r)
    case ZBin{n, +k, +e, +l, +r} _:
      zt.balance(k, e, l, zt.ins(r, zt.at(r, d, m), m, d))

def zt.add(+t: ZTree, +m: String, +d: F.F64) -> ZTree:
  zt.ins(t, zt.at(t, d, m), m, d)

# an element cut from the end of a tree, and the tree left
type ZCut is Data:
  ZCut{m: String, d: F.F64, t: ZTree}

def zt.cutl.fix(c: ZCut, +m: String, +d: F.F64, r: ZTree) -> ZCut:
  match c:
    case ZCut{+cm, +cd, +ct}:
      ZCut{cm, cd, zt.balance(m, d, ct, r)}

# the first element of the node of m and d between l and r, cut from it
def zt.cutl(l: ZTree, +m: String, +d: F.F64, r: ZTree) -> ZCut:
  match l:
    case ZTip{}:
      ZCut{m, d, r}
    case ZBin{n, +lm, +ld, ll, lr}:
      zt.cutl.fix(zt.cutl(ll, lm, ld, lr), m, d, r)

def zt.cutr.fix(c: ZCut, +m: String, +d: F.F64, l: ZTree) -> ZCut:
  match c:
    case ZCut{+cm, +cd, +ct}:
      ZCut{cm, cd, zt.balance(m, d, l, ct)}

# the last element of the node of m and d between l and r, cut from it
def zt.cutr(r: ZTree, +m: String, +d: F.F64, l: ZTree) -> ZCut:
  match r:
    case ZTip{}:
      ZCut{m, d, l}
    case ZBin{n, +rm, +rd, rl, rr}:
      zt.cutr.fix(zt.cutr(rr, rm, rd, rl), m, d, l)

def zt.glue.lfix(c: ZCut, r: ZTree) -> ZTree:
  match c:
    case ZCut{+m, +d, +l}:
      zt.balance(m, d, l, r)

def zt.glue.rfix(l: ZTree, c: ZCut) -> ZTree:
  match c:
    case ZCut{+m, +d, +r}:
      zt.balance(m, d, l, r)

# the larger side l's last element takes the place of the one deleted
def zt.glue.l(l: ZTree, r: ZTree) -> ZTree:
  match l:
    case ZTip{}:
      r
    case ZBin{n, +lm, +ld, ll, lr}:
      zt.glue.lfix(zt.cutr(lr, lm, ld, ll), r)

# or r's first element (r a tip: both sides are)
def zt.glue.r(l: ZTree, r: ZTree) -> ZTree:
  match r:
    case ZTip{}:
      l
    case ZBin{n, +rm, +rd, rl, rr}:
      zt.glue.rfix(l, zt.cutl(rl, rm, rd, rr))

def zt.glue.of(lbig: Bool, l: ZTree, r: ZTree) -> ZTree:
  match lbig:
    case True{}:
      zt.glue.l(l, r)
    case False{}:
      zt.glue.r(l, r)

# the elements of l and then those of r, the sides of a node whose
# element is deleted
def zt.glue(+l: ZTree, +r: ZTree) -> ZTree:
  zt.glue.of(Nat.is_lt(zt.size(r), zt.size(l)), l, r)

# t without the element (m, d), which it holds; c is how (d, m) compares
# with t's root
def zt.rm(t: ZTree, c: Cmp, +m: String, +d: F.F64) -> ZTree:
  match t c:
    case ZTip{} _:
      ZTip{}
    case ZBin{n, +k, +e, +l, +r} LT{}:
      zt.balance(k, e, zt.rm(l, zt.at(l, d, m), m, d), r)
    case ZBin{n, +k, +e, +l, +r} GT{}:
      zt.balance(k, e, l, zt.rm(r, zt.at(r, d, m), m, d))
    case ZBin{n, k, e, +l, +r} EQ{}:
      zt.glue(l, r)

def zt.del(+t: ZTree, +m: String, +d: F.F64) -> ZTree:
  zt.rm(t, zt.at(t, d, m), m, d)

# how many elements of t come before (d, m), which it holds; c is how
# (d, m) compares with t's root
def zt.rank.go(+t: ZTree, c: Cmp, +m: String, +d: F.F64, +acc: Nat) -> Nat:
  match t c:
    case ZTip{} _:
      acc
    case ZBin{n, k, e, +l, r} LT{}:
      zt.rank.go(l, zt.at(l, d, m), m, d, acc)
    case ZBin{n, k, e, +l, +r} GT{}:
      zt.rank.go(r, zt.at(r, d, m), m, d, Nat.add(acc, Nat.add(zt.size(l), 1n)))
    case ZBin{n, k, e, +l, r} EQ{}:
      Nat.add(acc, zt.size(l))

def zt.rank(+t: ZTree, +m: String, +d: F.F64) -> Nat:
  zt.rank.go(t, zt.at(t, d, m), m, d, 0n)

# the element at rank i of t (i below its size); c is how i compares with
# the size of t's left side
def zt.nth.go(+t: ZTree, c: Cmp, +i: Nat) -> ZEl:
  match t c:
    case ZTip{} _:
      ZEl{"", F.F64{0n, 0n}}
    case ZBin{n, k, e, +l, r} LT{}:
      zt.nth.go(l, Nat.cmp(i, zt.lsize(l)), i)
    case ZBin{n, +k, +e, l, r} EQ{}:
      ZEl{k, e}
    case ZBin{n, k, e, +l, +r} GT{}:
      +j = Nat.sub(i, Nat.add(zt.size(l), 1n))
      zt.nth.go(r, Nat.cmp(j, zt.lsize(r)), j)

def zt.nth(+t: ZTree, +i: Nat) -> ZEl:
  zt.nth.go(t, Nat.cmp(i, zt.lsize(t)), i)

# A test of an element (ZP): its score at least a lower bound of a range
# (ZGeS: Redis's zslValueGteMin) or at most an upper one (ZLeS:
# zslValueLteMax), its member at least a lower bound (ZGeL:
# zslLexValueGteMin) or at most an upper one (ZLeL: zslLexValueLteMax),
# or past an upper one (ZGtS, ZGtL: the opposite tests). A test holds no
# test of its own, so it is a few words passed as they are, never a node
# that a read of a tree would have to own. A bound of scores is a score, left
# out of the range when ex ('(' before it); a bound of members is '-'
# (before every member), '+' (after every one), or a member, taken in
# ('[' before it) or left out ('('), as Redis reads one (sdscmplex).

type ZSB is Data:
  ZSB{d: F.F64, ex: Bool}

type ZLB is Data:
  ZLNeg{}
  ZLPos{}
  ZLIn{s: String}
  ZLEx{s: String}

type ZP is Data:
  ZGeS{b: ZSB}
  ZLeS{b: ZSB}
  ZGeL{b: ZLB}
  ZLeL{b: ZLB}
  ZGtS{b: ZSB}
  ZGtL{b: ZLB}

def zsb.ge(+d: F.F64, +b: ZSB) -> Bool:
  match b:
    case ZSB{+e, +ex}:
      +c = F.f64.cmp(d, e)
      Bool.pick(Bool, ex, Cmp.is_gt(c), Bool.not(Cmp.is_lt(c)))

def zsb.le(+d: F.F64, +b: ZSB) -> Bool:
  match b:
    case ZSB{+e, +ex}:
      +c = F.f64.cmp(d, e)
      Bool.pick(Bool, ex, Cmp.is_lt(c), Bool.not(Cmp.is_gt(c)))

# how member m compares with a bound of members
def zlb.cmp(+m: String, +b: ZLB) -> Cmp:
  match b:
    case ZLNeg{}:
      GT{}
    case ZLPos{}:
      LT{}
    case ZLIn{+s}:
      String.order(m, s)
    case ZLEx{+s}:
      String.order(m, s)

# whether a bound of members is left out ('-' and '+' are, as Redis reads
# them)
def zlb.ex(+b: ZLB) -> Bool:
  match b:
    case ZLIn{s}:
      False{}
    case _:
      True{}

def zlb.ge(+m: String, +b: ZLB) -> Bool:
  +c = zlb.cmp(m, b)
  Bool.pick(Bool, zlb.ex(b), Cmp.is_gt(c), Bool.not(Cmp.is_lt(c)))

def zlb.le(+m: String, +b: ZLB) -> Bool:
  +c = zlb.cmp(m, b)
  Bool.pick(Bool, zlb.ex(b), Cmp.is_lt(c), Bool.not(Cmp.is_gt(c)))

def zp.ok(+p: ZP, +m: String, +d: F.F64) -> Bool:
  match p:
    case ZGeS{+b}:
      zsb.ge(d, b)
    case ZLeS{+b}:
      zsb.le(d, b)
    case ZGeL{+b}:
      zlb.ge(m, b)
    case ZLeL{+b}:
      zlb.le(m, b)
    case ZGtS{+b}:
      Bool.not(zsb.le(d, b))
    case ZGtL{+b}:
      Bool.not(zlb.le(m, b))

# whether p holds of t's root (True for a tip)
def zt.p_at(+t: ZTree, +p: ZP) -> Bool:
  match t:
    case ZTip{}:
      True{}
    case ZBin{n, +k, +e, l, r}:
      zp.ok(p, k, e)

# How many elements of t come before the first that p holds of, when p
# holds of none of the first elements and of all the others (a test of
# scores always does; one of members does when the scores are all the
# same, as Redis asks of a range of members): a walk down from the root,
# as Redis walks down its skiplist. ok is whether p holds of t's root.
def zt.before.go(+t: ZTree, ok: Bool, +p: ZP, +acc: Nat) -> Nat:
  match t ok:
    case ZTip{} _:
      acc
    case ZBin{n, k, e, +l, r} True{}:
      zt.before.go(l, zt.p_at(l, p), p, acc)
    case ZBin{n, k, e, +l, +r} False{}:
      zt.before.go(r, zt.p_at(r, p), p, Nat.add(acc, Nat.add(zt.size(l), 1n)))

def zt.before(+t: ZTree, +p: ZP) -> Nat:
  zt.before.go(t, zt.p_at(t, p), p, 0n)

# whether the ranks from lo to lo + n - 1 meet those from a to b - 1
def zt.meets(+lo: Nat, +n: Nat, +a: Nat, +b: Nat) -> Bool:
  Bool.and(Nat.is_lt(0n, n), Bool.and(Nat.is_lt(lo, b), Nat.is_lt(a, Nat.add(lo, n))))

def zt.slice.mid(take: Bool, x: ZEl, acc: List<&2, ZEl>) -> List<&2, ZEl>:
  match take:
    case True{}:
      x <> acc
    case False{}:
      acc

# a node's element, made before the walk goes on: a field of a node read
# past a call would have the walk own every node it reads
def zt.el(+m: String, +d: F.F64) -> ZEl:
  ZEl{m, d}

# the elements of t at the ranks from a to b - 1, in order, before acc;
# t's first element is at rank base, and hit is whether t's ranks meet
# those (a walk that reads only the nodes on the way to them)
def zt.slice.go(+t: ZTree, hit: Bool, +a: Nat, +b: Nat, +base: Nat, acc: List<&2, ZEl>) -> List<&2, ZEl>:
  match t hit:
    case ZTip{} _:
      acc
    case ZBin{n, k, e, l, r} False{}:
      acc
    case ZBin{n, +k, +e, +l, +r} True{}:
      +me = Nat.add(base, zt.size(l))
      +rb = Nat.add(me, 1n)
      x = zt.el(k, e)
      acc2 = zt.slice.go(r, zt.meets(rb, zt.size(r), a, b), a, b, rb, acc)
      acc3 = zt.slice.mid(Bool.and(Nat.is_le(a, me), Nat.is_lt(me, b)), x, acc2)
      zt.slice.go(l, zt.meets(base, zt.size(l), a, b), a, b, base, acc3)

def zt.slice(+t: ZTree, +a: Nat, +b: Nat) -> List<&2, ZEl>:
  zt.slice.go(t, zt.meets(0n, zt.size(t), a, b), a, b, 0n, Nil{})

# the same elements, last first
def zt.rslice.go(+t: ZTree, hit: Bool, +a: Nat, +b: Nat, +base: Nat, acc: List<&2, ZEl>) -> List<&2, ZEl>:
  match t hit:
    case ZTip{} _:
      acc
    case ZBin{n, k, e, l, r} False{}:
      acc
    case ZBin{n, +k, +e, +l, +r} True{}:
      +me = Nat.add(base, zt.size(l))
      +rb = Nat.add(me, 1n)
      x = zt.el(k, e)
      acc2 = zt.rslice.go(l, zt.meets(base, zt.size(l), a, b), a, b, base, acc)
      acc3 = zt.slice.mid(Bool.and(Nat.is_le(a, me), Nat.is_lt(me, b)), x, acc2)
      zt.rslice.go(r, zt.meets(rb, zt.size(r), a, b), a, b, rb, acc3)

def zt.rslice(+t: ZTree, +a: Nat, +b: Nat) -> List<&2, ZEl>:
  zt.rslice.go(t, zt.meets(0n, zt.size(t), a, b), a, b, 0n, Nil{})

# all the elements of t, in order
def zt.all(+t: ZTree) -> List<&2, ZEl>:
  zt.slice(t, 0n, zt.size(t))

# all the elements of a tree its caller owns, in order, before acc,
# taking it apart (a tree made for the purpose, as a STORE's): the reads
# above borrow the trees they read, and a tree computed for them alone
# would have them own every node they read
def zt.drain(t: ZTree, acc: List<&2, ZEl>) -> List<&2, ZEl>:
  match t:
    case ZTip{}:
      acc
    case ZBin{n, m, d, l, r}:
      zt.drain(l, ZEl{m, d} <> zt.drain(r, acc))

# m's score, when t holds m (got: the score found so far): a walk along
# all its elements in order, as along a listpack
def zt.find.node(got: Maybe<&2, F.F64>, +m: String, +k: String, +e: F.F64) -> Maybe<&2, F.F64>:
  match got:
    case Some{x}:
      Some{x}
    case None{}:
      Bool.pick(Maybe<&2, F.F64>, String.eq(m, k), Some{e}, None{})

def zt.find.go(+t: ZTree, got: Maybe<&2, F.F64>, +m: String) -> Maybe<&2, F.F64>:
  match t got:
    case ZTip{} g:
      g
    case ZBin{n, k, e, l, r} Some{x}:
      Some{x}
    case ZBin{n, +k, +e, +l, +r} None{}:
      zt.find.go(r, zt.find.node(zt.find.go(l, None{}, m), m, k, e), m)

def zt.find(+t: ZTree, +m: String) -> Maybe<&2, F.F64>:
  zt.find.go(t, None{}, m)

# the elements of t added to the trie s, each member with its score
def zt.trie(+t: ZTree, s: Trie<F.F64>) -> Trie<F.F64>:
  match t:
    case ZTip{}:
      s
    case ZBin{n, +k, +e, +l, +r}:
      zt.trie(r, set(F.F64, zt.trie(l, s), k, e))

# the score a listpack keeps for d: 0 for -0
def zset.norm(+d: F.F64) -> F.F64:
  match d:
    case F.F64{+hi, +lo}:
      Bool.pick(F.F64, Bool.and(Nat.is_eq(hi, 2147483648n), Nat.is_eq(lo, 0n)), F.F64{0n, 0n}, F.F64{hi, lo})

def zset.empty() -> Zset:
  ZSmall{ZTip{}}

def zset.tree(+z: Zset) -> ZTree:
  match z:
    case ZSmall{+tr}:
      tr
    case ZBig{+tr, t}:
      tr

# (a field of z, which a read borrows, not a tree computed from it: a
# computed tree passed to zt.size would have every reader of a size own
# the node it reads, and copy it when the tree shares it)
def zset.len(+z: Zset) -> Nat:
  match z:
    case ZSmall{tr}:
      zt.size(tr)
    case ZBig{tr, t}:
      zt.size(tr)

def zset.is_small(+z: Zset) -> Bool:
  match z:
    case ZSmall{tr}:
      True{}
    case ZBig{tr, t}:
      False{}

# m's score, when z holds m
def zset.score(+m: String, +z: Zset) -> Maybe<&2, F.F64>:
  match z:
    case ZSmall{+tr}:
      zt.find(tr, m)
    case ZBig{tr, +t}:
      get(F.F64, t, m)

# z with m of score d added (z does not hold m): a small one turns large
# when it would pass 128 elements, or m passes 64 bytes
def zset.add.small(fits: Bool, +tr: ZTree, +m: String, +d: F.F64) -> Zset:
  match fits:
    case True{}:
      ZSmall{zt.add(tr, m, zset.norm(d))}
    case False{}:
      ZBig{zt.add(tr, m, d), set(F.F64, zt.trie(tr, empty(F.F64)), m, d)}

def zset.add(z: Zset, +m: String, +d: F.F64) -> Zset:
  match z:
    case ZSmall{+tr}:
      zset.add.small(Bool.and(Nat.is_lt(zt.size(tr), 128n), Nat.is_le(String.length(m), 64n)), tr, m, d)
    case ZBig{+tr, +t}:
      ZBig{zt.add(tr, m, d), set(F.F64, t, m, d)}

# z without m, which it holds with score d
def zset.del(z: Zset, +m: String, +d: F.F64) -> Zset:
  match z:
    case ZSmall{+tr}:
      ZSmall{zt.del(tr, m, d)}
    case ZBig{+tr, +t}:
      ZBig{zt.del(tr, m, d), del(F.F64, t, m)}

# z with m's score, old, set to d
def zset.set(z: Zset, +m: String, +old: F.F64, +d: F.F64) -> Zset:
  match z:
    case ZSmall{+tr}:
      ZSmall{zt.add(zt.del(tr, m, old), m, zset.norm(d))}
    case ZBig{+tr, +t}:
      ZBig{zt.add(zt.del(tr, m, old), m, d), set(F.F64, t, m, d)}

# the elements of z at the ranks from a to b - 1, in order (last first
# when rev)
def zset.slice.of(rev: Bool, +t: ZTree, +a: Nat, +b: Nat) -> List<&2, ZEl>:
  match rev:
    case True{}:
      zt.rslice(t, a, b)
    case False{}:
      zt.slice(t, a, b)

def zset.slice(rev: Bool, +z: Zset, +a: Nat, +b: Nat) -> List<&2, ZEl>:
  match z:
    case ZSmall{tr}:
      zset.slice.of(rev, tr, a, b)
    case ZBig{tr, t}:
      zset.slice.of(rev, tr, a, b)

# all the elements of z, in order
def zset.all(+z: Zset) -> List<&2, ZEl>:
  match z:
    case ZSmall{tr}:
      zt.all(tr)
    case ZBig{tr, t}:
      zt.all(tr)

# how many elements of z come before (d, m), which it holds
def zset.rank(+z: Zset, +m: String, +d: F.F64) -> Nat:
  match z:
    case ZSmall{tr}:
      zt.rank(tr, m, d)
    case ZBig{tr, t}:
      zt.rank(tr, m, d)

# z without the elements xs, which it holds
def zset.dels(xs: List<&2, ZEl>, z: Zset) -> Zset:
  match xs:
    case Nil{}:
      z
    case Con{ZEl{+m, +d}, rest}:
      zset.dels(rest, zset.del(z, m, d))
