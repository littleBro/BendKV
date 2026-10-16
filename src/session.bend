# session.bend: what a connection and the server remember between
# commands, and a batch run with it. A batch's database commands run as
# exec runs them (redis.bend); the commands of the connection and of the
# server (R.Sess) run here, with the connection's state (Conn) and the
# server's (Srv), and none of them changes the database.
#
# A batch takes one of two paths. The general one (gen) takes a command
# at a time: a command after QUIT is dropped, an error the parser found is
# answered, a command of a client that must authenticate first is
# refused, a session command runs here and a database command runs with
# exec; each reply is sent or not as CLIENT REPLY says. The fast one
# (run, run_log) is for a batch of database commands only, from a
# client that has authenticated and gets every reply: the batch runs as
# the server ran every batch before there were sessions (B.exec_batch,
# A.log_batch). LAWS.bend (Sessions) shows that the fast path is the
# general one, that a batch changes the database exactly as exec_all
# runs the database commands that ran in it (plan), with the effects
# exec_log gives them, and that a client that has not authenticated runs
# none.

import Base
import ./map.bend as KV
import ./redis.bend as R
import ./batch.bend as B
import ./aof.bend as A
import ./config.bend as C
import ./info.bend as I
import ./command.bend as K
import ./float.bend as F
import ./lolwut.bend as L
import ./acl.bend as U

# Types
# -----

# which replies a connection gets (CLIENT REPLY): all, none, or none for
# the next command
type Mute is Data:
  MOn{}
  MOff{}
  MSkip{}

# a connection: its id, whether it has authenticated, its name (empty
# for none), which replies it gets, whether it has asked to close (QUIT),
# the database it selected (SELECT), and whether it speaks RESP3 (HELLO
# 3) or RESP2. The protocol changes how its replies are written (the
# server's), not which replies its commands give.
type Conn is Data:
  Conn{id: Nat, auth: Bool, name: String, mode: Mute, quit: Bool, db: Nat, r3: Bool}

# an entry of the eviction's pool (server.bend, Eviction): a key of
# database db, and its score, the higher the better a key to evict
type Pe is Data:
  Pe{score: Nat, db: Nat, key: String}

# What the server keeps for maxmemory (Memory, below), with the state of
# its random numbers (RANDOMKEY's, HRANDFIELD's, SPOP's) and its users
# (acl: ACL, below; here so that Srv stays four words): the parameters
# of maxmemory as the start and each CONFIG SET leave them (maxmemory in
# bytes, 0 for none; maxmemory-policy as a number, mm.pol.of;
# maxmemory-samples; maxmemory-eviction-tenacity; lfu-log-factor;
# lfu-decay-time), and the eviction's state (server.bend, Eviction):
# whether a CONFIG SET changed maxmemory (to one), which the actor sees to
# at once (kick), the pool (best first), the database the next random
# eviction starts after, and the bytes evicted while a rewrite of the
# append-only file runs, which its snapshot still holds (debt). MmOf,
# never built, makes Mm a type that holds itself, which the compiler makes
# a node of its own: Srv stays four words, as with the random numbers'
# word alone.
type Mm is Data:
  Mm{rng: U32, max: Nat, pol: Nat, smp: Nat, ten: Nat, lfl: Nat, lfd: Nat, kick: Bool, pool: List<&2, Pe>, next: Nat, debt: Nat, acl: U.Acl}
  MmOf{m: Mm}

# the server, besides its database: the requirepass it was last given
# (pass), its parameters (config.bend), what INFO shows of it that they
# do not (info.bend), and what it keeps for maxmemory, with its random
# numbers and its users (Mm). The users decide who must authenticate: a
# client must when the default user is off, or on without nopass; and
# requirepass is the default user's password (acl.bend)
type Srv is Data:
  Srv{pass: String, cfg: List<&2, C.CItem>, info: I.Info, mm: Mm}

def conn_new(id: Nat) -> Conn:
  Conn{id, False{}, "", MOn{}, False{}, 0n, False{}}

# Memory
# ------
# maxmemory's parameters as numbers: a number of bytes past 10^14 (100
# TB, which no heap reaches) as 10^14, so that it stays within a Nat;
# maxmemory-policy as 0 noeviction, 1 allkeys-lru, 2 volatile-lru, 3
# allkeys-lfu, 4 volatile-lfu, 5 allkeys-random, 6 volatile-random, 7
# volatile-ttl
def mm.nat.of(long: Bool, +v: String) -> Nat:
  match long:
    case True{}:
      Nat.mul(1000000000n, 100000n)
    case False{}:
      C.dec.small(v, 0n)

# (a match, not Bool.pick, which would read the long number too)
def mm.nat(+v: String) -> Nat:
  mm.nat.of(Nat.is_lt(14n, String.length(v)), v)

def mm.pol.of(+p: String) -> Nat:
  Bool.pick(Nat, String.eq(p, "allkeys-lru"), 1n,
    Bool.pick(Nat, String.eq(p, "volatile-lru"), 2n,
      Bool.pick(Nat, String.eq(p, "allkeys-lfu"), 3n,
        Bool.pick(Nat, String.eq(p, "volatile-lfu"), 4n,
          Bool.pick(Nat, String.eq(p, "allkeys-random"), 5n,
            Bool.pick(Nat, String.eq(p, "volatile-random"), 6n,
              Bool.pick(Nat, String.eq(p, "volatile-ttl"), 7n, 0n)))))))

def mm.get(+cfg: List<&2, C.CItem>, +name: String) -> Nat:
  mm.nat(C.config.get_value(cfg, name))

# what the server keeps for maxmemory with these parameters, its random
# numbers at rng, and its users: the default user alone, with requirepass
# as its password, GENPASS's key the start's secret
def mm.of(+rng: U32, +cfg: List<&2, C.CItem>, key: String) -> Mm:
  Mm{rng, mm.get(cfg, "maxmemory"), mm.pol.of(C.config.get_value(cfg, "maxmemory-policy")), mm.get(cfg, "maxmemory-samples"), mm.get(cfg, "maxmemory-eviction-tenacity"), mm.get(cfg, "lfu-log-factor"), mm.get(cfg, "lfu-decay-time"), False{}, Nil{}, 0n, 0n, U.acl.new(C.config.get_value(cfg, "requirepass"), key)}

def mm.rng(+m: Mm) -> U32:
  match m:
    case Mm{rng, max, pol, smp, ten, lfl, lfd, kick, pool, next, debt, acl}:
      rng
    case MmOf{+n}:
      mm.rng(n)

def mm.max(+m: Mm) -> Nat:
  match m:
    case Mm{rng, max, pol, smp, ten, lfl, lfd, kick, pool, next, debt, acl}:
      max
    case MmOf{+n}:
      mm.max(n)

def mm.pol(+m: Mm) -> Nat:
  match m:
    case Mm{rng, max, pol, smp, ten, lfl, lfd, kick, pool, next, debt, acl}:
      pol
    case MmOf{+n}:
      mm.pol(n)

# after CONFIG SET: the parameters read again, the random numbers and the
# eviction's state kept; a maxmemory changed to one (not 0) is to be seen
# to at once (kick), as Redis's updateMaxmemory starts its eviction; a
# requirepass changed is the default user's password from then on
def mm.cfg(+m: Mm, +cfg: List<&2, C.CItem>) -> Mm:
  match m:
    case Mm{rng, +max, pol, smp, ten, lfl, lfd, +kick, pool, next, debt, acl}:
      +mx = mm.get(cfg, "maxmemory")
      Mm{rng, mx, mm.pol.of(C.config.get_value(cfg, "maxmemory-policy")), mm.get(cfg, "maxmemory-samples"), mm.get(cfg, "maxmemory-eviction-tenacity"), mm.get(cfg, "lfu-log-factor"), mm.get(cfg, "lfu-decay-time"), Bool.and(Bool.or(kick, Bool.not(Nat.is_eq(mx, max))), Nat.is_lt(0n, mx)), pool, next, debt, U.acl.cfg(acl, C.config.get_value(cfg, "requirepass"))}
    case MmOf{+n}:
      mm.cfg(n, cfg)

# RANDOMKEY: the next state of the random numbers (a Weyl sequence, that
# KV.mix scrambles)
def mm.rand(m: Mm) -> Mm:
  match m:
    case Mm{rng, max, pol, smp, ten, lfl, lfd, kick, pool, next, debt, acl}:
      Mm{U32.add(rng, 2654435769), max, pol, smp, ten, lfl, lfd, kick, pool, next, debt, acl}
    case MmOf{n}:
      mm.rand(n)

# lfu-log-factor and lfu-decay-time
def mm.lfl(+m: Mm) -> Nat:
  match m:
    case Mm{rng, max, pol, smp, ten, lfl, lfd, kick, pool, next, debt, acl}:
      lfl
    case MmOf{+n}:
      mm.lfl(n)

def mm.lfd(+m: Mm) -> Nat:
  match m:
    case Mm{rng, max, pol, smp, ten, lfl, lfd, kick, pool, next, debt, acl}:
      lfd
    case MmOf{+n}:
      mm.lfd(n)

# whether the policy is an LFU one (allkeys-lfu, volatile-lfu)
def mm.lfu(+m: Mm) -> Bool:
  +p = mm.pol(m)
  Bool.or(Nat.is_eq(p, 3n), Nat.is_eq(p, 4n))

# whether a CONFIG SET changed maxmemory, and the eviction's debt
def mm.kick(+m: Mm) -> Bool:
  match m:
    case Mm{rng, max, pol, smp, ten, lfl, lfd, kick, pool, next, debt, acl}:
      kick
    case MmOf{+n}:
      mm.kick(n)

def mm.debt(+m: Mm) -> Nat:
  match m:
    case Mm{rng, max, pol, smp, ten, lfl, lfd, kick, pool, next, debt, acl}:
      debt
    case MmOf{+n}:
      mm.debt(n)

# what the actor does about memory, the heap's live bytes used: 0
# nothing, within maxmemory (none for 0), less the debt; 1 see to a
# CONFIG SET's change of maxmemory first; 2 evict
def mm.what(+m: Mm, +used: Nat) -> Nat:
  match m:
    case Mm{rng, +max, pol, smp, ten, lfl, lfd, +kick, pool, next, +debt, acl}:
      Bool.pick(Nat, kick, 1n, Bool.pick(Nat, Bool.and(Nat.is_lt(0n, max), Nat.is_lt(max, Nat.sub(used, debt))), 2n, 0n))
    case MmOf{+n}:
      mm.what(n, used)

# the change of maxmemory seen to
def mm.kicked(m: Mm) -> Mm:
  match m:
    case Mm{rng, max, pol, smp, ten, lfl, lfd, kick, pool, next, debt, acl}:
      Mm{rng, max, pol, smp, ten, lfl, lfd, False{}, pool, next, debt, acl}
    case MmOf{n}:
      mm.kicked(n)

def mm.smp(+m: Mm) -> Nat:
  match m:
    case Mm{rng, max, pol, smp, ten, lfl, lfd, kick, pool, next, debt, acl}:
      smp
    case MmOf{+n}:
      mm.smp(n)

def mm.ten(+m: Mm) -> Nat:
  match m:
    case Mm{rng, max, pol, smp, ten, lfl, lfd, kick, pool, next, debt, acl}:
      ten
    case MmOf{+n}:
      mm.ten(n)

def mm.next(+m: Mm) -> Nat:
  match m:
    case Mm{rng, max, pol, smp, ten, lfl, lfd, kick, pool, next, debt, acl}:
      next
    case MmOf{+n}:
      mm.next(n)

def mm.pool(+m: Mm) -> List<&2, Pe>:
  match m:
    case Mm{rng, max, pol, smp, ten, lfl, lfd, kick, pool, next, debt, acl}:
      pool
    case MmOf{+n}:
      mm.pool(n)

# the pool taken out of the eviction's state (none left in its place), so
# that a pick changes its entries in place, and the state
type Mp is Data:
  Mp{ps: List<&2, Pe>, m: Mm}

def mm.pool.take(m: Mm) -> Mp:
  match m:
    case Mm{rng, max, pol, smp, ten, lfl, lfd, kick, pool, next, debt, acl}:
      Mp{pool, Mm{rng, max, pol, smp, ten, lfl, lfd, kick, Nil{}, next, debt, acl}}
    case MmOf{x}:
      mm.pool.take(x)

# the random numbers after a pick that took n + 1 of them
def mm.step(+rng: U32, +n: Nat) -> U32:
  U32.add(rng, U32.mul(2654435769, U32.from_nat(1n+n)))

# the eviction's state after a pick from a pool (its pool after it) or at
# random (the database it picked from), of n databases
def mm.pool.set(m: Mm, ps: List<&2, Pe>, +n: Nat) -> Mm:
  match m:
    case Mm{+rng, max, pol, smp, ten, lfl, lfd, kick, pool, next, debt, acl}:
      Mm{mm.step(rng, n), max, pol, smp, ten, lfl, lfd, kick, ps, next, debt, acl}
    case MmOf{x}:
      mm.pool.set(x, ps, n)

def mm.next.set(m: Mm, +j: Nat, +n: Nat) -> Mm:
  match m:
    case Mm{+rng, max, pol, smp, ten, lfl, lfd, kick, pool, next, debt, acl}:
      Mm{mm.step(rng, n), max, pol, smp, ten, lfl, lfd, kick, pool, j, debt, acl}
    case MmOf{x}:
      mm.next.set(x, j, n)

# b bytes more of debt (a key evicted while a rewrite runs)
def mm.owe(m: Mm, +b: Nat) -> Mm:
  match m:
    case Mm{rng, max, pol, smp, ten, lfl, lfd, kick, pool, next, +debt, acl}:
      Mm{rng, max, pol, smp, ten, lfl, lfd, kick, pool, next, Nat.add(debt, b), acl}
    case MmOf{x}:
      mm.owe(x, b)

# the debt paid: the rewrite whose snapshot held what eviction freed ended
def mm.paid(m: Mm) -> Mm:
  match m:
    case Mm{rng, max, pol, smp, ten, lfl, lfd, kick, pool, next, debt, acl}:
      Mm{rng, max, pol, smp, ten, lfl, lfd, kick, pool, next, 0n, acl}
    case MmOf{n}:
      mm.paid(n)

# the users, and the server with them changed
def mm.acl(+m: Mm) -> U.Acl:
  match m:
    case Mm{rng, max, pol, smp, ten, lfl, lfd, kick, pool, next, debt, +acl}:
      acl
    case MmOf{+n}:
      mm.acl(n)

def mm.acl.set(m: Mm, a: U.Acl) -> Mm:
  match m:
    case Mm{rng, max, pol, smp, ten, lfl, lfd, kick, pool, next, debt, acl}:
      Mm{rng, max, pol, smp, ten, lfl, lfd, kick, pool, next, debt, a}
    case MmOf{n}:
      mm.acl.set(n, a)

# The users read in place, for the checks of each batch and call. A
# function that gives the users back (mm.acl, srv.acl) shares them with
# the server, and the server's next change then copies its state: the
# fast way's test that the default user is open cost a batch about 1,700
# instructions so (PERFORMANCE 70). These go down the fields and give
# back only what they read.
def mm.open(+m: Mm) -> Bool:
  match m:
    case Mm{rng, max, pol, smp, ten, lfl, lfd, kick, pool, next, debt, +acl}:
      U.acl.open(acl)
    case MmOf{+n}:
      mm.open(n)

def mm.restricted(+m: Mm, +id: Nat) -> Bool:
  match m:
    case Mm{rng, max, pol, smp, ten, lfl, lfd, kick, pool, next, debt, +acl}:
      U.acl.restricted(acl, id)
    case MmOf{+n}:
      mm.restricted(n, id)

def mm.acl.any(+m: Mm) -> Bool:
  match m:
    case Mm{rng, max, pol, smp, ten, lfl, lfd, kick, pool, next, debt, +acl}:
      U.acl.any(acl)
    case MmOf{+n}:
      mm.acl.any(n)

def mm.acl.check(+m: Mm, +n: String, +k: Nat, +argv: List<&2, String>) -> U.Verdict:
  match m:
    case Mm{rng, max, pol, smp, ten, lfl, lfd, kick, pool, next, debt, +acl}:
      U.acl.check(acl, n, k, argv)
    case MmOf{+x}:
      mm.acl.check(x, n, k, argv)

def mm.acl.sort(+m: Mm, +n: String, +k: Nat, +argv: List<&2, String>) -> Maybe<&2, String>:
  match m:
    case Mm{rng, max, pol, smp, ten, lfl, lfd, kick, pool, next, debt, +acl}:
      U.acl.sort.err(acl, n, k, argv)
    case MmOf{+x}:
      mm.acl.sort(x, n, k, argv)

# Access
# ------
# When each key was last used, for OBJECT IDLETIME and FREQ and the
# eviction's LRU and LFU, is kept outside the databases, in 2^20 words by
# the low twenty bits of a key's hash (Mem.touch and Mem.cell; the server
# marks the keys of a batch, by its hints, before the batch runs), as
# Redis keeps it in 24 bits of each value: under any policy but an LFU
# one, the second of the key's last use, its low 24 bits (acc.lru); under
# an LFU one, the minute of the last decay of its counter, its low 16
# bits, and the counter (lfu.word); with a bit of its kind above them
# (24, 25), so that a word set is never 0. A word of the other kind, after
# a change of policy, is read as Redis reads a value's 24 bits then (an
# LRU second as an LFU minute and counter, and the reverse). A word never
# set counts as a key's that was made at the server's start, never used
# since, with a counter of 5 (LFU_INIT_VAL), as Redis's values loaded at
# the start; its first use under an LFU policy gives it a counter of 5,
# as Redis gives a value it makes. Keys whose hashes have the same low
# twenty bits share a word, which no key's deletion clears: a key a
# command makes may find another key's word, but for RESTORE's, which its
# mark makes anew (server.bend, Access).

def acc.secs(+now: Nat) -> U32:
  U32.from_nat(Nat.div(now, 1000n))

# the word of a use at now (ms) under any policy but LFU
def acc.lru(+now: Nat) -> U32:
  U32.or(U32.and(acc.secs(now), 16777215), 16777216)

# the minute of now (ms), as Redis's LFUGetTimeInMinutes: its low 16 bits
def acc.min(+now: Nat) -> U32:
  U32.and(U32.from_nat(Nat.div(now, 60000n)), 65535)

def lfu.word(+min: U32, +c: U32) -> U32:
  U32.or(33554432, U32.or(U32.shln(min, 8n), c))

# the minutes from ldt to now, which wrap at 2^16 (LFUTimeElapsed)
def lfu.elapsed(+now: U32, +ldt: U32) -> U32:
  Bool.pick(U32, U32.is_le(ldt, now), U32.sub(now, ldt), U32.add(U32.sub(65535, ldt), now))

def lfu.periods(+el: Nat, +dt: Nat) -> Nat:
  match dt:
    case 0n:
      0n
    case _:
      Nat.div(el, dt)

# the counter of an LFU word decayed to the minute now, by one for each
# lfu-decay-time minutes since its last decay, none with a decay time of
# 0 (LFUDecrAndReturn)
def lfu.decr(+w: U32, +now: U32, +dt: Nat) -> U32:
  +c = U32.and(w, 255)
  +n = lfu.periods(U32.to_nat(lfu.elapsed(now, U32.and(U32.shrn(w, 8n), 65535))), dt)
  Bool.pick(U32, Nat.is_lt(U32.to_nat(c), n), 0, U32.sub(c, U32.from_nat(n)))

# a counter after a use, r a random word: up by one with a chance of
# 1/((c-5)*lfu-log-factor+1), which is 1 for a counter of 5 or less, as
# r/2^32 falls below it; 255 stays (LFULogIncr)
def lfu.incr(+c: U32, +r: U32, +lf: Nat) -> U32:
  +m = Nat.add(Nat.mul(Nat.sub(U32.to_nat(c), 5n), lf), 1n)
  Bool.pick(U32, Bool.and(U32.is_lt(c, 255), Nat.is_lt(U32.to_nat(r), Nat.div(4294967295n, m))), U32.add(c, 1), c)

# an LFU word after a use at the minute now: its counter decayed, then
# taken up (updateLFU); a word never set a new value's
def lfu.use(+w: U32, +now: U32, +r: U32, +lf: Nat, +dt: Nat) -> U32:
  Bool.pick(U32, U32.is_ne(w, 0), lfu.word(now, lfu.incr(lfu.decr(w, now, dt), r, lf)), lfu.word(now, 5))

# the LFU counter of a key's word at now (ms), the server started at
# start (s)
def acc.freq(+w: U32, +now: Nat, +start: U32, +dt: Nat) -> U32:
  lfu.decr(Bool.pick(U32, U32.is_ne(w, 0), w, lfu.word(U32.and(U32.div(start, 60), 65535), 5)), acc.min(now), dt)

# the seconds since a key's last use at now (ms): from its word's 24 bits
# to the second of now, as Redis's estimateObjectIdleTime counts them
# (past their wrap, one less: LRU_CLOCK_MAX), else since the server's
# start
def acc.idle(+w: U32, +now: Nat, +start: U32) -> Nat:
  +c = U32.and(acc.secs(now), 16777215)
  +l = U32.and(w, 16777215)
  Bool.pick(Nat, U32.is_ne(w, 0), U32.to_nat(Bool.pick(U32, U32.is_le(l, c), U32.sub(c, l), U32.sub(U32.add(c, 16777215), l))), Nat.sub(Nat.div(now, 1000n), U32.to_nat(start)))

# INFO's facts with the timing's parameters read again (info.bend,
# Timing: slowlog-log-slower-than, slowlog-max-len,
# latency-monitor-threshold, latency-tracking)
def srv.timing(i: I.Info, +cfg: List<&2, C.CItem>) -> I.Info:
  I.info.cfg(i, cfg)

# the server with these parameters: its default user's password is
# requirepass; its random numbers start from its run id
def srv_of(+cfg: List<&2, C.CItem>, info: I.Info) -> Srv:
  +i = info
  +r = I.info.seed(i)
  Srv{C.config.get_value(cfg, "requirepass"), cfg, srv.timing(i, cfg), mm.of(r, cfg, I.info.key(i))}

def srv.puts(sets: List<&2, String>, cfg: List<&2, C.CItem>) -> List<&2, C.CItem>:
  match sets:
    case Con{+n, Con{+v, rest}}:
      srv.puts(rest, C.items.put(cfg, n, v))
    case _:
      cfg

def conn.auth(+c: Conn) -> Bool:
  match c:
    case Conn{id, auth, name, mode, quit, db, r3}:
      auth

def conn.id(+c: Conn) -> Nat:
  match c:
    case Conn{id, auth, name, mode, quit, db, r3}:
      id

def conn.name(+c: Conn) -> String:
  match c:
    case Conn{id, auth, name, mode, quit, db, r3}:
      name

def conn.mode(+c: Conn) -> Mute:
  match c:
    case Conn{id, auth, name, mode, quit, db, r3}:
      mode

# the connection with every reply on (for INFO's statistics, which count
# the replies a client does not get)
def conn.on(c: Conn) -> Conn:
  match c:
    case Conn{id, auth, name, mode, quit, db, r3}:
      Conn{id, auth, name, MOn{}, quit, db, r3}

def conn.quit(+c: Conn) -> Bool:
  match c:
    case Conn{id, auth, name, mode, quit, db, r3}:
      quit

def conn.db(+c: Conn) -> Nat:
  match c:
    case Conn{id, auth, name, mode, quit, +db, r3}:
      db

# whether the connection speaks RESP3
def conn.r3(+c: Conn) -> Bool:
  match c:
    case Conn{id, auth, name, mode, quit, db, r3}:
      r3

def srv.pass(+s: Srv) -> String:
  match s:
    case Srv{pass, cfg, info, mm}:
      pass

def srv.cfg(+s: Srv) -> List<&2, C.CItem>:
  match s:
    case Srv{pass, cfg, info, mm}:
      cfg

def srv.info(+s: Srv) -> I.Info:
  match s:
    case Srv{pass, cfg, info, mm}:
      info

def srv.mm(+s: Srv) -> Mm:
  match s:
    case Srv{pass, cfg, info, mm}:
      mm

def srv.rng(+s: Srv) -> U32:
  mm.rng(srv.mm(s))

# maxmemory (0 for none)
def srv.max(+s: Srv) -> Nat:
  mm.max(srv.mm(s))

# how many databases the server has (databases, which cannot change while
# it runs)
def srv.dbs.of(v: Maybe<&2, R.Int>) -> Nat:
  match v:
    case Some{R.IPos{n}}:
      n
    case _:
      1n

def srv.dbs(+s: Srv) -> Nat:
  srv.dbs.of(R.int_read(C.config.get_value(srv.cfg(s), "databases")))

# what the shell adds to INFO's account (info.bend): a batch's calls (the
# ones that ran, and runs of codes, R.Tally), its error replies and its
# bytes, an error reply the shell sent itself, bytes appended to the
# append-only file, new facts, a sample of the rates
def srv.ran(s: Srv, +calls: Nat, +r: Nat, rs: List<&2, Nat>, +inb: Nat, +outb: Nat) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.ran(info, calls, r, rs, inb, outb), mm}

def srv.errs(s: Srv, xs: List<&2, R.Erred>) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.errs(info, xs), mm}

def srv.erred(s: Srv, +m: String) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.erred(info, m), mm}

def srv.aof(s: Srv, +n: Nat) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.aof(info, n), mm}

# the rewrite of the append-only file (info.bend: Rws): whether one runs,
# whether one is scheduled, how many failed in a row; one started at ms;
# one scheduled (BGREWRITEAOF in EXEC); the one that ran ended well at
# ms, the file of size bytes then; or failed at ms
def srv.rw.on(+s: Srv) -> Bool:
  match s:
    case Srv{pass, cfg, +info, mm}:
      I.rws.on(I.info.rw(info))

def srv.rw.sched(+s: Srv) -> Bool:
  match s:
    case Srv{pass, cfg, +info, mm}:
      I.rws.sched(I.info.rw(info))

def srv.rw.fails(+s: Srv) -> Nat:
  match s:
    case Srv{pass, cfg, +info, mm}:
      I.rws.fails(I.info.rw(info))

def srv.rw.go(s: Srv, +ms: Nat) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.rw.go(info, ms), mm}

def srv.rw.later(s: Srv) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.rw.later(info), mm}

def srv.rw.done(s: Srv, +size: Nat, +ms: Nat) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.rw.done(info, size, ms), mm.paid(mm)}

def srv.rw.failed(s: Srv, +ms: Nat) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.rw.failed(info, ms), mm.paid(mm)}

# the rewrite that runs stopped (a SHUTDOWN whose save failed)
def srv.rw.stop(s: Srv) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.rw.stop(info), mm.paid(mm)}

# The RDB file (info.bend: Rdb; server.bend: The RDB file): a SAVE
# counted as it runs; a save that ended, well or not, at the second secs;
# the keys the start loaded and those it found expired; a FLUSHALL's save
# asked for (on) or done, and whether one is; a SHUTDOWN's save, the same
def srv.rdb.save(s: Srv) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.rdb.save(info), mm}

def srv.rdb.saved(s: Srv, +well: Bool, +secs: Nat) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.rdb.saved(info, well, secs), mm}

def srv.rdb.loaded(s: Srv, +ld: Nat, +ex: Nat) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.rdb.loaded(info, ld, ex), mm}

def srv.rdb.flushed(s: Srv, +on: Bool) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.rdb.flushed(info, on), mm}

def srv.rdb.flush(+s: Srv) -> Bool:
  match s:
    case Srv{pass, cfg, +info, mm}:
      I.info.rdb.flush(info)

def srv.rdb.owed(+s: Srv) -> Bool:
  match s:
    case Srv{pass, cfg, +info, mm}:
      I.info.rdb.owed(info)

def srv.rdb.paid(s: Srv) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.rdb.paid(info), mm}

def srv.rdb.shutting(s: Srv, +on: Bool) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.rdb.shutting(info, on), mm}

def srv.rdb.shut(+s: Srv) -> Bool:
  match s:
    case Srv{pass, cfg, +info, mm}:
      I.info.rdb.shut(info)

# an eviction at now that deleted k keys and left the heap past
# maxmemory or not (over)
def srv.evicted(s: Srv, +k: Nat, +over: Bool, +now: Nat) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.evicted(info, k, over, now), mm}

def srv.debt(+s: Srv) -> Nat:
  mm.debt(srv.mm(s))

def srv.mem.what(+s: Srv, +used: Nat) -> Nat:
  match s:
    case Srv{pass, cfg, info, +mm}:
      mm.what(mm, used)

def srv.pol(+s: Srv) -> Nat:
  match s:
    case Srv{pass, cfg, info, +mm}:
      mm.pol(mm)

def srv.ten(+s: Srv) -> Nat:
  match s:
    case Srv{pass, cfg, info, +mm}:
      mm.ten(mm)

# the change of maxmemory seen to (Mm's kick)
def srv.kicked(s: Srv) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, info, mm.kicked(mm)}

# the size of the append-only file now, and after its last rewrite (or at
# the start)
def srv.aof.size(+s: Srv) -> Nat:
  match s:
    case Srv{pass, cfg, +info, mm}:
      I.info.aof.size(info)

def srv.aof.base(+s: Srv) -> Nat:
  match s:
    case Srv{pass, cfg, +info, mm}:
      I.info.aof.base(info)

def srv.live(s: Srv, l: I.Live) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.live(info, l), mm}

# the heap's used and active bytes as the actor read them
# (I.info.heap); and new facts from the shell that leave that reading as
# it is
def srv.heap(s: Srv, +h: Nat, +ac: Nat) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.heap(info, h, ac), mm}

def srv.live.held(s: Srv, l: I.Live) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.live.held(info, l), mm}

def srv.tick(s: Srv, +ms: Nat) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.tick(info, ms), mm}

# a call of code k that failed after it was counted (a blocked client
# that CLIENT UNBLOCK unblocked), and the clients that wait (INFO's
# blocked_clients) and those of them with a timeout
def srv.failed(s: Srv, +k: Nat) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.failed(info, k), mm}

def srv.blocked(s: Srv, +n: Nat, +t: Nat) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.blocked(info, n, t), mm}

# the engine's facts of scripts (server.bend, Scripts): n scripts cached,
# the Lua state's bytes (m), the cache's (c)
def srv.scripts(s: Srv, +n: Nat, +m: Nat, +c: Nat) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.scripts(info, n, m, c), mm}

# the engine's facts of functions (server.bend, Scripts): a functions in
# b libraries, the bytes of their Lua state (d) and of their records (e)
def srv.funcs(s: Srv, +a: Nat, +b: Nat, +d: Nat, +e: Nat) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.funcs(info, a, b, d, e), mm}

# the tracking's counts, for INFO (server.bend: Tracking)
def srv.tracking(s: Srv, +a: Nat, +b: Nat, +d: Nat, +e: Nat) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.tracking(info, a, b, d, e), mm}

# The timing of calls (info.bend: Timing a window): the window since the
# clock's last reading timed, with the slow log's entries it found for
# the shell to complete; the call of the general way about to run named,
# and blocking; a client served after it waited, or gone; an entry of the
# slow log
type Tw is Data:
  Tw{srv: Srv, js: List<&2, I.SlowJ>}

def srv.tw(+pass: String, cfg: List<&2, C.CItem>, t: I.Timed, mm: Mm) -> Tw:
  match t:
    case I.Timed{i, js}:
      Tw{Srv{pass, cfg, i, mm}, js}

def srv.window(s: Srv, +d: Nat, +id: Nat, raw: String, +now: Nat) -> Tw:
  match s:
    case Srv{pass, cfg, info, mm}:
      srv.tw(pass, cfg, I.info.window(info, d, id, raw, now), mm)

def srv.call(s: Srv, +id: Nat, arg: I.Arg) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.call(info, id, arg), mm}

def srv.blk(s: Srv) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.blk(info), mm}

def srv.served(s: Srv, +id: Nat) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.served(info, id), mm}

def srv.gone(s: Srv, +id: Nat) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.gone(info, id), mm}

def srv.slow(s: Srv, +us: Nat, +at: Nat, +xs: List<&2, String>, +peer: String, +name: String) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.slow(info, us, at, xs, peer, name), mm}

# a latency of ms of event name at second now, for the latency monitor
def srv.lat(s: Srv, +name: String, +ms: Nat, +now: Nat) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.lat(info, name, ms, now), mm}

# the sweep of expired keys (redis.bend: reap): where the next one starts
# in database j, and a sweep of j that stopped at next having deleted k
# keys
def srv.reap_at(+s: Srv, +j: Nat) -> Nat:
  match s:
    case Srv{pass, cfg, +info, mm}:
      I.info.reap_at(info, j)

def srv.reaped(s: Srv, +j: Nat, +next: Nat, +k: Nat) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.reaped(info, j, next, k), mm}

# Authentication
# --------------
# A client must authenticate when the server has a password: its default
# user (acl.bend) is off, or takes only its passwords. A client that has
# run a command while it needed none has authenticated, as in Redis,
# where a client is authenticated from the start when the default user is
# on and takes any password (Redis's authRequired). AUTH and HELLO's AUTH
# log a client in as a user (which the server keeps: server.bend, ACL).

# the users, and the server with them changed
def srv.acl(+s: Srv) -> U.Acl:
  mm.acl(srv.mm(s))

def srv.acl.set(s: Srv, a: U.Acl) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, info, mm.acl.set(mm, a)}

# the users read in place (mm.open): whether the default user is open,
# whether the client of id is restricted, whether some client is, a call
# of the user of name n checked, and SORT's check of its BY and GET
def srv.open(+s: Srv) -> Bool:
  match s:
    case Srv{pass, cfg, info, +mm}:
      mm.open(mm)

def srv.restricted(+s: Srv, +id: Nat) -> Bool:
  match s:
    case Srv{pass, cfg, info, +mm}:
      mm.restricted(mm, id)

def srv.acl.any(+s: Srv) -> Bool:
  match s:
    case Srv{pass, cfg, info, +mm}:
      mm.acl.any(mm)

def srv.acl.check(+s: Srv, +n: String, +k: Nat, +argv: List<&2, String>) -> U.Verdict:
  match s:
    case Srv{pass, cfg, info, +mm}:
      mm.acl.check(mm, n, k, argv)

def srv.acl.sort(+s: Srv, +n: String, +k: Nat, +argv: List<&2, String>) -> Maybe<&2, String>:
  match s:
    case Srv{pass, cfg, info, +mm}:
      mm.acl.sort(mm, n, k, argv)

# the client of id now the user of name n, among the restricted clients or
# not (acl.bend: Restricted clients), and the client of id gone
def srv.acl.client(s: Srv, +id: Nat, +n: String) -> Srv:
  +s0 = s
  srv.acl.set(s0, U.acl.client(srv.acl(s0), id, n))

def srv.acl.left(s: Srv, +id: Nat) -> Srv:
  +s0 = s
  srv.acl.set(s0, U.acl.client.gone(srv.acl(s0), id))

# a client gone (its connection's end): its counts (srv.gone), and out of
# the restricted clients
def srv.left(s: Srv, +id: Nat) -> Srv:
  srv.acl.left(srv.gone(s, id), id)

# the users ACL DELUSER removed forgotten, once the server closed their
# clients
def srv.acl.cleared(s: Srv) -> Srv:
  +s0 = s
  srv.acl.set(s0, U.acl.gone.clear(srv.acl(s0)))

# whether the server has no password: its default user is on and takes
# any password
def nopass(+s: Srv) -> Bool:
  srv.open(s)

def authed(+c: Conn, +s: Srv) -> Bool:
  Bool.or(conn.auth(c), nopass(s))

def authed.of(+auth: Bool, +s: Srv) -> Bool:
  Bool.or(auth, nopass(s))

# a client's connection as it joins the server: authenticated when there
# is no password then, as Redis's createClient sets it (it stays so after
# a password is set, until RESET)
def conn_join(+id: Nat, +s: Srv) -> Conn:
  Conn{id, nopass(s), "", MOn{}, False{}, 0n, False{}}

# whether a user takes a password: it is there, on, and takes any
# password or has this one (Redis's ACLCheckUserCredentials). AUTH's and
# HELLO's passwords come as their SHA-256 (R.parse_sess hashes them), so
# h is a hash, which the user's are compared with
def login_ok(+u: String, +h: String, +s: Srv) -> Bool:
  U.acl.login(srv.acl(s), u, h)

# whether the default user takes any password, on or off: AUTH with a
# password alone is then an error
def dflt_nopass(+s: Srv) -> Bool:
  U.acl.dflt.nopass(srv.acl(s))

def e_wrongpass() -> R.Reply:
  R.RError{"WRONGPASS invalid username-password pair or user is disabled."}

def e_noauth() -> R.Reply:
  R.RError{"NOAUTH Authentication required."}

# Replies
# -------

# a reply, sent or not as the mode says
def say(m: Mute, r: R.Reply) -> Maybe<&2, R.Reply>:
  match m:
    case MOn{}:
      Some{r}
    case MOff{}:
      None{}
    case MSkip{}:
      None{}

# the mode after a command: a skip lasts one command
def after(m: Mute) -> Mute:
  match m:
    case MSkip{}:
      MOn{}
    case MOn{}:
      MOn{}
    case MOff{}:
      MOff{}

def put(m: Maybe<&2, R.Reply>, rs: List<&2, R.Reply>) -> List<&2, R.Reply>:
  match m:
    case Some{r}:
      r <> rs
    case None{}:
      rs

# the connection after a command that leaves it as it is: its mode one
# command on. Whether it authenticated changes only as Redis's does: at
# its start and at RESET (authenticated when there is no password then,
# conn_join, reset.conn), and by AUTH or HELLO
def step_conn(+c: Conn, +s: Srv) -> Conn:
  match c:
    case Conn{id, auth, name, mode, quit, db, r3}:
      Conn{id, auth, name, after(mode), quit, db, r3}

# Session commands
# ----------------

# whether a name is fit for a client: every byte from '!' to '~', as
# Redis requires, so that a list of clients splits on spaces
def name_ok(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{Chr{+x}, t}:
      Bool.and(Bool.and(U32.is_ge(x, 33), U32.is_le(x, 126)), name_ok(t))

def e_name() -> R.Reply:
  R.RError{"ERR Client names cannot contain spaces, newlines or special characters."}

# the user an AUTH logs its client in as (LgIn), or tries and fails as
# (LgFail: WRONGPASS, which the ACL LOG counts); none for its other errors
type Login is Data:
  LgIn{user: String}
  LgFail{user: String}
  LgNone{}

def login.of(ok: Bool, +u: String) -> Login:
  match ok:
    case True{}:
      LgIn{u}
    case False{}:
      LgFail{u}

# HELLO [protover [AUTH user pass] [SETNAME name]]: the protocol (2 or
# 3; none keeps the one there is), then the options, in order; each one
# done stays done when a later one fails, as in Redis. The protocol
# changes only when HELLO answers (helloCommand sets it last), and its
# reply is in the protocol it changes to: a map of the server, as Redis
# 7.0.15 describes itself.

# what HELLO's options are doing: waiting for an option, the user of an
# AUTH, its password, or the name of a SETNAME; or failed
type Want is Data:
  WOpt{}
  WUser{}
  WPass{user: String}
  WName{}
  WFail{r: R.Reply}

# the state of a HELLO: what it waits for, the connection's
# authentication and name, the protocol it asks for (RESP3 or not), and
# what its AUTHs did, the last first (an AUTH that fails is the last)
type Hel is Data:
  Hel{w: Want, auth: Bool, name: String, r3: Bool, who: List<&2, Login>}

def hello.opt(a: String, auth: Bool, name: String, r3: Bool, who: List<&2, Login>, au: Bool, sn: Bool) -> Hel:
  match au sn:
    case True{} _:
      Hel{WUser{}, auth, name, r3, who}
    case False{} True{}:
      Hel{WName{}, auth, name, r3, who}
    case False{} False{}:
      Hel{WFail{R.RError{R.e_fmt("ERR Syntax error in HELLO option '" ++ R.cstr(a) ++ "'")}}, auth, name, r3, who}

def hello.pass(ok: Bool, auth: Bool, name: String, r3: Bool, who: List<&2, Login>, +u: String) -> Hel:
  match ok:
    case True{}:
      Hel{WOpt{}, True{}, name, r3, LgIn{u} <> who}
    case False{}:
      Hel{WFail{e_wrongpass()}, auth, name, r3, LgFail{u} <> who}

def hello.name(ok: Bool, auth: Bool, name: String, n: String, r3: Bool, who: List<&2, Login>) -> Hel:
  match ok:
    case True{}:
      Hel{WOpt{}, auth, n, r3, who}
    case False{}:
      Hel{WFail{e_name()}, auth, name, r3, who}

# one argument of HELLO's options, n the number of those after it
def hello.step(+s: Srv, h: Hel, +a: String, +n: Nat) -> Hel:
  match h:
    case Hel{WOpt{}, auth, name, r3, who}:
      hello.opt(a, auth, name, r3, who, Bool.and(R.is_word(a, "AUTH"), Nat.is_le(2n, n)), Bool.and(R.is_word(a, "SETNAME"), Nat.is_le(1n, n)))
    case Hel{WUser{}, auth, name, r3, who}:
      Hel{WPass{a}, auth, name, r3, who}
    case Hel{WPass{+u}, auth, name, r3, who}:
      hello.pass(login_ok(u, a, s), auth, name, r3, who, u)
    case Hel{WName{}, auth, name, r3, who}:
      hello.name(name_ok(a), auth, name, a, r3, who)
    case Hel{WFail{r}, auth, name, r3, who}:
      Hel{WFail{r}, auth, name, r3, who}

# HELLO's options from args on, n of them
def hello.go(+s: Srv, +args: List<&2, String>, +n: Nat, h: Hel) -> Hel:
  match args:
    case Nil{}:
      h
    case Con{+a, +rest}:
      hello.go(s, rest, Nat.sub(n, 1n), hello.step(s, h, a, Nat.sub(n, 1n)))

def hello.opts(+s: Srv, +opts: List<&2, String>, h: Hel) -> Hel:
  hello.go(s, opts, List.length(&2, String, opts), h)

# HELLO's reply: the server, as Redis 7.0.15 describes itself, in the
# protocol it switched to
def hello.map(id: Nat, r3: Bool) -> R.Reply:
  R.RMap{[R.RBulk{"server"}, R.RBulk{"redis"}, R.RBulk{"version"}, R.RBulk{"7.0.15"}, R.RBulk{"proto"}, R.r_int(Bool.pick(Nat, r3, 3n, 2n)), R.RBulk{"id"}, R.r_int(id), R.RBulk{"mode"}, R.RBulk{"standalone"}, R.RBulk{"role"}, R.RBulk{"master"}, R.RBulk{"modules"}, R.RArray{Nil{}}]}

def hello.fin(h: Hel, id: Nat, nopass: Bool) -> R.Reply:
  match h:
    case Hel{WFail{r}, auth, name, r3, who}:
      r
    case Hel{w, auth, name, r3, who}:
      Bool.pick(R.Reply, Bool.or(auth, nopass), hello.map(id, r3), R.RError{"NOAUTH HELLO must be called with the client already authenticated, otherwise the HELLO AUTH <user> <pass> option can be used to authenticate the client and select the RESP protocol version at the same time"})

# the protocol version, a long long as Redis reads one: none, 2, 3, or
# the reply that refuses it; a version is whether it is 3
type Ver is Data:
  VerNone{}
  VerOk{r3: Bool}
  VerBad{r: R.Reply}

def hello.ver(l: R.LL) -> Ver:
  match l:
    case R.LL{+neg, +hi, +lo}:
      Bool.pick(Ver, Bool.and(Bool.not(neg), Bool.and(Nat.is_eq(hi, 0n), Bool.or(Nat.is_eq(lo, 2n), Nat.is_eq(lo, 3n)))), VerOk{Nat.is_eq(lo, 3n)}, VerBad{R.RError{"NOPROTO unsupported protocol version"}})
    case R.LLBad{}:
      VerBad{R.RError{"ERR Protocol version is not an integer or out of range"}}

# HELLO's options after its version, and the version
def hello.args(args: List<&2, String>) -> Ver & List<&2, String>:
  match args:
    case Nil{}:
      (VerNone{}, Nil{})
    case Con{+v, rest}:
      (hello.ver(R.ll.read(v)), rest)

def hello.run.if(+s: Srv, +c: Conn, v: Ver, opts: List<&2, String>) -> Hel:
  match v:
    case VerBad{r}:
      Hel{WFail{r}, conn.auth(c), conn.name(c), conn.r3(c), Nil{}}
    case VerOk{r3}:
      hello.opts(s, opts, Hel{WOpt{}, conn.auth(c), conn.name(c), r3, Nil{}})
    case VerNone{}:
      hello.opts(s, opts, Hel{WOpt{}, conn.auth(c), conn.name(c), conn.r3(c), Nil{}})

def hello.run.of(+s: Srv, +c: Conn, p: Ver & List<&2, String>) -> Hel:
  (v, opts) = p
  hello.run.if(s, c, v, opts)

def hello.run(+s: Srv, +c: Conn, args: List<&2, String>) -> Hel:
  hello.run.of(s, c, hello.args(args))

# the connection after a HELLO: authenticated if an AUTH of it was, or
# if it was already, named as its SETNAME said, and in the protocol it
# asked for if it answers (no option failed, and the client is
# authenticated: hello.fin)
def hello.ok(+w: Want, +auth: Bool, +s: Srv) -> Bool:
  match w:
    case WFail{r}:
      False{}
    case _:
      authed.of(auth, s)

def hello.conn(h: Hel, +c: Conn, +s: Srv) -> Conn:
  match h c:
    case Hel{+w, auth, name, h3, who} Conn{id, a, n, mode, quit, db, r3}:
      +au = Bool.or(auth, a)
      Conn{id, au, name, after(mode), quit, db, Bool.pick(Bool, hello.ok(w, au, s), h3, r3)}

# what a HELLO's AUTHs did, the last first: the server logs its client in
# as the user of the last that did, and the ACL LOG counts one that
# failed (server.bend, ACL)
def hello.who(h: Hel) -> List<&2, Login>:
  match h:
    case Hel{w, auth, name, r3, who}:
      who

def hello.logins(+s: Srv, +c: Conn, args: List<&2, String>) -> List<&2, Login>:
  hello.who(hello.run(s, c, args))

# AUTH [user] password
def auth.one(nopass: Bool, ok: Bool) -> R.Reply:
  match nopass:
    case True{}:
      R.RError{"ERR AUTH <password> called without any password configured for the default user. Are you sure your configuration is correct?"}
    case False{}:
      Bool.pick(R.Reply, ok, R.r_ok(), e_wrongpass())

def auth.reply(+args: List<&2, String>, +s: Srv) -> R.Reply:
  match args:
    case Con{+p, Nil{}}:
      auth.one(dflt_nopass(s), login_ok("default", p, s))
    case Con{+u, Con{+p, Nil{}}}:
      Bool.pick(R.Reply, login_ok(u, p, s), R.r_ok(), e_wrongpass())
    case _:
      R.RError{"ERR syntax error"}

def auth.ok(+args: List<&2, String>, +s: Srv) -> Bool:
  match args:
    case Con{+p, Nil{}}:
      Bool.and(Bool.not(dflt_nopass(s)), login_ok("default", p, s))
    case Con{+u, Con{+p, Nil{}}}:
      login_ok(u, p, s)
    case _:
      False{}

def auth.conn(ok: Bool, +c: Conn, +s: Srv) -> Conn:
  match ok c:
    case True{} Conn{id, a, name, mode, quit, db, r3}:
      Conn{id, True{}, name, after(mode), quit, db, r3}
    case False{} c0:
      step_conn(c0, s)

def auth.login(+args: List<&2, String>, +s: Srv) -> Login:
  match args:
    case Con{+p, Nil{}}:
      Bool.pick(Login, dflt_nopass(s), LgNone{}, login.of(login_ok("default", p, s), "default"))
    case Con{+u, Con{+p, Nil{}}}:
      login.of(login_ok(u, p, s), u)
    case _:
      LgNone{}

# Blocking commands
# -----------------
# BLPOP, BRPOP, BRPOPLPUSH, BLMOVE, BLMPOP, BZPOPMIN, BZPOPMAX and BZMPOP
# (R.SBlock: the command's number and its arguments), read as Redis reads
# them, are the pop each makes once a key it waits on has elements: LMPOP
# of the keys (BLPOP and BRPOP pop one element and answer [key, element],
# form 1), LMOVE (BRPOPLPUSH, BLMOVE: a move from the source alone) or
# ZMPOP (BZPOPMIN and BZPOPMAX: [key, member, score], form 2), and the
# timeout in ms (a big integer, F's; 0 waits for ever). A session runs
# the pop once: a key with elements answers as the blocking command
# answers, and none as it answers a client that may not wait (a null
# array; a null for BRPOPLPUSH and BLMOVE, as LMOVE answers). The server
# makes such a client wait instead (server.bend, Blocked clients): it runs
# the same pop again once a write gives one of the keys elements, or
# answers a null array when the time is up. A client the server holds
# back while clients are paused waits as BlkPause (server.bend, The
# pause), which no key serves and no time ends. WAIT, which asks for
# acknowledgements no replica will send, waits as BlkWait for its timeout
# (in ms, the parser's: R.wait.of), which no key serves either; it
# answers 0, as Redis answers when no replica acknowledged, at once in
# MULTI and when its time is up. A client whose script, or SCRIPT LOAD,
# EXISTS or FLUSH, the server's engine runs waits as BlkScript (server.bend,
# Scripts), which no key serves and no time ends either: the server
# answers it when the engine is done, its replies before the command held
# until then (rs, newest first), as Redis writes a script's caller's
# replies once the script ends.
type Blk is Data:
  BlkPop{c: R.Cmd, form: Nat, ms: List<&2, Nat>}
  BlkBad{r: R.Reply}
  BlkPause{}
  BlkWait{ms: List<&2, Nat>}
  BlkScript{rs: List<&2, R.Reply>}

# The timeout, as getTimeoutFromObjectOrReply reads one in seconds: a
# long double as string2ld reads it, times 1000 (rounded as x87 rounds),
# up to the next integer (ceill), as a long long, which x87 makes its
# least (negative) for any number past its range, an infinity too.
type Tmo is Data:
  TmoMs{ms: List<&2, Nat>}
  TmoBad{r: R.Reply}

def blk.k1000() -> F.Fl:
  F.FNum{False{}, F.big.of(1000n), F.fl.eb()}

# |x| = m * 2^(e - eb) cut to an integer, and whether bits were cut
def blk.int.if(up: Bool, +m: List<&2, Nat>, +e: Nat) -> List<&2, Nat> & Bool:
  match up:
    case True{}:
      (F.big.shl(m, Nat.sub(e, F.fl.eb())), False{})
    case False{}:
      +sh = Nat.sub(F.fl.eb(), e)
      (F.big.shr(m, sh), F.big.low_nz(m, sh))

# a positive count of ms, a long long below 2^63
def blk.ms.pos(+n: List<&2, Nat>) -> Maybe<&2, List<&2, Nat>>:
  Bool.pick(Maybe<&2, List<&2, Nat>>, Nat.is_le(F.big.bitlen(n), 63n), Some{n}, None{})

# ceill of a negative number is its integer part (-0 is 0, no error)
def blk.ms.neg(p: List<&2, Nat> & Bool) -> Maybe<&2, List<&2, Nat>>:
  (+n, cut) = p
  Bool.pick(Maybe<&2, List<&2, Nat>>, F.big.is_zero(n), Some{Nil{}}, None{})

def blk.ms.up(p: List<&2, Nat> & Bool) -> Maybe<&2, List<&2, Nat>>:
  (+n, cut) = p
  blk.ms.pos(Bool.pick(List<&2, Nat>, cut, F.big.add(n, F.big.of(1n)), n))

def blk.ms.of(neg: Bool, p: List<&2, Nat> & Bool) -> Maybe<&2, List<&2, Nat>>:
  match neg:
    case True{}:
      blk.ms.neg(p)
    case False{}:
      blk.ms.up(p)

# (long long) ceill(x): the ms, or None for a negative long long
def blk.ll(x: F.Fl) -> Maybe<&2, List<&2, Nat>>:
  match x:
    case F.FNum{+neg, +m, +e}:
      blk.ms.of(neg, blk.int.if(Nat.is_le(F.fl.eb(), e), m, e))
    case F.FInf{neg}:
      None{}
    case F.FNaN{}:
      None{}

def blk.tmo.ms(m: Maybe<&2, List<&2, Nat>>) -> Tmo:
  match m:
    case Some{ms}:
      TmoMs{ms}
    case None{}:
      TmoBad{R.RError{"ERR timeout is negative"}}

def blk.tmo.of(m: Maybe<&2, F.Fl>) -> Tmo:
  match m:
    case Some{v}:
      blk.tmo.ms(blk.ll(F.fl.mul(F.fmt.ld(), v, blk.k1000())))
    case None{}:
      TmoBad{R.RError{"ERR timeout is not a float or out of range"}}

def blk.tmo(+s: String) -> Tmo:
  blk.tmo.of(F.ld.parse(s))

# the pop c with the timeout t, or t's error
def blk.with(t: Tmo, c: R.Cmd, +form: Nat) -> Blk:
  match t:
    case TmoMs{ms}:
      BlkPop{c, form, ms}
    case TmoBad{r}:
      BlkBad{r}

# a pop of LMPOP's or ZMPOP's parse, its timeout read after its other
# arguments (BLMPOP, BZMPOP), as Redis reads them
def blk.mpop(c: R.Cmd, +t: String) -> Blk:
  match c:
    case R.Bad{r}:
      BlkBad{r}
    case _:
      blk.with(blk.tmo(t), c, 0n)

# the arguments' last (the timeout) and the others before it, in order
def blk.last.go(xs: List<&2, String>, acc: List<&2, String>) -> List<&2, String> & String:
  match xs:
    case Nil{}:
      (List.reverse(&2, String, acc), "")
    case Con{x, Nil{}}:
      (List.reverse(&2, String, acc), x)
    case Con{x, rest}:
      blk.last.go(rest, x <> acc)

# BLPOP, BRPOP (keys, then the timeout): LMPOP of a count of 1; BZPOPMIN,
# BZPOPMAX: ZMPOP of a count of 1
def blk.keys.list(p: List<&2, String> & String, +left: Bool) -> Blk:
  (ks, +t) = p
  blk.with(blk.tmo(t), R.LMPop{ks, left, "1"}, 1n)

def blk.keys.zset(p: List<&2, String> & String, +max: Bool) -> Blk:
  (ks, +t) = p
  blk.with(blk.tmo(t), R.ZMPop{ks, max, "1"}, 2n)

# BLMOVE src dst from to timeout: the ends first, then the timeout
def blk.move(m: Maybe<&2, R.LEnds>, s: String, d: String, +t: String) -> Blk:
  match m:
    case Some{e}:
      blk.with(blk.tmo(t), R.LMove{s, d, e}, 0n)
    case None{}:
      BlkBad{R.RError{"ERR syntax error"}}

# WAIT's timeout, a long long the parser read (R.wait.of), as ms: its
# magnitude hi * 10^9 + lo
def blk.wait(l: R.LL) -> Blk:
  match l:
    case R.LL{neg, +hi, +lo}:
      BlkWait{F.big.add(F.big.mul_small(F.big.mul_small(F.big.of(hi), 1000n, 0n), 1000000n, 0n), F.big.of(lo))}
    case R.LLBad{}:
      BlkBad{R.RError{"ERR timeout is not an integer or out of range"}}

# a blocking command's pop, its arguments read as Redis reads them (their
# number checked by the parser)
def blk.parse(+id: Nat, args: List<&2, String>) -> Blk:
  match id args:
    case 186n Con{n, Con{+t, rest}}:
      blk.wait(R.ll.read(t))
    case 155n Con{s, Con{d, Con{+t, rest}}}:
      blk.with(blk.tmo(t), R.LMove{s, d, R.RtoL{}}, 0n)
    case 156n Con{s, Con{d, Con{+a, Con{+b, Con{+t, rest}}}}}:
      blk.move(R.lends.of(R.lend.word(a), R.lend.word(b)), s, d, t)
    case 157n Con{+t, rest}:
      blk.mpop(R.parse_lmpop(rest), t)
    case 160n Con{+t, rest}:
      blk.mpop(R.parse_zmpop(rest), t)
    case 153n xs:
      blk.keys.list(blk.last.go(xs, Nil{}), True{})
    case 154n xs:
      blk.keys.list(blk.last.go(xs, Nil{}), False{})
    case 158n xs:
      blk.keys.zset(blk.last.go(xs, Nil{}), False{})
    case 159n xs:
      blk.keys.zset(blk.last.go(xs, Nil{}), True{})
    case _ _:
      BlkBad{R.RError{"ERR syntax error"}}

# a reply's array, or nothing; its first and second item
def blk.items(r: R.Reply) -> List<&2, R.Reply>:
  match r:
    case R.RArray{xs}:
      xs
    case _:
      Nil{}

def blk.at0(xs: List<&2, R.Reply>) -> R.Reply:
  match xs:
    case Con{x, rest}:
      x
    case Nil{}:
      R.RNull{}

def blk.at1(xs: List<&2, R.Reply>) -> R.Reply:
  match xs:
    case Con{x, rest}:
      blk.at0(rest)
    case Nil{}:
      R.RNull{}

# [key, element] of LMPOP's [key, [element]]; [key, member, score] of
# ZMPOP's [key, [[member, score]]]
def blk.flat1(+xs: List<&2, R.Reply>) -> R.Reply:
  R.RArray{[blk.at0(xs), blk.at0(blk.items(blk.at1(xs)))]}

def blk.flat2(+xs: List<&2, R.Reply>) -> R.Reply:
  +e = blk.items(blk.at0(blk.items(blk.at1(xs))))
  R.RArray{[blk.at0(xs), blk.at0(e), blk.at1(e)]}

def blk.shape.arr(+form: Nat, +xs: List<&2, R.Reply>) -> R.Reply:
  match form:
    case 1n:
      blk.flat1(xs)
    case 2n:
      blk.flat2(xs)
    case _:
      R.RArray{xs}

# a blocking command's reply made of its pop's (form): a null or an error
# as it is
def blk.shape(+form: Nat, r: R.Reply) -> R.Reply:
  match r:
    case R.RArray{+xs}:
      blk.shape.arr(form, xs)
    case R.RStatus{x}:
      R.RStatus{x}
    case R.RError{x}:
      R.RError{x}
    case R.RInt{i}:
      R.RInt{i}
    case R.RBulk{x}:
      R.RBulk{x}
    case R.RNull{}:
      R.RNull{}
    case R.RIntS{x}:
      R.RIntS{x}
    case R.RNullA{}:
      R.RNullA{}
    case R.RDbl{x}:
      R.RDbl{x}
    case R.RMap{xs}:
      R.RMap{xs}
    case R.RSet{xs}:
      R.RSet{xs}
    case R.RPairs{xs}:
      R.RPairs{xs}
    case R.RPair{xs}:
      R.RPair{xs}
    case R.RVerb{x}:
      R.RVerb{x}
    case R.RPush{xs}:
      R.RPush{xs}
    case R.RSw{p, xs}:
      R.RSw{p, xs}
    case R.RRaw{x}:
      R.RRaw{x}

# the pop run once on db: its reply as the blocking command's
def blk.reply(b: Blk, db: R.Db) -> R.Reply:
  match b:
    case BlkPop{c, +form, ms}:
      blk.shape(form, R.reply_of(R.exec(c, db)))
    case BlkBad{r}:
      r
    case BlkPause{}:
      R.RNullA{}
    case BlkWait{ms}:
      R.RInt{R.IPos{0n}}
    case BlkScript{rs}:
      R.RNullA{}

# the reply of a client whose time is up, or that CLIENT UNBLOCK unblocks
# without an error, as Redis's replyToBlockedClientTimedOut: a null array
# for a pop, and for WAIT the replicas that acknowledged, none
def blk.late(+b: Blk) -> R.Reply:
  match b:
    case BlkWait{ms}:
      R.RInt{R.IPos{0n}}
    case _:
      R.RNullA{}

def blk.acts(b: Blk) -> List<&2, R.Act>:
  match b:
    case BlkPop{c, form, ms}:
      [R.ARun{c}]
    case _:
      Nil{}

# whether the pop finds nothing on db: its reply a null (an array for
# LMPOP and ZMPOP, a null for LMOVE); an error is an answer
def blk.none(r: R.Reply) -> Bool:
  match r:
    case R.RNullA{}:
      True{}
    case R.RNull{}:
      True{}
    case _:
      False{}

# whether a blocking command would wait on db: it reads, and finds
# nothing (server.bend)
def blk.waits(b: Blk, db: R.Db) -> Bool:
  match b:
    case BlkPop{c, form, ms}:
      blk.none(R.reply_of(R.exec(c, db)))
    case BlkWait{ms}:
      True{}
    case BlkScript{rs}:
      True{}
    case _:
      False{}

# the keys a blocking command waits on: LMPOP's and ZMPOP's, LMOVE's
# source
def blk.keys(b: Blk) -> List<&2, String>:
  match b:
    case BlkPop{R.LMPop{ks, left, n}, form, ms}:
      ks
    case BlkPop{R.ZMPop{ks, max, n}, form, ms}:
      ks
    case BlkPop{R.LMove{s, d, e}, form, ms}:
      [s]
    case _:
      Nil{}

# a big integer below 2^48 (two limbs at most) as a Nat
def blk.nat.hi(xs: List<&2, Nat>) -> Nat:
  match xs:
    case Con{+l, rest}:
      Nat.mul(l, 16777216n)
    case Nil{}:
      0n

def blk.nat(xs: List<&2, Nat>) -> Nat:
  match xs:
    case Con{+l, rest}:
      Nat.add(l, blk.nat.hi(rest))
    case Nil{}:
      0n

# when a client that waits from now (ms since 1970) times out: 0 never
# (a timeout of 0, or one past 2^46 ms, thousands of years: a deadline
# past a long long's range wraps in Redis to a negative one, which its
# table of timeouts reads as unsigned, past any time), else the ms
def blk.until.of(z: Bool, far: Bool, +now: Nat, ms: List<&2, Nat>) -> Nat:
  match z far:
    case True{} _:
      0n
    case False{} True{}:
      0n
    case False{} False{}:
      Nat.add(now, blk.nat(ms))

def blk.until(+now: Nat, +ms: List<&2, Nat>) -> Nat:
  blk.until.of(F.big.is_zero(ms), Nat.is_lt(46n, F.big.bitlen(ms)), now, ms)

def blk.ms(b: Blk) -> List<&2, Nat>:
  match b:
    case BlkPop{c, form, ms}:
      ms
    case BlkWait{ms}:
      ms
    case _:
      Nil{}

# the form of a pop's reply (blk.shape)
def blk.form(+b: Blk) -> Nat:
  match b:
    case BlkPop{c, +form, ms}:
      form
    case _:
      0n

# whether a pop waits for a sorted set (ZMPOP) rather than a list
def blk.zset(+b: Blk) -> Bool:
  match b:
    case BlkPop{R.ZMPop{ks, max, n}, form, ms}:
      True{}
    case _:
      False{}

# whether an entry holds what a pop waits for: a list, or a sorted set
# (z); a key never holds an empty one
def blk.has(+z: Bool, m: Maybe<&2, KV.Item<KV.Val>>) -> Bool:
  match m:
    case Some{KV.Item{KV.VColl{KV.CList{l}}, e}}:
      Bool.not(z)
    case Some{KV.Item{KV.VColl{KV.CZset{t}}, e}}:
      z
    case _:
      False{}

# the pop made from key k alone, once k holds what it waits for (the
# server, as Redis serves a client from the key a write made ready)
def blk.at(b: Blk, +k: String) -> R.Cmd:
  match b:
    case BlkPop{R.LMPop{ks, left, n}, form, ms}:
      R.LMPop{[k], left, n}
    case BlkPop{R.ZMPop{ks, max, n}, form, ms}:
      R.ZMPop{[k], max, n}
    case BlkPop{c, form, ms}:
      c
    case BlkBad{r}:
      R.Bad{r}
    case BlkPause{}:
      R.Bad{R.RNullA{}}
    case BlkWait{ms}:
      R.Bad{R.RInt{R.IPos{0n}}}
    case BlkScript{rs}:
      R.Bad{R.RNullA{}}

# Databases
# ---------
# SELECT, SWAPDB and MOVE name a database by its number, read as Redis
# reads one (getIntFromObjectOrReply): an integer that fits an int, else
# the command's own error, or Redis's ("value is not an integer or out of
# range" for no long long, "value is out of range, value must between
# ..." for a long long past an int); then one of the server's, else "DB
# index is out of range".
type Idx is Data:
  IdxOk{n: Nat}
  IdxBad{r: R.Reply}

def e_range() -> R.Reply:
  R.RError{"ERR DB index is out of range"}

def e_intr() -> R.Reply:
  R.RError{"ERR value is out of range, value must between -2147483648 and 2147483647"}

# a number as an int: one that fits (from -2^31 to 2^31 - 1), a long long
# past one, or no long long (R.ll.read reads one as Redis's string2ll)
type IntR is Data:
  IntOk{i: R.Int}
  IntBig{}
  IntNot{}

def int.mk(neg: Bool, +m: Nat) -> IntR:
  match neg:
    case True{}:
      IntOk{R.INeg{Nat.sub(m, 1n)}}
    case False{}:
      IntOk{R.IPos{m}}

def int.mag(+neg: Bool, +m: Nat) -> IntR:
  Bool.pick(IntR, Nat.is_lt(m, Bool.pick(Nat, neg, 2147483649n, 2147483648n)), int.mk(neg, m), IntBig{})

# a magnitude hi * 10^9 + lo, made only when hi is below 3 (a def, so
# that a long long past 2^48 is never made: a Nat stays below it)
def int.big(small: Bool, +neg: Bool, +hi: Nat, +lo: Nat) -> IntR:
  match small:
    case True{}:
      int.mag(neg, Nat.add(Nat.mul(hi, 1000000000n), lo))
    case False{}:
      IntBig{}

def int.of(l: R.LL) -> IntR:
  match l:
    case R.LL{+neg, +hi, +lo}:
      int.big(Nat.is_lt(hi, 3n), neg, hi, lo)
    case R.LLBad{}:
      IntNot{}

def int.read(+s: String) -> IntR:
  int.of(R.ll.read(s))

def idx.of(v: IntR, +dbs: Nat, e: R.Reply, big: R.Reply) -> Idx:
  match v:
    case IntOk{R.IPos{+n}}:
      Bool.pick(Idx, Nat.is_lt(n, dbs), IdxOk{n}, IdxBad{e_range()})
    case IntOk{R.INeg{n}}:
      IdxBad{e_range()}
    case IntBig{}:
      IdxBad{big}
    case IntNot{}:
      IdxBad{e}

def idx(+s: String, +dbs: Nat) -> Idx:
  idx.of(int.read(s), dbs, R.e_int(), e_intr())

def idx.reply(i: Idx) -> R.Reply:
  match i:
    case IdxOk{n}:
      R.r_ok()
    case IdxBad{r}:
      r

# SELECT index: the connection's database from then on
def select.idx(+d: String, +s: Srv) -> Idx:
  idx(d, srv.dbs(s))

def select.conn(i: Idx, +c: Conn, +s: Srv) -> Conn:
  match i c:
    case IdxOk{j} Conn{id, a, name, mode, quit, db, r3}:
      Conn{id, a, name, after(mode), quit, j, r3}
    case IdxBad{r} c0:
      step_conn(c0, s)

def select.acts(i: Idx) -> List<&2, R.Act>:
  match i:
    case IdxOk{j}:
      [R.AFocus{j}]
    case IdxBad{r}:
      Nil{}

# SWAPDB index1 index2: each an int ("invalid first DB index", "invalid
# second DB index"), then both of the server's
type Idx2 is Data:
  Idx2Ok{a: Nat, b: Nat}
  Idx2Bad{r: R.Reply}

def swap.check(ma: IntR, mb: IntR, +dbs: Nat) -> Idx2:
  match ma mb:
    case IntOk{R.IPos{+a}} IntOk{R.IPos{+b}}:
      Bool.pick(Idx2, Bool.and(Nat.is_lt(a, dbs), Nat.is_lt(b, dbs)), Idx2Ok{a, b}, Idx2Bad{e_range()})
    case IntOk{x} IntOk{y}:
      Idx2Bad{e_range()}
    case IntOk{x} _:
      Idx2Bad{R.RError{"ERR invalid second DB index"}}
    case _ _:
      Idx2Bad{R.RError{"ERR invalid first DB index"}}

def swap.idx(+a: String, +b: String, +s: Srv) -> Idx2:
  swap.check(int.read(a), int.read(b), srv.dbs(s))

def swap.reply(i: Idx2) -> R.Reply:
  match i:
    case Idx2Ok{a, b}:
      R.r_ok()
    case Idx2Bad{r}:
      r

def swap.acts(i: Idx2) -> List<&2, R.Act>:
  match i:
    case Idx2Ok{a, b}:
      [R.ASwap{a, b}]
    case Idx2Bad{r}:
      Nil{}

# MOVE key db: db an int, one of the server's, and not the connection's
# own ("source and destination objects are the same"); MOVE's two acts
# (R.ds.purge, R.ds.move), the second's reply being MOVE's
def move.of(i: Idx, +c: Conn) -> Idx:
  match i:
    case IdxOk{+j}:
      Bool.pick(Idx, Nat.is_eq(j, conn.db(c)), IdxBad{R.RError{"ERR source and destination objects are the same"}}, IdxOk{j})
    case IdxBad{r}:
      IdxBad{r}

def move.idx(+d: String, +c: Conn, +s: Srv) -> Idx:
  move.of(idx(d, srv.dbs(s)), c)

def move.acts(+k: String, i: Idx) -> List<&2, R.Act>:
  match i:
    case IdxOk{+j}:
      [R.APurge{k, j}, R.AMove{k, j}]
    case IdxBad{r}:
      Nil{}

def move.reply(+k: String, i: Idx, +ds: R.Ds) -> R.Reply:
  match i:
    case IdxOk{+j}:
      R.reply_ds(R.act(R.AMove{k, j}, R.ds_of(R.act(R.APurge{k, j}, ds))))
    case IdxBad{r}:
      r

# COPY source destination [DB index] [REPLACE]: the options after the two
# keys in turn, as Redis reads them: REPLACE, or DB and an index (an int,
# one of the server's databases, read as SELECT reads one); anything
# else, DB as the last argument too, is a syntax error. Then the same key
# to the same database is refused; else one act (R.ds.copy), whose reply
# is COPY's
type CopySt is Data:
  CsOpt{db: Nat, rep: Bool}
  CsDb{rep: Bool}
  CsBad{r: R.Reply}

def copy.word.of(isrep: Bool, isdb: Bool, db: Nat, rep: Bool) -> CopySt:
  match isrep isdb:
    case True{} _:
      CsOpt{db, True{}}
    case False{} True{}:
      CsDb{rep}
    case False{} False{}:
      CsBad{R.r_syntax()}

def copy.word(+a: String, db: Nat, rep: Bool) -> CopySt:
  +up = String.to_upper(a)
  copy.word.of(String.eq(up, "REPLACE"), String.eq(up, "DB"), db, rep)

def copy.db(i: Idx, rep: Bool) -> CopySt:
  match i:
    case IdxOk{j}:
      CsOpt{j, rep}
    case IdxBad{r}:
      CsBad{r}

def copy.go(args: List<&2, String>, st: CopySt, +dbs: Nat) -> CopySt:
  match args st:
    case _ CsBad{r}:
      CsBad{r}
    case Nil{} CsOpt{db, rep}:
      CsOpt{db, rep}
    case Nil{} CsDb{rep}:
      CsBad{R.r_syntax()}
    case Con{+a, rest} CsOpt{db, rep}:
      copy.go(rest, copy.word(a, db, rep), dbs)
    case Con{+a, rest} CsDb{rep}:
      copy.go(rest, copy.db(idx(a, dbs), rep), dbs)

type CopyArgs is Data:
  CopyOk{src: String, dst: String, db: Nat, rep: Bool}
  CopyBad{r: R.Reply}

def copy.fin(st: CopySt, +src: String, +dst: String, +cur: Nat) -> CopyArgs:
  match st:
    case CsOpt{+db, rep}:
      Bool.pick(CopyArgs, Bool.and(Nat.is_eq(db, cur), KV.str_eq(src, dst)), CopyBad{R.RError{"ERR source and destination objects are the same"}}, CopyOk{src, dst, db, rep})
    case CsDb{rep}:
      CopyBad{R.r_syntax()}
    case CsBad{r}:
      CopyBad{r}

def copy.of(+args: List<&2, String>, +c: Conn, +s: Srv) -> CopyArgs:
  match args:
    case Con{+a, Con{+b, rest}}:
      copy.fin(copy.go(rest, CsOpt{conn.db(c), False{}}, srv.dbs(s)), a, b, conn.db(c))
    case _:
      CopyBad{R.RError{"ERR wrong number of arguments for 'copy' command"}}

def copy.acts(ca: CopyArgs) -> List<&2, R.Act>:
  match ca:
    case CopyOk{s, d, j, rep}:
      [R.ACopy{s, d, j, rep}]
    case CopyBad{r}:
      Nil{}

def copy.reply(ca: CopyArgs, +ds: R.Ds) -> R.Reply:
  match ca:
    case CopyOk{s, d, j, rep}:
      R.reply_ds(R.act(R.ACopy{s, d, j, rep}, ds))
    case CopyBad{r}:
      r

# QUIT: OK, and the connection closes once its replies are out; the
# commands after it in the batch are dropped
def quit.conn(+c: Conn, +s: Srv) -> Conn:
  match c:
    case Conn{id, a, name, mode, quit, db, r3}:
      Conn{id, a, name, after(mode), True{}, db, r3}

# RESET: the connection as new, authenticated if there is no password,
# in RESP2; its reply goes out unless it is the one skipped
def reset.conn(c: Conn, +s: Srv) -> Conn:
  match c:
    case Conn{id, a, name, mode, quit, db, r3}:
      Conn{id, nopass(s), "", MOn{}, False{}, 0n, False{}}

def reset.out(m: Mute) -> Maybe<&2, R.Reply>:
  match m:
    case MSkip{}:
      None{}
    case _:
      Some{R.RStatus{"RESET"}}

# CLIENT GETNAME and SETNAME: an empty name is no name
def getname(n: String) -> R.Reply:
  match n:
    case SNil{}:
      R.RNull{}
    case SCon{h, t}:
      R.RBulk{SCon{h, t}}

def setname.conn(ok: Bool, n: String, +c: Conn, +s: Srv) -> Conn:
  match ok c:
    case True{} Conn{id, a, name, mode, quit, db, r3}:
      Conn{id, a, n, after(mode), quit, db, r3}
    case False{} c0:
      step_conn(c0, s)

# CLIENT REPLY ON|OFF|SKIP: ON sends its own reply, OFF and SKIP do not,
# and a SKIP while replies are off leaves them off
def reply_word(+m: String) -> Nat:
  Bool.pick(Nat, R.is_word(m, "ON"), 1n, Bool.pick(Nat, R.is_word(m, "OFF"), 2n, Bool.pick(Nat, R.is_word(m, "SKIP"), 3n, 0n)))

def reply.skip(old: Mute) -> Mute:
  match old:
    case MOff{}:
      MOff{}
    case _:
      MSkip{}

def reply.mode(w: Nat, old: Mute) -> Mute:
  match w:
    case 1n:
      MOn{}
    case 2n:
      MOff{}
    case 3n:
      reply.skip(old)
    case _:
      after(old)

def reply.out(w: Nat, old: Mute) -> Maybe<&2, R.Reply>:
  match w:
    case 1n:
      Some{R.r_ok()}
    case 2n:
      None{}
    case 3n:
      None{}
    case _:
      say(old, R.RError{"ERR syntax error"})

def mode.conn(m: Mute, +c: Conn, +s: Srv) -> Conn:
  match c:
    case Conn{id, a, name, mode, quit, db, r3}:
      Conn{id, a, name, m, quit, db, r3}

# RANDOMKEY's reply: a key there at now in the database's trie, by r, or
# nil
def randomkey.of(+db: R.Db, +r: U32) -> R.Reply:
  match db:
    case R.Db{+t, n, x, +now, rr}:
      R.r_get(KV.pick(KV.Val, t, r, now))

# TIME: the time the batch runs at (the focus's, set from the clock for
# each group of batches), in s and us since 1970; BendKV keeps it in ms
def time.reply(+now: Nat) -> R.Reply:
  R.RArray{[R.RBulk{Nat.show(Nat.div(now, 1000n))}, R.RBulk{Nat.show(Nat.mul(Nat.mod(now, 1000n), 1000n))}]}

# OBJECT of a key there (none: nil). BendKV keeps a value as its bytes
# alone, so it answers ENCODING as Redis 7.0.15 encodes a value set whole
# ("int" for a long, "embstr" up to 44 bytes, else "raw"; a value Redis
# made by APPEND, SETRANGE, SETBIT or a command of HyperLogLogs is "raw"
# there whatever it holds),
# REFCOUNT by the integers 0 to 9999 Redis shares (INT_MAX for one, unless
# maxmemory is set with an LRU or LFU policy, else 1), and IDLETIME and
# FREQ (obj.use) as a key's that no command used since the server's start:
# the server answers them from the key's word (Access; server.bend,
# bg.obj), which is the runtime's alone and which no law reads.
def obj.lfu(+cfg: List<&2, C.CItem>) -> Bool:
  +p = C.config.get_value(cfg, "maxmemory-policy")
  Bool.or(String.eq(p, "allkeys-lfu"), String.eq(p, "volatile-lfu"))

# OBJECT IDLETIME and FREQ of a key whose word is w (Access), at now (ms),
# the server started at start (s): IDLETIME the seconds since its last
# use, refused under an LFU policy; FREQ its counter, decayed to now,
# refused under any other, as in Redis
def obj.use(+sub: Nat, +w: U32, +now: Nat, +start: U32, +lfu: Bool, +dt: Nat) -> R.Reply:
  match sub lfu:
    case 2n True{}:
      R.r_int(U32.to_nat(acc.freq(w, now, start, dt)))
    case 2n False{}:
      R.RError{"ERR An LFU maxmemory policy is not selected, access frequency not tracked. Please note that when switching between policies at runtime LRU and LFU data will take some time to adjust."}
    case _ True{}:
      R.RError{"ERR An LFU maxmemory policy is selected, idle time not tracked. Please note that when switching between policies at runtime LRU and LFU data will take some time to adjust."}
    case _ False{}:
      R.r_int(acc.idle(w, now, start))

def obj.shared(+cfg: List<&2, C.CItem>) -> Bool:
  +p = C.config.get_value(cfg, "maxmemory-policy")
  Bool.or(String.eq(C.config.get_value(cfg, "maxmemory"), "0"),
    Bool.not(Bool.or(Bool.or(String.eq(p, "allkeys-lru"), String.eq(p, "volatile-lru")), obj.lfu(cfg))))

def obj.encoding(l: R.LL, +n: Nat) -> R.Reply:
  match l:
    case R.LL{neg, hi, lo}:
      R.RBulk{"int"}
    case R.LLBad{}:
      R.RBulk{Bool.pick(String, Nat.is_le(n, 44n), "embstr", "raw")}

def obj.refcount(l: R.LL, +shared: Bool) -> R.Reply:
  match l:
    case R.LL{+neg, +hi, +lo}:
      R.r_int(Bool.pick(Nat, Bool.and(shared, Bool.and(Bool.not(neg), Bool.and(Nat.is_eq(hi, 0n), Nat.is_lt(lo, 10000n)))), 2147483647n, 1n))
    case R.LLBad{}:
      R.r_int(1n)

def obj.of(+sub: Nat, +v: String, +cfg: List<&2, C.CItem>, u: R.Reply) -> R.Reply:
  match sub:
    case 3n:
      obj.encoding(R.ll.read(v), String.length(v))
    case 4n:
      obj.refcount(R.ll.read(v), obj.shared(cfg))
    case _:
      u

# OBJECT of a collection: its encoding as Redis 7.0 names it, a count of
# references of 1, and the rest as for a string. A hash is a listpack
# while it is small (KV.Hash: as Redis turns one into a hashtable at the
# parameters' defaults) and within hash-max-listpack-entries and, when it
# is below its default of 64, hash-max-listpack-value as they are now;
# else a hashtable. (Redis reads the parameters as a hash is written, and
# never turns a hashtable back: a small hash that once passed a lower
# limit, or a large one under limits raised since, is named otherwise
# there. A listpack RESTORE made keeps longer values: Redis turns one
# into a hashtable by its length alone, as BendKV keeps it small.)
# a parameter's number, at most 10^14 (a Nat stays below 2^48)
def cfg.nat.of(l: R.LL) -> Nat:
  match l:
    case R.LL{neg, +hi, +lo}:
      Nat.add(Nat.mul(Nat.min(hi, 100000n), 1000000000n), lo)
    case R.LLBad{}:
      0n

def cfg.nat(+cfg: List<&2, C.CItem>, +name: String) -> Nat:
  cfg.nat.of(R.ll.read(C.config.get_value(cfg, name)))

# the ACL LOG with an entry the server makes (a call it refused, an AUTH
# that failed: server.bend, ACL), as many kept as acllog-max-len says
def srv.acl.log(s: Srv, e: U.Ent) -> Srv:
  +s0 = s
  srv.acl.set(s0, U.acl.log.add(srv.acl(s0), e, cfg.nat(srv.cfg(s0), "acllog-max-len")))

# whether a listpack's longest element w is within the limit l: any is,
# with l at its default of 64 or more
def obj.wide.ok(+w: Nat, +l: Nat) -> Bool:
  Bool.or(Nat.is_le(w, l), Nat.is_le(64n, l))

def obj.hash.enc(+h: KV.Hash, +cfg: List<&2, C.CItem>) -> String:
  match h:
    case KV.HSmall{+n, +b}:
      Bool.pick(String, Bool.and(Nat.is_le(n, cfg.nat(cfg, "hash-max-listpack-entries")), obj.wide.ok(KV.hb.widest(n, b, 0n, 0n), cfg.nat(cfg, "hash-max-listpack-value"))), "listpack", "hashtable")
    case KV.HBig{n, t}:
      "hashtable"
    case KV.HLong{+n, +ps}:
      Bool.pick(String, Bool.and(Nat.is_le(n, cfg.nat(cfg, "hash-max-listpack-entries")), obj.wide.ok(KV.hl.widest(ps, 0n), cfg.nat(cfg, "hash-max-listpack-value"))), "listpack", "hashtable")

def obj.mems.enc(+m: KV.Mems, +cfg: List<&2, C.CItem>) -> String:
  match m:
    case KV.MInts{+n, xs}:
      Bool.pick(String, Nat.is_le(n, cfg.nat(cfg, "set-max-intset-entries")), "intset", "hashtable")
    case KV.MBig{n, t}:
      "hashtable"

# a sorted set is a listpack while it is small (KV.Zset: as Redis turns
# one into a skiplist at the parameters' defaults) and within
# zset-max-listpack-entries and zset-max-listpack-value as they are now,
# as a hash
def obj.zset.small(+n: Nat, +w: Nat, +cfg: List<&2, C.CItem>) -> String:
  Bool.pick(String, Bool.and(Nat.is_le(n, cfg.nat(cfg, "zset-max-listpack-entries")), obj.wide.ok(w, cfg.nat(cfg, "zset-max-listpack-value"))), "listpack", "skiplist")

def obj.zset.enc(+z: KV.Zset, +cfg: List<&2, C.CItem>) -> String:
  match z:
    case KV.ZSmall{+n, +b}:
      obj.zset.small(n, KV.zb.widest(n, b, 0n, 0n), cfg)
    case KV.ZWide{+tr}:
      obj.zset.small(KV.zt.size(tr), KV.zt.widest(tr, 0n), cfg)
    case KV.ZBig{tr, t}:
      "skiplist"

def obj.coll.enc(+c: KV.Coll, +cfg: List<&2, C.CItem>) -> String:
  match c:
    case KV.CHash{+h}:
      obj.hash.enc(h, cfg)
    case KV.CList{l}:
      "quicklist"
    case KV.CMems{+m}:
      obj.mems.enc(m, cfg)
    case KV.CZset{+z}:
      obj.zset.enc(z, cfg)
    case KV.CStream{x}:
      "stream"

def obj.coll(+sub: Nat, +c: KV.Coll, +cfg: List<&2, C.CItem>, u: R.Reply) -> R.Reply:
  match sub:
    case 3n:
      R.RBulk{obj.coll.enc(c, cfg)}
    case 4n:
      R.r_int(1n)
    case _:
      u

# OBJECT's reply of a key there, u that of IDLETIME or FREQ (obj.use)
def obj.reply(+sub: Nat, m: Maybe<&2, KV.Item<KV.Val>>, +cfg: List<&2, C.CItem>, u: R.Reply) -> R.Reply:
  match m:
    case Some{KV.Item{KV.VStr{+v}, e}}:
      obj.of(sub, v, cfg, u)
    case Some{KV.Item{KV.VColl{+c}, e}}:
      obj.coll(sub, c, cfg, u)
    case None{}:
      R.RNull{}

# HRANDFIELD key [count [WITHVALUES]]: fields of a hash at random, by r
# (the server's random number, and the numbers of its Weyl sequence after
# it, which KV.mix scrambles), read as Redis 7.0.15 reads them: the count
# is a long long other than LLONG_MIN, at most LONG_MAX/2 in size with
# WITHVALUES, and any other word after it a syntax error, all before the
# key is looked for. A key not there answers a nil (no count) or an empty
# array, one that holds a string WRONGTYPE. A negative count picks that
# many fields, each anew, so that a field may come again; a positive one
# that many different fields, all of them in the hash's order when it is
# at least the hash's size.
type HrArgs is Data:
  HrOne{}
  HrCount{neg: Bool, n: Nat, wv: Bool}
  HrBad{r: R.Reply}

def hr.cap(+hi: Nat, +lo: Nat) -> Nat:
  Nat.add(Nat.mul(Nat.min(hi, 100000n), 1000000000n), lo)

# LONG_MAX / 2 (4611686018427387903): its digits before the last nine
def hr.half.hi() -> Nat:
  Nat.add(Nat.mul(461168n, 10000n), 6018n)

def hr.half(+neg: Bool, +hi: Nat, +lo: Nat) -> HrArgs:
  Bool.pick(HrArgs, R.ll.le(hi, lo, hr.half.hi(), 427387903n), HrCount{neg, hr.cap(hi, lo), True{}}, HrBad{R.RError{"ERR value is out of range"}})

def hr.opts(+neg: Bool, +hi: Nat, +lo: Nat, rest: List<&2, String>) -> HrArgs:
  match rest:
    case Nil{}:
      HrCount{neg, hr.cap(hi, lo), False{}}
    case Con{+w, Nil{}}:
      Bool.pick(HrArgs, R.is_word(w, "WITHVALUES"), hr.half(neg, hi, lo), HrBad{R.RError{"ERR syntax error"}})
    case _:
      HrBad{R.RError{"ERR syntax error"}}

def hr.count(l: R.LL, rest: List<&2, String>) -> HrArgs:
  match l:
    case R.LL{+neg, +hi, +lo}:
      Bool.pick(HrArgs, Bool.and(neg, Bool.and(Nat.is_eq(hi, R.dec.llmax()), Nat.is_eq(lo, 854775808n))), HrBad{R.RError{"ERR value is out of range, value must between -9223372036854775807 and 9223372036854775807"}}, hr.opts(neg, hi, lo, rest))
    case R.LLBad{}:
      HrBad{R.RError{"ERR value is not an integer or out of range"}}

def hr.args(args: List<&2, String>) -> HrArgs:
  match args:
    case Nil{}:
      HrOne{}
    case Con{+c, rest}:
      hr.count(R.ll.read(c), rest)

def hr.next(+r: U32) -> U32:
  U32.add(r, 2654435769)

def hr.at(+r: U32, +n: Nat) -> Nat:
  Nat.mod(U32.to_nat(KV.mix(r)), Nat.max(n, 1n))

def hp.nth(ps: List<&2, KV.HPair>, i: Nat) -> Maybe<&2, KV.HPair>:
  match ps i:
    case Con{p, rest} 0n:
      Some{p}
    case Con{p, rest} 1n+j:
      hp.nth(rest, j)
    case Nil{} _:
      None{}

# ps without its i-th pair
def hp.drop(ps: List<&2, KV.HPair>, i: Nat) -> List<&2, KV.HPair>:
  match ps i:
    case Con{p, rest} 0n:
      rest
    case Con{p, rest} 1n+j:
      Con{p, hp.drop(rest, j)}
    case Nil{} _:
      Nil{}

# a field, or under WITHVALUES a field and its value as a pair (a flat
# array in RESP2, an array of pairs in RESP3)
def hr.pair(wv: Bool, f: String, v: String, rest: List<&2, R.Reply>) -> List<&2, R.Reply>:
  match wv:
    case True{}:
      R.RPair{[R.RBulk{f}, R.RBulk{v}]} <> rest
    case False{}:
      R.RBulk{f} <> rest

def hr.out(m: Maybe<&2, KV.HPair>, +wv: Bool, rest: List<&2, R.Reply>) -> List<&2, R.Reply>:
  match m:
    case Some{KV.HP{f, v}}:
      hr.pair(wv, f, v, rest)
    case None{}:
      rest

# all the pairs, in order
def hr.all(ps: List<&2, KV.HPair>, +wv: Bool) -> List<&2, R.Reply>:
  match ps:
    case Nil{}:
      Nil{}
    case Con{KV.HP{f, v}, rest}:
      hr.pair(wv, f, v, hr.all(rest, wv))

# k pairs of the n of ps, each picked anew
def hr.rep(k: Nat, +ps: List<&2, KV.HPair>, +n: Nat, +r: U32, +wv: Bool) -> List<&2, R.Reply>:
  match k:
    case 0n:
      Nil{}
    case 1n+j:
      +q = hr.next(r)
      hr.out(hp.nth(ps, hr.at(q, n)), wv, hr.rep(j, ps, n, q, wv))

# k different pairs of the n of ps
def hr.uniq(k: Nat, ps: List<&2, KV.HPair>, +n: Nat, +r: U32, +wv: Bool) -> List<&2, R.Reply>:
  match k:
    case 0n:
      Nil{}
    case 1n+j:
      +q = hr.next(r)
      +i = hr.at(q, n)
      +qs = ps
      hr.out(hp.nth(qs, i), wv, hr.uniq(j, hp.drop(qs, i), Nat.sub(n, 1n), q, wv))

def hr.pos(all: Bool, +k: Nat, +wv: Bool, ps: List<&2, KV.HPair>, +n: Nat, +r: U32) -> List<&2, R.Reply>:
  match all:
    case True{}:
      hr.all(ps, wv)
    case False{}:
      hr.uniq(k, ps, n, r, wv)

def hr.of(neg: Bool, +k: Nat, +wv: Bool, +ps: List<&2, KV.HPair>, +n: Nat, +r: U32) -> List<&2, R.Reply>:
  match neg:
    case True{}:
      hr.rep(k, ps, n, r, wv)
    case False{}:
      hr.pos(Nat.is_le(n, k), k, wv, ps, n, r)

def hr.first(m: Maybe<&2, KV.HPair>) -> R.Reply:
  match m:
    case Some{KV.HP{f, v}}:
      R.RBulk{f}
    case None{}:
      R.RNull{}

def hr.one(m: Maybe<&2, KV.Item<KV.Val>>, +r: U32) -> R.Reply:
  match m:
    case Some{KV.Item{KV.VColl{KV.CHash{+h}}, e}}:
      hr.first(hp.nth(KV.hash.pairs(h), hr.at(hr.next(r), KV.hash.len(h))))
    case Some{KV.Item{KV.VColl{KV.CList{l}}, e}}:
      R.e_wrongtype()
    case Some{KV.Item{KV.VColl{KV.CMems{l}}, e}}:
      R.e_wrongtype()
    case Some{KV.Item{KV.VColl{KV.CZset{z}}, e}}:
      R.e_wrongtype()
    case Some{KV.Item{KV.VColl{KV.CStream{x}}, e}}:
      R.e_wrongtype()
    case Some{KV.Item{KV.VStr{s}, e}}:
      R.e_wrongtype()
    case None{}:
      R.RNull{}

def hr.many(m: Maybe<&2, KV.Item<KV.Val>>, +neg: Bool, +k: Nat, +wv: Bool, +r: U32) -> R.Reply:
  match m:
    case Some{KV.Item{KV.VColl{KV.CHash{+h}}, e}}:
      R.zels.wrap(wv, hr.of(neg, k, wv, KV.hash.pairs(h), KV.hash.len(h), r))
    case Some{KV.Item{KV.VColl{KV.CList{l}}, e}}:
      R.e_wrongtype()
    case Some{KV.Item{KV.VColl{KV.CMems{l}}, e}}:
      R.e_wrongtype()
    case Some{KV.Item{KV.VColl{KV.CZset{z}}, e}}:
      R.e_wrongtype()
    case Some{KV.Item{KV.VColl{KV.CStream{x}}, e}}:
      R.e_wrongtype()
    case Some{KV.Item{KV.VStr{s}, e}}:
      R.e_wrongtype()
    case None{}:
      R.RArray{Nil{}}

def hr.reply(a: HrArgs, m: Maybe<&2, KV.Item<KV.Val>>, +r: U32) -> R.Reply:
  match a:
    case HrOne{}:
      hr.one(m, r)
    case HrCount{+neg, +k, +wv}:
      hr.many(m, neg, k, wv, r)
    case HrBad{e}:
      e

# SRANDMEMBER key [count] and SPOP key [count]: members of a set at
# random, by r (the server's random number, as HRANDFIELD's; R.srand
# picks them), the count read as Redis 7.0.15 reads it, before the key is
# looked for: one word after the key at most (else a syntax error),
# SRANDMEMBER's a long long other than LLONG_MIN, SPOP's a long at least
# 0. A key not there answers a nil (no count) or an empty array, one of
# another kind WRONGTYPE. SRANDMEMBER with a negative count picks that
# many members, each anew; with a positive one that many different
# members, all of them in the set's order when it is at least the set's
# size. SPOP takes the members it answers: it is the write R.SWPop (or
# R.SWPopN, with a count) on the database it acts on, and answers as that
# write answers there.
type SrArgs is Data:
  SrOne{}
  SrCount{neg: Bool, n: Nat}
  SrBad{r: R.Reply}

def sr.count(l: R.LL) -> SrArgs:
  match l:
    case R.LL{+neg, +hi, +lo}:
      Bool.pick(SrArgs, Bool.and(neg, Bool.and(Nat.is_eq(hi, R.dec.llmax()), Nat.is_eq(lo, 854775808n))), SrBad{R.RError{"ERR value is out of range, value must between -9223372036854775807 and 9223372036854775807"}}, SrCount{neg, hr.cap(hi, lo)})
    case R.LLBad{}:
      SrBad{R.RError{"ERR value is not an integer or out of range"}}

def sr.args(args: List<&2, String>) -> SrArgs:
  match args:
    case Nil{}:
      SrOne{}
    case Con{+c, Nil{}}:
      sr.count(R.ll.read(c))
    case _:
      SrBad{R.RError{"ERR syntax error"}}

def sr.pick(neg: Bool, +k: Nat, +s: KV.Mems, +r: U32) -> List<&2, String>:
  match neg:
    case True{}:
      R.srand.rep(k, s, r)
    case False{}:
      R.srand.many(k, s, r)

def sr.one(m: Maybe<&2, KV.Item<KV.Val>>, +r: U32) -> R.Reply:
  match m:
    case Some{KV.Item{KV.VColl{KV.CMems{+s}}, e}}:
      R.r_get(R.srand.pick(s, R.srand.next(r)))
    case None{}:
      R.RNull{}
    case _:
      R.e_wrongtype()

def sr.many(m: Maybe<&2, KV.Item<KV.Val>>, +neg: Bool, +k: Nat, +r: U32) -> R.Reply:
  match m:
    case Some{KV.Item{KV.VColl{KV.CMems{+s}}, e}}:
      R.RArray{R.lbulks(sr.pick(neg, k, s, r))}
    case None{}:
      R.RArray{Nil{}}
    case _:
      R.e_wrongtype()

def sr.reply(a: SrArgs, m: Maybe<&2, KV.Item<KV.Val>>, +r: U32) -> R.Reply:
  match a:
    case SrOne{}:
      sr.one(m, r)
    case SrCount{+neg, +k}:
      sr.many(m, neg, k, r)
    case SrBad{e}:
      e

def sp.count(l: R.LL) -> SrArgs:
  match l:
    case R.LL{+neg, +hi, +lo}:
      Bool.pick(SrArgs, neg, SrBad{R.RError{"ERR value is out of range, must be positive"}}, SrCount{False{}, hr.cap(hi, lo)})
    case R.LLBad{}:
      SrBad{R.RError{"ERR value is out of range, must be positive"}}

def sp.args(args: List<&2, String>) -> SrArgs:
  match args:
    case Nil{}:
      SrOne{}
    case Con{+c, Nil{}}:
      sp.count(R.ll.read(c))
    case _:
      SrBad{R.RError{"ERR syntax error"}}

def sp.reply(a: SrArgs, +k: String, +r: U32, db: R.Db) -> R.Reply:
  match a:
    case SrOne{}:
      R.reply_of(R.exec(R.Upd{k, R.UMems{R.SWPop{r}}}, db))
    case SrCount{neg, +n}:
      R.reply_of(R.exec(R.Upd{k, R.UMems{R.SWPopN{n, r}}}, db))
    case SrBad{e}:
      e

def sp.acts(a: SrArgs, +k: String, +r: U32) -> List<&2, R.Act>:
  match a:
    case SrOne{}:
      [R.ARun{R.Upd{k, R.UMems{R.SWPop{r}}}}]
    case SrCount{neg, +n}:
      [R.ARun{R.Upd{k, R.UMems{R.SWPopN{n, r}}}}]
    case SrBad{e}:
      Nil{}

# ZRANDMEMBER key [count [WITHSCORES]]: elements of a sorted set at
# random, by r (as HRANDFIELD's), the count read as HRANDFIELD reads its
# own (WITHSCORES for WITHVALUES). An element is picked by its rank: a
# large sorted set's tree finds it in O(log n), a small one's string in a
# walk to it, and more than 32 picks of a small one walk a tree made from
# its string (ZrSrc). A negative count picks that many elements,
# each anew; a positive one that many different elements, all of them
# from the last when it is at least the sorted set's size (Redis reads a
# sorted set from its last element there); else, when it is more
# than a third of the size, the size less the count of them taken out at
# random and the rest answered in order (Redis's third way), or picked
# until that many different ones come, 16 times the count and 64 picks at
# most (its fourth way).
def zr.opts(+neg: Bool, +hi: Nat, +lo: Nat, rest: List<&2, String>) -> HrArgs:
  match rest:
    case Nil{}:
      HrCount{neg, hr.cap(hi, lo), False{}}
    case Con{+w, Nil{}}:
      Bool.pick(HrArgs, R.is_word(w, "WITHSCORES"), hr.half(neg, hi, lo), HrBad{R.RError{"ERR syntax error"}})
    case _:
      HrBad{R.RError{"ERR syntax error"}}

def zr.count(l: R.LL, rest: List<&2, String>) -> HrArgs:
  match l:
    case R.LL{+neg, +hi, +lo}:
      Bool.pick(HrArgs, Bool.and(neg, Bool.and(Nat.is_eq(hi, R.dec.llmax()), Nat.is_eq(lo, 854775808n))), HrBad{R.RError{"ERR value is out of range, value must between -9223372036854775807 and 9223372036854775807"}}, zr.opts(neg, hi, lo, rest))
    case R.LLBad{}:
      HrBad{R.RError{"ERR value is not an integer or out of range"}}

def zr.args(args: List<&2, String>) -> HrArgs:
  match args:
    case Nil{}:
      HrOne{}
    case Con{+c, rest}:
      zr.count(R.ll.read(c), rest)

# where the picks are made: a tree (a large sorted set's own, or one
# made from a small one's string), or the sorted set as it is
type ZrSrc is Data:
  ZrTree{t: KV.ZTree}
  ZrZset{z: KV.Zset}

# the element at rank i of s
def zr.at(+s: ZrSrc, +i: Nat) -> KV.ZEl:
  match s:
    case ZrTree{+t}:
      KV.zt.nth(t, i)
    case ZrZset{+z}:
      KV.zset.nth(z, i)

# the elements of s, of n, from the last
def zr.rev(+s: ZrSrc, +n: Nat) -> List<&2, KV.ZEl>:
  match s:
    case ZrTree{+t}:
      KV.zt.rslice(t, 0n, n)
    case ZrZset{+z}:
      KV.zset.slice(True{}, z, 0n, n)

# s's elements as a tree
def zr.tree(+s: ZrSrc) -> KV.ZTree:
  match s:
    case ZrTree{+t}:
      t
    case ZrZset{+z}:
      KV.zset.tree(z)

# the element at a rank r picks
def zr.el(+s: ZrSrc, +r: U32, +n: Nat) -> KV.ZEl:
  zr.at(s, hr.at(r, n))

def zr.out(e: KV.ZEl, +ws: Bool, rest: List<&2, R.Reply>) -> List<&2, R.Reply>:
  match e:
    case KV.ZEl{m, +d}:
      R.zels.one(ws, m, d, rest)

# k elements, each anew
def zr.rep(k: Nat, +s: ZrSrc, +n: Nat, +r: U32, +ws: Bool) -> List<&2, R.Reply>:
  match k:
    case 0n:
      Nil{}
    case 1n+j:
      +q = hr.next(r)
      zr.out(zr.el(s, q, n), ws, zr.rep(j, s, n, q, ws))

# t without c elements taken at random
def zr.cut(e: KV.ZEl, +t: KV.ZTree) -> KV.ZTree:
  match e:
    case KV.ZEl{+m, +d}:
      KV.zt.del(t, m, d)

def zr.drop(c: Nat, +t: KV.ZTree, +r: U32) -> KV.ZTree:
  match c:
    case 0n:
      t
    case 1n+j:
      +q = hr.next(r)
      zr.drop(j, zr.cut(KV.zt.nth(t, hr.at(q, KV.zt.size(t))), t), q)

# picks until k different elements come: the members taken, the reply so
# far, how many
type ZrG is Data:
  ZrG{acc: KV.Trie<Unit>, out: List<&2, R.Reply>, c: Nat}

def zr.take(had: Bool, e: KV.ZEl, acc: KV.Trie<Unit>, out: List<&2, R.Reply>, +c: Nat, +ws: Bool) -> ZrG:
  match had e:
    case True{} x:
      ZrG{acc, out, c}
    case False{} KV.ZEl{+m, +d}:
      ZrG{KV.set(Unit, acc, m, Unit{}), zr.out(KV.ZEl{m, d}, ws, out), Nat.add(c, 1n)}

def zr.step(+e: KV.ZEl, g: ZrG, +ws: Bool) -> ZrG:
  match g:
    case ZrG{+acc, out, +c}:
      zr.take(KV.has(Unit, acc, R.zel.m(e)), e, acc, out, c, ws)

def zr.done(+g: ZrG, +k: Nat) -> Bool:
  match g:
    case ZrG{acc, out, +c}:
      Nat.is_le(k, c)

def zr.outs(g: ZrG) -> List<&2, R.Reply>:
  match g:
    case ZrG{acc, out, c}:
      out

def zr.gather(fuel: Nat, done: Bool, g: ZrG, +k: Nat, +s: ZrSrc, +n: Nat, +r: U32, +ws: Bool) -> List<&2, R.Reply>:
  match fuel done:
    case _ True{}:
      zr.outs(g)
    case 0n False{}:
      zr.outs(g)
    case 1n+f False{}:
      +q = hr.next(r)
      +g2 = zr.step(zr.el(s, q, n), g, ws)
      zr.gather(f, zr.done(g2, k), g2, k, s, n, q, ws)

def zr.uniq(third: Bool, +k: Nat, +s: ZrSrc, +n: Nat, +r: U32, +ws: Bool) -> List<&2, R.Reply>:
  match third:
    case True{}:
      R.zels(KV.zt.drain(zr.drop(Nat.sub(n, k), zr.tree(s), r), Nil{}), ws)
    case False{}:
      zr.gather(Nat.add(Nat.mul(k, 16n), 64n), Nat.is_eq(k, 0n), ZrG{KV.empty(Unit), Nil{}, 0n}, k, s, n, r, ws)

def zr.pos(all: Bool, +k: Nat, +s: ZrSrc, +n: Nat, +r: U32, +ws: Bool) -> List<&2, R.Reply>:
  match all:
    case True{}:
      R.zels(zr.rev(s, n), ws)
    case False{}:
      zr.uniq(Nat.is_lt(n, Nat.mul(k, 3n)), k, s, n, r, ws)

def zr.of(neg: Bool, +k: Nat, +ws: Bool, +s: ZrSrc, +n: Nat, +r: U32) -> List<&2, R.Reply>:
  match neg:
    case True{}:
      zr.rep(k, s, n, r, ws)
    case False{}:
      zr.pos(Nat.is_le(n, k), k, s, n, r, ws)

# where k picks of z are made: z as it is, or, for more than 32 picks of
# each anew (many), a tree of its elements
def zr.src(many: Bool, +z: KV.Zset) -> ZrSrc:
  match many:
    case True{}:
      ZrTree{KV.zset.tree(z)}
    case False{}:
      ZrZset{z}

def zr.one(m: Maybe<&2, KV.Item<KV.Val>>, +r: U32) -> R.Reply:
  match m:
    case Some{KV.Item{KV.VColl{KV.CZset{+z}}, e}}:
      R.RBulk{R.zel.m(KV.zset.nth(z, hr.at(hr.next(r), KV.zset.len(z))))}
    case None{}:
      R.RNull{}
    case _:
      R.e_wrongtype()

def zr.many(m: Maybe<&2, KV.Item<KV.Val>>, +neg: Bool, +k: Nat, +ws: Bool, +r: U32) -> R.Reply:
  match m:
    case Some{KV.Item{KV.VColl{KV.CZset{+z}}, e}}:
      R.zels.wrap(ws, zr.of(neg, k, ws, zr.src(Bool.and(neg, Nat.is_lt(32n, k)), z), KV.zset.len(z), r))
    case None{}:
      R.RArray{Nil{}}
    case _:
      R.e_wrongtype()

def zr.reply(a: HrArgs, m: Maybe<&2, KV.Item<KV.Val>>, +r: U32) -> R.Reply:
  match a:
    case HrOne{}:
      zr.one(m, r)
    case HrCount{+neg, +k, +wv}:
      zr.many(m, neg, k, wv, r)
    case HrBad{e}:
      e

# MEMORY USAGE key [SAMPLES count]: about how many bytes the key's entry
# takes: the key, the value (a string's bytes, a hash's fields and
# values, a list's elements) and a few words for the cells that hold
# them. SAMPLES takes a long long
# not below 0 (BendKV counts every field: it samples none); any other word
# is a syntax error; both are read before the key is looked for, as
# Redis reads them.
def mem.sample(l: R.LL) -> Maybe<&2, R.Reply>:
  match l:
    case R.LL{neg, hi, lo}:
      Bool.pick(Maybe<&2, R.Reply>, neg, Some{R.RError{"ERR syntax error"}}, None{})
    case R.LLBad{}:
      Some{R.RError{"ERR value is not an integer or out of range"}}

def mem.word(ok: Bool, +v: String) -> Maybe<&2, R.Reply>:
  match ok:
    case True{}:
      mem.sample(R.ll.read(v))
    case False{}:
      Some{R.RError{"ERR syntax error"}}

def mem.opts(xs: List<&2, String>, bad: Maybe<&2, R.Reply>) -> Maybe<&2, R.Reply>:
  match xs bad:
    case _ Some{e}:
      Some{e}
    case Nil{} None{}:
      None{}
    case Con{+w, Con{+v, rest}} None{}:
      mem.opts(rest, mem.word(R.is_word(w, "SAMPLES"), v))
    case Con{w, Nil{}} None{}:
      Some{R.RError{"ERR syntax error"}}

def mem.pairs(ps: List<&2, KV.HPair>, +acc: Nat) -> Nat:
  match ps:
    case Nil{}:
      acc
    case Con{KV.HP{f, v}, rest}:
      mem.pairs(rest, Nat.add(acc, Nat.add(32n, Nat.add(String.length(f), String.length(v)))))

def mem.elems(xs: List<&2, String>, +acc: Nat) -> Nat:
  match xs:
    case Nil{}:
      acc
    case Con{x, rest}:
      mem.elems(rest, Nat.add(acc, Nat.add(16n, String.length(x))))

def mem.zels(xs: List<&2, KV.ZEl>, +acc: Nat) -> Nat:
  match xs:
    case Nil{}:
      acc
    case Con{KV.ZEl{+m, d}, rest}:
      mem.zels(rest, Nat.add(acc, Nat.add(24n, String.length(m))))

# a stream's nodes (their listpacks' bytes and a radix tree's node
# each), and its groups (each its pending entries and its consumers)
def mem.xnodes(xs: List<&2, KV.XNode>, +acc: Nat) -> Nat:
  match xs:
    case Nil{}:
      acc
    case Con{+x, rest}:
      mem.xnodes(rest, Nat.add(acc, Nat.add(64n, KV.xnode.bytes(x))))

def mem.xcons(cs: List<&2, KV.XCon>, +acc: Nat) -> Nat:
  match cs:
    case Nil{}:
      acc
    case Con{KV.XCon{+name, seen, +ids}, rest}:
      mem.xcons(rest, Nat.add(acc, Nat.add(Nat.add(48n, String.length(name)), Nat.mul(32n, KV.xis.size(ids)))))

def mem.xgroup(+g: KV.XGroup) -> Nat:
  match g:
    case KV.XGrp{+name, last, read, +pel, +cons}:
      mem.xcons(KV.xcs.list(cons, Nil{}), Nat.add(Nat.add(64n, String.length(name)), Nat.mul(80n, KV.xpl.size(pel))))
    case KV.XGrpOf{+y}:
      mem.xgroup(y)

def mem.xgroups(gs: List<&2, KV.XGroup>, +acc: Nat) -> Nat:
  match gs:
    case Nil{}:
      acc
    case Con{+g, rest}:
      mem.xgroups(rest, Nat.add(acc, mem.xgroup(g)))

def mem.stream(+x: KV.XStream) -> Nat:
  match x:
    case KV.XStr{n, last, first, maxdel, added, +nodes, +groups}:
      mem.xgroups(KV.xgs.list(groups, Nil{}), mem.xnodes(KV.xns.list(nodes, Nil{}), 112n))
    case KV.XStrOf{+y}:
      mem.stream(y)

def mem.val(+v: KV.Val) -> Nat:
  match v:
    case KV.VStr{+s}:
      Nat.add(16n, String.length(s))
    case KV.VColl{KV.CHash{+h}}:
      mem.pairs(KV.hash.pairs(h), 48n)
    case KV.VColl{KV.CList{+l}}:
      KV.deq.bytes(l)
    case KV.VColl{KV.CMems{+m}}:
      mem.elems(KV.mems.all(m), 48n)
    case KV.VColl{KV.CZset{+z}}:
      mem.zels(KV.zset.all(z), 48n)
    case KV.VColl{KV.CStream{+x}}:
      mem.stream(x)

def mem.size(+k: String, m: Maybe<&2, KV.Item<KV.Val>>) -> R.Reply:
  match m:
    case Some{KV.Item{+v, e}}:
      R.r_int(Nat.add(Nat.add(40n, String.length(k)), mem.val(v)))
    case None{}:
      R.RNull{}

# MEMORY USAGE's estimate of the bytes of key k and its entry (0 for none)
def mem.est(+k: String, m: Maybe<&2, KV.Item<KV.Val>>) -> Nat:
  match m:
    case Some{KV.Item{+v, e}}:
      Nat.add(Nat.add(40n, String.length(k)), mem.val(v))
    case None{}:
      0n

def mem.usage(bad: Maybe<&2, R.Reply>, +k: String, m: Maybe<&2, KV.Item<KV.Val>>) -> R.Reply:
  match bad:
    case Some{e}:
      e
    case None{}:
      mem.size(k, m)

# LCS a b [IDX] [LEN] [WITHMATCHLEN] [MINMATCHLEN n]: the longest common
# subsequence of two values (a key not there reads as an empty one), found
# as Redis 7.0.15 finds it: the table of the lengths of the LCS of every
# two prefixes, then a walk back from its last cell that takes a byte when
# both prefixes end with it, and otherwise drops the last byte of a when
# the cell above holds more than the cell to the left, else b's. LEN
# answers the length (with no walk); IDX the runs of bytes the walk took
# one after another, the last first, each as its range in a and in b,
# with its length after WITHMATCHLEN, and none shorter than MINMATCHLEN;
# otherwise the LCS itself. The options read in order, their errors as
# Redis's; the table, 4 bytes a cell in Redis, must fit in
# proto-max-bulk-len.
type LcsSt is Data:
  LsOpt{len: Bool, idx: Bool, wml: Bool, min: Nat}
  LsMin{len: Bool, idx: Bool, wml: Bool}
  LsErr{r: R.Reply}

def lcs.word(isidx: Bool, islen: Bool, iswml: Bool, ismin: Bool, len: Bool, idx: Bool, wml: Bool, min: Nat) -> LcsSt:
  match isidx islen iswml ismin:
    case True{} _ _ _:
      LsOpt{len, True{}, wml, min}
    case False{} True{} _ _:
      LsOpt{True{}, idx, wml, min}
    case False{} False{} True{} _:
      LsOpt{len, idx, True{}, min}
    case False{} False{} False{} True{}:
      LsMin{len, idx, wml}
    case False{} False{} False{} False{}:
      LsErr{R.r_syntax()}

# a magnitude hi * 10^9 + lo when small says it is below cap, else cap
# (the product is made only when it is small: a Nat stays below 2^48)
def lcs.cap(small: Bool, +hi: Nat, +lo: Nat, +cap: Nat) -> Nat:
  match small:
    case True{}:
      Nat.add(Nat.mul(hi, 1000000000n), lo)
    case False{}:
      cap

# MINMATCHLEN's number, a long long as Redis reads one: below 0 it is 0,
# and from 10^10, which no run reaches (a value holds less than 2^32
# bytes), 10^10
def lcs.min(l: R.LL, len: Bool, idx: Bool, wml: Bool) -> LcsSt:
  match l:
    case R.LL{+neg, +hi, +lo}:
      LsOpt{len, idx, wml, Bool.pick(Nat, neg, 0n, lcs.cap(Nat.is_lt(hi, 10n), hi, lo, Nat.mul(100000n, 100000n)))}
    case R.LLBad{}:
      LsErr{R.e_int()}

def lcs.opts(args: List<&2, String>, st: LcsSt) -> LcsSt:
  match args st:
    case _ LsErr{r}:
      LsErr{r}
    case Nil{} LsOpt{len, idx, wml, min}:
      LsOpt{len, idx, wml, min}
    case Nil{} LsMin{len, idx, wml}:
      LsErr{R.r_syntax()}
    case Con{+a, rest} LsOpt{len, idx, wml, min}:
      lcs.opts(rest, lcs.word(R.is_word(a, "IDX"), R.is_word(a, "LEN"), R.is_word(a, "WITHMATCHLEN"), R.is_word(a, "MINMATCHLEN"), len, idx, wml, min))
    case Con{+a, rest} LsMin{len, idx, wml}:
      lcs.opts(rest, lcs.min(R.ll.read(a), len, idx, wml))

# a row of the table, for a's byte x: from the row above (prev, from its
# cell j - 1, so that its first two cells are above-left and above) and
# the cell to the left; the row comes out reversed onto acc
def lcs.cell(+x: U32, +y: U32, +dg: Nat, +up: Nat, +left: Nat) -> Nat:
  Bool.pick(Nat, U32.is_eq(x, y), Nat.add(dg, 1n), Nat.max(up, left))

def lcs.row(+x: U32, bs: String, prev: List<&2, Nat>, +left: Nat, acc: List<&2, Nat>) -> List<&2, Nat>:
  match bs prev:
    case SCon{Chr{+y}, t} Con{+dg, Con{+up, ps}}:
      +c = lcs.cell(x, y, dg, up, left)
      lcs.row(x, t, Con{up, ps}, c, Con{c, acc})
    case _ _:
      acc

def lcs.zeros(n: Nat, acc: List<&2, Nat>) -> List<&2, Nat>:
  match n:
    case 0n:
      Con{0n, acc}
    case 1n+m:
      lcs.zeros(m, Con{0n, acc})

# the rows for the bytes of as, each reversed, the last first, onto acc;
# prev is the row above them, in order
def lcs.rows(as: String, +bs: String, prev: List<&2, Nat>, acc: List<&2, List<&2, Nat>>) -> List<&2, List<&2, Nat>>:
  match as:
    case SNil{}:
      acc
    case SCon{Chr{+x}, t}:
      +r = lcs.row(x, bs, prev, 0n, [0n])
      lcs.rows(t, bs, List.reverse(&2, Nat, r), Con{r, acc})

def lcs.hd(+xs: List<&2, Nat>) -> Nat:
  match xs:
    case Con{+x, r}:
      x
    case Nil{}:
      0n

def lcs.tl(xs: List<&2, Nat>) -> List<&2, Nat>:
  match xs:
    case Con{x, r}:
      r
    case Nil{}:
      Nil{}

# the row before the rows rest hold, from its cell j (n = |b| - j cells
# dropped), and the rows before it
def lcs.next(rest: List<&2, List<&2, Nat>>, +n: Nat) -> List<&2, Nat> & List<&2, List<&2, Nat>>:
  match rest:
    case Nil{}:
      (Nil{}, Nil{})
    case Con{r, rs}:
      (List.drop(&2, Nat, r, n), rs)

# a run of matches the walk took: its first and last byte in a and in b
type LRange is Data:
  LNone{}
  LRun{a0: Nat, a1: Nat, b0: Nat, b1: Nat}

# the walk at cell (i, j): a's bytes before i reversed, b's before j, the
# row i from cell j (reversed), the row i - 1 from cell j, the rows before
# it, the LCS after (i, j), the run being taken, the runs emitted
type LcsW is Data:
  LcsW{ar: String, br: String, cur: List<&2, Nat>, up: List<&2, Nat>, rest: List<&2, List<&2, Nat>>, i: Nat, j: Nat, res: String, m: LRange, out: List<&2, R.Reply>}

# a run as IDX answers it, unless shorter than MINMATCHLEN (0: none is),
# or without IDX
def lcs.emit.if(ok: Bool, r: R.Reply, out: List<&2, R.Reply>) -> List<&2, R.Reply>:
  match ok:
    case True{}:
      Con{r, out}
    case False{}:
      out

def lcs.pair(+x: Nat, +y: Nat) -> R.Reply:
  R.RArray{[R.r_int(x), R.r_int(y)]}

def lcs.emit(m: LRange, +idx: Bool, +wml: Bool, +min: Nat, out: List<&2, R.Reply>) -> List<&2, R.Reply>:
  match m:
    case LNone{}:
      out
    case LRun{+a0, +a1, +b0, +b1}:
      +n = Nat.add(Nat.sub(a1, a0), 1n)
      +ra = lcs.pair(a0, a1)
      +rb = lcs.pair(b0, b1)
      lcs.emit.if(Bool.and(idx, Bool.or(Nat.is_eq(min, 0n), Nat.is_le(min, n))), R.RArray{Bool.pick(List<&2, R.Reply>, wml, [ra, rb, R.r_int(n)], [ra, rb])}, out)

# the run after a match at bytes i - 1 and j - 1, and whether it is
# emitted now: a new run, or the run grown back by one byte when it starts
# at i and j (else it ends, and is emitted as it was); emitted too when it
# reaches the first byte of a or of b
type LHit is Data:
  LHit{r: LRange, emit: Bool}

def lcs.hit(m: LRange, +i: Nat, +j: Nat) -> LHit:
  match m:
    case LNone{}:
      LHit{LRun{Nat.sub(i, 1n), Nat.sub(i, 1n), Nat.sub(j, 1n), Nat.sub(j, 1n)}, Bool.or(Nat.is_eq(i, 1n), Nat.is_eq(j, 1n))}
    case LRun{+a0, +a1, +b0, +b1}:
      +ext = Bool.and(Nat.is_eq(a0, i), Nat.is_eq(b0, j))
      +c0 = Bool.pick(Nat, ext, Nat.sub(a0, 1n), a0)
      +d0 = Bool.pick(Nat, ext, Nat.sub(b0, 1n), b0)
      LHit{LRun{c0, a1, d0, b1}, Bool.or(Bool.not(ext), Bool.or(Nat.is_eq(c0, 0n), Nat.is_eq(d0, 0n)))}

def lcs.after(e: Bool, r: LRange) -> LRange:
  match e:
    case True{}:
      LNone{}
    case False{}:
      r

def lcs.out(e: Bool, r: LRange, +idx: Bool, +wml: Bool, +min: Nat, out: List<&2, R.Reply>) -> List<&2, R.Reply>:
  match e:
    case True{}:
      lcs.emit(r, idx, wml, min, out)
    case False{}:
      out

# the walk with the row above and the rows before it from lcs.next
def lcs.w(ar: String, br: String, cur: List<&2, Nat>, p: List<&2, Nat> & List<&2, List<&2, Nat>>, +i: Nat, +j: Nat, res: String, m: LRange, out: List<&2, R.Reply>) -> LcsW:
  (up, rest) = p
  LcsW{ar, br, cur, up, rest, i, j, res, m, out}

# a step on a match: the byte taken, to cell (i - 1, j - 1)
def lcs.matched(h: LHit, +x: U32, at: String, bt: String, up: List<&2, Nat>, rest: List<&2, List<&2, Nat>>, +i: Nat, +j: Nat, res: String, out: List<&2, R.Reply>, +bl: Nat, +idx: Bool, +wml: Bool, +min: Nat) -> LcsW:
  match h:
    case LHit{+r, +e}:
      lcs.w(at, bt, lcs.tl(up), lcs.next(rest, Nat.sub(bl, Nat.sub(j, 1n))), Nat.sub(i, 1n), Nat.sub(j, 1n), SCon{Chr{x}, res}, lcs.after(e, r), lcs.out(e, r, idx, wml, min, out))

# a step on no match: to cell (i - 1, j) when the cell above holds more
# than the cell to the left, else to (i, j - 1); a run being taken ends
def lcs.moved(upi: Bool, at: String, bt: String, ar: String, br: String, cur: List<&2, Nat>, up: List<&2, Nat>, rest: List<&2, List<&2, Nat>>, +i: Nat, +j: Nat, res: String, out: List<&2, R.Reply>, +bl: Nat) -> LcsW:
  match upi:
    case True{}:
      lcs.w(at, br, up, lcs.next(rest, Nat.sub(bl, j)), Nat.sub(i, 1n), j, res, LNone{}, out)
    case False{}:
      LcsW{ar, bt, lcs.tl(cur), lcs.tl(up), rest, i, Nat.sub(j, 1n), res, LNone{}, out}

def lcs.step.of(eq: Bool, +x: U32, at: String, bt: String, ar: String, br: String, +cur: List<&2, Nat>, +up: List<&2, Nat>, rest: List<&2, List<&2, Nat>>, +i: Nat, +j: Nat, res: String, m: LRange, out: List<&2, R.Reply>, +bl: Nat, +idx: Bool, +wml: Bool, +min: Nat) -> LcsW:
  match eq:
    case True{}:
      lcs.matched(lcs.hit(m, i, j), x, at, bt, up, rest, i, j, res, out, bl, idx, wml, min)
    case False{}:
      lcs.moved(Nat.is_lt(lcs.hd(lcs.tl(cur)), lcs.hd(up)), at, bt, ar, br, cur, up, rest, i, j, res, lcs.emit(m, idx, wml, min, out), bl)

# one step of the walk, none past the first row or column
def lcs.step(+bl: Nat, +idx: Bool, +wml: Bool, +min: Nat, w: LcsW) -> LcsW:
  match w:
    case LcsW{+ar, +br, cur, up, rest, +i, +j, res, m, out}:
      match ar br:
        case SCon{Chr{+x}, at} SCon{Chr{+y}, bt}:
          lcs.step.of(U32.is_eq(x, y), x, at, bt, ar, br, cur, up, rest, i, j, res, m, out, bl, idx, wml, min)
        case _ _:
          LcsW{ar, br, cur, up, rest, i, j, res, m, out}

# the walk, f steps at most (|a| + |b| reach the first row or column)
def lcs.walk(f: Nat, +bl: Nat, +idx: Bool, +wml: Bool, +min: Nat, w: LcsW) -> LcsW:
  match f:
    case 0n:
      w
    case 1n+g:
      lcs.walk(g, bl, idx, wml, min, lcs.step(bl, idx, wml, min, w))

def lcs.start(rows: List<&2, List<&2, Nat>>, +a: String, +b: String, +al: Nat, +bl: Nat) -> LcsW:
  match rows:
    case Con{r, Con{u, rest}}:
      LcsW{String.reverse(a), String.reverse(b), r, u, rest, al, bl, "", LNone{}, Nil{}}
    case Con{r, Nil{}}:
      LcsW{String.reverse(a), String.reverse(b), r, Nil{}, Nil{}, al, bl, "", LNone{}, Nil{}}
    case Nil{}:
      LcsW{"", "", Nil{}, Nil{}, Nil{}, 0n, 0n, "", LNone{}, Nil{}}

def lcs.top(rows: List<&2, List<&2, Nat>>) -> Nat:
  match rows:
    case Con{r, rs}:
      lcs.hd(r)
    case Nil{}:
      0n

def lcs.fin(w: LcsW, +idx: Bool, +n: Nat) -> R.Reply:
  match w:
    case LcsW{ar, br, cur, up, rest, i, j, res, m, out}:
      match idx:
        case True{}:
          R.RMap{[R.RBulk{"matches"}, R.RArray{List.reverse(&2, R.Reply, out)}, R.RBulk{"len"}, R.r_int(n)]}
        case False{}:
          R.RBulk{res}

def lcs.walked(lenonly: Bool, +rows: List<&2, List<&2, Nat>>, +a: String, +b: String, +idx: Bool, +wml: Bool, +min: Nat) -> R.Reply:
  match lenonly:
    case True{}:
      R.r_int(lcs.top(rows))
    case False{}:
      +al = String.length(a)
      +bl = String.length(b)
      lcs.fin(lcs.walk(Nat.add(al, bl), bl, idx, wml, min, lcs.start(rows, a, b, al, bl)), idx, lcs.top(rows))

def lcs.run(+a: String, +b: String, +len: Bool, +idx: Bool, +wml: Bool, +min: Nat) -> R.Reply:
  +z = lcs.zeros(String.length(b), Nil{})
  lcs.walked(Bool.and(len, Bool.not(idx)), lcs.rows(a, b, z, [z]), a, b, idx, wml, min)

# whether the table, (|a| + 1) * (|b| + 1) cells of 4 bytes, passes max,
# found without the product: |a| + 1 > (max / 4) / (|b| + 1)
def lcs.big(+la: Nat, +lb: Nat, +max: Nat) -> Bool:
  Nat.is_lt(Nat.div(Nat.div(max, 4n), Nat.add(lb, 1n)), Nat.add(la, 1n))

# proto-max-bulk-len, kept below 2^46: no table BendKV can build passes it
def lcs.max.of(l: R.LL) -> Nat:
  match l:
    case R.LL{neg, +hi, +lo}:
      lcs.cap(Nat.is_lt(hi, 70000n), hi, lo, Nat.mul(70000n, 1000000000n))
    case R.LLBad{}:
      536870912n

def lcs.check.of(both: Bool, big: Bool, +a: String, +b: String, +len: Bool, +idx: Bool, +wml: Bool, +min: Nat) -> R.Reply:
  match both big:
    case True{} _:
      R.RError{"ERR If you want both the length and indexes, please just use IDX."}
    case False{} True{}:
      R.RError{"ERR Insufficient memory, transient memory for LCS exceeds proto-max-bulk-len"}
    case False{} False{}:
      lcs.run(a, b, len, idx, wml, min)

def lcs.check(st: LcsSt, +a: String, +b: String, +max: Nat) -> R.Reply:
  match st:
    case LsOpt{+len, +idx, +wml, +min}:
      lcs.check.of(Bool.and(len, idx), lcs.big(String.length(a), String.length(b), max), a, b, len, idx, wml, min)
    case LsMin{len, idx, wml}:
      R.r_syntax()
    case LsErr{r}:
      r

def lcs.val(m: Maybe<&2, KV.Item<KV.Val>>) -> String:
  match m:
    case Some{KV.Item{KV.VStr{v}, e}}:
      v
    case _:
      ""

# whether a key holds a collection (Redis checks both keys before the
# options)
def lcs.coll(+m: Maybe<&2, KV.Item<KV.Val>>) -> Bool:
  match m:
    case Some{KV.Item{KV.VColl{c}, e}}:
      True{}
    case _:
      False{}

def lcs.typed(coll: Bool, rest: List<&2, String>, +ma: Maybe<&2, KV.Item<KV.Val>>, +mb: Maybe<&2, KV.Item<KV.Val>>, +cfg: List<&2, C.CItem>) -> R.Reply:
  match coll:
    case True{}:
      R.RError{"ERR The specified keys must contain string values"}
    case False{}:
      lcs.check(lcs.opts(rest, LsOpt{False{}, False{}, False{}, 0n}), lcs.val(ma), lcs.val(mb), lcs.max.of(R.ll.read(C.config.get_value(cfg, "proto-max-bulk-len"))))

def lcs.reply(args: List<&2, String>, +db: R.Db, +cfg: List<&2, C.CItem>) -> R.Reply:
  match args:
    case Con{+ka, Con{+kb, rest}}:
      +ma = R.db.ent(db, ka)
      +mb = R.db.ent(db, kb)
      lcs.typed(Bool.or(lcs.coll(ma), lcs.coll(mb)), rest, ma, mb, cfg)
    case _:
      R.RError{"ERR wrong number of arguments for 'lcs' command"}

# Pub/Sub
# -------
# A session keeps no subscription and knows no other client: it answers a
# command of Pub/Sub as Redis answers a client alone on the server that
# subscribes to nothing (the server keeps the subscriptions: server.bend,
# Pub/Sub). SUBSCRIBE and its kin answer a reply for each name, its count
# the names so far, each once; UNSUBSCRIBE and its kin a reply for each
# name, or one with no name when there are none, the count 0. Redis sends
# these replies even to a client whose replies are held back (CLIENT
# REPLY OFF or SKIP), and each on its own: a session gathers them in one
# array. PUBLISH reaches no one, no channel has a subscriber, no pattern
# is subscribed.

# the word of a reply of SUBSCRIBE (on) or UNSUBSCRIBE (off) of a kind
def pub.word(on: Bool, +kind: Nat) -> String:
  match on kind:
    case True{} 0n:
      "subscribe"
    case True{} 1n:
      "psubscribe"
    case True{} _:
      "ssubscribe"
    case False{} 0n:
      "unsubscribe"
    case False{} 1n:
      "punsubscribe"
    case False{} _:
      "sunsubscribe"

def pub.has(+n: String, +xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Con{+x, +rest}:
      Bool.or(String.eq(n, x), pub.has(n, rest))

# the reply of SUBSCRIBE and its kin for one name: a push (RESP2's array)
def pub.note(+w: String, n: R.Reply, +count: Nat) -> R.Reply:
  R.RPush{[R.RBulk{w}, n, R.RInt{R.IPos{count}}]}

def pub.seen(new: Bool, +n: String, seen: List<&2, String>) -> List<&2, String>:
  match new:
    case True{}:
      n <> seen
    case False{}:
      seen

# the replies of SUBSCRIBE of names, newest first in acc
def pub.subs(+w: String, names: List<&2, String>, +seen: List<&2, String>, acc: List<&2, R.Reply>) -> List<&2, R.Reply>:
  match names:
    case Nil{}:
      List.reverse(&2, R.Reply, acc)
    case Con{+n, rest}:
      +now = pub.seen(Bool.not(pub.has(n, seen)), n, seen)
      pub.subs(w, rest, now, pub.note(w, R.RBulk{n}, List.length(&2, String, now)) <> acc)

def pub.unsubs(+w: String, names: List<&2, String>) -> List<&2, R.Reply>:
  match names:
    case Nil{}:
      Nil{}
    case Con{n, rest}:
      pub.note(w, R.RBulk{n}, 0n) <> pub.unsubs(w, rest)

def pub.zeros(chans: List<&2, String>) -> List<&2, R.Reply>:
  match chans:
    case Nil{}:
      Nil{}
    case Con{c, rest}:
      R.RBulk{c} <> R.RInt{R.IPos{0n}} <> pub.zeros(rest)

def pub.reply(p: R.PubOp) -> R.Reply:
  match p:
    case R.PSub{+k, names}:
      R.RArray{pub.subs(pub.word(True{}, k), names, Nil{}, Nil{})}
    case R.PUnsub{+k, Nil{}}:
      R.RArray{[pub.note(pub.word(False{}, k), R.RNull{}, 0n)]}
    case R.PUnsub{+k, names}:
      R.RArray{pub.unsubs(pub.word(False{}, k), names)}
    case R.PPub{sh, c, m}:
      R.RInt{R.IPos{0n}}
    case R.PChans{sh, pat}:
      R.RArray{Nil{}}
    case R.PNumSub{sh, chans}:
      R.RArray{pub.zeros(chans)}
    case R.PNumPat{}:
      R.RInt{R.IPos{0n}}

# the reply sent: those of SUBSCRIBE and its kin whatever the mode
def pub.say(m: Mute, p: R.PubOp) -> Maybe<&2, R.Reply>:
  match p:
    case R.PSub{k, names}:
      Some{pub.reply(R.PSub{k, names})}
    case R.PUnsub{k, names}:
      Some{pub.reply(R.PUnsub{k, names})}
    case other:
      say(m, pub.reply(other))

# Clients
# -------
# CLIENT LIST, INFO, KILL, NO-EVICT, PAUSE and UNPAUSE (R.SClient), as
# Redis answers a client alone on the server: LIST and INFO show the
# client's own line, its addresses and its socket unknown here ("?:0", fd
# 0), KILL finds no other client to kill and its old form no address,
# NO-EVICT, PAUSE and UNPAUSE answer OK (a pause holds back no other
# client). The server answers them with every client it holds, and
# pauses them (server.bend, Clients, The pause). MONITOR (R.SMonitor) answers OK, as Redis answers a client
# alone on the server, which sees no command but its own; the server
# makes the client a monitor (server.bend, MONITOR).
def cl.cmd(+info: Bool) -> String:
  Bool.pick(String, info, "client|info", "client|list")

# the bytes of a command's arguments, from n (argv-mem)
def cl.argv(args: List<&2, String>, +n: Nat) -> Nat:
  match args:
    case Nil{}:
      n
    case Con{+a, rest}:
      cl.argv(rest, Nat.add(n, String.length(a)))

def cl.alone.line(+c: Conn, +info: Bool, +argv: Nat) -> String:
  R.client.line(R.ClLine{conn.id(c), "?:0", "?:0", 0n, conn.name(c), 0n, 0n, "N", conn.db(c), 0n, 0n, 0n, None{}, 0n, argv, cl.cmd(info), "default", "-1", conn.r3(c)}) ++ "\n"

def cl.ids(ids: List<&2, Nat>, +c: Conn, +argv: Nat, acc: String) -> String:
  match ids:
    case Nil{}:
      acc
    case Con{+i, rest}:
      cl.ids(rest, c, argv, acc ++ Bool.pick(String, Nat.is_eq(i, conn.id(c)), cl.alone.line(c, False{}, argv), ""))

def cl.list(+ty: Nat, ids: Maybe<&2, List<&2, Nat>>, +c: Conn, +argv: Nat) -> R.Reply:
  match ids:
    case Some{xs}:
      R.RVerb{cl.ids(xs, c, argv, "")}
    case None{}:
      R.RVerb{Bool.pick(String, Nat.is_le(ty, 1n), cl.alone.line(c, False{}, argv), "")}

# the first of the users CLIENT KILL's USER options named that the
# server does not keep (none: it keeps them all)
def cl.user.miss(us: List<&2, String>, +s: Srv) -> Maybe<&2, String>:
  match us:
    case Nil{}:
      None{}
    case Con{+u, rest}:
      Bool.pick(Maybe<&2, String>, U.acl.some(U.acl.user(srv.acl(s), u)), cl.user.miss(rest, s), Some{u})

# CLIENT KILL's answer after its USER options: the error after them, or
# none killed (a session knows no other client)
def cl.kill.or(e: Maybe<&2, R.Reply>) -> R.Reply:
  match e:
    case Some{r}:
      r
    case None{}:
      R.RInt{R.IPos{0n}}

# CLIENT KILL's answer when a user its USER options named is not kept
def cl.users.of(m: Maybe<&2, String>, r: R.Reply) -> R.Reply:
  match m:
    case Some{+u}:
      R.e_no_user(u)
    case None{}:
      r

def cl.reply(op: R.ClOp, +c: Conn, +argv: Nat, +s: Srv) -> R.Reply:
  match op:
    case R.CoList{+ty, ids}:
      cl.list(ty, ids, c, argv)
    case R.CoInfo{}:
      R.RVerb{cl.alone.line(c, True{}, argv)}
    case R.CoKill{f}:
      R.RInt{R.IPos{0n}}
    case R.CoKillAddr{a}:
      R.RError{"ERR No such client"}
    case R.CoKillUsers{us, f, e}:
      cl.users.of(cl.user.miss(us, s), cl.kill.or(e))
    case R.CoNoEvict{on}:
      R.r_ok()
    case R.CoPause{hi, lo, all}:
      R.r_ok()
    case R.CoUnpause{}:
      R.r_ok()
    case R.CoTrack{on, opts}:
      R.r_ok()
    case R.CoCaching{yes}:
      R.RError{"ERR CLIENT CACHING can be called only when the client is in tracking mode with OPTIN or OPTOUT mode enabled"}
    case R.CoGetRedir{}:
      R.RInt{R.INeg{0n}}
    case R.CoTrackInfo{}:
      R.tracking_info()
    case R.CoBad{r}:
      r

# SORT with STORE's reply: how many values it stores at its destination,
# or its error, on the database in focus as it is before the act that
# writes them (ASort)
def sort.reply(+ds: R.Ds, +k: String, o: R.SortO) -> R.Reply:
  +d = R.ds.focused(ds)
  R.sort.store.reply(R.db.trie(d), R.db.now(d), k, o)

# The administrative commands
# ---------------------------
# LASTSAVE answers the time of the last save that ended well, the start
# until one does (Redis's lastsave; server.bend, The RDB file); MEMORY
# STATS and MEMORY DOCTOR the numbers INFO's memory section shows
# (info.bend, MEMORY STATS and MEMORY DOCTOR); LOLWUT VERSION 5 and 6
# their drawings (lolwut.bend), from the server's random numbers. SAVE
# writes the RDB file, and SHUTDOWN stops the server, after a save when it
# is to save one (server.bend, The RDB file and SHUTDOWN): the shell
# answers them once it has saved, or answers a SHUTDOWN whose save failed
# as Redis does. A session alone writes nothing and stops nothing: it
# answers OK for each.

# SLOWLOG GET's count: none for 10, -1 for all
def slow.get(+t: I.Tim, +args: List<&2, String>) -> R.Reply:
  match args:
    case Con{+c, rest}:
      I.slow.get(t, String.eq(c, "-1"), C.dec.small(c, 0n))
    case Nil{}:
      I.slow.get(t, False{}, 10n)

# the first argument (an event's name)
def arg.first(+args: List<&2, String>) -> String:
  match args:
    case Con{+x, rest}:
      x
    case Nil{}:
      ""

# SLOWLOG and LATENCY (info.bend, SLOWLOG and LATENCY), at the second of
# the group's time; LATENCY DOCTOR knows of no huge pages of the process
def latency.reply.of(+k: Nat, +args: List<&2, String>, +s: Srv, +t: I.Tim, +now: Nat) -> R.Reply:
  match k:
    case 6n:
      slow.get(t, args)
    case 7n:
      I.slow.len(t)
    case 8n:
      R.r_ok()
    case 9n:
      R.RArray{I.lat.latest(I.tim.evs(t))}
    case 10n:
      I.lat.history(I.lat.get(I.tim.evs(t), arg.first(args)))
    case 11n:
      R.r_int(I.lat.reset.n(I.lat.reset.of(I.tim.evs(t), args)))
    case 12n:
      I.lat.graph(I.lat.get(I.tim.evs(t), arg.first(args)), arg.first(args), now)
    case 13n:
      R.RVerb{I.lat.doctor(t, srv.cfg(s), now, False{})}
    case _:
      I.lat.histogram(I.info.stats(srv.info(s)), args)

def latency.reply(+k: Nat, +args: List<&2, String>, +s: Srv, +ds: R.Ds) -> R.Reply:
  latency.reply.of(k, args, s, I.info.tim(srv.info(s)), Nat.div(R.ds.now(ds), 1000n))

def admin.reply(+k: Nat, +args: List<&2, String>, +s: Srv, +ds: R.Ds) -> R.Reply:
  match k:
    case 0n:
      R.r_int(I.info.lastsave(srv.info(s)))
    case 1n:
      I.mem.stats(srv.info(s), R.ds.list(ds))
    case 2n:
      R.RVerb{I.mem.doctor(srv.info(s))}
    case 3n:
      R.RVerb{L.five(args, KV.mix(srv.rng(s)))}
    case 4n:
      R.r_ok()
    case 5n:
      R.RVerb{L.six(args, KV.mix(srv.rng(s)))}
    case 15n:
      R.r_ok()
    case _:
      latency.reply(k, args, s, ds)

# ACL
# ---
# ACL's subcommands (R.SAcl: their number, as R.acl_id gives it, and their
# arguments), on the users the server keeps (srv.acl): the session answers
# them and changes the users; the server answers WHOAMI from its clients,
# closes the clients of the users DELUSER removed and of the channels
# SETUSER takes away, and adds what it refuses to the log (server.bend,
# ACL). A session alone is the default user's (WHOAMI).

# ACL LOG's count, as getLongFromObjectOrReply reads it (a long long),
# negative as 0, one past 10^14 as 10^14, more than the log holds
def acl.count(+l: R.LL) -> Maybe<&2, Nat>:
  match l:
    case R.LL{+neg, +hi, +lo}:
      Some{Bool.pick(Nat, neg, 0n, Nat.add(Nat.mul(Nat.min(hi, 100000n), 1000000000n), lo))}
    case R.LLBad{}:
      None{}

def acl.log.of(m: Maybe<&2, Nat>, +s: Srv, +ds: R.Ds) -> R.Reply:
  match m:
    case Some{+n}:
      U.acl.log.reply(srv.acl(s), n, R.ds.now(ds))
    case None{}:
      R.e_int()

# ACL LOG: RESET (any case), a count, or the default 10
def acl.logs.reply(+args: List<&2, String>, +s: Srv, +ds: R.Ds) -> R.Reply:
  match args:
    case Con{+x, Nil{}}:
      Bool.pick(R.Reply, R.is_word(x, "RESET"), R.r_ok(), acl.log.of(acl.count(R.ll.read(x)), s, ds))
    case _:
      U.acl.log.reply(srv.acl(s), 10n, R.ds.now(ds))

def acl.bits.of(+l: R.LL) -> Nat:
  match l:
    case R.LL{+neg, +hi, +lo}:
      Bool.pick(Nat, Bool.or(neg, Bool.or(Nat.is_lt(0n, hi), Nat.is_lt(4096n, lo))), 0n, lo)
    case R.LLBad{}:
      0n

# ACL GENPASS's bits: 256 by default, else a long from 1 to 4096; 0 for
# an argument it refuses
def acl.bits(+args: List<&2, String>) -> Nat:
  match args:
    case Con{+x, Nil{}}:
      acl.bits.of(R.ll.read(x))
    case _:
      256n

def acl.genpass.err.of(+l: R.LL) -> R.Reply:
  match l:
    case R.LL{neg, hi, lo}:
      R.RError{"ERR ACL GENPASS argument must be the number of bits for the output password, a positive number up to 4096"}
    case R.LLBad{}:
      R.e_int()

def acl.genpass.err(+args: List<&2, String>) -> R.Reply:
  match args:
    case Con{+x, Nil{}}:
      acl.genpass.err.of(R.ll.read(x))
    case _:
      R.e_int()

def acl.genpass.reply(+args: List<&2, String>, +s: Srv) -> R.Reply:
  +b = acl.bits(args)
  Bool.pick(R.Reply, Nat.is_eq(b, 0n), acl.genpass.err(args), R.RBulk{U.acl.genpass(srv.acl(s), b)})

# whether new users and resetchannels get every channel
# (acl-pubsub-default)
def acl.allch(+s: Srv) -> Bool:
  String.eq(C.config.get_value(srv.cfg(s), "acl-pubsub-default"), "allchannels")

def acl.set.reply(r: U.SetR) -> R.Reply:
  match r:
    case U.SetOk{a, old}:
      R.r_ok()
    case U.SetErr{m}:
      R.RError{m}

def acl.set.srv(r: U.SetR, s: Srv) -> Srv:
  match r:
    case U.SetOk{a, old}:
      srv.acl.set(s, a)
    case U.SetErr{m}:
      s

def acl.del.reply(r: U.DelR) -> R.Reply:
  match r:
    case U.DelOk{n, a}:
      R.r_int(n)
    case U.DelErr{m}:
      R.RError{m}

def acl.del.srv(r: U.DelR, s: Srv) -> Srv:
  match r:
    case U.DelOk{n, a}:
      srv.acl.set(s, a)
    case U.DelErr{m}:
      s

def acl.cat.of(+args: List<&2, String>) -> R.Reply:
  match args:
    case Con{+c, Nil{}}:
      U.acl.cat.reply(U.acl.cat(c), c)
    case _:
      U.acl.cats.reply()

def acl.setuser.of(+args: List<&2, String>, +s: Srv) -> U.SetR:
  match args:
    case Con{+n, rules}:
      U.acl.setuser(srv.acl(s), n, rules, acl.allch(s))
    case Nil{}:
      U.SetErr{"ERR wrong number of arguments for 'acl|setuser' command"}

# an ACL subcommand's reply (by number: 1 CAT, 2 DELUSER, 3 DRYRUN, 4
# GENPASS, 5 GETUSER, 7 LIST, 9 LOG, 11 SETUSER, 12 USERS, 13 WHOAMI; the
# parser answers HELP, LOAD and SAVE)
def acl.reply(+k: Nat, +args: List<&2, String>, +s: Srv, +ds: R.Ds) -> R.Reply:
  match k:
    case 1n:
      acl.cat.of(args)
    case 2n:
      acl.del.reply(U.acl.deluser(srv.acl(s), args))
    case 3n:
      U.acl.dryrun(srv.acl(s), args)
    case 4n:
      acl.genpass.reply(args, s)
    case 5n:
      U.acl.getuser(srv.acl(s), arg.first(args))
    case 7n:
      U.acl.list(srv.acl(s))
    case 9n:
      acl.logs.reply(args, s, ds)
    case 11n:
      acl.set.reply(acl.setuser.of(args, s))
    case 12n:
      U.acl.usernames(srv.acl(s))
    case _:
      R.RBulk{"default"}

def acl.genpass.srv(+b: Nat, s: Srv) -> Srv:
  match b:
    case 0n:
      s
    case _:
      +s0 = s
      srv.acl.set(s0, U.acl.genpassed(srv.acl(s0), b))

def acl.log.srv(+args: List<&2, String>, s: Srv) -> Srv:
  match args:
    case Con{+x, Nil{}}:
      +s0 = s
      Bool.pick(Srv, R.is_word(x, "RESET"), srv.acl.set(s0, U.acl.log.reset(srv.acl(s0))), s0)
    case _:
      s

# the server after an ACL subcommand: DELUSER and SETUSER change its
# users, LOG RESET empties the log, and GENPASS counts its blocks
def acl.srv(+k: Nat, +args: List<&2, String>, +s: Srv) -> Srv:
  match k:
    case 2n:
      acl.del.srv(U.acl.deluser(srv.acl(s), args), s)
    case 4n:
      acl.genpass.srv(acl.bits(args), s)
    case 9n:
      acl.log.srv(args, s)
    case 11n:
      acl.set.srv(acl.setuser.of(args, s), s)
    case _:
      s

# a session command's reply, sent or not; the databases are there for
# the commands that read them
# SCRIPT as a session alone answers it: EXISTS that it knows no script
# (a 0 for each sha), FLUSH OK, KILL that no script runs, LOAD that it
# has no engine; the server answers them from its engine and its cache
# (server.bend, Scripts)
def script.zeros(+a: List<&2, String>) -> List<&2, R.Reply>:
  match a:
    case Nil{}:
      Nil{}
    case Con{x, rest}:
      R.RInt{R.IPos{0n}} <> script.zeros(rest)

def script.reply(+k: Nat, +a: List<&2, String>) -> R.Reply:
  match k:
    case 2n:
      R.RArray{script.zeros(a)}
    case 3n:
      R.r_ok()
    case 4n:
      R.RError{"NOTBUSY No scripts in execution right now."}
    case _:
      R.RError{"ERR a session alone runs no Lua script"}

def own_reply(+o: R.SessOp, +c: Conn, +s: Srv, +ds: R.Ds) -> Maybe<&2, R.Reply>:
  match o:
    case R.SHello{args}:
      say(conn.mode(c), hello.fin(hello.run(s, c, args), conn.id(c), nopass(s)))
    case R.SAuth{args}:
      say(conn.mode(c), auth.reply(args, s))
    case R.SSelect{+d}:
      say(conn.mode(c), idx.reply(select.idx(d, s)))
    case R.SQuit{}:
      say(conn.mode(c), R.r_ok())
    case R.SReset{}:
      reset.out(conn.mode(c))
    case R.SClientId{}:
      say(conn.mode(c), R.r_int(conn.id(c)))
    case R.SClientGetName{}:
      say(conn.mode(c), getname(conn.name(c)))
    case R.SClientSetName{n}:
      say(conn.mode(c), Bool.pick(R.Reply, name_ok(n), R.r_ok(), e_name()))
    case R.SClientReply{m}:
      reply.out(reply_word(m), conn.mode(c))
    case R.SConfigGet{args}:
      say(conn.mode(c), C.config.get(args, srv.cfg(s)))
    case R.SConfigSet{args}:
      say(conn.mode(c), C.config.set.reply(C.config.set(args, srv.cfg(s))))
    case R.SConfigResetStat{}:
      say(conn.mode(c), R.r_ok())
    case R.SInfo{args}:
      say(conn.mode(c), R.RVerb{I.text(args, srv.cfg(s), srv.info(s), ds)})
    case R.SCommand{args}:
      say(conn.mode(c), K.reply(args))
    case R.SRandomKey{}:
      say(conn.mode(c), randomkey.of(R.ds.focused(ds), KV.mix(srv.rng(s))))
    case R.SSwapDb{+a, +b}:
      say(conn.mode(c), swap.reply(swap.idx(a, b, s)))
    case R.SMove{+k, +d}:
      say(conn.mode(c), move.reply(k, move.idx(d, c, s), ds))
    case R.SFlushAll{}:
      say(conn.mode(c), R.r_ok())
    case R.STime{}:
      say(conn.mode(c), time.reply(R.ds.now(ds)))
    case R.SObject{+sub, +k}:
      say(conn.mode(c), obj.reply(sub, R.ds.ent(ds, k), srv.cfg(s), obj.use(sub, 0, R.ds.now(ds), I.info.start(srv.info(s)), mm.lfu(srv.mm(s)), mm.lfd(srv.mm(s)))))
    case R.SCopy{+args}:
      say(conn.mode(c), copy.reply(copy.of(args, c, s), ds))
    case R.SLcs{args}:
      say(conn.mode(c), lcs.reply(args, R.ds.focused(ds), srv.cfg(s)))
    case R.SHRandField{+k, args}:
      say(conn.mode(c), hr.reply(hr.args(args), R.ds.ent(ds, k), KV.mix(srv.rng(s))))
    case R.SMemUsage{+k, args}:
      say(conn.mode(c), mem.usage(mem.opts(args, None{}), k, R.ds.ent(ds, k)))
    case R.SReply{r}:
      say(conn.mode(c), r)
    case R.SBad{r}:
      say(conn.mode(c), r)
    case R.SFail{r}:
      say(conn.mode(c), r)
    case R.SSPop{+k, args}:
      say(conn.mode(c), sp.reply(sp.args(args), k, KV.mix(srv.rng(s)), R.ds.focused(ds)))
    case R.SSRandMember{+k, args}:
      say(conn.mode(c), sr.reply(sr.args(args), R.ds.ent(ds, k), KV.mix(srv.rng(s))))
    case R.SZRandMember{+k, args}:
      say(conn.mode(c), zr.reply(zr.args(args), R.ds.ent(ds, k), KV.mix(srv.rng(s))))
    case R.SBlock{+id, args}:
      say(conn.mode(c), blk.reply(blk.parse(id, args), R.ds.focused(ds)))
    case R.SUnblock{i, e}:
      say(conn.mode(c), R.RInt{R.IPos{0n}})
    case R.SMulti{}:
      say(conn.mode(c), R.r_ok())
    case R.SExec{}:
      say(conn.mode(c), R.RError{"ERR EXEC without MULTI"})
    case R.SDiscard{}:
      say(conn.mode(c), R.RError{"ERR DISCARD without MULTI"})
    case R.SWatch{ks}:
      say(conn.mode(c), R.r_ok())
    case R.SUnwatch{}:
      say(conn.mode(c), R.r_ok())
    case R.SPub{+k, a}:
      pub.say(conn.mode(c), R.pub.op(k, a))
    case R.SClient{+k, +a}:
      say(conn.mode(c), cl.reply(R.client.op(k, a), c, cl.argv(a, 10n), s))
    case R.SMonitor{}:
      say(conn.mode(c), R.r_ok())
    case R.SRewrite{}:
      say(conn.mode(c), R.RStatus{"Background append only file rewriting started"})
    case R.SSortStore{+k, o}:
      say(conn.mode(c), sort.reply(ds, k, o))
    case R.SPfCount{ks}:
      say(conn.mode(c), R.pf.count(ks, R.ds.focused(ds)))
    case R.SPfMerge{+d, srcs}:
      say(conn.mode(c), R.pf.merge.reply(d, srcs, R.ds.focused(ds)))
    case R.SPfSelfTest{}:
      say(conn.mode(c), R.pf.selftest())
    case R.SAdmin{+k, +a}:
      say(conn.mode(c), admin.reply(k, a, s, ds))
    case R.SGeoStore{+k, a}:
      say(conn.mode(c), R.geo.store.reply(R.ds.focused(ds), k, a))
    case R.SEval{h, xs}:
      say(conn.mode(c), R.RError{"ERR a session alone runs no Lua script"})
    case R.SScript{+k, +a}:
      say(conn.mode(c), script.reply(k, a))
    case R.SRestore{+k, op}:
      say(conn.mode(c), R.reply_of(R.exec(R.Upd{k, op}, R.ds.focused(ds))))
    case R.SAcl{+k, +a}:
      say(conn.mode(c), acl.reply(k, a, s, ds))

# the connection after a session command
def own_conn(+o: R.SessOp, +c: Conn, +s: Srv) -> Conn:
  match o:
    case R.SHello{args}:
      hello.conn(hello.run(s, c, args), c, s)
    case R.SAuth{args}:
      auth.conn(auth.ok(args, s), c, s)
    case R.SSelect{+d}:
      select.conn(select.idx(d, s), c, s)
    case R.SQuit{}:
      quit.conn(c, s)
    case R.SReset{}:
      reset.conn(c, s)
    case R.SClientId{}:
      step_conn(c, s)
    case R.SClientGetName{}:
      step_conn(c, s)
    case R.SClientSetName{+n}:
      setname.conn(name_ok(n), n, c, s)
    case R.SClientReply{+m}:
      mode.conn(reply.mode(reply_word(m), conn.mode(c)), c, s)
    case R.SConfigGet{a}:
      step_conn(c, s)
    case R.SConfigSet{a}:
      step_conn(c, s)
    case R.SConfigResetStat{}:
      step_conn(c, s)
    case R.SInfo{a}:
      step_conn(c, s)
    case R.SCommand{a}:
      step_conn(c, s)
    case R.SRandomKey{}:
      step_conn(c, s)
    case R.SSwapDb{a, b}:
      step_conn(c, s)
    case R.SMove{k, d}:
      step_conn(c, s)
    case R.SFlushAll{}:
      step_conn(c, s)
    case R.STime{}:
      step_conn(c, s)
    case R.SObject{sub, k}:
      step_conn(c, s)
    case R.SCopy{a}:
      step_conn(c, s)
    case R.SLcs{a}:
      step_conn(c, s)
    case R.SHRandField{k, a}:
      step_conn(c, s)
    case R.SMemUsage{k, a}:
      step_conn(c, s)
    case R.SReply{r}:
      step_conn(c, s)
    case R.SBad{r}:
      step_conn(c, s)
    case R.SFail{r}:
      step_conn(c, s)
    case R.SSPop{k, a}:
      step_conn(c, s)
    case R.SSRandMember{k, a}:
      step_conn(c, s)
    case R.SZRandMember{k, a}:
      step_conn(c, s)
    case R.SBlock{i, a}:
      step_conn(c, s)
    case R.SUnblock{i, e}:
      step_conn(c, s)
    case R.SMulti{}:
      step_conn(c, s)
    case R.SExec{}:
      step_conn(c, s)
    case R.SDiscard{}:
      step_conn(c, s)
    case R.SWatch{ks}:
      step_conn(c, s)
    case R.SUnwatch{}:
      step_conn(c, s)
    case R.SPub{k, a}:
      step_conn(c, s)
    case R.SClient{k, a}:
      step_conn(c, s)
    case R.SMonitor{}:
      step_conn(c, s)
    case R.SRewrite{}:
      step_conn(c, s)
    case R.SSortStore{k, o}:
      step_conn(c, s)
    case R.SPfCount{ks}:
      step_conn(c, s)
    case R.SPfMerge{d, srcs}:
      step_conn(c, s)
    case R.SPfSelfTest{}:
      step_conn(c, s)
    case R.SAdmin{k, a}:
      step_conn(c, s)
    case R.SGeoStore{k, a}:
      step_conn(c, s)
    case R.SEval{h, xs}:
      step_conn(c, s)
    case R.SScript{k, a}:
      step_conn(c, s)
    case R.SRestore{k, op}:
      step_conn(c, s)
    case R.SAcl{k, a}:
      step_conn(c, s)

# what a session command does to the databases: SELECT and RESET move the
# focus to the connection's new database, SWAPDB, MOVE, COPY and FLUSHALL
# act on the databases, SPOP and a blocking command that runs at once on
# the focus, SORT with STORE, PFMERGE and a GEO search that stores write
# their destination there, RESTORE with IDLETIME or FREQ its key, and the
# others do nothing to them
def own_acts(+o: R.SessOp, +c: Conn, +s: Srv) -> List<&2, R.Act>:
  match o:
    case R.SSelect{+d}:
      select.acts(select.idx(d, s))
    case R.SReset{}:
      [R.AFocus{0n}]
    case R.SSwapDb{+a, +b}:
      swap.acts(swap.idx(a, b, s))
    case R.SMove{+k, +d}:
      move.acts(k, move.idx(d, c, s))
    case R.SCopy{+args}:
      copy.acts(copy.of(args, c, s))
    case R.SFlushAll{}:
      [R.AWipe{}]
    case R.SSPop{+k, args}:
      sp.acts(sp.args(args), k, KV.mix(srv.rng(s)))
    case R.SBlock{+id, args}:
      blk.acts(blk.parse(id, args))
    case R.SSortStore{+k, o}:
      [R.ASort{k, o}]
    case R.SPfMerge{+d, srcs}:
      [R.APfMerge{d, srcs}]
    case R.SGeoStore{+k, a}:
      [R.AGeo{k, a}]
    case R.SRestore{+k, op}:
      [R.ARun{R.Upd{k, op}}]
    case _:
      Nil{}

def srv.set(r: Result<&2, &2, R.Reply, List<&2, C.CItem>>, +s: Srv) -> Srv:
  match r:
    case Done{+cfg}:
      Srv{C.config.get_value(cfg, "requirepass"), cfg, srv.timing(srv.info(s), cfg), mm.cfg(srv.mm(s), cfg)}
    case Fail{e}:
      s

# CONFIG RESETSTAT: INFO's counts start again
def srv.reset(s: Srv) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.reset(info), mm}

# RANDOMKEY: the next state of the random numbers (mm.rand)
def srv.rand(s: Srv) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, info, mm.rand(mm)}

# SLOWLOG RESET and LATENCY RESET of events (all for none)
def srv.slow.reset(s: Srv) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.slow.reset(info), mm}

def srv.lat.reset(s: Srv, names: List<&2, String>) -> Srv:
  match s:
    case Srv{pass, cfg, info, mm}:
      Srv{pass, cfg, I.info.lat.reset(info, names), mm}

# the server after an administrative command: LOLWUT's drawings take its
# random numbers, SLOWLOG RESET and LATENCY RESET change its timing
def admin.srv(+k: Nat, a: List<&2, String>, +s: Srv) -> Srv:
  match k:
    case 3n:
      srv.rand(s)
    case 5n:
      srv.rand(s)
    case 8n:
      srv.slow.reset(s)
    case 11n:
      srv.lat.reset(s, a)
    case _:
      s

# the server after a session command: CONFIG SET changes it when it
# succeeds, CONFIG RESETSTAT its counts, and RANDOMKEY, HRANDFIELD and
# LOLWUT's drawings its random numbers
def own_srv(+o: R.SessOp, +c: Conn, +s: Srv) -> Srv:
  match o:
    case R.SConfigSet{args}:
      srv.set(C.config.set(args, srv.cfg(s)), s)
    case R.SConfigResetStat{}:
      srv.reset(s)
    case R.SRandomKey{}:
      srv.rand(s)
    case R.SHRandField{k, a}:
      srv.rand(s)
    case R.SSPop{k, a}:
      srv.rand(s)
    case R.SSRandMember{k, a}:
      srv.rand(s)
    case R.SZRandMember{k, a}:
      srv.rand(s)
    case R.SAdmin{+k, a}:
      admin.srv(k, a, s)
    case R.SAcl{+k, +a}:
      acl.srv(k, a, s)
    case _:
      s

# A batch
# -------

# what a command is to a session: a command on the database, one of the
# connection or of the server (R.Own), or an error the parser found
# (R.Bad), which exec answers whoever the client is, and which changes
# nothing
type Role is Data:
  KData{}
  KSess{s: R.SessOp}
  KBad{}

def kind(+c: R.Cmd) -> Role:
  match c:
    case R.Own{o}:
      KSess{o}
    case R.Bad{r}:
      KBad{}
    case _:
      KData{}

# the session commands a client may run before it authenticates, with
# the errors the parser refuses a session command for (SBad); a failed
# call's error (SFail) waits for AUTH, as Redis's command runs only then
def no_auth(+o: R.SessOp) -> Bool:
  match o:
    case R.SHello{a}:
      True{}
    case R.SAuth{a}:
      True{}
    case R.SQuit{}:
      True{}
    case R.SReset{}:
      True{}
    case R.SBad{r}:
      True{}
    case _:
      False{}

# whether a command of kind k runs now
def may(+k: Role, +c: Conn, +s: Srv) -> Bool:
  match k:
    case KData{}:
      authed(c, s)
    case KSess{o}:
      Bool.or(no_auth(o), authed(c, s))
    case KBad{}:
      True{}

# a batch so far on the general path: its replies and its effects
# (newest first), the connection, the server and the databases
type Gen is Data:
  Gen{rs: List<&2, R.Reply>, es: List<&2, A.Eff>, conn: Conn, srv: Srv, ds: R.Ds}

# the replies, the effects and the databases after a command; the
# connection and the server after it come apart (next_conn, next_srv),
# for they do not depend on the databases
type Out is Data:
  Out{rs: List<&2, R.Reply>, es: List<&2, A.Eff>, ds: R.Ds}

# a command of one database run on the focus with its effects (A.act):
# its reply, sent or not, and its effects, put before those of the
# commands before it
def out.data(rs: List<&2, R.Reply>, es: List<&2, A.Eff>, m: Mute, r: R.Reply & (List<&2, A.Eff> & R.Ds)) -> Out:
  (+x, q) = r
  (e, d) = q
  Out{put(say(m, x), rs), List.reverse.go(&2, A.Eff, e, es), d}

# a session command: its reply, sent or not, and what its acts did
def out.own(rs: List<&2, R.Reply>, q: List<&2, A.Eff> & R.Ds) -> Out:
  (es, d) = q
  Out{rs, es, d}

def out.k(+k: Role, ok: Bool, +c: R.Cmd, rs: List<&2, R.Reply>, es: List<&2, A.Eff>, +conn: Conn, +srv: Srv, ds: R.Ds) -> Out:
  match k ok:
    case KSess{o} True{}:
      +x = ds
      out.own(put(own_reply(o, conn, srv, x), rs), A.acts(own_acts(o, conn, srv), (es, x)))
    case KSess{o} False{}:
      Out{put(say(conn.mode(conn), e_noauth()), rs), es, ds}
    case _ True{}:
      out.data(rs, es, conn.mode(conn), A.act(R.ARun{c}, ds))
    case _ False{}:
      Out{put(say(conn.mode(conn), e_noauth()), rs), es, ds}

def out.q(quit: Bool, +c: R.Cmd, rs: List<&2, R.Reply>, es: List<&2, A.Eff>, +conn: Conn, +srv: Srv, ds: R.Ds) -> Out:
  match quit:
    case True{}:
      Out{rs, es, ds}
    case False{}:
      +k = kind(c)
      out.k(k, may(k, conn, srv), c, rs, es, conn, srv, ds)

def next_conn.k(+k: Role, ok: Bool, +conn: Conn, +srv: Srv) -> Conn:
  match k ok:
    case KSess{o} True{}:
      own_conn(o, conn, srv)
    case _ _:
      step_conn(conn, srv)

def next_conn(quit: Bool, +c: R.Cmd, +conn: Conn, +srv: Srv) -> Conn:
  match quit:
    case True{}:
      conn
    case False{}:
      +k = kind(c)
      next_conn.k(k, may(k, conn, srv), conn, srv)

def next_srv.k(+k: Role, ok: Bool, +conn: Conn, +srv: Srv) -> Srv:
  match k ok:
    case KSess{o} True{}:
      own_srv(o, conn, srv)
    case _ _:
      srv

def next_srv(quit: Bool, +c: R.Cmd, +conn: Conn, +srv: Srv) -> Srv:
  match quit:
    case True{}:
      srv
    case False{}:
      +k = kind(c)
      next_srv.k(k, may(k, conn, srv), conn, srv)

def gen.mk(o: Out, conn: Conn, srv: Srv) -> Gen:
  match o:
    case Out{rs, es, ds}:
      Gen{rs, es, conn, srv, ds}

def gen.step(+c: R.Cmd, st: Gen) -> Gen:
  match st:
    case Gen{rs, es, +conn, +srv, ds}:
      +q = conn.quit(conn)
      gen.mk(out.q(q, c, rs, es, conn, srv, ds), next_conn(q, c, conn, srv), next_srv(q, c, conn, srv))

def gen.go(cmds: List<&2, R.Cmd>, st: Gen) -> Gen:
  match cmds:
    case Nil{}:
      st
    case Con{c, rest}:
      gen.go(rest, gen.step(c, st))

def gen(conn: Conn, srv: Srv, cmds: List<&2, R.Cmd>, ds: R.Ds) -> Gen:
  gen.go(cmds, Gen{Nil{}, Nil{}, conn, srv, ds})

# what a command that runs does to the databases: a command of one
# database runs on the focus (as exec runs it; an error the parser found
# among them answers and changes nothing), a session command acts as
# own_acts says
def acts.k(+k: Role, ok: Bool, +c: R.Cmd, +conn: Conn, +srv: Srv) -> List<&2, R.Act>:
  match k ok:
    case KSess{o} True{}:
      own_acts(o, conn, srv)
    case KSess{o} False{}:
      Nil{}
    case _ True{}:
      [R.ARun{c}]
    case _ False{}:
      Nil{}

def acts.q(quit: Bool, +c: R.Cmd, +conn: Conn, +srv: Srv) -> List<&2, R.Act>:
  match quit:
    case True{}:
      Nil{}
    case False{}:
      +k = kind(c)
      acts.k(k, may(k, conn, srv), c, conn, srv)

# what a batch does to the databases, in order, as R.acts runs it: the
# spec of gen
def plan(cmds: List<&2, R.Cmd>, conn: Conn, srv: Srv) -> List<&2, R.Act>:
  match cmds:
    case Nil{}:
      Nil{}
    case Con{+c, rest}:
      +cn = conn
      +sv = srv
      +q = conn.quit(cn)
      List.append(&2, R.Act, acts.q(q, c, cn, sv), plan(rest, next_conn(q, c, cn, sv), next_srv(q, c, cn, sv)))

# The fast path: a batch of database commands only, from a client that
# may run them and gets every reply, run on the focus. It leaves the
# connection as it was, as the general path does after such commands.

def ready(+c: Conn, +s: Srv) -> Bool:
  match c:
    case Conn{id, auth, name, MOn{}, False{}, db, r3}:
      authed(c, s)
    case _:
      False{}

# a batch's outcome: its replies in order, the connection and the server
# after it, and the databases
type Fin is Data:
  Fin{rs: List<&2, R.Reply>, conn: Conn, srv: Srv, ds: R.Ds}

def done.fast(conn: Conn, srv: Srv, pre: List<&2, R.Db>, post: List<&2, R.Db>, r: List<&2, R.Reply> & R.Db) -> Fin:
  (rs, d) = r
  Fin{rs, conn, srv, R.Ds{d, pre, post}}

def run.fast(conn: Conn, srv: Srv, cmds: List<&2, R.Cmd>, hs: List<&2, U32>, ds: R.Ds) -> Fin:
  match ds:
    case R.Ds{d, pre, post}:
      done.fast(conn, srv, pre, post, B.exec_batch(cmds, hs, d))

def done.gen(st: Gen) -> Fin:
  match st:
    case Gen{rs, es, conn, srv, ds}:
      Fin{List.reverse(&2, R.Reply, rs), conn, srv, ds}

def run.plain(fast: Bool, conn: Conn, srv: Srv, cmds: List<&2, R.Cmd>, hs: List<&2, U32>, ds: R.Ds) -> Fin:
  match fast cmds:
    case _ Nil{}:
      Fin{Nil{}, conn, srv, ds}
    case True{} Con{c, cs}:
      run.fast(conn, srv, c <> cs, hs, ds)
    case False{} Con{c, cs}:
      done.gen(gen(conn, srv, c <> cs, ds))

# a batch, as the server without an append-only file runs it
def run(conn: Conn, srv: Srv, job: B.Job, ds: R.Ds) -> Fin:
  match job:
    case B.Plain{cmds, hs}:
      +c = conn
      +s = srv
      run.plain(ready(c, s), c, s, cmds, hs, ds)
    case B.Mixed{cmds, hs}:
      done.gen(gen(conn, srv, cmds, ds))

# a batch's outcome with its effects, in order, for the append-only file
type Logged is Data:
  Logged{rs: List<&2, R.Reply>, es: List<&2, A.Eff>, conn: Conn, srv: Srv, ds: R.Ds}

def logged.fast2(conn: Conn, srv: Srv, rs: List<&2, R.Reply>, +i: Nat, pre: List<&2, R.Db>, post: List<&2, R.Db>, q: List<&2, R.Cmd> & R.Db) -> Logged:
  (es, d) = q
  Logged{rs, A.at_db(i, es), conn, srv, R.Ds{d, pre, post}}

def logged.fast(conn: Conn, srv: Srv, +i: Nat, pre: List<&2, R.Db>, post: List<&2, R.Db>, r: List<&2, R.Reply> & (List<&2, R.Cmd> & R.Db)) -> Logged:
  (rs, q) = r
  logged.fast2(conn, srv, rs, i, pre, post, q)

def run_log.fast(conn: Conn, srv: Srv, cmds: List<&2, R.Cmd>, hs: List<&2, U32>, ds: R.Ds) -> Logged:
  match ds:
    case R.Ds{d, +pre, post}:
      logged.fast(conn, srv, List.length(&2, R.Db, pre), pre, post, A.log_batch(cmds, hs, d))

def logged.gen(st: Gen) -> Logged:
  match st:
    case Gen{rs, es, conn, srv, ds}:
      Logged{List.reverse(&2, R.Reply, rs), List.reverse(&2, A.Eff, es), conn, srv, ds}

def run_log.plain(fast: Bool, conn: Conn, srv: Srv, cmds: List<&2, R.Cmd>, hs: List<&2, U32>, ds: R.Ds) -> Logged:
  match fast cmds:
    case _ Nil{}:
      Logged{Nil{}, Nil{}, conn, srv, ds}
    case True{} Con{c, cs}:
      run_log.fast(conn, srv, c <> cs, hs, ds)
    case False{} Con{c, cs}:
      logged.gen(gen(conn, srv, c <> cs, ds))

# a batch, as the server with an append-only file runs it
def run_log(conn: Conn, srv: Srv, job: B.Job, ds: R.Ds) -> Logged:
  match job:
    case B.Plain{cmds, hs}:
      +c = conn
      +s = srv
      run_log.plain(ready(c, s), c, s, cmds, hs, ds)
    case B.Mixed{cmds, hs}:
      logged.gen(gen(conn, srv, cmds, ds))
