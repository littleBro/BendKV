# aof_check.bend: runs smoke.bend's batch with its effects (aof.bend:
# exec_log), writes the effects as the server appends them, reads the
# file back, runs it from an empty database and prints whether that gives
# the batch's database; then cuts the file at every length and prints
# whether each cut loads as whole entries and a leftover that together
# are the cut, the leftover holding no whole entry. Then the same for a
# batch on several databases (SELECT, SWAPDB, MOVE, FLUSHDB, FLUSHALL),
# run as acts (aof.bend: A.acts), its effects written with the SELECTs
# the server writes, the file replayed over 16 databases.
# Run: bend tests/aof_check.bend
import Base
import ../src/map.bend as KV
import ../src/redis.bend as R
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
  "BITFIELD g SET u8 0 x\r\nBITFIELD bo5 INCRBY u8 0 1\r\nBITFIELD bf1 SET u8 0 255\r\nBITFIELD_RO bf1 SET u8 0 1\r\n"

# an entry as its value, and the time it expires at when it has one
def dump.val(v: KV.Val) -> String:
  match v:
    case KV.VStr{s}:
      s
    case KV.VColl{c}:
      "<" ++ R.coll.type(c) ++ ">"

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

def same(+got: String, +want: String) -> String:
  Bool.pick(String, String.eq(got, want), "same", "differ: " ++ got ++ " vs " ++ want)

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

def cuts(+f: String, k: Nat, +n: Nat) -> String:
  match k:
    case 0n:
      "all " ++ Nat.show(n) ++ " cuts load"
    case 1n+m:
      +c = String.take(f, n)
      Bool.pick(String, cut_ok(c, A.load(c)), cuts(f, m, 1n+n), "cut at " ++ Nat.show(n) ++ " fails")

def report.of(+cs: List<&2, R.Cmd>, q: List<&2, R.Cmd> & R.Db) -> IO(Unit):
  (es, +db) = q
  +f = A.encode(A.args_all(es))
  +want = dump(db)
  +one = dump(db_of(R.exec_all(cs, R.db.empty())))
  do IO<Unit>:
    Unit <- IO.print("file: " ++ Nat.show(String.length(f)) ++ " bytes, " ++ Nat.show(List.length(&2, List<&2, String>, Pair.fst(List<&2, List<&2, String>>, String, A.load(f)))) ++ " entries")
    Unit <- IO.print("exec_log's database is exec_all's: " ++ same(want, one))
    Unit <- IO.print("replayed database: " ++ same(dump(replay(A.load(f))), want))
    Unit <- IO.print("database: " ++ want)
    IO.print(cuts(f, 1n+String.length(f), 0n))

def report(+cs: List<&2, R.Cmd>, r: List<&2, R.Reply> & (List<&2, R.Cmd> & R.Db)) -> IO(Unit):
  (rs, q) = r
  report.of(cs, q)

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

def mreport.of(q: List<&2, A.Eff> & R.Ds) -> IO(Unit):
  (es, +ds) = q
  +f = A.encode(A.effs.args(List.reverse(&2, A.Eff, es), 0n))
  +want = dump.ds(ds)
  do IO<Unit>:
    Unit <- IO.print("file on several databases: " ++ Nat.show(String.length(f)) ++ " bytes, " ++ Nat.show(List.length(&2, List<&2, String>, Pair.fst(List<&2, List<&2, String>>, String, A.load(f)))) ++ " entries")
    Unit <- IO.print("replayed databases: " ++ same(dump.ds(A.replay(Pair.fst(List<&2, List<&2, String>>, String, A.load(f)), 15n)), want))
    Unit <- IO.print("databases:\n" ++ want)
    IO.print(cuts(f, 1n+String.length(f), 0n))

def main() -> IO(Unit):
  +cs = batch_of(P.parse(buf()))
  do IO<Unit>:
    Unit <- report(cs, A.exec_log(cs, R.db.empty()))
    mreport.of(A.acts(A.file.acts(batch_of(P.parse(mbuf()))), (Nil{}, R.ds.empty(15n))))
