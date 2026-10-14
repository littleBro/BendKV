#!/usr/bin/env python3
# gen_trie.py: writes the 16-way parts of src/map.bend (and of proof/PROOF.bend)
# between their "# BEGIN gen_trie: NAME" and "# END gen_trie: NAME"
# lines. A 16-way node spelled out by hand is 16 fields in every pattern
# and 16 or 256 cases in every proof; this script spells them instead.
#
#   python3 tools/gen_trie.py          # rewrites the blocks in place
#   python3 tools/gen_trie.py --check  # fails if a block is out of date
import re, sys, pathlib

N = 16
HERE = pathlib.Path(__file__).resolve().parent.parent
cs = [f"c{i}" for i in range(N)]
H = [f"H{i}" for i in range(N)]

def fields(xs):
    return ", ".join(xs)

def node(xs):
    return "Node{" + fields(xs) + "}"

def with_at(xs, i, v):
    return xs[:i] + [v] + xs[i + 1:]

def tips(i, v):
    return with_at(["Tip{}"] * N, i, v)

def block_types():
    out = ["# a hex digit of a hash: which of a node's 16 subtries a path takes",
           "type Hex is Data:"]
    out += [f"  {h}{{}}" for h in H]
    out += ["",
            "# a 16-way trie: Tip is the empty trie, and a Node holds the subtries",
            "# for the 16 values of the next digit. Where a path ends, the trie is",
            "# the bucket of that path: a chain of Ent cells, each a key, its value,",
            "# the time it expires at (ms since 1970; 0 when it does not) and the",
            "# rest of the bucket, which ends in Tip. A Node inside a bucket and an",
            "# Ent above the end of a path are never built; they read as empty. An",
            "# Ent of four words fills its block, as one of three did (the",
            "# allocator's blocks are powers of two).",
            "type Trie<-V: Data> is Data:",
            "  Tip{}",
            "  Node{" + fields(f"{c}: Trie<V>" for c in cs) + "}",
            "  Ent{key: String, val: V, exp: Nat, rest: Trie<V>}"]
    return out

def block_hex():
    out = ["# the digit n, for n below 16 (a larger n reads as 15): a chain of",
           "# matches that clang folds into the number itself",
           "def hex.of(n: Nat) -> Hex:"]
    def go(i, var, ind):
        r = [f"{ind}match {var}:", f"{ind}  case 0n:", f"{ind}    {H[i]}{{}}",
             f"{ind}  case 1n+n{i}:"]
        if i == N - 2:
            return r + [f"{ind}    {H[N - 1]}{{}}"]
        return r + go(i + 1, f"n{i}", ind + "    ")
    return out + go(0, "n", "  ")

STEP = "hex(shr4(h)), shr4(h)"

def block_walks():
    out = ["# the bucket where a walk of depth d ends: x is the digit of h that it",
           "# takes first. get walks with tget_k, which reads the bucket where it",
           "# ends, so the walk only reads the trie; tget_h is its spec",
           "# (PROOF.bend: tget_k_eq). A walk looks at the node before the digit,",
           "# so an empty subtrie ends it whatever the digit.",
           "def tget_h(-V: Data, d: Nat, t: Trie<V>, x: Hex, +h: U32) -> Trie<V>:",
           "  match d t x:",
           "    case 0n t0 _:",
           "      t0"]
    for i in range(N):
        out += [f"    case 1n+p {node(cs)} {H[i]}{{}}:",
                f"      tget_h(V, p, {cs[i]}, {STEP})"]
    out += ["    case 1n+p other _:", "      Tip{}", ""]
    out += ["def tget_k(-V: Data, d: Nat, t: Trie<V>, x: Hex, +h: U32, +k: String) -> Maybe<&2, V>:",
            "  match d t x:",
            "    case 0n t0 _:",
            "      bget(V, k, t0)"]
    for i in range(N):
        out += [f"    case 1n+p {node(cs)} {H[i]}{{}}:",
                f"      tget_k(V, p, {cs[i]}, {STEP}, k)"]
    out += ["    case 1n+p other _:", "      None{}", ""]
    out += ["# tget_k answering the code of k's entry (bcode): 0 when there is none,",
            "# else 1 plus the time it expires at (a write that counts the keys asks",
            "# it first)",
            "def tget_kx(-V: Data, d: Nat, +t: Trie<V>, x: Hex, +h: U32, +k: String) -> Nat:",
            "  match d t x:",
            "    case 0n t0 _:",
            "      bcode(V, k, t0)"]
    for i in range(N):
        out += [f"    case 1n+p {node(cs)} {H[i]}{{}}:",
                f"      tget_kx(V, p, {cs[i]}, {STEP}, k)"]
    out += ["    case 1n+p other _:", "      0n", ""]
    out += ["# the keys of the bucket a walk ends at that a scan of mode takes at now",
            "# (bkeys), before acc: eviction's samples read buckets one walk each,",
            "# which reads the trie lent, as get's do",
            "def tget_kb(-V: Data, d: Nat, +t: Trie<V>, x: Hex, +h: U32, +now: Nat, +mode: Nat, acc: List<&2, String>) -> List<&2, String>:",
            "  match d t x:",
            "    case 0n t0 _:",
            "      bkeys(V, t0, now, mode, acc)"]
    for i in range(N):
        out += [f"    case 1n+p {node(cs)} {H[i]}{{}}:",
                f"      tget_kb(V, p, {cs[i]}, {STEP}, now, mode, acc)"]
    out += ["    case 1n+p other _:", "      acc", ""]
    out += ["# tget_k answering k's entry, its value and its time (bent)",
            "def tget_ke(-V: Data, d: Nat, +t: Trie<V>, x: Hex, +h: U32, +k: String) -> Maybe<&2, Item<V>>:",
            "  match d t x:",
            "    case 0n t0 _:",
            "      bent(V, k, t0)"]
    for i in range(N):
        out += [f"    case 1n+p {node(cs)} {H[i]}{{}}:",
                f"      tget_ke(V, p, {cs[i]}, {STEP}, k)"]
    out += ["    case 1n+p other _:", "      None{}", ""]
    out += ["# tget_k answering the value when the key is there at now (blive)",
            "def tget_kl(-V: Data, d: Nat, +t: Trie<V>, x: Hex, +h: U32, +k: String, +now: Nat) -> Maybe<&2, V>:",
            "  match d t x:",
            "    case 0n t0 _:",
            "      blive(V, k, t0, now)"]
    for i in range(N):
        out += [f"    case 1n+p {node(cs)} {H[i]}{{}}:",
                f"      tget_kl(V, p, {cs[i]}, {STEP}, k, now)"]
    out += ["    case 1n+p other _:", "      None{}", ""]
    out += ["# tget_kl for the keys' values, answering a copy of a string (bget_c)",
            "def tget_kc(d: Nat, +t: Trie<Val>, x: Hex, +h: U32, +k: String, +now: Nat) -> Got:",
            "  match d t x:",
            "    case 0n t0 _:",
            "      bget_c(k, t0, now)"]
    for i in range(N):
        out += [f"    case 1n+p {node(cs)} {H[i]}{{}}:",
                f"      tget_kc(p, {cs[i]}, {STEP}, k, now)"]
    out += ["    case 1n+p other _:", "      GNone{}", ""]
    out += ["# hints for a walk to come (Mem.prefetch): ttouch is acc, after starting",
            "# to load the subtrie where a walk of depth d ends (a bucket at depth",
            "# 5); tetouch is acc, after starting to load the key and the value of",
            "# the first entry of that bucket. Each reads the nodes above, which a",
            "# pass over many keys keeps in the cache, and changes nothing.",
            "def ttouch(-V: Data, d: Nat, t: Trie<V>, x: Hex, +h: U32, acc: U32) -> U32:",
            "  match d t x:",
            "    case 0n t0 _:",
            "      Mem.prefetch(Trie<V>, t0, acc)"]
    for i in range(N):
        out += [f"    case 1n+p {node(cs)} {H[i]}{{}}:",
                f"      ttouch(V, p, {cs[i]}, {STEP}, acc)"]
    out += ["    case 1n+p other _:", "      acc", ""]
    out += ["def tetouch(-V: Data, d: Nat, t: Trie<V>, x: Hex, +h: U32, acc: U32) -> U32:",
            "  match d t x:",
            "    case 0n t0 _:",
            "      btouch(V, t0, acc)"]
    for i in range(N):
        out += [f"    case 1n+p {node(cs)} {H[i]}{{}}:",
                f"      tetouch(V, p, {cs[i]}, {STEP}, acc)"]
    out += ["    case 1n+p other _:", "      acc", ""]
    out += ["# the trie with op applied to the bucket where the walk ends; a walk",
            "# into an empty subtrie builds the nodes down to the bucket. A delete",
            "# walks with tdel_h, which reads as this walk with ODel.",
            "def tmod_h(-V: Data, d: Nat, t: Trie<V>, x: Hex, +h: U32, op: Op<V>) -> Trie<V>:",
            "  match d t x:",
            "    case 0n t0 _:",
            "      bapply(V, op, t0)"]
    for i in range(N):
        rec = f"tmod_h(V, p, {cs[i]}, {STEP}, op)"
        out += [f"    case 1n+p {node(cs)} {H[i]}{{}}:",
                f"      {node(with_at(cs, i, rec))}"]
    for i in range(N):
        rec = f"tmod_h(V, p, Tip{{}}, {STEP}, op)"
        out += [f"    case 1n+p other {H[i]}{{}}:",
                f"      {node(tips(i, rec))}"]
    out += ["",
            "# t, but the empty trie for a node of 16 empty subtries",
            "def tnode(-V: Data, t: Trie<V>) -> Trie<V>:",
            "  match t:",
            f"    case {node(['Tip{}'] * N)}:",
            "      Tip{}",
            "    case other:",
            "      other",
            "",
            "# whether t is the empty trie",
            "def tis_tip(-V: Data, +t: Trie<V>) -> Bool:",
            "  match t:",
            "    case Tip{}:",
            "      True{}",
            "    case other:",
            "      False{}",
            "",
            "# tnode of t when e says so (a delete emptied one of its subtries),",
            "# else t: a node with a subtrie that is not empty is kept unread",
            "def tnode_if(-V: Data, e: Bool, t: Trie<V>) -> Trie<V>:",
            "  match e:",
            "    case True{}:",
            "      tnode(V, t)",
            "    case False{}:",
            "      t",
            "",
            "# the trie without k's entries in the bucket where the walk ends",
            "# (bdel). A node that this leaves empty goes too (tnode_if), so a",
            "# trie keeps no more nodes than its keys take, and a walk into an",
            "# empty subtrie changes nothing. It reads as tmod_h with ODel{k},",
            "# bucket by bucket (PROOF.bend: tdel_eq).",
            "def tdel_h(-V: Data, d: Nat, t: Trie<V>, x: Hex, +h: U32, +k: String) -> Trie<V>:",
            "  match d t x:",
            "    case 0n t0 _:",
            "      bdel(V, k, t0)"]
    for i in range(N):
        out += [f"    case 1n+p {node(cs)} {H[i]}{{}}:",
                f"      +a = tdel_h(V, p, {cs[i]}, {STEP}, k)",
                f"      tnode_if(V, tis_tip(V, a), {node(with_at(cs, i, 'a'))})"]
    out += ["    case 1n+p other _:", "      other"]
    return out

def block_folds():
    acc = "acc"
    for c in reversed(cs):
        acc = f"tkeys(V, {c}, now, {acc})"
    size = "0n"
    for c in reversed(cs):
        size = f"tsize(V, {c})" if size == "0n" else f"Nat.add(tsize(V, {c}), {size})"
    return ["# the keys of t there at now, before acc; and how many entries t holds",
            "def tkeys(-V: Data, t: Trie<V>, +now: Nat, acc: List<&2, String>) -> List<&2, String>:",
            "  match t:",
            "    case Tip{}:",
            "      acc",
            f"    case {node(cs)}:",
            f"      {acc}",
            "    case Ent{k, v, +e, rest}:",
            "      kput(live(now, e), k, tkeys(V, rest, now, acc))",
            "",
            "def tsize(-V: Data, t: Trie<V>) -> Nat:",
            "  match t:",
            "    case Tip{}:",
            "      0n",
            f"    case {node(cs)}:",
            f"      {size}",
            "    case Ent{k, v, e, rest}:",
            "      1n+tsize(V, rest)"]

# the scan of a node: its 16 subtries in order, each skipped whole when
# it lies before the cursor (or at or past the bound to); the subtries are
# lent, as the trie is (taken, each would be shared and dropped at every
# node the scan reads)
def block_scan():
    s = "s"
    for i, c in enumerate(cs):
        base = "base" if i == 0 else f"Nat.add(base, Nat.mul({i}n, q))"
        skip = f"Nat.is_le(Nat.add(base, Nat.mul({i + 1}n, q)), from)"
        skip = f"Bool.or({skip}, Nat.is_le(to, {base}))"
        s = f"tscan(V, p, {skip}, {c}, {base}, q, from, to, now, all, mode, {s})"
    return ["def tscan(-V: Data, +d: Nat, skip: Bool, +t: Trie<V>, +base: Nat, +span: Nat, +from: Nat, +to: Nat, +now: Nat, +all: Bool, +mode: Nat, s: Scan) -> Scan:",
            "  match d skip t s:",
            "    case _ True{} _ s:",
            "      s",
            "    case _ False{} _ Stop{at, acc}:",
            "      Stop{at, acc}",
            "    case 0n False{} b Scan{want, acc}:",
            "      bscan(V, b, base, want, acc, now, all, mode)",
            "    case 1n+p False{} Tip{} s:",
            "      s",
            f"    case 1n+p False{{}} {node(['+' + c for c in cs])} s:",
            "      +q = Nat.div(span, 16n)",
            f"      {s}",
            "    case 1n+p False{} Ent{+k, +v, +e, +rest} s:",
            "      s"]

# Proofs (PROOF.bend)
# ------------------

K = [f"KV.{h}{{}}" for h in H]
NX = "KV.hex(KV.shr4(h))"

def kv_node(xs):
    return "KV.Node{" + fields(xs) + "}"

def kv_tips(i=None, v=None):
    xs = ["KV.Tip{}"] * N
    return xs if i is None else with_at(xs, i, v)

def nxt(h):
    return f"KV.hex(KV.shr4({h})), KV.shr4({h})"

def block_digits():
    out = ["# hex_eq decides whether two digits are the same; it serves only the",
           "# proofs, which split on whether two walks take the same digits",
           "def hex_eq(x: KV.Hex, y: KV.Hex) -> Bool:",
           "  match x y:"]
    for i in range(N):
        out += [f"    case {K[i]} {K[i]}:", "      True{}", f"    case {K[i]} other:", "      False{}"]
    out += ["", "# digits that hex_eq calls the same are the same",
            "def hex_eq_sound(x: KV.Hex, y: KV.Hex) -> {hex_eq(x, y) == True{} : Bool} -> {x == y : KV.Hex}:",
            "  match x y:"]
    for i in range(N):
        for j in range(N):
            out.append(f"    case {K[i]} {K[j]}:")
            out.append("      e => {==}" if i == j else
                       f"      e => Empty.absurd({{{K[i]} == {K[j]} : KV.Hex}}, false_true(e))")
    return out

# the cases of a walk lemma past depth 0: a node goes on into the
# child of the digit, an empty trie or a misplaced entry ends the walk
def walk_cases(name, args):
    out = []
    for i in range(N):
        out += [f"    case 1n+p {kv_node(cs)} {K[i]}:",
                f"      {name}({args.replace('CHILD', cs[i])})"]
    out += ["    case 1n+p KV.Tip{} _:", "      {==}",
            "    case 1n+p KV.Ent{a, b, e, c} _:", "      {==}"]
    return out

def block_tget_k():
    out = ["# get walks with tget_k, which reads the bucket where the walk ends: the",
           "# bucket lookup after tget_h, by induction on the depth",
           "def tget_k_eq(-V: Data, d: Nat, t: KV.Trie<V>, x: KV.Hex, +h: U32, +k: String) -> {KV.bget(V, k, KV.tget_h(V, d, t, x, h)) == KV.tget_k(V, d, t, x, h, k) : Maybe<&2, V>}:",
           "  match d t x:",
           "    case 0n t0 _:",
           "      {==}"]
    return out + walk_cases("tget_k_eq", f"V, p, CHILD, {nxt('h')}, k")

def block_tget_kx():
    out = ["# a write that counts the keys asks tget_kx for its key's code: bcode",
           "# of the bucket where the walk ends, by induction on the depth",
           "def tget_kx_eq(-V: Data, d: Nat, t: KV.Trie<V>, x: KV.Hex, +h: U32, +k: String) -> {KV.bcode(V, k, KV.tget_h(V, d, t, x, h)) == KV.tget_kx(V, d, t, x, h, k) : Nat}:",
           "  match d t x:",
           "    case 0n t0 _:",
           "      {==}"]
    return out + walk_cases("tget_kx_eq", f"V, p, CHILD, {nxt('h')}, k")

def block_tget_ke():
    out = ["# an update reads its key's entry with tget_ke: bent of the bucket where",
           "# the walk ends, by induction on the depth",
           "def tget_ke_eq(-V: Data, d: Nat, t: KV.Trie<V>, x: KV.Hex, +h: U32, +k: String) -> {KV.bent(V, k, KV.tget_h(V, d, t, x, h)) == KV.tget_ke(V, d, t, x, h, k) : Maybe<&2, KV.Item<V>>}:",
           "  match d t x:",
           "    case 0n t0 _:",
           "      {==}"]
    return out + walk_cases("tget_ke_eq", f"V, p, CHILD, {nxt('h')}, k")

def block_tget_kl():
    out = ["# a read of a key there at now walks with tget_kl: blive of the bucket",
           "# where the walk ends, by induction on the depth",
           "def tget_kl_eq(-V: Data, d: Nat, t: KV.Trie<V>, x: KV.Hex, +h: U32, +k: String, +now: Nat) -> {KV.blive(V, k, KV.tget_h(V, d, t, x, h), now) == KV.tget_kl(V, d, t, x, h, k, now) : Maybe<&2, V>}:",
           "  match d t x:",
           "    case 0n t0 _:",
           "      {==}"]
    return out + walk_cases("tget_kl_eq", f"V, p, CHILD, {nxt('h')}, k, now")

def block_tget_kc():
    out = ["# GET reads with tget_kc, which answers a copy of the value: the same",
           "# answer as blive of the bucket where the walk ends (bget_c_eq), by",
           "# induction on the depth",
           "def tget_kc_eq(d: Nat, t: KV.Trie<KV.Val>, x: KV.Hex, +h: U32, +k: String, +now: Nat) -> {KV.got_of(KV.blive(KV.Val, k, KV.tget_h(KV.Val, d, t, x, h), now)) == KV.tget_kc(d, t, x, h, k, now) : KV.Got}:",
           "  match d t x:",
           "    case 0n t0 _:",
           "      bget_c_eq(k, t0, now)"]
    return out + walk_cases("tget_kc_eq", f"p, CHILD, {nxt('h')}, k, now")

def block_same():
    m = f"KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{{}}, {nxt('h')}, op), {nxt('h')})"
    tip_body = [f"      %tget_h_tip(V, p, {nxt('h')}) : {{KV.bapply(V, op, _) == {m} : KV.Trie<V>}}",
                f"      tget_tmod_same(V, p, KV.Tip{{}}, {nxt('h')}, op)"]
    out = ["# a read of the bucket that a walk modifies sees the modification",
           "def tget_tmod_same(-V: Data, d: Nat, +t: KV.Trie<V>, x: KV.Hex, +h: U32, +op: KV.Op<V>) -> {KV.bapply(V, op, KV.tget_h(V, d, t, x, h)) == KV.tget_h(V, d, KV.tmod_h(V, d, t, x, h, op), x, h) : KV.Trie<V>}:",
           "  match d t x:",
           "    case 0n t0 _:",
           "      {==}"]
    for i in range(N):
        out += [f"    case 1n++p {kv_node(cs)} {K[i]}:",
                f"      tget_tmod_same(V, p, {cs[i]}, {nxt('h')}, op)"]
    for pat in ["KV.Tip{}", "KV.Ent{a, b, e, c}"]:
        for i in range(N):
            out += [f"    case 1n++p {pat} {K[i]}:"] + tip_body
    return out

D = "dsame(p, KV.hex(KV.shr4(h1)), KV.shr4(h1), KV.hex(KV.shr4(h2)), KV.shr4(h2))"

def block_walk_same():
    out = ["# a step of walk_same: both walks take the digit x here",
           f"def walk_same_step(-V: Data, -p: Nat, +t: KV.Trie<V>, x: KV.Hex, +h1: U32, +h2: U32, ih: @u: KV.Trie<V> -> {{{D} == True{{}} : Bool}} -> {{KV.tget_h(V, p, u, {nxt('h1')}) == KV.tget_h(V, p, u, {nxt('h2')}) : KV.Trie<V>}}) -> {{{D} == True{{}} : Bool}} -> {{KV.tget_h(V, 1n+p, t, x, h1) == KV.tget_h(V, 1n+p, t, x, h2) : KV.Trie<V>}}:",
           "  match t x:"]
    for i in range(N):
        out += [f"    case {kv_node(cs)} {K[i]}:", f"      e => ih({cs[i]})(e)"]
    out += ["    case KV.Tip{} _:", "      e => {==}",
            "    case KV.Ent{a, b, x0, c} _:", "      e => {==}"]
    return out

def block_other():
    ih = (f"ih: @u: KV.Trie<V> -> {{{D} == False{{}} : Bool}} -> "
          f"{{KV.tget_h(V, p, KV.tmod_h(V, p, u, {nxt('h1')}, op), {nxt('h2')}) == KV.tget_h(V, p, u, {nxt('h2')}) : KV.Trie<V>}}")
    out = ["# a step of tget_tmod_other where the write and the read take the same",
           "# digit x here: they go to the same child",
           f"def same_digit_step(-V: Data, +p: Nat, +t: KV.Trie<V>, x: KV.Hex, +h1: U32, +h2: U32, +op: KV.Op<V>, {ih}) -> {{{D} == False{{}} : Bool}} -> {{KV.tget_h(V, 1n+p, KV.tmod_h(V, 1n+p, t, x, h1, op), x, h2) == KV.tget_h(V, 1n+p, t, x, h2) : KV.Trie<V>}}:",
           "  match t x:"]
    for i in range(N):
        out += [f"    case {kv_node(cs)} {K[i]}:", f"      e => ih({cs[i]})(e)"]
    m = f"KV.tget_h(V, p, KV.tmod_h(V, p, KV.Tip{{}}, {nxt('h1')}, op), {nxt('h2')})"
    for pat in ["KV.Tip{}", "KV.Ent{a, b, x0, c}"]:
        for i in range(N):
            out += [f"    case {pat} {K[i]}:",
                    f"      e => %tget_h_tip(V, p, {nxt('h2')}) : {{{m} == _ : KV.Trie<V>}}",
                    f"           ih(KV.Tip{{}})(e)"]
    tips = kv_node(kv_tips())
    out += ["", "# a write through an empty subtrie writes through a node of empty subtries",
            f"def n1_tip(-V: Data, -p: Nat, x: KV.Hex, -h: U32, -op: KV.Op<V>) -> {{KV.tmod_h(V, 1n+p, {tips}, x, h, op) == KV.tmod_h(V, 1n+p, KV.Tip{{}}, x, h, op) : KV.Trie<V>}}:",
            "  match x:"]
    for i in range(N):
        out += [f"    case {K[i]}:", "      {==}"]
    out += ["", f"def n1_ent(-V: Data, -p: Nat, -a: String, -b: V, -e: Nat, -c: KV.Trie<V>, x: KV.Hex, -h: U32, -op: KV.Op<V>) -> {{KV.tmod_h(V, 1n+p, {tips}, x, h, op) == KV.tmod_h(V, 1n+p, KV.Ent{{a, b, e, c}}, x, h, op) : KV.Trie<V>}}:",
            "  match x:"]
    for i in range(N):
        out += [f"    case {K[i]}:", "      {==}"]
    out += ["", "# a read through a node of empty subtries reads the empty bucket",
            f"def n2_tip(-V: Data, +p: Nat, x: KV.Hex, +h: U32) -> {{KV.tget_h(V, 1n+p, {tips}, x, h) == KV.Tip{{}} : KV.Trie<V>}}:",
            "  match x:"]
    for i in range(N):
        out += [f"    case {K[i]}:", f"      tget_h_tip(V, p, {nxt('h')})"]
    node = kv_node(cs)
    out += ["", "# a write through child x1 of a node leaves the read of child x2",
            "def upd_other_node(-V: Data, -p: Nat, " + fields(f"-{c}: KV.Trie<V>" for c in cs)
            + f", x1: KV.Hex, -h1: U32, x2: KV.Hex, -h2: U32, -op: KV.Op<V>) -> {{hex_eq(x1, x2) == False{{}} : Bool}} -> {{KV.tget_h(V, 1n+p, KV.tmod_h(V, 1n+p, {node}, x1, h1, op), x2, h2) == KV.tget_h(V, 1n+p, {node}, x2, h2) : KV.Trie<V>}}:",
            "  match x1 x2:"]
    for i in range(N):
        for j in range(N):
            out.append(f"    case {K[i]} {K[j]}:")
            if i == j:
                out.append(f"      e => Empty.absurd({{KV.tget_h(V, 1n+p, KV.tmod_h(V, 1n+p, {node}, {K[i]}, h1, op), {K[i]}, h2) == KV.tget_h(V, 1n+p, {node}, {K[i]}, h2) : KV.Trie<V>}}, true_false(e))")
            else:
                out.append("      e => {==}")
    return out

def block_del():
    tips = kv_node(kv_tips())
    a = [f"a{i}" for i in range(N)]
    b = [f"b{i}" for i in range(N)]
    # tnode keeps a node at its first child that is not empty: a case
    # for each such child, a node or an entry, so that tnode reduces
    out = ["# a node and the trie tnode makes of it read alike",
           "def tnode_read(-V: Data, +p: Nat, t: KV.Trie<V>, x: KV.Hex, +h: U32) -> {KV.tget_h(V, 1n+p, t, x, h) == KV.tget_h(V, 1n+p, KV.tnode(V, t), x, h) : KV.Trie<V>}:",
           "  match t:",
           f"    case {tips}:",
           "      n2_tip(V, p, x, h)"]
    for j in range(N):
        for pat in [kv_node([f"d{i}" for i in range(N)]), "KV.Ent{a, b, e, c}"]:
            out += [f"    case {kv_node(['KV.Tip{}'] * j + [pat] + cs[j + 1:])}:", "      {==}"]
    out += ["    case KV.Tip{}:", "      {==}", "    case KV.Ent{a, b, e, c}:", "      {==}"]
    es = [f"e{i}: @y: KV.Hex -> @g: U32 -> {{KV.tget_h(V, p, a{i}, y, g) == KV.tget_h(V, p, b{i}, y, g) : KV.Trie<V>}}"
          for i in range(N)]
    sig = ("(-V: Data, -p: Nat, " + fields(f"-{v}: KV.Trie<V>" for v in a + b)
           + ", x: KV.Hex, +h: U32, " + fields(es) + ")")
    out += ["", "# and the trie tnode_if makes of it",
            "def tnode_if_read(-V: Data, +p: Nat, z: Bool, t: KV.Trie<V>, x: KV.Hex, +h: U32) -> {KV.tget_h(V, 1n+p, t, x, h) == KV.tget_h(V, 1n+p, KV.tnode_if(V, z, t), x, h) : KV.Trie<V>}:",
            "  match z:",
            "    case True{}:",
            "      tnode_read(V, p, t, x, h)",
            "    case False{}:",
            "      {==}"]
    out += ["", "# two nodes whose children read alike read alike",
            f"def node_same{sig} -> {{KV.tget_h(V, 1n+p, {kv_node(a)}, x, h) == KV.tget_h(V, 1n+p, {kv_node(b)}, x, h) : KV.Trie<V>}}:",
            "  match x:"]
    for i in range(N):
        out += [f"    case {K[i]}:", f"      e{i}(KV.hex(KV.shr4(h)), KV.shr4(h))"]
    # tnode_read takes the second node: its children are not erased
    tsig = ("(-V: Data, +p: Nat, " + fields([f"-{v}: KV.Trie<V>" for v in a] + [f"{v}: KV.Trie<V>" for v in b])
            + ", z: Bool, +x: KV.Hex, +h: U32, " + fields(es) + ")")
    out += ["", "# and the trie tnode_if makes of the second",
            f"def tnode_same{tsig} -> {{KV.tget_h(V, 1n+p, {kv_node(a)}, x, h) == KV.tget_h(V, 1n+p, KV.tnode_if(V, z, {kv_node(b)}), x, h) : KV.Trie<V>}}:",
            f"  %tnode_if_read(V, p, z, {kv_node(b)}, x, h) : {{KV.tget_h(V, 1n+p, {kv_node(a)}, x, h) == _ : KV.Trie<V>}}",
            f"  node_same(V, p, {fields(a + b)}, x, h, {fields(f'e{i}' for i in range(N))})"]
    nx1 = nxt("h1")
    refl = "y => g => {==}"
    out += ["", "# a delete that takes the nodes it empties (tdel_h) reads as the walk",
            "# that deletes and keeps them (tmod_h with ODel), bucket by bucket",
            "def tdel_eq(-V: Data, d: Nat, +t: KV.Trie<V>, x1: KV.Hex, +h1: U32, +k: String, +x2: KV.Hex, +h2: U32) -> {KV.tget_h(V, d, KV.tmod_h(V, d, t, x1, h1, KV.ODel{k}), x2, h2) == KV.tget_h(V, d, KV.tdel_h(V, d, t, x1, h1, k), x2, h2) : KV.Trie<V>}:",
            "  match d t x1:",
            "    case 0n t0 _:",
            "      {==}"]
    for i in range(N):
        da = f"KV.tdel_h(V, p, {cs[i]}, {nx1}, k)"
        na = with_at(cs, i, da)
        nb = with_at(cs, i, f"KV.tmod_h(V, p, {cs[i]}, {nx1}, KV.ODel{{k}})")
        hs = with_at([refl] * N, i, f"y => g => tdel_eq(V, p, {cs[i]}, {nx1}, k, y, g)")
        out += [f"    case 1n++p {kv_node(['+' + c for c in cs])} {K[i]}:",
                f"      tnode_same(V, p, {fields(nb + na)}, KV.tis_tip(V, {da}), x2, h2, {fields(hs)})"]
    for pat in ["KV.Tip{}", "KV.Ent{a, b, e, c}"]:
        for i in range(N):
            out += [f"    case 1n++p {pat} {K[i]}:",
                    f"      del_tip(V, 1n+p, {K[i]}, h1, k, x2, h2)"]
    return out

def block_twice():
    hb = "hb: @b: KV.Trie<V> -> {KV.bapply(V, o2, KV.bapply(V, o1, b)) == KV.bapply(V, o2, b) : KV.Trie<V>}"
    out = ["# two writes along the same walk, where the second written over the",
           "# first is as the second alone on a bucket (hb): as the second alone",
           f"def tmod_twice(-V: Data, d: Nat, +t: KV.Trie<V>, x: KV.Hex, +h: U32, +o1: KV.Op<V>, +o2: KV.Op<V>, {hb}) -> {{KV.tmod_h(V, d, KV.tmod_h(V, d, t, x, h, o1), x, h, o2) == KV.tmod_h(V, d, t, x, h, o2) : KV.Trie<V>}}:",
           "  match d t x:",
           "    case 0n t0 _:",
           "      hb(t0)"]
    def step(i, c, around):
        a = f"KV.tmod_h(V, p, KV.tmod_h(V, p, {c}, {nxt('h')}, o1), {nxt('h')}, o2)"
        b = f"KV.tmod_h(V, p, {c}, {nxt('h')}, o2)"
        return (f"      Equal.cong(KV.Trie<V>, KV.Trie<V>, z => {kv_node(with_at(around, i, 'z'))}, {a}, {b}, "
                f"tmod_twice(V, p, {c}, {nxt('h')}, o1, o2, hb))")
    for i in range(N):
        out += [f"    case 1n++p {kv_node(cs)} {K[i]}:", step(i, cs[i], cs)]
    for pat in ["KV.Tip{}", "KV.Ent{a, b, e, c}"]:
        for i in range(N):
            out += [f"    case 1n++p {pat} {K[i]}:", step(i, "KV.Tip{}", kv_tips())]
    return out

BLOCKS = {"src/map.bend": {"types": block_types, "hex": block_hex,
                       "walks": block_walks, "folds": block_folds, "scan": block_scan},
          "proof/PROOF.bend": {"digits": block_digits, "tget_k": block_tget_k, "tget_kx": block_tget_kx,
                         "tget_ke": block_tget_ke, "tget_kl": block_tget_kl, "tget_kc": block_tget_kc,
                         "same": block_same, "walk_same": block_walk_same,
                         "other": block_other, "del": block_del, "twice": block_twice}}

def fill(path, blocks, check):
    text = path.read_text()
    for name, gen in blocks.items():
        pat = re.compile(r"(?ms)^(# BEGIN gen_trie: %s\n).*?^(# END gen_trie: %s\n)" % (name, name))
        if not pat.search(text):
            sys.exit(f"{path.name}: no block {name}")
        body = "\n".join(gen()) + "\n"
        text = pat.sub(lambda m: m.group(1) + body + m.group(2), text)
    if check:
        if text != path.read_text():
            sys.exit(f"{path.name} is out of date: run tools/gen_trie.py")
    else:
        path.write_text(text)

if __name__ == "__main__":
    for f, blocks in BLOCKS.items():
        fill(HERE / f, blocks, "--check" in sys.argv)
