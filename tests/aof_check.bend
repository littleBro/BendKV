# aof_check.bend: runs smoke.bend's batch, and writes of hashes, of
# lists, of sets and of sorted sets, with its effects (aof.bend:
# exec_log), writes the effects as the server appends them, reads the
# file back, runs it from an empty database and checks that this gives
# the batch's database; then cuts the file at every length and checks
# that each cut loads as whole entries and a leftover that together are
# the cut, the leftover holding no whole entry. Then the same for a batch
# on several databases (SELECT, SWAPDB, MOVE, FLUSHDB, FLUSHALL), run as
# acts (aof.bend: A.acts), its effects written with the SELECTs the
# server writes, the file replayed over 16 databases. Each check prints
# its line; any that fails makes the run exit with 1. With
# BENDKV_CHECK_BREAK set to log, db or cut, one kind of check is given a
# wrong expectation, to show that its failure fails the run
# (tests/smoke_check.sh).
# Run: bend tests/aof_check.bend
import Base
import ../src/map.bend as KV
import ../src/redis.bend as R
import ../src/float.bend as F
import ../src/resp.bend as P
import ../src/batch.bend as B
import ../src/aof.bend as A

def batch_of(b: P.Batch) -> List<&2, R.Cmd>:
  match b:
    case P.Batch{reqs, tl, rest, err, need}:
      B.cmds_of(reqs, Nil{})

def buf() -> String:
  "*3\r\n$3\r\nSET\r\n$3\r\nfoo\r\n$3\r\nbar\r\n" ++
  "*2\r\n$3\r\nGET\r\n$3\r\nfoo\r\n" ++
  "get missing\r\n" ++
  "INCR n\r\nINCRBY n 41\r\nDECRBY n 100\r\n" ++
  "set s 99999999999999\r\nincr s\r\nincr foo\r\n" ++
  "APPEND foo baz\r\nSTRLEN foo\r\nMSET a 1 b 2 c 3 d 4 e 5 f 6\r\nMGET a b c x d e f\r\n" ++
  "EXISTS a b c a z\r\nDEL a b c z\r\nSETNX foo x\r\nSETNX g x\r\nGETSET foo y\r\nDBSIZE\r\n" ++
  "KEYS *\r\nKEYS f?o\r\nPING\r\nECHO hi\r\nNOPE 1 2\r\nSET k\r\nINCRBY n x\r\n" ++
  "SET big 9223372036854775807\r\nINCR big\r\nINCRBY m -5\r\nSET e \"\"\r\n" ++
  "FLUSHDB\r\nDBSIZE\r\nSET q 1\r\nMGET q q\r\nDEL q q\r\nKEYS *\r\n" ++
  "SET a 1\r\nINCRBY a 99\r\nAPPEND a 0\r\nMSET x 1 y 2\r\nDEL y\r\nSETNX z 3\r\nGETSET z 4\r\n" ++
  "SET t 1 EX 100\r\nSETEX u 10 v\r\nPSETEX w 5 w\r\nPEXPIRE a 5000\r\nEXPIRE x 7 NX\r\nEXPIRE x 9 NX\r\n" ++
  "EXPIRE x 8 GT\r\nEXPIRE x 9 LT\r\nPERSIST t\r\nPERSIST t\r\nINCR a\r\nAPPEND a 1\r\nGETEX u PX 300\r\n" ++
  "GETEX w PERSIST\r\nGETDEL z\r\nGETDEL z\r\nEXPIREAT n 2\r\nPEXPIREAT m 1\r\nSET g h KEEPTTL\r\n" ++
  "SET u v2 KEEPTTL GET\r\nSET p 1 PXAT 99999999999999999\r\nSET o 1 EXAT 1\r\nEXPIRE o -1\r\nSET o2 1 NX PX 10\r\n" ++
  "SET o2 2 XX\r\nTTL u\r\nPTTL a\r\nEXPIRETIME x\r\nPEXPIRETIME p\r\nTTL nope\r\nSET bad 1 EX 0\r\n" ++
  "SET bad 1 EX x\r\nSET bad 1 NX XX\r\nEXPIRE x 1 NX XX\r\nEXPIRE x 1 GT LT\r\nEXPIRE x 1 FOO\r\n" ++
  "SETRANGE g 3 xyz\r\nSETRANGE r1 2 ab\r\nSETRANGE r2 0 \"\"\r\nSETRANGE g 0 \"\"\r\nSETRANGE u 1 Z\r\n" ++
  "SETRANGE g 536870912 a\r\nSETRANGE g -1 a\r\nSETBIT b1 9 1\r\nSETBIT b1 9 1\r\nSETBIT b1 0 1\r\n" ++
  "SETBIT b1 100 0\r\nSETBIT a 3 1\r\nSETBIT b1 4294967296 1\r\nGETRANGE g 0 -1\r\nGETBIT b1 9\r\n" ++
  "BITCOUNT b1\r\nBITCOUNT b1 0 -1 BIT\r\nBITPOS b1 1\r\nBITPOS b1 0 2 -1 BYTE\r\nSUBSTR u 0 3\r\n" ++
  "MSETNX mx1 1 mx2 2\r\nMSETNX mx2 3 mx3 4\r\nMSETNX mx3 5 mx3 6\r\nMSETNX odd 1 x\r\nRENAME mx1 rn1\r\n" ++
  "RENAME rn1 u\r\nRENAMENX u mx2\r\nRENAMENX u rn2\r\nRENAME nope x\r\nRENAME rn2 rn2\r\nRENAMENX rn2 rn2\r\n" ++
  "BITOP AND bo1 g rn2\r\nBITOP OR bo2 g nope rn2\r\nBITOP XOR bo3 g g\r\nBITOP NOT bo4 g\r\nBITOP NOT g g\r\n" ++
  "SET bo5 1 EX 100\r\nBITOP OR bo5 g\r\nBITOP NOT bo4 nope\r\nBITOP FOO x y\r\nBITOP NOT x y z\r\nLCS g u\r\n" ++
  "BITFIELD bf1 SET u8 0 255 INCRBY i5 100 1 GET u4 0\r\nBITFIELD bf1 OVERFLOW FAIL INCRBY u2 0 9\r\n" ++
  "BITFIELD bf2 OVERFLOW FAIL INCRBY u2 30 9\r\nBITFIELD g SET i64 #1 -1 GET u63 64\r\nBITFIELD_RO g GET u8 0\r\n" ++
  "BITFIELD g SET u8 0 x\r\nBITFIELD bo5 INCRBY u8 0 1\r\nBITFIELD bf1 SET u8 0 255\r\nBITFIELD_RO bf1 SET u8 0 1\r\n" ++
  "HSET h a 1 b 2 a 3\r\nHMSET h c 4\r\nHSETNX h d 5\r\nHSETNX h a 9\r\nHINCRBY h a 10\r\nHINCRBY h2 n -7\r\n" ++
  "HDEL h b nope\r\nHDEL h2 n\r\nHSET g x y\r\nHSET h3 long vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv\r\nHSET h3 f 1\r\nHDEL h3 long\r\n" ++
  "HGET h a\r\nHGETALL h\r\nHINCRBY h a x\r\nHSET\r\nHSET h odd\r\nEXPIRE h 100\r\n" ++
  "*7\r\n$4\r\nEVAL\r\n$131\r\n" ++ R.hnew.script() ++ "\r\n$1\r\n1\r\n$2\r\nh4\r\n$4\r\nHSET\r\n$1\r\nf\r\n$1\r\nv\r\n" ++
  "*7\r\n$4\r\nEVAL\r\n$131\r\n" ++ R.hnew.script() ++ "\r\n$1\r\n1\r\n$1\r\nh\r\n$4\r\nHSET\r\n$1\r\nz\r\n$1\r\n1\r\n" ++
  "*8\r\n$4\r\nEVAL\r\n$131\r\n" ++ R.hnew.script() ++ "\r\n$1\r\n1\r\n$1\r\nu\r\n$4\r\nHSET\r\n$1\r\nz\r\n$1\r\n1\r\n$1\r\ny\r\n" ++
  "EVAL x 0\r\nEVAL\r\n" ++
  "RPUSH l a b c\r\nLPUSH l x\r\nLPUSHX l y\r\nRPUSHX nope z\r\nLPOP l\r\nRPOP l 2\r\nLSET l 0 q\r\n" ++
  "LINSERT l BEFORE q p\r\nLINSERT l AFTER nope p\r\nLREM l 0 p\r\nRPUSH l2 1 2 3 4 5 6\r\nLTRIM l2 1 -2\r\n" ++
  "LMOVE l2 l LEFT RIGHT\r\nLMOVE l2 l2 RIGHT LEFT\r\nRPOPLPUSH l2 l3\r\nLMPOP 2 nope l2 RIGHT COUNT 5\r\n" ++
  "LPUSH g x\r\nLPOP l3\r\nLPOP l3\r\nRPUSH l4 a\r\nEXPIRE l4 100\r\nRPOP l4 0\r\nLREM l4 0 a\r\n" ++
  "*7\r\n$4\r\nEVAL\r\n$131\r\n" ++ R.hnew.script() ++ "\r\n$1\r\n1\r\n$2\r\nl5\r\n$5\r\nLPUSH\r\n$1\r\na\r\n$1\r\nb\r\n" ++
  "*6\r\n$4\r\nEVAL\r\n$131\r\n" ++ R.hnew.script() ++ "\r\n$1\r\n1\r\n$1\r\nh\r\n$5\r\nRPUSH\r\n$1\r\nc\r\n" ++
  "*7\r\n$4\r\nEVAL\r\n$84\r\n" ++ R.lmove.script() ++ "\r\n$1\r\n2\r\n$1\r\nl\r\n$2\r\nl5\r\n$4\r\nLEFT\r\n$5\r\nRIGHT\r\n" ++
  "*7\r\n$4\r\nEVAL\r\n$84\r\n" ++ R.lmove.script() ++ "\r\n$1\r\n2\r\n$1\r\nl\r\n$1\r\nu\r\n$5\r\nRIGHT\r\n$4\r\nLEFT\r\n" ++
  "SADD st 1 2 3\r\nSADD st a\r\nSREM st 2 nope\r\nSADD sn 5 6\r\nSMOVE st sn 1\r\nSMOVE st st 3\r\n" ++
  "SMOVE st nope2 zz\r\nSINTERSTORE si st sn\r\nSUNIONSTORE su st sn\r\nSDIFFSTORE sd st sn\r\n" ++
  "SINTERSTORE sd st nope\r\nSINTERCARD 2 st sn\r\nSMEMBERS st\r\nSADD g x\r\nSET sx v\r\nEXPIRE st 100\r\n" ++
  "SREM st a\r\nSADD sb 1 b\r\nSREM sb b\r\nSREM sn 5 6\r\nSADD\r\nSINTERCARD 0 st\r\n" ++
  "*7\r\n$4\r\nEVAL\r\n$131\r\n" ++ R.hnew.script() ++ "\r\n$1\r\n1\r\n$2\r\nsx\r\n$4\r\nSADD\r\n$1\r\na\r\n$1\r\nb\r\n" ++
  "*6\r\n$4\r\nEVAL\r\n$131\r\n" ++ R.hnew.script() ++ "\r\n$1\r\n1\r\n$1\r\nh\r\n$4\r\nSADD\r\n$1\r\nc\r\n" ++
  "*6\r\n$4\r\nEVAL\r\n$76\r\n" ++ R.smove.script() ++ "\r\n$1\r\n2\r\n$2\r\nsu\r\n$2\r\nsx\r\n$1\r\n5\r\n" ++
  "*6\r\n$4\r\nEVAL\r\n$76\r\n" ++ R.smove.script() ++ "\r\n$1\r\n2\r\n$2\r\nsu\r\n$1\r\nl\r\n$1\r\n6\r\n" ++
  "ZADD zs 1 a 2 b 3 c\r\nZADD zs XX CH 5 a 9 nope\r\nZADD zs NX 7 a 4 d\r\nZINCRBY zs 2.5 b\r\nZADD zs INCR 1 c\r\n" ++
  "ZREM zs d nope\r\nZADD zs GT CH 0 a 6 c\r\nZADD z2 1 x 2 y 3 z 4 w\r\nZREMRANGEBYRANK z2 0 0\r\n" ++
  "ZREMRANGEBYSCORE z2 (2 3\r\nZADD zl 0 a 0 b 0 c 0 d\r\nZREMRANGEBYLEX zl [b (d\r\nZPOPMIN zl\r\nZPOPMAX z2 5\r\n" ++
  "ZADD z3 1 a 2 b 3 c 4 d\r\nZMPOP 2 nope z3 MAX COUNT 2\r\nZUNIONSTORE zu 2 zs z3 WEIGHTS 2 1\r\n" ++
  "ZINTERSTORE zi 2 zs z3 AGGREGATE MAX\r\nZDIFFSTORE zd 2 zs z3\r\nZDIFFSTORE zd 2 zs zs\r\nZRANGESTORE zr zs 0 1 REV\r\n" ++
  "ZRANGESTORE zr2 zs (1 +inf BYSCORE LIMIT 0 1\r\nZUNIONSTORE g 1 zs\r\nZADD zx 1 a\r\nEXPIRE zx 100\r\nZADD zx 2 b\r\n" ++
  "ZPOPMIN zx 2\r\nZADD\r\nZADD zs NX XX 1 a\r\nZADD zs -0 neg 1e300 big\r\nZINCRBY zs inf big\r\n" ++
  "*7\r\n$4\r\nEVAL\r\n$230\r\n" ++ R.znew.script() ++ "\r\n$1\r\n1\r\n$2\r\nzw\r\n$1\r\n0\r\n$1\r\n1\r\n$1\r\na\r\n" ++
  "*8\r\n$4\r\nEVAL\r\n$230\r\n" ++ R.znew.script() ++ "\r\n$1\r\n1\r\n$1\r\nh\r\n$1\r\n1\r\n$2\r\nCH\r\n$1\r\n5\r\n$1\r\nb\r\n" ++
  "*8\r\n$4\r\nEVAL\r\n$230\r\n" ++ R.znew.script() ++ "\r\n$1\r\n1\r\n$2\r\nzs\r\n$1\r\n1\r\n$4\r\nINCR\r\n$1\r\n5\r\n$1\r\nb\r\n"

# an entry as its value, and the time it expires at when it has one
def dump.pairs(ps: List<&2, KV.HPair>) -> String:
  match ps:
    case Nil{}:
      ""
    case Con{KV.HP{f, v}, rest}:
      " " ++ f ++ ":" ++ v ++ dump.pairs(rest)

def dump.elems(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{x, rest}:
      " " ++ x ++ dump.elems(rest)

def dump.zels(xs: List<&2, KV.ZEl>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{KV.ZEl{m, +d}, rest}:
      " " ++ m ++ ":" ++ F.f64.show(d) ++ dump.zels(rest)

def dump.val(v: KV.Val) -> String:
  match v:
    case KV.VStr{s}:
      s
    case KV.VColl{KV.CHash{+h}}:
      "<hash" ++ dump.pairs(KV.hash.pairs(h)) ++ ">"
    case KV.VColl{KV.CList{+l}}:
      "<list" ++ dump.elems(KV.deq.all(l)) ++ ">"
    case KV.VColl{KV.CMems{+m}}:
      "<set" ++ dump.elems(KV.mems.all(m)) ++ ">"
    case KV.VColl{KV.CZset{+z}}:
      "<zset" ++ dump.zels(KV.zt.all(KV.zset.tree(z))) ++ ">"

def dump.ent(m: Maybe<&2, KV.Item<KV.Val>>) -> String:
  match m:
    case Some{KV.Item{v, +e}}:
      dump.val(v) ++ Bool.pick(String, Nat.is_eq(e, 0n), "", "@" ++ Nat.show(e))
    case None{}:
      "?"

# a database as its keys and entries, in its own order (all keys are
# there at time 0)
def dump.go(+db: KV.Trie<KV.Val>, ks: List<&2, String>) -> String:
  match ks:
    case Nil{}:
      SNil{}
    case Con{+k, rest}:
      k ++ "=" ++ dump.ent(KV.entry(KV.Val, db, k)) ++ " " ++ dump.go(db, rest)

def dump.of(+t: KV.Trie<KV.Val>, +n: Nat, +x: Nat) -> String:
  dump.go(t, KV.keys(KV.Val, t, 0n)) ++ "(" ++ Nat.show(n) ++ " keys counted, " ++ Nat.show(x) ++ " with a time)"

# and the counts of keys the database keeps
def dump(+db: R.Db) -> String:
  match db:
    case R.Db{+t, +n, +x, now, rr}:
      dump.of(t, n, x)

def db_of(r: List<&2, R.Reply> & R.Db) -> R.Db:
  (rs, db) = r
  db

# the database the entries of a file leave, from an empty one
def replay(f: List<&2, List<&2, String>> & String) -> R.Db:
  (reqs, rest) = f
  db_of(R.exec_all(A.parse_all(reqs), R.db.empty()))

# a check's line: the two the same, or where they differ; and whether
# they are
def same(name: String, +got: String, +want: String) -> IO(Bool):
  do IO<Bool>:
    Unit <- IO.print(name ++ ": " ++ Bool.pick(String, String.eq(got, want), "same", "differ: " ++ got ++ " vs " ++ want))
    return String.eq(got, want)

# what a check of kind k expects is made wrong when the run breaks k
def brk(+mode: String, k: String) -> String:
  Bool.pick(String, String.eq(mode, k), "!", "")

def is_none(m: Maybe<&1, List<&2, String> & String>) -> Bool:
  match m:
    case None{}:
      True{}
    case Some{p}:
      False{}

# a cut loads as whole entries and a leftover that make the cut, and the
# leftover holds no whole entry
def cut_ok(+cut: String, l: List<&2, List<&2, String>> & String) -> Bool:
  (reqs, +rest) = l
  Bool.and(String.eq(A.encode(reqs) ++ rest, cut), is_none(A.entry(rest)))

# k cuts left from length n on, the cut before n loading (ok), each
# compared with the cut and b after it: a loop (a call in the place of a
# Bool.pick's branch would not be the last thing done, and a file of
# thousands of bytes would run out of stack)
def cuts(k: Nat, +f: String, +b: String, +n: Nat, ok: Bool) -> String:
  match k ok:
    case _ False{}:
      "cut at " ++ Nat.show(Nat.sub(n, 1n)) ++ " fails"
    case 0n True{}:
      "all " ++ Nat.show(n) ++ " cuts load"
    case 1n+m True{}:
      +c = String.take(f, n)
      cuts(m, f, b, 1n+n, cut_ok(c ++ b, A.load(c)))

def cuts.say(+r: String) -> IO(Bool):
  do IO<Bool>:
    Unit <- IO.print(r)
    return String.starts_with(r, "all ")

# the cuts of f, each compared with the cut and b after it; left out of a
# run that breaks another kind of check (their failure is all that run
# shows, and the cuts are the slowest checks)
def cuts.run(go: Bool, +f: String, +b: String) -> IO(Bool):
  match go:
    case True{}:
      cuts.say(cuts(1n+String.length(f), f, b, 0n, True{}))
    case False{}:
      IO.pure(Bool, True{})

def cuts.go(+mode: String) -> Bool:
  Bool.or(String.is_empty(mode), String.eq(mode, "cut"))

def report.of(+mode: String, +cs: List<&2, R.Cmd>, q: List<&2, R.Cmd> & R.Db) -> IO(Bool):
  (es, +db) = q
  +f = A.encode(A.args_all(es))
  +want = dump(db)
  +one = dump(db_of(R.exec_all(cs, R.db.empty())))
  do IO<Bool>:
    Unit <- IO.print("file: " ++ Nat.show(String.length(f)) ++ " bytes, " ++ Nat.show(List.length(&2, List<&2, String>, Pair.fst(List<&2, List<&2, String>>, String, A.load(f)))) ++ " entries")
    a : Bool <- same("exec_log's database is exec_all's", want, one ++ brk(mode, "log"))
    b : Bool <- same("replayed database", dump(replay(A.load(f))), want ++ brk(mode, "db"))
    Unit <- IO.print("database: " ++ want)
    d : Bool <- cuts.run(cuts.go(mode), f, brk(mode, "cut"))
    return Bool.and(a, Bool.and(b, d))

def report(+mode: String, +cs: List<&2, R.Cmd>, r: List<&2, R.Reply> & (List<&2, R.Cmd> & R.Db)) -> IO(Bool):
  (rs, q) = r
  report.of(mode, cs, q)

# a batch on several databases: SELECT moves the focus, SWAPDB, MOVE, COPY
# and FLUSHALL act on the databases (the batch is read as a file: COPY as
# BendKV writes it, COPY s d DB n REPLACE, and as Redis writes it, as the
# client sent it, the last two refused)
def mbuf() -> String:
  "SET a 0\r\nSELECT 4\r\nSET z 0\r\nFLUSHALL\r\nSET a 1\r\nSELECT 2\r\nSET b 2\r\nSET c 3 PX 100000\r\nSELECT 5\r\nSET d 4\r\n" ++
  "SELECT 2\r\nMOVE b 7\r\nMOVE b 7\r\nMOVE c 7\r\nSWAPDB 5 9\r\nSELECT 9\r\nINCR d\r\nSELECT 7\r\nSET h 8\r\n" ++
  "SELECT 6\r\nSET k 1\r\nFLUSHDB\r\nSET e 5\r\nSELECT 3\r\nSET g 7\r\nSELECT 14\r\nSWAPDB 3 15\r\nSET i 9\r\n" ++
  "COPY i i2 DB 14 REPLACE\r\nCOPY i j DB 4 REPLACE\r\nSET i 10\r\nCOPY i j DB 4 REPLACE\r\nCOPY nope x DB 1 REPLACE\r\n" ++
  "SELECT 7\r\nCOPY c c2 DB 0 REPLACE\r\nCOPY h i DB 14 REPLACE\r\n" ++
  "SELECT 14\r\ncopy i k\r\ncopy i2 k replace\r\nCOPY i2 m REPLACE db 5\r\nCOPY i2 k\r\nCOPY i k DB\r\nCOPY i k FOO\r\n"

# the databases as one string, each with its number
def dump.dbs(dbs: List<&2, R.Db>, +i: Nat) -> String:
  match dbs:
    case Nil{}:
      SNil{}
    case Con{+d, rest}:
      Nat.show(i) ++ ": " ++ dump(d) ++ "\n" ++ dump.dbs(rest, 1n+i)

def dump.ds(+ds: R.Ds) -> String:
  dump.dbs(R.ds.list(ds), 0n)

def mreport.of(+mode: String, q: List<&2, A.Eff> & R.Ds) -> IO(Bool):
  (es, +ds) = q
  +f = A.encode(A.effs.args(List.reverse(&2, A.Eff, es), 0n))
  +want = dump.ds(ds)
  do IO<Bool>:
    Unit <- IO.print("file on several databases: " ++ Nat.show(String.length(f)) ++ " bytes, " ++ Nat.show(List.length(&2, List<&2, String>, Pair.fst(List<&2, List<&2, String>>, String, A.load(f)))) ++ " entries")
    a : Bool <- same("replayed databases", dump.ds(A.replay(Pair.fst(List<&2, List<&2, String>>, String, A.load(f)), 15n)), want ++ brk(mode, "db"))
    Unit <- IO.print("databases:\n" ++ want)
    c : Bool <- cuts.run(cuts.go(mode), f, brk(mode, "cut"))
    return Bool.and(a, c)

def env.or(r: Result<&1, &1, U32 & String, String>) -> String:
  match r:
    case Done{v}:
      v
    case Fail{e}:
      ""

def verdict(ok: Bool) -> IO(Unit):
  match ok:
    case True{}:
      IO.print("ALL AOF CHECKS PASS")
    case False{}:
      IO.die(Unit, 1, "SOME AOF CHECKS FAIL")

def run(+mode: String) -> IO(Unit):
  +cs = batch_of(P.parse(buf()))
  do IO<Unit>:
    a : Bool <- report(mode, cs, A.exec_log(cs, R.db.empty()))
    b : Bool <- mreport.of(mode, A.acts(A.file.acts(batch_of(P.parse(mbuf()))), (Nil{}, R.ds.empty(15n))))
    verdict(Bool.and(a, b))

def main() -> IO(Unit):
  do IO<Unit>:
    r : Result<&1, &1, U32 & String, String> <- IO.get_env("BENDKV_CHECK_BREAK")
    run(env.or(r))
