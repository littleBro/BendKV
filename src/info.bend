# info.bend: INFO, as Redis 7.0.15 writes it (genRedisInfoString in
# server.c): its sections, picked as Redis picks them, in Redis's order,
# each with Redis's fields in Redis's order. The values are BendKV's own
# where it has them: its process, its parameters, its counts of
# connections, commands and bytes, its memory, its keys, its append-only
# file, its evictions. For what it does not have (replication, forks,
# scripts, the eviction of clients, expiry, defragmentation, I/O threads)
# they are what Redis shows when it has none of it. Facts only the shell can see (the clock, the processor
# time, the memory, the connections) come in Live, gathered for a batch
# that asks for them; the counts are added a batch at a time, and the
# rates sampled every 100 ms (server.bend).

import Base
import ./map.bend as KV
import ./redis.bend as R
import ./config.bend as C
import ./float.bend as F

# Counts
# ------

# a count that may outgrow what a Nat holds (2^48): lo below 10^12, hi
# the number of 10^12s
type Big is Data:
  IBig{hi: Nat, lo: Nat}

def big.lim() -> Nat:
  Nat.mul(1000000n, 1000000n)

def big.zero() -> Big:
  IBig{0n, 0n}

def big.carry(over: Bool, hi: Nat, +lo: Nat) -> Big:
  match over:
    case False{}:
      IBig{hi, lo}
    case True{}:
      IBig{1n+hi, Nat.sub(lo, big.lim())}

def big.add(b: Big, +n: Nat) -> Big:
  match b:
    case IBig{hi, lo}:
      +s = Nat.add(lo, n)
      big.carry(Nat.is_le(big.lim(), s), hi, s)

def zeros(n: Nat) -> String:
  match n:
    case 0n:
      ""
    case 1n+m:
      "0" ++ zeros(m)

# s with zeros before it, to w digits
def pad(+s: String, +w: Nat) -> String:
  zeros(Nat.sub(w, String.length(s))) ++ s

def big.show.if(top: Bool, +hi: Nat, +lo: Nat) -> String:
  match top:
    case True{}:
      Nat.show(hi) ++ pad(Nat.show(lo), 12n)
    case False{}:
      Nat.show(lo)

def big.show(+b: Big) -> String:
  match b:
    case IBig{+hi, +lo}:
      big.show.if(Nat.is_lt(0n, hi), hi, lo)

# a - b for counts at most 10^12 apart
def big.diff(+a: Big, +b: Big) -> Nat:
  match a b:
    case IBig{ah, al} IBig{bh, bl}:
      Nat.sub(Nat.add(al, Nat.mul(Nat.sub(ah, bh), big.lim())), bl)

def big.is_zero(+b: Big) -> Bool:
  match b:
    case IBig{+hi, +lo}:
      Bool.and(Nat.is_eq(hi, 0n), Nat.is_eq(lo, 0n))

# Histograms
# ----------
# A command's latencies as Redis 7.0.15 keeps them (hdr_histogram, from
# 1 ns to 1 s with two significant digits: updateCommandLatencyHistogram):
# a count at each index of the values, where a value below 256 ns has an
# index of its own and each power of two above it (bucket b, from 1) is
# cut into 128 indexes of 2^b ns. The statistics keep a histogram as a
# trie of its counts by index (HT, below); its readers take its counts
# that are not 0, by index, the lowest first (HBin).

type HBin is Data:
  HBin{i: Nat, n: Nat}

# the index of a value of v ns (counts_index_for): 128 for each halving
# that brings it below 256, plus what is left (lo: whether v is below
# 256)
def hdr.at(fuel: Nat, lo: Bool, +v: Nat, +b: Nat) -> Nat:
  match fuel lo:
    case 1n+f False{}:
      +h = Nat.div(v, 2n)
      hdr.at(f, Nat.is_lt(h, 256n), h, 1n+b)
    case _ _:
      Nat.add(Nat.mul(b, 128n), v)

def hdr.idx(+v: Nat) -> Nat:
  hdr.at(24n, Nat.is_lt(v, 256n), v, 0n)

# the index of a call of d us: Redis records d * 1000 ns, within 1 ns and
# 1 s; a call of 0 or 1 us, the most common, needs no halving
def hdr.us.of(few: Bool, +d: Nat) -> Nat:
  match few:
    case True{}:
      Bool.pick(Nat, Nat.is_eq(d, 0n), 1n, 506n)
    case False{}:
      hdr.idx(Nat.min(Nat.mul(d, 1000n), 1000000000n))

def hdr.us(+d: Nat) -> Nat:
  hdr.us.of(Nat.is_lt(d, 2n), d)

# an index's bucket, the lowest value it counts (hdr_value_at_index) and
# the highest (highest_equivalent_value)
def hdr.b(+i: Nat) -> Nat:
  Nat.sub(Nat.div(i, 128n), 1n)

def hdr.low(+i: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_lt(i, 256n), i, Nat.mul(Nat.add(Nat.mod(i, 128n), 128n), F.nat.pow2(hdr.b(i))))

def hdr.high(+i: Nat) -> Nat:
  Nat.sub(Nat.add(hdr.low(i), F.nat.pow2(hdr.b(i))), 1n)

# the counts of a histogram's bins
def bins.total(bs: List<&2, HBin>, +acc: Nat) -> Nat:
  match bs:
    case Nil{}:
      acc
    case Con{HBin{i, +n}, rest}:
      bins.total(rest, Nat.add(acc, n))

# A histogram as the statistics keep it: its counts by index (0 to 4095),
# in a trie of four levels of 8 (the index's octal digits, the highest
# first), whose leaves hold the counts. A count added walks four nodes,
# each written in place when the statistics hold the only reference
# (Redis's hdr_histogram adds one to an array's cell); the readers take
# the counts as a list of bins, lowest index first (ht.bins).
type HT is Data:
  HT0{}
  HTC{n: Nat}
  HTN{c0: HT, c1: HT, c2: HT, c3: HT, c4: HT, c5: HT, c6: HT, c7: HT}

# the digit of index i that picks the child of a node of level l (4: the
# root, 1: a node of leaves): its l-th octal digit from the right
def ht.dig(+i: Nat, +l: Nat) -> Nat:
  U32.to_nat(U32.and(U32.shrn(U32.from_nat(i), Nat.mul(3n, Nat.sub(l, 1n))), 7))

# a node whose child at digit d is x, the others empty
def ht.path.at(d: Nat, x: HT) -> HT:
  match d:
    case 0n:
      HTN{x, HT0{}, HT0{}, HT0{}, HT0{}, HT0{}, HT0{}, HT0{}}
    case 1n:
      HTN{HT0{}, x, HT0{}, HT0{}, HT0{}, HT0{}, HT0{}, HT0{}}
    case 2n:
      HTN{HT0{}, HT0{}, x, HT0{}, HT0{}, HT0{}, HT0{}, HT0{}}
    case 3n:
      HTN{HT0{}, HT0{}, HT0{}, x, HT0{}, HT0{}, HT0{}, HT0{}}
    case 4n:
      HTN{HT0{}, HT0{}, HT0{}, HT0{}, x, HT0{}, HT0{}, HT0{}}
    case 5n:
      HTN{HT0{}, HT0{}, HT0{}, HT0{}, HT0{}, x, HT0{}, HT0{}}
    case 6n:
      HTN{HT0{}, HT0{}, HT0{}, HT0{}, HT0{}, HT0{}, x, HT0{}}
    case _:
      HTN{HT0{}, HT0{}, HT0{}, HT0{}, HT0{}, HT0{}, HT0{}, x}

# a new path of level l to a count of k at index i
def ht.path(l: Nat, +i: Nat, +k: Nat) -> HT:
  match l:
    case 0n:
      HTC{k}
    case 1n++m:
      ht.path.at(ht.dig(i, 1n+m), ht.path(m, i, k))

# k more at index i in t, a trie of level l (d: the digit of i at it)
def ht.add(t: HT, l: Nat, +d: Nat, +i: Nat, +k: Nat) -> HT:
  match t l d:
    case HTC{n} 0n _:
      HTC{Nat.add(n, k)}
    case _ 0n _:
      HTC{k}
    case HTN{c0, c1, c2, c3, c4, c5, c6, c7} 1n++m 0n:
      HTN{ht.add(c0, m, ht.dig(i, m), i, k), c1, c2, c3, c4, c5, c6, c7}
    case HTN{c0, c1, c2, c3, c4, c5, c6, c7} 1n++m 1n:
      HTN{c0, ht.add(c1, m, ht.dig(i, m), i, k), c2, c3, c4, c5, c6, c7}
    case HTN{c0, c1, c2, c3, c4, c5, c6, c7} 1n++m 2n:
      HTN{c0, c1, ht.add(c2, m, ht.dig(i, m), i, k), c3, c4, c5, c6, c7}
    case HTN{c0, c1, c2, c3, c4, c5, c6, c7} 1n++m 3n:
      HTN{c0, c1, c2, ht.add(c3, m, ht.dig(i, m), i, k), c4, c5, c6, c7}
    case HTN{c0, c1, c2, c3, c4, c5, c6, c7} 1n++m 4n:
      HTN{c0, c1, c2, c3, ht.add(c4, m, ht.dig(i, m), i, k), c5, c6, c7}
    case HTN{c0, c1, c2, c3, c4, c5, c6, c7} 1n++m 5n:
      HTN{c0, c1, c2, c3, c4, ht.add(c5, m, ht.dig(i, m), i, k), c6, c7}
    case HTN{c0, c1, c2, c3, c4, c5, c6, c7} 1n++m 6n:
      HTN{c0, c1, c2, c3, c4, c5, ht.add(c6, m, ht.dig(i, m), i, k), c7}
    case HTN{c0, c1, c2, c3, c4, c5, c6, c7} 1n++m _:
      HTN{c0, c1, c2, c3, c4, c5, c6, ht.add(c7, m, ht.dig(i, m), i, k)}
    case _ 1n++m 0n:
      HTN{ht.path(m, i, k), HT0{}, HT0{}, HT0{}, HT0{}, HT0{}, HT0{}, HT0{}}
    case _ 1n++m 1n:
      HTN{HT0{}, ht.path(m, i, k), HT0{}, HT0{}, HT0{}, HT0{}, HT0{}, HT0{}}
    case _ 1n++m 2n:
      HTN{HT0{}, HT0{}, ht.path(m, i, k), HT0{}, HT0{}, HT0{}, HT0{}, HT0{}}
    case _ 1n++m 3n:
      HTN{HT0{}, HT0{}, HT0{}, ht.path(m, i, k), HT0{}, HT0{}, HT0{}, HT0{}}
    case _ 1n++m 4n:
      HTN{HT0{}, HT0{}, HT0{}, HT0{}, ht.path(m, i, k), HT0{}, HT0{}, HT0{}}
    case _ 1n++m 5n:
      HTN{HT0{}, HT0{}, HT0{}, HT0{}, HT0{}, ht.path(m, i, k), HT0{}, HT0{}}
    case _ 1n++m 6n:
      HTN{HT0{}, HT0{}, HT0{}, HT0{}, HT0{}, HT0{}, ht.path(m, i, k), HT0{}}
    case _ 1n++m _:
      HTN{HT0{}, HT0{}, HT0{}, HT0{}, HT0{}, HT0{}, HT0{}, ht.path(m, i, k)}

# k more at index i
def ht.put(t: HT, +i: Nat, +k: Nat) -> HT:
  match k:
    case 0n:
      t
    case _:
      ht.add(t, 4n, ht.dig(i, 4n), i, k)

# the counts of a and b together
def ht.merge(a: HT, b: HT) -> HT:
  match a b:
    case HT0{} y:
      y
    case x HT0{}:
      x
    case HTC{x} HTC{y}:
      HTC{Nat.add(x, y)}
    case HTN{a0, a1, a2, a3, a4, a5, a6, a7} HTN{b0, b1, b2, b3, b4, b5, b6, b7}:
      HTN{ht.merge(a0, b0), ht.merge(a1, b1), ht.merge(a2, b2), ht.merge(a3, b3), ht.merge(a4, b4), ht.merge(a5, b5), ht.merge(a6, b6), ht.merge(a7, b7)}
    case x y:
      x

# the counts of t, a trie whose indexes start at base and are w of them,
# as bins, lowest index first, before acc
def ht.list(t: HT, +base: Nat, +w: Nat, acc: List<&2, HBin>) -> List<&2, HBin>:
  match t:
    case HT0{}:
      acc
    case HTC{n}:
      HBin{base, n} <> acc
    case HTN{c0, c1, c2, c3, c4, c5, c6, c7}:
      +v = Nat.div(w, 8n)
      ht.list(c0, base, v, ht.list(c1, Nat.add(base, Nat.mul(1n, v)), v, ht.list(c2, Nat.add(base, Nat.mul(2n, v)), v, ht.list(c3, Nat.add(base, Nat.mul(3n, v)), v, ht.list(c4, Nat.add(base, Nat.mul(4n, v)), v, ht.list(c5, Nat.add(base, Nat.mul(5n, v)), v, ht.list(c6, Nat.add(base, Nat.mul(6n, v)), v, ht.list(c7, Nat.add(base, Nat.mul(7n, v)), v, acc))))))))

def ht.bins(t: HT) -> List<&2, HBin>:
  ht.list(t, 0n, 4096n, Nil{})

def ht.some(+t: HT) -> Bool:
  match t:
    case HT0{}:
      False{}
    case _:
      True{}


# Statistics per command and per error
# ------------------------------------
# As Redis 7.0.15 keeps them: for each command and subcommand (by its key,
# R.stat.key), the calls that ran, the calls refused before they ran (a
# number of arguments its arity does not allow, a client that must
# authenticate first) and the calls that ran and answered an error; for each error code (the first
# word of an error reply, as afterErrorReply takes it), how many replies
# had it; and all the error replies. A batch puts its runs of calls
# (R.Tally) in the window of the actor's time it runs in (fresh); timed
# (Timing a window, below), they go with what their calls took to the
# runs not yet counted (cur, pend), which are counted in the entries,
# kept last used first, at the cron's tick (every 100 ms) and whenever
# INFO shows them, which lists them by name. Each entry also has the us
# its calls took (usec) and their histogram.

type Ent is Data:
  Ent{key: Nat, calls: Big, rej: Big, fail: Big, us: Big, h: HT}

type ErrN is Data:
  ErrN{code: String, n: Big}

# a run of calls (R.Tally's) not yet counted in the entries, with what its
# calls took (us) and their histogram. TRunOf, a run that holds a run, is
# never built: it makes TRun a node of its own, which Stats holds as one
# word (Info)
type TRun is Data:
  TRun{run: Nat, us: Nat, h: HT}
  TRunOf{t: TRun}

# where a call's arguments as its client sent them are: the n-th request
# of a batch's bytes, read only when the slow log needs them, or read
type Arg is Data:
  ArgRaw{raw: String, n: Nat}
  ArgList{xs: List<&2, String>}

# what a window of the actor's time saw, newest first (Timing a window,
# below): the run, or the runs (R.Tally's), of a batch of the fast way,
# whose requests are its calls, in order; a call of the general way, with
# its run (of one call, or of one refused) and the call it was named; the
# call of the general way about to run, which server.bend names before
# each (its client's id, its arguments, and whether it blocks: its
# client waits), until its run comes; a call that blocked, served, for
# the slow log (its client, its share, its code and arguments); a CONFIG
# RESETSTAT
type Fresh is Data:
  FRun{r: Nat}
  FRuns{rs: List<&2, Nat>}
  FCall{r: Nat, id: Nat, arg: Arg, blk: Bool}
  FNamed{id: Nat, arg: Arg, blk: Bool}
  FSlow{id: Nat, us: Nat, code: Nat, arg: Arg}
  FReset{}

# the entries, the window's runs and calls, the runs timed not yet
# counted (cur, pend), the error codes and all the error replies
type Stats is Data:
  Stats{ents: List<&2, Ent>, fresh: List<&2, Fresh>, cur: TRun, pend: List<&2, TRun>, errs: List<&2, ErrN>, total: Big}

def trun.zero() -> TRun:
  TRun{0n, 0n, HT0{}}

def stats.zero() -> Stats:
  Stats{Nil{}, Nil{}, trun.zero(), Nil{}, Nil{}, big.zero()}

def ent.add(e: Ent, +c: Nat, +r: Nat, +f: Nat, +u: Nat, h1: HT) -> Ent:
  match e:
    case Ent{k, calls, rej, fail, us, h}:
      Ent{k, big.add(calls, c), big.add(rej, r), big.add(fail, f), big.add(us, u), ht.merge(h1, h)}

def ent.is(+k: Nat, +es: List<&2, Ent>) -> Bool:
  match es:
    case Con{Ent{+j, calls, rej, fail, us, h}, rest}:
      Nat.is_eq(j, k)
    case Nil{}:
      False{}

# the entry of key k taken out of es, a new one when there is none; same
# says whether the first entry is k's
type Pick is Data:
  Pick{e: Ent, rest: List<&2, Ent>}

def pick.keep(e: Ent, p: Pick) -> Pick:
  match p:
    case Pick{x, rest}:
      Pick{x, e <> rest}

def ents.pick(+k: Nat, es: List<&2, Ent>, same: Bool) -> Pick:
  match es same:
    case Nil{} _:
      Pick{Ent{k, big.zero(), big.zero(), big.zero(), big.zero(), HT0{}}, Nil{}}
    case Con{e, rest} True{}:
      Pick{e, rest}
    case Con{e, +rest} False{}:
      pick.keep(e, ents.pick(k, rest, ent.is(k, rest)))

def ents.front(p: Pick, +c: Nat, +r: Nat, +f: Nat, +u: Nat, h: HT) -> List<&2, Ent>:
  match p:
    case Pick{e, rest}:
      ent.add(e, c, r, f, u, h) <> rest

# what calls of key k add: c that ran, r refused, f failed, the us they
# took and their histogram h; the entry goes first. A call of the last
# command used costs one comparison.
def ents.add.if(same: Bool, es: List<&2, Ent>, +k: Nat, +c: Nat, +r: Nat, +f: Nat, +u: Nat, h: HT) -> List<&2, Ent>:
  match same es:
    case True{} Con{e, rest}:
      ent.add(e, c, r, f, u, h) <> rest
    case _ _:
      ents.front(ents.pick(k, es, False{}), c, r, f, u, h)

def ents.add(+es: List<&2, Ent>, +k: Nat, +c: Nat, +r: Nat, +f: Nat, +u: Nat, h: HT) -> List<&2, Ent>:
  ents.add.if(ent.is(k, es), es, k, c, r, f, u, h)

# the error code of an error reply: its first word, when it ends in the
# first 31 bytes, else ERR (Redis looks for the space in "-" and the 31
# bytes after it)
def err.code(+m: String) -> String:
  +at = String.find(m, ' ', 0n)
  Bool.pick(String, Bool.and(Nat.is_lt(at, 31n), Nat.is_lt(at, String.length(m))), String.take(m, at), "ERR")

# where error code c goes among es: its own (EQ), before the first (LT,
# or the end), or after it (GT)
def errs.cmp(+c: String, +es: List<&2, ErrN>) -> Cmp:
  match es:
    case Con{ErrN{+x, n}, rest}:
      String.order(c, x)
    case Nil{}:
      LT{}

# one more reply with error code c (o is errs.cmp(c, es)); the codes are
# kept in order
def errs.add(es: List<&2, ErrN>, +c: String, o: Cmp) -> List<&2, ErrN>:
  match es o:
    case Con{ErrN{x, n}, rest} EQ{}:
      ErrN{x, big.add(n, 1n)} <> rest
    case Con{e, +rest} GT{}:
      e <> errs.add(rest, c, errs.cmp(c, rest))
    case _ _:
      ErrN{c, big.add(big.zero(), 1n)} <> es

# a run of calls (R.Tally) with the us they took and their histogram:
# its key's entry; key 0, an unknown command or subcommand, has none
def stats.run.at(es: List<&2, Ent>, +key: Nat, +class: Nat, +n: Nat, +u: Nat, h: HT) -> List<&2, Ent>:
  match class:
    case 0n:
      ents.add(es, key, n, 0n, 0n, u, h)
    case 1n:
      ents.add(es, key, 0n, n, 0n, u, h)
    case _:
      ents.add(es, key, n, 0n, n, u, h)

def stats.run.if(none: Bool, es: List<&2, Ent>, +code: Nat, +n: Nat, +u: Nat, h: HT) -> List<&2, Ent>:
  match none:
    case True{}:
      es
    case False{}:
      stats.run.at(es, R.code.key(code), R.code.class(code), n, u, h)

def stats.runs(ts: List<&2, TRun>, es: List<&2, Ent>) -> List<&2, Ent>:
  match ts:
    case Nil{}:
      es
    case Con{TRun{+r, +u, h}, rest}:
      +code = R.run.code(r)
      stats.runs(rest, stats.run.if(Nat.is_eq(R.code.key(code), 0n), es, code, R.run.n(r), u, h))
    case Con{TRunOf{t}, rest}:
      stats.runs(rest, es)

# an error reply of a call of code k: one more of its error code, and of
# all; a call that ran (class 0) failed with it (the parser's errors are
# counted with their runs)
def stats.err.ent(ran: Bool, es: List<&2, Ent>, +k: Nat) -> List<&2, Ent>:
  match ran:
    case True{}:
      ents.add(es, R.code.key(k), 0n, 0n, 1n, 0n, HT0{})
    case False{}:
      es

def stats.err(st: Stats, +k: Nat, +m: String) -> Stats:
  match st:
    case Stats{es, fresh, cur, pend, +errs, total}:
      +c = err.code(m)
      Stats{stats.err.ent(Bool.and(Nat.is_eq(R.code.class(k), 0n), Nat.is_lt(0n, R.code.key(k))), es, k), fresh, cur, pend, errs.add(errs, c, errs.cmp(c, errs)), big.add(total, 1n)}

def stats.failed(st: Stats, +k: Nat) -> Stats:
  match st:
    case Stats{es, fresh, cur, pend, errs, total}:
      Stats{ents.add(es, R.code.key(k), 0n, 0n, 1n, 0n, HT0{}), fresh, cur, pend, errs, total}

def stats.errs(xs: List<&2, R.Erred>, st: Stats) -> Stats:
  match xs:
    case Nil{}:
      st
    case Con{R.Erred{+k, +m}, rest}:
      stats.errs(rest, stats.err(st, k, m))

# a batch's runs of calls in the window (fresh, newest first): the run of
# a batch of one code (r, 0 for none: R.Tally), or the runs of any other
# batch (rs); a call of the general way that was named (FNamed) goes with
# its run (of one call)
def fresh.put(none: Bool, +r: Nat, fresh: List<&2, Fresh>) -> List<&2, Fresh>:
  match none:
    case True{}:
      fresh
    case False{}:
      FRun{r} <> fresh

def stats.add(st: Stats, +r: Nat, rs: List<&2, Nat>) -> Stats:
  match st rs:
    case Stats{es, Con{FNamed{id, arg, blk}, fresh}, cur, pend, errs, total} _:
      Stats{es, FCall{r, id, arg, blk} <> fresh, cur, pend, errs, total}
    case Stats{es, fresh, cur, pend, errs, total} Nil{}:
      Stats{es, fresh.put(Nat.is_lt(r, 1n), r, fresh), cur, pend, errs, total}
    case Stats{es, fresh, cur, pend, errs, total} _:
      Stats{es, FRuns{rs} <> fresh, cur, pend, errs, total}

# the call of the general way about to run: of the client of id, with
# arguments arg, in the place of one named that did not run
def stats.call(st: Stats, +id: Nat, arg: Arg) -> Stats:
  match st:
    case Stats{es, Con{FNamed{i, a, b}, fresh}, cur, pend, errs, total}:
      Stats{es, FNamed{id, arg, False{}} <> fresh, cur, pend, errs, total}
    case Stats{es, fresh, cur, pend, errs, total}:
      Stats{es, FNamed{id, arg, False{}} <> fresh, cur, pend, errs, total}

# the call about to be counted blocks: its client waits
def stats.blk(st: Stats) -> Stats:
  match st:
    case Stats{es, Con{FNamed{id, arg, b}, fresh}, cur, pend, errs, total}:
      Stats{es, FNamed{id, arg, True{}} <> fresh, cur, pend, errs, total}
    case other:
      other

# CONFIG RESETSTAT: the entries, the error codes and replies and the runs
# timed start again; the window keeps what it saw, the reset after it
# (its calls before it are timed, not counted)
def stats.reset(st: Stats) -> Stats:
  match st:
    case Stats{es, fresh, cur, pend, errs, total}:
      Stats{Nil{}, FReset{} <> fresh, trun.zero(), Nil{}, Nil{}, big.zero()}

# A window timed (Timing a window, below): it took d us, and each of its
# calls that ran (the refused ones do not run) takes an equal share: s =
# d / n, and one us more for d mod n of them. Its runs then go with those
# not yet counted: a run into the newest of them (cur) when it has its
# code, or else in its place, cur going before the others (pend).

# the calls of run r that ran
def run.ran(+r: Nat) -> Nat:
  R.code.calls(R.run.code(r), R.run.n(r))

def runs.ran(rs: List<&2, Nat>, +acc: Nat) -> Nat:
  match rs:
    case Nil{}:
      acc
    case Con{+r, rest}:
      runs.ran(rest, Nat.add(acc, run.ran(r)))

# the histogram of k calls of s us, x of them of s + 1, while
# latency-tracking is on (trk)
def trun.h.of(h: HT, +s: Nat, +k: Nat, +x: Nat) -> HT:
  match x:
    case 0n:
      ht.put(h, hdr.us(s), k)
    case _:
      ht.put(ht.put(h, hdr.us(s), Nat.sub(k, x)), hdr.us(1n+s), x)

# the histogram h with k calls of s us more, x of them of s + 1, while
# latency-tracking is on (trk)
def trun.h.at(trk: Bool, h: HT, +s: Nat, +k: Nat, +x: Nat) -> HT:
  match trk:
    case True{}:
      trun.h.of(h, s, k, x)
    case False{}:
      h

def trun.h(trk: Bool, +s: Nat, +k: Nat, +x: Nat) -> HT:
  trun.h.at(trk, HT0{}, s, k, x)

def trun.code(+t: TRun) -> Nat:
  match t:
    case TRun{+r, u, h}:
      R.run.code(r)
    case TRunOf{+t0}:
      trun.code(t0)

# b's calls, us and histogram added to a's (of the same code)
def trun.join(a: TRun, b: TRun) -> TRun:
  match a b:
    case TRun{r, u, h} TRun{+r2, u2, h2}:
      TRun{Nat.add(r, R.run.n(r2)), Nat.add(u, u2), ht.merge(h2, h)}
    case TRunOf{a0} b0:
      trun.join(a0, b0)
    case a0 TRunOf{b0}:
      trun.join(a0, b0)

def trun.put(same: Bool, t: TRun, cur: TRun, pend: List<&2, TRun>) -> TRun & List<&2, TRun>:
  match same:
    case True{}:
      (trun.join(cur, t), pend)
    case False{}:
      (t, cur <> pend)

def timed.put(+t: TRun, p: TRun & List<&2, TRun>) -> TRun & List<&2, TRun>:
  (cur, pend) = p
  +c = cur
  trun.put(Nat.is_eq(trun.code(c), trun.code(t)), t, c, pend)

# run r timed, its calls having taken u us (k of them s us each, x of
# them one more, for the histogram while latency-tracking is on, trk):
# into cur when it has cur's code, its counts added to cur's histogram,
# else in cur's place, cur going before the others (pend)
def timed.add(same: Bool, +r: Nat, +u: Nat, +trk: Bool, +s: Nat, +k: Nat, +x: Nat, cur: TRun, pend: List<&2, TRun>) -> TRun & List<&2, TRun>:
  match same cur:
    case True{} TRun{r0, u0, h0}:
      (TRun{Nat.add(r0, R.run.n(r)), Nat.add(u0, u), trun.h.at(trk, h0, s, k, x)}, pend)
    case True{} TRunOf{c0}:
      timed.add(True{}, r, u, trk, s, k, x, c0, pend)
    case False{} c:
      (TRun{r, u, trun.h(trk, s, k, x)}, c <> pend)

def timed.run(+r: Nat, +u: Nat, +trk: Bool, +s: Nat, +k: Nat, +x: Nat, p: TRun & List<&2, TRun>) -> TRun & List<&2, TRun>:
  (cur, pend) = p
  +c = cur
  timed.add(Nat.is_eq(trun.code(c), R.run.code(r)), r, u, trk, s, k, x, c, pend)

# runs not yet timed before acc, as runs that took no time
def truns.of(rs: List<&2, Nat>, acc: List<&2, TRun>) -> List<&2, TRun>:
  match rs:
    case Nil{}:
      acc
    case Con{r, rest}:
      TRun{r, 0n, HT0{}} <> truns.of(rest, acc)

# the window's runs since its CONFIG RESETSTAT, newest first, before acc,
# as runs that took no time
def fresh.truns(fs: List<&2, Fresh>, acc: List<&2, TRun>) -> List<&2, TRun>:
  match fs:
    case Nil{}:
      acc
    case Con{FRun{r}, rest}:
      TRun{r, 0n, HT0{}} <> fresh.truns(rest, acc)
    case Con{FRuns{rs}, rest}:
      truns.of(rs, fresh.truns(rest, acc))
    case Con{FCall{r, id, arg, blk}, rest}:
      TRun{r, 0n, HT0{}} <> fresh.truns(rest, acc)
    case Con{FNamed{id, arg, blk}, rest}:
      fresh.truns(rest, acc)
    case Con{FSlow{id, us, code, arg}, rest}:
      fresh.truns(rest, acc)
    case Con{FReset{}, rest}:
      acc

# the runs not yet counted, the ones of one code next to each other put
# together first (a run per batch, of one command most of the time)
def truns.merge.if(same: Bool, acc: List<&2, TRun>, t: TRun) -> List<&2, TRun>:
  match same acc:
    case True{} Con{a, rest}:
      trun.join(a, t) <> rest
    case _ _:
      t <> acc

def truns.merge.at(+acc: List<&2, TRun>, +t: TRun) -> List<&2, TRun>:
  match acc:
    case Con{+a, rest}:
      truns.merge.if(Nat.is_eq(trun.code(a), trun.code(t)), acc, t)
    case Nil{}:
      [t]

def truns.merge(ts: List<&2, TRun>, acc: List<&2, TRun>) -> List<&2, TRun>:
  match ts:
    case Nil{}:
      acc
    case Con{+t, rest}:
      truns.merge(rest, truns.merge.at(acc, t))

# the entries with the runs not yet counted in them (those of the window
# as runs that took no time)
def stats.view(+st: Stats) -> List<&2, Ent>:
  match st:
    case Stats{+es, +fresh, +cur, +pend, errs, total}:
      stats.runs(truns.merge(fresh.truns(fresh, cur <> pend), Nil{}), es)

# the runs timed counted in the entries but the newest (the cron's tick),
# which goes on taking the runs of its code (its histogram is not merged
# into its entry's at every tick); the window's wait for its timing
def stats.fold(st: Stats) -> Stats:
  match st:
    case Stats{es, fresh, cur, pend, errs, total}:
      Stats{stats.runs(truns.merge(pend, Nil{}), es), fresh, cur, Nil{}, errs, total}

# Commandstats and Errorstats, as INFO writes them
def ent.name(+e: Ent) -> String:
  match e:
    case Ent{+k, calls, rej, fail, us, h}:
      R.stat.name(k)

def ent.shown(+e: Ent) -> Bool:
  match e:
    case Ent{k, +calls, +rej, +fail, us, h}:
      Bool.not(Bool.and(big.is_zero(calls), Bool.and(big.is_zero(rej), big.is_zero(fail))))

# es in order of their names (an insertion sort: there are a few dozen);
# first says whether e goes before the first of es
def ent.first(+e: Ent, +es: List<&2, Ent>) -> Bool:
  match es:
    case Con{+x, rest}:
      String.is_le(ent.name(e), ent.name(x))
    case Nil{}:
      True{}

def ents.insert(+e: Ent, es: List<&2, Ent>, first: Bool) -> List<&2, Ent>:
  match es first:
    case Con{x, +rest} False{}:
      x <> ents.insert(e, rest, ent.first(e, rest))
    case _ _:
      e <> es

def ents.sort(es: List<&2, Ent>, +acc: List<&2, Ent>) -> List<&2, Ent>:
  match es:
    case Nil{}:
      acc
    case Con{+e, rest}:
      ents.sort(rest, ents.insert(e, acc, ent.first(e, acc)))

# a count past 2^48 (lo below 10^12) as limbs (float.bend), and as C's
# float
def big.limbs(+b: Big) -> List<&2, Nat>:
  match b:
    case IBig{+hi, +lo}:
      F.big.add(F.big.mul(F.big.of(hi), F.big.of(big.lim())), F.big.of(lo))

def big.float(+b: Big) -> F.Fl:
  F.fl.round(F.fmt.f(), False{}, big.limbs(b), F.fl.eb(), False{})

# usec_per_call: usec over calls, (float)usec / calls in C's float, as
# "%.2f" prints it; 0 with no call
def ent.per.if(none: Bool, +us: Big, +calls: Big) -> String:
  match none:
    case True{}:
      "0.00"
    case False{}:
      F.fl.show_fix(2n, F.fl.div(F.fmt.f(), big.float(us), big.float(calls)))

def ent.per(+us: Big, +calls: Big) -> String:
  ent.per.if(big.is_zero(calls), us, calls)

def ent.line.if(shown: Bool, +e: Ent) -> String:
  match shown e:
    case True{} Ent{+k, +calls, +rej, +fail, +us, h}:
      "cmdstat_" ++ R.stat.name(k) ++ ":calls=" ++ big.show(calls) ++ ",usec=" ++ big.show(us) ++ ",usec_per_call=" ++ ent.per(us, calls) ++ ",rejected_calls=" ++ big.show(rej) ++ ",failed_calls=" ++ big.show(fail) ++ "\r\n"
    case False{} _:
      ""

def ent.line(+e: Ent) -> String:
  ent.line.if(ent.shown(e), e)

def ents.lines(es: List<&2, Ent>) -> String:
  match es:
    case Nil{}:
      ""
    case Con{+e, rest}:
      ent.line(e) ++ ents.lines(rest)

def errs.lines(es: List<&2, ErrN>) -> String:
  match es:
    case Nil{}:
      ""
    case Con{ErrN{+c, +n}, rest}:
      "errorstat_" ++ c ++ ":count=" ++ big.show(n) ++ "\r\n" ++ errs.lines(rest)

def stats.cmds(+st: Stats) -> String:
  ents.lines(ents.sort(stats.view(st), Nil{}))

def stats.errors(+st: Stats) -> String:
  match st:
    case Stats{es, fresh, cur, pend, +errs, total}:
      errs.lines(errs)

def stats.total(+st: Stats) -> String:
  match st:
    case Stats{es, fresh, cur, pend, errs, +total}:
      big.show(total)

# Timing
# ------
# As Redis 7.0.15 times its calls (call() in server.c, slowlog.c and
# latency.c): what each call took goes to its command's usec and, while
# latency-tracking is on, its histogram (Statistics, above); a call that
# took slowlog-log-slower-than us or more goes to the slow log (SLOWLOG),
# with its arguments as its client sent them, its client's address and
# name; and one that took latency-monitor-threshold ms or more, when that
# is not 0, is a sample of the latency monitor's event "command", or
# "fast-command" for a command Redis flags fast (LATENCY). The shell times
# each batch as a whole (server.bend), and each call of a batch takes an
# equal share of its time.

# the timing's parameters, as the start and each CONFIG SET leave them:
# whether the slow log logs (slowlog-log-slower-than is not negative),
# from how many us on, how many entries it keeps (slowlog-max-len), the
# latency monitor's threshold in ms (latency-monitor-threshold; 0 for
# none) and whether calls go to their histograms (latency-tracking). A
# number past 10^14 is read as 10^14, which no call reaches.
type TCfg is Data:
  TCfg{son: Bool, slt: Nat, smax: Nat, lat: Nat, trk: Bool}

# an entry of the slow log: its id, when it was logged (s since 1970),
# what its call took (us), its arguments as Redis keeps them (32 at most,
# the last one then saying how many more there were; each of 128 bytes at
# most, then how many more it had), and its client's address and name
type SlowE is Data:
  SlowE{id: Nat, at: Nat, us: Nat, args: List<&2, String>, peer: String, name: String}

# the slow log: the id of its next entry, how many it holds, and its
# entries, newest first
type Slow is Data:
  Slow{next: Nat, n: Nat, es: List<&2, SlowE>}

# a sample of a latency event: its second (since 1970), and the highest
# latency of that second (ms)
type LatS is Data:
  LatS{t: Nat, ms: Nat}

# a latency event: its name, the highest latency it had since it came,
# and its last 160 samples (LATENCY_TS_LEN), newest first
type LatEv is Data:
  LatEv{name: String, max: Nat, ss: List<&2, LatS>}

# a call that blocked, kept while its client waits (Timing a window,
# below): the client's id, the call's code, its share of its window (us)
# and its arguments
type Wt is Data:
  Wt{id: Nat, code: Nat, us: Nat, arg: Arg}

# the timing's parameters, the slow log, the latency events, in the order
# they came (Redis keeps them in a hash table), and the calls that
# blocked, of clients that wait. TimOf, a timing that holds a timing, is
# never built: it makes Tim a node of its own, which Info holds as one
# word, read by a quiet window and written only by the others
type Tim is Data:
  Tim{cf: TCfg, slow: Slow, evs: List<&2, LatEv>, wt: List<&2, Wt>}
  TimOf{t: Tim}

def tcfg.son(+c: TCfg) -> Bool:
  match c:
    case TCfg{son, slt, smax, lat, trk}:
      son

def tcfg.slt(+c: TCfg) -> Nat:
  match c:
    case TCfg{son, slt, smax, lat, trk}:
      slt

def tcfg.smax(+c: TCfg) -> Nat:
  match c:
    case TCfg{son, slt, smax, lat, trk}:
      smax

def tcfg.lat(+c: TCfg) -> Nat:
  match c:
    case TCfg{son, slt, smax, lat, trk}:
      lat

def tcfg.trk(+c: TCfg) -> Bool:
  match c:
    case TCfg{son, slt, smax, lat, trk}:
      trk

def tim.num.of(long: Bool, +v: String) -> Nat:
  match long:
    case True{}:
      Nat.mul(1000000000n, 100000n)
    case False{}:
      C.dec.small(v, 0n)

def tim.num(+v: String) -> Nat:
  tim.num.of(Nat.is_lt(14n, String.length(v)), v)

def tcfg.slow(on: Bool, +v: String) -> Nat:
  match on:
    case True{}:
      tim.num(v)
    case False{}:
      0n

def tcfg.of(+items: List<&2, C.CItem>) -> TCfg:
  +sl = C.config.get_value(items, "slowlog-log-slower-than")
  +on = Bool.not(String.starts_with(sl, "-"))
  TCfg{on, tcfg.slow(on, sl), tim.num(C.config.get_value(items, "slowlog-max-len")), tim.num(C.config.get_value(items, "latency-monitor-threshold")), String.eq(C.config.get_value(items, "latency-tracking"), "yes")}

def tim.new() -> Tim:
  Tim{TCfg{True{}, 10000n, 128n, 0n, True{}}, Slow{0n, 0n, Nil{}}, Nil{}, Nil{}}

def tim.cf(+t: Tim) -> TCfg:
  match t:
    case Tim{cf, slow, evs, wt}:
      cf
    case TimOf{+x}:
      tim.cf(x)

def tim.evs(+t: Tim) -> List<&2, LatEv>:
  match t:
    case Tim{cf, slow, evs, wt}:
      evs
    case TimOf{+x}:
      tim.evs(x)

# an argument as the slow log keeps it: 128 bytes at most, then how many
# more it had
def slow.arg.if(long: Bool, +a: String, +n: Nat) -> String:
  match long:
    case True{}:
      String.take(a, 128n) ++ "... (" ++ Nat.show(Nat.sub(n, 128n)) ++ " more bytes)"
    case False{}:
      a

def slow.arg(+a: String) -> String:
  +n = String.length(a)
  slow.arg.if(Nat.is_lt(128n, n), a, n)

# the first k arguments, each as the slow log keeps it
def slow.map(xs: List<&2, String>, k: Nat) -> List<&2, String>:
  match xs k:
    case Con{+a, rest} 1n+m:
      slow.arg(a) <> slow.map(rest, m)
    case _ _:
      Nil{}

def slow.args.if(many: Bool, xs: List<&2, String>, +argc: Nat) -> List<&2, String>:
  match many:
    case True{}:
      List.append(&2, String, slow.map(xs, 31n), ["... (" ++ Nat.show(Nat.sub(argc, 31n)) ++ " more arguments)"])
    case False{}:
      slow.map(xs, 32n)

# the arguments of a call as an entry keeps them (slowlogCreateEntry): all
# of them when they are 32 at most, else the first 31 and how many more
def slow.args(+xs: List<&2, String>) -> List<&2, String>:
  +argc = List.length(&2, String, xs)
  slow.args.if(Nat.is_lt(32n, argc), xs, argc)

def slow.take(es: List<&2, SlowE>, k: Nat) -> List<&2, SlowE>:
  match es k:
    case Con{e, rest} 1n+m:
      e <> slow.take(rest, m)
    case _ _:
      Nil{}

def slow.n(+sl: Slow) -> Nat:
  match sl:
    case Slow{next, n, es}:
      n

def slow.cut(over: Bool, sl: Slow, +max: Nat) -> Slow:
  match over sl:
    case True{} Slow{next, n, es}:
      Slow{next, max, slow.take(es, max)}
    case False{} _:
      sl

# the log with max entries at most, its oldest dropped
def slow.trim(+sl: Slow, +max: Nat) -> Slow:
  slow.cut(Nat.is_lt(max, slow.n(sl)), sl, max)

# the parameters read again (the start, CONFIG SET); while the slow log
# logs, it is cut to slowlog-max-len, as Redis cuts it after each call
# (CONFIG SET's own: slowlogPushEntryIfNeeded)
def tim.cfg.of(on: Bool, +cf: TCfg, slow: Slow, evs: List<&2, LatEv>, wt: List<&2, Wt>) -> Tim:
  match on:
    case True{}:
      Tim{cf, slow.trim(slow, tcfg.smax(cf)), evs, wt}
    case False{}:
      Tim{cf, slow, evs, wt}

def tim.cfg(t: Tim, +items: List<&2, C.CItem>) -> Tim:
  match t:
    case Tim{cf, slow, evs, wt}:
      +c = tcfg.of(items)
      tim.cfg.of(tcfg.son(c), c, slow, evs, wt)
    case TimOf{x}:
      tim.cfg(x, items)

def slow.add(log: Bool, sl: Slow, +d: Nat, +at: Nat, +xs: List<&2, String>, +peer: String, +name: String) -> Slow:
  match log sl:
    case True{} Slow{+next, n, es}:
      Slow{1n+next, 1n+n, SlowE{next, at, d, slow.args(xs), peer, name} <> es}
    case False{} _:
      sl

def slow.push(on: Bool, sl: Slow, +cf: TCfg, +d: Nat, +at: Nat, +xs: List<&2, String>, +peer: String, +name: String) -> Slow:
  match on:
    case True{}:
      slow.trim(slow.add(Nat.is_le(tcfg.slt(cf), d), sl, d, at, xs, peer, name), tcfg.smax(cf))
    case False{}:
      sl

# a call that took d us, logged at at (s since 1970), with arguments xs,
# of the client of address peer named name: in the slow log when it logs
# and d is at least its threshold, the log then cut to slowlog-max-len
# (slowlogPushEntryIfNeeded, after each call)
def tim.slow(t: Tim, +d: Nat, +at: Nat, +xs: List<&2, String>, +peer: String, +name: String) -> Tim:
  match t:
    case Tim{+cf, slow, evs, wt}:
      Tim{cf, slow.push(tcfg.son(cf), slow, cf, d, at, xs, peer, name), evs, wt}
    case TimOf{x}:
      tim.slow(x, d, at, xs, peer, name)

# SLOWLOG RESET: no entry left; the ids go on
def tim.slow.reset(t: Tim) -> Tim:
  match t:
    case Tim{cf, Slow{next, n, es}, evs, wt}:
      Tim{cf, Slow{next, 0n, Nil{}}, evs, wt}
    case TimOf{x}:
      tim.slow.reset(x)

def lat.take(ss: List<&2, LatS>, k: Nat) -> List<&2, LatS>:
  match ss k:
    case Con{x, rest} 1n+m:
      x <> lat.take(rest, m)
    case _ _:
      Nil{}

# the second of the newest sample (0 for none), and its latency
def lat.t(+ss: List<&2, LatS>) -> Nat:
  match ss:
    case Con{LatS{+t, ms}, rest}:
      t
    case Nil{}:
      0n

def lat.ms(+ss: List<&2, LatS>) -> Nat:
  match ss:
    case Con{LatS{t, +ms}, rest}:
      ms
    case Nil{}:
      0n

# a sample of ms at second now: the newest's when it is of that second
# (old: it is), the highest of the two, else a new one, the 160 newest
# kept
def lat.sample(old: Bool, ss: List<&2, LatS>, +ms: Nat, +now: Nat) -> List<&2, LatS>:
  match old ss:
    case True{} Con{LatS{t, m}, rest}:
      LatS{t, Nat.max(m, ms)} <> rest
    case _ _:
      LatS{now, ms} <> lat.take(ss, 159n)

def lat.ev.add(e: LatEv, +ms: Nat, +now: Nat) -> LatEv:
  match e:
    case LatEv{name, max, +ss}:
      LatEv{name, Nat.max(max, ms), lat.sample(Nat.is_eq(lat.t(ss), now), ss, ms, now)}

# whether the first of evs is event name
def lat.is(+name: String, +evs: List<&2, LatEv>) -> Bool:
  match evs:
    case Con{LatEv{+n, max, ss}, rest}:
      String.eq(n, name)
    case Nil{}:
      False{}

# a sample of event name in the events (hit: whether the first is it): its
# own, or a new event's after the others (latencyAddSample)
def lat.add(evs: List<&2, LatEv>, hit: Bool, +name: String, +ms: Nat, +now: Nat) -> List<&2, LatEv>:
  match evs hit:
    case Con{e, rest} True{}:
      lat.ev.add(e, ms, now) <> rest
    case Con{e, +rest} False{}:
      e <> lat.add(rest, lat.is(name, rest), name, ms, now)
    case Nil{} _:
      [lat.ev.add(LatEv{name, 0n, Nil{}}, ms, now)]

def tim.lat.if(on: Bool, t: Tim, +name: String, +ms: Nat, +now: Nat) -> Tim:
  match on t:
    case True{} Tim{cf, slow, +evs, wt}:
      Tim{cf, slow, lat.add(evs, lat.is(name, evs), name, ms, now), wt}
    case True{} TimOf{x}:
      tim.lat.if(True{}, x, name, ms, now)
    case False{} _:
      t

# a latency of ms of event name at second now, a sample when the monitor
# is on and ms reaches its threshold (latencyAddSampleIfNeeded)
def tim.lat(+t: Tim, +name: String, +ms: Nat, +now: Nat) -> Tim:
  +th = tcfg.lat(tim.cf(t))
  tim.lat.if(Bool.and(Nat.is_lt(0n, th), Nat.is_le(th, ms)), t, name, ms, now)

# LATENCY RESET: the events of a name, case aside, dropped
def lat.hit(+name: String, +e: LatEv) -> Bool:
  match e:
    case LatEv{+n, max, ss}:
      C.text.same(n, name)

def lat.hit1(+name: String, +evs: List<&2, LatEv>) -> Bool:
  match evs:
    case Con{+e, rest}:
      lat.hit(name, e)
    case Nil{}:
      False{}

# the events but those of name (hit: whether the first is one)
def lat.keep(evs: List<&2, LatEv>, hit: Bool, +name: String) -> List<&2, LatEv>:
  match evs hit:
    case Con{e, +rest} True{}:
      lat.keep(rest, lat.hit1(name, rest), name)
    case Con{e, +rest} False{}:
      e <> lat.keep(rest, lat.hit1(name, rest), name)
    case Nil{} _:
      Nil{}

def lat.count(evs: List<&2, LatEv>, +name: String, +n: Nat) -> Nat:
  match evs:
    case Nil{}:
      n
    case Con{+e, rest}:
      lat.count(rest, name, Bool.pick(Nat, lat.hit(name, e), 1n+n, n))

# the events after LATENCY RESET of names (each in turn), and how many it
# dropped
def lat.resets(names: List<&2, String>, evs: List<&2, LatEv>, +n: Nat) -> List<&2, LatEv> & Nat:
  match names:
    case Nil{}:
      (evs, n)
    case Con{+x, rest}:
      +e = evs
      lat.resets(rest, lat.keep(e, lat.hit1(x, e), x), lat.count(e, x, n))

# LATENCY RESET [event ...]: all events dropped with no name
def lat.reset.of(evs: List<&2, LatEv>, names: List<&2, String>) -> List<&2, LatEv> & Nat:
  match names:
    case Nil{}:
      +e = evs
      (Nil{}, List.length(&2, LatEv, e))
    case Con{x, rest}:
      lat.resets(Con{x, rest}, evs, 0n)

def tim.lat.reset.of(cf: TCfg, slow: Slow, p: List<&2, LatEv> & Nat, wt: List<&2, Wt>) -> Tim:
  (evs, n) = p
  Tim{cf, slow, evs, wt}

def tim.lat.reset(t: Tim, names: List<&2, String>) -> Tim:
  match t:
    case Tim{cf, slow, evs, wt}:
      tim.lat.reset.of(cf, slow, lat.reset.of(evs, names), wt)
    case TimOf{x}:
      tim.lat.reset(x, names)

def lat.reset.n(p: List<&2, LatEv> & Nat) -> Nat:
  (evs, n) = p
  n

# Timing a window
# ---------------
# The actor reads the clock after each batch it runs, after the end of a
# group and after each other request it takes (server.bend): what the
# window since its last reading took (d us) is shared by the calls that
# ran in it, each an equal share: s = d / n, and one us more for the
# first d mod n. A batch of one command, as a client without a pipeline
# sends, is timed as Redis times it; the calls of a pipeline share its
# time.
#
# A call's share goes to its command's usec and, while latency-tracking
# is on, its histogram (Statistics); to the slow log while it logs, when
# the share reaches slowlog-log-slower-than (EXEC aside: Redis's
# CMD_SKIP_SLOWLOG), with the call's arguments (a run of the fast way's:
# the requests of its batch's bytes, in order) and its client, which the
# shell completes (SlowJ); and to the latency monitor, while it is on, as
# a sample of "fast-command" or "command" (Redis's CMD_FAST) when the
# share's ms reach latency-monitor-threshold. Redis does each of these in
# call(), with each call timed on its own.
#
# A call that blocked has its share in usec only, as Redis's call()
# counts a call that blocks; the share is kept with its client (Wt), and
# when the client is served, or CLIENT UNBLOCK unblocks it, it goes to
# usec again, to the histogram and to the slow log, as Redis's
# updateStatsOnUnblock adds the call's c->duration (the reply's own time,
# which Redis adds too, is the window's that served it). A client whose
# time is up keeps its share until it blocks again or is gone. The calls
# of a window before a CONFIG RESETSTAT in it are timed for the slow log
# and the latency monitor, not counted.

# an entry the slow log takes from a window, for the shell to complete
# (server.bend: the client's address and name, the arguments read and
# redacted): its client's id, what its call took (us), its code and where
# its arguments are
type SlowJ is Data:
  SlowJ{id: Nat, us: Nat, code: Nat, arg: Arg}

# a window's timing as it goes: the runs timed (cur, pend: Statistics),
# the calls that blocked (wt), the slow log's entries (js, newest first),
# the shares of one us more left (x), the request of the batch's bytes
# that the next run of the fast way starts at (pos), and the highest
# share of a fast command and of another (for the latency monitor). WinOf,
# a window that holds a window, is never built: it makes Win a node of
# its own, which a function takes as one word.
type Win is Data:
  Win{cur: TRun, pend: List<&2, TRun>, wt: List<&2, Wt>, js: List<&2, SlowJ>, x: Nat, pos: Nat, fast: Nat, slow: Nat}
  WinOf{w: Win}

# the calls of the window that ran
def fresh.ran(fs: List<&2, Fresh>, +acc: Nat) -> Nat:
  match fs:
    case Nil{}:
      acc
    case Con{FRun{+r}, rest}:
      fresh.ran(rest, Nat.add(acc, run.ran(r)))
    case Con{FRuns{+rs}, rest}:
      fresh.ran(rest, runs.ran(rs, acc))
    case Con{FCall{+r, id, arg, blk}, rest}:
      fresh.ran(rest, Nat.add(acc, run.ran(r)))
    case Con{FNamed{id, arg, blk}, rest}:
      fresh.ran(rest, acc)
    case Con{FSlow{id, us, code, arg}, rest}:
      fresh.ran(rest, acc)
    case Con{FReset{}, rest}:
      fresh.ran(rest, acc)

# the window's entries since its newest CONFIG RESETSTAT, oldest first
# (acc), and those before it, newest first
type Split is Data:
  Split{new: List<&2, Fresh>, old: List<&2, Fresh>}

def fresh.split(fs: List<&2, Fresh>, acc: List<&2, Fresh>) -> Split:
  match fs:
    case Nil{}:
      Split{acc, Nil{}}
    case Con{FReset{}, rest}:
      Split{acc, rest}
    case Con{FRun{r}, rest}:
      fresh.split(rest, FRun{r} <> acc)
    case Con{FRuns{rs}, rest}:
      fresh.split(rest, FRuns{rs} <> acc)
    case Con{FCall{r, id, arg, blk}, rest}:
      fresh.split(rest, FCall{r, id, arg, blk} <> acc)
    case Con{FNamed{id, arg, blk}, rest}:
      fresh.split(rest, acc)
    case Con{FSlow{id, us, code, arg}, rest}:
      fresh.split(rest, FSlow{id, us, code, arg} <> acc)

# whether the first of the calls that blocked is client id's
def wt.is(+id: Nat, +ws: List<&2, Wt>) -> Bool:
  match ws:
    case Con{Wt{+j, code, us, arg}, rest}:
      Nat.is_eq(j, id)
    case Nil{}:
      False{}

# the calls that blocked but client id's (hit: whether the first is it);
# a client has one at most
def wt.drop(ws: List<&2, Wt>, hit: Bool, +id: Nat) -> List<&2, Wt>:
  match ws hit:
    case Con{w, rest} True{}:
      rest
    case Con{w, +rest} False{}:
      w <> wt.drop(rest, wt.is(id, rest), id)
    case Nil{} _:
      Nil{}

def wt.del(+ws: List<&2, Wt>, +id: Nat) -> List<&2, Wt>:
  wt.drop(ws, wt.is(id, ws), id)

# client id's call that blocked, if it has one (hit: whether the first
# is it)
def wt.find(ws: List<&2, Wt>, hit: Bool, +id: Nat) -> Maybe<&2, Wt>:
  match ws hit:
    case Con{w, rest} True{}:
      Some{w}
    case Con{w, +rest} False{}:
      wt.find(rest, wt.is(id, rest), id)
    case Nil{} _:
      None{}

def wt.get(+ws: List<&2, Wt>, +id: Nat) -> Maybe<&2, Wt>:
  wt.find(ws, wt.is(id, ws), id)

# a run timed into the window: with the runs timed when it counts (cnt:
# it came after the window's CONFIG RESETSTAT)
def win.of(p: TRun & List<&2, TRun>, wt: List<&2, Wt>, js: List<&2, SlowJ>, +x: Nat, +pos: Nat, +fast: Nat, +slow: Nat) -> Win:
  (cur, pend) = p
  Win{cur, pend, wt, js, x, pos, fast, slow}

def win.put(cnt: Bool, +t: TRun, cur: TRun, pend: List<&2, TRun>, wt: List<&2, Wt>, js: List<&2, SlowJ>, +x: Nat, +pos: Nat, +fast: Nat, +slow: Nat) -> Win:
  match cnt:
    case True{}:
      win.of(timed.put(t, (cur, pend)), wt, js, x, pos, fast, slow)
    case False{}:
      Win{cur, pend, wt, js, x, pos, fast, slow}

# the slow log's entries of j calls of code k of the fast way, from the
# i-th, the first m of s + 1 us, the others of s: the requests of raw from
# pos + i
def jobs.run(j: Nat, +i: Nat, +m: Nat, +s: Nat, +id: Nat, +k: Nat, +raw: String, +pos: Nat, js: List<&2, SlowJ>) -> List<&2, SlowJ>:
  match j:
    case 0n:
      js
    case 1n+h:
      jobs.run(h, 1n+i, m, s, id, k, raw, pos, SlowJ{id, Bool.pick(Nat, Nat.is_lt(i, m), 1n+s, s), k, ArgRaw{raw, Nat.add(pos, i)}} <> js)

# how many of n calls, the first m of s + 1 us, the others of s, the slow
# log takes (on: whether it logs their command), from the first
def jobs.n(+on: Bool, +slt: Nat, +s: Nat, +m: Nat, +n: Nat) -> Nat:
  Bool.pick(Nat, on, Bool.pick(Nat, Nat.is_le(slt, s), n, Bool.pick(Nat, Nat.is_le(slt, 1n+s), m, 0n)), 0n)

# the highest of the shares a command's calls took, by whether it is fast
def win.fast(+fa: Bool, +top: Nat, +fast: Nat) -> Nat:
  Bool.pick(Nat, fa, Nat.max(fast, top), fast)

def win.slow(+fa: Bool, +top: Nat, +slow: Nat) -> Nat:
  Bool.pick(Nat, fa, slow, Nat.max(slow, top))

# a run r of the fast way timed, s us each call, the first x left of
# them s + 1 (Win), from the request at pos of the batch's bytes (raw,
# the client id's) on; while the slow log logs (son), the calls of slt us
# or more go to it
def win.run(+cnt: Bool, +r: Nat, +s: Nat, +trk: Bool, +son: Bool, +slt: Nat, +id: Nat, +raw: String, w: Win) -> Win:
  match w:
    case Win{cur, pend, wt, js, +x, +pos, fast, slow}:
      +k = run.ran(r)
      +m = Nat.min(x, k)
      +code = R.run.code(r)
      +key = R.code.key(code)
      +fa = R.stat.fast(key)
      +top = Nat.add(Nat.mul(Nat.min(k, 1n), s), Nat.min(m, 1n))
      win.put(cnt, TRun{r, Nat.add(Nat.mul(k, s), m), trun.h(Bool.and(cnt, trk), s, k, m)}, cur, pend, wt, jobs.run(jobs.n(Bool.and(son, Bool.not(R.stat.noslow(key))), slt, s, m, k), 0n, m, s, id, code, raw, pos, js), Nat.sub(x, m), Nat.add(pos, R.run.n(r)), win.fast(fa, top, fast), win.slow(fa, top, slow))
    case WinOf{w0}:
      win.run(cnt, r, s, trk, son, slt, id, raw, w0)

# the runs of a batch of the fast way, oldest first
def win.runs(rs: List<&2, Nat>, +cnt: Bool, +s: Nat, +trk: Bool, +son: Bool, +slt: Nat, +id: Nat, +raw: String, w: Win) -> Win:
  match rs:
    case Nil{}:
      w
    case Con{+r, rest}:
      win.runs(rest, cnt, s, trk, son, slt, id, raw, win.run(cnt, r, s, trk, son, slt, id, raw, w))

# the calls that blocked, with client id's (its share us, its code and
# arguments) in place of any it had, when its call blocked (blk)
def win.wt(blk: Bool, +id: Nat, +code: Nat, +us: Nat, arg: Arg, ws: List<&2, Wt>) -> List<&2, Wt>:
  match blk:
    case True{}:
      Wt{id, code, us, arg} <> wt.del(ws, id)
    case False{}:
      ws

def win.job(log: Bool, +id: Nat, +us: Nat, +code: Nat, arg: Arg, js: List<&2, SlowJ>) -> List<&2, SlowJ>:
  match log:
    case True{}:
      SlowJ{id, us, code, arg} <> js
    case False{}:
      js

# a call of the general way (run r, of one call or of one refused) timed,
# of client id, with arguments arg: a call that blocked (blk) has its
# share in usec only, kept with its client
def win.call(+cnt: Bool, +r: Nat, +id: Nat, +arg: Arg, +blk: Bool, +s: Nat, +trk: Bool, +son: Bool, +slt: Nat, w: Win) -> Win:
  match w:
    case Win{cur, pend, wt, js, +x, pos, fast, slow}:
      +k = run.ran(r)
      +m = Nat.min(x, k)
      +us = Nat.add(Nat.mul(k, s), m)
      +code = R.run.code(r)
      +key = R.code.key(code)
      +fa = R.stat.fast(key)
      +log = Bool.and(Bool.and(son, Bool.not(blk)), Bool.and(Nat.is_lt(0n, k), Bool.and(Nat.is_le(slt, us), Bool.not(R.stat.noslow(key)))))
      win.put(cnt, TRun{r, us, trun.h(Bool.and(cnt, Bool.and(trk, Bool.not(blk))), s, k, m)}, cur, pend, win.wt(blk, id, code, us, arg, wt), win.job(log, id, us, code, arg, js), Nat.sub(x, m), pos, win.fast(fa, us, fast), win.slow(fa, us, slow))
    case WinOf{w0}:
      win.call(cnt, r, id, arg, blk, s, trk, son, slt, w0)

# a call that blocked, served: its entry for the slow log, as it was
# found when it was served
def win.served(+id: Nat, +us: Nat, +code: Nat, arg: Arg, w: Win) -> Win:
  match w:
    case Win{cur, pend, wt, js, x, pos, fast, slow}:
      Win{cur, pend, wt, SlowJ{id, us, code, arg} <> js, x, pos, fast, slow}
    case WinOf{w0}:
      win.served(id, us, code, arg, w0)

# the window's entries, oldest first, timed (cnt: whether they count)
def win.go(fs: List<&2, Fresh>, +cnt: Bool, +s: Nat, +trk: Bool, +son: Bool, +slt: Nat, +id: Nat, +raw: String, w: Win) -> Win:
  match fs:
    case Nil{}:
      w
    case Con{FRun{+r}, rest}:
      win.go(rest, cnt, s, trk, son, slt, id, raw, win.run(cnt, r, s, trk, son, slt, id, raw, w))
    case Con{FRuns{rs}, rest}:
      win.go(rest, cnt, s, trk, son, slt, id, raw, win.runs(List.reverse(&2, Nat, rs), cnt, s, trk, son, slt, id, raw, w))
    case Con{FCall{+r, +i, arg, +blk}, rest}:
      win.go(rest, cnt, s, trk, son, slt, id, raw, win.call(cnt, r, i, arg, blk, s, trk, son, slt, w))
    case Con{FNamed{i, arg, blk}, rest}:
      win.go(rest, cnt, s, trk, son, slt, id, raw, w)
    case Con{FSlow{+i, +us, +code, arg}, rest}:
      win.go(rest, cnt, s, trk, son, slt, id, raw, win.served(i, us, code, arg, w))
    case Con{FReset{}, rest}:
      win.go(rest, cnt, s, trk, son, slt, id, raw, w)

# the window's entries timed: those before its newest CONFIG RESETSTAT
# first, not counted, then those after it
def win.both(p: Split, +s: Nat, +trk: Bool, +son: Bool, +slt: Nat, +id: Nat, +raw: String, w: Win) -> Win:
  match p:
    case Split{new, old}:
      win.go(new, True{}, s, trk, son, slt, id, raw, win.go(List.reverse(&2, Fresh, old), False{}, s, trk, son, slt, id, raw, w))

# the window timed: the statistics with its runs timed, and none left in
# it
def win.stats(es: List<&2, Ent>, errs: List<&2, ErrN>, total: Big, +w: Win) -> Stats:
  match w:
    case Win{+cur, +pend, wt, js, x, pos, fast, slow}:
      Stats{es, Nil{}, cur, pend, errs, total}
    case WinOf{+w0}:
      win.stats(es, errs, total, w0)

# a latency monitor's sample of the highest share of each kind of
# command (each of its calls is one, and a second keeps its highest)
def win.lat(t: Tim, +fast: Nat, +slow: Nat, +now: Nat) -> Tim:
  tim.lat(tim.lat(t, "fast-command", Nat.div(fast, 1000n), now), "command", Nat.div(slow, 1000n), now)

def win.tim.if(on: Bool, t: Tim, +fast: Nat, +slow: Nat, +now: Nat) -> Tim:
  match on:
    case True{}:
      win.lat(t, fast, slow, now)
    case False{}:
      t

# the timing's state after the window (now: its end, in s since 1970)
def win.tim(cf: TCfg, slow: Slow, evs: List<&2, LatEv>, +now: Nat, +w: Win) -> Tim:
  match w:
    case Win{cur, pend, +wt, js, x, pos, +fast, +sl}:
      +c = cf
      win.tim.if(Nat.is_lt(0n, tcfg.lat(c)), Tim{c, slow, evs, wt}, fast, sl, now)
    case WinOf{+w0}:
      win.tim(cf, slow, evs, now, w0)

# the slow log's entries of the window, oldest first
def win.js(+w: Win) -> List<&2, SlowJ>:
  match w:
    case Win{cur, pend, wt, +js, x, pos, fast, slow}:
      List.reverse(&2, SlowJ, js)
    case WinOf{+w0}:
      win.js(w0)

def stats.one.of(p: TRun & List<&2, TRun>, es: List<&2, Ent>, errs: List<&2, ErrN>, total: Big) -> Stats:
  (cur, pend) = p
  Stats{es, Nil{}, cur, pend, errs, total}

def tim.wt(+t: Tim) -> List<&2, Wt>:
  match t:
    case Tim{cf, slow, evs, +wt}:
      wt
    case TimOf{+x}:
      tim.wt(x)

# the call that client id blocked with, if any, forgotten (served, or the
# client gone)
def tim.unwait(t: Tim, +id: Nat) -> Tim:
  match t:
    case Tim{cf, slow, evs, wt}:
      Tim{cf, slow, evs, wt.del(wt, id)}
    case TimOf{x}:
      tim.unwait(x, id)

# the window's call of client id that blocked, timed as one that did not
# (served in the window it blocked in)
def fresh.unblk(fs: List<&2, Fresh>, +id: Nat) -> List<&2, Fresh>:
  match fs:
    case Nil{}:
      Nil{}
    case Con{FCall{r, +j, arg, blk}, rest}:
      FCall{r, j, arg, Bool.and(blk, Bool.not(Nat.is_eq(j, id)))} <> fresh.unblk(rest, id)
    case Con{FRun{r}, rest}:
      FRun{r} <> fresh.unblk(rest, id)
    case Con{FNamed{j, arg, blk}, rest}:
      FNamed{j, arg, blk} <> fresh.unblk(rest, id)
    case Con{FRuns{rs}, rest}:
      FRuns{rs} <> fresh.unblk(rest, id)
    case Con{FSlow{j, us, code, arg}, rest}:
      FSlow{j, us, code, arg} <> fresh.unblk(rest, id)
    case Con{FReset{}, rest}:
      FReset{} <> fresh.unblk(rest, id)

def served.slow(log: Bool, +id: Nat, +us: Nat, +code: Nat, arg: Arg, fs: List<&2, Fresh>) -> List<&2, Fresh>:
  match log:
    case True{}:
      FSlow{id, us, code, arg} <> fs
    case False{}:
      fs

def served.of(p: TRun & List<&2, TRun>, es: List<&2, Ent>, fresh: List<&2, Fresh>, errs: List<&2, ErrN>, total: Big) -> Stats:
  (cur, pend) = p
  Stats{es, fresh, cur, pend, errs, total}

# the statistics after client id is served (m: the call it blocked with,
# kept: Wt): its share to usec again, and to the histogram while
# latency-tracking is on; its entry, when the slow log takes it, in the
# window, for the window's order; with none kept, its call blocked in the
# window, which times it as one that did not block
def stats.served(m: Maybe<&2, Wt>, st: Stats, +cf: TCfg, +id: Nat) -> Stats:
  match m st:
    case Some{Wt{j, +code, +us, arg}} Stats{es, fresh, cur, pend, errs, total}:
      served.of(timed.run(R.run.of(code, 0n), us, tcfg.trk(cf), us, 1n, 0n, (cur, pend)), es, served.slow(Bool.and(tcfg.son(cf), Bool.and(Nat.is_le(tcfg.slt(cf), us), Bool.not(R.stat.noslow(R.code.key(code))))), id, us, code, arg, fresh), errs, total)
    case None{} Stats{es, fresh, cur, pend, errs, total}:
      Stats{es, fresh.unblk(fresh, id), cur, pend, errs, total}

# Facts
# -----

# the server at its start: the operating system (as uname names it), the
# pid, the run id and the replication id (40 hex digits each), the
# program and the configuration file (absolute paths, "" for none), the
# machine's memory, the time it started (seconds since 1970) and the bytes
# its heap's live values held then (IO.heap)
type Boot is Data:
  IBoot{os: String, pid: String, run: String, replid: String, exe: String, conf: String, sysmem: Nat, start: U32, heap0: Nat}

def boot.start(+b: Boot) -> U32:
  match b:
    case IBoot{os, pid, run, replid, exe, conf, sysmem, start, heap0}:
      start

# what the shell saw last: the wall clock (seconds since 1970 and
# microseconds), the processor time of the process and of its main
# thread (user, system; clock ticks of 10 ms), the resident memory, the
# bytes the heap's live values hold and those the heap has taken
# (IO.heap: an allocator's allocated and active bytes), the
# connections taken since the start and those open, and the clients that
# wait (blocked) and those of them with a timeout, as the actor counts
# them (a connection's facts leave them as they were)
type Live is Data:
  ILive{secs: U32, usec: U32, ut: Nat, st: Nat, mut: Nat, mst: Nat, rss: Nat, heap: Nat, act: Nat, conns: Nat, clients: Nat, blk: Nat, tmo: Nat}

# commands run, bytes read and bytes sent
type Count is Data:
  ICount{cmds: Big, inb: Big, outb: Big}

# Redis's instantaneous rates: the time of the last sample (ms), the
# counts then, and the last 16 samples of each rate (per second, newest
# first), one each 100 ms
type Inst is Data:
  IInst{ms: Nat, last: Count, sc: List<&2, Nat>, si: List<&2, Nat>, so: List<&2, Nat>}

# the sweep of expired keys (redis.bend: reap): the bucket the next one
# starts at in each database (by number; none for 0), and the keys the
# sweeps deleted (Redis's expired_keys); and eviction's (server.bend,
# Eviction): the keys it deleted (evicted_keys), how long the heap was
# past maxmemory with the keys to evict not yet evicted (in ms) before the
# time that runs now, and when that time began (ms since 1970; 0 while it
# does not run), as Redis's stat_total_eviction_exceeded_time and
# stat_last_eviction_exceeded_time
type Exp is Data:
  IExp{cur: List<&2, Nat>, n: Nat, ev: Nat, xsum: Nat, xfrom: Nat}

# the rewrite of the append-only file (BGREWRITEAOF; server.bend, The
# rewrite of the append-only file), as INFO shows it: whether one runs,
# whether one is scheduled (asked for in EXEC: the cron starts it), when
# the one that runs started (ms since 1970), how long the last one took
# (s; none before the first), whether the last one ended well, how many
# started and how many failed in a row (CONFIG RESETSTAT counts both
# again)
type Rws is Data:
  IRws{on: Bool, sched: Bool, start: Nat, last: Maybe<&2, Nat>, ok: Bool, n: Nat, fails: Nat}

def rws.zero() -> Rws:
  IRws{False{}, False{}, 0n, None{}, True{}, 0n, 0n}

def rws.on(+r: Rws) -> Bool:
  match r:
    case IRws{+on, sched, start, last, ok, n, fails}:
      on

def rws.sched(+r: Rws) -> Bool:
  match r:
    case IRws{on, +sched, start, last, ok, n, fails}:
      sched

def rws.fails(+r: Rws) -> Nat:
  match r:
    case IRws{on, sched, start, last, ok, n, +fails}:
      fails

# a rewrite starts at ms (Redis's rewriteAppendOnlyFileBackground): it
# runs, none is scheduled any more, and it is counted
def rws.go(r: Rws, +ms: Nat) -> Rws:
  match r:
    case IRws{on, sched, start, last, ok, +n, fails}:
      IRws{True{}, False{}, ms, last, ok, 1n+n, fails}

# BGREWRITEAOF in EXEC: a rewrite scheduled, and the failures in a row
# forgotten, so that the cron starts it at once (bgrewriteaofCommand)
def rws.later(r: Rws) -> Rws:
  match r:
    case IRws{on, sched, start, last, ok, n, fails}:
      IRws{on, True{}, start, last, ok, n, 0n}

# the rewrite that ran ended at ms, well or not: the seconds it took are
# the difference of the two times in whole seconds, as Redis's time()
def rws.end(r: Rws, +well: Bool, +ms: Nat) -> Rws:
  match r:
    case IRws{on, sched, +start, last, ok, n, +fails}:
      IRws{False{}, sched, start, Some{Nat.sub(Nat.div(ms, 1000n), Nat.div(start, 1000n))}, well, n, Bool.pick(Nat, well, 0n, 1n+fails)}

# a rewrite that runs stopped, neither done nor failed, as Redis's
# killAppendOnlyChild stops it (a SHUTDOWN whose save failed)
def rws.stop(r: Rws) -> Rws:
  match r:
    case IRws{on, sched, start, last, ok, n, fails}:
      IRws{False{}, sched, start, last, ok, n, fails}

# CONFIG RESETSTAT: the rewrites and the failures in a row counted again
# (resetServerStats)
def rws.reset(r: Rws) -> Rws:
  match r:
    case IRws{on, sched, start, last, ok, n, fails}:
      IRws{on, sched, start, last, ok, 0n, 0n}

# the RDB file (server.bend, The RDB file), as INFO shows it: when the
# last save that ended well ended (s since 1970; the start until one
# does, as Redis's lastsave, which LASTSAVE answers), the SAVEs run
# (rdb_saves: CONFIG RESETSTAT counts them again), whether the last save
# ended well (rdb_last_bgsave_status: a save that fails leaves it as it
# was, as Redis's rdbSave does), the keys the start loaded from the file
# and those it dropped as their time had passed
# (rdb_last_load_keys_loaded and _expired), whether a FLUSHALL in the
# group asked for a save, and whether a SHUTDOWN asked for one before the
# server stops (the shell saves once the group has run). IRdbOf,
# a record that holds a record, is never built: it makes Rdb a node of its
# own, a word in Info, which is 64 words with it (a wider node is copied
# whole at every update: section 3zzz of FINDINGS.md)
type Rdb is Data:
  IRdb{last: Nat, saves: Nat, ok: Bool, loaded: Nat, expired: Nat, flush: Bool, shut: Bool, owed: Bool}
  IRdbOf{r: Rdb}

def rdb.new(+secs: Nat) -> Rdb:
  IRdb{secs, 0n, True{}, 0n, 0n, False{}, False{}, False{}}

def rdb.last(+r: Rdb) -> Nat:
  match r:
    case IRdb{+last, saves, ok, loaded, expired, flush, shut, owed}:
      last
    case IRdbOf{+x}:
      rdb.last(x)

def rdb.flush(+r: Rdb) -> Bool:
  match r:
    case IRdb{last, saves, ok, loaded, expired, +flush, shut, owed}:
      flush
    case IRdbOf{+x}:
      rdb.flush(x)

def rdb.shut(+r: Rdb) -> Bool:
  match r:
    case IRdb{last, saves, ok, loaded, expired, flush, +shut, owed}:
      shut
    case IRdbOf{+x}:
      rdb.shut(x)

# a save that ended well at the second secs; one that failed changes
# nothing
def rdb.saved(r: Rdb, +well: Bool, +secs: Nat) -> Rdb:
  match r:
    case IRdb{+last, saves, +ok, loaded, expired, flush, shut, owed}:
      IRdb{Bool.pick(Nat, well, secs, last), saves, Bool.or(ok, well), loaded, expired, flush, shut, owed}
    case IRdbOf{x}:
      rdb.saved(x, well, secs)

# a SAVE, counted as it runs (saveCommand)
def rdb.save(r: Rdb) -> Rdb:
  match r:
    case IRdb{last, +saves, ok, loaded, expired, flush, shut, owed}:
      IRdb{last, 1n+saves, ok, loaded, expired, flush, shut, True{}}
    case IRdbOf{x}:
      rdb.save(x)

def rdb.loaded(r: Rdb, +ld: Nat, +ex: Nat) -> Rdb:
  match r:
    case IRdb{last, saves, ok, loaded, expired, flush, shut, owed}:
      IRdb{last, saves, ok, ld, ex, flush, shut, owed}
    case IRdbOf{x}:
      rdb.loaded(x, ld, ex)

def rdb.flushed(r: Rdb, +on: Bool) -> Rdb:
  match r:
    case IRdb{last, saves, ok, loaded, expired, flush, shut, owed}:
      IRdb{last, saves, ok, loaded, expired, on, shut, owed}
    case IRdbOf{x}:
      rdb.flushed(x, on)

def rdb.shutting(r: Rdb, +on: Bool) -> Rdb:
  match r:
    case IRdb{last, saves, ok, loaded, expired, flush, shut, owed}:
      IRdb{last, saves, ok, loaded, expired, flush, on, owed}
    case IRdbOf{x}:
      rdb.shutting(x, on)

# whether a SAVE asked for a save the shell has not made yet; and that
# save made
def rdb.owed(+r: Rdb) -> Bool:
  match r:
    case IRdb{last, saves, ok, loaded, expired, flush, shut, +owed}:
      owed
    case IRdbOf{+x}:
      rdb.owed(x)

def rdb.paid(r: Rdb) -> Rdb:
  match r:
    case IRdb{last, saves, ok, loaded, expired, flush, shut, owed}:
      IRdb{last, saves, ok, loaded, expired, flush, shut, False{}}
    case IRdbOf{x}:
      rdb.paid(x)

def rdb.reset(r: Rdb) -> Rdb:
  match r:
    case IRdb{last, saves, ok, loaded, expired, flush, shut, owed}:
      IRdb{last, 0n, ok, loaded, expired, flush, shut, owed}
    case IRdbOf{x}:
      rdb.reset(x)

# everything INFO shows that the parameters and the keys do not: the
# start, the last facts, the counts, the rates, the peak of memory, the
# connections taken before the last CONFIG RESETSTAT, the size of the
# append-only file at the start (or after its last rewrite: Redis's
# aof_rewrite_base_size) and now, the statistics per command and per
# error, the sweep of expired keys, the rewrite of the file, and the
# timing (Timing), and the RDB file's account (Rdb). Info is a node of 64
# words: the compiler rebuilds a node of 64 words or fewer in place, where
# it copies a wider one whole at every update (once a batch: srv.ran), so
# the timing's state, the runs not yet counted and the RDB file's account
# are nodes of their own (Tim, TRun, Rdb)
type Info is Data:
  IInfo{boot: Boot, live: Live, cnt: Count, inst: Inst, peak: Nat, conns0: Nat, aof0: Nat, aof: Nat, st: Stats, ex: Exp, rw: Rws, tm: Tim, rdb: Rdb}

# CONFIG RESETSTAT counts the keys the sweeps and eviction delete and the
# time past maxmemory again (Redis's stat_expiredkeys, stat_evictedkeys
# and the times), and the sweeps go on where they were
def exp.reset(e: Exp) -> Exp:
  match e:
    case IExp{cur, n, ev, xsum, xfrom}:
      IExp{cur, 0n, 0n, 0n, 0n}

def exp.n(+e: Exp) -> Nat:
  match e:
    case IExp{cur, +n, ev, xsum, xfrom}:
      n

def exp.ev(+e: Exp) -> Nat:
  match e:
    case IExp{cur, n, +ev, xsum, xfrom}:
      ev

# the time past maxmemory at now, ms: before the one that runs, and the
# one that runs
def exp.cur(+e: Exp, +now: Nat) -> Nat:
  match e:
    case IExp{cur, n, ev, xsum, +xfrom}:
      Bool.pick(Nat, Nat.is_eq(xfrom, 0n), 0n, Nat.sub(now, xfrom))

def exp.total(+e: Exp, +now: Nat) -> Nat:
  match e:
    case IExp{cur, n, ev, +xsum, xfrom}:
      Nat.add(xsum, exp.cur(e, now))

# an eviction's outcome at now (Redis's update_metrics): one that left
# the heap past maxmemory (over: keys left to evict, or none it may
# evict) starts the time past it, if none runs; one that brought it back
# ends the time that runs; k keys evicted
def exp.evicted(e: Exp, +k: Nat, +over: Bool, +now: Nat) -> Exp:
  match e over:
    case IExp{cur, n, ev, xsum, +xfrom} True{}:
      IExp{cur, n, Nat.add(ev, k), xsum, Bool.pick(Nat, Nat.is_eq(xfrom, 0n), Nat.max(now, 1n), xfrom)}
    case IExp{cur, n, ev, +xsum, +xfrom} False{}:
      IExp{cur, n, Nat.add(ev, k), Nat.add(xsum, Bool.pick(Nat, Nat.is_eq(xfrom, 0n), 0n, Nat.sub(now, xfrom))), 0n}

def count.zero() -> Count:
  ICount{big.zero(), big.zero(), big.zero()}

def samples.zero() -> List<&2, Nat>:
  [0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n]

def live.ms(+l: Live) -> Nat:
  match l:
    case ILive{+secs, +usec, ut, st, mut, mst, rss, heap, act, conns, clients, b, t}:
      Nat.add(Nat.mul(U32.to_nat(secs), 1000n), U32.to_nat(U32.div(usec, 1000)))

def live.rss(+l: Live) -> Nat:
  match l:
    case ILive{secs, usec, ut, st, mut, mst, rss, heap, act, conns, clients, b, t}:
      rss

def live.heap(+l: Live) -> Nat:
  match l:
    case ILive{secs, usec, ut, st, mut, mst, rss, heap, act, conns, clients, b, t}:
      heap

def live.act(+l: Live) -> Nat:
  match l:
    case ILive{secs, usec, ut, st, mut, mst, rss, heap, act, conns, clients, b, t}:
      act

def live.conns(+l: Live) -> Nat:
  match l:
    case ILive{secs, usec, ut, st, mut, mst, rss, heap, act, conns, clients, b, t}:
      conns

# the server's facts at its start
def info.new(+b: Boot, +l: Live) -> Info:
  IInfo{b, l, count.zero(), IInst{live.ms(l), count.zero(), samples.zero(), samples.zero(), samples.zero()}, live.heap(l), 0n, 0n, 0n, stats.zero(), IExp{Nil{}, 0n, 0n, 0n, 0n}, rws.zero(), tim.new(), rdb.new(U32.to_nat(boot.start(b)))}

# the append-only file the server restored at its start, of size bytes
def info.restored(i: Info, +size: Nat) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, l, c, inst, pk, c0, size, size, st, ex, rw, tm, rf}

# a batch's commands, the bytes it came in and the bytes of its replies
def count.add(c: Count, +n: Nat, +inb: Nat, +outb: Nat) -> Count:
  match c:
    case ICount{x, y, z}:
      ICount{big.add(x, n), big.add(y, inb), big.add(z, outb)}

# a batch's calls that ran (Redis's total_commands_processed counts no
# others), its runs of calls (R.Tally), the bytes it came in and the
# bytes of its replies
def info.ran(i: Info, +calls: Nat, +r: Nat, rs: List<&2, Nat>, +inb: Nat, +outb: Nat) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, l, count.add(c, calls, inb, outb), inst, pk, c0, a0, a, stats.add(st, r, rs), ex, rw, tm, rf}

# a batch's error replies
def info.errs(i: Info, xs: List<&2, R.Erred>) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, l, c, inst, pk, c0, a0, a, stats.errs(xs, st), ex, rw, tm, rf}

# an error reply the shell sent itself (a protocol error)
def info.erred(i: Info, +m: String) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, l, c, inst, pk, c0, a0, a, stats.err(st, 1n, m), ex, rw, tm, rf}

# bytes appended to the append-only file
def info.aof(i: Info, +n: Nat) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, l, c, inst, pk, c0, a0, Nat.add(a, n), st, ex, rw, tm, rf}

# the rewrite of the file (Rws): its record; one started at ms; one
# scheduled; the one that ran ended well at ms, the file of size bytes
# then (the size after the rewrite is the base the cron's growth is
# measured from, as Redis's aof_rewrite_base_size); or failed at ms
def info.rw(+i: Info) -> Rws:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, +rw, tm, rf}:
      rw

def info.rw.go(i: Info, +ms: Nat) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rws.go(rw, ms), tm, rf}

def info.rw.later(i: Info) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rws.later(rw), tm, rf}

def info.rw.done(i: Info, +size: Nat, +ms: Nat) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, l, c, inst, pk, c0, size, size, st, ex, rws.end(rw, True{}, ms), tm, rf}

def info.rw.stop(i: Info) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rws.stop(rw), tm, rf}

def info.rw.failed(i: Info, +ms: Nat) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rws.end(rw, False{}, ms), tm, rf}

# the RDB file (Rdb): the second of the last save that ended well
# (LASTSAVE), whether a FLUSHALL of the group asked for a save; a save
# ended, well or not, at the second secs; a SAVE counted; the keys the
# start loaded and those it found expired; a FLUSHALL's save asked for
# (on) or done; a SHUTDOWN's save asked for (on) or made
def info.lastsave(+i: Info) -> Nat:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, +rf}:
      rdb.last(rf)

def info.rdb.flush(+i: Info) -> Bool:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, +rf}:
      rdb.flush(rf)

def info.rdb.saved(i: Info, +well: Bool, +secs: Nat) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rdb.saved(rf, well, secs)}

def info.rdb.save(i: Info) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rdb.save(rf)}

def info.rdb.loaded(i: Info, +ld: Nat, +ex2: Nat) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rdb.loaded(rf, ld, ex2)}

def info.rdb.flushed(i: Info, +on: Bool) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rdb.flushed(rf, on)}

def info.rdb.owed(+i: Info) -> Bool:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, +rf}:
      rdb.owed(rf)

def info.rdb.paid(i: Info) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rdb.paid(rf)}

def info.rdb.shut(+i: Info) -> Bool:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, +rf}:
      rdb.shut(rf)

def info.rdb.shutting(i: Info, +on: Bool) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rdb.shutting(rf, on)}

# the size of the file now and at the start or the last rewrite
def info.aof.size(+i: Info) -> Nat:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, +a, st, ex, rw, tm, rf}:
      a

def info.aof.base(+i: Info) -> Nat:
  match i:
    case IInfo{b, l, c, inst, pk, c0, +a0, a, st, ex, rw, tm, rf}:
      a0

# new facts from the shell; the peak of memory follows them
# new facts, the clients that wait as the actor counted them
def live.keep(l: Live, old: Live) -> Live:
  match l old:
    case ILive{secs, usec, ut, st, mut, mst, rss, heap, act, conns, clients, b0, t0} ILive{s1, u1, ut1, st1, mu1, ms1, r1, h1, a1, n1, c1, blk, tmo}:
      ILive{secs, usec, ut, st, mut, mst, rss, heap, act, conns, clients, blk, tmo}

def live.waits(l: Live, +n: Nat, +t: Nat) -> Live:
  match l:
    case ILive{secs, usec, ut, st, mut, mst, rss, heap, act, conns, clients, b0, t0}:
      ILive{secs, usec, ut, st, mut, mst, rss, heap, act, conns, clients, n, t}

def info.live(i: Info, +l: Live) -> Info:
  match i:
    case IInfo{b, old, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, live.keep(l, old), c, inst, Nat.max(pk, live.heap(l)), c0, a0, a, st, ex, rw, tm, rf}

# the heap's used bytes as the actor read them (IO.heap, before a group
# and after each key an eviction freed: the server's mem.run), which with
# maxmemory INFO shows, as Redis's INFO and performEvictions read one
# counter (zmalloc_used_memory); the peak follows
def live.heap.at(l: Live, +h: Nat) -> Live:
  match l:
    case ILive{secs, usec, ut, st, mut, mst, rss, heap, act, conns, clients, b, t}:
      ILive{secs, usec, ut, st, mut, mst, rss, h, act, conns, clients, b, t}

def info.heap(i: Info, +h: Nat) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, live.heap.at(l, h), c, inst, Nat.max(pk, h), c0, a0, a, st, ex, rw, tm, rf}

# new facts from the shell, the heap's reading left for the actor's own
# (info.heap), which the eviction went by
def info.live.held(i: Info, +l: Live) -> Info:
  match i:
    case IInfo{b, +old, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, live.heap.at(live.keep(l, old), live.heap(old)), c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}

# the clients that wait, n of them, t of them with a timeout
def info.blocked(i: Info, +n: Nat, +t: Nat) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, live.waits(l, n, t), c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}

# a call of code k that failed after it was counted: a blocked client
# that CLIENT UNBLOCK unblocked (Redis's updateStatsOnUnblock)
def info.failed(i: Info, +k: Nat) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, l, c, inst, pk, c0, a0, a, stats.failed(st, k), ex, rw, tm, rf}

def take15(n: Nat, xs: List<&2, Nat>) -> List<&2, Nat>:
  match n xs:
    case 0n _:
      Nil{}
    case 1n+m Con{x, rest}:
      x <> take15(m, rest)
    case 1n+m Nil{}:
      Nil{}

# a sample: what was done since the last one, per second (Redis's
# trackInstantaneousMetric)
def rate(+d: Nat, +t: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_lt(0n, t), Nat.div(Nat.mul(d, 1000n), t), 0n)

def inst.go(+c: Count, +last: Count, +t: Nat, +ms: Nat, sc: List<&2, Nat>, si: List<&2, Nat>, so: List<&2, Nat>) -> Inst:
  match c last:
    case ICount{+x, +y, +z} ICount{+lx, +ly, +lz}:
      IInst{ms, c, rate(big.diff(x, lx), t) <> take15(15n, sc), rate(big.diff(y, ly), t) <> take15(15n, si), rate(big.diff(z, lz), t) <> take15(15n, so)}

def inst.tick(inst: Inst, +c: Count, +ms: Nat) -> Inst:
  match inst:
    case IInst{lms, +last, sc, si, so}:
      inst.go(c, last, Nat.sub(ms, lms), ms, sc, si, so)

# the cron's sample, at ms since 1970; the runs of calls not yet counted
# are counted
def info.tick(i: Info, +ms: Nat) -> Info:
  match i:
    case IInfo{b, l, +c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, l, c, inst.tick(inst, c, ms), pk, c0, a0, a, stats.fold(st), ex, rw, tm, rf}

# CONFIG RESETSTAT: the counts, the rates and the statistics start again,
# as Redis's resetServerStats, resetCommandTableStats and
# resetErrorTableStats start them (the window's calls before it are timed,
# not counted: stats.reset)
def info.reset(i: Info) -> Info:
  match i:
    case IInfo{b, +l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, l, count.zero(), IInst{live.ms(l), count.zero(), samples.zero(), samples.zero(), samples.zero()}, pk, live.conns(l), a0, a, stats.reset(st), exp.reset(ex), rws.reset(rw), tm, rdb.reset(rf)}

# the j-th of a list of numbers (0 past its end), and the list with v in
# its place
def cur.nth(j: Nat, +xs: List<&2, Nat>) -> Nat:
  match j xs:
    case 0n Con{+x, rest}:
      x
    case 1n+i Con{x, +rest}:
      cur.nth(i, rest)
    case _ Nil{}:
      0n

def cur.put(j: Nat, +v: Nat, xs: List<&2, Nat>) -> List<&2, Nat>:
  match j xs:
    case 0n Con{x, rest}:
      v <> rest
    case 0n Nil{}:
      [v]
    case 1n+i Con{x, rest}:
      x <> cur.put(i, v, rest)
    case 1n+i Nil{}:
      0n <> cur.put(i, v, Nil{})

# the sweep of expired keys: where the next one starts in database j, and
# a sweep of j that stopped at next having deleted k keys
def info.reap_at(+i: Info, +j: Nat) -> Nat:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, +ex, rw, tm, rf}:
      match ex:
        case IExp{+cur, n, ev, xsum, xfrom}:
          cur.nth(j, cur)

def info.reaped(i: Info, +j: Nat, +next: Nat, +k: Nat) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      match ex:
        case IExp{cur, +n, ev, xsum, xfrom}:
          IInfo{b, l, c, inst, pk, c0, a0, a, st, IExp{cur.put(j, next, cur), Nat.add(n, k), ev, xsum, xfrom}, rw, tm, rf}

# an eviction at now that deleted k keys and left the heap past maxmemory
# or not (over)
def info.evicted(i: Info, +k: Nat, +over: Bool, +now: Nat) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, l, c, inst, pk, c0, a0, a, st, exp.evicted(ex, k, over, now), rw, tm, rf}

# the timing's parameters read again (the start, CONFIG SET)
def info.cfg(i: Info, +items: List<&2, C.CItem>) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tim.cfg(tm, items), rf}

def info.tim(+i: Info) -> Tim:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, +tm, rf}:
      tm

def info.stats(+i: Info) -> Stats:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, +st, ex, rw, tm, rf}:
      st

# a window timed (Timing a window): the server's facts after it, and the
# slow log's entries for the shell to complete, oldest first
type Timed is Data:
  Timed{i: Info, js: List<&2, SlowJ>}

# what the window since the clock's last reading, which took d us, needs:
# nothing when it saw nothing to time (0), its one run timed when it is
# quiet (1: one run of the fast way, its highest share below the slow
# log's and the latency monitor's thresholds, or they are off), else all
# of its timing (2)
def info.how(+i: Info, +d: Nat) -> Nat:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, Stats{es, Nil{}, cur, pend, errs, total}, ex, rw, tm, rf}:
      0n
    case IInfo{b, l, c, inst, pk, c0, a0, a, Stats{es, Con{FRun{+r}, Nil{}}, cur, pend, errs, total}, ex, rw, Tim{TCfg{+son, +slt, smax, +lat, trk}, slow, evs, wt}, rf}:
      +n = Nat.max(run.ran(r), 1n)
      +top = Nat.add(Nat.div(d, n), Nat.min(Nat.mod(d, n), 1n))
      Bool.pick(Nat, Bool.and(Bool.or(Bool.not(son), Nat.is_lt(top, slt)), Bool.or(Nat.is_eq(lat, 0n), Nat.is_lt(Nat.div(top, 1000n), lat))), 1n, 2n)
    case _:
      2n

# a quiet window timed: its one run's calls share its d us
def info.one(i: Info, +d: Nat) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, Stats{es, Con{FRun{+r}, Nil{}}, cur, pend, errs, total}, ex, rw, +tm, rf}:
      +k = run.ran(r)
      +n = Nat.max(k, 1n)
      +s = Nat.div(d, n)
      +m = Nat.mod(d, n)
      IInfo{b, l, c, inst, pk, c0, a0, a, stats.one.of(timed.run(r, Nat.add(Nat.mul(k, s), m), tcfg.trk(tim.cf(tm)), s, k, m, (cur, pend)), es, errs, total), ex, rw, tm, rf}
    case other:
      other

# the window since the clock's last reading took d us; a run of the fast
# way in it is of the batch of raw, the client id's; now: the window's
# end, in s since 1970
def info.window(i: Info, +d: Nat, +id: Nat, raw: String, +now: Nat) -> Timed:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      match st tm:
        case Stats{es, +fresh, cur, pend, errs, total} Tim{+cf, slow, evs, wt}:
          +n = Nat.max(fresh.ran(fresh, 0n), 1n)
          +w = win.both(fresh.split(fresh, Nil{}), Nat.div(d, n), tcfg.trk(cf), tcfg.son(cf), tcfg.slt(cf), id, raw, Win{cur, pend, wt, Nil{}, Nat.mod(d, n), 0n, 0n, 0n})
          Timed{IInfo{b, l, c, inst, pk, c0, a0, a, win.stats(es, errs, total, w), ex, rw, win.tim(cf, slow, evs, now, w), rf}, win.js(w)}
        case s0 TimOf{x}:
          Timed{IInfo{b, l, c, inst, pk, c0, a0, a, s0, ex, rw, x, rf}, Nil{}}

# the call of the general way about to run, of the client of id, with
# arguments arg; and that it blocks, as it is counted
def info.call(i: Info, +id: Nat, arg: Arg) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, l, c, inst, pk, c0, a0, a, stats.call(st, id, arg), ex, rw, tm, rf}

def info.blk(i: Info) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, l, c, inst, pk, c0, a0, a, stats.blk(st), ex, rw, tm, rf}

# the client of id served after it waited, or unblocked by CLIENT UNBLOCK
# (stats.served); gone, the call it blocked with is forgotten
def info.served(i: Info, +id: Nat) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, +tm, rf}:
      IInfo{b, l, c, inst, pk, c0, a0, a, stats.served(wt.get(tim.wt(tm), id), st, tim.cf(tm), id), ex, rw, tim.unwait(tm, id), rf}

def info.gone(i: Info, +id: Nat) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tim.unwait(tm, id), rf}

# a call of d us at at (s since 1970), its arguments xs, its client's
# address and name, for the slow log (Timing)
def info.slow(i: Info, +d: Nat, +at: Nat, +xs: List<&2, String>, +peer: String, +name: String) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tim.slow(tm, d, at, xs, peer, name), rf}

# a latency of ms of event name at second now, for the latency monitor
def info.lat(i: Info, +name: String, +ms: Nat, +now: Nat) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tim.lat(tm, name, ms, now), rf}

# SLOWLOG RESET, and LATENCY RESET of names (all with none)
def info.slow.reset(i: Info) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tim.slow.reset(tm), rf}

def info.lat.reset(i: Info, names: List<&2, String>) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tim.lat.reset(tm, names), rf}

# Numbers as printf writes them
# ----------------------------

# a quotient and a remainder
type QR is Data:
  IQR{q: String, r: Nat}

def ldiv.go(s: String, +d: Nat, +r: Nat, acc: String) -> QR:
  match s:
    case SNil{}:
      IQR{C.dec.trim(String.reverse(acc)), r}
    case SCon{Chr{+x}, t}:
      +v = Nat.add(Nat.mul(r, 10n), U32.to_nat(U32.sub(x, 48)))
      ldiv.go(t, d, Nat.mod(v, d), SCon{C.dec.digit(Nat.div(v, d)), acc})

# decimal digits divided by d, by long division (10 d below 2^48)
def ldiv(s: String, +d: Nat) -> QR:
  ldiv.go(s, d, 0n, "")

# hundredths as "x.yy"
def hundredths(+q: Nat) -> String:
  Nat.show(Nat.div(q, 100n)) ++ "." ++ pad(Nat.show(Nat.mod(q, 100n)), 2n)

# hundredths rounded as printf rounds an exact quotient: to the nearest,
# and an exact half to the even one
def round2(+q: Nat, +up: Bool, +tie: Bool) -> String:
  hundredths(Bool.pick(Nat, Bool.or(up, Bool.and(tie, Nat.is_eq(Nat.mod(q, 2n), 1n))), 1n+q, q))

def fix2.qr(qr: QR, +d: Nat) -> String:
  match qr:
    case IQR{q, +r}:
      round2(C.dec.small(q, 0n), Nat.is_lt(d, Nat.mul(r, 2n)), Nat.is_eq(d, Nat.mul(r, 2n)))

# "%.2f" of the digits n over d (d below 2^44)
def fix2(+n: String, +d: Nat) -> String:
  fix2.qr(ldiv(n ++ "00", d), d)

# a quotient by 1024 several times over: the quotient, the last
# remainder, and whether any remainder before it was not 0 (the rest of
# the fraction, for rounding)
type HD is Data:
  IHD{q: String, top: Nat, low: Bool}

def h.step(qr: QR, +top: Nat, +low: Bool) -> HD:
  match qr:
    case IQR{q, r}:
      IHD{q, r, Bool.or(low, Nat.is_lt(0n, top))}

def h.div1(d: HD) -> HD:
  match d:
    case IHD{q, +top, +low}:
      h.step(ldiv(q, 1024n), top, low)

def h.div(k: Nat, d: HD) -> HD:
  match k:
    case 0n:
      d
    case 1n+m:
      h.div(m, h.div1(d))

def h.fin(d: HD, +unit: String) -> String:
  match d:
    case IHD{q, +top, +low}:
      round2(C.dec.small(q, 0n), Bool.or(Nat.is_lt(512n, top), Bool.and(Nat.is_eq(top, 512n), low)), Bool.and(Nat.is_eq(top, 512n), Bool.not(low))) ++ unit

def h.unit(+n: String, k: Nat, +unit: String) -> String:
  h.fin(h.div(k, IHD{C.dec.mul(n, 100n), 0n, False{}}), unit)

def lt(+a: String, +b: String) -> Bool:
  Bool.not(C.dec.le(b, a))

# bytes as Redis's bytesToHuman writes them: B under 1024, then K, M, G,
# T and P with two decimals, B again from 1024^6 on. Each unit is a match
# on whether the bytes are below the next: a unit's quotient is worked out
# for the unit that applies alone (Bool.pick would work out each, and that
# of maxmemory's largest values in K is past a Nat)
def human.p(below: Bool, +n: String) -> String:
  match below:
    case True{}:
      h.unit(n, 5n, "P")
    case False{}:
      n ++ "B"

def human.t(below: Bool, +n: String) -> String:
  match below:
    case True{}:
      h.unit(n, 4n, "T")
    case False{}:
      human.p(lt(n, "1152921504606846976"), n)

def human.g(below: Bool, +n: String) -> String:
  match below:
    case True{}:
      h.unit(n, 3n, "G")
    case False{}:
      human.t(lt(n, "1125899906842624"), n)

def human.m(below: Bool, +n: String) -> String:
  match below:
    case True{}:
      h.unit(n, 2n, "M")
    case False{}:
      human.g(lt(n, "1099511627776"), n)

def human.k(below: Bool, +n: String) -> String:
  match below:
    case True{}:
      h.unit(n, 1n, "K")
    case False{}:
      human.m(lt(n, "1073741824"), n)

def human.b(below: Bool, +n: String) -> String:
  match below:
    case True{}:
      n ++ "B"
    case False{}:
      human.k(lt(n, "1048576"), n)

def human(+n: String) -> String:
  human.b(lt(n, "1024"), n)

# a number up to 2^64 - 1 as "%lld" prints it
def signed64(+v: String) -> String:
  Bool.pick(String, C.dec.le("9223372036854775808", v), "-" ++ C.dec.sub("18446744073709551616", v), v)

# clock ticks of 10 ms as "%ld.%06ld" prints seconds and microseconds
def cpu(+t: Nat) -> String:
  Nat.show(Nat.div(t, 100n)) ++ "." ++ pad(Nat.show(Nat.mul(Nat.mod(t, 100n), 10000n)), 6n)

def sum(xs: List<&2, Nat>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case Con{x, rest}:
      Nat.add(x, sum(rest))

# the mean of the samples, as Redis's getInstantaneousMetric
def mean(xs: List<&2, Nat>) -> Nat:
  Nat.div(sum(xs), 16n)

# whether an entry has a histogram
def ent.timed(+e: Ent) -> Bool:
  match e:
    case Ent{k, calls, rej, fail, us, +h}:
      ht.some(h)

# INFO's latencystats: for each command with a histogram, while
# latency-tracking is on, the percentiles latency-tracking-info-percentiles
# names, each as hdr_value_at_percentile finds it: the first index whose
# count, with those before it, reaches (p / 100) * total + 0.5 in C's
# doubles, cut to an integer (1 at least), and the highest value of that
# index (its lowest for p 0), in us with three decimals ("%.3f")
def d64.two32() -> Nat:
  Nat.mul(65536n, 65536n)

def d64.of(+n: Nat) -> U32 & U32:
  F64.of_u64(U32.from_nat(Nat.div(n, d64.two32())), U32.from_nat(Nat.mod(n, d64.two32())))

def d64.mul(a: U32 & U32, b: U32 & U32) -> U32 & U32:
  (ah, al) = a
  (bh, bl) = b
  F64.mul(ah, al, bh, bl)

def d64.div(a: U32 & U32, b: U32 & U32) -> U32 & U32:
  (ah, al) = a
  (bh, bl) = b
  F64.div(ah, al, bh, bl)

def d64.half(a: U32 & U32) -> U32 & U32:
  (h, l) = a
  F64.add(h, l, 1071644672, 0)

def d64.nat(a: U32 & U32) -> Nat:
  (h, l) = a
  Nat.add(Nat.mul(U32.to_nat(h), d64.two32()), U32.to_nat(l))

def d64.int(a: U32 & U32) -> Nat:
  (h, l) = a
  d64.nat(F64.to_i64(h, l))

def hist.first(+want: Nat, +cum: Nat, +bs: List<&2, HBin>) -> Bool:
  match bs:
    case Con{HBin{i, +n}, rest}:
      Nat.is_le(want, Nat.add(cum, n))
    case Nil{}:
      True{}

# the index where the counts reach want (hit: whether the first's does)
def hist.at(+bs: List<&2, HBin>, hit: Bool, +want: Nat, +cum: Nat) -> Nat:
  match bs hit:
    case Con{HBin{+i, n}, rest} True{}:
      i
    case Con{HBin{i, +n}, +rest} False{}:
      +c = Nat.add(cum, n)
      hist.at(rest, hist.first(want, c, rest), want, c)
    case Nil{} _:
      0n

def pct.ns(zero: Bool, +i: Nat) -> Nat:
  match zero:
    case True{}:
      hdr.low(i)
    case False{}:
      hdr.high(i)

def pct.us(+v: Nat) -> String:
  Nat.show(Nat.div(v, 1000n)) ++ "." ++ pad(Nat.show(Nat.mod(v, 1000n)), 3n)

def pct.one.of(+tok: String, +h: List<&2, HBin>, +t: Nat, p: U32 & U32) -> String:
  (h0, l0) = p
  +ph = h0
  +pl = l0
  +want = Nat.max(d64.int(d64.half(d64.mul(F64.div(ph, pl, 1079574528, 0), d64.of(t)))), 1n)
  "p" ++ tok ++ "=" ++ pct.us(pct.ns(F64.is_eq(ph, pl, 0, 0), hist.at(h, hist.first(want, 0n, h), want, 0n)))

def pct.one(+tok: String, +h: List<&2, HBin>, +t: Nat) -> String:
  pct.one.of(tok, h, t, F64.read(tok))

def pct.all(toks: List<&2, String>, +h: List<&2, HBin>, +t: Nat, +first: Bool) -> String:
  match toks:
    case Nil{}:
      ""
    case Con{+x, rest}:
      Bool.pick(String, first, "", ",") ++ pct.one(x, h, t) ++ pct.all(rest, h, t, False{})

def lat.line(+e: Ent, +toks: List<&2, String>) -> String:
  match e:
    case Ent{+k, calls, rej, fail, us, h}:
      +bs = ht.bins(h)
      "latency_percentiles_usec_" ++ R.stat.name(k) ++ ":" ++ pct.all(toks, bs, bins.total(bs, 0n), True{}) ++ "\r\n"

def lat.lines(+es: List<&2, Ent>, +toks: List<&2, String>) -> String:
  match es:
    case Nil{}:
      ""
    case Con{+e, +rest}:
      Bool.pick(String, ent.timed(e), lat.line(e, toks), "") ++ lat.lines(rest, toks)

def lat.stats.of(on: Bool, +st: Stats, +items: List<&2, C.CItem>) -> String:
  match on:
    case True{}:
      lat.lines(ents.sort(stats.view(st), Nil{}), C.words(C.config.get_value(items, "latency-tracking-info-percentiles")))
    case False{}:
      ""

# The sections
# ------------

def kv(+k: String, +v: String) -> String:
  k ++ ":" ++ v ++ "\r\n"

def cfg(+items: List<&2, C.CItem>, +name: String) -> String:
  C.config.get_value(items, name)

def flag(b: Bool) -> String:
  match b:
    case True{}:
      "1"
    case False{}:
      "0"

def sec.server(+items: List<&2, C.CItem>, +b: Boot, +l: Live) -> String:
  match b l:
    case IBoot{+os, +pid, +run, +replid, +exe, +conf, sysmem, +start, heap0} ILive{+secs, +usec, ut, st, mut, mst, rss, heap, act, conns, clients, bk, tm}:
      +up = Bool.pick(U32, U32.is_le(start, secs), U32.sub(secs, start), 0)
      "# Server\r\n" ++ kv("redis_version", "7.0.15") ++ kv("redis_git_sha1", "00000000") ++ kv("redis_git_dirty", "0") ++
      kv("redis_build_id", "0000000000000000") ++ kv("redis_mode", "standalone") ++ kv("os", os) ++ kv("arch_bits", "64") ++
      kv("monotonic_clock", "POSIX clock_gettime") ++ kv("multiplexing_api", "epoll") ++ kv("atomicvar_api", "c11-builtin") ++
      kv("gcc_version", "0.0.0") ++ kv("process_id", pid) ++ kv("process_supervised", "no") ++ kv("run_id", run) ++
      kv("tcp_port", cfg(items, "port")) ++ kv("server_time_usec", U32.show(secs) ++ pad(U32.show(usec), 6n)) ++
      kv("uptime_in_seconds", U32.show(up)) ++ kv("uptime_in_days", U32.show(U32.div(up, 86400))) ++
      kv("hz", cfg(items, "hz")) ++ kv("configured_hz", cfg(items, "hz")) ++ kv("lru_clock", U32.show(U32.and(secs, 16777215))) ++
      kv("executable", exe) ++ kv("config_file", conf) ++ kv("io_threads_active", "0")

def sec.clients(+items: List<&2, C.CItem>, +l: Live) -> String:
  match l:
    case ILive{secs, usec, ut, st, mut, mst, rss, heap, act, conns, +clients, +blk, +tmo}:
      "# Clients\r\n" ++ kv("connected_clients", Nat.show(clients)) ++ kv("cluster_connections", "0") ++
      kv("maxclients", cfg(items, "maxclients")) ++ kv("client_recent_max_input_buffer", "0") ++
      kv("client_recent_max_output_buffer", "0") ++ kv("blocked_clients", Nat.show(blk)) ++ kv("tracking_clients", "0") ++
      kv("clients_in_timeout_table", Nat.show(tmo))

# memory: used_memory is what the heap's live values hold (IO.heap, as
# zmalloc counts what Redis allocated), from which maxmemory evicts;
# allocator_active what the heap has taken, which it keeps; the resident
# memory is the process's. The start's live bytes are the overhead, the
# rest the dataset. A difference that may be negative is printed so (%zd)
def sdiff(+a: Nat, +b: Nat) -> String:
  Bool.pick(String, Nat.is_le(b, a), Nat.show(Nat.sub(a, b)), "-" ++ Nat.show(Nat.sub(b, a)))

def ratio(+a: Nat, +b: Nat) -> String:
  fix2(Nat.show(a), Nat.max(b, 1n))

def sec.memory.go(+items: List<&2, C.CItem>, +used: Nat, +pk: Nat, +used0: Nat, +rss: Nat, +act: Nat, +sysmem: Nat) -> String:
  +data = Nat.sub(used, used0)
  +net = Bool.pick(Nat, Nat.is_lt(used0, used), Nat.sub(used, used0), 1n)
  "# Memory\r\n" ++ kv("used_memory", Nat.show(used)) ++ kv("used_memory_human", human(Nat.show(used))) ++
  kv("used_memory_rss", Nat.show(rss)) ++ kv("used_memory_rss_human", human(Nat.show(rss))) ++
  kv("used_memory_peak", Nat.show(pk)) ++ kv("used_memory_peak_human", human(Nat.show(pk))) ++
  kv("used_memory_peak_perc", fix2(C.dec.mul(Nat.show(used), 100n), Nat.max(pk, 1n)) ++ "%") ++
  kv("used_memory_overhead", Nat.show(used0)) ++ kv("used_memory_startup", Nat.show(used0)) ++
  kv("used_memory_dataset", Nat.show(data)) ++ kv("used_memory_dataset_perc", fix2(C.dec.mul(Nat.show(data), 100n), net) ++ "%") ++
  kv("allocator_allocated", Nat.show(used)) ++ kv("allocator_active", Nat.show(act)) ++ kv("allocator_resident", Nat.show(rss)) ++
  kv("total_system_memory", Nat.show(sysmem)) ++ kv("total_system_memory_human", human(Nat.show(sysmem))) ++
  kv("used_memory_lua", "0") ++ kv("used_memory_vm_eval", "0") ++ kv("used_memory_lua_human", "0B") ++
  kv("used_memory_scripts_eval", "0") ++ kv("number_of_cached_scripts", "0") ++ kv("number_of_functions", "0") ++
  kv("number_of_libraries", "0") ++ kv("used_memory_vm_functions", "0") ++ kv("used_memory_vm_total", "0") ++
  kv("used_memory_vm_total_human", "0B") ++ kv("used_memory_functions", "0") ++ kv("used_memory_scripts", "0") ++
  kv("used_memory_scripts_human", "0B") ++ kv("maxmemory", signed64(cfg(items, "maxmemory"))) ++
  kv("maxmemory_human", human(cfg(items, "maxmemory"))) ++ kv("maxmemory_policy", cfg(items, "maxmemory-policy")) ++
  kv("allocator_frag_ratio", ratio(act, used)) ++ kv("allocator_frag_bytes", Nat.show(Nat.sub(act, used))) ++
  kv("allocator_rss_ratio", ratio(rss, act)) ++ kv("allocator_rss_bytes", sdiff(rss, act)) ++
  kv("rss_overhead_ratio", "1.00") ++ kv("rss_overhead_bytes", "0") ++
  kv("mem_fragmentation_ratio", ratio(rss, used)) ++ kv("mem_fragmentation_bytes", sdiff(rss, used)) ++
  kv("mem_not_counted_for_evict", "0") ++
  kv("mem_replication_backlog", "0") ++ kv("mem_total_replication_buffers", "0") ++ kv("mem_clients_slaves", "0") ++
  kv("mem_clients_normal", "0") ++ kv("mem_cluster_links", "0") ++ kv("mem_aof_buffer", "0") ++ kv("mem_allocator", "libc") ++
  kv("active_defrag_running", "0") ++ kv("lazyfree_pending_objects", "0") ++ kv("lazyfreed_objects", "0")

def sec.memory(+items: List<&2, C.CItem>, +b: Boot, +l: Live, +pk: Nat) -> String:
  match b:
    case IBoot{os, pid, run, replid, exe, conf, +sysmem, start, +heap0}:
      sec.memory.go(items, live.heap(l), Nat.max(pk, live.heap(l)), heap0, live.rss(l), live.act(l), sysmem)

def sec.aof(on: Bool, +a0: Nat, +a: Nat, +sched: Bool) -> String:
  match on:
    case True{}:
      kv("aof_current_size", Nat.show(a)) ++ kv("aof_base_size", Nat.show(a0)) ++ kv("aof_pending_rewrite", flag(sched)) ++
      kv("aof_buffer_length", "0") ++ kv("aof_pending_bio_fsync", "0") ++ kv("aof_delayed_fsync", "0")
    case False{}:
      ""

# how long the last rewrite took (-1 before the first), and the one that
# runs so far at now (ms; -1 when none runs), in seconds as Redis counts
# them (the difference of the two times in whole seconds)
def rw.last(m: Maybe<&2, Nat>) -> String:
  match m:
    case Some{+t}:
      Nat.show(t)
    case None{}:
      "-1"

def rw.cur(on: Bool, +start: Nat, +now: Nat) -> String:
  match on:
    case True{}:
      Nat.show(Nat.sub(Nat.div(now, 1000n), Nat.div(start, 1000n)))
    case False{}:
      "-1"

def sec.rewrite(r: Rws, +now: Nat) -> String:
  match r:
    case IRws{+on, +sched, +start, last, +ok, +n, +fails}:
      kv("aof_rewrite_in_progress", flag(on)) ++ kv("aof_rewrite_scheduled", flag(sched)) ++
      kv("aof_last_rewrite_time_sec", rw.last(last)) ++ kv("aof_current_rewrite_time_sec", rw.cur(on, start, now)) ++
      kv("aof_last_bgrewrite_status", Bool.pick(String, ok, "ok", "err")) ++ kv("aof_rewrites", Nat.show(n)) ++
      kv("aof_rewrites_consecutive_failures", Nat.show(fails))

def rdb.lines(+r: Rdb) -> String:
  match r:
    case IRdb{+last, +saves, +ok, +loaded, +expired, flush, shut, owed}:
      kv("rdb_last_save_time", Nat.show(last)) ++ kv("rdb_last_bgsave_status", Bool.pick(String, ok, "ok", "err")) ++
      kv("rdb_last_bgsave_time_sec", "-1") ++ kv("rdb_current_bgsave_time_sec", "-1") ++ kv("rdb_saves", Nat.show(saves)) ++
      kv("rdb_last_cow_size", "0") ++ kv("rdb_last_load_keys_expired", Nat.show(expired)) ++ kv("rdb_last_load_keys_loaded", Nat.show(loaded))
    case IRdbOf{+x}:
      rdb.lines(x)

def sec.persistence(+items: List<&2, C.CItem>, +rf: Rdb, +a0: Nat, +a: Nat, +rw: Rws, +now: Nat) -> String:
  +on = String.eq(cfg(items, "appendonly"), "yes")
  "# Persistence\r\n" ++ kv("loading", "0") ++ kv("async_loading", "0") ++ kv("current_cow_peak", "0") ++
  kv("current_cow_size", "0") ++ kv("current_cow_size_age", "0") ++ kv("current_fork_perc", "0.00") ++
  kv("current_save_keys_processed", "0") ++ kv("current_save_keys_total", "0") ++ kv("rdb_changes_since_last_save", "0") ++
  kv("rdb_bgsave_in_progress", "0") ++ rdb.lines(rf) ++
  kv("aof_enabled", flag(on)) ++ sec.rewrite(rw, now) ++ kv("aof_last_write_status", "ok") ++
  kv("aof_last_cow_size", "0") ++ kv("module_fork_in_progress", "0") ++ kv("module_fork_last_cow_size", "0") ++
  sec.aof(on, a0, a, rws.sched(rw))

def sec.stats.go(c: Count, inst: Inst, +conns: Nat, +errs: String, +expired: Nat, +ex: Exp, +now: Nat) -> String:
  match c inst:
    case ICount{+cmds, +inb, +outb} IInst{ms, last, +sc, +si, +so}:
      "# Stats\r\n" ++ kv("total_connections_received", Nat.show(conns)) ++ kv("total_commands_processed", big.show(cmds)) ++
      kv("instantaneous_ops_per_sec", Nat.show(mean(sc))) ++ kv("total_net_input_bytes", big.show(inb)) ++
      kv("total_net_output_bytes", big.show(outb)) ++ kv("total_net_repl_input_bytes", "0") ++
      kv("total_net_repl_output_bytes", "0") ++ kv("instantaneous_input_kbps", fix2(Nat.show(mean(si)), 1024n)) ++
      kv("instantaneous_output_kbps", fix2(Nat.show(mean(so)), 1024n)) ++ kv("instantaneous_input_repl_kbps", "0.00") ++
      kv("instantaneous_output_repl_kbps", "0.00") ++ kv("rejected_connections", "0") ++ kv("sync_full", "0") ++
      kv("sync_partial_ok", "0") ++ kv("sync_partial_err", "0") ++ kv("expired_keys", Nat.show(expired)) ++ kv("expired_stale_perc", "0.00") ++
      kv("expired_time_cap_reached_count", "0") ++ kv("expire_cycle_cpu_milliseconds", "0") ++ kv("evicted_keys", Nat.show(exp.ev(ex))) ++
      kv("evicted_clients", "0") ++ kv("total_eviction_exceeded_time", Nat.show(exp.total(ex, now))) ++ kv("current_eviction_exceeded_time", Nat.show(exp.cur(ex, now))) ++
      kv("keyspace_hits", "0") ++ kv("keyspace_misses", "0") ++ kv("pubsub_channels", "0") ++ kv("pubsub_patterns", "0") ++
      kv("pubsubshard_channels", "0") ++ kv("latest_fork_usec", "0") ++ kv("total_forks", "0") ++
      kv("migrate_cached_sockets", "0") ++ kv("slave_expires_tracked_keys", "0") ++ kv("active_defrag_hits", "0") ++
      kv("active_defrag_misses", "0") ++ kv("active_defrag_key_hits", "0") ++ kv("active_defrag_key_misses", "0") ++
      kv("total_active_defrag_time", "0") ++ kv("current_active_defrag_time", "0") ++ kv("tracking_total_keys", "0") ++
      kv("tracking_total_items", "0") ++ kv("tracking_total_prefixes", "0") ++ kv("unexpected_error_replies", "0") ++
      kv("total_error_replies", errs) ++ kv("dump_payload_sanitizations", "0") ++ kv("total_reads_processed", "0") ++
      kv("total_writes_processed", "0") ++ kv("io_threaded_reads_processed", "0") ++ kv("io_threaded_writes_processed", "0") ++
      kv("reply_buffer_shrinks", "0") ++ kv("reply_buffer_expands", "0")

def sec.good(on: Bool) -> String:
  match on:
    case True{}:
      kv("min_slaves_good_slaves", "0")
    case False{}:
      ""

def sec.replication(+items: List<&2, C.CItem>, +replid: String) -> String:
  "# Replication\r\n" ++ kv("role", "master") ++ kv("connected_slaves", "0") ++
  sec.good(Bool.and(Bool.not(String.eq(cfg(items, "min-replicas-to-write"), "0")), Bool.not(String.eq(cfg(items, "min-replicas-max-lag"), "0")))) ++
  kv("master_failover_state", "no-failover") ++ kv("master_replid", replid) ++
  kv("master_replid2", "0000000000000000000000000000000000000000") ++ kv("master_repl_offset", "0") ++
  kv("second_repl_offset", "-1") ++ kv("repl_backlog_active", "0") ++ kv("repl_backlog_size", cfg(items, "repl-backlog-size")) ++
  kv("repl_backlog_first_byte_offset", "0") ++ kv("repl_backlog_histlen", "0")

def sec.cpu(+l: Live) -> String:
  match l:
    case ILive{secs, usec, +ut, +st, +mut, +mst, rss, heap, act, conns, clients, b, t}:
      "# CPU\r\n" ++ kv("used_cpu_sys", cpu(st)) ++ kv("used_cpu_user", cpu(ut)) ++ kv("used_cpu_sys_children", "0.000000") ++
      kv("used_cpu_user_children", "0.000000") ++ kv("used_cpu_sys_main_thread", cpu(mst)) ++ kv("used_cpu_user_main_thread", cpu(mut))

# a line for each database that holds keys
def ks.line(has: Bool, +i: Nat, +n: Nat, +x: Nat) -> String:
  match has:
    case True{}:
      "db" ++ Nat.show(i) ++ ":keys=" ++ Nat.show(n) ++ ",expires=" ++ Nat.show(x) ++ ",avg_ttl=0\r\n"
    case False{}:
      ""

def ks.lines(dbs: List<&2, R.Db>, +i: Nat) -> String:
  match dbs:
    case Nil{}:
      ""
    case Con{+d, rest}:
      +n = R.db.n(d)
      ks.line(Nat.is_lt(0n, n), i, n, R.db.x(d)) ++ ks.lines(rest, 1n+i)

def sec.keyspace(dbs: List<&2, R.Db>) -> String:
  "# Keyspace\r\n" ++ ks.lines(dbs, 0n)

# Which sections
# --------------
# As Redis's genInfoSectionDict picks them: none named is the default
# ones; "default" adds them, "all" is every section but the modules'
# own, "everything" every one; any other name, case aside, is a section.

type Sel is Data:
  ISel{all: Bool, every: Bool, names: List<&2, String>}

def sel.defaults() -> List<&2, String>:
  ["server", "clients", "memory", "persistence", "stats", "replication", "cpu", "module_list", "errorstats", "cluster", "keyspace"]

def sel.arg(+a: String, s: Sel) -> Sel:
  match s:
    case ISel{+all, +every, +names}:
      +l = String.to_lower(a)
      Bool.pick(Sel, String.eq(l, "default"), ISel{all, every, List.append(&2, String, names, sel.defaults())},
        Bool.pick(Sel, String.eq(l, "all"), ISel{True{}, every, names},
          Bool.pick(Sel, String.eq(l, "everything"), ISel{True{}, True{}, names}, ISel{all, every, l <> names})))

def sel.go(args: List<&2, String>, s: Sel) -> Sel:
  match args:
    case Nil{}:
      s
    case Con{+a, rest}:
      sel.go(rest, sel.arg(a, s))

def sel.of(args: List<&2, String>) -> Sel:
  match args:
    case Nil{}:
      ISel{False{}, False{}, sel.defaults()}
    case Con{a, rest}:
      sel.go(Con{a, rest}, ISel{False{}, False{}, Nil{}})

def sel.has(+s: Sel, +name: String) -> Bool:
  match s:
    case ISel{all, every, +names}:
      Bool.or(all, C.text.member(names, name))

# Redis puts an empty line between sections
def join(xs: List<&2, String>, +acc: String) -> String:
  match xs:
    case Nil{}:
      acc
    case Con{+x, rest}:
      join(rest, Bool.pick(String, String.is_empty(x), acc, Bool.pick(String, String.is_empty(acc), x, acc ++ "\r\n" ++ x)))

# Each section is written only when it is picked (a match, not a
# Bool.pick, which would write them all): the keyspace's count walks the
# keys.

def on.server(on: Bool, +items: List<&2, C.CItem>, +i: Info) -> String:
  match on i:
    case True{} IInfo{+b, +l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      sec.server(items, b, l)
    case False{} _:
      ""

def on.clients(on: Bool, +items: List<&2, C.CItem>, +i: Info) -> String:
  match on i:
    case True{} IInfo{b, +l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      sec.clients(items, l)
    case False{} _:
      ""

def on.memory(on: Bool, +items: List<&2, C.CItem>, +i: Info) -> String:
  match on i:
    case True{} IInfo{+b, +l, c, inst, +pk, c0, a0, a, st, ex, rw, tm, rf}:
      sec.memory(items, b, l, pk)
    case False{} _:
      ""

def boot.heap0(+b: Boot) -> Nat:
  match b:
    case IBoot{os, pid, run, replid, exe, conf, sysmem, start, heap0}:
      heap0

def boot.replid(+b: Boot) -> String:
  match b:
    case IBoot{os, pid, run, replid, exe, conf, sysmem, start, heap0}:
      replid

# the second the server started at (since 1970)
def info.start(+i: Info) -> U32:
  match i:
    case IInfo{+b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      boot.start(b)

# a seed for the server's random numbers: its run id hashed
def info.seed(+i: Info) -> U32:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      match b:
        case IBoot{os, pid, +run, replid, exe, conf, sysmem, start, heap0}:
          String.hash(run)

def on.persistence(on: Bool, +items: List<&2, C.CItem>, +i: Info, +now: Nat) -> String:
  match on i:
    case True{} IInfo{b, l, c, inst, pk, c0, +a0, +a, st, ex, +rw, tm, +rf}:
      sec.persistence(items, rf, a0, a, rw, now)
    case False{} _:
      ""

def on.stats(on: Bool, +i: Info, +now: Nat) -> String:
  match on i:
    case True{} IInfo{b, +l, +c, +inst, pk, +c0, a0, a, +st, +ex, rw, tm, rf}:
      sec.stats.go(c, inst, Nat.sub(live.conns(l), c0), stats.total(st), exp.n(ex), ex, now)
    case False{} _:
      ""

def on.replication(on: Bool, +items: List<&2, C.CItem>, +i: Info) -> String:
  match on i:
    case True{} IInfo{+b, l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      sec.replication(items, boot.replid(b))
    case False{} _:
      ""

def on.cpu(on: Bool, +i: Info) -> String:
  match on i:
    case True{} IInfo{b, +l, c, inst, pk, c0, a0, a, st, ex, rw, tm, rf}:
      sec.cpu(l)
    case False{} _:
      ""

def on.keyspace(on: Bool, +ds: R.Ds) -> String:
  match on:
    case True{}:
      sec.keyspace(R.ds.list(ds))
    case False{}:
      ""

def on.cmdstats(on: Bool, +i: Info) -> String:
  match on i:
    case True{} IInfo{b, l, c, inst, pk, c0, a0, a, +st, ex, rw, tm, rf}:
      "# Commandstats\r\n" ++ stats.cmds(st)
    case False{} _:
      ""

def on.errstats(on: Bool, +i: Info) -> String:
  match on i:
    case True{} IInfo{b, l, c, inst, pk, c0, a0, a, +st, ex, rw, tm, rf}:
      "# Errorstats\r\n" ++ stats.errors(st)
    case False{} _:
      ""

# latencystats: each command's percentiles while latency-tracking is on
# (SLOWLOG and LATENCY, below)
def on.latstats(on: Bool, +items: List<&2, C.CItem>, +i: Info) -> String:
  match on i:
    case True{} IInfo{b, l, c, inst, pk, c0, a0, a, +st, ex, rw, tm, rf}:
      "# Latencystats\r\n" ++ lat.stats.of(String.eq(cfg(items, "latency-tracking"), "yes"), st, items)
    case False{} _:
      ""

def on.head(on: Bool, +head: String) -> String:
  match on:
    case True{}:
      head
    case False{}:
      ""

# INFO [section ...]: the text of the sections asked for
def text(args: List<&2, String>, +items: List<&2, C.CItem>, +i: Info, +ds: R.Ds) -> String:
  +s = sel.of(args)
  join([
    on.server(sel.has(s, "server"), items, i),
    on.clients(sel.has(s, "clients"), items, i),
    on.memory(sel.has(s, "memory"), items, i),
    on.persistence(sel.has(s, "persistence"), items, i, R.ds.now(ds)),
    on.stats(sel.has(s, "stats"), i, R.ds.now(ds)),
    on.replication(sel.has(s, "replication"), items, i),
    on.cpu(sel.has(s, "cpu"), i),
    on.head(Bool.or(sel.has(s, "module_list"), sel.has(s, "modules")), "# Modules\r\n"),
    on.cmdstats(sel.has(s, "commandstats"), i),
    on.errstats(sel.has(s, "errorstats"), i),
    on.latstats(sel.has(s, "latencystats"), items, i),
    on.head(sel.has(s, "cluster"), "# Cluster\r\n" ++ kv("cluster_enabled", "0")),
    on.keyspace(sel.has(s, "keyspace"), ds)], "")

# MEMORY STATS and MEMORY DOCTOR
# ------------------------------
# As Redis's memoryCommand answers them from getMemoryOverheadData, with
# the numbers INFO's memory section shows: used_memory and its peak, the
# start's bytes as the overhead, the allocator's bytes and the resident
# memory; no replication backlog, no client buffers apart (INFO's
# mem_clients_normal is 0), no AOF buffer, no scripts. Each database
# with keys is listed, its tables' overheads 0: the trie's nodes are in
# the dataset, as INFO counts them. The ratios are C floats, each
# operation rounded to a float as Redis computes them in float, and sent
# as the double the float is.

def mem.f(+n: Nat) -> F.Fl:
  F.fl.round(F.fmt.f(), False{}, F.big.of(n), F.fl.eb(), False{})

# (float)a / b, and (float)a * 100 / b
def mem.ratio(+a: Nat, +b: Nat) -> F.Fl:
  F.fl.div(F.fmt.f(), mem.f(a), mem.f(b))

def mem.pct(+a: Nat, +b: Nat) -> F.Fl:
  F.fl.div(F.fmt.f(), F.fl.mul(F.fmt.f(), mem.f(a), mem.f(100n)), mem.f(b))

def mem.dbl(x: F.Fl) -> R.Reply:
  R.RDbl{F.fl.show_g(F.fl.to(F.fmt.d(), x))}

# a - b, signed (ssize_t)
def mem.diff(+a: Nat, +b: Nat) -> R.Int:
  Bool.pick(R.Int, Nat.is_le(b, a), R.IPos{Nat.sub(a, b)}, R.INeg{Nat.sub(Nat.sub(b, a), 1n)})

def mem.keys(dbs: List<&2, R.Db>, +acc: Nat) -> Nat:
  match dbs:
    case Nil{}:
      acc
    case Con{+d, rest}:
      mem.keys(rest, Nat.add(acc, R.db.n(d)))

def mem.db(+i: Nat) -> List<&2, R.Reply>:
  [R.RBulk{"db." ++ Nat.show(i)}, R.RMap{[R.RBulk{"overhead.hashtable.main"}, R.r_int(0n), R.RBulk{"overhead.hashtable.expires"}, R.r_int(0n), R.RBulk{"overhead.hashtable.slot-to-keys"}, R.r_int(0n)]}]

def mem.dbs.if(has: Bool, +i: Nat, rest: List<&2, R.Reply>) -> List<&2, R.Reply>:
  match has:
    case True{}:
      List.append(&2, R.Reply, mem.db(i), rest)
    case False{}:
      rest

# the databases with keys (i: the first's number), before tail
def mem.dbs(dbs: List<&2, R.Db>, +i: Nat, tail: List<&2, R.Reply>) -> List<&2, R.Reply>:
  match dbs:
    case Nil{}:
      tail
    case Con{+d, rest}:
      mem.dbs.if(Nat.is_lt(0n, R.db.n(d)), i, mem.dbs(rest, 1n+i, tail))

def mem.stats.go(+used: Nat, +pk: Nat, +used0: Nat, +rss: Nat, +act: Nat, +keys: Nat, dbs: List<&2, R.Reply>) -> R.Reply:
  +data = Nat.sub(used, used0)
  +net = Bool.pick(Nat, Nat.is_lt(used0, used), Nat.sub(used, used0), 1n)
  R.RMap{List.append(&2, R.Reply, [
    R.RBulk{"peak.allocated"}, R.r_int(pk), R.RBulk{"total.allocated"}, R.r_int(used),
    R.RBulk{"startup.allocated"}, R.r_int(used0), R.RBulk{"replication.backlog"}, R.r_int(0n),
    R.RBulk{"clients.slaves"}, R.r_int(0n), R.RBulk{"clients.normal"}, R.r_int(0n),
    R.RBulk{"cluster.links"}, R.r_int(0n), R.RBulk{"aof.buffer"}, R.r_int(0n),
    R.RBulk{"lua.caches"}, R.r_int(0n), R.RBulk{"functions.caches"}, R.r_int(0n)], List.append(&2, R.Reply, dbs, [
    R.RBulk{"overhead.total"}, R.r_int(used0), R.RBulk{"keys.count"}, R.r_int(keys),
    R.RBulk{"keys.bytes-per-key"}, R.r_int(Bool.pick(Nat, Nat.is_eq(keys, 0n), 0n, Nat.div(net, Nat.max(keys, 1n)))),
    R.RBulk{"dataset.bytes"}, R.r_int(data), R.RBulk{"dataset.percentage"}, mem.dbl(mem.pct(data, net)),
    R.RBulk{"peak.percentage"}, mem.dbl(mem.pct(used, pk)),
    R.RBulk{"allocator.allocated"}, R.r_int(used), R.RBulk{"allocator.active"}, R.r_int(act),
    R.RBulk{"allocator.resident"}, R.r_int(rss),
    R.RBulk{"allocator-fragmentation.ratio"}, mem.dbl(mem.ratio(act, used)),
    R.RBulk{"allocator-fragmentation.bytes"}, R.RInt{mem.diff(act, used)},
    R.RBulk{"allocator-rss.ratio"}, mem.dbl(mem.ratio(rss, act)),
    R.RBulk{"allocator-rss.bytes"}, R.RInt{mem.diff(rss, act)},
    R.RBulk{"rss-overhead.ratio"}, mem.dbl(mem.ratio(rss, rss)), R.RBulk{"rss-overhead.bytes"}, R.r_int(0n),
    R.RBulk{"fragmentation"}, mem.dbl(mem.ratio(rss, used)),
    R.RBulk{"fragmentation.bytes"}, R.RInt{mem.diff(rss, used)}]))}

# MEMORY STATS of the server whose facts are i, its databases dbs
def mem.stats(+i: Info, +dbs: List<&2, R.Db>) -> R.Reply:
  match i:
    case IInfo{+b, +l, c, inst, +pk, c0, a0, a, st, ex, rw, tm, rf}:
      +used = live.heap(l)
      mem.stats.go(used, Nat.max(pk, used), boot.heap0(b), live.rss(l), live.act(l), mem.keys(dbs, 0n), mem.dbs(dbs, 0n, Nil{}))

# whether a float is past a double (hi, lo: its bits), as C compares them
def mem.gt(x: F.Fl, +hi: Nat, +lo: Nat) -> Bool:
  Cmp.is_gt(F.f64.cmp(F.f64.of(F.fl.to(F.fmt.d(), x)), F.F64{hi, lo}))

# MEMORY DOCTOR (getMemoryDoctorReport): under 5 MB of used_memory, the
# instance is empty; past it, a peak past 1.5 times the memory in use,
# and fragmentation past 1.4 (the resident memory to used_memory) or 1.1
# (the allocator's) with more than 10 MB of it. The other issues Redis
# looks for need what BendKV has none of (the RSS of something else than
# the heap, client buffers, replicas, scripts). The ratios are floats
# compared with the doubles 1.5, 1.4 and 1.1.
def doc.empty() -> String:
  "Hi Sam, this instance is empty or is using very little memory, my issues detector can't be used in these conditions. Please, leave for your mission on Earth and fill it with some data. The new Sam and I will be back to our programming as soon as I finished rebooting.\n"

def doc.none() -> String:
  "Hi Sam, I can't find any memory issue in your instance. I can only account for what occurs on this base.\n"

def doc.peak(on: Bool) -> String:
  match on:
    case True{}:
      " * Peak memory: In the past this instance used more than 150% the memory that is currently using. The allocator is normally not able to release memory after a peak, so you can expect to see a big fragmentation ratio, however this is actually harmless and is only due to the memory peak, and if the Redis instance Resident Set Size (RSS) is currently bigger than expected, the memory will be used as soon as you fill the Redis instance with more data. If the memory peak was only occasional and you want to try to reclaim memory, please try the MEMORY PURGE command, otherwise the only other option is to shutdown and restart the instance.\n\n"
    case False{}:
      ""

def doc.frag(on: Bool) -> String:
  match on:
    case True{}:
      " * High total RSS: This instance has a memory fragmentation and RSS overhead greater than 1.4 (this means that the Resident Set Size of the Redis process is much larger than the sum of the logical allocations Redis performed). This problem is usually due either to a large peak memory (check if there is a peak memory entry above in the report) or may result from a workload that causes the allocator to fragment memory a lot. If the problem is a large peak memory, then there is no issue. Otherwise, make sure you are using the Jemalloc allocator and not the default libc malloc. Note: The currently used allocator is \"libc\".\n\n"
    case False{}:
      ""

def doc.afrag(on: Bool) -> String:
  match on:
    case True{}:
      " * High allocator fragmentation: This instance has an allocator external fragmentation greater than 1.1. This problem is usually due either to a large peak memory (check if there is a peak memory entry above in the report) or may result from a workload that causes the allocator to fragment memory a lot. You can try enabling 'activedefrag' config option.\n\n"
    case False{}:
      ""

def doc.arss(on: Bool) -> String:
  match on:
    case True{}:
      " * High allocator RSS overhead: This instance has an RSS memory overhead is greater than 1.1 (this means that the Resident Set Size of the allocator is much larger than the sum what the allocator actually holds). This problem is usually due to a large peak memory (check if there is a peak memory entry above in the report), you can try the MEMORY PURGE command to reclaim it.\n\n"
    case False{}:
      ""

def doc.issues(any: Bool, +peak: Bool, +frag: Bool, +afrag: Bool, +arss: Bool) -> String:
  match any:
    case True{}:
      "Sam, I detected a few issues in this Redis instance memory implants:\n\n" ++ doc.peak(peak) ++ doc.frag(frag) ++ doc.afrag(afrag) ++ doc.arss(arss) ++ "I'm here to keep you safe, Sam. I want to help you.\n"
    case False{}:
      doc.none()

def doc.ten() -> Nat:
  10485760n

def doc.look(+used: Nat, +pk: Nat, +rss: Nat, +act: Nat) -> String:
  +peak = mem.gt(mem.ratio(pk, used), 1073217536n, 0n)
  +frag = Bool.and(mem.gt(mem.ratio(rss, used), 1073112678n, 1717986918n), Nat.is_lt(Nat.add(used, doc.ten()), rss))
  +afrag = Bool.and(mem.gt(mem.ratio(act, used), 1072798105n, 2576980378n), Nat.is_lt(Nat.add(used, doc.ten()), act))
  +arss = Bool.and(mem.gt(mem.ratio(rss, act), 1072798105n, 2576980378n), Nat.is_lt(Nat.add(act, doc.ten()), rss))
  doc.issues(Bool.or(Bool.or(peak, frag), Bool.or(afrag, arss)), peak, frag, afrag, arss)

def doc.of(empty: Bool, +used: Nat, +pk: Nat, +rss: Nat, +act: Nat) -> String:
  match empty:
    case True{}:
      doc.empty()
    case False{}:
      doc.look(used, pk, rss, act)

def mem.doctor(+i: Info) -> String:
  match i:
    case IInfo{b, +l, c, inst, +pk, c0, a0, a, st, ex, rw, tm, rf}:
      +used = live.heap(l)
      doc.of(Nat.is_lt(used, 5242880n), used, Nat.max(pk, used), live.rss(l), live.act(l))

# SLOWLOG and LATENCY
# -------------------
# Their replies as Redis 7.0.15 gives them (slowlogCommand, latencyCommand,
# createLatencyReport, latencyCommandGenSparkeline in latency.c, the
# sparkline of sparkline.c, fillCommandCDF), from the timing (Timing) and
# the statistics (Statistics); and INFO's latencystats
# (genRedisInfoStringLatencyStats).

def slow.bulks(xs: List<&2, String>) -> List<&2, R.Reply>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{x, rest}:
      R.RBulk{x} <> slow.bulks(rest)

def slow.entry(+e: SlowE) -> R.Reply:
  match e:
    case SlowE{+id, +at, +us, +args, +peer, +name}:
      R.RArray{[R.r_int(id), R.r_int(at), R.r_int(us), R.RArray{slow.bulks(args)}, R.RBulk{peer}, R.RBulk{name}]}

def slow.entries(+es: List<&2, SlowE>, k: Nat) -> List<&2, R.Reply>:
  match es k:
    case Con{+e, +rest} 1n+m:
      slow.entry(e) <> slow.entries(rest, m)
    case _ _:
      Nil{}

# SLOWLOG GET: the newest k entries, or all of them
def slow.get(+t: Tim, +all: Bool, +k: Nat) -> R.Reply:
  match t:
    case Tim{cf, Slow{next, +n, +es}, evs, wt}:
      R.RArray{slow.entries(es, Bool.pick(Nat, all, n, k))}
    case TimOf{+x}:
      slow.get(x, all, k)

# SLOWLOG LEN
def slow.len(+t: Tim) -> R.Reply:
  match t:
    case Tim{cf, +slow, evs, wt}:
      R.r_int(slow.n(slow))
    case TimOf{+x}:
      slow.len(x)

# LATENCY LATEST: each event, its newest sample's second and latency, and
# its highest
def lat.latest(+evs: List<&2, LatEv>) -> List<&2, R.Reply>:
  match evs:
    case Nil{}:
      Nil{}
    case Con{LatEv{+name, +max, +ss}, +rest}:
      R.RArray{[R.RBulk{name}, R.r_int(lat.t(ss)), R.r_int(lat.ms(ss)), R.r_int(max)]} <> lat.latest(rest)

# event name among evs, its name as it is (hit: whether the first is it)
def lat.find(+evs: List<&2, LatEv>, hit: Bool, +name: String) -> Maybe<&2, LatEv>:
  match evs hit:
    case Con{+e, rest} True{}:
      Some{e}
    case Con{e, +rest} False{}:
      lat.find(rest, lat.is(name, rest), name)
    case Nil{} _:
      None{}

def lat.get(+evs: List<&2, LatEv>, +name: String) -> Maybe<&2, LatEv>:
  lat.find(evs, lat.is(name, evs), name)

# LATENCY HISTORY: an event's samples, oldest first (none for an event
# not there)
def lat.hist(ss: List<&2, LatS>, acc: List<&2, R.Reply>) -> List<&2, R.Reply>:
  match ss:
    case Nil{}:
      acc
    case Con{LatS{+t, +ms}, rest}:
      lat.hist(rest, R.RArray{[R.r_int(t), R.r_int(ms)]} <> acc)

def lat.history(m: Maybe<&2, LatEv>) -> R.Reply:
  match m:
    case Some{LatEv{name, max, ss}}:
      R.RArray{lat.hist(ss, Nil{})}
    case None{}:
      R.RArray{Nil{}}

# LATENCY GRAPH: a sparkline of an event's samples, oldest first, each
# with how long ago it came under it; the lowest and highest of its
# samples, and of all time, above
def graph.label(+el: Nat) -> String:
  Bool.pick(String, Nat.is_lt(el, 60n), Nat.show(el) ++ "s",
    Bool.pick(String, Nat.is_lt(el, 3600n), Nat.show(Nat.div(el, 60n)) ++ "m",
      Bool.pick(String, Nat.is_lt(el, 86400n), Nat.show(Nat.div(el, 3600n)) ++ "h", Nat.show(Nat.div(el, 86400n)) ++ "d")))

def lat.lo(+ss: List<&2, LatS>, +acc: Nat) -> Nat:
  match ss:
    case Nil{}:
      acc
    case Con{LatS{t, +ms}, +rest}:
      lat.lo(rest, Nat.min(acc, ms))

def lat.hi(+ss: List<&2, LatS>, +acc: Nat) -> Nat:
  match ss:
    case Nil{}:
      acc
    case Con{LatS{t, +ms}, +rest}:
      lat.hi(rest, Nat.max(acc, ms))

# each sample's step, from 0 to 11 (12 steps over its range: rows of 3
# characters, 4 rows), as (int)(relval * steps) / relmax cuts it
def spark.steps(+ss: List<&2, LatS>, +lo: Nat, +rel: Nat) -> List<&2, Nat>:
  match ss:
    case Nil{}:
      Nil{}
    case Con{LatS{t, +ms}, +rest}:
      Nat.min(Nat.div(Nat.mul(Nat.sub(ms, lo), 12n), rel), 11n) <> spark.steps(rest, lo, rel)

def spark.labels(+ss: List<&2, LatS>, +now: Nat) -> List<&2, String>:
  match ss:
    case Nil{}:
      Nil{}
    case Con{LatS{+t, ms}, +rest}:
      graph.label(Nat.sub(now, t)) <> spark.labels(rest, now)

# a sample's character in row r (0 to 3, the top first): '_', 'o' and '#'
# in its own row, '|' in the rows below it (SPARKLINE_FILL)
def spark.ch.of(+c: Nat) -> String:
  match c:
    case 0n:
      "_"
    case 1n:
      "o"
    case 2n:
      "#"
    case _:
      "|"

def spark.ch(+s: Nat, +r: Nat) -> String:
  +base = Nat.mul(Nat.sub(3n, r), 3n)
  Bool.pick(String, Nat.is_lt(s, base), " ", spark.ch.of(Nat.sub(s, base)))

def spark.row(+steps: List<&2, Nat>, +r: Nat) -> String:
  match steps:
    case Nil{}:
      ""
    case Con{+s, +rest}:
      spark.ch(s, r) ++ spark.row(rest, r)

# a row of the labels: the j-th character of each, a space past its end;
# whether one has a j-th
def spark.lab(+ls: List<&2, String>, +j: Nat) -> String:
  match ls:
    case Nil{}:
      ""
    case Con{+l, +rest}:
      Bool.pick(String, Nat.is_lt(j, String.length(l)), String.take(String.drop(l, j), 1n), " ") ++ spark.lab(rest, j)

def spark.any(+ls: List<&2, String>, +j: Nat) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case Con{+l, +rest}:
      Bool.or(Nat.is_lt(j, String.length(l)), spark.any(rest, j))

def spark.labs(fuel: Nat, go: Bool, +ls: List<&2, String>, +j: Nat) -> String:
  match fuel go:
    case 1n+f True{}:
      spark.lab(ls, j) ++ "\n" ++ spark.labs(f, spark.any(ls, 1n+j), ls, 1n+j)
    case _ _:
      ""

# 80 columns at most: the four rows, a row of spaces, then the labels'
def spark.chunk(+steps: List<&2, Nat>, +ls: List<&2, String>) -> String:
  spark.row(steps, 0n) ++ "\n" ++ spark.row(steps, 1n) ++ "\n" ++ spark.row(steps, 2n) ++ "\n" ++ spark.row(steps, 3n) ++ "\n" ++
  String.repeat(" ", List.length(&2, Nat, steps)) ++ "\n" ++ spark.labs(64n, spark.any(ls, 0n), ls, 0n)

def spark.more(more: Bool, +steps: List<&2, Nat>, +ls: List<&2, String>) -> String:
  match more:
    case True{}:
      "\n" ++ spark.chunk(List.drop(&2, Nat, steps, 80n), List.drop(&2, String, ls, 80n))
    case False{}:
      ""

# the samples (oldest first, 160 at most) in chunks of 80 columns
def spark.render(+steps: List<&2, Nat>, +ls: List<&2, String>) -> String:
  spark.chunk(List.take(&2, Nat, steps, 80n), List.take(&2, String, ls, 80n)) ++ spark.more(Nat.is_lt(80n, List.length(&2, Nat, steps)), steps, ls)

def graph.of(+name: String, +max: Nat, +ss: List<&2, LatS>, +now: Nat) -> String:
  +lo = lat.lo(ss, lat.ms(ss))
  +hi = lat.hi(ss, 0n)
  name ++ " - high " ++ Nat.show(hi) ++ " ms, low " ++ Nat.show(lo) ++ " ms (all time high " ++ Nat.show(max) ++ " ms)\n" ++
  String.repeat("-", 80n) ++ "\n" ++ spark.render(spark.steps(ss, lo, Nat.max(Nat.sub(hi, lo), 1n)), spark.labels(ss, now))

def lat.graph(m: Maybe<&2, LatEv>, +arg: String, +now: Nat) -> R.Reply:
  match m:
    case Some{LatEv{+name, +max, ss}}:
      R.RVerb{graph.of(name, max, List.reverse(&2, LatS, ss), now)}
    case None{}:
      R.RError{R.no_newlines("ERR No samples available for event '" ++ arg ++ "'")}

# LATENCY DOCTOR (createLatencyReport): each event with its samples' count,
# mean and mean absolute deviation (ms, as integers), the seconds since its
# oldest per sample (a C double, "%.2f") and its highest of all time, then
# the advice its kind calls for; and the advice about the process's
# transparent huge pages (thp: AnonHugePages past 0)
def lat.sum(+ss: List<&2, LatS>, +acc: Nat) -> Nat:
  match ss:
    case Nil{}:
      acc
    case Con{LatS{t, +ms}, +rest}:
      lat.sum(rest, Nat.add(acc, ms))

def lat.dev(+ss: List<&2, LatS>, +avg: Nat, +acc: Nat) -> Nat:
  match ss:
    case Nil{}:
      acc
    case Con{LatS{t, +ms}, +rest}:
      lat.dev(rest, avg, Nat.add(acc, Bool.pick(Nat, Nat.is_le(ms, avg), Nat.sub(avg, ms), Nat.sub(ms, avg))))

def lat.oldest(+ss: List<&2, LatS>, +acc: Nat) -> Nat:
  match ss:
    case Nil{}:
      acc
    case Con{LatS{+t, ms}, +rest}:
      lat.oldest(rest, Nat.min(acc, t))

def d64.show2(r: U32 & U32) -> String:
  (h, l) = r
  F.fl.show_fix(2n, F.f64.to(F.F64{U32.to_nat(h), U32.to_nat(l)}))

def ldoc.line(+num: Nat, +name: String, +max: Nat, +ss: List<&2, LatS>, +now: Nat) -> String:
  +n = Nat.max(List.length(&2, LatS, ss), 1n)
  +avg = Nat.div(lat.sum(ss, 0n), n)
  +p = Nat.sub(now, lat.oldest(ss, lat.t(ss)))
  +period = Bool.pick(Nat, Nat.is_eq(p, 0n), 1n, p)
  Nat.show(num) ++ ". " ++ name ++ ": " ++ Nat.show(n) ++ " latency spikes (average " ++ Nat.show(avg) ++ "ms, mean deviation " ++
  Nat.show(Nat.div(lat.dev(ss, avg, 0n), n)) ++ "ms, period " ++ d64.show2(d64.div(U32.to_f64(U32.from_nat(period)), U32.to_f64(U32.from_nat(n)))) ++
  " sec). Worst all time event " ++ Nat.show(max) ++ "ms.\n"

# the advice so far: how many, and which (createLatencyReport's advise_*)
type Adv is Data:
  Adv{n: Nat, slen: Bool, stune: Bool, sinsp: Bool, sched: Bool, local: Bool, ssd: Bool, wb: Bool, disk: Bool, noapp: Bool, relax: Bool, wload: Bool, hz: Bool, large: Bool, mass: Bool, thp: Bool}

def adv.zero() -> Adv:
  Adv{0n, False{}, False{}, False{}, False{}, False{}, False{}, False{}, False{}, False{}, False{}, False{}, False{}, False{}, False{}, False{}}

# the advice an event calls for, by its name (case aside); for command,
# the slow log's: enable it (off), or log the commands the monitor sees
# (tune: its threshold past the monitor's)
def adv.ev(a: Adv, +ev: String, +off: Bool, +tune: Bool) -> Adv:
  match a:
    case Adv{n, slen, stune, sinsp, sched, local, ssd, wb, disk, noapp, relax, wload, hz, large, mass, thp}:
      +e = String.to_lower(ev)
      +cmd = String.eq(e, "command")
      +pend = String.eq(e, "aof-write-pending-fsync")
      +child = String.eq(e, "aof-write-active-child")
      +alone = String.eq(e, "aof-write-alone")
      +fst = Bool.or(String.eq(e, "aof-fstat"), String.eq(e, "rdb-unlink-temp-file"))
      +rn = Bool.or(String.eq(e, "aof-rewrite-diff-write"), String.eq(e, "aof-rename"))
      +exp = String.eq(e, "expire-cycle")
      +k = Nat.add(Nat.add(Nat.add(Bool.pick(Nat, cmd, Bool.pick(Nat, Bool.or(off, tune), 3n, 2n), 0n), Bool.pick(Nat, String.eq(e, "fast-command"), 1n, 0n)),
        Nat.add(Bool.pick(Nat, pend, 4n, 0n), Bool.pick(Nat, Bool.or(child, alone), 3n, 0n))),
        Nat.add(Nat.add(Bool.pick(Nat, String.eq(e, "aof-fsync-always"), 1n, 0n), Bool.pick(Nat, fst, 2n, 0n)),
          Nat.add(Nat.add(Bool.pick(Nat, rn, 4n, 0n), Bool.pick(Nat, exp, 2n, 0n)), Bool.pick(Nat, Bool.or(String.eq(e, "eviction-del"), String.eq(e, "eviction-cycle")), 1n, 0n))))
      Adv{Nat.add(n, k), Bool.or(slen, Bool.and(cmd, off)), Bool.or(stune, Bool.and(cmd, Bool.and(Bool.not(off), tune))), Bool.or(sinsp, cmd),
        Bool.or(sched, String.eq(e, "fast-command")), Bool.or(local, Bool.or(Bool.or(pend, alone), Bool.or(fst, rn))),
        Bool.or(ssd, Bool.or(Bool.or(pend, child), Bool.or(alone, rn))), Bool.or(wb, Bool.or(Bool.or(pend, child), Bool.or(alone, rn))),
        Bool.or(disk, Bool.or(pend, fst)), Bool.or(noapp, child), Bool.or(relax, String.eq(e, "aof-fsync-always")), Bool.or(wload, rn),
        Bool.or(hz, exp), Bool.or(large, Bool.or(Bool.or(cmd, exp), String.eq(e, "eviction-del"))), Bool.or(mass, String.eq(e, "eviction-cycle")), thp}

def adv.thp(a: Adv, +on: Bool) -> Adv:
  match a:
    case Adv{+n, slen, stune, sinsp, sched, local, ssd, wb, disk, noapp, relax, wload, hz, large, mass, thp}:
      Adv{Bool.pick(Nat, on, 1n+n, n), slen, stune, sinsp, sched, local, ssd, wb, disk, noapp, relax, wload, hz, large, mass, on}

def adv.n(+a: Adv) -> Nat:
  match a:
    case Adv{+n, slen, stune, sinsp, sched, local, ssd, wb, disk, noapp, relax, wload, hz, large, mass, thp}:
      n

def adv.if(on: Bool, +s: String) -> String:
  match on:
    case True{}:
      s
    case False{}:
      ""

# the advice, in Redis's order (thr: the monitor's threshold; always:
# appendfsync always; hz: the parameter)
def adv.text(+a: Adv, +thr: Nat, +always: Bool, +hz: Nat) -> String:
  match a:
    case Adv{n, +slen, +stune, +sinsp, +sched, +local, +ssd, +wb, +disk, +noapp, +relax, +wload, +hzs, +large, +mass, +thp}:
      "\nI have a few advices for you:\n\n" ++
      adv.if(slen, "- There are latency issues with potentially slow commands you are using. Try to enable the Slow Log Redis feature using the command 'CONFIG SET slowlog-log-slower-than " ++ Nat.show(Nat.mul(thr, 1000n)) ++ "'. If the Slow log is disabled Redis is not able to log slow commands execution for you.\n") ++
      adv.if(stune, "- Your current Slow Log configuration only logs events that are slower than your configured latency monitor threshold. Please use 'CONFIG SET slowlog-log-slower-than " ++ Nat.show(Nat.mul(thr, 1000n)) ++ "'.\n") ++
      adv.if(sinsp, "- Check your Slow Log to understand what are the commands you are running which are too slow to execute. Please check https://redis.io/commands/slowlog for more information.\n") ++
      adv.if(sched, "- The system is slow to execute Redis code paths not containing system calls. This usually means the system does not provide Redis CPU time to run for long periods. You should try to:\n  1) Lower the system load.\n  2) Use a computer / VM just for Redis if you are running other software in the same system.\n  3) Check if you have a \"noisy neighbour\" problem.\n  4) Check with 'redis-cli --intrinsic-latency 100' what is the intrinsic latency in your system.\n  5) Check if the problem is allocator-related by recompiling Redis with MALLOC=libc, if you are using Jemalloc. However this may create fragmentation problems.\n") ++
      adv.if(local, "- It is strongly advised to use local disks for persistence, especially if you are using AOF. Remote disks provided by platform-as-a-service providers are known to be slow.\n") ++
      adv.if(ssd, "- SSD disks are able to reduce fsync latency, and total time needed for snapshotting and AOF log rewriting (resulting in smaller memory usage). With extremely high write load SSD disks can be a good option. However Redis should perform reasonably with high load using normal disks. Use this advice as a last resort.\n") ++
      adv.if(wb, "- Mounting ext3/4 filesystems with data=writeback can provide a performance boost compared to data=ordered, however this mode of operation provides less guarantees, and sometimes it can happen that after a hard crash the AOF file will have a half-written command at the end and will require to be repaired before Redis restarts.\n") ++
      adv.if(disk, "- Try to lower the disk contention. This is often caused by other disk intensive processes running in the same computer (including other Redis instances).\n") ++
      adv.if(noapp, "- Assuming from the point of view of data safety this is viable in your environment, you could try to enable the 'no-appendfsync-on-rewrite' option, so that fsync will not be performed while there is a child rewriting the AOF file or producing an RDB file (the moment where there is high disk contention).\n") ++
      adv.if(Bool.and(relax, always), "- Your fsync policy is set to 'always'. It is very hard to get good performances with such a setup, if possible try to relax the fsync policy to 'onesec'.\n") ++
      adv.if(wload, "- Latency during the AOF atomic rename operation or when the final difference is flushed to the AOF file at the end of the rewrite, sometimes is caused by very high write load, causing the AOF buffer to get very large. If possible try to send less commands to accomplish the same work, or use Lua scripts to group multiple operations into a single EVALSHA call.\n") ++
      adv.if(Bool.and(hzs, Nat.is_lt(hz, 100n)), "- In order to make the Redis keys expiring process more incremental, try to set the 'hz' configuration parameter to 100 using 'CONFIG SET hz 100'.\n") ++
      adv.if(large, "- Deleting, expiring or evicting (because of maxmemory policy) large objects is a blocking operation. If you have very large objects that are often deleted, expired, or evicted, try to fragment those objects into multiple smaller objects.\n") ++
      adv.if(mass, "- Sudden changes to the 'maxmemory' setting via 'CONFIG SET', or allocation of large objects via sets or sorted sets intersections, STORE option of SORT, Redis Cluster large keys migrations (RESTORE command), may create sudden memory pressure forcing the server to block trying to evict keys. \n") ++
      adv.if(thp, "- I detected a non zero amount of anonymous huge pages used by your process. This creates very serious latency events in different conditions, especially when Redis is persisting on disk. To disable THP support use the command 'echo never > /sys/kernel/mm/transparent_hugepage/enabled', make sure to also add it into /etc/rc.local so that the command will be executed again after a reboot. Note that even if you have already disabled THP, you still need to restart the Redis process to get rid of the huge pages already created.\n")

# each event's line, numbered from num, and the advice they call for
type LDoc is Data:
  LDoc{text: String, adv: Adv}

def ldoc.events(evs: List<&2, LatEv>, +num: Nat, +now: Nat, +off: Bool, +tune: Bool, text: String, a: Adv) -> LDoc:
  match evs:
    case Nil{}:
      LDoc{text, a}
    case Con{LatEv{+name, +max, +ss}, rest}:
      ldoc.events(rest, 1n+num, now, off, tune, text ++ ldoc.line(num, name, max, ss, now), adv.ev(a, name, off, tune))

def ldoc.end(+none: Bool, +a: Adv, +thr: Nat, +always: Bool, +hz: Nat) -> String:
  Bool.pick(String, Nat.is_eq(adv.n(a), 0n),
    Bool.pick(String, none, "Dave, no latency spike was observed during the lifetime of this Redis instance, not in the slightest bit. I honestly think you ought to sit down calmly, take a stress pill, and think things over.\n", "\nWhile there are latency events logged, I'm not able to suggest any easy fix. Please use the Redis community to get some help, providing this report in your help request.\n"),
    adv.text(a, thr, always, hz))

def ldoc.fin(d: LDoc, +none: Bool, +thp: Bool, +thr: Nat, +always: Bool, +hz: Nat) -> String:
  match d:
    case LDoc{text, a}:
      +b = adv.thp(a, thp)
      text ++ ldoc.end(none, b, thr, always, hz)

def ldoc.report(+evs: List<&2, LatEv>, +cf: TCfg, +now: Nat, +thp: Bool, +always: Bool, +hz: Nat) -> String:
  +none = List.is_empty(&2, LatEv, evs)
  +off = Bool.not(tcfg.son(cf))
  ldoc.fin(ldoc.events(evs, 1n, now, off, Nat.is_lt(tcfg.lat(cf), Nat.div(tcfg.slt(cf), 1000n)), Bool.pick(String, none, "", "Dave, I have observed latency spikes in this Redis instance. You don't mind talking about it, do you Dave?\n\n"), adv.zero()), none, thp, tcfg.lat(cf), always, hz)

def ldoc.of(sorry: Bool, +evs: List<&2, LatEv>, +cf: TCfg, +now: Nat, +thp: Bool, +always: Bool, +hz: Nat) -> String:
  match sorry:
    case True{}:
      "I'm sorry, Dave, I can't do that. Latency monitoring is disabled in this Redis instance. You may use \"CONFIG SET latency-monitor-threshold <milliseconds>.\" in order to enable it. If we weren't in a deep space mission I'd suggest to take a look at https://redis.io/topics/latency-monitor.\n"
    case False{}:
      ldoc.report(evs, cf, now, thp, always, hz)

# LATENCY DOCTOR of the timing t at second now (items: the parameters)
def lat.doctor(+t: Tim, +items: List<&2, C.CItem>, +now: Nat, +thp: Bool) -> String:
  +evs = tim.evs(t)
  +cf = tim.cf(t)
  ldoc.of(Bool.and(List.is_empty(&2, LatEv, evs), Nat.is_eq(tcfg.lat(cf), 0n)), evs, cf, now, thp, String.eq(C.config.get_value(items, "appendfsync"), "always"), C.dec.small(C.config.get_value(items, "hz"), 0n))

# LATENCY HISTOGRAM (fillCommandCDF): a command's calls in its histogram,
# and the counts Redis's log iterator reports: at each level of 1024 ns
# times a power of two (index 512 + 128 j, j up to 19) and at the end of
# the counts (index 3071, past 2^29 ns), the count of the values up to
# its highest value, under that value in us, when it grew, until all are
# counted
def cdf.lvl(+j: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_lt(j, 20n), Nat.add(512n, Nat.mul(j, 128n)), 3071n)

# the counts up to index l counted, and the rest
type Cdf is Data:
  Cdf{rest: List<&2, HBin>, cum: Nat}

def cdf.in(+l: Nat, +bs: List<&2, HBin>) -> Bool:
  match bs:
    case Con{HBin{+i, n}, rest}:
      Nat.is_le(i, l)
    case Nil{}:
      False{}

def cdf.cut(bs: List<&2, HBin>, in: Bool, +l: Nat, +cum: Nat) -> Cdf:
  match bs in:
    case Con{HBin{i, +n}, +rest} True{}:
      cdf.cut(rest, cdf.in(l, rest), l, Nat.add(cum, n))
    case _ _:
      Cdf{bs, cum}

def cdf.at(+bs: List<&2, HBin>, +j: Nat, +cum: Nat) -> Cdf:
  +l = cdf.lvl(j)
  cdf.cut(bs, cdf.in(l, bs), l, cum)

def cdf.pair(grew: Bool, +j: Nat, +cum: Nat) -> List<&2, R.Reply>:
  match grew:
    case True{}:
      [R.r_int(Nat.div(hdr.high(cdf.lvl(j)), 1000n)), R.r_int(cum)]
    case False{}:
      Nil{}

# level j (go: whether the counts before it left some out), the counts
# up to it in c
def cdf.go(fuel: Nat, go: Bool, c: Cdf, +j: Nat, +prev: Nat, +total: Nat) -> List<&2, R.Reply>:
  match fuel go c:
    case 1n+f True{} Cdf{+rest, +cum}:
      List.append(&2, R.Reply, cdf.pair(Nat.is_lt(prev, cum), j, cum), cdf.go(f, Nat.is_lt(cum, total), cdf.at(rest, 1n+j, cum), 1n+j, cum, total))
    case _ _ _:
      Nil{}

def ent.cdf(+e: Ent) -> List<&2, R.Reply>:
  match e:
    case Ent{+k, calls, rej, fail, us, h}:
      +bs = ht.bins(h)
      +t = bins.total(bs, 0n)
      [R.RBulk{R.stat.name(k)}, R.RMap{[R.RBulk{"calls"}, R.r_int(t), R.RBulk{"histogram_usec"}, R.RMap{cdf.go(21n, True{}, cdf.at(bs, 0n, 0n), 0n, 0n, t)}]}]

def histo.all(+es: List<&2, Ent>) -> List<&2, R.Reply>:
  match es:
    case Nil{}:
      Nil{}
    case Con{+e, +rest}:
      List.append(&2, R.Reply, Bool.pick(List<&2, R.Reply>, ent.timed(e), ent.cdf(e), Nil{}), histo.all(rest))

# a command's entry, or a subcommand's of it when it is a container (sub:
# its name has no '|'), as Redis's lookupCommandBySds finds them
def histo.hit(+e: Ent, +name: String, +sub: Bool) -> Bool:
  +n = ent.name(e)
  Bool.and(ent.timed(e), Bool.or(String.eq(n, name), Bool.and(sub, String.starts_with(n, name ++ "|"))))

def histo.of(+es: List<&2, Ent>, +name: String, +sub: Bool) -> List<&2, R.Reply>:
  match es:
    case Nil{}:
      Nil{}
    case Con{+e, +rest}:
      List.append(&2, R.Reply, Bool.pick(List<&2, R.Reply>, histo.hit(e, name, sub), ent.cdf(e), Nil{}), histo.of(rest, name, sub))

def histo.names(+es: List<&2, Ent>, names: List<&2, String>) -> List<&2, R.Reply>:
  match names:
    case Nil{}:
      Nil{}
    case Con{x, rest}:
      +l = String.to_lower(x)
      List.append(&2, R.Reply, histo.of(es, l, Nat.is_le(String.length(l), String.find(l, '|', 0n))), histo.names(es, rest))

# LATENCY HISTOGRAM of names (none: every command with a histogram), the
# commands in the order of their names
def lat.histogram.of(+es: List<&2, Ent>, names: List<&2, String>) -> R.Reply:
  match names:
    case Nil{}:
      R.RMap{histo.all(es)}
    case Con{x, rest}:
      R.RMap{histo.names(es, Con{x, rest})}

def lat.histogram(+st: Stats, names: List<&2, String>) -> R.Reply:
  lat.histogram.of(ents.sort(stats.view(st), Nil{}), names)
