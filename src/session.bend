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
      R.r_get(KV.pick(KV.Val, t, r, now))

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

# OBJECT of a collection: its encoding as Redis 7.0 names it, a count of
# references of 1, and the rest as for a string. A hash is a listpack
# while it is small (KV.Hash: as Redis turns one into a hashtable at the
# parameters' defaults) and within hash-max-listpack-entries and
# hash-max-listpack-value as they are now; else a hashtable. (Redis reads
# the parameters as a hash is written, and never turns a hashtable back:
# a small hash that once passed a lower limit, or a large one under limits
# raised since, is named otherwise there.)
# a parameter's number, at most 10^14 (a Nat stays below 2^48)
def cfg.nat.of(l: R.LL) -> Nat:
  match l:
    case R.LL{neg, +hi, +lo}:
      Nat.add(Nat.mul(Nat.min(hi, 100000n), 1000000000n), lo)
    case R.LLBad{}:
      0n

def cfg.nat(+cfg: List<&2, C.CItem>, +name: String) -> Nat:
  cfg.nat.of(R.ll.read(C.config.get_value(cfg, name)))

def obj.hash.enc(+h: KV.Hash, +cfg: List<&2, C.CItem>) -> String:
  match h:
    case KV.HSmall{+n, +ps}:
      Bool.pick(String, Bool.and(Nat.is_le(n, cfg.nat(cfg, "hash-max-listpack-entries")), Nat.is_le(KV.hps.widest(ps, 0n), cfg.nat(cfg, "hash-max-listpack-value"))), "listpack", "hashtable")
    case KV.HBig{n, t}:
      "hashtable"

def obj.mems.enc(+m: KV.Mems, +cfg: List<&2, C.CItem>) -> String:
  match m:
    case KV.MInts{+n, xs}:
      Bool.pick(String, Nat.is_le(n, cfg.nat(cfg, "set-max-intset-entries")), "intset", "hashtable")
    case KV.MBig{n, t}:
      "hashtable"

# the longest member of the elements xs, at least m
def obj.zwidest(xs: List<&2, KV.ZEl>, +m: Nat) -> Nat:
  match xs:
    case Nil{}:
      m
    case Con{KV.ZEl{+k, d}, rest}:
      obj.zwidest(rest, Nat.max(m, String.length(k)))

# a sorted set is a listpack while it is small (KV.Zset: as Redis turns
# one into a skiplist at the parameters' defaults) and within
# zset-max-listpack-entries and zset-max-listpack-value as they are now,
# as a hash
def obj.zset.enc(+z: KV.Zset, +cfg: List<&2, C.CItem>) -> String:
  match z:
    case KV.ZSmall{+tr}:
      Bool.pick(String, Bool.and(Nat.is_le(KV.zt.size(tr), cfg.nat(cfg, "zset-max-listpack-entries")), Nat.is_le(obj.zwidest(KV.zt.all(tr), 0n), cfg.nat(cfg, "zset-max-listpack-value"))), "listpack", "skiplist")
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

def obj.coll(+sub: Nat, +c: KV.Coll, +cfg: List<&2, C.CItem>) -> R.Reply:
  match sub:
    case 3n:
      R.RBulk{obj.coll.enc(c, cfg)}
    case 4n:
      R.r_int(1n)
    case _:
      obj.of(sub, "", cfg)

def obj.reply(+sub: Nat, m: Maybe<&2, KV.Item<KV.Val>>, +cfg: List<&2, C.CItem>) -> R.Reply:
  match m:
    case Some{KV.Item{KV.VStr{+v}, e}}:
      obj.of(sub, v, cfg)
    case Some{KV.Item{KV.VColl{+c}, e}}:
      obj.coll(sub, c, cfg)
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

def hr.pair(wv: Bool, f: String, v: String, rest: List<&2, R.Reply>) -> List<&2, R.Reply>:
  match wv:
    case True{}:
      R.RBulk{f} <> R.RBulk{v} <> rest
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
    case Some{KV.Item{KV.VStr{s}, e}}:
      R.e_wrongtype()
    case None{}:
      R.RNull{}

def hr.many(m: Maybe<&2, KV.Item<KV.Val>>, +neg: Bool, +k: Nat, +wv: Bool, +r: U32) -> R.Reply:
  match m:
    case Some{KV.Item{KV.VColl{KV.CHash{+h}}, e}}:
      R.RArray{hr.of(neg, k, wv, KV.hash.pairs(h), KV.hash.len(h), r)}
    case Some{KV.Item{KV.VColl{KV.CList{l}}, e}}:
      R.e_wrongtype()
    case Some{KV.Item{KV.VColl{KV.CMems{l}}, e}}:
      R.e_wrongtype()
    case Some{KV.Item{KV.VColl{KV.CZset{z}}, e}}:
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
# own (WITHSCORES for WITHVALUES). An element is picked by its rank (the
# tree finds it in O(log n)). A negative count picks that many elements,
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

# the element at a rank r picks
def zr.el(+t: KV.ZTree, +r: U32, +n: Nat) -> KV.ZEl:
  KV.zt.nth(t, hr.at(r, n))

def zr.out(e: KV.ZEl, +ws: Bool, rest: List<&2, R.Reply>) -> List<&2, R.Reply>:
  match e:
    case KV.ZEl{m, +d}:
      R.zels.one(ws, m, d, rest)

# k elements, each anew
def zr.rep(k: Nat, +t: KV.ZTree, +n: Nat, +r: U32, +ws: Bool) -> List<&2, R.Reply>:
  match k:
    case 0n:
      Nil{}
    case 1n+j:
      +q = hr.next(r)
      zr.out(zr.el(t, q, n), ws, zr.rep(j, t, n, q, ws))

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
      zr.drop(j, zr.cut(zr.el(t, q, KV.zt.size(t)), t), q)

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

def zr.gather(fuel: Nat, done: Bool, g: ZrG, +k: Nat, +t: KV.ZTree, +n: Nat, +r: U32, +ws: Bool) -> List<&2, R.Reply>:
  match fuel done:
    case _ True{}:
      zr.outs(g)
    case 0n False{}:
      zr.outs(g)
    case 1n+f False{}:
      +q = hr.next(r)
      +g2 = zr.step(zr.el(t, q, n), g, ws)
      zr.gather(f, zr.done(g2, k), g2, k, t, n, q, ws)

def zr.uniq(third: Bool, +k: Nat, +t: KV.ZTree, +n: Nat, +r: U32, +ws: Bool) -> List<&2, R.Reply>:
  match third:
    case True{}:
      R.zels(KV.zt.drain(zr.drop(Nat.sub(n, k), t, r), Nil{}), ws)
    case False{}:
      zr.gather(Nat.add(Nat.mul(k, 16n), 64n), Nat.is_eq(k, 0n), ZrG{KV.empty(Unit), Nil{}, 0n}, k, t, n, r, ws)

def zr.pos(all: Bool, +k: Nat, +t: KV.ZTree, +n: Nat, +r: U32, +ws: Bool) -> List<&2, R.Reply>:
  match all:
    case True{}:
      R.zels(KV.zt.rslice(t, 0n, n), ws)
    case False{}:
      zr.uniq(Nat.is_lt(n, Nat.mul(k, 3n)), k, t, n, r, ws)

def zr.of(neg: Bool, +k: Nat, +ws: Bool, +t: KV.ZTree, +n: Nat, +r: U32) -> List<&2, R.Reply>:
  match neg:
    case True{}:
      zr.rep(k, t, n, r, ws)
    case False{}:
      zr.pos(Nat.is_le(n, k), k, t, n, r, ws)

def zr.one(m: Maybe<&2, KV.Item<KV.Val>>, +r: U32) -> R.Reply:
  match m:
    case Some{KV.Item{KV.VColl{KV.CZset{+z}}, e}}:
      R.RBulk{R.zel.m(zr.el(KV.zset.tree(z), hr.next(r), KV.zset.len(z)))}
    case None{}:
      R.RNull{}
    case _:
      R.e_wrongtype()

def zr.many(m: Maybe<&2, KV.Item<KV.Val>>, +neg: Bool, +k: Nat, +ws: Bool, +r: U32) -> R.Reply:
  match m:
    case Some{KV.Item{KV.VColl{KV.CZset{+z}}, e}}:
      R.RArray{zr.of(neg, k, ws, KV.zset.tree(z), KV.zset.len(z), r)}
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

def mem.val(+v: KV.Val) -> Nat:
  match v:
    case KV.VStr{+s}:
      Nat.add(16n, String.length(s))
    case KV.VColl{KV.CHash{+h}}:
      mem.pairs(KV.hash.pairs(h), 48n)
    case KV.VColl{KV.CList{+l}}:
      mem.elems(KV.deq.all(l), 48n)
    case KV.VColl{KV.CMems{+m}}:
      mem.elems(KV.mems.all(m), 48n)
    case KV.VColl{KV.CZset{+z}}:
      mem.zels(KV.zset.all(z), 48n)

def mem.size(+k: String, m: Maybe<&2, KV.Item<KV.Val>>) -> R.Reply:
  match m:
    case Some{KV.Item{+v, e}}:
      R.r_int(Nat.add(Nat.add(40n, String.length(k)), mem.val(v)))
    case None{}:
      R.RNull{}

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
          R.RArray{[R.RBulk{"matches"}, R.RArray{List.reverse(&2, R.Reply, out)}, R.RBulk{"len"}, R.r_int(n)]}
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
    case R.SLcs{args}:
      say(conn.mode(c), lcs.reply(args, R.ds.focused(ds), srv.cfg(s)))
    case R.SHRandField{+k, args}:
      say(conn.mode(c), hr.reply(hr.args(args), R.db.ent(R.ds.focused(ds), k), KV.mix(srv.rng(s))))
    case R.SMemUsage{+k, args}:
      say(conn.mode(c), mem.usage(mem.opts(args, None{}), k, R.db.ent(R.ds.focused(ds), k)))
    case R.SReply{r}:
      say(conn.mode(c), r)
    case R.SBad{r}:
      say(conn.mode(c), r)
    case R.SSPop{+k, args}:
      say(conn.mode(c), sp.reply(sp.args(args), k, KV.mix(srv.rng(s)), R.ds.focused(ds)))
    case R.SSRandMember{+k, args}:
      say(conn.mode(c), sr.reply(sr.args(args), R.db.ent(R.ds.focused(ds), k), KV.mix(srv.rng(s))))
    case R.SZRandMember{+k, args}:
      say(conn.mode(c), zr.reply(zr.args(args), R.db.ent(R.ds.focused(ds), k), KV.mix(srv.rng(s))))

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
    case R.SSPop{k, a}:
      step_conn(c, s)
    case R.SSRandMember{k, a}:
      step_conn(c, s)
    case R.SZRandMember{k, a}:
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
    case R.SSPop{+k, args}:
      sp.acts(sp.args(args), k, KV.mix(srv.rng(s)))
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
# succeeds, CONFIG RESETSTAT its counts, and RANDOMKEY and HRANDFIELD its
# random numbers
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
