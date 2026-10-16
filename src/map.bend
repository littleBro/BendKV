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
# elements in order (Deq), a set, its members (Mems), a sorted set, its
# members and their scores (Zset), or a stream, its entries and its
# consumer groups (XStream). CStream comes last, so that the others keep
# their tags.
type Coll is Data:
  CHash{h: Hash}
  CList{l: Deq}
  CMems{s: Mems}
  CZset{z: Zset}
  CStream{x: XStream}

# a hash: a field and its value
type HPair is Data:
  HP{f: String, v: String}

# k pairs of a small hash past one buffer, coded as in a small hash's
# string (Hashes, below)
type HPiece is Data:
  HPc{k: Nat, s: String}

# where hb.find found a field in a piece: the index of its pair and of its
# value's code (Hashes, below)
type HAt is Data:
  HAt{i: Nat, vi: Nat}

# A hash, as Redis 7.0 keeps one: a small one (n fields, each of at most
# hash-max-listpack-value bytes, n at most hash-max-listpack-entries) as
# the string of its pairs in the order they came (a listpack: HGETALL
# answers them so; Hashes, below), in pieces of one buffer each past one
# buffer (HLong), a larger one as a trie of its fields (a hashtable, in no
# order), which it stays.
type Hash is Data:
  HSmall{n: Nat, b: String}
  HBig{n: Nat, t: Trie<String>}
  HLong{n: Nat, ps: List<&2, HPiece>}

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
# elements, each member of at most 64 bytes) as a listpack, the string of
# its n elements in order while that fits one buffer (2,048 bytes), else
# its tree alone, which it stays (ZWide); any other as a skiplist with a
# hashtable of its members, its tree and a trie of its members' scores,
# which it stays (Sorted sets, below)
type Zset is Data:
  ZSmall{n: Nat, b: String}
  ZWide{tr: ZTree}
  ZBig{tr: ZTree, t: Trie<F.F64>}

# A number of a stream below 2^64 (an ID's time or sequence, a count),
# split in decimal so that no Nat passes 2^48: one below 10^14 (every
# time in ms, almost every sequence and count) as itself (XS), any other
# as hi * 10^14 + lo, hi from 1 to 184467 and lo below 10^14 (XL)
# (Streams, below)
type XN is Data:
  XS{n: Nat}
  XL{hi: Nat, lo: Nat}

# a stream entry's ID: its time in ms and its sequence
type XId is Data:
  XId{ms: XN, seq: XN}

# A node of a stream, one listpack of Redis's radix tree: its master ID
# (the radix tree's key) and fields, its live and deleted entries, its
# listpack's size in bytes and its count of elements, and its entries,
# the newest first, each the bytes Redis's listpack holds for it (flags,
# ms delta, seq delta, [num-fields, fields], values, lp-count, each
# element with its backlen). XNdOf, a node that holds a node, is never
# built: it makes XNode a node of its own, one word (a type travels as
# wide as its widest form).
type XNode is Data:
  XNd{mid: XId, mfs: List<&2, String>, live: Nat, dead: Nat, bytes: Nat, nel: Nat, es: List<&2, String>}
  XNdOf{x: XNode}

# a stream's nodes by master ID, as a weight-balanced tree (a tip, or a
# node of n nodes, x's after those of l and before those of r)
type XNodes is Data:
  XNTip{}
  XNBin{n: Nat, x: XNode, l: XNodes, r: XNodes}

# an entry pending in a group (Redis's NACK): its ID, the consumer it was
# last delivered to, the time of that delivery (ms) and how many times it
# was delivered (XNkOf is never built, as XNdOf)
type XNack is Data:
  XNk{id: XId, owner: String, time: Nat, count: XN}
  XNkOf{x: XNack}

# a group's pending entries by ID, as a weight-balanced tree
type XPel is Data:
  XPTip{}
  XPBin{n: Nat, x: XNack, l: XPel, r: XPel}

# the IDs pending for a consumer, as a weight-balanced tree
type XIds is Data:
  XITip{}
  XIBin{n: Nat, x: XId, l: XIds, r: XIds}

# a consumer: its name, the time it was last seen (ms), its pending IDs
type XCon is Data:
  XCon{name: String, seen: Nat, ids: XIds}

# a group's consumers by name (bytes, as memcmp orders them, a prefix
# first), as a weight-balanced tree
type XCons is Data:
  XCTip{}
  XCBin{n: Nat, x: XCon, l: XCons, r: XCons}

# a group's count of entries read (entries_read): unknown (-1), or one
type XRd is Data:
  XRdNone{}
  XRdN{n: XN}

# a consumer group: its name, the last ID delivered to it, its count of
# entries read, its pending entries and its consumers (XGrpOf is never
# built, as XNdOf)
type XGroup is Data:
  XGrp{name: String, last: XId, read: XRd, pel: XPel, cons: XCons}
  XGrpOf{x: XGroup}

# a stream's groups by name, as a weight-balanced tree
type XGroups is Data:
  XGTip{}
  XGBin{n: Nat, x: XGroup, l: XGroups, r: XGroups}

# A stream, as Redis 7.0 keeps one: its count of live entries, the last
# ID added, its first live entry's ID, the greatest ID deleted, how many
# entries were ever added, its nodes and its groups (XStrOf is never
# built, as XNdOf) (Streams, below)
type XStream is Data:
  XStr{len: Nat, last: XId, first: XId, maxdel: XId, added: XN, nodes: XNodes, groups: XGroups}
  XStrOf{x: XStream}

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

# whether the bucket a walk ends at holds an entry: a key whose hash
# has h's low digits can be in t only there, so an empty one shows that
# t holds no such key (the server looks its heeded keys up so, by the
# hashes its requests carry); the walk only reads t
def tget_hn(-V: Data, d: Nat, +t: Trie<V>, x: Hex, +h: U32) -> Bool:
  match d t x:
    case 0n Tip{} _:
      False{}
    case 0n other _:
      True{}
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H0{}:
      tget_hn(V, p, c0, hex(shr4(h)), shr4(h))
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H1{}:
      tget_hn(V, p, c1, hex(shr4(h)), shr4(h))
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H2{}:
      tget_hn(V, p, c2, hex(shr4(h)), shr4(h))
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H3{}:
      tget_hn(V, p, c3, hex(shr4(h)), shr4(h))
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H4{}:
      tget_hn(V, p, c4, hex(shr4(h)), shr4(h))
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H5{}:
      tget_hn(V, p, c5, hex(shr4(h)), shr4(h))
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H6{}:
      tget_hn(V, p, c6, hex(shr4(h)), shr4(h))
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H7{}:
      tget_hn(V, p, c7, hex(shr4(h)), shr4(h))
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H8{}:
      tget_hn(V, p, c8, hex(shr4(h)), shr4(h))
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H9{}:
      tget_hn(V, p, c9, hex(shr4(h)), shr4(h))
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H10{}:
      tget_hn(V, p, c10, hex(shr4(h)), shr4(h))
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H11{}:
      tget_hn(V, p, c11, hex(shr4(h)), shr4(h))
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H12{}:
      tget_hn(V, p, c12, hex(shr4(h)), shr4(h))
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H13{}:
      tget_hn(V, p, c13, hex(shr4(h)), shr4(h))
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H14{}:
      tget_hn(V, p, c14, hex(shr4(h)), shr4(h))
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H15{}:
      tget_hn(V, p, c15, hex(shr4(h)), shr4(h))
    case 1n+p other _:
      False{}

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

# whether the bucket of a hash h holds an entry: when it does not, t holds
# no key whose hash has h's low twenty bits, the digits of the walk
# (tget_hn)
def filled.at(-V: Data, +t: Trie<V>, +h: U32) -> Bool:
  tget_hn(V, 5n, t, hex(h), h)

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

# Packed strings
# --------------
# A small hash and a small sorted set keep their elements one after
# another in one string, as Redis keeps them in a listpack, one
# allocation (Hashes and Sorted sets, below). A string among them is
# coded as its length and its bytes. A length below 255 takes one byte; a
# longer one (RESTORE keeps a listpack's elements whatever their lengths)
# takes the byte 255 and then its four bytes, the high first. A read
# walks the lengths from the start to the element it wants, comparing a
# string of the right length by its last byte, then whole, and copies
# one out with String.slice. A write makes the string anew: in the C
# runtime, a ++ whose right side has no room before its bytes links the
# two into a chain of chunks, and a chain reads a chunk at a time, so the
# pieces a write puts together are copied into one buffer (pk.flat), as a
# listpack is written anew in its allocation.

# the byte at index i of b (255 past its end, so that a read past it
# stays below 2^32)
def pk.byte(+b: String, +i: Nat) -> Nat:
  U32.to_nat(U32.and(String.code_at(b, i), 255))

# the k bytes from index i of b, the high first, after the number acc
def pk.long(k: Nat, +b: String, +i: Nat, +acc: Nat) -> Nat:
  match k:
    case 0n:
      acc
    case 1n+j:
      pk.long(j, b, Nat.add(i, 1n), Nat.add(Nat.mul(acc, 256n), pk.byte(b, i)))

def pk.len.of(short: Bool, +b: String, +i: Nat, x: Nat) -> Nat:
  match short:
    case True{}:
      x
    case False{}:
      pk.long(4n, b, Nat.add(i, 1n), 0n)

# the length whose code starts at index i of b
def pk.len(+b: String, +i: Nat) -> Nat:
  +x = pk.byte(b, i)
  pk.len.of(Nat.is_lt(x, 255n), b, i, x)

# the length whose code starts at index i of b, of the first of k
# strings from there on (0 when there is none)
def pk.len.if(k: Nat, +b: String, +i: Nat) -> Nat:
  match k:
    case 0n:
      0n
    case 1n+j:
      pk.len(b, i)

# how many bytes code the length n: one below 255, else five (255 - n,
# cut at 0, is at least 1 exactly when n is below 255)
def pk.hdr(+n: Nat) -> Nat:
  Nat.sub(5n, Nat.mul(4n, Nat.min(Nat.sub(255n, n), 1n)))

# the index just past the string whose code starts at index i of b
def pk.end(+b: String, +i: Nat) -> Nat:
  +n = pk.len(b, i)
  Nat.add(i, Nat.add(pk.hdr(n), n))

# the byte x (below 256) before rest
def pk.byte.put(+x: Nat, rest: String) -> String:
  SCon{Chr{U32.from_nat(x)}, rest}

# the k low bytes of n, the high first, before rest
def pk.long.put(k: Nat, +n: Nat, rest: String) -> String:
  match k:
    case 0n:
      rest
    case 1n+j:
      pk.long.put(j, Nat.div(n, 256n), pk.byte.put(Nat.mod(n, 256n), rest))

def pk.code.of(short: Bool, +n: Nat, rest: String) -> String:
  match short:
    case True{}:
      pk.byte.put(n, rest)
    case False{}:
      pk.byte.put(255n, pk.long.put(4n, n, rest))

# the code of the length n before rest
def pk.code(+n: Nat, rest: String) -> String:
  pk.code.of(Nat.is_lt(n, 255n), n, rest)

# the string s, of n bytes, as one buffer: String.take copies a String
# into one buffer in the C runtime (into a chain of 2,048 bytes a buffer
# past 2,048), and the take of all n bytes is s itself
def pk.flat(s: String, +n: Nat) -> String:
  String.take(s, n)

# whether the n bytes from index i of b are f, when same says their last
# bytes agree. String.eq, not str_eq: a call that gives str_eq a value of
# its own (the slice) makes str_eq own its first argument, and every key
# the trie compares with it be given one (FINDINGS.md, section 7)
def pk.is.whole(same: Bool, +f: String, +b: String, +i: Nat, +n: Nat) -> Bool:
  match same:
    case True{}:
      String.eq(String.slice(b, i, n), f)
    case False{}:
      False{}

# whether the n bytes from index i of b are f, as many as f's, whose last
# is lb: an empty one is, and a longer one's last byte is compared before
# the whole
def pk.hit.last(n: Nat, +f: String, +lb: U32, +b: String, +i: Nat) -> Bool:
  match n:
    case 0n:
      True{}
    case 1n++m:
      pk.is.whole(U32.is_eq(String.code_at(b, Nat.add(i, m)), lb), f, b, i, 1n+m)

def pk.hit.of(same: Bool, +f: String, +lb: U32, +b: String, +i: Nat, +n: Nat) -> Bool:
  match same:
    case True{}:
      pk.hit.last(n, f, lb, b, i)
    case False{}:
      False{}

# whether the string whose code starts at index i of b, the first of k
# strings from there on, n bytes long, is f (lf bytes long, its last
# byte lb): the lengths first, then the last bytes, then the bytes (a
# test of the lengths and the last bytes at once, in one call, reads the
# last byte of every string of another length too, and costs more than
# the calls it saves: FINDINGS.md, section 3zzzn)
def pk.hit(k: Nat, +f: String, +lf: Nat, +lb: U32, +b: String, +i: Nat, +n: Nat) -> Bool:
  match k:
    case 0n:
      False{}
    case 1n+j:
      pk.hit.of(Nat.is_eq(n, lf), f, lb, b, Nat.add(i, pk.hdr(n)), n)

# b without its bytes from index i to index end
def pk.cut(+b: String, +i: Nat, +end: Nat) -> String:
  +n = Nat.sub(String.length(b), Nat.sub(end, i))
  +pre = String.take(b, i)
  pk.flat(pre ++ String.drop(b, end), n)

# Hashes
# ------
# A hash's fields and values (Hash, above): a small one is the string of
# its pairs in the order they came, a large one a trie of its fields, each
# with no time. Redis 7.0 keeps a hash as a listpack while it holds at
# most hash-max-listpack-entries pairs (512), each of at most
# hash-max-listpack-value bytes (64), and as a hashtable from the first
# write that passes either, for good. BendKV turns a small hash into a
# large one at those defaults, whatever the parameters say, so that the
# hash a history of writes leaves depends on the writes alone (the
# append-only file makes it again on any server); OBJECT ENCODING reads
# the parameters as they are (session.bend).
#
# A small hash's string holds its pairs one after another, in the order
# they came (Packed strings, above): a pair is its field's code and its
# value's code. A read walks the lengths, two a pair, to the pair it
# wants, and copies a field or a value out with String.slice.
#
# A buffer holds at most 2,048 bytes: a longer string is a chain of them,
# and String.code_at past the first walks the chain from its start, so a
# read by index would cost the pairs times the buffers. A small hash's
# string therefore holds at most 2,048 bytes (hb.small); past that, its
# pairs are in pieces (HLong), each the pairs that fill one buffer (or one
# pair longer than that, which RESTORE may give), and a read or a write
# goes through them in order and reads or writes in one. A write that
# makes a piece longer than a buffer deals its pairs into pieces again
# (hl.fix), and a piece a delete empties goes.

# whether the first pair of ps is f's
def hps.head(+f: String, ps: List<&2, HPair>) -> Bool:
  match ps:
    case Con{HP{g, v}, rest}:
      str_eq(f, g)
    case Nil{}:
      False{}

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

# the pair of the field f and its value v, before rest
def hb.pair(+f: String, +v: String, rest: String) -> String:
  pk.code(String.length(f), f ++ pk.code(String.length(v), v ++ rest))

# the pairs ps as a small hash's string, before rest
def hb.enc(ps: List<&2, HPair>, rest: String) -> String:
  match ps:
    case Nil{}:
      rest
    case Con{HP{f, v}, more}:
      hb.pair(f, v, hb.enc(more, rest))

# f's pair among the k pairs from index i of b on, the first of them with
# a field of n bytes: the index of the pair and of its value's code, or
# the index past the pairs twice; hit is pk.hit(k, f, lf, lb, b, i, n),
# computed before b is passed on
def hb.find.go(+f: String, +lf: Nat, +lb: U32, +b: String, k: Nat, hit: Bool, +i: Nat, +n: Nat) -> Nat & Nat:
  match k hit:
    case 0n _:
      (i, i)
    case 1n++j True{}:
      (i, Nat.add(i, Nat.add(pk.hdr(n), n)))
    case 1n++j False{}:
      +vi = Nat.add(i, Nat.add(pk.hdr(n), n))
      +vl = pk.len(b, vi)
      +x = Nat.add(vi, Nat.add(pk.hdr(vl), vl))
      +xn = pk.len.if(j, b, x)
      hb.find.go(f, lf, lb, b, j, pk.hit(j, f, lf, lb, b, x, xn), x, xn)

# f's pair in the string b of a small hash of k pairs: the index of the
# pair and of its value's code, or b's length twice when f is not there
def hb.find(+f: String, +b: String, +k: Nat) -> Nat & Nat:
  +lf = String.length(f)
  +lb = String.code_at(f, Nat.sub(lf, 1n))
  +n = pk.len.if(k, b, 0n)
  hb.find.go(f, lf, lb, b, k, pk.hit(k, f, lf, lb, b, 0n, n), 0n, n)

# whether hb.find found its field in b
def hb.has(+b: String, p: Nat & Nat) -> Bool:
  (i, vi) = p
  Nat.is_lt(i, String.length(b))

# the value whose code starts at index vi of b
def hb.val(+b: String, +vi: Nat) -> String:
  +n = pk.len(b, vi)
  String.slice(b, Nat.add(vi, pk.hdr(n)), n)

def hb.get.of(had: Bool, +b: String, +vi: Nat) -> Maybe<&2, String>:
  match had:
    case True{}:
      Some{hb.val(b, vi)}
    case False{}:
      None{}

# the value hb.find found in b
def hb.get(+b: String, p: Nat & Nat) -> Maybe<&2, String>:
  (i, vi) = p
  hb.get.of(Nat.is_lt(i, String.length(b)), b, vi)

# the k pairs from index i of b on, the last first, before acc
def hb.pairs.rev(k: Nat, +b: String, +i: Nat, acc: List<&2, HPair>) -> List<&2, HPair>:
  match k:
    case 0n:
      acc
    case 1n+j:
      +fl = pk.len(b, i)
      +fi = Nat.add(i, pk.hdr(fl))
      +vi = Nat.add(fi, fl)
      +vl = pk.len(b, vi)
      +vj = Nat.add(vi, pk.hdr(vl))
      hb.pairs.rev(j, b, Nat.add(vj, vl), HP{String.slice(b, fi, fl), String.slice(b, vj, vl)} <> acc)

# the k pairs from index i of b on, in their order: a walk that keeps no
# frame for each pair, then the list turned around
def hb.pairs(k: Nat, +b: String, +i: Nat) -> List<&2, HPair>:
  List.reverse(&2, HPair, hb.pairs.rev(k, b, i, Nil{}))

# the length of the longest field or value of the k pairs from index i of
# b on, at least m
def hb.widest(k: Nat, +b: String, +i: Nat, +m: Nat) -> Nat:
  match k:
    case 0n:
      m
    case 1n+j:
      +fl = pk.len(b, i)
      +vi = Nat.add(i, Nat.add(pk.hdr(fl), fl))
      +vl = pk.len(b, vi)
      hb.widest(j, b, Nat.add(vi, Nat.add(pk.hdr(vl), vl)), Nat.max(m, Nat.max(fl, vl)))

# b with the value whose code starts at index vi set to v, in its place
def hb.reset(+b: String, +vi: Nat, +v: String) -> String:
  +end = pk.end(b, vi)
  +lv = String.length(v)
  +n = Nat.add(Nat.sub(String.length(b), Nat.sub(end, vi)), Nat.add(pk.hdr(lv), lv))
  +pre = String.take(b, vi)
  pk.flat(pre ++ pk.code(lv, v ++ String.drop(b, end)), n)

# b with f's value set to v: in its place when f is there (had: its
# value's code at index vi), else in a pair after the last
def hb.set(had: Bool, +b: String, +vi: Nat, +f: String, +v: String) -> String:
  match had:
    case True{}:
      hb.reset(b, vi, v)
    case False{}:
      +lf = String.length(f)
      +lv = String.length(v)
      +n = Nat.add(String.length(b), Nat.add(Nat.add(pk.hdr(lf), lf), Nat.add(pk.hdr(lv), lv)))
      pk.flat(b ++ hb.pair(f, v, ""), n)

# b without its pair at index i, whose value's code is at index vi (b as
# it is when had is False: the pair is not there)
def hb.cut(had: Bool, +b: String, +i: Nat, +vi: Nat) -> String:
  match had:
    case True{}:
      pk.cut(b, i, pk.end(b, vi))
    case False{}:
      b

# b without the pair hb.find found
def hb.del(+b: String, p: Nat & Nat) -> String:
  (+i, vi) = p
  hb.cut(Nat.is_lt(i, String.length(b)), b, i, vi)

# hb.find's indices, as data a walk reads more than once; whether it
# found its field (the index of the value's code is past the pair's then,
# and the same index twice else: no String.length, which walks a chain);
# the index of the pair; of its value's code
def hl.at(p: Nat & Nat) -> HAt:
  (i, vi) = p
  HAt{i, vi}

def hl.found(q: HAt) -> Bool:
  match q:
    case HAt{i, vi}:
      Nat.is_lt(i, vi)

def hl.i(q: HAt) -> Nat:
  match q:
    case HAt{i, vi}:
      i

def hl.vi(q: HAt) -> Nat:
  match q:
    case HAt{i, vi}:
      vi

# how many bytes the pair of the field f and its value v takes
def hb.size(+f: String, +v: String) -> Nat:
  +lf = String.length(f)
  +lv = String.length(v)
  Nat.add(Nat.add(pk.hdr(lf), lf), Nat.add(pk.hdr(lv), lv))

# how many bytes the pairs ps take in a small hash's string, after n
def hb.bytes(ps: List<&2, HPair>, +n: Nat) -> Nat:
  match ps:
    case Nil{}:
      n
    case Con{HP{+f, +v}, more}:
      hb.bytes(more, Nat.add(n, hb.size(f, v)))

# the pairs ps (the last first) as a small hash's string, before acc
def hl.enc.rev(ps: List<&2, HPair>, acc: String) -> String:
  match ps:
    case Nil{}:
      acc
    case Con{HP{f, v}, more}:
      hl.enc.rev(more, hb.pair(f, v, acc))

# the piece of the k pairs cur (the last first), len bytes, before rest
# (none when k is 0)
def hl.close(k: Nat, cur: List<&2, HPair>, +len: Nat, rest: List<&2, HPiece>) -> List<&2, HPiece>:
  match k:
    case 0n:
      rest
    case 1n+j:
      Con{HPc{1n+j, pk.flat(hl.enc.rev(cur, ""), len)}, rest}

# whether the first pair of ps goes in a piece of len bytes: it fills no
# more than a buffer, or the piece is empty
def hl.room(ps: List<&2, HPair>, +len: Nat) -> Bool:
  match ps:
    case Nil{}:
      True{}
    case Con{HP{+f, +v}, more}:
      Bool.or(Nat.is_eq(len, 0n), Nat.is_le(Nat.add(len, hb.size(f, v)), 2048n))

# the pairs ps in pieces before the pieces tail, after the k pairs cur
# (the last first, len bytes) of the piece being filled; room is
# hl.room(ps, len)
def hl.fill(ps: List<&2, HPair>, room: Bool, cur: List<&2, HPair>, +k: Nat, +len: Nat, tail: List<&2, HPiece>) -> List<&2, HPiece>:
  match ps room:
    case Nil{} _:
      hl.close(k, cur, len, tail)
    case Con{HP{+f, +v}, +more} True{}:
      +l = Nat.add(len, hb.size(f, v))
      hl.fill(more, hl.room(more, l), Con{HP{f, v}, cur}, 1n+k, l, tail)
    case Con{HP{+f, +v}, +more} False{}:
      +l = hb.size(f, v)
      hl.close(k, cur, len, hl.fill(more, hl.room(more, l), [HP{f, v}], 1n, l, tail))

# the pairs ps, in their order, in pieces of one buffer each
def hl.of(ps: List<&2, HPair>) -> List<&2, HPiece>:
  hl.fill(ps, True{}, Nil{}, 0n, 0n, Nil{})

# a piece's pairs, the last first, before acc; its longest field or
# value, at least m; f's value in it; whether f is in it
def hl.pairs.in(+p: HPiece, acc: List<&2, HPair>) -> List<&2, HPair>:
  match p:
    case HPc{+k, +s}:
      hb.pairs.rev(k, s, 0n, acc)

def hl.widest.in(+p: HPiece, +m: Nat) -> Nat:
  match p:
    case HPc{+k, +s}:
      hb.widest(k, s, 0n, m)

def hl.get.in(+f: String, +p: HPiece) -> Maybe<&2, String>:
  match p:
    case HPc{+k, +s}:
      +q = hl.at(hb.find(f, s, k))
      hb.get.of(hl.found(q), s, hl.vi(q))

def hl.has.in(+f: String, +p: HPiece) -> Bool:
  match p:
    case HPc{+k, +s}:
      hl.found(hl.at(hb.find(f, s, k)))

# the pairs of the pieces ps, the last first, before acc
def hl.pairs.rev(+ps: List<&2, HPiece>, acc: List<&2, HPair>) -> List<&2, HPair>:
  match ps:
    case Nil{}:
      acc
    case Con{+p, +rest}:
      hl.pairs.rev(rest, hl.pairs.in(p, acc))

# the pairs of the pieces ps, in their order
def hl.pairs(+ps: List<&2, HPiece>) -> List<&2, HPair>:
  List.reverse(&2, HPair, hl.pairs.rev(ps, Nil{}))

# the length of the longest field or value of the pieces ps, at least m
def hl.widest(+ps: List<&2, HPiece>, +m: Nat) -> Nat:
  match ps:
    case Nil{}:
      m
    case Con{+p, +rest}:
      hl.widest(rest, hl.widest.in(p, m))

# f's value in the pieces ps, unless m already holds it
def hl.get(+f: String, +ps: List<&2, HPiece>, m: Maybe<&2, String>) -> Maybe<&2, String>:
  match ps m:
    case Nil{} Some{v}:
      Some{v}
    case Nil{} None{}:
      None{}
    case Con{+p, +rest} Some{v}:
      Some{v}
    case Con{+p, +rest} None{}:
      hl.get(f, rest, hl.get.in(f, p))

# whether f is in the pieces ps, unless had already says so
def hl.has(+f: String, +ps: List<&2, HPiece>, had: Bool) -> Bool:
  match ps had:
    case Nil{} True{}:
      True{}
    case Nil{} False{}:
      False{}
    case Con{+p, +rest} True{}:
      True{}
    case Con{+p, +rest} False{}:
      hl.has(f, rest, hl.has.in(f, p))

# the piece of k pairs s before rest, dealt into pieces again when a write
# made it longer than a buffer
def hl.fix.of(long: Bool, +k: Nat, +s: String, rest: List<&2, HPiece>) -> List<&2, HPiece>:
  match long:
    case True{}:
      hl.fill(hb.pairs(k, s, 0n), True{}, Nil{}, 0n, 0n, rest)
    case False{}:
      Con{HPc{k, s}, rest}

def hl.fix(+k: Nat, +s: String, rest: List<&2, HPiece>) -> List<&2, HPiece>:
  hl.fix.of(Bool.and(Nat.is_lt(1n, k), Nat.is_lt(2048n, String.length(s))), k, s, rest)

# the last piece, of k pairs s, with the pair of f and v after its last:
# in it while it fills no more than a buffer, else in a piece of its own
def hl.add.of(room: Bool, +k: Nat, +s: String, +f: String, +v: String) -> List<&2, HPiece>:
  match room:
    case True{}:
      [HPc{1n+k, hb.set(False{}, s, 0n, f, v)}]
    case False{}:
      [HPc{k, s}, HPc{1n, hb.set(False{}, "", 0n, f, v)}]

def hl.add(+k: Nat, +s: String, +f: String, +v: String) -> List<&2, HPiece>:
  hl.add.of(Nat.is_le(Nat.add(String.length(s), hb.size(f, v)), 2048n), k, s, f, v)

# whether f was there, and the pieces q holds after the piece of k pairs
# s
def hl.set.on(+k: Nat, +s: String, q: Bool & List<&2, HPiece>) -> Bool & List<&2, HPiece>:
  (had, qs) = q
  (had, Con{HPc{k, s}, qs})

# whether f is there, and the pieces with f's value set to v: the piece
# of k pairs s, then rest; had: f is in s, its value's code at index vi
def hl.set.go(+f: String, +v: String, rest: List<&2, HPiece>, had: Bool, +k: Nat, +s: String, +vi: Nat) -> Bool & List<&2, HPiece>:
  match rest had:
    case Nil{} True{}:
      (True{}, hl.fix(k, hb.reset(s, vi, v), Nil{}))
    case Nil{} False{}:
      (False{}, hl.add(k, s, f, v))
    case Con{HPc{j, r}, more} True{}:
      (True{}, hl.fix(k, hb.reset(s, vi, v), Con{HPc{j, r}, more}))
    case Con{HPc{+j, +r}, more} False{}:
      +q = hl.at(hb.find(f, r, j))
      hl.set.on(k, s, hl.set.go(f, v, more, hl.found(q), j, r, hl.vi(q)))

# whether f is there, and the pieces ps with f's value set to v: in its
# place when f is there, else after the last pair
def hl.set(+f: String, +v: String, ps: List<&2, HPiece>) -> Bool & List<&2, HPiece>:
  match ps:
    case Nil{}:
      (False{}, [HPc{1n, hb.set(False{}, "", 0n, f, v)}])
    case Con{HPc{+k, +s}, rest}:
      +q = hl.at(hb.find(f, s, k))
      hl.set.go(f, v, rest, hl.found(q), k, s, hl.vi(q))

# the piece of k pairs s before rest, none when k is 0
def hl.drop(k: Nat, +s: String, rest: List<&2, HPiece>) -> List<&2, HPiece>:
  match k:
    case 0n:
      rest
    case 1n+j:
      Con{HPc{1n+j, s}, rest}

# the pieces with f's pair taken out: the piece of k pairs s, then rest;
# had: f's pair is in s, at index i, its value's code at index vi. A
# piece left with no pair goes
def hl.cut.go(+f: String, rest: List<&2, HPiece>, had: Bool, +k: Nat, +s: String, +i: Nat, +vi: Nat) -> List<&2, HPiece>:
  match rest had:
    case Nil{} True{}:
      hl.drop(Nat.sub(k, 1n), hb.cut(True{}, s, i, vi), Nil{})
    case Nil{} False{}:
      [HPc{k, s}]
    case Con{HPc{j, r}, more} True{}:
      hl.drop(Nat.sub(k, 1n), hb.cut(True{}, s, i, vi), Con{HPc{j, r}, more})
    case Con{HPc{+j, +r}, more} False{}:
      +q = hl.at(hb.find(f, r, j))
      Con{HPc{k, s}, hl.cut.go(f, more, hl.found(q), j, r, hl.i(q), hl.vi(q))}

# the pieces ps with f's pair taken out
def hl.cut(+f: String, ps: List<&2, HPiece>) -> List<&2, HPiece>:
  match ps:
    case Nil{}:
      Nil{}
    case Con{HPc{+k, +s}, rest}:
      +q = hl.at(hb.find(f, s, k))
      hl.cut.go(f, rest, hl.found(q), k, s, hl.i(q), hl.vi(q))

# a hash of n pairs whose string is s: small while s fills no more than
# a buffer, else in pieces
def hb.small.of(fits: Bool, +n: Nat, +s: String) -> Hash:
  match fits:
    case True{}:
      HSmall{n, s}
    case False{}:
      HLong{n, hl.of(hb.pairs(n, s, 0n))}

def hb.small(+n: Nat, +s: String) -> Hash:
  hb.small.of(Nat.is_le(String.length(s), 2048n), n, s)

# a hash of n pairs in the pieces ps: back in one string when one piece
# of no more than a buffer is left
def hl.one.of(fits: Bool, +n: Nat, +k: Nat, +s: String) -> Hash:
  match fits:
    case True{}:
      HSmall{n, s}
    case False{}:
      HLong{n, [HPc{k, s}]}

def hl.hash.of(+n: Nat, +k: Nat, +s: String, rest: List<&2, HPiece>) -> Hash:
  match rest:
    case Nil{}:
      hl.one.of(Nat.is_le(String.length(s), 2048n), n, k, s)
    case Con{q, more}:
      HLong{n, Con{HPc{k, s}, Con{q, more}}}

def hl.hash(+n: Nat, ps: List<&2, HPiece>) -> Hash:
  match ps:
    case Nil{}:
      HSmall{n, ""}
    case Con{HPc{+k, +s}, rest}:
      hl.hash.of(n, k, s, rest)

def hash.empty() -> Hash:
  HSmall{0n, ""}

def hash.of.at(fits: Bool, +n: Nat, ps: List<&2, HPair>) -> Hash:
  match fits:
    case True{}:
      +s = hb.enc(ps, "")
      HSmall{n, pk.flat(s, String.length(s))}
    case False{}:
      HLong{n, hl.of(ps)}

# a small hash of the n pairs ps, in their order (RESTORE)
def hash.of(+n: Nat, +ps: List<&2, HPair>) -> Hash:
  hash.of.at(Nat.is_le(hb.bytes(ps, 0n), 2048n), n, ps)

def hash.len(+h: Hash) -> Nat:
  match h:
    case HSmall{+n, b}:
      n
    case HBig{+n, t}:
      n
    case HLong{+n, ps}:
      n

def hash.get(+f: String, +h: Hash) -> Maybe<&2, String>:
  match h:
    case HSmall{n, +b}:
      hb.get(b, hb.find(f, b, n))
    case HBig{n, +t}:
      get(String, t, f)
    case HLong{n, +ps}:
      hl.get(f, ps, None{})

def hash.has(+f: String, +h: Hash) -> Bool:
  match h:
    case HSmall{n, +b}:
      hb.has(b, hb.find(f, b, n))
    case HBig{n, +t}:
      Maybe.is_some(&2, String, get(String, t, f))
    case HLong{n, +ps}:
      hl.has(f, ps, False{})

# whether a small hash of m pairs, one of them f and v, stays small
def hash.fits(+m: Nat, +f: String, +v: String) -> Bool:
  Bool.and(Nat.is_le(m, 512n), Bool.and(Nat.is_le(String.length(f), 64n), Nat.is_le(String.length(v), 64n)))

# a hash of m pairs in the pieces ps, large when it no longer fits
def hl.put(fits: Bool, +m: Nat, ps: List<&2, HPiece>) -> Hash:
  match fits:
    case True{}:
      HLong{m, ps}
    case False{}:
      HBig{m, hps.trie(hl.pairs(ps), empty(String))}

# a hash of n pairs in pieces with f's value set to v, as hl.set gave
# them (q)
def hl.put.at(+n: Nat, q: Bool & List<&2, HPiece>, +f: String, +v: String) -> Hash:
  (had, qs) = q
  +m = Bool.pick(Nat, had, n, 1n+n)
  hl.put(hash.fits(m, f, v), m, qs)

# a small hash of n pairs b with f's value set to v (had: f is there, its
# value's code at index vi): small with m pairs when it fits, else large
def hb.put(fits: Bool, had: Bool, +m: Nat, +n: Nat, b: String, +vi: Nat, +f: String, +v: String) -> Hash:
  match fits:
    case True{}:
      hb.small(m, hb.set(had, b, vi, f, v))
    case False{}:
      HBig{m, hps.trie(hps.put(f, v, hb.pairs(n, b, 0n)), empty(String))}

# a small hash of n pairs b with f's value set to v, where hb.find found
# f (p)
def hb.put.at(+n: Nat, +b: String, p: Nat & Nat, +f: String, +v: String) -> Hash:
  (i, vi) = p
  +had = Nat.is_lt(i, String.length(b))
  +m = Bool.pick(Nat, had, n, 1n+n)
  hb.put(hash.fits(m, f, v), had, m, n, b, vi, f, v)

# h with f's value set to v. The read of f comes before the write: in a
# node built of both the write would run first, the trie held for the
# read after it, and a held trie is shared, so the write would copy the
# path it changes
def hash.put(h: Hash, +f: String, +v: String) -> Hash:
  match h:
    case HSmall{+n, +b}:
      p = hb.find(f, b, n)
      hb.put.at(n, b, p, f, v)
    case HBig{+n, +t}:
      +had = has(String, t, f)
      HBig{Bool.pick(Nat, had, n, 1n+n), set(String, t, f, v)}
    case HLong{+n, ps}:
      hl.put.at(n, hl.set(f, v, ps), f, v)

# h without f, which it holds
def hash.del(h: Hash, +f: String) -> Hash:
  match h:
    case HSmall{+n, +b}:
      p = hb.find(f, b, n)
      HSmall{Nat.sub(n, 1n), hb.del(b, p)}
    case HBig{+n, t}:
      HBig{Nat.sub(n, 1n), del(String, t, f)}
    case HLong{+n, ps}:
      hl.hash(Nat.sub(n, 1n), hl.cut(f, ps))

# the pairs of h, in its order (a small hash's, the order they came)
def hash.pairs(+h: Hash) -> List<&2, HPair>:
  match h:
    case HSmall{+n, +b}:
      hb.pairs(n, b, 0n)
    case HBig{n, +t}:
      hash.kv(t, keys(String, t, 0n))
    case HLong{n, +ps}:
      hl.pairs(ps)

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
# a sorted set's is, zt.build below): a walk with a list of jobs:
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
# member (bytes, as memcmp orders them, a prefix first: String.order).
# Redis 7.0 keeps a sorted set as a listpack while it holds at most
# zset-max-listpack-entries elements (128), each member of at most
# zset-max-listpack-value bytes (64), and as a skiplist with a hashtable
# of its members from the first write that passes either, for good.
# BendKV keeps a small one as the string of its elements in order, and a
# large one as a tree with a trie of its members' scores, turning one
# into the other at those defaults, whatever the parameters say, as it
# does a hash (Hashes, above); OBJECT ENCODING reads the parameters as
# they are (session.bend). A listpack keeps an integral score as an
# integer, so -0 reads back from it as 0: a small sorted set keeps 0 for
# a score of -0, as Redis does. A key never holds an empty sorted set: a
# write that takes its last element deletes it.
#
# A small sorted set's string holds its elements one after another in
# order (Packed strings, above): an element is its member's code, then
# its score's 8 bytes, the double's bits as they are (the high word
# first, each word its high byte first). A read walks the elements from
# the first: to a member as to a hash's field, comparing lengths, then
# last bytes, then bytes; to an element's place by its score, then, for
# the same score, by its member, copied out only then. A write builds the
# string from the pieces of the old one around the element it adds,
# takes or moves, and copies it into one buffer, as a listpack is written
# anew.
#
# The string is one buffer of the C runtime, of at most 2,048 bytes: a
# longer String is a chain of such buffers, and a read by index past the
# first (String.code_at, String.slice, String.length) walks the chain
# from its start, so each walk of the elements would cost their number
# times the chain's length. A small sorted set whose string would pass
# 2,048 bytes is kept as the tree of its elements instead (ZWide), and
# stays so, read as the tree was read before (a member found along it,
# as along a listpack), until it turns large.
#
# The tree (a large sorted set's, and ZWide's) is weight-balanced: each
# node keeps how many elements it holds, so that the element at a rank,
# and the rank of an element, are found in O(log n), and no side of a
# node holds more than 3 times the other (as Adams's trees, and
# Haskell's Data.Map, keep them).

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

# whether a member that compares with a bound of members as c is at
# least the bound (at most it)
def zlb.ge.of(+c: Cmp, +b: ZLB) -> Bool:
  Bool.pick(Bool, zlb.ex(b), Cmp.is_gt(c), Bool.not(Cmp.is_lt(c)))

def zlb.le.of(+c: Cmp, +b: ZLB) -> Bool:
  Bool.pick(Bool, zlb.ex(b), Cmp.is_lt(c), Bool.not(Cmp.is_gt(c)))

def zlb.ge(+m: String, +b: ZLB) -> Bool:
  zlb.ge.of(zlb.cmp(m, b), b)

def zlb.le(+m: String, +b: ZLB) -> Bool:
  zlb.le.of(zlb.cmp(m, b), b)

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
# all its elements in order, as along a listpack (a small sorted set's
# tree, ZWide)
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

# the length of the longest member of t, at least m
def zt.widest(+t: ZTree, +m: Nat) -> Nat:
  match t:
    case ZTip{}:
      m
    case ZBin{n, +k, e, +l, +r}:
      zt.widest(r, zt.widest(l, Nat.max(m, String.length(k))))

# the elements of t added to the trie s, each member with its score
def zt.trie(+t: ZTree, s: Trie<F.F64>) -> Trie<F.F64>:
  match t:
    case ZTip{}:
      s
    case ZBin{n, +k, +e, +l, +r}:
      zt.trie(r, set(F.F64, zt.trie(l, s), k, e))

# The tree of n elements that come in order, made at once: as balanced as
# a tree of them can be, each node made once, where adding the elements
# one at a time copies a path and drops the old one for each (a small
# sorted set turned large, or read as a tree, and RESTORE of a large
# one). A walk with a list of jobs: build a tree of n elements (its left
# side first); take the next element as the root of a node of n whose
# left side is the tree just made (a its size), then build its right
# side; join that node.
type ZJob is Data:
  ZJBuild{n: Nat}
  ZJRoot{n: Nat, a: Nat}
  ZJJoin{n: Nat, e: ZEl, l: ZTree}

def zt.join(+n: Nat, l: ZTree, e: ZEl, r: ZTree) -> ZTree:
  match e:
    case ZEl{m, d}:
      ZBin{n, m, d, l, r}

# the jobs js run on the elements es, t the tree last made (f bounds the
# steps: four for each element and one)
def zt.mach(f: Nat, js: List<&2, ZJob>, es: List<&2, ZEl>, t: ZTree) -> ZTree:
  match f js:
    case 1n+g Con{ZJBuild{n}, rest}:
      match n:
        case 0n:
          zt.mach(g, rest, es, t)
        case 1n+(+k):
          +a = Nat.div(k, 2n)
          zt.mach(g, ZJBuild{a} <> (ZJRoot{1n+k, a} <> rest), es, t)
    case 1n+g Con{ZJRoot{+n, +a}, rest}:
      match es:
        case Con{e, more}:
          zt.mach(g, ZJBuild{Nat.sub(Nat.sub(n, 1n), a)} <> (ZJJoin{n, e, t} <> rest), more, ZTip{})
        case Nil{}:
          t
    case 1n+g Con{ZJJoin{+n, e, l}, rest}:
      zt.mach(g, rest, es, zt.join(n, l, e, t))
    case _ _:
      t

def zt.build(+n: Nat, es: List<&2, ZEl>) -> ZTree:
  zt.mach(Nat.add(Nat.mul(4n, n), 4n), [ZJBuild{n}], es, ZTip{})

# A small sorted set's string (zb): its elements in order, each its
# member's code and its score's 8 bytes (Sorted sets, above).

# the score whose 8 bytes start at index j of b: its high word, then its
# low word, each the high byte first
def zb.score(+b: String, +j: Nat) -> F.F64:
  F.F64{pk.long(4n, b, j, 0n), pk.long(4n, b, Nat.add(j, 4n), 0n)}

# the 8 bytes of the score d, before rest
def zb.score.put(+d: F.F64, rest: String) -> String:
  match d:
    case F.F64{+hi, +lo}:
      pk.long.put(4n, hi, pk.long.put(4n, lo, rest))

# the element of the member m and the score d, before rest
def zb.el(+m: String, +d: F.F64, rest: String) -> String:
  pk.code(String.length(m), m ++ zb.score.put(d, rest))

# the elements es as a small sorted set's string, before rest
def zb.enc(es: List<&2, ZEl>, rest: String) -> String:
  match es:
    case Nil{}:
      rest
    case Con{ZEl{m, +d}, more}:
      zb.el(m, d, zb.enc(more, rest))

# the index past the element at index i of b: past its member, then its
# score
def zb.next(+b: String, +i: Nat) -> Nat:
  Nat.add(pk.end(b, i), 8n)

# How a score d compares with one of the string: by their high words
# when those decide, so that the low word is read only when they do not.
# They decide when they differ, unless both hold no more than a sign (0,
# -0 and numbers below 2^-1042 do): the one with no sign is the greater,
# else the one with the greater high word, or, of two below 0, the less.

# how d, of high word dh, compares with a score of high word eh, EQ when
# they do not decide (open); dneg and eneg: whether they have a sign
def zb.hcmp.of(open: Bool, dneg: Bool, eneg: Bool, +dh: Nat, +eh: Nat) -> Cmp:
  match open dneg eneg:
    case True{} _ _:
      EQ{}
    case False{} True{} False{}:
      LT{}
    case False{} False{} True{}:
      GT{}
    case False{} False{} False{}:
      Nat.cmp(dh, eh)
    case False{} True{} True{}:
      Nat.cmp(eh, dh)

def zb.hcmp(+dh: Nat, +eh: Nat) -> Cmp:
  +tiny = Bool.and(Nat.is_eq(Nat.mod(dh, 2147483648n), 0n), Nat.is_eq(Nat.mod(eh, 2147483648n), 0n))
  zb.hcmp.of(Bool.or(Nat.is_eq(dh, eh), tiny), Nat.is_le(2147483648n, dh), Nat.is_le(2147483648n, eh), dh, eh)

def zb.dcmp.of(c: Cmp, +d: F.F64, +b: String, +j: Nat, +eh: Nat) -> Cmp:
  match c:
    case EQ{}:
      F.f64.cmp(d, F.F64{eh, pk.long(4n, b, Nat.add(j, 4n), 0n)})
    case LT{}:
      LT{}
    case GT{}:
      GT{}

def zb.hi(+d: F.F64) -> Nat:
  match d:
    case F.F64{+hi, lo}:
      hi

# how d compares with the score whose 8 bytes start at index j of b
def zb.dcmp(+d: F.F64, +b: String, +j: Nat) -> Cmp:
  +eh = pk.long(4n, b, j, 0n)
  zb.dcmp.of(zb.hcmp(zb.hi(d), eh), d, b, j, eh)

# how (d, m) compares with an element whose score compares with d as c,
# its member the n bytes from index mi of b: by score, then by member
def zb.cmp.of(c: Cmp, +m: String, +b: String, +mi: Nat, +n: Nat) -> Cmp:
  match c:
    case EQ{}:
      String.order(m, String.slice(b, mi, n))
    case LT{}:
      LT{}
    case GT{}:
      GT{}

# how (d, m) compares with the element at index i of b, the first of k
# elements from there on, whose member is n bytes long (GT for none)
def zb.cmp(k: Nat, +d: F.F64, +m: String, +b: String, +i: Nat, +n: Nat) -> Cmp:
  match k:
    case 0n:
      GT{}
    case 1n+j:
      +mi = Nat.add(i, pk.hdr(n))
      zb.cmp.of(zb.dcmp(d, b, Nat.add(mi, n)), m, b, mi, n)

# the index of the first of the k elements from index i of b on that
# comes after (d, m), past them all when none does; c is how (d, m)
# compares with the element at i, whose member is n bytes long
def zb.pos.go(+d: F.F64, +m: String, +b: String, k: Nat, c: Cmp, +i: Nat, +n: Nat) -> Nat:
  match k c:
    case 0n _:
      i
    case 1n+j LT{}:
      i
    case 1n++j _:
      +x = Nat.add(Nat.add(i, Nat.add(pk.hdr(n), n)), 8n)
      +xn = pk.len.if(j, b, x)
      zb.pos.go(d, m, b, j, zb.cmp(j, d, m, b, x, xn), x, xn)

def zb.pos.of(last: Bool, +d: F.F64, +m: String, +b: String, +k: Nat) -> Nat:
  match last:
    case True{}:
      String.length(b)
    case False{}:
      +n = pk.len.if(k, b, 0n)
      zb.pos.go(d, m, b, k, zb.cmp(k, d, m, b, 0n, n), 0n, n)

# where (d, m) goes among the k elements of b: the index of the first
# element after it (m's own, when it is there, has another score). Past
# them all at once when d is above the last score, b's last 8 bytes:
# elements that come in order of score each go there, as those of an
# append-only file or of a STORE do.
def zb.pos(+d: F.F64, +m: String, +b: String, +k: Nat) -> Nat:
  zb.pos.of(Bool.and(Nat.is_lt(0n, k), Cmp.is_gt(zb.dcmp(d, b, Nat.sub(String.length(b), 8n)))), d, m, b, k)

# Where an element is in b (zb.find): the index it starts at, the index
# its score starts at, and how many elements there are from it on; when
# there is none, the index past the elements twice, and 0.
type ZAt is Data:
  ZAt{i: Nat, s: Nat, k: Nat}

# m's element among the k elements from index i of b on, the first of
# them with a member of n bytes (m: lm bytes long, its last byte lb); hit
# is pk.hit(k, m, lm, lb, b, i, n), computed before b is passed on
def zb.find.go(+m: String, +lm: Nat, +lb: U32, +b: String, k: Nat, hit: Bool, +i: Nat, +n: Nat) -> ZAt:
  match k hit:
    case 0n _:
      ZAt{i, i, 0n}
    case 1n+j True{}:
      ZAt{i, Nat.add(i, Nat.add(pk.hdr(n), n)), 1n+j}
    case 1n++j False{}:
      +x = Nat.add(Nat.add(i, Nat.add(pk.hdr(n), n)), 8n)
      +xn = pk.len.if(j, b, x)
      zb.find.go(m, lm, lb, b, j, pk.hit(j, m, lm, lb, b, x, xn), x, xn)

# m's element in the string b of a small sorted set of k elements, found
# as a hash's field is (Hashes, above)
def zb.find(+m: String, +b: String, +k: Nat) -> ZAt:
  +lm = String.length(m)
  +lb = String.code_at(m, Nat.sub(lm, 1n))
  +n = pk.len.if(k, b, 0n)
  zb.find.go(m, lm, lb, b, k, pk.hit(k, m, lm, lb, b, 0n, n), 0n, n)

def zb.get.of(k: Nat, +b: String, +s: Nat) -> Maybe<&2, F.F64>:
  match k:
    case 0n:
      None{}
    case 1n+j:
      Some{zb.score(b, s)}

# the score of the element zb.find found
def zb.get(+b: String, at: ZAt) -> Maybe<&2, F.F64>:
  match at:
    case ZAt{i, +s, k}:
      zb.get.of(k, b, s)

def zb.rank.of(k: Nat, +n: Nat) -> Maybe<&2, Nat>:
  match k:
    case 0n:
      None{}
    case 1n+j:
      Some{Nat.sub(n, 1n+j)}

# the rank of the element zb.find found, one of n
def zb.rank(+n: Nat, at: ZAt) -> Maybe<&2, Nat>:
  match at:
    case ZAt{i, s, k}:
      zb.rank.of(k, n)

def zb.del.of(k: Nat, +b: String, +i: Nat, +s: Nat) -> String:
  match k:
    case 0n:
      b
    case 1n+j:
      pk.cut(b, i, Nat.add(s, 8n))

# b without the element zb.find found (b when it found none)
def zb.del(+b: String, at: ZAt) -> String:
  match at:
    case ZAt{+i, +s, k}:
      zb.del.of(k, b, i, s)

# b with the element (m, d) at index p
def zb.ins(+b: String, +p: Nat, +m: String, +d: F.F64) -> String:
  +lm = String.length(m)
  +n = Nat.add(String.length(b), Nat.add(Nat.add(pk.hdr(lm), lm), 8n))
  +pre = String.take(b, p)
  pk.flat(pre ++ zb.el(m, d, String.drop(b, p)), n)

# b with its element from index i to index e, m's, taken out and (m, d)
# put at index p, where it goes: before it (p at most i), or after it (p
# at least e). The element keeps its length, and b its own.
def zb.move.of(before: Bool, +b: String, +i: Nat, +e: Nat, +p: Nat, +m: String, +d: F.F64) -> String:
  match before:
    case True{}:
      +pre = String.take(b, p)
      pk.flat(pre ++ zb.el(m, d, String.slice(b, p, Nat.sub(i, p)) ++ String.drop(b, e)), String.length(b))
    case False{}:
      +pre = String.take(b, i)
      pk.flat(pre ++ (String.slice(b, e, Nat.sub(p, e)) ++ zb.el(m, d, String.drop(b, p))), String.length(b))

# b, of k elements, with m's score set to d, m's element at index i:
# moved where (d, m) goes, in one copy
def zb.set(+b: String, +k: Nat, +i: Nat, +m: String, +d: F.F64) -> String:
  +p = zb.pos(d, m, b, k)
  zb.move.of(Nat.is_le(p, i), b, i, zb.next(b, i), p, m, d)

# the index of the element a elements on from the one at index i of b
def zb.skip(a: Nat, +b: String, +i: Nat) -> Nat:
  match a:
    case 0n:
      i
    case 1n+j:
      zb.skip(j, b, zb.next(b, i))

# the element at index i of b
def zb.at(+b: String, +i: Nat) -> ZEl:
  +l = pk.len(b, i)
  +mi = Nat.add(i, pk.hdr(l))
  ZEl{String.slice(b, mi, l), zb.score(b, Nat.add(mi, l))}

# the k elements from index i of b on, the last first, before acc
def zb.els.rev(k: Nat, +b: String, +i: Nat, acc: List<&2, ZEl>) -> List<&2, ZEl>:
  match k:
    case 0n:
      acc
    case 1n+j:
      +l = pk.len(b, i)
      +mi = Nat.add(i, pk.hdr(l))
      +s = Nat.add(mi, l)
      zb.els.rev(j, b, Nat.add(s, 8n), ZEl{String.slice(b, mi, l), zb.score(b, s)} <> acc)

# the n elements of b, in order: a walk that keeps no frame for each
# element, then the list turned around
def zb.all(+n: Nat, +b: String) -> List<&2, ZEl>:
  List.reverse(&2, ZEl, zb.els.rev(n, b, 0n, Nil{}))

def zb.slice.of(rev: Bool, xs: List<&2, ZEl>) -> List<&2, ZEl>:
  match rev:
    case True{}:
      xs
    case False{}:
      List.reverse(&2, ZEl, xs)

# the elements of b, of n, at the ranks from a to c - 1, in order (last
# first when rev)
def zb.slice(rev: Bool, +n: Nat, +b: String, +a: Nat, +c: Nat) -> List<&2, ZEl>:
  +e = Nat.min(c, n)
  +s = Nat.min(a, e)
  zb.slice.of(rev, zb.els.rev(Nat.sub(e, s), b, zb.skip(s, b, 0n), Nil{}))

# whether the score whose 8 bytes start at index j of b is at least a
# bound of scores (zsb.ge), or at most one (zsb.le)
def zb.sge(+b: String, +j: Nat, +bd: ZSB) -> Bool:
  match bd:
    case ZSB{+d, +ex}:
      +c = zb.dcmp(d, b, j)
      Bool.pick(Bool, ex, Cmp.is_lt(c), Bool.not(Cmp.is_gt(c)))

def zb.sle(+b: String, +j: Nat, +bd: ZSB) -> Bool:
  match bd:
    case ZSB{+d, +ex}:
      +c = zb.dcmp(d, b, j)
      Bool.pick(Bool, ex, Cmp.is_gt(c), Bool.not(Cmp.is_lt(c)))

# how the member whose code starts at index i of b compares with a bound
# of members (zlb.cmp)
def zb.lcmp.of(+b: String, +mi: Nat, +n: Nat, +bd: ZLB) -> Cmp:
  match bd:
    case ZLNeg{}:
      GT{}
    case ZLPos{}:
      LT{}
    case ZLIn{+s}:
      String.order(String.slice(b, mi, n), s)
    case ZLEx{+s}:
      String.order(String.slice(b, mi, n), s)

def zb.lcmp(+b: String, +i: Nat, +bd: ZLB) -> Cmp:
  +n = pk.len(b, i)
  zb.lcmp.of(b, Nat.add(i, pk.hdr(n)), n, bd)

# whether p holds of the element at index i of b (zp.ok): of its score,
# or of its member, which is copied out only for a test of members
def zb.ok(+p: ZP, +b: String, +i: Nat) -> Bool:
  match p:
    case ZGeS{+bd}:
      zb.sge(b, pk.end(b, i), bd)
    case ZLeS{+bd}:
      zb.sle(b, pk.end(b, i), bd)
    case ZGeL{+bd}:
      zlb.ge.of(zb.lcmp(b, i, bd), bd)
    case ZLeL{+bd}:
      zlb.le.of(zb.lcmp(b, i, bd), bd)
    case ZGtS{+bd}:
      Bool.not(zb.sle(b, pk.end(b, i), bd))
    case ZGtL{+bd}:
      Bool.not(zlb.le.of(zb.lcmp(b, i, bd), bd))

def zb.ok.if(k: Nat, +p: ZP, +b: String, +i: Nat) -> Bool:
  match k:
    case 0n:
      True{}
    case 1n+j:
      zb.ok(p, b, i)

# how many of the k elements from index i of b on come before the first
# that p holds of, after acc, when p holds of none of the first and of
# all the others (zt.before); ok is whether p holds of the element at i
def zb.before.go(+b: String, k: Nat, ok: Bool, +p: ZP, +i: Nat, +acc: Nat) -> Nat:
  match k ok:
    case 0n _:
      acc
    case 1n+j True{}:
      acc
    case 1n++j False{}:
      +x = zb.next(b, i)
      zb.before.go(b, j, zb.ok.if(j, p, b, x), p, x, Nat.add(acc, 1n))

def zb.before(+n: Nat, +b: String, +p: ZP) -> Nat:
  zb.before.go(b, n, zb.ok.if(n, p, b, 0n), p, 0n, 0n)

# the length of the longest member of the k elements from index i of b
# on, at least m
def zb.widest(k: Nat, +b: String, +i: Nat, +m: Nat) -> Nat:
  match k:
    case 0n:
      m
    case 1n+j:
      +l = pk.len(b, i)
      zb.widest(j, b, Nat.add(Nat.add(i, Nat.add(pk.hdr(l), l)), 8n), Nat.max(m, l))

# the score a listpack keeps for d: 0 for -0
def zset.norm(+d: F.F64) -> F.F64:
  match d:
    case F.F64{+hi, +lo}:
      Bool.pick(F.F64, Bool.and(Nat.is_eq(hi, 2147483648n), Nat.is_eq(lo, 0n)), F.F64{0n, 0n}, F.F64{hi, lo})

def zset.empty() -> Zset:
  ZSmall{0n, ""}

# how many bytes the elements es take in a small sorted set's string,
# after acc
def zb.size(+es: List<&2, ZEl>, +acc: Nat) -> Nat:
  match es:
    case Nil{}:
      acc
    case Con{ZEl{+m, d}, rest}:
      +l = String.length(m)
      zb.size(rest, Nat.add(acc, Nat.add(Nat.add(pk.hdr(l), l), 8n)))

def zset.of.at(room: Bool, +n: Nat, +l: Nat, es: List<&2, ZEl>) -> Zset:
  match room:
    case True{}:
      ZSmall{n, pk.flat(zb.enc(es, ""), l)}
    case False{}:
      ZWide{zt.build(n, es)}

# a small sorted set of the n elements es, which come in order (RESTORE):
# their string when it fits one buffer, else their tree
def zset.of(+n: Nat, +es: List<&2, ZEl>) -> Zset:
  +l = zb.size(es, 0n)
  zset.of.at(Nat.is_le(l, 2048n), n, l, es)

# z's elements as a tree: a large one's own, a small one's (ZWide), or
# one made from a small one's string (ZRANDMEMBER's many picks and its
# third way read them as a tree)
def zset.tree(+z: Zset) -> ZTree:
  match z:
    case ZSmall{+n, +b}:
      zt.build(n, zb.all(n, b))
    case ZWide{+tr}:
      tr
    case ZBig{+tr, t}:
      tr

# (a field of z, which a read borrows, not a tree computed from it: a
# computed tree passed to zt.size would have every reader of a size own
# the node it reads, and copy it when the tree shares it)
def zset.len(+z: Zset) -> Nat:
  match z:
    case ZSmall{+n, b}:
      n
    case ZWide{tr}:
      zt.size(tr)
    case ZBig{tr, t}:
      zt.size(tr)

def zset.is_small(+z: Zset) -> Bool:
  match z:
    case ZSmall{n, b}:
      True{}
    case ZWide{tr}:
      True{}
    case ZBig{tr, t}:
      False{}

# m's score, when z holds m
def zset.score(+m: String, +z: Zset) -> Maybe<&2, F.F64>:
  match z:
    case ZSmall{+n, +b}:
      zb.get(b, zb.find(m, b, n))
    case ZWide{+tr}:
      zt.find(tr, m)
    case ZBig{tr, +t}:
      get(F.F64, t, m)

# m's score, when z holds m, and where a small one's string holds m's
# element (0 for a tree): zset.set and zset.del take it, so that a write
# walks to m once
type ZHit is Data:
  ZNo{}
  ZYes{d: F.F64, i: Nat}

def zb.hit.of(k: Nat, +b: String, +i: Nat, +s: Nat) -> ZHit:
  match k:
    case 0n:
      ZNo{}
    case 1n+j:
      ZYes{zb.score(b, s), i}

def zb.hit(+b: String, at: ZAt) -> ZHit:
  match at:
    case ZAt{+i, +s, k}:
      zb.hit.of(k, b, i, s)

def zset.hit.big(m: Maybe<&2, F.F64>) -> ZHit:
  match m:
    case Some{d}:
      ZYes{d, 0n}
    case None{}:
      ZNo{}

def zset.find(+m: String, +z: Zset) -> ZHit:
  match z:
    case ZSmall{+n, +b}:
      zb.hit(b, zb.find(m, b, n))
    case ZWide{+tr}:
      zset.hit.big(zt.find(tr, m))
    case ZBig{tr, +t}:
      zset.hit.big(get(F.F64, t, m))

def zt.rank.at(s: Maybe<&2, F.F64>, +t: ZTree, +m: String) -> Maybe<&2, Nat>:
  match s:
    case Some{+d}:
      Some{zt.rank(t, m, d)}
    case None{}:
      None{}

# how many elements of z come before m's, when z holds m: a small one's
# in the walk that finds m
def zset.rank(+m: String, +z: Zset) -> Maybe<&2, Nat>:
  match z:
    case ZSmall{+n, +b}:
      zb.rank(n, zb.find(m, b, n))
    case ZWide{+tr}:
      zt.rank.at(zt.find(tr, m), tr, m)
    case ZBig{+tr, +t}:
      zt.rank.at(get(F.F64, t, m), tr, m)

# z with m of score d added (z does not hold m): a small one turns large
# when it would pass 128 elements, or m passes 64 bytes, and a small
# one's string turns its tree when it would pass one buffer
def zset.add.packed(room: Bool, +n: Nat, +b: String, +m: String, +e: F.F64) -> Zset:
  match room:
    case True{}:
      ZSmall{1n+n, zb.ins(b, zb.pos(e, m, b, n), m, e)}
    case False{}:
      ZWide{zt.add(zt.build(n, zb.all(n, b)), m, e)}

def zset.add.small(fits: Bool, +n: Nat, +b: String, +m: String, +d: F.F64) -> Zset:
  match fits:
    case True{}:
      +lm = String.length(m)
      zset.add.packed(Nat.is_le(Nat.add(String.length(b), Nat.add(Nat.add(pk.hdr(lm), lm), 8n)), 2048n), n, b, m, zset.norm(d))
    case False{}:
      +tr = zt.build(n, zb.all(n, b))
      ZBig{zt.add(tr, m, d), set(F.F64, zt.trie(tr, empty(F.F64)), m, d)}

def zset.add.wide(fits: Bool, +tr: ZTree, +m: String, +d: F.F64) -> Zset:
  match fits:
    case True{}:
      ZWide{zt.add(tr, m, zset.norm(d))}
    case False{}:
      ZBig{zt.add(tr, m, d), set(F.F64, zt.trie(tr, empty(F.F64)), m, d)}

def zset.add(z: Zset, +m: String, +d: F.F64) -> Zset:
  match z:
    case ZSmall{+n, +b}:
      zset.add.small(Bool.and(Nat.is_lt(n, 128n), Nat.is_le(String.length(m), 64n)), n, b, m, d)
    case ZWide{+tr}:
      zset.add.wide(Bool.and(Nat.is_lt(zt.size(tr), 128n), Nat.is_le(String.length(m), 64n)), tr, m, d)
    case ZBig{+tr, +t}:
      ZBig{zt.add(tr, m, d), set(F.F64, t, m, d)}

# z without m, which it holds with score d
def zset.del(z: Zset, +m: String, +d: F.F64) -> Zset:
  match z:
    case ZSmall{+n, +b}:
      ZSmall{Nat.sub(n, 1n), zb.del(b, zb.find(m, b, n))}
    case ZWide{+tr}:
      ZWide{zt.del(tr, m, d)}
    case ZBig{+tr, +t}:
      ZBig{zt.del(tr, m, d), del(F.F64, t, m)}

# z without m, which it holds with score d, its element at index i of a
# small one's string (zset.find)
def zset.del.at(z: Zset, +i: Nat, +m: String, +d: F.F64) -> Zset:
  match z:
    case ZSmall{+n, +b}:
      ZSmall{Nat.sub(n, 1n), pk.cut(b, i, zb.next(b, i))}
    case ZWide{+tr}:
      ZWide{zt.del(tr, m, d)}
    case ZBig{+tr, +t}:
      ZBig{zt.del(tr, m, d), del(F.F64, t, m)}

# z with m's score, old, set to d, m's element at index i of a small
# one's string (zset.find)
def zset.set(z: Zset, +i: Nat, +m: String, +old: F.F64, +d: F.F64) -> Zset:
  match z:
    case ZSmall{+n, +b}:
      ZSmall{n, zb.set(b, n, i, m, zset.norm(d))}
    case ZWide{+tr}:
      ZWide{zt.add(zt.del(tr, m, old), m, zset.norm(d))}
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
    case ZSmall{+n, +s}:
      zb.slice(rev, n, s, a, b)
    case ZWide{tr}:
      zset.slice.of(rev, tr, a, b)
    case ZBig{tr, t}:
      zset.slice.of(rev, tr, a, b)

# all the elements of z, in order
def zset.all(+z: Zset) -> List<&2, ZEl>:
  match z:
    case ZSmall{+n, +b}:
      zb.all(n, b)
    case ZWide{tr}:
      zt.all(tr)
    case ZBig{tr, t}:
      zt.all(tr)

# how many elements of z come before the first that p holds of, when p
# holds of none of the first elements and of all the others (zt.before)
def zset.before(+z: Zset, +p: ZP) -> Nat:
  match z:
    case ZSmall{+n, +b}:
      zb.before(n, b, p)
    case ZWide{tr}:
      zt.before(tr, p)
    case ZBig{tr, t}:
      zt.before(tr, p)

# the element at rank i of z (i below its size)
def zset.nth(+z: Zset, +i: Nat) -> ZEl:
  match z:
    case ZSmall{n, +b}:
      zb.at(b, zb.skip(i, b, 0n))
    case ZWide{tr}:
      zt.nth(tr, i)
    case ZBig{tr, t}:
      zt.nth(tr, i)

# z without the elements xs, which it holds
def zset.dels(xs: List<&2, ZEl>, z: Zset) -> Zset:
  match xs:
    case Nil{}:
      z
    case Con{ZEl{+m, +d}, rest}:
      zset.dels(rest, zset.del(z, m, d))

# Streams
# -------
# A stream (XStream, above) as Redis 7.0 keeps one: its entries in nodes
# of a radix tree by master ID, each node a listpack (here a tree by
# master ID, each node the bytes of its entries), and its consumer groups
# by name, each with its pending entries by ID and its consumers by name.
# Its numbers are 64-bit, and each is split in decimal at 10^14, so that
# no Nat passes 2^48 (XN, above); their arithmetic runs at run time only
# (no proof computes 10^14: the checker counts in unary).

# 10^14 (a literal stops at 2^32 - 1)
def xn.e14() -> Nat:
  Nat.mul(100000000n, 1000000n)

# the low part of 2^64 = 184467 * 10^14 + 44073709551616
def xn.top.lo() -> Nat:
  Nat.add(Nat.mul(4407370n, 10000000n), 9551616n)

# hi * 10^14 + lo (lo below 10^14) in its one form
def xn.of2(+hi: Nat, +lo: Nat) -> XN:
  match hi:
    case 0n:
      XS{lo}
    case 1n+h:
      XL{1n+h, lo}

# n (below 2^48)
def xn.of(+n: Nat) -> XN:
  +e = xn.e14()
  xn.of2(Nat.div(n, e), Nat.mod(n, e))

def xn.hi(+a: XN) -> Nat:
  match a:
    case XS{n}:
      0n
    case XL{+h, l}:
      h

def xn.lo(+a: XN) -> Nat:
  match a:
    case XS{+n}:
      n
    case XL{h, +l}:
      l

def xn.cmp.lo(c: Cmp, +a: Nat, +b: Nat) -> Cmp:
  match c:
    case EQ{}:
      Nat.cmp(a, b)
    case LT{}:
      LT{}
    case GT{}:
      GT{}

# how a compares with b (XS below XL: each number has one form)
def xn.cmp(+a: XN, +b: XN) -> Cmp:
  match a b:
    case XS{+x} XS{+y}:
      Nat.cmp(x, y)
    case XS{x} XL{h, l}:
      LT{}
    case XL{h, l} XS{y}:
      GT{}
    case XL{+h, +l} XL{+g, +k}:
      xn.cmp.lo(Nat.cmp(h, g), l, k)

def xn.is_eq(+a: XN, +b: XN) -> Bool:
  match a b:
    case XS{+x} XS{+y}:
      Nat.is_eq(x, y)
    case XL{+h, +l} XL{+g, +k}:
      Bool.and(Nat.is_eq(h, g), Nat.is_eq(l, k))
    case _ _:
      False{}

# hi * 10^14 + lo mod 2^64 (lo below 10^14, the number below 2^65)
def xn.wrap.of(ge: Bool, +hi: Nat, +lo: Nat) -> XN:
  match ge:
    case False{}:
      xn.of2(hi, lo)
    case True{}:
      +t = xn.top.lo()
      +b = Nat.is_lt(lo, t)
      xn.of2(Nat.sub(Nat.sub(hi, 184467n), Bool.pick(Nat, b, 1n, 0n)), Nat.sub(Nat.add(lo, Bool.pick(Nat, b, xn.e14(), 0n)), t))

def xn.wrap(+hi: Nat, +lo: Nat) -> XN:
  xn.wrap.of(Bool.or(Nat.is_lt(184467n, hi), Bool.and(Nat.is_eq(hi, 184467n), Nat.is_le(xn.top.lo(), lo))), hi, lo)

def xn.add.of(+hi: Nat, +lo: Nat) -> XN:
  +e = xn.e14()
  +c = Nat.is_le(e, lo)
  xn.wrap(Nat.add(hi, Bool.pick(Nat, c, 1n, 0n)), Bool.pick(Nat, c, Nat.sub(lo, e), lo))

# a + b mod 2^64
def xn.add(+a: XN, +b: XN) -> XN:
  xn.add.of(Nat.add(xn.hi(a), xn.hi(b)), Nat.add(xn.lo(a), xn.lo(b)))

def xn.neg.of(le: Bool, +h: Nat, +l: Nat) -> XN:
  match le:
    case True{}:
      xn.wrap(Nat.sub(184467n, h), Nat.sub(xn.top.lo(), l))
    case False{}:
      xn.wrap(Nat.sub(184466n, h), Nat.sub(Nat.add(xn.top.lo(), xn.e14()), l))

# 2^64 - a mod 2^64: the two's complement of a, as a uint64_t negates
def xn.neg(+a: XN) -> XN:
  +l = xn.lo(a)
  xn.neg.of(Nat.is_le(l, xn.top.lo()), xn.hi(a), l)

# s with zeros before it, k of them
def xn.pad(k: Nat, +s: String) -> String:
  match k:
    case 0n:
      s
    case 1n+j:
      xn.pad(j, "0" ++ s)

# a's digits, as Redis prints a uint64_t (%llu)
def xn.show(+a: XN) -> String:
  match a:
    case XS{+n}:
      Nat.show(n)
    case XL{+h, +l}:
      +s = Nat.show(l)
      Nat.show(h) ++ xn.pad(Nat.sub(14n, String.length(s)), s)

def xn.dec.of(short: Bool, +s: String, +a: Nat, +d: Nat) -> XN:
  match short:
    case True{}:
      XS{String.dec_at(s, a, d)}
    case False{}:
      +k = Nat.sub(d, 14n)
      xn.of2(String.dec_at(s, a, k), String.dec_at(s, Nat.add(a, k), 14n))

# the number of the d digits of s from index a on (d at most 20, the
# number below 2^64)
def xn.dec(+s: String, +a: Nat, +d: Nat) -> XN:
  xn.dec.of(Nat.is_le(d, 14n), s, a, d)

def xn.of_int.of(neg: Bool, +s: String, +n: Nat) -> XN:
  match neg:
    case True{}:
      xn.neg(xn.dec(s, 1n, Nat.sub(n, 1n)))
    case False{}:
      xn.dec(s, 0n, n)

# the 64 bits of the integer whose text is s (a long long's, as
# ll2string writes one), as a uint64_t holds them
def xn.of_int(+s: String) -> XN:
  xn.of_int.of(U32.is_eq(String.code_at(s, 0n), 45), s, String.length(s))

def xid.cmp.of(c: Cmp, +a: XN, +b: XN) -> Cmp:
  match c:
    case EQ{}:
      xn.cmp(a, b)
    case LT{}:
      LT{}
    case GT{}:
      GT{}

# how ID a compares with ID b: by time, then by sequence
def xid.cmp(+a: XId, +b: XId) -> Cmp:
  match a b:
    case XId{+am, +aq} XId{+bm, +bq}:
      xid.cmp.of(xn.cmp(am, bm), aq, bq)

# the keys of the trees below
def xnode.mid(+x: XNode) -> XId:
  match x:
    case XNd{+mid, mfs, live, dead, bytes, nel, es}:
      mid
    case XNdOf{+y}:
      xnode.mid(y)

def xnack.id(+x: XNack) -> XId:
  match x:
    case XNk{+id, owner, time, count}:
      id
    case XNkOf{+y}:
      xnack.id(y)

# a node's listpack's size in bytes
def xnode.bytes(+x: XNode) -> Nat:
  match x:
    case XNd{mid, mfs, live, dead, +bytes, nel, es}:
      bytes
    case XNdOf{+y}:
      xnode.bytes(y)

# a stream's count of live entries
def xstream.len(+x: XStream) -> Nat:
  match x:
    case XStr{+n, last, first, maxdel, added, nodes, groups}:
      n
    case XStrOf{+y}:
      xstream.len(y)

def xid.self(+x: XId) -> XId:
  x

def xcon.name(+x: XCon) -> String:
  match x:
    case XCon{+name, seen, ids}:
      name

def xgroup.name(+x: XGroup) -> String:
  match x:
    case XGrp{+name, last, read, pel, cons}:
      name
    case XGrpOf{+y}:
      xgroup.name(y)

# The trees of a stream: weight-balanced, as an intset's (ITree, Sets,
# above), one shape for each kind of element and its key (written by
# tools/gen_streams.py)
# BEGIN gen_streams: trees
# XNodes, by ID (xns)

def xns.size(+t: XNodes) -> Nat:
  match t:
    case XNTip{}:
      0n
    case XNBin{n, x, l, r}:
      n

def xns.bin(+x: XNode, +l: XNodes, +r: XNodes) -> XNodes:
  XNBin{Nat.add(Nat.add(xns.size(l), xns.size(r)), 1n), x, l, r}

# how the key k compares with t's root's (GT for a tip)
def xns.at(+t: XNodes, +k: XId) -> Cmp:
  match t:
    case XNTip{}:
      GT{}
    case XNBin{n, +x, l, r}:
      xid.cmp(k, xnode.mid(x))

def xns.dbll(+x: XNode, l: XNodes, +rx: XNode, rr: XNodes, rl: XNodes) -> XNodes:
  match rl:
    case XNTip{}:
      xns.bin(rx, xns.bin(x, l, XNTip{}), rr)
    case XNBin{n, +y, +yl, +yr}:
      xns.bin(y, xns.bin(x, l, yl), xns.bin(rx, yr, rr))

def xns.rotl.of(single: Bool, +x: XNode, l: XNodes, +rx: XNode, rl: XNodes, rr: XNodes) -> XNodes:
  match single:
    case True{}:
      xns.bin(rx, xns.bin(x, l, rl), rr)
    case False{}:
      xns.dbll(x, l, rx, rr, rl)

def xns.rotl(+x: XNode, l: XNodes, r: XNodes) -> XNodes:
  match r:
    case XNTip{}:
      xns.bin(x, l, XNTip{})
    case XNBin{n, +rx, +rl, +rr}:
      xns.rotl.of(Nat.is_lt(xns.size(rl), Nat.mul(2n, xns.size(rr))), x, l, rx, rl, rr)

def xns.dblr(+x: XNode, r: XNodes, +lx: XNode, ll: XNodes, lr: XNodes) -> XNodes:
  match lr:
    case XNTip{}:
      xns.bin(lx, ll, xns.bin(x, XNTip{}, r))
    case XNBin{n, +y, +yl, +yr}:
      xns.bin(y, xns.bin(lx, ll, yl), xns.bin(x, yr, r))

def xns.rotr.of(single: Bool, +x: XNode, r: XNodes, +lx: XNode, ll: XNodes, lr: XNodes) -> XNodes:
  match single:
    case True{}:
      xns.bin(lx, ll, xns.bin(x, lr, r))
    case False{}:
      xns.dblr(x, r, lx, ll, lr)

def xns.rotr(+x: XNode, l: XNodes, r: XNodes) -> XNodes:
  match l:
    case XNTip{}:
      xns.bin(x, XNTip{}, r)
    case XNBin{n, +lx, +ll, +lr}:
      xns.rotr.of(Nat.is_lt(xns.size(lr), Nat.mul(2n, xns.size(ll))), x, r, lx, ll, lr)

def xns.bal.of(few: Bool, rh: Bool, lh: Bool, +x: XNode, l: XNodes, r: XNodes) -> XNodes:
  match few rh lh:
    case True{} _ _:
      xns.bin(x, l, r)
    case False{} True{} _:
      xns.rotl(x, l, r)
    case False{} False{} True{}:
      xns.rotr(x, l, r)
    case False{} False{} False{}:
      xns.bin(x, l, r)

def xns.balance(+x: XNode, +l: XNodes, +r: XNodes) -> XNodes:
  +sl = xns.size(l)
  +sr = xns.size(r)
  xns.bal.of(Nat.is_le(Nat.add(sl, sr), 1n), Nat.is_lt(Nat.mul(3n, sl), sr), Nat.is_lt(Nat.mul(3n, sr), sl), x, l, r)

# the element of key k in t; c is how k compares with t's root's
def xns.find(+t: XNodes, c: Cmp, +k: XId) -> Maybe<&2, XNode>:
  match t c:
    case XNTip{} _:
      None{}
    case XNBin{n, x, +l, r} LT{}:
      xns.find(l, xns.at(l, k), k)
    case XNBin{n, x, l, +r} GT{}:
      xns.find(r, xns.at(r, k), k)
    case XNBin{n, +x, l, r} EQ{}:
      Some{x}

# t with x in its place (t holds no element of x's key); c is how x's key
# compares with t's root's
def xns.ins(t: XNodes, c: Cmp, +x: XNode) -> XNodes:
  match t c:
    case XNTip{} _:
      XNBin{1n, x, XNTip{}, XNTip{}}
    case XNBin{n, +y, +l, +r} LT{}:
      xns.balance(y, xns.ins(l, xns.at(l, xnode.mid(x)), x), r)
    case XNBin{n, +y, +l, +r} _:
      xns.balance(y, l, xns.ins(r, xns.at(r, xnode.mid(x)), x))

def xns.put(+x: XNode, +t: XNodes) -> XNodes:
  xns.ins(t, xns.at(t, xnode.mid(x)), x)

# t with x in the place of the element of x's key, which t holds; c is
# how x's key compares with t's root's
def xns.rep(t: XNodes, c: Cmp, +x: XNode) -> XNodes:
  match t c:
    case XNTip{} _:
      XNTip{}
    case XNBin{+n, +y, +l, +r} LT{}:
      XNBin{n, y, xns.rep(l, xns.at(l, xnode.mid(x)), x), r}
    case XNBin{+n, +y, +l, +r} GT{}:
      XNBin{n, y, l, xns.rep(r, xns.at(r, xnode.mid(x)), x)}
    case XNBin{+n, y, +l, +r} EQ{}:
      XNBin{n, x, l, r}

def xns.set(+x: XNode, +t: XNodes) -> XNodes:
  xns.rep(t, xns.at(t, xnode.mid(x)), x)

# a node's element, made before the walk goes on (as it.el)
def xns.el(+x: XNode) -> XNode:
  x

# the elements of t in order, before acc
def xns.list(+t: XNodes, acc: List<&2, XNode>) -> List<&2, XNode>:
  match t:
    case XNTip{}:
      acc
    case XNBin{n, +x, +l, +r}:
      y = xns.el(x)
      acc2 = xns.list(r, acc)
      xns.list(l, y <> acc2)

# XPel, by ID (xpl)

def xpl.size(+t: XPel) -> Nat:
  match t:
    case XPTip{}:
      0n
    case XPBin{n, x, l, r}:
      n

def xpl.bin(+x: XNack, +l: XPel, +r: XPel) -> XPel:
  XPBin{Nat.add(Nat.add(xpl.size(l), xpl.size(r)), 1n), x, l, r}

# how the key k compares with t's root's (GT for a tip)
def xpl.at(+t: XPel, +k: XId) -> Cmp:
  match t:
    case XPTip{}:
      GT{}
    case XPBin{n, +x, l, r}:
      xid.cmp(k, xnack.id(x))

def xpl.dbll(+x: XNack, l: XPel, +rx: XNack, rr: XPel, rl: XPel) -> XPel:
  match rl:
    case XPTip{}:
      xpl.bin(rx, xpl.bin(x, l, XPTip{}), rr)
    case XPBin{n, +y, +yl, +yr}:
      xpl.bin(y, xpl.bin(x, l, yl), xpl.bin(rx, yr, rr))

def xpl.rotl.of(single: Bool, +x: XNack, l: XPel, +rx: XNack, rl: XPel, rr: XPel) -> XPel:
  match single:
    case True{}:
      xpl.bin(rx, xpl.bin(x, l, rl), rr)
    case False{}:
      xpl.dbll(x, l, rx, rr, rl)

def xpl.rotl(+x: XNack, l: XPel, r: XPel) -> XPel:
  match r:
    case XPTip{}:
      xpl.bin(x, l, XPTip{})
    case XPBin{n, +rx, +rl, +rr}:
      xpl.rotl.of(Nat.is_lt(xpl.size(rl), Nat.mul(2n, xpl.size(rr))), x, l, rx, rl, rr)

def xpl.dblr(+x: XNack, r: XPel, +lx: XNack, ll: XPel, lr: XPel) -> XPel:
  match lr:
    case XPTip{}:
      xpl.bin(lx, ll, xpl.bin(x, XPTip{}, r))
    case XPBin{n, +y, +yl, +yr}:
      xpl.bin(y, xpl.bin(lx, ll, yl), xpl.bin(x, yr, r))

def xpl.rotr.of(single: Bool, +x: XNack, r: XPel, +lx: XNack, ll: XPel, lr: XPel) -> XPel:
  match single:
    case True{}:
      xpl.bin(lx, ll, xpl.bin(x, lr, r))
    case False{}:
      xpl.dblr(x, r, lx, ll, lr)

def xpl.rotr(+x: XNack, l: XPel, r: XPel) -> XPel:
  match l:
    case XPTip{}:
      xpl.bin(x, XPTip{}, r)
    case XPBin{n, +lx, +ll, +lr}:
      xpl.rotr.of(Nat.is_lt(xpl.size(lr), Nat.mul(2n, xpl.size(ll))), x, r, lx, ll, lr)

def xpl.bal.of(few: Bool, rh: Bool, lh: Bool, +x: XNack, l: XPel, r: XPel) -> XPel:
  match few rh lh:
    case True{} _ _:
      xpl.bin(x, l, r)
    case False{} True{} _:
      xpl.rotl(x, l, r)
    case False{} False{} True{}:
      xpl.rotr(x, l, r)
    case False{} False{} False{}:
      xpl.bin(x, l, r)

def xpl.balance(+x: XNack, +l: XPel, +r: XPel) -> XPel:
  +sl = xpl.size(l)
  +sr = xpl.size(r)
  xpl.bal.of(Nat.is_le(Nat.add(sl, sr), 1n), Nat.is_lt(Nat.mul(3n, sl), sr), Nat.is_lt(Nat.mul(3n, sr), sl), x, l, r)

# the element of key k in t; c is how k compares with t's root's
def xpl.find(+t: XPel, c: Cmp, +k: XId) -> Maybe<&2, XNack>:
  match t c:
    case XPTip{} _:
      None{}
    case XPBin{n, x, +l, r} LT{}:
      xpl.find(l, xpl.at(l, k), k)
    case XPBin{n, x, l, +r} GT{}:
      xpl.find(r, xpl.at(r, k), k)
    case XPBin{n, +x, l, r} EQ{}:
      Some{x}

# t with x in its place (t holds no element of x's key); c is how x's key
# compares with t's root's
def xpl.ins(t: XPel, c: Cmp, +x: XNack) -> XPel:
  match t c:
    case XPTip{} _:
      XPBin{1n, x, XPTip{}, XPTip{}}
    case XPBin{n, +y, +l, +r} LT{}:
      xpl.balance(y, xpl.ins(l, xpl.at(l, xnack.id(x)), x), r)
    case XPBin{n, +y, +l, +r} _:
      xpl.balance(y, l, xpl.ins(r, xpl.at(r, xnack.id(x)), x))

def xpl.put(+x: XNack, +t: XPel) -> XPel:
  xpl.ins(t, xpl.at(t, xnack.id(x)), x)

# t with x in the place of the element of x's key, which t holds; c is
# how x's key compares with t's root's
def xpl.rep(t: XPel, c: Cmp, +x: XNack) -> XPel:
  match t c:
    case XPTip{} _:
      XPTip{}
    case XPBin{+n, +y, +l, +r} LT{}:
      XPBin{n, y, xpl.rep(l, xpl.at(l, xnack.id(x)), x), r}
    case XPBin{+n, +y, +l, +r} GT{}:
      XPBin{n, y, l, xpl.rep(r, xpl.at(r, xnack.id(x)), x)}
    case XPBin{+n, y, +l, +r} EQ{}:
      XPBin{n, x, l, r}

def xpl.set(+x: XNack, +t: XPel) -> XPel:
  xpl.rep(t, xpl.at(t, xnack.id(x)), x)

# a node's element, made before the walk goes on (as it.el)
def xpl.el(+x: XNack) -> XNack:
  x

# the elements of t in order, before acc
def xpl.list(+t: XPel, acc: List<&2, XNack>) -> List<&2, XNack>:
  match t:
    case XPTip{}:
      acc
    case XPBin{n, +x, +l, +r}:
      y = xpl.el(x)
      acc2 = xpl.list(r, acc)
      xpl.list(l, y <> acc2)

# XIds, by ID (xis)

def xis.size(+t: XIds) -> Nat:
  match t:
    case XITip{}:
      0n
    case XIBin{n, x, l, r}:
      n

def xis.bin(+x: XId, +l: XIds, +r: XIds) -> XIds:
  XIBin{Nat.add(Nat.add(xis.size(l), xis.size(r)), 1n), x, l, r}

# how the key k compares with t's root's (GT for a tip)
def xis.at(+t: XIds, +k: XId) -> Cmp:
  match t:
    case XITip{}:
      GT{}
    case XIBin{n, +x, l, r}:
      xid.cmp(k, xid.self(x))

def xis.dbll(+x: XId, l: XIds, +rx: XId, rr: XIds, rl: XIds) -> XIds:
  match rl:
    case XITip{}:
      xis.bin(rx, xis.bin(x, l, XITip{}), rr)
    case XIBin{n, +y, +yl, +yr}:
      xis.bin(y, xis.bin(x, l, yl), xis.bin(rx, yr, rr))

def xis.rotl.of(single: Bool, +x: XId, l: XIds, +rx: XId, rl: XIds, rr: XIds) -> XIds:
  match single:
    case True{}:
      xis.bin(rx, xis.bin(x, l, rl), rr)
    case False{}:
      xis.dbll(x, l, rx, rr, rl)

def xis.rotl(+x: XId, l: XIds, r: XIds) -> XIds:
  match r:
    case XITip{}:
      xis.bin(x, l, XITip{})
    case XIBin{n, +rx, +rl, +rr}:
      xis.rotl.of(Nat.is_lt(xis.size(rl), Nat.mul(2n, xis.size(rr))), x, l, rx, rl, rr)

def xis.dblr(+x: XId, r: XIds, +lx: XId, ll: XIds, lr: XIds) -> XIds:
  match lr:
    case XITip{}:
      xis.bin(lx, ll, xis.bin(x, XITip{}, r))
    case XIBin{n, +y, +yl, +yr}:
      xis.bin(y, xis.bin(lx, ll, yl), xis.bin(x, yr, r))

def xis.rotr.of(single: Bool, +x: XId, r: XIds, +lx: XId, ll: XIds, lr: XIds) -> XIds:
  match single:
    case True{}:
      xis.bin(lx, ll, xis.bin(x, lr, r))
    case False{}:
      xis.dblr(x, r, lx, ll, lr)

def xis.rotr(+x: XId, l: XIds, r: XIds) -> XIds:
  match l:
    case XITip{}:
      xis.bin(x, XITip{}, r)
    case XIBin{n, +lx, +ll, +lr}:
      xis.rotr.of(Nat.is_lt(xis.size(lr), Nat.mul(2n, xis.size(ll))), x, r, lx, ll, lr)

def xis.bal.of(few: Bool, rh: Bool, lh: Bool, +x: XId, l: XIds, r: XIds) -> XIds:
  match few rh lh:
    case True{} _ _:
      xis.bin(x, l, r)
    case False{} True{} _:
      xis.rotl(x, l, r)
    case False{} False{} True{}:
      xis.rotr(x, l, r)
    case False{} False{} False{}:
      xis.bin(x, l, r)

def xis.balance(+x: XId, +l: XIds, +r: XIds) -> XIds:
  +sl = xis.size(l)
  +sr = xis.size(r)
  xis.bal.of(Nat.is_le(Nat.add(sl, sr), 1n), Nat.is_lt(Nat.mul(3n, sl), sr), Nat.is_lt(Nat.mul(3n, sr), sl), x, l, r)

# the element of key k in t; c is how k compares with t's root's
def xis.find(+t: XIds, c: Cmp, +k: XId) -> Maybe<&2, XId>:
  match t c:
    case XITip{} _:
      None{}
    case XIBin{n, x, +l, r} LT{}:
      xis.find(l, xis.at(l, k), k)
    case XIBin{n, x, l, +r} GT{}:
      xis.find(r, xis.at(r, k), k)
    case XIBin{n, +x, l, r} EQ{}:
      Some{x}

# t with x in its place (t holds no element of x's key); c is how x's key
# compares with t's root's
def xis.ins(t: XIds, c: Cmp, +x: XId) -> XIds:
  match t c:
    case XITip{} _:
      XIBin{1n, x, XITip{}, XITip{}}
    case XIBin{n, +y, +l, +r} LT{}:
      xis.balance(y, xis.ins(l, xis.at(l, xid.self(x)), x), r)
    case XIBin{n, +y, +l, +r} _:
      xis.balance(y, l, xis.ins(r, xis.at(r, xid.self(x)), x))

def xis.put(+x: XId, +t: XIds) -> XIds:
  xis.ins(t, xis.at(t, xid.self(x)), x)

# t with x in the place of the element of x's key, which t holds; c is
# how x's key compares with t's root's
def xis.rep(t: XIds, c: Cmp, +x: XId) -> XIds:
  match t c:
    case XITip{} _:
      XITip{}
    case XIBin{+n, +y, +l, +r} LT{}:
      XIBin{n, y, xis.rep(l, xis.at(l, xid.self(x)), x), r}
    case XIBin{+n, +y, +l, +r} GT{}:
      XIBin{n, y, l, xis.rep(r, xis.at(r, xid.self(x)), x)}
    case XIBin{+n, y, +l, +r} EQ{}:
      XIBin{n, x, l, r}

def xis.set(+x: XId, +t: XIds) -> XIds:
  xis.rep(t, xis.at(t, xid.self(x)), x)

# a node's element, made before the walk goes on (as it.el)
def xis.el(+x: XId) -> XId:
  x

# the elements of t in order, before acc
def xis.list(+t: XIds, acc: List<&2, XId>) -> List<&2, XId>:
  match t:
    case XITip{}:
      acc
    case XIBin{n, +x, +l, +r}:
      y = xis.el(x)
      acc2 = xis.list(r, acc)
      xis.list(l, y <> acc2)

# XCons, by name (xcs)

def xcs.size(+t: XCons) -> Nat:
  match t:
    case XCTip{}:
      0n
    case XCBin{n, x, l, r}:
      n

def xcs.bin(+x: XCon, +l: XCons, +r: XCons) -> XCons:
  XCBin{Nat.add(Nat.add(xcs.size(l), xcs.size(r)), 1n), x, l, r}

# how the key k compares with t's root's (GT for a tip)
def xcs.at(+t: XCons, +k: String) -> Cmp:
  match t:
    case XCTip{}:
      GT{}
    case XCBin{n, +x, l, r}:
      String.order(k, xcon.name(x))

def xcs.dbll(+x: XCon, l: XCons, +rx: XCon, rr: XCons, rl: XCons) -> XCons:
  match rl:
    case XCTip{}:
      xcs.bin(rx, xcs.bin(x, l, XCTip{}), rr)
    case XCBin{n, +y, +yl, +yr}:
      xcs.bin(y, xcs.bin(x, l, yl), xcs.bin(rx, yr, rr))

def xcs.rotl.of(single: Bool, +x: XCon, l: XCons, +rx: XCon, rl: XCons, rr: XCons) -> XCons:
  match single:
    case True{}:
      xcs.bin(rx, xcs.bin(x, l, rl), rr)
    case False{}:
      xcs.dbll(x, l, rx, rr, rl)

def xcs.rotl(+x: XCon, l: XCons, r: XCons) -> XCons:
  match r:
    case XCTip{}:
      xcs.bin(x, l, XCTip{})
    case XCBin{n, +rx, +rl, +rr}:
      xcs.rotl.of(Nat.is_lt(xcs.size(rl), Nat.mul(2n, xcs.size(rr))), x, l, rx, rl, rr)

def xcs.dblr(+x: XCon, r: XCons, +lx: XCon, ll: XCons, lr: XCons) -> XCons:
  match lr:
    case XCTip{}:
      xcs.bin(lx, ll, xcs.bin(x, XCTip{}, r))
    case XCBin{n, +y, +yl, +yr}:
      xcs.bin(y, xcs.bin(lx, ll, yl), xcs.bin(x, yr, r))

def xcs.rotr.of(single: Bool, +x: XCon, r: XCons, +lx: XCon, ll: XCons, lr: XCons) -> XCons:
  match single:
    case True{}:
      xcs.bin(lx, ll, xcs.bin(x, lr, r))
    case False{}:
      xcs.dblr(x, r, lx, ll, lr)

def xcs.rotr(+x: XCon, l: XCons, r: XCons) -> XCons:
  match l:
    case XCTip{}:
      xcs.bin(x, XCTip{}, r)
    case XCBin{n, +lx, +ll, +lr}:
      xcs.rotr.of(Nat.is_lt(xcs.size(lr), Nat.mul(2n, xcs.size(ll))), x, r, lx, ll, lr)

def xcs.bal.of(few: Bool, rh: Bool, lh: Bool, +x: XCon, l: XCons, r: XCons) -> XCons:
  match few rh lh:
    case True{} _ _:
      xcs.bin(x, l, r)
    case False{} True{} _:
      xcs.rotl(x, l, r)
    case False{} False{} True{}:
      xcs.rotr(x, l, r)
    case False{} False{} False{}:
      xcs.bin(x, l, r)

def xcs.balance(+x: XCon, +l: XCons, +r: XCons) -> XCons:
  +sl = xcs.size(l)
  +sr = xcs.size(r)
  xcs.bal.of(Nat.is_le(Nat.add(sl, sr), 1n), Nat.is_lt(Nat.mul(3n, sl), sr), Nat.is_lt(Nat.mul(3n, sr), sl), x, l, r)

# the element of key k in t; c is how k compares with t's root's
def xcs.find(+t: XCons, c: Cmp, +k: String) -> Maybe<&2, XCon>:
  match t c:
    case XCTip{} _:
      None{}
    case XCBin{n, x, +l, r} LT{}:
      xcs.find(l, xcs.at(l, k), k)
    case XCBin{n, x, l, +r} GT{}:
      xcs.find(r, xcs.at(r, k), k)
    case XCBin{n, +x, l, r} EQ{}:
      Some{x}

# t with x in its place (t holds no element of x's key); c is how x's key
# compares with t's root's
def xcs.ins(t: XCons, c: Cmp, +x: XCon) -> XCons:
  match t c:
    case XCTip{} _:
      XCBin{1n, x, XCTip{}, XCTip{}}
    case XCBin{n, +y, +l, +r} LT{}:
      xcs.balance(y, xcs.ins(l, xcs.at(l, xcon.name(x)), x), r)
    case XCBin{n, +y, +l, +r} _:
      xcs.balance(y, l, xcs.ins(r, xcs.at(r, xcon.name(x)), x))

def xcs.put(+x: XCon, +t: XCons) -> XCons:
  xcs.ins(t, xcs.at(t, xcon.name(x)), x)

# t with x in the place of the element of x's key, which t holds; c is
# how x's key compares with t's root's
def xcs.rep(t: XCons, c: Cmp, +x: XCon) -> XCons:
  match t c:
    case XCTip{} _:
      XCTip{}
    case XCBin{+n, +y, +l, +r} LT{}:
      XCBin{n, y, xcs.rep(l, xcs.at(l, xcon.name(x)), x), r}
    case XCBin{+n, +y, +l, +r} GT{}:
      XCBin{n, y, l, xcs.rep(r, xcs.at(r, xcon.name(x)), x)}
    case XCBin{+n, y, +l, +r} EQ{}:
      XCBin{n, x, l, r}

def xcs.set(+x: XCon, +t: XCons) -> XCons:
  xcs.rep(t, xcs.at(t, xcon.name(x)), x)

# a node's element, made before the walk goes on (as it.el)
def xcs.el(+x: XCon) -> XCon:
  x

# the elements of t in order, before acc
def xcs.list(+t: XCons, acc: List<&2, XCon>) -> List<&2, XCon>:
  match t:
    case XCTip{}:
      acc
    case XCBin{n, +x, +l, +r}:
      y = xcs.el(x)
      acc2 = xcs.list(r, acc)
      xcs.list(l, y <> acc2)

# XGroups, by name (xgs)

def xgs.size(+t: XGroups) -> Nat:
  match t:
    case XGTip{}:
      0n
    case XGBin{n, x, l, r}:
      n

def xgs.bin(+x: XGroup, +l: XGroups, +r: XGroups) -> XGroups:
  XGBin{Nat.add(Nat.add(xgs.size(l), xgs.size(r)), 1n), x, l, r}

# how the key k compares with t's root's (GT for a tip)
def xgs.at(+t: XGroups, +k: String) -> Cmp:
  match t:
    case XGTip{}:
      GT{}
    case XGBin{n, +x, l, r}:
      String.order(k, xgroup.name(x))

def xgs.dbll(+x: XGroup, l: XGroups, +rx: XGroup, rr: XGroups, rl: XGroups) -> XGroups:
  match rl:
    case XGTip{}:
      xgs.bin(rx, xgs.bin(x, l, XGTip{}), rr)
    case XGBin{n, +y, +yl, +yr}:
      xgs.bin(y, xgs.bin(x, l, yl), xgs.bin(rx, yr, rr))

def xgs.rotl.of(single: Bool, +x: XGroup, l: XGroups, +rx: XGroup, rl: XGroups, rr: XGroups) -> XGroups:
  match single:
    case True{}:
      xgs.bin(rx, xgs.bin(x, l, rl), rr)
    case False{}:
      xgs.dbll(x, l, rx, rr, rl)

def xgs.rotl(+x: XGroup, l: XGroups, r: XGroups) -> XGroups:
  match r:
    case XGTip{}:
      xgs.bin(x, l, XGTip{})
    case XGBin{n, +rx, +rl, +rr}:
      xgs.rotl.of(Nat.is_lt(xgs.size(rl), Nat.mul(2n, xgs.size(rr))), x, l, rx, rl, rr)

def xgs.dblr(+x: XGroup, r: XGroups, +lx: XGroup, ll: XGroups, lr: XGroups) -> XGroups:
  match lr:
    case XGTip{}:
      xgs.bin(lx, ll, xgs.bin(x, XGTip{}, r))
    case XGBin{n, +y, +yl, +yr}:
      xgs.bin(y, xgs.bin(lx, ll, yl), xgs.bin(x, yr, r))

def xgs.rotr.of(single: Bool, +x: XGroup, r: XGroups, +lx: XGroup, ll: XGroups, lr: XGroups) -> XGroups:
  match single:
    case True{}:
      xgs.bin(lx, ll, xgs.bin(x, lr, r))
    case False{}:
      xgs.dblr(x, r, lx, ll, lr)

def xgs.rotr(+x: XGroup, l: XGroups, r: XGroups) -> XGroups:
  match l:
    case XGTip{}:
      xgs.bin(x, XGTip{}, r)
    case XGBin{n, +lx, +ll, +lr}:
      xgs.rotr.of(Nat.is_lt(xgs.size(lr), Nat.mul(2n, xgs.size(ll))), x, r, lx, ll, lr)

def xgs.bal.of(few: Bool, rh: Bool, lh: Bool, +x: XGroup, l: XGroups, r: XGroups) -> XGroups:
  match few rh lh:
    case True{} _ _:
      xgs.bin(x, l, r)
    case False{} True{} _:
      xgs.rotl(x, l, r)
    case False{} False{} True{}:
      xgs.rotr(x, l, r)
    case False{} False{} False{}:
      xgs.bin(x, l, r)

def xgs.balance(+x: XGroup, +l: XGroups, +r: XGroups) -> XGroups:
  +sl = xgs.size(l)
  +sr = xgs.size(r)
  xgs.bal.of(Nat.is_le(Nat.add(sl, sr), 1n), Nat.is_lt(Nat.mul(3n, sl), sr), Nat.is_lt(Nat.mul(3n, sr), sl), x, l, r)

# the element of key k in t; c is how k compares with t's root's
def xgs.find(+t: XGroups, c: Cmp, +k: String) -> Maybe<&2, XGroup>:
  match t c:
    case XGTip{} _:
      None{}
    case XGBin{n, x, +l, r} LT{}:
      xgs.find(l, xgs.at(l, k), k)
    case XGBin{n, x, l, +r} GT{}:
      xgs.find(r, xgs.at(r, k), k)
    case XGBin{n, +x, l, r} EQ{}:
      Some{x}

# t with x in its place (t holds no element of x's key); c is how x's key
# compares with t's root's
def xgs.ins(t: XGroups, c: Cmp, +x: XGroup) -> XGroups:
  match t c:
    case XGTip{} _:
      XGBin{1n, x, XGTip{}, XGTip{}}
    case XGBin{n, +y, +l, +r} LT{}:
      xgs.balance(y, xgs.ins(l, xgs.at(l, xgroup.name(x)), x), r)
    case XGBin{n, +y, +l, +r} _:
      xgs.balance(y, l, xgs.ins(r, xgs.at(r, xgroup.name(x)), x))

def xgs.put(+x: XGroup, +t: XGroups) -> XGroups:
  xgs.ins(t, xgs.at(t, xgroup.name(x)), x)

# t with x in the place of the element of x's key, which t holds; c is
# how x's key compares with t's root's
def xgs.rep(t: XGroups, c: Cmp, +x: XGroup) -> XGroups:
  match t c:
    case XGTip{} _:
      XGTip{}
    case XGBin{+n, +y, +l, +r} LT{}:
      XGBin{n, y, xgs.rep(l, xgs.at(l, xgroup.name(x)), x), r}
    case XGBin{+n, +y, +l, +r} GT{}:
      XGBin{n, y, l, xgs.rep(r, xgs.at(r, xgroup.name(x)), x)}
    case XGBin{+n, y, +l, +r} EQ{}:
      XGBin{n, x, l, r}

def xgs.set(+x: XGroup, +t: XGroups) -> XGroups:
  xgs.rep(t, xgs.at(t, xgroup.name(x)), x)

# a node's element, made before the walk goes on (as it.el)
def xgs.el(+x: XGroup) -> XGroup:
  x

# the elements of t in order, before acc
def xgs.list(+t: XGroups, acc: List<&2, XGroup>) -> List<&2, XGroup>:
  match t:
    case XGTip{}:
      acc
    case XGBin{n, +x, +l, +r}:
      y = xgs.el(x)
      acc2 = xgs.list(r, acc)
      xgs.list(l, y <> acc2)
# END gen_streams: trees
