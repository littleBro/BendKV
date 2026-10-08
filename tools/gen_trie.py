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
            "# the bucket of that path: a chain of Ent cells, each a key, its value",
            "# and the rest of the bucket, which ends in Tip. A Node inside a bucket",
            "# and an Ent above the end of a path are never built; they read as",
            "# empty.",
            "type Trie<-V: Data> is Data:",
            "  Tip{}",
            "  Node{" + fields(f"{c}: Trie<V>" for c in cs) + "}",
            "  Ent{key: String, val: V, rest: Trie<V>}"]
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
    out += ["# tget_k for String values, answering a copy of the value (bget_c)",
            "def tget_kc(d: Nat, t: Trie<String>, x: Hex, +h: U32, +k: String) -> Maybe<&2, String>:",
            "  match d t x:",
            "    case 0n t0 _:",
            "      bget_c(k, t0)"]
    for i in range(N):
        out += [f"    case 1n+p {node(cs)} {H[i]}{{}}:",
                f"      tget_kc(p, {cs[i]}, {STEP}, k)"]
    out += ["    case 1n+p other _:", "      None{}", ""]
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
    out += ["# the trie with op applied to the bucket where the walk ends. A node",
            "# that a delete leaves without entries stays: at most 69905 of them,",
            "# 9MB, for the 2^20 buckets.",
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
    return out

def block_folds():
    acc = "acc"
    for c in reversed(cs):
        acc = f"tkeys(V, {c}, {acc})"
    size = "0n"
    for c in reversed(cs):
        size = f"tsize(V, {c})" if size == "0n" else f"Nat.add(tsize(V, {c}), {size})"
    return ["def tkeys(-V: Data, t: Trie<V>, acc: List<&2, String>) -> List<&2, String>:",
            "  match t:",
            "    case Tip{}:",
            "      acc",
            f"    case {node(cs)}:",
            f"      {acc}",
            "    case Ent{k, v, rest}:",
            "      k <> tkeys(V, rest, acc)",
            "",
            "def tsize(-V: Data, t: Trie<V>) -> Nat:",
            "  match t:",
            "    case Tip{}:",
            "      0n",
            f"    case {node(cs)}:",
            f"      {size}",
            "    case Ent{k, v, rest}:",
            "      1n+tsize(V, rest)"]

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

def block_tget_k():
    out = ["# get walks with tget_k, which reads the bucket where the walk ends: the",
           "# bucket lookup after tget_h, by induction on the depth",
           "def tget_k_eq(-V: Data, d: Nat, t: KV.Trie<V>, x: KV.Hex, +h: U32, +k: String) -> {KV.bget(V, k, KV.tget_h(V, d, t, x, h)) == KV.tget_k(V, d, t, x, h, k) : Maybe<&2, V>}:",
           "  match d t x:",
           "    case 0n t0 _:",
           "      {==}"]
    for i in range(N):
        out += [f"    case 1n+p {kv_node(cs)} {K[i]}:",
                f"      tget_k_eq(V, p, {cs[i]}, {nxt('h')}, k)"]
    out += ["    case 1n+p KV.Tip{} _:", "      {==}",
            "    case 1n+p KV.Ent{a, b, c} _:", "      {==}"]
    return out

def block_tget_kc():
    out = ["# GET reads with tget_kc, which answers a copy of the value: the same",
           "# answer as tget_k (bget_c_eq), by induction on the depth",
           "def tget_kc_eq(d: Nat, t: KV.Trie<String>, x: KV.Hex, +h: U32, +k: String) -> {KV.tget_k(String, d, t, x, h, k) == KV.tget_kc(d, t, x, h, k) : Maybe<&2, String>}:",
           "  match d t x:",
           "    case 0n t0 _:",
           "      bget_c_eq(k, t0)"]
    for i in range(N):
        out += [f"    case 1n+p {kv_node(cs)} {K[i]}:",
                f"      tget_kc_eq(p, {cs[i]}, {nxt('h')}, k)"]
    out += ["    case 1n+p KV.Tip{} _:", "      {==}",
            "    case 1n+p KV.Ent{a, b, c} _:", "      {==}"]
    return out

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
    for pat in ["KV.Tip{}", "KV.Ent{a, b, c}"]:
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
            "    case KV.Ent{a, b, c} _:", "      e => {==}"]
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
    for pat in ["KV.Tip{}", "KV.Ent{a, b, c}"]:
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
    out += ["", f"def n1_ent(-V: Data, -p: Nat, -a: String, -b: V, -c: KV.Trie<V>, x: KV.Hex, -h: U32, -op: KV.Op<V>) -> {{KV.tmod_h(V, 1n+p, {tips}, x, h, op) == KV.tmod_h(V, 1n+p, KV.Ent{{a, b, c}}, x, h, op) : KV.Trie<V>}}:",
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

BLOCKS = {"src/map.bend": {"types": block_types, "hex": block_hex,
                       "walks": block_walks, "folds": block_folds},
          "proof/PROOF.bend": {"digits": block_digits, "tget_k": block_tget_k, "tget_kc": block_tget_kc,
                         "same": block_same, "walk_same": block_walk_same,
                         "other": block_other}}

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
