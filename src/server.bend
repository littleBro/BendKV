# server.bend: the TCP server. This is the unverified shell around the
# proven core: it moves bytes between sockets and the pure functions of
# resp.bend, redis.bend and batch.bend, and runs forever, hence @unsafe.
#
# One computation, the database actor, owns the database and runs the
# commands one batch at a time, in arrival order, as Redis's single
# command thread does; the batches that wait for it together it takes at
# once and answers at once. Each connection is a computation of its own: it
# reads bytes, parses every complete request in its buffer, sends the
# batch to the actor with the connection's state (session.bend: S.Conn)
# and writes the replies back in order, keeping the state the actor gives
# back; after a QUIT it closes once its replies are out.
#
# Replies go out in one of two ways: post hands them to the loop's writer
# thread (TCP.post), which sends them on a core of its own while the loop
# goes on; send sends them from the loop itself (TCP.send_raw). A writer
# pays when it has a core to itself, so the default is post when the
# process may use two cores or more (IO.thread_count), and send otherwise;
# io-threads 1 sends, as Redis with one thread does.
#
# With an append-only file (appendonly yes), the actor also appends what
# each batch did to the file before it answers. When the server starts,
# it restores its database from the file (aof.bend and the Persistence
# laws).
#
# The server starts as redis-server starts (startup.bend reads the command
# line and the configuration; this file reads the files, changes the
# directory, listens and writes the log), or in BendKV's short form:
#
#   bend src/server.bend -o bendkv && ./bendkv [redis.conf] [--port 6380 ...]
#   ./bendkv 6380 [post|send [file [always|everysec|no]]]
#   redis-cli -p 6380 set foo bar

import Base
import ./map.bend as KV
import ./redis.bend as R
import ./resp.bend as P
import ./batch.bend as B
import ./aof.bend as A
import ./session.bend as S
import ./config.bend as C
import ./startup.bend as T
import ./info.bend as I
import ./rdb.bend as D
import ./command.bend as M

# a batch from a connection in the state cn (B.Job: its commands, and
# the hashes of their keys, for the hints of batch.bend, with the words
# of the codes of INFO's statistics in their high twelve bits), the
# channel its answer goes back on, how many requests it has and the words
# of their codes (R.tl.add), how many bytes it came in, and those bytes
# (raw: the lines of MONITOR read the arguments as sent from them; the
# fast way drops them); the shell's
# facts (info.bend: Live), which a connection sends before a batch that
# asks INFO or CONFIG RESETSTAT; the cron's tick, at ms since 1970, for
# INFO's rates; a protocol error a connection answered, for errorstats;
# a connection closed while its client waited (Blocked clients), and
# the channel its Bye goes back on; a connection closed, whose client's
# transaction, watched keys, subscriptions and line are forgotten
# (Transactions, Pub/Sub, Clients), and the channel the Bye it waits for
# before it closes its socket goes back on; or a connection opened, with
# its client's id, channel, socket's fd and addresses (Clients). A batch
# from a client with a subscription is a SubReq, which runs a command at
# a time.
type Req is Data:
  Req{cn: S.Conn, job: B.Job, back: Chan(Ans), tl: U32, inb: Nat, raw: String}
  SubReq{cn: S.Conn, job: B.Job, back: Chan(Ans), tl: U32, inb: Nat, raw: String}
  Facts{live: I.Live}
  Tick{ms: Nat}
  Oops{}
  Gone{id: Nat, back: Chan(Ans)}
  Left{id: Nat, back: Chan(Ans)}
  Join{id: Nat, back: Chan(Ans), fd: U32, addr: String, laddr: String}

# a batch's answer: its replies, encoded (none when CLIENT REPLY held
# them all back), and the connection's state after it (AnsSub: its
# client has a subscription after it, Pub/Sub, or monitors, MONITOR); or
# the replies of the
# batch so far, its client waiting (Hold), more to come. On the same
# channel, a watch of the socket says that bytes came (Ready), the actor
# that it holds nothing more for a client gone (Bye), and a message
# published to a subscribed client, or a line to a monitor, comes (Push).
type Ans is Data:
  Ans{out: Maybe<&2, String>, cn: S.Conn}
  AnsSub{out: Maybe<&2, String>, cn: S.Conn}
  Hold{out: Maybe<&2, String>}
  Ready{}
  Bye{}
  Push{out: String}

def ans_of(rs: List<&2, R.Reply>, cn: S.Conn) -> Ans:
  match rs:
    case Nil{}:
      Ans{None{}, cn}
    case Con{r, rest}:
      +c = cn
      Ans{Some{P.encode_in(S.conn.r3(c), r <> rest, SNil{})}, c}

# The protocol a batch run the general way began in: the connection's
# after it, unless a command of it switched (R.RSw): a switch is a change,
# so the protocol before the first is the other one
def sw.first(rs: List<&2, R.Reply>, +r3: Bool) -> Bool:
  match rs:
    case Nil{}:
      r3
    case Con{R.RSw{p, xs}, rest}:
      Bool.not(p)
    case Con{x, rest}:
      sw.first(rest, r3)

def ans_of.gen(rs: List<&2, R.Reply>, cn: S.Conn) -> Ans:
  match rs:
    case Nil{}:
      Ans{None{}, cn}
    case Con{+r, +rest}:
      +c = cn
      Ans{Some{P.encode_as(sw.first(r <> rest, S.conn.r3(c)), r <> rest)}, c}

# the bytes of an answer's replies
def ans.len(+a: Ans) -> Nat:
  match a:
    case Ans{Some{+out}, cn}:
      String.length(out)
    case AnsSub{Some{+out}, cn}:
      String.length(out)
    case Hold{Some{+out}}:
      String.length(out)
    case _:
      0n

# Statistics of a batch
# ---------------------
# INFO counts each call as Redis does (info.bend, Statistics): what it
# counts as comes in the high twelve bits of its hash (R.stat.hash). A
# batch that runs the fast way (S.run.plain: database commands only,
# from a client that may run them and gets every reply) gives each call
# one reply, in order, so its hashes count it whole (R.tally), and its
# replies are looked at for errors only where a call may have one
# (run_put). Any other batch runs a command at a time (S.run of one
# command runs it as the batch would: gen takes a command at a time), so
# that each is counted as it runs: dropped after a QUIT, refused when
# its client must authenticate first, or with the reply it gave, which
# is looked at even when CLIENT REPLY holds it back, as Redis counts
# every error reply. A later command of the batch (INFO) sees the counts
# of those before it.

# the message of an error the parser found (Bad, a session command's
# SBad, a failed call's SFail)
def gen.bad(+c: R.Cmd) -> String:
  match c:
    case R.Bad{R.RError{+m}}:
      m
    case R.Own{R.SBad{R.RError{+m}}}:
      m
    case R.Own{R.SFail{R.RError{+m}}}:
      m
    case _:
      ""

def mute.on(+m: S.Mute) -> Bool:
  match m:
    case S.MOn{}:
      True{}
    case _:
      False{}

# what a call counts as before it runs, and its error reply when that is
# known without its replies: a call refused for its client (NOAUTH), or
# one the parser refused or failed (its message). None: its error, if
# any, is among the replies of its run.
type Pre is Data:
  Pre{code: Nat, xs: Maybe<&2, List<&2, R.Erred>>}

def gen.pre.ran(ran: Bool, +c: R.Cmd, +code: Nat) -> Pre:
  match ran:
    case True{}:
      Pre{code, None{}}
    case False{}:
      Pre{code, Some{[R.Erred{code, gen.bad(c)}]}}

def gen.pre(ok: Bool, +c: R.Cmd, +code: Nat) -> Pre:
  match ok:
    case False{}:
      +refused = R.code.refused(code)
      Pre{refused, Some{[R.Erred{refused, "NOAUTH Authentication required."}]}}
    case True{}:
      gen.pre.ran(Nat.is_eq(R.code.class(code), 0n), c, code)

# whether a call runs while its client's replies are held back (CLIENT
# REPLY OFF or SKIP): its reply counts all the same
def gen.muted(+ok: Bool, +code: Nat, +conn: S.Conn) -> Bool:
  Bool.and(ok, Bool.and(Nat.is_eq(R.code.class(code), 0n), Bool.not(mute.on(S.conn.mode(conn)))))

def gen.errs(xs: Maybe<&2, List<&2, R.Erred>>, +rs1: List<&2, R.Reply>, +code: Nat) -> List<&2, R.Erred>:
  match xs:
    case Some{ys}:
      ys
    case None{}:
      R.errs.zip(rs1, [code], Nil{})

# one call's counts: whether it ran, its run, its error replies
def gen.count(srv: S.Srv, +code: Nat, ys: List<&2, R.Erred>) -> S.Srv:
  S.srv.errs(S.srv.ran(srv, R.code.calls(code, 1n), R.run.of(code, 1n), Nil{}, 0n, 0n), ys)

def gen.err.of(m: Maybe<&2, R.Reply>, +code: Nat) -> List<&2, R.Erred>:
  match m:
    case Some{R.RError{x}}:
      [R.Erred{code, x}]
    case _:
      Nil{}

def gen.pre.own(+o: R.SessOp, +code: Nat, +conn: S.Conn, +srv: S.Srv, +ds: R.Ds) -> Pre:
  Pre{code, Some{gen.err.of(S.own_reply(o, S.conn.on(conn), srv, ds), code)}}

# Blocked clients
# ---------------
# A blocking command that finds nothing to pop (session.bend, Blocking
# commands) makes its client wait, as Redis's blockForKeys does: the
# actor answers the replies of the batch before it (Hold), keeps the rest
# of the batch with the client, and the client's connection waits for the
# actor's next answer while it watches its socket (Connections). The
# clients wait in the order they came. After each command that runs while
# some wait, the first of them that a key of its own holds what it waits
# for (a list, or a sorted set) is served, the pop made on that key alone,
# then the first again, until none is: a key's elements go to the clients
# that waited longest, and a move (BLMOVE) may serve another, as Redis
# serves a ready key's clients in the order they blocked. Redis looks at a
# key when a command adds it (dbAdd), the actor at the keys after each
# command: a key that a STORE overwrote with a list or a sorted set serves
# a client that waits on it, where Redis 7.0 leaves it waiting, and the
# clients that one command serves from several keys (SWAPDB) go in the
# order they blocked, where Redis goes key by key. A client whose time is
# up at the end of a group gets a null array; CLIENT UNBLOCK unblocks one
# (a null array, or an UNBLOCKED error). An unblocked client's batch goes
# on at the end of the group, after the group's batches, as Redis runs an
# unblocked client's commands before it sleeps. The call counts when it
# blocks, as Redis's call() counts it, and fails when CLIENT UNBLOCK
# unblocks it or its reply is an error (updateStatsOnUnblock). A client
# whose connection closes is forgotten (Gone), its batch dropped. A
# client that a pause holds back waits in the same chain, with the
# command held back at the head of the rest of its batch (The pause): no
# key serves it, no time ends it, CLIENT UNBLOCK leaves it, and the end
# of the pause lets it go on.
#
# The state of a batch and the clients that wait are types that hold
# themselves, which the compiler makes nodes of their own: they travel
# as one word each. Flat, a batch's state is some twenty words, and the
# widest function or result sets the registers of every function: the
# server's requests would pay for the blocking commands (section 3zp).

# the arguments of a batch's requests as its client sent them, for the
# lines of MONITOR (MONITOR, below): the batch's bytes and the number of
# the request that runs next, read only once a client monitors (AvRaw);
# or read, the arguments of each request yet to run, in order (AvArgs)
type Av is Data:
  AvRaw{raw: String, next: Nat}
  AvArgs{xs: List<&2, List<&2, String>>}

# the clients that wait, in the order they came, a chain of them: each
# with its id and the channel its answers go back on, its connection
# before the blocking command (whose mode says whether the reply goes
# out) and after it, the pop it waits to make, the size of the blocking
# command's arguments (CLIENT LIST's argv-mem), the code it counts as,
# its database, when its time is up (ms since 1970, 0 never), and the
# rest of its batch: the commands after the blocking one, their codes and
# their arguments as sent.
# A client taken out of the chain is a chain of one.
type Waits is Data:
  WaitNone{}
  WaitOn{id: Nat, back: Chan(Ans), c0: S.Conn, c1: S.Conn, b: S.Blk, argv: Nat, code: Nat, db: Nat, until: Nat, cmds: List<&2, R.Cmd>, codes: List<&2, Nat>, av: Av, rest: Waits}

# a client unblocked, whose batch goes on at the end of the group: the
# channel of its answers, its connection, its replies so far (newest
# first: the blocking command's, unless its replies are held back) and
# the rest of its batch, with its arguments as sent
type Up is Data:
  Up{back: Chan(Ans), conn: S.Conn, rs: List<&2, R.Reply>, cmds: List<&2, R.Cmd>, codes: List<&2, Nat>, av: Av}

# whether the first client of ws is the client of id n; whether its time
# is up at now; its pop, code and database
def waits.is(+n: Nat, +ws: Waits) -> Bool:
  match ws:
    case WaitOn{+id, back, c0, c1, b, argv, code, db, until, cmds, codes, av, rest}:
      Nat.is_eq(id, n)
    case WaitNone{}:
      False{}

def waits.late(+now: Nat, +ws: Waits) -> Bool:
  match ws:
    case WaitOn{id, back, c0, c1, b, argv, code, db, +until, cmds, codes, av, rest}:
      Bool.and(Nat.is_lt(0n, until), Nat.is_lt(until, now))
    case WaitNone{}:
      False{}

def waits.blk(+ws: Waits) -> S.Blk:
  match ws:
    case WaitOn{id, back, c0, c1, +b, argv, code, db, until, cmds, codes, av, rest}:
      b
    case WaitNone{}:
      S.BlkBad{R.RNull{}}

def waits.db(+ws: Waits) -> Nat:
  match ws:
    case WaitOn{id, back, c0, c1, b, argv, code, +db, until, cmds, codes, av, rest}:
      db
    case WaitNone{}:
      0n

# whether a client waits held back by the pause (BlkPause: The pause)
def blk.held(+b: S.Blk) -> Bool:
  match b:
    case S.BlkPause{}:
      True{}
    case _:
      False{}

def waits.held(+ws: Waits) -> Bool:
  match ws:
    case WaitOn{id, back, c0, c1, +b, argv, code, db, until, cmds, codes, av, rest}:
      blk.held(b)
    case WaitNone{}:
      False{}

# whether the client of id waits for a save (save.hold: SAVE's, or a
# SHUTDOWN's that saves): Redis saves within the command, so no client of
# theirs is ever blocked, and CLIENT UNBLOCK answers 0 for it
def waits.saving.is(+n: Nat, +ws: Waits) -> Bool:
  match ws:
    case WaitOn{+id, back, c0, c1, b, argv, +code, db, until, cmds, codes, av, +rest}:
      +k = R.code.key(code)
      Bool.or(Bool.and(Nat.is_eq(id, n), Bool.or(Nat.is_eq(k, R.stat.top(203n)), Nat.is_eq(k, R.stat.top(187n)))), waits.saving.is(n, rest))
    case WaitNone{}:
      False{}

# whether the client of id waits held back by the pause
def waits.held.is(+n: Nat, +ws: Waits) -> Bool:
  match ws:
    case WaitOn{+id, back, c0, c1, +b, argv, code, db, until, cmds, codes, av, +rest}:
      Bool.or(Bool.and(Nat.is_eq(id, n), blk.held(b)), waits.held.is(n, rest))
    case WaitNone{}:
      False{}

def ups.is(+n: Nat, +us: List<&2, Up>) -> Bool:
  match us:
    case Con{Up{back, +conn, rs, cmds, codes, av}, rest}:
      Nat.is_eq(S.conn.id(conn), n)
    case _:
      False{}

# acc (newest first) put back in order before ws
def waits.rev(acc: Waits, ws: Waits) -> Waits:
  match acc:
    case WaitNone{}:
      ws
    case WaitOn{id, back, c0, c1, b, argv, code, db, until, cmds, codes, av, rest}:
      waits.rev(rest, WaitOn{id, back, c0, c1, b, argv, code, db, until, cmds, codes, av, ws})

# ws with w after its clients
def waits.add(ws: Waits, w: Waits) -> Waits:
  match ws:
    case WaitNone{}:
      w
    case WaitOn{id, back, c0, c1, b, argv, code, db, until, cmds, codes, av, rest}:
      WaitOn{id, back, c0, c1, b, argv, code, db, until, cmds, codes, av, waits.add(rest, w)}

# how many clients wait (on n), and how many of them have a time (on t)
def waits.len(ws: Waits, +n: Nat, +t: Nat) -> Nat & Nat:
  match ws:
    case WaitNone{}:
      (n, t)
    case WaitOn{id, back, c0, c1, b, argv, code, db, +until, cmds, codes, av, rest}:
      waits.len(rest, 1n+n, Bool.pick(Nat, Nat.is_lt(0n, until), 1n+t, t))

def waits.put(p: Nat & Nat, srv: S.Srv) -> S.Srv:
  (+n, +t) = p
  S.srv.blocked(srv, n, t)

# the clients that wait, and those of them with a time, for INFO
def waits.count(+ws: Waits, srv: S.Srv) -> S.Srv:
  waits.put(waits.len(ws, 0n, 0n), srv)

def waits.length(ws: Waits, +n: Nat) -> Nat:
  match ws:
    case WaitNone{}:
      n
    case WaitOn{id, back, c0, c1, b, argv, code, db, until, cmds, codes, av, rest}:
      waits.length(rest, 1n+n)

# the client of id n taken out of ws, a chain of one (none: no client of
# the id waits), and the others (hit: whether the first of ws is it; acc:
# those before it, newest first)
def waits.take(ws: Waits, hit: Bool, +n: Nat, acc: Waits) -> Waits & Waits:
  match ws hit:
    case WaitOn{id, back, c0, c1, b, argv, code, db, until, cmds, codes, av, rest} True{}:
      (WaitOn{id, back, c0, c1, b, argv, code, db, until, cmds, codes, av, WaitNone{}}, waits.rev(acc, rest))
    case WaitOn{id, back, c0, c1, b, argv, code, db, until, cmds, codes, av, +rest} False{}:
      waits.take(rest, waits.is(n, rest), n, WaitOn{id, back, c0, c1, b, argv, code, db, until, cmds, codes, av, acc})
    case WaitNone{} _:
      (WaitNone{}, waits.rev(acc, WaitNone{}))

def waits.rest(p: Waits & Waits) -> Waits:
  (w, ws) = p
  ws

# us without the client of id n (hit: whether the first of us is it)
def ups.drop(us: List<&2, Up>, hit: Bool, +n: Nat) -> List<&2, Up>:
  match us hit:
    case Nil{} _:
      Nil{}
    case Con{u, +rest} True{}:
      ups.drop(rest, ups.is(n, rest), n)
    case Con{u, +rest} False{}:
      u <> ups.drop(rest, ups.is(n, rest), n)

# the clients whose time is up at now unblocked (late: whether the first
# of ws's is) with a null array, or 0 for WAIT (S.blk.late), in the order
# they came, the others kept in order (keep: those before, newest first)
def waits.expire(ws: Waits, late: Bool, +now: Nat, keep: Waits, up: List<&2, Up>) -> Waits & List<&2, Up>:
  match ws late:
    case WaitNone{} _:
      (waits.rev(keep, WaitNone{}), up)
    case WaitOn{id, back, +c0, c1, +b, argv, code, db, until, cmds, codes, av, +rest} True{}:
      waits.expire(rest, waits.late(now, rest), now, keep, Up{back, c1, S.put(S.say(S.conn.mode(c0), S.blk.late(b)), Nil{}), cmds, codes, av} <> up)
    case WaitOn{id, back, c0, c1, b, argv, code, db, until, cmds, codes, av, +rest} False{}:
      waits.expire(rest, waits.late(now, rest), now, WaitOn{id, back, c0, c1, b, argv, code, db, until, cmds, codes, av, keep}, up)

# whether the first of ks holds what a pop waits for (z: a sorted set) in
# the focus of d, and the first of ks that does (hit: whether the first
# does)
def keys.has(+d: R.Ds, +z: Bool, +ks: List<&2, String>) -> Bool:
  match ks:
    case Con{+k, rest}:
      S.blk.has(z, R.ds.ent(d, k))
    case Nil{}:
      False{}

def keys.ready(ks: List<&2, String>, hit: Bool, +d: R.Ds, +z: Bool) -> Maybe<&2, String>:
  match ks hit:
    case Con{k, rest} True{}:
      Some{k}
    case Con{k, +rest} False{}:
      keys.ready(rest, keys.has(d, z, rest), d, z)
    case Nil{} _:
      None{}

# the key of the first client's (b: its pop, d: the databases focused on
# its own) that holds what it waits for, if one does
def waits.ready.of(+d: R.Ds, +b: S.Blk) -> Maybe<&2, String>:
  +z = S.blk.zset(b)
  +ks = S.blk.keys(b)
  keys.ready(ks, keys.has(d, z, ks), d, z)

def waits.ready(+ds: R.Ds, +ws: Waits) -> Maybe<&2, String>:
  match ws:
    case WaitOn{id, back, c0, c1, +b, argv, code, +db, until, cmds, codes, av, rest}:
      waits.ready.of(R.ds.focus(db, ds), b)
    case WaitNone{}:
      None{}

# the first client of ws that a key of its holds what it waits for, a
# chain of one, with that key and the others in order (m: that key of
# the first of ws, if one does; acc: those before, newest first)
type Found is Data:
  Found{w: Waits, k: String, ws: Waits}
  NotFound{ws: Waits}

def waits.find(ws: Waits, m: Maybe<&2, String>, +ds: R.Ds, acc: Waits) -> Found:
  match ws m:
    case WaitOn{id, back, c0, c1, b, argv, code, db, until, cmds, codes, av, rest} Some{k}:
      Found{WaitOn{id, back, c0, c1, b, argv, code, db, until, cmds, codes, av, WaitNone{}}, k, waits.rev(acc, rest)}
    case WaitOn{id, back, c0, c1, b, argv, code, db, until, cmds, codes, av, +rest} None{}:
      waits.find(rest, waits.ready(ds, rest), ds, WaitOn{id, back, c0, c1, b, argv, code, db, until, cmds, codes, av, acc})
    case WaitNone{} _:
      NotFound{waits.rev(acc, WaitNone{})}

# Transactions
# ------------
# MULTI, EXEC, DISCARD, WATCH and UNWATCH run as Redis 7.0.15 runs them
# (multi.c). The session answers them as a client without a transaction
# is answered (session.bend); the actor keeps each client's transaction
# and the keys it watches, a chain of clients by their ids, and acts on
# them as they run (bg.cmd). After MULTI a command is queued (QUEUED),
# but for EXEC, DISCARD, MULTI (an error: they do not nest), WATCH (an
# error inside MULTI), QUIT and RESET, which run; a command refused
# while it is queued (an unknown command, a wrong number of arguments,
# NOAUTH) flags the transaction, and EXEC then answers EXECABORT. EXEC
# runs the queued commands one after another as one: no client that
# waits is served between them, a blocking command does not wait (it
# answers as a client that may not wait is answered), and their replies
# are EXEC's array; the append-only file has their effects between a
# MULTI and an EXEC when they are two or more, as Redis has them. A
# watched key that a command changes (its effects, Touches), or that is
# there with its time passed when EXEC comes, makes EXEC answer a null
# array, and the transaction is dropped. EXEC, DISCARD and RESET end a
# transaction and unwatch the keys, and a client gone is forgotten (its
# connection tells the actor, Left). Each call counts as Redis counts
# it: a queued command when EXEC runs it, a refused one when it is
# refused, and EXEC itself once, failed when its own reply is an error.
#
# While no client has a transaction or watches a key, the chain is empty
# and costs nothing; while one does, every batch runs the general way,
# a command at a time, so that each command's effects touch the keys.

# a watched key: its database, the key, and whether the key's entry was
# there with its time passed when it was watched (old: Redis's expired
# flag; the deletion of such an entry is no change)
type Wk is Data:
  Wk{db: Nat, key: String, old: Bool}

# the clients with a transaction or watched keys, a chain of them: each
# with its id, whether it is in MULTI, whether a command was refused
# while it queued (bad: EXECABORT), whether a key it watched was touched
# (cas: EXEC answers a null array), the commands queued (newest first),
# their codes and their arguments as sent (each an Av whose next request
# is the command's), and the keys it watches. While a batch runs, its
# client is the first of the chain, if it is in it (tx.front).
type Tx is Data:
  TxNone{}
  TxOn{id: Nat, multi: Bool, bad: Bool, cas: Bool, cmds: List<&2, R.Cmd>, codes: List<&2, Nat>, avs: List<&2, Av>, keys: List<&2, Wk>, rest: Tx}

def tx.on(+t: Tx) -> Bool:
  match t:
    case TxNone{}:
      False{}
    case TxOn{i, mu, bd, cs, qs, qc, qa, wk, r}:
      True{}

# whether the first client of t is the client of id n, and whether it is
# in MULTI
def tx.is(+n: Nat, +t: Tx) -> Bool:
  match t:
    case TxOn{+i, mu, bd, cs, qs, qc, qa, wk, r}:
      Nat.is_eq(i, n)
    case TxNone{}:
      False{}

def tx.multi(+n: Nat, +t: Tx) -> Bool:
  match t:
    case TxOn{+i, +mu, bd, cs, qs, qc, qa, wk, r}:
      Bool.and(Nat.is_eq(i, n), mu)
    case TxNone{}:
      False{}

# whether the client of id n is in MULTI, wherever it is in t, or hit
def tx.in.multi(+t: Tx, +n: Nat, hit: Bool) -> Bool:
  match t:
    case TxNone{}:
      hit
    case TxOn{+i, +mu, bd, cs, qs, qc, qa, wk, +r}:
      tx.in.multi(r, n, Bool.or(hit, Bool.and(Nat.is_eq(i, n), mu)))

# acc (newest first) put back in order before t
def tx.rev(acc: Tx, t: Tx) -> Tx:
  match acc:
    case TxNone{}:
      t
    case TxOn{i, mu, bd, cs, qs, qc, qa, wk, r}:
      tx.rev(r, TxOn{i, mu, bd, cs, qs, qc, qa, wk, t})

# the client of id n taken out of t, a chain of one (none: it has no
# transaction and watches nothing), and the others (hit: whether the
# first of t is it; acc: those before it, newest first)
def tx.take(t: Tx, hit: Bool, +n: Nat, acc: Tx) -> Tx & Tx:
  match t hit:
    case TxOn{i, mu, bd, cs, qs, qc, qa, wk, r} True{}:
      (TxOn{i, mu, bd, cs, qs, qc, qa, wk, TxNone{}}, tx.rev(acc, r))
    case TxOn{i, mu, bd, cs, qs, qc, qa, wk, +r} False{}:
      tx.take(r, tx.is(n, r), n, TxOn{i, mu, bd, cs, qs, qc, qa, wk, acc})
    case TxNone{} _:
      (TxNone{}, tx.rev(acc, TxNone{}))

def tx.put(p: Tx & Tx) -> Tx:
  (one, others) = p
  match one:
    case TxOn{i, mu, bd, cs, qs, qc, qa, wk, r}:
      TxOn{i, mu, bd, cs, qs, qc, qa, wk, others}
    case TxNone{}:
      others

def tx.rest(p: Tx & Tx) -> Tx:
  (one, others) = p
  others

# the client of id n first in t, if it is in it
def tx.front(+n: Nat, t: Tx) -> Tx:
  +x = t
  tx.put(tx.take(x, tx.is(n, x), n, TxNone{}))

# t without the client of id n (its connection closed)
def tx.drop(+n: Nat, t: Tx) -> Tx:
  +x = t
  tx.rest(tx.take(x, tx.is(n, x), n, TxNone{}))

# MULTI of the client of id n, first in t if it is in it
def tx.open.of(mine: Bool, +n: Nat, t: Tx) -> Tx:
  match mine t:
    case True{} TxOn{i, mu, bd, cs, qs, qc, qa, wk, r}:
      TxOn{i, True{}, bd, cs, qs, qc, qa, wk, r}
    case _ t0:
      TxOn{n, True{}, False{}, False{}, Nil{}, Nil{}, Nil{}, Nil{}, t0}

def tx.open(+n: Nat, t: Tx) -> Tx:
  +x = t
  tx.open.of(tx.is(n, x), n, x)

# the transaction of the client first in t, ended: EXEC, DISCARD, RESET
def tx.close.of(mine: Bool, t: Tx) -> Tx:
  match mine t:
    case True{} TxOn{i, mu, bd, cs, qs, qc, qa, wk, r}:
      r
    case _ t0:
      t0

def tx.close(+n: Nat, t: Tx) -> Tx:
  +x = t
  tx.close.of(tx.is(n, x), x)

# a command queued by the client first in t (in MULTI); none once the
# transaction is to fail, as Redis keeps none then
def tx.queued(skip: Bool, i: Nat, mu: Bool, bd: Bool, cs: Bool, qs: List<&2, R.Cmd>, qc: List<&2, Nat>, qa: List<&2, Av>, wk: List<&2, Wk>, r: Tx, c: R.Cmd, +code: Nat, a: Av) -> Tx:
  match skip:
    case True{}:
      TxOn{i, mu, bd, cs, qs, qc, qa, wk, r}
    case False{}:
      TxOn{i, mu, bd, cs, c <> qs, code <> qc, a <> qa, wk, r}

def tx.queue(c: R.Cmd, +code: Nat, a: Av, t: Tx) -> Tx:
  match t:
    case TxOn{i, mu, +bd, +cs, qs, qc, qa, wk, r}:
      tx.queued(Bool.or(bd, cs), i, mu, bd, cs, qs, qc, qa, wk, r, c, code, a)
    case TxNone{}:
      TxNone{}

# the transaction of the client first in t flagged: a command refused
# while it queued
def tx.bad(t: Tx) -> Tx:
  match t:
    case TxOn{i, mu, bd, cs, qs, qc, qa, wk, r}:
      TxOn{i, mu, True{}, cs, qs, qc, qa, wk, r}
    case TxNone{}:
      TxNone{}

# UNWATCH of the client first in t: its keys and its touch forgotten
def tx.unwatch.of(mine: Bool, t: Tx) -> Tx:
  match mine t:
    case True{} TxOn{i, True{}, bd, cs, qs, qc, qa, wk, r}:
      TxOn{i, True{}, bd, False{}, qs, qc, qa, Nil{}, r}
    case True{} TxOn{i, False{}, bd, cs, qs, qc, qa, wk, r}:
      r
    case _ t0:
      t0

def tx.unwatch(+n: Nat, t: Tx) -> Tx:
  +x = t
  tx.unwatch.of(tx.is(n, x), x)

# k's entry in database j of ds (there at now or not). The list of the
# databases is held while R.dbs.entry reads it, so that the reads of the
# keyspace borrow it.
def ds.entry.at(focus: Bool, +j: Nat, +k: String, +ds: R.Ds) -> Maybe<&2, KV.Item<KV.Val>>:
  match focus:
    case True{}:
      R.ds.entry(ds, k)
    case False{}:
      xs = R.ds.list(ds)
      m = R.dbs.entry(j, k, xs)
      m

def ds.entry(+j: Nat, +k: String, +ds: R.Ds) -> Maybe<&2, KV.Item<KV.Val>>:
  ds.entry.at(Nat.is_eq(j, R.ds.index(ds)), j, k, ds)

def ds.here(+j: Nat, +k: String, +ds: R.Ds) -> Bool:
  Maybe.is_some(&2, KV.Item<KV.Val>, ds.entry(j, k, ds))

# whether ks has key k of database j
def wk.hit(+j: Nat, +k: String, +w: Wk) -> Bool:
  match w:
    case Wk{+d, +key, old}:
      Bool.and(Nat.is_eq(d, j), String.eq(key, k))

def wk.has(+j: Nat, +k: String, +ks: List<&2, Wk>) -> Bool:
  match ks:
    case Nil{}:
      False{}
    case Con{+w, +rest}:
      Bool.or(wk.hit(j, k, w), wk.has(j, k, rest))

# WATCH of keys ks of database j: each key not watched yet, with whether
# its entry is there with its time passed at now
def wk.put(has: Bool, +j: Nat, +k: String, old: Bool, acc: List<&2, Wk>) -> List<&2, Wk>:
  match has:
    case True{}:
      acc
    case False{}:
      Wk{j, k, old} <> acc

def wk.add(ks: List<&2, String>, +j: Nat, +ds: R.Ds, +now: Nat, acc: List<&2, Wk>) -> List<&2, Wk>:
  match ks:
    case Nil{}:
      acc
    case Con{+k, rest}:
      +a = acc
      wk.add(rest, j, ds, now, wk.put(wk.has(j, k, a), j, k, R.ent.dead(now, ds.entry(j, k, ds)), a))

# WATCH of the client of id n, first in t if it is in it: nothing more
# once a key it watched was touched, as Redis watches no more then
def tx.watch.of(mine: Bool, +n: Nat, +j: Nat, ks: List<&2, String>, +ds: R.Ds, t: Tx) -> Tx:
  match mine t:
    case True{} TxOn{i, mu, bd, True{}, qs, qc, qa, wk, r}:
      TxOn{i, mu, bd, True{}, qs, qc, qa, wk, r}
    case True{} TxOn{i, mu, bd, False{}, qs, qc, qa, wk, r}:
      TxOn{i, mu, bd, False{}, qs, qc, qa, wk.add(ks, j, ds, R.ds.now(ds), wk), r}
    case _ t0:
      TxOn{n, False{}, False{}, False{}, Nil{}, Nil{}, Nil{}, wk.add(ks, j, ds, R.ds.now(ds), Nil{}), t0}

def tx.watch(+n: Nat, +j: Nat, ks: List<&2, String>, +ds: R.Ds, t: Tx) -> Tx:
  +x = t
  tx.watch.of(tx.is(n, x), n, j, ks, ds, x)

# whether a key watched while its entry was not there with its time
# passed is there now with its time passed (Redis's isWatchedKeyExpired)
def wk.late(+ks: List<&2, Wk>, +ds: R.Ds, +now: Nat) -> Bool:
  match ks:
    case Nil{}:
      False{}
    case Con{Wk{+d, +k, +old}, +rest}:
      Bool.or(Bool.and(Bool.not(old), R.ent.dead(now, ds.entry(d, k, ds))), wk.late(rest, ds, now))

# Touches
# -------
# A command's effects say what it changed, as Redis's signalModifiedKey
# says it: the keys a command of one database wrote (SET, an update, DEL,
# MSET, RENAME, LMOVE, SMOVE: a key that was there before the command or
# after it; a DEL of a key that was not there touches nothing, nor does
# SMOVE its destination when the member was there already), MOVE's
# key in both databases, COPY's destination, and FLUSHDB, FLUSHALL and
# SWAPDB, which touch the keys there before them (touchAllWatchedKeysInDb).
# A touch makes the clients that watch the key dirty and unwatches their
# keys; but a key watched while its entry was there with its time passed
# (old) is no change when the entry goes, and is watched on as a key not
# there, as Redis clears its expired flag when such a key is deleted.

# a client's keys after a touch of key k of database j (here: whether it
# is there after the command), or none when the touch makes it dirty
def wk.cons(w: Wk, m: Maybe<&2, List<&2, Wk>>) -> Maybe<&2, List<&2, Wk>>:
  match m:
    case Some{ks}:
      Some{w <> ks}
    case None{}:
      None{}

def wk.gone(here: Bool, d: Nat, k: String, m: Maybe<&2, List<&2, Wk>>) -> Maybe<&2, List<&2, Wk>>:
  match here:
    case True{}:
      None{}
    case False{}:
      wk.cons(Wk{d, k, False{}}, m)

def wk.touch.at(hit: Bool, w: Wk, +here: Bool, m: Maybe<&2, List<&2, Wk>>) -> Maybe<&2, List<&2, Wk>>:
  match hit w:
    case False{} w0:
      wk.cons(w0, m)
    case True{} Wk{d, key, True{}}:
      wk.gone(here, d, key, m)
    case True{} Wk{d, key, False{}}:
      None{}

def wk.touch(ks: List<&2, Wk>, +j: Nat, +k: String, +here: Bool) -> Maybe<&2, List<&2, Wk>>:
  match ks:
    case Nil{}:
      Some{Nil{}}
    case Con{+w, rest}:
      wk.touch.at(wk.hit(j, k, w), w, here, wk.touch(rest, j, k, here))

# a client after a touch: its keys, or dirty with none
def tx.touched(m: Maybe<&2, List<&2, Wk>>, i: Nat, mu: Bool, bd: Bool, cs: Bool, qs: List<&2, R.Cmd>, qc: List<&2, Nat>, qa: List<&2, Av>, r: Tx) -> Tx:
  match m:
    case Some{ks}:
      TxOn{i, mu, bd, cs, qs, qc, qa, ks, r}
    case None{}:
      TxOn{i, mu, bd, True{}, qs, qc, qa, Nil{}, r}

def tx.touch(t: Tx, +j: Nat, +k: String, +here: Bool) -> Tx:
  match t:
    case TxNone{}:
      TxNone{}
    case TxOn{i, mu, bd, cs, qs, qc, qa, wk, r}:
      tx.touched(wk.touch(wk, j, k, here), i, mu, bd, cs, qs, qc, qa, tx.touch(r, j, k, here))

# whether a client of t watches key k of database j
def tx.watched(+j: Nat, +k: String, +t: Tx) -> Bool:
  match t:
    case TxNone{}:
      False{}
    case TxOn{i, mu, bd, cs, qs, qc, qa, +wk, +r}:
      Bool.or(wk.has(j, k, wk), tx.watched(j, k, r))

# a write of key k of database j: a touch when the key was there before
# the command (pre; none: it was) or is after it (post)
def tx.was(+pre: Maybe<&2, R.Ds>, +j: Nat, +k: String) -> Bool:
  match pre:
    case Some{+d}:
      ds.here(j, k, d)
    case None{}:
      True{}

def touch.key.at(any: Bool, t: Tx, +j: Nat, +k: String, +here: Bool) -> Tx:
  match any:
    case True{}:
      tx.touch(t, j, k, here)
    case False{}:
      t

def touch.key.if(w: Bool, t: Tx, +j: Nat, +k: String, +pre: Maybe<&2, R.Ds>, +post: R.Ds) -> Tx:
  match w:
    case False{}:
      t
    case True{}:
      +here = ds.here(j, k, post)
      touch.key.at(Bool.or(here, tx.was(pre, j, k)), t, j, k, here)

def touch.key(t: Tx, +j: Nat, +k: String, +pre: Maybe<&2, R.Ds>, +post: R.Ds) -> Tx:
  +x = t
  touch.key.if(tx.watched(j, k, x), x, j, k, pre, post)

def touch.keys(+ks: List<&2, String>, t: Tx, +j: Nat, +pre: Maybe<&2, R.Ds>, +post: R.Ds) -> Tx:
  match ks:
    case Nil{}:
      t
    case Con{+k, +rest}:
      touch.keys(rest, touch.key(t, j, k, pre, post), j, pre, post)

def touch.pairs(+ps: List<&2, R.KVPair>, t: Tx, +j: Nat, +pre: Maybe<&2, R.Ds>, +post: R.Ds) -> Tx:
  match ps:
    case Nil{}:
      t
    case Con{R.KP{+k, v}, +rest}:
      touch.pairs(rest, touch.key(t, j, k, pre, post), j, pre, post)

# FLUSHDB of database j (all: FLUSHALL, of every database): a watched
# key of it that was there before (pre) is touched as one deleted
def wk.flush.at(hit: Bool, d: Nat, k: String, old: Bool, m: Maybe<&2, List<&2, Wk>>) -> Maybe<&2, List<&2, Wk>>:
  match hit old:
    case False{} o:
      wk.cons(Wk{d, k, o}, m)
    case True{} True{}:
      wk.cons(Wk{d, k, False{}}, m)
    case True{} False{}:
      None{}

def wk.flush(ks: List<&2, Wk>, +all: Bool, +j: Nat, +pre: R.Ds) -> Maybe<&2, List<&2, Wk>>:
  match ks:
    case Nil{}:
      Some{Nil{}}
    case Con{Wk{+d, +k, old}, rest}:
      wk.flush.at(Bool.and(Bool.or(all, Nat.is_eq(d, j)), ds.here(d, k, pre)), d, k, old, wk.flush(rest, all, j, pre))

def tx.flush(t: Tx, +all: Bool, +j: Nat, +pre: R.Ds) -> Tx:
  match t:
    case TxNone{}:
      TxNone{}
    case TxOn{i, mu, bd, cs, qs, qc, qa, wk, r}:
      tx.touched(wk.flush(wk, all, j, pre), i, mu, bd, cs, qs, qc, qa, tx.flush(r, all, j, pre))

# SWAPDB a b: a watched key of either is touched when it was there in
# its database or in the other before the swap, as Redis's
# touchAllWatchedKeysInDb sees it: a key watched old stays watched when
# the other has none (the deletion of an old entry) or has one whose
# time has passed, and a key not there replaced by one whose time has
# passed is watched on as old (ex: there in its own; inr: there in the
# other; dead: the other's time passed at now)
def wk.swap.old(inr: Bool, ex: Bool, dead: Bool, d: Nat, k: String, m: Maybe<&2, List<&2, Wk>>) -> Maybe<&2, List<&2, Wk>>:
  match inr ex dead:
    case False{} True{} _:
      wk.cons(Wk{d, k, False{}}, m)
    case False{} False{} _:
      wk.cons(Wk{d, k, True{}}, m)
    case True{} _ True{}:
      wk.cons(Wk{d, k, True{}}, m)
    case True{} _ False{}:
      None{}

def wk.swap.new(inr: Bool, ex: Bool, dead: Bool, d: Nat, k: String, m: Maybe<&2, List<&2, Wk>>) -> Maybe<&2, List<&2, Wk>>:
  match inr ex dead:
    case False{} True{} _:
      None{}
    case False{} False{} _:
      wk.cons(Wk{d, k, False{}}, m)
    case True{} False{} True{}:
      wk.cons(Wk{d, k, True{}}, m)
    case True{} _ _:
      None{}

def wk.swap.do(old: Bool, ex: Bool, inr: Bool, dead: Bool, d: Nat, k: String, m: Maybe<&2, List<&2, Wk>>) -> Maybe<&2, List<&2, Wk>>:
  match old:
    case True{}:
      wk.swap.old(inr, ex, dead, d, k, m)
    case False{}:
      wk.swap.new(inr, ex, dead, d, k, m)

# a key of database d swapped with database o
def wk.swap.at(+d: Nat, +o: Nat, +k: String, old: Bool, +pre: R.Ds, m: Maybe<&2, List<&2, Wk>>) -> Maybe<&2, List<&2, Wk>>:
  +mr = ds.entry(o, k, pre)
  wk.swap.do(old, ds.here(d, k, pre), Maybe.is_some(&2, KV.Item<KV.Val>, mr), R.ent.dead(R.ds.now(pre), mr), d, k, m)

def wk.swap.one(isa: Bool, isb: Bool, +d: Nat, +k: String, old: Bool, +a: Nat, +b: Nat, +pre: R.Ds, m: Maybe<&2, List<&2, Wk>>) -> Maybe<&2, List<&2, Wk>>:
  match isa isb:
    case True{} _:
      wk.swap.at(d, b, k, old, pre, m)
    case False{} True{}:
      wk.swap.at(d, a, k, old, pre, m)
    case False{} False{}:
      wk.cons(Wk{d, k, old}, m)

def wk.swap(ks: List<&2, Wk>, +a: Nat, +b: Nat, +pre: R.Ds) -> Maybe<&2, List<&2, Wk>>:
  match ks:
    case Nil{}:
      Some{Nil{}}
    case Con{Wk{+d, +k, old}, rest}:
      wk.swap.one(Nat.is_eq(d, a), Nat.is_eq(d, b), d, k, old, a, b, pre, wk.swap(rest, a, b, pre))

def tx.swap(t: Tx, +a: Nat, +b: Nat, +pre: R.Ds) -> Tx:
  match t:
    case TxNone{}:
      TxNone{}
    case TxOn{i, mu, bd, cs, qs, qc, qa, wk, r}:
      tx.touched(wk.swap(wk, a, b, pre), i, mu, bd, cs, qs, qc, qa, tx.swap(r, a, b, pre))

def touch.swap.if(same: Bool, t: Tx, +a: Nat, +b: Nat, +pre: R.Ds) -> Tx:
  match same:
    case True{}:
      t
    case False{}:
      tx.swap(t, a, b, pre)

def touch.swap(+pre: Maybe<&2, R.Ds>, t: Tx, +a: Nat, +b: Nat) -> Tx:
  match pre:
    case Some{+d}:
      touch.swap.if(Nat.is_eq(a, b), t, a, b, d)
    case None{}:
      t

def touch.wipe(+pre: Maybe<&2, R.Ds>, t: Tx, +all: Bool, +j: Nat, +post: R.Ds) -> Tx:
  match pre:
    case Some{+d}:
      tx.flush(t, all, j, d)
    case None{}:
      tx.flush(t, all, j, post)

# a command of database j's effect
# SMOVE's destination changes only when the member was not in its set
# (smoveCommand signals it when setTypeAdd added): the member there in
# the live set before the command (pre; none: it was not) is no change
def smv.had(+now: Nat, +m: String, e: Maybe<&2, KV.Item<KV.Val>>) -> Bool:
  match e:
    case Some{KV.Item{KV.VColl{KV.CMems{+s}}, +x}}:
      Bool.and(KV.live(now, x), KV.mems.has(m, s))
    case _:
      False{}

def smv.added(+pre: Maybe<&2, R.Ds>, +j: Nat, +d: String, +m: String) -> Bool:
  match pre:
    case Some{+x}:
      Bool.not(smv.had(R.ds.now(x), m, ds.entry(j, d, x)))
    case None{}:
      True{}

def touch.dst(on: Bool, t: Tx, +j: Nat, +k: String, +pre: Maybe<&2, R.Ds>, +post: R.Ds) -> Tx:
  match on:
    case True{}:
      touch.key(t, j, k, pre, post)
    case False{}:
      t

def touch.cmd(+c: R.Cmd, t: Tx, +j: Nat, +pre: Maybe<&2, R.Ds>, +post: R.Ds) -> Tx:
  match c:
    case R.Set{+k, v}:
      touch.key(t, j, k, pre, post)
    case R.Upd{+k, op}:
      touch.key(t, j, k, pre, post)
    case R.Del{+ks}:
      touch.keys(ks, t, j, pre, post)
    case R.MSet{+ps}:
      touch.pairs(ps, t, j, pre, post)
    case R.FlushDb{}:
      touch.wipe(pre, t, False{}, j, post)
    case R.Rename{+s, +d, nx}:
      touch.key(touch.key(t, j, s, pre, post), j, d, pre, post)
    case R.LMove{+s, +d, e}:
      touch.key(touch.key(t, j, s, pre, post), j, d, pre, post)
    case R.SMv{+s, +d, +w}:
      touch.dst(smv.added(pre, j, d, R.smv.member(w)), touch.key(t, j, s, pre, post), j, d, pre, post)
    case _:
      t

def touch.eff(+e: A.Eff, t: Tx, +pre: Maybe<&2, R.Ds>, +post: R.Ds) -> Tx:
  match e:
    case A.EDb{+j, +c}:
      touch.cmd(c, t, j, pre, post)
    case A.ESwap{+a, +b}:
      touch.swap(pre, t, a, b)
    case A.EMove{+k, +s, +d}:
      touch.key(touch.key(t, s, k, pre, post), d, k, pre, post)
    case A.ECopy{s, +d, from, +to}:
      touch.key(t, to, d, pre, post)
    case A.EWipe{}:
      touch.wipe(pre, t, True{}, 0n, post)

def touch.effs.go(+es: List<&2, A.Eff>, t: Tx, +pre: Maybe<&2, R.Ds>, +post: R.Ds) -> Tx:
  match es:
    case Nil{}:
      t
    case Con{+e, +rest}:
      touch.effs.go(rest, touch.eff(e, t, pre, post), pre, post)

def touch.effs.if(on: Bool, t: Tx, +es: List<&2, A.Eff>, +pre: Maybe<&2, R.Ds>, +post: R.Ds) -> Tx:
  match on:
    case False{}:
      t
    case True{}:
      touch.effs.go(es, t, pre, post)

# the touches of a command's effects es, with the databases before it
# (pre; none: each key a DEL deleted was there) and after it (post)
def touch.effs(t: Tx, +es: List<&2, A.Eff>, +pre: Maybe<&2, R.Ds>, +post: R.Ds) -> Tx:
  +x = t
  touch.effs.if(tx.on(x), x, es, pre, post)

# and of its effects as entries of the file
def touch.ent(+x: A.Ent, t: Tx, +pre: Maybe<&2, R.Ds>, +post: R.Ds) -> Tx:
  match x:
    case A.EOne{+e}:
      touch.eff(e, t, pre, post)
    case A.ETx{+es}:
      touch.effs.go(es, t, pre, post)

def touch.ents.go(+xs: List<&2, A.Ent>, t: Tx, +pre: Maybe<&2, R.Ds>, +post: R.Ds) -> Tx:
  match xs:
    case Nil{}:
      t
    case Con{+x, +rest}:
      touch.ents.go(rest, touch.ent(x, t, pre, post), pre, post)

def touch.ents.if(on: Bool, t: Tx, +xs: List<&2, A.Ent>, +pre: Maybe<&2, R.Ds>, +post: R.Ds) -> Tx:
  match on:
    case False{}:
      t
    case True{}:
      touch.ents.go(xs, t, pre, post)

def touch.ents(t: Tx, +xs: List<&2, A.Ent>, +pre: Maybe<&2, R.Ds>, +post: R.Ds) -> Tx:
  +x = t
  touch.ents.if(tx.on(x), x, xs, pre, post)

# the keys a command's effects touch: all of them, but PFDEBUG's, which
# changes a value's encoding without signalModifiedKey
def touch.by(+c: R.Cmd, t: Tx, +xs: List<&2, A.Ent>, +pre: Maybe<&2, R.Ds>, +post: R.Ds) -> Tx:
  match c:
    case R.Upd{k, R.UHll{R.HDebug{s}}}:
      t
    case _:
      touch.ents(t, xs, pre, post)

# Tracking
# --------
# CLIENT TRACKING runs as Redis 7.0.15 runs it (tracking.c). The actor
# keeps the keys each tracking client read, whatever their database (the
# tracking table: a key and the ids of the clients that read it, as Redis
# keeps it); when a command changes one of them (the keys its effects
# change, as Touches finds them), each of those clients is sent an
# invalidation, and the key leaves the table. A client in BCAST mode
# hears instead of every key changed under its prefixes, at the end of
# the group (Redis's beforeSleep). An invalidation goes to the client
# itself when it speaks RESP3 (a push), or to the client it redirects to:
# as a push in RESP3, or as a message of the channel __redis__:invalidate
# to a client of RESP2 with a subscription, and to no one else. The
# client whose command runs gets its own after the command's reply (after
# EXEC's for a command EXEC runs, after its reply for a client served),
# as Redis keeps them for after the call. FLUSHDB and FLUSHALL send every
# tracking client a null and empty the table; the sweep of expired keys
# and eviction invalidate the keys they delete, as no client's. While a
# key is in the table, a batch that may write it runs the general way
# (it is a heeded key too: Heeded keys), and while some client is in
# BCAST mode, every batch does. A tracking client, and a client whose
# batch ran the general way while another redirects to it, wait for their
# socket and for pushes at once, as a client with a subscription does (A
# subscribed client), so that an invalidation goes out when it is made.
# A client that stops tracking, or goes, leaves its ids in the table, as
# Redis cleans them up lazily.

# a client's tracking: off, or on with the client its invalidations go to
# (redir; 0: itself), its mode (BCAST, OPTIN, OPTOUT, NOLOOP), whether
# CLIENT CACHING was given for its next command, whether its redirect was
# found gone (broken), and its prefixes (BCAST), in the order of their
# bytes
type Tk is Data:
  TkOff{}
  TkOn{redir: Nat, bcast: Bool, optin: Bool, optout: Bool, noloop: Bool, caching: Bool, broken: Bool, pfx: List<&2, String>}

# a key changed under a BCAST prefix since the end of the last group, and
# the client whose command changed it last (0: none, the server's own
# deletion)
type Bk is Data:
  Bk{key: String, by: Nat}

# a BCAST prefix: the clients that listen to it (their ids), and the keys
# changed under it (Bk), newest first, a key once for each change
# (bk.sorted puts them in the order of their bytes, each once, at the end
# of the group)
type Bc is Data:
  Bc{p: String, ids: List<&2, Nat>, keys: List<&2, Bk>}

# the tracking: the table (each key a tracking client read, with the ids
# of the clients that read it, newest first), how many keys and ids it
# holds, the tracking clients (their ids), the clients invalidations are
# redirected to (one id for each client that redirects), the BCAST
# prefixes in the order of their bytes, the invalidations of the client
# whose command runs, kept for after its reply (newest first), how many
# ticks in a row found the table over its limit (over: the effort of the
# next one), and the table's limit (max: tracking-table-max-keys, 0 for
# none) as the
# parameters held it after the last command that may have set it
# (bg.trk.max), so that a tick reads no parameter by its name. TrkOf, a
# tracking that holds a tracking, is never built: it makes Trk a node of
# its own, one word of the heeded keys' record.
type Trk is Data:
  TrkOn{tab: KV.Trie<List<&2, Nat>>, keys: Nat, items: Nat, ids: List<&2, Nat>, rds: List<&2, Nat>, pfx: List<&2, Bc>, pend: List<&2, R.Reply>, over: Nat, max: Nat}
  TrkOf{t: Trk}

def trk.new() -> Trk:
  TrkOn{KV.empty(List<&2, Nat>), 0n, 0n, Nil{}, Nil{}, Nil{}, Nil{}, 0n, 0n}

# the table, lent (Heeded keys: its keys are heeded keys)
def trk.tab(+t: Trk) -> KV.Trie<List<&2, Nat>>:
  match t:
    case TrkOn{+tab, keys, items, ids, rds, pfx, pend, over, mx}:
      tab
    case TrkOf{+x}:
      trk.tab(x)

# whether xs holds n
def ids.has(+n: Nat, +xs: List<&2, Nat>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Con{+x, +rest}:
      Bool.or(Nat.is_eq(x, n), ids.has(n, rest))

# xs without the first n
def ids.drop(+n: Nat, xs: List<&2, Nat>) -> List<&2, Nat>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{+x, +rest}:
      Bool.pick(List<&2, Nat>, Nat.is_eq(x, n), rest, x <> ids.drop(n, rest))

# An invalidation carries keys (an array of them), or the null of a
# FLUSHDB or FLUSHALL, in the protocol of the client that tracks (r3), as
# Redis takes it from that client before it follows the redirect.
type Pl is Data:
  PlKeys{ks: List<&2, String>}
  PlNull{r3: Bool}

def pl.keys.bytes(+ks: List<&2, String>) -> String:
  match ks:
    case Nil{}:
      ""
    case Con{+k, +rest}:
      "$" ++ Nat.show(String.length(k)) ++ "\r\n" ++ k ++ "\r\n" ++ pl.keys.bytes(rest)

def pl.bytes(+p: Pl) -> String:
  match p:
    case PlKeys{+ks}:
      "*" ++ Nat.show(List.length(&2, String, ks)) ++ "\r\n" ++ pl.keys.bytes(ks)
    case PlNull{+r3}:
      Bool.pick(String, r3, "_\r\n", "$-1\r\n")

def pl.bulks(+ks: List<&2, String>) -> List<&2, R.Reply>:
  match ks:
    case Nil{}:
      Nil{}
    case Con{+k, +rest}:
      R.RBulk{k} <> pl.bulks(rest)

def pl.reply(+p: Pl) -> R.Reply:
  match p:
    case PlKeys{+ks}:
      R.RArray{pl.bulks(ks)}
    case PlNull{r3}:
      R.RNull{}

# an invalidation's bytes to a client of RESP3 (a push), or of RESP2 (a
# message of __redis__:invalidate); and as a reply, among the replies of
# the client whose command runs
def inv.bytes(+r3: Bool, +p: Pl) -> String:
  Bool.pick(String, r3, ">2\r\n$10\r\ninvalidate\r\n", "*3\r\n$7\r\nmessage\r\n$20\r\n__redis__:invalidate\r\n") ++ pl.bytes(p)

def inv.reply(+r3: Bool, +p: Pl) -> R.Reply:
  Bool.pick(R.Reply, r3, R.RPush{[R.RBulk{"invalidate"}, pl.reply(p)]}, R.RArray{[R.RBulk{"message"}, R.RBulk{"__redis__:invalidate"}, pl.reply(p)]})

# the push that tells a client of RESP3 that the client of id, to which it
# redirects its invalidations, is gone
def broken.bytes(+id: Nat) -> String:
  ">2\r\n$21\r\ntracking-redir-broken\r\n:" ++ Nat.show(id) ++ "\r\n"

def broken.reply(+id: Nat) -> R.Reply:
  R.RPush{[R.RBulk{"tracking-redir-broken"}, R.RInt{R.IPos{id}}]}

def tk.on(+t: Tk) -> Bool:
  match t:
    case TkOff{}:
      False{}
    case TkOn{rd, b, i, o, l, c, br, p}:
      True{}

def tk.bcast(+t: Tk) -> Bool:
  match t:
    case TkOff{}:
      False{}
    case TkOn{rd, +b, i, o, l, c, br, p}:
      b

def tk.optin(+t: Tk) -> Bool:
  match t:
    case TkOff{}:
      False{}
    case TkOn{rd, b, +i, o, l, c, br, p}:
      i

def tk.optout(+t: Tk) -> Bool:
  match t:
    case TkOff{}:
      False{}
    case TkOn{rd, b, i, +o, l, c, br, p}:
      o

def tk.noloop(+t: Tk) -> Bool:
  match t:
    case TkOff{}:
      False{}
    case TkOn{rd, b, i, o, +l, c, br, p}:
      l

def tk.caching(+t: Tk) -> Bool:
  match t:
    case TkOff{}:
      False{}
    case TkOn{rd, b, i, o, l, +c, br, p}:
      c

def tk.redir(+t: Tk) -> Nat:
  match t:
    case TkOff{}:
      0n
    case TkOn{+rd, b, i, o, l, c, br, p}:
      rd

def tk.pfx(+t: Tk) -> List<&2, String>:
  match t:
    case TkOff{}:
      Nil{}
    case TkOn{rd, b, i, o, l, c, br, +p}:
      p

# whether a call's keys go to the table (trackingRememberKeys): a client
# in OPTIN mode only after CLIENT CACHING yes, in OPTOUT mode unless
# after CLIENT CACHING no, and no client in BCAST mode
def tk.reads(+t: Tk) -> Bool:
  match t:
    case TkOff{}:
      False{}
    case TkOn{rd, +b, +i, +o, l, +c, br, p}:
      Bool.and(Bool.not(b), Bool.not(Bool.or(Bool.and(i, Bool.not(c)), Bool.and(o, c))))

# whether a tracking client hears of a key in the table that changed (cur:
# whether its own command changed it): one not in BCAST mode, nor in
# NOLOOP mode for its own changes
def tk.hears(+t: Tk, +cur: Bool) -> Bool:
  match t:
    case TkOff{}:
      False{}
    case TkOn{rd, +b, i, o, +l, c, br, p}:
      Bool.and(Bool.not(b), Bool.not(Bool.and(l, cur)))

def tk.caching.set(+on: Bool, t: Tk) -> Tk:
  match t:
    case TkOff{}:
      TkOff{}
    case TkOn{rd, b, i, o, l, c, br, p}:
      TkOn{rd, b, i, o, l, on, br, p}

def tk.broken.set(t: Tk) -> Tk:
  match t:
    case TkOff{}:
      TkOff{}
    case TkOn{rd, b, i, o, l, c, br, p}:
      TkOn{rd, b, i, o, l, c, True{}, p}

# CLIENT TRACKINGINFO's flags, redirect and prefixes
def tk.flags(+t: Tk) -> List<&2, R.Reply>:
  match t:
    case TkOff{}:
      [R.RBulk{"off"}]
    case TkOn{rd, +b, +i, +o, +l, +c, +br, p}:
      R.RBulk{"on"} <> List.append(&2, R.Reply, Bool.pick(List<&2, R.Reply>, b, [R.RBulk{"bcast"}], Nil{}),
        List.append(&2, R.Reply, Bool.pick(List<&2, R.Reply>, i, Bool.pick(List<&2, R.Reply>, c, [R.RBulk{"optin"}, R.RBulk{"caching-yes"}], [R.RBulk{"optin"}]), Nil{}),
        List.append(&2, R.Reply, Bool.pick(List<&2, R.Reply>, o, Bool.pick(List<&2, R.Reply>, c, [R.RBulk{"optout"}, R.RBulk{"caching-no"}], [R.RBulk{"optout"}]), Nil{}),
        List.append(&2, R.Reply, Bool.pick(List<&2, R.Reply>, l, [R.RBulk{"noloop"}], Nil{}),
          Bool.pick(List<&2, R.Reply>, br, [R.RBulk{"broken_redirect"}], Nil{})))))

def tk.info(+t: Tk) -> R.Reply:
  R.RMap{[R.RBulk{"flags"}, R.RSet{tk.flags(t)}, R.RBulk{"redirect"}, Bool.pick(R.Reply, tk.on(t), R.RInt{R.IPos{tk.redir(t)}}, R.RInt{R.INeg{0n}}), R.RBulk{"prefixes"}, R.RArray{pl.bulks(tk.pfx(t))}]}

# CLIENT LIST's flags of tracking (t, R, B) and its redirect (-1 when the
# client does not track)
def tk.line.flags(+t: Tk) -> String:
  match t:
    case TkOff{}:
      ""
    case TkOn{rd, +b, i, o, l, c, +br, p}:
      "t" ++ Bool.pick(String, br, "R", "") ++ Bool.pick(String, b, "B", "")

def tk.line.redir(+t: Tk) -> String:
  match t:
    case TkOff{}:
      "-1"
    case TkOn{+rd, b, i, o, l, c, br, p}:
      Nat.show(rd)

# Ps's bits of the tracking: 22 while some client tracks, the table holds
# keys (a batch that may write a key of the table runs the general way:
# Heeded keys) or invalidations wait for the reply of the command that
# made them, 21 while some client is in BCAST mode (every batch runs the
# general way)
def trk.bits(+t: Trk) -> U32:
  match t:
    case TrkOn{tab, +keys, items, +ids, rds, +pfx, +pend, over, mx}:
      U32.or(Bool.pick(U32, Bool.or(Bool.or(Nat.is_lt(0n, keys), Bool.not(List.is_empty(&2, Nat, ids))), Bool.not(List.is_empty(&2, R.Reply, pend))), 4194304, 0), Bool.pick(U32, List.is_empty(&2, Bc, pfx), 0, 2097152))
    case TrkOf{+x}:
      trk.bits(x)

# the prefix table without the client of id under p; a prefix no client
# listens to any more goes, its keys with it
def bc.drop(+p: String, +id: Nat, bs: List<&2, Bc>) -> List<&2, Bc>:
  match bs:
    case Nil{}:
      Nil{}
    case Con{Bc{+x, +ids, +keys}, +rest}:
      +left = ids.drop(id, ids)
      Bool.pick(List<&2, Bc>, String.eq(x, p), Bool.pick(List<&2, Bc>, List.is_empty(&2, Nat, left), rest, Bc{x, left, keys} <> rest), Bc{x, ids, keys} <> bc.drop(p, id, rest))

def bc.drop.all(+gs: List<&2, String>, +id: Nat, bs: List<&2, Bc>) -> List<&2, Bc>:
  match gs:
    case Nil{}:
      bs
    case Con{+p, +rest}:
      bc.drop.all(rest, id, bc.drop(p, id, bs))

# the redirect of a client dropped (0: none)
def rds.drop(+rd: Nat, xs: List<&2, Nat>) -> List<&2, Nat>:
  match rd:
    case 0n:
      xs
    case _:
      ids.drop(rd, xs)

def rds.add(+rd: Nat, xs: List<&2, Nat>) -> List<&2, Nat>:
  match rd:
    case 0n:
      xs
    case _:
      rd <> xs

# the client of id stops tracking (CLIENT TRACKING off, RESET, its end):
# out of its prefixes, the tracking clients and the redirects; its ids
# stay in the table (disableTracking)
def trk.off(+id: Nat, +cur: Tk, t: Trk) -> Trk:
  match cur t:
    case TkOn{+rd, b, i, o, l, c, br, +p} TrkOn{tab, keys, items, ids, rds, pfx, pend, over, mx}:
      TrkOn{tab, keys, items, ids.drop(id, ids), rds.drop(rd, rds), bc.drop.all(p, id, pfx), pend, over, mx}
    case TkOn{rd, b, i, o, l, c, br, p} TrkOf{x}:
      trk.off(id, cur, x)
    case TkOff{} t0:
      t0

# Clients
# -------
# Every client the server holds, by id, from its connection's start
# (Join, which the actor answers with the client's state as it comes:
# authenticated when there is no password then, as Redis's createClient
# sets it, S.conn_join) to its end (Left): the channel its answers come
# back on, its socket's fd, its peer's address and its own (TCP.name),
# when it came (ms), its name and database as the last command that set
# them left them (CLIENT SETNAME, HELLO, SELECT, RESET: the actor writes
# them as such a command runs), whether CLIENT NO-EVICT is on, and its
# tracking (CLIENT TRACKING: Tracking, above). Its
# last command and the time of its last batch are its channel's mark
# (Chan.mark), which the actor sets with each batch: a store, where a
# write to the registry would cost every request a walk of a trie.
# CLIENT KILL takes a client out of the registry at once (killed) and
# shuts its socket down at the end of the group (kills: their fds), so
# its connection finds its end wherever it waits; until the connection
# tells the actor it ended (Left), a batch of its that comes is answered
# Bye and not run, as Redis frees a client with what it had read. A
# connection closes its socket only once the actor answered its Left
# (conn_end), so an fd in the registry or in kills is still its client's
# open socket. The monitors (MONITOR, below) are a list, in the order
# they came, as Redis keeps them; the registry also keeps the pause of
# CLIENT PAUSE (The pause, below), and a SHUTDOWN asked for in the group
# (down: SHUTDOWN, below).
type Cl is Data:
  Cl{id: Nat, back: Chan(Ans), fd: U32, addr: String, laddr: String, since: Nat, name: String, db: Nat, noev: Bool, r3: Bool, tk: Tk}

# CLIENT PAUSE's pause (The pause, below): none, or one of the commands
# that write (all: of every command) until a time (ms since 1970)
type Pz is Data:
  PzOff{}
  PzOn{all: Bool, end: Nat}

# a monitor: its client's id, the channel its lines go back on, and
# whether its replies were on as its last batch ended (on: not held back
# by CLIENT REPLY OFF, nor by a SKIP of its next command), as Redis writes
# a line to a monitor as it writes any reply
type Mon is Data:
  Mon{id: Nat, back: Chan(Ans), on: Bool}

# the keys that clients heed, the earliest time a client's wait ends, or
# one before it (0: no client's wait ends), the clients that started to
# heed keys since the set was made (adds), and how many heeded keys then
# (base): Heeded keys; and the tracking (Tracking, above), whose table's
# keys are heeded keys too (the checks look in the table itself)
type Hd is Data:
  Hd{keys: KV.Trie<Nat>, soon: Nat, adds: Nat, base: Nat, trk: Trk}

type Cls is Data:
  Cls{tab: KV.Trie<Cl>, killed: List<&2, Nat>, kills: List<&2, U32>, mons: List<&2, Mon>, pause: Pz, down: Nat, heed: Hd}

def cls.new() -> Cls:
  Cls{KV.empty(Cl), Nil{}, Nil{}, Nil{}, PzOff{}, 0n, Hd{KV.empty(Nat), 0n, 0n, 0n, trk.new()}}

# the bits of Ps's ev that keep the fast way off while a killed client's
# connection has not ended (the 31st), a client monitors (the 30th),
# clients are paused (the 25th), or a SHUTDOWN stops the server (the
# 24th) or a save is asked for (the 23rd), and the tracking's (the 22nd
# and the 21st: trk.bits): no class of keyspace event has them
def kill.bit(+kd: List<&2, Nat>) -> U32:
  match kd:
    case Nil{}:
      0
    case Con{i, rest}:
      2147483648

def mon.bit(+ms: List<&2, Mon>) -> U32:
  match ms:
    case Nil{}:
      0
    case Con{m, rest}:
      1073741824

def pz.bit(+p: Pz) -> U32:
  match p:
    case PzOff{}:
      0
    case PzOn{all, end}:
      33554432

def dn.bit(+dn: Nat) -> U32:
  match dn:
    case 0n:
      0
    case 1n:
      8388608
    case _:
      16777216

def cls.bit(+cs: Cls) -> U32:
  match cs:
    case Cls{tab, +kd, ks, +ms, +pz, +dn, Hd{hk, sn, ad, bs, +tr}}:
      U32.or(U32.or(U32.or(U32.or(kill.bit(kd), mon.bit(ms)), pz.bit(pz)), dn.bit(dn)), trk.bits(tr))

def cls.get(+id: Nat, +cs: Cls) -> Maybe<&2, Cl>:
  match cs:
    case Cls{+tab, kd, ks, ms, pz, dn, hd}:
      KV.get(Cl, tab, Nat.show(id))

def cls.put(+id: Nat, c: Cl, cs: Cls) -> Cls:
  match cs:
    case Cls{tab, kd, ks, ms, pz, dn, hd}:
      Cls{KV.set(Cl, tab, Nat.show(id), c), kd, ks, ms, pz, dn, hd}

def cls.del(+id: Nat, cs: Cls) -> Cls:
  match cs:
    case Cls{tab, kd, ks, ms, pz, dn, hd}:
      Cls{KV.del(Cl, tab, Nat.show(id)), kd, ks, ms, pz, dn, hd}

# whether xs holds n
def nats.has(+n: Nat, +xs: List<&2, Nat>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Con{+x, rest}:
      Bool.or(Nat.is_eq(x, n), nats.has(n, rest))

# xs without n
def nats.drop(+n: Nat, xs: List<&2, Nat>) -> List<&2, Nat>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{+x, rest}:
      +r = nats.drop(n, rest)
      Bool.pick(List<&2, Nat>, Nat.is_eq(x, n), r, x <> r)

# whether the client of id was killed and its connection has not ended
def cls.killed(+id: Nat, +cs: Cls) -> Bool:
  match cs:
    case Cls{tab, +kd, ks, ms, pz, dn, hd}:
      nats.has(id, kd)

# a client's tracking (Tracking), read and set
def cl.tk(+c: Cl) -> Tk:
  match c:
    case Cl{id, back, fd, addr, laddr, since, name, db, noev, r3, +kt}:
      kt

def cl.tk.set(kt: Tk, c: Cl) -> Cl:
  match c:
    case Cl{id, back, fd, addr, laddr, since, name, db, noev, r3, t0}:
      Cl{id, back, fd, addr, laddr, since, name, db, noev, r3, kt}

def cl.tk.of(+m: Maybe<&2, Cl>) -> Tk:
  match m:
    case Some{+c}:
      cl.tk(c)
    case None{}:
      TkOff{}

# the tracking of the client of id (off when there is none)
def cls.tk(+id: Nat, +cs: Cls) -> Tk:
  cl.tk.of(cls.get(id, cs))

def cls.tk.put(+id: Nat, kt: Tk, m: Maybe<&2, Cl>, cs: Cls) -> Cls:
  match m:
    case Some{c}:
      cls.put(id, cl.tk.set(kt, c), cs)
    case None{}:
      cs

# the client of id with its tracking set to tk
def cls.tk.set(+id: Nat, kt: Tk, cs: Cls) -> Cls:
  +c = cs
  cls.tk.put(id, kt, cls.get(id, c), c)

# the client of id's connection ended: out of the registry, and of the
# killed, its tracking off (Tracking: its ids stay in the table)
def cls.left.of(+id: Nat, +kt: Tk, cs: Cls) -> Cls:
  match cs:
    case Cls{tab, kd, ks, ms, pz, dn, Hd{hk, sn, ad, bs, tr}}:
      Cls{KV.del(Cl, tab, Nat.show(id)), nats.drop(id, kd), ks, ms, pz, dn, Hd{hk, sn, ad, bs, trk.off(id, kt, tr)}}

def cls.left(+id: Nat, cs: Cls) -> Cls:
  +c = cs
  cls.left.of(id, cls.tk(id, c), c)

# the fds to shut down taken (at the end of the group)
def cls.kills(cs: Cls) -> List<&2, U32> & Cls:
  match cs:
    case Cls{tab, kd, ks, ms, pz, dn, hd}:
      (ks, Cls{tab, kd, Nil{}, ms, pz, dn, hd})

# a client's name, database and protocol set from its connection
def cl.conn(+cn: S.Conn, c: Cl) -> Cl:
  match c:
    case Cl{id, back, fd, addr, laddr, since, name, db, noev, r3, kt}:
      Cl{id, back, fd, addr, laddr, since, S.conn.name(cn), S.conn.db(cn), noev, S.conn.r3(cn), kt}

def cl.noev(on: Bool, c: Cl) -> Cl:
  match c:
    case Cl{id, back, fd, addr, laddr, since, name, db, noev, r3, kt}:
      Cl{id, back, fd, addr, laddr, since, name, db, on, r3, kt}

def cls.with.if(+id: Nat, m: Maybe<&2, Cl>, +cn: S.Conn, cs: Cls) -> Cls:
  match m:
    case Some{c}:
      cls.put(id, cl.conn(cn, c), cs)
    case None{}:
      cs

# the registry with the client's name, database and protocol as its
# connection has them
def cls.with(+cn: S.Conn, cs: Cls) -> Cls:
  +id = S.conn.id(cn)
  +c = cs
  cls.with.if(id, cls.get(id, c), cn, c)

def cls.noev.if(+id: Nat, on: Bool, m: Maybe<&2, Cl>, cs: Cls) -> Cls:
  match m:
    case Some{c}:
      cls.put(id, cl.noev(on, c), cs)
    case None{}:
      cs

def cls.noev(+id: Nat, on: Bool, cs: Cls) -> Cls:
  +c = cs
  cls.noev.if(id, on, cls.get(id, c), c)

# whether the client of id monitors
def mons.has(+id: Nat, +ms: List<&2, Mon>) -> Bool:
  match ms:
    case Nil{}:
      False{}
    case Con{Mon{+i, b, o}, +rest}:
      Bool.or(Nat.is_eq(i, id), mons.has(id, rest))

# the monitors but the client of id
def mons.drop(+id: Nat, ms: List<&2, Mon>) -> List<&2, Mon>:
  match ms:
    case Nil{}:
      Nil{}
    case Con{Mon{+i, b, o}, rest}:
      +r = mons.drop(id, rest)
      Bool.pick(List<&2, Mon>, Nat.is_eq(i, id), r, Mon{i, b, o} <> r)

# the monitor of id with its replies on or not, as its batch left them
def mons.mute(+id: Nat, +on: Bool, ms: List<&2, Mon>) -> List<&2, Mon>:
  match ms:
    case Nil{}:
      Nil{}
    case Con{Mon{+i, b, +o}, rest}:
      Mon{i, b, Bool.pick(Bool, Nat.is_eq(i, id), on, o)} <> mons.mute(id, on, rest)

# a line (out, its bytes) pushed to each monitor whose replies are on,
# but the client of id, whose own line goes with its replies
def mons.push1(go: Bool, +b: Chan(Ans), +out: String, px: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>) -> List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>:
  match go:
    case True{}:
      (b, Push{out}) <> px
    case False{}:
      px

def mons.push(+id: Nat, +out: String, +ms: List<&2, Mon>, px: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>) -> List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>:
  match ms:
    case Nil{}:
      px
    case Con{Mon{+i, +b, +o}, +rest}:
      mons.push(id, out, rest, mons.push1(Bool.and(o, Bool.not(Nat.is_eq(i, id))), b, out, px))

# the client of id no monitor (RESET, its end, CLIENT KILL)
def cls.unmon(+id: Nat, cs: Cls) -> Cls:
  match cs:
    case Cls{tab, kd, ks, ms, pz, dn, hd}:
      Cls{tab, kd, ks, mons.drop(id, ms), pz, dn, hd}

# Pub/Sub
# -------
# SUBSCRIBE, PSUBSCRIBE, SSUBSCRIBE, their UNSUBSCRIBEs, PUBLISH, SPUBLISH
# and PUBSUB run here as Redis 7.0.15 runs them (pubsub.c); a session
# keeps no subscription (session.bend, Pub/Sub). The actor keeps the
# subscribers of each channel and shard channel, in the order they came,
# those of each pattern (the patterns in the order they came: Redis's in
# the order of a hash table), and each client's channels, patterns and
# shard channels (Mine), in the order they came: UNSUBSCRIBE of all goes
# in that order, where Redis's goes in the order of a hash table. A
# message goes to the subscribers of its channel, then to those of each
# pattern it matches, as a push (Push) on the channel each one's answers
# come back on, which its connection writes out while it waits for its
# socket (A subscribed client, below); the pushes of a batch go out
# before its answer. Redis sends the replies of SUBSCRIBE and its kin even
# to a client whose replies are held back (CLIENT REPLY OFF or SKIP), and
# so does the actor. A client with a subscription runs (P|S)SUBSCRIBE,
# (P|S)UNSUBSCRIBE, PING (answered [pong, its argument]), QUIT and RESET
# alone, as a client of RESP2 does in Redis: any other command is
# refused, once the checks of its name and of the number of its
# arguments pass, as processCommand refuses it. RESET and the
# connection's end drop the client's subscriptions.

# a subscriber: its client's id, the channel its answers go back on, and
# whether it spoke RESP3 when it subscribed (its messages are pushes)
type Sub is Data:
  Sub{id: Nat, back: Chan(Ans), r3: Bool}

# a pattern and its subscribers
type Pat is Data:
  Pat{pat: String, subs: List<&2, Sub>}

# a client's channels, patterns and shard channels
type Mine is Data:
  Mine{chans: List<&2, String>, pats: List<&2, String>, shard: List<&2, String>}

# the subscriptions: none, or the subscribers of each channel, of each
# pattern and of each shard channel, each client's subscriptions (by its
# id), and how many clients have one
type Reg is Data:
  RegNone{}
  RegOn{chans: KV.Trie<List<&2, Sub>>, pats: List<&2, Pat>, shard: KV.Trie<List<&2, Sub>>, cl: KV.Trie<Mine>, n: Nat}

# Pub/Sub's state: the subscriptions, the classes of keyspace events the
# subscribers may hear (0 while there are none to send: Keyspace
# notifications), the pushes of the batch so far, newest first, and those
# to the client whose command runs (own: a RESP3 client with a
# subscription that publishes to itself, or hears its own keyspace
# events), which go among its replies, before its command's, as Redis
# writes them to its buffer as the command runs. PsOf,
# a state that holds a state, is never built: it makes Ps a type that
# holds itself, which the compiler makes a node of its own, so that it
# travels as one word, as the clients that wait and the transactions do
# (Blocked clients); flat, it would be eight, which every batch's state
# would carry.
type Ps is Data:
  Ps{reg: Reg, ev: U32, px: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, cs: Cls, own: List<&2, R.Reply>}
  PsOf{p: Ps}

def ps.new() -> Ps:
  Ps{RegNone{}, 0, Nil{}, cls.new(), Nil{}}

# whether the fast way may run a batch: no keyspace event is to be sent,
# no client killed, no monitor, the group not past maxmemory (ev but its
# bits 28, maxmemory set, 27, an LFU policy, and 26, an eviction to go
# on with: mem.bits)
def ps.calm(+pb: Ps) -> Bool:
  match pb:
    case Ps{reg, +ev, px, cs, own}:
      U32.is_eq(U32.and(ev, 3825205247), 0)
    case PsOf{+p}:
      ps.calm(p)

# how a batch of a client with no subscription may run (group_job): 0 as
# ps.calm lets it; 1 the fast way only when it writes no heeded key, while
# the tracking has work but no client is in BCAST mode (Ps's bit 22 alone:
# the keys of the tracking table are heeded keys, Tracking); 2 the
# general way
def ps.gate(+pb: Ps) -> Nat:
  match pb:
    case Ps{reg, +ev, px, cs, own}:
      Bool.pick(Nat, U32.is_eq(U32.and(ev, 3821010943), 0), Bool.pick(Nat, U32.is_eq(U32.and(ev, 4194304), 0), 0n, 1n), 2n)
    case PsOf{+p}:
      ps.gate(p)

# Heeded keys
# -----------
# The keys that clients heed: those a client waits on (Blocked clients)
# or watches (Transactions), in any database, kept with the registry of
# the clients (heed). While some client waits or watches, a batch of
# database commands runs the fast way when its client is in no MULTI and
# none of its commands may write a heeded key, and the clients that wait
# and watch stay as they were: a command leaves as it was the entry of
# each key its writes do not name (LAWS.bend, frame), and the keys a
# command of the database touches for the clients that watch are keys
# its writes name (Touches), so no client that waits finds what it
# waits for, and no watched key is touched. Redis looks a key up in
# blocking_keys and watched_keys as a command writes it. The general way
# serves the clients that wait only after a command that may make one
# ready (bg.stir). A key goes in as a client starts to wait on it or
# watches it, and a tick makes the set anew from the clients that wait
# and watch then, when one that heeded keys stopped since it was made
# (heed.tick: a count, which walks the chains without a lookup): until
# it does, a key that no client heeds any more still sends the batches
# that write it the general way. With the keys goes the earliest time a
# client's wait ends (soon): at the end of a group the actor walks the
# chain of the clients that wait, for those whose time is up, only once
# that time has passed (grp.end.due), where it walked the chain at the
# end of every group; Redis keeps the clients that wait in a radix tree
# by their timeouts.

# The checks below only read what they are lent, and each is a tight
# loop: a walk of a list tells the next step whether an item so far was
# one it looks for (hit). A Cmd is laid out in words that hold a string
# in one constructor and a number in another, and one read out of a
# list is unpacked with a reference count on each of its strings,
# whatever reads it (FINDINGS 7): the batch then keeps its keys and
# values in the database with counts, a word more to read for each. So
# a batch's commands are read (heed.cmds) only when the hashes of its
# requests cannot tell (heed.quick, below).

# whether h or the tracking table tb holds k (KV.code.at: 0 when it does
# not), or one of ks, or the key of one of ps
def heed.has(+h: KV.Trie<Nat>, +tb: KV.Trie<List<&2, Nat>>, +k: String) -> Bool:
  +x = KV.hash(k)
  Bool.not(Bool.and(Nat.is_eq(KV.code.at(Nat, h, k, x), 0n), Nat.is_eq(KV.code.at(List<&2, Nat>, tb, k, x), 0n)))

def heed.keys(+ks: List<&2, String>, +h: KV.Trie<Nat>, +tb: KV.Trie<List<&2, Nat>>, hit: Bool) -> Bool:
  match ks:
    case Nil{}:
      hit
    case Con{+k, +rest}:
      heed.keys(rest, h, tb, Bool.or(hit, heed.has(h, tb, k)))

def heed.pairs(+ps: List<&2, R.KVPair>, +h: KV.Trie<Nat>, +tb: KV.Trie<List<&2, Nat>>, hit: Bool) -> Bool:
  match ps:
    case Nil{}:
      hit
    case Con{R.KP{+k, v}, +rest}:
      heed.pairs(rest, h, tb, Bool.or(hit, heed.has(h, tb, k)))

# whether a command may make a client that waits ready, or touch a
# watched key: one of the connection or of the server (SWAPDB, MOVE and
# COPY among them; a batch the fast way has none), or one of the
# database that may write a key of h, one that LAWS.bend's writes names
# (each key for FLUSHDB). A command of the database that writes must
# have its case here and there both.
def heed.cmd(+h: KV.Trie<Nat>, +tb: KV.Trie<List<&2, Nat>>, +c: R.Cmd) -> Bool:
  match c:
    case R.Set{+k, v}:
      heed.has(h, tb, k)
    case R.Del{+ks}:
      heed.keys(ks, h, tb, False{})
    case R.IncrBy{+k, by}:
      heed.has(h, tb, k)
    case R.MSet{+ps}:
      heed.pairs(ps, h, tb, False{})
    case R.FlushDb{}:
      True{}
    case R.Upd{+k, op}:
      heed.has(h, tb, k)
    case R.MSetNx{+ps}:
      heed.pairs(ps, h, tb, False{})
    case R.Rename{+s, +d, nx}:
      Bool.or(heed.has(h, tb, s), heed.has(h, tb, d))
    case R.BitOp{op, +d, srcs}:
      heed.has(h, tb, d)
    case R.LMove{+s, +d, e}:
      Bool.or(heed.has(h, tb, s), heed.has(h, tb, d))
    case R.LMPop{+ks, left, n}:
      heed.keys(ks, h, tb, False{})
    case R.SStore{op, +d, srcs}:
      heed.has(h, tb, d)
    case R.SMv{+s, +d, m}:
      Bool.or(heed.has(h, tb, s), heed.has(h, tb, d))
    case R.ZStore{op, +d, srcs}:
      heed.has(h, tb, d)
    case R.ZRangeStore{+d, s, q}:
      heed.has(h, tb, d)
    case R.ZMPop{+ks, max, n}:
      heed.keys(ks, h, tb, False{})
    case R.Own{o}:
      True{}
    case _:
      False{}

# heed.cmd of each command of cs, or hit
def heed.cmds(+cs: List<&2, R.Cmd>, +h: KV.Trie<Nat>, +tb: KV.Trie<List<&2, Nat>>, hit: Bool) -> Bool:
  match cs:
    case Nil{}:
      hit
    case Con{+c, +rest}:
      heed.cmds(rest, h, tb, Bool.or(hit, heed.cmd(h, tb, c)))

# Most batches need no command read: the hash of a request carries its
# call's code (redis.bend, Statistics), and the hashes of a call of GET,
# SET and INCR that runs carry the marks the parser writes for them (as
# the stats of a batch count them). GET writes nothing; SET and INCR
# write their key alone, their first argument, whose hash is the
# request's (resp.bend: req.hash, and the parser's ways for the three),
# so a heeded key they may write is in the bucket of that hash
# (KV.filled.at). A batch of these alone, none of whose writes has a
# heeded key in its bucket, goes the fast way unread (heed.quick); any
# other is read command by command (heed.cmds).

# whether a request may run the fast way unread: a GET, or a SET or INCR
# (sw) whose key's bucket holds no heeded key
def heed.quick.sw(sw: Bool, +h: KV.Trie<Nat>, +tb: KV.Trie<List<&2, Nat>>, +x: U32) -> Bool:
  match sw:
    case True{}:
      Bool.not(Bool.or(KV.filled.at(Nat, h, x), KV.filled.at(List<&2, Nat>, tb, x)))
    case False{}:
      False{}

def heed.quick.one(get: Bool, +h: KV.Trie<Nat>, +tb: KV.Trie<List<&2, Nat>>, +m: U32, +x: U32) -> Bool:
  match get:
    case True{}:
      True{}
    case False{}:
      heed.quick.sw(Bool.or(U32.is_eq(m, R.stat.mark.set()), U32.is_eq(m, R.stat.mark.incr())), h, tb, x)

# whether every request of hs may run the fast way unread, and ok
def heed.quick(+hs: List<&2, U32>, +h: KV.Trie<Nat>, +tb: KV.Trie<List<&2, Nat>>, ok: Bool) -> Bool:
  match hs:
    case Nil{}:
      ok
    case Con{+x, +rest}:
      +m = U32.and(x, 4293918720)
      heed.quick(rest, h, tb, Bool.and(ok, heed.quick.one(U32.is_eq(m, R.stat.mark.get()), h, tb, m, x)))

# whether a batch writes no heeded key: unread (heed.quick), or read
def heed.free.of(quick: Bool, +h: KV.Trie<Nat>, +tb: KV.Trie<List<&2, Nat>>, +cs: List<&2, R.Cmd>) -> Bool:
  match quick:
    case True{}:
      True{}
    case False{}:
      Bool.not(heed.cmds(cs, h, tb, False{}))

def ps.heed.free(+cs: List<&2, R.Cmd>, +hs: List<&2, U32>, +pb: Ps) -> Bool:
  match pb:
    case Ps{reg, ev, px, Cls{tab, kd, ks, ms, pz, dn, Hd{+hk, sn, ad, bs, +tr}}, own}:
      +tb = trk.tab(tr)
      heed.free.of(heed.quick(hs, hk, tb, True{}), hk, tb, cs)
    case PsOf{+p}:
      ps.heed.free(cs, hs, p)

# whether a batch of database commands may run the fast way while some
# client waits or watches (group_job): its client may run it so, is in
# no MULTI (looked for only while some client has a transaction or
# watches keys) and none of its commands may write a heeded key
def heed.ok.of(ready: Bool, +n: Nat, +t: Tx, +cs: List<&2, R.Cmd>, +hs: List<&2, U32>, +pb: Ps) -> Bool:
  match ready t:
    case False{} _:
      False{}
    case True{} TxNone{}:
      ps.heed.free(cs, hs, pb)
    case True{} t0:
      Bool.and(Bool.not(tx.in.multi(t0, n, False{})), ps.heed.free(cs, hs, pb))

def heed.ok(+cn: S.Conn, +srv: S.Srv, +t: Tx, +cs: List<&2, R.Cmd>, +hs: List<&2, U32>, +pb: Ps) -> Bool:
  heed.ok.of(S.ready(cn, srv), S.conn.id(cn), t, cs, hs, pb)

def ps.heed.stir(+c: R.Cmd, +pb: Ps) -> Bool:
  match pb:
    case Ps{reg, ev, px, Cls{tab, kd, ks, ms, pz, dn, Hd{+hk, sn, ad, bs, tr}}, own}:
      heed.cmd(hk, KV.empty(List<&2, Nat>), c)
    case PsOf{+p}:
      ps.heed.stir(c, p)

# h with the keys ks, with those the clients of ws wait on, and with
# those the clients of t watch
def heed.put(+ks: List<&2, String>, h: KV.Trie<Nat>) -> KV.Trie<Nat>:
  match ks:
    case Nil{}:
      h
    case Con{+k, +rest}:
      heed.put(rest, KV.set(Nat, h, k, 0n))

def heed.waits(+ws: Waits, h: KV.Trie<Nat>) -> KV.Trie<Nat>:
  match ws:
    case WaitNone{}:
      h
    case WaitOn{id, back, c0, c1, +b, argv, code, db, until, cmds, codes, av, +rest}:
      heed.waits(rest, heed.put(S.blk.keys(b), h))

def heed.wks(+ks: List<&2, Wk>, h: KV.Trie<Nat>) -> KV.Trie<Nat>:
  match ks:
    case Nil{}:
      h
    case Con{Wk{d, +k, old}, +rest}:
      heed.wks(rest, KV.set(Nat, h, k, 0n))

def heed.tx(+t: Tx, h: KV.Trie<Nat>) -> KV.Trie<Nat>:
  match t:
    case TxNone{}:
      h
    case TxOn{i, mu, bd, cs, qs, qc, qa, +wk, +r}:
      heed.tx(r, heed.wks(wk, h))

# the earlier of two ends of a wait (0: none), and the earliest of the
# clients of ws, s or earlier; whether the time of a client may be up at
# now (some end before now: waits.late)
def soon.min(+a: Nat, +b: Nat) -> Nat:
  Bool.pick(Nat, Bool.or(Nat.is_eq(a, 0n), Bool.and(Nat.is_lt(0n, b), Nat.is_lt(b, a))), b, a)

def waits.soon(+ws: Waits, +s: Nat) -> Nat:
  match ws:
    case WaitNone{}:
      s
    case WaitOn{id, back, c0, c1, b, argv, code, db, +until, cmds, codes, av, +rest}:
      waits.soon(rest, soon.min(s, until))

def waits.due(+now: Nat, +soon: Nat) -> Bool:
  Bool.and(Nat.is_lt(0n, soon), Nat.is_lt(soon, now))

def ps.soon(+pb: Ps) -> Nat:
  match pb:
    case Ps{reg, ev, px, Cls{tab, kd, ks, ms, pz, dn, Hd{hk, +sn, ad, bs, tr}}, own}:
      sn
    case PsOf{+p}:
      ps.soon(p)

# a client that starts to heed keys xs, its wait ending at until (0:
# never): the keys put in the set, the earliest end put anew, and the
# client counted among those that started to heed keys since the set was
# made
def ps.heed.add(+xs: List<&2, String>, +until: Nat, pb: Ps) -> Ps:
  match pb:
    case Ps{reg, ev, px, Cls{tab, kd, ks, ms, pz, dn, Hd{hk, +sn, ad, bs, tr}}, own}:
      Ps{reg, ev, px, Cls{tab, kd, ks, ms, pz, dn, Hd{heed.put(xs, hk), soon.min(sn, until), 1n+ad, bs, tr}}, own}
    case PsOf{p}:
      ps.heed.add(xs, until, p)

def ps.soon.set(+s: Nat, pb: Ps) -> Ps:
  match pb:
    case Ps{reg, ev, px, Cls{tab, kd, ks, ms, pz, dn, Hd{hk, sn, ad, bs, tr}}, own}:
      Ps{reg, ev, px, Cls{tab, kd, ks, ms, pz, dn, Hd{hk, s, ad, bs, tr}}, own}
    case PsOf{p}:
      ps.soon.set(s, p)

# how many clients heed keys: those that wait on keys (a pop; not one
# the pause holds back, nor WAIT's) and those that watch some
def blk.pops(+b: S.Blk) -> Bool:
  match b:
    case S.BlkPop{c, form, ms}:
      True{}
    case _:
      False{}

def heed.n.waits(+ws: Waits, +n: Nat) -> Nat:
  match ws:
    case WaitNone{}:
      n
    case WaitOn{id, back, c0, c1, +b, argv, code, db, until, cmds, codes, av, +rest}:
      heed.n.waits(rest, Nat.add(n, Bool.pick(Nat, blk.pops(b), 1n, 0n)))

def wks.some(+ks: List<&2, Wk>) -> Bool:
  match ks:
    case Nil{}:
      False{}
    case Con{w, rest}:
      True{}

def heed.n.tx(+t: Tx, +n: Nat) -> Nat:
  match t:
    case TxNone{}:
      n
    case TxOn{i, mu, bd, cs, qs, qc, qa, +wk, +r}:
      heed.n.tx(r, Nat.add(n, Bool.pick(Nat, wks.some(wk), 1n, 0n)))

# at a tick, the set made anew from the clients that wait and watch, but
# when as many heed keys as did when it was made, and as started to since
# (live: how many do): then no client that heeded keys stopped, and the
# set holds no key that none heeds (a client that started to heed keys
# while another stopped may leave its keys in it until a later tick). The
# tracking table's keys are not in it: the checks look in the table.
def heed.tick(same: Bool, +live: Nat, +ws: Waits, +t: Tx, hd: Hd) -> Hd:
  match same hd:
    case True{} h:
      h
    case False{} Hd{hk, sn, ad, bs, tr}:
      Hd{heed.tx(t, heed.waits(ws, KV.empty(Nat))), waits.soon(ws, 0n), 0n, live, tr}

def ps.heed.tick(+live: Nat, +ws: Waits, +t: Tx, pb: Ps) -> Ps:
  match pb:
    case Ps{reg, ev, px, Cls{tab, kd, ks, ms, pz, dn, Hd{hk, sn, +ad, +bs, tr}}, own}:
      Ps{reg, ev, px, Cls{tab, kd, ks, ms, pz, dn, heed.tick(Nat.is_eq(live, Nat.add(ad, bs)), live, ws, t, Hd{hk, sn, ad, bs, tr})}, own}
    case PsOf{p}:
      ps.heed.tick(live, ws, t, p)

# Each walk of a list below is told whether its first item is the one
# it looks for (hit), as the item before it is looked at.

# whether n is the first of xs
def names.first(+n: String, +xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Con{+x, rest}:
      String.eq(n, x)

# xs without n
def names.drop(+n: String, xs: List<&2, String>, hit: Bool) -> List<&2, String>:
  match xs hit:
    case Nil{} _:
      Nil{}
    case Con{x, rest} True{}:
      rest
    case Con{x, +rest} False{}:
      x <> names.drop(n, rest, names.first(n, rest))

# whether the client of id is the first of xs
def subs.first(+id: Nat, +xs: List<&2, Sub>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Con{Sub{+i, b, p}, rest}:
      Nat.is_eq(i, id)

# the subscribers but the client of id
def subs.drop(+id: Nat, xs: List<&2, Sub>, hit: Bool) -> List<&2, Sub>:
  match xs hit:
    case Nil{} _:
      Nil{}
    case Con{x, rest} True{}:
      rest
    case Con{x, +rest} False{}:
      x <> subs.drop(id, rest, subs.first(id, rest))

def subs.drop.of(+id: Nat, +xs: List<&2, Sub>) -> List<&2, Sub>:
  subs.drop(id, xs, subs.first(id, xs))

def subs.or(m: Maybe<&2, List<&2, Sub>>) -> List<&2, Sub>:
  match m:
    case Some{xs}:
      xs
    case None{}:
      Nil{}

# the subscribers of channel c
def chan.subs(+t: KV.Trie<List<&2, Sub>>, +c: String) -> List<&2, Sub>:
  subs.or(KV.get(List<&2, Sub>, t, c))

# a subscriber of channel c added after the others
def chan.add(t: KV.Trie<List<&2, Sub>>, +c: String, s: Sub) -> KV.Trie<List<&2, Sub>>:
  +t0 = t
  KV.set(List<&2, Sub>, t0, c, List.append(&2, Sub, chan.subs(t0, c), [s]))

# channel c's subscribers set, the channel gone with the last
def chan.put(t: KV.Trie<List<&2, Sub>>, +c: String, xs: List<&2, Sub>) -> KV.Trie<List<&2, Sub>>:
  match xs:
    case Nil{}:
      KV.del(List<&2, Sub>, t, c)
    case Con{x, rest}:
      KV.set(List<&2, Sub>, t, c, x <> rest)

# the client of id taken from channel c's subscribers
def chan.drop(t: KV.Trie<List<&2, Sub>>, +c: String, +id: Nat) -> KV.Trie<List<&2, Sub>>:
  +t0 = t
  chan.put(t0, c, subs.drop.of(id, chan.subs(t0, c)))

# whether pattern p is the first of xs
def pats.first(+p: String, +xs: List<&2, Pat>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Con{Pat{+q, subs}, rest}:
      String.eq(p, q)

# a subscriber of pattern p added after the others (the pattern after the
# others when it is new)
def pats.add(xs: List<&2, Pat>, +p: String, s: Sub, hit: Bool) -> List<&2, Pat>:
  match xs hit:
    case Nil{} _:
      [Pat{p, [s]}]
    case Con{Pat{q, subs}, rest} True{}:
      Pat{q, List.append(&2, Sub, subs, [s])} <> rest
    case Con{x, +rest} False{}:
      x <> pats.add(rest, p, s, pats.first(p, rest))

def pats.add.of(+xs: List<&2, Pat>, +p: String, s: Sub) -> List<&2, Pat>:
  pats.add(xs, p, s, pats.first(p, xs))

# the client of id taken from pattern p's subscribers, the pattern gone
# with the last
def pats.keep(q: String, subs: List<&2, Sub>, rest: List<&2, Pat>) -> List<&2, Pat>:
  match subs:
    case Nil{}:
      rest
    case Con{x, more}:
      Pat{q, x <> more} <> rest

def pats.drop(xs: List<&2, Pat>, +p: String, +id: Nat, hit: Bool) -> List<&2, Pat>:
  match xs hit:
    case Nil{} _:
      Nil{}
    case Con{Pat{q, subs}, rest} True{}:
      pats.keep(q, subs.drop.of(id, subs), rest)
    case Con{x, +rest} False{}:
      x <> pats.drop(rest, p, id, pats.first(p, rest))

def pats.drop.of(+xs: List<&2, Pat>, +p: String, +id: Nat) -> List<&2, Pat>:
  pats.drop(xs, p, id, pats.first(p, xs))

def mine.of(m: Maybe<&2, Mine>) -> Mine:
  match m:
    case Some{x}:
      x
    case None{}:
      Mine{Nil{}, Nil{}, Nil{}}

# the count the replies of SUBSCRIBE and its kin give: the channels and
# patterns (kinds 0 and 1), or the shard channels (kind 2)
def mine.count(+kind: Nat, +m: Mine) -> Nat:
  match kind m:
    case 2n Mine{c, p, +s}:
      List.length(&2, String, s)
    case _ Mine{+c, +p, s}:
      Nat.add(List.length(&2, String, c), List.length(&2, String, p))

def mine.total(+m: Mine) -> Nat:
  match m:
    case Mine{+c, +p, +s}:
      Nat.add(Nat.add(List.length(&2, String, c), List.length(&2, String, p)), List.length(&2, String, s))

# a client's names of a kind
def mine.names(+kind: Nat, +m: Mine) -> List<&2, String>:
  match kind m:
    case 0n Mine{+c, p, s}:
      c
    case 1n Mine{c, +p, s}:
      p
    case _ Mine{c, p, +s}:
      s

def mine.with(+kind: Nat, m: Mine, xs: List<&2, String>) -> Mine:
  match kind m:
    case 0n Mine{c, p, s}:
      Mine{xs, p, s}
    case 1n Mine{c, p, s}:
      Mine{c, xs, s}
    case _ Mine{c, p, s}:
      Mine{c, p, xs}

def reg.open(r: Reg) -> Reg:
  match r:
    case RegNone{}:
      RegOn{KV.empty(List<&2, Sub>), Nil{}, KV.empty(List<&2, Sub>), KV.empty(Mine), 0n}
    case RegOn{c, p, sh, cl, n}:
      RegOn{c, p, sh, cl, n}

# the subscriptions of the client of id
def reg.mine(+id: Nat, +r: Reg) -> Maybe<&2, Mine>:
  match r:
    case RegNone{}:
      None{}
    case RegOn{c, p, sh, +cl, n}:
      KV.get(Mine, cl, Nat.show(id))

# whether the client of id has a subscription
def ps.has(+id: Nat, +pb: Ps) -> Bool:
  match pb:
    case Ps{+reg, ev, px, cs, own}:
      Maybe.is_some(&2, Mine, reg.mine(id, reg))
    case PsOf{+p}:
      ps.has(id, p)

# a subscriber of name x of a kind added
def reg.add(+kind: Nat, +x: String, s: Sub, r: Reg) -> Reg:
  match kind r:
    case 0n RegOn{c, p, sh, cl, n}:
      RegOn{chan.add(c, x, s), p, sh, cl, n}
    case 1n RegOn{c, p, sh, cl, n}:
      RegOn{c, pats.add.of(p, x, s), sh, cl, n}
    case _ RegOn{c, p, sh, cl, n}:
      RegOn{c, p, chan.add(sh, x, s), cl, n}
    case _ RegNone{}:
      RegNone{}

# the client of id taken from name x's subscribers
def reg.del(+kind: Nat, +x: String, +id: Nat, r: Reg) -> Reg:
  match kind r:
    case 0n RegOn{c, p, sh, cl, n}:
      RegOn{chan.drop(c, x, id), p, sh, cl, n}
    case 1n RegOn{c, p, sh, cl, n}:
      RegOn{c, pats.drop.of(p, x, id), sh, cl, n}
    case _ RegOn{c, p, sh, cl, n}:
      RegOn{c, p, chan.drop(sh, x, id), cl, n}
    case _ RegNone{}:
      RegNone{}

# the subscriptions with no client left are none
def reg.close(r: Reg) -> Reg:
  match r:
    case RegOn{c, p, sh, cl, 0n}:
      RegNone{}
    case RegOn{c, p, sh, cl, 1n+n}:
      RegOn{c, p, sh, cl, 1n+n}
    case RegNone{}:
      RegNone{}

# the client's subscriptions put back (had: it had some before): kept
# while it has one, else dropped, and the subscriptions none with the
# last client
def reg.put.if(had: Bool, has: Bool, +id: Nat, m: Mine, r: Reg) -> Reg:
  match had has r:
    case True{} True{} RegOn{c, p, sh, cl, n}:
      RegOn{c, p, sh, KV.set(Mine, cl, Nat.show(id), m), n}
    case False{} True{} RegOn{c, p, sh, cl, n}:
      RegOn{c, p, sh, KV.set(Mine, cl, Nat.show(id), m), 1n+n}
    case True{} False{} RegOn{c, p, sh, cl, n}:
      reg.close(RegOn{c, p, sh, KV.del(Mine, cl, Nat.show(id)), Nat.sub(n, 1n)})
    case False{} False{} r0:
      reg.close(r0)
    case _ _ RegNone{}:
      RegNone{}

def reg.put(+id: Nat, had: Bool, m: Mine, r: Reg) -> Reg:
  +m0 = m
  reg.put.if(had, Nat.is_lt(0n, mine.total(m0)), id, m0, r)

# SUBSCRIBE and its kin of name x, when the client has none: its
# subscriptions and the registry after
def reg.sub1.if(had: Bool, +kind: Nat, +x: String, +id: Nat, +back: Chan(Ans), +r3: Bool, m: Mine, r: Reg) -> Mine & Reg:
  match had:
    case True{}:
      (m, r)
    case False{}:
      +m0 = m
      (mine.with(kind, m0, List.append(&2, String, mine.names(kind, m0), [x])), reg.add(kind, x, Sub{id, back, r3}, r))

def reg.sub1(+kind: Nat, +x: String, +id: Nat, +back: Chan(Ans), +r3: Bool, m: Mine, r: Reg) -> Mine & Reg:
  +m0 = m
  reg.sub1.if(S.pub.has(x, mine.names(kind, m0)), kind, x, id, back, r3, m0, r)

# UNSUBSCRIBE and its kin of name x, when the client has it
def reg.unsub1.if(had: Bool, +kind: Nat, +x: String, +id: Nat, m: Mine, r: Reg) -> Mine & Reg:
  match had:
    case False{}:
      (m, r)
    case True{}:
      +m0 = m
      +xs = mine.names(kind, m0)
      (mine.with(kind, m0, names.drop(x, xs, names.first(x, xs))), reg.del(kind, x, id, r))

def reg.unsub1(+kind: Nat, +x: String, +id: Nat, m: Mine, r: Reg) -> Mine & Reg:
  +m0 = m
  reg.unsub1.if(S.pub.has(x, mine.names(kind, m0)), kind, x, id, m0, r)

# the replies so far (newest first), with the client's subscriptions and
# the registry after them
type Run is Data:
  Run{acc: List<&2, R.Reply>, m: Mine, r: Reg}

# the reply of a name once it is done: the count after it
def run.note(+on: Bool, +kind: Nat, +x: String, acc: List<&2, R.Reply>, p: Mine & Reg) -> Run:
  (m, r) = p
  +m0 = m
  Run{S.pub.note(S.pub.word(on, kind), R.RBulk{x}, mine.count(kind, m0)) <> acc, m0, r}

# SUBSCRIBE (on) or UNSUBSCRIBE of a name
def reg.one(+on: Bool, +kind: Nat, +x: String, +id: Nat, +back: Chan(Ans), +r3: Bool, m: Mine, r: Reg) -> Mine & Reg:
  match on:
    case True{}:
      reg.sub1(kind, x, id, back, r3, m, r)
    case False{}:
      reg.unsub1(kind, x, id, m, r)

# SUBSCRIBE (on) or UNSUBSCRIBE of names, one at a time
def reg.each(+on: Bool, +kind: Nat, names: List<&2, String>, +id: Nat, +back: Chan(Ans), +r3: Bool, w: Run) -> Run:
  match names w:
    case Nil{} w0:
      w0
    case Con{+x, rest} Run{acc, m, r}:
      reg.each(on, kind, rest, id, back, r3, run.note(on, kind, x, acc, reg.one(on, kind, x, id, back, r3, m, r)))

# UNSUBSCRIBE and its kin of all the client's names of the kind: a reply
# with no name when it has none
def reg.all(xs: List<&2, String>, +kind: Nat, +id: Nat, +back: Chan(Ans), +r3: Bool, m: Mine, r: Reg) -> Run:
  match xs:
    case Nil{}:
      +m0 = m
      Run{[S.pub.note(S.pub.word(False{}, kind), R.RNull{}, mine.count(kind, m0))], m0, r}
    case Con{x, rest}:
      reg.each(False{}, kind, x <> rest, id, back, r3, Run{Nil{}, m, r})

def reg.run(+on: Bool, +kind: Nat, names: List<&2, String>, +id: Nat, +back: Chan(Ans), +r3: Bool, m: Mine, r: Reg) -> Run:
  match on names:
    case False{} Nil{}:
      +m0 = m
      reg.all(mine.names(kind, m0), kind, id, back, r3, m0, r)
    case _ ns:
      reg.each(on, kind, ns, id, back, r3, Run{Nil{}, m, r})

def ps.ran(+id: Nat, had: Bool, w: Run, ev: U32, px: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, cs: Cls, own: List<&2, R.Reply>) -> List<&2, R.Reply> & Ps:
  match w:
    case Run{acc, m, r}:
      (List.reverse(&2, R.Reply, acc), Ps{reg.put(id, had, m, r), ev, px, cs, own})

# SUBSCRIBE (on) or UNSUBSCRIBE of a kind for the client of id: its
# replies, in order, and Pub/Sub's state after it
def ps.sub(+id: Nat, +back: Chan(Ans), +r3: Bool, +on: Bool, +kind: Nat, names: List<&2, String>, pb: Ps) -> List<&2, R.Reply> & Ps:
  match pb:
    case Ps{reg, ev, px, cs, own}:
      +r = reg.open(reg)
      +m = reg.mine(id, r)
      ps.ran(id, Maybe.is_some(&2, Mine, m), reg.run(on, kind, names, id, back, r3, mine.of(m), r), ev, px, cs, own)
    case PsOf{p}:
      ps.sub(id, back, r3, on, kind, names, p)

# a client's names of a kind taken from their subscribers
def names.dels(+kind: Nat, xs: List<&2, String>, +id: Nat, r: Reg) -> Reg:
  match xs:
    case Nil{}:
      r
    case Con{+x, rest}:
      names.dels(kind, rest, id, reg.del(kind, x, id, r))

def ps.dropped(+id: Nat, m: Maybe<&2, Mine>, r: Reg, ev: U32, px: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, cs: Cls, own: List<&2, R.Reply>) -> Ps:
  match m:
    case None{}:
      Ps{r, ev, px, cs, own}
    case Some{Mine{c, p, s}}:
      Ps{reg.put(id, True{}, Mine{Nil{}, Nil{}, Nil{}}, names.dels(2n, s, id, names.dels(1n, p, id, names.dels(0n, c, id, r)))), ev, px, cs, own}

# every subscription of the client of id dropped, and the client no
# monitor (RESET, its end)
def ps.drop(+id: Nat, pb: Ps) -> Ps:
  match pb:
    case Ps{reg, ev, px, cs, own}:
      +r = reg
      ps.dropped(id, reg.mine(id, r), r, ev, px, cls.unmon(id, cs), own)
    case PsOf{p}:
      ps.drop(id, p)

# The registry of clients in Pub/Sub's state (Clients, above): a client
# joins, its connection ends, its name and database or NO-EVICT change,
# it is killed; the fds to shut down are taken at the end of the group.
def ps.join(+id: Nat, c: Cl, pb: Ps) -> Ps:
  match pb:
    case Ps{reg, ev, px, cs, own}:
      Ps{reg, ev, px, cls.put(id, c, cs), own}
    case PsOf{p}:
      ps.join(id, c, p)

def ps.left(+id: Nat, pb: Ps) -> Ps:
  match pb:
    case Ps{reg, ev, px, cs, own}:
      +c = cls.left(id, cs)
      Ps{reg, U32.or(U32.and(ev, 1067450367), cls.bit(c)), px, c, own}
    case PsOf{p}:
      ps.left(id, p)

# A client with a subscription that switched its protocol (HELLO, from
# RESP3: a client of RESP2 with one may not run it) has its subscriptions
# made again with the new one, the pushes of its messages as it speaks
# now: each of its names taken from it and given again (it comes last
# among a name's subscribers then, which no client sees)
def reg.renames(+kind: Nat, xs: List<&2, String>, +id: Nat, +back: Chan(Ans), +r3: Bool, r: Reg) -> Reg:
  match xs:
    case Nil{}:
      r
    case Con{+x, rest}:
      reg.renames(kind, rest, id, back, r3, reg.add(kind, x, Sub{id, back, r3}, reg.del(kind, x, id, r)))

def reg.reproto.of(m: Maybe<&2, Mine>, +id: Nat, +back: Chan(Ans), +r3: Bool, r: Reg) -> Reg:
  match m:
    case Some{Mine{c, p, sh}}:
      reg.renames(2n, sh, id, back, r3, reg.renames(1n, p, id, back, r3, reg.renames(0n, c, id, back, r3, r)))
    case None{}:
      r

def reg.reproto.if(ch: Bool, +id: Nat, +back: Chan(Ans), +r3: Bool, r: Reg) -> Reg:
  match ch:
    case True{}:
      +r0 = r
      reg.reproto.of(reg.mine(id, r0), id, back, r3, r0)
    case False{}:
      r

def ps.reproto(+cn: S.Conn, m: Maybe<&2, Cl>, r: Reg) -> Reg:
  match m:
    case Some{Cl{id, +back, fd, addr, laddr, since, name, db, noev, +r3, kt}}:
      +now = S.conn.r3(cn)
      reg.reproto.if(Bool.xor(r3, now), S.conn.id(cn), back, now, r)
    case None{}:
      r

def ps.conn(+cn: S.Conn, pb: Ps) -> Ps:
  match pb:
    case Ps{reg, ev, px, +cs, own}:
      Ps{ps.reproto(cn, cls.get(S.conn.id(cn), cs), reg), ev, px, cls.with(cn, cs), own}
    case PsOf{p}:
      ps.conn(cn, p)

def ps.noev(+id: Nat, on: Bool, pb: Ps) -> Ps:
  match pb:
    case Ps{reg, ev, px, cs, own}:
      Ps{reg, ev, px, cls.noev(id, on, cs), own}
    case PsOf{p}:
      ps.noev(id, on, p)

def ps.cls(+pb: Ps) -> Cls:
  match pb:
    case Ps{reg, ev, px, +cs, own}:
      cs
    case PsOf{+p}:
      ps.cls(p)

# The monitors in Pub/Sub's state (MONITOR, below): whether some client
# monitors, whether the client of id does, the client of id made one
# (its replies on until its batch ends), its replies on or off as its
# batch left them, and a line to the others
def ps.mon.any(+pb: Ps) -> Bool:
  match pb:
    case Ps{reg, ev, px, Cls{tab, kd, ks, +ms, pz, dn, hd}, own}:
      Bool.not(U32.is_eq(mon.bit(ms), 0))
    case PsOf{+p}:
      ps.mon.any(p)

def ps.mon.is(+id: Nat, +pb: Ps) -> Bool:
  match pb:
    case Ps{reg, ev, px, Cls{tab, kd, ks, +ms, pz, dn, hd}, own}:
      mons.has(id, ms)
    case PsOf{+p}:
      ps.mon.is(id, p)

def ps.mon.add(+id: Nat, +back: Chan(Ans), pb: Ps) -> Ps:
  match pb:
    case Ps{reg, ev, px, Cls{tab, kd, ks, ms, pz, dn, hd}, own}:
      Ps{reg, ev, px, Cls{tab, kd, ks, List.append(&2, Mon, ms, [Mon{id, back, True{}}]), pz, dn, hd}, own}
    case PsOf{p}:
      ps.mon.add(id, back, p)

def ps.mon.mute(+id: Nat, +on: Bool, pb: Ps) -> Ps:
  match pb:
    case Ps{reg, ev, px, Cls{tab, kd, ks, ms, pz, dn, hd}, own}:
      Ps{reg, ev, px, Cls{tab, kd, ks, mons.mute(id, on, ms), pz, dn, hd}, own}
    case PsOf{p}:
      ps.mon.mute(id, on, p)

def ps.mon.push(+id: Nat, +out: String, pb: Ps) -> Ps:
  match pb:
    case Ps{reg, ev, px, Cls{tab, kd, ks, +ms, pz, dn, hd}, own}:
      Ps{reg, ev, mons.push(id, out, ms, px), Cls{tab, kd, ks, ms, pz, dn, hd}, own}
    case PsOf{p}:
      ps.mon.push(id, out, p)

# the address of the client of id, as a line shows it
def cl.addr.or(m: Maybe<&2, Cl>) -> String:
  match m:
    case Some{Cl{id, back, fd, addr, laddr, since, name, db, noev, r3, kt}}:
      addr
    case None{}:
      "?:0"

def ps.addr(+id: Nat, +pb: Ps) -> String:
  match pb:
    case Ps{reg, ev, px, Cls{+tab, kd, ks, ms, pz, dn, hd}, own}:
      cl.addr.or(KV.get(Cl, tab, Nat.show(id)))
    case PsOf{+p}:
      ps.addr(id, p)

# the name of the client of id (CLIENT SETNAME's), "" for none
def cl.name.or(m: Maybe<&2, Cl>) -> String:
  match m:
    case Some{Cl{id, back, fd, addr, laddr, since, name, db, noev, r3, kt}}:
      name
    case None{}:
      ""

def ps.name(+id: Nat, +pb: Ps) -> String:
  match pb:
    case Ps{reg, ev, px, Cls{+tab, kd, ks, ms, pz, dn, hd}, own}:
      cl.name.or(KV.get(Cl, tab, Nat.show(id)))
    case PsOf{+p}:
      ps.name(id, p)

# the client of id killed: out of the registry, its fd to be shut down,
# and the fast way off until its connection ends
def ps.kill(+id: Nat, +fd: U32, pb: Ps) -> Ps:
  match pb:
    case Ps{reg, ev, px, Cls{tab, kd, ks, ms, pz, dn, hd}, own}:
      Ps{reg, U32.or(ev, 2147483648), px, Cls{KV.del(Cl, tab, Nat.show(id)), id <> kd, fd <> ks, ms, pz, dn, hd}, own}
    case PsOf{p}:
      ps.kill(id, fd, p)

def ps.kills.of(q: List<&2, U32> & Cls, reg: Reg, ev: U32, px: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, own: List<&2, R.Reply>) -> List<&2, U32> & Ps:
  (ks, cs) = q
  (ks, Ps{reg, ev, px, cs, own})

def ps.kills(pb: Ps) -> List<&2, U32> & Ps:
  match pb:
    case Ps{reg, ev, px, cs, own}:
      ps.kills.of(cls.kills(cs), reg, ev, px, own)
    case PsOf{p}:
      ps.kills(p)

# A message: what each subscriber of its channel gets (smessage for a
# shard channel), and what a pattern's does: a push, and its bytes in
# RESP2 (an array)
def pub.msg.r(shard: Bool, +c: String, +m: String) -> R.Reply:
  R.RPush{[R.RBulk{Bool.pick(String, shard, "smessage", "message")}, R.RBulk{c}, R.RBulk{m}]}

def pub.pmsg.r(+p: String, +c: String, +m: String) -> R.Reply:
  R.RPush{[R.RBulk{"pmessage"}, R.RBulk{p}, R.RBulk{c}, R.RBulk{m}]}

def pub.bytes(+r: R.Reply) -> String:
  P.encode(r)

# a message's bytes for a subscriber in RESP3 (r3: a push, its first byte
# > for the * of RESP2's array) or RESP2
def push.as(r3: Bool, +out: String) -> String:
  match r3:
    case True{}:
      ">" ++ String.slice(out, 1n, String.length(out))
    case False{}:
      out

# the receivers so far, the pushes, and those to the client of the
# command that runs (own)
type Sent is Data:
  Sent{k: Nat, px: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, own: List<&2, R.Reply>}

# a message (r, out its bytes in RESP2) pushed to each subscriber, before
# those so far; the one to the client of id me goes among its replies
def push.one(mine: Bool, +b: Chan(Ans), +r3: Bool, +r: R.Reply, +out: String, d: Sent) -> Sent:
  match mine d:
    case True{} Sent{k, px, own}:
      Sent{k, px, r <> own}
    case False{} Sent{k, px, own}:
      Sent{k, (b, Push{push.as(r3, out)}) <> px, own}

def push.all(subs: List<&2, Sub>, +r: R.Reply, +out: String, +me: Nat, d: Sent) -> Sent:
  match subs:
    case Nil{}:
      d
    case Con{Sub{+i, +b, +r3}, rest}:
      push.all(rest, r, out, me, push.one(Nat.is_eq(i, me), b, r3, r, out, d))

def sent.add(+subs: List<&2, Sub>, +r: R.Reply, +me: Nat, d: Sent) -> Sent:
  match d:
    case Sent{+k, px, own}:
      push.all(subs, r, pub.bytes(r), me, Sent{Nat.add(k, List.length(&2, Sub, subs)), px, own})

# the message sent to the subscribers of each pattern channel c matches
def pats.send.if(hit: Bool, +p: String, +subs: List<&2, Sub>, +c: String, +m: String, +me: Nat, d: Sent) -> Sent:
  match hit:
    case True{}:
      sent.add(subs, pub.pmsg.r(p, c, m), me, d)
    case False{}:
      d

def pats.send(xs: List<&2, Pat>, +c: String, +m: String, +me: Nat, d: Sent) -> Sent:
  match xs:
    case Nil{}:
      d
    case Con{Pat{+p, +subs}, rest}:
      pats.send(rest, c, m, me, pats.send.if(R.stringmatch(p, c, False{}), p, subs, c, m, me, d))

def ps.sent(d: Sent, reg: Reg, ev: U32, cs: Cls) -> Nat & Ps:
  match d:
    case Sent{k, px, own}:
      (k, Ps{reg, ev, px, cs, own})

# PUBLISH (or SPUBLISH: shard) of message m to channel c by the client of
# id me (0 for none: the server's own events): how many got it, and
# Pub/Sub's state with the pushes
def ps.publish(shard: Bool, +c: String, +m: String, +me: Nat, pb: Ps) -> Nat & Ps:
  match shard pb:
    case _ Ps{RegNone{}, ev, px, cs, own}:
      (0n, Ps{RegNone{}, ev, px, cs, own})
    case False{} Ps{RegOn{+ch, +p, sh, cl, n}, ev, px, cs, own}:
      ps.sent(pats.send(p, c, m, me, sent.add(chan.subs(ch, c), pub.msg.r(False{}, c, m), me, Sent{0n, px, own})), RegOn{ch, p, sh, cl, n}, ev, cs)
    case True{} Ps{RegOn{ch, p, +sh, cl, n}, ev, px, cs, own}:
      ps.sent(sent.add(chan.subs(sh, c), pub.msg.r(True{}, c, m), me, Sent{0n, px, own}), RegOn{ch, p, sh, cl, n}, ev, cs)
    case sh PsOf{p}:
      ps.publish(sh, c, m, me, p)

# the pushes to the client of the command that runs, taken out (newest
# first)
def ps.own.take(pb: Ps) -> List<&2, R.Reply> & Ps:
  match pb:
    case Ps{reg, ev, px, cs, own}:
      (own, Ps{reg, ev, px, cs, Nil{}})
    case PsOf{p}:
      ps.own.take(p)

# a command's replies (newest first) with the pushes to its own client
# before its reply (its one reply: the head)
def own.under(own: List<&2, R.Reply>, rs: List<&2, R.Reply>) -> List<&2, R.Reply>:
  match own rs:
    case Nil{} xs:
      xs
    case ys Con{h, t}:
      h <> List.append(&2, R.Reply, ys, t)
    case ys Nil{}:
      ys

# PUBSUB's CHANNELS (of a pattern, or all) and SHARDCHANNELS, NUMSUB and
# SHARDNUMSUB, NUMPAT
def chans.of(pat: Maybe<&2, String>, ks: List<&2, String>) -> List<&2, R.Reply>:
  match pat:
    case None{}:
      R.glob_go(True{}, "", ks)
    case Some{+p}:
      R.glob_go(False{}, p, ks)

def numsub.of(+t: KV.Trie<List<&2, Sub>>, cs: List<&2, String>) -> List<&2, R.Reply>:
  match cs:
    case Nil{}:
      Nil{}
    case Con{+c, rest}:
      R.RBulk{c} <> R.RInt{R.IPos{List.length(&2, Sub, chan.subs(t, c))}} <> numsub.of(t, rest)

def reg.read(op: R.PubOp, +r: Reg) -> R.Reply:
  match op r:
    case R.PChans{sh, pat} RegNone{}:
      R.RArray{Nil{}}
    case R.PChans{False{}, pat} RegOn{+ch, p, sh, cl, n}:
      R.RArray{chans.of(pat, KV.keys(List<&2, Sub>, ch, 0n))}
    case R.PChans{True{}, pat} RegOn{ch, p, +sh, cl, n}:
      R.RArray{chans.of(pat, KV.keys(List<&2, Sub>, sh, 0n))}
    case R.PNumSub{sh, cs} RegNone{}:
      R.RArray{S.pub.zeros(cs)}
    case R.PNumSub{False{}, cs} RegOn{+ch, p, sh, cl, n}:
      R.RArray{numsub.of(ch, cs)}
    case R.PNumSub{True{}, cs} RegOn{ch, p, +sh, cl, n}:
      R.RArray{numsub.of(sh, cs)}
    case R.PNumPat{} RegNone{}:
      R.RInt{R.IPos{0n}}
    case R.PNumPat{} RegOn{ch, +p, sh, cl, n}:
      R.RInt{R.IPos{List.length(&2, Pat, p)}}
    case _ _:
      R.RNull{}

def ps.read(op: R.PubOp, +pb: Ps) -> R.Reply:
  match pb:
    case Ps{+reg, ev, px, cs, own}:
      reg.read(op, reg)
    case PsOf{+p}:
      ps.read(op, p)

# the classes of keyspace events the subscribers may hear: those
# notify-keyspace-events names, when it names K or E and a class, and
# none while no client has a subscription (Keyspace notifications)
def ev.flags(m: Maybe<&2, U32>) -> U32:
  match m:
    case Some{+f}:
      Bool.pick(U32, Bool.and(U32.is_ne(U32.and(f, 3), 0), U32.is_ne(U32.and(f, 4294967292), 0)), f, 0)
    case None{}:
      0

def ev.of(+srv: S.Srv) -> U32:
  ev.flags(C.notify.read(C.config.get_value(S.srv.cfg(srv), "notify-keyspace-events"), Some{0}))

# the bits of ev past the events' (ps.loud): a killed client (31), the
# monitors (30), a group past maxmemory with nothing left to evict (29,
# Eviction), maxmemory set (28), an LFU policy (27, Access), an eviction
# to go on with (26: one ran out of time, or a CONFIG SET changed
# maxmemory) and a pause (25, The pause), each keeping the fast way off
# but 28, 27 and 26; 29 to 26 follow the server and the actor
def mem.bits(+srv: S.Srv, +ev: U32) -> U32:
  +m = S.srv.mm(srv)
  U32.or(U32.or(U32.or(U32.and(ev, 603979776), Bool.pick(U32, Nat.is_lt(0n, S.mm.max(m)), 268435456, 0)), Bool.pick(U32, S.mm.lfu(m), 134217728, 0)), Bool.pick(U32, S.mm.kick(m), 67108864, 0))

def ps.tune(pb: Ps, +srv: S.Srv) -> Ps:
  match pb:
    case Ps{RegNone{}, +ev, px, +cs, own}:
      Ps{RegNone{}, U32.or(cls.bit(cs), mem.bits(srv, ev)), px, cs, own}
    case Ps{RegOn{c, p, sh, cl, n}, +ev, px, +cs, own}:
      Ps{RegOn{c, p, sh, cl, n}, U32.or(U32.or(ev.of(srv), cls.bit(cs)), mem.bits(srv, ev)), px, cs, own}
    case PsOf{p}:
      ps.tune(p, srv)

# an eviction's outcome (Eviction: Evd's res) in Ps: 0 none, the heap
# within maxmemory; 1 one that ran out of time (bit 26: the actor goes on
# evicting between groups); 2 one with no key left to evict (bit 29: the
# commands that may take memory are refused)
def mem.res.bits(+res: Nat) -> U32:
  match res:
    case 1n:
      67108864
    case 2n:
      536870912
    case _:
      0

def ps.mem(pb: Ps, +res: Nat) -> Ps:
  match pb:
    case Ps{reg, ev, px, cs, own}:
      Ps{reg, U32.or(U32.and(ev, 3690987519), mem.res.bits(res)), px, cs, own}
    case PsOf{p}:
      ps.mem(p, res)

# whether the actor is to evict before it waits for a request: an
# eviction ran out of time, or a CONFIG SET changed maxmemory (bit 26),
# and no pause holds (bit 25: The pause)
def ps.evicting(+pb: Ps) -> Bool:
  match pb:
    case Ps{reg, +ev, px, cs, own}:
      U32.is_eq(U32.and(ev, 100663296), 67108864)
    case PsOf{+p}:
      ps.evicting(p)

# whether the commands that may take memory are refused: past maxmemory
# with nothing left to evict (bit 29), while no pause holds
def ps.oom.is(+pb: Ps) -> Bool:
  match pb:
    case Ps{reg, +ev, px, cs, own}:
      U32.is_eq(U32.and(ev, 570425344), 536870912)
    case PsOf{+p}:
      ps.oom.is(p)

# whether the policy is an LFU one (Access)
def ps.lfu(+pb: Ps) -> Bool:
  match pb:
    case Ps{reg, +ev, px, cs, own}:
      U32.is_ne(U32.and(ev, 134217728), 0)
    case PsOf{+p}:
      ps.lfu(p)

# what the actor does about memory before a group: 0 nothing (no
# maxmemory, and no eviction's outcome kept), 1 forget the last
# eviction's outcome (maxmemory was taken away, or a pause holds: The
# pause), 2 read the heap's account and evict (Eviction)
def mem.need(+pb: Ps) -> Nat:
  match pb:
    case Ps{reg, +ev, px, cs, own}:
      Bool.pick(Nat, U32.is_eq(U32.and(ev, 301989888), 268435456), 2n, Bool.pick(Nat, U32.is_ne(U32.and(ev, 603979776), 0), 1n, 0n))
    case PsOf{+p}:
      mem.need(p)

# the pause (The pause)
def ps.pz(+pb: Ps) -> Pz:
  match pb:
    case Ps{reg, ev, px, Cls{tab, kd, ks, ms, +pz, dn, hd}, own}:
      pz
    case PsOf{+p}:
      ps.pz(p)

# what the group asks of the shell once it has run: 0 nothing, 1 a save
# (SAVE, FLUSHALL with save points, or a SHUTDOWN that saves first and
# stops the server unless its save fails: The RDB file, SHUTDOWN), 2 a
# SHUTDOWN that stops the server, 3 one that stops it after a save
# whether the save works or not (FORCE); and the group with one asked for
def ps.down(+pb: Ps) -> Nat:
  match pb:
    case Ps{reg, ev, px, Cls{tab, kd, ks, ms, pz, +dn, hd}, own}:
      dn
    case PsOf{+p}:
      ps.down(p)

def ps.down.set(+d: Nat, pb: Ps) -> Ps:
  match pb:
    case Ps{reg, ev, px, Cls{tab, kd, ks, ms, pz, dn, hd}, own}:
      Ps{reg, U32.or(U32.and(ev, 4269801471), dn.bit(d)), px, Cls{tab, kd, ks, ms, pz, d, hd}, own}
    case PsOf{p}:
      ps.down.set(d, p)

# the pushes of a batch put before the group's answers
def ps.flush(pb: Ps, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>) -> Ps & List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>:
  match pb:
    case Ps{reg, ev, px, cs, own}:
      (Ps{reg, ev, Nil{}, cs, own}, List.append(&2, Sigma<&2, &2, Chan(Ans), _ => Ans>, px, outs))
    case PsOf{p}:
      ps.flush(p, outs)

# a batch's answer to a client with a subscription after it
def ans.sub(on: Bool, a: Ans) -> Ans:
  match on a:
    case True{} Ans{out, cn}:
      AnsSub{out, cn}
    case _ a0:
      a0

# The commands of a client with a subscription: (P|S)SUBSCRIBE,
# (P|S)UNSUBSCRIBE, PING, QUIT and RESET, by the parser's numbers
def sub.allowed(+key: Nat) -> Bool:
  Bool.or(Nat.is_eq(key, R.stat.top(1n)), Bool.or(Nat.is_eq(key, R.stat.top(103n)), Bool.or(Nat.is_eq(key, R.stat.top(104n)),
  Bool.or(Nat.is_eq(key, R.stat.top(166n)), Bool.or(Nat.is_eq(key, R.stat.top(167n)), Bool.or(Nat.is_eq(key, R.stat.top(168n)),
  Bool.or(Nat.is_eq(key, R.stat.top(169n)), Bool.or(Nat.is_eq(key, R.stat.top(170n)), Nat.is_eq(key, R.stat.top(171n))))))))))

def sub.deny(+name: String) -> String:
  "Can't execute '" ++ name ++ "': only (P|S)SUBSCRIBE / (P|S)UNSUBSCRIBE / PING / QUIT / RESET are allowed in this context"

# Tracking in the actor
# ---------------------
# (Tracking, above.) The registry keeps each client's tracking (its Cl's
# tk), and the heeded keys' record keeps the table, the prefixes and the
# tracking clients (Hd's trk). An invalidation is worked out on Iv:
# Pub/Sub's state with the tracking taken out of the registry, so that a
# walk of the table's keys reads and writes both at once.

type Iv is Data:
  Iv{reg: Reg, ev: U32, px: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, cs: Cls, own: List<&2, R.Reply>, t: Trk}

# the registry's tracking swapped for t
def cls.trk.swap(t: Trk, cs: Cls) -> Trk & Cls:
  match cs:
    case Cls{tab, kd, ks, ms, pz, dn, Hd{hk, sn, ad, bs, tr}}:
      (tr, Cls{tab, kd, ks, ms, pz, dn, Hd{hk, sn, ad, bs, t}})

def cls.trk(+cs: Cls) -> Trk:
  match cs:
    case Cls{tab, kd, ks, ms, pz, dn, Hd{hk, sn, ad, bs, +tr}}:
      tr

def cls.trk.put(t: Trk, cs: Cls) -> Cls:
  match cs:
    case Cls{tab, kd, ks, ms, pz, dn, Hd{hk, sn, ad, bs, tr}}:
      Cls{tab, kd, ks, ms, pz, dn, Hd{hk, sn, ad, bs, t}}

def iv.mk(p: Trk & Cls, reg: Reg, ev: U32, px: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, own: List<&2, R.Reply>) -> Iv:
  (t, cs) = p
  Iv{reg, ev, px, cs, own, t}

def iv.of(pb: Ps) -> Iv:
  match pb:
    case Ps{reg, ev, px, cs, own}:
      iv.mk(cls.trk.swap(trk.new(), cs), reg, ev, px, own)
    case PsOf{p}:
      iv.of(p)

def iv.ps.mk(p: Trk & Cls, reg: Reg, ev: U32, px: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, own: List<&2, R.Reply>) -> Ps:
  (t0, cs) = p
  Ps{reg, ev, px, cs, own}

# Pub/Sub's state again, its bits of the tracking made anew (trk.bits)
def iv.ps(v: Iv) -> Ps:
  match v:
    case Iv{reg, ev, px, cs, own, +t}:
      iv.ps.mk(cls.trk.swap(t, cs), reg, U32.or(U32.and(ev, 4288675839), trk.bits(t)), px, own)

# the tracking in Pub/Sub's state, read
def ps.trk(+pb: Ps) -> Trk:
  match pb:
    case Ps{reg, ev, px, Cls{tab, kd, ks, ms, pz, dn, Hd{hk, sn, ad, bs, +tr}}, own}:
      tr
    case PsOf{+p}:
      ps.trk(p)

# the tracking clients and the redirects, read: whether the client of id
# tracks, or is a redirect's client (its pushes must go out at once)
def trk.waits(+id: Nat, +t: Trk) -> Bool:
  match t:
    case TrkOn{tab, keys, items, +ids, +rds, pfx, pend, over, mx}:
      Bool.or(ids.has(id, ids), ids.has(id, rds))
    case TrkOf{+x}:
      trk.waits(id, x)

# the tracking of the client of id
def ps.tk(+id: Nat, +pb: Ps) -> Tk:
  cls.tk(id, ps.cls(pb))

# whether the tracking has work: Ps's bit 22 (trk.bits)
def ps.trk.hot(+pb: Ps) -> Bool:
  match pb:
    case Ps{reg, +ev, px, cs, own}:
      U32.is_ne(U32.and(ev, 4194304), 0)
    case PsOf{+p}:
      ps.trk.hot(p)

# whether some client is in BCAST mode: Ps's bit 21
def ps.trk.bcasts(+pb: Ps) -> Bool:
  match pb:
    case Ps{reg, +ev, px, cs, own}:
      U32.is_ne(U32.and(ev, 2097152), 0)
    case PsOf{+p}:
      ps.trk.bcasts(p)

def ps.trk.waits.if(on: Bool, +id: Nat, +pb: Ps) -> Bool:
  match on:
    case True{}:
      trk.waits(id, ps.trk(pb))
    case False{}:
      False{}

def ps.trk.waits(+id: Nat, +pb: Ps) -> Bool:
  ps.trk.waits.if(ps.trk.hot(pb), id, pb)

# the counts INFO shows: the tracking clients, the table's keys and ids,
# the prefixes
def trk.info(+t: Trk, srv: S.Srv) -> S.Srv:
  match t:
    case TrkOn{tab, +keys, +items, +ids, rds, +pfx, pend, over, mx}:
      S.srv.tracking(srv, List.length(&2, Nat, ids), keys, items, List.length(&2, Bc, pfx))
    case TrkOf{+x}:
      trk.info(x, srv)

# Reading: a call's keys remembered for the client of id
def trk.remember.add(has: Bool, +k: String, +id: Nat, xs: List<&2, Nat>, t: Trk) -> Trk:
  match has t:
    case False{} TrkOn{tab, keys, items, ids, rds, pfx, pend, over, mx}:
      TrkOn{KV.set(List<&2, Nat>, tab, k, id <> xs), keys, 1n+items, ids, rds, pfx, pend, over, mx}
    case _ t0:
      t0

def trk.remember.of(m: Maybe<&2, List<&2, Nat>>, +k: String, +id: Nat, t: Trk) -> Trk:
  match m t:
    case None{} TrkOn{tab, keys, items, ids, rds, pfx, pend, over, mx}:
      TrkOn{KV.set(List<&2, Nat>, tab, k, [id]), 1n+keys, 1n+items, ids, rds, pfx, pend, over, mx}
    case Some{+xs} t0:
      trk.remember.add(ids.has(id, xs), k, id, xs, t0)
    case _ t0:
      t0

def trk.remember(+k: String, +id: Nat, t: Trk) -> Trk:
  match t:
    case TrkOn{+tab, keys, items, ids, rds, pfx, pend, over, mx}:
      trk.remember.of(KV.read(List<&2, Nat>, tab, k, 0n), k, id, TrkOn{tab, keys, items, ids, rds, pfx, pend, over, mx})
    case TrkOf{x}:
      trk.remember(k, id, x)

def trk.reads(+xs: List<&2, String>, +id: Nat, t: Trk) -> Trk:
  match xs:
    case Nil{}:
      t
    case Con{+k, +rest}:
      trk.reads(rest, id, trk.remember(k, id, t))

# the keys xs a call of the client of id read, in the table (whose keys
# are heeded keys)
def ps.trk.read(+id: Nat, +xs: List<&2, String>, pb: Ps) -> Ps:
  match pb:
    case Ps{reg, ev, px, Cls{tab, kd, ks, ms, pz, dn, Hd{hk, sn, ad, bs, tr}}, own}:
      Ps{reg, U32.or(ev, 4194304), px, Cls{tab, kd, ks, ms, pz, dn, Hd{hk, sn, ad, bs, trk.reads(xs, id, tr)}}, own}
    case PsOf{p}:
      ps.trk.read(id, xs, p)

# CLIENT CACHING's flag of the client of id set (CLIENT CACHING), or
# cleared after a call that is no CLIENT command and leaves its client in
# no MULTI (resetClient)
def ps.trk.caching(+id: Nat, +on: Bool, pb: Ps) -> Ps:
  match pb:
    case Ps{reg, ev, px, cs, own}:
      +c = cs
      Ps{reg, ev, px, cls.tk.set(id, tk.caching.set(on, cls.tk(id, c)), c), own}
    case PsOf{p}:
      ps.trk.caching(id, on, p)

# Ps's bits of the tracking made anew from it (trk.bits), after a client
# starts or stops to track
def ps.trk.bits(pb: Ps) -> Ps:
  match pb:
    case Ps{reg, ev, px, +cs, own}:
      Ps{reg, U32.or(U32.and(ev, 4288675839), trk.bits(cls.trk(cs))), px, cs, own}
    case PsOf{p}:
      ps.trk.bits(p)

# Turning tracking on and off. A prefix list in byte order, with p in it.
def pfx.ins(+p: String, xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      [p]
    case Con{+x, +rest}:
      +o = String.order(x, p)
      Bool.pick(List<&2, String>, Cmp.is_lt(o), x <> pfx.ins(p, rest), Bool.pick(List<&2, String>, Cmp.is_eq(o), x <> rest, p <> (x <> rest)))

def pfx.ins.all(+gs: List<&2, String>, xs: List<&2, String>) -> List<&2, String>:
  match gs:
    case Nil{}:
      xs
    case Con{+p, +rest}:
      pfx.ins.all(rest, pfx.ins(p, xs))

# the prefix table with the client of id listening to p (a prefix of its
# own when none listened), in the order of the prefixes' bytes
def bc.add(+p: String, +id: Nat, bs: List<&2, Bc>) -> List<&2, Bc>:
  match bs:
    case Nil{}:
      [Bc{p, [id], Nil{}}]
    case Con{Bc{+x, +ids, +keys}, +rest}:
      +o = String.order(x, p)
      Bool.pick(List<&2, Bc>, Cmp.is_lt(o), Bc{x, ids, keys} <> bc.add(p, id, rest),
        Bool.pick(List<&2, Bc>, Cmp.is_eq(o), Bc{x, Bool.pick(List<&2, Nat>, ids.has(id, ids), ids, List.append(&2, Nat, ids, [id])), keys} <> rest, Bc{p, [id], Nil{}} <> (Bc{x, ids, keys} <> rest)))

def bc.add.all(+gs: List<&2, String>, +id: Nat, bs: List<&2, Bc>) -> List<&2, Bc>:
  match gs:
    case Nil{}:
      bs
    case Con{+p, +rest}:
      bc.add.all(rest, id, bc.add(p, id, bs))

def ps.trk.off(+id: Nat, pb: Ps) -> Ps:
  match pb:
    case Ps{reg, ev, px, cs, own}:
      +c = cs
      +cur = cls.tk(id, c)
      ps.trk.bits(Ps{reg, ev, px, cls.tk.set(id, TkOff{}, cls.trk.put(trk.off(id, cur, cls.trk(c)), c)), own})
    case PsOf{p}:
      ps.trk.off(id, p)

# the client of id tracks (enableTracking): its redirect, its mode, and
# its prefixes (BCAST: those given, or the empty one) added to its own;
# CLIENT CACHING's flag kept, broken cleared
def ids.add.if(was: Bool, +id: Nat, xs: List<&2, Nat>) -> List<&2, Nat>:
  match was:
    case True{}:
      xs
    case False{}:
      id <> xs

def bc.add.if(on: Bool, +gs: List<&2, String>, +id: Nat, bs: List<&2, Bc>) -> List<&2, Bc>:
  match on:
    case True{}:
      bc.add.all(gs, id, bs)
    case False{}:
      bs

def trk.on(+id: Nat, +was: Bool, +old: Nat, +rd: Nat, +b: Bool, +gs: List<&2, String>, t: Trk) -> Trk:
  match t:
    case TrkOn{tab, keys, items, ids, rds, pfx, pend, over, mx}:
      TrkOn{tab, keys, items, ids.add.if(was, id, ids), rds.add(rd, rds.drop(Bool.pick(Nat, was, old, 0n), rds)), bc.add.if(b, gs, id, pfx), pend, over, mx}
    case TrkOf{x}:
      trk.on(id, was, old, rd, b, gs, x)

# the prefixes a client in BCAST mode listens to after CLIENT TRACKING on:
# its own and those given, or the empty one when none is given
def pfx.given(+gs: List<&2, String>) -> List<&2, String>:
  match gs:
    case Nil{}:
      [""]
    case Con{x, rest}:
      gs

# a client's tracking after CLIENT TRACKING on: its redirect and mode,
# CLIENT CACHING's flag kept, broken cleared, its prefixes and those
# given (BCAST)
def tk.made(+rd: Nat, +b: Bool, +i: Bool, +o: Bool, +l: Bool, +cur: Tk, +given: List<&2, String>) -> Tk:
  TkOn{rd, b, i, o, l, tk.caching(cur), False{}, pfx.ins.all(given, Bool.pick(List<&2, String>, b, tk.pfx(cur), Nil{}))}

def ps.trk.on(+id: Nat, +rd: Nat, +b: Bool, +i: Bool, +o: Bool, +l: Bool, +gs: List<&2, String>, pb: Ps) -> Ps:
  match pb:
    case Ps{reg, ev, px, cs, own}:
      +c = cs
      +cur = cls.tk(id, c)
      +given = Bool.pick(List<&2, String>, b, pfx.given(gs), Nil{})
      ps.trk.bits(Ps{reg, ev, px, cls.tk.set(id, tk.made(rd, b, i, o, l, cur, given), cls.trk.put(trk.on(id, tk.on(cur), tk.redir(cur), rd, b, given, cls.trk(c)), c)), own})
    case PsOf{p}:
      ps.trk.on(id, rd, b, i, o, l, gs, p)

# CLIENT TRACKING's options checked in order: a REDIRECT's client looked
# for, the first error the parser found
type Tq is Data:
  TqOk{redir: Nat, bcast: Bool, optin: Bool, optout: Bool, noloop: Bool, pfx: List<&2, String>}
  TqBad{r: R.Reply}

def tq.redir(found: Bool, +n: Nat, q: Tq) -> Tq:
  match found q:
    case True{} TqOk{rd, b, i, o, l, p}:
      TqOk{n, b, i, o, l, p}
    case False{} TqOk{rd, b, i, o, l, p}:
      TqBad{R.RError{"ERR The client ID you want redirect to does not exist"}}
    case _ q0:
      q0

def tq.go(opts: List<&2, R.TOpt>, q: Tq, +cs: Cls) -> Tq:
  match opts q:
    case _ TqBad{r}:
      TqBad{r}
    case Nil{} q0:
      q0
    case Con{R.TrRedir{+n}, rest} q0:
      tq.go(rest, tq.redir(Bool.and(Nat.is_lt(0n, n), Maybe.is_some(&2, Cl, cls.get(n, cs))), n, q0), cs)
    case Con{R.TrBcast{}, rest} TqOk{rd, b, i, o, l, p}:
      tq.go(rest, TqOk{rd, True{}, i, o, l, p}, cs)
    case Con{R.TrPrefix{x}, rest} TqOk{rd, b, i, o, l, p}:
      tq.go(rest, TqOk{rd, b, i, o, l, x <> p}, cs)
    case Con{R.TrOptin{}, rest} TqOk{rd, b, i, o, l, p}:
      tq.go(rest, TqOk{rd, b, True{}, o, l, p}, cs)
    case Con{R.TrOptout{}, rest} TqOk{rd, b, i, o, l, p}:
      tq.go(rest, TqOk{rd, b, i, True{}, l, p}, cs)
    case Con{R.TrNoloop{}, rest} TqOk{rd, b, i, o, l, p}:
      tq.go(rest, TqOk{rd, b, i, o, True{}, p}, cs)
    case Con{R.TrBad{r}, rest} q0:
      TqBad{r}

# the prefix g against the client's own prefixes (es), and against those
# given after it (gs), as checkPrefixCollisionsOrReply: one is the other's
# beginning
def pfx.olap(+a: String, +b: String) -> Bool:
  Bool.or(String.starts_with(a, b), String.starts_with(b, a))

def pfx.olap.end() -> String:
  "'. Prefixes for a single client must not overlap."

def pfx.have(+g: String, +es: List<&2, String>) -> Maybe<&2, R.Reply>:
  match es:
    case Nil{}:
      None{}
    case Con{+e, +rest}:
      Bool.pick(Maybe<&2, R.Reply>, pfx.olap(e, g), Some{R.RError{"ERR Prefix '" ++ g ++ "' overlaps with an existing prefix '" ++ e ++ pfx.olap.end()}}, pfx.have(g, rest))

def pfx.later(+g: String, +gs: List<&2, String>) -> Maybe<&2, R.Reply>:
  match gs:
    case Nil{}:
      None{}
    case Con{+x, +rest}:
      Bool.pick(Maybe<&2, R.Reply>, pfx.olap(g, x), Some{R.RError{"ERR Prefix '" ++ g ++ "' overlaps with another provided prefix '" ++ x ++ pfx.olap.end()}}, pfx.later(g, rest))

def err.or(a: Maybe<&2, R.Reply>, b: Maybe<&2, R.Reply>) -> Maybe<&2, R.Reply>:
  match a:
    case Some{x}:
      Some{x}
    case None{}:
      b

def pfx.clash(+es: List<&2, String>, +gs: List<&2, String>) -> Maybe<&2, R.Reply>:
  match gs:
    case Nil{}:
      None{}
    case Con{+g, +rest}:
      err.or(err.or(pfx.have(g, es), pfx.later(g, rest)), pfx.clash(es, rest))

def err.of(+on: Bool, +m: String) -> Maybe<&2, R.Reply>:
  Bool.pick(Maybe<&2, R.Reply>, on, Some{R.RError{m}}, None{})

# CLIENT TRACKING on's errors, in Redis's order: a PREFIX without BCAST, a
# switch of BCAST, OPTIN or OPTOUT with BCAST, both, a switch of OPTIN or
# OPTOUT, a prefix that overlaps (Redis 7.0.15 answers a second error and
# then OK for an overlap of two given prefixes past the first one: this
# answers the error alone)
def trk.err(+cur: Tk, +b: Bool, +i: Bool, +o: Bool, +gs: List<&2, String>) -> Maybe<&2, R.Reply>:
  err.or(err.of(Bool.and(Bool.not(b), Bool.not(List.is_empty(&2, String, gs))), "ERR PREFIX option requires BCAST mode to be enabled"),
  err.or(err.of(Bool.and(tk.on(cur), Bool.xor(tk.bcast(cur), b)), "ERR You can't switch BCAST mode on/off before disabling tracking for this client, and then re-enabling it with a different mode."),
  err.or(err.of(Bool.and(b, Bool.or(i, o)), "ERR OPTIN and OPTOUT are not compatible with BCAST"),
  err.or(err.of(Bool.and(i, o), "ERR You can't specify both OPTIN mode and OPTOUT mode"),
  err.or(err.of(Bool.or(Bool.and(i, tk.optout(cur)), Bool.and(o, tk.optin(cur))), "ERR You can't switch OPTIN/OPTOUT mode before disabling tracking for this client, and then re-enabling it with a different mode."),
    Bool.pick(Maybe<&2, R.Reply>, b, pfx.clash(tk.pfx(cur), gs), None{}))))))


# Invalidation. A message for a tracking client goes where Redis's
# sendTrackingMessage sends it: to the client itself, or to the client it
# redirects to (red); in RESP3 as a push, in RESP2 only to a redirect's
# client with a subscription. To another client it is a push on its
# channel; to the client whose command runs (cur), among its replies,
# before its command's when it is another client's (own), after it when
# it is its own, kept for after the call (the tracking's pend).
#
# While a blocked client is served (out: Some of the id of the client
# whose command served it, else None), the served client is cur: what it
# gets as another's goes on its channel, which its reply follows (bg.ups);
# what the client out gets goes after that client's reply, as Redis
# writes it once its call is over (own collects it meanwhile, and
# pd.aside puts it with that client's pending ones).
def iv.route.me(mine: Bool, srv: Bool, +dback: Chan(Ans), +dr3: Bool, +p: Pl, v: Iv) -> Iv:
  match mine srv v:
    case True{} _ Iv{reg, ev, px, cs, own, TrkOn{tab, keys, items, ids, rds, pfx, pend, over, mx}}:
      Iv{reg, ev, px, cs, own, TrkOn{tab, keys, items, ids, rds, pfx, inv.reply(dr3, p) <> pend, over, mx}}
    case False{} False{} Iv{reg, ev, px, cs, own, t}:
      Iv{reg, ev, px, cs, inv.reply(dr3, p) <> own, t}
    case False{} True{} Iv{reg, ev, px, cs, own, t}:
      Iv{reg, ev, (dback, Push{inv.bytes(dr3, p)}) <> px, cs, own, t}
    case _ _ v0:
      v0

def iv.route.other(late: Bool, +dback: Chan(Ans), +dr3: Bool, +p: Pl, v: Iv) -> Iv:
  match late v:
    case True{} Iv{reg, ev, px, cs, own, t}:
      Iv{reg, ev, px, cs, inv.reply(dr3, p) <> own, t}
    case False{} Iv{reg, ev, px, cs, own, t}:
      Iv{reg, ev, (dback, Push{inv.bytes(dr3, p)}) <> px, cs, own, t}

def iv.route(me: Bool, mine: Bool, late: Bool, srv: Bool, +dback: Chan(Ans), +dr3: Bool, +p: Pl, v: Iv) -> Iv:
  match me:
    case True{}:
      iv.route.me(mine, srv, dback, dr3, p, v)
    case False{}:
      iv.route.other(late, dback, dr3, p, v)

# whether the client of id is the one whose command served a client (out)
def iv.late(+id: Nat, +out: Maybe<&2, Nat>) -> Bool:
  match out:
    case Some{+o}:
      Nat.is_eq(id, o)
    case None{}:
      False{}

def iv.put.as(go: Bool, +did: Nat, +dback: Chan(Ans), +dr3: Bool, +p: Pl, +tid: Nat, +cur: Nat, +out: Maybe<&2, Nat>, v: Iv) -> Iv:
  match go:
    case True{}:
      iv.route(Nat.is_eq(did, cur), Nat.is_eq(tid, cur), iv.late(did, out), Maybe.is_some(&2, Nat, out), dback, dr3, p, v)
    case False{}:
      v

def iv.put(red: Bool, +did: Nat, +dback: Chan(Ans), +dr3: Bool, +p: Pl, +tid: Nat, +cur: Nat, +out: Maybe<&2, Nat>, v: Iv) -> Iv:
  match v:
    case Iv{+reg, ev, px, cs, own, t}:
      iv.put.as(Bool.or(dr3, Bool.and(red, Maybe.is_some(&2, Mine, reg.mine(did, reg)))), did, dback, dr3, p, tid, cur, out, Iv{reg, ev, px, cs, own, t})

# a client whose redirect is gone: flagged broken, and told so in RESP3
# (after its reply when its own command runs, or when its command served
# the client whose change it hears of: late)
def iv.notice.other(late: Bool, +back: Chan(Ans), +rd: Nat, v: Iv) -> Iv:
  match late v:
    case True{} Iv{reg, ev, px, cs, own, t}:
      Iv{reg, ev, px, cs, broken.reply(rd) <> own, t}
    case False{} Iv{reg, ev, px, cs, own, t}:
      Iv{reg, ev, (back, Push{broken.bytes(rd)}) <> px, cs, own, t}

def iv.notice(on: Bool, me: Bool, late: Bool, +back: Chan(Ans), +rd: Nat, v: Iv) -> Iv:
  match on me v:
    case True{} True{} Iv{reg, ev, px, cs, own, TrkOn{tab, keys, items, ids, rds, pfx, pend, over, mx}}:
      Iv{reg, ev, px, cs, own, TrkOn{tab, keys, items, ids, rds, pfx, broken.reply(rd) <> pend, over, mx}}
    case True{} False{} v0:
      iv.notice.other(late, back, rd, v0)
    case _ _ v0:
      v0

def iv.broken(+id: Nat, +back: Chan(Ans), +r3: Bool, +rd: Nat, +cur: Nat, +out: Maybe<&2, Nat>, v: Iv) -> Iv:
  match v:
    case Iv{reg, ev, px, cs, own, t}:
      +c = cs
      iv.notice(r3, Nat.is_eq(id, cur), iv.late(id, out), back, rd, Iv{reg, ev, px, cls.tk.set(id, tk.broken.set(cls.tk(id, c)), c), own, t})

def iv.redir.of(m: Maybe<&2, Cl>, +rd: Nat, +id: Nat, +back: Chan(Ans), +r3: Bool, +p: Pl, +cur: Nat, +out: Maybe<&2, Nat>, v: Iv) -> Iv:
  match m:
    case Some{Cl{+rid, +rback, fd, addr, laddr, since, name, db, noev, +rr3, kt}}:
      iv.put(True{}, rid, rback, rr3, p, id, cur, out, v)
    case None{}:
      iv.broken(id, back, r3, rd, cur, out, v)

def iv.to(+rd: Nat, +id: Nat, +back: Chan(Ans), +r3: Bool, +p: Pl, +cur: Nat, +out: Maybe<&2, Nat>, v: Iv) -> Iv:
  match rd v:
    case 0n v0:
      iv.put(False{}, id, back, r3, p, id, cur, out, v0)
    case _ Iv{reg, ev, px, +cs, own, t}:
      iv.redir.of(cls.get(rd, cs), rd, id, back, r3, p, cur, out, Iv{reg, ev, px, cs, own, t})

# an invalidation p for the tracking client c, cur being the client whose
# command runs (0: none), out as iv.route reads it
def iv.send(+c: Cl, +p: Pl, +cur: Nat, +out: Maybe<&2, Nat>, v: Iv) -> Iv:
  match c:
    case Cl{+id, +back, fd, addr, laddr, since, name, db, noev, +r3, +kt}:
      iv.to(tk.redir(kt), id, back, r3, p, cur, out, v)

# a key of the table that changed: each of its clients that hears of it
# told, the key out of the table
def iv.one.if(on: Bool, +c: Cl, +k: String, +cur: Nat, +out: Maybe<&2, Nat>, v: Iv) -> Iv:
  match on:
    case True{}:
      iv.send(c, PlKeys{[k]}, cur, out, v)
    case False{}:
      v

def iv.one.of(m: Maybe<&2, Cl>, +id: Nat, +k: String, +cur: Nat, +out: Maybe<&2, Nat>, v: Iv) -> Iv:
  match m:
    case Some{+c}:
      iv.one.if(tk.hears(cl.tk(c), Nat.is_eq(id, cur)), c, k, cur, out, v)
    case None{}:
      v

def iv.one(+id: Nat, +k: String, +cur: Nat, +out: Maybe<&2, Nat>, v: Iv) -> Iv:
  match v:
    case Iv{reg, ev, px, +cs, own, t}:
      iv.one.of(cls.get(id, cs), id, k, cur, out, Iv{reg, ev, px, cs, own, t})

def iv.ids(+xs: List<&2, Nat>, +k: String, +cur: Nat, +out: Maybe<&2, Nat>, v: Iv) -> Iv:
  match xs:
    case Nil{}:
      v
    case Con{+id, +rest}:
      iv.ids(rest, k, cur, out, iv.one(id, k, cur, out, v))

# the key k out of the table: the ids of its clients (none when it is not
# there), and the tracking without it
def trk.take.of(m: Maybe<&2, List<&2, Nat>>, +k: String, t: Trk) -> List<&2, Nat> & Trk:
  match m t:
    case Some{+xs} TrkOn{tab, keys, items, ids, rds, pfx, pend, over, mx}:
      (xs, TrkOn{KV.del(List<&2, Nat>, tab, k), Nat.sub(keys, 1n), Nat.sub(items, List.length(&2, Nat, xs)), ids, rds, pfx, pend, over, mx})
    case _ t0:
      (Nil{}, t0)

def trk.take(+k: String, t: Trk) -> List<&2, Nat> & Trk:
  match t:
    case TrkOn{+tab, keys, items, ids, rds, pfx, pend, over, mx}:
      trk.take.of(KV.read(List<&2, Nat>, tab, k, 0n), k, TrkOn{tab, keys, items, ids, rds, pfx, pend, over, mx})
    case TrkOf{x}:
      trk.take(k, x)

# BCAST: a key changed by the client by, among the keys of each prefix it
# begins with, first (bk.sorted orders them at the end of the group)
def bk.put.if(on: Bool, +k: String, +by: Nat, xs: List<&2, Bk>) -> List<&2, Bk>:
  match on:
    case True{}:
      Bk{k, by} <> xs
    case False{}:
      xs

def bc.mark(+k: String, +by: Nat, bs: List<&2, Bc>) -> List<&2, Bc>:
  match bs:
    case Nil{}:
      Nil{}
    case Con{Bc{+p, ids, keys}, rest}:
      Bc{p, ids, bk.put.if(String.starts_with(k, p), k, by, keys)} <> bc.mark(k, by, rest)

def trk.mark(+on: Bool, +k: String, +by: Nat, t: Trk) -> Trk:
  match on t:
    case True{} TrkOn{tab, keys, items, ids, rds, pfx, pend, over, mx}:
      TrkOn{tab, keys, items, ids, rds, bc.mark(k, by, pfx), pend, over, mx}
    case True{} TrkOf{x}:
      trk.mark(on, k, by, x)
    case False{} t0:
      t0

def iv.key.of(p: List<&2, Nat> & Trk, +k: String, +cur: Nat, +out: Maybe<&2, Nat>, reg: Reg, ev: U32, px: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, cs: Cls, own: List<&2, R.Reply>) -> Iv:
  (+xs, t) = p
  iv.ids(xs, k, cur, out, Iv{reg, ev, px, cs, own, t})

# key k changed by the client cur (0: none), as trackingInvalidateKey:
# under the BCAST prefixes (bc: but for a key the table's limit evicts),
# then to the clients in the table (out as iv.route reads it)
def iv.key.as(+k: String, +cur: Nat, +out: Maybe<&2, Nat>, +bc: Bool, v: Iv) -> Iv:
  match v:
    case Iv{reg, ev, px, cs, own, t}:
      iv.key.of(trk.take(k, trk.mark(bc, k, cur, t)), k, cur, out, reg, ev, px, cs, own)

def iv.key(+k: String, +cur: Nat, +bc: Bool, v: Iv) -> Iv:
  iv.key.as(k, cur, None{}, bc, v)

# FLUSHDB and FLUSHALL: a null to every tracking client (after its reply
# to the client whose command runs, whatever NOLOOP says), then the table
# emptied (trackingInvalidateKeysOnFlush)
def iv.null.of(m: Maybe<&2, Cl>, +cur: Nat, v: Iv) -> Iv:
  match m:
    case Some{Cl{+id, +back, fd, addr, laddr, since, name, db, noev, +r3, +kt}}:
      iv.to(tk.redir(kt), id, back, r3, PlNull{r3}, cur, None{}, v)
    case None{}:
      v

def iv.null.one(+id: Nat, +cur: Nat, v: Iv) -> Iv:
  match v:
    case Iv{reg, ev, px, +cs, own, t}:
      iv.null.of(cls.get(id, cs), cur, Iv{reg, ev, px, cs, own, t})

def iv.null.all(+xs: List<&2, Nat>, +cur: Nat, v: Iv) -> Iv:
  match xs:
    case Nil{}:
      v
    case Con{+id, +rest}:
      iv.null.all(rest, cur, iv.null.one(id, cur, v))

def trk.ids(+t: Trk) -> List<&2, Nat>:
  match t:
    case TrkOn{tab, keys, items, +ids, rds, pfx, pend, over, mx}:
      ids
    case TrkOf{+x}:
      trk.ids(x)

def trk.clear(t: Trk) -> Trk:
  match t:
    case TrkOn{tab, keys, items, ids, rds, pfx, pend, over, mx}:
      TrkOn{KV.empty(List<&2, Nat>), 0n, 0n, ids, rds, pfx, pend, over, mx}
    case TrkOf{x}:
      trk.clear(x)

def iv.clear(v: Iv) -> Iv:
  match v:
    case Iv{reg, ev, px, cs, own, t}:
      Iv{reg, ev, px, cs, own, trk.clear(t)}

def iv.flush(+cur: Nat, v: Iv) -> Iv:
  match v:
    case Iv{reg, ev, px, cs, own, +t}:
      iv.clear(iv.null.all(trk.ids(t), cur, Iv{reg, ev, px, cs, own, t}))

# the keys a command's effects change, as Touches finds them for WATCH
# (Redis calls signalModifiedKey for both): a key there before the
# command or after it; SMOVE's destination when its member was added;
# MOVE's key, COPY's destination; FLUSHDB and FLUSHALL flush; SWAPDB
# invalidates nothing
def iv.write.if(on: Bool, +k: String, +cur: Nat, v: Iv) -> Iv:
  match on:
    case True{}:
      iv.key(k, cur, True{}, v)
    case False{}:
      v

def iv.write(+j: Nat, +k: String, +pre: Maybe<&2, R.Ds>, +post: R.Ds, +cur: Nat, v: Iv) -> Iv:
  iv.write.if(Bool.or(ds.here(j, k, post), tx.was(pre, j, k)), k, cur, v)

def iv.writes(+ks: List<&2, String>, +j: Nat, +pre: Maybe<&2, R.Ds>, +post: R.Ds, +cur: Nat, v: Iv) -> Iv:
  match ks:
    case Nil{}:
      v
    case Con{+k, +rest}:
      iv.writes(rest, j, pre, post, cur, iv.write(j, k, pre, post, cur, v))

def iv.pairs(+ps: List<&2, R.KVPair>, +j: Nat, +pre: Maybe<&2, R.Ds>, +post: R.Ds, +cur: Nat, v: Iv) -> Iv:
  match ps:
    case Nil{}:
      v
    case Con{R.KP{+k, w}, +rest}:
      iv.pairs(rest, j, pre, post, cur, iv.write(j, k, pre, post, cur, v))

def iv.dst(on: Bool, +j: Nat, +k: String, +pre: Maybe<&2, R.Ds>, +post: R.Ds, +cur: Nat, v: Iv) -> Iv:
  match on:
    case True{}:
      iv.write(j, k, pre, post, cur, v)
    case False{}:
      v

def iv.cmd(+c: R.Cmd, +j: Nat, +pre: Maybe<&2, R.Ds>, +post: R.Ds, +cur: Nat, v: Iv) -> Iv:
  match c:
    case R.Set{+k, w}:
      iv.write(j, k, pre, post, cur, v)
    case R.Upd{+k, op}:
      iv.write(j, k, pre, post, cur, v)
    case R.Del{+ks}:
      iv.writes(ks, j, pre, post, cur, v)
    case R.MSet{+ps}:
      iv.pairs(ps, j, pre, post, cur, v)
    case R.FlushDb{}:
      iv.flush(cur, v)
    case R.Rename{+s, +d, nx}:
      iv.write(j, d, pre, post, cur, iv.write(j, s, pre, post, cur, v))
    case R.LMove{+s, +d, e}:
      iv.write(j, s, pre, post, cur, iv.write(j, d, pre, post, cur, v))
    case R.SMv{+s, +d, +w}:
      iv.dst(smv.added(pre, j, d, R.smv.member(w)), j, d, pre, post, cur, iv.write(j, s, pre, post, cur, v))
    case _:
      v

def iv.eff(+e: A.Eff, +pre: Maybe<&2, R.Ds>, +post: R.Ds, +cur: Nat, v: Iv) -> Iv:
  match e:
    case A.EDb{+j, +c}:
      iv.cmd(c, j, pre, post, cur, v)
    case A.ESwap{a, b}:
      v
    case A.EMove{+k, +s, +d}:
      iv.write(d, k, pre, post, cur, iv.write(s, k, pre, post, cur, v))
    case A.ECopy{s, +d, from, +to}:
      iv.write(to, d, pre, post, cur, v)
    case A.EWipe{}:
      iv.flush(cur, v)

def iv.effs(+es: List<&2, A.Eff>, +pre: Maybe<&2, R.Ds>, +post: R.Ds, +cur: Nat, v: Iv) -> Iv:
  match es:
    case Nil{}:
      v
    case Con{+e, +rest}:
      iv.effs(rest, pre, post, cur, iv.eff(e, pre, post, cur, v))

def iv.ent(+x: A.Ent, +pre: Maybe<&2, R.Ds>, +post: R.Ds, +cur: Nat, v: Iv) -> Iv:
  match x:
    case A.EOne{+e}:
      iv.eff(e, pre, post, cur, v)
    case A.ETx{+es}:
      iv.effs(es, pre, post, cur, v)

def iv.ents(+xs: List<&2, A.Ent>, +pre: Maybe<&2, R.Ds>, +post: R.Ds, +cur: Nat, v: Iv) -> Iv:
  match xs:
    case Nil{}:
      v
    case Con{+x, +rest}:
      iv.ents(rest, pre, post, cur, iv.ent(x, pre, post, cur, v))

# a command's effects (xs, its entries), the databases before it (pre;
# none: each key a DEL deleted was there) and after it, cur the client
# whose command it is (0: none); PFDEBUG's write is none (Touches)
def ps.trk.cmd.if(on: Bool, +c: R.Cmd, +xs: List<&2, A.Ent>, +pre: Maybe<&2, R.Ds>, +post: R.Ds, +cur: Nat, pb: Ps) -> Ps:
  match on c:
    case True{} R.Upd{k, R.UHll{R.HDebug{s}}}:
      pb
    case True{} c0:
      iv.ps(iv.ents(xs, pre, post, cur, iv.of(pb)))
    case False{} c0:
      pb

def ps.trk.cmd(+c: R.Cmd, +xs: List<&2, A.Ent>, +pre: Maybe<&2, R.Ds>, +post: R.Ds, +cur: Nat, pb: Ps) -> Ps:
  +p = pb
  ps.trk.cmd.if(ps.trk.hot(p), c, xs, pre, post, cur, p)

# the keys the sweep of expired keys or eviction deleted (their DELs),
# invalidated as no client's
def ps.trk.gone(+xs: List<&2, A.Ent>, +post: R.Ds, pb: Ps) -> Ps:
  +p = pb
  ps.trk.cmd.if(ps.trk.hot(p), R.Ping{}, xs, None{}, post, 0n, p)

# the invalidations kept for after the reply of the client whose command
# ran, taken (oldest last: they go on top of its replies, newest first)
def trk.pend.take(t: Trk) -> List<&2, R.Reply> & Trk:
  match t:
    case TrkOn{tab, keys, items, ids, rds, pfx, pend, over, mx}:
      (pend, TrkOn{tab, keys, items, ids, rds, pfx, Nil{}, over, mx})
    case TrkOf{x}:
      trk.pend.take(x)

def ps.pend.mk(p: List<&2, R.Reply> & Trk, reg: Reg, ev: U32, px: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, cs: Cls, own: List<&2, R.Reply>) -> List<&2, R.Reply> & Ps:
  (xs, t) = p
  (xs, Ps{reg, ev, px, cls.trk.put(t, cs), own})

def ps.pend.take(pb: Ps) -> List<&2, R.Reply> & Ps:
  match pb:
    case Ps{reg, ev, px, +cs, own}:
      ps.pend.mk(trk.pend.take(cls.trk(cs)), reg, ev, px, cs, own)
    case PsOf{p}:
      ps.pend.take(p)

def trk.pend.put(xs: List<&2, R.Reply>, t: Trk) -> Trk:
  match t:
    case TrkOn{tab, keys, items, ids, rds, pfx, pend, over, mx}:
      TrkOn{tab, keys, items, ids, rds, pfx, xs, over, mx}
    case TrkOf{x}:
      trk.pend.put(xs, x)

def ps.pend.put(xs: List<&2, R.Reply>, pb: Ps) -> Ps:
  match pb:
    case Ps{reg, ev, px, cs, own}:
      +c = cs
      Ps{reg, ev, px, cls.trk.put(trk.pend.put(xs, cls.trk(c)), c), own}
    case PsOf{p}:
      ps.pend.put(xs, p)

# A client served (blocked clients: bg.popped), the served client the one
# whose command runs, as Redis serves it: BLMOVE and BRPOPLPUSH change
# their destination (lmoveHandlePush signals it; the key they popped from
# was signalled by the push that made it ready, as serveClientBlockedOnList
# says), unless it holds another type: then they answer WRONGTYPE, change
# nothing and signal nothing (ok is False); BLMPOP's pop
# (listElementsRemoved), BZPOPMIN's, BZPOPMAX's and BZMPOP's
# (genericZpopCommand) signal the key they popped from, and BLPOP's and
# BRPOP's (form 1) do not. The invalidations the served
# client gets after its reply (pend, newest first); those it gets as
# another's go on its channel, before its reply (iv.route). Those for the
# client out, whose command served it, go after that client's reply, with
# its own pending ones (kept aside meanwhile), as Redis writes them once
# that client's call is over
type Pd is Data:
  Pd{pend: List<&2, R.Reply>, pb: Ps}

def ps.trk.popped(on: Bool, +ks: List<&2, String>, +id: Nat, +out: Maybe<&2, Nat>, pb: Ps) -> Ps:
  match on ks:
    case True{} Con{+k, rest}:
      iv.ps(iv.key.as(k, id, out, True{}, iv.of(pb)))
    case _ _:
      pb

def ps.trk.moved(on: Bool, +d: String, +id: Nat, +out: Maybe<&2, Nat>, pb: Ps) -> Ps:
  match on:
    case True{}:
      iv.ps(iv.key.as(d, id, out, True{}, iv.of(pb)))
    case False{}:
      pb

def ps.trk.served.go(+pc: R.Cmd, +form: Nat, ok: Bool, +id: Nat, +out: Maybe<&2, Nat>, pb: Ps) -> Ps:
  match pc:
    case R.LMove{s, +d, e}:
      ps.trk.moved(ok, d, id, out, pb)
    case R.LMPop{+ks, l, n}:
      ps.trk.popped(Bool.not(Nat.is_eq(form, 1n)), ks, id, out, pb)
    case R.ZMPop{+ks, m, n}:
      ps.trk.popped(True{}, ks, id, out, pb)
    case _:
      pb

# the served client's pending invalidations (p), and the client out's
# again: those the serving made for it (late, newer) on top of its own
def pd.of(p: List<&2, R.Reply> & Ps, late: List<&2, R.Reply>, old: List<&2, R.Reply>) -> Pd:
  (pend, pb) = p
  Pd{pend, ps.pend.put(List.append(&2, R.Reply, late, old), pb)}

def pd.mk(p: List<&2, R.Reply> & Ps, old: List<&2, R.Reply>) -> Pd:
  (late, pb) = p
  pd.of(ps.pend.take(pb), late, old)

def pd.aside(p: List<&2, R.Reply> & Ps, +pc: R.Cmd, +form: Nat, ok: Bool, +id: Nat, +out: Nat) -> Pd:
  (old, pb) = p
  pd.mk(ps.own.take(ps.trk.served.go(pc, form, ok, id, Some{out}, pb)), old)

def ps.trk.served.if(on: Bool, +pc: R.Cmd, +form: Nat, ok: Bool, +id: Nat, +out: Nat, pb: Ps) -> Pd:
  match on:
    case True{}:
      pd.aside(ps.pend.take(pb), pc, form, ok, id, out)
    case False{}:
      Pd{Nil{}, pb}

def ps.trk.served(+pc: R.Cmd, +form: Nat, ok: Bool, +id: Nat, +out: Nat, pb: Ps) -> Pd:
  +p = pb
  ps.trk.served.if(ps.trk.hot(p), pc, form, ok, id, out, p)

# The end of a group (Redis's beforeSleep): the keys changed under each
# BCAST prefix to the clients that listen to it, each of them but the
# keys its own commands changed last when it is in NOLOOP mode, nothing
# when none is left; then no key is pending. The keys go in the order of
# their bytes, each once with the client of its last change, as Redis's
# radix tree of them holds them: a merge sort that keeps the newest first
# among equal keys (it takes the left one first, and merges neighbouring
# runs), then the first of each.

# a merge of two sorted lists, one key at a time (out: the merged ones,
# last first)
type Mg is Data:
  Mg{out: List<&2, Bk>, xs: List<&2, Bk>, ys: List<&2, Bk>}

def mg.pick(gt: Bool, out: List<&2, Bk>, x: Bk, xr: List<&2, Bk>, y: Bk, yr: List<&2, Bk>) -> Mg:
  match gt:
    case True{}:
      Mg{y <> out, x <> xr, yr}
    case False{}:
      Mg{x <> out, xr, y <> yr}

def mg.step(m: Mg) -> Mg:
  match m:
    case Mg{out, Con{Bk{+x, bx}, xr}, Con{Bk{+y, by}, yr}}:
      mg.pick(Cmp.is_gt(String.order(x, y)), out, Bk{x, bx}, xr, Bk{y, by}, yr)
    case Mg{out, Con{x, xr}, Nil{}}:
      Mg{x <> out, xr, Nil{}}
    case Mg{out, Nil{}, Con{y, yr}}:
      Mg{y <> out, Nil{}, yr}
    case other:
      other

def mg.run(n: Nat, m: Mg) -> Mg:
  match n:
    case 0n:
      m
    case 1n+p:
      mg.run(p, mg.step(m))

def mg.out(m: Mg) -> List<&2, Bk>:
  match m:
    case Mg{out, xs, ys}:
      List.reverse(&2, Bk, out)

def bk.merge(xs: List<&2, Bk>, ys: List<&2, Bk>) -> List<&2, Bk>:
  +a = xs
  +b = ys
  mg.out(mg.run(Nat.add(List.length(&2, Bk, a), List.length(&2, Bk, b)), Mg{Nil{}, a, b}))

# a bottom-up merge sort: runs of one key, merged two by two, left before
# right, until one is left (n: fuel, the number of keys)
def bk.runs(xs: List<&2, Bk>) -> List<&2, List<&2, Bk>>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{x, rest}:
      [x] <> bk.runs(rest)

def bk.pairs(rs: List<&2, List<&2, Bk>>) -> List<&2, List<&2, Bk>>:
  match rs:
    case Con{a, Con{b, rest}}:
      bk.merge(a, b) <> bk.pairs(rest)
    case other:
      other

def bk.passes(n: Nat, rs: List<&2, List<&2, Bk>>) -> List<&2, Bk>:
  match n rs:
    case _ Nil{}:
      Nil{}
    case _ Con{a, Nil{}}:
      a
    case 0n Con{a, rest}:
      a
    case 1n+p r0:
      bk.passes(p, bk.pairs(r0))

def bk.uniq.keep(same: Bool, x: Bk, rest: List<&2, Bk>) -> List<&2, Bk>:
  match same:
    case True{}:
      rest
    case False{}:
      x <> rest

# xs without a key that follows itself (prev: the key before, first: none)
def bk.uniq(xs: List<&2, Bk>, +prev: String, +first: Bool) -> List<&2, Bk>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{Bk{+k, b}, rest}:
      bk.uniq.keep(Bool.and(Bool.not(first), String.eq(k, prev)), Bk{k, b}, bk.uniq(rest, k, False{}))

def bk.sorted(xs: List<&2, Bk>) -> List<&2, Bk>:
  +x0 = xs
  bk.uniq(bk.passes(List.length(&2, Bk, x0), bk.runs(x0)), "", True{})

def bk.not.keep(same: Bool, +k: String, rest: List<&2, String>) -> List<&2, String>:
  match same:
    case True{}:
      rest
    case False{}:
      k <> rest

def bk.not.by(+id: Nat, +xs: List<&2, Bk>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{Bk{+k, +b}, +rest}:
      bk.not.keep(Nat.is_eq(b, id), k, bk.not.by(id, rest))

def bk.keys(+xs: List<&2, Bk>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{Bk{+k, b}, +rest}:
      k <> bk.keys(rest)

def iv.bc.send(+c: Cl, +ks: List<&2, String>, v: Iv) -> Iv:
  match ks:
    case Nil{}:
      v
    case Con{k, rest}:
      iv.send(c, PlKeys{ks}, 0n, None{}, v)

# the keys a BCAST client is told: in NOLOOP mode, but those it changed
# last
def bc.keys.of(noloop: Bool, +id: Nat, +xs: List<&2, Bk>) -> List<&2, String>:
  match noloop:
    case True{}:
      bk.not.by(id, xs)
    case False{}:
      bk.keys(xs)

def iv.bc.of(m: Maybe<&2, Cl>, +id: Nat, +xs: List<&2, Bk>, v: Iv) -> Iv:
  match m:
    case Some{+c}:
      iv.bc.send(c, bc.keys.of(tk.noloop(cl.tk(c)), id, xs), v)
    case None{}:
      v

def iv.bc.ids(+ids: List<&2, Nat>, +xs: List<&2, Bk>, v: Iv) -> Iv:
  match ids v:
    case Nil{} v0:
      v0
    case Con{+id, +rest} Iv{reg, ev, px, +cs, own, t}:
      iv.bc.ids(rest, xs, iv.bc.of(cls.get(id, cs), id, xs, Iv{reg, ev, px, cs, own, t}))

def iv.bcs(+bs: List<&2, Bc>, v: Iv) -> Iv:
  match bs:
    case Nil{}:
      v
    case Con{Bc{p, +ids, +keys}, +rest}:
      iv.bcs(rest, iv.bc.ids(ids, bk.sorted(keys), v))

def bc.clean(bs: List<&2, Bc>) -> List<&2, Bc>:
  match bs:
    case Nil{}:
      Nil{}
    case Con{Bc{p, ids, keys}, rest}:
      Bc{p, ids, Nil{}} <> bc.clean(rest)

def trk.pfx(+t: Trk) -> List<&2, Bc>:
  match t:
    case TrkOn{tab, keys, items, ids, rds, +pfx, pend, over, mx}:
      pfx
    case TrkOf{+x}:
      trk.pfx(x)

def trk.pfx.clean(t: Trk) -> Trk:
  match t:
    case TrkOn{tab, keys, items, ids, rds, pfx, pend, over, mx}:
      TrkOn{tab, keys, items, ids, rds, bc.clean(pfx), pend, over, mx}
    case TrkOf{x}:
      trk.pfx.clean(x)

def iv.bcast.done(v: Iv) -> Iv:
  match v:
    case Iv{reg, ev, px, cs, own, t}:
      Iv{reg, ev, px, cs, own, trk.pfx.clean(t)}

def iv.bcast(v: Iv) -> Iv:
  match v:
    case Iv{reg, ev, px, cs, own, +t}:
      iv.bcast.done(iv.bcs(trk.pfx(t), Iv{reg, ev, px, cs, own, t}))

def ps.trk.bcast(pb: Ps) -> Ps:
  iv.ps(iv.bcast(iv.of(pb)))

# tracking-table-max-keys (max; 0: no limit): while some client tracks,
# the table evicts keys at random until it holds no more, each key's
# clients told as of a change of it, but under no prefix, at most 100
# keys a tick for each tick in a row that found it over its limit, as
# Redis's trackingLimitUsedSlots bounds its effort; r picks them
def trk.keys(+t: Trk) -> Nat:
  match t:
    case TrkOn{tab, +keys, items, ids, rds, pfx, pend, over, mx}:
      keys
    case TrkOf{+x}:
      trk.keys(x)

def trk.max(+t: Trk) -> Nat:
  match t:
    case TrkOn{tab, keys, items, ids, rds, pfx, pend, over, +mx}:
      mx
    case TrkOf{+x}:
      trk.max(x)

# whether a tick holds the table to its limit: while some client tracks
# and the limit is set, as Redis calls trackingLimitUsedSlots
def trk.over(+t: Trk) -> Bool:
  match t:
    case TrkOn{tab, keys, items, +ids, rds, pfx, pend, over, +mx}:
      Bool.and(Bool.not(List.is_empty(&2, Nat, ids)), Nat.is_lt(0n, mx))
    case TrkOf{+x}:
      trk.over(x)

# the ticks in a row that found the table over its limit
def trk.overn(+t: Trk) -> Nat:
  match t:
    case TrkOn{tab, keys, items, ids, rds, pfx, pend, +over, mx}:
      over
    case TrkOf{+x}:
      trk.overn(x)

# none, as trackingLimitUsedSlots counts them anew when the table is
# within its limit
def trk.rest(t: Trk) -> Trk:
  match t:
    case TrkOn{tab, keys, items, ids, rds, pfx, pend, over, mx}:
      TrkOn{tab, keys, items, ids, rds, pfx, pend, 0n, mx}
    case TrkOf{x}:
      trk.rest(x)

def ps.trk.rest(pb: Ps) -> Ps:
  match pb:
    case Ps{reg, ev, px, cs, own}:
      +c = cs
      Ps{reg, ev, px, cls.trk.put(trk.rest(cls.trk(c)), c), own}
    case PsOf{p}:
      ps.trk.rest(p)

# the keys a tick may evict: 100 for each tick in a row over the limit
def trk.effort(+t: Trk) -> Nat:
  match t:
    case TrkOn{tab, keys, items, ids, rds, pfx, pend, +over, mx}:
      Nat.mul(100n, 1n+over)
    case TrkOf{+x}:
      trk.effort(x)

# the ticks in a row over the limit, after one: one more while the table
# is still over it, none once it is not
def trk.overs(t: Trk) -> Trk:
  match t:
    case TrkOn{tab, +keys, items, ids, rds, pfx, pend, over, +mx}:
      TrkOn{tab, keys, items, ids, rds, pfx, pend, Bool.pick(Nat, Nat.is_lt(mx, keys), 1n+over, 0n), mx}
    case TrkOf{x}:
      trk.overs(x)

def trk.max.put(+n: Nat, t: Trk) -> Trk:
  match t:
    case TrkOn{tab, keys, items, ids, rds, pfx, pend, over, mx}:
      TrkOn{tab, keys, items, ids, rds, pfx, pend, over, n}
    case TrkOf{x}:
      trk.max.put(n, x)

def ps.trk.max.put(+n: Nat, pb: Ps) -> Ps:
  match pb:
    case Ps{reg, ev, px, cs, own}:
      +c = cs
      Ps{reg, ev, px, cls.trk.put(trk.max.put(n, cls.trk(c)), c), own}
    case PsOf{p}:
      ps.trk.max.put(n, p)

def trk.pick(+t: Trk, +r: U32) -> Maybe<&2, String>:
  match t:
    case TrkOn{+tab, keys, items, ids, rds, pfx, pend, over, mx}:
      KV.pick(List<&2, Nat>, tab, r, 0n)
    case TrkOf{+x}:
      trk.pick(x, r)

# one key of the table evicted, picked by r, while it holds more than
# max keys
def iv.evict.at(m: Maybe<&2, String>, v: Iv) -> Iv:
  match m:
    case Some{+k}:
      iv.key(k, 0n, False{}, v)
    case None{}:
      v

def iv.evict.one(+max: Nat, +r: U32, v: Iv) -> Iv:
  match v:
    case Iv{reg, ev, px, cs, own, +t}:
      iv.evict.at(Bool.pick(Maybe<&2, String>, Nat.is_lt(max, trk.keys(t)), trk.pick(t, r), None{}), Iv{reg, ev, px, cs, own, t})

# n keys evicted at most, each picked by a number of its own
def iv.evict(+n: Nat, +max: Nat, +r: U32, v: Iv) -> Iv:
  match n:
    case 0n:
      v
    case 1n+h:
      iv.evict(h, max, KV.mix(r), iv.evict.one(max, r, v))

def ps.trk.overs(pb: Ps) -> Ps:
  match pb:
    case Ps{reg, ev, px, cs, own}:
      +c = cs
      Ps{reg, ev, px, cls.trk.put(trk.overs(cls.trk(c)), c), own}
    case PsOf{p}:
      ps.trk.overs(p)

# over its limit, n keys of the table evicted; within it, the ticks in a
# row over it counted anew (rest: when some were)
def ps.trk.limit.if(on: Bool, rest: Bool, +n: Nat, +max: Nat, +r: U32, pb: Ps) -> Ps:
  match on rest:
    case True{} _:
      ps.trk.overs(iv.ps(iv.evict(n, max, r, iv.of(pb))))
    case False{} True{}:
      ps.trk.rest(pb)
    case False{} False{}:
      pb

def ps.trk.limit(+r: U32, pb: Ps) -> Ps:
  +p = pb
  +t = ps.trk(p)
  +n = trk.keys(t)
  +max = trk.max(t)
  ps.trk.limit.if(Nat.is_lt(max, n), Nat.is_lt(0n, trk.overn(t)), Nat.min(Nat.sub(n, max), trk.effort(t)), max, r, p)

# Keyspace notifications
# ----------------------
# With notify-keyspace-events set, each change a command makes is
# published as Redis's notifyKeyspaceEvent publishes it: the event's name
# to __keyspace@<db>__:<key> (K) and the key to __keyevent@<db>__:<name>
# (E), for the classes the parameter names (g generic, $ strings, l
# lists, s sets, h hashes, z sorted sets, x expired, n new keys). While
# no client has a subscription, or the parameter names no class, nothing
# is published and batches run the fast way; else each command runs on
# its own (Pub/Sub), and its events come from the command, from whether
# it changed anything (its effects), and from what each key it writes
# was before it and is after it (there, gone, or there with its time
# passed): a key it makes is new (n) before its event, a collection it
# empties is deleted (del) after its event, and a key whose time had
# passed and that it replaced or deleted expired (x) before both. Redis
# expires such a key when a read finds it too; here the sweep of expired
# keys deletes it, and its event is published then. Evicted keys (no
# maxmemory here) and missed ones (m) are not published.

def ev.g() -> U32:
  4

def ev.str() -> U32:
  8

def ev.l() -> U32:
  16

def ev.s() -> U32:
  32

def ev.h() -> U32:
  64

def ev.z() -> U32:
  128

def ev.x() -> U32:
  256

def ev.n() -> U32:
  16384

# an event: its class, its name, its key and its database
type Ev is Data:
  Ev{cls: U32, name: String, key: String, db: Nat}

# what a command did to a key of database j, for its events: a write
# (EkW: [expired] [new] name [del]); a store (EkS: [expired], then [new]
# name when the key is there after it, else del when it was there); a
# time set (EkX: [expired], then name when the key is there after it,
# else del); a delete (EkD: [expired] del); an event that comes as it is
# (EkA); the expiry of a key replaced (EkE); a trim (EkL: name when the
# key held a list, then [del])
type Ek is Data:
  EkW{j: Nat, k: String, name: String, cls: U32}
  EkS{j: Nat, k: String, name: String, cls: U32}
  EkX{j: Nat, k: String, name: String}
  EkD{j: Nat, k: String}
  EkA{j: Nat, k: String, name: String, cls: U32}
  EkE{j: Nat, k: String}
  EkL{j: Nat, k: String, name: String}

# a key in ds: gone (0), there (1), or there with its time passed (2)
def ek.state.of(m: Maybe<&2, KV.Item<KV.Val>>, +now: Nat) -> Nat:
  match m:
    case None{}:
      0n
    case Some{KV.Item{v, +x}}:
      Bool.pick(Nat, KV.live(now, x), 1n, 2n)

def ek.state(+j: Nat, +k: String, +ds: R.Ds) -> Nat:
  ek.state.of(ds.entry(j, k, ds), R.ds.now(ds))

# whether a key there in ds at now holds a list
def ek.list.of(m: Maybe<&2, KV.Item<KV.Val>>, +now: Nat) -> Bool:
  match m:
    case Some{KV.Item{KV.VColl{KV.CList{l}}, +x}}:
      KV.live(now, x)
    case _:
      False{}

def ev.one(on: Bool, +cls: U32, +name: String, +k: String, +j: Nat, acc: List<&2, Ev>) -> List<&2, Ev>:
  match on:
    case True{}:
      Ev{cls, name, k, j} <> acc
    case False{}:
      acc

def ek.expired(+a: Nat, +b: Nat) -> Bool:
  Bool.and(Nat.is_eq(a, 2n), Bool.not(Nat.is_eq(b, 2n)))

# a write's events: a the key's state before it, b after it
def ek.write(+a: Nat, +b: Nat, +j: Nat, +k: String, +name: String, +cls: U32, acc: List<&2, Ev>) -> List<&2, Ev>:
  ev.one(Bool.and(Nat.is_eq(a, 1n), Nat.is_eq(b, 0n)), ev.g(), "del", k, j,
    ev.one(True{}, cls, name, k, j,
      ev.one(Bool.and(Bool.not(Nat.is_eq(a, 1n)), Bool.not(Nat.is_eq(b, 0n))), ev.n(), "new", k, j,
        ev.one(ek.expired(a, b), ev.x(), "expired", k, j, acc))))

def ek.store(+a: Nat, +b: Nat, +j: Nat, +k: String, +name: String, +cls: U32, acc: List<&2, Ev>) -> List<&2, Ev>:
  ev.one(Bool.and(Nat.is_eq(a, 1n), Nat.is_eq(b, 0n)), ev.g(), "del", k, j,
    ev.one(Bool.not(Nat.is_eq(b, 0n)), cls, name, k, j,
      ev.one(Bool.and(Bool.not(Nat.is_eq(a, 1n)), Bool.not(Nat.is_eq(b, 0n))), ev.n(), "new", k, j,
        ev.one(ek.expired(a, b), ev.x(), "expired", k, j, acc))))

def ek.time(+a: Nat, +b: Nat, +j: Nat, +k: String, +name: String, acc: List<&2, Ev>) -> List<&2, Ev>:
  ev.one(Bool.and(Nat.is_eq(a, 1n), Nat.is_eq(b, 0n)), ev.g(), "del", k, j,
    ev.one(Bool.not(Nat.is_eq(b, 0n)), ev.g(), name, k, j,
      ev.one(ek.expired(a, b), ev.x(), "expired", k, j, acc)))

def ek.trim(+list: Bool, +b: Nat, +j: Nat, +k: String, +name: String, acc: List<&2, Ev>) -> List<&2, Ev>:
  ev.one(Bool.and(list, Nat.is_eq(b, 0n)), ev.g(), "del", k, j, ev.one(list, ev.l(), name, k, j, acc))

# the events of what a command did to a key, newest first before acc
def ek.evs(e: Ek, +pre: R.Ds, +post: R.Ds, acc: List<&2, Ev>) -> List<&2, Ev>:
  match e:
    case EkW{+j, +k, +name, +cls}:
      ek.write(ek.state(j, k, pre), ek.state(j, k, post), j, k, name, cls, acc)
    case EkS{+j, +k, +name, +cls}:
      ek.store(ek.state(j, k, pre), ek.state(j, k, post), j, k, name, cls, acc)
    case EkX{+j, +k, +name}:
      ek.time(ek.state(j, k, pre), ek.state(j, k, post), j, k, name, acc)
    case EkD{+j, +k}:
      +a = ek.state(j, k, pre)
      +b = ek.state(j, k, post)
      ev.one(Bool.and(Nat.is_eq(a, 1n), Nat.is_eq(b, 0n)), ev.g(), "del", k, j, ev.one(ek.expired(a, b), ev.x(), "expired", k, j, acc))
    case EkA{+j, +k, +name, +cls}:
      Ev{cls, name, k, j} <> acc
    case EkE{+j, +k}:
      ev.one(ek.expired(ek.state(j, k, pre), ek.state(j, k, post)), ev.x(), "expired", k, j, acc)
    case EkL{+j, +k, +name}:
      ek.trim(ek.list.of(ds.entry(j, k, pre), R.ds.now(pre)), ek.state(j, k, post), j, k, name, acc)

def ek.evs.all(es: List<&2, Ek>, +pre: R.Ds, +post: R.Ds, acc: List<&2, Ev>) -> List<&2, Ev>:
  match es:
    case Nil{}:
      acc
    case Con{e, rest}:
      ek.evs.all(rest, pre, post, ek.evs(e, pre, post, acc))

# The names of the events of each write
def ek.push(left: Bool) -> String:
  Bool.pick(String, left, "lpush", "rpush")

def ek.pop(left: Bool) -> String:
  Bool.pick(String, left, "lpop", "rpop")

def ek.zpop(max: Bool) -> String:
  Bool.pick(String, max, "zpopmax", "zpopmin")

def ek.hash(op: R.HWrite) -> String:
  match op:
    case R.HWDel{fs}:
      "hdel"
    case R.HWIncr{f, by}:
      "hincrby"
    case R.HWIncrF{f, by}:
      "hincrbyfloat"
    case _:
      "hset"

def ek.list(op: R.LWrite) -> String:
  match op:
    case R.LWPush{left, xs}:
      ek.push(left)
    case R.LWPushX{left, xs}:
      ek.push(left)
    case R.LWNew{left, xs}:
      ek.push(left)
    case R.LWPop{left}:
      ek.pop(left)
    case R.LWPopN{left, c}:
      ek.pop(left)
    case R.LWSet{i, v}:
      "lset"
    case R.LWBefore{p, v}:
      "linsert"
    case R.LWAfter{p, v}:
      "linsert"
    case R.LWRem{c, v}:
      "lrem"
    case R.LWTrim{a, b}:
      "ltrim"

def ek.mems(op: R.SWrite) -> String:
  match op:
    case R.SWRem{ms}:
      "srem"
    case R.SWPop{r}:
      "spop"
    case R.SWPopN{c, r}:
      "spop"
    case _:
      "sadd"

def ek.zadd(o: R.ZOpts) -> String:
  match o:
    case R.ZOpts{nx, xx, gt, lt, ch, incr}:
      Bool.pick(String, incr, "zincr", "zadd")

def ek.zset(op: R.ZWrite) -> String:
  match op:
    case R.ZWAdd{o, ps}:
      ek.zadd(o)
    case R.ZWNew{o, ps}:
      ek.zadd(o)
    case R.ZWRem{ms}:
      "zrem"
    case R.ZWRemRank{a, b}:
      "zremrangebyrank"
    case R.ZWRemScore{a, b}:
      "zremrangebyscore"
    case R.ZWRemLex{a, b}:
      "zremrangebylex"
    case R.ZWPop{max}:
      ek.zpop(max)
    case R.ZWPopN{max, c}:
      ek.zpop(max)

def ek.sstore(k: R.SetK) -> String:
  match k:
    case R.KInter{}:
      "sinterstore"
    case R.KUnion{}:
      "sunionstore"
    case _:
      "sdiffstore"

def ek.zstore(k: R.ZSetK) -> String:
  match k:
    case R.ZKUnion{o}:
      "zunionstore"
    case R.ZKInter{o}:
      "zinterstore"
    case _:
      "zdiffstore"

# an update's events (SET with a time adds expire after set)
def ek.ttl(t: R.SetTtl, +j: Nat, +k: String) -> List<&2, Ek>:
  match t:
    case R.TAt{x}:
      [EkA{j, k, "expire", ev.g()}]
    case _:
      Nil{}

def ek.upd(+j: Nat, +k: String, op: R.UpdOp) -> List<&2, Ek>:
  match op:
    case R.UGet{o}:
      ek.upd(j, k, o)
    case R.USetNx{v}:
      [EkW{j, k, "set", ev.str()}]
    case R.USet{v, cond, t, name}:
      EkW{j, k, "set", ev.str()} <> ek.ttl(t, j, k)
    case R.UAppend{v}:
      [EkW{j, k, "append", ev.str()}]
    case R.UGetEx{R.XNone{}}:
      Nil{}
    case R.UGetEx{R.XPersist{}}:
      [EkA{j, k, "persist", ev.g()}]
    case R.UGetEx{R.XAt{a, m, v}}:
      [EkX{j, k, "expire"}]
    case R.UGetDel{}:
      [EkD{j, k}]
    case R.UExpire{t, c, name}:
      [EkX{j, k, "expire"}]
    case R.UPersist{}:
      [EkA{j, k, "persist", ev.g()}]
    case R.UIncr{by}:
      [EkW{j, k, "incrby", ev.str()}]
    case R.URange{off, s}:
      [EkW{j, k, "setrange", ev.str()}]
    case R.USetBit{off, on}:
      [EkW{j, k, "setbit", ev.str()}]
    case R.UBitfield{ops}:
      [EkW{j, k, "setbit", ev.str()}]
    case R.UHash{h}:
      [EkW{j, k, ek.hash(h), ev.h()}]
    case R.UList{R.LWTrim{a, b}}:
      [EkL{j, k, "ltrim"}]
    case R.UList{l}:
      [EkW{j, k, ek.list(l), ev.l()}]
    case R.UMems{m}:
      [EkW{j, k, ek.mems(m), ev.s()}]
    case R.UIncrF{by}:
      [EkW{j, k, "incrbyfloat", ev.str()}]
    case R.UZset{z}:
      [EkW{j, k, ek.zset(z), ev.z()}]
    case R.UHll{R.HAdd{es}}:
      [EkW{j, k, "pfadd", ev.str()}]
    case R.UHll{h}:
      Nil{}
    case R.URestore{p, t, rep, ac}:
      Nil{}

# DEL's keys, each deleted
def ek.dels(+j: Nat, ks: List<&2, String>) -> List<&2, Ek>:
  match ks:
    case Nil{}:
      Nil{}
    case Con{k, rest}:
      EkD{j, k} <> ek.dels(j, rest)

# MSET's keys: each set, a key set before in the same MSET not new again
def ek.sets(+j: Nat, ps: List<&2, R.KVPair>, +seen: List<&2, String>) -> List<&2, Ek>:
  match ps:
    case Nil{}:
      Nil{}
    case Con{R.KP{+k, v}, rest}:
      Bool.pick(Ek, S.pub.has(k, seen), EkA{j, k, "set", ev.str()}, EkW{j, k, "set", ev.str()}) <> ek.sets(j, rest, k <> seen)

# the key a pop of the first of keys that is there pops from
def ek.first(ks: List<&2, String>, +j: Nat, +pre: R.Ds) -> Maybe<&2, String>:
  match ks:
    case Nil{}:
      None{}
    case Con{+k, rest}:
      Bool.pick(Maybe<&2, String>, Nat.is_eq(ek.state(j, k, pre), 1n), Some{k}, ek.first(rest, j, pre))

def ek.popped(m: Maybe<&2, String>, +j: Nat, +name: String, +cls: U32) -> List<&2, Ek>:
  match m:
    case Some{k}:
      [EkW{j, k, name, cls}]
    case None{}:
      Nil{}

# SMOVE: srem of its source, then sadd of its destination when the
# member was not in it
def ek.smove(added: Bool, +j: Nat, +d: String) -> List<&2, Ek>:
  match added:
    case True{}:
      [EkW{j, d, "sadd", ev.s()}]
    case False{}:
      Nil{}

# MOVE and COPY, from their effects
def ek.eff(e: A.Eff) -> List<&2, Ek>:
  match e:
    case A.EMove{+k, +s, +d}:
      [EkE{d, k}, EkA{d, k, "new", ev.n()}, EkA{s, k, "move_from", ev.g()}, EkA{d, k, "move_to", ev.g()}]
    case A.ECopy{s, +d, from, +to}:
      [EkE{to, d}, EkA{to, d, "new", ev.n()}, EkA{to, d, "copy_to", ev.g()}]
    case _:
      Nil{}

def ek.ents(es: List<&2, A.Ent>) -> List<&2, Ek>:
  match es:
    case Nil{}:
      Nil{}
    case Con{A.EOne{e}, rest}:
      List.append(&2, Ek, ek.eff(e), ek.ents(rest))
    case Con{A.ETx{xs}, rest}:
      ek.ents(rest)

# SORT with STORE: sortstore when it set its destination, del when it
# deleted it
def ek.sort(o: R.SortO, +j: Nat) -> List<&2, Ek>:
  match o:
    case R.SortStore{d, x}:
      [EkS{j, d, "sortstore", ev.l()}]
    case R.SortO{by, off, cnt, gs, desc, alpha}:
      Nil{}

# a GEO search that stores: georadiusstore (geosearchstore for
# GEOSEARCHSTORE) when it set its destination, del when it deleted it
def ek.geo(m: Maybe<&2, String>, +kind: Nat, +j: Nat) -> List<&2, Ek>:
  match m:
    case Some{d}:
      [EkS{j, d, Bool.pick(String, Nat.is_eq(kind, 5n), "geosearchstore", "georadiusstore"), ev.z()}]
    case None{}:
      Nil{}

# RESTORE's events, from its effects (es): del when it deleted its key (a
# time already past, with REPLACE: ek.del.first); when it restored the
# key, new and restore, with REPLACE (Redis deletes the key it finds,
# its time passed or not, and adds the new one), else [expired] new
# restore (Redis's lookup of the key finds its time passed)
def ek.restore.of(del: Bool, rep: Bool, +j: Nat, +k: String) -> List<&2, Ek>:
  match del rep:
    case True{} _:
      [EkD{j, k}]
    case False{} True{}:
      [EkA{j, k, "new", ev.n()}, EkA{j, k, "restore", ev.g()}]
    case False{} False{}:
      [EkW{j, k, "restore", ev.g()}]

def ek.del.first(+es: List<&2, A.Ent>) -> Bool:
  match es:
    case Con{A.EOne{A.EDb{x, R.Del{ks}}}, rest}:
      True{}
    case _:
      False{}

def ek.restore(op: R.UpdOp, +j: Nat, +k: String, +es: List<&2, A.Ent>) -> List<&2, Ek>:
  match op:
    case R.URestore{p, t, +rep, ac}:
      ek.restore.of(ek.del.first(es), rep, j, k)
    case _:
      Nil{}

# what a command did to each key it wrote (j: its database), in order
def ek.base(+c: R.Cmd, +j: Nat, +pre: R.Ds, +es: List<&2, A.Ent>) -> List<&2, Ek>:
  match c:
    case R.Set{+k, v}:
      [EkW{j, k, "set", ev.str()}]
    case R.IncrBy{+k, by}:
      [EkW{j, k, "incrby", ev.str()}]
    case R.Del{+ks}:
      ek.dels(j, ks)
    case R.MSet{+ps}:
      ek.sets(j, ps, Nil{})
    case R.MSetNx{+ps}:
      ek.sets(j, ps, Nil{})
    case R.Rename{+s, +d, nx}:
      [EkE{j, d}, EkA{j, d, "new", ev.n()}, EkA{j, s, "rename_from", ev.g()}, EkA{j, d, "rename_to", ev.g()}]
    case R.BitOp{op, +d, srcs}:
      [EkS{j, d, "set", ev.str()}]
    case R.LMove{+s, +d, R.LtoL{}}:
      [EkW{j, d, "lpush", ev.l()}, EkW{j, s, "lpop", ev.l()}]
    case R.LMove{+s, +d, R.LtoR{}}:
      [EkW{j, d, "rpush", ev.l()}, EkW{j, s, "lpop", ev.l()}]
    case R.LMove{+s, +d, R.RtoL{}}:
      [EkW{j, d, "lpush", ev.l()}, EkW{j, s, "rpop", ev.l()}]
    case R.LMove{+s, +d, R.RtoR{}}:
      [EkW{j, d, "rpush", ev.l()}, EkW{j, s, "rpop", ev.l()}]
    case R.LMPop{+ks, +left, n}:
      ek.popped(ek.first(ks, j, pre), j, ek.pop(left), ev.l())
    case R.SStore{+k, +d, srcs}:
      [EkS{j, d, ek.sstore(k), ev.s()}]
    case R.SMv{+s, +d, +w}:
      EkW{j, s, "srem", ev.s()} <> ek.smove(smv.added(Some{pre}, j, d, R.smv.member(w)), j, d)
    case R.ZStore{+k, +d, srcs}:
      [EkS{j, d, ek.zstore(k), ev.z()}]
    case R.ZRangeStore{+d, s, q}:
      [EkS{j, d, "zrangestore", ev.z()}]
    case R.ZMPop{+ks, +max, n}:
      ek.popped(ek.first(ks, j, pre), j, ek.zpop(max), ev.z())
    case R.Upd{+k, R.URestore{p, t, rep, ac}}:
      ek.restore(R.URestore{p, t, rep, ac}, j, k, es)
    case R.Upd{+k, +op}:
      ek.upd(j, k, op)
    case R.Own{R.SRestore{+k, op}}:
      ek.restore(op, j, k, es)
    case R.Own{R.SSPop{+k, a}}:
      [EkW{j, k, "spop", ev.s()}]
    case R.Own{R.SSortStore{k, o}}:
      ek.sort(o, j)
    case R.Own{R.SPfMerge{+d, srcs}}:
      [EkW{j, d, "pfadd", ev.str()}]
    case R.Own{R.SGeoStore{+k, a}}:
      ek.geo(R.geo.dst(k, a), k, j)
    case R.Own{o}:
      ek.ents(es)
    case _:
      Nil{}

# a blocking command that ran at once: as its pop
def ek.blk(b: S.Blk, +j: Nat, +pre: R.Ds, +es: List<&2, A.Ent>) -> List<&2, Ek>:
  match b:
    case S.BlkPop{c, form, ms}:
      ek.base(c, j, pre, es)
    case _:
      Nil{}

def ek.of(+c: R.Cmd, +j: Nat, +pre: R.Ds, +es: List<&2, A.Ent>) -> List<&2, Ek>:
  match c:
    case R.Own{R.SBlock{+id, +args}}:
      ek.blk(S.blk.parse(id, args), j, pre, es)
    case _:
      ek.base(c, j, pre, es)

# Publishing: each event of a class the parameter names, to the
# keyspace's channel (K) and to the event's (E)
def ps.pub.only(p: Nat & Ps) -> Ps:
  (n, pb) = p
  pb

def ps.ev.space(on: Bool, +name: String, +key: String, +db: Nat, +me: Nat, pb: Ps) -> Ps:
  match on:
    case True{}:
      ps.pub.only(ps.publish(False{}, "__keyspace@" ++ Nat.show(db) ++ "__:" ++ key, name, me, pb))
    case False{}:
      pb

def ps.ev.event(on: Bool, +name: String, +key: String, +db: Nat, +me: Nat, pb: Ps) -> Ps:
  match on:
    case True{}:
      ps.pub.only(ps.publish(False{}, "__keyevent@" ++ Nat.show(db) ++ "__:" ++ name, key, me, pb))
    case False{}:
      pb

def ps.ev.send(on: Bool, +ev: U32, +name: String, +key: String, +db: Nat, +me: Nat, pb: Ps) -> Ps:
  match on:
    case True{}:
      ps.ev.event(U32.is_ne(U32.and(ev, 2), 0), name, key, db, me, ps.ev.space(U32.is_ne(U32.and(ev, 1), 0), name, key, db, me, pb))
    case False{}:
      pb

def ps.ev1(e: Ev, +me: Nat, pb: Ps) -> Ps:
  match e pb:
    case Ev{+cls, +name, +key, +db} Ps{reg, +ev, px, cs, own}:
      ps.ev.send(U32.is_ne(U32.and(ev, cls), 0), ev, name, key, db, me, Ps{reg, ev, px, cs, own})
    case x PsOf{p}:
      ps.ev1(x, me, p)

# the events published, by the command of the client of id me (0 for the
# server's own: the sweep, the eviction)
def ps.evs(es: List<&2, Ev>, +me: Nat, pb: Ps) -> Ps:
  match es:
    case Nil{}:
      pb
    case Con{e, rest}:
      ps.evs(rest, me, ps.ev1(e, me, pb))

# whether keyspace events are to be sent: a class of them is on (bits 0
# to 14; the bits past theirs say other things, and no event goes out for
# them: trk.bits, dn.bit, mem.bits)
def ps.loud(+pb: Ps) -> Bool:
  match pb:
    case Ps{reg, +ev, px, cs, own}:
      U32.is_ne(U32.and(ev, 32767), 0)
    case PsOf{+p}:
      ps.loud(p)

# whether the effects of a command, of the sweep and of an eviction are
# looked at key by key: keyspace events are to be sent, or the tracking
# has work or some client is in BCAST mode (Ps's bits 22 and 21:
# trk.bits)
def ps.looks(+pb: Ps) -> Bool:
  match pb:
    case Ps{reg, +ev, px, cs, own}:
      U32.is_ne(U32.and(ev, 6324223), 0)
    case PsOf{+p}:
      ps.looks(p)

def ents.some(+es: List<&2, A.Ent>) -> Bool:
  match es:
    case Nil{}:
      False{}
    case Con{e, rest}:
      True{}

# what a command that changed nothing still sends: LTRIM's event, which
# Redis sends whatever it trims
def ek.still(es: List<&2, Ek>) -> List<&2, Ek>:
  match es:
    case Nil{}:
      Nil{}
    case Con{EkL{j, k, name}, rest}:
      EkL{j, k, name} <> ek.still(rest)
    case Con{e, rest}:
      ek.still(rest)

def ek.keep(changed: Bool, es: List<&2, Ek>) -> List<&2, Ek>:
  match changed:
    case True{}:
      es
    case False{}:
      ek.still(es)

# the events of a command (changed: whether its effects es are some),
# with the databases before it (pre) and after it (post)
def ps.cmd.if(on: Bool, +c: R.Cmd, +es: List<&2, A.Ent>, +pre: Maybe<&2, R.Ds>, +post: R.Ds, +me: Nat, pb: Ps) -> Ps:
  match on pre:
    case True{} Some{+d0}:
      ps.evs(List.reverse(&2, Ev, ek.evs.all(ek.keep(ents.some(es), ek.of(c, R.ds.index(d0), d0, es)), d0, post, Nil{})), me, pb)
    case _ _:
      pb

def ps.cmd(+c: R.Cmd, +es: List<&2, A.Ent>, +pre: Maybe<&2, R.Ds>, +post: R.Ds, +me: Nat, pb: Ps) -> Ps:
  +p = pb
  ps.cmd.if(ps.loud(p), c, es, pre, post, me, p)

def ev.expired(+i: Nat, ks: List<&2, String>) -> List<&2, Ev>:
  match ks:
    case Nil{}:
      Nil{}
    case Con{k, rest}:
      Ev{ev.x(), "expired", k, i} <> ev.expired(i, rest)

# the keys the sweep of expired keys deleted (its effects, newest
# first): expired, oldest first
def ev.swept(es: List<&2, A.Ent>, acc: List<&2, Ev>) -> List<&2, Ev>:
  match es:
    case Nil{}:
      acc
    case Con{A.EOne{A.EDb{+i, R.Del{ks}}}, rest}:
      ev.swept(rest, List.append(&2, Ev, ev.expired(i, ks), acc))
    case Con{x, rest}:
      ev.swept(rest, acc)

def ps.swept.if(on: Bool, +es: List<&2, A.Ent>, pb: Ps) -> Ps:
  match on:
    case True{}:
      ps.evs(ev.swept(es, Nil{}), 0n, pb)
    case False{}:
      pb

def ps.swept(+es: List<&2, A.Ent>, pb: Ps) -> Ps:
  +p = pb
  ps.swept.if(ps.loud(p), es, p)

# a batch on the general way so far: its replies (newest first), the
# effects so far (newest first; the server without an append-only file
# drops them), the connection, the server, the databases, the clients
# that wait and those unblocked meanwhile (newest first), the clients
# with a transaction or watched keys, and Pub/Sub's state; or a batch
# whose client now waits (LHeld: the last of the clients that wait)
type LRun is Data:
  LRun{rs: List<&2, R.Reply>, es: List<&2, A.Ent>, conn: S.Conn, srv: S.Srv, ds: R.Ds, ws: Waits, up: List<&2, Up>, tx: Tx, pb: Ps}
  LHeld{g: LRun}

# a group so far: its answers (newest first), the effects of its batches
# (newest first), the server's state, the databases, the clients that
# wait and those unblocked meanwhile, whose batches go on at its end
# (newest first), the clients with a transaction or watched keys, and
# Pub/Sub's state
type Grp is Data:
  Grp{outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, srv: S.Srv, ds: R.Ds, ws: Waits, up: List<&2, Up>, tx: Tx, pb: Ps}

# a command's replies, after it changed its client's protocol (HELLO,
# RESET) or not: a change is a switch (R.RSw) of its replies, the
# protocol of those after them in the batch (resp.bend, encode_as)
def bg.sw(ch: Bool, +r3: Bool, rs1: List<&2, R.Reply>) -> List<&2, R.Reply>:
  match ch:
    case True{}:
      [R.RSw{r3, rs1}]
    case False{}:
      rs1

def bg.done(+r0: Bool, d: S.Logged, p: Pre, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, ws: Waits, up: List<&2, Up>, tx: Tx, pb: Ps) -> LRun:
  match d p:
    case S.Logged{+rs1, e, +conn, srv, ds} Pre{+code, xs}:
      +ys = gen.errs(xs, rs1, code)
      +r3 = S.conn.r3(conn)
      LRun{List.reverse.go(&2, R.Reply, bg.sw(Bool.xor(r0, r3), r3, rs1), rs), A.ents.onto(e, es), conn, gen.count(srv, code, ys), ds, ws, up, tx, pb}

# A call that runs while its client's replies are held back has its reply
# counted as Redis has it. A command of the database runs with them on,
# for its reply, which is counted and dropped (its client gets none), the
# connection after it being the one its run with them held back gives
# (S.next_conn: the replies are all that the mode changes); its run is its
# only one, so the databases go on unshared. A command of the connection
# or of the server runs as it is (CLIENT REPLY ON and RESET answer all the
# same), its reply as Redis has it taken from S.own_reply before.
def bg.held(d: S.Logged, conn: S.Conn, +code: Nat, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, ws: Waits, up: List<&2, Up>, tx: Tx, pb: Ps) -> LRun:
  match d:
    case S.Logged{+rs1, e, c1, srv, ds}:
      LRun{rs, A.ents.onto(e, es), conn, gen.count(srv, code, R.errs.zip(rs1, [code], Nil{})), ds, ws, up, tx, pb}

def bg.held.k(+k: S.Role, +c: R.Cmd, +code: Nat, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, +conn: S.Conn, +srv: S.Srv, ds: R.Ds, ws: Waits, up: List<&2, Up>, tx: Tx, pb: Ps) -> LRun:
  match k:
    case S.KSess{+o}:
      +d = ds
      +p = gen.pre.own(o, code, conn, srv, d)
      bg.done(S.conn.r3(conn), S.run_log(conn, srv, B.Mixed{[c], Nil{}}, d), p, rs, es, ws, up, tx, pb)
    case _:
      bg.held(S.run_log(S.conn.on(conn), srv, B.Mixed{[c], Nil{}}, ds), S.next_conn(False{}, c, conn, srv), code, rs, es, ws, up, tx, pb)

def bg.run.go(held: Bool, +ok: Bool, +k: S.Role, +c: R.Cmd, +code: Nat, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, +conn: S.Conn, +srv: S.Srv, ds: R.Ds, ws: Waits, up: List<&2, Up>, tx: Tx, pb: Ps) -> LRun:
  match held:
    case True{}:
      bg.held.k(k, c, code, rs, es, conn, srv, ds, ws, up, tx, pb)
    case False{}:
      bg.done(S.conn.r3(conn), S.run_log(conn, srv, B.Mixed{[c], Nil{}}, ds), gen.pre(ok, c, code), rs, es, ws, up, tx, pb)

# a command run while some client has a transaction or watches keys, or
# keyspace events are to be sent: its effects touch the keys watched
# (Touches), and its events are published (Keyspace notifications), with
# the databases before it and after
def bg.touched.of(rs: List<&2, R.Reply>, es: List<&2, A.Ent>, conn: S.Conn, srv: S.Srv, ds: R.Ds, ws: Waits, up: List<&2, Up>, tx: Tx, p: List<&2, R.Reply> & Ps) -> LRun:
  (own, pb) = p
  LRun{own.under(own, rs), es, conn, srv, ds, ws, up, tx, pb}

def bg.touched(+pre: Maybe<&2, R.Ds>, +c: R.Cmd, es: List<&2, A.Ent>, g: LRun) -> LRun:
  match g:
    case LRun{rs, +e1, +conn, srv, +ds, ws, up, tx, pb}:
      +me = S.conn.id(conn)
      bg.touched.of(rs, List.append(&2, A.Ent, e1, es), conn, srv, ds, ws, up, touch.by(c, tx, e1, pre, ds), ps.own.take(ps.cmd(c, e1, pre, ds, me, ps.trk.cmd(c, e1, pre, ds, me, pb))))
    case LHeld{h}:
      LHeld{h}

def bg.run.tx(on: Bool, held: Bool, +ok: Bool, +k: S.Role, +c: R.Cmd, +code: Nat, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, +conn: S.Conn, +srv: S.Srv, ds: R.Ds, ws: Waits, up: List<&2, Up>, tx: Tx, pb: Ps) -> LRun:
  match on:
    case False{}:
      bg.run.go(held, ok, k, c, code, rs, es, conn, srv, ds, ws, up, tx, pb)
    case True{}:
      +d0 = ds
      bg.touched(Some{d0}, c, es, bg.run.go(held, ok, k, c, code, rs, Nil{}, conn, srv, d0, ws, up, tx, pb))

def bg.run(held: Bool, +ok: Bool, +k: S.Role, +c: R.Cmd, +code: Nat, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, +conn: S.Conn, +srv: S.Srv, ds: R.Ds, ws: Waits, up: List<&2, Up>, tx: Tx, pb: Ps) -> LRun:
  +t = tx
  +p = pb
  bg.run.tx(Bool.or(tx.on(t), ps.looks(p)), held, ok, k, c, code, rs, es, conn, srv, ds, ws, up, t, p)

# OBJECT FREQ and IDLETIME answered from the key's word (Access): the
# session, which is proved, answers them as a key's that no command used
# since the server's start (a word is the runtime's alone, no law reads
# it); its reply, when an integer (the key there, the policy of the kind
# it asks), is made again from the key's word
def bg.obj.rs(+sub: Nat, +k: String, +rs: List<&2, R.Reply>, +srv: S.Srv, +now: Nat) -> List<&2, R.Reply>:
  match rs:
    case Con{R.RInt{n}, +rest}:
      S.obj.use(sub, Mem.cell(KV.hash(k)), now, I.info.start(S.srv.info(srv)), S.mm.lfu(S.srv.mm(srv)), S.mm.lfd(S.srv.mm(srv))) <> rest
    case _:
      rs

def bg.obj.of(+sub: Nat, +k: String, g: LRun) -> LRun:
  match g:
    case LRun{+rs, es, conn, +srv, +ds, ws, up, tx, pb}:
      LRun{bg.obj.rs(sub, k, rs, srv, R.ds.now(ds)), es, conn, srv, ds, ws, up, tx, pb}
    case LHeld{h}:
      LHeld{h}

# whether an OBJECT subcommand reads the key's word: FREQ (2) and
# IDLETIME (5), not ENCODING nor REFCOUNT
def bg.obj.uses(+sub: Nat) -> Bool:
  Bool.or(Nat.is_eq(sub, 2n), Nat.is_eq(sub, 5n))

def bg.obj.if(uses: Bool, +sub: Nat, +k: String, g: LRun) -> LRun:
  match uses:
    case True{}:
      bg.obj.of(sub, k, g)
    case False{}:
      g

def bg.obj(+c: R.Cmd, g: LRun) -> LRun:
  match c:
    case R.Own{R.SObject{+sub, +k}}:
      bg.obj.if(bg.obj.uses(sub), sub, k, g)
    case _:
      g

# RESTORE with IDLETIME or FREQ (R.SRestore; ac: 1 + f for FREQ f, 257 +
# s for IDLETIME, R.rs.idle.at): run with its effects apart (e1, then put
# before es) and, when it restored its key (its effect is the RESTORE's),
# the key's word set as Redis's objectSetLRUOrLFU sets a value's 24 bits:
# under an LFU policy FREQ's counter at the minute of now; under any other
# IDLETIME's second, s seconds before the LRU clock's second c, or, past
# the clock's 0, that less one, mod 2^24 (lru_abs + LRU_CLOCK_MAX, cut to
# 24 bits: s of 2^24 and more keeps its remainder mod 2^24 alone); the
# other option is ignored
def bg.rs.made(+es: List<&2, A.Ent>) -> Bool:
  match es:
    case Con{A.EOne{A.EDb{x, R.Upd{k, R.URestore{p, t, rep, ac}}}}, rest}:
      True{}
    case _:
      False{}

def bg.rs.lru(+s: Nat, +now: Nat) -> U32:
  +c = U32.to_nat(U32.and(S.acc.secs(now), 16777215))
  +l = Bool.pick(Nat, Nat.is_lt(s, 16777216n), Bool.pick(Nat, Nat.is_le(s, c), Nat.sub(c, s), Nat.sub(Nat.add(c, 16777215n), s)), Nat.mod(Nat.sub(Nat.add(c, 33554431n), s), 16777216n))
  U32.or(U32.from_nat(l), 16777216)

# the word, 0 for none
def bg.rs.word(+lfu: Bool, +ac: Nat, +now: Nat) -> U32:
  match lfu:
    case True{}:
      Bool.pick(U32, Bool.and(Nat.is_lt(0n, ac), Nat.is_le(ac, 256n)), S.lfu.word(S.acc.min(now), U32.from_nat(Nat.sub(ac, 1n))), 0)
    case False{}:
      Bool.pick(U32, Nat.is_lt(256n, ac), bg.rs.lru(Nat.sub(ac, 257n), now), 0)

def bg.cell.of(done: Bool, g: LRun) -> LRun:
  match done:
    case True{}:
      g
    case False{}:
      g

# g after a write of w in the cell of hash h, when set (its token
# compared, so that the write is made)
def bg.cell.if(set: Bool, +h: U32, +w: U32, g: LRun) -> LRun:
  match set:
    case True{}:
      bg.cell.of(U32.is_eq(Mem.touch(0, h, w), 0), g)
    case False{}:
      g

def bg.rs.cell(+made: Bool, +key: String, +w: U32, g: LRun) -> LRun:
  bg.cell.if(Bool.and(made, U32.is_ne(w, 0)), KV.hash(key), w, g)

def bg.restored(+key: String, +ac: Nat, es: List<&2, A.Ent>, g: LRun) -> LRun:
  match g:
    case LRun{rs, +e1, conn, srv, +ds, ws, up, tx, +pb}:
      bg.rs.cell(bg.rs.made(e1), key, bg.rs.word(ps.lfu(pb), ac, R.ds.now(ds)), LRun{rs, List.append(&2, A.Ent, e1, es), conn, srv, ds, ws, up, tx, pb})
    case LHeld{h}:
      LHeld{h}

# a command run the general way, in EXEC too; INFO with the tracking's
# counts (trk.info) set before it runs
def bg.cmd.run(held: Bool, +ok: Bool, +k: S.Role, +c: R.Cmd, +code: Nat, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, +conn: S.Conn, +srv: S.Srv, ds: R.Ds, ws: Waits, up: List<&2, Up>, tx: Tx, pb: Ps) -> LRun:
  match c:
    case R.Own{R.SRestore{+key, R.URestore{p, t, rep, +ac}}}:
      bg.restored(key, ac, es, bg.run(held, ok, k, c, code, rs, Nil{}, conn, srv, ds, ws, up, tx, pb))
    case R.Own{R.SInfo{a}}:
      +p = pb
      bg.run(held, ok, k, c, code, rs, es, conn, trk.info(ps.trk(p), srv), ds, ws, up, tx, p)
    case _:
      bg.run(held, ok, k, c, code, rs, es, conn, srv, ds, ws, up, tx, pb)

# one command, unless a QUIT before it dropped it
def bg.one.q(q: Bool, +c: R.Cmd, +code: Nat, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, +conn: S.Conn, +srv: S.Srv, ds: R.Ds, ws: Waits, up: List<&2, Up>, tx: Tx, pb: Ps) -> LRun:
  match q:
    case True{}:
      LRun{rs, es, conn, srv, ds, ws, up, tx, pb}
    case False{}:
      +k = S.kind(c)
      +ok = S.may(k, conn, srv)
      bg.obj(c, bg.cmd.run(gen.muted(ok, code, conn), ok, k, c, code, rs, es, conn, srv, ds, ws, up, tx, pb))

def bg.one(+c: R.Cmd, +code: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, +conn, srv, ds, ws, up, tx, pb}:
      bg.one.q(S.conn.quit(conn), c, code, rs, es, conn, srv, ds, ws, up, tx, pb)
    case LHeld{h}:
      LHeld{h}

# a reply's error, counted for the call of code k
def bg.errs(srv: S.Srv, +code: Nat, +r: R.Reply) -> S.Srv:
  match r:
    case R.RError{+m}:
      S.srv.errs(srv, [R.Erred{code, m}])
    case _:
      srv

# a client served: the pop made on its database, its reply shaped as its
# command's (counted when it is an error), its effects, its batch to go on
# a pop's effects, which touch the keys watched (each key popped from
# was there)
# a pop's events too (Keyspace notifications), with the databases
# before it (pre) and its command (pc)
def bg.popped.put(+e: List<&2, A.Eff>, +ds: R.Ds, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, conn: S.Conn, srv: S.Srv, ws: Waits, up: List<&2, Up>, tx: Tx, pb: Ps, +pc: R.Cmd, +pre: R.Ds) -> LRun:
  LRun{rs, A.ents.onto(e, es), conn, srv, ds, ws, up, touch.effs(tx, e, None{}, ds), ps.cmd(pc, A.ents.of(e), Some{pre}, ds, 0n, pb)}

# a client served, with the invalidations its pop made for it after its
# reply (ps.trk.served)
def bg.popped.up(d: Pd, +back: Chan(Ans), +c0: S.Conn, c1: S.Conn, +y: R.Reply, cmds: List<&2, R.Cmd>, codes: List<&2, Nat>, av: Av, +e: List<&2, A.Eff>, +ds: R.Ds, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, conn: S.Conn, srv: S.Srv, ws: Waits, up: List<&2, Up>, tx: Tx, +pc: R.Cmd, +pre: R.Ds) -> LRun:
  match d:
    case Pd{pend, pb}:
      bg.popped.put(e, ds, rs, es, conn, srv, ws, Up{back, c1, List.append(&2, R.Reply, pend, S.put(S.say(S.conn.mode(c0), y), Nil{})), cmds, codes, av} <> up, tx, pb, pc, pre)

def bg.popped(w: Waits, r: R.Reply & (List<&2, A.Eff> & R.Ds), rs: List<&2, R.Reply>, es: List<&2, A.Ent>, +conn: S.Conn, srv: S.Srv, ws: Waits, up: List<&2, Up>, tx: Tx, pb: Ps, +pc: R.Cmd, +pre: R.Ds) -> LRun:
  match w:
    case WaitOn{+id, back, +c0, c1, +b, argv, +code, db, until, cmds, codes, av, rest}:
      (x, q) = r
      (e, ds) = q
      +y = S.blk.shape(S.blk.form(b), x)
      +left = ws
      bg.popped.up(ps.trk.served(pc, S.blk.form(b), Bool.not(R.r_is_err(y)), id, S.conn.id(conn), pb), back, c0, c1, y, cmds, codes, av, e, ds, rs, es, conn, waits.count(left, S.srv.served(bg.errs(srv, code, y), id)), left, up, tx, pc, pre)
    case WaitNone{}:
      (x, q) = r
      (e, ds) = q
      LRun{rs, es, conn, srv, ds, ws, up, tx, pb}

def bg.pop(w: Waits, +k: String, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, ws, up, tx, pb}:
      +x = w
      +pc = S.blk.at(waits.blk(x), k)
      +d0 = R.ds.focus(waits.db(x), ds)
      bg.popped(x, A.act(R.ARun{pc}, d0), rs, es, conn, srv, ws, up, tx, pb, pc, d0)
    case LHeld{h}:
      LHeld{h}

# the clients served while one is ready: the first that is, each round
# (fuel: a client served each round, so one round for each, and one more)
type Sv is Data:
  Sv{more: Bool, g: LRun}

def bg.serve.one(m: Found, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, conn: S.Conn, srv: S.Srv, ds: R.Ds, up: List<&2, Up>, tx: Tx, pb: Ps) -> Sv:
  match m:
    case Found{w, +k, ws}:
      Sv{True{}, bg.pop(w, k, LRun{rs, es, conn, srv, ds, ws, up, tx, pb})}
    case NotFound{ws}:
      Sv{False{}, LRun{rs, es, conn, srv, ds, ws, up, tx, pb}}

def bg.serve.go(f: Nat, v: Sv) -> LRun:
  match f v:
    case 1n+h Sv{True{}, LRun{rs, es, conn, srv, +ds, +ws, up, tx, pb}}:
      bg.serve.go(h, bg.serve.one(waits.find(ws, waits.ready(ds, ws), ds, WaitNone{}), rs, es, conn, srv, ds, up, tx, pb))
    case _ Sv{more, g0}:
      g0

# the batch's database in focus again
def bg.refocus(g: LRun) -> LRun:
  match g:
    case LRun{rs, es, +conn, srv, ds, ws, up, tx, pb}:
      LRun{rs, es, conn, srv, R.ds.focus(S.conn.db(conn), ds), ws, up, tx, pb}
    case LHeld{h}:
      LHeld{h}

# after a command, the clients that wait served while one is ready
def bg.serve(g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, WaitNone{}, up, tx, pb}:
      LRun{rs, es, conn, srv, ds, WaitNone{}, up, tx, pb}
    case LRun{rs, es, conn, srv, ds, +ws, up, tx, pb}:
      bg.refocus(bg.serve.go(1n+waits.length(ws, 0n), Sv{True{}, LRun{rs, es, conn, srv, ds, ws, up, tx, pb}}))
    case LHeld{h}:
      LHeld{h}

# after a command c, the clients that wait served while one is ready,
# when some client waits and c may have made one ready (stir: Heeded
# keys): before it none was, and a command that does not stir leaves
# each entry they wait on as it was. Whether c stirs is asked before c
# runs, which changes neither the clients that wait nor the heeded keys:
# c is lent to the check, then given to the run (bg.one.serve)
def bg.serve.if(on: Bool, g: LRun) -> LRun:
  match on:
    case True{}:
      bg.serve(g)
    case False{}:
      g

def bg.stir(+c: R.Cmd, +g: LRun) -> Bool:
  match g:
    case LRun{rs, es, conn, srv, ds, WaitNone{}, up, tx, pb}:
      False{}
    case LRun{rs, es, conn, srv, ds, ws, up, tx, +pb}:
      ps.heed.stir(c, pb)
    case LHeld{h}:
      False{}

def bg.one.serve(stir: Bool, c: R.Cmd, code: Nat, g: LRun) -> LRun:
  bg.serve.if(stir, bg.one(c, code, g))

# the size of a blocking command's arguments, its name's too: Redis's
# argv-mem of a client while it waits
def wait.argv(+c: R.Cmd) -> Nat:
  match c:
    case R.Own{R.SBlock{+i, args}}:
      S.cl.argv(args, String.length(R.stat.name(i)))
    case _:
      0n

# a blocking command that finds nothing: its client waits, the call
# counted now, its channel marked with the blocking command (CLIENT LIST's
# cmd while it waits, as Redis's last command)
def bg.wait(+id: Nat, +back: Chan(Ans), b: S.Blk, +c: R.Cmd, +code: Nat, rest: List<&2, R.Cmd>, more: List<&2, Nat>, av: Av, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, +conn, +srv, +ds, ws, up, tx, pb}:
      +x = b
      +u = S.blk.until(R.ds.now(ds), S.blk.ms(x))
      +ws2 = waits.add(ws, WaitOn{id, Chan.mark(Ans, back, U32.from_nat(code), R.ds.now(ds)), conn, S.next_conn(False{}, c, conn, srv), x, wait.argv(c), code, S.conn.db(conn), u, rest, more, av, WaitNone{}})
      LHeld{LRun{rs, es, conn, waits.count(ws2, gen.count(S.srv.blk(srv), code, Nil{})), ds, ws2, up, tx, ps.heed.add(S.blk.keys(x), u, pb)}}
    case LHeld{h}:
      LHeld{h}

# CLIENT UNBLOCK: the client of the id, if it waits, unblocked with a
# null array (0 for WAIT: S.blk.late) or an UNBLOCKED error, its call
# failed (an error reply's counted as one); the command answers 1, or 0
# when no client of the id waits. Redis counts CLIENT UNBLOCK's own call failed when it sends the
# error: the error reply came while it ran (incrCommandStatsOnError).
def unblock.msg() -> String:
  "UNBLOCKED client unblocked via CLIENT UNBLOCK"

def unblock.reply(+err: Bool, +b: S.Blk) -> R.Reply:
  Bool.pick(R.Reply, err, R.RError{unblock.msg()}, S.blk.late(b))

def unblock.stat(+err: Bool, +code: Nat, +own: Nat, srv: S.Srv) -> S.Srv:
  match err:
    case True{}:
      S.srv.failed(S.srv.errs(srv, [R.Erred{code, unblock.msg()}]), own)
    case False{}:
      S.srv.failed(srv, code)

def bg.unblocked(p: Waits & Waits, +err: Bool, +code: Nat, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, conn: S.Conn, srv: S.Srv, ds: R.Ds, up: List<&2, Up>, tx: Tx, pb: Ps) -> LRun:
  (w, +ws) = p
  match w:
    case WaitOn{id, back, +c0, c1, +b, argv, +wc, db, until, cmds, codes, av, rest}:
      bg.one(R.Own{R.SReply{R.RInt{R.IPos{1n}}}}, code, LRun{rs, es, conn, waits.count(ws, S.srv.served(unblock.stat(err, wc, code, srv), id)), ds, ws, Up{back, c1, S.put(S.say(S.conn.mode(c0), unblock.reply(err, b)), Nil{}), cmds, codes, av} <> up, tx, pb})
    case WaitNone{}:
      bg.one(R.Own{R.SReply{R.RInt{R.IPos{0n}}}}, code, LRun{rs, es, conn, srv, ds, ws, up, tx, pb})

# a client the pause holds back is not unblocked (The pause)
def bg.unblock.at(held: Bool, +n: Nat, +err: Bool, +code: Nat, g: LRun) -> LRun:
  match held g:
    case True{} g0:
      bg.one(R.Own{R.SReply{R.RInt{R.IPos{0n}}}}, code, g0)
    case False{} LRun{rs, es, conn, srv, ds, +ws, up, tx, pb}:
      bg.unblocked(waits.take(ws, waits.is(n, ws), n, WaitNone{}), err, code, rs, es, conn, srv, ds, up, tx, pb)
    case False{} LHeld{h}:
      LHeld{h}

def bg.unblock(+n: Nat, +err: Bool, +code: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, +ws, up, tx, pb}:
      bg.unblock.at(Bool.or(waits.held.is(n, ws), waits.saving.is(n, ws)), n, err, code, LRun{rs, es, conn, srv, ds, ws, up, tx, pb})
    case LHeld{h}:
      LHeld{h}

# what the shell does with a command: run it as the session runs it, make
# its client wait (a blocking command that would), unblock a client
# (CLIENT UNBLOCK), or act on its client's transaction (Transactions):
# open one (MULTI), refuse a MULTI in one, run one (EXEC), abort one (an
# EXEC refused, with why), drop one (DISCARD), watch keys, refuse a WATCH
# in one, unwatch, end one with the connection's state (RESET), queue a
# command in one, or refuse one queued and flag the transaction; or run
# a command of Pub/Sub, answer a PING of a client with a subscription, or
# refuse any other command of such a client (Pub/Sub); make the client a
# monitor, or refuse a monitor a command that reads or writes keys (in
# MULTI, flagging the transaction: MONITOR); or start a rewrite of the
# append-only file (BGREWRITEAOF: The rewrite of the append-only file); or
# refuse a command past maxmemory (Memory: in MULTI, flagging the
# transaction); or hold a command back while clients are paused (The
# pause); stop the server (SHUTDOWN, after a save or not), or refuse
# SHUTDOWN and SAVE in MULTI (SHUTDOWN); save (SAVE), or save once the
# group has run (FLUSHALL with save points: The RDB file); a command that
# does not run (after a QUIT, or before the client authenticates) runs as
# the session runs it.
type Sh is Data:
  ShRun{}
  ShWait{b: S.Blk}
  ShUnblock{id: Nat, err: Bool}
  ShMulti{}
  ShNested{}
  ShExec{}
  ShAbort{why: String}
  ShDiscard{}
  ShWatch{keys: List<&2, String>}
  ShWatchIn{}
  ShUnwatch{}
  ShReset{}
  ShQueue{}
  ShRefuse{}
  ShPub{op: R.PubOp}
  ShPing{m: String}
  ShDeny{name: String}
  ShClient{op: R.ClOp, argv: Nat}
  ShConn{}
  ShMonitor{}
  ShMonDeny{inm: Bool}
  ShRewrite{}
  ShOom{inm: Bool}
  ShPause{}
  ShDown{save: Bool, nosave: Bool, force: Bool}
  ShNoMulti{}
  ShSave{}
  ShFlush{}

def sh.blk(b: S.Blk, +ds: R.Ds) -> Sh:
  +x = b
  Bool.pick(Sh, S.blk.waits(x, R.ds.focused(ds)), ShWait{x}, ShRun{})

# why an EXEC refused aborts its transaction: its error, without ERR (as
# Redis words EXECABORT's reason)
def abort.why(+m: String) -> String:
  Bool.pick(String, String.eq(String.take(m, 4n), "ERR "), String.drop(m, 4n), m)

# the error past maxmemory (Redis's shared.oomerr)
def oom.msg() -> String:
  "OOM command not allowed when used memory > 'maxmemory'."

def sh.refused(+c: R.Cmd, +code: Nat) -> Sh:
  match c:
    case R.Own{R.SBad{R.RError{+m}}}:
      Bool.pick(Sh, Nat.is_eq(R.code.key(code), R.stat.top(162n)), ShAbort{abort.why(m)}, ShRefuse{})
    case _:
      ShRefuse{}

# EXEC refused (its arguments, NOAUTH) aborts the transaction, in MULTI
# or not, as Redis's rejectCommand does
def sh.abort.if(hit: Bool, +m: String) -> Sh:
  match hit:
    case True{}:
      ShAbort{abort.why(m)}
    case False{}:
      ShRun{}

# SHUTDOWN stops the server, after a save when it is to save one (SAVE,
# or save points without NOSAVE: bg.down), which FORCE ignores the
# failure of; SAVE saves (The RDB file); the other administrative
# commands run as the session runs them
def sh.down(+sd: R.Sd) -> Sh:
  match sd:
    case R.Sd{+nosave, +save, now, +force, abort}:
      ShDown{save, nosave, force}
    case R.SdBad{}:
      ShDown{False{}, False{}, False{}}

def sh.admin(+k: Nat, +a: List<&2, String>) -> Sh:
  match k:
    case 4n:
      sh.down(R.sd.flags(a))
    case 15n:
      ShSave{}
    case _:
      ShRun{}

# a command of a client with no open transaction, that may run
def sh.plain(+c: R.Cmd, +code: Nat, +ds: R.Ds) -> Sh:
  match c:
    case R.Own{R.SBlock{+i, args}}:
      sh.blk(S.blk.parse(i, args), ds)
    case R.Own{R.SUnblock{+n, +e}}:
      ShUnblock{n, e}
    case R.Own{R.SMulti{}}:
      ShMulti{}
    case R.Own{R.SWatch{ks}}:
      ShWatch{ks}
    case R.Own{R.SUnwatch{}}:
      ShUnwatch{}
    case R.Own{R.SReset{}}:
      ShReset{}
    case R.Own{R.SPub{+k, a}}:
      ShPub{R.pub.op(k, a)}
    case R.Own{R.SClient{+k, +a}}:
      ShClient{R.client.op(k, a), S.cl.argv(a, 10n)}
    case R.Own{R.SClientSetName{n}}:
      ShConn{}
    case R.Own{R.SHello{a}}:
      ShConn{}
    case R.Own{R.SSelect{d}}:
      ShConn{}
    case R.Own{R.SMonitor{}}:
      ShMonitor{}
    case R.Own{R.SRewrite{}}:
      ShRewrite{}
    case R.Own{R.SAdmin{+k, +a}}:
      sh.admin(k, a)
    case R.Own{R.SFlushAll{}}:
      ShFlush{}
    case R.Own{R.SBad{R.RError{+m}}}:
      sh.abort.if(Nat.is_eq(R.code.key(code), R.stat.top(162n)), m)
    case _:
      ShRun{}

# a command of a client with no open transaction, that may not run
def sh.noauth(+c: R.Cmd) -> Sh:
  match c:
    case R.Own{R.SExec{}}:
      ShAbort{"NOAUTH Authentication required."}
    case _:
      ShRun{}

# a command of a client in MULTI that may run: refused (its code says
# the parser refused it) or queued
def sh.queue.if(refused: Bool, +c: R.Cmd, +code: Nat) -> Sh:
  match refused:
    case True{}:
      sh.refused(c, code)
    case False{}:
      ShQueue{}

def sh.queue(+c: R.Cmd, +code: Nat) -> Sh:
  sh.queue.if(Nat.is_eq(R.code.class(code), 1n), c, code)

# a command of a client in MULTI (may: whether it may run)
def sh.multi(may: Bool, +c: R.Cmd, +code: Nat) -> Sh:
  match may c:
    case _ R.Own{R.SQuit{}}:
      ShRun{}
    case _ R.Own{R.SReset{}}:
      ShReset{}
    case False{} R.Own{R.SExec{}}:
      ShAbort{"NOAUTH Authentication required."}
    case False{} _:
      ShRefuse{}
    case True{} R.Own{R.SMulti{}}:
      ShNested{}
    case True{} R.Own{R.SExec{}}:
      ShExec{}
    case True{} R.Own{R.SDiscard{}}:
      ShDiscard{}
    case True{} R.Own{R.SWatch{ks}}:
      ShWatchIn{}
    case True{} _:
      sh.queue(c, code)

# a command of a client with a subscription, that may run: one the
# parser refused (its name, the number of its arguments) answers its own
# error, as do (P|S)SUBSCRIBE, (P|S)UNSUBSCRIBE, PING, QUIT and RESET
# when the parser failed them; any other is refused (EXEC aborts its
# transaction with why)
def sh.deny(+code: Nat) -> Sh:
  +key = R.code.key(code)
  Bool.pick(Sh, Bool.or(Nat.is_eq(R.code.class(code), 1n), sub.allowed(key)), ShRun{}, ShDeny{R.stat.name(key)})

def sh.echo(ping: Bool, m: String, +code: Nat) -> Sh:
  match ping:
    case True{}:
      ShPing{m}
    case False{}:
      sh.deny(code)

# (P|S)SUBSCRIBE and (P|S)UNSUBSCRIBE (kinds 0 to 5) run; PUBLISH and
# PUBSUB are refused
def sh.subop(on: Bool, +k: Nat, a: List<&2, String>, +code: Nat) -> Sh:
  match on:
    case True{}:
      ShPub{R.pub.op(k, a)}
    case False{}:
      sh.deny(code)

def sh.sub(+c: R.Cmd, +code: Nat) -> Sh:
  match c:
    case R.Own{R.SPub{+k, a}}:
      sh.subop(Nat.is_lt(k, 6n), k, a, code)
    case R.Ping{}:
      ShPing{""}
    case R.Echo{m}:
      sh.echo(Nat.is_eq(R.code.key(code), R.stat.top(1n)), m, code)
    case R.Own{R.SQuit{}}:
      ShRun{}
    case R.Own{R.SReset{}}:
      ShReset{}
    case R.Own{R.SExec{}}:
      ShAbort{sub.deny("exec")}
    case _:
      sh.deny(code)

# a command of a client that may run it, in MULTI or not
def sh.in(inm: Bool, +c: R.Cmd, +code: Nat, +ds: R.Ds) -> Sh:
  match inm:
    case True{}:
      sh.multi(True{}, c, code)
    case False{}:
      sh.plain(c, code, ds)

# a command of a monitor that reads or writes keys, or may be replicated,
# is refused once the parser's checks passed, as Redis refuses it to a
# replica (processCommand), before it is queued in MULTI
def sh.mon(refused: Bool, inm: Bool, +c: R.Cmd, +code: Nat, +ds: R.Ds) -> Sh:
  match refused:
    case True{}:
      ShMonDeny{inm}
    case False{}:
      sh.in(inm, c, code, ds)

def sh.of.noauth(inm: Bool, +c: R.Cmd, +code: Nat) -> Sh:
  match inm:
    case True{}:
      sh.multi(False{}, c, code)
    case False{}:
      sh.noauth(c)

# A command the pause holds back (held) waits, but for the refusals Redis
# makes before it pauses: a command of a client with a subscription that
# it may not run, a monitor's that reads or writes keys, EXEC refused
# (The pause)
def sh.held.of(s: Sh) -> Sh:
  match s:
    case ShDeny{n}:
      ShDeny{n}
    case ShAbort{m}:
      ShAbort{m}
    case ShMonDeny{i}:
      ShMonDeny{i}
    case ShRefuse{}:
      ShRefuse{}
    case ShNoMulti{}:
      ShNoMulti{}
    case _:
      ShPause{}

def sh.held(held: Bool, s: Sh) -> Sh:
  match held:
    case False{}:
      s
    case True{}:
      sh.held.of(s)

def sh.of.may(may: Bool, subd: Bool, inm: Bool, mon: Bool, held: Bool, +c: R.Cmd, +code: Nat, +ds: R.Ds) -> Sh:
  match may subd:
    case True{} True{}:
      sh.held(held, sh.sub(c, code))
    case True{} False{}:
      sh.held(held, sh.mon(Bool.and(mon, Bool.and(R.stat.keyspace(R.code.key(code)), Bool.not(Nat.is_eq(R.code.class(code), 1n)))), inm, c, code, ds))
    case False{} _:
      sh.of.noauth(inm, c, code)

# Past maxmemory with nothing left to evict (oom), Redis refuses, after it
# has checked the client's authentication and before the rest (a client
# with a subscription, a monitor), a command that may take memory
# (denyoom), and in MULTI any command but EXEC, DISCARD, QUIT and RESET,
# which flags the transaction; never one the parser refused (unknown, or
# with a number of arguments the table refuses), which Redis refuses
# before. EXEC itself is refused when its transaction queued one that may
# take memory (bg.exec).
def sh.oom.multi(+c: R.Cmd) -> Bool:
  match c:
    case R.Own{R.SExec{}}:
      False{}
    case R.Own{R.SDiscard{}}:
      False{}
    case R.Own{R.SQuit{}}:
      False{}
    case R.Own{R.SReset{}}:
      False{}
    case _:
      True{}

def sh.oomy(+inm: Bool, +c: R.Cmd, +code: Nat) -> Bool:
  Bool.and(Bool.not(Nat.is_eq(R.code.class(code), 1n)),
    Bool.or(R.stat.denyoom(R.code.key(code)), Bool.and(inm, sh.oom.multi(c))))

def sh.of.run(rej: Bool, may: Bool, subd: Bool, inm: Bool, mon: Bool, held: Bool, +c: R.Cmd, +code: Nat, +ds: R.Ds) -> Sh:
  match rej:
    case True{}:
      ShOom{inm}
    case False{}:
      sh.of.may(may, subd, inm, mon, held, c, code, ds)

# SHUTDOWN and SAVE in MULTI are refused (NO_MULTI) once the client may
# run them, before the rest, as processCommand refuses them right after
# AUTH: their arguments have not been read, so a SHUTDOWN the parser
# failed is refused too
def sh.nomulti(+code: Nat) -> Bool:
  Bool.and(R.stat.nomulti(R.code.key(code)), Bool.not(Nat.is_eq(R.code.class(code), 1n)))

def sh.of.nm(nm: Bool, +m: Bool, subd: Bool, +i: Bool, mon: Bool, oom: Bool, held: Bool, +c: R.Cmd, +code: Nat, +ds: R.Ds) -> Sh:
  match nm:
    case True{}:
      ShNoMulti{}
    case False{}:
      sh.of.run(Bool.and(m, Bool.and(oom, sh.oomy(i, c, code))), m, subd, i, mon, held, c, code, ds)

def sh.of(quit: Bool, may: Bool, inm: Bool, subd: Bool, mon: Bool, oom: Bool, held: Bool, +c: R.Cmd, +code: Nat, +ds: R.Ds) -> Sh:
  match quit:
    case True{}:
      ShRun{}
    case False{}:
      +m = may
      +i = inm
      sh.of.nm(Bool.and(m, Bool.and(i, sh.nomulti(code))), m, subd, i, mon, oom, held, c, code, ds)

# the client's transaction state, changed (its client first in the chain)
def bg.open(+id: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, ws, up, tx, pb}:
      LRun{rs, es, conn, srv, ds, ws, up, tx.open(id, tx), pb}
    case LHeld{h}:
      LHeld{h}

def bg.close(+id: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, ws, up, tx, pb}:
      LRun{rs, es, conn, srv, ds, ws, up, tx.close(id, tx), pb}
    case LHeld{h}:
      LHeld{h}

def bg.bad(g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, ws, up, tx, pb}:
      LRun{rs, es, conn, srv, ds, ws, up, tx.bad(tx), pb}
    case LHeld{h}:
      LHeld{h}

# a command refused past maxmemory in MULTI flags the transaction
def bg.oom.tx(inm: Bool, g: LRun) -> LRun:
  match inm:
    case True{}:
      bg.bad(g)
    case False{}:
      g

def bg.unwatch(+id: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, ws, up, tx, pb}:
      LRun{rs, es, conn, srv, ds, ws, up, tx.unwatch(id, tx), pb}
    case LHeld{h}:
      LHeld{h}

def bg.watch(+id: Nat, ks: List<&2, String>, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, +conn, srv, +ds, ws, up, tx, pb}:
      +x = ks
      LRun{rs, es, conn, srv, ds, ws, up, tx.watch(id, S.conn.db(conn), x, ds, tx), ps.heed.add(x, 0n, pb)}
    case LHeld{h}:
      LHeld{h}

# a command queued: QUEUED, sent or not as the mode says; it counts when
# EXEC runs it
def bg.queue(+c: R.Cmd, +code: Nat, a: Av, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, +conn, +srv, ds, ws, up, tx, pb}:
      LRun{S.put(S.say(S.conn.mode(conn), R.RStatus{"QUEUED"}), rs), es, S.step_conn(conn, srv), srv, ds, ws, up, tx.queue(c, code, a, tx), pb}
    case LHeld{h}:
      LHeld{h}

# a reply of the shell's own to a command, counted as its call
def bg.say(+r: R.Reply, +code: Nat, g: LRun) -> LRun:
  bg.one(R.Own{R.SReply{r}}, code, g)

# MONITOR
# -------
# MONITOR runs as Redis 7.0.15 runs it (monitorCommand, call() and
# replicationFeedMonitors): it makes its client a monitor, answered OK
# (a monitor already is answered nothing), and each call that runs then,
# of any client, sends every monitor a line: the time, the database after
# the call and the client's address, then the call's arguments as the
# client sent them, each quoted as Redis quotes it (P.reprs). A call runs
# as Redis's call() runs one: not one the parser refused (an unknown
# command, the number of its arguments), nor one refused before the
# client authenticated, to a subscribed client or to a monitor, nor one
# queued in a transaction, whose line goes out as EXEC runs it, before
# EXEC's own; an EXEC refused goes out all the same, as Redis's
# execCommandAbort sends it. A blocking command's line goes out when it
# blocks, not when it is served. The administrative commands (CONFIG,
# CLIENT LIST, KILL, NO-EVICT and UNBLOCK, MONITOR) and EVAL send none
# (R.stat.unseen), and AUTH's password, and HELLO's user and password,
# are "(redacted)" as Redis redacts them as it reads them. A monitor
# reads nothing and writes nothing (R.stat.keyspace: a command that
# reads or writes keys, or may be replicated, is refused "Replica can't
# interact with the keyspace", once the parser's checks, the client's
# authentication and a subscription's limits pass, as Redis refuses it
# to a replica); in MULTI, MONITOR is queued and answers an error when
# EXEC runs it. RESET, QUIT and the connection's end make the client no
# monitor; its own QUIT's line it does not get (Redis writes nothing to
# a client that closes after its reply).
#
# A line goes to each other monitor as a push, which its connection, a
# subscribed client's (A subscribed client), writes out as it comes; to
# the client itself, when it monitors, after the call's reply, among its
# batch's replies (after EXEC's array, for the calls EXEC runs, where
# Redis writes them between the array's replies). A monitor whose replies
# are held back (CLIENT REPLY OFF, or SKIP: Redis drops what it writes to
# such a client) gets no line: the actor keeps whether each monitor's
# replies were on as its last batch ended, and for its own calls looks at
# its mode before the call (a skip) and after it (off).
#
# The arguments as sent are read from the batch's bytes, which every
# batch brings (Req's raw) and the fast way drops: once a client
# monitors, the fast way is off (a bit of Pub/Sub's ev, as for a killed
# client), and the actor reads the bytes into each request's arguments
# (P.argvs) at the first line of the batch (Av). A batch's rest after a
# blocking command keeps its arguments with it, and so does each command
# queued in a transaction. The time is the group's, the one time the
# actor runs a group at, in ms (its microseconds end in 000), where Redis
# reads its clock for each call.

# the ms of a time in ms as a line's microseconds: three digits and 000
def mon.usec(+ms: Nat) -> String:
  Bool.pick(String, Nat.is_lt(ms, 10n), "00", Bool.pick(String, Nat.is_lt(ms, 100n), "0", "")) ++ Nat.show(ms) ++ "000"

# a line: the time (ms since 1970), the database after the call, the
# client's address, and the call's arguments
def mon.line(+now: Nat, +db: Nat, +addr: String, args: List<&2, String>) -> String:
  Nat.show(Nat.div(now, 1000n)) ++ "." ++ mon.usec(Nat.mod(now, 1000n)) ++ " [" ++ Nat.show(db) ++ " " ++ addr ++ "] " ++ P.reprs(args)

def red.word() -> String:
  "(redacted)"

# AUTH's arguments, the password (and the user) redacted, unless they are
# more than two (a syntax error, which Redis finds first)
def red.auth(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Con{a, Con{p, Nil{}}}:
      [a, red.word()]
    case Con{a, Con{u, Con{p, Nil{}}}}:
      [a, red.word(), red.word()]
    case other:
      other

# HELLO's options read as Redis reads them: an option next, the user and
# the password of an AUTH (each redacted), the name of a SETNAME, or an
# option not right, which ends them (what follows is as it was)
type Red is Data:
  RedOpt{}
  RedUser{}
  RedPass{}
  RedName{}
  RedDone{}

def red.opt(au: Bool, sn: Bool) -> Red:
  match au sn:
    case True{} _:
      RedUser{}
    case False{} True{}:
      RedName{}
    case False{} False{}:
      RedDone{}

# the state after argument a, read in state st, n arguments after it
def red.step(st: Red, +a: String, +n: Nat) -> Red:
  match st:
    case RedOpt{}:
      red.opt(Bool.and(R.is_word(a, "AUTH"), Nat.is_le(2n, n)), Bool.and(R.is_word(a, "SETNAME"), Nat.is_le(1n, n)))
    case RedUser{}:
      RedPass{}
    case RedPass{}:
      RedOpt{}
    case RedName{}:
      RedOpt{}
    case RedDone{}:
      RedDone{}

# an argument read in state st, redacted when it is a user or a password
def red.put(st: Red, a: String) -> String:
  match st:
    case RedUser{}:
      red.word()
    case RedPass{}:
      red.word()
    case _:
      a

def red.hello.opts(xs: List<&2, String>, +st: Red) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{+a, +rest}:
      red.put(st, a) <> red.hello.opts(rest, red.step(st, a, List.length(&2, String, rest)))

# whether HELLO's version is one Redis reads its options after: 2 or 3
def red.ver(l: R.LL) -> Bool:
  match l:
    case R.LL{+neg, +hi, +lo}:
      Bool.and(Bool.not(neg), Bool.and(Nat.is_eq(hi, 0n), Bool.or(Nat.is_eq(lo, 2n), Nat.is_eq(lo, 3n))))
    case R.LLBad{}:
      False{}

def red.hello.ver(ok: Bool, h: String, v: String, rest: List<&2, String>) -> List<&2, String>:
  match ok:
    case True{}:
      h <> v <> red.hello.opts(rest, RedOpt{})
    case False{}:
      h <> v <> rest

def red.hello(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Con{h, Con{+v, rest}}:
      red.hello.ver(red.ver(R.ll.read(v)), h, v, rest)
    case other:
      other

def red.of(auth: Bool, hello: Bool, xs: List<&2, String>) -> List<&2, String>:
  match auth hello:
    case True{} _:
      red.auth(xs)
    case False{} True{}:
      red.hello(xs)
    case False{} False{}:
      xs

# a call's arguments as a line shows them (key: its command's)
def mon.redact(+key: Nat, xs: List<&2, String>) -> List<&2, String>:
  red.of(Nat.is_eq(key, R.stat.top(102n)), Nat.is_eq(key, R.stat.top(101n)), xs)

# CONFIG SET's parameters that Redis flags sensitive (SENSITIVE_CONFIG),
# whose values it redacts, case aside
def red.secret(+p: String) -> Bool:
  Bool.or(C.text.same(p, "requirepass"), Bool.or(C.text.same(p, "masterauth"), C.text.same(p, "masteruser")))

def red.pairs(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Con{+p, Con{v, rest}}:
      p <> Bool.pick(String, red.secret(p), red.word(), v) <> red.pairs(rest)
    case other:
      other

def red.config.if(even: Bool, xs: List<&2, String>) -> List<&2, String>:
  match even:
    case True{}:
      red.pairs(xs)
    case False{}:
      xs

# CONFIG SET's arguments, its sensitive values redacted when its pairs
# are whole (configSetCommand, before it looks at any: an odd count is an
# error of arity first)
def red.config(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Con{c, Con{s, +rest}}:
      c <> s <> red.config.if(Nat.is_eq(Nat.mod(List.length(&2, String, rest), 2n), 0n), rest)
    case other:
      other

def slow.redact.if(cs: Bool, +key: Nat, xs: List<&2, String>) -> List<&2, String>:
  match cs:
    case True{}:
      red.config(xs)
    case False{}:
      mon.redact(key, xs)

# a call's arguments as the slow log keeps them: the monitor's, and
# CONFIG SET's values of sensitive parameters redacted (redactClientCommandArgument)
def slow.redact(+key: Nat, xs: List<&2, String>) -> List<&2, String>:
  slow.redact.if(Nat.is_eq(key, R.stat.sub.config(2n)), key, xs)

# whether a call of code that ran (may: its client may run it) sends a
# line: one the parser did not refuse, of a command not administrative
def mon.ran(+may: Bool, +code: Nat) -> Bool:
  Bool.and(may, Bool.and(Bool.not(Nat.is_eq(R.code.class(code), 1n)), Bool.not(R.stat.unseen(R.code.key(code)))))

# whether a command of a batch sends a line, by what the shell did with
# it (q: a QUIT before it dropped it)
def mon.seen.sh(+may: Bool, +sh: Sh, +code: Nat) -> Bool:
  match sh:
    case ShAbort{m}:
      True{}
    case ShQueue{}:
      False{}
    case ShRefuse{}:
      False{}
    case ShDeny{n}:
      False{}
    case ShMonDeny{i}:
      False{}
    case ShOom{i}:
      False{}
    case ShPause{}:
      False{}
    case ShNoMulti{}:
      False{}
    case _:
      mon.ran(may, code)

def mon.seen(+q: Bool, +may: Bool, +sh: Sh, +code: Nat) -> Bool:
  match q:
    case True{}:
      False{}
    case False{}:
      mon.seen.sh(may, sh, code)

def mute.is.skip(+m: S.Mute) -> Bool:
  match m:
    case S.MSkip{}:
      True{}
    case _:
      False{}

def mute.is.off(+m: S.Mute) -> Bool:
  match m:
    case S.MOff{}:
      True{}
    case _:
      False{}

# whether the client's own line goes out: it monitors, has not quit, and
# its replies were not skipped for the call (m0: its mode before) nor
# are off after it
def mon.self(+mo: Bool, +m0: S.Mute, +conn: S.Conn) -> Bool:
  Bool.and(Bool.and(mo, Bool.not(S.conn.quit(conn))), Bool.and(Bool.not(mute.is.skip(m0)), Bool.not(mute.is.off(S.conn.mode(conn)))))

def mon.mine(on: Bool, +line: String, rs: List<&2, R.Reply>) -> List<&2, R.Reply>:
  match on:
    case True{}:
      R.RStatus{line} <> rs
    case False{}:
      rs

def mon.add(on: Bool, +line: String, xs: List<&2, String>) -> List<&2, String>:
  match on:
    case True{}:
      line <> xs
    case False{}:
      xs

# the rest of a batch's arguments after the request that runs
def av.tail(+xs: List<&2, List<&2, String>>) -> List<&2, List<&2, String>>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{x, +rest}:
      rest

def av.rest(+a: Av) -> Av:
  match a:
    case AvRaw{+raw, +n}:
      AvRaw{raw, 1n+n}
    case AvArgs{+xs}:
      AvArgs{av.tail(xs)}

# the arguments of the request an Av's next is, and the Av of those after
# it, read from the batch's bytes if they were not
type Got is Data:
  Got{args: List<&2, String>, rest: Av}

def av.got(xs: List<&2, List<&2, String>>) -> Got:
  match xs:
    case Nil{}:
      Got{Nil{}, AvArgs{Nil{}}}
    case Con{x, rest}:
      Got{x, AvArgs{rest}}

def av.get(a: Av) -> Got:
  match a:
    case AvRaw{+raw, +n}:
      av.got(List.drop(&2, List<&2, String>, P.argvs(raw), n))
    case AvArgs{xs}:
      av.got(xs)

# where the arguments of the request an Av's next is are, for the slow
# log (info.bend: Timing a window)
def av.first(+xs: List<&2, List<&2, String>>) -> List<&2, String>:
  match xs:
    case Con{+x, rest}:
      x
    case Nil{}:
      Nil{}

def av.arg(+a: Av) -> I.Arg:
  match a:
    case AvRaw{+raw, +n}:
      I.ArgRaw{raw, n}
    case AvArgs{+xs}:
      I.ArgList{av.first(xs)}

# a batch's state after a call, with the Av of the rest of the batch
type Fed is Data:
  Fed{g: LRun, av: Av}

def fed.held(f: Fed) -> Fed:
  match f:
    case Fed{g, av}:
      Fed{LHeld{g}, av}

# the call's line, to the other monitors and to its client (k: its code,
# m0: its client's mode before it)
def bg.fed(+id: Nat, +k: Nat, +m0: S.Mute, got: Got, g: LRun) -> Fed:
  match got g:
    case Got{args, rest} LRun{rs, es, +conn, srv, +ds, ws, up, tx, +pb}:
      +line = mon.line(R.ds.now(ds), S.conn.db(conn), ps.addr(id, pb), mon.redact(R.code.key(k), args))
      Fed{LRun{mon.mine(mon.self(ps.mon.is(id, pb), m0, conn), line, rs), es, conn, srv, ds, ws, up, tx, ps.mon.push(id, "+" ++ line ++ "\r\n", pb)}, rest}
    case Got{args, rest} LHeld{h}:
      Fed{LHeld{h}, rest}

def bg.feed.on(on: Bool, +id: Nat, +k: Nat, +m0: S.Mute, a: Av, ar: Av, g: LRun) -> Fed:
  match on:
    case False{}:
      Fed{g, ar}
    case True{}:
      bg.fed(id, k, m0, av.get(a), g)

# after a command of a batch (a: its Av; ar: the rest's), its line, if it
# sends one (seen) and some client monitors
def bg.feed(seen: Bool, +id: Nat, +k: Nat, +m0: S.Mute, a: Av, ar: Av, g: LRun) -> Fed:
  match g:
    case LRun{rs, es, conn, srv, ds, ws, up, tx, +pb}:
      bg.feed.on(Bool.and(seen, ps.mon.any(pb)), id, k, m0, a, ar, LRun{rs, es, conn, srv, ds, ws, up, tx, pb})
    case LHeld{h}:
      fed.held(bg.feed(seen, id, k, m0, a, ar, h))

# The commands EXEC runs: each one's line, the client's own kept for after
# EXEC's array (mine, newest first)
type Xr is Data:
  Xr{g: LRun, mine: List<&2, String>}

def bg.x.fed(+id: Nat, +k: Nat, +m0: S.Mute, got: Got, g: LRun, mine: List<&2, String>) -> Xr:
  match got g:
    case Got{args, rest} LRun{rs, es, +conn, srv, +ds, ws, up, tx, +pb}:
      +line = mon.line(R.ds.now(ds), S.conn.db(conn), ps.addr(id, pb), mon.redact(R.code.key(k), args))
      Xr{LRun{rs, es, conn, srv, ds, ws, up, tx, ps.mon.push(id, "+" ++ line ++ "\r\n", pb)}, mon.add(mon.self(ps.mon.is(id, pb), m0, conn), line, mine)}
    case Got{args, rest} LHeld{h}:
      Xr{LHeld{h}, mine}

def bg.x.feed.on(on: Bool, +id: Nat, +k: Nat, +m0: S.Mute, a: Av, g: LRun, mine: List<&2, String>) -> Xr:
  match on:
    case False{}:
      Xr{g, mine}
    case True{}:
      bg.x.fed(id, k, m0, av.get(a), g, mine)

def bg.x.feed(ran: Bool, +id: Nat, +k: Nat, +m0: S.Mute, a: Av, g: LRun, mine: List<&2, String>) -> Xr:
  match g:
    case LRun{rs, es, conn, srv, ds, ws, up, tx, +pb}:
      bg.x.feed.on(Bool.and(ran, ps.mon.any(pb)), id, k, m0, a, LRun{rs, es, conn, srv, ds, ws, up, tx, pb}, mine)
    case LHeld{h}:
      Xr{LHeld{h}, mine}

# the client's own lines of EXEC's commands (newest first), after EXEC's
# reply
def mon.after.rs(mine: List<&2, String>, rs: List<&2, R.Reply>) -> List<&2, R.Reply>:
  match mine:
    case Nil{}:
      rs
    case Con{l, rest}:
      R.RStatus{l} <> mon.after.rs(rest, rs)

def mon.after(mine: List<&2, String>, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, ws, up, tx, pb}:
      LRun{mon.after.rs(mine, rs), es, conn, srv, ds, ws, up, tx, pb}
    case LHeld{h}:
      LHeld{h}

# MONITOR: the client a monitor, answered OK; a monitor already is
# answered nothing, its call counted all the same
def bg.monitor.if(already: Bool, +id: Nat, +back: Chan(Ans), +code: Nat, g: LRun) -> LRun:
  match already g:
    case True{} LRun{rs, es, +conn, +srv, ds, ws, up, tx, pb}:
      LRun{rs, es, S.step_conn(conn, srv), gen.count(srv, code, Nil{}), ds, ws, up, tx, pb}
    case False{} LRun{rs, es, conn, srv, ds, ws, up, tx, pb}:
      bg.one(R.Own{R.SMonitor{}}, code, LRun{rs, es, conn, srv, ds, ws, up, tx, ps.mon.add(id, back, pb)})
    case _ LHeld{h}:
      LHeld{h}

def bg.monitor(+id: Nat, +back: Chan(Ans), +code: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, ws, up, tx, +pb}:
      bg.monitor.if(ps.mon.is(id, pb), id, back, code, LRun{rs, es, conn, srv, ds, ws, up, tx, pb})
    case LHeld{h}:
      LHeld{h}

# BGREWRITEAOF, as Redis 7.0.15's bgrewriteaofCommand answers it: while a
# rewrite runs, refused; in EXEC, scheduled (the cron starts it); else
# started: the server's state says it runs from the group's time, and the
# actor starts it once the group is answered (The rewrite of the
# append-only file)
def bg.rw.go(g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, +ds, ws, up, tx, pb}:
      LRun{rs, es, conn, S.srv.rw.go(srv, R.ds.now(ds)), ds, ws, up, tx, pb}
    case LHeld{h}:
      LHeld{h}

def bg.rw.later(g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, ws, up, tx, pb}:
      LRun{rs, es, conn, S.srv.rw.later(srv), ds, ws, up, tx, pb}
    case LHeld{h}:
      LHeld{h}

def bg.rewrite.if(on: Bool, exec: Bool, +code: Nat, g: LRun) -> LRun:
  match on exec:
    case True{} _:
      bg.say(R.RError{"ERR Background append only file rewriting already in progress"}, code, g)
    case False{} True{}:
      bg.say(R.RStatus{"Background append only file rewriting scheduled"}, code, bg.rw.later(g))
    case False{} False{}:
      bg.say(R.RStatus{"Background append only file rewriting started"}, code, bg.rw.go(g))

def bg.rewrite(exec: Bool, +code: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, +srv, ds, ws, up, tx, pb}:
      bg.rewrite.if(S.srv.rw.on(srv), exec, code, LRun{rs, es, conn, srv, ds, ws, up, tx, pb})
    case LHeld{h}:
      LHeld{h}

# a monitor's command that reads or writes keys refused (in MULTI, the
# transaction flagged), counted as refused
def bg.mon.bad(inm: Bool, g: LRun) -> LRun:
  match inm:
    case True{}:
      bg.bad(g)
    case False{}:
      g

# a monitor's replies on or off, as its batch left them
def ps.mon.end.if(mo: Bool, +conn: S.Conn, pb: Ps) -> Ps:
  match mo:
    case True{}:
      ps.mon.mute(S.conn.id(conn), mute.on(S.conn.mode(conn)), pb)
    case False{}:
      pb

def ps.mon.end(+conn: S.Conn, pb: Ps) -> Ps:
  +p = pb
  ps.mon.end.if(ps.mon.is(S.conn.id(conn), p), conn, p)

# EXEC: the queued commands run, oldest first, as one. Their replies are
# gathered on their own, each sent or not as the mode says, with the
# mode on unless the client's replies are held back (then off: EXEC's
# array is not sent, and its commands count all the same); after them
# the mode is as it was, unless one of them changed it (CLIENT REPLY),
# and EXEC's array goes as the mode says; their effects are one
# transaction (tx.effs); then the clients that wait are served.
def exec.mode(+m: S.Mute) -> S.Mute:
  match m:
    case S.MOn{}:
      S.MOn{}
    case _:
      S.MOff{}

def mute.same(+a: S.Mute, +b: S.Mute) -> Bool:
  match a b:
    case S.MOn{} S.MOn{}:
      True{}
    case S.MOff{} S.MOff{}:
      True{}
    case S.MSkip{} S.MSkip{}:
      True{}
    case _ _:
      False{}

def conn.mode.set(+m: S.Mute, c: S.Conn) -> S.Conn:
  match c:
    case S.Conn{id, auth, name, mode, quit, db, r3}:
      S.Conn{id, auth, name, m, quit, db, r3}

# a transaction's entries (newest first, each its own) put before es as
# one entry of them all when they are two or more (A.tx.wrap: the
# append-only file has them between a MULTI and an EXEC), as Redis
# propagates them
def tx.flat(xs: List<&2, A.Ent>, acc: List<&2, A.Eff>) -> List<&2, A.Eff>:
  match xs:
    case Nil{}:
      acc
    case Con{A.EOne{e}, rest}:
      tx.flat(rest, e <> acc)
    case Con{A.ETx{es}, rest}:
      tx.flat(rest, List.append(&2, A.Eff, es, acc))

def tx.effs(e1: List<&2, A.Ent>, es: List<&2, A.Ent>) -> List<&2, A.Ent>:
  List.reverse.go(&2, A.Ent, A.tx.wrap(tx.flat(e1, Nil{})), es)

def bg.exec.done(rs: List<&2, R.Reply>, es: List<&2, A.Ent>, +m0: S.Mute, +mi: S.Mute, +code: Nat, x: Xr) -> LRun:
  match x:
    case Xr{LRun{rs1, es1, +conn1, srv1, ds1, ws1, up1, tx1, pb}, mine}:
      +conn2 = Bool.pick(S.Conn, mute.same(S.conn.mode(conn1), mi), conn.mode.set(m0, conn1), conn1)
      mon.after(mine, bg.say(R.RArray{List.reverse(&2, R.Reply, rs1)}, code, LRun{rs, tx.effs(es1, es), conn2, srv1, ds1, ws1, up1, tx1, pb}))
    case Xr{LHeld{h}, mine}:
      LHeld{h}

# A command of Pub/Sub. SUBSCRIBE and its kin: their replies sent
# whatever the client's mode, the call counted, the connection one
# command on (a skip spent); PUBLISH, SPUBLISH and PUBSUB: their reply
# as the session sends any, the call counted
def bg.pushed(+code: Nat, p: List<&2, R.Reply> & Ps, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, +conn: S.Conn, +srv: S.Srv, ds: R.Ds, ws: Waits, up: List<&2, Up>, tx: Tx) -> LRun:
  (xs, pb) = p
  LRun{List.reverse.go(&2, R.Reply, xs, rs), es, S.step_conn(conn, srv), gen.count(srv, code, Nil{}), ds, ws, up, tx, pb}

def bg.subs(+id: Nat, +back: Chan(Ans), +on: Bool, +kind: Nat, names: List<&2, String>, +code: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, +conn, srv, ds, ws, up, tx, pb}:
      bg.pushed(code, ps.sub(id, back, S.conn.r3(conn), on, kind, names, pb), rs, es, conn, srv, ds, ws, up, tx)
    case LHeld{h}:
      LHeld{h}

def bg.published.of(+code: Nat, +k: Nat, q: List<&2, R.Reply> & Ps, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, conn: S.Conn, srv: S.Srv, ds: R.Ds, ws: Waits, up: List<&2, Up>, tx: Tx) -> LRun:
  (own, pb) = q
  bg.say(R.RInt{R.IPos{k}}, code, LRun{List.append(&2, R.Reply, own, rs), es, conn, srv, ds, ws, up, tx, pb})

# PUBLISH's reply after the pushes to its own client, if it has a
# subscription to the channel (RESP3)
def bg.published(+code: Nat, p: Nat & Ps, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, conn: S.Conn, srv: S.Srv, ds: R.Ds, ws: Waits, up: List<&2, Up>, tx: Tx) -> LRun:
  (k, pb) = p
  bg.published.of(code, k, ps.own.take(pb), rs, es, conn, srv, ds, ws, up, tx)

def bg.publish(+shard: Bool, +c: String, +m: String, +code: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, +conn, srv, ds, ws, up, tx, pb}:
      bg.published(code, ps.publish(shard, c, m, S.conn.id(conn), pb), rs, es, conn, srv, ds, ws, up, tx)
    case LHeld{h}:
      LHeld{h}

def bg.ps.read(op: R.PubOp, +code: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, ws, up, tx, +pb}:
      bg.say(ps.read(op, pb), code, LRun{rs, es, conn, srv, ds, ws, up, tx, pb})
    case LHeld{h}:
      LHeld{h}

def bg.pub(+id: Nat, +back: Chan(Ans), op: R.PubOp, +code: Nat, g: LRun) -> LRun:
  match op:
    case R.PSub{+k, names}:
      bg.subs(id, back, True{}, k, names, code, g)
    case R.PUnsub{+k, names}:
      bg.subs(id, back, False{}, k, names, code, g)
    case R.PPub{+sh, +c, +m}:
      bg.publish(sh, c, m, code, g)
    case other:
      bg.ps.read(other, code, g)

# every subscription of the client of id dropped (RESET)
def bg.unsub.all(+id: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, ws, up, tx, pb}:
      LRun{rs, es, conn, srv, ds, ws, up, tx, ps.drop(id, pb)}
    case LHeld{h}:
      LHeld{h}

# CLIENT LIST, INFO, KILL and NO-EVICT
# ------------------------------------
# A client's line as Redis writes it (R.client.line), from the registry
# (Clients) and the actor's state: O for a monitor (MONITOR; its type is
# normal, as Redis's), P with a subscription, x in MULTI
# (its queued commands as multi), b waiting, d with a watched key
# touched, e with NO-EVICT on, N for none; its counts of channels,
# patterns and shard channels; its last command and the time of its last
# batch from its channel's mark (NULL before its first batch); a client
# that waits, the size of its blocking command's arguments (argv-mem). The
# client that asks shows its own connection's name and database, the
# command that runs, idle 0, and the bytes of its batch (qbuf) and of the
# command's arguments (argv-mem).

# whether the client of id waits, anywhere in ws
def waits.has(+n: Nat, +ws: Waits) -> Bool:
  match ws:
    case WaitOn{+id, back, c0, c1, b, argv, code, db, until, cmds, codes, av, +rest}:
      Bool.or(Nat.is_eq(id, n), waits.has(n, rest))
    case WaitNone{}:
      False{}

# the size of the arguments of the command the client of id waits in
# (argv-mem: Redis keeps a blocked client's arguments), 0 if it waits not
def waits.argv(+n: Nat, +ws: Waits) -> Nat:
  match ws:
    case WaitOn{+id, back, c0, c1, b, +argv, code, db, until, cmds, codes, av, +rest}:
      Bool.pick(Nat, Nat.is_eq(id, n), argv, waits.argv(n, rest))
    case WaitNone{}:
      0n

# a client's transaction as CLIENT LIST shows it: in MULTI, its queued
# commands, and whether a watched key of its was touched
type TxIs is Data:
  TxIs{multi: Bool, n: Nat, cas: Bool}

def tx.find(+n: Nat, +t: Tx) -> TxIs:
  match t:
    case TxOn{+i, +mu, bd, +cs, +qs, qc, qa, wk, +r}:
      Bool.pick(TxIs, Nat.is_eq(i, n), TxIs{mu, List.length(&2, R.Cmd, qs), cs}, tx.find(n, r))
    case TxNone{}:
      TxIs{False{}, 0n, False{}}

def cl.flag(+on: Bool, +f: String) -> String:
  Bool.pick(String, on, f, "")

def cl.flags.of(+s: String) -> String:
  Bool.pick(String, String.eq(s, ""), "N", s)

def cl.flags(+mo: Bool, +sub: Bool, +x: TxIs, +b: Bool, +kt: Tk, +e: Bool) -> String:
  match x:
    case TxIs{+mu, n, +cas}:
      cl.flags.of(cl.flag(mo, "O") ++ cl.flag(sub, "P") ++ cl.flag(mu, "x") ++ cl.flag(b, "b") ++ tk.line.flags(kt) ++ cl.flag(cas, "d") ++ cl.flag(e, "e"))

def cl.multi(+x: TxIs) -> Maybe<&2, Nat>:
  match x:
    case TxIs{+mu, +n, cas}:
      Bool.pick(Maybe<&2, Nat>, mu, Some{n}, None{})

def ps.mine(+id: Nat, +pb: Ps) -> Maybe<&2, Mine>:
  match pb:
    case Ps{+reg, ev, px, cs, own}:
      reg.mine(id, reg)
    case PsOf{+p}:
      ps.mine(id, p)

def mine.or(m: Maybe<&2, Mine>) -> Mine:
  match m:
    case Some{x}:
      x
    case None{}:
      Mine{Nil{}, Nil{}, Nil{}}

# the name of the command of code w (its channel's mark: 0 before any)
def cl.cmd.of(+w: U32) -> String:
  +k = R.code.key(U32.to_nat(w))
  Bool.pick(String, Nat.is_eq(k, 0n), "NULL", R.stat.name(k))

# whole seconds between two times in ms, as Redis subtracts its unixtime
def cl.secs(+now: Nat, +t: Nat) -> Nat:
  Nat.sub(Nat.div(now, 1000n), Nat.div(t, 1000n))

# What a line shows of the client that asks (Me: its id, its connection,
# the name of the command that runs, the bytes of its batch and of the
# command's arguments, and while EXEC runs its transaction the number of
# the commands queued), or of another client (Them).
type Who is Data:
  Me{id: Nat, cn: S.Conn, cmd: String, qbuf: Nat, argv: Nat, ex: Maybe<&2, Nat>}
  Them{}

def cl.line.of(m: Mine, +mo: Bool, +sub: Bool, +x: TxIs, +b: Bool, +wa: Nat, c: Cl, +now: Nat, +word: U32, +at: Nat, w: Who) -> String:
  match m:
    case Mine{+ch, +pa, +sh}:
      match c:
        case Cl{id, back, fd, addr, laddr, +since, name, db, +noev, r3, +kt}:
          match w:
            case Them{}:
              R.client.line(R.ClLine{id, addr, laddr, U32.to_nat(fd), name, cl.secs(now, since), cl.secs(now, at), cl.flags(mo, sub, x, b, kt, noev), db, List.length(&2, String, ch), List.length(&2, String, pa), List.length(&2, String, sh), cl.multi(x), 0n, wa, cl.cmd.of(word), tk.line.redir(kt), r3})
            case Me{i, +cn, cmd, qbuf, argv, ex}:
              R.client.line(R.ClLine{id, addr, laddr, U32.to_nat(fd), S.conn.name(cn), cl.secs(now, since), 0n, cl.flags(mo, sub, x, b, kt, noev), S.conn.db(cn), List.length(&2, String, ch), List.length(&2, String, pa), List.length(&2, String, sh), cl.multi(x), qbuf, argv, cmd, tk.line.redir(kt), S.conn.r3(cn)})

def cl.line.mk(m: Mine, +mo: Bool, +sub: Bool, +x: TxIs, +b: Bool, +wa: Nat, c: Cl, +now: Nat, mk: U32 & Nat, w: Who) -> String:
  (word, at) = mk
  cl.line.of(m, mo, sub, x, b, wa, c, now, word, at, w)

# the transaction a line shows: of the client that asks while EXEC runs
# it (in MULTI, its commands queued, as Redis shows a client in EXEC),
# else the chain's
def cl.tx.of(+ex: Maybe<&2, Nat>, +id: Nat, +tx: Tx) -> TxIs:
  match ex:
    case Some{+n}:
      TxIs{True{}, n, False{}}
    case None{}:
      tx.find(id, tx)

def cl.tx(+w: Who, +id: Nat, +tx: Tx) -> TxIs:
  match w:
    case Me{i, cn, cmd, qbuf, argv, +ex}:
      cl.tx.of(ex, id, tx)
    case Them{}:
      tx.find(id, tx)

# client c's line, ended by a newline
def cl.line(c: Cl, +now: Nat, +w: Who, +ws: Waits, +tx: Tx, +pb: Ps) -> String:
  match c:
    case Cl{+id, +back, fd, addr, laddr, since, name, db, noev, r3, kt}:
      cl.line.mk(mine.or(ps.mine(id, pb)), ps.mon.is(id, pb), ps.has(id, pb), cl.tx(w, id, tx), waits.has(id, ws), waits.argv(id, ws), Cl{id, back, fd, addr, laddr, since, name, db, noev, r3, kt}, now, Chan.marked(Ans, back), w) ++ "\n"

def cl.id(+c: Cl) -> Nat:
  match c:
    case Cl{+id, back, fd, addr, laddr, since, name, db, noev, r3, kt}:
      id

# the registry's clients, in the order of their ids (as Redis lists them
# in the order they came, but for its rotations): a merge sort, with the
# number of clients as its fuel
@unsafe
def cls.merge(xs: List<&2, Cl>, ys: List<&2, Cl>) -> List<&2, Cl>:
  match xs:
    case Nil{}:
      ys
    case Con{+x, +xr}:
      match ys:
        case Nil{}:
          x <> xr
        case Con{+y, +yr}:
          cls.merge.pick(Nat.is_lt(cl.id(x), cl.id(y)), x, xr, y, yr)

@unsafe
def cls.merge.pick(lt: Bool, x: Cl, xr: List<&2, Cl>, y: Cl, yr: List<&2, Cl>) -> List<&2, Cl>:
  match lt:
    case True{}:
      x <> cls.merge(xr, y <> yr)
    case False{}:
      y <> cls.merge(x <> xr, yr)

def cls.split(xs: List<&2, Cl>, a: List<&2, Cl>, b: List<&2, Cl>) -> List<&2, Cl> & List<&2, Cl>:
  match xs:
    case Nil{}:
      (a, b)
    case Con{x, rest}:
      cls.split(rest, b, x <> a)

@unsafe
def cls.sort(xs: List<&2, Cl>) -> List<&2, Cl>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{x, Nil{}}:
      [x]
    case Con{x, Con{y, rest}}:
      cls.sort.halves(cls.split(x <> y <> rest, Nil{}, Nil{}))

@unsafe
def cls.sort.halves(p: List<&2, Cl> & List<&2, Cl>) -> List<&2, Cl>:
  (a, b) = p
  cls.merge(cls.sort(a), cls.sort(b))

def cls.add(m: Maybe<&2, Cl>, acc: List<&2, Cl>) -> List<&2, Cl>:
  match m:
    case Some{c}:
      c <> acc
    case None{}:
      acc

def cls.of(ks: List<&2, String>, +tab: KV.Trie<Cl>, acc: List<&2, Cl>) -> List<&2, Cl>:
  match ks:
    case Nil{}:
      acc
    case Con{+k, rest}:
      cls.of(rest, tab, cls.add(KV.get(Cl, tab, k), acc))

def cls.all(+cs: Cls) -> List<&2, Cl>:
  match cs:
    case Cls{+tab, kd, ks, ms, pz, dn, hd}:
      cls.sort(cls.of(KV.keys(Cl, tab, 0n), tab, Nil{}))

# a client's type as CLIENT LIST TYPE and CLIENT KILL TYPE read it: 3
# pubsub with a subscription, else 1 normal (no client is a replica or
# a master)
def cl.type(+id: Nat, +pb: Ps) -> Nat:
  Bool.pick(Nat, ps.has(id, pb), 3n, 1n)

def cl.typed(+ty: Nat, +id: Nat, +pb: Ps) -> Bool:
  Bool.or(Nat.is_eq(ty, 0n), Nat.is_eq(ty, cl.type(id, pb)))

def cl.who(+me: Who, +id: Nat) -> Who:
  match me:
    case Me{+i, cn, cmd, qbuf, argv, ex}:
      Bool.pick(Who, Nat.is_eq(i, id), me, Them{})
    case Them{}:
      Them{}

def cl.lines(xs: List<&2, Cl>, +ty: Nat, +now: Nat, +me: Who, +ws: Waits, +tx: Tx, +pb: Ps, acc: String) -> String:
  match xs:
    case Nil{}:
      acc
    case Con{+c, rest}:
      +id = cl.id(c)
      cl.lines(rest, ty, now, me, ws, tx, pb, acc ++ Bool.pick(String, cl.typed(ty, id, pb), cl.line(c, now, cl.who(me, id), ws, tx, pb), ""))

def cl.line.or(m: Maybe<&2, Cl>, +now: Nat, w: Who, +ws: Waits, +tx: Tx, +pb: Ps) -> String:
  match m:
    case Some{c}:
      cl.line(c, now, w, ws, tx, pb)
    case None{}:
      ""

def cl.ids(ids: List<&2, Nat>, +now: Nat, +me: Who, +ws: Waits, +tx: Tx, +pb: Ps, acc: String) -> String:
  match ids:
    case Nil{}:
      acc
    case Con{+id, rest}:
      cl.ids(rest, now, me, ws, tx, pb, acc ++ cl.line.or(cls.get(id, ps.cls(pb)), now, cl.who(me, id), ws, tx, pb))

# CLIENT LIST: all clients, of a type, or of ids (a verbatim text, as
# Redis answers it)
def cl.list(+ty: Nat, ids: Maybe<&2, List<&2, Nat>>, +now: Nat, +me: Who, +ws: Waits, +tx: Tx, +pb: Ps) -> R.Reply:
  match ids:
    case Some{xs}:
      R.RVerb{cl.ids(xs, now, me, ws, tx, pb, "")}
    case None{}:
      R.RVerb{cl.lines(cls.all(ps.cls(pb)), ty, now, me, ws, tx, pb, "")}

# CLIENT INFO: the client's own line
def cl.info(+now: Nat, +me: Who, +ws: Waits, +tx: Tx, +pb: Ps) -> R.Reply:
  match me:
    case Me{+id, cn, cmd, qbuf, argv, ex}:
      R.RVerb{cl.ids([id], now, me, ws, tx, pb, "")}
    case Them{}:
      R.RVerb{""}

def opt.is(m: Maybe<&2, String>, +s: String) -> Bool:
  match m:
    case Some{+x}:
      String.eq(x, s)
    case None{}:
      True{}

def id.is(m: Maybe<&2, Nat>, +n: Nat) -> Bool:
  match m:
    case Some{+x}:
      Nat.is_eq(x, n)
    case None{}:
      True{}

# whether CLIENT KILL's filter picks client c (me: the id of the client
# that kills)
def cl.picked(f: R.Kill, c: Cl, +me: Nat, +pb: Ps) -> Bool:
  match f c:
    case R.Kill{a, l, i, +ty, +skip} Cl{+id, back, fd, +addr, +laddr, since, name, db, noev, r3, kt}:
      Bool.and(Bool.and(Bool.and(opt.is(a, addr), opt.is(l, laddr)), Bool.and(id.is(i, id), cl.typed(ty, id, pb))), Bool.not(Bool.and(skip, Nat.is_eq(id, me))))

def cl.fd(+c: Cl) -> U32:
  match c:
    case Cl{id, back, +fd, addr, laddr, since, name, db, noev, r3, kt}:
      fd

# the clients a filter picks
def cl.pick(xs: List<&2, Cl>, +f: R.Kill, +me: Nat, +pb: Ps) -> List<&2, Cl>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{+c, rest}:
      +r = cl.pick(rest, f, me, pb)
      Bool.pick(List<&2, Cl>, cl.picked(f, c, me, pb), c <> r, r)

# a client the actor holds dropped, as if its connection had ended: its
# wait, its unblocked batch, its transaction, its subscriptions, its
# tracking (before it leaves the registry, which keeps its Tk); out of
# the registry, its fd to be shut down
def bg.kill1(+v: Nat, +fd: U32, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, +ws, +up, tx, pb}:
      +left = waits.rest(waits.take(ws, waits.is(v, ws), v, WaitNone{}))
      LRun{rs, es, conn, waits.count(left, srv), ds, left, ups.drop(up, ups.is(v, up), v), tx.drop(v, tx), ps.kill(v, fd, ps.trk.off(v, ps.drop(v, pb)))}
    case LHeld{h}:
      LHeld{h}

# the client itself, killed: its connection closes once this reply is
# out (CLIENT_CLOSE_AFTER_REPLY), the rest of its batch not run
def bg.self.kill(g: LRun) -> LRun:
  match g:
    case LRun{rs, es, S.Conn{id, auth, name, mode, quit, db, r3}, srv, ds, ws, up, tx, pb}:
      LRun{rs, es, S.Conn{id, auth, name, mode, True{}, db, r3}, srv, ds, ws, up, tx, pb}
    case LHeld{h}:
      LHeld{h}

# the victims killed, each another client or the client itself (after
# the reply, which comes first)
# a victim: the client itself (killed after its reply), or another
def bg.kill.of(it: Bool, +c: Cl, p: Bool & LRun) -> Bool & LRun:
  match it:
    case True{}:
      (s, g) = p
      (True{}, g)
    case False{}:
      (s, g) = p
      (s, bg.kill1(cl.id(c), cl.fd(c), g))

def bg.kill.next(vs: List<&2, Cl>, +me: Nat, p: Bool & LRun) -> Bool & LRun:
  match vs:
    case Nil{}:
      p
    case Con{+c, rest}:
      bg.kill.next(rest, me, bg.kill.of(Nat.is_eq(cl.id(c), me), c, p))

def bg.kills(vs: List<&2, Cl>, +me: Nat, g: LRun) -> Bool & LRun:
  bg.kill.next(vs, me, (False{}, g))

def bg.killed.say(p: Bool & LRun, +r: R.Reply, +code: Nat) -> LRun:
  (self, g) = p
  match self:
    case True{}:
      bg.self.kill(bg.say(r, code, g))
    case False{}:
      bg.say(r, code, g)

# CLIENT KILL: the new form answers how many it killed; the old form, of
# an address, OK, or an error when no client has it
def bg.kill(+old: Bool, f: R.Kill, +me: Nat, +code: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, ws, up, tx, +pb}:
      +vs = cl.pick(cls.all(ps.cls(pb)), f, me, pb)
      +n = List.length(&2, Cl, vs)
      +r = Bool.pick(R.Reply, old, Bool.pick(R.Reply, Nat.is_eq(n, 0n), R.RError{"ERR No such client"}, R.r_ok()), R.RInt{R.IPos{n}})
      bg.killed.say(bg.kills(vs, me, LRun{rs, es, conn, srv, ds, ws, up, tx, pb}), r, code)
    case LHeld{h}:
      LHeld{h}

def bg.noev(+id: Nat, on: Bool, +code: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, ws, up, tx, pb}:
      bg.say(R.r_ok(), code, LRun{rs, es, conn, srv, ds, ws, up, tx, ps.noev(id, on, pb)})
    case LHeld{h}:
      LHeld{h}

# the client's name, database and protocol written to the registry,
# after a command that may set them (CLIENT SETNAME, HELLO, SELECT, RESET)
def bg.conned(g: LRun) -> LRun:
  match g:
    case LRun{rs, es, +conn, srv, ds, ws, up, tx, pb}:
      LRun{rs, es, conn, srv, ds, ws, up, tx, ps.conn(conn, pb)}
    case LHeld{h}:
      LHeld{h}

# CLIENT LIST, INFO, KILL and NO-EVICT of the client of id, whose batch
# came in inb bytes, the command's arguments argv bytes
def bg.list.r(info: Bool, +ty: Nat, ids: Maybe<&2, List<&2, Nat>>, +now: Nat, +me: Who, +ws: Waits, +tx: Tx, +pb: Ps) -> R.Reply:
  match info:
    case True{}:
      cl.info(now, me, ws, tx, pb)
    case False{}:
      cl.list(ty, ids, now, me, ws, tx, pb)

# the command a client's own line shows: EXEC while it runs the client's
# transaction (Redis's last command), else CLIENT INFO or LIST
def cl.cmd.me(+info: Bool, +ex: Maybe<&2, Nat>) -> String:
  match ex:
    case Some{n}:
      "exec"
    case None{}:
      Bool.pick(String, info, "client|info", "client|list")

def bg.list(+id: Nat, +info: Bool, +ty: Nat, ids: Maybe<&2, List<&2, Nat>>, +argv: Nat, +inb: Nat, +ex: Maybe<&2, Nat>, +code: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, +conn, srv, +ds, +ws, up, +tx, +pb}:
      bg.say(bg.list.r(info, ty, ids, R.ds.now(ds), Me{id, conn, cl.cmd.me(info, ex), inb, argv, ex}, ws, tx, pb), code, LRun{rs, es, conn, srv, ds, ws, up, tx, pb})
    case LHeld{h}:
      LHeld{h}

# The sweep of expired keys
# -------------------------
# At each tick, the actor sweeps each database where some key has a time
# for keys whose time has passed (R.reap: reap.want entries a round, from
# where the last round of that database stopped), at the group's time,
# and deletes the keys it found with DEL, as a batch on that database
# would, which the append-only file logs as one. While a round finds
# expired more than one in ten of the entries it read, another one goes on
# from where it stopped, up to reap.rounds of them, as Redis's sweep goes
# on while more than a tenth of the keys it looked at had expired.
def reap.want() -> Nat:
  400n

def reap.rounds() -> Nat:
  10n

# whether a round that stopped at next (0: it read the last bucket) and
# deleted k keys is followed by another
def reap.more(+next: Nat, +k: Nat) -> Bool:
  Bool.and(Nat.is_lt(0n, next), Nat.is_lt(reap.want(), Nat.mul(10n, k)))

# the keys the sweep deleted: those the database counted before it less
# those it counts after
def reap.gone(+before: Nat, +d: R.Db) -> Nat:
  Nat.sub(before, R.db.n(d))

# a round's outcome on a database: whether another one follows, the
# server, the effects so far (newest first) and the database
type Rd is Data:
  Rd{more: Bool, srv: S.Srv, es: List<&2, A.Ent>, db: R.Db}

# a sweep starts only when some key has a time (Redis's sweep samples the
# keys with a time alone): with none, a tick reads no entry
def reap.start(srv: S.Srv, es: List<&2, A.Ent>, db: R.Db) -> Rd:
  +d = db
  Rd{Nat.is_lt(0n, R.db.x(d)), srv, es, d}

def reap.del(+i: Nat, srv: S.Srv, +next: Nat, ks: List<&2, String>, es: List<&2, A.Ent>, db: R.Db) -> Rd:
  match ks:
    case Nil{}:
      Rd{False{}, S.srv.reaped(srv, i, next, 0n), es, db}
    case Con{+k, +rest}:
      +d0 = db
      +n0 = R.db.n(d0)
      +d = R.db_of(R.exec(R.Del{k <> rest}, d0))
      +gone = reap.gone(n0, d)
      Rd{reap.more(next, gone), S.srv.reaped(srv, i, next, gone), A.EOne{A.EDb{i, R.Del{k <> rest}}} <> es, d}

def reap.done(+i: Nat, srv: S.Srv, r: R.Reap, es: List<&2, A.Ent>, db: R.Db) -> Rd:
  match r:
    case R.Reap{+next, ks}:
      reap.del(i, srv, next, ks, es, db)

def reap.round(+i: Nat, srv: S.Srv, es: List<&2, A.Ent>, db: R.Db) -> Rd:
  +d = db
  +sv = srv
  reap.done(i, sv, R.reap(d, S.srv.reap_at(sv, i), reap.want()), es, d)

def reap.run(f: Nat, +i: Nat, r: Rd) -> Rd:
  match f r:
    case 1n+g Rd{True{}, srv, es, db}:
      reap.run(g, i, reap.round(i, srv, es, db))
    case _ r0:
      r0

# the sweep of the databases from the i-th on, each at the time now: the
# server, the effects (newest first) and the databases swept, newest first
type Sw is Data:
  Sw{srv: S.Srv, es: List<&2, A.Ent>, done: List<&2, R.Db>}

def sw.put(r: Rd, done: List<&2, R.Db>) -> Sw:
  match r:
    case Rd{more, srv, es, db}:
      Sw{srv, es, db <> done}

def sweep.dbs(dbs: List<&2, R.Db>, +i: Nat, +now: Nat, w: Sw) -> Sw:
  match dbs w:
    case Nil{} w0:
      w0
    case Con{d, rest} Sw{srv, es, done}:
      sweep.dbs(rest, 1n+i, now, sw.put(reap.run(reap.rounds(), i, reap.start(srv, es, R.db.at(now, d))), done))

def sweep.fin(w: Sw, ds: R.Ds) -> S.Srv & (List<&2, A.Ent> & R.Ds):
  match w:
    case Sw{srv, es, done}:
      (srv, (es, R.ds.with(List.reverse(&2, R.Db, done), ds)))

# the sweep of every database: the server after it, the effects in front
# of es (newest first), and the databases after it, the focus where it was
def sweep(srv: S.Srv, es: List<&2, A.Ent>, ds: R.Ds) -> S.Srv & (List<&2, A.Ent> & R.Ds):
  +x = ds
  sweep.fin(sweep.dbs(R.ds.list(x), 0n, R.ds.now(x), Sw{srv, es, Nil{}}), x)

# The RDB file
# ------------
# SAVE writes the RDB file as Redis 7.0.15's saveCommand and rdbSave
# write it (rdb.bend: The file): to temp-<pid>.rdb in the directory,
# synced, renamed onto dbfilename, the directory synced; then "DB saved
# on disk", and the second of the save is LASTSAVE's (INFO's
# rdb_last_save_time, rdb_last_bgsave_status ok). A save that fails
# logs why, as Redis does, and SAVE answers -ERR. Redis saves within the
# command, the server still meanwhile; BendKV's group is pure, so SAVE's
# client waits (save.hold): in the chain of the clients that wait, as
# WAIT's does (S.BlkWait of no time: no key serves it, no time ends it),
# with the rest of its batch, and the group asks the shell for a save
# (ps.down 1). Once the group has run, the shell saves the databases as
# the group left them (the save is as late as the group's last command,
# before any of its replies goes out), answers each client that waited,
# and their batches go on at the end of a group of their own (The RDB
# file on the disk, below). SHUTDOWN that is to save (SAVE, or save
# points without NOSAVE) has its client wait the same way, so that a save
# that fails can answer it Redis's error, its batch going on, as
# finishShutdown's error path does: it asks for a save (ps.down 1, the
# server's S.srv.rdb.shut set), or with FORCE for a stop after one
# (ps.down 3). FLUSHALL, with save points, asks the shell to save the
# databases as FLUSHALL left them, empty (flushAllDataAndResetRDB),
# whatever the group did after it (S.srv.rdb.flushed); its reply is OK
# whether that save works or not.

# whether save points are set (save is not empty)
def save.points(+srv: S.Srv) -> Bool:
  Bool.not(String.is_empty(C.config.get_value(S.srv.cfg(srv), "save")))

# a client that waits for a save: the rest of its batch kept, its call
# counted now (its reply comes with the save: The RDB file on the disk),
# its channel marked with the command, and d asked of the shell (ps.down,
# never lowered)
def save.hold(+d: Nat, +id: Nat, +back: Chan(Ans), +c: R.Cmd, +code: Nat, rest: List<&2, R.Cmd>, more: List<&2, Nat>, av: Av, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, +conn, +srv, +ds, ws, up, tx, +pb}:
      +ws2 = waits.add(ws, WaitOn{id, Chan.mark(Ans, back, U32.from_nat(code), R.ds.now(ds)), conn, S.next_conn(False{}, c, conn, srv), S.BlkWait{Nil{}}, 0n, code, S.conn.db(conn), 0n, rest, more, av, WaitNone{}})
      LHeld{LRun{rs, es, conn, waits.count(ws2, gen.count(S.srv.blk(srv), code, Nil{})), ds, ws2, up, tx, ps.down.set(Nat.max(d, ps.down(pb)), pb)}}
    case LHeld{h}:
      LHeld{h}

# SAVE: counted as it runs (rdb_saves), its client waits for the save
def bg.save(+id: Nat, +back: Chan(Ans), +c: R.Cmd, +code: Nat, rest: List<&2, R.Cmd>, more: List<&2, Nat>, av: Av, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, ws, up, tx, pb}:
      save.hold(1n, id, back, c, code, rest, more, av, LRun{rs, es, conn, S.srv.rdb.save(srv), ds, ws, up, tx, pb})
    case LHeld{h}:
      LHeld{h}

# FLUSHALL that ran: with save points, the shell saves the empty
# databases once the group has run
def bg.flushall.if(on: Bool, g: LRun) -> LRun:
  match on g:
    case True{} LRun{rs, es, conn, srv, ds, ws, up, tx, +pb}:
      LRun{rs, es, conn, S.srv.rdb.flushed(srv, True{}), ds, ws, up, tx, ps.down.set(Nat.max(1n, ps.down(pb)), pb)}
    case _ g0:
      g0

def bg.flushall(g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, +srv, ds, ws, up, tx, pb}:
      bg.flushall.if(save.points(srv), LRun{rs, es, conn, srv, ds, ws, up, tx, pb})
    case LHeld{h}:
      LHeld{h}

# The pause
# ---------
# CLIENT PAUSE and CLIENT UNPAUSE run as Redis 7.0.15 runs them
# (pauseClients, unpauseClients, processCommand). A pause holds back the
# commands that write or may be replicated (WRITE: stat.pausable, and an
# EXEC whose transaction queued one) or every command (ALL), until a
# time; a pause while one holds keeps the more restrictive kind and the
# later end, and one of a timeout of 0 adds no end. A command the pause
# holds back, once the checks Redis makes before it passed (its name and
# arguments, AUTH, maxmemory, the refusals of a subscriber and of a
# monitor) and before MULTI queues it, makes its client wait (BlkPause in
# the chain of the clients that wait: Blocked clients), with the rest of
# its batch, uncounted: Redis postpones the client, and runs the command
# when the pause ends as if it came then. A monitor is never held back,
# as Redis never pauses a replica; under ALL every other command is,
# CLIENT UNPAUSE and QUIT too. The pause ends at CLIENT UNPAUSE, or at
# the first tick past its end (Redis's cron ends it): the clients it held
# back go on at the end of the group, in the order they came, each from
# the command held back. While the pause holds, the sweep of expired
# keys and eviction do not run, and nothing is refused past maxmemory, as
# Redis keeps the data set still (a key whose time passed reads as gone,
# as it always does); the sweep runs as the pause ends, as Redis's
# lookups then delete such keys. While clients are paused, every batch
# runs the general way (bit 25 of Ps's ev). CLIENT UNBLOCK of a client
# the pause holds back answers 0: Redis 7.0.15 crashes on it.

# a pause's end for a timeout of hi * 10^9 + lo ms from now: none (0) for
# a timeout of 0, or for one whose end passes a long long's range
# (Redis's end wraps to a time long past), as getTimeoutFromObjectOrReply
# makes them; 2^48 - 1, past any time, for a timeout of 2^47 ms or more
# (thousands of years: a Nat stays below 2^48); else now and the timeout
def pause.end.of(over: Bool, far: Bool, +now: Nat, +hi: Nat, +lo: Nat) -> Nat:
  match over far:
    case True{} _:
      0n
    case False{} True{}:
      Nat.sub(Nat.mul(16777216n, 16777216n), 1n)
    case False{} False{}:
      Nat.add(now, Nat.add(Nat.mul(hi, 1000000000n), lo))

def pause.end(+now: Nat, +hi: Nat, +lo: Nat) -> Nat:
  +nl = Nat.add(Nat.mod(now, 1000000000n), lo)
  +eh = Nat.add(Nat.add(Nat.div(now, 1000000000n), hi), Nat.div(nl, 1000000000n))
  pause.end.of(Bool.or(Bool.and(Nat.is_eq(hi, 0n), Nat.is_eq(lo, 0n)), Bool.not(R.ll.le(eh, Nat.mod(nl, 1000000000n), Nat.add(Nat.mul(9n, 1000000000n), 223372036n), 854775807n))), Nat.is_le(140737n, hi), now, hi, lo)

# the pause after another of its kind (all) and end
def pz.with(p: Pz, +all: Bool, +end: Nat) -> Pz:
  match p:
    case PzOff{}:
      Bool.pick(Pz, Nat.is_eq(end, 0n), PzOff{}, PzOn{all, end})
    case PzOn{+a, +e}:
      PzOn{Bool.or(a, all), Nat.max(e, end)}

def ps.pause(+all: Bool, +end: Nat, pb: Ps) -> Ps:
  match pb:
    case Ps{reg, ev, px, Cls{tab, kd, ks, ms, pz, dn, hd}, own}:
      +p = pz.with(pz, all, end)
      Ps{reg, U32.or(ev, pz.bit(p)), px, Cls{tab, kd, ks, ms, p, dn, hd}, own}
    case PsOf{p}:
      ps.pause(all, end, p)

def ps.unpause(pb: Ps) -> Ps:
  match pb:
    case Ps{reg, ev, px, Cls{tab, kd, ks, ms, pz, dn, hd}, own}:
      Ps{reg, U32.and(ev, 4261412863), px, Cls{tab, kd, ks, ms, PzOff{}, dn, hd}, own}
    case PsOf{p}:
      ps.unpause(p)

# whether a pause holds, and whether it held at now and ended
def pz.on(+p: Pz) -> Bool:
  match p:
    case PzOff{}:
      False{}
    case PzOn{all, end}:
      True{}

def pz.over(+p: Pz, +now: Nat) -> Bool:
  match p:
    case PzOff{}:
      False{}
    case PzOn{all, +end}:
      Nat.is_lt(end, now)

# whether the pause of writes holds a call of code back: a call of a
# command that writes or may be replicated, but EVAL of a script BendKV
# does not run (an error its parser found: class 2), which writes nothing
# (Redis holds back a script that does not declare no-writes, and runs
# it after)
def code.pausable(+code: Nat) -> Bool:
  +k = R.code.key(code)
  Bool.and(R.stat.pausable(k), Bool.not(Bool.and(Nat.is_eq(k, R.stat.top(65n)), Nat.is_eq(R.code.class(code), 2n))))

# whether the codes of a transaction's queued commands hold one the
# pause of writes holds back
def codes.pausable(+ks: List<&2, Nat>) -> Bool:
  match ks:
    case Nil{}:
      False{}
    case Con{+k, rest}:
      Bool.or(code.pausable(k), codes.pausable(rest))

# a command that is EXEC, of a client whose transaction (the first of
# the chain, its client's) queued a command the pause of writes holds back
def pause.exec(+c: R.Cmd, +id: Nat, +t: Tx) -> Bool:
  match c t:
    case R.Own{R.SExec{}} TxOn{+i, mu, bd, cs, qs, +qc, qa, wk, r}:
      Bool.and(Nat.is_eq(i, id), codes.pausable(qc))
    case _ _:
      False{}

# whether the pause holds a command (code) of the client of id back: a
# pause holds, the client is no monitor, the parser did not refuse the
# command, and the pause is of every command or the command is one that
# writes or may be replicated
def pause.holds(+p: Pz, +mon: Bool, +c: R.Cmd, +code: Nat, +id: Nat, +tx: Tx) -> Bool:
  match p:
    case PzOff{}:
      False{}
    case PzOn{+all, end}:
      Bool.and(Bool.not(Bool.or(mon, Nat.is_eq(R.code.class(code), 1n))), Bool.or(all, Bool.or(code.pausable(code), pause.exec(c, id, tx))))

# the clients the pause held back (hit: whether the first of ws is one),
# in the order they came, their batches to go on (up, newest first), from
# the command held back; the others kept in order (keep: those before,
# newest first)
def waits.unpause(ws: Waits, hit: Bool, keep: Waits, up: List<&2, Up>) -> Waits & List<&2, Up>:
  match ws hit:
    case WaitNone{} _:
      (waits.rev(keep, WaitNone{}), up)
    case WaitOn{id, back, c0, c1, b, argv, code, db, until, cmds, codes, av, +rest} True{}:
      waits.unpause(rest, waits.held(rest), keep, Up{back, c1, Nil{}, cmds, codes, av} <> up)
    case WaitOn{id, back, c0, c1, b, argv, code, db, until, cmds, codes, av, +rest} False{}:
      waits.unpause(rest, waits.held(rest), WaitOn{id, back, c0, c1, b, argv, code, db, until, cmds, codes, av, keep}, up)

# the size of the arguments of the request an Av's next is (argv-mem)
def got.argv(g: Got) -> Nat:
  match g:
    case Got{args, rest}:
      S.cl.argv(args, 0n)

# a command the pause holds back: its client waits with the command and
# the rest of its batch (a: their arguments as sent, from the command
# on), its call not counted; its channel marked with the command (CLIENT
# LIST's cmd while it waits, as Redis's last command), the size of its
# arguments kept (argv-mem)
def bg.postpone(+id: Nat, +back: Chan(Ans), +c: R.Cmd, +code: Nat, rest: List<&2, R.Cmd>, more: List<&2, Nat>, a: Av, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, +conn, +srv, +ds, ws, up, tx, pb}:
      +x = a
      +ws2 = waits.add(ws, WaitOn{id, Chan.mark(Ans, back, U32.from_nat(code), R.ds.now(ds)), conn, conn, S.BlkPause{}, got.argv(av.get(x)), code, S.conn.db(conn), 0n, c <> rest, code <> more, x, WaitNone{}})
      LHeld{LRun{rs, es, conn, waits.count(ws2, srv), ds, ws2, up, tx, pb}}
    case LHeld{h}:
      LHeld{h}

# CLIENT PAUSE: the pause of the kind for hi * 10^9 + lo ms from now
def bg.pause(+hi: Nat, +lo: Nat, +all: Bool, +code: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, +ds, ws, up, tx, pb}:
      bg.say(R.r_ok(), code, LRun{rs, es, conn, srv, ds, ws, up, tx, ps.pause(all, pause.end(R.ds.now(ds), hi, lo), pb)})
    case LHeld{h}:
      LHeld{h}

# the pause ended: the clients it held back go on at the end of the
# group, and the sweep of expired keys it held back runs (its DELs logged
# and touching the keys watched, its events sent, as a tick's)
def bg.swept.put(+e1: List<&2, A.Ent>, +ds: R.Ds, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, conn: S.Conn, srv: S.Srv, ws: Waits, up: List<&2, Up>, tx: Tx, pb: Ps) -> LRun:
  LRun{rs, List.append(&2, A.Ent, e1, es), conn, srv, ds, ws, up, touch.ents(tx, e1, None{}, ds), ps.trk.gone(e1, ds, ps.swept(e1, pb))}

def bg.swept(r: S.Srv & (List<&2, A.Ent> & R.Ds), rs: List<&2, R.Reply>, es: List<&2, A.Ent>, conn: S.Conn, ws: Waits, up: List<&2, Up>, tx: Tx, pb: Ps) -> LRun:
  (srv, q) = r
  (e1, ds) = q
  bg.swept.put(e1, ds, rs, es, conn, srv, ws, up, tx, pb)

def bg.resumed(p: Waits & List<&2, Up>, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, conn: S.Conn, srv: S.Srv, ds: R.Ds, tx: Tx, pb: Ps) -> LRun:
  (+ws, up) = p
  bg.swept(sweep(waits.count(ws, srv), Nil{}, ds), rs, es, conn, ws, up, tx, pb)

def bg.resume(on: Bool, g: LRun) -> LRun:
  match on g:
    case True{} LRun{rs, es, conn, srv, ds, +ws, up, tx, pb}:
      bg.resumed(waits.unpause(ws, waits.held(ws), WaitNone{}, up), rs, es, conn, srv, ds, tx, ps.unpause(pb))
    case _ g0:
      g0

# CLIENT UNPAUSE: the pause, if one holds, ends
def bg.unpause(+code: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, ws, up, tx, +pb}:
      bg.say(R.r_ok(), code, bg.resume(pz.on(ps.pz(pb)), LRun{rs, es, conn, srv, ds, ws, up, tx, pb}))
    case LHeld{h}:
      LHeld{h}

# Tracking in the shell
# ---------------------
# (Tracking in the actor, above.) CLIENT TRACKING, CACHING, GETREDIR and
# TRACKINGINFO run here; after each command of the general way, while
# the tracking has work (Ps's bit 22), the keys of a call that only reads
# go to the table for its client when it tracks them, CLIENT CACHING's
# flag is cleared, and the invalidations kept for after the command's
# reply go after it (bg.trk.after). The arguments of a batch are read
# from its bytes once a call needs its own (av.if), so that the calls
# after it find theirs read.

# CLIENT TRACKING's options checked, then on, off, or a syntax error
def bg.track.go(e: Maybe<&2, R.Reply>, +id: Nat, +rd: Nat, +b: Bool, +i: Bool, +o: Bool, +l: Bool, +gs: List<&2, String>, +code: Nat, g: LRun) -> LRun:
  match e g:
    case Some{r} g0:
      bg.say(r, code, g0)
    case None{} LRun{rs, es, conn, srv, ds, ws, up, tx, pb}:
      bg.say(R.r_ok(), code, LRun{rs, es, conn, srv, ds, ws, up, tx, ps.trk.on(id, rd, b, i, o, l, gs, pb)})
    case None{} LHeld{h}:
      LHeld{h}

def bg.track.on(+id: Nat, +rd: Nat, +b: Bool, +i: Bool, +o: Bool, +l: Bool, +gs: List<&2, String>, +code: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, ws, up, tx, +pb}:
      bg.track.go(trk.err(ps.tk(id, pb), b, i, o, gs), id, rd, b, i, o, l, gs, code, LRun{rs, es, conn, srv, ds, ws, up, tx, pb})
    case LHeld{h}:
      LHeld{h}

# the client of id stops tracking (CLIENT TRACKING off, RESET)
def bg.trk.off(+id: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, ws, up, tx, pb}:
      LRun{rs, es, conn, srv, ds, ws, up, tx, ps.trk.off(id, pb)}
    case LHeld{h}:
      LHeld{h}

def bg.track.ok(+on: Nat, q: Tq, +id: Nat, +code: Nat, g: LRun) -> LRun:
  match on q:
    case _ TqBad{r}:
      bg.say(r, code, g)
    case 1n TqOk{+rd, +b, +i, +o, +l, p}:
      bg.track.on(id, rd, b, i, o, l, List.reverse(&2, String, p), code, g)
    case 0n TqOk{rd, b, i, o, l, p}:
      bg.say(R.r_ok(), code, bg.trk.off(id, g))
    case _ TqOk{rd, b, i, o, l, p}:
      bg.say(R.RError{"ERR syntax error"}, code, g)

def bg.track(+id: Nat, +on: Nat, opts: List<&2, R.TOpt>, +code: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, ws, up, tx, +pb}:
      bg.track.ok(on, tq.go(opts, TqOk{0n, False{}, False{}, False{}, False{}, Nil{}}, ps.cls(pb)), id, code, LRun{rs, es, conn, srv, ds, ws, up, tx, pb})
    case LHeld{h}:
      LHeld{h}

# CLIENT CACHING yes (1), no (0) or neither (2): its error for the
# client's tracking t, or none when the flag is set
def caching.err(+t: Tk, +yes: Nat) -> Maybe<&2, R.Reply>:
  match yes:
    case 1n:
      err.of(Bool.not(tk.optin(t)), "ERR CLIENT CACHING YES is only valid when tracking is enabled in OPTIN mode.")
    case 0n:
      err.of(Bool.not(tk.optout(t)), "ERR CLIENT CACHING NO is only valid when tracking is enabled in OPTOUT mode.")
    case _:
      Some{R.RError{"ERR syntax error"}}

def caching.check(+t: Tk, +yes: Nat) -> Maybe<&2, R.Reply>:
  Bool.pick(Maybe<&2, R.Reply>, tk.on(t), caching.err(t, yes), Some{R.RError{"ERR CLIENT CACHING can be called only when the client is in tracking mode with OPTIN or OPTOUT mode enabled"}})

def bg.caching.go(e: Maybe<&2, R.Reply>, +id: Nat, +code: Nat, g: LRun) -> LRun:
  match e g:
    case Some{r} g0:
      bg.say(r, code, g0)
    case None{} LRun{rs, es, conn, srv, ds, ws, up, tx, pb}:
      bg.say(R.r_ok(), code, LRun{rs, es, conn, srv, ds, ws, up, tx, ps.trk.caching(id, True{}, pb)})
    case None{} LHeld{h}:
      LHeld{h}

def bg.caching(+id: Nat, +yes: Nat, +code: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, ws, up, tx, +pb}:
      bg.caching.go(caching.check(ps.tk(id, pb), yes), id, code, LRun{rs, es, conn, srv, ds, ws, up, tx, pb})
    case LHeld{h}:
      LHeld{h}

# CLIENT GETREDIR (the redirect, -1 when the client does not track) and
# CLIENT TRACKINGINFO (info)
def tk.getredir(+t: Tk) -> R.Reply:
  Bool.pick(R.Reply, tk.on(t), R.RInt{R.IPos{tk.redir(t)}}, R.RInt{R.INeg{0n}})

def bg.trk.say(+id: Nat, +info: Bool, +code: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, ws, up, tx, +pb}:
      +t = ps.tk(id, pb)
      bg.say(Bool.pick(R.Reply, info, tk.info(t), tk.getredir(t)), code, LRun{rs, es, conn, srv, ds, ws, up, tx, pb})
    case LHeld{h}:
      LHeld{h}

# the arguments of the request an Av's next is, read from the batch's
# bytes if they were not
def av.now(+a: Av) -> List<&2, String>:
  match a:
    case AvArgs{+xs}:
      av.first(xs)
    case AvRaw{+raw, +n}:
      av.first(List.drop(&2, List<&2, String>, P.argvs(raw), n))

# a batch's arguments from its next request on, read from its bytes when
# a call needs its own (on)
def av.read(+a: Av) -> Av:
  match a:
    case AvRaw{+raw, +n}:
      AvArgs{List.drop(&2, List<&2, String>, P.argvs(raw), n)}
    case AvArgs{+xs}:
      AvArgs{xs}

def av.if(on: Bool, +a: Av) -> Av:
  match on:
    case True{}:
      av.read(a)
    case False{}:
      a

# whether a call's key is one of CLIENT's subcommands' (after any of them
# Redis keeps CLIENT CACHING's flag: resetClient; CLIENT alone, which
# Redis refuses before any runs, and an unknown subcommand, have no
# clientCommand, and clear it)
def trk.client.key(+key: Nat) -> Bool:
  Bool.and(Nat.is_le(R.stat.sub.client(1n), key), Nat.is_le(key, R.stat.sub.client(16n)))

# whether a command the shell runs as the session runs it was called: its
# client may run it, has not quit, and the parser did not refuse it
def sh.ran(+s: Sh, +q: Bool, +may: Bool, +code: Nat) -> Bool:
  match s:
    case ShRun{}:
      Bool.and(Bool.and(Bool.not(q), may), Bool.not(Nat.is_eq(R.code.class(code), 1n)))
    case _:
      False{}

# whether a call's keys go to the table: its client tracks them (kt), it
# only reads, and it was called (ran)
def trk.wants(+kt: Tk, +code: Nat, +ran: Bool) -> Bool:
  Bool.and(Bool.and(tk.reads(kt), R.stat.ro(R.code.key(code))), ran)

def bg.trk.read.if(on: Bool, +id: Nat, +code: Nat, +a: Av, pb: Ps) -> Ps:
  match on:
    case True{}:
      ps.trk.read(id, M.keys.read(R.code.key(code), av.now(a)), pb)
    case False{}:
      pb

def bg.trk.cache.if(on: Bool, +id: Nat, pb: Ps) -> Ps:
  match on:
    case True{}:
      ps.trk.caching(id, False{}, pb)
    case False{}:
      pb

def bg.trk.pend(p: List<&2, R.Reply> & Ps, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, conn: S.Conn, srv: S.Srv, ds: R.Ds, ws: Waits, up: List<&2, Up>, tx: Tx) -> LRun:
  (xs, pb) = p
  LRun{List.append(&2, R.Reply, xs, rs), es, conn, srv, ds, ws, up, tx, pb}

# whether a call may set tracking-table-max-keys or start the tracking:
# CONFIG SET, EXEC (which may run one) and CLIENT TRACKING; after one,
# the table's limit is read again from the parameters (Trk's max), and
# after no other
def trk.max.key(+key: Nat) -> Bool:
  Bool.or(Nat.is_eq(key, R.stat.sub.config(2n)), Bool.or(Nat.is_eq(key, R.stat.top(162n)), Nat.is_eq(key, R.stat.sub.client(16n))))

def bg.trk.max(on: Bool, g: LRun) -> LRun:
  match on g:
    case True{} LRun{rs, es, conn, +srv, ds, ws, up, tx, pb}:
      LRun{rs, es, conn, srv, ds, ws, up, tx, ps.trk.max.put(S.cfg.nat(S.srv.cfg(srv), "tracking-table-max-keys"), pb)}
    case _ g0:
      g0

def bg.trk.after.go(g: LRun, +rk: Bool, +id: Nat, +code: Nat, +kt: Tk, +a: Av) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, ws, up, +tx, pb}:
      +key = R.code.key(code)
      +clear = Bool.and(Bool.or(tk.caching(kt), Nat.is_eq(key, R.stat.top(162n))), Bool.and(Bool.not(trk.client.key(key)), Bool.not(tx.multi(id, tx))))
      bg.trk.max(trk.max.key(R.code.key(code)), bg.trk.pend(ps.pend.take(bg.trk.cache.if(clear, id, bg.trk.read.if(rk, id, code, a, pb))), rs, es, conn, srv, ds, ws, up, tx))
    case LHeld{h}:
      LHeld{bg.trk.after.go(h, False{}, id, code, kt, a)}

# whether the tracking has work after a command (Ps's bit 22)
def bg.trk.hot(+g: LRun) -> Bool:
  match g:
    case LRun{rs, es, conn, srv, ds, ws, up, tx, +pb}:
      ps.trk.hot(pb)
    case LHeld{+h}:
      bg.trk.hot(h)

# a call's tracking, read before it runs: none while the tracking has no
# work (Ps's bit 22), or the tracking of its client (kt) and whether the
# call's keys go to the table (rk: trk.wants). One value, so that the
# general way's loop (bg.go) makes one call for it, and saves its frame
# once, while no client tracks
type TkPre is Data:
  TkPreOff{}
  TkPreOn{kt: Tk, rk: Bool}

def bg.trk.pre.on(on: Bool, +id: Nat, +code: Nat, +s: Sh, +q: Bool, +may: Bool, +pb: Ps) -> TkPre:
  match on:
    case True{}:
      +kt = ps.tk(id, pb)
      TkPreOn{kt, trk.wants(kt, code, sh.ran(s, q, may, code))}
    case False{}:
      TkPreOff{}

def bg.trk.pre(+id: Nat, +code: Nat, +s: Sh, +q: Bool, +may: Bool, +pb: Ps) -> TkPre:
  bg.trk.pre.on(ps.trk.hot(pb), id, code, s, q, may, pb)

# the call's own arguments, read from the batch's bytes when its keys go
# to the table (av.if)
def trk.pre.av(+p: TkPre, +a: Av) -> Av:
  match p:
    case TkPreOn{kt, +rk}:
      av.if(rk, a)
    case TkPreOff{}:
      a

def bg.trk.after.hot(on: Bool, +id: Nat, +code: Nat, +a: Av, g: LRun) -> LRun:
  match on:
    case True{}:
      bg.trk.after.go(g, False{}, id, code, TkOff{}, a)
    case False{}:
      g

# after a command of the client of id: the tracking's step when it had
# work before the command (p) or has after it
def bg.trk.after(+p: TkPre, +id: Nat, +code: Nat, +a: Av, g: LRun) -> LRun:
  match p:
    case TkPreOn{+kt, +rk}:
      bg.trk.after.go(g, rk, id, code, kt, a)
    case TkPreOff{}:
      +h = g
      bg.trk.after.hot(bg.trk.hot(h), id, code, a, h)

# whether a call of EXEC's that only reads goes to the table: its client
# tracks its keys, while the tracking has work (on)
def bg.x.rk.on(on: Bool, +id: Nat, +may: Bool, +code: Nat, +pb: Ps) -> Bool:
  match on:
    case True{}:
      trk.wants(ps.tk(id, pb), code, mon.ran(may, code))
    case False{}:
      False{}

def bg.x.rk(+id: Nat, +may: Bool, +code: Nat, +pb: Ps) -> Bool:
  bg.x.rk.on(ps.trk.hot(pb), id, may, code, pb)

# a call of EXEC's that only reads, of a client that tracks its keys
def bg.x.trk(on: Bool, +id: Nat, +code: Nat, +a: Av, g: LRun) -> LRun:
  match on g:
    case True{} LRun{rs, es, conn, srv, ds, ws, up, tx, pb}:
      LRun{rs, es, conn, srv, ds, ws, up, tx, ps.trk.read(id, M.keys.read(R.code.key(code), av.now(a)), pb)}
    case _ g0:
      g0

def bg.client(+id: Nat, op: R.ClOp, +argv: Nat, +inb: Nat, +ex: Maybe<&2, Nat>, +code: Nat, g: LRun) -> LRun:
  match op:
    case R.CoList{+ty, ids}:
      bg.list(id, False{}, ty, ids, argv, inb, ex, code, g)
    case R.CoInfo{}:
      bg.list(id, True{}, 0n, None{}, argv, inb, ex, code, g)
    case R.CoKill{f}:
      bg.kill(False{}, f, id, code, g)
    case R.CoKillAddr{a}:
      bg.kill(True{}, R.Kill{Some{a}, None{}, None{}, 0n, False{}}, id, code, g)
    case R.CoNoEvict{on}:
      bg.noev(id, on, code, g)
    case R.CoPause{+hi, +lo, +all}:
      bg.pause(hi, lo, all, code, g)
    case R.CoUnpause{}:
      bg.unpause(code, g)
    case R.CoTrack{+on, opts}:
      bg.track(id, on, opts, code, g)
    case R.CoCaching{+yes}:
      bg.caching(id, yes, code, g)
    case R.CoGetRedir{}:
      bg.trk.say(id, False{}, code, g)
    case R.CoTrackInfo{}:
      bg.trk.say(id, True{}, code, g)
    case R.CoBad{+r}:
      bg.say(r, code, g)

# a command of EXEC: as it runs outside of a transaction, but that no
# client waits (a blocking command answers as for a client that may not
# wait: the session's pop, run once) and the clients that wait are
# served only after EXEC; a command of Pub/Sub runs as outside of one,
# but SSUBSCRIBE, which Redis refuses to a client that may not wait, as
# PING answers as to a client with a subscription when the client has
# one by then; CLIENT LIST and INFO show the client as Redis does while
# EXEC runs: in MULTI with its commands queued (n), its last command
# EXEC, the bytes of EXEC's batch (inb) and EXEC's argument (4)
def bg.x.ping(on: Bool, +m: String, +c: R.Cmd, +code: Nat, g: LRun) -> LRun:
  match on:
    case True{}:
      bg.say(R.RArray{[R.RBulk{"pong"}, R.RBulk{m}]}, code, g)
    case False{}:
      bg.one(c, code, g)

def bg.x.pong(+id: Nat, +m: String, +c: R.Cmd, +code: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, +conn, srv, ds, ws, up, tx, +pb}:
      bg.x.ping(Bool.and(ps.has(id, pb), Bool.not(S.conn.r3(conn))), m, c, code, LRun{rs, es, conn, srv, ds, ws, up, tx, pb})
    case LHeld{h}:
      LHeld{h}

def bg.x.echo(ping: Bool, +id: Nat, +m: String, +c: R.Cmd, +code: Nat, g: LRun) -> LRun:
  match ping:
    case True{}:
      bg.x.pong(id, m, c, code, g)
    case False{}:
      bg.one(c, code, g)

def bg.x.cmd(may: Bool, +id: Nat, +back: Chan(Ans), +inb: Nat, +n: Nat, +c: R.Cmd, +code: Nat, g: LRun) -> LRun:
  match may c:
    case True{} R.Own{R.SUnblock{+n, +e}}:
      bg.unblock(n, e, code, g)
    case True{} R.Own{R.SPub{2n, ns}}:
      bg.say(R.RError{"ERR SSUBSCRIBE isn't allowed for a DENY BLOCKING client"}, code, g)
    case True{} R.Own{R.SMonitor{}}:
      bg.say(R.RError{"ERR MONITOR isn't allowed for DENY BLOCKING client"}, code, g)
    case True{} R.Own{R.SRewrite{}}:
      bg.rewrite(True{}, code, g)
    case True{} R.Own{R.SFlushAll{}}:
      bg.flushall(bg.one(c, code, g))
    case True{} R.Own{R.SPub{+k, a}}:
      bg.pub(id, back, R.pub.op(k, a), code, g)
    case True{} R.Own{R.SClient{+k, +a}}:
      bg.client(id, R.client.op(k, a), 4n, inb, Some{n}, code, g)
    case True{} R.Own{R.SClientSetName{n}}:
      bg.conned(bg.one(c, code, g))
    case True{} R.Own{R.SSelect{d}}:
      bg.conned(bg.one(c, code, g))
    case True{} R.Ping{}:
      bg.x.pong(id, "", c, code, g)
    case True{} R.Echo{+m}:
      bg.x.echo(Nat.is_eq(R.code.key(code), R.stat.top(1n)), id, m, c, code, g)
    case _ _:
      bg.one(c, code, g)

def bg.x.go(+id: Nat, +back: Chan(Ans), +inb: Nat, +n: Nat, cmds: List<&2, R.Cmd>, codes: List<&2, Nat>, avs: List<&2, Av>, x: Xr) -> Xr:
  match cmds codes avs x:
    case Con{+c, rest} Con{+k, more} Con{+a, ar} Xr{LRun{rs, es, +conn, +srv, ds, ws, up, tx, +pb}, mine}:
      +may = S.may(S.kind(c), conn, srv)
      +rk = bg.x.rk(id, may, k, pb)
      bg.x.go(id, back, inb, n, rest, more, ar, bg.x.feed(mon.ran(may, k), id, k, S.conn.mode(conn), a, bg.x.trk(rk, id, k, a, bg.x.cmd(may, id, back, inb, n, c, k, LRun{rs, es, conn, S.srv.call(srv, id, av.arg(a)), ds, ws, up, tx, pb})), mine))
    case _ _ _ x0:
      x0

def bg.exec.run(+id: Nat, +back: Chan(Ans), +inb: Nat, +code: Nat, +cmds: List<&2, R.Cmd>, codes: List<&2, Nat>, avs: List<&2, Av>, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, +conn, srv, ds, ws, up, tx, pb}:
      +m0 = S.conn.mode(conn)
      +mi = exec.mode(m0)
      bg.exec.done(rs, es, m0, mi, code, bg.x.go(id, back, inb, List.length(&2, R.Cmd, cmds), cmds, codes, avs, Xr{LRun{Nil{}, Nil{}, conn.mode.set(mi, conn), srv, ds, ws, up, tx, pb}, Nil{}}))
    case LHeld{h}:
      LHeld{h}

def bg.exec.if(late: Bool, +id: Nat, +back: Chan(Ans), +inb: Nat, +code: Nat, qs: List<&2, R.Cmd>, qc: List<&2, Nat>, qa: List<&2, Av>, g: LRun) -> LRun:
  match late:
    case True{}:
      bg.say(R.RNullA{}, code, g)
    case False{}:
      bg.exec.run(id, back, inb, code, List.reverse(&2, R.Cmd, qs), List.reverse(&2, Nat, qc), List.reverse(&2, Av, qa), g)

# EXEC of a transaction taken out of the chain (mine): EXECABORT when a
# command was refused while it queued, a null array when a watched key
# was touched or is there with its time passed now, else its commands
# past maxmemory with nothing left to evict, an EXEC whose transaction
# queued a command that may take memory is refused: the transaction is
# dropped, as Redis's execCommandAbort drops it
def codes.denyoom(+ks: List<&2, Nat>) -> Bool:
  match ks:
    case Nil{}:
      False{}
    case Con{+k, rest}:
      Bool.or(R.stat.denyoom(R.code.key(k)), codes.denyoom(rest))

def tx.denyoom(+t: Tx) -> Bool:
  match t:
    case TxOn{i, mu, bad, cas, cs, +qc, qa, wk, r}:
      codes.denyoom(qc)
    case TxNone{}:
      False{}

def bg.exec.go(mine: Tx, others: Tx, +id: Nat, +back: Chan(Ans), +inb: Nat, +code: Nat, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, conn: S.Conn, srv: S.Srv, +ds: R.Ds, ws: Waits, up: List<&2, Up>, pb: Ps) -> LRun:
  match mine:
    case TxOn{i, mu, True{}, cs, qs, qc, qa, wk, r}:
      bg.say(R.RError{"EXECABORT Transaction discarded because of previous errors."}, code, LRun{rs, es, conn, srv, ds, ws, up, others, pb})
    case TxOn{i, mu, False{}, True{}, qs, qc, qa, wk, r}:
      bg.say(R.RNullA{}, code, LRun{rs, es, conn, srv, ds, ws, up, others, pb})
    case TxOn{i, mu, False{}, False{}, qs, qc, qa, +wk, r}:
      bg.exec.if(wk.late(wk, ds, R.ds.now(ds)), id, back, inb, code, qs, qc, qa, LRun{rs, es, conn, srv, ds, ws, up, others, pb})
    case TxNone{}:
      bg.say(R.RError{"ERR EXEC without MULTI"}, code, LRun{rs, es, conn, srv, ds, ws, up, others, pb})

def bg.exec.oom(oom: Bool, mine: Tx, others: Tx, +id: Nat, +back: Chan(Ans), +inb: Nat, +code: Nat, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, conn: S.Conn, srv: S.Srv, +ds: R.Ds, ws: Waits, up: List<&2, Up>, pb: Ps) -> LRun:
  match oom:
    case True{}:
      bg.one(R.Own{R.SBad{R.RError{"EXECABORT Transaction discarded because of: " ++ abort.why(oom.msg())}}}, R.code.refused(code), LRun{rs, es, conn, srv, ds, ws, up, others, pb})
    case False{}:
      bg.exec.go(mine, others, id, back, inb, code, rs, es, conn, srv, ds, ws, up, pb)

def bg.exec.of(p: Tx & Tx, +id: Nat, +back: Chan(Ans), +inb: Nat, +code: Nat, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, conn: S.Conn, srv: S.Srv, +ds: R.Ds, ws: Waits, up: List<&2, Up>, +pb: Ps) -> LRun:
  (+mine, others) = p
  bg.exec.oom(Bool.and(ps.oom.is(pb), tx.denyoom(mine)), mine, others, id, back, inb, code, rs, es, conn, srv, ds, ws, up, pb)

def bg.exec(+id: Nat, +back: Chan(Ans), +inb: Nat, +code: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, +ds, ws, up, +tx, pb}:
      bg.exec.of(tx.take(tx, tx.is(id, tx), id, TxNone{}), id, back, inb, code, rs, es, conn, srv, ds, ws, up, pb)
    case LHeld{h}:
      LHeld{h}

# SHUTDOWN
# --------
# SHUTDOWN stops the server as Redis 7.0.15's shutdownCommand does when no
# replica waits (prepareForShutdown, finishShutdown): the group's entries
# written to the append-only file as after any group, and the file synced,
# a rewrite's temporary file removed, the pid file too, then exit(0); its
# client is answered nothing, its connection ending with the process. The
# commands after it in its batch and the requests after it in the group do
# not run (ps.killed answers their clients Bye), nor does the end of the
# group (grp.end) or a tick in it, as Redis exits within the command.
# With SAVE, or with save points and without NOSAVE, the RDB file is
# saved first, after the append-only file's sync, as finishShutdown saves
# it (The RDB file); a save that fails stops nothing but with FORCE: the
# server goes on, the log saying why, and SHUTDOWN's client is answered
# "Errors trying to SHUTDOWN. Check logs.", the rest of its batch going
# on (its client waited for the save, as SAVE's does). As that save may
# fail, the group goes on after such a SHUTDOWN without FORCE, its end
# and ticks too, as after a SAVE: when the save ends well and the server
# stops, the replies of the requests after it are not sent, and what they
# wrote is in the files, written and not acknowledged, as a crash may
# leave a write (Redis would not have run them). The registry of clients
# keeps what the group asked for (ps.down), and bits 23 and 24 of Ps's ev
# keep the batches after it off the fast way; the shell acts on it once
# the group is run (db_group, aof_reply).
def bg.down.at(+d: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, ws, up, tx, pb}:
      LRun{rs, es, conn, srv, ds, ws, up, tx, ps.down.set(d, pb)}
    case LHeld{h}:
      LHeld{h}

# with no save to make (NOSAVE, or neither SAVE nor save points), the
# server stops once the group is run (2); else SHUTDOWN's client waits
# for the save, as SAVE's does (save.hold), and the server stops after it
# unless it fails (1, the server's S.srv.rdb.shut set), or after it all
# the same (3: FORCE)
def bg.down.shut(g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, ws, up, tx, pb}:
      LRun{rs, es, conn, S.srv.rdb.shutting(srv, True{}), ds, ws, up, tx, pb}
    case LHeld{h}:
      LHeld{h}

def bg.down.go(want: Bool, +force: Bool, +id: Nat, +back: Chan(Ans), +c: R.Cmd, +code: Nat, rest: List<&2, R.Cmd>, more: List<&2, Nat>, av: Av, g: LRun) -> LRun:
  match want:
    case False{}:
      LHeld{bg.down.at(2n, g)}
    case True{}:
      save.hold(Bool.pick(Nat, force, 3n, 1n), id, back, c, code, rest, more, av, bg.down.shut(g))

def bg.down(+save: Bool, +nosave: Bool, +force: Bool, +id: Nat, +back: Chan(Ans), +c: R.Cmd, +code: Nat, rest: List<&2, R.Cmd>, more: List<&2, Nat>, av: Av, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, +srv, ds, ws, up, tx, pb}:
      bg.down.go(Bool.or(save, Bool.and(Bool.not(nosave), save.points(srv))), force, id, back, c, code, rest, more, av, LRun{rs, es, conn, srv, ds, ws, up, tx, pb})
    case LHeld{h}:
      LHeld{h}

def bg.cmd(+id: Nat, +back: Chan(Ans), +inb: Nat, sh: Sh, +c: R.Cmd, +code: Nat, rest: List<&2, R.Cmd>, more: List<&2, Nat>, +a: Av, +ar: Av, g: LRun) -> LRun:
  match sh:
    case ShRun{}:
      +l = g
      bg.one.serve(bg.stir(c, l), c, code, l)
    case ShWait{b}:
      bg.wait(id, back, b, c, code, rest, more, ar, g)
    case ShUnblock{+n, +e}:
      bg.unblock(n, e, code, g)
    case ShMulti{}:
      bg.one(c, code, bg.open(id, g))
    case ShNested{}:
      bg.say(R.RError{"ERR MULTI calls can not be nested"}, code, g)
    case ShExec{}:
      bg.serve(bg.exec(id, back, inb, code, g))
    case ShAbort{m}:
      bg.one(R.Own{R.SBad{R.RError{"EXECABORT Transaction discarded because of: " ++ m}}}, R.code.refused(code), bg.close(id, g))
    case ShDiscard{}:
      bg.say(R.r_ok(), code, bg.close(id, g))
    case ShWatch{ks}:
      bg.one(c, code, bg.watch(id, ks, g))
    case ShWatchIn{}:
      bg.say(R.RError{"ERR WATCH inside MULTI is not allowed"}, code, g)
    case ShUnwatch{}:
      bg.one(c, code, bg.unwatch(id, g))
    case ShReset{}:
      bg.conned(bg.one(c, code, bg.trk.off(id, bg.unsub.all(id, bg.close(id, g)))))
    case ShQueue{}:
      bg.queue(c, code, a, g)
    case ShRefuse{}:
      bg.one(c, code, bg.bad(g))
    case ShPub{op}:
      bg.pub(id, back, op, code, g)
    case ShPing{m}:
      bg.say(R.RArray{[R.RBulk{"pong"}, R.RBulk{m}]}, code, g)
    case ShDeny{name}:
      bg.one(R.Own{R.SBad{R.RError{"ERR " ++ sub.deny(name)}}}, R.code.refused(code), g)
    case ShClient{op, +argv}:
      bg.client(id, op, argv, inb, None{}, code, g)
    case ShConn{}:
      bg.conned(bg.one(c, code, g))
    case ShMonitor{}:
      bg.monitor(id, back, code, g)
    case ShRewrite{}:
      bg.rewrite(False{}, code, g)
    case ShOom{inm}:
      bg.one(R.Own{R.SBad{R.RError{oom.msg()}}}, R.code.refused(code), bg.oom.tx(inm, g))
    case ShMonDeny{inm}:
      bg.one(R.Own{R.SBad{R.RError{"ERR Replica can't interact with the keyspace"}}}, R.code.refused(code), bg.mon.bad(inm, g))
    case ShPause{}:
      bg.postpone(id, back, c, code, rest, more, a, g)
    case ShDown{+save, +nosave, +force}:
      bg.down(save, nosave, force, id, back, c, code, rest, more, ar, g)
    case ShNoMulti{}:
      bg.one(R.Own{R.SBad{R.RError{"ERR Command not allowed inside a transaction"}}}, R.code.refused(code), bg.bad(g))
    case ShSave{}:
      bg.save(id, back, c, code, rest, more, ar, g)
    case ShFlush{}:
      +l = g
      bg.flushall(bg.one.serve(bg.stir(c, l), c, code, l))

# a batch the general way: a command at a time, until its client waits;
# after each, its line to the monitors (MONITOR), the arguments of the
# batch's requests as sent (the Fed's Av) read once a line needs them
def bg.go(+id: Nat, +back: Chan(Ans), +inb: Nat, cmds: List<&2, R.Cmd>, codes: List<&2, Nat>, f: Fed) -> LRun:
  match cmds codes f:
    case Con{+c, +rest} Con{+k, +more} Fed{LRun{rs, es, +conn, +srv, +ds, ws, up, +tx, +pb}, +av}:
      +q = S.conn.quit(conn)
      +may = S.may(S.kind(c), conn, srv)
      +mo = ps.mon.is(id, pb)
      +sh = sh.of(q, may, tx.multi(id, tx), Bool.and(ps.has(id, pb), Bool.not(S.conn.r3(conn))), mo, ps.oom.is(pb), pause.holds(ps.pz(pb), mo, c, k, id, tx), c, k, ds)
      +pre = bg.trk.pre(id, k, sh, q, may, pb)
      +a = trk.pre.av(pre, av)
      +ar = av.rest(a)
      +g1 = bg.cmd(id, back, inb, sh, c, k, rest, more, a, ar, LRun{rs, es, conn, S.srv.call(srv, id, av.arg(a)), ds, ws, up, tx, pb})
      bg.go(id, back, inb, rest, more, bg.feed(mon.seen(q, may, sh, k), id, k, S.conn.mode(conn), a, ar, bg.trk.after(pre, id, k, a, g1)))
    case _ _ Fed{g0, av}:
      g0

# the answer to a batch whose client waits: the replies before its
# blocking command, encoded (none when there are none)
def hold_of(rs: List<&2, R.Reply>, +cn: S.Conn) -> Ans:
  match rs:
    case Nil{}:
      Hold{None{}}
    case Con{+r, +rest}:
      Hold{Some{P.encode_as(sw.first(r <> rest, S.conn.r3(cn)), r <> rest)}}

# a batch run the general way, put in the group: the pushes it made,
# then its answer (AnsSub when its client has a subscription after it),
# and its bytes for INFO (inb: those it came in, counted once)
def bg.out(+back: Chan(Ans), a: Ans, p: Ps & List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, +srv: S.Srv, ds: R.Ds, ws: Waits, up: List<&2, Up>, tx: Tx) -> Grp:
  (pb, outs) = p
  Grp{(back, a) <> outs, es, srv, ds, ws, up, tx, ps.tune(pb, srv)}

# a client that quits has its subscriptions dropped at once, as Redis
# frees it once its last reply is written, before it reads more
def ps.quit(quit: Bool, +id: Nat, pb: Ps) -> Ps:
  match quit:
    case True{}:
      ps.drop(id, pb)
    case False{}:
      pb

def bg.put(+back: Chan(Ans), +inb: Nat, g: LRun, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>) -> Grp:
  match g:
    case LRun{rs, es, +conn, srv, ds, ws, up, tx, pb}:
      +p = ps.quit(S.conn.quit(conn), S.conn.id(conn), ps.mon.end(conn, pb))
      +a = ans.sub(Bool.or(Bool.or(ps.has(S.conn.id(conn), p), ps.mon.is(S.conn.id(conn), p)), ps.trk.waits(S.conn.id(conn), p)), ans_of.gen(List.reverse(&2, R.Reply, rs), conn))
      +outb = ans.len(a)
      bg.out(back, a, ps.flush(p, outs), es, S.srv.ran(srv, 0n, 0n, Nil{}, inb, outb), ds, ws, up, tx)
    case LHeld{LRun{rs, es, +conn, srv, ds, ws, up, tx, pb}}:
      +a = hold_of(List.reverse(&2, R.Reply, rs), conn)
      +outb = ans.len(a)
      bg.out(back, a, ps.flush(pb, outs), es, S.srv.ran(srv, 0n, 0n, Nil{}, inb, outb), ds, ws, up, tx)
    case LHeld{LHeld{h}}:
      bg.put(back, inb, h, outs)

def bg.batch(+cn: S.Conn, +back: Chan(Ans), +inb: Nat, raw: String, cmds: List<&2, R.Cmd>, codes: List<&2, Nat>, g: Grp) -> Grp:
  match g:
    case Grp{outs, es, srv, ds, ws, up, tx, pb}:
      +id = S.conn.id(cn)
      bg.put(back, inb, bg.go(id, back, inb, cmds, codes, Fed{LRun{Nil{}, es, cn, srv, ds, ws, up, tx.front(id, tx), pb}, AvRaw{raw, 0n}}), outs)

# the last of codes, else k
def codes.last(+ks: List<&2, Nat>, +k: Nat) -> Nat:
  match ks:
    case Nil{}:
      k
    case Con{+x, rest}:
      codes.last(rest, x)

# an unblocked client's channel marked with the code of the last command
# of the rest of its batch, which runs now (else still the blocking
# command's), at the time of its batch
def mark.up.of(+back: Chan(Ans), mk: U32 & Nat, +codes: List<&2, Nat>) -> Chan(Ans):
  (w, at) = mk
  Chan.mark(Ans, back, U32.from_nat(codes.last(codes, U32.to_nat(w))), at)

def mark.up(+back: Chan(Ans), +codes: List<&2, Nat>) -> Chan(Ans):
  mark.up.of(back, Chan.marked(Ans, back), codes)

# an unblocked client's batch, on: on its database, after its reply
def bg.up(u: Up, g: Grp) -> Grp:
  match u g:
    case Up{+back, +conn, rs, cmds, +codes, av} Grp{outs, es, srv, ds, ws, up, tx, pb}:
      +id = S.conn.id(conn)
      bg.put(mark.up(back, codes), 0n, bg.go(id, back, 0n, cmds, codes, Fed{LRun{rs, es, conn, srv, R.ds.focus(S.conn.db(conn), ds), ws, up, tx.front(id, tx), pb}, av}), outs)

def bg.ups.run(us: List<&2, Up>, g: Grp) -> Grp:
  match us:
    case Nil{}:
      g
    case Con{u, rest}:
      bg.ups.run(rest, bg.up(u, g))

# the unblocked clients' batches, oldest first, until none is left: those
# they unblock go on in a round of their own (fuel: each round runs a
# blocking command at least, of the batches left)
def bg.ups(f: Nat, g: Grp) -> Grp:
  match f g:
    case 1n+h Grp{outs, es, srv, ds, ws, Con{u, more}, tx, pb}:
      bg.ups(h, bg.ups.run(List.reverse(&2, Up, u <> more), Grp{outs, es, srv, ds, ws, Nil{}, tx, pb}))
    case _ g0:
      g0

def ups.fuel() -> Nat:
  1000000n

def grp.late(p: Waits & List<&2, Up>, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, srv: S.Srv, ds: R.Ds, tx: Tx, pb: Ps) -> Grp:
  (+ws, up) = p
  bg.ups(ups.fuel(), Grp{outs, es, waits.count(ws, srv), ds, ws, up, tx, ps.soon.set(waits.soon(ws, 0n), pb)})

# the end of a group while some client waits: the clients whose time is
# up unblocked when one's may be (due: before now the earliest end, kept
# with the heeded keys: Heeded keys), the earliest end found anew; else
# the chain as it was, without a walk of it, and the unblocked clients'
# batches on
def grp.end.due(due: Bool, +now: Nat, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, srv: S.Srv, ds: R.Ds, ws: Waits, up: List<&2, Up>, tx: Tx, pb: Ps) -> Grp:
  match due up:
    case True{} u0:
      +w = ws
      grp.late(waits.expire(w, waits.late(now, w), now, WaitNone{}, u0), outs, es, srv, ds, tx, pb)
    case False{} Nil{}:
      Grp{outs, es, srv, ds, ws, Nil{}, tx, pb}
    case False{} Con{u, more}:
      bg.ups(ups.fuel(), Grp{outs, es, srv, ds, ws, u <> more, tx, pb})

# the end of a group: the clients whose time is up unblocked, then the
# unblocked clients' batches go on; nothing after a SHUTDOWN that stops
# the server
def grp.end.go(g: Grp) -> Grp:
  match g:
    case Grp{outs, es, srv, ds, WaitNone{}, Nil{}, tx, pb}:
      Grp{outs, es, srv, ds, WaitNone{}, Nil{}, tx, pb}
    case Grp{outs, es, srv, ds, WaitNone{}, Con{u, more}, tx, pb}:
      bg.ups(ups.fuel(), Grp{outs, es, srv, ds, WaitNone{}, u <> more, tx, pb})
    case Grp{outs, es, srv, +ds, ws, up, tx, +pb}:
      +now = R.ds.now(ds)
      grp.end.due(waits.due(now, ps.soon(pb)), now, outs, es, srv, ds, ws, up, tx, pb)

def grp.down(+g: Grp) -> Nat:
  match g:
    case Grp{outs, es, srv, ds, ws, up, tx, +pb}:
      ps.down(pb)

# the end of a group, while some client is in BCAST mode: the keys
# changed under each prefix to the clients that listen (Tracking in the
# actor)
def grp.pushed(p: Ps & List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, srv: S.Srv, ds: R.Ds, ws: Waits, up: List<&2, Up>, tx: Tx) -> Grp:
  (pb, outs) = p
  Grp{outs, es, srv, ds, ws, up, tx, pb}

def grp.bcast.if(on: Bool, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, srv: S.Srv, ds: R.Ds, ws: Waits, up: List<&2, Up>, tx: Tx, pb: Ps) -> Grp:
  match on:
    case True{}:
      grp.pushed(ps.flush(ps.trk.bcast(pb), outs), es, srv, ds, ws, up, tx)
    case False{}:
      Grp{outs, es, srv, ds, ws, up, tx, pb}

def grp.bcast(g: Grp) -> Grp:
  match g:
    case Grp{outs, es, srv, ds, ws, up, tx, +pb}:
      grp.bcast.if(ps.trk.bcasts(pb), outs, es, srv, ds, ws, up, tx, pb)

def grp.end.if(stop: Bool, g: Grp) -> Grp:
  match stop:
    case True{}:
      g
    case False{}:
      grp.bcast(grp.end.go(g))

def grp.end(g: Grp) -> Grp:
  +x = g
  grp.end.if(Nat.is_le(2n, grp.down(x)), x)

# a client gone (its connection closed while it waits): forgotten, its
# batch dropped, and its connection answered Bye, after any answer before
def grp.gone(+id: Nat, +back: Chan(Ans), outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, srv: S.Srv, ds: R.Ds, +ws: Waits, +up: List<&2, Up>, tx: Tx, pb: Ps) -> Grp:
  +left = waits.rest(waits.take(ws, waits.is(id, ws), id, WaitNone{}))
  Grp{(back, Bye{}) <> outs, es, waits.count(left, S.srv.gone(srv, id)), ds, left, ups.drop(up, ups.is(id, up), id), tx.drop(id, tx), ps.drop(id, pb)}

# Memory
# ------
# With maxmemory, the actor reads the heap's account (IO.heap: the bytes
# its live values hold, as Redis's zmalloc counts) before each group it
# runs, as Redis's processCommand calls performEvictions before each
# command, and evicts keys while it is past maxmemory (Eviction, below);
# past it with nothing it may evict, the group's commands that may take
# memory are refused (sh.of: ShOom), and its batches run the general way,
# a command at a time. Without maxmemory nothing is read.

# Eviction
# --------
# While the heap's live bytes, less those a rewrite's snapshot still holds
# of the keys evicted while it runs (Mm's debt), are past maxmemory, the
# actor picks a key by the policy and deletes it as the sweep of expired
# keys deletes one (a DEL in the append-only file; the WATCHes of the key
# touched; "evicted" to the keyspace's subscribers), counts it
# (evicted_keys) and reads the heap again, as Redis's performEvictions.
# LRU, LFU and volatile-ttl pick from a pool of the 16 best keys of their
# samples (maxmemory-samples keys of each database with keys, from a
# random bucket on: KV.sample), scored by the seconds since the key's last
# use (Access), 255 less its LFU counter, or how soon it expires; the pool
# lasts from one eviction to the next, a key deleted meanwhile dropped as
# it comes up (Redis's ghosts). allkeys-random and volatile-random pick a
# key at random of the next database with keys after the one they picked
# from last (next_db). The volatile policies pick among keys with a time
# alone. Every 16 keys the actor looks at the time: past the limit of
# maxmemory-eviction-tenacity (500 us at 10), it stops with keys left to
# evict (RUNNING) and goes on between groups, as Redis's evictionTimeProc;
# with no key left the policy may evict, the group runs with the commands
# that may take memory refused (FAIL). A CONFIG SET that changes
# maxmemory starts an eviction at once (Mm's kick), with Redis's warning
# when the heap is past the new value. While a rewrite of the append-only
# file runs, its snapshot holds what an eviction frees: an evicted key
# counts as freed by MEMORY USAGE's estimate (the debt, paid when the
# rewrite ends). INFO's evicted_keys and the times past maxmemory count as
# Redis's do (I.info.evicted).

# 2^47: volatile-ttl's score is it less the time a key expires at (ms)
def evict.far() -> Nat:
  Nat.mul(32768n, Nat.mul(65536n, 65536n))

# how long an eviction may run, us (evictionTimeLimitUs): 50 for each
# step of the tenacity up to 10, 15% more for each one past it, no limit
# at 100
def evict.limit.go(n: Nat, +l: Nat) -> Nat:
  match n:
    case 0n:
      l
    case 1n+m:
      evict.limit.go(m, Nat.div(Nat.mul(l, 115n), 100n))

def evict.limit(+ten: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_le(ten, 10n), Nat.mul(50n, ten), Bool.pick(Nat, Nat.is_lt(ten, 100n), evict.limit.go(Nat.sub(ten, 10n), 500n), Nat.mul(1000000n, 1000000n)))

# the us from the clock's (s, us) t0 to t: a clock set back reads as a day
# past, which ends the eviction's turn (and keeps the count within a Nat)
def evict.us(+s0: U32, +u0: U32, t: U32 & U32) -> Nat:
  (s, u) = t
  +d = U32.sub(s, s0)
  Nat.sub(Nat.add(Nat.mul(U32.to_nat(Bool.pick(U32, U32.is_lt(d, 86400), d, 86400)), 1000000n), U32.to_nat(u)), U32.to_nat(u0))

# whether a policy evicts keys with a time alone (volatile-*)
def evict.vol(+pol: Nat) -> Bool:
  Bool.or(Bool.or(Nat.is_eq(pol, 2n), Nat.is_eq(pol, 4n)), Bool.or(Nat.is_eq(pol, 6n), Nat.is_eq(pol, 7n)))

# the keys of a database the policy may evict: all, or those with a time
def evict.count(+vol: Bool, +d: R.Db) -> Nat:
  Bool.pick(Nat, vol, R.db.x(d), R.db.n(d))

def evict.time(m: Maybe<&2, KV.Item<KV.Val>>) -> Nat:
  match m:
    case Some{KV.Item{v, e}}:
      e
    case None{}:
      0n

# a key's score under policy pol, at now, the server started at start
def evict.score(+pol: Nat, +d: R.Db, +k: String, +now: Nat, +start: U32, +lfd: Nat) -> Nat:
  match pol:
    case 7n:
      Nat.sub(evict.far(), evict.time(R.db.ent(d, k)))
    case 3n:
      Nat.sub(255n, U32.to_nat(S.acc.freq(Mem.cell(KV.hash(k)), now, start, lfd)))
    case 4n:
      Nat.sub(255n, U32.to_nat(S.acc.freq(Mem.cell(KV.hash(k)), now, start, lfd)))
    case _:
      S.acc.idle(Mem.cell(KV.hash(k)), now, start)

def pe.score(+p: S.Pe) -> Nat:
  match p:
    case S.Pe{+s, db, key}:
      s

# whether the first entry of the pool scores s or more
def pool.ge(+s: Nat, +ps: List<&2, S.Pe>) -> Bool:
  match ps:
    case Nil{}:
      False{}
    case Con{+p, rest}:
      Nat.is_le(s, pe.score(p))

# the pool (best first) with e, of score s, after the entries that score
# as well or better (as Redis's evictionPoolPopulate puts a key before
# those that score as well, the worst first); ge: pool.ge of ps
def pool.ins(e: S.Pe, +s: Nat, ps: List<&2, S.Pe>, ge: Bool) -> List<&2, S.Pe>:
  match ps ge:
    case Con{p, +rest} True{}:
      p <> pool.ins(e, s, rest, pool.ge(s, rest))
    case Con{p, rest} False{}:
      e <> (p <> rest)
    case Nil{} _:
      [e]

# the pool with e, of score s: 16 entries at most, the worst dropped
def pool.add(e: S.Pe, +s: Nat, ps: List<&2, S.Pe>) -> List<&2, S.Pe>:
  +q = ps
  List.take(&2, S.Pe, pool.ins(e, s, q, pool.ge(s, q)), 16n)

# The databases are walked lent, as Ds keeps them (those before the focus,
# nearest first; the focus; those after it): a database taken out of them
# (R.ds.list, R.db.trie) would share its trie, which the delete of a key
# would then copy along the key's path.

# how many databases xs holds, lent (List.length would take them)
def dbs.len(+xs: List<&2, R.Db>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case Con{d, +rest}:
      1n+dbs.len(rest)

def dbs.count(+ds: R.Ds) -> Nat:
  match ds:
    case R.Ds{d, +pre, +post}:
      1n+Nat.add(dbs.len(pre), dbs.len(post))

# the pool with the keys ks of database i, sampled
def evict.adds(+pol: Nat, +i: Nat, +d: R.Db, +now: Nat, +start: U32, +lfd: Nat, ks: List<&2, String>, ps: List<&2, S.Pe>) -> List<&2, S.Pe>:
  match ks:
    case Nil{}:
      ps
    case Con{+k, rest}:
      +s = evict.score(pol, d, k, now, start, lfd)
      evict.adds(pol, i, d, now, start, lfd, rest, pool.add(S.Pe{s, i, k}, s, ps))

# a sample of database d: maxmemory-samples keys the policy may evict
# (mode: KV.scan.ok; 2 those with a time) from a random bucket (r) on,
# among win buckets, as Redis's dictGetSomeKeys looks at a bounded number
# of buckets and may find fewer (2^20: all of them, on until it finds
# them)
def evict.sample(+d: R.Db, +r: U32, +smp: Nat, +now: Nat, +mode: Nat, +win: Nat) -> List<&2, String>:
  match d:
    case R.Db{+t, n, x, tm, rr}:
      KV.sample(KV.Val, t, r, smp, now, mode, win)

# the buckets a sample of a database with c keys the policy may evict
# reads: as many as hold three times maxmemory-samples of them, as the
# keys spread over the buckets
def evict.win(+c: Nat, +smp: Nat) -> Nat:
  Nat.min(1048576n, Nat.max(64n, Nat.div(Nat.mul(1048576n, Nat.mul(3n, smp)), Nat.max(c, 1n))))

# the parameters of a sample: the policy, whether it evicts keys with a
# time alone (vol), whether the sample reads on until it finds its keys
# (full), maxmemory-samples, the time, the server's start, lfu-decay-time
type Smp is Data:
  Smp{pol: Nat, vol: Bool, full: Bool, smp: Nat, now: Nat, start: U32, lfd: Nat}

# a database's sample put in the pool, when it holds keys the policy may
# evict (c of them)
def evict.db(+sp: Smp, +i: Nat, +d: R.Db, +c: Nat, +r: U32, ps: List<&2, S.Pe>) -> List<&2, S.Pe>:
  match sp c:
    case _ 0n:
      ps
    case Smp{+pol, +vol, +full, +smp, +now, +start, +lfd} _:
      evict.adds(pol, i, d, now, start, lfd, List.take(&2, String, evict.sample(d, r, smp, now, Bool.pick(Nat, vol, 2n, 0n), Bool.pick(Nat, full, 1048576n, evict.win(c, smp))), smp), ps)

# the pool after a sample of each database, and whether any held a key
# the policy may evict
type Fill is Data:
  Fill{ps: List<&2, S.Pe>, any: Bool}

def smp.vol(+sp: Smp) -> Bool:
  match sp:
    case Smp{pol, +vol, full, smp, now, start, lfd}:
      vol

def evict.fill1(+sp: Smp, +i: Nat, +d: R.Db, +r: U32, f: Fill) -> Fill:
  match f:
    case Fill{ps, +any}:
      +c = evict.count(smp.vol(sp), d)
      Fill{evict.db(sp, i, d, c, KV.mix(r), ps), Bool.or(any, Nat.is_lt(0n, c))}

# a sample of each of the databases xs, the first numbered i, the next
# ones numbered up (up) or down
def evict.fill(+sp: Smp, +xs: List<&2, R.Db>, +i: Nat, +up: Bool, +r: U32, f: Fill) -> Fill:
  match xs:
    case Nil{}:
      f
    case Con{+d, +rest}:
      evict.fill(sp, rest, Bool.pick(Nat, up, 1n+i, Nat.sub(i, 1n)), up, U32.add(r, 2654435769), evict.fill1(sp, i, d, r, f))

def evict.fill.ds(+sp: Smp, +ds: R.Ds, +r: U32, f: Fill) -> Fill:
  match ds:
    case R.Ds{+d, +pre, +post}:
      +i = dbs.len(pre)
      evict.fill(sp, post, 1n+i, True{}, U32.add(r, 2654435761), evict.fill1(sp, i, d, r, evict.fill(sp, pre, Nat.sub(i, 1n), False{}, U32.add(r, 2246822519), f)))

def evict.has.ent(+vol: Bool, m: Maybe<&2, KV.Item<KV.Val>>) -> Bool:
  match m:
    case Some{KV.Item{v, +e}}:
      Bool.or(Bool.not(vol), Nat.is_lt(0n, e))
    case None{}:
      False{}

# a random policy's key of database d, which holds c keys it may evict:
# one at random of 16 from a random bucket on, as RANDOMKEY picks one, or
# the first with a time from a random bucket on (r); none when it holds
# none
def evict.rand.key(+vol: Bool, +d: R.Db, +c: Nat, +r: U32, +now: Nat) -> Maybe<&2, String>:
  match vol d c:
    case _ _ 0n:
      None{}
    case False{} R.Db{+t, n, x, tm, rr} _:
      KV.pick.of(KV.sample(KV.Val, t, r, 16n, now, 0n, 1048576n), KV.mix(r))
    case True{} R.Db{+t, n, x, tm, rr} _:
      List.head(&2, String, KV.sample(KV.Val, t, r, 1n, now, 2n, 1048576n))

# what is asked of a database: whether it holds key k as the policy takes
# keys (with a time, when vol); MEMORY USAGE's estimate of key k; a random
# policy's key of it, by r
type Ask is Data:
  AskHas{vol: Bool, k: String}
  AskEst{k: String}
  AskKey{vol: Bool, r: U32, now: Nat}

# its answer: a truth, a number or a key
type Ans1 is Data:
  A1{b: Bool, n: Nat, k: Maybe<&2, String>}

def a1.b(a: Ans1) -> Bool:
  match a:
    case A1{b, n, k}:
      b

def a1.n(a: Ans1) -> Nat:
  match a:
    case A1{b, n, k}:
      n

def a1.k(a: Ans1) -> Maybe<&2, String>:
  match a:
    case A1{b, n, k}:
      k

def evict.ask(+a: Ask, +d: R.Db) -> Ans1:
  match a:
    case AskHas{+vol, +k}:
      A1{evict.has.ent(vol, R.db.ent(d, k)), 0n, None{}}
    case AskEst{+k}:
      A1{False{}, S.mem.est(k, R.db.ent(d, k)), None{}}
    case AskKey{+vol, +r, +now}:
      A1{False{}, 0n, evict.rand.key(vol, d, evict.count(vol, d), r, now)}

# what the n-th of xs answers (none past the last)
def evict.ask.nth(+a: Ask, +n: Nat, +xs: List<&2, R.Db>) -> Ans1:
  match n xs:
    case 0n Con{+d, rest}:
      evict.ask(a, d)
    case 1n+m Con{d, +rest}:
      evict.ask.nth(a, m, rest)
    case _ Nil{}:
      A1{False{}, 0n, None{}}

# where database j is to the focus, the i-th: 0 before it, 1 it, 2 after
def evict.where(+j: Nat, +i: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_lt(j, i), 0n, Bool.pick(Nat, Nat.is_eq(j, i), 1n, 2n))

def evict.ask.at(w: Nat, +a: Ask, +j: Nat, +i: Nat, +d: R.Db, +pre: List<&2, R.Db>, +post: List<&2, R.Db>) -> Ans1:
  match w:
    case 0n:
      evict.ask.nth(a, Nat.sub(Nat.sub(i, j), 1n), pre)
    case 1n:
      evict.ask(a, d)
    case _:
      evict.ask.nth(a, Nat.sub(Nat.sub(j, i), 1n), post)

# what database j answers to a
def evict.ask.ds(+a: Ask, +j: Nat, +ds: R.Ds) -> Ans1:
  match ds:
    case R.Ds{+d, +pre, +post}:
      +i = dbs.len(pre)
      evict.ask.at(evict.where(j, i), a, j, i, d, pre, post)

# whether the first key of the pool is still there, as the policy takes
# keys
def evict.there(+vol: Bool, +ds: R.Ds, +ps: List<&2, S.Pe>) -> Bool:
  match ps:
    case Nil{}:
      False{}
    case Con{S.Pe{s, +j, +k}, rest}:
      a1.b(evict.ask.ds(AskHas{vol, k}, j, ds))

# the key picked: none, or key k of database j
type Vic is Data:
  VicNone{}
  Vic{db: Nat, key: String}

# the best key of the pool still there (there: evict.there of ps), the
# pool after it, without the keys before it (Redis's ghosts), and whether
# any database held a key the policy may evict
type Pk is Data:
  Pk{g: Vic, ps: List<&2, S.Pe>, any: Bool}

def pool.pick(+vol: Bool, +ds: R.Ds, ps: List<&2, S.Pe>, there: Bool, +any: Bool) -> Pk:
  match ps there:
    case Con{S.Pe{s, j, k}, rest} True{}:
      Pk{Vic{j, k}, rest, any}
    case Con{p, +rest} False{}:
      pool.pick(vol, ds, rest, evict.there(vol, ds, rest), any)
    case Nil{} _:
      Pk{VicNone{}, Nil{}, any}

def evict.pool.of(+vol: Bool, +ds: R.Ds, f: Fill) -> Pk:
  match f:
    case Fill{+ps, True{}}:
      pool.pick(vol, ds, ps, evict.there(vol, ds, ps), True{})
    case Fill{ps, False{}}:
      Pk{VicNone{}, ps, False{}}

# a pick that found no key though some database held one the policy may
# evict (its samples found none): a full sample of each, then the pick
def evict.retry(p: Pk, +sp: Smp, +vol: Bool, +ds: R.Ds, +r: U32) -> Pk:
  match p:
    case Pk{Vic{j, k}, ps, any}:
      Pk{Vic{j, k}, ps, any}
    case Pk{VicNone{}, ps, True{}}:
      evict.pool.of(vol, ds, evict.fill.ds(sp, ds, r, Fill{ps, False{}}))
    case Pk{VicNone{}, ps, False{}}:
      Pk{VicNone{}, ps, False{}}

# a random policy's pick: the databases from the one after the last it
# picked from (Redis's static next_db goes up by one for each database
# it looks at), n of them, j the one looked at, m its key; the key, and
# the database it is of (next, for the next pick)
type Rk is Data:
  Rk{g: Vic, next: Nat}

def evict.rand(+vol: Bool, +ds: R.Ds, +n: Nat, left: Nat, +j: Nat, m: Maybe<&2, String>, +r: U32, +now: Nat) -> Rk:
  match left m:
    case 1n+l Some{k}:
      Rk{Vic{j, k}, j}
    case 1n+l None{}:
      +j2 = Nat.mod(1n+j, n)
      evict.rand(vol, ds, n, l, j2, a1.k(evict.ask.ds(AskKey{vol, r, now}, j2, ds)), r, now)
    case 0n _:
      Rk{VicNone{}, j}

# a pick: the eviction's state after it (its pool and random numbers, or
# the database the next random pick starts after) and the key
type Ep is Data:
  Ep{mm: S.Mm, g: Vic}

def evict.random.of(k: Rk, +n: Nat, mm: S.Mm) -> Ep:
  match k:
    case Rk{g, +next}:
      Ep{S.mm.next.set(mm, next, n), g}

# allkeys-random's or volatile-random's pick, of the n databases
def evict.random(+vol: Bool, mm: S.Mm, +ds: R.Ds, +n: Nat, +now: Nat) -> Ep:
  +m = mm
  +j = Nat.mod(1n+S.mm.next(m), Nat.max(n, 1n))
  +r = KV.mix(S.mm.rng(m))
  evict.random.of(evict.rand(vol, ds, n, n, j, a1.k(evict.ask.ds(AskKey{vol, r, now}, j, ds)), r, now), n, m)

def evict.pooled.of(p: Pk, +n: Nat, mm: S.Mm) -> Ep:
  match p:
    case Pk{g, ps, any}:
      Ep{S.mm.pool.set(mm, ps, n), g}

# a pool policy's pick (LRU, LFU, volatile-ttl), of the n databases:
# samples within windows, and full ones when those found no key
def evict.pooled.mp(+pol: Nat, p: S.Mp, +ds: R.Ds, +n: Nat, +now: Nat, +start: U32) -> Ep:
  match p:
    case S.Mp{ps, mm}:
      +m = mm
      +vol = evict.vol(pol)
      +smp = S.mm.smp(m)
      +lfd = S.mm.lfd(m)
      +r = S.mm.rng(m)
      evict.pooled.of(evict.retry(evict.pool.of(vol, ds, evict.fill.ds(Smp{pol, vol, False{}, smp, now, start, lfd}, ds, r, Fill{ps, False{}})), Smp{pol, vol, True{}, smp, now, start, lfd}, vol, ds, KV.mix(r)), n, m)

def evict.pooled(+pol: Nat, mm: S.Mm, +ds: R.Ds, +n: Nat, +now: Nat, +start: U32) -> Ep:
  evict.pooled.mp(pol, S.mm.pool.take(mm), ds, n, now, start)

# the pick of the policy pol (Memory: mm.pol.of), of the n databases, at
# now, the server started at start
def evict.pick(+pol: Nat, mm: S.Mm, +ds: R.Ds, +n: Nat, +now: Nat, +start: U32) -> Ep:
  match pol:
    case 0n:
      Ep{mm, VicNone{}}
    case 5n:
      evict.random(False{}, mm, ds, n, now)
    case 6n:
      evict.random(True{}, mm, ds, n, now)
    case _:
      evict.pooled(pol, mm, ds, n, now, start)

# eviction's state as it goes: the server, the databases, the DELs of the
# keys it evicted (newest first), how many, and the heap's used bytes at
# its last reading
type Evs is Data:
  Evs{srv: S.Srv, ds: R.Ds, es: List<&2, A.Ent>, n: Nat, last: Nat}

def evs.n(+x: Evs) -> Nat:
  match x:
    case Evs{srv, ds, es, +n, last}:
      n

# a key evicted, or none the policy may evict
type Ev1 is Data:
  EvOne{x: Evs}
  EvNone{x: Evs}

# the databases with key k of the j-th deleted, the focus where it was
def evict.del.focused(+k: String, ds: R.Ds) -> R.Ds:
  match ds:
    case R.Ds{d, pre, post}:
      R.Ds{R.db_of(R.exec(R.Del{[k]}, d)), pre, post}

def evict.del(+j: Nat, +k: String, ds: R.Ds) -> R.Ds:
  +x = ds
  +i = R.ds.index(x)
  R.ds.focus(i, evict.del.focused(k, R.ds.focus(j, x)))

# a pick and the debt of its key: MEMORY USAGE's estimate of it, while a
# rewrite runs (rws)
type Ed is Data:
  Ed{mm: S.Mm, g: Vic, debt: Nat}

# (a match, not Bool.pick, so that no estimate is made without a rewrite)
def evict.est(rws: Bool, +j: Nat, +k: String, +ds: R.Ds) -> Nat:
  match rws:
    case True{}:
      a1.n(evict.ask.ds(AskEst{k}, j, ds))
    case False{}:
      0n

def evict.debt(p: Ep, +rws: Bool, +ds: R.Ds) -> Ed:
  match p:
    case Ep{mm, Vic{+j, +k}}:
      Ed{mm, Vic{j, k}, evict.est(rws, j, k, ds)}
    case Ep{mm, VicNone{}}:
      Ed{mm, VicNone{}, 0n}

def evict.pick.of(+rws: Bool, mm: S.Mm, +ds: R.Ds, +start: U32) -> Ed:
  +m = mm
  evict.debt(evict.pick(S.mm.pol(m), m, ds, dbs.count(ds), R.ds.now(ds), start), rws, ds)

# the key picked deleted: its DEL with the others, the server's debt up
def evict.done(p: Ed, pass: String, cfg: List<&2, C.CItem>, info: I.Info, ds: R.Ds, es: List<&2, A.Ent>, +n: Nat, +last: Nat) -> Ev1:
  match p:
    case Ed{mm, Vic{+j, +k}, +debt}:
      EvOne{Evs{S.Srv{pass, cfg, info, S.mm.owe(mm, debt)}, evict.del(j, k, ds), A.EOne{A.EDb{j, R.Del{[k]}}} <> es, 1n+n, last}}
    case Ed{mm, VicNone{}, debt}:
      EvNone{Evs{S.Srv{pass, cfg, info, mm}, ds, es, n, last}}

# one key evicted (rws: while a rewrite runs)
def evict.one(x: Evs, +rws: Bool) -> Ev1:
  match x:
    case Evs{S.Srv{pass, cfg, +info, mm}, +ds, es, +n, +last}:
      evict.done(evict.pick.of(rws, mm, ds, I.info.start(info)), pass, cfg, info, ds, es, n, last)

# whether the heap's used bytes, less the debt, are past maxmemory (none
# with maxmemory 0)
def evict.over(+used: Nat, +srv: S.Srv) -> Bool:
  +max = S.srv.max(srv)
  Bool.and(Nat.is_lt(0n, max), Nat.is_lt(max, Nat.sub(used, S.srv.debt(srv))))

def evs.over(+used: Nat, +x: Evs) -> Bool:
  match x:
    case Evs{+srv, ds, es, n, last}:
      evict.over(used, srv)

# the debt up by b: what the snapshot of a rewrite that runs holds of
# what the eviction let go (S.mm.owe)
def evs.owe(srv: S.Srv, +b: Nat) -> S.Srv:
  match srv:
    case S.Srv{pass, cfg, info, mm}:
      S.Srv{pass, cfg, info, S.mm.owe(mm, b)}

# while a rewrite runs, what the heap grew by since the eviction's last
# reading: no client's command runs inside the eviction, so this is the
# nodes its DELs copied on the way to their keys, whose old ones the
# snapshot still holds, as it holds the keys (evict.est); counted as debt,
# or the eviction, its own copies growing the heap as fast as its debt,
# would go on until the rewrite ends (issue #100). Without a rewrite the
# old nodes are let go, and nothing is owed (a match, not Bool.pick).
def evs.grown(rws: Bool, +used: Nat, +last: Nat) -> Nat:
  match rws:
    case True{}:
      Nat.sub(used, last)
    case False{}:
      0n

# the heap's reading kept in the server's state, for INFO (S.srv.heap),
# and as the eviction's last; its growth while a rewrite runs owed
def evs.heap(+used: Nat, +act: Nat, rws: Bool, x: Evs) -> Evs:
  match x:
    case Evs{srv, ds, es, n, +last}:
      Evs{evs.owe(S.srv.heap(srv, used, act), evs.grown(rws, used, last)), ds, es, n, used}

# an eviction's outcome: 0 the heap within maxmemory (EVICT_OK), 1 keys
# left to evict when its time ran out (EVICT_RUNNING), 2 none left that
# the policy may evict (EVICT_FAIL); and its state
type Evd is Data:
  Evd{res: Nat, x: Evs}

# evicting while the heap is past maxmemory (over), a key at a time, the
# heap read after each; each 16 keys the time since the start (s0, u0)
# looked at, against lim (us)
@unsafe
def evict.loop(over: Bool, x: Evs, +rws: Bool, +s0: U32, +u0: U32, +lim: Nat) -> IO(Evd):
  match over:
    case False{}:
      IO.pure(Evd, Evd{0n, x})
    case True{}:
      evict.next(evict.one(x, rws), rws, s0, u0, lim)

@unsafe
def evict.next(r: Ev1, +rws: Bool, +s0: U32, +u0: U32, +lim: Nat) -> IO(Evd):
  match r:
    case EvNone{x}:
      IO.pure(Evd, Evd{2n, x})
    case EvOne{x}:
      +y = x
      evict.look(Nat.is_eq(Nat.mod(evs.n(y), 16n), 0n), y, rws, s0, u0, lim)

@unsafe
def evict.look(look: Bool, x: Evs, +rws: Bool, +s0: U32, +u0: U32, +lim: Nat) -> IO(Evd):
  match look:
    case False{}:
      evict.heap(x, rws, s0, u0, lim)
    case True{}:
      do IO<Evd>:
        t : U32 & U32 <- IO.clock()
        evict.timed(Nat.is_lt(lim, evict.us(s0, u0, t)), x, rws, s0, u0, lim)

@unsafe
def evict.timed(up: Bool, x: Evs, +rws: Bool, +s0: U32, +u0: U32, +lim: Nat) -> IO(Evd):
  match up:
    case True{}:
      IO.pure(Evd, Evd{1n, x})
    case False{}:
      evict.heap(x, rws, s0, u0, lim)

@unsafe
def evict.heap(x: Evs, +rws: Bool, +s0: U32, +u0: U32, +lim: Nat) -> IO(Evd):
  do IO<Evd>:
    h : Nat & Nat <- IO.heap()
    evict.heap.of(h, x, rws, s0, u0, lim)

@unsafe
def evict.heap.at(+used: Nat, +act: Nat, x: Evs, +rws: Bool, +s0: U32, +u0: U32, +lim: Nat) -> IO(Evd):
  +y = evs.heap(used, act, rws, x)
  evict.loop(evs.over(used, y), y, rws, s0, u0, lim)

# the heap's reading taken apart, for evict.heap.at
@unsafe
def evict.heap.of(h: Nat & Nat, x: Evs, +rws: Bool, +s0: U32, +u0: U32, +lim: Nat) -> IO(Evd):
  (u, a) = h
  evict.heap.at(u, a, x, rws, s0, u0, lim)

# the evicted keys' events (expired's: ps.swept)
def ev.e() -> U32:
  512

def ev.evicted.ks(+i: Nat, ks: List<&2, String>) -> List<&2, Ev>:
  match ks:
    case Nil{}:
      Nil{}
    case Con{k, rest}:
      Ev{ev.e(), "evicted", k, i} <> ev.evicted.ks(i, rest)

def ev.evicted(es: List<&2, A.Ent>, acc: List<&2, Ev>) -> List<&2, Ev>:
  match es:
    case Nil{}:
      acc
    case Con{A.EOne{A.EDb{+i, R.Del{ks}}}, rest}:
      ev.evicted(rest, List.append(&2, Ev, ev.evicted.ks(i, ks), acc))
    case Con{x, rest}:
      ev.evicted(rest, acc)

def ps.evicted.if(on: Bool, +es: List<&2, A.Ent>, pb: Ps) -> Ps:
  match on:
    case True{}:
      ps.evs(ev.evicted(es, Nil{}), 0n, pb)
    case False{}:
      pb

def ps.evicted(+es: List<&2, A.Ent>, pb: Ps) -> Ps:
  +p = pb
  ps.evicted.if(ps.loud(p), es, p)

# the group after an eviction of the keys es: their WATCHes touched,
# their readers told (Tracking: as no client's change, before their
# events, as Redis's performEvictions signals each key before its event)
# and their events pushed (before the group's answers), their DELs the
# group's first effects; Ps with the outcome (ps.mem), the server with
# its counts (I.info.evicted)
def mem.grp(p: Ps & List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, srv: S.Srv, ds: R.Ds, ws: Waits, tx: Tx) -> Grp:
  (pb, outs) = p
  Grp{outs, es, srv, ds, ws, Nil{}, tx, pb}

def mem.done(d: Evd, ws: Waits, tx: Tx, pb: Ps) -> Grp:
  match d:
    case Evd{+res, Evs{srv, +ds, +es, +n, last}}:
      mem.grp(ps.flush(ps.evicted(es, ps.trk.gone(es, ds, ps.mem(pb, res))), Nil{}), es, S.srv.evicted(srv, n, Nat.is_lt(0n, res), R.ds.now(ds)), ds, ws, touch.ents(tx, es, None{}, ds))

# Redis's warning for a CONFIG SET that set maxmemory below the memory in
# use (updateMaxmemory)
@unsafe
def mem.warn.if(past: Bool, +srv: S.Srv, +used: Nat, +pid: U32) -> IO(Unit):
  match past:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      log(log.up(log.of(S.srv.cfg(srv), pid)), 3, "WARNING: the new maxmemory value set via CONFIG SET (" ++ Nat.show(S.srv.max(srv)) ++ ") is smaller than the current memory usage (" ++ Nat.show(used) ++ "). This will result in key eviction and/or the inability to accept new write commands depending on the maxmemory-policy.")

# the group as it starts when the heap is within maxmemory: as it is,
# unless the last eviction left it past (Ps's bits 29 and 26: was), whose
# outcome is cleared and whose time past maxmemory ends
def mem.ok(was: Bool, srv: S.Srv, ds: R.Ds, ws: Waits, tx: Tx, pb: Ps) -> Grp:
  match was:
    case False{}:
      Grp{Nil{}, Nil{}, srv, ds, ws, Nil{}, tx, pb}
    case True{}:
      mem.done(Evd{0n, Evs{srv, ds, Nil{}, 0n, 0n}}, ws, tx, pb)

def ps.mem.was(+pb: Ps) -> Bool:
  match pb:
    case Ps{reg, +ev, px, cs, own}:
      U32.is_ne(U32.and(ev, 603979776), 0)
    case PsOf{+p}:
      ps.mem.was(p)

# the memory seen to before a group (w: S.srv.mem.what of the heap's
# used bytes, read at the clock's s0, u0): nothing within maxmemory; a
# CONFIG SET's change of maxmemory first (its warning, Mm's kick cleared);
# the eviction (rws: whether a rewrite runs; pid, the server's, for the
# log); the group's state after it
@unsafe
def mem.run.w(w: Nat, +used: Nat, +s0: U32, +u0: U32, srv: S.Srv, ds: R.Ds, ws: Waits, tx: Tx, pb: Ps, +rws: Bool, +pid: U32) -> IO(Grp):
  match w:
    case 0n:
      +p = pb
      IO.pure(Grp, mem.ok(ps.mem.was(p), srv, ds, ws, tx, p))
    case 1n:
      +sv = srv
      do IO<Grp>:
        Unit <- mem.warn.if(evict.over(used, sv), sv, Nat.sub(used, S.srv.debt(sv)), pid)
        mem.run.k(used, s0, u0, S.srv.kicked(sv), ds, ws, tx, pb, rws, pid)
    case _:
      +sv = srv
      evict.go(S.srv.pol(sv), Evs{sv, ds, Nil{}, 0n, used}, ws, tx, pb, rws, s0, u0, evict.limit(S.srv.ten(sv)))

@unsafe
def mem.run.k(+used: Nat, +s0: U32, +u0: U32, srv: S.Srv, ds: R.Ds, ws: Waits, tx: Tx, pb: Ps, +rws: Bool, +pid: U32) -> IO(Grp):
  +sv = srv
  mem.run.w(S.srv.mem.what(sv, used), used, s0, u0, sv, ds, ws, tx, pb, rws, pid)

# the eviction under policy pol: none under noeviction (EVICT_FAIL)
@unsafe
def evict.go(+pol: Nat, x: Evs, ws: Waits, tx: Tx, pb: Ps, +rws: Bool, +s0: U32, +u0: U32, +lim: Nat) -> IO(Grp):
  match pol:
    case 0n:
      IO.pure(Grp, mem.done(Evd{2n, x}, ws, tx, pb))
    case _:
      do IO<Grp>:
        d : Evd <- evict.loop(True{}, x, rws, s0, u0, lim)
        IO.pure(Grp, mem.done(d, ws, tx, pb))

@unsafe
def mem.run(h: Nat & Nat, +s0: U32, +u0: U32, srv: S.Srv, ds: R.Ds, ws: Waits, tx: Tx, pb: Ps, +rws: Bool, +pid: U32) -> IO(Grp):
  (u, a) = h
  +used = u
  +act = a
  mem.run.k(used, s0, u0, S.srv.heap(srv, used, act), ds, ws, tx, pb, rws, pid)

# a group of requests taken at t, its memory seen to (w: mem.need): with
# maxmemory, the heap read and the eviction (mem.run); without it, the
# outcome of an eviction before it cleared (ps.mem)
@unsafe
def db_mem(+w: Nat, qs: List<&1, Req>, t: U32 & U32, srv: S.Srv, ds: R.Ds, ws: Waits, tx: Tx, pb: Ps, rw: Rw, +reqs: Chan(Req)) -> IO(Unit):
  match w:
    case 0n:
      (a, b) = t
      +s0 = a
      +u0 = b
      db_group(group_at(False{}, qs, s0, u0, Grp{Nil{}, Nil{}, srv, R.ds.at(clock.ms.of(s0, u0), ds), ws, Nil{}, tx, pb}), rw, reqs)
    case 1n:
      (a, b) = t
      +s0 = a
      +u0 = b
      db_group(group_at(False{}, qs, s0, u0, Grp{Nil{}, Nil{}, srv, R.ds.at(clock.ms.of(s0, u0), ds), ws, Nil{}, tx, ps.mem(pb, 0n)}), rw, reqs)
    case _:
      (a, b) = t
      +s0 = a
      +u0 = b
      +w2 = rw
      +k = U32.sub(Clock.us(u0), u0)
      do IO<Unit>:
        h : Nat & Nat <- IO.heap()
        g : Grp <- mem.run(h, s0, u0, srv, R.ds.at(clock.ms.of(s0, u0), ds), ws, tx, pb, rw.runs(w2), rw.pid(w2))
        db_group(group_from(False{}, qs, g, s0, k), w2, reqs)

# The database actor
# ------------------

# The actor takes a request, and with it those that came meanwhile
# (Chan.drain, up to group_max): it runs their batches one after another,
# in the order they came, and answers them all at once (Chan.send_all).
# While no client waits, a batch of database commands only, from a client
# that may run them, runs the fast way (S.run.plain, as S.run runs it; or
# S.run_log.plain with the append-only file); any other a command at a
# time (bg.go, Statistics), as every batch does while a client waits.
# Each batch runs on its connection's database (the focus moves to it),
# and adds its calls, errors and bytes to the server's counts for INFO,
# the shell's facts go in the server's state, a tick takes a sample of
# the rates, and at the group's end the clients that wait are seen to
# (Blocked clients).
def group_max() -> U32:
  255

# a batch's error replies, counted (most batches have none)
def errs.put(xs: List<&2, R.Erred>, srv: S.Srv) -> S.Srv:
  match xs:
    case Nil{}:
      srv
    case _:
      S.srv.errs(srv, xs)

# a batch run the fast way: its calls counted, and its replies looked at
# for errors only where a call may have one (R.Tally), as they are, before
# they are encoded (each call has one reply, in order; the errors of a
# batch of one code all have its code, R.errs.one); with the append-only
# file, its effects put before the group's. Not in the encoded bytes: a
# '-' also begins a line of a reply that is no error (a bulk "-5", a
# negative score), and an answer of many chunks is read from its start
# for each index of a line.
def run_put(outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, back: Chan(Ans), t: R.Tally, +inb: Nat, d: S.Fin, up: List<&2, Up>, pb: Ps) -> Grp:
  match t d:
    case R.Tally{+calls, False{}, +run, runs} S.Fin{rs, cn, srv, ds}:
      +a = ans_of(rs, cn)
      +outb = ans.len(a)
      Grp{(back, a) <> outs, es, S.srv.ran(srv, calls, run, runs, inb, outb), ds, WaitNone{}, up, TxNone{}, pb}
    case R.Tally{+calls, True{}, +run, Nil{}} S.Fin{+rs, cn, srv, ds}:
      +xs = R.errs.one(rs, R.run.code(run), Nil{})
      +a = ans_of(rs, cn)
      +outb = ans.len(a)
      Grp{(back, a) <> outs, es, errs.put(xs, S.srv.ran(srv, calls, run, Nil{}, inb, outb)), ds, WaitNone{}, up, TxNone{}, pb}
    case R.Tally{+calls, True{}, +run, +runs} S.Fin{+rs, cn, srv, ds}:
      +xs = R.errs.zip(rs, R.codes.runs(runs, Nil{}), Nil{})
      +a = ans_of(rs, cn)
      +outb = ans.len(a)
      Grp{(back, a) <> outs, es, errs.put(xs, S.srv.ran(srv, calls, run, runs, inb, outb)), ds, WaitNone{}, up, TxNone{}, pb}

def group_put(outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, back: Chan(Ans), t: R.Tally, +inb: Nat, d: S.Logged, up: List<&2, Up>, pb: Ps) -> Grp:
  match t d:
    case R.Tally{+calls, False{}, +run, runs} S.Logged{rs, e, cn, srv, ds}:
      +a = ans_of(rs, cn)
      +outb = ans.len(a)
      Grp{(back, a) <> outs, A.ents.onto(e, es), S.srv.ran(srv, calls, run, runs, inb, outb), ds, WaitNone{}, up, TxNone{}, pb}
    case R.Tally{+calls, True{}, +run, Nil{}} S.Logged{+rs, e, cn, srv, ds}:
      +xs = R.errs.one(rs, R.run.code(run), Nil{})
      +a = ans_of(rs, cn)
      +outb = ans.len(a)
      Grp{(back, a) <> outs, A.ents.onto(e, es), errs.put(xs, S.srv.ran(srv, calls, run, Nil{}, inb, outb)), ds, WaitNone{}, up, TxNone{}, pb}
    case R.Tally{+calls, True{}, +run, +runs} S.Logged{+rs, e, cn, srv, ds}:
      +xs = R.errs.zip(rs, R.codes.runs(runs, Nil{}), Nil{})
      +a = ans_of(rs, cn)
      +outb = ans.len(a)
      Grp{(back, a) <> outs, A.ents.onto(e, es), errs.put(xs, S.srv.ran(srv, calls, run, runs, inb, outb)), ds, WaitNone{}, up, TxNone{}, pb}

# A batch's client's channel is marked with the code of its last command
# and the group's time (Clients: CLIENT LIST's cmd and idle): the fast way
# takes the code from the batch's tally (its one run's, else its newest
# run's), the general way from the batch's last hash.
def mark(+back: Chan(Ans), +k: Nat, +now: Nat) -> Chan(Ans):
  Chan.mark(Ans, back, U32.from_nat(k), now)

def tally.last.of(+run: Nat, +runs: List<&2, Nat>) -> Nat:
  match runs:
    case Con{+r, rest}:
      R.run.code(r)
    case Nil{}:
      R.run.code(run)

def tally.last(+t: R.Tally) -> Nat:
  match t:
    case R.Tally{calls, risky, +run, +runs}:
      tally.last.of(run, runs)

def hs.last(+hs: List<&2, U32>, +w: U32) -> U32:
  match hs:
    case Nil{}:
      w
    case Con{+h, rest}:
      hs.last(rest, U32.shrn(h, 20n))

# (k: 0, after the marks of the batch's keys: Access)
def mark.hs(+back: Chan(Ans), +hs: List<&2, U32>, +now: Nat, k: U32) -> Chan(Ans):
  mark(back, R.stat.code.cw(U32.to_nat(hs.last(hs, k))), now)

# Access
# ------
# Before a batch runs, the keys its requests name are marked used
# (session.bend, Access), by their hints' hashes, at the group's time: by
# the second, or under an LFU policy (ps.lfu) by their counters, with the
# server's lfu-log-factor and lfu-decay-time, as Redis marks a value as a
# command looks it up. A request whose command touches no key has no hash
# (0: resp.bend, req.hash) and marks word 0 alone. Redis marks a key as a
# command finds it; BendKV marks the first key of each request in a batch
# before the batch runs, there or not (MGET's other keys, for one, stay
# as they were, and a command queued in a transaction marks its key as
# it is queued). The random number of an LFU counter's step scrambles the
# key's hash and word with the time and the request's place in the batch.
# A RESTORE makes its key anew, as Redis makes a new value: under an LFU
# policy its mark gives the key's word a counter of 5 at the minute
# (use.lfu.word), whatever word another key that shares it left, where
# any other request steps the word as a use (S.lfu.use); RESTORE's FREQ
# then sets it once the key is restored (bg.restored).

def use.lru(+hs: List<&2, U32>, +w: U32, k: U32) -> U32:
  match hs:
    case Nil{}:
      k
    case Con{+h, +rest}:
      use.lru(rest, w, Mem.touch(k, h, w))

# the word a request of hash h leaves in its key's word w under an LFU
# policy, at the minute min, r its random number
def use.lfu.word(+h: U32, +w: U32, +min: U32, +r: U32, +lf: Nat, +dt: Nat) -> U32:
  Bool.pick(U32, U32.is_eq(U32.and(h, 4293918720), R.stat.mark.restore()), S.lfu.word(min, 5), S.lfu.use(w, min, r, lf, dt))

def use.lfu(+hs: List<&2, U32>, +now: Nat, +min: U32, +lf: Nat, +dt: Nat, +i: U32, k: U32) -> U32:
  match hs:
    case Nil{}:
      k
    case Con{+h, +rest}:
      +w = Mem.cell(h)
      use.lfu(rest, now, min, lf, dt, U32.add(i, 2654435769), Mem.touch(k, h, use.lfu.word(h, w, min, KV.mix(U32.xor(U32.xor(h, w), U32.xor(U32.from_nat(now), i))), lf, dt)))

# a batch the general way, its keys marked used first (lfu: under an LFU
# policy) and its client's channel marked with its last command (mark.hs)
def bg.used(lfu: Bool, +cn: S.Conn, +back: Chan(Ans), +inb: Nat, raw: String, cmds: List<&2, R.Cmd>, +hs: List<&2, U32>, g: Grp) -> Grp:
  match lfu g:
    case False{} Grp{outs, es, srv, +ds, ws, up, tx, pb}:
      +now = R.ds.now(ds)
      bg.batch(cn, mark.hs(back, hs, now, use.lru(hs, S.acc.lru(now), 0)), inb, raw, cmds, R.codes.of(hs), Grp{outs, es, srv, ds, ws, up, tx, pb})
    case True{} Grp{outs, es, S.Srv{pass, cfg, info, +mm}, +ds, ws, up, tx, pb}:
      +now = R.ds.now(ds)
      bg.batch(cn, mark.hs(back, hs, now, use.lfu(hs, now, S.acc.min(now), S.mm.lfl(mm), S.mm.lfd(mm), 0, 0)), inb, raw, cmds, R.codes.of(hs), Grp{outs, es, S.Srv{pass, cfg, info, mm}, ds, ws, up, tx, pb})

# (after a SHUTDOWN that stops the server, every client's: SHUTDOWN)
def ps.killed(+id: Nat, +pb: Ps) -> Bool:
  Bool.or(Nat.is_le(2n, ps.down(pb)), cls.killed(id, ps.cls(pb)))

# a batch the general way, unless its client was killed (its connection
# answered Bye, the batch not run)
def job.slow.if(killed: Bool, lfu: Bool, +cn: S.Conn, +back: Chan(Ans), +inb: Nat, raw: String, cmds: List<&2, R.Cmd>, +hs: List<&2, U32>, g: Grp) -> Grp:
  match killed g:
    case True{} Grp{outs, es, srv, ds, ws, up, tx, pb}:
      Grp{(back, Bye{}) <> outs, es, srv, ds, ws, up, tx, pb}
    case False{} g0:
      bg.used(lfu, cn, back, inb, raw, cmds, hs, g0)

def job.slow(+cn: S.Conn, +back: Chan(Ans), +inb: Nat, raw: String, cmds: List<&2, R.Cmd>, +hs: List<&2, U32>, g: Grp) -> Grp:
  match g:
    case Grp{outs, es, srv, ds, ws, up, tx, +pb}:
      job.slow.if(ps.killed(S.conn.id(cn), pb), ps.lfu(pb), cn, back, inb, raw, cmds, hs, Grp{outs, es, srv, ds, ws, up, tx, pb})

# a batch the fast way, without the append-only file or with it (log)

def fast.run(+log: Bool, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, back: Chan(Ans), t: R.Tally, +inb: Nat, cn: S.Conn, srv: S.Srv, cmds: List<&2, R.Cmd>, hs: List<&2, U32>, ds: R.Ds, up: List<&2, Up>, pb: Ps) -> Grp:
  match log:
    case True{}:
      group_put(outs, es, back, t, inb, S.run_log.plain(True{}, cn, srv, cmds, hs, ds), up, pb)
    case False{}:
      run_put(outs, es, back, t, inb, S.run.plain(True{}, cn, srv, cmds, hs, ds), up, pb)

# a batch the fast way, its keys marked used first (Access; lfu: under an
# LFU policy)
def fast.at(lfu: Bool, +log: Bool, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, cn: S.Conn, cmds: List<&2, R.Cmd>, +hs: List<&2, U32>, back: Chan(Ans), +tl: U32, +inb: Nat, srv: S.Srv, +ds: R.Ds, up: List<&2, Up>, pb: Ps) -> Grp:
  match lfu srv:
    case False{} s:
      +now = R.ds.now(ds)
      +t = R.tally(use.lru(hs, S.acc.lru(now), tl), inb, hs)
      fast.run(log, outs, es, mark(back, tally.last(t), now), t, inb, cn, s, cmds, hs, ds, up, pb)
    case True{} S.Srv{pass, cfg, info, +mm}:
      +now = R.ds.now(ds)
      +t = R.tally(use.lfu(hs, now, S.acc.min(now), S.mm.lfl(mm), S.mm.lfd(mm), 0, tl), inb, hs)
      fast.run(log, outs, es, mark(back, tally.last(t), now), t, inb, cn, S.Srv{pass, cfg, info, mm}, cmds, hs, ds, up, pb)

def fast(+log: Bool, ready: Bool, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, cn: S.Conn, cmds: List<&2, R.Cmd>, +hs: List<&2, U32>, back: Chan(Ans), +tl: U32, +inb: Nat, raw: String, srv: S.Srv, +ds: R.Ds, up: List<&2, Up>, pb: Ps) -> Grp:
  match ready:
    case True{}:
      +p = pb
      fast.at(ps.lfu(p), log, outs, es, cn, cmds, hs, back, tl, inb, srv, ds, up, p)
    case False{}:
      +p = pb
      bg.used(ps.lfu(p), cn, back, inb, raw, cmds, hs, Grp{outs, es, srv, ds, WaitNone{}, up, TxNone{}, p})

# a batch run the fast way while some client waits or watches: the
# clients that wait and watch as they were (the fast way gives none)
def grp.keep(ws: Waits, tx: Tx, g: Grp) -> Grp:
  match g:
    case Grp{outs, es, srv, ds, w0, up, t0, pb}:
      Grp{outs, es, srv, ds, ws, up, tx, pb}

# a batch of database commands while some client waits or watches: the
# fast way when its client may run it so, is in no MULTI and writes no
# heeded key (ok: Heeded keys), else the general way
def group.heeded(ok: Bool, +log: Bool, ws: Waits, tx: Tx, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, +cn: S.Conn, cmds: List<&2, R.Cmd>, +hs: List<&2, U32>, back: Chan(Ans), +tl: U32, +inb: Nat, raw: String, +srv: S.Srv, ds: R.Ds, up: List<&2, Up>, pb: Ps) -> Grp:
  match ok:
    case True{}:
      grp.keep(ws, tx, fast(log, True{}, outs, es, cn, cmds, hs, back, tl, inb, raw, srv, ds, up, pb))
    case False{}:
      job.slow(cn, back, inb, raw, cmds, hs, Grp{outs, es, srv, ds, ws, up, tx, pb})

def group.heed(+log: Bool, ws: Waits, +tx: Tx, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, +cn: S.Conn, +cmds: List<&2, R.Cmd>, +hs: List<&2, U32>, back: Chan(Ans), +tl: U32, +inb: Nat, raw: String, +srv: S.Srv, ds: R.Ds, up: List<&2, Up>, +pb: Ps) -> Grp:
  group.heeded(heed.ok(cn, srv, tx, cmds, hs, pb), log, ws, tx, outs, es, cn, cmds, hs, back, tl, inb, raw, srv, ds, up, pb)

# a batch from a client with no subscription: the fast way while no
# keyspace event is to be sent and no client waits, has a transaction or
# watches a key (calm 0: ps.gate); while some client does, or the
# tracking has work (calm 1), the fast way for a batch of database
# commands that writes no heeded key, from a client in no MULTI
# (group.heeded)
def group_job(+log: Bool, job: B.Job, ws: Waits, tx: Tx, calm: Nat, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, +cn: S.Conn, back: Chan(Ans), +tl: U32, +inb: Nat, raw: String, +srv: S.Srv, ds: R.Ds, up: List<&2, Up>, pb: Ps) -> Grp:
  match job ws tx calm:
    case B.Plain{cmds, hs} WaitNone{} TxNone{} 0n:
      fast(log, S.ready(cn, srv), outs, es, cn, cmds, hs, back, tl, inb, raw, srv, ds, up, pb)
    case B.Plain{cmds, +hs} w t 2n:
      job.slow(cn, back, inb, raw, cmds, hs, Grp{outs, es, srv, ds, w, up, t, pb})
    case B.Plain{cmds, hs} w t c:
      group.heed(log, w, t, outs, es, cn, cmds, hs, back, tl, inb, raw, srv, ds, up, pb)
    case B.Mixed{cmds, +hs} w t c:
      job.slow(cn, back, inb, raw, cmds, hs, Grp{outs, es, srv, ds, w, up, t, pb})

# a batch from a client with a subscription, or a monitor: a command at a
# time
def sub_job(job: B.Job, +cn: S.Conn, back: Chan(Ans), +inb: Nat, raw: String, g: Grp) -> Grp:
  match job:
    case B.Plain{cmds, +hs}:
      job.slow(cn, back, inb, raw, cmds, hs, g)
    case B.Mixed{cmds, +hs}:
      job.slow(cn, back, inb, raw, cmds, hs, g)

# a sweep of expired keys: its DELs are logged as the batches' effects
# are, with the append-only file
def group.swept(outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, r: S.Srv & (List<&2, A.Ent> & R.Ds), ws: Waits, up: List<&2, Up>, tx: Tx, pb: Ps) -> Grp:
  (srv, q) = r
  (es, ds) = q
  Grp{outs, es, srv, ds, ws, up, tx, pb}

# a sweep while some client has a transaction or watches keys, keyspace
# events are to be sent, or the tracking has work (ps.looks): the keys it
# deleted are touched (each was there), expired (Keyspace notifications),
# and their readers told (Tracking)
def group.swept.out(p: Ps & List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, srv: S.Srv, ds: R.Ds, ws: Waits, up: List<&2, Up>, tx: Tx) -> Grp:
  (pb, outs) = p
  Grp{outs, es, srv, ds, ws, up, tx, pb}

def group.swept.put(outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, srv: S.Srv, +e1: List<&2, A.Ent>, +ds: R.Ds, ws: Waits, up: List<&2, Up>, tx: Tx, pb: Ps) -> Grp:
  group.swept.out(ps.flush(ps.trk.gone(e1, ds, ps.swept(e1, pb)), outs), List.append(&2, A.Ent, e1, es), srv, ds, ws, up, touch.ents(tx, e1, None{}, ds))

def group.swept.tx(outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, r: S.Srv & (List<&2, A.Ent> & R.Ds), ws: Waits, up: List<&2, Up>, tx: Tx, pb: Ps) -> Grp:
  (srv, q) = r
  (e1, ds) = q
  group.swept.put(outs, es, srv, e1, ds, ws, up, tx, pb)

def group.sweep(on: Bool, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, srv: S.Srv, ds: R.Ds, ws: Waits, up: List<&2, Up>, tx: Tx, pb: Ps) -> Grp:
  match on:
    case False{}:
      group.swept(outs, sweep(srv, es, ds), ws, up, tx, pb)
    case True{}:
      group.swept.tx(outs, es, sweep(srv, Nil{}, ds), ws, up, tx, pb)

# a tick: the sweep of expired keys, but while a pause holds (on); one
# whose end passed (over) ends, the clients it held back go on at the end
# of the group, and the sweep runs (The pause)
def group.resumed(p: Waits & List<&2, Up>, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, srv: S.Srv, ds: R.Ds, +tx: Tx, +pb: Ps) -> Grp:
  (+ws, up) = p
  group.sweep(Bool.or(tx.on(tx), ps.looks(pb)), outs, es, waits.count(ws, srv), ds, ws, up, tx, pb)

def group.tick(on: Bool, over: Bool, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, srv: S.Srv, ds: R.Ds, ws: Waits, up: List<&2, Up>, +tx: Tx, pb: Ps) -> Grp:
  match on over:
    case False{} _:
      +p = pb
      group.sweep(Bool.or(tx.on(tx), ps.looks(p)), outs, es, srv, ds, ws, up, tx, p)
    case True{} False{}:
      Grp{outs, es, srv, ds, ws, up, tx, pb}
    case True{} True{}:
      +w = ws
      group.resumed(waits.unpause(w, waits.held(w), WaitNone{}, up), outs, es, srv, ds, tx, ps.unpause(pb))

# no tick after a SHUTDOWN that stops the server (SHUTDOWN)
def group.tick.if(stop: Bool, on: Bool, over: Bool, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, srv: S.Srv, +ms: Nat, ds: R.Ds, ws: Waits, up: List<&2, Up>, +tx: Tx, pb: Ps) -> Grp:
  match stop:
    case True{}:
      Grp{outs, es, srv, ds, ws, up, tx, pb}
    case False{}:
      group.tick(on, over, outs, es, S.srv.tick(srv, ms), ds, ws, up, tx, pb)

# at a tick, the tracking table held to tracking-table-max-keys (Tracking
# in the actor: its keys picked at random, by the tick's time) while it
# holds more keys than that, and the ticks over it counted anew once it
# does not (ps.trk.limit)
def grp.limit.if(on: Bool, +ms: Nat, g: Grp) -> Grp:
  match on g:
    case True{} Grp{outs, es, srv, ds, ws, up, tx, pb}:
      grp.pushed(ps.flush(ps.trk.limit(KV.mix(U32.from_nat(ms)), pb), outs), es, srv, ds, ws, up, tx)
    case _ g0:
      g0

def grp.limit(+ms: Nat, g: Grp) -> Grp:
  match g:
    case Grp{outs, es, srv, ds, ws, up, tx, +pb}:
      grp.limit.if(trk.over(ps.trk(pb)), ms, Grp{outs, es, srv, ds, ws, up, tx, pb})

# at a tick, the heeded keys made anew from the clients that wait and
# watch, when one that heeded keys stopped since they were made
# (heed.tick: Heeded keys)
def grp.heed(g: Grp) -> Grp:
  match g:
    case Grp{outs, es, srv, ds, +ws, up, +tx, pb}:
      Grp{outs, es, srv, ds, ws, up, tx, ps.heed.tick(heed.n.tx(tx, heed.n.waits(ws, 0n)), ws, tx, pb)}

# a batch of the client of cn, of its connection's database
def grp.req(+log: Bool, +cn: S.Conn, job: B.Job, back: Chan(Ans), +tl: U32, +inb: Nat, raw: String, g: Grp) -> Grp:
  match g:
    case Grp{outs, es, srv, ds, ws, up, tx, +pb}:
      group_job(log, job, ws, tx, ps.gate(pb), outs, es, cn, back, tl, inb, raw, srv, R.ds.focus(S.conn.db(cn), ds), up, pb)

# a batch of a client with a subscription (Pub/Sub)
def grp.sub(+cn: S.Conn, job: B.Job, back: Chan(Ans), +inb: Nat, raw: String, g: Grp) -> Grp:
  match g:
    case Grp{outs, es, srv, ds, ws, up, tx, pb}:
      sub_job(job, cn, back, inb, raw, Grp{outs, es, srv, R.ds.focus(S.conn.db(cn), ds), ws, up, tx, pb})

# the shell's facts, for INFO; the heap's used bytes left as the actor
# read them before this group (mem.run, then after each key the eviction
# freed: evict.heap), which the eviction went by, when it read them:
# maxmemory set and no pause (mem.need 2), and no CONFIG SET of maxmemory
# since (Mm's kick: the next group reads them). The shell reads the heap
# in another thread before the request reaches the actor, and with its
# reading INFO could show the heap past maxmemory while each group's
# eviction found it within, the eviction stopped a few hundred bytes
# under the limit; Redis's INFO and performEvictions read one counter.
# A pause that ended in this group leaves a reading from before it, of a
# dataset that the pause kept as it was
def facts.held(+pb: Ps, +srv: S.Srv) -> Bool:
  +m = S.srv.mm(srv)
  Bool.and(Nat.is_eq(mem.need(pb), 2n), Bool.and(Nat.is_lt(0n, S.mm.max(m)), Bool.not(S.mm.kick(m))))

def srv.facts(held: Bool, srv: S.Srv, l: I.Live) -> S.Srv:
  match held:
    case True{}:
      S.srv.live.held(srv, l)
    case False{}:
      S.srv.live(srv, l)

def group_req(+log: Bool, q: Req, g: Grp) -> Grp:
  match q g:
    case Req{+cn, job, back, +tl, +inb, raw} g0:
      grp.req(log, cn, job, back, tl, inb, raw, g0)
    case SubReq{+cn, job, back, tl, +inb, raw} g0:
      grp.sub(cn, job, back, inb, raw, g0)
    case Facts{live} Grp{outs, es, +srv, ds, ws, up, tx, +pb}:
      Grp{outs, es, srv.facts(facts.held(pb, srv), srv, live), ds, ws, up, tx, pb}
    case Tick{+ms} Grp{outs, es, srv, +ds, ws, up, tx, +pb}:
      +p = ps.pz(pb)
      grp.heed(grp.limit(ms, group.tick.if(Nat.is_le(2n, ps.down(pb)), pz.on(p), pz.over(p, R.ds.now(ds)), outs, es, srv, ms, ds, ws, up, tx, pb)))
    case Oops{} Grp{outs, es, srv, ds, ws, up, tx, pb}:
      Grp{outs, es, S.srv.erred(srv, "ERR Protocol error"), ds, ws, up, tx, pb}
    case Gone{+id, +back} Grp{outs, es, srv, ds, +ws, +up, tx, pb}:
      grp.gone(id, back, outs, es, srv, ds, ws, up, tx, pb)
    case Left{+id, back} Grp{outs, es, srv, ds, ws, up, tx, pb}:
      Grp{(back, Bye{}) <> outs, es, S.srv.gone(srv, id), ds, ws, up, tx.drop(id, tx), ps.left(id, ps.drop(id, pb))}
    case Join{+id, +back, fd, addr, laddr} Grp{outs, es, +srv, +ds, ws, up, tx, pb}:
      +now = R.ds.now(ds)
      Grp{(back, Ans{None{}, S.conn_join(id, srv)}) <> outs, es, srv, ds, ws, up, tx, ps.join(id, Cl{id, Chan.mark(Ans, back, 0, now), fd, addr, laddr, now, "", 0n, False{}, False{}, TkOff{}}, pb)}

# the clock (IO.clock: s and us since 1970) in ms
def clock.ms(t: U32 & U32) -> Nat:
  (secs, us) = t
  Nat.add(Nat.mul(U32.to_nat(secs), 1000n), U32.to_nat(U32.div(us, 1000)))

def clock.ms.of(+secs: U32, +us: U32) -> Nat:
  Nat.add(Nat.mul(U32.to_nat(secs), 1000n), U32.to_nat(U32.div(us, 1000)))

# Timing
# ------
# The actor reads the monotonic clock (Clock.us, in us mod 2^32) when a
# group starts, after each of its requests and after its end: the window
# between two readings is timed (info.bend: Timing a window), its calls
# sharing it. A reading is no effect, so the group runs as one pure step;
# where a reading falls in s since 1970, for the slow log's entries and
# the latency monitor's samples, comes from the wall clock's reading when
# the group started (IO.clock, as Redis's ustime reads it). A window of a
# batch of the fast way has the batch's bytes and its client's id with
# it, for the slow log's entries of its calls; the general way names
# each call before it runs (S.srv.call, with its arguments as sent: Av).
# The slow log's entries a window finds are completed here: their
# clients' addresses and names from the registry, their arguments read
# from their batches' bytes, redacted as Redis redacts them.

# the us from the clock's reading c0 to c1 (Clock.us)
def us.of(+c0: U32, +c1: U32) -> Nat:
  U32.to_nat(U32.sub(c1, c0))

# the s since 1970 at the clock's reading c, in a group that started when
# the wall clock read s0 s and the us past them that the clock read
# less k
def secs.of(+s0: U32, +k: U32, +c: U32) -> Nat:
  Nat.add(U32.to_nat(s0), Nat.div(U32.to_nat(U32.sub(c, k)), 1000000n))

# the arguments of a batch's requests read last (its bytes, the number of
# the request the list starts at, the list), which the next entry of the
# same batch reads on from
type Sla is Data:
  SlaNone{}
  SlaAt{raw: String, at: Nat, xs: List<&2, List<&2, String>>}

# what an entry's arguments are: those read, and what is read after them
type Slg is Data:
  Slg{args: List<&2, String>, rd: Sla}

def sla.of(+raw: String, +n: Nat, xs: List<&2, List<&2, String>>) -> Slg:
  match xs:
    case Con{x, rest}:
      Slg{x, SlaAt{raw, 1n+n, rest}}
    case Nil{}:
      Slg{Nil{}, SlaNone{}}

def sla.from(same: Bool, +raw: String, +n: Nat, rd: Sla) -> Slg:
  match same rd:
    case True{} SlaAt{r, +at, xs}:
      sla.of(raw, n, List.drop(&2, List<&2, String>, xs, Nat.sub(n, at)))
    case _ _:
      sla.of(raw, n, List.drop(&2, List<&2, String>, P.argvs(raw), n))

def sla.same(+raw: String, +n: Nat, +rd: Sla) -> Bool:
  match rd:
    case SlaAt{+r, +at, xs}:
      Bool.and(Nat.is_le(at, n), Bool.and(Nat.is_eq(String.length(r), String.length(raw)), String.eq(r, raw)))
    case SlaNone{}:
      False{}

def sla.args(a: I.Arg, rd: Sla) -> Slg:
  match a:
    case I.ArgRaw{+raw, +n}:
      +d = rd
      sla.from(sla.same(raw, n, d), raw, n, d)
    case I.ArgList{xs}:
      Slg{xs, rd}

def slow.put(+us: Nat, +now: Nat, +key: Nat, +id: Nat, g: Slg, srv: S.Srv, +pb: Ps) -> S.Srv & Sla:
  match g:
    case Slg{args, rd}:
      (S.srv.slow(srv, us, now, slow.redact(key, args), ps.addr(id, pb), ps.name(id, pb)), rd)

def slow.jobs.at(js: List<&2, I.SlowJ>, +now: Nat, p: S.Srv & Sla, +pb: Ps) -> S.Srv:
  match js:
    case Nil{}:
      (srv, rd) = p
      srv
    case Con{I.SlowJ{+id, +us, +code, arg}, rest}:
      (srv, rd) = p
      slow.jobs.at(rest, now, slow.put(us, now, R.code.key(code), id, sla.args(arg, rd), srv, pb), pb)

# the slow log's entries a window found, oldest first, completed and
# logged at now (s since 1970)
def slow.jobs(js: List<&2, I.SlowJ>, +now: Nat, srv: S.Srv, +pb: Ps) -> S.Srv:
  match js:
    case Nil{}:
      srv
    case _:
      slow.jobs.at(js, now, (srv, SlaNone{}), pb)

def grp.slow(t: S.Tw, +now: Nat, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, ds: R.Ds, ws: Waits, up: List<&2, Up>, tx: Tx, +pb: Ps) -> Grp:
  match t:
    case S.Tw{srv, js}:
      Grp{outs, es, slow.jobs(js, now, srv, pb), ds, ws, up, tx, pb}

# the window that ended at now (s since 1970), which took d us, of the
# batch of raw, the client id's, if it was one (Timing)
def grp.window(+id: Nat, raw: String, +d: Nat, +now: Nat, g: Grp) -> Grp:
  match g:
    case Grp{outs, es, srv, ds, ws, up, tx, +pb}:
      grp.slow(S.srv.window(srv, d, id, raw, now), now, outs, es, ds, ws, up, tx, pb)

def grp.timed.at(how: Nat, +id: Nat, raw: String, +d: Nat, +now: Nat, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, pass: String, cfg: List<&2, C.CItem>, info: I.Info, mm: S.Mm, ds: R.Ds, ws: Waits, up: List<&2, Up>, tx: Tx, pb: Ps) -> Grp:
  match how:
    case 0n:
      Grp{outs, es, S.Srv{pass, cfg, info, mm}, ds, ws, up, tx, pb}
    case 1n:
      Grp{outs, es, S.Srv{pass, cfg, I.info.one(info, d), mm}, ds, ws, up, tx, pb}
    case _:
      grp.window(id, raw, d, now, Grp{outs, es, S.Srv{pass, cfg, info, mm}, ds, ws, up, tx, pb})

# the window timed as it needs (I.info.how: nothing, its one run, or all
# of its timing)
def grp.timed(+id: Nat, raw: String, +d: Nat, +now: Nat, g: Grp) -> Grp:
  match g:
    case Grp{outs, es, S.Srv{pass, cfg, +info, mm}, ds, ws, up, tx, pb}:
      grp.timed.at(I.info.how(info, d), id, raw, d, now, outs, es, pass, cfg, info, mm, ds, ws, up, tx, pb)

# a tick's window: the sweep of expired keys, a sample of the latency
# monitor's event "expire-cycle" when it took its threshold or more (as
# Redis's activeExpireCycle samples it)
def grp.lat(+name: String, +d: Nat, +now: Nat, g: Grp) -> Grp:
  match g:
    case Grp{outs, es, srv, ds, ws, up, tx, pb}:
      Grp{outs, es, S.srv.lat(srv, name, Nat.div(d, 1000n), now), ds, ws, up, tx, pb}

# the clock's reading once g is made (Clock.us, after a word of g)
def grp.clock(+g: Grp) -> U32:
  Clock.us(U32.from_nat(grp.down(g)))

# the group's requests, each timed: the window from the clock's reading
# c0 (Clock.us) to the one after it; s0 and k place a reading in s since
# 1970 (secs.of)
# the end of a group, its window timed when it has a client to see to
# (grp.end.go: one waits, or a batch was unblocked)
def group_end(calm: Bool, g: Grp, +s0: U32, +k: U32, +c0: U32) -> Grp:
  match calm:
    case True{}:
      grp.end(g)
    case False{}:
      +e = grp.end(g)
      +c1 = grp.clock(e)
      grp.timed(0n, "", us.of(c0, c1), secs.of(s0, k, c1), e)

def grp.calm(+g: Grp) -> Bool:
  match g:
    case Grp{outs, es, srv, ds, WaitNone{}, Nil{}, tx, pb}:
      True{}
    case _:
      False{}

def group_all(+log: Bool, qs: List<&1, Req>, g: Grp, +s0: U32, +k: U32, +c0: U32) -> Grp:
  match qs:
    case Nil{}:
      +x = g
      group_end(grp.calm(x), x, s0, k, c0)
    case Con{Req{+cn, job, back, +tl, +inb, +raw}, rest}:
      +g1 = grp.req(log, cn, job, back, tl, inb, raw, g)
      +c1 = grp.clock(g1)
      group_all(log, rest, grp.timed(S.conn.id(cn), raw, us.of(c0, c1), secs.of(s0, k, c1), g1), s0, k, c1)
    case Con{SubReq{+cn, job, back, tl, +inb, +raw}, rest}:
      +g1 = grp.sub(cn, job, back, inb, raw, g)
      +c1 = grp.clock(g1)
      group_all(log, rest, grp.timed(S.conn.id(cn), raw, us.of(c0, c1), secs.of(s0, k, c1), g1), s0, k, c1)
    case Con{Tick{+ms}, rest}:
      +g1 = group_req(log, Tick{ms}, g)
      +c1 = grp.clock(g1)
      group_all(log, rest, grp.lat("expire-cycle", us.of(c0, c1), secs.of(s0, k, c1), g1), s0, k, c1)
    case Con{q, rest}:
      +g1 = group_req(log, q, g)
      +c1 = grp.clock(g1)
      group_all(log, rest, grp.timed(0n, "", us.of(c0, c1), secs.of(s0, k, c1), g1), s0, k, c1)

# the group's requests when the wall clock read s0 s and u0 us past them
# (IO.clock), timed from the clock's reading now
def group_at(+log: Bool, qs: List<&1, Req>, +s0: U32, +u0: U32, g: Grp) -> Grp:
  +c = Clock.us(u0)
  group_all(log, qs, g, s0, U32.sub(c, u0), c)

# the group's requests after an eviction (mem.run), which Redis does not
# count in a call's time either: the first window starts after it; s0 and
# k as group_all takes them
def group_from(+log: Bool, qs: List<&1, Req>, g: Grp, +s0: U32, +k: U32) -> Grp:
  +x = g
  group_all(log, qs, x, s0, k, grp.clock(x))

# The rewrite's state
# -------------------
# What the actor keeps of a rewrite of the append-only file (BGREWRITEAOF,
# and the cron's: The rewrite of the append-only file, below).

# a rewrite that runs: the snapshot left to write (None: all of it is),
# the temporary file's path, the bytes written to it, the snapshot's
# bytes not yet written (newest first: they go to the file 64 KB at a
# time) and how many, and the entries appended to the file since the
# rewrite started (newest first)
type RwRun is Data:
  RwRun{snap: Maybe<&2, A.Snap>, tmp: String, size: Nat, pend: List<&2, String>, pn: Nat, buf: List<&2, String>}

# the file's path (appendfilename with appendonly no, which the rewrite
# writes all the same), whether the server appends to it (appendonly
# yes), the server's pid (the temporary file's name, the log's lines),
# when the cron looks next (ms, each 100 ms as Redis's serverCron), the
# cron's limit after failures in a row (Redis's aofRewriteLimited: its
# next delay in minutes, and the second it holds until, 0 for none), the
# time of the group after which the last slice was written (ms), and the
# rewrite that runs. RwOf, a state that holds a state, is never
# built: it makes Rw a type that holds itself, which the compiler makes a
# node of its own, so that it travels as one word, as Pub/Sub's state
# does; flat, it would be eighteen words in every frame of the actor's
# loop, and the widest frame sets the registers of every function.
type Rw is Data:
  Rw{path: String, aof: Bool, pid: U32, cron: Nat, delay: Nat, until: Nat, last: Nat, run: Maybe<&2, RwRun>}
  RwOf{r: Rw}

# what a step of a rewrite reads and changes: the server's state (INFO's
# account of rewrites), the databases (the snapshot, the time), the
# database the file has selected (A.ents.args) and the rewrite's state
type Rx is Data:
  Rx{srv: S.Srv, ds: R.Ds, sel: Nat, rw: Rw}

def rw.new(+path: String, +aof: Bool, +pid: U32) -> Rw:
  Rw{path, aof, pid, 0n, 0n, 0n, 0n, None{}}

def run.is(+m: Maybe<&2, RwRun>) -> Bool:
  match m:
    case Some{r}:
      True{}
    case None{}:
      False{}

# whether a rewrite runs
def rw.runs(+rw: Rw) -> Bool:
  match rw:
    case Rw{path, aof, pid, cron, delay, until, last, +run}:
      run.is(run)
    case RwOf{+r}:
      rw.runs(r)

# what the actor does about a rewrite once a group is answered, at now
# (the group's time, ms): 0 nothing; 1 start the one the group started
# (the server's state says one runs, and none does); 2 the next slice of
# the one that runs, once 4 ms have passed since the last one (under a
# load that never lets the actor wait, the rewrite takes a small part of
# its time; while no request waits the actor writes slices one after
# another); 3 the cron's look
def rw.what.idle(on: Bool, +cron: Nat, +now: Nat) -> Nat:
  match on:
    case True{}:
      1n
    case False{}:
      Bool.pick(Nat, Nat.is_le(cron, now), 3n, 0n)

def rw.what.of(runs: Bool, +srv: S.Srv, +cron: Nat, +last: Nat, +now: Nat) -> Nat:
  match runs:
    case True{}:
      Bool.pick(Nat, Nat.is_le(Nat.add(last, 4n), now), 2n, 0n)
    case False{}:
      rw.what.idle(S.srv.rw.on(srv), cron, now)

def rw.what(+rw: Rw, +srv: S.Srv, +now: Nat) -> Nat:
  match rw:
    case Rw{path, aof, pid, +cron, delay, until, +last, +run}:
      rw.what.of(run.is(run), srv, cron, last, now)
    case RwOf{+r}:
      rw.what(r, srv, now)

# the entries appended to the file, kept while a rewrite runs
def run.keep(m: Maybe<&2, RwRun>, +bytes: String) -> Maybe<&2, RwRun>:
  match m:
    case Some{RwRun{snap, tmp, size, pend, pn, buf}}:
      Some{RwRun{snap, tmp, size, pend, pn, bytes <> buf}}
    case None{}:
      None{}

def rw.keep(rw: Rw, +bytes: String) -> Rw:
  match rw:
    case Rw{path, aof, pid, cron, delay, until, last, run}:
      Rw{path, aof, pid, cron, delay, until, last, run.keep(run, bytes)}
    case RwOf{r}:
      rw.keep(r, bytes)

# The actor without a file runs a rewrite all the same: while one runs,
# it takes the requests that wait without waiting for one, and writes a
# slice of the snapshot after each group it answers, and one after
# another while no request waits (each with a turn of the event loop for
# the connections, IO.sleep(0)).
@unsafe
def db_loop(srv: S.Srv, ds: R.Ds, ws: Waits, tx: Tx, pb: Ps, rw: Rw, +reqs: Chan(Req)) -> IO(Unit):
  +w = rw
  +p = pb
  db_wait(Bool.or(rw.runs(w), ps.evicting(p)), srv, ds, ws, tx, p, w, reqs)

@unsafe
def db_wait(runs: Bool, srv: S.Srv, ds: R.Ds, ws: Waits, tx: Tx, pb: Ps, rw: Rw, +reqs: Chan(Req)) -> IO(Unit):
  match runs:
    case False{}:
      do IO<Unit>:
        m : Maybe<&1, Req> <- Chan.recv(Req, reqs)
        db_serve(srv, ds, ws, tx, pb, rw, reqs, m)
    case True{}:
      do IO<Unit>:
        qs : List<&1, Req> <- Chan.drain(Req, reqs, group_max())
        db_busy(qs, srv, ds, ws, tx, pb, rw, reqs)

@unsafe
def db_busy(qs: List<&1, Req>, srv: S.Srv, ds: R.Ds, ws: Waits, tx: Tx, pb: Ps, rw: Rw, +reqs: Chan(Req)) -> IO(Unit):
  match qs:
    case Nil{}:
      +p = pb
      db_idle(ps.evicting(p), srv, ds, ws, tx, p, rw, reqs)
    case Con{q, rest}:
      +p = pb
      do IO<Unit>:
        t : U32 & U32 <- IO.clock()
        db_mem(mem.need(p), q <> rest, t, srv, ds, ws, tx, p, rw, reqs)

# while no request waits: an eviction to go on with runs as a group of no
# request, after a turn of the event loop (as Redis's evictionTimeProc
# runs in its loop's turn); else the rewrite's slice
@unsafe
def db_idle(ev: Bool, srv: S.Srv, ds: R.Ds, ws: Waits, tx: Tx, pb: Ps, rw: Rw, +reqs: Chan(Req)) -> IO(Unit):
  match ev:
    case True{}:
      do IO<Unit>:
        Unit <- IO.sleep(0)
        t : U32 & U32 <- IO.clock()
        db_mem(2n, Nil{}, t, srv, ds, ws, tx, pb, rw, reqs)
    case False{}:
      +d = ds
      do IO<Unit>:
        t : U32 & U32 <- IO.clock()
        p : Maybe<&1, File> & Rx <- step.go(idle.step(d, clock.ms(t)), Rx{srv, d, 0n, rw}, None{})
        Unit <- IO.sleep(0)
        db_stepped(p, ws, tx, pb, reqs)

@unsafe
def db_serve(srv: S.Srv, ds: R.Ds, ws: Waits, tx: Tx, pb: Ps, rw: Rw, +reqs: Chan(Req), m: Maybe<&1, Req>) -> IO(Unit):
  match m:
    case None{}:
      IO.pure(Unit, Unit{})
    case Some{q}:
      +p = pb
      do IO<Unit>:
        more : List<&1, Req> <- Chan.drain(Req, reqs, group_max())
        t : U32 & U32 <- IO.clock()
        db_mem(mem.need(p), q <> more, t, srv, ds, ws, tx, p, rw, reqs)

@unsafe
def db_group(g: Grp, rw: Rw, +reqs: Chan(Req)) -> IO(Unit):
  match g:
    case Grp{outs, es, srv, ds, ws, up, tx, +pb}:
      db_down(ps.down(pb), pb, outs, srv, ds, ws, tx, rw, reqs)

# a group that asked the shell for a save or a SHUTDOWN (ps.down): the
# saves it asked for (The RDB file on the disk), then its clients that
# waited for them go on, or a SHUTDOWN's save is made and the server stops
# unless it fails (1: db_saved); or the server stops (2), after a save
# when a SHUTDOWN of the group asked for one, its client waiting (Redis
# would have run that SHUTDOWN, saving, first), or after its own save
# whatever it gives (3, FORCE: db_shut)
@unsafe
def db_down(+d: Nat, +pb: Ps, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, srv: S.Srv, ds: R.Ds, ws: Waits, tx: Tx, rw: Rw, +reqs: Chan(Req)) -> IO(Unit):
  match d:
    case 0n:
      db_kill(ps.calm(pb), pb, outs, srv, ds, ws, tx, rw, reqs)
    case 1n:
      +x = srv
      +y = ds
      +v = ws
      +w = rw
      do IO<Unit>:
        p : S.Srv & Bool <- rdb.saves(down.lg(x, w), x, y, S.srv.rdb.owed(x), rw.pid(w))
        db_saved(p, outs, y, v, tx, pb, w, reqs)
    case 2n:
      +x = srv
      +w = rw
      do IO<Unit>:
        p : S.Srv & Bool <- rdb.saves(down.lg(x, w), x, ds, Bool.or(S.srv.rdb.owed(x), S.srv.rdb.shut(x)), rw.pid(w))
        down.stop.p(p, w, None{})
    case _:
      +x = srv
      +y = ds
      +v = ws
      +w = rw
      do IO<Unit>:
        p : S.Srv & Bool <- rdb.saves(down.lg(x, w), x, y, S.srv.rdb.owed(x), rw.pid(w))
        db_shut(p, True{}, outs, y, v, tx, pb, w, reqs)

# the saves made: the clients that waited for them go on, in a group of
# their own (grp.saved), answered with the group's other answers; or a
# SHUTDOWN asked for its save (S.srv.rdb.shut), made now (db_shut)
@unsafe
def db_saved.of(shut: Bool, srv: S.Srv, +ok: Bool, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, ds: R.Ds, ws: Waits, tx: Tx, pb: Ps, rw: Rw, +reqs: Chan(Req)) -> IO(Unit):
  match shut:
    case False{}:
      db_group(grp.saved(ok, outs, srv, ds, ws, tx, pb), rw, reqs)
    case True{}:
      db_shut((S.srv.rdb.shutting(srv, False{}), ok), False{}, outs, ds, ws, tx, pb, rw, reqs)

@unsafe
def db_saved(p: S.Srv & Bool, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, ds: R.Ds, ws: Waits, tx: Tx, pb: Ps, rw: Rw, +reqs: Chan(Req)) -> IO(Unit):
  (+srv, +ok) = p
  db_saved.of(S.srv.rdb.shut(srv), srv, ok, outs, ds, ws, tx, pb, rw, reqs)

# SHUTDOWN with a save (down.final), without the append-only file; its
# save failed without FORCE, its client and those that waited for the
# group's saves go on, the rewrite stopped
@unsafe
def db_shut.end(ok: Bool, +force: Bool, +ok1: Bool, +srv: S.Srv, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, ds: R.Ds, ws: Waits, tx: Tx, pb: Ps, +rw: Rw, +reqs: Chan(Req)) -> IO(Unit):
  match ok force:
    case True{} _:
      down.exit(srv, down.lg(srv, rw))
    case False{} True{}:
      down.forced(srv, down.lg(srv, rw))
    case False{} False{}:
      do IO<Unit>:
        Unit <- down.cant(down.lg(srv, rw))
        db_group(grp.saved(ok1, outs, S.srv.rw.stop(srv), ds, ws, tx, pb), rw.with(rw, None{}), reqs)

@unsafe
def db_shut(p: S.Srv & Bool, +force: Bool, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, +ds: R.Ds, ws: Waits, tx: Tx, pb: Ps, +rw: Rw, +reqs: Chan(Req)) -> IO(Unit):
  (+srv, +ok1) = p
  +lg = down.lg(srv, rw)
  do IO<Unit>:
    Unit <- log(lg, 3, "User requested shutdown...")
    Unit <- down.rewrite(rw.runs(rw), lg, rw.tmp(rw))
    ok : Bool <- down.final(lg, srv, ds, rw.pid(rw))
    db_shut.end(ok, force, ok1, srv, outs, ds, ws, tx, pb, rw, reqs)

# after a group is answered, the rewrite's step, if any (rw.what)
@unsafe
def db_next(+srv: S.Srv, +ds: R.Ds, ws: Waits, tx: Tx, pb: Ps, +rw: Rw, +reqs: Chan(Req)) -> IO(Unit):
  db_after(rw.what(rw, srv, R.ds.now(ds)), srv, ds, ws, tx, pb, rw, reqs)

@unsafe
def db_after(w: Nat, srv: S.Srv, ds: R.Ds, ws: Waits, tx: Tx, pb: Ps, rw: Rw, +reqs: Chan(Req)) -> IO(Unit):
  match w:
    case 0n:
      db_loop(srv, ds, ws, tx, pb, rw, reqs)
    case _:
      do IO<Unit>:
        p : Maybe<&1, File> & Rx <- step.go(w, Rx{srv, ds, 0n, rw}, None{})
        db_stepped(p, ws, tx, pb, reqs)

@unsafe
def db_stepped(p: Maybe<&1, File> & Rx, ws: Waits, tx: Tx, pb: Ps, +reqs: Chan(Req)) -> IO(Unit):
  (m, x) = p
  match x:
    case Rx{srv, ds, sel, rw}:
      do IO<Unit>:
        Unit <- file.end(m)
        db_loop(srv, ds, ws, tx, pb, rw, reqs)

# the sockets of the clients CLIENT KILL took shut down (TCP.kill), before
# the group's answers go out
@unsafe
def kill_all(ks: List<&2, U32>) -> IO(Unit):
  match ks:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{fd, rest}:
      do IO<Unit>:
        b : Bool <- TCP.kill(fd)
        kill_all(rest)

@unsafe
def db_send(p: List<&2, U32> & Ps, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, srv: S.Srv, ds: R.Ds, ws: Waits, tx: Tx, rw: Rw, +reqs: Chan(Req)) -> IO(Unit):
  (ks, pb) = p
  do IO<Unit>:
    Unit <- kill_all(ks)
    Unit <- Chan.send_all(Ans, List.reverse(&2, Sigma<&2, &2, Chan(Ans), _ => Ans>, outs))
    db_next(srv, ds, ws, tx, pb, rw, reqs)

# while no client was killed (calm), no socket is to be shut down
@unsafe
def db_kill(calm: Bool, pb: Ps, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, srv: S.Srv, ds: R.Ds, ws: Waits, tx: Tx, rw: Rw, +reqs: Chan(Req)) -> IO(Unit):
  match calm:
    case True{}:
      do IO<Unit>:
        Unit <- Chan.send_all(Ans, List.reverse(&2, Sigma<&2, &2, Chan(Ans), _ => Ans>, outs))
        db_next(srv, ds, ws, tx, pb, rw, reqs)
    case False{}:
      db_send(ps.kills(pb), outs, srv, ds, ws, tx, rw, reqs)

# Connections
# -----------

# the connections: how many were taken since the start (the last client
# id given, from 1, as Redis's CLIENT ID) and how many are open. The count
# waits in a channel the listeners and the connections share.
type Tally is Data:
  Tally{taken: Nat, open: Nat}

# a connection's way to the actor: the actor's channel, the channel its
# answers come back on, whether replies are posted, the channel of the
# count of connections (for INFO's facts), and its client's id
type Link is Data:
  Link{db: Chan(Req), back: Chan(Ans), post: Bool, tl: Chan(Tally), id: Nat}

def link.post(+ln: Link) -> Bool:
  match ln:
    case Link{db, back, post, tl, id}:
      post

# A connection ends here, whichever way it ends (the client closed it or
# reset it, a read or a send failed, QUIT, a protocol error): its socket
# closes, after the bytes posted to it (TCP.post), and so does the
# channel its answers come back on, which nothing is on its way to: the
# connection waits for each batch's answer before it goes on, so at its
# end the actor holds no answer for it, and the channel's row is free
# for the next connection. The actor's channel, which every connection
# shares, stays open; the actor is told the client is gone (Left), and
# forgets its transaction and the keys it watched.
@unsafe
def conn_end(s: Socket, ln: Link) -> IO(Unit):
  match ln:
    case Link{db, +back, post, tl, id}:
      do IO<Unit>:
        sent : Bool <- Chan.send(Req, db, Left{id, back})
        Unit <- conn_left(back)
        Unit <- Socket.close(s)
        Chan.close(Ans, back)

# The actor's Bye to the connection's Left: what comes on the channel
# before it (a push to a client with a subscription) is dropped. The
# socket closes only after it, so that the actor, which may shut a
# client's socket down by its fd (CLIENT KILL), never meets an fd closed
# and taken by another connection (Clients).
@unsafe
def conn_left.of(m: Maybe<&1, Ans>, +back: Chan(Ans)) -> IO(Unit):
  match m:
    case Some{Bye{}}:
      IO.pure(Unit, Unit{})
    case Some{a}:
      conn_left(back)
    case None{}:
      IO.pure(Unit, Unit{})

@unsafe
def conn_left(+back: Chan(Ans)) -> IO(Unit):
  do IO<Unit>:
    m : Maybe<&1, Ans> <- Chan.recv(Ans, back)
    conn_left.of(m, back)

# x before s; an empty s costs nothing, so the newest piece is not copied
def cat(x: String, s: String) -> String:
  match s:
    case SNil{}:
      x
    case SCon{h, t}:
      x ++ SCon{h, t}

# the pieces of a buffer, newest first, glued in order before s
def glue(xs: List<&2, String>, s: String) -> String:
  match xs:
    case Nil{}:
      s
    case Con{x, rest}:
      glue(rest, cat(x, s))

# the length of s, counted up to n: enough to compare with a need of n
# (String.length reads a chunk at a time)
def count_upto(+n: Nat, +s: String) -> Nat:
  Nat.min(n, String.length(s))

# the bytes of the pieces read, for INFO
def got.bytes(+xs: List<&2, String>, +acc: Nat) -> Nat:
  match xs:
    case Nil{}:
      acc
    case Con{+x, +rest}:
      got.bytes(rest, Nat.add(acc, String.length(x)))

# the requests read so far: a lone new piece is one run when it is short
# (resp.bend reads longer ones in windows), and the tail of the last
# read with what came since is several; the batch holds the bytes they
# were read from, whole (the parser takes them and gives them back, so
# that nothing shares them), which go to the actor with the batch
def parse_in(rest: P.Tail, got: List<&2, String>) -> P.Batch:
  match rest got:
    case P.TailNone{} Con{x, Nil{}}:
      P.parse_read(x)
    case r g:
      P.parse_tail(r, glue(g, SNil{}))

# the connection's loop: rest is the unparsed tail of what came before
# (at most one incomplete request; of a long one, the arguments read so
# far and the bytes from its bulk not whole yet: P.Tail); got holds the
# pieces read since, newest first, have counts their bytes (up to need),
# and the tail needs need more bytes before a parse can make progress, so
# a large value is parsed once, not once per read; cn is the connection's
# state, as the actor gave it back after the last batch. Bytes cross as
# they are, one Char each (recv_raw, send_raw): a String of them is a
# packed buffer.
@unsafe
def conn_loop(s: Socket, rest: P.Tail, got: List<&2, String>, have: Nat, need: Nat, +ln: Link, cn: S.Conn) -> IO(Unit):
  do IO<Unit>:
    m : Socket & Result<&1, &1, U32 & String, String> <- TCP.recv_raw(s, 65536)
    conn_got(m, rest, got, have, need, ln, cn)

@unsafe
def conn_got(m: Socket & Result<&1, &1, U32 & String, String>, rest: P.Tail, got: List<&2, String>, have: Nat, need: Nat, +ln: Link, cn: S.Conn) -> IO(Unit):
  (s, r) = m
  match r:
    case Fail{e}:
      conn_end(s, ln)
    case Done{+x}:
      conn_data(s, Nat.is_eq(String.length(x), 0n), x, rest, got, have, need, ln, cn)

@unsafe
def conn_data(s: Socket, eof: Bool, +x: String, rest: P.Tail, got: List<&2, String>, have: Nat, +need: Nat, +ln: Link, cn: S.Conn) -> IO(Unit):
  match eof:
    case True{}:
      conn_end(s, ln)
    case False{}:
      +h = Nat.add(have, count_upto(need, x))
      conn_more(s, rest, x <> got, h, need, ln, cn, Nat.is_lt(h, need))

@unsafe
def conn_more(s: Socket, rest: P.Tail, +got: List<&2, String>, have: Nat, need: Nat, +ln: Link, cn: S.Conn, wait: Bool) -> IO(Unit):
  match wait:
    case True{}:
      conn_loop(s, rest, got, have, need, ln, cn)
    case False{}:
      +inb = got.bytes(got, 0n)
      conn_batch(s, parse_in(rest, got), inb, ln, cn)

# A parsed batch goes to the actor, its replies go out, then the
# protocol error the requests ended in, if any, and the next read: rest
# is the unparsed tail and need the bytes it needs, and cn the
# connection's state, as the actor gave it back. These steps call each
# other and conn_loop directly, as the loop's own steps do, rather than
# through a continuation.
@unsafe
def conn_batch(s: Socket, batch: P.Batch, +inb: Nat, +ln: Link, cn: S.Conn) -> IO(Unit):
  match batch:
    case P.Batch{reqs, tl, rest, err, need, raw}:
      conn_send(s, ln, cn, reqs, tl, err, rest, need, inb, raw)

@unsafe
def conn_send(s: Socket, +ln: Link, cn: S.Conn, reqs: List<&2, B.Req>, tl: U32, err: Maybe<&2, String>, rest: P.Tail, need: Nat, +inb: Nat, raw: String) -> IO(Unit):
  match reqs:
    case Nil{}:
      conn_err(s, ln, cn, err, rest, need)
    case Con{r, rs}:
      conn_ask(s, ln, cn, r <> rs, tl, err, rest, need, inb, raw)

# whether a batch asks for the shell's facts: INFO, or CONFIG RESETSTAT
# (which counts the connections from then on); only a batch with a
# command of the connection or of the server (B.Mixed) can
def live.cmd(+c: R.Cmd) -> Bool:
  match c:
    case R.Own{R.SInfo{a}}:
      True{}
    case R.Own{R.SConfigResetStat{}}:
      True{}
    case _:
      False{}

def live.any(+cs: List<&2, R.Cmd>) -> Bool:
  match cs:
    case Nil{}:
      False{}
    case Con{+c, +rest}:
      Bool.or(live.cmd(c), live.any(rest))

def live.wants(+job: B.Job) -> Bool:
  match job:
    case B.Plain{cs, hs}:
      False{}
    case B.Mixed{+cs, hs}:
      live.any(cs)

# the batch to the actor, the answer back; first the shell's facts, for
# a batch that wants them. Each arm sends and waits itself: a step both
# called would be a segment of its own, entered on every batch.
@unsafe
def conn_job(live: Bool, s: Socket, +ln: Link, job: B.Job, cn: S.Conn, n: U32, +inb: Nat, raw: String, err: Maybe<&2, String>, rest: P.Tail, need: Nat) -> IO(Unit):
  match live ln:
    case False{} Link{db, +back, post, tl, id}:
      do IO<Unit>:
        sent : Bool <- Chan.send(Req, db, Req{cn, job, back, n, inb, raw})
        got : Maybe<&1, Ans> <- Chan.recv(Ans, back)
        conn_ans(s, ln, got, err, rest, need)
    case True{} Link{+db, +back, post, +tl, id}:
      do IO<Unit>:
        l : I.Live <- live.read(tl)
        sent1 : Bool <- Chan.send(Req, db, Facts{l})
        sent2 : Bool <- Chan.send(Req, db, Req{cn, job, back, n, inb, raw})
        got : Maybe<&1, Ans> <- Chan.recv(Ans, back)
        conn_ans(s, ln, got, err, rest, need)

# a batch: the parsed requests (newest first) put in order, how many they
# are and the words of their codes (R.tl.add), and the bytes they came in
# (how many, and the bytes themselves)
@unsafe
def conn_ask(s: Socket, +ln: Link, cn: S.Conn, rs: List<&2, B.Req>, tl: U32, err: Maybe<&2, String>, rest: P.Tail, need: Nat, +inb: Nat, raw: String) -> IO(Unit):
  +job = B.job(B.unzip(rs, Nil{}, Nil{}))
  conn_job(live.wants(job), s, ln, job, cn, tl, inb, raw, err, rest, need)

@unsafe
def conn_ans(s: Socket, +ln: Link, got: Maybe<&1, Ans>, err: Maybe<&2, String>, rest: P.Tail, need: Nat) -> IO(Unit):
  match got:
    case None{}:
      conn_end(s, ln)
    case Some{Ans{None{}, cn}}:
      conn_quit(s, ln, cn, err, rest, need)
    case Some{Ans{Some{out}, cn}}:
      conn_put(s, ln, link.post(ln), out, cn, err, rest, need)
    case Some{AnsSub{out, cn}}:
      conn_sub.put(s, ln, link.post(ln), out, cn, err, rest, need)
    case Some{Push{out}}:
      conn_push(s, ln, link.post(ln), out, err, rest, need)
    case Some{Hold{out}}:
      conn_hold(s, ln, link.post(ln), True{}, out, Nil{}, 0n, need, err, rest)
    case Some{Ready{}}:
      conn_end(s, ln)
    case Some{Bye{}}:
      conn_end(s, ln)

@unsafe
def conn_put(s: Socket, +ln: Link, post: Bool, out: String, cn: S.Conn, err: Maybe<&2, String>, rest: P.Tail, need: Nat) -> IO(Unit):
  match post:
    case True{}:
      do IO<Unit>:
        s2 : Socket <- TCP.post(s, out)
        conn_quit(s2, ln, cn, err, rest, need)
    case False{}:
      do IO<Unit>:
        m : Socket & Result<&1, &1, U32 & String, Unit> <- TCP.send_raw(s, out)
        conn_sent(m, ln, cn, err, rest, need)

@unsafe
def conn_sent(m: Socket & Result<&1, &1, U32 & String, Unit>, +ln: Link, cn: S.Conn, err: Maybe<&2, String>, rest: P.Tail, need: Nat) -> IO(Unit):
  (s, r) = m
  match r:
    case Fail{e}:
      conn_end(s, ln)
    case Done{u}:
      conn_quit(s, ln, cn, err, rest, need)

# after a QUIT, the connection closes once its replies are out; the rest
# of what it sent is not read
@unsafe
def conn_quit(s: Socket, +ln: Link, +cn: S.Conn, err: Maybe<&2, String>, rest: P.Tail, need: Nat) -> IO(Unit):
  conn_quit.if(S.conn.quit(cn), s, ln, cn, err, rest, need)

@unsafe
def conn_quit.if(quit: Bool, s: Socket, +ln: Link, cn: S.Conn, err: Maybe<&2, String>, rest: P.Tail, need: Nat) -> IO(Unit):
  match quit:
    case True{}:
      conn_end(s, ln)
    case False{}:
      conn_err(s, ln, cn, err, rest, need)

@unsafe
def conn_sent.end(m: Socket & Result<&1, &1, U32 & String, Unit>, +ln: Link) -> IO(Unit):
  (s, r) = m
  conn_end(s, ln)

# a connection's last bytes, then its end, whether they went out or not:
# posted (TCP.post: the loop hands them to its writer thread, and the
# socket closes once they are sent), or sent from the loop
@unsafe
def conn_bye(s: Socket, +ln: Link, post: Bool, out: String) -> IO(Unit):
  match post:
    case True{}:
      do IO<Unit>:
        s2 : Socket <- TCP.post(s, out)
        conn_end(s2, ln)
    case False{}:
      do IO<Unit>:
        m : Socket & Result<&1, &1, U32 & String, Unit> <- TCP.send_raw(s, out)
        conn_sent.end(m, ln)

# a connection whose protocol error is held back: nothing goes out, and
# what comes in is read and dropped until the client closes it
@unsafe
def conn_drop(s: Socket, +ln: Link) -> IO(Unit):
  do IO<Unit>:
    m : Socket & Result<&1, &1, U32 & String, String> <- TCP.recv_raw(s, 65536)
    conn_dropped(m, ln)

@unsafe
def conn_dropped(m: Socket & Result<&1, &1, U32 & String, String>, +ln: Link) -> IO(Unit):
  (s, r) = m
  match r:
    case Fail{e}:
      conn_end(s, ln)
    case Done{+x}:
      conn_drop.on(Nat.is_eq(String.length(x), 0n), s, ln)

@unsafe
def conn_drop.on(eof: Bool, s: Socket, +ln: Link) -> IO(Unit):
  match eof:
    case True{}:
      conn_end(s, ln)
    case False{}:
      conn_drop(s, ln)

# A protocol error is counted among the error replies for INFO, and
# answered, as any error reply is encoded (on one line: a byte the
# parser did not expect may be a CR or LF), unless the client's replies
# are held back (CLIENT REPLY OFF, or SKIP for the request the error is
# in), as say holds them back (session.bend); then the connection ends,
# as in Redis. A held-back error does not end it, as it does not in
# Redis, which closes a connection once its last reply is written, and
# has none to write, and reads nothing more from it (processInputBuffer
# stops at CLOSE_AFTER_REPLY): it stays open, counted in INFO, and what
# comes on it is read and dropped until the client closes it. Without an
# error, the connection reads on.
@unsafe
def conn_oops(on: Bool, s: Socket, +ln: Link, msg: String) -> IO(Unit):
  match on ln:
    case True{} Link{db, back, post, tl, id}:
      do IO<Unit>:
        sent : Bool <- Chan.send(Req, db, Oops{})
        conn_bye(s, ln, post, P.encode(R.RError{"ERR " ++ msg}))
    case False{} Link{db, back, post, tl, id}:
      do IO<Unit>:
        sent : Bool <- Chan.send(Req, db, Oops{})
        conn_drop(s, ln)

@unsafe
def conn_err(s: Socket, +ln: Link, cn: S.Conn, err: Maybe<&2, String>, rest: P.Tail, need: Nat) -> IO(Unit):
  match err:
    case None{}:
      conn_loop(s, rest, Nil{}, 0n, need, ln, cn)
    case Some{msg}:
      conn_oops(mute.on(S.conn.mode(cn)), s, ln, msg)

# A client that waits
# -------------------
# A batch whose client waits (a blocking command found nothing) is
# answered Hold, with the replies before the blocking command: the
# connection sends them, then waits for the actor's next answer and for
# its socket at once, a watch (TCP.watch) putting Ready on its channel
# when bytes come or the client closes it. What comes meanwhile is kept
# for after the batch, as Redis keeps a blocked client's input; the
# batch's answer (Ans) takes the watch back, and drops the Ready the
# watch put if it fired. A client that closes its connection while it
# waits (or a send that fails) is gone: the actor is told (Gone) and
# answers Bye once it holds nothing for it; the answers before Bye are
# dropped, and the connection ends.
@unsafe
def conn_gone.got(s: Socket, +ln: Link, m: Maybe<&1, Ans>) -> IO(Unit):
  match m:
    case Some{Bye{}}:
      conn_end(s, ln)
    case None{}:
      conn_end(s, ln)
    case Some{a}:
      conn_gone.wait(s, ln)

@unsafe
def conn_gone.wait(s: Socket, +ln: Link) -> IO(Unit):
  match ln:
    case Link{db, +back, post, tl, id}:
      do IO<Unit>:
        m : Maybe<&1, Ans> <- Chan.recv(Ans, back)
        conn_gone.got(s, ln, m)

@unsafe
def conn_gone(s: Socket, +ln: Link) -> IO(Unit):
  match ln:
    case Link{+db, +back, post, tl, +id}:
      do IO<Unit>:
        sent : Bool <- Chan.send(Req, db, Gone{id, back})
        conn_gone.wait(s, ln)

@unsafe
def conn_gone.p(p: Socket & Bool, +ln: Link) -> IO(Unit):
  (s, b) = p
  conn_gone(s, ln)

# the replies of a Hold sent: then the watch put out (a first Hold), or
# out already (a Hold while the client waits)
@unsafe
def conn_held.new(m: Socket & Result<&1, &1, U32 & String, Unit>, +ln: Link, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: P.Tail) -> IO(Unit):
  (s, r) = m
  match r:
    case Fail{e}:
      conn_gone(s, ln)
    case Done{u}:
      conn_watch(s, ln, got, have, need, err, rest)

@unsafe
def conn_held.out(m: Socket & Result<&1, &1, U32 & String, Unit>, +ln: Link, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: P.Tail) -> IO(Unit):
  (s, r) = m
  match r:
    case Fail{e}:
      do IO<Unit>:
        p : Socket & Bool <- TCP.unwatch(s)
        conn_gone.p(p, ln)
    case Done{u}:
      conn_wait(s, ln, got, have, need, err, rest)

@unsafe
def conn_held(m: Socket & Result<&1, &1, U32 & String, Unit>, watch: Bool, +ln: Link, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: P.Tail) -> IO(Unit):
  match watch:
    case True{}:
      conn_held.new(m, ln, got, have, need, err, rest)
    case False{}:
      conn_held.out(m, ln, got, have, need, err, rest)

@unsafe
def conn_hold(s: Socket, +ln: Link, post: Bool, watch: Bool, out: Maybe<&2, String>, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: P.Tail) -> IO(Unit):
  match post out:
    case _ None{}:
      conn_held.on(s, watch, ln, got, have, need, err, rest)
    case True{} Some{x}:
      do IO<Unit>:
        s2 : Socket <- TCP.post(s, x)
        conn_held.on(s2, watch, ln, got, have, need, err, rest)
    case False{} Some{x}:
      do IO<Unit>:
        m : Socket & Result<&1, &1, U32 & String, Unit> <- TCP.send_raw(s, x)
        conn_held(m, watch, ln, got, have, need, err, rest)

@unsafe
def conn_held.on(s: Socket, watch: Bool, +ln: Link, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: P.Tail) -> IO(Unit):
  match watch:
    case True{}:
      conn_watch(s, ln, got, have, need, err, rest)
    case False{}:
      conn_wait(s, ln, got, have, need, err, rest)

@unsafe
def conn_watch(s: Socket, +ln: Link, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: P.Tail) -> IO(Unit):
  match ln:
    case Link{db, +back, post, tl, id}:
      do IO<Unit>:
        s2 : Socket <- TCP.watch(Ans, s, back, Ready{})
        conn_wait(s2, ln, got, have, need, err, rest)

@unsafe
def conn_wait(s: Socket, +ln: Link, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: P.Tail) -> IO(Unit):
  match ln:
    case Link{db, +back, post, tl, id}:
      do IO<Unit>:
        m : Maybe<&1, Ans> <- Chan.recv(Ans, back)
        conn_woke(s, ln, m, got, have, need, err, rest)

@unsafe
def conn_woke(s: Socket, +ln: Link, m: Maybe<&1, Ans>, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: P.Tail) -> IO(Unit):
  match m:
    case None{}:
      conn_end(s, ln)
    case Some{Ready{}}:
      do IO<Unit>:
        r : Socket & Result<&1, &1, U32 & String, String> <- TCP.recv_raw(s, 65536)
        conn_came(r, ln, got, have, need, err, rest)
    case Some{Hold{out}}:
      conn_hold(s, ln, link.post(ln), False{}, out, got, have, need, err, rest)
    case Some{Ans{out, cn}}:
      do IO<Unit>:
        p : Socket & Bool <- TCP.unwatch(s)
        conn_unwatched(p, ln, out, cn, got, have, need, err, rest)
    case Some{AnsSub{out, cn}}:
      do IO<Unit>:
        p : Socket & Bool <- TCP.unwatch(s)
        conn_sub.unwatched(p, ln, out, cn, got, have, need, err, rest)
    case Some{Push{out}}:
      conn_hold(s, ln, link.post(ln), False{}, Some{out}, got, have, need, err, rest)
    case Some{Bye{}}:
      conn_wait(s, ln, got, have, need, err, rest)

# bytes that came while the client waits, kept; or its close
@unsafe
def conn_came.on(eof: Bool, s: Socket, +ln: Link, +x: String, got: List<&2, String>, have: Nat, +need: Nat, err: Maybe<&2, String>, rest: P.Tail) -> IO(Unit):
  match eof:
    case True{}:
      conn_gone(s, ln)
    case False{}:
      conn_watch(s, ln, x <> got, Nat.add(have, count_upto(need, x)), need, err, rest)

@unsafe
def conn_came(r: Socket & Result<&1, &1, U32 & String, String>, +ln: Link, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: P.Tail) -> IO(Unit):
  (s, x) = r
  match x:
    case Fail{e}:
      conn_gone(s, ln)
    case Done{+d}:
      conn_came.on(Nat.is_eq(String.length(d), 0n), s, ln, d, got, have, need, err, rest)

# the batch's answer: the watch taken back (a Ready it put dropped), the
# replies sent, then what came meanwhile read on, as after any batch
@unsafe
def conn_unwatched.drop(s: Socket, +ln: Link, out: Maybe<&2, String>, cn: S.Conn, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: P.Tail) -> IO(Unit):
  match ln:
    case Link{db, +back, post, tl, id}:
      do IO<Unit>:
        m : Maybe<&1, Ans> <- Chan.recv(Ans, back)
        conn_resume(s, ln, out, cn, got, have, need, err, rest)

@unsafe
def conn_unwatched(p: Socket & Bool, +ln: Link, out: Maybe<&2, String>, cn: S.Conn, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: P.Tail) -> IO(Unit):
  (s, taken) = p
  match taken:
    case True{}:
      conn_resume(s, ln, out, cn, got, have, need, err, rest)
    case False{}:
      conn_unwatched.drop(s, ln, out, cn, got, have, need, err, rest)

@unsafe
def conn_resume(s: Socket, +ln: Link, out: Maybe<&2, String>, cn: S.Conn, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: P.Tail) -> IO(Unit):
  match ln out:
    case Link{db, back, post, tl, id} None{}:
      conn_after(s, ln, cn, got, have, need, err, rest)
    case Link{db, back, True{}, tl, id} Some{x}:
      do IO<Unit>:
        s2 : Socket <- TCP.post(s, x)
        conn_after(s2, ln, cn, got, have, need, err, rest)
    case Link{db, back, False{}, tl, id} Some{x}:
      do IO<Unit>:
        m : Socket & Result<&1, &1, U32 & String, Unit> <- TCP.send_raw(s, x)
        conn_resent(m, ln, cn, got, have, need, err, rest)

@unsafe
def conn_resent(m: Socket & Result<&1, &1, U32 & String, Unit>, +ln: Link, cn: S.Conn, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: P.Tail) -> IO(Unit):
  (s, r) = m
  match r:
    case Fail{e}:
      conn_end(s, ln)
    case Done{u}:
      conn_after(s, ln, cn, got, have, need, err, rest)

@unsafe
def conn_after.q(quit: Bool, s: Socket, +ln: Link, +cn: S.Conn, +got: List<&2, String>, +have: Nat, +need: Nat, err: Maybe<&2, String>, rest: P.Tail) -> IO(Unit):
  match quit err:
    case True{} _:
      conn_end(s, ln)
    case False{} Some{msg}:
      conn_oops(mute.on(S.conn.mode(cn)), s, ln, msg)
    case False{} None{}:
      conn_more(s, rest, got, have, need, ln, cn, Nat.is_lt(have, need))

@unsafe
def conn_after(s: Socket, +ln: Link, +cn: S.Conn, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: P.Tail) -> IO(Unit):
  conn_after.q(S.conn.quit(cn), s, ln, cn, got, have, need, err, rest)

# A subscribed client
# -------------------
# A client with a subscription waits for its socket and for what is
# published to it at once: a watch of the socket (TCP.watch) puts Ready
# on its channel when bytes come or the client closes it, and the actor
# puts there the messages published to it (Push), which the connection
# writes out as they come. Bytes that come are read as by any connection
# (the watch has fired, so the read finds them at once), and a batch goes
# to the actor as a SubReq; pushes that come before its answer are
# written first, in the order they came. The answer says whether the
# client still has a subscription after the batch (AnsSub), and the
# connection waits so, or reads on as any connection (Ans). These steps
# are the loop's own steps for a subscribed client, so that the loop of
# every other client stays as it was. A connection that ends while its
# watch waits takes it back first.

# a push before a batch's answer, written, then the wait for the answer
@unsafe
def conn_ans.wait(s: Socket, +ln: Link, err: Maybe<&2, String>, rest: P.Tail, need: Nat) -> IO(Unit):
  match ln:
    case Link{db, +back, post, tl, id}:
      do IO<Unit>:
        got : Maybe<&1, Ans> <- Chan.recv(Ans, back)
        conn_ans(s, ln, got, err, rest, need)

@unsafe
def conn_pushed(m: Socket & Result<&1, &1, U32 & String, Unit>, +ln: Link, err: Maybe<&2, String>, rest: P.Tail, need: Nat) -> IO(Unit):
  (s, r) = m
  match r:
    case Fail{e}:
      conn_end(s, ln)
    case Done{u}:
      conn_ans.wait(s, ln, err, rest, need)

@unsafe
def conn_push(s: Socket, +ln: Link, post: Bool, out: String, err: Maybe<&2, String>, rest: P.Tail, need: Nat) -> IO(Unit):
  match post:
    case True{}:
      do IO<Unit>:
        s2 : Socket <- TCP.post(s, out)
        conn_ans.wait(s2, ln, err, rest, need)
    case False{}:
      do IO<Unit>:
        m : Socket & Result<&1, &1, U32 & String, Unit> <- TCP.send_raw(s, out)
        conn_pushed(m, ln, err, rest, need)

# A batch's answer to a subscribed client: as any answer, but that the
# connection then waits as a subscribed client while the answer says it
# still has a subscription
@unsafe
def conn_sub.ans.wait(s: Socket, +ln: Link, err: Maybe<&2, String>, rest: P.Tail, need: Nat) -> IO(Unit):
  match ln:
    case Link{db, +back, post, tl, id}:
      do IO<Unit>:
        got : Maybe<&1, Ans> <- Chan.recv(Ans, back)
        conn_sub.ans(s, ln, got, err, rest, need)

@unsafe
def conn_sub.pushed(m: Socket & Result<&1, &1, U32 & String, Unit>, +ln: Link, err: Maybe<&2, String>, rest: P.Tail, need: Nat) -> IO(Unit):
  (s, r) = m
  match r:
    case Fail{e}:
      conn_end(s, ln)
    case Done{u}:
      conn_sub.ans.wait(s, ln, err, rest, need)

@unsafe
def conn_sub.ans.push(s: Socket, +ln: Link, post: Bool, out: String, err: Maybe<&2, String>, rest: P.Tail, need: Nat) -> IO(Unit):
  match post:
    case True{}:
      do IO<Unit>:
        s2 : Socket <- TCP.post(s, out)
        conn_sub.ans.wait(s2, ln, err, rest, need)
    case False{}:
      do IO<Unit>:
        m : Socket & Result<&1, &1, U32 & String, Unit> <- TCP.send_raw(s, out)
        conn_sub.pushed(m, ln, err, rest, need)

@unsafe
def conn_sub.ans(s: Socket, +ln: Link, got: Maybe<&1, Ans>, err: Maybe<&2, String>, rest: P.Tail, need: Nat) -> IO(Unit):
  match got:
    case Some{AnsSub{out, cn}}:
      conn_sub.put(s, ln, link.post(ln), out, cn, err, rest, need)
    case Some{Push{out}}:
      conn_sub.ans.push(s, ln, link.post(ln), out, err, rest, need)
    case other:
      conn_ans(s, ln, other, err, rest, need)

# the answer's replies written, then the connection's end (QUIT), its
# protocol error, or its wait as a subscribed client
@unsafe
def conn_sub.err(s: Socket, +ln: Link, cn: S.Conn, err: Maybe<&2, String>, rest: P.Tail, need: Nat) -> IO(Unit):
  match err:
    case None{}:
      conn_sub(s, rest, Nil{}, 0n, need, ln, cn)
    case Some{msg}:
      conn_oops(mute.on(S.conn.mode(cn)), s, ln, msg)

@unsafe
def conn_sub.quit.if(quit: Bool, s: Socket, +ln: Link, cn: S.Conn, err: Maybe<&2, String>, rest: P.Tail, need: Nat) -> IO(Unit):
  match quit:
    case True{}:
      conn_end(s, ln)
    case False{}:
      conn_sub.err(s, ln, cn, err, rest, need)

@unsafe
def conn_sub.quit(s: Socket, +ln: Link, +cn: S.Conn, err: Maybe<&2, String>, rest: P.Tail, need: Nat) -> IO(Unit):
  conn_sub.quit.if(S.conn.quit(cn), s, ln, cn, err, rest, need)

@unsafe
def conn_sub.sent(m: Socket & Result<&1, &1, U32 & String, Unit>, +ln: Link, cn: S.Conn, err: Maybe<&2, String>, rest: P.Tail, need: Nat) -> IO(Unit):
  (s, r) = m
  match r:
    case Fail{e}:
      conn_end(s, ln)
    case Done{u}:
      conn_sub.quit(s, ln, cn, err, rest, need)

@unsafe
def conn_sub.put(s: Socket, +ln: Link, post: Bool, out: Maybe<&2, String>, cn: S.Conn, err: Maybe<&2, String>, rest: P.Tail, need: Nat) -> IO(Unit):
  match post out:
    case _ None{}:
      conn_sub.quit(s, ln, cn, err, rest, need)
    case True{} Some{x}:
      do IO<Unit>:
        s2 : Socket <- TCP.post(s, x)
        conn_sub.quit(s2, ln, cn, err, rest, need)
    case False{} Some{x}:
      do IO<Unit>:
        m : Socket & Result<&1, &1, U32 & String, Unit> <- TCP.send_raw(s, x)
        conn_sub.sent(m, ln, cn, err, rest, need)

# A batch of a subscribed client to the actor (SubReq), as conn_job sends
# any batch
@unsafe
def conn_sub.job(live: Bool, s: Socket, +ln: Link, job: B.Job, cn: S.Conn, n: U32, +inb: Nat, raw: String, err: Maybe<&2, String>, rest: P.Tail, need: Nat) -> IO(Unit):
  match live ln:
    case False{} Link{db, +back, post, tl, id}:
      do IO<Unit>:
        sent : Bool <- Chan.send(Req, db, SubReq{cn, job, back, n, inb, raw})
        got : Maybe<&1, Ans> <- Chan.recv(Ans, back)
        conn_sub.ans(s, ln, got, err, rest, need)
    case True{} Link{+db, +back, post, +tl, id}:
      do IO<Unit>:
        l : I.Live <- live.read(tl)
        sent1 : Bool <- Chan.send(Req, db, Facts{l})
        sent2 : Bool <- Chan.send(Req, db, SubReq{cn, job, back, n, inb, raw})
        got : Maybe<&1, Ans> <- Chan.recv(Ans, back)
        conn_sub.ans(s, ln, got, err, rest, need)

@unsafe
def conn_sub.ask(s: Socket, +ln: Link, cn: S.Conn, rs: List<&2, B.Req>, tl: U32, err: Maybe<&2, String>, rest: P.Tail, need: Nat, +inb: Nat, raw: String) -> IO(Unit):
  +job = B.job(B.unzip(rs, Nil{}, Nil{}))
  conn_sub.job(live.wants(job), s, ln, job, cn, tl, inb, raw, err, rest, need)

@unsafe
def conn_sub.send(s: Socket, +ln: Link, cn: S.Conn, reqs: List<&2, B.Req>, tl: U32, err: Maybe<&2, String>, rest: P.Tail, need: Nat, +inb: Nat, raw: String) -> IO(Unit):
  match reqs:
    case Nil{}:
      conn_sub.err(s, ln, cn, err, rest, need)
    case Con{r, rs}:
      conn_sub.ask(s, ln, cn, r <> rs, tl, err, rest, need, inb, raw)

@unsafe
def conn_sub.batch(s: Socket, batch: P.Batch, +inb: Nat, +ln: Link, cn: S.Conn) -> IO(Unit):
  match batch:
    case P.Batch{reqs, tl, rest, err, need, raw}:
      conn_sub.send(s, ln, cn, reqs, tl, err, rest, need, inb, raw)


# bytes read once the watch fired, as conn_got, conn_data and conn_more
# take them
@unsafe
def conn_sub.more(s: Socket, rest: P.Tail, +got: List<&2, String>, have: Nat, need: Nat, +ln: Link, cn: S.Conn, wait: Bool) -> IO(Unit):
  match wait:
    case True{}:
      conn_sub(s, rest, got, have, need, ln, cn)
    case False{}:
      +inb = got.bytes(got, 0n)
      conn_sub.batch(s, parse_in(rest, got), inb, ln, cn)

@unsafe
def conn_sub.data(s: Socket, eof: Bool, +x: String, rest: P.Tail, got: List<&2, String>, have: Nat, +need: Nat, +ln: Link, cn: S.Conn) -> IO(Unit):
  match eof:
    case True{}:
      conn_end(s, ln)
    case False{}:
      +h = Nat.add(have, count_upto(need, x))
      conn_sub.more(s, rest, x <> got, h, need, ln, cn, Nat.is_lt(h, need))

@unsafe
def conn_sub.got(m: Socket & Result<&1, &1, U32 & String, String>, rest: P.Tail, got: List<&2, String>, have: Nat, need: Nat, +ln: Link, cn: S.Conn) -> IO(Unit):
  (s, r) = m
  match r:
    case Fail{e}:
      conn_end(s, ln)
    case Done{+x}:
      conn_sub.data(s, Nat.is_eq(String.length(x), 0n), x, rest, got, have, need, ln, cn)

# The wait: for the socket and for pushes at once
@unsafe
def conn_sub.end(p: Socket & Bool, +ln: Link) -> IO(Unit):
  (s, b) = p
  conn_end(s, ln)

@unsafe
def conn_sub.wsent(m: Socket & Result<&1, &1, U32 & String, Unit>, rest: P.Tail, got: List<&2, String>, have: Nat, need: Nat, +ln: Link, cn: S.Conn) -> IO(Unit):
  (s, r) = m
  match r:
    case Fail{e}:
      do IO<Unit>:
        p : Socket & Bool <- TCP.unwatch(s)
        conn_sub.end(p, ln)
    case Done{u}:
      conn_sub.wait(s, rest, got, have, need, ln, cn)

# a push written while the watch waits
@unsafe
def conn_sub.push(s: Socket, post: Bool, out: String, rest: P.Tail, got: List<&2, String>, have: Nat, need: Nat, +ln: Link, cn: S.Conn) -> IO(Unit):
  match post:
    case True{}:
      do IO<Unit>:
        s2 : Socket <- TCP.post(s, out)
        conn_sub.wait(s2, rest, got, have, need, ln, cn)
    case False{}:
      do IO<Unit>:
        m : Socket & Result<&1, &1, U32 & String, Unit> <- TCP.send_raw(s, out)
        conn_sub.wsent(m, rest, got, have, need, ln, cn)

@unsafe
def conn_sub.woke(s: Socket, m: Maybe<&1, Ans>, rest: P.Tail, got: List<&2, String>, have: Nat, need: Nat, +ln: Link, cn: S.Conn) -> IO(Unit):
  match m:
    case Some{Ready{}}:
      do IO<Unit>:
        r : Socket & Result<&1, &1, U32 & String, String> <- TCP.recv_raw(s, 65536)
        conn_sub.got(r, rest, got, have, need, ln, cn)
    case Some{Push{out}}:
      conn_sub.push(s, link.post(ln), out, rest, got, have, need, ln, cn)
    case Some{a}:
      conn_sub.wait(s, rest, got, have, need, ln, cn)
    case None{}:
      do IO<Unit>:
        p : Socket & Bool <- TCP.unwatch(s)
        conn_sub.end(p, ln)

@unsafe
def conn_sub.wait(s: Socket, rest: P.Tail, got: List<&2, String>, have: Nat, need: Nat, +ln: Link, cn: S.Conn) -> IO(Unit):
  match ln:
    case Link{db, +back, post, tl, id}:
      do IO<Unit>:
        m : Maybe<&1, Ans> <- Chan.recv(Ans, back)
        conn_sub.woke(s, m, rest, got, have, need, ln, cn)

@unsafe
def conn_sub(s: Socket, rest: P.Tail, got: List<&2, String>, have: Nat, need: Nat, +ln: Link, cn: S.Conn) -> IO(Unit):
  match ln:
    case Link{db, +back, post, tl, id}:
      do IO<Unit>:
        s2 : Socket <- TCP.watch(Ans, s, back, Ready{})
        conn_sub.wait(s2, rest, got, have, need, ln, cn)

# A client that waited (Blocked clients) and has a subscription after its
# batch: its answer's replies written once the watch is taken back, then
# what came meanwhile read on as a subscribed client
@unsafe
def conn_sub.after.q(quit: Bool, s: Socket, +ln: Link, +cn: S.Conn, +got: List<&2, String>, +have: Nat, +need: Nat, err: Maybe<&2, String>, rest: P.Tail) -> IO(Unit):
  match quit err:
    case True{} _:
      conn_end(s, ln)
    case False{} Some{msg}:
      conn_oops(mute.on(S.conn.mode(cn)), s, ln, msg)
    case False{} None{}:
      conn_sub.more(s, rest, got, have, need, ln, cn, Nat.is_lt(have, need))

@unsafe
def conn_sub.after(s: Socket, +ln: Link, +cn: S.Conn, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: P.Tail) -> IO(Unit):
  conn_sub.after.q(S.conn.quit(cn), s, ln, cn, got, have, need, err, rest)

@unsafe
def conn_sub.resent(m: Socket & Result<&1, &1, U32 & String, Unit>, +ln: Link, cn: S.Conn, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: P.Tail) -> IO(Unit):
  (s, r) = m
  match r:
    case Fail{e}:
      conn_end(s, ln)
    case Done{u}:
      conn_sub.after(s, ln, cn, got, have, need, err, rest)

@unsafe
def conn_sub.resume(s: Socket, +ln: Link, out: Maybe<&2, String>, cn: S.Conn, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: P.Tail) -> IO(Unit):
  match ln out:
    case Link{db, back, post, tl, id} None{}:
      conn_sub.after(s, ln, cn, got, have, need, err, rest)
    case Link{db, back, True{}, tl, id} Some{x}:
      do IO<Unit>:
        s2 : Socket <- TCP.post(s, x)
        conn_sub.after(s2, ln, cn, got, have, need, err, rest)
    case Link{db, back, False{}, tl, id} Some{x}:
      do IO<Unit>:
        m : Socket & Result<&1, &1, U32 & String, Unit> <- TCP.send_raw(s, x)
        conn_sub.resent(m, ln, cn, got, have, need, err, rest)

@unsafe
def conn_sub.unwatched.drop(s: Socket, +ln: Link, out: Maybe<&2, String>, cn: S.Conn, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: P.Tail) -> IO(Unit):
  match ln:
    case Link{db, +back, post, tl, id}:
      do IO<Unit>:
        m : Maybe<&1, Ans> <- Chan.recv(Ans, back)
        conn_sub.resume(s, ln, out, cn, got, have, need, err, rest)

@unsafe
def conn_sub.unwatched(p: Socket & Bool, +ln: Link, out: Maybe<&2, String>, cn: S.Conn, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: P.Tail) -> IO(Unit):
  (s, taken) = p
  match taken:
    case True{}:
      conn_sub.resume(s, ln, out, cn, got, have, need, err, rest)
    case False{}:
      conn_sub.unwatched.drop(s, ln, out, cn, got, have, need, err, rest)

# Accepting
# ---------
# Each connection gets the next id, from 1, as in Redis (CLIENT ID): the
# count of connections taken (Tally) waits in a channel the listeners and
# the connections share.

# the connection's state as the actor answered its Join: authenticated
# when the server had no password then (S.conn_join)
@unsafe
def conn_start.of(m: Maybe<&1, Ans>, s: Socket, +ln: Link, +id: Nat) -> IO(Unit):
  match m:
    case Some{Ans{o, cn}}:
      conn_loop(s, P.TailNone{}, Nil{}, 0n, 1n, ln, cn)
    case _:
      conn_loop(s, P.TailNone{}, Nil{}, 0n, 1n, ln, S.conn_new(id))

# the connection's client joins the actor's registry (Join: its socket's
# fd and addresses, TCP.name) before its first batch, which waits for the
# actor's answer: the client's state as it joins, its authentication
# decided where Redis decides it, as the client comes (Clients)
@unsafe
def conn_joined(n: Socket & (U32 & (String & String)), +db: Chan(Req), +back: Chan(Ans), post: Bool, tl: Chan(Tally), +id: Nat) -> IO(Unit):
  (s, i) = n
  (fd, a) = i
  (addr, laddr) = a
  do IO<Unit>:
    sent : Bool <- Chan.send(Req, db, Join{id, back, fd, addr, laddr})
    m : Maybe<&1, Ans> <- Chan.recv(Ans, back)
    conn_start.of(m, s, Link{db, back, post, tl, id}, id)

@unsafe
def conn_start(s: Socket, db: Chan(Req), post: Bool, tl: Chan(Tally), +id: Nat) -> IO(Unit):
  do IO<Unit>:
    back : Chan(Ans) <- Chan.new(Ans, 1)
    n : Socket & (U32 & (String & String)) <- TCP.name(s)
    conn_joined(n, db, back, post, tl, id)

@unsafe
def tally.took(m: Maybe<&1, Tally>, +tl: Chan(Tally)) -> IO(Nat):
  match m:
    case Some{Tally{+t, o}}:
      do IO<Nat>:
        ok : Bool <- Chan.send(Tally, tl, Tally{1n+t, 1n+o})
        return 1n+t
    case None{}:
      IO.pure(Nat, 0n)

# a connection taken: one more open, and its id
@unsafe
def tally.take(+tl: Chan(Tally)) -> IO(Nat):
  do IO<Nat>:
    m : Maybe<&1, Tally> <- Chan.recv(Tally, tl)
    tally.took(m, tl)

@unsafe
def tally.closed(m: Maybe<&1, Tally>, +tl: Chan(Tally)) -> IO(Unit):
  match m:
    case Some{Tally{t, o}}:
      do IO<Unit>:
        ok : Bool <- Chan.send(Tally, tl, Tally{t, Nat.sub(o, 1n)})
        return Unit{}
    case None{}:
      IO.pure(Unit, Unit{})

# a connection closed: one less open
@unsafe
def tally.close(+tl: Chan(Tally)) -> IO(Unit):
  do IO<Unit>:
    m : Maybe<&1, Tally> <- Chan.recv(Tally, tl)
    tally.closed(m, tl)

@unsafe
def tally.back(m: Maybe<&1, Tally>, +tl: Chan(Tally)) -> IO(Tally):
  match m:
    case Some{+c}:
      do IO<Tally>:
        ok : Bool <- Chan.send(Tally, tl, c)
        return c
    case None{}:
      IO.pure(Tally, Tally{0n, 0n})

# the count, left as it is
@unsafe
def tally.peek(+tl: Chan(Tally)) -> IO(Tally):
  do IO<Tally>:
    m : Maybe<&1, Tally> <- Chan.recv(Tally, tl)
    tally.back(m, tl)

# a connection, counted open until it ends
@unsafe
def conn_life(s: Socket, +db: Chan(Req), +post: Bool, +tl: Chan(Tally), id: Nat) -> IO(Unit):
  do IO<Unit>:
    Unit <- conn_start(s, db, post, tl, id)
    tally.close(tl)

@unsafe
def accept_next(m: Listener & Result<&1, &1, U32 & String, Socket>, +db: Chan(Req), +post: Bool, +tl: Chan(Tally)) -> IO(Listener):
  (l, r) = m
  match r:
    case Done{s}:
      do IO<Listener>:
        id : Nat <- tally.take(tl)
        IO.spawn(Unit, conn_life(s, db, post, tl, id))
        return l
    case Fail{e}:
      IO.pure(Listener, l)

@unsafe
def accept_loop(l: Listener, +db: Chan(Req), +post: Bool, +tl: Chan(Tally)) -> IO(Unit):
  do IO<Unit>:
    m : Listener & Result<&1, &1, U32 & String, Socket> <- TCP.accept(l)
    l2 : Listener <- accept_next(m, db, post, tl)
    accept_loop(l2, db, post, tl)

@unsafe
def accept_each(ls: List<&1, Listener>, +db: Chan(Req), +post: Bool, +tl: Chan(Tally)) -> IO(Unit):
  match ls:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{l, rest}:
      do IO<Unit>:
        IO.spawn(Unit, accept_loop(l, db, post, tl))
        accept_each(rest, db, post, tl)

# INFO's facts
# ------------
# What only the shell can see, read where Linux shows it (/proc) as Redis
# reads its own with uname, getrusage and its allocator: the system, the
# machine's memory, the resident memory, the processor time of the
# process and of its main thread (in clock ticks of 10 ms); the clock;
# and the connections, from the channel their count waits in.

def words.keep(empty: Bool, +w: String, rest: List<&2, String>) -> List<&2, String>:
  match empty:
    case True{}:
      rest
    case False{}:
      w <> rest

def words.go(ws: List<&2, String>) -> List<&2, String>:
  match ws:
    case Nil{}:
      Nil{}
    case Con{+w, rest}:
      words.keep(String.is_empty(w), w, words.go(rest))

# the words of a line, at its spaces
def words.of(+s: String) -> List<&2, String>:
  words.go(String.split(T.trim(s), ' '))

def nth(n: Nat, xs: List<&2, String>) -> String:
  match n xs:
    case 0n Con{x, rest}:
      x
    case 1n+m Con{x, rest}:
      nth(m, rest)
    case _ Nil{}:
      ""

def last(xs: List<&2, String>, +d: String) -> String:
  match xs:
    case Nil{}:
      d
    case Con{x, rest}:
      last(rest, x)

def nat.of(+s: String) -> Nat:
  Bool.pick(Nat, C.text.digits(s), C.dec.small(s, 0n), 0n)

# a field of /proc/.../stat, counted from the one after the command's
# name (which may hold spaces): 11 is utime, 12 stime
def stat.field(+s: String, +k: Nat) -> Nat:
  nat.of(nth(k, words.of(last(String.split(s, ')'), ""))))

def live.of(t: U32 & U32, +ps: String, +ts: String, +sm: String, h: Nat & Nat, c: Tally) -> I.Live:
  (secs, us) = t
  (heap, act) = h
  match c:
    case Tally{taken, open}:
      I.ILive{secs, us, stat.field(ps, 11n), stat.field(ps, 12n), stat.field(ts, 11n), stat.field(ts, 12n), Nat.mul(nat.of(nth(1n, words.of(sm))), 4096n), heap, act, taken, open, I.cn.zero()}

def hex8.go(n: Nat, +x: U32, acc: String) -> String:
  match n:
    case 0n:
      acc
    case 1n+m:
      hex8.go(m, U32.div(x, 16), SCon{T.hex.digit(U32.and(x, 15)), acc})

def hex.word(r: Result<&1, &1, U32 & String, U32>) -> String:
  match r:
    case Done{+x}:
      hex8.go(8n, x, "")
    case Fail{e}:
      "00000000"

def boot.of(+o1: String, +o2: String, +o3: String, +mem: String, h: Nat & Nat, run: String, rep: String, t: U32 & U32, +pid: U32, exe: String, conf: String) -> I.Boot:
  (heap, act) = h
  (secs, us) = t
  I.IBoot{T.trim(o1) ++ " " ++ T.trim(o2) ++ " " ++ T.trim(o3), U32.show(pid), run, rep, exe, conf, Nat.mul(nat.of(nth(1n, words.of(T.first(String.split(mem, '\n'))))), 1024n), secs, heap}

@unsafe
def proc.got(m: Result<&1, &1, U32 & String, File>) -> IO(String):
  match m:
    case Done{f}:
      do IO<String>:
        p : File & String <- text.all(f, Nil{})
        text.closed(p)
    case Fail{e}:
      IO.pure(String, "")

# a file of /proc ("" if it cannot be read)
@unsafe
def proc.text(+path: String) -> IO(String):
  do IO<String>:
    m : Result<&1, &1, U32 & String, File> <- File.open(path, "r")
    proc.got(m)

# 40 hex digits at random, as Redis's run and replication ids
@unsafe
def hex40() -> IO(String):
  do IO<String>:
    a : Result<&1, &1, U32 & String, U32> <- IO.random_u32()
    b : Result<&1, &1, U32 & String, U32> <- IO.random_u32()
    c : Result<&1, &1, U32 & String, U32> <- IO.random_u32()
    d : Result<&1, &1, U32 & String, U32> <- IO.random_u32()
    e : Result<&1, &1, U32 & String, U32> <- IO.random_u32()
    return hex.word(a) ++ hex.word(b) ++ hex.word(c) ++ hex.word(d) ++ hex.word(e)

# the facts now (the main thread's id is the pid)
@unsafe
def live.read(+tl: Chan(Tally)) -> IO(I.Live):
  do IO<I.Live>:
    t : U32 & U32 <- IO.clock()
    pid : U32 <- IO.pid()
    ps : String <- proc.text("/proc/self/stat")
    ts : String <- proc.text("/proc/self/task/" ++ U32.show(pid) ++ "/stat")
    sm : String <- proc.text("/proc/self/statm")
    h : Nat & Nat <- IO.heap()
    c : Tally <- tally.peek(tl)
    return live.of(t, ps, ts, sm, h, c)

# the facts of the start: the program's and the configuration file's
# absolute paths come from the start's own reading
@unsafe
def boot.read(+pid: U32, +exe: String, +conf: String) -> IO(I.Boot):
  do IO<I.Boot>:
    o1 : String <- proc.text("/proc/sys/kernel/ostype")
    o2 : String <- proc.text("/proc/sys/kernel/osrelease")
    o3 : String <- proc.text("/proc/sys/kernel/arch")
    mem : String <- proc.text("/proc/meminfo")
    h : Nat & Nat <- IO.heap()
    run : String <- hex40()
    rep : String <- hex40()
    t : U32 & U32 <- IO.clock()
    return boot.of(o1, o2, o3, mem, h, run, rep, t, pid, exe, conf)

# INFO's account at the start, before the append-only file is read
@unsafe
def info.read(+pid: U32, +exe: String, +conf: String, +tl: Chan(Tally)) -> IO(I.Info):
  do IO<I.Info>:
    boot : I.Boot <- boot.read(pid, exe, conf)
    live : I.Live <- live.read(tl)
    return I.info.new(boot, live)

# The log
# -------
# BendKV's log, in Redis's form (startup.bend: T.log.line): on the
# standard output, or appended to logfile, which is opened for each line
# as Redis opens it (a rotated file is let go at the next line); a line
# under loglevel is left out. role is 'C' until the server listens, 'M'
# after, as in Redis.
type Log is Data:
  Log{file: String, level: U32, pid: U32, role: String}

def log.level(+lg: Log) -> U32:
  match lg:
    case Log{file, level, pid, role}:
      level

def log.up(lg: Log) -> Log:
  match lg:
    case Log{file, level, pid, role}:
      Log{file, level, pid, "M"}

def log.of(+items: List<&2, C.CItem>, +pid: U32) -> Log:
  Log{T.cfg(items, "logfile"), T.log.level(T.cfg(items, "loglevel")), pid, "C"}

# the log before the configuration is read: the standard output, notice
def log.boot(+pid: U32) -> Log:
  Log{"", 2, pid, "C"}

@unsafe
def log.closed(p: File & Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  (f, r) = p
  File.close(f)

@unsafe
def log.write(m: Result<&1, &1, U32 & String, File>, +line: String) -> IO(Unit):
  match m:
    case Done{f}:
      do IO<Unit>:
        p : File & Result<&1, &1, U32 & String, Unit> <- File.write(f, line ++ "\n")
        log.closed(p)
    case Fail{e}:
      IO.pure(Unit, Unit{})

@unsafe
def log.to(out: Bool, +file: String, +line: String) -> IO(Unit):
  match out:
    case True{}:
      IO.print(line)
    case False{}:
      do IO<Unit>:
        m : Result<&1, &1, U32 & String, File> <- File.open(file, "a")
        log.write(m, line)

@unsafe
def log.stamp(+lg: Log, t: U32 & U32, +level: U32, +msg: String) -> IO(Unit):
  match lg:
    case Log{+file, lv, +pid, +role}:
      (secs, us) = t
      log.to(String.is_empty(file), file, T.log.line(pid, role, secs, us, level, msg))

@unsafe
def log.at(ok: Bool, +lg: Log, +level: U32, +msg: String) -> IO(Unit):
  match ok:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      do IO<Unit>:
        t : U32 & U32 <- IO.clock()
        log.stamp(lg, t, level, msg)

# a line at a level: 0 debug, 1 verbose, 2 notice, 3 warning
@unsafe
def log(+lg: Log, +level: U32, +msg: String) -> IO(Unit):
  log.at(U32.is_le(log.level(lg), level), lg, level, msg)

@unsafe
def log.lines(+lg: Log, +level: U32, ms: List<&2, String>) -> IO(Unit):
  match ms:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{m, rest}:
      do IO<Unit>:
        Unit <- log(lg, level, m)
        log.lines(lg, level, rest)

# a line as it is, with nothing before it (the logo)
@unsafe
def log.raw.at(ok: Bool, +lg: Log, +msg: String) -> IO(Unit):
  match ok:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      match lg:
        case Log{+file, lv, pid, role}:
          log.to(String.is_empty(file), file, msg)

# a warning, then the end of the start (exit code 1, nothing more said)
@unsafe
def log.die(-A: Type, +lg: Log, +msg: String) -> IO(A):
  do IO<A>:
    Unit <- log(lg, 3, msg)
    IO.die(A, 1, "")

# The append-only file
# --------------------
# With a file, the actor runs each batch with exec_log (aof.bend; after
# the hints of batch.bend, as log_batch), appends the entries of what it
# did to the file, and answers once they are written: synced to the disk
# first with always, synced each second by a syncer of their own with
# everysec (Redis's default), left to the system with no. A batch that
# changed nothing writes nothing, and the batches that wait together
# share one write and one sync. At start the server restores its
# database from the file (LAWS.bend: recover), once each entry is found to
# replay as the file means it (aof.bend: checked; a file with one that
# does not is refused, and left as it was). A file that ends inside an
# entry, cut by a crash in the middle of a write, is cut back to its last
# whole entry, as Redis does with aof-load-truncated, whatever its size;
# a file with anything else after its entries is refused, as Redis
# refuses it. The file opened to append, its directory is synced before
# the server serves, so that a new file's name is on the disk before the
# first write to it is acknowledged.

# how the file reaches the disk
type Sync is Data:
  Always{}
  EverySec{}
  Never{}

def sync_or(+m: String) -> Sync:
  Bool.pick(Sync, String.eq(m, "always"), Always{}, Bool.pick(Sync, String.eq(m, "no"), Never{}, EverySec{}))

def sync_note(s: Sync) -> String:
  match s:
    case Always{}:
      "always"
    case EverySec{}:
      "everysec"
    case Never{}:
      "no"

def aof_fail(e: U32 & String) -> String:
  (code, msg) = e
  "the append-only file failed: " ++ msg

# The actor takes a group of requests, as the actor without a file does
# (group_run, with the effects: S.run_log, session.bend): it runs their
# batches one after another, appends the effects of them all at once,
# syncs once, and answers them all at once, as Redis does in each turn of
# its loop. A group's effects are each batch's in front of the ones
# before reversed. The state is the server's, the databases, the database
# the file has selected (its last SELECT: an effect on another database
# is written after a SELECT of its own, aof.bend), the clients that wait,
# and the rewrite's (Rw). While a rewrite runs, the actor takes the
# requests that wait without waiting for one, as the actor without a
# file does (db_loop).
type St is Data:
  St{srv: S.Srv, ds: R.Ds, sel: Nat, ws: Waits, tx: Tx, pb: Ps, rw: Rw}

# whether the actor is not to block for a request: a rewrite runs, or an
# eviction is to go on (ps.evicting)
def st.runs(+st: St) -> Bool:
  match st:
    case St{srv, ds, sel, ws, tx, +pb, +rw}:
      Bool.or(rw.runs(rw), ps.evicting(pb))

def st.evicting(+st: St) -> Bool:
  match st:
    case St{srv, ds, sel, ws, tx, +pb, rw}:
      ps.evicting(pb)

@unsafe
def aof_loop(st: St, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  +x = st
  aof_wait(st.runs(x), x, f, sync, reqs)

@unsafe
def aof_wait(runs: Bool, st: St, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  match runs:
    case False{}:
      do IO<Unit>:
        m : Maybe<&1, Req> <- Chan.recv(Req, reqs)
        aof_more(st, f, sync, reqs, m)
    case True{}:
      do IO<Unit>:
        qs : List<&1, Req> <- Chan.drain(Req, reqs, group_max())
        aof_busy(qs, st, f, sync, reqs)

# while a rewrite runs and no request waits, a slice of it, then a turn
# of the event loop
@unsafe
def aof_busy(qs: List<&1, Req>, st: St, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  match qs:
    case Nil{}:
      +x = st
      aof_idle(st.evicting(x), x, f, sync, reqs)
    case Con{q, rest}:
      aof_take(q <> rest, st, f, sync, reqs)

# while no request waits: an eviction to go on with, as a group of no
# request (db_idle), else the rewrite's slice
@unsafe
def aof_idle(ev: Bool, st: St, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  match ev:
    case True{}:
      do IO<Unit>:
        Unit <- IO.sleep(0)
        aof_take(Nil{}, st, f, sync, reqs)
    case False{}:
      +x = st
      do IO<Unit>:
        t : U32 & U32 <- IO.clock()
        p : File & St <- aof_rw(st.idle(x, clock.ms(t)), x, f)
        Unit <- IO.sleep(0)
        aof_resume(p, sync, reqs)

def st.sel(+st: St) -> Nat:
  match st:
    case St{srv, ds, +sel, ws, tx, pb, rw}:
      sel

# the group's first request held in a list while the others are taken:
# a request travels flat, in as many registers as its widest form, and
# a function's registers are the widest function's
@unsafe
def aof_take(qs: List<&1, Req>, st: St, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  match st:
    case St{srv, ds, +sel, ws, tx, +pb, rw}:
      do IO<Unit>:
        more : List<&1, Req> <- Chan.drain(Req, reqs, group_max())
        t : U32 & U32 <- IO.clock()
        aof_mem(mem.need(pb), List.append(&1, Req, qs, more), t, srv, ds, ws, tx, pb, sel, rw, f, sync, reqs)

# a group of requests taken at t, its memory seen to (w: mem.need), as
# db_mem sees to it
@unsafe
def aof_mem(+w: Nat, qs: List<&1, Req>, t: U32 & U32, srv: S.Srv, ds: R.Ds, ws: Waits, tx: Tx, pb: Ps, +sel: Nat, rw: Rw, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  match w:
    case 0n:
      (a, b) = t
      +s0 = a
      +u0 = b
      aof_group(group_at(True{}, qs, s0, u0, Grp{Nil{}, Nil{}, srv, R.ds.at(clock.ms.of(s0, u0), ds), ws, Nil{}, tx, pb}), sel, rw, f, sync, reqs)
    case 1n:
      (a, b) = t
      +s0 = a
      +u0 = b
      aof_group(group_at(True{}, qs, s0, u0, Grp{Nil{}, Nil{}, srv, R.ds.at(clock.ms.of(s0, u0), ds), ws, Nil{}, tx, ps.mem(pb, 0n)}), sel, rw, f, sync, reqs)
    case _:
      (a, b) = t
      +s0 = a
      +u0 = b
      +w2 = rw
      +k = U32.sub(Clock.us(u0), u0)
      do IO<Unit>:
        h : Nat & Nat <- IO.heap()
        g : Grp <- mem.run(h, s0, u0, srv, R.ds.at(clock.ms.of(s0, u0), ds), ws, tx, pb, rw.runs(w2), rw.pid(w2))
        aof_group(group_from(True{}, qs, g, s0, k), sel, w2, f, sync, reqs)

@unsafe
def aof_more(st: St, f: File, +sync: Sync, +reqs: Chan(Req), m: Maybe<&1, Req>) -> IO(Unit):
  match m:
    case None{}:
      File.close(f)
    case Some{q}:
      aof_take([q], st, f, sync, reqs)

@unsafe
def aof_group(g: Grp, +sel: Nat, rw: Rw, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  match g:
    case Grp{outs, es, srv, ds, ws, up, tx, pb}:
      aof_put(List.reverse(&2, Sigma<&2, &2, Chan(Ans), _ => Ans>, outs), List.reverse(&2, A.Ent, es), St{srv, ds, sel, ws, tx, pb, rw}, f, sync, reqs)

# the bytes appended to the file, for INFO (and kept for the rewrite that
# runs, if one does), and the database the file has selected after them
def st.aof(st: St, +bytes: String, +sel: Nat) -> St:
  match st:
    case St{srv, ds, old, ws, tx, pb, rw}:
      St{S.srv.aof(srv, String.length(bytes)), ds, sel, ws, tx, pb, rw.keep(rw, bytes)}

@unsafe
def aof_write(outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, +es: List<&2, A.Ent>, st: St, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  +x = st
  +sel = st.sel(x)
  +bytes = A.encode(A.ents.args(es, sel))
  do IO<Unit>:
    p : File & Result<&1, &1, U32 & String, Unit> <- File.write_raw(f, bytes)
    aof_wrote(p, outs, st.aof(x, bytes, A.ents.sel(es, sel)), sync, reqs)

@unsafe
def aof_put(outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, st: St, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  match es:
    case Nil{}:
      aof_reply(outs, st, f, sync, reqs)
    case Con{e, more}:
      aof_write(outs, e <> more, st, f, sync, reqs)

@unsafe
def aof_wrote(p: File & Result<&1, &1, U32 & String, Unit>, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, st: St, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  (f, r) = p
  match r:
    case Fail{e}:
      IO.die(Unit, 1, aof_fail(e))
    case Done{u}:
      aof_sync(sync, f, outs, st, reqs)

@unsafe
def aof_synced(p: File & Result<&1, &1, U32 & String, Unit>, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, st: St, +reqs: Chan(Req)) -> IO(Unit):
  (f, r) = p
  match r:
    case Fail{e}:
      IO.die(Unit, 1, aof_fail(e))
    case Done{u}:
      aof_reply(outs, st, f, Always{}, reqs)

@unsafe
def aof_sync(+sync: Sync, f: File, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, st: St, +reqs: Chan(Req)) -> IO(Unit):
  match sync:
    case Always{}:
      do IO<Unit>:
        p : File & Result<&1, &1, U32 & String, Unit> <- File.sync(f)
        aof_synced(p, outs, st, reqs)
    case EverySec{}:
      aof_reply(outs, st, f, EverySec{}, reqs)
    case Never{}:
      aof_reply(outs, st, f, Never{}, reqs)

# the fds of the clients CLIENT KILL took, out of the state
def st.kills.of(p: List<&2, U32> & Ps, srv: S.Srv, ds: R.Ds, +sel: Nat, ws: Waits, tx: Tx, rw: Rw) -> List<&2, U32> & St:
  (ks, pb) = p
  (ks, St{srv, ds, sel, ws, tx, pb, rw})

def st.kills(st: St) -> List<&2, U32> & St:
  match st:
    case St{srv, ds, +sel, ws, tx, pb, rw}:
      st.kills.of(ps.kills(pb), srv, ds, sel, ws, tx, rw)

# what the actor does about a rewrite once the group is answered
# (rw.what)
def st.what(+st: St) -> Nat:
  match st:
    case St{+srv, +ds, sel, ws, tx, pb, +rw}:
      rw.what(rw, srv, R.ds.now(ds))

# the group's answers, after the sockets of the clients CLIENT KILL took
# are shut down (TCP.kill), as db_send does without the file; then the
# rewrite's step, if any
@unsafe
def aof_answer(p: List<&2, U32> & St, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  (ks, st) = p
  +x = st
  do IO<Unit>:
    Unit <- kill_all(ks)
    Unit <- Chan.send_all(Ans, outs)
    aof_after(st.what(x), x, f, sync, reqs)

@unsafe
def aof_after(w: Nat, st: St, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  match w:
    case 0n:
      aof_loop(st, f, sync, reqs)
    case _:
      do IO<Unit>:
        p : File & St <- aof_rw(w, st, f)
        aof_resume(p, sync, reqs)

@unsafe
def aof_resume(p: File & St, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  (f, st) = p
  aof_loop(st, f, sync, reqs)

# a step of the rewrite (rw.step), on the file's handle: the handle of the
# file after it (the new file's when it ends the rewrite)
@unsafe
def aof_rw(w: Nat, st: St, f: File) -> IO(File & St):
  match st:
    case St{srv, ds, sel, ws, tx, pb, rw}:
      do IO<File & St>:
        p : Maybe<&1, File> & Rx <- step.go(w, Rx{srv, ds, sel, rw}, Some{f})
        aof_rw.back(p, ws, tx, pb)

@unsafe
def aof_rw.back(p: Maybe<&1, File> & Rx, ws: Waits, tx: Tx, pb: Ps) -> IO(File & St):
  (m, x) = p
  match m x:
    case Some{f} Rx{srv, ds, sel, rw}:
      IO.pure(File & St, (f, St{srv, ds, sel, ws, tx, pb, rw}))
    case None{} _:
      IO.die(File & St, 1, "the append-only file has no handle after a step of its rewrite")

@unsafe
def aof_reply(outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, st: St, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  +x = st
  aof_down(st.down(x), outs, x, f, sync, reqs)

# the SHUTDOWN a group asked for, as db_down acts on it: the file synced
# before the server stops
def st.down(+st: St) -> Nat:
  match st:
    case St{srv, ds, sel, ws, tx, +pb, rw}:
      ps.down(pb)

# the saves a group asked for (rdb.saves), as db_down makes them (shut:
# a SHUTDOWN's save made among them, as the server stops without one of
# its own)
@unsafe
def aof_saves(+shut: Bool, +st: St) -> IO(S.Srv & Bool):
  match st:
    case St{+srv, +ds, sel, +ws, tx, pb, +rw}:
      rdb.saves(down.lg(srv, rw), srv, ds, Bool.or(S.srv.rdb.owed(srv), Bool.and(shut, S.srv.rdb.shut(srv))), rw.pid(rw))

# the clients that waited for the saves go on, as db_saved has them go on,
# their effects appended to the file (the group's answers, oldest first,
# are a group's again, newest first)
@unsafe
def aof_saved.go(p: S.Srv & Bool, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, ds: R.Ds, +sel: Nat, ws: Waits, tx: Tx, pb: Ps, rw: Rw, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  (srv, ok) = p
  aof_group(grp.saved(ok, List.reverse(&2, Sigma<&2, &2, Chan(Ans), _ => Ans>, outs), srv, ds, ws, tx, pb), sel, rw, f, sync, reqs)

@unsafe
def aof_saved(p: S.Srv & Bool, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, st: St, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  match st:
    case St{s0, ds, +sel, ws, tx, pb, rw}:
      aof_saved.go(p, outs, ds, sel, ws, tx, pb, rw, f, sync, reqs)

# the saves made, as db_saved has them: the clients that waited go on,
# or a SHUTDOWN's save is made now (aof_shut)
@unsafe
def aof_saved.if(shut: Bool, srv: S.Srv, +ok: Bool, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, st: St, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  match shut:
    case False{}:
      aof_saved((srv, ok), outs, st, f, sync, reqs)
    case True{}:
      aof_shut((S.srv.rdb.shutting(srv, False{}), ok), False{}, outs, st, f, sync, reqs)

@unsafe
def aof_stop(p: S.Srv & Bool, st: St, f: File) -> IO(Unit):
  match st:
    case St{s0, ds, sel, ws, tx, pb, +rw}:
      down.stop.p(p, rw, Some{f})

# SHUTDOWN with a save (down.final), as db_shut, the append-only file
# synced before the save, as finishShutdown syncs it
@unsafe
def aof_shut.end(ok: Bool, +force: Bool, +ok1: Bool, +srv: S.Srv, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, ds: R.Ds, +sel: Nat, ws: Waits, tx: Tx, pb: Ps, +rw: Rw, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  match ok force:
    case True{} _:
      down.exit(srv, down.lg(srv, rw))
    case False{} True{}:
      down.forced(srv, down.lg(srv, rw))
    case False{} False{}:
      do IO<Unit>:
        Unit <- down.cant(down.lg(srv, rw))
        aof_group(grp.saved(ok1, List.reverse(&2, Sigma<&2, &2, Chan(Ans), _ => Ans>, outs), S.srv.rw.stop(srv), ds, ws, tx, pb), sel, rw.with(rw, None{}), f, sync, reqs)

@unsafe
def aof_shut.go(p: S.Srv & Bool, +force: Bool, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, +ds: R.Ds, +sel: Nat, ws: Waits, tx: Tx, pb: Ps, +rw: Rw, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  (+srv, +ok1) = p
  +lg = down.lg(srv, rw)
  do IO<Unit>:
    Unit <- log(lg, 3, "User requested shutdown...")
    Unit <- down.rewrite(rw.runs(rw), lg, rw.tmp(rw))
    g : File <- down.sync.f(f, lg)
    ok : Bool <- down.final(lg, srv, ds, rw.pid(rw))
    aof_shut.end(ok, force, ok1, srv, outs, ds, sel, ws, tx, pb, rw, g, sync, reqs)

@unsafe
def aof_shut(p: S.Srv & Bool, +force: Bool, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, st: St, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  match st:
    case St{s0, ds, +sel, ws, tx, pb, rw}:
      aof_shut.go(p, force, outs, ds, sel, ws, tx, pb, rw, f, sync, reqs)

# a group that asked the shell for a save or a SHUTDOWN, as db_down acts
# on it
@unsafe
def aof_saves.of(p: S.Srv & Bool, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, st: St, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  (+srv, +ok) = p
  aof_saved.if(S.srv.rdb.shut(srv), srv, ok, outs, st, f, sync, reqs)

@unsafe
def aof_down(+d: Nat, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, st: St, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  match d:
    case 0n:
      aof_answer(st.kills(st), outs, f, sync, reqs)
    case 1n:
      +x = st
      do IO<Unit>:
        p : S.Srv & Bool <- aof_saves(False{}, x)
        aof_saves.of(p, outs, x, f, sync, reqs)
    case 2n:
      +x = st
      do IO<Unit>:
        p : S.Srv & Bool <- aof_saves(True{}, x)
        aof_stop(p, x, f)
    case _:
      +x = st
      do IO<Unit>:
        p : S.Srv & Bool <- aof_saves(False{}, x)
        aof_shut(p, True{}, outs, x, f, sync, reqs)

# everysec: the file synced each second, through a handle of its own,
# opened at its path each time: a rewrite puts a new file there
@unsafe
def sync_loop(+path: String) -> IO(Unit):
  do IO<Unit>:
    Unit <- IO.sleep(1000)
    m : Result<&1, &1, U32 & String, File> <- File.open(path, "a")
    sync_open(m, path)

@unsafe
def sync_open(m: Result<&1, &1, U32 & String, File>, +path: String) -> IO(Unit):
  match m:
    case Fail{e}:
      IO.die(Unit, 1, aof_fail(e))
    case Done{f}:
      do IO<Unit>:
        p : File & Result<&1, &1, U32 & String, Unit> <- File.sync(f)
        sync_next(p, path)

# a failed sync stops the server, as with always: the writes it
# acknowledged may not be on the disk, and the kernel may have dropped
# them, so a later sync that succeeds would not show it
@unsafe
def sync_next(p: File & Result<&1, &1, U32 & String, Unit>, +path: String) -> IO(Unit):
  (f, r) = p
  do IO<Unit>:
    Unit <- File.close(f)
    sync_after(r, path)

@unsafe
def sync_after(r: Result<&1, &1, U32 & String, Unit>, +path: String) -> IO(Unit):
  match r:
    case Fail{e}:
      IO.die(Unit, 1, aof_fail(e))
    case Done{u}:
      sync_loop(path)

@unsafe
def syncer(sync: Sync, +path: String) -> IO(Unit):
  match sync:
    case EverySec{}:
      IO.spawn(Unit, sync_loop(path))
    case Always{}:
      IO.pure(Unit, Unit{})
    case Never{}:
      IO.pure(Unit, Unit{})

# The rewrite of the append-only file
# ------------------------------------
# BGREWRITEAOF (or the cron: a rewrite scheduled in EXEC, or a file grown
# past auto-aof-rewrite-percentage of its size after its last rewrite)
# writes the append-only file again, as Redis 7.0.15 writes its base: the
# commands that make the databases as they are when it starts (aof.bend:
# The rewrite), to a temporary file next to the file
# (temp-rewriteaof-bg-<pid>.aof), then the entries appended to the file
# since it started; the temporary file synced, it is renamed onto the
# file and the directory synced, and the actor appends to the new file
# from then on. Redis forks a child that writes its memory as it was at
# the fork; BendKV's databases are values, so the actor keeps them as they
# are at the start (the snapshot: nothing copies them, the writes after
# it make new nodes where they change shared ones, as Redis's child's
# pages are copied on write) and writes them a slice at a time (the keys
# of a few dozen entries of a database: A.rw.slice), after the groups it
# answers and while no request waits (The steps: when, and how many),
# each then with a turn of the event loop for the connections; the
# temporary file is synced each 4 MB as it is written when
# aof-rewrite-incremental-fsync is yes, as Redis's child syncs its file,
# so that the last sync has little left to write. The entries appended
# meanwhile are kept (as Redis 6 kept them in its rewrite buffer; Redis 7
# writes them to a new file of its multi-part layout) and written after
# the snapshot. The file has one layout, Redis 6's single file, which
# Redis 7 reads as a file of Redis 6 (it moves it into its multi-part
# layout). With appendonly no the rewrite writes appendfilename all the
# same, as Redis does. A rewrite that fails (a file it cannot open, write
# or sync, a rename that fails) leaves the file as it was and removes the
# temporary one; one that fails after its rename (the directory's sync,
# the new file's opening) stops the server, as a failed write to the file
# does, since the file's name may not be on the disk.

# the directory of a path, with its last '/' ("" for a name alone)
def path.cut(s: String, +i: Nat, +at: Nat) -> Nat:
  match s:
    case SNil{}:
      at
    case SCon{Chr{+x}, t}:
      path.cut(t, 1n+i, Bool.pick(Nat, U32.is_eq(x, 47), 1n+i, at))

def path.dir(+p: String) -> String:
  String.take(p, path.cut(p, 0n, 0n))

# the temporary file of a rewrite: next to the file (a rename does not
# cross file systems), named as Redis names its child's
def tmp.path(+path: String, +pid: U32) -> String:
  path.dir(path) ++ "temp-rewriteaof-bg-" ++ U32.show(pid) ++ ".aof"

# strings kept newest first, as one, oldest first, before acc
def strs.cat(xs: List<&2, String>, acc: String) -> String:
  match xs:
    case Nil{}:
      acc
    case Con{x, rest}:
      strs.cat(rest, x ++ acc)

def err.msg(e: U32 & String) -> String:
  (code, msg) = e
  msg

# The rewrite that runs
# ---------------------

def run.tmp(+m: Maybe<&2, RwRun>) -> String:
  match m:
    case Some{RwRun{snap, +tmp, size, pend, pn, buf}}:
      tmp
    case None{}:
      ""

def run.size(+m: Maybe<&2, RwRun>) -> Nat:
  match m:
    case Some{RwRun{snap, tmp, +size, pend, pn, buf}}:
      size
    case None{}:
      0n

# the snapshot's bytes kept and not yet written; the same, then the
# entries appended to the file since the rewrite started
def run.pending(+m: Maybe<&2, RwRun>) -> String:
  match m:
    case Some{RwRun{snap, tmp, size, +pend, pn, buf}}:
      strs.cat(pend, "")
    case None{}:
      ""

def run.rest(+m: Maybe<&2, RwRun>) -> String:
  match m:
    case Some{RwRun{snap, tmp, size, +pend, pn, +buf}}:
      strs.cat(pend, strs.cat(buf, ""))
    case None{}:
      ""

# a slice of the snapshot taken: its commands encoded and kept
def run.sliced(sl: A.Slice, +tmp: String, +size: Nat, pend: List<&2, String>, +pn: Nat, buf: List<&2, String>) -> RwRun:
  match sl:
    case A.Slice{reqs, more}:
      +b = A.encode(reqs)
      RwRun{more, tmp, size, b <> pend, Nat.add(pn, String.length(b)), buf}

def run.slice(m: Maybe<&2, RwRun>, +want: Nat) -> Maybe<&2, RwRun>:
  match m:
    case Some{RwRun{Some{s}, tmp, size, pend, pn, buf}}:
      Some{run.sliced(A.rw.slice(s, want), tmp, size, pend, pn, buf)}
    case Some{RwRun{None{}, tmp, size, pend, pn, buf}}:
      Some{RwRun{None{}, tmp, size, pend, pn, buf}}
    case None{}:
      None{}

# what follows a slice: 0 nothing yet, 1 the bytes kept written (64 KB
# of them), 2 the rewrite's end (all of the snapshot is taken)
def run.next(+m: Maybe<&2, RwRun>) -> Nat:
  match m:
    case Some{RwRun{None{}, tmp, size, pend, pn, buf}}:
      2n
    case Some{RwRun{Some{s}, tmp, size, pend, +pn, buf}}:
      Bool.pick(Nat, Nat.is_le(65536n, pn), 1n, 0n)
    case None{}:
      0n

# the bytes kept written: n more in the temporary file
def run.flushed(m: Maybe<&2, RwRun>, +n: Nat) -> Maybe<&2, RwRun>:
  match m:
    case Some{RwRun{snap, tmp, size, pend, pn, buf}}:
      Some{RwRun{snap, tmp, Nat.add(size, n), Nil{}, 0n, buf}}
    case None{}:
      None{}

# A step's state
# --------------

def rw.path(+rw: Rw) -> String:
  match rw:
    case Rw{+path, aof, pid, cron, delay, until, last, run}:
      path
    case RwOf{+r}:
      rw.path(r)

def rw.pid(+rw: Rw) -> U32:
  match rw:
    case Rw{path, aof, +pid, cron, delay, until, last, run}:
      pid
    case RwOf{+r}:
      rw.pid(r)

def rw.tmp(+rw: Rw) -> String:
  match rw:
    case Rw{path, aof, pid, cron, delay, until, last, +run}:
      run.tmp(run)
    case RwOf{+r}:
      rw.tmp(r)

def rw.pending(+rw: Rw) -> String:
  match rw:
    case Rw{path, aof, pid, cron, delay, until, last, +run}:
      run.pending(run)
    case RwOf{+r}:
      rw.pending(r)

def rw.rest(+rw: Rw) -> String:
  match rw:
    case Rw{path, aof, pid, cron, delay, until, last, +run}:
      run.rest(run)
    case RwOf{+r}:
      rw.rest(r)

def rw.next(+rw: Rw) -> Nat:
  match rw:
    case Rw{path, aof, pid, cron, delay, until, last, +run}:
      run.next(run)
    case RwOf{+r}:
      rw.next(r)

def rw.size(+rw: Rw) -> Nat:
  match rw:
    case Rw{path, aof, pid, cron, delay, until, last, +run}:
      run.size(run)
    case RwOf{+r}:
      rw.size(r)

# SHUTDOWN's log and its exit (SHUTDOWN, above), with Redis's lines: the
# log of the server (its pid the rewrite's)
def down.lg(+srv: S.Srv, +rw: Rw) -> Log:
  log.up(log.of(S.srv.cfg(srv), rw.pid(rw)))

def st.lg(+st: St) -> Log:
  match st:
    case St{+srv, ds, sel, ws, tx, pb, +rw}:
      down.lg(srv, rw)

# a rewrite that runs: its temporary file removed, as Redis kills its
# child and removes its file
@unsafe
def down.rewrite(runs: Bool, +lg: Log, +tmp: String) -> IO(Unit):
  match runs:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      do IO<Unit>:
        Unit <- log(lg, 3, "There is a child rewriting the AOF. Killing it!")
        r : Result<&1, &1, U32 & String, Unit> <- File.unlink(tmp)
        IO.pure(Unit, Unit{})

# the append-only file synced, if the server appends to one: its handle
# after the sync (a sync that fails stops the server)
@unsafe
def down.synced(p: File & Result<&1, &1, U32 & String, Unit>) -> IO(File):
  (f, r) = p
  match r:
    case Fail{e}:
      IO.die(File, 1, aof_fail(e))
    case Done{u}:
      IO.pure(File, f)

@unsafe
def down.sync.f(f: File, +lg: Log) -> IO(File):
  do IO<File>:
    Unit <- log(lg, 2, "Calling fsync() on the AOF file.")
    p : File & Result<&1, &1, U32 & String, Unit> <- File.sync(f)
    down.synced(p)

@unsafe
def down.sync(m: Maybe<&1, File>, +lg: Log) -> IO(Unit):
  match m:
    case None{}:
      IO.pure(Unit, Unit{})
    case Some{f}:
      do IO<Unit>:
        g : File <- down.sync.f(f, lg)
        IO.pure(Unit, Unit{})

@unsafe
def down.pid(none: Bool, +lg: Log, +path: String) -> IO(Unit):
  match none:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      do IO<Unit>:
        Unit <- log(lg, 2, "Removing the pid file.")
        r : Result<&1, &1, U32 & String, Unit> <- File.unlink(path)
        IO.pure(Unit, Unit{})

# the end: the pid file removed, the log's last line, exit(0)
@unsafe
def down.exit(+srv: S.Srv, +lg: Log) -> IO(Unit):
  +pid = T.cfg(S.srv.cfg(srv), "pidfile")
  do IO<Unit>:
    Unit <- down.pid(String.is_empty(pid), lg, pid)
    Unit <- log(lg, 3, "BendKV is now ready to exit, bye bye...")
    IO.die(Unit, 0, "")

# SHUTDOWN without a save (ps.down 2): the request logged, a rewrite that
# runs stopped, the append-only file synced, and the end
@unsafe
def down.stop(+srv: S.Srv, +rw: Rw, m: Maybe<&1, File>) -> IO(Unit):
  +lg = down.lg(srv, rw)
  do IO<Unit>:
    Unit <- log(lg, 3, "User requested shutdown...")
    Unit <- down.rewrite(rw.runs(rw), lg, rw.tmp(rw))
    Unit <- down.sync(m, lg)
    down.exit(srv, lg)

# the saves the group asked for before its SHUTDOWN (rdb.saves), then
# SHUTDOWN without a save of its own
@unsafe
def down.stop.p(p: S.Srv & Bool, +rw: Rw, m: Maybe<&1, File>) -> IO(Unit):
  (srv, ok) = p
  down.stop(srv, rw, m)

# SHUTDOWN with a save (S.srv.rdb.shut, or ps.down 3 with FORCE), as
# finishShutdown runs it: the request logged, a rewrite that runs
# stopped, the append-only file synced (aof_shut), the RDB file saved
# ("Saving the final RDB snapshot before exiting."), then the end; a save
# that failed ends it all the same with FORCE ("Error trying to save the
# DB. Exit anyway."), else the server goes on (down.cant), the rewrite
# stopped
@unsafe
def down.final(+lg: Log, +srv: S.Srv, +ds: R.Ds, +pid: U32) -> IO(Bool):
  do IO<Bool>:
    Unit <- log(lg, 2, "Saving the final RDB snapshot before exiting.")
    rdb.save(lg, pid, S.srv.cfg(srv), rdb.fdbs(R.ds.list(ds)))

@unsafe
def down.forced(+srv: S.Srv, +lg: Log) -> IO(Unit):
  do IO<Unit>:
    Unit <- log(lg, 3, "Error trying to save the DB. Exit anyway.")
    down.exit(srv, lg)

@unsafe
def down.cant(+lg: Log) -> IO(Unit):
  do IO<Unit>:
    Unit <- log(lg, 3, "Error trying to save the DB, can't exit.")
    log(lg, 3, "Errors trying to shut down the server. Check the logs for more information.")

# the same state with run as the rewrite that runs; with a slice of its
# snapshot taken; with n more bytes in its temporary file
def rw.with(rw: Rw, run: Maybe<&2, RwRun>) -> Rw:
  match rw:
    case Rw{path, aof, pid, cron, delay, until, last, old}:
      Rw{path, aof, pid, cron, delay, until, last, run}
    case RwOf{r}:
      rw.with(r, run)

def rw.sliced(rw: Rw, +now: Nat, +want: Nat) -> Rw:
  match rw:
    case Rw{path, aof, pid, cron, delay, until, last, run}:
      Rw{path, aof, pid, cron, delay, until, now, run.slice(run, want)}
    case RwOf{r}:
      rw.sliced(r, now, want)

def rw.flushed(rw: Rw, +n: Nat) -> Rw:
  match rw:
    case Rw{path, aof, pid, cron, delay, until, last, run}:
      Rw{path, aof, pid, cron, delay, until, last, run.flushed(run, n)}
    case RwOf{r}:
      rw.flushed(r, n)

def rx.path(+x: Rx) -> String:
  match x:
    case Rx{srv, ds, sel, +rw}:
      rw.path(rw)

def rx.pid(+x: Rx) -> U32:
  match x:
    case Rx{srv, ds, sel, +rw}:
      rw.pid(rw)

def rx.tmp(+x: Rx) -> String:
  match x:
    case Rx{srv, ds, sel, +rw}:
      rw.tmp(rw)

def rx.pending(+x: Rx) -> String:
  match x:
    case Rx{srv, ds, sel, +rw}:
      rw.pending(rw)

def rx.rest(+x: Rx) -> String:
  match x:
    case Rx{srv, ds, sel, +rw}:
      rw.rest(rw)

def rx.next(+x: Rx) -> Nat:
  match x:
    case Rx{srv, ds, sel, +rw}:
      rw.next(rw)

# the temporary file a rewrite that starts writes
def rx.tmp0(+x: Rx) -> String:
  match x:
    case Rx{srv, ds, sel, +rw}:
      tmp.path(rw.path(rw), rw.pid(rw))

# the log, as the configuration has it now
def rx.lg(+x: Rx) -> Log:
  match x:
    case Rx{+srv, ds, sel, +rw}:
      log.up(log.of(S.srv.cfg(srv), rw.pid(rw)))

# a rewrite begun: the snapshot of the databases as they are, its
# temporary file (made empty), and the database the file has selected one
# that is not there, so that the file's next entry comes after a SELECT
# of its own (Redis's aof_selected_db = -1)
def rx.begin(x: Rx, +tmp: String) -> Rx:
  match x:
    case Rx{srv, +ds, sel, rw}:
      Rx{srv, ds, R.ds.count(ds), rw.with(rw, Some{RwRun{Some{A.snap.of(ds)}, tmp, 0n, Nil{}, 0n, Nil{}}})}

def rx.slice(x: Rx, +want: Nat) -> Rx:
  match x:
    case Rx{srv, +ds, sel, rw}:
      Rx{srv, ds, sel, rw.sliced(rw, R.ds.now(ds), want)}

# whether n more bytes in the temporary file pass a multiple of 4 MB, with
# aof-rewrite-incremental-fsync yes
def rx.autosync(+x: Rx, +n: Nat) -> Bool:
  match x:
    case Rx{+srv, ds, sel, +rw}:
      +size = rw.size(rw)
      Bool.and(Bool.not(Nat.is_eq(Nat.div(size, 4194304n), Nat.div(Nat.add(size, n), 4194304n))), String.eq(C.config.get_value(S.srv.cfg(srv), "aof-rewrite-incremental-fsync"), "yes"))

def rx.flushed(x: Rx, +n: Nat) -> Rx:
  match x:
    case Rx{srv, ds, sel, rw}:
      Rx{srv, ds, sel, rw.flushed(rw, n)}

# the rewrite ended well at ms, its last n bytes written: INFO's account
# (its time, and the file's size and base, the temporary file's size)
def rx.done(x: Rx, +n: Nat, +ms: Nat) -> Rx:
  match x:
    case Rx{srv, ds, sel, +rw}:
      Rx{S.srv.rw.done(srv, Nat.add(rw.size(rw), n), ms), ds, sel, rw.with(rw, None{})}

# it failed at ms: the file as it was
def rx.failed(x: Rx, +ms: Nat) -> Rx:
  match x:
    case Rx{srv, ds, sel, rw}:
      Rx{S.srv.rw.failed(srv, ms), ds, sel, rw.with(rw, None{})}

# a rewrite the cron starts, from the group's time
def rx.go(x: Rx) -> Rx:
  match x:
    case Rx{srv, +ds, sel, rw}:
      Rx{S.srv.rw.go(srv, R.ds.now(ds)), ds, sel, rw}

# The cron
# --------
# Each 100 ms of the actor's time it looks, as Redis's serverCron does (at
# hz 10) while no rewrite runs: a rewrite scheduled starts, and with
# appendonly yes a file past auto-aof-rewrite-min-size grown by
# auto-aof-rewrite-percentage (not 0) of its size after its last rewrite
# (or at the start) is rewritten, both unless the limit after failures
# holds.

# the file's growth since its last rewrite, in percent, as Redis measures
# it (a base of 0 as 1)
def rw.growth(+cur: Nat, +base: Nat) -> Nat:
  Nat.sub(Nat.div(Nat.mul(cur, 100n), Nat.max(base, 1n)), 100n)

# (the parameters looked up only as far as they are needed: a look of
# the actor without a file, or with a rewrite percentage of 0, reads
# none past the first)
def rw.auto.big(grown: Bool, +srv: S.Srv) -> Bool:
  match grown:
    case True{}:
      Bool.not(C.dec.le(Nat.show(S.srv.aof.size(srv)), C.config.get_value(S.srv.cfg(srv), "auto-aof-rewrite-min-size")))
    case False{}:
      False{}

def rw.auto.on(+srv: S.Srv) -> Bool:
  +perc = nat.of(C.config.get_value(S.srv.cfg(srv), "auto-aof-rewrite-percentage"))
  rw.auto.big(Bool.and(Nat.is_lt(0n, perc), Nat.is_le(perc, rw.growth(S.srv.aof.size(srv), S.srv.aof.base(srv)))), srv)

def rw.auto(aof: Bool, +srv: S.Srv) -> Bool:
  match aof:
    case True{}:
      rw.auto.on(srv)
    case False{}:
      False{}

# Redis's aofRewriteLimited, asked when the cron would start a rewrite:
# after three failures in a row the cron waits 1 minute from the look
# that finds them, then 2, 4 and so on up to 60 after each further one
# (each wait logged as it is set); fewer failures lift it. Its state: the
# next wait (minutes) and the second the wait holds until (0: none set).
type RwLim is Data:
  RwLim{held: Bool, delay: Nat, until: Nat, note: Nat}

def lim.set(+s: Nat, +delay: Nat) -> RwLim:
  +d = Bool.pick(Nat, Nat.is_eq(delay, 0n), 1n, Bool.pick(Nat, Nat.is_lt(60n, Nat.mul(delay, 2n)), 60n, Nat.mul(delay, 2n)))
  RwLim{True{}, d, Nat.add(s, Nat.mul(d, 60n)), d}

def lim.wait(+s: Nat, +delay: Nat, +until: Nat) -> RwLim:
  Bool.pick(RwLim, Nat.is_eq(until, 0n), lim.set(s, delay), Bool.pick(RwLim, Nat.is_lt(s, until), RwLim{True{}, delay, until, 0n}, RwLim{False{}, delay, 0n, 0n}))

def lim.of(few: Bool, +s: Nat, +delay: Nat, +until: Nat) -> RwLim:
  match few:
    case True{}:
      RwLim{False{}, 0n, 0n, 0n}
    case False{}:
      lim.wait(s, delay, until)

def lim.ask(want: Bool, +fails: Nat, +s: Nat, +delay: Nat, +until: Nat) -> RwLim:
  match want:
    case True{}:
      lim.of(Nat.is_lt(fails, 3n), s, delay, until)
    case False{}:
      RwLim{False{}, delay, until, 0n}

# the cron's look: the state after it (its next look 100 ms on), what it
# starts (0 nothing, 1 the rewrite scheduled, 2 one for the file's
# growth), the growth, and the limit's wait to log (minutes; 0 none)
type RwLook is Data:
  RwLook{x: Rx, go: Nat, grow: Nat, note: Nat}

def look.go(held: Bool, sched: Bool, auto: Bool) -> Nat:
  match held sched auto:
    case True{} _ _:
      0n
    case False{} True{} _:
      1n
    case False{} False{} True{}:
      2n
    case False{} False{} False{}:
      0n

def look.of(+sched: Bool, +auto: Bool, l: RwLim, +grow: Nat, srv: S.Srv, ds: R.Ds, +sel: Nat, path: String, +aof: Bool, +pid: U32, +now: Nat, +last: Nat, run: Maybe<&2, RwRun>) -> RwLook:
  match l:
    case RwLim{held, +delay, +until, +note}:
      RwLook{Rx{srv, ds, sel, Rw{path, aof, pid, Nat.add(now, 100n), delay, until, last, run}}, look.go(held, sched, auto), grow, note}

def rw.look(rw: Rw, +srv: S.Srv, +ds: R.Ds, +sel: Nat) -> RwLook:
  match rw:
    case Rw{path, +aof, +pid, cron, +delay, +until, +last, run}:
      +now = R.ds.now(ds)
      +sched = S.srv.rw.sched(srv)
      +grow = rw.growth(S.srv.aof.size(srv), S.srv.aof.base(srv))
      +auto = rw.auto(aof, srv)
      look.of(sched, auto, lim.ask(Bool.or(sched, auto), S.srv.rw.fails(srv), Nat.div(now, 1000n), delay, until), grow, srv, ds, sel, path, aof, pid, now, last, run)
    case RwOf{r}:
      rw.look(r, srv, ds, sel)

def rx.look(x: Rx) -> RwLook:
  match x:
    case Rx{+srv, +ds, +sel, rw}:
      rw.look(rw, srv, ds, sel)

# The steps
# ---------
# A step of the rewrite, on the file's handle (None with appendonly no):
# 1 its start, 2 its next slice after a group (64 entries; and its end
# after the last), 3 the cron's look (rw.what), 4 its next slice while no
# request waits (32 entries: a request that comes meanwhile waits for it,
# about a tenth of a millisecond), 5 the same once no group has run for
# 10 ms (256 entries: the server is idle, and the rewrite goes faster).

# the slice while no request waits, at ms (the clock), by how long ago the
# last group ran (step.go: 4 or 5)
def idle.step(+ds: R.Ds, +ms: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_le(Nat.add(R.ds.now(ds), 10n), ms), 5n, 4n)

def st.idle(+st: St, +ms: Nat) -> Nat:
  match st:
    case St{srv, +ds, sel, ws, tx, pb, rw}:
      idle.step(ds, ms)

@unsafe
def step.say(+x: Rx, +level: U32, +msg: String) -> IO(Unit):
  log(rx.lg(x), level, msg)

@unsafe
def step.go(w: Nat, x: Rx, f: Maybe<&1, File>) -> IO(Maybe<&1, File> & Rx):
  match w:
    case 1n:
      step.start(x, f)
    case 2n:
      step.slice(x, f, 64n)
    case 3n:
      step.cron(x, f)
    case 4n:
      step.slice(x, f, 32n)
    case _:
      step.slice(x, f, 256n)

# the start: the temporary file made empty, then the snapshot taken
@unsafe
def step.start(+x: Rx, f: Maybe<&1, File>) -> IO(Maybe<&1, File> & Rx):
  +tmp = rx.tmp0(x)
  do IO<Maybe<&1, File> & Rx>:
    m : Result<&1, &1, U32 & String, File> <- File.open(tmp, "w")
    step.opened(m, tmp, x, f)

@unsafe
def step.opened(m: Result<&1, &1, U32 & String, File>, +tmp: String, +x: Rx, f: Maybe<&1, File>) -> IO(Maybe<&1, File> & Rx):
  match m:
    case Done{t}:
      do IO<Maybe<&1, File> & Rx>:
        Unit <- File.close(t)
        Unit <- step.say(x, 2, "Background append only file rewriting started by pid " ++ U32.show(rx.pid(x)))
        return (f, rx.begin(x, tmp))
    case Fail{e}:
      step.fail(x, f, tmp, "Can't open the temporary file " ++ tmp ++ " for the AOF rewrite: " ++ err.msg(e))

# a slice of want entries, then what follows it
@unsafe
def step.slice(+x: Rx, f: Maybe<&1, File>, +want: Nat) -> IO(Maybe<&1, File> & Rx):
  +y = rx.slice(x, want)
  step.sliced(rx.next(y), y, f)

@unsafe
def step.sliced(w: Nat, +x: Rx, f: Maybe<&1, File>) -> IO(Maybe<&1, File> & Rx):
  match w:
    case 0n:
      IO.pure(Maybe<&1, File> & Rx, (f, x))
    case 1n:
      step.flush(x, f)
    case _:
      step.finish(x, f)

def step.wfail(+tmp: String, +msg: String) -> String:
  "Error writing the temporary file " ++ tmp ++ " of the AOF rewrite: " ++ msg

# the bytes kept appended to the temporary file
@unsafe
def step.flush(+x: Rx, f: Maybe<&1, File>) -> IO(Maybe<&1, File> & Rx):
  +tmp = rx.tmp(x)
  do IO<Maybe<&1, File> & Rx>:
    m : Result<&1, &1, U32 & String, File> <- File.open(tmp, "a")
    step.put(m, rx.pending(x), tmp, x, f)

@unsafe
def step.put(m: Result<&1, &1, U32 & String, File>, +bytes: String, +tmp: String, +x: Rx, f: Maybe<&1, File>) -> IO(Maybe<&1, File> & Rx):
  match m:
    case Fail{e}:
      step.fail(x, f, tmp, step.wfail(tmp, err.msg(e)))
    case Done{t}:
      do IO<Maybe<&1, File> & Rx>:
        p : File & Result<&1, &1, U32 & String, Unit> <- File.write_raw(t, bytes)
        step.put.done(p, String.length(bytes), tmp, x, f)

@unsafe
def step.put.done(p: File & Result<&1, &1, U32 & String, Unit>, +n: Nat, +tmp: String, +x: Rx, f: Maybe<&1, File>) -> IO(Maybe<&1, File> & Rx):
  (t, r) = p
  match r:
    case Fail{e}:
      do IO<Maybe<&1, File> & Rx>:
        Unit <- File.close(t)
        step.fail(x, f, tmp, step.wfail(tmp, err.msg(e)))
    case Done{u}:
      step.put.auto(rx.autosync(x, n), t, n, tmp, x, f)

# the temporary file synced each 4 MB written, with
# aof-rewrite-incremental-fsync yes (Redis's default: its child syncs so,
# REDIS_AUTOSYNC_BYTES), so that the sync before the rename, which the
# actor waits for, finds little to write
@unsafe
def step.put.auto(sync: Bool, t: File, +n: Nat, +tmp: String, +x: Rx, f: Maybe<&1, File>) -> IO(Maybe<&1, File> & Rx):
  match sync:
    case False{}:
      do IO<Maybe<&1, File> & Rx>:
        Unit <- File.close(t)
        return (f, rx.flushed(x, n))
    case True{}:
      do IO<Maybe<&1, File> & Rx>:
        q : File & Result<&1, &1, U32 & String, Unit> <- File.sync(t)
        step.put.synced(q, n, tmp, x, f)

@unsafe
def step.put.synced(q: File & Result<&1, &1, U32 & String, Unit>, +n: Nat, +tmp: String, +x: Rx, f: Maybe<&1, File>) -> IO(Maybe<&1, File> & Rx):
  (t, r) = q
  do IO<Maybe<&1, File> & Rx>:
    Unit <- File.close(t)
    step.put.end(r, n, tmp, x, f)

@unsafe
def step.put.end(r: Result<&1, &1, U32 & String, Unit>, +n: Nat, +tmp: String, +x: Rx, f: Maybe<&1, File>) -> IO(Maybe<&1, File> & Rx):
  match r:
    case Fail{e}:
      step.fail(x, f, tmp, "Error syncing the temporary file " ++ tmp ++ " of the AOF rewrite: " ++ err.msg(e))
    case Done{u}:
      IO.pure(Maybe<&1, File> & Rx, (f, rx.flushed(x, n)))

# the end (Redis's backgroundRewriteDoneHandler): the snapshot's last
# bytes, then the entries appended since the start, written to the
# temporary file and synced; the temporary file renamed onto the file
# (whoever opens it finds the old file or the new one, whole) and the
# directory synced; then the new file opened to append to and the old
# handle closed
@unsafe
def step.finish(+x: Rx, f: Maybe<&1, File>) -> IO(Maybe<&1, File> & Rx):
  +tmp = rx.tmp(x)
  do IO<Maybe<&1, File> & Rx>:
    m : Result<&1, &1, U32 & String, File> <- File.open(tmp, "a")
    step.fin(m, rx.rest(x), tmp, x, f)

@unsafe
def step.fin(m: Result<&1, &1, U32 & String, File>, +bytes: String, +tmp: String, +x: Rx, f: Maybe<&1, File>) -> IO(Maybe<&1, File> & Rx):
  match m:
    case Fail{e}:
      step.fail(x, f, tmp, step.wfail(tmp, err.msg(e)))
    case Done{t}:
      do IO<Maybe<&1, File> & Rx>:
        p : File & Result<&1, &1, U32 & String, Unit> <- File.write_raw(t, bytes)
        step.fin.wrote(p, String.length(bytes), tmp, x, f)

@unsafe
def step.fin.wrote(p: File & Result<&1, &1, U32 & String, Unit>, +n: Nat, +tmp: String, +x: Rx, f: Maybe<&1, File>) -> IO(Maybe<&1, File> & Rx):
  (t, r) = p
  match r:
    case Fail{e}:
      do IO<Maybe<&1, File> & Rx>:
        Unit <- File.close(t)
        step.fail(x, f, tmp, step.wfail(tmp, err.msg(e)))
    case Done{u}:
      do IO<Maybe<&1, File> & Rx>:
        q : File & Result<&1, &1, U32 & String, Unit> <- File.sync(t)
        step.fin.synced(q, n, tmp, x, f)

@unsafe
def step.fin.synced(q: File & Result<&1, &1, U32 & String, Unit>, +n: Nat, +tmp: String, +x: Rx, f: Maybe<&1, File>) -> IO(Maybe<&1, File> & Rx):
  (t, r) = q
  do IO<Maybe<&1, File> & Rx>:
    Unit <- File.close(t)
    step.fin.sync(r, n, tmp, x, f)

@unsafe
def step.fin.sync(r: Result<&1, &1, U32 & String, Unit>, +n: Nat, +tmp: String, +x: Rx, f: Maybe<&1, File>) -> IO(Maybe<&1, File> & Rx):
  match r:
    case Fail{e}:
      step.fail(x, f, tmp, "Error syncing the temporary file " ++ tmp ++ " of the AOF rewrite: " ++ err.msg(e))
    case Done{u}:
      do IO<Maybe<&1, File> & Rx>:
        q : Result<&1, &1, U32 & String, Unit> <- File.rename(tmp, rx.path(x))
        step.fin.renamed(q, n, tmp, x, f)

@unsafe
def step.fin.renamed(q: Result<&1, &1, U32 & String, Unit>, +n: Nat, +tmp: String, +x: Rx, f: Maybe<&1, File>) -> IO(Maybe<&1, File> & Rx):
  match q:
    case Fail{e}:
      step.fail(x, f, tmp, "Error trying to rename the temporary AOF file " ++ tmp ++ " into " ++ rx.path(x) ++ ": " ++ err.msg(e))
    case Done{u}:
      do IO<Maybe<&1, File> & Rx>:
        d : Result<&1, &1, U32 & String, Unit> <- File.sync_dir(rx.path(x))
        step.fin.dir(d, n, x, f)

@unsafe
def step.fin.dir(d: Result<&1, &1, U32 & String, Unit>, +n: Nat, +x: Rx, f: Maybe<&1, File>) -> IO(Maybe<&1, File> & Rx):
  match d:
    case Fail{e}:
      do IO<Maybe<&1, File> & Rx>:
        Unit <- step.say(x, 3, "The rewritten append-only file " ++ rx.path(x) ++ " is in place, but its directory failed to sync: " ++ err.msg(e))
        IO.die(Maybe<&1, File> & Rx, 1, "")
    case Done{u}:
      step.fin.open(f, n, x)

@unsafe
def step.fin.open(f: Maybe<&1, File>, +n: Nat, +x: Rx) -> IO(Maybe<&1, File> & Rx):
  match f:
    case None{}:
      step.done(None{}, n, x)
    case Some{old}:
      do IO<Maybe<&1, File> & Rx>:
        m : Result<&1, &1, U32 & String, File> <- File.open(rx.path(x), "a")
        step.fin.opened(m, old, n, x)

@unsafe
def step.fin.opened(m: Result<&1, &1, U32 & String, File>, old: File, +n: Nat, +x: Rx) -> IO(Maybe<&1, File> & Rx):
  match m:
    case Fail{e}:
      do IO<Maybe<&1, File> & Rx>:
        Unit <- step.say(x, 3, "Can't open the rewritten append-only file " ++ rx.path(x) ++ ": " ++ err.msg(e))
        IO.die(Maybe<&1, File> & Rx, 1, "")
    case Done{g}:
      do IO<Maybe<&1, File> & Rx>:
        Unit <- File.close(old)
        step.done(Some{g}, n, x)

@unsafe
def step.done(f: Maybe<&1, File>, +n: Nat, +x: Rx) -> IO(Maybe<&1, File> & Rx):
  do IO<Maybe<&1, File> & Rx>:
    t : U32 & U32 <- IO.clock()
    Unit <- step.say(x, 2, "Background AOF rewrite terminated with success")
    Unit <- step.say(x, 2, "Background AOF rewrite finished successfully")
    return (f, rx.done(x, n, clock.ms(t)))

# a rewrite that failed: why, logged; its temporary file removed; the
# file as it was
@unsafe
def step.fail(+x: Rx, f: Maybe<&1, File>, +tmp: String, +why: String) -> IO(Maybe<&1, File> & Rx):
  do IO<Maybe<&1, File> & Rx>:
    r : Result<&1, &1, U32 & String, Unit> <- File.unlink(tmp)
    t : U32 & U32 <- IO.clock()
    Unit <- step.say(x, 3, why)
    Unit <- step.say(x, 3, "Background AOF rewrite terminated with error")
    return (f, rx.failed(x, clock.ms(t)))

# the cron's look
@unsafe
def step.cron(x: Rx, f: Maybe<&1, File>) -> IO(Maybe<&1, File> & Rx):
  step.look(rx.look(x), f)

@unsafe
def step.note(note: Nat, +x: Rx) -> IO(Unit):
  match note:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+k:
      step.say(x, 3, "Background AOF rewrite has repeatedly failed and triggered the limit, will retry in " ++ Nat.show(1n+k) ++ " minutes")

@unsafe
def step.look(l: RwLook, f: Maybe<&1, File>) -> IO(Maybe<&1, File> & Rx):
  match l:
    case RwLook{+x, go, +grow, note}:
      do IO<Maybe<&1, File> & Rx>:
        Unit <- step.note(note, x)
        step.look.go(go, grow, x, f)

@unsafe
def step.look.go(go: Nat, +grow: Nat, +x: Rx, f: Maybe<&1, File>) -> IO(Maybe<&1, File> & Rx):
  match go:
    case 0n:
      IO.pure(Maybe<&1, File> & Rx, (f, x))
    case 1n:
      step.start(rx.go(x), f)
    case _:
      do IO<Maybe<&1, File> & Rx>:
        Unit <- step.say(x, 2, "Starting automatic rewriting of AOF on " ++ Nat.show(grow) ++ "% growth")
        step.start(rx.go(x), f)

# the file's handle a step of the actor without a file gives back (None)
@unsafe
def file.end(m: Maybe<&1, File>) -> IO(Unit):
  match m:
    case Some{f}:
      File.close(f)
    case None{}:
      IO.pure(Unit, Unit{})

# Restoring
# ---------

# the bytes of a file from where it is, read until a read comes back empty
@unsafe
def read_all(f: File, got: List<&2, String>) -> IO(File & String):
  do IO<File & String>:
    p : File & Result<&1, &1, U32 & String, String> <- File.read_raw(f, 16777216)
    read_more(p, got)

@unsafe
def read_more(p: File & Result<&1, &1, U32 & String, String>, got: List<&2, String>) -> IO(File & String):
  (f, r) = p
  match r:
    case Fail{e}:
      IO.die(File & String, 1, aof_fail(e))
    case Done{+x}:
      read_next(f, String.is_empty(x), x, got)

@unsafe
def read_next(f: File, eof: Bool, x: String, got: List<&2, String>) -> IO(File & String):
  match eof:
    case True{}:
      IO.pure(File & String, (f, glue(got, SNil{})))
    case False{}:
      read_all(f, x <> got)

# a leftover is an entry cut short when it starts as one and the request
# parser waits for more of it
def cut_short.of(b: P.Batch) -> Bool:
  match b:
    case P.Batch{reqs, tl, rest, err, need, raw}:
      Bool.and(List.is_empty(&2, B.Req, reqs), Maybe.is_none(&2, String, err))

def cut_short(s: String) -> Bool:
  match s:
    case SCon{'*', t}:
      cut_short.of(P.parse(SCon{'*', t}))
    case _:
      False{}

# the keys of the databases
def keys.all(dbs: List<&2, R.Db>) -> Nat:
  match dbs:
    case Nil{}:
      0n
    case Con{+d, rest}:
      Nat.add(R.db.n(d), keys.all(rest))

def restored(+n: Nat, +ds: R.Ds, +path: String) -> String:
  "BendKV restored " ++ Nat.show(keys.all(R.ds.list(ds))) ++ " keys from " ++ Nat.show(n) ++ " entries of " ++ path

@unsafe
def cut_done(+lg: Log, p: File & Result<&1, &1, U32 & String, Unit>, +path: String, +cut: Nat, +what: String) -> IO(Unit):
  (f, r) = p
  match r:
    case Fail{e}:
      IO.die(Unit, 1, aof_fail(e))
    case Done{u}:
      do IO<Unit>:
        Unit <- File.close(f)
        log(lg, 3, "BendKV cut " ++ Nat.show(cut) ++ " bytes of " ++ what ++ " cut short from the end of " ++ path)

# the file cut to its first keep bytes: File.truncate takes the Nat
# itself (a 64-bit word in the runtime), so a file of 4 GiB or more keeps
# all its whole entries, not keep modulo 2^32 of them
@unsafe
def cut_file(+lg: Log, +path: String, keep: Nat, +cut: Nat, +what: String) -> IO(Unit):
  do IO<Unit>:
    f : File <- IO.try(File, File.open(path, "a"))
    p : File & Result<&1, &1, U32 & String, Unit> <- File.truncate(f, keep)
    cut_done(lg, p, path, cut, what)

def uxeof(+path: String) -> String:
  "Unexpected end of file reading the append only file " ++ path ++ ". You can: 1) Make a backup of your AOF file, then use ./redis-check-aof --fix <filename>. 2) Alternatively you can set the 'aof-load-truncated' configuration option to yes and restart the server."

# a file that ends in an entry cut short is cut back to its last whole
# entry, unless aof-load-truncated is no: then it stops the start, as in
# Redis. What a start gives is the databases and the file's size.
@unsafe
def restore_cut(trunc: Bool, +lg: Log, +path: String, +size: Nat, +n: Nat, +ds: R.Ds, +rest: String) -> IO(R.Ds & Nat):
  match trunc:
    case True{}:
      do IO<R.Ds & Nat>:
        Unit <- cut_file(lg, path, Nat.sub(size, String.length(rest)), String.length(rest), "an entry")
        Unit <- log(lg, 2, restored(n, ds, path))
        return (ds, Nat.sub(size, String.length(rest)))
    case False{}:
      log.die(R.Ds & Nat, lg, uxeof(path))

# the databases of the entries, once the file is fit to append to: whole,
# or cut back to its last whole entry
@unsafe
def restore_fix(+lg: Log, +trunc: Bool, +path: String, +size: Nat, +n: Nat, +ds: R.Ds, +rest: String, whole: Bool, cut: Bool) -> IO(R.Ds & Nat):
  match whole cut:
    case True{} _:
      do IO<R.Ds & Nat>:
        Unit <- log(lg, 2, restored(n, ds, path))
        return (ds, size)
    case False{} True{}:
      restore_cut(trunc, lg, path, size, n, ds, rest)
    case False{} False{}:
      log.die(R.Ds & Nat, lg, "Bad file format reading the append only file " ++ path ++ ": no entry at byte " ++ Nat.show(Nat.sub(size, String.length(rest))))

# a file with an entry that does not replay as the file means it stops
# the start, with the entry's number and the byte it starts at (A.offset
# of the file read again: the text read first is let go before the
# replay, as before the check)
@unsafe
def restore_refused_at(+lg: Log, +path: String, +i: Nat, +why: String, p: File & String) -> IO(R.Ds & Nat):
  (f, +s) = p
  do IO<R.Ds & Nat>:
    Unit <- File.close(f)
    log.die(R.Ds & Nat, lg, "Bad command reading the append only file " ++ path ++ ": entry " ++ Nat.show(1n+i) ++ ", at byte " ++ Nat.show(A.offset(s, i)) ++ ": " ++ why)

@unsafe
def restore_refused(+lg: Log, +path: String, +i: Nat, +why: String) -> IO(R.Ds & Nat):
  do IO<R.Ds & Nat>:
    f : File <- IO.try(File, File.open(path, "r"))
    p : File & String <- read_all(f, Nil{})
    restore_refused_at(lg, path, i, why, p)

# the databases of the entries, when each replays as the file means it
# (aof.bend: checked); else the start stops at the first that does not,
# before the file is cut or opened to append: it is left as it was
@unsafe
def restore_checked(+lg: Log, +trunc: Bool, +path: String, +size: Nat, +n: Nat, r: A.Replay, +rest: String) -> IO(R.Ds & Nat):
  match r:
    case A.Replayed{+ds}:
      restore_fix(lg, trunc, path, size, n, ds, rest, String.is_empty(rest), cut_short(rest))
    case A.Refused{+i, +why}:
      restore_refused(lg, path, i, why)

# a file that ends inside a transaction (A.untx): the transaction is
# reverted and the file cut back to before its MULTI, as Redis does,
# unless aof-load-truncated is no: then it stops the start, as a file
# that ends in an entry cut short does; what follows the last whole
# entry must be an entry cut short, or nothing
@unsafe
def restore_reverted(+lg: Log, +path: String, +size: Nat, +keep: Nat, +n: Nat, r: A.Replay) -> IO(R.Ds & Nat):
  match r:
    case A.Replayed{+ds}:
      do IO<R.Ds & Nat>:
        Unit <- cut_file(lg, path, keep, Nat.sub(size, keep), "a transaction")
        Unit <- log(lg, 2, restored(n, ds, path))
        return (ds, keep)
    case A.Refused{+i, +why}:
      restore_refused(lg, path, i, why)

@unsafe
def restore_revert(trunc: Bool, +lg: Log, +path: String, +size: Nat, +more: Nat, +keep: List<&2, List<&2, String>>, +k: Nat) -> IO(R.Ds & Nat):
  match trunc:
    case True{}:
      do IO<R.Ds & Nat>:
        Unit <- log(lg, 3, "Revert incomplete MULTI/EXEC transaction in AOF file " ++ path)
        restore_reverted(lg, path, size, String.length(A.encode(keep)), k, A.checked(keep, more))
    case False{}:
      log.die(R.Ds & Nat, lg, uxeof(path))

@unsafe
def restore_tx(open: Bool, ok: Bool, +lg: Log, +trunc: Bool, +path: String, +size: Nat, +more: Nat, +reqs: List<&2, List<&2, String>>, +kept: List<&2, List<&2, String>>, +k: Nat, +rest: String) -> IO(R.Ds & Nat):
  match open ok:
    case False{} _:
      restore_checked(lg, trunc, path, size, List.length(&2, List<&2, String>, reqs), A.checked(reqs, more), rest)
    case True{} True{}:
      restore_revert(trunc, lg, path, size, more, kept, k)
    case True{} False{}:
      log.die(R.Ds & Nat, lg, "Bad file format reading the append only file " ++ path ++ ": no entry at byte " ++ Nat.show(Nat.sub(size, String.length(rest))))

@unsafe
def restore_load(+lg: Log, +trunc: Bool, +path: String, +size: Nat, +more: Nat, l: List<&2, List<&2, String>> & String) -> IO(R.Ds & Nat):
  (+reqs, +rest) = l
  +kept = A.untx(reqs)
  +k = List.length(&2, List<&2, String>, kept)
  restore_tx(Nat.is_lt(k, List.length(&2, List<&2, String>, reqs)), Bool.or(String.is_empty(rest), cut_short(rest)), lg, trunc, path, size, more, reqs, kept, k, rest)

@unsafe
def restore_read(+lg: Log, +trunc: Bool, +path: String, +more: Nat, p: File & String) -> IO(R.Ds & Nat):
  (f, +s) = p
  do IO<R.Ds & Nat>:
    Unit <- File.close(f)
    restore_load(lg, trunc, path, String.length(s), more, A.load(s))

# ENOENT: the one failure to open a file that means it is not there
def enoent() -> U32:
  2

def open_fail(+path: String, msg: String) -> String:
  "Can't open the append-only file " ++ path ++ ": " ++ msg

# a file not there is empty databases; any other failure to open it (no
# permission, an I/O error, no descriptor left) stops the start: serving
# empty databases would append to a file that holds others
@unsafe
def restore_none(none: Bool, +lg: Log, +path: String, +more: Nat, msg: String) -> IO(R.Ds & Nat):
  match none:
    case True{}:
      IO.pure(R.Ds & Nat, (R.ds.empty(more), 0n))
    case False{}:
      log.die(R.Ds & Nat, lg, open_fail(path, msg))

@unsafe
def restore_fail(+lg: Log, +path: String, +more: Nat, e: U32 & String) -> IO(R.Ds & Nat):
  (code, msg) = e
  restore_none(U32.is_eq(code, enoent()), lg, path, more, msg)

@unsafe
def restore_open(+lg: Log, +trunc: Bool, +path: String, +more: Nat, m: Result<&1, &1, U32 & String, File>) -> IO(R.Ds & Nat):
  match m:
    case Fail{e}:
      restore_fail(lg, path, more, e)
    case Done{f}:
      do IO<R.Ds & Nat>:
        p : File & String <- read_all(f, Nil{})
        restore_read(lg, trunc, path, more, p)

# the databases a file holds (1 + more of them), and the file's size;
# empty ones for a file not there yet
@unsafe
def restore(+lg: Log, +trunc: Bool, +path: String, +more: Nat) -> IO(R.Ds & Nat):
  do IO<R.Ds & Nat>:
    m : Result<&1, &1, U32 & String, File> <- File.open(path, "r")
    restore_open(lg, trunc, path, more, m)

# the actor appending to the file, on the databases the file held, with
# the database its last SELECT selected (the focus after its entries)
def st.new(+srv: S.Srv, ds: R.Ds, rw: Rw) -> St:
  +x = ds
  St{srv, x, R.ds.index(x), WaitNone{}, TxNone{}, ps.tune(ps.new(), srv), rw}

# the directory that holds the file synced, so that the file's name is on
# the disk before the first write to it is acknowledged: File.open may
# have just made the file, and a sync of the file does not make its
# entry in the directory durable (a crash could lose the name, and the
# next start find no file). It runs at each start, whether the start
# made the file or found it (one made by a start that stopped on this
# very failure may be there and not yet on the disk); a failure stops
# the start.
@unsafe
def dir_synced(r: Result<&1, &1, U32 & String, Unit>, +path: String, +lg: Log) -> IO(Unit):
  match r:
    case Done{u}:
      IO.pure(Unit, Unit{})
    case Fail{e}:
      (code, msg) = e
      log.die(Unit, lg, "Can't sync the directory of the append-only file " ++ path ++ ": " ++ msg)

@unsafe
def open_aof(+path: String, +sync: Sync, srv: S.Srv, ds: R.Ds, +lg: Log, +pid: U32) -> IO(Chan(Req)):
  do IO<Chan(Req)>:
    f : File <- IO.try(File, File.open(path, "a"))
    r : Result<&1, &1, U32 & String, Unit> <- File.sync_dir(path)
    Unit <- dir_synced(r, path, lg)
    Unit <- syncer(sync, path)
    +reqs : Chan(Req) <- Chan.new(Req, 1024)
    Unit <- IO.spawn(Unit, aof_loop(st.new(srv, ds, rw.new(path, True{}, pid)), f, sync, reqs))
    return reqs

# The RDB file on the disk
# ------------------------
# A save as rdbSave makes it (rdb.c): temp-<pid>.rdb opened in the
# directory (the server's: dir, which BendKV never leaves), the file
# written a slice of a database at a time (rdb.bend: The file), its
# CRC64 made as it goes with rdbchecksum yes, synced, closed, renamed onto
# dbfilename, the directory synced; then "DB saved on disk", and LASTSAVE
# the second it ended at. A failure logs Redis's line for it, removes the
# temporary file, and leaves the file as it was. At the start, without an
# append-only file, the file is loaded whole (as the append-only file
# is), as rdbLoad loads it (rdb.bend: Reading a file), with Redis's lines;
# a file that does not load stops the start; no file is empty databases.

# entries a slice of the file reads at most (a bucket is read whole)
def rdb.want() -> Nat:
  4096n

def rdb.tmp(+pid: U32) -> String:
  "temp-" ++ U32.show(pid) ++ ".rdb"

def clock.secs(t: U32 & U32) -> Nat:
  (secs, us) = t
  U32.to_nat(secs)

# the databases as the file writes them: each a trie lent, and its counts
def rdb.fdbs(dbs: List<&2, R.Db>) -> List<&2, D.FDb>:
  match dbs:
    case Nil{}:
      Nil{}
    case Con{+d, rest}:
      D.FDb{R.db.trie(d), R.db.n(d), R.db.x(d)} <> rdb.fdbs(rest)

# a write so far: on, with the CRC64 of its bytes, or stopped at an
# error (the step that failed, as Redis names it, and why)
type RdbW is Data:
  RdbOn{c: D.C}
  RdbErr{op: String, msg: String}

def rdb.crc(sum: Bool, +b: String, c: D.C) -> D.C:
  match sum:
    case True{}:
      D.crc.k(String.length(b), b, c)
    case False{}:
      c

@unsafe
def rdb.tailed(p: File & Result<&1, &1, U32 & String, Unit>, c: D.C) -> IO(File & RdbW):
  (f, r) = p
  match r:
    case Fail{e}:
      IO.pure(File & RdbW, (f, RdbErr{"rdbSaveRio", err.msg(e)}))
    case Done{u}:
      IO.pure(File & RdbW, (f, RdbOn{c}))

# the slices after the one written, then the file's end
@unsafe
def rdb.more(m: Maybe<&2, D.FW>, f: File, +sum: Bool, +c: D.C) -> IO(File & RdbW):
  match m:
    case Some{w}:
      rdb.write(f, D.file.slice(w, rdb.want()), sum, c)
    case None{}:
      do IO<File & RdbW>:
        p : File & Result<&1, &1, U32 & String, Unit> <- File.write_raw(f, D.file.tail(sum, c))
        rdb.tailed(p, c)

@unsafe
def rdb.wrote(p: File & Result<&1, &1, U32 & String, Unit>, more: Maybe<&2, D.FW>, +sum: Bool, c: D.C) -> IO(File & RdbW):
  (f, r) = p
  match r:
    case Fail{e}:
      IO.pure(File & RdbW, (f, RdbErr{"rdbSaveRio", err.msg(e)}))
    case Done{u}:
      rdb.more(more, f, sum, c)

@unsafe
def rdb.write(f: File, sl: D.FSl, +sum: Bool, c: D.C) -> IO(File & RdbW):
  match sl:
    case D.FSl{+b, more}:
      do IO<File & RdbW>:
        p : File & Result<&1, &1, U32 & String, Unit> <- File.write_raw(f, b)
        rdb.wrote(p, more, sum, rdb.crc(sum, b, c))

# a write error: Redis's line, the temporary file closed and removed
@unsafe
def rdb.werr(m: Maybe<&1, File>, +lg: Log, +tmp: String, +op: String, +msg: String) -> IO(Bool):
  do IO<Bool>:
    Unit <- log(lg, 3, "Write error saving DB on disk(" ++ op ++ "): " ++ msg)
    Unit <- file.end(m)
    r : Result<&1, &1, U32 & String, Unit> <- File.unlink(tmp)
    IO.pure(Bool, False{})

@unsafe
def rdb.dir.synced(r: Result<&1, &1, U32 & String, Unit>, +lg: Log, +tmp: String) -> IO(Bool):
  match r:
    case Fail{e}:
      rdb.werr(None{}, lg, tmp, "fsyncFileDir", err.msg(e))
    case Done{u}:
      do IO<Bool>:
        Unit <- log(lg, 2, "DB saved on disk")
        IO.pure(Bool, True{})

@unsafe
def rdb.renamed(r: Result<&1, &1, U32 & String, Unit>, +lg: Log, +tmp: String, +name: String) -> IO(Bool):
  match r:
    case Fail{e}:
      do IO<Bool>:
        c : Result<&1, &1, U32 & String, String> <- IO.cwd()
        Unit <- log(lg, 3, "Error moving temp DB file " ++ tmp ++ " on the final destination " ++ name ++ " (in server root dir " ++ env_or(c) ++ "): " ++ err.msg(e))
        u : Result<&1, &1, U32 & String, Unit> <- File.unlink(tmp)
        IO.pure(Bool, False{})
    case Done{u}:
      do IO<Bool>:
        d : Result<&1, &1, U32 & String, Unit> <- File.sync_dir(name)
        rdb.dir.synced(d, lg, tmp)

@unsafe
def rdb.synced(p: File & Result<&1, &1, U32 & String, Unit>, +lg: Log, +tmp: String, +name: String) -> IO(Bool):
  (f, r) = p
  match r:
    case Fail{e}:
      rdb.werr(Some{f}, lg, tmp, "fsync", err.msg(e))
    case Done{u}:
      do IO<Bool>:
        Unit <- File.close(f)
        q : Result<&1, &1, U32 & String, Unit> <- File.rename(tmp, name)
        rdb.renamed(q, lg, tmp, name)

@unsafe
def rdb.written(p: File & RdbW, +lg: Log, +tmp: String, +name: String) -> IO(Bool):
  (f, w) = p
  match w:
    case RdbErr{+op, +msg}:
      rdb.werr(Some{f}, lg, tmp, op, msg)
    case RdbOn{c}:
      do IO<Bool>:
        q : File & Result<&1, &1, U32 & String, Unit> <- File.sync(f)
        rdb.synced(q, lg, tmp, name)

@unsafe
def rdb.opened(m: Result<&1, &1, U32 & String, File>, +lg: Log, +tmp: String, +name: String, +sum: Bool, dbs: List<&2, D.FDb>) -> IO(Bool):
  match m:
    case Fail{e}:
      do IO<Bool>:
        c : Result<&1, &1, U32 & String, String> <- IO.cwd()
        Unit <- log(lg, 3, "Failed opening the temp RDB file " ++ tmp ++ " (in server root dir " ++ env_or(c) ++ ") for saving: " ++ err.msg(e))
        IO.pure(Bool, False{})
    case Done{f}:
      do IO<Bool>:
        t : U32 & U32 <- IO.clock()
        h : Nat & Nat <- IO.heap()
        p : File & RdbW <- rdb.write(f, D.FSl{D.file.head(clock.secs(t), Pair.fst(Nat, Nat, h)), Some{D.FW{dbs, 0n, None{}}}}, sum, D.C{0, 0})
        rdb.written(p, lg, tmp, name)

# the save of the databases dbs, as the parameters items say: whether it
# ended well
@unsafe
def rdb.save(+lg: Log, +pid: U32, +items: List<&2, C.CItem>, dbs: List<&2, D.FDb>) -> IO(Bool):
  +tmp = rdb.tmp(pid)
  do IO<Bool>:
    m : Result<&1, &1, U32 & String, File> <- File.open(tmp, "w")
    rdb.opened(m, lg, tmp, T.cfg(items, "dbfilename"), String.eq(T.cfg(items, "rdbchecksum"), "yes"), dbs)

# The saves a group asks for (ps.down), once it has run: FLUSHALL's, of
# the databases as it left them, empty, when it ran with save points
# (S.srv.rdb.flush); then SAVE's, of the databases as the group left them,
# when a client waits for one; each counted in the server's state, and
# whether SAVE's ended well (none: True)
@unsafe
def rdb.flush.save(on: Bool, +lg: Log, +srv: S.Srv, +pid: U32) -> IO(S.Srv):
  match on:
    case False{}:
      IO.pure(S.Srv, srv)
    case True{}:
      do IO<S.Srv>:
        ok : Bool <- rdb.save(lg, pid, S.srv.cfg(srv), Nil{})
        t : U32 & U32 <- IO.clock()
        IO.pure(S.Srv, S.srv.rdb.flushed(S.srv.rdb.saved(srv, ok, clock.secs(t)), False{}))

@unsafe
def rdb.save.want(want: Bool, +lg: Log, +srv: S.Srv, +ds: R.Ds, +pid: U32) -> IO(S.Srv & Bool):
  match want:
    case False{}:
      IO.pure(S.Srv & Bool, (srv, True{}))
    case True{}:
      do IO<S.Srv & Bool>:
        +ok : Bool <- rdb.save(lg, pid, S.srv.cfg(srv), rdb.fdbs(R.ds.list(ds)))
        t : U32 & U32 <- IO.clock()
        IO.pure(S.Srv & Bool, (S.srv.rdb.paid(S.srv.rdb.saved(srv, ok, clock.secs(t))), ok))

@unsafe
def rdb.saves(+lg: Log, +srv: S.Srv, +ds: R.Ds, +want: Bool, +pid: U32) -> IO(S.Srv & Bool):
  do IO<S.Srv & Bool>:
    s1 : S.Srv <- rdb.flush.save(S.srv.rdb.flush(srv), lg, srv, pid)
    rdb.save.want(want, lg, s1, ds, pid)

# A client that waits for a save (save.hold): in WAIT's way, of SAVE (1)
# or of SHUTDOWN (2); 0 any other
def save.kind(+b: S.Blk, +code: Nat) -> Nat:
  match b:
    case S.BlkWait{ms}:
      +k = R.code.key(code)
      Bool.pick(Nat, Nat.is_eq(k, R.stat.top(203n)), 1n, Bool.pick(Nat, Nat.is_eq(k, R.stat.top(187n)), 2n, 0n))
    case _:
      0n

def waits.saving(+ws: Waits) -> Bool:
  match ws:
    case WaitOn{id, back, c0, c1, +b, argv, +code, db, until, cmds, codes, av, rest}:
      Nat.is_lt(0n, save.kind(b, code))
    case WaitNone{}:
      False{}

# what a client that waited for a save is answered: SAVE OK, or -ERR when
# the save failed (saveCommand's shared.err); SHUTDOWN, whose save failed
# (its server stops otherwise), Redis's error
def saved.reply(+ok: Bool, +code: Nat) -> R.Reply:
  Bool.pick(R.Reply, Nat.is_eq(R.code.key(code), R.stat.top(187n)), R.RError{"ERR Errors trying to SHUTDOWN. Check logs."}, Bool.pick(R.Reply, ok, R.r_ok(), R.RError{"ERR"}))

# the clients that waited for a save taken out of the chain (hit: whether
# the first of ws is one), in the order they came, each answered (ok:
# whether SAVE's save ended well) as a client CLIENT UNBLOCK unblocks is
# (an error counted as the call's failure, the call's time ended), their
# batches to go on (up, newest first); the others kept in order (keep:
# those before, newest first)
def waits.saved(ws: Waits, hit: Bool, +ok: Bool, keep: Waits, up: List<&2, Up>, srv: S.Srv) -> Waits & (List<&2, Up> & S.Srv):
  match ws hit:
    case WaitNone{} _:
      (waits.rev(keep, WaitNone{}), (up, srv))
    case WaitOn{+id, back, +c0, c1, b, argv, +code, db, until, cmds, codes, av, +rest} True{}:
      +r = saved.reply(ok, code)
      waits.saved(rest, waits.saving(rest), ok, keep, Up{back, c1, S.put(S.say(S.conn.mode(c0), r), Nil{}), cmds, codes, av} <> up, S.srv.served(bg.errs(srv, code, r), id))
    case WaitOn{id, back, c0, c1, b, argv, code, db, until, cmds, codes, av, +rest} False{}:
      waits.saved(rest, waits.saving(rest), ok, WaitOn{id, back, c0, c1, b, argv, code, db, until, cmds, codes, av, keep}, up, srv)

def grp.saved.of(p: Waits & (List<&2, Up> & S.Srv), outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, ds: R.Ds, tx: Tx, pb: Ps) -> Grp:
  (+ws, q) = p
  (up, srv) = q
  grp.end(Grp{outs, Nil{}, waits.count(ws, srv), ds, ws, up, tx, ps.down.set(0n, pb)})

# once the shell has saved, the clients that waited go on: each
# answered, its batch on at the end of a group of no request (grp.end),
# whose answers go out after the group's (outs)
def grp.saved(+ok: Bool, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, srv: S.Srv, ds: R.Ds, +ws: Waits, tx: Tx, pb: Ps) -> Grp:
  grp.saved.of(waits.saved(ws, waits.saving(ws), ok, WaitNone{}, Nil{}, srv), outs, ds, tx, pb)

# The start: without an append-only file (and not in the short form), the
# file loaded, as loadDataFromDisk loads it: a file not there is empty
# databases; one that cannot be opened stops the start, as one that does
# not load does, with Redis's lines
def rdb.db(d: D.FDb) -> R.Db:
  match d:
    case D.FDb{t, n, x}:
      R.Db{t, n, x, 0n, None{}}

def rdb.dbs(xs: List<&2, D.FDb>) -> List<&2, R.Db>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{d, rest}:
      rdb.db(d) <> rdb.dbs(rest)

def rdb.ds(xs: List<&2, D.FDb>, +more: Nat) -> R.Ds:
  match xs:
    case Con{d, rest}:
      R.Ds{rdb.db(d), Nil{}, rdb.dbs(rest)}
    case Nil{}:
      R.ds.empty(more)

# ms as %.3f writes them in seconds
def secs3(+ms: Nat) -> String:
  +f = Nat.mod(ms, 1000n)
  Nat.show(Nat.div(ms, 1000n)) ++ "." ++ Bool.pick(String, Nat.is_lt(f, 100n), Bool.pick(String, Nat.is_lt(f, 10n), "00", "0"), "") ++ Nat.show(f)

@unsafe
def rdb.log(+lg: Log, ls: List<&2, D.FLine>) -> IO(Unit):
  match ls:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{D.FLine{+level, +msg}, rest}:
      do IO<Unit>:
        Unit <- log(lg, level, msg)
        rdb.log(lg, rest)

@unsafe
def rdb.loaded(d: D.FLd, +t0: Nat, +lg: Log, info: I.Info, +more: Nat) -> IO(R.Ds & I.Info):
  match d:
    case D.FFail{ls}:
      do IO<R.Ds & I.Info>:
        Unit <- rdb.log(lg, List.reverse(&2, D.FLine, ls))
        IO.die(R.Ds & I.Info, 1, "")
    case D.FOk{dbs, +ld, +ex, em, ls, sm}:
      do IO<R.Ds & I.Info>:
        Unit <- rdb.log(lg, List.reverse(&2, D.FLine, ls))
        t1 : Nat <- IO.now()
        Unit <- log(lg, 2, "DB loaded from disk: " ++ secs3(Nat.sub(t1, t0)) ++ " seconds")
        IO.pure(R.Ds & I.Info, (rdb.ds(dbs, more), I.info.rdb.loaded(info, ld, ex)))

# The file read in windows (issue #107): 1 MiB at a time, or as many bytes
# as the window held when a value runs past it (the window doubles), so
# that the start holds a window and the databases it fills, not the file
# (the heap gives no memory back: a file read whole stayed resident). A
# window's bytes the load has gone past go into the CRC64 before the next
# one is read; its last bytes, up to EOF, once the load is done.
def rdb.window() -> Nat:
  1048576n

def rdb.w.size(+left: Nat) -> U32:
  U32.from_nat(Nat.max(rdb.window(), left))

def rdb.w.crc(sum: Bool, +k: Nat, +w: String, c: D.C) -> D.C:
  match sum:
    case True{}:
      D.crc.k(k, w, c)
    case False{}:
      c

@unsafe
def rdb.w.more(eof: Bool, +x: String, f: File, r: D.FR, fail: D.FLd, c: D.C, +left: String, +base: Nat, +llen: Nat, +sum: Bool, +t0: Nat, +lg: Log, info: I.Info, +more: Nat) -> IO(R.Ds & I.Info):
  match eof:
    case True{}:
      do IO<R.Ds & I.Info>:
        Unit <- File.close(f)
        rdb.loaded(fail, t0, lg, info, more)
    case False{}:
      +xlen = String.length(x)
      +w = left ++ x
      rdb.w.went(D.file.next(r, w, Nat.add(llen, xlen), xlen), f, c, w, base, Nat.add(llen, xlen), sum, t0, lg, info, more)

@unsafe
def rdb.w.read(p: File & Result<&1, &1, U32 & String, String>, r: D.FR, fail: D.FLd, c: D.C, +left: String, +base: Nat, +llen: Nat, +sum: Bool, +t0: Nat, +lg: Log, info: I.Info, +more: Nat) -> IO(R.Ds & I.Info):
  (f, q) = p
  match q:
    case Fail{e}:
      log.die(R.Ds & I.Info, lg, "Short read or OOM loading DB. Unrecoverable error, aborting now.")
    case Done{+x}:
      rdb.w.more(String.is_empty(x), x, f, r, fail, c, left, base, llen, sum, t0, lg, info, more)

# the load s on the window w (wlen bytes, at the file's offset base), the
# CRC64 of the bytes before it c
@unsafe
def rdb.w.went(s: D.FS, f: File, c: D.C, +w: String, +base: Nat, +wlen: Nat, +sum: Bool, +t0: Nat, +lg: Log, info: I.Info, +more: Nat) -> IO(R.Ds & I.Info):
  match s:
    case D.FEnd{d}:
      do IO<R.Ds & I.Info>:
        Unit <- File.close(f)
        rdb.loaded(D.file.checked(d, c, w, base), t0, lg, info, more)
    case D.FMore{+r, fail}:
      +left = D.file.left(r)
      +llen = String.length(left)
      +used = Nat.sub(wlen, llen)
      do IO<R.Ds & I.Info>:
        p : File & Result<&1, &1, U32 & String, String> <- File.read_raw(f, rdb.w.size(llen))
        rdb.w.read(p, r, fail, rdb.w.crc(sum, used, w, c), left, Nat.add(base, used), llen, sum, t0, lg, info, more)
    case D.FGo{r}:
      do IO<R.Ds & I.Info>:
        Unit <- File.close(f)
        rdb.loaded(D.file.end(D.FGo{r}), t0, lg, info, more)

@unsafe
def rdb.w.first(p: File & Result<&1, &1, U32 & String, String>, +t0: Nat, +lg: Log, +items: List<&2, C.CItem>, info: I.Info, +more: Nat) -> IO(R.Ds & I.Info):
  (f, r) = p
  match r:
    case Fail{e}:
      log.die(R.Ds & I.Info, lg, "Short read or OOM loading DB. Unrecoverable error, aborting now.")
    case Done{+x}:
      +xlen = String.length(x)
      +sum = String.eq(T.cfg(items, "rdbchecksum"), "yes")
      do IO<R.Ds & I.Info>:
        t : U32 & U32 <- IO.clock()
        rdb.w.went(D.file.first(x, xlen, 1n+more, clock.ms(t), sum), f, D.C{0, 0}, x, 0n, xlen, sum, t0, lg, info, more)

@unsafe
def rdb.start.none(none: Bool, +msg: String, +lg: Log, info: I.Info, +more: Nat) -> IO(R.Ds & I.Info):
  match none:
    case True{}:
      IO.pure(R.Ds & I.Info, (R.ds.empty(more), info))
    case False{}:
      log.die(R.Ds & I.Info, lg, "Fatal error loading the DB: " ++ msg ++ ". Exiting.")

@unsafe
def rdb.start.open(m: Result<&1, &1, U32 & String, File>, +lg: Log, +items: List<&2, C.CItem>, info: I.Info, +more: Nat) -> IO(R.Ds & I.Info):
  match m:
    case Fail{e}:
      (code, msg) = e
      rdb.start.none(U32.is_eq(code, enoent()), msg, lg, info, more)
    case Done{f}:
      do IO<R.Ds & I.Info>:
        t0 : Nat <- IO.now()
        p : File & Result<&1, &1, U32 & String, String> <- File.read_raw(f, U32.from_nat(rdb.window()))
        rdb.w.first(p, t0, lg, items, info, more)

# the databases at the start (1 + more of them), and the server's facts
# with the keys the load loaded and found expired
@unsafe
def rdb.start(on: Bool, +lg: Log, +items: List<&2, C.CItem>, info: I.Info, +more: Nat) -> IO(R.Ds & I.Info):
  match on:
    case False{}:
      IO.pure(R.Ds & I.Info, (R.ds.empty(more), info))
    case True{}:
      do IO<R.Ds & I.Info>:
        m : Result<&1, &1, U32 & String, File> <- File.open(T.cfg(items, "dbfilename"), "r")
        rdb.start.open(m, lg, items, info, more)

# Serving
# -------
# The actor on its database (restored from the append-only file, with
# one), then a loop on each listener; then the server is ready.

# Redis's serverCron samples its rates every 100 ms: so does the cron,
# with a tick to the actor
@unsafe
def cron.next(ok: Bool, +reqs: Chan(Req)) -> IO(Unit):
  match ok:
    case True{}:
      cron(reqs)
    case False{}:
      IO.pure(Unit, Unit{})

@unsafe
def cron(+reqs: Chan(Req)) -> IO(Unit):
  do IO<Unit>:
    Unit <- IO.sleep(100)
    t : U32 & U32 <- IO.clock()
    ok : Bool <- Chan.send(Req, reqs, Tick{clock.ms(t)})
    cron.next(ok, reqs)

# Redis's warning, once it is ready, about a maxmemory under 1MB
@unsafe
def mm.warn.if(on: Bool, +lg: Log, +max: Nat) -> IO(Unit):
  match on:
    case True{}:
      log(lg, 3, "WARNING: You specified a maxmemory value that is less than 1MB (current value is " ++ Nat.show(max) ++ " bytes). Are you sure this is what you really want?")
    case False{}:
      IO.pure(Unit, Unit{})

@unsafe
def mm.warn(+lg: Log, +max: Nat) -> IO(Unit):
  mm.warn.if(Bool.and(Nat.is_lt(0n, max), Nat.is_lt(max, 1048576n)), lg, max)

@unsafe
def accept_all(ls: List<&1, Listener>, +reqs: Chan(Req), +post: Bool, +lg: Log, +tl: Chan(Tally), +items: List<&2, C.CItem>) -> IO(Unit):
  do IO<Unit>:
    Unit <- IO.spawn(Unit, cron(reqs))
    Unit <- accept_each(ls, reqs, post, tl)
    Unit <- log(lg, 2, "Ready to accept connections")
    mm.warn(lg, S.mm.get(items, "maxmemory"))

@unsafe
def serve.aof(p: R.Ds & Nat, +path: String, +sync: Sync, +items: List<&2, C.CItem>, info: I.Info, ls: List<&1, Listener>, +post: Bool, +lg: Log, +tl: Chan(Tally), +pid: U32) -> IO(Unit):
  (ds, +size) = p
  do IO<Unit>:
    +reqs : Chan(Req) <- open_aof(path, sync, S.srv_of(items, I.info.restored(info, size)), ds, lg, pid)
    accept_all(ls, reqs, post, lg, tl, items)

# the actor without a file, its Pub/Sub's state told of maxmemory
@unsafe
def db_start(+srv: S.Srv, ds: R.Ds, rw: Rw, +reqs: Chan(Req)) -> IO(Unit):
  db_loop(srv, ds, WaitNone{}, TxNone{}, ps.tune(ps.new(), srv), rw, reqs)

# the databases after the first (databases less one)
def dbs.more(+items: List<&2, C.CItem>) -> Nat:
  Nat.sub(S.srv.dbs.of(R.int_read(C.config.get_value(items, "databases"))), 1n)

# the actor without a file, on the databases the RDB file held (The RDB
# file on the disk: rdb.start)
@unsafe
def serve.db(p: R.Ds & I.Info, ls: List<&1, Listener>, +post: Bool, +items: List<&2, C.CItem>, +lg: Log, +tl: Chan(Tally), +pid: U32) -> IO(Unit):
  (ds, info) = p
  do IO<Unit>:
    +reqs : Chan(Req) <- Chan.new(Req, 1024)
    Unit <- IO.spawn(Unit, db_start(S.srv_of(items, info), ds, rw.new(T.cfg(items, "appendfilename"), False{}, pid), reqs))
    accept_all(ls, reqs, post, lg, tl, items)

# rdb: whether the RDB file is loaded when there is no append-only file
# (not in the short form)
@unsafe
def serve(aof: Maybe<&2, String>, ls: List<&1, Listener>, +post: Bool, +sync: Sync, +trunc: Bool, +items: List<&2, C.CItem>, info: I.Info, +lg: Log, +tl: Chan(Tally), +pid: U32, rdb: Bool) -> IO(Unit):
  match aof:
    case None{}:
      do IO<Unit>:
        p : R.Ds & I.Info <- rdb.start(rdb, lg, items, info, dbs.more(items))
        serve.db(p, ls, post, items, lg, tl, pid)
    case Some{+path}:
      do IO<Unit>:
        p : R.Ds & Nat <- restore(lg, trunc, path, dbs.more(items))
        serve.aof(p, path, sync, items, info, ls, post, lg, tl, pid)

# Listening
# ---------
# On each address of bind (startup.bend: T.addrs), as Redis's listenToPort
# does: an address that cannot be had for a reason Redis lets go is let go
# with a warning; any other failure stops the start, with the line Redis
# writes (and its test suite looks for, to try another port).

@unsafe
def log.if(c: Bool, +lg: Log, +level: U32, +msg: String) -> IO(Unit):
  match c:
    case True{}:
      log(lg, level, msg)
    case False{}:
      IO.pure(Unit, Unit{})

@unsafe
def listen.fail(skip: Bool, +port: U32, +lg: Log, ls: List<&1, Listener>) -> IO(List<&1, Listener>):
  match skip:
    case True{}:
      IO.pure(List<&1, Listener>, ls)
    case False{}:
      log.die(List<&1, Listener>, lg, "Failed listening on port " ++ U32.show(port) ++ " (TCP), aborting.")

@unsafe
def listen.got(m: Result<&1, &1, U32 & String, Listener>, +name: String, +port: U32, +lg: Log, ls: List<&1, Listener>) -> IO(List<&1, Listener>):
  match m:
    case Done{l}:
      IO.pure(List<&1, Listener>, l <> ls)
    case Fail{e}:
      (code, msg) = e
      do IO<List<&1, Listener>>:
        Unit <- log(lg, 3, "Warning: Could not create server TCP listening socket " ++ name ++ ":" ++ U32.show(port) ++ ": bind: " ++ msg)
        listen.fail(T.listen.skip(code), port, lg, ls)

@unsafe
def listen.host(none: Bool, +host: String, +name: String, +port: U32, +lg: Log, ls: List<&1, Listener>) -> IO(List<&1, Listener>):
  match none:
    case True{}:
      IO.pure(List<&1, Listener>, ls)
    case False{}:
      do IO<List<&1, Listener>>:
        m : Result<&1, &1, U32 & String, Listener> <- TCP.listen(host, port)
        listen.got(m, name, port, lg, ls)

@unsafe
def listen.addr(a: T.Addr, +port: U32, +lg: Log, ls: List<&1, Listener>) -> IO(List<&1, Listener>):
  match a:
    case T.Addr{+host, +name, +warn}:
      do IO<List<&1, Listener>>:
        Unit <- log.if(Bool.not(String.is_empty(warn)), lg, 3, warn)
        listen.host(String.is_empty(host), host, name, port, lg, ls)

@unsafe
def listen.all(xs: List<&2, T.Addr>, +port: U32, +lg: Log, ls: List<&1, Listener>) -> IO(List<&1, Listener>):
  match xs:
    case Nil{}:
      IO.pure(List<&1, Listener>, ls)
    case Con{a, rest}:
      do IO<List<&1, Listener>>:
        ls2 : List<&1, Listener> <- listen.addr(a, port, lg, ls)
        listen.all(rest, port, lg, ls2)

@unsafe
def listen.check(ls: List<&1, Listener>, +lg: Log) -> IO(List<&1, Listener>):
  match ls:
    case Nil{}:
      log.die(List<&1, Listener>, lg, "Configured to not listen anywhere, exiting.")
    case Con{l, rest}:
      IO.pure(List<&1, Listener>, Con{l, rest})

# no TCP for port 0
@unsafe
def listen.start(zero: Bool, xs: List<&2, T.Addr>, +port: U32, +lg: Log) -> IO(List<&1, Listener>):
  match zero:
    case True{}:
      listen.check(Nil{}, lg)
    case False{}:
      do IO<List<&1, Listener>>:
        ls : List<&1, Listener> <- listen.all(xs, port, lg, Nil{})
        listen.check(ls, lg)

# The start
# ---------

@unsafe
def pidfile.write(m: Result<&1, &1, U32 & String, File>, +pid: U32, +lg: Log) -> IO(Unit):
  match m:
    case Done{f}:
      do IO<Unit>:
        p : File & Result<&1, &1, U32 & String, Unit> <- File.write(f, U32.show(pid) ++ "\n")
        log.closed(p)
    case Fail{e}:
      (code, msg) = e
      log(lg, 3, "Failed to write PID file: " ++ msg)

# the pid in pidfile, when there is one
@unsafe
def pidfile(none: Bool, +path: String, +pid: U32, +lg: Log) -> IO(Unit):
  match none:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      do IO<Unit>:
        m : Result<&1, &1, U32 & String, File> <- File.open(path, "w")
        pidfile.write(m, pid, lg)

# BendKV has no modules: a module to load, or a module's parameter, stops
# the start, with the lines Redis writes when it cannot load one
@unsafe
def modules(load: Bool, cfg: Bool, +mod: String, +lg: Log) -> IO(Unit):
  match load cfg:
    case True{} _:
      do IO<Unit>:
        Unit <- log(lg, 3, "Module " ++ mod ++ " failed to load: BendKV has no modules")
        log.die(Unit, lg, "Can't load module from " ++ mod ++ ": server aborting")
    case False{} True{}:
      log.die(Unit, lg, "Module Configuration detected without loadmodule directive or no ApplyConfig call: aborting")
    case False{} False{}:
      IO.pure(Unit, Unit{})

@unsafe
def refuse.there(m: Result<&1, &1, U32 & String, File>, +msg: String, +lg: Log) -> IO(Unit):
  match m:
    case Done{f}:
      do IO<Unit>:
        Unit <- File.close(f)
        log.die(Unit, lg, msg)
    case Fail{e}:
      IO.pure(Unit, Unit{})

# a file there stops the start
@unsafe
def refuse.if_there(+path: String, +msg: String, +lg: Log) -> IO(Unit):
  do IO<Unit>:
    m : Result<&1, &1, U32 & String, File> <- File.open(path, "r")
    refuse.there(m, msg, lg)

# data BendKV cannot read stops the start, rather than a start without
# it: Redis 7's multi-part append-only file (its manifest), with
# appendonly yes (without, the RDB file loads: The RDB file on the disk)
@unsafe
def data.check(checks: Bool, +aof: Bool, +items: List<&2, C.CItem>, +lg: Log) -> IO(Unit):
  match checks aof:
    case True{} True{}:
      refuse.if_there(T.cfg(items, "appenddirname") ++ "/" ++ T.cfg(items, "appendfilename") ++ ".manifest",
        "BendKV cannot read Redis 7's multi-part append-only files yet: " ++ T.cfg(items, "dir") ++ "/" ++ T.cfg(items, "appenddirname") ++ " holds one", lg)
    case _ _:
      IO.pure(Unit, Unit{})

@unsafe
def start.refused(none: Bool, +msg: String, +lg: Log) -> IO(Unit):
  match none:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      log.die(Unit, lg, msg)

@unsafe
def start.sup(+k: Nat, +lg: Log) -> IO(Unit):
  match k:
    case 1n:
      log.die(Unit, lg, T.sup.msg(k))
    case 2n:
      log.die(Unit, lg, T.sup.msg(k))
    case 0n:
      IO.pure(Unit, Unit{})
    case _:
      log(lg, 3, T.sup.msg(k))

def env.set(r: Result<&1, &1, U32 & String, String>) -> Bool:
  match r:
    case Done{v}:
      True{}
    case Fail{e}:
      False{}

# supervised, as its environment shows it (upstart, systemd)
@unsafe
def start.sup.env(+items: List<&2, C.CItem>, +lg: Log) -> IO(Unit):
  do IO<Unit>:
    up : Result<&1, &1, U32 & String, String> <- IO.get_env("UPSTART_JOB")
    sd : Result<&1, &1, U32 & String, String> <- IO.get_env("NOTIFY_SOCKET")
    start.sup(T.sup.kind(T.cfg(items, "supervised"), env.set(up), env.set(sd)), lg)

# the server as the configuration asks: up to listening, then serving;
# checks: the data checks and the RDB file's load (not in the short
# form); mod and mcfg: what startup.bend found of modules
@unsafe
def run(+items: List<&2, C.CItem>, +post: Bool, +aof: Maybe<&2, String>, +sync: Sync, +bare: Bool, +prog: String, +pid: U32, +checks: Bool, +mod: String, +mcfg: Bool, +exe: String, +conf: String) -> IO(Unit):
  +lg = log.of(items, pid)
  +lm = log.up(log.of(items, pid))
  +port = port_or(T.cfg(items, "port"))
  do IO<Unit>:
    Unit <- start.sup.env(items, lg)
    Unit <- start.refused(String.is_empty(T.refusal(items, False{})), T.refusal(items, False{}), lg)
    Unit <- log(lg, 3, "oO0OoO0OoO0Oo BendKV is starting oO0OoO0OoO0Oo")
    Unit <- log(lg, 3, "BendKV version=" ++ T.version() ++ ", Redis 7.0.15 commands, bits=64, pid=" ++ U32.show(pid) ++ ", just started")
    Unit <- log(lg, 3, Bool.pick(String, bare, "Warning: no config file specified, using the default config. In order to specify a config file use " ++ prog ++ " /path/to/redis.conf", "Configuration loaded"))
    Unit <- log.lines(lm, 3, T.warnings(items))
    ls : List<&1, Listener> <- listen.start(U32.is_eq(port, 0), T.addrs(items), port, lm)
    Unit <- pidfile(String.is_empty(T.cfg(items, "pidfile")), T.cfg(items, "pidfile"), pid, lm)
    Unit <- log.raw.at(Bool.and(String.eq(T.cfg(items, "always-show-logo"), "yes"), U32.is_le(log.level(lg), 2)), lm, T.logo(T.cfg(items, "port"), pid))
    Unit <- log.if(Bool.not(String.eq(T.cfg(items, "always-show-logo"), "yes")), lm, 2, "Running mode=standalone, port=" ++ T.cfg(items, "port") ++ ".")
    Unit <- log(lm, 3, "Server initialized")
    Unit <- modules(Bool.not(String.is_empty(mod)), mcfg, mod, lm)
    Unit <- data.check(checks, Maybe.is_some(&2, String, aof), items, lm)
    +tl : Chan(Tally) <- Chan.new(Tally, 1)
    ok : Bool <- Chan.send(Tally, tl, Tally{0n, 0n})
    info : I.Info <- info.read(pid, exe, conf, tl)
    serve(aof, ls, post, sync, String.eq(T.cfg(items, "aof-load-truncated"), "yes"), items, info, lm, tl, pid, checks)

# The short form
# --------------
# bendkv PORT [post|send [FILE [always|everysec|no]]]: the port, whether
# replies are posted (post or send; by default, posted when the process
# may use two cores or more), the append-only file (any path) and how it
# is synced (everysec by default). It listens on 127.0.0.1.

def port_or(+p: String) -> U32:
  Maybe.default(&2, U32, U32.read(p), 6380)

def post_or(+m: String) -> Maybe<&2, Bool>:
  Bool.pick(Maybe<&2, Bool>, String.eq(m, "post"), Some{True{}}, Bool.pick(Maybe<&2, Bool>, String.eq(m, "send"), Some{False{}}, None{}))

# by default replies are posted when the writer can have a core of its
# own: the process may use two cores or more
def post_default(cpus: U32) -> Bool:
  U32.is_lt(1, cpus)

type Short is Data:
  Short{post: Maybe<&2, Bool>, aof: Maybe<&2, String>, sync: Sync}

def short.of(rest: List<&2, String>) -> Short:
  match rest:
    case Con{m, Con{f, Con{y, more}}}:
      Short{post_or(m), Some{f}, sync_or(y)}
    case Con{m, Con{f, more}}:
      Short{post_or(m), Some{f}, EverySec{}}
    case Con{m, more}:
      Short{post_or(m), None{}, EverySec{}}
    case Nil{}:
      Short{None{}, None{}, EverySec{}}

# the parameters the short form starts with: its port, its directory, and
# its append-only file and how it is synced
def aof_sets(aof: Maybe<&2, String>, +sync: Sync) -> List<&2, String>:
  match aof:
    case None{}:
      ["appendonly", "no", "appendfsync", sync_note(sync)]
    case Some{+path}:
      List.append(&2, String, ["appendonly", "yes", "appendfsync", sync_note(sync)], Bool.pick(List<&2, String>, C.text.path(path), Nil{}, ["appendfilename", path]))

def start_sets(+port: U32, dir: String, aof: Maybe<&2, String>, +sync: Sync) -> List<&2, String>:
  List.append(&2, String, ["port", U32.show(port), "dir", dir], aof_sets(aof, sync))

def env_or(r: Result<&1, &1, U32 & String, String>) -> String:
  match r:
    case Done{v}:
      v
    case Fail{e}:
      ""

@unsafe
def start.short(s: Short, +port: U32, cpus: U32, +prog: String, +pid: U32) -> IO(Unit):
  match s:
    case Short{post, +aof, +sync}:
      do IO<Unit>:
        +d : Result<&1, &1, U32 & String, String> <- IO.cwd()
        run(S.srv.puts(start_sets(port, env_or(d), aof, sync), C.config.table()), Maybe.default(&2, Bool, post, post_default(cpus)), aof, sync, False{}, prog, pid, False{}, "", False{}, T.abs(env_or(d), prog), "")

# The configuration
# -----------------
# Read as Redis reads it (startup.bend): the file, then the standard input
# with "-", then the options; a dir line changes the directory at once,
# and an include reads its file then and there.

# the bytes of a file, up to the first read that fails or comes back
# empty (Redis reads a directory as an empty file), 64 kB at a time
# (Linux refuses a read of more than 4 MB from /proc/sys)
@unsafe
def text.next(f: File, eof: Bool, x: String, got: List<&2, String>) -> IO(File & String):
  match eof:
    case True{}:
      IO.pure(File & String, (f, glue(got, SNil{})))
    case False{}:
      text.all(f, x <> got)

@unsafe
def text.more(p: File & Result<&1, &1, U32 & String, String>, got: List<&2, String>) -> IO(File & String):
  (f, r) = p
  match r:
    case Fail{e}:
      IO.pure(File & String, (f, glue(got, SNil{})))
    case Done{+x}:
      text.next(f, String.is_empty(x), x, got)

@unsafe
def text.all(f: File, got: List<&2, String>) -> IO(File & String):
  do IO<File & String>:
    p : File & Result<&1, &1, U32 & String, String> <- File.read_raw(f, 65536)
    text.more(p, got)

@unsafe
def text.closed(p: File & String) -> IO(String):
  (f, s) = p
  do IO<String>:
    Unit <- File.close(f)
    return s

# a configuration file's text; a file that cannot be opened stops the
# start, as in Redis
@unsafe
def conf.read(m: Result<&1, &1, U32 & String, File>, +path: String, +lg: Log) -> IO(String):
  match m:
    case Done{f}:
      do IO<String>:
        p : File & String <- text.all(f, Nil{})
        text.closed(p)
    case Fail{e}:
      (code, msg) = e
      log.die(String, lg, "Fatal error, can't open config file '" ++ path ++ "': " ++ msg)

@unsafe
def conf.stdin(stdin: Bool, +lg: Log) -> IO(String):
  match stdin:
    case False{}:
      IO.pure(String, "")
    case True{}:
      do IO<String>:
        Unit <- log(lg, 3, "Reading config from stdin")
        m : Result<&1, &1, U32 & String, File> <- File.open("/dev/stdin", "r")
        conf.read(m, "/dev/stdin", lg)

# the whole configuration: the file's text, the standard input's, and the
# options' lines after them
@unsafe
def conf.text(file: Maybe<&2, String>, stdin: Bool, +opts: String, +cwd: String, +lg: Log) -> IO(String):
  match file:
    case Some{f}:
      +path = T.abs(cwd, f)
      do IO<String>:
        m : Result<&1, &1, U32 & String, File> <- File.open(path, "r")
        body : String <- conf.read(m, path, lg)
        more : String <- conf.stdin(stdin, lg)
        return body ++ more ++ "\n" ++ opts
    case None{}:
      do IO<String>:
        more : String <- conf.stdin(stdin, lg)
        return more ++ "\n" ++ opts

# the checks at the end of a file, as Redis's: the log file must open,
# then startup.bend's (T.conf.end); after them a save line takes the save
# points away again (Redis is no longer reading a file)
@unsafe
def conf.fin.end(+st: T.Load) -> IO(T.Load):
  conf.fin.ok(T.conf.end(st), st)

@unsafe
def conf.fin.ok(e: Maybe<&2, String>, st: T.Load) -> IO(T.Load):
  match e:
    case Some{m}:
      IO.die(T.Load, 1, T.fatal.end(m))
    case None{}:
      IO.pure(T.Load, T.load.reading(st, False{}))

@unsafe
def conf.fin.log(m: Result<&1, &1, U32 & String, File>, st: T.Load) -> IO(T.Load):
  match m:
    case Done{f}:
      do IO<T.Load>:
        Unit <- File.close(f)
        conf.fin.end(st)
    case Fail{e}:
      (code, msg) = e
      IO.die(T.Load, 1, T.fatal.end("Can't open the log file: " ++ msg))

@unsafe
def conf.fin.if(none: Bool, +file: String, st: T.Load) -> IO(T.Load):
  match none:
    case True{}:
      conf.fin.end(st)
    case False{}:
      do IO<T.Load>:
        m : Result<&1, &1, U32 & String, File> <- File.open(file, "a")
        conf.fin.log(m, st)

@unsafe
def conf.fin(+st: T.Load) -> IO(T.Load):
  conf.fin.if(String.is_empty(T.cfg(T.load.items(st), "logfile")), T.cfg(T.load.items(st), "logfile"), st)

# a file's lines, from where they stop on: at a dir, the directory is
# changed (a failure is the line's error); at an include, its file is
# read, to its end, before the lines after it
@unsafe
def conf.next(nx: T.Next, +depth: Nat, +lg: Log) -> IO(T.Load):
  match nx:
    case T.NEnd{st}:
      conf.fin(st)
    case T.NErr{n, line, err}:
      IO.die(T.Load, 1, T.fatal(n, line, err))
    case T.NDir{+n, +line, path, st, rest}:
      do IO<T.Load>:
        r : Result<&1, &1, U32 & String, Unit> <- IO.chdir(path)
        conf.dir(r, n, line, st, rest, depth, lg)
    case T.NInc{+n, +line, +path, st, rest}:
      do IO<T.Load>:
        st2 : T.Load <- conf.include(T.conf.glob(path), n, line, path, st, depth, lg)
        conf.next(T.conf.resume(rest, st2, n), depth, lg)

@unsafe
def conf.dir(r: Result<&1, &1, U32 & String, Unit>, +n: Nat, +line: String, st: T.Load, rest: List<&2, String>, +depth: Nat, +lg: Log) -> IO(T.Load):
  match r:
    case Done{u}:
      conf.next(T.conf.resume(rest, st, n), depth, lg)
    case Fail{e}:
      (code, msg) = e
      IO.die(T.Load, 1, T.fatal(n, line, msg))

@unsafe
def conf.file(text: String, st: T.Load, depth: Nat, +lg: Log) -> IO(T.Load):
  conf.next(T.conf.start(text, st), depth, lg)

@unsafe
def conf.include.at(ok: Bool, +n: Nat, +line: String, +path: String, st: T.Load, +depth: Nat, +lg: Log) -> IO(T.Load):
  match ok:
    case False{}:
      IO.die(T.Load, 1, T.fatal(n, line, "BendKV stops at includes nested 64 deep"))
    case True{}:
      do IO<T.Load>:
        m : Result<&1, &1, U32 & String, File> <- File.open(path, "r")
        text : String <- conf.read(m, path, lg)
        conf.file(text, st, 1n+depth, lg)

@unsafe
def conf.include(glob: Bool, +n: Nat, +line: String, +path: String, st: T.Load, +depth: Nat, +lg: Log) -> IO(T.Load):
  match glob:
    case True{}:
      IO.die(T.Load, 1, T.fatal(n, line, "BendKV cannot include files by a pattern yet"))
    case False{}:
      conf.include.at(Nat.is_lt(depth, 64n), n, line, path, st, depth, lg)

# with no arguments at all, Redis reads no configuration
@unsafe
def conf.all(bare: Bool, text: String, +lg: Log) -> IO(T.Load):
  match bare:
    case True{}:
      IO.pure(T.Load, T.load.new(C.config.table()))
    case False{}:
      conf.file(text, T.load.new(C.config.table()), 0n, lg)

# replies posted or sent: by io-threads when it was given (1: from the
# event loop, as Redis with one thread; more: from a writer thread), else
# BendKV's default
def conf.post(io: Bool, +items: List<&2, C.CItem>, cpus: U32) -> Bool:
  match io:
    case True{}:
      Bool.not(String.eq(T.cfg(items, "io-threads"), "1"))
    case False{}:
      post_default(cpus)

def conf.aof(+items: List<&2, C.CItem>) -> Maybe<&2, String>:
  Bool.pick(Maybe<&2, String>, String.eq(T.cfg(items, "appendonly"), "yes"), Some{T.cfg(items, "appendfilename")}, None{})

@unsafe
def conf.ready(st: T.Load, +dir: String, cpus: U32, +bare: Bool, +prog: String, +pid: U32, +exe: String, +conf: String) -> IO(Unit):
  match st:
    case T.Load{+items, saved, reading, io, +mod, +mcfg}:
      run(C.items.put(items, "dir", dir), conf.post(io, items, cpus), conf.aof(items), sync_or(T.cfg(items, "appendfsync")), bare, prog, pid, True{}, mod, mcfg, exe, conf)

# the configuration file's absolute path, as Redis keeps it (INFO's
# config_file); "" for none
def conf.path(+file: Maybe<&2, String>, +cwd: String) -> String:
  match file:
    case Some{+f}:
      T.abs(cwd, f)
    case None{}:
      ""

@unsafe
def start.conf(+file: Maybe<&2, String>, stdin: Bool, +opts: String, +bare: Bool, cpus: U32, +prog: String, +pid: U32) -> IO(Unit):
  +lg = log.boot(pid)
  do IO<Unit>:
    +c : Result<&1, &1, U32 & String, String> <- IO.cwd()
    text : String <- conf.text(file, stdin, opts, env_or(c), lg)
    st : T.Load <- conf.all(bare, text, lg)
    d : Result<&1, &1, U32 & String, String> <- IO.cwd()
    conf.ready(st, env_or(d), cpus, bare, prog, pid, T.abs(env_or(c), prog), conf.path(file, env_or(c)))

# Main
# ----

@unsafe
def start(c: T.Cli, cpus: U32, +prog: String, +pid: U32) -> IO(Unit):
  match c:
    case T.CliVersion{}:
      IO.print(T.version.line())
    case T.CliHelp{}:
      IO.die(Unit, 1, T.usage())
    case T.CliSentinel{}:
      IO.die(Unit, 1, "BendKV has no sentinel mode")
    case T.CliShort{+port, rest}:
      start.short(short.of(rest), port_or(port), cpus, prog, pid)
    case T.CliConf{file, stdin, opts, bare}:
      start.conf(file, stdin, opts, bare, cpus, prog, pid)

@unsafe
def start.args(args: List<String>, cpus: U32, +pid: U32) -> IO(Unit):
  match args:
    case Con{prog, rest}:
      start(T.cli.of(T.utf8.all(rest)), cpus, prog, pid)
    case Nil{}:
      start(T.cli.of(Nil{}), cpus, "bendkv", pid)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    cpus : U32 <- IO.thread_count()
    pid : U32 <- IO.pid()
    start.args(args, cpus, pid)
