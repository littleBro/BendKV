# sha.bend: FIPS 180-4's SHA-256 of a string's bytes, written as 64
# lowercase hex digits: what Redis keeps of a password (ACLHashPassword).
# The parser hashes AUTH's and HELLO's passwords as it reads them
# (redis.bend, parse_sess), and acl.bend the ones a user is given. A
# message goes in windows of 2,048 bytes, each of 32 blocks; its last
# bytes, with the padding and the length, make a string of one or two
# blocks of their own, so that the time is linear in the length.
import Base

type H8 is Data:
  H8{a: U32, b: U32, c: U32, d: U32, e: U32, f: U32, g: U32, h: U32}

def sha.h0() -> H8:
  H8{1779033703, 3144134277, 1013904242, 2773480762, 1359893119, 2600822924, 528734635, 1541459225}

def sha.rotr(+x: U32, +n: Nat) -> U32:
  U32.or(U32.shrn(x, n), U32.shln(x, Nat.sub(32n, n)))

def sha.bs0(+x: U32) -> U32:
  U32.xor(U32.xor(sha.rotr(x, 2n), sha.rotr(x, 13n)), sha.rotr(x, 22n))

def sha.bs1(+x: U32) -> U32:
  U32.xor(U32.xor(sha.rotr(x, 6n), sha.rotr(x, 11n)), sha.rotr(x, 25n))

def sha.ss0(+x: U32) -> U32:
  U32.xor(U32.xor(sha.rotr(x, 7n), sha.rotr(x, 18n)), U32.shrn(x, 3n))

def sha.ss1(+x: U32) -> U32:
  U32.xor(U32.xor(sha.rotr(x, 17n), sha.rotr(x, 19n)), U32.shrn(x, 10n))

def sha.ch(+e: U32, +f: U32, +g: U32) -> U32:
  U32.xor(U32.and(e, f), U32.and(U32.not(e), g))

def sha.maj(+a: U32, +b: U32, +c: U32) -> U32:
  U32.xor(U32.xor(U32.and(a, b), U32.and(a, c)), U32.and(b, c))

def sha.step(st: H8, +kw: U32) -> H8:
  match st:
    case H8{+a, +b, +c, d, +e, +f, +g, h}:
      +t1 = U32.add(U32.add(h, sha.bs1(e)), U32.add(sha.ch(e, f, g), kw))
      H8{U32.add(t1, U32.add(sha.bs0(a), sha.maj(a, b, c))), a, b, c, U32.add(d, t1), e, f, g}

def sha.add(x: H8, y: H8) -> H8:
  match x y:
    case H8{a0, b0, c0, d0, e0, f0, g0, h0} H8{a1, b1, c1, d1, e1, f1, g1, h1}:
      H8{U32.add(a0, a1), U32.add(b0, b1), U32.add(c0, c1), U32.add(d0, d1), U32.add(e0, e1), U32.add(f0, f1), U32.add(g0, g1), U32.add(h0, h1)}

# a block's schedule, sixteen words at a time, the oldest first
type W16 is Data:
  W16{w0: U32, w1: U32, w2: U32, w3: U32, w4: U32, w5: U32, w6: U32, w7: U32, w8: U32, w9: U32, w10: U32, w11: U32, w12: U32, w13: U32, w14: U32, w15: U32}

# the round constants, sixteen to a window, in order
def sha.k0() -> W16:
  W16{1116352408, 1899447441, 3049323471, 3921009573, 961987163, 1508970993, 2453635748, 2870763221, 3624381080, 310598401, 607225278, 1426881987, 1925078388, 2162078206, 2614888103, 3248222580}

def sha.k1() -> W16:
  W16{3835390401, 4022224774, 264347078, 604807628, 770255983, 1249150122, 1555081692, 1996064986, 2554220882, 2821834349, 2952996808, 3210313671, 3336571891, 3584528711, 113926993, 338241895}

def sha.k2() -> W16:
  W16{666307205, 773529912, 1294757372, 1396182291, 1695183700, 1986661051, 2177026350, 2456956037, 2730485921, 2820302411, 3259730800, 3345764771, 3516065817, 3600352804, 4094571909, 275423344}

def sha.k3() -> W16:
  W16{430227734, 506948616, 659060556, 883997877, 958139571, 1322822218, 1537002063, 1747873779, 1955562222, 2024104815, 2227730452, 2361852424, 2428436474, 2756734187, 3204031479, 3329325298}

# the window of sixteen words after w's (FIPS 180-4's schedule: a word
# from the words 2, 7, 15 and 16 before it)
def sha.expand(+w: W16) -> W16:
  match w:
    case W16{+o0, +o1, +o2, +o3, +o4, +o5, +o6, +o7, +o8, +o9, +o10, +o11, +o12, +o13, +o14, +o15}:
      +n0 = U32.add(U32.add(sha.ss1(o14), o9), U32.add(sha.ss0(o1), o0))
      +n1 = U32.add(U32.add(sha.ss1(o15), o10), U32.add(sha.ss0(o2), o1))
      +n2 = U32.add(U32.add(sha.ss1(n0), o11), U32.add(sha.ss0(o3), o2))
      +n3 = U32.add(U32.add(sha.ss1(n1), o12), U32.add(sha.ss0(o4), o3))
      +n4 = U32.add(U32.add(sha.ss1(n2), o13), U32.add(sha.ss0(o5), o4))
      +n5 = U32.add(U32.add(sha.ss1(n3), o14), U32.add(sha.ss0(o6), o5))
      +n6 = U32.add(U32.add(sha.ss1(n4), o15), U32.add(sha.ss0(o7), o6))
      +n7 = U32.add(U32.add(sha.ss1(n5), n0), U32.add(sha.ss0(o8), o7))
      +n8 = U32.add(U32.add(sha.ss1(n6), n1), U32.add(sha.ss0(o9), o8))
      +n9 = U32.add(U32.add(sha.ss1(n7), n2), U32.add(sha.ss0(o10), o9))
      +n10 = U32.add(U32.add(sha.ss1(n8), n3), U32.add(sha.ss0(o11), o10))
      +n11 = U32.add(U32.add(sha.ss1(n9), n4), U32.add(sha.ss0(o12), o11))
      +n12 = U32.add(U32.add(sha.ss1(n10), n5), U32.add(sha.ss0(o13), o12))
      +n13 = U32.add(U32.add(sha.ss1(n11), n6), U32.add(sha.ss0(o14), o13))
      +n14 = U32.add(U32.add(sha.ss1(n12), n7), U32.add(sha.ss0(o15), o14))
      +n15 = U32.add(U32.add(sha.ss1(n13), n8), U32.add(sha.ss0(n0), o15))
      W16{n0, n1, n2, n3, n4, n5, n6, n7, n8, n9, n10, n11, n12, n13, n14, n15}

# sixteen rounds over st, with a window of the constants and of the
# schedule
def sha.r16(st: H8, +k: W16, +w: W16) -> H8:
  match k w:
    case W16{k0, k1, k2, k3, k4, k5, k6, k7, k8, k9, k10, k11, k12, k13, k14, k15} W16{w0, w1, w2, w3, w4, w5, w6, w7, w8, w9, w10, w11, w12, w13, w14, w15}:
      sha.step(sha.step(sha.step(sha.step(sha.step(sha.step(sha.step(sha.step(sha.step(sha.step(sha.step(sha.step(sha.step(sha.step(sha.step(sha.step(st, U32.add(k0, w0)), U32.add(k1, w1)), U32.add(k2, w2)), U32.add(k3, w3)), U32.add(k4, w4)), U32.add(k5, w5)), U32.add(k6, w6)), U32.add(k7, w7)), U32.add(k8, w8)), U32.add(k9, w9)), U32.add(k10, w10)), U32.add(k11, w11)), U32.add(k12, w12)), U32.add(k13, w13)), U32.add(k14, w14)), U32.add(k15, w15))

# the big-endian word at byte i of s
def sha.word(+s: String, +i: Nat) -> U32:
  U32.or(U32.or(U32.shln(String.code_at(s, i), 24n), U32.shln(String.code_at(s, Nat.add(i, 1n)), 16n)),
    U32.or(U32.shln(String.code_at(s, Nat.add(i, 2n)), 8n), String.code_at(s, Nat.add(i, 3n))))

# the sixteen words of the block at byte i of s
def sha.read(+s: String, +i: Nat) -> W16:
  W16{sha.word(s, i), sha.word(s, Nat.add(i, 4n)), sha.word(s, Nat.add(i, 8n)), sha.word(s, Nat.add(i, 12n)), sha.word(s, Nat.add(i, 16n)), sha.word(s, Nat.add(i, 20n)), sha.word(s, Nat.add(i, 24n)), sha.word(s, Nat.add(i, 28n)), sha.word(s, Nat.add(i, 32n)), sha.word(s, Nat.add(i, 36n)), sha.word(s, Nat.add(i, 40n)), sha.word(s, Nat.add(i, 44n)), sha.word(s, Nat.add(i, 48n)), sha.word(s, Nat.add(i, 52n)), sha.word(s, Nat.add(i, 56n)), sha.word(s, Nat.add(i, 60n))}

# a block's 64 rounds over st, from its sixteen words w, added to st
def sha.block(st: H8, w: W16) -> H8:
  +h = st
  +w0 = w
  +w1 = sha.expand(w0)
  +w2 = sha.expand(w1)
  +w3 = sha.expand(w2)
  sha.add(h, sha.r16(sha.r16(sha.r16(sha.r16(h, sha.k0(), w0), sha.k1(), w1), sha.k2(), w2), sha.k3(), w3))

# the k blocks of s from byte i, over st
def sha.blocks(k: Nat, +s: String, +i: Nat, st: H8) -> H8:
  match k:
    case 0n:
      st
    case 1n+p:
      sha.blocks(p, s, Nat.add(i, 64n), sha.block(st, sha.read(s, i)))

# the blocks of the first n bytes of s (a multiple of 64) over st, a
# window of 2,048 bytes at a time: a window is one chunk, whose bytes
# String.code_at reads at once (a walk of s by its characters makes a
# view of each; f bounds the windows)
def sha.run(f: Nat, +s: String, +n: Nat, st: H8) -> H8:
  match f:
    case 0n:
      st
    case 1n+g:
      +k = Nat.min(n, 2048n)
      sha.run(g, String.drop(s, k), Nat.sub(n, k), sha.blocks(Nat.div(k, 64n), String.take(s, k), 0n, st))

# k zero bytes before rest
def sha.zeros(k: Nat, rest: String) -> String:
  match k:
    case 0n:
      rest
    case 1n+p:
      sha.zeros(p, SCon{Chr{0}, rest})

# the k low bytes of x, big-endian, before rest
def sha.len(k: Nat, +x: Nat, rest: String) -> String:
  match k:
    case 0n:
      rest
    case 1n+p:
      sha.len(p, Nat.div(x, 256n), SCon{Chr{U32.from_nat(Nat.mod(x, 256n))}, rest})

# the last r bytes of a message of n (t, fewer than 64) padded as FIPS
# 180-4 pads it: 0x80, zeros, and n in bits in eight bytes, big-endian,
# to the end of one block, or of two when the eight do not fit in one
def sha.tail(+t: String, +r: Nat, +n: Nat) -> String:
  t ++ SCon{Chr{128}, sha.zeros(Bool.pick(Nat, Nat.is_lt(r, 56n), Nat.sub(55n, r), Nat.sub(119n, r)), sha.len(8n, Nat.mul(n, 8n), SNil{}))}

def sha.digit(+d: U32) -> String:
  String.from_list([Chr{Bool.pick(U32, U32.is_lt(d, 10), U32.add(d, 48), U32.add(d, 87))}])

# the k lowest hex digits of x put before acc
def sha.hex(k: Nat, +x: U32, acc: String) -> String:
  match k:
    case 0n:
      acc
    case 1n+p:
      sha.hex(p, U32.shrn(x, 4n), sha.digit(U32.and(x, 15)) ++ acc)

def sha.out(st: H8) -> String:
  match st:
    case H8{a, b, c, d, e, f, g, h}:
      sha.hex(8n, a, sha.hex(8n, b, sha.hex(8n, c, sha.hex(8n, d, sha.hex(8n, e, sha.hex(8n, f, sha.hex(8n, g, sha.hex(8n, h, ""))))))))

# SHA-256 of s's bytes (each char a byte), as 64 lowercase hex digits:
# its whole blocks, then its last bytes padded, in time linear in its
# length
def sha256(+s: String) -> String:
  +n = String.length(s)
  +r = Nat.mod(n, 64n)
  +m = Nat.sub(n, r)
  +t = sha.tail(String.drop(s, m), r, n)
  sha.out(sha.blocks(Nat.div(String.length(t), 64n), t, 0n, sha.run(Nat.div(Nat.add(m, 2047n), 2048n), s, m, sha.h0())))
