# redis.bend: the semantics of the Redis commands BendKV serves, as one
# pure function exec(cmd, db) -> (reply, db'). The server (server.bend)
# only moves bytes and calls exec in order, as Redis's single command
# thread does, so every law about exec is a law about the running server.

import Base
import ./map.bend as KV

# Types
# -----

# the database: string keys to string values (Redis strings are bytes;
# BendKV keeps one byte per Char) in a trie (t), and beside it how many
# keys the trie holds (n: kept as the commands change the trie, so that
# DBSIZE and INFO's keyspace do not count them), how many of them have a
# time to live (x) and the time at which a batch's commands run (now, ms
# since 1970). x and now are 0 until keys expire. rr is always None: a
# field of the record's own type makes the compiler box the record (a
# record of plain fields travels as separate registers, and each call
# that passes the database on would pass every field).
type Db is Data:
  Db{t: KV.Trie<String>, n: Nat, x: Nat, now: Nat, rr: Maybe<&2, Db>}

# an integer: IPos{n} is n, INeg{n} is -(n+1), so each integer has one form
type Int is Data:
  IPos{n: Nat}
  INeg{n: Nat}

# a RESP2 reply; an array holds replies, so arrays nest (HELLO, the
# tracking info of CLIENT)
type Reply is Data:
  RStatus{s: String}
  RError{s: String}
  RInt{i: Int}
  RBulk{s: String}
  RNull{}
  RArray{xs: List<&2, Reply>}

# a key and a value, for MSET
type KVPair is Data:
  KP{key: String, val: String}

# A read of one key whose reply depends on what the key holds at now
# alone (its value and the time it expires at, when it is there): its
# type (TYPE), its length (STRLEN), its time to live in s or ms (TTL,
# PTTL) or the time it expires at (EXPIRETIME, PEXPIRETIME). The laws see
# them as one command, Peek (LAWS.bend: disturbs), so one more needs no
# more proof. Each is a constructor of its own, with no fields: a command
# travels in registers as wide as its widest form.
type PeekOp is Data:
  PType{}
  PStrlen{}
  PTtl{}
  PPttl{}
  PExpTime{}
  PPExpTime{}

# A time a command names, in ms (a time in s, times 1000; Times, below):
# a short one (TmN, below 10^14) or any other long long (TmB: its sign and
# its magnitude hi * 10^9 + lo); at says whether it counts from 1970
# (EXAT, PXAT, EXPIREAT, PEXPIREAT) or from now
type Tm is Data:
  TmN{at: Bool, ms: Nat}
  TmB{at: Bool, neg: Bool, hi: Nat, lo: Nat}

# the time to live SET leaves: none (TNone), the one the key had (TKeep:
# KEEPTTL), or a time (TAt; checked as SET reads it)
type SetTtl is Data:
  TNone{}
  TKeep{}
  TAt{t: Tm}

# GETEX's option: none, PERSIST, or a time, kept as it came (at: EXAT or
# PXAT; ms: PX or PXAT), as GETEX reads it only once it finds the key
type ExOpt is Data:
  XNone{}
  XPersist{}
  XAt{at: Bool, ms: Bool, v: String}

# EXPIRE's conditions: NX, XX, GT, LT (NX goes with none of the others,
# nor GT with LT)
type ExpIf is Data:
  ExpIf{nx: Bool, xx: Bool, gt: Bool, lt: Bool}

# A write of one key whose reply and change depend on what the key holds
# at now alone: SETNX, APPEND, SET with options (and SETEX, PSETEX: cond 0
# none, 1 NX, 2 XX; name is the command's, for its errors), an update
# whose reply is the old value (UGet: SET's GET option, and GETSET, which
# is SET with GET), GETEX, GETDEL, EXPIRE and its kin (t from now or from
# 1970), PERSIST, and INCRBY (UIncr: as the append-only file sees it,
# aof.bend; the server runs INCRBY as its own command, IncrBy, the same
# way, faster). The laws see them as one command, Upd, so one more needs
# no more proof. UGet holds an update, so the compiler makes an update a
# node of its own: a command travels in registers as wide as its widest
# form, and an update's options are many.
type UpdOp is Data:
  USetNx{v: String}
  UGet{op: UpdOp}
  UAppend{v: String}
  USet{v: String, cond: Nat, ttl: SetTtl, name: String}
  UGetEx{o: ExOpt}
  UGetDel{}
  UExpire{t: Tm, c: ExpIf, name: String}
  UPersist{}
  UIncr{by: Int}

# The commands of a connection and of the server: session.bend runs
# them, with the state of the connection and of the server, and none of
# them changes the database. They come as one command, Own, which exec
# never meets (it answers one with an error), so the laws see them as
# one more command that only reads. A command whose reply is fixed (a
# HELP) is SReply; one the parser found wrong (an unknown subcommand, a
# wrong number of arguments) is SBad, answered as Redis answers those,
# before it asks a client to authenticate.

type SessOp is Data:
  SHello{args: List<&2, String>}
  SAuth{args: List<&2, String>}
  SSelect{db: String}
  SQuit{}
  SReset{}
  SClientId{}
  SClientGetName{}
  SClientSetName{name: String}
  SClientReply{mode: String}
  SConfigGet{args: List<&2, String>}
  SConfigSet{args: List<&2, String>}
  SConfigResetStat{}
  SInfo{args: List<&2, String>}
  SCommand{args: List<&2, String>}
  SRandomKey{}
  SReply{r: Reply}
  SBad{r: Reply}

# a parsed command
type Cmd is Data:
  Ping{}
  Echo{msg: String}
  Get{key: String}
  Set{key: String, val: String}
  Del{keys: List<&2, String>}
  Exists{keys: List<&2, String>}
  IncrBy{key: String, by: Int}
  MGet{keys: List<&2, String>}
  MSet{pairs: List<&2, KVPair>}
  DbSize{}
  FlushAll{}
  Keys{pattern: String}
  Scan{args: List<&2, String>}
  Peek{key: String, c: PeekOp}
  Upd{key: String, op: UpdOp}
  Own{op: SessOp}
  Bad{reply: Reply}

# Integers
# --------
# Redis integers are 64-bit; BendKV's are bounded by 14 decimal digits,
# so every sum of two stays below 2^48, where Bend's Nat must stay.

def int_sub_nat(+x: Nat, +y: Nat) -> Int:
  Bool.pick(Int, Nat.is_lt(x, y), INeg{Nat.sub(Nat.sub(y, x), 1n)}, IPos{Nat.sub(x, y)})

def int_add(a: Int, b: Int) -> Int:
  match a b:
    case IPos{x} IPos{y}:
      IPos{Nat.add(x, y)}
    case INeg{x} INeg{y}:
      INeg{1n+Nat.add(x, y)}
    case IPos{x} INeg{y}:
      int_sub_nat(x, 1n+y)
    case INeg{x} IPos{y}:
      int_sub_nat(y, 1n+x)

def int_neg(a: Int) -> Int:
  match a:
    case IPos{n}:
      match n:
        case 0n:
          IPos{0n}
        case 1n+p:
          INeg{p}
    case INeg{n}:
      IPos{1n+n}

def int_show(a: Int) -> String:
  match a:
    case IPos{n}:
      Nat.show(n)
    case INeg{n}:
      "-" ++ Nat.show(1n+n)

def int_mag(a: Int) -> Nat:
  match a:
    case IPos{n}:
      n
    case INeg{n}:
      1n+n

# the digit a code point stands for, when it is one
def int_digit.if(x: U32, ok: Bool) -> Maybe<&2, Nat>:
  match ok:
    case True{}:
      Some{U32.to_nat(U32.sub(x, 48))}
    case False{}:
      None{}

def int_digit(+x: U32) -> Maybe<&2, Nat>:
  int_digit.if(x, Bool.and(U32.is_ge(x, 48), U32.is_le(x, 57)))

def int_step(acc: Maybe<&2, Nat>, d: Maybe<&2, Nat>) -> Maybe<&2, Nat>:
  match acc d:
    case Some{a} Some{n}:
      Some{Nat.add(Nat.mul(a, 10n), n)}
    case _ _:
      None{}

# the k digits of s from index i, read left to right; None when one is not
# a digit. The string is read by index (String.code_at), not taken apart.
def int_digits(+s: String, k: Nat, +i: Nat, acc: Maybe<&2, Nat>) -> Maybe<&2, Nat>:
  match k:
    case 0n:
      acc
    case 1n+p:
      int_digits(s, p, Nat.add(i, 1n), int_step(acc, int_digit(String.code_at(s, i))))

# the n characters of s from index i as a magnitude: "0", or 1 to 14
# digits with no leading zero
def int_mag_read.gate(+s: String, +i: Nat, +n: Nat, ok: Bool) -> Maybe<&2, Nat>:
  match ok:
    case True{}:
      int_digits(s, n, i, Some{0n})
    case False{}:
      None{}

def int_mag_read(+s: String, +i: Nat, +n: Nat) -> Maybe<&2, Nat>:
  int_mag_read.gate(s, i, n, Bool.and(Bool.and(Nat.is_lt(0n, n), Nat.is_le(n, 14n)), Bool.or(Nat.is_eq(n, 1n), U32.is_ne(String.code_at(s, i), 48))))

def int_neg_of(m: Maybe<&2, Nat>) -> Maybe<&2, Int>:
  match m:
    case Some{n}:
      match n:
        case 0n:
          None{}
        case 1n+p:
          Some{INeg{p}}
    case None{}:
      None{}

def int_pos_of(m: Maybe<&2, Nat>) -> Maybe<&2, Int>:
  match m:
    case Some{n}:
      Some{IPos{n}}
    case None{}:
      None{}

def int_read.sign(+s: String, +n: Nat, neg: Bool) -> Maybe<&2, Int>:
  match neg:
    case True{}:
      int_neg_of(int_mag_read(s, 1n, Nat.sub(n, 1n)))
    case False{}:
      int_pos_of(int_mag_read(s, 0n, n))

# an integer in Redis's canonical form: an optional '-', no leading
# zeros, no '+', no spaces ("-0" is refused, as Redis does)
def int_read(+s: String) -> Maybe<&2, Int>:
  +n = String.length(s)
  int_read.sign(s, n, U32.is_eq(String.code_at(s, 0n), 45))

# an integer fits when its magnitude has at most 14 digits
def int_fits(a: Int) -> Bool:
  Nat.is_le(String.length(Nat.show(int_mag(a))), 14n)

# Replies
# -------

def r_ok() -> Reply:
  RStatus{"OK"}

def r_int(n: Nat) -> Reply:
  RInt{IPos{n}}

def r_get(m: Maybe<&2, String>) -> Reply:
  match m:
    case Some{s}:
      RBulk{s}
    case None{}:
      RNull{}

def i_get(m: Maybe<&2, String>) -> Reply:
  match m:
    case Some{s}:
      RBulk{s}
    case None{}:
      RNull{}

def e_arity(name: String) -> Cmd:
  Bad{RError{"ERR wrong number of arguments for '" ++ String.to_lower(name) ++ "' command"}}

def e_int() -> Reply:
  RError{"ERR value is not an integer or out of range"}

def e_syntax() -> Cmd:
  Bad{RError{"ERR syntax error"}}

# An error as Redis sends it: a CR or LF in it becomes a space, so the
# reply stays one line
def no_newlines(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{'\r', t}:
      SCon{' ', no_newlines(t)}
    case SCon{'\n', t}:
      SCon{' ', no_newlines(t)}
    case SCon{c, t}:
      SCon{c, no_newlines(t)}

# a string as C's functions read it: up to its first NUL. Redis compares
# option words with strcasecmp and formats errors with %s, which stop
# there
def cstr(+s: String) -> String:
  String.take(s, String.find(s, Chr{0}, 0n))

def crlf.last(c: Char) -> String:
  match c:
    case Chr{+x}:
      Bool.pick(String, Bool.or(U32.is_eq(x, 13), U32.is_eq(x, 10)), SNil{}, SCon{Chr{x}, SNil{}})

def crlf.drop(c: Char, t: String) -> String:
  match t:
    case SNil{}:
      crlf.last(c)
    case SCon{h, u}:
      SCon{c, SCon{h, u}}

# a string without the CRs and LFs it ends with
def trim_crlf(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{c, t}:
      crlf.drop(c, trim_crlf(t))

# an error as addReplyErrorFormat sends it: the CRs and LFs it ends with
# dropped, the others as spaces
def e_fmt(s: String) -> String:
  no_newlines(trim_crlf(s))

# Redis's reply to an unknown command: the name as it was sent (up to 128
# bytes) and its first arguments, each quoted and followed by a space,
# while they make less than 128 bytes, each cut to what is left
def unknown.arg(room: Bool, x: String, +acc: String) -> String:
  match room:
    case True{}:
      acc ++ "'" ++ String.take(x, Nat.sub(128n, String.length(acc))) ++ "' "
    case False{}:
      acc

def unknown.args(xs: List<&2, String>, +acc: String) -> String:
  match xs:
    case Nil{}:
      acc
    case Con{x, rest}:
      unknown.args(rest, unknown.arg(Nat.is_lt(String.length(acc), 128n), x, acc))

def e_unknown(name: String, args: List<&2, String>) -> Cmd:
  Bad{RError{no_newlines("ERR unknown command '" ++ String.take(name, 128n) ++ "', with args beginning with: " ++ unknown.args(args, ""))}}

def s_arity(name: String) -> SessOp:
  SBad{RError{"ERR wrong number of arguments for '" ++ name ++ "' command"}}

# Parsing
# -------
# a command arrives as its argument strings; the name is not case
# sensitive

# the pairs of MSET, or None on an odd count
def pairs.put(k: String, v: String, m: Maybe<&2, List<&2, KVPair>>) -> Maybe<&2, List<&2, KVPair>>:
  match m:
    case Some{ps}:
      Some{KP{k, v} <> ps}
    case None{}:
      None{}

def pairs(xs: List<&2, String>) -> Maybe<&2, List<&2, KVPair>>:
  match xs:
    case Nil{}:
      Some{Nil{}}
    case Con{k, Nil{}}:
      None{}
    case Con{k, Con{v, rest}}:
      pairs.put(k, v, pairs(rest))

def parse_mset(ps: Maybe<&2, List<&2, KVPair>>) -> Cmd:
  match ps:
    case Some{Nil{}}:
      e_arity("mset")
    case Some{Con{p, rest}}:
      MSet{p <> rest}
    case None{}:
      e_arity("mset")

def parse_incrby(k: String, by: Maybe<&2, Int>) -> Cmd:
  match by:
    case Some{n}:
      IncrBy{k, n}
    case None{}:
      Bad{e_int()}

def parse_decrby(k: String, by: Maybe<&2, Int>) -> Cmd:
  match by:
    case Some{n}:
      IncrBy{k, int_neg(n)}
    case None{}:
      Bad{e_int()}

# Container commands (CLIENT, FUNCTION) pick a subcommand by their first
# argument. An unknown one, and a wrong number of arguments, are errors
# found before the command runs, as Redis finds them when it looks the
# command up; the others come from the command itself (a Sess, which
# needs the connection to be authenticated).

def e_unknown_sub(sub: String, cmd: String) -> SessOp:
  SBad{RError{no_newlines("ERR unknown subcommand '" ++ String.take(sub, 128n) ++ "'. Try " ++ cmd ++ " HELP.")}}

# a subcommand's own complaint about its arguments
def e_sub_syntax(sub: String, cmd: String) -> Reply:
  RError{no_newlines("ERR unknown subcommand or wrong number of arguments for '" ++ String.take(sub, 128n) ++ "'. Try " ++ cmd ++ " HELP.")}

def statuses(xs: List<&2, String>) -> List<&2, Reply>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{x, rest}:
      RStatus{x} <> statuses(rest)

# a HELP reply: a header, the subcommands, and HELP itself
def help(cmd: String, lines: List<&2, String>) -> SessOp:
  SReply{RArray{statuses(Con{cmd ++ " <subcommand> [<arg> [value] [opt] ...]. Subcommands are:", List.append(&2, String, lines, ["HELP", "    Prints this help."])})}}

def client_help() -> List<&2, String>:
  ["CACHING (YES|NO)",
   "    Enable/disable tracking of the keys for next command in OPTIN/OPTOUT modes.",
   "GETREDIR",
   "    Return the client ID we are redirecting to when tracking is enabled.",
   "GETNAME",
   "    Return the name of the current connection.",
   "ID",
   "    Return the ID of the current connection.",
   "REPLY (ON|OFF|SKIP)",
   "    Control the replies sent to the current connection.",
   "SETNAME <name>",
   "    Assign the name <name> to the current connection.",
   "UNBLOCK <clientid> [TIMEOUT|ERROR]",
   "    Unblock the specified blocked client.",
   "TRACKINGINFO",
   "    Report tracking status for the current connection.",
   "NO-EVICT (ON|OFF)",
   "    Protect current client connection from eviction."]

def function_help() -> List<&2, String>:
  ["FLUSH [ASYNC|SYNC]",
   "    Delete all the libraries.",
   "    When called without the optional mode argument, the behavior is determined by the",
   "    lazyfree-lazy-user-flush configuration directive. Valid modes are:",
   "    * ASYNC: Asynchronously flush the libraries.",
   "    * SYNC: Synchronously flush the libraries."]

def sess_reply(r: Reply) -> SessOp:
  SReply{r}

# whether s is the word w (in upper case) in any case, as strcasecmp
# finds it: up to s's first NUL
def is_word(+s: String, w: String) -> Bool:
  String.eq(String.to_upper(cstr(s)), w)

# CLIENT: BendKV has no client tracking and no blocking commands, so the
# subcommands about them answer as Redis does when none is in use
def client_id(+n: String, len: Nat) -> Nat:
  match len:
    case 2n:
      Bool.pick(Nat, String.eq(n, "ID"), 1n, 0n)
    case 4n:
      Bool.pick(Nat, String.eq(n, "HELP"), 2n, 0n)
    case 5n:
      Bool.pick(Nat, String.eq(n, "REPLY"), 3n, 0n)
    case 7n:
      Bool.pick(Nat, String.eq(n, "GETNAME"), 4n,
      Bool.pick(Nat, String.eq(n, "SETNAME"), 5n,
      Bool.pick(Nat, String.eq(n, "CACHING"), 6n,
      Bool.pick(Nat, String.eq(n, "UNBLOCK"), 7n, 0n))))
    case 8n:
      Bool.pick(Nat, String.eq(n, "GETREDIR"), 8n,
      Bool.pick(Nat, String.eq(n, "NO-EVICT"), 9n, 0n))
    case 12n:
      Bool.pick(Nat, String.eq(n, "TRACKINGINFO"), 10n, 0n)
    case _:
      0n

# CLIENT NO-EVICT: BendKV evicts no clients, so it only checks the word
def no_evict(+on: String) -> SessOp:
  sess_reply(Bool.pick(Reply, Bool.or(is_word(on, "ON"), is_word(on, "OFF")), r_ok(), RError{"ERR syntax error"}))

# CLIENT UNBLOCK id [TIMEOUT|ERROR]: no client is ever blocked
def unblock_id(+id: String) -> Reply:
  Bool.pick(Reply, Maybe.is_some(&2, Int, int_read(id)), RInt{IPos{0n}}, e_int())

def unblock(sub: String, args: List<&2, String>) -> SessOp:
  match args:
    case Con{+id, Nil{}}:
      sess_reply(unblock_id(id))
    case Con{+id, Con{+why, Nil{}}}:
      sess_reply(Bool.pick(Reply, Bool.or(is_word(why, "TIMEOUT"), is_word(why, "ERROR")), unblock_id(id), RError{"ERR CLIENT UNBLOCK reason should be TIMEOUT or ERROR"}))
    case _:
      sess_reply(e_sub_syntax(sub, "CLIENT"))

def tracking_info() -> Reply:
  RArray{[RBulk{"flags"}, RArray{[RBulk{"off"}]}, RBulk{"redirect"}, RInt{INeg{0n}}, RBulk{"prefixes"}, RArray{Nil{}}]}

def parse_client(id: Nat, sub: String, args: List<&2, String>) -> SessOp:
  match id:
    case 1n:  # ID
      match args:
        case Nil{}:
          SClientId{}
        case _:
          s_arity("client|id")
    case 2n:  # HELP
      match args:
        case Nil{}:
          help("CLIENT", client_help())
        case _:
          s_arity("client|help")
    case 3n:  # REPLY
      match args:
        case Con{m, Nil{}}:
          SClientReply{m}
        case _:
          s_arity("client|reply")
    case 4n:  # GETNAME
      match args:
        case Nil{}:
          SClientGetName{}
        case _:
          s_arity("client|getname")
    case 5n:  # SETNAME
      match args:
        case Con{n, Nil{}}:
          SClientSetName{n}
        case _:
          s_arity("client|setname")
    case 6n:  # CACHING
      match args:
        case Con{v, Nil{}}:
          sess_reply(RError{"ERR CLIENT CACHING can be called only when the client is in tracking mode with OPTIN or OPTOUT mode enabled"})
        case _:
          s_arity("client|caching")
    case 7n:  # UNBLOCK
      match args:
        case Nil{}:
          s_arity("client|unblock")
        case Con{a, rest}:
          unblock(sub, a <> rest)
    case 8n:  # GETREDIR
      match args:
        case Nil{}:
          sess_reply(RInt{INeg{0n}})
        case _:
          s_arity("client|getredir")
    case 9n:  # NO-EVICT
      match args:
        case Con{+on, Nil{}}:
          no_evict(on)
        case _:
          s_arity("client|no-evict")
    case 10n:  # TRACKINGINFO
      match args:
        case Nil{}:
          sess_reply(tracking_info())
        case _:
          s_arity("client|trackinginfo")
    case _:
      e_unknown_sub(sub, "CLIENT")

# FUNCTION: BendKV runs no functions, so there are none to flush
def function_id(+n: String, len: Nat) -> Nat:
  match len:
    case 4n:
      Bool.pick(Nat, String.eq(n, "HELP"), 2n, 0n)
    case 5n:
      Bool.pick(Nat, String.eq(n, "FLUSH"), 1n, 0n)
    case _:
      0n

def function_flush(sub: String, args: List<&2, String>) -> SessOp:
  match args:
    case Nil{}:
      sess_reply(r_ok())
    case Con{+m, Nil{}}:
      sess_reply(Bool.pick(Reply, Bool.or(is_word(m, "SYNC"), is_word(m, "ASYNC")), r_ok(), RError{"ERR FUNCTION FLUSH only supports SYNC|ASYNC option"}))
    case _:
      sess_reply(e_sub_syntax(sub, "FUNCTION"))

def parse_function(id: Nat, sub: String, args: List<&2, String>) -> SessOp:
  match id:
    case 1n:  # FLUSH
      function_flush(sub, args)
    case 2n:  # HELP
      match args:
        case Nil{}:
          help("FUNCTION", function_help())
        case _:
          s_arity("function|help")
    case _:
      e_unknown_sub(sub, "FUNCTION")

# COMMAND: Redis's description of each command BendKV has (command.bend)
def command_id(+n: String, len: Nat) -> Nat:
  match len:
    case 4n:
      Bool.pick(Nat, String.eq(n, "INFO"), 1n,
      Bool.pick(Nat, String.eq(n, "DOCS"), 2n,
      Bool.pick(Nat, String.eq(n, "LIST"), 3n,
      Bool.pick(Nat, String.eq(n, "HELP"), 4n, 0n))))
    case 5n:
      Bool.pick(Nat, String.eq(n, "COUNT"), 5n, 0n)
    case 7n:
      Bool.pick(Nat, String.eq(n, "GETKEYS"), 6n, 0n)
    case 15n:
      Bool.pick(Nat, String.eq(n, "GETKEYSANDFLAGS"), 7n, 0n)
    case _:
      0n

def command_help() -> List<&2, String>:
  ["(no subcommand)",
   "    Return details about all Redis commands.",
   "COUNT",
   "    Return the total number of commands in this Redis server.",
   "LIST",
   "    Return a list of all commands in this Redis server.",
   "INFO [<command-name> ...]",
   "    Return details about multiple Redis commands.",
   "    If no command names are given, documentation details for all",
   "    commands are returned.",
   "DOCS [<command-name> ...]",
   "    Return documentation details about multiple Redis commands.",
   "    If no command names are given, documentation details for all",
   "    commands are returned.",
   "GETKEYS <full-command>",
   "    Return the keys from a full Redis command.",
   "GETKEYSANDFLAGS <full-command>",
   "    Return the keys and the access flags from a full Redis command."]

# GETKEYS and GETKEYSANDFLAGS take a command and at least one argument
def command_keys(+sub: String, args: List<&2, String>, name: String) -> SessOp:
  match args:
    case Con{c, Con{a, rest}}:
      SCommand{sub <> (c <> (a <> rest))}
    case _:
      s_arity(name)

# the subcommands with a wrong number of arguments, the unknown ones and
# HELP are answered here; command.bend answers the others (SCommand holds
# COMMAND's arguments as they came, so that a command is a word wider
# for none of them)
def parse_command(id: Nat, +sub: String, args: List<&2, String>) -> SessOp:
  match id:
    case 1n:  # INFO
      SCommand{sub <> args}
    case 2n:  # DOCS
      SCommand{sub <> args}
    case 3n:  # LIST
      SCommand{sub <> args}
    case 4n:  # HELP
      match args:
        case Nil{}:
          help("COMMAND", command_help())
        case _:
          s_arity("command|help")
    case 5n:  # COUNT
      match args:
        case Nil{}:
          SCommand{[sub]}
        case _:
          s_arity("command|count")
    case 6n:  # GETKEYS
      command_keys(sub, args, "command|getkeys")
    case 7n:  # GETKEYSANDFLAGS
      command_keys(sub, args, "command|getkeysandflags")
    case _:
      e_unknown_sub(sub, "COMMAND")

# CONFIG: GET and SET of the server's parameters (config.bend), RESETSTAT,
# and REWRITE, which fails as Redis fails without a config file
def config_id(+n: String, len: Nat) -> Nat:
  match len:
    case 3n:
      Bool.pick(Nat, String.eq(n, "GET"), 1n, Bool.pick(Nat, String.eq(n, "SET"), 2n, 0n))
    case 4n:
      Bool.pick(Nat, String.eq(n, "HELP"), 5n, 0n)
    case 7n:
      Bool.pick(Nat, String.eq(n, "REWRITE"), 4n, 0n)
    case 9n:
      Bool.pick(Nat, String.eq(n, "RESETSTAT"), 3n, 0n)
    case _:
      0n

def config_help() -> List<&2, String>:
  ["GET <pattern>",
   "    Return parameters matching the glob-like <pattern> and their values.",
   "SET <directive> <value>",
   "    Set the configuration <directive> to <value>.",
   "RESETSTAT",
   "    Reset statistics reported by the INFO command.",
   "REWRITE",
   "    Rewrite the configuration file."]

def config_set(args: List<&2, String>) -> SessOp:
  match args:
    case Con{n, Con{v, +rest}}:
      Bool.pick(SessOp, Nat.is_eq(Nat.mod(List.length(&2, String, rest), 2n), 0n), SConfigSet{Con{n, Con{v, rest}}}, sess_reply(RError{"ERR syntax error"}))
    case _:
      s_arity("config|set")

def parse_config(id: Nat, sub: String, args: List<&2, String>) -> SessOp:
  match id:
    case 1n:  # GET
      match args:
        case Nil{}:
          s_arity("config|get")
        case Con{a, rest}:
          SConfigGet{a <> rest}
    case 2n:  # SET
      config_set(args)
    case 3n:  # RESETSTAT
      match args:
        case Nil{}:
          SConfigResetStat{}
        case _:
          s_arity("config|resetstat")
    case 4n:  # REWRITE
      match args:
        case Nil{}:
          sess_reply(RError{"ERR The server is running without a config file"})
        case _:
          s_arity("config|rewrite")
    case 5n:  # HELP
      match args:
        case Nil{}:
          help("CONFIG", config_help())
        case _:
          s_arity("config|help")
    case _:
      e_unknown_sub(sub, "CONFIG")

# FLUSHALL and FLUSHDB take ASYNC or SYNC, which change nothing here
def parse_flush(args: List<&2, String>) -> Cmd:
  match args:
    case Nil{}:
      FlushAll{}
    case Con{+m, Nil{}}:
      Bool.pick(Cmd, Bool.or(is_word(m, "SYNC"), is_word(m, "ASYNC")), FlushAll{}, e_syntax())
    case _:
      e_syntax()

# SCAN
# ----
# SCAN cursor [MATCH pattern] [COUNT count] [TYPE type], as Redis 7.0.15
# reads it: the cursor first ("ERR invalid cursor"), then the options in
# any order, a later one over an earlier one, each with its value (an
# option without one, or another word, is a syntax error); COUNT a long
# integer (not one: "ERR value is not an integer or out of range"), 1 or
# more (else a syntax error). The parser checks them, and the command
# keeps its arguments as they came (one word in Cmd); exec reads them
# again. The cursor is the index of a bucket (KV.scan): the reply is the
# next one, 0 at the end, and the keys of the buckets read, COUNT of
# them at least, then filtered by the pattern and the type.

# Long decimals: the digits of s from index i to index e, as Redis's
# string2ll and strtoul read them past what a Nat holds: whether all were
# digits, how many there were, whether the first was 0, how many came
# after the leading zeros, and of those the first ten (hi) and the next
# ten (lo).
type Dec is Data:
  Dec{ok: Bool, n: Nat, zero: Bool, sig: Nat, hi: Nat, lo: Nat}

# a digit d after n others: a leading zero (lead) counts in n only
def dec.lead(lead: Bool, +d: Nat, +n: Nat, z: Bool, +sig: Nat, +hi: Nat, +lo: Nat) -> Dec:
  match lead:
    case True{}:
      Dec{True{}, Nat.add(n, 1n), Bool.or(z, Nat.is_eq(n, 0n)), sig, hi, lo}
    case False{}:
      Dec{True{}, Nat.add(n, 1n), z, Nat.add(sig, 1n),
        Bool.pick(Nat, Nat.is_lt(sig, 10n), Nat.add(Nat.mul(hi, 10n), d), hi),
        Bool.pick(Nat, Bool.and(Nat.is_le(10n, sig), Nat.is_lt(sig, 20n)), Nat.add(Nat.mul(lo, 10n), d), lo)}

def dec.next(digit: Bool, +c: U32, +n: Nat, z: Bool, +sig: Nat, +hi: Nat, +lo: Nat) -> Dec:
  match digit:
    case True{}:
      +d = U32.to_nat(U32.sub(c, 48))
      dec.lead(Bool.and(Nat.is_eq(d, 0n), Nat.is_eq(sig, 0n)), d, n, z, sig, hi, lo)
    case False{}:
      Dec{False{}, n, z, sig, hi, lo}

def dec.go(fuel: Nat, +s: String, +i: Nat, d: Dec) -> Dec:
  match fuel d:
    case 0n d:
      d
    case 1n+f Dec{False{}, n, z, sig, hi, lo}:
      Dec{False{}, n, z, sig, hi, lo}
    case 1n+f Dec{True{}, +n, z, +sig, +hi, +lo}:
      +c = String.code_at(s, i)
      dec.go(f, s, Nat.add(i, 1n), dec.next(U32.is_lt(U32.sub(c, 48), 10), c, n, z, sig, hi, lo))

# the digits of s from index i to index e
def dec.of(+s: String, +i: Nat, +e: Nat) -> Dec:
  dec.go(Nat.sub(e, i), s, i, Dec{True{}, 0n, False{}, 0n, 0n, 0n})

# whether a magnitude of sig significant digits (hi, then lo) is at most
# the one of msig digits (19 or 20) whose first ten are mh and the rest ml
def dec.le(+sig: Nat, +hi: Nat, +lo: Nat, +msig: Nat, +mh: Nat, +ml: Nat) -> Bool:
  Bool.or(Nat.is_lt(sig, msig), Bool.and(Nat.is_eq(sig, msig), Bool.or(Nat.is_lt(hi, mh), Bool.and(Nat.is_eq(hi, mh), Nat.is_le(lo, ml)))))

# the first ten digits of 2^63 - 1 and of 2^63
def dec.llmax() -> Nat:
  Nat.add(Nat.mul(922337n, 10000n), 2036n)

# a magnitude of sig significant digits, at most cap: the cap when it
# has more than ten digits (cap is 10^10 at most)
def dec.cap(+sig: Nat, +hi: Nat, +cap: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_le(sig, 10n), Nat.min(hi, cap), cap)

# the blanks of C's isspace
def is_blank(+c: U32) -> Bool:
  Bool.or(U32.is_eq(c, 32), U32.is_lt(U32.sub(c, 9), 5))

# SCAN's cursor, as Redis 7.0.15 reads it (strtoul): no blank first, a
# sign, then digits up to the end of the string or its first NUL, 2^64 - 1
# at most; the empty string is 0. None when it is no cursor. A cursor past
# the last bucket, or a negative one, reads as 2^20, where a scan finds
# nothing.
def cur.of(+d: Dec, blank: Bool, +neg: Bool, empty: Bool) -> Maybe<&2, Nat>:
  match d:
    case Dec{+ok, +n, +zero, +sig, +hi, +lo}:
      +fits = dec.le(sig, hi, lo, 20n, 1844674407n, 3709551615n)
      Bool.pick(Maybe<&2, Nat>, Bool.and(Bool.and(Bool.not(blank), Bool.and(ok, fits)), Bool.or(Nat.is_lt(0n, n), empty)),
        Some{Bool.pick(Nat, Bool.and(neg, Nat.is_lt(0n, sig)), 1048576n, dec.cap(sig, hi, 1048576n))}, None{})

def scan.cursor(+s: String) -> Maybe<&2, Nat>:
  +c = String.code_at(s, 0n)
  +e = String.find(s, Chr{0}, 0n)
  +at = Bool.pick(Nat, Bool.or(U32.is_eq(c, 43), U32.is_eq(c, 45)), 1n, 0n)
  cur.of(dec.of(s, Nat.min(at, e), e), is_blank(c), U32.is_eq(c, 45), Nat.is_eq(e, 0n))

# COUNT, as Redis's string2ll reads a long long: an optional '-', then
# digits with no leading zero (or 0 alone); None when it is not one. Past
# ten digits it reads as 10^10, more keys than BendKV holds.
def scan.count.of(+d: Dec, +neg: Bool) -> Maybe<&2, Int>:
  match d:
    case Dec{+ok, +n, +zero, +sig, +hi, +lo}:
      +canon = Bool.or(Bool.not(zero), Bool.and(Nat.is_eq(n, 1n), Bool.not(neg)))
      +fits = dec.le(sig, hi, lo, 19n, dec.llmax(), Bool.pick(Nat, neg, 854775808n, 854775807n))
      +v = dec.cap(sig, hi, Nat.mul(100000n, 100000n))
      Bool.pick(Maybe<&2, Int>, Bool.and(Bool.and(Bool.and(ok, Nat.is_lt(0n, n)), canon), fits),
        Some{Bool.pick(Int, Bool.and(neg, Nat.is_lt(0n, v)), INeg{Nat.sub(v, 1n)}, IPos{v})}, None{})

def scan.count(+s: String) -> Maybe<&2, Int>:
  +neg = U32.is_eq(String.code_at(s, 0n), 45)
  scan.count.of(dec.of(s, Bool.pick(Nat, neg, 1n, 0n), String.length(s)), neg)

# SCAN's arguments read
type ScanArgs is Data:
  ScanArgs{cur: Nat, count: Nat, pat: Maybe<&2, String>, typ: Maybe<&2, String>}
  ScanBad{r: Reply}

def scan.count.set(m: Maybe<&2, Int>, +cur: Nat, pat: Maybe<&2, String>, typ: Maybe<&2, String>) -> ScanArgs:
  match m:
    case Some{IPos{+n}}:
      Bool.pick(ScanArgs, Nat.is_lt(0n, n), ScanArgs{cur, n, pat, typ}, ScanBad{RError{"ERR syntax error"}})
    case Some{INeg{n}}:
      ScanBad{RError{"ERR syntax error"}}
    case None{}:
      ScanBad{e_int()}

# an option and its value: COUNT (1), MATCH (2), TYPE (3), another word (0)
def scan.word(+w: String) -> Nat:
  Bool.pick(Nat, is_word(w, "COUNT"), 1n, Bool.pick(Nat, is_word(w, "MATCH"), 2n, Bool.pick(Nat, is_word(w, "TYPE"), 3n, 0n)))

def scan.set(o: Nat, v: String, +cur: Nat, +n: Nat, pat: Maybe<&2, String>, typ: Maybe<&2, String>) -> ScanArgs:
  match o:
    case 1n:
      scan.count.set(scan.count(v), cur, pat, typ)
    case 2n:
      ScanArgs{cur, n, Some{v}, typ}
    case 3n:
      ScanArgs{cur, n, pat, Some{v}}
    case _:
      ScanBad{RError{"ERR syntax error"}}

def scan.opts(xs: List<&2, String>, a: ScanArgs) -> ScanArgs:
  match xs a:
    case _ ScanBad{r}:
      ScanBad{r}
    case Nil{} a:
      a
    case Con{+w, Con{v, rest}} ScanArgs{+cur, +n, pat, typ}:
      scan.opts(rest, scan.set(scan.word(w), v, cur, n, pat, typ))
    case Con{w, Nil{}} ScanArgs{cur, n, pat, typ}:
      ScanBad{RError{"ERR syntax error"}}

def scan.args.of(c: Maybe<&2, Nat>, rest: List<&2, String>) -> ScanArgs:
  match c:
    case Some{+cur}:
      scan.opts(rest, ScanArgs{cur, 10n, None{}, None{}})
    case None{}:
      ScanBad{RError{"ERR invalid cursor"}}

def scan.args(args: List<&2, String>) -> ScanArgs:
  match args:
    case Con{+c, rest}:
      scan.args.of(scan.cursor(c), rest)
    case Nil{}:
      ScanBad{RError{"ERR invalid cursor"}}

def scan.check(a: ScanArgs, args: List<&2, String>) -> Cmd:
  match a:
    case ScanBad{r}:
      Bad{r}
    case _:
      Scan{args}

def scan.parse(+args: List<&2, String>) -> Cmd:
  scan.check(scan.args(args), args)

# Times
# -----
# A time a command names is a long long, read as Redis's string2ll reads
# one. Most are short: no sign, no leading zero, below 10^14 (all the
# times the append-only file holds, as PXAT and PEXPIREAT give them). A
# short one reads digit by digit as a Nat (num14), as the file's lengths
# do, and PROOF.bend shows that what Nat.show writes reads back so
# (num14_show); any other goes through Dec, which keeps its magnitude as
# hi * 10^9 + lo, so that Redis's checks of overflow near 2^63 come out
# exactly. A time in s counts as 1000 times as many ms. A time from 1970
# at or past 10^14 ms (the year 5138) is far (AtFar): a key gets no time
# for it, as it would never come (a Nat holds 2^48 - 1 at most). No
# number here is built from 10^13 or 10^14: digits are counted instead,
# as the proofs never build such numbers.

# what a char is to a short number: a digit and its value, or not one
type NCh is Data:
  NDig{d: Nat}
  NOther{}

def nch.of(+x: U32, dig: Bool) -> NCh:
  match dig:
    case True{}:
      NDig{U32.to_nat(U32.sub(x, 48))}
    case False{}:
      NOther{}

def nch(s: String) -> NCh:
  match s:
    case SCon{Chr{+x}, t}:
      nch.of(x, U32.is_lt(U32.sub(x, 48), 10))
    case SNil{}:
      NOther{}

# the next char, when a digit may come after the number a of n digits:
# a has 13 digits at most and no leading 0 (a number that is 0 takes no
# more digits)
def n14.next(+n: Nat, +a: Nat, c: NCh) -> NCh:
  match c:
    case NDig{d}:
      Bool.pick(NCh, Bool.and(Nat.is_lt(n, 14n), Nat.is_lt(0n, a)), NDig{d}, NOther{})
    case NOther{}:
      NOther{}

def num14.end(lead: Bool, acc: Nat) -> Maybe<&2, Nat>:
  match lead:
    case True{}:
      Some{acc}
    case False{}:
      None{}

# the number the digits of s make after acc (of n digits), when s holds
# digits only, one at least (lead: a digit came), with no leading 0, and
# the number has 14 digits at most (is below 10^14); c is what s's first
# char is
def num14(s: String, acc: Nat, +n: Nat, lead: Bool, c: NCh) -> Maybe<&2, Nat>:
  match s c:
    case SCon{h, +t} NDig{d}:
      +a = Nat.add(Nat.mul(acc, 10n), d)
      num14(t, a, 1n+n, True{}, n14.next(1n+n, a, nch(t)))
    case SNil{} _:
      num14.end(lead, acc)
    case _ _:
      None{}

# a long long as Redis's string2ll reads one, past what num14 reads: its
# sign and its magnitude (hi * 10^9 + lo), or none
type LL is Data:
  LL{neg: Bool, hi: Nat, lo: Nat}
  LLBad{}

def pow10(k: Nat) -> Nat:
  match k:
    case 0n:
      1n
    case 1n+j:
      Nat.mul(10n, pow10(j))

# a magnitude of sig significant digits (the first ten hi, the next ten
# lo, as Dec keeps them), split at 10^9: with j digits in lo, hi's last
# 9 - j digits go before lo
def ll.mk(+neg: Bool, +sig: Nat, +hi: Nat, +lo: Nat) -> LL:
  +j = Nat.sub(sig, 10n)
  +p = pow10(Nat.sub(9n, j))
  Bool.pick(LL, Nat.is_le(sig, 10n), LL{neg, Nat.div(hi, 1000000000n), Nat.mod(hi, 1000000000n)},
    LL{neg, Nat.div(hi, p), Nat.add(Nat.mul(Nat.mod(hi, p), pow10(j)), lo)})

def ll.of(+d: Dec, +neg: Bool) -> LL:
  match d:
    case Dec{+ok, +n, +zero, +sig, +hi, +lo}:
      +canon = Bool.or(Bool.not(zero), Bool.and(Nat.is_eq(n, 1n), Bool.not(neg)))
      +fits = dec.le(sig, hi, lo, 19n, dec.llmax(), Bool.pick(Nat, neg, 854775808n, 854775807n))
      Bool.pick(LL, Bool.and(Bool.and(Bool.and(ok, Nat.is_lt(0n, n)), canon), fits), ll.mk(neg, sig, hi, lo), LLBad{})

def ll.read(+s: String) -> LL:
  +neg = U32.is_eq(String.code_at(s, 0n), 45)
  ll.of(dec.of(s, Bool.pick(Nat, neg, 1n, 0n), String.length(s)), neg)

# whether a magnitude hi * 10^9 + lo is at most hb * 10^9 + lb
def ll.le(+hi: Nat, +lo: Nat, +hb: Nat, +lb: Nat) -> Bool:
  Bool.or(Nat.is_lt(hi, hb), Bool.and(Nat.is_eq(hi, hb), Nat.is_le(lo, lb)))

# a time in s as ms: its magnitude times 1000, at most LLONG_MAX / 1000
# (9223372036854775) before
def ll.ms(+hi: Nat, +lo: Nat) -> Nat & Nat:
  (Nat.add(Nat.mul(hi, 1000n), Nat.div(lo, 1000000n)), Nat.mul(Nat.mod(lo, 1000000n), 1000n))

# a time as a command reads it, or the error it answers
type TmR is Data:
  TOk{t: Tm}
  TBad{r: Reply}

def e_time(+name: String) -> Reply:
  RError{"ERR invalid expire time in '" ++ name ++ "' command"}

def tm.big.ms(+at: Bool, secs: Bool, +neg: Bool, ms: Nat & Nat, +hi: Nat, +lo: Nat) -> Tm:
  (+mh, +ml) = ms
  Bool.pick(Tm, secs, TmB{at, neg, mh, ml}, TmB{at, neg, hi, lo})

# a long time: in s, its magnitude past LLONG_MAX / 1000 is an error; one
# that is 0 or less is when pos (SET's and GETEX's)
def tm.big(+at: Bool, +secs: Bool, +pos: Bool, +name: String, l: LL) -> TmR:
  match l:
    case LL{+neg, +hi, +lo}:
      +zero = Bool.and(Nat.is_eq(hi, 0n), Nat.is_eq(lo, 0n))
      +bad = Bool.or(Bool.and(pos, Bool.or(neg, zero)), Bool.and(secs, Bool.not(ll.le(hi, lo, 9223372n, 36854775n))))
      Bool.pick(TmR, bad, TBad{e_time(name)}, TOk{tm.big.ms(at, secs, neg, ll.ms(hi, lo), hi, lo)})
    case LLBad{}:
      TBad{e_int()}

def tm.pair(+at: Bool, ms: Nat & Nat) -> Tm:
  (+h, +l) = ms
  TmB{at, False{}, h, l}

# a short time in s: as ms, a TmN below 10^11 s (small), else a TmB (the
# ms past 10^14 would not fit a Nat). A def, not a Bool.pick, so that the
# product is made only when it fits; so in the defs below.
def tm.short.s(small: Bool, +at: Bool, +n: Nat) -> Tm:
  match small:
    case True{}:
      TmN{at, Nat.mul(n, 1000n)}
    case False{}:
      tm.pair(at, ll.ms(Nat.div(n, 1000000000n), Nat.mod(n, 1000000000n)))

# a short time: in ms below 10^14 a TmN, in s as tm.short.s makes it; 0
# is an error when pos
def tm.short(+at: Bool, +secs: Bool, +pos: Bool, +name: String, +n: Nat) -> TmR:
  Bool.pick(TmR, Bool.and(pos, Nat.is_eq(n, 0n)), TBad{e_time(name)},
    TOk{Bool.pick(Tm, secs, tm.short.s(KV.digits.le(11n, n), at, n), TmN{at, n})})

def tm.of.go(m: Maybe<&2, Nat>, +s: String, +at: Bool, +secs: Bool, +pos: Bool, +name: String) -> TmR:
  match m:
    case Some{n}:
      tm.short(at, secs, pos, name, n)
    case None{}:
      tm.big(at, secs, pos, name, ll.read(s))

# a time s names: from 1970 (at) or from now, in s or ms; pos when it must
# be more than 0 (SET, SETEX, PSETEX, GETEX), and name the command's
def tm.of(+s: String, +at: Bool, +secs: Bool, +pos: Bool, +name: String) -> TmR:
  tm.of.go(num14(s, 0n, 0n, False{}, nch(s)), s, at, secs, pos, name)

# The time a command's time comes to at now: before or at 1970 (AtPast),
# at ms (AtMs, below 10^14: KV.small), or at 10^14 ms or later (AtFar, a
# time that never comes); None when a time from now overflows LLONG_MAX
# (Redis: "invalid expire time")
type At is Data:
  AtPast{}
  AtMs{ms: Nat}
  AtFar{}

def at.ms(+m: Nat) -> At:
  Bool.pick(At, KV.small(m), AtMs{m}, AtFar{})

# a time from now of m ms less
def at.sub(+m: Nat, +now: Nat) -> At:
  Bool.pick(At, Nat.is_le(m, now), AtMs{Nat.sub(now, m)}, AtPast{})

# a time of hi * 10^9 + lo ms from 1970, made only when hi is below 10^5
# (small); and that many ms before now
def at.big(small: Bool, +hi: Nat, +lo: Nat) -> At:
  match small:
    case True{}:
      at.ms(Nat.add(Nat.mul(hi, 1000000000n), lo))
    case False{}:
      AtFar{}

def at.big.sub(small: Bool, +hi: Nat, +lo: Nat, +now: Nat) -> At:
  match small:
    case True{}:
      at.sub(Nat.add(Nat.mul(hi, 1000000000n), lo), now)
    case False{}:
      AtPast{}

# a time from now of hi * 10^9 + lo ms more: past LLONG_MAX
# (9223372036 * 10^9 + 854775807) is an overflow
def at.add(+hi: Nat, +lo: Nat, +now: Nat) -> Maybe<&2, At>:
  +l = Nat.add(lo, Nat.mod(now, 1000000000n))
  +h = Nat.add(Nat.add(hi, Nat.div(now, 1000000000n)), Nat.div(l, 1000000000n))
  +l2 = Nat.mod(l, 1000000000n)
  Bool.pick(Maybe<&2, At>, ll.le(h, l2, dec.llmax(), 854775807n), Some{at.big(Nat.is_lt(h, 100000n), h, l2)}, None{})

def at.of(t: Tm, +now: Nat) -> Maybe<&2, At>:
  match t:
    case TmN{at, +ms}:
      match at:
        case True{}:
          Some{at.ms(ms)}
        case False{}:
          Some{at.ms(Nat.add(ms, now))}
    case TmB{at, neg, +hi, +lo}:
      match at neg:
        case True{} True{}:
          Some{AtPast{}}
        case True{} False{}:
          Some{at.big(Nat.is_lt(hi, 100000n), hi, lo)}
        case False{} True{}:
          Some{at.big.sub(Nat.is_lt(hi, 100000n), hi, lo, now)}
        case False{} False{}:
          at.add(hi, lo, now)

# whether a time is past at now (Redis's checkAlreadyExpired: at or
# before now)
def at.past(+a: At, +now: Nat) -> Bool:
  match a:
    case AtPast{}:
      True{}
    case AtMs{+m}:
      Nat.is_le(m, now)
    case AtFar{}:
      False{}

# the time a key keeps for a time that is not past: none for a far one
def at.exp(+a: At) -> Nat:
  match a:
    case AtPast{}:
      1n
    case AtMs{+m}:
      Nat.max(m, 1n)
    case AtFar{}:
      0n

# whether a time is after, and before, a key's time e (not 0)
def at.gt(+a: At, +e: Nat) -> Bool:
  match a:
    case AtPast{}:
      False{}
    case AtMs{+m}:
      Nat.is_lt(e, m)
    case AtFar{}:
      True{}

def at.lt(+a: At, +e: Nat) -> Bool:
  match a:
    case AtPast{}:
      True{}
    case AtMs{+m}:
      Nat.is_lt(m, e)
    case AtFar{}:
      False{}

# Options of SET, GETEX and EXPIRE
# --------------------------------
# SET's and GETEX's options as Redis's parseExtendedStringArgumentsOrReply
# reads them: SET takes NX, XX, GET and KEEPTTL, GETEX PERSIST, and both a
# time (EX, PX, EXAT, PXAT, with its value; the last one counts, of one
# kind only). Any word in any case; any other word, or one that clashes
# with those before it, is a syntax error. The time is read once the
# options are (tk: 0 none, 1 EX, 2 PX, 3 EXAT, 4 PXAT; tv its value).
type SetSt is Data:
  SetSt{nx: Bool, xx: Bool, get: Bool, keep: Bool, persist: Bool, tk: Nat, tv: String}
  SetBad{}

# NX 1, XX 2, GET 3, KEEPTTL 4, PERSIST 5, EX 6, PX 7, EXAT 8, PXAT 9,
# another word 0
def set.word(+w: String) -> Nat:
  Bool.pick(Nat, is_word(w, "NX"), 1n, Bool.pick(Nat, is_word(w, "XX"), 2n,
  Bool.pick(Nat, is_word(w, "GET"), 3n, Bool.pick(Nat, is_word(w, "KEEPTTL"), 4n,
  Bool.pick(Nat, is_word(w, "PERSIST"), 5n, Bool.pick(Nat, is_word(w, "EX"), 6n,
  Bool.pick(Nat, is_word(w, "PX"), 7n, Bool.pick(Nat, is_word(w, "EXAT"), 8n,
  Bool.pick(Nat, is_word(w, "PXAT"), 9n, 0n)))))))))

# a time option t (1 to 4) with its value, when ok
def set.time(+t: Nat, next: Maybe<&2, String>, ok: Bool, +nx: Bool, +xx: Bool, +get: Bool, +keep: Bool, +persist: Bool) -> SetSt:
  match next ok:
    case Some{v} True{}:
      SetSt{nx, xx, get, keep, persist, t, v}
    case _ _:
      SetBad{}

# whether a time option t may come: no KEEPTTL or PERSIST before it, and
# no time of another kind
def set.tok(+keep: Bool, +persist: Bool, +tk: Nat, +t: Nat) -> Bool:
  Bool.and(Bool.and(Bool.not(keep), Bool.not(persist)), Bool.or(Nat.is_eq(tk, 0n), Nat.is_eq(tk, t)))

def set.one.go(+set: Bool, +k: Nat, next: Maybe<&2, String>, +nx: Bool, +xx: Bool, +get: Bool, +keep: Bool, +persist: Bool, +tk: Nat, +tv: String) -> SetSt:
  match k:
    case 1n:
      Bool.pick(SetSt, Bool.and(set, Bool.not(xx)), SetSt{True{}, xx, get, keep, persist, tk, tv}, SetBad{})
    case 2n:
      Bool.pick(SetSt, Bool.and(set, Bool.not(nx)), SetSt{nx, True{}, get, keep, persist, tk, tv}, SetBad{})
    case 3n:
      Bool.pick(SetSt, set, SetSt{nx, xx, True{}, keep, persist, tk, tv}, SetBad{})
    case 4n:
      Bool.pick(SetSt, Bool.and(set, Bool.and(Bool.not(persist), Nat.is_eq(tk, 0n))), SetSt{nx, xx, get, True{}, persist, tk, tv}, SetBad{})
    case 5n:
      Bool.pick(SetSt, Bool.and(Bool.not(set), Bool.and(Nat.is_eq(tk, 0n), Bool.not(keep))), SetSt{nx, xx, get, keep, True{}, tk, tv}, SetBad{})
    case 6n:
      set.time(1n, next, set.tok(keep, persist, tk, 1n), nx, xx, get, keep, persist)
    case 7n:
      set.time(2n, next, set.tok(keep, persist, tk, 2n), nx, xx, get, keep, persist)
    case 8n:
      set.time(3n, next, set.tok(keep, persist, tk, 3n), nx, xx, get, keep, persist)
    case 9n:
      set.time(4n, next, set.tok(keep, persist, tk, 4n), nx, xx, get, keep, persist)
    case _:
      SetBad{}

def set.one(+set: Bool, +k: Nat, next: Maybe<&2, String>, st: SetSt) -> SetSt:
  match st:
    case SetSt{+nx, +xx, +get, +keep, +persist, +tk, +tv}:
      set.one.go(set, k, next, nx, xx, get, keep, persist, tk, tv)
    case SetBad{}:
      SetBad{}

def set.next(+xs: List<&2, String>) -> Maybe<&2, String>:
  match xs:
    case Con{+v, +rest}:
      Some{v}
    case Nil{}:
      None{}

# the options after option k: a time option took its value
def set.drop.go(drop: Bool, v: String, rest: List<&2, String>) -> List<&2, String>:
  match drop:
    case True{}:
      rest
    case False{}:
      v <> rest

def set.drop(+k: Nat, xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Con{v, rest}:
      set.drop.go(Nat.is_lt(5n, k), v, rest)
    case Nil{}:
      Nil{}

def set.opts(fuel: Nat, +set: Bool, xs: List<&2, String>, st: SetSt) -> SetSt:
  match fuel:
    case 0n:
      st
    case 1n+f:
      match xs:
        case Nil{}:
          st
        case Con{+w, rest}:
          +k = set.word(w)
          +r = rest
          next = set.next(r)
          set.opts(f, set, set.drop(k, r), set.one(set, k, next, st))

def set.init() -> SetSt:
  SetSt{False{}, False{}, False{}, False{}, False{}, 0n, ""}

# a time option's value read: from 1970 for EXAT and PXAT, in s for EX
# and EXAT, more than 0 (pos) as SET and GETEX read it
def set.tm(+tk: Nat, +tv: String, +name: String) -> TmR:
  tm.of(tv, Nat.is_lt(2n, tk), Bool.or(Nat.is_eq(tk, 1n), Nat.is_eq(tk, 3n)), True{}, name)

# SET's update, under GET when the option asks
def set.upd(get: Bool, op: UpdOp) -> UpdOp:
  match get:
    case True{}:
      UGet{op}
    case False{}:
      op

def set.ttl.cmd(+k: String, +v: String, +cond: Nat, +get: Bool, r: TmR, +name: String) -> Cmd:
  match r:
    case TOk{t}:
      Upd{k, set.upd(get, USet{v, cond, TAt{t}, name})}
    case TBad{e}:
      Bad{e}

def set.cmd(+k: String, +v: String, st: SetSt) -> Cmd:
  match st:
    case SetSt{+nx, +xx, +get, +keep, persist, +tk, +tv}:
      +cond = Bool.pick(Nat, nx, 1n, Bool.pick(Nat, xx, 2n, 0n))
      Bool.pick(Cmd, Nat.is_eq(tk, 0n), Upd{k, set.upd(get, USet{v, cond, Bool.pick(SetTtl, keep, TKeep{}, TNone{}), "set"})},
        set.ttl.cmd(k, v, cond, get, set.tm(tk, tv, "set"), "set"))
    case SetBad{}:
      e_syntax()

# SET key value with options
def parse_set(+k: String, +v: String, +os: List<&2, String>) -> Cmd:
  set.cmd(k, v, set.opts(List.length(&2, String, os), True{}, os, set.init()))

# SETEX and PSETEX: SET with EX or PX
def parse_setex(+k: String, +s: String, +v: String, +secs: Bool, +name: String) -> Cmd:
  set.ttl.cmd(k, v, 0n, False{}, tm.of(s, False{}, secs, True{}, name), name)

def getex.opt(st: SetSt) -> Maybe<&2, ExOpt>:
  match st:
    case SetSt{nx, xx, get, keep, +persist, +tk, tv}:
      Some{Bool.pick(ExOpt, persist, XPersist{}, Bool.pick(ExOpt, Nat.is_eq(tk, 0n), XNone{}, XAt{Nat.is_lt(2n, tk), Bool.or(Nat.is_eq(tk, 2n), Nat.is_eq(tk, 4n)), tv}))}
    case SetBad{}:
      None{}

def getex.cmd(+k: String, m: Maybe<&2, ExOpt>) -> Cmd:
  match m:
    case Some{o}:
      Upd{k, UGetEx{o}}
    case None{}:
      e_syntax()

# GETEX key with options: the time is read once the key is found
def parse_getex(+k: String, +os: List<&2, String>) -> Cmd:
  getex.cmd(k, getex.opt(set.opts(List.length(&2, String, os), False{}, os, set.init())))

# EXPIRE's options, as Redis's parseExtendedExpireArgumentsOrReply reads
# them: NX, XX, GT and LT in any case, any of them again; another word is
# an error; then NX goes with none of the others, nor GT with LT
type ExpSt is Data:
  ExpSt{nx: Bool, xx: Bool, gt: Bool, lt: Bool}
  ExpBad{r: Reply}

def exp.word(+w: String, +nx: Bool, +xx: Bool, +gt: Bool, +lt: Bool) -> ExpSt:
  Bool.pick(ExpSt, is_word(w, "NX"), ExpSt{True{}, xx, gt, lt},
  Bool.pick(ExpSt, is_word(w, "XX"), ExpSt{nx, True{}, gt, lt},
  Bool.pick(ExpSt, is_word(w, "GT"), ExpSt{nx, xx, True{}, lt},
  Bool.pick(ExpSt, is_word(w, "LT"), ExpSt{nx, xx, gt, True{}},
    ExpBad{RError{e_fmt("ERR Unsupported option " ++ cstr(w))}}))))

def exp.opts(xs: List<&2, String>, st: ExpSt) -> ExpSt:
  match xs st:
    case _ ExpBad{r}:
      ExpBad{r}
    case Nil{} st:
      st
    case Con{+w, rest} ExpSt{+nx, +xx, +gt, +lt}:
      exp.opts(rest, exp.word(w, nx, xx, gt, lt))

def exp.ttl.cmd(+k: String, +c: ExpIf, r: TmR, +name: String) -> Cmd:
  match r:
    case TOk{t}:
      Upd{k, UExpire{t, c, name}}
    case TBad{e}:
      Bad{e}

def exp.cmd(+k: String, +s: String, +at: Bool, +secs: Bool, +name: String, st: ExpSt) -> Cmd:
  match st:
    case ExpSt{+nx, +xx, +gt, +lt}:
      Bool.pick(Cmd, Bool.and(nx, Bool.or(xx, Bool.or(gt, lt))), Bad{RError{"ERR NX and XX, GT or LT options at the same time are not compatible"}},
      Bool.pick(Cmd, Bool.and(gt, lt), Bad{RError{"ERR GT and LT options at the same time are not compatible"}},
        exp.ttl.cmd(k, ExpIf{nx, xx, gt, lt}, tm.of(s, at, secs, False{}, name), name)))
    case ExpBad{r}:
      Bad{r}

# EXPIRE, PEXPIRE, EXPIREAT and PEXPIREAT key time [options]: the options
# are read first, then the time
def parse_expire(+k: String, +s: String, +os: List<&2, String>, +at: Bool, +secs: Bool, +name: String) -> Cmd:
  exp.cmd(k, s, at, secs, name, exp.opts(os, ExpSt{False{}, False{}, False{}, False{}}))

# A command's name, in upper case, picks how its arguments parse. The
# name's length narrows it down to a few names, which cmd_id compares with
# it whole: String.eq with a literal is one memcmp, cheap enough that
# Bool.pick computes all of them. parse_id goes by the name's number, 0
# for a name no command has, and has the name as the client sent it, for
# the error about an unknown one.
def cmd_id(+n: String, len: Nat) -> Nat:
  match len:
    case 3n:
      Bool.pick(Nat, String.eq(n, "GET"), 3n,
      Bool.pick(Nat, String.eq(n, "SET"), 4n,
      Bool.pick(Nat, String.eq(n, "DEL"), 7n,
      Bool.pick(Nat, String.eq(n, "TTL"), 32n, 0n))))
    case 4n:
      Bool.pick(Nat, String.eq(n, "PING"), 1n,
      Bool.pick(Nat, String.eq(n, "ECHO"), 2n,
      Bool.pick(Nat, String.eq(n, "INCR"), 10n,
      Bool.pick(Nat, String.eq(n, "DECR"), 11n,
      Bool.pick(Nat, String.eq(n, "MGET"), 16n,
      Bool.pick(Nat, String.eq(n, "MSET"), 17n,
      Bool.pick(Nat, String.eq(n, "KEYS"), 21n,
      Bool.pick(Nat, String.eq(n, "SCAN"), 22n,
      Bool.pick(Nat, String.eq(n, "TYPE"), 25n,
      Bool.pick(Nat, String.eq(n, "AUTH"), 42n,
      Bool.pick(Nat, String.eq(n, "QUIT"), 43n,
      Bool.pick(Nat, String.eq(n, "INFO"), 48n,
      Bool.pick(Nat, String.eq(n, "PTTL"), 33n, 0n)))))))))))))
    case 5n:
      Bool.pick(Nat, String.eq(n, "SETNX"), 5n,
      Bool.pick(Nat, String.eq(n, "HELLO"), 41n,
      Bool.pick(Nat, String.eq(n, "RESET"), 44n,
      Bool.pick(Nat, String.eq(n, "SETEX"), 23n,
      Bool.pick(Nat, String.eq(n, "GETEX"), 26n, 0n)))))
    case 6n:
      Bool.pick(Nat, String.eq(n, "GETSET"), 6n,
      Bool.pick(Nat, String.eq(n, "UNLINK"), 8n,
      Bool.pick(Nat, String.eq(n, "EXISTS"), 9n,
      Bool.pick(Nat, String.eq(n, "INCRBY"), 12n,
      Bool.pick(Nat, String.eq(n, "DECRBY"), 13n,
      Bool.pick(Nat, String.eq(n, "APPEND"), 14n,
      Bool.pick(Nat, String.eq(n, "STRLEN"), 15n,
      Bool.pick(Nat, String.eq(n, "DBSIZE"), 18n,
      Bool.pick(Nat, String.eq(n, "CONFIG"), 47n,
      Bool.pick(Nat, String.eq(n, "SELECT"), 40n,
      Bool.pick(Nat, String.eq(n, "CLIENT"), 45n,
      Bool.pick(Nat, String.eq(n, "PSETEX"), 24n,
      Bool.pick(Nat, String.eq(n, "GETDEL"), 27n,
      Bool.pick(Nat, String.eq(n, "EXPIRE"), 28n, 0n))))))))))))))
    case 7n:
      Bool.pick(Nat, String.eq(n, "FLUSHDB"), 20n,
      Bool.pick(Nat, String.eq(n, "COMMAND"), 49n,
      Bool.pick(Nat, String.eq(n, "PEXPIRE"), 29n,
      Bool.pick(Nat, String.eq(n, "PERSIST"), 36n, 0n))))
    case 8n:
      Bool.pick(Nat, String.eq(n, "FLUSHALL"), 19n,
      Bool.pick(Nat, String.eq(n, "FUNCTION"), 46n,
      Bool.pick(Nat, String.eq(n, "EXPIREAT"), 30n, 0n)))
    case 9n:
      Bool.pick(Nat, String.eq(n, "RANDOMKEY"), 50n,
      Bool.pick(Nat, String.eq(n, "PEXPIREAT"), 31n, 0n))
    case 10n:
      Bool.pick(Nat, String.eq(n, "EXPIRETIME"), 34n, 0n)
    case 11n:
      Bool.pick(Nat, String.eq(n, "PEXPIRETIME"), 35n, 0n)
    case _:
      0n

def parse_id(id: Nat, name: String, args: List<&2, String>) -> Cmd:
  match id:
    case 1n:  # PING
      match args:
        case Nil{}:
          Ping{}
        case Con{m, Nil{}}:
          Echo{m}
        case _:
          e_arity("ping")
    case 2n:  # ECHO
      match args:
        case Con{m, Nil{}}:
          Echo{m}
        case _:
          e_arity("echo")
    case 3n:  # GET
      match args:
        case Con{k, Nil{}}:
          Get{k}
        case _:
          e_arity("get")
    case 4n:  # SET
      match args:
        case Con{k, Con{v, Nil{}}}:
          Set{k, v}
        case Con{k, Con{v, Con{o, os}}}:
          parse_set(k, v, o <> os)
        case _:
          e_arity("set")
    case 5n:  # SETNX
      match args:
        case Con{k, Con{v, Nil{}}}:
          Upd{k, USetNx{v}}
        case _:
          e_arity("setnx")
    case 6n:  # GETSET
      match args:
        case Con{k, Con{v, Nil{}}}:
          Upd{k, UGet{USet{v, 0n, TNone{}, "getset"}}}
        case _:
          e_arity("getset")
    case 7n:  # DEL
      match args:
        case Nil{}:
          e_arity("del")
        case Con{k, ks}:
          Del{k <> ks}
    case 8n:  # UNLINK
      match args:
        case Nil{}:
          e_arity("unlink")
        case Con{k, ks}:
          Del{k <> ks}
    case 9n:  # EXISTS
      match args:
        case Nil{}:
          e_arity("exists")
        case Con{k, ks}:
          Exists{k <> ks}
    case 10n:  # INCR
      match args:
        case Con{k, Nil{}}:
          IncrBy{k, IPos{1n}}
        case _:
          e_arity("incr")
    case 11n:  # DECR
      match args:
        case Con{k, Nil{}}:
          IncrBy{k, INeg{0n}}
        case _:
          e_arity("decr")
    case 12n:  # INCRBY
      match args:
        case Con{k, Con{n, Nil{}}}:
          parse_incrby(k, int_read(n))
        case _:
          e_arity("incrby")
    case 13n:  # DECRBY
      match args:
        case Con{k, Con{n, Nil{}}}:
          parse_decrby(k, int_read(n))
        case _:
          e_arity("decrby")
    case 14n:  # APPEND
      match args:
        case Con{k, Con{v, Nil{}}}:
          Upd{k, UAppend{v}}
        case _:
          e_arity("append")
    case 15n:  # STRLEN
      match args:
        case Con{k, Nil{}}:
          Peek{k, PStrlen{}}
        case _:
          e_arity("strlen")
    case 16n:  # MGET
      match args:
        case Nil{}:
          e_arity("mget")
        case Con{k, ks}:
          MGet{k <> ks}
    case 17n:  # MSET
      parse_mset(pairs(args))
    case 18n:  # DBSIZE
      match args:
        case Nil{}:
          DbSize{}
        case _:
          e_arity("dbsize")
    case 19n:  # FLUSHALL
      parse_flush(args)
    case 20n:  # FLUSHDB
      parse_flush(args)
    case 21n:  # KEYS
      match args:
        case Con{p, Nil{}}:
          Keys{p}
        case _:
          e_arity("keys")
    case 22n:  # SCAN
      match args:
        case Nil{}:
          e_arity("scan")
        case Con{c, rest}:
          scan.parse(Con{c, rest})
    case 23n:  # SETEX
      match args:
        case Con{k, Con{s, Con{v, Nil{}}}}:
          parse_setex(k, s, v, True{}, "setex")
        case _:
          e_arity("setex")
    case 24n:  # PSETEX
      match args:
        case Con{k, Con{s, Con{v, Nil{}}}}:
          parse_setex(k, s, v, False{}, "psetex")
        case _:
          e_arity("psetex")
    case 25n:  # TYPE
      match args:
        case Con{k, Nil{}}:
          Peek{k, PType{}}
        case _:
          e_arity("type")
    case 26n:  # GETEX
      match args:
        case Con{k, os}:
          parse_getex(k, os)
        case _:
          e_arity("getex")
    case 27n:  # GETDEL
      match args:
        case Con{k, Nil{}}:
          Upd{k, UGetDel{}}
        case _:
          e_arity("getdel")
    case 28n:  # EXPIRE
      match args:
        case Con{k, Con{s, os}}:
          parse_expire(k, s, os, False{}, True{}, "expire")
        case _:
          e_arity("expire")
    case 29n:  # PEXPIRE
      match args:
        case Con{k, Con{s, os}}:
          parse_expire(k, s, os, False{}, False{}, "pexpire")
        case _:
          e_arity("pexpire")
    case 30n:  # EXPIREAT
      match args:
        case Con{k, Con{s, os}}:
          parse_expire(k, s, os, True{}, True{}, "expireat")
        case _:
          e_arity("expireat")
    case 31n:  # PEXPIREAT
      match args:
        case Con{k, Con{s, os}}:
          parse_expire(k, s, os, True{}, False{}, "pexpireat")
        case _:
          e_arity("pexpireat")
    case 32n:  # TTL
      match args:
        case Con{k, Nil{}}:
          Peek{k, PTtl{}}
        case _:
          e_arity("ttl")
    case 33n:  # PTTL
      match args:
        case Con{k, Nil{}}:
          Peek{k, PPttl{}}
        case _:
          e_arity("pttl")
    case 34n:  # EXPIRETIME
      match args:
        case Con{k, Nil{}}:
          Peek{k, PExpTime{}}
        case _:
          e_arity("expiretime")
    case 35n:  # PEXPIRETIME
      match args:
        case Con{k, Nil{}}:
          Peek{k, PPExpTime{}}
        case _:
          e_arity("pexpiretime")
    case 36n:  # PERSIST
      match args:
        case Con{k, Nil{}}:
          Upd{k, UPersist{}}
        case _:
          e_arity("persist")
    case _:
      e_unknown(name, args)

# the session commands (ids from 40), parsed into their ops
def parse_sess(id: Nat, name: String, args: List<&2, String>) -> SessOp:
  match id:
    case 40n:  # SELECT
      match args:
        case Con{d, Nil{}}:
          SSelect{d}
        case _:
          s_arity("select")
    case 41n:  # HELLO
      SHello{args}
    case 42n:  # AUTH
      match args:
        case Nil{}:
          s_arity("auth")
        case Con{a, rest}:
          SAuth{a <> rest}
    case 43n:  # QUIT
      SQuit{}
    case 44n:  # RESET
      match args:
        case Nil{}:
          SReset{}
        case _:
          s_arity("reset")
    case 45n:  # CLIENT
      match args:
        case Nil{}:
          s_arity("client")
        case Con{+sub, rest}:
          +up = String.to_upper(sub)
          parse_client(client_id(up, String.length(up)), sub, rest)
    case 46n:  # FUNCTION
      match args:
        case Nil{}:
          s_arity("function")
        case Con{+sub, rest}:
          +up = String.to_upper(sub)
          parse_function(function_id(up, String.length(up)), sub, rest)
    case 47n:  # CONFIG
      match args:
        case Nil{}:
          s_arity("config")
        case Con{+sub, rest}:
          +up = String.to_upper(sub)
          parse_config(config_id(up, String.length(up)), sub, rest)
    case 48n:  # INFO
      SInfo{args}
    case 49n:  # COMMAND
      match args:
        case Nil{}:
          SCommand{Nil{}}
        case Con{+sub, rest}:
          +up = String.to_upper(sub)
          parse_command(command_id(up, String.length(up)), sub, rest)
    case 50n:  # RANDOMKEY
      match args:
        case Nil{}:
          SRandomKey{}
        case _:
          s_arity("randomkey")
    case _:
      SBad{RError{no_newlines("ERR unknown command '" ++ String.take(name, 128n) ++ "', with args beginning with: " ++ unknown.args(args, ""))}}

def parse_named(+name: String, args: List<&2, String>) -> Cmd:
  +up = String.to_upper(name)
  parse_id(cmd_id(up, String.length(up)), name, args)

def parse(args: List<&2, String>) -> Cmd:
  match args:
    case Nil{}:
      Bad{RError{"ERR empty command"}}
    case Con{name, rest}:
      parse_named(name, rest)

# Statistics
# ----------
# INFO commandstats counts each command and subcommand by its name, as the
# client called it (INCR and INCRBY apart, though both parse to IncrBy).
# Its key here is a number (tools/gen_commands.py writes the keys, below):
# the commands in the order of their numbers (cmd_id), then the
# subcommands of CLIENT, FUNCTION, CONFIG and COMMAND; 0 is an unknown
# command or subcommand, which Redis counts nowhere but in errorstats.
# With the key comes what a call counts as (stat.code: 4 times the key
# plus that): 0 when it runs; 1 when it is refused before it runs, as
# Redis refuses an unknown command or subcommand and a number of
# arguments its arity does not allow; 2 when it fails on an error that
# BendKV's parser finds and Redis's command finds as it runs (a syntax
# error, a value that is not an integer), which is a call that failed
# (stat.class). The code rides in the high twelve bits of the request's
# hash as its word (stat.cw: twelve bits, six of them set), and the hints
# of batch.bend read only the low twenty.

# BEGIN gen_commands: stats
# a command's key, by its number in the parser (cmd_id); 0 for none
def stat.top(+id: Nat) -> Nat:
  match id:
    case 1n:
      1n
    case 2n:
      2n
    case 3n:
      3n
    case 4n:
      4n
    case 5n:
      5n
    case 6n:
      6n
    case 7n:
      7n
    case 8n:
      8n
    case 9n:
      9n
    case 10n:
      10n
    case 11n:
      11n
    case 12n:
      12n
    case 13n:
      13n
    case 14n:
      14n
    case 15n:
      15n
    case 16n:
      16n
    case 17n:
      17n
    case 18n:
      18n
    case 19n:
      19n
    case 20n:
      20n
    case 21n:
      21n
    case 22n:
      22n
    case 23n:
      23n
    case 24n:
      24n
    case 25n:
      25n
    case 26n:
      26n
    case 27n:
      27n
    case 28n:
      28n
    case 29n:
      29n
    case 30n:
      30n
    case 31n:
      31n
    case 32n:
      32n
    case 33n:
      33n
    case 34n:
      34n
    case 35n:
      35n
    case 36n:
      36n
    case 40n:
      37n
    case 41n:
      38n
    case 42n:
      39n
    case 43n:
      40n
    case 44n:
      41n
    case 45n:
      42n
    case 46n:
      43n
    case 47n:
      44n
    case 48n:
      45n
    case 49n:
      46n
    case 50n:
      47n
    case _:
      0n

# a subcommand of CLIENT's key, by its number; 0 for none
def stat.sub.client(+sub: Nat) -> Nat:
  match sub:
    case 1n:
      48n
    case 2n:
      49n
    case 3n:
      50n
    case 4n:
      51n
    case 5n:
      52n
    case 6n:
      53n
    case 7n:
      54n
    case 8n:
      55n
    case 9n:
      56n
    case 10n:
      57n
    case _:
      0n

# a subcommand of FUNCTION's key, by its number; 0 for none
def stat.sub.function(+sub: Nat) -> Nat:
  match sub:
    case 1n:
      58n
    case 2n:
      59n
    case _:
      0n

# a subcommand of CONFIG's key, by its number; 0 for none
def stat.sub.config(+sub: Nat) -> Nat:
  match sub:
    case 1n:
      60n
    case 2n:
      61n
    case 3n:
      62n
    case 4n:
      63n
    case 5n:
      64n
    case _:
      0n

# a subcommand of COMMAND's key, by its number; 0 for none
def stat.sub.command(+sub: Nat) -> Nat:
  match sub:
    case 1n:
      65n
    case 2n:
      66n
    case 3n:
      67n
    case 4n:
      68n
    case 5n:
      69n
    case 6n:
      70n
    case 7n:
      71n
    case _:
      0n

# the name INFO gives a key (as COMMAND names it); "" for none
def stat.name(+key: Nat) -> String:
  match key:
    case 1n:
      "ping"
    case 2n:
      "echo"
    case 3n:
      "get"
    case 4n:
      "set"
    case 5n:
      "setnx"
    case 6n:
      "getset"
    case 7n:
      "del"
    case 8n:
      "unlink"
    case 9n:
      "exists"
    case 10n:
      "incr"
    case 11n:
      "decr"
    case 12n:
      "incrby"
    case 13n:
      "decrby"
    case 14n:
      "append"
    case 15n:
      "strlen"
    case 16n:
      "mget"
    case 17n:
      "mset"
    case 18n:
      "dbsize"
    case 19n:
      "flushall"
    case 20n:
      "flushdb"
    case 21n:
      "keys"
    case 22n:
      "scan"
    case 23n:
      "setex"
    case 24n:
      "psetex"
    case 25n:
      "type"
    case 26n:
      "getex"
    case 27n:
      "getdel"
    case 28n:
      "expire"
    case 29n:
      "pexpire"
    case 30n:
      "expireat"
    case 31n:
      "pexpireat"
    case 32n:
      "ttl"
    case 33n:
      "pttl"
    case 34n:
      "expiretime"
    case 35n:
      "pexpiretime"
    case 36n:
      "persist"
    case 37n:
      "select"
    case 38n:
      "hello"
    case 39n:
      "auth"
    case 40n:
      "quit"
    case 41n:
      "reset"
    case 42n:
      "client"
    case 43n:
      "function"
    case 44n:
      "config"
    case 45n:
      "info"
    case 46n:
      "command"
    case 47n:
      "randomkey"
    case 48n:
      "client|id"
    case 49n:
      "client|help"
    case 50n:
      "client|reply"
    case 51n:
      "client|getname"
    case 52n:
      "client|setname"
    case 53n:
      "client|caching"
    case 54n:
      "client|unblock"
    case 55n:
      "client|getredir"
    case 56n:
      "client|no-evict"
    case 57n:
      "client|trackinginfo"
    case 58n:
      "function|flush"
    case 59n:
      "function|help"
    case 60n:
      "config|get"
    case 61n:
      "config|set"
    case 62n:
      "config|resetstat"
    case 63n:
      "config|rewrite"
    case 64n:
      "config|help"
    case 65n:
      "command|info"
    case 66n:
      "command|docs"
    case 67n:
      "command|list"
    case 68n:
      "command|help"
    case 69n:
      "command|count"
    case 70n:
      "command|getkeys"
    case 71n:
      "command|getkeysandflags"
    case _:
      ""

# Redis's arity of the command or subcommand of a key: 2a when it takes
# exactly a arguments (its name included), 2a + 1 when it takes a or more
def stat.arity(+key: Nat) -> Nat:
  match key:
    case 1n:
      3n
    case 2n:
      4n
    case 3n:
      4n
    case 4n:
      7n
    case 5n:
      6n
    case 6n:
      6n
    case 7n:
      5n
    case 8n:
      5n
    case 9n:
      5n
    case 10n:
      4n
    case 11n:
      4n
    case 12n:
      6n
    case 13n:
      6n
    case 14n:
      6n
    case 15n:
      4n
    case 16n:
      5n
    case 17n:
      7n
    case 18n:
      2n
    case 19n:
      3n
    case 20n:
      3n
    case 21n:
      4n
    case 22n:
      5n
    case 23n:
      8n
    case 24n:
      8n
    case 25n:
      4n
    case 26n:
      5n
    case 27n:
      4n
    case 28n:
      7n
    case 29n:
      7n
    case 30n:
      7n
    case 31n:
      7n
    case 32n:
      4n
    case 33n:
      4n
    case 34n:
      4n
    case 35n:
      4n
    case 36n:
      4n
    case 37n:
      4n
    case 38n:
      3n
    case 39n:
      5n
    case 40n:
      3n
    case 41n:
      2n
    case 42n:
      5n
    case 43n:
      5n
    case 44n:
      5n
    case 45n:
      3n
    case 46n:
      3n
    case 47n:
      2n
    case 48n:
      4n
    case 49n:
      4n
    case 50n:
      6n
    case 51n:
      4n
    case 52n:
      6n
    case 53n:
      6n
    case 54n:
      7n
    case 55n:
      4n
    case 56n:
      6n
    case 57n:
      4n
    case 58n:
      5n
    case 59n:
      4n
    case 60n:
      7n
    case 61n:
      9n
    case 62n:
      4n
    case 63n:
      4n
    case 64n:
      4n
    case 65n:
      5n
    case 66n:
      5n
    case 67n:
      5n
    case 68n:
      4n
    case 69n:
      4n
    case 70n:
      9n
    case 71n:
      9n
    case _:
      1n

# whether a call of the command of a key can fail as it runs
def stat.risky(+key: Nat) -> Bool:
  match key:
    case 10n:
      True{}
    case 11n:
      True{}
    case 12n:
      True{}
    case 13n:
      True{}
    case 23n:
      True{}
    case 24n:
      True{}
    case 26n:
      True{}
    case 28n:
      True{}
    case 29n:
      True{}
    case _:
      False{}

# a code's word
def stat.cw(+code: Nat) -> U32:
  match code:
    case 0n:
      63
    case 1n:
      95
    case 2n:
      111
    case 3n:
      119
    case 4n:
      123
    case 5n:
      125
    case 6n:
      126
    case 7n:
      159
    case 8n:
      175
    case 9n:
      183
    case 10n:
      187
    case 11n:
      189
    case 12n:
      190
    case 13n:
      207
    case 14n:
      215
    case 15n:
      219
    case 16n:
      221
    case 17n:
      222
    case 18n:
      231
    case 19n:
      235
    case 20n:
      237
    case 21n:
      238
    case 22n:
      243
    case 23n:
      245
    case 24n:
      246
    case 25n:
      249
    case 26n:
      250
    case 27n:
      252
    case 28n:
      287
    case 29n:
      303
    case 30n:
      311
    case 31n:
      315
    case 32n:
      317
    case 33n:
      318
    case 34n:
      335
    case 35n:
      343
    case 36n:
      347
    case 37n:
      349
    case 38n:
      350
    case 39n:
      359
    case 40n:
      363
    case 41n:
      365
    case 42n:
      366
    case 43n:
      371
    case 44n:
      373
    case 45n:
      374
    case 46n:
      377
    case 47n:
      378
    case 48n:
      380
    case 49n:
      399
    case 50n:
      407
    case 51n:
      411
    case 52n:
      413
    case 53n:
      414
    case 54n:
      423
    case 55n:
      427
    case 56n:
      429
    case 57n:
      430
    case 58n:
      435
    case 59n:
      437
    case 60n:
      438
    case 61n:
      441
    case 62n:
      442
    case 63n:
      444
    case 64n:
      455
    case 65n:
      459
    case 66n:
      461
    case 67n:
      462
    case 68n:
      467
    case 69n:
      469
    case 70n:
      470
    case 71n:
      473
    case 72n:
      474
    case 73n:
      476
    case 74n:
      483
    case 75n:
      485
    case 76n:
      486
    case 77n:
      489
    case 78n:
      490
    case 79n:
      492
    case 80n:
      497
    case 81n:
      498
    case 82n:
      500
    case 83n:
      504
    case 84n:
      543
    case 85n:
      559
    case 86n:
      567
    case 87n:
      571
    case 88n:
      573
    case 89n:
      574
    case 90n:
      591
    case 91n:
      599
    case 92n:
      603
    case 93n:
      605
    case 94n:
      606
    case 95n:
      615
    case 96n:
      619
    case 97n:
      621
    case 98n:
      622
    case 99n:
      627
    case 100n:
      629
    case 101n:
      630
    case 102n:
      633
    case 103n:
      634
    case 104n:
      636
    case 105n:
      655
    case 106n:
      663
    case 107n:
      667
    case 108n:
      669
    case 109n:
      670
    case 110n:
      679
    case 111n:
      683
    case 112n:
      685
    case 113n:
      686
    case 114n:
      691
    case 115n:
      693
    case 116n:
      694
    case 117n:
      697
    case 118n:
      698
    case 119n:
      700
    case 120n:
      711
    case 121n:
      715
    case 122n:
      717
    case 123n:
      718
    case 124n:
      723
    case 125n:
      725
    case 126n:
      726
    case 127n:
      729
    case 128n:
      730
    case 129n:
      732
    case 130n:
      739
    case 131n:
      741
    case 132n:
      742
    case 133n:
      745
    case 134n:
      746
    case 135n:
      748
    case 136n:
      753
    case 137n:
      754
    case 138n:
      756
    case 139n:
      760
    case 140n:
      783
    case 141n:
      791
    case 142n:
      795
    case 143n:
      797
    case 144n:
      798
    case 145n:
      807
    case 146n:
      811
    case 147n:
      813
    case 148n:
      814
    case 149n:
      819
    case 150n:
      821
    case 151n:
      822
    case 152n:
      825
    case 153n:
      826
    case 154n:
      828
    case 155n:
      839
    case 156n:
      843
    case 157n:
      845
    case 158n:
      846
    case 159n:
      851
    case 160n:
      853
    case 161n:
      854
    case 162n:
      857
    case 163n:
      858
    case 164n:
      860
    case 165n:
      867
    case 166n:
      869
    case 167n:
      870
    case 168n:
      873
    case 169n:
      874
    case 170n:
      876
    case 171n:
      881
    case 172n:
      882
    case 173n:
      884
    case 174n:
      888
    case 175n:
      903
    case 176n:
      907
    case 177n:
      909
    case 178n:
      910
    case 179n:
      915
    case 180n:
      917
    case 181n:
      918
    case 182n:
      921
    case 183n:
      922
    case 184n:
      924
    case 185n:
      931
    case 186n:
      933
    case 187n:
      934
    case 188n:
      937
    case 189n:
      938
    case 190n:
      940
    case 191n:
      945
    case 192n:
      946
    case 193n:
      948
    case 194n:
      952
    case 195n:
      963
    case 196n:
      965
    case 197n:
      966
    case 198n:
      969
    case 199n:
      970
    case 200n:
      972
    case 201n:
      977
    case 202n:
      978
    case 203n:
      980
    case 204n:
      984
    case 205n:
      993
    case 206n:
      994
    case 207n:
      996
    case 208n:
      1000
    case 209n:
      1008
    case 210n:
      1055
    case 211n:
      1071
    case 212n:
      1079
    case 213n:
      1083
    case 214n:
      1085
    case 215n:
      1086
    case 216n:
      1103
    case 217n:
      1111
    case 218n:
      1115
    case 219n:
      1117
    case 220n:
      1118
    case 221n:
      1127
    case 222n:
      1131
    case 223n:
      1133
    case 224n:
      1134
    case 225n:
      1139
    case 226n:
      1141
    case 227n:
      1142
    case 228n:
      1145
    case 229n:
      1146
    case 230n:
      1148
    case 231n:
      1167
    case 232n:
      1175
    case 233n:
      1179
    case 234n:
      1181
    case 235n:
      1182
    case 236n:
      1191
    case 237n:
      1195
    case 238n:
      1197
    case 239n:
      1198
    case 240n:
      1203
    case 241n:
      1205
    case 242n:
      1206
    case 243n:
      1209
    case 244n:
      1210
    case 245n:
      1212
    case 246n:
      1223
    case 247n:
      1227
    case 248n:
      1229
    case 249n:
      1230
    case 250n:
      1235
    case 251n:
      1237
    case 252n:
      1238
    case 253n:
      1241
    case 254n:
      1242
    case 255n:
      1244
    case 256n:
      1251
    case 257n:
      1253
    case 258n:
      1254
    case 259n:
      1257
    case 260n:
      1258
    case 261n:
      1260
    case 262n:
      1265
    case 263n:
      1266
    case 264n:
      1268
    case 265n:
      1272
    case 266n:
      1295
    case 267n:
      1303
    case 268n:
      1307
    case 269n:
      1309
    case 270n:
      1310
    case 271n:
      1319
    case 272n:
      1323
    case 273n:
      1325
    case 274n:
      1326
    case 275n:
      1331
    case 276n:
      1333
    case 277n:
      1334
    case 278n:
      1337
    case 279n:
      1338
    case 280n:
      1340
    case 281n:
      1351
    case 282n:
      1355
    case 283n:
      1357
    case 284n:
      1358
    case 285n:
      1363
    case 286n:
      1365
    case 287n:
      1366
    case _:
      63

# a word's code (0 for one no code has)
def stat.code.cw(+w: Nat) -> Nat:
  match w:
    case 63n:
      0n
    case 95n:
      1n
    case 111n:
      2n
    case 119n:
      3n
    case 123n:
      4n
    case 125n:
      5n
    case 126n:
      6n
    case 159n:
      7n
    case 175n:
      8n
    case 183n:
      9n
    case 187n:
      10n
    case 189n:
      11n
    case 190n:
      12n
    case 207n:
      13n
    case 215n:
      14n
    case 219n:
      15n
    case 221n:
      16n
    case 222n:
      17n
    case 231n:
      18n
    case 235n:
      19n
    case 237n:
      20n
    case 238n:
      21n
    case 243n:
      22n
    case 245n:
      23n
    case 246n:
      24n
    case 249n:
      25n
    case 250n:
      26n
    case 252n:
      27n
    case 287n:
      28n
    case 303n:
      29n
    case 311n:
      30n
    case 315n:
      31n
    case 317n:
      32n
    case 318n:
      33n
    case 335n:
      34n
    case 343n:
      35n
    case 347n:
      36n
    case 349n:
      37n
    case 350n:
      38n
    case 359n:
      39n
    case 363n:
      40n
    case 365n:
      41n
    case 366n:
      42n
    case 371n:
      43n
    case 373n:
      44n
    case 374n:
      45n
    case 377n:
      46n
    case 378n:
      47n
    case 380n:
      48n
    case 399n:
      49n
    case 407n:
      50n
    case 411n:
      51n
    case 413n:
      52n
    case 414n:
      53n
    case 423n:
      54n
    case 427n:
      55n
    case 429n:
      56n
    case 430n:
      57n
    case 435n:
      58n
    case 437n:
      59n
    case 438n:
      60n
    case 441n:
      61n
    case 442n:
      62n
    case 444n:
      63n
    case 455n:
      64n
    case 459n:
      65n
    case 461n:
      66n
    case 462n:
      67n
    case 467n:
      68n
    case 469n:
      69n
    case 470n:
      70n
    case 473n:
      71n
    case 474n:
      72n
    case 476n:
      73n
    case 483n:
      74n
    case 485n:
      75n
    case 486n:
      76n
    case 489n:
      77n
    case 490n:
      78n
    case 492n:
      79n
    case 497n:
      80n
    case 498n:
      81n
    case 500n:
      82n
    case 504n:
      83n
    case 543n:
      84n
    case 559n:
      85n
    case 567n:
      86n
    case 571n:
      87n
    case 573n:
      88n
    case 574n:
      89n
    case 591n:
      90n
    case 599n:
      91n
    case 603n:
      92n
    case 605n:
      93n
    case 606n:
      94n
    case 615n:
      95n
    case 619n:
      96n
    case 621n:
      97n
    case 622n:
      98n
    case 627n:
      99n
    case 629n:
      100n
    case 630n:
      101n
    case 633n:
      102n
    case 634n:
      103n
    case 636n:
      104n
    case 655n:
      105n
    case 663n:
      106n
    case 667n:
      107n
    case 669n:
      108n
    case 670n:
      109n
    case 679n:
      110n
    case 683n:
      111n
    case 685n:
      112n
    case 686n:
      113n
    case 691n:
      114n
    case 693n:
      115n
    case 694n:
      116n
    case 697n:
      117n
    case 698n:
      118n
    case 700n:
      119n
    case 711n:
      120n
    case 715n:
      121n
    case 717n:
      122n
    case 718n:
      123n
    case 723n:
      124n
    case 725n:
      125n
    case 726n:
      126n
    case 729n:
      127n
    case 730n:
      128n
    case 732n:
      129n
    case 739n:
      130n
    case 741n:
      131n
    case 742n:
      132n
    case 745n:
      133n
    case 746n:
      134n
    case 748n:
      135n
    case 753n:
      136n
    case 754n:
      137n
    case 756n:
      138n
    case 760n:
      139n
    case 783n:
      140n
    case 791n:
      141n
    case 795n:
      142n
    case 797n:
      143n
    case 798n:
      144n
    case 807n:
      145n
    case 811n:
      146n
    case 813n:
      147n
    case 814n:
      148n
    case 819n:
      149n
    case 821n:
      150n
    case 822n:
      151n
    case 825n:
      152n
    case 826n:
      153n
    case 828n:
      154n
    case 839n:
      155n
    case 843n:
      156n
    case 845n:
      157n
    case 846n:
      158n
    case 851n:
      159n
    case 853n:
      160n
    case 854n:
      161n
    case 857n:
      162n
    case 858n:
      163n
    case 860n:
      164n
    case 867n:
      165n
    case 869n:
      166n
    case 870n:
      167n
    case 873n:
      168n
    case 874n:
      169n
    case 876n:
      170n
    case 881n:
      171n
    case 882n:
      172n
    case 884n:
      173n
    case 888n:
      174n
    case 903n:
      175n
    case 907n:
      176n
    case 909n:
      177n
    case 910n:
      178n
    case 915n:
      179n
    case 917n:
      180n
    case 918n:
      181n
    case 921n:
      182n
    case 922n:
      183n
    case 924n:
      184n
    case 931n:
      185n
    case 933n:
      186n
    case 934n:
      187n
    case 937n:
      188n
    case 938n:
      189n
    case 940n:
      190n
    case 945n:
      191n
    case 946n:
      192n
    case 948n:
      193n
    case 952n:
      194n
    case 963n:
      195n
    case 965n:
      196n
    case 966n:
      197n
    case 969n:
      198n
    case 970n:
      199n
    case 972n:
      200n
    case 977n:
      201n
    case 978n:
      202n
    case 980n:
      203n
    case 984n:
      204n
    case 993n:
      205n
    case 994n:
      206n
    case 996n:
      207n
    case 1000n:
      208n
    case 1008n:
      209n
    case 1055n:
      210n
    case 1071n:
      211n
    case 1079n:
      212n
    case 1083n:
      213n
    case 1085n:
      214n
    case 1086n:
      215n
    case 1103n:
      216n
    case 1111n:
      217n
    case 1115n:
      218n
    case 1117n:
      219n
    case 1118n:
      220n
    case 1127n:
      221n
    case 1131n:
      222n
    case 1133n:
      223n
    case 1134n:
      224n
    case 1139n:
      225n
    case 1141n:
      226n
    case 1142n:
      227n
    case 1145n:
      228n
    case 1146n:
      229n
    case 1148n:
      230n
    case 1167n:
      231n
    case 1175n:
      232n
    case 1179n:
      233n
    case 1181n:
      234n
    case 1182n:
      235n
    case 1191n:
      236n
    case 1195n:
      237n
    case 1197n:
      238n
    case 1198n:
      239n
    case 1203n:
      240n
    case 1205n:
      241n
    case 1206n:
      242n
    case 1209n:
      243n
    case 1210n:
      244n
    case 1212n:
      245n
    case 1223n:
      246n
    case 1227n:
      247n
    case 1229n:
      248n
    case 1230n:
      249n
    case 1235n:
      250n
    case 1237n:
      251n
    case 1238n:
      252n
    case 1241n:
      253n
    case 1242n:
      254n
    case 1244n:
      255n
    case 1251n:
      256n
    case 1253n:
      257n
    case 1254n:
      258n
    case 1257n:
      259n
    case 1258n:
      260n
    case 1260n:
      261n
    case 1265n:
      262n
    case 1266n:
      263n
    case 1268n:
      264n
    case 1272n:
      265n
    case 1295n:
      266n
    case 1303n:
      267n
    case 1307n:
      268n
    case 1309n:
      269n
    case 1310n:
      270n
    case 1319n:
      271n
    case 1323n:
      272n
    case 1325n:
      273n
    case 1326n:
      274n
    case 1331n:
      275n
    case 1333n:
      276n
    case 1334n:
      277n
    case 1337n:
      278n
    case 1338n:
      279n
    case 1340n:
      280n
    case 1351n:
      281n
    case 1355n:
      282n
    case 1357n:
      283n
    case 1358n:
      284n
    case 1363n:
      285n
    case 1365n:
      286n
    case 1366n:
      287n
    case _:
      0n

# the high twelve bits of the hash of a call of GET, SET and INCR that
# runs, as the parser writes them
def stat.mark.get() -> U32:
  199229440

def stat.mark.set() -> U32:
  231735296

def stat.mark.incr() -> U32:
  380633088
# END gen_commands: stats

# a container (CLIENT, FUNCTION, CONFIG, COMMAND) by its first argument;
# alone, the container itself (top)
def stat.sub.of(id: Nat, +up: String) -> Nat:
  match id:
    case 45n:
      stat.sub.client(client_id(up, String.length(up)))
    case 46n:
      stat.sub.function(function_id(up, String.length(up)))
    case 47n:
      stat.sub.config(config_id(up, String.length(up)))
    case _:
      stat.sub.command(command_id(up, String.length(up)))

def stat.key.args(top: Nat, id: Nat, +args: List<&2, String>) -> Nat:
  match args:
    case Nil{}:
      top
    case Con{+a, rest}:
      stat.sub.of(id, String.to_upper(a))

# the key of a command of number id with these arguments
def stat.key(+id: Nat, +args: List<&2, String>) -> Nat:
  match id:
    case 45n:
      stat.key.args(stat.top(45n), 45n, args)
    case 46n:
      stat.key.args(stat.top(46n), 46n, args)
    case 47n:
      stat.key.args(stat.top(47n), 47n, args)
    case 49n:
      stat.key.args(stat.top(49n), 49n, args)
    case _:
      stat.top(id)

# whether argc arguments (the name included) pass Redis's check of the
# arity of the command or subcommand of key
def stat.arity.ok(+key: Nat, +argc: Nat) -> Bool:
  +a = stat.arity(key)
  +n = Nat.div(a, 2n)
  Bool.pick(Bool, Nat.is_eq(Nat.mod(a, 2n), 0n), Nat.is_eq(argc, n), Nat.is_le(n, argc))

def stat.refused(+m: String) -> Bool:
  Bool.or(String.starts_with(m, "ERR unknown command '"), String.starts_with(m, "ERR unknown subcommand '"))

# what an error the parser found counts as: a wrong number of arguments
# is refused when Redis's check of the arity refuses it, and fails as the
# command runs otherwise (PING with two arguments, MSET with a key and no
# value: the command checks them itself); an unknown command or
# subcommand is refused; any other error fails
def stat.class.args(arity: Bool, refused: Bool, +key: Nat, +args: List<&2, String>) -> Nat:
  match arity refused:
    case True{} _:
      Bool.pick(Nat, stat.arity.ok(key, Nat.add(List.length(&2, String, args), 1n)), 2n, 1n)
    case False{} True{}:
      1n
    case False{} False{}:
      2n

def stat.class.err(+r: Reply, +key: Nat, +args: List<&2, String>) -> Nat:
  match r:
    case RError{+m}:
      stat.class.args(String.starts_with(m, "ERR wrong number of arguments for "), stat.refused(m), key, args)
    case _:
      2n

# what a parsed command of key with arguments args counts as: an error
# the parser found (Bad, and a session command's SBad) is refused or
# failed; anything else runs
def stat.class(+c: Cmd, +key: Nat, +args: List<&2, String>) -> Nat:
  match c:
    case Bad{+r}:
      stat.class.err(r, key, args)
    case Own{SBad{+r}}:
      stat.class.err(r, key, args)
    case _:
      0n

def stat.code(+key: Nat, +class: Nat) -> Nat:
  Nat.add(Nat.mul(key, 4n), class)

# a hint's hash with code's word in its high twelve bits
def stat.hash(+h: U32, +code: Nat) -> U32:
  U32.or(U32.and(h, 1048575), U32.shln(stat.cw(code), 20n))

# the code of the word in a hash's high twelve bits
def code.of(+h: U32) -> Nat:
  stat.code.cw(U32.to_nat(U32.shrn(h, 20n)))

# A batch's calls are counted as runs of one code each: a run is
# code * 2^32 + how many calls in a row have it.
def run.top() -> Nat:
  Nat.mul(65536n, 65536n)

def run.code(+r: Nat) -> Nat:
  Nat.div(r, run.top())

def run.n(+r: Nat) -> Nat:
  Nat.mod(r, run.top())

def run.of(+code: Nat, +n: Nat) -> Nat:
  Nat.add(Nat.mul(code, run.top()), n)

# the calls of n of code k that ran (0 and 2; key 0 is never one)
def code.calls(+k: Nat, +n: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_eq(Nat.mod(k, 4n), 1n), 0n, n)

# whether replies of calls of code k need a look for errors: calls
# refused or failed by the parser, or calls that can fail as they run
# (stat.risky: INCR, DECR, INCRBY and DECRBY meet values that are not
# integers, and overflows)
def code.risky(+k: Nat) -> Bool:
  Bool.or(Nat.is_lt(0n, Nat.mod(k, 4n)), stat.risky(Nat.div(k, 4n)))

# The words of a batch's requests or-ed together have six bits set
# exactly when all of them are one word: two words of six bits each that
# differ have seven or more between them. So a batch of one command, most
# of them, is counted without a look at its requests. The parser keeps a
# batch's count and words in one word (tl): the count in its high twenty
# bits, the words in its low twelve.
def tl.add(tl: U32, +h: U32) -> U32:
  U32.or(U32.add(tl, 4096), U32.shrn(h, 20n))

# the bits set in a word of twelve bits
def bits12(+w: U32) -> U32:
  +a = U32.sub(w, U32.and(U32.shrn(w, 1n), 1365))
  +b = U32.add(U32.and(a, 819), U32.and(U32.shrn(a, 2n), 819))
  +c = U32.and(U32.add(b, U32.shrn(b, 4n)), 3855)
  U32.and(U32.add(c, U32.shrn(c, 8n)), 31)

# What a batch that runs the fast way counts: the calls that ran, whether
# its replies need a look for errors, and its runs: the one run of a
# batch of one code (run; 0 for none), or the runs of any other, newest
# first (runs), which is taken a hash at a time.
type Tally is Data:
  Tally{calls: Nat, risky: Bool, run: Nat, runs: List<&2, Nat>}

# a call of code k after the runs rs: one more in the first run when it
# has k, else a run of its own
def runs.add.if(same: Bool, rs: List<&2, Nat>, +k: Nat) -> List<&2, Nat>:
  match same rs:
    case True{} Con{r, rest}:
      Nat.add(r, 1n) <> rest
    case _ _:
      run.of(k, 1n) <> rs

def runs.add(+rs: List<&2, Nat>, +k: Nat) -> List<&2, Nat>:
  match rs:
    case Con{+r, rest}:
      runs.add.if(Nat.is_eq(run.code(r), k), rs, k)
    case Nil{}:
      [run.of(k, 1n)]

def tally.step(t: Tally, +k: Nat) -> Tally:
  match t:
    case Tally{calls, risky, r, rs}:
      Tally{Nat.add(calls, code.calls(k, 1n)), Bool.or(risky, code.risky(k)), r, runs.add(rs, k)}

def tally.each(+hs: List<&2, U32>, t: Tally) -> Tally:
  match hs:
    case Nil{}:
      t
    case Con{+h, +rest}:
      tally.each(rest, tally.step(t, code.of(h)))

# A batch of one code k (the code of tl's low twelve bits), n calls (its
# high twenty bits), is counted as code.calls and code.risky count: with
# c its class, n calls ran unless c is 1 (((c xor 1) + 3) / 4 is 1, 0 and
# 1 for c of 0, 1 and 2). It is one only when tl counts all its requests:
# when it came in fewer than 2^20 bytes, it has 2^19 + 1 at most (the
# tail of a request before them, then two bytes or more each).
def tally.one(+k: Nat, +n: U32) -> Tally:
  +c = U32.and(U32.from_nat(k), 3)
  Tally{U32.to_nat(U32.mul(n, U32.shrn(U32.add(U32.xor(c, 1), 3), 2n))), code.risky(k), run.of(k, U32.to_nat(n)), Nil{}}

def tally.if(one: Bool, small: Bool, +tl: U32, +hs: List<&2, U32>) -> Tally:
  match one small:
    case True{} True{}:
      tally.one(stat.code.cw(U32.to_nat(U32.and(tl, 4095))), U32.shrn(tl, 12n))
    case _ _:
      tally.each(hs, Tally{0n, False{}, 0n, Nil{}})

# what a batch counts, from its count and words (tl), the bytes it came in
# and its hashes
def tally(+tl: U32, +inb: Nat, +hs: List<&2, U32>) -> Tally:
  tally.if(U32.is_eq(bits12(U32.and(tl, 4095)), 6), Nat.is_lt(inb, 1048576n), tl, hs)

# the codes of a batch's calls, from its hashes, in order
def codes.of(+hs: List<&2, U32>) -> List<&2, Nat>:
  match hs:
    case Nil{}:
      Nil{}
    case Con{+h, +rest}:
      code.of(h) <> codes.of(rest)

# the codes of the calls of runs (newest first), one each, in order,
# before acc
def codes.rep(n: Nat, +k: Nat, acc: List<&2, Nat>) -> List<&2, Nat>:
  match n:
    case 0n:
      acc
    case 1n+m:
      codes.rep(m, k, k <> acc)

def codes.runs(+rs: List<&2, Nat>, acc: List<&2, Nat>) -> List<&2, Nat>:
  match rs:
    case Nil{}:
      acc
    case Con{+r, +rest}:
      codes.runs(rest, codes.rep(run.n(r), run.code(r), acc))

# an error reply, and the code of the call that gave it
type Erred is Data:
  Erred{code: Nat, msg: String}

def err.put(+r: Reply, +k: Nat, acc: List<&2, Erred>) -> List<&2, Erred>:
  match r:
    case RError{+m}:
      Erred{k, m} <> acc
    case _:
      acc

# the error replies among replies, each with the code of its call (ks, in
# the same order)
def errs.zip(+rs: List<&2, Reply>, ks: List<&2, Nat>, acc: List<&2, Erred>) -> List<&2, Erred>:
  match rs ks:
    case Con{+r, +rest} Con{+k, more}:
      errs.zip(rest, more, err.put(r, k, acc))
    case _ _:
      acc

# ASCII lower case, as C's tolower
def byte.lower(+x: U32) -> U32:
  U32.add(x, U32.mul(Bool.to_u32(Bool.and(U32.is_ge(x, 65), U32.is_le(x, 90))), 32))

# Patterns
# --------
# KEYS, CONFIG GET and COMMAND LIST match as Redis's stringmatchlen does
# (the last two with case aside): '*' any run of bytes, '?' any byte,
# '[...]' a class (with '^', ranges and '\'), '\' the byte after it. A '*'
# whose rest matches nowhere in the rest of the string ends the search
# (Redis's skipLongerMatches): a longer run for an earlier '*' could only
# start the rest later, so a pattern costs polynomial time, not
# exponential. A '*' does not match an empty string, as in Redis, where
# the empty string never enters the loop.

type Sm is Data:
  SmYes{}
  SmNo{}
  SmStop{}

def sm.eq(nc: Bool, +a: U32, +c: U32) -> Bool:
  match nc:
    case True{}:
      U32.is_eq(byte.lower(a), byte.lower(c))
    case False{}:
      U32.is_eq(a, c)

# bytes compare in a range as C's signed chars do: flipping the top bit
# puts -128..127 in the order of 0..255
def sm.sgn(x: U32) -> U32:
  U32.xor(x, 128)

def sm.in(+lo: U32, +hi: U32, +c: U32) -> Bool:
  Bool.and(U32.is_le(sm.sgn(lo), sm.sgn(c)), U32.is_le(sm.sgn(c), sm.sgn(hi)))

def sm.cased(+nc: Bool, +lo: U32, +hi: U32, +c: U32) -> Bool:
  match nc:
    case True{}:
      sm.in(byte.lower(lo), byte.lower(hi), byte.lower(c))
    case False{}:
      sm.in(lo, hi, c)

# a-b: the ends swapped when a > b, then lowered when case is aside
def sm.range(+nc: Bool, +a: U32, +z: U32, +c: U32) -> Bool:
  Bool.pick(Bool, U32.is_gt(sm.sgn(a), sm.sgn(z)), sm.cased(nc, z, a, c), sm.cased(nc, a, z, c))

# The elements of a class after its '[' and '^': its end, a byte after a
# '\', its ']', a range a-z, or one byte; each with the class after it.
# They are told apart by comparing bytes, not by patterns of literal
# bytes nested in a String: those make the kernel's decision trees
# explode (a Char is a 32-bit word there).
type ClsTok is Data:
  TEnd{}
  TEsc{x: U32, rest: String}
  TClose{rest: String}
  TRange{a: U32, z: U32, rest: String}
  TOne{a: U32, rest: String}

# an element that is not an escape or the end: a range when a '-' and
# another byte follow
def cls.three(+a: U32, +t: String) -> ClsTok:
  match t:
    case SCon{Chr{+d}, SCon{Chr{+z}, +r}}:
      Bool.pick(ClsTok, U32.is_eq(d, 45), TRange{a, z, r}, TOne{a, SCon{Chr{d}, SCon{Chr{z}, r}}})
    case _:
      TOne{a, t}

# after a '\': the byte it escapes, or itself when it ends the pattern
def cls.esc(t: String) -> ClsTok:
  match t:
    case SCon{Chr{+x}, r}:
      TEsc{x, r}
    case SNil{}:
      TOne{92, SNil{}}

def cls.kind(+q: String) -> ClsTok:
  match q:
    case SNil{}:
      TEnd{}
    case SCon{Chr{+a}, +t}:
      Bool.pick(ClsTok, U32.is_eq(a, 92), cls.esc(t), Bool.pick(ClsTok, U32.is_eq(a, 93), TClose{t}, cls.three(a, t)))

# whether byte c is in a class, and the pattern after its ']' (none left
# when no ']' ends it); f bounds the steps (each takes a byte at least)
def sm.cls(f: Nat, tok: ClsTok, +nc: Bool, +c: U32, m: Bool) -> Bool & String:
  match f:
    case 0n:
      (m, SNil{})
    case 1n+g:
      match tok:
        case TEnd{}:
          (m, SNil{})
        case TEsc{x, rest}:
          sm.cls(g, cls.kind(rest), nc, c, Bool.or(m, U32.is_eq(x, c)))
        case TClose{rest}:
          (m, rest)
        case TRange{a, z, rest}:
          sm.cls(g, cls.kind(rest), nc, c, Bool.or(m, sm.range(nc, a, z, c)))
        case TOne{a, rest}:
          sm.cls(g, cls.kind(rest), nc, c, Bool.or(m, sm.eq(nc, a, c)))

def sm.cls.of(+q: String, +nc: Bool, +c: U32) -> Bool & String:
  sm.cls(1n+String.length(q), cls.kind(q), nc, c, False{})

# what the matcher does next: a step of the pattern on a string that is
# not empty; the bottom of Redis's loop (the string may be used up); the
# step after a byte or a class, which matched or not; a run of stars
# done (the pattern is what follows it); the rest after a '*' tried at s
# and then at each later byte; and what that try gave
type SmMode is Data:
  SmStep{}
  SmNext{}
  SmLit{ok: Bool}
  SmCls{ok: Bool, rest: String}
  SmStars{}
  SmStar{}
  SmTry{r: Sm}

def sm.cls.mode(neg: Bool, r: Bool & String) -> SmMode:
  (m, rest) = r
  SmCls{Bool.xor(neg, m), rest}

def sm.class(+q: String, +nc: Bool, +c: U32) -> SmMode:
  match q:
    case SCon{Chr{+h}, +t}:
      Bool.pick(SmMode, U32.is_eq(h, 94), sm.cls.mode(True{}, sm.cls.of(t, nc, c)), sm.cls.mode(False{}, sm.cls.of(SCon{Chr{h}, t}, nc, c)))
    case SNil{}:
      sm.cls.mode(False{}, sm.cls.of(SNil{}, nc, c))

def sm.unstar(p: String) -> String:
  match p:
    case SCon{'*', t}:
      sm.unstar(t)
    case _:
      p

# the end of the pattern once the string is used up: stars only
def sm.ends(p: String) -> Sm:
  match p:
    case SNil{}:
      SmYes{}
    case SCon{'*', t}:
      sm.ends(t)
    case _:
      SmNo{}

def sm.yes(r: Sm) -> Bool:
  match r:
    case SmYes{}:
      True{}
    case _:
      False{}

# one function, so that a decision can recurse: f bounds the depth (each
# call goes one level down)
def sm.go(f: Nat, mode: SmMode, +p: String, +s: String, +nc: Bool) -> Sm:
  match f:
    case 0n:
      SmNo{}
    case 1n++g:
      match mode:
        case SmNext{}:
          match s:
            case SNil{}:
              sm.ends(p)
            case SCon{c, t}:
              sm.go(g, SmStep{}, p, SCon{c, t}, nc)
        case SmLit{ok}:
          match ok s:
            case True{} SCon{c, t}:
              sm.go(g, SmNext{}, p, t, nc)
            case _ _:
              SmNo{}
        case SmCls{ok, rest}:
          match ok s:
            case True{} SCon{c, t}:
              sm.go(g, SmNext{}, rest, t, nc)
            case _ _:
              SmNo{}
        case SmStars{}:
          match p:
            case SNil{}:
              SmYes{}
            case SCon{a, q}:
              sm.go(g, SmStar{}, SCon{a, q}, s, nc)
        case SmStar{}:
          match s:
            case SNil{}:
              SmStop{}
            case SCon{+c, +t}:
              sm.go(g, SmTry{sm.go(g, SmStep{}, p, SCon{c, t}, nc)}, p, SCon{c, t}, nc)
        case SmTry{r}:
          match r s:
            case SmYes{} _:
              SmYes{}
            case SmStop{} _:
              SmStop{}
            case SmNo{} SNil{}:
              SmStop{}
            case SmNo{} SCon{c, t}:
              sm.go(g, SmStar{}, p, t, nc)
        case SmStep{}:
          match p s:
            case SNil{} _:
              SmNo{}
            case _ SNil{}:
              SmNo{}
            case SCon{'*', pt} SCon{c, t}:
              sm.go(g, SmStars{}, sm.unstar(pt), SCon{c, t}, nc)
            case SCon{'?', pt} SCon{c, t}:
              sm.go(g, SmNext{}, pt, t, nc)
            case SCon{'[', pt} SCon{Chr{+x}, t}:
              sm.go(g, sm.class(pt, nc, x), pt, SCon{Chr{x}, t}, nc)
            case SCon{'\\', SCon{Chr{+y}, pt}} SCon{Chr{+x}, t}:
              sm.go(g, SmLit{sm.eq(nc, y, x)}, pt, SCon{Chr{x}, t}, nc)
            case SCon{Chr{+y}, pt} SCon{Chr{+x}, t}:
              sm.go(g, SmLit{sm.eq(nc, y, x)}, pt, SCon{Chr{x}, t}, nc)

# whether pattern p matches string s, case aside when nc
def stringmatch(+p: String, +s: String, nc: Bool) -> Bool:
  match s:
    case SNil{}:
      String.is_empty(p)
    case SCon{c, t}:
      sm.yes(sm.go(Nat.mul(4n, Nat.add(4n, Nat.add(String.length(p), String.length(s)))), SmStep{}, p, SCon{c, t}, nc))

def glob_keep(+k: String, ks: List<&2, Reply>, hit: Bool) -> List<&2, Reply>:
  match hit:
    case True{}:
      RBulk{k} <> ks
    case False{}:
      ks

# whether KEYS lists a key: all of them for "*", the empty key too, as
# Redis takes them without matching
def glob_hit(all: Bool, +p: String, +k: String) -> Bool:
  match all:
    case True{}:
      True{}
    case False{}:
      stringmatch(p, k, False{})

def glob_go(+all: Bool, +p: String, ks: List<&2, String>) -> List<&2, Reply>:
  match ks:
    case Nil{}:
      Nil{}
    case Con{+k, rest}:
      glob_keep(k, glob_go(all, p, rest), glob_hit(all, p, k))

def glob_filter(+p: String, ks: List<&2, String>) -> List<&2, Reply>:
  glob_go(String.eq(p, "*"), p, ks)

# SCAN's reply: the scan's keys, filtered (the parser is above parse_id)
# the keys a scan found, by the pattern ("*" when there is none), then by
# the type: BendKV holds strings only, so a type other than "string"
# keeps none
def scan.match(ks: List<&2, String>, pat: Maybe<&2, String>) -> List<&2, Reply>:
  match pat:
    case Some{+p}:
      glob_filter(p, ks)
    case None{}:
      glob_filter("*", ks)

def scan.typed(ks: List<&2, String>, pat: Maybe<&2, String>, ok: Bool) -> List<&2, Reply>:
  match ok:
    case True{}:
      scan.match(ks, pat)
    case False{}:
      Nil{}

def scan.keep(ks: List<&2, String>, pat: Maybe<&2, String>, typ: Maybe<&2, String>) -> List<&2, Reply>:
  match typ:
    case Some{+t}:
      scan.typed(ks, pat, is_word(t, "STRING"))
    case None{}:
      scan.match(ks, pat)

def scan.rep(+next: Nat, ks: List<&2, String>, pat: Maybe<&2, String>, typ: Maybe<&2, String>) -> Reply:
  RArray{[RBulk{Nat.show(next)}, RArray{scan.keep(ks, pat, typ)}]}

def scan.out(sc: KV.Scan, pat: Maybe<&2, String>, typ: Maybe<&2, String>) -> Reply:
  match sc:
    case KV.Stop{+at, acc}:
      scan.rep(Bool.pick(Nat, Nat.is_lt(at, 1048576n), at, 0n), List.reverse(&2, String, acc), pat, typ)
    case KV.Scan{w, acc}:
      scan.rep(0n, List.reverse(&2, String, acc), pat, typ)

def scan.reply(a: ScanArgs, +d: KV.Trie<String>, +now: Nat) -> Reply:
  match a:
    case ScanArgs{+cur, +n, pat, typ}:
      scan.out(KV.scan(String, d, cur, n, now), pat, typ)
    case ScanBad{r}:
      r

# Execution
# ---------
# A key whose time has passed is not there for any command (Redis's keys
# expire at their time), but its entry stays in the trie until a write
# puts the key anew or deletes it, or the server's sweep of expired keys
# does (below), as a Redis replica keeps such a key until its master
# deletes it (Redis itself also deletes it when a read comes to it). A
# read changes nothing, so the laws of reads and of commuting commands
# hold with time as without. DBSIZE and INFO's keyspace count the
# entries, as Redis counts the keys it has not deleted yet.

# the empty database
def db.empty() -> Db:
  Db{KV.empty(String), 0n, 0n, 0n, None{}}

# the database at the time now (ms since 1970): the server sets it before
# each group of batches, and while a file loads it is 0, when no key has
# expired (Redis expires nothing while it loads)
def db.at(+now: Nat, db: Db) -> Db:
  match db:
    case Db{t, n, x, old, rr}:
      Db{t, n, x, now, rr}

# the trie of a database, and how many keys it counts and how many of
# them have a time (for the laws, and for INFO's keyspace)
def db.t(d: Db) -> KV.Trie<String>:
  match d:
    case Db{t, n, x, now, rr}:
      t

def db.n(+d: Db) -> Nat:
  match d:
    case Db{t, +n, x, now, rr}:
      n

def db.x(+d: Db) -> Nat:
  match d:
    case Db{t, n, +x, now, rr}:
      x

def db.now(+d: Db) -> Nat:
  match d:
    case Db{t, n, x, +now, rr}:
      now

# the trie of a database it lends, for a read
def db.trie(+d: Db) -> KV.Trie<String>:
  match d:
    case Db{+t, n, x, now, rr}:
      t

# The counts after a write of a key whose code was c (KV.code.at: 0 when
# the trie did not hold the key, else 1 plus its time): one more key for a
# new one, and of keys with a time, one more when its time e is one and
# one less when it had one
def cnt.n(+c: Nat, +n: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_eq(c, 0n), 1n+n, n)

def cnt.x(+c: Nat, +e: Nat, +x: Nat) -> Nat:
  Nat.sub(Nat.add(x, Bool.pick(Nat, Nat.is_eq(e, 0n), 0n, 1n)), Bool.pick(Nat, Nat.is_lt(1n, c), 1n, 0n))

# whether a key of code c is there at now
def code.live(+c: Nat, +now: Nat) -> Bool:
  Bool.and(Nat.is_lt(0n, c), KV.live(now, Nat.sub(c, 1n)))

# SET of k to v, counted: the key's code is asked first, while the trie is
# lent (KV.code.at), so that a new key counts and a key that had a time
# loses it
def db.set(db: Db, +k: String, v: String) -> Db:
  match db:
    case Db{t, +n, +x, now, rr}:
      +u = t
      +h = KV.hash(k)
      +c = KV.code.at(String, u, k, h)
      Db{KV.set.at(String, u, k, v, h), cnt.n(c, n), cnt.x(c, 0n, x), now, rr}

# GET's read of a database it lends: k's value when the key is there at
# now, copied (KV.get_copy)
def db.get_copy(+d: Db, +k: String) -> Maybe<&2, String>:
  match d:
    case Db{+t, n, x, +now, rr}:
      KV.get_copy(t, k, now)

# DEL: the keys removed in order; how many of them were there at now (the
# reply), how many entries went and how many of those had a time (for the
# counts)
type Dels is Data:
  Dels{live: Nat, gone: Nat, gonex: Nat, t: KV.Trie<String>}

def del_keys.put(+c: Nat, +now: Nat, r: Dels) -> Dels:
  match r:
    case Dels{+live, +gone, +gonex, t}:
      Dels{Nat.add(live, Bool.pick(Nat, code.live(c, now), 1n, 0n)), Nat.add(gone, Bool.pick(Nat, Nat.is_eq(c, 0n), 0n, 1n)), Nat.add(gonex, Bool.pick(Nat, Nat.is_lt(1n, c), 1n, 0n)), t}

def del_keys(ks: List<&2, String>, +now: Nat, db: KV.Trie<String>) -> Dels:
  match ks:
    case Nil{}:
      Dels{0n, 0n, 0n, db}
    case Con{+k, rest}:
      +u = db
      +h = KV.hash(k)
      +c = KV.code.at(String, u, k, h)
      del_keys.put(c, now, del_keys(rest, now, KV.del.at(String, u, k, h)))

def del.db(r: Dels, +n: Nat, +x: Nat, now: Nat, rr: Maybe<&2, Db>) -> Reply & Db:
  match r:
    case Dels{+live, +gone, +gonex, t}:
      (r_int(live), Db{t, Nat.sub(n, gone), Nat.sub(x, gonex), now, rr})

def db.del(db: Db, ks: List<&2, String>) -> Reply & Db:
  match db:
    case Db{t, +n, +x, +now, rr}:
      del.db(del_keys(ks, now, t), n, x, now, rr)

# EXISTS: how many of the keys are there at now (a repeated key counts
# again)
def exists_keys(ks: List<&2, String>, +now: Nat, +db: KV.Trie<String>) -> Nat:
  match ks:
    case Nil{}:
      0n
    case Con{+k, rest}:
      Nat.add(Bool.pick(Nat, Maybe.is_some(&2, String, KV.read(String, db, k, now)), 1n, 0n), exists_keys(rest, now, db))

def mget_keys(ks: List<&2, String>, +now: Nat, +db: KV.Trie<String>) -> List<&2, Reply>:
  match ks:
    case Nil{}:
      Nil{}
    case Con{+k, rest}:
      i_get(KV.read(String, db, k, now)) <> mget_keys(rest, now, db)

def mset_pairs(ps: List<&2, KVPair>, db: Db) -> Db:
  match ps:
    case Nil{}:
      db
    case Con{KP{k, v}, rest}:
      mset_pairs(rest, db.set(db, k, v))

# INCRBY: the stored value must read as an integer, and the sum must fit.
# A key there at now keeps its time (keep); a new one, or one whose time
# has passed, gets none: m and y are the counts once the sum is stored, n
# and x before.
def incr.put(keep: Bool, t: KV.Trie<String>, +k: String, v: String, +h: U32) -> KV.Trie<String>:
  match keep:
    case True{}:
      KV.keep.at(String, t, k, v, h)
    case False{}:
      KV.set.at(String, t, k, v, h)

def incr.fit(t: KV.Trie<String>, +k: String, +h: U32, +i: Int, ok: Bool, keep: Bool, m: Nat, n: Nat, y: Nat, x: Nat, now: Nat, rr: Maybe<&2, Db>) -> Reply & Db:
  match ok:
    case True{}:
      (RInt{i}, Db{incr.put(keep, t, k, int_show(i), h), m, y, now, rr})
    case False{}:
      (RError{"ERR increment or decrement would overflow"}, Db{t, n, x, now, rr})

# the integer a key there holds, or none
def incr.num(t: KV.Trie<String>, +k: String, +h: U32, by: Int, +n: Nat, +x: Nat, now: Nat, rr: Maybe<&2, Db>, cur: Maybe<&2, Int>) -> Reply & Db:
  match cur:
    case Some{i}:
      +s = int_add(i, by)
      incr.fit(t, k, h, s, int_fits(s), True{}, n, n, x, x, now, rr)
    case None{}:
      (e_int(), Db{t, n, x, now, rr})

# a key that is not there reads as 0: the sum is by; c is its code
def incr.new(t: KV.Trie<String>, +k: String, +h: U32, +by: Int, +n: Nat, +x: Nat, now: Nat, rr: Maybe<&2, Db>, +c: Nat) -> Reply & Db:
  incr.fit(t, k, h, by, int_fits(by), False{}, cnt.n(c, n), n, cnt.x(c, 0n, x), x, now, rr)

# the value of INCRBY's key there at now (old), or none
def incr.got(t: KV.Trie<String>, +k: String, +h: U32, +by: Int, +n: Nat, +x: Nat, now: Nat, rr: Maybe<&2, Db>, old: Maybe<&2, String>) -> Reply & Db:
  match old:
    case Some{s}:
      incr.num(t, k, h, by, n, x, now, rr, int_read(s))
    case None{}:
      +u = t
      incr.new(u, k, h, by, n, x, now, rr, KV.code.at(String, u, k, h))

def db.incr(db: Db, +k: String, by: Int) -> Reply & Db:
  match db:
    case Db{t, n, x, +now, rr}:
      +u = t
      +h = KV.hash(k)
      incr.got(u, k, h, by, n, x, now, rr, KV.live.at(String, u, k, h, now))

# A key's entry, when it is there at now; and the code of an entry
def ent.live(+now: Nat, m: Maybe<&2, KV.Item<String>>) -> Maybe<&2, KV.Item<String>>:
  match m:
    case Some{KV.Item{v, +e}}:
      Bool.pick(Maybe<&2, KV.Item<String>>, KV.live(now, e), Some{KV.Item{v, e}}, None{})
    case None{}:
      None{}

def ent.code(+m: Maybe<&2, KV.Item<String>>) -> Nat:
  match m:
    case Some{KV.Item{v, +e}}:
      1n+e
    case None{}:
      0n

# k's entry in a database it lends, there at now or not
def db.entry(+d: Db, +k: String) -> Maybe<&2, KV.Item<String>>:
  match d:
    case Db{+t, n, x, now, rr}:
      KV.entry.at(String, t, k, KV.hash(k))

# k's entry in a database it lends, when the key is there at now
def db.ent(+d: Db, +k: String) -> Maybe<&2, KV.Item<String>>:
  match d:
    case Db{+t, n, x, +now, rr}:
      ent.live(now, KV.entry.at(String, t, k, KV.hash(k)))

def strlen_of(m: Maybe<&2, KV.Item<String>>) -> Nat:
  match m:
    case Some{KV.Item{v, e}}:
      String.length(v)
    case None{}:
      0n

# TTL and its kin: -2 for a key that is not there, -1 for one with no
# time, else the time left (or, abs, the time it expires at), in ms or in
# s rounded to the nearest
def ttl.e(ms: Bool, abs: Bool, +now: Nat, +e: Nat) -> Reply:
  match e:
    case 0n:
      RInt{INeg{0n}}
    case 1n+p:
      +t = Bool.pick(Nat, abs, e, Nat.sub(e, now))
      RInt{IPos{Bool.pick(Nat, ms, t, Nat.div(Nat.add(t, 500n), 1000n))}}

def ttl.of(ms: Bool, abs: Bool, +now: Nat, m: Maybe<&2, KV.Item<String>>) -> Reply:
  match m:
    case Some{KV.Item{v, +e}}:
      ttl.e(ms, abs, now, e)
    case None{}:
      RInt{INeg{1n}}

# the reply of a Peek, from the entry of its key there at now
def peek(c: PeekOp, +now: Nat, m: Maybe<&2, KV.Item<String>>) -> Reply:
  match c:
    case PType{}:
      Bool.pick(Reply, Maybe.is_some(&2, KV.Item<String>, m), RStatus{"string"}, RStatus{"none"})
    case PStrlen{}:
      r_int(strlen_of(m))
    case PTtl{}:
      ttl.of(False{}, False{}, now, m)
    case PPttl{}:
      ttl.of(True{}, False{}, now, m)
    case PExpTime{}:
      ttl.of(False{}, True{}, now, m)
    case PPExpTime{}:
      ttl.of(True{}, True{}, now, m)

# What a write of one key does to it: nothing, delete it, set its time
# alone, set its value and its time (0: none), or set its value and keep
# its time, for a key that is there (CKeepT; CApp for an APPEND of s,
# which leaves v). An Upd's reply and change come from the key's entry
# there at now alone. A time a change gives a key is one the key may keep
# (KV.clamp: a time at or past the year 5138 is none), and a key without
# a time is never given none again (exp.to): so the change the
# append-only file logs for it (aof.bend) makes it again, on any
# database.
type Change is Data:
  CKeep{}
  CDel{}
  CExp{e: Nat}
  CPut{v: String, e: Nat}
  CKeepT{v: String}
  CApp{s: String, v: String}

type Out is Data:
  Out{r: Reply, ch: Change}

def setnx.of(v: String, m: Maybe<&2, KV.Item<String>>) -> Out:
  match m:
    case Some{x}:
      Out{r_int(0n), CKeep{}}
    case None{}:
      Out{r_int(1n), CPut{v, 0n}}

# APPEND: the old value with v after it, keeping the key's time, or v
def append.of(+v: String, m: Maybe<&2, KV.Item<String>>) -> Out:
  match m:
    case Some{KV.Item{w, e}}:
      +s = w ++ v
      Out{r_int(String.length(s)), CApp{v, s}}
    case None{}:
      +s = v
      Out{r_int(String.length(s)), CPut{s, 0n}}

# INCRBY as an update (as db.incr runs it): the integer the key holds
# plus by, keeping the key's time (keep), or by for a key that is not
# there; the value must read as an integer, and the sum must fit
def uincr.ch(keep: Bool, v: String) -> Change:
  match keep:
    case True{}:
      CKeepT{v}
    case False{}:
      CPut{v, 0n}

def uincr.fit(+i: Int, ok: Bool, keep: Bool) -> Out:
  match ok:
    case True{}:
      Out{RInt{i}, uincr.ch(keep, int_show(i))}
    case False{}:
      Out{RError{"ERR increment or decrement would overflow"}, CKeep{}}

def uincr.num(by: Int, cur: Maybe<&2, Int>) -> Out:
  match cur:
    case Some{i}:
      +s = int_add(i, by)
      uincr.fit(s, int_fits(s), True{})
    case None{}:
      Out{e_int(), CKeep{}}

def uincr.of(+by: Int, m: Maybe<&2, KV.Item<String>>) -> Out:
  match m:
    case Some{KV.Item{+w, e}}:
      uincr.num(by, int_read(w))
    case None{}:
      uincr.fit(by, int_fits(by), False{})

# the value and the time of an entry
def ent.val(+m: Maybe<&2, KV.Item<String>>) -> Maybe<&2, String>:
  match m:
    case Some{KV.Item{+v, e}}:
      Some{v}
    case None{}:
      None{}

def ent.exp(+m: Maybe<&2, KV.Item<String>>) -> Nat:
  match m:
    case Some{KV.Item{v, +e}}:
      e
    case None{}:
      0n

# SET with options: NX (cond 1) sets a key that is not there, XX (2) one
# that is (ch, the change it makes); the key's time is none, the one it
# had (KEEPTTL, for a key that is there), or the one given, past or not
# (Redis then sets a key that has expired)
def set.do(+cond: Nat, ch: Change, +m: Maybe<&2, KV.Item<String>>) -> Out:
  +there = Maybe.is_some(&2, KV.Item<String>, m)
  Bool.pick(Out, Bool.or(Bool.and(Nat.is_eq(cond, 1n), there), Bool.and(Nat.is_eq(cond, 2n), Bool.not(there))), Out{RNull{}, CKeep{}},
    Out{r_ok(), ch})

def set.at(+cond: Nat, v: String, +name: String, a: Maybe<&2, At>, +m: Maybe<&2, KV.Item<String>>) -> Out:
  match a:
    case Some{+t}:
      set.do(cond, CPut{v, KV.clamp(at.exp(t))}, m)
    case None{}:
      Out{e_time(name), CKeep{}}

def set.kept(v: String, +m: Maybe<&2, KV.Item<String>>) -> Change:
  match m:
    case Some{x}:
      CKeepT{v}
    case None{}:
      CPut{v, 0n}

def set.of(v: String, +cond: Nat, ttl: SetTtl, +name: String, +now: Nat, +m: Maybe<&2, KV.Item<String>>) -> Out:
  match ttl:
    case TNone{}:
      set.do(cond, CPut{v, 0n}, m)
    case TKeep{}:
      set.do(cond, set.kept(v, m), m)
    case TAt{t}:
      set.at(cond, v, name, at.of(t, now), m)

# an error reply
def r_is_err(+r: Reply) -> Bool:
  match r:
    case RError{s}:
      True{}
    case _:
      False{}

# GET of an update: the reply is the old value (nil for none) whether the
# key is set or not, unless the update fails (a time Redis cannot keep)
def get.out(+old: Reply, o: Out) -> Out:
  match o:
    case Out{+r, ch}:
      Out{Bool.pick(Reply, r_is_err(r), r, old), ch}

# a key's new time f (0: none), when it had e: nothing to do when it had
# none and gets none
def exp.to(+f: Nat, +e: Nat) -> Change:
  Bool.pick(Change, Bool.and(Nat.is_eq(f, 0n), Nat.is_eq(e, 0n)), CKeep{}, CExp{f})

# GETEX: the value of a key there (w, with time e); with PERSIST the key
# loses its time, with a time it expires then, or goes now when that
# time, from 1970, has passed. The time is read only for a key that is
# there, as Redis reads it.
def getex.at(+w: String, at: Bool, +now: Nat, +e: Nat, a: Maybe<&2, At>) -> Out:
  match a:
    case Some{+t}:
      Out{RBulk{w}, Bool.pick(Change, Bool.and(at, at.past(t, now)), CDel{}, exp.to(KV.clamp(at.exp(t)), e))}
    case None{}:
      Out{e_time("getex"), CKeep{}}

def getex.tm(+w: String, +at: Bool, +now: Nat, +e: Nat, r: TmR) -> Out:
  match r:
    case TOk{t}:
      getex.at(w, at, now, e, at.of(t, now))
    case TBad{x}:
      Out{x, CKeep{}}

def getex.ent(o: ExOpt, +now: Nat, +w: String, +e: Nat) -> Out:
  match o:
    case XNone{}:
      Out{RBulk{w}, CKeep{}}
    case XPersist{}:
      Out{RBulk{w}, Bool.pick(Change, Nat.is_eq(e, 0n), CKeep{}, CExp{0n})}
    case XAt{+at, ms, s}:
      getex.tm(w, at, now, e, tm.of(s, at, Bool.not(ms), True{}, "getex"))

def getex.of(o: ExOpt, +now: Nat, m: Maybe<&2, KV.Item<String>>) -> Out:
  match m:
    case Some{KV.Item{+w, +e}}:
      getex.ent(o, now, w, e)
    case None{}:
      Out{RNull{}, CKeep{}}

def getdel.of(m: Maybe<&2, KV.Item<String>>) -> Out:
  match m:
    case Some{KV.Item{w, e}}:
      Out{RBulk{w}, CDel{}}
    case None{}:
      Out{RNull{}, CKeep{}}

# EXPIRE's conditions on a key with time e (0: none): NX, none yet; XX,
# one; GT, one before the new time; LT, none or one after it
def expire.ok(c: ExpIf, +a: At, +e: Nat) -> Bool:
  match c:
    case ExpIf{+nx, +xx, +gt, +lt}:
      +none = Nat.is_eq(e, 0n)
      +gok = Bool.and(Bool.not(none), at.gt(a, e))
      +lok = Bool.or(none, at.lt(a, e))
      Bool.and(Bool.and(Bool.not(Bool.and(nx, Bool.not(none))), Bool.not(Bool.and(xx, none))), Bool.and(Bool.or(Bool.not(gt), gok), Bool.or(Bool.not(lt), lok)))

# EXPIRE and its kin: a key there gets the time, or goes when the time has
# passed (Redis's checkAlreadyExpired), if the conditions hold
def expire.do(+now: Nat, +e: Nat, a: At, ok: Bool) -> Out:
  match ok:
    case True{}:
      +t = a
      Out{r_int(1n), Bool.pick(Change, at.past(t, now), CDel{}, exp.to(KV.clamp(at.exp(t)), e))}
    case False{}:
      Out{r_int(0n), CKeep{}}

def expire.at(c: ExpIf, +name: String, +now: Nat, a: Maybe<&2, At>, m: Maybe<&2, KV.Item<String>>) -> Out:
  match a m:
    case None{} _:
      Out{e_time(name), CKeep{}}
    case Some{t} None{}:
      Out{r_int(0n), CKeep{}}
    case Some{+t} Some{KV.Item{w, +e}}:
      expire.do(now, e, t, expire.ok(c, t, e))

def persist.of(m: Maybe<&2, KV.Item<String>>) -> Out:
  match m:
    case Some{KV.Item{w, +e}}:
      Bool.pick(Out, Nat.is_eq(e, 0n), Out{r_int(0n), CKeep{}}, Out{r_int(1n), CExp{0n}})
    case None{}:
      Out{r_int(0n), CKeep{}}

def upd(op: UpdOp, +now: Nat, m: Maybe<&2, KV.Item<String>>) -> Out:
  match op:
    case USetNx{v}:
      setnx.of(v, m)
    case UGet{o}:
      +u = m
      +old = r_get(ent.val(u))
      get.out(old, upd(o, now, u))
    case UAppend{v}:
      append.of(v, m)
    case USet{v, +cond, ttl, +name}:
      set.of(v, cond, ttl, name, now, m)
    case UGetEx{o}:
      getex.of(o, now, m)
    case UGetDel{}:
      getdel.of(m)
    case UExpire{t, c, +name}:
      expire.at(c, name, now, at.of(t, now), m)
    case UPersist{}:
      persist.of(m)
    case UIncr{+by}:
      uincr.of(by, m)

# the change done to key k, whose code was c (a deleted key, or one whose
# time alone changes, was there)
def upd.ch(t: KV.Trie<String>, +k: String, +h: U32, +n: Nat, +x: Nat, now: Nat, rr: Maybe<&2, Db>, +c: Nat, r: Reply, ch: Change) -> Reply & Db:
  match ch:
    case CKeep{}:
      (r, Db{t, n, x, now, rr})
    case CDel{}:
      (r, Db{KV.del.at(String, t, k, h), Nat.sub(n, 1n), cnt.x(c, 0n, x), now, rr})
    case CExp{+e}:
      (r, Db{KV.expire.at(String, t, k, e, h), n, cnt.x(c, e, x), now, rr})
    case CPut{v, +e}:
      (r, Db{KV.setx.at(String, t, k, v, e, h), cnt.n(c, n), cnt.x(c, e, x), now, rr})
    case CKeepT{v}:
      (r, Db{KV.keep.at(String, t, k, v, h), cnt.n(c, n), x, now, rr})
    case CApp{s, v}:
      (r, Db{KV.keep.at(String, t, k, v, h), cnt.n(c, n), x, now, rr})

def upd.put(t: KV.Trie<String>, +k: String, +h: U32, +n: Nat, +x: Nat, now: Nat, rr: Maybe<&2, Db>, +c: Nat, o: Out) -> Reply & Db:
  match o:
    case Out{r, ch}:
      upd.ch(t, k, h, n, x, now, rr, c, r, ch)

# an Upd of k: k's entry is read while the trie is lent, then the change
# is made where it lies
def db.upd(db: Db, +k: String, op: UpdOp) -> Reply & Db:
  match db:
    case Db{t, +n, +x, +now, rr}:
      +u = t
      +h = KV.hash(k)
      +m = KV.entry.at(String, u, k, h)
      upd.put(u, k, h, n, x, now, rr, ent.code(m), upd(op, now, ent.live(now, m)))

def db.flush(db: Db) -> Db:
  match db:
    case Db{t, n, x, now, rr}:
      Db{KV.empty(String), 0n, 0n, now, rr}

# The sweep of expired keys
# -------------------------
# Redis deletes the keys whose time has passed when a command comes to
# one, and in a sweep from its cron; BendKV, in a sweep at each tick of
# its cron (server.bend). A sweep scans the trie from where the last one
# stopped, a bounded number of entries (KV.reap), and the server deletes
# what it found with DEL, a batch like any other, which the append-only
# file logs (Redis logs a DEL too). The keys found are checked again
# here, so that a sweep deletes no key that is there, whatever the scan
# finds (LAWS.bend: reap_keeps).

# the keys of ks that are not there at now
def reap.put(there: Bool, k: String, ks: List<&2, String>) -> List<&2, String>:
  match there:
    case True{}:
      ks
    case False{}:
      k <> ks

def reap.keys(ks: List<&2, String>, +d: Db) -> List<&2, String>:
  match ks:
    case Nil{}:
      Nil{}
    case Con{+k, rest}:
      reap.put(Maybe.is_some(&2, KV.Item<String>, db.ent(d, k)), k, reap.keys(rest, d))

# a sweep: the bucket the next one starts at (0 once it read the last
# bucket), and the keys it deletes
type Reap is Data:
  Reap{next: Nat, ks: List<&2, String>}

def reap.of(s: KV.Scan, +d: Db) -> Reap:
  match s:
    case KV.Stop{at, acc}:
      Reap{at, reap.keys(acc, d)}
    case KV.Scan{want, acc}:
      Reap{0n, reap.keys(acc, d)}

# the sweep of d from the bucket from on, until want entries are read
def reap(+d: Db, +from: Nat, +want: Nat) -> Reap:
  reap.of(KV.reap(String, db.trie(d), from, want, db.now(d)), d)

def reply_of(r: Reply & Db) -> Reply:
  (x, db) = r
  x

def db_of(r: Reply & Db) -> Db:
  (x, db) = r
  db

# one command: its reply and the database after it. The database is
# passed on, not shared, so a write rebuilds only the path it changes.
# A key read only reads the trie: the compiler lends t to the read and
# then hands t back, and the value it answers is kept in place, shared
# with the trie (Bend with bend-patches/borrow-reads.patch). GET answers a
# copy of the value instead, made while the trie is lent (KV.get_copy):
# the value in the trie stays unshared, so a read puts no seal on its
# entry, and the batch hints reach the value's bytes. KEYS and SCAN fold
# the whole trie, so they share it. A command that reads a key and then
# writes it hashes the key once (the .at walks: the walks with the hash
# given). A write that does not read the key (SET, MSET) asks the key's
# code first (KV.code.at), so that the counts change by what the key was.
def exec(cmd: Cmd, db: Db) -> Reply & Db:
  match cmd:
    case Ping{}:
      (RStatus{"PONG"}, db)
    case Echo{m}:
      (RBulk{m}, db)
    case Get{+k}:
      +d = db
      (r_get(db.get_copy(d, k)), d)
    case Set{+k, v}:
      (r_ok(), db.set(db, k, v))
    case Del{ks}:
      db.del(db, ks)
    case Exists{ks}:
      +d = db
      (r_int(exists_keys(ks, db.now(d), db.trie(d))), d)
    case IncrBy{+k, by}:
      db.incr(db, k, by)
    case MGet{ks}:
      +d = db
      (RArray{mget_keys(ks, db.now(d), db.trie(d))}, d)
    case MSet{ps}:
      (r_ok(), mset_pairs(ps, db))
    case DbSize{}:
      +d = db
      (r_int(db.n(d)), d)
    case FlushAll{}:
      (r_ok(), db.flush(db))
    case Keys{p}:
      +d = db
      (RArray{glob_filter(p, KV.keys(String, db.trie(d), db.now(d)))}, d)
    case Scan{args}:
      +d = db
      (scan.reply(scan.args(args), db.trie(d), db.now(d)), d)
    case Peek{+k, c}:
      +d = db
      (peek(c, db.now(d), db.ent(d, k)), d)
    case Upd{+k, op}:
      db.upd(db, k, op)
    case Own{o}:
      (RError{"ERR a command of the connection, not of the database"}, db)
    case Bad{r}:
      (r, db)

# a batch of commands, in order: the replies in order, and the database
# after the last
def exec_all.put(rs: List<&2, Reply>, r: Reply & Db) -> List<&2, Reply> & Db:
  (x, db) = r
  (x <> rs, db)

def exec_all.step(c: Cmd, st: List<&2, Reply> & Db) -> List<&2, Reply> & Db:
  (rs, db) = st
  exec_all.put(rs, exec(c, db))

def exec_all.go(cmds: List<&2, Cmd>, st: List<&2, Reply> & Db) -> List<&2, Reply> & Db:
  match cmds:
    case Nil{}:
      st
    case Con{c, rest}:
      exec_all.go(rest, exec_all.step(c, st))

def exec_all.fin(st: List<&2, Reply> & Db) -> List<&2, Reply> & Db:
  (rs, db) = st
  (List.reverse(&2, Reply, rs), db)

# a reply in front of a batch's replies (the spec of exec_all uses it)
def exec_all.cons(r: Reply, rest: List<&2, Reply> & Db) -> List<&2, Reply> & Db:
  (rs, db) = rest
  (r <> rs, db)

def exec_all(cmds: List<&2, Cmd>, db: Db) -> List<&2, Reply> & Db:
  exec_all.fin(exec_all.go(cmds, (Nil{}, db)))
