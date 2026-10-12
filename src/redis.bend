# redis.bend: the semantics of the Redis commands BendKV serves, as one
# pure function exec(cmd, db) -> (reply, db'). The server (server.bend)
# only moves bytes and calls exec in order, as Redis's single command
# thread does, so every law about exec is a law about the running server.

import Base
import ./map.bend as KV
import ./float.bend as F

# Types
# -----

# the database: string keys to values (KV.Val: a string, or a collection;
# Redis strings are bytes, BendKV keeps one byte per Char) in a trie (t),
# and beside it how many
# keys the trie holds (n: kept as the commands change the trie, so that
# DBSIZE and INFO's keyspace do not count them), how many of them have a
# time to live (x) and the time at which a batch's commands run (now, ms
# since 1970). x and now are 0 until keys expire. rr is always None: a
# field of the record's own type makes the compiler box the record (a
# record of plain fields travels as separate registers, and each call
# that passes the database on would pass every field).
type Db is Data:
  Db{t: KV.Trie<KV.Val>, n: Nat, x: Nat, now: Nat, rr: Maybe<&2, Db>}

# an integer: IPos{n} is n, INeg{n} is -(n+1), so each integer has one form
type Int is Data:
  IPos{n: Nat}
  INeg{n: Nat}

# a RESP2 reply; an array holds replies, so arrays nest (HELLO, the
# tracking info of CLIENT). RIntS is an integer as its decimal text:
# BITFIELD's, of up to 64 bits, past what an Int holds. It comes last, so
# that the others keep their tags: after RInt, it made GET 1.5% dearer
# in instructions (the reply's encoder compiled otherwise). RNullA is the
# null array (LPOP with a count of a key not there), after it for the
# same reason
type Reply is Data:
  RStatus{s: String}
  RError{s: String}
  RInt{i: Int}
  RBulk{s: String}
  RNull{}
  RArray{xs: List<&2, Reply>}
  RIntS{s: String}
  RNullA{}

# a key and a value, for MSET
type KVPair is Data:
  KP{key: String, val: String}

# BITFIELD's fields are integers of up to 64 bits, signed (two's
# complement) or not, and its arithmetic wraps as C's does. A Nat stays
# below 2^48, so a word is two U32 halves, which wrap as C's do. No shift
# is ever by 32 or more: the defs that pick a half make the shift only on
# the half it is for.
type W64 is Data:
  W64{hi: U32, lo: U32}

# BITFIELD key [GET type offset] [SET type offset value] [INCRBY type
# offset increment] [OVERFLOW WRAP|SAT|FAIL] ...: a field is a signed (iN,
# N from 1 to 64) or unsigned (uN, N from 1 to 63) integer of N bits at a
# bit offset (#k: k times N), its bits numbered as SETBIT numbers them.
# OVERFLOW (0 WRAP, 1 SAT, 2 FAIL) holds for the operations after it.
type BfOp is Data:
  BfGet{sign: Bool, bits: Nat, off: Nat}
  BfSet{sign: Bool, bits: Nat, off: Nat, v: W64, ow: Nat}
  BfIncr{sign: Bool, bits: Nat, off: Nat, v: W64, ow: Nat}

# A read of a hash (PHash, below): a field's value (HGET), several
# (HMGET), how many fields it has (HLEN), a value's length (HSTRLEN),
# whether a field is there (HEXISTS), its fields (HKEYS), its values
# (HVALS), both (HGETALL), or a scan of it (HSCAN, its arguments after the
# key as they came: the cursor is read as the command parses, the options
# only once the key is found to hold a hash, as Redis reads them)
type HRead is Data:
  HRGet{f: String}
  HRMGet{fs: List<&2, String>}
  HRLen{}
  HRStrlen{f: String}
  HRExists{f: String}
  HRKeys{}
  HRVals{}
  HRAll{}
  HRScan{args: List<&2, String>}

# A write of a hash (UHash, below): HSET of pairs (HMSET when mset, which
# answers OK), HSETNX of a pair, HDEL of fields, HINCRBY of a field, a
# new hash of pairs where the key was, whatever it held (HWNew: the
# script the append-only file logs for a hash made where a key whose time
# had passed still lay, aof.bend), or HINCRBYFLOAT of a field (its
# increment a long double, read as the command parses, float.bend)
type HWrite is Data:
  HWSet{ps: List<&2, KV.HPair>, mset: Bool}
  HWSetNx{f: String, v: String}
  HWDel{fs: List<&2, String>}
  HWIncr{f: String, by: Int}
  HWNew{ps: List<&2, KV.HPair>}
  HWIncrF{f: String, by: F.Fl}

# LPOS's options: from the last element (back), the match to start from
# (rank, 1 the first), how many to answer (count: none for one, as an
# integer; 0 for all, as an array), how many elements to read (maxlen, 0
# for all); or the error they make
type LPosOpts is Data:
  LPosOpts{back: Bool, rank: Nat, count: Maybe<&2, Nat>, maxlen: Nat}
  LPosBad{r: Reply}

# A read of a list (PList, below): its length (LLEN), an element (LINDEX,
# its index as it came: Redis reads it only once it finds the list), a
# range (LRANGE: start and end), or where an element is (LPOS: the
# element and the options). Each keeps its arguments as they came, one
# word (PeekOp), and reads them as it runs; the parser reads LRANGE's and
# LPOS's first, to answer their errors before the key is looked for, as
# Redis does.
type LRead is Data:
  LRLen{}
  LRIndex{i: String}
  LRRange{args: List<&2, String>}
  LRPos{args: List<&2, String>}

# A write of a list (UList, below): pushes of elements at its first end
# (left) or its last (LPUSH, RPUSH), or onto a list that is there only
# (LPUSHX, RPUSHX); a pop of one element (LPOP, RPOP) or of a count (as
# an array); LSET of the element at an index; LINSERT of v before (or
# after) the first p; LREM of v (c of them from the first end, -c from
# the last, 0 all); LTRIM to a range; or a new list of pushes where the
# key was, whatever it held (LWNew: the script the append-only file logs
# for a list made where a key whose time had passed still lay,
# aof.bend). The numbers keep the text they came as: the parser reads
# the counts of LPOP and LREM and LTRIM's range to answer its errors
# first, as Redis does, and the write reads them again as it runs (LSET
# reads its index only once it finds the list), so that the write the
# append-only file logs is the one the client sent. Each form has two
# fields at most, so that a change that keeps one is no wider than a
# hash's (Change, below).
type LWrite is Data:
  LWPush{left: Bool, xs: List<&2, String>}
  LWPushX{left: Bool, xs: List<&2, String>}
  LWPop{left: Bool}
  LWPopN{left: Bool, c: String}
  LWSet{i: String, v: String}
  LWBefore{p: String, v: String}
  LWAfter{p: String, v: String}
  LWRem{c: String, v: String}
  LWTrim{a: String, b: String}
  LWNew{left: Bool, xs: List<&2, String>}

# A read of a set (PMems, below): whether a member is there (SISMEMBER),
# each of several (SMISMEMBER), how many members it has (SCARD), its
# members (SMEMBERS), or a scan of it (SSCAN, its arguments after the key
# as they came, as HSCAN keeps them)
type SRead is Data:
  SRIs{m: String}
  SRMIs{ms: List<&2, String>}
  SRCard{}
  SRAll{}
  SRScan{args: List<&2, String>}

# A write of a set (UMems, below): SADD of members, SREM of members, a
# new set of members where the key was, whatever it held (SWNew: the
# script the append-only file logs for a set made where a key whose time
# had passed still lay, and the set a STORE of a set operation leaves,
# aof.bend), or SPOP of a member (SWPop) or of c different members
# (SWPopN), picked by the server's random number r (the session makes
# these two, session.bend: SPOP is logged as the SREM of what it took)
type SWrite is Data:
  SWAdd{ms: List<&2, String>}
  SWRem{ms: List<&2, String>}
  SWNew{ms: List<&2, String>}
  SWPop{r: U32}
  SWPopN{c: Nat, r: U32}

# A sorted set's score and member, as ZADD takes them (the score's text
# as it came: the write reads it as it runs, and the append-only file
# logs it again)
type ZPair is Data:
  ZPair{s: String, m: String}

# ZADD's options (ZINCRBY is ZADD with INCR)
type ZOpts is Data:
  ZOpts{nx: Bool, xx: Bool, gt: Bool, lt: Bool, ch: Bool, incr: Bool}

# A range of a sorted set's elements, as ZRANGE and its kin read it: by
# rank (start and stop, as LRANGE reads them), by score or by member
# (each bound read: the lower one first, as Redis keeps them once it has
# swapped those of a reversed range)
type ZRng is Data:
  ZRankR{a: Int, b: Int}
  ZScoreR{lo: KV.ZSB, hi: KV.ZSB}
  ZLexR{lo: KV.ZLB, hi: KV.ZLB}

# A read of a range: the range, LIMIT's offset and count (longs; none is
# 0 and -1) and whether it answers the scores (WITHSCORES); or such a read
# from the last element (REV). A command travels in registers as wide as
# its widest form, and a range and its options are many words: as a read
# from the last element holds the read it reverses, the compiler makes a
# read a node of its own, as UGet makes an update one.
type ZQ is Data:
  ZQ{r: ZRng, off: Int, cnt: Int, ws: Bool}
  ZQRev{q: ZQ}

# A read of a sorted set (PZset, below): how many elements it has
# (ZCARD), a member's score (ZSCORE), several (ZMSCORE), a member's rank
# (ZRANK), from the last element (ZREVRANK), how many elements a range of
# scores holds (ZCOUNT) or of members (ZLEXCOUNT: the bounds of both as
# they came, as LRANGE keeps its own, read as the command parses and
# again as it runs), a range (ZRANGE and its kin, read as the command
# parses), each read to answer its errors before the key is looked for,
# as Redis does; or a scan of it (ZSCAN, its arguments after the key as
# they came, as HSCAN keeps them)
type ZRead is Data:
  ZRCard{}
  ZRScore{m: String}
  ZRMScore{ms: List<&2, String>}
  ZRRank{m: String}
  ZRRevRank{m: String}
  ZRCount{args: List<&2, String>}
  ZRLexCount{args: List<&2, String>}
  ZRRange{q: ZQ}
  ZRScan{args: List<&2, String>}

# A write of a sorted set (UZset, below): ZADD of pairs with options
# (ZINCRBY: with INCR), ZREM of members, a new sorted set of a ZADD where
# the key was, whatever it held (ZWNew: the script the append-only file
# logs for a sorted set made where a key whose time had passed still
# lay, and the sorted set a STORE leaves, aof.bend), ZREMRANGEBYRANK,
# ZREMRANGEBYSCORE and ZREMRANGEBYLEX of a range (its bounds as they
# came: the parser reads them to answer their errors first, as Redis
# does, and the write reads them again as it runs, so that the write the
# append-only file logs is the one the client sent), or ZPOPMIN (ZPOPMAX
# when max) of one element or of a count (as it came)
type ZWrite is Data:
  ZWAdd{o: ZOpts, ps: List<&2, ZPair>}
  ZWRem{ms: List<&2, String>}
  ZWNew{o: ZOpts, ps: List<&2, ZPair>}
  ZWRemRank{a: String, b: String}
  ZWRemScore{a: String, b: String}
  ZWRemLex{a: String, b: String}
  ZWPop{max: Bool}
  ZWPopN{max: Bool, c: String}

# A read of one key whose reply depends on what the key holds at now
# alone (its value and the time it expires at, when it is there): its
# type (TYPE), its length (STRLEN), its time to live in s or ms (TTL,
# PTTL) or the time it expires at (EXPIRETIME, PEXPIRETIME), a range of
# its bytes (GETRANGE, SUBSTR), a bit (GETBIT), the bits set in a range
# (BITCOUNT), the first bit of a value in one (BITPOS), fields of its
# bits (BITFIELD_RO, and BITFIELD whose operations are GETs alone), a
# read of a hash (PHash), of a list (PList) or of a set (PMems). The
# laws see them as one command, Peek (LAWS.bend: disturbs), so one more
# needs no more proof. A command travels in registers as wide as its
# widest form, so each has one field of a word at most: GETRANGE,
# BITCOUNT and BITPOS keep their arguments as they came (Ranges and bits,
# below), BITFIELD its operations as a list.
type PeekOp is Data:
  PType{}
  PStrlen{}
  PTtl{}
  PPttl{}
  PExpTime{}
  PPExpTime{}
  PRange{args: List<&2, String>}
  PGetBit{off: Nat}
  PCount{args: List<&2, String>}
  PPos{args: List<&2, String>}
  PBitfield{ops: List<&2, BfOp>}
  PHash{op: HRead}
  PList{op: LRead}
  PMems{op: SRead}
  PZset{op: ZRead}

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
# 1970), PERSIST, INCRBY (UIncr: as the append-only file sees it,
# aof.bend; the server runs INCRBY as its own command, IncrBy, the same
# way, faster), SETRANGE (s at offset off), SETBIT (the bit at offset
# off, to on), BITFIELD with a write among its operations, a write of a
# hash (UHash), of a list (UList) or of a set (UMems), and INCRBYFLOAT
# (its increment as it came, read once the key's value is). The laws
# see them as one command, Upd, so one more needs no more proof. UGet holds an update, so the compiler makes an update a
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
  URange{off: Nat, s: String}
  USetBit{off: Nat, on: Bool}
  UBitfield{ops: List<&2, BfOp>}
  UHash{op: HWrite}
  UList{op: LWrite}
  UMems{op: SWrite}
  UIncrF{by: String}
  UZset{op: ZWrite}

# The commands of a connection and of the server: session.bend runs
# them, with the state of the connection and of the server. None of them
# changes a database but the commands of several databases (SWAPDB, MOVE,
# FLUSHALL), which act on all of them (Databases, below). They come as
# one command, Own, which exec never meets (it answers one with an
# error), so the laws of exec see them as one more command that only
# reads. TIME reads the clock (the time the batch runs at), OBJECT a key of
# the selected database and the parameters of eviction; COPY copies a key
# to the selected database or another one (an act of several databases,
# below), its arguments kept as they came and read as it runs; LCS reads
# two keys of the selected database and proto-max-bulk-len, which bounds
# its table, its arguments read as it runs; HRANDFIELD reads a hash and
# the server's random numbers, MEMORY USAGE the size of a key's entry,
# their arguments read as they run; SPOP and SRANDMEMBER read a set and
# the random numbers, and SPOP takes the members it answers out of the set
# (an act of the session's database, session.bend). A command whose
# reply is fixed (a HELP) is SReply; one the parser found wrong (an
# unknown subcommand, a wrong number of arguments) is SBad, answered as
# Redis answers those, before it asks a client to authenticate.

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
  SSwapDb{a: String, b: String}
  SMove{key: String, db: String}
  SFlushAll{}
  STime{}
  SObject{sub: Nat, key: String}
  SCopy{args: List<&2, String>}
  SLcs{args: List<&2, String>}
  SHRandField{key: String, args: List<&2, String>}
  SMemUsage{key: String, args: List<&2, String>}
  SReply{r: Reply}
  SBad{r: Reply}
  SSPop{key: String, args: List<&2, String>}
  SSRandMember{key: String, args: List<&2, String>}
  SZRandMember{key: String, args: List<&2, String>}

# BITOP's operation
type BitK is Data:
  BAnd{}
  BOr{}
  BXor{}
  BNot{}

# LMOVE's ends: where it pops (L the first end, R the last) and where it
# pushes; a New form deletes the destination first (the script the
# append-only file logs for a move to a key whose entry's time had
# passed, aof.bend)
type LEnds is Data:
  LtoL{}
  LtoR{}
  RtoL{}
  RtoR{}
  LtoLNew{}
  LtoRNew{}
  RtoLNew{}
  RtoRNew{}

# A set operation: the intersection of sets (SINTER, SINTERSTORE), their
# union (SUNION), the first less the others (SDIFF), or the size of the
# intersection, counted up to limit (SINTERCARD; 0 counts all)
type SetK is Data:
  KInter{}
  KUnion{}
  KDiff{}
  KCard{limit: Nat}

# The options of ZUNION, ZINTER, ZDIFF and ZINTERCARD (and of their
# STOREs), read as the command parses: WEIGHTS (a double for each key;
# none given: 1 for each), AGGREGATE (0 SUM, 1 MIN, 2 MAX) and LIMIT
# (lim; 0 counts all); such options with WITHSCORES; or the error they
# make, answered once the keys are found to hold sets or sorted sets
# (Redis reads the options after the keys). As the options with
# WITHSCORES hold the options, the compiler makes them a node of their
# own, and an operation is a word wide (Cmd, below).
type ZAgg is Data:
  ZAgg{ws: List<&2, F.F64>, agg: Nat, lim: Nat}
  ZAggScores{o: ZAgg}
  ZAggBad{r: Reply}

# A sorted-set operation and its options: the union of sorted sets
# (ZUNION; a set is a sorted set of scores 1), their intersection
# (ZINTER), the first less the others (ZDIFF), or the size of the
# intersection, counted up to its LIMIT (ZINTERCARD)
type ZSetK is Data:
  ZKUnion{o: ZAgg}
  ZKInter{o: ZAgg}
  ZKDiff{o: ZAgg}
  ZKCard{o: ZAgg}

# SMOVE's member, and whether the move takes the destination as not
# there, whatever it holds (SMemNew: the script the append-only file logs
# for a move to a key whose entry's time had passed, aof.bend)
type SMem is Data:
  SMem{m: String}
  SMemNew{m: String}

# a parsed command. LMove (LMOVE, RPOPLPUSH: an element popped from the
# list at src and pushed onto the one at dst, the ends e) and LMPop
# (LMPOP: up to c elements popped from the first of the keys that is
# there, at its first end when left) come after the others, so that they
# keep their tags, and the commands of several sets after them: SOp (a
# set operation on the sets at keys: SINTER, SUNION, SDIFF, SINTERCARD),
# SStore (SINTERSTORE, SUNIONSTORE, SDIFFSTORE: the set an operation
# makes of the sets at srcs, set at dst) and SMv (SMOVE: a member moved
# from the set at src to the set at dst), then those of several sorted
# sets: ZOp (a sorted-set operation on the keys: ZUNION, ZINTER, ZDIFF,
# ZINTERCARD), ZStore (ZUNIONSTORE, ZINTERSTORE, ZDIFFSTORE: the sorted
# set an operation makes of the keys at srcs, set at dst), ZRangeStore
# (ZRANGESTORE: a range of the sorted set at src, set at dst) and ZMPop
# (ZMPOP: up to c elements popped from the first of the keys that is
# there, from its last end when max)
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
  FlushDb{}
  Keys{pattern: String}
  Scan{args: List<&2, String>}
  Peek{key: String, c: PeekOp}
  Upd{key: String, op: UpdOp}
  MSetNx{pairs: List<&2, KVPair>}
  Rename{src: String, dst: String, nx: Bool}
  BitOp{op: BitK, dst: String, srcs: List<&2, String>}
  Own{op: SessOp}
  Bad{reply: Reply}
  LMove{src: String, dst: String, e: LEnds}
  LMPop{keys: List<&2, String>, left: Bool, c: String}
  SOp{k: SetK, keys: List<&2, String>}
  SStore{k: SetK, dst: String, srcs: List<&2, String>}
  SMv{src: String, dst: String, m: SMem}
  ZOp{k: ZSetK, keys: List<&2, String>}
  ZStore{k: ZSetK, dst: String, srcs: List<&2, String>}
  ZRangeStore{dst: String, src: String, q: ZQ}
  ZMPop{keys: List<&2, String>, max: Bool, c: String}

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

def e_wrongtype() -> Reply:
  RError{"WRONGTYPE Operation against a key holding the wrong kind of value"}

# GET's reply from what it finds (KV.get_copy): a string, or WRONGTYPE
# for another kind of value; MGET's answers nil for one
def r_getv(m: KV.Got) -> Reply:
  match m:
    case KV.GStr{s}:
      RBulk{s}
    case KV.GColl{}:
      e_wrongtype()
    case KV.GNone{}:
      RNull{}

def i_getv(m: Maybe<&2, KV.Val>) -> Reply:
  match m:
    case Some{KV.VStr{s}}:
      RBulk{s}
    case Some{KV.VColl{c}}:
      RNull{}
    case None{}:
      RNull{}

# the name TYPE gives a value's kind
def coll.type(+c: KV.Coll) -> String:
  match c:
    case KV.CHash{h}:
      "hash"
    case KV.CList{l}:
      "list"
    case KV.CMems{s}:
      "set"
    case KV.CZset{z}:
      "zset"

def val.type(+v: KV.Val) -> String:
  match v:
    case KV.VStr{s}:
      "string"
    case KV.VColl{+c}:
      coll.type(c)

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
# while they make less than 128 bytes, each cut to what is left; each up
# to its first NUL, as Redis formats them with %s
def unknown.arg(room: Bool, x: String, +acc: String) -> String:
  match room:
    case True{}:
      acc ++ "'" ++ String.take(cstr(x), Nat.sub(128n, String.length(acc))) ++ "' "
    case False{}:
      acc

def unknown.args(xs: List<&2, String>, +acc: String) -> String:
  match xs:
    case Nil{}:
      acc
    case Con{x, rest}:
      unknown.args(rest, unknown.arg(Nat.is_lt(String.length(acc), 128n), x, acc))

def e_unknown(name: String, args: List<&2, String>) -> Cmd:
  Bad{RError{no_newlines("ERR unknown command '" ++ String.take(cstr(name), 128n) ++ "', with args beginning with: " ++ unknown.args(args, ""))}}

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

def parse_msetnx(ps: Maybe<&2, List<&2, KVPair>>) -> Cmd:
  match ps:
    case Some{Nil{}}:
      e_arity("msetnx")
    case Some{Con{p, rest}}:
      MSetNx{p <> rest}
    case None{}:
      e_arity("msetnx")

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
# needs the connection to be authenticated). The subcommand is quoted up
# to 128 bytes and its first NUL, as Redis's %.128s quotes it.

def e_unknown_sub(sub: String, cmd: String) -> SessOp:
  SBad{RError{no_newlines("ERR unknown subcommand '" ++ String.take(cstr(sub), 128n) ++ "'. Try " ++ cmd ++ " HELP.")}}

# a subcommand's own complaint about its arguments
def e_sub_syntax(sub: String, cmd: String) -> Reply:
  RError{no_newlines("ERR unknown subcommand or wrong number of arguments for '" ++ String.take(cstr(sub), 128n) ++ "'. Try " ++ cmd ++ " HELP.")}

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

# BITOP op dst src...: the operation named in any case, as strcasecmp
# reads it; NOT takes exactly one source
def bitop.kind(+w: String) -> Maybe<&2, BitK>:
  Bool.pick(Maybe<&2, BitK>, is_word(w, "AND"), Some{BAnd{}},
  Bool.pick(Maybe<&2, BitK>, is_word(w, "OR"), Some{BOr{}},
  Bool.pick(Maybe<&2, BitK>, is_word(w, "XOR"), Some{BXor{}},
  Bool.pick(Maybe<&2, BitK>, is_word(w, "NOT"), Some{BNot{}}, None{}))))

def parse_bitop(m: Maybe<&2, BitK>, d: String, srcs: List<&2, String>) -> Cmd:
  match m:
    case None{}:
      Bad{RError{"ERR syntax error"}}
    case Some{BNot{}}:
      match srcs:
        case Con{k, Nil{}}:
          BitOp{BNot{}, d, [k]}
        case _:
          Bad{RError{"ERR BITOP NOT must be called with a single source key."}}
    case Some{BAnd{}}:
      BitOp{BAnd{}, d, srcs}
    case Some{BOr{}}:
      BitOp{BOr{}, d, srcs}
    case Some{BXor{}}:
      BitOp{BXor{}, d, srcs}

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

# OBJECT: what Redis keeps of a value beside it (session.bend answers it,
# with the parameters of eviction)
def object_id(+n: String, len: Nat) -> Nat:
  match len:
    case 4n:
      Bool.pick(Nat, String.eq(n, "HELP"), 1n,
      Bool.pick(Nat, String.eq(n, "FREQ"), 2n, 0n))
    case 8n:
      Bool.pick(Nat, String.eq(n, "ENCODING"), 3n,
      Bool.pick(Nat, String.eq(n, "REFCOUNT"), 4n,
      Bool.pick(Nat, String.eq(n, "IDLETIME"), 5n, 0n)))
    case _:
      0n

def object_help() -> List<&2, String>:
  ["ENCODING <key>",
   "    Return the kind of internal representation used in order to store the value",
   "    associated with a <key>.",
   "FREQ <key>",
   "    Return the access frequency index of the <key>. The returned integer is",
   "    proportional to the logarithm of the recent access frequency of the key.",
   "IDLETIME <key>",
   "    Return the idle time of the <key>, that is the approximated number of",
   "    seconds elapsed since the last access to the key.",
   "REFCOUNT <key>",
   "    Return the number of references of the value associated with the specified",
   "    <key>."]

# a subcommand of a key: FREQ 2, ENCODING 3, REFCOUNT 4, IDLETIME 5
def object_key(+id: Nat, args: List<&2, String>, name: String) -> SessOp:
  match args:
    case Con{k, Nil{}}:
      SObject{id, k}
    case _:
      s_arity(name)

def parse_object(id: Nat, sub: String, args: List<&2, String>) -> SessOp:
  match id:
    case 1n:  # HELP
      match args:
        case Nil{}:
          help("OBJECT", object_help())
        case _:
          s_arity("object|help")
    case 2n:
      object_key(2n, args, "object|freq")
    case 3n:
      object_key(3n, args, "object|encoding")
    case 4n:
      object_key(4n, args, "object|refcount")
    case 5n:
      object_key(5n, args, "object|idletime")
    case _:
      e_unknown_sub(sub, "OBJECT")

# MEMORY: USAGE of a key (its options read as it runs) and HELP
def memory_id(+n: String, len: Nat) -> Nat:
  match len:
    case 4n:
      Bool.pick(Nat, String.eq(n, "HELP"), 1n, 0n)
    case 5n:
      Bool.pick(Nat, String.eq(n, "USAGE"), 2n, 0n)
    case _:
      0n

def memory_help() -> List<&2, String>:
  ["DOCTOR",
   "    Return memory problems reports.",
   "MALLOC-STATS",
   "    Return internal statistics report from the memory allocator.",
   "PURGE",
   "    Attempt to purge dirty pages for reclamation by the allocator.",
   "STATS",
   "    Return information about the memory usage of the server.",
   "USAGE <key> [SAMPLES <count>]",
   "    Return memory in bytes used by <key> and its value. Nested values are",
   "    sampled up to <count> times (default: 5, 0 means sample all)."]

def parse_memory(id: Nat, sub: String, args: List<&2, String>) -> SessOp:
  match id:
    case 1n:  # HELP
      match args:
        case Nil{}:
          help("MEMORY", memory_help())
        case _:
          s_arity("memory|help")
    case 2n:  # USAGE
      match args:
        case Con{k, rest}:
          SMemUsage{k, rest}
        case Nil{}:
          s_arity("memory|usage")
    case _:
      e_unknown_sub(sub, "MEMORY")

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

# FLUSHDB and FLUSHALL take ASYNC or SYNC, which change nothing here:
# FLUSHDB empties the selected database, FLUSHALL every database (a
# command of several databases, Own)
def parse_flush(args: List<&2, String>, c: Cmd) -> Cmd:
  match args:
    case Nil{}:
      c
    case Con{+m, Nil{}}:
      Bool.pick(Cmd, Bool.or(is_word(m, "SYNC"), is_word(m, "ASYNC")), c, e_syntax())
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

# A list's index or count is a long as Redis reads one (string2ll), its
# magnitude clamped to 2^47: no list holds that many elements, so each
# command answers for the clamped long as for the long itself.
def lnum.big() -> Nat:
  Nat.mul(Nat.mul(65536n, 65536n), 32768n)

def lnum.mag(small: Bool, +hi: Nat, +lo: Nat) -> Nat:
  match small:
    case True{}:
      Nat.min(Nat.add(Nat.mul(hi, 1000000000n), lo), lnum.big())
    case False{}:
      lnum.big()

def lnum.of(l: LL) -> Maybe<&2, Int>:
  match l:
    case LL{+neg, +hi, +lo}:
      +m = lnum.mag(Nat.is_lt(hi, 140737n), hi, lo)
      Some{Bool.pick(Int, neg, INeg{Nat.sub(m, 1n)}, IPos{m})}
    case LLBad{}:
      None{}

# s as a list's index or count; none when it is no long
def lnum(+s: String) -> Maybe<&2, Int>:
  lnum.of(ll.read(s))

def lnum.ok(+s: String) -> Bool:
  Maybe.is_some(&2, Int, lnum(s))

def lcount.of(m: Maybe<&2, Int>) -> Maybe<&2, Nat>:
  match m:
    case Some{IPos{n}}:
      Some{n}
    case _:
      None{}

# s as a count: a long at least 0
def lcount(+s: String) -> Maybe<&2, Nat>:
  lcount.of(lnum(s))

# the position of index i among n elements (n + i for i below 0), when
# it falls among them
def lidx.at(+i: Int, +n: Nat) -> Maybe<&2, Nat>:
  match i:
    case IPos{+m}:
      Bool.pick(Maybe<&2, Nat>, Nat.is_lt(m, n), Some{m}, None{})
    case INeg{+m}:
      Bool.pick(Maybe<&2, Nat>, Nat.is_lt(m, n), Some{Nat.sub(Nat.sub(n, m), 1n)}, None{})

# LRANGE's and LTRIM's range among n elements, as Redis reads it: start
# and end count from the first element (from the last for one below
# 0), start at least 0, end at most n - 1; none when it holds no element
type LSpan is Data:
  LSpan{s: Nat, e: Nat}
  LNone{}

def lspan.start(+a: Int, +n: Nat) -> Nat:
  match a:
    case IPos{+x}:
      x
    case INeg{+x}:
      Nat.sub(n, 1n+x)

def lspan.end(+b: Int, +n: Nat) -> Maybe<&2, Nat>:
  match b:
    case IPos{+y}:
      Some{y}
    case INeg{+y}:
      Bool.pick(Maybe<&2, Nat>, Nat.is_lt(y, n), Some{Nat.sub(Nat.sub(n, y), 1n)}, None{})

def lspan.of(+s: Nat, me: Maybe<&2, Nat>, +n: Nat) -> LSpan:
  match me:
    case Some{+e}:
      Bool.pick(LSpan, Bool.or(Nat.is_lt(e, s), Nat.is_le(n, s)), LNone{}, LSpan{s, Nat.min(e, Nat.sub(n, 1n))})
    case None{}:
      LNone{}

def lspan(+a: Int, +b: Int, +n: Nat) -> LSpan:
  lspan.of(lspan.start(a, n), lspan.end(b, n), n)


# 64-bit words
# ------------
# BITFIELD's arithmetic, on W64 (Types): C's on int64_t and uint64_t.

def w64.zero() -> W64:
  W64{0, 0}

def w64.ones() -> W64:
  W64{4294967295, 4294967295}

def w64.not(a: W64) -> W64:
  match a:
    case W64{+h, +l}:
      W64{U32.not(h), U32.not(l)}

def w64.and(a: W64, b: W64) -> W64:
  match a b:
    case W64{+h, +l} W64{+g, +m}:
      W64{U32.and(h, g), U32.and(l, m)}

def w64.or(a: W64, b: W64) -> W64:
  match a b:
    case W64{+h, +l} W64{+g, +m}:
      W64{U32.or(h, g), U32.or(l, m)}

# a + b, wrapping: the carry out of the low halves goes into the high one
def w64.add(a: W64, b: W64) -> W64:
  match a b:
    case W64{+h, +l} W64{+g, +m}:
      +s = U32.add(l, m)
      W64{U32.add(U32.add(h, g), Bool.pick(U32, U32.is_lt(s, l), 1, 0)), s}

def w64.neg(a: W64) -> W64:
  w64.add(w64.not(a), W64{0, 1})

def w64.sub(a: W64, b: W64) -> W64:
  w64.add(a, w64.neg(b))

def w64.is_neg(+a: W64) -> Bool:
  match a:
    case W64{+h, l}:
      U32.is_eq(U32.shrn(h, 31n), 1)

def w64.is_zero(+a: W64) -> Bool:
  match a:
    case W64{+h, +l}:
      Bool.and(U32.is_eq(h, 0), U32.is_eq(l, 0))

def w64.eq(+a: W64, +b: W64) -> Bool:
  match a b:
    case W64{+h, +l} W64{+g, +m}:
      Bool.and(U32.is_eq(h, g), U32.is_eq(l, m))

def w64.is_pos(+a: W64) -> Bool:
  Bool.and(Bool.not(w64.is_neg(a)), Bool.not(w64.is_zero(a)))

# a < b, unsigned and signed
def w64.ult(+a: W64, +b: W64) -> Bool:
  match a b:
    case W64{+h, +l} W64{+g, +m}:
      Bool.or(U32.is_lt(h, g), Bool.and(U32.is_eq(h, g), U32.is_lt(l, m)))

def w64.slt(+a: W64, +b: W64) -> Bool:
  +na = w64.is_neg(a)
  +nb = w64.is_neg(b)
  Bool.or(Bool.and(na, Bool.not(nb)), Bool.and(Bool.not(Bool.xor(na, nb)), w64.ult(a, b)))

# a shifted left by one, the bit b coming in at the low end
def w64.shl1(a: W64, +b: U32) -> W64:
  match a:
    case W64{+h, +l}:
      W64{U32.or(U32.shln(h, 1n), U32.shrn(l, 31n)), U32.or(U32.shln(l, 1n), b)}

# a times n (n small), wrapping
def w64.mul(+a: W64, n: Nat, acc: W64) -> W64:
  match n:
    case 0n:
      acc
    case 1n+m:
      w64.mul(a, m, w64.add(acc, a))

# the n low bits of a half (n below 32)
def w64.mask32(+n: Nat) -> U32:
  U32.sub(U32.shln(1, n), 1)

def w64.low.hi(all: Bool, +n: Nat) -> W64:
  match all:
    case True{}:
      w64.ones()
    case False{}:
      W64{w64.mask32(Nat.sub(n, 32n)), 4294967295}

def w64.low.of(big: Bool, +n: Nat) -> W64:
  match big:
    case True{}:
      w64.low.hi(Nat.is_le(64n, n), n)
    case False{}:
      W64{0, w64.mask32(n)}

# the n low bits set (n from 0 to 64)
def w64.low(+n: Nat) -> W64:
  w64.low.of(Nat.is_le(32n, n), n)

# a's bit i (0 the lowest, i below 64)
def w64.bit.of(low: Bool, +h: U32, +l: U32, +i: Nat) -> U32:
  match low:
    case True{}:
      U32.and(U32.shrn(l, i), 1)
    case False{}:
      U32.and(U32.shrn(h, Nat.sub(i, 32n)), 1)

def w64.bit(+a: W64, +i: Nat) -> U32:
  match a:
    case W64{+h, +l}:
      w64.bit.of(Nat.is_lt(i, 32n), h, l, i)

# a shifted left by n (1 to 8) bits, the n bits y coming in at its low end
def w64.shln8(a: W64, +n: Nat, +y: U32) -> W64:
  match a:
    case W64{+h, +l}:
      W64{U32.or(U32.shln(h, n), U32.shrn(l, Nat.sub(32n, n))), U32.or(U32.shln(l, n), y)}

# the n bits (n from 1 to 8) of a from its bit sh up (sh below 64): of the
# high half, of the low one, or across them (sh above 24, below 32)
def w64.bits.lo(fits: Bool, +h: U32, +l: U32, +sh: Nat, +n: Nat) -> U32:
  match fits:
    case True{}:
      U32.and(U32.shrn(l, sh), w64.mask32(n))
    case False{}:
      U32.and(U32.or(U32.shrn(l, sh), U32.shln(h, Nat.sub(32n, sh))), w64.mask32(n))

def w64.bits.of(high: Bool, +h: U32, +l: U32, +sh: Nat, +n: Nat) -> U32:
  match high:
    case True{}:
      U32.and(U32.shrn(h, Nat.sub(sh, 32n)), w64.mask32(n))
    case False{}:
      w64.bits.lo(Nat.is_le(Nat.add(sh, n), 32n), h, l, sh, n)

def w64.bits(+a: W64, +sh: Nat, +n: Nat) -> U32:
  match a:
    case W64{+h, +l}:
      w64.bits.of(Nat.is_le(32n, sh), h, l, sh, n)

# the bits low bits of a, sign-extended (bits from 1 to 64)
def w64.sext.of(neg: Bool, a: W64, +bits: Nat) -> W64:
  match neg:
    case True{}:
      w64.or(a, w64.not(w64.low(bits)))
    case False{}:
      a

def w64.sext(a: W64, +bits: Nat) -> W64:
  +x = w64.and(a, w64.low(bits))
  w64.sext.of(Bool.and(Nat.is_lt(bits, 64n), U32.is_eq(w64.bit(x, Nat.sub(bits, 1n)), 1)), x, bits)

# a word's decimal digits, unsigned: its value divided by 10^9 by long
# division over its four 16-bit limbs (no Nat past 10^9 * 2^16 is made),
# the quotient (below 2^35) and the remainder put together
def w64.digits(+q: Nat, +r: Nat) -> String:
  match q:
    case 0n:
      Nat.show(r)
    case 1n+p:
      +d = Nat.show(r)
      Nat.show(q) ++ String.repeat("0", Nat.sub(9n, String.length(d))) ++ d

def w64.ushow(+a: W64) -> String:
  match a:
    case W64{+h, +l}:
      +hn = U32.to_nat(h)
      +ln = U32.to_nat(l)
      +c1 = Nat.add(Nat.mul(Nat.mod(hn, 1000000000n), 65536n), Nat.div(ln, 65536n))
      +c0 = Nat.add(Nat.mul(Nat.mod(c1, 1000000000n), 65536n), Nat.mod(ln, 65536n))
      w64.digits(Nat.add(Nat.mul(Nat.add(Nat.mul(Nat.div(hn, 1000000000n), 65536n), Nat.div(c1, 1000000000n)), 65536n), Nat.div(c0, 1000000000n)), Nat.mod(c0, 1000000000n))

# a word as a long long's decimal text
def w64.show.of(neg: Bool, +a: W64) -> String:
  match neg:
    case True{}:
      "-" ++ w64.ushow(w64.neg(a))
    case False{}:
      w64.ushow(a)

def w64.show(+a: W64) -> String:
  w64.show.of(w64.is_neg(a), a)

# the digits of a decimal string into a word, wrapping
def w64.read.go(s: String, acc: W64) -> W64:
  match s:
    case SNil{}:
      acc
    case SCon{Chr{+c}, t}:
      +x = acc
      +x2 = w64.shl1(x, 0)
      w64.read.go(t, w64.add(w64.add(w64.shl1(w64.shl1(x2, 0), 0), x2), W64{0, U32.sub(c, 48)}))

# a long long's word, from its text, which ll.read has read as one, its
# magnitude hi * 10^9 + lo: below 10^9 (hi 0) the word of lo, else of
# the digits
def w64.mag(small: Bool, +lo: Nat, +s: String) -> W64:
  match small:
    case True{}:
      W64{0, U32.from_nat(lo)}
    case False{}:
      w64.read.go(s, w64.zero())

def w64.read(+s: String, neg: Bool, +hi: Nat, +lo: Nat) -> W64:
  match neg:
    case True{}:
      w64.neg(w64.mag(Nat.is_eq(hi, 0n), lo, String.drop(s, 1n)))
    case False{}:
      w64.mag(Nat.is_eq(hi, 0n), lo, s)

# BITFIELD's operations (BfOp, Types) as they read, a word at a time: a
# subcommand next (with the words left after it, which it must have),
# OVERFLOW's word, a type, an offset, a value, or an error, as Redis
# checks each in turn
type BfSt is Data:
  BfWord{ow: Nat, wr: Bool, acc: List<&2, BfOp>}
  BfOw{wr: Bool, acc: List<&2, BfOp>}
  BfTy{op: Nat, ow: Nat, wr: Bool, acc: List<&2, BfOp>}
  BfOff{op: Nat, sign: Bool, bits: Nat, ow: Nat, wr: Bool, acc: List<&2, BfOp>}
  BfVal{op: Nat, sign: Bool, bits: Nat, off: Nat, ow: Nat, wr: Bool, acc: List<&2, BfOp>}
  BfErr{r: Reply}

def bf.e_type() -> Reply:
  RError{"ERR Invalid bitfield type. Use something like i16 u8. Note that u64 is not supported but i64 is."}

def bf.e_off() -> Reply:
  RError{"ERR bit offset is not an integer or out of range"}

# whether l has n items at least
def bf.has(n: Nat, +l: List<&2, String>) -> Bool:
  match n l:
    case 0n _:
      True{}
    case 1n+m Con{x, t}:
      bf.has(m, t)
    case 1n+m Nil{}:
      False{}

# a subcommand (is it GET, SET, INCRBY, OVERFLOW?) with the words rest
# after it, which must be as many as it takes
def bf.word(isget: Bool, isset: Bool, isincr: Bool, isow: Bool, +rest: List<&2, String>, ow: Nat, wr: Bool, acc: List<&2, BfOp>) -> BfSt:
  match isget isset isincr isow:
    case True{} _ _ _:
      Bool.pick(BfSt, bf.has(2n, rest), BfTy{0n, ow, wr, acc}, BfErr{RError{"ERR syntax error"}})
    case False{} True{} _ _:
      Bool.pick(BfSt, bf.has(3n, rest), BfTy{1n, ow, wr, acc}, BfErr{RError{"ERR syntax error"}})
    case False{} False{} True{} _:
      Bool.pick(BfSt, bf.has(3n, rest), BfTy{2n, ow, wr, acc}, BfErr{RError{"ERR syntax error"}})
    case False{} False{} False{} True{}:
      Bool.pick(BfSt, bf.has(1n, rest), BfOw{wr, acc}, BfErr{RError{"ERR syntax error"}})
    case False{} False{} False{} False{}:
      BfErr{RError{"ERR syntax error"}}

def bf.word.of(+u: String, +rest: List<&2, String>, ow: Nat, wr: Bool, acc: List<&2, BfOp>) -> BfSt:
  bf.word(String.eq(u, "GET"), String.eq(u, "SET"), String.eq(u, "INCRBY"), String.eq(u, "OVERFLOW"), rest, ow, wr, acc)

def bf.ow(+u: String, +wr: Bool, +acc: List<&2, BfOp>) -> BfSt:
  Bool.pick(BfSt, String.eq(u, "WRAP"), BfWord{0n, wr, acc},
  Bool.pick(BfSt, String.eq(u, "SAT"), BfWord{1n, wr, acc},
  Bool.pick(BfSt, String.eq(u, "FAIL"), BfWord{2n, wr, acc}, BfErr{RError{"ERR Invalid OVERFLOW type specified"}})))

# a type: 'i' or 'u', then its bits as string2ll reads them, up to a NUL,
# from 1 to 64 (63 unsigned): a short number (num14), as one that
# string2ll reads and num14 does not is below 1 or past 64
def bf.ty.of(+sign: Bool, m: Maybe<&2, Nat>, +op: Nat, +ow: Nat, wr: Bool, acc: List<&2, BfOp>) -> BfSt:
  match m:
    case Some{+n}:
      Bool.pick(BfSt, Bool.and(Nat.is_le(1n, n), Nat.is_le(n, Bool.pick(Nat, sign, 64n, 63n))), BfOff{op, sign, n, ow, wr, acc}, BfErr{bf.e_type()})
    case None{}:
      BfErr{bf.e_type()}

def bf.ty(+t: String, +op: Nat, +ow: Nat, wr: Bool, acc: List<&2, BfOp>) -> BfSt:
  +c = String.code_at(t, 0n)
  +d = cstr(String.drop(t, 1n))
  Bool.pick(BfSt, Bool.or(U32.is_eq(c, 105), U32.is_eq(c, 117)),
    bf.ty.of(U32.is_eq(c, 105), num14(d, 0n, 0n, False{}, nch(d)), op, ow, wr, acc), BfErr{bf.e_type()})

# an offset: a long long (#k: k times the bits, wrapping as C's does),
# at least 0 and below 2^32 (a byte below proto-max-bulk-len, 512MB). A
# short one (num14) needs no word: its product with the bits (64 at most)
# is made only below 2^32, a Nat below 2^38 then
def bf.off.ok(+x: W64) -> Maybe<&2, Nat>:
  match x:
    case W64{+h, +l}:
      Bool.pick(Maybe<&2, Nat>, U32.is_eq(h, 0), Some{U32.to_nat(l)}, None{})

def bf.off.mul(hash: Bool, +x: W64, +bits: Nat) -> W64:
  match hash:
    case True{}:
      w64.mul(x, bits, w64.zero())
    case False{}:
      x

def bf.off.word(l: LL, +s: String, +hash: Bool, +bits: Nat) -> Maybe<&2, Nat>:
  match l:
    case LL{+neg, +hi, +lo}:
      bf.off.ok(bf.off.mul(hash, w64.read(s, neg, hi, lo), bits))
    case LLBad{}:
      None{}

def bf.off.hash(small: Bool, +n: Nat, +bits: Nat) -> Maybe<&2, Nat>:
  match small:
    case True{}:
      +x = Nat.mul(n, bits)
      Bool.pick(Maybe<&2, Nat>, Nat.is_le(x, 4294967295n), Some{x}, None{})
    case False{}:
      None{}

def bf.off.n(+hash: Bool, +n: Nat, +bits: Nat) -> Maybe<&2, Nat>:
  +small = Nat.is_le(n, 4294967295n)
  Bool.pick(Maybe<&2, Nat>, hash, bf.off.hash(small, n, bits), Bool.pick(Maybe<&2, Nat>, small, Some{n}, None{}))

def bf.off.of(m: Maybe<&2, Nat>, +t: String, +hash: Bool, +bits: Nat) -> Maybe<&2, Nat>:
  match m:
    case Some{+n}:
      bf.off.n(hash, n, bits)
    case None{}:
      bf.off.word(ll.read(t), t, hash, bits)

def bf.off(+s: String, +bits: Nat) -> Maybe<&2, Nat>:
  +hash = U32.is_eq(String.code_at(s, 0n), 35)
  +t = Bool.pick(String, hash, String.drop(s, 1n), s)
  bf.off.of(num14(t, 0n, 0n, False{}, nch(t)), t, hash, bits)

def bf.off.st(m: Maybe<&2, Nat>, +op: Nat, +sign: Bool, +bits: Nat, +ow: Nat, wr: Bool, +acc: List<&2, BfOp>) -> BfSt:
  match m:
    case Some{+off}:
      Bool.pick(BfSt, Nat.is_eq(op, 0n), BfWord{ow, wr, BfGet{sign, bits, off} <> acc}, BfVal{op, sign, bits, off, ow, True{}, acc})
    case None{}:
      BfErr{bf.e_off()}

# a value of SET or INCRBY: a long long. A short one (num14; after a '-',
# above 0, as string2ll refuses -0) is a Nat below 2^47, its word its
# halves; any other is read as ll.read reads it
def bf.v.put(+v: W64, +op: Nat, +sign: Bool, +bits: Nat, +off: Nat, +ow: Nat, acc: List<&2, BfOp>) -> BfSt:
  BfWord{ow, True{}, Bool.pick(BfOp, Nat.is_eq(op, 1n), BfSet{sign, bits, off, v, ow}, BfIncr{sign, bits, off, v, ow}) <> acc}

def bf.val.st(l: LL, +s: String, +op: Nat, +sign: Bool, +bits: Nat, +off: Nat, +ow: Nat, acc: List<&2, BfOp>) -> BfSt:
  match l:
    case LL{+neg, +hi, +lo}:
      bf.v.put(w64.read(s, neg, hi, lo), op, sign, bits, off, ow, acc)
    case LLBad{}:
      BfErr{e_int()}

def bf.v.nat(+n: Nat) -> W64:
  +b = Nat.mul(65536n, 65536n)
  W64{U32.from_nat(Nat.div(n, b)), U32.from_nat(Nat.mod(n, b))}

def bf.v.neg(neg: Bool, +n: Nat) -> W64:
  match neg:
    case True{}:
      w64.neg(bf.v.nat(n))
    case False{}:
      bf.v.nat(n)

def bf.v.of(m: Maybe<&2, Nat>, +neg: Bool, +s: String, +op: Nat, +sign: Bool, +bits: Nat, +off: Nat, +ow: Nat, acc: List<&2, BfOp>) -> BfSt:
  match m:
    case Some{+n}:
      bf.v.put(bf.v.neg(neg, n), op, sign, bits, off, ow, acc)
    case None{}:
      bf.val.st(ll.read(s), s, op, sign, bits, off, ow, acc)

def bf.v.pos(m: Maybe<&2, Nat>) -> Maybe<&2, Nat>:
  match m:
    case Some{+n}:
      Bool.pick(Maybe<&2, Nat>, Nat.is_eq(n, 0n), None{}, Some{n})
    case None{}:
      None{}

def bf.v.short(+neg: Bool, +t: String) -> Maybe<&2, Nat>:
  +m = num14(t, 0n, 0n, False{}, nch(t))
  Bool.pick(Maybe<&2, Nat>, neg, bf.v.pos(m), m)

def bf.value(+a: String, +op: Nat, +sign: Bool, +bits: Nat, +off: Nat, +ow: Nat, acc: List<&2, BfOp>) -> BfSt:
  +neg = U32.is_eq(String.code_at(a, 0n), 45)
  bf.v.of(bf.v.short(neg, Bool.pick(String, neg, String.drop(a, 1n), a)), neg, a, op, sign, bits, off, ow, acc)

def bf.step(st: BfSt, +a: String, +rest: List<&2, String>) -> BfSt:
  match st:
    case BfWord{+ow, wr, acc}:
      bf.word.of(String.to_upper(cstr(a)), rest, ow, wr, acc)
    case BfOw{wr, acc}:
      bf.ow(String.to_upper(cstr(a)), wr, acc)
    case BfTy{+op, +ow, wr, acc}:
      bf.ty(a, op, ow, wr, acc)
    case BfOff{+op, +sign, +bits, +ow, wr, acc}:
      bf.off.st(bf.off(a, bits), op, sign, bits, ow, wr, acc)
    case BfVal{+op, +sign, +bits, +off, +ow, wr, acc}:
      bf.value(a, op, sign, bits, off, ow, acc)
    case BfErr{r}:
      BfErr{r}

def bf.go(args: List<&2, String>, st: BfSt) -> BfSt:
  match args:
    case Nil{}:
      st
    case Con{+a, +rest}:
      bf.go(rest, bf.step(st, a, rest))

# the command: a read of the key when no operation writes (BITFIELD_RO,
# ro, refuses one that does), else an update of it
def bf.cmd(st: BfSt, +k: String, ro: Bool) -> Cmd:
  match st ro:
    case BfWord{ow, False{}, acc} _:
      Peek{k, PBitfield{List.reverse(&2, BfOp, acc)}}
    case BfWord{ow, True{}, acc} False{}:
      Upd{k, UBitfield{List.reverse(&2, BfOp, acc)}}
    case BfWord{ow, True{}, acc} True{}:
      Bad{RError{"ERR BITFIELD_RO only supports the GET subcommand"}}
    case BfErr{r} _:
      Bad{r}
    case _ _:
      Bad{RError{"ERR syntax error"}}

def parse_bitfield(+k: String, args: List<&2, String>, ro: Bool) -> Cmd:
  bf.cmd(bf.go(args, BfWord{0n, False{}, Nil{}}), k, ro)

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

# Ranges and bits
# ---------------
# GETRANGE (and SUBSTR, its old name), SETRANGE, GETBIT, SETBIT, BITCOUNT
# and BITPOS read their numbers as Redis 7.0.15 does, each a long long
# (string2ll, ll.read), and answer an error for one where Redis does:
# GETRANGE reads its range before it looks for its key, BITCOUNT and
# BITPOS theirs only once they find the key (BITPOS its bit before). So
# GETRANGE's arguments are checked here and kept as they came, as are
# BITCOUNT's and BITPOS's, and exec reads them again (Execution: Ranges),
# so that a command stays a word wide for them (Types). SETRANGE's offset
# is a Nat below 10^14 (num14; one of 10^14 or more acts as 2^29 + 1
# does, past 512MB, the most a value may hold: proto-max-bulk-len, which
# BendKV keeps at Redis's default); a bit's offset is below 2^32, the
# bits of 512MB.

def e_offset() -> Reply:
  RError{"ERR offset is out of range"}

def e_bitoff() -> Reply:
  RError{"ERR bit offset is not an integer or out of range"}

def ll.bad(l: LL) -> Bool:
  match l:
    case LL{neg, hi, lo}:
      False{}
    case LLBad{}:
      True{}

# whether s is a long long
def ll.is(+s: String) -> Bool:
  Bool.not(ll.bad(ll.read(s)))

# GETRANGE key start end
def parse_getrange(+k: String, +a: String, +b: String) -> Cmd:
  Bool.pick(Cmd, Bool.and(ll.is(a), ll.is(b)), Peek{k, PRange{[a, b]}}, Bad{e_int()})

# SETRANGE key offset value: an offset of 14 digits or more, or below 0
def setrange.big(+k: String, l: LL, s: String) -> Cmd:
  match l:
    case LL{neg, hi, lo}:
      Bool.pick(Cmd, neg, Bad{e_offset()}, Upd{k, URange{536870913n, s}})
    case LLBad{}:
      Bad{e_int()}

def setrange.of(+k: String, m: Maybe<&2, Nat>, +o: String, s: String) -> Cmd:
  match m:
    case Some{off}:
      Upd{k, URange{off, s}}
    case None{}:
      setrange.big(k, ll.read(o), s)

def parse_setrange(+k: String, +o: String, s: String) -> Cmd:
  setrange.of(k, num14(o, 0n, 0n, False{}, nch(o)), o, s)

# a bit's offset, below 2^32; None for none
def bitoff.of(m: Maybe<&2, Nat>) -> Maybe<&2, Nat>:
  match m:
    case Some{+n}:
      Bool.pick(Maybe<&2, Nat>, Nat.is_lt(n, Nat.mul(65536n, 65536n)), Some{n}, None{})
    case None{}:
      None{}

def bitoff(+o: String) -> Maybe<&2, Nat>:
  bitoff.of(num14(o, 0n, 0n, False{}, nch(o)))

# GETBIT key offset
def parse_getbit(+k: String, m: Maybe<&2, Nat>) -> Cmd:
  match m:
    case Some{off}:
      Peek{k, PGetBit{off}}
    case None{}:
      Bad{e_bitoff()}

# SETBIT key offset bit: the offset is read first, then the bit, 0 or 1
def setbit.cmd(+k: String, +off: Nat, +b: String) -> Cmd:
  Bool.pick(Cmd, String.eq(b, "1"), Upd{k, USetBit{off, True{}}},
    Bool.pick(Cmd, String.eq(b, "0"), Upd{k, USetBit{off, False{}}}, Bad{RError{"ERR bit is not an integer or out of range"}}))

def parse_setbit(+k: String, m: Maybe<&2, Nat>, +b: String) -> Cmd:
  match m:
    case Some{+off}:
      setbit.cmd(k, off, b)
    case None{}:
      Bad{e_bitoff()}

# BITPOS key bit [start [end [BYTE|BIT]]]: the bit is read before the key
# is looked for, an integer, then 0 or 1
def parse_bitpos(+k: String, +b: String, rest: List<&2, String>) -> Cmd:
  Bool.pick(Cmd, Bool.or(String.eq(b, "0"), String.eq(b, "1")), Peek{k, PPos{b <> rest}},
    Bool.pick(Cmd, ll.is(b), Bad{RError{"ERR The bit argument must be 1 or 0."}}, Bad{e_int()}))

# Hashes: HSET's (and HMSET's) arguments after the key are field-value
# pairs, a field without its value a wrong number of arguments (Redis
# checks it in the command, so the call counts as failed); HINCRBY's
# increment and HSCAN's cursor are read as the command parses, before the
# key is looked for, as Redis reads them
def hpairs.cons(p: KV.HPair, m: Maybe<&2, List<&2, KV.HPair>>) -> Maybe<&2, List<&2, KV.HPair>>:
  match m:
    case Some{ps}:
      Some{Con{p, ps}}
    case None{}:
      None{}

def hpairs(xs: List<&2, String>) -> Maybe<&2, List<&2, KV.HPair>>:
  match xs:
    case Nil{}:
      Some{Nil{}}
    case Con{f, Con{v, rest}}:
      hpairs.cons(KV.HP{f, v}, hpairs(rest))
    case Con{f, Nil{}}:
      None{}

def parse_hset.of(+k: String, m: Maybe<&2, List<&2, KV.HPair>>, mset: Bool, name: String) -> Cmd:
  match m:
    case Some{ps}:
      Upd{k, UHash{HWSet{ps, mset}}}
    case None{}:
      e_arity(name)

def parse_hset(args: List<&2, String>, mset: Bool, name: String) -> Cmd:
  match args:
    case Con{+k, Con{f, Con{v, rest}}}:
      parse_hset.of(k, hpairs(f <> v <> rest), mset, name)
    case _:
      e_arity(name)

def parse_hincrby(+k: String, +f: String, by: Maybe<&2, Int>) -> Cmd:
  match by:
    case Some{n}:
      Upd{k, UHash{HWIncr{f, n}}}
    case None{}:
      Bad{e_int()}

# HINCRBYFLOAT's increment, read as a long double before the key is
# looked for, an infinity refused, as Redis reads it
def parse_hincrbyfloat.of(inf: Bool, +k: String, +f: String, x: F.Fl) -> Cmd:
  match inf:
    case True{}:
      Bad{RError{"ERR value is NaN or Infinity"}}
    case False{}:
      Upd{k, UHash{HWIncrF{f, x}}}

def parse_hincrbyfloat(+k: String, +f: String, by: Maybe<&2, F.Fl>) -> Cmd:
  match by:
    case Some{+x}:
      parse_hincrbyfloat.of(F.fl.is_inf(x), k, f, x)
    case None{}:
      Bad{RError{"ERR value is not a valid float"}}

def parse_hscan(+k: String, +c: String, rest: List<&2, String>) -> Cmd:
  Bool.pick(Cmd, Maybe.is_some(&2, Nat, scan.cursor(c)), Peek{k, PHash{HRScan{c <> rest}}}, Bad{RError{"ERR invalid cursor"}})

# LMOVE's ends (LEnds): where it pops, where it pushes, whether it
# deletes the destination first, and the New form of each
def ends.from(+e: LEnds) -> Bool:
  match e:
    case LtoL{}:
      True{}
    case LtoR{}:
      True{}
    case LtoLNew{}:
      True{}
    case LtoRNew{}:
      True{}
    case _:
      False{}

def ends.to(+e: LEnds) -> Bool:
  match e:
    case LtoL{}:
      True{}
    case RtoL{}:
      True{}
    case LtoLNew{}:
      True{}
    case RtoLNew{}:
      True{}
    case _:
      False{}

def ends.fresh(+e: LEnds) -> Bool:
  match e:
    case LtoLNew{}:
      True{}
    case LtoRNew{}:
      True{}
    case RtoLNew{}:
      True{}
    case RtoRNew{}:
      True{}
    case _:
      False{}

# the New form of the ends e
def ends.new(+e: LEnds) -> LEnds:
  match e:
    case LtoL{}:
      LtoLNew{}
    case LtoR{}:
      LtoRNew{}
    case RtoL{}:
      RtoLNew{}
    case RtoR{}:
      RtoRNew{}
    case _:
      e

# an end of a list, as Redis reads one: 1 LEFT, 2 RIGHT, 0 another word
def lend.word(+w: String) -> Nat:
  Bool.pick(Nat, is_word(w, "LEFT"), 1n, Bool.pick(Nat, is_word(w, "RIGHT"), 2n, 0n))

def lends.of(a: Nat, b: Nat) -> Maybe<&2, LEnds>:
  match a b:
    case 1n 1n:
      Some{LtoL{}}
    case 1n 2n:
      Some{LtoR{}}
    case 2n 1n:
      Some{RtoL{}}
    case 2n 2n:
      Some{RtoR{}}
    case _ _:
      None{}

# Sorted sets: ZADD's options come before its pairs, in any case and
# order, each as often as it comes, as Redis reads them up to the first
# word that is none of them; then come pairs of a score and a member, one
# at least (else a syntax error). Then, in Redis's order: NX goes with
# neither XX nor GT nor LT, nor GT with LT; INCR takes one pair alone;
# every score reads as a double (string2d: F.f64.parse). The write checks
# them all again as it runs (zadd.check), so that a write that runs is
# one the parser takes; it also checks that the first score is none of
# the options' words, which no score that reads as a double is.

# an option's word: 1 NX, 2 XX, 3 GT, 4 LT, 5 CH, 6 INCR, 0 another
def zopt.word(+w: String) -> Nat:
  +up = String.to_upper(cstr(w))
  Bool.pick(Nat, String.eq(up, "NX"), 1n, Bool.pick(Nat, String.eq(up, "XX"), 2n, Bool.pick(Nat, String.eq(up, "GT"), 3n, Bool.pick(Nat, String.eq(up, "LT"), 4n, Bool.pick(Nat, String.eq(up, "CH"), 5n, Bool.pick(Nat, String.eq(up, "INCR"), 6n, 0n))))))

def zopt.head(+xs: List<&2, String>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case Con{+w, r}:
      zopt.word(w)

def zopts.none() -> ZOpts:
  ZOpts{False{}, False{}, False{}, False{}, False{}, False{}}

def zopts.incr() -> ZOpts:
  ZOpts{False{}, False{}, False{}, False{}, False{}, True{}}

def zopts.xx(+o: ZOpts) -> Bool:
  match o:
    case ZOpts{nx, +xx, gt, lt, ch, incr}:
      xx

def zopts.one(b: Bool) -> Nat:
  match b:
    case True{}:
      1n
    case False{}:
      0n

# how many options o has
def zopts.count(+o: ZOpts) -> Nat:
  match o:
    case ZOpts{+nx, +xx, +gt, +lt, +ch, +incr}:
      Nat.add(Nat.add(Nat.add(zopts.one(nx), zopts.one(xx)), Nat.add(zopts.one(gt), zopts.one(lt))), Nat.add(zopts.one(ch), zopts.one(incr)))

# o with the option of word c set
def zopts.set(c: Nat, o: ZOpts) -> ZOpts:
  match c o:
    case 1n ZOpts{nx, xx, gt, lt, ch, incr}:
      ZOpts{True{}, xx, gt, lt, ch, incr}
    case 2n ZOpts{nx, xx, gt, lt, ch, incr}:
      ZOpts{nx, True{}, gt, lt, ch, incr}
    case 3n ZOpts{nx, xx, gt, lt, ch, incr}:
      ZOpts{nx, xx, True{}, lt, ch, incr}
    case 4n ZOpts{nx, xx, gt, lt, ch, incr}:
      ZOpts{nx, xx, gt, True{}, ch, incr}
    case 5n ZOpts{nx, xx, gt, lt, ch, incr}:
      ZOpts{nx, xx, gt, lt, True{}, incr}
    case 6n ZOpts{nx, xx, gt, lt, ch, incr}:
      ZOpts{nx, xx, gt, lt, ch, True{}}
    case _ p:
      p

# the options before ZADD's pairs, set in o, and the words after them; c
# is the first word's option (0 for none)
def zadd.opts.go(xs: List<&2, String>, c: Nat, o: ZOpts) -> ZOpts & List<&2, String>:
  match xs c:
    case Con{w, +rest} 1n+p:
      zadd.opts.go(rest, zopt.head(rest), zopts.set(1n+p, o))
    case ys _:
      (o, ys)

def zadd.opts(+xs: List<&2, String>) -> ZOpts & List<&2, String>:
  zadd.opts.go(xs, zopt.head(xs), zopts.none())

def zpairs.cons(p: ZPair, m: Maybe<&2, List<&2, ZPair>>) -> Maybe<&2, List<&2, ZPair>>:
  match m:
    case Some{ps}:
      Some{Con{p, ps}}
    case None{}:
      None{}

# the words as pairs of a score and a member (None for an odd number)
def zpairs(xs: List<&2, String>) -> Maybe<&2, List<&2, ZPair>>:
  match xs:
    case Nil{}:
      Some{Nil{}}
    case Con{s, Con{m, rest}}:
      zpairs.cons(ZPair{s, m}, zpairs(rest))
    case Con{s, Nil{}}:
      None{}

# whether every score reads as a double
def zpairs.ok(+ps: List<&2, ZPair>) -> Bool:
  match ps:
    case Nil{}:
      True{}
    case Con{ZPair{+s, m}, +rest}:
      Bool.and(Maybe.is_some(&2, F.F64, F.f64.parse(s)), zpairs.ok(rest))

# whether there is a pair, and its score is none of the options' words
def zpairs.first(+ps: List<&2, ZPair>) -> Bool:
  match ps:
    case Nil{}:
      False{}
    case Con{ZPair{+s, m}, rest}:
      Nat.is_eq(zopt.word(s), 0n)

def zadd.check.of(first: Bool, nxx: Bool, gtl: Bool, many: Bool, ok: Bool) -> Maybe<&2, Reply>:
  match first nxx gtl many ok:
    case False{} _ _ _ _:
      Some{RError{"ERR syntax error"}}
    case True{} True{} _ _ _:
      Some{RError{"ERR XX and NX options at the same time are not compatible"}}
    case True{} False{} True{} _ _:
      Some{RError{"ERR GT, LT, and/or NX options at the same time are not compatible"}}
    case True{} False{} False{} True{} _:
      Some{RError{"ERR INCR option supports a single increment-element pair"}}
    case True{} False{} False{} False{} False{}:
      Some{RError{"ERR value is not a valid float"}}
    case True{} False{} False{} False{} True{}:
      None{}

# ZADD's options and pairs, checked as Redis checks them, in its order:
# None when they are fine, else the error
def zadd.check(+o: ZOpts, +ps: List<&2, ZPair>) -> Maybe<&2, Reply>:
  match o:
    case ZOpts{+nx, +xx, +gt, +lt, ch, +incr}:
      zadd.check.of(zpairs.first(ps), Bool.and(nx, xx), Bool.or(Bool.and(Bool.or(gt, lt), nx), Bool.and(gt, lt)), Bool.and(incr, Nat.is_lt(1n, List.length(&2, ZPair, ps))), zpairs.ok(ps))

def parse_zadd.ok(c: Maybe<&2, Reply>, k: String, o: ZOpts, ps: List<&2, ZPair>) -> Cmd:
  match c:
    case None{}:
      Upd{k, UZset{ZWAdd{o, ps}}}
    case Some{r}:
      Bad{r}

def parse_zadd.of(+k: String, m: Maybe<&2, List<&2, ZPair>>, +o: ZOpts) -> Cmd:
  match m:
    case Some{+ps}:
      parse_zadd.ok(zadd.check(o, ps), k, o, ps)
    case None{}:
      e_syntax()

def parse_zadd.at(+k: String, p: ZOpts & List<&2, String>) -> Cmd:
  (o, ws) = p
  parse_zadd.of(k, zpairs(ws), o)

def parse_zadd(args: List<&2, String>) -> Cmd:
  match args:
    case Con{+k, Con{x, Con{y, rest}}}:
      parse_zadd.at(k, zadd.opts(x <> (y <> rest)))
    case _:
      e_arity("zadd")

def zpairs.one(s: String, m: String) -> List<&2, ZPair>:
  [ZPair{s, m}]

# ZINCRBY key increment member: ZADD with INCR, as Redis runs it, so an
# increment that is an option's word is read as that option, and leaves
# a member without its score (a syntax error)
def parse_zincrby.of(ok: Bool, +k: String, n: String, m: String) -> Cmd:
  match ok:
    case True{}:
      +o = zopts.incr()
      +ps = zpairs.one(n, m)
      parse_zadd.ok(zadd.check(o, ps), k, o, ps)
    case False{}:
      e_syntax()

def parse_zincrby(args: List<&2, String>) -> Cmd:
  match args:
    case Con{+k, Con{+n, Con{m, Nil{}}}}:
      parse_zincrby.of(Nat.is_eq(zopt.word(n), 0n), k, n, m)
    case _:
      e_arity("zincrby")

# A bound of a range of scores, as zslParseRange reads one: '(' first for
# one left out, then a double as strtod reads it (F.f64.parse_range); of
# members, as zslParseLexRangeItem reads one: '+' or '-' alone (as C
# reads it, up to a NUL), or '[' (taken in) or '(' (left out) and a
# member.
def zsb.parse.of(m: Maybe<&2, F.F64>, ex: Bool) -> Maybe<&2, KV.ZSB>:
  match m:
    case Some{d}:
      Some{KV.ZSB{d, ex}}
    case None{}:
      None{}

def zsb.parse(+s: String) -> Maybe<&2, KV.ZSB>:
  +ex = U32.is_eq(String.code_at(s, 0n), 40)
  zsb.parse.of(F.f64.parse_range(Bool.pick(String, ex, String.drop(s, 1n), s)), ex)

def zlb.parse.of(+c: U32, +alone: Bool, +s: String) -> Maybe<&2, KV.ZLB>:
  Bool.pick(Maybe<&2, KV.ZLB>, U32.is_eq(c, 40), Some{KV.ZLEx{String.drop(s, 1n)}},
    Bool.pick(Maybe<&2, KV.ZLB>, U32.is_eq(c, 91), Some{KV.ZLIn{String.drop(s, 1n)}},
      Bool.pick(Maybe<&2, KV.ZLB>, Bool.and(U32.is_eq(c, 43), alone), Some{KV.ZLPos{}},
        Bool.pick(Maybe<&2, KV.ZLB>, Bool.and(U32.is_eq(c, 45), alone), Some{KV.ZLNeg{}}, None{}))))

def zlb.parse(+s: String) -> Maybe<&2, KV.ZLB>:
  zlb.parse.of(String.code_at(s, 0n), Bool.or(Nat.is_eq(String.length(s), 1n), U32.is_eq(String.code_at(s, 1n), 0)), s)

def zrng.rank(ma: Maybe<&2, Int>, mb: Maybe<&2, Int>) -> Maybe<&2, ZRng>:
  match ma mb:
    case Some{a} Some{b}:
      Some{ZRankR{a, b}}
    case _ _:
      None{}

def zrng.score(ma: Maybe<&2, KV.ZSB>, mb: Maybe<&2, KV.ZSB>) -> Maybe<&2, ZRng>:
  match ma mb:
    case Some{a} Some{b}:
      Some{ZScoreR{a, b}}
    case _ _:
      None{}

def zrng.lex(ma: Maybe<&2, KV.ZLB>, mb: Maybe<&2, KV.ZLB>) -> Maybe<&2, ZRng>:
  match ma mb:
    case Some{a} Some{b}:
      Some{ZLexR{a, b}}
    case _ _:
      None{}

# a range of kind k (1 by rank, 2 by score, 3 by member) of bounds a and
# b, as Redis reads it, and the error of one that does not read
def zrng.of(+k: Nat, +a: String, +b: String) -> Maybe<&2, ZRng>:
  match k:
    case 2n:
      zrng.score(zsb.parse(a), zsb.parse(b))
    case 3n:
      zrng.lex(zlb.parse(a), zlb.parse(b))
    case _:
      zrng.rank(lnum(a), lnum(b))

def zrng.err(+k: Nat) -> Reply:
  match k:
    case 2n:
      RError{"ERR min or max is not a float"}
    case 3n:
      RError{"ERR min or max not valid string range item"}
    case _:
      e_int()

def parse_zcount.of(m: Maybe<&2, ZRng>, +k: Nat, key: String, a: String, b: String) -> Cmd:
  match m:
    case Some{ZScoreR{lo, hi}}:
      Peek{key, PZset{ZRCount{[a, b]}}}
    case Some{ZLexR{lo, hi}}:
      Peek{key, PZset{ZRLexCount{[a, b]}}}
    case _:
      Bad{zrng.err(k)}

# ZCOUNT (k 2) and ZLEXCOUNT (k 3): a key and a range
def parse_zcount(args: List<&2, String>, +k: Nat, name: String) -> Cmd:
  match args:
    case Con{key, Con{+a, Con{+b, Nil{}}}}:
      parse_zcount.of(zrng.of(k, a, b), k, key, a, b)
    case _:
      e_arity(name)

# ZRANGE's options as Redis reads them, in turn (zrangeGenericCommand):
# WITHSCORES (not for ZRANGESTORE: store), LIMIT and two longs (offset
# and count), REV (where the command leaves the direction to them),
# BYSCORE or BYLEX (where it leaves the kind to them, and only once); any
# other word, or LIMIT with fewer than two words after it, is a syntax
# error, and a LIMIT that does not read as two longs answers that at
# once. dir is 0 (not given), 1 forward, 2 reverse; kind is 0 (not
# given), 1 by rank, 2 by score, 3 by member.
type ZqSt is Data:
  ZqSt{ws: Bool, off: Int, cnt: Int, dir: Nat, kind: Nat}
  ZqErr{r: Reply}

# a word of ZRANGE's options: 1 WITHSCORES, 2 LIMIT, 3 REV, 4 BYSCORE,
# 5 BYLEX, 0 another
def zq.word(+w: String) -> Nat:
  +up = String.to_upper(cstr(w))
  Bool.pick(Nat, String.eq(up, "WITHSCORES"), 1n, Bool.pick(Nat, String.eq(up, "LIMIT"), 2n, Bool.pick(Nat, String.eq(up, "REV"), 3n, Bool.pick(Nat, String.eq(up, "BYSCORE"), 4n, Bool.pick(Nat, String.eq(up, "BYLEX"), 5n, 0n)))))

def zq.head(+xs: List<&2, String>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case Con{+w, r}:
      zq.word(w)

def zq.ws(store: Bool, off: Int, cnt: Int, dir: Nat, kind: Nat) -> ZqSt:
  match store:
    case True{}:
      ZqErr{RError{"ERR syntax error"}}
    case False{}:
      ZqSt{True{}, off, cnt, dir, kind}

def zq.limit(ma: Maybe<&2, Int>, mb: Maybe<&2, Int>, ws: Bool, dir: Nat, kind: Nat) -> ZqSt:
  match ma mb:
    case Some{a} Some{b}:
      ZqSt{ws, a, b, dir, kind}
    case _ _:
      ZqErr{e_int()}

def zq.rev(dir: Nat, ws: Bool, off: Int, cnt: Int, kind: Nat) -> ZqSt:
  match dir:
    case 0n:
      ZqSt{ws, off, cnt, 2n, kind}
    case _:
      ZqErr{RError{"ERR syntax error"}}

def zq.kind(kind: Nat, +k: Nat, ws: Bool, off: Int, cnt: Int, dir: Nat) -> ZqSt:
  match kind:
    case 0n:
      ZqSt{ws, off, cnt, dir, k}
    case _:
      ZqErr{RError{"ERR syntax error"}}

# the options xs read into st; c is the first word's (zq.word)
def zq.go(xs: List<&2, String>, c: Nat, st: ZqSt, +store: Bool) -> ZqSt:
  match xs c st:
    case _ _ ZqErr{r}:
      ZqErr{r}
    case Nil{} _ s:
      s
    case Con{w, +rest} 1n ZqSt{ws, off, cnt, dir, kind}:
      zq.go(rest, zq.head(rest), zq.ws(store, off, cnt, dir, kind), store)
    case Con{w, Con{+a, Con{+b, +rest}}} 2n ZqSt{ws, off, cnt, dir, kind}:
      zq.go(rest, zq.head(rest), zq.limit(lnum(a), lnum(b), ws, dir, kind), store)
    case Con{w, +rest} 3n ZqSt{ws, off, cnt, dir, kind}:
      zq.go(rest, zq.head(rest), zq.rev(dir, ws, off, cnt, kind), store)
    case Con{w, +rest} 4n ZqSt{ws, off, cnt, dir, kind}:
      zq.go(rest, zq.head(rest), zq.kind(kind, 2n, ws, off, cnt, dir), store)
    case Con{w, +rest} 5n ZqSt{ws, off, cnt, dir, kind}:
      zq.go(rest, zq.head(rest), zq.kind(kind, 3n, ws, off, cnt, dir), store)
    case _ _ _:
      ZqErr{RError{"ERR syntax error"}}

# a range read, or the error it answers
type ZqOut is Data:
  ZqOk{q: ZQ}
  ZqBad{r: Reply}

# a read, from the last element when rev
def zq.dir(rev: Bool, q: ZQ) -> ZQ:
  match rev:
    case True{}:
      ZQRev{q}
    case False{}:
      q

def zq.mk(m: Maybe<&2, ZRng>, +k: Nat, rev: Bool, off: Int, cnt: Int, ws: Bool) -> ZqOut:
  match m:
    case Some{r}:
      ZqOk{zq.dir(rev, ZQ{r, off, cnt, ws})}
    case None{}:
      ZqBad{zrng.err(k)}

# whether a count is -1, which Redis takes for no LIMIT
def zq.nolimit(+c: Int) -> Bool:
  match c:
    case INeg{+n}:
      Nat.is_eq(n, 0n)
    case IPos{n}:
      False{}

def zq.check(lim: Bool, wsl: Bool, +k: Nat, +rev: Bool, off: Int, cnt: Int, ws: Bool, +a: String, +b: String) -> ZqOut:
  match lim wsl:
    case True{} _:
      ZqBad{RError{"ERR syntax error, LIMIT is only supported in combination with either BYSCORE or BYLEX"}}
    case False{} True{}:
      ZqBad{RError{"ERR syntax error, WITHSCORES not supported in combination with BYLEX"}}
    case False{} False{}:
      +sw = Bool.and(rev, Nat.is_lt(1n, k))
      zq.mk(zrng.of(k, Bool.pick(String, sw, b, a), Bool.pick(String, sw, a, b)), k, rev, off, cnt, ws)

# the options read, the range with them: the direction defaults to
# forward, the kind to by rank; LIMIT goes with a range by score or by
# member alone (a count of -1 counts as none, as Redis tells), WITHSCORES
# not with one by member; a reversed range by score or by member names its
# upper bound first; then the bounds are read
def zq.fin(st: ZqSt, +a: String, +b: String) -> ZqOut:
  match st:
    case ZqErr{r}:
      ZqBad{r}
    case ZqSt{+ws, off, +cnt, +dir, +kind}:
      +k = Bool.pick(Nat, Nat.is_eq(kind, 0n), 1n, kind)
      zq.check(Bool.and(Bool.not(zq.nolimit(cnt)), Nat.is_eq(k, 1n)), Bool.and(ws, Nat.is_eq(k, 3n)), k, Nat.is_eq(dir, 2n), off, cnt, ws, a, b)

# ZRANGE key a b [options], and its kin, which fix the direction (dir) or
# the kind (kind) where ZRANGE leaves them to its options (0)
def zq.read(+dir: Nat, +kind: Nat, +store: Bool, +a: String, +b: String, +rest: List<&2, String>) -> ZqOut:
  zq.fin(zq.go(rest, zq.head(rest), ZqSt{False{}, IPos{0n}, INeg{0n}, dir, kind}, store), a, b)

def parse_zrange.of(k: String, o: ZqOut) -> Cmd:
  match o:
    case ZqOk{q}:
      Peek{k, PZset{ZRRange{q}}}
    case ZqBad{r}:
      Bad{r}

def parse_zrange(args: List<&2, String>, +dir: Nat, +kind: Nat, name: String) -> Cmd:
  match args:
    case Con{k, Con{+a, Con{+b, +rest}}}:
      parse_zrange.of(k, zq.read(dir, kind, False{}, a, b, rest))
    case _:
      e_arity(name)

# ZREMRANGEBYRANK (k 1), ZREMRANGEBYSCORE (2) and ZREMRANGEBYLEX (3): a
# key and a range, read as the command parses and kept as it came
def zremr.op(+k: Nat, a: String, b: String) -> ZWrite:
  match k:
    case 2n:
      ZWRemScore{a, b}
    case 3n:
      ZWRemLex{a, b}
    case _:
      ZWRemRank{a, b}

def parse_zremrange.of(ok: Bool, +k: Nat, key: String, a: String, b: String) -> Cmd:
  match ok:
    case True{}:
      Upd{key, UZset{zremr.op(k, a, b)}}
    case False{}:
      Bad{zrng.err(k)}

def parse_zremrange(args: List<&2, String>, +k: Nat, name: String) -> Cmd:
  match args:
    case Con{key, Con{+a, Con{+b, Nil{}}}}:
      parse_zremrange.of(Maybe.is_some(&2, ZRng, zrng.of(k, a, b)), k, key, a, b)
    case _:
      e_arity(name)

# ZPOPMIN and ZPOPMAX (max): a key and a count at most, a long at least 0
# read as the command parses (Redis's error for one that is not is "out
# of range"); more is a syntax error
def parse_zpop.n(ok: Bool, k: String, +max: Bool, c: String) -> Cmd:
  match ok:
    case True{}:
      Upd{k, UZset{ZWPopN{max, c}}}
    case False{}:
      Bad{RError{"ERR value is out of range, must be positive"}}

def parse_zpop(args: List<&2, String>, +max: Bool, name: String) -> Cmd:
  match args:
    case Con{k, Nil{}}:
      Upd{k, UZset{ZWPop{max}}}
    case Con{k, Con{+c, Nil{}}}:
      parse_zpop.n(Maybe.is_some(&2, Nat, lcount(c)), k, max, c)
    case Con{k, Con{c, Con{x, rest}}}:
      e_syntax()
    case Nil{}:
      e_arity(name)

# ZSCAN's cursor is read as the command parses, as HSCAN's
def parse_zscan(+k: String, +c: String, rest: List<&2, String>) -> Cmd:
  Bool.pick(Cmd, Maybe.is_some(&2, Nat, scan.cursor(c)), Peek{k, PZset{ZRScan{c <> rest}}}, Bad{RError{"ERR invalid cursor"}})

# EVAL: BendKV runs no Lua scripts but the ones its append-only file
# writes (a new hash, list or set where a key whose time had passed
# still lay, aof.bend): EVAL <the script> 1 key HSET field value [field
# value ...], LPUSH (RPUSH) element [element ...], or SADD member
# [member ...], which deletes the key and runs the HSET (the pushes, the
# SADD), a thousand arguments a call, and returns 0, as Redis runs it
def hnew.script() -> String:
  "redis.call('del',KEYS[1]) local n=#ARGV for i=2,n,1000 do redis.call(ARGV[1],KEYS[1],unpack(ARGV,i,math.min(i+999,n))) end return 0"

def e_lua() -> Cmd:
  Bad{RError{"ERR BendKV runs no Lua scripts"}}

def parse_eval.of(ok: Bool, +k: String, m: Maybe<&2, List<&2, KV.HPair>>) -> Cmd:
  match ok m:
    case True{} Some{Con{p, ps}}:
      Upd{k, UHash{HWNew{p <> ps}}}
    case _ _:
      e_lua()

def parse_eval.list(ok: Bool, +k: String, +left: Bool, xs: List<&2, String>) -> Cmd:
  match ok xs:
    case True{} Con{x, rest}:
      Upd{k, UList{LWNew{left, x <> rest}}}
    case _ _:
      e_lua()

def parse_eval.set(ok: Bool, +k: String, xs: List<&2, String>) -> Cmd:
  match ok xs:
    case True{} Con{x, rest}:
      Upd{k, UMems{SWNew{x <> rest}}}
    case _ _:
      e_lua()

# the command the script runs: 1 HSET, 2 LPUSH, 3 RPUSH, 4 SADD, 0
# another
def parse_eval.w(w: Nat, ok: Bool, +k: String, rest: List<&2, String>) -> Cmd:
  match w:
    case 1n:
      parse_eval.of(ok, k, hpairs(rest))
    case 2n:
      parse_eval.list(ok, k, True{}, rest)
    case 3n:
      parse_eval.list(ok, k, False{}, rest)
    case 4n:
      parse_eval.set(ok, k, rest)
    case _:
      e_lua()

def parse_eval.one(ok: Bool, rest: List<&2, String>) -> Cmd:
  match rest:
    case Con{+k, Con{+w, more}}:
      parse_eval.w(Bool.pick(Nat, String.eq(w, "HSET"), 1n, Bool.pick(Nat, String.eq(w, "LPUSH"), 2n, Bool.pick(Nat, String.eq(w, "RPUSH"), 3n, Bool.pick(Nat, String.eq(w, "SADD"), 4n, 0n)))), ok, k, more)
    case _:
      e_lua()

# The script of a move to a key whose entry's time had passed: EVAL <it>
# 2 src dst from to, which deletes dst and runs the LMOVE (LMove with
# the ends' New form)
def lmove.script() -> String:
  "redis.call('del',KEYS[2]) return redis.call('lmove',KEYS[1],KEYS[2],ARGV[1],ARGV[2])"

def parse_eval.moved(ok: Bool, m: Maybe<&2, LEnds>, s: String, d: String) -> Cmd:
  match ok m:
    case True{} Some{+e}:
      LMove{s, d, ends.new(e)}
    case _ _:
      e_lua()

def parse_eval.move(ok: Bool, rest: List<&2, String>) -> Cmd:
  match rest:
    case Con{s, Con{d, Con{+a, Con{+b, Nil{}}}}}:
      parse_eval.moved(ok, lends.of(lend.word(a), lend.word(b)), s, d)
    case _:
      e_lua()

# The script of a set's move to a key whose entry's time had passed:
# EVAL <it> 2 src dst member, which deletes dst and runs the SMOVE (SMv
# with SMemNew)
def smove.script() -> String:
  "redis.call('del',KEYS[2]) return redis.call('smove',KEYS[1],KEYS[2],ARGV[1])"

def parse_eval.smove(ok: Bool, rest: List<&2, String>) -> Cmd:
  match ok rest:
    case True{} Con{s, Con{d, Con{m, Nil{}}}}:
      SMv{s, d, SMemNew{m}}
    case _ _:
      e_lua()

# The script of a new sorted set (ZWNew): EVAL <it> 1 key n o1 .. on s1
# m1 ..., which deletes the key and runs ZADD with the n options o1 to
# on (n written as Nat.show writes it; never XX, which would add
# nothing) and the pairs, a thousand words of pairs a call, each with the
# options before them (a ZADD of some of the pairs does to each what the
# ZADD of all does: INCR takes one alone), and returns 0
def znew.script() -> String:
  "redis.call('del',KEYS[1]) local o=tonumber(ARGV[1]) local n=#ARGV for i=o+2,n,1000 do local a={} for j=2,o+1 do a[#a+1]=ARGV[j] end for j=i,math.min(i+999,n) do a[#a+1]=ARGV[j] end redis.call('zadd',KEYS[1],unpack(a)) end return 0"

def parse_eval.znew.fin(c: Maybe<&2, Reply>, k: String, o: ZOpts, ps: List<&2, ZPair>) -> Cmd:
  match c:
    case None{}:
      Upd{k, UZset{ZWNew{o, ps}}}
    case Some{r}:
      e_lua()

def parse_eval.znew.ps(ok: Bool, +k: String, +o: ZOpts, m: Maybe<&2, List<&2, ZPair>>) -> Cmd:
  match ok m:
    case True{} Some{+ps}:
      parse_eval.znew.fin(zadd.check(o, ps), k, o, ps)
    case _ _:
      e_lua()

def parse_eval.znew.at(ok: Bool, +k: String, +n: String, +o: ZOpts, ws: List<&2, String>) -> Cmd:
  parse_eval.znew.ps(Bool.and(ok, Bool.and(String.eq(n, Nat.show(zopts.count(o))), Bool.not(zopts.xx(o)))), k, o, zpairs(ws))

def parse_eval.znew.of(ok: Bool, +k: String, +n: String, p: ZOpts & List<&2, String>) -> Cmd:
  (o, ws) = p
  parse_eval.znew.at(ok, k, n, o, ws)

def parse_eval.znew(ok: Bool, rest: List<&2, String>) -> Cmd:
  match rest:
    case Con{+k, Con{+n, +ws}}:
      parse_eval.znew.of(ok, k, n, zadd.opts(ws))
    case _:
      e_lua()

# which script: 1 a new hash's, list's or set's, 2 a list's move, 3 a
# set's move, 4 a new sorted set's, 0 another
def parse_eval.which(w: Nat, +nk: String, rest: List<&2, String>) -> Cmd:
  match w:
    case 1n:
      parse_eval.one(String.eq(nk, "1"), rest)
    case 2n:
      parse_eval.move(String.eq(nk, "2"), rest)
    case 3n:
      parse_eval.smove(String.eq(nk, "2"), rest)
    case 4n:
      parse_eval.znew(String.eq(nk, "1"), rest)
    case _:
      e_lua()

def parse_eval(args: List<&2, String>) -> Cmd:
  match args:
    case Con{+s, Con{+nk, rest}}:
      parse_eval.which(Bool.pick(Nat, String.eq(s, hnew.script()), 1n, Bool.pick(Nat, String.eq(s, lmove.script()), 2n, Bool.pick(Nat, String.eq(s, smove.script()), 3n, Bool.pick(Nat, String.eq(s, znew.script()), 4n, 0n)))), nk, rest)
    case _:
      e_arity("eval")

# Lists: a push takes a key and at least one element; LPOP and RPOP a
# count after the key at most, a long at least 0 read as the command
# parses (Redis's error for one that is not is "out of range"); LRANGE's
# and LTRIM's range and LREM's count are read as the command parses, the
# index of LINDEX and of LSET once the list is found, as Redis reads
# them; LINSERT's BEFORE or AFTER in any case
# a push of xs, onto a list that is there only for x
def lpush.op(+left: Bool, xs: List<&2, String>, x: Bool) -> LWrite:
  match x:
    case True{}:
      LWPushX{left, xs}
    case False{}:
      LWPush{left, xs}

def parse_lpush(args: List<&2, String>, +left: Bool, +x: Bool, name: String) -> Cmd:
  match args:
    case Con{k, Con{v, rest}}:
      Upd{k, UList{lpush.op(left, v <> rest, x)}}
    case _:
      e_arity(name)

def parse_lpop.n(ok: Bool, k: String, +left: Bool, c: String) -> Cmd:
  match ok:
    case True{}:
      Upd{k, UList{LWPopN{left, c}}}
    case False{}:
      Bad{RError{"ERR value is out of range, must be positive"}}

def parse_lpop(args: List<&2, String>, +left: Bool, name: String) -> Cmd:
  match args:
    case Con{k, Nil{}}:
      Upd{k, UList{LWPop{left}}}
    case Con{k, Con{+c, Nil{}}}:
      parse_lpop.n(Maybe.is_some(&2, Nat, lcount(c)), k, left, c)
    case _:
      e_arity(name)

def parse_lrange(ok: Bool, k: String, a: String, b: String) -> Cmd:
  match ok:
    case True{}:
      Peek{k, PList{LRRange{[a, b]}}}
    case False{}:
      Bad{e_int()}

def parse_ltrim(ok: Bool, k: String, a: String, b: String) -> Cmd:
  match ok:
    case True{}:
      Upd{k, UList{LWTrim{a, b}}}
    case False{}:
      Bad{e_int()}

def parse_lrem(ok: Bool, k: String, c: String, v: String) -> Cmd:
  match ok:
    case True{}:
      Upd{k, UList{LWRem{c, v}}}
    case False{}:
      Bad{e_int()}

# LINSERT's word: 1 AFTER, 2 BEFORE, 0 another
def parse_linsert(w: Nat, k: String, p: String, v: String) -> Cmd:
  match w:
    case 1n:
      Upd{k, UList{LWAfter{p, v}}}
    case 2n:
      Upd{k, UList{LWBefore{p, v}}}
    case _:
      Bad{RError{"ERR syntax error"}}

# LPOS's options as Redis reads them, in turn: RANK (a long, not 0),
# COUNT and MAXLEN (longs at least 0); an option without its argument,
# or any other word, is a syntax error. The last of an option counts.
# RANK LLONG_MIN, whose negation wraps in C, reads from the last
# element, takes the first match on, and with COUNT never stops: every
# match.
type LPosSt is Data:
  LPosSt{neg: Bool, rank: Nat, min: Bool, cnt: Maybe<&2, Nat>, maxlen: Nat}
  LPosErr{r: Reply}

def lpos.rank(l: LL, cnt: Maybe<&2, Nat>, maxlen: Nat) -> LPosSt:
  match l:
    case LL{+neg, +hi, +lo}:
      +zero = Bool.and(Nat.is_eq(hi, 0n), Nat.is_eq(lo, 0n))
      +min = Bool.and(neg, Bool.and(Nat.is_eq(hi, dec.llmax()), Nat.is_eq(lo, 854775808n)))
      Bool.pick(LPosSt, zero, LPosErr{RError{"ERR RANK can't be zero: use 1 to start from the first match, 2 from the second ... or use negative to start from the end of the list"}}, LPosSt{neg, lnum.mag(Nat.is_lt(hi, 140737n), hi, lo), min, cnt, maxlen})
    case LLBad{}:
      LPosErr{e_int()}

def lpos.count(m: Maybe<&2, Nat>, neg: Bool, rank: Nat, min: Bool, maxlen: Nat) -> LPosSt:
  match m:
    case Some{c}:
      LPosSt{neg, rank, min, Some{c}, maxlen}
    case None{}:
      LPosErr{RError{"ERR COUNT can't be negative"}}

def lpos.maxlen(m: Maybe<&2, Nat>, neg: Bool, rank: Nat, min: Bool, cnt: Maybe<&2, Nat>) -> LPosSt:
  match m:
    case Some{x}:
      LPosSt{neg, rank, min, cnt, x}
    case None{}:
      LPosErr{RError{"ERR MAXLEN can't be negative"}}

# an option's word: 1 RANK, 2 COUNT, 3 MAXLEN, 0 another
def lpos.word(+w: String) -> Nat:
  Bool.pick(Nat, is_word(w, "RANK"), 1n, Bool.pick(Nat, is_word(w, "COUNT"), 2n, Bool.pick(Nat, is_word(w, "MAXLEN"), 3n, 0n)))

def lpos.opt(w: Nat, +v: String, neg: Bool, rank: Nat, min: Bool, cnt: Maybe<&2, Nat>, maxlen: Nat) -> LPosSt:
  match w:
    case 1n:
      lpos.rank(ll.read(v), cnt, maxlen)
    case 2n:
      lpos.count(lcount(v), neg, rank, min, maxlen)
    case 3n:
      lpos.maxlen(lcount(v), neg, rank, min, cnt)
    case _:
      LPosErr{RError{"ERR syntax error"}}

def lpos.opts(xs: List<&2, String>, st: LPosSt) -> LPosSt:
  match xs st:
    case Nil{} st:
      st
    case Con{+w, Con{+v, rest}} LPosSt{neg, rank, min, cnt, maxlen}:
      lpos.opts(rest, lpos.opt(lpos.word(w), v, neg, rank, min, cnt, maxlen))
    case Con{w, Nil{}} LPosSt{neg, rank, min, cnt, maxlen}:
      LPosErr{RError{"ERR syntax error"}}
    case _ LPosErr{r}:
      LPosErr{r}

def lpos.all(cnt: Maybe<&2, Nat>) -> Maybe<&2, Nat>:
  match cnt:
    case Some{c}:
      Some{0n}
    case None{}:
      None{}

def lpos.mk(min: Bool, neg: Bool, rank: Nat, cnt: Maybe<&2, Nat>, maxlen: Nat) -> LPosOpts:
  match min:
    case True{}:
      LPosOpts{True{}, 1n, lpos.all(cnt), maxlen}
    case False{}:
      LPosOpts{neg, rank, cnt, maxlen}

def lpos.fin(st: LPosSt) -> LPosOpts:
  match st:
    case LPosSt{neg, rank, min, cnt, maxlen}:
      lpos.mk(min, neg, rank, cnt, maxlen)
    case LPosErr{r}:
      LPosBad{r}

def lpos.args(args: List<&2, String>) -> LPosOpts:
  lpos.fin(lpos.opts(args, LPosSt{False{}, 1n, False{}, None{}, 0n}))

def parse_lpos(o: LPosOpts, k: String, args: List<&2, String>) -> Cmd:
  match o:
    case LPosOpts{back, rank, cnt, maxlen}:
      Peek{k, PList{LRPos{args}}}
    case LPosBad{r}:
      Bad{r}

# LMOVE src dst from to: each end LEFT or RIGHT in any case, from first
def parse_lmove(m: Maybe<&2, LEnds>, s: String, d: String) -> Cmd:
  match m:
    case Some{e}:
      LMove{s, d, e}
    case None{}:
      Bad{RError{"ERR syntax error"}}

# LMPOP numkeys key [key ...] LEFT|RIGHT [COUNT count], as Redis reads it:
# numkeys a long from 1 (else "numkeys should be greater than 0"), then
# that many keys and an end (a syntax error when the words run out
# first), then COUNT and a long from 1 once at most (else "count should
# be greater than 0"); any other word is a syntax error. The count is
# kept as it came ("1" without one), the write of the key it pops reads
# it again (LWPopN).
# whether a count is a long from 1
def lmpop.pos(m: Maybe<&2, Int>) -> Bool:
  match m:
    case Some{IPos{1n+n}}:
      True{}
    case _:
      False{}

def lmpop.count.of(word: Bool, ok: Bool, c: String) -> Maybe<&2, String> & Maybe<&2, Reply>:
  match word ok:
    case True{} True{}:
      (Some{c}, None{})
    case True{} False{}:
      (None{}, Some{RError{"ERR count should be greater than 0"}})
    case False{} _:
      (None{}, Some{RError{"ERR syntax error"}})

# the count, or the error its words make
def lmpop.count(xs: List<&2, String>) -> Maybe<&2, String> & Maybe<&2, Reply>:
  match xs:
    case Nil{}:
      (Some{"1"}, None{})
    case Con{+w, Con{+c, Nil{}}}:
      lmpop.count.of(is_word(w, "COUNT"), lmpop.pos(lnum(c)), c)
    case _:
      (None{}, Some{RError{"ERR syntax error"}})

def lmpop.fin.of(mc: Maybe<&2, String>, me: Maybe<&2, Reply>, ks: List<&2, String>, +left: Bool) -> Cmd:
  match mc me:
    case Some{c} _:
      LMPop{ks, left, c}
    case None{} Some{r}:
      Bad{r}
    case None{} None{}:
      Bad{RError{"ERR syntax error"}}

def lmpop.fin(ks: List<&2, String>, +left: Bool, p: Maybe<&2, String> & Maybe<&2, Reply>) -> Cmd:
  (mc, me) = p
  lmpop.fin.of(mc, me, ks, left)

def lmpop.end(w: Nat, ks: List<&2, String>, rest: List<&2, String>) -> Cmd:
  match w:
    case 1n:
      lmpop.fin(ks, True{}, lmpop.count(rest))
    case 2n:
      lmpop.fin(ks, False{}, lmpop.count(rest))
    case _:
      Bad{RError{"ERR syntax error"}}

def lmpop.where(p: List<&2, String> & List<&2, String>) -> Cmd:
  (ks, rest) = p
  match rest:
    case Con{+w, more}:
      lmpop.end(lend.word(w), List.reverse(&2, String, ks), more)
    case Nil{}:
      Bad{RError{"ERR syntax error"}}

def lmpop.keys(m: Maybe<&2, Int>, rest: List<&2, String>) -> Cmd:
  match m:
    case Some{IPos{1n+n}}:
      lmpop.where(KV.deq.cut(1n+n, rest, Nil{}))
    case _:
      Bad{RError{"ERR numkeys should be greater than 0"}}

def parse_lmpop(args: List<&2, String>) -> Cmd:
  match args:
    case Con{+nk, Con{k, Con{w, rest}}}:
      lmpop.keys(lnum(nk), k <> (w <> rest))
    case _:
      e_arity("lmpop")

# ZUNION, ZINTER, ZDIFF and ZINTERCARD numkeys key [key ...] [options],
# and their STOREs destination numkeys key ...: numkeys a long (else not
# an integer), at least 1 (else "at least 1 input key is needed", with
# the command's name), at most the words after it (else a syntax error);
# then the options, as Redis reads them, a word at a time: WEIGHTS and a
# double for each key (not for ZDIFF nor ZINTERCARD; "weight value is not
# a float"), AGGREGATE and SUM, MIN or MAX (the same), WITHSCORES (not
# for a STORE nor ZINTERCARD), LIMIT and a long at least 0 (ZINTERCARD
# alone; "LIMIT can't be negative"), as often as each comes, the last
# counting; any other word, or one without the words it takes, is a
# syntax error. kind is 1 for ZUNION, 2 ZINTER, 3 ZDIFF, 4 ZINTERCARD.
# The options' state: m is what the next word is (0 an option, 1 a
# weight, k of them still to come, 2 AGGREGATE's word, 3 LIMIT's count),
# left how many words are left with it.
type ZOptSt is Data:
  ZOptSt{ws: List<&2, F.F64>, agg: Nat, sc: Bool, lim: Nat, m: Nat, k: Nat}
  ZOptBad{r: Reply}

# an option's word: 1 WEIGHTS, 2 AGGREGATE, 3 WITHSCORES, 4 LIMIT, 0 another
def zagg.word(+w: String) -> Nat:
  +up = String.to_upper(cstr(w))
  Bool.pick(Nat, String.eq(up, "WEIGHTS"), 1n, Bool.pick(Nat, String.eq(up, "AGGREGATE"), 2n, Bool.pick(Nat, String.eq(up, "WITHSCORES"), 3n, Bool.pick(Nat, String.eq(up, "LIMIT"), 4n, 0n))))

# AGGREGATE's word: 0 SUM, 1 MIN, 2 MAX, 3 another
def zagg.fn(+w: String) -> Nat:
  +up = String.to_upper(cstr(w))
  Bool.pick(Nat, String.eq(up, "SUM"), 0n, Bool.pick(Nat, String.eq(up, "MIN"), 1n, Bool.pick(Nat, String.eq(up, "MAX"), 2n, 3n)))

def zopt.err() -> ZOptSt:
  ZOptBad{RError{"ERR syntax error"}}

# an option's word, with kind, whether the command is a STORE, n the
# number of keys and left the words left
def zopt.at(c: Nat, +sets: Bool, +kind: Nat, +store: Bool, +n: Nat, +left: Nat, ws: List<&2, F.F64>, agg: Nat, sc: Bool, lim: Nat) -> ZOptSt:
  match c:
    case 1n:
      Bool.pick(ZOptSt, Bool.and(sets, Nat.is_le(Nat.add(n, 1n), left)), ZOptSt{Nil{}, agg, sc, lim, 1n, n}, zopt.err())
    case 2n:
      Bool.pick(ZOptSt, Bool.and(sets, Nat.is_le(2n, left)), ZOptSt{ws, agg, sc, lim, 2n, 0n}, zopt.err())
    case 3n:
      Bool.pick(ZOptSt, Bool.and(Bool.not(store), Nat.is_lt(kind, 4n)), ZOptSt{ws, agg, True{}, lim, 0n, 0n}, zopt.err())
    case 4n:
      Bool.pick(ZOptSt, Bool.and(Nat.is_eq(kind, 4n), Nat.is_le(2n, left)), ZOptSt{ws, agg, sc, lim, 3n, 0n}, zopt.err())
    case _:
      zopt.err()

def zopt.weight(m: Maybe<&2, F.F64>, ws: List<&2, F.F64>, agg: Nat, sc: Bool, lim: Nat, +k: Nat) -> ZOptSt:
  match m:
    case Some{d}:
      ZOptSt{d <> ws, agg, sc, lim, Bool.pick(Nat, Nat.is_eq(k, 1n), 0n, 1n), Nat.sub(k, 1n)}
    case None{}:
      ZOptBad{RError{"ERR weight value is not a float"}}

def zopt.fn(f: Nat, ws: List<&2, F.F64>, sc: Bool, lim: Nat) -> ZOptSt:
  match f:
    case 3n:
      zopt.err()
    case _:
      ZOptSt{ws, f, sc, lim, 0n, 0n}

def zopt.lim(m: Maybe<&2, Nat>, ws: List<&2, F.F64>, agg: Nat, sc: Bool) -> ZOptSt:
  match m:
    case Some{l}:
      ZOptSt{ws, agg, sc, l, 0n, 0n}
    case None{}:
      ZOptBad{RError{"ERR LIMIT can't be negative"}}

# the state after the word w
def zopt.step(+w: String, st: ZOptSt, +kind: Nat, +store: Bool, +n: Nat, +left: Nat) -> ZOptSt:
  match st:
    case ZOptBad{r}:
      ZOptBad{r}
    case ZOptSt{ws, agg, sc, lim, m, +k}:
      match m:
        case 0n:
          zopt.at(zagg.word(w), Nat.is_le(kind, 2n), kind, store, n, left, ws, agg, sc, lim)
        case 1n:
          zopt.weight(F.f64.parse(w), ws, agg, sc, lim, k)
        case 2n:
          zopt.fn(zagg.fn(w), ws, sc, lim)
        case _:
          zopt.lim(lcount(w), ws, agg, sc)

def zopt.go(xs: List<&2, String>, st: ZOptSt, +kind: Nat, +store: Bool, +n: Nat, +left: Nat) -> ZOptSt:
  match xs:
    case Nil{}:
      st
    case Con{+w, rest}:
      zopt.go(rest, zopt.step(w, st, kind, store, n, left), kind, store, n, Nat.sub(left, 1n))

# the options, with WITHSCORES when sc
def zagg.with(sc: Bool, o: ZAgg) -> ZAgg:
  match sc:
    case True{}:
      ZAggScores{o}
    case False{}:
      o

def zopt.fin(st: ZOptSt) -> ZAgg:
  match st:
    case ZOptSt{ws, agg, sc, lim, m, k}:
      zagg.with(sc, ZAgg{List.reverse(&2, F.F64, ws), agg, lim})
    case ZOptBad{r}:
      ZAggBad{r}

def zagg.of(+kind: Nat, +store: Bool, +n: Nat, +xs: List<&2, String>) -> ZAgg:
  zopt.fin(zopt.go(xs, ZOptSt{Nil{}, 0n, False{}, 0n, 0n, 0n}, kind, store, n, List.length(&2, String, xs)))

def zsetk.of(+kind: Nat, o: ZAgg) -> ZSetK:
  match kind:
    case 1n:
      ZKUnion{o}
    case 2n:
      ZKInter{o}
    case 3n:
      ZKDiff{o}
    case _:
      ZKCard{o}

def zop.cmd(store: Maybe<&2, String>, k: ZSetK, ks: List<&2, String>) -> Cmd:
  match store:
    case Some{d}:
      ZStore{k, d, ks}
    case None{}:
      ZOp{k, ks}

# the keys and the options' words, split, with the command they make
def zop.mk.of(+kind: Nat, +store: Maybe<&2, String>, +ks: List<&2, String>, +rest: List<&2, String>) -> Cmd:
  zop.cmd(store, zsetk.of(kind, zagg.of(kind, Maybe.is_some(&2, String, store), List.length(&2, String, ks), rest)), List.reverse(&2, String, ks))

def zop.mk(+kind: Nat, store: Maybe<&2, String>, p: List<&2, String> & List<&2, String>) -> Cmd:
  (ks, rest) = p
  zop.mk.of(kind, store, ks, rest)

def zop.fit(ok: Bool, +kind: Nat, store: Maybe<&2, String>, +n: Nat, rest: List<&2, String>) -> Cmd:
  match ok:
    case True{}:
      zop.mk(kind, store, KV.deq.cut(n, rest, Nil{}))
    case False{}:
      e_syntax()

def zop.keys(m: Maybe<&2, Int>, +kind: Nat, store: Maybe<&2, String>, +rest: List<&2, String>, name: String) -> Cmd:
  match m:
    case Some{IPos{1n+(+n)}}:
      zop.fit(Nat.is_le(1n+n, List.length(&2, String, rest)), kind, store, 1n+n, rest)
    case Some{x}:
      Bad{RError{"ERR at least 1 input key is needed for '" ++ name ++ "' command"}}
    case None{}:
      Bad{e_int()}

def parse_zop(args: List<&2, String>, +kind: Nat, name: String) -> Cmd:
  match args:
    case Con{+nk, Con{k, rest}}:
      zop.keys(lnum(nk), kind, None{}, k <> rest, name)
    case _:
      e_arity(name)

def parse_zstore(args: List<&2, String>, +kind: Nat, name: String) -> Cmd:
  match args:
    case Con{d, Con{+nk, Con{k, rest}}}:
      zop.keys(lnum(nk), kind, Some{d}, k <> rest, name)
    case _:
      e_arity(name)

# ZRANGESTORE dst src min max [options]: ZRANGE's, but WITHSCORES
def parse_zrangestore.of(d: String, s: String, o: ZqOut) -> Cmd:
  match o:
    case ZqOk{q}:
      ZRangeStore{d, s, q}
    case ZqBad{r}:
      Bad{r}

def parse_zrangestore(args: List<&2, String>) -> Cmd:
  match args:
    case Con{d, Con{s, Con{+a, Con{+b, +rest}}}}:
      parse_zrangestore.of(d, s, zq.read(0n, 0n, True{}, a, b, rest))
    case _:
      e_arity("zrangestore")

# ZMPOP numkeys key [key ...] MIN|MAX [COUNT count], as LMPOP's
# arguments are read (MIN and MAX for LEFT and RIGHT)
def zend.word(+w: String) -> Nat:
  Bool.pick(Nat, is_word(w, "MIN"), 1n, Bool.pick(Nat, is_word(w, "MAX"), 2n, 0n))

def zmpop.fin.of(mc: Maybe<&2, String>, me: Maybe<&2, Reply>, ks: List<&2, String>, +max: Bool) -> Cmd:
  match mc me:
    case Some{c} _:
      ZMPop{ks, max, c}
    case None{} Some{r}:
      Bad{r}
    case None{} None{}:
      Bad{RError{"ERR syntax error"}}

def zmpop.fin(ks: List<&2, String>, +max: Bool, p: Maybe<&2, String> & Maybe<&2, Reply>) -> Cmd:
  (mc, me) = p
  zmpop.fin.of(mc, me, ks, max)

def zmpop.end(w: Nat, ks: List<&2, String>, rest: List<&2, String>) -> Cmd:
  match w:
    case 1n:
      zmpop.fin(ks, False{}, lmpop.count(rest))
    case 2n:
      zmpop.fin(ks, True{}, lmpop.count(rest))
    case _:
      Bad{RError{"ERR syntax error"}}

def zmpop.where(p: List<&2, String> & List<&2, String>) -> Cmd:
  (ks, rest) = p
  match rest:
    case Con{+w, more}:
      zmpop.end(zend.word(w), List.reverse(&2, String, ks), more)
    case Nil{}:
      Bad{RError{"ERR syntax error"}}

def zmpop.keys(m: Maybe<&2, Int>, rest: List<&2, String>) -> Cmd:
  match m:
    case Some{IPos{1n+n}}:
      zmpop.where(KV.deq.cut(1n+n, rest, Nil{}))
    case _:
      Bad{RError{"ERR numkeys should be greater than 0"}}

def parse_zmpop(args: List<&2, String>) -> Cmd:
  match args:
    case Con{+nk, Con{k, Con{w, rest}}}:
      zmpop.keys(lnum(nk), k <> (w <> rest))
    case _:
      e_arity("zmpop")

# Sets: SADD, SREM and SMISMEMBER take a key and at least one member;
# SSCAN's cursor is read as the command parses, before the key is looked
# for, as HSCAN's
def parse_sscan(+k: String, +c: String, rest: List<&2, String>) -> Cmd:
  Bool.pick(Cmd, Maybe.is_some(&2, Nat, scan.cursor(c)), Peek{k, PMems{SRScan{c <> rest}}}, Bad{RError{"ERR invalid cursor"}})

# SINTER, SUNION and SDIFF take at least one key; their STOREs a
# destination and at least one source
def parse_sop(+k: SetK, args: List<&2, String>, name: String) -> Cmd:
  match args:
    case Con{x, xs}:
      SOp{k, x <> xs}
    case Nil{}:
      e_arity(name)

def parse_sstore(+k: SetK, args: List<&2, String>, name: String) -> Cmd:
  match args:
    case Con{d, Con{x, xs}}:
      SStore{k, d, x <> xs}
    case _:
      e_arity(name)

# SINTERCARD numkeys key [key ...] [LIMIT limit], as Redis reads it:
# numkeys a long from 1 (else "numkeys should be greater than 0"), at
# most the arguments after it, then LIMIT and a long at least 0 (else
# "LIMIT can't be negative"), as often as it comes, the last one
# counting; any other word, or LIMIT last, is a syntax error
type SicSt is Data:
  SicOk{limit: Nat}
  SicErr{r: Reply}

def sic.opt(limit: Bool, m: Maybe<&2, Nat>) -> SicSt:
  match limit m:
    case True{} Some{n}:
      SicOk{n}
    case True{} None{}:
      SicErr{RError{"ERR LIMIT can't be negative"}}
    case False{} _:
      SicErr{RError{"ERR syntax error"}}

def sic.opts(xs: List<&2, String>, st: SicSt) -> SicSt:
  match xs st:
    case _ SicErr{r}:
      SicErr{r}
    case Nil{} st:
      st
    case Con{+w, Con{+v, rest}} SicOk{l}:
      sic.opts(rest, sic.opt(is_word(w, "LIMIT"), lcount(v)))
    case Con{w, Nil{}} SicOk{l}:
      SicErr{RError{"ERR syntax error"}}

def sic.of(st: SicSt, ks: List<&2, String>) -> Cmd:
  match st:
    case SicOk{l}:
      SOp{KCard{l}, ks}
    case SicErr{r}:
      Bad{r}

def sic.fin(p: List<&2, String> & List<&2, String>) -> Cmd:
  (ks, more) = p
  sic.of(sic.opts(more, SicOk{0n}), List.reverse(&2, String, ks))

def sic.fit(ok: Bool, +n: Nat, rest: List<&2, String>) -> Cmd:
  match ok:
    case True{}:
      sic.fin(KV.deq.cut(n, rest, Nil{}))
    case False{}:
      Bad{RError{"ERR Number of keys can't be greater than number of args"}}

def sic.keys(m: Maybe<&2, Int>, +rest: List<&2, String>) -> Cmd:
  match m:
    case Some{IPos{1n++n}}:
      sic.fit(Nat.is_le(1n+n, List.length(&2, String, rest)), 1n+n, rest)
    case _:
      Bad{RError{"ERR numkeys should be greater than 0"}}

def parse_sintercard(args: List<&2, String>) -> Cmd:
  match args:
    case Con{+nk, Con{k, rest}}:
      sic.keys(lnum(nk), k <> rest)
    case _:
      e_arity("sintercard")

# A command's name, in upper case, picks how its arguments parse: cmd_id
# gives the name's number in the parser (parse_id, or parse_sess for a
# number cmd_own names), 0 for a name no command has, and parse_id has
# the name as the client sent it, for the error about an unknown one.
# tools/gen_commands.py writes cmd_id from the parser's cases, each of
# which names its command in a comment: the name's length, then its first
# letter (cmd_id.lN, the letter by its place in the alphabet) narrow it
# down to a few names, which String.eq compares with it whole: with a
# literal that is one memcmp (one comparison of words up to six bytes),
# cheap enough that Bool.pick computes all of them.

# BEGIN gen_commands: dispatch
def cmd_id.l3(+n: String, c: Nat) -> Nat:
  match c:
    case 4n:  # D
      Bool.pick(Nat, String.eq(n, "DEL"), 7n, 0n)
    case 7n:  # G
      Bool.pick(Nat, String.eq(n, "GET"), 3n, 0n)
    case 12n:  # L
      Bool.pick(Nat, String.eq(n, "LCS"), 116n, 0n)
    case 19n:  # S
      Bool.pick(Nat, String.eq(n, "SET"), 4n, 0n)
    case 20n:  # T
      Bool.pick(Nat, String.eq(n, "TTL"), 32n, 0n)
    case _:
      0n

def cmd_id.l4(+n: String, c: Nat) -> Nat:
  match c:
    case 1n:  # A
      Bool.pick(Nat, String.eq(n, "AUTH"), 102n, 0n)
    case 3n:  # C
      Bool.pick(Nat, String.eq(n, "COPY"), 115n, 0n)
    case 4n:  # D
      Bool.pick(Nat, String.eq(n, "DECR"), 11n, 0n)
    case 5n:  # E
      Bool.pick(Nat, String.eq(n, "ECHO"), 2n,
      Bool.pick(Nat, String.eq(n, "EVAL"), 65n, 0n))
    case 8n:  # H
      Bool.pick(Nat, String.eq(n, "HSET"), 51n,
      Bool.pick(Nat, String.eq(n, "HGET"), 53n,
      Bool.pick(Nat, String.eq(n, "HDEL"), 56n,
      Bool.pick(Nat, String.eq(n, "HLEN"), 57n, 0n))))
    case 9n:  # I
      Bool.pick(Nat, String.eq(n, "INCR"), 10n,
      Bool.pick(Nat, String.eq(n, "INFO"), 108n, 0n))
    case 11n:  # K
      Bool.pick(Nat, String.eq(n, "KEYS"), 21n, 0n)
    case 12n:  # L
      Bool.pick(Nat, String.eq(n, "LPOP"), 70n,
      Bool.pick(Nat, String.eq(n, "LLEN"), 72n,
      Bool.pick(Nat, String.eq(n, "LSET"), 75n,
      Bool.pick(Nat, String.eq(n, "LREM"), 77n,
      Bool.pick(Nat, String.eq(n, "LPOS"), 79n, 0n)))))
    case 13n:  # M
      Bool.pick(Nat, String.eq(n, "MGET"), 16n,
      Bool.pick(Nat, String.eq(n, "MSET"), 17n,
      Bool.pick(Nat, String.eq(n, "MOVE"), 112n, 0n)))
    case 16n:  # P
      Bool.pick(Nat, String.eq(n, "PING"), 1n,
      Bool.pick(Nat, String.eq(n, "PTTL"), 33n, 0n))
    case 17n:  # Q
      Bool.pick(Nat, String.eq(n, "QUIT"), 103n, 0n)
    case 18n:  # R
      Bool.pick(Nat, String.eq(n, "RPOP"), 71n, 0n)
    case 19n:  # S
      Bool.pick(Nat, String.eq(n, "SCAN"), 22n,
      Bool.pick(Nat, String.eq(n, "SADD"), 83n,
      Bool.pick(Nat, String.eq(n, "SREM"), 84n,
      Bool.pick(Nat, String.eq(n, "SPOP"), 119n, 0n))))
    case 20n:  # T
      Bool.pick(Nat, String.eq(n, "TYPE"), 25n,
      Bool.pick(Nat, String.eq(n, "TIME"), 113n, 0n))
    case 26n:  # Z
      Bool.pick(Nat, String.eq(n, "ZADD"), 121n,
      Bool.pick(Nat, String.eq(n, "ZREM"), 123n, 0n))
    case _:
      0n

def cmd_id.l5(+n: String, c: Nat) -> Nat:
  match c:
    case 2n:  # B
      Bool.pick(Nat, String.eq(n, "BITOP"), 48n, 0n)
    case 7n:  # G
      Bool.pick(Nat, String.eq(n, "GETEX"), 26n, 0n)
    case 8n:  # H
      Bool.pick(Nat, String.eq(n, "HMGET"), 54n,
      Bool.pick(Nat, String.eq(n, "HMSET"), 55n,
      Bool.pick(Nat, String.eq(n, "HKEYS"), 60n,
      Bool.pick(Nat, String.eq(n, "HVALS"), 61n,
      Bool.pick(Nat, String.eq(n, "HSCAN"), 64n,
      Bool.pick(Nat, String.eq(n, "HELLO"), 101n, 0n))))))
    case 12n:  # L
      Bool.pick(Nat, String.eq(n, "LPUSH"), 66n,
      Bool.pick(Nat, String.eq(n, "LTRIM"), 78n,
      Bool.pick(Nat, String.eq(n, "LMOVE"), 80n,
      Bool.pick(Nat, String.eq(n, "LMPOP"), 82n, 0n))))
    case 18n:  # R
      Bool.pick(Nat, String.eq(n, "RPUSH"), 67n,
      Bool.pick(Nat, String.eq(n, "RESET"), 104n, 0n))
    case 19n:  # S
      Bool.pick(Nat, String.eq(n, "SETNX"), 5n,
      Bool.pick(Nat, String.eq(n, "SETEX"), 23n,
      Bool.pick(Nat, String.eq(n, "SCARD"), 85n,
      Bool.pick(Nat, String.eq(n, "SSCAN"), 89n,
      Bool.pick(Nat, String.eq(n, "SMOVE"), 90n,
      Bool.pick(Nat, String.eq(n, "SDIFF"), 96n, 0n))))))
    case 20n:  # T
      Bool.pick(Nat, String.eq(n, "TOUCH"), 44n, 0n)
    case 26n:  # Z
      Bool.pick(Nat, String.eq(n, "ZCARD"), 124n,
      Bool.pick(Nat, String.eq(n, "ZRANK"), 127n,
      Bool.pick(Nat, String.eq(n, "ZSCAN"), 142n,
      Bool.pick(Nat, String.eq(n, "ZDIFF"), 145n,
      Bool.pick(Nat, String.eq(n, "ZMPOP"), 151n, 0n)))))
    case _:
      0n

def cmd_id.l6(+n: String, c: Nat) -> Nat:
  match c:
    case 1n:  # A
      Bool.pick(Nat, String.eq(n, "APPEND"), 14n, 0n)
    case 2n:  # B
      Bool.pick(Nat, String.eq(n, "BITPOS"), 43n, 0n)
    case 3n:  # C
      Bool.pick(Nat, String.eq(n, "CLIENT"), 105n,
      Bool.pick(Nat, String.eq(n, "CONFIG"), 107n, 0n))
    case 4n:  # D
      Bool.pick(Nat, String.eq(n, "DECRBY"), 13n,
      Bool.pick(Nat, String.eq(n, "DBSIZE"), 18n, 0n))
    case 5n:  # E
      Bool.pick(Nat, String.eq(n, "EXISTS"), 9n,
      Bool.pick(Nat, String.eq(n, "EXPIRE"), 28n, 0n))
    case 7n:  # G
      Bool.pick(Nat, String.eq(n, "GETSET"), 6n,
      Bool.pick(Nat, String.eq(n, "GETDEL"), 27n,
      Bool.pick(Nat, String.eq(n, "GETBIT"), 40n, 0n)))
    case 8n:  # H
      Bool.pick(Nat, String.eq(n, "HSETNX"), 52n, 0n)
    case 9n:  # I
      Bool.pick(Nat, String.eq(n, "INCRBY"), 12n, 0n)
    case 12n:  # L
      Bool.pick(Nat, String.eq(n, "LPUSHX"), 68n,
      Bool.pick(Nat, String.eq(n, "LINDEX"), 73n,
      Bool.pick(Nat, String.eq(n, "LRANGE"), 74n, 0n)))
    case 13n:  # M
      Bool.pick(Nat, String.eq(n, "MSETNX"), 45n,
      Bool.pick(Nat, String.eq(n, "MEMORY"), 118n, 0n))
    case 15n:  # O
      Bool.pick(Nat, String.eq(n, "OBJECT"), 114n, 0n)
    case 16n:  # P
      Bool.pick(Nat, String.eq(n, "PSETEX"), 24n, 0n)
    case 18n:  # R
      Bool.pick(Nat, String.eq(n, "RENAME"), 46n,
      Bool.pick(Nat, String.eq(n, "RPUSHX"), 69n, 0n))
    case 19n:  # S
      Bool.pick(Nat, String.eq(n, "STRLEN"), 15n,
      Bool.pick(Nat, String.eq(n, "SUBSTR"), 38n,
      Bool.pick(Nat, String.eq(n, "SETBIT"), 41n,
      Bool.pick(Nat, String.eq(n, "SINTER"), 91n,
      Bool.pick(Nat, String.eq(n, "SUNION"), 94n,
      Bool.pick(Nat, String.eq(n, "SELECT"), 100n,
      Bool.pick(Nat, String.eq(n, "SWAPDB"), 111n, 0n)))))))
    case 21n:  # U
      Bool.pick(Nat, String.eq(n, "UNLINK"), 8n, 0n)
    case 26n:  # Z
      Bool.pick(Nat, String.eq(n, "ZSCORE"), 125n,
      Bool.pick(Nat, String.eq(n, "ZCOUNT"), 129n,
      Bool.pick(Nat, String.eq(n, "ZRANGE"), 131n,
      Bool.pick(Nat, String.eq(n, "ZUNION"), 143n,
      Bool.pick(Nat, String.eq(n, "ZINTER"), 144n, 0n)))))
    case _:
      0n

def cmd_id.l7(+n: String, c: Nat) -> Nat:
  match c:
    case 3n:  # C
      Bool.pick(Nat, String.eq(n, "COMMAND"), 109n, 0n)
    case 6n:  # F
      Bool.pick(Nat, String.eq(n, "FLUSHDB"), 20n, 0n)
    case 8n:  # H
      Bool.pick(Nat, String.eq(n, "HSTRLEN"), 58n,
      Bool.pick(Nat, String.eq(n, "HEXISTS"), 59n,
      Bool.pick(Nat, String.eq(n, "HGETALL"), 62n,
      Bool.pick(Nat, String.eq(n, "HINCRBY"), 63n, 0n))))
    case 12n:  # L
      Bool.pick(Nat, String.eq(n, "LINSERT"), 76n, 0n)
    case 16n:  # P
      Bool.pick(Nat, String.eq(n, "PEXPIRE"), 29n,
      Bool.pick(Nat, String.eq(n, "PERSIST"), 36n, 0n))
    case 26n:  # Z
      Bool.pick(Nat, String.eq(n, "ZINCRBY"), 122n,
      Bool.pick(Nat, String.eq(n, "ZMSCORE"), 126n,
      Bool.pick(Nat, String.eq(n, "ZPOPMIN"), 140n,
      Bool.pick(Nat, String.eq(n, "ZPOPMAX"), 141n, 0n))))
    case _:
      0n

def cmd_id.l8(+n: String, c: Nat) -> Nat:
  match c:
    case 2n:  # B
      Bool.pick(Nat, String.eq(n, "BITCOUNT"), 42n,
      Bool.pick(Nat, String.eq(n, "BITFIELD"), 49n, 0n))
    case 5n:  # E
      Bool.pick(Nat, String.eq(n, "EXPIREAT"), 30n, 0n)
    case 6n:  # F
      Bool.pick(Nat, String.eq(n, "FLUSHALL"), 19n,
      Bool.pick(Nat, String.eq(n, "FUNCTION"), 106n, 0n))
    case 7n:  # G
      Bool.pick(Nat, String.eq(n, "GETRANGE"), 37n, 0n)
    case 18n:  # R
      Bool.pick(Nat, String.eq(n, "RENAMENX"), 47n, 0n)
    case 19n:  # S
      Bool.pick(Nat, String.eq(n, "SETRANGE"), 39n,
      Bool.pick(Nat, String.eq(n, "SMEMBERS"), 88n, 0n))
    case 26n:  # Z
      Bool.pick(Nat, String.eq(n, "ZREVRANK"), 128n, 0n)
    case _:
      0n

def cmd_id.l9(+n: String, c: Nat) -> Nat:
  match c:
    case 16n:  # P
      Bool.pick(Nat, String.eq(n, "PEXPIREAT"), 31n, 0n)
    case 18n:  # R
      Bool.pick(Nat, String.eq(n, "RPOPLPUSH"), 81n,
      Bool.pick(Nat, String.eq(n, "RANDOMKEY"), 110n, 0n))
    case 19n:  # S
      Bool.pick(Nat, String.eq(n, "SISMEMBER"), 86n, 0n)
    case 26n:  # Z
      Bool.pick(Nat, String.eq(n, "ZLEXCOUNT"), 130n,
      Bool.pick(Nat, String.eq(n, "ZREVRANGE"), 136n, 0n))
    case _:
      0n

def cmd_id.l10(+n: String, c: Nat) -> Nat:
  match c:
    case 5n:  # E
      Bool.pick(Nat, String.eq(n, "EXPIRETIME"), 34n, 0n)
    case 8n:  # H
      Bool.pick(Nat, String.eq(n, "HRANDFIELD"), 117n, 0n)
    case 19n:  # S
      Bool.pick(Nat, String.eq(n, "SMISMEMBER"), 87n,
      Bool.pick(Nat, String.eq(n, "SINTERCARD"), 92n,
      Bool.pick(Nat, String.eq(n, "SDIFFSTORE"), 97n, 0n)))
    case 26n:  # Z
      Bool.pick(Nat, String.eq(n, "ZINTERCARD"), 146n,
      Bool.pick(Nat, String.eq(n, "ZDIFFSTORE"), 149n, 0n))
    case _:
      0n

def cmd_id.l11(+n: String, c: Nat) -> Nat:
  match c:
    case 2n:  # B
      Bool.pick(Nat, String.eq(n, "BITFIELD_RO"), 50n, 0n)
    case 9n:  # I
      Bool.pick(Nat, String.eq(n, "INCRBYFLOAT"), 98n, 0n)
    case 16n:  # P
      Bool.pick(Nat, String.eq(n, "PEXPIRETIME"), 35n, 0n)
    case 19n:  # S
      Bool.pick(Nat, String.eq(n, "SINTERSTORE"), 93n,
      Bool.pick(Nat, String.eq(n, "SUNIONSTORE"), 95n,
      Bool.pick(Nat, String.eq(n, "SRANDMEMBER"), 120n, 0n)))
    case 26n:  # Z
      Bool.pick(Nat, String.eq(n, "ZRANGEBYLEX"), 134n,
      Bool.pick(Nat, String.eq(n, "ZUNIONSTORE"), 147n,
      Bool.pick(Nat, String.eq(n, "ZINTERSTORE"), 148n,
      Bool.pick(Nat, String.eq(n, "ZRANGESTORE"), 150n,
      Bool.pick(Nat, String.eq(n, "ZRANDMEMBER"), 152n, 0n)))))
    case _:
      0n

def cmd_id.l12(+n: String, c: Nat) -> Nat:
  match c:
    case 8n:  # H
      Bool.pick(Nat, String.eq(n, "HINCRBYFLOAT"), 99n, 0n)
    case _:
      0n

def cmd_id.l13(+n: String, c: Nat) -> Nat:
  match c:
    case 26n:  # Z
      Bool.pick(Nat, String.eq(n, "ZRANGEBYSCORE"), 132n, 0n)
    case _:
      0n

def cmd_id.l14(+n: String, c: Nat) -> Nat:
  match c:
    case 26n:  # Z
      Bool.pick(Nat, String.eq(n, "ZREVRANGEBYLEX"), 135n,
      Bool.pick(Nat, String.eq(n, "ZREMRANGEBYLEX"), 139n, 0n))
    case _:
      0n

def cmd_id.l15(+n: String, c: Nat) -> Nat:
  match c:
    case 26n:  # Z
      Bool.pick(Nat, String.eq(n, "ZREMRANGEBYRANK"), 137n, 0n)
    case _:
      0n

def cmd_id.l16(+n: String, c: Nat) -> Nat:
  match c:
    case 26n:  # Z
      Bool.pick(Nat, String.eq(n, "ZREVRANGEBYSCORE"), 133n,
      Bool.pick(Nat, String.eq(n, "ZREMRANGEBYSCORE"), 138n, 0n))
    case _:
      0n

def cmd_id(+n: String, len: Nat) -> Nat:
  match len:
    case 3n:
      cmd_id.l3(n, Nat.sub(U32.to_nat(String.code_at(n, 0n)), 64n))
    case 4n:
      cmd_id.l4(n, Nat.sub(U32.to_nat(String.code_at(n, 0n)), 64n))
    case 5n:
      cmd_id.l5(n, Nat.sub(U32.to_nat(String.code_at(n, 0n)), 64n))
    case 6n:
      cmd_id.l6(n, Nat.sub(U32.to_nat(String.code_at(n, 0n)), 64n))
    case 7n:
      cmd_id.l7(n, Nat.sub(U32.to_nat(String.code_at(n, 0n)), 64n))
    case 8n:
      cmd_id.l8(n, Nat.sub(U32.to_nat(String.code_at(n, 0n)), 64n))
    case 9n:
      cmd_id.l9(n, Nat.sub(U32.to_nat(String.code_at(n, 0n)), 64n))
    case 10n:
      cmd_id.l10(n, Nat.sub(U32.to_nat(String.code_at(n, 0n)), 64n))
    case 11n:
      cmd_id.l11(n, Nat.sub(U32.to_nat(String.code_at(n, 0n)), 64n))
    case 12n:
      cmd_id.l12(n, Nat.sub(U32.to_nat(String.code_at(n, 0n)), 64n))
    case 13n:
      cmd_id.l13(n, Nat.sub(U32.to_nat(String.code_at(n, 0n)), 64n))
    case 14n:
      cmd_id.l14(n, Nat.sub(U32.to_nat(String.code_at(n, 0n)), 64n))
    case 15n:
      cmd_id.l15(n, Nat.sub(U32.to_nat(String.code_at(n, 0n)), 64n))
    case 16n:
      cmd_id.l16(n, Nat.sub(U32.to_nat(String.code_at(n, 0n)), 64n))
    case _:
      0n

# whether a command's number is parse_sess's (a command of the
# connection, of the server or of several databases)
def cmd_own(+id: Nat) -> Bool:
  Bool.or(Bool.and(Nat.is_le(100n, id), Nat.is_le(id, 120n)), Bool.and(Nat.is_le(152n, id), Nat.is_le(id, 152n)))
# END gen_commands: dispatch

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
      parse_flush(args, Own{SFlushAll{}})
    case 20n:  # FLUSHDB
      parse_flush(args, FlushDb{})
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
    case 37n:  # GETRANGE
      match args:
        case Con{k, Con{a, Con{b, Nil{}}}}:
          parse_getrange(k, a, b)
        case _:
          e_arity("getrange")
    case 38n:  # SUBSTR
      match args:
        case Con{k, Con{a, Con{b, Nil{}}}}:
          parse_getrange(k, a, b)
        case _:
          e_arity("substr")
    case 39n:  # SETRANGE
      match args:
        case Con{k, Con{o, Con{v, Nil{}}}}:
          parse_setrange(k, o, v)
        case _:
          e_arity("setrange")
    case 40n:  # GETBIT
      match args:
        case Con{k, Con{+o, Nil{}}}:
          parse_getbit(k, bitoff(o))
        case _:
          e_arity("getbit")
    case 41n:  # SETBIT
      match args:
        case Con{k, Con{+o, Con{b, Nil{}}}}:
          parse_setbit(k, bitoff(o), b)
        case _:
          e_arity("setbit")
    case 42n:  # BITCOUNT
      match args:
        case Con{k, rest}:
          Peek{k, PCount{rest}}
        case _:
          e_arity("bitcount")
    case 43n:  # BITPOS
      match args:
        case Con{k, Con{b, rest}}:
          parse_bitpos(k, b, rest)
        case _:
          e_arity("bitpos")
    case 44n:  # TOUCH: EXISTS, as Redis counts a key there (BendKV keeps
               # no time of last access)
      match args:
        case Nil{}:
          e_arity("touch")
        case Con{k, ks}:
          Exists{k <> ks}
    case 45n:  # MSETNX
      parse_msetnx(pairs(args))
    case 46n:  # RENAME
      match args:
        case Con{a, Con{b, Nil{}}}:
          Rename{a, b, False{}}
        case _:
          e_arity("rename")
    case 47n:  # RENAMENX
      match args:
        case Con{a, Con{b, Nil{}}}:
          Rename{a, b, True{}}
        case _:
          e_arity("renamenx")
    case 48n:  # BITOP
      match args:
        case Con{o, Con{d, Con{k, ks}}}:
          parse_bitop(bitop.kind(o), d, k <> ks)
        case _:
          e_arity("bitop")
    case 49n:  # BITFIELD
      match args:
        case Con{k, rest}:
          parse_bitfield(k, rest, False{})
        case _:
          e_arity("bitfield")
    case 50n:  # BITFIELD_RO
      match args:
        case Con{k, rest}:
          parse_bitfield(k, rest, True{})
        case _:
          e_arity("bitfield_ro")
    case 51n:  # HSET
      parse_hset(args, False{}, "hset")
    case 52n:  # HSETNX
      match args:
        case Con{k, Con{f, Con{v, Nil{}}}}:
          Upd{k, UHash{HWSetNx{f, v}}}
        case _:
          e_arity("hsetnx")
    case 53n:  # HGET
      match args:
        case Con{k, Con{f, Nil{}}}:
          Peek{k, PHash{HRGet{f}}}
        case _:
          e_arity("hget")
    case 54n:  # HMGET
      match args:
        case Con{k, Con{f, fs}}:
          Peek{k, PHash{HRMGet{f <> fs}}}
        case _:
          e_arity("hmget")
    case 55n:  # HMSET
      parse_hset(args, True{}, "hmset")
    case 56n:  # HDEL
      match args:
        case Con{k, Con{f, fs}}:
          Upd{k, UHash{HWDel{f <> fs}}}
        case _:
          e_arity("hdel")
    case 57n:  # HLEN
      match args:
        case Con{k, Nil{}}:
          Peek{k, PHash{HRLen{}}}
        case _:
          e_arity("hlen")
    case 58n:  # HSTRLEN
      match args:
        case Con{k, Con{f, Nil{}}}:
          Peek{k, PHash{HRStrlen{f}}}
        case _:
          e_arity("hstrlen")
    case 59n:  # HEXISTS
      match args:
        case Con{k, Con{f, Nil{}}}:
          Peek{k, PHash{HRExists{f}}}
        case _:
          e_arity("hexists")
    case 60n:  # HKEYS
      match args:
        case Con{k, Nil{}}:
          Peek{k, PHash{HRKeys{}}}
        case _:
          e_arity("hkeys")
    case 61n:  # HVALS
      match args:
        case Con{k, Nil{}}:
          Peek{k, PHash{HRVals{}}}
        case _:
          e_arity("hvals")
    case 62n:  # HGETALL
      match args:
        case Con{k, Nil{}}:
          Peek{k, PHash{HRAll{}}}
        case _:
          e_arity("hgetall")
    case 63n:  # HINCRBY
      match args:
        case Con{k, Con{f, Con{n, Nil{}}}}:
          parse_hincrby(k, f, int_read(n))
        case _:
          e_arity("hincrby")
    case 64n:  # HSCAN
      match args:
        case Con{k, Con{c, rest}}:
          parse_hscan(k, c, rest)
        case _:
          e_arity("hscan")
    case 65n:  # EVAL
      parse_eval(args)
    case 66n:  # LPUSH
      parse_lpush(args, True{}, False{}, "lpush")
    case 67n:  # RPUSH
      parse_lpush(args, False{}, False{}, "rpush")
    case 68n:  # LPUSHX
      parse_lpush(args, True{}, True{}, "lpushx")
    case 69n:  # RPUSHX
      parse_lpush(args, False{}, True{}, "rpushx")
    case 70n:  # LPOP
      parse_lpop(args, True{}, "lpop")
    case 71n:  # RPOP
      parse_lpop(args, False{}, "rpop")
    case 72n:  # LLEN
      match args:
        case Con{k, Nil{}}:
          Peek{k, PList{LRLen{}}}
        case _:
          e_arity("llen")
    case 73n:  # LINDEX
      match args:
        case Con{k, Con{i, Nil{}}}:
          Peek{k, PList{LRIndex{i}}}
        case _:
          e_arity("lindex")
    case 74n:  # LRANGE
      match args:
        case Con{k, Con{+a, Con{+b, Nil{}}}}:
          parse_lrange(Bool.and(lnum.ok(a), lnum.ok(b)), k, a, b)
        case _:
          e_arity("lrange")
    case 75n:  # LSET
      match args:
        case Con{k, Con{i, Con{v, Nil{}}}}:
          Upd{k, UList{LWSet{i, v}}}
        case _:
          e_arity("lset")
    case 76n:  # LINSERT
      match args:
        case Con{k, Con{+w, Con{p, Con{v, Nil{}}}}}:
          parse_linsert(Bool.pick(Nat, is_word(w, "AFTER"), 1n, Bool.pick(Nat, is_word(w, "BEFORE"), 2n, 0n)), k, p, v)
        case _:
          e_arity("linsert")
    case 77n:  # LREM
      match args:
        case Con{k, Con{+c, Con{v, Nil{}}}}:
          parse_lrem(lnum.ok(c), k, c, v)
        case _:
          e_arity("lrem")
    case 78n:  # LTRIM
      match args:
        case Con{k, Con{+a, Con{+b, Nil{}}}}:
          parse_ltrim(Bool.and(lnum.ok(a), lnum.ok(b)), k, a, b)
        case _:
          e_arity("ltrim")
    case 79n:  # LPOS
      match args:
        case Con{k, Con{x, +rest}}:
          parse_lpos(lpos.args(rest), k, x <> rest)
        case _:
          e_arity("lpos")
    case 80n:  # LMOVE
      match args:
        case Con{s, Con{d, Con{+a, Con{+b, Nil{}}}}}:
          parse_lmove(lends.of(lend.word(a), lend.word(b)), s, d)
        case _:
          e_arity("lmove")
    case 81n:  # RPOPLPUSH
      match args:
        case Con{s, Con{d, Nil{}}}:
          LMove{s, d, RtoL{}}
        case _:
          e_arity("rpoplpush")
    case 82n:  # LMPOP
      parse_lmpop(args)
    case 83n:  # SADD
      match args:
        case Con{k, Con{m, ms}}:
          Upd{k, UMems{SWAdd{m <> ms}}}
        case _:
          e_arity("sadd")
    case 84n:  # SREM
      match args:
        case Con{k, Con{m, ms}}:
          Upd{k, UMems{SWRem{m <> ms}}}
        case _:
          e_arity("srem")
    case 85n:  # SCARD
      match args:
        case Con{k, Nil{}}:
          Peek{k, PMems{SRCard{}}}
        case _:
          e_arity("scard")
    case 86n:  # SISMEMBER
      match args:
        case Con{k, Con{m, Nil{}}}:
          Peek{k, PMems{SRIs{m}}}
        case _:
          e_arity("sismember")
    case 87n:  # SMISMEMBER
      match args:
        case Con{k, Con{m, ms}}:
          Peek{k, PMems{SRMIs{m <> ms}}}
        case _:
          e_arity("smismember")
    case 88n:  # SMEMBERS
      match args:
        case Con{k, Nil{}}:
          Peek{k, PMems{SRAll{}}}
        case _:
          e_arity("smembers")
    case 89n:  # SSCAN
      match args:
        case Con{+k, Con{+c, rest}}:
          parse_sscan(k, c, rest)
        case _:
          e_arity("sscan")
    case 90n:  # SMOVE
      match args:
        case Con{a, Con{b, Con{m, Nil{}}}}:
          SMv{a, b, SMem{m}}
        case _:
          e_arity("smove")
    case 91n:  # SINTER
      parse_sop(KInter{}, args, "sinter")
    case 92n:  # SINTERCARD
      parse_sintercard(args)
    case 93n:  # SINTERSTORE
      parse_sstore(KInter{}, args, "sinterstore")
    case 94n:  # SUNION
      parse_sop(KUnion{}, args, "sunion")
    case 95n:  # SUNIONSTORE
      parse_sstore(KUnion{}, args, "sunionstore")
    case 96n:  # SDIFF
      parse_sop(KDiff{}, args, "sdiff")
    case 97n:  # SDIFFSTORE
      parse_sstore(KDiff{}, args, "sdiffstore")
    case 98n:  # INCRBYFLOAT
      match args:
        case Con{k, Con{n, Nil{}}}:
          Upd{k, UIncrF{n}}
        case _:
          e_arity("incrbyfloat")
    case 99n:  # HINCRBYFLOAT
      match args:
        case Con{+k, Con{+f, Con{n, Nil{}}}}:
          parse_hincrbyfloat(k, f, F.ld.parse(n))
        case _:
          e_arity("hincrbyfloat")
    case 121n:  # ZADD
      parse_zadd(args)
    case 122n:  # ZINCRBY
      parse_zincrby(args)
    case 123n:  # ZREM
      match args:
        case Con{k, Con{m, ms}}:
          Upd{k, UZset{ZWRem{m <> ms}}}
        case _:
          e_arity("zrem")
    case 124n:  # ZCARD
      match args:
        case Con{k, Nil{}}:
          Peek{k, PZset{ZRCard{}}}
        case _:
          e_arity("zcard")
    case 125n:  # ZSCORE
      match args:
        case Con{k, Con{m, Nil{}}}:
          Peek{k, PZset{ZRScore{m}}}
        case _:
          e_arity("zscore")
    case 126n:  # ZMSCORE
      match args:
        case Con{k, Con{m, ms}}:
          Peek{k, PZset{ZRMScore{m <> ms}}}
        case _:
          e_arity("zmscore")
    case 127n:  # ZRANK
      match args:
        case Con{k, Con{m, Nil{}}}:
          Peek{k, PZset{ZRRank{m}}}
        case _:
          e_arity("zrank")
    case 128n:  # ZREVRANK
      match args:
        case Con{k, Con{m, Nil{}}}:
          Peek{k, PZset{ZRRevRank{m}}}
        case _:
          e_arity("zrevrank")
    case 129n:  # ZCOUNT
      parse_zcount(args, 2n, "zcount")
    case 130n:  # ZLEXCOUNT
      parse_zcount(args, 3n, "zlexcount")
    case 131n:  # ZRANGE
      parse_zrange(args, 0n, 0n, "zrange")
    case 132n:  # ZRANGEBYSCORE
      parse_zrange(args, 1n, 2n, "zrangebyscore")
    case 133n:  # ZREVRANGEBYSCORE
      parse_zrange(args, 2n, 2n, "zrevrangebyscore")
    case 134n:  # ZRANGEBYLEX
      parse_zrange(args, 1n, 3n, "zrangebylex")
    case 135n:  # ZREVRANGEBYLEX
      parse_zrange(args, 2n, 3n, "zrevrangebylex")
    case 136n:  # ZREVRANGE
      parse_zrange(args, 2n, 1n, "zrevrange")
    case 137n:  # ZREMRANGEBYRANK
      parse_zremrange(args, 1n, "zremrangebyrank")
    case 138n:  # ZREMRANGEBYSCORE
      parse_zremrange(args, 2n, "zremrangebyscore")
    case 139n:  # ZREMRANGEBYLEX
      parse_zremrange(args, 3n, "zremrangebylex")
    case 140n:  # ZPOPMIN
      parse_zpop(args, False{}, "zpopmin")
    case 141n:  # ZPOPMAX
      parse_zpop(args, True{}, "zpopmax")
    case 142n:  # ZSCAN
      match args:
        case Con{+k, Con{+c, rest}}:
          parse_zscan(k, c, rest)
        case _:
          e_arity("zscan")
    case 143n:  # ZUNION
      parse_zop(args, 1n, "zunion")
    case 144n:  # ZINTER
      parse_zop(args, 2n, "zinter")
    case 145n:  # ZDIFF
      parse_zop(args, 3n, "zdiff")
    case 146n:  # ZINTERCARD
      parse_zop(args, 4n, "zintercard")
    case 147n:  # ZUNIONSTORE
      parse_zstore(args, 1n, "zunionstore")
    case 148n:  # ZINTERSTORE
      parse_zstore(args, 2n, "zinterstore")
    case 149n:  # ZDIFFSTORE
      parse_zstore(args, 3n, "zdiffstore")
    case 150n:  # ZRANGESTORE
      parse_zrangestore(args)
    case 151n:  # ZMPOP
      parse_zmpop(args)
    case _:
      e_unknown(name, args)

# the session commands (cmd_own), parsed into their ops
def parse_sess(id: Nat, name: String, args: List<&2, String>) -> SessOp:
  match id:
    case 100n:  # SELECT
      match args:
        case Con{d, Nil{}}:
          SSelect{d}
        case _:
          s_arity("select")
    case 101n:  # HELLO
      SHello{args}
    case 102n:  # AUTH
      match args:
        case Nil{}:
          s_arity("auth")
        case Con{a, rest}:
          SAuth{a <> rest}
    case 103n:  # QUIT
      SQuit{}
    case 104n:  # RESET
      match args:
        case Nil{}:
          SReset{}
        case _:
          s_arity("reset")
    case 105n:  # CLIENT
      match args:
        case Nil{}:
          s_arity("client")
        case Con{+sub, rest}:
          +up = String.to_upper(sub)
          parse_client(client_id(up, String.length(up)), sub, rest)
    case 106n:  # FUNCTION
      match args:
        case Nil{}:
          s_arity("function")
        case Con{+sub, rest}:
          +up = String.to_upper(sub)
          parse_function(function_id(up, String.length(up)), sub, rest)
    case 107n:  # CONFIG
      match args:
        case Nil{}:
          s_arity("config")
        case Con{+sub, rest}:
          +up = String.to_upper(sub)
          parse_config(config_id(up, String.length(up)), sub, rest)
    case 108n:  # INFO
      SInfo{args}
    case 109n:  # COMMAND
      match args:
        case Nil{}:
          SCommand{Nil{}}
        case Con{+sub, rest}:
          +up = String.to_upper(sub)
          parse_command(command_id(up, String.length(up)), sub, rest)
    case 110n:  # RANDOMKEY
      match args:
        case Nil{}:
          SRandomKey{}
        case _:
          s_arity("randomkey")
    case 111n:  # SWAPDB
      match args:
        case Con{a, Con{b, Nil{}}}:
          SSwapDb{a, b}
        case _:
          s_arity("swapdb")
    case 112n:  # MOVE
      match args:
        case Con{k, Con{d, Nil{}}}:
          SMove{k, d}
        case _:
          s_arity("move")
    case 113n:  # TIME
      match args:
        case Nil{}:
          STime{}
        case _:
          s_arity("time")
    case 114n:  # OBJECT
      match args:
        case Nil{}:
          s_arity("object")
        case Con{+sub, rest}:
          +up = String.to_upper(sub)
          parse_object(object_id(up, String.length(up)), sub, rest)
    case 115n:  # COPY
      match args:
        case Con{a, Con{b, rest}}:
          SCopy{a <> b <> rest}
        case _:
          s_arity("copy")
    case 116n:  # LCS
      match args:
        case Con{a, Con{b, rest}}:
          SLcs{a <> b <> rest}
        case _:
          s_arity("lcs")
    case 117n:  # HRANDFIELD
      match args:
        case Con{k, rest}:
          SHRandField{k, rest}
        case _:
          s_arity("hrandfield")
    case 118n:  # MEMORY
      match args:
        case Nil{}:
          s_arity("memory")
        case Con{+sub, rest}:
          +up = String.to_upper(sub)
          parse_memory(memory_id(up, String.length(up)), sub, rest)
    case 119n:  # SPOP
      match args:
        case Con{k, rest}:
          SSPop{k, rest}
        case Nil{}:
          s_arity("spop")
    case 120n:  # SRANDMEMBER
      match args:
        case Con{k, rest}:
          SSRandMember{k, rest}
        case Nil{}:
          s_arity("srandmember")
    case 152n:  # ZRANDMEMBER
      match args:
        case Con{k, rest}:
          SZRandMember{k, rest}
        case Nil{}:
          s_arity("zrandmember")
    case _:
      SBad{RError{no_newlines("ERR unknown command '" ++ String.take(cstr(name), 128n) ++ "', with args beginning with: " ++ unknown.args(args, ""))}}

# a command of number id: a command of the connection, of the server or
# of several databases (parse_sess) for a number cmd_own names
def parse_of(own: Bool, +id: Nat, name: String, args: List<&2, String>) -> Cmd:
  match own:
    case True{}:
      Own{parse_sess(id, name, args)}
    case False{}:
      parse_id(id, name, args)

def parse_named(+name: String, args: List<&2, String>) -> Cmd:
  +up = String.to_upper(name)
  +id = cmd_id(up, String.length(up))
  parse_of(cmd_own(id), id, name, args)

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
# subcommands of CLIENT, FUNCTION, CONFIG, COMMAND and OBJECT; 0 is an unknown
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
    case 37n:
      37n
    case 38n:
      38n
    case 39n:
      39n
    case 40n:
      40n
    case 41n:
      41n
    case 42n:
      42n
    case 43n:
      43n
    case 44n:
      44n
    case 45n:
      45n
    case 46n:
      46n
    case 47n:
      47n
    case 48n:
      48n
    case 49n:
      49n
    case 50n:
      50n
    case 51n:
      51n
    case 52n:
      52n
    case 53n:
      53n
    case 54n:
      54n
    case 55n:
      55n
    case 56n:
      56n
    case 57n:
      57n
    case 58n:
      58n
    case 59n:
      59n
    case 60n:
      60n
    case 61n:
      61n
    case 62n:
      62n
    case 63n:
      63n
    case 64n:
      64n
    case 65n:
      65n
    case 66n:
      66n
    case 67n:
      67n
    case 68n:
      68n
    case 69n:
      69n
    case 70n:
      70n
    case 71n:
      71n
    case 72n:
      72n
    case 73n:
      73n
    case 74n:
      74n
    case 75n:
      75n
    case 76n:
      76n
    case 77n:
      77n
    case 78n:
      78n
    case 79n:
      79n
    case 80n:
      80n
    case 81n:
      81n
    case 82n:
      82n
    case 83n:
      83n
    case 84n:
      84n
    case 85n:
      85n
    case 86n:
      86n
    case 87n:
      87n
    case 88n:
      88n
    case 89n:
      89n
    case 90n:
      90n
    case 91n:
      91n
    case 92n:
      92n
    case 93n:
      93n
    case 94n:
      94n
    case 95n:
      95n
    case 96n:
      96n
    case 97n:
      97n
    case 98n:
      98n
    case 99n:
      99n
    case 100n:
      100n
    case 101n:
      101n
    case 102n:
      102n
    case 103n:
      103n
    case 104n:
      104n
    case 105n:
      105n
    case 106n:
      106n
    case 107n:
      107n
    case 108n:
      108n
    case 109n:
      109n
    case 110n:
      110n
    case 111n:
      111n
    case 112n:
      112n
    case 113n:
      113n
    case 114n:
      114n
    case 115n:
      115n
    case 116n:
      116n
    case 117n:
      117n
    case 118n:
      118n
    case 119n:
      119n
    case 120n:
      120n
    case 121n:
      121n
    case 122n:
      122n
    case 123n:
      123n
    case 124n:
      124n
    case 125n:
      125n
    case 126n:
      126n
    case 127n:
      127n
    case 128n:
      128n
    case 129n:
      129n
    case 130n:
      130n
    case 131n:
      131n
    case 132n:
      132n
    case 133n:
      133n
    case 134n:
      134n
    case 135n:
      135n
    case 136n:
      136n
    case 137n:
      137n
    case 138n:
      138n
    case 139n:
      139n
    case 140n:
      140n
    case 141n:
      141n
    case 142n:
      142n
    case 143n:
      143n
    case 144n:
      144n
    case 145n:
      145n
    case 146n:
      146n
    case 147n:
      147n
    case 148n:
      148n
    case 149n:
      149n
    case 150n:
      150n
    case 151n:
      151n
    case 152n:
      152n
    case _:
      0n

# a subcommand of CLIENT's key, by its number; 0 for none
def stat.sub.client(+sub: Nat) -> Nat:
  match sub:
    case 1n:
      153n
    case 2n:
      154n
    case 3n:
      155n
    case 4n:
      156n
    case 5n:
      157n
    case 6n:
      158n
    case 7n:
      159n
    case 8n:
      160n
    case 9n:
      161n
    case 10n:
      162n
    case _:
      0n

# a subcommand of FUNCTION's key, by its number; 0 for none
def stat.sub.function(+sub: Nat) -> Nat:
  match sub:
    case 1n:
      163n
    case 2n:
      164n
    case _:
      0n

# a subcommand of CONFIG's key, by its number; 0 for none
def stat.sub.config(+sub: Nat) -> Nat:
  match sub:
    case 1n:
      165n
    case 2n:
      166n
    case 3n:
      167n
    case 4n:
      168n
    case 5n:
      169n
    case _:
      0n

# a subcommand of COMMAND's key, by its number; 0 for none
def stat.sub.command(+sub: Nat) -> Nat:
  match sub:
    case 1n:
      170n
    case 2n:
      171n
    case 3n:
      172n
    case 4n:
      173n
    case 5n:
      174n
    case 6n:
      175n
    case 7n:
      176n
    case _:
      0n

# a subcommand of OBJECT's key, by its number; 0 for none
def stat.sub.object(+sub: Nat) -> Nat:
  match sub:
    case 1n:
      177n
    case 2n:
      178n
    case 3n:
      179n
    case 4n:
      180n
    case 5n:
      181n
    case _:
      0n

# a subcommand of MEMORY's key, by its number; 0 for none
def stat.sub.memory(+sub: Nat) -> Nat:
  match sub:
    case 1n:
      182n
    case 2n:
      183n
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
      "getrange"
    case 38n:
      "substr"
    case 39n:
      "setrange"
    case 40n:
      "getbit"
    case 41n:
      "setbit"
    case 42n:
      "bitcount"
    case 43n:
      "bitpos"
    case 44n:
      "touch"
    case 45n:
      "msetnx"
    case 46n:
      "rename"
    case 47n:
      "renamenx"
    case 48n:
      "bitop"
    case 49n:
      "bitfield"
    case 50n:
      "bitfield_ro"
    case 51n:
      "hset"
    case 52n:
      "hsetnx"
    case 53n:
      "hget"
    case 54n:
      "hmget"
    case 55n:
      "hmset"
    case 56n:
      "hdel"
    case 57n:
      "hlen"
    case 58n:
      "hstrlen"
    case 59n:
      "hexists"
    case 60n:
      "hkeys"
    case 61n:
      "hvals"
    case 62n:
      "hgetall"
    case 63n:
      "hincrby"
    case 64n:
      "hscan"
    case 65n:
      "eval"
    case 66n:
      "lpush"
    case 67n:
      "rpush"
    case 68n:
      "lpushx"
    case 69n:
      "rpushx"
    case 70n:
      "lpop"
    case 71n:
      "rpop"
    case 72n:
      "llen"
    case 73n:
      "lindex"
    case 74n:
      "lrange"
    case 75n:
      "lset"
    case 76n:
      "linsert"
    case 77n:
      "lrem"
    case 78n:
      "ltrim"
    case 79n:
      "lpos"
    case 80n:
      "lmove"
    case 81n:
      "rpoplpush"
    case 82n:
      "lmpop"
    case 83n:
      "sadd"
    case 84n:
      "srem"
    case 85n:
      "scard"
    case 86n:
      "sismember"
    case 87n:
      "smismember"
    case 88n:
      "smembers"
    case 89n:
      "sscan"
    case 90n:
      "smove"
    case 91n:
      "sinter"
    case 92n:
      "sintercard"
    case 93n:
      "sinterstore"
    case 94n:
      "sunion"
    case 95n:
      "sunionstore"
    case 96n:
      "sdiff"
    case 97n:
      "sdiffstore"
    case 98n:
      "incrbyfloat"
    case 99n:
      "hincrbyfloat"
    case 100n:
      "select"
    case 101n:
      "hello"
    case 102n:
      "auth"
    case 103n:
      "quit"
    case 104n:
      "reset"
    case 105n:
      "client"
    case 106n:
      "function"
    case 107n:
      "config"
    case 108n:
      "info"
    case 109n:
      "command"
    case 110n:
      "randomkey"
    case 111n:
      "swapdb"
    case 112n:
      "move"
    case 113n:
      "time"
    case 114n:
      "object"
    case 115n:
      "copy"
    case 116n:
      "lcs"
    case 117n:
      "hrandfield"
    case 118n:
      "memory"
    case 119n:
      "spop"
    case 120n:
      "srandmember"
    case 121n:
      "zadd"
    case 122n:
      "zincrby"
    case 123n:
      "zrem"
    case 124n:
      "zcard"
    case 125n:
      "zscore"
    case 126n:
      "zmscore"
    case 127n:
      "zrank"
    case 128n:
      "zrevrank"
    case 129n:
      "zcount"
    case 130n:
      "zlexcount"
    case 131n:
      "zrange"
    case 132n:
      "zrangebyscore"
    case 133n:
      "zrevrangebyscore"
    case 134n:
      "zrangebylex"
    case 135n:
      "zrevrangebylex"
    case 136n:
      "zrevrange"
    case 137n:
      "zremrangebyrank"
    case 138n:
      "zremrangebyscore"
    case 139n:
      "zremrangebylex"
    case 140n:
      "zpopmin"
    case 141n:
      "zpopmax"
    case 142n:
      "zscan"
    case 143n:
      "zunion"
    case 144n:
      "zinter"
    case 145n:
      "zdiff"
    case 146n:
      "zintercard"
    case 147n:
      "zunionstore"
    case 148n:
      "zinterstore"
    case 149n:
      "zdiffstore"
    case 150n:
      "zrangestore"
    case 151n:
      "zmpop"
    case 152n:
      "zrandmember"
    case 153n:
      "client|id"
    case 154n:
      "client|help"
    case 155n:
      "client|reply"
    case 156n:
      "client|getname"
    case 157n:
      "client|setname"
    case 158n:
      "client|caching"
    case 159n:
      "client|unblock"
    case 160n:
      "client|getredir"
    case 161n:
      "client|no-evict"
    case 162n:
      "client|trackinginfo"
    case 163n:
      "function|flush"
    case 164n:
      "function|help"
    case 165n:
      "config|get"
    case 166n:
      "config|set"
    case 167n:
      "config|resetstat"
    case 168n:
      "config|rewrite"
    case 169n:
      "config|help"
    case 170n:
      "command|info"
    case 171n:
      "command|docs"
    case 172n:
      "command|list"
    case 173n:
      "command|help"
    case 174n:
      "command|count"
    case 175n:
      "command|getkeys"
    case 176n:
      "command|getkeysandflags"
    case 177n:
      "object|help"
    case 178n:
      "object|freq"
    case 179n:
      "object|encoding"
    case 180n:
      "object|refcount"
    case 181n:
      "object|idletime"
    case 182n:
      "memory|help"
    case 183n:
      "memory|usage"
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
      8n
    case 38n:
      8n
    case 39n:
      8n
    case 40n:
      6n
    case 41n:
      8n
    case 42n:
      5n
    case 43n:
      7n
    case 44n:
      5n
    case 45n:
      7n
    case 46n:
      6n
    case 47n:
      6n
    case 48n:
      9n
    case 49n:
      5n
    case 50n:
      5n
    case 51n:
      9n
    case 52n:
      8n
    case 53n:
      6n
    case 54n:
      7n
    case 55n:
      9n
    case 56n:
      7n
    case 57n:
      4n
    case 58n:
      6n
    case 59n:
      6n
    case 60n:
      4n
    case 61n:
      4n
    case 62n:
      4n
    case 63n:
      8n
    case 64n:
      7n
    case 65n:
      7n
    case 66n:
      7n
    case 67n:
      7n
    case 68n:
      7n
    case 69n:
      7n
    case 70n:
      5n
    case 71n:
      5n
    case 72n:
      4n
    case 73n:
      6n
    case 74n:
      8n
    case 75n:
      8n
    case 76n:
      10n
    case 77n:
      8n
    case 78n:
      8n
    case 79n:
      7n
    case 80n:
      10n
    case 81n:
      6n
    case 82n:
      9n
    case 83n:
      7n
    case 84n:
      7n
    case 85n:
      4n
    case 86n:
      6n
    case 87n:
      7n
    case 88n:
      4n
    case 89n:
      7n
    case 90n:
      8n
    case 91n:
      5n
    case 92n:
      7n
    case 93n:
      7n
    case 94n:
      5n
    case 95n:
      7n
    case 96n:
      5n
    case 97n:
      7n
    case 98n:
      6n
    case 99n:
      8n
    case 100n:
      4n
    case 101n:
      3n
    case 102n:
      5n
    case 103n:
      3n
    case 104n:
      2n
    case 105n:
      5n
    case 106n:
      5n
    case 107n:
      5n
    case 108n:
      3n
    case 109n:
      3n
    case 110n:
      2n
    case 111n:
      6n
    case 112n:
      6n
    case 113n:
      2n
    case 114n:
      5n
    case 115n:
      7n
    case 116n:
      7n
    case 117n:
      5n
    case 118n:
      5n
    case 119n:
      5n
    case 120n:
      5n
    case 121n:
      9n
    case 122n:
      8n
    case 123n:
      7n
    case 124n:
      4n
    case 125n:
      6n
    case 126n:
      7n
    case 127n:
      6n
    case 128n:
      6n
    case 129n:
      8n
    case 130n:
      8n
    case 131n:
      9n
    case 132n:
      9n
    case 133n:
      9n
    case 134n:
      9n
    case 135n:
      9n
    case 136n:
      9n
    case 137n:
      8n
    case 138n:
      8n
    case 139n:
      8n
    case 140n:
      5n
    case 141n:
      5n
    case 142n:
      7n
    case 143n:
      7n
    case 144n:
      7n
    case 145n:
      7n
    case 146n:
      7n
    case 147n:
      9n
    case 148n:
      9n
    case 149n:
      9n
    case 150n:
      11n
    case 151n:
      9n
    case 152n:
      5n
    case 153n:
      4n
    case 154n:
      4n
    case 155n:
      6n
    case 156n:
      4n
    case 157n:
      6n
    case 158n:
      6n
    case 159n:
      7n
    case 160n:
      4n
    case 161n:
      6n
    case 162n:
      4n
    case 163n:
      5n
    case 164n:
      4n
    case 165n:
      7n
    case 166n:
      9n
    case 167n:
      4n
    case 168n:
      4n
    case 169n:
      4n
    case 170n:
      5n
    case 171n:
      5n
    case 172n:
      5n
    case 173n:
      4n
    case 174n:
      4n
    case 175n:
      9n
    case 176n:
      9n
    case 177n:
      4n
    case 178n:
      6n
    case 179n:
      6n
    case 180n:
      6n
    case 181n:
      6n
    case 182n:
      4n
    case 183n:
      7n
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
    case 39n:
      True{}
    case 42n:
      True{}
    case 43n:
      True{}
    case 46n:
      True{}
    case 47n:
      True{}
    case 49n:
      True{}
    case 51n:
      True{}
    case 52n:
      True{}
    case 53n:
      True{}
    case 54n:
      True{}
    case 55n:
      True{}
    case 56n:
      True{}
    case 57n:
      True{}
    case 58n:
      True{}
    case 59n:
      True{}
    case 60n:
      True{}
    case 61n:
      True{}
    case 62n:
      True{}
    case 63n:
      True{}
    case 64n:
      True{}
    case 66n:
      True{}
    case 67n:
      True{}
    case 68n:
      True{}
    case 69n:
      True{}
    case 70n:
      True{}
    case 71n:
      True{}
    case 72n:
      True{}
    case 73n:
      True{}
    case 74n:
      True{}
    case 75n:
      True{}
    case 76n:
      True{}
    case 77n:
      True{}
    case 78n:
      True{}
    case 79n:
      True{}
    case 80n:
      True{}
    case 81n:
      True{}
    case 82n:
      True{}
    case 83n:
      True{}
    case 84n:
      True{}
    case 85n:
      True{}
    case 86n:
      True{}
    case 87n:
      True{}
    case 88n:
      True{}
    case 89n:
      True{}
    case 90n:
      True{}
    case 91n:
      True{}
    case 92n:
      True{}
    case 93n:
      True{}
    case 94n:
      True{}
    case 95n:
      True{}
    case 96n:
      True{}
    case 97n:
      True{}
    case 98n:
      True{}
    case 99n:
      True{}
    case 116n:
      True{}
    case 117n:
      True{}
    case 119n:
      True{}
    case 120n:
      True{}
    case 121n:
      True{}
    case 122n:
      True{}
    case 123n:
      True{}
    case 124n:
      True{}
    case 125n:
      True{}
    case 126n:
      True{}
    case 127n:
      True{}
    case 128n:
      True{}
    case 129n:
      True{}
    case 130n:
      True{}
    case 131n:
      True{}
    case 132n:
      True{}
    case 133n:
      True{}
    case 134n:
      True{}
    case 135n:
      True{}
    case 136n:
      True{}
    case 137n:
      True{}
    case 138n:
      True{}
    case 139n:
      True{}
    case 140n:
      True{}
    case 141n:
      True{}
    case 142n:
      True{}
    case 143n:
      True{}
    case 144n:
      True{}
    case 145n:
      True{}
    case 146n:
      True{}
    case 147n:
      True{}
    case 148n:
      True{}
    case 149n:
      True{}
    case 150n:
      True{}
    case 151n:
      True{}
    case 152n:
      True{}
    case 178n:
      True{}
    case 181n:
      True{}
    case 183n:
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
    case 288n:
      1369
    case 289n:
      1370
    case 290n:
      1372
    case 291n:
      1379
    case 292n:
      1381
    case 293n:
      1382
    case 294n:
      1385
    case 295n:
      1386
    case 296n:
      1388
    case 297n:
      1393
    case 298n:
      1394
    case 299n:
      1396
    case 300n:
      1400
    case 301n:
      1415
    case 302n:
      1419
    case 303n:
      1421
    case 304n:
      1422
    case 305n:
      1427
    case 306n:
      1429
    case 307n:
      1430
    case 308n:
      1433
    case 309n:
      1434
    case 310n:
      1436
    case 311n:
      1443
    case 312n:
      1445
    case 313n:
      1446
    case 314n:
      1449
    case 315n:
      1450
    case 316n:
      1452
    case 317n:
      1457
    case 318n:
      1458
    case 319n:
      1460
    case 320n:
      1464
    case 321n:
      1475
    case 322n:
      1477
    case 323n:
      1478
    case 324n:
      1481
    case 325n:
      1482
    case 326n:
      1484
    case 327n:
      1489
    case 328n:
      1490
    case 329n:
      1492
    case 330n:
      1496
    case 331n:
      1505
    case 332n:
      1506
    case 333n:
      1508
    case 334n:
      1512
    case 335n:
      1520
    case 336n:
      1551
    case 337n:
      1559
    case 338n:
      1563
    case 339n:
      1565
    case 340n:
      1566
    case 341n:
      1575
    case 342n:
      1579
    case 343n:
      1581
    case 344n:
      1582
    case 345n:
      1587
    case 346n:
      1589
    case 347n:
      1590
    case 348n:
      1593
    case 349n:
      1594
    case 350n:
      1596
    case 351n:
      1607
    case 352n:
      1611
    case 353n:
      1613
    case 354n:
      1614
    case 355n:
      1619
    case 356n:
      1621
    case 357n:
      1622
    case 358n:
      1625
    case 359n:
      1626
    case 360n:
      1628
    case 361n:
      1635
    case 362n:
      1637
    case 363n:
      1638
    case 364n:
      1641
    case 365n:
      1642
    case 366n:
      1644
    case 367n:
      1649
    case 368n:
      1650
    case 369n:
      1652
    case 370n:
      1656
    case 371n:
      1671
    case 372n:
      1675
    case 373n:
      1677
    case 374n:
      1678
    case 375n:
      1683
    case 376n:
      1685
    case 377n:
      1686
    case 378n:
      1689
    case 379n:
      1690
    case 380n:
      1692
    case 381n:
      1699
    case 382n:
      1701
    case 383n:
      1702
    case 384n:
      1705
    case 385n:
      1706
    case 386n:
      1708
    case 387n:
      1713
    case 388n:
      1714
    case 389n:
      1716
    case 390n:
      1720
    case 391n:
      1731
    case 392n:
      1733
    case 393n:
      1734
    case 394n:
      1737
    case 395n:
      1738
    case 396n:
      1740
    case 397n:
      1745
    case 398n:
      1746
    case 399n:
      1748
    case 400n:
      1752
    case 401n:
      1761
    case 402n:
      1762
    case 403n:
      1764
    case 404n:
      1768
    case 405n:
      1776
    case 406n:
      1799
    case 407n:
      1803
    case 408n:
      1805
    case 409n:
      1806
    case 410n:
      1811
    case 411n:
      1813
    case 412n:
      1814
    case 413n:
      1817
    case 414n:
      1818
    case 415n:
      1820
    case 416n:
      1827
    case 417n:
      1829
    case 418n:
      1830
    case 419n:
      1833
    case 420n:
      1834
    case 421n:
      1836
    case 422n:
      1841
    case 423n:
      1842
    case 424n:
      1844
    case 425n:
      1848
    case 426n:
      1859
    case 427n:
      1861
    case 428n:
      1862
    case 429n:
      1865
    case 430n:
      1866
    case 431n:
      1868
    case 432n:
      1873
    case 433n:
      1874
    case 434n:
      1876
    case 435n:
      1880
    case 436n:
      1889
    case 437n:
      1890
    case 438n:
      1892
    case 439n:
      1896
    case 440n:
      1904
    case 441n:
      1923
    case 442n:
      1925
    case 443n:
      1926
    case 444n:
      1929
    case 445n:
      1930
    case 446n:
      1932
    case 447n:
      1937
    case 448n:
      1938
    case 449n:
      1940
    case 450n:
      1944
    case 451n:
      1953
    case 452n:
      1954
    case 453n:
      1956
    case 454n:
      1960
    case 455n:
      1968
    case 456n:
      1985
    case 457n:
      1986
    case 458n:
      1988
    case 459n:
      1992
    case 460n:
      2000
    case 461n:
      2016
    case 462n:
      2079
    case 463n:
      2095
    case 464n:
      2103
    case 465n:
      2107
    case 466n:
      2109
    case 467n:
      2110
    case 468n:
      2127
    case 469n:
      2135
    case 470n:
      2139
    case 471n:
      2141
    case 472n:
      2142
    case 473n:
      2151
    case 474n:
      2155
    case 475n:
      2157
    case 476n:
      2158
    case 477n:
      2163
    case 478n:
      2165
    case 479n:
      2166
    case 480n:
      2169
    case 481n:
      2170
    case 482n:
      2172
    case 483n:
      2191
    case 484n:
      2199
    case 485n:
      2203
    case 486n:
      2205
    case 487n:
      2206
    case 488n:
      2215
    case 489n:
      2219
    case 490n:
      2221
    case 491n:
      2222
    case 492n:
      2227
    case 493n:
      2229
    case 494n:
      2230
    case 495n:
      2233
    case 496n:
      2234
    case 497n:
      2236
    case 498n:
      2247
    case 499n:
      2251
    case 500n:
      2253
    case 501n:
      2254
    case 502n:
      2259
    case 503n:
      2261
    case 504n:
      2262
    case 505n:
      2265
    case 506n:
      2266
    case 507n:
      2268
    case 508n:
      2275
    case 509n:
      2277
    case 510n:
      2278
    case 511n:
      2281
    case 512n:
      2282
    case 513n:
      2284
    case 514n:
      2289
    case 515n:
      2290
    case 516n:
      2292
    case 517n:
      2296
    case 518n:
      2319
    case 519n:
      2327
    case 520n:
      2331
    case 521n:
      2333
    case 522n:
      2334
    case 523n:
      2343
    case 524n:
      2347
    case 525n:
      2349
    case 526n:
      2350
    case 527n:
      2355
    case 528n:
      2357
    case 529n:
      2358
    case 530n:
      2361
    case 531n:
      2362
    case 532n:
      2364
    case 533n:
      2375
    case 534n:
      2379
    case 535n:
      2381
    case 536n:
      2382
    case 537n:
      2387
    case 538n:
      2389
    case 539n:
      2390
    case 540n:
      2393
    case 541n:
      2394
    case 542n:
      2396
    case 543n:
      2403
    case 544n:
      2405
    case 545n:
      2406
    case 546n:
      2409
    case 547n:
      2410
    case 548n:
      2412
    case 549n:
      2417
    case 550n:
      2418
    case 551n:
      2420
    case 552n:
      2424
    case 553n:
      2439
    case 554n:
      2443
    case 555n:
      2445
    case 556n:
      2446
    case 557n:
      2451
    case 558n:
      2453
    case 559n:
      2454
    case 560n:
      2457
    case 561n:
      2458
    case 562n:
      2460
    case 563n:
      2467
    case 564n:
      2469
    case 565n:
      2470
    case 566n:
      2473
    case 567n:
      2474
    case 568n:
      2476
    case 569n:
      2481
    case 570n:
      2482
    case 571n:
      2484
    case 572n:
      2488
    case 573n:
      2499
    case 574n:
      2501
    case 575n:
      2502
    case 576n:
      2505
    case 577n:
      2506
    case 578n:
      2508
    case 579n:
      2513
    case 580n:
      2514
    case 581n:
      2516
    case 582n:
      2520
    case 583n:
      2529
    case 584n:
      2530
    case 585n:
      2532
    case 586n:
      2536
    case 587n:
      2544
    case 588n:
      2575
    case 589n:
      2583
    case 590n:
      2587
    case 591n:
      2589
    case 592n:
      2590
    case 593n:
      2599
    case 594n:
      2603
    case 595n:
      2605
    case 596n:
      2606
    case 597n:
      2611
    case 598n:
      2613
    case 599n:
      2614
    case 600n:
      2617
    case 601n:
      2618
    case 602n:
      2620
    case 603n:
      2631
    case 604n:
      2635
    case 605n:
      2637
    case 606n:
      2638
    case 607n:
      2643
    case 608n:
      2645
    case 609n:
      2646
    case 610n:
      2649
    case 611n:
      2650
    case 612n:
      2652
    case 613n:
      2659
    case 614n:
      2661
    case 615n:
      2662
    case 616n:
      2665
    case 617n:
      2666
    case 618n:
      2668
    case 619n:
      2673
    case 620n:
      2674
    case 621n:
      2676
    case 622n:
      2680
    case 623n:
      2695
    case 624n:
      2699
    case 625n:
      2701
    case 626n:
      2702
    case 627n:
      2707
    case 628n:
      2709
    case 629n:
      2710
    case 630n:
      2713
    case 631n:
      2714
    case 632n:
      2716
    case 633n:
      2723
    case 634n:
      2725
    case 635n:
      2726
    case 636n:
      2729
    case 637n:
      2730
    case 638n:
      2732
    case 639n:
      2737
    case 640n:
      2738
    case 641n:
      2740
    case 642n:
      2744
    case 643n:
      2755
    case 644n:
      2757
    case 645n:
      2758
    case 646n:
      2761
    case 647n:
      2762
    case 648n:
      2764
    case 649n:
      2769
    case 650n:
      2770
    case 651n:
      2772
    case 652n:
      2776
    case 653n:
      2785
    case 654n:
      2786
    case 655n:
      2788
    case 656n:
      2792
    case 657n:
      2800
    case 658n:
      2823
    case 659n:
      2827
    case 660n:
      2829
    case 661n:
      2830
    case 662n:
      2835
    case 663n:
      2837
    case 664n:
      2838
    case 665n:
      2841
    case 666n:
      2842
    case 667n:
      2844
    case 668n:
      2851
    case 669n:
      2853
    case 670n:
      2854
    case 671n:
      2857
    case 672n:
      2858
    case 673n:
      2860
    case 674n:
      2865
    case 675n:
      2866
    case 676n:
      2868
    case 677n:
      2872
    case 678n:
      2883
    case 679n:
      2885
    case 680n:
      2886
    case 681n:
      2889
    case 682n:
      2890
    case 683n:
      2892
    case 684n:
      2897
    case 685n:
      2898
    case 686n:
      2900
    case 687n:
      2904
    case 688n:
      2913
    case 689n:
      2914
    case 690n:
      2916
    case 691n:
      2920
    case 692n:
      2928
    case 693n:
      2947
    case 694n:
      2949
    case 695n:
      2950
    case 696n:
      2953
    case 697n:
      2954
    case 698n:
      2956
    case 699n:
      2961
    case 700n:
      2962
    case 701n:
      2964
    case 702n:
      2968
    case 703n:
      2977
    case 704n:
      2978
    case 705n:
      2980
    case 706n:
      2984
    case 707n:
      2992
    case 708n:
      3009
    case 709n:
      3010
    case 710n:
      3012
    case 711n:
      3016
    case 712n:
      3024
    case 713n:
      3040
    case 714n:
      3087
    case 715n:
      3095
    case 716n:
      3099
    case 717n:
      3101
    case 718n:
      3102
    case 719n:
      3111
    case 720n:
      3115
    case 721n:
      3117
    case 722n:
      3118
    case 723n:
      3123
    case 724n:
      3125
    case 725n:
      3126
    case 726n:
      3129
    case 727n:
      3130
    case 728n:
      3132
    case 729n:
      3143
    case 730n:
      3147
    case 731n:
      3149
    case 732n:
      3150
    case 733n:
      3155
    case 734n:
      3157
    case 735n:
      3158
    case _:
      63

def stat.code.lo0(+lo: Nat) -> Nat:
  match lo:
    case 63n:
      0n
    case _:
      0n

def stat.code.lo1(+lo: Nat) -> Nat:
  match lo:
    case 31n:
      1n
    case 47n:
      2n
    case 55n:
      3n
    case 59n:
      4n
    case 61n:
      5n
    case 62n:
      6n
    case _:
      0n

def stat.code.lo2(+lo: Nat) -> Nat:
  match lo:
    case 31n:
      7n
    case 47n:
      8n
    case 55n:
      9n
    case 59n:
      10n
    case 61n:
      11n
    case 62n:
      12n
    case _:
      0n

def stat.code.lo3(+lo: Nat) -> Nat:
  match lo:
    case 15n:
      13n
    case 23n:
      14n
    case 27n:
      15n
    case 29n:
      16n
    case 30n:
      17n
    case 39n:
      18n
    case 43n:
      19n
    case 45n:
      20n
    case 46n:
      21n
    case 51n:
      22n
    case 53n:
      23n
    case 54n:
      24n
    case 57n:
      25n
    case 58n:
      26n
    case 60n:
      27n
    case _:
      0n

def stat.code.lo4(+lo: Nat) -> Nat:
  match lo:
    case 31n:
      28n
    case 47n:
      29n
    case 55n:
      30n
    case 59n:
      31n
    case 61n:
      32n
    case 62n:
      33n
    case _:
      0n

def stat.code.lo5(+lo: Nat) -> Nat:
  match lo:
    case 15n:
      34n
    case 23n:
      35n
    case 27n:
      36n
    case 29n:
      37n
    case 30n:
      38n
    case 39n:
      39n
    case 43n:
      40n
    case 45n:
      41n
    case 46n:
      42n
    case 51n:
      43n
    case 53n:
      44n
    case 54n:
      45n
    case 57n:
      46n
    case 58n:
      47n
    case 60n:
      48n
    case _:
      0n

def stat.code.lo6(+lo: Nat) -> Nat:
  match lo:
    case 15n:
      49n
    case 23n:
      50n
    case 27n:
      51n
    case 29n:
      52n
    case 30n:
      53n
    case 39n:
      54n
    case 43n:
      55n
    case 45n:
      56n
    case 46n:
      57n
    case 51n:
      58n
    case 53n:
      59n
    case 54n:
      60n
    case 57n:
      61n
    case 58n:
      62n
    case 60n:
      63n
    case _:
      0n

def stat.code.lo7(+lo: Nat) -> Nat:
  match lo:
    case 7n:
      64n
    case 11n:
      65n
    case 13n:
      66n
    case 14n:
      67n
    case 19n:
      68n
    case 21n:
      69n
    case 22n:
      70n
    case 25n:
      71n
    case 26n:
      72n
    case 28n:
      73n
    case 35n:
      74n
    case 37n:
      75n
    case 38n:
      76n
    case 41n:
      77n
    case 42n:
      78n
    case 44n:
      79n
    case 49n:
      80n
    case 50n:
      81n
    case 52n:
      82n
    case 56n:
      83n
    case _:
      0n

def stat.code.lo8(+lo: Nat) -> Nat:
  match lo:
    case 31n:
      84n
    case 47n:
      85n
    case 55n:
      86n
    case 59n:
      87n
    case 61n:
      88n
    case 62n:
      89n
    case _:
      0n

def stat.code.lo9(+lo: Nat) -> Nat:
  match lo:
    case 15n:
      90n
    case 23n:
      91n
    case 27n:
      92n
    case 29n:
      93n
    case 30n:
      94n
    case 39n:
      95n
    case 43n:
      96n
    case 45n:
      97n
    case 46n:
      98n
    case 51n:
      99n
    case 53n:
      100n
    case 54n:
      101n
    case 57n:
      102n
    case 58n:
      103n
    case 60n:
      104n
    case _:
      0n

def stat.code.lo10(+lo: Nat) -> Nat:
  match lo:
    case 15n:
      105n
    case 23n:
      106n
    case 27n:
      107n
    case 29n:
      108n
    case 30n:
      109n
    case 39n:
      110n
    case 43n:
      111n
    case 45n:
      112n
    case 46n:
      113n
    case 51n:
      114n
    case 53n:
      115n
    case 54n:
      116n
    case 57n:
      117n
    case 58n:
      118n
    case 60n:
      119n
    case _:
      0n

def stat.code.lo11(+lo: Nat) -> Nat:
  match lo:
    case 7n:
      120n
    case 11n:
      121n
    case 13n:
      122n
    case 14n:
      123n
    case 19n:
      124n
    case 21n:
      125n
    case 22n:
      126n
    case 25n:
      127n
    case 26n:
      128n
    case 28n:
      129n
    case 35n:
      130n
    case 37n:
      131n
    case 38n:
      132n
    case 41n:
      133n
    case 42n:
      134n
    case 44n:
      135n
    case 49n:
      136n
    case 50n:
      137n
    case 52n:
      138n
    case 56n:
      139n
    case _:
      0n

def stat.code.lo12(+lo: Nat) -> Nat:
  match lo:
    case 15n:
      140n
    case 23n:
      141n
    case 27n:
      142n
    case 29n:
      143n
    case 30n:
      144n
    case 39n:
      145n
    case 43n:
      146n
    case 45n:
      147n
    case 46n:
      148n
    case 51n:
      149n
    case 53n:
      150n
    case 54n:
      151n
    case 57n:
      152n
    case 58n:
      153n
    case 60n:
      154n
    case _:
      0n

def stat.code.lo13(+lo: Nat) -> Nat:
  match lo:
    case 7n:
      155n
    case 11n:
      156n
    case 13n:
      157n
    case 14n:
      158n
    case 19n:
      159n
    case 21n:
      160n
    case 22n:
      161n
    case 25n:
      162n
    case 26n:
      163n
    case 28n:
      164n
    case 35n:
      165n
    case 37n:
      166n
    case 38n:
      167n
    case 41n:
      168n
    case 42n:
      169n
    case 44n:
      170n
    case 49n:
      171n
    case 50n:
      172n
    case 52n:
      173n
    case 56n:
      174n
    case _:
      0n

def stat.code.lo14(+lo: Nat) -> Nat:
  match lo:
    case 7n:
      175n
    case 11n:
      176n
    case 13n:
      177n
    case 14n:
      178n
    case 19n:
      179n
    case 21n:
      180n
    case 22n:
      181n
    case 25n:
      182n
    case 26n:
      183n
    case 28n:
      184n
    case 35n:
      185n
    case 37n:
      186n
    case 38n:
      187n
    case 41n:
      188n
    case 42n:
      189n
    case 44n:
      190n
    case 49n:
      191n
    case 50n:
      192n
    case 52n:
      193n
    case 56n:
      194n
    case _:
      0n

def stat.code.lo15(+lo: Nat) -> Nat:
  match lo:
    case 3n:
      195n
    case 5n:
      196n
    case 6n:
      197n
    case 9n:
      198n
    case 10n:
      199n
    case 12n:
      200n
    case 17n:
      201n
    case 18n:
      202n
    case 20n:
      203n
    case 24n:
      204n
    case 33n:
      205n
    case 34n:
      206n
    case 36n:
      207n
    case 40n:
      208n
    case 48n:
      209n
    case _:
      0n

def stat.code.lo16(+lo: Nat) -> Nat:
  match lo:
    case 31n:
      210n
    case 47n:
      211n
    case 55n:
      212n
    case 59n:
      213n
    case 61n:
      214n
    case 62n:
      215n
    case _:
      0n

def stat.code.lo17(+lo: Nat) -> Nat:
  match lo:
    case 15n:
      216n
    case 23n:
      217n
    case 27n:
      218n
    case 29n:
      219n
    case 30n:
      220n
    case 39n:
      221n
    case 43n:
      222n
    case 45n:
      223n
    case 46n:
      224n
    case 51n:
      225n
    case 53n:
      226n
    case 54n:
      227n
    case 57n:
      228n
    case 58n:
      229n
    case 60n:
      230n
    case _:
      0n

def stat.code.lo18(+lo: Nat) -> Nat:
  match lo:
    case 15n:
      231n
    case 23n:
      232n
    case 27n:
      233n
    case 29n:
      234n
    case 30n:
      235n
    case 39n:
      236n
    case 43n:
      237n
    case 45n:
      238n
    case 46n:
      239n
    case 51n:
      240n
    case 53n:
      241n
    case 54n:
      242n
    case 57n:
      243n
    case 58n:
      244n
    case 60n:
      245n
    case _:
      0n

def stat.code.lo19(+lo: Nat) -> Nat:
  match lo:
    case 7n:
      246n
    case 11n:
      247n
    case 13n:
      248n
    case 14n:
      249n
    case 19n:
      250n
    case 21n:
      251n
    case 22n:
      252n
    case 25n:
      253n
    case 26n:
      254n
    case 28n:
      255n
    case 35n:
      256n
    case 37n:
      257n
    case 38n:
      258n
    case 41n:
      259n
    case 42n:
      260n
    case 44n:
      261n
    case 49n:
      262n
    case 50n:
      263n
    case 52n:
      264n
    case 56n:
      265n
    case _:
      0n

def stat.code.lo20(+lo: Nat) -> Nat:
  match lo:
    case 15n:
      266n
    case 23n:
      267n
    case 27n:
      268n
    case 29n:
      269n
    case 30n:
      270n
    case 39n:
      271n
    case 43n:
      272n
    case 45n:
      273n
    case 46n:
      274n
    case 51n:
      275n
    case 53n:
      276n
    case 54n:
      277n
    case 57n:
      278n
    case 58n:
      279n
    case 60n:
      280n
    case _:
      0n

def stat.code.lo21(+lo: Nat) -> Nat:
  match lo:
    case 7n:
      281n
    case 11n:
      282n
    case 13n:
      283n
    case 14n:
      284n
    case 19n:
      285n
    case 21n:
      286n
    case 22n:
      287n
    case 25n:
      288n
    case 26n:
      289n
    case 28n:
      290n
    case 35n:
      291n
    case 37n:
      292n
    case 38n:
      293n
    case 41n:
      294n
    case 42n:
      295n
    case 44n:
      296n
    case 49n:
      297n
    case 50n:
      298n
    case 52n:
      299n
    case 56n:
      300n
    case _:
      0n

def stat.code.lo22(+lo: Nat) -> Nat:
  match lo:
    case 7n:
      301n
    case 11n:
      302n
    case 13n:
      303n
    case 14n:
      304n
    case 19n:
      305n
    case 21n:
      306n
    case 22n:
      307n
    case 25n:
      308n
    case 26n:
      309n
    case 28n:
      310n
    case 35n:
      311n
    case 37n:
      312n
    case 38n:
      313n
    case 41n:
      314n
    case 42n:
      315n
    case 44n:
      316n
    case 49n:
      317n
    case 50n:
      318n
    case 52n:
      319n
    case 56n:
      320n
    case _:
      0n

def stat.code.lo23(+lo: Nat) -> Nat:
  match lo:
    case 3n:
      321n
    case 5n:
      322n
    case 6n:
      323n
    case 9n:
      324n
    case 10n:
      325n
    case 12n:
      326n
    case 17n:
      327n
    case 18n:
      328n
    case 20n:
      329n
    case 24n:
      330n
    case 33n:
      331n
    case 34n:
      332n
    case 36n:
      333n
    case 40n:
      334n
    case 48n:
      335n
    case _:
      0n

def stat.code.lo24(+lo: Nat) -> Nat:
  match lo:
    case 15n:
      336n
    case 23n:
      337n
    case 27n:
      338n
    case 29n:
      339n
    case 30n:
      340n
    case 39n:
      341n
    case 43n:
      342n
    case 45n:
      343n
    case 46n:
      344n
    case 51n:
      345n
    case 53n:
      346n
    case 54n:
      347n
    case 57n:
      348n
    case 58n:
      349n
    case 60n:
      350n
    case _:
      0n

def stat.code.lo25(+lo: Nat) -> Nat:
  match lo:
    case 7n:
      351n
    case 11n:
      352n
    case 13n:
      353n
    case 14n:
      354n
    case 19n:
      355n
    case 21n:
      356n
    case 22n:
      357n
    case 25n:
      358n
    case 26n:
      359n
    case 28n:
      360n
    case 35n:
      361n
    case 37n:
      362n
    case 38n:
      363n
    case 41n:
      364n
    case 42n:
      365n
    case 44n:
      366n
    case 49n:
      367n
    case 50n:
      368n
    case 52n:
      369n
    case 56n:
      370n
    case _:
      0n

def stat.code.lo26(+lo: Nat) -> Nat:
  match lo:
    case 7n:
      371n
    case 11n:
      372n
    case 13n:
      373n
    case 14n:
      374n
    case 19n:
      375n
    case 21n:
      376n
    case 22n:
      377n
    case 25n:
      378n
    case 26n:
      379n
    case 28n:
      380n
    case 35n:
      381n
    case 37n:
      382n
    case 38n:
      383n
    case 41n:
      384n
    case 42n:
      385n
    case 44n:
      386n
    case 49n:
      387n
    case 50n:
      388n
    case 52n:
      389n
    case 56n:
      390n
    case _:
      0n

def stat.code.lo27(+lo: Nat) -> Nat:
  match lo:
    case 3n:
      391n
    case 5n:
      392n
    case 6n:
      393n
    case 9n:
      394n
    case 10n:
      395n
    case 12n:
      396n
    case 17n:
      397n
    case 18n:
      398n
    case 20n:
      399n
    case 24n:
      400n
    case 33n:
      401n
    case 34n:
      402n
    case 36n:
      403n
    case 40n:
      404n
    case 48n:
      405n
    case _:
      0n

def stat.code.lo28(+lo: Nat) -> Nat:
  match lo:
    case 7n:
      406n
    case 11n:
      407n
    case 13n:
      408n
    case 14n:
      409n
    case 19n:
      410n
    case 21n:
      411n
    case 22n:
      412n
    case 25n:
      413n
    case 26n:
      414n
    case 28n:
      415n
    case 35n:
      416n
    case 37n:
      417n
    case 38n:
      418n
    case 41n:
      419n
    case 42n:
      420n
    case 44n:
      421n
    case 49n:
      422n
    case 50n:
      423n
    case 52n:
      424n
    case 56n:
      425n
    case _:
      0n

def stat.code.lo29(+lo: Nat) -> Nat:
  match lo:
    case 3n:
      426n
    case 5n:
      427n
    case 6n:
      428n
    case 9n:
      429n
    case 10n:
      430n
    case 12n:
      431n
    case 17n:
      432n
    case 18n:
      433n
    case 20n:
      434n
    case 24n:
      435n
    case 33n:
      436n
    case 34n:
      437n
    case 36n:
      438n
    case 40n:
      439n
    case 48n:
      440n
    case _:
      0n

def stat.code.lo30(+lo: Nat) -> Nat:
  match lo:
    case 3n:
      441n
    case 5n:
      442n
    case 6n:
      443n
    case 9n:
      444n
    case 10n:
      445n
    case 12n:
      446n
    case 17n:
      447n
    case 18n:
      448n
    case 20n:
      449n
    case 24n:
      450n
    case 33n:
      451n
    case 34n:
      452n
    case 36n:
      453n
    case 40n:
      454n
    case 48n:
      455n
    case _:
      0n

def stat.code.lo31(+lo: Nat) -> Nat:
  match lo:
    case 1n:
      456n
    case 2n:
      457n
    case 4n:
      458n
    case 8n:
      459n
    case 16n:
      460n
    case 32n:
      461n
    case _:
      0n

def stat.code.lo32(+lo: Nat) -> Nat:
  match lo:
    case 31n:
      462n
    case 47n:
      463n
    case 55n:
      464n
    case 59n:
      465n
    case 61n:
      466n
    case 62n:
      467n
    case _:
      0n

def stat.code.lo33(+lo: Nat) -> Nat:
  match lo:
    case 15n:
      468n
    case 23n:
      469n
    case 27n:
      470n
    case 29n:
      471n
    case 30n:
      472n
    case 39n:
      473n
    case 43n:
      474n
    case 45n:
      475n
    case 46n:
      476n
    case 51n:
      477n
    case 53n:
      478n
    case 54n:
      479n
    case 57n:
      480n
    case 58n:
      481n
    case 60n:
      482n
    case _:
      0n

def stat.code.lo34(+lo: Nat) -> Nat:
  match lo:
    case 15n:
      483n
    case 23n:
      484n
    case 27n:
      485n
    case 29n:
      486n
    case 30n:
      487n
    case 39n:
      488n
    case 43n:
      489n
    case 45n:
      490n
    case 46n:
      491n
    case 51n:
      492n
    case 53n:
      493n
    case 54n:
      494n
    case 57n:
      495n
    case 58n:
      496n
    case 60n:
      497n
    case _:
      0n

def stat.code.lo35(+lo: Nat) -> Nat:
  match lo:
    case 7n:
      498n
    case 11n:
      499n
    case 13n:
      500n
    case 14n:
      501n
    case 19n:
      502n
    case 21n:
      503n
    case 22n:
      504n
    case 25n:
      505n
    case 26n:
      506n
    case 28n:
      507n
    case 35n:
      508n
    case 37n:
      509n
    case 38n:
      510n
    case 41n:
      511n
    case 42n:
      512n
    case 44n:
      513n
    case 49n:
      514n
    case 50n:
      515n
    case 52n:
      516n
    case 56n:
      517n
    case _:
      0n

def stat.code.lo36(+lo: Nat) -> Nat:
  match lo:
    case 15n:
      518n
    case 23n:
      519n
    case 27n:
      520n
    case 29n:
      521n
    case 30n:
      522n
    case 39n:
      523n
    case 43n:
      524n
    case 45n:
      525n
    case 46n:
      526n
    case 51n:
      527n
    case 53n:
      528n
    case 54n:
      529n
    case 57n:
      530n
    case 58n:
      531n
    case 60n:
      532n
    case _:
      0n

def stat.code.lo37(+lo: Nat) -> Nat:
  match lo:
    case 7n:
      533n
    case 11n:
      534n
    case 13n:
      535n
    case 14n:
      536n
    case 19n:
      537n
    case 21n:
      538n
    case 22n:
      539n
    case 25n:
      540n
    case 26n:
      541n
    case 28n:
      542n
    case 35n:
      543n
    case 37n:
      544n
    case 38n:
      545n
    case 41n:
      546n
    case 42n:
      547n
    case 44n:
      548n
    case 49n:
      549n
    case 50n:
      550n
    case 52n:
      551n
    case 56n:
      552n
    case _:
      0n

def stat.code.lo38(+lo: Nat) -> Nat:
  match lo:
    case 7n:
      553n
    case 11n:
      554n
    case 13n:
      555n
    case 14n:
      556n
    case 19n:
      557n
    case 21n:
      558n
    case 22n:
      559n
    case 25n:
      560n
    case 26n:
      561n
    case 28n:
      562n
    case 35n:
      563n
    case 37n:
      564n
    case 38n:
      565n
    case 41n:
      566n
    case 42n:
      567n
    case 44n:
      568n
    case 49n:
      569n
    case 50n:
      570n
    case 52n:
      571n
    case 56n:
      572n
    case _:
      0n

def stat.code.lo39(+lo: Nat) -> Nat:
  match lo:
    case 3n:
      573n
    case 5n:
      574n
    case 6n:
      575n
    case 9n:
      576n
    case 10n:
      577n
    case 12n:
      578n
    case 17n:
      579n
    case 18n:
      580n
    case 20n:
      581n
    case 24n:
      582n
    case 33n:
      583n
    case 34n:
      584n
    case 36n:
      585n
    case 40n:
      586n
    case 48n:
      587n
    case _:
      0n

def stat.code.lo40(+lo: Nat) -> Nat:
  match lo:
    case 15n:
      588n
    case 23n:
      589n
    case 27n:
      590n
    case 29n:
      591n
    case 30n:
      592n
    case 39n:
      593n
    case 43n:
      594n
    case 45n:
      595n
    case 46n:
      596n
    case 51n:
      597n
    case 53n:
      598n
    case 54n:
      599n
    case 57n:
      600n
    case 58n:
      601n
    case 60n:
      602n
    case _:
      0n

def stat.code.lo41(+lo: Nat) -> Nat:
  match lo:
    case 7n:
      603n
    case 11n:
      604n
    case 13n:
      605n
    case 14n:
      606n
    case 19n:
      607n
    case 21n:
      608n
    case 22n:
      609n
    case 25n:
      610n
    case 26n:
      611n
    case 28n:
      612n
    case 35n:
      613n
    case 37n:
      614n
    case 38n:
      615n
    case 41n:
      616n
    case 42n:
      617n
    case 44n:
      618n
    case 49n:
      619n
    case 50n:
      620n
    case 52n:
      621n
    case 56n:
      622n
    case _:
      0n

def stat.code.lo42(+lo: Nat) -> Nat:
  match lo:
    case 7n:
      623n
    case 11n:
      624n
    case 13n:
      625n
    case 14n:
      626n
    case 19n:
      627n
    case 21n:
      628n
    case 22n:
      629n
    case 25n:
      630n
    case 26n:
      631n
    case 28n:
      632n
    case 35n:
      633n
    case 37n:
      634n
    case 38n:
      635n
    case 41n:
      636n
    case 42n:
      637n
    case 44n:
      638n
    case 49n:
      639n
    case 50n:
      640n
    case 52n:
      641n
    case 56n:
      642n
    case _:
      0n

def stat.code.lo43(+lo: Nat) -> Nat:
  match lo:
    case 3n:
      643n
    case 5n:
      644n
    case 6n:
      645n
    case 9n:
      646n
    case 10n:
      647n
    case 12n:
      648n
    case 17n:
      649n
    case 18n:
      650n
    case 20n:
      651n
    case 24n:
      652n
    case 33n:
      653n
    case 34n:
      654n
    case 36n:
      655n
    case 40n:
      656n
    case 48n:
      657n
    case _:
      0n

def stat.code.lo44(+lo: Nat) -> Nat:
  match lo:
    case 7n:
      658n
    case 11n:
      659n
    case 13n:
      660n
    case 14n:
      661n
    case 19n:
      662n
    case 21n:
      663n
    case 22n:
      664n
    case 25n:
      665n
    case 26n:
      666n
    case 28n:
      667n
    case 35n:
      668n
    case 37n:
      669n
    case 38n:
      670n
    case 41n:
      671n
    case 42n:
      672n
    case 44n:
      673n
    case 49n:
      674n
    case 50n:
      675n
    case 52n:
      676n
    case 56n:
      677n
    case _:
      0n

def stat.code.lo45(+lo: Nat) -> Nat:
  match lo:
    case 3n:
      678n
    case 5n:
      679n
    case 6n:
      680n
    case 9n:
      681n
    case 10n:
      682n
    case 12n:
      683n
    case 17n:
      684n
    case 18n:
      685n
    case 20n:
      686n
    case 24n:
      687n
    case 33n:
      688n
    case 34n:
      689n
    case 36n:
      690n
    case 40n:
      691n
    case 48n:
      692n
    case _:
      0n

def stat.code.lo46(+lo: Nat) -> Nat:
  match lo:
    case 3n:
      693n
    case 5n:
      694n
    case 6n:
      695n
    case 9n:
      696n
    case 10n:
      697n
    case 12n:
      698n
    case 17n:
      699n
    case 18n:
      700n
    case 20n:
      701n
    case 24n:
      702n
    case 33n:
      703n
    case 34n:
      704n
    case 36n:
      705n
    case 40n:
      706n
    case 48n:
      707n
    case _:
      0n

def stat.code.lo47(+lo: Nat) -> Nat:
  match lo:
    case 1n:
      708n
    case 2n:
      709n
    case 4n:
      710n
    case 8n:
      711n
    case 16n:
      712n
    case 32n:
      713n
    case _:
      0n

def stat.code.lo48(+lo: Nat) -> Nat:
  match lo:
    case 15n:
      714n
    case 23n:
      715n
    case 27n:
      716n
    case 29n:
      717n
    case 30n:
      718n
    case 39n:
      719n
    case 43n:
      720n
    case 45n:
      721n
    case 46n:
      722n
    case 51n:
      723n
    case 53n:
      724n
    case 54n:
      725n
    case 57n:
      726n
    case 58n:
      727n
    case 60n:
      728n
    case _:
      0n

def stat.code.lo49(+lo: Nat) -> Nat:
  match lo:
    case 7n:
      729n
    case 11n:
      730n
    case 13n:
      731n
    case 14n:
      732n
    case 19n:
      733n
    case 21n:
      734n
    case 22n:
      735n
    case _:
      0n

def stat.code.hl(+hi: Nat, +lo: Nat) -> Nat:
  match hi:
    case 0n:
      stat.code.lo0(lo)
    case 1n:
      stat.code.lo1(lo)
    case 2n:
      stat.code.lo2(lo)
    case 3n:
      stat.code.lo3(lo)
    case 4n:
      stat.code.lo4(lo)
    case 5n:
      stat.code.lo5(lo)
    case 6n:
      stat.code.lo6(lo)
    case 7n:
      stat.code.lo7(lo)
    case 8n:
      stat.code.lo8(lo)
    case 9n:
      stat.code.lo9(lo)
    case 10n:
      stat.code.lo10(lo)
    case 11n:
      stat.code.lo11(lo)
    case 12n:
      stat.code.lo12(lo)
    case 13n:
      stat.code.lo13(lo)
    case 14n:
      stat.code.lo14(lo)
    case 15n:
      stat.code.lo15(lo)
    case 16n:
      stat.code.lo16(lo)
    case 17n:
      stat.code.lo17(lo)
    case 18n:
      stat.code.lo18(lo)
    case 19n:
      stat.code.lo19(lo)
    case 20n:
      stat.code.lo20(lo)
    case 21n:
      stat.code.lo21(lo)
    case 22n:
      stat.code.lo22(lo)
    case 23n:
      stat.code.lo23(lo)
    case 24n:
      stat.code.lo24(lo)
    case 25n:
      stat.code.lo25(lo)
    case 26n:
      stat.code.lo26(lo)
    case 27n:
      stat.code.lo27(lo)
    case 28n:
      stat.code.lo28(lo)
    case 29n:
      stat.code.lo29(lo)
    case 30n:
      stat.code.lo30(lo)
    case 31n:
      stat.code.lo31(lo)
    case 32n:
      stat.code.lo32(lo)
    case 33n:
      stat.code.lo33(lo)
    case 34n:
      stat.code.lo34(lo)
    case 35n:
      stat.code.lo35(lo)
    case 36n:
      stat.code.lo36(lo)
    case 37n:
      stat.code.lo37(lo)
    case 38n:
      stat.code.lo38(lo)
    case 39n:
      stat.code.lo39(lo)
    case 40n:
      stat.code.lo40(lo)
    case 41n:
      stat.code.lo41(lo)
    case 42n:
      stat.code.lo42(lo)
    case 43n:
      stat.code.lo43(lo)
    case 44n:
      stat.code.lo44(lo)
    case 45n:
      stat.code.lo45(lo)
    case 46n:
      stat.code.lo46(lo)
    case 47n:
      stat.code.lo47(lo)
    case 48n:
      stat.code.lo48(lo)
    case 49n:
      stat.code.lo49(lo)
    case _:
      0n

# a word's code (0 for one no code has)
def stat.code.cw(+w: Nat) -> Nat:
  stat.code.hl(Nat.div(w, 64n), Nat.mod(w, 64n))

# the high twelve bits of the hash of a call of GET, SET and INCR that
# runs, as the parser writes them
def stat.mark.get() -> U32:
  199229440

def stat.mark.set() -> U32:
  231735296

def stat.mark.incr() -> U32:
  380633088
# END gen_commands: stats

# a container (CLIENT, FUNCTION, CONFIG, COMMAND, OBJECT, MEMORY) by its
# first argument; alone, the container itself (top)
def stat.sub.of(id: Nat, +up: String) -> Nat:
  match id:
    case 118n:
      stat.sub.memory(memory_id(up, String.length(up)))
    case 105n:
      stat.sub.client(client_id(up, String.length(up)))
    case 106n:
      stat.sub.function(function_id(up, String.length(up)))
    case 107n:
      stat.sub.config(config_id(up, String.length(up)))
    case 114n:
      stat.sub.object(object_id(up, String.length(up)))
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
    case 105n:
      stat.key.args(stat.top(105n), 105n, args)
    case 106n:
      stat.key.args(stat.top(106n), 106n, args)
    case 107n:
      stat.key.args(stat.top(107n), 107n, args)
    case 109n:
      stat.key.args(stat.top(109n), 109n, args)
    case 114n:
      stat.key.args(stat.top(114n), 114n, args)
    case 118n:
      stat.key.args(stat.top(118n), 118n, args)
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
# '[...]' a class (with '^', ranges and '\'), '\' the byte after it. A run
# of stars is one star, a star that ends the pattern matches at once, and
# a '*' tries the rest at each later byte only until a try matches. A '*'
# whose rest matches nowhere in the rest of the string ends the search
# (Redis's skipLongerMatches): a longer run for an earlier '*' could only
# start the rest later, so each star's loop runs once at most, and a
# pattern costs at most a pass over the string for each of its bytes,
# not time exponential in its stars. The rest after a '*' is a call of
# its own in Redis, and a call nested in more than 1000 others matches
# nothing (Redis's fix for CVE-2024-31228, in 6.2.16, 7.2.6 and 7.4.1, and
# in the 7.0.15 of Ubuntu the tests run against). A '*' does not match an
# empty string, as in Redis, where the empty string never enters the
# loop.

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
# and then at each later byte; what that try gave; and the start of the
# try, Redis's nested call, which goes on only when it is nested in 1000
# calls at most
type SmMode is Data:
  SmStep{}
  SmNext{}
  SmLit{ok: Bool}
  SmCls{ok: Bool, rest: String}
  SmStars{}
  SmStar{}
  SmTry{r: Sm}
  SmIn{ok: Bool}

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
# call goes one level down: four for each byte of the pattern and three
# for each of the string's are enough), and d is how many of Redis's calls
# the step is nested in
def sm.go(f: Nat, mode: SmMode, +p: String, +s: String, +nc: Bool, +d: Nat) -> Sm:
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
              sm.go(g, SmStep{}, p, SCon{c, t}, nc, d)
        case SmLit{ok}:
          match ok s:
            case True{} SCon{c, t}:
              sm.go(g, SmNext{}, p, t, nc, d)
            case _ _:
              SmNo{}
        case SmCls{ok, rest}:
          match ok s:
            case True{} SCon{c, t}:
              sm.go(g, SmNext{}, rest, t, nc, d)
            case _ _:
              SmNo{}
        case SmStars{}:
          match p:
            case SNil{}:
              SmYes{}
            case SCon{a, q}:
              sm.go(g, SmStar{}, SCon{a, q}, s, nc, d)
        case SmStar{}:
          match s:
            case SNil{}:
              SmStop{}
            case SCon{+c, +t}:
              sm.go(g, SmTry{sm.go(g, SmIn{Nat.is_lt(d, 1000n)}, p, SCon{c, t}, nc, 1n+d)}, p, SCon{c, t}, nc, d)
        case SmTry{r}:
          match r s:
            case SmYes{} _:
              SmYes{}
            case SmStop{} _:
              SmStop{}
            case SmNo{} SNil{}:
              SmStop{}
            case SmNo{} SCon{c, t}:
              sm.go(g, SmStar{}, p, t, nc, d)
        case SmIn{ok}:
          match ok:
            case True{}:
              sm.go(g, SmStep{}, p, s, nc, d)
            case False{}:
              SmNo{}
        case SmStep{}:
          match p s:
            case SNil{} _:
              SmNo{}
            case _ SNil{}:
              SmNo{}
            case SCon{'*', pt} SCon{c, t}:
              sm.go(g, SmStars{}, sm.unstar(pt), SCon{c, t}, nc, d)
            case SCon{'?', pt} SCon{c, t}:
              sm.go(g, SmNext{}, pt, t, nc, d)
            case SCon{'[', pt} SCon{Chr{+x}, t}:
              sm.go(g, sm.class(pt, nc, x), pt, SCon{Chr{x}, t}, nc, d)
            case SCon{'\\', SCon{Chr{+y}, pt}} SCon{Chr{+x}, t}:
              sm.go(g, SmLit{sm.eq(nc, y, x)}, pt, SCon{Chr{x}, t}, nc, d)
            case SCon{Chr{+y}, pt} SCon{Chr{+x}, t}:
              sm.go(g, SmLit{sm.eq(nc, y, x)}, pt, SCon{Chr{x}, t}, nc, d)

# whether pattern p matches string s, case aside when nc
def stringmatch(+p: String, +s: String, nc: Bool) -> Bool:
  match s:
    case SNil{}:
      String.is_empty(p)
    case SCon{c, t}:
      sm.yes(sm.go(Nat.mul(4n, Nat.add(4n, Nat.add(String.length(p), String.length(s)))), SmStep{}, p, SCon{c, t}, nc, 0n))

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
# the keys a scan found, by the type (the name TYPE gives a key's kind,
# in any case: "none" for a key gone since), then by the pattern ("*"
# when there is none)
def scan.match(ks: List<&2, String>, pat: Maybe<&2, String>) -> List<&2, Reply>:
  match pat:
    case Some{+p}:
      glob_filter(p, ks)
    case None{}:
      glob_filter("*", ks)

def scan.tname(m: Maybe<&2, KV.Val>) -> String:
  match m:
    case Some{+v}:
      val.type(v)
    case None{}:
      "none"

def scan.typed.put(ok: Bool, k: String, ks: List<&2, String>) -> List<&2, String>:
  match ok:
    case True{}:
      k <> ks
    case False{}:
      ks

def scan.typed(ks: List<&2, String>, +t: String, +d: KV.Trie<KV.Val>, +now: Nat) -> List<&2, String>:
  match ks:
    case Nil{}:
      Nil{}
    case Con{+k, rest}:
      scan.typed.put(String.eq(t, scan.tname(KV.read(KV.Val, d, k, now))), k, scan.typed(rest, t, d, now))

def scan.keep(ks: List<&2, String>, pat: Maybe<&2, String>, typ: Maybe<&2, String>, +d: KV.Trie<KV.Val>, +now: Nat) -> List<&2, Reply>:
  match typ:
    case Some{+t}:
      scan.match(scan.typed(ks, String.to_lower(cstr(t)), d, now), pat)
    case None{}:
      scan.match(ks, pat)

def scan.rep(+next: Nat, ks: List<&2, String>, pat: Maybe<&2, String>, typ: Maybe<&2, String>, +d: KV.Trie<KV.Val>, +now: Nat) -> Reply:
  RArray{[RBulk{Nat.show(next)}, RArray{scan.keep(ks, pat, typ, d, now)}]}

def scan.out(sc: KV.Scan, pat: Maybe<&2, String>, typ: Maybe<&2, String>, +d: KV.Trie<KV.Val>, +now: Nat) -> Reply:
  match sc:
    case KV.Stop{+at, acc}:
      scan.rep(Bool.pick(Nat, Nat.is_lt(at, 1048576n), at, 0n), List.reverse(&2, String, acc), pat, typ, d, now)
    case KV.Scan{w, acc}:
      scan.rep(0n, List.reverse(&2, String, acc), pat, typ, d, now)

def scan.reply(a: ScanArgs, +d: KV.Trie<KV.Val>, +now: Nat) -> Reply:
  match a:
    case ScanArgs{+cur, +n, pat, typ}:
      scan.out(KV.scan(KV.Val, d, cur, n, now), pat, typ, d, now)
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
  Db{KV.empty(KV.Val), 0n, 0n, 0n, None{}}

# the database at the time now (ms since 1970): the server sets it before
# each group of batches, and while a file loads it is 0, when no key has
# expired (Redis expires nothing while it loads)
def db.at(+now: Nat, db: Db) -> Db:
  match db:
    case Db{t, n, x, old, rr}:
      Db{t, n, x, now, rr}

# the trie of a database, and how many keys it counts and how many of
# them have a time (for the laws, and for INFO's keyspace)
def db.t(d: Db) -> KV.Trie<KV.Val>:
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
def db.trie(+d: Db) -> KV.Trie<KV.Val>:
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

# SET of k to the string v, counted: the key's code is asked first, while
# the trie is lent (KV.code.at), so that a new key counts and a key that
# had a time loses it; a value of another kind is replaced, as SET
# replaces any
def db.set(db: Db, +k: String, v: String) -> Db:
  match db:
    case Db{t, +n, +x, now, rr}:
      +u = t
      +h = KV.hash(k)
      +c = KV.code.at(KV.Val, u, k, h)
      Db{KV.set.at(KV.Val, u, k, KV.VStr{v}, h), cnt.n(c, n), cnt.x(c, 0n, x), now, rr}

# GET's read of a database it lends: k's value when the key is there at
# now, a string copied (KV.get_copy)
def db.get_copy(+d: Db, +k: String) -> KV.Got:
  match d:
    case Db{+t, n, x, +now, rr}:
      KV.get_copy(t, k, now)

# DEL: the keys removed in order; how many of them were there at now (the
# reply), how many entries went and how many of those had a time (for the
# counts)
type Dels is Data:
  Dels{live: Nat, gone: Nat, gonex: Nat, t: KV.Trie<KV.Val>}

def del_keys.put(+c: Nat, +now: Nat, r: Dels) -> Dels:
  match r:
    case Dels{+live, +gone, +gonex, t}:
      Dels{Nat.add(live, Bool.pick(Nat, code.live(c, now), 1n, 0n)), Nat.add(gone, Bool.pick(Nat, Nat.is_eq(c, 0n), 0n, 1n)), Nat.add(gonex, Bool.pick(Nat, Nat.is_lt(1n, c), 1n, 0n)), t}

def del_keys(ks: List<&2, String>, +now: Nat, db: KV.Trie<KV.Val>) -> Dels:
  match ks:
    case Nil{}:
      Dels{0n, 0n, 0n, db}
    case Con{+k, rest}:
      +u = db
      +h = KV.hash(k)
      +c = KV.code.at(KV.Val, u, k, h)
      del_keys.put(c, now, del_keys(rest, now, KV.del.at(KV.Val, u, k, h)))

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
def exists_keys(ks: List<&2, String>, +now: Nat, +db: KV.Trie<KV.Val>) -> Nat:
  match ks:
    case Nil{}:
      0n
    case Con{+k, rest}:
      Nat.add(Bool.pick(Nat, Maybe.is_some(&2, KV.Val, KV.read(KV.Val, db, k, now)), 1n, 0n), exists_keys(rest, now, db))

def mget_keys(ks: List<&2, String>, +now: Nat, +db: KV.Trie<KV.Val>) -> List<&2, Reply>:
  match ks:
    case Nil{}:
      Nil{}
    case Con{+k, rest}:
      i_getv(KV.read(KV.Val, db, k, now)) <> mget_keys(rest, now, db)

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
def incr.put(keep: Bool, t: KV.Trie<KV.Val>, +k: String, v: String, +h: U32) -> KV.Trie<KV.Val>:
  match keep:
    case True{}:
      KV.keep.at(KV.Val, t, k, KV.VStr{v}, h)
    case False{}:
      KV.set.at(KV.Val, t, k, KV.VStr{v}, h)

def incr.fit(t: KV.Trie<KV.Val>, +k: String, +h: U32, +i: Int, ok: Bool, keep: Bool, m: Nat, n: Nat, y: Nat, x: Nat, now: Nat, rr: Maybe<&2, Db>) -> Reply & Db:
  match ok:
    case True{}:
      (RInt{i}, Db{incr.put(keep, t, k, int_show(i), h), m, y, now, rr})
    case False{}:
      (RError{"ERR increment or decrement would overflow"}, Db{t, n, x, now, rr})

# the integer a key there holds, or none
def incr.num(t: KV.Trie<KV.Val>, +k: String, +h: U32, by: Int, +n: Nat, +x: Nat, now: Nat, rr: Maybe<&2, Db>, cur: Maybe<&2, Int>) -> Reply & Db:
  match cur:
    case Some{i}:
      +s = int_add(i, by)
      incr.fit(t, k, h, s, int_fits(s), True{}, n, n, x, x, now, rr)
    case None{}:
      (e_int(), Db{t, n, x, now, rr})

# a key that is not there reads as 0: the sum is by; c is its code
def incr.new(t: KV.Trie<KV.Val>, +k: String, +h: U32, +by: Int, +n: Nat, +x: Nat, now: Nat, rr: Maybe<&2, Db>, +c: Nat) -> Reply & Db:
  incr.fit(t, k, h, by, int_fits(by), False{}, cnt.n(c, n), n, cnt.x(c, 0n, x), x, now, rr)

# the value of INCRBY's key there at now (old), or none; a value of
# another kind is WRONGTYPE
def incr.got(t: KV.Trie<KV.Val>, +k: String, +h: U32, +by: Int, +n: Nat, +x: Nat, now: Nat, rr: Maybe<&2, Db>, old: KV.Got) -> Reply & Db:
  match old:
    case KV.GStr{s}:
      incr.num(t, k, h, by, n, x, now, rr, int_read(s))
    case KV.GColl{}:
      (e_wrongtype(), Db{t, n, x, now, rr})
    case KV.GNone{}:
      +u = t
      incr.new(u, k, h, by, n, x, now, rr, KV.code.at(KV.Val, u, k, h))

def db.incr(db: Db, +k: String, by: Int) -> Reply & Db:
  match db:
    case Db{t, n, x, +now, rr}:
      +u = t
      +h = KV.hash(k)
      incr.got(u, k, h, by, n, x, now, rr, KV.get_copy.at(u, k, h, now))

# A key's entry, when it is there at now; and the code of an entry
def ent.live(+now: Nat, m: Maybe<&2, KV.Item<KV.Val>>) -> Maybe<&2, KV.Item<KV.Val>>:
  match m:
    case Some{KV.Item{v, +e}}:
      Bool.pick(Maybe<&2, KV.Item<KV.Val>>, KV.live(now, e), Some{KV.Item{v, e}}, None{})
    case None{}:
      None{}

def ent.code(+m: Maybe<&2, KV.Item<KV.Val>>) -> Nat:
  match m:
    case Some{KV.Item{v, +e}}:
      1n+e
    case None{}:
      0n

# k's entry in a database it lends, there at now or not
def db.entry(+d: Db, +k: String) -> Maybe<&2, KV.Item<KV.Val>>:
  match d:
    case Db{+t, n, x, now, rr}:
      KV.entry.at(KV.Val, t, k, KV.hash(k))

# k's entry in a database it lends, when the key is there at now
def db.ent(+d: Db, +k: String) -> Maybe<&2, KV.Item<KV.Val>>:
  match d:
    case Db{+t, n, x, +now, rr}:
      ent.live(now, KV.entry.at(KV.Val, t, k, KV.hash(k)))

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

# Ranges
# ------
# GETRANGE, BITCOUNT and BITPOS take a range: from start to end, both
# counted from the end when below 0 (-1 the last), then cut to the value
# (its bytes, or its bits for BIT). A number of the range is a long long;
# one past 2^40, more than any value's length in bits, acts as 2^40
# would, so each is kept as a place: 2^41 plus the number, a Nat.

def rg.off() -> Nat:
  Nat.mul(2097152n, 1048576n)

def rg.big() -> Nat:
  Nat.mul(1048576n, 1048576n)

# a magnitude hi * 10^9 + lo, at most 2^40: a def, so that the product is
# made only when it may fit (small: hi below 1100)
def rg.mag(small: Bool, +hi: Nat, +lo: Nat) -> Nat:
  match small:
    case True{}:
      Nat.min(Nat.add(Nat.mul(hi, 1000000000n), lo), rg.big())
    case False{}:
      rg.big()

# a long long's place
def rg.place(l: LL) -> Nat:
  match l:
    case LL{+neg, +hi, +lo}:
      +m = rg.mag(Nat.is_lt(hi, 1100n), hi, lo)
      Bool.pick(Nat, neg, Nat.sub(rg.off(), m), Nat.add(rg.off(), m))
    case LLBad{}:
      rg.off()

# whether a start and an end are both below 0, the start after the end:
# GETRANGE and BITCOUNT then answer an empty range at once
def rg.flip(+a: LL, +b: LL) -> Bool:
  match a b:
    case LL{+na, +ha, +la} LL{+nb, +hb, +lb}:
      Bool.and(Bool.and(na, nb), Bool.not(ll.le(hb, lb, ha, la)))
    case _ _:
      False{}

# a place below 0 counted from the end of n units, then 0 at least
def rg.from(+p: Nat, +n: Nat) -> Nat:
  Nat.max(Bool.pick(Nat, Nat.is_lt(p, rg.off()), Nat.add(p, n), p), rg.off())

# a range cut to a value: its first and last index
type Span is Data:
  Span{i: Nat, j: Nat}

# the range from place s to place e, of n units, or none when it is empty
def rg.cut(+s: Nat, +e: Nat, +n: Nat) -> Maybe<&2, Span>:
  +a = rg.from(s, n)
  +b = Nat.min(rg.from(e, n), Nat.sub(Nat.add(rg.off(), n), 1n))
  Bool.pick(Maybe<&2, Span>, Nat.is_le(a, b), Some{Span{Nat.sub(a, rg.off()), Nat.sub(b, rg.off())}}, None{})

# BYTE or BIT, as a range's unit (none: BYTE); None for another word
def rg.unit(u: Maybe<&2, String>) -> Maybe<&2, Bool>:
  match u:
    case Some{+w}:
      Bool.pick(Maybe<&2, Bool>, is_word(w, "BIT"), Some{True{}}, Bool.pick(Maybe<&2, Bool>, is_word(w, "BYTE"), Some{False{}}, None{}))
    case None{}:
      Some{False{}}

def r_syntax() -> Reply:
  RError{"ERR syntax error"}

def r_neg1() -> Reply:
  RInt{INeg{0n}}

# the byte at index i of w, 0 past its end
def byte.at(+w: String, +i: Nat) -> U32:
  +x = String.code_at(w, i)
  Bool.pick(U32, U32.is_eq(x, 4294967295), 0, x)

# the bits set in a byte
def pop8(+x: U32) -> Nat:
  +a = U32.sub(x, U32.and(U32.shr(x), 85))
  +b = U32.add(U32.and(a, 51), U32.and(U32.shrn(a, 2n), 51))
  U32.to_nat(U32.and(U32.add(b, U32.shrn(b, 4n)), 15))

# the bits set in the bytes of s, after acc
def pop.go(+s: String, +acc: Nat) -> Nat:
  match s:
    case SNil{}:
      acc
    case SCon{Chr{+x}, t}:
      pop.go(t, Nat.add(acc, pop8(x)))

# the bits of a byte before its bit k, and after it (bit 0 is the high
# one, as Redis numbers the bits of a value)
def mask.before(+k: Nat) -> U32:
  U32.and(U32.not(U32.sub(U32.shln(1, Nat.sub(8n, k)), 1)), 255)

def mask.after(+k: Nat) -> U32:
  U32.sub(U32.shln(1, Nat.sub(7n, k)), 1)

# GETRANGE of a value w
def getrange.cut(+w: String, r: Maybe<&2, Span>) -> Reply:
  match r:
    case Some{Span{+i, +j}}:
      RBulk{String.slice(w, i, Nat.add(Nat.sub(j, i), 1n))}
    case None{}:
      RBulk{""}

def getrange.of(+w: String, +a: LL, +b: LL) -> Reply:
  Bool.pick(Reply, rg.flip(a, b), RBulk{""}, getrange.cut(w, rg.cut(rg.place(a), rg.place(b), String.length(w))))

def getrange.args(+w: String, args: List<&2, String>) -> Reply:
  match args:
    case Con{+a, Con{+b, Nil{}}}:
      getrange.of(w, ll.read(a), ll.read(b))
    case _:
      RBulk{""}

# GETBIT of a value w
def getbit.of(+w: String, +off: Nat) -> Reply:
  r_int(U32.to_nat(U32.and(U32.shrn(byte.at(w, Nat.div(off, 8n)), Nat.sub(7n, Nat.mod(off, 8n))), 1)))

# BITCOUNT of a value w: the bits set from index i to j, of its bytes, or
# of its bits (the bytes they are in, less the bits of the first before
# i and of the last after j)
def bitcount.in(+w: String, +bit: Bool, +i: Nat, +j: Nat) -> Reply:
  +bi = Bool.pick(Nat, bit, Nat.div(i, 8n), i)
  +bj = Bool.pick(Nat, bit, Nat.div(j, 8n), j)
  +all = pop.go(String.slice(w, bi, Nat.add(Nat.sub(bj, bi), 1n)), 0n)
  +lead = Bool.pick(U32, bit, mask.before(Nat.mod(i, 8n)), 0)
  +tail = Bool.pick(U32, bit, mask.after(Nat.mod(j, 8n)), 0)
  r_int(Nat.sub(Nat.sub(all, pop8(U32.and(byte.at(w, bi), lead))), pop8(U32.and(byte.at(w, bj), tail))))

def bitcount.cut(+w: String, +bit: Bool, r: Maybe<&2, Span>) -> Reply:
  match r:
    case Some{Span{+i, +j}}:
      bitcount.in(w, bit, i, j)
    case None{}:
      r_int(0n)

def bitcount.unit(+w: String, +s: Nat, +e: Nat, u: Maybe<&2, Bool>) -> Reply:
  match u:
    case Some{+bit}:
      +n = String.length(w)
      bitcount.cut(w, bit, rg.cut(s, e, Bool.pick(Nat, bit, Nat.mul(n, 8n), n)))
    case None{}:
      r_syntax()

# BITCOUNT key start end [unit]: the start and the end are read, then an
# empty range of two numbers below 0 counts 0, then the unit is read
def bitcount.rng(+w: String, a: LL, b: LL, u: Maybe<&2, String>) -> Reply:
  match a b:
    case LLBad{} _:
      e_int()
    case LL{na, ha, la} LLBad{}:
      e_int()
    case LL{+na, +ha, +la} LL{+nb, +hb, +lb}:
      Bool.pick(Reply, rg.flip(LL{na, ha, la}, LL{nb, hb, lb}), r_int(0n),
        bitcount.unit(w, rg.place(LL{na, ha, la}), rg.place(LL{nb, hb, lb}), rg.unit(u)))

def bitcount.args(+w: String, args: List<&2, String>) -> Reply:
  match args:
    case Nil{}:
      r_int(pop.go(w, 0n))
    case Con{+a, Con{+b, Nil{}}}:
      bitcount.rng(w, ll.read(a), ll.read(b), None{})
    case Con{+a, Con{+b, Con{u, Nil{}}}}:
      bitcount.rng(w, ll.read(a), ll.read(b), Some{u})
    case _:
      r_syntax()

# BITPOS: the first bit of value bit in the bytes of s, the slice of a
# value from byte q on: in byte bi the bits of fm, in byte bj those of lm,
# are out of the range; r is what the bytes before found
def bit.hi(+z: U32) -> Nat:
  Bool.pick(Nat, U32.is_le(128, z), 0n, Bool.pick(Nat, U32.is_le(64, z), 1n, Bool.pick(Nat, U32.is_le(32, z), 2n,
    Bool.pick(Nat, U32.is_le(16, z), 3n, Bool.pick(Nat, U32.is_le(8, z), 4n, Bool.pick(Nat, U32.is_le(4, z), 5n,
    Bool.pick(Nat, U32.is_le(2, z), 6n, 7n)))))))

# byte y at index q, when a bit of value bit is in it: where
def bit.in(+y: U32, +bit: Bool, +q: Nat) -> Maybe<&2, Nat>:
  +z = Bool.pick(U32, bit, y, U32.xor(y, 255))
  Bool.pick(Maybe<&2, Nat>, U32.is_ne(z, 0), Some{Nat.add(Nat.mul(q, 8n), bit.hi(z))}, None{})

def bit.scan(s: String, +bit: Bool, +q: Nat, +bi: Nat, +bj: Nat, +fm: U32, +lm: U32, r: Maybe<&2, Nat>) -> Maybe<&2, Nat>:
  match s r:
    case _ Some{p}:
      Some{p}
    case SNil{} None{}:
      None{}
    case SCon{Chr{+x}, t} None{}:
      +m = U32.or(Bool.pick(U32, Nat.is_eq(q, bi), fm, 0), Bool.pick(U32, Nat.is_eq(q, bj), lm, 0))
      bit.scan(t, bit, Nat.add(q, 1n), bi, bj, fm, lm, bit.in(Bool.pick(U32, bit, U32.and(x, U32.not(m)), U32.or(x, m)), bit, q))

# the first bit of value bit in w from bit i to bit j
def bit.first(+w: String, +bit: Bool, +i: Nat, +j: Nat) -> Maybe<&2, Nat>:
  +bi = Nat.div(i, 8n)
  +bj = Nat.div(j, 8n)
  bit.scan(String.slice(w, bi, Nat.add(Nat.sub(bj, bi), 1n)), bit, bi, bi, bj, mask.before(Nat.mod(i, 8n)), mask.after(Nat.mod(j, 8n)), None{})

# what BITPOS found: none is -1, but for a 0 sought in bytes with no end
# given (pad), where the value counts as followed by 0s: the bit after
# the range
def bitpos.found(m: Maybe<&2, Nat>, +pad: Bool, +j: Nat) -> Reply:
  match m:
    case Some{p}:
      r_int(p)
    case None{}:
      Bool.pick(Reply, pad, r_int(Nat.mul(Nat.add(j, 1n), 8n)), r_neg1())

def bitpos.cut(+w: String, +bit: Bool, +isbit: Bool, +given: Bool, r: Maybe<&2, Span>) -> Reply:
  match r:
    case Some{Span{+i, +j}}:
      bitpos.found(bit.first(w, bit, Bool.pick(Nat, isbit, i, Nat.mul(i, 8n)), Bool.pick(Nat, isbit, j, Nat.add(Nat.mul(j, 8n), 7n))),
        Bool.and(Bool.not(bit), Bool.and(Bool.not(isbit), Bool.not(given))), j)
    case None{}:
      r_neg1()

def bitpos.unit(+w: String, +bit: Bool, +s: Nat, +e: Nat, +given: Bool, u: Maybe<&2, Bool>) -> Reply:
  match u:
    case Some{+isbit}:
      +n = String.length(w)
      bitpos.cut(w, bit, isbit, given, rg.cut(s, e, Bool.pick(Nat, isbit, Nat.mul(n, 8n), n)))
    case None{}:
      r_syntax()

def bitpos.ll(e: Maybe<&2, String>) -> Maybe<&2, LL>:
  match e:
    case Some{+x}:
      Some{ll.read(x)}
    case None{}:
      None{}

# BITPOS's end, read last: none is the value's last byte
def bitpos.end(+w: String, +bit: Bool, +s: Nat, e: Maybe<&2, LL>, u: Maybe<&2, Bool>) -> Reply:
  match e:
    case Some{LL{+n, +h, +l}}:
      bitpos.unit(w, bit, s, rg.place(LL{n, h, l}), True{}, u)
    case Some{LLBad{}}:
      e_int()
    case None{}:
      bitpos.unit(w, bit, s, Nat.sub(Nat.add(rg.off(), String.length(w)), 1n), False{}, u)

# a unit given that is no unit is an error before the end is read
def bitpos.unit.word(given: Bool, u: Maybe<&2, Bool>, +w: String, +bit: Bool, +s: Nat, e: Maybe<&2, String>) -> Reply:
  match given u:
    case True{} None{}:
      r_syntax()
    case _ _:
      bitpos.end(w, bit, s, bitpos.ll(e), u)

# BITPOS's start, read first, then the unit (when it is given), then the
# end
def bitpos.start(+w: String, +bit: Bool, a: LL, e: Maybe<&2, String>, +u: Maybe<&2, String>) -> Reply:
  match a:
    case LL{+n, +h, +l}:
      +g = Maybe.is_some(&2, String, u)
      bitpos.unit.word(g, rg.unit(u), w, bit, rg.place(LL{n, h, l}), e)
    case LLBad{}:
      e_int()

def bitpos.args(+w: String, +bit: Bool, args: List<&2, String>) -> Reply:
  match args:
    case Nil{}:
      bitpos.unit(w, bit, rg.off(), Nat.sub(Nat.add(rg.off(), String.length(w)), 1n), False{}, Some{False{}})
    case Con{+a, Nil{}}:
      bitpos.start(w, bit, ll.read(a), None{}, None{})
    case Con{+a, Con{e, Nil{}}}:
      bitpos.start(w, bit, ll.read(a), Some{e}, None{})
    case Con{+a, Con{e, Con{u, Nil{}}}}:
      bitpos.start(w, bit, ll.read(a), Some{e}, Some{u})
    case _:
      r_syntax()

def bitpos.of(+w: String, args: List<&2, String>) -> Reply:
  match args:
    case Con{+b, rest}:
      bitpos.args(w, String.eq(b, "1"), rest)
    case Nil{}:
      r_neg1()

# BITPOS of a key that is not there: a value of 0s with no end
def bitpos.none(args: List<&2, String>) -> Reply:
  match args:
    case Con{+b, rest}:
      Bool.pick(Reply, String.eq(b, "1"), r_neg1(), r_int(0n))
    case Nil{}:
      r_neg1()

# the reads of a range and of bits, of a key there or not (GETRANGE's
# empty string, GETBIT's and BITCOUNT's 0, and BITPOS's in a value of 0s)
def range.peek(args: List<&2, String>, m: Maybe<&2, KV.Item<String>>) -> Reply:
  match m:
    case Some{KV.Item{+w, e}}:
      getrange.args(w, args)
    case None{}:
      RBulk{""}

def getbit.peek(+off: Nat, m: Maybe<&2, KV.Item<String>>) -> Reply:
  match m:
    case Some{KV.Item{+w, e}}:
      getbit.of(w, off)
    case None{}:
      r_int(0n)

def bitcount.peek(args: List<&2, String>, m: Maybe<&2, KV.Item<String>>) -> Reply:
  match m:
    case Some{KV.Item{+w, e}}:
      bitcount.args(w, args)
    case None{}:
      r_int(0n)

def bitpos.peek(args: List<&2, String>, m: Maybe<&2, KV.Item<String>>) -> Reply:
  match m:
    case Some{KV.Item{+w, e}}:
      bitpos.of(w, args)
    case None{}:
      bitpos.none(args)

# BITFIELD's fields. The byte at index i of the value as the writes so
# far leave it: the span sp's (its bytes lo on, below) where it lies, else
# w's (byte.at reads 0 past the end of either); a read alone has no span
def bf.vbyte(in: Bool, +w: String, +sp: String, +lo: Nat, +i: Nat) -> U32:
  match in:
    case True{}:
      byte.at(sp, Nat.sub(i, lo))
    case False{}:
      byte.at(w, i)

def bf.vb(+w: String, +sp: String, +lo: Nat, +i: Nat) -> U32:
  bf.vbyte(Bool.and(Nat.is_le(lo, i), Nat.is_lt(i, Nat.add(lo, String.length(sp)))), w, sp, lo, i)

# the bits a to b - 1 of a byte x (its bit 0 the high one, as SETBIT
# numbers them)
def bf.part(+x: U32, +a: Nat, +b: Nat) -> U32:
  U32.and(U32.shrn(x, Nat.sub(8n, b)), w64.mask32(Nat.sub(b, a)))

# a field's bits, bits s to e - 1 of k bytes from byte i: each byte's part
# after acc (q the byte's first bit, from the first byte's)
def bf.rd(k: Nat, +w: String, +sp: String, +lo: Nat, +i: Nat, +q: Nat, +s: Nat, +e: Nat, acc: W64) -> W64:
  match k:
    case 0n:
      acc
    case 1n+m:
      +a = Nat.sub(Nat.max(s, q), q)
      +b = Nat.sub(Nat.min(e, Nat.add(q, 8n)), q)
      bf.rd(m, w, sp, lo, Nat.add(i, 1n), Nat.add(q, 8n), s, e, w64.shln8(acc, Nat.sub(b, a), bf.part(bf.vb(w, sp, lo, i), a, b)))

# the bits of a field of bits bits at bit offset off
def bf.field(+w: String, +sp: String, +lo: Nat, +bits: Nat, +off: Nat) -> W64:
  +s = Nat.mod(off, 8n)
  +e = Nat.add(s, bits)
  bf.rd(Nat.div(Nat.add(e, 7n), 8n), w, sp, lo, Nat.div(off, 8n), 0n, s, e, w64.zero())

# a field's value, from its bits: signed, its sign extended
def bf.val(sign: Bool, +raw: W64, +bits: Nat) -> W64:
  match sign:
    case True{}:
      w64.sext(raw, bits)
    case False{}:
      raw

def bf.rint(+sign: Bool, +bits: Nat, +raw: W64) -> Reply:
  RIntS{w64.show(bf.val(sign, raw, bits))}

def bf.get(+w: String, +sign: Bool, +bits: Nat, +off: Nat) -> Reply:
  bf.rint(sign, bits, bf.field(w, "", 0n, bits, off))

def bf.read1(op: BfOp, +w: String) -> Reply:
  match op:
    case BfGet{+sign, +bits, +off}:
      bf.get(w, sign, bits, off)
    case _:
      RNull{}

# BITFIELD_RO, and BITFIELD with GETs alone: each a read of the value w
# ("" for a key not there), the replies before acc reversed
def bf.reads(ops: List<&2, BfOp>, +w: String, acc: List<&2, Reply>) -> List<&2, Reply>:
  match ops:
    case Nil{}:
      List.reverse(&2, Reply, acc)
    case Con{op, rest}:
      bf.reads(rest, w, bf.read1(op, w) <> acc)

def bf.peek(ops: List<&2, BfOp>, m: Maybe<&2, KV.Item<String>>) -> Reply:
  match m:
    case Some{KV.Item{+w, e}}:
      RArray{bf.reads(ops, w, Nil{})}
    case None{}:
      RArray{bf.reads(ops, "", Nil{})}

# Hashes
# ------
# A hash's reads. A key not there reads as an empty hash, as in Redis
# (HMGET's nulls, HLEN 0, an empty scan with cursor 0); a key that holds a
# string answers WRONGTYPE.

def hp.fields(ps: List<&2, KV.HPair>) -> List<&2, Reply>:
  match ps:
    case Nil{}:
      Nil{}
    case Con{KV.HP{f, v}, rest}:
      RBulk{f} <> hp.fields(rest)

def hp.values(ps: List<&2, KV.HPair>) -> List<&2, Reply>:
  match ps:
    case Nil{}:
      Nil{}
    case Con{KV.HP{f, v}, rest}:
      RBulk{v} <> hp.values(rest)

def hp.flat(ps: List<&2, KV.HPair>) -> List<&2, Reply>:
  match ps:
    case Nil{}:
      Nil{}
    case Con{KV.HP{f, v}, rest}:
      RBulk{f} <> RBulk{v} <> hp.flat(rest)

# the pairs whose field matches the pattern p (all of them when it is
# "*"), flat
def hp.keep(ok: Bool, f: String, v: String, rest: List<&2, Reply>) -> List<&2, Reply>:
  match ok:
    case True{}:
      RBulk{f} <> RBulk{v} <> rest
    case False{}:
      rest

def hp.glob(+all: Bool, +p: String, ps: List<&2, KV.HPair>) -> List<&2, Reply>:
  match ps:
    case Nil{}:
      Nil{}
    case Con{KV.HP{+f, v}, rest}:
      hp.keep(glob_hit(all, p, f), f, v, hp.glob(all, p, rest))

def hp.match(ps: List<&2, KV.HPair>, pat: Maybe<&2, String>) -> List<&2, Reply>:
  match pat:
    case Some{+p}:
      hp.glob(String.eq(p, "*"), p, ps)
    case None{}:
      hp.flat(ps)

def hmget.none(fs: List<&2, String>) -> List<&2, Reply>:
  match fs:
    case Nil{}:
      Nil{}
    case Con{f, rest}:
      RNull{} <> hmget.none(rest)

def hmget(fs: List<&2, String>, +h: KV.Hash) -> List<&2, Reply>:
  match fs:
    case Nil{}:
      Nil{}
    case Con{+f, rest}:
      r_get(KV.hash.get(f, h)) <> hmget(rest, h)

# HSCAN's options: MATCH and COUNT, as SCAN reads them (scan.opts), and
# any other word a syntax error (TYPE is SCAN's alone)
def hscan.set(o: Nat, v: String, +cur: Nat, +n: Nat, pat: Maybe<&2, String>) -> ScanArgs:
  match o:
    case 1n:
      scan.count.set(scan.count(v), cur, pat, None{})
    case 2n:
      ScanArgs{cur, n, Some{v}, None{}}
    case _:
      ScanBad{RError{"ERR syntax error"}}

def hscan.opts(xs: List<&2, String>, a: ScanArgs) -> ScanArgs:
  match xs a:
    case _ ScanBad{r}:
      ScanBad{r}
    case Nil{} a:
      a
    case Con{+w, Con{v, rest}} ScanArgs{+cur, +n, pat, typ}:
      hscan.opts(rest, hscan.set(scan.word(w), v, cur, n, pat))
    case Con{w, Nil{}} ScanArgs{cur, n, pat, typ}:
      ScanBad{RError{"ERR syntax error"}}

def hscan.args.of(c: Maybe<&2, Nat>, rest: List<&2, String>) -> ScanArgs:
  match c:
    case Some{+cur}:
      hscan.opts(rest, ScanArgs{cur, 10n, None{}, None{}})
    case None{}:
      ScanBad{RError{"ERR invalid cursor"}}

def hscan.args(args: List<&2, String>) -> ScanArgs:
  match args:
    case Con{+c, rest}:
      hscan.args.of(scan.cursor(c), rest)
    case Nil{}:
      ScanBad{RError{"ERR invalid cursor"}}

def hscan.rep(+next: Nat, ps: List<&2, KV.HPair>, pat: Maybe<&2, String>) -> Reply:
  RArray{[RBulk{Nat.show(next)}, RArray{hp.match(ps, pat)}]}

# a large hash scans its trie of fields as SCAN scans the keys (the
# cursor is a bucket's index), COUNT fields a call; a small one answers
# all its pairs at once, with cursor 0, as Redis answers a listpack
def hscan.big(+t: KV.Trie<String>, sc: KV.Scan, pat: Maybe<&2, String>) -> Reply:
  match sc:
    case KV.Stop{+at, acc}:
      hscan.rep(Bool.pick(Nat, Nat.is_lt(at, 1048576n), at, 0n), KV.hash.kv(t, List.reverse(&2, String, acc)), pat)
    case KV.Scan{w, acc}:
      hscan.rep(0n, KV.hash.kv(t, List.reverse(&2, String, acc)), pat)

def hscan.go(+h: KV.Hash, +cur: Nat, +n: Nat, pat: Maybe<&2, String>) -> Reply:
  match h:
    case KV.HSmall{m, +ps}:
      hscan.rep(0n, ps, pat)
    case KV.HBig{m, +t}:
      hscan.big(t, KV.scan(String, t, cur, n, 0n), pat)

def hscan.of(a: ScanArgs, +h: KV.Hash) -> Reply:
  match a:
    case ScanArgs{+cur, +n, pat, typ}:
      hscan.go(h, cur, n, pat)
    case ScanBad{r}:
      r

# a hash read of a key that holds a hash
def hread(op: HRead, +h: KV.Hash) -> Reply:
  match op:
    case HRGet{+f}:
      r_get(KV.hash.get(f, h))
    case HRMGet{fs}:
      RArray{hmget(fs, h)}
    case HRLen{}:
      r_int(KV.hash.len(h))
    case HRStrlen{+f}:
      r_int(String.length(KV.hash.or(KV.hash.get(f, h))))
    case HRExists{+f}:
      r_int(Bool.pick(Nat, KV.hash.has(f, h), 1n, 0n))
    case HRKeys{}:
      RArray{hp.fields(KV.hash.pairs(h))}
    case HRVals{}:
      RArray{hp.values(KV.hash.pairs(h))}
    case HRAll{}:
      RArray{hp.flat(KV.hash.pairs(h))}
    case HRScan{args}:
      hscan.of(hscan.args(args), h)

# of a key not there
def hread.none(op: HRead) -> Reply:
  match op:
    case HRGet{f}:
      RNull{}
    case HRMGet{fs}:
      RArray{hmget.none(fs)}
    case HRLen{}:
      r_int(0n)
    case HRStrlen{f}:
      r_int(0n)
    case HRExists{f}:
      r_int(0n)
    case HRKeys{}:
      RArray{Nil{}}
    case HRVals{}:
      RArray{Nil{}}
    case HRAll{}:
      RArray{Nil{}}
    case HRScan{args}:
      RArray{[RBulk{"0"}, RArray{Nil{}}]}

# of a key that holds a string (m: the string's entry, or none)
def hread.str(op: HRead, m: Maybe<&2, KV.Item<String>>) -> Reply:
  match m:
    case Some{x}:
      e_wrongtype()
    case None{}:
      hread.none(op)

# of a key that holds a collection
def hread.coll(op: HRead, +cl: KV.Coll) -> Reply:
  match cl:
    case KV.CHash{+h}:
      hread(op, h)
    case KV.CList{+l}:
      e_wrongtype()
    case KV.CMems{+m}:
      e_wrongtype()
    case KV.CZset{+z}:
      e_wrongtype()

# A list's reads.

def lbulks(xs: List<&2, String>) -> List<&2, Reply>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{x, rest}:
      RBulk{x} <> lbulks(rest)

def lindex.at(m: Maybe<&2, Nat>, +l: KV.Deq) -> Reply:
  match m:
    case Some{+p}:
      r_get(KV.deq.get(p, l))
    case None{}:
      RNull{}

def lindex.of(m: Maybe<&2, Int>, +l: KV.Deq) -> Reply:
  match m:
    case Some{+i}:
      lindex.at(lidx.at(i, KV.deq.len(l)), l)
    case None{}:
      e_int()

def lrange.of(sp: LSpan, +l: KV.Deq) -> Reply:
  match sp:
    case LSpan{+a, +e}:
      RArray{lbulks(KV.deq.range(a, e, l))}
    case LNone{}:
      RArray{Nil{}}

def lrange.read(ma: Maybe<&2, Int>, mb: Maybe<&2, Int>, +l: KV.Deq) -> Reply:
  match ma mb:
    case Some{+a} Some{+b}:
      lrange.of(lspan(a, b, KV.deq.len(l)), l)
    case _ _:
      e_int()

def lrange.args(args: List<&2, String>, +l: KV.Deq) -> Reply:
  match args:
    case Con{+a, Con{+b, Nil{}}}:
      lrange.read(lnum(a), lnum(b), l)
    case _:
      e_int()

# LPOS's walk, from the end it starts from: the elements xs, the i-th read
# next; stop says the walk is over (the matches it wants are found, or
# MAXLEN elements are read); m matches so far, the positions found
# reversed in acc (the answer with COUNT, else the one position)
def lpos.put(take: Bool, +p: Nat, acc: List<&2, Reply>) -> List<&2, Reply>:
  match take:
    case True{}:
      RInt{IPos{p}} <> acc
    case False{}:
      acc

def lpos.out(cnt: Maybe<&2, Nat>, acc: List<&2, Reply>) -> Reply:
  match cnt acc:
    case Some{c} rs:
      RArray{List.reverse(&2, Reply, rs)}
    case None{} Con{r, rest}:
      r
    case None{} Nil{}:
      RNull{}

# whether the match just taken (the m-th) is the last the walk wants: the
# first one without COUNT, the c-th from RANK on with COUNT c (0: every
# one)
def lpos.full(+cnt: Maybe<&2, Nat>, +rank: Nat, +m: Nat) -> Bool:
  match cnt:
    case None{}:
      True{}
    case Some{+c}:
      Bool.and(Nat.is_lt(0n, c), Nat.is_le(c, 1n+Nat.sub(m, rank)))

def lpos.go(xs: List<&2, String>, stop: Bool, +x: String, +n: Nat, +back: Bool, +rank: Nat, +cnt: Maybe<&2, Nat>, +maxlen: Nat, +i: Nat, +m: Nat, acc: List<&2, Reply>) -> Reply:
  match xs stop:
    case Con{y, rest} False{}:
      +hit = String.eq(y, x)
      +m2 = Bool.pick(Nat, hit, 1n+m, m)
      +take = Bool.and(hit, Nat.is_le(rank, m2))
      +last = Bool.and(Nat.is_lt(0n, maxlen), Nat.is_le(maxlen, 1n+i))
      lpos.go(rest, Bool.or(Bool.and(take, lpos.full(cnt, rank, m2)), last), x, n, back, rank, cnt, maxlen, 1n+i, m2, lpos.put(take, Bool.pick(Nat, back, Nat.sub(Nat.sub(n, 1n), i), i), acc))
    case _ _:
      lpos.out(cnt, acc)

def lpos.elems(back: Bool, +l: KV.Deq) -> List<&2, String>:
  match back:
    case True{}:
      List.reverse(&2, String, KV.deq.all(l))
    case False{}:
      KV.deq.all(l)

def lpos.run(o: LPosOpts, +x: String, +l: KV.Deq) -> Reply:
  match o:
    case LPosOpts{+back, +rank, +cnt, +maxlen}:
      lpos.go(lpos.elems(back, l), False{}, x, KV.deq.len(l), back, rank, cnt, maxlen, 0n, 0n, Nil{})
    case LPosBad{r}:
      r

def lpos.read(args: List<&2, String>, +l: KV.Deq) -> Reply:
  match args:
    case Con{+x, rest}:
      lpos.run(lpos.args(rest), x, l)
    case Nil{}:
      RError{"ERR syntax error"}

# a list read of a key that holds a list
def lread(op: LRead, +l: KV.Deq) -> Reply:
  match op:
    case LRLen{}:
      r_int(KV.deq.len(l))
    case LRIndex{+i}:
      lindex.of(lnum(i), l)
    case LRRange{args}:
      lrange.args(args, l)
    case LRPos{args}:
      lpos.read(args, l)

# of a key not there
def lpos.none(o: LPosOpts) -> Reply:
  match o:
    case LPosOpts{back, rank, Some{c}, maxlen}:
      RArray{Nil{}}
    case LPosOpts{back, rank, None{}, maxlen}:
      RNull{}
    case LPosBad{r}:
      r

def lpos.none.args(args: List<&2, String>) -> Reply:
  match args:
    case Con{x, rest}:
      lpos.none(lpos.args(rest))
    case Nil{}:
      RError{"ERR syntax error"}

def lread.none(op: LRead) -> Reply:
  match op:
    case LRLen{}:
      r_int(0n)
    case LRIndex{i}:
      RNull{}
    case LRRange{args}:
      RArray{Nil{}}
    case LRPos{args}:
      lpos.none.args(args)

# of a key that holds a string (m: the string's entry, or none)
def lread.str(op: LRead, m: Maybe<&2, KV.Item<String>>) -> Reply:
  match m:
    case Some{x}:
      e_wrongtype()
    case None{}:
      lread.none(op)

# of a key that holds a collection
def lread.coll(op: LRead, +cl: KV.Coll) -> Reply:
  match cl:
    case KV.CList{+l}:
      lread(op, l)
    case KV.CHash{+h}:
      e_wrongtype()
    case KV.CMems{+m}:
      e_wrongtype()
    case KV.CZset{+z}:
      e_wrongtype()

# A set's reads. A key not there reads as an empty set, as in Redis
# (SISMEMBER 0, SMISMEMBER's zeros, SCARD 0, SMEMBERS empty, an empty
# scan with cursor 0); a key that holds another kind answers WRONGTYPE.

def smis(ms: List<&2, String>, +s: KV.Mems) -> List<&2, Reply>:
  match ms:
    case Nil{}:
      Nil{}
    case Con{+m, rest}:
      r_int(Bool.pick(Nat, KV.mems.has(m, s), 1n, 0n)) <> smis(rest, s)

def smis.none(ms: List<&2, String>) -> List<&2, Reply>:
  match ms:
    case Nil{}:
      Nil{}
    case Con{m, rest}:
      r_int(0n) <> smis.none(rest)

# the members that match the pattern p (all of them when it is "*")
def ms.keep(ok: Bool, m: String, rest: List<&2, Reply>) -> List<&2, Reply>:
  match ok:
    case True{}:
      RBulk{m} <> rest
    case False{}:
      rest

def ms.glob(+all: Bool, +p: String, xs: List<&2, String>) -> List<&2, Reply>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{+x, rest}:
      ms.keep(glob_hit(all, p, x), x, ms.glob(all, p, rest))

def ms.match(xs: List<&2, String>, pat: Maybe<&2, String>) -> List<&2, Reply>:
  match pat:
    case Some{+p}:
      ms.glob(String.eq(p, "*"), p, xs)
    case None{}:
      lbulks(xs)

def sscan.rep(+next: Nat, xs: List<&2, String>, pat: Maybe<&2, String>) -> Reply:
  RArray{[RBulk{Nat.show(next)}, RArray{ms.match(xs, pat)}]}

# SSCAN: an intset answers all its members at once, with cursor 0, as
# Redis answers one; a hashtable scans its trie as HSCAN scans a hash's
# (the options as HSCAN reads them)
def sscan.big(sc: KV.Scan, pat: Maybe<&2, String>) -> Reply:
  match sc:
    case KV.Stop{+at, acc}:
      sscan.rep(Bool.pick(Nat, Nat.is_lt(at, 1048576n), at, 0n), List.reverse(&2, String, acc), pat)
    case KV.Scan{w, acc}:
      sscan.rep(0n, List.reverse(&2, String, acc), pat)

def sscan.go(+s: KV.Mems, +cur: Nat, +n: Nat, pat: Maybe<&2, String>) -> Reply:
  match s:
    case KV.MInts{m, +xs}:
      sscan.rep(0n, xs, pat)
    case KV.MBig{m, +t}:
      sscan.big(KV.scan(Unit, t, cur, n, 0n), pat)

def sscan.of(a: ScanArgs, +s: KV.Mems) -> Reply:
  match a:
    case ScanArgs{+cur, +n, pat, typ}:
      sscan.go(s, cur, n, pat)
    case ScanBad{r}:
      r

# a set read of a key that holds a set
def sread(op: SRead, +s: KV.Mems) -> Reply:
  match op:
    case SRIs{+m}:
      r_int(Bool.pick(Nat, KV.mems.has(m, s), 1n, 0n))
    case SRMIs{ms}:
      RArray{smis(ms, s)}
    case SRCard{}:
      r_int(KV.mems.len(s))
    case SRAll{}:
      RArray{lbulks(KV.mems.all(s))}
    case SRScan{args}:
      sscan.of(hscan.args(args), s)

# of a key not there
def sread.none(op: SRead) -> Reply:
  match op:
    case SRIs{m}:
      r_int(0n)
    case SRMIs{ms}:
      RArray{smis.none(ms)}
    case SRCard{}:
      r_int(0n)
    case SRAll{}:
      RArray{Nil{}}
    case SRScan{args}:
      RArray{[RBulk{"0"}, RArray{Nil{}}]}

# of a key that holds a string (m: the string's entry, or none)
def sread.str(op: SRead, m: Maybe<&2, KV.Item<String>>) -> Reply:
  match m:
    case Some{x}:
      e_wrongtype()
    case None{}:
      sread.none(op)

# of a key that holds a collection
def sread.coll(op: SRead, +cl: KV.Coll) -> Reply:
  match cl:
    case KV.CMems{+m}:
      sread(op, m)
    case KV.CHash{+h}:
      e_wrongtype()
    case KV.CList{+l}:
      e_wrongtype()
    case KV.CZset{+z}:
      e_wrongtype()

# A sorted set's reads. A key not there reads as an empty sorted set, as
# in Redis (ZCARD 0, nils for scores and ranks, no elements in a range,
# an empty scan with cursor 0); a key that holds another kind answers
# WRONGTYPE. A score is answered as Redis writes a double (%.17g; inf,
# -inf: F.f64.show).

def zscore.reply(m: Maybe<&2, F.F64>) -> Reply:
  match m:
    case Some{+d}:
      RBulk{F.f64.show(d)}
    case None{}:
      RNull{}

def zmscore(ms: List<&2, String>, +z: KV.Zset) -> List<&2, Reply>:
  match ms:
    case Nil{}:
      Nil{}
    case Con{+m, rest}:
      zscore.reply(KV.zset.score(m, z)) <> zmscore(rest, z)

def zmscore.none(ms: List<&2, String>) -> List<&2, Reply>:
  match ms:
    case Nil{}:
      Nil{}
    case Con{m, rest}:
      RNull{} <> zmscore.none(rest)

# a member's rank, from the first element (from the last when rev)
def zrank.of(m: Maybe<&2, F.F64>, +rev: Bool, +k: String, +z: KV.Zset) -> Reply:
  match m:
    case Some{+d}:
      +r = KV.zt.rank(KV.zset.tree(z), k, d)
      r_int(Bool.pick(Nat, rev, Nat.sub(Nat.sub(KV.zset.len(z), r), 1n), r))
    case None{}:
      RNull{}

def zel.m(e: KV.ZEl) -> String:
  match e:
    case KV.ZEl{m, d}:
      m

# a range's elements as Redis answers them: each member, and its score
# after it under WITHSCORES
def zels.one(ws: Bool, m: String, +d: F.F64, rest: List<&2, Reply>) -> List<&2, Reply>:
  match ws:
    case True{}:
      RBulk{m} <> (RBulk{F.f64.show(d)} <> rest)
    case False{}:
      RBulk{m} <> rest

def zels(xs: List<&2, KV.ZEl>, +ws: Bool) -> List<&2, Reply>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{KV.ZEl{m, +d}, rest}:
      zels.one(ws, m, d, zels(rest, ws))

# How a range's elements are found. By rank, as LRANGE reads its range
# (lspan); from the last element when reversed. By score (in order, so a
# walk down the tree finds where a bound falls, KV.zt.before): the ranks
# lo, of the first element in the range, and hi, past its last; then
# LIMIT as Redis reads it (genericZrangebyscoreCommand): an offset above
# 0 and at least the size of the sorted set, or below 0, keeps none, a
# count below 0 keeps all, and a reversed range is read from hi down. By
# member: a large sorted set's as by score (Redis's skiplist is walked
# down the same way, which finds the range when the scores are all the
# same, as Redis asks of such a range); a small one's as a listpack's is
# read, element by element (zzlFirstInLexRange, zzlLastInLexRange):
# none when the bounds alone make the range empty (sdscmplex), or the
# last element is below min, or the first above max; else from the first
# element at least min (the last at most max when reversed), when it is
# in the range, the offset skipped, then the elements while they stay at
# most max (at least min).

# the ranks a LIMIT keeps of the ranks lo to hi - 1, of n (from hi down
# when rev): its offset o (when it is a long at least 0, past keeps
# none) and its count c (n for a count below 0)
type ZWin is Data:
  ZWin{a: Nat, b: Nat}

def zwin.of(past: Bool, rev: Bool, +lo: Nat, +hi: Nat, +o: Nat, +c: Nat) -> ZWin:
  match past rev:
    case True{} _:
      ZWin{0n, 0n}
    case False{} False{}:
      +s = Nat.add(lo, o)
      ZWin{s, Nat.max(s, Nat.min(hi, Nat.add(s, c)))}
    case False{} True{}:
      +top = Nat.max(lo, Nat.sub(hi, o))
      ZWin{Nat.max(lo, Nat.sub(top, c)), top}

def zwin(off: Int, +rev: Bool, +lo: Nat, +hi: Nat, +c: Nat, +n: Nat) -> ZWin:
  match off:
    case INeg{x}:
      ZWin{0n, 0n}
    case IPos{+o}:
      zwin.of(Bool.and(Nat.is_lt(0n, o), Nat.is_le(n, o)), rev, lo, hi, o, c)

def zcnt(c: Int, +n: Nat) -> Nat:
  match c:
    case IPos{x}:
      x
    case INeg{x}:
      n

def zwin.slice(w: ZWin, rev: Bool, +z: KV.Zset) -> List<&2, KV.ZEl>:
  match w:
    case ZWin{+a, +b}:
      KV.zset.slice(rev, z, a, b)

def zrank.range(sp: LSpan, +rev: Bool, +z: KV.Zset) -> List<&2, KV.ZEl>:
  match sp:
    case LSpan{+s, +e}:
      +n = KV.zset.len(z)
      KV.zset.slice(rev, z, Bool.pick(Nat, rev, Nat.sub(Nat.sub(n, 1n), e), s), Bool.pick(Nat, rev, Nat.sub(n, s), Nat.add(e, 1n)))
    case LNone{}:
      Nil{}

# the elements a test holds of, of a list (the first that p holds of on)
def zl.ok(+xs: List<&2, KV.ZEl>, +p: KV.ZP) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case Con{KV.ZEl{+m, +d}, r}:
      KV.zp.ok(p, m, d)

def zl.from.go(xs: List<&2, KV.ZEl>, ok: Bool, +p: KV.ZP) -> List<&2, KV.ZEl>:
  match xs ok:
    case Con{x, +rest} False{}:
      zl.from.go(rest, zl.ok(rest, p), p)
    case ys _:
      ys

def zl.from(+xs: List<&2, KV.ZEl>, +p: KV.ZP) -> List<&2, KV.ZEl>:
  zl.from.go(xs, zl.ok(xs, p), p)

# the first elements of xs while p holds of them, c at most
def zl.take.go(xs: List<&2, KV.ZEl>, ok: Bool, +p: KV.ZP, c: Nat) -> List<&2, KV.ZEl>:
  match xs ok c:
    case Con{x, +rest} True{} 1n+j:
      x <> zl.take.go(rest, zl.ok(rest, p), p, j)
    case _ _ _:
      Nil{}

def zl.take(+xs: List<&2, KV.ZEl>, +p: KV.ZP, c: Nat) -> List<&2, KV.ZEl>:
  zl.take.go(xs, zl.ok(xs, p), p, c)

def zl.drop(xs: List<&2, KV.ZEl>, k: Nat) -> List<&2, KV.ZEl>:
  match xs k:
    case Con{x, rest} 1n+j:
      zl.drop(rest, j)
    case ys _:
      ys

# how two bounds of members compare, as sdscmplex compares them ('-' and
# '+' as the same bound only with themselves)
def zlb.cmp2(+a: KV.ZLB, +b: KV.ZLB) -> Cmp:
  match a b:
    case KV.ZLNeg{} KV.ZLNeg{}:
      EQ{}
    case KV.ZLPos{} KV.ZLPos{}:
      EQ{}
    case KV.ZLNeg{} _:
      LT{}
    case _ KV.ZLPos{}:
      LT{}
    case KV.ZLPos{} _:
      GT{}
    case _ KV.ZLNeg{}:
      GT{}
    case KV.ZLIn{+s} KV.ZLIn{+t}:
      String.order(s, t)
    case KV.ZLIn{+s} KV.ZLEx{+t}:
      String.order(s, t)
    case KV.ZLEx{+s} KV.ZLIn{+t}:
      String.order(s, t)
    case KV.ZLEx{+s} KV.ZLEx{+t}:
      String.order(s, t)

# whether a range of members holds no member by its bounds alone
def zlb.empty(+lo: KV.ZLB, +hi: KV.ZLB) -> Bool:
  +c = zlb.cmp2(lo, hi)
  Bool.or(Cmp.is_gt(c), Bool.and(Cmp.is_eq(c), Bool.or(KV.zlb.ex(lo), KV.zlb.ex(hi))))

def zel.ok(e: KV.ZEl, +p: KV.ZP) -> Bool:
  match e:
    case KV.ZEl{+m, +d}:
      KV.zp.ok(p, m, d)

# whether a small sorted set's range of members can hold an element
# (zzlIsInLexRange)
def zlex.in(+t: KV.ZTree, +lo: KV.ZLB, +hi: KV.ZLB) -> Bool:
  +n = KV.zt.size(t)
  Bool.and(Bool.not(zlb.empty(lo, hi)), Bool.and(Nat.is_lt(0n, n), Bool.and(zel.ok(KV.zt.nth(t, Nat.sub(n, 1n)), KV.ZGeL{lo}), zel.ok(KV.zt.nth(t, 0n), KV.ZLeL{hi}))))

def zlex.take(ok: Bool, +s: List<&2, KV.ZEl>, +o: Nat, +p: KV.ZP, +c: Nat) -> List<&2, KV.ZEl>:
  match ok:
    case True{}:
      zl.take(zl.drop(s, o), p, c)
    case False{}:
      Nil{}

def zlex.small.in(ok: Bool, rev: Bool, +t: KV.ZTree, +lo: KV.ZLB, +hi: KV.ZLB, +o: Nat, +c: Nat) -> List<&2, KV.ZEl>:
  match ok rev:
    case False{} _:
      Nil{}
    case True{} False{}:
      +s = zl.from(KV.zt.all(t), KV.ZGeL{lo})
      zlex.take(zl.ok(s, KV.ZLeL{hi}), s, o, KV.ZLeL{hi}, c)
    case True{} True{}:
      +s = zl.from(KV.zt.rslice(t, 0n, KV.zt.size(t)), KV.ZLeL{hi})
      zlex.take(zl.ok(s, KV.ZGeL{lo}), s, o, KV.ZGeL{lo}, c)

def zlex.small(off: Int, +rev: Bool, +t: KV.ZTree, +lo: KV.ZLB, +hi: KV.ZLB, +c: Nat) -> List<&2, KV.ZEl>:
  match off:
    case INeg{x}:
      Nil{}
    case IPos{+o}:
      zlex.small.in(zlex.in(t, lo, hi), rev, t, lo, hi, o, c)

def zlex.of(small: Bool, +lo: KV.ZLB, +hi: KV.ZLB, +rev: Bool, +off: Int, +cnt: Int, +z: KV.Zset) -> List<&2, KV.ZEl>:
  match small:
    case True{}:
      zlex.small(off, rev, KV.zset.tree(z), lo, hi, zcnt(cnt, KV.zset.len(z)))
    case False{}:
      +t = KV.zset.tree(z)
      +n = KV.zset.len(z)
      zwin.slice(zwin(off, rev, KV.zt.before(t, KV.ZGeL{lo}), KV.zt.before(t, KV.ZNot{KV.ZLeL{hi}}), zcnt(cnt, n), n), rev, z)

# a range's elements, in the order Redis answers them
def zrange.of(r: ZRng, +rev: Bool, +off: Int, +cnt: Int, +z: KV.Zset) -> List<&2, KV.ZEl>:
  match r:
    case ZRankR{+a, +b}:
      zrank.range(lspan(a, b, KV.zset.len(z)), rev, z)
    case ZScoreR{+lo, +hi}:
      +t = KV.zset.tree(z)
      +n = KV.zset.len(z)
      zwin.slice(zwin(off, rev, KV.zt.before(t, KV.ZGeS{lo}), KV.zt.before(t, KV.ZNot{KV.ZLeS{hi}}), zcnt(cnt, n), n), rev, z)
    case ZLexR{+lo, +hi}:
      zlex.of(KV.zset.is_small(z), lo, hi, rev, off, cnt, z)

# a read's elements, from the last when rev
def zq.els(q: ZQ, +rev: Bool, +z: KV.Zset) -> List<&2, KV.ZEl>:
  match q:
    case ZQ{r, +off, +cnt, ws}:
      zrange.of(r, rev, off, cnt, z)
    case ZQRev{q}:
      zq.els(q, True{}, z)

def zq.run(q: ZQ, +z: KV.Zset) -> List<&2, KV.ZEl>:
  zq.els(q, False{}, z)

# whether a read answers the scores (WITHSCORES)
def zq.scores(q: ZQ) -> Bool:
  match q:
    case ZQ{r, off, cnt, +ws}:
      ws
    case ZQRev{q}:
      zq.scores(q)

def zq.reply(+q: ZQ, +z: KV.Zset) -> Reply:
  RArray{zels(zq.run(q, z), zq.scores(q))}

# ZCOUNT: the elements between the ranks of its bounds; ZLEXCOUNT: of a
# small sorted set, those its range by member holds (as above), of a
# large one, those between the ranks of its bounds
def zcount(+lo: KV.ZSB, +hi: KV.ZSB, +z: KV.Zset) -> Nat:
  +t = KV.zset.tree(z)
  Nat.sub(KV.zt.before(t, KV.ZNot{KV.ZLeS{hi}}), KV.zt.before(t, KV.ZGeS{lo}))

def zlexcount.of(small: Bool, +lo: KV.ZLB, +hi: KV.ZLB, +z: KV.Zset) -> Nat:
  match small:
    case True{}:
      List.length(&2, KV.ZEl, zlex.small(IPos{0n}, False{}, KV.zset.tree(z), lo, hi, KV.zset.len(z)))
    case False{}:
      +t = KV.zset.tree(z)
      Nat.sub(KV.zt.before(t, KV.ZNot{KV.ZLeL{hi}}), KV.zt.before(t, KV.ZGeL{lo}))

# ZCOUNT's range (k 2) or ZLEXCOUNT's (k 3), read again as it runs: the
# count, or the error of a range that does not read
def zcount.rng(m: Maybe<&2, ZRng>, +k: Nat, +z: KV.Zset) -> Reply:
  match m:
    case Some{ZScoreR{+lo, +hi}}:
      r_int(zcount(lo, hi, z))
    case Some{ZLexR{+lo, +hi}}:
      r_int(zlexcount.of(KV.zset.is_small(z), lo, hi, z))
    case _:
      zrng.err(k)

def zcount.args(+k: Nat, args: List<&2, String>, +z: KV.Zset) -> Reply:
  match args:
    case Con{+a, Con{+b, rest}}:
      zcount.rng(zrng.of(k, a, b), k, z)
    case _:
      zrng.err(k)

# ZSCAN: a small sorted set answers all its elements at once, with cursor
# 0, each score as a listpack keeps it (F.f64.show_lp); a large one scans
# its trie of members as HSCAN scans a hash's, each score as Redis writes
# a double (the options as HSCAN reads them)
def zscan.lp(xs: List<&2, KV.ZEl>) -> List<&2, KV.HPair>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{KV.ZEl{m, +d}, rest}:
      KV.HP{m, F.f64.show_lp(d)} <> zscan.lp(rest)

def zscan.score(m: Maybe<&2, F.F64>) -> String:
  match m:
    case Some{+d}:
      F.f64.show(d)
    case None{}:
      "0"

def zscan.kv(+t: KV.Trie<F.F64>, ks: List<&2, String>) -> List<&2, KV.HPair>:
  match ks:
    case Nil{}:
      Nil{}
    case Con{+k, rest}:
      KV.HP{k, zscan.score(KV.get(F.F64, t, k))} <> zscan.kv(t, rest)

def zscan.big(+t: KV.Trie<F.F64>, sc: KV.Scan, pat: Maybe<&2, String>) -> Reply:
  match sc:
    case KV.Stop{+at, acc}:
      hscan.rep(Bool.pick(Nat, Nat.is_lt(at, 1048576n), at, 0n), zscan.kv(t, List.reverse(&2, String, acc)), pat)
    case KV.Scan{w, acc}:
      hscan.rep(0n, zscan.kv(t, List.reverse(&2, String, acc)), pat)

def zscan.go(+z: KV.Zset, +cur: Nat, +n: Nat, pat: Maybe<&2, String>) -> Reply:
  match z:
    case KV.ZSmall{+tr}:
      hscan.rep(0n, zscan.lp(KV.zt.all(tr)), pat)
    case KV.ZBig{tr, +t}:
      zscan.big(t, KV.scan(F.F64, t, cur, n, 0n), pat)

def zscan.of(a: ScanArgs, +z: KV.Zset) -> Reply:
  match a:
    case ScanArgs{+cur, +n, pat, typ}:
      zscan.go(z, cur, n, pat)
    case ScanBad{r}:
      r

# a read of a key that holds a sorted set
def zread(op: ZRead, +z: KV.Zset) -> Reply:
  match op:
    case ZRCard{}:
      r_int(KV.zset.len(z))
    case ZRScore{+m}:
      zscore.reply(KV.zset.score(m, z))
    case ZRMScore{ms}:
      RArray{zmscore(ms, z)}
    case ZRRank{+m}:
      zrank.of(KV.zset.score(m, z), False{}, m, z)
    case ZRRevRank{+m}:
      zrank.of(KV.zset.score(m, z), True{}, m, z)
    case ZRCount{args}:
      zcount.args(2n, args, z)
    case ZRLexCount{args}:
      zcount.args(3n, args, z)
    case ZRRange{q}:
      zq.reply(q, z)
    case ZRScan{args}:
      zscan.of(hscan.args(args), z)

# of a key not there
def zread.none(op: ZRead) -> Reply:
  match op:
    case ZRCard{}:
      r_int(0n)
    case ZRScore{m}:
      RNull{}
    case ZRMScore{ms}:
      RArray{zmscore.none(ms)}
    case ZRRank{m}:
      RNull{}
    case ZRRevRank{m}:
      RNull{}
    case ZRCount{args}:
      r_int(0n)
    case ZRLexCount{args}:
      r_int(0n)
    case ZRRange{q}:
      RArray{Nil{}}
    case ZRScan{args}:
      RArray{[RBulk{"0"}, RArray{Nil{}}]}

# of a key that holds a string (m: the string's entry, or none)
def zread.str(op: ZRead, m: Maybe<&2, KV.Item<String>>) -> Reply:
  match m:
    case Some{x}:
      e_wrongtype()
    case None{}:
      zread.none(op)

# of a key that holds a collection
def zread.coll(op: ZRead, +cl: KV.Coll) -> Reply:
  match cl:
    case KV.CZset{+z}:
      zread(op, z)
    case _:
      e_wrongtype()

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
    case PRange{args}:
      range.peek(args, m)
    case PGetBit{+off}:
      getbit.peek(off, m)
    case PCount{args}:
      bitcount.peek(args, m)
    case PPos{args}:
      bitpos.peek(args, m)
    case PBitfield{ops}:
      bf.peek(ops, m)
    case PHash{op}:
      hread.str(op, m)
    case PList{op}:
      lread.str(op, m)
    case PMems{op}:
      sread.str(op, m)
    case PZset{op}:
      zread.str(op, m)

# a Peek of a key that holds a collection: its type, its time, a read of
# a hash of a hash, or WRONGTYPE for a read of a string
def peek.coll(c: PeekOp, +now: Nat, +cl: KV.Coll, +e: Nat) -> Reply:
  match c:
    case PType{}:
      RStatus{coll.type(cl)}
    case PTtl{}:
      ttl.of(False{}, False{}, now, Some{KV.Item{"", e}})
    case PPttl{}:
      ttl.of(True{}, False{}, now, Some{KV.Item{"", e}})
    case PExpTime{}:
      ttl.of(False{}, True{}, now, Some{KV.Item{"", e}})
    case PPExpTime{}:
      ttl.of(True{}, True{}, now, Some{KV.Item{"", e}})
    case PHash{op}:
      hread.coll(op, cl)
    case PList{op}:
      lread.coll(op, cl)
    case PMems{op}:
      sread.coll(op, cl)
    case PZset{op}:
      zread.coll(op, cl)
    case _:
      e_wrongtype()

# the reply of a Peek, from the entry of its key there at now: a string
# is read as above
def peek.v(c: PeekOp, +now: Nat, m: Maybe<&2, KV.Item<KV.Val>>) -> Reply:
  match m:
    case Some{KV.Item{KV.VStr{w}, e}}:
      peek(c, now, Some{KV.Item{w, e}})
    case Some{KV.Item{KV.VColl{+cl}, +e}}:
      peek.coll(c, now, cl, e)
    case None{}:
      peek(c, now, None{})

# What a write of one key does to it: nothing, delete it, set its time
# alone, set its value and its time (0: none), or set its value and keep
# its time, for a key that is there (CKeepT; CApp for an APPEND of s,
# CRange for a SETRANGE of s at offset off, each of which leaves v), or
# set it to a hash: one the key held, changed by a write of a hash (an
# HSET of pairs, or an HDEL of fields), its time kept (CHash), or a new
# one, with no time, made of pairs where the key was not there at now
# (CHashNew); or set it to a list: one the key held, changed by a write
# of a list, its time kept (CList), or a new one, with no time, made of
# pushes where the key was not there at now (CListNew: the elements xs
# pushed in turn at its first end, left, or its last); or set it to a
# set: one the key held, changed by a write of a set, its time kept
# (CMems), or a new one, with no time, made of members where the key was
# not there at now (CMemsNew: the members ms added in turn); each keeps
# the write the append-only file logs. An
# Upd's reply and change come from the key's entry there at now alone. A
# time a change gives a key is one the key may keep (KV.clamp: a time at
# or past the year 5138 is none), and a key without a time is never given
# none again (exp.to): so the change the append-only file logs for it
# (aof.bend) makes it again, on any database.
type Change is Data:
  CKeep{}
  CDel{}
  CExp{e: Nat}
  CPut{v: String, e: Nat}
  CKeepT{v: String}
  CApp{s: String, v: String}
  CRange{off: Nat, s: String, v: String}
  CHash{op: HWrite, h: KV.Hash}
  CHashNew{ps: List<&2, KV.HPair>, h: KV.Hash}
  CList{op: LWrite, l: KV.Deq}
  CListNew{left: Bool, xs: List<&2, String>, l: KV.Deq}
  CMems{op: SWrite, s: KV.Mems}
  CMemsNew{ms: List<&2, String>, s: KV.Mems}
  CZset{op: ZWrite, z: KV.Zset}
  CZsetNew{o: ZOpts, ps: List<&2, ZPair>, z: KV.Zset}

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

# INCRBYFLOAT, as Redis 7.0.15 runs it on x86-64 (float.bend): the value
# and the increment read as long doubles (string2ld), added in x87's
# precision, the sum written as ld2string writes one for people; the key
# keeps its time (Redis propagates the SET of the sum with KEEPTTL), and
# a key not there is 0
def uincrf.fin(bad: Bool, +s: F.Fl, keep: Bool) -> Out:
  match bad:
    case True{}:
      Out{RError{"ERR increment would produce NaN or Infinity"}, CKeep{}}
    case False{}:
      +v = F.fl.show_human(s)
      Out{RBulk{v}, uincr.ch(keep, v)}

def uincrf.add(a: Maybe<&2, F.Fl>, b: Maybe<&2, F.Fl>, keep: Bool) -> Out:
  match a b:
    case Some{x} Some{y}:
      +s = F.fl.add(F.fmt.ld(), x, y)
      uincrf.fin(Bool.or(F.fl.is_nan(s), F.fl.is_inf(s)), s, keep)
    case _ _:
      Out{RError{"ERR value is not a valid float"}, CKeep{}}

def uincrf.of(+by: String, m: Maybe<&2, KV.Item<String>>) -> Out:
  match m:
    case Some{KV.Item{+w, e}}:
      uincrf.add(F.ld.parse(w), F.ld.parse(by), True{})
    case None{}:
      uincrf.add(Some{F.fl.zero(False{})}, F.ld.parse(by), False{})

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

# SETRANGE: s written at offset off of the value, which zero bytes pad
# when it is shorter; the key keeps its time, and a key not there is made
# with none. An empty s changes nothing (the reply is the value's length,
# 0 for no key, and no key is made); a value that would pass 512MB
# (proto-max-bulk-len) is an error (range.go; an offset of 14 digits or
# more does). The offset is small (KV.small), so the append-only file
# reads it back (aof.bend).
def range.go(+off: Nat, +s: String) -> Bool:
  Bool.and(Bool.not(String.is_empty(s)), Bool.and(KV.small(off), Nat.is_le(Nat.add(off, String.length(s)), 536870912n)))

# n zero bytes: the halves made once and put together (f bounds the
# depth; 64 is more than any n needs)
def zeros.go(f: Nat, n: Nat) -> String:
  match f n:
    case _ 0n:
      ""
    case 0n _:
      ""
    case 1n+g 1n++p:
      +h = zeros.go(g, Nat.div(1n+p, 2n))
      Bool.pick(String, Nat.is_eq(Nat.mod(1n+p, 2n), 1n), SCon{Chr{0}, SNil{}}, "") ++ h ++ h

def zeros(n: Nat) -> String:
  zeros.go(64n, n)

def range.put(+w: String, +off: Nat, +s: String) -> String:
  String.take(w, off) ++ zeros(Nat.sub(off, String.length(w))) ++ s ++ String.drop(w, Nat.add(off, String.length(s)))

def range.err() -> Reply:
  RError{"ERR string exceeds maximum allowed size (proto-max-bulk-len)"}

# of a key there, with value w: a def, so that the value is made only
# when it may (ok)
def range.some(ok: Bool, +off: Nat, +s: String, +w: String, +empty: Bool) -> Out:
  match ok:
    case True{}:
      +v = range.put(w, off, s)
      Out{r_int(String.length(v)), CRange{off, s, v}}
    case False{}:
      Out{Bool.pick(Reply, empty, r_int(String.length(w)), range.err()), CKeep{}}

def range.none(ok: Bool, +off: Nat, +s: String, +empty: Bool) -> Out:
  match ok:
    case True{}:
      +v = range.put("", off, s)
      Out{r_int(String.length(v)), CPut{v, 0n}}
    case False{}:
      Out{Bool.pick(Reply, empty, r_int(0n), range.err()), CKeep{}}

def range.of(+off: Nat, +s: String, m: Maybe<&2, KV.Item<String>>) -> Out:
  match m:
    case Some{KV.Item{+w, e}}:
      range.some(range.go(off, s), off, s, w, String.is_empty(s))
    case None{}:
      range.none(range.go(off, s), off, s, String.is_empty(s))

# SETBIT: the bit at offset off set to on; the reply is the bit it was. A
# key not there is made, of zero bytes up to the bit's, as a value too
# short grows to it: the change is the SETRANGE of the bit's new byte (an
# offset below 2^32 is a byte's below 2^29, so it never fails). A bit
# already so changes nothing.
def bit.put(+x: U32, +sh: Nat, +on: Bool) -> U32:
  Bool.pick(U32, on, U32.or(x, U32.shln(1, sh)), U32.and(x, U32.not(U32.shln(1, sh))))

# the byte the bit at off is in, of a value w, and the bit's place in it
# (7 for its high bit)
def setbit.x(+off: Nat, +w: String) -> U32:
  byte.at(w, Nat.div(off, 8n))

def setbit.sh(+off: Nat) -> Nat:
  Nat.sub(7n, Nat.mod(off, 8n))

# the bit at off of w, the reply, and its byte x with the bit set to on
def setbit.was(+off: Nat, +w: String) -> Bool:
  U32.is_ne(U32.and(U32.shrn(setbit.x(off, w), setbit.sh(off)), 1), 0)

def setbit.r(+off: Nat, +w: String) -> Reply:
  r_int(Bool.pick(Nat, setbit.was(off, w), 1n, 0n))

def setbit.byte(+off: Nat, +on: Bool, +x: U32) -> String:
  SCon{Chr{bit.put(x, setbit.sh(off), on)}, SNil{}}

# whether the bit is so already, in a value long enough
def setbit.same(+off: Nat, +on: Bool, +w: String) -> Bool:
  Bool.and(Nat.is_lt(Nat.div(off, 8n), String.length(w)), Bool.not(Bool.xor(setbit.was(off, w), on)))

def setbit.out(+r: Reply, o: Out) -> Out:
  match o:
    case Out{x, ch}:
      Out{r, ch}

def setbit.some(same: Bool, +off: Nat, +on: Bool, +w: String, +e: Nat) -> Out:
  match same:
    case True{}:
      Out{setbit.r(off, w), CKeep{}}
    case False{}:
      setbit.out(setbit.r(off, w), range.of(Nat.div(off, 8n), setbit.byte(off, on, setbit.x(off, w)), Some{KV.Item{w, e}}))

def setbit.of(+off: Nat, +on: Bool, m: Maybe<&2, KV.Item<String>>) -> Out:
  match m:
    case Some{KV.Item{+w, +e}}:
      setbit.some(setbit.same(off, on, w), off, on, w, e)
    case None{}:
      setbit.out(r_int(0n), range.of(Nat.div(off, 8n), setbit.byte(off, on, 0), None{}))

# BITFIELD's writes. Redis grows the value (makes it, of a key not there)
# to the last byte a write reaches, then runs the operations in turn on
# it. Here they run on the span of the bytes the writes reach, from lo to
# end - 1, as it starts of w's bytes there and zeros past w's end: a write
# reads its field there and puts it back there, a GET reads the span where
# it lies and w elsewhere. The change is the SETRANGE of the span at lo,
# made when the value grows or a write changes its bits (as Redis counts
# a change); a FAIL's overflow writes nothing (its reply a null). A span
# past 512MB (a field across the 2^32-th bit, which Redis lets grow the
# value past what a value may hold, by up to 8 bytes) is the error
# SETRANGE answers there.
def bf.wlo(op: BfOp, +acc: Nat) -> Nat:
  match op:
    case BfGet{sign, bits, off}:
      acc
    case BfSet{sign, bits, +off, v, ow}:
      Nat.min(acc, Nat.div(off, 8n))
    case BfIncr{sign, bits, +off, v, ow}:
      Nat.min(acc, Nat.div(off, 8n))

def bf.wend(op: BfOp, +acc: Nat) -> Nat:
  match op:
    case BfGet{sign, bits, off}:
      acc
    case BfSet{sign, +bits, +off, v, ow}:
      Nat.max(acc, Nat.add(Nat.div(Nat.sub(Nat.add(off, bits), 1n), 8n), 1n))
    case BfIncr{sign, +bits, +off, v, ow}:
      Nat.max(acc, Nat.add(Nat.div(Nat.sub(Nat.add(off, bits), 1n), 8n), 1n))

def bf.lo(ops: List<&2, BfOp>, +acc: Nat) -> Nat:
  match ops:
    case Nil{}:
      acc
    case Con{op, rest}:
      bf.lo(rest, bf.wlo(op, acc))

def bf.end(ops: List<&2, BfOp>, +acc: Nat) -> Nat:
  match ops:
    case Nil{}:
      acc
    case Con{op, rest}:
      bf.end(rest, bf.wend(op, acc))

# bytes lo to end - 1 of w, zeros past its end
def bf.span(+w: String, +lo: Nat, +end: Nat) -> String:
  +s = String.take(String.drop(w, lo), Nat.sub(end, lo))
  s ++ zeros(Nat.sub(Nat.sub(end, lo), String.length(s)))

# the span, whether a write changed the value (or it grows), and the
# replies so far, reversed
type BfRun is Data:
  BfRun{sp: String, ch: Bool, rs: List<&2, Reply>}

# an overflow (Redis's checkSignedBitfieldOverflow and
# checkUnsignedBitfieldOverflow, whose sums wrap as here): 0 none, 1 past
# the field's largest value, 2 past its least
def bf.over(+o: Bool, +u: Bool) -> Nat:
  Bool.pick(Nat, o, 1n, Bool.pick(Nat, u, 2n, 0n))

def bf.sover(+value: W64, +incr: W64, +bits: Nat) -> Nat:
  +max = w64.low(Nat.sub(bits, 1n))
  +min = w64.not(max)
  +maxincr = w64.sub(max, value)
  +minincr = w64.sub(min, value)
  +n64 = Bool.not(Nat.is_eq(bits, 64n))
  bf.over(Bool.or(w64.slt(max, value), Bool.or(Bool.and(n64, w64.slt(maxincr, incr)), Bool.and(Bool.and(Bool.not(w64.is_neg(value)), w64.is_pos(incr)), w64.slt(maxincr, incr)))),
    Bool.or(w64.slt(value, min), Bool.or(Bool.and(n64, w64.slt(incr, minincr)), Bool.and(Bool.and(w64.is_neg(value), w64.is_neg(incr)), w64.slt(incr, minincr)))))

def bf.uover(+value: W64, +incr: W64, +bits: Nat) -> Nat:
  +max = w64.low(bits)
  bf.over(Bool.or(w64.ult(max, value), Bool.and(w64.is_pos(incr), w64.slt(w64.sub(max, value), incr))),
    Bool.and(w64.is_neg(incr), w64.slt(incr, w64.neg(value))))

def bf.over.of(sign: Bool, +value: W64, +incr: W64, +bits: Nat) -> Nat:
  match sign:
    case True{}:
      bf.sover(value, incr, bits)
    case False{}:
      bf.uover(value, incr, bits)

# the value an overflow o leaves: WRAP's (ow 0) the sum's low bits, SAT's
# the field's largest value or its least
def bf.sat(+sign: Bool, +o: Nat, +bits: Nat) -> W64:
  +top = w64.low(Nat.sub(bits, 1n))
  Bool.pick(W64, sign, Bool.pick(W64, Nat.is_eq(o, 1n), top, w64.not(top)), Bool.pick(W64, Nat.is_eq(o, 1n), w64.low(bits), w64.zero()))

def bf.wrap(sign: Bool, +sum: W64, +bits: Nat) -> W64:
  match sign:
    case True{}:
      w64.sext(sum, bits)
    case False{}:
      w64.and(sum, w64.low(bits))

def bf.lim(wrap: Bool, +sign: Bool, +o: Nat, +sum: W64, +bits: Nat) -> W64:
  match wrap:
    case True{}:
      bf.wrap(sign, sum, bits)
    case False{}:
      bf.sat(sign, o, bits)

# the new value: the sum, or what its overflow o leaves
def bf.nv(none: Bool, +o: Nat, +sign: Bool, +ow: Nat, +sum: W64, +bits: Nat) -> W64:
  match none:
    case True{}:
      sum
    case False{}:
      bf.lim(Nat.is_eq(ow, 0n), sign, o, sum, bits)

# a field's k bytes from byte i, the field (bits s to e - 1 of them) the
# new value nb's bits: each byte's part (bits a to b - 1) nb's bits there
def bf.wb(k: Nat, +w: String, +sp: String, +lo: Nat, +i: Nat, +q: Nat, +s: Nat, +e: Nat, +nb: W64) -> String:
  match k:
    case 0n:
      ""
    case 1n+m:
      +a = Nat.sub(Nat.max(s, q), q)
      +b = Nat.sub(Nat.min(e, Nat.add(q, 8n)), q)
      +n = Nat.sub(b, a)
      +sh = Nat.sub(8n, b)
      +y = w64.bits(nb, Nat.sub(e, Nat.add(q, b)), n)
      +x = bf.vb(w, sp, lo, i)
      SCon{Chr{U32.or(U32.and(x, U32.not(U32.shln(w64.mask32(n), sh))), U32.shln(y, sh))}, bf.wb(m, w, sp, lo, Nat.add(i, 1n), Nat.add(q, 8n), s, e, nb)}

# a write of a field's new value nv, its bits raw before; the reply is the
# old value (SET) or the new one (INCRBY), or a null for a FAIL's
# overflow, which writes nothing
def bf.wr.do(fail: Bool, +set: Bool, +bits: Nat, +off: Nat, +w: String, +lo: Nat, +raw: W64, +old: W64, +nv: W64, +sp: String, +ch: Bool, rs: List<&2, Reply>) -> BfRun:
  match fail:
    case True{}:
      BfRun{sp, ch, RNull{} <> rs}
    case False{}:
      +nb = w64.and(nv, w64.low(bits))
      +s = Nat.mod(off, 8n)
      +e = Nat.add(s, bits)
      +i = Nat.div(off, 8n)
      BfRun{range.put(sp, Nat.sub(i, lo), bf.wb(Nat.div(Nat.add(e, 7n), 8n), w, sp, lo, i, 0n, s, e, nb)), Bool.or(ch, Bool.not(w64.eq(nb, raw))), RIntS{w64.show(Bool.pick(W64, set, old, nv))} <> rs}

# a SET (set) of v, or an INCRBY by v, of a field of bits bits at bit
# offset off, under the overflow ow (0 WRAP, 1 SAT, 2 FAIL)
def bf.wr(+set: Bool, +sign: Bool, +bits: Nat, +off: Nat, +v: W64, +ow: Nat, +w: String, +lo: Nat, st: BfRun) -> BfRun:
  match st:
    case BfRun{+sp, +ch, rs}:
      +raw = bf.field(w, sp, lo, bits, off)
      +old = bf.val(sign, raw, bits)
      +value = Bool.pick(W64, set, v, old)
      +incr = Bool.pick(W64, set, w64.zero(), v)
      +o = bf.over.of(sign, value, incr, bits)
      bf.wr.do(Bool.and(Nat.is_lt(0n, o), Nat.is_eq(ow, 2n)), set, bits, off, w, lo, raw, old, bf.nv(Nat.is_eq(o, 0n), o, sign, ow, w64.add(value, incr), bits), sp, ch, rs)

def bf.get.at(+sign: Bool, +bits: Nat, +off: Nat, +w: String, +lo: Nat, st: BfRun) -> BfRun:
  match st:
    case BfRun{+sp, ch, rs}:
      BfRun{sp, ch, bf.rint(sign, bits, bf.field(w, sp, lo, bits, off)) <> rs}

def bf.op(op: BfOp, +w: String, +lo: Nat, st: BfRun) -> BfRun:
  match op:
    case BfGet{+sign, +bits, +off}:
      bf.get.at(sign, bits, off, w, lo, st)
    case BfSet{+sign, +bits, +off, +v, +ow}:
      bf.wr(True{}, sign, bits, off, v, ow, w, lo, st)
    case BfIncr{+sign, +bits, +off, +v, +ow}:
      bf.wr(False{}, sign, bits, off, v, ow, w, lo, st)

def bf.run(ops: List<&2, BfOp>, +w: String, +lo: Nat, st: BfRun) -> BfRun:
  match ops:
    case Nil{}:
      st
    case Con{op, rest}:
      bf.run(rest, w, lo, bf.op(op, w, lo, st))

def bf.lo0(+ops: List<&2, BfOp>) -> Nat:
  bf.lo(ops, 1073741824n)

def bf.run0(+ops: List<&2, BfOp>, +w: String) -> BfRun:
  +lo = bf.lo0(ops)
  +end = bf.end(ops, 0n)
  bf.run(ops, w, lo, BfRun{bf.span(w, lo, end), Nat.is_lt(String.length(w), end), Nil{}})

def bf.put(ok: Bool, +r: Reply, +lo: Nat, +sp: String, m: Maybe<&2, KV.Item<String>>) -> Out:
  match ok:
    case True{}:
      setbit.out(r, range.of(lo, sp, m))
    case False{}:
      Out{range.err(), CKeep{}}

def bf.res(ch: Bool, +r: Reply, +lo: Nat, +sp: String, m: Maybe<&2, KV.Item<String>>) -> Out:
  match ch:
    case True{}:
      bf.put(range.go(lo, sp), r, lo, sp, m)
    case False{}:
      Out{r, CKeep{}}

def bf.fin(st: BfRun, +lo: Nat, m: Maybe<&2, KV.Item<String>>) -> Out:
  match st:
    case BfRun{+sp, ch, rs}:
      bf.res(ch, RArray{List.reverse(&2, Reply, rs)}, lo, sp, m)

def bitfield.of(+ops: List<&2, BfOp>, m: Maybe<&2, KV.Item<String>>) -> Out:
  match m:
    case Some{KV.Item{+w, +e}}:
      bf.fin(bf.run0(ops, w), bf.lo0(ops), Some{KV.Item{w, e}})
    case None{}:
      bf.fin(bf.run0(ops, ""), bf.lo0(ops), None{})

# A hash's writes. A key not there is an empty hash: HSET, HSETNX and
# HINCRBY make it, HDEL finds nothing; a key that holds a hash keeps its
# time, and is deleted when HDEL takes its last field (as Redis deletes
# an empty hash); a key that holds a string answers WRONGTYPE. The change
# keeps the write as the append-only file logs it: the pairs it set, as
# an HSET of them (HSETNX's pair, HINCRBY's field with its sum), or the
# fields HDEL took; fresh says whether the hash is a new one. A write
# that sets no pair (HSET without pairs, which the parser refuses) leaves
# the key as it was, so that no hash is ever empty.

def hchange(fresh: Bool, ps: List<&2, KV.HPair>, h: KV.Hash) -> Change:
  match fresh:
    case True{}:
      CHashNew{ps, h}
    case False{}:
      CHash{HWSet{ps, False{}}, h}

# HSET's pairs set in h, in order, and how many of their fields were new
type HPut is Data:
  HPut{h: KV.Hash, made: Nat}

def hset.go(ps: List<&2, KV.HPair>, acc: HPut) -> HPut:
  match ps acc:
    case Nil{} acc:
      acc
    case Con{KV.HP{+f, +v}, rest} HPut{+h, +made}:
      hset.go(rest, HPut{KV.hash.put(h, f, v), Bool.pick(Nat, KV.hash.has(f, h), made, 1n+made)})

def hset.ch(+fresh: Bool, ps: List<&2, KV.HPair>, h: KV.Hash) -> Change:
  match ps:
    case Nil{}:
      CKeep{}
    case Con{p, rest}:
      hchange(fresh, p <> rest, h)

def hset.out(r: HPut, +fresh: Bool, +ps: List<&2, KV.HPair>, +mset: Bool) -> Out:
  match r:
    case HPut{h, +made}:
      Out{Bool.pick(Reply, mset, r_ok(), r_int(made)), hset.ch(fresh, ps, h)}

def hsetnx.of(had: Bool, +fresh: Bool, +f: String, +v: String, h: KV.Hash) -> Out:
  match had:
    case True{}:
      Out{r_int(0n), CKeep{}}
    case False{}:
      Out{r_int(1n), hchange(fresh, [KV.HP{f, v}], KV.hash.put(h, f, v))}

# HDEL's fields taken out of h, and how many of them it held
type HDel is Data:
  HDel{h: KV.Hash, gone: Nat}

def hdel.one(had: Bool, h: KV.Hash, +f: String, +gone: Nat) -> HDel:
  match had:
    case True{}:
      HDel{KV.hash.del(h, f), 1n+gone}
    case False{}:
      HDel{h, gone}

def hdel.go(fs: List<&2, String>, acc: HDel) -> HDel:
  match fs acc:
    case Nil{} acc:
      acc
    case Con{+f, rest} HDel{+h, +gone}:
      hdel.go(rest, hdel.one(KV.hash.has(f, h), h, f, gone))

def hdel.of(none: Bool, empty: Bool, +fs: List<&2, String>, h: KV.Hash, +gone: Nat) -> Out:
  match none empty:
    case True{} _:
      Out{r_int(0n), CKeep{}}
    case False{} True{}:
      Out{r_int(gone), CDel{}}
    case False{} False{}:
      Out{r_int(gone), CHash{HWDel{fs}, h}}

def hdel.out(r: HDel, +fs: List<&2, String>) -> Out:
  match r:
    case HDel{+h, +gone}:
      hdel.of(Nat.is_eq(gone, 0n), Nat.is_eq(KV.hash.len(h), 0n), fs, h, gone)

# HINCRBY: the field's integer (0 when it is not there) plus by, which
# must fit (14 digits, as INCRBY's)
def hincr.fit(ok: Bool, +s: Int, +fresh: Bool, +f: String, h: KV.Hash) -> Out:
  match ok:
    case True{}:
      +v = int_show(s)
      Out{RInt{s}, hchange(fresh, [KV.HP{f, v}], KV.hash.put(h, f, v))}
    case False{}:
      Out{RError{"ERR increment or decrement would overflow"}, CKeep{}}

def hincr.num(m: Maybe<&2, Int>, +fresh: Bool, +f: String, +by: Int, h: KV.Hash) -> Out:
  match m:
    case Some{i}:
      +s = int_add(i, by)
      hincr.fit(int_fits(s), s, fresh, f, h)
    case None{}:
      Out{RError{"ERR hash value is not an integer"}, CKeep{}}

def hincr.of(cur: Maybe<&2, String>, +fresh: Bool, +f: String, +by: Int, h: KV.Hash) -> Out:
  match cur:
    case Some{s}:
      hincr.num(int_read(s), fresh, f, by, h)
    case None{}:
      hincr.fit(int_fits(by), by, fresh, f, h)

# HINCRBYFLOAT: the field's value read as a long double (0 when the field
# is not there) plus by, the sum written as INCRBYFLOAT writes it; the
# change is the HSET of the field with it, as Redis propagates it
def hincrf.fin(bad: Bool, +s: F.Fl, +fresh: Bool, +f: String, h: KV.Hash) -> Out:
  match bad:
    case True{}:
      Out{RError{"ERR increment would produce NaN or Infinity"}, CKeep{}}
    case False{}:
      +v = F.fl.show_human(s)
      Out{RBulk{v}, hchange(fresh, [KV.HP{f, v}], KV.hash.put(h, f, v))}

def hincrf.num(m: Maybe<&2, F.Fl>, +fresh: Bool, +f: String, +by: F.Fl, h: KV.Hash) -> Out:
  match m:
    case Some{x}:
      +s = F.fl.add(F.fmt.ld(), x, by)
      hincrf.fin(Bool.or(F.fl.is_nan(s), F.fl.is_inf(s)), s, fresh, f, h)
    case None{}:
      Out{RError{"ERR hash value is not a float"}, CKeep{}}

def hincrf.of(cur: Maybe<&2, String>, +fresh: Bool, +f: String, +by: F.Fl, h: KV.Hash) -> Out:
  match cur:
    case Some{s}:
      hincrf.num(F.ld.parse(s), fresh, f, by, h)
    case None{}:
      hincrf.num(Some{F.fl.zero(False{})}, fresh, f, by, h)

# HWNew: a new hash of pairs where the key was, whatever it held (the
# script the append-only file logs, aof.bend), answered 0 as the script
# returns it
def hnew.out(r: HPut, +ps: List<&2, KV.HPair>) -> Out:
  match r:
    case HPut{h, made}:
      Out{r_int(0n), hset.ch(True{}, ps, h)}

def hwrite(op: HWrite, +fresh: Bool, h: KV.Hash) -> Out:
  match op:
    case HWSet{+ps, +mset}:
      hset.out(hset.go(ps, HPut{h, 0n}), fresh, ps, mset)
    case HWSetNx{+f, +v}:
      +g = h
      hsetnx.of(KV.hash.has(f, g), fresh, f, v, g)
    case HWDel{+fs}:
      hdel.out(hdel.go(fs, HDel{h, 0n}), fs)
    case HWIncr{+f, +by}:
      +g = h
      hincr.of(KV.hash.get(f, g), fresh, f, by, g)
    case HWNew{+ps}:
      hnew.out(hset.go(ps, HPut{KV.hash.empty(), 0n}), ps)
    case HWIncrF{+f, +by}:
      +g = h
      hincrf.of(KV.hash.get(f, g), fresh, f, by, g)

# of a key that holds a string: WRONGTYPE, but for HWNew, which makes
# its hash whatever the key held
def hwrite.wrong(op: HWrite) -> Out:
  match op:
    case HWNew{+ps}:
      hwrite(HWNew{ps}, True{}, KV.hash.empty())
    case _:
      Out{e_wrongtype(), CKeep{}}

# of a key that holds a string (m: the string's entry, or none)
def hwrite.str(op: HWrite, m: Maybe<&2, KV.Item<String>>) -> Out:
  match m:
    case Some{x}:
      hwrite.wrong(op)
    case None{}:
      hwrite(op, True{}, KV.hash.empty())

# of a key that holds a collection
def hwrite.coll(op: HWrite, +cl: KV.Coll) -> Out:
  match cl:
    case KV.CHash{h}:
      hwrite(op, False{}, h)
    case KV.CList{l}:
      hwrite.wrong(op)
    case KV.CMems{m}:
      hwrite.wrong(op)
    case KV.CZset{z}:
      hwrite.wrong(op)

# A list's writes. A key not there is an empty list: LPUSH and RPUSH make
# it, LPUSHX and RPUSHX answer 0, the others find nothing (LSET: no such
# key); a key that holds a list keeps its time, and is deleted when a
# write takes its last element (as Redis deletes an empty list); a key
# that holds another kind answers WRONGTYPE. The change keeps the write
# as the client sent it, which the append-only file logs; fresh says
# whether the list is a new one. A write that changes nothing (a push of
# no elements, which the parser refuses; LINSERT without its pivot;
# LREM, LTRIM that take nothing) leaves the key as it was.

def lpush.out(fresh: Bool, +left: Bool, +xs: List<&2, String>, +x: Bool, nl: KV.Deq) -> Out:
  match fresh:
    case True{}:
      +m = nl
      Out{r_int(KV.deq.len(m)), CListNew{left, xs, m}}
    case False{}:
      +m = nl
      Out{r_int(KV.deq.len(m)), CList{lpush.op(left, xs, x), m}}

# skip: a push onto a key not there of LPUSHX or RPUSHX, or of no element
def lpush.of(skip: Bool, fresh: Bool, +left: Bool, +xs: List<&2, String>, +x: Bool, l: KV.Deq) -> Out:
  match skip:
    case True{}:
      +m = l
      Out{r_int(KV.deq.len(m)), CKeep{}}
    case False{}:
      lpush.out(fresh, left, xs, x, KV.deq.pushes(left, xs, l))

def lpop.op(+left: Bool, c: Maybe<&2, String>) -> LWrite:
  match c:
    case Some{n}:
      LWPopN{left, n}
    case None{}:
      LWPop{left}

# a pop's change: the key deleted when the list is left empty
def lpop.ch.of(empty: Bool, r: Reply, +left: Bool, c: Maybe<&2, String>, nl: KV.Deq) -> Out:
  match empty:
    case True{}:
      Out{r, CDel{}}
    case False{}:
      Out{r, CList{lpop.op(left, c), nl}}

def lpop.ch(r: Reply, +left: Bool, c: Maybe<&2, String>, nl: KV.Deq) -> Out:
  +m = nl
  lpop.ch.of(Nat.is_eq(KV.deq.len(m), 0n), r, left, c, m)

def lpop.one(p: KV.Pop, +left: Bool) -> Out:
  match p:
    case KV.Pop{x, nl}:
      lpop.ch(RBulk{x}, left, None{}, nl)
    case KV.PopNone{}:
      Out{RNull{}, CKeep{}}

def lpop.many(st: KV.Pops, +left: Bool, c: String) -> Out:
  match st:
    case KV.Pops{xs, nl}:
      lpop.ch(RArray{lbulks(List.reverse(&2, String, xs))}, left, Some{c}, nl)

# a count of pops, no more than the n elements there (a count may be
# as large as a long long)
def lpop.cap(lt: Bool, +k: Nat, +n: Nat) -> Nat:
  match lt:
    case True{}:
      k
    case False{}:
      n

def lpop.n(fresh: Bool, k: Nat, +left: Bool, c: String, l: KV.Deq) -> Out:
  match fresh k:
    case True{} _:
      Out{RNullA{}, CKeep{}}
    case False{} 0n:
      Out{RArray{Nil{}}, CKeep{}}
    case False{} 1n++j:
      +d = l
      +n = KV.deq.len(d)
      lpop.many(KV.deq.pops(lpop.cap(Nat.is_lt(1n+j, n), 1n+j, n), left, KV.Pops{Nil{}, d}), left, c)

# with a count: an array of up to count elements, or a null array for a
# key not there
def lpop.count(m: Maybe<&2, Nat>, fresh: Bool, +left: Bool, c: String, l: KV.Deq) -> Out:
  match m:
    case Some{k}:
      lpop.n(fresh, k, left, c, l)
    case None{}:
      Out{RError{"ERR value is out of range, must be positive"}, CKeep{}}

def lpop.of(fresh: Bool, +left: Bool, c: Maybe<&2, String>, l: KV.Deq) -> Out:
  match fresh c:
    case True{} None{}:
      Out{RNull{}, CKeep{}}
    case False{} None{}:
      lpop.one(KV.deq.pop(left, l), left)
    case f Some{+n}:
      lpop.count(lcount(n), f, left, n, l)

def lset.at(m: Maybe<&2, Nat>, +i: String, +v: String, l: KV.Deq) -> Out:
  match m:
    case Some{+p}:
      Out{r_ok(), CList{LWSet{i, v}, KV.deq.set(p, v, l)}}
    case None{}:
      Out{RError{"ERR index out of range"}, CKeep{}}

def lset.of(m: Maybe<&2, Int>, +i: String, +v: String, l: KV.Deq) -> Out:
  match m:
    case Some{+ix}:
      +d = l
      lset.at(lidx.at(ix, KV.deq.len(d)), i, v, d)
    case None{}:
      Out{e_int(), CKeep{}}

def lset.fresh(fresh: Bool, +i: String, +v: String, l: KV.Deq) -> Out:
  match fresh:
    case True{}:
      Out{RError{"ERR no such key"}, CKeep{}}
    case False{}:
      lset.of(lnum(i), i, v, l)

# LINSERT: the elements xs with v put before the first p (after it, for
# after), when one is there; hit says whether xs's first element is p
def lins.head(+p: String, +xs: List<&2, String>) -> Bool:
  match xs:
    case Con{+y, +rest}:
      String.eq(y, p)
    case Nil{}:
      False{}

def lins.put(after: Bool, y: String, v: String, rest: List<&2, String>) -> List<&2, String>:
  match after:
    case True{}:
      y <> (v <> rest)
    case False{}:
      v <> (y <> rest)

def lins.go(xs: List<&2, String>, hit: Bool, +after: Bool, +p: String, +v: String, acc: List<&2, String>) -> Maybe<&2, List<&2, String>>:
  match xs hit:
    case Con{y, rest} True{}:
      Some{List.reverse.go(&2, String, acc, lins.put(after, y, v, rest))}
    case Con{y, +rest} False{}:
      +h = lins.head(p, rest)
      lins.go(rest, h, after, p, v, y <> acc)
    case Nil{} _:
      None{}

def lins.op(after: Bool, p: String, v: String) -> LWrite:
  match after:
    case True{}:
      LWAfter{p, v}
    case False{}:
      LWBefore{p, v}

def lins.of(m: Maybe<&2, List<&2, String>>, +n: Nat, +after: Bool, +p: String, +v: String) -> Out:
  match m:
    case Some{xs}:
      Out{r_int(1n+n), CList{lins.op(after, p, v), KV.deq.of(1n+n, xs)}}
    case None{}:
      Out{RInt{INeg{0n}}, CKeep{}}

def lins.fresh(fresh: Bool, +after: Bool, +p: String, +v: String, l: KV.Deq) -> Out:
  match fresh:
    case True{}:
      Out{r_int(0n), CKeep{}}
    case False{}:
      +d = l
      +xs = KV.deq.all(d)
      lins.of(lins.go(xs, lins.head(p, xs), after, p, v, Nil{}), KV.deq.len(d), after, p, v)

# LREM: up to k matches of v taken (k 0: all) from the elements xs, the
# others kept in order; how many were taken
type LRem is Data:
  LRem{xs: List<&2, String>, gone: Nat}

def lrem.keep(hit: Bool, y: String, acc: List<&2, String>) -> List<&2, String>:
  match hit:
    case True{}:
      acc
    case False{}:
      y <> acc

def lrem.go(xs: List<&2, String>, +v: String, +k: Nat, +gone: Nat, acc: List<&2, String>) -> LRem:
  match xs:
    case Nil{}:
      LRem{List.reverse(&2, String, acc), gone}
    case Con{+y, rest}:
      +hit = Bool.and(String.eq(y, v), Bool.or(Nat.is_eq(k, 0n), Nat.is_lt(gone, k)))
      lrem.go(rest, v, k, Bool.pick(Nat, hit, 1n+gone, gone), lrem.keep(hit, y, acc))

# from the last element (back): the elements reversed, and the rest put
# back in order
def lrem.back(back: Bool, r: LRem) -> LRem:
  match back r:
    case True{} LRem{xs, gone}:
      LRem{List.reverse(&2, String, xs), gone}
    case False{} r:
      r

def lrem.elems(back: Bool, +l: KV.Deq) -> List<&2, String>:
  match back:
    case True{}:
      List.reverse(&2, String, KV.deq.all(l))
    case False{}:
      KV.deq.all(l)

def lrem.ch(none: Bool, all: Bool, +gone: Nat, +n: Nat, +c: String, +v: String, xs: List<&2, String>) -> Out:
  match none all:
    case True{} _:
      Out{r_int(0n), CKeep{}}
    case False{} True{}:
      Out{r_int(gone), CDel{}}
    case False{} False{}:
      Out{r_int(gone), CList{LWRem{c, v}, KV.deq.of(Nat.sub(n, gone), xs)}}

def lrem.out(r: LRem, +n: Nat, +c: String, +v: String) -> Out:
  match r:
    case LRem{xs, +gone}:
      lrem.ch(Nat.is_eq(gone, 0n), Nat.is_eq(gone, n), gone, n, c, v, xs)

# count c: c of v from the first element (0: every one), -c from the last
def lrem.of(m: Maybe<&2, Int>, +c: String, +v: String, l: KV.Deq) -> Out:
  match m:
    case Some{IPos{+k}}:
      +d = l
      lrem.out(lrem.go(KV.deq.all(d), v, k, 0n, Nil{}), KV.deq.len(d), c, v)
    case Some{INeg{+k}}:
      +d = l
      lrem.out(lrem.back(True{}, lrem.go(lrem.elems(True{}, d), v, 1n+k, 0n, Nil{})), KV.deq.len(d), c, v)
    case None{}:
      Out{e_int(), CKeep{}}

def lrem.fresh(fresh: Bool, +c: String, +v: String, l: KV.Deq) -> Out:
  match fresh:
    case True{}:
      Out{r_int(0n), CKeep{}}
    case False{}:
      lrem.of(lnum(c), c, v, l)

# LTRIM: the list cut to its range, or deleted when the range holds no
# element; the elements before it (s) and after it (r) go
def ltrim.cut(none: Bool, +s: Nat, +r: Nat, +a: String, +b: String, l: KV.Deq) -> Out:
  match none:
    case True{}:
      Out{r_ok(), CKeep{}}
    case False{}:
      Out{r_ok(), CList{LWTrim{a, b}, KV.deq.dropr(r, KV.deq.dropl(s, l))}}

def ltrim.span(sp: LSpan, +n: Nat, +a: String, +b: String, l: KV.Deq) -> Out:
  match sp:
    case LSpan{+s, +e}:
      +r = Nat.sub(Nat.sub(n, 1n), e)
      ltrim.cut(Nat.is_eq(Nat.add(s, r), 0n), s, r, a, b, l)
    case LNone{}:
      Out{r_ok(), CDel{}}

def ltrim.of(ma: Maybe<&2, Int>, mb: Maybe<&2, Int>, +a: String, +b: String, l: KV.Deq) -> Out:
  match ma mb:
    case Some{+x} Some{+y}:
      +d = l
      +n = KV.deq.len(d)
      ltrim.span(lspan(x, y, n), n, a, b, d)
    case _ _:
      Out{e_int(), CKeep{}}

def ltrim.fresh(fresh: Bool, +a: String, +b: String, l: KV.Deq) -> Out:
  match fresh:
    case True{}:
      Out{r_ok(), CKeep{}}
    case False{}:
      ltrim.of(lnum(a), lnum(b), a, b, l)

# LWNew: a new list of the pushes where the key was, whatever it held
# (the script the append-only file logs, aof.bend), answered 0 as the
# script returns it
def lnew.of(none: Bool, +left: Bool, +xs: List<&2, String>) -> Out:
  match none:
    case True{}:
      Out{r_int(0n), CKeep{}}
    case False{}:
      Out{r_int(0n), CListNew{left, xs, KV.deq.pushes(left, xs, KV.deq.empty())}}

def lwrite(op: LWrite, +fresh: Bool, l: KV.Deq) -> Out:
  match op:
    case LWPush{+left, +xs}:
      lpush.of(List.is_empty(&2, String, xs), fresh, left, xs, False{}, l)
    case LWPushX{+left, +xs}:
      lpush.of(Bool.or(fresh, List.is_empty(&2, String, xs)), fresh, left, xs, True{}, l)
    case LWPop{+left}:
      lpop.of(fresh, left, None{}, l)
    case LWPopN{+left, c}:
      lpop.of(fresh, left, Some{c}, l)
    case LWSet{+i, +v}:
      lset.fresh(fresh, i, v, l)
    case LWBefore{+p, +v}:
      lins.fresh(fresh, False{}, p, v, l)
    case LWAfter{+p, +v}:
      lins.fresh(fresh, True{}, p, v, l)
    case LWRem{+c, +v}:
      lrem.fresh(fresh, c, v, l)
    case LWTrim{+a, +b}:
      ltrim.fresh(fresh, a, b, l)
    case LWNew{+left, +xs}:
      lnew.of(List.is_empty(&2, String, xs), left, xs)

# of a key that holds a string or another collection: WRONGTYPE, but for
# LWNew, which makes its list whatever the key held
def lwrite.wrong(op: LWrite) -> Out:
  match op:
    case LWNew{+left, +xs}:
      lwrite(LWNew{left, xs}, True{}, KV.deq.empty())
    case _:
      Out{e_wrongtype(), CKeep{}}

# of a key that holds a string (m: the string's entry, or none)
def lwrite.str(op: LWrite, m: Maybe<&2, KV.Item<String>>) -> Out:
  match m:
    case Some{x}:
      lwrite.wrong(op)
    case None{}:
      lwrite(op, True{}, KV.deq.empty())

# of a key that holds a collection
def lwrite.coll(op: LWrite, +cl: KV.Coll) -> Out:
  match cl:
    case KV.CList{l}:
      lwrite(op, False{}, l)
    case KV.CHash{h}:
      lwrite.wrong(op)
    case KV.CMems{m}:
      lwrite.wrong(op)
    case KV.CZset{z}:
      lwrite.wrong(op)

# Members at random, by r (the server's random number, and the numbers of
# its Weyl sequence after it, each scrambled by KV.mix): a member of an
# intset by its index, of a hashtable as RANDOMKEY picks a key (KV.pick).
# k different members of a set of n, k below n: an intset's picked and
# dropped in turn; a hashtable's, when k is more than a third of n, by
# n - k members dropped from it at random (Redis's third way), else
# picked until k different ones come, at most 16k + 64 picks (Redis's
# fourth way), as SRANDMEMBER and SPOP pick them.
def srand.next(+r: U32) -> U32:
  U32.add(r, 2654435769)

def srand.at(+r: U32, +n: Nat) -> Nat:
  Nat.mod(U32.to_nat(KV.mix(r)), Nat.max(n, 1n))

def srand.pick(+s: KV.Mems, +r: U32) -> Maybe<&2, String>:
  match s:
    case KV.MInts{+n, +xs}:
      KV.nth(xs, srand.at(r, n))
    case KV.MBig{n, +t}:
      KV.pick(Unit, t, KV.mix(r), 0n)

def srand.cons(m: Maybe<&2, String>, rest: List<&2, String>) -> List<&2, String>:
  match m:
    case Some{x}:
      x <> rest
    case None{}:
      rest

# k members of s, each picked anew
def srand.rep(k: Nat, +s: KV.Mems, +r: U32) -> List<&2, String>:
  match k:
    case 0n:
      Nil{}
    case 1n+j:
      +q = srand.next(r)
      srand.cons(srand.pick(s, q), srand.rep(j, s, q))

# xs without its i-th
def srand.drop(xs: List<&2, String>, i: Nat) -> List<&2, String>:
  match xs i:
    case Con{x, rest} 0n:
      rest
    case Con{x, rest} 1n+j:
      Con{x, srand.drop(rest, j)}
    case Nil{} _:
      Nil{}

def srand.ints(k: Nat, xs: List<&2, String>, +n: Nat, +r: U32) -> List<&2, String>:
  match k:
    case 0n:
      Nil{}
    case 1n+j:
      +q = srand.next(r)
      +i = srand.at(q, n)
      +ys = xs
      srand.cons(KV.nth(ys, i), srand.ints(j, srand.drop(ys, i), Nat.sub(n, 1n), q))

def srand.drop1(m: Maybe<&2, String>, t: KV.Trie<Unit>) -> KV.Trie<Unit>:
  match m:
    case Some{+x}:
      KV.del(Unit, t, x)
    case None{}:
      t

# t with c of its members dropped at random
def srand.thin(c: Nat, t: KV.Trie<Unit>, +r: U32) -> KV.Trie<Unit>:
  match c:
    case 0n:
      t
    case 1n+j:
      +q = srand.next(r)
      +u = t
      srand.thin(j, srand.drop1(KV.pick(Unit, u, KV.mix(q), 0n), u), q)

# the members picked so far (acc, c of them), or all that are wanted
type Gath is Data:
  Gath{acc: KV.Trie<Unit>, c: Nat}
  GathDone{acc: KV.Trie<Unit>}

def srand.fin(done: Bool, acc: KV.Trie<Unit>, c: Nat) -> Gath:
  match done:
    case True{}:
      GathDone{acc}
    case False{}:
      Gath{acc, c}

def srand.put(had: Bool, +x: String, acc: KV.Trie<Unit>, +c: Nat, +k: Nat) -> Gath:
  match had:
    case True{}:
      Gath{acc, c}
    case False{}:
      srand.fin(Nat.is_le(k, 1n+c), KV.set(Unit, acc, x, Unit{}), 1n+c)

def srand.step(m: Maybe<&2, String>, +acc: KV.Trie<Unit>, +c: Nat, +k: Nat) -> Gath:
  match m:
    case Some{+x}:
      srand.put(KV.has(Unit, acc, x), x, acc, c, k)
    case None{}:
      GathDone{acc}

# members of t picked until k different ones come, or fuel runs out
def srand.gather(fuel: Nat, g: Gath, +k: Nat, +t: KV.Trie<Unit>, +r: U32) -> KV.Trie<Unit>:
  match fuel g:
    case _ GathDone{acc}:
      acc
    case 0n Gath{acc, c}:
      acc
    case 1n+f Gath{acc, +c}:
      +q = srand.next(r)
      srand.gather(f, srand.step(KV.pick(Unit, t, KV.mix(q), 0n), acc, c, k), k, t, q)

def srand.big(thin: Bool, +k: Nat, +n: Nat, +t: KV.Trie<Unit>, +r: U32) -> List<&2, String>:
  match thin:
    case True{}:
      KV.keys(Unit, srand.thin(Nat.sub(n, k), t, r), 0n)
    case False{}:
      KV.keys(Unit, srand.gather(Nat.add(Nat.mul(k, 16n), 64n), srand.fin(Nat.is_eq(k, 0n), KV.empty(Unit), 0n), k, t, r), 0n)

# k different members of s, k below its size
def srand.uniq(+k: Nat, +s: KV.Mems, +r: U32) -> List<&2, String>:
  match s:
    case KV.MInts{+n, +xs}:
      srand.ints(k, xs, n, r)
    case KV.MBig{+n, +t}:
      srand.big(Nat.is_lt(n, Nat.mul(k, 3n)), k, n, t, r)

# c different members of s, all of them when c is at least its size
def srand.many.of(all: Bool, +c: Nat, +s: KV.Mems, +r: U32) -> List<&2, String>:
  match all:
    case True{}:
      KV.mems.all(s)
    case False{}:
      srand.uniq(c, s, r)

def srand.many(+c: Nat, +s: KV.Mems, +r: U32) -> List<&2, String>:
  srand.many.of(Nat.is_le(KV.mems.len(s), c), c, s, r)

# A set's writes. A key not there is an empty set: SADD makes it, SREM
# finds nothing; a key that holds a set keeps its time, and is deleted
# when SREM takes its last member (as Redis deletes an empty set); a key
# that holds another kind answers WRONGTYPE. The change keeps the write
# as the append-only file logs it: SADD's members, SREM's; fresh says
# whether the set is a new one. SADD adds no member that is there, and a
# write that adds or takes none leaves the key as it was. SWNew makes a
# new set of its members where the key was, whatever it held, and
# answers 0, as the script the file logs for it does.

# SADD's members added to s: the reply counts them by the size they add
def sadd.ch(fresh: Bool, ms: List<&2, String>, s: KV.Mems) -> Change:
  match fresh:
    case True{}:
      CMemsNew{ms, s}
    case False{}:
      CMems{SWAdd{ms}, s}

def sadd.of(none: Bool, +fresh: Bool, ms: List<&2, String>, s: KV.Mems, +added: Nat) -> Out:
  match none:
    case True{}:
      Out{r_int(0n), CKeep{}}
    case False{}:
      Out{r_int(added), sadd.ch(fresh, ms, s)}

# whether SADD adds none: of a new set, when it has no members (one or
# more members make a set of one or more), else when the size is the same
def sadd.none(fresh: Bool, +ms: List<&2, String>, +added: Nat) -> Bool:
  match fresh:
    case True{}:
      List.is_empty(&2, String, ms)
    case False{}:
      Nat.is_eq(added, 0n)

def sadd.out(+fresh: Bool, +ms: List<&2, String>, +s: KV.Mems) -> Out:
  +n = KV.mems.len(s)
  +t = KV.mems.adds(ms, s)
  +added = Nat.sub(KV.mems.len(t), n)
  sadd.of(sadd.none(fresh, ms, added), fresh, ms, t, added)

# SREM's members taken out of s, and how many of them it held
type SDel is Data:
  SDel{s: KV.Mems, gone: Nat}

def srem.one(had: Bool, s: KV.Mems, +m: String, +gone: Nat) -> SDel:
  match had:
    case True{}:
      SDel{KV.mems.del(s, m), 1n+gone}
    case False{}:
      SDel{s, gone}

def srem.go(ms: List<&2, String>, acc: SDel) -> SDel:
  match ms acc:
    case Nil{} acc:
      acc
    case Con{+m, rest} SDel{+s, +gone}:
      srem.go(rest, srem.one(KV.mems.has(m, s), s, m, gone))

def srem.of(none: Bool, empty: Bool, +ms: List<&2, String>, s: KV.Mems, +gone: Nat) -> Out:
  match none empty:
    case True{} _:
      Out{r_int(0n), CKeep{}}
    case False{} True{}:
      Out{r_int(gone), CDel{}}
    case False{} False{}:
      Out{r_int(gone), CMems{SWRem{ms}, s}}

def srem.out(r: SDel, +ms: List<&2, String>) -> Out:
  match r:
    case SDel{+s, +gone}:
      srem.of(Nat.is_eq(gone, 0n), Nat.is_eq(KV.mems.len(s), 0n), ms, s, gone)

# SPOP's reply: the member it took (a nil for none), or the members, and
# its change: the SREM of them
def spop.reply(one: Bool, xs: List<&2, String>) -> Reply:
  match one xs:
    case True{} Con{x, rest}:
      RBulk{x}
    case True{} Nil{}:
      RNull{}
    case False{} ys:
      RArray{lbulks(ys)}

def spop.ch(o: Out) -> Change:
  match o:
    case Out{r, ch}:
      ch

def spop.out(+one: Bool, +xs: List<&2, String>, s: KV.Mems) -> Out:
  Out{spop.reply(one, xs), spop.ch(srem.out(srem.go(xs, SDel{s, 0n}), xs))}

def spop.one(m: Maybe<&2, String>) -> List<&2, String>:
  srand.cons(m, Nil{})

# SWNew: a new set of the members where the key was, whatever it held
# (the script the append-only file logs, aof.bend), answered 0 as the
# script returns it
def snew.of(none: Bool, +ms: List<&2, String>) -> Out:
  match none:
    case True{}:
      Out{r_int(0n), CKeep{}}
    case False{}:
      Out{r_int(0n), CMemsNew{ms, KV.mems.of(ms)}}

# a write of a set to a set s (an empty one for a key not there: fresh)
def swrite(op: SWrite, +fresh: Bool, +s: KV.Mems) -> Out:
  match op:
    case SWAdd{+ms}:
      sadd.out(fresh, ms, s)
    case SWRem{+ms}:
      srem.out(srem.go(ms, SDel{s, 0n}), ms)
    case SWNew{+ms}:
      snew.of(List.is_empty(&2, String, ms), ms)
    case SWPop{+r}:
      spop.out(True{}, spop.one(srand.pick(s, srand.next(r))), s)
    case SWPopN{+c, +r}:
      spop.out(False{}, srand.many(c, s, r), s)

# of a key that holds another kind: WRONGTYPE, but for SWNew
def swrite.wrong(op: SWrite) -> Out:
  match op:
    case SWNew{+ms}:
      swrite(SWNew{ms}, True{}, KV.mems.empty())
    case _:
      Out{e_wrongtype(), CKeep{}}

# of a key that holds a string (m: the string's entry, or none)
def swrite.str(op: SWrite, m: Maybe<&2, KV.Item<String>>) -> Out:
  match m:
    case Some{x}:
      swrite.wrong(op)
    case None{}:
      swrite(op, True{}, KV.mems.empty())

# of a key that holds a collection
def swrite.coll(op: SWrite, +cl: KV.Coll) -> Out:
  match cl:
    case KV.CMems{m}:
      swrite(op, False{}, m)
    case KV.CHash{h}:
      swrite.wrong(op)
    case KV.CList{l}:
      swrite.wrong(op)
    case KV.CZset{z}:
      swrite.wrong(op)

# A sorted set's writes. A key not there is an empty sorted set: ZADD
# makes it (but under XX, which adds nothing), the others find nothing; a
# key that holds a sorted set keeps its time, and is deleted when a write
# takes its last element (as Redis deletes an empty sorted set); a key
# that holds another kind answers WRONGTYPE. The change keeps the write
# as the client sent it (ZINCRBY as ZADD with INCR), which the
# append-only file logs; a write that changes nothing leaves the key as
# it was.

# ZADD's pairs added in turn to z, as Redis's zsetAdd adds each: a member
# there is left alone under NX; under INCR its score is the increment
# plus the one it had (a NaN is an error that stops the command: INCR
# takes one pair alone, so it changes nothing); under GT (LT) a score not
# above (below) the one it had leaves it alone; else the member takes the
# score, when it is another (-0 is 0). A member not there is left out
# under XX, else added with the score (the increment, under INCR). added
# and upd count the members it added and changed, done those it did not
# leave alone (taking the score they had counts), and last is the score
# the last of those took.
type ZAdd is Data:
  ZAdd{z: KV.Zset, added: Nat, upd: Nat, done: Nat, last: F.F64}
  ZAddNaN{}

def zadd.num(m: Maybe<&2, F.F64>) -> F.F64:
  match m:
    case Some{d}:
      d
    case None{}:
      F.F64{0n, 0n}

def zadd.score(incr: Bool, +c: F.F64, +d: F.F64) -> F.F64:
  match incr:
    case True{}:
      F.f64.of(F.fl.add(F.fmt.d(), F.f64.to(c), F.f64.to(d)))
    case False{}:
      d

def zadd.new(xx: Bool, +d: F.F64, +m: String, z: KV.Zset, +added: Nat, +upd: Nat, +done: Nat, last: F.F64) -> ZAdd:
  match xx:
    case True{}:
      ZAdd{z, added, upd, done, last}
    case False{}:
      ZAdd{KV.zset.add(z, m, d), Nat.add(added, 1n), upd, Nat.add(done, 1n), d}

def zadd.old.of(nx: Bool, nan: Bool, keep: Bool, same: Bool, +sc: F.F64, +c: F.F64, +m: String, z: KV.Zset, +added: Nat, +upd: Nat, +done: Nat, last: F.F64) -> ZAdd:
  match nx nan keep same:
    case True{} _ _ _:
      ZAdd{z, added, upd, done, last}
    case False{} True{} _ _:
      ZAddNaN{}
    case False{} False{} True{} _:
      ZAdd{z, added, upd, done, last}
    case False{} False{} False{} True{}:
      ZAdd{z, added, upd, Nat.add(done, 1n), sc}
    case False{} False{} False{} False{}:
      ZAdd{KV.zset.set(z, m, c, sc), added, Nat.add(upd, 1n), Nat.add(done, 1n), sc}

# a member there, of score c
def zadd.old(+o: ZOpts, +c: F.F64, +d: F.F64, +m: String, z: KV.Zset, +added: Nat, +upd: Nat, +done: Nat, last: F.F64) -> ZAdd:
  match o:
    case ZOpts{+nx, xx, +gt, +lt, ch, +incr}:
      +sc = zadd.score(incr, c, d)
      +cmp = F.f64.cmp(sc, c)
      zadd.old.of(nx, F.f64.is_nan(sc), Bool.or(Bool.and(lt, Bool.not(Cmp.is_lt(cmp))), Bool.and(gt, Bool.not(Cmp.is_gt(cmp)))), Cmp.is_eq(cmp), sc, c, m, z, added, upd, done, last)

def zadd.at(cur: Maybe<&2, F.F64>, +o: ZOpts, +d: F.F64, +m: String, z: KV.Zset, +added: Nat, +upd: Nat, +done: Nat, last: F.F64) -> ZAdd:
  match cur:
    case Some{+c}:
      zadd.old(o, c, d, m, z, added, upd, done, last)
    case None{}:
      zadd.new(zopts.xx(o), d, m, z, added, upd, done, last)

def zadd.step(+o: ZOpts, p: ZPair, st: ZAdd) -> ZAdd:
  match p st:
    case _ ZAddNaN{}:
      ZAddNaN{}
    case ZPair{+s, +m} ZAdd{+z, added, upd, done, last}:
      zadd.at(KV.zset.score(m, z), o, zadd.num(F.f64.parse(s)), m, z, added, upd, done, last)

def zadd.go(ps: List<&2, ZPair>, +o: ZOpts, st: ZAdd) -> ZAdd:
  match ps:
    case Nil{}:
      st
    case Con{p, rest}:
      zadd.go(rest, o, zadd.step(o, p, st))

# ZADD's reply: under INCR the score the member took (nil when it was
# left alone), else how many it added (CH: and changed)
def zadd.reply.of(incr: Bool, +ch: Bool, +added: Nat, +upd: Nat, +done: Nat, +last: F.F64) -> Reply:
  match incr:
    case True{}:
      Bool.pick(Reply, Nat.is_eq(done, 0n), RNull{}, RBulk{F.f64.show(last)})
    case False{}:
      r_int(Bool.pick(Nat, ch, Nat.add(added, upd), added))

def zadd.reply(+o: ZOpts, +added: Nat, +upd: Nat, +done: Nat, +last: F.F64) -> Reply:
  match o:
    case ZOpts{nx, xx, gt, lt, +ch, +incr}:
      zadd.reply.of(incr, ch, added, upd, done, last)

# the change: none when it added and changed nothing; a new sorted set,
# made by the ZADD (of options o and pairs ps) where the key was not
# there (fresh); else the ZADD of the sorted set the key held
def zadd.ch(none: Bool, fresh: Bool, o: ZOpts, ps: List<&2, ZPair>, z: KV.Zset) -> Change:
  match none fresh:
    case True{} _:
      CKeep{}
    case False{} True{}:
      CZsetNew{o, ps, z}
    case False{} False{}:
      CZset{ZWAdd{o, ps}, z}

def zadd.res(st: ZAdd, +fresh: Bool, +o: ZOpts, +ps: List<&2, ZPair>) -> Out:
  match st:
    case ZAddNaN{}:
      Out{RError{"ERR resulting score is not a number (NaN)"}, CKeep{}}
    case ZAdd{z, +added, +upd, +done, +last}:
      Out{zadd.reply(o, added, upd, done, last), zadd.ch(Nat.is_eq(Nat.add(added, upd), 0n), fresh, o, ps, z)}

def zadd.fin(err: Maybe<&2, Reply>, +fresh: Bool, +o: ZOpts, +ps: List<&2, ZPair>, z: KV.Zset) -> Out:
  match err:
    case Some{r}:
      Out{r, CKeep{}}
    case None{}:
      zadd.res(zadd.go(ps, o, ZAdd{z, 0n, 0n, 0n, F.F64{0n, 0n}}), fresh, o, ps)

def zadd.out(+fresh: Bool, +o: ZOpts, +ps: List<&2, ZPair>, z: KV.Zset) -> Out:
  zadd.fin(zadd.check(o, ps), fresh, o, ps, z)

# ZWNew: the change of the ZADD of o and ps on a key not there, made
# where the key was, whatever it held (the script the append-only file
# logs, aof.bend), answered 0 as the script returns it; nothing when it
# adds nothing (XX, which the script's parser refuses)
def znew.out(o: Out) -> Out:
  match o:
    case Out{r, ch}:
      Out{r_int(0n), ch}

# z without the elements xs, which it holds: the reply counts them, and
# the change deletes the key when none is left
def zdels.of(none: Bool, empty: Bool, +op: ZWrite, z: KV.Zset, r: Reply) -> Out:
  match none empty:
    case True{} _:
      Out{r, CKeep{}}
    case False{} True{}:
      Out{r, CDel{}}
    case False{} False{}:
      Out{r, CZset{op, z}}

def zdels.out(+xs: List<&2, KV.ZEl>, +op: ZWrite, z: KV.Zset, r: Reply) -> Out:
  +left = KV.zset.dels(xs, z)
  zdels.of(List.is_empty(&2, KV.ZEl, xs), Nat.is_eq(KV.zset.len(left), 0n), op, left, r)

# ZREM's members taken out of z, and how many of them it held
type ZDel is Data:
  ZDel{z: KV.Zset, gone: Nat}

def zrem.one(m: Maybe<&2, F.F64>, z: KV.Zset, +k: String, +gone: Nat) -> ZDel:
  match m:
    case Some{+d}:
      ZDel{KV.zset.del(z, k, d), Nat.add(gone, 1n)}
    case None{}:
      ZDel{z, gone}

def zrem.go(ms: List<&2, String>, st: ZDel) -> ZDel:
  match ms st:
    case Nil{} acc:
      acc
    case Con{+m, rest} ZDel{+z, +gone}:
      zrem.go(rest, zrem.one(KV.zset.score(m, z), z, m, gone))

def zrem.of(none: Bool, empty: Bool, +ms: List<&2, String>, z: KV.Zset, +gone: Nat) -> Out:
  match none empty:
    case True{} _:
      Out{r_int(0n), CKeep{}}
    case False{} True{}:
      Out{r_int(gone), CDel{}}
    case False{} False{}:
      Out{r_int(gone), CZset{ZWRem{ms}, z}}

def zrem.out(r: ZDel, +ms: List<&2, String>) -> Out:
  match r:
    case ZDel{+z, +gone}:
      zrem.of(Nat.is_eq(gone, 0n), Nat.is_eq(KV.zset.len(z), 0n), ms, z, gone)

# ZREMRANGEBY*: the elements its range holds (read again as it runs: a
# range that does not read answers its error), as ZRANGE finds them with
# no LIMIT, taken out; the reply counts them
def zremr.of(m: Maybe<&2, ZRng>, +k: Nat, +op: ZWrite, +z: KV.Zset) -> Out:
  match m:
    case Some{r}:
      +xs = zrange.of(r, False{}, IPos{0n}, INeg{0n}, z)
      zdels.out(xs, op, z, r_int(List.length(&2, KV.ZEl, xs)))
    case None{}:
      Out{zrng.err(k), CKeep{}}

# of a key not there (fresh): what the empty sorted set answers, and no
# change
def zremr.none(m: Maybe<&2, ZRng>, +k: Nat) -> Out:
  match m:
    case Some{r}:
      Out{r_int(0n), CKeep{}}
    case None{}:
      Out{zrng.err(k), CKeep{}}

def zremr.at(fresh: Bool, m: Maybe<&2, ZRng>, +k: Nat, +op: ZWrite, +z: KV.Zset) -> Out:
  match fresh:
    case True{}:
      zremr.none(m, k)
    case False{}:
      zremr.of(m, k, op, z)

# ZPOPMIN and ZPOPMAX (max): up to c elements from the first end (the
# last), answered with their scores, in the order they are taken
def zpop.pick(max: Bool, +k: Nat, +n: Nat, +z: KV.Zset) -> List<&2, KV.ZEl>:
  match max:
    case True{}:
      KV.zt.rslice(KV.zset.tree(z), Nat.sub(n, k), n)
    case False{}:
      KV.zt.slice(KV.zset.tree(z), 0n, k)

def zpop.els(+max: Bool, +c: Nat, +z: KV.Zset) -> List<&2, KV.ZEl>:
  +n = KV.zset.len(z)
  zpop.pick(max, Nat.min(c, n), n, z)

def zpop.of(m: Maybe<&2, Nat>, +max: Bool, +op: ZWrite, +z: KV.Zset) -> Out:
  match m:
    case Some{+c}:
      +xs = zpop.els(max, c, z)
      zdels.out(xs, op, z, RArray{zels(xs, True{})})
    case None{}:
      Out{RError{"ERR value is out of range, must be positive"}, CKeep{}}

def zpop.none(m: Maybe<&2, Nat>) -> Out:
  match m:
    case Some{c}:
      Out{RArray{Nil{}}, CKeep{}}
    case None{}:
      Out{RError{"ERR value is out of range, must be positive"}, CKeep{}}

def zpop.at(fresh: Bool, m: Maybe<&2, Nat>, +max: Bool, +op: ZWrite, +z: KV.Zset) -> Out:
  match fresh:
    case True{}:
      zpop.none(m)
    case False{}:
      zpop.of(m, max, op, z)

# a write of a sorted set to a sorted set z (an empty one for a key not
# there: fresh)
def zwrite(op: ZWrite, +fresh: Bool, +z: KV.Zset) -> Out:
  match op:
    case ZWAdd{+o, +ps}:
      zadd.out(fresh, o, ps, z)
    case ZWRem{+ms}:
      zrem.out(zrem.go(ms, ZDel{z, 0n}), ms)
    case ZWNew{+o, +ps}:
      znew.out(zadd.out(True{}, o, ps, KV.zset.empty()))
    case ZWRemRank{+a, +b}:
      zremr.at(fresh, zrng.of(1n, a, b), 1n, ZWRemRank{a, b}, z)
    case ZWRemScore{+a, +b}:
      zremr.at(fresh, zrng.of(2n, a, b), 2n, ZWRemScore{a, b}, z)
    case ZWRemLex{+a, +b}:
      zremr.at(fresh, zrng.of(3n, a, b), 3n, ZWRemLex{a, b}, z)
    case ZWPop{+max}:
      zpop.at(fresh, Some{1n}, max, ZWPop{max}, z)
    case ZWPopN{+max, +c}:
      zpop.at(fresh, lcount(c), max, ZWPopN{max, c}, z)

# of a key that holds another kind: WRONGTYPE, but for ZWNew
def zwrite.wrong(op: ZWrite) -> Out:
  match op:
    case ZWNew{+o, +ps}:
      zwrite(ZWNew{o, ps}, True{}, KV.zset.empty())
    case _:
      Out{e_wrongtype(), CKeep{}}

# of a key that holds a string (m: the string's entry, or none)
def zwrite.str(op: ZWrite, m: Maybe<&2, KV.Item<String>>) -> Out:
  match m:
    case Some{x}:
      zwrite.wrong(op)
    case None{}:
      zwrite(op, True{}, KV.zset.empty())

# of a key that holds a collection
def zwrite.coll(op: ZWrite, +cl: KV.Coll) -> Out:
  match cl:
    case KV.CZset{z}:
      zwrite(op, False{}, z)
    case _:
      zwrite.wrong(op)

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
    case URange{+off, +s}:
      range.of(off, s, m)
    case USetBit{+off, +on}:
      setbit.of(off, on, m)
    case UBitfield{ops}:
      bitfield.of(ops, m)
    case UHash{op}:
      hwrite.str(op, m)
    case UList{op}:
      lwrite.str(op, m)
    case UMems{op}:
      swrite.str(op, m)
    case UIncrF{+by}:
      uincrf.of(by, m)
    case UZset{op}:
      zwrite.str(op, m)

# An update of a key that holds a collection: SET (and SETEX, PSETEX)
# replaces it, SETNX finds it there, EXPIRE and its kin and PERSIST set
# its time; they see it as a key there with its time (and an empty
# string, which none of them reads). A write of a collection writes it
# (upd.only). Any other is WRONGTYPE, as Redis answers it, the key left
# as it was; SET with GET answers first the error of a time from now it
# cannot keep, as Redis checks the time before the type.
def upd.any(op: UpdOp) -> Bool:
  match op:
    case USetNx{v}:
      True{}
    case USet{v, cond, ttl, name}:
      True{}
    case UExpire{t, c, name}:
      True{}
    case UPersist{}:
      True{}
    case _:
      False{}

def get.wrong.at(a: Maybe<&2, At>, +name: String) -> Out:
  match a:
    case Some{t}:
      Out{e_wrongtype(), CKeep{}}
    case None{}:
      Out{e_time(name), CKeep{}}

def get.wrong(o: UpdOp, +now: Nat) -> Out:
  match o:
    case USet{v, cond, TAt{t}, +name}:
      get.wrong.at(at.of(t, now), name)
    case _:
      Out{e_wrongtype(), CKeep{}}

def upd.only(op: UpdOp, +now: Nat, +cl: KV.Coll) -> Out:
  match op:
    case UHash{hop}:
      hwrite.coll(hop, cl)
    case UList{lop}:
      lwrite.coll(lop, cl)
    case UMems{sop}:
      swrite.coll(sop, cl)
    case UZset{zop}:
      zwrite.coll(zop, cl)
    case UGet{o}:
      get.wrong(o, now)
    case _:
      Out{e_wrongtype(), CKeep{}}

def upd.coll(any: Bool, op: UpdOp, +now: Nat, +cl: KV.Coll, +e: Nat) -> Out:
  match any:
    case True{}:
      upd(op, now, Some{KV.Item{"", e}})
    case False{}:
      upd.only(op, now, cl)

# an update of a key, from its entry there at now: a string is updated as
# above
def upd.v(op: UpdOp, +now: Nat, m: Maybe<&2, KV.Item<KV.Val>>) -> Out:
  match m:
    case Some{KV.Item{KV.VStr{w}, e}}:
      upd(op, now, Some{KV.Item{w, e}})
    case Some{KV.Item{KV.VColl{+cl}, +e}}:
      +o = op
      upd.coll(upd.any(o), o, now, cl, e)
    case None{}:
      upd(op, now, None{})

# the change done to key k, whose code was c (a deleted key, or one whose
# time alone changes, was there)
def upd.ch(t: KV.Trie<KV.Val>, +k: String, +h: U32, +n: Nat, +x: Nat, now: Nat, rr: Maybe<&2, Db>, +c: Nat, r: Reply, ch: Change) -> Reply & Db:
  match ch:
    case CKeep{}:
      (r, Db{t, n, x, now, rr})
    case CDel{}:
      (r, Db{KV.del.at(KV.Val, t, k, h), Nat.sub(n, 1n), cnt.x(c, 0n, x), now, rr})
    case CExp{+e}:
      (r, Db{KV.expire.at(KV.Val, t, k, e, h), n, cnt.x(c, e, x), now, rr})
    case CPut{v, +e}:
      (r, Db{KV.setx.at(KV.Val, t, k, KV.VStr{v}, e, h), cnt.n(c, n), cnt.x(c, e, x), now, rr})
    case CKeepT{v}:
      (r, Db{KV.keep.at(KV.Val, t, k, KV.VStr{v}, h), cnt.n(c, n), x, now, rr})
    case CApp{s, v}:
      (r, Db{KV.keep.at(KV.Val, t, k, KV.VStr{v}, h), cnt.n(c, n), x, now, rr})
    case CRange{o, s, v}:
      (r, Db{KV.keep.at(KV.Val, t, k, KV.VStr{v}, h), cnt.n(c, n), x, now, rr})
    case CHash{op, hv}:
      (r, Db{KV.keep.at(KV.Val, t, k, KV.VColl{KV.CHash{hv}}, h), n, x, now, rr})
    case CHashNew{ps, hv}:
      (r, Db{KV.setx.at(KV.Val, t, k, KV.VColl{KV.CHash{hv}}, 0n, h), cnt.n(c, n), cnt.x(c, 0n, x), now, rr})
    case CList{op, lv}:
      (r, Db{KV.keep.at(KV.Val, t, k, KV.VColl{KV.CList{lv}}, h), n, x, now, rr})
    case CListNew{left, xs, lv}:
      (r, Db{KV.setx.at(KV.Val, t, k, KV.VColl{KV.CList{lv}}, 0n, h), cnt.n(c, n), cnt.x(c, 0n, x), now, rr})
    case CMems{op, sv}:
      (r, Db{KV.keep.at(KV.Val, t, k, KV.VColl{KV.CMems{sv}}, h), n, x, now, rr})
    case CMemsNew{ms, sv}:
      (r, Db{KV.setx.at(KV.Val, t, k, KV.VColl{KV.CMems{sv}}, 0n, h), cnt.n(c, n), cnt.x(c, 0n, x), now, rr})
    case CZset{op, zv}:
      (r, Db{KV.keep.at(KV.Val, t, k, KV.VColl{KV.CZset{zv}}, h), n, x, now, rr})
    case CZsetNew{o, ps, zv}:
      (r, Db{KV.setx.at(KV.Val, t, k, KV.VColl{KV.CZset{zv}}, 0n, h), cnt.n(c, n), cnt.x(c, 0n, x), now, rr})

def upd.put(t: KV.Trie<KV.Val>, +k: String, +h: U32, +n: Nat, +x: Nat, now: Nat, rr: Maybe<&2, Db>, +c: Nat, o: Out) -> Reply & Db:
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
      +m = KV.entry.at(KV.Val, u, k, h)
      upd.put(u, k, h, n, x, now, rr, ent.code(m), upd.v(op, now, ent.live(now, m)))

def db.flush(db: Db) -> Db:
  match db:
    case Db{t, n, x, now, rr}:
      Db{KV.empty(KV.Val), 0n, 0n, now, rr}

# MSETNX: when a key of the pairs is there at now it sets none and
# answers 0, else it sets them all, as MSET does, and answers 1
def pairs.live(+ps: List<&2, KVPair>, +now: Nat, +t: KV.Trie<KV.Val>) -> Bool:
  match ps:
    case Nil{}:
      False{}
    case Con{KP{+k, v}, +rest}:
      Bool.or(Maybe.is_some(&2, KV.Val, KV.read(KV.Val, t, k, now)), pairs.live(rest, now, t))

def msetnx.of(any: Bool, ps: List<&2, KVPair>, db: Db) -> Reply & Db:
  match any:
    case True{}:
      (r_int(0n), db)
    case False{}:
      (r_int(1n), mset_pairs(ps, db))

def db.msetnx(db: Db, ps: List<&2, KVPair>) -> Reply & Db:
  +d = db
  +p = ps
  msetnx.of(pairs.live(p, db.now(d), db.trie(d)), p, d)

# RENAME src dst: src's entry, its value and its time, moves to dst,
# whatever dst held; RENAMENX moves it only when dst is not there, and
# answers 0 when it is. An error when src is not there; when dst is src
# the entry stays where it is (OK, and 0 for RENAMENX, as Redis answers).
# What RENAME finds (Ren) comes first, read from the database it lends.
type Ren is Data:
  RnNone{}
  RnSame{}
  RnHeld{}
  RnMove{v: KV.Val, e: Nat}

def ren.of(m: Maybe<&2, KV.Item<KV.Val>>, same: Bool, held: Bool) -> Ren:
  match m same held:
    case None{} _ _:
      RnNone{}
    case Some{it} True{} _:
      RnSame{}
    case Some{it} False{} True{}:
      RnHeld{}
    case Some{KV.Item{v, e}} False{} False{}:
      RnMove{v, e}

# what RENAME finds: src's entry there at now, whether dst is src, and
# whether RENAMENX finds dst there
def ren.find(+d: Db, +src: String, +dst: String, nx: Bool) -> Ren:
  ren.of(db.ent(d, src), KV.str_eq(src, dst), Bool.and(nx, Maybe.is_some(&2, KV.Item<KV.Val>, db.ent(d, dst))))

def ren.ok(nx: Bool, +n: Nat) -> Reply:
  match nx:
    case True{}:
      r_int(n)
    case False{}:
      r_ok()

# src's entry, v with the time e, moved to dst: dst set and counted as
# SET with PXAT counts it, then src deleted
def db.renamed(db: Db, +src: String, +dst: String, v: KV.Val, +e: Nat) -> Db:
  match db:
    case Db{t, +n, +x, now, rr}:
      +u = t
      +h = KV.hash(dst)
      +c = KV.code.at(KV.Val, u, dst, h)
      Db{KV.del.at(KV.Val, KV.setx.at(KV.Val, u, dst, v, e, h), src, KV.hash(src)), Nat.sub(cnt.n(c, n), 1n), cnt.x(1n+e, 0n, cnt.x(c, e, x)), now, rr}

def ren.do(r: Ren, nx: Bool, +src: String, +dst: String, db: Db) -> Reply & Db:
  match r:
    case RnNone{}:
      (RError{"ERR no such key"}, db)
    case RnSame{}:
      (ren.ok(nx, 0n), db)
    case RnHeld{}:
      (r_int(0n), db)
    case RnMove{v, +e}:
      (ren.ok(nx, 1n), db.renamed(db, src, dst, v, e))

def db.rename(db: Db, +src: String, +dst: String, +nx: Bool) -> Reply & Db:
  +d = db
  ren.do(ren.find(d, src, dst, nx), nx, src, dst, d)

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
      reap.put(Maybe.is_some(&2, KV.Item<KV.Val>, db.ent(d, k)), k, reap.keys(rest, d))

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
  reap.of(KV.reap(KV.Val, db.trie(d), from, want, db.now(d)), d)

def reply_of(r: Reply & Db) -> Reply:
  (x, db) = r
  x

def db_of(r: Reply & Db) -> Db:
  (x, db) = r
  db

# BITOP op dst src...: the bytes of the sources (a key not there reads as
# no bytes) combined byte by byte, AND, OR or XOR, a source shorter than
# another padded with zero bytes, or the one source's bytes complemented
# (NOT). The value is set at dst as SET sets it, its time gone, or dst is
# deleted when the value is empty; the reply is the value's length. A
# source that holds a collection makes it WRONGTYPE, nothing set.
def bitop.byte(+op: BitK, +x: U32, +y: U32) -> U32:
  match op:
    case BAnd{}:
      U32.and(x, y)
    case BOr{}:
      U32.or(x, y)
    case BXor{}:
      U32.xor(x, y)
    case BNot{}:
      U32.and(U32.not(x), 255)

# the bytes of s, each against a zero byte (past the end of the shorter
# value; NOT's complement), onto acc, which holds the bytes before them
# reversed
def bitop.rest(+op: BitK, s: String, acc: String) -> String:
  match s:
    case SNil{}:
      String.reverse(acc)
    case SCon{Chr{+x}, t}:
      bitop.rest(op, t, SCon{Chr{bitop.byte(op, x, 0)}, acc})

def bitop.zip(+op: BitK, a: String, b: String, acc: String) -> String:
  match a:
    case SNil{}:
      bitop.rest(op, b, acc)
    case SCon{Chr{+x}, s}:
      match b:
        case SNil{}:
          bitop.rest(op, SCon{Chr{x}, s}, acc)
        case SCon{Chr{+y}, t}:
          bitop.zip(op, s, t, SCon{Chr{bitop.byte(op, x, y)}, acc})

def bitop.or_empty(m: Maybe<&2, KV.Val>) -> String:
  match m:
    case Some{KV.VStr{v}}:
      v
    case Some{KV.VColl{c}}:
      ""
    case None{}:
      ""

def bitop.src(+t: KV.Trie<KV.Val>, +now: Nat, +k: String) -> String:
  bitop.or_empty(KV.read(KV.Val, t, k, now))

# the value so far, acc, combined with each source after the first
def bitop.fold(+op: BitK, srcs: List<&2, String>, +now: Nat, +t: KV.Trie<KV.Val>, acc: String) -> String:
  match srcs:
    case Nil{}:
      acc
    case Con{+k, rest}:
      bitop.fold(op, rest, now, t, bitop.zip(op, acc, bitop.src(t, now, k), ""))

# the first source as the value starts: complemented for NOT
def bitop.first(+op: BitK, v: String) -> String:
  match op:
    case BNot{}:
      bitop.rest(BNot{}, v, "")
    case BAnd{}:
      v
    case BOr{}:
      v
    case BXor{}:
      v

def bitop.val(+op: BitK, srcs: List<&2, String>, +now: Nat, +t: KV.Trie<KV.Val>) -> String:
  match srcs:
    case Nil{}:
      ""
    case Con{+k, rest}:
      bitop.fold(op, rest, now, t, bitop.first(op, bitop.src(t, now, k)))

def bitop.db(e: Bool, +v: String, +d: String, db: Db) -> Db:
  match e:
    case True{}:
      db_of(db.del(db, [d]))
    case False{}:
      db.set(db, d, v)

# whether a source holds a collection
def is_coll(m: Maybe<&2, KV.Val>) -> Bool:
  match m:
    case Some{KV.VColl{c}}:
      True{}
    case _:
      False{}

def bitop.wrong(srcs: List<&2, String>, +now: Nat, +t: KV.Trie<KV.Val>) -> Bool:
  match srcs:
    case Nil{}:
      False{}
    case Con{+k, rest}:
      Bool.or(is_coll(KV.read(KV.Val, t, k, now)), bitop.wrong(rest, now, t))

def bitop.do(wrong: Bool, +op: BitK, +d: String, srcs: List<&2, String>, db: Db) -> Reply & Db:
  match wrong:
    case True{}:
      (e_wrongtype(), db)
    case False{}:
      +x = db
      +v = bitop.val(op, srcs, db.now(x), db.trie(x))
      (r_int(String.length(v)), bitop.db(String.is_empty(v), v, d, x))

def db.bitop(db: Db, +op: BitK, +d: String, srcs: List<&2, String>) -> Reply & Db:
  +x = db
  +ss = srcs
  bitop.do(bitop.wrong(ss, db.now(x), db.trie(x)), op, d, ss, x)

# LMOVE (and RPOPLPUSH): an element popped from the list at src and
# pushed onto the list at dst, as Redis 7.0.15 does it: src not there
# answers a nil; src or dst of another kind WRONGTYPE, the keys left as
# they were; else the element (src is deleted when it gives its last,
# and keeps its time, as dst does when it holds a list; a new list at
# dst has none). The New forms take dst as not there, whatever it holds,
# and set the new list where its entry lies: the script the file logs
# for them deletes dst before the LMOVE, and Redis runs it so (a script
# that moves nothing, which BendKV never logs, leaves dst as it was
# here).
# What LMOVE finds: no list at src (MvNone), src or dst of another kind
# (MvWrong), or src's list l and its time e, and dst: src itself
# (MvSelf), a list dl (MvOnto), or nothing there at now (MvNew)
type Mv is Data:
  MvNone{}
  MvWrong{}
  MvSelf{l: KV.Deq, e: Nat}
  MvOnto{l: KV.Deq, e: Nat, dl: KV.Deq}
  MvNew{l: KV.Deq, e: Nat}

def mv.dst(+same: Bool, l: KV.Deq, +e: Nat, md: Maybe<&2, KV.Item<KV.Val>>) -> Mv:
  match same md:
    case True{} _:
      MvSelf{l, e}
    case False{} None{}:
      MvNew{l, e}
    case False{} Some{KV.Item{KV.VColl{KV.CList{dl}}, de}}:
      MvOnto{l, e, dl}
    case False{} Some{it}:
      MvWrong{}

def mv.of(ms: Maybe<&2, KV.Item<KV.Val>>, +same: Bool, md: Maybe<&2, KV.Item<KV.Val>>) -> Mv:
  match ms:
    case Some{KV.Item{KV.VColl{KV.CList{l}}, +e}}:
      mv.dst(same, l, e, md)
    case Some{it}:
      MvWrong{}
    case None{}:
      MvNone{}

# dst's entry as the ends see it: none for a New form
def mv.dst.ent(fresh: Bool, m: Maybe<&2, KV.Item<KV.Val>>) -> Maybe<&2, KV.Item<KV.Val>>:
  match fresh:
    case True{}:
      None{}
    case False{}:
      m

def mv.find(+d: Db, +s: String, +t: String, +e: LEnds) -> Mv:
  mv.of(db.ent(d, s), KV.str_eq(s, t), mv.dst.ent(ends.fresh(e), db.ent(d, t)))

# k set to the list l, keeping its time (k holds a list)
def db.keepl(db: Db, +k: String, l: KV.Deq) -> Db:
  match db:
    case Db{t, n, x, now, rr}:
      Db{KV.keep.at(KV.Val, t, k, KV.VColl{KV.CList{l}}, KV.hash(k)), n, x, now, rr}

# k set to the new list l, with no time, counted
def db.newl(db: Db, +k: String, l: KV.Deq) -> Db:
  match db:
    case Db{t, +n, +x, now, rr}:
      +u = t
      +h = KV.hash(k)
      +c = KV.code.at(KV.Val, u, k, h)
      Db{KV.setx.at(KV.Val, u, k, KV.VColl{KV.CList{l}}, 0n, h), cnt.n(c, n), cnt.x(c, 0n, x), now, rr}

# src left with the list l: deleted when l is empty
def mv.src(empty: Bool, +k: String, l: KV.Deq, db: Db) -> Db:
  match empty:
    case True{}:
      db_of(db.del(db, [k]))
    case False{}:
      db.keepl(db, k, l)

def mv.put(+s: String, l: KV.Deq, db: Db) -> Db:
  +m = l
  mv.src(Nat.is_eq(KV.deq.len(m), 0n), s, m, db)

def mv.go(p: KV.Pop, +e: LEnds, +s: String, +t: String, dl: Maybe<&2, KV.Deq>, db: Db) -> Reply & Db:
  match p dl:
    case KV.Pop{+x, l} Some{d}:
      (RBulk{x}, db.keepl(mv.put(s, l, db), t, KV.deq.push(ends.to(e), x, d)))
    case KV.Pop{+x, l} None{}:
      (RBulk{x}, db.newl(mv.put(s, l, db), t, KV.deq.push(ends.to(e), x, KV.deq.empty())))
    case KV.PopNone{} _:
      (RNull{}, db)

def mv.self(p: KV.Pop, +e: LEnds, +s: String, db: Db) -> Reply & Db:
  match p:
    case KV.Pop{+x, l}:
      (RBulk{x}, db.keepl(db, s, KV.deq.push(ends.to(e), x, l)))
    case KV.PopNone{}:
      (RNull{}, db)

def mv.do(m: Mv, +e: LEnds, +s: String, +t: String, db: Db) -> Reply & Db:
  match m:
    case MvNone{}:
      (RNull{}, db)
    case MvWrong{}:
      (e_wrongtype(), db)
    case MvSelf{l, se}:
      mv.self(KV.deq.pop(ends.from(e), l), e, s, db)
    case MvOnto{l, se, dl}:
      mv.go(KV.deq.pop(ends.from(e), l), e, s, t, Some{dl}, db)
    case MvNew{l, se}:
      mv.go(KV.deq.pop(ends.from(e), l), e, s, t, None{}, db)

def db.lmove(db: Db, +s: String, +t: String, +e: LEnds) -> Reply & Db:
  +x = db
  mv.do(mv.find(x, s, t, e), e, s, t, x)

# LMPOP: the first of the keys there at now; none answers a null array,
# one of another kind WRONGTYPE, else up to c elements popped from its
# list (LWPopN), answered with the key
def lmpop.head(+ks: List<&2, String>, +d: Db) -> Bool:
  match ks:
    case Con{+k, +rest}:
      Maybe.is_some(&2, KV.Item<KV.Val>, db.ent(d, k))
    case Nil{}:
      False{}

# there: whether the first of ks is there
def lmpop.first(ks: List<&2, String>, there: Bool, +d: Db) -> Maybe<&2, String>:
  match ks there:
    case Con{k, rest} True{}:
      Some{k}
    case Con{k, +rest} False{}:
      +h = lmpop.head(rest, d)
      lmpop.first(rest, h, d)
    case Nil{} _:
      None{}

def lmpop.reply(+k: String, r: Reply) -> Reply:
  match r:
    case RArray{xs}:
      RArray{[RBulk{k}, RArray{xs}]}
    case _:
      r

def lmpop.out(+k: String, r: Reply & Db) -> Reply & Db:
  (x, d) = r
  (lmpop.reply(k, x), d)

def lmpop.at(m: Maybe<&2, String>, +left: Bool, c: String, db: Db) -> Reply & Db:
  match m:
    case Some{+k}:
      lmpop.out(k, db.upd(db, k, UList{LWPopN{left, c}}))
    case None{}:
      (RNullA{}, db)

def db.lmpop(db: Db, ks: List<&2, String>, +left: Bool, c: String) -> Reply & Db:
  +x = db
  +k = ks
  lmpop.at(lmpop.first(k, lmpop.head(k, x), x), left, c, x)

# Sets of several keys
# --------------------
# SINTER, SUNION, SDIFF, SINTERCARD and their STOREs read the sets at
# their keys there at now, in order: a key not there is an empty set, and
# one that holds another kind makes the command answer WRONGTYPE, as
# Redis answers once it has looked at every key (after a key not there,
# too). SINTER reads the members of its smallest set, in that set's order
# (an intset's increasing), and keeps those every other set holds;
# SUNION adds every set's members in turn to an empty set, and SDIFF the
# first set's members that no other holds, by the way Redis 7.0.15 picks
# for the sizes: both answer the members of the set they made, in its
# order. A STORE sets its destination to the set of the members the
# operation answers, added in turn to an empty set (the write SWNew, with
# no time, whatever the destination held), or deletes it when there are
# none, and answers how many there are.

# the sets at the keys (none for a key not there), or WRONGTYPE
type SGot is Data:
  SGot{ss: List<&2, Maybe<&2, KV.Mems>>}
  SGotWrong{}

def sget.one(m: Maybe<&2, KV.Val>, rest: SGot) -> SGot:
  match m rest:
    case _ SGotWrong{}:
      SGotWrong{}
    case None{} SGot{ss}:
      SGot{None{} <> ss}
    case Some{KV.VColl{KV.CMems{s}}} SGot{ss}:
      SGot{Some{s} <> ss}
    case Some{v} SGot{ss}:
      SGotWrong{}

def sets.at(ks: List<&2, String>, +now: Nat, +t: KV.Trie<KV.Val>) -> SGot:
  match ks:
    case Nil{}:
      SGot{Nil{}}
    case Con{+k, rest}:
      sget.one(KV.read(KV.Val, t, k, now), sets.at(rest, now, t))

# the sets, when every key holds one
def sets.all.cons(m: Maybe<&2, KV.Mems>, rest: Maybe<&2, List<&2, KV.Mems>>) -> Maybe<&2, List<&2, KV.Mems>>:
  match m rest:
    case Some{s} Some{xs}:
      Some{s <> xs}
    case _ _:
      None{}

def sets.all(ss: List<&2, Maybe<&2, KV.Mems>>) -> Maybe<&2, List<&2, KV.Mems>>:
  match ss:
    case Nil{}:
      Some{Nil{}}
    case Con{m, rest}:
      sets.all.cons(m, sets.all(rest))

# the sets of the keys that hold one, in order
def sets.some(ss: List<&2, Maybe<&2, KV.Mems>>) -> List<&2, KV.Mems>:
  match ss:
    case Nil{}:
      Nil{}
    case Con{Some{s}, rest}:
      s <> sets.some(rest)
    case Con{None{}, rest}:
      sets.some(rest)

# the sets from the smallest to the largest: s goes before the first set
# of ss that is larger (before: whether that is ss's first, computed
# before ss is passed on)
def sets.lt(+s: KV.Mems, +ss: List<&2, KV.Mems>) -> Bool:
  match ss:
    case Con{+x, rest}:
      Nat.is_lt(KV.mems.len(s), KV.mems.len(x))
    case Nil{}:
      True{}

def sets.ins(+s: KV.Mems, ss: List<&2, KV.Mems>, before: Bool) -> List<&2, KV.Mems>:
  match ss before:
    case Nil{} _:
      [s]
    case Con{x, rest} True{}:
      s <> Con{x, rest}
    case Con{x, +rest} False{}:
      b = sets.lt(s, rest)
      Con{x, sets.ins(s, rest, b)}

def sets.sort(ss: List<&2, KV.Mems>, acc: List<&2, KV.Mems>) -> List<&2, KV.Mems>:
  match ss:
    case Nil{}:
      acc
    case Con{+s, rest}:
      +a = acc
      sets.sort(rest, sets.ins(s, a, sets.lt(s, a)))

# whether each set of ss holds x (ok: so far)
def sets.has_all.go(ss: List<&2, KV.Mems>, ok: Bool, +x: String) -> Bool:
  match ss ok:
    case _ False{}:
      False{}
    case Nil{} True{}:
      True{}
    case Con{+s, rest} True{}:
      sets.has_all.go(rest, KV.mems.has(x, s), x)

def sets.has_all(+x: String, ss: List<&2, KV.Mems>) -> Bool:
  sets.has_all.go(ss, True{}, x)

# whether a set of ss holds x (none: so far)
def sets.has_any.go(ss: List<&2, KV.Mems>, none: Bool, +x: String) -> Bool:
  match ss none:
    case _ False{}:
      True{}
    case Nil{} True{}:
      False{}
    case Con{+s, rest} True{}:
      sets.has_any.go(rest, Bool.not(KV.mems.has(x, s)), x)

def sets.has_any(+x: String, ss: List<&2, KV.Mems>) -> Bool:
  sets.has_any.go(ss, True{}, x)

def sets.if(ok: Bool, x: String, rest: List<&2, String>) -> List<&2, String>:
  match ok:
    case True{}:
      x <> rest
    case False{}:
      rest

# the members of xs that each set of ss holds, in order
def sinter.keep(xs: List<&2, String>, +ss: List<&2, KV.Mems>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{+x, rest}:
      sets.if(sets.has_all(x, ss), x, sinter.keep(rest, ss))

# the members of xs that no set of ss holds, in order
def sinter.none(xs: List<&2, String>, +ss: List<&2, KV.Mems>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{+x, rest}:
      sets.if(Bool.not(sets.has_any(x, ss)), x, sinter.none(rest, ss))

def sinter.sorted(ss: List<&2, KV.Mems>) -> List<&2, String>:
  match ss:
    case Con{+s, rest}:
      sinter.keep(KV.mems.all(s), rest)
    case Nil{}:
      Nil{}

# SINTER's members: none when a key is not there
def sinter.of(m: Maybe<&2, List<&2, KV.Mems>>) -> List<&2, String>:
  match m:
    case Some{ss}:
      sinter.sorted(sets.sort(ss, Nil{}))
    case None{}:
      Nil{}

# how many members of xs each set of ss holds, counted from c up to
# limit (0: all of them); done once c reaches it
def sicard.go(xs: List<&2, String>, done: Bool, +ss: List<&2, KV.Mems>, +limit: Nat, +c: Nat) -> Nat:
  match xs done:
    case _ True{}:
      c
    case Nil{} False{}:
      c
    case Con{+x, rest} False{}:
      +d = Bool.pick(Nat, sets.has_all(x, ss), 1n+c, c)
      sicard.go(rest, Bool.and(Nat.is_lt(0n, limit), Nat.is_le(limit, d)), ss, limit, d)

def sicard.sorted(+limit: Nat, ss: List<&2, KV.Mems>) -> Nat:
  match ss:
    case Con{+s, rest}:
      sicard.go(KV.mems.all(s), False{}, rest, limit, 0n)
    case Nil{}:
      0n

def sicard.of(+limit: Nat, m: Maybe<&2, List<&2, KV.Mems>>) -> Nat:
  match m:
    case Some{ss}:
      sicard.sorted(limit, sets.sort(ss, Nil{}))
    case None{}:
      0n

# SUNION's set: every set's members added in turn to an empty set
def sunion.of(ss: List<&2, KV.Mems>, acc: KV.Mems) -> KV.Mems:
  match ss:
    case Nil{}:
      acc
    case Con{+s, rest}:
      sunion.of(rest, KV.mems.adds(KV.mems.all(s), acc))

# whether k is one of ks
def keys.has(+k: String, ks: List<&2, String>) -> Bool:
  match ks:
    case Nil{}:
      False{}
    case Con{+j, rest}:
      Bool.or(String.eq(k, j), keys.has(k, rest))

# the members xs of a set taken out of s, those it holds
def sdiff.one(had: Bool, s: KV.Mems, +x: String) -> KV.Mems:
  match had:
    case True{}:
      KV.mems.del(s, x)
    case False{}:
      s

def sdiff.drop(xs: List<&2, String>, s: KV.Mems) -> KV.Mems:
  match xs:
    case Nil{}:
      s
    case Con{+x, rest}:
      +t = s
      sdiff.drop(rest, sdiff.one(KV.mems.has(x, t), t, x))

def sdiff.drops(ss: List<&2, KV.Mems>, s: KV.Mems) -> KV.Mems:
  match ss:
    case Nil{}:
      s
    case Con{+x, rest}:
      sdiff.drops(rest, sdiff.drop(KV.mems.all(x), s))

def sets.sizes(ss: List<&2, KV.Mems>) -> Nat:
  match ss:
    case Nil{}:
      0n
    case Con{+x, rest}:
      Nat.add(KV.mems.len(x), sets.sizes(rest))

# SDIFF's set, the first set s0 and the other sets there, os: by Redis's
# first way (s0's members that no other set holds, added to an empty
# set) when its work, half of s0's size for each set, is at most the
# second's (s0's members added to an empty set, then the others' taken
# out), the sum of their sizes
def sdiff.way(one: Bool, +s0: KV.Mems, +os: List<&2, KV.Mems>) -> KV.Mems:
  match one:
    case True{}:
      KV.mems.of(sinter.none(KV.mems.all(s0), os))
    case False{}:
      sdiff.drops(os, KV.mems.of(KV.mems.all(s0)))

def sdiff.go(same: Bool, +s0: KV.Mems, +os: List<&2, KV.Mems>) -> KV.Mems:
  match same:
    case True{}:
      KV.mems.empty()
    case False{}:
      +n0 = KV.mems.len(s0)
      sdiff.way(Nat.is_le(Nat.div(Nat.mul(n0, 1n+List.length(&2, KV.Mems, os)), 2n), Nat.add(n0, sets.sizes(os))), s0, os)

# SDIFF's set: none when the first key is not there, and none when it
# comes again among the others (the same set taken from itself)
def sdiff.of(ks: List<&2, String>, ss: List<&2, Maybe<&2, KV.Mems>>) -> KV.Mems:
  match ks ss:
    case Con{+k, rest} Con{Some{s0}, os}:
      sdiff.go(keys.has(k, rest), s0, sets.some(os))
    case _ _:
      KV.mems.empty()

# the members a set operation answers
def sop.members(op: SetK, ks: List<&2, String>, ss: List<&2, Maybe<&2, KV.Mems>>) -> List<&2, String>:
  match op:
    case KInter{}:
      sinter.of(sets.all(ss))
    case KCard{l}:
      sinter.of(sets.all(ss))
    case KUnion{}:
      KV.mems.all(sunion.of(sets.some(ss), KV.mems.empty()))
    case KDiff{}:
      KV.mems.all(sdiff.of(ks, ss))

def sop.of(op: SetK, ks: List<&2, String>, ss: List<&2, Maybe<&2, KV.Mems>>) -> Reply:
  match op:
    case KCard{+limit}:
      r_int(sicard.of(limit, sets.all(ss)))
    case KInter{}:
      RArray{lbulks(sop.members(KInter{}, ks, ss))}
    case KUnion{}:
      RArray{lbulks(sop.members(KUnion{}, ks, ss))}
    case KDiff{}:
      RArray{lbulks(sop.members(KDiff{}, ks, ss))}

def sop.reply(op: SetK, ks: List<&2, String>, g: SGot) -> Reply:
  match g:
    case SGot{ss}:
      sop.of(op, ks, ss)
    case SGotWrong{}:
      e_wrongtype()

def sstore.put(+ms: List<&2, String>, +d: String, db: Db) -> Reply & Db:
  (r_int(List.length(&2, String, ms)), db_of(db.upd(db, d, UMems{SWNew{ms}})))

def sstore.of(xs: List<&2, String>, +d: String, db: Db) -> Reply & Db:
  match xs:
    case Nil{}:
      (r_int(0n), db_of(db.del(db, [d])))
    case Con{x, rest}:
      sstore.put(x <> rest, d, db)

def sstore.do(g: SGot, op: SetK, ks: List<&2, String>, +d: String, db: Db) -> Reply & Db:
  match g:
    case SGot{ss}:
      sstore.of(sop.members(op, ks, ss), d, db)
    case SGotWrong{}:
      (e_wrongtype(), db)

def db.sstore(db: Db, op: SetK, +d: String, ks: List<&2, String>) -> Reply & Db:
  +x = db
  +k = ks
  sstore.do(sets.at(k, db.now(x), db.trie(x)), op, k, d, x)

# SMOVE src dst m, as Redis 7.0.15 does it: src not there answers 0,
# whatever dst holds; src or dst of another kind WRONGTYPE; src the same
# key as dst answers whether it holds m; m not in src 0; else 1: m taken
# out of src (deleted when it gives its last member) and added to dst (a
# new set there when dst is not there at now), by the writes SREM and
# SADD make (db.upd). The New form adds m to a new set at dst, whatever
# dst holds (the script the file logs for it deletes dst first).
# What SMOVE finds: 0, WRONGTYPE, src the same key as dst (had: it holds
# m), or a move
type Smv is Data:
  SmvZero{}
  SmvWrong{}
  SmvSame{had: Bool}
  SmvGo{}

def smv.dst(same: Bool, +had: Bool, md: Maybe<&2, KV.Item<KV.Val>>) -> Smv:
  match same md:
    case True{} _:
      SmvSame{had}
    case False{} None{}:
      Bool.pick(Smv, had, SmvGo{}, SmvZero{})
    case False{} Some{KV.Item{KV.VColl{KV.CMems{d}}, e}}:
      Bool.pick(Smv, had, SmvGo{}, SmvZero{})
    case False{} Some{it}:
      SmvWrong{}

# from the entries of src and dst there at now (dst none for a New form)
def smv.find(ms: Maybe<&2, KV.Item<KV.Val>>, md: Maybe<&2, KV.Item<KV.Val>>, same: Bool, +m: String) -> Smv:
  match ms:
    case None{}:
      SmvZero{}
    case Some{KV.Item{KV.VColl{KV.CMems{+s}}, e}}:
      smv.dst(same, KV.mems.has(m, s), md)
    case Some{it}:
      SmvWrong{}

def smv.member(+w: SMem) -> String:
  match w:
    case SMem{+m}:
      m
    case SMemNew{+m}:
      m

def smv.fresh(+w: SMem) -> Bool:
  match w:
    case SMem{m}:
      False{}
    case SMemNew{m}:
      True{}

# the write of dst: SADD of m, or a new set of m
def smv.add(+w: SMem) -> SWrite:
  match w:
    case SMem{+m}:
      SWAdd{[m]}
    case SMemNew{+m}:
      SWNew{[m]}

def smove.do(f: Smv, +s: String, +d: String, +w: SMem, db: Db) -> Reply & Db:
  match f:
    case SmvZero{}:
      (r_int(0n), db)
    case SmvWrong{}:
      (e_wrongtype(), db)
    case SmvSame{had}:
      (r_int(Bool.pick(Nat, had, 1n, 0n)), db)
    case SmvGo{}:
      (r_int(1n), db_of(db.upd(db_of(db.upd(db, s, UMems{SWRem{[smv.member(w)]}})), d, UMems{smv.add(w)})))

# what SMOVE finds in the database x
def smv.of(+x: Db, +s: String, +d: String, +w: SMem) -> Smv:
  smv.find(db.ent(x, s), mv.dst.ent(smv.fresh(w), db.ent(x, d)), KV.str_eq(s, d), smv.member(w))

def db.smove(db: Db, +s: String, +d: String, +w: SMem) -> Reply & Db:
  +x = db
  smove.do(smv.of(x, s, d, w), s, d, w, x)

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
# Sorted sets of several keys
# ---------------------------
# ZUNION, ZINTER, ZDIFF, ZINTERCARD and their STOREs, as Redis 7.0.15
# runs them (zunionInterDiffGenericCommand): each key holds a sorted set
# or a set (a set's members of score 1), or is not there (none: an empty
# one), else WRONGTYPE; then the options' error, if they made one. A
# score of an input is its score times the key's weight (a NaN, as inf
# times 0, is 0), and a member of several inputs aggregates their
# scores, in their order: their sum (a NaN is 0, as for inf and -inf),
# the least or the greatest. ZUNION and ZINTER take the inputs from the
# smallest to the largest (stably, as glibc's qsort sorts so few):
# ZUNION every member of each, ZINTER the members of the smallest that
# all the others hold, each other input's score times its weight (not
# made 0 when a NaN: aggregated, a sum made a NaN is 0, and MIN and MAX
# keep the score they had). ZDIFF takes the members of the first input
# that no other holds, with their scores. ZINTERCARD counts ZINTER's
# members, up to its LIMIT. The members answer in order of score, then
# of member, as a sorted set holds them. A STORE sets its destination to
# the sorted set of the members, with no time, whatever it held (ZWNew:
# the ZADD of each score, as Redis writes a double, and member), or
# deletes it when there are none, and answers how many there are.

# a source: a sorted set, a set, or none
type ZSrc is Data:
  ZSrcZ{z: KV.Zset}
  ZSrcS{s: KV.Mems}
  ZSrcNone{}

# the sources at the keys, or WRONGTYPE
type ZGot is Data:
  ZGot{ss: List<&2, ZSrc>}
  ZGotWrong{}

def zget.one(m: Maybe<&2, KV.Val>, rest: ZGot) -> ZGot:
  match m rest:
    case _ ZGotWrong{}:
      ZGotWrong{}
    case None{} ZGot{ss}:
      ZGot{ZSrcNone{} <> ss}
    case Some{KV.VColl{KV.CZset{z}}} ZGot{ss}:
      ZGot{ZSrcZ{z} <> ss}
    case Some{KV.VColl{KV.CMems{s}}} ZGot{ss}:
      ZGot{ZSrcS{s} <> ss}
    case Some{v} ZGot{ss}:
      ZGotWrong{}

def zsrcs.at(ks: List<&2, String>, +now: Nat, +t: KV.Trie<KV.Val>) -> ZGot:
  match ks:
    case Nil{}:
      ZGot{Nil{}}
    case Con{+k, rest}:
      zget.one(KV.read(KV.Val, t, k, now), zsrcs.at(rest, now, t))

def zsrc.len(+s: ZSrc) -> Nat:
  match s:
    case ZSrcZ{+z}:
      KV.zset.len(z)
    case ZSrcS{+m}:
      KV.mems.len(m)
    case ZSrcNone{}:
      0n

# the score 1
def zone() -> F.F64:
  F.F64{1072693248n, 0n}

# a member's score in a source (1 in a set)
def zsrc.score(+m: String, +s: ZSrc) -> Maybe<&2, F.F64>:
  match s:
    case ZSrcZ{+z}:
      KV.zset.score(m, z)
    case ZSrcS{+ms}:
      Bool.pick(Maybe<&2, F.F64>, KV.mems.has(m, ms), Some{zone()}, None{})
    case ZSrcNone{}:
      None{}

def zsrc.ones(xs: List<&2, String>) -> List<&2, KV.ZEl>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{x, rest}:
      KV.ZEl{x, zone()} <> zsrc.ones(rest)

# a source's elements, in its order
def zsrc.els(+s: ZSrc) -> List<&2, KV.ZEl>:
  match s:
    case ZSrcZ{+z}:
      KV.zt.all(KV.zset.tree(z))
    case ZSrcS{+ms}:
      zsrc.ones(KV.mems.all(ms))
    case ZSrcNone{}:
      Nil{}

# an input: a source and its weight
type ZIn is Data:
  ZIn{s: ZSrc, w: F.F64}

def zins.of(ss: List<&2, ZSrc>, ws: List<&2, F.F64>) -> List<&2, ZIn>:
  match ss ws:
    case Con{s, rest} Con{w, more}:
      ZIn{s, w} <> zins.of(rest, more)
    case Con{s, rest} Nil{}:
      ZIn{s, zone()} <> zins.of(rest, Nil{})
    case Nil{} _:
      Nil{}

def zin.len(+x: ZIn) -> Nat:
  match x:
    case ZIn{+s, w}:
      zsrc.len(s)

# whether the first input of xs is larger than x
def zins.gt(+xs: List<&2, ZIn>, +x: ZIn) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Con{+y, r}:
      Nat.is_lt(zin.len(x), zin.len(y))

# xs (from the smallest) with x after the inputs of its size
def zins.ins(xs: List<&2, ZIn>, before: Bool, +x: ZIn) -> List<&2, ZIn>:
  match xs before:
    case Nil{} _:
      [x]
    case ys True{}:
      x <> ys
    case Con{y, +rest} False{}:
      y <> zins.ins(rest, zins.gt(rest, x), x)

def zins.sort(xs: List<&2, ZIn>, +acc: List<&2, ZIn>) -> List<&2, ZIn>:
  match xs:
    case Nil{}:
      acc
    case Con{+x, rest}:
      zins.sort(rest, zins.ins(acc, zins.gt(acc, x), x))

# a score times a weight (a weight of 1 changes no score: none is a NaN)
def zmul.of(one: Bool, +w: F.F64, +d: F.F64) -> F.F64:
  match one:
    case True{}:
      d
    case False{}:
      F.f64.of(F.fl.mul(F.fmt.d(), F.f64.to(w), F.f64.to(d)))

def zmul(+w: F.F64, +d: F.F64) -> F.F64:
  zmul.of(F.f64.same(w, zone()), w, d)

# 0 for a NaN
def znan0(+d: F.F64) -> F.F64:
  Bool.pick(F.F64, F.f64.is_nan(d), F.F64{0n, 0n}, d)

# a score aggregated with the one a member had (agg 0 SUM, 1 MIN, 2 MAX)
def zagg.do(+agg: Nat, +t: F.F64, +v: F.F64) -> F.F64:
  match agg:
    case 1n:
      Bool.pick(F.F64, Bool.and(Bool.not(F.f64.is_nan(v)), Cmp.is_lt(F.f64.cmp(v, t))), v, t)
    case 2n:
      Bool.pick(F.F64, Bool.and(Bool.not(F.f64.is_nan(v)), Cmp.is_gt(F.f64.cmp(v, t))), v, t)
    case _:
      znan0(F.f64.of(F.fl.add(F.fmt.d(), F.f64.to(t), F.f64.to(v))))

# the members and their scores as a sorted set orders them
def zres.put(xs: List<&2, KV.ZEl>, +t: KV.ZTree) -> KV.ZTree:
  match xs:
    case Nil{}:
      t
    case Con{KV.ZEl{+m, +d}, rest}:
      zres.put(rest, KV.zt.add(t, m, d))

def zres(xs: List<&2, KV.ZEl>) -> List<&2, KV.ZEl>:
  KV.zt.all(zres.put(xs, KV.ZTip{}))

# ZUNION: the scores of every input's members, in a trie
def zunion.put(cur: Maybe<&2, F.F64>, +agg: Nat, +m: String, +sc: F.F64, acc: KV.Trie<F.F64>) -> KV.Trie<F.F64>:
  match cur:
    case Some{+c}:
      KV.set(F.F64, acc, m, zagg.do(agg, c, sc))
    case None{}:
      KV.set(F.F64, acc, m, sc)

def zunion.els(xs: List<&2, KV.ZEl>, +w: F.F64, +agg: Nat, acc: KV.Trie<F.F64>) -> KV.Trie<F.F64>:
  match xs:
    case Nil{}:
      acc
    case Con{KV.ZEl{+m, +d}, rest}:
      +a = acc
      zunion.els(rest, w, agg, zunion.put(KV.get(F.F64, a, m), agg, m, znan0(zmul(w, d)), a))

def zunion.go(ins: List<&2, ZIn>, +agg: Nat, acc: KV.Trie<F.F64>) -> KV.Trie<F.F64>:
  match ins:
    case Nil{}:
      acc
    case Con{ZIn{+s, +w}, rest}:
      zunion.go(rest, agg, zunion.els(zsrc.els(s), w, agg, acc))

def zunion.kv(+t: KV.Trie<F.F64>, ks: List<&2, String>) -> List<&2, KV.ZEl>:
  match ks:
    case Nil{}:
      Nil{}
    case Con{+k, rest}:
      KV.ZEl{k, zadd.num(KV.get(F.F64, t, k))} <> zunion.kv(t, rest)

def zunion(ins: List<&2, ZIn>, +agg: Nat) -> List<&2, KV.ZEl>:
  +t = zunion.go(ins, agg, KV.empty(F.F64))
  zres(zunion.kv(t, KV.keys(F.F64, t, 0n)))

def zinter.with(v: Maybe<&2, F.F64>, +agg: Nat, +w: F.F64, +c: F.F64) -> Maybe<&2, F.F64>:
  match v:
    case Some{+x}:
      Some{zagg.do(agg, c, zmul(w, x))}
    case None{}:
      None{}

# ZINTER: a member's score through the other inputs, none when one of
# them does not hold it
def zinter.through(ins: List<&2, ZIn>, +agg: Nat, +m: String, sc: Maybe<&2, F.F64>) -> Maybe<&2, F.F64>:
  match ins sc:
    case _ None{}:
      None{}
    case Nil{} s:
      s
    case Con{ZIn{+s, +w}, rest} Some{+c}:
      zinter.through(rest, agg, m, zinter.with(zsrc.score(m, s), agg, w, c))

def zinter.keep(m: Maybe<&2, F.F64>, k: String, rest: List<&2, KV.ZEl>) -> List<&2, KV.ZEl>:
  match m:
    case Some{d}:
      KV.ZEl{k, d} <> rest
    case None{}:
      rest

def zinter.els(xs: List<&2, KV.ZEl>, +w: F.F64, +others: List<&2, ZIn>, +agg: Nat) -> List<&2, KV.ZEl>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{KV.ZEl{+m, +d}, rest}:
      zinter.keep(zinter.through(others, agg, m, Some{znan0(zmul(w, d))}), m, zinter.els(rest, w, others, agg))

def zinter.go(ins: List<&2, ZIn>, +agg: Nat) -> List<&2, KV.ZEl>:
  match ins:
    case Nil{}:
      Nil{}
    case Con{ZIn{+s, +w}, +rest}:
      zinter.els(zsrc.els(s), w, rest, agg)

def zinter(ins: List<&2, ZIn>, +agg: Nat) -> List<&2, KV.ZEl>:
  zres(zinter.go(ins, agg))

# ZINTERCARD: how many members ZINTER answers, counted up to lim (0: all)
def zcard.els(xs: List<&2, KV.ZEl>, stop: Bool, +others: List<&2, ZIn>, +lim: Nat, +n: Nat) -> Nat:
  match xs stop:
    case _ True{}:
      n
    case Nil{} _:
      n
    case Con{KV.ZEl{+m, d}, rest} False{}:
      +n2 = Bool.pick(Nat, Maybe.is_some(&2, F.F64, zinter.through(others, 0n, m, Some{zone()})), Nat.add(n, 1n), n)
      zcard.els(rest, Bool.and(Nat.is_lt(0n, lim), Nat.is_le(lim, n2)), others, lim, n2)

def zcard.go(ins: List<&2, ZIn>, +lim: Nat) -> Nat:
  match ins:
    case Nil{}:
      0n
    case Con{ZIn{+s, w}, +rest}:
      zcard.els(zsrc.els(s), False{}, rest, lim, 0n)

# ZDIFF: the members of the first input no other holds
def zdiff.any(ins: List<&2, ZIn>, +m: String) -> Bool:
  match ins:
    case Nil{}:
      False{}
    case Con{ZIn{+s, w}, rest}:
      Bool.or(Maybe.is_some(&2, F.F64, zsrc.score(m, s)), zdiff.any(rest, m))

def zdiff.els(xs: List<&2, KV.ZEl>, +others: List<&2, ZIn>) -> List<&2, KV.ZEl>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{KV.ZEl{+m, +d}, rest}:
      zinter.keep(Bool.pick(Maybe<&2, F.F64>, zdiff.any(others, m), None{}, Some{d}), m, zdiff.els(rest, others))

def zdiff(ins: List<&2, ZIn>) -> List<&2, KV.ZEl>:
  match ins:
    case Nil{}:
      Nil{}
    case Con{ZIn{+s, w}, +rest}:
      zres(zdiff.els(zsrc.els(s), rest))

# the options' WEIGHTS (none given: none), AGGREGATE, LIMIT, whether
# they answer the scores, and their error, if they made one
def zagg.ws(o: ZAgg) -> List<&2, F.F64>:
  match o:
    case ZAgg{ws, agg, lim}:
      ws
    case ZAggScores{o}:
      zagg.ws(o)
    case ZAggBad{r}:
      Nil{}

def zagg.agg(o: ZAgg) -> Nat:
  match o:
    case ZAgg{ws, agg, lim}:
      agg
    case ZAggScores{o}:
      zagg.agg(o)
    case ZAggBad{r}:
      0n

def zagg.lim(o: ZAgg) -> Nat:
  match o:
    case ZAgg{ws, agg, lim}:
      lim
    case ZAggScores{o}:
      zagg.lim(o)
    case ZAggBad{r}:
      0n

def zagg.sc(o: ZAgg) -> Bool:
  match o:
    case ZAggScores{o}:
      True{}
    case _:
      False{}

def zagg.bad(o: ZAgg) -> Maybe<&2, Reply>:
  match o:
    case ZAggBad{r}:
      Some{r}
    case _:
      None{}

# the members an operation makes of the sources, with its options
def zop.els(op: ZSetK, ss: List<&2, ZSrc>) -> List<&2, KV.ZEl>:
  match op:
    case ZKUnion{+o}:
      zunion(zins.sort(zins.of(ss, zagg.ws(o)), Nil{}), zagg.agg(o))
    case ZKInter{+o}:
      zinter(zins.sort(zins.of(ss, zagg.ws(o)), Nil{}), zagg.agg(o))
    case ZKDiff{o}:
      zdiff(zins.of(ss, Nil{}))
    case ZKCard{o}:
      Nil{}

# the options' error, if they made one
def zop.bad(+op: ZSetK) -> Maybe<&2, Reply>:
  match op:
    case ZKUnion{o}:
      zagg.bad(o)
    case ZKInter{o}:
      zagg.bad(o)
    case ZKDiff{o}:
      zagg.bad(o)
    case ZKCard{o}:
      zagg.bad(o)

# whether an operation answers the scores (WITHSCORES)
def zop.sc(+op: ZSetK) -> Bool:
  match op:
    case ZKUnion{o}:
      zagg.sc(o)
    case ZKInter{o}:
      zagg.sc(o)
    case ZKDiff{o}:
      zagg.sc(o)
    case ZKCard{o}:
      False{}

# ZINTERCARD's LIMIT (none for another operation)
def zop.lim(+op: ZSetK) -> Maybe<&2, Nat>:
  match op:
    case ZKCard{o}:
      Some{zagg.lim(o)}
    case _:
      None{}

def zop.ok(lim: Maybe<&2, Nat>, +op: ZSetK, ss: List<&2, ZSrc>) -> Reply:
  match lim:
    case Some{+l}:
      r_int(zcard.go(zins.sort(zins.of(ss, Nil{}), Nil{}), l))
    case None{}:
      RArray{zels(zop.els(op, ss), zop.sc(op))}

def zop.of(bad: Maybe<&2, Reply>, +op: ZSetK, ss: List<&2, ZSrc>) -> Reply:
  match bad:
    case Some{r}:
      r
    case None{}:
      zop.ok(zop.lim(op), op, ss)

def zop.reply(+op: ZSetK, g: ZGot) -> Reply:
  match g:
    case ZGot{ss}:
      zop.of(zop.bad(op), op, ss)
    case ZGotWrong{}:
      e_wrongtype()

# the pairs of a STORE's ZADD: each score as Redis writes a double, and
# its member
def zstore.pairs(xs: List<&2, KV.ZEl>) -> List<&2, ZPair>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{KV.ZEl{m, +d}, rest}:
      ZPair{F.f64.show(d), m} <> zstore.pairs(rest)

def zstore.put(+n: Nat, ps: List<&2, ZPair>, +d: String, db: Db) -> Reply & Db:
  (r_int(n), db_of(db.upd(db, d, UZset{ZWNew{zopts.none(), ps}})))

def zstore.of(+xs: List<&2, KV.ZEl>, +d: String, db: Db) -> Reply & Db:
  match xs:
    case Nil{}:
      (r_int(0n), db_of(db.del(db, [d])))
    case Con{x, rest}:
      zstore.put(List.length(&2, KV.ZEl, xs), zstore.pairs(xs), d, db)

def zstore.ok(bad: Maybe<&2, Reply>, +op: ZSetK, ss: List<&2, ZSrc>, +d: String, db: Db) -> Reply & Db:
  match bad:
    case Some{r}:
      (r, db)
    case None{}:
      zstore.of(zop.els(op, ss), d, db)

def zstore.do(g: ZGot, +op: ZSetK, +d: String, db: Db) -> Reply & Db:
  match g:
    case ZGot{ss}:
      zstore.ok(zop.bad(op), op, ss, d, db)
    case ZGotWrong{}:
      (e_wrongtype(), db)

def db.zstore(db: Db, +op: ZSetK, +d: String, ks: List<&2, String>) -> Reply & Db:
  +x = db
  zstore.do(zsrcs.at(ks, db.now(x), db.trie(x)), op, d, x)

# ZRANGESTORE: the range of the sorted set at src, in the order ZRANGE
# answers it, set at dst as a STORE sets it (a src not there: none);
# WRONGTYPE for a src of another kind
def zrs.of(m: Maybe<&2, KV.Val>, q: ZQ, +d: String, db: Db) -> Reply & Db:
  match m:
    case None{}:
      zstore.of(Nil{}, d, db)
    case Some{KV.VColl{KV.CZset{+z}}}:
      zstore.of(zq.run(q, z), d, db)
    case Some{v}:
      (e_wrongtype(), db)

def db.zrangestore(db: Db, +d: String, +s: String, q: ZQ) -> Reply & Db:
  +x = db
  zrs.of(KV.read(KV.Val, db.trie(x), s, db.now(x)), q, d, x)

# ZMPOP: as LMPOP, from the first of the keys there at now: its elements
# popped (ZWPopN), answered with the key, each element as a pair of its
# member and its score
def zmpop.pairs(xs: List<&2, Reply>) -> List<&2, Reply>:
  match xs:
    case Con{m, Con{s, rest}}:
      RArray{[m, s]} <> zmpop.pairs(rest)
    case _:
      Nil{}

def zmpop.reply(+k: String, r: Reply) -> Reply:
  match r:
    case RArray{xs}:
      RArray{[RBulk{k}, RArray{zmpop.pairs(xs)}]}
    case _:
      r

def zmpop.out(+k: String, r: Reply & Db) -> Reply & Db:
  (x, d) = r
  (zmpop.reply(k, x), d)

def zmpop.at(m: Maybe<&2, String>, +max: Bool, c: String, db: Db) -> Reply & Db:
  match m:
    case Some{+k}:
      zmpop.out(k, db.upd(db, k, UZset{ZWPopN{max, c}}))
    case None{}:
      (RNullA{}, db)

def db.zmpop(db: Db, ks: List<&2, String>, +max: Bool, c: String) -> Reply & Db:
  +x = db
  +k = ks
  zmpop.at(lmpop.first(k, lmpop.head(k, x), x), max, c, x)

def exec(cmd: Cmd, db: Db) -> Reply & Db:
  match cmd:
    case Ping{}:
      (RStatus{"PONG"}, db)
    case Echo{m}:
      (RBulk{m}, db)
    case Get{+k}:
      +d = db
      (r_getv(db.get_copy(d, k)), d)
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
    case FlushDb{}:
      (r_ok(), db.flush(db))
    case Keys{p}:
      +d = db
      (RArray{glob_filter(p, KV.keys(KV.Val, db.trie(d), db.now(d)))}, d)
    case Scan{args}:
      +d = db
      (scan.reply(scan.args(args), db.trie(d), db.now(d)), d)
    case Peek{+k, c}:
      +d = db
      (peek.v(c, db.now(d), db.ent(d, k)), d)
    case Upd{+k, op}:
      db.upd(db, k, op)
    case MSetNx{ps}:
      db.msetnx(db, ps)
    case Rename{+src, +dst, +nx}:
      db.rename(db, src, dst, nx)
    case BitOp{+op, +d, srcs}:
      db.bitop(db, op, d, srcs)
    case Own{o}:
      (RError{"ERR a command of the connection, not of the database"}, db)
    case Bad{r}:
      (r, db)
    case LMove{+s, +t, +e}:
      db.lmove(db, s, t, e)
    case LMPop{ks, +left, c}:
      db.lmpop(db, ks, left, c)
    case SOp{op, +ks}:
      +d = db
      (sop.reply(op, ks, sets.at(ks, db.now(d), db.trie(d))), d)
    case SStore{op, +d, ks}:
      db.sstore(db, op, d, ks)
    case SMv{+s, +d, +w}:
      db.smove(db, s, d, w)
    case ZOp{+op, +ks}:
      +d = db
      (zop.reply(op, zsrcs.at(ks, db.now(d), db.trie(d))), d)
    case ZStore{+op, +d, ks}:
      db.zstore(db, op, d, ks)
    case ZRangeStore{+d, +s, q}:
      db.zrangestore(db, d, s, q)
    case ZMPop{ks, +max, c}:
      db.zmpop(db, ks, max, c)

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

# Databases
# ---------
# The server holds several databases (databases: 16, as in Redis), by
# number from 0, and a connection works on the one it selected (SELECT;
# 0 at first). Ds holds them with one in focus: the focused database (d),
# those before it, nearest first (pre), and those after it (post). A
# command of one database runs on the focus as on a lone database, and
# the server moves the focus to a connection's database before it runs
# the connection's batch. A batch runs at the focus's time (its now): the
# others keep the time they last ran at, and the focus takes its time
# along when it moves.
type Ds is Data:
  Ds{d: Db, pre: List<&2, Db>, post: List<&2, Db>}

# the databases in order
def ds.list(+ds: Ds) -> List<&2, Db>:
  match ds:
    case Ds{d, pre, post}:
      List.reverse.go(&2, Db, pre, d <> post)

# the number of the focused database, and how many there are
def ds.index(+ds: Ds) -> Nat:
  match ds:
    case Ds{d, +pre, post}:
      List.length(&2, Db, pre)

def ds.count(+ds: Ds) -> Nat:
  match ds:
    case Ds{d, +pre, +post}:
      1n+Nat.add(List.length(&2, Db, pre), List.length(&2, Db, post))

def ds.empty.go(n: Nat) -> List<&2, Db>:
  match n:
    case 0n:
      Nil{}
    case 1n+m:
      db.empty() <> ds.empty.go(m)

# 1 + n empty databases, the first in focus
def ds.empty(n: Nat) -> Ds:
  Ds{db.empty(), Nil{}, ds.empty.go(n)}

# the databases at the time now: the focus's time
def ds.at(+now: Nat, ds: Ds) -> Ds:
  match ds:
    case Ds{d, pre, post}:
      Ds{db.at(now, d), pre, post}

def ds.now(+ds: Ds) -> Nat:
  match ds:
    case Ds{+d, pre, post}:
      db.now(d)

# the focused database, lent
def ds.focused(+ds: Ds) -> Db:
  match ds:
    case Ds{+d, pre, post}:
      d

# the databases xs with the j-th in focus at the time now, those before
# it being acc's (nearest first); none when there are not j + 1
def ds.pick(j: Nat, +now: Nat, acc: List<&2, Db>, xs: List<&2, Db>) -> Maybe<&2, Ds>:
  match j xs:
    case 0n Con{x, rest}:
      Some{Ds{db.at(now, x), acc, rest}}
    case 1n+i Con{x, rest}:
      ds.pick(i, now, x <> acc, rest)
    case _ Nil{}:
      None{}

# the databases xs, in focus as ds has its focus, or ds when xs has too
# few
def ds.or(m: Maybe<&2, Ds>, ds: Ds) -> Ds:
  match m:
    case Some{y}:
      y
    case None{}:
      ds

# the databases xs in place of those of ds, the focus at its number
def ds.with(xs: List<&2, Db>, ds: Ds) -> Ds:
  +x = ds
  ds.or(ds.pick(ds.index(x), ds.now(x), Nil{}, xs), x)

def ds.focus.if(same: Bool, +j: Nat, ds: Ds) -> Ds:
  match same:
    case True{}:
      ds
    case False{}:
      +x = ds
      ds.or(ds.pick(j, ds.now(x), Nil{}, ds.list(x)), x)

# the databases with the j-th in focus (as they are when there is none)
def ds.focus(+j: Nat, ds: Ds) -> Ds:
  +x = ds
  ds.focus.if(Nat.is_eq(ds.index(x), j), j, x)

# the j-th of xs, lent
def ds.nth(j: Nat, +xs: List<&2, Db>) -> Maybe<&2, Db>:
  match j xs:
    case 0n Con{x, rest}:
      Some{x}
    case 1n+i Con{x, +rest}:
      ds.nth(i, rest)
    case _ Nil{}:
      None{}

# xs with y in place of the j-th
def ds.put(j: Nat, y: Db, xs: List<&2, Db>) -> List<&2, Db>:
  match j xs:
    case 0n Con{x, rest}:
      y <> rest
    case 1n+i Con{x, rest}:
      x <> ds.put(i, y, rest)
    case _ Nil{}:
      Nil{}

# SWAPDB a b: the a-th and the b-th databases trade places, when there
# are both (whether there are, and the databases after); the focus stays
# at its number, on the database now there
def ds.swap.of(+a: Nat, +b: Nat, ma: Maybe<&2, Db>, mb: Maybe<&2, Db>, xs: List<&2, Db>, ds: Ds) -> Bool & Ds:
  match ma mb:
    case Some{x} Some{y}:
      (True{}, ds.with(ds.put(a, y, ds.put(b, x, xs)), ds))
    case _ _:
      (False{}, ds)

def ds.swap(+a: Nat, +b: Nat, ds: Ds) -> Bool & Ds:
  +x = ds
  +xs = ds.list(x)
  ds.swap.of(a, b, ds.nth(a, xs), ds.nth(b, xs), xs, x)

def ds.flush(xs: List<&2, Db>) -> List<&2, Db>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{x, rest}:
      db.flush(x) <> ds.flush(rest)

# FLUSHALL: every database emptied
def ds.wipe(ds: Ds) -> Ds:
  match ds:
    case Ds{d, pre, post}:
      Ds{db.flush(d), ds.flush(pre), ds.flush(post)}

# MOVE key db moves a key that is there in the selected database to the
# database db, when db is another one and the key is not there in it; on
# the way it deletes the key's entry in db when the key's time has passed
# there, as Redis deletes such a key when MOVE looks it up. BendKV runs
# that deletion as a step of its own (purge), and the move proper moves
# the key only to a database that holds no entry for it at all: each
# step is then one effect in the append-only file, which reads the same
# whenever it runs, and a file cut between them restores the databases
# as the first left them (LAWS.bend: recover_cut).

# whether a key's entry is one whose time has passed at now
def ent.dead(+now: Nat, +m: Maybe<&2, KV.Item<KV.Val>>) -> Bool:
  match m:
    case Some{KV.Item{v, +e}}:
      Bool.not(KV.live(now, e))
    case None{}:
      False{}

# whether k is there in the focus
def ds.has(+ds: Ds, +k: String) -> Bool:
  match ds:
    case Ds{+d, pre, post}:
      Maybe.is_some(&2, KV.Item<KV.Val>, db.ent(d, k))

# k's entry in the focus, when it is there
def ds.ent(+ds: Ds, +k: String) -> Maybe<&2, KV.Item<KV.Val>>:
  match ds:
    case Ds{+d, pre, post}:
      db.ent(d, k)

def ds.purge.if(ok: Bool, +k: String, +j: Nat, y: Db, xs: List<&2, Db>, ds: Ds) -> Bool & Ds:
  match ok:
    case True{}:
      (True{}, ds.with(ds.put(j, db_of(db.del(y, [k])), xs), ds))
    case False{}:
      (False{}, ds)

def ds.purge.of(+k: String, +j: Nat, my: Maybe<&2, Db>, xs: List<&2, Db>, ds: Ds) -> Bool & Ds:
  match my:
    case Some{+y}:
      +x = ds
      ds.purge.if(Bool.and(Nat.is_ne(j, ds.index(x)), Bool.and(ds.has(x, k), ent.dead(ds.now(x), db.entry(y, k)))), k, j, y, xs, x)
    case None{}:
      (False{}, ds)

# MOVE's first step: when k is there in the focus and database j is
# another one, k's entry in j goes if its time has passed there (whether
# it went, and the databases after)
def ds.purge(+k: String, +j: Nat, ds: Ds) -> Bool & Ds:
  +x = ds
  +xs = ds.list(x)
  ds.purge.of(k, j, ds.nth(j, xs), xs, x)

# k to v (of any kind) with the time e, counted, as SET with PXAT leaves
# a string
def db.setx(db: Db, +k: String, v: KV.Val, +e: Nat) -> Db:
  match db:
    case Db{t, +n, +x, now, rr}:
      +u = t
      +h = KV.hash(k)
      +c = KV.code.at(KV.Val, u, k, h)
      Db{KV.setx.at(KV.Val, u, k, v, e, h), cnt.n(c, n), cnt.x(c, e, x), now, rr}

# the databases with k deleted from the focus
def ds.unset(+k: String, ds: Ds) -> Ds:
  match ds:
    case Ds{d, pre, post}:
      Ds{db_of(db.del(d, [k])), pre, post}

def ds.moved(+k: String, +j: Nat, y: Db, ds: Ds) -> Ds:
  +x = ds.unset(k, ds)
  ds.with(ds.put(j, y, ds.list(x)), x)

def ds.move.if(ok: Bool, +k: String, +j: Nat, y: Db, m: Maybe<&2, KV.Item<KV.Val>>, ds: Ds) -> Bool & Ds:
  match ok m:
    case True{} Some{KV.Item{v, +e}}:
      (True{}, ds.moved(k, j, db.setx(y, k, v, e), ds))
    case _ _:
      (False{}, ds)

def ds.move.of(+k: String, +j: Nat, my: Maybe<&2, Db>, ds: Ds) -> Bool & Ds:
  match my:
    case Some{+y}:
      +x = ds
      ds.move.if(Bool.and(Nat.is_ne(j, ds.index(x)), Maybe.is_none(&2, KV.Item<KV.Val>, db.entry(y, k))), k, j, y, ds.ent(x, k), x)
    case None{}:
      (False{}, ds)

# MOVE's second step: when k is there in the focus and database j is
# another one that holds no entry for k, k's entry moves to j, its value
# and its time (whether it moved, and the databases after)
def ds.move(+k: String, +j: Nat, ds: Ds) -> Bool & Ds:
  +x = ds
  +xs = ds.list(x)
  ds.move.of(k, j, ds.nth(j, xs), x)

# COPY src dst DB j REPLACE: src's entry in the focus, its value and its
# time, set to dst in database j (the focus or another one), when dst is
# not there in j at the focus's time, or rep (REPLACE) says to replace
# it; whether it was set, and the databases after. COPY to the same key
# of the same database the session refuses before (Redis's "source and
# destination objects are the same").
def ds.copy.if(ok: Bool, m: Maybe<&2, KV.Item<KV.Val>>, +dst: String, +j: Nat, y: Db, ds: Ds) -> Bool & Ds:
  match ok m:
    case True{} Some{KV.Item{v, +e}}:
      +x = ds
      (True{}, ds.with(ds.put(j, db.setx(y, dst, v, e), ds.list(x)), x))
    case _ _:
      (False{}, ds)

def ds.copy.of(+src: String, +dst: String, +j: Nat, rep: Bool, my: Maybe<&2, Db>, ds: Ds) -> Bool & Ds:
  match my:
    case Some{+y}:
      +x = ds
      ds.copy.if(Bool.or(rep, Bool.not(Maybe.is_some(&2, KV.Item<KV.Val>, ent.live(ds.now(x), db.entry(y, dst))))), ds.ent(x, src), dst, j, y, x)
    case None{}:
      (False{}, ds)

def ds.copy(+src: String, +dst: String, +j: Nat, rep: Bool, ds: Ds) -> Bool & Ds:
  +x = ds
  +xs = ds.list(x)
  ds.copy.of(src, dst, j, rep, ds.nth(j, xs), x)

# What a batch does to the databases, command by command (session.bend:
# plan): a command of one database, run on the focus; the focus moved
# (SELECT, and RESET to 0); two databases swapped (SWAPDB); MOVE's two
# steps; a key copied (COPY) to a database it names, or within the focus
# (a COPY without DB in a file Redis wrote); every database emptied
# (FLUSHALL)
type Act is Data:
  ARun{c: Cmd}
  AFocus{db: Nat}
  ASwap{a: Nat, b: Nat}
  APurge{key: String, db: Nat}
  AMove{key: String, db: Nat}
  ACopy{src: String, dst: String, db: Nat, rep: Bool}
  ACopyHere{src: String, dst: String, rep: Bool}
  AWipe{}

def act.run(r: Reply & Db, pre: List<&2, Db>, post: List<&2, Db>) -> Reply & Ds:
  (x, d) = r
  (x, Ds{d, pre, post})

def act.ok(r: Bool & Ds) -> Reply & Ds:
  (b, ds) = r
  (r_ok(), ds)

# MOVE's and COPY's reply: 1 when the key moved (was copied), else 0
def act.moved(r: Bool & Ds) -> Reply & Ds:
  (b, ds) = r
  (r_int(Bool.pick(Nat, b, 1n, 0n)), ds)

# an act's reply, and the databases after it
def act(a: Act, ds: Ds) -> Reply & Ds:
  match a ds:
    case ARun{c} Ds{d, pre, post}:
      act.run(exec(c, d), pre, post)
    case AFocus{+j} x:
      (r_ok(), ds.focus(j, x))
    case ASwap{+a, +b} x:
      act.ok(ds.swap(a, b, x))
    case APurge{+k, +j} x:
      act.ok(ds.purge(k, j, x))
    case AMove{+k, +j} x:
      act.moved(ds.move(k, j, x))
    case ACopy{+s, +d, +j, rep} x:
      act.moved(ds.copy(s, d, j, rep, x))
    case ACopyHere{+s, +d, rep} x:
      +y = x
      act.moved(ds.copy(s, d, ds.index(y), rep, y))
    case AWipe{} x:
      (r_ok(), ds.wipe(x))

def ds_of(r: Reply & Ds) -> Ds:
  (x, ds) = r
  ds

def reply_ds(r: Reply & Ds) -> Reply:
  (x, ds) = r
  x

# acts one after another: the databases after the last
def acts(as: List<&2, Act>, ds: Ds) -> Ds:
  match as:
    case Nil{}:
      ds
    case Con{a, rest}:
      acts(rest, ds_of(act(a, ds)))
