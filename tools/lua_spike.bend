# A spike of the engine (src/script.bend, src/lua/engine.c): scripts
# loaded and run with canned replies to their calls, each step printed.
#   bun ../bend-patched/bend2/main.ts tools/lua_spike.bend -o build/lua_spike.c
#   clang-19 -std=c11 -O1 build/lua_spike.c deps/redis/deps/lua/src/*.c deps/redis/src/*.c
#     -I deps/redis/deps/lua/src -I deps/redis/src -DENABLE_CJSON_GLOBAL
#     -DREDIS_STATIC= -DLUA_USE_MKSTEMP -D_GNU_SOURCE -lpthread -lm -o build/lua_spike
import Base
import ../src/script.bend as S

# a step's kind, the low four bits of its word
def kind(w: U32) -> U32:
  U32.and(w, 15)

# the step shown: its kind, the script's protocol, the error bits
def show(+w: U32, s: String) -> String:
  "kind " ++ U32.show(kind(w)) ++ " resp " ++ U32.show(U32.and(U32.shrn(w, 4n), 15))
    ++ " err " ++ U32.show(U32.and(U32.shrn(w, 8n), 1))
    ++ " nostats " ++ U32.show(U32.and(U32.shrn(w, 9n), 1))
    ++ ": " ++ s

# whether p starts s
def starts(+p: String, s: String) -> Bool:
  String.eq(p, String.take(s, String.length(p)))

# the canned reply to a call: GET answers "bar", SET "+OK", INCR 7,
# PING "pong", anything else an error
def canned.on(g: Bool, st: Bool, i: Bool, p: Bool) -> String:
  match g:
    case True{}:
      "$3\r\nbar\r\n"
    case False{}:
      match st:
        case True{}:
          "+OK\r\n"
        case False{}:
          match i:
            case True{}:
              ":7\r\n"
            case False{}:
              match p:
                case True{}:
                  "$4\r\npong\r\n"
                case False{}:
                  "-ERR unknown command 'x', with args beginning with: \r\n"

def canned(+s: String) -> String:
  canned.on(starts("*2\r\n$3\r\nget\r\n", s), starts("*3\r\n$3\r\nset\r\n", s),
    starts("*2\r\n$4\r\nincr\r\n", s), starts("*2\r\n$4\r\nping\r\n", s))

# what to hand back for a step: a reply to a call (kind 0) or an ACL
# check (kind 4), a go-ahead to a tick or a log line
def answer.on(call: Bool, acl: Bool, s: String) -> IO(S.Step):
  match call:
    case True{}:
      S.Engine.next(0, canned(s))
    case False{}:
      match acl:
        case True{}:
          S.Engine.next(0, ":1\r\n")
        case False{}:
          S.Engine.next(1, "")

def answer(+w: U32, s: String) -> IO(S.Step):
  answer.on(U32.is_eq(kind(w), 0), U32.is_eq(kind(w), 4), s)

# the steps of a run, each printed, up to the done: the steps call each
# other directly, as the server's loops do
@unsafe
def drive(fuel: Nat, step: S.Step) -> IO(Unit):
  match fuel step:
    case 0n _:
      IO.print("out of fuel")
    case 1n+f S.Step{+w, +s}:
      do IO<Unit>:
        Unit <- IO.print(show(w, s))
        drive.on(f, U32.is_eq(kind(w), 2), w, s)

@unsafe
def drive.on(f: Nat, done: Bool, w: U32, s: String) -> IO(Unit):
  match done:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      do IO<Unit>:
        nx : S.Step <- answer(w, s)
        drive(f, nx)

# a loaded script run with the keys and args, in the caller's protocol
@unsafe
def run.go(ld: S.Step, keys: String, args: String, resp: U32) -> IO(Unit):
  match ld:
    case S.Step{lw, +sha}:
      do IO<Unit>:
        Unit <- IO.print("load " ++ U32.show(lw) ++ " " ++ sha)
        st : S.Step <- S.Engine.start(sha, keys, args, resp)
        drive(100n, st)

# a script loaded and run
@unsafe
def run(+body: String, keys: String, args: String, resp: U32) -> IO(Unit):
  do IO<Unit>:
    Unit <- IO.print("== " ++ body)
    ld : S.Step <- S.Engine.load(body)
    run.go(ld, keys, args, resp)

def main() -> IO(Unit):
  do IO<Unit>:
    Unit <- run("return redis.call('get', KEYS[1])", "*1\r\n$3\r\nfoo\r\n", "*0\r\n", 2)
    Unit <- run("return {1, 2, 'three', {ok='fine'}, redis.call('incr', 'n'), ARGV[1], ARGV[2]}", "*0\r\n", "*2\r\n$1\r\na\r\n$1\r\nb\r\n", 2)
    Unit <- run("return redis.pcall('nosuch', 'x')", "*0\r\n", "*0\r\n", 2)
    Unit <- run("return redis.call('nosuch', 'x')", "*0\r\n", "*0\r\n", 2)
    Unit <- run("return redis.error_reply('MY custom error')", "*0\r\n", "*0\r\n", 2)
    Unit <- run("local x = {} x.y.z = 1", "*0\r\n", "*0\r\n", 2)
    Unit <- run("return foo", "*0\r\n", "*0\r\n", 2)
    Unit <- run("redis.setresp(3) return redis.call('get', KEYS[1])", "*1\r\n$3\r\nfoo\r\n", "*0\r\n", 3)
    Unit <- run("return {true, false, 1.5, {double=1.5}, {map={a=1}}, {set={x=true}}}", "*0\r\n", "*0\r\n", 3)
    Unit <- run("redis.setresp(3) return {true, false}", "*0\r\n", "*0\r\n", 2)
    Unit <- run("return cjson.encode({a=1, b={1,2,3}}) .. ' ' .. cmsgpack.pack({1,2}):len() .. ' ' .. bit.band(12, 10) .. ' ' .. struct.pack('>I', 258):len()", "*0\r\n", "*0\r\n", 2)
    Unit <- run("local n = 0 for i = 1, 250000 do n = n + 1 end return n", "*0\r\n", "*0\r\n", 2)
    Unit <- run("redis.log(redis.LOG_WARNING, 'hello', 'world') return redis.sha1hex('')", "*0\r\n", "*0\r\n", 2)
    Unit <- run("return tostring(math.random())", "*0\r\n", "*0\r\n", 2)
    Unit <- run("#!lua flags=no-writes\nreturn 1", "*0\r\n", "*0\r\n", 2)
    Unit <- run("#!lua flags=nope\nreturn 1", "*0\r\n", "*0\r\n", 2)
    Unit <- run("return 1 +", "*0\r\n", "*0\r\n", 2)
    Unit <- run("return redis.acl_check_cmd('set', 'a', 'b')", "*0\r\n", "*0\r\n", 2)
    Unit <- run("return redis.call('ping', 1.5)", "*0\r\n", "*0\r\n", 2)
    Unit <- run("return {redis.pcall('nosuch')}", "*0\r\n", "*0\r\n", 2)
    cnt : U32 <- S.Engine.count()
    Unit <- IO.print("cached " ++ U32.show(cnt))
    Unit <- S.Engine.flush()
    cnt2 : U32 <- S.Engine.count()
    IO.print("after flush " ++ U32.show(cnt2))
