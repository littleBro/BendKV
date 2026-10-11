# PROOF.bend: the proofs of LAWS.bend. Run `bend proof/PROOF.bend`: it prints
# ALL PROOFS CHECK only when every law is proven; `--verdict` rechecks
# the proofs with BendTT, the kernel proven sound in Lean.

import Base
import ../src/map.bend as KV
import ../src/redis.bend as R
import ../src/batch.bend as B
import ../src/resp.bend as P
import ../src/aof.bend as A
import ../src/session.bend as S
import ../src/config.bend as C
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
# hex_eq decides whether two digits are the same; it serves only the
# proofs, which split on whether two walks take the same digits
def hex_eq(x: KV.Hex, y: KV.Hex) -> Bool:
  match x y:
    case KV.H0{} KV.H0{}:
      True{}
    case KV.H0{} other:
      False{}
    case KV.H1{} KV.H1{}:
      True{}
    case KV.H1{} other:
      False{}
    case KV.H2{} KV.H2{}:
      True{}
    case KV.H2{} other:
      False{}
    case KV.H3{} KV.H3{}:
      True{}
    case KV.H3{} other:
      False{}
    case KV.H4{} KV.H4{}:
      True{}
    case KV.H4{} other:
      False{}
    case KV.H5{} KV.H5{}:
      True{}
    case KV.H5{} other:
      False{}
    case KV.H6{} KV.H6{}:
      True{}
    case KV.H6{} other:
      False{}
    case KV.H7{} KV.H7{}:
      True{}
    case KV.H7{} other:
      False{}
    case KV.H8{} KV.H8{}:
      True{}
    case KV.H8{} other:
      False{}
    case KV.H9{} KV.H9{}:
      True{}
    case KV.H9{} other:
      False{}
    case KV.H10{} KV.H10{}:
      True{}
    case KV.H10{} other:
      False{}
    case KV.H11{} KV.H11{}:
      True{}
    case KV.H11{} other:
      False{}
    case KV.H12{} KV.H12{}:
      True{}
    case KV.H12{} other:
      False{}
    case KV.H13{} KV.H13{}:
      True{}
    case KV.H13{} other:
      False{}
    case KV.H14{} KV.H14{}:
      True{}
    case KV.H14{} other:
      False{}
    case KV.H15{} KV.H15{}:
      True{}
    case KV.H15{} other:
      False{}

# digits that hex_eq calls the same are the same
def hex_eq_sound(x: KV.Hex, y: KV.Hex) -> {hex_eq(x, y) == True{} : Bool} -> {x == y : KV.Hex}:
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
      Bool.and(hex_eq(x1, x2), dsame(p, KV.hex(KV.shr4(h1)), KV.shr4(h1), KV.hex(KV.shr4(h2)), KV.shr4(h2)))

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
  -> {c == hex_eq(x1, x2) : Bool}
  -> {Bool.and(c, dsame(p, KV.hex(KV.shr4(h1)), KV.shr4(h1), KV.hex(KV.shr4(h2)), KV.shr4(h2))) == True{} : Bool}
  -> {KV.tget_h(V, 1n+p, t, x1, h1) == KV.tget_h(V, 1n+p, t, x2, h2) : KV.Trie<V>}:
  match c:
    case False{}:
      ec => e => Empty.absurd({KV.tget_h(V, 1n+p, t, x1, h1) == KV.tget_h(V, 1n+p, t, x2, h2) : KV.Trie<V>}, false_true(e))
    case True{}:
      ec => e => %hex_eq_sound(x1, x2)(Equal.sym(Bool, True{}, hex_eq(x1, x2), ec)) : {KV.tget_h(V, 1n+p, t, x1, h1) == KV.tget_h(V, 1n+p, t, _, h2) : KV.Trie<V>}
                 walk_same_step(V, p, t, x1, h1, h2, ih)(e)

# two walks that take the same digits end in the same bucket
def walk_same(-V: Data, d: Nat, +t: KV.Trie<V>, +x1: KV.Hex, +h1: U32, +x2: KV.Hex, +h2: U32) -> {dsame(d, x1, h1, x2, h2) == True{} : Bool} -> {KV.tget_h(V, d, t, x1, h1) == KV.tget_h(V, d, t, x2, h2) : KV.Trie<V>}:
  match d:
    case 0n:
      e => {==}
    case 1n+p:
      same_step(V, p, t, x1, h1, x2, h2, hex_eq(x1, x2), u => walk_same(V, p, u, KV.hex(KV.shr4(h1)), KV.shr4(h1), KV.hex(KV.shr4(h2)), KV.shr4(h2)))({==})

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
def upd_other_node(-V: Data, -p: Nat, -c0: KV.Trie<V>, -c1: KV.Trie<V>, -c2: KV.Trie<V>, -c3: KV.Trie<V>, -c4: KV.Trie<V>, -c5: KV.Trie<V>, -c6: KV.Trie<V>, -c7: KV.Trie<V>, -c8: KV.Trie<V>, -c9: KV.Trie<V>, -c10: KV.Trie<V>, -c11: KV.Trie<V>, -c12: KV.Trie<V>, -c13: KV.Trie<V>, -c14: KV.Trie<V>, -c15: KV.Trie<V>, x1: KV.Hex, -h1: U32, x2: KV.Hex, -h2: U32, -op: KV.Op<V>) -> {hex_eq(x1, x2) == False{} : Bool} -> {KV.tget_h(V, 1n+p, KV.tmod_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, x1, h1, op), x2, h2) == KV.tget_h(V, 1n+p, KV.Node{c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14, c15}, x2, h2) : KV.Trie<V>}:
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
def upd_other(-V: Data, +p: Nat, +t: KV.Trie<V>, +x1: KV.Hex, +h1: U32, +x2: KV.Hex, +h2: U32, +op: KV.Op<V>) -> {hex_eq(x1, x2) == False{} : Bool} -> {KV.tget_h(V, 1n+p, KV.tmod_h(V, 1n+p, t, x1, h1, op), x2, h2) == KV.tget_h(V, 1n+p, t, x2, h2) : KV.Trie<V>}:
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
  -> {c == hex_eq(x1, x2) : Bool}
  -> {Bool.and(c, dsame(p, KV.hex(KV.shr4(h1)), KV.shr4(h1), KV.hex(KV.shr4(h2)), KV.shr4(h2))) == False{} : Bool}
  -> {KV.tget_h(V, 1n+p, KV.tmod_h(V, 1n+p, t, x1, h1, op), x2, h2) == KV.tget_h(V, 1n+p, t, x2, h2) : KV.Trie<V>}:
  match c:
    case False{}:
      ec => e => upd_other(V, p, t, x1, h1, x2, h2, op)(Equal.sym(Bool, False{}, hex_eq(x1, x2), ec))
    case True{}:
      ec => e => %hex_eq_sound(x1, x2)(Equal.sym(Bool, True{}, hex_eq(x1, x2), ec)) : {KV.tget_h(V, 1n+p, KV.tmod_h(V, 1n+p, t, x1, h1, op), _, h2) == KV.tget_h(V, 1n+p, t, _, h2) : KV.Trie<V>}
                 same_digit_step(V, p, t, x1, h1, h2, op, ih)(e)

# a read of any other bucket does not see the modification
def tget_tmod_other(-V: Data, d: Nat, +t: KV.Trie<V>, +x1: KV.Hex, +h1: U32, +x2: KV.Hex, +h2: U32, +op: KV.Op<V>) -> {dsame(d, x1, h1, x2, h2) == False{} : Bool} -> {KV.tget_h(V, d, KV.tmod_h(V, d, t, x1, h1, op), x2, h2) == KV.tget_h(V, d, t, x2, h2) : KV.Trie<V>}:
  match d:
    case 0n:
      e => Empty.absurd({KV.tget_h(V, 0n, KV.tmod_h(V, 0n, t, x1, h1, op), x2, h2) == KV.tget_h(V, 0n, t, x2, h2) : KV.Trie<V>}, true_false(e))
    case 1n++p:
      other_step(V, p, t, x1, h1, x2, h2, op, hex_eq(x1, x2), u => tget_tmod_other(V, p, u, KV.hex(KV.shr4(h1)), KV.shr4(h1), KV.hex(KV.shr4(h2)), KV.shr4(h2), op))({==})

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

# GET answers a copy of the value KV.get reads (tget_kc_eq)
def get_copy_eq(+t: KV.Trie<String>, +k: String) -> {KV.get(String, t, k) == KV.get_copy(t, k) : Maybe<&2, String>}:
  tget_kc_eq(5n, t, KV.hex(KV.hash(k)), KV.hash(k), k)

def Laws.get_after_set(db, k, v):
  %get_copy_eq(KV.set(String, db, k, v), k) : {R.r_get(_) == R.RBulk{v} : R.Reply}
  Equal.cong(Maybe<&2, String>, R.Reply, m => R.r_get(m), KV.get(String, KV.set(String, db, k, v), k), Some{v}, Laws.get_set_same(String, db, k, v))

def Laws.get_missing(db, k, e):
  %get_copy_eq(db, k) : {(R.r_get(_), db) == (R.RNull{}, db) : R.Reply & KV.Trie<String>}
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
    case R.Peek{k, o}:
      e => {==}
    case R.MGet{ks}:
      e => {==}
    case R.DbSize{}:
      e => {==}
    case R.Keys{p}:
      e => {==}
    case R.Peek{k, o}:
      e => {==}
    case R.Own{o}:
      e => {==}
    case R.Bad{r}:
      e => {==}
    case R.Own{o}:
      e => {==}
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
      e => Empty.absurd({KV.get(String, KV.empty(String), j) == KV.get(String, db, j) : Maybe<&2, String>}, true_false(e))
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
    case R.Peek{k, o}:
      e => {==}
    case R.MGet{ks}:
      e => {==}
    case R.DbSize{}:
      e => {==}
    case R.Keys{p}:
      e => {==}
    case R.Bad{r}:
      e => {==}
    case R.Own{o}:
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

# a batch's database after its first command runs is the one after it
def fin_cons(+c: R.Cmd, +cs: List<&2, R.Cmd>, +t: KV.Trie<String>) -> {Laws.final(R.exec_all(cs, R.db_of(R.exec(c, t)))) == Laws.final(R.exec_all(Con{c, cs}, t)) : KV.Trie<String>}:
  %Equal.sym(List<&2, R.Reply> & KV.Trie<String>, R.exec_all(Con{c, cs}, t), R.exec_all.cons(R.reply_of(R.exec(c, t)), R.exec_all(cs, R.db_of(R.exec(c, t)))), Laws.batch_step(c, cs, t)) : {Laws.final(R.exec_all(cs, R.db_of(R.exec(c, t)))) == Laws.final(_) : KV.Trie<String>}
  %eta_l(R.exec_all(cs, R.db_of(R.exec(c, t)))) : {Laws.final(_) == Laws.final(R.exec_all.cons(R.reply_of(R.exec(c, t)), _)) : KV.Trie<String>}
  {==}

# Hints
# -----

# a batch run after its hints is exec_all, whatever the hints' verdict
def hinted_any(u: Bool, +cs: List<&2, R.Cmd>, +db: KV.Trie<String>) -> {B.exec_hinted(u, cs, db) == R.exec_all(cs, db) : List<&2, R.Reply> & KV.Trie<String>}:
  match u:
    case True{}:
      {==}
    case False{}:
      {==}

def Laws.batch_hints(cs, hs, db):
  hinted_any(U32.is_eq(B.touch_if(B.many(hs), hs, db), 0), cs, db)

# Locality
# ========
# A command on one key: its reply depends only on what its key reads.

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

# the key of a command on keys ("" for a command of no key)
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
    case R.Peek{k, o}:
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
    case R.Peek{k, o}:
      True{}
    case R.Del{ks}:
      one_key(ks)
    case R.Exists{ks}:
      one_key(ks)
    case _:
      False{}

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
      kd => e => %get_copy_eq(t, k) : {R.r_get(_) == R.r_get(KV.get_copy(u, k)) : R.Reply}
                 %get_copy_eq(u, k) : {R.r_get(KV.get(String, t, k)) == R.r_get(_) : R.Reply}
                 Equal.cong(Maybe<&2, String>, R.Reply, m => R.r_get(m), KV.get(String, t, k), KV.get(String, u, k), e)
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
    case R.Peek{+k, o}:
      kd => e => Equal.cong(Maybe<&2, String>, R.Reply, m => R.peek(o, m), KV.get(String, t, k), KV.get(String, u, k), e)
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
    case R.Own{o}:
      kd => e => Empty.absurd({R.reply_of(R.exec(R.Own{o}, t)) == R.reply_of(R.exec(R.Own{o}, u)) : R.Reply}, false_true(kd))

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
    case R.Peek{+k, o}:
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
    case R.Own{o}:
      kd => e => Empty.absurd({KV.get(String, R.db_of(R.exec(R.Own{o}, t)), "") == KV.get(String, R.db_of(R.exec(R.Own{o}, u)), "") : Maybe<&2, String>}, false_true(kd))

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
    case R.Peek{k, o}:
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
    case R.Own{o}:
      kd => nb => Empty.absurd({Laws.writes(R.Own{o}, j) == False{} : Bool}, false_true(kd))


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
    case R.Peek{k, o}:
      e => e
    case R.MGet{ks}:
      e => e
    case R.MSet{+ps}:
      mset_point(ps, t, u, j)
    case R.DbSize{}:
      e => e
    case R.FlushAll{}:
      e => {==}
    case R.Keys{p}:
      e => e
    case R.Bad{r}:
      e => e
    case R.Own{o}:
      e => e

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

def mget_after(ks: List<&2, String>, +c2: R.Cmd, +db: KV.Trie<String>) -> {Laws.writes_any(c2, ks) == False{} : Bool} -> {R.mget_keys(ks, R.db_of(R.exec(c2, db))) == R.mget_keys(ks, db) : List<&2, R.Reply>}:
  match ks:
    case Nil{}:
      e => {==}
    case Con{+k, +rest}:
      +e => %Laws.frame(c2, db, k, or_false_l(Laws.writes(c2, k), Laws.writes_any(c2, rest))(e)) : {R.i_get(KV.get(String, R.db_of(R.exec(c2, db)), k)) <> R.mget_keys(rest, R.db_of(R.exec(c2, db))) == R.i_get(_) <> R.mget_keys(rest, db) : List<&2, R.Reply>}
            Equal.cong(List<&2, R.Reply>, List<&2, R.Reply>, z => R.i_get(KV.get(String, R.db_of(R.exec(c2, db)), k)) <> z, R.mget_keys(rest, R.db_of(R.exec(c2, db))), R.mget_keys(rest, db), mget_after(rest, c2, db)(or_false_r(Laws.writes(c2, k), Laws.writes_any(c2, rest))(e)))

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
    case R.Peek{+k, o}:
      e => loc_reply(R.Peek{k, o}, R.db_of(R.exec(c2, db)), db)({==})(Laws.frame(c2, db, k, e))
    case R.MGet{+ks}:
      e => Equal.cong(List<&2, R.Reply>, R.Reply, z => R.RArray{z}, R.mget_keys(ks, R.db_of(R.exec(c2, db))), R.mget_keys(ks, db), mget_after(ks, c2, db)(e))
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
    case R.Own{o}:
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
    case R.Peek{k, o}:
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
    case R.Own{o}:
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
    case R.Peek{k, o}:
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
    case R.Own{o}:
      e => {==}

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

def mget_tw(+c1: R.Cmd, +c2: R.Cmd, +db: KV.Trie<String>, +H: List<&2, R.Cmd>, +e: {Laws.clash(c2, c1) == False{} : Bool}, ks: List<&2, String>) -> {R.mget_keys(ks, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))))) == R.mget_keys(ks, tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))))) : List<&2, R.Reply>}:
  match ks:
    case Nil{}:
      {==}
    case Con{+k, +rest}:
      %eq_at(c1, c2, db, H, k, e) : {R.i_get(KV.get(String, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))), k)) <> R.mget_keys(rest, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))))) == R.i_get(_) <> R.mget_keys(rest, tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))))) : List<&2, R.Reply>}
      Equal.cong(List<&2, R.Reply>, List<&2, R.Reply>, z => R.i_get(KV.get(String, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))), k)) <> z, R.mget_keys(rest, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))))), R.mget_keys(rest, tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))))), mget_tw(c1, c2, db, H, e, rest))

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
    case R.Peek{+k, o}:
      kw => loc_reply(R.Peek{k, o}, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db))))), tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db))))))({==})(eq_at(c1, c2, db, H, k, e))
    case R.MGet{+ks}:
      kw => Equal.cong(List<&2, R.Reply>, R.Reply, z => R.RArray{z}, R.mget_keys(ks, tw(H, R.db_of(R.exec(c2, R.db_of(R.exec(c1, db)))))), R.mget_keys(ks, tw(H, R.db_of(R.exec(c1, R.db_of(R.exec(c2, db)))))), mget_tw(c1, c2, db, H, e, ks))
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
    case R.Own{o}:
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

# the log run after its hints is exec_log, whatever the hints' verdict
def log_hinted_any(u: Bool, +cs: List<&2, R.Cmd>, +db: KV.Trie<String>) -> {A.log_hinted(u, cs, db) == A.exec_log(cs, db) : List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>)}:
  match u:
    case True{}:
      {==}
    case False{}:
      {==}

def Laws.log_hints(cs, hs, db):
  log_hinted_any(U32.is_eq(B.touch_if(B.many(hs), hs, db), 0), cs, db)

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
    case R.Peek{k, o}:
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
    case R.Own{o}:
      {==}

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
    case R.Peek{k, o}:
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
    case R.Own{o}:
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
      Equal.cong(List<&2, R.Cmd>, List<&2, R.Cmd>, z => R.parse(r) <> z, List.append(&2, R.Cmd, A.parse_all(rest), A.parse_all(ys)), A.parse_all(List.append(&2, List<&2, String>, rest, ys)), parse_app(rest, ys))

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
    case R.Peek{k, o}:
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
    case R.Own{o}:
      Inl{{==}}

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
      Equal.cong(List<&2, R.Cmd>, List<&2, R.Cmd>, z => R.parse(r) <> z, ltake(R.Cmd, j, A.parse_all(rest)), A.parse_all(ltake(List<&2, String>, j, rest)), ltake_parse(j, rest))

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

# Sessions
# ========
# The general path (S.gen) folds a batch with its replies and its effects
# in reverse, as exec_all and exec_log do. rep1, eff_if and db_if spell
# one command of it: the reply it sends, if any, and, when it runs on the
# database (S.ran), its effects and the database after it; greps, gconn
# and gsrv spell a batch's replies, connection and server by plain
# recursion. gen_spec makes the fold these, with the effects and the
# database of the commands that ran (S.plan) as effs and run give them.
# A batch of database commands from a client that is ready runs every
# command and sends every reply, so gen is then exec_all (fast_eq); the
# server's unzip hands gen the batch's commands in order (unzip_gen). A
# client that has not authenticated stays so, and runs only the errors
# the parser found (noauth_go).

# the reply of a command of kind k that runs (ok) or is refused
def rep.k(+k: S.Role, ok: Bool, +c: R.Cmd, +conn: S.Conn, +srv: S.Srv, +d: KV.Trie<String>) -> Maybe<&2, R.Reply>:
  match k ok:
    case S.KSess{o} True{}:
      S.own_reply(o, conn, srv, d)
    case S.KSess{o} False{}:
      S.say(S.conn.mode(conn), S.e_noauth())
    case _ True{}:
      S.say(S.conn.mode(conn), R.reply_of(R.exec(c, d)))
    case _ False{}:
      S.say(S.conn.mode(conn), S.e_noauth())

# the reply a command sends, if any (none after QUIT)
def rep1(q: Bool, +c: R.Cmd, +conn: S.Conn, +srv: S.Srv, +d: KV.Trie<String>) -> Maybe<&2, R.Reply>:
  match q:
    case True{}:
      None{}
    case False{}:
      rep.k(S.kind(c), S.may(S.kind(c), conn, srv), c, conn, srv, d)

# a command's effects and the database after it, when it runs
def eff_if(b: Bool, +c: R.Cmd, +d: KV.Trie<String>) -> List<&2, R.Cmd>:
  match b:
    case True{}:
      A.effect(c, R.reply_of(R.exec(c, d)))
    case False{}:
      Nil{}

def db_if(b: Bool, +c: R.Cmd, +d: KV.Trie<String>) -> KV.Trie<String>:
  match b:
    case True{}:
      R.db_of(R.exec(c, d))
    case False{}:
      d

def out_k(+k: S.Role, ok: Bool, +c: R.Cmd, +rs: List<&2, R.Reply>, +es: List<&2, R.Cmd>, +conn: S.Conn, +srv: S.Srv, +d: KV.Trie<String>)
  -> {S.Out{S.put(rep.k(k, ok, c, conn, srv, d), rs), List.reverse.go(&2, R.Cmd, eff_if(S.ran.k(k, ok), c, d), es), db_if(S.ran.k(k, ok), c, d)} == S.out.k(k, ok, c, rs, es, conn, srv, d) : S.Out}:
  match k ok:
    case S.KSess{o} True{}:
      {==}
    case S.KSess{o} False{}:
      {==}
    case S.KData{} True{}:
      %eta_r(R.exec(c, d)) : {S.Out{S.put(S.say(S.conn.mode(conn), R.reply_of(R.exec(c, d))), rs), List.reverse.go(&2, R.Cmd, A.effect(c, R.reply_of(R.exec(c, d))), es), R.db_of(R.exec(c, d))} == S.out.data(c, rs, es, S.conn.mode(conn), _) : S.Out}
      {==}
    case S.KData{} False{}:
      {==}
    case S.KBad{} True{}:
      %eta_r(R.exec(c, d)) : {S.Out{S.put(S.say(S.conn.mode(conn), R.reply_of(R.exec(c, d))), rs), List.reverse.go(&2, R.Cmd, A.effect(c, R.reply_of(R.exec(c, d))), es), R.db_of(R.exec(c, d))} == S.out.data(c, rs, es, S.conn.mode(conn), _) : S.Out}
      {==}
    case S.KBad{} False{}:
      {==}

def out_q(q: Bool, +c: R.Cmd, +rs: List<&2, R.Reply>, +es: List<&2, R.Cmd>, +conn: S.Conn, +srv: S.Srv, +d: KV.Trie<String>)
  -> {S.Out{S.put(rep1(q, c, conn, srv, d), rs), List.reverse.go(&2, R.Cmd, eff_if(S.ran(q, c, conn, srv), c, d), es), db_if(S.ran(q, c, conn, srv), c, d)} == S.out.q(q, c, rs, es, conn, srv, d) : S.Out}:
  match q:
    case True{}:
      {==}
    case False{}:
      out_k(S.kind(c), S.may(S.kind(c), conn, srv), c, rs, es, conn, srv, d)

def opt_cons(m: Maybe<&2, R.Reply>, xs: List<&2, R.Reply>) -> List<&2, R.Reply>:
  match m:
    case Some{r}:
      r <> xs
    case None{}:
      xs

# the replies a batch sends, the connection and the server after it
def greps(cs: List<&2, R.Cmd>, +conn: S.Conn, +srv: S.Srv, +d: KV.Trie<String>) -> List<&2, R.Reply>:
  match cs:
    case Nil{}:
      Nil{}
    case Con{+c, rest}:
      opt_cons(rep1(S.conn.quit(conn), c, conn, srv, d), greps(rest, S.next_conn(S.conn.quit(conn), c, conn, srv), S.next_srv(S.conn.quit(conn), c, conn, srv), db_if(S.ran(S.conn.quit(conn), c, conn, srv), c, d)))

def gconn(cs: List<&2, R.Cmd>, +conn: S.Conn, +srv: S.Srv) -> S.Conn:
  match cs:
    case Nil{}:
      conn
    case Con{+c, rest}:
      gconn(rest, S.next_conn(S.conn.quit(conn), c, conn, srv), S.next_srv(S.conn.quit(conn), c, conn, srv))

def gsrv(cs: List<&2, R.Cmd>, +conn: S.Conn, +srv: S.Srv) -> S.Srv:
  match cs:
    case Nil{}:
      srv
    case Con{+c, rest}:
      gsrv(rest, S.next_conn(S.conn.quit(conn), c, conn, srv), S.next_srv(S.conn.quit(conn), c, conn, srv))

def rev_opt(m: Maybe<&2, R.Reply>, -xs: List<&2, R.Reply>, -rs: List<&2, R.Reply>) -> {List.reverse.go(&2, R.Reply, opt_cons(m, xs), rs) == List.reverse.go(&2, R.Reply, xs, S.put(m, rs)) : List<&2, R.Reply>}:
  match m:
    case Some{r}:
      {==}
    case None{}:
      {==}

def rev_app_go(e: List<&2, R.Cmd>, -ys: List<&2, R.Cmd>, -acc: List<&2, R.Cmd>) -> {List.reverse.go(&2, R.Cmd, List.append(&2, R.Cmd, e, ys), acc) == List.reverse.go(&2, R.Cmd, ys, List.reverse.go(&2, R.Cmd, e, acc)) : List<&2, R.Cmd>}:
  match e:
    case Nil{}:
      {==}
    case Con{h, t}:
      rev_app_go(t, ys, h <> acc)

# the effects and the database of a command that runs or not, then more
def effs_keep(b: Bool, +c: R.Cmd, +p: List<&2, R.Cmd>, +d: KV.Trie<String>, +es: List<&2, R.Cmd>) -> {List.reverse.go(&2, R.Cmd, effs(List.append(&2, R.Cmd, S.keep(b, c), p), d), es) == List.reverse.go(&2, R.Cmd, effs(p, db_if(b, c, d)), List.reverse.go(&2, R.Cmd, eff_if(b, c, d), es)) : List<&2, R.Cmd>}:
  match b:
    case True{}:
      rev_app_go(A.effect(c, R.reply_of(R.exec(c, d))), effs(p, R.db_of(R.exec(c, d))), es)
    case False{}:
      {==}

def run_keep(b: Bool, +c: R.Cmd, +p: List<&2, R.Cmd>, +d: KV.Trie<String>) -> {rsnd(run(List.append(&2, R.Cmd, S.keep(b, c), p), d)) == rsnd(run(p, db_if(b, c, d))) : KV.Trie<String>}:
  match b:
    case True{}:
      %eta_l(run(p, R.db_of(R.exec(c, d)))) : {rsnd(R.exec_all.cons(R.reply_of(R.exec(c, d)), _)) == rsnd(run(p, R.db_of(R.exec(c, d)))) : KV.Trie<String>}
      {==}
    case False{}:
      {==}

def gen5(-a1: List<&2, R.Reply>, -a2: List<&2, R.Reply>, -b1: List<&2, R.Cmd>, -b2: List<&2, R.Cmd>, -c: S.Conn, -s: S.Srv, -e1: KV.Trie<String>, -e2: KV.Trie<String>, ea: {a1 == a2 : List<&2, R.Reply>}, eb: {b1 == b2 : List<&2, R.Cmd>}, ee: {e1 == e2 : KV.Trie<String>}) -> {S.Gen{a1, b1, c, s, e1} == S.Gen{a2, b2, c, s, e2} : S.Gen}:
  %ea : {S.Gen{a1, b1, c, s, e1} == S.Gen{_, b2, c, s, e2} : S.Gen}
  %eb : {S.Gen{a1, b1, c, s, e1} == S.Gen{a1, _, c, s, e2} : S.Gen}
  %ee : {S.Gen{a1, b1, c, s, e1} == S.Gen{a1, b1, c, s, _} : S.Gen}
  {==}

# gen is its spec
def gen_spec(cs: List<&2, R.Cmd>, +rs: List<&2, R.Reply>, +es: List<&2, R.Cmd>, +conn: S.Conn, +srv: S.Srv, +d: KV.Trie<String>) -> {S.Gen{List.reverse.go(&2, R.Reply, greps(cs, conn, srv, d), rs), List.reverse.go(&2, R.Cmd, effs(S.plan(cs, conn, srv), d), es), gconn(cs, conn, srv), gsrv(cs, conn, srv), rsnd(run(S.plan(cs, conn, srv), d))} == S.gen.go(cs, S.Gen{rs, es, conn, srv, d}) : S.Gen}:
  match cs:
    case Nil{}:
      {==}
    case Con{+c, +rest}:
      %out_q(S.conn.quit(conn), c, rs, es, conn, srv, d) : {S.Gen{List.reverse.go(&2, R.Reply, greps(Con{c, rest}, conn, srv, d), rs), List.reverse.go(&2, R.Cmd, effs(S.plan(Con{c, rest}, conn, srv), d), es), gconn(Con{c, rest}, conn, srv), gsrv(Con{c, rest}, conn, srv), rsnd(run(S.plan(Con{c, rest}, conn, srv), d))} == S.gen.go(rest, S.gen.mk(_, S.next_conn(S.conn.quit(conn), c, conn, srv), S.next_srv(S.conn.quit(conn), c, conn, srv))) : S.Gen}
      %gen_spec(rest, S.put(rep1(S.conn.quit(conn), c, conn, srv, d), rs), List.reverse.go(&2, R.Cmd, eff_if(S.ran(S.conn.quit(conn), c, conn, srv), c, d), es), S.next_conn(S.conn.quit(conn), c, conn, srv), S.next_srv(S.conn.quit(conn), c, conn, srv), db_if(S.ran(S.conn.quit(conn), c, conn, srv), c, d)) : {S.Gen{List.reverse.go(&2, R.Reply, greps(Con{c, rest}, conn, srv, d), rs), List.reverse.go(&2, R.Cmd, effs(S.plan(Con{c, rest}, conn, srv), d), es), gconn(Con{c, rest}, conn, srv), gsrv(Con{c, rest}, conn, srv), rsnd(run(S.plan(Con{c, rest}, conn, srv), d))} == _ : S.Gen}
      Equal.sym(S.Gen, S.Gen{List.reverse.go(&2, R.Reply, greps(rest, S.next_conn(S.conn.quit(conn), c, conn, srv), S.next_srv(S.conn.quit(conn), c, conn, srv), db_if(S.ran(S.conn.quit(conn), c, conn, srv), c, d)), S.put(rep1(S.conn.quit(conn), c, conn, srv, d), rs)), List.reverse.go(&2, R.Cmd, effs(S.plan(rest, S.next_conn(S.conn.quit(conn), c, conn, srv), S.next_srv(S.conn.quit(conn), c, conn, srv)), db_if(S.ran(S.conn.quit(conn), c, conn, srv), c, d)), List.reverse.go(&2, R.Cmd, eff_if(S.ran(S.conn.quit(conn), c, conn, srv), c, d), es)), gconn(rest, S.next_conn(S.conn.quit(conn), c, conn, srv), S.next_srv(S.conn.quit(conn), c, conn, srv)), gsrv(rest, S.next_conn(S.conn.quit(conn), c, conn, srv), S.next_srv(S.conn.quit(conn), c, conn, srv)), rsnd(run(S.plan(rest, S.next_conn(S.conn.quit(conn), c, conn, srv), S.next_srv(S.conn.quit(conn), c, conn, srv)), db_if(S.ran(S.conn.quit(conn), c, conn, srv), c, d)))}, S.Gen{List.reverse.go(&2, R.Reply, greps(Con{c, rest}, conn, srv, d), rs), List.reverse.go(&2, R.Cmd, effs(S.plan(Con{c, rest}, conn, srv), d), es), gconn(Con{c, rest}, conn, srv), gsrv(Con{c, rest}, conn, srv), rsnd(run(S.plan(Con{c, rest}, conn, srv), d))},
        gen5(List.reverse.go(&2, R.Reply, greps(rest, S.next_conn(S.conn.quit(conn), c, conn, srv), S.next_srv(S.conn.quit(conn), c, conn, srv), db_if(S.ran(S.conn.quit(conn), c, conn, srv), c, d)), S.put(rep1(S.conn.quit(conn), c, conn, srv, d), rs)), List.reverse.go(&2, R.Reply, opt_cons(rep1(S.conn.quit(conn), c, conn, srv, d), greps(rest, S.next_conn(S.conn.quit(conn), c, conn, srv), S.next_srv(S.conn.quit(conn), c, conn, srv), db_if(S.ran(S.conn.quit(conn), c, conn, srv), c, d))), rs),
             List.reverse.go(&2, R.Cmd, effs(S.plan(rest, S.next_conn(S.conn.quit(conn), c, conn, srv), S.next_srv(S.conn.quit(conn), c, conn, srv)), db_if(S.ran(S.conn.quit(conn), c, conn, srv), c, d)), List.reverse.go(&2, R.Cmd, eff_if(S.ran(S.conn.quit(conn), c, conn, srv), c, d), es)), List.reverse.go(&2, R.Cmd, effs(List.append(&2, R.Cmd, S.keep(S.ran(S.conn.quit(conn), c, conn, srv), c), S.plan(rest, S.next_conn(S.conn.quit(conn), c, conn, srv), S.next_srv(S.conn.quit(conn), c, conn, srv))), d), es),
             gconn(rest, S.next_conn(S.conn.quit(conn), c, conn, srv), S.next_srv(S.conn.quit(conn), c, conn, srv)), gsrv(rest, S.next_conn(S.conn.quit(conn), c, conn, srv), S.next_srv(S.conn.quit(conn), c, conn, srv)),
             rsnd(run(S.plan(rest, S.next_conn(S.conn.quit(conn), c, conn, srv), S.next_srv(S.conn.quit(conn), c, conn, srv)), db_if(S.ran(S.conn.quit(conn), c, conn, srv), c, d))), rsnd(run(List.append(&2, R.Cmd, S.keep(S.ran(S.conn.quit(conn), c, conn, srv), c), S.plan(rest, S.next_conn(S.conn.quit(conn), c, conn, srv), S.next_srv(S.conn.quit(conn), c, conn, srv))), d)),
             Equal.sym(List<&2, R.Reply>, List.reverse.go(&2, R.Reply, opt_cons(rep1(S.conn.quit(conn), c, conn, srv, d), greps(rest, S.next_conn(S.conn.quit(conn), c, conn, srv), S.next_srv(S.conn.quit(conn), c, conn, srv), db_if(S.ran(S.conn.quit(conn), c, conn, srv), c, d))), rs), List.reverse.go(&2, R.Reply, greps(rest, S.next_conn(S.conn.quit(conn), c, conn, srv), S.next_srv(S.conn.quit(conn), c, conn, srv), db_if(S.ran(S.conn.quit(conn), c, conn, srv), c, d)), S.put(rep1(S.conn.quit(conn), c, conn, srv, d), rs)), rev_opt(rep1(S.conn.quit(conn), c, conn, srv, d), greps(rest, S.next_conn(S.conn.quit(conn), c, conn, srv), S.next_srv(S.conn.quit(conn), c, conn, srv), db_if(S.ran(S.conn.quit(conn), c, conn, srv), c, d)), rs)),
             Equal.sym(List<&2, R.Cmd>, List.reverse.go(&2, R.Cmd, effs(List.append(&2, R.Cmd, S.keep(S.ran(S.conn.quit(conn), c, conn, srv), c), S.plan(rest, S.next_conn(S.conn.quit(conn), c, conn, srv), S.next_srv(S.conn.quit(conn), c, conn, srv))), d), es), List.reverse.go(&2, R.Cmd, effs(S.plan(rest, S.next_conn(S.conn.quit(conn), c, conn, srv), S.next_srv(S.conn.quit(conn), c, conn, srv)), db_if(S.ran(S.conn.quit(conn), c, conn, srv), c, d)), List.reverse.go(&2, R.Cmd, eff_if(S.ran(S.conn.quit(conn), c, conn, srv), c, d), es)), effs_keep(S.ran(S.conn.quit(conn), c, conn, srv), c, S.plan(rest, S.next_conn(S.conn.quit(conn), c, conn, srv), S.next_srv(S.conn.quit(conn), c, conn, srv)), d, es)),
             Equal.sym(KV.Trie<String>, rsnd(run(List.append(&2, R.Cmd, S.keep(S.ran(S.conn.quit(conn), c, conn, srv), c), S.plan(rest, S.next_conn(S.conn.quit(conn), c, conn, srv), S.next_srv(S.conn.quit(conn), c, conn, srv))), d)), rsnd(run(S.plan(rest, S.next_conn(S.conn.quit(conn), c, conn, srv), S.next_srv(S.conn.quit(conn), c, conn, srv)), db_if(S.ran(S.conn.quit(conn), c, conn, srv), c, d))), run_keep(S.ran(S.conn.quit(conn), c, conn, srv), c, S.plan(rest, S.next_conn(S.conn.quit(conn), c, conn, srv), S.next_srv(S.conn.quit(conn), c, conn, srv)), d))))

def Laws.gen_db(conn, srv, cmds, db):
  %gen_spec(cmds, Nil{}, Nil{}, conn, srv, db) : {Laws.logged_db(S.logged.gen(_)) == Laws.final(R.exec_all(S.plan(cmds, conn, srv), db)) : KV.Trie<String>}
  %exec_all_run(S.plan(cmds, conn, srv), db) : {Laws.logged_db(S.logged.gen(S.Gen{List.reverse.go(&2, R.Reply, greps(cmds, conn, srv, db), Nil{}), List.reverse.go(&2, R.Cmd, effs(S.plan(cmds, conn, srv), db), Nil{}), gconn(cmds, conn, srv), gsrv(cmds, conn, srv), rsnd(run(S.plan(cmds, conn, srv), db))})) == Laws.final(_) : KV.Trie<String>}
  %eta_l(run(S.plan(cmds, conn, srv), db)) : {Laws.logged_db(S.logged.gen(S.Gen{List.reverse.go(&2, R.Reply, greps(cmds, conn, srv, db), Nil{}), List.reverse.go(&2, R.Cmd, effs(S.plan(cmds, conn, srv), db), Nil{}), gconn(cmds, conn, srv), gsrv(cmds, conn, srv), rsnd(run(S.plan(cmds, conn, srv), db))})) == Laws.final(_) : KV.Trie<String>}
  {==}

def app_nil(xs: List<&2, R.Cmd>) -> {List.append(&2, R.Cmd, xs, Nil{}) == xs : List<&2, R.Cmd>}:
  match xs:
    case Nil{}:
      {==}
    case Con{h, +t}:
      Equal.cong(List<&2, R.Cmd>, List<&2, R.Cmd>, z => h <> z, List.append(&2, R.Cmd, t, Nil{}), t, app_nil(t))

# a list reversed twice
def rev_rev(+xs: List<&2, R.Cmd>) -> {List.reverse(&2, R.Cmd, List.reverse.go(&2, R.Cmd, xs, Nil{})) == xs : List<&2, R.Cmd>}:
  Equal.trans(List<&2, R.Cmd>, List.reverse.go(&2, R.Cmd, List.reverse.go(&2, R.Cmd, xs, Nil{}), Nil{}), List.append(&2, R.Cmd, xs, Nil{}), xs, rev_go_app(xs, Nil{}, Nil{}), app_nil(xs))

def Laws.gen_log(conn, srv, cmds, db):
  %gen_spec(cmds, Nil{}, Nil{}, conn, srv, db) : {Laws.logged_es(S.logged.gen(_)) == Laws.effects(A.exec_log(S.plan(cmds, conn, srv), db)) : List<&2, R.Cmd>}
  %log_go(S.plan(cmds, conn, srv), Nil{}, Nil{}, db) : {Laws.logged_es(S.logged.gen(S.Gen{List.reverse.go(&2, R.Reply, greps(cmds, conn, srv, db), Nil{}), List.reverse.go(&2, R.Cmd, effs(S.plan(cmds, conn, srv), db), Nil{}), gconn(cmds, conn, srv), gsrv(cmds, conn, srv), rsnd(run(S.plan(cmds, conn, srv), db))})) == Laws.effects(_) : List<&2, R.Cmd>}
  rev_rev(effs(S.plan(cmds, conn, srv), db))

# A batch of database commands only
# ---------------------------------

def not_sess(k: S.Role) -> Bool:
  match k:
    case S.KSess{o}:
      False{}
    case S.KData{}:
      True{}
    case S.KBad{}:
      True{}

# whether no command of a batch is of the connection or of the server
def plain(cs: List<&2, R.Cmd>) -> Bool:
  match cs:
    case Nil{}:
      True{}
    case Con{c, rest}:
      Bool.and(not_sess(S.kind(c)), plain(rest))

# a ready client (S.ready) runs each command of such a batch, sends each
# reply, and stays ready, authenticated
def fast_greps.k(k: S.Role, +c: R.Cmd, +rest: List<&2, R.Cmd>, +id: Nat, +a: Bool, +n: String, +srv: S.Srv, +d: KV.Trie<String>,
    ih: {greps(rest, S.Conn{id, True{}, n, S.MOn{}, False{}}, srv, R.db_of(R.exec(c, d))) == rfst(run(rest, R.db_of(R.exec(c, d)))) : List<&2, R.Reply>})
  -> {not_sess(k) == True{} : Bool}
  -> {S.authed(S.Conn{id, a, n, S.MOn{}, False{}}, srv) == True{} : Bool}
  -> {opt_cons(rep.k(k, S.may(k, S.Conn{id, a, n, S.MOn{}, False{}}, srv), c, S.Conn{id, a, n, S.MOn{}, False{}}, srv, d), greps(rest, S.next_conn.k(k, S.may(k, S.Conn{id, a, n, S.MOn{}, False{}}, srv), S.Conn{id, a, n, S.MOn{}, False{}}, srv), S.next_srv.k(k, S.may(k, S.Conn{id, a, n, S.MOn{}, False{}}, srv), S.Conn{id, a, n, S.MOn{}, False{}}, srv), db_if(S.ran.k(k, S.may(k, S.Conn{id, a, n, S.MOn{}, False{}}, srv)), c, d))) == rfst(run(Con{c, rest}, d)) : List<&2, R.Reply>}:
  match k:
    case S.KSess{o}:
      e => ea => Empty.absurd({opt_cons(rep.k(S.KSess{o}, S.may(S.KSess{o}, S.Conn{id, a, n, S.MOn{}, False{}}, srv), c, S.Conn{id, a, n, S.MOn{}, False{}}, srv, d), greps(rest, S.next_conn.k(S.KSess{o}, S.may(S.KSess{o}, S.Conn{id, a, n, S.MOn{}, False{}}, srv), S.Conn{id, a, n, S.MOn{}, False{}}, srv), S.next_srv.k(S.KSess{o}, S.may(S.KSess{o}, S.Conn{id, a, n, S.MOn{}, False{}}, srv), S.Conn{id, a, n, S.MOn{}, False{}}, srv), db_if(S.ran.k(S.KSess{o}, S.may(S.KSess{o}, S.Conn{id, a, n, S.MOn{}, False{}}, srv)), c, d))) == rfst(run(Con{c, rest}, d)) : List<&2, R.Reply>}, false_true(e))
    case S.KData{}:
      e => ea =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, S.MOn{}, False{}}, srv), True{}, ea) : {opt_cons(rep.k(S.KData{}, _, c, S.Conn{id, a, n, S.MOn{}, False{}}, srv, d), greps(rest, S.Conn{id, _, n, S.after(S.MOn{}), False{}}, srv, db_if(S.ran.k(S.KData{}, _), c, d))) == rfst(run(Con{c, rest}, d)) : List<&2, R.Reply>}
        %eta_l(run(rest, R.db_of(R.exec(c, d)))) : {R.reply_of(R.exec(c, d)) <> greps(rest, S.Conn{id, True{}, n, S.MOn{}, False{}}, srv, R.db_of(R.exec(c, d))) == rfst(R.exec_all.cons(R.reply_of(R.exec(c, d)), _)) : List<&2, R.Reply>}
        Equal.cong(List<&2, R.Reply>, List<&2, R.Reply>, z => R.reply_of(R.exec(c, d)) <> z, greps(rest, S.Conn{id, True{}, n, S.MOn{}, False{}}, srv, R.db_of(R.exec(c, d))), rfst(run(rest, R.db_of(R.exec(c, d)))), ih)
    case S.KBad{}:
      e => ea =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, S.MOn{}, False{}}, srv), True{}, ea) : {opt_cons(rep.k(S.KBad{}, True{}, c, S.Conn{id, a, n, S.MOn{}, False{}}, srv, d), greps(rest, S.Conn{id, _, n, S.after(S.MOn{}), False{}}, srv, db_if(S.ran.k(S.KBad{}, True{}), c, d))) == rfst(run(Con{c, rest}, d)) : List<&2, R.Reply>}
        %eta_l(run(rest, R.db_of(R.exec(c, d)))) : {R.reply_of(R.exec(c, d)) <> greps(rest, S.Conn{id, True{}, n, S.MOn{}, False{}}, srv, R.db_of(R.exec(c, d))) == rfst(R.exec_all.cons(R.reply_of(R.exec(c, d)), _)) : List<&2, R.Reply>}
        Equal.cong(List<&2, R.Reply>, List<&2, R.Reply>, z => R.reply_of(R.exec(c, d)) <> z, greps(rest, S.Conn{id, True{}, n, S.MOn{}, False{}}, srv, R.db_of(R.exec(c, d))), rfst(run(rest, R.db_of(R.exec(c, d)))), ih)

def fast_greps(cs: List<&2, R.Cmd>, +id: Nat, +a: Bool, +n: String, +srv: S.Srv, +d: KV.Trie<String>)
  -> {S.authed(S.Conn{id, a, n, S.MOn{}, False{}}, srv) == True{} : Bool}
  -> {plain(cs) == True{} : Bool}
  -> {greps(cs, S.Conn{id, a, n, S.MOn{}, False{}}, srv, d) == rfst(run(cs, d)) : List<&2, R.Reply>}:
  match cs:
    case Nil{}:
      ea => ep => {==}
    case Con{+c, +rest}:
      +ea => +ep => fast_greps.k(S.kind(c), c, rest, id, a, n, srv, d, fast_greps(rest, id, True{}, n, srv, R.db_of(R.exec(c, d)))({==})(and_r(not_sess(S.kind(c)), plain(rest))(ep)))(and_l(not_sess(S.kind(c)), plain(rest))(ep))(ea)

def fast_plan.k(k: S.Role, +c: R.Cmd, +rest: List<&2, R.Cmd>, +id: Nat, +a: Bool, +n: String, +srv: S.Srv,
    ih: {S.plan(rest, S.Conn{id, True{}, n, S.MOn{}, False{}}, srv) == rest : List<&2, R.Cmd>})
  -> {not_sess(k) == True{} : Bool}
  -> {S.authed(S.Conn{id, a, n, S.MOn{}, False{}}, srv) == True{} : Bool}
  -> {List.append(&2, R.Cmd, S.keep(S.ran.k(k, S.may(k, S.Conn{id, a, n, S.MOn{}, False{}}, srv)), c), S.plan(rest, S.next_conn.k(k, S.may(k, S.Conn{id, a, n, S.MOn{}, False{}}, srv), S.Conn{id, a, n, S.MOn{}, False{}}, srv), S.next_srv.k(k, S.may(k, S.Conn{id, a, n, S.MOn{}, False{}}, srv), S.Conn{id, a, n, S.MOn{}, False{}}, srv))) == Con{c, rest} : List<&2, R.Cmd>}:
  match k:
    case S.KSess{o}:
      e => ea => Empty.absurd({List.append(&2, R.Cmd, S.keep(S.ran.k(S.KSess{o}, S.may(S.KSess{o}, S.Conn{id, a, n, S.MOn{}, False{}}, srv)), c), S.plan(rest, S.next_conn.k(S.KSess{o}, S.may(S.KSess{o}, S.Conn{id, a, n, S.MOn{}, False{}}, srv), S.Conn{id, a, n, S.MOn{}, False{}}, srv), S.next_srv.k(S.KSess{o}, S.may(S.KSess{o}, S.Conn{id, a, n, S.MOn{}, False{}}, srv), S.Conn{id, a, n, S.MOn{}, False{}}, srv))) == Con{c, rest} : List<&2, R.Cmd>}, false_true(e))
    case S.KData{}:
      e => ea =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, S.MOn{}, False{}}, srv), True{}, ea) : {List.append(&2, R.Cmd, S.keep(S.ran.k(S.KData{}, _), c), S.plan(rest, S.Conn{id, _, n, S.after(S.MOn{}), False{}}, srv)) == Con{c, rest} : List<&2, R.Cmd>}
        Equal.cong(List<&2, R.Cmd>, List<&2, R.Cmd>, z => c <> z, S.plan(rest, S.Conn{id, True{}, n, S.MOn{}, False{}}, srv), rest, ih)
    case S.KBad{}:
      e => ea =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, S.MOn{}, False{}}, srv), True{}, ea) : {List.append(&2, R.Cmd, S.keep(S.ran.k(S.KBad{}, True{}), c), S.plan(rest, S.Conn{id, _, n, S.after(S.MOn{}), False{}}, srv)) == Con{c, rest} : List<&2, R.Cmd>}
        Equal.cong(List<&2, R.Cmd>, List<&2, R.Cmd>, z => c <> z, S.plan(rest, S.Conn{id, True{}, n, S.MOn{}, False{}}, srv), rest, ih)

def fast_plan(cs: List<&2, R.Cmd>, +id: Nat, +a: Bool, +n: String, +srv: S.Srv)
  -> {S.authed(S.Conn{id, a, n, S.MOn{}, False{}}, srv) == True{} : Bool}
  -> {plain(cs) == True{} : Bool}
  -> {S.plan(cs, S.Conn{id, a, n, S.MOn{}, False{}}, srv) == cs : List<&2, R.Cmd>}:
  match cs:
    case Nil{}:
      ea => ep => {==}
    case Con{+c, +rest}:
      +ea => +ep => fast_plan.k(S.kind(c), c, rest, id, a, n, srv, fast_plan(rest, id, True{}, n, srv)({==})(and_r(not_sess(S.kind(c)), plain(rest))(ep)))(and_l(not_sess(S.kind(c)), plain(rest))(ep))(ea)

def fast_conn.k(k: S.Role, +rest: List<&2, R.Cmd>, +id: Nat, +a: Bool, +n: String, +srv: S.Srv,
    ih: {gconn(rest, S.Conn{id, True{}, n, S.MOn{}, False{}}, srv) == S.Conn{id, True{}, n, S.MOn{}, False{}} : S.Conn})
  -> {not_sess(k) == True{} : Bool}
  -> {S.authed(S.Conn{id, a, n, S.MOn{}, False{}}, srv) == True{} : Bool}
  -> {gconn(rest, S.next_conn.k(k, S.may(k, S.Conn{id, a, n, S.MOn{}, False{}}, srv), S.Conn{id, a, n, S.MOn{}, False{}}, srv), S.next_srv.k(k, S.may(k, S.Conn{id, a, n, S.MOn{}, False{}}, srv), S.Conn{id, a, n, S.MOn{}, False{}}, srv)) == S.Conn{id, True{}, n, S.MOn{}, False{}} : S.Conn}:
  match k:
    case S.KSess{o}:
      e => ea => Empty.absurd({gconn(rest, S.next_conn.k(S.KSess{o}, S.may(S.KSess{o}, S.Conn{id, a, n, S.MOn{}, False{}}, srv), S.Conn{id, a, n, S.MOn{}, False{}}, srv), S.next_srv.k(S.KSess{o}, S.may(S.KSess{o}, S.Conn{id, a, n, S.MOn{}, False{}}, srv), S.Conn{id, a, n, S.MOn{}, False{}}, srv)) == S.Conn{id, True{}, n, S.MOn{}, False{}} : S.Conn}, false_true(e))
    case S.KData{}:
      e => ea =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, S.MOn{}, False{}}, srv), True{}, ea) : {gconn(rest, S.Conn{id, _, n, S.after(S.MOn{}), False{}}, srv) == S.Conn{id, True{}, n, S.MOn{}, False{}} : S.Conn}
        ih
    case S.KBad{}:
      e => ea =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, S.MOn{}, False{}}, srv), True{}, ea) : {gconn(rest, S.Conn{id, _, n, S.after(S.MOn{}), False{}}, srv) == S.Conn{id, True{}, n, S.MOn{}, False{}} : S.Conn}
        ih


# a ready client stays ready, authenticated
def fast_conn1(cs: List<&2, R.Cmd>, +id: Nat, +n: String, +srv: S.Srv) -> {plain(cs) == True{} : Bool} -> {gconn(cs, S.Conn{id, True{}, n, S.MOn{}, False{}}, srv) == S.Conn{id, True{}, n, S.MOn{}, False{}} : S.Conn}:
  match cs:
    case Nil{}:
      ep => {==}
    case Con{+c, +rest}:
      +ep => fast_conn.k(S.kind(c), rest, id, True{}, n, srv, fast_conn1(rest, id, n, srv)(and_r(not_sess(S.kind(c)), plain(rest))(ep)))(and_l(not_sess(S.kind(c)), plain(rest))(ep))({==})

# the server is as it was after a batch of database commands only
def gsrv.k(k: S.Role, +ok: Bool, +rest: List<&2, R.Cmd>, +x: S.Conn, +conn: S.Conn, +srv: S.Srv, ih: {gsrv(rest, x, srv) == srv : S.Srv})
  -> {not_sess(k) == True{} : Bool}
  -> {gsrv(rest, x, S.next_srv.k(k, ok, conn, srv)) == srv : S.Srv}:
  match k:
    case S.KSess{o}:
      e => Empty.absurd({gsrv(rest, x, S.next_srv.k(S.KSess{o}, ok, conn, srv)) == srv : S.Srv}, false_true(e))
    case S.KData{}:
      e => ih
    case S.KBad{}:
      e => ih

def gsrv.q(q: Bool, +c: R.Cmd, +rest: List<&2, R.Cmd>, +conn: S.Conn, +srv: S.Srv, ih: {gsrv(rest, S.next_conn(q, c, conn, srv), srv) == srv : S.Srv})
  -> {not_sess(S.kind(c)) == True{} : Bool}
  -> {gsrv(rest, S.next_conn(q, c, conn, srv), S.next_srv(q, c, conn, srv)) == srv : S.Srv}:
  match q:
    case True{}:
      e => ih
    case False{}:
      e => gsrv.k(S.kind(c), S.may(S.kind(c), conn, srv), rest, S.next_conn(False{}, c, conn, srv), conn, srv, ih)(e)

def gsrv_plain(cs: List<&2, R.Cmd>, +conn: S.Conn, +srv: S.Srv) -> {plain(cs) == True{} : Bool} -> {gsrv(cs, conn, srv) == srv : S.Srv}:
  match cs:
    case Nil{}:
      ep => {==}
    case Con{+c, +rest}:
      +ep => gsrv.q(S.conn.quit(conn), c, rest, conn, srv, gsrv_plain(rest, S.next_conn(S.conn.quit(conn), c, conn, srv), srv)(and_r(not_sess(S.kind(c)), plain(rest))(ep)))(and_l(not_sess(S.kind(c)), plain(rest))(ep))

def app_nil_r(xs: List<&2, R.Reply>) -> {List.append(&2, R.Reply, xs, Nil{}) == xs : List<&2, R.Reply>}:
  match xs:
    case Nil{}:
      {==}
    case Con{h, +t}:
      Equal.cong(List<&2, R.Reply>, List<&2, R.Reply>, z => h <> z, List.append(&2, R.Reply, t, Nil{}), t, app_nil_r(t))

def rev_go_app_r(e: List<&2, R.Reply>, -es: List<&2, R.Reply>, -ys: List<&2, R.Reply>) -> {List.reverse.go(&2, R.Reply, List.reverse.go(&2, R.Reply, e, es), ys) == List.reverse.go(&2, R.Reply, es, List.append(&2, R.Reply, e, ys)) : List<&2, R.Reply>}:
  match e:
    case Nil{}:
      {==}
    case Con{h, t}:
      rev_go_app_r(t, h <> es, ys)

def rev_rev_r(+xs: List<&2, R.Reply>) -> {List.reverse(&2, R.Reply, List.reverse.go(&2, R.Reply, xs, Nil{})) == xs : List<&2, R.Reply>}:
  Equal.trans(List<&2, R.Reply>, List.reverse.go(&2, R.Reply, List.reverse.go(&2, R.Reply, xs, Nil{}), Nil{}), List.append(&2, R.Reply, xs, Nil{}), xs, rev_go_app_r(xs, Nil{}, Nil{}), app_nil_r(xs))

def fin4(-a1: List<&2, R.Reply>, -a2: List<&2, R.Reply>, -c1: S.Conn, -c2: S.Conn, -s1: S.Srv, -s2: S.Srv, -d1: KV.Trie<String>, -d2: KV.Trie<String>, ea: {a1 == a2 : List<&2, R.Reply>}, ec: {c1 == c2 : S.Conn}, es: {s1 == s2 : S.Srv}, ed: {d1 == d2 : KV.Trie<String>}) -> {S.Fin{a1, c1, s1, d1} == S.Fin{a2, c2, s2, d2} : S.Fin}:
  %ea : {S.Fin{a1, c1, s1, d1} == S.Fin{_, c2, s2, d2} : S.Fin}
  %ec : {S.Fin{a1, c1, s1, d1} == S.Fin{a1, _, s2, d2} : S.Fin}
  %es : {S.Fin{a1, c1, s1, d1} == S.Fin{a1, c1, _, d2} : S.Fin}
  %ed : {S.Fin{a1, c1, s1, d1} == S.Fin{a1, c1, s1, _} : S.Fin}
  {==}

# the fast way is the general one
def fast_eq(+c: R.Cmd, +cs: List<&2, R.Cmd>, +id: Nat, +a: Bool, +n: String, +srv: S.Srv, +hs: List<&2, U32>, +db: KV.Trie<String>)
  -> {S.authed(S.Conn{id, a, n, S.MOn{}, False{}}, srv) == True{} : Bool}
  -> {plain(Con{c, cs}) == True{} : Bool}
  -> {S.done.fast(S.Conn{id, a, n, S.MOn{}, False{}}, srv, B.exec_batch(Con{c, cs}, hs, db)) == S.done.gen(S.gen(S.Conn{id, a, n, S.MOn{}, False{}}, srv, Con{c, cs}, db)) : S.Fin}:
  +ea => +ep =>
    %Equal.sym(List<&2, R.Reply> & KV.Trie<String>, B.exec_batch(Con{c, cs}, hs, db), R.exec_all(Con{c, cs}, db), Laws.batch_hints(Con{c, cs}, hs, db)) : {S.done.fast(S.Conn{id, a, n, S.MOn{}, False{}}, srv, _) == S.done.gen(S.gen(S.Conn{id, a, n, S.MOn{}, False{}}, srv, Con{c, cs}, db)) : S.Fin}
    %exec_all_run(Con{c, cs}, db) : {S.done.fast(S.Conn{id, a, n, S.MOn{}, False{}}, srv, _) == S.done.gen(S.gen(S.Conn{id, a, n, S.MOn{}, False{}}, srv, Con{c, cs}, db)) : S.Fin}
    %eta_l(run(Con{c, cs}, db)) : {S.done.fast(S.Conn{id, a, n, S.MOn{}, False{}}, srv, _) == S.done.gen(S.gen(S.Conn{id, a, n, S.MOn{}, False{}}, srv, Con{c, cs}, db)) : S.Fin}
    %gen_spec(Con{c, cs}, Nil{}, Nil{}, S.Conn{id, a, n, S.MOn{}, False{}}, srv, db) : {S.done.fast(S.Conn{id, a, n, S.MOn{}, False{}}, srv, (rfst(run(Con{c, cs}, db)), rsnd(run(Con{c, cs}, db)))) == S.done.gen(_) : S.Fin}
    fin4(rfst(run(Con{c, cs}, db)), List.reverse(&2, R.Reply, List.reverse.go(&2, R.Reply, greps(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv, db), Nil{})),
         S.Conn{id, True{}, n, S.MOn{}, False{}}, gconn(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv), srv, gsrv(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv),
         rsnd(run(Con{c, cs}, db)), rsnd(run(S.plan(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv), db)),
         Equal.trans(List<&2, R.Reply>, rfst(run(Con{c, cs}, db)), greps(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv, db), List.reverse(&2, R.Reply, List.reverse.go(&2, R.Reply, greps(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv, db), Nil{})),
           Equal.sym(List<&2, R.Reply>, greps(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv, db), rfst(run(Con{c, cs}, db)), fast_greps(Con{c, cs}, id, a, n, srv, db)(ea)(ep)),
           Equal.sym(List<&2, R.Reply>, List.reverse(&2, R.Reply, List.reverse.go(&2, R.Reply, greps(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv, db), Nil{})), greps(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv, db), rev_rev_r(greps(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv, db)))),
         Equal.sym(S.Conn, gconn(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv), S.Conn{id, True{}, n, S.MOn{}, False{}}, fast_conn.k(S.kind(c), cs, id, a, n, srv, fast_conn1(cs, id, n, srv)(and_r(not_sess(S.kind(c)), plain(cs))(ep)))(and_l(not_sess(S.kind(c)), plain(cs))(ep))(ea)),
         Equal.sym(S.Srv, gsrv(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv), srv, gsrv_plain(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv)(ep)),
         Equal.cong(List<&2, R.Cmd>, KV.Trie<String>, z => rsnd(run(z, db)), Con{c, cs}, S.plan(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv), Equal.sym(List<&2, R.Cmd>, S.plan(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv), Con{c, cs}, fast_plan(Con{c, cs}, id, a, n, srv)(ea)(ep))))

# a batch of database commands taken the fast way or not

def plain_run(b: Bool, conn: S.Conn, +srv: S.Srv, cs: List<&2, R.Cmd>, +hs: List<&2, U32>, +db: KV.Trie<String>) -> {b == S.ready(conn, srv) : Bool} -> {plain(cs) == True{} : Bool} -> {S.run.plain(b, conn, srv, cs, hs, db) == S.done.gen(S.gen(conn, srv, cs, db)) : S.Fin}:
  match b conn cs:
    case _ _ Nil{}:
      eb => ep => {==}
    case False{} _ Con{c, rest}:
      eb => ep => {==}
    case True{} S.Conn{id, a, n, S.MOn{}, True{}} Con{c, rest}:
      eb => ep => Empty.absurd({S.run.plain(True{}, S.Conn{id, a, n, S.MOn{}, True{}}, srv, Con{c, rest}, hs, db) == S.done.gen(S.gen(S.Conn{id, a, n, S.MOn{}, True{}}, srv, Con{c, rest}, db)) : S.Fin}, true_false(eb))
    case True{} S.Conn{id, a, n, S.MOn{}, False{}} Con{+c, +rest}:
      eb => +ep => fast_eq(c, rest, id, a, n, srv, hs, db)(Equal.sym(Bool, True{}, S.authed(S.Conn{id, a, n, S.MOn{}, False{}}, srv), eb))(ep)
    case True{} S.Conn{id, a, n, S.MOff{}, True{}} Con{c, rest}:
      eb => ep => Empty.absurd({S.run.plain(True{}, S.Conn{id, a, n, S.MOff{}, True{}}, srv, Con{c, rest}, hs, db) == S.done.gen(S.gen(S.Conn{id, a, n, S.MOff{}, True{}}, srv, Con{c, rest}, db)) : S.Fin}, true_false(eb))
    case True{} S.Conn{id, a, n, S.MOff{}, False{}} Con{c, rest}:
      eb => ep => Empty.absurd({S.run.plain(True{}, S.Conn{id, a, n, S.MOff{}, False{}}, srv, Con{c, rest}, hs, db) == S.done.gen(S.gen(S.Conn{id, a, n, S.MOff{}, False{}}, srv, Con{c, rest}, db)) : S.Fin}, true_false(eb))
    case True{} S.Conn{id, a, n, S.MSkip{}, True{}} Con{c, rest}:
      eb => ep => Empty.absurd({S.run.plain(True{}, S.Conn{id, a, n, S.MSkip{}, True{}}, srv, Con{c, rest}, hs, db) == S.done.gen(S.gen(S.Conn{id, a, n, S.MSkip{}, True{}}, srv, Con{c, rest}, db)) : S.Fin}, true_false(eb))
    case True{} S.Conn{id, a, n, S.MSkip{}, False{}} Con{c, rest}:
      eb => ep => Empty.absurd({S.run.plain(True{}, S.Conn{id, a, n, S.MSkip{}, False{}}, srv, Con{c, rest}, hs, db) == S.done.gen(S.gen(S.Conn{id, a, n, S.MSkip{}, False{}}, srv, Con{c, rest}, db)) : S.Fin}, true_false(eb))

# the server's unzip hands gen a batch's commands in order, and takes the
# fast way only for database commands

def unzip_gen(+conn: S.Conn, +srv: S.Srv, rs: List<&2, B.Req>, +cs: List<&2, R.Cmd>, +hs: List<&2, U32>, +db: KV.Trie<String>) -> {plain(cs) == True{} : Bool} -> {S.run(conn, srv, B.job(B.unzip(rs, cs, hs)), db) == S.done.gen(S.gen(conn, srv, B.cmds_of(rs, cs), db)) : S.Fin}:
  match rs:
    case Nil{}:
      e => plain_run(S.ready(conn, srv), conn, srv, cs, hs, db)({==})(e)
    case Con{B.Req{R.Ping{}, h}, rest}:
      e => unzip_gen(conn, srv, rest, R.Ping{} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.Echo{x0}, h}, rest}:
      e => unzip_gen(conn, srv, rest, R.Echo{x0} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.Get{x0}, h}, rest}:
      e => unzip_gen(conn, srv, rest, R.Get{x0} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.Set{x0, x1}, h}, rest}:
      e => unzip_gen(conn, srv, rest, R.Set{x0, x1} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.SetNX{x0, x1}, h}, rest}:
      e => unzip_gen(conn, srv, rest, R.SetNX{x0, x1} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.GetSet{x0, x1}, h}, rest}:
      e => unzip_gen(conn, srv, rest, R.GetSet{x0, x1} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.Del{x0}, h}, rest}:
      e => unzip_gen(conn, srv, rest, R.Del{x0} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.Exists{x0}, h}, rest}:
      e => unzip_gen(conn, srv, rest, R.Exists{x0} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.IncrBy{x0, x1}, h}, rest}:
      e => unzip_gen(conn, srv, rest, R.IncrBy{x0, x1} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.Append{x0, x1}, h}, rest}:
      e => unzip_gen(conn, srv, rest, R.Append{x0, x1} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.Strlen{x0}, h}, rest}:
      e => unzip_gen(conn, srv, rest, R.Strlen{x0} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.MGet{x0}, h}, rest}:
      e => unzip_gen(conn, srv, rest, R.MGet{x0} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.MSet{x0}, h}, rest}:
      e => unzip_gen(conn, srv, rest, R.MSet{x0} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.DbSize{}, h}, rest}:
      e => unzip_gen(conn, srv, rest, R.DbSize{} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.FlushAll{}, h}, rest}:
      e => unzip_gen(conn, srv, rest, R.FlushAll{} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.Keys{x0}, h}, rest}:
      e => unzip_gen(conn, srv, rest, R.Keys{x0} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.Peek{x0, x1}, h}, rest}:
      e => unzip_gen(conn, srv, rest, R.Peek{x0, x1} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.Own{x0}, h}, rest}:
      e => {==}
    case Con{B.Req{R.Bad{x0}, h}, rest}:
      e => unzip_gen(conn, srv, rest, R.Bad{x0} <> cs, h <> hs, db)(e)

def Laws.run_gen(conn, srv, rs, db):
  unzip_gen(conn, srv, rs, Nil{}, Nil{}, db)({==})

def log5(-a1: List<&2, R.Reply>, -a2: List<&2, R.Reply>, -b1: List<&2, R.Cmd>, -b2: List<&2, R.Cmd>, -c1: S.Conn, -c2: S.Conn, -s1: S.Srv, -s2: S.Srv, -d1: KV.Trie<String>, -d2: KV.Trie<String>, ea: {a1 == a2 : List<&2, R.Reply>}, eb: {b1 == b2 : List<&2, R.Cmd>}, ec: {c1 == c2 : S.Conn}, es: {s1 == s2 : S.Srv}, ed: {d1 == d2 : KV.Trie<String>}) -> {S.Logged{a1, b1, c1, s1, d1} == S.Logged{a2, b2, c2, s2, d2} : S.Logged}:
  %ea : {S.Logged{a1, b1, c1, s1, d1} == S.Logged{_, b2, c2, s2, d2} : S.Logged}
  %eb : {S.Logged{a1, b1, c1, s1, d1} == S.Logged{a1, _, c2, s2, d2} : S.Logged}
  %ec : {S.Logged{a1, b1, c1, s1, d1} == S.Logged{a1, b1, _, s2, d2} : S.Logged}
  %es : {S.Logged{a1, b1, c1, s1, d1} == S.Logged{a1, b1, c1, _, d2} : S.Logged}
  %ed : {S.Logged{a1, b1, c1, s1, d1} == S.Logged{a1, b1, c1, s1, _} : S.Logged}
  {==}

# and with an append-only file
def fast_eq_log(+c: R.Cmd, +cs: List<&2, R.Cmd>, +id: Nat, +a: Bool, +n: String, +srv: S.Srv, +hs: List<&2, U32>, +db: KV.Trie<String>)
  -> {S.authed(S.Conn{id, a, n, S.MOn{}, False{}}, srv) == True{} : Bool}
  -> {plain(Con{c, cs}) == True{} : Bool}
  -> {S.logged.fast(S.Conn{id, a, n, S.MOn{}, False{}}, srv, A.log_batch(Con{c, cs}, hs, db)) == S.logged.gen(S.gen(S.Conn{id, a, n, S.MOn{}, False{}}, srv, Con{c, cs}, db)) : S.Logged}:
  +ea => +ep =>
    %Equal.sym(List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>), A.log_batch(Con{c, cs}, hs, db), A.exec_log(Con{c, cs}, db), Laws.log_hints(Con{c, cs}, hs, db)) : {S.logged.fast(S.Conn{id, a, n, S.MOn{}, False{}}, srv, _) == S.logged.gen(S.gen(S.Conn{id, a, n, S.MOn{}, False{}}, srv, Con{c, cs}, db)) : S.Logged}
    %log_go(Con{c, cs}, Nil{}, Nil{}, db) : {S.logged.fast(S.Conn{id, a, n, S.MOn{}, False{}}, srv, _) == S.logged.gen(S.gen(S.Conn{id, a, n, S.MOn{}, False{}}, srv, Con{c, cs}, db)) : S.Logged}
    %gen_spec(Con{c, cs}, Nil{}, Nil{}, S.Conn{id, a, n, S.MOn{}, False{}}, srv, db) : {S.logged.fast(S.Conn{id, a, n, S.MOn{}, False{}}, srv, (List.reverse.go(&2, R.Reply, Nil{}, rfst(run(Con{c, cs}, db))), (List.reverse.go(&2, R.Cmd, Nil{}, effs(Con{c, cs}, db)), rsnd(run(Con{c, cs}, db))))) == S.logged.gen(_) : S.Logged}
    log5(rfst(run(Con{c, cs}, db)), List.reverse(&2, R.Reply, List.reverse.go(&2, R.Reply, greps(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv, db), Nil{})),
         effs(Con{c, cs}, db), List.reverse(&2, R.Cmd, List.reverse.go(&2, R.Cmd, effs(S.plan(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv), db), Nil{})),
         S.Conn{id, True{}, n, S.MOn{}, False{}}, gconn(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv), srv, gsrv(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv),
         rsnd(run(Con{c, cs}, db)), rsnd(run(S.plan(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv), db)),
         Equal.trans(List<&2, R.Reply>, rfst(run(Con{c, cs}, db)), greps(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv, db), List.reverse(&2, R.Reply, List.reverse.go(&2, R.Reply, greps(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv, db), Nil{})),
           Equal.sym(List<&2, R.Reply>, greps(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv, db), rfst(run(Con{c, cs}, db)), fast_greps(Con{c, cs}, id, a, n, srv, db)(ea)(ep)),
           Equal.sym(List<&2, R.Reply>, List.reverse(&2, R.Reply, List.reverse.go(&2, R.Reply, greps(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv, db), Nil{})), greps(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv, db), rev_rev_r(greps(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv, db)))),
         Equal.trans(List<&2, R.Cmd>, effs(Con{c, cs}, db), effs(S.plan(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv), db), List.reverse(&2, R.Cmd, List.reverse.go(&2, R.Cmd, effs(S.plan(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv), db), Nil{})),
           Equal.cong(List<&2, R.Cmd>, List<&2, R.Cmd>, z => effs(z, db), Con{c, cs}, S.plan(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv), Equal.sym(List<&2, R.Cmd>, S.plan(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv), Con{c, cs}, fast_plan(Con{c, cs}, id, a, n, srv)(ea)(ep))),
           Equal.sym(List<&2, R.Cmd>, List.reverse(&2, R.Cmd, List.reverse.go(&2, R.Cmd, effs(S.plan(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv), db), Nil{})), effs(S.plan(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv), db), rev_rev(effs(S.plan(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv), db)))),
         Equal.sym(S.Conn, gconn(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv), S.Conn{id, True{}, n, S.MOn{}, False{}}, fast_conn.k(S.kind(c), cs, id, a, n, srv, fast_conn1(cs, id, n, srv)(and_r(not_sess(S.kind(c)), plain(cs))(ep)))(and_l(not_sess(S.kind(c)), plain(cs))(ep))(ea)),
         Equal.sym(S.Srv, gsrv(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv), srv, gsrv_plain(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv)(ep)),
         Equal.cong(List<&2, R.Cmd>, KV.Trie<String>, z => rsnd(run(z, db)), Con{c, cs}, S.plan(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv), Equal.sym(List<&2, R.Cmd>, S.plan(Con{c, cs}, S.Conn{id, a, n, S.MOn{}, False{}}, srv), Con{c, cs}, fast_plan(Con{c, cs}, id, a, n, srv)(ea)(ep))))

def plain_run_log(b: Bool, conn: S.Conn, +srv: S.Srv, cs: List<&2, R.Cmd>, +hs: List<&2, U32>, +db: KV.Trie<String>) -> {b == S.ready(conn, srv) : Bool} -> {plain(cs) == True{} : Bool} -> {S.run_log.plain(b, conn, srv, cs, hs, db) == S.logged.gen(S.gen(conn, srv, cs, db)) : S.Logged}:
  match b conn cs:
    case _ _ Nil{}:
      eb => ep => {==}
    case False{} _ Con{c, rest}:
      eb => ep => {==}
    case True{} S.Conn{id, a, n, S.MOn{}, True{}} Con{c, rest}:
      eb => ep => Empty.absurd({S.run_log.plain(True{}, S.Conn{id, a, n, S.MOn{}, True{}}, srv, Con{c, rest}, hs, db) == S.logged.gen(S.gen(S.Conn{id, a, n, S.MOn{}, True{}}, srv, Con{c, rest}, db)) : S.Logged}, true_false(eb))
    case True{} S.Conn{id, a, n, S.MOn{}, False{}} Con{+c, +rest}:
      eb => +ep => fast_eq_log(c, rest, id, a, n, srv, hs, db)(Equal.sym(Bool, True{}, S.authed(S.Conn{id, a, n, S.MOn{}, False{}}, srv), eb))(ep)
    case True{} S.Conn{id, a, n, S.MOff{}, True{}} Con{c, rest}:
      eb => ep => Empty.absurd({S.run_log.plain(True{}, S.Conn{id, a, n, S.MOff{}, True{}}, srv, Con{c, rest}, hs, db) == S.logged.gen(S.gen(S.Conn{id, a, n, S.MOff{}, True{}}, srv, Con{c, rest}, db)) : S.Logged}, true_false(eb))
    case True{} S.Conn{id, a, n, S.MOff{}, False{}} Con{c, rest}:
      eb => ep => Empty.absurd({S.run_log.plain(True{}, S.Conn{id, a, n, S.MOff{}, False{}}, srv, Con{c, rest}, hs, db) == S.logged.gen(S.gen(S.Conn{id, a, n, S.MOff{}, False{}}, srv, Con{c, rest}, db)) : S.Logged}, true_false(eb))
    case True{} S.Conn{id, a, n, S.MSkip{}, True{}} Con{c, rest}:
      eb => ep => Empty.absurd({S.run_log.plain(True{}, S.Conn{id, a, n, S.MSkip{}, True{}}, srv, Con{c, rest}, hs, db) == S.logged.gen(S.gen(S.Conn{id, a, n, S.MSkip{}, True{}}, srv, Con{c, rest}, db)) : S.Logged}, true_false(eb))
    case True{} S.Conn{id, a, n, S.MSkip{}, False{}} Con{c, rest}:
      eb => ep => Empty.absurd({S.run_log.plain(True{}, S.Conn{id, a, n, S.MSkip{}, False{}}, srv, Con{c, rest}, hs, db) == S.logged.gen(S.gen(S.Conn{id, a, n, S.MSkip{}, False{}}, srv, Con{c, rest}, db)) : S.Logged}, true_false(eb))

def unzip_gen_log(+conn: S.Conn, +srv: S.Srv, rs: List<&2, B.Req>, +cs: List<&2, R.Cmd>, +hs: List<&2, U32>, +db: KV.Trie<String>) -> {plain(cs) == True{} : Bool} -> {S.run_log(conn, srv, B.job(B.unzip(rs, cs, hs)), db) == S.logged.gen(S.gen(conn, srv, B.cmds_of(rs, cs), db)) : S.Logged}:
  match rs:
    case Nil{}:
      e => plain_run_log(S.ready(conn, srv), conn, srv, cs, hs, db)({==})(e)
    case Con{B.Req{R.Ping{}, h}, rest}:
      e => unzip_gen_log(conn, srv, rest, R.Ping{} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.Echo{x0}, h}, rest}:
      e => unzip_gen_log(conn, srv, rest, R.Echo{x0} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.Get{x0}, h}, rest}:
      e => unzip_gen_log(conn, srv, rest, R.Get{x0} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.Set{x0, x1}, h}, rest}:
      e => unzip_gen_log(conn, srv, rest, R.Set{x0, x1} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.SetNX{x0, x1}, h}, rest}:
      e => unzip_gen_log(conn, srv, rest, R.SetNX{x0, x1} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.GetSet{x0, x1}, h}, rest}:
      e => unzip_gen_log(conn, srv, rest, R.GetSet{x0, x1} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.Del{x0}, h}, rest}:
      e => unzip_gen_log(conn, srv, rest, R.Del{x0} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.Exists{x0}, h}, rest}:
      e => unzip_gen_log(conn, srv, rest, R.Exists{x0} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.IncrBy{x0, x1}, h}, rest}:
      e => unzip_gen_log(conn, srv, rest, R.IncrBy{x0, x1} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.Append{x0, x1}, h}, rest}:
      e => unzip_gen_log(conn, srv, rest, R.Append{x0, x1} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.Strlen{x0}, h}, rest}:
      e => unzip_gen_log(conn, srv, rest, R.Strlen{x0} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.MGet{x0}, h}, rest}:
      e => unzip_gen_log(conn, srv, rest, R.MGet{x0} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.MSet{x0}, h}, rest}:
      e => unzip_gen_log(conn, srv, rest, R.MSet{x0} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.DbSize{}, h}, rest}:
      e => unzip_gen_log(conn, srv, rest, R.DbSize{} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.FlushAll{}, h}, rest}:
      e => unzip_gen_log(conn, srv, rest, R.FlushAll{} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.Keys{x0}, h}, rest}:
      e => unzip_gen_log(conn, srv, rest, R.Keys{x0} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.Peek{x0, x1}, h}, rest}:
      e => unzip_gen_log(conn, srv, rest, R.Peek{x0, x1} <> cs, h <> hs, db)(e)
    case Con{B.Req{R.Own{x0}, h}, rest}:
      e => {==}
    case Con{B.Req{R.Bad{x0}, h}, rest}:
      e => unzip_gen_log(conn, srv, rest, R.Bad{x0} <> cs, h <> hs, db)(e)

def Laws.run_log_gen(conn, srv, rs, db):
  unzip_gen_log(conn, srv, rs, Nil{}, Nil{}, db)({==})

# A client that has not authenticated
# ------------------------------------

def or_ff(a: Bool, -b: Bool) -> {a == False{} : Bool} -> {b == False{} : Bool} -> {Bool.or(a, b) == False{} : Bool}:
  match a:
    case True{}:
      ea => eb => Empty.absurd({Bool.or(True{}, b) == False{} : Bool}, true_false(ea))
    case False{}:
      ea => eb => eb

def not_true(b: Bool) -> {Bool.not(b) == True{} : Bool} -> {b == False{} : Bool}:
  match b:
    case True{}:
      e => Empty.absurd({True{} == False{} : Bool}, false_true(e))
    case False{}:
      e => {==}

# a client that may not run commands changes the server with none of its
# commands: it may run only those that need no login, and those leave the
# server as it was (CONFIG SET, which changes it, needs one)
def srv_same.o(o: R.SessOp, +conn: S.Conn, +srv: S.Srv, +ef: {S.authed(conn, srv) == False{} : Bool})
  -> {True{} == S.may(S.KSess{o}, conn, srv) : Bool}
  -> {S.own_srv(o, conn, srv) == srv : S.Srv}:
  match o:
    case R.SHello{y0}:
      e => {==}
    case R.SAuth{y0}:
      e => {==}
    case R.SSelect{y0}:
      e => Empty.absurd({S.own_srv(R.SSelect{y0}, conn, srv) == srv : S.Srv}, true_false(Equal.trans(Bool, True{}, S.authed(conn, srv), False{}, e, ef)))
    case R.SQuit{}:
      e => {==}
    case R.SReset{}:
      e => {==}
    case R.SClientId{}:
      e => Empty.absurd({S.own_srv(R.SClientId{}, conn, srv) == srv : S.Srv}, true_false(Equal.trans(Bool, True{}, S.authed(conn, srv), False{}, e, ef)))
    case R.SClientGetName{}:
      e => Empty.absurd({S.own_srv(R.SClientGetName{}, conn, srv) == srv : S.Srv}, true_false(Equal.trans(Bool, True{}, S.authed(conn, srv), False{}, e, ef)))
    case R.SClientSetName{y0}:
      e => Empty.absurd({S.own_srv(R.SClientSetName{y0}, conn, srv) == srv : S.Srv}, true_false(Equal.trans(Bool, True{}, S.authed(conn, srv), False{}, e, ef)))
    case R.SClientReply{y0}:
      e => Empty.absurd({S.own_srv(R.SClientReply{y0}, conn, srv) == srv : S.Srv}, true_false(Equal.trans(Bool, True{}, S.authed(conn, srv), False{}, e, ef)))
    case R.SConfigGet{y0}:
      e => Empty.absurd({S.own_srv(R.SConfigGet{y0}, conn, srv) == srv : S.Srv}, true_false(Equal.trans(Bool, True{}, S.authed(conn, srv), False{}, e, ef)))
    case R.SConfigSet{y0}:
      e => Empty.absurd({S.own_srv(R.SConfigSet{y0}, conn, srv) == srv : S.Srv}, true_false(Equal.trans(Bool, True{}, S.authed(conn, srv), False{}, e, ef)))
    case R.SConfigResetStat{}:
      e => Empty.absurd({S.own_srv(R.SConfigResetStat{}, conn, srv) == srv : S.Srv}, true_false(Equal.trans(Bool, True{}, S.authed(conn, srv), False{}, e, ef)))
    case R.SInfo{y0}:
      e => Empty.absurd({S.own_srv(R.SInfo{y0}, conn, srv) == srv : S.Srv}, true_false(Equal.trans(Bool, True{}, S.authed(conn, srv), False{}, e, ef)))
    case R.SCommand{y0}:
      e => Empty.absurd({S.own_srv(R.SCommand{y0}, conn, srv) == srv : S.Srv}, true_false(Equal.trans(Bool, True{}, S.authed(conn, srv), False{}, e, ef)))
    case R.SReply{y0}:
      e => Empty.absurd({S.own_srv(R.SReply{y0}, conn, srv) == srv : S.Srv}, true_false(Equal.trans(Bool, True{}, S.authed(conn, srv), False{}, e, ef)))
    case R.SBad{y0}:
      e => {==}

def srv_same.k(k: S.Role, ok: Bool, +conn: S.Conn, +srv: S.Srv, +ef: {S.authed(conn, srv) == False{} : Bool})
  -> {ok == S.may(k, conn, srv) : Bool}
  -> {S.next_srv.k(k, ok, conn, srv) == srv : S.Srv}:
  match k ok:
    case S.KSess{o} True{}:
      e => srv_same.o(o, conn, srv, ef)(e)
    case S.KSess{o} False{}:
      e => {==}
    case S.KData{} _:
      e => {==}
    case S.KBad{} _:
      e => {==}

def srv_same(q: Bool, +c: R.Cmd, +conn: S.Conn, +srv: S.Srv, +ef: {S.authed(conn, srv) == False{} : Bool}) -> {S.next_srv(q, c, conn, srv) == srv : S.Srv}:
  match q:
    case True{}:
      {==}
    case False{}:
      srv_same.k(S.kind(c), S.may(S.kind(c), conn, srv), conn, srv, ef)({==})

# a command a client that may not run commands sends runs on the database
# only when it is an error the parser found
def ran_bad(c: R.Cmd, +ps: List<&2, R.Cmd>, +id: Nat, +a: Bool, +n: String, +m: S.Mute, +srv: S.Srv, ef: {S.authed(S.Conn{id, a, n, m, False{}}, srv) == False{} : Bool})
  -> {Laws.all_bad(ps) == True{} : Bool}
  -> {Laws.all_bad(List.append(&2, R.Cmd, S.keep(S.ran(False{}, c, S.Conn{id, a, n, m, False{}}, srv), c), ps)) == True{} : Bool}:
  match c:
    case R.Ping{}:
      ih =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, m, False{}}, srv), False{}, ef) : {Laws.all_bad(List.append(&2, R.Cmd, S.keep(_, R.Ping{}), ps)) == True{} : Bool}
        ih
    case R.Echo{x0}:
      ih =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, m, False{}}, srv), False{}, ef) : {Laws.all_bad(List.append(&2, R.Cmd, S.keep(_, R.Echo{x0}), ps)) == True{} : Bool}
        ih
    case R.Get{x0}:
      ih =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, m, False{}}, srv), False{}, ef) : {Laws.all_bad(List.append(&2, R.Cmd, S.keep(_, R.Get{x0}), ps)) == True{} : Bool}
        ih
    case R.Set{x0, x1}:
      ih =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, m, False{}}, srv), False{}, ef) : {Laws.all_bad(List.append(&2, R.Cmd, S.keep(_, R.Set{x0, x1}), ps)) == True{} : Bool}
        ih
    case R.SetNX{x0, x1}:
      ih =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, m, False{}}, srv), False{}, ef) : {Laws.all_bad(List.append(&2, R.Cmd, S.keep(_, R.SetNX{x0, x1}), ps)) == True{} : Bool}
        ih
    case R.GetSet{x0, x1}:
      ih =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, m, False{}}, srv), False{}, ef) : {Laws.all_bad(List.append(&2, R.Cmd, S.keep(_, R.GetSet{x0, x1}), ps)) == True{} : Bool}
        ih
    case R.Del{x0}:
      ih =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, m, False{}}, srv), False{}, ef) : {Laws.all_bad(List.append(&2, R.Cmd, S.keep(_, R.Del{x0}), ps)) == True{} : Bool}
        ih
    case R.Exists{x0}:
      ih =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, m, False{}}, srv), False{}, ef) : {Laws.all_bad(List.append(&2, R.Cmd, S.keep(_, R.Exists{x0}), ps)) == True{} : Bool}
        ih
    case R.IncrBy{x0, x1}:
      ih =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, m, False{}}, srv), False{}, ef) : {Laws.all_bad(List.append(&2, R.Cmd, S.keep(_, R.IncrBy{x0, x1}), ps)) == True{} : Bool}
        ih
    case R.Append{x0, x1}:
      ih =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, m, False{}}, srv), False{}, ef) : {Laws.all_bad(List.append(&2, R.Cmd, S.keep(_, R.Append{x0, x1}), ps)) == True{} : Bool}
        ih
    case R.Strlen{x0}:
      ih =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, m, False{}}, srv), False{}, ef) : {Laws.all_bad(List.append(&2, R.Cmd, S.keep(_, R.Strlen{x0}), ps)) == True{} : Bool}
        ih
    case R.MGet{x0}:
      ih =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, m, False{}}, srv), False{}, ef) : {Laws.all_bad(List.append(&2, R.Cmd, S.keep(_, R.MGet{x0}), ps)) == True{} : Bool}
        ih
    case R.MSet{x0}:
      ih =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, m, False{}}, srv), False{}, ef) : {Laws.all_bad(List.append(&2, R.Cmd, S.keep(_, R.MSet{x0}), ps)) == True{} : Bool}
        ih
    case R.DbSize{}:
      ih =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, m, False{}}, srv), False{}, ef) : {Laws.all_bad(List.append(&2, R.Cmd, S.keep(_, R.DbSize{}), ps)) == True{} : Bool}
        ih
    case R.FlushAll{}:
      ih =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, m, False{}}, srv), False{}, ef) : {Laws.all_bad(List.append(&2, R.Cmd, S.keep(_, R.FlushAll{}), ps)) == True{} : Bool}
        ih
    case R.Keys{x0}:
      ih =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, m, False{}}, srv), False{}, ef) : {Laws.all_bad(List.append(&2, R.Cmd, S.keep(_, R.Keys{x0}), ps)) == True{} : Bool}
        ih
    case R.Peek{x0, x1}:
      ih =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, m, False{}}, srv), False{}, ef) : {Laws.all_bad(List.append(&2, R.Cmd, S.keep(_, R.Peek{x0, x1}), ps)) == True{} : Bool}
        ih
    case R.Own{x0}:
      ih => ih
    case R.Bad{x0}:
      ih => ih

def auth_own(o: R.SessOp, +id: Nat, +a: Bool, +n: String, +m: S.Mute, +srv: S.Srv, +ef: {S.authed(S.Conn{id, a, n, m, False{}}, srv) == False{} : Bool}, +ep: {S.nopass(srv) == False{} : Bool})
  -> {Laws.logs_in(R.Own{o}) == False{} : Bool}
  -> {S.conn.auth(S.next_conn(False{}, R.Own{o}, S.Conn{id, a, n, m, False{}}, srv)) == False{} : Bool}:
  match o:
    case R.SHello{y0}:
      el => Empty.absurd({S.conn.auth(S.next_conn(False{}, R.Own{R.SHello{y0}}, S.Conn{id, a, n, m, False{}}, srv)) == False{} : Bool}, true_false(el))
    case R.SAuth{y0}:
      el => Empty.absurd({S.conn.auth(S.next_conn(False{}, R.Own{R.SAuth{y0}}, S.Conn{id, a, n, m, False{}}, srv)) == False{} : Bool}, true_false(el))
    case R.SSelect{y0}:
      el =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, m, False{}}, srv), False{}, ef) : {S.conn.auth(S.next_conn.k(S.KSess{R.SSelect{y0}}, _, S.Conn{id, a, n, m, False{}}, srv)) == False{} : Bool}
        ef
    case R.SQuit{}:
      el => ef
    case R.SReset{}:
      el => ep
    case R.SClientId{}:
      el =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, m, False{}}, srv), False{}, ef) : {S.conn.auth(S.next_conn.k(S.KSess{R.SClientId{}}, _, S.Conn{id, a, n, m, False{}}, srv)) == False{} : Bool}
        ef
    case R.SClientGetName{}:
      el =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, m, False{}}, srv), False{}, ef) : {S.conn.auth(S.next_conn.k(S.KSess{R.SClientGetName{}}, _, S.Conn{id, a, n, m, False{}}, srv)) == False{} : Bool}
        ef
    case R.SClientSetName{y0}:
      el =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, m, False{}}, srv), False{}, ef) : {S.conn.auth(S.next_conn.k(S.KSess{R.SClientSetName{y0}}, _, S.Conn{id, a, n, m, False{}}, srv)) == False{} : Bool}
        ef
    case R.SClientReply{y0}:
      el =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, m, False{}}, srv), False{}, ef) : {S.conn.auth(S.next_conn.k(S.KSess{R.SClientReply{y0}}, _, S.Conn{id, a, n, m, False{}}, srv)) == False{} : Bool}
        ef
    case R.SConfigGet{y0}:
      el =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, m, False{}}, srv), False{}, ef) : {S.conn.auth(S.next_conn.k(S.KSess{R.SConfigGet{y0}}, _, S.Conn{id, a, n, m, False{}}, srv)) == False{} : Bool}
        ef
    case R.SConfigSet{y0}:
      el =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, m, False{}}, srv), False{}, ef) : {S.conn.auth(S.next_conn.k(S.KSess{R.SConfigSet{y0}}, _, S.Conn{id, a, n, m, False{}}, srv)) == False{} : Bool}
        ef
    case R.SConfigResetStat{}:
      el =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, m, False{}}, srv), False{}, ef) : {S.conn.auth(S.next_conn.k(S.KSess{R.SConfigResetStat{}}, _, S.Conn{id, a, n, m, False{}}, srv)) == False{} : Bool}
        ef
    case R.SInfo{y0}:
      el =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, m, False{}}, srv), False{}, ef) : {S.conn.auth(S.next_conn.k(S.KSess{R.SInfo{y0}}, _, S.Conn{id, a, n, m, False{}}, srv)) == False{} : Bool}
        ef
    case R.SCommand{y0}:
      el =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, m, False{}}, srv), False{}, ef) : {S.conn.auth(S.next_conn.k(S.KSess{R.SCommand{y0}}, _, S.Conn{id, a, n, m, False{}}, srv)) == False{} : Bool}
        ef
    case R.SReply{y0}:
      el =>
        %Equal.sym(Bool, S.authed(S.Conn{id, a, n, m, False{}}, srv), False{}, ef) : {S.conn.auth(S.next_conn.k(S.KSess{R.SReply{y0}}, _, S.Conn{id, a, n, m, False{}}, srv)) == False{} : Bool}
        ef
    case R.SBad{y0}:
      el => ef

# and leaves the client not authenticated, unless it is AUTH or HELLO
def auth_nc(c: R.Cmd, +id: Nat, +a: Bool, +n: String, +m: S.Mute, +srv: S.Srv, +ef: {S.authed(S.Conn{id, a, n, m, False{}}, srv) == False{} : Bool}, +ep: {S.nopass(srv) == False{} : Bool})
  -> {Laws.logs_in(c) == False{} : Bool}
  -> {S.conn.auth(S.next_conn(False{}, c, S.Conn{id, a, n, m, False{}}, srv)) == False{} : Bool}:
  match c:
    case R.Ping{}:
      el => ef
    case R.Echo{x0}:
      el => ef
    case R.Get{x0}:
      el => ef
    case R.Set{x0, x1}:
      el => ef
    case R.SetNX{x0, x1}:
      el => ef
    case R.GetSet{x0, x1}:
      el => ef
    case R.Del{x0}:
      el => ef
    case R.Exists{x0}:
      el => ef
    case R.IncrBy{x0, x1}:
      el => ef
    case R.Append{x0, x1}:
      el => ef
    case R.Strlen{x0}:
      el => ef
    case R.MGet{x0}:
      el => ef
    case R.MSet{x0}:
      el => ef
    case R.DbSize{}:
      el => ef
    case R.FlushAll{}:
      el => ef
    case R.Keys{x0}:
      el => ef
    case R.Peek{x0, x1}:
      el => ef
    case R.Own{x0}:
      el => auth_own(x0, id, a, n, m, srv, ef, ep)(el)
    case R.Bad{x0}:
      el => ef

def noauth_go(cmds: List<&2, R.Cmd>, conn: S.Conn, +srv: S.Srv) -> {S.conn.auth(conn) == False{} : Bool} -> {S.nopass(srv) == False{} : Bool} -> {Laws.no_login(cmds) == True{} : Bool} -> {Laws.all_bad(S.plan(cmds, conn, srv)) == True{} : Bool}:
  match cmds conn:
    case Nil{} _:
      ea => ep => el => {==}
    case Con{+c, +rest} S.Conn{+id, +a, +n, +m, True{}}:
      +ea => +ep => +el => noauth_go(rest, S.Conn{id, a, n, m, True{}}, srv)(ea)(ep)(and_r(Bool.not(Laws.logs_in(c)), Laws.no_login(rest))(el))
    case Con{+c, +rest} S.Conn{+id, +a, +n, +m, False{}}:
      +ea => +ep => +el =>
        ran_bad(c, S.plan(rest, S.next_conn(False{}, c, S.Conn{id, a, n, m, False{}}, srv), S.next_srv(False{}, c, S.Conn{id, a, n, m, False{}}, srv)), id, a, n, m, srv, or_ff(a, S.nopass(srv))(ea)(ep))(
          noauth_go(rest, S.next_conn(False{}, c, S.Conn{id, a, n, m, False{}}, srv), S.next_srv(False{}, c, S.Conn{id, a, n, m, False{}}, srv))(auth_nc(c, id, a, n, m, srv, or_ff(a, S.nopass(srv))(ea)(ep), ep)(not_true(Laws.logs_in(c))(and_l(Bool.not(Laws.logs_in(c)), Laws.no_login(rest))(el))))(Equal.trans(Bool, S.nopass(S.next_srv(False{}, c, S.Conn{id, a, n, m, False{}}, srv)), S.nopass(srv), False{}, Equal.cong(S.Srv, Bool, z => S.nopass(z), S.next_srv(False{}, c, S.Conn{id, a, n, m, False{}}, srv), srv, srv_same(False{}, c, S.Conn{id, a, n, m, False{}}, srv, or_ff(a, S.nopass(srv))(ea)(ep))), ep))(and_r(Bool.not(Laws.logs_in(c)), Laws.no_login(rest))(el)))

def Laws.noauth(conn, srv, cmds, e1, e2, e3):
  noauth_go(cmds, conn, srv)(e1)(e2)(e3)

# Configuration
# =============

def Laws.config_fail(args, conn, srv, r, e):
  %Equal.sym(Result<&2, &2, R.Reply, List<&2, C.CItem>>, C.config.set(args, S.srv.cfg(srv)), Fail{r}, e) : {S.srv.set(_, srv) == srv : S.Srv}
  {==}

def Laws.config_pass(args, conn, srv, cfg, e):
  %Equal.sym(Result<&2, &2, R.Reply, List<&2, C.CItem>>, C.config.set(args, S.srv.cfg(srv)), Done{cfg}, e) : {S.srv.set(_, srv) == S.Srv{C.config.get_value(cfg, "requirepass"), cfg, S.srv.info(srv)} : S.Srv}
  {==}

def cfg_some_val(m: Maybe<&2, C.CItem>, d: C.CItem) -> C.CItem:
  match m:
    case Some{x}:
      x
    case None{}:
      d

def cfg_is_none(m: Maybe<&2, C.CItem>) -> Bool:
  match m:
    case Some{x}:
      False{}
    case None{}:
      True{}

def cfg_none_some(-x: C.CItem, e: {None{} == Some{x} : Maybe<&2, C.CItem>}) -> Empty:
  true_false(Equal.cong(Maybe<&2, C.CItem>, Bool, z => cfg_is_none(z), None{}, Some{x}, e))

def cfg_some_inj(+x: C.CItem, +y: C.CItem, e: {Some{x} == Some{y} : Maybe<&2, C.CItem>}) -> {x == y : C.CItem}:
  Equal.cong(Maybe<&2, C.CItem>, C.CItem, z => cfg_some_val(z, x), Some{x}, Some{y}, e)

def cfg_done_val(r: Result<&2, &2, R.Reply, List<&2, C.CItem>>, d: List<&2, C.CItem>) -> List<&2, C.CItem>:
  match r:
    case Done{x}:
      x
    case Fail{e}:
      d

def cfg_is_done(r: Result<&2, &2, R.Reply, List<&2, C.CItem>>) -> Bool:
  match r:
    case Done{x}:
      True{}
    case Fail{e}:
      False{}

def cfg_fail_done(-r: R.Reply, -x: List<&2, C.CItem>, e: {Fail{r} == Done{x} : Result<&2, &2, R.Reply, List<&2, C.CItem>>}) -> Empty:
  false_true(Equal.cong(Result<&2, &2, R.Reply, List<&2, C.CItem>>, Bool, z => cfg_is_done(z), Fail{r}, Done{x}, e))

def cfg_done_inj(+x: List<&2, C.CItem>, +y: List<&2, C.CItem>, e: {Done{x} == Done{y} : Result<&2, &2, R.Reply, List<&2, C.CItem>>}) -> {x == y : List<&2, C.CItem>}:
  Equal.cong(Result<&2, &2, R.Reply, List<&2, C.CItem>>, List<&2, C.CItem>, z => cfg_done_val(z, x), Done{x}, Done{y}, e)

# a parameter found by a name keeps being found by it once its value
# changes: with its new value, when the change is to it, and as it was,
# when the change is to another; b is whether the first parameter is the
# one called l
def find_put.k(b: Bool, +n: String, +a: String, +i: Bool, +h: Bool, +pr: Bool, +m: Bool, +t: C.CTy, +ap: C.CApp, +v: String, +rest: List<&2, C.CItem>, +l: String, +it: C.CItem, +name: String, +nv: String,
  ih: {C.item.find(rest, l) == Some{it} : Maybe<&2, C.CItem>} -> {C.item.name(it) == name : String} -> {C.item.find(C.items.put(rest, name, nv), l) == Some{Laws.with(it, nv)} : Maybe<&2, C.CItem>})
  -> {b == C.item.is(l, C.CItem{C.CParam{n, a, i, h, pr, m, t, ap}, v}) : Bool}
  -> {C.item.find(Con{C.CItem{C.CParam{n, a, i, h, pr, m, t, ap}, v}, rest}, l) == Some{it} : Maybe<&2, C.CItem>}
  -> {C.item.name(it) == name : String}
  -> {C.item.find(C.items.put(Con{C.CItem{C.CParam{n, a, i, h, pr, m, t, ap}, v}, rest}, name, nv), l) == Some{Laws.with(it, nv)} : Maybe<&2, C.CItem>}:
  match b:
    case True{}:
      +eb => +e1 => en =>
        %eb : {C.item.find.go(Con{C.CItem{C.CParam{n, a, i, h, pr, m, t, ap}, Bool.pick(String, String.eq(n, name), nv, v)}, C.items.put(rest, name, nv)}, l, _) == Some{Laws.with(it, nv)} : Maybe<&2, C.CItem>}
        %cfg_some_inj(C.CItem{C.CParam{n, a, i, h, pr, m, t, ap}, v}, it, Equal.trans(Maybe<&2, C.CItem>, C.item.find.go(Con{C.CItem{C.CParam{n, a, i, h, pr, m, t, ap}, v}, rest}, l, True{}), C.item.find(Con{C.CItem{C.CParam{n, a, i, h, pr, m, t, ap}, v}, rest}, l), Some{it}, Equal.cong(Bool, Maybe<&2, C.CItem>, z => C.item.find.go(Con{C.CItem{C.CParam{n, a, i, h, pr, m, t, ap}, v}, rest}, l, z), True{}, C.item.is(l, C.CItem{C.CParam{n, a, i, h, pr, m, t, ap}, v}), eb), e1)) : {Some{C.CItem{C.CParam{n, a, i, h, pr, m, t, ap}, Bool.pick(String, String.eq(n, name), nv, v)}} == Some{Laws.with(_, nv)} : Maybe<&2, C.CItem>}
        %Equal.sym(String, name, n, Equal.trans(String, name, C.item.name(it), n, Equal.sym(String, C.item.name(it), name, en), Equal.cong(C.CItem, String, z => C.item.name(z), it, C.CItem{C.CParam{n, a, i, h, pr, m, t, ap}, v}, Equal.sym(C.CItem, C.CItem{C.CParam{n, a, i, h, pr, m, t, ap}, v}, it, cfg_some_inj(C.CItem{C.CParam{n, a, i, h, pr, m, t, ap}, v}, it, Equal.trans(Maybe<&2, C.CItem>, C.item.find.go(Con{C.CItem{C.CParam{n, a, i, h, pr, m, t, ap}, v}, rest}, l, True{}), C.item.find(Con{C.CItem{C.CParam{n, a, i, h, pr, m, t, ap}, v}, rest}, l), Some{it}, Equal.cong(Bool, Maybe<&2, C.CItem>, z => C.item.find.go(Con{C.CItem{C.CParam{n, a, i, h, pr, m, t, ap}, v}, rest}, l, z), True{}, C.item.is(l, C.CItem{C.CParam{n, a, i, h, pr, m, t, ap}, v}), eb), e1)))))) : {Some{C.CItem{C.CParam{n, a, i, h, pr, m, t, ap}, Bool.pick(String, String.eq(n, _), nv, v)}} == Some{C.CItem{C.CParam{n, a, i, h, pr, m, t, ap}, nv}} : Maybe<&2, C.CItem>}
        %str_eq_self(n) : {Some{C.CItem{C.CParam{n, a, i, h, pr, m, t, ap}, Bool.pick(String, _, nv, v)}} == Some{C.CItem{C.CParam{n, a, i, h, pr, m, t, ap}, nv}} : Maybe<&2, C.CItem>}
        {==}
    case False{}:
      +eb => e1 => en =>
        %eb : {C.item.find.go(Con{C.CItem{C.CParam{n, a, i, h, pr, m, t, ap}, Bool.pick(String, String.eq(n, name), nv, v)}, C.items.put(rest, name, nv)}, l, _) == Some{Laws.with(it, nv)} : Maybe<&2, C.CItem>}
        ih(Equal.trans(Maybe<&2, C.CItem>, C.item.find.go(Con{C.CItem{C.CParam{n, a, i, h, pr, m, t, ap}, v}, rest}, l, False{}), C.item.find(Con{C.CItem{C.CParam{n, a, i, h, pr, m, t, ap}, v}, rest}, l), Some{it}, Equal.cong(Bool, Maybe<&2, C.CItem>, z => C.item.find.go(Con{C.CItem{C.CParam{n, a, i, h, pr, m, t, ap}, v}, rest}, l, z), False{}, C.item.is(l, C.CItem{C.CParam{n, a, i, h, pr, m, t, ap}, v}), eb), e1))(en)

def find_put(items: List<&2, C.CItem>, +l: String, +it: C.CItem, +name: String, +nv: String)
  -> {C.item.find(items, l) == Some{it} : Maybe<&2, C.CItem>}
  -> {C.item.name(it) == name : String}
  -> {C.item.find(C.items.put(items, name, nv), l) == Some{Laws.with(it, nv)} : Maybe<&2, C.CItem>}:
  match items:
    case Nil{}:
      e1 => en => Empty.absurd({C.item.find(C.items.put(Nil{}, name, nv), l) == Some{Laws.with(it, nv)} : Maybe<&2, C.CItem>}, cfg_none_some(it, e1))
    case Con{C.CItem{C.CParam{+n, +a, +i, +h, +pr, +m, +t, +ap}, +v}, +rest}:
      find_put.k(C.item.is(l, C.CItem{C.CParam{n, a, i, h, pr, m, t, ap}, v}), n, a, i, h, pr, m, t, ap, v, rest, l, it, name, nv, find_put(rest, l, it, name, nv))({==})

# A CONFIG SET of one parameter that succeeds got past the checks of its
# name, of its value (e2) and of what the value does; so it stored the
# checked value in the parameter, where a CONFIG GET finds it

# the end: the parameters are the old ones with the new value
def sg.end(+n: String, +v: String, +items: List<&2, C.CItem>, +name: String, +alias: String, +imm: Bool, +hidden: Bool, +prot: Bool, +multi: Bool, +ty: C.CTy, +app: C.CApp, +old: String, +nv: String, +items2: List<&2, C.CItem>, e1: {C.item.find(items, String.to_lower(n)) == Some{C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, app}, old}} : Maybe<&2, C.CItem>})
  -> {Done{C.items.put(items, name, nv)} == Done{items2} : Result<&2, &2, R.Reply, List<&2, C.CItem>>}
  -> {C.item.find(items2, String.to_lower(n)) == Some{Laws.with(C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, app}, old}, nv)} : Maybe<&2, C.CItem>}:
  e =>
    %cfg_done_inj(C.items.put(items, name, nv), items2, e) : {C.item.find(_, String.to_lower(n)) == Some{Laws.with(C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, app}, old}, nv)} : Maybe<&2, C.CItem>}
    find_put(items, String.to_lower(n), C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, app}, old}, name, nv)(e1)({==})

# a parameter that cannot change while the server runs: same is whether
# the new value is the old one
def sg.same(same: Bool, +msg: String, +n: String, +v: String, +items: List<&2, C.CItem>, +name: String, +alias: String, +imm: Bool, +hidden: Bool, +prot: Bool, +multi: Bool, +ty: C.CTy, +old: String, +nv: String, +items2: List<&2, C.CItem>, e1: {C.item.find(items, String.to_lower(n)) == Some{C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, C.AppFixed{msg}}, old}} : Maybe<&2, C.CItem>})
  -> {same == String.eq(old, nv) : Bool}
  -> {C.set.fixed(Maybe.or(&2, String, C.fixed.of(C.AppFixed{msg}, String.to_lower(n), String.eq(old, nv)), None{}), [C.VOk{C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, C.AppFixed{msg}}, old}, String.to_lower(n), nv}], items) == Done{items2} : Result<&2, &2, R.Reply, List<&2, C.CItem>>}
  -> {C.item.find(items2, String.to_lower(n)) == Some{Laws.with(C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, C.AppFixed{msg}}, old}, nv)} : Maybe<&2, C.CItem>}:
  match same:
    case True{}:
      es => e => sg.end(n, v, items, name, alias, imm, hidden, prot, multi, ty, C.AppFixed{msg}, old, nv, items2, e1)(Equal.trans(Result<&2, &2, R.Reply, List<&2, C.CItem>>, C.set.fixed(Maybe.or(&2, String, C.fixed.of(C.AppFixed{msg}, String.to_lower(n), True{}), None{}), [C.VOk{C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, C.AppFixed{msg}}, old}, String.to_lower(n), nv}], items), C.set.fixed(Maybe.or(&2, String, C.fixed.of(C.AppFixed{msg}, String.to_lower(n), String.eq(old, nv)), None{}), [C.VOk{C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, C.AppFixed{msg}}, old}, String.to_lower(n), nv}], items), Done{items2}, Equal.cong(Bool, Result<&2, &2, R.Reply, List<&2, C.CItem>>, z => C.set.fixed(Maybe.or(&2, String, C.fixed.of(C.AppFixed{msg}, String.to_lower(n), z), None{}), [C.VOk{C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, C.AppFixed{msg}}, old}, String.to_lower(n), nv}], items), True{}, String.eq(old, nv), es), e))
    case False{}:
      es => e => Empty.absurd({C.item.find(items2, String.to_lower(n)) == Some{Laws.with(C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, C.AppFixed{msg}}, old}, nv)} : Maybe<&2, C.CItem>}, cfg_fail_done(R.RError{C.e.set(String.to_lower(n), msg)}, items2, Equal.trans(Result<&2, &2, R.Reply, List<&2, C.CItem>>, C.set.fixed(Maybe.or(&2, String, C.fixed.of(C.AppFixed{msg}, String.to_lower(n), False{}), None{}), [C.VOk{C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, C.AppFixed{msg}}, old}, String.to_lower(n), nv}], items), C.set.fixed(Maybe.or(&2, String, C.fixed.of(C.AppFixed{msg}, String.to_lower(n), String.eq(old, nv)), None{}), [C.VOk{C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, C.AppFixed{msg}}, old}, String.to_lower(n), nv}], items), Done{items2}, Equal.cong(Bool, Result<&2, &2, R.Reply, List<&2, C.CItem>>, z => C.set.fixed(Maybe.or(&2, String, C.fixed.of(C.AppFixed{msg}, String.to_lower(n), z), None{}), [C.VOk{C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, C.AppFixed{msg}}, old}, String.to_lower(n), nv}], items), False{}, String.eq(old, nv), es), e)))

# what the new value does: only a parameter that cannot change may fail
def sg.app(+n: String, +v: String, +items: List<&2, C.CItem>, +name: String, +alias: String, +imm: Bool, +hidden: Bool, +prot: Bool, +multi: Bool, +ty: C.CTy, +app: C.CApp, +old: String, +nv: String, +items2: List<&2, C.CItem>, e1: {C.item.find(items, String.to_lower(n)) == Some{C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, app}, old}} : Maybe<&2, C.CItem>})
  -> {C.set.fixed(C.fixed.first([C.VOk{C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, app}, old}, String.to_lower(n), nv}]), [C.VOk{C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, app}, old}, String.to_lower(n), nv}], items) == Done{items2} : Result<&2, &2, R.Reply, List<&2, C.CItem>>}
  -> {C.item.find(items2, String.to_lower(n)) == Some{Laws.with(C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, app}, old}, nv)} : Maybe<&2, C.CItem>}:
  match app:
    case C.AppNone{}:
      e => sg.end(n, v, items, name, alias, imm, hidden, prot, multi, ty, C.AppNone{}, old, nv, items2, e1)(e)
    case C.AppHz{}:
      e => sg.end(n, v, items, name, alias, imm, hidden, prot, multi, ty, C.AppHz{}, old, nv, items2, e1)(e)
    case C.AppMin{+x}:
      e => sg.end(n, v, items, name, alias, imm, hidden, prot, multi, ty, C.AppMin{x}, old, nv, items2, e1)(e)
    case C.AppPass{}:
      e => sg.end(n, v, items, name, alias, imm, hidden, prot, multi, ty, C.AppPass{}, old, nv, items2, e1)(e)
    case C.AppFixed{+msg}:
      e => sg.same(String.eq(old, nv), msg, n, v, items, name, alias, imm, hidden, prot, multi, ty, old, nv, items2, e1)({==})(e)

# past the checks of its name: its value is checked (e2)
def sg.ok(+n: String, +v: String, +items: List<&2, C.CItem>, +name: String, +alias: String, +imm: Bool, +hidden: Bool, +prot: Bool, +multi: Bool, +ty: C.CTy, +app: C.CApp, +old: String, +nv: String, +items2: List<&2, C.CItem>, e1: {C.item.find(items, String.to_lower(n)) == Some{C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, app}, old}} : Maybe<&2, C.CItem>}, e2: {C.item.set(C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, app}, old}, v) == Done{nv} : Result<&2, &2, String, String>})
  -> {C.set.go([C.LOk{C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, app}, old}, String.to_lower(n), v}], items) == Done{items2} : Result<&2, &2, R.Reply, List<&2, C.CItem>>}
  -> {C.item.find(items2, String.to_lower(n)) == Some{Laws.with(C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, app}, old}, nv)} : Maybe<&2, C.CItem>}:
  e =>
    sg.app(n, v, items, name, alias, imm, hidden, prot, multi, ty, app, old, nv, items2, e1)(Equal.trans(Result<&2, &2, R.Reply, List<&2, C.CItem>>, C.set.vals([C.val.mk(Done{nv}, C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, app}, old}, String.to_lower(n))], items), C.set.vals([C.val.mk(C.item.set(C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, app}, old}, v), C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, app}, old}, String.to_lower(n))], items), Done{items2},
      Equal.cong(Result<&2, &2, String, String>, Result<&2, &2, R.Reply, List<&2, C.CItem>>, z => C.set.vals([C.val.mk(z, C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, app}, old}, String.to_lower(n))], items), Done{nv}, C.item.set(C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, app}, old}, v), Equal.sym(Result<&2, &2, String, String>, C.item.set(C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, app}, old}, v), Done{nv}, e2)), e))

# a protected parameter: p is whether enable-protected-configs lets it change
def sg.p(p: Bool, +n: String, +v: String, +items: List<&2, C.CItem>, +name: String, +alias: String, +hidden: Bool, +multi: Bool, +ty: C.CTy, +app: C.CApp, +old: String, +nv: String, +items2: List<&2, C.CItem>, e1: {C.item.find(items, String.to_lower(n)) == Some{C.CItem{C.CParam{name, alias, False{}, hidden, True{}, multi, ty, app}, old}} : Maybe<&2, C.CItem>}, e2: {C.item.set(C.CItem{C.CParam{name, alias, False{}, hidden, True{}, multi, ty, app}, old}, v) == Done{nv} : Result<&2, &2, String, String>})
  -> {p == C.prot_ok(items) : Bool}
  -> {C.set.go([C.look.deny(False{}, Bool.not(C.prot_ok(items)), False{}, n, C.LOk{C.CItem{C.CParam{name, alias, False{}, hidden, True{}, multi, ty, app}, old}, String.to_lower(n), v})], items) == Done{items2} : Result<&2, &2, R.Reply, List<&2, C.CItem>>}
  -> {C.item.find(items2, String.to_lower(n)) == Some{Laws.with(C.CItem{C.CParam{name, alias, False{}, hidden, True{}, multi, ty, app}, old}, nv)} : Maybe<&2, C.CItem>}:
  match p:
    case True{}:
      ep => e => sg.ok(n, v, items, name, alias, False{}, hidden, True{}, multi, ty, app, old, nv, items2, e1, e2)(Equal.trans(Result<&2, &2, R.Reply, List<&2, C.CItem>>, C.set.go([C.look.deny(False{}, Bool.not(True{}), False{}, n, C.LOk{C.CItem{C.CParam{name, alias, False{}, hidden, True{}, multi, ty, app}, old}, String.to_lower(n), v})], items), C.set.go([C.look.deny(False{}, Bool.not(C.prot_ok(items)), False{}, n, C.LOk{C.CItem{C.CParam{name, alias, False{}, hidden, True{}, multi, ty, app}, old}, String.to_lower(n), v})], items), Done{items2}, Equal.cong(Bool, Result<&2, &2, R.Reply, List<&2, C.CItem>>, z => C.set.go([C.look.deny(False{}, Bool.not(z), False{}, n, C.LOk{C.CItem{C.CParam{name, alias, False{}, hidden, True{}, multi, ty, app}, old}, String.to_lower(n), v})], items), True{}, C.prot_ok(items), ep), e))
    case False{}:
      ep => e => Empty.absurd({C.item.find(items2, String.to_lower(n)) == Some{Laws.with(C.CItem{C.CParam{name, alias, False{}, hidden, True{}, multi, ty, app}, old}, nv)} : Maybe<&2, C.CItem>}, cfg_fail_done(R.RError{C.e.set(n, "can't set protected config")}, items2, Equal.trans(Result<&2, &2, R.Reply, List<&2, C.CItem>>, C.set.go([C.look.deny(False{}, Bool.not(False{}), False{}, n, C.LOk{C.CItem{C.CParam{name, alias, False{}, hidden, True{}, multi, ty, app}, old}, String.to_lower(n), v})], items), C.set.go([C.look.deny(False{}, Bool.not(C.prot_ok(items)), False{}, n, C.LOk{C.CItem{C.CParam{name, alias, False{}, hidden, True{}, multi, ty, app}, old}, String.to_lower(n), v})], items), Done{items2}, Equal.cong(Bool, Result<&2, &2, R.Reply, List<&2, C.CItem>>, z => C.set.go([C.look.deny(False{}, Bool.not(z), False{}, n, C.LOk{C.CItem{C.CParam{name, alias, False{}, hidden, True{}, multi, ty, app}, old}, String.to_lower(n), v})], items), False{}, C.prot_ok(items), ep), e)))

def sg.prot(+n: String, +v: String, +items: List<&2, C.CItem>, +name: String, +alias: String, +hidden: Bool, +prot: Bool, +multi: Bool, +ty: C.CTy, +app: C.CApp, +old: String, +nv: String, +items2: List<&2, C.CItem>, e1: {C.item.find(items, String.to_lower(n)) == Some{C.CItem{C.CParam{name, alias, False{}, hidden, prot, multi, ty, app}, old}} : Maybe<&2, C.CItem>}, e2: {C.item.set(C.CItem{C.CParam{name, alias, False{}, hidden, prot, multi, ty, app}, old}, v) == Done{nv} : Result<&2, &2, String, String>})
  -> {C.set.go([C.look.deny(False{}, Bool.and(prot, Bool.not(C.prot_ok(items))), False{}, n, C.LOk{C.CItem{C.CParam{name, alias, False{}, hidden, prot, multi, ty, app}, old}, String.to_lower(n), v})], items) == Done{items2} : Result<&2, &2, R.Reply, List<&2, C.CItem>>}
  -> {C.item.find(items2, String.to_lower(n)) == Some{Laws.with(C.CItem{C.CParam{name, alias, False{}, hidden, prot, multi, ty, app}, old}, nv)} : Maybe<&2, C.CItem>}:
  match prot:
    case True{}:
      e => sg.p(C.prot_ok(items), n, v, items, name, alias, hidden, multi, ty, app, old, nv, items2, e1, e2)({==})(e)
    case False{}:
      e => sg.ok(n, v, items, name, alias, False{}, hidden, False{}, multi, ty, app, old, nv, items2, e1, e2)(e)

def sg.imm(+n: String, +v: String, +items: List<&2, C.CItem>, +name: String, +alias: String, +imm: Bool, +hidden: Bool, +prot: Bool, +multi: Bool, +ty: C.CTy, +app: C.CApp, +old: String, +nv: String, +items2: List<&2, C.CItem>, e1: {C.item.find(items, String.to_lower(n)) == Some{C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, app}, old}} : Maybe<&2, C.CItem>}, e2: {C.item.set(C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, app}, old}, v) == Done{nv} : Result<&2, &2, String, String>})
  -> {C.set.go([C.look.deny(imm, Bool.and(prot, Bool.not(C.prot_ok(items))), False{}, n, C.LOk{C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, app}, old}, String.to_lower(n), v})], items) == Done{items2} : Result<&2, &2, R.Reply, List<&2, C.CItem>>}
  -> {C.item.find(items2, String.to_lower(n)) == Some{Laws.with(C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, app}, old}, nv)} : Maybe<&2, C.CItem>}:
  match imm:
    case True{}:
      e => Empty.absurd({C.item.find(items2, String.to_lower(n)) == Some{Laws.with(C.CItem{C.CParam{name, alias, True{}, hidden, prot, multi, ty, app}, old}, nv)} : Maybe<&2, C.CItem>}, cfg_fail_done(R.RError{C.e.set(n, "can't set immutable config")}, items2, e))
    case False{}:
      e => sg.prot(n, v, items, name, alias, hidden, prot, multi, ty, app, old, nv, items2, e1, e2)(e)

def sg.top(+n: String, +v: String, +items: List<&2, C.CItem>, it: C.CItem, +nv: String, +items2: List<&2, C.CItem>)
  -> {C.item.find(items, String.to_lower(n)) == Some{it} : Maybe<&2, C.CItem>}
  -> {C.item.set(it, v) == Done{nv} : Result<&2, &2, String, String>}
  -> {C.config.set([n, v], items) == Done{items2} : Result<&2, &2, R.Reply, List<&2, C.CItem>>}
  -> {C.item.find(items2, String.to_lower(n)) == Some{Laws.with(it, nv)} : Maybe<&2, C.CItem>}:
  match it:
    case C.CItem{C.CParam{+name, +alias, +imm, +hidden, +prot, +multi, +ty, +app}, +old}:
      +e1 => e2 => e3 =>
        sg.imm(n, v, items, name, alias, imm, hidden, prot, multi, ty, app, old, nv, items2, e1, e2)(Equal.trans(Result<&2, &2, R.Reply, List<&2, C.CItem>>, C.set.go([C.look.mk(Some{C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, app}, old}}, n, v, Nil{}, C.prot_ok(items))], items), C.set.go([C.look.mk(C.item.find(items, String.to_lower(n)), n, v, Nil{}, C.prot_ok(items))], items), Done{items2}, Equal.cong(Maybe<&2, C.CItem>, Result<&2, &2, R.Reply, List<&2, C.CItem>>, z => C.set.go([C.look.mk(z, n, v, Nil{}, C.prot_ok(items))], items), Some{C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, app}, old}}, C.item.find(items, String.to_lower(n)), Equal.sym(Maybe<&2, C.CItem>, C.item.find(items, String.to_lower(n)), Some{C.CItem{C.CParam{name, alias, imm, hidden, prot, multi, ty, app}, old}}, e1)), e3))

def Laws.config_set_get(n, v, items, it, nv, items2, e1, e2, e3):
  sg.top(n, v, items, it, nv, items2)(e1)(e2)(e3)
