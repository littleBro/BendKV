# redis.bend: the semantics of the Redis commands BendKV serves, as one
# pure function exec(cmd, db) -> (reply, db'). The server (server.bend)
# only moves bytes and calls exec in order, as Redis's single command
# thread does, so every law about exec is a law about the running server.

import Base
import ./map.bend as KV

# Types
# -----

# the database: string keys to string values (Redis strings are bytes;
# BendKV keeps one byte per Char)
def DB() -> Data:
  KV.Trie<String>

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

# A read of one key whose reply depends on the key's value alone. The
# laws see them as one command, Peek (LAWS.bend: disturbs), so one more
# needs no more proof.
type PeekOp is Data:
  PType{}

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
  SetNX{key: String, val: String}
  GetSet{key: String, val: String}
  Del{keys: List<&2, String>}
  Exists{keys: List<&2, String>}
  IncrBy{key: String, by: Int}
  Append{key: String, val: String}
  Strlen{key: String}
  MGet{keys: List<&2, String>}
  MSet{pairs: List<&2, KVPair>}
  DbSize{}
  FlushAll{}
  Keys{pattern: String}
  Scan{args: List<&2, String>}
  Peek{key: String, c: PeekOp}
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

def is_word(+s: String, w: String) -> Bool:
  String.eq(String.to_upper(s), w)

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
      Bool.pick(Nat, String.eq(n, "DEL"), 7n, 0n)))
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
      Bool.pick(Nat, String.eq(n, "INFO"), 48n, 0n))))))))))))
    case 5n:
      Bool.pick(Nat, String.eq(n, "SETNX"), 5n,
      Bool.pick(Nat, String.eq(n, "HELLO"), 41n,
      Bool.pick(Nat, String.eq(n, "RESET"), 44n, 0n)))
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
      Bool.pick(Nat, String.eq(n, "CLIENT"), 45n, 0n)))))))))))
    case 7n:
      Bool.pick(Nat, String.eq(n, "FLUSHDB"), 20n,
      Bool.pick(Nat, String.eq(n, "COMMAND"), 49n, 0n))
    case 8n:
      Bool.pick(Nat, String.eq(n, "FLUSHALL"), 19n,
      Bool.pick(Nat, String.eq(n, "FUNCTION"), 46n, 0n))
    case 9n:
      Bool.pick(Nat, String.eq(n, "RANDOMKEY"), 50n, 0n)
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
          e_syntax()
        case _:
          e_arity("set")
    case 5n:  # SETNX
      match args:
        case Con{k, Con{v, Nil{}}}:
          SetNX{k, v}
        case _:
          e_arity("setnx")
    case 6n:  # GETSET
      match args:
        case Con{k, Con{v, Nil{}}}:
          GetSet{k, v}
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
          Append{k, v}
        case _:
          e_arity("append")
    case 15n:  # STRLEN
      match args:
        case Con{k, Nil{}}:
          Strlen{k}
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
    case 25n:  # TYPE
      match args:
        case Con{k, Nil{}}:
          Peek{k, PType{}}
        case _:
          e_arity("type")
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
    case 25n:
      23n
    case 40n:
      24n
    case 41n:
      25n
    case 42n:
      26n
    case 43n:
      27n
    case 44n:
      28n
    case 45n:
      29n
    case 46n:
      30n
    case 47n:
      31n
    case 48n:
      32n
    case 49n:
      33n
    case 50n:
      34n
    case _:
      0n

# a subcommand of CLIENT's key, by its number; 0 for none
def stat.sub.client(+sub: Nat) -> Nat:
  match sub:
    case 1n:
      35n
    case 2n:
      36n
    case 3n:
      37n
    case 4n:
      38n
    case 5n:
      39n
    case 6n:
      40n
    case 7n:
      41n
    case 8n:
      42n
    case 9n:
      43n
    case 10n:
      44n
    case _:
      0n

# a subcommand of FUNCTION's key, by its number; 0 for none
def stat.sub.function(+sub: Nat) -> Nat:
  match sub:
    case 1n:
      45n
    case 2n:
      46n
    case _:
      0n

# a subcommand of CONFIG's key, by its number; 0 for none
def stat.sub.config(+sub: Nat) -> Nat:
  match sub:
    case 1n:
      47n
    case 2n:
      48n
    case 3n:
      49n
    case 4n:
      50n
    case 5n:
      51n
    case _:
      0n

# a subcommand of COMMAND's key, by its number; 0 for none
def stat.sub.command(+sub: Nat) -> Nat:
  match sub:
    case 1n:
      52n
    case 2n:
      53n
    case 3n:
      54n
    case 4n:
      55n
    case 5n:
      56n
    case 6n:
      57n
    case 7n:
      58n
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
      "type"
    case 24n:
      "select"
    case 25n:
      "hello"
    case 26n:
      "auth"
    case 27n:
      "quit"
    case 28n:
      "reset"
    case 29n:
      "client"
    case 30n:
      "function"
    case 31n:
      "config"
    case 32n:
      "info"
    case 33n:
      "command"
    case 34n:
      "randomkey"
    case 35n:
      "client|id"
    case 36n:
      "client|help"
    case 37n:
      "client|reply"
    case 38n:
      "client|getname"
    case 39n:
      "client|setname"
    case 40n:
      "client|caching"
    case 41n:
      "client|unblock"
    case 42n:
      "client|getredir"
    case 43n:
      "client|no-evict"
    case 44n:
      "client|trackinginfo"
    case 45n:
      "function|flush"
    case 46n:
      "function|help"
    case 47n:
      "config|get"
    case 48n:
      "config|set"
    case 49n:
      "config|resetstat"
    case 50n:
      "config|rewrite"
    case 51n:
      "config|help"
    case 52n:
      "command|info"
    case 53n:
      "command|docs"
    case 54n:
      "command|list"
    case 55n:
      "command|help"
    case 56n:
      "command|count"
    case 57n:
      "command|getkeys"
    case 58n:
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
      4n
    case 24n:
      4n
    case 25n:
      3n
    case 26n:
      5n
    case 27n:
      3n
    case 28n:
      2n
    case 29n:
      5n
    case 30n:
      5n
    case 31n:
      5n
    case 32n:
      3n
    case 33n:
      3n
    case 34n:
      2n
    case 35n:
      4n
    case 36n:
      4n
    case 37n:
      6n
    case 38n:
      4n
    case 39n:
      6n
    case 40n:
      6n
    case 41n:
      7n
    case 42n:
      4n
    case 43n:
      6n
    case 44n:
      4n
    case 45n:
      5n
    case 46n:
      4n
    case 47n:
      7n
    case 48n:
      9n
    case 49n:
      4n
    case 50n:
      4n
    case 51n:
      4n
    case 52n:
      5n
    case 53n:
      5n
    case 54n:
      5n
    case 55n:
      4n
    case 56n:
      4n
    case 57n:
      9n
    case 58n:
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

def scan.reply(a: ScanArgs, +d: KV.Trie<String>) -> Reply:
  match a:
    case ScanArgs{+cur, +n, pat, typ}:
      scan.out(KV.scan(String, d, cur, n), pat, typ)
    case ScanBad{r}:
      r

# Execution
# ---------

def setnx.if(db: KV.Trie<String>, +k: String, v: String, +h: U32, had: Bool) -> Reply & KV.Trie<String>:
  match had:
    case True{}:
      (r_int(0n), db)
    case False{}:
      (r_int(1n), KV.set.at(String, db, k, v, h))

def del_keys.put(had: Bool, r: Nat & KV.Trie<String>) -> Nat & KV.Trie<String>:
  match had:
    case True{}:
      (n, db) = r
      (1n+n, db)
    case False{}:
      r

# DEL: the keys removed in order, and how many of them were present
def del_keys(ks: List<&2, String>, +db: KV.Trie<String>) -> Nat & KV.Trie<String>:
  match ks:
    case Nil{}:
      (0n, db)
    case Con{+k, rest}:
      del_keys.put(KV.has(String, db, k), del_keys(rest, KV.del(String, db, k)))


# EXISTS: how many of the keys are present (a repeated key counts again)
def exists_keys(ks: List<&2, String>, +db: KV.Trie<String>) -> Nat:
  match ks:
    case Nil{}:
      0n
    case Con{+k, rest}:
      Nat.add(Bool.pick(Nat, Maybe.is_some(&2, String, KV.get(String, db, k)), 1n, 0n), exists_keys(rest, db))

def mget_keys(ks: List<&2, String>, +db: KV.Trie<String>) -> List<&2, Reply>:
  match ks:
    case Nil{}:
      Nil{}
    case Con{+k, rest}:
      i_get(KV.get(String, db, k)) <> mget_keys(rest, db)

def mset_pairs(ps: List<&2, KVPair>, db: KV.Trie<String>) -> KV.Trie<String>:
  match ps:
    case Nil{}:
      db
    case Con{KP{k, v}, rest}:
      mset_pairs(rest, KV.set(String, db, k, v))

# INCRBY: the stored value must read as an integer, and the sum must fit
def incr.fit(db: KV.Trie<String>, +k: String, +h: U32, +n: Int, ok: Bool) -> Reply & KV.Trie<String>:
  match ok:
    case True{}:
      (RInt{n}, KV.set.at(String, db, k, int_show(n), h))
    case False{}:
      (RError{"ERR increment or decrement would overflow"}, db)

def incr.got(db: KV.Trie<String>, +k: String, +h: U32, by: Int, cur: Maybe<&2, Int>) -> Reply & KV.Trie<String>:
  match cur:
    case Some{x}:
      +n = int_add(x, by)
      incr.fit(db, k, h, n, int_fits(n))
    case None{}:
      (e_int(), db)

def incr.old(m: Maybe<&2, String>) -> Maybe<&2, Int>:
  match m:
    case Some{s}:
      int_read(s)
    case None{}:
      Some{IPos{0n}}

def append_to(m: Maybe<&2, String>, v: String) -> String:
  match m:
    case Some{s}:
      s ++ v
    case None{}:
      v

def strlen_of(m: Maybe<&2, String>) -> Nat:
  match m:
    case Some{s}:
      String.length(s)
    case None{}:
      0n

# the reply of a Peek, from the value of its key
def peek(c: PeekOp, m: Maybe<&2, String>) -> Reply:
  match c:
    case PType{}:
      Bool.pick(Reply, Maybe.is_some(&2, String, m), RStatus{"string"}, RStatus{"none"})

def del_reply(r: Nat & KV.Trie<String>) -> Reply & KV.Trie<String>:
  (n, db) = r
  (r_int(n), db)

def reply_of(r: Reply & KV.Trie<String>) -> Reply:
  (x, db) = r
  x

def db_of(r: Reply & KV.Trie<String>) -> KV.Trie<String>:
  (x, db) = r
  db

# one command: its reply and the database after it. The database is
# passed on, not shared, so a write rebuilds only the path it changes.
# A key read only reads the trie: the compiler lends d to KV.get and then
# hands d back, and the value it answers is kept in place, shared with the
# trie (Bend with bend-patches/borrow-reads.patch). GET answers a copy of
# the value instead, made while the trie is lent (KV.get_copy): the value
# in the trie stays unshared, so a read puts no seal on its entry, and the
# batch hints reach the value's bytes. DBSIZE and KEYS fold the whole
# trie, so they share it. A command that reads a key and then writes it
# hashes the key once (KV.get.at, KV.set.at: KV.get and KV.set with the
# hash given, as they compute it).
def exec(cmd: Cmd, db: KV.Trie<String>) -> Reply & KV.Trie<String>:
  match cmd:
    case Ping{}:
      (RStatus{"PONG"}, db)
    case Echo{m}:
      (RBulk{m}, db)
    case Get{+k}:
      +d = db
      (r_get(KV.get_copy(d, k)), d)
    case Set{+k, v}:
      (r_ok(), KV.set(String, db, k, v))
    case SetNX{+k, v}:
      +d = db
      +h = KV.hash(k)
      setnx.if(d, k, v, h, Maybe.is_some(&2, String, KV.get.at(String, d, k, h)))
    case GetSet{+k, v}:
      +d = db
      +h = KV.hash(k)
      (r_get(KV.get.at(String, d, k, h)), KV.set.at(String, d, k, v, h))
    case Del{ks}:
      del_reply(del_keys(ks, db))
    case Exists{ks}:
      +d = db
      (r_int(exists_keys(ks, d)), d)
    case IncrBy{+k, by}:
      +d = db
      +h = KV.hash(k)
      incr.got(d, k, h, by, incr.old(KV.get.at(String, d, k, h)))
    case Append{+k, v}:
      +d = db
      +h = KV.hash(k)
      +s = append_to(KV.get.at(String, d, k, h), v)
      (r_int(String.length(s)), KV.set.at(String, d, k, s, h))
    case Strlen{+k}:
      +d = db
      (r_int(strlen_of(KV.get(String, d, k))), d)
    case MGet{ks}:
      +d = db
      (RArray{mget_keys(ks, d)}, d)
    case MSet{ps}:
      (r_ok(), mset_pairs(ps, db))
    case DbSize{}:
      +d = db
      (r_int(KV.size(String, d)), d)
    case FlushAll{}:
      (r_ok(), KV.empty(String))
    case Keys{p}:
      +d = db
      (RArray{glob_filter(p, KV.keys(String, d))}, d)
    case Scan{args}:
      +d = db
      (scan.reply(scan.args(args), d), d)
    case Peek{+k, c}:
      +d = db
      (peek(c, KV.get(String, d, k)), d)
    case Own{o}:
      (RError{"ERR a command of the connection, not of the database"}, db)
    case Bad{r}:
      (r, db)

# a batch of commands, in order: the replies in order, and the database
# after the last
def exec_all.put(rs: List<&2, Reply>, r: Reply & KV.Trie<String>) -> List<&2, Reply> & KV.Trie<String>:
  (x, db) = r
  (x <> rs, db)

def exec_all.step(c: Cmd, st: List<&2, Reply> & KV.Trie<String>) -> List<&2, Reply> & KV.Trie<String>:
  (rs, db) = st
  exec_all.put(rs, exec(c, db))

def exec_all.go(cmds: List<&2, Cmd>, st: List<&2, Reply> & KV.Trie<String>) -> List<&2, Reply> & KV.Trie<String>:
  match cmds:
    case Nil{}:
      st
    case Con{c, rest}:
      exec_all.go(rest, exec_all.step(c, st))

def exec_all.fin(st: List<&2, Reply> & KV.Trie<String>) -> List<&2, Reply> & KV.Trie<String>:
  (rs, db) = st
  (List.reverse(&2, Reply, rs), db)

# a reply in front of a batch's replies (the spec of exec_all uses it)
def exec_all.cons(r: Reply, rest: List<&2, Reply> & KV.Trie<String>) -> List<&2, Reply> & KV.Trie<String>:
  (rs, db) = rest
  (r <> rs, db)

def exec_all(cmds: List<&2, Cmd>, db: KV.Trie<String>) -> List<&2, Reply> & KV.Trie<String>:
  exec_all.fin(exec_all.go(cmds, (Nil{}, db)))
