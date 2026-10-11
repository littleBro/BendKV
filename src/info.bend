# info.bend: INFO, as Redis 7.0.15 writes it (genRedisInfoString in
# server.c): its sections, picked as Redis picks them, in Redis's order,
# each with Redis's fields in Redis's order. The values are BendKV's own
# where it has them: its process, its parameters, its counts of
# connections, commands and bytes, its memory, its keys, its append-only
# file. For what it does not have (replication, forks, scripts, eviction,
# expiry, defragmentation, I/O threads) they are what Redis shows when it
# has none of it. Facts only the shell can see (the clock, the processor
# time, the memory, the connections) come in Live, gathered for a batch
# that asks for them; the counts are added a batch at a time, and the
# rates sampled every 100 ms (server.bend).

import Base
import ./map.bend as KV
import ./redis.bend as R
import ./config.bend as C

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

# Statistics per command and per error
# ------------------------------------
# As Redis 7.0.15 keeps them: for each command and subcommand (by its key,
# R.stat.key), the calls that ran, the calls refused before they ran (a
# number of arguments its arity does not allow, a client that must
# authenticate first) and the calls that ran and answered an error; for each error code (the first
# word of an error reply, as afterErrorReply takes it), how many replies
# had it; and all the error replies. A batch only puts its runs of calls
# (R.Tally) with the others not yet counted (cur, pend); they are counted
# in the entries, kept last used first, at the cron's tick (every 100 ms)
# and whenever INFO shows them, which lists them by name. BendKV does not
# time its commands: usec stays 0, and latencystats is empty.

type Ent is Data:
  Ent{key: Nat, calls: Big, rej: Big, fail: Big}

type ErrN is Data:
  ErrN{code: String, n: Big}

type Stats is Data:
  Stats{ents: List<&2, Ent>, cur: Nat, pend: List<&2, Nat>, errs: List<&2, ErrN>, total: Big}

def stats.zero() -> Stats:
  Stats{Nil{}, 0n, Nil{}, Nil{}, big.zero()}

def ent.add(e: Ent, +c: Nat, +r: Nat, +f: Nat) -> Ent:
  match e:
    case Ent{k, calls, rej, fail}:
      Ent{k, big.add(calls, c), big.add(rej, r), big.add(fail, f)}

def ent.is(+k: Nat, +es: List<&2, Ent>) -> Bool:
  match es:
    case Con{Ent{+j, calls, rej, fail}, rest}:
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
      Pick{Ent{k, big.zero(), big.zero(), big.zero()}, Nil{}}
    case Con{e, rest} True{}:
      Pick{e, rest}
    case Con{e, +rest} False{}:
      pick.keep(e, ents.pick(k, rest, ent.is(k, rest)))

def ents.front(p: Pick, +c: Nat, +r: Nat, +f: Nat) -> List<&2, Ent>:
  match p:
    case Pick{e, rest}:
      ent.add(e, c, r, f) <> rest

# what calls of key k add: c that ran, r refused, f failed; the entry
# goes first. A call of the last command used costs one comparison.
def ents.add.if(same: Bool, es: List<&2, Ent>, +k: Nat, +c: Nat, +r: Nat, +f: Nat) -> List<&2, Ent>:
  match same es:
    case True{} Con{e, rest}:
      ent.add(e, c, r, f) <> rest
    case _ _:
      ents.front(ents.pick(k, es, False{}), c, r, f)

def ents.add(+es: List<&2, Ent>, +k: Nat, +c: Nat, +r: Nat, +f: Nat) -> List<&2, Ent>:
  ents.add.if(ent.is(k, es), es, k, c, r, f)

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

# a run of calls (R.Tally): its key's entry; key 0, an unknown command
# or subcommand, has none
def stats.run.at(es: List<&2, Ent>, +key: Nat, +class: Nat, +n: Nat) -> List<&2, Ent>:
  match class:
    case 0n:
      ents.add(es, key, n, 0n, 0n)
    case 1n:
      ents.add(es, key, 0n, n, 0n)
    case _:
      ents.add(es, key, n, 0n, n)

def stats.run.if(none: Bool, es: List<&2, Ent>, +code: Nat, +n: Nat) -> List<&2, Ent>:
  match none:
    case True{}:
      es
    case False{}:
      stats.run.at(es, Nat.div(code, 4n), Nat.mod(code, 4n), n)

def stats.runs(rs: List<&2, Nat>, es: List<&2, Ent>) -> List<&2, Ent>:
  match rs:
    case Nil{}:
      es
    case Con{+r, rest}:
      +code = R.run.code(r)
      stats.runs(rest, stats.run.if(Nat.is_lt(code, 4n), es, code, R.run.n(r)))

# an error reply of a call of code k: one more of its error code, and of
# all; a call that ran (class 0) failed with it (the parser's errors are
# counted with their runs)
def stats.err.ent(ran: Bool, es: List<&2, Ent>, +k: Nat) -> List<&2, Ent>:
  match ran:
    case True{}:
      ents.add(es, Nat.div(k, 4n), 0n, 0n, 1n)
    case False{}:
      es

def stats.err(st: Stats, +k: Nat, +m: String) -> Stats:
  match st:
    case Stats{es, cur, pend, +errs, total}:
      +c = err.code(m)
      Stats{stats.err.ent(Bool.and(Nat.is_eq(Nat.mod(k, 4n), 0n), Nat.is_lt(3n, k)), es, k), cur, pend, errs.add(errs, c, errs.cmp(c, errs)), big.add(total, 1n)}

def stats.errs(xs: List<&2, R.Erred>, st: Stats) -> Stats:
  match xs:
    case Nil{}:
      st
    case Con{R.Erred{+k, +m}, rest}:
      stats.errs(rest, stats.err(st, k, m))

# a batch's runs of calls, put with those not yet counted: the run of a
# batch of one code (r, 0 for none: R.Tally) goes into the newest run of
# them (cur) when it has its code, or else takes its place, cur going
# before the others (pend); the runs of any other batch (rs) go before
# those
def stats.cur(same: Bool, es: List<&2, Ent>, +cur: Nat, +r: Nat, pend: List<&2, Nat>, errs: List<&2, ErrN>, total: Big) -> Stats:
  match same:
    case True{}:
      Stats{es, Nat.add(cur, R.run.n(r)), pend, errs, total}
    case False{}:
      Stats{es, r, cur <> pend, errs, total}

def stats.add(st: Stats, +r: Nat, rs: List<&2, Nat>) -> Stats:
  match st rs:
    case Stats{es, +cur, pend, errs, total} Nil{}:
      stats.cur(Bool.or(Nat.is_lt(r, 1n), U32.is_eq(U32.from_nat(R.run.code(cur)), U32.from_nat(R.run.code(r)))), es, cur, r, pend, errs, total)
    case Stats{es, cur, pend, errs, total} _:
      Stats{es, cur, List.reverse.go(&2, Nat, List.reverse(&2, Nat, rs), pend), errs, total}

# the runs not yet counted, the ones of one code next to each other put
# together first (a run per batch, of one command most of the time)
def runs.merge.if(same: Bool, acc: List<&2, Nat>, +k: Nat, +n: Nat) -> List<&2, Nat>:
  match same acc:
    case True{} Con{r, rest}:
      Nat.add(r, n) <> rest
    case _ _:
      R.run.of(k, n) <> acc

def runs.merge.at(+acc: List<&2, Nat>, +k: Nat, +n: Nat) -> List<&2, Nat>:
  match acc:
    case Con{+r, rest}:
      runs.merge.if(Nat.is_eq(R.run.code(r), k), acc, k, n)
    case Nil{}:
      [R.run.of(k, n)]

def runs.merge(rs: List<&2, Nat>, acc: List<&2, Nat>) -> List<&2, Nat>:
  match rs:
    case Nil{}:
      acc
    case Con{+r, rest}:
      runs.merge(rest, runs.merge.at(acc, R.run.code(r), R.run.n(r)))

def stats.fold(st: Stats) -> Stats:
  match st:
    case Stats{es, cur, pend, errs, total}:
      Stats{stats.runs(runs.merge(cur <> pend, Nil{}), es), 0n, Nil{}, errs, total}

# Commandstats and Errorstats, as INFO writes them
def ent.name(+e: Ent) -> String:
  match e:
    case Ent{+k, calls, rej, fail}:
      R.stat.name(k)

def ent.shown(+e: Ent) -> Bool:
  match e:
    case Ent{k, +calls, +rej, +fail}:
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

def ent.line(+e: Ent) -> String:
  match e:
    case Ent{+k, +calls, +rej, +fail}:
      Bool.pick(String, ent.shown(e), "cmdstat_" ++ R.stat.name(k) ++ ":calls=" ++ big.show(calls) ++ ",usec=0,usec_per_call=0.00,rejected_calls=" ++ big.show(rej) ++ ",failed_calls=" ++ big.show(fail) ++ "\r\n", "")

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
  match st:
    case Stats{+es, +cur, +pend, errs, total}:
      ents.lines(ents.sort(stats.runs(runs.merge(cur <> pend, Nil{}), es), Nil{}))

def stats.errors(+st: Stats) -> String:
  match st:
    case Stats{es, cur, pend, +errs, total}:
      errs.lines(errs)

def stats.total(+st: Stats) -> String:
  match st:
    case Stats{es, cur, pend, errs, +total}:
      big.show(total)

# Facts
# -----

# the server at its start: the operating system (as uname names it), the
# pid, the run id and the replication id (40 hex digits each), the
# program and the configuration file (absolute paths, "" for none), the
# machine's memory, the time it started (seconds since 1970) and its
# resident memory then
type Boot is Data:
  IBoot{os: String, pid: String, run: String, replid: String, exe: String, conf: String, sysmem: Nat, start: U32, rss0: Nat}

# what the shell saw last: the wall clock (seconds since 1970 and
# microseconds), the processor time of the process and of its main
# thread (user, system; clock ticks of 10 ms), the resident memory, the
# connections taken since the start and those open
type Live is Data:
  ILive{secs: U32, usec: U32, ut: Nat, st: Nat, mut: Nat, mst: Nat, rss: Nat, conns: Nat, clients: Nat}

# commands run, bytes read and bytes sent
type Count is Data:
  ICount{cmds: Big, inb: Big, outb: Big}

# Redis's instantaneous rates: the time of the last sample (ms), the
# counts then, and the last 16 samples of each rate (per second, newest
# first), one each 100 ms
type Inst is Data:
  IInst{ms: Nat, last: Count, sc: List<&2, Nat>, si: List<&2, Nat>, so: List<&2, Nat>}

# everything INFO shows that the parameters and the keys do not: the
# start, the last facts, the counts, the rates, the peak of memory, the
# connections taken before the last CONFIG RESETSTAT, the size of the
# append-only file at the start and now, and the statistics per command
# and per error
type Info is Data:
  IInfo{boot: Boot, live: Live, cnt: Count, inst: Inst, peak: Nat, conns0: Nat, aof0: Nat, aof: Nat, st: Stats}

def count.zero() -> Count:
  ICount{big.zero(), big.zero(), big.zero()}

def samples.zero() -> List<&2, Nat>:
  [0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n]

def live.ms(+l: Live) -> Nat:
  match l:
    case ILive{+secs, +usec, ut, st, mut, mst, rss, conns, clients}:
      Nat.add(Nat.mul(U32.to_nat(secs), 1000n), U32.to_nat(U32.div(usec, 1000)))

def live.rss(+l: Live) -> Nat:
  match l:
    case ILive{secs, usec, ut, st, mut, mst, rss, conns, clients}:
      rss

def live.conns(+l: Live) -> Nat:
  match l:
    case ILive{secs, usec, ut, st, mut, mst, rss, conns, clients}:
      conns

# the server's facts at its start
def info.new(b: Boot, +l: Live) -> Info:
  IInfo{b, l, count.zero(), IInst{live.ms(l), count.zero(), samples.zero(), samples.zero(), samples.zero()}, live.rss(l), 0n, 0n, 0n, stats.zero()}

# the append-only file the server restored at its start, of size bytes
def info.restored(i: Info, +size: Nat) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st}:
      IInfo{b, l, c, inst, pk, c0, size, size, st}

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
    case IInfo{b, l, c, inst, pk, c0, a0, a, st}:
      IInfo{b, l, count.add(c, calls, inb, outb), inst, pk, c0, a0, a, stats.add(st, r, rs)}

# a batch's error replies
def info.errs(i: Info, xs: List<&2, R.Erred>) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st}:
      IInfo{b, l, c, inst, pk, c0, a0, a, stats.errs(xs, st)}

# an error reply the shell sent itself (a protocol error)
def info.erred(i: Info, +m: String) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st}:
      IInfo{b, l, c, inst, pk, c0, a0, a, stats.err(st, 1n, m)}

# bytes appended to the append-only file
def info.aof(i: Info, +n: Nat) -> Info:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st}:
      IInfo{b, l, c, inst, pk, c0, a0, Nat.add(a, n), st}

# new facts from the shell; the peak of memory follows them
def info.live(i: Info, +l: Live) -> Info:
  match i:
    case IInfo{b, old, c, inst, pk, c0, a0, a, st}:
      IInfo{b, l, c, inst, Nat.max(pk, live.rss(l)), c0, a0, a, st}

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
    case IInfo{b, l, +c, inst, pk, c0, a0, a, st}:
      IInfo{b, l, c, inst.tick(inst, c, ms), pk, c0, a0, a, stats.fold(st)}

# CONFIG RESETSTAT: the counts, the rates and the statistics start again,
# as Redis's resetServerStats, resetCommandTableStats and
# resetErrorTableStats start them
def info.reset(i: Info) -> Info:
  match i:
    case IInfo{b, +l, c, inst, pk, c0, a0, a, st}:
      IInfo{b, l, count.zero(), IInst{live.ms(l), count.zero(), samples.zero(), samples.zero(), samples.zero()}, pk, live.conns(l), a0, a, stats.zero()}

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
# T and P with two decimals, B again from 1024^6 on
def human(+n: String) -> String:
  Bool.pick(String, lt(n, "1024"), n ++ "B",
  Bool.pick(String, lt(n, "1048576"), h.unit(n, 1n, "K"),
  Bool.pick(String, lt(n, "1073741824"), h.unit(n, 2n, "M"),
  Bool.pick(String, lt(n, "1099511627776"), h.unit(n, 3n, "G"),
  Bool.pick(String, lt(n, "1125899906842624"), h.unit(n, 4n, "T"),
  Bool.pick(String, lt(n, "1152921504606846976"), h.unit(n, 5n, "P"), n ++ "B"))))))

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
    case IBoot{+os, +pid, +run, +replid, +exe, +conf, sysmem, +start, rss0} ILive{+secs, +usec, ut, st, mut, mst, rss, conns, clients}:
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
    case ILive{secs, usec, ut, st, mut, mst, rss, conns, +clients}:
      "# Clients\r\n" ++ kv("connected_clients", Nat.show(clients)) ++ kv("cluster_connections", "0") ++
      kv("maxclients", cfg(items, "maxclients")) ++ kv("client_recent_max_input_buffer", "0") ++
      kv("client_recent_max_output_buffer", "0") ++ kv("blocked_clients", "0") ++ kv("tracking_clients", "0") ++
      kv("clients_in_timeout_table", "0")

# memory: what BendKV has is its resident memory; its heap keeps no
# allocator's account, so used_memory is the resident memory too, and its
# ratios are 1
def sec.memory.go(+items: List<&2, C.CItem>, +used: Nat, +pk: Nat, +rss0: Nat, +sysmem: Nat) -> String:
  +data = Nat.sub(used, rss0)
  +net = Bool.pick(Nat, Nat.is_lt(rss0, used), Nat.sub(used, rss0), 1n)
  "# Memory\r\n" ++ kv("used_memory", Nat.show(used)) ++ kv("used_memory_human", human(Nat.show(used))) ++
  kv("used_memory_rss", Nat.show(used)) ++ kv("used_memory_rss_human", human(Nat.show(used))) ++
  kv("used_memory_peak", Nat.show(pk)) ++ kv("used_memory_peak_human", human(Nat.show(pk))) ++
  kv("used_memory_peak_perc", fix2(C.dec.mul(Nat.show(used), 100n), Nat.max(pk, 1n)) ++ "%") ++
  kv("used_memory_overhead", Nat.show(rss0)) ++ kv("used_memory_startup", Nat.show(rss0)) ++
  kv("used_memory_dataset", Nat.show(data)) ++ kv("used_memory_dataset_perc", fix2(C.dec.mul(Nat.show(data), 100n), net) ++ "%") ++
  kv("allocator_allocated", Nat.show(used)) ++ kv("allocator_active", Nat.show(used)) ++ kv("allocator_resident", Nat.show(used)) ++
  kv("total_system_memory", Nat.show(sysmem)) ++ kv("total_system_memory_human", human(Nat.show(sysmem))) ++
  kv("used_memory_lua", "0") ++ kv("used_memory_vm_eval", "0") ++ kv("used_memory_lua_human", "0B") ++
  kv("used_memory_scripts_eval", "0") ++ kv("number_of_cached_scripts", "0") ++ kv("number_of_functions", "0") ++
  kv("number_of_libraries", "0") ++ kv("used_memory_vm_functions", "0") ++ kv("used_memory_vm_total", "0") ++
  kv("used_memory_vm_total_human", "0B") ++ kv("used_memory_functions", "0") ++ kv("used_memory_scripts", "0") ++
  kv("used_memory_scripts_human", "0B") ++ kv("maxmemory", signed64(cfg(items, "maxmemory"))) ++
  kv("maxmemory_human", human(cfg(items, "maxmemory"))) ++ kv("maxmemory_policy", cfg(items, "maxmemory-policy")) ++
  kv("allocator_frag_ratio", "1.00") ++ kv("allocator_frag_bytes", "0") ++ kv("allocator_rss_ratio", "1.00") ++
  kv("allocator_rss_bytes", "0") ++ kv("rss_overhead_ratio", "1.00") ++ kv("rss_overhead_bytes", "0") ++
  kv("mem_fragmentation_ratio", "1.00") ++ kv("mem_fragmentation_bytes", "0") ++ kv("mem_not_counted_for_evict", "0") ++
  kv("mem_replication_backlog", "0") ++ kv("mem_total_replication_buffers", "0") ++ kv("mem_clients_slaves", "0") ++
  kv("mem_clients_normal", "0") ++ kv("mem_cluster_links", "0") ++ kv("mem_aof_buffer", "0") ++ kv("mem_allocator", "libc") ++
  kv("active_defrag_running", "0") ++ kv("lazyfree_pending_objects", "0") ++ kv("lazyfreed_objects", "0")

def sec.memory(+items: List<&2, C.CItem>, +b: Boot, +l: Live, +pk: Nat) -> String:
  match b:
    case IBoot{os, pid, run, replid, exe, conf, +sysmem, start, +rss0}:
      sec.memory.go(items, live.rss(l), Nat.max(pk, live.rss(l)), rss0, sysmem)

def sec.aof(on: Bool, +a0: Nat, +a: Nat) -> String:
  match on:
    case True{}:
      kv("aof_current_size", Nat.show(a)) ++ kv("aof_base_size", Nat.show(a0)) ++ kv("aof_pending_rewrite", "0") ++
      kv("aof_buffer_length", "0") ++ kv("aof_pending_bio_fsync", "0") ++ kv("aof_delayed_fsync", "0")
    case False{}:
      ""

def sec.persistence(+items: List<&2, C.CItem>, +start: U32, +a0: Nat, +a: Nat) -> String:
  +on = String.eq(cfg(items, "appendonly"), "yes")
  "# Persistence\r\n" ++ kv("loading", "0") ++ kv("async_loading", "0") ++ kv("current_cow_peak", "0") ++
  kv("current_cow_size", "0") ++ kv("current_cow_size_age", "0") ++ kv("current_fork_perc", "0.00") ++
  kv("current_save_keys_processed", "0") ++ kv("current_save_keys_total", "0") ++ kv("rdb_changes_since_last_save", "0") ++
  kv("rdb_bgsave_in_progress", "0") ++ kv("rdb_last_save_time", U32.show(start)) ++ kv("rdb_last_bgsave_status", "ok") ++
  kv("rdb_last_bgsave_time_sec", "-1") ++ kv("rdb_current_bgsave_time_sec", "-1") ++ kv("rdb_saves", "0") ++
  kv("rdb_last_cow_size", "0") ++ kv("rdb_last_load_keys_expired", "0") ++ kv("rdb_last_load_keys_loaded", "0") ++
  kv("aof_enabled", flag(on)) ++ kv("aof_rewrite_in_progress", "0") ++ kv("aof_rewrite_scheduled", "0") ++
  kv("aof_last_rewrite_time_sec", "-1") ++ kv("aof_current_rewrite_time_sec", "-1") ++ kv("aof_last_bgrewrite_status", "ok") ++
  kv("aof_rewrites", "0") ++ kv("aof_rewrites_consecutive_failures", "0") ++ kv("aof_last_write_status", "ok") ++
  kv("aof_last_cow_size", "0") ++ kv("module_fork_in_progress", "0") ++ kv("module_fork_last_cow_size", "0") ++
  sec.aof(on, a0, a)

def sec.stats.go(c: Count, inst: Inst, +conns: Nat, +errs: String) -> String:
  match c inst:
    case ICount{+cmds, +inb, +outb} IInst{ms, last, +sc, +si, +so}:
      "# Stats\r\n" ++ kv("total_connections_received", Nat.show(conns)) ++ kv("total_commands_processed", big.show(cmds)) ++
      kv("instantaneous_ops_per_sec", Nat.show(mean(sc))) ++ kv("total_net_input_bytes", big.show(inb)) ++
      kv("total_net_output_bytes", big.show(outb)) ++ kv("total_net_repl_input_bytes", "0") ++
      kv("total_net_repl_output_bytes", "0") ++ kv("instantaneous_input_kbps", fix2(Nat.show(mean(si)), 1024n)) ++
      kv("instantaneous_output_kbps", fix2(Nat.show(mean(so)), 1024n)) ++ kv("instantaneous_input_repl_kbps", "0.00") ++
      kv("instantaneous_output_repl_kbps", "0.00") ++ kv("rejected_connections", "0") ++ kv("sync_full", "0") ++
      kv("sync_partial_ok", "0") ++ kv("sync_partial_err", "0") ++ kv("expired_keys", "0") ++ kv("expired_stale_perc", "0.00") ++
      kv("expired_time_cap_reached_count", "0") ++ kv("expire_cycle_cpu_milliseconds", "0") ++ kv("evicted_keys", "0") ++
      kv("evicted_clients", "0") ++ kv("total_eviction_exceeded_time", "0") ++ kv("current_eviction_exceeded_time", "0") ++
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
    case ILive{secs, usec, +ut, +st, +mut, +mst, rss, conns, clients}:
      "# CPU\r\n" ++ kv("used_cpu_sys", cpu(st)) ++ kv("used_cpu_user", cpu(ut)) ++ kv("used_cpu_sys_children", "0.000000") ++
      kv("used_cpu_user_children", "0.000000") ++ kv("used_cpu_sys_main_thread", cpu(mst)) ++ kv("used_cpu_user_main_thread", cpu(mut))

def sec.keyspace(+n: Nat, +x: Nat) -> String:
  "# Keyspace\r\n" ++ Bool.pick(String, Nat.is_lt(0n, n), "db0:keys=" ++ Nat.show(n) ++ ",expires=" ++ Nat.show(x) ++ ",avg_ttl=0\r\n", "")

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
    case True{} IInfo{+b, +l, c, inst, pk, c0, a0, a, st}:
      sec.server(items, b, l)
    case False{} _:
      ""

def on.clients(on: Bool, +items: List<&2, C.CItem>, +i: Info) -> String:
  match on i:
    case True{} IInfo{b, +l, c, inst, pk, c0, a0, a, st}:
      sec.clients(items, l)
    case False{} _:
      ""

def on.memory(on: Bool, +items: List<&2, C.CItem>, +i: Info) -> String:
  match on i:
    case True{} IInfo{+b, +l, c, inst, +pk, c0, a0, a, st}:
      sec.memory(items, b, l, pk)
    case False{} _:
      ""

def boot.start(+b: Boot) -> U32:
  match b:
    case IBoot{os, pid, run, replid, exe, conf, sysmem, start, rss0}:
      start

def boot.replid(+b: Boot) -> String:
  match b:
    case IBoot{os, pid, run, replid, exe, conf, sysmem, start, rss0}:
      replid

# a seed for the server's random numbers: its run id hashed
def info.seed(+i: Info) -> U32:
  match i:
    case IInfo{b, l, c, inst, pk, c0, a0, a, st}:
      match b:
        case IBoot{os, pid, +run, replid, exe, conf, sysmem, start, rss0}:
          String.hash(run)

def on.persistence(on: Bool, +items: List<&2, C.CItem>, +i: Info) -> String:
  match on i:
    case True{} IInfo{+b, l, c, inst, pk, c0, +a0, +a, st}:
      sec.persistence(items, boot.start(b), a0, a)
    case False{} _:
      ""

def on.stats(on: Bool, +i: Info) -> String:
  match on i:
    case True{} IInfo{b, +l, +c, +inst, pk, +c0, a0, a, +st}:
      sec.stats.go(c, inst, Nat.sub(live.conns(l), c0), stats.total(st))
    case False{} _:
      ""

def on.replication(on: Bool, +items: List<&2, C.CItem>, +i: Info) -> String:
  match on i:
    case True{} IInfo{+b, l, c, inst, pk, c0, a0, a, st}:
      sec.replication(items, boot.replid(b))
    case False{} _:
      ""

def on.cpu(on: Bool, +i: Info) -> String:
  match on i:
    case True{} IInfo{b, +l, c, inst, pk, c0, a0, a, st}:
      sec.cpu(l)
    case False{} _:
      ""

def on.keyspace(on: Bool, +db: R.Db) -> String:
  match on:
    case True{}:
      sec.keyspace(R.db.n(db), R.db.x(db))
    case False{}:
      ""

def on.cmdstats(on: Bool, +i: Info) -> String:
  match on i:
    case True{} IInfo{b, l, c, inst, pk, c0, a0, a, +st}:
      "# Commandstats\r\n" ++ stats.cmds(st)
    case False{} _:
      ""

def on.errstats(on: Bool, +i: Info) -> String:
  match on i:
    case True{} IInfo{b, l, c, inst, pk, c0, a0, a, +st}:
      "# Errorstats\r\n" ++ stats.errors(st)
    case False{} _:
      ""

def on.head(on: Bool, +head: String) -> String:
  match on:
    case True{}:
      head
    case False{}:
      ""

# INFO [section ...]: the text of the sections asked for
def text(args: List<&2, String>, +items: List<&2, C.CItem>, +i: Info, +db: R.Db) -> String:
  +s = sel.of(args)
  join([
    on.server(sel.has(s, "server"), items, i),
    on.clients(sel.has(s, "clients"), items, i),
    on.memory(sel.has(s, "memory"), items, i),
    on.persistence(sel.has(s, "persistence"), items, i),
    on.stats(sel.has(s, "stats"), i),
    on.replication(sel.has(s, "replication"), items, i),
    on.cpu(sel.has(s, "cpu"), i),
    on.head(Bool.or(sel.has(s, "module_list"), sel.has(s, "modules")), "# Modules\r\n"),
    on.cmdstats(sel.has(s, "commandstats"), i),
    on.errstats(sel.has(s, "errorstats"), i),
    on.head(sel.has(s, "latencystats"), "# Latencystats\r\n"),
    on.head(sel.has(s, "cluster"), "# Cluster\r\n" ++ kv("cluster_enabled", "0")),
    on.keyspace(sel.has(s, "keyspace"), db)], "")
