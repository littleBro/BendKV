# batch.bend: a batch of commands run with hints for the processor. The
# server runs each batch here (exec_batch) instead of with exec_all, and
# LAWS.bend (batch_hints) shows that nothing changes: the replies and the
# database after the batch are those of exec_all, whatever the hints.

import Base
import ./map.bend as KV
import ./redis.bend as R

# Before a batch of two commands or more runs, the keys of its commands
# are looked up ahead of time, one level of the trie at a time for all of
# them, each step only starting to load the next level (KV.touch.node,
# KV.touch.entry): the cache misses of different keys overlap, where a
# lookup alone waits for one miss after another. Nothing here changes a
# value; the batch then runs as before, and finds its paths in the cache.
# The hashes come from the requests as the connection parses them: the
# hash of each request's first argument after its name, which is the key
# of every command on keys (for the rest, a hint that goes unused). A Cmd
# is unpacked into words when a match binds it, so reading the hashes from
# the commands, which the batch still needs, would give their keys
# reference counts.

# a parsed request: its command, and the hash of its first argument after
# its name, for the hints (0 for none)
type Req is Data:
  Req{cmd: R.Cmd, hash: U32}

# a batch: of database commands only, with the hashes of their keys (most
# batches; they run as exec_batch runs them), or one with a command of
# the connection or of the server (R.Own) in it, which runs a command at
# a time (session.bend: gen)
type Job is Data:
  Plain{cmds: List<&2, R.Cmd>, hs: List<&2, U32>}
  Mixed{cmds: List<&2, R.Cmd>}

# The parser keeps a batch's requests newest first (resp.bend: Batch):
# putting each one before those that came after it, in one pass, puts
# them in order.

# the commands of parsed requests, newest first, put in order before cs
def cmds_of(rs: List<&2, Req>, cs: List<&2, R.Cmd>) -> List<&2, R.Cmd>:
  match rs:
    case Nil{}:
      cs
    case Con{Req{c, h}, rest}:
      cmds_of(rest, c <> cs)

# a batch of parsed requests, newest first, taken apart in one pass:
# while every request is a database command, its commands and the hashes
# of their keys, put in order before cs and hs (UPlain); at the first
# command of the connection or of the server, the requests not yet taken
# apart and the commands so far (USplit), which job puts together
type Unz is Data:
  UPlain{cs: List<&2, R.Cmd>, hs: List<&2, U32>}
  USplit{rest: List<&2, Req>, cs: List<&2, R.Cmd>}

def unzip(rs: List<&2, Req>, cs: List<&2, R.Cmd>, hs: List<&2, U32>) -> Unz:
  match rs:
    case Nil{}:
      UPlain{cs, hs}
    case Con{Req{R.Own{o}, h}, rest}:
      USplit{rest, R.Own{o} <> cs}
    case Con{Req{c, h}, rest}:
      unzip(rest, c <> cs, h <> hs)

def job(u: Unz) -> Job:
  match u:
    case UPlain{cs, hs}:
      Plain{cs, hs}
    case USplit{rest, cs}:
      Mixed{cmds_of(rest, cs)}

# the hash of a request's first argument after its name (0 for none)
def args_hash(args: List<&2, String>) -> U32:
  match args:
    case Con{key, rest}:
      KV.hash(key)
    case Nil{}:
      0

# whether there are two hashes or more: one has nothing to overlap with
def many(hs: List<&2, U32>) -> Bool:
  match hs:
    case Con{a, Con{b, rest}}:
      True{}
    case _:
      False{}

def touch_nodes(+hs: List<&2, U32>, +db: KV.Trie<String>, +d: Nat, acc: U32) -> U32:
  match hs:
    case Nil{}:
      acc
    case Con{+h, +rest}:
      touch_nodes(rest, db, d, KV.touch.node(String, db, h, d, acc))

def touch_entries(+hs: List<&2, U32>, +db: KV.Trie<String>, acc: U32) -> U32:
  match hs:
    case Nil{}:
      acc
    case Con{+h, +rest}:
      touch_entries(rest, db, KV.touch.entry(String, db, h, acc))

# the hints for a batch: the nodes at depth 4 (the top four levels stay in
# the cache), then the buckets, then their first keys and values
def touch_batch(hs: List<&2, U32>, +db: KV.Trie<String>) -> U32:
  +h = hs
  touch_entries(h, db, touch_nodes(h, db, 5n, touch_nodes(h, db, 4n, 0)))

# the hints of a batch of two commands or more
def touch_if(many: Bool, hs: List<&2, U32>, +db: KV.Trie<String>) -> U32:
  match many:
    case True{}:
      touch_batch(hs, db)
    case False{}:
      0

# the batch run once the hints are done: u is their result, and both arms
# run the batch alike, so the hints come first and change nothing
def exec_hinted(u: Bool, cmds: List<&2, R.Cmd>, db: KV.Trie<String>) -> List<&2, R.Reply> & KV.Trie<String>:
  match u:
    case True{}:
      R.exec_all(cmds, db)
    case False{}:
      R.exec_all(cmds, db)

def exec_batch(cmds: List<&2, R.Cmd>, hs: List<&2, U32>, db: KV.Trie<String>) -> List<&2, R.Reply> & KV.Trie<String>:
  +d = db
  +h = hs
  exec_hinted(U32.is_eq(touch_if(many(h), h, d), 0), cmds, d)
