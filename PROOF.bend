# PROOF.bend: the proofs of LAWS.bend. Run `bend PROOF.bend`: it prints
# ALL PROOFS CHECK only when every law is proven; `--verdict` rechecks
# the proofs with BendTT, the kernel proven sound in Lean.

import Base
import ./map.bend as KV
import ./redis.bend as R
import ./batch.bend as B
import ./shard.bend as S
import ./resp.bend as P
import ./wire.bend as W
import ./aof.bend as A
import ./LAWS.bend as Laws

# Kit
# ===

# Reflect(A, a, b, c): the Bool c decides a == b: it carries a proof of
# the equality when c is True and a refutation when c is False
def Reflect(-A: Type, a: A, b: A, c: Bool) -> Type:
  match c:
    case True{}:
      {a == b : A}
    case False{}:
      {a == b : A} -> Empty

# a decision on a == a is True
def refl_self(-A: Type, -a: A, c: Bool) -> Reflect(A, a, a, c) -> {True{} == c : Bool}:
  match c:
    case True{}:
      e => {==}
    case False{}:
      ne => Empty.absurd({True{} == False{} : Bool}, ne({==}))

# a decision on a == b is False when a != b
def refl_ne(-A: Type, -a: A, -b: A, c: Bool, ne: {a != b : A}) -> Reflect(A, a, b, c) -> {False{} == c : Bool}:
  match c:
    case True{}:
      e => Empty.absurd({False{} == True{} : Bool}, ne(e))
    case False{}:
      r => {==}

# motives that tell constructors apart
def is_true(b: Bool) -> Type:
  match b:
    case True{}:
      Unit
    case False{}:
      Empty

def is_false(b: Bool) -> Type:
  match b:
    case True{}:
      Empty
    case False{}:
      Unit

def is_snil(s: String) -> Type:
  match s:
    case SNil{}:
      Unit
    case SCon{h, t}:
      Empty

def is_scon(s: String) -> Type:
  match s:
    case SNil{}:
      Empty
    case SCon{h, t}:
      Unit

# a Bool is not both
def false_true(e: {False{} == True{} : Bool}) -> Empty:
  %e : is_false(_)
  Unit{}

def true_false(e: {True{} == False{} : Bool}) -> Empty:
  %e : is_true(_)
  Unit{}

# projections, for congruence
def whead(-p: Nat, w: Word(1n+p)) -> Bool:
  match w:
    case WCon{h, t}:
      h

def wtail(-p: Nat, w: Word(1n+p)) -> Word(p):
  match w:
    case WCon{h, t}:
      t

def u32_word(u: U32) -> Word(32n):
  match u:
    case U32{w}:
      w

def chr_code(c: Char) -> U32:
  match c:
    case Chr{x}:
      x

def shead(s: String) -> Char:
  match s:
    case SNil{}:
      Chr{0}
    case SCon{h, t}:
      h

def stail(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{h, t}:
      t

# Key equality
# ============
# str_eq decides String equality. The proof descends the representation:
# a String is a list of Char, a Char wraps a U32, and a U32 is a 32-bit
# Word, whose comparison Word.cmp is defined bit by bit in Base.

def word_fin_refl(-p: Nat, -at: Word(p), -bt: Word(p), t: Cmp, ab: Bool, bb: Bool)
  -> Reflect(Word(p), at, bt, Cmp.is_eq(t))
  -> Reflect(Word(1n+p), WCon{ab, at}, WCon{bb, bt}, Cmp.is_eq(Word.cmp.fin(ab, bb, t))):
  match t ab bb:
    case LT{} _ _:
      ne => e => ne(Equal.cong(Word(1n+p), Word(p), w => wtail(p, w), WCon{ab, at}, WCon{bb, bt}, e))
    case GT{} _ _:
      ne => e => ne(Equal.cong(Word(1n+p), Word(p), w => wtail(p, w), WCon{ab, at}, WCon{bb, bt}, e))
    case EQ{} True{} True{}:
      e => %e : {WCon{True{}, at} == WCon{True{}, _} : Word(1n+p)}
           {==}
    case EQ{} False{} False{}:
      e => %e : {WCon{False{}, at} == WCon{False{}, _} : Word(1n+p)}
           {==}
    case EQ{} True{} False{}:
      e => h => %Equal.cong(Word(1n+p), Bool, w => whead(p, w), WCon{True{}, at}, WCon{False{}, bt}, h) : is_true(_)
                Unit{}
    case EQ{} False{} True{}:
      e => h => %Equal.cong(Word(1n+p), Bool, w => whead(p, w), WCon{False{}, at}, WCon{True{}, bt}, h) : is_false(_)
                Unit{}

def word_refl(n: Nat, a: Word(n), b: Word(n)) -> Reflect(Word(n), a, b, Cmp.is_eq(Word.cmp(n, a, b))):
  match n:
    case 0n:
      match a b:
        case WNil{} WNil{}:
          {==}
    case 1n++p:
      match a b:
        case WCon{+ab, +at} WCon{+bb, +bt}:
          word_fin_refl(p, at, bt, Word.cmp(p, at, bt), ab, bb)(word_refl(p, at, bt))

def u32_lift(-x: Word(32n), -y: Word(32n), c: Bool) -> Reflect(Word(32n), x, y, c) -> Reflect(U32, U32{x}, U32{y}, c):
  match c:
    case True{}:
      e => %e : {U32{x} == U32{_} : U32}
           {==}
    case False{}:
      ne => e => ne(Equal.cong(U32, Word(32n), u => u32_word(u), U32{x}, U32{y}, e))

def u32_refl(a: U32, b: U32) -> Reflect(U32, a, b, U32.is_eq(a, b)):
  match a b:
    case U32{+x} U32{+y}:
      u32_lift(x, y, Cmp.is_eq(Word.cmp(32n, x, y)))(word_refl(32n, x, y))

def chr_lift(-x: U32, -y: U32, c: Bool) -> Reflect(U32, x, y, c) -> Reflect(Char, Chr{x}, Chr{y}, c):
  match c:
    case True{}:
      e => %e : {Chr{x} == Chr{_} : Char}
           {==}
    case False{}:
      ne => e => ne(Equal.cong(Char, U32, ch => chr_code(ch), Chr{x}, Chr{y}, e))

def chr_refl(a: Char, b: Char) -> Reflect(Char, a, b, Char.is_eq(a, b)):
  match a b:
    case Chr{+x} Chr{+y}:
      chr_lift(x, y, U32.is_eq(x, y))(u32_refl(x, y))

def str_lift(-x: Char, -xt: String, -y: Char, -yt: String, c: Bool, d: Bool)
  -> Reflect(Char, x, y, c) -> Reflect(String, xt, yt, d)
  -> Reflect(String, SCon{x, xt}, SCon{y, yt}, Bool.and(c, d)):
  match c d:
    case True{} True{}:
      e1 => e2 => %e1 : {SCon{x, xt} == SCon{_, yt} : String}
                  %e2 : {SCon{x, xt} == SCon{x, _} : String}
                  {==}
    case True{} False{}:
      e1 => ne2 => e => ne2(Equal.cong(String, String, s => stail(s), SCon{x, xt}, SCon{y, yt}, e))
    case False{} _:
      ne1 => r2 => e => ne1(Equal.cong(String, Char, s => shead(s), SCon{x, xt}, SCon{y, yt}, e))

# str_eq is String.eq; the proofs reason about the comparison char by
# char, which String.eq answers too (str_spec)
def str_eq.spec(a: String, b: String) -> Bool:
  match a b:
    case SNil{} SNil{}:
      True{}
    case SNil{} SCon{h, t}:
      False{}
    case SCon{h, t} SNil{}:
      False{}
    case SCon{x, xt} SCon{y, yt}:
      Bool.and(Char.is_eq(x, y), str_eq.spec(xt, yt))

def spec_refl(a: String, b: String) -> Reflect(String, a, b, str_eq.spec(a, b)):
  match a b:
    case SNil{} SNil{}:
      {==}
    case SNil{} SCon{h, t}:
      e => %e : is_snil(_)
           Unit{}
    case SCon{h, t} SNil{}:
      e => %e : is_scon(_)
           Unit{}
    case SCon{+x, +xt} SCon{+y, +yt}:
      str_lift(x, xt, y, yt, Char.is_eq(x, y), str_eq.spec(xt, yt))(chr_refl(x, y), spec_refl(xt, yt))

# String.cmp.rec keeps the verdict of the comparison it wraps
def rec_snd(-h1: Char, -h2: Char, p: (String & String) & Cmp) -> {Pair.snd(String & String, Cmp, p) == Pair.snd(String & String, Cmp, String.cmp.rec(h1, h2, p)) : Cmp}:
  match p:
    case ((t1, t2), r):
      {==}

# a step of str_spec: c is the verdict on the two heads' code points
def spec_step(c: Cmp, -h1: Char, -h2: Char, +xt: String, +yt: String, ih: {str_eq.spec(xt, yt) == String.eq(xt, yt) : Bool}) -> {Bool.and(Cmp.is_eq(c), str_eq.spec(xt, yt)) == Cmp.is_eq(Pair.snd(String & String, Cmp, String.cmp.fin(xt, yt, ((h1, h2), c)))) : Bool}:
  match c:
    case LT{}:
      {==}
    case EQ{}:
      %rec_snd(h1, h2, String.cmp(xt, yt)) : {str_eq.spec(xt, yt) == Cmp.is_eq(_) : Bool}
      ih
    case GT{}:
      {==}

def str_spec(a: String, b: String) -> {str_eq.spec(a, b) == KV.str_eq(a, b) : Bool}:
  match a b:
    case SNil{} SNil{}:
      {==}
    case SNil{} SCon{h, t}:
      {==}
    case SCon{h, t} SNil{}:
      {==}
    case SCon{Chr{+u}, +xt} SCon{Chr{+v}, +yt}:
      spec_step(U32.cmp(u, v), Chr{u}, Chr{v}, xt, yt, str_spec(xt, yt))

def str_refl(+a: String, +b: String) -> Reflect(String, a, b, KV.str_eq(a, b)):
  %str_spec(a, b) : Reflect(String, a, b, _)
  spec_refl(a, b)

# every key equals itself
def str_eq_self(+k: String) -> {True{} == KV.str_eq(k, k) : Bool}:
  refl_self(String, k, KV.str_eq(k, k))(str_refl(k, k))

# different keys compare unequal
def str_eq_ne(+a: String, +b: String, ne: {a != b : String}) -> {False{} == KV.str_eq(a, b) : Bool}:
  refl_ne(String, a, b, KV.str_eq(a, b), ne)(str_refl(a, b))

# Buckets
# =======
# A bucket is a chain of Ent cells. A step of bget, bset or bdel takes the
# comparison of the key with the entry's key as a parameter (bhead), so
# the lemmas split on that comparison: a Bool c, with an equation that
# says what it is. A bucket ends in a Tip, or in a Node, which reads as
# empty.

# a comparison's verdict carries its evidence
def refl_of(+a: String, +b: String, c: Bool, e: {c == KV.str_eq(a, b) : Bool}) -> Reflect(String, a, b, c):
  %Equal.sym(Bool, c, KV.str_eq(a, b), e) : Reflect(String, a, b, _)
  str_refl(a, b)

def bset_same_step(-V: Data, +k: String, -v: V, -key: String, -val: V, -rest: KV.Trie<V>, c: Bool, ih: {Some{v} == KV.bget(V, k, KV.bset(V, k, v, rest)) : Maybe<&2, V>})
  -> {c == KV.str_eq(k, key) : Bool}
  -> {Some{v} == KV.bget(V, k, KV.bset.go(V, k, v, KV.Ent{key, val, rest}, c)) : Maybe<&2, V>}:
  match c:
    case True{}:
      e => %e : {Some{v} == KV.bget.go(V, k, KV.Ent{key, v, rest}, _) : Maybe<&2, V>}
           {==}
    case False{}:
      e => %e : {Some{v} == KV.bget.go(V, k, KV.Ent{key, val, KV.bset(V, k, v, rest)}, _) : Maybe<&2, V>}
           ih

def bget_bset_same(-V: Data, +k: String, +v: V, +b: KV.Trie<V>) -> {Some{v} == KV.bget(V, k, KV.bset(V, k, v, b)) : Maybe<&2, V>}:
  match b:
    case KV.Ent{+key, +val, +rest}:
      bset_same_step(V, k, v, key, val, rest, KV.str_eq(k, key), bget_bset_same(V, k, v, rest))({==})
    case KV.Tip{}:
      %str_eq_self(k) : {Some{v} == KV.bget.go(V, k, KV.Ent{k, v, KV.Tip{}}, _) : Maybe<&2, V>}
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}:
      %str_eq_self(k) : {Some{v} == KV.bget.go(V, k, KV.Ent{k, v, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}}, _) : Maybe<&2, V>}
      {==}

# equal keys compare equal
def str_eq_of_eq(+j: String, -k: String, e: {j == k : String}) -> {True{} == KV.str_eq(j, k) : Bool}:
  %e : {True{} == KV.str_eq(j, _) : Bool}
  str_eq_self(j)

# keys that compare unequal cannot be equal: nb is the comparison's
# verdict, kept as an equation so that a proof may use it many times
def neq_eq(+j: String, -k: String, +nb: {False{} == KV.str_eq(j, k) : Bool}, e: {j == k : String}) -> Empty:
  %Equal.trans(Bool, False{}, KV.str_eq(j, k), True{}, nb, Equal.sym(Bool, True{}, KV.str_eq(j, k), str_eq_of_eq(j, k, e))) : is_false(_)
  Unit{}

# the step of bget_bset_other at an entry: c1 compares the read key j with
# the entry's key, c2 the written key k; both True would make j == k
def bset_other_step(-V: Data, +j: String, +k: String, +key: String, -v: V, -val: V, -rest: KV.Trie<V>, +nb: {False{} == KV.str_eq(j, k) : Bool}, c1: Bool, c2: Bool, ih: {KV.bget(V, j, rest) == KV.bget(V, j, KV.bset(V, k, v, rest)) : Maybe<&2, V>})
  -> {c1 == KV.str_eq(j, key) : Bool} -> {c2 == KV.str_eq(k, key) : Bool}
  -> {KV.bget.go(V, j, KV.Ent{key, val, rest}, c1) == KV.bget(V, j, KV.bset.go(V, k, v, KV.Ent{key, val, rest}, c2)) : Maybe<&2, V>}:
  match c1 c2:
    case True{} True{}:
      e1 => e2 => Empty.absurd({KV.bget.go(V, j, KV.Ent{key, val, rest}, True{}) == KV.bget(V, j, KV.bset.go(V, k, v, KV.Ent{key, val, rest}, True{})) : Maybe<&2, V>}, neq_eq(j, k, nb, Equal.trans(String, j, key, k, refl_of(j, key, True{}, e1), Equal.sym(String, k, key, refl_of(k, key, True{}, e2)))))
    case True{} False{}:
      e1 => e2 => %e1 : {KV.bget.go(V, j, KV.Ent{key, val, rest}, True{}) == KV.bget.go(V, j, KV.Ent{key, val, KV.bset(V, k, v, rest)}, _) : Maybe<&2, V>}
                  {==}
    case False{} True{}:
      e1 => e2 => %e1 : {KV.bget.go(V, j, KV.Ent{key, val, rest}, False{}) == KV.bget.go(V, j, KV.Ent{key, v, rest}, _) : Maybe<&2, V>}
                  {==}
    case False{} False{}:
      e1 => e2 => %e1 : {KV.bget.go(V, j, KV.Ent{key, val, rest}, False{}) == KV.bget.go(V, j, KV.Ent{key, val, KV.bset(V, k, v, rest)}, _) : Maybe<&2, V>}
                  ih

def bget_bset_other(-V: Data, +j: String, +k: String, +v: V, +b: KV.Trie<V>, +nb: {False{} == KV.str_eq(j, k) : Bool}) -> {KV.bget(V, j, b) == KV.bget(V, j, KV.bset(V, k, v, b)) : Maybe<&2, V>}:
  match b:
    case KV.Ent{+key, +val, +rest}:
      bset_other_step(V, j, k, key, v, val, rest, nb, KV.str_eq(j, key), KV.str_eq(k, key), bget_bset_other(V, j, k, v, rest, nb))({==})({==})
    case KV.Tip{}:
      %nb : {KV.bget(V, j, KV.Tip{}) == KV.bget.go(V, j, KV.Ent{k, v, KV.Tip{}}, _) : Maybe<&2, V>}
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}:
      %nb : {KV.bget(V, j, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}) == KV.bget.go(V, j, KV.Ent{k, v, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}}, _) : Maybe<&2, V>}
      {==}

def bdel_same_step(-V: Data, +k: String, -key: String, -val: V, -rest: KV.Trie<V>, c: Bool, ih: {None{} == KV.bget(V, k, KV.bdel(V, k, rest)) : Maybe<&2, V>})
  -> {c == KV.str_eq(k, key) : Bool}
  -> {None{} == KV.bget(V, k, KV.bdel.go(V, k, KV.Ent{key, val, rest}, c)) : Maybe<&2, V>}:
  match c:
    case True{}:
      e => ih
    case False{}:
      e => %e : {None{} == KV.bget.go(V, k, KV.Ent{key, val, KV.bdel(V, k, rest)}, _) : Maybe<&2, V>}
           ih

def bget_bdel_same(-V: Data, +k: String, +b: KV.Trie<V>) -> {None{} == KV.bget(V, k, KV.bdel(V, k, b)) : Maybe<&2, V>}:
  match b:
    case KV.Ent{+key, +val, +rest}:
      bdel_same_step(V, k, key, val, rest, KV.str_eq(k, key), bget_bdel_same(V, k, rest))({==})
    case KV.Tip{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}:
      {==}

def bdel_other_step(-V: Data, +j: String, +k: String, +key: String, -val: V, -rest: KV.Trie<V>, +nb: {False{} == KV.str_eq(j, k) : Bool}, c1: Bool, c2: Bool, ih: {KV.bget(V, j, rest) == KV.bget(V, j, KV.bdel(V, k, rest)) : Maybe<&2, V>})
  -> {c1 == KV.str_eq(j, key) : Bool} -> {c2 == KV.str_eq(k, key) : Bool}
  -> {KV.bget.go(V, j, KV.Ent{key, val, rest}, c1) == KV.bget(V, j, KV.bdel.go(V, k, KV.Ent{key, val, rest}, c2)) : Maybe<&2, V>}:
  match c1 c2:
    case True{} True{}:
      e1 => e2 => Empty.absurd({KV.bget.go(V, j, KV.Ent{key, val, rest}, True{}) == KV.bget(V, j, KV.bdel.go(V, k, KV.Ent{key, val, rest}, True{})) : Maybe<&2, V>}, neq_eq(j, k, nb, Equal.trans(String, j, key, k, refl_of(j, key, True{}, e1), Equal.sym(String, k, key, refl_of(k, key, True{}, e2)))))
    case True{} False{}:
      e1 => e2 => %e1 : {KV.bget.go(V, j, KV.Ent{key, val, rest}, True{}) == KV.bget.go(V, j, KV.Ent{key, val, KV.bdel(V, k, rest)}, _) : Maybe<&2, V>}
                  {==}
    case False{} True{}:
      e1 => e2 => ih
    case False{} False{}:
      e1 => e2 => %e1 : {KV.bget.go(V, j, KV.Ent{key, val, rest}, False{}) == KV.bget.go(V, j, KV.Ent{key, val, KV.bdel(V, k, rest)}, _) : Maybe<&2, V>}
                  ih

def bget_bdel_other(-V: Data, +j: String, +k: String, +b: KV.Trie<V>, +nb: {False{} == KV.str_eq(j, k) : Bool}) -> {KV.bget(V, j, b) == KV.bget(V, j, KV.bdel(V, k, b)) : Maybe<&2, V>}:
  match b:
    case KV.Ent{+key, +val, +rest}:
      bdel_other_step(V, j, k, key, val, rest, nb, KV.str_eq(j, key), KV.str_eq(k, key), bget_bdel_other(V, j, k, rest, nb))({==})({==})
    case KV.Tip{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}:
      {==}

# Digits
# ======

# BEGIN gen_trie: digits
# digits that hex_eq calls the same are the same
def hex_eq_sound(x: KV.Hex, y: KV.Hex) -> {KV.hex_eq(x, y) == True{} : Bool} -> {x == y : KV.Hex}:
  match x y:
    case KV.H0{} KV.H0{}:
      e => {==}
    case KV.H0{} KV.H1{}:
      e => Empty.absurd({KV.H0{} == KV.H1{} : KV.Hex}, false_true(e))
    case KV.H0{} KV.H2{}:
      e => Empty.absurd({KV.H0{} == KV.H2{} : KV.Hex}, false_true(e))
    case KV.H0{} KV.H3{}:
      e => Empty.absurd({KV.H0{} == KV.H3{} : KV.Hex}, false_true(e))
    case KV.H0{} KV.H4{}:
      e => Empty.absurd({KV.H0{} == KV.H4{} : KV.Hex}, false_true(e))
    case KV.H0{} KV.H5{}:
      e => Empty.absurd({KV.H0{} == KV.H5{} : KV.Hex}, false_true(e))
    case KV.H0{} KV.H6{}:
      e => Empty.absurd({KV.H0{} == KV.H6{} : KV.Hex}, false_true(e))
    case KV.H0{} KV.H7{}:
      e => Empty.absurd({KV.H0{} == KV.H7{} : KV.Hex}, false_true(e))
    case KV.H0{} KV.H8{}:
      e => Empty.absurd({KV.H0{} == KV.H8{} : KV.Hex}, false_true(e))
    case KV.H0{} KV.H9{}:
      e => Empty.absurd({KV.H0{} == KV.H9{} : KV.Hex}, false_true(e))
    case KV.H0{} KV.H10{}:
      e => Empty.absurd({KV.H0{} == KV.H10{} : KV.Hex}, false_true(e))
    case KV.H0{} KV.H11{}:
      e => Empty.absurd({KV.H0{} == KV.H11{} : KV.Hex}, false_true(e))
    case KV.H0{} KV.H12{}:
      e => Empty.absurd({KV.H0{} == KV.H12{} : KV.Hex}, false_true(e))
    case KV.H0{} KV.H13{}:
      e => Empty.absurd({KV.H0{} == KV.H13{} : KV.Hex}, false_true(e))
    case KV.H0{} KV.H14{}:
      e => Empty.absurd({KV.H0{} == KV.H14{} : KV.Hex}, false_true(e))
    case KV.H0{} KV.H15{}:
      e => Empty.absurd({KV.H0{} == KV.H15{} : KV.Hex}, false_true(e))
    case KV.H1{} KV.H0{}:
      e => Empty.absurd({KV.H1{} == KV.H0{} : KV.Hex}, false_true(e))
    case KV.H1{} KV.H1{}:
      e => {==}
    case KV.H1{} KV.H2{}:
      e => Empty.absurd({KV.H1{} == KV.H2{} : KV.Hex}, false_true(e))
    case KV.H1{} KV.H3{}:
      e => Empty.absurd({KV.H1{} == KV.H3{} : KV.Hex}, false_true(e))
    case KV.H1{} KV.H4{}:
      e => Empty.absurd({KV.H1{} == KV.H4{} : KV.Hex}, false_true(e))
    case KV.H1{} KV.H5{}:
      e => Empty.absurd({KV.H1{} == KV.H5{} : KV.Hex}, false_true(e))
    case KV.H1{} KV.H6{}:
      e => Empty.absurd({KV.H1{} == KV.H6{} : KV.Hex}, false_true(e))
    case KV.H1{} KV.H7{}:
      e => Empty.absurd({KV.H1{} == KV.H7{} : KV.Hex}, false_true(e))
    case KV.H1{} KV.H8{}:
      e => Empty.absurd({KV.H1{} == KV.H8{} : KV.Hex}, false_true(e))
    case KV.H1{} KV.H9{}:
      e => Empty.absurd({KV.H1{} == KV.H9{} : KV.Hex}, false_true(e))
    case KV.H1{} KV.H10{}:
      e => Empty.absurd({KV.H1{} == KV.H10{} : KV.Hex}, false_true(e))
    case KV.H1{} KV.H11{}:
      e => Empty.absurd({KV.H1{} == KV.H11{} : KV.Hex}, false_true(e))
    case KV.H1{} KV.H12{}:
      e => Empty.absurd({KV.H1{} == KV.H12{} : KV.Hex}, false_true(e))
    case KV.H1{} KV.H13{}:
      e => Empty.absurd({KV.H1{} == KV.H13{} : KV.Hex}, false_true(e))
    case KV.H1{} KV.H14{}:
      e => Empty.absurd({KV.H1{} == KV.H14{} : KV.Hex}, false_true(e))
    case KV.H1{} KV.H15{}:
      e => Empty.absurd({KV.H1{} == KV.H15{} : KV.Hex}, false_true(e))
    case KV.H2{} KV.H0{}:
      e => Empty.absurd({KV.H2{} == KV.H0{} : KV.Hex}, false_true(e))
    case KV.H2{} KV.H1{}:
      e => Empty.absurd({KV.H2{} == KV.H1{} : KV.Hex}, false_true(e))
    case KV.H2{} KV.H2{}:
      e => {==}
    case KV.H2{} KV.H3{}:
      e => Empty.absurd({KV.H2{} == KV.H3{} : KV.Hex}, false_true(e))
    case KV.H2{} KV.H4{}:
      e => Empty.absurd({KV.H2{} == KV.H4{} : KV.Hex}, false_true(e))
    case KV.H2{} KV.H5{}:
      e => Empty.absurd({KV.H2{} == KV.H5{} : KV.Hex}, false_true(e))
    case KV.H2{} KV.H6{}:
      e => Empty.absurd({KV.H2{} == KV.H6{} : KV.Hex}, false_true(e))
    case KV.H2{} KV.H7{}:
      e => Empty.absurd({KV.H2{} == KV.H7{} : KV.Hex}, false_true(e))
    case KV.H2{} KV.H8{}:
      e => Empty.absurd({KV.H2{} == KV.H8{} : KV.Hex}, false_true(e))
    case KV.H2{} KV.H9{}:
      e => Empty.absurd({KV.H2{} == KV.H9{} : KV.Hex}, false_true(e))
    case KV.H2{} KV.H10{}:
      e => Empty.absurd({KV.H2{} == KV.H10{} : KV.Hex}, false_true(e))
    case KV.H2{} KV.H11{}:
      e => Empty.absurd({KV.H2{} == KV.H11{} : KV.Hex}, false_true(e))
    case KV.H2{} KV.H12{}:
      e => Empty.absurd({KV.H2{} == KV.H12{} : KV.Hex}, false_true(e))
    case KV.H2{} KV.H13{}:
      e => Empty.absurd({KV.H2{} == KV.H13{} : KV.Hex}, false_true(e))
    case KV.H2{} KV.H14{}:
      e => Empty.absurd({KV.H2{} == KV.H14{} : KV.Hex}, false_true(e))
    case KV.H2{} KV.H15{}:
      e => Empty.absurd({KV.H2{} == KV.H15{} : KV.Hex}, false_true(e))
    case KV.H3{} KV.H0{}:
      e => Empty.absurd({KV.H3{} == KV.H0{} : KV.Hex}, false_true(e))
    case KV.H3{} KV.H1{}:
      e => Empty.absurd({KV.H3{} == KV.H1{} : KV.Hex}, false_true(e))
    case KV.H3{} KV.H2{}:
      e => Empty.absurd({KV.H3{} == KV.H2{} : KV.Hex}, false_true(e))
    case KV.H3{} KV.H3{}:
      e => {==}
    case KV.H3{} KV.H4{}:
      e => Empty.absurd({KV.H3{} == KV.H4{} : KV.Hex}, false_true(e))
    case KV.H3{} KV.H5{}:
      e => Empty.absurd({KV.H3{} == KV.H5{} : KV.Hex}, false_true(e))
    case KV.H3{} KV.H6{}:
      e => Empty.absurd({KV.H3{} == KV.H6{} : KV.Hex}, false_true(e))
    case KV.H3{} KV.H7{}:
      e => Empty.absurd({KV.H3{} == KV.H7{} : KV.Hex}, false_true(e))
    case KV.H3{} KV.H8{}:
      e => Empty.absurd({KV.H3{} == KV.H8{} : KV.Hex}, false_true(e))
    case KV.H3{} KV.H9{}:
      e => Empty.absurd({KV.H3{} == KV.H9{} : KV.Hex}, false_true(e))
    case KV.H3{} KV.H10{}:
      e => Empty.absurd({KV.H3{} == KV.H10{} : KV.Hex}, false_true(e))
    case KV.H3{} KV.H11{}:
      e => Empty.absurd({KV.H3{} == KV.H11{} : KV.Hex}, false_true(e))
    case KV.H3{} KV.H12{}:
      e => Empty.absurd({KV.H3{} == KV.H12{} : KV.Hex}, false_true(e))
    case KV.H3{} KV.H13{}:
      e => Empty.absurd({KV.H3{} == KV.H13{} : KV.Hex}, false_true(e))
    case KV.H3{} KV.H14{}:
      e => Empty.absurd({KV.H3{} == KV.H14{} : KV.Hex}, false_true(e))
    case KV.H3{} KV.H15{}:
      e => Empty.absurd({KV.H3{} == KV.H15{} : KV.Hex}, false_true(e))
    case KV.H4{} KV.H0{}:
      e => Empty.absurd({KV.H4{} == KV.H0{} : KV.Hex}, false_true(e))
    case KV.H4{} KV.H1{}:
      e => Empty.absurd({KV.H4{} == KV.H1{} : KV.Hex}, false_true(e))
    case KV.H4{} KV.H2{}:
      e => Empty.absurd({KV.H4{} == KV.H2{} : KV.Hex}, false_true(e))
    case KV.H4{} KV.H3{}:
      e => Empty.absurd({KV.H4{} == KV.H3{} : KV.Hex}, false_true(e))
    case KV.H4{} KV.H4{}:
      e => {==}
    case KV.H4{} KV.H5{}:
      e => Empty.absurd({KV.H4{} == KV.H5{} : KV.Hex}, false_true(e))
    case KV.H4{} KV.H6{}:
      e => Empty.absurd({KV.H4{} == KV.H6{} : KV.Hex}, false_true(e))
    case KV.H4{} KV.H7{}:
      e => Empty.absurd({KV.H4{} == KV.H7{} : KV.Hex}, false_true(e))
    case KV.H4{} KV.H8{}:
      e => Empty.absurd({KV.H4{} == KV.H8{} : KV.Hex}, false_true(e))
    case KV.H4{} KV.H9{}:
      e => Empty.absurd({KV.H4{} == KV.H9{} : KV.Hex}, false_true(e))
    case KV.H4{} KV.H10{}:
      e => Empty.absurd({KV.H4{} == KV.H10{} : KV.Hex}, false_true(e))
    case KV.H4{} KV.H11{}:
      e => Empty.absurd({KV.H4{} == KV.H11{} : KV.Hex}, false_true(e))
    case KV.H4{} KV.H12{}:
      e => Empty.absurd({KV.H4{} == KV.H12{} : KV.Hex}, false_true(e))
    case KV.H4{} KV.H13{}:
      e => Empty.absurd({KV.H4{} == KV.H13{} : KV.Hex}, false_true(e))
    case KV.H4{} KV.H14{}:
      e => Empty.absurd({KV.H4{} == KV.H14{} : KV.Hex}, false_true(e))
    case KV.H4{} KV.H15{}:
      e => Empty.absurd({KV.H4{} == KV.H15{} : KV.Hex}, false_true(e))
    case KV.H5{} KV.H0{}:
      e => Empty.absurd({KV.H5{} == KV.H0{} : KV.Hex}, false_true(e))
    case KV.H5{} KV.H1{}:
      e => Empty.absurd({KV.H5{} == KV.H1{} : KV.Hex}, false_true(e))
    case KV.H5{} KV.H2{}:
      e => Empty.absurd({KV.H5{} == KV.H2{} : KV.Hex}, false_true(e))
    case KV.H5{} KV.H3{}:
      e => Empty.absurd({KV.H5{} == KV.H3{} : KV.Hex}, false_true(e))
    case KV.H5{} KV.H4{}:
      e => Empty.absurd({KV.H5{} == KV.H4{} : KV.Hex}, false_true(e))
    case KV.H5{} KV.H5{}:
      e => {==}
    case KV.H5{} KV.H6{}:
      e => Empty.absurd({KV.H5{} == KV.H6{} : KV.Hex}, false_true(e))
    case KV.H5{} KV.H7{}:
      e => Empty.absurd({KV.H5{} == KV.H7{} : KV.Hex}, false_true(e))
    case KV.H5{} KV.H8{}:
      e => Empty.absurd({KV.H5{} == KV.H8{} : KV.Hex}, false_true(e))
    case KV.H5{} KV.H9{}:
      e => Empty.absurd({KV.H5{} == KV.H9{} : KV.Hex}, false_true(e))
    case KV.H5{} KV.H10{}:
      e => Empty.absurd({KV.H5{} == KV.H10{} : KV.Hex}, false_true(e))
    case KV.H5{} KV.H11{}:
      e => Empty.absurd({KV.H5{} == KV.H11{} : KV.Hex}, false_true(e))
    case KV.H5{} KV.H12{}:
      e => Empty.absurd({KV.H5{} == KV.H12{} : KV.Hex}, false_true(e))
    case KV.H5{} KV.H13{}:
      e => Empty.absurd({KV.H5{} == KV.H13{} : KV.Hex}, false_true(e))
    case KV.H5{} KV.H14{}:
      e => Empty.absurd({KV.H5{} == KV.H14{} : KV.Hex}, false_true(e))
    case KV.H5{} KV.H15{}:
      e => Empty.absurd({KV.H5{} == KV.H15{} : KV.Hex}, false_true(e))
    case KV.H6{} KV.H0{}:
      e => Empty.absurd({KV.H6{} == KV.H0{} : KV.Hex}, false_true(e))
    case KV.H6{} KV.H1{}:
      e => Empty.absurd({KV.H6{} == KV.H1{} : KV.Hex}, false_true(e))
    case KV.H6{} KV.H2{}:
      e => Empty.absurd({KV.H6{} == KV.H2{} : KV.Hex}, false_true(e))
    case KV.H6{} KV.H3{}:
      e => Empty.absurd({KV.H6{} == KV.H3{} : KV.Hex}, false_true(e))
    case KV.H6{} KV.H4{}:
      e => Empty.absurd({KV.H6{} == KV.H4{} : KV.Hex}, false_true(e))
    case KV.H6{} KV.H5{}:
      e => Empty.absurd({KV.H6{} == KV.H5{} : KV.Hex}, false_true(e))
    case KV.H6{} KV.H6{}:
      e => {==}
    case KV.H6{} KV.H7{}:
      e => Empty.absurd({KV.H6{} == KV.H7{} : KV.Hex}, false_true(e))
    case KV.H6{} KV.H8{}:
      e => Empty.absurd({KV.H6{} == KV.H8{} : KV.Hex}, false_true(e))
    case KV.H6{} KV.H9{}:
      e => Empty.absurd({KV.H6{} == KV.H9{} : KV.Hex}, false_true(e))
    case KV.H6{} KV.H10{}:
      e => Empty.absurd({KV.H6{} == KV.H10{} : KV.Hex}, false_true(e))
    case KV.H6{} KV.H11{}:
      e => Empty.absurd({KV.H6{} == KV.H11{} : KV.Hex}, false_true(e))
    case KV.H6{} KV.H12{}:
      e => Empty.absurd({KV.H6{} == KV.H12{} : KV.Hex}, false_true(e))
    case KV.H6{} KV.H13{}:
      e => Empty.absurd({KV.H6{} == KV.H13{} : KV.Hex}, false_true(e))
    case KV.H6{} KV.H14{}:
      e => Empty.absurd({KV.H6{} == KV.H14{} : KV.Hex}, false_true(e))
    case KV.H6{} KV.H15{}:
      e => Empty.absurd({KV.H6{} == KV.H15{} : KV.Hex}, false_true(e))
    case KV.H7{} KV.H0{}:
      e => Empty.absurd({KV.H7{} == KV.H0{} : KV.Hex}, false_true(e))
    case KV.H7{} KV.H1{}:
      e => Empty.absurd({KV.H7{} == KV.H1{} : KV.Hex}, false_true(e))
    case KV.H7{} KV.H2{}:
      e => Empty.absurd({KV.H7{} == KV.H2{} : KV.Hex}, false_true(e))
    case KV.H7{} KV.H3{}:
      e => Empty.absurd({KV.H7{} == KV.H3{} : KV.Hex}, false_true(e))
    case KV.H7{} KV.H4{}:
      e => Empty.absurd({KV.H7{} == KV.H4{} : KV.Hex}, false_true(e))
    case KV.H7{} KV.H5{}:
      e => Empty.absurd({KV.H7{} == KV.H5{} : KV.Hex}, false_true(e))
    case KV.H7{} KV.H6{}:
      e => Empty.absurd({KV.H7{} == KV.H6{} : KV.Hex}, false_true(e))
    case KV.H7{} KV.H7{}:
      e => {==}
    case KV.H7{} KV.H8{}:
      e => Empty.absurd({KV.H7{} == KV.H8{} : KV.Hex}, false_true(e))
    case KV.H7{} KV.H9{}:
      e => Empty.absurd({KV.H7{} == KV.H9{} : KV.Hex}, false_true(e))
    case KV.H7{} KV.H10{}:
      e => Empty.absurd({KV.H7{} == KV.H10{} : KV.Hex}, false_true(e))
    case KV.H7{} KV.H11{}:
      e => Empty.absurd({KV.H7{} == KV.H11{} : KV.Hex}, false_true(e))
    case KV.H7{} KV.H12{}:
      e => Empty.absurd({KV.H7{} == KV.H12{} : KV.Hex}, false_true(e))
    case KV.H7{} KV.H13{}:
      e => Empty.absurd({KV.H7{} == KV.H13{} : KV.Hex}, false_true(e))
    case KV.H7{} KV.H14{}:
      e => Empty.absurd({KV.H7{} == KV.H14{} : KV.Hex}, false_true(e))
    case KV.H7{} KV.H15{}:
      e => Empty.absurd({KV.H7{} == KV.H15{} : KV.Hex}, false_true(e))
    case KV.H8{} KV.H0{}:
      e => Empty.absurd({KV.H8{} == KV.H0{} : KV.Hex}, false_true(e))
    case KV.H8{} KV.H1{}:
      e => Empty.absurd({KV.H8{} == KV.H1{} : KV.Hex}, false_true(e))
    case KV.H8{} KV.H2{}:
      e => Empty.absurd({KV.H8{} == KV.H2{} : KV.Hex}, false_true(e))
    case KV.H8{} KV.H3{}:
      e => Empty.absurd({KV.H8{} == KV.H3{} : KV.Hex}, false_true(e))
    case KV.H8{} KV.H4{}:
      e => Empty.absurd({KV.H8{} == KV.H4{} : KV.Hex}, false_true(e))
    case KV.H8{} KV.H5{}:
      e => Empty.absurd({KV.H8{} == KV.H5{} : KV.Hex}, false_true(e))
    case KV.H8{} KV.H6{}:
      e => Empty.absurd({KV.H8{} == KV.H6{} : KV.Hex}, false_true(e))
    case KV.H8{} KV.H7{}:
      e => Empty.absurd({KV.H8{} == KV.H7{} : KV.Hex}, false_true(e))
    case KV.H8{} KV.H8{}:
      e => {==}
    case KV.H8{} KV.H9{}:
      e => Empty.absurd({KV.H8{} == KV.H9{} : KV.Hex}, false_true(e))
    case KV.H8{} KV.H10{}:
      e => Empty.absurd({KV.H8{} == KV.H10{} : KV.Hex}, false_true(e))
    case KV.H8{} KV.H11{}:
      e => Empty.absurd({KV.H8{} == KV.H11{} : KV.Hex}, false_true(e))
    case KV.H8{} KV.H12{}:
      e => Empty.absurd({KV.H8{} == KV.H12{} : KV.Hex}, false_true(e))
    case KV.H8{} KV.H13{}:
      e => Empty.absurd({KV.H8{} == KV.H13{} : KV.Hex}, false_true(e))
    case KV.H8{} KV.H14{}:
      e => Empty.absurd({KV.H8{} == KV.H14{} : KV.Hex}, false_true(e))
    case KV.H8{} KV.H15{}:
      e => Empty.absurd({KV.H8{} == KV.H15{} : KV.Hex}, false_true(e))
    case KV.H9{} KV.H0{}:
      e => Empty.absurd({KV.H9{} == KV.H0{} : KV.Hex}, false_true(e))
    case KV.H9{} KV.H1{}:
      e => Empty.absurd({KV.H9{} == KV.H1{} : KV.Hex}, false_true(e))
    case KV.H9{} KV.H2{}:
      e => Empty.absurd({KV.H9{} == KV.H2{} : KV.Hex}, false_true(e))
    case KV.H9{} KV.H3{}:
      e => Empty.absurd({KV.H9{} == KV.H3{} : KV.Hex}, false_true(e))
    case KV.H9{} KV.H4{}:
      e => Empty.absurd({KV.H9{} == KV.H4{} : KV.Hex}, false_true(e))
    case KV.H9{} KV.H5{}:
      e => Empty.absurd({KV.H9{} == KV.H5{} : KV.Hex}, false_true(e))
    case KV.H9{} KV.H6{}:
      e => Empty.absurd({KV.H9{} == KV.H6{} : KV.Hex}, false_true(e))
    case KV.H9{} KV.H7{}:
      e => Empty.absurd({KV.H9{} == KV.H7{} : KV.Hex}, false_true(e))
    case KV.H9{} KV.H8{}:
      e => Empty.absurd({KV.H9{} == KV.H8{} : KV.Hex}, false_true(e))
    case KV.H9{} KV.H9{}:
      e => {==}
    case KV.H9{} KV.H10{}:
      e => Empty.absurd({KV.H9{} == KV.H10{} : KV.Hex}, false_true(e))
    case KV.H9{} KV.H11{}:
      e => Empty.absurd({KV.H9{} == KV.H11{} : KV.Hex}, false_true(e))
    case KV.H9{} KV.H12{}:
      e => Empty.absurd({KV.H9{} == KV.H12{} : KV.Hex}, false_true(e))
    case KV.H9{} KV.H13{}:
      e => Empty.absurd({KV.H9{} == KV.H13{} : KV.Hex}, false_true(e))
    case KV.H9{} KV.H14{}:
      e => Empty.absurd({KV.H9{} == KV.H14{} : KV.Hex}, false_true(e))
    case KV.H9{} KV.H15{}:
      e => Empty.absurd({KV.H9{} == KV.H15{} : KV.Hex}, false_true(e))
    case KV.H10{} KV.H0{}:
      e => Empty.absurd({KV.H10{} == KV.H0{} : KV.Hex}, false_true(e))
    case KV.H10{} KV.H1{}:
      e => Empty.absurd({KV.H10{} == KV.H1{} : KV.Hex}, false_true(e))
    case KV.H10{} KV.H2{}:
      e => Empty.absurd({KV.H10{} == KV.H2{} : KV.Hex}, false_true(e))
    case KV.H10{} KV.H3{}:
      e => Empty.absurd({KV.H10{} == KV.H3{} : KV.Hex}, false_true(e))
    case KV.H10{} KV.H4{}:
      e => Empty.absurd({KV.H10{} == KV.H4{} : KV.Hex}, false_true(e))
    case KV.H10{} KV.H5{}:
      e => Empty.absurd({KV.H10{} == KV.H5{} : KV.Hex}, false_true(e))
    case KV.H10{} KV.H6{}:
      e => Empty.absurd({KV.H10{} == KV.H6{} : KV.Hex}, false_true(e))
    case KV.H10{} KV.H7{}:
      e => Empty.absurd({KV.H10{} == KV.H7{} : KV.Hex}, false_true(e))
    case KV.H10{} KV.H8{}:
      e => Empty.absurd({KV.H10{} == KV.H8{} : KV.Hex}, false_true(e))
    case KV.H10{} KV.H9{}:
      e => Empty.absurd({KV.H10{} == KV.H9{} : KV.Hex}, false_true(e))
    case KV.H10{} KV.H10{}:
      e => {==}
    case KV.H10{} KV.H11{}:
      e => Empty.absurd({KV.H10{} == KV.H11{} : KV.Hex}, false_true(e))
    case KV.H10{} KV.H12{}:
      e => Empty.absurd({KV.H10{} == KV.H12{} : KV.Hex}, false_true(e))
    case KV.H10{} KV.H13{}:
      e => Empty.absurd({KV.H10{} == KV.H13{} : KV.Hex}, false_true(e))
    case KV.H10{} KV.H14{}:
      e => Empty.absurd({KV.H10{} == KV.H14{} : KV.Hex}, false_true(e))
    case KV.H10{} KV.H15{}:
      e => Empty.absurd({KV.H10{} == KV.H15{} : KV.Hex}, false_true(e))
    case KV.H11{} KV.H0{}:
      e => Empty.absurd({KV.H11{} == KV.H0{} : KV.Hex}, false_true(e))
    case KV.H11{} KV.H1{}:
      e => Empty.absurd({KV.H11{} == KV.H1{} : KV.Hex}, false_true(e))
    case KV.H11{} KV.H2{}:
      e => Empty.absurd({KV.H11{} == KV.H2{} : KV.Hex}, false_true(e))
    case KV.H11{} KV.H3{}:
      e => Empty.absurd({KV.H11{} == KV.H3{} : KV.Hex}, false_true(e))
    case KV.H11{} KV.H4{}:
      e => Empty.absurd({KV.H11{} == KV.H4{} : KV.Hex}, false_true(e))
    case KV.H11{} KV.H5{}:
      e => Empty.absurd({KV.H11{} == KV.H5{} : KV.Hex}, false_true(e))
    case KV.H11{} KV.H6{}:
      e => Empty.absurd({KV.H11{} == KV.H6{} : KV.Hex}, false_true(e))
    case KV.H11{} KV.H7{}:
      e => Empty.absurd({KV.H11{} == KV.H7{} : KV.Hex}, false_true(e))
    case KV.H11{} KV.H8{}:
      e => Empty.absurd({KV.H11{} == KV.H8{} : KV.Hex}, false_true(e))
    case KV.H11{} KV.H9{}:
      e => Empty.absurd({KV.H11{} == KV.H9{} : KV.Hex}, false_true(e))
    case KV.H11{} KV.H10{}:
      e => Empty.absurd({KV.H11{} == KV.H10{} : KV.Hex}, false_true(e))
    case KV.H11{} KV.H11{}:
      e => {==}
    case KV.H11{} KV.H12{}:
      e => Empty.absurd({KV.H11{} == KV.H12{} : KV.Hex}, false_true(e))
    case KV.H11{} KV.H13{}:
      e => Empty.absurd({KV.H11{} == KV.H13{} : KV.Hex}, false_true(e))
    case KV.H11{} KV.H14{}:
      e => Empty.absurd({KV.H11{} == KV.H14{} : KV.Hex}, false_true(e))
    case KV.H11{} KV.H15{}:
      e => Empty.absurd({KV.H11{} == KV.H15{} : KV.Hex}, false_true(e))
    case KV.H12{} KV.H0{}:
      e => Empty.absurd({KV.H12{} == KV.H0{} : KV.Hex}, false_true(e))
    case KV.H12{} KV.H1{}:
      e => Empty.absurd({KV.H12{} == KV.H1{} : KV.Hex}, false_true(e))
    case KV.H12{} KV.H2{}:
      e => Empty.absurd({KV.H12{} == KV.H2{} : KV.Hex}, false_true(e))
    case KV.H12{} KV.H3{}:
      e => Empty.absurd({KV.H12{} == KV.H3{} : KV.Hex}, false_true(e))
    case KV.H12{} KV.H4{}:
      e => Empty.absurd({KV.H12{} == KV.H4{} : KV.Hex}, false_true(e))
    case KV.H12{} KV.H5{}:
      e => Empty.absurd({KV.H12{} == KV.H5{} : KV.Hex}, false_true(e))
    case KV.H12{} KV.H6{}:
      e => Empty.absurd({KV.H12{} == KV.H6{} : KV.Hex}, false_true(e))
    case KV.H12{} KV.H7{}:
      e => Empty.absurd({KV.H12{} == KV.H7{} : KV.Hex}, false_true(e))
    case KV.H12{} KV.H8{}:
      e => Empty.absurd({KV.H12{} == KV.H8{} : KV.Hex}, false_true(e))
    case KV.H12{} KV.H9{}:
      e => Empty.absurd({KV.H12{} == KV.H9{} : KV.Hex}, false_true(e))
    case KV.H12{} KV.H10{}:
      e => Empty.absurd({KV.H12{} == KV.H10{} : KV.Hex}, false_true(e))
    case KV.H12{} KV.H11{}:
      e => Empty.absurd({KV.H12{} == KV.H11{} : KV.Hex}, false_true(e))
    case KV.H12{} KV.H12{}:
      e => {==}
    case KV.H12{} KV.H13{}:
      e => Empty.absurd({KV.H12{} == KV.H13{} : KV.Hex}, false_true(e))
    case KV.H12{} KV.H14{}:
      e => Empty.absurd({KV.H12{} == KV.H14{} : KV.Hex}, false_true(e))
    case KV.H12{} KV.H15{}:
      e => Empty.absurd({KV.H12{} == KV.H15{} : KV.Hex}, false_true(e))
    case KV.H13{} KV.H0{}:
      e => Empty.absurd({KV.H13{} == KV.H0{} : KV.Hex}, false_true(e))
    case KV.H13{} KV.H1{}:
      e => Empty.absurd({KV.H13{} == KV.H1{} : KV.Hex}, false_true(e))
    case KV.H13{} KV.H2{}:
      e => Empty.absurd({KV.H13{} == KV.H2{} : KV.Hex}, false_true(e))
    case KV.H13{} KV.H3{}:
      e => Empty.absurd({KV.H13{} == KV.H3{} : KV.Hex}, false_true(e))
    case KV.H13{} KV.H4{}:
      e => Empty.absurd({KV.H13{} == KV.H4{} : KV.Hex}, false_true(e))
    case KV.H13{} KV.H5{}:
      e => Empty.absurd({KV.H13{} == KV.H5{} : KV.Hex}, false_true(e))
    case KV.H13{} KV.H6{}:
      e => Empty.absurd({KV.H13{} == KV.H6{} : KV.Hex}, false_true(e))
    case KV.H13{} KV.H7{}:
      e => Empty.absurd({KV.H13{} == KV.H7{} : KV.Hex}, false_true(e))
    case KV.H13{} KV.H8{}:
      e => Empty.absurd({KV.H13{} == KV.H8{} : KV.Hex}, false_true(e))
    case KV.H13{} KV.H9{}:
      e => Empty.absurd({KV.H13{} == KV.H9{} : KV.Hex}, false_true(e))
    case KV.H13{} KV.H10{}:
      e => Empty.absurd({KV.H13{} == KV.H10{} : KV.Hex}, false_true(e))
    case KV.H13{} KV.H11{}:
      e => Empty.absurd({KV.H13{} == KV.H11{} : KV.Hex}, false_true(e))
    case KV.H13{} KV.H12{}:
      e => Empty.absurd({KV.H13{} == KV.H12{} : KV.Hex}, false_true(e))
    case KV.H13{} KV.H13{}:
      e => {==}
    case KV.H13{} KV.H14{}:
      e => Empty.absurd({KV.H13{} == KV.H14{} : KV.Hex}, false_true(e))
    case KV.H13{} KV.H15{}:
      e => Empty.absurd({KV.H13{} == KV.H15{} : KV.Hex}, false_true(e))
    case KV.H14{} KV.H0{}:
      e => Empty.absurd({KV.H14{} == KV.H0{} : KV.Hex}, false_true(e))
    case KV.H14{} KV.H1{}:
      e => Empty.absurd({KV.H14{} == KV.H1{} : KV.Hex}, false_true(e))
    case KV.H14{} KV.H2{}:
      e => Empty.absurd({KV.H14{} == KV.H2{} : KV.Hex}, false_true(e))
    case KV.H14{} KV.H3{}:
      e => Empty.absurd({KV.H14{} == KV.H3{} : KV.Hex}, false_true(e))
    case KV.H14{} KV.H4{}:
      e => Empty.absurd({KV.H14{} == KV.H4{} : KV.Hex}, false_true(e))
    case KV.H14{} KV.H5{}:
      e => Empty.absurd({KV.H14{} == KV.H5{} : KV.Hex}, false_true(e))
    case KV.H14{} KV.H6{}:
      e => Empty.absurd({KV.H14{} == KV.H6{} : KV.Hex}, false_true(e))
    case KV.H14{} KV.H7{}:
      e => Empty.absurd({KV.H14{} == KV.H7{} : KV.Hex}, false_true(e))
    case KV.H14{} KV.H8{}:
      e => Empty.absurd({KV.H14{} == KV.H8{} : KV.Hex}, false_true(e))
    case KV.H14{} KV.H9{}:
      e => Empty.absurd({KV.H14{} == KV.H9{} : KV.Hex}, false_true(e))
    case KV.H14{} KV.H10{}:
      e => Empty.absurd({KV.H14{} == KV.H10{} : KV.Hex}, false_true(e))
    case KV.H14{} KV.H11{}:
      e => Empty.absurd({KV.H14{} == KV.H11{} : KV.Hex}, false_true(e))
    case KV.H14{} KV.H12{}:
      e => Empty.absurd({KV.H14{} == KV.H12{} : KV.Hex}, false_true(e))
    case KV.H14{} KV.H13{}:
      e => Empty.absurd({KV.H14{} == KV.H13{} : KV.Hex}, false_true(e))
    case KV.H14{} KV.H14{}:
      e => {==}
    case KV.H14{} KV.H15{}:
      e => Empty.absurd({KV.H14{} == KV.H15{} : KV.Hex}, false_true(e))
    case KV.H15{} KV.H0{}:
      e => Empty.absurd({KV.H15{} == KV.H0{} : KV.Hex}, false_true(e))
    case KV.H15{} KV.H1{}:
      e => Empty.absurd({KV.H15{} == KV.H1{} : KV.Hex}, false_true(e))
    case KV.H15{} KV.H2{}:
      e => Empty.absurd({KV.H15{} == KV.H2{} : KV.Hex}, false_true(e))
    case KV.H15{} KV.H3{}:
      e => Empty.absurd({KV.H15{} == KV.H3{} : KV.Hex}, false_true(e))
    case KV.H15{} KV.H4{}:
      e => Empty.absurd({KV.H15{} == KV.H4{} : KV.Hex}, false_true(e))
    case KV.H15{} KV.H5{}:
      e => Empty.absurd({KV.H15{} == KV.H5{} : KV.Hex}, false_true(e))
    case KV.H15{} KV.H6{}:
      e => Empty.absurd({KV.H15{} == KV.H6{} : KV.Hex}, false_true(e))
    case KV.H15{} KV.H7{}:
      e => Empty.absurd({KV.H15{} == KV.H7{} : KV.Hex}, false_true(e))
    case KV.H15{} KV.H8{}:
      e => Empty.absurd({KV.H15{} == KV.H8{} : KV.Hex}, false_true(e))
    case KV.H15{} KV.H9{}:
      e => Empty.absurd({KV.H15{} == KV.H9{} : KV.Hex}, false_true(e))
    case KV.H15{} KV.H10{}:
      e => Empty.absurd({KV.H15{} == KV.H10{} : KV.Hex}, false_true(e))
    case KV.H15{} KV.H11{}:
      e => Empty.absurd({KV.H15{} == KV.H11{} : KV.Hex}, false_true(e))
    case KV.H15{} KV.H12{}:
      e => Empty.absurd({KV.H15{} == KV.H12{} : KV.Hex}, false_true(e))
    case KV.H15{} KV.H13{}:
      e => Empty.absurd({KV.H15{} == KV.H13{} : KV.Hex}, false_true(e))
    case KV.H15{} KV.H14{}:
      e => Empty.absurd({KV.H15{} == KV.H14{} : KV.Hex}, false_true(e))
    case KV.H15{} KV.H15{}:
      e => {==}
# END gen_trie: digits

# Walks
# =====
# get, set and del walk the hex digits of a key's hash (tget_k, tmod_h);
# the lemmas reason about tget_h, the bucket where a walk ends, by
# induction on the depth: a step takes the digit as a parameter, so that a
# match can take it apart. A node has 16 children, so a step splits 16
# ways, and 256 ways where two walks meet; tools/gen_trie.py writes those
# steps out.

# whether two walks of depth d take the same digits
def dsame(d: Nat, x1: KV.Hex, +h1: U32, x2: KV.Hex, +h2: U32) -> Bool:
  match d:
    case 0n:
      True{}
    case 1n+p:
      Bool.and(KV.hex_eq(x1, x2), dsame(p, KV.hex(KV.shr4(h1)), KV.shr4(h1), KV.hex(KV.shr4(h2)), KV.shr4(h2)))

# a walk through the empty trie ends in the empty bucket
def tget_h_tip(-V: Data, d: Nat, -x: KV.Hex, -h: U32) -> {KV.tget_h(V, d, KV.Tip{}, x, h) == KV.Tip{} : KV.Trie<V>}:
  match d:
    case 0n:
      {==}
    case 1n+p:
      {==}

# BEGIN gen_trie: tget_k
# get walks with tget_k, which reads the bucket where the walk ends: the
# bucket lookup after tget_h, by induction on the depth
def tget_k_eq(-V: Data, d: Nat, t: KV.Trie<V>, x: KV.Hex, +h: U32, +k: String) -> {KV.bget(V, k, KV.tget_h(V, d, t, x, h)) == KV.tget_k(V, d, t, x, h, k) : Maybe<&2, V>}:
  match d t x:
    case 0n t0 _:
      {==}
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H0{}:
      tget_k_eq(V, p, c0, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H1{}:
      tget_k_eq(V, p, c1, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H2{}:
      tget_k_eq(V, p, c2, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H3{}:
      tget_k_eq(V, p, c3, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H4{}:
      tget_k_eq(V, p, c4, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H5{}:
      tget_k_eq(V, p, c5, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H6{}:
      tget_k_eq(V, p, c6, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H7{}:
      tget_k_eq(V, p, c7, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H8{}:
      tget_k_eq(V, p, c8, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H9{}:
      tget_k_eq(V, p, c9, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H10{}:
      tget_k_eq(V, p, c10, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H11{}:
      tget_k_eq(V, p, c11, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H12{}:
      tget_k_eq(V, p, c12, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H13{}:
      tget_k_eq(V, p, c13, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H14{}:
      tget_k_eq(V, p, c14, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H15{}:
      tget_k_eq(V, p, c15, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Tip{} _:
      {==}
    case 1n+p KV.Ent{a, b, c} _:
      {==}
# END gen_trie: tget_k

# a copy of a whole string is the string: what KV.bget_c answers
def take_len(s: String) -> {s == String.take(s, String.length(s)) : String}:
  match s:
    case SNil{}:
      {==}
    case SCon{h, r}:
      Equal.cong(String, String, x => SCon{h, x}, r, String.take(r, String.length(r)), take_len(r))

# bget_c answers as bget: the copy is the value
def bget_c_go_eq(+k: String, b: KV.Trie<String>, same: Bool) -> {KV.bget.go(String, k, b, same) == KV.bget_c.go(k, b, same) : Maybe<&2, String>}:
  match b same:
    case KV.Ent{key, v, rest} True{}:
      Equal.cong(String, Maybe<&2, String>, x => Some{x}, v, String.take(v, String.length(v)), take_len(v))
    case KV.Ent{key, v, +rest} False{}:
      bget_c_go_eq(k, rest, KV.bhead(String, k, rest))
    case KV.Tip{} _:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} _:
      {==}

def bget_c_eq(+k: String, +b: KV.Trie<String>) -> {KV.bget(String, k, b) == KV.bget_c(k, b) : Maybe<&2, String>}:
  bget_c_go_eq(k, b, KV.bhead(String, k, b))

# BEGIN gen_trie: tget_kc
# GET reads with tget_kc, which answers a copy of the value: the same
# answer as tget_k (bget_c_eq), by induction on the depth
def tget_kc_eq(d: Nat, t: KV.Trie<String>, x: KV.Hex, +h: U32, +k: String) -> {KV.tget_k(String, d, t, x, h, k) == KV.tget_kc(d, t, x, h, k) : Maybe<&2, String>}:
  match d t x:
    case 0n t0 _:
      bget_c_eq(k, t0)
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H0{}:
      tget_kc_eq(p, c0, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H1{}:
      tget_kc_eq(p, c1, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H2{}:
      tget_kc_eq(p, c2, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H3{}:
      tget_kc_eq(p, c3, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H4{}:
      tget_kc_eq(p, c4, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H5{}:
      tget_kc_eq(p, c5, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H6{}:
      tget_kc_eq(p, c6, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H7{}:
      tget_kc_eq(p, c7, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H8{}:
      tget_kc_eq(p, c8, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H9{}:
      tget_kc_eq(p, c9, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H10{}:
      tget_kc_eq(p, c10, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H11{}:
      tget_kc_eq(p, c11, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H12{}:
      tget_kc_eq(p, c12, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H13{}:
      tget_kc_eq(p, c13, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H14{}:
      tget_kc_eq(p, c14, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H15{}:
      tget_kc_eq(p, c15, KV.hex(KV.shr4(h)), KV.shr4(h), k)
    case 1n+p KV.Tip{} _:
      {==}
    case 1n+p KV.Ent{a, b, c} _:
      {==}
# END gen_trie: tget_kc

# BEGIN gen_trie: same
# a read of the bucket that a walk modifies sees the modification
def tget_tmod_same(-V: Data, d: Nat, +t: KV.Trie<V>, x: KV.Hex, +h: U32, +op: KV.Op<V>) -> {KV.bapply(V, op, KV.tget_h(V, d, t, x, h)) == KV.tget_h(V, d, KV.tmod_h(V, d, t, x, h, op), x, h) : KV.Trie<V>}:
  match d t x:
    case 0n t0 _:
      {==}
    case 1n++p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H0{}:
      tget_tmod_same(V, p, c0, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H1{}:
      tget_tmod_same(V, p, c1, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H2{}:
      tget_tmod_same(V, p, c2, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H3{}:
      tget_tmod_same(V, p, c3, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H4{}:
      tget_tmod_same(V, p, c4, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H5{}:
      tget_tmod_same(V, p, c5, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H6{}:
      tget_tmod_same(V, p, c6, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H7{}:
      tget_tmod_same(V, p, c7, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H8{}:
      tget_tmod_same(V, p, c8, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H9{}:
      tget_tmod_same(V, p, c9, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H10{}:
      tget_tmod_same(V, p, c10, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H11{}:
      tget_tmod_same(V, p, c11, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H12{}:
      tget_tmod_same(V, p, c12, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H13{}:
      tget_tmod_same(V, p, c13, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H14{}:
      tget_tmod_same(V, p, c14, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H15{}:
      tget_tmod_same(V, p, c15, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Tip{} KV.H0{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Tip{} KV.H1{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Tip{} KV.H2{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Tip{} KV.H3{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Tip{} KV.H4{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Tip{} KV.H5{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Tip{} KV.H6{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Tip{} KV.H7{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Tip{} KV.H8{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Tip{} KV.H9{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Tip{} KV.H10{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Tip{} KV.H11{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Tip{} KV.H12{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Tip{} KV.H13{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Tip{} KV.H14{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Tip{} KV.H15{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Ent{a, b, c} KV.H0{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Ent{a, b, c} KV.H1{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Ent{a, b, c} KV.H2{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Ent{a, b, c} KV.H3{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Ent{a, b, c} KV.H4{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Ent{a, b, c} KV.H5{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Ent{a, b, c} KV.H6{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Ent{a, b, c} KV.H7{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Ent{a, b, c} KV.H8{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Ent{a, b, c} KV.H9{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Ent{a, b, c} KV.H10{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Ent{a, b, c} KV.H11{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Ent{a, b, c} KV.H12{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Ent{a, b, c} KV.H13{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Ent{a, b, c} KV.H14{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
    case 1n++p KV.Ent{a, b, c} KV.H15{}:
      %tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h)) : {KV.bapply(V, op, _) == KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.hex(KV.shr4(h)), KV.shr4(h)) : KV.Trie<V>}
      tget_tmod_same(V, p, KV.Tip{}, KV.hex(KV.shr4(h)), KV.shr4(h), op)
# END gen_trie: same

# BEGIN gen_trie: walk_same
# a step of walk_same: both walks take the digit x here
def walk_same_step(-V: Data, -p: Nat, +t: KV.Trie<V>, x: KV.Hex, +h1: U32, +h2: U32, ih: @u: KV.Trie<V> -> {dsame(p, KV.hex(KV.shr4(h1)), KV.shr4(h1), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == True{} : Bool} -> {KV.tget_h(V, p, u, KV.hex(KV.shr4(h1)), KV.shr4(h1)) == KV.tget_h(V, p, u, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : KV.Trie<V>}) -> {dsame(p, KV.hex(KV.shr4(h1)), KV.shr4(h1), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == True{} : Bool} -> {KV.tget_h(V, 1n+p, t, x, h1) == KV.tget_h(V, 1n+p, t, x, h2) : KV.Trie<V>}:
  match t x:
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H0{}:
      e => ih(c0)(e)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H1{}:
      e => ih(c1)(e)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H2{}:
      e => ih(c2)(e)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H3{}:
      e => ih(c3)(e)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H4{}:
      e => ih(c4)(e)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H5{}:
      e => ih(c5)(e)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H6{}:
      e => ih(c6)(e)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H7{}:
      e => ih(c7)(e)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H8{}:
      e => ih(c8)(e)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H9{}:
      e => ih(c9)(e)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H10{}:
      e => ih(c10)(e)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H11{}:
      e => ih(c11)(e)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H12{}:
      e => ih(c12)(e)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H13{}:
      e => ih(c13)(e)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H14{}:
      e => ih(c14)(e)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H15{}:
      e => ih(c15)(e)
    case KV.Tip{} _:
      e => {==}
    case KV.Ent{a, b, c} _:
      e => {==}
# END gen_trie: walk_same

def same_step(-V: Data, -p: Nat, +t: KV.Trie<V>, +x1: KV.Hex, +h1: U32, +x2: KV.Hex, +h2: U32, c: Bool, ih: @u: KV.Trie<V> -> {dsame(p, KV.hex(KV.shr4(h1)), KV.shr4(h1), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == True{} : Bool} -> {KV.tget_h(V, p, u, KV.hex(KV.shr4(h1)), KV.shr4(h1)) == KV.tget_h(V, p, u, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : KV.Trie<V>})
  -> {c == KV.hex_eq(x1, x2) : Bool}
  -> {Bool.and(c, dsame(p, KV.hex(KV.shr4(h1)), KV.shr4(h1), KV.hex(KV.shr4(h2)), KV.shr4(h2))) == True{} : Bool}
  -> {KV.tget_h(V, 1n+p, t, x1, h1) == KV.tget_h(V, 1n+p, t, x2, h2) : KV.Trie<V>}:
  match c:
    case False{}:
      ec => e => Empty.absurd({KV.tget_h(V, 1n+p, t, x1, h1) == KV.tget_h(V, 1n+p, t, x2, h2) : KV.Trie<V>}, false_true(e))
    case True{}:
      ec => e => %hex_eq_sound(x1, x2)(Equal.sym(Bool, True{}, KV.hex_eq(x1, x2), ec)) : {KV.tget_h(V, 1n+p, t, x1, h1) == KV.tget_h(V, 1n+p, t, _, h2) : KV.Trie<V>}
                 walk_same_step(V, p, t, x1, h1, h2, ih)(e)

# two walks that take the same digits end in the same bucket
def walk_same(-V: Data, d: Nat, +t: KV.Trie<V>, +x1: KV.Hex, +h1: U32, +x2: KV.Hex, +h2: U32) -> {dsame(d, x1, h1, x2, h2) == True{} : Bool} -> {KV.tget_h(V, d, t, x1, h1) == KV.tget_h(V, d, t, x2, h2) : KV.Trie<V>}:
  match d:
    case 0n:
      e => {==}
    case 1n+p:
      same_step(V, p, t, x1, h1, x2, h2, KV.hex_eq(x1, x2), u => walk_same(V, p, u, KV.hex(KV.shr4(h1)), KV.shr4(h1), KV.hex(KV.shr4(h2)), KV.shr4(h2)))({==})

# BEGIN gen_trie: other
# a step of tget_tmod_other where the write and the read take the same
# digit x here: they go to the same child
def same_digit_step(-V: Data, +p: Nat, +t: KV.Trie<V>, x: KV.Hex, +h1: U32, +h2: U32, +op: KV.Op<V>, ih: @u: KV.Trie<V> -> {dsame(p, KV.hex(KV.shr4(h1)), KV.shr4(h1), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == False{} : Bool} -> {KV.tget_h(V, p, KV.tmod_h(V, p, u, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == KV.tget_h(V, p, u, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : KV.Trie<V>}) -> {dsame(p, KV.hex(KV.shr4(h1)), KV.shr4(h1), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == False{} : Bool} -> {KV.tget_h(V, 1n+p, KV.tmod_h(V, 1n+p, t, x, h1, op), x, h2) == KV.tget_h(V, 1n+p, t, x, h2) : KV.Trie<V>}:
  match t x:
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H0{}:
      e => ih(c0)(e)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H1{}:
      e => ih(c1)(e)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H2{}:
      e => ih(c2)(e)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H3{}:
      e => ih(c3)(e)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H4{}:
      e => ih(c4)(e)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H5{}:
      e => ih(c5)(e)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H6{}:
      e => ih(c6)(e)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H7{}:
      e => ih(c7)(e)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H8{}:
      e => ih(c8)(e)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H9{}:
      e => ih(c9)(e)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H10{}:
      e => ih(c10)(e)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H11{}:
      e => ih(c11)(e)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H12{}:
      e => ih(c12)(e)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H13{}:
      e => ih(c13)(e)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H14{}:
      e => ih(c14)(e)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H15{}:
      e => ih(c15)(e)
    case KV.Tip{} KV.H0{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)
    case KV.Tip{} KV.H1{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)
    case KV.Tip{} KV.H2{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)
    case KV.Tip{} KV.H3{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)
    case KV.Tip{} KV.H4{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)
    case KV.Tip{} KV.H5{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)
    case KV.Tip{} KV.H6{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)
    case KV.Tip{} KV.H7{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)
    case KV.Tip{} KV.H8{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)
    case KV.Tip{} KV.H9{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)
    case KV.Tip{} KV.H10{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)
    case KV.Tip{} KV.H11{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)
    case KV.Tip{} KV.H12{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)
    case KV.Tip{} KV.H13{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)
    case KV.Tip{} KV.H14{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)
    case KV.Tip{} KV.H15{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)
    case KV.Ent{a, b, c} KV.H0{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)
    case KV.Ent{a, b, c} KV.H1{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)
    case KV.Ent{a, b, c} KV.H2{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)
    case KV.Ent{a, b, c} KV.H3{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)
    case KV.Ent{a, b, c} KV.H4{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)
    case KV.Ent{a, b, c} KV.H5{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)
    case KV.Ent{a, b, c} KV.H6{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)
    case KV.Ent{a, b, c} KV.H7{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)
    case KV.Ent{a, b, c} KV.H8{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)
    case KV.Ent{a, b, c} KV.H9{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)
    case KV.Ent{a, b, c} KV.H10{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)
    case KV.Ent{a, b, c} KV.H11{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)
    case KV.Ent{a, b, c} KV.H12{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)
    case KV.Ent{a, b, c} KV.H13{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)
    case KV.Ent{a, b, c} KV.H14{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)
    case KV.Ent{a, b, c} KV.H15{}:
      e => %tget_h_tip(V, p, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : {KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{}, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == _ : KV.Trie<V>}
           ih(KV.Tip{})(e)

# a write through an empty subtrie writes through a node of empty subtries
def n1_tip(-V: Data, -p: Nat, x: KV.Hex, -h: U32, -op: KV.Op<V>) -> {KV.tmod_h(V, 1n+p, KV.Node{KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}}, x, h, op) == KV.tmod_h(V, 1n+p, KV.Tip{}, x, h, op) : KV.Trie<V>}:
  match x:
    case KV.H0{}:
      {==}
    case KV.H1{}:
      {==}
    case KV.H2{}:
      {==}
    case KV.H3{}:
      {==}
    case KV.H4{}:
      {==}
    case KV.H5{}:
      {==}
    case KV.H6{}:
      {==}
    case KV.H7{}:
      {==}
    case KV.H8{}:
      {==}
    case KV.H9{}:
      {==}
    case KV.H10{}:
      {==}
    case KV.H11{}:
      {==}
    case KV.H12{}:
      {==}
    case KV.H13{}:
      {==}
    case KV.H14{}:
      {==}
    case KV.H15{}:
      {==}

def n1_ent(-V: Data, -p: Nat, -a: String, -b: V, -c: KV.Trie<V>, x: KV.Hex, -h: U32, -op: KV.Op<V>) -> {KV.tmod_h(V, 1n+p, KV.Node{KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}}, x, h, op) == KV.tmod_h(V, 1n+p, KV.Ent{a, b, c}, x, h, op) : KV.Trie<V>}:
  match x:
    case KV.H0{}:
      {==}
    case KV.H1{}:
      {==}
    case KV.H2{}:
      {==}
    case KV.H3{}:
      {==}
    case KV.H4{}:
      {==}
    case KV.H5{}:
      {==}
    case KV.H6{}:
      {==}
    case KV.H7{}:
      {==}
    case KV.H8{}:
      {==}
    case KV.H9{}:
      {==}
    case KV.H10{}:
      {==}
    case KV.H11{}:
      {==}
    case KV.H12{}:
      {==}
    case KV.H13{}:
      {==}
    case KV.H14{}:
      {==}
    case KV.H15{}:
      {==}

# a read through a node of empty subtries reads the empty bucket
def n2_tip(-V: Data, +p: Nat, x: KV.Hex, +h: U32) -> {KV.tget_h(V, 1n+p, KV.Node{KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}}, x, h) == KV.Tip{} : KV.Trie<V>}:
  match x:
    case KV.H0{}:
      tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h))
    case KV.H1{}:
      tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h))
    case KV.H2{}:
      tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h))
    case KV.H3{}:
      tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h))
    case KV.H4{}:
      tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h))
    case KV.H5{}:
      tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h))
    case KV.H6{}:
      tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h))
    case KV.H7{}:
      tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h))
    case KV.H8{}:
      tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h))
    case KV.H9{}:
      tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h))
    case KV.H10{}:
      tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h))
    case KV.H11{}:
      tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h))
    case KV.H12{}:
      tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h))
    case KV.H13{}:
      tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h))
    case KV.H14{}:
      tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h))
    case KV.H15{}:
      tget_h_tip(V, p, KV.hex(KV.shr4(h)), KV.shr4(h))

# a write through child x1 of a node leaves the read of child x2
def upd_other_node(-V: Data, -p: Nat, -c0: KV.Trie<V>, -c1: KV.Trie<V>, -c2: KV.Trie<V>, -c3: KV.Trie<V>, -c4: KV.Trie<V>, -c5: KV.Trie<V>, -c6: KV.Trie<V>, -c7: KV.Trie<V>, -c8: KV.Trie<V>, -c9: KV.Trie<V>, -c10: KV.Trie<V>, -c11: KV.Trie<V>, -c12: KV.Trie<V>, -c13: KV.Trie<V>, -c14: KV.Trie<V>, -c15: KV.Trie<V>, x1: KV.Hex, -h1: U32, x2: KV.Hex, -h2: U32, -op: KV.Op<V>) -> {KV.hex_eq(x1, x2) == False{} : Bool} -> {KV.tget_h(V, 1n+p, KV.tmod_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, x1, h1, op), x2, h2) == KV.tget_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, x2, h2) : KV.Trie<V>}:
  match x1 x2:
    case KV.H0{} KV.H0{}:
      e => Empty.absurd({KV.tget_h(V, 1n+p, KV.tmod_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H0{}, h1, op), KV.H0{}, h2) == KV.tget_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H0{}, h2) : KV.Trie<V>}, true_false(e))
    case KV.H0{} KV.H1{}:
      e => {==}
    case KV.H0{} KV.H2{}:
      e => {==}
    case KV.H0{} KV.H3{}:
      e => {==}
    case KV.H0{} KV.H4{}:
      e => {==}
    case KV.H0{} KV.H5{}:
      e => {==}
    case KV.H0{} KV.H6{}:
      e => {==}
    case KV.H0{} KV.H7{}:
      e => {==}
    case KV.H0{} KV.H8{}:
      e => {==}
    case KV.H0{} KV.H9{}:
      e => {==}
    case KV.H0{} KV.H10{}:
      e => {==}
    case KV.H0{} KV.H11{}:
      e => {==}
    case KV.H0{} KV.H12{}:
      e => {==}
    case KV.H0{} KV.H13{}:
      e => {==}
    case KV.H0{} KV.H14{}:
      e => {==}
    case KV.H0{} KV.H15{}:
      e => {==}
    case KV.H1{} KV.H0{}:
      e => {==}
    case KV.H1{} KV.H1{}:
      e => Empty.absurd({KV.tget_h(V, 1n+p, KV.tmod_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H1{}, h1, op), KV.H1{}, h2) == KV.tget_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H1{}, h2) : KV.Trie<V>}, true_false(e))
    case KV.H1{} KV.H2{}:
      e => {==}
    case KV.H1{} KV.H3{}:
      e => {==}
    case KV.H1{} KV.H4{}:
      e => {==}
    case KV.H1{} KV.H5{}:
      e => {==}
    case KV.H1{} KV.H6{}:
      e => {==}
    case KV.H1{} KV.H7{}:
      e => {==}
    case KV.H1{} KV.H8{}:
      e => {==}
    case KV.H1{} KV.H9{}:
      e => {==}
    case KV.H1{} KV.H10{}:
      e => {==}
    case KV.H1{} KV.H11{}:
      e => {==}
    case KV.H1{} KV.H12{}:
      e => {==}
    case KV.H1{} KV.H13{}:
      e => {==}
    case KV.H1{} KV.H14{}:
      e => {==}
    case KV.H1{} KV.H15{}:
      e => {==}
    case KV.H2{} KV.H0{}:
      e => {==}
    case KV.H2{} KV.H1{}:
      e => {==}
    case KV.H2{} KV.H2{}:
      e => Empty.absurd({KV.tget_h(V, 1n+p, KV.tmod_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H2{}, h1, op), KV.H2{}, h2) == KV.tget_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H2{}, h2) : KV.Trie<V>}, true_false(e))
    case KV.H2{} KV.H3{}:
      e => {==}
    case KV.H2{} KV.H4{}:
      e => {==}
    case KV.H2{} KV.H5{}:
      e => {==}
    case KV.H2{} KV.H6{}:
      e => {==}
    case KV.H2{} KV.H7{}:
      e => {==}
    case KV.H2{} KV.H8{}:
      e => {==}
    case KV.H2{} KV.H9{}:
      e => {==}
    case KV.H2{} KV.H10{}:
      e => {==}
    case KV.H2{} KV.H11{}:
      e => {==}
    case KV.H2{} KV.H12{}:
      e => {==}
    case KV.H2{} KV.H13{}:
      e => {==}
    case KV.H2{} KV.H14{}:
      e => {==}
    case KV.H2{} KV.H15{}:
      e => {==}
    case KV.H3{} KV.H0{}:
      e => {==}
    case KV.H3{} KV.H1{}:
      e => {==}
    case KV.H3{} KV.H2{}:
      e => {==}
    case KV.H3{} KV.H3{}:
      e => Empty.absurd({KV.tget_h(V, 1n+p, KV.tmod_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H3{}, h1, op), KV.H3{}, h2) == KV.tget_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H3{}, h2) : KV.Trie<V>}, true_false(e))
    case KV.H3{} KV.H4{}:
      e => {==}
    case KV.H3{} KV.H5{}:
      e => {==}
    case KV.H3{} KV.H6{}:
      e => {==}
    case KV.H3{} KV.H7{}:
      e => {==}
    case KV.H3{} KV.H8{}:
      e => {==}
    case KV.H3{} KV.H9{}:
      e => {==}
    case KV.H3{} KV.H10{}:
      e => {==}
    case KV.H3{} KV.H11{}:
      e => {==}
    case KV.H3{} KV.H12{}:
      e => {==}
    case KV.H3{} KV.H13{}:
      e => {==}
    case KV.H3{} KV.H14{}:
      e => {==}
    case KV.H3{} KV.H15{}:
      e => {==}
    case KV.H4{} KV.H0{}:
      e => {==}
    case KV.H4{} KV.H1{}:
      e => {==}
    case KV.H4{} KV.H2{}:
      e => {==}
    case KV.H4{} KV.H3{}:
      e => {==}
    case KV.H4{} KV.H4{}:
      e => Empty.absurd({KV.tget_h(V, 1n+p, KV.tmod_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H4{}, h1, op), KV.H4{}, h2) == KV.tget_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H4{}, h2) : KV.Trie<V>}, true_false(e))
    case KV.H4{} KV.H5{}:
      e => {==}
    case KV.H4{} KV.H6{}:
      e => {==}
    case KV.H4{} KV.H7{}:
      e => {==}
    case KV.H4{} KV.H8{}:
      e => {==}
    case KV.H4{} KV.H9{}:
      e => {==}
    case KV.H4{} KV.H10{}:
      e => {==}
    case KV.H4{} KV.H11{}:
      e => {==}
    case KV.H4{} KV.H12{}:
      e => {==}
    case KV.H4{} KV.H13{}:
      e => {==}
    case KV.H4{} KV.H14{}:
      e => {==}
    case KV.H4{} KV.H15{}:
      e => {==}
    case KV.H5{} KV.H0{}:
      e => {==}
    case KV.H5{} KV.H1{}:
      e => {==}
    case KV.H5{} KV.H2{}:
      e => {==}
    case KV.H5{} KV.H3{}:
      e => {==}
    case KV.H5{} KV.H4{}:
      e => {==}
    case KV.H5{} KV.H5{}:
      e => Empty.absurd({KV.tget_h(V, 1n+p, KV.tmod_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H5{}, h1, op), KV.H5{}, h2) == KV.tget_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H5{}, h2) : KV.Trie<V>}, true_false(e))
    case KV.H5{} KV.H6{}:
      e => {==}
    case KV.H5{} KV.H7{}:
      e => {==}
    case KV.H5{} KV.H8{}:
      e => {==}
    case KV.H5{} KV.H9{}:
      e => {==}
    case KV.H5{} KV.H10{}:
      e => {==}
    case KV.H5{} KV.H11{}:
      e => {==}
    case KV.H5{} KV.H12{}:
      e => {==}
    case KV.H5{} KV.H13{}:
      e => {==}
    case KV.H5{} KV.H14{}:
      e => {==}
    case KV.H5{} KV.H15{}:
      e => {==}
    case KV.H6{} KV.H0{}:
      e => {==}
    case KV.H6{} KV.H1{}:
      e => {==}
    case KV.H6{} KV.H2{}:
      e => {==}
    case KV.H6{} KV.H3{}:
      e => {==}
    case KV.H6{} KV.H4{}:
      e => {==}
    case KV.H6{} KV.H5{}:
      e => {==}
    case KV.H6{} KV.H6{}:
      e => Empty.absurd({KV.tget_h(V, 1n+p, KV.tmod_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H6{}, h1, op), KV.H6{}, h2) == KV.tget_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H6{}, h2) : KV.Trie<V>}, true_false(e))
    case KV.H6{} KV.H7{}:
      e => {==}
    case KV.H6{} KV.H8{}:
      e => {==}
    case KV.H6{} KV.H9{}:
      e => {==}
    case KV.H6{} KV.H10{}:
      e => {==}
    case KV.H6{} KV.H11{}:
      e => {==}
    case KV.H6{} KV.H12{}:
      e => {==}
    case KV.H6{} KV.H13{}:
      e => {==}
    case KV.H6{} KV.H14{}:
      e => {==}
    case KV.H6{} KV.H15{}:
      e => {==}
    case KV.H7{} KV.H0{}:
      e => {==}
    case KV.H7{} KV.H1{}:
      e => {==}
    case KV.H7{} KV.H2{}:
      e => {==}
    case KV.H7{} KV.H3{}:
      e => {==}
    case KV.H7{} KV.H4{}:
      e => {==}
    case KV.H7{} KV.H5{}:
      e => {==}
    case KV.H7{} KV.H6{}:
      e => {==}
    case KV.H7{} KV.H7{}:
      e => Empty.absurd({KV.tget_h(V, 1n+p, KV.tmod_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H7{}, h1, op), KV.H7{}, h2) == KV.tget_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H7{}, h2) : KV.Trie<V>}, true_false(e))
    case KV.H7{} KV.H8{}:
      e => {==}
    case KV.H7{} KV.H9{}:
      e => {==}
    case KV.H7{} KV.H10{}:
      e => {==}
    case KV.H7{} KV.H11{}:
      e => {==}
    case KV.H7{} KV.H12{}:
      e => {==}
    case KV.H7{} KV.H13{}:
      e => {==}
    case KV.H7{} KV.H14{}:
      e => {==}
    case KV.H7{} KV.H15{}:
      e => {==}
    case KV.H8{} KV.H0{}:
      e => {==}
    case KV.H8{} KV.H1{}:
      e => {==}
    case KV.H8{} KV.H2{}:
      e => {==}
    case KV.H8{} KV.H3{}:
      e => {==}
    case KV.H8{} KV.H4{}:
      e => {==}
    case KV.H8{} KV.H5{}:
      e => {==}
    case KV.H8{} KV.H6{}:
      e => {==}
    case KV.H8{} KV.H7{}:
      e => {==}
    case KV.H8{} KV.H8{}:
      e => Empty.absurd({KV.tget_h(V, 1n+p, KV.tmod_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H8{}, h1, op), KV.H8{}, h2) == KV.tget_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H8{}, h2) : KV.Trie<V>}, true_false(e))
    case KV.H8{} KV.H9{}:
      e => {==}
    case KV.H8{} KV.H10{}:
      e => {==}
    case KV.H8{} KV.H11{}:
      e => {==}
    case KV.H8{} KV.H12{}:
      e => {==}
    case KV.H8{} KV.H13{}:
      e => {==}
    case KV.H8{} KV.H14{}:
      e => {==}
    case KV.H8{} KV.H15{}:
      e => {==}
    case KV.H9{} KV.H0{}:
      e => {==}
    case KV.H9{} KV.H1{}:
      e => {==}
    case KV.H9{} KV.H2{}:
      e => {==}
    case KV.H9{} KV.H3{}:
      e => {==}
    case KV.H9{} KV.H4{}:
      e => {==}
    case KV.H9{} KV.H5{}:
      e => {==}
    case KV.H9{} KV.H6{}:
      e => {==}
    case KV.H9{} KV.H7{}:
      e => {==}
    case KV.H9{} KV.H8{}:
      e => {==}
    case KV.H9{} KV.H9{}:
      e => Empty.absurd({KV.tget_h(V, 1n+p, KV.tmod_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H9{}, h1, op), KV.H9{}, h2) == KV.tget_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H9{}, h2) : KV.Trie<V>}, true_false(e))
    case KV.H9{} KV.H10{}:
      e => {==}
    case KV.H9{} KV.H11{}:
      e => {==}
    case KV.H9{} KV.H12{}:
      e => {==}
    case KV.H9{} KV.H13{}:
      e => {==}
    case KV.H9{} KV.H14{}:
      e => {==}
    case KV.H9{} KV.H15{}:
      e => {==}
    case KV.H10{} KV.H0{}:
      e => {==}
    case KV.H10{} KV.H1{}:
      e => {==}
    case KV.H10{} KV.H2{}:
      e => {==}
    case KV.H10{} KV.H3{}:
      e => {==}
    case KV.H10{} KV.H4{}:
      e => {==}
    case KV.H10{} KV.H5{}:
      e => {==}
    case KV.H10{} KV.H6{}:
      e => {==}
    case KV.H10{} KV.H7{}:
      e => {==}
    case KV.H10{} KV.H8{}:
      e => {==}
    case KV.H10{} KV.H9{}:
      e => {==}
    case KV.H10{} KV.H10{}:
      e => Empty.absurd({KV.tget_h(V, 1n+p, KV.tmod_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H10{}, h1, op), KV.H10{}, h2) == KV.tget_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H10{}, h2) : KV.Trie<V>}, true_false(e))
    case KV.H10{} KV.H11{}:
      e => {==}
    case KV.H10{} KV.H12{}:
      e => {==}
    case KV.H10{} KV.H13{}:
      e => {==}
    case KV.H10{} KV.H14{}:
      e => {==}
    case KV.H10{} KV.H15{}:
      e => {==}
    case KV.H11{} KV.H0{}:
      e => {==}
    case KV.H11{} KV.H1{}:
      e => {==}
    case KV.H11{} KV.H2{}:
      e => {==}
    case KV.H11{} KV.H3{}:
      e => {==}
    case KV.H11{} KV.H4{}:
      e => {==}
    case KV.H11{} KV.H5{}:
      e => {==}
    case KV.H11{} KV.H6{}:
      e => {==}
    case KV.H11{} KV.H7{}:
      e => {==}
    case KV.H11{} KV.H8{}:
      e => {==}
    case KV.H11{} KV.H9{}:
      e => {==}
    case KV.H11{} KV.H10{}:
      e => {==}
    case KV.H11{} KV.H11{}:
      e => Empty.absurd({KV.tget_h(V, 1n+p, KV.tmod_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H11{}, h1, op), KV.H11{}, h2) == KV.tget_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H11{}, h2) : KV.Trie<V>}, true_false(e))
    case KV.H11{} KV.H12{}:
      e => {==}
    case KV.H11{} KV.H13{}:
      e => {==}
    case KV.H11{} KV.H14{}:
      e => {==}
    case KV.H11{} KV.H15{}:
      e => {==}
    case KV.H12{} KV.H0{}:
      e => {==}
    case KV.H12{} KV.H1{}:
      e => {==}
    case KV.H12{} KV.H2{}:
      e => {==}
    case KV.H12{} KV.H3{}:
      e => {==}
    case KV.H12{} KV.H4{}:
      e => {==}
    case KV.H12{} KV.H5{}:
      e => {==}
    case KV.H12{} KV.H6{}:
      e => {==}
    case KV.H12{} KV.H7{}:
      e => {==}
    case KV.H12{} KV.H8{}:
      e => {==}
    case KV.H12{} KV.H9{}:
      e => {==}
    case KV.H12{} KV.H10{}:
      e => {==}
    case KV.H12{} KV.H11{}:
      e => {==}
    case KV.H12{} KV.H12{}:
      e => Empty.absurd({KV.tget_h(V, 1n+p, KV.tmod_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H12{}, h1, op), KV.H12{}, h2) == KV.tget_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H12{}, h2) : KV.Trie<V>}, true_false(e))
    case KV.H12{} KV.H13{}:
      e => {==}
    case KV.H12{} KV.H14{}:
      e => {==}
    case KV.H12{} KV.H15{}:
      e => {==}
    case KV.H13{} KV.H0{}:
      e => {==}
    case KV.H13{} KV.H1{}:
      e => {==}
    case KV.H13{} KV.H2{}:
      e => {==}
    case KV.H13{} KV.H3{}:
      e => {==}
    case KV.H13{} KV.H4{}:
      e => {==}
    case KV.H13{} KV.H5{}:
      e => {==}
    case KV.H13{} KV.H6{}:
      e => {==}
    case KV.H13{} KV.H7{}:
      e => {==}
    case KV.H13{} KV.H8{}:
      e => {==}
    case KV.H13{} KV.H9{}:
      e => {==}
    case KV.H13{} KV.H10{}:
      e => {==}
    case KV.H13{} KV.H11{}:
      e => {==}
    case KV.H13{} KV.H12{}:
      e => {==}
    case KV.H13{} KV.H13{}:
      e => Empty.absurd({KV.tget_h(V, 1n+p, KV.tmod_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H13{}, h1, op), KV.H13{}, h2) == KV.tget_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H13{}, h2) : KV.Trie<V>}, true_false(e))
    case KV.H13{} KV.H14{}:
      e => {==}
    case KV.H13{} KV.H15{}:
      e => {==}
    case KV.H14{} KV.H0{}:
      e => {==}
    case KV.H14{} KV.H1{}:
      e => {==}
    case KV.H14{} KV.H2{}:
      e => {==}
    case KV.H14{} KV.H3{}:
      e => {==}
    case KV.H14{} KV.H4{}:
      e => {==}
    case KV.H14{} KV.H5{}:
      e => {==}
    case KV.H14{} KV.H6{}:
      e => {==}
    case KV.H14{} KV.H7{}:
      e => {==}
    case KV.H14{} KV.H8{}:
      e => {==}
    case KV.H14{} KV.H9{}:
      e => {==}
    case KV.H14{} KV.H10{}:
      e => {==}
    case KV.H14{} KV.H11{}:
      e => {==}
    case KV.H14{} KV.H12{}:
      e => {==}
    case KV.H14{} KV.H13{}:
      e => {==}
    case KV.H14{} KV.H14{}:
      e => Empty.absurd({KV.tget_h(V, 1n+p, KV.tmod_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H14{}, h1, op), KV.H14{}, h2) == KV.tget_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H14{}, h2) : KV.Trie<V>}, true_false(e))
    case KV.H14{} KV.H15{}:
      e => {==}
    case KV.H15{} KV.H0{}:
      e => {==}
    case KV.H15{} KV.H1{}:
      e => {==}
    case KV.H15{} KV.H2{}:
      e => {==}
    case KV.H15{} KV.H3{}:
      e => {==}
    case KV.H15{} KV.H4{}:
      e => {==}
    case KV.H15{} KV.H5{}:
      e => {==}
    case KV.H15{} KV.H6{}:
      e => {==}
    case KV.H15{} KV.H7{}:
      e => {==}
    case KV.H15{} KV.H8{}:
      e => {==}
    case KV.H15{} KV.H9{}:
      e => {==}
    case KV.H15{} KV.H10{}:
      e => {==}
    case KV.H15{} KV.H11{}:
      e => {==}
    case KV.H15{} KV.H12{}:
      e => {==}
    case KV.H15{} KV.H13{}:
      e => {==}
    case KV.H15{} KV.H14{}:
      e => {==}
    case KV.H15{} KV.H15{}:
      e => Empty.absurd({KV.tget_h(V, 1n+p, KV.tmod_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H15{}, h1, op), KV.H15{}, h2) == KV.tget_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, KV.H15{}, h2) : KV.Trie<V>}, true_false(e))
# END gen_trie: other

# a write through one child leaves the reads of the other children
def upd_other(-V: Data, +p: Nat, +t: KV.Trie<V>, +x1: KV.Hex, +h1: U32, +x2: KV.Hex, +h2: U32, +op: KV.Op<V>) -> {KV.hex_eq(x1, x2) == False{} : Bool} -> {KV.tget_h(V, 1n+p, KV.tmod_h(V, 1n+p, t, x1, h1, op), x2, h2) == KV.tget_h(V, 1n+p, t, x2, h2) : KV.Trie<V>}:
  match t:
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}:
      upd_other_node(V, p, c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15, x1, h1, x2, h2, op)
    case KV.Tip{}:
      e => %n1_tip(V, p, x1, h1, op) : {KV.tget_h(V, 1n+p, _, x2, h2) == KV.Tip{} : KV.Trie<V>}
           %n2_tip(V, p, x2, h2) : {KV.tget_h(V, 1n+p, KV.tmod_h(V, 1n+p, KV.Node{KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}}, x1, h1, op), x2, h2) == _ : KV.Trie<V>}
           upd_other_node(V, p, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, x1, h1, x2, h2, op)(e)
    case KV.Ent{a, b, c}:
      e => %n1_ent(V, p, a, b, c, x1, h1, op) : {KV.tget_h(V, 1n+p, _, x2, h2) == KV.Tip{} : KV.Trie<V>}
           %n2_tip(V, p, x2, h2) : {KV.tget_h(V, 1n+p, KV.tmod_h(V, 1n+p, KV.Node{KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}}, x1, h1, op), x2, h2) == _ : KV.Trie<V>}
           upd_other_node(V, p, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, KV.Tip{}, x1, h1, x2, h2, op)(e)

def other_step(-V: Data, +p: Nat, +t: KV.Trie<V>, +x1: KV.Hex, +h1: U32, +x2: KV.Hex, +h2: U32, +op: KV.Op<V>, c: Bool, ih: @u: KV.Trie<V> -> {dsame(p, KV.hex(KV.shr4(h1)), KV.shr4(h1), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == False{} : Bool} -> {KV.tget_h(V, p, KV.tmod_h(V, p, u, KV.hex(KV.shr4(h1)), KV.shr4(h1), op), KV.hex(KV.shr4(h2)), KV.shr4(h2)) == KV.tget_h(V, p, u, KV.hex(KV.shr4(h2)), KV.shr4(h2)) : KV.Trie<V>})
  -> {c == KV.hex_eq(x1, x2) : Bool}
  -> {Bool.and(c, dsame(p, KV.hex(KV.shr4(h1)), KV.shr4(h1), KV.hex(KV.shr4(h2)), KV.shr4(h2))) == False{} : Bool}
  -> {KV.tget_h(V, 1n+p, KV.tmod_h(V, 1n+p, t, x1, h1, op), x2, h2) == KV.tget_h(V, 1n+p, t, x2, h2) : KV.Trie<V>}:
  match c:
    case False{}:
      ec => e => upd_other(V, p, t, x1, h1, x2, h2, op)(Equal.sym(Bool, False{}, KV.hex_eq(x1, x2), ec))
    case True{}:
      ec => e => %hex_eq_sound(x1, x2)(Equal.sym(Bool, True{}, KV.hex_eq(x1, x2), ec)) : {KV.tget_h(V, 1n+p, KV.tmod_h(V, 1n+p, t, x1, h1, op), _, h2) == KV.tget_h(V, 1n+p, t, _, h2) : KV.Trie<V>}
                 same_digit_step(V, p, t, x1, h1, h2, op, ih)(e)

# a read of any other bucket does not see the modification
def tget_tmod_other(-V: Data, d: Nat, +t: KV.Trie<V>, +x1: KV.Hex, +h1: U32, +x2: KV.Hex, +h2: U32, +op: KV.Op<V>) -> {dsame(d, x1, h1, x2, h2) == False{} : Bool} -> {KV.tget_h(V, d, KV.tmod_h(V, d, t, x1, h1, op), x2, h2) == KV.tget_h(V, d, t, x2, h2) : KV.Trie<V>}:
  match d:
    case 0n:
      e => Empty.absurd({KV.tget_h(V, 0n, KV.tmod_h(V, 0n, t, x1, h1, op), x2, h2) == KV.tget_h(V, 0n, t, x2, h2) : KV.Trie<V>}, true_false(e))
    case 1n++p:
      other_step(V, p, t, x1, h1, x2, h2, op, KV.hex_eq(x1, x2), u => tget_tmod_other(V, p, u, KV.hex(KV.shr4(h1)), KV.shr4(h1), KV.hex(KV.shr4(h2)), KV.shr4(h2), op))({==})

# The root
# ========
# The root's subtrie at a digit: a walk from the root goes on from there,
# and a write from the root changes it alone. A subtrie put under one
# digit (with_child) is the one found there, and leaves the others.

# BEGIN gen_trie: root
# a walk from the root goes on from the root's subtrie at its first digit
def get_root(-V: Data, t: KV.Trie<V>, x: KV.Hex, -h: U32, -k: String) -> {KV.tget_k(V, 4n, KV.child(V, t, x), KV.hex(KV.shr4(h)), KV.shr4(h), k) == KV.tget_k(V, 5n, t, x, h, k) : Maybe<&2, V>}:
  match t x:
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H0{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H1{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H2{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H3{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H4{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H5{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H6{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H7{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H8{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H9{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H10{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H11{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H12{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H13{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H14{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H15{}:
      {==}
    case KV.Tip{} _:
      {==}
    case KV.Ent{ka, va, ra} _:
      {==}

# a write from the root writes the root's subtrie at its first digit
def mod_root(-V: Data, t: KV.Trie<V>, x: KV.Hex, -h: U32, -op: KV.Op<V>) -> {KV.with_child(V, t, x, KV.tmod_h(V, 4n, KV.child(V, t, x), KV.hex(KV.shr4(h)), KV.shr4(h), op)) == KV.tmod_h(V, 5n, t, x, h, op) : KV.Trie<V>}:
  match t x:
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H0{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H1{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H2{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H3{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H4{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H5{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H6{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H7{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H8{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H9{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H10{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H11{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H12{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H13{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H14{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H15{}:
      {==}
    case KV.Tip{} KV.H0{}:
      {==}
    case KV.Tip{} KV.H1{}:
      {==}
    case KV.Tip{} KV.H2{}:
      {==}
    case KV.Tip{} KV.H3{}:
      {==}
    case KV.Tip{} KV.H4{}:
      {==}
    case KV.Tip{} KV.H5{}:
      {==}
    case KV.Tip{} KV.H6{}:
      {==}
    case KV.Tip{} KV.H7{}:
      {==}
    case KV.Tip{} KV.H8{}:
      {==}
    case KV.Tip{} KV.H9{}:
      {==}
    case KV.Tip{} KV.H10{}:
      {==}
    case KV.Tip{} KV.H11{}:
      {==}
    case KV.Tip{} KV.H12{}:
      {==}
    case KV.Tip{} KV.H13{}:
      {==}
    case KV.Tip{} KV.H14{}:
      {==}
    case KV.Tip{} KV.H15{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H0{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H1{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H2{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H3{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H4{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H5{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H6{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H7{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H8{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H9{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H10{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H11{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H12{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H13{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H14{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H15{}:
      {==}

# the subtrie put under a digit is the root's subtrie at that digit
def child_with_same(-V: Data, t: KV.Trie<V>, x: KV.Hex, -c: KV.Trie<V>) -> {c == KV.child(V, KV.with_child(V, t, x, c), x) : KV.Trie<V>}:
  match t x:
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H0{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H1{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H2{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H3{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H4{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H5{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H6{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H7{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H8{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H9{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H10{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H11{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H12{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H13{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H14{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H15{}:
      {==}
    case KV.Tip{} KV.H0{}:
      {==}
    case KV.Tip{} KV.H1{}:
      {==}
    case KV.Tip{} KV.H2{}:
      {==}
    case KV.Tip{} KV.H3{}:
      {==}
    case KV.Tip{} KV.H4{}:
      {==}
    case KV.Tip{} KV.H5{}:
      {==}
    case KV.Tip{} KV.H6{}:
      {==}
    case KV.Tip{} KV.H7{}:
      {==}
    case KV.Tip{} KV.H8{}:
      {==}
    case KV.Tip{} KV.H9{}:
      {==}
    case KV.Tip{} KV.H10{}:
      {==}
    case KV.Tip{} KV.H11{}:
      {==}
    case KV.Tip{} KV.H12{}:
      {==}
    case KV.Tip{} KV.H13{}:
      {==}
    case KV.Tip{} KV.H14{}:
      {==}
    case KV.Tip{} KV.H15{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H0{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H1{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H2{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H3{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H4{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H5{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H6{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H7{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H8{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H9{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H10{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H11{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H12{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H13{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H14{}:
      {==}
    case KV.Ent{ka, va, ra} KV.H15{}:
      {==}

# a subtrie put under one digit leaves the subtries of the others
def child_with_other(-V: Data, t: KV.Trie<V>, -x: KV.Hex, -c: KV.Trie<V>, y: KV.Hex) -> {False{} == KV.hex_eq(y, x) : Bool} -> {KV.child(V, t, y) == KV.child(V, KV.with_child(V, t, x, c), y) : KV.Trie<V>}:
  match t y:
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H0{}:
      e => %e : {c0 == Bool.pick(KV.Trie<V>, _, c, c0) : KV.Trie<V>}
           {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H1{}:
      e => %e : {c1 == Bool.pick(KV.Trie<V>, _, c, c1) : KV.Trie<V>}
           {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H2{}:
      e => %e : {c2 == Bool.pick(KV.Trie<V>, _, c, c2) : KV.Trie<V>}
           {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H3{}:
      e => %e : {c3 == Bool.pick(KV.Trie<V>, _, c, c3) : KV.Trie<V>}
           {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H4{}:
      e => %e : {c4 == Bool.pick(KV.Trie<V>, _, c, c4) : KV.Trie<V>}
           {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H5{}:
      e => %e : {c5 == Bool.pick(KV.Trie<V>, _, c, c5) : KV.Trie<V>}
           {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H6{}:
      e => %e : {c6 == Bool.pick(KV.Trie<V>, _, c, c6) : KV.Trie<V>}
           {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H7{}:
      e => %e : {c7 == Bool.pick(KV.Trie<V>, _, c, c7) : KV.Trie<V>}
           {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H8{}:
      e => %e : {c8 == Bool.pick(KV.Trie<V>, _, c, c8) : KV.Trie<V>}
           {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H9{}:
      e => %e : {c9 == Bool.pick(KV.Trie<V>, _, c, c9) : KV.Trie<V>}
           {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H10{}:
      e => %e : {c10 == Bool.pick(KV.Trie<V>, _, c, c10) : KV.Trie<V>}
           {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H11{}:
      e => %e : {c11 == Bool.pick(KV.Trie<V>, _, c, c11) : KV.Trie<V>}
           {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H12{}:
      e => %e : {c12 == Bool.pick(KV.Trie<V>, _, c, c12) : KV.Trie<V>}
           {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H13{}:
      e => %e : {c13 == Bool.pick(KV.Trie<V>, _, c, c13) : KV.Trie<V>}
           {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H14{}:
      e => %e : {c14 == Bool.pick(KV.Trie<V>, _, c, c14) : KV.Trie<V>}
           {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H15{}:
      e => %e : {c15 == Bool.pick(KV.Trie<V>, _, c, c15) : KV.Trie<V>}
           {==}
    case KV.Tip{} KV.H0{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}
    case KV.Tip{} KV.H1{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}
    case KV.Tip{} KV.H2{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}
    case KV.Tip{} KV.H3{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}
    case KV.Tip{} KV.H4{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}
    case KV.Tip{} KV.H5{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}
    case KV.Tip{} KV.H6{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}
    case KV.Tip{} KV.H7{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}
    case KV.Tip{} KV.H8{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}
    case KV.Tip{} KV.H9{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}
    case KV.Tip{} KV.H10{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}
    case KV.Tip{} KV.H11{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}
    case KV.Tip{} KV.H12{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}
    case KV.Tip{} KV.H13{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}
    case KV.Tip{} KV.H14{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}
    case KV.Tip{} KV.H15{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}
    case KV.Ent{ka, va, ra} KV.H0{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}
    case KV.Ent{ka, va, ra} KV.H1{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}
    case KV.Ent{ka, va, ra} KV.H2{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}
    case KV.Ent{ka, va, ra} KV.H3{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}
    case KV.Ent{ka, va, ra} KV.H4{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}
    case KV.Ent{ka, va, ra} KV.H5{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}
    case KV.Ent{ka, va, ra} KV.H6{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}
    case KV.Ent{ka, va, ra} KV.H7{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}
    case KV.Ent{ka, va, ra} KV.H8{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}
    case KV.Ent{ka, va, ra} KV.H9{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}
    case KV.Ent{ka, va, ra} KV.H10{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}
    case KV.Ent{ka, va, ra} KV.H11{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}
    case KV.Ent{ka, va, ra} KV.H12{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}
    case KV.Ent{ka, va, ra} KV.H13{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}
    case KV.Ent{ka, va, ra} KV.H14{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}
    case KV.Ent{ka, va, ra} KV.H15{}:
      e => %e : {KV.Tip{} == Bool.pick(KV.Trie<V>, _, c, KV.Tip{}) : KV.Trie<V>}
           {==}

# the size and the keys under a digit are those of the subtrie there
def size_at_child(-V: Data, t: KV.Trie<V>, x: KV.Hex) -> {KV.tsize(V, KV.child(V, t, x)) == KV.size.at(V, t, x) : Nat}:
  match t x:
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H0{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H1{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H2{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H3{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H4{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H5{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H6{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H7{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H8{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H9{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H10{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H11{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H12{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H13{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H14{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H15{}:
      {==}
    case KV.Tip{} _:
      {==}
    case KV.Ent{ka, va, ra} _:
      {==}

def keys_at_child(-V: Data, t: KV.Trie<V>, x: KV.Hex, -acc: List<&2, String>) -> {KV.tkeys(V, KV.child(V, t, x), acc) == KV.keys.at(V, t, x, acc) : List<&2, String>}:
  match t x:
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H0{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H1{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H2{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H3{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H4{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H5{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H6{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H7{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H8{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H9{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H10{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H11{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H12{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H13{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H14{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H15{}:
      {==}
    case KV.Tip{} _:
      {==}
    case KV.Ent{ka, va, ra} _:
      {==}
# END gen_trie: root

# BEGIN gen_trie: folds
# tkeys puts a trie's keys in front of acc, so a list appended to acc
# comes after them
def tkeys_app(-V: Data, t: KV.Trie<V>, -a: List<&2, String>, -b: List<&2, String>) -> {KV.tkeys(V, t, List.append(&2, String, a, b)) == List.append(&2, String, KV.tkeys(V, t, a), b) : List<&2, String>}:
  match t:
    case KV.Tip{}:
      {==}
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}:
      %tkeys_app(V, c0, KV.tkeys(V, c1, KV.tkeys(V, c2, KV.tkeys(V, c3, KV.tkeys(V, c4, KV.tkeys(V, c5, KV.tkeys(V, c6, KV.tkeys(V, c7, KV.tkeys(V, c8, KV.tkeys(V, c9, KV.tkeys(V, c10, KV.tkeys(V, c11, KV.tkeys(V, c12, KV.tkeys(V, c13, KV.tkeys(V, c14, KV.tkeys(V, c15, a))))))))))))))), b) : {KV.tkeys(V, c0, KV.tkeys(V, c1, KV.tkeys(V, c2, KV.tkeys(V, c3, KV.tkeys(V, c4, KV.tkeys(V, c5, KV.tkeys(V, c6, KV.tkeys(V, c7, KV.tkeys(V, c8, KV.tkeys(V, c9, KV.tkeys(V, c10, KV.tkeys(V, c11, KV.tkeys(V, c12, KV.tkeys(V, c13, KV.tkeys(V, c14, KV.tkeys(V, c15, List.append(&2, String, a, b))))))))))))))))) == _ : List<&2, String>}
      %tkeys_app(V, c1, KV.tkeys(V, c2, KV.tkeys(V, c3, KV.tkeys(V, c4, KV.tkeys(V, c5, KV.tkeys(V, c6, KV.tkeys(V, c7, KV.tkeys(V, c8, KV.tkeys(V, c9, KV.tkeys(V, c10, KV.tkeys(V, c11, KV.tkeys(V, c12, KV.tkeys(V, c13, KV.tkeys(V, c14, KV.tkeys(V, c15, a)))))))))))))), b) : {KV.tkeys(V, c0, KV.tkeys(V, c1, KV.tkeys(V, c2, KV.tkeys(V, c3, KV.tkeys(V, c4, KV.tkeys(V, c5, KV.tkeys(V, c6, KV.tkeys(V, c7, KV.tkeys(V, c8, KV.tkeys(V, c9, KV.tkeys(V, c10, KV.tkeys(V, c11, KV.tkeys(V, c12, KV.tkeys(V, c13, KV.tkeys(V, c14, KV.tkeys(V, c15, List.append(&2, String, a, b))))))))))))))))) == KV.tkeys(V, c0, _) : List<&2, String>}
      %tkeys_app(V, c2, KV.tkeys(V, c3, KV.tkeys(V, c4, KV.tkeys(V, c5, KV.tkeys(V, c6, KV.tkeys(V, c7, KV.tkeys(V, c8, KV.tkeys(V, c9, KV.tkeys(V, c10, KV.tkeys(V, c11, KV.tkeys(V, c12, KV.tkeys(V, c13, KV.tkeys(V, c14, KV.tkeys(V, c15, a))))))))))))), b) : {KV.tkeys(V, c0, KV.tkeys(V, c1, KV.tkeys(V, c2, KV.tkeys(V, c3, KV.tkeys(V, c4, KV.tkeys(V, c5, KV.tkeys(V, c6, KV.tkeys(V, c7, KV.tkeys(V, c8, KV.tkeys(V, c9, KV.tkeys(V, c10, KV.tkeys(V, c11, KV.tkeys(V, c12, KV.tkeys(V, c13, KV.tkeys(V, c14, KV.tkeys(V, c15, List.append(&2, String, a, b))))))))))))))))) == KV.tkeys(V, c0, KV.tkeys(V, c1, _)) : List<&2, String>}
      %tkeys_app(V, c3, KV.tkeys(V, c4, KV.tkeys(V, c5, KV.tkeys(V, c6, KV.tkeys(V, c7, KV.tkeys(V, c8, KV.tkeys(V, c9, KV.tkeys(V, c10, KV.tkeys(V, c11, KV.tkeys(V, c12, KV.tkeys(V, c13, KV.tkeys(V, c14, KV.tkeys(V, c15, a)))))))))))), b) : {KV.tkeys(V, c0, KV.tkeys(V, c1, KV.tkeys(V, c2, KV.tkeys(V, c3, KV.tkeys(V, c4, KV.tkeys(V, c5, KV.tkeys(V, c6, KV.tkeys(V, c7, KV.tkeys(V, c8, KV.tkeys(V, c9, KV.tkeys(V, c10, KV.tkeys(V, c11, KV.tkeys(V, c12, KV.tkeys(V, c13, KV.tkeys(V, c14, KV.tkeys(V, c15, List.append(&2, String, a, b))))))))))))))))) == KV.tkeys(V, c0, KV.tkeys(V, c1, KV.tkeys(V, c2, _))) : List<&2, String>}
      %tkeys_app(V, c4, KV.tkeys(V, c5, KV.tkeys(V, c6, KV.tkeys(V, c7, KV.tkeys(V, c8, KV.tkeys(V, c9, KV.tkeys(V, c10, KV.tkeys(V, c11, KV.tkeys(V, c12, KV.tkeys(V, c13, KV.tkeys(V, c14, KV.tkeys(V, c15, a))))))))))), b) : {KV.tkeys(V, c0, KV.tkeys(V, c1, KV.tkeys(V, c2, KV.tkeys(V, c3, KV.tkeys(V, c4, KV.tkeys(V, c5, KV.tkeys(V, c6, KV.tkeys(V, c7, KV.tkeys(V, c8, KV.tkeys(V, c9, KV.tkeys(V, c10, KV.tkeys(V, c11, KV.tkeys(V, c12, KV.tkeys(V, c13, KV.tkeys(V, c14, KV.tkeys(V, c15, List.append(&2, String, a, b))))))))))))))))) == KV.tkeys(V, c0, KV.tkeys(V, c1, KV.tkeys(V, c2, KV.tkeys(V, c3, _)))) : List<&2, String>}
      %tkeys_app(V, c5, KV.tkeys(V, c6, KV.tkeys(V, c7, KV.tkeys(V, c8, KV.tkeys(V, c9, KV.tkeys(V, c10, KV.tkeys(V, c11, KV.tkeys(V, c12, KV.tkeys(V, c13, KV.tkeys(V, c14, KV.tkeys(V, c15, a)))))))))), b) : {KV.tkeys(V, c0, KV.tkeys(V, c1, KV.tkeys(V, c2, KV.tkeys(V, c3, KV.tkeys(V, c4, KV.tkeys(V, c5, KV.tkeys(V, c6, KV.tkeys(V, c7, KV.tkeys(V, c8, KV.tkeys(V, c9, KV.tkeys(V, c10, KV.tkeys(V, c11, KV.tkeys(V, c12, KV.tkeys(V, c13, KV.tkeys(V, c14, KV.tkeys(V, c15, List.append(&2, String, a, b))))))))))))))))) == KV.tkeys(V, c0, KV.tkeys(V, c1, KV.tkeys(V, c2, KV.tkeys(V, c3, KV.tkeys(V, c4, _))))) : List<&2, String>}
      %tkeys_app(V, c6, KV.tkeys(V, c7, KV.tkeys(V, c8, KV.tkeys(V, c9, KV.tkeys(V, c10, KV.tkeys(V, c11, KV.tkeys(V, c12, KV.tkeys(V, c13, KV.tkeys(V, c14, KV.tkeys(V, c15, a))))))))), b) : {KV.tkeys(V, c0, KV.tkeys(V, c1, KV.tkeys(V, c2, KV.tkeys(V, c3, KV.tkeys(V, c4, KV.tkeys(V, c5, KV.tkeys(V, c6, KV.tkeys(V, c7, KV.tkeys(V, c8, KV.tkeys(V, c9, KV.tkeys(V, c10, KV.tkeys(V, c11, KV.tkeys(V, c12, KV.tkeys(V, c13, KV.tkeys(V, c14, KV.tkeys(V, c15, List.append(&2, String, a, b))))))))))))))))) == KV.tkeys(V, c0, KV.tkeys(V, c1, KV.tkeys(V, c2, KV.tkeys(V, c3, KV.tkeys(V, c4, KV.tkeys(V, c5, _)))))) : List<&2, String>}
      %tkeys_app(V, c7, KV.tkeys(V, c8, KV.tkeys(V, c9, KV.tkeys(V, c10, KV.tkeys(V, c11, KV.tkeys(V, c12, KV.tkeys(V, c13, KV.tkeys(V, c14, KV.tkeys(V, c15, a)))))))), b) : {KV.tkeys(V, c0, KV.tkeys(V, c1, KV.tkeys(V, c2, KV.tkeys(V, c3, KV.tkeys(V, c4, KV.tkeys(V, c5, KV.tkeys(V, c6, KV.tkeys(V, c7, KV.tkeys(V, c8, KV.tkeys(V, c9, KV.tkeys(V, c10, KV.tkeys(V, c11, KV.tkeys(V, c12, KV.tkeys(V, c13, KV.tkeys(V, c14, KV.tkeys(V, c15, List.append(&2, String, a, b))))))))))))))))) == KV.tkeys(V, c0, KV.tkeys(V, c1, KV.tkeys(V, c2, KV.tkeys(V, c3, KV.tkeys(V, c4, KV.tkeys(V, c5, KV.tkeys(V, c6, _))))))) : List<&2, String>}
      %tkeys_app(V, c8, KV.tkeys(V, c9, KV.tkeys(V, c10, KV.tkeys(V, c11, KV.tkeys(V, c12, KV.tkeys(V, c13, KV.tkeys(V, c14, KV.tkeys(V, c15, a))))))), b) : {KV.tkeys(V, c0, KV.tkeys(V, c1, KV.tkeys(V, c2, KV.tkeys(V, c3, KV.tkeys(V, c4, KV.tkeys(V, c5, KV.tkeys(V, c6, KV.tkeys(V, c7, KV.tkeys(V, c8, KV.tkeys(V, c9, KV.tkeys(V, c10, KV.tkeys(V, c11, KV.tkeys(V, c12, KV.tkeys(V, c13, KV.tkeys(V, c14, KV.tkeys(V, c15, List.append(&2, String, a, b))))))))))))))))) == KV.tkeys(V, c0, KV.tkeys(V, c1, KV.tkeys(V, c2, KV.tkeys(V, c3, KV.tkeys(V, c4, KV.tkeys(V, c5, KV.tkeys(V, c6, KV.tkeys(V, c7, _)))))))) : List<&2, String>}
      %tkeys_app(V, c9, KV.tkeys(V, c10, KV.tkeys(V, c11, KV.tkeys(V, c12, KV.tkeys(V, c13, KV.tkeys(V, c14, KV.tkeys(V, c15, a)))))), b) : {KV.tkeys(V, c0, KV.tkeys(V, c1, KV.tkeys(V, c2, KV.tkeys(V, c3, KV.tkeys(V, c4, KV.tkeys(V, c5, KV.tkeys(V, c6, KV.tkeys(V, c7, KV.tkeys(V, c8, KV.tkeys(V, c9, KV.tkeys(V, c10, KV.tkeys(V, c11, KV.tkeys(V, c12, KV.tkeys(V, c13, KV.tkeys(V, c14, KV.tkeys(V, c15, List.append(&2, String, a, b))))))))))))))))) == KV.tkeys(V, c0, KV.tkeys(V, c1, KV.tkeys(V, c2, KV.tkeys(V, c3, KV.tkeys(V, c4, KV.tkeys(V, c5, KV.tkeys(V, c6, KV.tkeys(V, c7, KV.tkeys(V, c8, _))))))))) : List<&2, String>}
      %tkeys_app(V, c10, KV.tkeys(V, c11, KV.tkeys(V, c12, KV.tkeys(V, c13, KV.tkeys(V, c14, KV.tkeys(V, c15, a))))), b) : {KV.tkeys(V, c0, KV.tkeys(V, c1, KV.tkeys(V, c2, KV.tkeys(V, c3, KV.tkeys(V, c4, KV.tkeys(V, c5, KV.tkeys(V, c6, KV.tkeys(V, c7, KV.tkeys(V, c8, KV.tkeys(V, c9, KV.tkeys(V, c10, KV.tkeys(V, c11, KV.tkeys(V, c12, KV.tkeys(V, c13, KV.tkeys(V, c14, KV.tkeys(V, c15, List.append(&2, String, a, b))))))))))))))))) == KV.tkeys(V, c0, KV.tkeys(V, c1, KV.tkeys(V, c2, KV.tkeys(V, c3, KV.tkeys(V, c4, KV.tkeys(V, c5, KV.tkeys(V, c6, KV.tkeys(V, c7, KV.tkeys(V, c8, KV.tkeys(V, c9, _)))))))))) : List<&2, String>}
      %tkeys_app(V, c11, KV.tkeys(V, c12, KV.tkeys(V, c13, KV.tkeys(V, c14, KV.tkeys(V, c15, a)))), b) : {KV.tkeys(V, c0, KV.tkeys(V, c1, KV.tkeys(V, c2, KV.tkeys(V, c3, KV.tkeys(V, c4, KV.tkeys(V, c5, KV.tkeys(V, c6, KV.tkeys(V, c7, KV.tkeys(V, c8, KV.tkeys(V, c9, KV.tkeys(V, c10, KV.tkeys(V, c11, KV.tkeys(V, c12, KV.tkeys(V, c13, KV.tkeys(V, c14, KV.tkeys(V, c15, List.append(&2, String, a, b))))))))))))))))) == KV.tkeys(V, c0, KV.tkeys(V, c1, KV.tkeys(V, c2, KV.tkeys(V, c3, KV.tkeys(V, c4, KV.tkeys(V, c5, KV.tkeys(V, c6, KV.tkeys(V, c7, KV.tkeys(V, c8, KV.tkeys(V, c9, KV.tkeys(V, c10, _))))))))))) : List<&2, String>}
      %tkeys_app(V, c12, KV.tkeys(V, c13, KV.tkeys(V, c14, KV.tkeys(V, c15, a))), b) : {KV.tkeys(V, c0, KV.tkeys(V, c1, KV.tkeys(V, c2, KV.tkeys(V, c3, KV.tkeys(V, c4, KV.tkeys(V, c5, KV.tkeys(V, c6, KV.tkeys(V, c7, KV.tkeys(V, c8, KV.tkeys(V, c9, KV.tkeys(V, c10, KV.tkeys(V, c11, KV.tkeys(V, c12, KV.tkeys(V, c13, KV.tkeys(V, c14, KV.tkeys(V, c15, List.append(&2, String, a, b))))))))))))))))) == KV.tkeys(V, c0, KV.tkeys(V, c1, KV.tkeys(V, c2, KV.tkeys(V, c3, KV.tkeys(V, c4, KV.tkeys(V, c5, KV.tkeys(V, c6, KV.tkeys(V, c7, KV.tkeys(V, c8, KV.tkeys(V, c9, KV.tkeys(V, c10, KV.tkeys(V, c11, _)))))))))))) : List<&2, String>}
      %tkeys_app(V, c13, KV.tkeys(V, c14, KV.tkeys(V, c15, a)), b) : {KV.tkeys(V, c0, KV.tkeys(V, c1, KV.tkeys(V, c2, KV.tkeys(V, c3, KV.tkeys(V, c4, KV.tkeys(V, c5, KV.tkeys(V, c6, KV.tkeys(V, c7, KV.tkeys(V, c8, KV.tkeys(V, c9, KV.tkeys(V, c10, KV.tkeys(V, c11, KV.tkeys(V, c12, KV.tkeys(V, c13, KV.tkeys(V, c14, KV.tkeys(V, c15, List.append(&2, String, a, b))))))))))))))))) == KV.tkeys(V, c0, KV.tkeys(V, c1, KV.tkeys(V, c2, KV.tkeys(V, c3, KV.tkeys(V, c4, KV.tkeys(V, c5, KV.tkeys(V, c6, KV.tkeys(V, c7, KV.tkeys(V, c8, KV.tkeys(V, c9, KV.tkeys(V, c10, KV.tkeys(V, c11, KV.tkeys(V, c12, _))))))))))))) : List<&2, String>}
      %tkeys_app(V, c14, KV.tkeys(V, c15, a), b) : {KV.tkeys(V, c0, KV.tkeys(V, c1, KV.tkeys(V, c2, KV.tkeys(V, c3, KV.tkeys(V, c4, KV.tkeys(V, c5, KV.tkeys(V, c6, KV.tkeys(V, c7, KV.tkeys(V, c8, KV.tkeys(V, c9, KV.tkeys(V, c10, KV.tkeys(V, c11, KV.tkeys(V, c12, KV.tkeys(V, c13, KV.tkeys(V, c14, KV.tkeys(V, c15, List.append(&2, String, a, b))))))))))))))))) == KV.tkeys(V, c0, KV.tkeys(V, c1, KV.tkeys(V, c2, KV.tkeys(V, c3, KV.tkeys(V, c4, KV.tkeys(V, c5, KV.tkeys(V, c6, KV.tkeys(V, c7, KV.tkeys(V, c8, KV.tkeys(V, c9, KV.tkeys(V, c10, KV.tkeys(V, c11, KV.tkeys(V, c12, KV.tkeys(V, c13, _)))))))))))))) : List<&2, String>}
      %tkeys_app(V, c15, a, b) : {KV.tkeys(V, c0, KV.tkeys(V, c1, KV.tkeys(V, c2, KV.tkeys(V, c3, KV.tkeys(V, c4, KV.tkeys(V, c5, KV.tkeys(V, c6, KV.tkeys(V, c7, KV.tkeys(V, c8, KV.tkeys(V, c9, KV.tkeys(V, c10, KV.tkeys(V, c11, KV.tkeys(V, c12, KV.tkeys(V, c13, KV.tkeys(V, c14, KV.tkeys(V, c15, List.append(&2, String, a, b))))))))))))))))) == KV.tkeys(V, c0, KV.tkeys(V, c1, KV.tkeys(V, c2, KV.tkeys(V, c3, KV.tkeys(V, c4, KV.tkeys(V, c5, KV.tkeys(V, c6, KV.tkeys(V, c7, KV.tkeys(V, c8, KV.tkeys(V, c9, KV.tkeys(V, c10, KV.tkeys(V, c11, KV.tkeys(V, c12, KV.tkeys(V, c13, KV.tkeys(V, c14, _))))))))))))))) : List<&2, String>}
      {==}
    case KV.Ent{k, v, rest}:
      Equal.cong(List<&2, String>, List<&2, String>, z => k <> z, KV.tkeys(V, rest, List.append(&2, String, a, b)), List.append(&2, String, KV.tkeys(V, rest, a), b), tkeys_app(V, rest, a, b))

# and so do the keys under a digit of the root
def keys_at_app(-V: Data, t: KV.Trie<V>, x: KV.Hex, -a: List<&2, String>, -b: List<&2, String>) -> {KV.keys.at(V, t, x, List.append(&2, String, a, b)) == List.append(&2, String, KV.keys.at(V, t, x, a), b) : List<&2, String>}:
  match t x:
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H0{}:
      tkeys_app(V, c0, a, b)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H1{}:
      tkeys_app(V, c1, a, b)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H2{}:
      tkeys_app(V, c2, a, b)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H3{}:
      tkeys_app(V, c3, a, b)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H4{}:
      tkeys_app(V, c4, a, b)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H5{}:
      tkeys_app(V, c5, a, b)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H6{}:
      tkeys_app(V, c6, a, b)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H7{}:
      tkeys_app(V, c7, a, b)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H8{}:
      tkeys_app(V, c8, a, b)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H9{}:
      tkeys_app(V, c9, a, b)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H10{}:
      tkeys_app(V, c10, a, b)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H11{}:
      tkeys_app(V, c11, a, b)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H12{}:
      tkeys_app(V, c12, a, b)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H13{}:
      tkeys_app(V, c13, a, b)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H14{}:
      tkeys_app(V, c14, a, b)
    case KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15} KV.H15{}:
      tkeys_app(V, c15, a, b)
    case KV.Tip{} _:
      {==}
    case KV.Ent{ka, va, ra} _:
      {==}
# END gen_trie: folds

# two tries with the same subtrie at a key's digit read the key alike
def get_child(-V: Data, +t: KV.Trie<V>, +u: KV.Trie<V>, +k: String) -> {KV.child(V, t, KV.hex(KV.hash(k))) == KV.child(V, u, KV.hex(KV.hash(k))) : KV.Trie<V>} -> {KV.get(V, t, k) == KV.get(V, u, k) : Maybe<&2, V>}:
  e => %get_root(V, t, KV.hex(KV.hash(k)), KV.hash(k), k) : {_ == KV.get(V, u, k) : Maybe<&2, V>}
       %get_root(V, u, KV.hex(KV.hash(k)), KV.hash(k), k) : {KV.tget_k(V, 4n, KV.child(V, t, KV.hex(KV.hash(k))), KV.hex(KV.shr4(KV.hash(k))), KV.shr4(KV.hash(k)), k) == _ : Maybe<&2, V>}
       Equal.cong(KV.Trie<V>, Maybe<&2, V>, z => KV.tget_k(V, 4n, z, KV.hex(KV.shr4(KV.hash(k))), KV.shr4(KV.hash(k)), k), KV.child(V, t, KV.hex(KV.hash(k))), KV.child(V, u, KV.hex(KV.hash(k))), e)

# a write from the root leaves at its digit the subtrie a write through
# the subtrie there gives
def child_mod(-V: Data, +t: KV.Trie<V>, +x: KV.Hex, -h: U32, -op: KV.Op<V>) -> {KV.tmod_h(V, 4n, KV.child(V, t, x), KV.hex(KV.shr4(h)), KV.shr4(h), op) == KV.child(V, KV.tmod_h(V, 5n, t, x, h, op), x) : KV.Trie<V>}:
  %mod_root(V, t, x, h, op) : {KV.tmod_h(V, 4n, KV.child(V, t, x), KV.hex(KV.shr4(h)), KV.shr4(h), op) == KV.child(V, _, x) : KV.Trie<V>}
  child_with_same(V, t, x, KV.tmod_h(V, 4n, KV.child(V, t, x), KV.hex(KV.shr4(h)), KV.shr4(h), op))

# and leaves the subtries at the other digits
def mod_other(-V: Data, +t: KV.Trie<V>, +x: KV.Hex, -h: U32, -op: KV.Op<V>, +y: KV.Hex) -> {False{} == KV.hex_eq(y, x) : Bool} -> {KV.child(V, t, y) == KV.child(V, KV.tmod_h(V, 5n, t, x, h, op), y) : KV.Trie<V>}:
  e => %mod_root(V, t, x, h, op) : {KV.child(V, t, y) == KV.child(V, _, y) : KV.Trie<V>}
       child_with_other(V, t, x, KV.tmod_h(V, 4n, KV.child(V, t, x), KV.hex(KV.shr4(h)), KV.shr4(h), op), y)(e)

# two tries with the same subtrie at a write's digit have the same
# subtrie there after the write
def mod_same(-V: Data, +t: KV.Trie<V>, +u: KV.Trie<V>, +x: KV.Hex, -h: U32, -op: KV.Op<V>) -> {KV.child(V, t, x) == KV.child(V, u, x) : KV.Trie<V>} -> {KV.child(V, KV.tmod_h(V, 5n, t, x, h, op), x) == KV.child(V, KV.tmod_h(V, 5n, u, x, h, op), x) : KV.Trie<V>}:
  e => %child_mod(V, t, x, h, op) : {_ == KV.child(V, KV.tmod_h(V, 5n, u, x, h, op), x) : KV.Trie<V>}
       %child_mod(V, u, x, h, op) : {KV.tmod_h(V, 4n, KV.child(V, t, x), KV.hex(KV.shr4(h)), KV.shr4(h), op) == _ : KV.Trie<V>}
       Equal.cong(KV.Trie<V>, KV.Trie<V>, z => KV.tmod_h(V, 4n, z, KV.hex(KV.shr4(h)), KV.shr4(h), op), KV.child(V, t, x), KV.child(V, u, x), e)

# The laws
# ========

def Laws.get_empty(V, k):
  {==}

def Laws.get_set_same(V, t, k, v):
  %tget_k_eq(V, 5n, KV.tmod_h(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k), KV.OSet{k, v}), KV.hex(KV.hash(k)), KV.hash(k), k) : {_ == Some{v} : Maybe<&2, V>}
  %tget_tmod_same(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k), KV.OSet{k, v}) : {KV.bget(V, k, _) == Some{v} : Maybe<&2, V>}
  Equal.sym(Maybe<&2, V>, Some{v}, KV.bget(V, k, KV.bset(V, k, v, KV.tget_h(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k)))), bget_bset_same(V, k, v, KV.tget_h(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k))))

def set_other_step(-V: Data, +t: KV.Trie<V>, +k: String, +j: String, +v: V, +nb: {False{} == KV.str_eq(j, k) : Bool}, c: Bool)
  -> {dsame(5n, KV.hex(KV.hash(k)), KV.hash(k), KV.hex(KV.hash(j)), KV.hash(j)) == c : Bool}
  -> {KV.bget(V, j, KV.tget_h(V, 5n, KV.tmod_h(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k), KV.OSet{k, v}), KV.hex(KV.hash(j)), KV.hash(j))) == KV.bget(V, j, KV.tget_h(V, 5n, t, KV.hex(KV.hash(j)), KV.hash(j))) : Maybe<&2, V>}:
  match c:
    case True{}:
      +e => %walk_same(V, 5n, KV.tmod_h(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k), KV.OSet{k, v}), KV.hex(KV.hash(k)), KV.hash(k), KV.hex(KV.hash(j)), KV.hash(j))(e) : {KV.bget(V, j, _) == KV.bget(V, j, KV.tget_h(V, 5n, t, KV.hex(KV.hash(j)), KV.hash(j))) : Maybe<&2, V>}
            %walk_same(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k), KV.hex(KV.hash(j)), KV.hash(j))(e) : {KV.bget(V, j, KV.tget_h(V, 5n, KV.tmod_h(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k), KV.OSet{k, v}), KV.hex(KV.hash(k)), KV.hash(k))) == KV.bget(V, j, _) : Maybe<&2, V>}
            %tget_tmod_same(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k), KV.OSet{k, v}) : {KV.bget(V, j, _) == KV.bget(V, j, KV.tget_h(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k))) : Maybe<&2, V>}
            Equal.sym(Maybe<&2, V>, KV.bget(V, j, KV.tget_h(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k))), KV.bget(V, j, KV.bset(V, k, v, KV.tget_h(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k)))), bget_bset_other(V, j, k, v, KV.tget_h(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k)), nb))
    case False{}:
      e => Equal.cong(KV.Trie<V>, Maybe<&2, V>, b => KV.bget(V, j, b), KV.tget_h(V, 5n, KV.tmod_h(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k), KV.OSet{k, v}), KV.hex(KV.hash(j)), KV.hash(j)), KV.tget_h(V, 5n, t, KV.hex(KV.hash(j)), KV.hash(j)), tget_tmod_other(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k), KV.hex(KV.hash(j)), KV.hash(j), KV.OSet{k, v})(e))

def Laws.get_set_other(V, t, k, j, v, ne):
  %tget_k_eq(V, 5n, KV.tmod_h(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k), KV.OSet{k, v}), KV.hex(KV.hash(j)), KV.hash(j), j) : {_ == KV.get(V, t, j) : Maybe<&2, V>}
  %tget_k_eq(V, 5n, t, KV.hex(KV.hash(j)), KV.hash(j), j) : {KV.bget(V, j, KV.tget_h(V, 5n, KV.tmod_h(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k), KV.OSet{k, v}), KV.hex(KV.hash(j)), KV.hash(j))) == _ : Maybe<&2, V>}
  set_other_step(V, t, k, j, v, str_eq_ne(j, k, ne), dsame(5n, KV.hex(KV.hash(k)), KV.hash(k), KV.hex(KV.hash(j)), KV.hash(j)))({==})

def Laws.get_del_same(V, t, k):
  %tget_k_eq(V, 5n, KV.tmod_h(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k), KV.ODel{k}), KV.hex(KV.hash(k)), KV.hash(k), k) : {_ == None{} : Maybe<&2, V>}
  %tget_tmod_same(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k), KV.ODel{k}) : {KV.bget(V, k, _) == None{} : Maybe<&2, V>}
  Equal.sym(Maybe<&2, V>, None{}, KV.bget(V, k, KV.bdel(V, k, KV.tget_h(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k)))), bget_bdel_same(V, k, KV.tget_h(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k))))

def del_other_step(-V: Data, +t: KV.Trie<V>, +k: String, +j: String, +nb: {False{} == KV.str_eq(j, k) : Bool}, c: Bool)
  -> {dsame(5n, KV.hex(KV.hash(k)), KV.hash(k), KV.hex(KV.hash(j)), KV.hash(j)) == c : Bool}
  -> {KV.bget(V, j, KV.tget_h(V, 5n, KV.tmod_h(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k), KV.ODel{k}), KV.hex(KV.hash(j)), KV.hash(j))) == KV.bget(V, j, KV.tget_h(V, 5n, t, KV.hex(KV.hash(j)), KV.hash(j))) : Maybe<&2, V>}:
  match c:
    case True{}:
      +e => %walk_same(V, 5n, KV.tmod_h(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k), KV.ODel{k}), KV.hex(KV.hash(k)), KV.hash(k), KV.hex(KV.hash(j)), KV.hash(j))(e) : {KV.bget(V, j, _) == KV.bget(V, j, KV.tget_h(V, 5n, t, KV.hex(KV.hash(j)), KV.hash(j))) : Maybe<&2, V>}
            %walk_same(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k), KV.hex(KV.hash(j)), KV.hash(j))(e) : {KV.bget(V, j, KV.tget_h(V, 5n, KV.tmod_h(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k), KV.ODel{k}), KV.hex(KV.hash(k)), KV.hash(k))) == KV.bget(V, j, _) : Maybe<&2, V>}
            %tget_tmod_same(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k), KV.ODel{k}) : {KV.bget(V, j, _) == KV.bget(V, j, KV.tget_h(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k))) : Maybe<&2, V>}
            Equal.sym(Maybe<&2, V>, KV.bget(V, j, KV.tget_h(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k))), KV.bget(V, j, KV.bdel(V, k, KV.tget_h(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k)))), bget_bdel_other(V, j, k, KV.tget_h(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k)), nb))
    case False{}:
      e => Equal.cong(KV.Trie<V>, Maybe<&2, V>, b => KV.bget(V, j, b), KV.tget_h(V, 5n, KV.tmod_h(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k), KV.ODel{k}), KV.hex(KV.hash(j)), KV.hash(j)), KV.tget_h(V, 5n, t, KV.hex(KV.hash(j)), KV.hash(j)), tget_tmod_other(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k), KV.hex(KV.hash(j)), KV.hash(j), KV.ODel{k})(e))

def Laws.get_del_other(V, t, k, j, ne):
  %tget_k_eq(V, 5n, KV.tmod_h(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k), KV.ODel{k}), KV.hex(KV.hash(j)), KV.hash(j), j) : {_ == KV.get(V, t, j) : Maybe<&2, V>}
  %tget_k_eq(V, 5n, t, KV.hex(KV.hash(j)), KV.hash(j), j) : {KV.bget(V, j, KV.tget_h(V, 5n, KV.tmod_h(V, 5n, t, KV.hex(KV.hash(k)), KV.hash(k), KV.ODel{k}), KV.hex(KV.hash(j)), KV.hash(j))) == _ : Maybe<&2, V>}
  del_other_step(V, t, k, j, str_eq_ne(j, k, ne), dsame(5n, KV.hex(KV.hash(k)), KV.hash(k), KV.hex(KV.hash(j)), KV.hash(j)))({==})

# Keys
# ====

def Laws.key_eq_true(a, b, e):
  %e : Reflect(String, a, b, _)
  str_refl(a, b)

def Laws.key_eq_false(a, b, e):
  %e : Reflect(String, a, b, _)
  str_refl(a, b)

# Commands
# ========

def Laws.get_after_set(db, k, v):
  Equal.cong(Maybe<&2, String>, R.Reply, m => R.r_get(m), KV.get(String, KV.set(String, db, k, v), k), Some{v}, Laws.get_set_same(String, db, k, v))

def Laws.get_missing(db, k, e):
  Equal.cong(Maybe<&2, String>, R.Reply & KV.Trie<String>, m => (R.r_get(m), db), KV.get(String, db, k), None{}, e)

def del_one_step(b: Bool, -d: KV.Trie<String>) -> {R.reply_of(R.del_reply(R.del_keys.put(b, (0n, d)))) == R.r_int(Bool.pick(Nat, b, 1n, 0n)) : R.Reply}:
  match b:
    case True{}:
      {==}
    case False{}:
      {==}

def Laws.del_one_count(db, k):
  del_one_step(KV.has(String, db, k), KV.del(String, db, k))

def append_to_spec(m: Maybe<&2, String>, -v: String) -> {R.append_to(m, v) == Laws.old_or_empty(m) ++ v : String}:
  match m:
    case Some{x}:
      {==}
    case None{}:
      {==}

def Laws.append_effect(db, k, s):
  %append_to_spec(KV.get(String, db, k), s) : {(R.r_int(String.length(R.append_to(KV.get(String, db, k), s))), KV.set(String, db, k, R.append_to(KV.get(String, db, k), s))) == (R.r_int(String.length(_)), KV.set(String, db, k, _)) : R.Reply & KV.Trie<String>}
  {==}

def Laws.setnx_missing(db, k, v, e):
  %Equal.sym(Maybe<&2, String>, KV.get(String, db, k), None{}, e) : {R.setnx.if(db, k, v, KV.hash(k), Maybe.is_some(&2, String, _)) == (R.r_int(1n), KV.set(String, db, k, v)) : R.Reply & KV.Trie<String>}
  {==}

def Laws.setnx_present(db, k, v, x, e):
  %Equal.sym(Maybe<&2, String>, KV.get(String, db, k), Some{x}, e) : {R.setnx.if(db, k, v, KV.hash(k), Maybe.is_some(&2, String, _)) == (R.r_int(0n), db) : R.Reply & KV.Trie<String>}
  {==}

def Laws.incr_missing(db, k, e):
  %Equal.sym(Maybe<&2, String>, KV.get(String, db, k), None{}, e) : {R.incr.got(db, k, KV.hash(k), R.IPos{1n}, R.incr.old(_)) == (R.RInt{R.IPos{1n}}, KV.set(String, db, k, "1")) : R.Reply & KV.Trie<String>}
  {==}

def Laws.batch_nil(db):
  {==}

# Reads
# -----

def reads_go(c: R.Cmd, +db: KV.Trie<String>) -> {Laws.is_read(c) == True{} : Bool} -> {R.db_of(R.exec(c, db)) == db : KV.Trie<String>}:
  match c:
    case R.Ping{}:
      e => {==}
    case R.Echo{m}:
      e => {==}
    case R.Get{k}:
      e => {==}
    case R.Exists{ks}:
      e => {==}
    case R.Strlen{k}:
      e => {==}
    case R.MGet{ks}:
      e => {==}
    case R.DbSize{}:
      e => {==}
    case R.Keys{p}:
      e => {==}
    case R.Bad{r}:
      e => {==}
    case R.SizeAt{x}:
      e => {==}
    case R.KeysAt{p, x}:
      e => {==}
    case R.FlushAt{x}:
      e => Empty.absurd({R.db_of(R.exec(R.FlushAt{x}, db)) == db : KV.Trie<String>}, false_true(e))
    case R.Set{k, v}:
      e => Empty.absurd({R.db_of(R.exec(R.Set{k, v}, db)) == db : KV.Trie<String>}, false_true(e))
    case R.SetNX{k, v}:
      e => Empty.absurd({R.db_of(R.exec(R.SetNX{k, v}, db)) == db : KV.Trie<String>}, false_true(e))
    case R.GetSet{k, v}:
      e => Empty.absurd({R.db_of(R.exec(R.GetSet{k, v}, db)) == db : KV.Trie<String>}, false_true(e))
    case R.Del{ks}:
      e => Empty.absurd({R.db_of(R.exec(R.Del{ks}, db)) == db : KV.Trie<String>}, false_true(e))
    case R.IncrBy{k, by}:
      e => Empty.absurd({R.db_of(R.exec(R.IncrBy{k, by}, db)) == db : KV.Trie<String>}, false_true(e))
    case R.Append{k, v}:
      e => Empty.absurd({R.db_of(R.exec(R.Append{k, v}, db)) == db : KV.Trie<String>}, false_true(e))
    case R.MSet{ps}:
      e => Empty.absurd({R.db_of(R.exec(R.MSet{ps}, db)) == db : KV.Trie<String>}, false_true(e))
    case R.FlushAll{}:
      e => Empty.absurd({R.db_of(R.exec(R.FlushAll{}, db)) == db : KV.Trie<String>}, false_true(e))

def Laws.reads_keep_db(c, db, e):
  reads_go(c, db)(e)

# Multi-key writes
# ----------------
# DEL and MSET fold the map's delete and set over their keys; their laws
# follow from the map's laws, one key at a time

# what DEL computes, spelled as two folds
def del_all(ks: List<&2, String>, db: KV.Trie<String>) -> KV.Trie<String>:
  match ks:
    case Nil{}:
      db
    case Con{+k, rest}:
      del_all(rest, KV.del(String, db, k))

def del_count(ks: List<&2, String>, +db: KV.Trie<String>) -> Nat:
  match ks:
    case Nil{}:
      0n
    case Con{+k, rest}:
      +c = del_count(rest, KV.del(String, db, k))
      Bool.pick(Nat, KV.has(String, db, k), 1n+c, c)

def del_put(b: Bool, -n: Nat, -d: KV.Trie<String>) -> {(Bool.pick(Nat, b, 1n+n, n), d) == R.del_keys.put(b, (n, d)) : Nat & KV.Trie<String>}:
  match b:
    case True{}:
      {==}
    case False{}:
      {==}

def del_keys_eq(ks: List<&2, String>, +db: KV.Trie<String>) -> {(del_count(ks, db), del_all(ks, db)) == R.del_keys(ks, db) : Nat & KV.Trie<String>}:
  match ks:
    case Nil{}:
      {==}
    case Con{+k, +rest}:
      %del_keys_eq(rest, KV.del(String, db, k)) : {(Bool.pick(Nat, KV.has(String, db, k), 1n+del_count(rest, KV.del(String, db, k)), del_count(rest, KV.del(String, db, k))), del_all(rest, KV.del(String, db, k))) == R.del_keys.put(KV.has(String, db, k), _) : Nat & KV.Trie<String>}
      del_put(KV.has(String, db, k), del_count(rest, KV.del(String, db, k)), del_all(rest, KV.del(String, db, k)))

# DEL changes the database as del_all does
def exec_del(ks: List<&2, String>, +db: KV.Trie<String>) -> {del_all(ks, db) == R.db_of(R.exec(R.Del{ks}, db)) : KV.Trie<String>}:
  %del_keys_eq(ks, db) : {del_all(ks, db) == R.db_of(R.del_reply(_)) : KV.Trie<String>}
  {==}

# a Bool.or that is False has two False halves
def or_false_l(a: Bool, -b: Bool) -> {Bool.or(a, b) == False{} : Bool} -> {a == False{} : Bool}:
  match a:
    case True{}:
      e => Empty.absurd({True{} == False{} : Bool}, true_false(e))
    case False{}:
      e => {==}

def or_false_r(a: Bool, -b: Bool) -> {Bool.or(a, b) == False{} : Bool} -> {b == False{} : Bool}:
  match a:
    case True{}:
      e => Empty.absurd({b == False{} : Bool}, true_false(e))
    case False{}:
      e => e

# deleting keys other than j leaves j as it was
def del_all_frame(ks: List<&2, String>, +db: KV.Trie<String>, +j: String) -> {Laws.any_key(j, ks) == False{} : Bool} -> {KV.get(String, del_all(ks, db), j) == KV.get(String, db, j) : Maybe<&2, String>}:
  match ks:
    case Nil{}:
      e => {==}
    case Con{+k, +rest}:
      +e => Equal.trans(Maybe<&2, String>, KV.get(String, del_all(rest, KV.del(String, db, k)), j), KV.get(String, KV.del(String, db, k), j), KV.get(String, db, j),
              del_all_frame(rest, KV.del(String, db, k), j)(or_false_r(KV.str_eq(j, k), Laws.any_key(j, rest))(e)),
              Laws.get_del_other(String, db, k, j, Laws.key_eq_false(j, k, or_false_l(KV.str_eq(j, k), Laws.any_key(j, rest))(e))))

def del_none(+db: KV.Trie<String>, +k: String, +j: String, c: Bool) -> Reflect(String, j, k, c) -> {KV.get(String, db, j) == None{} : Maybe<&2, String>} -> {KV.get(String, KV.del(String, db, k), j) == None{} : Maybe<&2, String>}:
  match c:
    case True{}:
      ejk => e => %ejk : {KV.get(String, KV.del(String, db, _), j) == None{} : Maybe<&2, String>}
                  Laws.get_del_same(String, db, j)
    case False{}:
      ne => e => Equal.trans(Maybe<&2, String>, KV.get(String, KV.del(String, db, k), j), KV.get(String, db, j), None{}, Laws.get_del_other(String, db, k, j, ne), e)

# a missing key stays missing through any deletes
def del_all_none(ks: List<&2, String>, +db: KV.Trie<String>, +j: String) -> {KV.get(String, db, j) == None{} : Maybe<&2, String>} -> {KV.get(String, del_all(ks, db), j) == None{} : Maybe<&2, String>}:
  match ks:
    case Nil{}:
      e => e
    case Con{+k, +rest}:
      e => del_all_none(rest, KV.del(String, db, k), j)(del_none(db, k, j, KV.str_eq(j, k), str_refl(j, k), e))


# a deleted key reads as missing, under any name equal to it
def get_del_eq(+db: KV.Trie<String>, -k: String, +j: String, ejk: {j == k : String}) -> {KV.get(String, KV.del(String, db, k), j) == None{} : Maybe<&2, String>}:
  %ejk : {KV.get(String, KV.del(String, db, _), j) == None{} : Maybe<&2, String>}
  Laws.get_del_same(String, db, j)

def del_eff_step(+db: KV.Trie<String>, +k: String, +rest: List<&2, String>, +j: String, c1: Bool, c2: Bool)
  -> Reflect(String, j, k, c1)
  -> ({c2 == True{} : Bool} -> {KV.get(String, del_all(rest, KV.del(String, db, k)), j) == None{} : Maybe<&2, String>})
  -> {Bool.or(c1, c2) == True{} : Bool}
  -> {KV.get(String, del_all(rest, KV.del(String, db, k)), j) == None{} : Maybe<&2, String>}:
  match c1 c2:
    case True{} _:
      ejk => ih => e => del_all_none(rest, KV.del(String, db, k), j)(get_del_eq(db, k, j, ejk))
    case False{} True{}:
      ne => ih => e => ih({==})
    case False{} False{}:
      ne => ih => e => Empty.absurd({KV.get(String, del_all(rest, KV.del(String, db, k)), j) == None{} : Maybe<&2, String>}, false_true(e))

# every key DEL names is missing afterwards
def del_all_effect(ks: List<&2, String>, +db: KV.Trie<String>, +j: String) -> {Laws.any_key(j, ks) == True{} : Bool} -> {KV.get(String, del_all(ks, db), j) == None{} : Maybe<&2, String>}:
  match ks:
    case Nil{}:
      e => Empty.absurd({KV.get(String, db, j) == None{} : Maybe<&2, String>}, false_true(e))
    case Con{+k, +rest}:
      del_eff_step(db, k, rest, j, KV.str_eq(j, k), Laws.any_key(j, rest))(str_refl(j, k), del_all_effect(rest, KV.del(String, db, k), j))

def Laws.del_effect(ks, db, j, e):
  %exec_del(ks, db) : {KV.get(String, _, j) == None{} : Maybe<&2, String>}
  del_all_effect(ks, db, j)(e)

# The frame law
# -------------

def setnx_frame(+db: KV.Trie<String>, +k: String, +v: String, +j: String, b: Bool, ne: {j != k : String}) -> {KV.get(String, R.db_of(R.setnx.if(db, k, v, KV.hash(k), b)), j) == KV.get(String, db, j) : Maybe<&2, String>}:
  match b:
    case True{}:
      {==}
    case False{}:
      Laws.get_set_other(String, db, k, j, v, ne)

def incr_fit_frame(+db: KV.Trie<String>, +k: String, +n: R.Int, +j: String, ok: Bool, ne: {j != k : String}) -> {KV.get(String, R.db_of(R.incr.fit(db, k, KV.hash(k), n, ok)), j) == KV.get(String, db, j) : Maybe<&2, String>}:
  match ok:
    case True{}:
      Laws.get_set_other(String, db, k, j, R.int_show(n), ne)
    case False{}:
      {==}

def incr_frame(+db: KV.Trie<String>, +k: String, +by: R.Int, +j: String, m: Maybe<&2, R.Int>, ne: {j != k : String}) -> {KV.get(String, R.db_of(R.incr.got(db, k, KV.hash(k), by, m)), j) == KV.get(String, db, j) : Maybe<&2, String>}:
  match m:
    case None{}:
      {==}
    case Some{+x}:
      incr_fit_frame(db, k, R.int_add(x, by), j, R.int_fits(R.int_add(x, by)), ne)

def mset_frame(ps: List<&2, R.KVPair>, +db: KV.Trie<String>, +j: String) -> {Laws.any_pair(j, ps) == False{} : Bool} -> {KV.get(String, R.mset_pairs(ps, db), j) == KV.get(String, db, j) : Maybe<&2, String>}:
  match ps:
    case Nil{}:
      e => {==}
    case Con{R.KP{+k, +v}, +rest}:
      +e => Equal.trans(Maybe<&2, String>, KV.get(String, R.mset_pairs(rest, KV.set(String, db, k, v)), j), KV.get(String, KV.set(String, db, k, v), j), KV.get(String, db, j),
              mset_frame(rest, KV.set(String, db, k, v), j)(or_false_r(KV.str_eq(j, k), Laws.any_pair(j, rest))(e)),
              Laws.get_set_other(String, db, k, j, v, Laws.key_eq_false(j, k, or_false_l(KV.str_eq(j, k), Laws.any_pair(j, rest))(e))))

def frame_go(c: R.Cmd, +db: KV.Trie<String>, +j: String) -> {Laws.writes(c, j) == False{} : Bool} -> {KV.get(String, R.db_of(R.exec(c, db)), j) == KV.get(String, db, j) : Maybe<&2, String>}:
  match c:
    case R.Set{+k, +v}:
      e => Laws.get_set_other(String, db, k, j, v, Laws.key_eq_false(j, k, e))
    case R.GetSet{+k, +v}:
      e => Laws.get_set_other(String, db, k, j, v, Laws.key_eq_false(j, k, e))
    case R.Append{+k, +v}:
      e => Laws.get_set_other(String, db, k, j, R.append_to(KV.get(String, db, k), v), Laws.key_eq_false(j, k, e))
    case R.SetNX{+k, +v}:
      e => setnx_frame(db, k, v, j, Maybe.is_some(&2, String, KV.get(String, db, k)), Laws.key_eq_false(j, k, e))
    case R.IncrBy{+k, +by}:
      e => incr_frame(db, k, by, j, R.incr.old(KV.get(String, db, k)), Laws.key_eq_false(j, k, e))
    case R.Del{+ks}:
      e => %exec_del(ks, db) : {KV.get(String, _, j) == KV.get(String, db, j) : Maybe<&2, String>}
           del_all_frame(ks, db, j)(e)
    case R.MSet{+ps}:
      e => mset_frame(ps, db, j)(e)
    case R.FlushAll{}:
      e => Empty.absurd({KV.get(String, KV.clear(String, db), j) == KV.get(String, db, j) : Maybe<&2, String>}, true_false(e))
    case R.FlushAt{+x}:
      e => get_child(String, KV.with_child(String, db, x, KV.empty(String)), db, j)(Equal.sym(KV.Trie<String>, KV.child(String, db, KV.hex(KV.hash(j))), KV.child(String, KV.with_child(String, db, x, KV.empty(String)), KV.hex(KV.hash(j))), child_with_other(String, db, x, KV.empty(String), KV.hex(KV.hash(j)))(Equal.sym(Bool, KV.hex_eq(KV.hex(KV.hash(j)), x), False{}, e))))
    case R.SizeAt{x}:
      e => {==}
    case R.KeysAt{p, x}:
      e => {==}
    case R.Ping{}:
      e => {==}
    case R.Echo{m}:
      e => {==}
    case R.Get{k}:
      e => {==}
    case R.Exists{ks}:
      e => {==}
    case R.Strlen{k}:
      e => {==}
    case R.MGet{ks}:
      e => {==}
    case R.DbSize{}:
      e => {==}
    case R.Keys{p}:
      e => {==}
    case R.Bad{r}:
      e => {==}

def Laws.frame(c, db, j, e):
  frame_go(c, db, j)(e)

# Batches
# -------
# exec_all accumulates replies in reverse and flips them at the end; run
# is the plain recursive spec. G generalizes over the accumulator, and
# eta lets a computed pair be taken apart.

def rfst(r: List<&2, R.Reply> & KV.Trie<String>) -> List<&2, R.Reply>:
  (rs, db) = r
  rs

def rsnd(r: List<&2, R.Reply> & KV.Trie<String>) -> KV.Trie<String>:
  (rs, db) = r
  db

def eta_r(p: R.Reply & KV.Trie<String>) -> {(R.reply_of(p), R.db_of(p)) == p : R.Reply & KV.Trie<String>}:
  (x, db) = p
  {==}

def eta_l(p: List<&2, R.Reply> & KV.Trie<String>) -> {(rfst(p), rsnd(p)) == p : List<&2, R.Reply> & KV.Trie<String>}:
  (rs, db) = p
  {==}

def run(cs: List<&2, R.Cmd>, +db: KV.Trie<String>) -> List<&2, R.Reply> & KV.Trie<String>:
  match cs:
    case Nil{}:
      (Nil{}, db)
    case Con{+c, rest}:
      R.exec_all.cons(R.reply_of(R.exec(c, db)), run(rest, R.db_of(R.exec(c, db))))

def batch_go(cs: List<&2, R.Cmd>, +acc: List<&2, R.Reply>, +d: KV.Trie<String>)
  -> {(List.reverse.go(&2, R.Reply, acc, rfst(run(cs, d))), rsnd(run(cs, d))) == R.exec_all.fin(R.exec_all.go(cs, (acc, d))) : List<&2, R.Reply> & KV.Trie<String>}:
  match cs:
    case Nil{}:
      {==}
    case Con{+c, +rest}:
      %eta_r(R.exec(c, d)) : {(List.reverse.go(&2, R.Reply, acc, rfst(run(Con{c, rest}, d))), rsnd(run(Con{c, rest}, d))) == R.exec_all.fin(R.exec_all.go(rest, R.exec_all.put(acc, _))) : List<&2, R.Reply> & KV.Trie<String>}
      %batch_go(rest, Con{R.reply_of(R.exec(c, d)), acc}, R.db_of(R.exec(c, d))) : {(List.reverse.go(&2, R.Reply, acc, rfst(run(Con{c, rest}, d))), rsnd(run(Con{c, rest}, d))) == _ : List<&2, R.Reply> & KV.Trie<String>}
      %eta_l(run(rest, R.db_of(R.exec(c, d)))) : {(List.reverse.go(&2, R.Reply, acc, rfst(R.exec_all.cons(R.reply_of(R.exec(c, d)), _))), rsnd(R.exec_all.cons(R.reply_of(R.exec(c, d)), _))) == (List.reverse.go(&2, R.Reply, Con{R.reply_of(R.exec(c, d)), acc}, rfst(run(rest, R.db_of(R.exec(c, d))))), rsnd(run(rest, R.db_of(R.exec(c, d))))) : List<&2, R.Reply> & KV.Trie<String>}
      {==}

# exec_all is run
def exec_all_run(+cs: List<&2, R.Cmd>, +d: KV.Trie<String>) -> {run(cs, d) == R.exec_all(cs, d) : List<&2, R.Reply> & KV.Trie<String>}:
  Equal.trans(List<&2, R.Reply> & KV.Trie<String>, run(cs, d), (rfst(run(cs, d)), rsnd(run(cs, d))), R.exec_all(cs, d),
    Equal.sym(List<&2, R.Reply> & KV.Trie<String>, (rfst(run(cs, d)), rsnd(run(cs, d))), run(cs, d), eta_l(run(cs, d))),
    batch_go(cs, Nil{}, d))

def Laws.batch_step(c, cs, db):
  %exec_all_run(cs, R.db_of(R.exec(c, db))) : {R.exec_all(Con{c, cs}, db) == R.exec_all.cons(R.reply_of(R.exec(c, db)), _) : List<&2, R.Reply> & KV.Trie<String>}
  %exec_all_run(Con{c, cs}, db) : {_ == R.exec_all.cons(R.reply_of(R.exec(c, db)), run(cs, R.db_of(R.exec(c, db)))) : List<&2, R.Reply> & KV.Trie<String>}
  {==}

# Hints
# -----

# exec.at with a hash that fits computes what exec does: a command on one
# key walks the trie with the hash given, which is its key's; the rest
# exec.at hands to exec
def exec_fit(c: R.Cmd, +h: U32, +db: KV.Trie<String>) -> Laws.fits(c, h) -> {R.exec.at(c, h, db) == R.exec(c, db) : R.Reply & KV.Trie<String>}:
  match c:
    case R.Get{+k}:
      e =>
        %Equal.sym(U32, h, KV.hash(k), e) : {R.exec.at(R.Get{k}, _, db) == R.exec(R.Get{k}, db) : R.Reply & KV.Trie<String>}
        %tget_kc_eq(5n, db, KV.hex(KV.hash(k)), KV.hash(k), k) : {(R.r_get(_), db) == R.exec(R.Get{k}, db) : R.Reply & KV.Trie<String>}
        {==}
    case R.Set{k, v}:
      e =>
        %Equal.sym(U32, h, KV.hash(k), e) : {R.exec.at(R.Set{k, v}, _, db) == R.exec(R.Set{k, v}, db) : R.Reply & KV.Trie<String>}
        {==}
    case R.SetNX{k, v}:
      e =>
        %Equal.sym(U32, h, KV.hash(k), e) : {R.exec.at(R.SetNX{k, v}, _, db) == R.exec(R.SetNX{k, v}, db) : R.Reply & KV.Trie<String>}
        {==}
    case R.GetSet{k, v}:
      e =>
        %Equal.sym(U32, h, KV.hash(k), e) : {R.exec.at(R.GetSet{k, v}, _, db) == R.exec(R.GetSet{k, v}, db) : R.Reply & KV.Trie<String>}
        {==}
    case R.IncrBy{k, by}:
      e =>
        %Equal.sym(U32, h, KV.hash(k), e) : {R.exec.at(R.IncrBy{k, by}, _, db) == R.exec(R.IncrBy{k, by}, db) : R.Reply & KV.Trie<String>}
        {==}
    case R.Append{k, v}:
      e =>
        %Equal.sym(U32, h, KV.hash(k), e) : {R.exec.at(R.Append{k, v}, _, db) == R.exec(R.Append{k, v}, db) : R.Reply & KV.Trie<String>}
        {==}
    case R.Strlen{k}:
      e =>
        %Equal.sym(U32, h, KV.hash(k), e) : {R.exec.at(R.Strlen{k}, _, db) == R.exec(R.Strlen{k}, db) : R.Reply & KV.Trie<String>}
        {==}
    case R.Ping{}:
      e => {==}
    case R.Echo{m}:
      e => {==}
    case R.Del{ks}:
      e => {==}
    case R.Exists{ks}:
      e => {==}
    case R.MGet{ks}:
      e => {==}
    case R.MSet{ps}:
      e => {==}
    case R.DbSize{}:
      e => {==}
    case R.FlushAll{}:
      e => {==}
    case R.Keys{p}:
      e => {==}
    case R.Bad{r}:
      e => {==}
    case R.SizeAt{x}:
      e => {==}
    case R.KeysAt{p, x}:
      e => {==}
    case R.FlushAt{x}:
      e => {==}

def Laws.exec_at(c, h, db, e):
  exec_fit(c, h, db)(e)

# so a batch run with hashes that fit is exec_all, a command at a time
def go_fit.con(+c: R.Cmd, -rest: List<&2, R.Cmd>, +h: U32, -hrest: List<&2, U32>, +rs: List<&2, R.Reply>, +db: KV.Trie<String>, e: Laws.fits(c, h) & Laws.all_fit(rest, hrest), ih: Laws.all_fit(rest, hrest) -> {R.exec_all.go.at(rest, hrest, (R.reply_of(R.exec(c, db)) <> rs, R.db_of(R.exec(c, db)))) == R.exec_all.go(rest, (R.reply_of(R.exec(c, db)) <> rs, R.db_of(R.exec(c, db)))) : List<&2, R.Reply> & KV.Trie<String>}) -> {R.exec_all.go.at(Con{c, rest}, Con{h, hrest}, (rs, db)) == R.exec_all.go(Con{c, rest}, (rs, db)) : List<&2, R.Reply> & KV.Trie<String>}:
  (e1, e2) = e
  %Equal.sym(R.Reply & KV.Trie<String>, R.exec.at(c, h, db), R.exec(c, db), exec_fit(c, h, db)(e1)) : {R.exec_all.go.at(rest, hrest, R.exec_all.put(rs, _)) == R.exec_all.go(rest, R.exec_all.put(rs, R.exec(c, db))) : List<&2, R.Reply> & KV.Trie<String>}
  %eta_r(R.exec(c, db)) : {R.exec_all.go.at(rest, hrest, R.exec_all.put(rs, _)) == R.exec_all.go(rest, R.exec_all.put(rs, _)) : List<&2, R.Reply> & KV.Trie<String>}
  ih(e2)

def go_fit(cs: List<&2, R.Cmd>, hs: List<&2, U32>, +rs: List<&2, R.Reply>, +db: KV.Trie<String>) -> Laws.all_fit(cs, hs) -> {R.exec_all.go.at(cs, hs, (rs, db)) == R.exec_all.go(cs, (rs, db)) : List<&2, R.Reply> & KV.Trie<String>}:
  match cs hs:
    case Con{+c, +rest} Con{+h, +hrest}:
      e => go_fit.con(c, rest, h, hrest, rs, db, e, e2 => go_fit(rest, hrest, R.reply_of(R.exec(c, db)) <> rs, R.db_of(R.exec(c, db)))(e2))
    case Con{c, rest} Nil{}:
      e => {==}
    case Nil{} _:
      e => {==}

# a batch run after its hints is exec_all.at, whatever the hints' verdict
def hinted_any(u: Bool, +cs: List<&2, R.Cmd>, +hs: List<&2, U32>, +db: KV.Trie<String>) -> {B.exec_hinted(u, cs, hs, db) == R.exec_all.at(cs, hs, db) : List<&2, R.Reply> & KV.Trie<String>}:
  match u:
    case True{}:
      {==}
    case False{}:
      {==}

def Laws.batch_hints(cs, hs, db, e):
  Equal.trans(List<&2, R.Reply> & KV.Trie<String>, B.exec_batch(cs, hs, db), R.exec_all.at(cs, hs, db), R.exec_all(cs, db),
    hinted_any(U32.is_eq(B.touch_if(B.many(hs), hs, db), 0), cs, hs, db),
    Equal.cong(List<&2, R.Reply> & KV.Trie<String>, List<&2, R.Reply> & KV.Trie<String>, z => R.exec_all.fin(z), R.exec_all.go.at(cs, hs, (Nil{}, db)), R.exec_all.go(cs, (Nil{}, db)), go_fit(cs, hs, Nil{}, db)(e)))

# The hashes of the requests
# --------------------------
# The connection parses each request into a B.Fit: a command, the hash it
# runs with, and why that hash fits it (batch.bend: fits, id_fit). Taking
# any list of them apart onto commands and hashes that fit gives commands
# and hashes that fit: each puts its proof before theirs.

def unzip_fit(fs: List<&2, B.Fit>, +cs: List<&2, R.Cmd>, +hs: List<&2, U32>, e: Laws.all_fit(cs, hs)) -> Laws.pair_fit(B.fit_unzip(fs, cs, hs)):
  match fs:
    case Nil{}:
      e
    case Con{B.Fit{c, h, ok}, rest}:
      unzip_fit(rest, c <> cs, h <> hs, (ok, e))

def Laws.fit_hashes(fs):
  unzip_fit(fs, Nil{}, Nil{}, Unit{})

# Shards
# ======
# The sharded server answers as the single one (LAWS: Shards). A command
# on several keys runs on the shards in pieces, a command of one key for
# each of its keys (shard.bend: each, pairs), and DBSIZE, KEYS and
# FLUSHALL run in a piece for each digit of the root, on that digit's
# subtrie (fan). A piece goes to one shard, its home: the shard of its
# key, or of its digit (home). The proof runs a history piece by piece,
# each piece on its home shard (seqT, on a list of tries; seqD, on one
# database), and shows four things:
# - under each digit of the root, the digit's shard holds the subtrie the
#   database holds (struct_seq), because a piece changes the subtrie under
#   its own digit alone (child_frame), as that subtrie alone decides
#   (child_loc); so every key reads in its shard as in the database;
# - a batch's pieces, pushed on the shards' lists, come back off them in
#   the batch's order (pop_push), each reply as a run of the piece on its
#   shard would give it, and that reply is the database's (reply_loc);
# - a command's pieces, run one after another on the database, give the
#   command's reply and database (mget_items, exists_total, del_total,
#   size_total, keys_cats, pieces_db);
# - the shards after a batch are those of the run (after_push).
# Bend can call a closure only once, and a hypothesis "for every digit" is
# a closure; so the proof never assumes one. struct_seq is a top-level
# function, called at whatever digit a step needs.

# Kit
# ---

def nat_eq(a: Nat, b: Nat) -> Bool:
  match a b:
    case 0n 0n:
      True{}
    case 1n+p 1n+q:
      nat_eq(p, q)
    case _ _:
      False{}

def is_zero(n: Nat) -> Type:
  match n:
    case 0n:
      Unit
    case 1n+p:
      Empty

def nat_pred(n: Nat) -> Nat:
  match n:
    case 0n:
      0n
    case 1n+p:
      p

def zero_succ(-q: Nat, e: {0n == 1n+q : Nat}) -> Empty:
  %e : is_zero(_)
  Unit{}

def nat_lift(-p: Nat, -q: Nat, c: Bool) -> Reflect(Nat, p, q, c) -> Reflect(Nat, 1n+p, 1n+q, c):
  match c:
    case True{}:
      e => %e : {1n+p == 1n+_ : Nat}
           {==}
    case False{}:
      ne => e => ne(Equal.cong(Nat, Nat, x => nat_pred(x), 1n+p, 1n+q, e))

def nat_refl(a: Nat, b: Nat) -> Reflect(Nat, a, b, nat_eq(a, b)):
  match a b:
    case 0n 0n:
      {==}
    case 0n 1n+q:
      e => zero_succ(q, e)
    case 1n+p 0n:
      e => zero_succ(p, Equal.sym(Nat, 1n+p, 0n, e))
    case 1n++p 1n++q:
      nat_lift(p, q, nat_eq(p, q))(nat_refl(p, q))

def and_r(a: Bool, -b: Bool) -> {Bool.and(a, b) == True{} : Bool} -> {b == True{} : Bool}:
  match a:
    case True{}:
      e => e
    case False{}:
      e => Empty.absurd({b == True{} : Bool}, false_true(e))

def and_l(a: Bool, -b: Bool) -> {Bool.and(a, b) == True{} : Bool} -> {a == True{} : Bool}:
  match a:
    case True{}:
      e => {==}
    case False{}:
      e => Empty.absurd({False{} == True{} : Bool}, false_true(e))

def and_true(a: Bool, -b: Bool) -> {a == True{} : Bool} -> {b == True{} : Bool} -> {Bool.and(a, b) == True{} : Bool}:
  match a:
    case True{}:
      ea => eb => eb
    case False{}:
      ea => eb => Empty.absurd({Bool.and(False{}, b) == True{} : Bool}, false_true(ea))

def add_zero(a: Nat) -> {a == Nat.add(a, 0n) : Nat}:
  match a:
    case 0n:
      {==}
    case 1n+p:
      Equal.cong(Nat, Nat, x => 1n+x, p, Nat.add(p, 0n), add_zero(p))

def add_assoc(a: Nat, -b: Nat, -c: Nat) -> {Nat.add(Nat.add(a, b), c) == Nat.add(a, Nat.add(b, c)) : Nat}:
  match a:
    case 0n:
      {==}
    case 1n+p:
      Equal.cong(Nat, Nat, x => 1n+x, Nat.add(Nat.add(p, b), c), Nat.add(p, Nat.add(b, c)), add_assoc(p, b, c))

def rev_rev.go(xs: List<&2, R.Item>, +acc: List<&2, R.Item>) -> {List.reverse.go(&2, R.Item, acc, xs) == List.reverse.go(&2, R.Item, List.reverse.go(&2, R.Item, xs, acc), Nil{}) : List<&2, R.Item>}:
  match xs:
    case Nil{}:
      {==}
    case Con{x, rest}:
      rev_rev.go(rest, Con{x, acc})

# reversing twice changes nothing
def rev_rev(xs: List<&2, R.Item>) -> {xs == List.reverse(&2, R.Item, List.reverse.go(&2, R.Item, xs, Nil{})) : List<&2, R.Item>}:
  rev_rev.go(xs, Nil{})

# a list reversed onto acc after another one reversed onto it
def rev_app(xs: List<&2, R.Item>, -ys: List<&2, R.Item>, -acc: List<&2, R.Item>) -> {List.reverse.go(&2, R.Item, ys, S.cat.rev(xs, acc)) == List.reverse.go(&2, R.Item, List.append(&2, R.Item, xs, ys), acc) : List<&2, R.Item>}:
  match xs:
    case Nil{}:
      {==}
    case Con{x, rest}:
      rev_app(rest, ys, Con{x, acc})

# Shard lists
# -----------

def put(ts: List<&2, KV.Trie<String>>, s: Nat, t: KV.Trie<String>) -> List<&2, KV.Trie<String>>:
  match ts s:
    case Con{x, rest} 0n:
      t <> rest
    case Nil{} 0n:
      [t]
    case Con{x, rest} 1n+p:
      x <> put(rest, p, t)
    case Nil{} 1n+p:
      KV.empty(String) <> put(Nil{}, p, t)

def at_put_same(s: Nat, ts: List<&2, KV.Trie<String>>, -t: KV.Trie<String>) -> {t == Laws.at(put(ts, s, t), s) : KV.Trie<String>}:
  match s ts:
    case 0n Con{x, rest}:
      {==}
    case 0n Nil{}:
      {==}
    case 1n+p Con{x, rest}:
      at_put_same(p, rest, t)
    case 1n+p Nil{}:
      at_put_same(p, Nil{}, t)

def at_put_other(s: Nat, i: Nat, ts: List<&2, KV.Trie<String>>, -t: KV.Trie<String>) -> {False{} == nat_eq(i, s) : Bool} -> {Laws.at(ts, i) == Laws.at(put(ts, s, t), i) : KV.Trie<String>}:
  match s i ts:
    case 0n 0n other:
      nb => Empty.absurd({Laws.at(other, 0n) == Laws.at(put(other, 0n, t), 0n) : KV.Trie<String>}, false_true(nb))
    case 0n 1n+j Con{x, rest}:
      nb => {==}
    case 0n 1n+j Nil{}:
      nb => {==}
    case 1n+p 0n Con{x, rest}:
      nb => {==}
    case 1n+p 0n Nil{}:
      nb => {==}
    case 1n+p 1n+j Con{x, rest}:
      nb => at_put_other(p, j, rest, t)(nb)
    case 1n+p 1n+j Nil{}:
      nb => at_put_other(p, j, Nil{}, t)(nb)

# The run, piece by piece
# -----------------------

def first_key(ks: List<&2, String>) -> String:
  match ks:
    case Nil{}:
      ""
    case Con{k, rest}:
      k

def one_key(ks: List<&2, String>) -> Bool:
  match ks:
    case Con{k, Nil{}}:
      True{}
    case _:
      False{}

# the key of a piece ("" for a command of no key)
def key_of(c: R.Cmd) -> String:
  match c:
    case R.Get{k}:
      k
    case R.Set{k, v}:
      k
    case R.SetNX{k, v}:
      k
    case R.GetSet{k, v}:
      k
    case R.IncrBy{k, by}:
      k
    case R.Append{k, v}:
      k
    case R.Strlen{k}:
      k
    case R.Del{ks}:
      first_key(ks)
    case R.Exists{ks}:
      first_key(ks)
    case _:
      ""

# a command on one key, named once
def keyed(c: R.Cmd) -> Bool:
  match c:
    case R.Get{k}:
      True{}
    case R.Set{k, v}:
      True{}
    case R.SetNX{k, v}:
      True{}
    case R.GetSet{k, v}:
      True{}
    case R.IncrBy{k, by}:
      True{}
    case R.Append{k, v}:
      True{}
    case R.Strlen{k}:
      True{}
    case R.Del{ks}:
      one_key(ks)
    case R.Exists{ks}:
      one_key(ks)
    case _:
      False{}

# a piece: a command on one key, named once, or on one digit's subtrie
def placed(c: R.Cmd) -> Bool:
  match c:
    case R.SizeAt{x}:
      True{}
    case R.KeysAt{p, x}:
      True{}
    case R.FlushAt{x}:
      True{}
    case other:
      keyed(other)

# the digit of the root a piece works under: its own, or its key's
def dig(c: R.Cmd) -> KV.Hex:
  match c:
    case R.SizeAt{x}:
      x
    case R.KeysAt{p, x}:
      x
    case R.FlushAt{x}:
      x
    case other:
      KV.hex(KV.hash(key_of(other)))

# the shard among n a piece goes to: the one that holds its digit
def home(+n: U32, c: R.Cmd) -> Nat:
  S.owner(n, dig(c))

# the hint a piece's part carries: its key's hash, or 0
def hint(c: R.Cmd) -> U32:
  match c:
    case R.SizeAt{x}:
      0
    case R.KeysAt{p, x}:
      0
    case R.FlushAt{x}:
      0
    case other:
      KV.hash(key_of(other))

# a command that goes whole to one shard
def whole(c: R.Cmd) -> Bool:
  match c:
    case R.Get{k}:
      True{}
    case R.Set{k, v}:
      True{}
    case R.SetNX{k, v}:
      True{}
    case R.GetSet{k, v}:
      True{}
    case R.IncrBy{k, by}:
      True{}
    case R.Append{k, v}:
      True{}
    case R.Strlen{k}:
      True{}
    case R.SizeAt{x}:
      True{}
    case R.KeysAt{p, x}:
      True{}
    case R.FlushAt{x}:
      True{}
    case _:
      False{}

# a piece, or a command of no key
def pc(c: R.Cmd) -> Bool:
  match c:
    case R.Ping{}:
      True{}
    case R.Echo{m}:
      True{}
    case R.Bad{r}:
      True{}
    case other:
      placed(other)

def pcs(cs: List<&2, R.Cmd>) -> Bool:
  match cs:
    case Nil{}:
      True{}
    case Con{c, rest}:
      Bool.and(pc(c), pcs(rest))

def placeds(cs: List<&2, R.Cmd>) -> Bool:
  match cs:
    case Nil{}:
      True{}
    case Con{c, rest}:
      Bool.and(placed(c), placeds(rest))

# c run on its home shard of ts (a command of no key leaves ts)
def step.if(b: Bool, +n: U32, +c: R.Cmd, ts: List<&2, KV.Trie<String>>) -> List<&2, KV.Trie<String>>:
  match b:
    case True{}:
      +t = ts
      put(t, home(n, c), R.db_of(R.exec(c, Laws.at(t, home(n, c)))))
    case False{}:
      ts

def step(+n: U32, +c: R.Cmd, ts: List<&2, KV.Trie<String>>) -> List<&2, KV.Trie<String>>:
  step.if(placed(c), n, c, ts)

# a run of pieces, newest first, from empty shards and an empty database
def seqT(+n: U32, cs: List<&2, R.Cmd>) -> List<&2, KV.Trie<String>>:
  match cs:
    case Nil{}:
      Nil{}
    case Con{+c, older}:
      step(n, c, seqT(n, older))

def seqD(cs: List<&2, R.Cmd>) -> KV.Trie<String>:
  match cs:
    case Nil{}:
      KV.empty(String)
    case Con{+c, older}:
      R.db_of(R.exec(c, seqD(older)))

# a command's pieces, in order: one for each key of DEL, EXISTS and MGET,
# one for each pair of MSET, one for each digit of DBSIZE, KEYS and
# FLUSHALL, the command itself for the others
def each_cmds(+e: S.Each, ks: List<&2, String>) -> List<&2, R.Cmd>:
  match ks:
    case Nil{}:
      Nil{}
    case Con{k, rest}:
      S.each.cmd(e, k) <> each_cmds(e, rest)

def set_cmds(kvs: List<&2, R.KVPair>) -> List<&2, R.Cmd>:
  match kvs:
    case Nil{}:
      Nil{}
    case Con{R.KP{k, v}, rest}:
      R.Set{k, v} <> set_cmds(rest)

def fan_cmds(+f: S.Fan, xs: List<&2, KV.Hex>) -> List<&2, R.Cmd>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{x, rest}:
      S.fan.cmd(f, x) <> fan_cmds(f, rest)

def pieces(c: R.Cmd) -> List<&2, R.Cmd>:
  match c:
    case R.Del{ks}:
      each_cmds(S.EDel{}, ks)
    case R.Exists{ks}:
      each_cmds(S.EExists{}, ks)
    case R.MGet{ks}:
      each_cmds(S.EGet{}, ks)
    case R.MSet{kvs}:
      set_cmds(kvs)
    case R.DbSize{}:
      fan_cmds(S.FSize{}, KV.digits())
    case R.Keys{p}:
      fan_cmds(S.FKeys{p}, KV.digits())
    case R.FlushAll{}:
      fan_cmds(S.FFlush{}, KV.digits())
    case other:
      [other]

# a batch run piece by piece after the run H
def unfold(cs: List<&2, R.Cmd>, H: List<&2, R.Cmd>) -> List<&2, R.Cmd>:
  match cs:
    case Nil{}:
      H
    case Con{c, rest}:
      unfold(rest, List.reverse.go(&2, R.Cmd, pieces(c), H))

# Locality
# --------
# A command on one key: its reply depends only on what its key reads.

def setnx_rep(b: Bool, -t: KV.Trie<String>, -u: KV.Trie<String>, -k: String, -v: String, -h: U32) -> {R.reply_of(R.setnx.if(t, k, v, h, b)) == R.reply_of(R.setnx.if(u, k, v, h, b)) : R.Reply}:
  match b:
    case True{}:
      {==}
    case False{}:
      {==}

def incr_fit_rep(ok: Bool, -t: KV.Trie<String>, -u: KV.Trie<String>, -k: String, -h: U32, -n: R.Int) -> {R.reply_of(R.incr.fit(t, k, h, n, ok)) == R.reply_of(R.incr.fit(u, k, h, n, ok)) : R.Reply}:
  match ok:
    case True{}:
      {==}
    case False{}:
      {==}

def incr_rep(x: Maybe<&2, R.Int>, -t: KV.Trie<String>, -u: KV.Trie<String>, -k: String, -h: U32, +by: R.Int) -> {R.reply_of(R.incr.got(t, k, h, by, x)) == R.reply_of(R.incr.got(u, k, h, by, x)) : R.Reply}:
  match x:
    case Some{+a}:
      incr_fit_rep(R.int_fits(R.int_add(a, by)), t, u, k, h, R.int_add(a, by))
    case None{}:
      {==}

# DEL of one key: its count, and the database without the key
def del_one(b: Bool, -d: KV.Trie<String>) -> {(R.r_int(Bool.pick(Nat, b, 1n, 0n)), d) == R.del_reply(R.del_keys.put(b, (0n, d))) : R.Reply & KV.Trie<String>}:
  match b:
    case True{}:
      {==}
    case False{}:
      {==}

def loc_reply_del(ks: List<&2, String>, +t: KV.Trie<String>, +u: KV.Trie<String>) -> {keyed(R.Del{ks}) == True{} : Bool} -> {KV.get(String, t, key_of(R.Del{ks})) == KV.get(String, u, key_of(R.Del{ks})) : Maybe<&2, String>} -> {R.reply_of(R.exec(R.Del{ks}, t)) == R.reply_of(R.exec(R.Del{ks}, u)) : R.Reply}:
  match ks:
    case Nil{}:
      kd => e => Empty.absurd({R.reply_of(R.exec(R.Del{Nil{}}, t)) == R.reply_of(R.exec(R.Del{Nil{}}, u)) : R.Reply}, false_true(kd))
    case Con{+k, Nil{}}:
      kd => e => %del_one(KV.has(String, t, k), KV.del(String, t, k)) : {R.reply_of(_) == R.reply_of(R.exec(R.Del{[k]}, u)) : R.Reply}
                 %del_one(KV.has(String, u, k), KV.del(String, u, k)) : {R.r_int(Bool.pick(Nat, KV.has(String, t, k), 1n, 0n)) == R.reply_of(_) : R.Reply}
                 Equal.cong(Maybe<&2, String>, R.Reply, m => R.r_int(Bool.pick(Nat, Maybe.is_some(&2, String, m), 1n, 0n)), KV.get(String, t, k), KV.get(String, u, k), e)
    case Con{k, Con{j, rest}}:
      kd => e => Empty.absurd({R.reply_of(R.exec(R.Del{Con{k, Con{j, rest}}}, t)) == R.reply_of(R.exec(R.Del{Con{k, Con{j, rest}}}, u)) : R.Reply}, false_true(kd))

def loc_reply_ex(ks: List<&2, String>, +t: KV.Trie<String>, +u: KV.Trie<String>) -> {keyed(R.Exists{ks}) == True{} : Bool} -> {KV.get(String, t, key_of(R.Exists{ks})) == KV.get(String, u, key_of(R.Exists{ks})) : Maybe<&2, String>} -> {R.reply_of(R.exec(R.Exists{ks}, t)) == R.reply_of(R.exec(R.Exists{ks}, u)) : R.Reply}:
  match ks:
    case Nil{}:
      kd => e => Empty.absurd({R.reply_of(R.exec(R.Exists{Nil{}}, t)) == R.reply_of(R.exec(R.Exists{Nil{}}, u)) : R.Reply}, false_true(kd))
    case Con{+k, Nil{}}:
      kd => e => Equal.cong(Maybe<&2, String>, R.Reply, m => R.r_int(Nat.add(Bool.pick(Nat, Maybe.is_some(&2, String, m), 1n, 0n), 0n)), KV.get(String, t, k), KV.get(String, u, k), e)
    case Con{k, Con{j, rest}}:
      kd => e => Empty.absurd({R.reply_of(R.exec(R.Exists{Con{k, Con{j, rest}}}, t)) == R.reply_of(R.exec(R.Exists{Con{k, Con{j, rest}}}, u)) : R.Reply}, false_true(kd))

def loc_reply(c: R.Cmd, +t: KV.Trie<String>, +u: KV.Trie<String>) -> {keyed(c) == True{} : Bool} -> {KV.get(String, t, key_of(c)) == KV.get(String, u, key_of(c)) : Maybe<&2, String>} -> {R.reply_of(R.exec(c, t)) == R.reply_of(R.exec(c, u)) : R.Reply}:
  match c:
    case R.Get{+k}:
      kd => e => Equal.cong(Maybe<&2, String>, R.Reply, m => R.r_get(m), KV.get(String, t, k), KV.get(String, u, k), e)
    case R.Set{+k, +v}:
      kd => e => {==}
    case R.SetNX{+k, +v}:
      kd => e => %e : {R.reply_of(R.setnx.if(t, k, v, KV.hash(k), Maybe.is_some(&2, String, KV.get(String, t, k)))) == R.reply_of(R.setnx.if(u, k, v, KV.hash(k), Maybe.is_some(&2, String, _))) : R.Reply}
                  setnx_rep(Maybe.is_some(&2, String, KV.get(String, t, k)), t, u, k, v, KV.hash(k))
    case R.GetSet{+k, +v}:
      kd => e => Equal.cong(Maybe<&2, String>, R.Reply, m => R.r_get(m), KV.get(String, t, k), KV.get(String, u, k), e)
    case R.IncrBy{+k, +by}:
      kd => e => %e : {R.reply_of(R.incr.got(t, k, KV.hash(k), by, R.incr.old(KV.get(String, t, k)))) == R.reply_of(R.incr.got(u, k, KV.hash(k), by, R.incr.old(_))) : R.Reply}
                  incr_rep(R.incr.old(KV.get(String, t, k)), t, u, k, KV.hash(k), by)
    case R.Append{+k, +v}:
      kd => e => %e : {R.r_int(String.length(R.append_to(KV.get(String, t, k), v))) == R.r_int(String.length(R.append_to(_, v))) : R.Reply}
                  {==}
    case R.Strlen{+k}:
      kd => e => Equal.cong(Maybe<&2, String>, R.Reply, m => R.r_int(R.strlen_of(m)), KV.get(String, t, k), KV.get(String, u, k), e)
    case R.Del{ks}:
      loc_reply_del(ks, t, u)
    case R.Exists{ks}:
      loc_reply_ex(ks, t, u)
    case R.Ping{}:
      kd => e => Empty.absurd({R.reply_of(R.exec(R.Ping{}, t)) == R.reply_of(R.exec(R.Ping{}, u)) : R.Reply}, false_true(kd))
    case R.Echo{m}:
      kd => e => Empty.absurd({R.reply_of(R.exec(R.Echo{m}, t)) == R.reply_of(R.exec(R.Echo{m}, u)) : R.Reply}, false_true(kd))
    case R.MGet{ks}:
      kd => e => Empty.absurd({R.reply_of(R.exec(R.MGet{ks}, t)) == R.reply_of(R.exec(R.MGet{ks}, u)) : R.Reply}, false_true(kd))
    case R.MSet{ps}:
      kd => e => Empty.absurd({R.reply_of(R.exec(R.MSet{ps}, t)) == R.reply_of(R.exec(R.MSet{ps}, u)) : R.Reply}, false_true(kd))
    case R.DbSize{}:
      kd => e => Empty.absurd({R.reply_of(R.exec(R.DbSize{}, t)) == R.reply_of(R.exec(R.DbSize{}, u)) : R.Reply}, false_true(kd))
    case R.FlushAll{}:
      kd => e => Empty.absurd({R.reply_of(R.exec(R.FlushAll{}, t)) == R.reply_of(R.exec(R.FlushAll{}, u)) : R.Reply}, false_true(kd))
    case R.Keys{p}:
      kd => e => Empty.absurd({R.reply_of(R.exec(R.Keys{p}, t)) == R.reply_of(R.exec(R.Keys{p}, u)) : R.Reply}, false_true(kd))
    case R.Bad{r}:
      kd => e => Empty.absurd({R.reply_of(R.exec(R.Bad{r}, t)) == R.reply_of(R.exec(R.Bad{r}, u)) : R.Reply}, false_true(kd))
    case R.SizeAt{x}:
      kd => e => Empty.absurd({R.reply_of(R.exec(R.SizeAt{x}, t)) == R.reply_of(R.exec(R.SizeAt{x}, u)) : R.Reply}, false_true(kd))
    case R.KeysAt{p, x}:
      kd => e => Empty.absurd({R.reply_of(R.exec(R.KeysAt{p, x}, t)) == R.reply_of(R.exec(R.KeysAt{p, x}, u)) : R.Reply}, false_true(kd))
    case R.FlushAt{x}:
      kd => e => Empty.absurd({R.reply_of(R.exec(R.FlushAt{x}, t)) == R.reply_of(R.exec(R.FlushAt{x}, u)) : R.Reply}, false_true(kd))

# Pieces and subtries
# -------------------
# A piece changes the root's subtrie under its digit alone (child_frame);
# its reply, and that subtrie after it, depend only on that subtrie
# before it (reply_loc, child_loc). A write to a key is a write from the
# root under the key's digit (mod_other, mod_same).

def setnx_frame_c(b: Bool, +d: KV.Trie<String>, +k: String, -v: String, +y: KV.Hex) -> {False{} == KV.hex_eq(y, KV.hex(KV.hash(k))) : Bool} -> {KV.child(String, d, y) == KV.child(String, R.db_of(R.setnx.if(d, k, v, KV.hash(k), b)), y) : KV.Trie<String>}:
  match b:
    case True{}:
      e => {==}
    case False{}:
      e => mod_other(String, d, KV.hex(KV.hash(k)), KV.hash(k), KV.OSet{k, v}, y)(e)

def incr_fit_frame_c(ok: Bool, +d: KV.Trie<String>, +k: String, -n: R.Int, +y: KV.Hex) -> {False{} == KV.hex_eq(y, KV.hex(KV.hash(k))) : Bool} -> {KV.child(String, d, y) == KV.child(String, R.db_of(R.incr.fit(d, k, KV.hash(k), n, ok)), y) : KV.Trie<String>}:
  match ok:
    case True{}:
      e => mod_other(String, d, KV.hex(KV.hash(k)), KV.hash(k), KV.OSet{k, R.int_show(n)}, y)(e)
    case False{}:
      e => {==}

def incr_frame_c(m: Maybe<&2, R.Int>, +d: KV.Trie<String>, +k: String, +by: R.Int, +y: KV.Hex) -> {False{} == KV.hex_eq(y, KV.hex(KV.hash(k))) : Bool} -> {KV.child(String, d, y) == KV.child(String, R.db_of(R.incr.got(d, k, KV.hash(k), by, m)), y) : KV.Trie<String>}:
  match m:
    case None{}:
      e => {==}
    case Some{+x}:
      e => incr_fit_frame_c(R.int_fits(R.int_add(x, by)), d, k, R.int_add(x, by), y)(e)

def del_frame_c(ks: List<&2, String>, +d: KV.Trie<String>, +y: KV.Hex) -> {placed(R.Del{ks}) == True{} : Bool} -> {False{} == KV.hex_eq(y, dig(R.Del{ks})) : Bool} -> {KV.child(String, d, y) == KV.child(String, R.db_of(R.exec(R.Del{ks}, d)), y) : KV.Trie<String>}:
  match ks:
    case Nil{}:
      pd => e => Empty.absurd({KV.child(String, d, y) == KV.child(String, R.db_of(R.exec(R.Del{Nil{}}, d)), y) : KV.Trie<String>}, false_true(pd))
    case Con{+k, Nil{}}:
      pd => e => %del_one(KV.has(String, d, k), KV.del(String, d, k)) : {KV.child(String, d, y) == KV.child(String, R.db_of(_), y) : KV.Trie<String>}
                 mod_other(String, d, KV.hex(KV.hash(k)), KV.hash(k), KV.ODel{k}, y)(e)
    case Con{k, Con{j, rest}}:
      pd => e => Empty.absurd({KV.child(String, d, y) == KV.child(String, R.db_of(R.exec(R.Del{Con{k, Con{j, rest}}}, d)), y) : KV.Trie<String>}, false_true(pd))

# a piece leaves the root's subtries under the other digits
def child_frame(c: R.Cmd, +d: KV.Trie<String>, +y: KV.Hex) -> {placed(c) == True{} : Bool} -> {False{} == KV.hex_eq(y, dig(c)) : Bool} -> {KV.child(String, d, y) == KV.child(String, R.db_of(R.exec(c, d)), y) : KV.Trie<String>}:
  match c:
    case R.Ping{}:
      pd => e => Empty.absurd({KV.child(String, d, y) == KV.child(String, R.db_of(R.exec(R.Ping{}, d)), y) : KV.Trie<String>}, false_true(pd))
    case R.Echo{m}:
      pd => e => Empty.absurd({KV.child(String, d, y) == KV.child(String, R.db_of(R.exec(R.Echo{m}, d)), y) : KV.Trie<String>}, false_true(pd))
    case R.Get{k}:
      pd => e => {==}
    case R.Set{+k, +v}:
      pd => e => mod_other(String, d, KV.hex(KV.hash(k)), KV.hash(k), KV.OSet{k, v}, y)(e)
    case R.SetNX{+k, +v}:
      pd => e => setnx_frame_c(Maybe.is_some(&2, String, KV.get(String, d, k)), d, k, v, y)(e)
    case R.GetSet{+k, +v}:
      pd => e => mod_other(String, d, KV.hex(KV.hash(k)), KV.hash(k), KV.OSet{k, v}, y)(e)
    case R.Del{ks}:
      del_frame_c(ks, d, y)
    case R.Exists{ks}:
      pd => e => {==}
    case R.IncrBy{+k, +by}:
      pd => e => incr_frame_c(R.incr.old(KV.get(String, d, k)), d, k, by, y)(e)
    case R.Append{+k, +v}:
      pd => e => mod_other(String, d, KV.hex(KV.hash(k)), KV.hash(k), KV.OSet{k, R.append_to(KV.get(String, d, k), v)}, y)(e)
    case R.Strlen{k}:
      pd => e => {==}
    case R.MGet{ks}:
      pd => e => Empty.absurd({KV.child(String, d, y) == KV.child(String, R.db_of(R.exec(R.MGet{ks}, d)), y) : KV.Trie<String>}, false_true(pd))
    case R.MSet{ps}:
      pd => e => Empty.absurd({KV.child(String, d, y) == KV.child(String, R.db_of(R.exec(R.MSet{ps}, d)), y) : KV.Trie<String>}, false_true(pd))
    case R.DbSize{}:
      pd => e => Empty.absurd({KV.child(String, d, y) == KV.child(String, R.db_of(R.exec(R.DbSize{}, d)), y) : KV.Trie<String>}, false_true(pd))
    case R.FlushAll{}:
      pd => e => Empty.absurd({KV.child(String, d, y) == KV.child(String, R.db_of(R.exec(R.FlushAll{}, d)), y) : KV.Trie<String>}, false_true(pd))
    case R.Keys{p}:
      pd => e => Empty.absurd({KV.child(String, d, y) == KV.child(String, R.db_of(R.exec(R.Keys{p}, d)), y) : KV.Trie<String>}, false_true(pd))
    case R.Bad{r}:
      pd => e => Empty.absurd({KV.child(String, d, y) == KV.child(String, R.db_of(R.exec(R.Bad{r}, d)), y) : KV.Trie<String>}, false_true(pd))
    case R.SizeAt{x}:
      pd => e => {==}
    case R.KeysAt{p, x}:
      pd => e => {==}
    case R.FlushAt{+x}:
      pd => e => child_with_other(String, d, x, KV.empty(String), y)(e)

def setnx_loc_c(b: Bool, +t: KV.Trie<String>, +u: KV.Trie<String>, +k: String, -v: String) -> {KV.child(String, t, KV.hex(KV.hash(k))) == KV.child(String, u, KV.hex(KV.hash(k))) : KV.Trie<String>} -> {KV.child(String, R.db_of(R.setnx.if(t, k, v, KV.hash(k), b)), KV.hex(KV.hash(k))) == KV.child(String, R.db_of(R.setnx.if(u, k, v, KV.hash(k), b)), KV.hex(KV.hash(k))) : KV.Trie<String>}:
  match b:
    case True{}:
      e => e
    case False{}:
      e => mod_same(String, t, u, KV.hex(KV.hash(k)), KV.hash(k), KV.OSet{k, v})(e)

def incr_fit_loc_c(ok: Bool, +t: KV.Trie<String>, +u: KV.Trie<String>, +k: String, -n: R.Int) -> {KV.child(String, t, KV.hex(KV.hash(k))) == KV.child(String, u, KV.hex(KV.hash(k))) : KV.Trie<String>} -> {KV.child(String, R.db_of(R.incr.fit(t, k, KV.hash(k), n, ok)), KV.hex(KV.hash(k))) == KV.child(String, R.db_of(R.incr.fit(u, k, KV.hash(k), n, ok)), KV.hex(KV.hash(k))) : KV.Trie<String>}:
  match ok:
    case True{}:
      e => mod_same(String, t, u, KV.hex(KV.hash(k)), KV.hash(k), KV.OSet{k, R.int_show(n)})(e)
    case False{}:
      e => e

def incr_loc_c(m: Maybe<&2, R.Int>, +t: KV.Trie<String>, +u: KV.Trie<String>, +k: String, +by: R.Int) -> {KV.child(String, t, KV.hex(KV.hash(k))) == KV.child(String, u, KV.hex(KV.hash(k))) : KV.Trie<String>} -> {KV.child(String, R.db_of(R.incr.got(t, k, KV.hash(k), by, m)), KV.hex(KV.hash(k))) == KV.child(String, R.db_of(R.incr.got(u, k, KV.hash(k), by, m)), KV.hex(KV.hash(k))) : KV.Trie<String>}:
  match m:
    case None{}:
      e => e
    case Some{+a}:
      e => incr_fit_loc_c(R.int_fits(R.int_add(a, by)), t, u, k, R.int_add(a, by))(e)

def del_loc_c(ks: List<&2, String>, +t: KV.Trie<String>, +u: KV.Trie<String>) -> {placed(R.Del{ks}) == True{} : Bool} -> {KV.child(String, t, dig(R.Del{ks})) == KV.child(String, u, dig(R.Del{ks})) : KV.Trie<String>} -> {KV.child(String, R.db_of(R.exec(R.Del{ks}, t)), dig(R.Del{ks})) == KV.child(String, R.db_of(R.exec(R.Del{ks}, u)), dig(R.Del{ks})) : KV.Trie<String>}:
  match ks:
    case Nil{}:
      pd => e => Empty.absurd({KV.child(String, R.db_of(R.exec(R.Del{Nil{}}, t)), dig(R.Del{Nil{}})) == KV.child(String, R.db_of(R.exec(R.Del{Nil{}}, u)), dig(R.Del{Nil{}})) : KV.Trie<String>}, false_true(pd))
    case Con{+k, Nil{}}:
      pd => e => %del_one(KV.has(String, t, k), KV.del(String, t, k)) : {KV.child(String, R.db_of(_), KV.hex(KV.hash(k))) == KV.child(String, R.db_of(R.exec(R.Del{[k]}, u)), KV.hex(KV.hash(k))) : KV.Trie<String>}
                 %del_one(KV.has(String, u, k), KV.del(String, u, k)) : {KV.child(String, KV.del(String, t, k), KV.hex(KV.hash(k))) == KV.child(String, R.db_of(_), KV.hex(KV.hash(k))) : KV.Trie<String>}
                 mod_same(String, t, u, KV.hex(KV.hash(k)), KV.hash(k), KV.ODel{k})(e)
    case Con{k, Con{j, rest}}:
      pd => e => Empty.absurd({KV.child(String, R.db_of(R.exec(R.Del{Con{k, Con{j, rest}}}, t)), dig(R.Del{Con{k, Con{j, rest}}})) == KV.child(String, R.db_of(R.exec(R.Del{Con{k, Con{j, rest}}}, u)), dig(R.Del{Con{k, Con{j, rest}}})) : KV.Trie<String>}, false_true(pd))

# the subtrie under a piece's digit after it depends on that subtrie
# before it alone
def child_loc(c: R.Cmd, +t: KV.Trie<String>, +u: KV.Trie<String>) -> {placed(c) == True{} : Bool} -> {KV.child(String, t, dig(c)) == KV.child(String, u, dig(c)) : KV.Trie<String>} -> {KV.child(String, R.db_of(R.exec(c, t)), dig(c)) == KV.child(String, R.db_of(R.exec(c, u)), dig(c)) : KV.Trie<String>}:
  match c:
    case R.Ping{}:
      pd => e => Empty.absurd({KV.child(String, R.db_of(R.exec(R.Ping{}, t)), dig(R.Ping{})) == KV.child(String, R.db_of(R.exec(R.Ping{}, u)), dig(R.Ping{})) : KV.Trie<String>}, false_true(pd))
    case R.Echo{m}:
      pd => e => Empty.absurd({KV.child(String, R.db_of(R.exec(R.Echo{m}, t)), dig(R.Echo{m})) == KV.child(String, R.db_of(R.exec(R.Echo{m}, u)), dig(R.Echo{m})) : KV.Trie<String>}, false_true(pd))
    case R.Get{k}:
      pd => e => e
    case R.Set{+k, +v}:
      pd => e => mod_same(String, t, u, KV.hex(KV.hash(k)), KV.hash(k), KV.OSet{k, v})(e)
    case R.SetNX{+k, +v}:
      pd => +e => %get_child(String, t, u, k)(e) : {KV.child(String, R.db_of(R.setnx.if(t, k, v, KV.hash(k), Maybe.is_some(&2, String, KV.get(String, t, k)))), KV.hex(KV.hash(k))) == KV.child(String, R.db_of(R.setnx.if(u, k, v, KV.hash(k), Maybe.is_some(&2, String, _))), KV.hex(KV.hash(k))) : KV.Trie<String>}
                  setnx_loc_c(Maybe.is_some(&2, String, KV.get(String, t, k)), t, u, k, v)(e)
    case R.GetSet{+k, +v}:
      pd => e => mod_same(String, t, u, KV.hex(KV.hash(k)), KV.hash(k), KV.OSet{k, v})(e)
    case R.Del{ks}:
      del_loc_c(ks, t, u)
    case R.Exists{ks}:
      pd => e => e
    case R.IncrBy{+k, +by}:
      pd => +e => %get_child(String, t, u, k)(e) : {KV.child(String, R.db_of(R.incr.got(t, k, KV.hash(k), by, R.incr.old(KV.get(String, t, k)))), KV.hex(KV.hash(k))) == KV.child(String, R.db_of(R.incr.got(u, k, KV.hash(k), by, R.incr.old(_))), KV.hex(KV.hash(k))) : KV.Trie<String>}
                  incr_loc_c(R.incr.old(KV.get(String, t, k)), t, u, k, by)(e)
    case R.Append{+k, +v}:
      pd => +e => %get_child(String, t, u, k)(e) : {KV.child(String, KV.set.at(String, t, k, R.append_to(KV.get(String, t, k), v), KV.hash(k)), KV.hex(KV.hash(k))) == KV.child(String, KV.set.at(String, u, k, R.append_to(_, v), KV.hash(k)), KV.hex(KV.hash(k))) : KV.Trie<String>}
                  mod_same(String, t, u, KV.hex(KV.hash(k)), KV.hash(k), KV.OSet{k, R.append_to(KV.get(String, t, k), v)})(e)
    case R.Strlen{k}:
      pd => e => e
    case R.MGet{ks}:
      pd => e => Empty.absurd({KV.child(String, R.db_of(R.exec(R.MGet{ks}, t)), dig(R.MGet{ks})) == KV.child(String, R.db_of(R.exec(R.MGet{ks}, u)), dig(R.MGet{ks})) : KV.Trie<String>}, false_true(pd))
    case R.MSet{ps}:
      pd => e => Empty.absurd({KV.child(String, R.db_of(R.exec(R.MSet{ps}, t)), dig(R.MSet{ps})) == KV.child(String, R.db_of(R.exec(R.MSet{ps}, u)), dig(R.MSet{ps})) : KV.Trie<String>}, false_true(pd))
    case R.DbSize{}:
      pd => e => Empty.absurd({KV.child(String, R.db_of(R.exec(R.DbSize{}, t)), dig(R.DbSize{})) == KV.child(String, R.db_of(R.exec(R.DbSize{}, u)), dig(R.DbSize{})) : KV.Trie<String>}, false_true(pd))
    case R.FlushAll{}:
      pd => e => Empty.absurd({KV.child(String, R.db_of(R.exec(R.FlushAll{}, t)), dig(R.FlushAll{})) == KV.child(String, R.db_of(R.exec(R.FlushAll{}, u)), dig(R.FlushAll{})) : KV.Trie<String>}, false_true(pd))
    case R.Keys{p}:
      pd => e => Empty.absurd({KV.child(String, R.db_of(R.exec(R.Keys{p}, t)), dig(R.Keys{p})) == KV.child(String, R.db_of(R.exec(R.Keys{p}, u)), dig(R.Keys{p})) : KV.Trie<String>}, false_true(pd))
    case R.Bad{r}:
      pd => e => Empty.absurd({KV.child(String, R.db_of(R.exec(R.Bad{r}, t)), dig(R.Bad{r})) == KV.child(String, R.db_of(R.exec(R.Bad{r}, u)), dig(R.Bad{r})) : KV.Trie<String>}, false_true(pd))
    case R.SizeAt{x}:
      pd => e => e
    case R.KeysAt{p, x}:
      pd => e => e
    case R.FlushAt{+x}:
      pd => e => %child_with_same(String, t, x, KV.empty(String)) : {_ == KV.child(String, KV.with_child(String, u, x, KV.empty(String)), x) : KV.Trie<String>}
                 child_with_same(String, u, x, KV.empty(String))

# a piece's reply depends on the subtrie under its digit alone
def reply_loc(c: R.Cmd, +t: KV.Trie<String>, +u: KV.Trie<String>) -> {placed(c) == True{} : Bool} -> {KV.child(String, t, dig(c)) == KV.child(String, u, dig(c)) : KV.Trie<String>} -> {R.reply_of(R.exec(c, t)) == R.reply_of(R.exec(c, u)) : R.Reply}:
  match c:
    case R.Ping{}:
      pd => e => Empty.absurd({R.reply_of(R.exec(R.Ping{}, t)) == R.reply_of(R.exec(R.Ping{}, u)) : R.Reply}, false_true(pd))
    case R.Echo{m}:
      pd => e => Empty.absurd({R.reply_of(R.exec(R.Echo{m}, t)) == R.reply_of(R.exec(R.Echo{m}, u)) : R.Reply}, false_true(pd))
    case R.Get{+k}:
      pd => e => loc_reply(R.Get{k}, t, u)(pd)(get_child(String, t, u, key_of(R.Get{k}))(e))
    case R.Set{+k, +v}:
      pd => e => loc_reply(R.Set{k, v}, t, u)(pd)(get_child(String, t, u, key_of(R.Set{k, v}))(e))
    case R.SetNX{+k, +v}:
      pd => e => loc_reply(R.SetNX{k, v}, t, u)(pd)(get_child(String, t, u, key_of(R.SetNX{k, v}))(e))
    case R.GetSet{+k, +v}:
      pd => e => loc_reply(R.GetSet{k, v}, t, u)(pd)(get_child(String, t, u, key_of(R.GetSet{k, v}))(e))
    case R.Del{+ks}:
      pd => e => loc_reply(R.Del{ks}, t, u)(pd)(get_child(String, t, u, key_of(R.Del{ks}))(e))
    case R.Exists{+ks}:
      pd => e => loc_reply(R.Exists{ks}, t, u)(pd)(get_child(String, t, u, key_of(R.Exists{ks}))(e))
    case R.IncrBy{+k, +by}:
      pd => e => loc_reply(R.IncrBy{k, by}, t, u)(pd)(get_child(String, t, u, key_of(R.IncrBy{k, by}))(e))
    case R.Append{+k, +v}:
      pd => e => loc_reply(R.Append{k, v}, t, u)(pd)(get_child(String, t, u, key_of(R.Append{k, v}))(e))
    case R.Strlen{+k}:
      pd => e => loc_reply(R.Strlen{k}, t, u)(pd)(get_child(String, t, u, key_of(R.Strlen{k}))(e))
    case R.MGet{ks}:
      pd => e => Empty.absurd({R.reply_of(R.exec(R.MGet{ks}, t)) == R.reply_of(R.exec(R.MGet{ks}, u)) : R.Reply}, false_true(pd))
    case R.MSet{ps}:
      pd => e => Empty.absurd({R.reply_of(R.exec(R.MSet{ps}, t)) == R.reply_of(R.exec(R.MSet{ps}, u)) : R.Reply}, false_true(pd))
    case R.DbSize{}:
      pd => e => Empty.absurd({R.reply_of(R.exec(R.DbSize{}, t)) == R.reply_of(R.exec(R.DbSize{}, u)) : R.Reply}, false_true(pd))
    case R.FlushAll{}:
      pd => e => Empty.absurd({R.reply_of(R.exec(R.FlushAll{}, t)) == R.reply_of(R.exec(R.FlushAll{}, u)) : R.Reply}, false_true(pd))
    case R.Keys{p}:
      pd => e => Empty.absurd({R.reply_of(R.exec(R.Keys{p}, t)) == R.reply_of(R.exec(R.Keys{p}, u)) : R.Reply}, false_true(pd))
    case R.Bad{r}:
      pd => e => Empty.absurd({R.reply_of(R.exec(R.Bad{r}, t)) == R.reply_of(R.exec(R.Bad{r}, u)) : R.Reply}, false_true(pd))
    case R.SizeAt{+x}:
      pd => e => %size_at_child(String, t, x) : {R.r_int(_) == R.r_int(KV.size.at(String, u, x)) : R.Reply}
                 %size_at_child(String, u, x) : {R.r_int(KV.tsize(String, KV.child(String, t, x))) == R.r_int(_) : R.Reply}
                 Equal.cong(KV.Trie<String>, R.Reply, z => R.r_int(KV.tsize(String, z)), KV.child(String, t, x), KV.child(String, u, x), e)
    case R.KeysAt{+p, +x}:
      pd => e => %keys_at_child(String, t, x, Nil{}) : {R.RArray{R.glob_filter(p, _)} == R.RArray{R.glob_filter(p, KV.keys.at(String, u, x, Nil{}))} : R.Reply}
                 %keys_at_child(String, u, x, Nil{}) : {R.RArray{R.glob_filter(p, KV.tkeys(String, KV.child(String, t, x), Nil{}))} == R.RArray{R.glob_filter(p, _)} : R.Reply}
                 Equal.cong(KV.Trie<String>, R.Reply, z => R.RArray{R.glob_filter(p, KV.tkeys(String, z, Nil{}))}, KV.child(String, t, x), KV.child(String, u, x), e)
    case R.FlushAt{x}:
      pd => e => {==}

# The shards hold the database
# ----------------------------
# After a run of pieces, the shard of each digit holds under it the
# subtrie the database holds there. A step splits on whether the digit's
# shard is the piece's home and whether the digit is the piece's; ih is
# the claim for the run before the step, at the one digit the case needs.

def nat_self(+x: Nat) -> {True{} == nat_eq(x, x) : Bool}:
  refl_self(Nat, x, nat_eq(x, x))(nat_refl(x, x))

# digits held by different shards are different
def hex_ne(+n: U32, +y: KV.Hex, +x: KV.Hex, +nb: {False{} == nat_eq(S.owner(n, y), S.owner(n, x)) : Bool}, b: Bool) -> {b == KV.hex_eq(y, x) : Bool} -> {False{} == KV.hex_eq(y, x) : Bool}:
  match b:
    case True{}:
      eb => Empty.absurd({False{} == KV.hex_eq(y, x) : Bool}, false_true(
        Equal.trans(Bool, False{}, nat_eq(S.owner(n, y), S.owner(n, x)), True{}, nb,
          Equal.trans(Bool, nat_eq(S.owner(n, y), S.owner(n, x)), nat_eq(S.owner(n, x), S.owner(n, x)), True{},
            Equal.cong(KV.Hex, Bool, z => nat_eq(S.owner(n, z), S.owner(n, x)), y, x, hex_eq_sound(y, x)(Equal.sym(Bool, True{}, KV.hex_eq(y, x), eb))),
            Equal.sym(Bool, True{}, nat_eq(S.owner(n, x), S.owner(n, x)), nat_self(S.owner(n, x)))))))
    case False{}:
      eb => eb

# the digit's shard is the piece's home: the digit is the piece's
# (child_loc), or another, which the piece leaves (child_frame)
def struct_near(+n: U32, +c: R.Cmd, +older: List<&2, R.Cmd>, +y: KV.Hex, +pd: {placed(c) == True{} : Bool}, ih: @j: KV.Hex -> {KV.child(String, Laws.at(seqT(n, older), S.owner(n, j)), j) == KV.child(String, seqD(older), j) : KV.Trie<String>}, +es: {S.owner(n, y) == home(n, c) : Nat}, b: Bool)
  -> {b == KV.hex_eq(y, dig(c)) : Bool}
  -> {KV.child(String, R.db_of(R.exec(c, Laws.at(seqT(n, older), home(n, c)))), y) == KV.child(String, R.db_of(R.exec(c, seqD(older))), y) : KV.Trie<String>}:
  match b:
    case True{}:
      eb => %Equal.sym(KV.Hex, y, dig(c), hex_eq_sound(y, dig(c))(Equal.sym(Bool, True{}, KV.hex_eq(y, dig(c)), eb))) : {KV.child(String, R.db_of(R.exec(c, Laws.at(seqT(n, older), home(n, c)))), _) == KV.child(String, R.db_of(R.exec(c, seqD(older))), _) : KV.Trie<String>}
            child_loc(c, Laws.at(seqT(n, older), home(n, c)), seqD(older))(pd)(ih(dig(c)))
    case False{}:
      +eb => %child_frame(c, Laws.at(seqT(n, older), home(n, c)), y)(pd)(eb) : {_ == KV.child(String, R.db_of(R.exec(c, seqD(older))), y) : KV.Trie<String>}
             %child_frame(c, seqD(older), y)(pd)(eb) : {KV.child(String, Laws.at(seqT(n, older), home(n, c)), y) == _ : KV.Trie<String>}
             %es : {KV.child(String, Laws.at(seqT(n, older), _), y) == KV.child(String, seqD(older), y) : KV.Trie<String>}
             ih(y)

# the digit's shard is the piece's home
def struct_home(+n: U32, +c: R.Cmd, +older: List<&2, R.Cmd>, +y: KV.Hex, +pd: {placed(c) == True{} : Bool}, ih: @j: KV.Hex -> {KV.child(String, Laws.at(seqT(n, older), S.owner(n, j)), j) == KV.child(String, seqD(older), j) : KV.Trie<String>}, +es: {S.owner(n, y) == home(n, c) : Nat})
  -> {KV.child(String, Laws.at(put(seqT(n, older), home(n, c), R.db_of(R.exec(c, Laws.at(seqT(n, older), home(n, c))))), S.owner(n, y)), y) == KV.child(String, R.db_of(R.exec(c, seqD(older))), y) : KV.Trie<String>}:
  %Equal.sym(Nat, S.owner(n, y), home(n, c), es) : {KV.child(String, Laws.at(put(seqT(n, older), home(n, c), R.db_of(R.exec(c, Laws.at(seqT(n, older), home(n, c))))), _), y) == KV.child(String, R.db_of(R.exec(c, seqD(older))), y) : KV.Trie<String>}
  %at_put_same(home(n, c), seqT(n, older), R.db_of(R.exec(c, Laws.at(seqT(n, older), home(n, c))))) : {KV.child(String, _, y) == KV.child(String, R.db_of(R.exec(c, seqD(older))), y) : KV.Trie<String>}
  struct_near(n, c, older, y, pd, ih, es, KV.hex_eq(y, dig(c)))({==})

# a piece's step: the digit's shard is its home, or another, which the
# step leaves
def struct_placed(+n: U32, +c: R.Cmd, +older: List<&2, R.Cmd>, +y: KV.Hex, +pd: {placed(c) == True{} : Bool}, ih: @j: KV.Hex -> {KV.child(String, Laws.at(seqT(n, older), S.owner(n, j)), j) == KV.child(String, seqD(older), j) : KV.Trie<String>}, b: Bool)
  -> {b == nat_eq(S.owner(n, y), home(n, c)) : Bool}
  -> Reflect(Nat, S.owner(n, y), home(n, c), b)
  -> {KV.child(String, Laws.at(put(seqT(n, older), home(n, c), R.db_of(R.exec(c, Laws.at(seqT(n, older), home(n, c))))), S.owner(n, y)), y) == KV.child(String, R.db_of(R.exec(c, seqD(older))), y) : KV.Trie<String>}:
  match b:
    case True{}:
      eb => es => struct_home(n, c, older, y, pd, ih, es)
    case False{}:
      +nb => ne => %at_put_other(home(n, c), S.owner(n, y), seqT(n, older), R.db_of(R.exec(c, Laws.at(seqT(n, older), home(n, c)))))(nb) : {KV.child(String, _, y) == KV.child(String, R.db_of(R.exec(c, seqD(older))), y) : KV.Trie<String>}
                   %child_frame(c, seqD(older), y)(pd)(hex_ne(n, y, dig(c), nb, KV.hex_eq(y, dig(c)))({==})) : {KV.child(String, Laws.at(seqT(n, older), S.owner(n, y)), y) == _ : KV.Trie<String>}
                   ih(y)

# a command that is no piece leaves the database
def nokey_db(c: R.Cmd, +d: KV.Trie<String>) -> {pc(c) == True{} : Bool} -> {False{} == placed(c) : Bool} -> {d == R.db_of(R.exec(c, d)) : KV.Trie<String>}:
  match c:
    case R.Ping{}:
      e1 => e2 => {==}
    case R.Echo{m}:
      e1 => e2 => {==}
    case R.Get{k}:
      e1 => e2 => Empty.absurd({d == R.db_of(R.exec(R.Get{k}, d)) : KV.Trie<String>}, false_true(Equal.trans(Bool, False{}, placed(R.Get{k}), True{}, e2, e1)))
    case R.Set{k, v}:
      e1 => e2 => Empty.absurd({d == R.db_of(R.exec(R.Set{k, v}, d)) : KV.Trie<String>}, false_true(Equal.trans(Bool, False{}, placed(R.Set{k, v}), True{}, e2, e1)))
    case R.SetNX{k, v}:
      e1 => e2 => Empty.absurd({d == R.db_of(R.exec(R.SetNX{k, v}, d)) : KV.Trie<String>}, false_true(Equal.trans(Bool, False{}, placed(R.SetNX{k, v}), True{}, e2, e1)))
    case R.GetSet{k, v}:
      e1 => e2 => Empty.absurd({d == R.db_of(R.exec(R.GetSet{k, v}, d)) : KV.Trie<String>}, false_true(Equal.trans(Bool, False{}, placed(R.GetSet{k, v}), True{}, e2, e1)))
    case R.Del{ks}:
      e1 => e2 => Empty.absurd({d == R.db_of(R.exec(R.Del{ks}, d)) : KV.Trie<String>}, false_true(Equal.trans(Bool, False{}, placed(R.Del{ks}), True{}, e2, e1)))
    case R.Exists{ks}:
      e1 => e2 => Empty.absurd({d == R.db_of(R.exec(R.Exists{ks}, d)) : KV.Trie<String>}, false_true(Equal.trans(Bool, False{}, placed(R.Exists{ks}), True{}, e2, e1)))
    case R.IncrBy{k, by}:
      e1 => e2 => Empty.absurd({d == R.db_of(R.exec(R.IncrBy{k, by}, d)) : KV.Trie<String>}, false_true(Equal.trans(Bool, False{}, placed(R.IncrBy{k, by}), True{}, e2, e1)))
    case R.Append{k, v}:
      e1 => e2 => Empty.absurd({d == R.db_of(R.exec(R.Append{k, v}, d)) : KV.Trie<String>}, false_true(Equal.trans(Bool, False{}, placed(R.Append{k, v}), True{}, e2, e1)))
    case R.Strlen{k}:
      e1 => e2 => Empty.absurd({d == R.db_of(R.exec(R.Strlen{k}, d)) : KV.Trie<String>}, false_true(Equal.trans(Bool, False{}, placed(R.Strlen{k}), True{}, e2, e1)))
    case R.MGet{ks}:
      e1 => e2 => Empty.absurd({d == R.db_of(R.exec(R.MGet{ks}, d)) : KV.Trie<String>}, false_true(Equal.trans(Bool, False{}, placed(R.MGet{ks}), True{}, e2, e1)))
    case R.MSet{ps}:
      e1 => e2 => Empty.absurd({d == R.db_of(R.exec(R.MSet{ps}, d)) : KV.Trie<String>}, false_true(Equal.trans(Bool, False{}, placed(R.MSet{ps}), True{}, e2, e1)))
    case R.DbSize{}:
      e1 => e2 => Empty.absurd({d == R.db_of(R.exec(R.DbSize{}, d)) : KV.Trie<String>}, false_true(Equal.trans(Bool, False{}, placed(R.DbSize{}), True{}, e2, e1)))
    case R.FlushAll{}:
      e1 => e2 => Empty.absurd({d == R.db_of(R.exec(R.FlushAll{}, d)) : KV.Trie<String>}, false_true(Equal.trans(Bool, False{}, placed(R.FlushAll{}), True{}, e2, e1)))
    case R.Keys{p}:
      e1 => e2 => Empty.absurd({d == R.db_of(R.exec(R.Keys{p}, d)) : KV.Trie<String>}, false_true(Equal.trans(Bool, False{}, placed(R.Keys{p}), True{}, e2, e1)))
    case R.Bad{r}:
      e1 => e2 => {==}
    case R.SizeAt{x}:
      e1 => e2 => Empty.absurd({d == R.db_of(R.exec(R.SizeAt{x}, d)) : KV.Trie<String>}, false_true(Equal.trans(Bool, False{}, placed(R.SizeAt{x}), True{}, e2, e1)))
    case R.KeysAt{p, x}:
      e1 => e2 => Empty.absurd({d == R.db_of(R.exec(R.KeysAt{p, x}, d)) : KV.Trie<String>}, false_true(Equal.trans(Bool, False{}, placed(R.KeysAt{p, x}), True{}, e2, e1)))
    case R.FlushAt{x}:
      e1 => e2 => Empty.absurd({d == R.db_of(R.exec(R.FlushAt{x}, d)) : KV.Trie<String>}, false_true(Equal.trans(Bool, False{}, placed(R.FlushAt{x}), True{}, e2, e1)))

# a step of struct_seq: the command c after the run older
def struct_cmd(+n: U32, +c: R.Cmd, +older: List<&2, R.Cmd>, +y: KV.Hex, e: {Bool.and(pc(c), pcs(older)) == True{} : Bool}, ih: @j: KV.Hex -> {KV.child(String, Laws.at(seqT(n, older), S.owner(n, j)), j) == KV.child(String, seqD(older), j) : KV.Trie<String>}, b: Bool)
  -> {b == placed(c) : Bool}
  -> {KV.child(String, Laws.at(step.if(b, n, c, seqT(n, older)), S.owner(n, y)), y) == KV.child(String, R.db_of(R.exec(c, seqD(older))), y) : KV.Trie<String>}:
  match b:
    case True{}:
      eb => struct_placed(n, c, older, y, Equal.sym(Bool, True{}, placed(c), eb), ih, nat_eq(S.owner(n, y), home(n, c)))({==})(nat_refl(S.owner(n, y), home(n, c)))
    case False{}:
      eb => %nokey_db(c, seqD(older))(and_l(pc(c), pcs(older))(e))(eb) : {KV.child(String, Laws.at(seqT(n, older), S.owner(n, y)), y) == KV.child(String, _, y) : KV.Trie<String>}
            ih(y)

# after a run of pieces, the shard of each digit holds the database's
# subtrie under it
def struct_seq(+n: U32, cs: List<&2, R.Cmd>, +y: KV.Hex) -> {pcs(cs) == True{} : Bool} -> {KV.child(String, Laws.at(seqT(n, cs), S.owner(n, y)), y) == KV.child(String, seqD(cs), y) : KV.Trie<String>}:
  match cs:
    case Nil{}:
      e => {==}
    case Con{+c, +older}:
      +e => struct_cmd(n, c, older, y, e, j => struct_seq(n, older, j)(and_r(pc(c), pcs(older))(e)), placed(c))({==})

# so every key reads in its shard as in the database
def holds_seq(+n: U32, +cs: List<&2, R.Cmd>, +k: String) -> {pcs(cs) == True{} : Bool} -> {KV.get(String, Laws.at(seqT(n, cs), Laws.shard(n, k)), k) == KV.get(String, seqD(cs), k) : Maybe<&2, String>}:
  e => get_child(String, Laws.at(seqT(n, cs), Laws.shard(n, k)), seqD(cs), k)(struct_seq(n, cs, KV.hex(KV.hash(k)))(e))

# A batch on the shards
# ---------------------
# split pushes each piece on its home shard's list (push_at); a shard's
# actor answers its list in order (answers) and leaves its trie after it
# (after); merge pops each shard's next reply (pop). The piece pushed last
# is the first of its shard, so it pops first, with the reply a run of it
# on that shard gives, and leaves what the rest of the batch answers on
# the shards after that run (pop_push, after_push).

def rep_cons(+c: R.Cmd, +cs: List<&2, R.Cmd>, +t: KV.Trie<String>) -> {R.reply_of(R.exec(c, t)) <> Laws.replies(R.exec_all(cs, R.db_of(R.exec(c, t)))) == Laws.replies(R.exec_all(Con{c, cs}, t)) : List<&2, R.Reply>}:
  %Equal.sym(List<&2, R.Reply> & KV.Trie<String>, R.exec_all(Con{c, cs}, t), R.exec_all.cons(R.reply_of(R.exec(c, t)), R.exec_all(cs, R.db_of(R.exec(c, t)))), Laws.batch_step(c, cs, t)) : {R.reply_of(R.exec(c, t)) <> Laws.replies(R.exec_all(cs, R.db_of(R.exec(c, t)))) == Laws.replies(_) : List<&2, R.Reply>}
  %eta_l(R.exec_all(cs, R.db_of(R.exec(c, t)))) : {R.reply_of(R.exec(c, t)) <> Laws.replies(_) == Laws.replies(R.exec_all.cons(R.reply_of(R.exec(c, t)), _)) : List<&2, R.Reply>}
  {==}

def fin_cons(+c: R.Cmd, +cs: List<&2, R.Cmd>, +t: KV.Trie<String>) -> {Laws.final(R.exec_all(cs, R.db_of(R.exec(c, t)))) == Laws.final(R.exec_all(Con{c, cs}, t)) : KV.Trie<String>}:
  %Equal.sym(List<&2, R.Reply> & KV.Trie<String>, R.exec_all(Con{c, cs}, t), R.exec_all.cons(R.reply_of(R.exec(c, t)), R.exec_all(cs, R.db_of(R.exec(c, t)))), Laws.batch_step(c, cs, t)) : {Laws.final(R.exec_all(cs, R.db_of(R.exec(c, t)))) == Laws.final(_) : KV.Trie<String>}
  %eta_l(R.exec_all(cs, R.db_of(R.exec(c, t)))) : {Laws.final(_) == Laws.final(R.exec_all.cons(R.reply_of(R.exec(c, t)), _)) : KV.Trie<String>}
  {==}

def pop_push(s: Nat, +c: R.Cmd, -h: U32, ps: List<&2, List<&2, S.Part>>, ts: List<&2, KV.Trie<String>>) -> {(R.reply_of(R.exec(c, Laws.at(ts, s))), Laws.answers(ps, put(ts, s, R.db_of(R.exec(c, Laws.at(ts, s)))))) == S.pop(s, Laws.answers(S.push_at(s, S.Part{c, h}, ps), ts)) : R.Reply & S.Store()}:
  match s ps ts:
    case 0n Con{p, prest} Con{t, trest}:
      Equal.cong(List<&2, R.Reply>, R.Reply & S.Store(), z => S.pop(0n, z <> Laws.answers(prest, trest)), R.reply_of(R.exec(c, t)) <> Laws.replies(R.exec_all(Laws.part_cmds(p), R.db_of(R.exec(c, t)))), Laws.replies(R.exec_all(Con{c, Laws.part_cmds(p)}, t)), rep_cons(c, Laws.part_cmds(p), t))
    case 0n Con{p, prest} Nil{}:
      Equal.cong(List<&2, R.Reply>, R.Reply & S.Store(), z => S.pop(0n, z <> Laws.answers(prest, Nil{})), R.reply_of(R.exec(c, KV.empty(String))) <> Laws.replies(R.exec_all(Laws.part_cmds(p), R.db_of(R.exec(c, KV.empty(String))))), Laws.replies(R.exec_all(Con{c, Laws.part_cmds(p)}, KV.empty(String))), rep_cons(c, Laws.part_cmds(p), KV.empty(String)))
    case 0n Nil{} Con{t, trest}:
      Equal.cong(List<&2, R.Reply>, R.Reply & S.Store(), z => S.pop(0n, z <> Laws.answers(Nil{}, trest)), R.reply_of(R.exec(c, t)) <> Laws.replies(R.exec_all(Nil{}, R.db_of(R.exec(c, t)))), Laws.replies(R.exec_all(Con{c, Nil{}}, t)), rep_cons(c, Nil{}, t))
    case 0n Nil{} Nil{}:
      Equal.cong(List<&2, R.Reply>, R.Reply & S.Store(), z => S.pop(0n, z <> Laws.answers(Nil{}, Nil{})), R.reply_of(R.exec(c, KV.empty(String))) <> Laws.replies(R.exec_all(Nil{}, R.db_of(R.exec(c, KV.empty(String))))), Laws.replies(R.exec_all(Con{c, Nil{}}, KV.empty(String))), rep_cons(c, Nil{}, KV.empty(String)))
    case 1n+q Con{p, prest} Con{t, trest}:
      Equal.cong(R.Reply & S.Store(), R.Reply & S.Store(), z => S.pop.back(Laws.replies(R.exec_all(Laws.part_cmds(p), t)), z), (R.reply_of(R.exec(c, Laws.at(trest, q))), Laws.answers(prest, put(trest, q, R.db_of(R.exec(c, Laws.at(trest, q)))))), S.pop(q, Laws.answers(S.push_at(q, S.Part{c, h}, prest), trest)), pop_push(q, c, h, prest, trest))
    case 1n+q Con{p, prest} Nil{}:
      Equal.cong(R.Reply & S.Store(), R.Reply & S.Store(), z => S.pop.back(Laws.replies(R.exec_all(Laws.part_cmds(p), KV.empty(String))), z), (R.reply_of(R.exec(c, Laws.at(Nil{}, q))), Laws.answers(prest, put(Nil{}, q, R.db_of(R.exec(c, Laws.at(Nil{}, q)))))), S.pop(q, Laws.answers(S.push_at(q, S.Part{c, h}, prest), Nil{})), pop_push(q, c, h, prest, Nil{}))
    case 1n+q Nil{} Con{t, trest}:
      Equal.cong(R.Reply & S.Store(), R.Reply & S.Store(), z => S.pop.back(Laws.replies(R.exec_all(Nil{}, t)), z), (R.reply_of(R.exec(c, Laws.at(trest, q))), Laws.answers(Nil{}, put(trest, q, R.db_of(R.exec(c, Laws.at(trest, q)))))), S.pop(q, Laws.answers(S.push_at(q, S.Part{c, h}, Nil{}), trest)), pop_push(q, c, h, Nil{}, trest))
    case 1n+q Nil{} Nil{}:
      Equal.cong(R.Reply & S.Store(), R.Reply & S.Store(), z => S.pop.back(Laws.replies(R.exec_all(Nil{}, KV.empty(String))), z), (R.reply_of(R.exec(c, Laws.at(Nil{}, q))), Laws.answers(Nil{}, put(Nil{}, q, R.db_of(R.exec(c, Laws.at(Nil{}, q)))))), S.pop(q, Laws.answers(S.push_at(q, S.Part{c, h}, Nil{}), Nil{})), pop_push(q, c, h, Nil{}, Nil{}))

def after_push(s: Nat, +c: R.Cmd, -h: U32, ps: List<&2, List<&2, S.Part>>, ts: List<&2, KV.Trie<String>>) -> {Laws.after(ps, put(ts, s, R.db_of(R.exec(c, Laws.at(ts, s))))) == Laws.after(S.push_at(s, S.Part{c, h}, ps), ts) : List<&2, KV.Trie<String>>}:
  match s ps ts:
    case 0n Con{p, prest} Con{t, trest}:
      Equal.cong(KV.Trie<String>, List<&2, KV.Trie<String>>, z => z <> Laws.after(prest, trest), Laws.final(R.exec_all(Laws.part_cmds(p), R.db_of(R.exec(c, t)))), Laws.final(R.exec_all(Con{c, Laws.part_cmds(p)}, t)), fin_cons(c, Laws.part_cmds(p), t))
    case 0n Con{p, prest} Nil{}:
      Equal.cong(KV.Trie<String>, List<&2, KV.Trie<String>>, z => z <> Laws.after(prest, Nil{}), Laws.final(R.exec_all(Laws.part_cmds(p), R.db_of(R.exec(c, KV.empty(String))))), Laws.final(R.exec_all(Con{c, Laws.part_cmds(p)}, KV.empty(String))), fin_cons(c, Laws.part_cmds(p), KV.empty(String)))
    case 0n Nil{} Con{t, trest}:
      Equal.cong(KV.Trie<String>, List<&2, KV.Trie<String>>, z => z <> trest, Laws.final(R.exec_all(Nil{}, R.db_of(R.exec(c, t)))), Laws.final(R.exec_all(Con{c, Nil{}}, t)), fin_cons(c, Nil{}, t))
    case 0n Nil{} Nil{}:
      Equal.cong(KV.Trie<String>, List<&2, KV.Trie<String>>, z => z <> Nil{}, Laws.final(R.exec_all(Nil{}, R.db_of(R.exec(c, KV.empty(String))))), Laws.final(R.exec_all(Con{c, Nil{}}, KV.empty(String))), fin_cons(c, Nil{}, KV.empty(String)))
    case 1n+q Con{p, prest} Con{t, trest}:
      Equal.cong(List<&2, KV.Trie<String>>, List<&2, KV.Trie<String>>, z => Laws.final(R.exec_all(Laws.part_cmds(p), t)) <> z, Laws.after(prest, put(trest, q, R.db_of(R.exec(c, Laws.at(trest, q))))), Laws.after(S.push_at(q, S.Part{c, h}, prest), trest), after_push(q, c, h, prest, trest))
    case 1n+q Con{p, prest} Nil{}:
      Equal.cong(List<&2, KV.Trie<String>>, List<&2, KV.Trie<String>>, z => Laws.final(R.exec_all(Laws.part_cmds(p), KV.empty(String))) <> z, Laws.after(prest, put(Nil{}, q, R.db_of(R.exec(c, Laws.at(Nil{}, q))))), Laws.after(S.push_at(q, S.Part{c, h}, prest), Nil{}), after_push(q, c, h, prest, Nil{}))
    case 1n+q Nil{} Con{t, trest}:
      Equal.cong(List<&2, KV.Trie<String>>, List<&2, KV.Trie<String>>, z => t <> z, Laws.after(Nil{}, put(trest, q, R.db_of(R.exec(c, Laws.at(trest, q))))), Laws.after(S.push_at(q, S.Part{c, h}, Nil{}), trest), after_push(q, c, h, Nil{}, trest))
    case 1n+q Nil{} Nil{}:
      Equal.cong(List<&2, KV.Trie<String>>, List<&2, KV.Trie<String>>, z => KV.empty(String) <> z, Laws.after(Nil{}, put(Nil{}, q, R.db_of(R.exec(c, Laws.at(Nil{}, q))))), Laws.after(S.push_at(q, S.Part{c, h}, Nil{}), Nil{}), after_push(q, c, h, Nil{}, Nil{}))

# split, as two plain recursions over the batch: each command's route, and
# the shards' lists of parts
def rtfst(x: S.Route & List<&2, List<&2, S.Part>>) -> S.Route:
  (a, b) = x
  a

def rtsnd(x: S.Route & List<&2, List<&2, S.Part>>) -> List<&2, List<&2, S.Part>>:
  (a, b) = x
  b

def eta_rt(x: S.Route & List<&2, List<&2, S.Part>>) -> {(rtfst(x), rtsnd(x)) == x : S.Route & List<&2, List<&2, S.Part>>}:
  (a, b) = x
  {==}

def parts_of(+n: U32, cs: List<&2, R.Cmd>) -> List<&2, List<&2, S.Part>>:
  match cs:
    case Nil{}:
      Nil{}
    case Con{c, rest}:
      rtsnd(S.route(n, c, parts_of(n, rest)))

def routes_of(+n: U32, cs: List<&2, R.Cmd>) -> List<&2, S.Route>:
  match cs:
    case Nil{}:
      Nil{}
    case Con{c, +rest}:
      rtfst(S.route(n, c, parts_of(n, rest))) <> routes_of(n, rest)

def split_eq(+n: U32, cs: List<&2, R.Cmd>) -> {(routes_of(n, cs), parts_of(n, cs)) == S.split(n, cs) : List<&2, S.Route> & List<&2, List<&2, S.Part>>}:
  match cs:
    case Nil{}:
      {==}
    case Con{+c, +rest}:
      Equal.trans(List<&2, S.Route> & List<&2, List<&2, S.Part>>,
        (routes_of(n, Con{c, rest}), parts_of(n, Con{c, rest})),
        S.split.put(n, c, (routes_of(n, rest), parts_of(n, rest))),
        S.split(n, Con{c, rest}),
        Equal.cong(S.Route & List<&2, List<&2, S.Part>>, List<&2, S.Route> & List<&2, List<&2, S.Part>>, z => S.split.cons(routes_of(n, rest), z), (rtfst(S.route(n, c, parts_of(n, rest))), rtsnd(S.route(n, c, parts_of(n, rest)))), S.route(n, c, parts_of(n, rest)), eta_rt(S.route(n, c, parts_of(n, rest)))),
        Equal.cong(List<&2, S.Route> & List<&2, List<&2, S.Part>>, List<&2, S.Route> & List<&2, List<&2, S.Part>>, z => S.split.put(n, c, z), (routes_of(n, rest), parts_of(n, rest)), S.split(n, rest), split_eq(n, rest)))

# a command on one key or on one digit goes whole to its home shard
def route_whole(+n: U32, c: R.Cmd, +qs: List<&2, List<&2, S.Part>>) -> {whole(c) == True{} : Bool} -> {(S.ROne{home(n, c)}, S.push_at(home(n, c), S.Part{c, hint(c)}, qs)) == S.route(n, c, qs) : S.Route & List<&2, List<&2, S.Part>>}:
  match c:
    case R.Ping{}:
      wd => Empty.absurd({(S.ROne{home(n, R.Ping{})}, S.push_at(home(n, R.Ping{}), S.Part{R.Ping{}, hint(R.Ping{})}, qs)) == S.route(n, R.Ping{}, qs) : S.Route & List<&2, List<&2, S.Part>>}, false_true(wd))
    case R.Echo{m}:
      wd => Empty.absurd({(S.ROne{home(n, R.Echo{m})}, S.push_at(home(n, R.Echo{m}), S.Part{R.Echo{m}, hint(R.Echo{m})}, qs)) == S.route(n, R.Echo{m}, qs) : S.Route & List<&2, List<&2, S.Part>>}, false_true(wd))
    case R.Get{k}:
      wd => {==}
    case R.Set{k, v}:
      wd => {==}
    case R.SetNX{k, v}:
      wd => {==}
    case R.GetSet{k, v}:
      wd => {==}
    case R.Del{ks}:
      wd => Empty.absurd({(S.ROne{home(n, R.Del{ks})}, S.push_at(home(n, R.Del{ks}), S.Part{R.Del{ks}, hint(R.Del{ks})}, qs)) == S.route(n, R.Del{ks}, qs) : S.Route & List<&2, List<&2, S.Part>>}, false_true(wd))
    case R.Exists{ks}:
      wd => Empty.absurd({(S.ROne{home(n, R.Exists{ks})}, S.push_at(home(n, R.Exists{ks}), S.Part{R.Exists{ks}, hint(R.Exists{ks})}, qs)) == S.route(n, R.Exists{ks}, qs) : S.Route & List<&2, List<&2, S.Part>>}, false_true(wd))
    case R.IncrBy{k, by}:
      wd => {==}
    case R.Append{k, v}:
      wd => {==}
    case R.Strlen{k}:
      wd => {==}
    case R.MGet{ks}:
      wd => Empty.absurd({(S.ROne{home(n, R.MGet{ks})}, S.push_at(home(n, R.MGet{ks}), S.Part{R.MGet{ks}, hint(R.MGet{ks})}, qs)) == S.route(n, R.MGet{ks}, qs) : S.Route & List<&2, List<&2, S.Part>>}, false_true(wd))
    case R.MSet{ps}:
      wd => Empty.absurd({(S.ROne{home(n, R.MSet{ps})}, S.push_at(home(n, R.MSet{ps}), S.Part{R.MSet{ps}, hint(R.MSet{ps})}, qs)) == S.route(n, R.MSet{ps}, qs) : S.Route & List<&2, List<&2, S.Part>>}, false_true(wd))
    case R.DbSize{}:
      wd => Empty.absurd({(S.ROne{home(n, R.DbSize{})}, S.push_at(home(n, R.DbSize{}), S.Part{R.DbSize{}, hint(R.DbSize{})}, qs)) == S.route(n, R.DbSize{}, qs) : S.Route & List<&2, List<&2, S.Part>>}, false_true(wd))
    case R.FlushAll{}:
      wd => Empty.absurd({(S.ROne{home(n, R.FlushAll{})}, S.push_at(home(n, R.FlushAll{}), S.Part{R.FlushAll{}, hint(R.FlushAll{})}, qs)) == S.route(n, R.FlushAll{}, qs) : S.Route & List<&2, List<&2, S.Part>>}, false_true(wd))
    case R.Keys{p}:
      wd => Empty.absurd({(S.ROne{home(n, R.Keys{p})}, S.push_at(home(n, R.Keys{p}), S.Part{R.Keys{p}, hint(R.Keys{p})}, qs)) == S.route(n, R.Keys{p}, qs) : S.Route & List<&2, List<&2, S.Part>>}, false_true(wd))
    case R.Bad{r}:
      wd => Empty.absurd({(S.ROne{home(n, R.Bad{r})}, S.push_at(home(n, R.Bad{r}), S.Part{R.Bad{r}, hint(R.Bad{r})}, qs)) == S.route(n, R.Bad{r}, qs) : S.Route & List<&2, List<&2, S.Part>>}, false_true(wd))
    case R.SizeAt{x}:
      wd => {==}
    case R.KeysAt{p, x}:
      wd => {==}
    case R.FlushAt{x}:
      wd => {==}

# a piece steps the run on its home shard
def step_placed(+n: U32, +c: R.Cmd, +ts: List<&2, KV.Trie<String>>) -> {placed(c) == True{} : Bool} -> {step(n, c, ts) == put(ts, home(n, c), R.db_of(R.exec(c, Laws.at(ts, home(n, c))))) : List<&2, KV.Trie<String>>}:
  pd => %Equal.sym(Bool, placed(c), True{}, pd) : {step.if(_, n, c, ts) == put(ts, home(n, c), R.db_of(R.exec(c, Laws.at(ts, home(n, c))))) : List<&2, KV.Trie<String>>}
        {==}

def whole_placed(c: R.Cmd) -> {whole(c) == True{} : Bool} -> {placed(c) == True{} : Bool}:
  match c:
    case R.Ping{}:
      e => Empty.absurd({placed(R.Ping{}) == True{} : Bool}, false_true(e))
    case R.Echo{m}:
      e => Empty.absurd({placed(R.Echo{m}) == True{} : Bool}, false_true(e))
    case R.Get{k}:
      e => {==}
    case R.Set{k, v}:
      e => {==}
    case R.SetNX{k, v}:
      e => {==}
    case R.GetSet{k, v}:
      e => {==}
    case R.Del{ks}:
      e => Empty.absurd({placed(R.Del{ks}) == True{} : Bool}, false_true(e))
    case R.Exists{ks}:
      e => Empty.absurd({placed(R.Exists{ks}) == True{} : Bool}, false_true(e))
    case R.IncrBy{k, by}:
      e => {==}
    case R.Append{k, v}:
      e => {==}
    case R.Strlen{k}:
      e => {==}
    case R.MGet{ks}:
      e => Empty.absurd({placed(R.MGet{ks}) == True{} : Bool}, false_true(e))
    case R.MSet{ps}:
      e => Empty.absurd({placed(R.MSet{ps}) == True{} : Bool}, false_true(e))
    case R.DbSize{}:
      e => Empty.absurd({placed(R.DbSize{}) == True{} : Bool}, false_true(e))
    case R.FlushAll{}:
      e => Empty.absurd({placed(R.FlushAll{}) == True{} : Bool}, false_true(e))
    case R.Keys{p}:
      e => Empty.absurd({placed(R.Keys{p}) == True{} : Bool}, false_true(e))
    case R.Bad{r}:
      e => Empty.absurd({placed(R.Bad{r}) == True{} : Bool}, false_true(e))
    case R.SizeAt{x}:
      e => {==}
    case R.KeysAt{p, x}:
      e => {==}
    case R.FlushAt{x}:
      e => {==}

def placed_pc(c: R.Cmd) -> {placed(c) == True{} : Bool} -> {pc(c) == True{} : Bool}:
  match c:
    case R.Ping{}:
      e => {==}
    case R.Echo{m}:
      e => {==}
    case R.Get{k}:
      e => {==}
    case R.Set{k, v}:
      e => {==}
    case R.SetNX{k, v}:
      e => {==}
    case R.GetSet{k, v}:
      e => {==}
    case R.Del{ks}:
      e => e
    case R.Exists{ks}:
      e => e
    case R.IncrBy{k, by}:
      e => {==}
    case R.Append{k, v}:
      e => {==}
    case R.Strlen{k}:
      e => {==}
    case R.MGet{ks}:
      e => Empty.absurd({pc(R.MGet{ks}) == True{} : Bool}, false_true(e))
    case R.MSet{ps}:
      e => Empty.absurd({pc(R.MSet{ps}) == True{} : Bool}, false_true(e))
    case R.DbSize{}:
      e => Empty.absurd({pc(R.DbSize{}) == True{} : Bool}, false_true(e))
    case R.FlushAll{}:
      e => Empty.absurd({pc(R.FlushAll{}) == True{} : Bool}, false_true(e))
    case R.Keys{p}:
      e => Empty.absurd({pc(R.Keys{p}) == True{} : Bool}, false_true(e))
    case R.Bad{r}:
      e => {==}
    case R.SizeAt{x}:
      e => {==}
    case R.KeysAt{p, x}:
      e => {==}
    case R.FlushAt{x}:
      e => {==}

def placeds_pcs(cs: List<&2, R.Cmd>) -> {placeds(cs) == True{} : Bool} -> {pcs(cs) == True{} : Bool}:
  match cs:
    case Nil{}:
      e => {==}
    case Con{+c, +rest}:
      +e => and_true(pc(c), pcs(rest))(placed_pc(c)(and_l(placed(c), placeds(rest))(e)))(placeds_pcs(rest)(and_r(placed(c), placeds(rest))(e)))

def pcs_rev(cs: List<&2, R.Cmd>, +H: List<&2, R.Cmd>) -> {pcs(cs) == True{} : Bool} -> {pcs(H) == True{} : Bool} -> {pcs(List.reverse.go(&2, R.Cmd, cs, H)) == True{} : Bool}:
  match cs:
    case Nil{}:
      e1 => e2 => e2
    case Con{+c, +rest}:
      +e1 => e2 => pcs_rev(rest, Con{c, H})(and_r(pc(c), pcs(rest))(e1))(and_true(pc(c), pcs(H))(and_l(pc(c), pcs(rest))(e1))(e2))

# a piece of each, pairs or fan is placed under its key's digit, or its
# own, and carries its key's hash, or 0
def each_dig(e: S.Each, -k: String) -> {KV.hex(KV.hash(k)) == dig(S.each.cmd(e, k)) : KV.Hex}:
  match e:
    case S.EGet{}:
      {==}
    case S.EDel{}:
      {==}
    case S.EExists{}:
      {==}

def each_hint(e: S.Each, -k: String) -> {KV.hash(k) == hint(S.each.cmd(e, k)) : U32}:
  match e:
    case S.EGet{}:
      {==}
    case S.EDel{}:
      {==}
    case S.EExists{}:
      {==}

def placed_each(e: S.Each, -k: String) -> {placed(S.each.cmd(e, k)) == True{} : Bool}:
  match e:
    case S.EGet{}:
      {==}
    case S.EDel{}:
      {==}
    case S.EExists{}:
      {==}

def fan_dig(f: S.Fan, -x: KV.Hex) -> {x == dig(S.fan.cmd(f, x)) : KV.Hex}:
  match f:
    case S.FSize{}:
      {==}
    case S.FKeys{p}:
      {==}
    case S.FFlush{}:
      {==}

def fan_hint(f: S.Fan, -x: KV.Hex) -> {0 == hint(S.fan.cmd(f, x)) : U32}:
  match f:
    case S.FSize{}:
      {==}
    case S.FKeys{p}:
      {==}
    case S.FFlush{}:
      {==}

def placed_fan(f: S.Fan, -x: KV.Hex) -> {placed(S.fan.cmd(f, x)) == True{} : Bool}:
  match f:
    case S.FSize{}:
      {==}
    case S.FKeys{p}:
      {==}
    case S.FFlush{}:
      {==}

def placeds_each(+e: S.Each, ks: List<&2, String>) -> {placeds(each_cmds(e, ks)) == True{} : Bool}:
  match ks:
    case Nil{}:
      {==}
    case Con{+k, rest}:
      and_true(placed(S.each.cmd(e, k)), placeds(each_cmds(e, rest)))(placed_each(e, k))(placeds_each(e, rest))

def placeds_sets(kvs: List<&2, R.KVPair>) -> {placeds(set_cmds(kvs)) == True{} : Bool}:
  match kvs:
    case Nil{}:
      {==}
    case Con{R.KP{k, v}, rest}:
      placeds_sets(rest)

def placeds_fan(+f: S.Fan, xs: List<&2, KV.Hex>) -> {placeds(fan_cmds(f, xs)) == True{} : Bool}:
  match xs:
    case Nil{}:
      {==}
    case Con{+x, rest}:
      and_true(placed(S.fan.cmd(f, x)), placeds(fan_cmds(f, rest)))(placed_fan(f, x))(placeds_fan(f, rest))

# a command's pieces are pieces
def pcs_pieces(c: R.Cmd) -> {pcs(pieces(c)) == True{} : Bool}:
  match c:
    case R.Ping{}:
      {==}
    case R.Echo{m}:
      {==}
    case R.Get{k}:
      {==}
    case R.Set{k, v}:
      {==}
    case R.SetNX{k, v}:
      {==}
    case R.GetSet{k, v}:
      {==}
    case R.Del{+ks}:
      placeds_pcs(each_cmds(S.EDel{}, ks))(placeds_each(S.EDel{}, ks))
    case R.Exists{+ks}:
      placeds_pcs(each_cmds(S.EExists{}, ks))(placeds_each(S.EExists{}, ks))
    case R.IncrBy{k, by}:
      {==}
    case R.Append{k, v}:
      {==}
    case R.Strlen{k}:
      {==}
    case R.MGet{+ks}:
      placeds_pcs(each_cmds(S.EGet{}, ks))(placeds_each(S.EGet{}, ks))
    case R.MSet{+ps}:
      placeds_pcs(set_cmds(ps))(placeds_sets(ps))
    case R.DbSize{}:
      placeds_pcs(fan_cmds(S.FSize{}, KV.digits()))(placeds_fan(S.FSize{}, KV.digits()))
    case R.FlushAll{}:
      placeds_pcs(fan_cmds(S.FFlush{}, KV.digits()))(placeds_fan(S.FFlush{}, KV.digits()))
    case R.Keys{+p}:
      placeds_pcs(fan_cmds(S.FKeys{p}, KV.digits()))(placeds_fan(S.FKeys{p}, KV.digits()))
    case R.Bad{r}:
      {==}
    case R.SizeAt{x}:
      {==}
    case R.KeysAt{p, x}:
      {==}
    case R.FlushAt{x}:
      {==}

# Pieces on the shards
# --------------------
# each, pairs and fan push a command's pieces on their home shards' lists
# (push_pieces), and route its reply from those shards (shards_of). The
# folds of merge pop them back one by one: ok drops the replies, items
# makes an array of them, sum adds their counts up, cat joins their
# arrays.

def shards_of(+n: U32, cs: List<&2, R.Cmd>) -> List<&2, Nat>:
  match cs:
    case Nil{}:
      Nil{}
    case Con{+c, rest}:
      home(n, c) <> shards_of(n, rest)

def push_pieces(+n: U32, cs: List<&2, R.Cmd>, qs: List<&2, List<&2, S.Part>>) -> List<&2, List<&2, S.Part>>:
  match cs:
    case Nil{}:
      qs
    case Con{+c, rest}:
      S.push_at(home(n, c), S.Part{c, hint(c)}, push_pieces(n, rest, qs))

def each_eq(+n: U32, +e: S.Each, ks: List<&2, String>, +qs: List<&2, List<&2, S.Part>>) -> {(shards_of(n, each_cmds(e, ks)), push_pieces(n, each_cmds(e, ks), qs)) == S.each(n, e, ks, qs) : List<&2, Nat> & List<&2, List<&2, S.Part>>}:
  match ks:
    case Nil{}:
      {==}
    case Con{+k, +rest}:
      %each_dig(e, k) : {(S.owner(n, _) <> shards_of(n, each_cmds(e, rest)), S.push_at(S.owner(n, _), S.Part{S.each.cmd(e, k), hint(S.each.cmd(e, k))}, push_pieces(n, each_cmds(e, rest), qs))) == S.each(n, e, Con{k, rest}, qs) : List<&2, Nat> & List<&2, List<&2, S.Part>>}
      %each_hint(e, k) : {(S.owner(n, KV.hex(KV.hash(k))) <> shards_of(n, each_cmds(e, rest)), S.push_at(S.owner(n, KV.hex(KV.hash(k))), S.Part{S.each.cmd(e, k), _}, push_pieces(n, each_cmds(e, rest), qs))) == S.each(n, e, Con{k, rest}, qs) : List<&2, Nat> & List<&2, List<&2, S.Part>>}
      %each_eq(n, e, rest, qs) : {(S.owner(n, KV.hex(KV.hash(k))) <> shards_of(n, each_cmds(e, rest)), S.push_at(S.owner(n, KV.hex(KV.hash(k))), S.Part{S.each.cmd(e, k), KV.hash(k)}, push_pieces(n, each_cmds(e, rest), qs))) == S.each.put(n, e, k, _) : List<&2, Nat> & List<&2, List<&2, S.Part>>}
      {==}

def pairs_eq(+n: U32, kvs: List<&2, R.KVPair>, +qs: List<&2, List<&2, S.Part>>) -> {(shards_of(n, set_cmds(kvs)), push_pieces(n, set_cmds(kvs), qs)) == S.pairs(n, kvs, qs) : List<&2, Nat> & List<&2, List<&2, S.Part>>}:
  match kvs:
    case Nil{}:
      {==}
    case Con{R.KP{+k, +v}, +rest}:
      %pairs_eq(n, rest, qs) : {(Laws.shard(n, k) <> shards_of(n, set_cmds(rest)), S.push_at(Laws.shard(n, k), S.Part{R.Set{k, v}, KV.hash(k)}, push_pieces(n, set_cmds(rest), qs))) == S.pairs.put(n, k, v, _) : List<&2, Nat> & List<&2, List<&2, S.Part>>}
      {==}

def fan_eq(+n: U32, +f: S.Fan, xs: List<&2, KV.Hex>, +qs: List<&2, List<&2, S.Part>>) -> {(shards_of(n, fan_cmds(f, xs)), push_pieces(n, fan_cmds(f, xs), qs)) == S.fan(n, f, xs, qs) : List<&2, Nat> & List<&2, List<&2, S.Part>>}:
  match xs:
    case Nil{}:
      {==}
    case Con{+x, +rest}:
      %fan_dig(f, x) : {(S.owner(n, _) <> shards_of(n, fan_cmds(f, rest)), S.push_at(S.owner(n, _), S.Part{S.fan.cmd(f, x), hint(S.fan.cmd(f, x))}, push_pieces(n, fan_cmds(f, rest), qs))) == S.fan(n, f, Con{x, rest}, qs) : List<&2, Nat> & List<&2, List<&2, S.Part>>}
      %fan_hint(f, x) : {(S.owner(n, x) <> shards_of(n, fan_cmds(f, rest)), S.push_at(S.owner(n, x), S.Part{S.fan.cmd(f, x), _}, push_pieces(n, fan_cmds(f, rest), qs))) == S.fan(n, f, Con{x, rest}, qs) : List<&2, Nat> & List<&2, List<&2, S.Part>>}
      %fan_eq(n, f, rest, qs) : {(S.owner(n, x) <> shards_of(n, fan_cmds(f, rest)), S.push_at(S.owner(n, x), S.Part{S.fan.cmd(f, x), 0}, push_pieces(n, fan_cmds(f, rest), qs))) == S.fan.put(n, f, x, _) : List<&2, Nat> & List<&2, List<&2, S.Part>>}
      {==}

# a piece pushed on its home shard's list pops first, with the database's
# reply
def pop_piece(+n: U32, +c: R.Cmd, +qs: List<&2, List<&2, S.Part>>, +H: List<&2, R.Cmd>) -> {placed(c) == True{} : Bool} -> {pcs(H) == True{} : Bool} -> {(R.reply_of(R.exec(c, seqD(H))), Laws.answers(qs, seqT(n, Con{c, H}))) == S.pop(home(n, c), Laws.answers(S.push_at(home(n, c), S.Part{c, hint(c)}, qs), seqT(n, H))) : R.Reply & S.Store()}:
  +pd => e =>
    %pop_push(home(n, c), c, hint(c), qs, seqT(n, H)) : {(R.reply_of(R.exec(c, seqD(H))), Laws.answers(qs, seqT(n, Con{c, H}))) == _ : R.Reply & S.Store()}
    %step_placed(n, c, seqT(n, H))(pd) : {(R.reply_of(R.exec(c, seqD(H))), Laws.answers(qs, seqT(n, Con{c, H}))) == (R.reply_of(R.exec(c, Laws.at(seqT(n, H), home(n, c)))), Laws.answers(qs, _)) : R.Reply & S.Store()}
    %reply_loc(c, Laws.at(seqT(n, H), home(n, c)), seqD(H))(pd)(struct_seq(n, H, dig(c))(e)) : {(_, Laws.answers(qs, seqT(n, Con{c, H}))) == (R.reply_of(R.exec(c, Laws.at(seqT(n, H), home(n, c)))), Laws.answers(qs, step(n, c, seqT(n, H)))) : R.Reply & S.Store()}
    {==}

def after_pieces(+n: U32, cs: List<&2, R.Cmd>, +qs: List<&2, List<&2, S.Part>>, +H: List<&2, R.Cmd>) -> {placeds(cs) == True{} : Bool} -> {Laws.after(qs, seqT(n, List.reverse.go(&2, R.Cmd, cs, H))) == Laws.after(push_pieces(n, cs, qs), seqT(n, H)) : List<&2, KV.Trie<String>>}:
  match cs:
    case Nil{}:
      e => {==}
    case Con{+c, +rest}:
      +e => %after_push(home(n, c), c, hint(c), push_pieces(n, rest, qs), seqT(n, H)) : {Laws.after(qs, seqT(n, List.reverse.go(&2, R.Cmd, rest, Con{c, H}))) == _ : List<&2, KV.Trie<String>>}
            %step_placed(n, c, seqT(n, H))(and_l(placed(c), placeds(rest))(e)) : {Laws.after(qs, seqT(n, List.reverse.go(&2, R.Cmd, rest, Con{c, H}))) == Laws.after(push_pieces(n, rest, qs), _) : List<&2, KV.Trie<String>>}
            after_pieces(n, rest, qs, Con{c, H})(and_r(placed(c), placeds(rest))(e))

def ok_pieces(+n: U32, cs: List<&2, R.Cmd>, +qs: List<&2, List<&2, S.Part>>, +H: List<&2, R.Cmd>) -> {placeds(cs) == True{} : Bool} -> {Laws.answers(qs, seqT(n, List.reverse.go(&2, R.Cmd, cs, H))) == S.ok.go(shards_of(n, cs), Laws.answers(push_pieces(n, cs, qs), seqT(n, H))) : S.Store()}:
  match cs:
    case Nil{}:
      e => {==}
    case Con{+c, +rest}:
      +e => %pop_push(home(n, c), c, hint(c), push_pieces(n, rest, qs), seqT(n, H)) : {Laws.answers(qs, seqT(n, List.reverse.go(&2, R.Cmd, rest, Con{c, H}))) == S.ok.go(shards_of(n, rest), S.ok.drop(_)) : S.Store()}
            %step_placed(n, c, seqT(n, H))(and_l(placed(c), placeds(rest))(e)) : {Laws.answers(qs, seqT(n, List.reverse.go(&2, R.Cmd, rest, Con{c, H}))) == S.ok.go(shards_of(n, rest), Laws.answers(push_pieces(n, rest, qs), _)) : S.Store()}
            ok_pieces(n, rest, qs, Con{c, H})(and_r(placed(c), placeds(rest))(e))

def items_of(rs: List<&2, R.Reply>) -> List<&2, R.Item>:
  match rs:
    case Nil{}:
      Nil{}
    case Con{r, rest}:
      S.item_of(r) <> items_of(rest)

def items_pieces(+n: U32, cs: List<&2, R.Cmd>, +qs: List<&2, List<&2, S.Part>>, +H: List<&2, R.Cmd>, +acc: List<&2, R.Item>) -> {placeds(cs) == True{} : Bool} -> {pcs(H) == True{} : Bool} -> {(List.reverse.go(&2, R.Item, items_of(rfst(run(cs, seqD(H)))), acc), Laws.answers(qs, seqT(n, List.reverse.go(&2, R.Cmd, cs, H)))) == S.items.go(shards_of(n, cs), (acc, Laws.answers(push_pieces(n, cs, qs), seqT(n, H)))) : List<&2, R.Item> & S.Store()}:
  match cs:
    case Nil{}:
      e1 => e2 => {==}
    case Con{+c, +rest}:
      +e1 => +e2 =>
        %pop_piece(n, c, push_pieces(n, rest, qs), H)(and_l(placed(c), placeds(rest))(e1))(e2) : {(List.reverse.go(&2, R.Item, items_of(rfst(run(Con{c, rest}, seqD(H)))), acc), Laws.answers(qs, seqT(n, List.reverse.go(&2, R.Cmd, rest, Con{c, H})))) == S.items.go(shards_of(n, rest), S.items.put(acc, _)) : List<&2, R.Item> & S.Store()}
        %eta_l(run(rest, R.db_of(R.exec(c, seqD(H))))) : {(List.reverse.go(&2, R.Item, items_of(rfst(R.exec_all.cons(R.reply_of(R.exec(c, seqD(H))), _))), acc), Laws.answers(qs, seqT(n, List.reverse.go(&2, R.Cmd, rest, Con{c, H})))) == S.items.go(shards_of(n, rest), (S.item_of(R.reply_of(R.exec(c, seqD(H)))) <> acc, Laws.answers(push_pieces(n, rest, qs), seqT(n, Con{c, H})))) : List<&2, R.Item> & S.Store()}
        items_pieces(n, rest, qs, Con{c, H}, S.item_of(R.reply_of(R.exec(c, seqD(H)))) <> acc)(and_r(placed(c), placeds(rest))(e1))(and_true(pc(c), pcs(H))(placed_pc(c)(and_l(placed(c), placeds(rest))(e1)))(e2))

def total(rs: List<&2, R.Reply>) -> Nat:
  match rs:
    case Nil{}:
      0n
    case Con{r, rest}:
      Nat.add(S.count_of(r), total(rest))

def sum_pieces(+n: U32, cs: List<&2, R.Cmd>, +qs: List<&2, List<&2, S.Part>>, +H: List<&2, R.Cmd>, +acc: Nat) -> {placeds(cs) == True{} : Bool} -> {pcs(H) == True{} : Bool} -> {(Nat.add(acc, total(rfst(run(cs, seqD(H))))), Laws.answers(qs, seqT(n, List.reverse.go(&2, R.Cmd, cs, H)))) == S.sum.go(shards_of(n, cs), (acc, Laws.answers(push_pieces(n, cs, qs), seqT(n, H)))) : Nat & S.Store()}:
  match cs:
    case Nil{}:
      e1 => e2 => %add_zero(acc) : {(_, Laws.answers(qs, seqT(n, H))) == (acc, Laws.answers(qs, seqT(n, H))) : Nat & S.Store()}
                  {==}
    case Con{+c, +rest}:
      +e1 => +e2 =>
        %pop_piece(n, c, push_pieces(n, rest, qs), H)(and_l(placed(c), placeds(rest))(e1))(e2) : {(Nat.add(acc, total(rfst(run(Con{c, rest}, seqD(H))))), Laws.answers(qs, seqT(n, List.reverse.go(&2, R.Cmd, rest, Con{c, H})))) == S.sum.go(shards_of(n, rest), S.sum.put(acc, _)) : Nat & S.Store()}
        %eta_l(run(rest, R.db_of(R.exec(c, seqD(H))))) : {(Nat.add(acc, total(rfst(R.exec_all.cons(R.reply_of(R.exec(c, seqD(H))), _)))), Laws.answers(qs, seqT(n, List.reverse.go(&2, R.Cmd, rest, Con{c, H})))) == S.sum.go(shards_of(n, rest), (Nat.add(acc, S.count_of(R.reply_of(R.exec(c, seqD(H))))), Laws.answers(push_pieces(n, rest, qs), seqT(n, Con{c, H})))) : Nat & S.Store()}
        %add_assoc(acc, S.count_of(R.reply_of(R.exec(c, seqD(H)))), total(rfst(run(rest, R.db_of(R.exec(c, seqD(H))))))) : {(_, Laws.answers(qs, seqT(n, List.reverse.go(&2, R.Cmd, rest, Con{c, H})))) == S.sum.go(shards_of(n, rest), (Nat.add(acc, S.count_of(R.reply_of(R.exec(c, seqD(H))))), Laws.answers(push_pieces(n, rest, qs), seqT(n, Con{c, H})))) : Nat & S.Store()}
        sum_pieces(n, rest, qs, Con{c, H}, Nat.add(acc, S.count_of(R.reply_of(R.exec(c, seqD(H))))))(and_r(placed(c), placeds(rest))(e1))(and_true(pc(c), pcs(H))(placed_pc(c)(and_l(placed(c), placeds(rest))(e1)))(e2))

# the items of the arrays among rs, one array after another
def cats(rs: List<&2, R.Reply>) -> List<&2, R.Item>:
  match rs:
    case Nil{}:
      Nil{}
    case Con{r, rest}:
      List.append(&2, R.Item, S.array_of(r), cats(rest))

def cat_pieces(+n: U32, cs: List<&2, R.Cmd>, +qs: List<&2, List<&2, S.Part>>, +H: List<&2, R.Cmd>, +acc: List<&2, R.Item>) -> {placeds(cs) == True{} : Bool} -> {pcs(H) == True{} : Bool} -> {(List.reverse.go(&2, R.Item, cats(rfst(run(cs, seqD(H)))), acc), Laws.answers(qs, seqT(n, List.reverse.go(&2, R.Cmd, cs, H)))) == S.cat.go(shards_of(n, cs), (acc, Laws.answers(push_pieces(n, cs, qs), seqT(n, H)))) : List<&2, R.Item> & S.Store()}:
  match cs:
    case Nil{}:
      e1 => e2 => {==}
    case Con{+c, +rest}:
      +e1 => +e2 =>
        %pop_piece(n, c, push_pieces(n, rest, qs), H)(and_l(placed(c), placeds(rest))(e1))(e2) : {(List.reverse.go(&2, R.Item, cats(rfst(run(Con{c, rest}, seqD(H)))), acc), Laws.answers(qs, seqT(n, List.reverse.go(&2, R.Cmd, rest, Con{c, H})))) == S.cat.go(shards_of(n, rest), S.cat.put(acc, _)) : List<&2, R.Item> & S.Store()}
        %eta_l(run(rest, R.db_of(R.exec(c, seqD(H))))) : {(List.reverse.go(&2, R.Item, cats(rfst(R.exec_all.cons(R.reply_of(R.exec(c, seqD(H))), _))), acc), Laws.answers(qs, seqT(n, List.reverse.go(&2, R.Cmd, rest, Con{c, H})))) == S.cat.go(shards_of(n, rest), (S.cat.rev(S.array_of(R.reply_of(R.exec(c, seqD(H)))), acc), Laws.answers(push_pieces(n, rest, qs), seqT(n, Con{c, H})))) : List<&2, R.Item> & S.Store()}
        %rev_app(S.array_of(R.reply_of(R.exec(c, seqD(H)))), cats(rfst(run(rest, R.db_of(R.exec(c, seqD(H)))))), acc) : {(_, Laws.answers(qs, seqT(n, List.reverse.go(&2, R.Cmd, rest, Con{c, H})))) == S.cat.go(shards_of(n, rest), (S.cat.rev(S.array_of(R.reply_of(R.exec(c, seqD(H)))), acc), Laws.answers(push_pieces(n, rest, qs), seqT(n, Con{c, H})))) : List<&2, R.Item> & S.Store()}
        cat_pieces(n, rest, qs, Con{c, H}, S.cat.rev(S.array_of(R.reply_of(R.exec(c, seqD(H)))), acc))(and_r(placed(c), placeds(rest))(e1))(and_true(pc(c), pcs(H))(placed_pc(c)(and_l(placed(c), placeds(rest))(e1)))(e2))

# A command's pieces on the database
# ----------------------------------
# Run one after another on the database, a command's pieces give its
# reply and its database: MGET's values are its GETs', EXISTS counts what
# its EXISTS count, DEL removes and counts as its DELs do, MSET sets as its
# SETs do, DBSIZE counts what its SizeAts count, KEYS answers the keys
# its KeysAts answer, and FLUSHALL leaves the root of empty subtries its
# FlushAts leave.

def item_get(m: Maybe<&2, String>) -> {R.i_get(m) == S.item_of(R.r_get(m)) : R.Item}:
  match m:
    case Some{s}:
      {==}
    case None{}:
      {==}

def mget_items(ks: List<&2, String>, +d: KV.Trie<String>) -> {R.mget_keys(ks, d) == items_of(rfst(run(each_cmds(S.EGet{}, ks), d))) : List<&2, R.Item>}:
  match ks:
    case Nil{}:
      {==}
    case Con{+k, +rest}:
      %eta_l(run(each_cmds(S.EGet{}, rest), d)) : {R.mget_keys(Con{k, rest}, d) == items_of(rfst(R.exec_all.cons(R.r_get(KV.get(String, d, k)), _))) : List<&2, R.Item>}
      %item_get(KV.get(String, d, k)) : {R.i_get(KV.get(String, d, k)) <> R.mget_keys(rest, d) == _ <> items_of(rfst(run(each_cmds(S.EGet{}, rest), d))) : List<&2, R.Item>}
      Equal.cong(List<&2, R.Item>, List<&2, R.Item>, z => R.i_get(KV.get(String, d, k)) <> z, R.mget_keys(rest, d), items_of(rfst(run(each_cmds(S.EGet{}, rest), d))), mget_items(rest, d))

def gets_db(ks: List<&2, String>, +d: KV.Trie<String>) -> {d == rsnd(run(each_cmds(S.EGet{}, ks), d)) : KV.Trie<String>}:
  match ks:
    case Nil{}:
      {==}
    case Con{+k, +rest}:
      %eta_l(run(each_cmds(S.EGet{}, rest), d)) : {d == rsnd(R.exec_all.cons(R.r_get(KV.get(String, d, k)), _)) : KV.Trie<String>}
      gets_db(rest, d)

def exists_total(ks: List<&2, String>, +d: KV.Trie<String>) -> {R.exists_keys(ks, d) == total(rfst(run(each_cmds(S.EExists{}, ks), d))) : Nat}:
  match ks:
    case Nil{}:
      {==}
    case Con{+k, +rest}:
      %eta_l(run(each_cmds(S.EExists{}, rest), d)) : {R.exists_keys(Con{k, rest}, d) == total(rfst(R.exec_all.cons(R.r_int(Nat.add(Bool.pick(Nat, Maybe.is_some(&2, String, KV.get(String, d, k)), 1n, 0n), 0n)), _))) : Nat}
      %add_zero(Bool.pick(Nat, Maybe.is_some(&2, String, KV.get(String, d, k)), 1n, 0n)) : {Nat.add(Bool.pick(Nat, Maybe.is_some(&2, String, KV.get(String, d, k)), 1n, 0n), R.exists_keys(rest, d)) == Nat.add(_, total(rfst(run(each_cmds(S.EExists{}, rest), d)))) : Nat}
      Equal.cong(Nat, Nat, x => Nat.add(Bool.pick(Nat, Maybe.is_some(&2, String, KV.get(String, d, k)), 1n, 0n), x), R.exists_keys(rest, d), total(rfst(run(each_cmds(S.EExists{}, rest), d))), exists_total(rest, d))

def exs_db(ks: List<&2, String>, +d: KV.Trie<String>) -> {d == rsnd(run(each_cmds(S.EExists{}, ks), d)) : KV.Trie<String>}:
  match ks:
    case Nil{}:
      {==}
    case Con{+k, +rest}:
      %eta_l(run(each_cmds(S.EExists{}, rest), d)) : {d == rsnd(R.exec_all.cons(R.r_int(Nat.add(Bool.pick(Nat, Maybe.is_some(&2, String, KV.get(String, d, k)), 1n, 0n), 0n)), _)) : KV.Trie<String>}
      exs_db(rest, d)

def dfst(r: Nat & KV.Trie<String>) -> Nat:
  (a, d) = r
  a

def dsnd(r: Nat & KV.Trie<String>) -> KV.Trie<String>:
  (a, d) = r
  d

def put_fst(b: Bool, r: Nat & KV.Trie<String>) -> {Nat.add(Bool.pick(Nat, b, 1n, 0n), dfst(r)) == dfst(R.del_keys.put(b, r)) : Nat}:
  match b:
    case True{}:
      (a, d) = r
      {==}
    case False{}:
      {==}

def put_snd(b: Bool, r: Nat & KV.Trie<String>) -> {dsnd(r) == dsnd(R.del_keys.put(b, r)) : KV.Trie<String>}:
  match b:
    case True{}:
      (a, d) = r
      {==}
    case False{}:
      {==}

def del_eta(r: Nat & KV.Trie<String>) -> {(R.r_int(dfst(r)), dsnd(r)) == R.del_reply(r) : R.Reply & KV.Trie<String>}:
  (a, d) = r
  {==}

def del_total(ks: List<&2, String>, +d: KV.Trie<String>) -> {dfst(R.del_keys(ks, d)) == total(rfst(run(each_cmds(S.EDel{}, ks), d))) : Nat}:
  match ks:
    case Nil{}:
      {==}
    case Con{+k, +rest}:
      %put_fst(KV.has(String, d, k), R.del_keys(rest, KV.del(String, d, k))) : {_ == total(rfst(run(each_cmds(S.EDel{}, Con{k, rest}), d))) : Nat}
      %del_one(KV.has(String, d, k), KV.del(String, d, k)) : {Nat.add(Bool.pick(Nat, KV.has(String, d, k), 1n, 0n), dfst(R.del_keys(rest, KV.del(String, d, k)))) == total(rfst(R.exec_all.cons(R.reply_of(_), run(each_cmds(S.EDel{}, rest), R.db_of(_))))) : Nat}
      %eta_l(run(each_cmds(S.EDel{}, rest), KV.del(String, d, k))) : {Nat.add(Bool.pick(Nat, KV.has(String, d, k), 1n, 0n), dfst(R.del_keys(rest, KV.del(String, d, k)))) == total(rfst(R.exec_all.cons(R.r_int(Bool.pick(Nat, KV.has(String, d, k), 1n, 0n)), _))) : Nat}
      Equal.cong(Nat, Nat, x => Nat.add(Bool.pick(Nat, KV.has(String, d, k), 1n, 0n), x), dfst(R.del_keys(rest, KV.del(String, d, k))), total(rfst(run(each_cmds(S.EDel{}, rest), KV.del(String, d, k)))), del_total(rest, KV.del(String, d, k)))

def del_db(ks: List<&2, String>, +d: KV.Trie<String>) -> {dsnd(R.del_keys(ks, d)) == rsnd(run(each_cmds(S.EDel{}, ks), d)) : KV.Trie<String>}:
  match ks:
    case Nil{}:
      {==}
    case Con{+k, +rest}:
      %put_snd(KV.has(String, d, k), R.del_keys(rest, KV.del(String, d, k))) : {_ == rsnd(run(each_cmds(S.EDel{}, Con{k, rest}), d)) : KV.Trie<String>}
      %del_one(KV.has(String, d, k), KV.del(String, d, k)) : {dsnd(R.del_keys(rest, KV.del(String, d, k))) == rsnd(R.exec_all.cons(R.reply_of(_), run(each_cmds(S.EDel{}, rest), R.db_of(_)))) : KV.Trie<String>}
      %eta_l(run(each_cmds(S.EDel{}, rest), KV.del(String, d, k))) : {dsnd(R.del_keys(rest, KV.del(String, d, k))) == rsnd(R.exec_all.cons(R.r_int(Bool.pick(Nat, KV.has(String, d, k), 1n, 0n)), _)) : KV.Trie<String>}
      del_db(rest, KV.del(String, d, k))

def mset_db(kvs: List<&2, R.KVPair>, +d: KV.Trie<String>) -> {R.mset_pairs(kvs, d) == rsnd(run(set_cmds(kvs), d)) : KV.Trie<String>}:
  match kvs:
    case Nil{}:
      {==}
    case Con{R.KP{+k, +v}, +rest}:
      %eta_l(run(set_cmds(rest), KV.set(String, d, k, v))) : {R.mset_pairs(rest, KV.set(String, d, k, v)) == rsnd(R.exec_all.cons(R.r_ok(), _)) : KV.Trie<String>}
      mset_db(rest, KV.set(String, d, k, v))

def size_total(xs: List<&2, KV.Hex>, +d: KV.Trie<String>) -> {KV.sizes(String, d, xs) == total(rfst(run(fan_cmds(S.FSize{}, xs), d))) : Nat}:
  match xs:
    case Nil{}:
      {==}
    case Con{+x, +rest}:
      %eta_l(run(fan_cmds(S.FSize{}, rest), d)) : {KV.sizes(String, d, Con{x, rest}) == total(rfst(R.exec_all.cons(R.r_int(KV.size.at(String, d, x)), _))) : Nat}
      Equal.cong(Nat, Nat, z => Nat.add(KV.size.at(String, d, x), z), KV.sizes(String, d, rest), total(rfst(run(fan_cmds(S.FSize{}, rest), d))), size_total(rest, d))

def size_db(xs: List<&2, KV.Hex>, +d: KV.Trie<String>) -> {d == rsnd(run(fan_cmds(S.FSize{}, xs), d)) : KV.Trie<String>}:
  match xs:
    case Nil{}:
      {==}
    case Con{+x, +rest}:
      %eta_l(run(fan_cmds(S.FSize{}, rest), d)) : {d == rsnd(R.exec_all.cons(R.r_int(KV.size.at(String, d, x)), _)) : KV.Trie<String>}
      size_db(rest, d)

def keep_app(hit: Bool, -k: String, -xs: List<&2, R.Item>, -ys: List<&2, R.Item>) -> {List.append(&2, R.Item, R.glob_keep(k, xs, hit), ys) == R.glob_keep(k, List.append(&2, R.Item, xs, ys), hit) : List<&2, R.Item>}:
  match hit:
    case True{}:
      {==}
    case False{}:
      {==}

# the keys of two lists one after the other that match are those of each
def filter_app(+p: String, xs: List<&2, String>, -ys: List<&2, String>) -> {List.append(&2, R.Item, R.glob_filter(p, xs), R.glob_filter(p, ys)) == R.glob_filter(p, List.append(&2, String, xs, ys)) : List<&2, R.Item>}:
  match xs:
    case Nil{}:
      {==}
    case Con{+k, +rest}:
      %filter_app(p, rest, ys) : {List.append(&2, R.Item, R.glob_keep(k, R.glob_filter(p, rest), R.glob(p, k)), R.glob_filter(p, ys)) == R.glob_keep(k, _, R.glob(p, k)) : List<&2, R.Item>}
      keep_app(R.glob(p, k), k, R.glob_filter(p, rest), R.glob_filter(p, ys))

def keys_cats(+p: String, xs: List<&2, KV.Hex>, +d: KV.Trie<String>) -> {R.glob_filter(p, KV.keys.of(String, d, xs)) == cats(rfst(run(fan_cmds(S.FKeys{p}, xs), d))) : List<&2, R.Item>}:
  match xs:
    case Nil{}:
      {==}
    case Con{+x, +rest}:
      %eta_l(run(fan_cmds(S.FKeys{p}, rest), d)) : {R.glob_filter(p, KV.keys.of(String, d, Con{x, rest})) == cats(rfst(R.exec_all.cons(R.RArray{R.glob_filter(p, KV.keys.at(String, d, x, Nil{}))}, _))) : List<&2, R.Item>}
      %Equal.sym(List<&2, String>, KV.keys.at(String, d, x, KV.keys.of(String, d, rest)), List.append(&2, String, KV.keys.at(String, d, x, Nil{}), KV.keys.of(String, d, rest)), keys_at_app(String, d, x, Nil{}, KV.keys.of(String, d, rest))) : {R.glob_filter(p, _) == List.append(&2, R.Item, R.glob_filter(p, KV.keys.at(String, d, x, Nil{})), cats(rfst(run(fan_cmds(S.FKeys{p}, rest), d)))) : List<&2, R.Item>}
      %filter_app(p, KV.keys.at(String, d, x, Nil{}), KV.keys.of(String, d, rest)) : {_ == List.append(&2, R.Item, R.glob_filter(p, KV.keys.at(String, d, x, Nil{})), cats(rfst(run(fan_cmds(S.FKeys{p}, rest), d)))) : List<&2, R.Item>}
      Equal.cong(List<&2, R.Item>, List<&2, R.Item>, z => List.append(&2, R.Item, R.glob_filter(p, KV.keys.at(String, d, x, Nil{})), z), R.glob_filter(p, KV.keys.of(String, d, rest)), cats(rfst(run(fan_cmds(S.FKeys{p}, rest), d))), keys_cats(p, rest, d))

def keys_db(+p: String, xs: List<&2, KV.Hex>, +d: KV.Trie<String>) -> {d == rsnd(run(fan_cmds(S.FKeys{p}, xs), d)) : KV.Trie<String>}:
  match xs:
    case Nil{}:
      {==}
    case Con{+x, +rest}:
      %eta_l(run(fan_cmds(S.FKeys{p}, rest), d)) : {d == rsnd(R.exec_all.cons(R.RArray{R.glob_filter(p, KV.keys.at(String, d, x, Nil{}))}, _)) : KV.Trie<String>}
      keys_db(p, rest, d)

def flush_db(xs: List<&2, KV.Hex>, +d: KV.Trie<String>) -> {KV.clear.of(String, xs, d) == rsnd(run(fan_cmds(S.FFlush{}, xs), d)) : KV.Trie<String>}:
  match xs:
    case Nil{}:
      {==}
    case Con{+x, +rest}:
      %eta_l(run(fan_cmds(S.FFlush{}, rest), KV.with_child(String, d, x, KV.empty(String)))) : {KV.clear.of(String, rest, KV.with_child(String, d, x, KV.empty(String))) == rsnd(R.exec_all.cons(R.r_ok(), _)) : KV.Trie<String>}
      flush_db(rest, KV.with_child(String, d, x, KV.empty(String)))

# a run of pieces after H leaves the database the run H then the pieces do
def seqD_rev(cs: List<&2, R.Cmd>, +H: List<&2, R.Cmd>) -> {rsnd(run(cs, seqD(H))) == seqD(List.reverse.go(&2, R.Cmd, cs, H)) : KV.Trie<String>}:
  match cs:
    case Nil{}:
      {==}
    case Con{+c, +rest}:
      %eta_l(run(rest, R.db_of(R.exec(c, seqD(H))))) : {rsnd(R.exec_all.cons(R.reply_of(R.exec(c, seqD(H))), _)) == seqD(List.reverse.go(&2, R.Cmd, rest, Con{c, H})) : KV.Trie<String>}
      seqD_rev(rest, Con{c, H})

# a command leaves the database its pieces leave
def pieces_db(c: R.Cmd, +H: List<&2, R.Cmd>) -> {R.db_of(R.exec(c, seqD(H))) == seqD(List.reverse.go(&2, R.Cmd, pieces(c), H)) : KV.Trie<String>}:
  match c:
    case R.Ping{}:
      {==}
    case R.Echo{m}:
      {==}
    case R.Get{k}:
      {==}
    case R.Set{k, v}:
      {==}
    case R.SetNX{k, v}:
      {==}
    case R.GetSet{k, v}:
      {==}
    case R.Del{+ks}:
      %del_eta(R.del_keys(ks, seqD(H))) : {R.db_of(_) == seqD(List.reverse.go(&2, R.Cmd, each_cmds(S.EDel{}, ks), H)) : KV.Trie<String>}
      Equal.trans(KV.Trie<String>, dsnd(R.del_keys(ks, seqD(H))), rsnd(run(each_cmds(S.EDel{}, ks), seqD(H))), seqD(List.reverse.go(&2, R.Cmd, each_cmds(S.EDel{}, ks), H)), del_db(ks, seqD(H)), seqD_rev(each_cmds(S.EDel{}, ks), H))
    case R.Exists{+ks}:
      Equal.trans(KV.Trie<String>, seqD(H), rsnd(run(each_cmds(S.EExists{}, ks), seqD(H))), seqD(List.reverse.go(&2, R.Cmd, each_cmds(S.EExists{}, ks), H)), exs_db(ks, seqD(H)), seqD_rev(each_cmds(S.EExists{}, ks), H))
    case R.IncrBy{k, by}:
      {==}
    case R.Append{k, v}:
      {==}
    case R.Strlen{k}:
      {==}
    case R.MGet{+ks}:
      Equal.trans(KV.Trie<String>, seqD(H), rsnd(run(each_cmds(S.EGet{}, ks), seqD(H))), seqD(List.reverse.go(&2, R.Cmd, each_cmds(S.EGet{}, ks), H)), gets_db(ks, seqD(H)), seqD_rev(each_cmds(S.EGet{}, ks), H))
    case R.MSet{+ps}:
      Equal.trans(KV.Trie<String>, R.mset_pairs(ps, seqD(H)), rsnd(run(set_cmds(ps), seqD(H))), seqD(List.reverse.go(&2, R.Cmd, set_cmds(ps), H)), mset_db(ps, seqD(H)), seqD_rev(set_cmds(ps), H))
    case R.DbSize{}:
      Equal.trans(KV.Trie<String>, seqD(H), rsnd(run(fan_cmds(S.FSize{}, KV.digits()), seqD(H))), seqD(List.reverse.go(&2, R.Cmd, fan_cmds(S.FSize{}, KV.digits()), H)), size_db(KV.digits(), seqD(H)), seqD_rev(fan_cmds(S.FSize{}, KV.digits()), H))
    case R.FlushAll{}:
      Equal.trans(KV.Trie<String>, KV.clear.of(String, KV.digits(), seqD(H)), rsnd(run(fan_cmds(S.FFlush{}, KV.digits()), seqD(H))), seqD(List.reverse.go(&2, R.Cmd, fan_cmds(S.FFlush{}, KV.digits()), H)), flush_db(KV.digits(), seqD(H)), seqD_rev(fan_cmds(S.FFlush{}, KV.digits()), H))
    case R.Keys{+p}:
      Equal.trans(KV.Trie<String>, seqD(H), rsnd(run(fan_cmds(S.FKeys{p}, KV.digits()), seqD(H))), seqD(List.reverse.go(&2, R.Cmd, fan_cmds(S.FKeys{p}, KV.digits()), H)), keys_db(p, KV.digits(), seqD(H)), seqD_rev(fan_cmds(S.FKeys{p}, KV.digits()), H))
    case R.Bad{r}:
      {==}
    case R.SizeAt{x}:
      {==}
    case R.KeysAt{p, x}:
      {==}
    case R.FlushAt{x}:
      {==}

# The replies of a batch
# ----------------------
# merge, on the shards' answers to a batch run after a run H, gives the
# replies of the batch on H's database. rep_go goes command by command:
# the store st is what the shards have left to answer, so the claim
# carries an equation for it; ih is the claim for the rest of the batch.

def rep_whole(+n: U32, +c: R.Cmd, +rest: List<&2, R.Cmd>, +H: List<&2, R.Cmd>, +acc: List<&2, R.Reply>, +st: S.Store(), +wd: {whole(c) == True{} : Bool}, +e2: {pcs(H) == True{} : Bool}, es: {Laws.answers(rtsnd(S.route(n, c, parts_of(n, rest))), seqT(n, H)) == st : S.Store()}, ih: @H2: List<&2, R.Cmd> -> @acc2: List<&2, R.Reply> -> @st2: S.Store() -> {pcs(H2) == True{} : Bool} -> {Laws.answers(parts_of(n, rest), seqT(n, H2)) == st2 : S.Store()} -> {List.reverse.go(&2, R.Reply, acc2, rfst(run(rest, seqD(H2)))) == S.merge.fin(S.merge.go(routes_of(n, rest), (acc2, st2))) : List<&2, R.Reply>})
  -> {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{c, rest}, seqD(H)))) == S.merge.fin(S.merge.go(rtfst(S.route(n, c, parts_of(n, rest))) <> routes_of(n, rest), (acc, st))) : List<&2, R.Reply>}:
  +pd = whole_placed(c)(wd)
  +rk = route_whole(n, c, parts_of(n, rest))(wd)
  %rk : {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{c, rest}, seqD(H)))) == S.merge.fin(S.merge.go(rtfst(_) <> routes_of(n, rest), (acc, st))) : List<&2, R.Reply>}
  %Equal.trans(S.Store(), Laws.answers(S.push_at(home(n, c), S.Part{c, hint(c)}, parts_of(n, rest)), seqT(n, H)), Laws.answers(rtsnd(S.route(n, c, parts_of(n, rest))), seqT(n, H)), st, Equal.cong(S.Route & List<&2, List<&2, S.Part>>, S.Store(), z => Laws.answers(rtsnd(z), seqT(n, H)), (S.ROne{home(n, c)}, S.push_at(home(n, c), S.Part{c, hint(c)}, parts_of(n, rest))), S.route(n, c, parts_of(n, rest)), rk), es) : {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{c, rest}, seqD(H)))) == S.merge.fin(S.merge.go(routes_of(n, rest), S.merge.put(acc, S.pop(home(n, c), _)))) : List<&2, R.Reply>}
  %pop_piece(n, c, parts_of(n, rest), H)(pd)(e2) : {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{c, rest}, seqD(H)))) == S.merge.fin(S.merge.go(routes_of(n, rest), S.merge.put(acc, _))) : List<&2, R.Reply>}
  %eta_l(run(rest, R.db_of(R.exec(c, seqD(H))))) : {List.reverse.go(&2, R.Reply, acc, rfst(R.exec_all.cons(R.reply_of(R.exec(c, seqD(H))), _))) == S.merge.fin(S.merge.go(routes_of(n, rest), (R.reply_of(R.exec(c, seqD(H))) <> acc, Laws.answers(parts_of(n, rest), seqT(n, Con{c, H}))))) : List<&2, R.Reply>}
  ih(Con{c, H}, R.reply_of(R.exec(c, seqD(H))) <> acc, Laws.answers(parts_of(n, rest), seqT(n, Con{c, H})))(and_true(pc(c), pcs(H))(placed_pc(c)(pd))(e2))({==})

def rep_mget(+n: U32, +ks: List<&2, String>, +rest: List<&2, R.Cmd>, +H: List<&2, R.Cmd>, +acc: List<&2, R.Reply>, +st: S.Store(), +e2: {pcs(H) == True{} : Bool}, es: {Laws.answers(rtsnd(S.route(n, R.MGet{ks}, parts_of(n, rest))), seqT(n, H)) == st : S.Store()}, ih: @H2: List<&2, R.Cmd> -> @acc2: List<&2, R.Reply> -> @st2: S.Store() -> {pcs(H2) == True{} : Bool} -> {Laws.answers(parts_of(n, rest), seqT(n, H2)) == st2 : S.Store()} -> {List.reverse.go(&2, R.Reply, acc2, rfst(run(rest, seqD(H2)))) == S.merge.fin(S.merge.go(routes_of(n, rest), (acc2, st2))) : List<&2, R.Reply>})
  -> {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.MGet{ks}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(rtfst(S.route(n, R.MGet{ks}, parts_of(n, rest))) <> routes_of(n, rest), (acc, st))) : List<&2, R.Reply>}:
  +ee = each_eq(n, S.EGet{}, ks, parts_of(n, rest))
  %ee : {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.MGet{ks}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(rtfst(S.as_items(_)) <> routes_of(n, rest), (acc, st))) : List<&2, R.Reply>}
  %Equal.trans(S.Store(), Laws.answers(push_pieces(n, each_cmds(S.EGet{}, ks), parts_of(n, rest)), seqT(n, H)), Laws.answers(rtsnd(S.route(n, R.MGet{ks}, parts_of(n, rest))), seqT(n, H)), st, Equal.cong(List<&2, Nat> & List<&2, List<&2, S.Part>>, S.Store(), z => Laws.answers(rtsnd(S.as_items(z)), seqT(n, H)), (shards_of(n, each_cmds(S.EGet{}, ks)), push_pieces(n, each_cmds(S.EGet{}, ks), parts_of(n, rest))), S.each(n, S.EGet{}, ks, parts_of(n, rest)), ee), es) : {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.MGet{ks}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(routes_of(n, rest), S.merge.put(acc, S.items.fin(S.items.go(shards_of(n, each_cmds(S.EGet{}, ks)), (Nil{}, _)))))) : List<&2, R.Reply>}
  %items_pieces(n, each_cmds(S.EGet{}, ks), parts_of(n, rest), H, Nil{})(placeds_each(S.EGet{}, ks))(e2) : {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.MGet{ks}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(routes_of(n, rest), S.merge.put(acc, S.items.fin(_)))) : List<&2, R.Reply>}
  %rev_rev(items_of(rfst(run(each_cmds(S.EGet{}, ks), seqD(H))))) : {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.MGet{ks}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(routes_of(n, rest), (R.RArray{_} <> acc, Laws.answers(parts_of(n, rest), seqT(n, List.reverse.go(&2, R.Cmd, each_cmds(S.EGet{}, ks), H)))))) : List<&2, R.Reply>}
  %mget_items(ks, seqD(H)) : {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.MGet{ks}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(routes_of(n, rest), (R.RArray{_} <> acc, Laws.answers(parts_of(n, rest), seqT(n, List.reverse.go(&2, R.Cmd, each_cmds(S.EGet{}, ks), H)))))) : List<&2, R.Reply>}
  %eta_l(run(rest, seqD(H))) : {List.reverse.go(&2, R.Reply, acc, rfst(R.exec_all.cons(R.RArray{R.mget_keys(ks, seqD(H))}, _))) == S.merge.fin(S.merge.go(routes_of(n, rest), (R.RArray{R.mget_keys(ks, seqD(H))} <> acc, Laws.answers(parts_of(n, rest), seqT(n, List.reverse.go(&2, R.Cmd, each_cmds(S.EGet{}, ks), H)))))) : List<&2, R.Reply>}
  %Equal.trans(KV.Trie<String>, seqD(List.reverse.go(&2, R.Cmd, each_cmds(S.EGet{}, ks), H)), rsnd(run(each_cmds(S.EGet{}, ks), seqD(H))), seqD(H), Equal.sym(KV.Trie<String>, rsnd(run(each_cmds(S.EGet{}, ks), seqD(H))), seqD(List.reverse.go(&2, R.Cmd, each_cmds(S.EGet{}, ks), H)), seqD_rev(each_cmds(S.EGet{}, ks), H)), Equal.sym(KV.Trie<String>, seqD(H), rsnd(run(each_cmds(S.EGet{}, ks), seqD(H))), gets_db(ks, seqD(H)))) : {List.reverse.go(&2, R.Reply, acc, R.RArray{R.mget_keys(ks, seqD(H))} <> rfst(run(rest, _))) == S.merge.fin(S.merge.go(routes_of(n, rest), (R.RArray{R.mget_keys(ks, seqD(H))} <> acc, Laws.answers(parts_of(n, rest), seqT(n, List.reverse.go(&2, R.Cmd, each_cmds(S.EGet{}, ks), H)))))) : List<&2, R.Reply>}
  ih(List.reverse.go(&2, R.Cmd, each_cmds(S.EGet{}, ks), H), R.RArray{R.mget_keys(ks, seqD(H))} <> acc, Laws.answers(parts_of(n, rest), seqT(n, List.reverse.go(&2, R.Cmd, each_cmds(S.EGet{}, ks), H))))(pcs_rev(each_cmds(S.EGet{}, ks), H)(placeds_pcs(each_cmds(S.EGet{}, ks))(placeds_each(S.EGet{}, ks)))(e2))({==})

def rep_del(+n: U32, +ks: List<&2, String>, +rest: List<&2, R.Cmd>, +H: List<&2, R.Cmd>, +acc: List<&2, R.Reply>, +st: S.Store(), +e2: {pcs(H) == True{} : Bool}, es: {Laws.answers(rtsnd(S.route(n, R.Del{ks}, parts_of(n, rest))), seqT(n, H)) == st : S.Store()}, ih: @H2: List<&2, R.Cmd> -> @acc2: List<&2, R.Reply> -> @st2: S.Store() -> {pcs(H2) == True{} : Bool} -> {Laws.answers(parts_of(n, rest), seqT(n, H2)) == st2 : S.Store()} -> {List.reverse.go(&2, R.Reply, acc2, rfst(run(rest, seqD(H2)))) == S.merge.fin(S.merge.go(routes_of(n, rest), (acc2, st2))) : List<&2, R.Reply>})
  -> {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.Del{ks}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(rtfst(S.route(n, R.Del{ks}, parts_of(n, rest))) <> routes_of(n, rest), (acc, st))) : List<&2, R.Reply>}:
  +ee = each_eq(n, S.EDel{}, ks, parts_of(n, rest))
  %ee : {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.Del{ks}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(rtfst(S.as_sum(_)) <> routes_of(n, rest), (acc, st))) : List<&2, R.Reply>}
  %Equal.trans(S.Store(), Laws.answers(push_pieces(n, each_cmds(S.EDel{}, ks), parts_of(n, rest)), seqT(n, H)), Laws.answers(rtsnd(S.route(n, R.Del{ks}, parts_of(n, rest))), seqT(n, H)), st, Equal.cong(List<&2, Nat> & List<&2, List<&2, S.Part>>, S.Store(), z => Laws.answers(rtsnd(S.as_sum(z)), seqT(n, H)), (shards_of(n, each_cmds(S.EDel{}, ks)), push_pieces(n, each_cmds(S.EDel{}, ks), parts_of(n, rest))), S.each(n, S.EDel{}, ks, parts_of(n, rest)), ee), es) : {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.Del{ks}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(routes_of(n, rest), S.merge.put(acc, S.sum.fin(S.sum.go(shards_of(n, each_cmds(S.EDel{}, ks)), (0n, _)))))) : List<&2, R.Reply>}
  %sum_pieces(n, each_cmds(S.EDel{}, ks), parts_of(n, rest), H, 0n)(placeds_each(S.EDel{}, ks))(e2) : {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.Del{ks}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(routes_of(n, rest), S.merge.put(acc, S.sum.fin(_)))) : List<&2, R.Reply>}
  %del_total(ks, seqD(H)) : {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.Del{ks}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(routes_of(n, rest), (R.r_int(_) <> acc, Laws.answers(parts_of(n, rest), seqT(n, List.reverse.go(&2, R.Cmd, each_cmds(S.EDel{}, ks), H)))))) : List<&2, R.Reply>}
  %del_eta(R.del_keys(ks, seqD(H))) : {List.reverse.go(&2, R.Reply, acc, rfst(R.exec_all.cons(R.reply_of(_), run(rest, R.db_of(_))))) == S.merge.fin(S.merge.go(routes_of(n, rest), (R.r_int(dfst(R.del_keys(ks, seqD(H)))) <> acc, Laws.answers(parts_of(n, rest), seqT(n, List.reverse.go(&2, R.Cmd, each_cmds(S.EDel{}, ks), H)))))) : List<&2, R.Reply>}
  %eta_l(run(rest, dsnd(R.del_keys(ks, seqD(H))))) : {List.reverse.go(&2, R.Reply, acc, rfst(R.exec_all.cons(R.r_int(dfst(R.del_keys(ks, seqD(H)))), _))) == S.merge.fin(S.merge.go(routes_of(n, rest), (R.r_int(dfst(R.del_keys(ks, seqD(H)))) <> acc, Laws.answers(parts_of(n, rest), seqT(n, List.reverse.go(&2, R.Cmd, each_cmds(S.EDel{}, ks), H)))))) : List<&2, R.Reply>}
  %Equal.trans(KV.Trie<String>, seqD(List.reverse.go(&2, R.Cmd, each_cmds(S.EDel{}, ks), H)), rsnd(run(each_cmds(S.EDel{}, ks), seqD(H))), dsnd(R.del_keys(ks, seqD(H))), Equal.sym(KV.Trie<String>, rsnd(run(each_cmds(S.EDel{}, ks), seqD(H))), seqD(List.reverse.go(&2, R.Cmd, each_cmds(S.EDel{}, ks), H)), seqD_rev(each_cmds(S.EDel{}, ks), H)), Equal.sym(KV.Trie<String>, dsnd(R.del_keys(ks, seqD(H))), rsnd(run(each_cmds(S.EDel{}, ks), seqD(H))), del_db(ks, seqD(H)))) : {List.reverse.go(&2, R.Reply, acc, R.r_int(dfst(R.del_keys(ks, seqD(H)))) <> rfst(run(rest, _))) == S.merge.fin(S.merge.go(routes_of(n, rest), (R.r_int(dfst(R.del_keys(ks, seqD(H)))) <> acc, Laws.answers(parts_of(n, rest), seqT(n, List.reverse.go(&2, R.Cmd, each_cmds(S.EDel{}, ks), H)))))) : List<&2, R.Reply>}
  ih(List.reverse.go(&2, R.Cmd, each_cmds(S.EDel{}, ks), H), R.r_int(dfst(R.del_keys(ks, seqD(H)))) <> acc, Laws.answers(parts_of(n, rest), seqT(n, List.reverse.go(&2, R.Cmd, each_cmds(S.EDel{}, ks), H))))(pcs_rev(each_cmds(S.EDel{}, ks), H)(placeds_pcs(each_cmds(S.EDel{}, ks))(placeds_each(S.EDel{}, ks)))(e2))({==})

def rep_exists(+n: U32, +ks: List<&2, String>, +rest: List<&2, R.Cmd>, +H: List<&2, R.Cmd>, +acc: List<&2, R.Reply>, +st: S.Store(), +e2: {pcs(H) == True{} : Bool}, es: {Laws.answers(rtsnd(S.route(n, R.Exists{ks}, parts_of(n, rest))), seqT(n, H)) == st : S.Store()}, ih: @H2: List<&2, R.Cmd> -> @acc2: List<&2, R.Reply> -> @st2: S.Store() -> {pcs(H2) == True{} : Bool} -> {Laws.answers(parts_of(n, rest), seqT(n, H2)) == st2 : S.Store()} -> {List.reverse.go(&2, R.Reply, acc2, rfst(run(rest, seqD(H2)))) == S.merge.fin(S.merge.go(routes_of(n, rest), (acc2, st2))) : List<&2, R.Reply>})
  -> {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.Exists{ks}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(rtfst(S.route(n, R.Exists{ks}, parts_of(n, rest))) <> routes_of(n, rest), (acc, st))) : List<&2, R.Reply>}:
  +ee = each_eq(n, S.EExists{}, ks, parts_of(n, rest))
  %ee : {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.Exists{ks}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(rtfst(S.as_sum(_)) <> routes_of(n, rest), (acc, st))) : List<&2, R.Reply>}
  %Equal.trans(S.Store(), Laws.answers(push_pieces(n, each_cmds(S.EExists{}, ks), parts_of(n, rest)), seqT(n, H)), Laws.answers(rtsnd(S.route(n, R.Exists{ks}, parts_of(n, rest))), seqT(n, H)), st, Equal.cong(List<&2, Nat> & List<&2, List<&2, S.Part>>, S.Store(), z => Laws.answers(rtsnd(S.as_sum(z)), seqT(n, H)), (shards_of(n, each_cmds(S.EExists{}, ks)), push_pieces(n, each_cmds(S.EExists{}, ks), parts_of(n, rest))), S.each(n, S.EExists{}, ks, parts_of(n, rest)), ee), es) : {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.Exists{ks}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(routes_of(n, rest), S.merge.put(acc, S.sum.fin(S.sum.go(shards_of(n, each_cmds(S.EExists{}, ks)), (0n, _)))))) : List<&2, R.Reply>}
  %sum_pieces(n, each_cmds(S.EExists{}, ks), parts_of(n, rest), H, 0n)(placeds_each(S.EExists{}, ks))(e2) : {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.Exists{ks}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(routes_of(n, rest), S.merge.put(acc, S.sum.fin(_)))) : List<&2, R.Reply>}
  %exists_total(ks, seqD(H)) : {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.Exists{ks}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(routes_of(n, rest), (R.r_int(_) <> acc, Laws.answers(parts_of(n, rest), seqT(n, List.reverse.go(&2, R.Cmd, each_cmds(S.EExists{}, ks), H)))))) : List<&2, R.Reply>}
  %eta_l(run(rest, seqD(H))) : {List.reverse.go(&2, R.Reply, acc, rfst(R.exec_all.cons(R.r_int(R.exists_keys(ks, seqD(H))), _))) == S.merge.fin(S.merge.go(routes_of(n, rest), (R.r_int(R.exists_keys(ks, seqD(H))) <> acc, Laws.answers(parts_of(n, rest), seqT(n, List.reverse.go(&2, R.Cmd, each_cmds(S.EExists{}, ks), H)))))) : List<&2, R.Reply>}
  %Equal.trans(KV.Trie<String>, seqD(List.reverse.go(&2, R.Cmd, each_cmds(S.EExists{}, ks), H)), rsnd(run(each_cmds(S.EExists{}, ks), seqD(H))), seqD(H), Equal.sym(KV.Trie<String>, rsnd(run(each_cmds(S.EExists{}, ks), seqD(H))), seqD(List.reverse.go(&2, R.Cmd, each_cmds(S.EExists{}, ks), H)), seqD_rev(each_cmds(S.EExists{}, ks), H)), Equal.sym(KV.Trie<String>, seqD(H), rsnd(run(each_cmds(S.EExists{}, ks), seqD(H))), exs_db(ks, seqD(H)))) : {List.reverse.go(&2, R.Reply, acc, R.r_int(R.exists_keys(ks, seqD(H))) <> rfst(run(rest, _))) == S.merge.fin(S.merge.go(routes_of(n, rest), (R.r_int(R.exists_keys(ks, seqD(H))) <> acc, Laws.answers(parts_of(n, rest), seqT(n, List.reverse.go(&2, R.Cmd, each_cmds(S.EExists{}, ks), H)))))) : List<&2, R.Reply>}
  ih(List.reverse.go(&2, R.Cmd, each_cmds(S.EExists{}, ks), H), R.r_int(R.exists_keys(ks, seqD(H))) <> acc, Laws.answers(parts_of(n, rest), seqT(n, List.reverse.go(&2, R.Cmd, each_cmds(S.EExists{}, ks), H))))(pcs_rev(each_cmds(S.EExists{}, ks), H)(placeds_pcs(each_cmds(S.EExists{}, ks))(placeds_each(S.EExists{}, ks)))(e2))({==})

def rep_mset(+n: U32, +kvs: List<&2, R.KVPair>, +rest: List<&2, R.Cmd>, +H: List<&2, R.Cmd>, +acc: List<&2, R.Reply>, +st: S.Store(), +e2: {pcs(H) == True{} : Bool}, es: {Laws.answers(rtsnd(S.route(n, R.MSet{kvs}, parts_of(n, rest))), seqT(n, H)) == st : S.Store()}, ih: @H2: List<&2, R.Cmd> -> @acc2: List<&2, R.Reply> -> @st2: S.Store() -> {pcs(H2) == True{} : Bool} -> {Laws.answers(parts_of(n, rest), seqT(n, H2)) == st2 : S.Store()} -> {List.reverse.go(&2, R.Reply, acc2, rfst(run(rest, seqD(H2)))) == S.merge.fin(S.merge.go(routes_of(n, rest), (acc2, st2))) : List<&2, R.Reply>})
  -> {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.MSet{kvs}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(rtfst(S.route(n, R.MSet{kvs}, parts_of(n, rest))) <> routes_of(n, rest), (acc, st))) : List<&2, R.Reply>}:
  +pe = pairs_eq(n, kvs, parts_of(n, rest))
  %pe : {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.MSet{kvs}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(rtfst(S.as_ok(_)) <> routes_of(n, rest), (acc, st))) : List<&2, R.Reply>}
  %Equal.trans(S.Store(), Laws.answers(push_pieces(n, set_cmds(kvs), parts_of(n, rest)), seqT(n, H)), Laws.answers(rtsnd(S.route(n, R.MSet{kvs}, parts_of(n, rest))), seqT(n, H)), st, Equal.cong(List<&2, Nat> & List<&2, List<&2, S.Part>>, S.Store(), z => Laws.answers(rtsnd(S.as_ok(z)), seqT(n, H)), (shards_of(n, set_cmds(kvs)), push_pieces(n, set_cmds(kvs), parts_of(n, rest))), S.pairs(n, kvs, parts_of(n, rest)), pe), es) : {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.MSet{kvs}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(routes_of(n, rest), (R.r_ok() <> acc, S.ok.go(shards_of(n, set_cmds(kvs)), _)))) : List<&2, R.Reply>}
  %ok_pieces(n, set_cmds(kvs), parts_of(n, rest), H)(placeds_sets(kvs)) : {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.MSet{kvs}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(routes_of(n, rest), (R.r_ok() <> acc, _))) : List<&2, R.Reply>}
  %eta_l(run(rest, R.mset_pairs(kvs, seqD(H)))) : {List.reverse.go(&2, R.Reply, acc, rfst(R.exec_all.cons(R.r_ok(), _))) == S.merge.fin(S.merge.go(routes_of(n, rest), (R.r_ok() <> acc, Laws.answers(parts_of(n, rest), seqT(n, List.reverse.go(&2, R.Cmd, set_cmds(kvs), H)))))) : List<&2, R.Reply>}
  %Equal.trans(KV.Trie<String>, seqD(List.reverse.go(&2, R.Cmd, set_cmds(kvs), H)), rsnd(run(set_cmds(kvs), seqD(H))), R.mset_pairs(kvs, seqD(H)), Equal.sym(KV.Trie<String>, rsnd(run(set_cmds(kvs), seqD(H))), seqD(List.reverse.go(&2, R.Cmd, set_cmds(kvs), H)), seqD_rev(set_cmds(kvs), H)), Equal.sym(KV.Trie<String>, R.mset_pairs(kvs, seqD(H)), rsnd(run(set_cmds(kvs), seqD(H))), mset_db(kvs, seqD(H)))) : {List.reverse.go(&2, R.Reply, acc, R.r_ok() <> rfst(run(rest, _))) == S.merge.fin(S.merge.go(routes_of(n, rest), (R.r_ok() <> acc, Laws.answers(parts_of(n, rest), seqT(n, List.reverse.go(&2, R.Cmd, set_cmds(kvs), H)))))) : List<&2, R.Reply>}
  ih(List.reverse.go(&2, R.Cmd, set_cmds(kvs), H), R.r_ok() <> acc, Laws.answers(parts_of(n, rest), seqT(n, List.reverse.go(&2, R.Cmd, set_cmds(kvs), H))))(pcs_rev(set_cmds(kvs), H)(placeds_pcs(set_cmds(kvs))(placeds_sets(kvs)))(e2))({==})

def rep_dbsize(+n: U32, +rest: List<&2, R.Cmd>, +H: List<&2, R.Cmd>, +acc: List<&2, R.Reply>, +st: S.Store(), +e2: {pcs(H) == True{} : Bool}, es: {Laws.answers(rtsnd(S.route(n, R.DbSize{}, parts_of(n, rest))), seqT(n, H)) == st : S.Store()}, ih: @H2: List<&2, R.Cmd> -> @acc2: List<&2, R.Reply> -> @st2: S.Store() -> {pcs(H2) == True{} : Bool} -> {Laws.answers(parts_of(n, rest), seqT(n, H2)) == st2 : S.Store()} -> {List.reverse.go(&2, R.Reply, acc2, rfst(run(rest, seqD(H2)))) == S.merge.fin(S.merge.go(routes_of(n, rest), (acc2, st2))) : List<&2, R.Reply>})
  -> {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.DbSize{}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(rtfst(S.route(n, R.DbSize{}, parts_of(n, rest))) <> routes_of(n, rest), (acc, st))) : List<&2, R.Reply>}:
  +fe = fan_eq(n, S.FSize{}, KV.digits(), parts_of(n, rest))
  %fe : {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.DbSize{}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(rtfst(S.as_sum(_)) <> routes_of(n, rest), (acc, st))) : List<&2, R.Reply>}
  %Equal.trans(S.Store(), Laws.answers(push_pieces(n, fan_cmds(S.FSize{}, KV.digits()), parts_of(n, rest)), seqT(n, H)), Laws.answers(rtsnd(S.route(n, R.DbSize{}, parts_of(n, rest))), seqT(n, H)), st, Equal.cong(List<&2, Nat> & List<&2, List<&2, S.Part>>, S.Store(), z => Laws.answers(rtsnd(S.as_sum(z)), seqT(n, H)), (shards_of(n, fan_cmds(S.FSize{}, KV.digits())), push_pieces(n, fan_cmds(S.FSize{}, KV.digits()), parts_of(n, rest))), S.fan(n, S.FSize{}, KV.digits(), parts_of(n, rest)), fe), es) : {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.DbSize{}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(routes_of(n, rest), S.merge.put(acc, S.sum.fin(S.sum.go(shards_of(n, fan_cmds(S.FSize{}, KV.digits())), (0n, _)))))) : List<&2, R.Reply>}
  %sum_pieces(n, fan_cmds(S.FSize{}, KV.digits()), parts_of(n, rest), H, 0n)(placeds_fan(S.FSize{}, KV.digits()))(e2) : {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.DbSize{}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(routes_of(n, rest), S.merge.put(acc, S.sum.fin(_)))) : List<&2, R.Reply>}
  %size_total(KV.digits(), seqD(H)) : {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.DbSize{}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(routes_of(n, rest), (R.r_int(_) <> acc, Laws.answers(parts_of(n, rest), seqT(n, List.reverse.go(&2, R.Cmd, fan_cmds(S.FSize{}, KV.digits()), H)))))) : List<&2, R.Reply>}
  %eta_l(run(rest, seqD(H))) : {List.reverse.go(&2, R.Reply, acc, rfst(R.exec_all.cons(R.r_int(KV.sizes(String, seqD(H), KV.digits())), _))) == S.merge.fin(S.merge.go(routes_of(n, rest), (R.r_int(KV.sizes(String, seqD(H), KV.digits())) <> acc, Laws.answers(parts_of(n, rest), seqT(n, List.reverse.go(&2, R.Cmd, fan_cmds(S.FSize{}, KV.digits()), H)))))) : List<&2, R.Reply>}
  %Equal.trans(KV.Trie<String>, seqD(List.reverse.go(&2, R.Cmd, fan_cmds(S.FSize{}, KV.digits()), H)), rsnd(run(fan_cmds(S.FSize{}, KV.digits()), seqD(H))), seqD(H), Equal.sym(KV.Trie<String>, rsnd(run(fan_cmds(S.FSize{}, KV.digits()), seqD(H))), seqD(List.reverse.go(&2, R.Cmd, fan_cmds(S.FSize{}, KV.digits()), H)), seqD_rev(fan_cmds(S.FSize{}, KV.digits()), H)), Equal.sym(KV.Trie<String>, seqD(H), rsnd(run(fan_cmds(S.FSize{}, KV.digits()), seqD(H))), size_db(KV.digits(), seqD(H)))) : {List.reverse.go(&2, R.Reply, acc, R.r_int(KV.sizes(String, seqD(H), KV.digits())) <> rfst(run(rest, _))) == S.merge.fin(S.merge.go(routes_of(n, rest), (R.r_int(KV.sizes(String, seqD(H), KV.digits())) <> acc, Laws.answers(parts_of(n, rest), seqT(n, List.reverse.go(&2, R.Cmd, fan_cmds(S.FSize{}, KV.digits()), H)))))) : List<&2, R.Reply>}
  ih(List.reverse.go(&2, R.Cmd, fan_cmds(S.FSize{}, KV.digits()), H), R.r_int(KV.sizes(String, seqD(H), KV.digits())) <> acc, Laws.answers(parts_of(n, rest), seqT(n, List.reverse.go(&2, R.Cmd, fan_cmds(S.FSize{}, KV.digits()), H))))(pcs_rev(fan_cmds(S.FSize{}, KV.digits()), H)(placeds_pcs(fan_cmds(S.FSize{}, KV.digits()))(placeds_fan(S.FSize{}, KV.digits())))(e2))({==})

def rep_keys(+n: U32, +p: String, +rest: List<&2, R.Cmd>, +H: List<&2, R.Cmd>, +acc: List<&2, R.Reply>, +st: S.Store(), +e2: {pcs(H) == True{} : Bool}, es: {Laws.answers(rtsnd(S.route(n, R.Keys{p}, parts_of(n, rest))), seqT(n, H)) == st : S.Store()}, ih: @H2: List<&2, R.Cmd> -> @acc2: List<&2, R.Reply> -> @st2: S.Store() -> {pcs(H2) == True{} : Bool} -> {Laws.answers(parts_of(n, rest), seqT(n, H2)) == st2 : S.Store()} -> {List.reverse.go(&2, R.Reply, acc2, rfst(run(rest, seqD(H2)))) == S.merge.fin(S.merge.go(routes_of(n, rest), (acc2, st2))) : List<&2, R.Reply>})
  -> {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.Keys{p}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(rtfst(S.route(n, R.Keys{p}, parts_of(n, rest))) <> routes_of(n, rest), (acc, st))) : List<&2, R.Reply>}:
  +fe = fan_eq(n, S.FKeys{p}, KV.digits(), parts_of(n, rest))
  %fe : {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.Keys{p}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(rtfst(S.as_cat(_)) <> routes_of(n, rest), (acc, st))) : List<&2, R.Reply>}
  %Equal.trans(S.Store(), Laws.answers(push_pieces(n, fan_cmds(S.FKeys{p}, KV.digits()), parts_of(n, rest)), seqT(n, H)), Laws.answers(rtsnd(S.route(n, R.Keys{p}, parts_of(n, rest))), seqT(n, H)), st, Equal.cong(List<&2, Nat> & List<&2, List<&2, S.Part>>, S.Store(), z => Laws.answers(rtsnd(S.as_cat(z)), seqT(n, H)), (shards_of(n, fan_cmds(S.FKeys{p}, KV.digits())), push_pieces(n, fan_cmds(S.FKeys{p}, KV.digits()), parts_of(n, rest))), S.fan(n, S.FKeys{p}, KV.digits(), parts_of(n, rest)), fe), es) : {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.Keys{p}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(routes_of(n, rest), S.merge.put(acc, S.items.fin(S.cat.go(shards_of(n, fan_cmds(S.FKeys{p}, KV.digits())), (Nil{}, _)))))) : List<&2, R.Reply>}
  %cat_pieces(n, fan_cmds(S.FKeys{p}, KV.digits()), parts_of(n, rest), H, Nil{})(placeds_fan(S.FKeys{p}, KV.digits()))(e2) : {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.Keys{p}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(routes_of(n, rest), S.merge.put(acc, S.items.fin(_)))) : List<&2, R.Reply>}
  %rev_rev(cats(rfst(run(fan_cmds(S.FKeys{p}, KV.digits()), seqD(H))))) : {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.Keys{p}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(routes_of(n, rest), (R.RArray{_} <> acc, Laws.answers(parts_of(n, rest), seqT(n, List.reverse.go(&2, R.Cmd, fan_cmds(S.FKeys{p}, KV.digits()), H)))))) : List<&2, R.Reply>}
  %keys_cats(p, KV.digits(), seqD(H)) : {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.Keys{p}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(routes_of(n, rest), (R.RArray{_} <> acc, Laws.answers(parts_of(n, rest), seqT(n, List.reverse.go(&2, R.Cmd, fan_cmds(S.FKeys{p}, KV.digits()), H)))))) : List<&2, R.Reply>}
  %eta_l(run(rest, seqD(H))) : {List.reverse.go(&2, R.Reply, acc, rfst(R.exec_all.cons(R.RArray{R.glob_filter(p, KV.keys.of(String, seqD(H), KV.digits()))}, _))) == S.merge.fin(S.merge.go(routes_of(n, rest), (R.RArray{R.glob_filter(p, KV.keys.of(String, seqD(H), KV.digits()))} <> acc, Laws.answers(parts_of(n, rest), seqT(n, List.reverse.go(&2, R.Cmd, fan_cmds(S.FKeys{p}, KV.digits()), H)))))) : List<&2, R.Reply>}
  %Equal.trans(KV.Trie<String>, seqD(List.reverse.go(&2, R.Cmd, fan_cmds(S.FKeys{p}, KV.digits()), H)), rsnd(run(fan_cmds(S.FKeys{p}, KV.digits()), seqD(H))), seqD(H), Equal.sym(KV.Trie<String>, rsnd(run(fan_cmds(S.FKeys{p}, KV.digits()), seqD(H))), seqD(List.reverse.go(&2, R.Cmd, fan_cmds(S.FKeys{p}, KV.digits()), H)), seqD_rev(fan_cmds(S.FKeys{p}, KV.digits()), H)), Equal.sym(KV.Trie<String>, seqD(H), rsnd(run(fan_cmds(S.FKeys{p}, KV.digits()), seqD(H))), keys_db(p, KV.digits(), seqD(H)))) : {List.reverse.go(&2, R.Reply, acc, R.RArray{R.glob_filter(p, KV.keys.of(String, seqD(H), KV.digits()))} <> rfst(run(rest, _))) == S.merge.fin(S.merge.go(routes_of(n, rest), (R.RArray{R.glob_filter(p, KV.keys.of(String, seqD(H), KV.digits()))} <> acc, Laws.answers(parts_of(n, rest), seqT(n, List.reverse.go(&2, R.Cmd, fan_cmds(S.FKeys{p}, KV.digits()), H)))))) : List<&2, R.Reply>}
  ih(List.reverse.go(&2, R.Cmd, fan_cmds(S.FKeys{p}, KV.digits()), H), R.RArray{R.glob_filter(p, KV.keys.of(String, seqD(H), KV.digits()))} <> acc, Laws.answers(parts_of(n, rest), seqT(n, List.reverse.go(&2, R.Cmd, fan_cmds(S.FKeys{p}, KV.digits()), H))))(pcs_rev(fan_cmds(S.FKeys{p}, KV.digits()), H)(placeds_pcs(fan_cmds(S.FKeys{p}, KV.digits()))(placeds_fan(S.FKeys{p}, KV.digits())))(e2))({==})

def rep_flushall(+n: U32, +rest: List<&2, R.Cmd>, +H: List<&2, R.Cmd>, +acc: List<&2, R.Reply>, +st: S.Store(), +e2: {pcs(H) == True{} : Bool}, es: {Laws.answers(rtsnd(S.route(n, R.FlushAll{}, parts_of(n, rest))), seqT(n, H)) == st : S.Store()}, ih: @H2: List<&2, R.Cmd> -> @acc2: List<&2, R.Reply> -> @st2: S.Store() -> {pcs(H2) == True{} : Bool} -> {Laws.answers(parts_of(n, rest), seqT(n, H2)) == st2 : S.Store()} -> {List.reverse.go(&2, R.Reply, acc2, rfst(run(rest, seqD(H2)))) == S.merge.fin(S.merge.go(routes_of(n, rest), (acc2, st2))) : List<&2, R.Reply>})
  -> {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.FlushAll{}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(rtfst(S.route(n, R.FlushAll{}, parts_of(n, rest))) <> routes_of(n, rest), (acc, st))) : List<&2, R.Reply>}:
  +fe = fan_eq(n, S.FFlush{}, KV.digits(), parts_of(n, rest))
  %fe : {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.FlushAll{}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(rtfst(S.as_ok(_)) <> routes_of(n, rest), (acc, st))) : List<&2, R.Reply>}
  %Equal.trans(S.Store(), Laws.answers(push_pieces(n, fan_cmds(S.FFlush{}, KV.digits()), parts_of(n, rest)), seqT(n, H)), Laws.answers(rtsnd(S.route(n, R.FlushAll{}, parts_of(n, rest))), seqT(n, H)), st, Equal.cong(List<&2, Nat> & List<&2, List<&2, S.Part>>, S.Store(), z => Laws.answers(rtsnd(S.as_ok(z)), seqT(n, H)), (shards_of(n, fan_cmds(S.FFlush{}, KV.digits())), push_pieces(n, fan_cmds(S.FFlush{}, KV.digits()), parts_of(n, rest))), S.fan(n, S.FFlush{}, KV.digits(), parts_of(n, rest)), fe), es) : {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.FlushAll{}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(routes_of(n, rest), (R.r_ok() <> acc, S.ok.go(shards_of(n, fan_cmds(S.FFlush{}, KV.digits())), _)))) : List<&2, R.Reply>}
  %ok_pieces(n, fan_cmds(S.FFlush{}, KV.digits()), parts_of(n, rest), H)(placeds_fan(S.FFlush{}, KV.digits())) : {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{R.FlushAll{}, rest}, seqD(H)))) == S.merge.fin(S.merge.go(routes_of(n, rest), (R.r_ok() <> acc, _))) : List<&2, R.Reply>}
  %eta_l(run(rest, KV.clear(String, seqD(H)))) : {List.reverse.go(&2, R.Reply, acc, rfst(R.exec_all.cons(R.r_ok(), _))) == S.merge.fin(S.merge.go(routes_of(n, rest), (R.r_ok() <> acc, Laws.answers(parts_of(n, rest), seqT(n, List.reverse.go(&2, R.Cmd, fan_cmds(S.FFlush{}, KV.digits()), H)))))) : List<&2, R.Reply>}
  %Equal.trans(KV.Trie<String>, seqD(List.reverse.go(&2, R.Cmd, fan_cmds(S.FFlush{}, KV.digits()), H)), rsnd(run(fan_cmds(S.FFlush{}, KV.digits()), seqD(H))), KV.clear(String, seqD(H)), Equal.sym(KV.Trie<String>, rsnd(run(fan_cmds(S.FFlush{}, KV.digits()), seqD(H))), seqD(List.reverse.go(&2, R.Cmd, fan_cmds(S.FFlush{}, KV.digits()), H)), seqD_rev(fan_cmds(S.FFlush{}, KV.digits()), H)), Equal.sym(KV.Trie<String>, KV.clear.of(String, KV.digits(), seqD(H)), rsnd(run(fan_cmds(S.FFlush{}, KV.digits()), seqD(H))), flush_db(KV.digits(), seqD(H)))) : {List.reverse.go(&2, R.Reply, acc, R.r_ok() <> rfst(run(rest, _))) == S.merge.fin(S.merge.go(routes_of(n, rest), (R.r_ok() <> acc, Laws.answers(parts_of(n, rest), seqT(n, List.reverse.go(&2, R.Cmd, fan_cmds(S.FFlush{}, KV.digits()), H)))))) : List<&2, R.Reply>}
  ih(List.reverse.go(&2, R.Cmd, fan_cmds(S.FFlush{}, KV.digits()), H), R.r_ok() <> acc, Laws.answers(parts_of(n, rest), seqT(n, List.reverse.go(&2, R.Cmd, fan_cmds(S.FFlush{}, KV.digits()), H))))(pcs_rev(fan_cmds(S.FFlush{}, KV.digits()), H)(placeds_pcs(fan_cmds(S.FFlush{}, KV.digits()))(placeds_fan(S.FFlush{}, KV.digits())))(e2))({==})

def rep_cmd(+n: U32, c: R.Cmd, +rest: List<&2, R.Cmd>, +H: List<&2, R.Cmd>, +acc: List<&2, R.Reply>, +st: S.Store()) -> {pcs(H) == True{} : Bool} -> {Laws.answers(parts_of(n, Con{c, rest}), seqT(n, H)) == st : S.Store()} -> (@H2: List<&2, R.Cmd> -> @acc2: List<&2, R.Reply> -> @st2: S.Store() -> {pcs(H2) == True{} : Bool} -> {Laws.answers(parts_of(n, rest), seqT(n, H2)) == st2 : S.Store()} -> {List.reverse.go(&2, R.Reply, acc2, rfst(run(rest, seqD(H2)))) == S.merge.fin(S.merge.go(routes_of(n, rest), (acc2, st2))) : List<&2, R.Reply>}) -> {List.reverse.go(&2, R.Reply, acc, rfst(run(Con{c, rest}, seqD(H)))) == S.merge.fin(S.merge.go(routes_of(n, Con{c, rest}), (acc, st))) : List<&2, R.Reply>}:
  match c:
    case R.Ping{}:
      e2 => es => ih => %eta_l(run(rest, seqD(H))) : {List.reverse.go(&2, R.Reply, acc, rfst(R.exec_all.cons(R.RStatus{"PONG"}, _))) == S.merge.fin(S.merge.go(routes_of(n, rest), (Con{R.RStatus{"PONG"}, acc}, st))) : List<&2, R.Reply>}
                        ih(Con{R.Ping{}, H}, Con{R.RStatus{"PONG"}, acc}, st)(e2)(es)
    case R.Echo{+m}:
      e2 => es => ih => %eta_l(run(rest, seqD(H))) : {List.reverse.go(&2, R.Reply, acc, rfst(R.exec_all.cons(R.RBulk{m}, _))) == S.merge.fin(S.merge.go(routes_of(n, rest), (Con{R.RBulk{m}, acc}, st))) : List<&2, R.Reply>}
                        ih(Con{R.Echo{m}, H}, Con{R.RBulk{m}, acc}, st)(e2)(es)
    case R.Get{k}:
      e2 => es => ih => rep_whole(n, R.Get{k}, rest, H, acc, st, {==}, e2, es, ih)
    case R.Set{k, v}:
      e2 => es => ih => rep_whole(n, R.Set{k, v}, rest, H, acc, st, {==}, e2, es, ih)
    case R.SetNX{k, v}:
      e2 => es => ih => rep_whole(n, R.SetNX{k, v}, rest, H, acc, st, {==}, e2, es, ih)
    case R.GetSet{k, v}:
      e2 => es => ih => rep_whole(n, R.GetSet{k, v}, rest, H, acc, st, {==}, e2, es, ih)
    case R.Del{ks}:
      e2 => es => ih => rep_del(n, ks, rest, H, acc, st, e2, es, ih)
    case R.Exists{ks}:
      e2 => es => ih => rep_exists(n, ks, rest, H, acc, st, e2, es, ih)
    case R.IncrBy{k, by}:
      e2 => es => ih => rep_whole(n, R.IncrBy{k, by}, rest, H, acc, st, {==}, e2, es, ih)
    case R.Append{k, v}:
      e2 => es => ih => rep_whole(n, R.Append{k, v}, rest, H, acc, st, {==}, e2, es, ih)
    case R.Strlen{k}:
      e2 => es => ih => rep_whole(n, R.Strlen{k}, rest, H, acc, st, {==}, e2, es, ih)
    case R.MGet{ks}:
      e2 => es => ih => rep_mget(n, ks, rest, H, acc, st, e2, es, ih)
    case R.MSet{ps}:
      e2 => es => ih => rep_mset(n, ps, rest, H, acc, st, e2, es, ih)
    case R.DbSize{}:
      e2 => es => ih => rep_dbsize(n, rest, H, acc, st, e2, es, ih)
    case R.FlushAll{}:
      e2 => es => ih => rep_flushall(n, rest, H, acc, st, e2, es, ih)
    case R.Keys{p}:
      e2 => es => ih => rep_keys(n, p, rest, H, acc, st, e2, es, ih)
    case R.Bad{+r}:
      e2 => es => ih => %eta_l(run(rest, seqD(H))) : {List.reverse.go(&2, R.Reply, acc, rfst(R.exec_all.cons(r, _))) == S.merge.fin(S.merge.go(routes_of(n, rest), (Con{r, acc}, st))) : List<&2, R.Reply>}
                        ih(Con{R.Bad{r}, H}, Con{r, acc}, st)(e2)(es)
    case R.SizeAt{x}:
      e2 => es => ih => rep_whole(n, R.SizeAt{x}, rest, H, acc, st, {==}, e2, es, ih)
    case R.KeysAt{p, x}:
      e2 => es => ih => rep_whole(n, R.KeysAt{p, x}, rest, H, acc, st, {==}, e2, es, ih)
    case R.FlushAt{x}:
      e2 => es => ih => rep_whole(n, R.FlushAt{x}, rest, H, acc, st, {==}, e2, es, ih)

def rep_go(+n: U32, cs: List<&2, R.Cmd>, +H: List<&2, R.Cmd>, +acc: List<&2, R.Reply>, +st: S.Store())
  -> {pcs(H) == True{} : Bool}
  -> {Laws.answers(parts_of(n, cs), seqT(n, H)) == st : S.Store()}
  -> {List.reverse.go(&2, R.Reply, acc, rfst(run(cs, seqD(H)))) == S.merge.fin(S.merge.go(routes_of(n, cs), (acc, st))) : List<&2, R.Reply>}:
  match cs:
    case Nil{}:
      e2 => es => {==}
    case Con{c, +rest}:
      e2 => es => rep_cmd(n, c, rest, H, acc, st)(e2)(es)(H2 => acc2 => st2 => rep_go(n, rest, H2, acc2, st2))

# The shards after a batch
# ------------------------
# The shards' tries after a batch run after H are those of the run of the
# batch's pieces after H.

def tries_whole(+n: U32, +c: R.Cmd, +rest: List<&2, R.Cmd>, +H: List<&2, R.Cmd>, +wd: {whole(c) == True{} : Bool}, ih: @H2: List<&2, R.Cmd> -> {seqT(n, unfold(rest, H2)) == Laws.after(parts_of(n, rest), seqT(n, H2)) : List<&2, KV.Trie<String>>})
  -> {seqT(n, unfold(rest, Con{c, H})) == Laws.after(rtsnd(S.route(n, c, parts_of(n, rest))), seqT(n, H)) : List<&2, KV.Trie<String>>}:
  %route_whole(n, c, parts_of(n, rest))(wd) : {seqT(n, unfold(rest, Con{c, H})) == Laws.after(rtsnd(_), seqT(n, H)) : List<&2, KV.Trie<String>>}
  %after_push(home(n, c), c, hint(c), parts_of(n, rest), seqT(n, H)) : {seqT(n, unfold(rest, Con{c, H})) == _ : List<&2, KV.Trie<String>>}
  %step_placed(n, c, seqT(n, H))(whole_placed(c)(wd)) : {seqT(n, unfold(rest, Con{c, H})) == Laws.after(parts_of(n, rest), _) : List<&2, KV.Trie<String>>}
  ih(Con{c, H})

def tries_cmd(+n: U32, c: R.Cmd, +rest: List<&2, R.Cmd>, +H: List<&2, R.Cmd>) -> (@H2: List<&2, R.Cmd> -> {seqT(n, unfold(rest, H2)) == Laws.after(parts_of(n, rest), seqT(n, H2)) : List<&2, KV.Trie<String>>}) -> {seqT(n, unfold(Con{c, rest}, H)) == Laws.after(parts_of(n, Con{c, rest}), seqT(n, H)) : List<&2, KV.Trie<String>>}:
  match c:
    case R.Ping{}:
      ih => ih(Con{R.Ping{}, H})
    case R.Echo{+m}:
      ih => ih(Con{R.Echo{m}, H})
    case R.Get{k}:
      ih => tries_whole(n, R.Get{k}, rest, H, {==}, ih)
    case R.Set{k, v}:
      ih => tries_whole(n, R.Set{k, v}, rest, H, {==}, ih)
    case R.SetNX{k, v}:
      ih => tries_whole(n, R.SetNX{k, v}, rest, H, {==}, ih)
    case R.GetSet{k, v}:
      ih => tries_whole(n, R.GetSet{k, v}, rest, H, {==}, ih)
    case R.Del{+ks}:
      ih => %each_eq(n, S.EDel{}, ks, parts_of(n, rest)) : {seqT(n, unfold(rest, List.reverse.go(&2, R.Cmd, each_cmds(S.EDel{}, ks), H))) == Laws.after(rtsnd(S.as_sum(_)), seqT(n, H)) : List<&2, KV.Trie<String>>}
            %after_pieces(n, each_cmds(S.EDel{}, ks), parts_of(n, rest), H)(placeds_each(S.EDel{}, ks)) : {seqT(n, unfold(rest, List.reverse.go(&2, R.Cmd, each_cmds(S.EDel{}, ks), H))) == _ : List<&2, KV.Trie<String>>}
            ih(List.reverse.go(&2, R.Cmd, each_cmds(S.EDel{}, ks), H))
    case R.Exists{+ks}:
      ih => %each_eq(n, S.EExists{}, ks, parts_of(n, rest)) : {seqT(n, unfold(rest, List.reverse.go(&2, R.Cmd, each_cmds(S.EExists{}, ks), H))) == Laws.after(rtsnd(S.as_sum(_)), seqT(n, H)) : List<&2, KV.Trie<String>>}
            %after_pieces(n, each_cmds(S.EExists{}, ks), parts_of(n, rest), H)(placeds_each(S.EExists{}, ks)) : {seqT(n, unfold(rest, List.reverse.go(&2, R.Cmd, each_cmds(S.EExists{}, ks), H))) == _ : List<&2, KV.Trie<String>>}
            ih(List.reverse.go(&2, R.Cmd, each_cmds(S.EExists{}, ks), H))
    case R.IncrBy{k, by}:
      ih => tries_whole(n, R.IncrBy{k, by}, rest, H, {==}, ih)
    case R.Append{k, v}:
      ih => tries_whole(n, R.Append{k, v}, rest, H, {==}, ih)
    case R.Strlen{k}:
      ih => tries_whole(n, R.Strlen{k}, rest, H, {==}, ih)
    case R.MGet{+ks}:
      ih => %each_eq(n, S.EGet{}, ks, parts_of(n, rest)) : {seqT(n, unfold(rest, List.reverse.go(&2, R.Cmd, each_cmds(S.EGet{}, ks), H))) == Laws.after(rtsnd(S.as_items(_)), seqT(n, H)) : List<&2, KV.Trie<String>>}
            %after_pieces(n, each_cmds(S.EGet{}, ks), parts_of(n, rest), H)(placeds_each(S.EGet{}, ks)) : {seqT(n, unfold(rest, List.reverse.go(&2, R.Cmd, each_cmds(S.EGet{}, ks), H))) == _ : List<&2, KV.Trie<String>>}
            ih(List.reverse.go(&2, R.Cmd, each_cmds(S.EGet{}, ks), H))
    case R.MSet{+ps}:
      ih => %pairs_eq(n, ps, parts_of(n, rest)) : {seqT(n, unfold(rest, List.reverse.go(&2, R.Cmd, set_cmds(ps), H))) == Laws.after(rtsnd(S.as_ok(_)), seqT(n, H)) : List<&2, KV.Trie<String>>}
            %after_pieces(n, set_cmds(ps), parts_of(n, rest), H)(placeds_sets(ps)) : {seqT(n, unfold(rest, List.reverse.go(&2, R.Cmd, set_cmds(ps), H))) == _ : List<&2, KV.Trie<String>>}
            ih(List.reverse.go(&2, R.Cmd, set_cmds(ps), H))
    case R.DbSize{}:
      ih => %fan_eq(n, S.FSize{}, KV.digits(), parts_of(n, rest)) : {seqT(n, unfold(rest, List.reverse.go(&2, R.Cmd, fan_cmds(S.FSize{}, KV.digits()), H))) == Laws.after(rtsnd(S.as_sum(_)), seqT(n, H)) : List<&2, KV.Trie<String>>}
            %after_pieces(n, fan_cmds(S.FSize{}, KV.digits()), parts_of(n, rest), H)(placeds_fan(S.FSize{}, KV.digits())) : {seqT(n, unfold(rest, List.reverse.go(&2, R.Cmd, fan_cmds(S.FSize{}, KV.digits()), H))) == _ : List<&2, KV.Trie<String>>}
            ih(List.reverse.go(&2, R.Cmd, fan_cmds(S.FSize{}, KV.digits()), H))
    case R.FlushAll{}:
      ih => %fan_eq(n, S.FFlush{}, KV.digits(), parts_of(n, rest)) : {seqT(n, unfold(rest, List.reverse.go(&2, R.Cmd, fan_cmds(S.FFlush{}, KV.digits()), H))) == Laws.after(rtsnd(S.as_ok(_)), seqT(n, H)) : List<&2, KV.Trie<String>>}
            %after_pieces(n, fan_cmds(S.FFlush{}, KV.digits()), parts_of(n, rest), H)(placeds_fan(S.FFlush{}, KV.digits())) : {seqT(n, unfold(rest, List.reverse.go(&2, R.Cmd, fan_cmds(S.FFlush{}, KV.digits()), H))) == _ : List<&2, KV.Trie<String>>}
            ih(List.reverse.go(&2, R.Cmd, fan_cmds(S.FFlush{}, KV.digits()), H))
    case R.Keys{+p}:
      ih => %fan_eq(n, S.FKeys{p}, KV.digits(), parts_of(n, rest)) : {seqT(n, unfold(rest, List.reverse.go(&2, R.Cmd, fan_cmds(S.FKeys{p}, KV.digits()), H))) == Laws.after(rtsnd(S.as_cat(_)), seqT(n, H)) : List<&2, KV.Trie<String>>}
            %after_pieces(n, fan_cmds(S.FKeys{p}, KV.digits()), parts_of(n, rest), H)(placeds_fan(S.FKeys{p}, KV.digits())) : {seqT(n, unfold(rest, List.reverse.go(&2, R.Cmd, fan_cmds(S.FKeys{p}, KV.digits()), H))) == _ : List<&2, KV.Trie<String>>}
            ih(List.reverse.go(&2, R.Cmd, fan_cmds(S.FKeys{p}, KV.digits()), H))
    case R.Bad{+r}:
      ih => ih(Con{R.Bad{r}, H})
    case R.SizeAt{x}:
      ih => tries_whole(n, R.SizeAt{x}, rest, H, {==}, ih)
    case R.KeysAt{p, x}:
      ih => tries_whole(n, R.KeysAt{p, x}, rest, H, {==}, ih)
    case R.FlushAt{x}:
      ih => tries_whole(n, R.FlushAt{x}, rest, H, {==}, ih)

def tries_go(+n: U32, cs: List<&2, R.Cmd>, +H: List<&2, R.Cmd>) -> {seqT(n, unfold(cs, H)) == Laws.after(parts_of(n, cs), seqT(n, H)) : List<&2, KV.Trie<String>>}:
  match cs:
    case Nil{}:
      {==}
    case Con{c, +rest}:
      tries_cmd(n, c, rest, H)(H2 => tries_go(n, rest, H2))

# the database after a batch run after H is that of the run
def db_go(cs: List<&2, R.Cmd>, +H: List<&2, R.Cmd>) -> {seqD(unfold(cs, H)) == Laws.final(R.exec_all(cs, seqD(H))) : KV.Trie<String>}:
  match cs:
    case Nil{}:
      {==}
    case Con{+c, +rest}:
      Equal.trans(KV.Trie<String>, seqD(unfold(rest, List.reverse.go(&2, R.Cmd, pieces(c), H))), Laws.final(R.exec_all(rest, seqD(List.reverse.go(&2, R.Cmd, pieces(c), H)))), Laws.final(R.exec_all(Con{c, rest}, seqD(H))),
        db_go(rest, List.reverse.go(&2, R.Cmd, pieces(c), H)),
        Equal.trans(KV.Trie<String>, Laws.final(R.exec_all(rest, seqD(List.reverse.go(&2, R.Cmd, pieces(c), H)))), Laws.final(R.exec_all(rest, R.db_of(R.exec(c, seqD(H))))), Laws.final(R.exec_all(Con{c, rest}, seqD(H))),
          Equal.cong(KV.Trie<String>, KV.Trie<String>, d => Laws.final(R.exec_all(rest, d)), seqD(List.reverse.go(&2, R.Cmd, pieces(c), H)), R.db_of(R.exec(c, seqD(H))), Equal.sym(KV.Trie<String>, R.db_of(R.exec(c, seqD(H))), seqD(List.reverse.go(&2, R.Cmd, pieces(c), H)), pieces_db(c, H))),
          fin_cons(c, rest, seqD(H))))

# Histories
# ---------
# A history, newest batch first, is the run of its batches' pieces.

def flat(hist: List<&2, List<&2, R.Cmd>>) -> List<&2, R.Cmd>:
  match hist:
    case Nil{}:
      Nil{}
    case Con{cs, older}:
      unfold(cs, flat(older))

def pcs_unfold(cs: List<&2, R.Cmd>, +H: List<&2, R.Cmd>) -> {pcs(H) == True{} : Bool} -> {pcs(unfold(cs, H)) == True{} : Bool}:
  match cs:
    case Nil{}:
      e => e
    case Con{+c, +rest}:
      e => pcs_unfold(rest, List.reverse.go(&2, R.Cmd, pieces(c), H))(pcs_rev(pieces(c), H)(pcs_pieces(c))(e))

def pcs_flat(hist: List<&2, List<&2, R.Cmd>>) -> {pcs(flat(hist)) == True{} : Bool}:
  match hist:
    case Nil{}:
      {==}
    case Con{+cs, +older}:
      pcs_unfold(cs, flat(older))(pcs_flat(older))

def single_eq(hist: List<&2, List<&2, R.Cmd>>) -> {seqD(flat(hist)) == Laws.single(hist) : KV.Trie<String>}:
  match hist:
    case Nil{}:
      {==}
    case Con{+cs, +older}:
      Equal.trans(KV.Trie<String>, seqD(unfold(cs, flat(older))), Laws.final(R.exec_all(cs, seqD(flat(older)))), Laws.final(R.exec_all(cs, Laws.single(older))), db_go(cs, flat(older)), Equal.cong(KV.Trie<String>, KV.Trie<String>, d => Laws.final(R.exec_all(cs, d)), seqD(flat(older)), Laws.single(older), single_eq(older)))

def shards_eq(+n: U32, hist: List<&2, List<&2, R.Cmd>>) -> {seqT(n, flat(hist)) == Laws.shards(n, hist) : List<&2, KV.Trie<String>>}:
  match hist:
    case Nil{}:
      {==}
    case Con{+cs, +older}:
      Equal.trans(List<&2, KV.Trie<String>>, seqT(n, unfold(cs, flat(older))), Laws.after(parts_of(n, cs), seqT(n, flat(older))), Laws.sh_tries(Laws.sharded.go(Laws.shards(n, older), S.split(n, cs))),
        tries_go(n, cs, flat(older)),
        Equal.trans(List<&2, KV.Trie<String>>, Laws.after(parts_of(n, cs), seqT(n, flat(older))), Laws.after(parts_of(n, cs), Laws.shards(n, older)), Laws.sh_tries(Laws.sharded.go(Laws.shards(n, older), S.split(n, cs))),
          Equal.cong(List<&2, KV.Trie<String>>, List<&2, KV.Trie<String>>, z => Laws.after(parts_of(n, cs), z), seqT(n, flat(older)), Laws.shards(n, older), shards_eq(n, older)),
          Equal.cong(List<&2, S.Route> & List<&2, List<&2, S.Part>>, List<&2, KV.Trie<String>>, z => Laws.sh_tries(Laws.sharded.go(Laws.shards(n, older), z)), (routes_of(n, cs), parts_of(n, cs)), S.split(n, cs), split_eq(n, cs))))

# The laws
# --------

def holds_hist(+n: U32, +hist: List<&2, List<&2, R.Cmd>>, +k: String) -> {KV.get(String, Laws.at(Laws.shards(n, hist), Laws.shard(n, k)), k) == KV.get(String, Laws.single(hist), k) : Maybe<&2, String>}:
  %shards_eq(n, hist) : {KV.get(String, Laws.at(_, Laws.shard(n, k)), k) == KV.get(String, Laws.single(hist), k) : Maybe<&2, String>}
  %single_eq(hist) : {KV.get(String, Laws.at(seqT(n, flat(hist)), Laws.shard(n, k)), k) == KV.get(String, _, k) : Maybe<&2, String>}
  holds_seq(n, flat(hist), k)(pcs_flat(hist))

def Laws.shard_holds(n, hist, k):
  holds_hist(n, hist, k)

def replies_hist(+n: U32, +hist: List<&2, List<&2, R.Cmd>>, +cs: List<&2, R.Cmd>) -> {Laws.sh_replies(Laws.sharded(n, cs, Laws.shards(n, hist))) == Laws.replies(R.exec_all(cs, Laws.single(hist))) : List<&2, R.Reply>}:
  %shards_eq(n, hist) : {Laws.sh_replies(Laws.sharded(n, cs, _)) == Laws.replies(R.exec_all(cs, Laws.single(hist))) : List<&2, R.Reply>}
  %single_eq(hist) : {Laws.sh_replies(Laws.sharded(n, cs, seqT(n, flat(hist)))) == Laws.replies(R.exec_all(cs, _)) : List<&2, R.Reply>}
  %split_eq(n, cs) : {Laws.sh_replies(Laws.sharded.go(seqT(n, flat(hist)), _)) == Laws.replies(R.exec_all(cs, seqD(flat(hist)))) : List<&2, R.Reply>}
  %exec_all_run(cs, seqD(flat(hist))) : {S.merge(routes_of(n, cs), Laws.answers(parts_of(n, cs), seqT(n, flat(hist)))) == Laws.replies(_) : List<&2, R.Reply>}
  %eta_l(run(cs, seqD(flat(hist)))) : {S.merge(routes_of(n, cs), Laws.answers(parts_of(n, cs), seqT(n, flat(hist)))) == Laws.replies(_) : List<&2, R.Reply>}
  Equal.sym(List<&2, R.Reply>, rfst(run(cs, seqD(flat(hist)))), S.merge(routes_of(n, cs), Laws.answers(parts_of(n, cs), seqT(n, flat(hist)))),
    rep_go(n, cs, flat(hist), Nil{}, Laws.answers(parts_of(n, cs), seqT(n, flat(hist))))(pcs_flat(hist))({==}))

def Laws.shard_replies(n, hist, cs):
  replies_hist(n, hist, cs)

# The hashes of the parts
# -----------------------
# Each part a piece goes in carries the hash of the piece's key (push_pieces:
# its hint), which fits the piece; so every part of a batch comes with
# hashes that fit its commands.

def parts_fit(ps: List<&2, List<&2, S.Part>>) -> Type:
  match ps:
    case Con{p, rest}:
      Laws.all_fit(Laws.part_cmds(p), Laws.part_hashes(p)) & parts_fit(rest)
    case Nil{}:
      Unit

def hint_fits(c: R.Cmd) -> Laws.fits(c, hint(c)):
  match c:
    case R.Get{k}:
      {==}
    case R.Set{k, v}:
      {==}
    case R.SetNX{k, v}:
      {==}
    case R.GetSet{k, v}:
      {==}
    case R.IncrBy{k, by}:
      {==}
    case R.Append{k, v}:
      {==}
    case R.Strlen{k}:
      {==}
    case R.Ping{}:
      Unit{}
    case R.Echo{m}:
      Unit{}
    case R.Del{ks}:
      Unit{}
    case R.Exists{ks}:
      Unit{}
    case R.MGet{ks}:
      Unit{}
    case R.MSet{ps}:
      Unit{}
    case R.DbSize{}:
      Unit{}
    case R.FlushAll{}:
      Unit{}
    case R.Keys{p}:
      Unit{}
    case R.Bad{r}:
      Unit{}
    case R.SizeAt{x}:
      Unit{}
    case R.KeysAt{p, x}:
      Unit{}
    case R.FlushAt{x}:
      Unit{}

def push_fit.here(-c: R.Cmd, -h: U32, -p: List<&2, S.Part>, -rest: List<&2, List<&2, S.Part>>, f: Laws.fits(c, h), e: Laws.all_fit(Laws.part_cmds(p), Laws.part_hashes(p)) & parts_fit(rest)) -> parts_fit(Con{S.Part{c, h} <> p, rest}):
  (e1, e2) = e
  ((f, e1), e2)

def push_fit.on(-c: R.Cmd, -h: U32, -t: Nat, -p: List<&2, S.Part>, -rest: List<&2, List<&2, S.Part>>, e: Laws.all_fit(Laws.part_cmds(p), Laws.part_hashes(p)) & parts_fit(rest), ih: parts_fit(rest) -> parts_fit(S.push_at(t, S.Part{c, h}, rest))) -> parts_fit(Con{p, S.push_at(t, S.Part{c, h}, rest)}):
  (e1, e2) = e
  (e1, ih(e2))

def push_fit(s: Nat, +c: R.Cmd, +h: U32, ps: List<&2, List<&2, S.Part>>) -> Laws.fits(c, h) -> parts_fit(ps) -> parts_fit(S.push_at(s, S.Part{c, h}, ps)):
  match s ps:
    case 0n Con{p, rest}:
      f => e => push_fit.here(c, h, p, rest, f, e)
    case 0n Nil{}:
      f => e => ((f, Unit{}), Unit{})
    case 1n+t Con{p, +rest}:
      f => e => push_fit.on(c, h, t, p, rest, e, e2 => push_fit(t, c, h, rest)(f)(e2))
    case 1n+t Nil{}:
      f => e => (Unit{}, push_fit(t, c, h, Nil{})(f)(Unit{}))

def pieces_fit(+n: U32, cs: List<&2, R.Cmd>, +qs: List<&2, List<&2, S.Part>>) -> parts_fit(qs) -> parts_fit(push_pieces(n, cs, qs)):
  match cs:
    case Nil{}:
      e => e
    case Con{+c, +rest}:
      e => push_fit(home(n, c), c, hint(c), push_pieces(n, rest, qs))(hint_fits(c))(pieces_fit(n, rest, qs)(e))

def whole_fit(+n: U32, +c: R.Cmd, +qs: List<&2, List<&2, S.Part>>, wd: {whole(c) == True{} : Bool}) -> parts_fit(qs) -> parts_fit(rtsnd(S.route(n, c, qs))):
  e =>
    %route_whole(n, c, qs)(wd) : parts_fit(rtsnd(_))
    push_fit(home(n, c), c, hint(c), qs)(hint_fits(c))(e)

def route_fit(+n: U32, c: R.Cmd, +qs: List<&2, List<&2, S.Part>>) -> parts_fit(qs) -> parts_fit(rtsnd(S.route(n, c, qs))):
  match c:
    case R.Ping{}:
      e => e
    case R.Echo{m}:
      e => e
    case R.Bad{r}:
      e => e
    case R.Get{k}:
      e => whole_fit(n, R.Get{k}, qs, {==})(e)
    case R.Set{k, v}:
      e => whole_fit(n, R.Set{k, v}, qs, {==})(e)
    case R.SetNX{k, v}:
      e => whole_fit(n, R.SetNX{k, v}, qs, {==})(e)
    case R.GetSet{k, v}:
      e => whole_fit(n, R.GetSet{k, v}, qs, {==})(e)
    case R.IncrBy{k, by}:
      e => whole_fit(n, R.IncrBy{k, by}, qs, {==})(e)
    case R.Append{k, v}:
      e => whole_fit(n, R.Append{k, v}, qs, {==})(e)
    case R.Strlen{k}:
      e => whole_fit(n, R.Strlen{k}, qs, {==})(e)
    case R.SizeAt{x}:
      e => whole_fit(n, R.SizeAt{x}, qs, {==})(e)
    case R.KeysAt{p, x}:
      e => whole_fit(n, R.KeysAt{p, x}, qs, {==})(e)
    case R.FlushAt{x}:
      e => whole_fit(n, R.FlushAt{x}, qs, {==})(e)
    case R.Del{+ks}:
      e =>
        %each_eq(n, S.EDel{}, ks, qs) : parts_fit(rtsnd(S.as_sum(_)))
        pieces_fit(n, each_cmds(S.EDel{}, ks), qs)(e)
    case R.Exists{+ks}:
      e =>
        %each_eq(n, S.EExists{}, ks, qs) : parts_fit(rtsnd(S.as_sum(_)))
        pieces_fit(n, each_cmds(S.EExists{}, ks), qs)(e)
    case R.MGet{+ks}:
      e =>
        %each_eq(n, S.EGet{}, ks, qs) : parts_fit(rtsnd(S.as_items(_)))
        pieces_fit(n, each_cmds(S.EGet{}, ks), qs)(e)
    case R.MSet{+kvs}:
      e =>
        %pairs_eq(n, kvs, qs) : parts_fit(rtsnd(S.as_ok(_)))
        pieces_fit(n, set_cmds(kvs), qs)(e)
    case R.DbSize{}:
      e =>
        %fan_eq(n, S.FSize{}, KV.digits(), qs) : parts_fit(rtsnd(S.as_sum(_)))
        pieces_fit(n, fan_cmds(S.FSize{}, KV.digits()), qs)(e)
    case R.FlushAll{}:
      e =>
        %fan_eq(n, S.FFlush{}, KV.digits(), qs) : parts_fit(rtsnd(S.as_ok(_)))
        pieces_fit(n, fan_cmds(S.FFlush{}, KV.digits()), qs)(e)
    case R.Keys{+p}:
      e =>
        %fan_eq(n, S.FKeys{p}, KV.digits(), qs) : parts_fit(rtsnd(S.as_cat(_)))
        pieces_fit(n, fan_cmds(S.FKeys{p}, KV.digits()), qs)(e)

def parts_fit_of(+n: U32, cs: List<&2, R.Cmd>) -> parts_fit(parts_of(n, cs)):
  match cs:
    case Nil{}:
      Unit{}
    case Con{c, +rest}:
      route_fit(n, c, parts_of(n, rest))(parts_fit_of(n, rest))

def part_at_fit.here(-p: List<&2, S.Part>, -rest: List<&2, List<&2, S.Part>>, e: Laws.all_fit(Laws.part_cmds(p), Laws.part_hashes(p)) & parts_fit(rest)) -> Laws.all_fit(Laws.part_cmds(p), Laws.part_hashes(p)):
  (e1, e2) = e
  e1

def part_at_fit.on(-p: List<&2, S.Part>, -rest: List<&2, List<&2, S.Part>>, -t: Nat, e: Laws.all_fit(Laws.part_cmds(p), Laws.part_hashes(p)) & parts_fit(rest), ih: parts_fit(rest) -> Laws.all_fit(Laws.part_cmds(Laws.part_at(rest, t)), Laws.part_hashes(Laws.part_at(rest, t)))) -> Laws.all_fit(Laws.part_cmds(Laws.part_at(rest, t)), Laws.part_hashes(Laws.part_at(rest, t))):
  (e1, e2) = e
  ih(e2)

def part_at_fit(ps: List<&2, List<&2, S.Part>>, s: Nat) -> parts_fit(ps) -> Laws.all_fit(Laws.part_cmds(Laws.part_at(ps, s)), Laws.part_hashes(Laws.part_at(ps, s))):
  match ps s:
    case Con{p, rest} 0n:
      e => part_at_fit.here(p, rest, e)
    case Con{p, +rest} 1n+t:
      e => part_at_fit.on(p, rest, t, e, e2 => part_at_fit(rest, t)(e2))
    case Nil{} _:
      e => Unit{}

def Laws.shard_hashes(n, cs, s):
  %split_eq(n, cs) : Laws.all_fit(Laws.part_cmds(Laws.part_at(Laws.sh_parts(_), s)), Laws.part_hashes(Laws.part_at(Laws.sh_parts(_), s)))
  part_at_fit(parts_of(n, cs), s)(parts_fit_of(n, cs))

def unzip_eq(p: List<&2, S.Part>) -> {S.unzip(p) == (Laws.part_cmds(p), Laws.part_hashes(p)) : List<&2, R.Cmd> & List<&2, U32>}:
  match p:
    case Nil{}:
      {==}
    case Con{S.Part{+c, +h}, +rest}:
      %Equal.sym(List<&2, R.Cmd> & List<&2, U32>, S.unzip(rest), (Laws.part_cmds(rest), Laws.part_hashes(rest)), unzip_eq(rest)) : {S.unzip.put(S.Part{c, h}, _) == (c <> Laws.part_cmds(rest), h <> Laws.part_hashes(rest)) : List<&2, R.Cmd> & List<&2, U32>}
      {==}

def Laws.unzip_parts(p):
  unzip_eq(p)


# Bytes
# =====
# wire.bend merges the shards' answers in bytes step for step as
# shard.bend merges replies, and each step keeps the bytes those of the
# replies: a shard's next answer is out_of of its next reply (pop_store),
# a command's reply in bytes is its reply encoded (answer_store), and the
# replies the merge has put out are encodes of shard.bend's (merge_go_out).
# An encoder writes in front of what follows it (into_glue), so replies
# encoded one by one and glued are the replies encoded at once.

# Gluing
# ------

def app_assoc(a: String, -b: String, -c: String) -> {(a ++ b) ++ c == a ++ (b ++ c) : String}:
  match a:
    case SNil{}:
      {==}
    case SCon{h, t}:
      Equal.cong(String, String, x => SCon{h, x}, (t ++ b) ++ c, t ++ (b ++ c), app_assoc(t, b, c))

# a ++ x glued in front of out is a in front of x glued in front of out
def glue_in(a: String, -x: String, -y: String, -out: String, e: {x ++ out == y : String}) -> {(a ++ x) ++ out == a ++ y : String}:
  %e : {(a ++ x) ++ out == a ++ _ : String}
  app_assoc(a, x, out)

def bulk_glue(+s: String, -y: String, -out: String) -> {P.bulk_into(s, y) ++ out == P.bulk_into(s, y ++ out) : String}:
  glue_in("$", Nat.show(String.length(s)) ++ (P.crlf() ++ (s ++ (P.crlf() ++ y))), Nat.show(String.length(s)) ++ (P.crlf() ++ (s ++ (P.crlf() ++ (y ++ out)))), out,
    glue_in(Nat.show(String.length(s)), P.crlf() ++ (s ++ (P.crlf() ++ y)), P.crlf() ++ (s ++ (P.crlf() ++ (y ++ out))), out,
      glue_in(P.crlf(), s ++ (P.crlf() ++ y), s ++ (P.crlf() ++ (y ++ out)), out,
        glue_in(s, P.crlf() ++ y, P.crlf() ++ (y ++ out), out, app_assoc(P.crlf(), y, out)))))

def item_glue(i: R.Item, -y: String, -out: String) -> {P.item_into(i, y) ++ out == P.item_into(i, y ++ out) : String}:
  match i:
    case R.IBulk{s}:
      bulk_glue(s, y, out)
    case R.INull{}:
      app_assoc("$-1\r\n", y, out)

def items_glue(xs: List<&2, R.Item>, -y: String, -out: String) -> {P.items_into(xs, y) ++ out == P.items_into(xs, y ++ out) : String}:
  match xs:
    case Nil{}:
      {==}
    case Con{x, rest}:
      Equal.trans(String, P.item_into(x, P.items_into(rest, y)) ++ out, P.item_into(x, P.items_into(rest, y) ++ out), P.item_into(x, P.items_into(rest, y ++ out)),
        item_glue(x, P.items_into(rest, y), out),
        Equal.cong(String, String, z => P.item_into(x, z), P.items_into(rest, y) ++ out, P.items_into(rest, y ++ out), items_glue(rest, y, out)))

def int_glue(i: R.Int, -y: String, -out: String) -> {P.int_into(i, y) ++ out == P.int_into(i, y ++ out) : String}:
  match i:
    case R.IPos{n}:
      glue_in(":", Nat.show(n) ++ (P.crlf() ++ y), Nat.show(n) ++ (P.crlf() ++ (y ++ out)), out,
        glue_in(Nat.show(n), P.crlf() ++ y, P.crlf() ++ (y ++ out), out, app_assoc(P.crlf(), y, out)))
    case R.INeg{n}:
      glue_in(":-", Nat.show(1n+n) ++ (P.crlf() ++ y), Nat.show(1n+n) ++ (P.crlf() ++ (y ++ out)), out,
        glue_in(Nat.show(1n+n), P.crlf() ++ y, P.crlf() ++ (y ++ out), out, app_assoc(P.crlf(), y, out)))

# an encoder writes in front of what follows it
def into_glue(r: R.Reply, -y: String, -out: String) -> {P.encode_into(r, y) ++ out == P.encode_into(r, y ++ out) : String}:
  match r:
    case R.RStatus{s}:
      glue_in("+", s ++ (P.crlf() ++ y), s ++ (P.crlf() ++ (y ++ out)), out,
        glue_in(s, P.crlf() ++ y, P.crlf() ++ (y ++ out), out, app_assoc(P.crlf(), y, out)))
    case R.RError{s}:
      glue_in("-", s ++ (P.crlf() ++ y), s ++ (P.crlf() ++ (y ++ out)), out,
        glue_in(s, P.crlf() ++ y, P.crlf() ++ (y ++ out), out, app_assoc(P.crlf(), y, out)))
    case R.RInt{i}:
      int_glue(i, y, out)
    case R.RBulk{s}:
      bulk_glue(s, y, out)
    case R.RNull{}:
      app_assoc("$-1\r\n", y, out)
    case R.RArray{+xs}:
      glue_in("*", Nat.show(List.length(&2, R.Item, xs)) ++ (P.crlf() ++ P.items_into(xs, y)), Nat.show(List.length(&2, R.Item, xs)) ++ (P.crlf() ++ P.items_into(xs, y ++ out)), out,
        glue_in(Nat.show(List.length(&2, R.Item, xs)), P.crlf() ++ P.items_into(xs, y), P.crlf() ++ P.items_into(xs, y ++ out), out,
          glue_in(P.crlf(), P.items_into(xs, y), P.items_into(xs, y ++ out), out, items_glue(xs, y, out))))

def encodes_glue(rs: List<&2, R.Reply>) -> {String.concat(W.encodes(rs)) == P.encode_all(rs) : String}:
  match rs:
    case Nil{}:
      {==}
    case Con{+r, +rest}:
      %encodes_glue(rest) : {P.encode(r) ++ String.concat(W.encodes(rest)) == P.encode_into(r, _) : String}
      into_glue(r, SNil{}, String.concat(W.encodes(rest)))

def Laws.encodes_glue(rs):
  encodes_glue(rs)

# Answers
# -------

# a pop's reply and store, in bytes
def pop_out(x: R.Reply & S.Store()) -> W.Out & W.Store():
  (r, st) = x
  (W.out_of(r), W.store_of(st))

# a command's reply and the store left, in bytes
def ans_out(x: R.Reply & S.Store()) -> String & W.Store():
  (r, st) = x
  (P.encode(r), W.store_of(st))

def pop_back_out(-x: List<&2, R.Reply>, p: R.Reply & S.Store()) -> {W.pop.back(W.outs(x), pop_out(p)) == pop_out(S.pop.back(x, p)) : W.Out & W.Store()}:
  (r, st) = p
  {==}

# a shard's next answer is its next reply, in bytes
def pop_store(s: Nat, st: S.Store()) -> {W.pop(s, W.store_of(st)) == pop_out(S.pop(s, st)) : W.Out & W.Store()}:
  match s st:
    case 0n Con{Con{r, rs}, rest}:
      {==}
    case 0n Con{Nil{}, rest}:
      {==}
    case 0n Nil{}:
      {==}
    case 1n++t Con{x, +rest}:
      Equal.trans(W.Out & W.Store(), W.pop.back(W.outs(x), W.pop(t, W.store_of(rest))), W.pop.back(W.outs(x), pop_out(S.pop(t, rest))), pop_out(S.pop.back(x, S.pop(t, rest))),
        Equal.cong(W.Out & W.Store(), W.Out & W.Store(), q => W.pop.back(W.outs(x), q), W.pop(t, W.store_of(rest)), pop_out(S.pop(t, rest)), pop_store(t, rest)),
        pop_back_out(x, S.pop(t, rest)))
    case 1n+t Nil{}:
      {==}

def bytes_out(r: R.Reply) -> {W.bytes_of(W.out_of(r)) == P.encode(r) : String}:
  match r:
    case R.RStatus{s}:
      {==}
    case R.RError{s}:
      {==}
    case R.RInt{i}:
      {==}
    case R.RBulk{s}:
      {==}
    case R.RNull{}:
      {==}
    case R.RArray{xs}:
      {==}

def one_out(p: R.Reply & S.Store()) -> {W.one.fin(pop_out(p)) == ans_out(p) : String & W.Store()}:
  (r, st) = p
  Equal.cong(String, String & W.Store(), b => (b, W.store_of(st)), W.bytes_of(W.out_of(r)), P.encode(r), bytes_out(r))

# Arrays of GET replies (MGET)

def item_enc(i: R.Item) -> String:
  P.item_into(i, SNil{})

def item_encs(xs: List<&2, R.Item>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{x, rest}:
      item_enc(x) <> item_encs(rest)

def items_out(x: List<&2, R.Item> & S.Store()) -> List<&2, String> & W.Store():
  (acc, st) = x
  (item_encs(acc), W.store_of(st))

def item_out(r: R.Reply) -> {W.item_bytes(W.out_of(r)) == item_enc(S.item_of(r)) : String}:
  match r:
    case R.RStatus{s}:
      {==}
    case R.RError{s}:
      {==}
    case R.RInt{i}:
      {==}
    case R.RBulk{s}:
      {==}
    case R.RNull{}:
      {==}
    case R.RArray{xs}:
      {==}

def items_put_out(-acc: List<&2, R.Item>, p: R.Reply & S.Store()) -> {W.items.put(item_encs(acc), pop_out(p)) == items_out(S.items.put(acc, p)) : List<&2, String> & W.Store()}:
  (r, st) = p
  Equal.cong(String, List<&2, String> & W.Store(), b => (b <> item_encs(acc), W.store_of(st)), W.item_bytes(W.out_of(r)), item_enc(S.item_of(r)), item_out(r))

def items_step_out(+s: Nat, p: List<&2, R.Item> & S.Store()) -> {W.items.step(s, items_out(p)) == items_out(S.items.step(s, p)) : List<&2, String> & W.Store()}:
  (acc, +st) = p
  Equal.trans(List<&2, String> & W.Store(), W.items.put(item_encs(acc), W.pop(s, W.store_of(st))), W.items.put(item_encs(acc), pop_out(S.pop(s, st))), items_out(S.items.put(acc, S.pop(s, st))),
    Equal.cong(W.Out & W.Store(), List<&2, String> & W.Store(), q => W.items.put(item_encs(acc), q), W.pop(s, W.store_of(st)), pop_out(S.pop(s, st)), pop_store(s, st)),
    items_put_out(acc, S.pop(s, st)))

def items_go_out(ss: List<&2, Nat>, p: List<&2, R.Item> & S.Store()) -> {W.items.go(ss, items_out(p)) == items_out(S.items.go(ss, p)) : List<&2, String> & W.Store()}:
  match ss:
    case Nil{}:
      {==}
    case Con{+s, rest}:
      (+acc, +st) = p
      Equal.trans(List<&2, String> & W.Store(), W.items.go(rest, W.items.step(s, items_out((acc, st)))), W.items.go(rest, items_out(S.items.step(s, (acc, st)))), items_out(S.items.go(rest, S.items.step(s, (acc, st)))),
        Equal.cong(List<&2, String> & W.Store(), List<&2, String> & W.Store(), q => W.items.go(rest, q), W.items.step(s, items_out((acc, st))), items_out(S.items.step(s, (acc, st))), items_step_out(s, (acc, st))),
        items_go_out(rest, S.items.step(s, (acc, st))))

def len_encs(xs: List<&2, R.Item>) -> {List.length(&2, String, item_encs(xs)) == List.length(&2, R.Item, xs) : Nat}:
  match xs:
    case Nil{}:
      {==}
    case Con{x, rest}:
      Equal.cong(Nat, Nat, k => 1n+k, List.length(&2, String, item_encs(rest)), List.length(&2, R.Item, rest), len_encs(rest))

def items_concat(xs: List<&2, R.Item>) -> {String.concat(item_encs(xs)) == P.items_into(xs, SNil{}) : String}:
  match xs:
    case Nil{}:
      {==}
    case Con{+x, +rest}:
      %items_concat(rest) : {item_enc(x) ++ String.concat(item_encs(rest)) == P.item_into(x, _) : String}
      item_glue(x, SNil{}, String.concat(item_encs(rest)))

def rev_encs(xs: List<&2, R.Item>, -acc: List<&2, R.Item>) -> {List.reverse.go(&2, String, item_encs(xs), item_encs(acc)) == item_encs(List.reverse.go(&2, R.Item, xs, acc)) : List<&2, String>}:
  match xs:
    case Nil{}:
      {==}
    case Con{x, rest}:
      rev_encs(rest, Con{x, acc})

# an array's items encoded and glued under its header are the array encoded
def array_bytes(+ys: List<&2, R.Item>) -> {W.items.bytes(item_encs(ys)) == P.encode(R.RArray{ys}) : String}:
  %items_concat(ys) : {W.items.bytes(item_encs(ys)) == "*" ++ Nat.show(List.length(&2, R.Item, ys)) ++ P.crlf() ++ _ : String}
  %len_encs(ys) : {W.items.bytes(item_encs(ys)) == "*" ++ Nat.show(_) ++ P.crlf() ++ String.concat(item_encs(ys)) : String}
  {==}

def items_fin_out(q: List<&2, R.Item> & S.Store()) -> {W.items.fin(items_out(q)) == ans_out(S.items.fin(q)) : String & W.Store()}:
  (+acc, st) = q
  Equal.trans(String & W.Store(), (W.items.bytes(List.reverse(&2, String, item_encs(acc))), W.store_of(st)), (W.items.bytes(item_encs(List.reverse(&2, R.Item, acc))), W.store_of(st)), (P.encode(R.RArray{List.reverse(&2, R.Item, acc)}), W.store_of(st)),
    Equal.cong(List<&2, String>, String & W.Store(), xs => (W.items.bytes(xs), W.store_of(st)), List.reverse(&2, String, item_encs(acc)), item_encs(List.reverse(&2, R.Item, acc)), rev_encs(acc, Nil{})),
    Equal.cong(String, String & W.Store(), b => (b, W.store_of(st)), W.items.bytes(item_encs(List.reverse(&2, R.Item, acc))), P.encode(R.RArray{List.reverse(&2, R.Item, acc)}), array_bytes(List.reverse(&2, R.Item, acc))))

def items_answer(+ss: List<&2, Nat>, +st: S.Store()) -> {W.items.fin(W.items.go(ss, (Nil{}, W.store_of(st)))) == ans_out(S.items.fin(S.items.go(ss, (Nil{}, st)))) : String & W.Store()}:
  Equal.trans(String & W.Store(), W.items.fin(W.items.go(ss, items_out((Nil{}, st)))), W.items.fin(items_out(S.items.go(ss, (Nil{}, st)))), ans_out(S.items.fin(S.items.go(ss, (Nil{}, st)))),
    Equal.cong(List<&2, String> & W.Store(), String & W.Store(), q => W.items.fin(q), W.items.go(ss, items_out((Nil{}, st))), items_out(S.items.go(ss, (Nil{}, st))), items_go_out(ss, (Nil{}, st))),
    items_fin_out(S.items.go(ss, (Nil{}, st))))

# Sums of counts (DEL, EXISTS)

def sum_out(x: Nat & S.Store()) -> Nat & W.Store():
  (n, st) = x
  (n, W.store_of(st))

def count_out(r: R.Reply) -> {W.count_of(W.out_of(r)) == S.count_of(r) : Nat}:
  match r:
    case R.RStatus{s}:
      {==}
    case R.RError{s}:
      {==}
    case R.RInt{R.IPos{k}}:
      {==}
    case R.RInt{R.INeg{k}}:
      {==}
    case R.RBulk{s}:
      {==}
    case R.RNull{}:
      {==}
    case R.RArray{xs}:
      {==}

def sum_put_out(-n: Nat, p: R.Reply & S.Store()) -> {W.sum.put(n, pop_out(p)) == sum_out(S.sum.put(n, p)) : Nat & W.Store()}:
  (r, st) = p
  Equal.cong(Nat, Nat & W.Store(), k => (Nat.add(n, k), W.store_of(st)), W.count_of(W.out_of(r)), S.count_of(r), count_out(r))

def sum_step_out(+s: Nat, p: Nat & S.Store()) -> {W.sum.step(s, sum_out(p)) == sum_out(S.sum.step(s, p)) : Nat & W.Store()}:
  (n, +st) = p
  Equal.trans(Nat & W.Store(), W.sum.put(n, W.pop(s, W.store_of(st))), W.sum.put(n, pop_out(S.pop(s, st))), sum_out(S.sum.put(n, S.pop(s, st))),
    Equal.cong(W.Out & W.Store(), Nat & W.Store(), q => W.sum.put(n, q), W.pop(s, W.store_of(st)), pop_out(S.pop(s, st)), pop_store(s, st)),
    sum_put_out(n, S.pop(s, st)))

def sum_go_out(ss: List<&2, Nat>, p: Nat & S.Store()) -> {W.sum.go(ss, sum_out(p)) == sum_out(S.sum.go(ss, p)) : Nat & W.Store()}:
  match ss:
    case Nil{}:
      {==}
    case Con{+s, rest}:
      (+n, +st) = p
      Equal.trans(Nat & W.Store(), W.sum.go(rest, W.sum.step(s, sum_out((n, st)))), W.sum.go(rest, sum_out(S.sum.step(s, (n, st)))), sum_out(S.sum.go(rest, S.sum.step(s, (n, st)))),
        Equal.cong(Nat & W.Store(), Nat & W.Store(), q => W.sum.go(rest, q), W.sum.step(s, sum_out((n, st))), sum_out(S.sum.step(s, (n, st))), sum_step_out(s, (n, st))),
        sum_go_out(rest, S.sum.step(s, (n, st))))

def sum_fin_out(q: Nat & S.Store()) -> {W.sum.fin(sum_out(q)) == ans_out(S.sum.fin(q)) : String & W.Store()}:
  (n, st) = q
  {==}

def sum_answer(+ss: List<&2, Nat>, +st: S.Store()) -> {W.sum.fin(W.sum.go(ss, (0n, W.store_of(st)))) == ans_out(S.sum.fin(S.sum.go(ss, (0n, st)))) : String & W.Store()}:
  Equal.trans(String & W.Store(), W.sum.fin(W.sum.go(ss, sum_out((0n, st)))), W.sum.fin(sum_out(S.sum.go(ss, (0n, st)))), ans_out(S.sum.fin(S.sum.go(ss, (0n, st)))),
    Equal.cong(Nat & W.Store(), String & W.Store(), q => W.sum.fin(q), W.sum.go(ss, sum_out((0n, st))), sum_out(S.sum.go(ss, (0n, st))), sum_go_out(ss, (0n, st))),
    sum_fin_out(S.sum.go(ss, (0n, st))))

# OK (MSET)

def ok_drop_out(p: R.Reply & S.Store()) -> {W.ok.drop(pop_out(p)) == W.store_of(S.ok.drop(p)) : W.Store()}:
  (r, st) = p
  {==}

def ok_go_out(ss: List<&2, Nat>, +st: S.Store()) -> {W.ok.go(ss, W.store_of(st)) == W.store_of(S.ok.go(ss, st)) : W.Store()}:
  match ss:
    case Nil{}:
      {==}
    case Con{+s, rest}:
      Equal.trans(W.Store(), W.ok.go(rest, W.ok.drop(W.pop(s, W.store_of(st)))), W.ok.go(rest, W.ok.drop(pop_out(S.pop(s, st)))), W.store_of(S.ok.go(rest, S.ok.drop(S.pop(s, st)))),
        Equal.cong(W.Out & W.Store(), W.Store(), q => W.ok.go(rest, W.ok.drop(q)), W.pop(s, W.store_of(st)), pop_out(S.pop(s, st)), pop_store(s, st)),
        Equal.trans(W.Store(), W.ok.go(rest, W.ok.drop(pop_out(S.pop(s, st)))), W.ok.go(rest, W.store_of(S.ok.drop(S.pop(s, st)))), W.store_of(S.ok.go(rest, S.ok.drop(S.pop(s, st)))),
          Equal.cong(W.Store(), W.Store(), q => W.ok.go(rest, q), W.ok.drop(pop_out(S.pop(s, st))), W.store_of(S.ok.drop(S.pop(s, st))), ok_drop_out(S.pop(s, st))),
          ok_go_out(rest, S.ok.drop(S.pop(s, st)))))

def ok_answer(ss: List<&2, Nat>, +st: S.Store()) -> {(P.encode(R.r_ok()), W.ok.go(ss, W.store_of(st))) == ans_out((R.r_ok(), S.ok.go(ss, st))) : String & W.Store()}:
  Equal.cong(W.Store(), String & W.Store(), z => (P.encode(R.r_ok()), z), W.ok.go(ss, W.store_of(st)), W.store_of(S.ok.go(ss, st)), ok_go_out(ss, st))

# Arrays joined (KEYS)

def cat_out(x: List<&2, R.Item> & S.Store()) -> List<&2, R.Item> & W.Store():
  (acc, st) = x
  (acc, W.store_of(st))

def array_out(r: R.Reply) -> {W.items_of(W.out_of(r)) == S.array_of(r) : List<&2, R.Item>}:
  match r:
    case R.RStatus{s}:
      {==}
    case R.RError{s}:
      {==}
    case R.RInt{i}:
      {==}
    case R.RBulk{s}:
      {==}
    case R.RNull{}:
      {==}
    case R.RArray{xs}:
      {==}

def cat_put_out(-acc: List<&2, R.Item>, p: R.Reply & S.Store()) -> {W.cat.put(acc, pop_out(p)) == cat_out(S.cat.put(acc, p)) : List<&2, R.Item> & W.Store()}:
  (r, st) = p
  Equal.cong(List<&2, R.Item>, List<&2, R.Item> & W.Store(), xs => (S.cat.rev(xs, acc), W.store_of(st)), W.items_of(W.out_of(r)), S.array_of(r), array_out(r))

def cat_step_out(+s: Nat, p: List<&2, R.Item> & S.Store()) -> {W.cat.step(s, cat_out(p)) == cat_out(S.cat.step(s, p)) : List<&2, R.Item> & W.Store()}:
  (acc, +st) = p
  Equal.trans(List<&2, R.Item> & W.Store(), W.cat.put(acc, W.pop(s, W.store_of(st))), W.cat.put(acc, pop_out(S.pop(s, st))), cat_out(S.cat.put(acc, S.pop(s, st))),
    Equal.cong(W.Out & W.Store(), List<&2, R.Item> & W.Store(), q => W.cat.put(acc, q), W.pop(s, W.store_of(st)), pop_out(S.pop(s, st)), pop_store(s, st)),
    cat_put_out(acc, S.pop(s, st)))

def cat_go_out(ss: List<&2, Nat>, p: List<&2, R.Item> & S.Store()) -> {W.cat.go(ss, cat_out(p)) == cat_out(S.cat.go(ss, p)) : List<&2, R.Item> & W.Store()}:
  match ss:
    case Nil{}:
      {==}
    case Con{+s, rest}:
      (+acc, +st) = p
      Equal.trans(List<&2, R.Item> & W.Store(), W.cat.go(rest, W.cat.step(s, cat_out((acc, st)))), W.cat.go(rest, cat_out(S.cat.step(s, (acc, st)))), cat_out(S.cat.go(rest, S.cat.step(s, (acc, st)))),
        Equal.cong(List<&2, R.Item> & W.Store(), List<&2, R.Item> & W.Store(), q => W.cat.go(rest, q), W.cat.step(s, cat_out((acc, st))), cat_out(S.cat.step(s, (acc, st))), cat_step_out(s, (acc, st))),
        cat_go_out(rest, S.cat.step(s, (acc, st))))

def cat_fin_out(q: List<&2, R.Item> & S.Store()) -> {W.cat.fin(cat_out(q)) == ans_out(S.items.fin(q)) : String & W.Store()}:
  (acc, st) = q
  {==}

def cat_answer(+ss: List<&2, Nat>, +st: S.Store()) -> {W.cat.fin(W.cat.go(ss, (Nil{}, W.store_of(st)))) == ans_out(S.items.fin(S.cat.go(ss, (Nil{}, st)))) : String & W.Store()}:
  Equal.trans(String & W.Store(), W.cat.fin(W.cat.go(ss, cat_out((Nil{}, st)))), W.cat.fin(cat_out(S.cat.go(ss, (Nil{}, st)))), ans_out(S.items.fin(S.cat.go(ss, (Nil{}, st)))),
    Equal.cong(List<&2, R.Item> & W.Store(), String & W.Store(), q => W.cat.fin(q), W.cat.go(ss, cat_out((Nil{}, st))), cat_out(S.cat.go(ss, (Nil{}, st))), cat_go_out(ss, (Nil{}, st))),
    cat_fin_out(S.cat.go(ss, (Nil{}, st))))

# a command's reply in bytes is its reply, encoded
def answer_store(rt: S.Route, +st: S.Store()) -> {W.answer(rt, W.store_of(st)) == ans_out(S.answer(rt, st)) : String & W.Store()}:
  match rt:
    case S.RHere{r}:
      {==}
    case S.ROne{+s}:
      Equal.trans(String & W.Store(), W.one.fin(W.pop(s, W.store_of(st))), W.one.fin(pop_out(S.pop(s, st))), ans_out(S.pop(s, st)),
        Equal.cong(W.Out & W.Store(), String & W.Store(), q => W.one.fin(q), W.pop(s, W.store_of(st)), pop_out(S.pop(s, st)), pop_store(s, st)),
        one_out(S.pop(s, st)))
    case S.RItems{ss}:
      items_answer(ss, st)
    case S.RSum{ss}:
      sum_answer(ss, st)
    case S.ROk{ss}:
      ok_answer(ss, st)
    case S.RCat{ss}:
      cat_answer(ss, st)

# The merge
# ---------

def merge_out(x: List<&2, R.Reply> & S.Store()) -> List<&2, String> & W.Store():
  (racc, st) = x
  (W.encodes(racc), W.store_of(st))

def merge_put_out(-racc: List<&2, R.Reply>, p: R.Reply & S.Store()) -> {W.merge.put(W.encodes(racc), ans_out(p)) == merge_out(S.merge.put(racc, p)) : List<&2, String> & W.Store()}:
  (r, st) = p
  {==}

def merge_step_parts(+rt: S.Route, -racc: List<&2, R.Reply>, +st: S.Store()) -> {W.merge.put(W.encodes(racc), W.answer(rt, W.store_of(st))) == merge_out(S.merge.put(racc, S.answer(rt, st))) : List<&2, String> & W.Store()}:
  Equal.trans(List<&2, String> & W.Store(), W.merge.put(W.encodes(racc), W.answer(rt, W.store_of(st))), W.merge.put(W.encodes(racc), ans_out(S.answer(rt, st))), merge_out(S.merge.put(racc, S.answer(rt, st))),
    Equal.cong(String & W.Store(), List<&2, String> & W.Store(), q => W.merge.put(W.encodes(racc), q), W.answer(rt, W.store_of(st)), ans_out(S.answer(rt, st)), answer_store(rt, st)),
    merge_put_out(racc, S.answer(rt, st)))

def merge_step_out(+rt: S.Route, p: List<&2, R.Reply> & S.Store()) -> {W.merge.step(rt, merge_out(p)) == merge_out(S.merge.step(rt, p)) : List<&2, String> & W.Store()}:
  (racc, st) = p
  merge_step_parts(rt, racc, st)

def merge_go_out(routes: List<&2, S.Route>, p: List<&2, R.Reply> & S.Store()) -> {W.merge.go(routes, merge_out(p)) == merge_out(S.merge.go(routes, p)) : List<&2, String> & W.Store()}:
  match routes:
    case Nil{}:
      {==}
    case Con{+rt, rest}:
      (+racc, +st) = p
      Equal.trans(List<&2, String> & W.Store(), W.merge.go(rest, W.merge.step(rt, merge_out((racc, st)))), W.merge.go(rest, merge_out(S.merge.step(rt, (racc, st)))), merge_out(S.merge.go(rest, S.merge.step(rt, (racc, st)))),
        Equal.cong(List<&2, String> & W.Store(), List<&2, String> & W.Store(), q => W.merge.go(rest, q), W.merge.step(rt, merge_out((racc, st))), merge_out(S.merge.step(rt, (racc, st))), merge_step_out(rt, (racc, st))),
        merge_go_out(rest, S.merge.step(rt, (racc, st))))

def rev_encodes(xs: List<&2, R.Reply>, -acc: List<&2, R.Reply>) -> {List.reverse.go(&2, String, W.encodes(xs), W.encodes(acc)) == W.encodes(List.reverse.go(&2, R.Reply, xs, acc)) : List<&2, String>}:
  match xs:
    case Nil{}:
      {==}
    case Con{x, rest}:
      rev_encodes(rest, Con{x, acc})

def merge_fin_out(q: List<&2, R.Reply> & S.Store()) -> {W.merge.fin(merge_out(q)) == W.encodes(S.merge.fin(q)) : List<&2, String>}:
  (racc, st) = q
  rev_encodes(racc, Nil{})

def Laws.merge_bytes(routes, st):
  Equal.trans(List<&2, String>, W.merge.fin(W.merge.go(routes, merge_out((Nil{}, st)))), W.merge.fin(merge_out(S.merge.go(routes, (Nil{}, st)))), W.encodes(S.merge.fin(S.merge.go(routes, (Nil{}, st)))),
    Equal.cong(List<&2, String> & W.Store(), List<&2, String>, q => W.merge.fin(q), W.merge.go(routes, merge_out((Nil{}, st))), merge_out(S.merge.go(routes, (Nil{}, st))), merge_go_out(routes, (Nil{}, st))),
    merge_fin_out(S.merge.go(routes, (Nil{}, st))))

# The sharded server's bytes
# --------------------------

def bytes_parts(+routes: List<&2, S.Route>, +ps: List<&2, List<&2, S.Part>>, +ts: List<&2, KV.Trie<String>>) -> {String.concat(W.merge(routes, W.store_of(Laws.answers(ps, ts)))) == P.encode_all(S.merge(routes, Laws.answers(ps, ts))) : String}:
  Equal.trans(String, String.concat(W.merge(routes, W.store_of(Laws.answers(ps, ts)))), String.concat(W.encodes(S.merge(routes, Laws.answers(ps, ts)))), P.encode_all(S.merge(routes, Laws.answers(ps, ts))),
    Equal.cong(List<&2, String>, String, xs => String.concat(xs), W.merge(routes, W.store_of(Laws.answers(ps, ts))), W.encodes(S.merge(routes, Laws.answers(ps, ts))), Laws.merge_bytes(routes, Laws.answers(ps, ts))),
    encodes_glue(S.merge(routes, Laws.answers(ps, ts))))

def bytes_go(+ts: List<&2, KV.Trie<String>>, x: List<&2, S.Route> & List<&2, List<&2, S.Part>>) -> {String.concat(Laws.sh_bytes.go(ts, x)) == P.encode_all(Laws.sh_replies(Laws.sharded.go(ts, x))) : String}:
  (routes, ps) = x
  bytes_parts(routes, ps, ts)

def Laws.shard_bytes(n, hist, cs):
  Equal.trans(String, String.concat(Laws.sh_bytes(n, cs, Laws.shards(n, hist))), P.encode_all(Laws.sh_replies(Laws.sharded(n, cs, Laws.shards(n, hist)))), P.encode_all(Laws.replies(R.exec_all(cs, Laws.single(hist)))),
    bytes_go(Laws.shards(n, hist), S.split(n, cs)),
    Equal.cong(List<&2, R.Reply>, String, rs => P.encode_all(rs), Laws.sh_replies(Laws.sharded(n, cs, Laws.shards(n, hist))), Laws.replies(R.exec_all(cs, Laws.single(hist))), Laws.shard_replies(n, hist, cs)))

# Commuting commands
# ==================
# A command changes a key only as that key read before it (point_cmd),
# and leaves alone the keys it does not write (frame); so a key that at
# most one of two commands writes reads the same after both, in either
# order (commute_at). A command's reply depends only on what the keys it
# reads read, or for DBSIZE and KEYS on the whole database, which a
# command that only reads leaves as it was; so it is the same after a
# command that writes none of those keys (reply_after).

# A command's effect on a key
# ---------------------------
# A command on one key leaves its key reading as a function of what the
# key read before (loc_key), and the other keys as they were.

def gss(+t: KV.Trie<String>, +k: String, +v: String) -> {KV.get(String, KV.set(String, t, k, v), k) == Some{v} : Maybe<&2, String>}:
  Laws.get_set_same(String, t, k, v)

def set_key(+t: KV.Trie<String>, +u: KV.Trie<String>, +k: String, +v: String) -> {KV.get(String, KV.set(String, t, k, v), k) == KV.get(String, KV.set(String, u, k, v), k) : Maybe<&2, String>}:
  Equal.trans(Maybe<&2, String>, KV.get(String, KV.set(String, t, k, v), k), Some{v}, KV.get(String, KV.set(String, u, k, v), k), gss(t, k, v), Equal.sym(Maybe<&2, String>, KV.get(String, KV.set(String, u, k, v), k), Some{v}, gss(u, k, v)))

def setnx_key(b: Bool, +t: KV.Trie<String>, +u: KV.Trie<String>, +k: String, +v: String) -> {KV.get(String, t, k) == KV.get(String, u, k) : Maybe<&2, String>} -> {KV.get(String, R.db_of(R.setnx.if(t, k, v, KV.hash(k), b)), k) == KV.get(String, R.db_of(R.setnx.if(u, k, v, KV.hash(k), b)), k) : Maybe<&2, String>}:
  match b:
    case True{}:
      e => e
    case False{}:
      e => set_key(t, u, k, v)

def incr_fit_key(ok: Bool, +t: KV.Trie<String>, +u: KV.Trie<String>, +k: String, +n: R.Int) -> {KV.get(String, t, k) == KV.get(String, u, k) : Maybe<&2, String>} -> {KV.get(String, R.db_of(R.incr.fit(t, k, KV.hash(k), n, ok)), k) == KV.get(String, R.db_of(R.incr.fit(u, k, KV.hash(k), n, ok)), k) : Maybe<&2, String>}:
  match ok:
    case True{}:
      e => set_key(t, u, k, R.int_show(n))
    case False{}:
      e => e

def incr_key(x: Maybe<&2, R.Int>, +t: KV.Trie<String>, +u: KV.Trie<String>, +k: String, +by: R.Int) -> {KV.get(String, t, k) == KV.get(String, u, k) : Maybe<&2, String>} -> {KV.get(String, R.db_of(R.incr.got(t, k, KV.hash(k), by, x)), k) == KV.get(String, R.db_of(R.incr.got(u, k, KV.hash(k), by, x)), k) : Maybe<&2, String>}:
  match x:
    case Some{+a}:
      e => incr_fit_key(R.int_fits(R.int_add(a, by)), t, u, k, R.int_add(a, by))(e)
    case None{}:
      e => e

def loc_key_del(ks: List<&2, String>, +t: KV.Trie<String>, +u: KV.Trie<String>) -> {keyed(R.Del{ks}) == True{} : Bool} -> {KV.get(String, t, key_of(R.Del{ks})) == KV.get(String, u, key_of(R.Del{ks})) : Maybe<&2, String>} -> {KV.get(String, R.db_of(R.exec(R.Del{ks}, t)), key_of(R.Del{ks})) == KV.get(String, R.db_of(R.exec(R.Del{ks}, u)), key_of(R.Del{ks})) : Maybe<&2, String>}:
  match ks:
    case Nil{}:
      kd => e => Empty.absurd({KV.get(String, R.db_of(R.exec(R.Del{Nil{}}, t)), "") == KV.get(String, R.db_of(R.exec(R.Del{Nil{}}, u)), "") : Maybe<&2, String>}, false_true(kd))
    case Con{+k, Nil{}}:
      kd => e => %del_one(KV.has(String, t, k), KV.del(String, t, k)) : {KV.get(String, R.db_of(_), k) == KV.get(String, R.db_of(R.exec(R.Del{[k]}, u)), k) : Maybe<&2, String>}
                 %del_one(KV.has(String, u, k), KV.del(String, u, k)) : {KV.get(String, KV.del(String, t, k), k) == KV.get(String, R.db_of(_), k) : Maybe<&2, String>}
                 Equal.trans(Maybe<&2, String>, KV.get(String, KV.del(String, t, k), k), None{}, KV.get(String, KV.del(String, u, k), k), Laws.get_del_same(String, t, k), Equal.sym(Maybe<&2, String>, KV.get(String, KV.del(String, u, k), k), None{}, Laws.get_del_same(String, u, k)))
    case Con{+k, Con{j, rest}}:
      kd => e => Empty.absurd({KV.get(String, R.db_of(R.exec(R.Del{Con{k, Con{j, rest}}}, t)), k) == KV.get(String, R.db_of(R.exec(R.Del{Con{k, Con{j, rest}}}, u)), k) : Maybe<&2, String>}, false_true(kd))

def loc_key(c: R.Cmd, +t: KV.Trie<String>, +u: KV.Trie<String>) -> {keyed(c) == True{} : Bool} -> {KV.get(String, t, key_of(c)) == KV.get(String, u, key_of(c)) : Maybe<&2, String>} -> {KV.get(String, R.db_of(R.exec(c, t)), key_of(c)) == KV.get(String, R.db_of(R.exec(c, u)), key_of(c)) : Maybe<&2, String>}:
  match c:
    case R.Get{+k}:
      kd => e => e
    case R.Set{+k, +v}:
      kd => e => set_key(t, u, k, v)
    case R.SetNX{+k, +v}:
      kd => +e => %e : {KV.get(String, R.db_of(R.setnx.if(t, k, v, KV.hash(k), Maybe.is_some(&2, String, KV.get(String, t, k)))), k) == KV.get(String, R.db_of(R.setnx.if(u, k, v, KV.hash(k), Maybe.is_some(&2, String, _))), k) : Maybe<&2, String>}
                   setnx_key(Maybe.is_some(&2, String, KV.get(String, t, k)), t, u, k, v)(e)
    case R.GetSet{+k, +v}:
      kd => e => set_key(t, u, k, v)
    case R.IncrBy{+k, +by}:
      kd => +e => %e : {KV.get(String, R.db_of(R.incr.got(t, k, KV.hash(k), by, R.incr.old(KV.get(String, t, k)))), k) == KV.get(String, R.db_of(R.incr.got(u, k, KV.hash(k), by, R.incr.old(_))), k) : Maybe<&2, String>}
                   incr_key(R.incr.old(KV.get(String, t, k)), t, u, k, by)(e)
    case R.Append{+k, +v}:
      kd => e => %e : {KV.get(String, KV.set(String, t, k, R.append_to(KV.get(String, t, k), v)), k) == KV.get(String, KV.set(String, u, k, R.append_to(_, v)), k) : Maybe<&2, String>}
                  set_key(t, u, k, R.append_to(KV.get(String, t, k), v))
    case R.Strlen{+k}:
      kd => e => e
    case R.Del{ks}:
      loc_key_del(ks, t, u)
    case R.Exists{ks}:
      kd => e => e
    case R.Ping{}:
      kd => e => Empty.absurd({KV.get(String, R.db_of(R.exec(R.Ping{}, t)), "") == KV.get(String, R.db_of(R.exec(R.Ping{}, u)), "") : Maybe<&2, String>}, false_true(kd))
    case R.Echo{m}:
      kd => e => Empty.absurd({KV.get(String, R.db_of(R.exec(R.Echo{m}, t)), "") == KV.get(String, R.db_of(R.exec(R.Echo{m}, u)), "") : Maybe<&2, String>}, false_true(kd))
    case R.MGet{ks}:
      kd => e => Empty.absurd({KV.get(String, R.db_of(R.exec(R.MGet{ks}, t)), "") == KV.get(String, R.db_of(R.exec(R.MGet{ks}, u)), "") : Maybe<&2, String>}, false_true(kd))
    case R.MSet{ps}:
      kd => e => Empty.absurd({KV.get(String, R.db_of(R.exec(R.MSet{ps}, t)), "") == KV.get(String, R.db_of(R.exec(R.MSet{ps}, u)), "") : Maybe<&2, String>}, false_true(kd))
    case R.DbSize{}:
      kd => e => Empty.absurd({KV.get(String, R.db_of(R.exec(R.DbSize{}, t)), "") == KV.get(String, R.db_of(R.exec(R.DbSize{}, u)), "") : Maybe<&2, String>}, false_true(kd))
    case R.FlushAll{}:
      kd => e => Empty.absurd({KV.get(String, R.db_of(R.exec(R.FlushAll{}, t)), "") == KV.get(String, R.db_of(R.exec(R.FlushAll{}, u)), "") : Maybe<&2, String>}, false_true(kd))
    case R.Keys{p}:
      kd => e => Empty.absurd({KV.get(String, R.db_of(R.exec(R.Keys{p}, t)), "") == KV.get(String, R.db_of(R.exec(R.Keys{p}, u)), "") : Maybe<&2, String>}, false_true(kd))
    case R.Bad{r}:
      kd => e => Empty.absurd({KV.get(String, R.db_of(R.exec(R.Bad{r}, t)), "") == KV.get(String, R.db_of(R.exec(R.Bad{r}, u)), "") : Maybe<&2, String>}, false_true(kd))
    case R.SizeAt{x}:
      kd => e => Empty.absurd({KV.get(String, R.db_of(R.exec(R.SizeAt{x}, t)), "") == KV.get(String, R.db_of(R.exec(R.SizeAt{x}, u)), "") : Maybe<&2, String>}, false_true(kd))
    case R.KeysAt{p, x}:
      kd => e => Empty.absurd({KV.get(String, R.db_of(R.exec(R.KeysAt{p, x}, t)), "") == KV.get(String, R.db_of(R.exec(R.KeysAt{p, x}, u)), "") : Maybe<&2, String>}, false_true(kd))
    case R.FlushAt{x}:
      kd => e => Empty.absurd({KV.get(String, R.db_of(R.exec(R.FlushAt{x}, t)), "") == KV.get(String, R.db_of(R.exec(R.FlushAt{x}, u)), "") : Maybe<&2, String>}, false_true(kd))

def writes_del(ks: List<&2, String>, +j: String) -> {keyed(R.Del{ks}) == True{} : Bool} -> {False{} == KV.str_eq(j, key_of(R.Del{ks})) : Bool} -> {Laws.writes(R.Del{ks}, j) == False{} : Bool}:
  match ks:
    case Nil{}:
      kd => nb => Empty.absurd({Laws.writes(R.Del{Nil{}}, j) == False{} : Bool}, false_true(kd))
    case Con{k, Nil{}}:
      kd => nb => %nb : {Bool.or(_, False{}) == False{} : Bool}
                  {==}
    case Con{k, Con{i, rest}}:
      kd => nb => Empty.absurd({Laws.writes(R.Del{Con{k, Con{i, rest}}}, j) == False{} : Bool}, false_true(kd))

def writes_one(c: R.Cmd, +j: String) -> {keyed(c) == True{} : Bool} -> {False{} == KV.str_eq(j, key_of(c)) : Bool} -> {Laws.writes(c, j) == False{} : Bool}:
  match c:
    case R.Get{k}:
      kd => nb => {==}
    case R.Set{k, v}:
      kd => nb => Equal.sym(Bool, False{}, KV.str_eq(j, k), nb)
    case R.SetNX{k, v}:
      kd => nb => Equal.sym(Bool, False{}, KV.str_eq(j, k), nb)
    case R.GetSet{k, v}:
      kd => nb => Equal.sym(Bool, False{}, KV.str_eq(j, k), nb)
    case R.IncrBy{k, by}:
      kd => nb => Equal.sym(Bool, False{}, KV.str_eq(j, k), nb)
    case R.Append{k, v}:
      kd => nb => Equal.sym(Bool, False{}, KV.str_eq(j, k), nb)
    case R.Strlen{k}:
      kd => nb => {==}
    case R.Del{ks}:
      writes_del(ks, j)
    case R.Exists{ks}:
      kd => nb => {==}
    case R.Ping{}:
      kd => nb => Empty.absurd({Laws.writes(R.Ping{}, j) == False{} : Bool}, false_true(kd))
    case R.Echo{m}:
      kd => nb => Empty.absurd({Laws.writes(R.Echo{m}, j) == False{} : Bool}, false_true(kd))
    case R.MGet{ks}:
      kd => nb => Empty.absurd({Laws.writes(R.MGet{ks}, j) == False{} : Bool}, false_true(kd))
    case R.MSet{ps}:
      kd => nb => Empty.absurd({Laws.writes(R.MSet{ps}, j) == False{} : Bool}, false_true(kd))
    case R.DbSize{}:
      kd => nb => Empty.absurd({Laws.writes(R.DbSize{}, j) == False{} : Bool}, false_true(kd))
    case R.FlushAll{}:
      kd => nb => Empty.absurd({Laws.writes(R.FlushAll{}, j) == False{} : Bool}, false_true(kd))
    case R.Keys{p}:
      kd => nb => Empty.absurd({Laws.writes(R.Keys{p}, j) == False{} : Bool}, false_true(kd))
    case R.Bad{r}:
      kd => nb => Empty.absurd({Laws.writes(R.Bad{r}, j) == False{} : Bool}, false_true(kd))

    case R.SizeAt{x}:
      kd => nb => Empty.absurd({Laws.writes(R.SizeAt{x}, j) == False{} : Bool}, false_true(kd))
    case R.KeysAt{p, x}:
      kd => nb => Empty.absurd({Laws.writes(R.KeysAt{p, x}, j) == False{} : Bool}, false_true(kd))
    case R.FlushAt{x}:
      kd => nb => Empty.absurd({Laws.writes(R.FlushAt{x}, j) == False{} : Bool}, false_true(kd))

# a hypothesis about a key, for a key equal to it
def get_at(+t: KV.Trie<String>, +u: KV.Trie<String>, -j: String, -k: String, ejk: {j == k : String}, e: {KV.get(String, t, j) == KV.get(String, u, j) : Maybe<&2, String>}) -> {KV.get(String, t, k) == KV.get(String, u, k) : Maybe<&2, String>}:
  %ejk : {KV.get(String, t, _) == KV.get(String, u, _) : Maybe<&2, String>}
  e

def point_same(+c: R.Cmd, +t: KV.Trie<String>, +u: KV.Trie<String>, +j: String, +kd: {keyed(c) == True{} : Bool}, +ejk: {j == key_of(c) : String}, e: {KV.get(String, t, j) == KV.get(String, u, j) : Maybe<&2, String>}) -> {KV.get(String, R.db_of(R.exec(c, t)), j) == KV.get(String, R.db_of(R.exec(c, u)), j) : Maybe<&2, String>}:
  %Equal.sym(String, j, key_of(c), ejk) : {KV.get(String, R.db_of(R.exec(c, t)), _) == KV.get(String, R.db_of(R.exec(c, u)), _) : Maybe<&2, String>}
  loc_key(c, t, u)(kd)(get_at(t, u, j, key_of(c), ejk, e))

# a command on one key: what a key j reads after it depends only on what
# j read before it
def point_key(+c: R.Cmd, +t: KV.Trie<String>, +u: KV.Trie<String>, +j: String, +kd: {keyed(c) == True{} : Bool}, b: Bool)
  -> {b == KV.str_eq(j, key_of(c)) : Bool}
  -> Reflect(String, j, key_of(c), b)
  -> {KV.get(String, t, j) == KV.get(String, u, j) : Maybe<&2, String>}
  -> {KV.get(String, R.db_of(R.exec(c, t)), j) == KV.get(String, R.db_of(R.exec(c, u)), j) : Maybe<&2, String>}:
  match b:
    case True{}:
      eb => ejk => e => point_same(c, t, u, j, kd, ejk, e)
    case False{}:
      +eb => ne => e => Equal.trans(Maybe<&2, String>, KV.get(String, R.db_of(R.exec(c, t)), j), KV.get(String, t, j), KV.get(String, R.db_of(R.exec(c, u)), j),
                          Laws.frame(c, t, j, writes_one(c, j)(kd)(eb)),
                          Equal.trans(Maybe<&2, String>, KV.get(String, t, j), KV.get(String, u, j), KV.get(String, R.db_of(R.exec(c, u)), j), e,
                            Equal.sym(Maybe<&2, String>, KV.get(String, R.db_of(R.exec(c, u)), j), KV.get(String, u, j), Laws.frame(c, u, j, writes_one(c, j)(kd)(eb)))))

# a delete, or a set, of one key: a key that reads alike in two tries
# reads alike after it
def del_same(+t: KV.Trie<String>, +u: KV.Trie<String>, -k: String, +j: String, +ejk: {j == k : String}) -> {KV.get(String, KV.del(String, t, k), j) == KV.get(String, KV.del(String, u, k), j) : Maybe<&2, String>}:
  Equal.trans(Maybe<&2, String>, KV.get(String, KV.del(String, t, k), j), None{}, KV.get(String, KV.del(String, u, k), j), get_del_eq(t, k, j, ejk), Equal.sym(Maybe<&2, String>, KV.get(String, KV.del(String, u, k), j), None{}, get_del_eq(u, k, j, ejk)))

def del_one_point(+t: KV.Trie<String>, +u: KV.Trie<String>, +k: String, +j: String, c: Bool) -> {c == KV.str_eq(j, k) : Bool} -> Reflect(String, j, k, c) -> {KV.get(String, t, j) == KV.get(String, u, j) : Maybe<&2, String>} -> {KV.get(String, KV.del(String, t, k), j) == KV.get(String, KV.del(String, u, k), j) : Maybe<&2, String>}:
  match c:
    case True{}:
      eb => ejk => e => del_same(t, u, k, j, ejk)
    case False{}:
      +eb => ne => e => Equal.trans(Maybe<&2, String>, KV.get(String, KV.del(String, t, k), j), KV.get(String, t, j), KV.get(String, KV.del(String, u, k), j), Laws.get_del_other(String, t, k, j, Laws.key_eq_false(j, k, Equal.sym(Bool, False{}, KV.str_eq(j, k), eb))),
                          Equal.trans(Maybe<&2, String>, KV.get(String, t, j), KV.get(String, u, j), KV.get(String, KV.del(String, u, k), j), e, Equal.sym(Maybe<&2, String>, KV.get(String, KV.del(String, u, k), j), KV.get(String, u, j), Laws.get_del_other(String, u, k, j, Laws.key_eq_false(j, k, Equal.sym(Bool, False{}, KV.str_eq(j, k), eb))))))

def set_same(+t: KV.Trie<String>, +u: KV.Trie<String>, +k: String, +v: String, +j: String, +ejk: {j == k : String}) -> {KV.get(String, KV.set(String, t, k, v), j) == KV.get(String, KV.set(String, u, k, v), j) : Maybe<&2, String>}:
  %Equal.sym(String, j, k, ejk) : {KV.get(String, KV.set(String, t, k, v), _) == KV.get(String, KV.set(String, u, k, v), _) : Maybe<&2, String>}
  set_key(t, u, k, v)

def set_one_point(+t: KV.Trie<String>, +u: KV.Trie<String>, +k: String, +v: String, +j: String, c: Bool) -> {c == KV.str_eq(j, k) : Bool} -> Reflect(String, j, k, c) -> {KV.get(String, t, j) == KV.get(String, u, j) : Maybe<&2, String>} -> {KV.get(String, KV.set(String, t, k, v), j) == KV.get(String, KV.set(String, u, k, v), j) : Maybe<&2, String>}:
  match c:
    case True{}:
      eb => ejk => e => set_same(t, u, k, v, j, ejk)
    case False{}:
      +eb => ne => e => Equal.trans(Maybe<&2, String>, KV.get(String, KV.set(String, t, k, v), j), KV.get(String, t, j), KV.get(String, KV.set(String, u, k, v), j), Laws.get_set_other(String, t, k, j, v, Laws.key_eq_false(j, k, Equal.sym(Bool, False{}, KV.str_eq(j, k), eb))),
                          Equal.trans(Maybe<&2, String>, KV.get(String, t, j), KV.get(String, u, j), KV.get(String, KV.set(String, u, k, v), j), e, Equal.sym(Maybe<&2, String>, KV.get(String, KV.set(String, u, k, v), j), KV.get(String, u, j), Laws.get_set_other(String, u, k, j, v, Laws.key_eq_false(j, k, Equal.sym(Bool, False{}, KV.str_eq(j, k), eb))))))

def del_point(ks: List<&2, String>, +t: KV.Trie<String>, +u: KV.Trie<String>, +j: String) -> {KV.get(String, t, j) == KV.get(String, u, j) : Maybe<&2, String>} -> {KV.get(String, del_all(ks, t), j) == KV.get(String, del_all(ks, u), j) : Maybe<&2, String>}:
  match ks:
    case Nil{}:
      e => e
    case Con{+k, +rest}:
      e => del_point(rest, KV.del(String, t, k), KV.del(String, u, k), j)(del_one_point(t, u, k, j, KV.str_eq(j, k))({==})(str_refl(j, k))(e))

def mset_point(ps: List<&2, R.KVPair>, +t: KV.Trie<String>, +u: KV.Trie<String>, +j: String) -> {KV.get(String, t, j) == KV.get(String, u, j) : Maybe<&2, String>} -> {KV.get(String, R.mset_pairs(ps, t), j) == KV.get(String, R.mset_pairs(ps, u), j) : Maybe<&2, String>}:
  match ps:
    case Nil{}:
      e => e
    case Con{R.KP{+k, +v}, +rest}:
      e => mset_point(rest, KV.set(String, t, k, v), KV.set(String, u, k, v), j)(set_one_point(t, u, k, v, j, KV.str_eq(j, k))({==})(str_refl(j, k))(e))

# a subtrie emptied: a key under it reads as missing in both tries, and
# a key under another digit as before
def with_child_same(+t: KV.Trie<String>, +u: KV.Trie<String>, +x: KV.Hex, -j: String, +ex: {KV.hex(KV.hash(j)) == x : KV.Hex}) -> {KV.child(String, KV.with_child(String, t, x, KV.empty(String)), KV.hex(KV.hash(j))) == KV.child(String, KV.with_child(String, u, x, KV.empty(String)), KV.hex(KV.hash(j))) : KV.Trie<String>}:
  %Equal.sym(KV.Hex, KV.hex(KV.hash(j)), x, ex) : {KV.child(String, KV.with_child(String, t, x, KV.empty(String)), _) == KV.child(String, KV.with_child(String, u, x, KV.empty(String)), _) : KV.Trie<String>}
  %child_with_same(String, t, x, KV.empty(String)) : {_ == KV.child(String, KV.with_child(String, u, x, KV.empty(String)), x) : KV.Trie<String>}
  child_with_same(String, u, x, KV.empty(String))

def with_other(+t: KV.Trie<String>, +x: KV.Hex, +j: String, +nb: {False{} == KV.hex_eq(KV.hex(KV.hash(j)), x) : Bool}) -> {KV.get(String, KV.with_child(String, t, x, KV.empty(String)), j) == KV.get(String, t, j) : Maybe<&2, String>}:
  get_child(String, KV.with_child(String, t, x, KV.empty(String)), t, j)(Equal.sym(KV.Trie<String>, KV.child(String, t, KV.hex(KV.hash(j))), KV.child(String, KV.with_child(String, t, x, KV.empty(String)), KV.hex(KV.hash(j))), child_with_other(String, t, x, KV.empty(String), KV.hex(KV.hash(j)))(nb)))

def with_point(+t: KV.Trie<String>, +u: KV.Trie<String>, +x: KV.Hex, +j: String, b: Bool) -> {b == KV.hex_eq(KV.hex(KV.hash(j)), x) : Bool} -> {KV.get(String, t, j) == KV.get(String, u, j) : Maybe<&2, String>} -> {KV.get(String, KV.with_child(String, t, x, KV.empty(String)), j) == KV.get(String, KV.with_child(String, u, x, KV.empty(String)), j) : Maybe<&2, String>}:
  match b:
    case True{}:
      eb => e => get_child(String, KV.with_child(String, t, x, KV.empty(String)), KV.with_child(String, u, x, KV.empty(String)), j)(with_child_same(t, u, x, j, hex_eq_sound(KV.hex(KV.hash(j)), x)(Equal.sym(Bool, True{}, KV.hex_eq(KV.hex(KV.hash(j)), x), eb))))
    case False{}:
      +eb => e => Equal.trans(Maybe<&2, String>, KV.get(String, KV.with_child(String, t, x, KV.empty(String)), j), KV.get(String, t, j), KV.get(String, KV.with_child(String, u, x, KV.empty(String)), j), with_other(t, x, j, eb),
                    Equal.trans(Maybe<&2, String>, KV.get(String, t, j), KV.get(String, u, j), KV.get(String, KV.with_child(String, u, x, KV.empty(String)), j), e, Equal.sym(Maybe<&2, String>, KV.get(String, KV.with_child(String, u, x, KV.empty(String)), j), KV.get(String, u, j), with_other(u, x, j, eb))))

def clear_point(xs: List<&2, KV.Hex>, +t: KV.Trie<String>, +u: KV.Trie<String>, +j: String) -> {KV.get(String, t, j) == KV.get(String, u, j) : Maybe<&2, String>} -> {KV.get(String, KV.clear.of(String, xs, t), j) == KV.get(String, KV.clear.of(String, xs, u), j) : Maybe<&2, String>}:
  match xs:
    case Nil{}:
      e => e
    case Con{+x, +rest}:
      e => clear_point(rest, KV.with_child(String, t, x, KV.empty(String)), KV.with_child(String, u, x, KV.empty(String)), j)(with_point(t, u, x, j, KV.hex_eq(KV.hex(KV.hash(j)), x))({==})(e))

# any command: what a key j reads after it depends only on what j read
# before it
def point_cmd(c: R.Cmd, +t: KV.Trie<String>, +u: KV.Trie<String>, +j: String) -> {KV.get(String, t, j) == KV.get(String, u, j) : Maybe<&2, String>} -> {KV.get(String, R.db_of(R.exec(c, t)), j) == KV.get(String, R.db_of(R.exec(c, u)), j) : Maybe<&2, String>}:
  match c:
    case R.Ping{}:
      e => e
    case R.Echo{m}:
      e => e
    case R.Get{k}:
      e => e
    case R.Set{+k, +v}:
      point_key(R.Set{k, v}, t, u, j, {==}, KV.str_eq(j, k))({==})(str_refl(j, k))
    case R.SetNX{+k, +v}:
      point_key(R.SetNX{k, v}, t, u, j, {==}, KV.str_eq(j, k))({==})(str_refl(j, k))
    case R.GetSet{+k, +v}:
      point_key(R.GetSet{k, v}, t, u, j, {==}, KV.str_eq(j, k))({==})(str_refl(j, k))
    case R.Del{+ks}:
      e => %exec_del(ks, t) : {KV.get(String, _, j) == KV.get(String, R.db_of(R.exec(R.Del{ks}, u)), j) : Maybe<&2, String>}
           %exec_del(ks, u) : {KV.get(String, del_all(ks, t), j) == KV.get(String, _, j) : Maybe<&2, String>}
           del_point(ks, t, u, j)(e)
    case R.Exists{ks}:
      e => e
    case R.IncrBy{+k, +by}:
      point_key(R.IncrBy{k, by}, t, u, j, {==}, KV.str_eq(j, k))({==})(str_refl(j, k))
    case R.Append{+k, +v}:
      point_key(R.Append{k, v}, t, u, j, {==}, KV.str_eq(j, k))({==})(str_refl(j, k))
    case R.Strlen{k}:
      e => e
    case R.MGet{ks}:
      e => e
    case R.MSet{+ps}:
      mset_point(ps, t, u, j)
    case R.DbSize{}:
      e => e
    case R.FlushAll{}:
      clear_point(KV.digits(), t, u, j)
    case R.Keys{p}:
      e => e
    case R.Bad{r}:
      e => e
    case R.SizeAt{x}:
      e => e
    case R.KeysAt{p, x}:
      e => e
    case R.FlushAt{+x}:
      with_point(t, u, x, j, KV.hex_eq(KV.hex(KV.hash(j)), x))({==})

def and_true_false(a: Bool) -> {Bool.and(a, True{}) == False{} : Bool} -> {a == False{} : Bool}:
  match a:
    case True{}:
      e => Empty.absurd({True{} == False{} : Bool}, true_false(e))
    case False{}:
      e => {==}

# a key that c2 does not write reads after c1 then c2 as after c1, and
# after c2 then c1 as after c1 too; a key that c2 writes, c1 does not
def commute_at(+c1: R.Cmd, +c2: R.Cmd, +db: KV.Trie<String>, +j: String, b: Bool) -> {b == Laws.writes(c2, j) : Bool} -> {Bool.and(Laws.writes(c1, j), b) == False{} : Bool} -> {KV.get(String, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))), j) == KV.get(String, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))), j) : Maybe<&2, String>}:
  match b:
    case False{}:
      eb => e =>
        +w2 = Equal.sym(Bool, False{}, Laws.writes(c2, j), eb)
        Equal.trans(Maybe<&2, String>, KV.get(String, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))), j), KV.get(String, R.db_of(R.exec(c1, db)), j), KV.get(String, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))), j), Laws.frame(c2, R.db_of(R.exec(c1, db)), j, w2),
          Equal.sym(Maybe<&2, String>, KV.get(String, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))), j), KV.get(String, R.db_of(R.exec(c1, db)), j), point_cmd(c1, R.db_of(R.exec(c2, db)), db, j)(Laws.frame(c2, db, j, w2))))
    case True{}:
      eb => e =>
        +w1 = and_true_false(Laws.writes(c1, j))(e)
        Equal.trans(Maybe<&2, String>, KV.get(String, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))), j), KV.get(String, R.db_of(R.exec(c2, db)), j), KV.get(String, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))), j), point_cmd(c2, R.db_of(R.exec(c1, db)), db, j)(Laws.frame(c1, db, j, w1)),
          Equal.sym(Maybe<&2, String>, KV.get(String, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))), j), KV.get(String, R.db_of(R.exec(c2, db)), j), Laws.frame(c1, R.db_of(R.exec(c2, db)), j, w1)))

def Laws.commute_reads(c1, c2, db, j, e):
  commute_at(c1, c2, db, j, Laws.writes(c2, j))({==})(e)

# A command's reply after another
# --------------------------------

def not_false(a: Bool) -> {Bool.not(a) == False{} : Bool} -> {a == True{} : Bool}:
  match a:
    case True{}:
      e => {==}
    case False{}:
      e => Empty.absurd({False{} == True{} : Bool}, true_false(e))

def exists_after(ks: List<&2, String>, +c2: R.Cmd, +db: KV.Trie<String>) -> {Laws.writes_any(c2, ks) == False{} : Bool} -> {R.exists_keys(ks, R.db_of(R.exec(c2, db))) == R.exists_keys(ks, db) : Nat}:
  match ks:
    case Nil{}:
      e => {==}
    case Con{+k, +rest}:
      +e => %Laws.frame(c2, db, k, or_false_l(Laws.writes(c2, k), Laws.writes_any(c2, rest))(e)) : {Nat.add(Bool.pick(Nat, Maybe.is_some(&2, String, KV.get(String, R.db_of(R.exec(c2, db)), k)), 1n, 0n), R.exists_keys(rest, R.db_of(R.exec(c2, db)))) == Nat.add(Bool.pick(Nat, Maybe.is_some(&2, String, _), 1n, 0n), R.exists_keys(rest, db)) : Nat}
            Equal.cong(Nat, Nat, z => Nat.add(Bool.pick(Nat, Maybe.is_some(&2, String, KV.get(String, R.db_of(R.exec(c2, db)), k)), 1n, 0n), z), R.exists_keys(rest, R.db_of(R.exec(c2, db))), R.exists_keys(rest, db), exists_after(rest, c2, db)(or_false_r(Laws.writes(c2, k), Laws.writes_any(c2, rest))(e)))

def mget_after(ks: List<&2, String>, +c2: R.Cmd, +db: KV.Trie<String>) -> {Laws.writes_any(c2, ks) == False{} : Bool} -> {R.mget_keys(ks, R.db_of(R.exec(c2, db))) == R.mget_keys(ks, db) : List<&2, R.Item>}:
  match ks:
    case Nil{}:
      e => {==}
    case Con{+k, +rest}:
      +e => %Laws.frame(c2, db, k, or_false_l(Laws.writes(c2, k), Laws.writes_any(c2, rest))(e)) : {R.i_get(KV.get(String, R.db_of(R.exec(c2, db)), k)) <> R.mget_keys(rest, R.db_of(R.exec(c2, db))) == R.i_get(_) <> R.mget_keys(rest, db) : List<&2, R.Item>}
            Equal.cong(List<&2, R.Item>, List<&2, R.Item>, z => R.i_get(KV.get(String, R.db_of(R.exec(c2, db)), k)) <> z, R.mget_keys(rest, R.db_of(R.exec(c2, db))), R.mget_keys(rest, db), mget_after(rest, c2, db)(or_false_r(Laws.writes(c2, k), Laws.writes_any(c2, rest))(e)))

# deleting a key after deleting the keys of done
def del_snoc(done: List<&2, String>, -k: String, +x: KV.Trie<String>) -> {del_all(List.append(&2, String, done, [k]), x) == KV.del(String, del_all(done, x), k) : KV.Trie<String>}:
  match done:
    case Nil{}:
      {==}
    case Con{+d, +ds}:
      del_snoc(ds, k, KV.del(String, x, d))

# after the same deletes on both sides, a key c2 does not write reads alike
# in c2's database and in the one before it
def del_agree(+c2: R.Cmd, +db: KV.Trie<String>, +done: List<&2, String>, +k: String, +w: {Laws.writes(c2, k) == False{} : Bool}, b: Bool) -> {b == Laws.any_key(k, done) : Bool} -> {KV.get(String, del_all(done, R.db_of(R.exec(c2, db))), k) == KV.get(String, del_all(done, db), k) : Maybe<&2, String>}:
  match b:
    case True{}:
      +eb => Equal.trans(Maybe<&2, String>, KV.get(String, del_all(done, R.db_of(R.exec(c2, db))), k), None{}, KV.get(String, del_all(done, db), k), del_all_effect(done, R.db_of(R.exec(c2, db)), k)(Equal.sym(Bool, True{}, Laws.any_key(k, done), eb)), Equal.sym(Maybe<&2, String>, KV.get(String, del_all(done, db), k), None{}, del_all_effect(done, db, k)(Equal.sym(Bool, True{}, Laws.any_key(k, done), eb))))
    case False{}:
      +eb => Equal.trans(Maybe<&2, String>, KV.get(String, del_all(done, R.db_of(R.exec(c2, db))), k), KV.get(String, R.db_of(R.exec(c2, db)), k), KV.get(String, del_all(done, db), k), del_all_frame(done, R.db_of(R.exec(c2, db)), k)(Equal.sym(Bool, False{}, Laws.any_key(k, done), eb)),
               Equal.trans(Maybe<&2, String>, KV.get(String, R.db_of(R.exec(c2, db)), k), KV.get(String, db, k), KV.get(String, del_all(done, db), k), Laws.frame(c2, db, k, w), Equal.sym(Maybe<&2, String>, KV.get(String, del_all(done, db), k), KV.get(String, db, k), del_all_frame(done, db, k)(Equal.sym(Bool, False{}, Laws.any_key(k, done), eb)))))

# DEL counts the same keys after c2, when c2 writes none of them: the
# keys of done are deleted on both sides
def dcount(+c2: R.Cmd, +db: KV.Trie<String>, ks: List<&2, String>, +done: List<&2, String>) -> {Laws.writes_any(c2, ks) == False{} : Bool} -> {del_count(ks, del_all(done, R.db_of(R.exec(c2, db)))) == del_count(ks, del_all(done, db)) : Nat}:
  match ks:
    case Nil{}:
      e => {==}
    case Con{+k, +rest}:
      +e =>
        +ag = del_agree(c2, db, done, k, or_false_l(Laws.writes(c2, k), Laws.writes_any(c2, rest))(e), Laws.any_key(k, done))({==})
        %ag : {Bool.pick(Nat, KV.has(String, del_all(done, R.db_of(R.exec(c2, db))), k), 1n+del_count(rest, KV.del(String, del_all(done, R.db_of(R.exec(c2, db))), k)), del_count(rest, KV.del(String, del_all(done, R.db_of(R.exec(c2, db))), k))) == Bool.pick(Nat, Maybe.is_some(&2, String, _), 1n+del_count(rest, KV.del(String, del_all(done, db), k)), del_count(rest, KV.del(String, del_all(done, db), k))) : Nat}
        %del_snoc(done, k, R.db_of(R.exec(c2, db))) : {Bool.pick(Nat, KV.has(String, del_all(done, R.db_of(R.exec(c2, db))), k), 1n+del_count(rest, _), del_count(rest, _)) == Bool.pick(Nat, KV.has(String, del_all(done, R.db_of(R.exec(c2, db))), k), 1n+del_count(rest, KV.del(String, del_all(done, db), k)), del_count(rest, KV.del(String, del_all(done, db), k))) : Nat}
        %del_snoc(done, k, db) : {Bool.pick(Nat, KV.has(String, del_all(done, R.db_of(R.exec(c2, db))), k), 1n+del_count(rest, del_all(List.append(&2, String, done, [k]), R.db_of(R.exec(c2, db)))), del_count(rest, del_all(List.append(&2, String, done, [k]), R.db_of(R.exec(c2, db))))) == Bool.pick(Nat, KV.has(String, del_all(done, R.db_of(R.exec(c2, db))), k), 1n+del_count(rest, _), del_count(rest, _)) : Nat}
        Equal.cong(Nat, Nat, z => Bool.pick(Nat, KV.has(String, del_all(done, R.db_of(R.exec(c2, db))), k), 1n+z, z), del_count(rest, del_all(List.append(&2, String, done, [k]), R.db_of(R.exec(c2, db)))), del_count(rest, del_all(List.append(&2, String, done, [k]), db)), dcount(c2, db, rest, List.append(&2, String, done, [k]))(or_false_r(Laws.writes(c2, k), Laws.writes_any(c2, rest))(e)))

def del_reply_after(+ks: List<&2, String>, +c2: R.Cmd, +db: KV.Trie<String>) -> {Laws.writes_any(c2, ks) == False{} : Bool} -> {R.reply_of(R.exec(R.Del{ks}, R.db_of(R.exec(c2, db)))) == R.reply_of(R.exec(R.Del{ks}, db)) : R.Reply}:
  e => %del_keys_eq(ks, R.db_of(R.exec(c2, db))) : {R.reply_of(R.del_reply(_)) == R.reply_of(R.exec(R.Del{ks}, db)) : R.Reply}
       %del_keys_eq(ks, db) : {R.r_int(del_count(ks, R.db_of(R.exec(c2, db)))) == R.reply_of(R.del_reply(_)) : R.Reply}
       Equal.cong(Nat, R.Reply, n => R.r_int(n), del_count(ks, R.db_of(R.exec(c2, db))), del_count(ks, db), dcount(c2, db, ks, Nil{})(e))

# a command answers the same after c2 when c2 writes nothing it reads
def reply_after(c1: R.Cmd, +c2: R.Cmd, +db: KV.Trie<String>) -> {Laws.disturbs(c2, c1) == False{} : Bool} -> {R.reply_of(R.exec(c1, R.db_of(R.exec(c2, db)))) == R.reply_of(R.exec(c1, db)) : R.Reply}:
  match c1:
    case R.Ping{}:
      e => {==}
    case R.Echo{m}:
      e => {==}
    case R.Get{+k}:
      e => loc_reply(R.Get{k}, R.db_of(R.exec(c2, db)), db)({==})(Laws.frame(c2, db, k, e))
    case R.Set{k, v}:
      e => {==}
    case R.SetNX{+k, +v}:
      e => loc_reply(R.SetNX{k, v}, R.db_of(R.exec(c2, db)), db)({==})(Laws.frame(c2, db, k, e))
    case R.GetSet{+k, +v}:
      e => loc_reply(R.GetSet{k, v}, R.db_of(R.exec(c2, db)), db)({==})(Laws.frame(c2, db, k, e))
    case R.Del{+ks}:
      del_reply_after(ks, c2, db)
    case R.Exists{+ks}:
      e => Equal.cong(Nat, R.Reply, z => R.r_int(z), R.exists_keys(ks, R.db_of(R.exec(c2, db))), R.exists_keys(ks, db), exists_after(ks, c2, db)(e))
    case R.IncrBy{+k, +by}:
      e => loc_reply(R.IncrBy{k, by}, R.db_of(R.exec(c2, db)), db)({==})(Laws.frame(c2, db, k, e))
    case R.Append{+k, +v}:
      e => loc_reply(R.Append{k, v}, R.db_of(R.exec(c2, db)), db)({==})(Laws.frame(c2, db, k, e))
    case R.Strlen{+k}:
      e => loc_reply(R.Strlen{k}, R.db_of(R.exec(c2, db)), db)({==})(Laws.frame(c2, db, k, e))
    case R.MGet{+ks}:
      e => Equal.cong(List<&2, R.Item>, R.Reply, z => R.RArray{z}, R.mget_keys(ks, R.db_of(R.exec(c2, db))), R.mget_keys(ks, db), mget_after(ks, c2, db)(e))
    case R.MSet{ps}:
      e => {==}
    case R.DbSize{}:
      e => %Equal.sym(KV.Trie<String>, R.db_of(R.exec(c2, db)), db, Laws.reads_keep_db(c2, db, not_false(Laws.is_read(c2))(e))) : {R.reply_of(R.exec(R.DbSize{}, _)) == R.reply_of(R.exec(R.DbSize{}, db)) : R.Reply}
           {==}
    case R.FlushAll{}:
      e => {==}
    case R.Keys{p}:
      e => %Equal.sym(KV.Trie<String>, R.db_of(R.exec(c2, db)), db, Laws.reads_keep_db(c2, db, not_false(Laws.is_read(c2))(e))) : {R.reply_of(R.exec(R.Keys{p}, _)) == R.reply_of(R.exec(R.Keys{p}, db)) : R.Reply}
           {==}
    case R.Bad{r}:
      e => {==}
    case R.SizeAt{x}:
      e => %Equal.sym(KV.Trie<String>, R.db_of(R.exec(c2, db)), db, Laws.reads_keep_db(c2, db, not_false(Laws.is_read(c2))(e))) : {R.reply_of(R.exec(R.SizeAt{x}, _)) == R.reply_of(R.exec(R.SizeAt{x}, db)) : R.Reply}
           {==}
    case R.KeysAt{p, x}:
      e => %Equal.sym(KV.Trie<String>, R.db_of(R.exec(c2, db)), db, Laws.reads_keep_db(c2, db, not_false(Laws.is_read(c2))(e))) : {R.reply_of(R.exec(R.KeysAt{p, x}, _)) == R.reply_of(R.exec(R.KeysAt{p, x}, db)) : R.Reply}
           {==}
    case R.FlushAt{x}:
      e => {==}

def Laws.commute_reply(c1, c2, db, e):
  reply_after(c1, c2, db)(e)

# so two commands that do not disturb each other answer the same in
# either order
def commute_go(+c1: R.Cmd, +c2: R.Cmd, +db: KV.Trie<String>, +e: {Bool.or(Laws.disturbs(c1, c2), Laws.disturbs(c2, c1)) == False{} : Bool}) -> {Laws.replies(R.exec_all([c2, c1], db)) == List.reverse(&2, R.Reply, Laws.replies(R.exec_all([c1, c2], db))) : List<&2, R.Reply>}:
  %exec_all_run([c2, c1], db) : {Laws.replies(_) == List.reverse(&2, R.Reply, Laws.replies(R.exec_all([c1, c2], db))) : List<&2, R.Reply>}
  %exec_all_run([c1, c2], db) : {Laws.replies(run([c2, c1], db)) == List.reverse(&2, R.Reply, Laws.replies(_)) : List<&2, R.Reply>}
  %reply_after(c1, c2, db)(or_false_r(Laws.disturbs(c1, c2), Laws.disturbs(c2, c1))(e)) : {[R.reply_of(R.exec(c2, db)), R.reply_of(R.exec(c1, R.db_of(R.exec(c2, db))))] == [R.reply_of(R.exec(c2, R.db_of(R.exec(c1, db)))), _] : List<&2, R.Reply>}
  %reply_after(c2, c1, db)(or_false_l(Laws.disturbs(c1, c2), Laws.disturbs(c2, c1))(e)) : {[_, R.reply_of(R.exec(c1, R.db_of(R.exec(c2, db))))] == [R.reply_of(R.exec(c2, R.db_of(R.exec(c1, db)))), R.reply_of(R.exec(c1, R.db_of(R.exec(c2, db))))] : List<&2, R.Reply>}
  {==}

def Laws.commute(c1, c2, db, e):
  commute_go(c1, c2, db, e)
# A swap inside a batch
# ---------------------
# After c1 then c2 (A) and c2 then c1 (B), the rest of the batch runs on
# two databases that read alike at every key. tw(H, d) is the run H,
# newest first, on d; eq_at is the claim at one key after any such run,
# a top-level function called at whatever key a step needs.

# A key that c1 writes, c2 does not write (clash_at): a key DEL or MSET
# writes is one of their keys, which c2 does not write
def or_clash(+c2: R.Cmd, +j: String, +k: String, -rest: List<&2, String>, +w: {Laws.writes(c2, k) == False{} : Bool}, b: Bool) -> {b == KV.str_eq(j, k) : Bool} -> Reflect(String, j, k, b) -> {Bool.and(Laws.any_key(j, rest), Laws.writes(c2, j)) == False{} : Bool} -> {Bool.and(Bool.or(b, Laws.any_key(j, rest)), Laws.writes(c2, j)) == False{} : Bool}:
  match b:
    case True{}:
      eb => ejk => ih => %Equal.sym(String, j, k, ejk) : {Laws.writes(c2, _) == False{} : Bool}
                         w
    case False{}:
      eb => ne => ih => ih

def pair_clash(+c2: R.Cmd, +j: String, +k: String, -rest: List<&2, R.KVPair>, +w: {Laws.writes(c2, k) == False{} : Bool}, b: Bool) -> {b == KV.str_eq(j, k) : Bool} -> Reflect(String, j, k, b) -> {Bool.and(Laws.any_pair(j, rest), Laws.writes(c2, j)) == False{} : Bool} -> {Bool.and(Bool.or(b, Laws.any_pair(j, rest)), Laws.writes(c2, j)) == False{} : Bool}:
  match b:
    case True{}:
      eb => ejk => ih => %Equal.sym(String, j, k, ejk) : {Laws.writes(c2, _) == False{} : Bool}
                         w
    case False{}:
      eb => ne => ih => ih

def pairs_clash(+c2: R.Cmd, +j: String, ps: List<&2, R.KVPair>) -> {Laws.writes_pairs(c2, ps) == False{} : Bool} -> {Bool.and(Laws.any_pair(j, ps), Laws.writes(c2, j)) == False{} : Bool}:
  match ps:
    case Nil{}:
      e => {==}
    case Con{R.KP{+k, v}, +rest}:
      +e => pair_clash(c2, j, k, rest, or_false_l(Laws.writes(c2, k), Laws.writes_pairs(c2, rest))(e), KV.str_eq(j, k))({==})(str_refl(j, k))(pairs_clash(c2, j, rest)(or_false_r(Laws.writes(c2, k), Laws.writes_pairs(c2, rest))(e)))

# a command that only reads writes no key
def read_writes(c: R.Cmd, +j: String) -> {Laws.is_read(c) == True{} : Bool} -> {Laws.writes(c, j) == False{} : Bool}:
  match c:
    case R.Ping{}:
      e => {==}
    case R.Echo{m}:
      e => {==}
    case R.Get{k}:
      e => {==}
    case R.Set{k, v}:
      e => Empty.absurd({Laws.writes(R.Set{k, v}, j) == False{} : Bool}, false_true(e))
    case R.SetNX{k, v}:
      e => Empty.absurd({Laws.writes(R.SetNX{k, v}, j) == False{} : Bool}, false_true(e))
    case R.GetSet{k, v}:
      e => Empty.absurd({Laws.writes(R.GetSet{k, v}, j) == False{} : Bool}, false_true(e))
    case R.Del{ks}:
      e => Empty.absurd({Laws.writes(R.Del{ks}, j) == False{} : Bool}, false_true(e))
    case R.Exists{ks}:
      e => {==}
    case R.IncrBy{k, by}:
      e => Empty.absurd({Laws.writes(R.IncrBy{k, by}, j) == False{} : Bool}, false_true(e))
    case R.Append{k, v}:
      e => Empty.absurd({Laws.writes(R.Append{k, v}, j) == False{} : Bool}, false_true(e))
    case R.Strlen{k}:
      e => {==}
    case R.MGet{ks}:
      e => {==}
    case R.MSet{ps}:
      e => Empty.absurd({Laws.writes(R.MSet{ps}, j) == False{} : Bool}, false_true(e))
    case R.DbSize{}:
      e => {==}
    case R.FlushAll{}:
      e => Empty.absurd({Laws.writes(R.FlushAll{}, j) == False{} : Bool}, false_true(e))
    case R.Keys{p}:
      e => {==}
    case R.Bad{r}:
      e => {==}
    case R.SizeAt{x}:
      e => {==}
    case R.KeysAt{p, x}:
      e => {==}
    case R.FlushAt{x}:
      e => Empty.absurd({Laws.writes(R.FlushAt{x}, j) == False{} : Bool}, false_true(e))

def and_false_r(a: Bool, -b: Bool) -> {b == False{} : Bool} -> {Bool.and(a, b) == False{} : Bool}:
  match a:
    case True{}:
      e => e
    case False{}:
      e => {==}

def key_clash(+c2: R.Cmd, +j: String, +k: String, +w: {Laws.writes(c2, k) == False{} : Bool}, b: Bool) -> {b == KV.str_eq(j, k) : Bool} -> Reflect(String, j, k, b) -> {Bool.and(b, Laws.writes(c2, j)) == False{} : Bool}:
  match b:
    case True{}:
      eb => ejk => %Equal.sym(String, j, k, ejk) : {Laws.writes(c2, _) == False{} : Bool}
                   w
    case False{}:
      eb => ne => {==}

def any_clash(+c2: R.Cmd, +j: String, ks: List<&2, String>) -> {Laws.writes_any(c2, ks) == False{} : Bool} -> {Bool.and(Laws.any_key(j, ks), Laws.writes(c2, j)) == False{} : Bool}:
  match ks:
    case Nil{}:
      e => {==}
    case Con{+k, +rest}:
      +e => or_clash(c2, j, k, rest, or_false_l(Laws.writes(c2, k), Laws.writes_any(c2, rest))(e), KV.str_eq(j, k))({==})(str_refl(j, k))(any_clash(c2, j, rest)(or_false_r(Laws.writes(c2, k), Laws.writes_any(c2, rest))(e)))

# a key that c2 does not write in common with c1 is written by at most
# one of them
def clash_at(c1: R.Cmd, +c2: R.Cmd, +j: String) -> {Laws.clash(c2, c1) == False{} : Bool} -> {Bool.and(Laws.writes(c1, j), Laws.writes(c2, j)) == False{} : Bool}:
  match c1:
    case R.Ping{}:
      e => {==}
    case R.Echo{m}:
      e => {==}
    case R.Get{k}:
      e => {==}
    case R.Set{+k, +v}:
      e => key_clash(c2, j, k, e, KV.str_eq(j, k))({==})(str_refl(j, k))
    case R.SetNX{+k, +v}:
      e => key_clash(c2, j, k, e, KV.str_eq(j, k))({==})(str_refl(j, k))
    case R.GetSet{+k, +v}:
      e => key_clash(c2, j, k, e, KV.str_eq(j, k))({==})(str_refl(j, k))
    case R.Del{+ks}:
      any_clash(c2, j, ks)
    case R.Exists{ks}:
      e => {==}
    case R.IncrBy{+k, +by}:
      e => key_clash(c2, j, k, e, KV.str_eq(j, k))({==})(str_refl(j, k))
    case R.Append{+k, +v}:
      e => key_clash(c2, j, k, e, KV.str_eq(j, k))({==})(str_refl(j, k))
    case R.Strlen{k}:
      e => {==}
    case R.MGet{ks}:
      e => {==}
    case R.MSet{+ps}:
      pairs_clash(c2, j, ps)
    case R.DbSize{}:
      e => {==}
    case R.FlushAll{}:
      e => read_writes(c2, j)(not_false(Laws.is_read(c2))(e))
    case R.Keys{p}:
      e => {==}
    case R.Bad{r}:
      e => {==}
    case R.SizeAt{x}:
      e => {==}
    case R.KeysAt{p, x}:
      e => {==}
    case R.FlushAt{+x}:
      e => and_false_r(KV.hex_eq(KV.hex(KV.hash(j)), x), Laws.writes(c2, j))(read_writes(c2, j)(not_false(Laws.is_read(c2))(e)))

def tw(H: List<&2, R.Cmd>, d: KV.Trie<String>) -> KV.Trie<String>:
  match H:
    case Nil{}:
      d
    case Con{+c, older}:
      R.db_of(R.exec(c, tw(older, d)))

# after any run H, every key reads alike on both sides
def eq_at(+c1: R.Cmd, +c2: R.Cmd, +db: KV.Trie<String>, H: List<&2, R.Cmd>, +j: String, +e: {Laws.clash(c2, c1) == False{} : Bool}) -> {KV.get(String, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))), j) == KV.get(String, tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db))))), j) : Maybe<&2, String>}:
  match H:
    case Nil{}:
      Laws.commute_reads(c1, c2, db, j, clash_at(c1, c2, j)(e))
    case Con{+c, +older}:
      point_cmd(c, tw(older, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))), tw(older, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db))))), j)(eq_at(c1, c2, db, older, j, e))

def exists_tw(+c1: R.Cmd, +c2: R.Cmd, +db: KV.Trie<String>, +H: List<&2, R.Cmd>, +e: {Laws.clash(c2, c1) == False{} : Bool}, ks: List<&2, String>) -> {R.exists_keys(ks, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))))) == R.exists_keys(ks, tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))))) : Nat}:
  match ks:
    case Nil{}:
      {==}
    case Con{+k, +rest}:
      %eq_at(c1, c2, db, H, k, e) : {Nat.add(Bool.pick(Nat, Maybe.is_some(&2, String, KV.get(String, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))), k)), 1n, 0n), R.exists_keys(rest, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))))) == Nat.add(Bool.pick(Nat, Maybe.is_some(&2, String, _), 1n, 0n), R.exists_keys(rest, tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db))))))) : Nat}
      Equal.cong(Nat, Nat, z => Nat.add(Bool.pick(Nat, Maybe.is_some(&2, String, KV.get(String, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))), k)), 1n, 0n), z), R.exists_keys(rest, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))))), R.exists_keys(rest, tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))))), exists_tw(c1, c2, db, H, e, rest))

def mget_tw(+c1: R.Cmd, +c2: R.Cmd, +db: KV.Trie<String>, +H: List<&2, R.Cmd>, +e: {Laws.clash(c2, c1) == False{} : Bool}, ks: List<&2, String>) -> {R.mget_keys(ks, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))))) == R.mget_keys(ks, tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))))) : List<&2, R.Item>}:
  match ks:
    case Nil{}:
      {==}
    case Con{+k, +rest}:
      %eq_at(c1, c2, db, H, k, e) : {R.i_get(KV.get(String, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))), k)) <> R.mget_keys(rest, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))))) == R.i_get(_) <> R.mget_keys(rest, tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))))) : List<&2, R.Item>}
      Equal.cong(List<&2, R.Item>, List<&2, R.Item>, z => R.i_get(KV.get(String, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))), k)) <> z, R.mget_keys(rest, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))))), R.mget_keys(rest, tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))))), mget_tw(c1, c2, db, H, e, rest))

def dcount_tw(+c1: R.Cmd, +c2: R.Cmd, +db: KV.Trie<String>, +H: List<&2, R.Cmd>, +e: {Laws.clash(c2, c1) == False{} : Bool}, ks: List<&2, String>, +done: List<&2, String>) -> {del_count(ks, del_all(done, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))))) == del_count(ks, del_all(done, tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db))))))) : Nat}:
  match ks:
    case Nil{}:
      {==}
    case Con{+k, +rest}:
      %del_point(done, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))), tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db))))), k)(eq_at(c1, c2, db, H, k, e)) : {Bool.pick(Nat, KV.has(String, del_all(done, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))))), k), 1n+del_count(rest, KV.del(String, del_all(done, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))))), k)), del_count(rest, KV.del(String, del_all(done, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))))), k))) == Bool.pick(Nat, Maybe.is_some(&2, String, _), 1n+del_count(rest, KV.del(String, del_all(done, tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))))), k)), del_count(rest, KV.del(String, del_all(done, tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))))), k))) : Nat}
      %del_snoc(done, k, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))))) : {Bool.pick(Nat, KV.has(String, del_all(done, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))))), k), 1n+del_count(rest, _), del_count(rest, _)) == Bool.pick(Nat, KV.has(String, del_all(done, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))))), k), 1n+del_count(rest, KV.del(String, del_all(done, tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))))), k)), del_count(rest, KV.del(String, del_all(done, tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))))), k))) : Nat}
      %del_snoc(done, k, tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))))) : {Bool.pick(Nat, KV.has(String, del_all(done, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))))), k), 1n+del_count(rest, del_all(List.append(&2, String, done, [k]), tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))))), del_count(rest, del_all(List.append(&2, String, done, [k]), tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))))))) == Bool.pick(Nat, KV.has(String, del_all(done, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))))), k), 1n+del_count(rest, _), del_count(rest, _)) : Nat}
      Equal.cong(Nat, Nat, z => Bool.pick(Nat, KV.has(String, del_all(done, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))))), k), 1n+z, z), del_count(rest, del_all(List.append(&2, String, done, [k]), tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))))), del_count(rest, del_all(List.append(&2, String, done, [k]), tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db))))))), dcount_tw(c1, c2, db, H, e, rest, List.append(&2, String, done, [k])))

# a command whose reply depends only on what keys read answers alike on
# both sides
def rep_tw(+c1: R.Cmd, +c2: R.Cmd, +db: KV.Trie<String>, +H: List<&2, R.Cmd>, +e: {Laws.clash(c2, c1) == False{} : Bool}, c: R.Cmd) -> {Laws.keywise(c) == True{} : Bool} -> {R.reply_of(R.exec(c, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))))) == R.reply_of(R.exec(c, tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db))))))) : R.Reply}:
  match c:
    case R.Ping{}:
      kw => {==}
    case R.Echo{m}:
      kw => {==}
    case R.Get{+k}:
      kw => loc_reply(R.Get{k}, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))), tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db))))))({==})(eq_at(c1, c2, db, H, k, e))
    case R.Set{k, v}:
      kw => {==}
    case R.SetNX{+k, +v}:
      kw => loc_reply(R.SetNX{k, v}, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))), tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db))))))({==})(eq_at(c1, c2, db, H, k, e))
    case R.GetSet{+k, +v}:
      kw => loc_reply(R.GetSet{k, v}, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))), tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db))))))({==})(eq_at(c1, c2, db, H, k, e))
    case R.Del{+ks}:
      kw => %del_keys_eq(ks, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))))) : {R.reply_of(R.del_reply(_)) == R.reply_of(R.exec(R.Del{ks}, tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db))))))) : R.Reply}
            %del_keys_eq(ks, tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))))) : {R.r_int(del_count(ks, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))))) == R.reply_of(R.del_reply(_)) : R.Reply}
            Equal.cong(Nat, R.Reply, z => R.r_int(z), del_count(ks, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))))), del_count(ks, tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))))), dcount_tw(c1, c2, db, H, e, ks, Nil{}))
    case R.Exists{+ks}:
      kw => Equal.cong(Nat, R.Reply, z => R.r_int(z), R.exists_keys(ks, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))))), R.exists_keys(ks, tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))))), exists_tw(c1, c2, db, H, e, ks))
    case R.IncrBy{+k, +by}:
      kw => loc_reply(R.IncrBy{k, by}, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))), tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db))))))({==})(eq_at(c1, c2, db, H, k, e))
    case R.Append{+k, +v}:
      kw => loc_reply(R.Append{k, v}, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))), tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db))))))({==})(eq_at(c1, c2, db, H, k, e))
    case R.Strlen{+k}:
      kw => loc_reply(R.Strlen{k}, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))), tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db))))))({==})(eq_at(c1, c2, db, H, k, e))
    case R.MGet{+ks}:
      kw => Equal.cong(List<&2, R.Item>, R.Reply, z => R.RArray{z}, R.mget_keys(ks, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))))), R.mget_keys(ks, tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))))), mget_tw(c1, c2, db, H, e, ks))
    case R.MSet{ps}:
      kw => {==}
    case R.DbSize{}:
      kw => Empty.absurd({R.reply_of(R.exec(R.DbSize{}, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))))) == R.reply_of(R.exec(R.DbSize{}, tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db))))))) : R.Reply}, false_true(kw))
    case R.FlushAll{}:
      kw => {==}
    case R.Keys{p}:
      kw => Empty.absurd({R.reply_of(R.exec(R.Keys{p}, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))))) == R.reply_of(R.exec(R.Keys{p}, tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db))))))) : R.Reply}, false_true(kw))
    case R.Bad{r}:
      kw => {==}
    case R.SizeAt{x}:
      kw => Empty.absurd({R.reply_of(R.exec(R.SizeAt{x}, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))))) == R.reply_of(R.exec(R.SizeAt{x}, tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db))))))) : R.Reply}, false_true(kw))
    case R.KeysAt{p, x}:
      kw => Empty.absurd({R.reply_of(R.exec(R.KeysAt{p, x}, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))))) == R.reply_of(R.exec(R.KeysAt{p, x}, tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db))))))) : R.Reply}, false_true(kw))
    case R.FlushAt{x}:
      kw => {==}

# the rest of the batch answers alike on both sides
def rep_run(+c1: R.Cmd, +c2: R.Cmd, +db: KV.Trie<String>, +e: {Laws.clash(c2, c1) == False{} : Bool}, cs: List<&2, R.Cmd>, +H: List<&2, R.Cmd>) -> {Laws.keywise_all(cs) == True{} : Bool} -> {rfst(run(cs, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))))) == rfst(run(cs, tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db))))))) : List<&2, R.Reply>}:
  match cs:
    case Nil{}:
      kw => {==}
    case Con{+c, +rest}:
      +kw =>
        %eta_l(run(rest, tw(Con{c, H}, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))))) : {rfst(R.exec_all.cons(R.reply_of(R.exec(c, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))))), _)) == rfst(run(Con{c, rest}, tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db))))))) : List<&2, R.Reply>}
        %eta_l(run(rest, tw(Con{c, H}, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db))))))) : {R.reply_of(R.exec(c, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))))) <> rfst(run(rest, tw(Con{c, H}, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))))) == rfst(R.exec_all.cons(R.reply_of(R.exec(c, tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db))))))), _)) : List<&2, R.Reply>}
        %rep_tw(c1, c2, db, H, e, c)(and_l(Laws.keywise(c), Laws.keywise_all(rest))(kw)) : {R.reply_of(R.exec(c, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))))) <> rfst(run(rest, tw(Con{c, H}, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))))) == _ <> rfst(run(rest, tw(Con{c, H}, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db))))))) : List<&2, R.Reply>}
        Equal.cong(List<&2, R.Reply>, List<&2, R.Reply>, z => R.reply_of(R.exec(c, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))))) <> z, rfst(run(rest, tw(Con{c, H}, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))))), rfst(run(rest, tw(Con{c, H}, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db))))))), rep_run(c1, c2, db, e, rest, Con{c, H})(and_r(Laws.keywise(c), Laws.keywise_all(rest))(kw)))

# the database after a run of cs after H on d
def tw_rev(cs: List<&2, R.Cmd>, +H: List<&2, R.Cmd>, +d: KV.Trie<String>) -> {rsnd(run(cs, tw(H, d))) == tw(List.reverse.go(&2, R.Cmd, cs, H), d) : KV.Trie<String>}:
  match cs:
    case Nil{}:
      {==}
    case Con{+c, +rest}:
      %eta_l(run(rest, R.db_of(R.exec(c, tw(H, d))))) : {rsnd(R.exec_all.cons(R.reply_of(R.exec(c, tw(H, d))), _)) == tw(List.reverse.go(&2, R.Cmd, rest, Con{c, H}), d) : KV.Trie<String>}
      tw_rev(rest, Con{c, H}, d)

def swap_go(+c1: R.Cmd, +c2: R.Cmd, +cs: List<&2, R.Cmd>, +db: KV.Trie<String>, +e1: {Laws.interferes(c1, c2) == False{} : Bool}, +e2: {Laws.keywise_all(cs) == True{} : Bool}) -> {Laws.replies(R.exec_all(Con{c2, Con{c1, cs}}, db)) == Laws.swap2(Laws.replies(R.exec_all(Con{c1, Con{c2, cs}}, db))) : List<&2, R.Reply>}:
  +nd = or_false_l(Bool.or(Laws.disturbs(c1, c2), Laws.disturbs(c2, c1)), Laws.clash(c2, c1))(e1)
  +nc = or_false_r(Bool.or(Laws.disturbs(c1, c2), Laws.disturbs(c2, c1)), Laws.clash(c2, c1))(e1)
  %exec_all_run(Con{c2, Con{c1, cs}}, db) : {Laws.replies(_) == Laws.swap2(Laws.replies(R.exec_all(Con{c1, Con{c2, cs}}, db))) : List<&2, R.Reply>}
  %exec_all_run(Con{c1, Con{c2, cs}}, db) : {Laws.replies(run(Con{c2, Con{c1, cs}}, db)) == Laws.swap2(Laws.replies(_)) : List<&2, R.Reply>}
  %eta_l(run(cs, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))))) : {Laws.replies(R.exec_all.cons(R.reply_of(R.exec(c2, db)), R.exec_all.cons(R.reply_of(R.exec(c1, R.db_of(R.exec(c2, db)))), _))) == Laws.swap2(Laws.replies(run(Con{c1, Con{c2, cs}}, db))) : List<&2, R.Reply>}
  %eta_l(run(cs, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))))) : {R.reply_of(R.exec(c2, db)) <> R.reply_of(R.exec(c1, R.db_of(R.exec(c2, db)))) <> rfst(run(cs, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))))) == Laws.swap2(Laws.replies(R.exec_all.cons(R.reply_of(R.exec(c1, db)), R.exec_all.cons(R.reply_of(R.exec(c2, R.db_of(R.exec(c1, db)))), _)))) : List<&2, R.Reply>}
  %reply_after(c1, c2, db)(or_false_r(Laws.disturbs(c1, c2), Laws.disturbs(c2, c1))(nd)) : {R.reply_of(R.exec(c2, db)) <> R.reply_of(R.exec(c1, R.db_of(R.exec(c2, db)))) <> rfst(run(cs, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))))) == R.reply_of(R.exec(c2, R.db_of(R.exec(c1, db)))) <> _ <> rfst(run(cs, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))))) : List<&2, R.Reply>}
  %reply_after(c2, c1, db)(or_false_l(Laws.disturbs(c1, c2), Laws.disturbs(c2, c1))(nd)) : {_ <> R.reply_of(R.exec(c1, R.db_of(R.exec(c2, db)))) <> rfst(run(cs, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))))) == R.reply_of(R.exec(c2, R.db_of(R.exec(c1, db)))) <> R.reply_of(R.exec(c1, R.db_of(R.exec(c2, db)))) <> rfst(run(cs, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))))) : List<&2, R.Reply>}
  %rep_run(c1, c2, db, nc, cs, Nil{})(e2) : {R.reply_of(R.exec(c2, R.db_of(R.exec(c1, db)))) <> R.reply_of(R.exec(c1, R.db_of(R.exec(c2, db)))) <> _ == R.reply_of(R.exec(c2, R.db_of(R.exec(c1, db)))) <> R.reply_of(R.exec(c1, R.db_of(R.exec(c2, db)))) <> rfst(run(cs, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))))) : List<&2, R.Reply>}
  {==}

def Laws.swap_replies(c1, c2, cs, db, e1, e2):
  swap_go(c1, c2, cs, db, e1, e2)

def Laws.swap_reads(c1, c2, cs, db, j, e):
  %exec_all_run(Con{c2, Con{c1, cs}}, db) : {KV.get(String, Laws.final(_), j) == KV.get(String, Laws.final(R.exec_all(Con{c1, Con{c2, cs}}, db)), j) : Maybe<&2, String>}
  %exec_all_run(Con{c1, Con{c2, cs}}, db) : {KV.get(String, Laws.final(run(Con{c2, Con{c1, cs}}, db)), j) == KV.get(String, Laws.final(_), j) : Maybe<&2, String>}
  %eta_l(run(cs, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))))) : {KV.get(String, Laws.final(R.exec_all.cons(R.reply_of(R.exec(c2, db)), R.exec_all.cons(R.reply_of(R.exec(c1, R.db_of(R.exec(c2, db)))), _))), j) == KV.get(String, Laws.final(run(Con{c1, Con{c2, cs}}, db)), j) : Maybe<&2, String>}
  %eta_l(run(cs, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))))) : {KV.get(String, rsnd(run(cs, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))))), j) == KV.get(String, Laws.final(R.exec_all.cons(R.reply_of(R.exec(c1, db)), R.exec_all.cons(R.reply_of(R.exec(c2, R.db_of(R.exec(c1, db)))), _))), j) : Maybe<&2, String>}
  %Equal.sym(KV.Trie<String>, rsnd(run(cs, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))))), tw(List.reverse.go(&2, R.Cmd, cs, Nil{}), R.db_of(R.exec(c1, R.db_of(R.exec(c2, db))))), tw_rev(cs, Nil{}, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))))) : {KV.get(String, _, j) == KV.get(String, rsnd(run(cs, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))))), j) : Maybe<&2, String>}
  %Equal.sym(KV.Trie<String>, rsnd(run(cs, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))))), tw(List.reverse.go(&2, R.Cmd, cs, Nil{}), R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))), tw_rev(cs, Nil{}, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))))) : {KV.get(String, tw(List.reverse.go(&2, R.Cmd, cs, Nil{}), R.db_of(R.exec(c1, R.db_of(R.exec(c2, db))))), j) == KV.get(String, _, j) : Maybe<&2, String>}
  Equal.sym(Maybe<&2, String>, KV.get(String, tw(List.reverse.go(&2, R.Cmd, cs, Nil{}), R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))), j), KV.get(String, tw(List.reverse.go(&2, R.Cmd, cs, Nil{}), R.db_of(R.exec(c1, R.db_of(R.exec(c2, db))))), j), eq_at(c1, c2, db, List.reverse.go(&2, R.Cmd, cs, Nil{}), j, e))


# Persistence
# ===========
# The file loads as written (Laws.aof_load): a number line reads back as
# the number Nat.show wrote (num_show), a bulk as its bytes (bulk_rt), an
# entry as its strings (entry_rt), and the loader has fuel for every
# entry (load_fuel). exec_log runs as run does, its effects being each
# command's in turn (log_parts). A command's effect, run where the command
# ran, leaves the database the command left (effect_db), and a client
# command's effect parses back to itself (effect_args). The file after a
# history holds the entries of all its effects (aof_all); they parse back
# to them, and run from an empty database they leave the history's
# database (replay_all).

# Numbers
# -------
# Nat.show writes n's last digit, then the digits of n's tens before it,
# with n itself as its fuel. quot10 and rem10 are n's tens and last digit,
# found by steps of ten; they are what divmod by 10 gives (divmod_10).

type Dig is Data:
  D0{}
  D1{}
  D2{}
  D3{}
  D4{}
  D5{}
  D6{}
  D7{}
  D8{}
  D9{}

def dval(d: Dig) -> Nat:
  match d:
    case D0{}:
      0n
    case D1{}:
      1n
    case D2{}:
      2n
    case D3{}:
      3n
    case D4{}:
      4n
    case D5{}:
      5n
    case D6{}:
      6n
    case D7{}:
      7n
    case D8{}:
      8n
    case D9{}:
      9n

def quot10(n: Nat) -> Nat:
  match n:
    case 0n:
      0n
    case 1n:
      0n
    case 2n:
      0n
    case 3n:
      0n
    case 4n:
      0n
    case 5n:
      0n
    case 6n:
      0n
    case 7n:
      0n
    case 8n:
      0n
    case 9n:
      0n
    case 10n+m:
      1n+quot10(m)

def rem10(n: Nat) -> Dig:
  match n:
    case 0n:
      D0{}
    case 1n:
      D1{}
    case 2n:
      D2{}
    case 3n:
      D3{}
    case 4n:
      D4{}
    case 5n:
      D5{}
    case 6n:
      D6{}
    case 7n:
      D7{}
    case 8n:
      D8{}
    case 9n:
      D9{}
    case 10n+m:
      rem10(m)

def add_succ_r(a: Nat, -b: Nat) -> {Nat.add(a, 1n+b) == 1n+Nat.add(a, b) : Nat}:
  match a:
    case 0n:
      {==}
    case 1n+p:
      Equal.cong(Nat, Nat, x => 1n+x, Nat.add(p, 1n+b), 1n+Nat.add(p, b), add_succ_r(p, b))

def divmod_go(n: Nat, -d: Nat) -> {(Nat.add(quot10(n), d), dval(rem10(n))) == Nat.divmod.go(n, 9n, d, 0n) : Nat & Nat}:
  match n:
    case 0n:
      {==}
    case 1n:
      {==}
    case 2n:
      {==}
    case 3n:
      {==}
    case 4n:
      {==}
    case 5n:
      {==}
    case 6n:
      {==}
    case 7n:
      {==}
    case 8n:
      {==}
    case 9n:
      {==}
    case 10n++m:
      %add_succ_r(quot10(m), d) : {(_, dval(rem10(m))) == Nat.divmod.go(m, 9n, 1n+d, 0n) : Nat & Nat}
      divmod_go(m, 1n+d)

def divmod_10(+n: Nat) -> {(quot10(n), dval(rem10(n))) == Nat.divmod(n, 10n) : Nat & Nat}:
  %Equal.sym(Nat, quot10(n), Nat.add(quot10(n), 0n), add_zero(quot10(n))) : {(_, dval(rem10(n))) == Nat.divmod(n, 10n) : Nat & Nat}
  divmod_go(n, 0n)

def quot_spec(n: Nat) -> {n == Nat.add(Nat.mul(quot10(n), 10n), dval(rem10(n))) : Nat}:
  match n:
    case 0n:
      {==}
    case 1n:
      {==}
    case 2n:
      {==}
    case 3n:
      {==}
    case 4n:
      {==}
    case 5n:
      {==}
    case 6n:
      {==}
    case 7n:
      {==}
    case 8n:
      {==}
    case 9n:
      {==}
    case 10n+m:
      Equal.cong(Nat, Nat, x => 10n+x, m, Nat.add(Nat.mul(quot10(m), 10n), dval(rem10(m))), quot_spec(m))

# a <= b
def le(a: Nat, b: Nat) -> Bool:
  match a b:
    case 0n _:
      True{}
    case 1n+p 0n:
      False{}
    case 1n+p 1n+q:
      le(p, q)

def le_succ(a: Nat, b: Nat) -> {le(a, b) == True{} : Bool} -> {le(a, 1n+b) == True{} : Bool}:
  match a b:
    case 0n _:
      e => {==}
    case 1n+p 0n:
      e => Empty.absurd({le(1n+p, 1n) == True{} : Bool}, false_true(e))
    case 1n+p 1n+q:
      e => le_succ(p, q)(e)

def le_self(n: Nat) -> {le(n, 1n+n) == True{} : Bool}:
  match n:
    case 0n:
      {==}
    case 1n+p:
      le_self(p)

def le_drop(k: Nat, +a: Nat, b: Nat) -> {le(Nat.add(k, a), b) == True{} : Bool} -> {le(a, b) == True{} : Bool}:
  match k b:
    case 0n _:
      e => e
    case 1n+j 0n:
      e => Empty.absurd({le(a, 0n) == True{} : Bool}, false_true(e))
    case 1n+j 1n++c:
      e => le_succ(a, c)(le_drop(j, a, c)(e))

# the fuel of Nat.show lasts: a number below 1 + g has its tens below g
def le_quot(n: Nat, g: Nat) -> {le(n, 1n+g) == True{} : Bool} -> {le(quot10(n), g) == True{} : Bool}:
  match n g:
    case 0n _:
      e => {==}
    case 1n _:
      e => {==}
    case 2n _:
      e => {==}
    case 3n _:
      e => {==}
    case 4n _:
      e => {==}
    case 5n _:
      e => {==}
    case 6n _:
      e => {==}
    case 7n _:
      e => {==}
    case 8n _:
      e => {==}
    case 9n _:
      e => {==}
    case 10n+m 0n:
      e => Empty.absurd({le(quot10(10n+m), 0n) == True{} : Bool}, false_true(e))
    case 10n++m 1n++h:
      e => le_quot(m, h)(le_succ(m, h)(le_drop(8n, m, h)(e)))

# the char Nat.show writes for a digit reads back as that digit
def ch_dig(r: Dig, -t: String) -> {A.CDigit{dval(r)} == A.ch(SCon{Chr{U32.from_nat(Nat.add(48n, dval(r)))}, t}) : A.Ch}:
  match r:
    case D0{}:
      {==}
    case D1{}:
      {==}
    case D2{}:
      {==}
    case D3{}:
      {==}
    case D4{}:
      {==}
    case D5{}:
      {==}
    case D6{}:
      {==}
    case D7{}:
      {==}
    case D8{}:
      {==}
    case D9{}:
      {==}

# the digits Nat.show.go writes in front of acc, read as a number from 0,
# are acc read on from n
def num_fin(-g: Nat, q: Nat, -n: Nat, +r: Dig, +acc: String, ih: @m: Nat -> @t: String -> {le(m, g) == True{} : Bool} -> {A.num(t, m, A.ch(t)) == A.num(Nat.show.go(g, m, t), 0n, A.ch(Nat.show.go(g, m, t))) : Maybe<&1, Nat & String>})
  -> {n == Nat.add(Nat.mul(q, 10n), dval(r)) : Nat}
  -> {le(q, g) == True{} : Bool}
  -> {A.num(acc, n, A.ch(acc)) == A.num(Nat.show.fin(g, acc, (Chr{U32.from_nat(Nat.add(48n, dval(r)))}, q)), 0n, A.ch(Nat.show.fin(g, acc, (Chr{U32.from_nat(Nat.add(48n, dval(r)))}, q)))) : Maybe<&1, Nat & String>}:
  match q:
    case 0n:
      sp => lq =>
        %ch_dig(r, acc) : {A.num(acc, n, A.ch(acc)) == A.num(SCon{Chr{U32.from_nat(Nat.add(48n, dval(r)))}, acc}, 0n, _) : Maybe<&1, Nat & String>}
        %sp : {A.num(acc, n, A.ch(acc)) == A.num(acc, _, A.ch(acc)) : Maybe<&1, Nat & String>}
        {==}
    case 1n+p:
      sp => lq =>
        %ih(1n+p, SCon{Chr{U32.from_nat(Nat.add(48n, dval(r)))}, acc})(lq) : {A.num(acc, n, A.ch(acc)) == _ : Maybe<&1, Nat & String>}
        %ch_dig(r, acc) : {A.num(acc, n, A.ch(acc)) == A.num(SCon{Chr{U32.from_nat(Nat.add(48n, dval(r)))}, acc}, 1n+p, _) : Maybe<&1, Nat & String>}
        %sp : {A.num(acc, n, A.ch(acc)) == A.num(acc, _, A.ch(acc)) : Maybe<&1, Nat & String>}
        {==}

def num_go(f: Nat, +n: Nat, acc: String) -> {le(n, f) == True{} : Bool} -> {A.num(acc, n, A.ch(acc)) == A.num(Nat.show.go(f, n, acc), 0n, A.ch(Nat.show.go(f, n, acc))) : Maybe<&1, Nat & String>}:
  match f:
    case 0n:
      match n:
        case 0n:
          e => {==}
        case 1n+p:
          e => Empty.absurd({A.num(acc, 1n+p, A.ch(acc)) == A.num(acc, 0n, A.ch(acc)) : Maybe<&1, Nat & String>}, false_true(e))
    case 1n++g:
      e =>
        %divmod_10(n) : {A.num(acc, n, A.ch(acc)) == A.num(Nat.show.fin(g, acc, Nat.show.put(_)), 0n, A.ch(Nat.show.fin(g, acc, Nat.show.put(_)))) : Maybe<&1, Nat & String>}
        num_fin(g, quot10(n), n, rem10(n), acc, m => t => num_go(g, m, t))(quot_spec(n))(le_quot(n, g)(e))

# Nat.show.go writes in front of what follows its acc
def show_fin_app(-g: Nat, acc: String, -t: String, p: Char & Nat, ih: @m: Nat -> @a: String -> {Nat.show.go(g, m, a ++ t) == Nat.show.go(g, m, a) ++ t : String}) -> {Nat.show.fin(g, acc ++ t, p) == Nat.show.fin(g, acc, p) ++ t : String}:
  (c, q) = p
  match q:
    case 0n:
      {==}
    case 1n+r:
      ih(1n+r, SCon{c, acc})

def show_app(f: Nat, n: Nat, acc: String, -t: String) -> {Nat.show.go(f, n, acc ++ t) == Nat.show.go(f, n, acc) ++ t : String}:
  match f:
    case 0n:
      {==}
    case 1n++g:
      show_fin_app(g, acc, t, Nat.show.put(Nat.divmod(n, 10n)), m => a => show_app(g, m, a, t))

# a number line reads back as the number Nat.show wrote
def num_show(+n: Nat, rest: String) -> {Some{(n, rest)} == A.num(Nat.show(n) ++ (P.crlf() ++ rest), 0n, A.ch(Nat.show(n) ++ (P.crlf() ++ rest))) : Maybe<&1, Nat & String>}:
  %show_app(1n+n, n, SNil{}, P.crlf() ++ rest) : {Some{(n, rest)} == A.num(_, 0n, A.ch(_)) : Maybe<&1, Nat & String>}
  num_go(1n+n, n, P.crlf() ++ rest)(le_self(n))

# Entries
# -------

def take_app(s: String, t: String) -> {s == String.take(s ++ t, String.length(s)) : String}:
  match s:
    case SNil{}:
      match t:
        case SNil{}:
          {==}
        case SCon{h, r}:
          {==}
    case SCon{h, r}:
      Equal.cong(String, String, x => SCon{h, x}, r, String.take(r ++ t, String.length(r)), take_app(r, t))

def drop_app(s: String, t: String) -> {t == String.drop(s ++ t, String.length(s)) : String}:
  match s:
    case SNil{}:
      match t:
        case SNil{}:
          {==}
        case SCon{h, r}:
          {==}
    case SCon{h, r}:
      drop_app(r, t)

# a bulk reads back as its bytes
def bulk_rt(+s: String, +rest: String) -> {Some{(s, rest)} == A.bulk(P.bulk_into(s, rest)) : Maybe<&1, String & String>}:
  %num_show(String.length(s), s ++ (P.crlf() ++ rest)) : {Some{(s, rest)} == A.bulk.body(_) : Maybe<&1, String & String>}
  %take_app(s, P.crlf() ++ rest) : {Some{(s, rest)} == A.bulk.end(_, String.drop(s ++ (P.crlf() ++ rest), String.length(s))) : Maybe<&1, String & String>}
  %drop_app(s, P.crlf() ++ rest) : {Some{(s, rest)} == A.bulk.end(s, _) : Maybe<&1, String & String>}
  {==}

# the bulks after the one just read (x) read back as the strings written
def bulks_rt(ys: List<&2, String>, -x: String, +rest: String, -acc: List<&2, String>) -> {Some{(List.reverse.go(&2, String, acc, x <> ys), rest)} == A.bulks(List.length(&2, String, ys), Some{(x, A.bulks.onto(ys, rest))}, acc) : Maybe<&1, List<&2, String> & String>}:
  match ys:
    case Nil{}:
      {==}
    case Con{+y, +zs}:
      %bulk_rt(y, A.bulks.onto(zs, rest)) : {Some{(List.reverse.go(&2, String, acc, x <> y <> zs), rest)} == A.bulks(List.length(&2, String, zs), _, x <> acc) : Maybe<&1, List<&2, String> & String>}
      bulks_rt(zs, y, rest, x <> acc)

# an entry reads back as its strings
def entry_rt(xs: List<&2, String>, +rest: String) -> {Some{(xs, rest)} == A.entry(A.entry.onto(xs, rest)) : Maybe<&1, List<&2, String> & String>}:
  match xs:
    case Nil{}:
      %num_show(0n, rest) : {Some{(Nil{}, rest)} == A.entry.head(_) : Maybe<&1, List<&2, String> & String>}
      {==}
    case Con{+x, +ys}:
      %num_show(1n+List.length(&2, String, ys), A.bulks.onto(Con{x, ys}, rest)) : {Some{(Con{x, ys}, rest)} == A.entry.head(_) : Maybe<&1, List<&2, String> & String>}
      %bulk_rt(x, A.bulks.onto(ys, rest)) : {Some{(Con{x, ys}, rest)} == A.bulks(List.length(&2, String, ys), _, Nil{}) : Maybe<&1, List<&2, String> & String>}
      bulks_rt(ys, x, rest, Nil{})

# Loading
# -------

# the entries of a file, with fuel for each, read back as written, up to
# what follows them (rest, where no entry starts)
def load_go(reqs: List<&2, List<&2, String>>, f: Nat, +rest: String, -acc: List<&2, List<&2, String>>, en: {None{} == A.entry(rest) : Maybe<&1, List<&2, String> & String>})
  -> {le(List.length(&2, List<&2, String>, reqs), f) == True{} : Bool}
  -> {(List.reverse.go(&2, List<&2, String>, acc, reqs), rest) == A.load.go(f, A.encode.onto(reqs, rest), A.entry(A.encode.onto(reqs, rest)), acc) : List<&2, List<&2, String>> & String}:
  match reqs f:
    case Nil{} 0n:
      e =>
        %en : {(List.reverse.go(&2, List<&2, String>, acc, Nil{}), rest) == A.load.go(0n, rest, _, acc) : List<&2, List<&2, String>> & String}
        {==}
    case Nil{} 1n+g:
      e =>
        %en : {(List.reverse.go(&2, List<&2, String>, acc, Nil{}), rest) == A.load.go(1n+g, rest, _, acc) : List<&2, List<&2, String>> & String}
        {==}
    case Con{+r, +more} 0n:
      e => Empty.absurd({(List.reverse.go(&2, List<&2, String>, acc, Con{r, more}), rest) == A.load.go(0n, A.encode.onto(Con{r, more}, rest), A.entry(A.encode.onto(Con{r, more}, rest)), acc) : List<&2, List<&2, String>> & String}, false_true(e))
    case Con{+r, more} 1n+g:
      e =>
        %entry_rt(r, A.encode.onto(more, rest)) : {(List.reverse.go(&2, List<&2, String>, acc, Con{r, more}), rest) == A.load.go(1n+g, A.entry.onto(r, A.encode.onto(more, rest)), _, acc) : List<&2, List<&2, String>> & String}
        load_go(more, g, rest, r <> acc, en)(e)

# a file has a byte for each entry, at least: enough fuel for load
def le_app(+a: Nat, p: String, +t: String) -> {le(a, String.length(t)) == True{} : Bool} -> {le(a, String.length(p ++ t)) == True{} : Bool}:
  match p:
    case SNil{}:
      e => e
    case SCon{h, +q}:
      e => le_succ(a, String.length(q ++ t))(le_app(a, q, t)(e))

def le_bulks(+a: Nat, xs: List<&2, String>, +t: String) -> {le(a, String.length(t)) == True{} : Bool} -> {le(a, String.length(A.bulks.onto(xs, t))) == True{} : Bool}:
  match xs:
    case Nil{}:
      e => e
    case Con{+x, +ys}:
      e => le_succ(a, String.length(Nat.show(String.length(x)) ++ (P.crlf() ++ (x ++ (P.crlf() ++ A.bulks.onto(ys, t))))))(
        le_app(a, Nat.show(String.length(x)), P.crlf() ++ (x ++ (P.crlf() ++ A.bulks.onto(ys, t))))(
          le_app(a, P.crlf(), x ++ (P.crlf() ++ A.bulks.onto(ys, t)))(
            le_app(a, x, P.crlf() ++ A.bulks.onto(ys, t))(
              le_app(a, P.crlf(), A.bulks.onto(ys, t))(
                le_bulks(a, ys, t)(e))))))

def load_fuel(reqs: List<&2, List<&2, String>>, +rest: String) -> {le(List.length(&2, List<&2, String>, reqs), String.length(A.encode.onto(reqs, rest))) == True{} : Bool}:
  match reqs:
    case Nil{}:
      {==}
    case Con{+r, +more}:
      le_app(List.length(&2, List<&2, String>, more), Nat.show(List.length(&2, String, r)), P.crlf() ++ A.bulks.onto(r, A.encode.onto(more, rest)))(
        le_app(List.length(&2, List<&2, String>, more), P.crlf(), A.bulks.onto(r, A.encode.onto(more, rest)))(
          le_bulks(List.length(&2, List<&2, String>, more), r, A.encode.onto(more, rest))(load_fuel(more, rest))))

def Laws.aof_load(reqs):
  Equal.sym(List<&2, List<&2, String>> & String, (reqs, ""), A.load(A.encode(reqs)), load_go(reqs, String.length(A.encode(reqs)), "", Nil{}, {==})(load_fuel(reqs, "")))

# Logging
# -------

# the effects of a batch run on db, in order
def effs(cs: List<&2, R.Cmd>, +db: KV.Trie<String>) -> List<&2, R.Cmd>:
  match cs:
    case Nil{}:
      Nil{}
    case Con{+c, rest}:
      List.append(&2, R.Cmd, A.effect(c, R.reply_of(R.exec(c, db))), effs(rest, R.db_of(R.exec(c, db))))

def rev_go_app(e: List<&2, R.Cmd>, -es: List<&2, R.Cmd>, -ys: List<&2, R.Cmd>) -> {List.reverse.go(&2, R.Cmd, List.reverse.go(&2, R.Cmd, e, es), ys) == List.reverse.go(&2, R.Cmd, es, List.append(&2, R.Cmd, e, ys)) : List<&2, R.Cmd>}:
  match e:
    case Nil{}:
      {==}
    case Con{h, t}:
      rev_go_app(t, h <> es, ys)

# exec_log is run, with each command's effects in turn
def log_go(cs: List<&2, R.Cmd>, +rs: List<&2, R.Reply>, +es: List<&2, R.Cmd>, +d: KV.Trie<String>)
  -> {(List.reverse.go(&2, R.Reply, rs, rfst(run(cs, d))), (List.reverse.go(&2, R.Cmd, es, effs(cs, d)), rsnd(run(cs, d)))) == A.log.fin(A.log.go(cs, (rs, (es, d)))) : List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>)}:
  match cs:
    case Nil{}:
      {==}
    case Con{+c, +rest}:
      %eta_r(R.exec(c, d)) : {(List.reverse.go(&2, R.Reply, rs, rfst(run(Con{c, rest}, d))), (List.reverse.go(&2, R.Cmd, es, effs(Con{c, rest}, d)), rsnd(run(Con{c, rest}, d)))) == A.log.fin(A.log.go(rest, A.log.put(rs, es, c, _))) : List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>)}
      %eta_l(run(rest, R.db_of(R.exec(c, d)))) : {(List.reverse.go(&2, R.Reply, rs, rfst(R.exec_all.cons(R.reply_of(R.exec(c, d)), _))), (List.reverse.go(&2, R.Cmd, es, effs(Con{c, rest}, d)), rsnd(R.exec_all.cons(R.reply_of(R.exec(c, d)), _)))) == A.log.fin(A.log.go(rest, (R.reply_of(R.exec(c, d)) <> rs, (List.reverse.go(&2, R.Cmd, A.effect(c, R.reply_of(R.exec(c, d))), es), R.db_of(R.exec(c, d)))))) : List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>)}
      %rev_go_app(A.effect(c, R.reply_of(R.exec(c, d))), es, effs(rest, R.db_of(R.exec(c, d)))) : {(List.reverse.go(&2, R.Reply, rs, R.reply_of(R.exec(c, d)) <> rfst(run(rest, R.db_of(R.exec(c, d))))), (_, rsnd(run(rest, R.db_of(R.exec(c, d)))))) == A.log.fin(A.log.go(rest, (R.reply_of(R.exec(c, d)) <> rs, (List.reverse.go(&2, R.Cmd, A.effect(c, R.reply_of(R.exec(c, d))), es), R.db_of(R.exec(c, d)))))) : List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>)}
      log_go(rest, R.reply_of(R.exec(c, d)) <> rs, List.reverse.go(&2, R.Cmd, A.effect(c, R.reply_of(R.exec(c, d))), es), R.db_of(R.exec(c, d)))

def log_parts(+cs: List<&2, R.Cmd>, +db: KV.Trie<String>) -> {(rfst(run(cs, db)), (effs(cs, db), rsnd(run(cs, db)))) == A.exec_log(cs, db) : List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>)}:
  log_go(cs, Nil{}, Nil{}, db)

def effects_eq(+cs: List<&2, R.Cmd>, +db: KV.Trie<String>) -> {effs(cs, db) == Laws.effects(A.exec_log(cs, db)) : List<&2, R.Cmd>}:
  %log_parts(cs, db) : {effs(cs, db) == Laws.effects(_) : List<&2, R.Cmd>}
  {==}

# the log run with hashes that fit is exec_log, a command at a time
def log_go_fit.con(+c: R.Cmd, -rest: List<&2, R.Cmd>, +h: U32, -hrest: List<&2, U32>, +rs: List<&2, R.Reply>, +es: List<&2, R.Cmd>, +db: KV.Trie<String>, e: Laws.fits(c, h) & Laws.all_fit(rest, hrest), ih: Laws.all_fit(rest, hrest) -> {A.log.go.at(rest, hrest, (R.reply_of(R.exec(c, db)) <> rs, (List.reverse.go(&2, R.Cmd, A.effect(c, R.reply_of(R.exec(c, db))), es), R.db_of(R.exec(c, db))))) == A.log.go(rest, (R.reply_of(R.exec(c, db)) <> rs, (List.reverse.go(&2, R.Cmd, A.effect(c, R.reply_of(R.exec(c, db))), es), R.db_of(R.exec(c, db))))) : List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>)}) -> {A.log.go.at(Con{c, rest}, Con{h, hrest}, (rs, (es, db))) == A.log.go(Con{c, rest}, (rs, (es, db))) : List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>)}:
  (e1, e2) = e
  %Equal.sym(R.Reply & KV.Trie<String>, R.exec.at(c, h, db), R.exec(c, db), exec_fit(c, h, db)(e1)) : {A.log.go.at(rest, hrest, A.log.put(rs, es, c, _)) == A.log.go(rest, A.log.put(rs, es, c, R.exec(c, db))) : List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>)}
  %eta_r(R.exec(c, db)) : {A.log.go.at(rest, hrest, A.log.put(rs, es, c, _)) == A.log.go(rest, A.log.put(rs, es, c, _)) : List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>)}
  ih(e2)

def log_go_fit(cs: List<&2, R.Cmd>, hs: List<&2, U32>, +rs: List<&2, R.Reply>, +es: List<&2, R.Cmd>, +db: KV.Trie<String>) -> Laws.all_fit(cs, hs) -> {A.log.go.at(cs, hs, (rs, (es, db))) == A.log.go(cs, (rs, (es, db))) : List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>)}:
  match cs hs:
    case Con{+c, +rest} Con{+h, +hrest}:
      e => log_go_fit.con(c, rest, h, hrest, rs, es, db, e, e2 => log_go_fit(rest, hrest, R.reply_of(R.exec(c, db)) <> rs, List.reverse.go(&2, R.Cmd, A.effect(c, R.reply_of(R.exec(c, db))), es), R.db_of(R.exec(c, db)))(e2))
    case Con{c, rest} Nil{}:
      e => {==}
    case Nil{} _:
      e => {==}

def log_hinted_any(u: Bool, +cs: List<&2, R.Cmd>, +hs: List<&2, U32>, +db: KV.Trie<String>) -> {A.log_hinted(u, cs, hs, db) == A.exec_log.at(cs, hs, db) : List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>)}:
  match u:
    case True{}:
      {==}
    case False{}:
      {==}

def Laws.log_hints(cs, hs, db, e):
  Equal.trans(List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>), A.log_batch(cs, hs, db), A.exec_log.at(cs, hs, db), A.exec_log(cs, db),
    log_hinted_any(U32.is_eq(B.touch_if(B.many(hs), hs, db), 0), cs, hs, db),
    Equal.cong(List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>), List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>), z => A.log.fin(z), A.log.go.at(cs, hs, (Nil{}, (Nil{}, db))), A.log.go(cs, (Nil{}, (Nil{}, db))), log_go_fit(cs, hs, Nil{}, Nil{}, db)(e)))

def Laws.log_exec(cs, db):
  %log_parts(cs, db) : {Laws.log_out(_) == R.exec_all(cs, db) : List<&2, R.Reply> & KV.Trie<String>}
  Equal.trans(List<&2, R.Reply> & KV.Trie<String>, (rfst(run(cs, db)), rsnd(run(cs, db))), run(cs, db), R.exec_all(cs, db), eta_l(run(cs, db)), exec_all_run(cs, db))

# Replaying
# ---------

# a batch's run, then another's, is the run of both
def comp(xs: List<&2, R.Cmd>, +ys: List<&2, R.Cmd>, +d: KV.Trie<String>) -> {Laws.final(R.exec_all(ys, Laws.final(R.exec_all(xs, d)))) == Laws.final(R.exec_all(List.append(&2, R.Cmd, xs, ys), d)) : KV.Trie<String>}:
  match xs:
    case Nil{}:
      {==}
    case Con{+c, +rest}:
      %fin_cons(c, List.append(&2, R.Cmd, rest, ys), d) : {Laws.final(R.exec_all(ys, Laws.final(R.exec_all(Con{c, rest}, d)))) == _ : KV.Trie<String>}
      %fin_cons(c, rest, d) : {Laws.final(R.exec_all(ys, _)) == Laws.final(R.exec_all(List.append(&2, R.Cmd, rest, ys), R.db_of(R.exec(c, d)))) : KV.Trie<String>}
      comp(rest, ys, R.db_of(R.exec(c, d)))

def incr_fit_db(+db: KV.Trie<String>, +k: String, +n: R.Int, ok: Bool) -> {R.db_of(R.incr.fit(db, k, KV.hash(k), n, ok)) == Laws.final(R.exec_all(A.incr.effect(k, R.reply_of(R.incr.fit(db, k, KV.hash(k), n, ok))), db)) : KV.Trie<String>}:
  match ok:
    case True{}:
      {==}
    case False{}:
      {==}

def incr_db(+db: KV.Trie<String>, +k: String, by: R.Int, cur: Maybe<&2, R.Int>) -> {R.db_of(R.incr.got(db, k, KV.hash(k), by, cur)) == Laws.final(R.exec_all(A.incr.effect(k, R.reply_of(R.incr.got(db, k, KV.hash(k), by, cur))), db)) : KV.Trie<String>}:
  match cur:
    case Some{x}:
      +n = R.int_add(x, by)
      incr_fit_db(db, k, n, R.int_fits(n))
    case None{}:
      {==}

# a command's effect, run where the command ran, leaves its database
def effect_db(c: R.Cmd, +db: KV.Trie<String>) -> {R.db_of(R.exec(c, db)) == Laws.final(R.exec_all(A.effect(c, R.reply_of(R.exec(c, db))), db)) : KV.Trie<String>}:
  match c:
    case R.Ping{}:
      {==}
    case R.Echo{m}:
      {==}
    case R.Get{k}:
      {==}
    case R.Set{k, v}:
      fin_cons(R.Set{k, v}, Nil{}, db)
    case R.SetNX{k, v}:
      fin_cons(R.SetNX{k, v}, Nil{}, db)
    case R.GetSet{k, v}:
      fin_cons(R.GetSet{k, v}, Nil{}, db)
    case R.Del{ks}:
      match ks:
        case Nil{}:
          {==}
        case Con{k, rest}:
          fin_cons(R.Del{Con{k, rest}}, Nil{}, db)
    case R.Exists{ks}:
      {==}
    case R.IncrBy{+k, by}:
      incr_db(db, k, by, R.incr.old(KV.get.at(String, db, k, KV.hash(k))))
    case R.Append{k, v}:
      fin_cons(R.Append{k, v}, Nil{}, db)
    case R.Strlen{k}:
      {==}
    case R.MGet{ks}:
      {==}
    case R.MSet{ps}:
      match ps:
        case Nil{}:
          {==}
        case Con{p, rest}:
          fin_cons(R.MSet{Con{p, rest}}, Nil{}, db)
    case R.DbSize{}:
      {==}
    case R.FlushAll{}:
      fin_cons(R.FlushAll{}, Nil{}, db)
    case R.Keys{p}:
      {==}
    case R.Bad{r}:
      {==}
    case R.SizeAt{x}:
      {==}
    case R.KeysAt{p, x}:
      {==}
    case R.FlushAt{x}:
      fin_cons(R.FlushAt{x}, Nil{}, db)

def replay_effs(cs: List<&2, R.Cmd>, +db: KV.Trie<String>) -> {Laws.final(R.exec_all(effs(cs, db), db)) == Laws.final(R.exec_all(cs, db)) : KV.Trie<String>}:
  match cs:
    case Nil{}:
      {==}
    case Con{+c, +rest}:
      %comp(A.effect(c, R.reply_of(R.exec(c, db))), effs(rest, R.db_of(R.exec(c, db))), db) : {_ == Laws.final(R.exec_all(Con{c, rest}, db)) : KV.Trie<String>}
      %effect_db(c, db) : {Laws.final(R.exec_all(effs(rest, R.db_of(R.exec(c, db))), _)) == Laws.final(R.exec_all(Con{c, rest}, db)) : KV.Trie<String>}
      %fin_cons(c, rest, db) : {Laws.final(R.exec_all(effs(rest, R.db_of(R.exec(c, db))), R.db_of(R.exec(c, db)))) == _ : KV.Trie<String>}
      replay_effs(rest, R.db_of(R.exec(c, db)))

def Laws.log_replay(cs, db):
  %effects_eq(cs, db) : {Laws.final(R.exec_all(_, db)) == Laws.final(R.exec_all(cs, db)) : KV.Trie<String>}
  replay_effs(cs, db)

# Parsing back
# ------------

def pairs_rt(ps: List<&2, R.KVPair>) -> {Some{ps} == R.pairs(A.pair_args(ps)) : Maybe<&2, List<&2, R.KVPair>>}:
  match ps:
    case Nil{}:
      {==}
    case Con{R.KP{k, v}, rest}:
      %pairs_rt(rest) : {Some{Con{R.KP{k, v}, rest}} == R.pairs.put(k, v, _) : Maybe<&2, List<&2, R.KVPair>>}
      {==}

def incr_args(-k: String, r: R.Reply) -> {A.incr.effect(k, r) == A.parse_all(A.args_all(A.incr.effect(k, r))) : List<&2, R.Cmd>}:
  match r:
    case R.RStatus{s}:
      {==}
    case R.RError{s}:
      {==}
    case R.RInt{n}:
      {==}
    case R.RBulk{s}:
      {==}
    case R.RNull{}:
      {==}
    case R.RArray{xs}:
      {==}

# a client command's effect parses back to itself
def effect_args(c: R.Cmd, r: R.Reply) -> {A.effect(c, r) == A.parse_all(A.args_all(A.effect(c, r))) : List<&2, R.Cmd>}:
  match c:
    case R.Ping{}:
      {==}
    case R.Echo{m}:
      {==}
    case R.Get{k}:
      {==}
    case R.Set{k, v}:
      {==}
    case R.SetNX{k, v}:
      {==}
    case R.GetSet{k, v}:
      {==}
    case R.Del{ks}:
      match ks:
        case Nil{}:
          {==}
        case Con{k, rest}:
          {==}
    case R.Exists{ks}:
      {==}
    case R.IncrBy{k, by}:
      incr_args(k, r)
    case R.Append{k, v}:
      {==}
    case R.Strlen{k}:
      {==}
    case R.MGet{ks}:
      {==}
    case R.MSet{ps}:
      match ps:
        case Nil{}:
          {==}
        case Con{+p, +rest}:
          %pairs_rt(Con{p, rest}) : {[R.MSet{Con{p, rest}}] == [R.parse_mset(_)] : List<&2, R.Cmd>}
          {==}
    case R.DbSize{}:
      {==}
    case R.FlushAll{}:
      {==}
    case R.Keys{p}:
      {==}
    case R.Bad{b}:
      {==}
    case R.SizeAt{x}:
      {==}
    case R.KeysAt{p, x}:
      {==}
    case R.FlushAt{x}:
      match x:
        case KV.H0{}:
          {==}
        case KV.H1{}:
          {==}
        case KV.H2{}:
          {==}
        case KV.H3{}:
          {==}
        case KV.H4{}:
          {==}
        case KV.H5{}:
          {==}
        case KV.H6{}:
          {==}
        case KV.H7{}:
          {==}
        case KV.H8{}:
          {==}
        case KV.H9{}:
          {==}
        case KV.H10{}:
          {==}
        case KV.H11{}:
          {==}
        case KV.H12{}:
          {==}
        case KV.H13{}:
          {==}
        case KV.H14{}:
          {==}
        case KV.H15{}:
          {==}

def args_app(xs: List<&2, R.Cmd>, -ys: List<&2, R.Cmd>) -> {List.append(&2, List<&2, String>, A.args_all(xs), A.args_all(ys)) == A.args_all(List.append(&2, R.Cmd, xs, ys)) : List<&2, List<&2, String>>}:
  match xs:
    case Nil{}:
      {==}
    case Con{c, rest}:
      Equal.cong(List<&2, List<&2, String>>, List<&2, List<&2, String>>, z => A.args(c) <> z, List.append(&2, List<&2, String>, A.args_all(rest), A.args_all(ys)), A.args_all(List.append(&2, R.Cmd, rest, ys)), args_app(rest, ys))

def parse_app(xs: List<&2, List<&2, String>>, -ys: List<&2, List<&2, String>>) -> {List.append(&2, R.Cmd, A.parse_all(xs), A.parse_all(ys)) == A.parse_all(List.append(&2, List<&2, String>, xs, ys)) : List<&2, R.Cmd>}:
  match xs:
    case Nil{}:
      {==}
    case Con{r, rest}:
      Equal.cong(List<&2, R.Cmd>, List<&2, R.Cmd>, z => A.parse_cmd(r) <> z, List.append(&2, R.Cmd, A.parse_all(rest), A.parse_all(ys)), A.parse_all(List.append(&2, List<&2, String>, rest, ys)), parse_app(rest, ys))

# effects, written as entries and parsed back, give themselves back
def args_round(+xs: List<&2, R.Cmd>, +ys: List<&2, R.Cmd>, ex: {xs == A.parse_all(A.args_all(xs)) : List<&2, R.Cmd>}, ey: {ys == A.parse_all(A.args_all(ys)) : List<&2, R.Cmd>}) -> {List.append(&2, R.Cmd, xs, ys) == A.parse_all(A.args_all(List.append(&2, R.Cmd, xs, ys))) : List<&2, R.Cmd>}:
  %args_app(xs, ys) : {List.append(&2, R.Cmd, xs, ys) == A.parse_all(_) : List<&2, R.Cmd>}
  %parse_app(A.args_all(xs), A.args_all(ys)) : {List.append(&2, R.Cmd, xs, ys) == _ : List<&2, R.Cmd>}
  %ex : {List.append(&2, R.Cmd, xs, ys) == List.append(&2, R.Cmd, _, A.parse_all(A.args_all(ys))) : List<&2, R.Cmd>}
  %ey : {List.append(&2, R.Cmd, xs, ys) == List.append(&2, R.Cmd, xs, _) : List<&2, R.Cmd>}
  {==}

def effs_args(cs: List<&2, R.Cmd>, +db: KV.Trie<String>) -> {effs(cs, db) == A.parse_all(A.args_all(effs(cs, db))) : List<&2, R.Cmd>}:
  match cs:
    case Nil{}:
      {==}
    case Con{+c, +rest}:
      args_round(A.effect(c, R.reply_of(R.exec(c, db))), effs(rest, R.db_of(R.exec(c, db))),
        effect_args(c, R.reply_of(R.exec(c, db))),
        effs_args(rest, R.db_of(R.exec(c, db))))

def Laws.log_args(cs, db):
  %effects_eq(cs, db) : {A.parse_all(A.args_all(_)) == _ : List<&2, R.Cmd>}
  Equal.sym(List<&2, R.Cmd>, effs(cs, db), A.parse_all(A.args_all(effs(cs, db))), effs_args(cs, db))

# Recovering
# ----------

# entries are written in front of what follows them, so a file appended
# to holds the entries of both
def bulks_glue(xs: List<&2, String>, -y: String, -out: String) -> {A.bulks.onto(xs, y) ++ out == A.bulks.onto(xs, y ++ out) : String}:
  match xs:
    case Nil{}:
      {==}
    case Con{+x, rest}:
      Equal.trans(String, P.bulk_into(x, A.bulks.onto(rest, y)) ++ out, P.bulk_into(x, A.bulks.onto(rest, y) ++ out), P.bulk_into(x, A.bulks.onto(rest, y ++ out)),
        bulk_glue(x, A.bulks.onto(rest, y), out),
        Equal.cong(String, String, z => P.bulk_into(x, z), A.bulks.onto(rest, y) ++ out, A.bulks.onto(rest, y ++ out), bulks_glue(rest, y, out)))

def entry_glue(+xs: List<&2, String>, -y: String, -out: String) -> {A.entry.onto(xs, y) ++ out == A.entry.onto(xs, y ++ out) : String}:
  glue_in("*", Nat.show(List.length(&2, String, xs)) ++ (P.crlf() ++ A.bulks.onto(xs, y)), Nat.show(List.length(&2, String, xs)) ++ (P.crlf() ++ A.bulks.onto(xs, y ++ out)), out,
    glue_in(Nat.show(List.length(&2, String, xs)), P.crlf() ++ A.bulks.onto(xs, y), P.crlf() ++ A.bulks.onto(xs, y ++ out), out,
      glue_in(P.crlf(), A.bulks.onto(xs, y), A.bulks.onto(xs, y ++ out), out, bulks_glue(xs, y, out))))

def encode_glue(reqs: List<&2, List<&2, String>>, -y: String, -out: String) -> {A.encode.onto(reqs, y) ++ out == A.encode.onto(reqs, y ++ out) : String}:
  match reqs:
    case Nil{}:
      {==}
    case Con{+r, more}:
      Equal.trans(String, A.entry.onto(r, A.encode.onto(more, y)) ++ out, A.entry.onto(r, A.encode.onto(more, y) ++ out), A.entry.onto(r, A.encode.onto(more, y ++ out)),
        entry_glue(r, A.encode.onto(more, y), out),
        Equal.cong(String, String, z => A.entry.onto(r, z), A.encode.onto(more, y) ++ out, A.encode.onto(more, y ++ out), encode_glue(more, y, out)))

def onto_app(a: List<&2, List<&2, String>>, -b: List<&2, List<&2, String>>, -rest: String) -> {A.encode.onto(a, A.encode.onto(b, rest)) == A.encode.onto(List.append(&2, List<&2, String>, a, b), rest) : String}:
  match a:
    case Nil{}:
      {==}
    case Con{r, more}:
      Equal.cong(String, String, z => A.entry.onto(r, z), A.encode.onto(more, A.encode.onto(b, rest)), A.encode.onto(List.append(&2, List<&2, String>, more, b), rest), onto_app(more, b, rest))

def enc_cat(+a: List<&2, List<&2, String>>, +b: List<&2, List<&2, String>>) -> {A.encode(a) ++ A.encode(b) == A.encode(List.append(&2, List<&2, String>, a, b)) : String}:
  Equal.trans(String, A.encode(a) ++ A.encode(b), A.encode.onto(a, A.encode(b)), A.encode(List.append(&2, List<&2, String>, a, b)),
    encode_glue(a, "", A.encode(b)),
    onto_app(a, b, ""))

# the effects of a history, oldest first
def all_effs(hist: List<&2, List<&2, R.Cmd>>) -> List<&2, R.Cmd>:
  match hist:
    case Nil{}:
      Nil{}
    case Con{cs, +older}:
      List.append(&2, R.Cmd, all_effs(older), effs(cs, Laws.single(older)))

# the file after a history holds the entries of all its effects
def aof_all(hist: List<&2, List<&2, R.Cmd>>) -> {A.encode(A.args_all(all_effs(hist))) == Laws.aof(hist) : String}:
  match hist:
    case Nil{}:
      {==}
    case Con{+cs, +older}:
      %args_app(all_effs(older), effs(cs, Laws.single(older))) : {A.encode(_) == Laws.aof(Con{cs, older}) : String}
      %enc_cat(A.args_all(all_effs(older)), A.args_all(effs(cs, Laws.single(older)))) : {_ == Laws.aof(Con{cs, older}) : String}
      %effects_eq(cs, Laws.single(older)) : {A.encode(A.args_all(all_effs(older))) ++ A.encode(A.args_all(effs(cs, Laws.single(older)))) == Laws.aof(older) ++ A.encode(A.args_all(_)) : String}
      %aof_all(older) : {A.encode(A.args_all(all_effs(older))) ++ A.encode(A.args_all(effs(cs, Laws.single(older)))) == _ ++ A.encode(A.args_all(effs(cs, Laws.single(older)))) : String}
      {==}

# all the effects, run from an empty database, leave the history's
def replay_all(hist: List<&2, List<&2, R.Cmd>>) -> {Laws.final(R.exec_all(all_effs(hist), KV.empty(String))) == Laws.single(hist) : KV.Trie<String>}:
  match hist:
    case Nil{}:
      {==}
    case Con{+cs, +older}:
      %comp(all_effs(older), effs(cs, Laws.single(older)), KV.empty(String)) : {_ == Laws.single(Con{cs, older}) : KV.Trie<String>}
      %Equal.sym(KV.Trie<String>, Laws.final(R.exec_all(all_effs(older), KV.empty(String))), Laws.single(older), replay_all(older)) : {Laws.final(R.exec_all(effs(cs, Laws.single(older)), _)) == Laws.single(Con{cs, older}) : KV.Trie<String>}
      replay_effs(cs, Laws.single(older))

# and they parse back to themselves
def parse_all_effs(hist: List<&2, List<&2, R.Cmd>>) -> {all_effs(hist) == A.parse_all(A.args_all(all_effs(hist))) : List<&2, R.Cmd>}:
  match hist:
    case Nil{}:
      {==}
    case Con{+cs, +older}:
      args_round(all_effs(older), effs(cs, Laws.single(older)),
        parse_all_effs(older),
        effs_args(cs, Laws.single(older)))

def Laws.recover(hist):
  %aof_all(hist) : {A.restore(_) == (Laws.single(hist), "") : KV.Trie<String> & String}
  %Equal.sym(List<&2, List<&2, String>> & String, A.load(A.encode(A.args_all(all_effs(hist)))), (A.args_all(all_effs(hist)), ""), Laws.aof_load(A.args_all(all_effs(hist)))) : {A.restore.of(_) == (Laws.single(hist), "") : KV.Trie<String> & String}
  %parse_all_effs(hist) : {(A.db_after(R.exec_all(_, KV.empty(String))), "") == (Laws.single(hist), "") : KV.Trie<String> & String}
  %replay_all(hist) : {(A.db_after(R.exec_all(all_effs(hist), KV.empty(String))), "") == (_, "") : KV.Trie<String> & String}
  %eta_l(R.exec_all(all_effs(hist), KV.empty(String))) : {(A.db_after(_), "") == (Laws.final(_), "") : KV.Trie<String> & String}
  {==}

# Cuts
# ----
# A crash leaves c of the file, c ++ d being the file (Laws.recover_cut,
# Laws.load_cut). An entry cut short never parses (entry_cut): a cut
# number line ends without its "\r\n" (num_cut), a cut bulk lacks bytes
# or its "\r\n" (bulk_cut). So the loader reads the whole entries in
# front of the cut and leaves the rest (load_cut_go). Each entry is one
# effect, and the first k effects of a run leave the database its first j
# commands leave, for some j (effs_prefix): a command with no effect
# leaves the database as it was. A history's effects are those of its
# commands in order (all_effs_cmds), so the k entries in front of a cut
# restore the database after some j of its commands (Laws.recover_cut).

def scon_snil(-h: Char, -t: String, e: {SCon{h, t} == SNil{} : String}) -> Empty:
  %e : is_scon(_)
  Unit{}

def scon_head(-a: Char, -b: Char, -s: String, -t: String, e: {SCon{a, s} == SCon{b, t} : String}) -> {a == b : Char}:
  Equal.cong(String, Char, shead, SCon{a, s}, SCon{b, t}, e)

def scon_tail(-a: Char, -b: Char, -s: String, -t: String, e: {SCon{a, s} == SCon{b, t} : String}) -> {s == t : String}:
  Equal.cong(String, String, stail, SCon{a, s}, SCon{b, t}, e)

# nothing glued in front of a char is empty
def app_scon(a: String, -h: Char, -t: String, e: {a ++ SCon{h, t} == SNil{} : String}) -> Empty:
  match a:
    case SNil{}:
      scon_snil(h, t, e)
    case SCon{x, y}:
      scon_snil(x, y ++ SCon{h, t}, e)

def app_empty(a: String, -b: String) -> {a ++ b == SNil{} : String} -> {a == SNil{} : String}:
  match a:
    case SNil{}:
      e => {==}
    case SCon{x, y}:
      e => Empty.absurd({SCon{x, y} == SNil{} : String}, scon_snil(x, y ++ b, e))

# c ++ d == x ++ z: c holds all of x and more (c is x ++ c2), or c stops
# inside x (x is c ++ SCon{h, t})
def Split(c: String, d: String, x: String, z: String) -> Type:
  Or(Exists(String, c2 => {c == x ++ c2 : String} & {c2 ++ d == z : String}), Exists(Char, h => Exists(String, t => {x == c ++ SCon{h, t} : String})))

def scon_eq(-a: Char, -b: Char, -s: String, -t: String, ea: {a == b : Char}, es: {s == t : String}) -> {SCon{a, s} == SCon{b, t} : String}:
  %ea : {SCon{a, s} == SCon{_, t} : String}
  %es : {SCon{a, s} == SCon{a, _} : String}
  {==}

def split_step(-ch: Char, -ct: String, -d: String, -xh: Char, -xt: String, -z: String, +eh: {ch == xh : Char}, r: Split(ct, d, xt, z)) -> Split(SCon{ch, ct}, d, SCon{xh, xt}, z):
  match r:
    case Inl{p}:
      (c2, q) = p
      (e1, e2) = q
      Inl{(c2, (scon_eq(ch, xh, ct, xt ++ c2, eh, e1), e2))}
    case Inr{p}:
      (h, q) = p
      (t, e1) = q
      Inr{(h, (t, scon_eq(xh, ch, xt, ct ++ SCon{h, t}, Equal.sym(Char, ch, xh, eh), e1)))}

def split(x: String, +c: String, -d: String, -z: String) -> {c ++ d == x ++ z : String} -> Split(c, d, x, z):
  match x c:
    case SNil{} _:
      e => Inl{(c, ({==}, e))}
    case SCon{xh, xt} SNil{}:
      e => Inr{(xh, (xt, {==}))}
    case SCon{xh, xt} SCon{+ch, +ct}:
      +e => split_step(ch, ct, d, xh, xt, z, scon_head(ch, xh, ct ++ d, xt ++ z, e), split(xt, ct, d, z)(scon_tail(ch, xh, ct ++ d, xt ++ z, e)))

# a char that ch reads as a digit, and a string of them
def isdig(c: Char) -> Bool:
  match c:
    case Chr{x}:
      U32.is_lt(U32.sub(x, 48), 10)

def digs(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{c, t}:
      Bool.and(isdig(c), digs(t))

def isdig_dig(r: Dig) -> {isdig(Chr{U32.from_nat(Nat.add(48n, dval(r)))}) == True{} : Bool}:
  match r:
    case D0{}:
      {==}
    case D1{}:
      {==}
    case D2{}:
      {==}
    case D3{}:
      {==}
    case D4{}:
      {==}
    case D5{}:
      {==}
    case D6{}:
      {==}
    case D7{}:
      {==}
    case D8{}:
      {==}
    case D9{}:
      {==}

# Nat.show writes digits only
def digs_fin(-g: Nat, q: Nat, +r: Dig, +acc: String, ih: @m: Nat -> @a: String -> {digs(a) == True{} : Bool} -> {digs(Nat.show.go(g, m, a)) == True{} : Bool})
  -> {digs(acc) == True{} : Bool}
  -> {digs(Nat.show.fin(g, acc, (Chr{U32.from_nat(Nat.add(48n, dval(r)))}, q))) == True{} : Bool}:
  match q:
    case 0n:
      ea => and_true(isdig(Chr{U32.from_nat(Nat.add(48n, dval(r)))}), digs(acc))(isdig_dig(r))(ea)
    case 1n+p:
      ea => ih(1n+p, SCon{Chr{U32.from_nat(Nat.add(48n, dval(r)))}, acc})(and_true(isdig(Chr{U32.from_nat(Nat.add(48n, dval(r)))}), digs(acc))(isdig_dig(r))(ea))

def digs_show_go(f: Nat, +n: Nat, acc: String) -> {digs(acc) == True{} : Bool} -> {digs(Nat.show.go(f, n, acc)) == True{} : Bool}:
  match f:
    case 0n:
      ea => ea
    case 1n++g:
      ea =>
        %divmod_10(n) : {digs(Nat.show.fin(g, acc, Nat.show.put(_))) == True{} : Bool}
        digs_fin(g, quot10(n), rem10(n), acc, m => a => digs_show_go(g, m, a))(ea)

def digs_show(+n: Nat) -> {digs(Nat.show(n)) == True{} : Bool}:
  digs_show_go(1n+n, n, SNil{})({==})

# a number line cut before its end reads as no number
def num_cut_cr(c1: Char, c2: String, -acc: Nat, -h: Char, -t: String, e: {SCon{c1, c2 ++ SCon{h, t}} == P.crlf() : String}) -> {None{} == A.num(SCon{c1, c2}, acc, A.ch(SCon{c1, c2})) : Maybe<&1, Nat & String>}:
  match c2:
    case SNil{}:
      %Equal.sym(Char, c1, '\r', scon_head(c1, '\r', SCon{h, t}, "\n", e)) : {None{} == A.num(SCon{_, SNil{}}, acc, A.ch(SCon{_, SNil{}})) : Maybe<&1, Nat & String>}
      {==}
    case SCon{c3, c4}:
      Empty.absurd({None{} == A.num(SCon{c1, SCon{c3, c4}}, acc, A.ch(SCon{c1, SCon{c3, c4}})) : Maybe<&1, Nat & String>}, app_scon(c4, h, t, scon_tail(c3, '\n', c4 ++ SCon{h, t}, SNil{}, scon_tail(c1, '\r', SCon{c3, c4 ++ SCon{h, t}}, "\n", e))))

def num_cut(dd: String, c: String, -acc: Nat, -h: Char, -t: String) -> {digs(dd) == True{} : Bool} -> {c ++ SCon{h, t} == dd ++ P.crlf() : String} -> {None{} == A.num(c, acc, A.ch(c)) : Maybe<&1, Nat & String>}:
  match dd c:
    case SNil{} SNil{}:
      ed => e => {==}
    case SNil{} SCon{c1, c2}:
      ed => e => num_cut_cr(c1, c2, acc, h, t, e)
    case SCon{d1, ds} SNil{}:
      ed => e => {==}
    case SCon{Chr{+x}, ds} SCon{c1, c2}:
      +ed => +e =>
        %Equal.sym(Char, c1, Chr{x}, scon_head(c1, Chr{x}, c2 ++ SCon{h, t}, ds ++ P.crlf(), e)) : {None{} == A.num(SCon{_, c2}, acc, A.ch(SCon{_, c2})) : Maybe<&1, Nat & String>}
        %Equal.sym(Bool, U32.is_lt(U32.sub(x, 48), 10), True{}, and_l(U32.is_lt(U32.sub(x, 48), 10), digs(ds))(ed)) : {None{} == A.num(SCon{Chr{x}, c2}, acc, A.ch.of(x, _, U32.is_eq(x, 13))) : Maybe<&1, Nat & String>}
        num_cut(ds, c2, Nat.add(Nat.mul(acc, 10n), U32.to_nat(U32.sub(x, 48))), h, t)(and_r(U32.is_lt(U32.sub(x, 48), 10), digs(ds))(ed))(scon_tail(c1, Chr{x}, c2 ++ SCon{h, t}, ds ++ P.crlf(), e))

# dropping at least a string's length leaves nothing
def drop_long(c: String, -h: Char, -t: String) -> {SNil{} == String.drop(c, String.length(c ++ SCon{h, t})) : String}:
  match c:
    case SNil{}:
      {==}
    case SCon{a, b}:
      drop_long(b, h, t)

# a bulk's bytes followed by less than its "\r\n" is no bulk
def bulk_end_cut(-s: String, c4: String, -h: Char, -t: String, e: {c4 ++ SCon{h, t} == P.crlf() : String}) -> {None{} == A.bulk.end(s, c4) : Maybe<&1, String & String>}:
  match c4:
    case SNil{}:
      {==}
    case SCon{a, b}:
      match b:
        case SNil{}:
          %Equal.sym(Char, a, '\r', scon_head(a, '\r', SCon{h, t}, "\n", e)) : {None{} == A.bulk.end(s, SCon{_, SNil{}}) : Maybe<&1, String & String>}
          {==}
        case SCon{b1, b2}:
          Empty.absurd({None{} == A.bulk.end(s, SCon{a, SCon{b1, b2}}) : Maybe<&1, String & String>}, app_scon(b2, h, t, scon_tail(b1, '\n', b2 ++ SCon{h, t}, SNil{}, scon_tail(a, '\r', SCon{b1, b2 ++ SCon{h, t}}, "\n", e))))

def bulk_cut_body(c3: String, +s: String, -h: Char, -t: String, sp: Split(c3, SCon{h, t}, s, P.crlf() ++ "")) -> {None{} == A.bulk.end(String.take(c3, String.length(s)), String.drop(c3, String.length(s))) : Maybe<&1, String & String>}:
  match sp:
    case Inl{p}:
      (+c4, q) = p
      (e3, e4) = q
      %Equal.sym(String, c3, s ++ c4, e3) : {None{} == A.bulk.end(String.take(_, String.length(s)), String.drop(_, String.length(s))) : Maybe<&1, String & String>}
      %take_app(s, c4) : {None{} == A.bulk.end(_, String.drop(s ++ c4, String.length(s))) : Maybe<&1, String & String>}
      %drop_app(s, c4) : {None{} == A.bulk.end(s, _) : Maybe<&1, String & String>}
      bulk_end_cut(s, c4, h, t, e4)
    case Inr{p}:
      (h2, q) = p
      (t2, e3) = q
      %Equal.sym(String, s, c3 ++ SCon{h2, t2}, e3) : {None{} == A.bulk.end(String.take(c3, String.length(_)), String.drop(c3, String.length(_))) : Maybe<&1, String & String>}
      %drop_long(c3, h2, t2) : {None{} == A.bulk.end(String.take(c3, String.length(c3 ++ SCon{h2, t2})), _) : Maybe<&1, String & String>}
      {==}

def bulk_cut_num(c2: String, +s: String, -h: Char, -t: String, sp: Split(c2, SCon{h, t}, Nat.show(String.length(s)) ++ P.crlf(), s ++ (P.crlf() ++ ""))) -> {None{} == A.bulk(SCon{'$', c2}) : Maybe<&1, String & String>}:
  match sp:
    case Inl{p}:
      (+c3, q) = p
      (e1, e2) = q
      %Equal.sym(String, c2, (Nat.show(String.length(s)) ++ P.crlf()) ++ c3, e1) : {None{} == A.bulk(SCon{'$', _}) : Maybe<&1, String & String>}
      %Equal.sym(String, (Nat.show(String.length(s)) ++ P.crlf()) ++ c3, Nat.show(String.length(s)) ++ (P.crlf() ++ c3), app_assoc(Nat.show(String.length(s)), P.crlf(), c3)) : {None{} == A.bulk(SCon{'$', _}) : Maybe<&1, String & String>}
      %num_show(String.length(s), c3) : {None{} == A.bulk.body(_) : Maybe<&1, String & String>}
      bulk_cut_body(c3, s, h, t, split(s, c3, SCon{h, t}, P.crlf() ++ "")(e2))
    case Inr{p}:
      (h2, q) = p
      (t2, e1) = q
      %num_cut(Nat.show(String.length(s)), c2, 0n, h2, t2)(digs_show(String.length(s)))(Equal.sym(String, Nat.show(String.length(s)) ++ P.crlf(), c2 ++ SCon{h2, t2}, e1)) : {None{} == A.bulk.body(_) : Maybe<&1, String & String>}
      {==}

# a bulk cut short is no bulk
def bulk_cut(c: String, +s: String, -h: Char, -t: String) -> {c ++ SCon{h, t} == P.bulk_into(s, "") : String} -> {None{} == A.bulk(c) : Maybe<&1, String & String>}:
  match c:
    case SNil{}:
      e => {==}
    case SCon{c1, +c2}:
      +e =>
        %Equal.sym(Char, c1, '$', scon_head(c1, '$', c2 ++ SCon{h, t}, Nat.show(String.length(s)) ++ (P.crlf() ++ (s ++ (P.crlf() ++ ""))), e)) : {None{} == A.bulk(SCon{_, c2}) : Maybe<&1, String & String>}
        bulk_cut_num(c2, s, h, t, split(Nat.show(String.length(s)) ++ P.crlf(), c2, SCon{h, t}, s ++ (P.crlf() ++ ""))(Equal.trans(String, c2 ++ SCon{h, t}, Nat.show(String.length(s)) ++ (P.crlf() ++ (s ++ (P.crlf() ++ ""))), (Nat.show(String.length(s)) ++ P.crlf()) ++ (s ++ (P.crlf() ++ "")), scon_tail(c1, '$', c2 ++ SCon{h, t}, Nat.show(String.length(s)) ++ (P.crlf() ++ (s ++ (P.crlf() ++ ""))), e), Equal.sym(String, (Nat.show(String.length(s)) ++ P.crlf()) ++ (s ++ (P.crlf() ++ "")), Nat.show(String.length(s)) ++ (P.crlf() ++ (s ++ (P.crlf() ++ ""))), app_assoc(Nat.show(String.length(s)), P.crlf(), s ++ (P.crlf() ++ ""))))))

# the bulks of an entry, cut short: the last one, or one with more after it
def bulks_cut_last(+b: String, +c: String, -h: Char, -t: String, -acc: List<&2, String>, sp: Split(c, SCon{h, t}, P.bulk_into(b, ""), "")) -> {None{} == A.bulks(0n, A.bulk(c), acc) : Maybe<&1, List<&2, String> & String>}:
  match sp:
    case Inl{p}:
      (c2, q) = p
      (e1, e2) = q
      Empty.absurd({None{} == A.bulks(0n, A.bulk(c), acc) : Maybe<&1, List<&2, String> & String>}, app_scon(c2, h, t, e2))
    case Inr{p}:
      (h2, q) = p
      (t2, e1) = q
      %bulk_cut(c, b, h2, t2)(Equal.sym(String, P.bulk_into(b, ""), c ++ SCon{h2, t2}, e1)) : {None{} == A.bulks(0n, _, acc) : Maybe<&1, List<&2, String> & String>}
      {==}

def bulks_cut_more(+b: String, -b2: String, -bs2: List<&2, String>, +c: String, -h: Char, -t: String, -acc: List<&2, String>, sp: Split(c, SCon{h, t}, P.bulk_into(b, ""), A.bulks.onto(Con{b2, bs2}, "")), ih: @c2: String -> {c2 ++ SCon{h, t} == A.bulks.onto(Con{b2, bs2}, "") : String} -> {None{} == A.bulks(List.length(&2, String, bs2), A.bulk(c2), b <> acc) : Maybe<&1, List<&2, String> & String>})
  -> {None{} == A.bulks(1n+List.length(&2, String, bs2), A.bulk(c), acc) : Maybe<&1, List<&2, String> & String>}:
  match sp:
    case Inl{p}:
      (+c2, q) = p
      (e1, e2) = q
      %Equal.sym(String, c, P.bulk_into(b, "") ++ c2, e1) : {None{} == A.bulks(1n+List.length(&2, String, bs2), A.bulk(_), acc) : Maybe<&1, List<&2, String> & String>}
      %Equal.sym(String, P.bulk_into(b, "") ++ c2, P.bulk_into(b, c2), bulk_glue(b, "", c2)) : {None{} == A.bulks(1n+List.length(&2, String, bs2), A.bulk(_), acc) : Maybe<&1, List<&2, String> & String>}
      %bulk_rt(b, c2) : {None{} == A.bulks(1n+List.length(&2, String, bs2), _, acc) : Maybe<&1, List<&2, String> & String>}
      ih(c2)(e2)
    case Inr{p}:
      (h2, q) = p
      (t2, e1) = q
      %bulk_cut(c, b, h2, t2)(Equal.sym(String, P.bulk_into(b, ""), c ++ SCon{h2, t2}, e1)) : {None{} == A.bulks(1n+List.length(&2, String, bs2), _, acc) : Maybe<&1, List<&2, String> & String>}
      {==}

def bulks_cut(bs: List<&2, String>, +b: String, +c: String, -h: Char, -t: String, -acc: List<&2, String>) -> {c ++ SCon{h, t} == A.bulks.onto(Con{b, bs}, "") : String} -> {None{} == A.bulks(List.length(&2, String, bs), A.bulk(c), acc) : Maybe<&1, List<&2, String> & String>}:
  match bs:
    case Nil{}:
      e => bulks_cut_last(b, c, h, t, acc, split(P.bulk_into(b, ""), c, SCon{h, t}, "")(Equal.trans(String, c ++ SCon{h, t}, P.bulk_into(b, ""), P.bulk_into(b, "") ++ "", e, Equal.sym(String, P.bulk_into(b, "") ++ "", P.bulk_into(b, ""), bulk_glue(b, "", "")))))
    case Con{+b2, +bs2}:
      e => bulks_cut_more(b, b2, bs2, c, h, t, acc, split(P.bulk_into(b, ""), c, SCon{h, t}, A.bulks.onto(Con{b2, bs2}, ""))(Equal.trans(String, c ++ SCon{h, t}, P.bulk_into(b, A.bulks.onto(Con{b2, bs2}, "")), P.bulk_into(b, "") ++ A.bulks.onto(Con{b2, bs2}, ""), e, Equal.sym(String, P.bulk_into(b, "") ++ A.bulks.onto(Con{b2, bs2}, ""), P.bulk_into(b, A.bulks.onto(Con{b2, bs2}, "")), bulk_glue(b, "", A.bulks.onto(Con{b2, bs2}, ""))))), c2 => e2 => bulks_cut(bs2, b2, c2, h, t, b <> acc)(e2))

# an entry cut short is no entry: cut in its count line, or in its bulks
def entry_cut_nil(+c2: String, -h: Char, -t: String, sp: Split(c2, SCon{h, t}, Nat.show(0n) ++ P.crlf(), "")) -> {None{} == A.entry(SCon{'*', c2}) : Maybe<&1, List<&2, String> & String>}:
  match sp:
    case Inl{p}:
      (c3, q) = p
      (e1, e2) = q
      Empty.absurd({None{} == A.entry(SCon{'*', c2}) : Maybe<&1, List<&2, String> & String>}, app_scon(c3, h, t, e2))
    case Inr{p}:
      (h2, q) = p
      (t2, e1) = q
      %num_cut(Nat.show(0n), c2, 0n, h2, t2)(digs_show(0n))(Equal.sym(String, Nat.show(0n) ++ P.crlf(), c2 ++ SCon{h2, t2}, e1)) : {None{} == A.entry.head(_) : Maybe<&1, List<&2, String> & String>}
      {==}

def entry_cut_con(+b: String, +bs: List<&2, String>, +c2: String, -h: Char, -t: String, sp: Split(c2, SCon{h, t}, Nat.show(1n+List.length(&2, String, bs)) ++ P.crlf(), A.bulks.onto(Con{b, bs}, ""))) -> {None{} == A.entry(SCon{'*', c2}) : Maybe<&1, List<&2, String> & String>}:
  match sp:
    case Inl{p}:
      (+c3, q) = p
      (e1, e2) = q
      %Equal.sym(String, c2, (Nat.show(1n+List.length(&2, String, bs)) ++ P.crlf()) ++ c3, e1) : {None{} == A.entry(SCon{'*', _}) : Maybe<&1, List<&2, String> & String>}
      %Equal.sym(String, (Nat.show(1n+List.length(&2, String, bs)) ++ P.crlf()) ++ c3, Nat.show(1n+List.length(&2, String, bs)) ++ (P.crlf() ++ c3), app_assoc(Nat.show(1n+List.length(&2, String, bs)), P.crlf(), c3)) : {None{} == A.entry(SCon{'*', _}) : Maybe<&1, List<&2, String> & String>}
      %num_show(1n+List.length(&2, String, bs), c3) : {None{} == A.entry.head(_) : Maybe<&1, List<&2, String> & String>}
      bulks_cut(bs, b, c3, h, t, Nil{})(e2)
    case Inr{p}:
      (h2, q) = p
      (t2, e1) = q
      %num_cut(Nat.show(1n+List.length(&2, String, bs)), c2, 0n, h2, t2)(digs_show(1n+List.length(&2, String, bs)))(Equal.sym(String, Nat.show(1n+List.length(&2, String, bs)) ++ P.crlf(), c2 ++ SCon{h2, t2}, e1)) : {None{} == A.entry.head(_) : Maybe<&1, List<&2, String> & String>}
      {==}

def entry_cut_num(xs: List<&2, String>, +c2: String, -h: Char, -t: String, sp: Split(c2, SCon{h, t}, Nat.show(List.length(&2, String, xs)) ++ P.crlf(), A.bulks.onto(xs, ""))) -> {None{} == A.entry(SCon{'*', c2}) : Maybe<&1, List<&2, String> & String>}:
  match xs:
    case Nil{}:
      entry_cut_nil(c2, h, t, sp)
    case Con{b, bs}:
      entry_cut_con(b, bs, c2, h, t, sp)

def entry_cut(+xs: List<&2, String>, c: String, -h: Char, -t: String) -> {c ++ SCon{h, t} == A.entry.onto(xs, "") : String} -> {None{} == A.entry(c) : Maybe<&1, List<&2, String> & String>}:
  match c:
    case SNil{}:
      e => {==}
    case SCon{c1, +c2}:
      +e =>
        %Equal.sym(Char, c1, '*', scon_head(c1, '*', c2 ++ SCon{h, t}, Nat.show(List.length(&2, String, xs)) ++ (P.crlf() ++ A.bulks.onto(xs, "")), e)) : {None{} == A.entry(SCon{_, c2}) : Maybe<&1, List<&2, String> & String>}
        entry_cut_num(xs, c2, h, t, split(Nat.show(List.length(&2, String, xs)) ++ P.crlf(), c2, SCon{h, t}, A.bulks.onto(xs, ""))(Equal.trans(String, c2 ++ SCon{h, t}, Nat.show(List.length(&2, String, xs)) ++ (P.crlf() ++ A.bulks.onto(xs, "")), (Nat.show(List.length(&2, String, xs)) ++ P.crlf()) ++ A.bulks.onto(xs, ""), scon_tail(c1, '*', c2 ++ SCon{h, t}, Nat.show(List.length(&2, String, xs)) ++ (P.crlf() ++ A.bulks.onto(xs, "")), e), Equal.sym(String, (Nat.show(List.length(&2, String, xs)) ++ P.crlf()) ++ A.bulks.onto(xs, ""), Nat.show(List.length(&2, String, xs)) ++ (P.crlf() ++ A.bulks.onto(xs, "")), app_assoc(Nat.show(List.length(&2, String, xs)), P.crlf(), A.bulks.onto(xs, ""))))))

# Loading a cut file
# ------------------

# the first k of a list (List.take looks at the list first: this one
# looks at k first, so that the first 0 of any list is Nil)
def ltake(-A: Data, k: Nat, xs: List<&2, A>) -> List<&2, A>:
  match k xs:
    case 0n _:
      Nil{}
    case 1n+j Nil{}:
      Nil{}
    case 1n+j Con{h, t}:
      h <> ltake(A, j, t)

def le_refl(n: Nat) -> {le(n, n) == True{} : Bool}:
  match n:
    case 0n:
      {==}
    case 1n+p:
      le_refl(p)

# fuel for the rest of a file is fuel for its suffix
def le_suffix(p: String, +t: String, +g: Nat) -> {le(String.length(p ++ t), g) == True{} : Bool} -> {le(String.length(t), g) == True{} : Bool}:
  match p:
    case SNil{}:
      e => e
    case SCon{h, +q}:
      e => le_suffix(q, t, g)(le_drop(1n, String.length(q ++ t), g)(e))

def le_unbulks(xs: List<&2, String>, +c: String, +g: Nat) -> {le(String.length(A.bulks.onto(xs, c)), g) == True{} : Bool} -> {le(String.length(c), g) == True{} : Bool}:
  match xs:
    case Nil{}:
      e => e
    case Con{+x, +ys}:
      e => le_unbulks(ys, c, g)(
        le_suffix(P.crlf(), A.bulks.onto(ys, c), g)(
          le_suffix(x, P.crlf() ++ A.bulks.onto(ys, c), g)(
            le_suffix(P.crlf(), x ++ (P.crlf() ++ A.bulks.onto(ys, c)), g)(
              le_suffix(Nat.show(String.length(x)), P.crlf() ++ (x ++ (P.crlf() ++ A.bulks.onto(ys, c))), g)(
                le_drop(1n, String.length(Nat.show(String.length(x)) ++ (P.crlf() ++ (x ++ (P.crlf() ++ A.bulks.onto(ys, c))))), g)(e))))))

def le_unentry(+xs: List<&2, String>, +c: String, +g: Nat) -> {le(String.length(A.entry.onto(xs, c)), 1n+g) == True{} : Bool} -> {le(String.length(c), g) == True{} : Bool}:
  e => le_unbulks(xs, c, g)(
    le_suffix(P.crlf(), A.bulks.onto(xs, c), g)(
      le_suffix(Nat.show(List.length(&2, String, xs)), P.crlf() ++ A.bulks.onto(xs, c), g)(e)))

# the loader on c, with fuel f and acc read before: the first k entries
# of es, and a rest r, the two making c
def Cut(f: Nat, c: String, acc: List<&2, List<&2, String>>, es: List<&2, List<&2, String>>) -> Type:
  Exists(Nat, k => Exists(String, r => {A.load.go(f, c, A.entry(c), acc) == (List.reverse.go(&2, List<&2, String>, acc, ltake(List<&2, String>, k, es)), r) : List<&2, List<&2, String>> & String} & {A.encode.onto(ltake(List<&2, String>, k, es), "") ++ r == c : String}))

# the loader stops where no entry starts
def cut_go_none(f: Nat, -c: String, -acc: List<&2, List<&2, String>>) -> {A.load.go(f, c, None{}, acc) == (List.reverse.go(&2, List<&2, String>, acc, Nil{}), c) : List<&2, List<&2, String>> & String}:
  match f:
    case 0n:
      {==}
    case 1n+g:
      {==}

def cut_stop.p(f: Nat, -c: String, -acc: List<&2, List<&2, String>>, en: {None{} == A.entry(c) : Maybe<&1, List<&2, String> & String>}) -> {A.load.go(f, c, A.entry(c), acc) == (List.reverse.go(&2, List<&2, String>, acc, Nil{}), c) : List<&2, List<&2, String>> & String}:
  %en : {A.load.go(f, c, _, acc) == (List.reverse.go(&2, List<&2, String>, acc, Nil{}), c) : List<&2, List<&2, String>> & String}
  cut_go_none(f, c, acc)

def cut_stop(f: Nat, +c: String, -acc: List<&2, List<&2, String>>, -es: List<&2, List<&2, String>>, en: {None{} == A.entry(c) : Maybe<&1, List<&2, String> & String>}) -> Cut(f, c, acc, es):
  (0n, (c, (cut_stop.p(f, c, acc, en), {==})))

def cut_lift.p1(+x: List<&2, String>, -E2: List<&2, List<&2, String>>, +c2: String, -acc: List<&2, List<&2, String>>, -g: Nat, -k: Nat, -r: String, p1: {A.load.go(g, c2, A.entry(c2), x <> acc) == (List.reverse.go(&2, List<&2, String>, x <> acc, ltake(List<&2, String>, k, E2)), r) : List<&2, List<&2, String>> & String}) -> {A.load.go(1n+g, A.entry.onto(x, c2), A.entry(A.entry.onto(x, c2)), acc) == (List.reverse.go(&2, List<&2, String>, acc, ltake(List<&2, String>, 1n+k, Con{x, E2})), r) : List<&2, List<&2, String>> & String}:
  %entry_rt(x, c2) : {A.load.go(1n+g, A.entry.onto(x, c2), _, acc) == (List.reverse.go(&2, List<&2, String>, acc, ltake(List<&2, String>, 1n+k, Con{x, E2})), r) : List<&2, List<&2, String>> & String}
  p1

def cut_lift.p2(+x: List<&2, String>, -E2: List<&2, List<&2, String>>, -c2: String, -k: Nat, -r: String, p2: {A.encode.onto(ltake(List<&2, String>, k, E2), "") ++ r == c2 : String}) -> {A.encode.onto(ltake(List<&2, String>, 1n+k, Con{x, E2}), "") ++ r == A.entry.onto(x, c2) : String}:
  Equal.trans(String, A.entry.onto(x, A.encode.onto(ltake(List<&2, String>, k, E2), "")) ++ r, A.entry.onto(x, A.encode.onto(ltake(List<&2, String>, k, E2), "") ++ r), A.entry.onto(x, c2),
    entry_glue(x, A.encode.onto(ltake(List<&2, String>, k, E2), ""), r),
    Equal.cong(String, String, z => A.entry.onto(x, z), A.encode.onto(ltake(List<&2, String>, k, E2), "") ++ r, c2, p2))

# a whole entry in front: the loader takes it and goes on
def cut_lift(+x: List<&2, String>, -E2: List<&2, List<&2, String>>, +c2: String, -acc: List<&2, List<&2, String>>, -g: Nat, res: Cut(g, c2, x <> acc, E2)) -> Cut(1n+g, A.entry.onto(x, c2), acc, Con{x, E2}):
  (k, q) = res
  (r, pq) = q
  (p1, p2) = pq
  (1n+k, (r, (cut_lift.p1(x, E2, c2, acc, g, k, r, p1), cut_lift.p2(x, E2, c2, k, r, p2))))

def cut_more(f: Nat, +x: List<&2, String>, -E2: List<&2, List<&2, String>>, +c2: String, -acc: List<&2, List<&2, String>>, ih: @g: Nat -> {le(String.length(c2), g) == True{} : Bool} -> Cut(g, c2, x <> acc, E2))
  -> {le(String.length(A.entry.onto(x, c2)), f) == True{} : Bool}
  -> Cut(f, A.entry.onto(x, c2), acc, Con{x, E2}):
  match f:
    case 0n:
      fl => Empty.absurd(Cut(0n, A.entry.onto(x, c2), acc, Con{x, E2}), false_true(fl))
    case 1n++g:
      fl => cut_lift(x, E2, c2, acc, g, ih(g)(le_unentry(x, c2, g)(fl)))

def le_at(-a: String, -b: String, -f: Nat, e: {a == b : String}, fl: {le(String.length(b), f) == True{} : Bool}) -> {le(String.length(a), f) == True{} : Bool}:
  %Equal.sym(String, a, b, e) : {le(String.length(_), f) == True{} : Bool}
  fl

def cut_split(f: Nat, +x: List<&2, String>, -E2: List<&2, List<&2, String>>, +c: String, -d: String, -acc: List<&2, List<&2, String>>, sp: Split(c, d, A.entry.onto(x, ""), A.encode.onto(E2, "")), fl: {le(String.length(c), f) == True{} : Bool}, ih: @c2: String -> @g: Nat -> {c2 ++ d == A.encode.onto(E2, "") : String} -> {le(String.length(c2), g) == True{} : Bool} -> Cut(g, c2, x <> acc, E2)) -> Cut(f, c, acc, Con{x, E2}):
  match sp:
    case Inl{p}:
      (+c2, q) = p
      (e1, e2) = q
      +ec = Equal.sym(String, c, A.entry.onto(x, c2), Equal.trans(String, c, A.entry.onto(x, "") ++ c2, A.entry.onto(x, c2), e1, entry_glue(x, "", c2)))
      %ec : Cut(f, _, acc, Con{x, E2})
      cut_more(f, x, E2, c2, acc, g => fl2 => ih(c2, g, e2, fl2))(le_at(A.entry.onto(x, c2), c, f, ec, fl))
    case Inr{p}:
      (h, q) = p
      (t, e1) = q
      cut_stop(f, c, acc, Con{x, E2}, entry_cut(x, c, h, t)(Equal.sym(String, A.entry.onto(x, ""), c ++ SCon{h, t}, e1)))

def cut_empty_en(+c: String, -d: String, e: {c ++ d == SNil{} : String}) -> {None{} == A.entry(c) : Maybe<&1, List<&2, String> & String>}:
  %Equal.sym(String, c, SNil{}, app_empty(c, d)(e)) : {None{} == A.entry(_) : Maybe<&1, List<&2, String> & String>}
  {==}

# a file cut anywhere loads as the whole entries in front of the cut,
# and a rest, which together make the cut file
def load_cut_go(es: List<&2, List<&2, String>>, +c: String, -d: String, f: Nat, -acc: List<&2, List<&2, String>>) -> {c ++ d == A.encode.onto(es, "") : String} -> {le(String.length(c), f) == True{} : Bool} -> Cut(f, c, acc, es):
  match es:
    case Nil{}:
      e => fl => cut_stop(f, c, acc, Nil{}, cut_empty_en(c, d, e))
    case Con{+x, +E2}:
      e => fl => cut_split(f, x, E2, c, d, acc, split(A.entry.onto(x, ""), c, d, A.encode.onto(E2, ""))(Equal.trans(String, c ++ d, A.entry.onto(x, A.encode.onto(E2, "")), A.entry.onto(x, "") ++ A.encode.onto(E2, ""), e, Equal.sym(String, A.entry.onto(x, "") ++ A.encode.onto(E2, ""), A.entry.onto(x, A.encode.onto(E2, "")), entry_glue(x, "", A.encode.onto(E2, ""))))), fl, c2 => g => e2 => fl2 => load_cut_go(E2, c2, d, g, x <> acc)(e2)(fl2))

def load_cut_fin(+c: String, -es: List<&2, List<&2, String>>, res: Cut(String.length(c), c, Nil{}, es)) -> {A.encode(Pair.fst(List<&2, List<&2, String>>, String, A.load(c))) ++ Pair.snd(List<&2, List<&2, String>>, String, A.load(c)) == c : String}:
  (k, q) = res
  (r, pq) = q
  (p1, p2) = pq
  %Equal.sym(List<&2, List<&2, String>> & String, A.load.go(String.length(c), c, A.entry(c), Nil{}), (List.reverse.go(&2, List<&2, String>, Nil{}, ltake(List<&2, String>, k, es)), r), p1) : {A.encode(Pair.fst(List<&2, List<&2, String>>, String, _)) ++ Pair.snd(List<&2, List<&2, String>>, String, _) == c : String}
  p2

# the file is the entries of the history's effects
def aof_entries(+hist: List<&2, List<&2, R.Cmd>>, +c: String, -d: String, e: {c ++ d == Laws.aof(hist) : String}) -> {c ++ d == A.encode.onto(A.args_all(all_effs(hist)), "") : String}:
  Equal.trans(String, c ++ d, Laws.aof(hist), A.encode(A.args_all(all_effs(hist))), e, Equal.sym(String, A.encode(A.args_all(all_effs(hist))), Laws.aof(hist), aof_all(hist)))

def Laws.load_cut(hist, c, d, e):
  load_cut_fin(c, A.args_all(all_effs(hist)), load_cut_go(A.args_all(all_effs(hist)), c, d, String.length(c), Nil{})(aof_entries(hist, c, d, e))(le_refl(String.length(c))))

# Effects and commands
# --------------------

# a command's effect is nothing or one command
def effect_one(c: R.Cmd, r: R.Reply) -> Or({A.effect(c, r) == Nil{} : List<&2, R.Cmd>}, Exists(R.Cmd, e => {A.effect(c, r) == [e] : List<&2, R.Cmd>})):
  match c:
    case R.Ping{}:
      Inl{{==}}
    case R.Echo{m}:
      Inl{{==}}
    case R.Get{k}:
      Inl{{==}}
    case R.Set{k, v}:
      Inr{(R.Set{k, v}, {==})}
    case R.SetNX{k, v}:
      Inr{(R.SetNX{k, v}, {==})}
    case R.GetSet{k, v}:
      Inr{(R.GetSet{k, v}, {==})}
    case R.Del{ks}:
      match ks:
        case Nil{}:
          Inl{{==}}
        case Con{k, rest}:
          Inr{(R.Del{Con{k, rest}}, {==})}
    case R.Exists{ks}:
      Inl{{==}}
    case R.IncrBy{k, by}:
      match r:
        case R.RStatus{s}:
          Inl{{==}}
        case R.RError{s}:
          Inl{{==}}
        case R.RInt{n}:
          Inr{(R.Set{k, R.int_show(n)}, {==})}
        case R.RBulk{s}:
          Inl{{==}}
        case R.RNull{}:
          Inl{{==}}
        case R.RArray{xs}:
          Inl{{==}}
    case R.Append{k, v}:
      Inr{(R.Append{k, v}, {==})}
    case R.Strlen{k}:
      Inl{{==}}
    case R.MGet{ks}:
      Inl{{==}}
    case R.MSet{ps}:
      match ps:
        case Nil{}:
          Inl{{==}}
        case Con{p, rest}:
          Inr{(R.MSet{Con{p, rest}}, {==})}
    case R.DbSize{}:
      Inl{{==}}
    case R.FlushAll{}:
      Inr{(R.FlushAll{}, {==})}
    case R.Keys{p}:
      Inl{{==}}
    case R.Bad{b}:
      Inl{{==}}
    case R.SizeAt{x}:
      Inl{{==}}
    case R.KeysAt{p, x}:
      Inl{{==}}
    case R.FlushAt{x}:
      Inr{(R.FlushAt{x}, {==})}

# the first k effects of a run on db leave the database its first j
# commands leave, for some j
def EP(cs: List<&2, R.Cmd>, db: KV.Trie<String>, k: Nat) -> Type:
  Exists(Nat, j => {Laws.final(R.exec_all(ltake(R.Cmd, k, effs(cs, db)), db)) == Laws.final(R.exec_all(List.take(&2, R.Cmd, cs, j), db)) : KV.Trie<String>})

def ep_none.p(+c: R.Cmd, +rest: List<&2, R.Cmd>, +db: KV.Trie<String>, -k: Nat, +j: Nat, +e0: {A.effect(c, R.reply_of(R.exec(c, db))) == Nil{} : List<&2, R.Cmd>}, p: {Laws.final(R.exec_all(ltake(R.Cmd, k, effs(rest, R.db_of(R.exec(c, db)))), R.db_of(R.exec(c, db)))) == Laws.final(R.exec_all(List.take(&2, R.Cmd, rest, j), R.db_of(R.exec(c, db)))) : KV.Trie<String>})
  -> {Laws.final(R.exec_all(ltake(R.Cmd, k, effs(Con{c, rest}, db)), db)) == Laws.final(R.exec_all(List.take(&2, R.Cmd, Con{c, rest}, 1n+j), db)) : KV.Trie<String>}:
  %Equal.sym(List<&2, R.Cmd>, A.effect(c, R.reply_of(R.exec(c, db))), Nil{}, e0) : {Laws.final(R.exec_all(ltake(R.Cmd, k, List.append(&2, R.Cmd, _, effs(rest, R.db_of(R.exec(c, db))))), db)) == Laws.final(R.exec_all(List.take(&2, R.Cmd, Con{c, rest}, 1n+j), db)) : KV.Trie<String>}
  %Equal.trans(KV.Trie<String>, R.db_of(R.exec(c, db)), Laws.final(R.exec_all(A.effect(c, R.reply_of(R.exec(c, db))), db)), db, effect_db(c, db), Equal.cong(List<&2, R.Cmd>, KV.Trie<String>, z => Laws.final(R.exec_all(z, db)), A.effect(c, R.reply_of(R.exec(c, db))), Nil{}, e0)) : {Laws.final(R.exec_all(ltake(R.Cmd, k, effs(rest, R.db_of(R.exec(c, db)))), _)) == Laws.final(R.exec_all(List.take(&2, R.Cmd, Con{c, rest}, 1n+j), db)) : KV.Trie<String>}
  %fin_cons(c, List.take(&2, R.Cmd, rest, j), db) : {Laws.final(R.exec_all(ltake(R.Cmd, k, effs(rest, R.db_of(R.exec(c, db)))), R.db_of(R.exec(c, db)))) == _ : KV.Trie<String>}
  p

def ep_none(+c: R.Cmd, +rest: List<&2, R.Cmd>, +db: KV.Trie<String>, -k: Nat, +e0: {A.effect(c, R.reply_of(R.exec(c, db))) == Nil{} : List<&2, R.Cmd>}, r: EP(rest, R.db_of(R.exec(c, db)), k)) -> EP(Con{c, rest}, db, k):
  (+j, p) = r
  (1n+j, ep_none.p(c, rest, db, k, j, e0, p))

# a command whose effect is e leaves the database e leaves
def one_db_eq(+c: R.Cmd, +db: KV.Trie<String>, +e: R.Cmd, +e1: {A.effect(c, R.reply_of(R.exec(c, db))) == [e] : List<&2, R.Cmd>}) -> {R.db_of(R.exec(e, db)) == R.db_of(R.exec(c, db)) : KV.Trie<String>}:
  Equal.trans(KV.Trie<String>, R.db_of(R.exec(e, db)), Laws.final(R.exec_all([e], db)), R.db_of(R.exec(c, db)),
    fin_cons(e, Nil{}, db),
    Equal.sym(KV.Trie<String>, R.db_of(R.exec(c, db)), Laws.final(R.exec_all([e], db)),
      Equal.trans(KV.Trie<String>, R.db_of(R.exec(c, db)), Laws.final(R.exec_all(A.effect(c, R.reply_of(R.exec(c, db))), db)), Laws.final(R.exec_all([e], db)),
        effect_db(c, db),
        Equal.cong(List<&2, R.Cmd>, KV.Trie<String>, z => Laws.final(R.exec_all(z, db)), A.effect(c, R.reply_of(R.exec(c, db))), [e], e1))))

def ep_one.p(+c: R.Cmd, +rest: List<&2, R.Cmd>, +db: KV.Trie<String>, +k2: Nat, +j: Nat, +e: R.Cmd, +e1: {A.effect(c, R.reply_of(R.exec(c, db))) == [e] : List<&2, R.Cmd>}, p: {Laws.final(R.exec_all(ltake(R.Cmd, k2, effs(rest, R.db_of(R.exec(c, db)))), R.db_of(R.exec(c, db)))) == Laws.final(R.exec_all(List.take(&2, R.Cmd, rest, j), R.db_of(R.exec(c, db)))) : KV.Trie<String>})
  -> {Laws.final(R.exec_all(ltake(R.Cmd, 1n+k2, effs(Con{c, rest}, db)), db)) == Laws.final(R.exec_all(List.take(&2, R.Cmd, Con{c, rest}, 1n+j), db)) : KV.Trie<String>}:
  %Equal.sym(List<&2, R.Cmd>, A.effect(c, R.reply_of(R.exec(c, db))), [e], e1) : {Laws.final(R.exec_all(ltake(R.Cmd, 1n+k2, List.append(&2, R.Cmd, _, effs(rest, R.db_of(R.exec(c, db))))), db)) == Laws.final(R.exec_all(List.take(&2, R.Cmd, Con{c, rest}, 1n+j), db)) : KV.Trie<String>}
  %fin_cons(e, ltake(R.Cmd, k2, effs(rest, R.db_of(R.exec(c, db)))), db) : {_ == Laws.final(R.exec_all(List.take(&2, R.Cmd, Con{c, rest}, 1n+j), db)) : KV.Trie<String>}
  %Equal.sym(KV.Trie<String>, R.db_of(R.exec(e, db)), R.db_of(R.exec(c, db)), one_db_eq(c, db, e, e1)) : {Laws.final(R.exec_all(ltake(R.Cmd, k2, effs(rest, R.db_of(R.exec(c, db)))), _)) == Laws.final(R.exec_all(List.take(&2, R.Cmd, Con{c, rest}, 1n+j), db)) : KV.Trie<String>}
  %fin_cons(c, List.take(&2, R.Cmd, rest, j), db) : {Laws.final(R.exec_all(ltake(R.Cmd, k2, effs(rest, R.db_of(R.exec(c, db)))), R.db_of(R.exec(c, db)))) == _ : KV.Trie<String>}
  p

def ep_one_more(+c: R.Cmd, +rest: List<&2, R.Cmd>, +db: KV.Trie<String>, +k2: Nat, +e: R.Cmd, +e1: {A.effect(c, R.reply_of(R.exec(c, db))) == [e] : List<&2, R.Cmd>}, r: EP(rest, R.db_of(R.exec(c, db)), k2)) -> EP(Con{c, rest}, db, 1n+k2):
  (+j, p) = r
  (1n+j, ep_one.p(c, rest, db, k2, j, e, e1, p))

def ep_one(k: Nat, +c: R.Cmd, +rest: List<&2, R.Cmd>, +db: KV.Trie<String>, +e: R.Cmd, +e1: {A.effect(c, R.reply_of(R.exec(c, db))) == [e] : List<&2, R.Cmd>}, ih: @k2: Nat -> EP(rest, R.db_of(R.exec(c, db)), k2)) -> EP(Con{c, rest}, db, k):
  match k:
    case 0n:
      (0n, {==})
    case 1n++k2:
      ep_one_more(c, rest, db, k2, e, e1, ih(k2))

def ep_step(+c: R.Cmd, +rest: List<&2, R.Cmd>, +db: KV.Trie<String>, k: Nat, o: Or({A.effect(c, R.reply_of(R.exec(c, db))) == Nil{} : List<&2, R.Cmd>}, Exists(R.Cmd, e => {A.effect(c, R.reply_of(R.exec(c, db))) == [e] : List<&2, R.Cmd>})), ih: @k2: Nat -> EP(rest, R.db_of(R.exec(c, db)), k2)) -> EP(Con{c, rest}, db, k):
  match o:
    case Inl{e0}:
      ep_none(c, rest, db, k, e0, ih(k))
    case Inr{p}:
      (e, e1) = p
      ep_one(k, c, rest, db, e, e1, ih)

def effs_prefix(cs: List<&2, R.Cmd>, +db: KV.Trie<String>, k: Nat) -> EP(cs, db, k):
  match cs:
    case Nil{}:
      match k:
        case 0n:
          (0n, {==})
        case 1n+j:
          (0n, {==})
    case Con{+c, +rest}:
      ep_step(c, rest, db, k, effect_one(c, R.reply_of(R.exec(c, db))), k2 => effs_prefix(rest, R.db_of(R.exec(c, db)), k2))

# History and commands
# --------------------

def lapp_assoc(a: List<&2, R.Cmd>, -b: List<&2, R.Cmd>, -c: List<&2, R.Cmd>) -> {List.append(&2, R.Cmd, List.append(&2, R.Cmd, a, b), c) == List.append(&2, R.Cmd, a, List.append(&2, R.Cmd, b, c)) : List<&2, R.Cmd>}:
  match a:
    case Nil{}:
      {==}
    case Con{h, t}:
      Equal.cong(List<&2, R.Cmd>, List<&2, R.Cmd>, z => h <> z, List.append(&2, R.Cmd, List.append(&2, R.Cmd, t, b), c), List.append(&2, R.Cmd, t, List.append(&2, R.Cmd, b, c)), lapp_assoc(t, b, c))

# the effects of a run of xs then ys
def effs_app(xs: List<&2, R.Cmd>, +ys: List<&2, R.Cmd>, +db: KV.Trie<String>) -> {List.append(&2, R.Cmd, effs(xs, db), effs(ys, Laws.final(R.exec_all(xs, db)))) == effs(List.append(&2, R.Cmd, xs, ys), db) : List<&2, R.Cmd>}:
  match xs:
    case Nil{}:
      {==}
    case Con{+c, +rest}:
      %fin_cons(c, rest, db) : {List.append(&2, R.Cmd, List.append(&2, R.Cmd, A.effect(c, R.reply_of(R.exec(c, db))), effs(rest, R.db_of(R.exec(c, db)))), effs(ys, _)) == effs(Con{c, List.append(&2, R.Cmd, rest, ys)}, db) : List<&2, R.Cmd>}
      %Equal.sym(List<&2, R.Cmd>, List.append(&2, R.Cmd, List.append(&2, R.Cmd, A.effect(c, R.reply_of(R.exec(c, db))), effs(rest, R.db_of(R.exec(c, db)))), effs(ys, Laws.final(R.exec_all(rest, R.db_of(R.exec(c, db)))))), List.append(&2, R.Cmd, A.effect(c, R.reply_of(R.exec(c, db))), List.append(&2, R.Cmd, effs(rest, R.db_of(R.exec(c, db))), effs(ys, Laws.final(R.exec_all(rest, R.db_of(R.exec(c, db))))))), lapp_assoc(A.effect(c, R.reply_of(R.exec(c, db))), effs(rest, R.db_of(R.exec(c, db))), effs(ys, Laws.final(R.exec_all(rest, R.db_of(R.exec(c, db))))))) : {_ == effs(Con{c, List.append(&2, R.Cmd, rest, ys)}, db) : List<&2, R.Cmd>}
      Equal.cong(List<&2, R.Cmd>, List<&2, R.Cmd>, z => List.append(&2, R.Cmd, A.effect(c, R.reply_of(R.exec(c, db))), z), List.append(&2, R.Cmd, effs(rest, R.db_of(R.exec(c, db))), effs(ys, Laws.final(R.exec_all(rest, R.db_of(R.exec(c, db)))))), effs(List.append(&2, R.Cmd, rest, ys), R.db_of(R.exec(c, db))), effs_app(rest, ys, R.db_of(R.exec(c, db))))

# a history's commands, run from an empty database, leave its database
def single_cmds(hist: List<&2, List<&2, R.Cmd>>) -> {Laws.final(R.exec_all(Laws.commands(hist), KV.empty(String))) == Laws.single(hist) : KV.Trie<String>}:
  match hist:
    case Nil{}:
      {==}
    case Con{+cs, +older}:
      %comp(Laws.commands(older), cs, KV.empty(String)) : {_ == Laws.single(Con{cs, older}) : KV.Trie<String>}
      Equal.cong(KV.Trie<String>, KV.Trie<String>, z => Laws.final(R.exec_all(cs, z)), Laws.final(R.exec_all(Laws.commands(older), KV.empty(String))), Laws.single(older), single_cmds(older))

# and their effects are the history's
def all_effs_cmds(hist: List<&2, List<&2, R.Cmd>>) -> {effs(Laws.commands(hist), KV.empty(String)) == all_effs(hist) : List<&2, R.Cmd>}:
  match hist:
    case Nil{}:
      {==}
    case Con{+cs, +older}:
      %effs_app(Laws.commands(older), cs, KV.empty(String)) : {_ == all_effs(Con{cs, older}) : List<&2, R.Cmd>}
      %single_cmds(older) : {List.append(&2, R.Cmd, effs(Laws.commands(older), KV.empty(String)), effs(cs, Laws.final(R.exec_all(Laws.commands(older), KV.empty(String))))) == List.append(&2, R.Cmd, all_effs(older), effs(cs, _)) : List<&2, R.Cmd>}
      %all_effs_cmds(older) : {List.append(&2, R.Cmd, effs(Laws.commands(older), KV.empty(String)), effs(cs, Laws.final(R.exec_all(Laws.commands(older), KV.empty(String))))) == List.append(&2, R.Cmd, _, effs(cs, Laws.final(R.exec_all(Laws.commands(older), KV.empty(String))))) : List<&2, R.Cmd>}
      {==}

# the first k parsed entries are the first k entries parsed
def ltake_parse(k: Nat, L: List<&2, List<&2, String>>) -> {ltake(R.Cmd, k, A.parse_all(L)) == A.parse_all(ltake(List<&2, String>, k, L)) : List<&2, R.Cmd>}:
  match k L:
    case 0n _:
      {==}
    case 1n+j Nil{}:
      {==}
    case 1n+j Con{r, rest}:
      Equal.cong(List<&2, R.Cmd>, List<&2, R.Cmd>, z => A.parse_cmd(r) <> z, ltake(R.Cmd, j, A.parse_all(rest)), A.parse_all(ltake(List<&2, String>, j, rest)), ltake_parse(j, rest))

# Recovering a cut file
# ---------------------

# the k whole entries in front of a cut replay the first k effects
def cut_db(+hist: List<&2, List<&2, R.Cmd>>, -c: String, +k: Nat, -r: String, p1: {A.load.go(String.length(c), c, A.entry(c), Nil{}) == (List.reverse.go(&2, List<&2, String>, Nil{}, ltake(List<&2, String>, k, A.args_all(all_effs(hist)))), r) : List<&2, List<&2, String>> & String}) -> {Pair.fst(KV.Trie<String>, String, A.restore(c)) == Laws.final(R.exec_all(ltake(R.Cmd, k, effs(Laws.commands(hist), KV.empty(String))), KV.empty(String))) : KV.Trie<String>}:
  %Equal.sym(List<&2, List<&2, String>> & String, A.load.go(String.length(c), c, A.entry(c), Nil{}), (List.reverse.go(&2, List<&2, String>, Nil{}, ltake(List<&2, String>, k, A.args_all(all_effs(hist)))), r), p1) : {Pair.fst(KV.Trie<String>, String, A.restore.of(_)) == Laws.final(R.exec_all(ltake(R.Cmd, k, effs(Laws.commands(hist), KV.empty(String))), KV.empty(String))) : KV.Trie<String>}
  %ltake_parse(k, A.args_all(all_effs(hist))) : {A.db_after(R.exec_all(_, KV.empty(String))) == Laws.final(R.exec_all(ltake(R.Cmd, k, effs(Laws.commands(hist), KV.empty(String))), KV.empty(String))) : KV.Trie<String>}
  %parse_all_effs(hist) : {A.db_after(R.exec_all(ltake(R.Cmd, k, _), KV.empty(String))) == Laws.final(R.exec_all(ltake(R.Cmd, k, effs(Laws.commands(hist), KV.empty(String))), KV.empty(String))) : KV.Trie<String>}
  %all_effs_cmds(hist) : {A.db_after(R.exec_all(ltake(R.Cmd, k, _), KV.empty(String))) == Laws.final(R.exec_all(ltake(R.Cmd, k, effs(Laws.commands(hist), KV.empty(String))), KV.empty(String))) : KV.Trie<String>}
  %eta_l(R.exec_all(ltake(R.Cmd, k, effs(Laws.commands(hist), KV.empty(String))), KV.empty(String))) : {A.db_after(_) == Laws.final(_) : KV.Trie<String>}
  {==}

# and so do the first j commands, for some j
def cut_held(+hist: List<&2, List<&2, R.Cmd>>, -c: String, -k: Nat, d0: {Pair.fst(KV.Trie<String>, String, A.restore(c)) == Laws.final(R.exec_all(ltake(R.Cmd, k, effs(Laws.commands(hist), KV.empty(String))), KV.empty(String))) : KV.Trie<String>}, ep: EP(Laws.commands(hist), KV.empty(String), k)) -> Exists(Nat, j => {Pair.fst(KV.Trie<String>, String, A.restore(c)) == Laws.held(hist, j) : KV.Trie<String>}):
  (+j, q) = ep
  (j, Equal.trans(KV.Trie<String>, Pair.fst(KV.Trie<String>, String, A.restore(c)), Laws.final(R.exec_all(ltake(R.Cmd, k, effs(Laws.commands(hist), KV.empty(String))), KV.empty(String))), Laws.held(hist, j), d0, q))

def cut_fin(+hist: List<&2, List<&2, R.Cmd>>, -c: String, res: Cut(String.length(c), c, Nil{}, A.args_all(all_effs(hist)))) -> Exists(Nat, j => {Pair.fst(KV.Trie<String>, String, A.restore(c)) == Laws.held(hist, j) : KV.Trie<String>}):
  (+k, q) = res
  (r, pq) = q
  (p1, p2) = pq
  cut_held(hist, c, k, cut_db(hist, c, k, r, p1), effs_prefix(Laws.commands(hist), KV.empty(String), k))

def Laws.recover_cut(hist, c, d, e):
  cut_fin(hist, c, load_cut_go(A.args_all(all_effs(hist)), c, d, String.length(c), Nil{})(aof_entries(hist, c, d, e))(le_refl(String.length(c))))

# Persistence on shards
# ---------------------
# A shard's history runs to its trie (shard_single): a batch's parts
# leave shard s its part run on its trie (at_after). Then recover gives
# each shard's file, and shard_holds every key.

def at_after(ps: List<&2, List<&2, S.Part>>, ts: List<&2, KV.Trie<String>>, s: Nat) -> {Laws.at(Laws.after(ps, ts), s) == Laws.final(R.exec_all(Laws.part_cmds(Laws.part_at(ps, s)), Laws.at(ts, s))) : KV.Trie<String>}:
  match ps ts s:
    case Nil{} _ _:
      {==}
    case Con{p, prest} Nil{} 0n:
      {==}
    case Con{p, prest} Nil{} 1n+t:
      at_after(prest, Nil{}, t)
    case Con{p, prest} Con{t0, trest} 0n:
      {==}
    case Con{p, prest} Con{t0, trest} 1n+t:
      at_after(prest, trest, t)

def shard_single(+n: U32, +s: Nat, hist: List<&2, List<&2, R.Cmd>>) -> {Laws.single(Laws.shard_hist(n, s, hist)) == Laws.at(Laws.shards(n, hist), s) : KV.Trie<String>}:
  match hist:
    case Nil{}:
      {==}
    case Con{+cs, +older}:
      %split_eq(n, cs) : {Laws.final(R.exec_all(Laws.part_cmds(Laws.part_at(Laws.sh_parts(_), s)), Laws.single(Laws.shard_hist(n, s, older)))) == Laws.at(Laws.sh_tries(Laws.sharded.go(Laws.shards(n, older), _)), s) : KV.Trie<String>}
      %Equal.sym(KV.Trie<String>, Laws.single(Laws.shard_hist(n, s, older)), Laws.at(Laws.shards(n, older), s), shard_single(n, s, older)) : {Laws.final(R.exec_all(Laws.part_cmds(Laws.part_at(parts_of(n, cs), s)), _)) == Laws.at(Laws.after(parts_of(n, cs), Laws.shards(n, older)), s) : KV.Trie<String>}
      Equal.sym(KV.Trie<String>, Laws.at(Laws.after(parts_of(n, cs), Laws.shards(n, older)), s), Laws.final(R.exec_all(Laws.part_cmds(Laws.part_at(parts_of(n, cs), s)), Laws.at(Laws.shards(n, older), s))), at_after(parts_of(n, cs), Laws.shards(n, older), s))

def Laws.shard_recover(n, s, hist):
  %shard_single(n, s, hist) : {A.restore(Laws.aof(Laws.shard_hist(n, s, hist))) == (_, "") : KV.Trie<String> & String}
  Laws.recover(Laws.shard_hist(n, s, hist))

def Laws.shard_restore(n, hist, k):
  %Equal.sym(KV.Trie<String> & String, A.restore(Laws.aof(Laws.shard_hist(n, Laws.shard(n, k), hist))), (Laws.at(Laws.shards(n, hist), Laws.shard(n, k)), ""), Laws.shard_recover(n, Laws.shard(n, k), hist)) : {KV.get(String, Pair.fst(KV.Trie<String>, String, _), k) == KV.get(String, Laws.single(hist), k) : Maybe<&2, String>}
  Laws.shard_holds(n, hist, k)

def Laws.shard_recover_cut(n, s, hist, c, d, e):
  Laws.recover_cut(Laws.shard_hist(n, s, hist), c, d, e)
