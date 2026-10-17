# Lua scripting: the engine
# =========================
# The engine of EVAL, EVALSHA, SCRIPT and FUNCTION is Redis 7.0.15's own
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
#     with ":1" when the command is known and ":0" when it is not.
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

# the first step of a run of the script of sha, with KEYS and ARGV as
# RESP arrays; word: the caller's protocol (bits 0 to 3), whether the
# command was EVAL_RO or EVALSHA_RO (bit 4), EVAL rather than FCALL
# (bit 5)
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
