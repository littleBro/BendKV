# aofdir.bend: Redis 7's multi-part append-only file, its manifest read
# and written as redis-server 7.0.15 reads and writes it (aof.c:
# aofLoadManifestFromFile, getAofManifestAsString, and the names its
# rewrites give the files). Pure: the shell (server.bend: The append-only
# directory) reads and writes the files, and logs what this says. Tested
# against redis-server (tests/aofdir_test.py), not proved.
#
# The directory, appenddirname in dir, holds a manifest,
# <appendfilename>.manifest, a line per file:
#
#   file appendonly.aof.2.base.rdb seq 2 type b
#   file appendonly.aof.1.incr.aof seq 1 type h
#   file appendonly.aof.2.incr.aof seq 2 type i
#
# the base (at most one: the databases as a rewrite wrote them, as an RDB
# file or as commands), the history files (what a rewrite left, to be
# deleted), and the incremental files (the commands since, in order).

import Base
import ./startup.bend as T

# a file of the manifest: its name, its sequence number, and its type as
# the manifest writes it ('b' base, 'h' history, 'i' incremental: the
# byte)
type MFile is Data:
  MFile{name: String, seq: Nat, kind: U32}

# the manifest: its base, its history files and its incremental files,
# each list in the manifest's order, and the sequence numbers of the last
# base and of the last incremental file (Redis's curr_base_file_seq and
# curr_incr_file_seq)
type Mf is Data:
  Mf{base: Maybe<&2, MFile>, hist: List<&2, MFile>, incr: List<&2, MFile>, bseq: Nat, iseq: Nat}

def mf.empty() -> Mf:
  Mf{None{}, Nil{}, Nil{}, 0n, 0n}

# Reading
# -------
# Redis reads the manifest a line at a time with fgets into a buffer of
# 1,025 bytes: up to 1,024 bytes, through the first '\n'. A line that
# starts with '#' is skipped; one that holds no '\n' is too long (the
# last line of a file that does not end in one too). The rest of a line,
# trimmed, is split as sdssplitargs splits it, into pairs of a key (file,
# seq or type, in any case; others are let go) and its value. A file's
# name is a name, not a path; its sequence number is atoll's reading of
# its value, and 0 is none; its type is its value's first byte.

# the length of the line at the start of s, and whether it ends in '\n'
def chunk.len(s: String, +n: Nat, +i: Nat) -> Nat:
  match s n:
    case SNil{} _:
      i
    case SCon{x, t} 0n:
      i
    case SCon{Chr{+x}, t} 1n+k:
      Bool.pick(Nat, U32.is_eq(x, 10), 1n+i, chunk.len(t, k, 1n+i))

def chunk.nl(s: String, +n: Nat) -> Bool:
  match s n:
    case SNil{} _:
      False{}
    case SCon{x, t} 0n:
      False{}
    case SCon{Chr{+x}, t} 1n+k:
      Bool.or(U32.is_eq(x, 10), chunk.nl(t, k))

# the C locale's isspace: ' ', '\t', '\n', '\v', '\f', '\r'
def space(+x: U32) -> Bool:
  Bool.or(U32.is_eq(x, 32), Bool.and(U32.is_le(9, x), U32.is_le(x, 13)))

def spaces(s: String, +i: Nat) -> Nat:
  match s:
    case SNil{}:
      i
    case SCon{Chr{+x}, t}:
      Bool.pick(Nat, space(x), spaces(t, 1n+i), i)

# A sequence number as atoll reads it: none (0), below 0, past what
# BendKV takes (10^13 and more: a Nat stays far below 2^48), or a number
type MSeq is Data:
  SeqNone{}
  SeqNeg{}
  SeqBig{}
  SeqAt{n: Nat}

# 10^12 and 10^13 (a literal stays below 2^32)
def seq.lim() -> Nat:
  Nat.mul(1000000n, 1000000n)

def seq.cap() -> Nat:
  Nat.mul(10000000n, 1000000n)

def seq.at(+n: Nat) -> MSeq:
  Bool.pick(MSeq, Nat.is_eq(n, 0n), SeqNone{}, Bool.pick(MSeq, Nat.is_lt(n, seq.cap()), SeqAt{n}, SeqBig{}))

# the digits from s on, read into acc (10^13 once past 10^12: no step
# makes a Nat past 10^14)
def seq.digits(s: String, +acc: Nat) -> Nat:
  match s:
    case SNil{}:
      acc
    case SCon{Chr{+x}, t}:
      Bool.pick(Nat, Bool.and(U32.is_le(48, x), U32.is_le(x, 57)),
        seq.digits(t, Bool.pick(Nat, Nat.is_lt(acc, seq.lim()), Nat.add(Nat.mul(acc, 10n), U32.to_nat(U32.sub(x, 48))), seq.cap())),
        acc)

def seq.neg(+n: Nat) -> MSeq:
  Bool.pick(MSeq, Nat.is_eq(n, 0n), SeqNone{}, SeqNeg{})

def seq.signed(s: String) -> MSeq:
  match s:
    case SNil{}:
      SeqNone{}
    case SCon{Chr{+x}, +t}:
      Bool.pick(MSeq, U32.is_eq(x, 45), seq.neg(seq.digits(t, 0n)),
        Bool.pick(MSeq, U32.is_eq(x, 43), seq.at(seq.digits(t, 0n)), seq.at(seq.digits(SCon{Chr{x}, t}, 0n))))

def seq.of(+s: String) -> MSeq:
  seq.signed(String.drop(s, spaces(s, 0n)))

# whether a name is a name alone (pathIsBaseName: no '/', no '\\')
def base.name(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{Chr{+x}, t}:
      Bool.and(Bool.not(Bool.or(U32.is_eq(x, 47), U32.is_eq(x, 92))), base.name(t))

def first.byte(s: String) -> U32:
  match s:
    case SNil{}:
      0
    case SCon{Chr{+x}, t}:
      x

# a line's fields so far: its name, sequence number and type (0: none),
# or a name that is a path (which stops the line at once)
type MFields is Data:
  MFGot{name: Maybe<&2, String>, seq: MSeq, kind: U32}
  MFPath{}

def field.file(ok: Bool, +v: String, seq: MSeq, +kind: U32) -> MFields:
  match ok:
    case True{}:
      MFGot{Some{v}, seq, kind}
    case False{}:
      MFPath{}

def field.at(+key: Nat, +v: String, name: Maybe<&2, String>, seq: MSeq, +kind: U32) -> MFields:
  match key:
    case 1n:
      field.file(base.name(v), v, seq, kind)
    case 2n:
      MFGot{name, seq.of(v), kind}
    case 3n:
      MFGot{name, seq, first.byte(v)}
    case _:
      MFGot{name, seq, kind}

def field.key(+k: String) -> Nat:
  +l = String.to_lower(k)
  Bool.pick(Nat, String.eq(l, "file"), 1n, Bool.pick(Nat, String.eq(l, "seq"), 2n, Bool.pick(Nat, String.eq(l, "type"), 3n, 0n)))

def fields(ws: List<&2, String>, f: MFields) -> MFields:
  match ws f:
    case Con{k, Con{v, rest}} MFGot{name, seq, kind}:
      fields(rest, field.at(field.key(k), v, name, seq, kind))
    case _ g:
      g

# The manifest so far, with the greatest sequence number of its
# incremental files (each must pass the one before it); or why it stops
# the start: the line's number, the line (trimmed) when Redis logs it, and
# what is wrong
type MRead is Data:
  MOk{mf: Mf, max: Nat}
  MBad{num: Nat, line: Maybe<&2, String>, msg: String}

def bad.form(+num: Nat, +line: String) -> MRead:
  MBad{num, Some{line}, "Invalid AOF manifest file format"}

def mf.base.got(had: Bool, +name: String, +n: Nat, +line: String, +num: Nat, mf: Mf, +max: Nat) -> MRead:
  match had mf:
    case True{} _:
      MBad{num, Some{line}, "Found duplicate base file information"}
    case False{} Mf{base, hist, incr, bseq, iseq}:
      MOk{Mf{Some{MFile{name, n, 98}}, hist, incr, n, iseq}, max}

def mf.hist.got(+name: String, +n: Nat, mf: Mf, +max: Nat) -> MRead:
  match mf:
    case Mf{base, hist, incr, bseq, iseq}:
      MOk{Mf{base, List.append(&2, MFile, hist, [MFile{name, n, 104}]), incr, bseq, iseq}, max}

def mf.incr.got(more: Bool, +name: String, +n: Nat, +line: String, +num: Nat, mf: Mf, +max: Nat) -> MRead:
  match more mf:
    case False{} _:
      MBad{num, Some{line}, "Found a non-monotonic sequence number"}
    case True{} Mf{base, hist, incr, bseq, iseq}:
      MOk{Mf{base, hist, List.append(&2, MFile, incr, [MFile{name, n, 105}]), bseq, n}, n}

def mf.has.base(+mf: Mf) -> Bool:
  match mf:
    case Mf{+base, hist, incr, bseq, iseq}:
      Maybe.is_some(&2, MFile, base)

# a line of type kind, name and sequence number seq: a base, a history
# file or an incremental file; Redis takes a sequence number below 1 for
# a base or a history file, and any for an incremental file past the one
# before it; BendKV refuses these as a line of a bad format (none of
# Redis's own manifests holds one)
def mf.kind(+kind: U32, +name: String, seq: MSeq, +line: String, +num: Nat, +mf: Mf, +max: Nat) -> MRead:
  match seq:
    case SeqAt{+n}:
      Bool.pick(MRead, U32.is_eq(kind, 98), mf.base.got(mf.has.base(mf), name, n, line, num, mf, max),
        Bool.pick(MRead, U32.is_eq(kind, 104), mf.hist.got(name, n, mf, max),
          Bool.pick(MRead, U32.is_eq(kind, 105), mf.incr.got(Nat.is_lt(max, n), name, n, line, num, mf, max),
            MBad{num, Some{line}, "Unknown AOF file type"})))
    case SeqNeg{}:
      Bool.pick(MRead, U32.is_eq(kind, 105), MBad{num, Some{line}, "Found a non-monotonic sequence number"},
        Bool.pick(MRead, Bool.or(U32.is_eq(kind, 98), U32.is_eq(kind, 104)), bad.form(num, line), MBad{num, Some{line}, "Unknown AOF file type"}))
    case _:
      Bool.pick(MRead, Bool.or(U32.is_eq(kind, 98), Bool.or(U32.is_eq(kind, 104), U32.is_eq(kind, 105))), bad.form(num, line), MBad{num, Some{line}, "Unknown AOF file type"})

def mf.named(name: Maybe<&2, String>, seq: MSeq, +kind: U32, +line: String, +num: Nat, mf: Mf, +max: Nat) -> MRead:
  match name seq:
    case None{} _:
      bad.form(num, line)
    case Some{n} SeqNone{}:
      bad.form(num, line)
    case Some{+n} q:
      Bool.pick(MRead, U32.is_eq(kind, 0), bad.form(num, line), mf.kind(kind, n, q, line, num, mf, max))

def mf.fields(f: MFields, +line: String, +num: Nat, mf: Mf, +max: Nat) -> MRead:
  match f:
    case MFPath{}:
      MBad{num, Some{line}, "File can't be a path, just a filename"}
    case MFGot{name, seq, +kind}:
      mf.named(name, seq, kind, line, num, mf, max)

def mf.pairs(bad: Bool, ws: List<&2, String>, +line: String, +num: Nat, mf: Mf, +max: Nat) -> MRead:
  match bad:
    case True{}:
      bad.form(num, line)
    case False{}:
      mf.fields(fields(ws, MFGot{None{}, SeqNone{}, 0}), line, num, mf, max)

# a line trimmed (sdstrim's blanks) and split; with fewer than six words,
# or an odd number of them (or a quote left open), it is of a bad format
def mf.words(m: Maybe<&2, List<&2, String>>, +line: String, +num: Nat, mf: Mf, +max: Nat) -> MRead:
  match m:
    case None{}:
      bad.form(num, line)
    case Some{+ws}:
      +n = List.length(&2, String, ws)
      mf.pairs(Bool.or(Nat.is_lt(n, 6n), Nat.is_eq(Nat.mod(n, 2n), 1n)), ws, line, num, mf, max)

# a line read (what: 0 nothing, at the file's end, or a comment; 1 too
# long; 2 a line to read)
def mf.line.at(+what: Nat, +s: String, +num: Nat, mf: Mf, +max: Nat) -> MRead:
  match what:
    case 0n:
      MOk{mf, max}
    case 1n:
      MBad{num, None{}, "The AOF manifest file contains too long line"}
    case _:
      +line = T.trim(s)
      mf.words(T.split(line), line, num, mf, max)

def mf.line(+s: String, +nl: Bool, +num: Nat, r: MRead) -> MRead:
  match r:
    case MOk{mf, +max}:
      mf.line.at(Bool.pick(Nat, Bool.or(String.is_empty(s), String.starts_with(s, "#")), 0n, Bool.pick(Nat, nl, 2n, 1n)), s, num, mf, max)
    case MBad{n, l, m}:
      MBad{n, l, m}

# the lines from s on, the next of number num (fuel: one step for each
# byte, as each line takes one at least; the steps past the file's end
# read nothing)
def mf.lines(fuel: Nat, +s: String, +num: Nat, r: MRead) -> MRead:
  match fuel:
    case 0n:
      r
    case 1n+f:
      +k = chunk.len(s, 1024n, 0n)
      mf.lines(f, String.drop(s, k), 1n+num, mf.line(String.take(s, k), chunk.nl(s, 1024n), num, r))

# the manifest as Redis reads it from the file's bytes s
def mf.read(+s: String) -> MRead:
  Bool.pick(MRead, String.is_empty(s), MBad{0n, None{}, "Found an empty AOF manifest"}, mf.lines(1n+String.length(s), s, 1n, MOk{mf.empty(), 0n}))

# the lines Redis logs when its manifest stops the start (each a line of
# the log, as Redis writes them, with their '\n's)
def mf.bad.lines(+num: Nat, line: Maybe<&2, String>, +msg: String) -> List<&2, String>:
  match line:
    case Some{l}:
      ["\n*** FATAL AOF MANIFEST FILE ERROR ***\n", "Reading the manifest file, at line " ++ Nat.show(num) ++ "\n", ">>> '" ++ l ++ "'\n", msg ++ "\n"]
    case None{}:
      ["\n*** FATAL AOF MANIFEST FILE ERROR ***\n", msg ++ "\n"]

# Writing
# -------
# The manifest as Redis writes it: the base, then the history files, then
# the incremental files, a line each, the name quoted (sdscatrepr) when
# it holds a byte that sdsneedsrepr marks: '\\', '"', a blank, or one
# that does not print.

def needs.repr(s: String) -> Bool:
  match s:
    case SNil{}:
      False{}
    case SCon{Chr{+x}, t}:
      Bool.or(Bool.or(Bool.or(U32.is_lt(x, 33), U32.is_lt(126, x)), Bool.or(U32.is_eq(x, 92), U32.is_eq(x, 34))), needs.repr(t))

def mfile.line(f: MFile) -> String:
  match f:
    case MFile{+name, +seq, +kind}:
      "file " ++ Bool.pick(String, needs.repr(name), T.repr(name), name) ++ " seq " ++ Nat.show(seq) ++ " type " ++ SCon{Chr{kind}, SNil{}} ++ "\n"

def mfile.lines(fs: List<&2, MFile>) -> String:
  match fs:
    case Nil{}:
      ""
    case Con{f, rest}:
      mfile.line(f) ++ mfile.lines(rest)

def mf.base.line(m: Maybe<&2, MFile>) -> String:
  match m:
    case Some{f}:
      mfile.line(f)
    case None{}:
      ""

def mf.text(mf: Mf) -> String:
  match mf:
    case Mf{base, hist, incr, bseq, iseq}:
      mf.base.line(base) ++ mfile.lines(hist) ++ mfile.lines(incr)

# The files
# ---------

def mfile.name(+f: MFile) -> String:
  match f:
    case MFile{+name, seq, kind}:
      name

def mfile.names(+fs: List<&2, MFile>) -> List<&2, String>:
  match fs:
    case Nil{}:
      Nil{}
    case Con{+f, +rest}:
      mfile.name(f) <> mfile.names(rest)

# the files a start loads, in order: the base, then the incremental files
type MLoad is Data:
  MLoad{name: String, base: Bool}

def mf.loads.base(+m: Maybe<&2, MFile>) -> List<&2, MLoad>:
  match m:
    case Some{+f}:
      [MLoad{mfile.name(f), True{}}]
    case None{}:
      Nil{}

def mf.loads.incr(ns: List<&2, String>) -> List<&2, MLoad>:
  match ns:
    case Nil{}:
      Nil{}
    case Con{n, rest}:
      MLoad{n, False{}} <> mf.loads.incr(rest)

def mf.loads(+mf: Mf) -> List<&2, MLoad>:
  match mf:
    case Mf{+base, hist, +incr, bseq, iseq}:
      List.append(&2, MLoad, mf.loads.base(base), mf.loads.incr(mfile.names(incr)))

def mf.hist.names(+mf: Mf) -> List<&2, String>:
  match mf:
    case Mf{base, +hist, incr, bseq, iseq}:
      mfile.names(hist)

def mf.incr.names(+mf: Mf) -> List<&2, String>:
  match mf:
    case Mf{base, hist, +incr, bseq, iseq}:
      mfile.names(incr)

def mf.base.name.of(+m: Maybe<&2, MFile>) -> Maybe<&2, String>:
  match m:
    case Some{+f}:
      Some{mfile.name(f)}
    case None{}:
      None{}

def mf.base.of(+mf: Mf) -> Maybe<&2, String>:
  match mf:
    case Mf{+base, hist, incr, bseq, iseq}:
      mf.base.name.of(base)

# whether the manifest names a base or an incremental file
def mf.any(+mf: Mf) -> Bool:
  match mf:
    case Mf{+base, hist, +incr, bseq, iseq}:
      Bool.or(Maybe.is_some(&2, MFile, base), Bool.not(List.is_empty(&2, MFile, incr)))

def mf.upgrade.base(+m: Maybe<&2, MFile>, +name: String, +there: Bool) -> Bool:
  match m:
    case None{}:
      True{}
    case Some{+f}:
      Bool.and(String.eq(mfile.name(f), name), Bool.not(there))

# whether a start upgrades an old single file, name, there in dir
# (loadAppendOnlyFiles, the directory there): when the manifest names no
# base and no incremental file, or names only a base, of that name, which
# the directory does not hold (an upgrade that stopped half way)
def mf.upgrade.when(+mf: Mf, +name: String, +there: Bool) -> Bool:
  match mf:
    case Mf{+base, hist, +incr, bseq, iseq}:
      Bool.and(List.is_empty(&2, MFile, incr), mf.upgrade.base(base, name, there))

# the manifest after the upgrade (aofUpgradePrepare): the old file its base,
# of sequence number 1
def mf.upgraded(mf: Mf, +name: String) -> Mf:
  match mf:
    case Mf{base, hist, incr, bseq, iseq}:
      Mf{Some{MFile{name, 1n, 98}}, hist, incr, 1n, iseq}

def mf.base.file(+name: String, +seq: Nat, +rdb: Bool) -> String:
  name ++ "." ++ Nat.show(seq) ++ ".base" ++ Bool.pick(String, rdb, ".rdb", ".aof")

def mf.incr.file(+name: String, +seq: Nat) -> String:
  name ++ "." ++ Nat.show(seq) ++ ".incr.aof"

def hist.with(m: Maybe<&2, MFile>, hist: List<&2, MFile>) -> List<&2, MFile>:
  match m:
    case Some{MFile{n, s, k}}:
      MFile{n, s, 104} <> hist
    case None{}:
      hist

# a new base, of the next sequence number, named for its format (rdb: an
# RDB file); the base before it, if any, the first of the history
# (getNewBaseFileNameAndMarkPreAsHistory)
def mf.base.new(mf: Mf, +name: String, +rdb: Bool) -> Mf:
  match mf:
    case Mf{base, hist, incr, +bseq, iseq}:
      Mf{Some{MFile{mf.base.file(name, 1n+bseq, rdb), 1n+bseq, 98}}, hist.with(base, hist), incr, 1n+bseq, iseq}

# a new incremental file, the last (getNewIncrAofName)
def mf.incr.new(mf: Mf, +name: String) -> Mf:
  match mf:
    case Mf{base, hist, incr, bseq, +iseq}:
      Mf{base, hist, List.append(&2, MFile, incr, [MFile{mf.incr.file(name, 1n+iseq), 1n+iseq, 105}]), bseq, 1n+iseq}

# the last incremental file's name (the one a server appends to), none
# for a manifest that names none
def mf.incr.last(+mf: Mf) -> Maybe<&2, String>:
  match mf:
    case Mf{base, hist, +incr, bseq, iseq}:
      List.last(&2, String, mfile.names(incr))

def name.or(m: Maybe<&2, String>) -> String:
  match m:
    case Some{n}:
      n
    case None{}:
      ""

def mf.incr.at(+mf: Mf) -> String:
  name.or(mf.incr.last(mf))

# the base's name ("" for none)
def mf.base.at(+mf: Mf) -> String:
  name.or(mf.base.of(mf))

def as.hist(fs: List<&2, MFile>) -> List<&2, MFile>:
  match fs:
    case Nil{}:
      Nil{}
    case Con{MFile{n, s, k}, rest}:
      MFile{n, s, 104} <> as.hist(rest)

# a list less its last, and its last alone
def but.last(fs: List<&2, MFile>) -> List<&2, MFile>:
  match fs:
    case Nil{}:
      Nil{}
    case Con{f, Nil{}}:
      Nil{}
    case Con{f, rest}:
      f <> but.last(rest)

def last.only(fs: List<&2, MFile>) -> List<&2, MFile>:
  match fs:
    case Nil{}:
      Nil{}
    case Con{f, Nil{}}:
      [f]
    case Con{f, rest}:
      last.only(rest)

# after a rewrite (markRewrittenIncrAofAsHistory): the incremental files
# made history, in order, before the history there was, but the last
# when on (the server appends to it: appendonly yes)
def mark.hist(on: Bool, +incr: List<&2, MFile>, hist: List<&2, MFile>) -> List<&2, MFile>:
  match on:
    case True{}:
      List.append(&2, MFile, as.hist(but.last(incr)), hist)
    case False{}:
      List.append(&2, MFile, as.hist(incr), hist)

def mark.incr(on: Bool, +incr: List<&2, MFile>) -> List<&2, MFile>:
  match on:
    case True{}:
      last.only(incr)
    case False{}:
      Nil{}

def mf.mark(mf: Mf, +on: Bool) -> Mf:
  match mf:
    case Mf{base, hist, +incr, bseq, iseq}:
      Mf{base, mark.hist(on, incr, hist), mark.incr(on, incr), bseq, iseq}

# the history let go (aofDelHistoryFiles, once it has removed them)
def mf.hist.gone(mf: Mf) -> Mf:
  match mf:
    case Mf{base, hist, incr, bseq, iseq}:
      Mf{base, Nil{}, incr, bseq, iseq}
