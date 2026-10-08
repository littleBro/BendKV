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
# the bucket of that path: a chain of Ent cells, each a key, its value
# and the rest of the bucket, which ends in Tip. A Node inside a bucket
# and an Ent above the end of a path are never built; they read as
# empty.
type Trie<-V: Data> is Data:
  Tip{}
  Node{c0: Trie<V>, c1: Trie<V>, c2: Trie<V>, c3: Trie<V>, c4: Trie<V>, c5: Trie<V>, c6: Trie<V>, c7: Trie<V>, c8: Trie<V>, c9: Trie<V>, c10: Trie<V>, c11: Trie<V>, c12: Trie<V>, c13: Trie<V>, c14: Trie<V>, c15: Trie<V>}
  Ent{key: String, val: V, rest: Trie<V>}
# END gen_trie: types

# a change to one bucket
type Op<-V: Data> is Data:
  OSet{key: String, val: V}
  ODel{key: String}

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
# write builds only the bucket it returns.

# whether a bucket's first entry is for k
def bhead(-V: Data, +k: String, b: Trie<V>) -> Bool:
  match b:
    case Ent{key, v, rest}:
      str_eq(k, key)
    case other:
      False{}

# the value of the first entry for k; same is bhead(V, k, b), computed
# before b is passed on, so that b is not shared
def bget.go(-V: Data, +k: String, b: Trie<V>, same: Bool) -> Maybe<&2, V>:
  match b same:
    case Ent{key, v, rest} True{}:
      Some{v}
    case Ent{key, v, +rest} False{}:
      s = bhead(V, k, rest)
      bget.go(V, k, rest, s)
    case other _:
      None{}

def bget(-V: Data, +k: String, +b: Trie<V>) -> Maybe<&2, V>:
  s = bhead(V, k, b)
  bget.go(V, k, b, s)

# bget for String values, answering a copy of the value made where it
# lies: the value is only read, so the trie never shares it (bget answers
# the value itself, which the trie and the answer then share, under a
# seal). A copy of the whole string is the string (PROOF.bend: take_len).
def bget_c.go(+k: String, b: Trie<String>, same: Bool) -> Maybe<&2, String>:
  match b same:
    case Ent{key, +v, rest} True{}:
      Some{String.take(v, String.length(v))}
    case Ent{key, v, +rest} False{}:
      s = bhead(String, k, rest)
      bget_c.go(k, rest, s)
    case other _:
      None{}

def bget_c(+k: String, +b: Trie<String>) -> Maybe<&2, String>:
  s = bhead(String, k, b)
  bget_c.go(k, b, s)

# the bucket with the first entry for k set to v, or k appended. The
# bucket's end goes back into the result (a Tip, or a Node that reads as
# empty), so that bset.go owns the bucket and rebuilds it in place.
def bset.go(-V: Data, +k: String, v: V, b: Trie<V>, same: Bool) -> Trie<V>:
  match b same:
    case Ent{key, val, rest} True{}:
      Ent{key, v, rest}
    case Ent{key, val, +rest} False{}:
      s = bhead(V, k, rest)
      Ent{key, val, bset.go(V, k, v, rest, s)}
    case other _:
      Ent{k, v, other}

def bset(-V: Data, +k: String, v: V, +b: Trie<V>) -> Trie<V>:
  s = bhead(V, k, b)
  bset.go(V, k, v, b, s)

# the bucket without any entry for k; its end goes back, as in bset.go
def bdel.go(-V: Data, +k: String, b: Trie<V>, same: Bool) -> Trie<V>:
  match b same:
    case Ent{key, val, +rest} True{}:
      s = bhead(V, k, rest)
      bdel.go(V, k, rest, s)
    case Ent{key, val, +rest} False{}:
      s = bhead(V, k, rest)
      Ent{key, val, bdel.go(V, k, rest, s)}
    case other _:
      other

def bdel(-V: Data, +k: String, +b: Trie<V>) -> Trie<V>:
  s = bhead(V, k, b)
  bdel.go(V, k, b, s)

# a hint for a read of a bucket (Mem.prefetch): acc, after starting to
# load the key and the value of its first entry
def btouch(-V: Data, b: Trie<V>, acc: U32) -> U32:
  match b:
    case Ent{key, v, rest}:
      Mem.prefetch(String, key, Mem.prefetch(V, v, acc))
    case other:
      acc

def bapply(-V: Data, op: Op<V>, b: Trie<V>) -> Trie<V>:
  match op:
    case OSet{k, v}:
      bset(V, k, v, b)
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

# tget_k for String values, answering a copy of the value (bget_c)
def tget_kc(d: Nat, t: Trie<String>, x: Hex, +h: U32, +k: String) -> Maybe<&2, String>:
  match d t x:
    case 0n t0 _:
      bget_c(k, t0)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H0{}:
      tget_kc(p, c0, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H1{}:
      tget_kc(p, c1, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H2{}:
      tget_kc(p, c2, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H3{}:
      tget_kc(p, c3, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H4{}:
      tget_kc(p, c4, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H5{}:
      tget_kc(p, c5, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H6{}:
      tget_kc(p, c6, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H7{}:
      tget_kc(p, c7, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H8{}:
      tget_kc(p, c8, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H9{}:
      tget_kc(p, c9, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H10{}:
      tget_kc(p, c10, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H11{}:
      tget_kc(p, c11, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H12{}:
      tget_kc(p, c12, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H13{}:
      tget_kc(p, c13, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H14{}:
      tget_kc(p, c14, hex(shr4(h)), shr4(h), k)
    case 1n+p Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H15{}:
      tget_kc(p, c15, hex(shr4(h)), shr4(h), k)
    case 1n+p other _:
      None{}

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
def tkeys(-V: Data, t: Trie<V>, acc: List<&2, String>) -> List<&2, String>:
  match t:
    case Tip{}:
      acc
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}:
      tkeys(V, c0, tkeys(V, c1, tkeys(V, c2, tkeys(V, c3, tkeys(V, c4, tkeys(V, c5, tkeys(V, c6, tkeys(V, c7, tkeys(V, c8, tkeys(V, c9, tkeys(V, c10, tkeys(V, c11, tkeys(V, c12, tkeys(V, c13, tkeys(V, c14, tkeys(V, c15, acc))))))))))))))))
    case Ent{k, v, rest}:
      k <> tkeys(V, rest, acc)

def tsize(-V: Data, t: Trie<V>) -> Nat:
  match t:
    case Tip{}:
      0n
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}:
      Nat.add(tsize(V, c0), Nat.add(tsize(V, c1), Nat.add(tsize(V, c2), Nat.add(tsize(V, c3), Nat.add(tsize(V, c4), Nat.add(tsize(V, c5), Nat.add(tsize(V, c6), Nat.add(tsize(V, c7), Nat.add(tsize(V, c8), Nat.add(tsize(V, c9), Nat.add(tsize(V, c10), Nat.add(tsize(V, c11), Nat.add(tsize(V, c12), Nat.add(tsize(V, c13), Nat.add(tsize(V, c14), tsize(V, c15))))))))))))))))
    case Ent{k, v, rest}:
      1n+tsize(V, rest)
# END gen_trie: folds

# Root
# ----
# The root branches on the lowest hex digit of a hash. A server with n
# shards gives each shard the subtries of some of the root's digits
# (shard.bend), and DBSIZE, KEYS and FLUSHALL reach the shards as a
# command for each digit, on that digit's subtrie (redis.bend: SizeAt,
# KeysAt, FlushAt).

# BEGIN gen_trie: root
# every digit, in order
def digits() -> List<&2, Hex>:
  [H0{}, H1{}, H2{}, H3{}, H4{}, H5{}, H6{}, H7{}, H8{}, H9{}, H10{}, H11{}, H12{}, H13{}, H14{}, H15{}]

# whether two digits are the same
def hex_eq(x: Hex, y: Hex) -> Bool:
  match x y:
    case H0{} H0{}:
      True{}
    case H0{} other:
      False{}
    case H1{} H1{}:
      True{}
    case H1{} other:
      False{}
    case H2{} H2{}:
      True{}
    case H2{} other:
      False{}
    case H3{} H3{}:
      True{}
    case H3{} other:
      False{}
    case H4{} H4{}:
      True{}
    case H4{} other:
      False{}
    case H5{} H5{}:
      True{}
    case H5{} other:
      False{}
    case H6{} H6{}:
      True{}
    case H6{} other:
      False{}
    case H7{} H7{}:
      True{}
    case H7{} other:
      False{}
    case H8{} H8{}:
      True{}
    case H8{} other:
      False{}
    case H9{} H9{}:
      True{}
    case H9{} other:
      False{}
    case H10{} H10{}:
      True{}
    case H10{} other:
      False{}
    case H11{} H11{}:
      True{}
    case H11{} other:
      False{}
    case H12{} H12{}:
      True{}
    case H12{} other:
      False{}
    case H13{} H13{}:
      True{}
    case H13{} other:
      False{}
    case H14{} H14{}:
      True{}
    case H14{} other:
      False{}
    case H15{} H15{}:
      True{}
    case H15{} other:
      False{}

# the digit as a number
def hex_val(x: Hex) -> U32:
  match x:
    case H0{}:
      0
    case H1{}:
      1
    case H2{}:
      2
    case H3{}:
      3
    case H4{}:
      4
    case H5{}:
      5
    case H6{}:
      6
    case H7{}:
      7
    case H8{}:
      8
    case H9{}:
      9
    case H10{}:
      10
    case H11{}:
      11
    case H12{}:
      12
    case H13{}:
      13
    case H14{}:
      14
    case H15{}:
      15

# the subtrie under digit x of t's root (an empty one where the root is
# not a node): the proofs speak of it, and the code takes the child
# apart where it uses it (size.at, keys.at)
def child(-V: Data, t: Trie<V>, x: Hex) -> Trie<V>:
  match t x:
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H0{}:
      c0
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H1{}:
      c1
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H2{}:
      c2
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H3{}:
      c3
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H4{}:
      c4
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H5{}:
      c5
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H6{}:
      c6
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H7{}:
      c7
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H8{}:
      c8
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H9{}:
      c9
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H10{}:
      c10
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H11{}:
      c11
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H12{}:
      c12
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H13{}:
      c13
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H14{}:
      c14
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H15{}:
      c15
    case other _:
      Tip{}

# t with the subtrie under digit x of its root replaced by c
def with_child(-V: Data, t: Trie<V>, +x: Hex, +c: Trie<V>) -> Trie<V>:
  match t:
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}:
      Node{Bool.pick(Trie<V>, hex_eq(H0{}, x), c, c0), Bool.pick(Trie<V>, hex_eq(H1{}, x), c, c1), Bool.pick(Trie<V>, hex_eq(H2{}, x), c, c2), Bool.pick(Trie<V>, hex_eq(H3{}, x), c, c3), Bool.pick(Trie<V>, hex_eq(H4{}, x), c, c4), Bool.pick(Trie<V>, hex_eq(H5{}, x), c, c5), Bool.pick(Trie<V>, hex_eq(H6{}, x), c, c6), Bool.pick(Trie<V>, hex_eq(H7{}, x), c, c7), Bool.pick(Trie<V>, hex_eq(H8{}, x), c, c8), Bool.pick(Trie<V>, hex_eq(H9{}, x), c, c9), Bool.pick(Trie<V>, hex_eq(H10{}, x), c, c10), Bool.pick(Trie<V>, hex_eq(H11{}, x), c, c11), Bool.pick(Trie<V>, hex_eq(H12{}, x), c, c12), Bool.pick(Trie<V>, hex_eq(H13{}, x), c, c13), Bool.pick(Trie<V>, hex_eq(H14{}, x), c, c14), Bool.pick(Trie<V>, hex_eq(H15{}, x), c, c15)}
    case other:
      Node{Bool.pick(Trie<V>, hex_eq(H0{}, x), c, Tip{}), Bool.pick(Trie<V>, hex_eq(H1{}, x), c, Tip{}), Bool.pick(Trie<V>, hex_eq(H2{}, x), c, Tip{}), Bool.pick(Trie<V>, hex_eq(H3{}, x), c, Tip{}), Bool.pick(Trie<V>, hex_eq(H4{}, x), c, Tip{}), Bool.pick(Trie<V>, hex_eq(H5{}, x), c, Tip{}), Bool.pick(Trie<V>, hex_eq(H6{}, x), c, Tip{}), Bool.pick(Trie<V>, hex_eq(H7{}, x), c, Tip{}), Bool.pick(Trie<V>, hex_eq(H8{}, x), c, Tip{}), Bool.pick(Trie<V>, hex_eq(H9{}, x), c, Tip{}), Bool.pick(Trie<V>, hex_eq(H10{}, x), c, Tip{}), Bool.pick(Trie<V>, hex_eq(H11{}, x), c, Tip{}), Bool.pick(Trie<V>, hex_eq(H12{}, x), c, Tip{}), Bool.pick(Trie<V>, hex_eq(H13{}, x), c, Tip{}), Bool.pick(Trie<V>, hex_eq(H14{}, x), c, Tip{}), Bool.pick(Trie<V>, hex_eq(H15{}, x), c, Tip{})}

# the number of entries under digit x of t's root, and the keys there in
# front of acc: tsize and tkeys go on from a field of t's root, so they
# only read the trie (a subtrie handed to them would be theirs to take
# apart, and taking a shared node apart copies it)
def size.at(-V: Data, t: Trie<V>, x: Hex) -> Nat:
  match t x:
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H0{}:
      tsize(V, c0)
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H1{}:
      tsize(V, c1)
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H2{}:
      tsize(V, c2)
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H3{}:
      tsize(V, c3)
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H4{}:
      tsize(V, c4)
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H5{}:
      tsize(V, c5)
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H6{}:
      tsize(V, c6)
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H7{}:
      tsize(V, c7)
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H8{}:
      tsize(V, c8)
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H9{}:
      tsize(V, c9)
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H10{}:
      tsize(V, c10)
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H11{}:
      tsize(V, c11)
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H12{}:
      tsize(V, c12)
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H13{}:
      tsize(V, c13)
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H14{}:
      tsize(V, c14)
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H15{}:
      tsize(V, c15)
    case other _:
      0n

def keys.at(-V: Data, t: Trie<V>, x: Hex, acc: List<&2, String>) -> List<&2, String>:
  match t x:
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H0{}:
      tkeys(V, c0, acc)
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H1{}:
      tkeys(V, c1, acc)
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H2{}:
      tkeys(V, c2, acc)
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H3{}:
      tkeys(V, c3, acc)
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H4{}:
      tkeys(V, c4, acc)
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H5{}:
      tkeys(V, c5, acc)
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H6{}:
      tkeys(V, c6, acc)
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H7{}:
      tkeys(V, c7, acc)
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H8{}:
      tkeys(V, c8, acc)
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H9{}:
      tkeys(V, c9, acc)
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H10{}:
      tkeys(V, c10, acc)
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H11{}:
      tkeys(V, c11, acc)
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H12{}:
      tkeys(V, c12, acc)
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H13{}:
      tkeys(V, c13, acc)
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H14{}:
      tkeys(V, c14, acc)
    case Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} H15{}:
      tkeys(V, c15, acc)
    case other _:
      acc
# END gen_trie: root

# API
# ---

def empty(-V: Data) -> Trie<V>:
  Tip{}

# t with the subtrie under each digit of xs emptied, one after another
def clear.of(-V: Data, xs: List<&2, Hex>, t: Trie<V>) -> Trie<V>:
  match xs:
    case Nil{}:
      t
    case Con{+x, rest}:
      clear.of(V, rest, with_child(V, t, x, empty(V)))

# the map without its keys: the subtrie under every digit emptied, as a
# server with shards empties each digit's subtrie in its shard. (A root of
# 16 empty subtries written as a constant would be allocated statically,
# and a Node that may be static is never updated in place: every write to
# the trie would copy the nodes on its path.)
def clear(-V: Data, t: Trie<V>) -> Trie<V>:
  clear.of(V, digits(), t)

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

def get.at(-V: Data, t: Trie<V>, +k: String, +h: U32) -> Maybe<&2, V>:
  tget_k(V, 5n, t, hex(h), h, k)

def get(-V: Data, t: Trie<V>, +k: String) -> Maybe<&2, V>:
  get.at(V, t, k, hash(k))

# get.at for String values, answering a copy of the value (bget_c)
def get_copy.at(t: Trie<String>, +k: String, +h: U32) -> Maybe<&2, String>:
  tget_kc(5n, t, hex(h), h, k)

def set.at(-V: Data, t: Trie<V>, +k: String, v: V, +h: U32) -> Trie<V>:
  tmod_h(V, 5n, t, hex(h), h, OSet{k, v})

def set(-V: Data, t: Trie<V>, +k: String, v: V) -> Trie<V>:
  set.at(V, t, k, v, hash(k))

def del.at(-V: Data, t: Trie<V>, +k: String, +h: U32) -> Trie<V>:
  tmod_h(V, 5n, t, hex(h), h, ODel{k})

def del(-V: Data, t: Trie<V>, +k: String) -> Trie<V>:
  del.at(V, t, k, hash(k))

def has(-V: Data, t: Trie<V>, k: String) -> Bool:
  Maybe.is_some(&2, V, get(V, t, k))

# the number of entries under the root's subtries at the digits xs
def sizes(-V: Data, +t: Trie<V>, xs: List<&2, Hex>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case Con{x, rest}:
      Nat.add(size.at(V, t, x), sizes(V, t, rest))

# the keys under the root's subtries at the digits xs, in order
def keys.of(-V: Data, +t: Trie<V>, xs: List<&2, Hex>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{x, rest}:
      keys.at(V, t, x, keys.of(V, t, rest))

# the keys of a map, and how many there are: those under the root's
# subtries, digit by digit (a root that is not a node has none)
def keys(-V: Data, +t: Trie<V>) -> List<&2, String>:
  keys.of(V, t, digits())

def size(-V: Data, +t: Trie<V>) -> Nat:
  sizes(V, t, digits())
