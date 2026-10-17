# Lua scripting: the engine
# =========================
# The engine of EVAL, EVALSHA, SCRIPT and FUNCTION is Redis 7.2.16's own
# Lua (deps/lua), built into the program by src/lua/engine.c, which
# declares the effects below. Bend drives a script as an automaton of
# steps, each a word and a string (the word's layout is in engine.c):
#
#   a call (kind 0): the arguments of redis.call or redis.pcall as the
#     RESP request a client would send, run as one, its reply's bytes
#     handed back with Engine.next(0, bytes) in the protocol of bits 4
#     to 7 (redis.setresp's);
#   a tick (kind 1): every 100,000 Lua instructions; Engine.next(1, "")
#     goes on, Engine.next(2, "") kills the script;
#   done (kind 2): the reply as RESP bytes in the caller's protocol, or,
#     with bit 8, an error's text (bit 9: one the statistics counted
#     already, when the call that made it ran);
#   a log line (kind 3), redis.log's, its level in bits 12 to 15, answered
#     with Engine.next(1, "");
#   an ACL check (kind 4): a command's arguments as a request, answered
#     with ":1" when the caller's user may run it and ":0" when it may not,
#     "-" when the command is not known and "!" when its arity does not
#     allow the request's number of words.
#
# FUNCTION and FCALL run on the same engine, in a Lua state of their own:
# an FCALL is a run of a function (Engine.start), FUNCTION LOAD and
# RESTORE are runs of loads (Engine.fload), whose steps are log lines and
# done, and the other subcommands are effects of their own.
#
# Only src/server.bend runs scripts; the proofs never see these effects.
import Base

# a step of a run: its word and its string
type Step is Data:
  Step{w: U32, s: String}

# the body of a script compiled and cached under its SHA1: a Step of
# 1 + (its flags << 1) and the sha, or of 0 and the error's text
# ("ERR ...")
def Engine.load(body: String) -> IO(Step):
  import "./lua/engine.c"
  import "./lua/engine.js"

# 0 when no cached script has the sha (40 hexadecimal digits, in either
# case), else 1 + (its flags << 1)
def Engine.find(sha: String) -> IO(U32):
  import "./lua/engine.c"
  import "./lua/engine.js"

# the first step of a run of the script of sha (EVAL rather than FCALL,
# bit 5), or of the function of that name (FCALL, FCALL_RO), with its
# keys and arguments as RESP arrays; word: the caller's protocol (bits 0
# to 3), whether the command was one of the read-only ones (bit 4)
def Engine.start(sha: String, keys: String, args: String, word: U32) -> IO(Step):
  import "./lua/engine.c"
  import "./lua/engine.js"

# the next step, after a reply (0, its bytes), a go-ahead (1) or a
# kill (2)
def Engine.next(word: U32, data: String) -> IO(Step):
  import "./lua/engine.c"
  import "./lua/engine.js"

# SCRIPT FLUSH: the cache emptied and the Lua state made anew
def Engine.flush() -> IO(Unit):
  import "./lua/engine.c"
  import "./lua/engine.js"

# how many scripts the cache holds
def Engine.count() -> IO(U32):
  import "./lua/engine.c"
  import "./lua/engine.js"

# the bytes the Lua state holds (INFO's used_memory_lua)
def Engine.mem() -> IO(U32):
  import "./lua/engine.c"
  import "./lua/engine.js"

# the bytes the cache of scripts holds (INFO's used_memory_scripts)
def Engine.cache_mem() -> IO(U32):
  import "./lua/engine.c"
  import "./lua/engine.js"

# Functions
# ---------

# the first step of a run of loads, the libraries' codes a RESP array;
# word: how to take them in (bits 0 to 2: 0 FUNCTION LOAD, 1 with REPLACE,
# 2 RESTORE's APPEND, 3 its REPLACE, 4 its FLUSH), whether FUNCTION LOAD's
# limit of 500 ms holds them (bit 3), and whether the last code is the
# error's text of RESTORE's read that failed after the others (bit 4);
# done with the library's name (LOAD) or nothing, or with bit 8 an error's
# text
def Engine.fload(codes: String, word: U32) -> IO(Step):
  import "./lua/engine.c"
  import "./lua/engine.js"

# FUNCTION DELETE: 1 when the library of the name was there
def Engine.fdelete(name: String) -> IO(U32):
  import "./lua/engine.c"
  import "./lua/engine.js"

# FUNCTION FLUSH: every library gone
def Engine.fflush() -> IO(Unit):
  import "./lua/engine.c"
  import "./lua/engine.js"

# FUNCTION LIST's reply as RESP bytes; word: WITHCODE (bit 0), LIBRARYNAME
# given (bit 1, its pattern the string), the protocol (bits 4 to 7)
def Engine.flist(pat: String, word: U32) -> IO(String):
  import "./lua/engine.c"
  import "./lua/engine.js"

# the libraries' codes as a RESP array (FUNCTION DUMP, the RDB file, the
# rewrite of the append-only file)
def Engine.fcodes() -> IO(String):
  import "./lua/engine.c"
  import "./lua/engine.js"

# the functions as a RESP array of each one's name in lower case and its
# flags in decimal, for the actor's mirror
def Engine.ffuncs() -> IO(String):
  import "./lua/engine.c"
  import "./lua/engine.js"

# how many libraries (0) or functions (1) there are
def Engine.fcount(which: U32) -> IO(U32):
  import "./lua/engine.c"
  import "./lua/engine.js"

# the bytes of the functions' Lua state (0) or of their records (1)
def Engine.fmem(which: U32) -> IO(U32):
  import "./lua/engine.c"
  import "./lua/engine.js"
