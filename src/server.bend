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
# Replies go out in one of two ways (the second argument): post hands them
# to the loop's writer thread (TCP.post), which sends them on a core of
# its own while the loop goes on; send sends them from the loop itself
# (TCP.send_raw). A writer pays when it has a core to itself, so the
# default is post when the process may use two cores or more
# (IO.thread_count), and send otherwise.
#
# With an append-only file (the third argument), the actor also appends
# what each batch did to the file before it answers. When the server
# starts, it restores its database from the file (aof.bend and the
# Persistence laws).
#
#   bend src/server.bend -o bendkv && ./bendkv 6380 [post|send [file [always|everysec|no]]]
#   redis-cli -p 6380 set foo bar

import Base
import ./map.bend as KV
import ./redis.bend as R
import ./resp.bend as P
import ./batch.bend as B
import ./aof.bend as A
import ./session.bend as S
import ./config.bend as C

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
# Each connection gets the next id, from 1, as in Redis (CLIENT ID).

@unsafe
def conn_start(s: Socket, db: Chan(Req), post: Bool, id: Nat) -> IO(Unit):
  do IO<Unit>:
    back : Chan(Ans) <- Chan.new(Ans, 1)
    conn_loop(s, SNil{}, Nil{}, 0n, 1n, Link{db, back, post}, S.conn_new(id))

@unsafe
def accept_next(m: Listener & Result<&1, &1, U32 & String, Socket>, +db: Chan(Req), +post: Bool, id: Nat) -> IO(Listener):
  (l, r) = m
  match r:
    case Done{s}:
      do IO<Listener>:
        IO.spawn(Unit, conn_start(s, db, post, id))
        return l
    case Fail{e}:
      IO.pure(Listener, l)

@unsafe
def accept_loop(l: Listener, +db: Chan(Req), +post: Bool, +id: Nat) -> IO(Unit):
  do IO<Unit>:
    m : Listener & Result<&1, &1, U32 & String, Socket> <- TCP.accept(l)
    l2 : Listener <- accept_next(m, db, post, id)
    accept_loop(l2, db, post, 1n+id)

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
def cut_file(+path: String, keep: Nat, +cut: Nat) -> IO(Unit):
  do IO<Unit>:
    f : File <- IO.try(File, File.open(path, "a"))
    p : File & Result<&1, &1, U32 & String, Unit> <- File.truncate(f, U32.from_nat(keep))
    cut_done(p, path, cut)

@unsafe
def cut_done(p: File & Result<&1, &1, U32 & String, Unit>, +path: String, +cut: Nat) -> IO(Unit):
  (f, r) = p
  match r:
    case Fail{e}:
      IO.die(Unit, 1, aof_fail(e))
    case Done{u}:
      do IO<Unit>:
        Unit <- File.close(f)
        IO.print("BendKV cut " ++ Nat.show(cut) ++ " bytes of an entry cut short from the end of " ++ path)

# the database of the entries, once the file is fit to append to: whole,
# or cut back to its last whole entry
@unsafe
def restore_fix(+path: String, +size: Nat, +n: Nat, +db: KV.Trie<String>, +rest: String, whole: Bool, cut: Bool) -> IO(KV.Trie<String>):
  match whole cut:
    case True{} _:
      do IO<KV.Trie<String>>:
        Unit <- IO.print(restored(n, db, path))
        return db
    case False{} True{}:
      do IO<KV.Trie<String>>:
        Unit <- cut_file(path, Nat.sub(size, String.length(rest)), String.length(rest))
        Unit <- IO.print(restored(n, db, path))
        return db
    case False{} False{}:
      IO.die(KV.Trie<String>, 1, "Bad file format reading the append only file " ++ path ++ ": no entry at byte " ++ Nat.show(Nat.sub(size, String.length(rest))))

@unsafe
def restore_load(+path: String, +size: Nat, l: List<&2, List<&2, String>> & String) -> IO(KV.Trie<String>):
  (+reqs, +rest) = l
  restore_fix(path, size, List.length(&2, List<&2, String>, reqs), A.replay(reqs), rest, String.is_empty(rest), cut_short(rest))

@unsafe
def restore_read(+path: String, p: File & String) -> IO(KV.Trie<String>):
  (f, +s) = p
  do IO<KV.Trie<String>>:
    Unit <- File.close(f)
    restore_load(path, String.length(s), A.load(s))

# ENOENT: the one failure to open a file that means it is not there
def enoent() -> U32:
  2

def open_fail(+path: String, msg: String) -> String:
  "Can't open the append-only file " ++ path ++ ": " ++ msg

# a file not there is an empty database; any other failure to open it (no
# permission, an I/O error, no descriptor left) stops the start: serving
# an empty database would append to a file that holds another
@unsafe
def restore_none(none: Bool, +path: String, msg: String) -> IO(KV.Trie<String>):
  match none:
    case True{}:
      IO.pure(KV.Trie<String>, KV.empty(String))
    case False{}:
      IO.die(KV.Trie<String>, 1, open_fail(path, msg))

@unsafe
def restore_fail(+path: String, e: U32 & String) -> IO(KV.Trie<String>):
  (code, msg) = e
  restore_none(U32.is_eq(code, enoent()), path, msg)

@unsafe
def restore_open(+path: String, m: Result<&1, &1, U32 & String, File>) -> IO(KV.Trie<String>):
  match m:
    case Fail{e}:
      restore_fail(path, e)
    case Done{f}:
      do IO<KV.Trie<String>>:
        p : File & String <- read_all(f, Nil{})
        restore_read(path, p)

# the database a file holds; none for a file not there yet
@unsafe
def restore(+path: String) -> IO(KV.Trie<String>):
  do IO<KV.Trie<String>>:
    m : Result<&1, &1, U32 & String, File> <- File.open(path, "r")
    restore_open(path, m)

# the actor appending to the file, on the database the file held
@unsafe
def open_aof(+path: String, +sync: Sync, srv: S.Srv, db: KV.Trie<String>) -> IO(Chan(Req)):
  do IO<Chan(Req)>:
    f : File <- IO.try(File, File.open(path, "a"))
    Unit <- syncer(sync, path)
    +reqs : Chan(Req) <- Chan.new(Req, 1024)
    Unit <- IO.spawn(Unit, aof_loop(St{srv, db}, f, sync, reqs))
    return reqs

@unsafe
def serve_aof(+port: U32, +post: Bool, +path: String, +sync: Sync, srv: S.Srv) -> IO(Unit):
  do IO<Unit>:
    db : KV.Trie<String> <- restore(path)
    reqs : Chan(Req) <- open_aof(path, sync, srv, db)
    l : Listener <- IO.try(Listener, TCP.listen("127.0.0.1", port))
    IO.print("BendKV listening on 127.0.0.1:" ++ U32.show(port) ++ " (" ++ post_note(post) ++ ", append-only file " ++ path ++ ", fsync " ++ sync_note(sync) ++ ")")
    accept_loop(l, reqs, post, 1n)

# Main
# ----

# the port (the first argument, default 6380), whether replies are posted
# (the second, post or send; none for the default), and the append-only
# file (the third, none by default) with how it is synced (the fourth:
# always, everysec or no; everysec by default)
type Opts is Data:
  Opts{port: U32, post: Maybe<&2, Bool>, aof: Maybe<&2, String>, sync: Sync}

def port_or(p: String) -> U32:
  Maybe.default(&2, U32, U32.read(p), 6380)

def post_or(+m: String) -> Maybe<&2, Bool>:
  Bool.pick(Maybe<&2, Bool>, String.eq(m, "post"), Some{True{}}, Bool.pick(Maybe<&2, Bool>, String.eq(m, "send"), Some{False{}}, None{}))

# by default replies are posted when the writer can have a core of its
# own: the process may use two cores or more
def post_default(cpus: U32) -> Bool:
  U32.is_lt(1, cpus)

def opts_of(args: List<String>) -> Opts:
  match args:
    case Con{prog, Con{p, Con{m, Con{f, Con{y, rest}}}}}:
      Opts{port_or(p), post_or(m), Some{f}, sync_or(y)}
    case Con{prog, Con{p, Con{m, Con{f, rest}}}}:
      Opts{port_or(p), post_or(m), Some{f}, EverySec{}}
    case Con{prog, Con{p, Con{m, rest}}}:
      Opts{port_or(p), post_or(m), None{}, EverySec{}}
    case Con{prog, Con{p, rest}}:
      Opts{port_or(p), None{}, None{}, EverySec{}}
    case _:
      Opts{6380, None{}, None{}, EverySec{}}

def post_note(post: Bool) -> String:
  Bool.pick(String, post, "post", "send")

@unsafe
def serve_mem(+port: U32, +post: Bool, srv: S.Srv) -> IO(Unit):
  do IO<Unit>:
    +reqs : Chan(Req) <- Chan.new(Req, 1024)
    Unit <- IO.spawn(Unit, db_loop(srv, KV.empty(String), reqs))
    l : Listener <- IO.try(Listener, TCP.listen("127.0.0.1", port))
    IO.print("BendKV listening on 127.0.0.1:" ++ U32.show(port) ++ " (" ++ post_note(post) ++ ")")
    accept_loop(l, reqs, post, 1n)

# the parameters the server starts with (config.bend): its port, its
# directory, and its append-only file and how it is synced
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
def serve_on(+port: U32, +post: Bool, aof: Maybe<&2, String>, +sync: Sync, srv: S.Srv) -> IO(Unit):
  match aof:
    case None{}:
      serve_mem(port, post, srv)
    case Some{path}:
      serve_aof(port, post, path, sync, srv)

@unsafe
def serve(o: Opts, cpus: U32, dir: String) -> IO(Unit):
  match o:
    case Opts{+port, post, +aof, +sync}:
      serve_on(port, Maybe.default(&2, Bool, post, post_default(cpus)), aof, sync, S.srv_start(start_sets(port, dir, aof, sync)))

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    cpus : U32 <- IO.thread_count()
    pwd : Result<&1, &1, U32 & String, String> <- IO.get_env("PWD")
    serve(opts_of(args), cpus, env_or(pwd))
