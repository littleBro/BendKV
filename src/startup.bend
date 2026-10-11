# startup.bend: how BendKV starts, as redis-server 7.0.15 starts (main in
# server.c, loadServerConfigFromString in config.c): its command line, and
# its configuration, read a line at a time. Pure: the shell (server.bend)
# reads the files, changes the directory and writes the log when this
# says so. Tested against redis-server (tests/start_test.py), not proved.
#
#   bendkv [/path/to/redis.conf] [--name value ...] [-]
#
# The file comes first; each --name starts a line of its own, with the
# arguments after it quoted, and these lines come after the file's (and
# after the standard input's, with "-"); the last value of a parameter is
# the one that counts. BendKV also keeps its short form, a port first:
#
#   bendkv PORT [post|send [FILE [always|everysec|no]]]

import Base
import ./resp.bend as P
import ./config.bend as C

def version() -> String:
  "0.1.0"

def version.line() -> String:
  "BendKV server v=" ++ version() ++ " redis=7.0.15 bits=64"

def usage() -> String:
  "Usage: ./bendkv [/path/to/redis.conf] [options] [-]\n" ++
  "       ./bendkv - (read config from stdin)\n" ++
  "       ./bendkv -v or --version\n" ++
  "       ./bendkv -h or --help\n" ++
  "       ./bendkv PORT [post|send [FILE [always|everysec|no]]]\n\n" ++
  "Examples:\n" ++
  "       ./bendkv (run the server with default conf)\n" ++
  "       echo 'maxmemory 128mb' | ./bendkv -\n" ++
  "       ./bendkv /etc/redis/6379.conf\n" ++
  "       ./bendkv --port 7777\n" ++
  "       ./bendkv /etc/myredis.conf --loglevel verbose -\n" ++
  "       ./bendkv /etc/myredis.conf --loglevel verbose\n" ++
  "       ./bendkv 6380 send appendonly.aof everysec (the short form)"

# Bytes
# -----

# a String of code points, as the runtime decodes the command line, as
# the bytes of its UTF-8, a Char each: the bytes a client sends
def utf8.char(+x: U32, +t: String) -> String:
  Bool.pick(String, U32.is_lt(x, 128), SCon{Chr{x}, t},
  Bool.pick(String, U32.is_lt(x, 2048), SCon{Chr{U32.or(192, U32.div(x, 64))}, SCon{Chr{U32.or(128, U32.and(x, 63))}, t}},
  Bool.pick(String, U32.is_lt(x, 65536), SCon{Chr{U32.or(224, U32.div(x, 4096))}, SCon{Chr{U32.or(128, U32.and(U32.div(x, 64), 63))}, SCon{Chr{U32.or(128, U32.and(x, 63))}, t}}},
    SCon{Chr{U32.or(240, U32.div(x, 262144))}, SCon{Chr{U32.or(128, U32.and(U32.div(x, 4096), 63))}, SCon{Chr{U32.or(128, U32.and(U32.div(x, 64), 63))}, SCon{Chr{U32.or(128, U32.and(x, 63))}, t}}}})))

def utf8(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{Chr{+x}, t}:
      utf8.char(x, utf8(t))

def utf8.all(xs: List<String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{x, rest}:
      utf8(x) <> utf8.all(rest)

# the words of a line, as Redis's sdssplitargs splits one (the splitter of
# inline requests, resp.bend); None for a quote left open
def split.fin(m: Maybe<&2, List<&2, String>>) -> Maybe<&2, List<&2, String>>:
  match m:
    case Some{ws}:
      Some{List.reverse(&2, String, ws)}
    case None{}:
      None{}

def split(+s: String) -> Maybe<&2, List<&2, String>>:
  split.fin(P.sp.run(Nat.mul(2n, 1n+String.length(s)), P.Go{P.MBlank{}, s, SNil{}, Nil{}}))

def split.count(m: Maybe<&2, List<&2, String>>) -> Nat:
  match m:
    case Some{ws}:
      List.length(&2, String, ws)
    case None{}:
      0n

# a String as Redis's sdscatrepr quotes it, which sdssplitargs reads back
def hex.digit(+d: U32) -> Char:
  Chr{Bool.pick(U32, U32.is_lt(d, 10), U32.add(48, d), U32.add(87, d))}

def repr.char(+x: U32) -> String:
  Bool.pick(String, U32.is_eq(x, 92), "\\\\",
  Bool.pick(String, U32.is_eq(x, 34), "\\\"",
  Bool.pick(String, U32.is_eq(x, 10), "\\n",
  Bool.pick(String, U32.is_eq(x, 13), "\\r",
  Bool.pick(String, U32.is_eq(x, 9), "\\t",
  Bool.pick(String, U32.is_eq(x, 7), "\\a",
  Bool.pick(String, U32.is_eq(x, 8), "\\b",
  Bool.pick(String, Bool.or(Bool.and(U32.is_le(32, x), U32.is_le(x, 126)), U32.is_le(256, x)), SCon{Chr{x}, SNil{}},
    SCon{'\\', SCon{'x', SCon{hex.digit(U32.div(x, 16)), SCon{hex.digit(U32.and(x, 15)), SNil{}}}}}))))))))

def repr.go(s: String) -> String:
  match s:
    case SNil{}:
      "\""
    case SCon{Chr{+x}, t}:
      repr.char(x) ++ repr.go(t)

def repr(s: String) -> String:
  "\"" ++ repr.go(s)

# sdstrim's blanks: ' ', '\t', '\r' and '\n'
def blank(+x: U32) -> Bool:
  Bool.or(Bool.or(U32.is_eq(x, 32), U32.is_eq(x, 9)), Bool.or(U32.is_eq(x, 13), U32.is_eq(x, 10)))

def trim.start(s: String) -> String:
  match s:
    case SCon{Chr{+x}, +t}:
      Bool.pick(String, blank(x), trim.start(t), SCon{Chr{x}, t})
    case SNil{}:
      SNil{}

def trim(s: String) -> String:
  String.reverse(trim.start(String.reverse(trim.start(s))))

def first(xs: List<&2, String>) -> String:
  match xs:
    case Con{x, rest}:
      x
    case Nil{}:
      ""

# Paths
# -----

# the directory above: "/a/b/" is "/a/", "/" is "/"
def abs.cut(s: String) -> String:
  match s:
    case SCon{'/', t}:
      SCon{'/', t}
    case SCon{c, t}:
      abs.cut(t)
    case SNil{}:
      SNil{}

def abs.up(+base: String) -> String:
  Bool.pick(String, Nat.is_lt(1n, String.length(base)), String.reverse(abs.cut(String.drop(String.reverse(base), 1n))), base)

def abs.dots(rel: String, +base: String) -> String:
  match rel:
    case SCon{'.', SCon{'.', SCon{'/', t}}}:
      abs.dots(t, abs.up(base))
    case other:
      base ++ other

def abs.slash(+cwd: String) -> String:
  Bool.pick(String, Bool.or(String.is_empty(cwd), U32.is_eq(String.code_at(String.reverse(cwd), 0n), 47)), cwd, cwd ++ "/")

# a path as Redis's getAbsolutePath makes one: trimmed, and if relative,
# after the working directory, with its leading "../" taken off it
def abs(+cwd: String, p: String) -> String:
  +rel = trim(p)
  Bool.pick(String, String.starts_with(rel, "/"), rel, abs.dots(rel, abs.slash(cwd)))

# The command line
# ----------------

# what the command line asks: the version, the usage, sentinel mode (which
# BendKV has not), the short form (its arguments after the port), or a
# configuration: its file, whether the standard input follows it, the
# lines of the options, and whether there were no arguments at all
type Cli is Data:
  CliVersion{}
  CliHelp{}
  CliSentinel{}
  CliShort{port: String, rest: List<&2, String>}
  CliConf{file: Maybe<&2, String>, stdin: Bool, opts: String, bare: Bool}

type OptStep is Data:
  OptStep{opts: String, handled: Bool, stdin: Bool}

# an argument that starts an option: its name starts a line, and the
# arguments after it follow on that line, unless it already has one ("--port
# 6380" as one argument). A --save with nothing after it but another option
# or the end is --save "", which takes the save points away.
def opt.name(+a: String, +next: String, +last: Bool, +opts: String, stdin: Bool) -> OptStep:
  +one = Nat.is_eq(split.count(split(a)), 1n)
  +save = String.eq(String.to_lower(a), "--save")
  +sent = String.eq(String.to_lower(a), "--sentinel")
  +nextopt = Bool.and(Bool.not(last), String.starts_with(next, "--"))
  +o1 = Bool.pick(String, String.is_empty(opts), opts, opts ++ "\n") ++ String.drop(a, 2n) ++ " "
  OptStep{o1 ++ Bool.pick(String, Bool.and(one, Bool.and(save, Bool.or(nextopt, last))), "\"\"", ""), Bool.or(Bool.not(one), Bool.and(Bool.or(save, sent), nextopt)), stdin}

def opt.step(+a: String, +next: String, +last: Bool, +first: Bool, +handled: Bool, +opts: String, +stdin: Bool) -> OptStep:
  Bool.pick(OptStep, Bool.and(String.eq(a, "-"), Bool.or(first, last)), OptStep{opts, handled, True{}},
    Bool.pick(OptStep, Bool.and(handled, String.starts_with(a, "--")), opt.name(a, next, last, opts, stdin),
      OptStep{opts ++ repr(a) ++ " ", True{}, stdin}))

def nonempty(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Con{x, rest}:
      True{}

# the options, as Redis's main turns them into lines; j1: whether this
# is the first argument (a "-" there or last reads the standard input)
def opt.go(args: List<&2, String>, st: OptStep, j1: Bool) -> OptStep:
  match args st:
    case Nil{} s:
      s
    case Con{+a, +rest} OptStep{+opts, +handled, +stdin}:
      opt.go(rest, opt.step(a, first(rest), Bool.not(nonempty(rest)), j1, handled, opts, stdin), False{})

def cli.conf(file: Maybe<&2, String>, st: OptStep) -> Cli:
  match st:
    case OptStep{opts, handled, stdin}:
      CliConf{file, stdin, opts, False{}}

def text.digits(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{Chr{+x}, t}:
      Bool.and(Bool.and(U32.is_le(48, x), U32.is_le(x, 57)), text.digits(t))

def cli.has(xs: List<&2, String>, +w: String) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Con{x, rest}:
      Bool.or(String.eq(x, w), cli.has(rest, w))

def cli.run(+a: String, +rest: List<&2, String>) -> Cli:
  Bool.pick(Cli, cli.has(a <> rest, "--sentinel"), CliSentinel{},
    Bool.pick(Cli, String.starts_with(a, "-"), cli.conf(None{}, opt.go(a <> rest, OptStep{"", True{}, False{}}, True{})),
      cli.conf(Some{a}, opt.go(rest, OptStep{"", True{}, False{}}, False{}))))

def cli.first(+a: String, +rest: List<&2, String>) -> Cli:
  Bool.pick(Cli, Bool.or(String.eq(a, "-v"), String.eq(a, "--version")), CliVersion{},
    Bool.pick(Cli, Bool.or(String.eq(a, "--help"), String.eq(a, "-h")), CliHelp{},
      Bool.pick(Cli, Bool.and(Bool.not(String.is_empty(a)), text.digits(a)), CliShort{a, rest}, cli.run(a, rest))))

# the arguments after the program's name, as their bytes
def cli.of(args: List<&2, String>) -> Cli:
  match args:
    case Nil{}:
      CliConf{None{}, False{}, "", True{}}
    case Con{+a, +rest}:
      cli.first(a, rest)

# The configuration
# -----------------
# The configuration as it is read: the parameters; whether a save line was
# read (the first one takes the save points away, the next ones add to
# them, as in Redis); whether a file is being read (after an include, a
# save line takes the points away again, as in Redis); whether io-threads
# was given; the first module to load; and whether a module's parameter
# was given (BendKV has no modules, so either stops the start, as Redis
# stops when it cannot load one).
type Load is Data:
  Load{items: List<&2, C.CItem>, saved: Bool, reading: Bool, io: Bool, mod: String, mcfg: Bool}

def load.new(items: List<&2, C.CItem>) -> Load:
  Load{items, False{}, True{}, False{}, "", False{}}

def load.items(+st: Load) -> List<&2, C.CItem>:
  match st:
    case Load{items, saved, reading, io, mod, mcfg}:
      items

def load.reading(st: Load, r: Bool) -> Load:
  match st:
    case Load{items, saved, reading, io, mod, mcfg}:
      Load{items, saved, r, io, mod, mcfg}

def load.put(st: Load, +name: String, +nv: String) -> Load:
  match st:
    case Load{items, saved, reading, io, mod, mcfg}:
      Load{C.items.put(items, name, nv), saved, reading, Bool.or(io, String.eq(name, "io-threads")), mod, mcfg}

def save.join(+base: String, +nv: String) -> String:
  base ++ Bool.pick(String, Bool.or(String.is_empty(base), String.is_empty(nv)), "", " ") ++ nv

def load.save(st: Load, +empty: Bool, +nv: String) -> Load:
  match st:
    case Load{+items, +saved, +reading, io, mod, mcfg}:
      +base = Bool.pick(String, Bool.or(empty, Bool.or(Bool.not(reading), Bool.not(saved))), "", C.config.get_value(items, "save"))
      Load{C.items.put(items, "save", save.join(base, nv)), Bool.or(saved, reading), reading, io, mod, mcfg}

def load.module(st: Load, +path: String) -> Load:
  match st:
    case Load{items, saved, reading, io, +mod, mcfg}:
      Load{items, saved, reading, io, Bool.pick(String, String.is_empty(mod), path, mod), mcfg}

def load.modcfg(st: Load) -> Load:
  match st:
    case Load{items, saved, reading, io, mod, mcfg}:
      Load{items, saved, reading, io, mod, True{}}

# what a line does: the configuration after it; an error (with the line,
# trimmed); a change of directory (dir), or another file to read
# (include), for the shell, after which the lines go on
type Act is Data:
  AOk{st: Load}
  AErr{err: String, line: String}
  ADir{path: String, st: Load, line: String}
  AInc{path: String, st: Load, line: String}

def act.put(r: Result<&2, &2, String, String>, +name: String, +t: String, st: Load) -> Act:
  match r:
    case Done{nv}:
      AOk{load.put(st, name, nv)}
    case Fail{e}:
      AErr{e, t}

def act.save(r: Result<&2, &2, String, String>, +empty: Bool, +t: String, st: Load) -> Act:
  match r:
    case Done{nv}:
      AOk{load.save(st, empty, nv)}
    case Fail{e}:
      AErr{e, t}

# a parameter of one word; dir changes the directory at once, as Redis's
# does (the paths after it are read from there)
def conf.one.v(dir: Bool, v: String, +it: C.CItem, +t: String, st: Load) -> Act:
  match dir:
    case True{}:
      ADir{v, st, t}
    case False{}:
      act.put(C.item.load(it, [v]), C.item.name(it), t, st)

def conf.one(args: List<&2, String>, +it: C.CItem, +t: String, st: Load) -> Act:
  match args:
    case Con{v, Nil{}}:
      conf.one.v(String.eq(C.item.name(it), "dir"), v, it, t, st)
    case _:
      AErr{"wrong number of arguments", t}

# a parameter of several words: one word that is not empty is split into
# them, so that --save "900 1" is save 900 1
def conf.words.of(m: Maybe<&2, List<&2, String>>) -> List<&2, String>:
  match m:
    case Some{ws}:
      ws
    case None{}:
      Nil{}

def conf.words(args: List<&2, String>) -> List<&2, String>:
  match args:
    case Con{SCon{c, s}, Nil{}}:
      conf.words.of(split(SCon{c, s}))
    case other:
      other

def conf.empty(+ws: List<&2, String>) -> Bool:
  Bool.and(Nat.is_eq(List.length(&2, String, ws), 1n), String.is_empty(first(ws)))

def conf.many.v(save: Bool, +ws: List<&2, String>, +it: C.CItem, +t: String, st: Load) -> Act:
  match save:
    case True{}:
      act.save(C.item.load(it, ws), conf.empty(ws), t, st)
    case False{}:
      act.put(C.item.load(it, ws), C.item.name(it), t, st)

def conf.param(multi: Bool, +it: C.CItem, args: List<&2, String>, +t: String, st: Load) -> Act:
  match multi:
    case False{}:
      conf.one(args, it, t, st)
    case True{}:
      conf.many.v(String.eq(C.item.name(it), "save"), conf.words(args), it, t, st)

def deprecated(+name: String) -> Bool:
  Bool.or(Bool.or(String.eq(name, "list-max-ziplist-entries"), String.eq(name, "list-max-ziplist-value")), String.eq(name, "lua-replicate-commands"))

def text.dot(s: String) -> Bool:
  match s:
    case SNil{}:
      False{}
    case SCon{Chr{+x}, t}:
      Bool.or(U32.is_eq(x, 46), text.dot(t))

# a line that names no parameter: what Redis does with it, by number
def other.kind(+name: String, +argc: Nat) -> Nat:
  Bool.pick(Nat, Bool.and(deprecated(name), Nat.is_eq(argc, 2n)), 1n,
  Bool.pick(Nat, Bool.and(String.eq(name, "include"), Nat.is_eq(argc, 2n)), 2n,
  Bool.pick(Nat, Bool.and(String.eq(name, "rename-command"), Nat.is_eq(argc, 3n)), 3n,
  Bool.pick(Nat, Bool.and(String.eq(name, "user"), Nat.is_le(2n, argc)), 4n,
  Bool.pick(Nat, Bool.and(String.eq(name, "loadmodule"), Nat.is_le(2n, argc)), 5n,
  Bool.pick(Nat, text.dot(name), Bool.pick(Nat, Nat.is_lt(argc, 2n), 6n, 7n),
  Bool.pick(Nat, String.eq(name, "sentinel"), Bool.pick(Nat, Nat.is_eq(argc, 1n), 1n, 8n), 9n)))))))

def conf.other(k: Nat, args: List<&2, String>, +t: String, st: Load) -> Act:
  match k:
    case 1n:
      AOk{st}
    case 2n:
      AInc{first(args), st, t}
    case 3n:
      AErr{"BendKV cannot rename commands yet", t}
    case 4n:
      AErr{"BendKV has no ACL users yet", t}
    case 5n:
      AOk{load.module(st, first(args))}
    case 6n:
      AErr{"Module config specified without value", t}
    case 7n:
      AOk{load.modcfg(st)}
    case 8n:
      AErr{"sentinel directive while not in sentinel mode", t}
    case _:
      AErr{"Bad directive or wrong number of arguments", t}

def conf.cmd.of(f: Maybe<&2, C.CItem>, +name: String, +args: List<&2, String>, +t: String, st: Load) -> Act:
  match f:
    case Some{+it}:
      conf.param(C.item.multi(it), it, args, t, st)
    case None{}:
      conf.other(other.kind(name, 1n+List.length(&2, String, args)), args, t, st)

def conf.cmd(+name: String, +args: List<&2, String>, +t: String, +st: Load) -> Act:
  conf.cmd.of(C.item.find(load.items(st), name), name, args, t, st)

def conf.split(m: Maybe<&2, List<&2, String>>, +t: String, st: Load) -> Act:
  match m:
    case None{}:
      AErr{"Unbalanced quotes in configuration line", t}
    case Some{Nil{}}:
      AOk{st}
    case Some{Con{w, args}}:
      conf.cmd(String.to_lower(w), args, t, st)

def conf.skip(+t: String) -> Bool:
  Bool.or(String.is_empty(t), U32.is_eq(String.code_at(t, 0n), 35))

def conf.line.t(skip: Bool, +t: String, st: Load) -> Act:
  match skip:
    case True{}:
      AOk{st}
    case False{}:
      conf.split(split(t), t, st)

# a line: trimmed; a comment or a blank line is skipped
def conf.line(l: String, st: Load) -> Act:
  +t = trim(l)
  conf.line.t(conf.skip(t), t, st)

# where the lines stop: at their end, at an error (its line's number, the
# line, the error), or at a dir or an include, with the lines after it
type Next is Data:
  NEnd{st: Load}
  NErr{n: Nat, line: String, err: String}
  NDir{n: Nat, line: String, path: String, st: Load, rest: List<&2, String>}
  NInc{n: Nat, line: String, path: String, st: Load, rest: List<&2, String>}

# the lines after line n, a being what line n did
def conf.go(lines: List<&2, String>, a: Act, +n: Nat) -> Next:
  match lines a:
    case Nil{} AOk{st}:
      NEnd{st}
    case Con{l, rest} AOk{st}:
      conf.go(rest, conf.line(l, st), 1n+n)
    case ls AErr{e, t}:
      NErr{n, t, e}
    case ls ADir{p, st, t}:
      NDir{n, t, p, st, ls}
    case ls AInc{p, st, t}:
      NInc{n, t, p, st, ls}

# an include by a pattern, which Redis expands as glob does
def conf.glob(s: String) -> Bool:
  match s:
    case SNil{}:
      False{}
    case SCon{Chr{+x}, t}:
      Bool.or(Bool.or(U32.is_eq(x, 42), U32.is_eq(x, 63)), Bool.or(U32.is_eq(x, 91), conf.glob(t)))

# a file's lines, from the first
def conf.lines(text: String) -> List<&2, String>:
  String.split(text, '\n')

def conf.start(text: String, st: Load) -> Next:
  conf.go(conf.lines(text), AOk{load.reading(st, True{})}, 0n)

# after line n, on to the lines left
def conf.resume(rest: List<&2, String>, st: Load, +n: Nat) -> Next:
  conf.go(rest, AOk{st}, n)

# the checks at the end of a file, after the log file's: replication is
# not for a cluster
def conf.end(+st: Load) -> Maybe<&2, String>:
  Bool.pick(Maybe<&2, String>, Bool.and(String.eq(C.config.get_value(load.items(st), "cluster-enabled"), "yes"), Bool.not(String.is_empty(C.config.get_value(load.items(st), "replicaof")))),
    Some{"replicaof directive not allowed in cluster mode"}, None{})

# Redis's report of an error in the configuration, with the line when
# there is one
def fatal.head() -> String:
  "\n*** FATAL CONFIG FILE ERROR (BendKV " ++ version() ++ ") ***\n"

def fatal(+n: Nat, +line: String, +err: String) -> String:
  fatal.head() ++ "Reading the configuration file, at line " ++ Nat.show(n) ++ "\n>>> '" ++ line ++ "'\n" ++ err

def fatal.end(+err: String) -> String:
  fatal.head() ++ err

# The log
# -------
# Redis's lines: "pid:role date level message", the date in UTC (Redis
# writes its local time), the level a char: '.' debug, '-' verbose, '*'
# notice, '#' warning; a line under loglevel is not written.

type Ymd is Data:
  Ymd{y: U32, m: U32, d: U32}

# the date of a day since 1970-01-01 (Howard Hinnant's civil_from_days)
def civil.fin(+y: U32, +mp: U32, +d: U32) -> Ymd:
  +m = Bool.pick(U32, U32.is_lt(mp, 10), U32.add(mp, 3), U32.sub(mp, 9))
  Ymd{U32.add(y, Bool.pick(U32, U32.is_le(m, 2), 1, 0)), m, d}

def civil.doy(+y: U32, +doy: U32) -> Ymd:
  +mp = U32.div(U32.add(U32.mul(5, doy), 2), 153)
  civil.fin(y, mp, U32.add(U32.sub(doy, U32.div(U32.add(U32.mul(153, mp), 2), 5)), 1))

def civil.doe(+era: U32, +doe: U32) -> Ymd:
  +yoe = U32.div(U32.sub(U32.sub(U32.add(doe, U32.div(doe, 36524)), U32.div(doe, 1460)), U32.div(doe, 146096)), 365)
  civil.doy(U32.add(yoe, U32.mul(era, 400)), U32.sub(doe, U32.sub(U32.add(U32.mul(365, yoe), U32.div(yoe, 4)), U32.div(yoe, 100))))

def civil(+days: U32) -> Ymd:
  +z = U32.add(days, 719468)
  +era = U32.div(z, 146097)
  civil.doe(era, U32.sub(z, U32.mul(era, 146097)))

def pad2(+x: U32) -> String:
  Bool.pick(String, U32.is_lt(x, 10), "0", "") ++ U32.show(x)

def pad3(+x: U32) -> String:
  Bool.pick(String, U32.is_lt(x, 10), "00", Bool.pick(String, U32.is_lt(x, 100), "0", "")) ++ U32.show(x)

def month(+m: U32) -> String:
  Bool.pick(String, U32.is_eq(m, 1), "Jan", Bool.pick(String, U32.is_eq(m, 2), "Feb",
  Bool.pick(String, U32.is_eq(m, 3), "Mar", Bool.pick(String, U32.is_eq(m, 4), "Apr",
  Bool.pick(String, U32.is_eq(m, 5), "May", Bool.pick(String, U32.is_eq(m, 6), "Jun",
  Bool.pick(String, U32.is_eq(m, 7), "Jul", Bool.pick(String, U32.is_eq(m, 8), "Aug",
  Bool.pick(String, U32.is_eq(m, 9), "Sep", Bool.pick(String, U32.is_eq(m, 10), "Oct",
  Bool.pick(String, U32.is_eq(m, 11), "Nov", "Dec")))))))))))

def date.ymd(d: Ymd, +secs: U32, +us: U32) -> String:
  match d:
    case Ymd{+y, +m, +day}:
      +t = U32.mod(secs, 86400)
      pad2(day) ++ " " ++ month(m) ++ " " ++ U32.show(y) ++ " " ++ pad2(U32.div(t, 3600)) ++ ":" ++ pad2(U32.mod(U32.div(t, 60), 60)) ++ ":" ++ pad2(U32.mod(t, 60)) ++ "." ++ pad3(U32.div(us, 1000))

# "%d %b %Y %H:%M:%S.%03d", from seconds and microseconds since 1970
def date(+secs: U32, +us: U32) -> String:
  date.ymd(civil(U32.div(secs, 86400)), secs, us)

def log.char(+level: U32) -> String:
  Bool.pick(String, U32.is_eq(level, 0), ".", Bool.pick(String, U32.is_eq(level, 1), "-", Bool.pick(String, U32.is_eq(level, 2), "*", "#")))

# loglevel's value as a level
def log.level(+v: String) -> U32:
  Bool.pick(U32, String.eq(v, "debug"), 0, Bool.pick(U32, String.eq(v, "verbose"), 1, Bool.pick(U32, String.eq(v, "warning"), 3, 2)))

# role: 'C' before the server is up (Redis's pid is not yet set then), 'M'
# after
def log.line(+pid: U32, +role: String, +secs: U32, +us: U32, +level: U32, +msg: String) -> String:
  U32.show(pid) ++ ":" ++ role ++ " " ++ date(secs, us) ++ " " ++ log.char(level) ++ " " ++ msg

# The start
# ---------
# What the configuration asks that BendKV cannot do stops the start, with
# a line in the log (as Redis stops when it cannot do what it is asked);
# what BendKV keeps but does nothing with is said in the log once.

def cfg(+items: List<&2, C.CItem>, +name: String) -> String:
  C.config.get_value(items, name)

# how the server is supervised, as Redis's redisIsSupervised finds it (the
# mode asked, and whether UPSTART_JOB and NOTIFY_SOCKET are set): 0 not
# supervised, 1 by upstart, 2 by systemd; 3 and 4 when upstart or systemd
# was asked but its variable is not set (a warning, and not supervised)
def sup.kind(+mode: String, +upstart: Bool, +systemd: Bool) -> Nat:
  +m = Bool.pick(String, String.eq(mode, "auto"), Bool.pick(String, upstart, "upstart", Bool.pick(String, systemd, "systemd", "no")), mode)
  Bool.pick(Nat, String.eq(m, "upstart"), Bool.pick(Nat, upstart, 1n, 3n),
    Bool.pick(Nat, String.eq(m, "systemd"), Bool.pick(Nat, systemd, 2n, 4n), 0n))

# BendKV can neither stop itself to signal upstart nor notify systemd
def sup.msg(+k: Nat) -> String:
  Bool.pick(String, Nat.is_eq(k, 1n), "supervised by upstart, which BendKV cannot signal (it cannot stop itself): run it unsupervised",
  Bool.pick(String, Nat.is_eq(k, 2n), "supervised by systemd, which BendKV cannot notify (READY=1): run it as a Type=simple service with supervised no",
  Bool.pick(String, Nat.is_eq(k, 3n), "upstart supervision requested, but UPSTART_JOB not found!",
  Bool.pick(String, Nat.is_eq(k, 4n), "systemd supervision requested or auto-detected, but NOTIFY_SOCKET not found!", ""))))

# what stops the start, the first of it (given whether the server is
# supervised)
def refusal(+items: List<&2, C.CItem>, +sup: Bool) -> String:
  Bool.pick(String, Bool.and(String.eq(cfg(items, "daemonize"), "yes"), Bool.not(sup)), "BendKV cannot run in the background (daemonize yes): run it in the foreground, or under a supervisor",
  Bool.pick(String, String.eq(cfg(items, "cluster-enabled"), "yes"), "BendKV has no cluster mode: set cluster-enabled no",
  Bool.pick(String, Bool.not(String.is_empty(cfg(items, "replicaof"))), "BendKV cannot be a replica: replicaof must be no one",
  Bool.pick(String, Bool.not(String.eq(cfg(items, "tls-port"), "0")), "BendKV has no TLS: set tls-port 0", ""))))

def warn.if(c: Bool, +w: String, ws: List<&2, String>) -> List<&2, String>:
  match c:
    case True{}:
      w <> ws
    case False{}:
      ws

# what BendKV keeps and does nothing with
def warnings(+items: List<&2, C.CItem>) -> List<&2, String>:
  warn.if(Bool.not(String.eq(cfg(items, "databases"), "1")), "BendKV keeps one database: databases " ++ cfg(items, "databases") ++ " is taken as 1",
  warn.if(Bool.not(String.is_empty(cfg(items, "save"))), "BendKV writes no RDB snapshots: save is kept but saves nothing (appendonly yes keeps the data)",
  warn.if(Bool.not(String.eq(cfg(items, "maxmemory"), "0")), "BendKV has no eviction: maxmemory is kept but limits nothing",
  warn.if(Bool.not(String.is_empty(cfg(items, "unixsocket"))), "BendKV listens on TCP only: unixsocket " ++ cfg(items, "unixsocket") ++ " is ignored",
  warn.if(String.eq(cfg(items, "syslog-enabled"), "yes"), "BendKV does not log to syslog", Nil{})))))

# The addresses
# -------------
# bind's addresses, as Redis's listenToPort takes them: a '-' in front
# makes one optional; "*" is every IPv4 address. BendKV listens on IPv4
# only, so an IPv6 address is let go, as Redis lets one go on a host
# without IPv6. In protected mode with no password, Redis takes only
# clients on the loopback; BendKV cannot tell where a client is, so it
# listens on the loopback only (127.0.0.1 for 0.0.0.0, no other address).
# An address: the host to listen on ("" for none), the name Redis gives
# it in its messages, and a warning to log ("" for none).
type Addr is Data:
  Addr{host: String, name: String, warn: String}

def text.has_colon(s: String) -> Bool:
  match s:
    case SNil{}:
      False{}
    case SCon{Chr{+x}, t}:
      Bool.or(U32.is_eq(x, 58), text.has_colon(t))

def addr.of(+a: String, +port: String, +prot: Bool) -> Addr:
  +host = Bool.pick(String, String.eq(a, "*"), "0.0.0.0", Bool.pick(String, String.eq(a, "localhost"), "127.0.0.1", a))
  +lo = String.starts_with(host, "127.")
  Bool.pick(Addr, text.has_colon(a), Addr{"", a, "Warning: Could not create server TCP listening socket " ++ a ++ ":" ++ port ++ ": BendKV listens on IPv4 only"},
    Bool.pick(Addr, Bool.or(Bool.not(prot), lo), Addr{host, a, ""},
      Bool.pick(Addr, String.eq(host, "0.0.0.0"), Addr{"127.0.0.1", a, "Protected mode with no password: BendKV cannot tell local clients from remote ones, so it listens on 127.0.0.1 for " ++ a},
        Addr{"", a, "Protected mode with no password: BendKV cannot tell local clients from remote ones, so it does not listen on " ++ a})))

def addr.opt(w: String) -> String:
  match w:
    case SCon{'-', t}:
      t
    case other:
      other

def addrs.go(ws: List<&2, String>, +port: String, +prot: Bool) -> List<&2, Addr>:
  match ws:
    case Nil{}:
      Nil{}
    case Con{w, rest}:
      addr.of(addr.opt(w), port, prot) <> addrs.go(rest, port, prot)

def addrs(+items: List<&2, C.CItem>) -> List<&2, Addr>:
  addrs.go(C.words(cfg(items, "bind")), cfg(items, "port"), Bool.and(String.eq(cfg(items, "protected-mode"), "yes"), String.is_empty(cfg(items, "requirepass"))))

# the errors of listen that let an address go, as in Redis: ENOPROTOOPT,
# EPROTONOSUPPORT, ESOCKTNOSUPPORT, EPFNOSUPPORT, EAFNOSUPPORT and
# EADDRNOTAVAIL
def listen.skip(+code: U32) -> Bool:
  Bool.or(Bool.or(Bool.or(U32.is_eq(code, 92), U32.is_eq(code, 93)), Bool.or(U32.is_eq(code, 94), U32.is_eq(code, 96))), Bool.or(U32.is_eq(code, 97), U32.is_eq(code, 99)))

# The logo, shown with always-show-logo yes: Redis's has its version, its
# mode, its port and its pid
def logo(+port: String, +pid: U32) -> String:
  "\n" ++
  "                BendKV " ++ version() ++ " (Redis 7.0.15 commands) 64 bit\n" ++
  "                Running in standalone mode\n" ++
  "                Port: " ++ port ++ "\n" ++
  "                PID: " ++ U32.show(pid) ++ "\n"
