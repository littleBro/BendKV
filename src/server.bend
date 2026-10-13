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

# a batch from a connection in the state cn (B.Job: its commands, and
# the hashes of their keys, for the hints of batch.bend, with the words
# of the codes of INFO's statistics in their high twelve bits), the
# channel its answer goes back on, how many requests it has and the words
# of their codes (R.tl.add), and how many bytes it came in; the shell's
# facts (info.bend: Live), which a connection sends before a batch that
# asks INFO or CONFIG RESETSTAT; the cron's tick, at ms since 1970, for
# INFO's rates; a protocol error a connection answered, for errorstats;
# a connection closed while its client waited (Blocked clients), and
# the channel its Bye goes back on; or a connection closed, whose
# client's transaction and watched keys are forgotten (Transactions)
type Req is Data:
  Req{cn: S.Conn, job: B.Job, back: Chan(Ans), tl: U32, inb: Nat}
  Facts{live: I.Live}
  Tick{ms: Nat}
  Oops{}
  Gone{id: Nat, back: Chan(Ans)}
  Left{id: Nat}

# a batch's answer: its replies, encoded (none when CLIENT REPLY held
# them all back), and the connection's state after it; or the replies of
# the batch so far, its client waiting (Hold), more to come. On the same
# channel, a watch of the socket says that bytes came (Ready), and the
# actor that it holds nothing more for a client gone (Bye).
type Ans is Data:
  Ans{out: Maybe<&2, String>, cn: S.Conn}
  Hold{out: Maybe<&2, String>}
  Ready{}
  Bye{}

def ans_of(rs: List<&2, R.Reply>, cn: S.Conn) -> Ans:
  match rs:
    case Nil{}:
      Ans{None{}, cn}
    case Con{r, rest}:
      Ans{Some{P.encode_all(r <> rest)}, cn}

# the bytes of an answer's replies
def ans.len(+a: Ans) -> Nat:
  match a:
    case Ans{Some{+out}, cn}:
      String.length(out)
    case Hold{Some{+out}}:
      String.length(out)
    case _:
      0n

# The error replies of a batch of one code k, from its bytes: each reply
# of such a batch is a line (INCR's integers and errors, or the errors of
# calls the parser refused or failed), and an error reply's begins with
# '-'. Bytes without a '-', as most batches of INCR have, have none.
def ans.err(err: Bool, +out: String, +i: Nat, +j: Nat, +k: Nat, acc: List<&2, R.Erred>) -> List<&2, R.Erred>:
  match err:
    case True{}:
      R.Erred{k, String.slice(out, Nat.add(i, 1n), Nat.sub(Nat.sub(j, i), 2n))} <> acc
    case False{}:
      acc

def ans.errs.go(fuel: Nat, more: Bool, +out: String, +l: Nat, +i: Nat, +k: Nat, acc: List<&2, R.Erred>) -> List<&2, R.Erred>:
  match fuel more:
    case 1n+f True{}:
      +j = String.find(out, '\n', i)
      ans.errs.go(f, Nat.is_lt(Nat.add(j, 1n), l), out, l, Nat.add(j, 1n), k, ans.err(U32.is_eq(String.code_at(out, i), 45), out, i, j, k, acc))
    case _ _:
      acc

def ans.errs(+a: Ans, +k: Nat) -> List<&2, R.Erred>:
  match a:
    case Ans{Some{+out}, cn}:
      +l = String.length(out)
      ans.errs.go(l, Nat.is_lt(0n, l), out, l, 0n, k, Nil{})
    case _:
      Nil{}

# whether an answer of l bytes has a '-'
def ans.dash(+a: Ans, +l: Nat) -> Bool:
  match a:
    case Ans{Some{+out}, cn}:
      Nat.is_lt(String.find(out, '-', 0n), l)
    case _:
      False{}

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

# the message of an error the parser found (Bad, a session command's SBad)
def gen.bad(+c: R.Cmd) -> String:
  match c:
    case R.Bad{R.RError{+m}}:
      m
    case R.Own{R.SBad{R.RError{+m}}}:
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
      +refused = Nat.add(Nat.mul(Nat.div(code, 4n), 4n), 1n)
      Pre{refused, Some{[R.Erred{refused, "NOAUTH Authentication required."}]}}
    case True{}:
      gen.pre.ran(Nat.is_eq(Nat.mod(code, 4n), 0n), c, code)

# whether a call runs while its client's replies are held back (CLIENT
# REPLY OFF or SKIP): its reply counts all the same
def gen.muted(+ok: Bool, +code: Nat, +conn: S.Conn) -> Bool:
  Bool.and(ok, Bool.and(Nat.is_eq(Nat.mod(code, 4n), 0n), Bool.not(mute.on(S.conn.mode(conn)))))

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
# whose connection closes is forgotten (Gone), its batch dropped.
#
# The state of a batch and the clients that wait are types that hold
# themselves, which the compiler makes nodes of their own: they travel
# as one word each. Flat, a batch's state is some twenty words, and the
# widest function or result sets the registers of every function: the
# server's requests would pay for the blocking commands (section 3zp).

# the clients that wait, in the order they came, a chain of them: each
# with its id and the channel its answers go back on, its connection
# before the blocking command (whose mode says whether the reply goes
# out) and after it, the pop it waits to make and the code it counts as,
# its database, when its time is up (ms since 1970, 0 never), and the
# rest of its batch: the commands after the blocking one and their codes.
# A client taken out of the chain is a chain of one.
type Waits is Data:
  WaitNone{}
  WaitOn{id: Nat, back: Chan(Ans), c0: S.Conn, c1: S.Conn, b: S.Blk, code: Nat, db: Nat, until: Nat, cmds: List<&2, R.Cmd>, codes: List<&2, Nat>, rest: Waits}

# a client unblocked, whose batch goes on at the end of the group: the
# channel of its answers, its connection, its replies so far (newest
# first: the blocking command's, unless its replies are held back) and
# the rest of its batch
type Up is Data:
  Up{back: Chan(Ans), conn: S.Conn, rs: List<&2, R.Reply>, cmds: List<&2, R.Cmd>, codes: List<&2, Nat>}

# whether the first client of ws is the client of id n; whether its time
# is up at now; its pop, code and database
def waits.is(+n: Nat, +ws: Waits) -> Bool:
  match ws:
    case WaitOn{+id, back, c0, c1, b, code, db, until, cmds, codes, rest}:
      Nat.is_eq(id, n)
    case WaitNone{}:
      False{}

def waits.late(+now: Nat, +ws: Waits) -> Bool:
  match ws:
    case WaitOn{id, back, c0, c1, b, code, db, +until, cmds, codes, rest}:
      Bool.and(Nat.is_lt(0n, until), Nat.is_lt(until, now))
    case WaitNone{}:
      False{}

def waits.blk(+ws: Waits) -> S.Blk:
  match ws:
    case WaitOn{id, back, c0, c1, +b, code, db, until, cmds, codes, rest}:
      b
    case WaitNone{}:
      S.BlkBad{R.RNull{}}

def waits.db(+ws: Waits) -> Nat:
  match ws:
    case WaitOn{id, back, c0, c1, b, code, +db, until, cmds, codes, rest}:
      db
    case WaitNone{}:
      0n

def ups.is(+n: Nat, +us: List<&2, Up>) -> Bool:
  match us:
    case Con{Up{back, +conn, rs, cmds, codes}, rest}:
      Nat.is_eq(S.conn.id(conn), n)
    case _:
      False{}

# acc (newest first) put back in order before ws
def waits.rev(acc: Waits, ws: Waits) -> Waits:
  match acc:
    case WaitNone{}:
      ws
    case WaitOn{id, back, c0, c1, b, code, db, until, cmds, codes, rest}:
      waits.rev(rest, WaitOn{id, back, c0, c1, b, code, db, until, cmds, codes, ws})

# ws with w after its clients
def waits.add(ws: Waits, w: Waits) -> Waits:
  match ws:
    case WaitNone{}:
      w
    case WaitOn{id, back, c0, c1, b, code, db, until, cmds, codes, rest}:
      WaitOn{id, back, c0, c1, b, code, db, until, cmds, codes, waits.add(rest, w)}

# how many clients wait (on n), and how many of them have a time (on t)
def waits.len(ws: Waits, +n: Nat, +t: Nat) -> Nat & Nat:
  match ws:
    case WaitNone{}:
      (n, t)
    case WaitOn{id, back, c0, c1, b, code, db, +until, cmds, codes, rest}:
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
    case WaitOn{id, back, c0, c1, b, code, db, until, cmds, codes, rest}:
      waits.length(rest, 1n+n)

# the client of id n taken out of ws, a chain of one (none: no client of
# the id waits), and the others (hit: whether the first of ws is it; acc:
# those before it, newest first)
def waits.take(ws: Waits, hit: Bool, +n: Nat, acc: Waits) -> Waits & Waits:
  match ws hit:
    case WaitOn{id, back, c0, c1, b, code, db, until, cmds, codes, rest} True{}:
      (WaitOn{id, back, c0, c1, b, code, db, until, cmds, codes, WaitNone{}}, waits.rev(acc, rest))
    case WaitOn{id, back, c0, c1, b, code, db, until, cmds, codes, +rest} False{}:
      waits.take(rest, waits.is(n, rest), n, WaitOn{id, back, c0, c1, b, code, db, until, cmds, codes, acc})
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

# the clients whose time is up at now unblocked with a null array (late:
# whether the first of ws's is), in the order they came, the others kept
# in order (keep: those before, newest first)
def waits.expire(ws: Waits, late: Bool, +now: Nat, keep: Waits, up: List<&2, Up>) -> Waits & List<&2, Up>:
  match ws late:
    case WaitNone{} _:
      (waits.rev(keep, WaitNone{}), up)
    case WaitOn{id, back, +c0, c1, b, code, db, until, cmds, codes, +rest} True{}:
      waits.expire(rest, waits.late(now, rest), now, keep, Up{back, c1, S.put(S.say(S.conn.mode(c0), R.RNullA{}), Nil{}), cmds, codes} <> up)
    case WaitOn{id, back, c0, c1, b, code, db, until, cmds, codes, +rest} False{}:
      waits.expire(rest, waits.late(now, rest), now, WaitOn{id, back, c0, c1, b, code, db, until, cmds, codes, keep}, up)

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
    case WaitOn{id, back, c0, c1, +b, code, +db, until, cmds, codes, rest}:
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
    case WaitOn{id, back, c0, c1, b, code, db, until, cmds, codes, rest} Some{k}:
      Found{WaitOn{id, back, c0, c1, b, code, db, until, cmds, codes, WaitNone{}}, k, waits.rev(acc, rest)}
    case WaitOn{id, back, c0, c1, b, code, db, until, cmds, codes, +rest} None{}:
      waits.find(rest, waits.ready(ds, rest), ds, WaitOn{id, back, c0, c1, b, code, db, until, cmds, codes, acc})
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
# (cas: EXEC answers a null array), the commands queued (newest first)
# and their codes, and the keys it watches. While a batch runs, its
# client is the first of the chain, if it is in it (tx.front).
type Tx is Data:
  TxNone{}
  TxOn{id: Nat, multi: Bool, bad: Bool, cas: Bool, cmds: List<&2, R.Cmd>, codes: List<&2, Nat>, keys: List<&2, Wk>, rest: Tx}

def tx.on(+t: Tx) -> Bool:
  match t:
    case TxNone{}:
      False{}
    case TxOn{i, mu, bd, cs, qs, qc, wk, r}:
      True{}

# whether the first client of t is the client of id n, and whether it is
# in MULTI
def tx.is(+n: Nat, +t: Tx) -> Bool:
  match t:
    case TxOn{+i, mu, bd, cs, qs, qc, wk, r}:
      Nat.is_eq(i, n)
    case TxNone{}:
      False{}

def tx.multi(+n: Nat, +t: Tx) -> Bool:
  match t:
    case TxOn{+i, +mu, bd, cs, qs, qc, wk, r}:
      Bool.and(Nat.is_eq(i, n), mu)
    case TxNone{}:
      False{}

# acc (newest first) put back in order before t
def tx.rev(acc: Tx, t: Tx) -> Tx:
  match acc:
    case TxNone{}:
      t
    case TxOn{i, mu, bd, cs, qs, qc, wk, r}:
      tx.rev(r, TxOn{i, mu, bd, cs, qs, qc, wk, t})

# the client of id n taken out of t, a chain of one (none: it has no
# transaction and watches nothing), and the others (hit: whether the
# first of t is it; acc: those before it, newest first)
def tx.take(t: Tx, hit: Bool, +n: Nat, acc: Tx) -> Tx & Tx:
  match t hit:
    case TxOn{i, mu, bd, cs, qs, qc, wk, r} True{}:
      (TxOn{i, mu, bd, cs, qs, qc, wk, TxNone{}}, tx.rev(acc, r))
    case TxOn{i, mu, bd, cs, qs, qc, wk, +r} False{}:
      tx.take(r, tx.is(n, r), n, TxOn{i, mu, bd, cs, qs, qc, wk, acc})
    case TxNone{} _:
      (TxNone{}, tx.rev(acc, TxNone{}))

def tx.put(p: Tx & Tx) -> Tx:
  (one, others) = p
  match one:
    case TxOn{i, mu, bd, cs, qs, qc, wk, r}:
      TxOn{i, mu, bd, cs, qs, qc, wk, others}
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
    case True{} TxOn{i, mu, bd, cs, qs, qc, wk, r}:
      TxOn{i, True{}, bd, cs, qs, qc, wk, r}
    case _ t0:
      TxOn{n, True{}, False{}, False{}, Nil{}, Nil{}, Nil{}, t0}

def tx.open(+n: Nat, t: Tx) -> Tx:
  +x = t
  tx.open.of(tx.is(n, x), n, x)

# the transaction of the client first in t, ended: EXEC, DISCARD, RESET
def tx.close.of(mine: Bool, t: Tx) -> Tx:
  match mine t:
    case True{} TxOn{i, mu, bd, cs, qs, qc, wk, r}:
      r
    case _ t0:
      t0

def tx.close(+n: Nat, t: Tx) -> Tx:
  +x = t
  tx.close.of(tx.is(n, x), x)

# a command queued by the client first in t (in MULTI); none once the
# transaction is to fail, as Redis keeps none then
def tx.queued(skip: Bool, i: Nat, mu: Bool, bd: Bool, cs: Bool, qs: List<&2, R.Cmd>, qc: List<&2, Nat>, wk: List<&2, Wk>, r: Tx, c: R.Cmd, +code: Nat) -> Tx:
  match skip:
    case True{}:
      TxOn{i, mu, bd, cs, qs, qc, wk, r}
    case False{}:
      TxOn{i, mu, bd, cs, c <> qs, code <> qc, wk, r}

def tx.queue(c: R.Cmd, +code: Nat, t: Tx) -> Tx:
  match t:
    case TxOn{i, mu, +bd, +cs, qs, qc, wk, r}:
      tx.queued(Bool.or(bd, cs), i, mu, bd, cs, qs, qc, wk, r, c, code)
    case TxNone{}:
      TxNone{}

# the transaction of the client first in t flagged: a command refused
# while it queued
def tx.bad(t: Tx) -> Tx:
  match t:
    case TxOn{i, mu, bd, cs, qs, qc, wk, r}:
      TxOn{i, mu, True{}, cs, qs, qc, wk, r}
    case TxNone{}:
      TxNone{}

# UNWATCH of the client first in t: its keys and its touch forgotten
def tx.unwatch.of(mine: Bool, t: Tx) -> Tx:
  match mine t:
    case True{} TxOn{i, True{}, bd, cs, qs, qc, wk, r}:
      TxOn{i, True{}, bd, False{}, qs, qc, Nil{}, r}
    case True{} TxOn{i, False{}, bd, cs, qs, qc, wk, r}:
      r
    case _ t0:
      t0

def tx.unwatch(+n: Nat, t: Tx) -> Tx:
  +x = t
  tx.unwatch.of(tx.is(n, x), x)

# k's entry in database j of ds (there at now or not)
def ds.entry.of(m: Maybe<&2, R.Db>, +k: String) -> Maybe<&2, KV.Item<KV.Val>>:
  match m:
    case Some{+d}:
      R.db.entry(d, k)
    case None{}:
      None{}

def ds.entry.at(focus: Bool, +j: Nat, +k: String, +ds: R.Ds) -> Maybe<&2, KV.Item<KV.Val>>:
  match focus:
    case True{}:
      R.db.entry(R.ds.focused(ds), k)
    case False{}:
      +xs = R.ds.list(ds)
      ds.entry.of(R.ds.nth(j, xs), k)

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
    case True{} TxOn{i, mu, bd, True{}, qs, qc, wk, r}:
      TxOn{i, mu, bd, True{}, qs, qc, wk, r}
    case True{} TxOn{i, mu, bd, False{}, qs, qc, wk, r}:
      TxOn{i, mu, bd, False{}, qs, qc, wk.add(ks, j, ds, R.ds.now(ds), wk), r}
    case _ t0:
      TxOn{n, False{}, False{}, False{}, Nil{}, Nil{}, wk.add(ks, j, ds, R.ds.now(ds), Nil{}), t0}

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
def tx.touched(m: Maybe<&2, List<&2, Wk>>, i: Nat, mu: Bool, bd: Bool, cs: Bool, qs: List<&2, R.Cmd>, qc: List<&2, Nat>, r: Tx) -> Tx:
  match m:
    case Some{ks}:
      TxOn{i, mu, bd, cs, qs, qc, ks, r}
    case None{}:
      TxOn{i, mu, bd, True{}, qs, qc, Nil{}, r}

def tx.touch(t: Tx, +j: Nat, +k: String, +here: Bool) -> Tx:
  match t:
    case TxNone{}:
      TxNone{}
    case TxOn{i, mu, bd, cs, qs, qc, wk, r}:
      tx.touched(wk.touch(wk, j, k, here), i, mu, bd, cs, qs, qc, tx.touch(r, j, k, here))

# whether a client of t watches key k of database j
def tx.watched(+j: Nat, +k: String, +t: Tx) -> Bool:
  match t:
    case TxNone{}:
      False{}
    case TxOn{i, mu, bd, cs, qs, qc, +wk, +r}:
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
    case TxOn{i, mu, bd, cs, qs, qc, wk, r}:
      tx.touched(wk.flush(wk, all, j, pre), i, mu, bd, cs, qs, qc, tx.flush(r, all, j, pre))

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
    case TxOn{i, mu, bd, cs, qs, qc, wk, r}:
      tx.touched(wk.swap(wk, a, b, pre), i, mu, bd, cs, qs, qc, tx.swap(r, a, b, pre))

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

# a batch on the general way so far: its replies (newest first), the
# effects so far (newest first; the server without an append-only file
# drops them), the connection, the server, the databases, the clients
# that wait and those unblocked meanwhile (newest first), and the
# clients with a transaction or watched keys; or a batch whose client
# now waits (LHeld: the last of the clients that wait)
type LRun is Data:
  LRun{rs: List<&2, R.Reply>, es: List<&2, A.Ent>, conn: S.Conn, srv: S.Srv, ds: R.Ds, ws: Waits, up: List<&2, Up>, tx: Tx}
  LHeld{g: LRun}

# a group so far: its answers (newest first), the effects of its batches
# (newest first), the server's state, the databases, the clients that
# wait and those unblocked meanwhile, whose batches go on at its end
# (newest first), and the clients with a transaction or watched keys
type Grp is Data:
  Grp{outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, srv: S.Srv, ds: R.Ds, ws: Waits, up: List<&2, Up>, tx: Tx}

def bg.done(d: S.Logged, p: Pre, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, ws: Waits, up: List<&2, Up>, tx: Tx) -> LRun:
  match d p:
    case S.Logged{+rs1, e, conn, srv, ds} Pre{+code, xs}:
      +ys = gen.errs(xs, rs1, code)
      LRun{List.reverse.go(&2, R.Reply, rs1, rs), A.ents.onto(e, es), conn, gen.count(srv, code, ys), ds, ws, up, tx}

# A call that runs while its client's replies are held back has its reply
# counted as Redis has it. A command of the database runs with them on,
# for its reply, which is counted and dropped (its client gets none), the
# connection after it being the one its run with them held back gives
# (S.next_conn: the replies are all that the mode changes); its run is its
# only one, so the databases go on unshared. A command of the connection
# or of the server runs as it is (CLIENT REPLY ON and RESET answer all the
# same), its reply as Redis has it taken from S.own_reply before.
def bg.held(d: S.Logged, conn: S.Conn, +code: Nat, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, ws: Waits, up: List<&2, Up>, tx: Tx) -> LRun:
  match d:
    case S.Logged{+rs1, e, c1, srv, ds}:
      LRun{rs, A.ents.onto(e, es), conn, gen.count(srv, code, R.errs.zip(rs1, [code], Nil{})), ds, ws, up, tx}

def bg.held.k(+k: S.Role, +c: R.Cmd, +code: Nat, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, +conn: S.Conn, +srv: S.Srv, ds: R.Ds, ws: Waits, up: List<&2, Up>, tx: Tx) -> LRun:
  match k:
    case S.KSess{+o}:
      +d = ds
      +p = gen.pre.own(o, code, conn, srv, d)
      bg.done(S.run_log(conn, srv, B.Mixed{[c], Nil{}}, d), p, rs, es, ws, up, tx)
    case _:
      bg.held(S.run_log(S.conn.on(conn), srv, B.Mixed{[c], Nil{}}, ds), S.next_conn(False{}, c, conn, srv), code, rs, es, ws, up, tx)

def bg.run.go(held: Bool, +ok: Bool, +k: S.Role, +c: R.Cmd, +code: Nat, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, +conn: S.Conn, +srv: S.Srv, ds: R.Ds, ws: Waits, up: List<&2, Up>, tx: Tx) -> LRun:
  match held:
    case True{}:
      bg.held.k(k, c, code, rs, es, conn, srv, ds, ws, up, tx)
    case False{}:
      bg.done(S.run_log(conn, srv, B.Mixed{[c], Nil{}}, ds), gen.pre(ok, c, code), rs, es, ws, up, tx)

# a command run while some client has a transaction or watches keys: its
# effects touch them (Touches), with the databases before it and after
def bg.touched(+pre: Maybe<&2, R.Ds>, es: List<&2, A.Ent>, g: LRun) -> LRun:
  match g:
    case LRun{rs, +e1, conn, srv, +ds, ws, up, tx}:
      LRun{rs, List.append(&2, A.Ent, e1, es), conn, srv, ds, ws, up, touch.ents(tx, e1, pre, ds)}
    case LHeld{h}:
      LHeld{h}

def bg.run.tx(on: Bool, held: Bool, +ok: Bool, +k: S.Role, +c: R.Cmd, +code: Nat, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, +conn: S.Conn, +srv: S.Srv, ds: R.Ds, ws: Waits, up: List<&2, Up>, tx: Tx) -> LRun:
  match on:
    case False{}:
      bg.run.go(held, ok, k, c, code, rs, es, conn, srv, ds, ws, up, tx)
    case True{}:
      +d0 = ds
      bg.touched(Some{d0}, es, bg.run.go(held, ok, k, c, code, rs, Nil{}, conn, srv, d0, ws, up, tx))

def bg.run(held: Bool, +ok: Bool, +k: S.Role, +c: R.Cmd, +code: Nat, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, +conn: S.Conn, +srv: S.Srv, ds: R.Ds, ws: Waits, up: List<&2, Up>, tx: Tx) -> LRun:
  +t = tx
  bg.run.tx(tx.on(t), held, ok, k, c, code, rs, es, conn, srv, ds, ws, up, t)

# one command, unless a QUIT before it dropped it
def bg.one.q(q: Bool, +c: R.Cmd, +code: Nat, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, +conn: S.Conn, +srv: S.Srv, ds: R.Ds, ws: Waits, up: List<&2, Up>, tx: Tx) -> LRun:
  match q:
    case True{}:
      LRun{rs, es, conn, srv, ds, ws, up, tx}
    case False{}:
      +k = S.kind(c)
      +ok = S.may(k, conn, srv)
      bg.run(gen.muted(ok, code, conn), ok, k, c, code, rs, es, conn, srv, ds, ws, up, tx)

def bg.one(+c: R.Cmd, +code: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, +conn, srv, ds, ws, up, tx}:
      bg.one.q(S.conn.quit(conn), c, code, rs, es, conn, srv, ds, ws, up, tx)
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
def bg.popped.put(+e: List<&2, A.Eff>, +ds: R.Ds, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, conn: S.Conn, srv: S.Srv, ws: Waits, up: List<&2, Up>, tx: Tx) -> LRun:
  LRun{rs, A.ents.onto(e, es), conn, srv, ds, ws, up, touch.effs(tx, e, None{}, ds)}

def bg.popped(w: Waits, r: R.Reply & (List<&2, A.Eff> & R.Ds), rs: List<&2, R.Reply>, es: List<&2, A.Ent>, conn: S.Conn, srv: S.Srv, ws: Waits, up: List<&2, Up>, tx: Tx) -> LRun:
  match w:
    case WaitOn{id, back, +c0, c1, +b, +code, db, until, cmds, codes, rest}:
      (x, q) = r
      (e, ds) = q
      +y = S.blk.shape(S.blk.form(b), x)
      +left = ws
      bg.popped.put(e, ds, rs, es, conn, waits.count(left, bg.errs(srv, code, y)), left, Up{back, c1, S.put(S.say(S.conn.mode(c0), y), Nil{}), cmds, codes} <> up, tx)
    case WaitNone{}:
      (x, q) = r
      (e, ds) = q
      LRun{rs, es, conn, srv, ds, ws, up, tx}

def bg.pop(w: Waits, +k: String, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, ws, up, tx}:
      +x = w
      bg.popped(x, A.act(R.ARun{S.blk.at(waits.blk(x), k)}, R.ds.focus(waits.db(x), ds)), rs, es, conn, srv, ws, up, tx)
    case LHeld{h}:
      LHeld{h}

# the clients served while one is ready: the first that is, each round
# (fuel: a client served each round, so one round for each, and one more)
type Sv is Data:
  Sv{more: Bool, g: LRun}

def bg.serve.one(m: Found, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, conn: S.Conn, srv: S.Srv, ds: R.Ds, up: List<&2, Up>, tx: Tx) -> Sv:
  match m:
    case Found{w, +k, ws}:
      Sv{True{}, bg.pop(w, k, LRun{rs, es, conn, srv, ds, ws, up, tx})}
    case NotFound{ws}:
      Sv{False{}, LRun{rs, es, conn, srv, ds, ws, up, tx}}

def bg.serve.go(f: Nat, v: Sv) -> LRun:
  match f v:
    case 1n+h Sv{True{}, LRun{rs, es, conn, srv, +ds, +ws, up, tx}}:
      bg.serve.go(h, bg.serve.one(waits.find(ws, waits.ready(ds, ws), ds, WaitNone{}), rs, es, conn, srv, ds, up, tx))
    case _ Sv{more, g0}:
      g0

# the batch's database in focus again
def bg.refocus(g: LRun) -> LRun:
  match g:
    case LRun{rs, es, +conn, srv, ds, ws, up, tx}:
      LRun{rs, es, conn, srv, R.ds.focus(S.conn.db(conn), ds), ws, up, tx}
    case LHeld{h}:
      LHeld{h}

# after a command, the clients that wait served while one is ready
def bg.serve(g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, WaitNone{}, up, tx}:
      LRun{rs, es, conn, srv, ds, WaitNone{}, up, tx}
    case LRun{rs, es, conn, srv, ds, +ws, up, tx}:
      bg.refocus(bg.serve.go(1n+waits.length(ws, 0n), Sv{True{}, LRun{rs, es, conn, srv, ds, ws, up, tx}}))
    case LHeld{h}:
      LHeld{h}

# a blocking command that finds nothing: its client waits, the call
# counted now
def bg.wait(+id: Nat, +back: Chan(Ans), b: S.Blk, +c: R.Cmd, +code: Nat, rest: List<&2, R.Cmd>, more: List<&2, Nat>, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, +conn, +srv, +ds, ws, up, tx}:
      +x = b
      +ws2 = waits.add(ws, WaitOn{id, back, conn, S.next_conn(False{}, c, conn, srv), x, code, S.conn.db(conn), S.blk.until(R.ds.now(ds), S.blk.ms(x)), rest, more, WaitNone{}})
      LHeld{LRun{rs, es, conn, waits.count(ws2, gen.count(srv, code, Nil{})), ds, ws2, up, tx}}
    case LHeld{h}:
      LHeld{h}

# CLIENT UNBLOCK: the client of the id, if it waits, unblocked with a
# null array or an UNBLOCKED error, its call failed (an error reply's
# counted as one); the command answers 1, or 0 when no client of the id
# waits. Redis counts CLIENT UNBLOCK's own call failed when it sends the
# error: the error reply came while it ran (incrCommandStatsOnError).
def unblock.msg() -> String:
  "UNBLOCKED client unblocked via CLIENT UNBLOCK"

def unblock.reply(+err: Bool) -> R.Reply:
  Bool.pick(R.Reply, err, R.RError{unblock.msg()}, R.RNullA{})

def unblock.stat(+err: Bool, +code: Nat, +own: Nat, srv: S.Srv) -> S.Srv:
  match err:
    case True{}:
      S.srv.failed(S.srv.errs(srv, [R.Erred{code, unblock.msg()}]), own)
    case False{}:
      S.srv.failed(srv, code)

def bg.unblocked(p: Waits & Waits, +err: Bool, +code: Nat, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, conn: S.Conn, srv: S.Srv, ds: R.Ds, up: List<&2, Up>, tx: Tx) -> LRun:
  (w, +ws) = p
  match w:
    case WaitOn{id, back, +c0, c1, b, +wc, db, until, cmds, codes, rest}:
      bg.one(R.Own{R.SReply{R.RInt{R.IPos{1n}}}}, code, LRun{rs, es, conn, waits.count(ws, unblock.stat(err, wc, code, srv)), ds, ws, Up{back, c1, S.put(S.say(S.conn.mode(c0), unblock.reply(err)), Nil{}), cmds, codes} <> up, tx})
    case WaitNone{}:
      bg.one(R.Own{R.SReply{R.RInt{R.IPos{0n}}}}, code, LRun{rs, es, conn, srv, ds, ws, up, tx})

def bg.unblock(+n: Nat, +err: Bool, +code: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, +ws, up, tx}:
      bg.unblocked(waits.take(ws, waits.is(n, ws), n, WaitNone{}), err, code, rs, es, conn, srv, ds, up, tx)
    case LHeld{h}:
      LHeld{h}

# what the shell does with a command: run it as the session runs it, make
# its client wait (a blocking command that would), unblock a client
# (CLIENT UNBLOCK), or act on its client's transaction (Transactions):
# open one (MULTI), refuse a MULTI in one, run one (EXEC), abort one (an
# EXEC refused, with why), drop one (DISCARD), watch keys, refuse a WATCH
# in one, unwatch, end one with the connection's state (RESET), queue a
# command in one, or refuse one queued and flag the transaction; a
# command that does not run (after a QUIT, or before the client
# authenticates) runs as the session runs it.
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

def sh.blk(b: S.Blk, +ds: R.Ds) -> Sh:
  +x = b
  Bool.pick(Sh, S.blk.waits(x, R.ds.focused(ds)), ShWait{x}, ShRun{})

# why an EXEC refused aborts its transaction: its error, without ERR (as
# Redis words EXECABORT's reason)
def abort.why(+m: String) -> String:
  Bool.pick(String, String.eq(String.take(m, 4n), "ERR "), String.drop(m, 4n), m)

def sh.refused(+c: R.Cmd, +code: Nat) -> Sh:
  match c:
    case R.Own{R.SBad{R.RError{+m}}}:
      Bool.pick(Sh, Nat.is_eq(Nat.div(code, 4n), R.stat.top(162n)), ShAbort{abort.why(m)}, ShRefuse{})
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
    case R.Own{R.SBad{R.RError{+m}}}:
      sh.abort.if(Nat.is_eq(Nat.div(code, 4n), R.stat.top(162n)), m)
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
  sh.queue.if(Nat.is_eq(Nat.mod(code, 4n), 1n), c, code)

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

def sh.of.run(inm: Bool, may: Bool, +c: R.Cmd, +code: Nat, +ds: R.Ds) -> Sh:
  match inm may:
    case True{} _:
      sh.multi(may, c, code)
    case False{} True{}:
      sh.plain(c, code, ds)
    case False{} False{}:
      sh.noauth(c)

def sh.of(quit: Bool, may: Bool, inm: Bool, +c: R.Cmd, +code: Nat, +ds: R.Ds) -> Sh:
  match quit:
    case True{}:
      ShRun{}
    case False{}:
      sh.of.run(inm, may, c, code, ds)

# the client's transaction state, changed (its client first in the chain)
def bg.open(+id: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, ws, up, tx}:
      LRun{rs, es, conn, srv, ds, ws, up, tx.open(id, tx)}
    case LHeld{h}:
      LHeld{h}

def bg.close(+id: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, ws, up, tx}:
      LRun{rs, es, conn, srv, ds, ws, up, tx.close(id, tx)}
    case LHeld{h}:
      LHeld{h}

def bg.bad(g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, ws, up, tx}:
      LRun{rs, es, conn, srv, ds, ws, up, tx.bad(tx)}
    case LHeld{h}:
      LHeld{h}

def bg.unwatch(+id: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, ds, ws, up, tx}:
      LRun{rs, es, conn, srv, ds, ws, up, tx.unwatch(id, tx)}
    case LHeld{h}:
      LHeld{h}

def bg.watch(+id: Nat, ks: List<&2, String>, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, +conn, srv, +ds, ws, up, tx}:
      LRun{rs, es, conn, srv, ds, ws, up, tx.watch(id, S.conn.db(conn), ks, ds, tx)}
    case LHeld{h}:
      LHeld{h}

# a command queued: QUEUED, sent or not as the mode says; it counts when
# EXEC runs it
def bg.queue(+c: R.Cmd, +code: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, +conn, +srv, ds, ws, up, tx}:
      LRun{S.put(S.say(S.conn.mode(conn), R.RStatus{"QUEUED"}), rs), es, S.step_conn(conn, srv), srv, ds, ws, up, tx.queue(c, code, tx)}
    case LHeld{h}:
      LHeld{h}

# a reply of the shell's own to a command, counted as its call
def bg.say(+r: R.Reply, +code: Nat, g: LRun) -> LRun:
  bg.one(R.Own{R.SReply{r}}, code, g)

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
    case S.Conn{id, auth, name, mode, quit, db}:
      S.Conn{id, auth, name, m, quit, db}

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

def bg.exec.done(rs: List<&2, R.Reply>, es: List<&2, A.Ent>, +m0: S.Mute, +mi: S.Mute, +code: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs1, es1, +conn1, srv1, ds1, ws1, up1, tx1}:
      +conn2 = Bool.pick(S.Conn, mute.same(S.conn.mode(conn1), mi), conn.mode.set(m0, conn1), conn1)
      bg.say(R.RArray{List.reverse(&2, R.Reply, rs1)}, code, LRun{rs, tx.effs(es1, es), conn2, srv1, ds1, ws1, up1, tx1})
    case LHeld{h}:
      LHeld{h}

# a command of EXEC: as it runs outside of a transaction, but that no
# client waits (a blocking command answers as for a client that may not
# wait: the session's pop, run once) and the clients that wait are
# served only after EXEC
def bg.x.cmd(may: Bool, +c: R.Cmd, +code: Nat, g: LRun) -> LRun:
  match may c:
    case True{} R.Own{R.SUnblock{+n, +e}}:
      bg.unblock(n, e, code, g)
    case _ _:
      bg.one(c, code, g)

def bg.x.go(cmds: List<&2, R.Cmd>, codes: List<&2, Nat>, g: LRun) -> LRun:
  match cmds codes g:
    case Con{+c, rest} Con{+k, more} LRun{rs, es, +conn, +srv, ds, ws, up, tx}:
      bg.x.go(rest, more, bg.x.cmd(S.may(S.kind(c), conn, srv), c, k, LRun{rs, es, conn, srv, ds, ws, up, tx}))
    case _ _ g0:
      g0

def bg.exec.run(+code: Nat, cmds: List<&2, R.Cmd>, codes: List<&2, Nat>, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, +conn, srv, ds, ws, up, tx}:
      +m0 = S.conn.mode(conn)
      +mi = exec.mode(m0)
      bg.exec.done(rs, es, m0, mi, code, bg.x.go(cmds, codes, LRun{Nil{}, Nil{}, conn.mode.set(mi, conn), srv, ds, ws, up, tx}))
    case LHeld{h}:
      LHeld{h}

def bg.exec.if(late: Bool, +code: Nat, qs: List<&2, R.Cmd>, qc: List<&2, Nat>, g: LRun) -> LRun:
  match late:
    case True{}:
      bg.say(R.RNullA{}, code, g)
    case False{}:
      bg.exec.run(code, List.reverse(&2, R.Cmd, qs), List.reverse(&2, Nat, qc), g)

# EXEC of a transaction taken out of the chain (mine): EXECABORT when a
# command was refused while it queued, a null array when a watched key
# was touched or is there with its time passed now, else its commands
def bg.exec.of(p: Tx & Tx, +code: Nat, rs: List<&2, R.Reply>, es: List<&2, A.Ent>, conn: S.Conn, srv: S.Srv, +ds: R.Ds, ws: Waits, up: List<&2, Up>) -> LRun:
  (mine, others) = p
  match mine:
    case TxOn{i, mu, True{}, cs, qs, qc, wk, r}:
      bg.say(R.RError{"EXECABORT Transaction discarded because of previous errors."}, code, LRun{rs, es, conn, srv, ds, ws, up, others})
    case TxOn{i, mu, False{}, True{}, qs, qc, wk, r}:
      bg.say(R.RNullA{}, code, LRun{rs, es, conn, srv, ds, ws, up, others})
    case TxOn{i, mu, False{}, False{}, qs, qc, +wk, r}:
      bg.exec.if(wk.late(wk, ds, R.ds.now(ds)), code, qs, qc, LRun{rs, es, conn, srv, ds, ws, up, others})
    case TxNone{}:
      bg.say(R.RError{"ERR EXEC without MULTI"}, code, LRun{rs, es, conn, srv, ds, ws, up, others})

def bg.exec(+id: Nat, +code: Nat, g: LRun) -> LRun:
  match g:
    case LRun{rs, es, conn, srv, +ds, ws, up, +tx}:
      bg.exec.of(tx.take(tx, tx.is(id, tx), id, TxNone{}), code, rs, es, conn, srv, ds, ws, up)
    case LHeld{h}:
      LHeld{h}

def bg.cmd(+id: Nat, +back: Chan(Ans), sh: Sh, +c: R.Cmd, +code: Nat, rest: List<&2, R.Cmd>, more: List<&2, Nat>, g: LRun) -> LRun:
  match sh:
    case ShRun{}:
      bg.serve(bg.one(c, code, g))
    case ShWait{b}:
      bg.wait(id, back, b, c, code, rest, more, g)
    case ShUnblock{+n, +e}:
      bg.unblock(n, e, code, g)
    case ShMulti{}:
      bg.one(c, code, bg.open(id, g))
    case ShNested{}:
      bg.say(R.RError{"ERR MULTI calls can not be nested"}, code, g)
    case ShExec{}:
      bg.serve(bg.exec(id, code, g))
    case ShAbort{m}:
      bg.one(R.Own{R.SBad{R.RError{"EXECABORT Transaction discarded because of: " ++ m}}}, Nat.add(Nat.mul(Nat.div(code, 4n), 4n), 1n), bg.close(id, g))
    case ShDiscard{}:
      bg.say(R.r_ok(), code, bg.close(id, g))
    case ShWatch{ks}:
      bg.one(c, code, bg.watch(id, ks, g))
    case ShWatchIn{}:
      bg.say(R.RError{"ERR WATCH inside MULTI is not allowed"}, code, g)
    case ShUnwatch{}:
      bg.one(c, code, bg.unwatch(id, g))
    case ShReset{}:
      bg.one(c, code, bg.close(id, g))
    case ShQueue{}:
      bg.queue(c, code, g)
    case ShRefuse{}:
      bg.one(c, code, bg.bad(g))

# a batch the general way: a command at a time, until its client waits
def bg.go(+id: Nat, +back: Chan(Ans), cmds: List<&2, R.Cmd>, codes: List<&2, Nat>, g: LRun) -> LRun:
  match cmds codes g:
    case Con{+c, +rest} Con{+k, +more} LRun{rs, es, +conn, +srv, +ds, ws, up, +tx}:
      +sh = sh.of(S.conn.quit(conn), S.may(S.kind(c), conn, srv), tx.multi(id, tx), c, k, ds)
      bg.go(id, back, rest, more, bg.cmd(id, back, sh, c, k, rest, more, LRun{rs, es, conn, srv, ds, ws, up, tx}))
    case _ _ g0:
      g0

# the answer to a batch whose client waits: the replies before its
# blocking command, encoded (none when there are none)
def hold_of(rs: List<&2, R.Reply>) -> Ans:
  match rs:
    case Nil{}:
      Hold{None{}}
    case Con{r, rest}:
      Hold{Some{P.encode_all(r <> rest)}}

# a batch run the general way, put in the group: its answer, and its
# bytes for INFO (inb: those it came in, counted once)
def bg.put(+back: Chan(Ans), +inb: Nat, g: LRun, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>) -> Grp:
  match g:
    case LRun{rs, es, conn, srv, ds, ws, up, tx}:
      +a = ans_of(List.reverse(&2, R.Reply, rs), conn)
      +outb = ans.len(a)
      Grp{(back, a) <> outs, es, S.srv.ran(srv, 0n, 0n, Nil{}, inb, outb), ds, ws, up, tx}
    case LHeld{LRun{rs, es, conn, srv, ds, ws, up, tx}}:
      +a = hold_of(List.reverse(&2, R.Reply, rs))
      +outb = ans.len(a)
      Grp{(back, a) <> outs, es, S.srv.ran(srv, 0n, 0n, Nil{}, inb, outb), ds, ws, up, tx}
    case LHeld{LHeld{h}}:
      bg.put(back, inb, h, outs)

def bg.batch(+cn: S.Conn, +back: Chan(Ans), +inb: Nat, cmds: List<&2, R.Cmd>, codes: List<&2, Nat>, g: Grp) -> Grp:
  match g:
    case Grp{outs, es, srv, ds, ws, up, tx}:
      +id = S.conn.id(cn)
      bg.put(back, inb, bg.go(id, back, cmds, codes, LRun{Nil{}, es, cn, srv, ds, ws, up, tx.front(id, tx)}), outs)

# an unblocked client's batch, on: on its database, after its reply
def bg.up(u: Up, g: Grp) -> Grp:
  match u g:
    case Up{+back, +conn, rs, cmds, codes} Grp{outs, es, srv, ds, ws, up, tx}:
      +id = S.conn.id(conn)
      bg.put(back, 0n, bg.go(id, back, cmds, codes, LRun{rs, es, conn, srv, R.ds.focus(S.conn.db(conn), ds), ws, up, tx.front(id, tx)}), outs)

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
    case 1n+h Grp{outs, es, srv, ds, ws, Con{u, more}, tx}:
      bg.ups(h, bg.ups.run(List.reverse(&2, Up, u <> more), Grp{outs, es, srv, ds, ws, Nil{}, tx}))
    case _ g0:
      g0

def ups.fuel() -> Nat:
  1000000n

def grp.late(p: Waits & List<&2, Up>, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, srv: S.Srv, ds: R.Ds, tx: Tx) -> Grp:
  (+ws, up) = p
  bg.ups(ups.fuel(), Grp{outs, es, waits.count(ws, srv), ds, ws, up, tx})

# the end of a group: the clients whose time is up unblocked, then the
# unblocked clients' batches go on
def grp.end(g: Grp) -> Grp:
  match g:
    case Grp{outs, es, srv, ds, WaitNone{}, Nil{}, tx}:
      Grp{outs, es, srv, ds, WaitNone{}, Nil{}, tx}
    case Grp{outs, es, srv, ds, WaitNone{}, Con{u, more}, tx}:
      bg.ups(ups.fuel(), Grp{outs, es, srv, ds, WaitNone{}, u <> more, tx})
    case Grp{outs, es, srv, +ds, +ws, up, tx}:
      +now = R.ds.now(ds)
      grp.late(waits.expire(ws, waits.late(now, ws), now, WaitNone{}, up), outs, es, srv, ds, tx)

# a client gone (its connection closed while it waits): forgotten, its
# batch dropped, and its connection answered Bye, after any answer before
def grp.gone(+id: Nat, +back: Chan(Ans), outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, srv: S.Srv, ds: R.Ds, +ws: Waits, +up: List<&2, Up>, tx: Tx) -> Grp:
  +left = waits.rest(waits.take(ws, waits.is(id, ws), id, WaitNone{}))
  Grp{(back, Bye{}) <> outs, es, waits.count(left, srv), ds, left, ups.drop(up, ups.is(id, up), id), tx.drop(id, tx)}

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

# a batch of one code run the fast way, its replies looked at for errors
# when they have a '-' (ans.errs)
def run_put.one(dash: Bool, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, back: Chan(Ans), a: Ans, +calls: Nat, +run: Nat, +inb: Nat, +outb: Nat, srv: S.Srv, ds: R.Ds, up: List<&2, Up>) -> Grp:
  match dash:
    case False{}:
      Grp{(back, a) <> outs, es, S.srv.ran(srv, calls, run, Nil{}, inb, outb), ds, WaitNone{}, up, TxNone{}}
    case True{}:
      +b = a
      +xs = ans.errs(b, R.run.code(run))
      Grp{(back, b) <> outs, es, errs.put(xs, S.srv.ran(srv, calls, run, Nil{}, inb, outb)), ds, WaitNone{}, up, TxNone{}}

# a batch run the fast way: its calls counted, and its replies looked at
# for errors only where a call may have one (R.Tally): those of a batch
# of one code in its bytes (ans.errs), those of any other as they are,
# before they are encoded (each call has one reply, in order); with the
# append-only file, its effects put before the group's
def run_put(outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, back: Chan(Ans), t: R.Tally, +inb: Nat, d: S.Fin, up: List<&2, Up>) -> Grp:
  match t d:
    case R.Tally{+calls, False{}, +run, runs} S.Fin{rs, cn, srv, ds}:
      +a = ans_of(rs, cn)
      +outb = ans.len(a)
      Grp{(back, a) <> outs, es, S.srv.ran(srv, calls, run, runs, inb, outb), ds, WaitNone{}, up, TxNone{}}
    case R.Tally{+calls, True{}, +run, Nil{}} S.Fin{rs, cn, srv, ds}:
      +a = ans_of(rs, cn)
      +outb = ans.len(a)
      run_put.one(ans.dash(a, outb), outs, es, back, a, calls, run, inb, outb, srv, ds, up)
    case R.Tally{+calls, True{}, +run, +runs} S.Fin{+rs, cn, srv, ds}:
      +xs = R.errs.zip(rs, R.codes.runs(runs, Nil{}), Nil{})
      +a = ans_of(rs, cn)
      +outb = ans.len(a)
      Grp{(back, a) <> outs, es, errs.put(xs, S.srv.ran(srv, calls, run, runs, inb, outb)), ds, WaitNone{}, up, TxNone{}}

def group_put(outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, back: Chan(Ans), t: R.Tally, +inb: Nat, d: S.Logged, up: List<&2, Up>) -> Grp:
  match t d:
    case R.Tally{+calls, False{}, +run, runs} S.Logged{rs, e, cn, srv, ds}:
      +a = ans_of(rs, cn)
      +outb = ans.len(a)
      Grp{(back, a) <> outs, A.ents.onto(e, es), S.srv.ran(srv, calls, run, runs, inb, outb), ds, WaitNone{}, up, TxNone{}}
    case R.Tally{+calls, True{}, +run, Nil{}} S.Logged{rs, e, cn, srv, ds}:
      +a = ans_of(rs, cn)
      +outb = ans.len(a)
      run_put.one(ans.dash(a, outb), outs, A.ents.onto(e, es), back, a, calls, run, inb, outb, srv, ds, up)
    case R.Tally{+calls, True{}, +run, +runs} S.Logged{+rs, e, cn, srv, ds}:
      +xs = R.errs.zip(rs, R.codes.runs(runs, Nil{}), Nil{})
      +a = ans_of(rs, cn)
      +outb = ans.len(a)
      Grp{(back, a) <> outs, A.ents.onto(e, es), errs.put(xs, S.srv.ran(srv, calls, run, runs, inb, outb)), ds, WaitNone{}, up, TxNone{}}

# a batch the fast way, without the append-only file or with it (log)
def fast.run(+log: Bool, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, back: Chan(Ans), t: R.Tally, +inb: Nat, cn: S.Conn, srv: S.Srv, cmds: List<&2, R.Cmd>, hs: List<&2, U32>, ds: R.Ds, up: List<&2, Up>) -> Grp:
  match log:
    case True{}:
      group_put(outs, es, back, t, inb, S.run_log.plain(True{}, cn, srv, cmds, hs, ds), up)
    case False{}:
      run_put(outs, es, back, t, inb, S.run.plain(True{}, cn, srv, cmds, hs, ds), up)

def fast(+log: Bool, ready: Bool, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, cn: S.Conn, cmds: List<&2, R.Cmd>, +hs: List<&2, U32>, back: Chan(Ans), +tl: U32, +inb: Nat, srv: S.Srv, ds: R.Ds, up: List<&2, Up>) -> Grp:
  match ready:
    case True{}:
      +t = R.tally(tl, inb, hs)
      fast.run(log, outs, es, back, t, inb, cn, srv, cmds, hs, ds, up)
    case False{}:
      bg.batch(cn, back, inb, cmds, R.codes.of(hs), Grp{outs, es, srv, ds, WaitNone{}, up, TxNone{}})

def group_job(+log: Bool, job: B.Job, ws: Waits, tx: Tx, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, +cn: S.Conn, back: Chan(Ans), +tl: U32, +inb: Nat, +srv: S.Srv, ds: R.Ds, up: List<&2, Up>) -> Grp:
  match job ws tx:
    case B.Plain{cmds, hs} WaitNone{} TxNone{}:
      fast(log, S.ready(cn, srv), outs, es, cn, cmds, hs, back, tl, inb, srv, ds, up)
    case B.Plain{cmds, +hs} w t:
      bg.batch(cn, back, inb, cmds, R.codes.of(hs), Grp{outs, es, srv, ds, w, up, t})
    case B.Mixed{cmds, +hs} w t:
      bg.batch(cn, back, inb, cmds, R.codes.of(hs), Grp{outs, es, srv, ds, w, up, t})

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

# a sweep of expired keys: its DELs are logged as the batches' effects
# are, with the append-only file
def group.swept(outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, r: S.Srv & (List<&2, A.Ent> & R.Ds), ws: Waits, up: List<&2, Up>, tx: Tx) -> Grp:
  (srv, q) = r
  (es, ds) = q
  Grp{outs, es, srv, ds, ws, up, tx}

# a sweep while some client has a transaction or watches keys: the keys
# it deleted are touched (each was there)
def group.swept.put(outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, srv: S.Srv, +e1: List<&2, A.Ent>, +ds: R.Ds, ws: Waits, up: List<&2, Up>, tx: Tx) -> Grp:
  Grp{outs, List.append(&2, A.Ent, e1, es), srv, ds, ws, up, touch.ents(tx, e1, None{}, ds)}

def group.swept.tx(outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, r: S.Srv & (List<&2, A.Ent> & R.Ds), ws: Waits, up: List<&2, Up>, tx: Tx) -> Grp:
  (srv, q) = r
  (e1, ds) = q
  group.swept.put(outs, es, srv, e1, ds, ws, up, tx)

def group.sweep(on: Bool, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, A.Ent>, srv: S.Srv, ds: R.Ds, ws: Waits, up: List<&2, Up>, tx: Tx) -> Grp:
  match on:
    case False{}:
      group.swept(outs, sweep(srv, es, ds), ws, up, tx)
    case True{}:
      group.swept.tx(outs, es, sweep(srv, Nil{}, ds), ws, up, tx)

def group_req(+log: Bool, q: Req, g: Grp) -> Grp:
  match q g:
    case Req{+cn, job, back, +tl, +inb} Grp{outs, es, srv, ds, ws, up, tx}:
      group_job(log, job, ws, tx, outs, es, cn, back, tl, inb, srv, R.ds.focus(S.conn.db(cn), ds), up)
    case Facts{live} Grp{outs, es, srv, ds, ws, up, tx}:
      Grp{outs, es, S.srv.live(srv, live), ds, ws, up, tx}
    case Tick{+ms} Grp{outs, es, srv, ds, ws, up, +tx}:
      group.sweep(tx.on(tx), outs, es, S.srv.tick(srv, ms), ds, ws, up, tx)
    case Oops{} Grp{outs, es, srv, ds, ws, up, tx}:
      Grp{outs, es, S.srv.erred(srv, "ERR Protocol error"), ds, ws, up, tx}
    case Gone{+id, +back} Grp{outs, es, srv, ds, +ws, +up, tx}:
      grp.gone(id, back, outs, es, srv, ds, ws, up, tx)
    case Left{+id} Grp{outs, es, srv, ds, ws, up, tx}:
      Grp{outs, es, srv, ds, ws, up, tx.drop(id, tx)}

# the clock (IO.clock: s and us since 1970) in ms
def clock.ms(t: U32 & U32) -> Nat:
  (secs, us) = t
  Nat.add(Nat.mul(U32.to_nat(secs), 1000n), U32.to_nat(U32.div(us, 1000)))

def group_run(+log: Bool, qs: List<&1, Req>, g: Grp) -> Grp:
  match qs:
    case Nil{}:
      g
    case Con{q, rest}:
      group_run(log, rest, group_req(log, q, g))

@unsafe
def db_loop(srv: S.Srv, ds: R.Ds, ws: Waits, tx: Tx, +reqs: Chan(Req)) -> IO(Unit):
  do IO<Unit>:
    m : Maybe<&1, Req> <- Chan.recv(Req, reqs)
    db_serve(srv, ds, ws, tx, reqs, m)

@unsafe
def db_serve(srv: S.Srv, ds: R.Ds, ws: Waits, tx: Tx, +reqs: Chan(Req), m: Maybe<&1, Req>) -> IO(Unit):
  match m:
    case None{}:
      IO.pure(Unit, Unit{})
    case Some{q}:
      do IO<Unit>:
        more : List<&1, Req> <- Chan.drain(Req, reqs, group_max())
        t : U32 & U32 <- IO.clock()
        db_group(grp.end(group_run(False{}, q <> more, Grp{Nil{}, Nil{}, srv, R.ds.at(clock.ms(t), ds), ws, Nil{}, tx})), reqs)

@unsafe
def db_group(g: Grp, +reqs: Chan(Req)) -> IO(Unit):
  match g:
    case Grp{outs, es, srv, ds, ws, up, tx}:
      do IO<Unit>:
        Unit <- Chan.send_all(Ans, List.reverse(&2, Sigma<&2, &2, Chan(Ans), _ => Ans>, outs))
        db_loop(srv, ds, ws, tx, reqs)

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
    case Link{db, back, post, tl, id}:
      do IO<Unit>:
        Unit <- Socket.close(s)
        sent : Bool <- Chan.send(Req, db, Left{id})
        Chan.close(Ans, back)

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
def count_upto(n: Nat, s: String) -> Nat:
  match n s:
    case 0n _:
      0n
    case 1n+m SNil{}:
      0n
    case 1n+m SCon{c, t}:
      1n+count_upto(m, t)

# the bytes of the pieces read, for INFO
def got.bytes(+xs: List<&2, String>, +acc: Nat) -> Nat:
  match xs:
    case Nil{}:
      acc
    case Con{+x, +rest}:
      got.bytes(rest, Nat.add(acc, String.length(x)))

# the requests read so far: a lone new piece is one run when it is short
# (resp.bend reads longer ones in windows), and the tail of the last
# read with what came since is several
def parse_in(rest: String, got: List<&2, String>) -> P.Batch:
  match rest got:
    case SNil{} Con{x, Nil{}}:
      P.parse_read(x)
    case r g:
      P.parse_runs(r ++ glue(g, SNil{}))

# the connection's loop: rest is the unparsed tail of what came before
# (at most one incomplete request); got holds the pieces read since,
# newest first, have counts their bytes (up to need), and the tail needs
# need more bytes before a parse can make progress, so a large value is
# parsed once, not once per read; cn is the connection's state, as the
# actor gave it back after the last batch. Bytes cross as they are, one
# Char each (recv_raw, send_raw): a String of them is a packed buffer.
@unsafe
def conn_loop(s: Socket, rest: String, got: List<&2, String>, have: Nat, need: Nat, +ln: Link, cn: S.Conn) -> IO(Unit):
  do IO<Unit>:
    m : Socket & Result<&1, &1, U32 & String, String> <- TCP.recv_raw(s, 65536)
    conn_got(m, rest, got, have, need, ln, cn)

@unsafe
def conn_got(m: Socket & Result<&1, &1, U32 & String, String>, rest: String, got: List<&2, String>, have: Nat, need: Nat, +ln: Link, cn: S.Conn) -> IO(Unit):
  (s, r) = m
  match r:
    case Fail{e}:
      conn_end(s, ln)
    case Done{+x}:
      conn_data(s, Nat.is_eq(String.length(x), 0n), x, rest, got, have, need, ln, cn)

@unsafe
def conn_data(s: Socket, eof: Bool, +x: String, rest: String, got: List<&2, String>, have: Nat, +need: Nat, +ln: Link, cn: S.Conn) -> IO(Unit):
  match eof:
    case True{}:
      conn_end(s, ln)
    case False{}:
      +h = Nat.add(have, count_upto(need, x))
      conn_more(s, rest, x <> got, h, need, ln, cn, Nat.is_lt(h, need))

@unsafe
def conn_more(s: Socket, rest: String, +got: List<&2, String>, have: Nat, need: Nat, +ln: Link, cn: S.Conn, wait: Bool) -> IO(Unit):
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
    case P.Batch{reqs, tl, rest, err, need}:
      conn_send(s, ln, cn, reqs, tl, err, rest, need, inb)

@unsafe
def conn_send(s: Socket, +ln: Link, cn: S.Conn, reqs: List<&2, B.Req>, tl: U32, err: Maybe<&2, String>, rest: String, need: Nat, +inb: Nat) -> IO(Unit):
  match reqs:
    case Nil{}:
      conn_err(s, ln, cn, err, rest, need)
    case Con{r, rs}:
      conn_ask(s, ln, cn, r <> rs, tl, err, rest, need, inb)

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
def conn_job(live: Bool, s: Socket, +ln: Link, job: B.Job, cn: S.Conn, n: U32, +inb: Nat, err: Maybe<&2, String>, rest: String, need: Nat) -> IO(Unit):
  match live ln:
    case False{} Link{db, +back, post, tl, id}:
      do IO<Unit>:
        sent : Bool <- Chan.send(Req, db, Req{cn, job, back, n, inb})
        got : Maybe<&1, Ans> <- Chan.recv(Ans, back)
        conn_ans(s, ln, got, err, rest, need)
    case True{} Link{+db, +back, post, +tl, id}:
      do IO<Unit>:
        l : I.Live <- live.read(tl)
        sent1 : Bool <- Chan.send(Req, db, Facts{l})
        sent2 : Bool <- Chan.send(Req, db, Req{cn, job, back, n, inb})
        got : Maybe<&1, Ans> <- Chan.recv(Ans, back)
        conn_ans(s, ln, got, err, rest, need)

# a batch: the parsed requests (newest first) put in order, how many they
# are and the words of their codes (R.tl.add), and the bytes they came in
@unsafe
def conn_ask(s: Socket, +ln: Link, cn: S.Conn, rs: List<&2, B.Req>, tl: U32, err: Maybe<&2, String>, rest: String, need: Nat, +inb: Nat) -> IO(Unit):
  +job = B.job(B.unzip(rs, Nil{}, Nil{}))
  conn_job(live.wants(job), s, ln, job, cn, tl, inb, err, rest, need)

@unsafe
def conn_ans(s: Socket, +ln: Link, got: Maybe<&1, Ans>, err: Maybe<&2, String>, rest: String, need: Nat) -> IO(Unit):
  match got:
    case None{}:
      conn_end(s, ln)
    case Some{Ans{None{}, cn}}:
      conn_quit(s, ln, cn, err, rest, need)
    case Some{Ans{Some{out}, cn}}:
      conn_put(s, ln, link.post(ln), out, cn, err, rest, need)
    case Some{Hold{out}}:
      conn_hold(s, ln, link.post(ln), True{}, out, Nil{}, 0n, need, err, rest)
    case Some{Ready{}}:
      conn_end(s, ln)
    case Some{Bye{}}:
      conn_end(s, ln)

@unsafe
def conn_put(s: Socket, +ln: Link, post: Bool, out: String, cn: S.Conn, err: Maybe<&2, String>, rest: String, need: Nat) -> IO(Unit):
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
def conn_sent(m: Socket & Result<&1, &1, U32 & String, Unit>, +ln: Link, cn: S.Conn, err: Maybe<&2, String>, rest: String, need: Nat) -> IO(Unit):
  (s, r) = m
  match r:
    case Fail{e}:
      conn_end(s, ln)
    case Done{u}:
      conn_quit(s, ln, cn, err, rest, need)

# after a QUIT, the connection closes once its replies are out; the rest
# of what it sent is not read
@unsafe
def conn_quit(s: Socket, +ln: Link, +cn: S.Conn, err: Maybe<&2, String>, rest: String, need: Nat) -> IO(Unit):
  conn_quit.if(S.conn.quit(cn), s, ln, cn, err, rest, need)

@unsafe
def conn_quit.if(quit: Bool, s: Socket, +ln: Link, cn: S.Conn, err: Maybe<&2, String>, rest: String, need: Nat) -> IO(Unit):
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
def conn_err(s: Socket, +ln: Link, cn: S.Conn, err: Maybe<&2, String>, rest: String, need: Nat) -> IO(Unit):
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
def conn_held.new(m: Socket & Result<&1, &1, U32 & String, Unit>, +ln: Link, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: String) -> IO(Unit):
  (s, r) = m
  match r:
    case Fail{e}:
      conn_gone(s, ln)
    case Done{u}:
      conn_watch(s, ln, got, have, need, err, rest)

@unsafe
def conn_held.out(m: Socket & Result<&1, &1, U32 & String, Unit>, +ln: Link, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: String) -> IO(Unit):
  (s, r) = m
  match r:
    case Fail{e}:
      do IO<Unit>:
        p : Socket & Bool <- TCP.unwatch(s)
        conn_gone.p(p, ln)
    case Done{u}:
      conn_wait(s, ln, got, have, need, err, rest)

@unsafe
def conn_held(m: Socket & Result<&1, &1, U32 & String, Unit>, watch: Bool, +ln: Link, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: String) -> IO(Unit):
  match watch:
    case True{}:
      conn_held.new(m, ln, got, have, need, err, rest)
    case False{}:
      conn_held.out(m, ln, got, have, need, err, rest)

@unsafe
def conn_hold(s: Socket, +ln: Link, post: Bool, watch: Bool, out: Maybe<&2, String>, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: String) -> IO(Unit):
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
def conn_held.on(s: Socket, watch: Bool, +ln: Link, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: String) -> IO(Unit):
  match watch:
    case True{}:
      conn_watch(s, ln, got, have, need, err, rest)
    case False{}:
      conn_wait(s, ln, got, have, need, err, rest)

@unsafe
def conn_watch(s: Socket, +ln: Link, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: String) -> IO(Unit):
  match ln:
    case Link{db, +back, post, tl, id}:
      do IO<Unit>:
        s2 : Socket <- TCP.watch(Ans, s, back, Ready{})
        conn_wait(s2, ln, got, have, need, err, rest)

@unsafe
def conn_wait(s: Socket, +ln: Link, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: String) -> IO(Unit):
  match ln:
    case Link{db, +back, post, tl, id}:
      do IO<Unit>:
        m : Maybe<&1, Ans> <- Chan.recv(Ans, back)
        conn_woke(s, ln, m, got, have, need, err, rest)

@unsafe
def conn_woke(s: Socket, +ln: Link, m: Maybe<&1, Ans>, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: String) -> IO(Unit):
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
    case Some{Bye{}}:
      conn_wait(s, ln, got, have, need, err, rest)

# bytes that came while the client waits, kept; or its close
@unsafe
def conn_came.on(eof: Bool, s: Socket, +ln: Link, +x: String, got: List<&2, String>, have: Nat, +need: Nat, err: Maybe<&2, String>, rest: String) -> IO(Unit):
  match eof:
    case True{}:
      conn_gone(s, ln)
    case False{}:
      conn_watch(s, ln, x <> got, Nat.add(have, count_upto(need, x)), need, err, rest)

@unsafe
def conn_came(r: Socket & Result<&1, &1, U32 & String, String>, +ln: Link, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: String) -> IO(Unit):
  (s, x) = r
  match x:
    case Fail{e}:
      conn_gone(s, ln)
    case Done{+d}:
      conn_came.on(Nat.is_eq(String.length(d), 0n), s, ln, d, got, have, need, err, rest)

# the batch's answer: the watch taken back (a Ready it put dropped), the
# replies sent, then what came meanwhile read on, as after any batch
@unsafe
def conn_unwatched.drop(s: Socket, +ln: Link, out: Maybe<&2, String>, cn: S.Conn, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: String) -> IO(Unit):
  match ln:
    case Link{db, +back, post, tl, id}:
      do IO<Unit>:
        m : Maybe<&1, Ans> <- Chan.recv(Ans, back)
        conn_resume(s, ln, out, cn, got, have, need, err, rest)

@unsafe
def conn_unwatched(p: Socket & Bool, +ln: Link, out: Maybe<&2, String>, cn: S.Conn, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: String) -> IO(Unit):
  (s, taken) = p
  match taken:
    case True{}:
      conn_resume(s, ln, out, cn, got, have, need, err, rest)
    case False{}:
      conn_unwatched.drop(s, ln, out, cn, got, have, need, err, rest)

@unsafe
def conn_resume(s: Socket, +ln: Link, out: Maybe<&2, String>, cn: S.Conn, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: String) -> IO(Unit):
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
def conn_resent(m: Socket & Result<&1, &1, U32 & String, Unit>, +ln: Link, cn: S.Conn, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: String) -> IO(Unit):
  (s, r) = m
  match r:
    case Fail{e}:
      conn_end(s, ln)
    case Done{u}:
      conn_after(s, ln, cn, got, have, need, err, rest)

@unsafe
def conn_after.q(quit: Bool, s: Socket, +ln: Link, +cn: S.Conn, +got: List<&2, String>, +have: Nat, +need: Nat, err: Maybe<&2, String>, rest: String) -> IO(Unit):
  match quit err:
    case True{} _:
      conn_end(s, ln)
    case False{} Some{msg}:
      conn_oops(mute.on(S.conn.mode(cn)), s, ln, msg)
    case False{} None{}:
      conn_more(s, rest, got, have, need, ln, cn, Nat.is_lt(have, need))

@unsafe
def conn_after(s: Socket, +ln: Link, +cn: S.Conn, got: List<&2, String>, have: Nat, need: Nat, err: Maybe<&2, String>, rest: String) -> IO(Unit):
  conn_after.q(S.conn.quit(cn), s, ln, cn, got, have, need, err, rest)

# Accepting
# ---------
# Each connection gets the next id, from 1, as in Redis (CLIENT ID): the
# count of connections taken (Tally) waits in a channel the listeners and
# the connections share.

@unsafe
def conn_start(s: Socket, db: Chan(Req), post: Bool, tl: Chan(Tally), +id: Nat) -> IO(Unit):
  do IO<Unit>:
    back : Chan(Ans) <- Chan.new(Ans, 1)
    conn_loop(s, SNil{}, Nil{}, 0n, 1n, Link{db, back, post, tl, id}, S.conn_new(id))

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

def live.of(t: U32 & U32, +ps: String, +ts: String, +sm: String, c: Tally) -> I.Live:
  (secs, us) = t
  match c:
    case Tally{taken, open}:
      I.ILive{secs, us, stat.field(ps, 11n), stat.field(ps, 12n), stat.field(ts, 11n), stat.field(ts, 12n), Nat.mul(nat.of(nth(1n, words.of(sm))), 4096n), taken, open, 0n, 0n}

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

def boot.of(+o1: String, +o2: String, +o3: String, +mem: String, +sm: String, run: String, rep: String, t: U32 & U32, +pid: U32, exe: String, conf: String) -> I.Boot:
  (secs, us) = t
  I.IBoot{T.trim(o1) ++ " " ++ T.trim(o2) ++ " " ++ T.trim(o3), U32.show(pid), run, rep, exe, conf, Nat.mul(nat.of(nth(1n, words.of(T.first(String.split(mem, '\n'))))), 1024n), secs, Nat.mul(nat.of(nth(1n, words.of(sm))), 4096n)}

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
    c : Tally <- tally.peek(tl)
    return live.of(t, ps, ts, sm, c)

# the facts of the start: the program's and the configuration file's
# absolute paths come from the start's own reading
@unsafe
def boot.read(+pid: U32, +exe: String, +conf: String) -> IO(I.Boot):
  do IO<I.Boot>:
    o1 : String <- proc.text("/proc/sys/kernel/ostype")
    o2 : String <- proc.text("/proc/sys/kernel/osrelease")
    o3 : String <- proc.text("/proc/sys/kernel/arch")
    mem : String <- proc.text("/proc/meminfo")
    sm : String <- proc.text("/proc/self/statm")
    run : String <- hex40()
    rep : String <- hex40()
    t : U32 & U32 <- IO.clock()
    return boot.of(o1, o2, o3, mem, sm, run, rep, t, pid, exe, conf)

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
# is written after a SELECT of its own, aof.bend) and the clients that
# wait.
type St is Data:
  St{srv: S.Srv, ds: R.Ds, sel: Nat, ws: Waits, tx: Tx}

@unsafe
def aof_loop(st: St, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  do IO<Unit>:
    m : Maybe<&1, Req> <- Chan.recv(Req, reqs)
    aof_more(st, f, sync, reqs, m)

def st.sel(+st: St) -> Nat:
  match st:
    case St{srv, ds, +sel, ws, tx}:
      sel

# the group's first request held in a list while the others are taken:
# a request travels flat, in as many registers as its widest form, and
# a function's registers are the widest function's
@unsafe
def aof_take(qs: List<&1, Req>, st: St, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  match st:
    case St{srv, ds, +sel, ws, tx}:
      do IO<Unit>:
        more : List<&1, Req> <- Chan.drain(Req, reqs, group_max())
        t : U32 & U32 <- IO.clock()
        aof_group(grp.end(group_run(True{}, List.append(&1, Req, qs, more), Grp{Nil{}, Nil{}, srv, R.ds.at(clock.ms(t), ds), ws, Nil{}, tx})), sel, f, sync, reqs)

@unsafe
def aof_more(st: St, f: File, +sync: Sync, +reqs: Chan(Req), m: Maybe<&1, Req>) -> IO(Unit):
  match m:
    case None{}:
      File.close(f)
    case Some{q}:
      aof_take([q], st, f, sync, reqs)

@unsafe
def aof_group(g: Grp, +sel: Nat, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  match g:
    case Grp{outs, es, srv, ds, ws, up, tx}:
      aof_put(List.reverse(&2, Sigma<&2, &2, Chan(Ans), _ => Ans>, outs), List.reverse(&2, A.Ent, es), St{srv, ds, sel, ws, tx}, f, sync, reqs)

# the bytes appended to the file, for INFO, and the database the file has
# selected after them
def st.aof(st: St, +n: Nat, +sel: Nat) -> St:
  match st:
    case St{srv, ds, old, ws, tx}:
      St{S.srv.aof(srv, n), ds, sel, ws, tx}

@unsafe
def aof_write(outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, +es: List<&2, A.Ent>, st: St, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  +x = st
  +sel = st.sel(x)
  +bytes = A.encode(A.ents.args(es, sel))
  do IO<Unit>:
    p : File & Result<&1, &1, U32 & String, Unit> <- File.write_raw(f, bytes)
    aof_wrote(p, outs, st.aof(x, String.length(bytes), A.ents.sel(es, sel)), sync, reqs)

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

@unsafe
def aof_reply(outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, st: St, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  do IO<Unit>:
    Unit <- Chan.send_all(Ans, outs)
    aof_loop(st, f, sync, reqs)

# everysec: the file synced each second, through a handle of its own
@unsafe
def sync_loop(f: File) -> IO(Unit):
  do IO<Unit>:
    Unit <- IO.sleep(1000)
    p : File & Result<&1, &1, U32 & String, Unit> <- File.sync(f)
    sync_next(p)

# a failed sync stops the server, as with always: the writes it
# acknowledged may not be on the disk, and the kernel may have dropped
# them, so a later sync that succeeds would not show it
@unsafe
def sync_next(p: File & Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  (f, r) = p
  match r:
    case Fail{e}:
      IO.die(Unit, 1, aof_fail(e))
    case Done{u}:
      sync_loop(f)

@unsafe
def syncer(sync: Sync, path: String) -> IO(Unit):
  match sync:
    case EverySec{}:
      do IO<Unit>:
        f : File <- IO.try(File, File.open(path, "a"))
        IO.spawn(Unit, sync_loop(f))
    case Always{}:
      IO.pure(Unit, Unit{})
    case Never{}:
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
    case P.Batch{reqs, tl, rest, err, need}:
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
def st.new(srv: S.Srv, ds: R.Ds) -> St:
  +x = ds
  St{srv, x, R.ds.index(x), WaitNone{}, TxNone{}}

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
def open_aof(+path: String, +sync: Sync, srv: S.Srv, ds: R.Ds, +lg: Log) -> IO(Chan(Req)):
  do IO<Chan(Req)>:
    f : File <- IO.try(File, File.open(path, "a"))
    r : Result<&1, &1, U32 & String, Unit> <- File.sync_dir(path)
    Unit <- dir_synced(r, path, lg)
    Unit <- syncer(sync, path)
    +reqs : Chan(Req) <- Chan.new(Req, 1024)
    Unit <- IO.spawn(Unit, aof_loop(st.new(srv, ds), f, sync, reqs))
    return reqs

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

@unsafe
def accept_all(ls: List<&1, Listener>, +reqs: Chan(Req), +post: Bool, +lg: Log, +tl: Chan(Tally)) -> IO(Unit):
  do IO<Unit>:
    Unit <- IO.spawn(Unit, cron(reqs))
    Unit <- accept_each(ls, reqs, post, tl)
    log(lg, 2, "Ready to accept connections")

@unsafe
def serve.aof(p: R.Ds & Nat, +path: String, +sync: Sync, +items: List<&2, C.CItem>, info: I.Info, ls: List<&1, Listener>, +post: Bool, +lg: Log, +tl: Chan(Tally)) -> IO(Unit):
  (ds, +size) = p
  do IO<Unit>:
    +reqs : Chan(Req) <- open_aof(path, sync, S.srv_of(items, I.info.restored(info, size)), ds, lg)
    accept_all(ls, reqs, post, lg, tl)

# the databases after the first (databases less one)
def dbs.more(+items: List<&2, C.CItem>) -> Nat:
  Nat.sub(S.srv.dbs.of(R.int_read(C.config.get_value(items, "databases"))), 1n)

@unsafe
def serve(aof: Maybe<&2, String>, ls: List<&1, Listener>, +post: Bool, +sync: Sync, +trunc: Bool, +items: List<&2, C.CItem>, info: I.Info, +lg: Log, +tl: Chan(Tally)) -> IO(Unit):
  match aof:
    case None{}:
      do IO<Unit>:
        +reqs : Chan(Req) <- Chan.new(Req, 1024)
        Unit <- IO.spawn(Unit, db_loop(S.srv_of(items, info), R.ds.empty(dbs.more(items)), WaitNone{}, TxNone{}, reqs))
        accept_all(ls, reqs, post, lg, tl)
    case Some{+path}:
      do IO<Unit>:
        p : R.Ds & Nat <- restore(lg, trunc, path, dbs.more(items))
        serve.aof(p, path, sync, items, info, ls, post, lg, tl)

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
# it: an RDB file (when the data is not in an append-only file), or
# Redis 7's multi-part append-only file (its manifest)
@unsafe
def data.check(checks: Bool, +aof: Bool, +items: List<&2, C.CItem>, +lg: Log) -> IO(Unit):
  match checks aof:
    case False{} _:
      IO.pure(Unit, Unit{})
    case True{} True{}:
      refuse.if_there(T.cfg(items, "appenddirname") ++ "/" ++ T.cfg(items, "appendfilename") ++ ".manifest",
        "BendKV cannot read Redis 7's multi-part append-only files yet: " ++ T.cfg(items, "dir") ++ "/" ++ T.cfg(items, "appenddirname") ++ " holds one", lg)
    case True{} False{}:
      refuse.if_there(T.cfg(items, "dbfilename"),
        "BendKV cannot load RDB files yet: " ++ T.cfg(items, "dir") ++ "/" ++ T.cfg(items, "dbfilename") ++ " would be left out; move it away, or keep the data in an append-only file (appendonly yes)", lg)

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
# checks: the data checks (not in the short form); mod and mcfg: what
# startup.bend found of modules
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
    serve(aof, ls, post, sync, String.eq(T.cfg(items, "aof-load-truncated"), "yes"), items, info, lm, tl)

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
