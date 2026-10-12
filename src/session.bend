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
# and the database it selected (SELECT)
type Conn is Data:
  Conn{id: Nat, auth: Bool, name: String, mode: Mute, quit: Bool, db: Nat}

# the server, besides its database: its password (empty for none), its
# parameters (config.bend), of which requirepass is the password, what
# INFO shows of it that they do not (info.bend), and the state of its
# random numbers (RANDOMKEY's)
type Srv is Data:
  Srv{pass: String, cfg: List<&2, C.CItem>, info: I.Info, rng: U32}

def conn_new(id: Nat) -> Conn:
  Conn{id, False{}, "", MOn{}, False{}, 0n}

# the server with these parameters: its password is requirepass; its
# random numbers start from its run id
def srv_of(+cfg: List<&2, C.CItem>, info: I.Info) -> Srv:
  +i = info
  +r = I.info.seed(i)
  Srv{C.config.get_value(cfg, "requirepass"), cfg, i, r}

def srv.puts(sets: List<&2, String>, cfg: List<&2, C.CItem>) -> List<&2, C.CItem>:
  match sets:
    case Con{+n, Con{+v, rest}}:
      srv.puts(rest, C.items.put(cfg, n, v))
    case _:
      cfg

def conn.auth(+c: Conn) -> Bool:
  match c:
    case Conn{id, auth, name, mode, quit, db}:
      auth

def conn.id(+c: Conn) -> Nat:
  match c:
    case Conn{id, auth, name, mode, quit, db}:
      id

def conn.name(+c: Conn) -> String:
  match c:
    case Conn{id, auth, name, mode, quit, db}:
      name

def conn.mode(+c: Conn) -> Mute:
  match c:
    case Conn{id, auth, name, mode, quit, db}:
      mode

# the connection with every reply on (for INFO's statistics, which count
# the replies a client does not get)
def conn.on(c: Conn) -> Conn:
  match c:
    case Conn{id, auth, name, mode, quit, db}:
      Conn{id, auth, name, MOn{}, quit, db}

def conn.quit(+c: Conn) -> Bool:
  match c:
    case Conn{id, auth, name, mode, quit, db}:
      quit

def conn.db(+c: Conn) -> Nat:
  match c:
    case Conn{id, auth, name, mode, quit, +db}:
      db

def srv.pass(+s: Srv) -> String:
  match s:
    case Srv{pass, cfg, info, rng}:
      pass

def srv.cfg(+s: Srv) -> List<&2, C.CItem>:
  match s:
    case Srv{pass, cfg, info, rng}:
      cfg

def srv.info(+s: Srv) -> I.Info:
  match s:
    case Srv{pass, cfg, info, rng}:
      info

def srv.rng(+s: Srv) -> U32:
  match s:
    case Srv{pass, cfg, info, rng}:
      rng

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
    case Srv{pass, cfg, info, rng}:
      Srv{pass, cfg, I.info.ran(info, calls, r, rs, inb, outb), rng}

def srv.errs(s: Srv, xs: List<&2, R.Erred>) -> Srv:
  match s:
    case Srv{pass, cfg, info, rng}:
      Srv{pass, cfg, I.info.errs(info, xs), rng}

def srv.erred(s: Srv, +m: String) -> Srv:
  match s:
    case Srv{pass, cfg, info, rng}:
      Srv{pass, cfg, I.info.erred(info, m), rng}

def srv.aof(s: Srv, +n: Nat) -> Srv:
  match s:
    case Srv{pass, cfg, info, rng}:
      Srv{pass, cfg, I.info.aof(info, n), rng}

def srv.live(s: Srv, l: I.Live) -> Srv:
  match s:
    case Srv{pass, cfg, info, rng}:
      Srv{pass, cfg, I.info.live(info, l), rng}

def srv.tick(s: Srv, +ms: Nat) -> Srv:
  match s:
    case Srv{pass, cfg, info, rng}:
      Srv{pass, cfg, I.info.tick(info, ms), rng}

# the sweep of expired keys (redis.bend: reap): where the next one starts
# in database j, and a sweep of j that stopped at next having deleted k
# keys
def srv.reap_at(+s: Srv, +j: Nat) -> Nat:
  match s:
    case Srv{pass, cfg, +info, rng}:
      I.info.reap_at(info, j)

def srv.reaped(s: Srv, +j: Nat, +next: Nat, +k: Nat) -> Srv:
  match s:
    case Srv{pass, cfg, info, rng}:
      Srv{pass, cfg, I.info.reaped(info, j, next, k), rng}

# Authentication
# --------------
# A client must authenticate when the server has a password; a client
# that has run a command while the server had none has authenticated, as
# in Redis, where a client is authenticated from the start when there is
# no password.

# whether the server has no password (String.length reads a packed
# String where it lies; String.is_empty would take it apart)
def nopass(+s: Srv) -> Bool:
  match s:
    case Srv{+pass, cfg, info, rng}:
      Nat.is_eq(String.length(pass), 0n)

def authed(+c: Conn, +s: Srv) -> Bool:
  Bool.or(conn.auth(c), nopass(s))

# a user and a password: the one user is "default", and without a
# password any password is its own
def login_ok(+u: String, +p: String, +s: Srv) -> Bool:
  Bool.and(String.eq(u, "default"), Bool.or(nopass(s), String.eq(p, srv.pass(s))))

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

# the connection after a command that leaves it as it is: authenticated
# if it may run commands now, its mode one command on
def step_conn(+c: Conn, +s: Srv) -> Conn:
  match c:
    case Conn{id, auth, name, mode, quit, db}:
      Conn{id, authed(c, s), name, after(mode), quit, db}

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

# HELLO [protover [AUTH user pass] [SETNAME name]]: BendKV speaks RESP2
# alone, so HELLO 3 is refused as an unknown version, and a client goes
# on with RESP2. The options run in order, and each one done stays done
# when a later one fails, as in Redis.

# what HELLO's options are doing: waiting for an option, the user of an
# AUTH, its password, or the name of a SETNAME; or failed
type Want is Data:
  WOpt{}
  WUser{}
  WPass{user: String}
  WName{}
  WFail{r: R.Reply}

# the state of a HELLO: what it waits for, and the connection
type Hel is Data:
  Hel{w: Want, auth: Bool, name: String}

def hello.opt(a: String, auth: Bool, name: String, au: Bool, sn: Bool) -> Hel:
  match au sn:
    case True{} _:
      Hel{WUser{}, auth, name}
    case False{} True{}:
      Hel{WName{}, auth, name}
    case False{} False{}:
      Hel{WFail{R.RError{"ERR Syntax error in HELLO option '" ++ a ++ "'"}}, auth, name}

def hello.pass(ok: Bool, auth: Bool, name: String) -> Hel:
  match ok:
    case True{}:
      Hel{WOpt{}, True{}, name}
    case False{}:
      Hel{WFail{e_wrongpass()}, auth, name}

def hello.name(ok: Bool, auth: Bool, name: String, n: String) -> Hel:
  match ok:
    case True{}:
      Hel{WOpt{}, auth, n}
    case False{}:
      Hel{WFail{e_name()}, auth, name}

# one argument of HELLO's options, n the number of those after it
def hello.step(+s: Srv, h: Hel, +a: String, +n: Nat) -> Hel:
  match h:
    case Hel{WOpt{}, auth, name}:
      hello.opt(a, auth, name, Bool.and(R.is_word(a, "AUTH"), Nat.is_le(2n, n)), Bool.and(R.is_word(a, "SETNAME"), Nat.is_le(1n, n)))
    case Hel{WUser{}, auth, name}:
      Hel{WPass{a}, auth, name}
    case Hel{WPass{+u}, auth, name}:
      hello.pass(login_ok(u, a, s), auth, name)
    case Hel{WName{}, auth, name}:
      hello.name(name_ok(a), auth, name, a)
    case Hel{WFail{r}, auth, name}:
      Hel{WFail{r}, auth, name}

def hello.go(+s: Srv, args: List<&2, String>, h: Hel) -> Hel:
  match args:
    case Nil{}:
      h
    case Con{+a, +rest}:
      hello.go(s, rest, hello.step(s, h, a, List.length(&2, String, rest)))

# HELLO's reply: the server, as Redis 7.0.15 describes itself
def hello.map(id: Nat) -> R.Reply:
  R.RArray{[R.RBulk{"server"}, R.RBulk{"redis"}, R.RBulk{"version"}, R.RBulk{"7.0.15"}, R.RBulk{"proto"}, R.r_int(2n), R.RBulk{"id"}, R.r_int(id), R.RBulk{"mode"}, R.RBulk{"standalone"}, R.RBulk{"role"}, R.RBulk{"master"}, R.RBulk{"modules"}, R.RArray{Nil{}}]}

def hello.fin(h: Hel, id: Nat, nopass: Bool) -> R.Reply:
  match h:
    case Hel{WFail{r}, auth, name}:
      r
    case Hel{w, auth, name}:
      Bool.pick(R.Reply, Bool.or(auth, nopass), hello.map(id), R.RError{"NOAUTH HELLO must be called with the client already authenticated, otherwise the HELLO AUTH <user> <pass> option can be used to authenticate the client and select the RESP protocol version at the same time"})

# the protocol version, a long long as Redis reads one: none, 2, or the
# reply that refuses it
def hello.ver(l: R.LL) -> Maybe<&2, R.Reply>:
  match l:
    case R.LL{+neg, +hi, +lo}:
      Bool.pick(Maybe<&2, R.Reply>, Bool.and(Bool.not(neg), Bool.and(Nat.is_eq(hi, 0n), Nat.is_eq(lo, 2n))), None{}, Some{R.RError{"NOPROTO unsupported protocol version"}})
    case R.LLBad{}:
      Some{R.RError{"ERR Protocol version is not an integer or out of range"}}

# HELLO's options after its version, or the version's refusal
def hello.args(args: List<&2, String>) -> Maybe<&2, R.Reply> & List<&2, String>:
  match args:
    case Nil{}:
      (None{}, Nil{})
    case Con{+v, rest}:
      (hello.ver(R.ll.read(v)), rest)

def hello.run.if(+s: Srv, +c: Conn, bad: Maybe<&2, R.Reply>, opts: List<&2, String>) -> Hel:
  match bad:
    case Some{r}:
      Hel{WFail{r}, conn.auth(c), conn.name(c)}
    case None{}:
      hello.go(s, opts, Hel{WOpt{}, conn.auth(c), conn.name(c)})

def hello.run.of(+s: Srv, +c: Conn, p: Maybe<&2, R.Reply> & List<&2, String>) -> Hel:
  (bad, opts) = p
  hello.run.if(s, c, bad, opts)

def hello.run(+s: Srv, +c: Conn, args: List<&2, String>) -> Hel:
  hello.run.of(s, c, hello.args(args))

# the connection after a HELLO: authenticated if an AUTH of it was, or
# if it may run commands now, and named as its SETNAME said
def hello.conn(h: Hel, +c: Conn, +s: Srv) -> Conn:
  match h c:
    case Hel{w, auth, name} Conn{id, a, n, mode, quit, db}:
      Conn{id, Bool.or(auth, authed(c, s)), name, after(mode), quit, db}

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
      auth.one(nopass(s), String.eq(p, srv.pass(s)))
    case Con{+u, Con{+p, Nil{}}}:
      Bool.pick(R.Reply, login_ok(u, p, s), R.r_ok(), e_wrongpass())
    case _:
      R.RError{"ERR syntax error"}

def auth.ok(+args: List<&2, String>, +s: Srv) -> Bool:
  match args:
    case Con{+p, Nil{}}:
      Bool.and(Bool.not(nopass(s)), String.eq(p, srv.pass(s)))
    case Con{+u, Con{+p, Nil{}}}:
      login_ok(u, p, s)
    case _:
      False{}

def auth.conn(ok: Bool, +c: Conn, +s: Srv) -> Conn:
  match ok c:
    case True{} Conn{id, a, name, mode, quit, db}:
      Conn{id, True{}, name, after(mode), quit, db}
    case False{} c0:
      step_conn(c0, s)

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
    case IdxOk{j} Conn{id, a, name, mode, quit, db}:
      Conn{id, authed(c, s), name, after(mode), quit, j}
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
    case Conn{id, a, name, mode, quit, db}:
      Conn{id, authed(c, s), name, after(mode), True{}, db}

# RESET: the connection as new, authenticated if there is no password;
# its reply goes out unless it is the one skipped
def reset.conn(c: Conn, +s: Srv) -> Conn:
  match c:
    case Conn{id, a, name, mode, quit, db}:
      Conn{id, nopass(s), "", MOn{}, False{}, 0n}

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
    case True{} Conn{id, a, name, mode, quit, db}:
      Conn{id, authed(c, s), n, after(mode), quit, db}
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
    case Conn{id, a, name, mode, quit, db}:
      Conn{id, authed(c, s), name, m, quit, db}

# RANDOMKEY's reply: a key there at now in the database's trie, by r, or
# nil
def randomkey.of(+db: R.Db, +r: U32) -> R.Reply:
  match db:
    case R.Db{+t, n, x, +now, rr}:
      R.r_get(KV.pick(String, t, r, now))

# TIME: the time the batch runs at (the focus's, set from the clock for
# each group of batches), in s and us since 1970; BendKV keeps it in ms
def time.reply(+now: Nat) -> R.Reply:
  R.RArray{[R.RBulk{Nat.show(Nat.div(now, 1000n))}, R.RBulk{Nat.show(Nat.mul(Nat.mod(now, 1000n), 1000n))}]}

# OBJECT of a key there (none: nil). BendKV keeps a value as its bytes
# alone, so it answers ENCODING as Redis 7.0.15 encodes a value set whole
# ("int" for a long, "embstr" up to 44 bytes, else "raw"; a value Redis
# made by APPEND, SETRANGE or SETBIT is "raw" there whatever it holds),
# REFCOUNT by the integers 0 to 9999 Redis shares (INT_MAX for one, unless
# maxmemory is set with an LRU or LFU policy, else 1), IDLETIME and FREQ
# 0: it does not track accesses. IDLETIME is refused under an LFU policy,
# FREQ under any other, as in Redis.
def obj.lfu(+cfg: List<&2, C.CItem>) -> Bool:
  +p = C.config.get_value(cfg, "maxmemory-policy")
  Bool.or(String.eq(p, "allkeys-lfu"), String.eq(p, "volatile-lfu"))

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

def obj.of(+sub: Nat, +v: String, +cfg: List<&2, C.CItem>) -> R.Reply:
  match sub:
    case 2n:
      Bool.pick(R.Reply, obj.lfu(cfg), R.r_int(0n), R.RError{"ERR An LFU maxmemory policy is not selected, access frequency not tracked. Please note that when switching between policies at runtime LRU and LFU data will take some time to adjust."})
    case 3n:
      obj.encoding(R.ll.read(v), String.length(v))
    case 4n:
      obj.refcount(R.ll.read(v), obj.shared(cfg))
    case _:
      Bool.pick(R.Reply, obj.lfu(cfg), R.RError{"ERR An LFU maxmemory policy is selected, idle time not tracked. Please note that when switching between policies at runtime LRU and LFU data will take some time to adjust."}, R.r_int(0n))

def obj.reply(+sub: Nat, m: Maybe<&2, KV.Item<String>>, +cfg: List<&2, C.CItem>) -> R.Reply:
  match m:
    case Some{KV.Item{+v, e}}:
      obj.of(sub, v, cfg)
    case None{}:
      R.RNull{}

# a session command's reply, sent or not; the databases are there for
# the commands that read them
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
      say(conn.mode(c), R.RBulk{I.text(args, srv.cfg(s), srv.info(s), ds)})
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
      say(conn.mode(c), obj.reply(sub, R.db.ent(R.ds.focused(ds), k), srv.cfg(s)))
    case R.SCopy{+args}:
      say(conn.mode(c), copy.reply(copy.of(args, c, s), ds))
    case R.SReply{r}:
      say(conn.mode(c), r)
    case R.SBad{r}:
      say(conn.mode(c), r)

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
    case R.SReply{r}:
      step_conn(c, s)
    case R.SBad{r}:
      step_conn(c, s)

# what a session command does to the databases: SELECT and RESET move the
# focus to the connection's new database, SWAPDB, MOVE, COPY and FLUSHALL
# act on the databases, and the others do nothing to them
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
    case _:
      Nil{}

def srv.set(r: Result<&2, &2, R.Reply, List<&2, C.CItem>>, +s: Srv) -> Srv:
  match r:
    case Done{+cfg}:
      Srv{C.config.get_value(cfg, "requirepass"), cfg, srv.info(s), srv.rng(s)}
    case Fail{e}:
      s

# CONFIG RESETSTAT: INFO's counts start again
def srv.reset(s: Srv) -> Srv:
  match s:
    case Srv{pass, cfg, info, rng}:
      Srv{pass, cfg, I.info.reset(info), rng}

# RANDOMKEY: the next state of the random numbers (a Weyl sequence, that
# KV.mix scrambles)
def srv.rand(s: Srv) -> Srv:
  match s:
    case Srv{pass, cfg, info, rng}:
      Srv{pass, cfg, info, U32.add(rng, 2654435769)}

# the server after a session command: CONFIG SET changes it when it
# succeeds, CONFIG RESETSTAT its counts, and RANDOMKEY its random numbers
def own_srv(+o: R.SessOp, +c: Conn, +s: Srv) -> Srv:
  match o:
    case R.SConfigSet{args}:
      srv.set(C.config.set(args, srv.cfg(s)), s)
    case R.SConfigResetStat{}:
      srv.reset(s)
    case R.SRandomKey{}:
      srv.rand(s)
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
# the errors the parser found in session commands
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
# connection authenticated, as the general path does after a command (an
# empty batch, which the server never sends, leaves it as it was).

def ready(+c: Conn, +s: Srv) -> Bool:
  match c:
    case Conn{id, auth, name, MOn{}, False{}, db}:
      authed(c, s)
    case _:
      False{}

def conn_ok(c: Conn) -> Conn:
  match c:
    case Conn{id, auth, name, mode, quit, db}:
      Conn{id, True{}, name, mode, quit, db}

# a batch's outcome: its replies in order, the connection and the server
# after it, and the databases
type Fin is Data:
  Fin{rs: List<&2, R.Reply>, conn: Conn, srv: Srv, ds: R.Ds}

def done.fast(conn: Conn, srv: Srv, pre: List<&2, R.Db>, post: List<&2, R.Db>, r: List<&2, R.Reply> & R.Db) -> Fin:
  (rs, d) = r
  Fin{rs, conn_ok(conn), srv, R.Ds{d, pre, post}}

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
  Logged{rs, A.at_db(i, es), conn_ok(conn), srv, R.Ds{d, pre, post}}

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
