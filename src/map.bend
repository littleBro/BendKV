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

# k members of a small set past one buffer, coded as in a small set's
# string (Sets, below)
type MPiece is Data:
  MPc{k: Nat, s: String}

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

# k elements of a list in n bytes of s, each its length's code and its
# bytes (Packed strings, below): in the list's order (fw), or the last
# first (Lists, below)
type LPiece is Data:
  LPc{k: Nat, n: Nat, fw: Bool, s: String}

# A list's elements, as a deque of two stacks of pieces: the nf elements
# of its front part in pf pieces, in order (f), then the nb of its back
# part in pb pieces, the last first (b) (Lists, below)
type DQ is Data:
  DQ{nf: Nat, pf: Nat, f: List<&2, LPiece>, nb: Nat, pb: Nat, b: List<&2, LPiece>}

# A node of a quicklist, as Redis 7.2 holds a larger list (Lists as Redis
# 7.2 holds them, below): its count of elements and its listpack's bytes
type QN is Data:
  QN{c: Nat, sz: Nat}

# How Redis 7.2 holds a list: as a listpack of lb bytes, or as a quicklist
# of nodes, nf of them (of cf elements) in order (f), then nb (of cb
# elements) the last first (b)
type QNs is Data:
  QLp{lb: Nat}
  QQl{nf: Nat, cf: Nat, f: List<&2, QN>, nb: Nat, cb: Nat, b: List<&2, QN>}

# A list as Redis 7.2 holds it: its elements (q), and its listpack or its
# quicklist's nodes (ns)
type Deq is Data:
  Deq{q: DQ, ns: QNs}

# An integer of an intset (Sets, below): its sign, and its magnitude's
# high and low 32 bits; and a key, an integer's bits in some width with
# its sign's turned over (h is 0 for a width of 2 or 4 bytes)
type IVal is Data:
  IVal{neg: Bool, hi: Nat, lo: Nat}

type IKey is Data:
  IKey{h: Nat, l: Nat}

# a view of an intset's string past one buffer, for the reads of one
# command (Sets, below): its bytes below k in a, those from k on in b
type IView is Data:
  IView{a: String, b: String, k: Nat}

# A set, as Redis 7.0 keeps one: one whose members all read as 64-bit
# integers in the form Redis writes them (ints.ok), at most
# set-max-intset-entries of them (512), as the string of its n members in
# increasing order, each in as many bytes as the widest needs (an intset:
# SMEMBERS answers them so); any other as a
# hashtable, in no order, which it stays: while it is small (n members,
# at most 128, each of at most 64 bytes) as the string of its members in
# the order they came (as Redis 7.2's listpack holds a small set), in
# pieces of one buffer each past one buffer (MLong), else as a trie of
# its members, for good (Sets, below)
type Mems is Data:
  MInts{n: Nat, b: String}
  MBig{n: Nat, t: Trie<Unit>}
  MSmall{n: Nat, b: String}
  MLong{n: Nat, ps: List<&2, MPiece>}

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

# a consumer's active time (Redis 7.2's active_time): none yet (-1, as a
# consumer is made), or the time (ms) it last read or claimed an entry
type XAct is Data:
  XActNone{}
  XActAt{ms: Nat}

# a consumer: its name, the time it was last seen (ms), its active time,
# its pending IDs
type XCon is Data:
  XCon{name: String, seen: Nat, active: XAct, ids: XIds}

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
# allocation (Hashes and Sorted sets, below); a list keeps its elements so
# in pieces of one buffer (Lists, below). A string among them is
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
# quicklist (OBJECT ENCODING answers quicklist for every list): a chain
# of listpacks of up to 8 KB, each its elements one after another.
# BendKV keeps them in pieces (LPiece) of up to 2,048 bytes, a buffer of
# the C runtime (FINDINGS.md, section 3zzzm), each its elements' codes
# one after another, and the pieces in two stacks (DQ): those of the
# front part in order, those of the back part the last first.
#
# A piece's string holds its elements in the list's order (fw) or the
# last first. A push or a pop at an end works on the start of the string
# of the piece at that end, when that start is at the end (lp.out). A
# push puts the element's code before the string, which a write then
# copies into one buffer (String.take): a write sees the list a key held
# as shared, so a ++ there links buffers into a chain, which a read by
# index walks from its start, and Redis too writes a listpack anew at
# each insert. The pushes of one command go in together, the piece
# copied once (lp.onto). A push past 2,048 bytes, or onto a piece whose
# string starts at the other end, starts a piece. A pop drops the first
# code, which moves the string's start in its buffer (String.drop); one
# that meets a piece whose string starts at the other end first codes it
# again the other way (lp.turn).
#
# When one stack holds more than three times the other's pieces and one
# more, the pieces are dealt again, half to each, as they are (dq.fix):
# a push copies one piece at most, a pop none, each O(1) amortized in the
# pieces, and LINDEX, LSET and LRANGE go from the end nearer to what they
# read, past whole pieces by their counts, then through the codes of one
# piece. A key never holds an empty list: a write that takes its last
# element deletes it.

def dq.empty() -> DQ:
  DQ{0n, 0n, Nil{}, 0n, 0n, Nil{}}

def dq.len(+d: DQ) -> Nat:
  match d:
    case DQ{+nf, pf, f, +nb, pb, b}:
      Nat.add(nf, nb)

# the bytes a piece of more than one element holds at most: a buffer of
# the C runtime
def lp.cap() -> Nat:
  2048n

# how many bytes x's code takes
def lp.size(+x: String) -> Nat:
  +m = String.length(x)
  Nat.add(pk.hdr(m), m)

# x's code before rest
def lp.code(+x: String, rest: String) -> String:
  pk.code(String.length(x), x ++ rest)

# the index past the code that starts at index i of s
def lp.past(+s: String, +i: Nat) -> Nat:
  +m = pk.len(s, i)
  Nat.add(i, Nat.add(pk.hdr(m), m))

# the index past j codes from index i of s on
def lp.skip(j: Nat, +s: String, +i: Nat) -> Nat:
  match j:
    case 0n:
      i
    case 1n+t:
      lp.skip(t, s, lp.past(s, i))

# the element whose code starts at index i of s
def lp.at(+s: String, +i: Nat) -> String:
  +m = pk.len(s, i)
  String.slice(s, Nat.add(i, pk.hdr(m)), m)

# the k elements whose codes start at index i of s, the last first,
# before acc
def lp.rev(k: Nat, +s: String, +i: Nat, acc: List<&2, String>) -> List<&2, String>:
  match k:
    case 0n:
      acc
    case 1n+j:
      +m = pk.len(s, i)
      +at = Nat.add(i, pk.hdr(m))
      lp.rev(j, s, Nat.add(at, m), String.slice(s, at, m) <> acc)

# the k codes from index i of s on, each put before acc in turn: their
# elements the other way
def lp.turn.go(k: Nat, +s: String, +i: Nat, acc: String) -> String:
  match k:
    case 0n:
      acc
    case 1n+j:
      +m = pk.len(s, i)
      +at = Nat.add(i, pk.hdr(m))
      lp.turn.go(j, s, Nat.add(at, m), pk.code(m, String.slice(s, at, m) ++ acc))

def lp.close.of(one: Bool, +k: Nat, +n: Nat, fw: Bool, s: String) -> LPiece:
  match one:
    case True{}:
      LPc{k, n, fw, pk.flat(s, n)}
    case False{}:
      LPc{k, n, fw, s}

# the piece of k elements in n bytes of s, s copied into one buffer when
# it fits in one (an element longer than that keeps its own chain)
def lp.close(+k: Nat, +n: Nat, fw: Bool, s: String) -> LPiece:
  lp.close.of(Nat.is_le(n, lp.cap()), k, n, fw, s)

# the piece with its elements the other way in its string
def lp.turn(p: LPiece) -> LPiece:
  match p:
    case LPc{+k, +n, fw, +s}:
      lp.close(k, n, Bool.not(fw), lp.turn.go(k, s, 0n, ""))

# whether the string of a piece (fw) of the stack rv starts at the end
# that stack is read from: the front stack's (rv False) from the list's
# first element on, the back stack's (rv True) from its last
def lp.out(fw: Bool, rv: Bool) -> Bool:
  Bool.xor(fw, rv)

# the index in a piece's string of its element at index j of its stack's
# order, of its k elements: from the string's start when it starts at
# that end (out), else from its end
def lp.idx(out: Bool, +k: Nat, +j: Nat) -> Nat:
  match out:
    case True{}:
      j
    case False{}:
      Nat.sub(Nat.sub(k, 1n), j)

def lp.k(+p: LPiece) -> Nat:
  match p:
    case LPc{+k, n, fw, s}:
      k

def lp.n(+p: LPiece) -> Nat:
  match p:
    case LPc{k, +n, fw, s}:
      n

# how many elements the pieces ps hold, after c
def lp.count(+ps: List<&2, LPiece>, +c: Nat) -> Nat:
  match ps:
    case Nil{}:
      c
    case Con{+p, +rest}:
      lp.count(rest, Nat.add(c, lp.k(p)))

# the first h pieces of ps reversed before acc, and the others
def lp.cut(h: Nat, ps: List<&2, LPiece>, acc: List<&2, LPiece>) -> List<&2, LPiece> & List<&2, LPiece>:
  match h ps:
    case 0n qs:
      (acc, qs)
    case 1n+j Con{p, rest}:
      lp.cut(j, rest, p <> acc)
    case 1n+j Nil{}:
      (acc, Nil{})

# whether one stack holds more than three times the other's pieces and
# one more
def dq.tilted(+pf: Nat, +pb: Nat) -> Bool:
  Bool.or(Nat.is_lt(Nat.add(Nat.mul(3n, pb), 1n), pf), Nat.is_lt(Nat.add(Nat.mul(3n, pf), 1n), pb))

def lp.outward.of(out: Bool, p: LPiece) -> LPiece:
  match out:
    case True{}:
      p
    case False{}:
      lp.turn(p)

# the piece p of the stack rv with its string starting at the end that
# stack is read from
def lp.outward(+rv: Bool, p: LPiece) -> LPiece:
  match p:
    case LPc{k, n, +fw, s}:
      lp.outward.of(lp.out(fw, rv), LPc{k, n, fw, s})

# the stack ps of the part rv with its first piece's string starting at
# the stack's end: the piece that pushes, pops and the reads near that end
# meet
def lp.head(+rv: Bool, ps: List<&2, LPiece>) -> List<&2, LPiece>:
  match ps:
    case Con{p, rest}:
      lp.outward(rv, p) <> rest
    case Nil{}:
      Nil{}

# a list of n elements in p pieces: the first h (q's first, reversed) in
# the front stack, the others in the back stack; the first piece of each
# turned to start at its end, when it came from the other stack
def dq.deal.of(+n: Nat, +p: Nat, +h: Nat, q: List<&2, LPiece> & List<&2, LPiece>) -> DQ:
  (rf, +rest) = q
  +m = lp.count(rest, 0n)
  DQ{Nat.sub(n, m), h, lp.head(False{}, List.reverse(&2, LPiece, rf)), m, Nat.sub(p, h), lp.head(True{}, List.reverse(&2, LPiece, rest))}

# the n elements of the p pieces ps, in order, dealt half to each stack,
# the pieces as they are
def dq.deal(+n: Nat, +p: Nat, ps: List<&2, LPiece>) -> DQ:
  +h = Nat.div(p, 2n)
  dq.deal.of(n, p, h, lp.cut(h, ps, Nil{}))

def dq.redeal(d: DQ) -> DQ:
  match d:
    case DQ{+nf, +pf, f, +nb, +pb, b}:
      dq.deal(Nat.add(nf, nb), Nat.add(pf, pb), List.append(&2, LPiece, f, List.reverse(&2, LPiece, b)))

def dq.fix.if(tilted: Bool, d: DQ) -> DQ:
  match tilted:
    case True{}:
      dq.redeal(d)
    case False{}:
      d

def dq.fix(d: DQ) -> DQ:
  match d:
    case DQ{nf, +pf, f, nb, +pb, b}:
      dq.fix.if(dq.tilted(pf, pb), DQ{nf, pf, f, nb, pb, b})

# a piece being packed (k elements in n bytes of s), and the c pieces
# packed before it, the last first
type LPack is Data:
  LPack{k: Nat, n: Nat, s: String, ps: List<&2, LPiece>, c: Nat}

def lp.pack.put(fits: Bool, +fw: Bool, +x: String, +k: Nat, +n: Nat, s: String, ps: List<&2, LPiece>, +c: Nat) -> LPack:
  match fits:
    case True{}:
      LPack{1n+k, Nat.add(n, lp.size(x)), lp.code(x, s), ps, c}
    case False{}:
      LPack{1n, lp.size(x), lp.code(x, ""), lp.close(k, n, fw, s) <> ps, 1n+c}

# x's code put before the piece st packs, or in a new piece when it does
# not fit
def lp.pack.step(+fw: Bool, +x: String, st: LPack) -> LPack:
  match st:
    case LPack{+k, +n, s, ps, c}:
      lp.pack.put(Bool.or(Nat.is_eq(k, 0n), Nat.is_le(Nat.add(n, lp.size(x)), lp.cap())), fw, x, k, n, s, ps, c)

def lp.pack.last(k: Nat, +n: Nat, +fw: Bool, s: String, ps: List<&2, LPiece>, +c: Nat) -> Nat & List<&2, LPiece>:
  match k:
    case 0n:
      (c, ps)
    case 1n+j:
      (1n+c, lp.close(1n+j, n, fw, s) <> ps)

def lp.pack.end(+fw: Bool, st: LPack) -> Nat & List<&2, LPiece>:
  match st:
    case LPack{k, n, s, ps, c}:
      lp.pack.last(k, n, fw, s, ps, c)

# the elements xs packed into pieces (fw) after the piece st packs: each
# code put before those packed before it, so that a piece's string holds
# them the other way, and each piece closed in one buffer; how many
# pieces, and they, the last packed first
def lp.pack(xs: List<&2, String>, +fw: Bool, st: LPack) -> Nat & List<&2, LPiece>:
  match xs:
    case Nil{}:
      lp.pack.end(fw, st)
    case Con{x, rest}:
      lp.pack(rest, fw, lp.pack.step(fw, x, st))

# a stack's start, for pushes onto it: its first piece taken in (a 1)
# when its string starts at the stack's end, else a piece begun; and the
# rest of the stack
type LOnto is Data:
  LOnto{a: Nat, st: LPack, rest: List<&2, LPiece>}

def lp.start.of(out: Bool, +k: Nat, +n: Nat, fw: Bool, s: String, rest: List<&2, LPiece>) -> LOnto:
  match out:
    case True{}:
      LOnto{1n, LPack{k, n, s, Nil{}, 0n}, rest}
    case False{}:
      LOnto{0n, LPack{0n, 0n, "", Nil{}, 0n}, LPc{k, n, fw, s} <> rest}

def lp.start(+rv: Bool, ps: List<&2, LPiece>) -> LOnto:
  match ps:
    case Con{LPc{k, n, +fw, s}, rest}:
      lp.start.of(lp.out(fw, rv), k, n, fw, s, rest)
    case Nil{}:
      LOnto{0n, LPack{0n, 0n, "", Nil{}, 0n}, Nil{}}

# a stack after pushes: the pieces it took in (a) and made (c), and its
# pieces
type LGrow is Data:
  LGrow{a: Nat, c: Nat, ps: List<&2, LPiece>}

def lp.grow.of(+a: Nat, q: Nat & List<&2, LPiece>, rest: List<&2, LPiece>) -> LGrow:
  (c, ps) = q
  LGrow{a, c, List.append(&2, LPiece, ps, rest)}

# the elements xs pushed in turn onto the stack rv, each before those
# before it: packed onto the stack's start (lp.start), so that a write
# copies the piece it writes into one buffer once, as Redis writes a
# listpack anew, whatever the pushes
def lp.onto(+rv: Bool, xs: List<&2, String>, o: LOnto) -> LGrow:
  match o:
    case LOnto{+a, st, rest}:
      lp.grow.of(a, lp.pack(xs, Bool.not(rv), st), rest)

# how many elements xs holds, after c, read in place
def lp.len(+xs: List<&2, String>, +c: Nat) -> Nat:
  match xs:
    case Nil{}:
      c
    case Con{+x, +rest}:
      lp.len(rest, 1n+c)

def dq.grow.f(+nf: Nat, +pf: Nat, g: LGrow, nb: Nat, pb: Nat, b: List<&2, LPiece>) -> DQ:
  match g:
    case LGrow{+a, +c, ps}:
      DQ{nf, Nat.sub(Nat.add(pf, c), a), ps, nb, pb, b}

def dq.grow.b(nf: Nat, pf: Nat, f: List<&2, LPiece>, +nb: Nat, +pb: Nat, g: LGrow) -> DQ:
  match g:
    case LGrow{+a, +c, ps}:
      DQ{nf, pf, f, nb, Nat.sub(Nat.add(pb, c), a), ps}

# the elements xs pushed in turn, each first (left) or last, together
def dq.pushes.n(+left: Bool, +xs: List<&2, String>, d: DQ) -> DQ:
  match left d:
    case True{} DQ{+nf, pf, f, nb, pb, b}:
      dq.fix(dq.grow.f(Nat.add(nf, lp.len(xs, 0n)), pf, lp.onto(False{}, xs, lp.start(False{}, f)), nb, pb, b))
    case False{} DQ{nf, pf, f, +nb, pb, b}:
      dq.fix(dq.grow.b(nf, pf, f, Nat.add(nb, lp.len(xs, 0n)), pb, lp.onto(True{}, xs, lp.start(True{}, b))))

# x put first: its code before the front stack's first piece's string
# (of k elements in n bytes of s, m with x), the piece copied into one
# buffer, when that string starts at the list's first element and x fits;
# else in a piece of its own
def dq.pushl.of(room: Bool, +x: String, +m: Nat, +nf: Nat, +pf: Nat, +k: Nat, +n: Nat, fw: Bool, s: String, f: List<&2, LPiece>, nb: Nat, pb: Nat, b: List<&2, LPiece>) -> DQ:
  match room:
    case True{}:
      DQ{1n+nf, pf, LPc{1n+k, m, fw, pk.flat(lp.code(x, s), m)} <> f, nb, pb, b}
    case False{}:
      dq.fix(DQ{1n+nf, 1n+pf, lp.close(1n, lp.size(x), True{}, lp.code(x, "")) <> (LPc{k, n, fw, s} <> f), nb, pb, b})

def dq.pushl(+x: String, +nf: Nat, +pf: Nat, f: List<&2, LPiece>, nb: Nat, pb: Nat, b: List<&2, LPiece>) -> DQ:
  match f:
    case Con{LPc{+k, +n, +fw, s}, rest}:
      +m = Nat.add(n, lp.size(x))
      dq.pushl.of(Bool.and(fw, Nat.is_le(m, lp.cap())), x, m, nf, pf, k, n, fw, s, rest, nb, pb, b)
    case Nil{}:
      dq.fix(DQ{1n+nf, 1n+pf, [lp.close(1n, lp.size(x), True{}, lp.code(x, ""))], nb, pb, b})

# x put last, as dq.pushl puts it first
def dq.pushr.of(room: Bool, +x: String, +m: Nat, nf: Nat, pf: Nat, f: List<&2, LPiece>, +nb: Nat, +pb: Nat, +k: Nat, +n: Nat, fw: Bool, s: String, b: List<&2, LPiece>) -> DQ:
  match room:
    case True{}:
      DQ{nf, pf, f, 1n+nb, pb, LPc{1n+k, m, fw, pk.flat(lp.code(x, s), m)} <> b}
    case False{}:
      dq.fix(DQ{nf, pf, f, 1n+nb, 1n+pb, lp.close(1n, lp.size(x), False{}, lp.code(x, "")) <> (LPc{k, n, fw, s} <> b)})

def dq.pushr(+x: String, nf: Nat, pf: Nat, f: List<&2, LPiece>, +nb: Nat, +pb: Nat, b: List<&2, LPiece>) -> DQ:
  match b:
    case Con{LPc{+k, +n, +fw, s}, rest}:
      +m = Nat.add(n, lp.size(x))
      dq.pushr.of(Bool.and(Bool.not(fw), Nat.is_le(m, lp.cap())), x, m, nf, pf, f, nb, pb, k, n, fw, s, rest)
    case Nil{}:
      dq.fix(DQ{nf, pf, f, 1n+nb, 1n+pb, [lp.close(1n, lp.size(x), False{}, lp.code(x, ""))]})

# x put first (left) or last
def dq.push(+left: Bool, x: String, d: DQ) -> DQ:
  match left d:
    case True{} DQ{nf, pf, f, nb, pb, b}:
      dq.pushl(x, nf, pf, f, nb, pb, b)
    case False{} DQ{nf, pf, f, nb, pb, b}:
      dq.pushr(x, nf, pf, f, nb, pb, b)

# the elements xs pushed in turn, each first (left) or last: one alone as
# dq.push puts it, more together (dq.pushes.n)
def dq.pushes(+left: Bool, xs: List<&2, String>, d: DQ) -> DQ:
  match xs:
    case Con{x, Nil{}}:
      dq.push(left, x, d)
    case ys:
      dq.pushes.n(left, ys, d)

# a list's first (or last) element and the others; none for an empty one
type DPop is Data:
  DPop{x: String, d: DQ}
  DPopNone{}

# the element x taken from the front stack's first piece, whose string s
# (of 1+j elements, n bytes) loses its first code, of b0 bytes; the piece
# goes with its last element
def dq.popl.k(j: Nat, x: String, +b0: Nat, +n: Nat, fw: Bool, s: String, +nf: Nat, +pf: Nat, f: List<&2, LPiece>, nb: Nat, pb: Nat, b: List<&2, LPiece>) -> DPop:
  match j:
    case 0n:
      DPop{x, dq.fix(DQ{Nat.sub(nf, 1n), Nat.sub(pf, 1n), f, nb, pb, b})}
    case 1n+i:
      DPop{x, DQ{Nat.sub(nf, 1n), pf, LPc{1n+i, Nat.sub(n, b0), fw, String.drop(s, b0)} <> f, nb, pb, b}}

# the first element, from the front stack's first piece, whose string
# starts at it
def dq.popl.out(k: Nat, +n: Nat, fw: Bool, +s: String, nf: Nat, pf: Nat, f: List<&2, LPiece>, nb: Nat, pb: Nat, b: List<&2, LPiece>) -> DPop:
  +m = pk.len(s, 0n)
  +h = pk.hdr(m)
  dq.popl.k(Nat.sub(k, 1n), String.slice(s, h, m), Nat.add(h, m), n, fw, s, nf, pf, f, nb, pb, b)

def dq.popl.turned(p: LPiece, nf: Nat, pf: Nat, f: List<&2, LPiece>, nb: Nat, pb: Nat, b: List<&2, LPiece>) -> DPop:
  match p:
    case LPc{k, n, fw, s}:
      dq.popl.out(k, n, fw, s, nf, pf, f, nb, pb, b)

def dq.popl.p(out: Bool, k: Nat, n: Nat, fw: Bool, s: String, nf: Nat, pf: Nat, f: List<&2, LPiece>, nb: Nat, pb: Nat, b: List<&2, LPiece>) -> DPop:
  match out:
    case True{}:
      dq.popl.out(k, n, fw, s, nf, pf, f, nb, pb, b)
    case False{}:
      dq.popl.turned(lp.turn(LPc{k, n, fw, s}), nf, pf, f, nb, pb, b)

def dq.popl.go(f: List<&2, LPiece>, nf: Nat, pf: Nat, nb: Nat, pb: Nat, b: List<&2, LPiece>) -> DPop:
  match f:
    case Con{LPc{k, n, +fw, s}, rest}:
      dq.popl.p(fw, k, n, fw, s, nf, pf, rest, nb, pb, b)
    case Nil{}:
      DPopNone{}

# the first element and the rest: from the front stack, else from the
# back stack's pieces, moved to the front (one at most, while the stacks
# are dealt as dq.fix keeps them)
def dq.popl.f(f: List<&2, LPiece>, nf: Nat, pf: Nat, nb: Nat, pb: Nat, b: List<&2, LPiece>) -> DPop:
  match f:
    case Con{LPc{k, n, +fw, s}, rest}:
      dq.popl.p(fw, k, n, fw, s, nf, pf, rest, nb, pb, b)
    case Nil{}:
      dq.popl.go(List.reverse(&2, LPiece, b), nb, pb, 0n, 0n, Nil{})

def dq.popl(d: DQ) -> DPop:
  match d:
    case DQ{nf, pf, f, nb, pb, b}:
      dq.popl.f(f, nf, pf, nb, pb, b)

# the element x taken from the back stack's first piece (as dq.popl.k)
def dq.popr.k(j: Nat, x: String, +b0: Nat, +n: Nat, fw: Bool, s: String, nf: Nat, pf: Nat, f: List<&2, LPiece>, +nb: Nat, +pb: Nat, b: List<&2, LPiece>) -> DPop:
  match j:
    case 0n:
      DPop{x, dq.fix(DQ{nf, pf, f, Nat.sub(nb, 1n), Nat.sub(pb, 1n), b})}
    case 1n+i:
      DPop{x, DQ{nf, pf, f, Nat.sub(nb, 1n), pb, LPc{1n+i, Nat.sub(n, b0), fw, String.drop(s, b0)} <> b}}

def dq.popr.out(k: Nat, +n: Nat, fw: Bool, +s: String, nf: Nat, pf: Nat, f: List<&2, LPiece>, nb: Nat, pb: Nat, b: List<&2, LPiece>) -> DPop:
  +m = pk.len(s, 0n)
  +h = pk.hdr(m)
  dq.popr.k(Nat.sub(k, 1n), String.slice(s, h, m), Nat.add(h, m), n, fw, s, nf, pf, f, nb, pb, b)

def dq.popr.turned(p: LPiece, nf: Nat, pf: Nat, f: List<&2, LPiece>, nb: Nat, pb: Nat, b: List<&2, LPiece>) -> DPop:
  match p:
    case LPc{k, n, fw, s}:
      dq.popr.out(k, n, fw, s, nf, pf, f, nb, pb, b)

def dq.popr.p(out: Bool, k: Nat, n: Nat, fw: Bool, s: String, nf: Nat, pf: Nat, f: List<&2, LPiece>, nb: Nat, pb: Nat, b: List<&2, LPiece>) -> DPop:
  match out:
    case True{}:
      dq.popr.out(k, n, fw, s, nf, pf, f, nb, pb, b)
    case False{}:
      dq.popr.turned(lp.turn(LPc{k, n, fw, s}), nf, pf, f, nb, pb, b)

def dq.popr.go(b: List<&2, LPiece>, nf: Nat, pf: Nat, f: List<&2, LPiece>, nb: Nat, pb: Nat) -> DPop:
  match b:
    case Con{LPc{k, n, +fw, s}, rest}:
      dq.popr.p(Bool.not(fw), k, n, fw, s, nf, pf, f, nb, pb, rest)
    case Nil{}:
      DPopNone{}

def dq.popr.b(b: List<&2, LPiece>, nf: Nat, pf: Nat, f: List<&2, LPiece>, nb: Nat, pb: Nat) -> DPop:
  match b:
    case Con{LPc{k, n, +fw, s}, rest}:
      dq.popr.p(Bool.not(fw), k, n, fw, s, nf, pf, f, nb, pb, rest)
    case Nil{}:
      dq.popr.go(List.reverse(&2, LPiece, f), 0n, 0n, Nil{}, nf, pf)

# the last element and the rest
def dq.popr(d: DQ) -> DPop:
  match d:
    case DQ{nf, pf, f, nb, pb, b}:
      dq.popr.b(b, nf, pf, f, nb, pb)

def dq.pop(+left: Bool, d: DQ) -> DPop:
  match left:
    case True{}:
      dq.popl(d)
    case False{}:
      dq.popr(d)

def lp.elems.of(fw: Bool, +k: Nat, +s: String, acc: List<&2, String>) -> List<&2, String>:
  match fw:
    case True{}:
      List.reverse.go(&2, String, lp.rev(k, s, 0n, Nil{}), acc)
    case False{}:
      lp.rev(k, s, 0n, acc)

# the elements of piece p in the list's order, before acc
def lp.elems(+p: LPiece, acc: List<&2, String>) -> List<&2, String>:
  match p:
    case LPc{+k, n, +fw, +s}:
      lp.elems.of(fw, k, s, acc)

# the elements of the front stack's pieces ps, before acc
def lp.all.f(+ps: List<&2, LPiece>, acc: List<&2, String>) -> List<&2, String>:
  match ps:
    case Nil{}:
      acc
    case Con{+p, +rest}:
      lp.elems(p, lp.all.f(rest, acc))

# the elements of the back stack's pieces ps (the last piece first), in
# the list's order, before acc
def lp.all.b(+ps: List<&2, LPiece>, acc: List<&2, String>) -> List<&2, String>:
  match ps:
    case Nil{}:
      acc
    case Con{+p, +rest}:
      lp.all.b(rest, lp.elems(p, acc))

# the elements, in order
def dq.all(+d: DQ) -> List<&2, String>:
  match d:
    case DQ{nf, pf, +f, nb, pb, +b}:
      lp.all.f(f, lp.all.b(b, Nil{}))

# the first n elements of xs reversed before acc, and the others
def deq.cut(n: Nat, xs: List<&2, String>, acc: List<&2, String>) -> List<&2, String> & List<&2, String>:
  match n xs:
    case 0n ys:
      (acc, ys)
    case 1n+m Con{x, rest}:
      deq.cut(m, rest, x <> acc)
    case 1n+m Nil{}:
      (acc, Nil{})

# where an index of a stack's order falls among its pieces: t pieces
# wholly before it, at o in the next (done: found)
type LAt is Data:
  LAt{t: Nat, o: Nat, done: Bool}

def lp.find.at(inside: Bool, +k: Nat, +t: Nat, +o: Nat) -> LAt:
  match inside:
    case True{}:
      LAt{t, o, True{}}
    case False{}:
      LAt{1n+t, Nat.sub(o, k), False{}}

# where the index of at falls among the pieces ps, past those at passed
def lp.find(+ps: List<&2, LPiece>, at: LAt) -> LAt:
  match ps at:
    case _ LAt{t, o, True{}}:
      LAt{t, o, True{}}
    case Nil{} LAt{t, o, False{}}:
      LAt{t, o, False{}}
    case Con{+p, +rest} LAt{+t, +o, False{}}:
      +k = lp.k(p)
      lp.find(rest, lp.find.at(Nat.is_lt(o, k), k, t, o))

# the element at index o of the stack rv's order in piece p, below its k
def lp.get.in(+p: LPiece, +rv: Bool, +o: Nat) -> String:
  match p:
    case LPc{+k, n, +fw, +s}:
      lp.at(s, lp.skip(lp.idx(lp.out(fw, rv), k, o), s, 0n))

def lp.get.if(has: Bool, +p: LPiece, +rv: Bool, +o: Nat) -> Maybe<&2, String>:
  match has:
    case True{}:
      Some{lp.get.in(p, rv, o)}
    case False{}:
      None{}

# the element at index o of the stack rv's order in the pieces ps, unless
# m holds it already: read in place
def lp.get(+ps: List<&2, LPiece>, +rv: Bool, +o: Nat, m: Maybe<&2, String>) -> Maybe<&2, String>:
  match ps m:
    case _ Some{x}:
      Some{x}
    case Nil{} None{}:
      None{}
    case Con{+p, +rest} None{}:
      +k = lp.k(p)
      lp.get(rest, rv, Nat.sub(o, k), lp.get.if(Nat.is_lt(o, k), p, rv, o))

def dq.get.of(front: Bool, +i: Nat, +nf: Nat, +f: List<&2, LPiece>, +nb: Nat, +b: List<&2, LPiece>) -> Maybe<&2, String>:
  match front:
    case True{}:
      lp.get(f, False{}, i, None{})
    case False{}:
      lp.get(b, True{}, Nat.sub(Nat.sub(nb, 1n), Nat.sub(i, nf)), None{})

# the element at position i, below the list's length
def dq.get(+i: Nat, +d: DQ) -> Maybe<&2, String>:
  match d:
    case DQ{+nf, pf, +f, +nb, pb, +b}:
      dq.get.of(Nat.is_lt(i, nf), i, nf, f, nb, b)

# c elements of a piece's string t of k elements, from index s of its
# stack's order on, reversed before acc: from the string's start when it
# starts at that end (out), else from its end
def lp.slice.of(out: Bool, +k: Nat, +t: String, +s: Nat, +c: Nat, acc: List<&2, String>) -> List<&2, String>:
  match out:
    case True{}:
      lp.rev(c, t, lp.skip(s, t, 0n), acc)
    case False{}:
      List.reverse.go(&2, String, lp.rev(c, t, lp.skip(Nat.sub(k, Nat.add(s, c)), t, 0n), Nil{}), acc)

def lp.slice.p(+p: LPiece, +rv: Bool, +s: Nat, +c: Nat, acc: List<&2, String>) -> List<&2, String>:
  match p:
    case LPc{+k, n, +fw, +t}:
      lp.slice.of(lp.out(fw, rv), k, t, s, Nat.min(c, Nat.sub(k, s)), acc)

def lp.slice.in(has: Bool, +p: LPiece, +rv: Bool, +s: Nat, +c: Nat, acc: List<&2, String>) -> List<&2, String>:
  match has:
    case True{}:
      lp.slice.p(p, rv, s, c, acc)
    case False{}:
      acc

# c elements of the pieces ps from index s of the stack rv's order on,
# read in place, reversed before acc
def lp.slice(+ps: List<&2, LPiece>, +rv: Bool, +s: Nat, c: Nat, acc: List<&2, String>) -> List<&2, String>:
  match ps c:
    case _ 0n:
      acc
    case Nil{} 1n+j:
      acc
    case Con{+p, +rest} 1n+j:
      +k = lp.k(p)
      +c1 = Nat.add(1n, j)
      lp.slice(rest, rv, Nat.sub(s, k), Nat.sub(c1, Nat.min(c1, Nat.sub(k, s))), lp.slice.in(Nat.is_lt(s, k), p, rv, s, c1, acc))

def dq.range.f(ok: Bool, +s: Nat, +e: Nat, +f: List<&2, LPiece>, acc: List<&2, String>) -> List<&2, String>:
  match ok:
    case True{}:
      List.reverse.go(&2, String, lp.slice(f, False{}, s, 1n+Nat.sub(e, s), Nil{}), acc)
    case False{}:
      acc

def dq.range.b(ok: Bool, +lo: Nat, +e: Nat, +n: Nat, +b: List<&2, LPiece>) -> List<&2, String>:
  match ok:
    case True{}:
      lp.slice(b, True{}, Nat.sub(Nat.sub(n, 1n), e), 1n+Nat.sub(e, lo), Nil{})
    case False{}:
      Nil{}

# the elements at positions s to e, in order, s <= e below the length
def dq.range(+s: Nat, +e: Nat, +d: DQ) -> List<&2, String>:
  match d:
    case DQ{+nf, pf, +f, +nb, pb, +b}:
      dq.range.f(Nat.is_lt(s, nf), s, Nat.min(e, Nat.sub(nf, 1n)), f, dq.range.b(Nat.is_le(nf, e), Nat.max(s, nf), e, Nat.add(nf, nb), b))

# the k elements of a piece's string t, from the end farther from where
# its stack is read on: t's last first when t starts at that end (out)
def lp.inner(out: Bool, +k: Nat, +t: String) -> List<&2, String>:
  match out:
    case True{}:
      lp.rev(k, t, 0n, Nil{})
    case False{}:
      List.reverse(&2, String, lp.rev(k, t, 0n, Nil{}))

# a piece of k elements in m bytes of t, after an LSET: dealt into
# pieces of a buffer each when it grew past one (and holds more than one
# element); how many pieces, and they in the stack rv's order
def lp.put.of(long: Bool, +rv: Bool, +k: Nat, +m: Nat, +fw: Bool, t: String) -> Nat & List<&2, LPiece>:
  match long:
    case False{}:
      (1n, [lp.close(k, m, fw, t)])
    case True{}:
      lp.pack(lp.inner(lp.out(fw, rv), k, t), Bool.not(rv), LPack{0n, 0n, "", Nil{}, 0n})

# piece p of the stack rv with its element at index o of that stack's
# order set to v: the bytes before the old code, v's code and the bytes
# after it
def lp.put(+rv: Bool, +o: Nat, +v: String, p: LPiece) -> Nat & List<&2, LPiece>:
  match p:
    case LPc{+k, +n, +fw, +s}:
      +i = lp.skip(lp.idx(lp.out(fw, rv), k, o), s, 0n)
      +j = lp.past(s, i)
      +m = Nat.add(Nat.sub(n, Nat.sub(j, i)), lp.size(v))
      lp.put.of(Bool.and(Nat.is_lt(lp.cap(), m), Nat.is_lt(1n, k)), rv, k, m, fw, String.slice(s, 0n, i) ++ lp.code(v, String.drop(s, j)))

def lp.set.put(+pc: Nat, pre: List<&2, LPiece>, q: Nat & List<&2, LPiece>, rest: List<&2, LPiece>) -> Nat & List<&2, LPiece>:
  (c, qs) = q
  (Nat.sub(Nat.add(pc, c), 1n), List.reverse.go(&2, LPiece, pre, List.append(&2, LPiece, qs, rest)))

def lp.set.in(+rv: Bool, +o: Nat, v: String, +pc: Nat, pre: List<&2, LPiece>, post: List<&2, LPiece>) -> Nat & List<&2, LPiece>:
  match post:
    case Con{p, rest}:
      lp.set.put(pc, pre, lp.put(rv, o, v, p), rest)
    case Nil{}:
      (pc, List.reverse(&2, LPiece, pre))

def lp.set.of(+rv: Bool, +o: Nat, v: String, +pc: Nat, q: List<&2, LPiece> & List<&2, LPiece>) -> Nat & List<&2, LPiece>:
  (pre, post) = q
  lp.set.in(rv, o, v, pc, pre, post)

def lp.set.at(+rv: Bool, v: String, +pc: Nat, at: LAt, ps: List<&2, LPiece>) -> Nat & List<&2, LPiece>:
  match at:
    case LAt{t, +o, done}:
      lp.set.of(rv, o, v, pc, lp.cut(t, ps, Nil{}))

# the stack ps of pc pieces (rv) with its element at index j of its order
# set to v: how many pieces, and the stack
def lp.set(+rv: Bool, +j: Nat, v: String, +pc: Nat, +ps: List<&2, LPiece>) -> Nat & List<&2, LPiece>:
  lp.set.at(rv, v, pc, lp.find(ps, LAt{0n, j, False{}}), ps)

# the list with its front stack (of pf pieces) given by q
def dq.with.f(+nf: Nat, q: Nat & List<&2, LPiece>, nb: Nat, pb: Nat, b: List<&2, LPiece>) -> DQ:
  (pf, f) = q
  DQ{nf, pf, f, nb, pb, b}

# the list with its back stack (of pb pieces) given by q
def dq.with.b(nf: Nat, pf: Nat, f: List<&2, LPiece>, +nb: Nat, q: Nat & List<&2, LPiece>) -> DQ:
  (pb, b) = q
  DQ{nf, pf, f, nb, pb, b}

def dq.set.of(front: Bool, +i: Nat, v: String, +nf: Nat, +pf: Nat, f: List<&2, LPiece>, +nb: Nat, +pb: Nat, b: List<&2, LPiece>) -> DQ:
  match front:
    case True{}:
      dq.fix(dq.with.f(nf, lp.set(False{}, i, v, pf, f), nb, pb, b))
    case False{}:
      dq.fix(dq.with.b(nf, pf, f, nb, lp.set(True{}, Nat.sub(Nat.sub(nb, 1n), Nat.sub(i, nf)), v, pb, b)))

# the list with the element at position i, below its length, set to v
def dq.set(+i: Nat, v: String, d: DQ) -> DQ:
  match d:
    case DQ{+nf, +pf, f, +nb, +pb, b}:
      dq.set.of(Nat.is_lt(i, nf), i, v, nf, pf, f, nb, pb, b)

# piece p of its stack without its first o elements of the stack's order
# (0 < o < its k): its string's first codes dropped when it starts at
# that end (out), the buffer kept, else its first codes copied
def lp.cut.out.of(out: Bool, +o: Nat, +k: Nat, +n: Nat, fw: Bool, +s: String) -> LPiece:
  match out:
    case True{}:
      +i = lp.skip(o, s, 0n)
      LPc{Nat.sub(k, o), Nat.sub(n, i), fw, String.drop(s, i)}
    case False{}:
      +i = lp.skip(Nat.sub(k, o), s, 0n)
      LPc{Nat.sub(k, o), i, fw, String.take(s, i)}

def lp.cut.out(+rv: Bool, +o: Nat, p: LPiece) -> LPiece:
  match p:
    case LPc{+k, +n, +fw, +s}:
      lp.cut.out.of(lp.out(fw, rv), o, k, n, fw, s)

# piece p of its stack with only its first o elements of the stack's
# order (0 < o < its k)
def lp.keep.out.of(out: Bool, +o: Nat, +k: Nat, +n: Nat, fw: Bool, +s: String) -> LPiece:
  match out:
    case True{}:
      +i = lp.skip(o, s, 0n)
      LPc{o, i, fw, String.take(s, i)}
    case False{}:
      +i = lp.skip(Nat.sub(k, o), s, 0n)
      LPc{o, Nat.sub(n, i), fw, String.drop(s, i)}

def lp.keep.out(+rv: Bool, +o: Nat, p: LPiece) -> LPiece:
  match p:
    case LPc{+k, +n, +fw, +s}:
      lp.keep.out.of(lp.out(fw, rv), o, k, n, fw, s)

def lp.cut.zero(zero: Bool, +rv: Bool, +o: Nat, p: LPiece) -> LPiece:
  match zero:
    case True{}:
      p
    case False{}:
      lp.cut.out(rv, o, p)

def lp.drop.head(+rv: Bool, +o: Nat, +pc: Nat, ps: List<&2, LPiece>) -> Nat & List<&2, LPiece>:
  match ps:
    case Con{p, rest}:
      (pc, lp.cut.zero(Nat.is_eq(o, 0n), rv, o, p) <> rest)
    case Nil{}:
      (pc, Nil{})

def lp.drop.at(+rv: Bool, +pc: Nat, at: LAt, ps: List<&2, LPiece>) -> Nat & List<&2, LPiece>:
  match at:
    case LAt{+t, +o, done}:
      lp.drop.head(rv, o, Nat.sub(pc, t), List.drop(&2, LPiece, ps, t))

# the stack ps of pc pieces (rv) without its first j elements of its
# order: how many pieces, and the stack
def lp.drop(+rv: Bool, +j: Nat, +pc: Nat, +ps: List<&2, LPiece>) -> Nat & List<&2, LPiece>:
  lp.drop.at(rv, pc, lp.find(ps, LAt{0n, j, False{}}), ps)

def lp.keep.last(zero: Bool, +rv: Bool, +t: Nat, +o: Nat, pre: List<&2, LPiece>, p: LPiece) -> Nat & List<&2, LPiece>:
  match zero:
    case True{}:
      (t, List.reverse(&2, LPiece, pre))
    case False{}:
      (1n+t, List.reverse.go(&2, LPiece, pre, [lp.keep.out(rv, o, p)]))

def lp.keep.tail(+rv: Bool, +t: Nat, +o: Nat, pre: List<&2, LPiece>, post: List<&2, LPiece>) -> Nat & List<&2, LPiece>:
  match post:
    case Con{p, rest}:
      lp.keep.last(Nat.is_eq(o, 0n), rv, t, o, pre, p)
    case Nil{}:
      (t, List.reverse(&2, LPiece, pre))

def lp.keep.of(+rv: Bool, +t: Nat, +o: Nat, q: List<&2, LPiece> & List<&2, LPiece>) -> Nat & List<&2, LPiece>:
  (pre, post) = q
  lp.keep.tail(rv, t, o, pre, post)

def lp.keep.at(+rv: Bool, at: LAt, ps: List<&2, LPiece>) -> Nat & List<&2, LPiece>:
  match at:
    case LAt{+t, +o, done}:
      lp.keep.of(rv, t, o, lp.cut(t, ps, Nil{}))

# the stack ps (rv) with only its first m elements of its order: how many
# pieces, and the stack
def lp.keep(+rv: Bool, +m: Nat, +ps: List<&2, LPiece>) -> Nat & List<&2, LPiece>:
  lp.keep.at(rv, lp.find(ps, LAt{0n, m, False{}}), ps)

def dq.dropl.of(front: Bool, +k: Nat, +nf: Nat, +pf: Nat, f: List<&2, LPiece>, +nb: Nat, +pb: Nat, b: List<&2, LPiece>) -> DQ:
  match front:
    case True{}:
      dq.fix(dq.with.f(Nat.sub(nf, k), lp.drop(False{}, k, pf, f), nb, pb, b))
    case False{}:
      +m = Nat.sub(nb, Nat.sub(k, nf))
      dq.fix(dq.with.b(0n, 0n, Nil{}, m, lp.keep(True{}, m, b)))

# the list without its first k elements, k at most its length
def dq.dropl(+k: Nat, d: DQ) -> DQ:
  match d:
    case DQ{+nf, +pf, f, +nb, +pb, b}:
      dq.dropl.of(Nat.is_le(k, nf), k, nf, pf, f, nb, pb, b)

def dq.dropr.of(back: Bool, +k: Nat, +nf: Nat, +pf: Nat, f: List<&2, LPiece>, +nb: Nat, +pb: Nat, b: List<&2, LPiece>) -> DQ:
  match back:
    case True{}:
      dq.fix(dq.with.b(nf, pf, f, Nat.sub(nb, k), lp.drop(True{}, k, pb, b)))
    case False{}:
      +m = Nat.sub(nf, Nat.sub(k, nb))
      dq.fix(dq.with.f(m, lp.keep(False{}, m, f), 0n, 0n, Nil{}))

# the list without its last k elements, k at most its length
def dq.dropr(+k: Nat, d: DQ) -> DQ:
  match d:
    case DQ{+nf, +pf, f, +nb, +pb, b}:
      dq.dropr.of(Nat.is_le(k, nb), k, nf, pf, f, nb, pb, b)

# Searches and writes along the list
# ----------------------------------
# LPOS, LINSERT and LREM compare elements with a string where they lie, a
# piece at a time, as a small hash compares a field (pk.hit): the
# lengths first, then the last bytes, then the bytes. A walk goes in the
# list's order or from its last element: the front stack's pieces in
# their order, then the back stack's against theirs (or the other way).
# A piece whose string goes the other way is read through the indices of
# its codes, the last first (lp.offs). LPOS and LINSERT's pivot stop at
# the matches they want; LINSERT then writes one piece, as LSET does, and
# LREM writes anew only the pieces it takes elements from.

# the indices of the k codes of s from index i on, the last first, before
# acc
def lp.offs(k: Nat, +s: String, +i: Nat, acc: List<&2, Nat>) -> List<&2, Nat>:
  match k:
    case 0n:
      acc
    case 1n+j:
      lp.offs(j, s, lp.past(s, i), i <> acc)

# x's last byte, which a comparison reads before the others (none for an
# empty x, which pk.hit does not read)
def lp.last(+x: String, +lx: Nat) -> U32:
  String.code_at(x, Nat.sub(lx, 1n))

# A search of x (LPOS, LINSERT's pivot): the element read next is the
# c-th of the walk; up to w more matches are wanted and up to l more
# elements read; the positions found, the last first
type LSeek is Data:
  LSeek{c: Nat, w: Nat, l: Nat, ps: List<&2, Nat>}

# whether the search goes on
def lp.seek.on(+st: LSeek) -> Bool:
  match st:
    case LSeek{c, +w, +l, ps}:
      Bool.and(Nat.is_lt(0n, w), Nat.is_lt(0n, l))

# the search past one element, a match (hit) or not: its position in the
# list of n is c, or n - 1 - c from the last (back)
def lp.seek.at(hit: Bool, +back: Bool, +n: Nat, st: LSeek) -> LSeek:
  match hit st:
    case True{} LSeek{+c, +w, +l, ps}:
      LSeek{1n+c, Nat.sub(w, 1n), Nat.sub(l, 1n), Bool.pick(Nat, back, Nat.sub(Nat.sub(n, 1n), c), c) <> ps}
    case False{} LSeek{+c, w, +l, ps}:
      LSeek{1n+c, w, Nat.sub(l, 1n), ps}

# the search through the k codes of s from index i on, in the string's
# order
def lp.seek.fw(k: Nat, on: Bool, +s: String, +i: Nat, +x: String, +lx: Nat, +lb: U32, +back: Bool, +n: Nat, st: LSeek) -> LSeek:
  match k on:
    case 1n+j True{}:
      +m = pk.len(s, i)
      +t = lp.seek.at(pk.hit(1n, x, lx, lb, s, i, m), back, n, st)
      lp.seek.fw(j, lp.seek.on(t), s, Nat.add(i, Nat.add(pk.hdr(m), m)), x, lx, lb, back, n, t)
    case _ _:
      st

# the search through the codes of s at the indices os
def lp.seek.bw(+os: List<&2, Nat>, on: Bool, +s: String, +x: String, +lx: Nat, +lb: U32, +back: Bool, +n: Nat, st: LSeek) -> LSeek:
  match os on:
    case Con{+i, +rest} True{}:
      +t = lp.seek.at(pk.hit(1n, x, lx, lb, s, i, pk.len(s, i)), back, n, st)
      lp.seek.bw(rest, lp.seek.on(t), s, x, lx, lb, back, n, t)
    case _ _:
      st

def lp.seek.of(same: Bool, +k: Nat, +s: String, +x: String, +lx: Nat, +lb: U32, +back: Bool, +n: Nat, st: LSeek) -> LSeek:
  match same:
    case True{}:
      lp.seek.fw(k, True{}, s, 0n, x, lx, lb, back, n, st)
    case False{}:
      lp.seek.bw(lp.offs(k, s, 0n, Nil{}), True{}, s, x, lx, lb, back, n, st)

# the search through piece p, in the walk's order: its string's order
# when the string goes in the list's order (fw) and the walk too, or both
# from the last
def lp.seek.p(+p: LPiece, +x: String, +lx: Nat, +lb: U32, +back: Bool, +n: Nat, st: LSeek) -> LSeek:
  match p:
    case LPc{+k, n0, +fw, +s}:
      lp.seek.of(Bool.xor(fw, back), k, s, x, lx, lb, back, n, st)

def lp.seek.one(on: Bool, +p: LPiece, +x: String, +lx: Nat, +lb: U32, +back: Bool, +n: Nat, st: LSeek) -> LSeek:
  match on:
    case True{}:
      lp.seek.p(p, x, lx, lb, back, n, st)
    case False{}:
      st

# the search through the pieces ps, in their order
def lp.seek.ps(+ps: List<&2, LPiece>, on: Bool, +x: String, +lx: Nat, +lb: U32, +back: Bool, +n: Nat, st: LSeek) -> LSeek:
  match ps on:
    case Con{+p, +rest} True{}:
      +t = lp.seek.p(p, x, lx, lb, back, n, st)
      lp.seek.ps(rest, lp.seek.on(t), x, lx, lb, back, n, t)
    case _ _:
      st

# the search through the pieces ps, against their order: the last first
def lp.seek.rb(+ps: List<&2, LPiece>, +x: String, +lx: Nat, +lb: U32, +back: Bool, +n: Nat, st: LSeek) -> LSeek:
  match ps:
    case Nil{}:
      st
    case Con{+p, +rest}:
      +t = lp.seek.rb(rest, x, lx, lb, back, n, st)
      lp.seek.one(lp.seek.on(t), p, x, lx, lb, back, n, t)

def dq.find.of(back: Bool, +x: String, +lx: Nat, +lb: U32, +n: Nat, +f: List<&2, LPiece>, +b: List<&2, LPiece>, st: LSeek) -> LSeek:
  match back:
    case False{}:
      +t = lp.seek.ps(f, True{}, x, lx, lb, False{}, n, st)
      lp.seek.rb(b, x, lx, lb, False{}, n, t)
    case True{}:
      +t = lp.seek.ps(b, True{}, x, lx, lb, True{}, n, st)
      lp.seek.rb(f, x, lx, lb, True{}, n, t)

def lp.seek.ps.of(+st: LSeek) -> List<&2, Nat>:
  match st:
    case LSeek{c, w, l, +ps}:
      ps

# the positions of up to w elements that are x, among the first l read
# (w and l at least 1), in the list's order or from its last element
# (back): the positions found, the last first
def dq.find(+x: String, +back: Bool, +w: Nat, +l: Nat, +d: DQ) -> List<&2, Nat>:
  match d:
    case DQ{+nf, pf, +f, +nb, pb, +b}:
      +lx = String.length(x)
      lp.seek.ps.of(dq.find.of(back, x, lx, lp.last(x, lx), Nat.add(nf, nb), f, b, LSeek{0n, w, l, Nil{}}))

# piece p of the stack rv with v put next to its element at index o of
# that stack's order: after it in that order (a), else before it. In the
# string, v's code goes after the element's code when the string goes in
# the stack's order (out) and v after the element, or neither.
def lp.ins.p(+rv: Bool, +a: Bool, +o: Nat, +v: String, p: LPiece) -> Nat & List<&2, LPiece>:
  match p:
    case LPc{+k, +n, +fw, +s}:
      +out = lp.out(fw, rv)
      +i = lp.skip(lp.idx(out, k, o), s, 0n)
      +q = Bool.pick(Nat, Bool.not(Bool.xor(a, out)), lp.past(s, i), i)
      +m = Nat.add(n, lp.size(v))
      lp.put.of(Nat.is_lt(lp.cap(), m), rv, 1n+k, m, fw, String.slice(s, 0n, q) ++ lp.code(v, String.drop(s, q)))

def lp.ins.in(+rv: Bool, +a: Bool, +o: Nat, v: String, +pc: Nat, pre: List<&2, LPiece>, post: List<&2, LPiece>) -> Nat & List<&2, LPiece>:
  match post:
    case Con{p, rest}:
      lp.set.put(pc, pre, lp.ins.p(rv, a, o, v, p), rest)
    case Nil{}:
      (pc, List.reverse(&2, LPiece, pre))

def lp.ins.of(+rv: Bool, +a: Bool, +o: Nat, v: String, +pc: Nat, q: List<&2, LPiece> & List<&2, LPiece>) -> Nat & List<&2, LPiece>:
  (pre, post) = q
  lp.ins.in(rv, a, o, v, pc, pre, post)

def lp.ins.at(+rv: Bool, +a: Bool, v: String, +pc: Nat, at: LAt, ps: List<&2, LPiece>) -> Nat & List<&2, LPiece>:
  match at:
    case LAt{t, +o, done}:
      lp.ins.of(rv, a, o, v, pc, lp.cut(t, ps, Nil{}))

# the stack ps of pc pieces (rv) with v put after its element at index j
# of its order (a), else before it: how many pieces, and the stack
def lp.ins(+rv: Bool, +j: Nat, +a: Bool, v: String, +pc: Nat, +ps: List<&2, LPiece>) -> Nat & List<&2, LPiece>:
  lp.ins.at(rv, a, v, pc, lp.find(ps, LAt{0n, j, False{}}), ps)

def dq.ins.of(front: Bool, +i: Nat, +after: Bool, v: String, +nf: Nat, +pf: Nat, f: List<&2, LPiece>, +nb: Nat, +pb: Nat, b: List<&2, LPiece>) -> DQ:
  match front:
    case True{}:
      dq.fix(dq.with.f(1n+nf, lp.ins(False{}, i, after, v, pf, f), nb, pb, b))
    case False{}:
      dq.fix(dq.with.b(nf, pf, f, 1n+nb, lp.ins(True{}, Nat.sub(Nat.sub(nb, 1n), Nat.sub(i, nf)), Bool.not(after), v, pb, b)))

# the list with v put after the element at position i, below its length
# (after), else before it: in the front stack's order, or against the
# back stack's
def dq.ins.at(+i: Nat, +after: Bool, v: String, d: DQ) -> DQ:
  match d:
    case DQ{+nf, +pf, f, +nb, +pb, b}:
      dq.ins.of(Nat.is_lt(i, nf), i, after, v, nf, pf, f, nb, pb, b)

def dq.ins.if(+ps: List<&2, Nat>, +after: Bool, v: String, d: DQ) -> Maybe<&2, DQ>:
  match ps:
    case Con{+i, rest}:
      Some{dq.ins.at(i, after, v, d)}
    case Nil{}:
      None{}

# LINSERT: the list with v put after the first element that is p
# (after), else before it; none when no element is
def dq.ins(+p: String, +after: Bool, v: String, d: DQ) -> Maybe<&2, DQ>:
  +e = d
  dq.ins.if(dq.find(p, False{}, 1n, 1n+dq.len(e), e), after, v, e)

# how many of the k elements whose codes start at index i of s are x,
# after h
def lp.hits(k: Nat, +s: String, +i: Nat, +x: String, +lx: Nat, +lb: U32, +h: Nat) -> Nat:
  match k:
    case 0n:
      h
    case 1n+j:
      +m = pk.len(s, i)
      lp.hits(j, s, Nat.add(i, Nat.add(pk.hdr(m), m)), x, lx, lb, Bool.pick(Nat, pk.hit(1n, x, lx, lb, s, i, m), 1n+h, h))

# the bytes from index a to index b of a piece's string that a removal
# keeps
type LKept is Data:
  LKept{a: Nat, b: Nat}

# the run of bytes from a to i put before acc, when it holds any
def lp.run.put(some: Bool, +a: Nat, +i: Nat, acc: List<&2, LKept>) -> List<&2, LKept>:
  match some:
    case True{}:
      LKept{a, i} <> acc
    case False{}:
      acc

# the run from a to i closed when the code at i is dropped
def lp.run.cut(drop: Bool, +a: Nat, +i: Nat, acc: List<&2, LKept>) -> List<&2, LKept>:
  match drop:
    case True{}:
      lp.run.put(Nat.is_lt(a, i), a, i, acc)
    case False{}:
      acc

# the bytes of the k codes of s from index i on that a removal keeps: the
# matches of x numbered lo to hi - 1 (h of them met before i) dropped; the
# runs kept, the last first, before acc, the one from a not closed yet
def lp.runs(k: Nat, +s: String, +i: Nat, +a: Nat, +h: Nat, +lo: Nat, +hi: Nat, +x: String, +lx: Nat, +lb: U32, acc: List<&2, LKept>) -> List<&2, LKept>:
  match k:
    case 0n:
      lp.run.put(Nat.is_lt(a, i), a, i, acc)
    case 1n+j:
      +m = pk.len(s, i)
      +e = Nat.add(i, Nat.add(pk.hdr(m), m))
      +hit = pk.hit(1n, x, lx, lb, s, i, m)
      +drop = Bool.and(hit, Bool.and(Nat.is_le(lo, h), Nat.is_lt(h, hi)))
      lp.runs(j, s, e, Bool.pick(Nat, drop, e, a), Bool.pick(Nat, hit, 1n+h, h), lo, hi, x, lx, lb, lp.run.cut(drop, a, i, acc))

# the bytes of the runs rs of s (the last first) in order, before t
def lp.runs.str(rs: List<&2, LKept>, +s: String, t: String) -> String:
  match rs:
    case Nil{}:
      t
    case Con{LKept{+a, +b}, rest}:
      lp.runs.str(rest, s, String.slice(s, a, Nat.sub(b, a)) ++ t)

# how many bytes the runs rs hold, after c
def lp.runs.len(+rs: List<&2, LKept>, +c: Nat) -> Nat:
  match rs:
    case Nil{}:
      c
    case Con{LKept{+a, +b}, +rest}:
      lp.runs.len(rest, Nat.add(c, Nat.sub(b, a)))

# A removal of x (LREM) through a stack: w more matches to take, gone
# taken so far, and the stack's pieces kept or written anew, k elements in
# c pieces (in the order the walk put them)
type LRm is Data:
  LRm{w: Nat, gone: Nat, k: Nat, c: Nat, ps: List<&2, LPiece>}

# a piece kept as it is
def lp.rm.keep(+p: LPiece, st: LRm) -> LRm:
  match st:
    case LRm{w, gone, +k, +c, ps}:
      LRm{w, gone, Nat.add(k, lp.k(p)), 1n+c, p <> ps}

# a piece kept unless it holds none (none)
def lp.rm.put(none: Bool, p: LPiece, st: LRm) -> LRm:
  match none:
    case True{}:
      st
    case False{}:
      lp.rm.keep(p, st)

# the piece of k elements, of which r are taken, written anew from the
# runs rs of s: none when it keeps none
def lp.rm.new(+k: Nat, +r: Nat, fw: Bool, +s: String, +rs: List<&2, LKept>, st: LRm) -> LRm:
  match st:
    case LRm{+w, +gone, +kk, +c, ps}:
      +left = Nat.sub(k, r)
      +n = lp.runs.len(rs, 0n)
      lp.rm.put(Nat.is_eq(left, 0n), LPc{left, n, fw, pk.flat(lp.runs.str(rs, s, ""), n)}, LRm{Nat.sub(w, r), Nat.add(gone, r), kk, c, ps})

# piece LPc{k, n, fw, s} with r of its h matches taken, those the walk
# meets first: the first r of its string when the string goes the walk's
# way (same), else the last r
def lp.rm.take(+r: Nat, +h: Nat, same: Bool, +x: String, +lx: Nat, +lb: U32, +k: Nat, +n: Nat, fw: Bool, +s: String, st: LRm) -> LRm:
  +lo = Bool.pick(Nat, same, 0n, Nat.sub(h, r))
  lp.rm.new(k, r, fw, s, lp.runs(k, s, 0n, 0n, 0n, lo, Nat.add(lo, r), x, lx, lb, Nil{}), st)

def lp.rm.of(none: Bool, +h: Nat, same: Bool, +x: String, +lx: Nat, +lb: U32, +k: Nat, +n: Nat, fw: Bool, +s: String, st: LRm) -> LRm:
  match none st:
    case True{} st0:
      lp.rm.keep(LPc{k, n, fw, s}, st0)
    case False{} LRm{+w, gone, kk, c, ps}:
      lp.rm.take(Nat.min(h, w), h, same, x, lx, lb, k, n, fw, s, LRm{w, gone, kk, c, ps})

# how many of the k elements of s are x, when matches are still to take
# (w), else none: a match, not Bool.pick, which would read them all
def lp.rm.hits(w: Nat, +k: Nat, +s: String, +x: String, +lx: Nat, +lb: U32) -> Nat:
  match w:
    case 0n:
      0n
    case _:
      lp.hits(k, s, 0n, x, lx, lb, 0n)

# piece p met by the walk (from the last element, back): read when
# matches are still to take, and written anew when it holds any
def lp.rm.p(+back: Bool, +x: String, +lx: Nat, +lb: U32, p: LPiece, st: LRm) -> LRm:
  match p st:
    case LPc{+k, +n, +fw, +s} LRm{+w, gone, kk, c, ps}:
      +h = lp.rm.hits(w, k, s, x, lx, lb)
      lp.rm.of(Nat.is_eq(h, 0n), h, Bool.xor(fw, back), x, lx, lb, k, n, fw, s, LRm{w, gone, kk, c, ps})

# the removal through the pieces ps, in their order (the pieces kept put
# the last first)
def lp.rm.ps(ps: List<&2, LPiece>, +back: Bool, +x: String, +lx: Nat, +lb: U32, st: LRm) -> LRm:
  match ps:
    case Nil{}:
      st
    case Con{p, rest}:
      lp.rm.ps(rest, back, x, lx, lb, lp.rm.p(back, x, lx, lb, p, st))

# the removal through the pieces ps, against their order (the pieces kept
# put in their order)
def lp.rm.rb(ps: List<&2, LPiece>, +back: Bool, +x: String, +lx: Nat, +lb: U32, st: LRm) -> LRm:
  match ps:
    case Nil{}:
      st
    case Con{p, rest}:
      lp.rm.p(back, x, lx, lb, p, lp.rm.rb(rest, back, x, lx, lb, st))

# a list after LREM, and how many elements it took
type DRem is Data:
  DRem{d: DQ, gone: Nat}

# the list from the stacks the removal kept: the first stack's (k1
# elements in c1 pieces ps1), then the second's (s2)
def dq.rm.fin(back: Bool, +k1: Nat, +c1: Nat, ps1: List<&2, LPiece>, s2: LRm) -> DRem:
  match back s2:
    case False{} LRm{w, +gone, +k2, +c2, ps2}:
      DRem{dq.fix(DQ{k1, c1, ps1, k2, c2, ps2}), gone}
    case True{} LRm{w, +gone, +k2, +c2, ps2}:
      DRem{dq.fix(DQ{k2, c2, ps2, k1, c1, ps1}), gone}

# the second stack's removal, after the first's (s1, whose pieces came
# the last first)
def dq.rm.two(back: Bool, s1: LRm, +x: String, +lx: Nat, +lb: U32, two: List<&2, LPiece>) -> DRem:
  match back s1:
    case False{} LRm{w, gone, +k1, +c1, ps1}:
      dq.rm.fin(False{}, k1, c1, List.reverse(&2, LPiece, ps1), lp.rm.rb(two, False{}, x, lx, lb, LRm{w, gone, 0n, 0n, Nil{}}))
    case True{} LRm{w, gone, +k1, +c1, ps1}:
      dq.rm.fin(True{}, k1, c1, List.reverse(&2, LPiece, ps1), lp.rm.rb(two, True{}, x, lx, lb, LRm{w, gone, 0n, 0n, Nil{}}))

def dq.rm.of(back: Bool, +x: String, +lx: Nat, +lb: U32, +w: Nat, f: List<&2, LPiece>, b: List<&2, LPiece>) -> DRem:
  match back:
    case False{}:
      dq.rm.two(False{}, lp.rm.ps(f, False{}, x, lx, lb, LRm{w, 0n, 0n, 0n, Nil{}}), x, lx, lb, b)
    case True{}:
      dq.rm.two(True{}, lp.rm.ps(b, True{}, x, lx, lb, LRm{w, 0n, 0n, 0n, Nil{}}), x, lx, lb, f)

# LREM: the list without its first w elements that are x (all of them
# for w 0), in its order or from its last element (back), and how many
# it took
def dq.rem(+x: String, +w: Nat, +back: Bool, d: DQ) -> DRem:
  match d:
    case DQ{+nf, pf, f, +nb, pb, b}:
      +lx = String.length(x)
      dq.rm.of(back, x, lx, lp.last(x, lx), Bool.pick(Nat, Nat.is_eq(w, 0n), Nat.add(nf, nb), w), f, b)

# the list of n elements xs, in order: packed the last first, the pieces
# then dealt to both stacks
def dq.of.at(+n: Nat, q: Nat & List<&2, LPiece>) -> DQ:
  (c, b) = q
  dq.fix(DQ{0n, 0n, Nil{}, n, c, b})

def dq.of(+n: Nat, xs: List<&2, String>) -> DQ:
  dq.of.at(n, lp.pack(xs, False{}, LPack{0n, 0n, "", Nil{}, 0n}))

# MEMORY USAGE's estimate of a list's bytes past its key's entry: its
# pieces' bytes, and 72 for each piece's nodes
def lp.bytes(+ps: List<&2, LPiece>, +acc: Nat) -> Nat:
  match ps:
    case Nil{}:
      acc
    case Con{+p, +rest}:
      lp.bytes(rest, Nat.add(acc, Nat.add(72n, lp.n(p))))

def dq.bytes(+d: DQ) -> Nat:
  match d:
    case DQ{nf, pf, +f, nb, pb, +b}:
      lp.bytes(f, lp.bytes(b, 48n))

# Sets
# ----
# A set's members (Mems, above): a small set of integers is the string
# of its members in increasing order, as Redis's intset, a small set of
# other members the string of its members in the order they came, any
# other a trie of its members, each with no time. Redis 7.0 keeps a set as an intset while
# its members all read as 64-bit integers and they are at most
# set-max-intset-entries (512), as a hashtable from the first write that
# passes either, for good. BendKV turns an intset into a hashtable at
# that default, whatever the parameter says, as it does a hash (Hashes,
# above); OBJECT ENCODING reads the parameter as it is (session.bend). A
# hashtable is a string of its members while it holds at most 128 of at
# most 64 bytes (Redis 7.2's set-max-listpack-entries and -value: Redis
# 7.0 has no listpack of a set, so OBJECT ENCODING answers hashtable for
# both, and DUMP writes both as a hashtable), and a trie from the first
# write that passes either, for good. A key never holds an empty set: a
# write that takes its last member deletes it.

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

# An intset's string (MInts, above) holds its n members as Redis's intset
# holds them (intset.c, without its header of 8 bytes): each an integer
# of w bytes, two's complement, the low byte first, in increasing order;
# w (2, 4 or 8) is the width the widest member needed, so the string's
# length over n. A member wider than the others makes them all as wide
# (Redis's intsetUpgradeAndAdd: it is then the least or the greatest),
# and a member taken out leaves the width as it was, as Redis leaves it.
# A member is found by halves (is.find, as intsetSearch finds one), each
# step a compare of two keys: an integer's bits with its sign's turned
# over, so that keys compare as the integers do, 64 bits in two halves of
# 32 (a Nat stops at 2^48). An add or a deletion makes the string anew in
# one buffer. 512 members of 8 bytes take 4,096 bytes, two buffers: a
# read past the first walks to the second (Hashes, above).

# 2^32 (a literal stops at 2^32 - 1)
def ints.two32() -> Nat:
  Nat.mul(65536n, 65536n)

def iv.small(+neg: Bool, +m: Nat) -> IVal:
  IVal{neg, Nat.div(m, ints.two32()), Nat.mod(m, ints.two32())}

# the magnitude x * 10^9 + y (x below 10^10, y below 10^9) in its halves:
# x in three limbs of 16 bits, each times 10^9 below 2^46, and the carries
# up through the low half's two limbs
def iv.join(+neg: Bool, +x: Nat, +y: Nat) -> IVal:
  +p0 = Nat.add(Nat.mul(Nat.mod(x, 65536n), 1000000000n), y)
  +p1 = Nat.add(Nat.mul(Nat.mod(Nat.div(x, 65536n), 65536n), 1000000000n), Nat.div(p0, 65536n))
  +hi = Nat.add(Nat.mul(Nat.div(x, ints.two32()), 1000000000n), Nat.div(p1, 65536n))
  IVal{neg, hi, Nat.add(Nat.mul(Nat.mod(p1, 65536n), 65536n), Nat.mod(p0, 65536n))}

def iv.of.pick(small: Bool, +neg: Bool, +s: String, +a: Nat, +d: Nat) -> IVal:
  match small:
    case True{}:
      iv.small(neg, String.dec_at(s, a, d))
    case False{}:
      +k = Nat.sub(d, 9n)
      iv.join(neg, String.dec_at(s, a, k), String.dec_at(s, Nat.add(a, k), 9n))

# the integer whose text is s (one of ints.ok): its 14 digits at most
# read at once, more as two parts, the last nine digits and those before
# (19 digits pass 2^48, where a Nat stops)
def iv.of(+s: String) -> IVal:
  +neg = U32.is_eq(String.code_at(s, 0n), 45)
  +a = Bool.pick(Nat, neg, 1n, 0n)
  +d = Nat.sub(String.length(s), a)
  iv.of.pick(Nat.is_le(d, 14n), neg, s, a, d)

# the width v needs: 2 bytes from -2^15 to 2^15 - 1, 4 from -2^31 to
# 2^31 - 1, else 8
def iv.w(+v: IVal) -> Nat:
  match v:
    case IVal{+neg, +hi, +lo}:
      +b = Bool.pick(Nat, neg, 1n, 0n)
      Bool.pick(Nat, Nat.is_eq(hi, 0n), Bool.pick(Nat, Nat.is_lt(lo, Nat.add(32768n, b)), 2n, Bool.pick(Nat, Nat.is_lt(lo, Nat.add(2147483648n, b)), 4n, 8n)), 8n)

def iv.neg(+v: IVal) -> Bool:
  match v:
    case IVal{+neg, hi, lo}:
      neg

# 2^(8w - 1), for a width w of 2 or 4
def iv.half(w: Nat) -> Nat:
  match w:
    case 2n:
      32768n
    case _:
      2147483648n

def iv.key.of(wide: Bool, +w: Nat, +neg: Bool, +hi: Nat, +lo: Nat) -> IKey:
  match wide:
    case False{}:
      +half = iv.half(w)
      IKey{0n, Bool.pick(Nat, neg, Nat.sub(half, lo), Nat.add(half, lo))}
    case True{}:
      +nz = Bool.pick(Nat, Nat.is_eq(lo, 0n), 0n, 1n)
      Bool.pick(IKey, neg, IKey{Nat.sub(Nat.sub(2147483648n, hi), nz), Nat.mod(Nat.sub(ints.two32(), lo), ints.two32())}, IKey{Nat.add(2147483648n, hi), lo})

# v's key in the width w, one v fits in
def iv.key(+w: Nat, +v: IVal) -> IKey:
  match v:
    case IVal{+neg, +hi, +lo}:
      iv.key.of(Nat.is_eq(w, 8n), w, neg, hi, lo)

# the 2 and 4 bytes of b from index at on, the low first
def is.u16(+b: String, +at: Nat) -> Nat:
  Nat.add(pk.byte(b, at), Nat.mul(256n, pk.byte(b, Nat.add(at, 1n))))

def is.u32(+b: String, +at: Nat) -> Nat:
  Nat.add(is.u16(b, at), Nat.mul(65536n, is.u16(b, Nat.add(at, 2n))))

def is.key.w(w: Nat, +b: String, +at: Nat) -> IKey:
  match w:
    case 2n:
      IKey{0n, Nat.mod(Nat.add(is.u16(b, at), 32768n), 65536n)}
    case 4n:
      IKey{0n, Nat.mod(Nat.add(is.u32(b, at), 2147483648n), ints.two32())}
    case _:
      IKey{Nat.mod(Nat.add(is.u32(b, Nat.add(at, 4n)), 2147483648n), ints.two32()), is.u32(b, at)}

# the key of the member at index i of an intset's string b, of width w
def is.key(+b: String, +w: Nat, +i: Nat) -> IKey:
  is.key.w(w, b, Nat.mul(i, w))

def ik.lt(+a: IKey, +b: IKey) -> Bool:
  match a b:
    case IKey{+ah, +al} IKey{+bh, +bl}:
      Bool.or(Nat.is_lt(ah, bh), Bool.and(Nat.is_eq(ah, bh), Nat.is_lt(al, bl)))

def ik.eq(+a: IKey, +b: IKey) -> Bool:
  match a b:
    case IKey{+ah, +al} IKey{+bh, +bl}:
      Bool.and(Nat.is_eq(ah, bh), Nat.is_eq(al, bl))

# the first index from lo on, below hi, of a member whose key is not
# below k, or hi: by halves, f steps at most; mid is the middle, less
# whether its member's key is below k, done whether no index is left
def is.lb(f: Nat, done: Bool, less: Bool, +b: String, +w: Nat, +k: IKey, +lo: Nat, +hi: Nat, +mid: Nat) -> Nat:
  match f done less:
    case 0n _ _:
      lo
    case 1n+g True{} _:
      lo
    case 1n+g False{} True{}:
      +l = Nat.add(mid, 1n)
      +m = Nat.div(Nat.add(l, hi), 2n)
      is.lb(g, Nat.is_le(hi, l), ik.lt(is.key(b, w, m), k), b, w, k, l, hi, m)
    case 1n+g False{} False{}:
      +m = Nat.div(Nat.add(lo, mid), 2n)
      is.lb(g, Nat.is_le(mid, lo), ik.lt(is.key(b, w, m), k), b, w, k, lo, mid, m)

# the index of the first member of the intset b (n members of w bytes)
# whose key is not below k (n when none), b of one buffer
def is.find.one(+b: String, +w: Nat, +n: Nat, +k: IKey) -> Nat:
  +mid = Nat.div(n, 2n)
  is.lb(Nat.add(n, 1n), Nat.is_eq(n, 0n), ik.lt(is.key(b, w, mid), k), b, w, k, 0n, n, mid)

# An intset's string past one buffer (2,048 bytes: 257 members of 8
# bytes or more) is two buffers: the C runtime fills the last one and
# leaves the rest to the first, and a read of a byte of a String of two
# buffers walks them from the first (str_code_at_far), where a read of a
# String of one buffer reads where the byte lies. A command that reads
# several members of such a string reads them through a view of its two
# buffers (the drop of the first takes the last as it is, the take of
# the first copies it); a string of one buffer is read as it is.
def iw.view(+b: String) -> IView:
  +k = Nat.sub(String.length(b), 2048n)
  IView{String.take(b, k), String.drop(b, k), k}

# is.key.w for the view's reads alone: a call of is.key.w from here
# would change how the compiler passes its arguments where the reads of
# one buffer call it (FINDINGS.md, section 7)
def iw.key.w(w: Nat, +b: String, +at: Nat) -> IKey:
  match w:
    case 2n:
      IKey{0n, Nat.mod(Nat.add(is.u16(b, at), 32768n), 65536n)}
    case 4n:
      IKey{0n, Nat.mod(Nat.add(is.u32(b, at), 2147483648n), ints.two32())}
    case _:
      IKey{Nat.mod(Nat.add(is.u32(b, Nat.add(at, 4n)), 2147483648n), ints.two32()), is.u32(b, at)}

def iw.key.at(lo: Bool, +a: String, +b: String, +k: Nat, +w: Nat, +at: Nat) -> IKey:
  match lo:
    case True{}:
      iw.key.w(w, a, at)
    case False{}:
      iw.key.w(w, b, Nat.sub(at, k))

# the key of the member at index i (w bytes) of the view v
def iw.key(+v: IView, +w: Nat, +i: Nat) -> IKey:
  match v:
    case IView{+a, +b, +k}:
      +at = Nat.mul(i, w)
      iw.key.at(Nat.is_lt(at, k), a, b, k, w, at)

# is.lb through a view
def iw.lb(f: Nat, done: Bool, less: Bool, +v: IView, +w: Nat, +k: IKey, +lo: Nat, +hi: Nat, +mid: Nat) -> Nat:
  match f done less:
    case 0n _ _:
      lo
    case 1n+g True{} _:
      lo
    case 1n+g False{} True{}:
      +l = Nat.add(mid, 1n)
      +m = Nat.div(Nat.add(l, hi), 2n)
      iw.lb(g, Nat.is_le(hi, l), ik.lt(iw.key(v, w, m), k), v, w, k, l, hi, m)
    case 1n+g False{} False{}:
      +m = Nat.div(Nat.add(lo, mid), 2n)
      iw.lb(g, Nat.is_le(mid, lo), ik.lt(iw.key(v, w, m), k), v, w, k, lo, mid, m)

# is.find.one through a view
def iw.find(+v: IView, +w: Nat, +n: Nat, +k: IKey) -> Nat:
  +mid = Nat.div(n, 2n)
  iw.lb(Nat.add(n, 1n), Nat.is_eq(n, 0n), ik.lt(iw.key(v, w, mid), k), v, w, k, 0n, n, mid)

def is.find.of(far: Bool, +b: String, +w: Nat, +n: Nat, +k: IKey) -> Nat:
  match far:
    case True{}:
      iw.find(iw.view(b), w, n, k)
    case False{}:
      is.find.one(b, w, n, k)

# the index of the first member of the intset b (n members of w bytes)
# whose key is not below k (n when none)
def is.find(+b: String, +w: Nat, +n: Nat, +k: IKey) -> Nat:
  is.find.of(Nat.is_lt(2048n, Nat.mul(n, w)), b, w, n, k)

# the k low bytes of u, the low first, before rest
def is.bytes(k: Nat, +u: Nat, rest: String) -> String:
  match k:
    case 0n:
      rest
    case 1n+j:
      pk.byte.put(Nat.mod(u, 256n), is.bytes(j, Nat.div(u, 256n), rest))

def is.enc.w(w: Nat, +neg: Bool, +hi: Nat, +lo: Nat, rest: String) -> String:
  match w:
    case 2n:
      is.bytes(2n, Bool.pick(Nat, neg, Nat.sub(65536n, lo), lo), rest)
    case 4n:
      is.bytes(4n, Bool.pick(Nat, neg, Nat.sub(ints.two32(), lo), lo), rest)
    case _:
      +nz = Bool.pick(Nat, Nat.is_eq(lo, 0n), 0n, 1n)
      +ulo = Bool.pick(Nat, neg, Nat.mod(Nat.sub(ints.two32(), lo), ints.two32()), lo)
      +uhi = Bool.pick(Nat, neg, Nat.mod(Nat.sub(Nat.sub(ints.two32(), hi), nz), ints.two32()), hi)
      is.bytes(4n, ulo, is.bytes(4n, uhi, rest))

# v's w bytes before rest
def is.enc(+w: Nat, +v: IVal, rest: String) -> String:
  match v:
    case IVal{+neg, +hi, +lo}:
      is.enc.w(w, neg, hi, lo, rest)

# the text of a magnitude of halves hi and lo: one Nat below 2^48, else
# divided by 10^9 a limb of 16 bits at a time (each step below 2^46), the
# quotient (at least 281,474) and the nine digits of the remainder
def is.dec(small: Bool, +hi: Nat, +lo: Nat) -> String:
  match small:
    case True{}:
      Nat.show(Nat.add(Nat.mul(hi, ints.two32()), lo))
    case False{}:
      +c2 = hi
      +r2 = Nat.mod(c2, 1000000000n)
      +c1 = Nat.add(Nat.mul(r2, 65536n), Nat.div(lo, 65536n))
      +r1 = Nat.mod(c1, 1000000000n)
      +c0 = Nat.add(Nat.mul(r1, 65536n), Nat.mod(lo, 65536n))
      +q = Nat.add(Nat.mul(Nat.add(Nat.mul(Nat.div(c2, 1000000000n), 65536n), Nat.div(c1, 1000000000n)), 65536n), Nat.div(c0, 1000000000n))
      +r = Nat.show(Nat.mod(c0, 1000000000n))
      Nat.show(q) ++ String.repeat("0", Nat.sub(9n, String.length(r))) ++ r

def is.sign(neg: Bool, s: String) -> String:
  match neg:
    case True{}:
      "-" ++ s
    case False{}:
      s

# the text of the two's complement u of 2 or 4 bytes (half 2^(8w - 1),
# full 2^(8w))
def is.text.small(+u: Nat, +half: Nat, +full: Nat) -> String:
  +neg = Nat.is_le(half, u)
  is.sign(neg, Nat.show(Bool.pick(Nat, neg, Nat.sub(full, u), u)))

# the text of the 64-bit two's complement of halves uhi and ulo
def is.text.wide(+uhi: Nat, +ulo: Nat) -> String:
  +neg = Nat.is_le(2147483648n, uhi)
  +nz = Bool.pick(Nat, Nat.is_eq(ulo, 0n), 0n, 1n)
  +mhi = Bool.pick(Nat, neg, Nat.sub(Nat.sub(ints.two32(), uhi), nz), uhi)
  +mlo = Bool.pick(Nat, neg, Nat.mod(Nat.sub(ints.two32(), ulo), ints.two32()), ulo)
  is.sign(neg, is.dec(Nat.is_lt(mhi, 65536n), mhi, mlo))

def is.text.w(w: Nat, +b: String, +at: Nat) -> String:
  match w:
    case 2n:
      is.text.small(is.u16(b, at), 32768n, 65536n)
    case 4n:
      is.text.small(is.u32(b, at), 2147483648n, ints.two32())
    case _:
      is.text.wide(is.u32(b, Nat.add(at, 4n)), is.u32(b, at))

# the text of the member at index i of an intset's string b of width w
def is.text(+b: String, +w: Nat, +i: Nat) -> String:
  is.text.w(w, b, Nat.mul(i, w))

# the members of indices below k, in increasing order, before acc
def is.down(k: Nat, +b: String, +w: Nat, acc: List<&2, String>) -> List<&2, String>:
  match k:
    case 0n:
      acc
    case 1n++j:
      is.down(j, b, w, is.text(b, w, j) <> acc)

# is.text.w for the view's reads alone, as iw.key.w
def iw.text.w(w: Nat, +b: String, +at: Nat) -> String:
  match w:
    case 2n:
      is.text.small(is.u16(b, at), 32768n, 65536n)
    case 4n:
      is.text.small(is.u32(b, at), 2147483648n, ints.two32())
    case _:
      is.text.wide(is.u32(b, Nat.add(at, 4n)), is.u32(b, at))

def iw.text.at(lo: Bool, +a: String, +b: String, +k: Nat, +w: Nat, +at: Nat) -> String:
  match lo:
    case True{}:
      iw.text.w(w, a, at)
    case False{}:
      iw.text.w(w, b, Nat.sub(at, k))

# the text of the member at index i (w bytes) of the view v
def iw.text(+v: IView, +w: Nat, +i: Nat) -> String:
  match v:
    case IView{+a, +b, +k}:
      +at = Nat.mul(i, w)
      iw.text.at(Nat.is_lt(at, k), a, b, k, w, at)

# is.down through a view
def iw.down(k: Nat, +v: IView, +w: Nat, acc: List<&2, String>) -> List<&2, String>:
  match k:
    case 0n:
      acc
    case 1n++j:
      iw.down(j, v, w, iw.text(v, w, j) <> acc)

# k bytes x before rest
def is.fill(k: Nat, +x: Nat, rest: String) -> String:
  match k:
    case 0n:
      rest
    case 1n+j:
      pk.byte.put(x, is.fill(j, x, rest))

# the k members of b from index i on (w bytes each) in x bytes each, x
# at least w, each sign-extended, before rest
def is.widen(k: Nat, +b: String, +w: Nat, +x: Nat, +i: Nat, rest: String) -> String:
  match k:
    case 0n:
      rest
    case 1n+j:
      +at = Nat.mul(i, w)
      +top = Nat.is_le(128n, pk.byte(b, Nat.add(at, Nat.sub(w, 1n))))
      String.slice(b, at, w) ++ is.fill(Nat.sub(x, w), Bool.pick(Nat, top, 255n, 0n), is.widen(j, b, w, x, Nat.add(i, 1n), rest))

# the width of the members of the intset b of n members
def ints.w(+b: String, +n: Nat) -> Nat:
  Nat.div(String.length(b), n)

# far: b is past one buffer (n * w past 2,048 bytes)
def ints.has.of(fits: Bool, far: Bool, +v: IVal, +b: String, +w: Nat, +n: Nat) -> Bool:
  match fits far:
    case True{} False{}:
      +k = iv.key(w, v)
      +i = is.find.one(b, w, n, k)
      Bool.and(Nat.is_lt(i, n), ik.eq(is.key(b, w, i), k))
    case True{} True{}:
      +k = iv.key(w, v)
      +x = iw.view(b)
      +i = iw.find(x, w, n, k)
      Bool.and(Nat.is_lt(i, n), ik.eq(iw.key(x, w, i), k))
    case False{} _:
      False{}

# whether the intset of n members b holds the integer m (one of
# ints.ok): none that needs more bytes than its members
def ints.has(+m: String, +b: String, n: Nat) -> Bool:
  match n:
    case 0n:
      False{}
    case 1n++p:
      +v = iv.of(m)
      +w = ints.w(b, 1n+p)
      ints.has.of(Nat.is_le(iv.w(v), w), Nat.is_lt(2048n, Nat.mul(1n+p, w)), v, b, w, 1n+p)

def ints.put.wide(neg: Bool, +v: IVal, +x: Nat, all: String) -> String:
  match neg:
    case True{}:
      is.enc(x, v, all)
    case False{}:
      all ++ is.enc(x, v, "")

# the intset b of n members (w bytes each) with v, which it lacks: in its
# place when v fits in w bytes, else all of them made as wide as v, v the
# least (a negative one) or the greatest
def ints.put.of(fits: Bool, +v: IVal, +b: String, +w: Nat, +n: Nat) -> String:
  match fits:
    case True{}:
      +at = Nat.mul(is.find(b, w, n, iv.key(w, v)), w)
      pk.flat(String.take(b, at) ++ is.enc(w, v, String.drop(b, at)), Nat.mul(Nat.add(n, 1n), w))
    case False{}:
      +x = iv.w(v)
      pk.flat(ints.put.wide(iv.neg(v), v, x, is.widen(n, b, w, x, 0n, "")), Nat.mul(Nat.add(n, 1n), x))

def ints.put.go(n: Nat, +v: IVal, +b: String) -> String:
  match n:
    case 0n:
      +x = iv.w(v)
      pk.flat(is.enc(x, v, ""), x)
    case 1n++p:
      +w = ints.w(b, 1n+p)
      ints.put.of(Nat.is_le(iv.w(v), w), v, b, w, 1n+p)

# the intset b of n members with the integer m (one of ints.ok), which it
# lacks
def ints.put(+m: String, +b: String, +n: Nat) -> String:
  ints.put.go(n, iv.of(m), b)

# the intset b of n members without the integer m, which it holds
def ints.del(+m: String, +b: String, +n: Nat) -> String:
  +w = ints.w(b, n)
  +at = Nat.mul(is.find(b, w, n, iv.key(w, iv.of(m))), w)
  pk.flat(String.take(b, at) ++ String.drop(b, Nat.add(at, w)), Nat.mul(Nat.sub(n, 1n), w))

def ints.nth.of(ok: Bool, +b: String, +w: Nat, +i: Nat) -> Maybe<&2, String>:
  match ok:
    case True{}:
      Some{is.text(b, w, i)}
    case False{}:
      None{}

# the member at rank i of the intset b of n members (none when i is not
# below n)
def ints.nth(+b: String, +n: Nat, +i: Nat) -> Maybe<&2, String>:
  ints.nth.of(Nat.is_lt(i, n), b, ints.w(b, n), i)

# the members of the intset b of n members, in increasing order, before
# acc
def ints.list.of(far: Bool, +b: String, +n: Nat, +w: Nat, acc: List<&2, String>) -> List<&2, String>:
  match far:
    case True{}:
      iw.down(n, iw.view(b), w, acc)
    case False{}:
      is.down(n, b, w, acc)

def ints.list.on(+b: String, +n: Nat, acc: List<&2, String>) -> List<&2, String>:
  +w = ints.w(b, n)
  ints.list.of(Nat.is_lt(2048n, Nat.mul(n, w)), b, n, w, acc)

def ints.list(+b: String, +n: Nat) -> List<&2, String>:
  ints.list.on(b, n, Nil{})

# the k members of an intset's string b (w bytes each) from index i on,
# in increasing order, added to the trie t
def ints.trie(k: Nat, +b: String, +w: Nat, +i: Nat, t: Trie<Unit>) -> Trie<Unit>:
  match k:
    case 0n:
      t
    case 1n+j:
      ints.trie(j, b, w, Nat.add(i, 1n), set(Unit, t, is.text(b, w, i), Unit{}))

# ints.trie through a view
def iw.trie(k: Nat, +v: IView, +w: Nat, +i: Nat, t: Trie<Unit>) -> Trie<Unit>:
  match k:
    case 0n:
      t
    case 1n+j:
      iw.trie(j, v, w, Nat.add(i, 1n), set(Unit, t, iw.text(v, w, i), Unit{}))

# the trie of the n members of the intset b, w bytes each (far: b is
# past one buffer)
def ints.trie.of(far: Bool, +b: String, +n: Nat, +w: Nat) -> Trie<Unit>:
  match far:
    case True{}:
      iw.trie(n, iw.view(b), w, 0n, empty(Unit))
    case False{}:
      ints.trie(n, b, w, 0n, empty(Unit))

# the intset b of n members with the integers xs (one of ints.ok each,
# none there, none twice) added in turn (RESTORE of a set of them)
def ints.of(xs: List<&2, String>, +b: String, +n: Nat) -> String:
  match xs:
    case Nil{}:
      b
    case Con{+x, rest}:
      ints.of(rest, ints.put(x, b, n), Nat.add(n, 1n))

# A small hashtable's string (MSmall, above) holds its members one after
# another, as a listpack holds a small set in one allocation: a member is
# its length, one byte (a member of a small set has at most 64 bytes),
# then its bytes. A read walks the lengths from the start to the member
# it wants, comparing a member of the right length by its last byte, then
# whole (pk.hit.of, as a small hash compares a field); a write makes the
# string anew in one buffer (pk.flat), as a small hash's write does. The
# string holds at most a buffer, 2,048 bytes: past one, String.code_at
# walks a chain from its start (Hashes, above), and 128 members of 64
# bytes take 8,320. Past that, the members are in pieces (MLong), each
# the members that fill one buffer: a read goes through them in order
# and finds in one, a new member goes in the last piece while it has
# room, else in a piece of its own, a delete cuts one piece, and a piece
# it empties goes; one piece left is a string again (ml.set).

# the length of the member whose code is at index i of b, one of k
# members from there on (0 when there is none)
def ms.flen(k: Nat, +b: String, +i: Nat) -> Nat:
  match k:
    case 0n:
      0n
    case 1n+j:
      pk.byte(b, i)

# whether the member at index i of b, one of k from there on, n bytes
# long, is m (lm bytes long, its last byte lb): the lengths first, then
# the last bytes, then the bytes
def ms.hit(k: Nat, +m: String, +lm: Nat, +lb: U32, +b: String, +i: Nat, +n: Nat) -> Bool:
  match k:
    case 0n:
      False{}
    case 1n+j:
      pk.hit.of(Nat.is_eq(n, lm), m, lb, b, Nat.add(i, 1n), n)

# the index of m's code among the k members from index i of b on, the
# first of them n bytes long, or the index past them when m is not one;
# hit is ms.hit(k, m, lm, lb, b, i, n), computed before b is passed on
def ms.find.go(+m: String, +lm: Nat, +lb: U32, +b: String, k: Nat, hit: Bool, +i: Nat, +n: Nat) -> Nat:
  match k hit:
    case 0n _:
      i
    case 1n++j True{}:
      i
    case 1n++j False{}:
      +x = Nat.add(i, Nat.add(1n, n))
      +xn = ms.flen(j, b, x)
      ms.find.go(m, lm, lb, b, j, ms.hit(j, m, lm, lb, b, x, xn), x, xn)

# the index of m's code in the string b of a small set of k members, or
# b's length when m is not there
def ms.find(+m: String, +b: String, +k: Nat) -> Nat:
  +lm = String.length(m)
  +lb = String.code_at(m, Nat.sub(lm, 1n))
  +n = ms.flen(k, b, 0n)
  ms.find.go(m, lm, lb, b, k, ms.hit(k, m, lm, lb, b, 0n, n), 0n, n)

# whether the small set of k members b holds m
def ms.has(+m: String, +b: String, +k: Nat) -> Bool:
  Nat.is_lt(ms.find(m, b, k), String.length(b))

# the k members from index i of b on, the last first, before acc
def ms.all.rev(k: Nat, +b: String, +i: Nat, acc: List<&2, String>) -> List<&2, String>:
  match k:
    case 0n:
      acc
    case 1n+j:
      +n = pk.byte(b, i)
      ms.all.rev(j, b, Nat.add(i, Nat.add(1n, n)), String.slice(b, Nat.add(i, 1n), n) <> acc)

# the k members of the small set b, in its order: a walk that keeps no
# frame for each member, then the list turned around
def ms.all(k: Nat, +b: String) -> List<&2, String>:
  List.reverse(&2, String, ms.all.rev(k, b, 0n, Nil{}))

# the index of the code of the member r places after the one whose code
# is at index i
def ms.skip(r: Nat, +b: String, +i: Nat) -> Nat:
  match r:
    case 0n:
      i
    case 1n+q:
      ms.skip(q, b, Nat.add(i, Nat.add(1n, pk.byte(b, i))))

def ms.nth.of(ok: Bool, +b: String, +i: Nat) -> Maybe<&2, String>:
  match ok:
    case True{}:
      Some{String.slice(b, Nat.add(i, 1n), pk.byte(b, i))}
    case False{}:
      None{}

# the member at rank r of the small set of k members b (none when r is
# not below k)
def ms.nth(+k: Nat, +b: String, +r: Nat) -> Maybe<&2, String>:
  ms.nth.of(Nat.is_lt(r, k), b, ms.skip(Nat.min(r, k), b, 0n))

# b, of l bytes, with the member m (lm bytes) after its last, in one
# buffer
def ms.push(+b: String, +l: Nat, +m: String, +lm: Nat) -> String:
  pk.flat(b ++ pk.byte.put(lm, m), Nat.add(l, Nat.add(1n, lm)))

# b without the member whose code is at index i, in one buffer
def ms.cut(+b: String, +i: Nat) -> String:
  +end = Nat.add(i, Nat.add(1n, pk.byte(b, i)))
  +n = Nat.sub(String.length(b), Nat.sub(end, i))
  +pre = String.take(b, i)
  pk.flat(pre ++ String.drop(b, end), n)

# the k members from index i of b on added to the trie t
def ms.trie(k: Nat, +b: String, +i: Nat, t: Trie<Unit>) -> Trie<Unit>:
  match k:
    case 0n:
      t
    case 1n+j:
      +n = pk.byte(b, i)
      ms.trie(j, b, Nat.add(i, Nat.add(1n, n)), set(Unit, t, String.slice(b, Nat.add(i, 1n), n), Unit{}))

# whether a small set of n members, one of them m, stays small
def ms.fits(+n: Nat, +m: String) -> Bool:
  Bool.and(Nat.is_le(n, 128n), Nat.is_le(String.length(m), 64n))

# the member m (lm bytes) alone, as a small set's string
def ms.one(+m: String, +lm: Nat) -> String:
  pk.flat(pk.byte.put(lm, m), Nat.add(1n, lm))

# the members xs (the last first) as a small set's string, before acc
def ms.enc.rev(xs: List<&2, String>, acc: String) -> String:
  match xs:
    case Nil{}:
      acc
    case Con{+x, more}:
      ms.enc.rev(more, pk.byte.put(String.length(x), x ++ acc))

# Pieces (MLong, above): each the k members of its string s.

def ml.has.in(+m: String, +p: MPiece) -> Bool:
  match p:
    case MPc{+k, +s}:
      ms.has(m, s, k)

# whether m is in the pieces ps, unless had already says so
def ml.has(+m: String, +ps: List<&2, MPiece>, had: Bool) -> Bool:
  match ps had:
    case Nil{} True{}:
      True{}
    case Nil{} False{}:
      False{}
    case Con{+p, +rest} True{}:
      True{}
    case Con{+p, +rest} False{}:
      ml.has(m, rest, ml.has.in(m, p))

def ml.all.in(+p: MPiece, acc: List<&2, String>) -> List<&2, String>:
  match p:
    case MPc{+k, +s}:
      ms.all.rev(k, s, 0n, acc)

# the members of the pieces ps, the last first, before acc
def ml.all.rev(+ps: List<&2, MPiece>, acc: List<&2, String>) -> List<&2, String>:
  match ps:
    case Nil{}:
      acc
    case Con{+p, +rest}:
      ml.all.rev(rest, ml.all.in(p, acc))

# the members of the pieces ps, in their order
def ml.all(+ps: List<&2, MPiece>) -> List<&2, String>:
  List.reverse(&2, String, ml.all.rev(ps, Nil{}))

def ml.nth.in(+p: MPiece, +r: Nat) -> Maybe<&2, String>:
  match p:
    case MPc{+k, +s}:
      ms.nth(k, s, r)

def ml.k(+p: MPiece) -> Nat:
  match p:
    case MPc{+k, s}:
      k

# the member at rank r of the pieces ps, unless m already holds the one
# asked for (r is then past the pieces' members, and not read)
def ml.nth(+ps: List<&2, MPiece>, +r: Nat, m: Maybe<&2, String>) -> Maybe<&2, String>:
  match ps m:
    case Nil{} Some{x}:
      Some{x}
    case Nil{} None{}:
      None{}
    case Con{+p, +rest} Some{x}:
      Some{x}
    case Con{+p, +rest} None{}:
      ml.nth(rest, Nat.sub(r, ml.k(p)), ml.nth.in(p, r))

def ml.trie.in(+p: MPiece, t: Trie<Unit>) -> Trie<Unit>:
  match p:
    case MPc{+k, +s}:
      ms.trie(k, s, 0n, t)

# the members of the pieces ps added to the trie t
def ml.trie(+ps: List<&2, MPiece>, t: Trie<Unit>) -> Trie<Unit>:
  match ps:
    case Nil{}:
      t
    case Con{+p, +rest}:
      ml.trie(rest, ml.trie.in(p, t))

# the last piece, of k members s, with the member m (lm bytes) after its
# last: in it while it fills no more than a buffer, else in a piece of
# its own
def ml.add.of(room: Bool, +k: Nat, +s: String, +m: String, +lm: Nat) -> List<&2, MPiece>:
  match room:
    case True{}:
      [MPc{1n+k, ms.push(s, String.length(s), m, lm)}]
    case False{}:
      [MPc{k, s}, MPc{1n, ms.one(m, lm)}]

# the piece of k members s, then rest, with m after the last member
def ml.push.go(rest: List<&2, MPiece>, +k: Nat, +s: String, +m: String, +lm: Nat) -> List<&2, MPiece>:
  match rest:
    case Nil{}:
      ml.add.of(Nat.is_le(Nat.add(String.length(s), Nat.add(1n, lm)), 2048n), k, s, m, lm)
    case Con{MPc{+j, +r}, more}:
      Con{MPc{k, s}, ml.push.go(more, j, r, m, lm)}

# the pieces ps with the member m (lm bytes), which they lack, after the
# last
def ml.push(ps: List<&2, MPiece>, +m: String, +lm: Nat) -> List<&2, MPiece>:
  match ps:
    case Nil{}:
      [MPc{1n, ms.one(m, lm)}]
    case Con{MPc{+k, +s}, rest}:
      ml.push.go(rest, k, s, m, lm)

# the piece of k members s before rest, none when k is 0
def ml.drop(k: Nat, +s: String, rest: List<&2, MPiece>) -> List<&2, MPiece>:
  match k:
    case 0n:
      rest
    case 1n+j:
      Con{MPc{1n+j, s}, rest}

# the pieces with m taken out: the piece of k members s, then rest; had:
# m is in s, its code at index i. A piece left with no member goes
def ml.cut.go(+m: String, rest: List<&2, MPiece>, had: Bool, +k: Nat, +s: String, +i: Nat) -> List<&2, MPiece>:
  match rest had:
    case Nil{} True{}:
      ml.drop(Nat.sub(k, 1n), ms.cut(s, i), Nil{})
    case Nil{} False{}:
      [MPc{k, s}]
    case Con{MPc{j, r}, more} True{}:
      ml.drop(Nat.sub(k, 1n), ms.cut(s, i), Con{MPc{j, r}, more})
    case Con{MPc{+j, +r}, more} False{}:
      +q = ms.find(m, r, j)
      Con{MPc{k, s}, ml.cut.go(m, more, Nat.is_lt(q, String.length(r)), j, r, q)}

# the pieces ps with m, which they hold, taken out
def ml.cut(+m: String, ps: List<&2, MPiece>) -> List<&2, MPiece>:
  match ps:
    case Nil{}:
      Nil{}
    case Con{MPc{+k, +s}, rest}:
      +q = ms.find(m, s, k)
      ml.cut.go(m, rest, Nat.is_lt(q, String.length(s)), k, s, q)

# the piece of the k members cur (the last first), len bytes, before rest
# (none when k is 0)
def ml.close(k: Nat, cur: List<&2, String>, +len: Nat, rest: List<&2, MPiece>) -> List<&2, MPiece>:
  match k:
    case 0n:
      rest
    case 1n+j:
      Con{MPc{1n+j, pk.flat(ms.enc.rev(cur, ""), len)}, rest}

# whether the first member of xs goes in a piece of len bytes: it fills
# no more than a buffer, or the piece is empty
def ml.room(xs: List<&2, String>, +len: Nat) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case Con{+x, more}:
      Bool.or(Nat.is_eq(len, 0n), Nat.is_le(Nat.add(len, Nat.add(1n, String.length(x))), 2048n))

# the members xs in pieces before the pieces tail, after the k members
# cur (the last first, len bytes) of the piece being filled; room is
# ml.room(xs, len)
def ml.fill(xs: List<&2, String>, room: Bool, cur: List<&2, String>, +k: Nat, +len: Nat, tail: List<&2, MPiece>) -> List<&2, MPiece>:
  match xs room:
    case Nil{} _:
      ml.close(k, cur, len, tail)
    case Con{+x, +more} True{}:
      +l = Nat.add(len, Nat.add(1n, String.length(x)))
      ml.fill(more, ml.room(more, l), Con{x, cur}, 1n+k, l, tail)
    case Con{+x, +more} False{}:
      +l = Nat.add(1n, String.length(x))
      ml.close(k, cur, len, ml.fill(more, ml.room(more, l), [x], 1n, l, tail))

# the members xs, in their order, in pieces of one buffer each
def ml.of(xs: List<&2, String>) -> List<&2, MPiece>:
  ml.fill(xs, True{}, Nil{}, 0n, 0n, Nil{})

# a small set of n members in the pieces ps: one string when one piece
# is left (or none)
def ml.set.of(+n: Nat, +k: Nat, +s: String, rest: List<&2, MPiece>) -> Mems:
  match rest:
    case Nil{}:
      MSmall{n, s}
    case Con{q, more}:
      MLong{n, Con{MPc{k, s}, Con{q, more}}}

def ml.set(+n: Nat, ps: List<&2, MPiece>) -> Mems:
  match ps:
    case Nil{}:
      MSmall{n, ""}
    case Con{MPc{+k, +s}, rest}:
      ml.set.of(n, k, s, rest)

# the small set of the n members xs, in their order (RESTORE)
def ms.make(+n: Nat, xs: List<&2, String>) -> Mems:
  ml.set(n, ml.of(xs))

def mems.empty() -> Mems:
  MInts{0n, ""}

def mems.len(+s: Mems) -> Nat:
  match s:
    case MInts{+n, xs}:
      n
    case MBig{+n, t}:
      n
    case MSmall{+n, b}:
      n
    case MLong{+n, ps}:
      n

def mems.ints.has(int: Bool, +m: String, +b: String, +n: Nat) -> Bool:
  match int:
    case True{}:
      ints.has(m, b, n)
    case False{}:
      False{}

# whether s holds m
def mems.has(+m: String, +s: Mems) -> Bool:
  match s:
    case MInts{+n, +b}:
      mems.ints.has(ints.ok(m), m, b, n)
    case MBig{n, +t}:
      has(Unit, t, m)
    case MSmall{+n, +b}:
      ms.has(m, b, n)
    case MLong{n, +ps}:
      ml.has(m, ps, False{})

# n members b of an intset, and m, which they do not hold, as a
# hashtable: small while it fits (the intset's members in increasing
# order, then m), else a trie
def mems.grow.of(fits: Bool, +n: Nat, +b: String, +m: String) -> Mems:
  match fits:
    case True{}:
      ml.set(1n+n, ml.of(ints.list.on(b, n, [m])))
    case False{}:
      +w = ints.w(b, n)
      MBig{1n+n, set(Unit, ints.trie.of(Nat.is_lt(2048n, Nat.mul(n, w)), b, n, w), m, Unit{})}

def mems.grow(+n: Nat, +b: String, +m: String) -> Mems:
  mems.grow.of(ms.fits(1n+n, m), n, b, m)

def mems.ints.put(fits: Bool, +n: Nat, +b: String, +m: String) -> Mems:
  match fits:
    case True{}:
      MInts{1n+n, ints.put(m, b, n)}
    case False{}:
      mems.grow(n, b, m)

def mems.ints.add(had: Bool, int: Bool, +n: Nat, b: String, +m: String) -> Mems:
  match had int:
    case True{} _:
      MInts{n, b}
    case False{} True{}:
      mems.ints.put(Nat.is_lt(n, 512n), n, b, m)
    case False{} False{}:
      mems.grow(n, b, m)

def mems.big.add(had: Bool, +n: Nat, t: Trie<Unit>, +m: String) -> Mems:
  match had:
    case True{}:
      MBig{n, t}
    case False{}:
      MBig{1n+n, set(Unit, t, m, Unit{})}

# the string b of a small set of n members with m (lm bytes), which it
# lacks, after its last: in the string while it fills no more than a
# buffer, else in a piece of its own
def ms.push.of(room: Bool, +n: Nat, +b: String, +m: String, +lm: Nat) -> Mems:
  match room:
    case True{}:
      MSmall{1n+n, ms.push(b, String.length(b), m, lm)}
    case False{}:
      MLong{1n+n, [MPc{n, b}, MPc{1n, ms.one(m, lm)}]}

# a small set of n members b with m, which it lacks, after its last:
# small while it fits, else a trie
def mems.small.put(fits: Bool, +n: Nat, +b: String, +m: String) -> Mems:
  match fits:
    case True{}:
      +lm = String.length(m)
      ms.push.of(Nat.is_le(Nat.add(String.length(b), Nat.add(1n, lm)), 2048n), n, b, m, lm)
    case False{}:
      MBig{1n+n, set(Unit, ms.trie(n, b, 0n, empty(Unit)), m, Unit{})}

def mems.small.add(had: Bool, +n: Nat, b: String, +m: String) -> Mems:
  match had:
    case True{}:
      MSmall{n, b}
    case False{}:
      mems.small.put(ms.fits(1n+n, m), n, b, m)

# a small set of n members in the pieces ps with m, which they lack,
# after the last: small while it fits, else a trie
def mems.long.put(fits: Bool, +n: Nat, ps: List<&2, MPiece>, +m: String) -> Mems:
  match fits:
    case True{}:
      MLong{1n+n, ml.push(ps, m, String.length(m))}
    case False{}:
      MBig{1n+n, set(Unit, ml.trie(ps, empty(Unit)), m, Unit{})}

def mems.long.add(had: Bool, +n: Nat, ps: List<&2, MPiece>, +m: String) -> Mems:
  match had:
    case True{}:
      MLong{n, ps}
    case False{}:
      mems.long.put(ms.fits(1n+n, m), n, ps, m)

# s with m added (s may hold it already): an integer joins an intset in
# its place, while it holds at most 512; any other member makes it a
# hashtable, a small one while it holds at most 128 members of at most
# 64 bytes
def mems.add(s: Mems, +m: String) -> Mems:
  match s:
    case MInts{+n, +b}:
      +int = ints.ok(m)
      mems.ints.add(mems.ints.has(int, m, b, n), int, n, b, m)
    case MBig{+n, +t}:
      +had = has(Unit, t, m)
      mems.big.add(had, n, t, m)
    case MSmall{+n, +b}:
      +had = ms.has(m, b, n)
      mems.small.add(had, n, b, m)
    case MLong{+n, +ps}:
      +had = ml.has(m, ps, False{})
      mems.long.add(had, n, ps, m)

# the members xs added in turn to s
def mems.adds(xs: List<&2, String>, s: Mems) -> Mems:
  match xs:
    case Nil{}:
      s
    case Con{+x, rest}:
      mems.adds(rest, mems.add(s, x))

# A write of k members (SADD) first sizes its set by them, as Redis 7.2
# does with the count of its arguments, whether they are there or come
# twice: a key not there starts as an intset when the first is an integer
# and they are 512 at most, else as a listpack when they are 128 at most,
# else as a hashtable (setTypeCreate); a listpack that is there becomes a
# hashtable when they are more than 128, an intset when they are more
# than 512 (setTypeMaybeConvert)
def mems.create.str(+k: Nat) -> Mems:
  Bool.pick(Mems, Nat.is_le(k, 128n), MSmall{0n, ""}, MBig{0n, empty(Unit)})

def mems.create.of(int: Bool, +k: Nat) -> Mems:
  match int:
    case True{}:
      Bool.pick(Mems, Nat.is_le(k, 512n), MInts{0n, ""}, mems.create.str(k))
    case False{}:
      mems.create.str(k)

# the empty set a write of the members xs starts from
def mems.create(+xs: List<&2, String>) -> Mems:
  match xs:
    case Nil{}:
      mems.empty()
    case Con{+x, rest}:
      mems.create.of(ints.ok(x), 1n+List.length(&2, String, rest))

def mems.maybe.ints(past: Bool, +n: Nat, +b: String) -> Mems:
  match past:
    case True{}:
      +w = ints.w(b, n)
      MBig{n, ints.trie.of(Nat.is_lt(2048n, Nat.mul(n, w)), b, n, w)}
    case False{}:
      MInts{n, b}

def mems.maybe.small(past: Bool, +n: Nat, +b: String) -> Mems:
  match past:
    case True{}:
      MBig{n, ms.trie(n, b, 0n, empty(Unit))}
    case False{}:
      MSmall{n, b}

def mems.maybe.long(past: Bool, +n: Nat, +ps: List<&2, MPiece>) -> Mems:
  match past:
    case True{}:
      MBig{n, ml.trie(ps, empty(Unit))}
    case False{}:
      MLong{n, ps}

# the set s before a write of k members
def mems.maybe(+k: Nat, s: Mems) -> Mems:
  match s:
    case MInts{+n, +b}:
      mems.maybe.ints(Nat.is_lt(512n, k), n, b)
    case MBig{n, t}:
      MBig{n, t}
    case MSmall{+n, +b}:
      mems.maybe.small(Nat.is_lt(128n, k), n, b)
    case MLong{+n, +ps}:
      mems.maybe.long(Nat.is_lt(128n, k), n, ps)

# the set of the members xs (a member may come twice), as SADD makes it
# where the key is not there
def mems.of(+xs: List<&2, String>) -> Mems:
  mems.adds(xs, mems.create(xs))

# s without m, which it holds
def mems.del(s: Mems, +m: String) -> Mems:
  match s:
    case MInts{+n, +b}:
      MInts{Nat.sub(n, 1n), ints.del(m, b, n)}
    case MBig{+n, t}:
      MBig{Nat.sub(n, 1n), del(Unit, t, m)}
    case MSmall{+n, +b}:
      MSmall{Nat.sub(n, 1n), ms.cut(b, ms.find(m, b, n))}
    case MLong{+n, ps}:
      ml.set(Nat.sub(n, 1n), ml.cut(m, ps))

# the members of s, in its order (an intset's, increasing; a small
# hashtable's, the order they came)
def mems.all(+s: Mems) -> List<&2, String>:
  match s:
    case MInts{+n, +b}:
      ints.list(b, n)
    case MBig{n, +t}:
      keys(Unit, t, 0n)
    case MSmall{+n, +b}:
      ms.all(n, b)
    case MLong{n, +ps}:
      ml.all(ps)

# Lists as Redis 7.2 holds them
# -----------------------------
# Redis 7.2 holds a small list as a listpack and a larger one as a
# quicklist, a chain of listpacks (its nodes), at list-max-listpack-size's
# default of -2 (8 KB) and list-compress-depth's of 0 (t_list.c,
# quicklist.c). A write that adds elements first makes a listpack a
# quicklist of one node, itself, when its bytes (lpBytes) and the lengths
# of the elements to come pass 8 KB (listTypeTryConvertListpack: an
# integer that a quicklist gave back to LMOVE counts no bytes); a write
# that takes elements out then makes a quicklist of one node of 4 KB at
# most a listpack again (listTypeTryConvertQuicklist), and a list read
# from a payload or a file is a listpack when it is one node of 8 KB at
# most. A node takes an element pushed at its end while its bytes, the
# element's length and 8 stay within 8 KB (_quicklistNodeAllowInsert),
# else the element starts a node of its own; a pop, LREM and LTRIM take
# elements out of their nodes and drop the nodes they empty; LSET writes
# its element in its node, whatever its size; LINSERT writes into the
# node of its pivot when that has room, else at the node's end into the
# next node or the one before when that has room, or into a node of its
# own, else splits the node and merges the nodes around it that fit in
# 8 KB together (_quicklistInsert). Deq keeps the elements (DQ) and the
# listpack's bytes or the quicklist's nodes, each its count of elements
# and its bytes (QNs), in two stacks that are dealt again as a list's
# pieces are (dq.fix). An entry's bytes are its encoding's and its
# backlen's (lpk.esize). Where BendKV differs: an LINSERT whose pivot is
# not there and an LSET of an index the list does not have leave the list
# as it was, where Redis has already made a listpack a quicklist when the
# element would take it past 8 KB, and an LTRIM that takes nothing leaves
# it as it was, where Redis makes a quicklist of one node of 4 KB at most
# a listpack (a list read from a ziplist, before any write), none of them
# logged; LMOVE counts an integer it takes from a quicklist by its length
# toward a listpack's 8 KB, where Redis counts none, and LMOVE of a list
# onto itself makes it a listpack when the pop leaves it one node of 4 KB
# at most, where Redis looks once the push is done; SORT's STORE makes its
# list as RPUSH makes one, where Redis
# pushes it into a quicklist that it makes a listpack when that is one
# node; an element of 1 GB or more is kept in a node as any other, where
# Redis keeps it in a plain node of its own; and list-max-listpack-size's
# and list-compress-depth's other values are kept and read back, but move
# none of these limits.

# the bytes a listpack or a node holds before a write makes it a
# quicklist or a new node, and half of them, which a quicklist's one node
# holds at most to be a listpack again
def lpk.lim() -> Nat:
  8192n

def lpk.half() -> Nat:
  4096n

# the bytes of an empty listpack: its header of 6 and its end
def lpk.empty() -> Nat:
  7n

# an integer's entry (lpStringToInt64 reads it): 7 bits (0 to 127), 13,
# 16, 24, 32 or 64, the narrowest that holds it, after its tag
def lpk.isize(+v: IVal) -> Nat:
  match v:
    case IVal{+neg, +hi, +lo}:
      +b = Bool.pick(Nat, neg, 1n, 0n)
      Bool.pick(Nat, Nat.is_lt(0n, hi), 9n,
        Bool.pick(Nat, Bool.and(Bool.not(neg), Nat.is_le(lo, 127n)), 1n,
          Bool.pick(Nat, Nat.is_lt(lo, Nat.add(4096n, b)), 2n,
            Bool.pick(Nat, Nat.is_lt(lo, Nat.add(32768n, b)), 3n,
              Bool.pick(Nat, Nat.is_lt(lo, Nat.add(8388608n, b)), 4n,
                Bool.pick(Nat, Nat.is_lt(lo, Nat.add(2147483648n, b)), 5n, 9n))))))

# a string's entry of l bytes: its header of 1, 2 or 5 bytes, then its
# bytes
def lpk.ssize(+l: Nat) -> Nat:
  Nat.add(l, Bool.pick(Nat, Nat.is_lt(l, 64n), 1n, Bool.pick(Nat, Nat.is_lt(l, 4096n), 2n, 5n)))

def lpk.esize.of(int: Bool, +x: String) -> Nat:
  match int:
    case True{}:
      lpk.isize(iv.of(x))
    case False{}:
      lpk.ssize(String.length(x))

# how many bytes the backlen of an entry of e bytes takes
def lpk.backn(+e: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_le(e, 127n), 1n, Bool.pick(Nat, Nat.is_lt(e, 16383n), 2n, Bool.pick(Nat, Nat.is_lt(e, 2097151n), 3n, Bool.pick(Nat, Nat.is_lt(e, 268435455n), 4n, 5n))))

# the bytes of x's entry in a listpack, its backlen with it
def lpk.esize(+x: String) -> Nat:
  +e = lpk.esize.of(ints.ok(x), x)
  Nat.add(e, lpk.backn(e))

# the entries' bytes of xs, after acc
def lpk.sum(xs: List<&2, String>, +acc: Nat) -> Nat:
  match xs:
    case Nil{}:
      acc
    case Con{+x, rest}:
      lpk.sum(rest, Nat.add(acc, lpk.esize(x)))

# the lengths of xs, after acc
def lpk.raw(xs: List<&2, String>, +acc: Nat) -> Nat:
  match xs:
    case Nil{}:
      acc
    case Con{+x, rest}:
      lpk.raw(rest, Nat.add(acc, String.length(x)))

# the entries' bytes of the first k elements of q, or of the last
def lpk.ends(+last: Bool, +k: Nat, +q: DQ) -> Nat:
  match k:
    case 0n:
      0n
    case 1n++j:
      +n = dq.len(q)
      lpk.sum(dq.range(Bool.pick(Nat, last, Nat.sub(n, 1n+j), 0n), Bool.pick(Nat, last, Nat.sub(n, 1n), j), q), 0n)

# the entries' bytes of the r elements of q from index s on
def lpk.span(r: Nat, +s: Nat, +q: DQ) -> Nat:
  match r:
    case 0n:
      0n
    case 1n+j:
      lpk.sum(dq.range(s, Nat.add(s, j), q), 0n)

# Nodes

# whether a node of sz bytes takes an element of l bytes at its end: its
# bytes, l and 8 more (SIZE_ESTIMATE_OVERHEAD) within 8 KB
def qn.room(+sz: Nat, +l: Nat) -> Bool:
  Nat.is_le(Nat.add(Nat.add(sz, l), 8n), lpk.lim())

# whether nodes of a and b bytes merge: one listpack of both, with one
# header and one end, within 8 KB (_quicklistNodeAllowMerge)
def qn.joins(+a: Nat, +b: Nat) -> Bool:
  Nat.is_le(Nat.sub(Nat.add(a, b), lpk.empty()), lpk.lim())

# the node two nodes make (lpMerge)
def qn.join(a: QN, b: QN) -> QN:
  match a b:
    case QN{+ac, +asz} QN{+bc, +bsz}:
      QN{Nat.add(ac, bc), Nat.sub(Nat.add(asz, bsz), lpk.empty())}

# a node of one element, an entry of e bytes
def qn.new(+e: Nat) -> QN:
  QN{1n, Nat.add(lpk.empty(), e)}

# how many elements the nodes ns hold, after acc
def qn.count(ns: List<&2, QN>, +acc: Nat) -> Nat:
  match ns:
    case Nil{}:
      acc
    case Con{QN{+c, sz}, rest}:
      qn.count(rest, Nat.add(acc, c))

# the first h nodes of ns reversed before acc, and the others
def qn.cut(h: Nat, ns: List<&2, QN>, acc: List<&2, QN>) -> List<&2, QN> & List<&2, QN>:
  match h ns:
    case 0n ms:
      (acc, ms)
    case 1n+j Con{x, rest}:
      qn.cut(j, rest, x <> acc)
    case 1n+j Nil{}:
      (acc, Nil{})

# n nodes of c elements: the first h (q's first, reversed) in the front
# stack, the others in the back stack
def qn.dealt(+h: Nat, +n: Nat, +c: Nat, q: List<&2, QN> & List<&2, QN>) -> QNs:
  (rf, +rest) = q
  +cb = qn.count(rest, 0n)
  QQl{h, Nat.sub(c, cb), List.reverse(&2, QN, rf), Nat.sub(n, h), cb, List.reverse(&2, QN, rest)}

# the n nodes ns of c elements, in order, dealt half to each stack
def qn.deal(+n: Nat, +c: Nat, ns: List<&2, QN>) -> QNs:
  +h = Nat.div(n, 2n)
  qn.dealt(h, n, c, qn.cut(h, ns, Nil{}))

# the nodes ns, in order, as a quicklist's
def qn.of(+ns: List<&2, QN>) -> QNs:
  qn.deal(List.length(&2, QN, ns), qn.count(ns, 0n), ns)

# a quicklist's nodes in order
def qn.list(f: List<&2, QN>, b: List<&2, QN>) -> List<&2, QN>:
  List.append(&2, QN, f, List.reverse(&2, QN, b))

def qn.fix.if(tilted: Bool, +nf: Nat, +cf: Nat, f: List<&2, QN>, +nb: Nat, +cb: Nat, b: List<&2, QN>) -> QNs:
  match tilted:
    case True{}:
      qn.deal(Nat.add(nf, nb), Nat.add(cf, cb), qn.list(f, b))
    case False{}:
      QQl{nf, cf, f, nb, cb, b}

# the nodes dealt again, half to each stack, when one stack holds more
# than three times the other's and one more (as a list's pieces, dq.fix):
# when a stack is empty, the other holds one node at most
def qn.fix(+nf: Nat, +cf: Nat, f: List<&2, QN>, +nb: Nat, +cb: Nat, b: List<&2, QN>) -> QNs:
  qn.fix.if(dq.tilted(nf, nb), nf, cf, f, nb, cb, b)

# a listpack of n elements in lb bytes made a quicklist: one node, itself,
# or none when it is empty
def qn.one(n: Nat, +lb: Nat) -> QNs:
  match n:
    case 0n:
      QQl{0n, 0n, Nil{}, 0n, 0n, Nil{}}
    case 1n++k:
      QQl{1n, 1n+k, [QN{1n+k, lb}], 0n, 0n, Nil{}}

def qn.grown(past: Bool, +n: Nat, +lb: Nat) -> QNs:
  match past:
    case True{}:
      qn.one(n, lb)
    case False{}:
      QLp{lb}

# a list of n elements, held as ns, before a write adds elements of add
# bytes: a listpack that they would take past 8 KB made a quicklist
def qn.grow(+n: Nat, +add: Nat, ns: QNs) -> QNs:
  match ns:
    case QLp{+lb}:
      qn.grown(Nat.is_lt(lpk.lim(), Nat.add(lb, add)), n, lb)
    case ms:
      ms

def qn.head.sz(ns: List<&2, QN>) -> Nat:
  match ns:
    case Nil{}:
      0n
    case Con{QN{c, +sz}, rest}:
      sz

def qn.fit.if(one: Bool, +lim: Nat, +sz: Nat, ns: QNs) -> QNs:
  match one:
    case True{}:
      Bool.pick(QNs, Nat.is_le(sz, lim), QLp{sz}, ns)
    case False{}:
      ns

# a list after a write or a read: a quicklist of one node of lim bytes at
# most made a listpack, the node itself (lim: 4 KB after a write that took
# elements out, 8 KB for a list read)
def qn.fit(+lim: Nat, ns: QNs) -> QNs:
  match ns:
    case QLp{+lb}:
      QLp{lb}
    case QQl{+nf, +cf, +f, +nb, +cb, +b}:
      qn.fit.if(Nat.is_eq(Nat.add(nf, nb), 1n), lim, Nat.add(qn.head.sz(f), qn.head.sz(b)), QQl{nf, cf, f, nb, cb, b})

# whether a list is a quicklist
def qn.ql(+ns: QNs) -> Bool:
  match ns:
    case QLp{lb}:
      False{}
    case QQl{nf, cf, f, nb, cb, b}:
      True{}

# Pushes and pops at the ends: x (l bytes, an entry of e bytes) put first
# into the first node when it has room, else into a node of its own
# (quicklistPushHead); the front stack empty, the first node is the back
# stack's one
def qn.pushl.in(room: Bool, +e: Nat, +c: Nat, +sz: Nat, rest: List<&2, QN>, +nf: Nat, +cf: Nat, +nb: Nat, +cb: Nat, b: List<&2, QN>) -> QNs:
  match room:
    case True{}:
      QQl{nf, 1n+cf, QN{1n+c, Nat.add(sz, e)} <> rest, nb, cb, b}
    case False{}:
      qn.fix(1n+nf, 1n+cf, qn.new(e) <> (QN{c, sz} <> rest), nb, cb, b)

def qn.pushl.one(room: Bool, +e: Nat, +c: Nat, +sz: Nat, +nb: Nat, +cb: Nat, rest: List<&2, QN>) -> QNs:
  match room:
    case True{}:
      QQl{0n, 0n, Nil{}, nb, 1n+cb, QN{1n+c, Nat.add(sz, e)} <> rest}
    case False{}:
      qn.fix(1n, 1n, [qn.new(e)], nb, cb, QN{c, sz} <> rest)

def qn.pushl.b(+l: Nat, +e: Nat, +nb: Nat, +cb: Nat, b: List<&2, QN>) -> QNs:
  match b:
    case Con{QN{+c, +sz}, rest}:
      qn.pushl.one(qn.room(sz, l), e, c, sz, nb, cb, rest)
    case Nil{}:
      QQl{1n, 1n, [qn.new(e)], 0n, 0n, Nil{}}

def qn.pushl(+l: Nat, +e: Nat, +nf: Nat, +cf: Nat, f: List<&2, QN>, +nb: Nat, +cb: Nat, b: List<&2, QN>) -> QNs:
  match f:
    case Con{QN{+c, +sz}, rest}:
      qn.pushl.in(qn.room(sz, l), e, c, sz, rest, nf, cf, nb, cb, b)
    case Nil{}:
      qn.pushl.b(l, e, nb, cb, b)

# x put last, as qn.pushl puts it first (quicklistPushTail)
def qn.pushr.in(room: Bool, +e: Nat, +c: Nat, +sz: Nat, rest: List<&2, QN>, +nf: Nat, +cf: Nat, f: List<&2, QN>, +nb: Nat, +cb: Nat) -> QNs:
  match room:
    case True{}:
      QQl{nf, cf, f, nb, 1n+cb, QN{1n+c, Nat.add(sz, e)} <> rest}
    case False{}:
      qn.fix(nf, cf, f, 1n+nb, 1n+cb, qn.new(e) <> (QN{c, sz} <> rest))

def qn.pushr.one(room: Bool, +e: Nat, +c: Nat, +sz: Nat, +nf: Nat, +cf: Nat, rest: List<&2, QN>) -> QNs:
  match room:
    case True{}:
      QQl{nf, 1n+cf, QN{1n+c, Nat.add(sz, e)} <> rest, 0n, 0n, Nil{}}
    case False{}:
      qn.fix(nf, cf, QN{c, sz} <> rest, 1n, 1n, [qn.new(e)])

def qn.pushr.f(+l: Nat, +e: Nat, +nf: Nat, +cf: Nat, f: List<&2, QN>) -> QNs:
  match f:
    case Con{QN{+c, +sz}, rest}:
      qn.pushr.one(qn.room(sz, l), e, c, sz, nf, cf, rest)
    case Nil{}:
      QQl{0n, 0n, Nil{}, 1n, 1n, [qn.new(e)]}

def qn.pushr(+l: Nat, +e: Nat, +nf: Nat, +cf: Nat, f: List<&2, QN>, +nb: Nat, +cb: Nat, b: List<&2, QN>) -> QNs:
  match b:
    case Con{QN{+c, +sz}, rest}:
      qn.pushr.in(qn.room(sz, l), e, c, sz, rest, nf, cf, f, nb, cb)
    case Nil{}:
      qn.pushr.f(l, e, nf, cf, f)

def qn.push.of(+left: Bool, +l: Nat, +e: Nat, +nf: Nat, +cf: Nat, f: List<&2, QN>, +nb: Nat, +cb: Nat, b: List<&2, QN>) -> QNs:
  match left:
    case True{}:
      qn.pushl(l, e, nf, cf, f, nb, cb, b)
    case False{}:
      qn.pushr(l, e, nf, cf, f, nb, cb, b)

# a list after x (l bytes, an entry of e bytes) is pushed first (left) or
# last: a listpack e bytes longer, or a quicklist's nodes with x
def qn.push(+left: Bool, +l: Nat, +e: Nat, ns: QNs) -> QNs:
  match ns:
    case QLp{+lb}:
      QLp{Nat.add(lb, e)}
    case QQl{nf, cf, f, nb, cb, b}:
      qn.push.of(left, l, e, nf, cf, f, nb, cb, b)

# the elements xs pushed in turn
def qn.pushes(+left: Bool, xs: List<&2, String>, ns: QNs) -> QNs:
  match xs:
    case Nil{}:
      ns
    case Con{+x, rest}:
      qn.pushes(left, rest, qn.push(left, String.length(x), lpk.esize(x), ns))

# the first element (an entry of e bytes) popped: its node holds one
# fewer, or is gone with it (quicklistDelIndex)
def qn.popl.in(last: Bool, +e: Nat, +c: Nat, +sz: Nat, rest: List<&2, QN>, +nf: Nat, +cf: Nat, +nb: Nat, +cb: Nat, b: List<&2, QN>) -> QNs:
  match last:
    case True{}:
      qn.fix(Nat.sub(nf, 1n), Nat.sub(cf, 1n), rest, nb, cb, b)
    case False{}:
      QQl{nf, Nat.sub(cf, 1n), QN{Nat.sub(c, 1n), Nat.sub(sz, e)} <> rest, nb, cb, b}

def qn.popl.one(last: Bool, +e: Nat, +c: Nat, +sz: Nat, +nb: Nat, +cb: Nat, rest: List<&2, QN>) -> QNs:
  match last:
    case True{}:
      QQl{0n, 0n, Nil{}, Nat.sub(nb, 1n), Nat.sub(cb, 1n), rest}
    case False{}:
      QQl{0n, 0n, Nil{}, nb, Nat.sub(cb, 1n), QN{Nat.sub(c, 1n), Nat.sub(sz, e)} <> rest}

def qn.popl.b(+e: Nat, +nb: Nat, +cb: Nat, b: List<&2, QN>) -> QNs:
  match b:
    case Con{QN{+c, +sz}, rest}:
      qn.popl.one(Nat.is_eq(c, 1n), e, c, sz, nb, cb, rest)
    case Nil{}:
      QQl{0n, 0n, Nil{}, 0n, 0n, Nil{}}

def qn.popl(+e: Nat, +nf: Nat, +cf: Nat, f: List<&2, QN>, +nb: Nat, +cb: Nat, b: List<&2, QN>) -> QNs:
  match f:
    case Con{QN{+c, +sz}, rest}:
      qn.popl.in(Nat.is_eq(c, 1n), e, c, sz, rest, nf, cf, nb, cb, b)
    case Nil{}:
      qn.popl.b(e, nb, cb, b)

# the last element popped, as qn.popl pops the first
def qn.popr.in(last: Bool, +e: Nat, +c: Nat, +sz: Nat, rest: List<&2, QN>, +nf: Nat, +cf: Nat, f: List<&2, QN>, +nb: Nat, +cb: Nat) -> QNs:
  match last:
    case True{}:
      qn.fix(nf, cf, f, Nat.sub(nb, 1n), Nat.sub(cb, 1n), rest)
    case False{}:
      QQl{nf, cf, f, nb, Nat.sub(cb, 1n), QN{Nat.sub(c, 1n), Nat.sub(sz, e)} <> rest}

def qn.popr.one(last: Bool, +e: Nat, +c: Nat, +sz: Nat, +nf: Nat, +cf: Nat, rest: List<&2, QN>) -> QNs:
  match last:
    case True{}:
      QQl{Nat.sub(nf, 1n), Nat.sub(cf, 1n), rest, 0n, 0n, Nil{}}
    case False{}:
      QQl{nf, Nat.sub(cf, 1n), QN{Nat.sub(c, 1n), Nat.sub(sz, e)} <> rest, 0n, 0n, Nil{}}

def qn.popr.f(+e: Nat, +nf: Nat, +cf: Nat, f: List<&2, QN>) -> QNs:
  match f:
    case Con{QN{+c, +sz}, rest}:
      qn.popr.one(Nat.is_eq(c, 1n), e, c, sz, nf, cf, rest)
    case Nil{}:
      QQl{0n, 0n, Nil{}, 0n, 0n, Nil{}}

def qn.popr(+e: Nat, +nf: Nat, +cf: Nat, f: List<&2, QN>, +nb: Nat, +cb: Nat, b: List<&2, QN>) -> QNs:
  match b:
    case Con{QN{+c, +sz}, rest}:
      qn.popr.in(Nat.is_eq(c, 1n), e, c, sz, rest, nf, cf, f, nb, cb)
    case Nil{}:
      qn.popr.f(e, nf, cf, f)

def qn.pop.of(+left: Bool, +e: Nat, +nf: Nat, +cf: Nat, f: List<&2, QN>, +nb: Nat, +cb: Nat, b: List<&2, QN>) -> QNs:
  match left:
    case True{}:
      qn.popl(e, nf, cf, f, nb, cb, b)
    case False{}:
      qn.popr(e, nf, cf, f, nb, cb, b)

# LSET: the node of the element at index j of the nodes ns (from the
# first: on) with its bytes eo fewer and ev more
def qn.set.go(ns: List<&2, QN>, on: Bool, +j: Nat, +eo: Nat, +ev: Nat) -> List<&2, QN>:
  match ns on:
    case Con{QN{+c, +sz}, rest} True{}:
      +here = Nat.is_lt(j, c)
      QN{c, Bool.pick(Nat, here, Nat.sub(Nat.add(sz, ev), eo), sz)} <> qn.set.go(rest, Bool.not(here), Nat.sub(j, c), eo, ev)
    case ms _:
      ms

def qn.set.of(front: Bool, +i: Nat, +eo: Nat, +ev: Nat, +nf: Nat, +cf: Nat, f: List<&2, QN>, +nb: Nat, +cb: Nat, b: List<&2, QN>) -> QNs:
  match front:
    case True{}:
      QQl{nf, cf, qn.set.go(f, True{}, i, eo, ev), nb, cb, b}
    case False{}:
      QQl{nf, cf, f, nb, cb, qn.set.go(b, True{}, Nat.sub(Nat.sub(Nat.add(cf, cb), 1n), i), eo, ev)}

# a list after LSET writes an element of an entry of ev bytes for one of
# eo at index i (quicklistReplaceEntry), from the nearer stack
def qn.set(+i: Nat, +eo: Nat, +ev: Nat, ns: QNs) -> QNs:
  match ns:
    case QLp{+lb}:
      QLp{Nat.sub(Nat.add(lb, ev), eo)}
    case QQl{+nf, +cf, f, +nb, +cb, b}:
      qn.set.of(Nat.is_lt(i, cf), i, eo, ev, nf, cf, f, nb, cb, b)

# the node m, when there is one, before ns
def qn.cons(m: Maybe<&2, QN>, ns: List<&2, QN>) -> List<&2, QN>:
  match m:
    case Some{x}:
      x <> ns
    case None{}:
      ns

# LTRIM: the nodes ns (from the first: on) without the whole ones among
# their first k elements: how many elements those held (after a), and the
# nodes left, the first of them m when the walk stopped at it
def qn.skip(ns: List<&2, QN>, on: Bool, +k: Nat, +a: Nat, m: Maybe<&2, QN>) -> Nat & List<&2, QN>:
  match ns on:
    case Con{QN{+c, +sz}, rest} True{}:
      +whole = Nat.is_le(c, k)
      qn.skip(rest, whole, Nat.sub(k, Bool.pick(Nat, whole, c, 0n)), Bool.pick(Nat, whole, Nat.add(a, c), a), Bool.pick(Maybe<&2, QN>, whole, None{}, Some{QN{c, sz}}))
    case ms _:
      (a, qn.cons(m, ms))

# the first node of ns without r of its elements, of w bytes
def qn.less(ns: List<&2, QN>, +r: Nat, +w: Nat) -> List<&2, QN>:
  match ns:
    case Con{QN{+c, +sz}, rest}:
      QN{Nat.sub(c, r), Nat.sub(sz, w)} <> rest
    case Nil{}:
      Nil{}

def qn.dropl.of(+k: Nat, +q: DQ, p: Nat & List<&2, QN>) -> QNs:
  (+s, ms) = p
  +r = Nat.sub(k, s)
  qn.of(qn.less(ms, r, lpk.span(r, s, q)))

# a list without its first k elements, of q (quicklistDelRange): the
# nodes they fill gone, and the next without those it holds
def qn.dropl(+k: Nat, +q: DQ, ns: QNs) -> QNs:
  match ns:
    case QLp{+lb}:
      QLp{Nat.sub(lb, lpk.ends(False{}, k, q))}
    case QQl{nf, cf, f, nb, cb, b}:
      qn.dropl.of(k, q, qn.skip(qn.list(f, b), True{}, k, 0n, None{}))

def qn.dropr.of(+k: Nat, +q: DQ, p: Nat & List<&2, QN>) -> QNs:
  (+s, ms) = p
  +r = Nat.sub(k, s)
  qn.of(List.reverse(&2, QN, qn.less(ms, r, lpk.span(r, Nat.sub(dq.len(q), k), q))))

# a list without its last k elements, as qn.dropl takes the first
def qn.dropr(+k: Nat, +q: DQ, ns: QNs) -> QNs:
  match ns:
    case QLp{+lb}:
      QLp{Nat.sub(lb, lpk.ends(True{}, k, q))}
    case QQl{nf, cf, f, nb, cb, b}:
      qn.dropr.of(k, q, qn.skip(List.append(&2, QN, b, List.reverse(&2, QN, f)), True{}, k, 0n, None{}))

# LREM: how many of the positions ps (in increasing order, from the first:
# on) are below e, after a
def qn.below(ps: List<&2, Nat>, on: Bool, +e: Nat, +a: Nat) -> Nat:
  match ps on:
    case Con{+p, rest} True{}:
      +lt = Nat.is_lt(p, e)
      qn.below(rest, lt, e, Bool.pick(Nat, lt, 1n+a, a))
    case _ _:
      a

def qn.rem.put(gone: Bool, x: QN, rest: List<&2, QN>) -> List<&2, QN>:
  match gone:
    case True{}:
      rest
    case False{}:
      x <> rest

# the nodes ns, the first from index a on, without the elements at the
# positions ps (in increasing order), each an entry of e bytes
# (quicklistDelEntry)
def qn.rem.go(ns: List<&2, QN>, +a: Nat, +ps: List<&2, Nat>, +e: Nat) -> List<&2, QN>:
  match ns:
    case Nil{}:
      Nil{}
    case Con{QN{+c, +sz}, rest}:
      +end = Nat.add(a, c)
      +k = qn.below(ps, True{}, end, 0n)
      qn.rem.put(Nat.is_eq(k, c), QN{Nat.sub(c, k), Nat.sub(sz, Nat.mul(k, e))}, qn.rem.go(rest, end, List.drop(&2, Nat, ps, k), e))

def qn.inc(back: Bool, ps: List<&2, Nat>) -> List<&2, Nat>:
  match back:
    case True{}:
      ps
    case False{}:
      List.reverse(&2, Nat, ps)

# the positions in q of the gone elements that are x, from its first
# element or its last (back), in increasing order
def qn.rem.ps(gone: Nat, +x: String, +back: Bool, +q: DQ) -> List<&2, Nat>:
  match gone:
    case 0n:
      Nil{}
    case 1n+j:
      qn.inc(back, dq.find(x, back, 1n+j, dq.len(q), q))

# a list of q after LREM takes gone elements that are x, from the first
# element or the last (back)
def qn.rem(+x: String, +gone: Nat, +back: Bool, +q: DQ, ns: QNs) -> QNs:
  match ns:
    case QLp{+lb}:
      QLp{Nat.sub(lb, Nat.mul(gone, lpk.esize(x)))}
    case QQl{nf, cf, f, nb, cb, b}:
      qn.of(qn.rem.go(qn.list(f, b), 0n, qn.rem.ps(gone, x, back, q), lpk.esize(x)))

# LINSERT: a node and where it is: the nodes before it, the nearest first
# (pre), the offset in it of the element sought (o), and the nodes from it
# on (ns)
type QAt is Data:
  QAt{pre: List<&2, QN>, o: Nat, ns: List<&2, QN>}

# the node of the nodes ns (from the first: on) that holds the element at
# index i of their order, the nodes before it put before pre (m: the node
# the walk stopped at)
def qn.at(ns: List<&2, QN>, on: Bool, +i: Nat, +pre: List<&2, QN>, m: Maybe<&2, QN>) -> QAt:
  match ns on:
    case Con{QN{+c, +sz}, rest} True{}:
      +past = Nat.is_le(c, i)
      qn.at(rest, past, Bool.pick(Nat, past, Nat.sub(i, c), i), Bool.pick(List<&2, QN>, past, QN{c, sz} <> pre, pre), Bool.pick(Maybe<&2, QN>, past, None{}, Some{QN{c, sz}}))
    case ms _:
      QAt{pre, i, qn.cons(m, ms)}

# whether the first node of ns takes an element of l bytes
def qn.room1(ns: List<&2, QN>, +l: Nat) -> Bool:
  match ns:
    case Con{QN{c, +sz}, rest}:
      qn.room(sz, l)
    case Nil{}:
      False{}

# the first node of ns with an element more, an entry of e bytes
def qn.bump(ns: List<&2, QN>, +e: Nat) -> List<&2, QN>:
  match ns:
    case Con{QN{+c, +sz}, rest}:
      QN{1n+c, Nat.add(sz, e)} <> rest
    case Nil{}:
      Nil{}

def qn.join2.if(ok: Bool, a: QN, b: QN, rest: List<&2, QN>) -> List<&2, QN>:
  match ok:
    case True{}:
      qn.join(a, b) <> rest
    case False{}:
      a <> (b <> rest)

# ns with its first two nodes merged when they fit together
def qn.join2(ns: List<&2, QN>) -> List<&2, QN>:
  match ns:
    case Con{QN{+ac, +asz}, Con{QN{+bc, +bsz}, rest}}:
      qn.join2.if(qn.joins(asz, bsz), QN{ac, asz}, QN{bc, bsz}, rest)
    case ms:
      ms

# a node t and the nodes on one side of it, the nearest first
type QMid is Data:
  QMid{t: QN, ns: List<&2, QN>}

def qn.mid.if(ok: Bool, t: QN, x: QN, rest: List<&2, QN>) -> QMid:
  match ok:
    case True{}:
      QMid{qn.join(x, t), rest}
    case False{}:
      QMid{t, x <> rest}

# the node of tc elements in tsz bytes merged with the nearest of ns when
# they fit together
def qn.mid(+tc: Nat, +tsz: Nat, ns: List<&2, QN>) -> QMid:
  match ns:
    case Con{QN{+c, +sz}, rest}:
      qn.mid.if(qn.joins(tsz, sz), QN{tc, tsz}, QN{c, sz}, rest)
    case Nil{}:
      QMid{QN{tc, tsz}, Nil{}}

def qn.merge.end(pre: List<&2, QN>, m: QMid) -> List<&2, QN>:
  match m:
    case QMid{t, post}:
      List.reverse.go(&2, QN, pre, t <> post)

def qn.merge.next(m: QMid, post: List<&2, QN>) -> List<&2, QN>:
  match m:
    case QMid{QN{+tc, +tsz}, pre}:
      qn.merge.end(pre, qn.mid(tc, tsz, post))

# the nodes in order once the node t, between pre (the nearest first) and
# post, has merged with those around it (_quicklistMergeNodes): the two
# before it when they fit together, the two after it, then t with the one
# before, then what that made with the one after
def qn.merge(pre: List<&2, QN>, t: QN, post: List<&2, QN>) -> List<&2, QN>:
  match t:
    case QN{+tc, +tsz}:
      qn.merge.next(qn.mid(tc, tsz, qn.join2(pre)), qn.join2(post))

def qn.ins.own(after: Bool, +e: Nat, +c: Nat, +sz: Nat, pre: List<&2, QN>, post: List<&2, QN>) -> List<&2, QN>:
  match after:
    case True{}:
      List.reverse.go(&2, QN, pre, QN{c, sz} <> (qn.new(e) <> post))
    case False{}:
      List.reverse.go(&2, QN, pre, qn.new(e) <> (QN{c, sz} <> post))

# the bytes of the elements a split moves to the new node: those after
# offset o (after), else those before it, of the node of c elements from
# index s of q on
def qn.moved(after: Bool, +o: Nat, +c: Nat, +s: Nat, +q: DQ) -> Nat:
  match after:
    case True{}:
      lpk.span(Nat.sub(Nat.sub(c, o), 1n), Nat.add(Nat.add(s, o), 1n), q)
    case False{}:
      lpk.span(o, s, q)

# the node split at offset o (_quicklistSplitNode): after, it keeps its
# first o + 1 elements, and a node after it takes the others and the
# element first; before, it keeps those from o on, and a node before it
# takes the first o and the element last; then the node merges with
# those around it
def qn.ins.cut(after: Bool, +e: Nat, +o: Nat, +c: Nat, +sz: Nat, +m: Nat, pre: List<&2, QN>, post: List<&2, QN>) -> List<&2, QN>:
  match after:
    case True{}:
      qn.merge(pre, QN{1n+o, Nat.sub(sz, m)}, QN{Nat.sub(c, o), Nat.add(Nat.add(lpk.empty(), m), e)} <> post)
    case False{}:
      qn.merge(QN{1n+o, Nat.add(Nat.add(lpk.empty(), m), e)} <> pre, QN{Nat.sub(c, o), Nat.sub(sz, m)}, post)

# the element (an entry of e bytes) put after (or before) the element at
# offset o of the node of c elements in sz bytes, from index s of q on,
# between pre (the nearest first) and post, the way k says (qn.ins.way)
def qn.ins.do(k: Nat, +after: Bool, +e: Nat, +o: Nat, +c: Nat, +sz: Nat, +s: Nat, +q: DQ, pre: List<&2, QN>, post: List<&2, QN>) -> List<&2, QN>:
  match k:
    case 0n:
      List.reverse.go(&2, QN, pre, QN{1n+c, Nat.add(sz, e)} <> post)
    case 1n:
      List.reverse.go(&2, QN, pre, QN{c, sz} <> qn.bump(post, e))
    case 2n:
      List.reverse.go(&2, QN, qn.bump(pre, e), QN{c, sz} <> post)
    case 3n:
      qn.ins.own(after, e, c, sz, pre, post)
    case _:
      qn.ins.cut(after, e, o, c, sz, qn.moved(after, o, c, s, q), pre, post)

# the way LINSERT goes (_quicklistInsert): 0 into the node, when it has
# room; else, at its end (after its last element, or before its first),
# 1 into the next node or 2 into the one before, when that has room, or 3
# into a node of its own; else 4, the node split
def qn.ins.way(room: Bool, +tail: Bool, +head: Bool, next: Bool, prev: Bool) -> Nat:
  Bool.pick(Nat, room, 0n, Bool.pick(Nat, Bool.and(tail, next), 1n, Bool.pick(Nat, Bool.and(head, prev), 2n, Bool.pick(Nat, Bool.or(tail, head), 3n, 4n))))

def qn.ins.in(+after: Bool, +l: Nat, +e: Nat, +o: Nat, +s: Nat, +q: DQ, +pre: List<&2, QN>, ns: List<&2, QN>) -> List<&2, QN>:
  match ns:
    case Con{QN{+c, +sz}, +post}:
      qn.ins.do(qn.ins.way(qn.room(sz, l), Bool.and(after, Nat.is_eq(o, Nat.sub(c, 1n))), Bool.and(Bool.not(after), Nat.is_eq(o, 0n)), qn.room1(post, l), qn.room1(pre, l)), after, e, o, c, sz, s, q, pre, post)
    case Nil{}:
      List.reverse(&2, QN, pre)

def qn.ins.at(+after: Bool, +l: Nat, +e: Nat, +i: Nat, +q: DQ, at: QAt) -> List<&2, QN>:
  match at:
    case QAt{pre, +o, ns}:
      qn.ins.in(after, l, e, o, Nat.sub(i, o), q, pre, ns)

# a list of q after LINSERT puts an element of l bytes (an entry of e
# bytes) after (or before) its element at index i
def qn.ins(+i: Nat, +after: Bool, +l: Nat, +e: Nat, +q: DQ, ns: QNs) -> QNs:
  match ns:
    case QLp{+lb}:
      QLp{Nat.add(lb, e)}
    case QQl{nf, cf, f, nb, cb, b}:
      qn.of(qn.ins.at(after, l, e, i, q, qn.at(qn.list(f, b), True{}, i, Nil{}, None{})))

# A list read: the nodes RPUSH makes of the elements xs, the last first,
# after the node of c elements in sz bytes that it fills and the nodes acc
# before it
def qn.part.end(c: Nat, +sz: Nat, acc: List<&2, QN>) -> List<&2, QN>:
  match c:
    case 0n:
      acc
    case 1n+k:
      QN{1n+k, sz} <> acc

def qn.part(xs: List<&2, String>, +c: Nat, +sz: Nat, +acc: List<&2, QN>) -> List<&2, QN>:
  match xs:
    case Nil{}:
      qn.part.end(c, sz, acc)
    case Con{+x, rest}:
      +room = Bool.or(Nat.is_eq(c, 0n), qn.room(sz, String.length(x)))
      +e = lpk.esize(x)
      qn.part(rest, Bool.pick(Nat, room, 1n+c, 1n), Bool.pick(Nat, room, Nat.add(sz, e), Nat.add(lpk.empty(), e)), Bool.pick(List<&2, QN>, room, acc, QN{c, sz} <> acc))

# the elements xs cut into the nodes ns, in order, after acc (the last
# node first)
def qn.parts(ns: List<&2, QN>, +xs: List<&2, String>, acc: List<&2, List<&2, String>>) -> List<&2, List<&2, String>>:
  match ns:
    case Nil{}:
      List.reverse(&2, List<&2, String>, acc)
    case Con{QN{+c, sz}, rest}:
      qn.parts(rest, List.drop(&2, String, xs, c), List.take(&2, String, xs, c) <> acc)

# Lists
def deq.empty() -> Deq:
  Deq{dq.empty(), QLp{lpk.empty()}}

def deq.len(+d: Deq) -> Nat:
  match d:
    case Deq{+q, ns}:
      dq.len(q)

# whether Redis 7.2 holds the list as a quicklist (OBJECT ENCODING)
def deq.qk(+d: Deq) -> Bool:
  match d:
    case Deq{q, +ns}:
      qn.ql(ns)

# x put first (left) or last, a listpack that x would take past 8 KB
# first made a quicklist
def deq.push(+left: Bool, +x: String, d: Deq) -> Deq:
  match d:
    case Deq{+q, ns}:
      Deq{dq.push(left, x, q), qn.push(left, String.length(x), lpk.esize(x), qn.grow(dq.len(q), String.length(x), ns))}

# the elements xs pushed in turn, each first (left) or last, a listpack
# that they would take past 8 KB first made a quicklist
def deq.pushes.n(+left: Bool, +xs: List<&2, String>, d: Deq) -> Deq:
  match d:
    case Deq{+q, ns}:
      Deq{dq.pushes.n(left, xs, q), qn.pushes(left, xs, qn.grow(dq.len(q), lpk.raw(xs, 0n), ns))}

# the elements xs pushed in turn: one alone as deq.push puts it, more
# together
def deq.pushes(+left: Bool, xs: List<&2, String>, d: Deq) -> Deq:
  match xs:
    case Con{x, Nil{}}:
      deq.push(left, x, d)
    case ys:
      deq.pushes.n(left, ys, d)

# a list's first (or last) element and the list without it, a quicklist
# of one node of 4 KB at most made a listpack (listElementsRemoved); none
# for an empty list
type Pop is Data:
  Pop{x: String, d: Deq}
  PopNone{}

def deq.popped.of(+left: Bool, +x: String, q: DQ, ns: QNs) -> Pop:
  match ns:
    case QLp{+lb}:
      Pop{x, Deq{q, QLp{Nat.sub(lb, lpk.esize(x))}}}
    case QQl{nf, cf, f, nb, cb, b}:
      Pop{x, Deq{q, qn.fit(lpk.half(), qn.pop.of(left, lpk.esize(x), nf, cf, f, nb, cb, b))}}

def deq.popped(p: DPop, +left: Bool, ns: QNs) -> Pop:
  match p:
    case DPop{+x, q}:
      deq.popped.of(left, x, q, ns)
    case DPopNone{}:
      PopNone{}

def deq.pop(+left: Bool, d: Deq) -> Pop:
  match d:
    case Deq{q, ns}:
      deq.popped(dq.pop(left, q), left, ns)

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

# up to c more elements popped from the first end (left) or the last: a
# quicklist made a listpack after one of them is one after the others too,
# as Redis checks once after them all
def deq.pops(c: Nat, +left: Bool, st: Pops) -> Pops:
  match c:
    case 0n:
      st
    case 1n+k:
      deq.pops(k, left, deq.pop.step(left, st))

# the elements, in order
def deq.all(+d: Deq) -> List<&2, String>:
  match d:
    case Deq{+q, ns}:
      dq.all(q)

def deq.get(+i: Nat, +d: Deq) -> Maybe<&2, String>:
  match d:
    case Deq{+q, ns}:
      dq.get(i, q)

def deq.range(+s: Nat, +e: Nat, +d: Deq) -> List<&2, String>:
  match d:
    case Deq{+q, ns}:
      dq.range(s, e, q)

def deq.find(+x: String, +back: Bool, +w: Nat, +l: Nat, +d: Deq) -> List<&2, Nat>:
  match d:
    case Deq{+q, ns}:
      dq.find(x, back, w, l, q)

# LSET of index i (one the list has) to v: a listpack made a quicklist
# first when v's length would take it past 8 KB (lsetCommand), v written
# in its node, then a quicklist of one node of 4 KB at most made a
# listpack
def deq.set(+i: Nat, +v: String, d: Deq) -> Deq:
  match d:
    case Deq{+q, ns}:
      Deq{dq.set(i, v, q), qn.fit(lpk.half(), qn.set(i, lpk.esize(Maybe.default(&2, String, dq.get(i, q), "")), lpk.esize(v), qn.grow(dq.len(q), String.length(v), ns)))}

# LTRIM's drops: the first k elements, or the last, a quicklist of one
# node of 4 KB at most then made a listpack (as after the pops, once is as
# Redis's once after both)
def deq.dropl(+k: Nat, d: Deq) -> Deq:
  match d:
    case Deq{+q, ns}:
      Deq{dq.dropl(k, q), qn.fit(lpk.half(), qn.dropl(k, q, ns))}

def deq.dropr(+k: Nat, d: Deq) -> Deq:
  match d:
    case Deq{+q, ns}:
      Deq{dq.dropr(k, q), qn.fit(lpk.half(), qn.dropr(k, q, ns))}

def deq.ins.of(ps: List<&2, Nat>, +after: Bool, +v: String, +q: DQ, ns: QNs) -> Maybe<&2, Deq>:
  match ps:
    case Con{+i, rest}:
      +l = String.length(v)
      Some{Deq{dq.ins.at(i, after, v, q), qn.ins(i, after, l, lpk.esize(v), q, qn.grow(dq.len(q), l, ns))}}
    case Nil{}:
      None{}

# LINSERT of v after (or before) the first element that is p, when one
# is there: a listpack made a quicklist first when v's length would take
# it past 8 KB
def deq.ins(+p: String, +after: Bool, +v: String, d: Deq) -> Maybe<&2, Deq>:
  match d:
    case Deq{+q, ns}:
      deq.ins.of(dq.find(p, False{}, 1n, 1n+dq.len(q), q), after, v, q, ns)

# a list after LREM, and how many elements it took
type Rem is Data:
  Rem{d: Deq, gone: Nat}

def deq.removed(r: DRem, +x: String, +back: Bool, +q: DQ, ns: QNs) -> Rem:
  match r:
    case DRem{q2, +gone}:
      Rem{Deq{q2, qn.fit(lpk.half(), qn.rem(x, gone, back, q, ns))}, gone}

# LREM: the list without its first w elements that are x (all of them
# for w 0), from its first element or its last (back), then shrunk
def deq.rem(+x: String, +w: Nat, +back: Bool, d: Deq) -> Rem:
  match d:
    case Deq{+q, ns}:
      deq.removed(dq.rem(x, w, back, q), x, back, q, ns)

def deq.auto(d: Deq) -> Deq:
  match d:
    case Deq{q, ns}:
      Deq{q, qn.fit(lpk.lim(), ns)}

# the list of the n elements xs as RPUSH makes a quicklist of them (a
# ziplist's, ZIPLIST, as rdbLoadObject reads one: a quicklist whatever
# its size)
def deq.zl(+n: Nat, +xs: List<&2, String>) -> Deq:
  Deq{dq.of(n, xs), qn.of(List.reverse(&2, QN, qn.part(xs, 0n, lpk.empty(), Nil{})))}

# the list of the n elements xs pushed into a quicklist, then made a
# listpack when it is one node of 8 KB at most (LIST, as rdbLoadObject
# reads one: LIST_CONV_AUTO)
def deq.of(+n: Nat, +xs: List<&2, String>) -> Deq:
  deq.auto(deq.zl(n, xs))

# the list of the n elements xs in the nodes ns, in order (QUICKLIST and
# QUICKLIST_2, as rdbLoadObject reads them), made a listpack when it is
# one node of 8 KB at most
def deq.nodes(+n: Nat, +xs: List<&2, String>, ns: List<&2, QN>) -> Deq:
  deq.auto(Deq{dq.of(n, xs), qn.of(ns)})

def deq.parts.of(ns: QNs, xs: List<&2, String>) -> List<&2, List<&2, String>>:
  match ns:
    case QLp{lb}:
      [xs]
    case QQl{nf, cf, f, nb, cb, b}:
      qn.parts(qn.list(f, b), xs, Nil{})

# the elements of each node, in order: a listpack's all in one, as
# rdbSaveObject writes a listpack (a quicklist of one node)
def deq.parts(+d: Deq) -> List<&2, List<&2, String>>:
  match d:
    case Deq{+q, ns}:
      deq.parts.of(ns, dq.all(q))

def deq.bytes(+d: Deq) -> Nat:
  match d:
    case Deq{+q, ns}:
      dq.bytes(q)

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
# (d, m) compares with t's root. A side is compared with (d, m) before it
# goes down (+cl, +cr): read after it was given to the insertion, it would be
# shared while the insertion runs, which would copy each node it passes,
# and a tree the insertion owns alone (a sorted set taken out of the
# keyspace, R.upd.takes) is changed in place.
def zt.ins(t: ZTree, c: Cmp, +m: String, +d: F.F64) -> ZTree:
  match t c:
    case ZTip{} _:
      ZBin{1n, m, d, ZTip{}, ZTip{}}
    case ZBin{n, +k, +e, +l, r} LT{}:
      +cl = zt.at(l, d, m)
      zt.balance(k, e, zt.ins(l, cl, m, d), r)
    case ZBin{n, +k, +e, l, +r} _:
      +cr = zt.at(r, d, m)
      zt.balance(k, e, l, zt.ins(r, cr, m, d))

def zt.add(+t: ZTree, +m: String, +d: F.F64) -> ZTree:
  zt.ins(t, zt.at(t, d, m), m, d)

# zt.add of a tree given to it: its root is compared where it is matched,
# so that a tree held once is changed in place
def zt.add.own(t: ZTree, +m: String, +d: F.F64) -> ZTree:
  match t:
    case ZTip{}:
      ZBin{1n, m, d, ZTip{}, ZTip{}}
    case ZBin{+n, +k, +e, l, r}:
      +c = zel.cmp(d, m, e, k)
      zt.ins(ZBin{n, k, e, l, r}, c, m, d)

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
# with t's root (a side is compared before it goes down, as in zt.ins)
def zt.rm(t: ZTree, c: Cmp, +m: String, +d: F.F64) -> ZTree:
  match t c:
    case ZTip{} _:
      ZTip{}
    case ZBin{n, +k, +e, +l, r} LT{}:
      +cl = zt.at(l, d, m)
      zt.balance(k, e, zt.rm(l, cl, m, d), r)
    case ZBin{n, +k, +e, l, +r} GT{}:
      +cr = zt.at(r, d, m)
      zt.balance(k, e, l, zt.rm(r, cr, m, d))
    case ZBin{n, k, e, l, r} EQ{}:
      zt.glue(l, r)

def zt.del(+t: ZTree, +m: String, +d: F.F64) -> ZTree:
  zt.rm(t, zt.at(t, d, m), m, d)

# zt.del of a tree given to it, as zt.add.own
def zt.del.own(t: ZTree, +m: String, +d: F.F64) -> ZTree:
  match t:
    case ZTip{}:
      ZTip{}
    case ZBin{+n, +k, +e, l, r}:
      +c = zel.cmp(d, m, e, k)
      zt.rm(ZBin{n, k, e, l, r}, c, m, d)

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
def zset.big.of(+tr: ZTree, +m: String, +d: F.F64) -> Zset:
  ZBig{zt.add(tr, m, d), set(F.F64, zt.trie(tr, empty(F.F64)), m, d)}

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

def zset.add.wide(fits: Bool, tr: ZTree, +m: String, +d: F.F64) -> Zset:
  match fits:
    case True{}:
      ZWide{zt.add.own(tr, m, zset.norm(d))}
    case False{}:
      zset.big.of(tr, m, d)

def zset.add(z: Zset, +m: String, +d: F.F64) -> Zset:
  match z:
    case ZSmall{+n, +b}:
      zset.add.small(Bool.and(Nat.is_lt(n, 128n), Nat.is_le(String.length(m), 64n)), n, b, m, d)
    case ZWide{+tr}:
      zset.add.wide(Bool.and(Nat.is_lt(zt.size(tr), 128n), Nat.is_le(String.length(m), 64n)), tr, m, d)
    case ZBig{tr, t}:
      ZBig{zt.add.own(tr, m, d), set(F.F64, t, m, d)}

# z without m, which it holds with score d
def zset.del(z: Zset, +m: String, +d: F.F64) -> Zset:
  match z:
    case ZSmall{+n, +b}:
      ZSmall{Nat.sub(n, 1n), zb.del(b, zb.find(m, b, n))}
    case ZWide{tr}:
      ZWide{zt.del.own(tr, m, d)}
    case ZBig{tr, t}:
      ZBig{zt.del.own(tr, m, d), del(F.F64, t, m)}

# z without m, which it holds with score d, its element at index i of a
# small one's string (zset.find)
def zset.del.at(z: Zset, +i: Nat, +m: String, +d: F.F64) -> Zset:
  match z:
    case ZSmall{+n, +b}:
      ZSmall{Nat.sub(n, 1n), pk.cut(b, i, zb.next(b, i))}
    case ZWide{tr}:
      ZWide{zt.del.own(tr, m, d)}
    case ZBig{tr, t}:
      ZBig{zt.del.own(tr, m, d), del(F.F64, t, m)}

# z with m's score, old, set to d, m's element at index i of a small
# one's string (zset.find)
def zset.set(z: Zset, +i: Nat, +m: String, +old: F.F64, +d: F.F64) -> Zset:
  match z:
    case ZSmall{+n, +b}:
      ZSmall{n, zb.set(b, n, i, m, zset.norm(d))}
    case ZWide{tr}:
      ZWide{zt.add.own(zt.del.own(tr, m, old), m, zset.norm(d))}
    case ZBig{tr, t}:
      ZBig{zt.add.own(zt.del.own(tr, m, old), m, d), set(F.F64, t, m, d)}

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
    case XCon{+name, seen, active, ids}:
      name

def xgroup.name(+x: XGroup) -> String:
  match x:
    case XGrp{+name, last, read, pel, cons}:
      name
    case XGrpOf{+y}:
      xgroup.name(y)

# The trees of a stream: weight-balanced, as a large sorted set's (ZTree,
# Sorted sets, above), one shape for each kind of element and its key
# (written by tools/gen_streams.py)
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

# a node's element cut from the end of a tree, and the tree left
type XNCut is Data:
  XNCut{x: XNode, t: XNodes}

def xns.cutl.fix(c: XNCut, +x: XNode, r: XNodes) -> XNCut:
  match c:
    case XNCut{+cx, +ct}:
      XNCut{cx, xns.balance(x, ct, r)}

# the first element of the node of x between l and r, cut from it
def xns.cutl(l: XNodes, +x: XNode, r: XNodes) -> XNCut:
  match l:
    case XNTip{}:
      XNCut{x, r}
    case XNBin{n, +lx, ll, lr}:
      xns.cutl.fix(xns.cutl(ll, lx, lr), x, r)

def xns.cutr.fix(c: XNCut, +x: XNode, l: XNodes) -> XNCut:
  match c:
    case XNCut{+cx, +ct}:
      XNCut{cx, xns.balance(x, l, ct)}

# the last element of the node of x between l and r, cut from it
def xns.cutr(r: XNodes, +x: XNode, l: XNodes) -> XNCut:
  match r:
    case XNTip{}:
      XNCut{x, l}
    case XNBin{n, +rx, rl, rr}:
      xns.cutr.fix(xns.cutr(rr, rx, rl), x, l)

def xns.glue.lfix(c: XNCut, r: XNodes) -> XNodes:
  match c:
    case XNCut{+x, +l}:
      xns.balance(x, l, r)

def xns.glue.rfix(l: XNodes, c: XNCut) -> XNodes:
  match c:
    case XNCut{+x, +r}:
      xns.balance(x, l, r)

# the larger side l's last element takes the place of the one taken out
def xns.glue.l(l: XNodes, r: XNodes) -> XNodes:
  match l:
    case XNTip{}:
      r
    case XNBin{n, +lx, ll, lr}:
      xns.glue.lfix(xns.cutr(lr, lx, ll), r)

# or r's first element (r a tip: both sides are)
def xns.glue.r(l: XNodes, r: XNodes) -> XNodes:
  match r:
    case XNTip{}:
      l
    case XNBin{n, +rx, rl, rr}:
      xns.glue.rfix(l, xns.cutl(rl, rx, rr))

def xns.glue.of(lbig: Bool, l: XNodes, r: XNodes) -> XNodes:
  match lbig:
    case True{}:
      xns.glue.l(l, r)
    case False{}:
      xns.glue.r(l, r)

# the elements of l and then those of r, the sides of a node whose
# element is taken out
def xns.glue(+l: XNodes, +r: XNodes) -> XNodes:
  xns.glue.of(Nat.is_lt(xns.size(r), xns.size(l)), l, r)

# t without the element of key k (t as it was when it holds none); c is
# how k compares with t's root's
def xns.rm(t: XNodes, c: Cmp, +k: XId) -> XNodes:
  match t c:
    case XNTip{} _:
      XNTip{}
    case XNBin{n, +y, +l, +r} LT{}:
      xns.balance(y, xns.rm(l, xns.at(l, k), k), r)
    case XNBin{n, +y, +l, +r} GT{}:
      xns.balance(y, l, xns.rm(r, xns.at(r, k), k))
    case XNBin{n, y, +l, +r} EQ{}:
      xns.glue(l, r)

def xns.del(+k: XId, +t: XNodes) -> XNodes:
  xns.rm(t, xns.at(t, k), k)

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

# a node's element cut from the end of a tree, and the tree left
type XPCut is Data:
  XPCut{x: XNack, t: XPel}

def xpl.cutl.fix(c: XPCut, +x: XNack, r: XPel) -> XPCut:
  match c:
    case XPCut{+cx, +ct}:
      XPCut{cx, xpl.balance(x, ct, r)}

# the first element of the node of x between l and r, cut from it
def xpl.cutl(l: XPel, +x: XNack, r: XPel) -> XPCut:
  match l:
    case XPTip{}:
      XPCut{x, r}
    case XPBin{n, +lx, ll, lr}:
      xpl.cutl.fix(xpl.cutl(ll, lx, lr), x, r)

def xpl.cutr.fix(c: XPCut, +x: XNack, l: XPel) -> XPCut:
  match c:
    case XPCut{+cx, +ct}:
      XPCut{cx, xpl.balance(x, l, ct)}

# the last element of the node of x between l and r, cut from it
def xpl.cutr(r: XPel, +x: XNack, l: XPel) -> XPCut:
  match r:
    case XPTip{}:
      XPCut{x, l}
    case XPBin{n, +rx, rl, rr}:
      xpl.cutr.fix(xpl.cutr(rr, rx, rl), x, l)

def xpl.glue.lfix(c: XPCut, r: XPel) -> XPel:
  match c:
    case XPCut{+x, +l}:
      xpl.balance(x, l, r)

def xpl.glue.rfix(l: XPel, c: XPCut) -> XPel:
  match c:
    case XPCut{+x, +r}:
      xpl.balance(x, l, r)

# the larger side l's last element takes the place of the one taken out
def xpl.glue.l(l: XPel, r: XPel) -> XPel:
  match l:
    case XPTip{}:
      r
    case XPBin{n, +lx, ll, lr}:
      xpl.glue.lfix(xpl.cutr(lr, lx, ll), r)

# or r's first element (r a tip: both sides are)
def xpl.glue.r(l: XPel, r: XPel) -> XPel:
  match r:
    case XPTip{}:
      l
    case XPBin{n, +rx, rl, rr}:
      xpl.glue.rfix(l, xpl.cutl(rl, rx, rr))

def xpl.glue.of(lbig: Bool, l: XPel, r: XPel) -> XPel:
  match lbig:
    case True{}:
      xpl.glue.l(l, r)
    case False{}:
      xpl.glue.r(l, r)

# the elements of l and then those of r, the sides of a node whose
# element is taken out
def xpl.glue(+l: XPel, +r: XPel) -> XPel:
  xpl.glue.of(Nat.is_lt(xpl.size(r), xpl.size(l)), l, r)

# t without the element of key k (t as it was when it holds none); c is
# how k compares with t's root's
def xpl.rm(t: XPel, c: Cmp, +k: XId) -> XPel:
  match t c:
    case XPTip{} _:
      XPTip{}
    case XPBin{n, +y, +l, +r} LT{}:
      xpl.balance(y, xpl.rm(l, xpl.at(l, k), k), r)
    case XPBin{n, +y, +l, +r} GT{}:
      xpl.balance(y, l, xpl.rm(r, xpl.at(r, k), k))
    case XPBin{n, y, +l, +r} EQ{}:
      xpl.glue(l, r)

def xpl.del(+k: XId, +t: XPel) -> XPel:
  xpl.rm(t, xpl.at(t, k), k)

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

# a node's element cut from the end of a tree, and the tree left
type XICut is Data:
  XICut{x: XId, t: XIds}

def xis.cutl.fix(c: XICut, +x: XId, r: XIds) -> XICut:
  match c:
    case XICut{+cx, +ct}:
      XICut{cx, xis.balance(x, ct, r)}

# the first element of the node of x between l and r, cut from it
def xis.cutl(l: XIds, +x: XId, r: XIds) -> XICut:
  match l:
    case XITip{}:
      XICut{x, r}
    case XIBin{n, +lx, ll, lr}:
      xis.cutl.fix(xis.cutl(ll, lx, lr), x, r)

def xis.cutr.fix(c: XICut, +x: XId, l: XIds) -> XICut:
  match c:
    case XICut{+cx, +ct}:
      XICut{cx, xis.balance(x, l, ct)}

# the last element of the node of x between l and r, cut from it
def xis.cutr(r: XIds, +x: XId, l: XIds) -> XICut:
  match r:
    case XITip{}:
      XICut{x, l}
    case XIBin{n, +rx, rl, rr}:
      xis.cutr.fix(xis.cutr(rr, rx, rl), x, l)

def xis.glue.lfix(c: XICut, r: XIds) -> XIds:
  match c:
    case XICut{+x, +l}:
      xis.balance(x, l, r)

def xis.glue.rfix(l: XIds, c: XICut) -> XIds:
  match c:
    case XICut{+x, +r}:
      xis.balance(x, l, r)

# the larger side l's last element takes the place of the one taken out
def xis.glue.l(l: XIds, r: XIds) -> XIds:
  match l:
    case XITip{}:
      r
    case XIBin{n, +lx, ll, lr}:
      xis.glue.lfix(xis.cutr(lr, lx, ll), r)

# or r's first element (r a tip: both sides are)
def xis.glue.r(l: XIds, r: XIds) -> XIds:
  match r:
    case XITip{}:
      l
    case XIBin{n, +rx, rl, rr}:
      xis.glue.rfix(l, xis.cutl(rl, rx, rr))

def xis.glue.of(lbig: Bool, l: XIds, r: XIds) -> XIds:
  match lbig:
    case True{}:
      xis.glue.l(l, r)
    case False{}:
      xis.glue.r(l, r)

# the elements of l and then those of r, the sides of a node whose
# element is taken out
def xis.glue(+l: XIds, +r: XIds) -> XIds:
  xis.glue.of(Nat.is_lt(xis.size(r), xis.size(l)), l, r)

# t without the element of key k (t as it was when it holds none); c is
# how k compares with t's root's
def xis.rm(t: XIds, c: Cmp, +k: XId) -> XIds:
  match t c:
    case XITip{} _:
      XITip{}
    case XIBin{n, +y, +l, +r} LT{}:
      xis.balance(y, xis.rm(l, xis.at(l, k), k), r)
    case XIBin{n, +y, +l, +r} GT{}:
      xis.balance(y, l, xis.rm(r, xis.at(r, k), k))
    case XIBin{n, y, +l, +r} EQ{}:
      xis.glue(l, r)

def xis.del(+k: XId, +t: XIds) -> XIds:
  xis.rm(t, xis.at(t, k), k)

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

# a node's element cut from the end of a tree, and the tree left
type XCCut is Data:
  XCCut{x: XCon, t: XCons}

def xcs.cutl.fix(c: XCCut, +x: XCon, r: XCons) -> XCCut:
  match c:
    case XCCut{+cx, +ct}:
      XCCut{cx, xcs.balance(x, ct, r)}

# the first element of the node of x between l and r, cut from it
def xcs.cutl(l: XCons, +x: XCon, r: XCons) -> XCCut:
  match l:
    case XCTip{}:
      XCCut{x, r}
    case XCBin{n, +lx, ll, lr}:
      xcs.cutl.fix(xcs.cutl(ll, lx, lr), x, r)

def xcs.cutr.fix(c: XCCut, +x: XCon, l: XCons) -> XCCut:
  match c:
    case XCCut{+cx, +ct}:
      XCCut{cx, xcs.balance(x, l, ct)}

# the last element of the node of x between l and r, cut from it
def xcs.cutr(r: XCons, +x: XCon, l: XCons) -> XCCut:
  match r:
    case XCTip{}:
      XCCut{x, l}
    case XCBin{n, +rx, rl, rr}:
      xcs.cutr.fix(xcs.cutr(rr, rx, rl), x, l)

def xcs.glue.lfix(c: XCCut, r: XCons) -> XCons:
  match c:
    case XCCut{+x, +l}:
      xcs.balance(x, l, r)

def xcs.glue.rfix(l: XCons, c: XCCut) -> XCons:
  match c:
    case XCCut{+x, +r}:
      xcs.balance(x, l, r)

# the larger side l's last element takes the place of the one taken out
def xcs.glue.l(l: XCons, r: XCons) -> XCons:
  match l:
    case XCTip{}:
      r
    case XCBin{n, +lx, ll, lr}:
      xcs.glue.lfix(xcs.cutr(lr, lx, ll), r)

# or r's first element (r a tip: both sides are)
def xcs.glue.r(l: XCons, r: XCons) -> XCons:
  match r:
    case XCTip{}:
      l
    case XCBin{n, +rx, rl, rr}:
      xcs.glue.rfix(l, xcs.cutl(rl, rx, rr))

def xcs.glue.of(lbig: Bool, l: XCons, r: XCons) -> XCons:
  match lbig:
    case True{}:
      xcs.glue.l(l, r)
    case False{}:
      xcs.glue.r(l, r)

# the elements of l and then those of r, the sides of a node whose
# element is taken out
def xcs.glue(+l: XCons, +r: XCons) -> XCons:
  xcs.glue.of(Nat.is_lt(xcs.size(r), xcs.size(l)), l, r)

# t without the element of key k (t as it was when it holds none); c is
# how k compares with t's root's
def xcs.rm(t: XCons, c: Cmp, +k: String) -> XCons:
  match t c:
    case XCTip{} _:
      XCTip{}
    case XCBin{n, +y, +l, +r} LT{}:
      xcs.balance(y, xcs.rm(l, xcs.at(l, k), k), r)
    case XCBin{n, +y, +l, +r} GT{}:
      xcs.balance(y, l, xcs.rm(r, xcs.at(r, k), k))
    case XCBin{n, y, +l, +r} EQ{}:
      xcs.glue(l, r)

def xcs.del(+k: String, +t: XCons) -> XCons:
  xcs.rm(t, xcs.at(t, k), k)

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

# a node's element cut from the end of a tree, and the tree left
type XGCut is Data:
  XGCut{x: XGroup, t: XGroups}

def xgs.cutl.fix(c: XGCut, +x: XGroup, r: XGroups) -> XGCut:
  match c:
    case XGCut{+cx, +ct}:
      XGCut{cx, xgs.balance(x, ct, r)}

# the first element of the node of x between l and r, cut from it
def xgs.cutl(l: XGroups, +x: XGroup, r: XGroups) -> XGCut:
  match l:
    case XGTip{}:
      XGCut{x, r}
    case XGBin{n, +lx, ll, lr}:
      xgs.cutl.fix(xgs.cutl(ll, lx, lr), x, r)

def xgs.cutr.fix(c: XGCut, +x: XGroup, l: XGroups) -> XGCut:
  match c:
    case XGCut{+cx, +ct}:
      XGCut{cx, xgs.balance(x, l, ct)}

# the last element of the node of x between l and r, cut from it
def xgs.cutr(r: XGroups, +x: XGroup, l: XGroups) -> XGCut:
  match r:
    case XGTip{}:
      XGCut{x, l}
    case XGBin{n, +rx, rl, rr}:
      xgs.cutr.fix(xgs.cutr(rr, rx, rl), x, l)

def xgs.glue.lfix(c: XGCut, r: XGroups) -> XGroups:
  match c:
    case XGCut{+x, +l}:
      xgs.balance(x, l, r)

def xgs.glue.rfix(l: XGroups, c: XGCut) -> XGroups:
  match c:
    case XGCut{+x, +r}:
      xgs.balance(x, l, r)

# the larger side l's last element takes the place of the one taken out
def xgs.glue.l(l: XGroups, r: XGroups) -> XGroups:
  match l:
    case XGTip{}:
      r
    case XGBin{n, +lx, ll, lr}:
      xgs.glue.lfix(xgs.cutr(lr, lx, ll), r)

# or r's first element (r a tip: both sides are)
def xgs.glue.r(l: XGroups, r: XGroups) -> XGroups:
  match r:
    case XGTip{}:
      l
    case XGBin{n, +rx, rl, rr}:
      xgs.glue.rfix(l, xgs.cutl(rl, rx, rr))

def xgs.glue.of(lbig: Bool, l: XGroups, r: XGroups) -> XGroups:
  match lbig:
    case True{}:
      xgs.glue.l(l, r)
    case False{}:
      xgs.glue.r(l, r)

# the elements of l and then those of r, the sides of a node whose
# element is taken out
def xgs.glue(+l: XGroups, +r: XGroups) -> XGroups:
  xgs.glue.of(Nat.is_lt(xgs.size(r), xgs.size(l)), l, r)

# t without the element of key k (t as it was when it holds none); c is
# how k compares with t's root's
def xgs.rm(t: XGroups, c: Cmp, +k: String) -> XGroups:
  match t c:
    case XGTip{} _:
      XGTip{}
    case XGBin{n, +y, +l, +r} LT{}:
      xgs.balance(y, xgs.rm(l, xgs.at(l, k), k), r)
    case XGBin{n, +y, +l, +r} GT{}:
      xgs.balance(y, l, xgs.rm(r, xgs.at(r, k), k))
    case XGBin{n, y, +l, +r} EQ{}:
      xgs.glue(l, r)

def xgs.del(+k: String, +t: XGroups) -> XGroups:
  xgs.rm(t, xgs.at(t, k), k)

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
