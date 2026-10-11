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

# a batch from a connection in the state cn (B.Job: its commands, and
# the hashes of their keys, for the hints of batch.bend), and the channel
# its answer goes back on
type Req is Data:
  Req{cn: S.Conn, job: B.Job, back: Chan(Ans)}

# a batch's answer: its replies, encoded (none when CLIENT REPLY held
# them all back), and the connection's state after it
type Ans is Data:
  Ans{out: Maybe<&2, String>, cn: S.Conn}

def ans_of(rs: List<&2, R.Reply>, cn: S.Conn) -> Ans:
  match rs:
    case Nil{}:
      Ans{None{}, cn}
    case Con{r, rest}:
      Ans{Some{P.encode_all(r <> rest)}, cn}

# The database actor
# ------------------

# The actor takes a request, and with it those that came meanwhile
# (Chan.drain, up to group_max): it runs their batches one after another,
# in the order they came (S.run: session.bend), and answers them all at
# once (Chan.send_all). A group is its answers so far, newest first, the
# server's state and the database.
type Run is Data:
  Run{outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, srv: S.Srv, db: KV.Trie<String>}

def group_max() -> U32:
  255

def run_put(outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, back: Chan(Ans), d: S.Fin) -> Run:
  match d:
    case S.Fin{rs, cn, srv, db}:
      Run{(back, ans_of(rs, cn)) <> outs, srv, db}

def run_req(q: Req, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, srv: S.Srv, db: KV.Trie<String>) -> Run:
  match q:
    case Req{cn, job, back}:
      run_put(outs, back, S.run(cn, srv, job, db))

def run_step(q: Req, g: Run) -> Run:
  match g:
    case Run{outs, srv, db}:
      run_req(q, outs, srv, db)

def run_group(qs: List<&1, Req>, g: Run) -> Run:
  match qs:
    case Nil{}:
      g
    case Con{q, rest}:
      run_group(rest, run_step(q, g))

@unsafe
def db_loop(srv: S.Srv, db: KV.Trie<String>, +reqs: Chan(Req)) -> IO(Unit):
  do IO<Unit>:
    m : Maybe<&1, Req> <- Chan.recv(Req, reqs)
    db_serve(srv, db, reqs, m)

@unsafe
def db_serve(srv: S.Srv, db: KV.Trie<String>, +reqs: Chan(Req), m: Maybe<&1, Req>) -> IO(Unit):
  match m:
    case None{}:
      IO.pure(Unit, Unit{})
    case Some{q}:
      do IO<Unit>:
        more : List<&1, Req> <- Chan.drain(Req, reqs, group_max())
        db_group(run_group(q <> more, Run{Nil{}, srv, db}), reqs)

@unsafe
def db_group(g: Run, +reqs: Chan(Req)) -> IO(Unit):
  match g:
    case Run{outs, srv, db}:
      do IO<Unit>:
        Unit <- Chan.send_all(Ans, List.reverse(&2, Sigma<&2, &2, Chan(Ans), _ => Ans>, outs))
        db_loop(srv, db, reqs)

# Connections
# -----------

# a batch to send: the parsed requests (newest first) put in order
def batch_req(cn: S.Conn, rs: List<&2, B.Req>, back: Chan(Ans)) -> Req:
  Req{cn, B.job(B.unzip(rs, Nil{}, Nil{})), back}

def sent_ok(m: Socket & Result<&1, &1, U32 & String, Unit>, next: Socket -> IO(Unit)) -> IO(Unit):
  (s, r) = m
  match r:
    case Done{u}:
      next(s)
    case Fail{e}:
      Socket.close(s)

# str out on s, then next: posted (TCP.post: the loop hands it to its
# writer thread and goes on, and a dead peer shows on the next read), or
# sent from the loop
def put_out(s: Socket, post: Bool, str: String, next: Socket -> IO(Unit)) -> IO(Unit):
  match post:
    case True{}:
      do IO<Unit>:
        s2 : Socket <- TCP.post(s, str)
        next(s2)
    case False{}:
      do IO<Unit>:
        m : Socket & Result<&1, &1, U32 & String, Unit> <- TCP.send_raw(s, str)
        sent_ok(m, next)

# a connection's way to the actor: the actor's channel, the channel its
# answers come back on, and whether replies are posted
type Link is Data:
  Link{db: Chan(Req), back: Chan(Ans), post: Bool}

def link.post(+ln: Link) -> Bool:
  match ln:
    case Link{db, back, post}:
      post

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
      Socket.close(s)
    case Done{+x}:
      conn_data(s, Nat.is_eq(String.length(x), 0n), x, rest, got, have, need, ln, cn)

@unsafe
def conn_data(s: Socket, eof: Bool, +x: String, rest: String, got: List<&2, String>, have: Nat, +need: Nat, +ln: Link, cn: S.Conn) -> IO(Unit):
  match eof:
    case True{}:
      Socket.close(s)
    case False{}:
      +h = Nat.add(have, count_upto(need, x))
      conn_more(s, rest, x <> got, h, need, ln, cn, Nat.is_lt(h, need))

@unsafe
def conn_more(s: Socket, rest: String, got: List<&2, String>, have: Nat, need: Nat, +ln: Link, cn: S.Conn, wait: Bool) -> IO(Unit):
  match wait:
    case True{}:
      conn_loop(s, rest, got, have, need, ln, cn)
    case False{}:
      conn_batch(s, parse_in(rest, got), ln, cn)

# A parsed batch goes to the actor, its replies go out, then the
# protocol error the requests ended in, if any, and the next read: rest
# is the unparsed tail and need the bytes it needs, and cn the
# connection's state, as the actor gave it back. These steps call each
# other and conn_loop directly, as the loop's own steps do, rather than
# through a continuation.
@unsafe
def conn_batch(s: Socket, batch: P.Batch, +ln: Link, cn: S.Conn) -> IO(Unit):
  match batch:
    case P.Batch{reqs, rest, err, need}:
      conn_send(s, ln, cn, reqs, err, rest, need)

@unsafe
def conn_send(s: Socket, +ln: Link, cn: S.Conn, reqs: List<&2, B.Req>, err: Maybe<&2, String>, rest: String, need: Nat) -> IO(Unit):
  match reqs:
    case Nil{}:
      conn_err(s, ln, cn, err, rest, need)
    case Con{r, rs}:
      conn_ask(s, ln, cn, r <> rs, err, rest, need)

@unsafe
def conn_ask(s: Socket, +ln: Link, cn: S.Conn, rs: List<&2, B.Req>, err: Maybe<&2, String>, rest: String, need: Nat) -> IO(Unit):
  match ln:
    case Link{db, +back, post}:
      do IO<Unit>:
        sent : Bool <- Chan.send(Req, db, batch_req(cn, rs, back))
        got : Maybe<&1, Ans> <- Chan.recv(Ans, back)
        conn_ans(s, ln, got, err, rest, need)

@unsafe
def conn_ans(s: Socket, +ln: Link, got: Maybe<&1, Ans>, err: Maybe<&2, String>, rest: String, need: Nat) -> IO(Unit):
  match got:
    case None{}:
      Socket.close(s)
    case Some{Ans{None{}, cn}}:
      conn_quit(s, ln, cn, err, rest, need)
    case Some{Ans{Some{out}, cn}}:
      conn_put(s, ln, link.post(ln), out, cn, err, rest, need)

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
      Socket.close(s)
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
      Socket.close(s)
    case False{}:
      conn_err(s, ln, cn, err, rest, need)

# a protocol error is answered, then the connection closes, as in Redis;
# without one, the connection reads on
@unsafe
def conn_err(s: Socket, +ln: Link, cn: S.Conn, err: Maybe<&2, String>, rest: String, need: Nat) -> IO(Unit):
  match err:
    case None{}:
      conn_loop(s, rest, Nil{}, 0n, need, ln, cn)
    case Some{msg}:
      put_out(s, link.post(ln), "-ERR " ++ msg ++ "\r\n", s2 => Socket.close(s2))

# Accepting
# ---------
# Each connection gets the next id, from 1, as in Redis (CLIENT ID): the
# next one waits in a channel the listeners share.

@unsafe
def conn_start(s: Socket, db: Chan(Req), post: Bool, id: Nat) -> IO(Unit):
  do IO<Unit>:
    back : Chan(Ans) <- Chan.new(Ans, 1)
    conn_loop(s, SNil{}, Nil{}, 0n, 1n, Link{db, back, post}, S.conn_new(id))

@unsafe
def next_id(m: Maybe<&1, Nat>, +ids: Chan(Nat)) -> IO(Nat):
  match m:
    case Some{+id}:
      do IO<Nat>:
        ok : Bool <- Chan.send(Nat, ids, 1n+id)
        return id
    case None{}:
      IO.pure(Nat, 0n)

@unsafe
def accept_next(m: Listener & Result<&1, &1, U32 & String, Socket>, +db: Chan(Req), +post: Bool, +ids: Chan(Nat)) -> IO(Listener):
  (l, r) = m
  match r:
    case Done{s}:
      do IO<Listener>:
        g : Maybe<&1, Nat> <- Chan.recv(Nat, ids)
        id : Nat <- next_id(g, ids)
        IO.spawn(Unit, conn_start(s, db, post, id))
        return l
    case Fail{e}:
      IO.pure(Listener, l)

@unsafe
def accept_loop(l: Listener, +db: Chan(Req), +post: Bool, +ids: Chan(Nat)) -> IO(Unit):
  do IO<Unit>:
    m : Listener & Result<&1, &1, U32 & String, Socket> <- TCP.accept(l)
    l2 : Listener <- accept_next(m, db, post, ids)
    accept_loop(l2, db, post, ids)

@unsafe
def accept_each(ls: List<&1, Listener>, +db: Chan(Req), +post: Bool, +ids: Chan(Nat)) -> IO(Unit):
  match ls:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{l, rest}:
      do IO<Unit>:
        IO.spawn(Unit, accept_loop(l, db, post, ids))
        accept_each(rest, db, post, ids)

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
# database from the file (LAWS.bend: recover). A file that ends inside an
# entry, cut by a crash in the middle of a write, is cut back to its last
# whole entry, as Redis does with aof-load-truncated; a file with anything
# else after its entries is refused, as Redis refuses it.

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

# The actor takes a group of requests, as the actor without a file does:
# it runs their batches one after another (S.run_log: session.bend),
# appends the effects of them all at once, syncs once, and answers them
# all at once, as Redis does in each turn of its loop. A group is its
# answers so far, newest first, the effects so far, each batch's in front
# of the ones before reversed, and the state: the server's and the
# database.
type St is Data:
  St{srv: S.Srv, db: KV.Trie<String>}

type Grp is Data:
  Grp{outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, R.Cmd>, st: St}

def group_put(outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, R.Cmd>, back: Chan(Ans), d: S.Logged) -> Grp:
  match d:
    case S.Logged{rs, e, cn, srv, db}:
      Grp{(back, ans_of(rs, cn)) <> outs, List.reverse.go(&2, R.Cmd, e, es), St{srv, db}}

def group_req(q: Req, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, R.Cmd>, st: St) -> Grp:
  match q st:
    case Req{cn, job, back} St{srv, db}:
      group_put(outs, es, back, S.run_log(cn, srv, job, db))

def group_step(q: Req, g: Grp) -> Grp:
  match g:
    case Grp{outs, es, st}:
      group_req(q, outs, es, st)

def group_run(qs: List<&1, Req>, g: Grp) -> Grp:
  match qs:
    case Nil{}:
      g
    case Con{q, rest}:
      group_run(rest, group_step(q, g))

@unsafe
def aof_loop(st: St, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  do IO<Unit>:
    m : Maybe<&1, Req> <- Chan.recv(Req, reqs)
    aof_more(st, f, sync, reqs, m)

@unsafe
def aof_more(st: St, f: File, +sync: Sync, +reqs: Chan(Req), m: Maybe<&1, Req>) -> IO(Unit):
  match m:
    case None{}:
      File.close(f)
    case Some{q}:
      do IO<Unit>:
        more : List<&1, Req> <- Chan.drain(Req, reqs, group_max())
        aof_group(group_run(q <> more, Grp{Nil{}, Nil{}, st}), f, sync, reqs)

@unsafe
def aof_group(g: Grp, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  match g:
    case Grp{outs, es, st}:
      aof_put(List.reverse(&2, Sigma<&2, &2, Chan(Ans), _ => Ans>, outs), List.reverse(&2, R.Cmd, es), st, f, sync, reqs)

@unsafe
def aof_put(outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, R.Cmd>, st: St, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  match es:
    case Nil{}:
      aof_reply(outs, st, f, sync, reqs)
    case Con{e, more}:
      do IO<Unit>:
        p : File & Result<&1, &1, U32 & String, Unit> <- File.write_raw(f, A.encode(A.args_all(e <> more)))
        aof_wrote(p, outs, st, sync, reqs)

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
    case P.Batch{reqs, rest, err, need}:
      Bool.and(List.is_empty(&2, B.Req, reqs), Maybe.is_none(&2, String, err))

def cut_short(s: String) -> Bool:
  match s:
    case SCon{'*', t}:
      cut_short.of(P.parse(SCon{'*', t}))
    case _:
      False{}

def restored(+n: Nat, +db: KV.Trie<String>, +path: String) -> String:
  "BendKV restored " ++ Nat.show(KV.size(String, db)) ++ " keys from " ++ Nat.show(n) ++ " entries of " ++ path

@unsafe
def cut_done(+lg: Log, p: File & Result<&1, &1, U32 & String, Unit>, +path: String, +cut: Nat) -> IO(Unit):
  (f, r) = p
  match r:
    case Fail{e}:
      IO.die(Unit, 1, aof_fail(e))
    case Done{u}:
      do IO<Unit>:
        Unit <- File.close(f)
        log(lg, 3, "BendKV cut " ++ Nat.show(cut) ++ " bytes of an entry cut short from the end of " ++ path)

@unsafe
def cut_file(+lg: Log, +path: String, keep: Nat, +cut: Nat) -> IO(Unit):
  do IO<Unit>:
    f : File <- IO.try(File, File.open(path, "a"))
    p : File & Result<&1, &1, U32 & String, Unit> <- File.truncate(f, U32.from_nat(keep))
    cut_done(lg, p, path, cut)

# a file that ends in an entry cut short is cut back to its last whole
# entry, unless aof-load-truncated is no: then it stops the start, as in
# Redis
@unsafe
def restore_cut(trunc: Bool, +lg: Log, +path: String, +size: Nat, +n: Nat, +db: KV.Trie<String>, +rest: String) -> IO(KV.Trie<String>):
  match trunc:
    case True{}:
      do IO<KV.Trie<String>>:
        Unit <- cut_file(lg, path, Nat.sub(size, String.length(rest)), String.length(rest))
        Unit <- log(lg, 2, restored(n, db, path))
        return db
    case False{}:
      log.die(KV.Trie<String>, lg, "Unexpected end of file reading the append only file " ++ path ++ ". You can: 1) Make a backup of your AOF file, then use ./redis-check-aof --fix <filename>. 2) Alternatively you can set the 'aof-load-truncated' configuration option to yes and restart the server.")

# the database of the entries, once the file is fit to append to: whole,
# or cut back to its last whole entry
@unsafe
def restore_fix(+lg: Log, +trunc: Bool, +path: String, +size: Nat, +n: Nat, +db: KV.Trie<String>, +rest: String, whole: Bool, cut: Bool) -> IO(KV.Trie<String>):
  match whole cut:
    case True{} _:
      do IO<KV.Trie<String>>:
        Unit <- log(lg, 2, restored(n, db, path))
        return db
    case False{} True{}:
      restore_cut(trunc, lg, path, size, n, db, rest)
    case False{} False{}:
      log.die(KV.Trie<String>, lg, "Bad file format reading the append only file " ++ path ++ ": no entry at byte " ++ Nat.show(Nat.sub(size, String.length(rest))))

@unsafe
def restore_load(+lg: Log, +trunc: Bool, +path: String, +size: Nat, l: List<&2, List<&2, String>> & String) -> IO(KV.Trie<String>):
  (+reqs, +rest) = l
  restore_fix(lg, trunc, path, size, List.length(&2, List<&2, String>, reqs), A.replay(reqs), rest, String.is_empty(rest), cut_short(rest))

@unsafe
def restore_read(+lg: Log, +trunc: Bool, +path: String, p: File & String) -> IO(KV.Trie<String>):
  (f, +s) = p
  do IO<KV.Trie<String>>:
    Unit <- File.close(f)
    restore_load(lg, trunc, path, String.length(s), A.load(s))

# ENOENT: the one failure to open a file that means it is not there
def enoent() -> U32:
  2

def open_fail(+path: String, msg: String) -> String:
  "Can't open the append-only file " ++ path ++ ": " ++ msg

# a file not there is an empty database; any other failure to open it (no
# permission, an I/O error, no descriptor left) stops the start: serving
# an empty database would append to a file that holds another
@unsafe
def restore_none(none: Bool, +lg: Log, +path: String, msg: String) -> IO(KV.Trie<String>):
  match none:
    case True{}:
      IO.pure(KV.Trie<String>, KV.empty(String))
    case False{}:
      log.die(KV.Trie<String>, lg, open_fail(path, msg))

@unsafe
def restore_fail(+lg: Log, +path: String, e: U32 & String) -> IO(KV.Trie<String>):
  (code, msg) = e
  restore_none(U32.is_eq(code, enoent()), lg, path, msg)

@unsafe
def restore_open(+lg: Log, +trunc: Bool, +path: String, m: Result<&1, &1, U32 & String, File>) -> IO(KV.Trie<String>):
  match m:
    case Fail{e}:
      restore_fail(lg, path, e)
    case Done{f}:
      do IO<KV.Trie<String>>:
        p : File & String <- read_all(f, Nil{})
        restore_read(lg, trunc, path, p)

# the database a file holds; none for a file not there yet
@unsafe
def restore(+lg: Log, +trunc: Bool, +path: String) -> IO(KV.Trie<String>):
  do IO<KV.Trie<String>>:
    m : Result<&1, &1, U32 & String, File> <- File.open(path, "r")
    restore_open(lg, trunc, path, m)

# the actor appending to the file, on the database the file held
@unsafe
def open_aof(+path: String, +sync: Sync, srv: S.Srv, db: KV.Trie<String>) -> IO(Chan(Req)):
  do IO<Chan(Req)>:
    f : File <- IO.try(File, File.open(path, "a"))
    Unit <- syncer(sync, path)
    +reqs : Chan(Req) <- Chan.new(Req, 1024)
    Unit <- IO.spawn(Unit, aof_loop(St{srv, db}, f, sync, reqs))
    return reqs

# Serving
# -------
# The actor on its database (restored from the append-only file, with
# one), then a loop on each listener; then the server is ready.

@unsafe
def accept_all(ls: List<&1, Listener>, +reqs: Chan(Req), +post: Bool, +lg: Log) -> IO(Unit):
  do IO<Unit>:
    +ids : Chan(Nat) <- Chan.new(Nat, 1)
    ok : Bool <- Chan.send(Nat, ids, 1n)
    Unit <- accept_each(ls, reqs, post, ids)
    log(lg, 2, "Ready to accept connections")

@unsafe
def serve(aof: Maybe<&2, String>, ls: List<&1, Listener>, +post: Bool, +sync: Sync, +trunc: Bool, srv: S.Srv, +lg: Log) -> IO(Unit):
  match aof:
    case None{}:
      do IO<Unit>:
        +reqs : Chan(Req) <- Chan.new(Req, 1024)
        Unit <- IO.spawn(Unit, db_loop(srv, KV.empty(String), reqs))
        accept_all(ls, reqs, post, lg)
    case Some{+path}:
      do IO<Unit>:
        db : KV.Trie<String> <- restore(lg, trunc, path)
        reqs : Chan(Req) <- open_aof(path, sync, srv, db)
        accept_all(ls, reqs, post, lg)

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

# the server as the configuration asks: up to listening, then serving;
# checks: the data checks (not in the short form); mod and mcfg: what
# startup.bend found of modules
@unsafe
def run(+items: List<&2, C.CItem>, +post: Bool, +aof: Maybe<&2, String>, +sync: Sync, +bare: Bool, +prog: String, +pid: U32, +checks: Bool, +mod: String, +mcfg: Bool) -> IO(Unit):
  +lg = log.of(items, pid)
  +lm = log.up(log.of(items, pid))
  +port = port_or(T.cfg(items, "port"))
  do IO<Unit>:
    up : Result<&1, &1, U32 & String, String> <- IO.get_env("UPSTART_JOB")
    sd : Result<&1, &1, U32 & String, String> <- IO.get_env("NOTIFY_SOCKET")
    Unit <- start.sup(T.sup.kind(T.cfg(items, "supervised"), env.set(up), env.set(sd)), lg)
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
    serve(aof, ls, post, sync, String.eq(T.cfg(items, "aof-load-truncated"), "yes"), S.srv_of(C.items.put(items, "databases", "1")), lm)

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
        d : Result<&1, &1, U32 & String, String> <- IO.cwd()
        run(S.srv.puts(start_sets(port, env_or(d), aof, sync), C.config.table()), Maybe.default(&2, Bool, post, post_default(cpus)), aof, sync, False{}, prog, pid, False{}, "", False{})

# The configuration
# -----------------
# Read as Redis reads it (startup.bend): the file, then the standard input
# with "-", then the options; a dir line changes the directory at once,
# and an include reads its file then and there.

# the bytes of a file, up to the first read that fails or comes back
# empty (Redis reads a directory as an empty file)
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
    p : File & Result<&1, &1, U32 & String, String> <- File.read_raw(f, 16777216)
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
def conf.ready(st: T.Load, +dir: String, cpus: U32, +bare: Bool, +prog: String, +pid: U32) -> IO(Unit):
  match st:
    case T.Load{+items, saved, reading, io, +mod, +mcfg}:
      run(C.items.put(items, "dir", dir), conf.post(io, items, cpus), conf.aof(items), sync_or(T.cfg(items, "appendfsync")), bare, prog, pid, True{}, mod, mcfg)

@unsafe
def start.conf(file: Maybe<&2, String>, stdin: Bool, +opts: String, +bare: Bool, cpus: U32, +prog: String, +pid: U32) -> IO(Unit):
  +lg = log.boot(pid)
  do IO<Unit>:
    c : Result<&1, &1, U32 & String, String> <- IO.cwd()
    text : String <- conf.text(file, stdin, opts, env_or(c), lg)
    st : T.Load <- conf.all(bare, text, lg)
    d : Result<&1, &1, U32 & String, String> <- IO.cwd()
    conf.ready(st, env_or(d), cpus, bare, prog, pid)

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
