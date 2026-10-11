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

# Types
# -----

# which replies a connection gets (CLIENT REPLY): all, none, or none for
# the next command
type Mute is Data:
  MOn{}
  MOff{}
  MSkip{}

# a connection: its id, whether it has authenticated, its name (empty
# for none), which replies it gets, and whether it has asked to close
# (QUIT)
type Conn is Data:
  Conn{id: Nat, auth: Bool, name: String, mode: Mute, quit: Bool}

# the server, besides its database: its password (empty for none) and its
# parameters (config.bend), of which requirepass is the password
type Srv is Data:
  Srv{pass: String, cfg: List<&2, C.CItem>}

def conn_new(id: Nat) -> Conn:
  Conn{id, False{}, "", MOn{}, False{}}

# the server with these parameters: its password is requirepass
def srv_of(+cfg: List<&2, C.CItem>) -> Srv:
  Srv{C.config.get_value(cfg, "requirepass"), cfg}

def srv.puts(sets: List<&2, String>, cfg: List<&2, C.CItem>) -> List<&2, C.CItem>:
  match sets:
    case Con{+n, Con{+v, rest}}:
      srv.puts(rest, C.items.put(cfg, n, v))
    case _:
      cfg

# the server at its start: the table's values, with the values it was
# started with (a name and a value, and so on), which the shell checked
def srv_start(sets: List<&2, String>) -> Srv:
  srv_of(srv.puts(sets, C.config.table()))

def srv_new(pass: String) -> Srv:
  srv_start(["requirepass", pass])

def conn.auth(+c: Conn) -> Bool:
  match c:
    case Conn{id, auth, name, mode, quit}:
      auth

def conn.id(+c: Conn) -> Nat:
  match c:
    case Conn{id, auth, name, mode, quit}:
      id

def conn.name(+c: Conn) -> String:
  match c:
    case Conn{id, auth, name, mode, quit}:
      name

def conn.mode(+c: Conn) -> Mute:
  match c:
    case Conn{id, auth, name, mode, quit}:
      mode

def conn.quit(+c: Conn) -> Bool:
  match c:
    case Conn{id, auth, name, mode, quit}:
      quit

def srv.pass(+s: Srv) -> String:
  match s:
    case Srv{pass, cfg}:
      pass

def srv.cfg(+s: Srv) -> List<&2, C.CItem>:
  match s:
    case Srv{pass, cfg}:
      cfg

# Authentication
# --------------
# A client must authenticate when the server has a password; a client
# that has run a command while the server had none has authenticated, as
# in Redis, where a client is authenticated from the start when there is
# no password.

# whether the server has no password (String.length reads a packed
# String where it lies; String.is_empty would take it apart)
def nopass(+s: Srv) -> Bool:
  Nat.is_eq(String.length(srv.pass(s)), 0n)

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
    case Conn{id, auth, name, mode, quit}:
      Conn{id, authed(c, s), name, after(mode), quit}

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

# the protocol version: none, 2, or the reply that refuses it
def hello.ver(v: Maybe<&2, R.Int>) -> Maybe<&2, R.Reply>:
  match v:
    case Some{R.IPos{2n}}:
      None{}
    case Some{other}:
      Some{R.RError{"NOPROTO unsupported protocol version"}}
    case None{}:
      Some{R.RError{"ERR Protocol version is not an integer or out of range"}}

# HELLO's options after its version, or the version's refusal
def hello.args(args: List<&2, String>) -> Maybe<&2, R.Reply> & List<&2, String>:
  match args:
    case Nil{}:
      (None{}, Nil{})
    case Con{+v, rest}:
      (hello.ver(R.int_read(v)), rest)

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
    case Hel{w, auth, name} Conn{id, a, n, mode, quit}:
      Conn{id, Bool.or(auth, authed(c, s)), name, after(mode), quit}

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
    case True{} Conn{id, a, name, mode, quit}:
      Conn{id, True{}, name, after(mode), quit}
    case False{} c0:
      step_conn(c0, s)

# SELECT: BendKV has one database, as Redis has with "databases 1"
def select.reply(v: Maybe<&2, R.Int>) -> R.Reply:
  match v:
    case Some{R.IPos{0n}}:
      R.r_ok()
    case Some{other}:
      R.RError{"ERR DB index is out of range"}
    case None{}:
      R.e_int()

# QUIT: OK, and the connection closes once its replies are out; the
# commands after it in the batch are dropped
def quit.conn(+c: Conn, +s: Srv) -> Conn:
  match c:
    case Conn{id, a, name, mode, quit}:
      Conn{id, authed(c, s), name, after(mode), True{}}

# RESET: the connection as new, authenticated if there is no password;
# its reply goes out unless it is the one skipped
def reset.conn(c: Conn, +s: Srv) -> Conn:
  match c:
    case Conn{id, a, name, mode, quit}:
      Conn{id, nopass(s), "", MOn{}, False{}}

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
    case True{} Conn{id, a, name, mode, quit}:
      Conn{id, authed(c, s), n, after(mode), quit}
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
    case Conn{id, a, name, mode, quit}:
      Conn{id, authed(c, s), name, m, quit}

# a session command's reply, sent or not; the database is there for the
# commands that read it
def own_reply(+o: R.SessOp, +c: Conn, +s: Srv, +db: KV.Trie<String>) -> Maybe<&2, R.Reply>:
  match o:
    case R.SHello{args}:
      say(conn.mode(c), hello.fin(hello.run(s, c, args), conn.id(c), nopass(s)))
    case R.SAuth{args}:
      say(conn.mode(c), auth.reply(args, s))
    case R.SSelect{d}:
      say(conn.mode(c), select.reply(R.int_read(d)))
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
    case R.SSelect{d}:
      step_conn(c, s)
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
    case R.SReply{r}:
      step_conn(c, s)
    case R.SBad{r}:
      step_conn(c, s)

def srv.set(r: Result<&2, &2, R.Reply, List<&2, C.CItem>>, s: Srv) -> Srv:
  match r:
    case Done{cfg}:
      srv_of(cfg)
    case Fail{e}:
      s

# the server after a session command: CONFIG SET changes it when it
# succeeds
def own_srv(+o: R.SessOp, +c: Conn, +s: Srv) -> Srv:
  match o:
    case R.SConfigSet{args}:
      srv.set(C.config.set(args, srv.cfg(s)), s)
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
# (newest first), the connection, the server and the database
type Gen is Data:
  Gen{rs: List<&2, R.Reply>, es: List<&2, R.Cmd>, conn: Conn, srv: Srv, db: KV.Trie<String>}

# the replies, the effects and the database after a command; the
# connection and the server after it come apart (next_conn, next_srv),
# for they do not depend on the database
type Out is Data:
  Out{rs: List<&2, R.Reply>, es: List<&2, R.Cmd>, db: KV.Trie<String>}

# a database command run: its reply, sent or not, and its effects
# (aof.bend), put before those of the commands before it
def out.data(c: R.Cmd, rs: List<&2, R.Reply>, es: List<&2, R.Cmd>, m: Mute, r: R.Reply & KV.Trie<String>) -> Out:
  (+x, db) = r
  Out{put(say(m, x), rs), List.reverse.go(&2, R.Cmd, A.effect(c, x), es), db}

def out.k(+k: Role, ok: Bool, +c: R.Cmd, rs: List<&2, R.Reply>, es: List<&2, R.Cmd>, +conn: Conn, +srv: Srv, +db: KV.Trie<String>) -> Out:
  match k ok:
    case KSess{o} True{}:
      Out{put(own_reply(o, conn, srv, db), rs), es, db}
    case KSess{o} False{}:
      Out{put(say(conn.mode(conn), e_noauth()), rs), es, db}
    case _ True{}:
      out.data(c, rs, es, conn.mode(conn), R.exec(c, db))
    case _ False{}:
      Out{put(say(conn.mode(conn), e_noauth()), rs), es, db}

def out.q(quit: Bool, +c: R.Cmd, rs: List<&2, R.Reply>, es: List<&2, R.Cmd>, +conn: Conn, +srv: Srv, db: KV.Trie<String>) -> Out:
  match quit:
    case True{}:
      Out{rs, es, db}
    case False{}:
      +k = kind(c)
      out.k(k, may(k, conn, srv), c, rs, es, conn, srv, db)

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
    case Out{rs, es, db}:
      Gen{rs, es, conn, srv, db}

def gen.step(+c: R.Cmd, st: Gen) -> Gen:
  match st:
    case Gen{rs, es, +conn, +srv, db}:
      +q = conn.quit(conn)
      gen.mk(out.q(q, c, rs, es, conn, srv, db), next_conn(q, c, conn, srv), next_srv(q, c, conn, srv))

def gen.go(cmds: List<&2, R.Cmd>, st: Gen) -> Gen:
  match cmds:
    case Nil{}:
      st
    case Con{c, rest}:
      gen.go(rest, gen.step(c, st))

def gen(conn: Conn, srv: Srv, cmds: List<&2, R.Cmd>, db: KV.Trie<String>) -> Gen:
  gen.go(cmds, Gen{Nil{}, Nil{}, conn, srv, db})

# whether a command runs on the database (as exec runs it)
def ran.k(+k: Role, ok: Bool) -> Bool:
  match k:
    case KSess{o}:
      False{}
    case _:
      ok

def ran(quit: Bool, +c: R.Cmd, +conn: Conn, +srv: Srv) -> Bool:
  match quit:
    case True{}:
      False{}
    case False{}:
      +k = kind(c)
      ran.k(k, may(k, conn, srv))

def keep(ok: Bool, c: R.Cmd) -> List<&2, R.Cmd>:
  match ok:
    case True{}:
      [c]
    case False{}:
      Nil{}

# the commands a batch runs on the database, in order, as exec runs them
# (an error the parser found among them answers and changes nothing):
# the spec of gen
def plan(cmds: List<&2, R.Cmd>, conn: Conn, srv: Srv) -> List<&2, R.Cmd>:
  match cmds:
    case Nil{}:
      Nil{}
    case Con{+c, rest}:
      +cn = conn
      +sv = srv
      +q = conn.quit(cn)
      List.append(&2, R.Cmd, keep(ran(q, c, cn, sv), c), plan(rest, next_conn(q, c, cn, sv), next_srv(q, c, cn, sv)))

# The fast path: a batch of database commands only, from a client that
# may run them and gets every reply. It leaves the connection
# authenticated, as the general path does after a command (an empty
# batch, which the server never sends, leaves it as it was).

def ready(+c: Conn, +s: Srv) -> Bool:
  match c:
    case Conn{id, auth, name, MOn{}, False{}}:
      authed(c, s)
    case _:
      False{}

def conn_ok(c: Conn) -> Conn:
  match c:
    case Conn{id, auth, name, mode, quit}:
      Conn{id, True{}, name, mode, quit}

# a batch's outcome: its replies in order, the connection and the server
# after it, and the database
type Fin is Data:
  Fin{rs: List<&2, R.Reply>, conn: Conn, srv: Srv, db: KV.Trie<String>}

def done.fast(conn: Conn, srv: Srv, r: List<&2, R.Reply> & KV.Trie<String>) -> Fin:
  (rs, db) = r
  Fin{rs, conn_ok(conn), srv, db}

def done.gen(st: Gen) -> Fin:
  match st:
    case Gen{rs, es, conn, srv, db}:
      Fin{List.reverse(&2, R.Reply, rs), conn, srv, db}

def run.plain(fast: Bool, conn: Conn, srv: Srv, cmds: List<&2, R.Cmd>, hs: List<&2, U32>, db: KV.Trie<String>) -> Fin:
  match fast cmds:
    case _ Nil{}:
      Fin{Nil{}, conn, srv, db}
    case True{} Con{c, cs}:
      done.fast(conn, srv, B.exec_batch(c <> cs, hs, db))
    case False{} Con{c, cs}:
      done.gen(gen(conn, srv, c <> cs, db))

# a batch, as the server without an append-only file runs it
def run(conn: Conn, srv: Srv, job: B.Job, db: KV.Trie<String>) -> Fin:
  match job:
    case B.Plain{cmds, hs}:
      +c = conn
      +s = srv
      run.plain(ready(c, s), c, s, cmds, hs, db)
    case B.Mixed{cmds}:
      done.gen(gen(conn, srv, cmds, db))

# a batch's outcome with its effects, in order, for the append-only file
type Logged is Data:
  Logged{rs: List<&2, R.Reply>, es: List<&2, R.Cmd>, conn: Conn, srv: Srv, db: KV.Trie<String>}

def logged.fast2(conn: Conn, srv: Srv, rs: List<&2, R.Reply>, q: List<&2, R.Cmd> & KV.Trie<String>) -> Logged:
  (es, db) = q
  Logged{rs, es, conn_ok(conn), srv, db}

def logged.fast(conn: Conn, srv: Srv, r: List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>)) -> Logged:
  (rs, q) = r
  logged.fast2(conn, srv, rs, q)

def logged.gen(st: Gen) -> Logged:
  match st:
    case Gen{rs, es, conn, srv, db}:
      Logged{List.reverse(&2, R.Reply, rs), List.reverse(&2, R.Cmd, es), conn, srv, db}

def run_log.plain(fast: Bool, conn: Conn, srv: Srv, cmds: List<&2, R.Cmd>, hs: List<&2, U32>, db: KV.Trie<String>) -> Logged:
  match fast cmds:
    case _ Nil{}:
      Logged{Nil{}, Nil{}, conn, srv, db}
    case True{} Con{c, cs}:
      logged.fast(conn, srv, A.log_batch(c <> cs, hs, db))
    case False{} Con{c, cs}:
      logged.gen(gen(conn, srv, c <> cs, db))

# a batch, as the server with an append-only file runs it
def run_log(conn: Conn, srv: Srv, job: B.Job, db: KV.Trie<String>) -> Logged:
  match job:
    case B.Plain{cmds, hs}:
      +c = conn
      +s = srv
      run_log.plain(ready(c, s), c, s, cmds, hs, db)
    case B.Mixed{cmds}:
      logged.gen(gen(conn, srv, cmds, db))
