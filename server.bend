# server.bend: the TCP server. This is the unverified shell around the
# proven core: it moves bytes between sockets and the pure functions of
# resp.bend, redis.bend and shard.bend, and runs forever, hence @unsafe.
#
# One computation, the database actor, owns the database and runs the
# commands one batch at a time, in arrival order, as Redis's single
# command thread does; the batches that wait for it together it takes at
# once and answers at once. Each connection is a computation of its own: it
# reads bytes, parses every complete request in its buffer, sends the
# batch to the actor and writes the replies back in order.
#
# With n shards (the second argument), the database is cut in n, as
# shard.bend describes: an actor for each shard, each on an event loop
# of its own (IO.spawn_on, a thread each), and the connections spread
# over the loops in turn. A connection cuts each batch among the shards,
# hands every shard its part at once (Chan.send_all), and puts their
# replies back in order. As every shard takes the parts of all batches in
# one same order, the shards run the batches as one actor would, one
# after another. An actor answers in bytes (wire.bend): it encodes its
# replies, so values leave a shard as bytes, and a connection merges the
# answers into the pieces of its reply, which go out together.
#
# Replies go out in one of two ways (the third argument): post hands them
# to the loop's writer thread (TCP.post), which sends them on a core of
# its own while the loop goes on; send sends them from the loop itself
# (TCP.send_raw). A writer pays when it has a core to itself, so the
# default is post for one shard when the process may use two cores or
# more (IO.thread_count), and send otherwise.
#
# With an append-only file (the fourth argument), each shard's actor also
# appends what its part of each batch did to a file of its own before it
# answers: the path itself for one shard, path.0, path.1, ... for several.
# When the server starts, each shard restores its database from its file
# (aof.bend and the Persistence laws).
#
#   bend server.bend -o bendkv && ./bendkv 6380 [shards [post|send [file [always|everysec|no]]]]
#   redis-cli -p 6380 set foo bar

import Base
import ./map.bend as KV
import ./redis.bend as R
import ./resp.bend as P
import ./batch.bend as B
import ./shard.bend as S
import ./wire.bend as W
import ./aof.bend as A

# what an actor answers: a whole batch's replies, encoded, or each
# command's answer (wire.bend), for a part of a batch
type Ans is Data:
  AAll{s: String}
  AParts{os: List<&2, W.Out>}

# a batch of commands, the hashes of their keys (for the hints of
# batch.bend, and for exec.at), the channel its answer goes back on, and
# whether it is a whole batch or a part of one
type Req is Data:
  Req{cmds: List<&2, R.Cmd>, hs: List<&2, U32>, back: Chan(Ans), whole: Bool}

# The database actor
# ------------------

def ans_of(whole: Bool, rs: List<&2, R.Reply>) -> Ans:
  match whole:
    case True{}:
      AAll{P.encode_all(rs)}
    case False{}:
      AParts{W.outs(rs)}

# The actor takes a request, and with it those that came meanwhile
# (Chan.drain, up to group_max): it runs their batches one after another,
# in the order they came, and answers them all at once (Chan.send_all). A
# group is its answers so far, newest first, and the database.
type Run is Data:
  Run{outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, db: KV.Trie<String>}

def group_max() -> U32:
  255

def run_put(outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, back: Chan(Ans), whole: Bool, r: List<&2, R.Reply> & KV.Trie<String>) -> Run:
  (rs, db) = r
  Run{(back, ans_of(whole, rs)) <> outs, db}

def run_req(q: Req, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, db: KV.Trie<String>) -> Run:
  match q:
    case Req{cmds, hs, back, whole}:
      run_put(outs, back, whole, B.exec_batch(cmds, hs, db))

def run_step(q: Req, g: Run) -> Run:
  match g:
    case Run{outs, db}:
      run_req(q, outs, db)

def run_group(qs: List<&1, Req>, g: Run) -> Run:
  match qs:
    case Nil{}:
      g
    case Con{q, rest}:
      run_group(rest, run_step(q, g))

@unsafe
def db_loop(db: KV.Trie<String>, +reqs: Chan(Req)) -> IO(Unit):
  do IO<Unit>:
    m : Maybe<&1, Req> <- Chan.recv(Req, reqs)
    db_serve(db, reqs, m)

@unsafe
def db_serve(db: KV.Trie<String>, +reqs: Chan(Req), m: Maybe<&1, Req>) -> IO(Unit):
  match m:
    case None{}:
      IO.pure(Unit, Unit{})
    case Some{q}:
      do IO<Unit>:
        more : List<&1, Req> <- Chan.drain(Req, reqs, group_max())
        db_group(run_group(q <> more, Run{Nil{}, db}), reqs)

@unsafe
def db_group(g: Run, +reqs: Chan(Req)) -> IO(Unit):
  match g:
    case Run{outs, db}:
      do IO<Unit>:
        Unit <- Chan.send_all(Ans, List.reverse(&2, Sigma<&2, &2, Chan(Ans), _ => Ans>, outs))
        db_loop(db, reqs)

# Connections
# -----------

# a batch to send: the commands of the parsed requests (newest first, put
# in order) and the hashes they run with (LAWS.bend: fit_hashes)
def batch_req.of(p: List<&2, R.Cmd> & List<&2, U32>, back: Chan(Ans)) -> Req:
  (cs, hs) = p
  Req{cs, hs, back, True{}}

def batch_req(fs: List<&2, B.Fit>, back: Chan(Ans)) -> Req:
  batch_req.of(B.fit_unzip(fs, Nil{}, Nil{}), back)

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

# a merged batch's replies out on s together: one post (TCP.post_list
# glues them once, into the post's buffer), or one send
def put_all(s: Socket, post: Bool, pieces: List<&2, String>, next: Socket -> IO(Unit)) -> IO(Unit):
  match post:
    case True{}:
      do IO<Unit>:
        s2 : Socket <- TCP.post_list(s, pieces)
        next(s2)
    case False{}:
      do IO<Unit>:
        m : Socket & Result<&1, &1, U32 & String, Unit> <- TCP.send_raw(s, String.concat(pieces))
        sent_ok(m, next)

def reply_to(s: Socket, post: Bool, got: Maybe<&1, Ans>, next: Socket -> IO(Unit)) -> IO(Unit):
  match got:
    case Some{AAll{str}}:
      put_out(s, post, str, next)
    case Some{AParts{os}}:
      Socket.close(s)
    case None{}:
      Socket.close(s)

# a protocol error is answered, then the connection closes, as in Redis
def after(s: Socket, post: Bool, err: Maybe<&2, String>, next: Socket -> IO(Unit)) -> IO(Unit):
  match err:
    case None{}:
      next(s)
    case Some{msg}:
      put_out(s, post, "-ERR " ++ msg ++ "\r\n", s2 => Socket.close(s2))

# a connection's way to the shards: how many (n), each shard's actor
# (dbs), the channel each shard's replies come back on (backs), and
# whether its replies are posted
type Link is Data:
  Link{n: U32, dbs: List<&2, Chan(Req)>, backs: List<&2, Chan(Ans)>, post: Bool}

def posts(ln: Link) -> Bool:
  match ln:
    case Link{n, dbs, backs, post}:
      post

# the parts of a batch, for the shards that have one: each with its hints
# and its shard's back channel; and which shards have one
def part_req.of(x: List<&2, R.Cmd> & List<&2, U32>, back: Chan(Ans)) -> Req:
  (cs, hs) = x
  Req{cs, hs, back, False{}}

def part_req(p: List<&2, S.Part>, back: Chan(Ans)) -> Req:
  match p:
    case Con{S.Part{c, h}, Nil{}}:
      Req{[c], [h], back, False{}}
    case other:
      part_req.of(S.unzip(other), back)

def sends.put(d: Chan(Req), r: Req, x: List<&2, Sigma<&2, &2, Chan(Req), _ => Req>> & List<&2, Bool>) -> List<&2, Sigma<&2, &2, Chan(Req), _ => Req>> & List<&2, Bool>:
  (ss, us) = x
  ((d, r) <> ss, True{} <> us)

def sends.skip(x: List<&2, Sigma<&2, &2, Chan(Req), _ => Req>> & List<&2, Bool>) -> List<&2, Sigma<&2, &2, Chan(Req), _ => Req>> & List<&2, Bool>:
  (ss, us) = x
  (ss, False{} <> us)

# (split's list of parts ends at the last shard that has one)
def sends(dbs: List<&2, Chan(Req)>, backs: List<&2, Chan(Ans)>, ps: List<&2, List<&2, S.Part>>) -> List<&2, Sigma<&2, &2, Chan(Req), _ => Req>> & List<&2, Bool>:
  match dbs backs ps:
    case Con{d, ds} Con{b, bs} Con{Nil{}, rest}:
      sends.skip(sends(ds, bs, rest))
    case Con{d, ds} Con{b, bs} Con{Con{p, more}, rest}:
      sends.put(d, part_req(p <> more, b), sends(ds, bs, rest))
    case _ _ _:
      (Nil{}, Nil{})

def got_or_nil(m: Maybe<&1, Ans>) -> List<&2, W.Out>:
  match m:
    case Some{AParts{os}}:
      os
    case _:
      Nil{}

# each shard's answers, in shard order: none from a shard without a part
@unsafe
def collect(backs: List<&2, Chan(Ans)>, used: List<&2, Bool>, acc: W.Store()) -> IO(W.Store()):
  match backs used:
    case Con{b, bs} Con{True{}, us}:
      do IO<W.Store()>:
        m : Maybe<&1, Ans> <- Chan.recv(Ans, b)
        collect(bs, us, got_or_nil(m) <> acc)
    case Con{b, bs} Con{False{}, us}:
      collect(bs, us, Nil{} <> acc)
    case _ _:
      IO.pure(W.Store(), List.reverse(&2, List<&2, W.Out>, acc))

@unsafe
def run_split.go(s: Socket, +backs: List<&2, Chan(Ans)>, routes: List<&2, S.Route>, x: List<&2, Sigma<&2, &2, Chan(Req), _ => Req>> & List<&2, Bool>, +post: Bool, err: Maybe<&2, String>, next: Socket -> IO(Unit)) -> IO(Unit):
  (ss, used) = x
  do IO<Unit>:
    Unit <- Chan.send_all(Req, ss)
    st : W.Store() <- collect(backs, used, Nil{})
    put_all(s, post, W.merge(routes, st), s2 => after(s2, post, err, next))

@unsafe
def run_split(s: Socket, +dbs: List<&2, Chan(Req)>, +backs: List<&2, Chan(Ans)>, r: List<&2, S.Route> & List<&2, List<&2, S.Part>>, post: Bool, err: Maybe<&2, String>, next: Socket -> IO(Unit)) -> IO(Unit):
  (routes, ps) = r
  run_split.go(s, backs, routes, sends(dbs, backs, ps), post, err, next)

# a batch to the database: whole to a lone shard's actor, else cut among
# the shards
@unsafe
def run_on(s: Socket, ln: Link, reqs: List<&2, B.Fit>, err: Maybe<&2, String>, next: Socket -> IO(Unit)) -> IO(Unit):
  match ln:
    case Link{n, Con{db, Nil{}}, Con{back, Nil{}}, +post}:
      do IO<Unit>:
        got : Maybe<&1, Ans> <- Chan.call(Req, Ans, db, batch_req(reqs, back), back)
        reply_to(s, post, got, s2 => after(s2, post, err, next))
    case Link{+n, +dbs, +backs, post}:
      run_split(s, dbs, backs, S.split(n, B.fit_cmds(reqs, Nil{})), post, err, next)

@unsafe
def run_batch(s: Socket, +ln: Link, reqs: List<&2, B.Fit>, err: Maybe<&2, String>, next: Socket -> IO(Unit)) -> IO(Unit):
  match reqs:
    case Nil{}:
      after(s, posts(ln), err, next)
    case Con{r, rs}:
      run_on(s, ln, r <> rs, err, next)

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
# parsed once, not once per read. Bytes cross as they are, one Char each
# (recv_raw, send_raw): a String of them is a packed buffer.
@unsafe
def conn_loop(s: Socket, rest: String, got: List<&2, String>, have: Nat, need: Nat, +ln: Link) -> IO(Unit):
  do IO<Unit>:
    m : Socket & Result<&1, &1, U32 & String, String> <- TCP.recv_raw(s, 65536)
    conn_got(m, rest, got, have, need, ln)

@unsafe
def conn_got(m: Socket & Result<&1, &1, U32 & String, String>, rest: String, got: List<&2, String>, have: Nat, need: Nat, +ln: Link) -> IO(Unit):
  (s, r) = m
  match r:
    case Fail{e}:
      Socket.close(s)
    case Done{+x}:
      conn_data(s, String.is_empty(x), x, rest, got, have, need, ln)

@unsafe
def conn_data(s: Socket, eof: Bool, +x: String, rest: String, got: List<&2, String>, have: Nat, +need: Nat, +ln: Link) -> IO(Unit):
  match eof:
    case True{}:
      Socket.close(s)
    case False{}:
      +h = Nat.add(have, count_upto(need, x))
      conn_more(s, rest, x <> got, h, need, ln, Nat.is_lt(h, need))

@unsafe
def conn_more(s: Socket, rest: String, got: List<&2, String>, have: Nat, need: Nat, +ln: Link, wait: Bool) -> IO(Unit):
  match wait:
    case True{}:
      conn_loop(s, rest, got, have, need, ln)
    case False{}:
      conn_batch(s, parse_in(rest, got), ln)

# One shard, its replies posted, a batch without a protocol error: the
# common case takes two effects a batch besides the read, one to hand the
# batch to the actor and wait for its answer (Chan.call), one to post the
# answer and read on (TCP.post_recv_raw). Every other case goes the long
# way, by run_batch.
@unsafe
def conn_reply(s: Socket, got: Maybe<&1, Ans>, rest: String, +need: Nat, +ln: Link) -> IO(Unit):
  match got:
    case Some{AAll{str}}:
      do IO<Unit>:
        m : Socket & Result<&1, &1, U32 & String, String> <- TCP.post_recv_raw(s, str, 65536)
        conn_got(m, rest, Nil{}, 0n, need, ln)
    case Some{AParts{os}}:
      Socket.close(s)
    case None{}:
      Socket.close(s)

@unsafe
def conn_run(s: Socket, +ln: Link, reqs: List<&2, B.Fit>, err: Maybe<&2, String>, rest: String, +need: Nat) -> IO(Unit):
  match ln reqs err:
    case Link{n, Con{db, Nil{}}, Con{back, Nil{}}, True{}} Con{r, rs} None{}:
      do IO<Unit>:
        got : Maybe<&1, Ans> <- Chan.call(Req, Ans, db, batch_req(r <> rs, back), back)
        conn_reply(s, got, rest, need, ln)
    case _ q e:
      run_batch(s, ln, q, e, s2 => conn_loop(s2, rest, Nil{}, 0n, need, ln))

@unsafe
def conn_batch(s: Socket, batch: P.Batch, +ln: Link) -> IO(Unit):
  match batch:
    case P.Batch{reqs, rest, err, +need}:
      conn_run(s, ln, reqs, err, rest, need)

# the shards, as every connection knows them: how many, each shard's
# actor, and whether replies are posted
type Shards is Data:
  Shards{n: U32, dbs: List<&2, Chan(Req)>, post: Bool}

# a back channel for each of k shards
@unsafe
def new_backs(k: Nat, acc: List<&2, Chan(Ans)>) -> IO(List<&2, Chan(Ans)>):
  match k:
    case 0n:
      IO.pure(List<&2, Chan(Ans)>, acc)
    case 1n+p:
      do IO<List<&2, Chan(Ans)>>:
        b : Chan(Ans) <- Chan.new(Ans, 1)
        new_backs(p, b <> acc)

@unsafe
def conn_start(s: Socket, sh: Shards) -> IO(Unit):
  match sh:
    case Shards{+n, dbs, post}:
      do IO<Unit>:
        backs : List<&2, Chan(Ans)> <- new_backs(U32.to_nat(n), Nil{})
        conn_loop(s, SNil{}, Nil{}, 0n, 1n, Link{n, dbs, backs, post})

# Accepting
# ---------
# Connection i runs on event loop i mod n, the loop of shard i mod n.

def next_loop(+i: U32, sh: Shards) -> U32:
  match sh:
    case Shards{n, dbs, post}:
      Bool.pick(U32, U32.is_lt((i + 1 : U32), n), (i + 1 : U32), 0)

@unsafe
def accept_next(m: Listener & Result<&1, &1, U32 & String, Socket>, +sh: Shards, +i: U32) -> IO(Listener):
  (l, r) = m
  match r:
    case Done{s}:
      do IO<Listener>:
        IO.spawn_on(Unit, i, conn_start(s, sh))
        return l
    case Fail{e}:
      IO.pure(Listener, l)

@unsafe
def accept_loop(l: Listener, +sh: Shards, +i: U32) -> IO(Unit):
  do IO<Unit>:
    m : Listener & Result<&1, &1, U32 & String, Socket> <- TCP.accept(l)
    l2 : Listener <- accept_next(m, sh, i)
    accept_loop(l2, sh, next_loop(i, sh))

# The append-only file
# --------------------
# With a file, each shard's actor runs each batch (or part of one) with
# exec_log (aof.bend; after the hints of batch.bend, as log_batch),
# appends the entries of what it did to the shard's file, and answers once
# they are written: synced to the disk first with always, synced each
# second by a syncer of their own with everysec (Redis's default), left to
# the system with no. A batch that changed nothing writes nothing, and the
# batches that wait together share one write and one sync. At
# start each shard restores its database from its file (LAWS.bend:
# recover, shard_recover). A file that ends inside an entry, cut by a
# crash in the middle of a write, is cut back to its last whole entry, as
# Redis does with aof-load-truncated; a file with anything else after its
# entries is refused, as Redis refuses it. So are the files of a server
# with another shard count: a shard holds the keys of its digits, and the
# digits are cut among the shards by their count.

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
# it runs their batches one after another, appends the effects of them
# all at once, syncs once, and answers them all at once, as Redis does in
# each turn of its loop. A group is its
# answers so far, newest first, the effects so far, each batch's in front
# of the ones before reversed, and the database.
type Grp is Data:
  Grp{outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, R.Cmd>, db: KV.Trie<String>}

def group_put2(outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, R.Cmd>, back: Chan(Ans), a: Ans, q: List<&2, R.Cmd> & KV.Trie<String>) -> Grp:
  (e, db) = q
  Grp{(back, a) <> outs, List.reverse.go(&2, R.Cmd, e, es), db}

def group_put(outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, R.Cmd>, back: Chan(Ans), whole: Bool, r: List<&2, R.Reply> & (List<&2, R.Cmd> & KV.Trie<String>)) -> Grp:
  (rs, q) = r
  group_put2(outs, es, back, ans_of(whole, rs), q)

def group_req(q: Req, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, R.Cmd>, db: KV.Trie<String>) -> Grp:
  match q:
    case Req{cmds, hs, back, whole}:
      group_put(outs, es, back, whole, A.log_batch(cmds, hs, db))

def group_step(q: Req, g: Grp) -> Grp:
  match g:
    case Grp{outs, es, db}:
      group_req(q, outs, es, db)

def group_run(qs: List<&1, Req>, g: Grp) -> Grp:
  match qs:
    case Nil{}:
      g
    case Con{q, rest}:
      group_run(rest, group_step(q, g))

@unsafe
def aof_loop(db: KV.Trie<String>, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  do IO<Unit>:
    m : Maybe<&1, Req> <- Chan.recv(Req, reqs)
    aof_more(db, f, sync, reqs, m)

@unsafe
def aof_more(db: KV.Trie<String>, f: File, +sync: Sync, +reqs: Chan(Req), m: Maybe<&1, Req>) -> IO(Unit):
  match m:
    case None{}:
      File.close(f)
    case Some{q}:
      do IO<Unit>:
        more : List<&1, Req> <- Chan.drain(Req, reqs, group_max())
        aof_group(group_run(q <> more, Grp{Nil{}, Nil{}, db}), f, sync, reqs)

@unsafe
def aof_group(g: Grp, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  match g:
    case Grp{outs, es, db}:
      aof_put(List.reverse(&2, Sigma<&2, &2, Chan(Ans), _ => Ans>, outs), List.reverse(&2, R.Cmd, es), db, f, sync, reqs)

@unsafe
def aof_put(outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, es: List<&2, R.Cmd>, db: KV.Trie<String>, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  match es:
    case Nil{}:
      aof_reply(outs, db, f, sync, reqs)
    case Con{e, more}:
      do IO<Unit>:
        p : File & Result<&1, &1, U32 & String, Unit> <- File.write_raw(f, A.encode(A.args_all(e <> more)))
        aof_wrote(p, outs, db, sync, reqs)

@unsafe
def aof_wrote(p: File & Result<&1, &1, U32 & String, Unit>, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, db: KV.Trie<String>, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  (f, r) = p
  match r:
    case Fail{e}:
      IO.die(Unit, 1, aof_fail(e))
    case Done{u}:
      aof_sync(sync, f, outs, db, reqs)

@unsafe
def aof_synced(p: File & Result<&1, &1, U32 & String, Unit>, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, db: KV.Trie<String>, +reqs: Chan(Req)) -> IO(Unit):
  (f, r) = p
  match r:
    case Fail{e}:
      IO.die(Unit, 1, aof_fail(e))
    case Done{u}:
      aof_reply(outs, db, f, Always{}, reqs)

@unsafe
def aof_sync(+sync: Sync, f: File, outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, db: KV.Trie<String>, +reqs: Chan(Req)) -> IO(Unit):
  match sync:
    case Always{}:
      do IO<Unit>:
        p : File & Result<&1, &1, U32 & String, Unit> <- File.sync(f)
        aof_synced(p, outs, db, reqs)
    case EverySec{}:
      aof_reply(outs, db, f, EverySec{}, reqs)
    case Never{}:
      aof_reply(outs, db, f, Never{}, reqs)

@unsafe
def aof_reply(outs: List<&2, Sigma<&2, &2, Chan(Ans), _ => Ans>>, db: KV.Trie<String>, f: File, +sync: Sync, +reqs: Chan(Req)) -> IO(Unit):
  do IO<Unit>:
    Unit <- Chan.send_all(Ans, outs)
    aof_loop(db, f, sync, reqs)

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
      Bool.and(List.is_empty(&2, B.Fit, reqs), Maybe.is_none(&2, String, err))

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

# The files of several shards
# ---------------------------

# shard s's file among n: the path itself for one shard (a file Redis
# loads), else the path and the shard's number
def shard_file(+path: String, +n: U32, +s: U32) -> String:
  Bool.pick(String, U32.is_eq(n, 1), path, path ++ "." ++ U32.show(s))

def files_note(+path: String, +n: U32) -> String:
  Bool.pick(String, U32.is_eq(n, 1), "file " ++ path, "files " ++ path ++ ".0 to " ++ path ++ "." ++ U32.show((n - 1 : U32)))

@unsafe
def is_file.none(none: Bool, +path: String, msg: String) -> IO(Bool):
  match none:
    case True{}:
      IO.pure(Bool, False{})
    case False{}:
      IO.die(Bool, 1, open_fail(path, msg))

@unsafe
def is_file.fail(+path: String, e: U32 & String) -> IO(Bool):
  (code, msg) = e
  is_file.none(U32.is_eq(code, enoent()), path, msg)

# whether a file is there: not there only when opening it says so
@unsafe
def is_file.of(+path: String, m: Result<&1, &1, U32 & String, File>) -> IO(Bool):
  match m:
    case Fail{e}:
      is_file.fail(path, e)
    case Done{f}:
      do IO<Bool>:
        Unit <- File.close(f)
        return True{}

@unsafe
def is_file(+path: String) -> IO(Bool):
  do IO<Bool>:
    m : Result<&1, &1, U32 & String, File> <- File.open(path, "r")
    is_file.of(path, m)

@unsafe
def refuse_if(bad: Bool, msg: String) -> IO(Unit):
  match bad:
    case True{}:
      IO.die(Unit, 1, msg)
    case False{}:
      IO.pure(Unit, Unit{})

@unsafe
def refuse_file(+path: String, msg: String) -> IO(Unit):
  do IO<Unit>:
    there : Bool <- is_file(path)
    refuse_if(there, msg)

# the files of a server with another shard count are refused: with one
# shard, path.0 (of several); with n, the path (of one) and path.n (of
# more). Files of fewer shards than n hold keys of the wrong shards, which
# open_aof finds (strays)
@unsafe
def layout_check(+path: String, +n: U32, one: Bool) -> IO(Unit):
  match one:
    case True{}:
      refuse_file(path ++ ".0", path ++ ".0 is the append-only file of a shard: start the server with as many shards as wrote it")
    case False{}:
      do IO<Unit>:
        Unit <- refuse_file(path, path ++ " is the append-only file of a server with one shard: start it with one shard")
        refuse_file(path ++ "." ++ U32.show(n), path ++ "." ++ U32.show(n) ++ " is the append-only file of a shard past the last of " ++ U32.show(n) ++ ": start the server with as many shards as wrote it")

def stray(own: Bool, +db: KV.Trie<String>, +x: KV.Hex) -> Nat:
  match own:
    case True{}:
      0n
    case False{}:
      KV.size.at(String, db, x)

# the keys shard s of n holds under digits of other shards: none, unless
# its file is of a server with another shard count
def strays(+n: U32, +s: Nat, xs: List<&2, KV.Hex>, +db: KV.Trie<String>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case Con{+x, rest}:
      Nat.add(stray(Nat.is_eq(S.owner(n, x), s), db, x), strays(n, s, rest, db))

# shard s of n, its database restored from its file, its actor on loop s
@unsafe
def open_aof(+file: String, +n: U32, +s: U32, +sync: Sync, +db: KV.Trie<String>) -> IO(Chan(Req)):
  do IO<Chan(Req)>:
    Unit <- refuse_if(Nat.is_lt(0n, strays(n, U32.to_nat(s), KV.digits(), db)), file ++ " holds keys of other shards: start the server with as many shards as wrote it")
    f : File <- IO.try(File, File.open(file, "a"))
    Unit <- syncer(sync, file)
    +reqs : Chan(Req) <- Chan.new(Req, 1024)
    Unit <- IO.spawn_on(Unit, s, aof_loop(db, f, sync, reqs))
    return reqs

# a shard's file restored on the shard's own loop, the database sent back
@unsafe
def restore_on(+file: String, back: Chan(KV.Trie<String>)) -> IO(Unit):
  do IO<Unit>:
    db : KV.Trie<String> <- restore(file)
    sent : Bool <- Chan.send(KV.Trie<String>, back, db)
    return Unit{}

# the shards from i on, k of them, each restoring its file on its loop, all
# at once: the channels their databases come back on, in shard order
@unsafe
def restores(k: Nat, +i: U32, +n: U32, +path: String, acc: List<&2, Chan(KV.Trie<String>)>) -> IO(List<&2, Chan(KV.Trie<String>)>):
  match k:
    case 0n:
      IO.pure(List<&2, Chan(KV.Trie<String>)>, List.reverse(&2, Chan(KV.Trie<String>), acc))
    case 1n+p:
      do IO<List<&2, Chan(KV.Trie<String>)>>:
        +back : Chan(KV.Trie<String>) <- Chan.new(KV.Trie<String>, 1)
        Unit <- IO.spawn_on(Unit, i, restore_on(shard_file(path, n, i), back))
        restores(p, (i + 1 : U32), n, path, back <> acc)

@unsafe
def restored_db(+file: String, +n: U32, +s: U32, +sync: Sync, m: Maybe<&1, KV.Trie<String>>) -> IO(Chan(Req)):
  match m:
    case Some{db}:
      open_aof(file, n, s, sync, db)
    case None{}:
      IO.die(Chan(Req), 1, "the shard restoring " ++ file ++ " stopped")

# the shards from i on, each started on its database once restored: their
# channels, in shard order
@unsafe
def open_aofs(backs: List<&2, Chan(KV.Trie<String>)>, +i: U32, +n: U32, +path: String, +sync: Sync, acc: List<&2, Chan(Req)>) -> IO(List<&2, Chan(Req)>):
  match backs:
    case Nil{}:
      IO.pure(List<&2, Chan(Req)>, List.reverse(&2, Chan(Req), acc))
    case Con{back, more}:
      do IO<List<&2, Chan(Req)>>:
        m : Maybe<&1, KV.Trie<String>> <- Chan.recv(KV.Trie<String>, back)
        reqs : Chan(Req) <- restored_db(shard_file(path, n, i), n, i, sync, m)
        open_aofs(more, (i + 1 : U32), n, path, sync, reqs <> acc)

# n shards, each actor appending to its file
@unsafe
def serve_aof(+port: U32, +n: U32, +post: Bool, +path: String, +sync: Sync) -> IO(Unit):
  do IO<Unit>:
    Unit <- layout_check(path, n, U32.is_eq(n, 1))
    backs : List<&2, Chan(KV.Trie<String>)> <- restores(U32.to_nat(n), 0, n, path, Nil{})
    dbs : List<&2, Chan(Req)> <- open_aofs(backs, 0, n, path, sync, Nil{})
    l : Listener <- IO.try(Listener, TCP.listen("127.0.0.1", port))
    IO.print("BendKV listening on 127.0.0.1:" ++ U32.show(port) ++ " (" ++ shards_note(n) ++ ", " ++ post_note(post) ++ ", append-only " ++ files_note(path, n) ++ ", fsync " ++ sync_note(sync) ++ ")")
    accept_loop(l, Shards{n, dbs, post}, 0)

# Main
# ----

# the port (the first argument, default 6380), the shard count (the
# second, 1 to 16, default 1), whether replies are posted (the third,
# post or send; none for the default), and the append-only file (the
# fourth, none by default) with how it is synced (the fifth: always,
# everysec or no; everysec by default)
type Opts is Data:
  Opts{port: U32, n: U32, post: Maybe<&2, Bool>, aof: Maybe<&2, String>, sync: Sync}

def port_or(p: String) -> U32:
  Maybe.default(&2, U32, U32.read(p), 6380)

def shards_or(k: String) -> U32:
  U32.clamp(Maybe.default(&2, U32, U32.read(k), 1), 1, 16)

def post_or(+m: String) -> Maybe<&2, Bool>:
  Bool.pick(Maybe<&2, Bool>, String.eq(m, "post"), Some{True{}}, Bool.pick(Maybe<&2, Bool>, String.eq(m, "send"), Some{False{}}, None{}))

# by default replies are posted for one shard whose writer can have a
# core of its own: the process may use two cores or more
def post_default(+n: U32, cpus: U32) -> Bool:
  Bool.and(U32.is_eq(n, 1), U32.is_lt(1, cpus))

def opts_of(args: List<String>) -> Opts:
  match args:
    case Con{prog, Con{p, Con{k, Con{m, Con{f, Con{y, rest}}}}}}:
      Opts{port_or(p), shards_or(k), post_or(m), Some{f}, sync_or(y)}
    case Con{prog, Con{p, Con{k, Con{m, Con{f, rest}}}}}:
      Opts{port_or(p), shards_or(k), post_or(m), Some{f}, EverySec{}}
    case Con{prog, Con{p, Con{k, Con{m, rest}}}}:
      Opts{port_or(p), shards_or(k), post_or(m), None{}, EverySec{}}
    case Con{prog, Con{p, Con{k, rest}}}:
      Opts{port_or(p), shards_or(k), None{}, None{}, EverySec{}}
    case Con{prog, Con{p, rest}}:
      Opts{port_or(p), 1, None{}, None{}, EverySec{}}
    case _:
      Opts{6380, 1, None{}, None{}, EverySec{}}

# an actor for each shard from i on, k of them, each on its own loop:
# their channels, in shard order
@unsafe
def open_shards(k: Nat, +i: U32, acc: List<&2, Chan(Req)>) -> IO(List<&2, Chan(Req)>):
  match k:
    case 0n:
      IO.pure(List<&2, Chan(Req)>, List.reverse(&2, Chan(Req), acc))
    case 1n+p:
      do IO<List<&2, Chan(Req)>>:
        +reqs : Chan(Req) <- Chan.new(Req, 1024)
        Unit <- IO.spawn_on(Unit, i, db_loop(KV.empty(String), reqs))
        open_shards(p, (i + 1 : U32), reqs <> acc)

def shards_note(+n: U32) -> String:
  Bool.pick(String, U32.is_eq(n, 1), "1 shard", U32.show(n) ++ " shards")

def post_note(post: Bool) -> String:
  Bool.pick(String, post, "post", "send")

@unsafe
def serve_mem(+port: U32, +n: U32, +post: Bool) -> IO(Unit):
  do IO<Unit>:
    dbs : List<&2, Chan(Req)> <- open_shards(U32.to_nat(n), 0, Nil{})
    l : Listener <- IO.try(Listener, TCP.listen("127.0.0.1", port))
    IO.print("BendKV listening on 127.0.0.1:" ++ U32.show(port) ++ " (" ++ shards_note(n) ++ ", " ++ post_note(post) ++ ")")
    accept_loop(l, Shards{n, dbs, post}, 0)

@unsafe
def serve_on(+port: U32, +n: U32, +post: Bool, aof: Maybe<&2, String>, sync: Sync) -> IO(Unit):
  match aof:
    case None{}:
      serve_mem(port, n, post)
    case Some{path}:
      serve_aof(port, n, post, path, sync)

@unsafe
def serve(o: Opts, cpus: U32) -> IO(Unit):
  match o:
    case Opts{+port, +n, post, aof, sync}:
      serve_on(port, n, Maybe.default(&2, Bool, post, post_default(n, cpus)), aof, sync)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    cpus : U32 <- IO.thread_count()
    serve(opts_of(args), cpus)
