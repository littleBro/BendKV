# redis.bend: the semantics of the Redis commands BendKV serves, as one
# pure function exec(cmd, db) -> (reply, db'). The server (server.bend)
# only moves bytes and calls exec in order, as Redis's single command
# thread does, so every law about exec is a law about the running server.

import Base
import ./map.bend as KV
import ./float.bend as F
import ./hll.bend as H
import ./geo.bend as G
import ./rdb.bend as D
import ./sha.bend as Sha
import ./stream.bend as X

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

# a long long, as Redis's string2ll reads one and INCRBY's family adds
# two (Long longs, below): its sign and its magnitude hi * 10^9 + lo (lo
# below 10^9, so that each part stays below 2^48, where a Nat must), or
# none (LLBad: no long long, or a sum past one)
type LL is Data:
  LL{neg: Bool, hi: Nat, lo: Nat}
  LLBad{}

# INCRBY's increment, a long long with its sign in its constructor: ByPos
# adds hi * 10^9 + lo, ByNeg takes it away. A command travels in
# registers as wide as its widest form (Cmd, below), and an LL's three
# fields would make IncrBy, and so every command, a word wider.
type By is Data:
  ByPos{hi: Nat, lo: Nat}
  ByNeg{hi: Nat, lo: Nat}

# a reply; an array holds replies, so arrays nest (HELLO, the tracking
# info of CLIENT). RIntS is an integer as its decimal text: BITFIELD's, of
# up to 64 bits, past what an Int holds. It comes last, so that the others
# keep their tags: after RInt, it made GET 1.5% dearer in instructions
# (the reply's encoder compiled otherwise). RNullA is the null array
# (LPOP with a count of a key not there), after it for the same reason.
# The rest are typed where Redis types a reply, as RESP3 writes them
# (resp.bend, Replies): a double as its text (RDbl: Redis's %.17g, inf or
# -inf), a map (RMap: its keys and values in turn), a set (RSet), pairs
# (RPairs, each an RPair of two: ZRANGE's members and their scores, an
# array of pairs in RESP3 and their items flat in RESP2), a verbatim text
# (RVerb: INFO's), a push (RPush: Pub/Sub's), a switch of the protocol
# (RSw: its reply, the one in xs, and those after it in RESP3, r3, or
# RESP2: HELLO's, RESET's), and a map of keys (RKMap, each an RKPair of
# a key and its reply: XREAD's streams, an array of arrays of two in
# RESP2 and a map in RESP3). RESP2 writes RDbl and RVerb as RBulk, and
# RMap, RSet, RPairs and RPush as RArray, so that its bytes are what
# they were. (A pair and a switch hold lists, which the encoder walks as
# it walks an array's items.)
type Reply is Data:
  RStatus{s: String}
  RError{s: String}
  RInt{i: Int}
  RBulk{s: String}
  RNull{}
  RArray{xs: List<&2, Reply>}
  RIntS{s: String}
  RNullA{}
  RDbl{s: String}
  RMap{xs: List<&2, Reply>}
  RSet{xs: List<&2, Reply>}
  RPairs{xs: List<&2, Reply>}
  RPair{xs: List<&2, Reply>}
  RVerb{s: String}
  RPush{xs: List<&2, Reply>}
  RSw{r3: Bool, xs: List<&2, Reply>}
  RKMap{xs: List<&2, Reply>}
  RKPair{xs: List<&2, Reply>}

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
  HWIncr{f: String, by: By}
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
# as Redis does; a scan of it (ZSCAN, its arguments after the key as they
# came, as HSCAN keeps them); or a read of GEO, whose scores are geohashes
# (geo.bend): the positions of members (GEOPOS), their geohashes
# (GEOHASH), the distance of two (GEODIST: its members and unit as they
# came, the unit read as the command parses, its error before the key is
# looked for, as Redis reads it), or a search without STORE (GEORADIUS,
# GEORADIUSBYMEMBER, their _RO forms and GEOSEARCH: its arguments as they
# came, the name it was called by first, which tells its kind, read as it
# runs, as georadiusGeneric reads them once it has looked the key up). A
# command travels in registers as wide as its widest form, so each has
# one field of a word.
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
  ZRGeoPos{ms: List<&2, String>}
  ZRGeoHash{ms: List<&2, String>}
  ZRGeoDist{args: List<&2, String>}
  ZRGeoFind{args: List<&2, String>}

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

# A range of a stream's entries (XRANGE): its bounds, as XRANGE reads
# them, and its count (0 for COUNT 0, which answers a null; past any
# stream's when there is none); or such a range from its last entry back
# (XREVRANGE). A read from the last entry holds the read it reverses, so
# the compiler makes a range a node of its own, as ZQ is.
type XQ is Data:
  XQ{lo: KV.XId, hi: KV.XId, c: Nat}
  XQRev{q: XQ}

# XREAD of one key without BLOCK: the key, its ID as it came (read once
# the key is found, as Redis reads it) and its count (past any stream's
# for none). XRqOf is never built: it makes XRq a node of its own.
type XRq is Data:
  XRq{key: String, id: String, c: Nat}
  XRqOf{x: XRq}

# XREAD of several keys, or with BLOCK (SXRead, below): its count,
# whether BLOCK came, and its keys, then their IDs, as they came. XRmOf
# is never built.
type XRm is Data:
  XRm{c: Nat, block: Bool, ws: List<&2, String>}
  XRmOf{x: XRm}

# XINFO of a key: STREAM with its options as they came (read once the
# key is found; sub: the subcommand's name as it came, for the error of
# options that are wrong), GROUPS, or CONSUMERS of a group (the key, for
# the error of a group not there). XIOf is never built.
type XInf is Data:
  XIStream{sub: String, args: List<&2, String>}
  XIGroups{}
  XICons{key: String, g: String}
  XIOf{x: XInf}

# XPENDING of a group: its summary, or its entries: IDLE's time, the
# range's bounds, the count (past any group's for one past it) and the
# consumer, or none; each with the key, for the error of a group not
# there. XPqOf is never built.
type XPq is Data:
  XPSum{key: String, g: String}
  XPExt{key: String, g: String, idle: X.XIdle, lo: KV.XId, hi: KV.XId, c: Nat, con: Maybe<&2, String>}
  XPqOf{x: XPq}

# A read of a stream (PStream, below): its count of entries (XLEN), a
# range of its entries (XRANGE, XREVRANGE), the entries after an ID
# (XREAD of one key), what XINFO tells of it, or a group's pending
# entries (XPENDING)
type XRead is Data:
  XRLen{}
  XRRange{q: XQ}
  XRRead{q: XRq}
  XRInfo{i: XInf}
  XRPend{q: XPq}

# A write of a stream (UStream, below), each with its arguments as they
# came (the words after the key), which the file logs: XADD's (options,
# ID, fields and values), XTRIM's (options), XDEL's IDs, XSETID's (ID
# and options), and XWNew: XADD on a key not there, made where the key
# was whatever it held (the script the file logs for a new stream where
# a key whose time had passed lay, as for a new hash). The parser reads
# them as Redis reads them before it looks the key up (their errors
# first); the write reads them again (Stream writes, below).
type XWrite is Data:
  XWAdd{ws: List<&2, String>}
  XWTrim{ws: List<&2, String>}
  XWDel{ids: List<&2, String>}
  XWSetId{ws: List<&2, String>}
  XWNew{ws: List<&2, String>}

# A read of one key whose reply depends on what the key holds at now
# alone (its value and the time it expires at, when it is there): its
# type (TYPE), its length (STRLEN), its time to live in s or ms (TTL,
# PTTL) or the time it expires at (EXPIRETIME, PEXPIRETIME), a range of
# its bytes (GETRANGE, SUBSTR), a bit (GETBIT), the bits set in a range
# (BITCOUNT), the first bit of a value in one (BITPOS), fields of its
# bits (BITFIELD_RO, and BITFIELD whose operations are GETs alone), a
# read of a hash (PHash), of a list (PList), of a set (PMems), of a
# sorted set (PZset) or of a stream (PStream), and DUMP's payload of its
# value (PDump). The laws see them as one command, Peek (LAWS.bend:
# disturbs), so one more needs no more proof. A command travels in registers as wide as its
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
  PDump{}
  PStream{op: XRead}

# A time a command names, in ms (a time in s, times 1000; Times, below):
# a short one (TmN, below 10^14) or any other long long (TmB: its sign and
# its magnitude hi * 10^9 + lo); at says whether it counts from 1970
# (EXAT, PXAT, EXPIREAT, PEXPIREAT) or from now
type Tm is Data:
  TmN{at: Bool, ms: Nat}
  TmB{at: Bool, neg: Bool, hi: Nat, lo: Nat}

# a time as a command reads it, or the error it answers
type TmR is Data:
  TOk{t: Tm}
  TBad{r: Reply}

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
# (its increment as it came, read once the key's value is), and a write
# of a HyperLogLog (UHll: PFADD, PFCOUNT of one key, PFDEBUG), and
# RESTORE (URestore: its payload, its time as it read it, REPLACE, and
# IDLETIME or FREQ, which the server sets in the key's access cell; the
# time's errors come once the key is looked up, as Redis checks the key
# first), and a write of a stream (UStream). The laws
# see them as one command, Upd, so one more needs no more proof. UGet holds an update, so the compiler makes an update a
# node of its own: a command travels in registers as wide as its widest
# form, and an update's options are many.
# A write of a HyperLogLog's key (HyperLogLog, below): PFADD of elements,
# PFCOUNT of one key (it keeps the count it makes in the value), and
# PFDEBUG's subcommand as it came (Redis reads it once the key is found)
type HllOp is Data:
  HAdd{els: List<&2, String>}
  HCount{}
  HDebug{sub: String}

type UpdOp is Data:
  USetNx{v: String}
  UGet{op: UpdOp}
  UAppend{v: String}
  USet{v: String, cond: Nat, ttl: SetTtl, name: String}
  UGetEx{o: ExOpt}
  UGetDel{}
  UExpire{t: Tm, c: ExpIf, name: String}
  UPersist{}
  UIncr{by: By}
  URange{off: Nat, s: String}
  USetBit{off: Nat, on: Bool}
  UBitfield{ops: List<&2, BfOp>}
  UHash{op: HWrite}
  UList{op: LWrite}
  UMems{op: SWrite}
  UIncrF{by: String}
  UZset{op: ZWrite}
  UHll{op: HllOp}
  URestore{p: String, t: TmR, rep: Bool, ac: Nat}
  UStream{op: XWrite}

# A command of Pub/Sub: SUBSCRIBE, PSUBSCRIBE and SSUBSCRIBE of their
# channels, patterns or shard channels (kind 0, 1, 2: PSub), UNSUBSCRIBE
# and its kin of theirs (none: all of them; PUnsub), PUBLISH and SPUBLISH
# (shard) of a message to a channel, and PUBSUB's CHANNELS and
# SHARDCHANNELS (of a pattern or all), NUMSUB and SHARDNUMSUB (of
# channels) and NUMPAT. A session command travels as its number and its
# arguments (SPub, below), as wide as the other session commands: a
# command travels in registers as wide as its widest form, and every
# request would pay for a wider one.
type PubOp is Data:
  PSub{kind: Nat, names: List<&2, String>}
  PUnsub{kind: Nat, names: List<&2, String>}
  PPub{shard: Bool, chan: String, msg: String}
  PChans{shard: Bool, pat: Maybe<&2, String>}
  PNumSub{shard: Bool, chans: List<&2, String>}
  PNumPat{}

def pub.arg(args: List<&2, String>) -> Maybe<&2, String>:
  match args:
    case Con{a, rest}:
      Some{a}
    case Nil{}:
      None{}

def pub.pub(+shard: Bool, args: List<&2, String>) -> PubOp:
  match args:
    case Con{c, Con{m, rest}}:
      PPub{shard, c, m}
    case _:
      PNumPat{}

# SPub's number and arguments as the command they are: 0 to 2 SUBSCRIBE,
# PSUBSCRIBE, SSUBSCRIBE; 3 to 5 their UNSUBSCRIBEs; 6 PUBLISH, 7
# SPUBLISH (a channel and a message); 8 PUBSUB CHANNELS, 9 SHARDCHANNELS
# (a pattern, or none); 10 NUMSUB, 11 SHARDNUMSUB; 12 NUMPAT
def pub.op(+kind: Nat, args: List<&2, String>) -> PubOp:
  match kind:
    case 0n:
      PSub{0n, args}
    case 1n:
      PSub{1n, args}
    case 2n:
      PSub{2n, args}
    case 3n:
      PUnsub{0n, args}
    case 4n:
      PUnsub{1n, args}
    case 5n:
      PUnsub{2n, args}
    case 6n:
      pub.pub(False{}, args)
    case 7n:
      pub.pub(True{}, args)
    case 8n:
      PChans{False{}, pub.arg(args)}
    case 9n:
      PChans{True{}, pub.arg(args)}
    case 10n:
      PNumSub{False{}, args}
    case 11n:
      PNumSub{True{}, args}
    case _:
      PNumPat{}

# SORT's options (Sorting, below): what it sorts by (SortBy: each element
# itself; the values a pattern with a '*' names, BY's; or nothing, the
# elements left in their order, as a BY without a '*' leaves them, for
# good once given), LIMIT's offset and count (longs as lnum reads them;
# none is 0 and -1), the patterns of GET in order, DESC and ALPHA; or
# such options with STORE's destination (SortStore: SORT with STORE,
# which the session runs, session.bend). As the options with STORE hold
# the options, the compiler makes them a node of their own, and SORT is
# two words wide (Cmd, below).
type SortBy is Data:
  SByElem{}
  SByPat{p: String}
  SByNone{}

type SortO is Data:
  SortO{by: SortBy, off: Int, cnt: Int, gets: List<&2, String>, desc: Bool, alpha: Bool}
  SortStore{dst: String, o: SortO}

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
# Redis answers those, before it asks a client to authenticate. An error
# the parser finds where Redis's command finds it as it runs (a syntax
# error, a value that is not an integer, of any command: a failed call,
# stat.class) is SFail as the server takes it (fail.of): answered with
# the error once the client may run commands, as Redis asks for AUTH
# before it runs the command. A
# blocking command (BLPOP and its kin, its number id) is SBlock, its
# arguments read as it runs: the session pops what is there, and the
# server waits for a write to its keys when nothing is (session.bend,
# Blocking commands). CLIENT UNBLOCK of a client id (a long long past
# 0; err for its ERROR form) is SUnblock: a session has no client that
# waits, and answers 0; the server unblocks the client, if it waits.
# MULTI, EXEC, DISCARD, WATCH (of its keys) and UNWATCH are SMulti,
# SExec, SDiscard, SWatch and SUnwatch: a session keeps no transaction,
# and answers as a client that has none is answered (EXEC and DISCARD
# without MULTI are errors); the server keeps each client's transaction
# and the keys it watches (server.bend, Transactions).
# The commands of Pub/Sub are SPub, their number and arguments (pub.op,
# above, makes the PubOp they are): a session keeps no
# subscription and knows no other client, and answers as Redis answers a
# client alone on the server that subscribes to nothing; the server keeps
# every client's subscriptions and sends what is published to them
# (server.bend, Pub/Sub). MONITOR is SMonitor: a session alone answers
# OK, and sees no command but its own; the server makes the client a
# monitor and sends it a line of each command that runs (server.bend,
# MONITOR). BGREWRITEAOF is SRewrite: a session alone answers that the
# rewrite started, as Redis does when none runs; the server writes its
# append-only file again from a snapshot of its databases (server.bend,
# The rewrite of the append-only file). SORT with STORE is SSortStore: it
# reads the keys SORT reads and writes its destination with what it
# makes of them, an act of the session's database (ASort, below), so
# that the laws of exec meet SORT as a read alone (Sort). PFCOUNT of
# several keys reads them (SPfCount); PFMERGE reads its keys and writes
# its destination with their union, an act of the session's database
# (APfMerge, below); PFSELFTEST (SPfSelfTest) reads nothing. LASTSAVE,
# MEMORY STATS, MEMORY DOCTOR, LOLWUT's drawings, SHUTDOWN and SAVE are
# SAdmin, their kind and arguments (The administrative commands, below):
# they read the server's state, the drawings its random numbers, SAVE
# writes the RDB file and SHUTDOWN stops the server (server.bend, The RDB
# file and SHUTDOWN), which a session alone does not. A GEO search that
# stores (GEORADIUS's and GEORADIUSBYMEMBER's STORE and STOREDIST,
# GEOSEARCHSTORE) is SGeoStore, its kind and its arguments, the name it
# was called by first (GEO, below): it reads its key and writes its
# destination with what it finds, an act of the session's database
# (AGeo, below), as SORT with STORE does. RESTORE
# with IDLETIME or FREQ is SRestore, its key and its update (URestore):
# the session runs the update on its database, and the server, which
# keeps when each key was last used, sets the key's word as the option
# says once the update restored the key (server.bend, Access). ACL's
# subcommands are SAcl, their number and arguments (ACL, below): the
# session keeps the users and the log (session.bend, ACL), and the server
# answers WHOAMI from its clients (server.bend, ACL). AUTH (SAuth) and
# HELLO (SHello) keep their arguments with each password put as its
# SHA-256 (auth.hashed, hello.hashed), which is all the session reads of
# one. XREAD of several keys, or with BLOCK (SXRead), reads them
# (Streams, below).

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
  SFail{r: Reply}
  SSPop{key: String, args: List<&2, String>}
  SSRandMember{key: String, args: List<&2, String>}
  SZRandMember{key: String, args: List<&2, String>}
  SBlock{id: Nat, args: List<&2, String>}
  SUnblock{id: Nat, err: Bool}
  SMulti{}
  SExec{}
  SDiscard{}
  SWatch{keys: List<&2, String>}
  SUnwatch{}
  SPub{kind: Nat, args: List<&2, String>}
  SClient{kind: Nat, args: List<&2, String>}
  SMonitor{}
  SRewrite{}
  SSortStore{key: String, o: SortO}
  SPfCount{keys: List<&2, String>}
  SPfMerge{dst: String, srcs: List<&2, String>}
  SPfSelfTest{}
  SAdmin{kind: Nat, args: List<&2, String>}
  SGeoStore{kind: Nat, args: List<&2, String>}
  SRestore{key: String, op: UpdOp}
  SAcl{kind: Nat, args: List<&2, String>}
  SXRead{q: XRm}

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
# there, from its last end when max), and last Sort (SORT and SORT_RO
# without STORE: the elements of the list, set or sorted set at key,
# sorted as o says, or the values its patterns name for them, a read of
# those keys as well; Sorting, below)
type Cmd is Data:
  Ping{}
  Echo{msg: String}
  Get{key: String}
  Set{key: String, val: String}
  Del{keys: List<&2, String>}
  Exists{keys: List<&2, String>}
  IncrBy{key: String, by: By}
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
  Sort{key: String, o: SortO}

# Integers
# --------
# An Int holds what a Nat holds, below 2^48: a reply's count, an index.
# int_read reads one of 14 digits at most (a client's id, the number of
# databases). Redis's integers are long longs, which INCRBY's family adds
# as such (Long longs, below).

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
    case KV.CStream{x}:
      "stream"

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
   "INFO",
   "    Return information about the current client connection.",
   "KILL <ip:port>",
   "    Kill connection made from <ip:port>.",
   "KILL <option> <value> [<option> <value> [...]]",
   "    Kill connections. Options are:",
   "    * ADDR (<ip:port>|<unixsocket>:0)",
   "      Kill connections made from the specified address",
   "    * LADDR (<ip:port>|<unixsocket>:0)",
   "      Kill connections made to specified local address",
   "    * TYPE (NORMAL|MASTER|REPLICA|PUBSUB)",
   "      Kill connections by type.",
   "    * USER <username>",
   "      Kill connections authenticated by <username>.",
   "    * SKIPME (YES|NO)",
   "      Skip killing current connection (default: yes).",
   "LIST [options ...]",
   "    Return information about client connections. Options:",
   "    * TYPE (NORMAL|MASTER|REPLICA|PUBSUB)",
   "      Return clients of specified type.",
   "UNPAUSE",
   "    Stop the current client pause, resuming traffic.",
   "PAUSE <timeout> [WRITE|ALL]",
   "    Suspend all, or just write, clients for <timeout> milliseconds.",
   "REPLY (ON|OFF|SKIP)",
   "    Control the replies sent to the current connection.",
   "SETNAME <name>",
   "    Assign the name <name> to the current connection.",
   "UNBLOCK <clientid> [TIMEOUT|ERROR]",
   "    Unblock the specified blocked client.",
   "TRACKING (ON|OFF) [REDIRECT <id>] [BCAST] [PREFIX <prefix> [...]]",
   "         [OPTIN] [OPTOUT] [NOLOOP]",
   "    Control server assisted client side caching.",
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

# CLIENT's subcommands by their names, in any case
def client_id(+n: String, len: Nat) -> Nat:
  match len:
    case 2n:
      Bool.pick(Nat, String.eq(n, "ID"), 1n, 0n)
    case 4n:
      Bool.pick(Nat, String.eq(n, "HELP"), 2n,
      Bool.pick(Nat, String.eq(n, "LIST"), 11n,
      Bool.pick(Nat, String.eq(n, "INFO"), 12n,
      Bool.pick(Nat, String.eq(n, "KILL"), 13n, 0n))))
    case 5n:
      Bool.pick(Nat, String.eq(n, "REPLY"), 3n,
      Bool.pick(Nat, String.eq(n, "PAUSE"), 14n, 0n))
    case 7n:
      Bool.pick(Nat, String.eq(n, "GETNAME"), 4n,
      Bool.pick(Nat, String.eq(n, "SETNAME"), 5n,
      Bool.pick(Nat, String.eq(n, "CACHING"), 6n,
      Bool.pick(Nat, String.eq(n, "UNBLOCK"), 7n,
      Bool.pick(Nat, String.eq(n, "UNPAUSE"), 15n, 0n)))))
    case 8n:
      Bool.pick(Nat, String.eq(n, "GETREDIR"), 8n,
      Bool.pick(Nat, String.eq(n, "NO-EVICT"), 9n,
      Bool.pick(Nat, String.eq(n, "TRACKING"), 16n, 0n)))
    case 12n:
      Bool.pick(Nat, String.eq(n, "TRACKINGINFO"), 10n, 0n)
    case _:
      0n

# CLIENT NO-EVICT: BendKV evicts no clients, so it only checks the word
def no_evict(+on: String) -> SessOp:
  sess_reply(Bool.pick(Reply, Bool.or(is_word(on, "ON"), is_word(on, "OFF")), r_ok(), RError{"ERR syntax error"}))

# CLIENT UNBLOCK id [TIMEOUT|ERROR]: no client is ever blocked
# CLIENT UNBLOCK of an id read as a long long: no client has a negative
# id (nor 0, which SUnblock finds no client of)
def unblock_id(m: Maybe<&2, Int>, +err: Bool) -> SessOp:
  match m:
    case Some{IPos{n}}:
      SUnblock{n, err}
    case Some{INeg{n}}:
      sess_reply(RInt{IPos{0n}})
    case None{}:
      sess_reply(e_int())

# the reason, read before the id, as Redis reads them
def unblock_why(t: Bool, e: Bool, +id: String) -> SessOp:
  match t e:
    case True{} _:
      unblock_id(int_read(id), False{})
    case False{} True{}:
      unblock_id(int_read(id), True{})
    case False{} False{}:
      sess_reply(RError{"ERR CLIENT UNBLOCK reason should be TIMEOUT or ERROR"})

def unblock(sub: String, args: List<&2, String>) -> SessOp:
  match args:
    case Con{+id, Nil{}}:
      unblock_id(int_read(id), False{})
    case Con{+id, Con{+why, Nil{}}}:
      unblock_why(is_word(why, "TIMEOUT"), is_word(why, "ERROR"), id)
    case _:
      sess_reply(e_sub_syntax(sub, "CLIENT"))

def tracking_info() -> Reply:
  RMap{[RBulk{"flags"}, RSet{[RBulk{"off"}]}, RBulk{"redirect"}, RInt{INeg{0n}}, RBulk{"prefixes"}, RArray{Nil{}}]}

# CLIENT TRACKING's options, read in order as Redis reads them before it
# looks at ON or OFF (clientCommand), each for the server to act on in
# turn: a REDIRECT names a client by an id read as a long long (0 for an
# id no client can have), whose client the server looks for then; BCAST,
# a PREFIX, OPTIN, OPTOUT and NOLOOP; an option the parser cannot read
# (an unknown one, or one without its argument, an id that is no
# integer, a second REDIRECT) is the error the server answers when it
# comes to it, and nothing after it counts
type TOpt is Data:
  TrRedir{id: Nat}
  TrBcast{}
  TrPrefix{p: String}
  TrOptin{}
  TrOptout{}
  TrNoloop{}
  TrBad{r: Reply}

# CLIENT LIST, INFO, KILL, NO-EVICT, PAUSE, UNPAUSE, TRACKING, CACHING,
# GETREDIR and TRACKINGINFO are SClient, their number and arguments
# (client.op makes the ClOp they are): a session knows no other client,
# and answers as Redis answers a client alone on the server, with no
# tracking; the server keeps every client's facts, kills, pauses and
# tracking (server.bend, Clients, The pause, Tracking). LIST of all
# clients, of a type (1 normal, 2 replica, 3 pubsub, 4 master) or of ids,
# in the order given; INFO of the client itself; KILL of those a filter
# picks (the new form) or of the one at an address (the old form, which
# may kill the client itself); NO-EVICT on or off, which CLIENT LIST
# shows; PAUSE of the commands that write (all: of every command) for hi
# * 10^9 + lo milliseconds (a long long's magnitude, as LL keeps one);
# UNPAUSE; TRACKING on (1), off (0) or neither (2: a syntax error, once
# its options are read), with its options; CACHING yes (1), no (0) or
# neither (2); GETREDIR; TRACKINGINFO. Errors in the arguments are found
# here, in Redis's order (clientCommand), but those that depend on other
# clients, and on the users the server keeps: KILL's USER options before
# the first error, or all of them, are CoKillUsers, whose first user the
# server does not keep answers its error, as Redis answers it when it
# reads that option, else the error after them (err), or the kill.
type ClOp is Data:
  CoList{ty: Nat, ids: Maybe<&2, List<&2, Nat>>}
  CoInfo{}
  CoKill{f: Kill}
  CoKillAddr{addr: String}
  CoKillUsers{users: List<&2, String>, f: Kill, err: Maybe<&2, Reply>}
  CoNoEvict{on: Bool}
  CoPause{hi: Nat, lo: Nat, all: Bool}
  CoUnpause{}
  CoTrack{on: Nat, opts: List<&2, TOpt>}
  CoCaching{yes: Nat}
  CoGetRedir{}
  CoTrackInfo{}
  CoBad{r: Reply}

# CLIENT KILL's filter: the client's address and its own (none: any), its
# id (none: any; Some{0} names no client), its type (0: any), whether
# the client that kills is spared (SKIPME, yes unless told no) and its
# user (none: any).
type Kill is Data:
  Kill{addr: Maybe<&2, String>, laddr: Maybe<&2, String>, id: Maybe<&2, Nat>, ty: Nat, skip: Bool, user: Maybe<&2, String>}

# a client id as Redis reads one, a long long (string2ll): one that can
# be a client's (14 digits at most, as int_read reads them; ids start at
# 1), a long long past 14 digits (no client has it), one that is 0 or
# negative, or none
type Cid is Data:
  CidPos{n: Nat}
  CidBig{}
  CidNot{}
  CidBad{}

def cid.sign(neg: Bool) -> Cid:
  match neg:
    case True{}:
      CidNot{}
    case False{}:
      CidBig{}

# at 19 digits, a long long is at most 9223372036854775807 (its
# negation's magnitude 9223372036854775808)
def cid.top.of(c: Cmp, neg: Bool) -> Cid:
  match c:
    case GT{}:
      CidBad{}
    case _:
      cid.sign(neg)

def cid.top(+ds: String, +neg: Bool) -> Cid:
  cid.top.of(String.order(ds, Bool.pick(String, neg, "9223372036854775808", "9223372036854775807")), neg)

def cid.long.of(ok: Bool, at19: Bool, +s: String, +i: Nat, +neg: Bool) -> Cid:
  match ok at19:
    case True{} True{}:
      cid.top(String.drop(s, i), neg)
    case True{} False{}:
      cid.sign(neg)
    case False{} _:
      CidBad{}

# n digits from i, past 14: a long long when they are all digits, the
# first no zero, and at most 19 of them
def cid.long(+s: String, +i: Nat, +n: Nat, +neg: Bool) -> Cid:
  cid.long.of(Bool.and(Bool.and(Nat.is_eq(String.digits_at(s, i), n), U32.is_ne(String.code_at(s, i), 48)), Nat.is_le(n, 19n)), Nat.is_eq(n, 19n), s, i, neg)

def cid.of(m: Maybe<&2, Int>) -> Cid:
  match m:
    case Some{IPos{n}}:
      match n:
        case 0n:
          CidNot{}
        case 1n+p:
          CidPos{1n+p}
    case Some{INeg{n}}:
      CidNot{}
    case None{}:
      CidBad{}

def cid.read.of(short: Bool, +s: String, +k: Nat, +n: Nat, +neg: Bool) -> Cid:
  match short:
    case True{}:
      cid.of(int_read(s))
    case False{}:
      cid.long(s, k, Nat.sub(n, k), neg)

def cid.read(+s: String) -> Cid:
  +n = String.length(s)
  +neg = U32.is_eq(String.code_at(s, 0n), 45)
  +k = Bool.pick(Nat, neg, 1n, 0n)
  cid.read.of(Nat.is_le(Nat.sub(n, k), 14n), s, k, n, neg)

# a client type by its name, in any case (getClientTypeByName): 1
# normal, 2 replica (or slave), 3 pubsub, 4 master; 0 for none
def client.type(+n: String) -> Nat:
  Bool.pick(Nat, is_word(n, "NORMAL"), 1n,
  Bool.pick(Nat, Bool.or(is_word(n, "SLAVE"), is_word(n, "REPLICA")), 2n,
  Bool.pick(Nat, is_word(n, "PUBSUB"), 3n,
  Bool.pick(Nat, is_word(n, "MASTER"), 4n, 0n))))

def e_client_type(+n: String) -> ClOp:
  CoBad{RError{no_newlines("ERR Unknown client type '" ++ cstr(n) ++ "'")}}

def e_client_syntax() -> ClOp:
  CoBad{RError{"ERR syntax error"}}

# CLIENT LIST ID's ids, each read as Redis reads it: the first that is no
# long long ends it with an error; one no client can have is dropped
def list.ids(args: List<&2, String>, c: Cid, acc: List<&2, Nat>) -> ClOp:
  match args c:
    case _ CidBad{}:
      CoBad{RError{"ERR Invalid client ID"}}
    case Nil{} CidPos{n}:
      CoList{0n, Some{List.reverse(&2, Nat, n <> acc)}}
    case Nil{} _:
      CoList{0n, Some{List.reverse(&2, Nat, acc)}}
    case Con{+a, rest} CidPos{n}:
      list.ids(rest, cid.read(a), n <> acc)
    case Con{+a, rest} _:
      list.ids(rest, cid.read(a), acc)

# the ids of CLIENT LIST ID (a CidNot reads none and adds no id)
def list.ids.of(args: List<&2, String>) -> ClOp:
  match args:
    case Nil{}:
      CoList{0n, Some{Nil{}}}
    case Con{+a, rest}:
      list.ids(rest, cid.read(a), Nil{})

def list.type(+t: Nat, +n: String) -> ClOp:
  match t:
    case 0n:
      e_client_type(n)
    case _:
      CoList{t, None{}}

def list.two(ty: Bool, id: Bool, +x: String) -> ClOp:
  match ty id:
    case True{} _:
      list.type(client.type(x), x)
    case False{} True{}:
      list.ids.of([x])
    case False{} False{}:
      e_client_syntax()

def list.more(id: Bool, xs: List<&2, String>) -> ClOp:
  match id:
    case True{}:
      list.ids.of(xs)
    case False{}:
      e_client_syntax()

# CLIENT LIST's arguments: none; TYPE and a type; ID and ids
def list.args(args: List<&2, String>) -> ClOp:
  match args:
    case Nil{}:
      CoList{0n, None{}}
    case Con{+w, Con{+x, Nil{}}}:
      list.two(is_word(w, "TYPE"), is_word(w, "ID"), x)
    case Con{+w, Con{x, Con{y, more}}}:
      list.more(is_word(w, "ID"), x <> y <> more)
    case _:
      e_client_syntax()

# CLIENT KILL's options by name: 1 ID, 2 TYPE, 3 ADDR, 4 LADDR, 5 USER,
# 6 SKIPME; 0 for none
def kill.word(+o: String) -> Nat:
  Bool.pick(Nat, is_word(o, "ID"), 1n,
  Bool.pick(Nat, is_word(o, "TYPE"), 2n,
  Bool.pick(Nat, is_word(o, "ADDR"), 3n,
  Bool.pick(Nat, is_word(o, "LADDR"), 4n,
  Bool.pick(Nat, is_word(o, "USER"), 5n,
  Bool.pick(Nat, is_word(o, "SKIPME"), 6n, 0n))))))

def kill.id(m: Maybe<&2, Nat>, f: Kill) -> Kill:
  match f:
    case Kill{a, l, i, t, s, u}:
      Kill{a, l, m, t, s, u}

def kill.ty(+n: Nat, f: Kill) -> Kill:
  match f:
    case Kill{a, l, i, t, s, u}:
      Kill{a, l, i, n, s, u}

def kill.addr(v: String, f: Kill) -> Kill:
  match f:
    case Kill{a, l, i, t, s, u}:
      Kill{Some{v}, l, i, t, s, u}

def kill.laddr(v: String, f: Kill) -> Kill:
  match f:
    case Kill{a, l, i, t, s, u}:
      Kill{a, Some{v}, i, t, s, u}

def kill.skip(b: Bool, f: Kill) -> Kill:
  match f:
    case Kill{a, l, i, t, s, u}:
      Kill{a, l, i, t, b, u}

def kill.usr(v: String, f: Kill) -> Kill:
  match f:
    case Kill{a, l, i, t, s, u}:
      Kill{a, l, i, t, s, Some{v}}

# a step of CLIENT KILL's options: the filter so far, or the error that
# ends them
type KSt is Data:
  KOk{f: Kill}
  KErr{r: Reply}

def e_kill_id() -> KSt:
  KErr{RError{"ERR client-id should be greater than 0"}}

def kill.idv(c: Cid, f: Kill) -> KSt:
  match c:
    case CidPos{n}:
      KOk{kill.id(Some{n}, f)}
    case CidBig{}:
      KOk{kill.id(Some{0n}, f)}
    case _:
      e_kill_id()

def kill.tyv(+ty: Nat, +v: String, f: Kill) -> KSt:
  match ty:
    case 0n:
      KErr{RError{no_newlines("ERR Unknown client type '" ++ cstr(v) ++ "'")}}
    case _:
      KOk{kill.ty(ty, f)}

# CLIENT KILL's error for a USER option whose user the server does not
# keep
def e_no_user(+u: String) -> Reply:
  RError{no_newlines("ERR No such user '" ++ cstr(u) ++ "'")}

def kill.skipv(yes: Bool, no: Bool, f: Kill) -> KSt:
  match yes no:
    case True{} _:
      KOk{kill.skip(True{}, f)}
    case False{} True{}:
      KOk{kill.skip(False{}, f)}
    case False{} False{}:
      KErr{RError{"ERR syntax error"}}

# an option (by kill.word) and its value applied to the filter
def kill.opt(+k: Nat, +v: String, f: Kill) -> KSt:
  match k:
    case 1n:
      kill.idv(cid.read(v), f)
    case 2n:
      kill.tyv(client.type(v), v, f)
    case 3n:
      KOk{kill.addr(v, f)}
    case 4n:
      KOk{kill.laddr(v, f)}
    case 5n:
      KOk{kill.usr(v, f)}
    case 6n:
      kill.skipv(is_word(v, "YES"), is_word(v, "NO"), f)
    case _:
      KErr{RError{"ERR syntax error"}}

def kill.step(st: KSt, +k: Nat, +v: String) -> KSt:
  match st:
    case KOk{f}:
      kill.opt(k, v, f)
    case KErr{r}:
      KErr{r}

# the options read, an option left without its value: a syntax error,
# unless an error came before
def kill.odd(st: KSt) -> KSt:
  match st:
    case KOk{f}:
      KErr{RError{"ERR syntax error"}}
    case KErr{r}:
      KErr{r}

# the users of USER options read before any error (us, newest first),
# with the user of an option k read now
def kill.users(+st: KSt, +k: Nat, +v: String, +us: List<&2, String>) -> List<&2, String>:
  match st:
    case KOk{f}:
      Bool.pick(List<&2, String>, Nat.is_eq(k, 5n), v <> us, us)
    case KErr{r}:
      us

# the options' outcome, after the users they named (CoKillUsers) when
# they named some
def kill.end(us: List<&2, String>, st: KSt) -> ClOp:
  match us st:
    case Nil{} KOk{f}:
      CoKill{f}
    case Nil{} KErr{r}:
      CoBad{r}
    case Con{u, rest} KOk{f}:
      CoKillUsers{List.reverse(&2, String, u <> rest), f, None{}}
    case Con{u, rest} KErr{r}:
      CoKillUsers{List.reverse(&2, String, u <> rest), Kill{None{}, None{}, None{}, 0n, True{}, None{}}, Some{r}}

# The new form's options, each with its value, in order: the first error
# ends them, as Redis's loop does; a later option of a name overrides an
# earlier one. An option without a value, or one Redis does not know, is
# a syntax error. Each USER option's user is looked up as Redis reads it
# (us: kill.end).
def kill.args(args: List<&2, String>, +st: KSt, us: List<&2, String>) -> ClOp:
  match args:
    case Nil{}:
      kill.end(us, st)
    case Con{+o, Con{+v, rest}}:
      +k = kill.word(o)
      kill.args(rest, kill.step(st, k, v), kill.users(st, k, v, us))
    case Con{o, Nil{}}:
      kill.end(us, kill.odd(st))

# CLIENT KILL: one argument is the old form, an address; more are options
def kill.of(args: List<&2, String>) -> ClOp:
  match args:
    case Con{a, Nil{}}:
      CoKillAddr{a}
    case _:
      kill.args(args, KOk{Kill{None{}, None{}, None{}, 0n, True{}, None{}}}, Nil{})

def no_evict.on(on: Bool, off: Bool) -> ClOp:
  match on off:
    case True{} _:
      CoNoEvict{True{}}
    case False{} True{}:
      CoNoEvict{False{}}
    case False{} False{}:
      e_client_syntax()

def no_evict.of(args: List<&2, String>) -> ClOp:
  match args:
    case Con{+on, Nil{}}:
      no_evict.on(is_word(on, "ON"), is_word(on, "OFF"))
    case _:
      e_client_syntax()

# A client's line in CLIENT LIST and CLIENT INFO, as Redis 7.0.15 writes
# it (catClientInfoString): its id, its peer's address and its own, its
# socket's fd, name, age and idle time (s), flags, database, the counts of
# its channels, patterns and shard channels, the commands queued in its
# MULTI (none: -1), the bytes of the batch it runs (qbuf) and of the
# command's arguments (argv-mem), its last command (cmd), its user (ACL),
# the client its invalidations go to (redir: -1 when it does not track, 0 itself), and
# whether it speaks RESP3 (resp). BendKV keeps no buffer of a client's own, so
# qbuf-free, multi-mem, the reply buffer's size and peak, the output
# lists and the memory are 0.
type ClLine is Data:
  ClLine{id: Nat, addr: String, laddr: String, fd: Nat, name: String, age: Nat, idle: Nat, flags: String, db: Nat, sub: Nat, psub: Nat, ssub: Nat, multi: Maybe<&2, Nat>, qbuf: Nat, argv: Nat, cmd: String, user: String, redir: String, r3: Bool}

def line.multi(m: Maybe<&2, Nat>) -> String:
  match m:
    case Some{n}:
      Nat.show(n)
    case None{}:
      "-1"

def client.line(l: ClLine) -> String:
  match l:
    case ClLine{id, addr, laddr, fd, name, age, idle, flags, db, sub, psub, ssub, multi, qbuf, argv, cmd, user, redir, r3}:
      a = "id=" ++ Nat.show(id) ++ " addr=" ++ addr ++ " laddr=" ++ laddr ++ " fd=" ++ Nat.show(fd) ++ " name=" ++ name
      b = " age=" ++ Nat.show(age) ++ " idle=" ++ Nat.show(idle) ++ " flags=" ++ flags ++ " db=" ++ Nat.show(db)
      c = " sub=" ++ Nat.show(sub) ++ " psub=" ++ Nat.show(psub) ++ " ssub=" ++ Nat.show(ssub) ++ " multi=" ++ line.multi(multi)
      d = " qbuf=" ++ Nat.show(qbuf) ++ " qbuf-free=0 argv-mem=" ++ Nat.show(argv) ++ " multi-mem=0 rbs=0 rbp=0 obl=0 oll=0 omem=0 tot-mem=0"
      a ++ b ++ c ++ d ++ " events=r cmd=" ++ cmd ++ " user=" ++ user ++ " redir=" ++ redir ++ " resp=" ++ Bool.pick(String, r3, "3", "2")

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
          SClient{7n, [v]}
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
          SClient{8n, Nil{}}
        case _:
          s_arity("client|getredir")
    case 9n:  # NO-EVICT
      match args:
        case Con{on, Nil{}}:
          SClient{3n, [on]}
        case _:
          s_arity("client|no-evict")
    case 10n:  # TRACKINGINFO
      match args:
        case Nil{}:
          SClient{9n, Nil{}}
        case _:
          s_arity("client|trackinginfo")
    case 11n:  # LIST
      SClient{0n, args}
    case 12n:  # INFO
      match args:
        case Nil{}:
          SClient{1n, Nil{}}
        case _:
          s_arity("client|info")
    case 13n:  # KILL
      match args:
        case Nil{}:
          s_arity("client|kill")
        case Con{a, rest}:
          SClient{2n, a <> rest}
    case 14n:  # PAUSE
      match args:
        case Nil{}:
          s_arity("client|pause")
        case Con{t, Nil{}}:
          SClient{4n, [t]}
        case Con{t, Con{m, Nil{}}}:
          SClient{4n, [t, m]}
        case _:
          sess_reply(e_sub_syntax(sub, "CLIENT"))
    case 15n:  # UNPAUSE
      match args:
        case Nil{}:
          SClient{5n, Nil{}}
        case _:
          s_arity("client|unpause")
    case 16n:  # TRACKING
      match args:
        case Nil{}:
          s_arity("client|tracking")
        case Con{a, rest}:
          SClient{6n, a <> rest}
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

# MEMORY: USAGE of a key (its options read as it runs), STATS and DOCTOR
# (SAdmin: they read the server's state), PURGE and MALLOC-STATS (as Redis
# answers them built with libc's malloc, as INFO's mem_allocator says
# BendKV is: purgeless, and with no statistics of its own), and HELP
def memory_id(+n: String, len: Nat) -> Nat:
  match len:
    case 4n:
      Bool.pick(Nat, String.eq(n, "HELP"), 1n, 0n)
    case 5n:
      Bool.pick(Nat, String.eq(n, "USAGE"), 2n, Bool.pick(Nat, String.eq(n, "STATS"), 3n, Bool.pick(Nat, String.eq(n, "PURGE"), 5n, 0n)))
    case 6n:
      Bool.pick(Nat, String.eq(n, "DOCTOR"), 4n, 0n)
    case 12n:
      Bool.pick(Nat, String.eq(n, "MALLOC-STATS"), 6n, 0n)
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
    case 3n:  # STATS
      match args:
        case Nil{}:
          SAdmin{1n, Nil{}}
        case _:
          s_arity("memory|stats")
    case 4n:  # DOCTOR
      match args:
        case Nil{}:
          SAdmin{2n, Nil{}}
        case _:
          s_arity("memory|doctor")
    case 5n:  # PURGE
      match args:
        case Nil{}:
          SReply{r_ok()}
        case _:
          s_arity("memory|purge")
    case 6n:  # MALLOC-STATS
      match args:
        case Nil{}:
          SReply{RBulk{"Stats not supported for the current allocator"}}
        case _:
          s_arity("memory|malloc-stats")
    case _:
      e_unknown_sub(sub, "MEMORY")

# PUBSUB: CHANNELS and SHARDCHANNELS of a pattern, or of all (one
# argument more is the subcommand's own complaint, as Redis's), NUMSUB
# and SHARDNUMSUB of channels, NUMPAT, HELP
def pubsub_id(+n: String, len: Nat) -> Nat:
  match len:
    case 4n:
      Bool.pick(Nat, String.eq(n, "HELP"), 2n, 0n)
    case 6n:
      Bool.pick(Nat, String.eq(n, "NUMPAT"), 3n, Bool.pick(Nat, String.eq(n, "NUMSUB"), 4n, 0n))
    case 8n:
      Bool.pick(Nat, String.eq(n, "CHANNELS"), 1n, 0n)
    case 11n:
      Bool.pick(Nat, String.eq(n, "SHARDNUMSUB"), 6n, 0n)
    case 13n:
      Bool.pick(Nat, String.eq(n, "SHARDCHANNELS"), 5n, 0n)
    case _:
      0n

def pubsub_help() -> List<&2, String>:
  ["CHANNELS [<pattern>]",
   "    Return the currently active channels matching a <pattern> (default: '*').",
   "NUMPAT",
   "    Return number of subscriptions to patterns.",
   "NUMSUB [<channel> ...]",
   "    Return the number of subscribers for the specified channels, excluding",
   "    pattern subscriptions(default: no channels).",
   "SHARDCHANNELS [<pattern>]",
   "    Return the currently active shard level channels matching a <pattern> (default: '*').",
   "SHARDNUMSUB [<shardchannel> ...]",
   "    Return the number of subscribers for the specified shard level channel(s)"]

def pubsub_chans(+kind: Nat, sub: String, args: List<&2, String>) -> SessOp:
  match args:
    case Nil{}:
      SPub{kind, Nil{}}
    case Con{p, Nil{}}:
      SPub{kind, [p]}
    case _:
      SBad{e_sub_syntax(sub, "PUBSUB")}

def parse_pubsub(id: Nat, sub: String, args: List<&2, String>) -> SessOp:
  match id:
    case 1n:  # CHANNELS
      pubsub_chans(8n, sub, args)
    case 2n:  # HELP
      match args:
        case Nil{}:
          help("PUBSUB", pubsub_help())
        case _:
          s_arity("pubsub|help")
    case 3n:  # NUMPAT
      match args:
        case Nil{}:
          SPub{12n, Nil{}}
        case _:
          s_arity("pubsub|numpat")
    case 4n:  # NUMSUB
      SPub{10n, args}
    case 5n:  # SHARDCHANNELS
      pubsub_chans(9n, sub, args)
    case 6n:  # SHARDNUMSUB
      SPub{11n, args}
    case _:
      e_unknown_sub(sub, "PUBSUB")

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

# Long longs
# ----------
# A long long is read as Redis's string2ll reads one, and INCRBY's family
# (INCR, DECR, INCRBY, DECRBY, HINCRBY) adds two as incrDecrCommand and
# hincrbyCommand do, refusing a sum past LLONG_MAX or below LLONG_MIN. A
# magnitude is kept as hi * 10^9 + lo (LL, Types), so that no Nat here
# passes 2^48: hi is below 10^10, and a sum of two below 2 * 10^10.

# whether a magnitude hi * 10^9 + lo is at most hb * 10^9 + lb
def ll.le(+hi: Nat, +lo: Nat, +hb: Nat, +lb: Nat) -> Bool:
  Bool.or(Nat.is_lt(hi, hb), Bool.and(Nat.is_eq(hi, hb), Nat.is_le(lo, lb)))

# the long long of sign neg and magnitude hi * 10^9 + lo, or none past
# 2^63 - 1 (past 2^63 when neg)
def ll.in(+neg: Bool, +hi: Nat, +lo: Nat) -> LL:
  Bool.pick(LL, ll.le(hi, lo, dec.llmax(), Bool.pick(Nat, neg, 854775808n, 854775807n)), LL{neg, hi, lo}, LLBad{})

# the d digits of s from index i as a magnitude, when ok: the last nine
# are lo, those before them hi
def ll.at.of(ok: Bool, +neg: Bool, +s: String, +i: Nat, +d: Nat) -> LL:
  match ok:
    case True{}:
      +k = Nat.sub(d, 9n)
      ll.in(neg, String.dec_at(s, i, k), String.dec_at(s, Nat.add(i, k), Nat.min(d, 9n)))
    case False{}:
      LLBad{}

# d chars from index i, 1 to 19 of them (short): all digits, the first
# not 0 unless it is the only one and no '-' came before it
def ll.at.short(short: Bool, +neg: Bool, +s: String, +i: Nat, +d: Nat) -> LL:
  match short:
    case True{}:
      ll.at.of(Bool.and(Nat.is_le(d, String.digits_at(s, i)), Bool.or(U32.is_ne(String.code_at(s, i), 48), Bool.and(Nat.is_eq(d, 1n), Bool.not(neg)))), neg, s, i, d)
    case False{}:
      LLBad{}

# the long long the chars of s from index a to index e spell, as
# string2ll reads one: an optional '-', then 1 to 19 digits, no 0 first
# but in "0" ("-0" is none), at most 2^63 - 1 (2^63 after a '-'). The
# digits are read where they lie (String.digits_at, String.dec_at).
def ll.at(+s: String, +a: Nat, +e: Nat) -> LL:
  +neg = U32.is_eq(String.code_at(s, a), 45)
  +i = Bool.pick(Nat, neg, 1n+a, a)
  +d = Nat.sub(e, i)
  ll.at.short(Bool.and(Nat.is_lt(0n, d), Nat.is_le(d, 19n)), neg, s, i, d)

# a value of 1 to 9 chars (nine) that is digits alone, the first not 0
# unless it is the only one, reads at once; any other the general way
def ll.read.nine(ok: Bool, +s: String, +n: Nat) -> LL:
  match ok:
    case True{}:
      LL{False{}, 0n, String.dec_at(s, 0n, n)}
    case False{}:
      ll.at(s, 0n, n)

def ll.read.of(nine: Bool, +s: String, +n: Nat) -> LL:
  match nine:
    case True{}:
      ll.read.nine(Bool.and(Nat.is_eq(String.digits_at(s, 0n), n), Bool.or(Nat.is_eq(n, 1n), U32.is_ne(String.code_at(s, 0n), 48))), s, n)
    case False{}:
      ll.at(s, 0n, n)

def ll.read(+s: String) -> LL:
  +n = String.length(s)
  ll.read.of(Bool.and(Nat.is_lt(0n, n), Nat.is_le(n, 9n)), s, n)

# a magnitude q * 10^9 + r as its decimal digits: r's nine, zeros first,
# after q's (10^9 + r has ten digits, a 1 first)
def ll.digits(+q: Nat, +r: Nat) -> String:
  match q:
    case 0n:
      Nat.show(r)
    case 1n+p:
      Nat.show(q) ++ String.drop(Nat.show(Nat.add(r, 1000000000n)), 1n)

# a long long's text, as Redis writes one (ll2string)
def ll.show(+neg: Bool, +hi: Nat, +lo: Nat) -> String:
  match neg:
    case True{}:
      "-" ++ ll.digits(hi, lo)
    case False{}:
      ll.digits(hi, lo)

# a magnitude hi * 10^9 + lo of sign neg (lo below 10^9): a long long
# at once when hi is below 922337203 (the magnitude below 2^63), else
# when ll.in finds it one
def ll.top(below: Bool, +neg: Bool, +hi: Nat, +lo: Nat) -> LL:
  match below:
    case True{}:
      LL{neg, hi, lo}
    case False{}:
      ll.in(neg, hi, lo)

# the sum of two magnitudes of sign neg, hi * 10^9 + lo with lo below
# 2 * 10^9: its carry (c) taken, or none past a long long
def ll.add.carry(c: Bool, +neg: Bool, +hi: Nat, +lo: Nat) -> LL:
  match c:
    case False{}:
      ll.top(Nat.is_lt(hi, 922337203n), neg, hi, lo)
    case True{}:
      +h = Nat.add(hi, 1n)
      ll.top(Nat.is_lt(h, 922337203n), neg, h, Nat.sub(lo, 1000000000n))

def ll.add.same(+neg: Bool, +hi: Nat, +lo: Nat) -> LL:
  ll.add.carry(Nat.is_le(1000000000n, lo), neg, hi, lo)

# magnitude x (xh * 10^9 + xl) less y (yh, yl), x at least y, of sign
# neg (0 has none)
def ll.sub(+neg: Bool, +xh: Nat, +xl: Nat, +yh: Nat, +yl: Nat) -> LL:
  +b = Nat.is_lt(xl, yl)
  +h = Nat.sub(Nat.sub(xh, yh), Bool.pick(Nat, b, 1n, 0n))
  +l = Nat.sub(Bool.pick(Nat, b, Nat.add(xl, 1000000000n), xl), yl)
  LL{Bool.and(neg, Bool.not(Bool.and(Nat.is_eq(h, 0n), Nat.is_eq(l, 0n)))), h, l}

# a and b of signs that differ: the sign of the greater magnitude (ge:
# a's), and the difference
def ll.add.diff(ge: Bool, +an: Bool, +ah: Nat, +al: Nat, +bn: Bool, +bh: Nat, +bl: Nat) -> LL:
  match ge:
    case True{}:
      ll.sub(an, ah, al, bh, bl)
    case False{}:
      ll.sub(bn, bh, bl, ah, al)

def ll.add.of(differ: Bool, +an: Bool, +ah: Nat, +al: Nat, +bn: Bool, +bh: Nat, +bl: Nat) -> LL:
  match differ:
    case False{}:
      ll.add.same(an, Nat.add(ah, bh), Nat.add(al, bl))
    case True{}:
      ll.add.diff(ll.le(bh, bl, ah, al), an, ah, al, bn, bh, bl)

# the long long of sign an and magnitude ah * 10^9 + al, plus b: none
# past LLONG_MAX or below LLONG_MIN (Redis's check of overflow)
def ll.add(+an: Bool, +ah: Nat, +al: Nat, b: By) -> LL:
  match b:
    case ByPos{+bh, +bl}:
      ll.add.of(an, an, ah, al, False{}, bh, bl)
    case ByNeg{+bh, +bl}:
      ll.add.of(Bool.not(an), an, ah, al, True{}, bh, bl)

# an increment as the long long it is: the sum when the key is not there
def by.ll(b: By) -> LL:
  match b:
    case ByPos{hi, lo}:
      LL{False{}, hi, lo}
    case ByNeg{hi, lo}:
      LL{True{}, hi, lo}

def by.of(neg: Bool, hi: Nat, lo: Nat) -> By:
  match neg:
    case True{}:
      ByNeg{hi, lo}
    case False{}:
      ByPos{hi, lo}

# INCRBY's increment, read before the key is looked at
def parse_incrby(k: String, by: LL) -> Cmd:
  match by:
    case LL{neg, hi, lo}:
      IncrBy{k, by.of(neg, hi, lo)}
    case LLBad{}:
      Bad{e_int()}

# DECRBY's increment is by negated (0 stays ByPos{0, 0}, so that a key
# not there gets "0"): LLONG_MIN has no negation, and Redis refuses it
# before it looks at the key
def parse_decrby(k: String, by: LL) -> Cmd:
  match by:
    case LL{+neg, +hi, +lo}:
      +zero = Bool.and(Nat.is_eq(hi, 0n), Nat.is_eq(lo, 0n))
      +min = Bool.and(neg, Bool.and(Nat.is_eq(hi, dec.llmax()), Nat.is_eq(lo, 854775808n)))
      Bool.pick(Cmd, min, Bad{RError{"ERR decrement would overflow"}}, IncrBy{k, by.of(Bool.not(Bool.or(neg, zero)), hi, lo)})
    case LLBad{}:
      Bad{e_int()}

# Times
# -----
# A time a command names is a long long, read as Redis's string2ll reads
# one. Most are short: no sign, no leading zero, below 10^14 (all the
# times the append-only file holds, as PXAT and PEXPIREAT give them). A
# short one reads digit by digit as a Nat (num14), as the file's lengths
# do, and PROOF.bend shows that what Nat.show writes reads back so
# (num14_show); any other as a long long (ll.read), whose magnitude is
# kept as hi * 10^9 + lo, so that Redis's checks of overflow near 2^63
# come out exactly. A time in s counts as 1000 times as many ms. A time from 1970
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

# the long long a Dec spells, as string2ll reads one: the reader of a
# length line of the protocol that the fast one does not take (resp.bend,
# len.read). With ll.at there, the parser compiled otherwise, and SET
# took 62 instructions more a request.
def ll.of(+d: Dec, +neg: Bool) -> LL:
  match d:
    case Dec{+ok, +n, +zero, +sig, +hi, +lo}:
      +canon = Bool.or(Bool.not(zero), Bool.and(Nat.is_eq(n, 1n), Bool.not(neg)))
      +fits = dec.le(sig, hi, lo, 19n, dec.llmax(), Bool.pick(Nat, neg, 854775808n, 854775807n))
      Bool.pick(LL, Bool.and(Bool.and(Bool.and(ok, Nat.is_lt(0n, n)), canon), fits), ll.mk(neg, sig, hi, lo), LLBad{})

# CLIENT PAUSE's timeout, read as a long long after its mode, as
# getTimeoutFromObjectOrReply reads one in milliseconds
def pause.ms(l: LL, +all: Bool) -> ClOp:
  match l:
    case LL{neg, hi, lo}:
      Bool.pick(ClOp, neg, CoBad{RError{"ERR timeout is negative"}}, CoPause{hi, lo, all})
    case LLBad{}:
      CoBad{RError{"ERR timeout is not an integer or out of range"}}

def pause.mode(w: Bool, a: Bool, +t: String) -> ClOp:
  match w a:
    case True{} _:
      pause.ms(ll.read(t), False{})
    case False{} True{}:
      pause.ms(ll.read(t), True{})
    case False{} False{}:
      CoBad{RError{"ERR CLIENT PAUSE mode must be WRITE or ALL"}}

# CLIENT PAUSE timeout [WRITE|ALL]: ALL when no mode is given
def pause.of(args: List<&2, String>) -> ClOp:
  match args:
    case Con{+t, Con{+m, Nil{}}}:
      pause.mode(is_word(m, "WRITE"), is_word(m, "ALL"), t)
    case Con{+t, rest}:
      pause.ms(ll.read(t), True{})
    case Nil{}:
      CoBad{RError{"ERR syntax error"}}

# CLIENT TRACKING's option at a word: 1 REDIRECT, 2 PREFIX, 3 BCAST, 4
# OPTIN, 5 OPTOUT, 6 NOLOOP, 7 another (0: none left)
def track.kind(+args: List<&2, String>) -> Nat:
  match args:
    case Nil{}:
      0n
    case Con{+o, rest}:
      Bool.pick(Nat, is_word(o, "REDIRECT"), 1n,
      Bool.pick(Nat, is_word(o, "PREFIX"), 2n,
      Bool.pick(Nat, is_word(o, "BCAST"), 3n,
      Bool.pick(Nat, is_word(o, "OPTIN"), 4n,
      Bool.pick(Nat, is_word(o, "OPTOUT"), 5n,
      Bool.pick(Nat, is_word(o, "NOLOOP"), 6n, 7n))))))

# a REDIRECT's id (a second REDIRECT is an error of its own, before its id
# is read)
def track.redir(+second: Bool, c: Cid) -> TOpt:
  match second c:
    case True{} _:
      TrBad{RError{"ERR A client can only redirect to a single other client"}}
    case False{} CidPos{n}:
      TrRedir{n}
    case False{} CidBad{}:
      TrBad{e_int()}
    case False{} _:
      TrRedir{0n}

# the options from a word of the kind kind on (second: a REDIRECT came
# before); the parser goes on past an error, which ends what counts
def track.opts(args: List<&2, String>, +kind: Nat, +second: Bool) -> List<&2, TOpt>:
  match args kind:
    case Con{o, Con{+x, +rest}} 1n:
      track.redir(second, cid.read(x)) <> track.opts(rest, track.kind(rest), True{})
    case Con{o, Con{x, +rest}} 2n:
      TrPrefix{x} <> track.opts(rest, track.kind(rest), second)
    case Con{o, +rest} 3n:
      TrBcast{} <> track.opts(rest, track.kind(rest), second)
    case Con{o, +rest} 4n:
      TrOptin{} <> track.opts(rest, track.kind(rest), second)
    case Con{o, +rest} 5n:
      TrOptout{} <> track.opts(rest, track.kind(rest), second)
    case Con{o, +rest} 6n:
      TrNoloop{} <> track.opts(rest, track.kind(rest), second)
    case Con{o, rest} _:
      [TrBad{RError{"ERR syntax error"}}]
    case Nil{} _:
      Nil{}

def track.on(+w: String) -> Nat:
  Bool.pick(Nat, is_word(w, "ON"), 1n, Bool.pick(Nat, is_word(w, "OFF"), 0n, 2n))

# CLIENT TRACKING on|off [REDIRECT id] [BCAST] [PREFIX p ...] [OPTIN]
# [OPTOUT] [NOLOOP]
def track.of(args: List<&2, String>) -> ClOp:
  match args:
    case Con{+w, +rest}:
      CoTrack{track.on(w), track.opts(rest, track.kind(rest), False{})}
    case Nil{}:
      CoBad{RError{"ERR syntax error"}}

# CLIENT CACHING yes|no
def caching.of(args: List<&2, String>) -> ClOp:
  match args:
    case Con{+w, rest}:
      CoCaching{Bool.pick(Nat, is_word(w, "YES"), 1n, Bool.pick(Nat, is_word(w, "NO"), 0n, 2n))}
    case Nil{}:
      CoCaching{2n}

# SClient's number and arguments as the command they are: 0 LIST, 1 INFO,
# 2 KILL, 3 NO-EVICT, 4 PAUSE, 5 UNPAUSE, 6 TRACKING, 7 CACHING, 8
# GETREDIR, 9 TRACKINGINFO
def client.op(+kind: Nat, args: List<&2, String>) -> ClOp:
  match kind:
    case 0n:
      list.args(args)
    case 1n:
      CoInfo{}
    case 2n:
      kill.of(args)
    case 3n:
      no_evict.of(args)
    case 4n:
      pause.of(args)
    case 5n:
      CoUnpause{}
    case 6n:
      track.of(args)
    case 7n:
      caching.of(args)
    case 8n:
      CoGetRedir{}
    case _:
      CoTrackInfo{}

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
def w64.ushow(+a: W64) -> String:
  match a:
    case W64{+h, +l}:
      +hn = U32.to_nat(h)
      +ln = U32.to_nat(l)
      +c1 = Nat.add(Nat.mul(Nat.mod(hn, 1000000000n), 65536n), Nat.div(ln, 65536n))
      +c0 = Nat.add(Nat.mul(Nat.mod(c1, 1000000000n), 65536n), Nat.mod(ln, 65536n))
      ll.digits(Nat.add(Nat.mul(Nat.add(Nat.mul(Nat.div(hn, 1000000000n), 65536n), Nat.div(c1, 1000000000n)), 65536n), Nat.div(c0, 1000000000n)), Nat.mod(c0, 1000000000n))

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

def parse_hincrby(+k: String, +f: String, by: LL) -> Cmd:
  match by:
    case LL{neg, hi, lo}:
      Upd{k, UHash{HWIncr{f, by.of(neg, hi, lo)}}}
    case LLBad{}:
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

# SORT key [BY pattern] [LIMIT offset count] [GET pattern ...] [ASC|DESC]
# [ALPHA] [STORE destination], and SORT_RO, which takes no STORE: the
# options as Redis 7.0.15 reads them (sort.c), word by word, each word in
# any case up to its first NUL, a later one over an earlier one (a BY
# without a '*' leaves the elements in their order for good); a word it
# does not know, or one of these without the words it takes, is a syntax
# error, and a LIMIT whose numbers do not read as longs answers that at
# once. The options read so far (the GET patterns last first) and STORE's
# destination, or the error they make:
type SortSt is Data:
  SortSt{by: SortBy, off: Int, cnt: Int, gets: List<&2, String>, desc: Bool, alpha: Bool, dst: Maybe<&2, String>}
  SortErr{r: Reply}

# a word of SORT's options: 1 ASC, 2 DESC, 3 ALPHA, 4 LIMIT, 5 STORE, 6
# BY, 7 GET, 0 another
def sort.word(+w: String) -> Nat:
  +up = String.to_upper(cstr(w))
  Bool.pick(Nat, String.eq(up, "ASC"), 1n, Bool.pick(Nat, String.eq(up, "DESC"), 2n, Bool.pick(Nat, String.eq(up, "ALPHA"), 3n, Bool.pick(Nat, String.eq(up, "LIMIT"), 4n, Bool.pick(Nat, String.eq(up, "STORE"), 5n, Bool.pick(Nat, String.eq(up, "BY"), 6n, Bool.pick(Nat, String.eq(up, "GET"), 7n, 0n)))))))

def sort.head(+xs: List<&2, String>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case Con{+w, r}:
      sort.word(w)

# whether s holds a '*' before its first NUL, as strchr finds one
def sort.star(+s: String) -> Bool:
  +c = cstr(s)
  Nat.is_lt(String.find(c, '*', 0n), String.length(c))

# BY p after by: a BY without a '*' leaves the elements in their order,
# and so does any BY after it
def sort.by(by: SortBy, +p: String) -> SortBy:
  match by:
    case SByNone{}:
      SByNone{}
    case _:
      Bool.pick(SortBy, sort.star(p), SByPat{p}, SByNone{})

def sort.limit(ma: Maybe<&2, Int>, mb: Maybe<&2, Int>, by: SortBy, gs: List<&2, String>, desc: Bool, alpha: Bool, dst: Maybe<&2, String>) -> SortSt:
  match ma mb:
    case Some{a} Some{b}:
      SortSt{by, a, b, gs, desc, alpha, dst}
    case _ _:
      SortErr{e_int()}

def sort.store(ro: Bool, d: String, by: SortBy, off: Int, cnt: Int, gs: List<&2, String>, desc: Bool, alpha: Bool) -> SortSt:
  match ro:
    case True{}:
      SortErr{RError{"ERR syntax error"}}
    case False{}:
      SortSt{by, off, cnt, gs, desc, alpha, Some{d}}

# the options xs read into st; c is the first word's (sort.word); ro:
# SORT_RO's
def sort.go(xs: List<&2, String>, c: Nat, st: SortSt, +ro: Bool) -> SortSt:
  match xs c st:
    case _ _ SortErr{r}:
      SortErr{r}
    case Nil{} _ s:
      s
    case Con{w, +rest} 1n SortSt{by, off, cnt, gs, desc, alpha, dst}:
      sort.go(rest, sort.head(rest), SortSt{by, off, cnt, gs, False{}, alpha, dst}, ro)
    case Con{w, +rest} 2n SortSt{by, off, cnt, gs, desc, alpha, dst}:
      sort.go(rest, sort.head(rest), SortSt{by, off, cnt, gs, True{}, alpha, dst}, ro)
    case Con{w, +rest} 3n SortSt{by, off, cnt, gs, desc, alpha, dst}:
      sort.go(rest, sort.head(rest), SortSt{by, off, cnt, gs, desc, True{}, dst}, ro)
    case Con{w, Con{+a, Con{+b, +rest}}} 4n SortSt{by, off, cnt, gs, desc, alpha, dst}:
      sort.go(rest, sort.head(rest), sort.limit(lnum(a), lnum(b), by, gs, desc, alpha, dst), ro)
    case Con{w, Con{d, +rest}} 5n SortSt{by, off, cnt, gs, desc, alpha, dst}:
      sort.go(rest, sort.head(rest), sort.store(ro, d, by, off, cnt, gs, desc, alpha), ro)
    case Con{w, Con{+p, +rest}} 6n SortSt{by, off, cnt, gs, desc, alpha, dst}:
      sort.go(rest, sort.head(rest), SortSt{sort.by(by, p), off, cnt, gs, desc, alpha, dst}, ro)
    case Con{w, Con{p, +rest}} 7n SortSt{by, off, cnt, gs, desc, alpha, dst}:
      sort.go(rest, sort.head(rest), SortSt{by, off, cnt, p <> gs, desc, alpha, dst}, ro)
    case _ _ _:
      SortErr{RError{"ERR syntax error"}}

# the command the options make: a read (Sort), or SORT with STORE
def sort.cmd(st: SortSt, k: String) -> Cmd:
  match st:
    case SortErr{r}:
      Bad{r}
    case SortSt{by, off, cnt, gs, desc, alpha, None{}}:
      Sort{k, SortO{by, off, cnt, List.reverse(&2, String, gs), desc, alpha}}
    case SortSt{by, off, cnt, gs, desc, alpha, Some{d}}:
      Own{SSortStore{k, SortStore{d, SortO{by, off, cnt, List.reverse(&2, String, gs), desc, alpha}}}}

def parse_sort(args: List<&2, String>, +ro: Bool, name: String) -> Cmd:
  match args:
    case Con{k, +rest}:
      sort.cmd(sort.go(rest, sort.head(rest), SortSt{SByElem{}, IPos{0n}, INeg{0n}, Nil{}, False{}, False{}, None{}}, ro), k)
    case Nil{}:
      e_arity(name)

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

# GEO
# ---
# GEO keeps positions in a sorted set, each member's score its geohash
# (geo.bend: as Redis 7.0.15's geo.c, geohash.c and geohash_helper.c
# compute them, in C's doubles). GEOADD is ZADD of the scores its
# positions make (geoaddCommand calls zaddCommand), its options and
# positions read as it parses, each error as Redis answers it. GEOPOS,
# GEOHASH and GEODIST read the sorted set of their key (ZRGeoPos,
# ZRGeoHash and ZRGeoDist, a Peek), GEODIST's unit read as it parses. The searches (GEORADIUS,
# GEORADIUSBYMEMBER, their _RO forms and GEOSEARCH) read theirs too,
# their arguments read as georadiusGeneric reads them once it has looked
# the key up (ZRGeoFind): the center (a member's position, which only the
# key holds), the shape and the options. A search that stores (STORE and
# STOREDIST of GEORADIUS and GEORADIUSBYMEMBER, GEOSEARCHSTORE) is
# SGeoStore, which writes what it finds at its destination as an act of
# the session's database (AGeo, below), as SORT with STORE does.

def e_syntax_r() -> Reply:
  RError{"ERR syntax error"}

def e_unit() -> Reply:
  RError{"ERR unsupported unit provided. please use M, KM, FT, MI"}

# extractUnitOrReply: the meters of a unit, M, KM, FT or MI in any case
# (1, 1000, 0.3048 and 1609.34 as doubles)
def geo.unit(+u: String) -> Maybe<&2, G.D>:
  +up = String.to_upper(cstr(u))
  Bool.pick(Maybe<&2, G.D>, String.eq(up, "M"), Some{G.D{1072693248, 0}},
    Bool.pick(Maybe<&2, G.D>, String.eq(up, "KM"), Some{G.D{1083129856, 0}},
      Bool.pick(Maybe<&2, G.D>, String.eq(up, "FT"), Some{G.D{1070825943, 3690235901}},
        Bool.pick(Maybe<&2, G.D>, String.eq(up, "MI"), Some{G.D{1083778396, 687194767}}, None{}))))

# a position read: the point, or the error that answers it
type GPt is Data:
  GPtOk{p: G.Pos}
  GPtErr{r: Reply}

# printf's "%f" of a double (the error of a position out of range)
def geo.f6(+x: G.D) -> String:
  F.fl.show_f(F.f64.to(G.d.score(x)))

def geo.lonlat.at(bad: Bool, out: Bool, +lon: G.D, +lat: G.D) -> GPt:
  match bad out:
    case True{} _:
      GPtErr{RError{"ERR value is not a valid float"}}
    case False{} True{}:
      GPtErr{RError{"ERR invalid longitude,latitude pair " ++ geo.f6(lon) ++ "," ++ geo.f6(lat)}}
    case False{} False{}:
      GPtOk{G.Pos{lon, lat}}

# extractLongLatOrReply: a longitude and a latitude, each a float (as
# string2d reads one), within Redis's ranges (-180 to 180, and
# -85.05112878 to 85.05112878)
def geo.lonlat(+a: String, +b: String) -> GPt:
  +lon = G.d.read(a)
  +lat = G.d.read(b)
  geo.lonlat.at(Bool.or(G.d.is_nan(lon), G.d.is_nan(lat)), Bool.or(G.rng.out(G.geo.lon_rng(), lon), G.rng.out(G.geo.lat_rng(), lat)), lon, lat)

# a shape read (a radius, or a box's width and height) and the meters of
# its unit, or the error that answers it
type GDst is Data:
  GDstOk{s: G.Shape, conv: G.D}
  GDstErr{r: Reply}

def geo.radius.at(bad: Bool, neg: Bool, u: Maybe<&2, G.D>, +r: G.D) -> GDst:
  match bad neg u:
    case True{} _ _:
      GDstErr{RError{"ERR need numeric radius"}}
    case False{} True{} _:
      GDstErr{RError{"ERR radius cannot be negative"}}
    case False{} False{} None{}:
      GDstErr{e_unit()}
    case False{} False{} Some{c}:
      GDstOk{G.Circle{r}, c}

# extractDistanceOrReply: a radius (a float, not negative), then its unit
def geo.radius(+a: String, +u: String) -> GDst:
  +r = G.d.read(a)
  geo.radius.at(G.d.is_nan(r), G.d.lt(r, G.d.zero()), geo.unit(u), r)

def geo.box.at(bw: Bool, bh: Bool, neg: Bool, u: Maybe<&2, G.D>, +w: G.D, +h: G.D) -> GDst:
  match bw bh neg u:
    case True{} _ _ _:
      GDstErr{RError{"ERR need numeric width"}}
    case False{} True{} _ _:
      GDstErr{RError{"ERR need numeric height"}}
    case False{} False{} True{} _:
      GDstErr{RError{"ERR height or width cannot be negative"}}
    case False{} False{} False{} None{}:
      GDstErr{e_unit()}
    case False{} False{} False{} Some{c}:
      GDstOk{G.Box{w, h}, c}

# extractBoxOrReply: a width and a height (floats, not negative), then
# their unit
def geo.box(+a: String, +b: String, +u: String) -> GDst:
  +w = G.d.read(a)
  +h = G.d.read(b)
  geo.box.at(G.d.is_nan(w), G.d.is_nan(h), Bool.or(G.d.lt(h, G.d.zero()), G.d.lt(w, G.d.zero())), geo.unit(u), w, h)

# A search's options, as georadiusGeneric reads them: WITHDIST, WITHHASH,
# WITHCOORD, ANY, the order (0 none, 1 ASC, 2 DESC), COUNT (0 none; a
# count past 10^14, which no sorted set reaches, as 10^14), the
# destination of STORE or STOREDIST, whether the distances are stored
# (STOREDIST), whether FROMMEMBER, FROMLONLAT, BYRADIUS and BYBOX came,
# and the center, the shape and the meters of its unit. GOptOf, options
# that hold options, is never built: it makes GOpt a type that holds
# itself, which the compiler makes a node of its own, so that it travels
# as one word; flat, it would be 24 words in the results of the options'
# loop, and the widest result sets what every return of the program
# copies (WL_RESW: 26 words where it is 17).
type GOpt is Data:
  GOpt{wd: Bool, wh: Bool, wc: Bool, any: Bool, sort: Nat, count: Nat, store: Maybe<&2, String>, sdist: Bool, fm: Bool, fl: Bool, br: Bool, bb: Bool, ctr: G.Pos, shp: G.Shape, conv: G.D}
  GOptOf{o: GOpt}

# the options before any word: the center, the shape and its unit's
# meters those of GEORADIUS and GEORADIUSBYMEMBER, read first
def gopt.shape(p: G.Pos, s: G.Shape, c: G.D) -> GOpt:
  GOpt{False{}, False{}, False{}, False{}, 0n, 0n, None{}, False{}, False{}, False{}, False{}, False{}, p, s, c}

def gopt.new() -> GOpt:
  gopt.shape(G.Pos{G.d.zero(), G.d.zero()}, G.Circle{G.d.zero()}, G.d.zero())

# o with the flag of word c: 1 WITHDIST, 2 WITHHASH, 3 WITHCOORD, 4 ANY,
# 5 ASC, 6 DESC
def gopt.word(c: Nat, o: GOpt) -> GOpt:
  match c o:
    case 1n GOpt{wd, wh, wc, any, sort, count, store, sdist, fm, fl, br, bb, ctr, shp, conv}:
      GOpt{True{}, wh, wc, any, sort, count, store, sdist, fm, fl, br, bb, ctr, shp, conv}
    case 2n GOpt{wd, wh, wc, any, sort, count, store, sdist, fm, fl, br, bb, ctr, shp, conv}:
      GOpt{wd, True{}, wc, any, sort, count, store, sdist, fm, fl, br, bb, ctr, shp, conv}
    case 3n GOpt{wd, wh, wc, any, sort, count, store, sdist, fm, fl, br, bb, ctr, shp, conv}:
      GOpt{wd, wh, True{}, any, sort, count, store, sdist, fm, fl, br, bb, ctr, shp, conv}
    case 4n GOpt{wd, wh, wc, any, sort, count, store, sdist, fm, fl, br, bb, ctr, shp, conv}:
      GOpt{wd, wh, wc, True{}, sort, count, store, sdist, fm, fl, br, bb, ctr, shp, conv}
    case 5n GOpt{wd, wh, wc, any, sort, count, store, sdist, fm, fl, br, bb, ctr, shp, conv}:
      GOpt{wd, wh, wc, any, 1n, count, store, sdist, fm, fl, br, bb, ctr, shp, conv}
    case 6n GOpt{wd, wh, wc, any, sort, count, store, sdist, fm, fl, br, bb, ctr, shp, conv}:
      GOpt{wd, wh, wc, any, 2n, count, store, sdist, fm, fl, br, bb, ctr, shp, conv}
    case _ x:
      x

def gopt.count(+n: Nat, o: GOpt) -> GOpt:
  match o:
    case GOpt{wd, wh, wc, any, sort, count, store, sdist, fm, fl, br, bb, ctr, shp, conv}:
      GOpt{wd, wh, wc, any, sort, n, store, sdist, fm, fl, br, bb, ctr, shp, conv}
    case GOptOf{x}:
      gopt.count(n, x)

def gopt.store(k: String, dist: Bool, o: GOpt) -> GOpt:
  match o:
    case GOpt{wd, wh, wc, any, sort, count, store, sdist, fm, fl, br, bb, ctr, shp, conv}:
      GOpt{wd, wh, wc, any, sort, count, Some{k}, dist, fm, fl, br, bb, ctr, shp, conv}
    case GOptOf{x}:
      gopt.store(k, dist, x)

def gopt.sdist(o: GOpt) -> GOpt:
  match o:
    case GOpt{wd, wh, wc, any, sort, count, store, sdist, fm, fl, br, bb, ctr, shp, conv}:
      GOpt{wd, wh, wc, any, sort, count, store, True{}, fm, fl, br, bb, ctr, shp, conv}
    case GOptOf{x}:
      gopt.sdist(x)

def gopt.at(m: Maybe<&2, G.Pos>, c: G.Pos) -> G.Pos:
  match m:
    case Some{p}:
      p
    case None{}:
      c

# FROMMEMBER (mem) or FROMLONLAT: the center, when it is known
def gopt.from(m: Maybe<&2, G.Pos>, +mem: Bool, o: GOpt) -> GOpt:
  match o:
    case GOpt{wd, wh, wc, any, sort, count, store, sdist, +fm, +fl, br, bb, ctr, shp, conv}:
      GOpt{wd, wh, wc, any, sort, count, store, sdist, Bool.or(fm, mem), Bool.or(fl, Bool.not(mem)), br, bb, gopt.at(m, ctr), shp, conv}
    case GOptOf{x}:
      gopt.from(m, mem, x)

# BYBOX (box) or BYRADIUS: the shape and its unit's meters
def gopt.by(s: G.Shape, c: G.D, +box: Bool, o: GOpt) -> GOpt:
  match o:
    case GOpt{wd, wh, wc, any, sort, count, store, sdist, fm, fl, +br, +bb, ctr, shp, conv}:
      GOpt{wd, wh, wc, any, sort, count, store, sdist, fm, fl, Bool.or(br, Bool.not(box)), Bool.or(bb, box), ctr, s, c}
    case GOptOf{x}:
      gopt.by(s, c, box, x)

def gopt.fm(+o: GOpt) -> Bool:
  match o:
    case GOpt{wd, wh, wc, any, sort, count, store, sdist, +fm, fl, br, bb, ctr, shp, conv}:
      fm
    case GOptOf{x}:
      gopt.fm(x)

def gopt.fl(+o: GOpt) -> Bool:
  match o:
    case GOpt{wd, wh, wc, any, sort, count, store, sdist, fm, +fl, br, bb, ctr, shp, conv}:
      fl
    case GOptOf{x}:
      gopt.fl(x)

def gopt.br(+o: GOpt) -> Bool:
  match o:
    case GOpt{wd, wh, wc, any, sort, count, store, sdist, fm, fl, +br, bb, ctr, shp, conv}:
      br
    case GOptOf{x}:
      gopt.br(x)

def gopt.bb(+o: GOpt) -> Bool:
  match o:
    case GOpt{wd, wh, wc, any, sort, count, store, sdist, fm, fl, br, +bb, ctr, shp, conv}:
      bb
    case GOptOf{x}:
      gopt.bb(x)

# the loop of the options: the words left and the options so far, or the
# error that ends it
type GSt is Data:
  GGo{xs: List<&2, String>, o: GOpt}
  GErr{r: Reply}

# a word of the options (strcasecmp's, up to a NUL): 1 WITHDIST, 2
# WITHHASH, 3 WITHCOORD, 4 ANY, 5 ASC, 6 DESC, 7 COUNT, 8 STORE, 9
# STOREDIST, 10 FROMMEMBER, 11 FROMLONLAT, 12 BYRADIUS, 13 BYBOX, 0
# another
def geo.word(+w: String) -> Nat:
  +up = String.to_upper(cstr(w))
  Bool.pick(Nat, String.eq(up, "WITHDIST"), 1n, Bool.pick(Nat, String.eq(up, "WITHHASH"), 2n,
    Bool.pick(Nat, String.eq(up, "WITHCOORD"), 3n, Bool.pick(Nat, String.eq(up, "ANY"), 4n,
      Bool.pick(Nat, String.eq(up, "ASC"), 5n, Bool.pick(Nat, String.eq(up, "DESC"), 6n,
        Bool.pick(Nat, String.eq(up, "COUNT"), 7n, Bool.pick(Nat, String.eq(up, "STORE"), 8n,
          Bool.pick(Nat, String.eq(up, "STOREDIST"), 9n, Bool.pick(Nat, String.eq(up, "FROMMEMBER"), 10n,
            Bool.pick(Nat, String.eq(up, "FROMLONLAT"), 11n, Bool.pick(Nat, String.eq(up, "BYRADIUS"), 12n,
              Bool.pick(Nat, String.eq(up, "BYBOX"), 13n, 0n)))))))))))))

# A search's kind, as georadiusGeneric's flags: 0 GEORADIUS
# (RADIUS_COORDS), 1 GEORADIUS_RO (with RADIUS_NOSTORE), 2
# GEORADIUSBYMEMBER (RADIUS_MEMBER), 3 GEORADIUSBYMEMBER_RO, 4 GEOSEARCH
# (GEOSEARCH), 5 GEOSEARCHSTORE (with GEOSEARCHSTORE)

# whether STORE and STOREDIST take a key (GEORADIUS, GEORADIUSBYMEMBER)
def geo.kstore(+kind: Nat) -> Bool:
  Bool.or(Nat.is_eq(kind, 0n), Nat.is_eq(kind, 2n))

# whether FROMMEMBER, FROMLONLAT, BYRADIUS and BYBOX are its options
def geo.ksearch(+kind: Nat) -> Bool:
  Nat.is_le(4n, kind)

# a count of hi * 10^9 + lo, 10^14 when it is past that
def geo.count.n(big: Bool, +hi: Nat, +lo: Nat) -> Nat:
  match big:
    case True{}:
      Nat.mul(100000n, 1000000000n)
    case False{}:
      Nat.add(Nat.mul(hi, 1000000000n), lo)

# COUNT n: a long long past 0
def geo.count.pos(bad: Bool, +hi: Nat, +lo: Nat, more: List<&2, String>, o: GOpt) -> GSt:
  match bad:
    case True{}:
      GErr{RError{"ERR COUNT must be > 0"}}
    case False{}:
      GGo{more, gopt.count(geo.count.n(Nat.is_le(100000n, hi), hi, lo), o)}

def geo.count.of(l: LL, more: List<&2, String>, o: GOpt) -> GSt:
  match l:
    case LL{+neg, +hi, +lo}:
      geo.count.pos(Bool.or(neg, Bool.and(Nat.is_eq(hi, 0n), Nat.is_eq(lo, 0n))), hi, lo, more, o)
    case LLBad{}:
      GErr{e_int()}

def geo.count(rest: List<&2, String>, o: GOpt) -> GSt:
  match rest:
    case Con{+n, more}:
      geo.count.of(ll.read(n), more, o)
    case Nil{}:
      GErr{e_syntax_r()}

# STORE key (ok: the kind takes it)
def geo.store(ok: Bool, rest: List<&2, String>, o: GOpt) -> GSt:
  match ok rest:
    case True{} Con{k, more}:
      GGo{more, gopt.store(k, False{}, o)}
    case _ _:
      GErr{e_syntax_r()}

# STOREDIST key, or GEOSEARCHSTORE's STOREDIST alone (ss)
def geo.sdist(ss: Bool, rest: List<&2, String>, o: GOpt) -> GSt:
  match ss:
    case True{}:
      GGo{rest, gopt.sdist(o)}
    case False{}:
      GErr{e_syntax_r()}

def geo.storedist(ok: Bool, +ss: Bool, rest: List<&2, String>, o: GOpt) -> GSt:
  match ok rest:
    case True{} Con{k, more}:
      GGo{more, gopt.store(k, True{}, o)}
    case _ ys:
      geo.sdist(ss, ys, o)

# FROMMEMBER m: the member's position (none read when the key is not
# there, as Redis goes on to answer the rest)
def geo.fm.pos(s: Maybe<&2, F.F64>, more: List<&2, String>, o: GOpt) -> GSt:
  match s:
    case Some{+sc}:
      GGo{more, gopt.from(Some{G.geo.pos(G.d.of_score(sc))}, True{}, o)}
    case None{}:
      GErr{RError{"ERR could not decode requested zset member"}}

def geo.fm.at(z: Maybe<&2, KV.Zset>, +m: String, more: List<&2, String>, o: GOpt) -> GSt:
  match z:
    case None{}:
      GGo{more, gopt.from(None{}, True{}, o)}
    case Some{+zz}:
      geo.fm.pos(KV.zset.score(m, zz), more, o)

def geo.frommember(ok: Bool, rest: List<&2, String>, o: GOpt, +z: Maybe<&2, KV.Zset>) -> GSt:
  match ok rest:
    case True{} Con{+m, more}:
      geo.fm.at(z, m, more, o)
    case _ _:
      GErr{e_syntax_r()}

def geo.fl.at(p: GPt, more: List<&2, String>, o: GOpt) -> GSt:
  match p:
    case GPtOk{x}:
      GGo{more, gopt.from(Some{x}, False{}, o)}
    case GPtErr{r}:
      GErr{r}

def geo.fromlonlat(ok: Bool, rest: List<&2, String>, o: GOpt) -> GSt:
  match ok rest:
    case True{} Con{+a, Con{+b, more}}:
      geo.fl.at(geo.lonlat(a, b), more, o)
    case _ _:
      GErr{e_syntax_r()}

def geo.by.at(d: GDst, +box: Bool, more: List<&2, String>, o: GOpt) -> GSt:
  match d:
    case GDstOk{s, c}:
      GGo{more, gopt.by(s, c, box, o)}
    case GDstErr{r}:
      GErr{r}

def geo.byradius(ok: Bool, rest: List<&2, String>, o: GOpt) -> GSt:
  match ok rest:
    case True{} Con{+r, Con{+u, more}}:
      geo.by.at(geo.radius(r, u), False{}, more, o)
    case _ _:
      GErr{e_syntax_r()}

def geo.bybox(ok: Bool, rest: List<&2, String>, o: GOpt) -> GSt:
  match ok rest:
    case True{} Con{+w, Con{+h, Con{+u, more}}}:
      geo.by.at(geo.box(w, h, u), True{}, more, o)
    case _ _:
      GErr{e_syntax_r()}

# a word of the options (its code c) and those after it: each where the
# kind takes it and the words it takes follow, else a syntax error
def geo.step(c: Nat, rest: List<&2, String>, +o: GOpt, +kind: Nat, +z: Maybe<&2, KV.Zset>) -> GSt:
  match c:
    case 0n:
      GErr{e_syntax_r()}
    case 1n:
      GGo{rest, gopt.word(1n, o)}
    case 2n:
      GGo{rest, gopt.word(2n, o)}
    case 3n:
      GGo{rest, gopt.word(3n, o)}
    case 4n:
      GGo{rest, gopt.word(4n, o)}
    case 5n:
      GGo{rest, gopt.word(5n, o)}
    case 6n:
      GGo{rest, gopt.word(6n, o)}
    case 7n:
      geo.count(rest, o)
    case 8n:
      geo.store(geo.kstore(kind), rest, o)
    case 9n:
      geo.storedist(geo.kstore(kind), Nat.is_eq(kind, 5n), rest, o)
    case 10n:
      geo.frommember(Bool.and(geo.ksearch(kind), Bool.not(gopt.fl(o))), rest, o, z)
    case 11n:
      geo.fromlonlat(Bool.and(geo.ksearch(kind), Bool.not(gopt.fm(o))), rest, o)
    case 12n:
      geo.byradius(Bool.and(geo.ksearch(kind), Bool.not(gopt.bb(o))), rest, o)
    case 13n:
      geo.bybox(Bool.and(geo.ksearch(kind), Bool.not(gopt.br(o))), rest, o)
    case _:
      GErr{e_syntax_r()}

# the loop of the options, a word at a time (fuel: the words)
def geo.loop(fuel: Nat, st: GSt, +kind: Nat, +z: Maybe<&2, KV.Zset>) -> GSt:
  match fuel st:
    case 1n+f GGo{Con{+w, rest}, o}:
      geo.loop(f, geo.step(geo.word(w), rest, o, kind, z), kind, z)
    case _ x:
      x

# GEORADIUS's and GEORADIUSBYMEMBER's circle, read before the options
def geo.circle(d: GDst, p: G.Pos, opts: List<&2, String>) -> GSt:
  match d:
    case GDstOk{s, c}:
      GGo{opts, gopt.shape(p, s, c)}
    case GDstErr{r}:
      GErr{r}

def geo.pre.xy.of(p: GPt, +r: String, +u: String, opts: List<&2, String>) -> GSt:
  match p:
    case GPtOk{x}:
      geo.circle(geo.radius(r, u), x, opts)
    case GPtErr{e}:
      GErr{e}

# GEORADIUS key lon lat radius unit: the center, then the radius
def geo.pre.xy(args: List<&2, String>) -> GSt:
  match args:
    case Con{k, Con{+lon, Con{+lat, Con{+r, Con{+u, opts}}}}}:
      geo.pre.xy.of(geo.lonlat(lon, lat), r, u, opts)
    case _:
      GErr{e_syntax_r()}

def geo.pre.m.of(s: Maybe<&2, F.F64>, +r: String, +u: String, opts: List<&2, String>) -> GSt:
  match s:
    case Some{+sc}:
      geo.circle(geo.radius(r, u), G.geo.pos(G.d.of_score(sc)), opts)
    case None{}:
      GErr{RError{"ERR could not decode requested zset member"}}

def geo.pre.m.at(z: Maybe<&2, KV.Zset>, +m: String, +r: String, +u: String, opts: List<&2, String>) -> GSt:
  match z:
    case None{}:
      GGo{opts, gopt.new()}
    case Some{+zz}:
      geo.pre.m.of(KV.zset.score(m, zz), r, u, opts)

# GEORADIUSBYMEMBER key member radius unit: the member's position, then
# the radius; neither read when the key is not there
def geo.pre.m(args: List<&2, String>, +z: Maybe<&2, KV.Zset>) -> GSt:
  match args:
    case Con{k, Con{+m, Con{+r, Con{+u, opts}}}}:
      geo.pre.m.at(z, m, r, u, opts)
    case _:
      GErr{e_syntax_r()}

# GEOSEARCH key
def geo.pre.s(args: List<&2, String>) -> GSt:
  match args:
    case Con{k, opts}:
      GGo{opts, gopt.new()}
    case Nil{}:
      GErr{e_syntax_r()}

# GEOSEARCHSTORE dst src: its destination first
def geo.pre.ss(args: List<&2, String>) -> GSt:
  match args:
    case Con{d, Con{s, opts}}:
      GGo{opts, gopt.store(d, False{}, gopt.new())}
    case _:
      GErr{e_syntax_r()}

def geo.pre(kind: Nat, args: List<&2, String>, +z: Maybe<&2, KV.Zset>) -> GSt:
  match kind:
    case 0n:
      geo.pre.xy(args)
    case 1n:
      geo.pre.xy(args)
    case 2n:
      geo.pre.m(args, z)
    case 3n:
      geo.pre.m(args, z)
    case 4n:
      geo.pre.s(args)
    case _:
      geo.pre.ss(args)

# the checks after the options, in Redis's order: STORE with WITHDIST,
# WITHHASH or WITHCOORD (1); GEOSEARCH without FROMMEMBER or FROMLONLAT
# (2), or without BYRADIUS or BYBOX (3); ANY without COUNT (4); 0 none
def geo.post.code(+kind: Nat, +o: GOpt) -> Nat:
  match o:
    case GOpt{+wd, +wh, +wc, +any, sort, +count, +store, sdist, +fm, +fl, +br, +bb, ctr, shp, conv}:
      +srch = geo.ksearch(kind)
      Bool.pick(Nat, Bool.and(Maybe.is_some(&2, String, store), Bool.or(wd, Bool.or(wh, wc))), 1n,
        Bool.pick(Nat, Bool.and(srch, Bool.not(Bool.or(fm, fl))), 2n,
          Bool.pick(Nat, Bool.and(srch, Bool.not(Bool.or(br, bb))), 3n,
            Bool.pick(Nat, Bool.and(any, Nat.is_eq(count, 0n)), 4n, 0n))))
    case GOptOf{x}:
      geo.post.code(kind, x)

def geo.post.err(c: Nat, +kind: Nat, +name: String, o: GOpt) -> GSt:
  match c:
    case 0n:
      GGo{Nil{}, o}
    case 1n:
      GErr{RError{"ERR " ++ Bool.pick(String, Nat.is_eq(kind, 5n), "GEOSEARCHSTORE", "STORE option in GEORADIUS") ++ " is not compatible with WITHDIST, WITHHASH and WITHCOORD options"}}
    case 2n:
      GErr{RError{"ERR exactly one of FROMMEMBER or FROMLONLAT can be specified for " ++ name}}
    case 3n:
      GErr{RError{"ERR exactly one of BYRADIUS and BYBOX can be specified for " ++ name}}
    case _:
      GErr{RError{"ERR the ANY argument requires COUNT argument"}}

def geo.post(st: GSt, +kind: Nat, +name: String) -> GSt:
  match st:
    case GGo{xs, +o}:
      geo.post.err(geo.post.code(kind, o), kind, name, o)
    case GErr{r}:
      GErr{r}

# What a search finds: the error it answers, nothing for a key not there
# (its options say what it answers), or the points it answers, sorted as
# asked and cut to COUNT
type GFound is Data:
  GFErr{r: Reply}
  GFNone{o: GOpt}
  GFPts{o: GOpt, ps: List<&2, G.GP>}

def geo.cut(full: Bool, ps: List<&2, G.GP>, +n: Nat, +k: Nat, +desc: Bool) -> List<&2, G.GP>:
  match full:
    case True{}:
      G.geo.sort(ps, n, desc)
    case False{}:
      List.take(&2, G.GP, G.geo.psort(ps, n, k, desc), k)

# the n points found, sorted as asked (0: not sorted), k of them kept: by
# glibc's qsort when all are kept, by Redis's pqsort when COUNT keeps
# fewer
def geo.order(srt: Nat, ps: List<&2, G.GP>, +n: Nat, +k: Nat) -> List<&2, G.GP>:
  match srt:
    case 0n:
      ps
    case 1n:
      geo.cut(Nat.is_eq(k, n), ps, n, k, False{})
    case _:
      geo.cut(Nat.is_eq(k, n), ps, n, k, True{})

# COUNT without an order and without ANY sorts ASC
def geo.kept(+o: GOpt, +ps: List<&2, G.GP>) -> List<&2, G.GP>:
  match o:
    case GOpt{wd, wh, wc, +any, +sort, +count, store, sdist, fm, fl, br, bb, ctr, shp, conv}:
      +n = List.length(&2, G.GP, ps)
      +k = Bool.pick(Nat, Bool.or(Nat.is_eq(count, 0n), Nat.is_lt(n, count)), n, count)
      geo.order(Bool.pick(Nat, Bool.and(Bool.and(Nat.is_lt(0n, count), Nat.is_eq(sort, 0n)), Bool.not(any)), 1n, sort), ps, n, k)
    case GOptOf{x}:
      geo.kept(x, ps)

# membersOfAllNeighbors's points (ANY: up to COUNT of them)
def geo.scan(+o: GOpt, +z: KV.Zset) -> List<&2, G.GP>:
  match o:
    case GOpt{wd, wh, wc, +any, sort, +count, store, sdist, fm, fl, br, bb, +ctr, +shp, +conv}:
      G.geo.search(z, G.Search{G.pos.lon(ctr), G.pos.lat(ctr), shp, conv}, Bool.pick(Nat, any, count, 0n))
    case GOptOf{x}:
      geo.scan(x, z)

def geo.found.at(st: GSt, z: Maybe<&2, KV.Zset>) -> GFound:
  match st z:
    case GErr{r} _:
      GFErr{r}
    case GGo{xs, o} None{}:
      GFNone{o}
    case GGo{xs, +o} Some{+zz}:
      GFPts{o, geo.kept(o, geo.scan(o, zz))}

# a search of a kind on the sorted set z (None: its key is not there),
# its arguments args (the name it was called by first), as
# georadiusGeneric runs it once the key's type is checked
def geo.found(+kind: Nat, args: List<&2, String>, +z: Maybe<&2, KV.Zset>) -> GFound:
  match args:
    case Con{+name, +rest}:
      geo.found.at(geo.post(geo.loop(Nat.add(List.length(&2, String, rest), 1n), geo.pre(kind, rest, z), kind, z), kind, name), z)
    case Nil{}:
      GFErr{e_syntax_r()}

# A point as a search answers it: its member, or, with WITHDIST, WITHHASH
# or WITHCOORD, an array of it and its distance (in the unit, with four
# decimals: addReplyDoubleDistance), its score (an integer) and its
# position (addReplyHumanLongDouble's: a double in RESP3)
def geo.w.dist(on: Bool, +dist: G.D, +conv: G.D, rest: List<&2, Reply>) -> List<&2, Reply>:
  match on:
    case True{}:
      RBulk{G.geo.dist_text(G.d.div(dist, conv))} <> rest
    case False{}:
      rest

def geo.w.hash(on: Bool, +sc: G.D, rest: List<&2, Reply>) -> List<&2, Reply>:
  match on:
    case True{}:
      RIntS{G.geo.hash_int(sc)} <> rest
    case False{}:
      rest

def geo.w.coord(on: Bool, +lon: G.D, +lat: G.D, rest: List<&2, Reply>) -> List<&2, Reply>:
  match on:
    case True{}:
      RArray{[RDbl{G.geo.coord_text(lon)}, RDbl{G.geo.coord_text(lat)}]} <> rest
    case False{}:
      rest

def geo.item(any: Bool, +wd: Bool, +wh: Bool, +wc: Bool, +conv: G.D, p: G.GP) -> Reply:
  match any p:
    case False{} G.GP{m, lon, lat, dist, sc}:
      RBulk{m}
    case True{} G.GP{m, +lon, +lat, +dist, +sc}:
      RArray{RBulk{m} <> geo.w.dist(wd, dist, conv, geo.w.hash(wh, sc, geo.w.coord(wc, lon, lat, Nil{})))}

def geo.items(ps: List<&2, G.GP>, +any: Bool, +wd: Bool, +wh: Bool, +wc: Bool, +conv: G.D) -> List<&2, Reply>:
  match ps:
    case Nil{}:
      Nil{}
    case Con{p, rest}:
      geo.item(any, wd, wh, wc, conv, p) <> geo.items(rest, any, wd, wh, wc, conv)

def geo.reply.of(+o: GOpt, ps: List<&2, G.GP>) -> Reply:
  match o:
    case GOpt{+wd, +wh, +wc, any, sort, count, store, sdist, fm, fl, br, bb, ctr, shp, +conv}:
      RArray{geo.items(ps, Bool.or(wd, Bool.or(wh, wc)), wd, wh, wc, conv)}
    case GOptOf{x}:
      geo.reply.of(x, ps)

# a search's reply (with no STORE): its error, an empty array for a key
# not there, or its points
def geo.reply(f: GFound) -> Reply:
  match f:
    case GFErr{r}:
      r
    case GFNone{o}:
      RArray{Nil{}}
    case GFPts{+o, ps}:
      geo.reply.of(o, ps)

# a STORE's reply: how many points it stores (0 for a key not there), or
# its error
def geo.stored(f: GFound) -> Reply:
  match f:
    case GFErr{r}:
      r
    case GFNone{o}:
      r_int(0n)
    case GFPts{o, ps}:
      r_int(List.length(&2, G.GP, ps))

# the pairs a STORE's ZADD takes: each point's score (STOREDIST: its
# distance in the unit), as Redis writes a double, and its member
def geo.pairs(ps: List<&2, G.GP>, +sdist: Bool, +conv: G.D) -> List<&2, ZPair>:
  match ps:
    case Nil{}:
      Nil{}
    case Con{G.GP{m, lon, lat, +dist, +sc}, rest}:
      ZPair{F.f64.show(G.d.score(Bool.pick(G.D, sdist, G.d.div(dist, conv), sc))), m} <> geo.pairs(rest, sdist, conv)

def geo.put(m: Maybe<&2, String>, ps: List<&2, ZPair>) -> Cmd:
  match m ps:
    case Some{d} Nil{}:
      Del{[d]}
    case Some{d} Con{p, rest}:
      Upd{d, UZset{ZWNew{zopts.none(), Con{p, rest}}}}
    case None{} _:
      Bad{r_int(0n)}

def geo.put.of(+o: GOpt, ps: List<&2, G.GP>) -> Cmd:
  match o:
    case GOpt{wd, wh, wc, any, sort, count, +store, +sdist, fm, fl, br, bb, ctr, shp, +conv}:
      geo.put(store, geo.pairs(ps, sdist, conv))
    case GOptOf{x}:
      geo.put.of(x, ps)

# a STORE's write of its destination: the sorted set of the points it
# finds, whatever the key held, with no time (setKey), or the DEL of the
# destination when it finds none or its key is not there (dbDelete); an
# error writes nothing
def geo.write(f: GFound) -> Cmd:
  match f:
    case GFErr{r}:
      Bad{r}
    case GFNone{+o}:
      geo.put.of(o, Nil{})
    case GFPts{+o, ps}:
      geo.put.of(o, ps)

# GEOPOS, GEOHASH and GEODIST of a member's score (none when the member
# is not there: a null array, a null, and a null for either of GEODIST's)
def geo.pos.reply(+p: G.Pos) -> Reply:
  RArray{[RDbl{G.geo.coord_text(G.pos.lon(p))}, RDbl{G.geo.coord_text(G.pos.lat(p))}]}

def geo.pos.of(s: Maybe<&2, F.F64>) -> Reply:
  match s:
    case Some{+sc}:
      geo.pos.reply(G.geo.pos(G.d.of_score(sc)))
    case None{}:
      RNullA{}

def geo.poss(ms: List<&2, String>, +z: KV.Zset) -> List<&2, Reply>:
  match ms:
    case Nil{}:
      Nil{}
    case Con{+m, rest}:
      geo.pos.of(KV.zset.score(m, z)) <> geo.poss(rest, z)

def geo.hash.of(s: Maybe<&2, F.F64>) -> Reply:
  match s:
    case Some{+sc}:
      RBulk{G.geo.hash11(G.d.of_score(sc))}
    case None{}:
      RNull{}

def geo.hashes(ms: List<&2, String>, +z: KV.Zset) -> List<&2, Reply>:
  match ms:
    case Nil{}:
      Nil{}
    case Con{+m, rest}:
      geo.hash.of(KV.zset.score(m, z)) <> geo.hashes(rest, z)

def geo.nulls(ms: List<&2, String>, +r: Reply) -> List<&2, Reply>:
  match ms:
    case Nil{}:
      Nil{}
    case Con{m, rest}:
      r <> geo.nulls(rest, r)

def geo.dist.at(a: Maybe<&2, F.F64>, b: Maybe<&2, F.F64>, +conv: G.D) -> Reply:
  match a b:
    case Some{+x} Some{+y}:
      +p = G.geo.pos(G.d.of_score(x))
      +q = G.geo.pos(G.d.of_score(y))
      RBulk{G.geo.dist_text(G.d.div(G.geo.dist(G.pos.lon(p), G.pos.lat(p), G.pos.lon(q), G.pos.lat(q)), conv))}
    case _ _:
      RNull{}

# the meters of a unit read already (as the command parsed)
def geo.conv(m: Maybe<&2, G.D>) -> G.D:
  match m:
    case Some{c}:
      c
    case None{}:
      G.D{1072693248, 0}

# GEODIST of members a and b in a unit (args: as they came), of the
# sorted set z
def geo.dist(args: List<&2, String>, +z: KV.Zset) -> Reply:
  match args:
    case Con{a, Con{b, Nil{}}}:
      geo.dist.at(KV.zset.score(a, z), KV.zset.score(b, z), G.D{1072693248, 0})
    case Con{a, Con{b, Con{u, more}}}:
      geo.dist.at(KV.zset.score(a, z), KV.zset.score(b, z), geo.conv(geo.unit(u)))
    case _:
      RNull{}

# a search's kind (GEO, below) from the name it was called by, in any
# case: GEORADIUS 0 and GEOSEARCH 4 (nine letters, the fourth an R or an
# S), GEORADIUS_RO 1, GEORADIUSBYMEMBER 2 and GEORADIUSBYMEMBER_RO 3 (by
# their lengths)
def geo.kind9(+c: U32) -> Nat:
  Bool.pick(Nat, U32.is_eq(U32.or(c, 32), 114), 0n, 4n)

def geo.kind.len(+n: Nat, +name: String) -> Nat:
  match n:
    case 9n:
      geo.kind9(String.code_at(name, 3n))
    case 12n:
      1n
    case 17n:
      2n
    case 20n:
      3n
    case _:
      4n

def geo.kind(+args: List<&2, String>) -> Nat:
  match args:
    case Con{+nm, rest}:
      geo.kind.len(String.length(nm), nm)
    case Nil{}:
      4n

# a search without STORE (args: as they came, the name it was called by
# first) of the sorted set z (None: its key is not there)
def geo.find(+args: List<&2, String>, +z: Maybe<&2, KV.Zset>) -> Reply:
  geo.reply(geo.found(geo.kind(args), args, z))

# GEOADD key [NX|XX] [CH] lon lat member ...: its options (NX, XX and CH,
# each as often as it comes), then the triples, read as geoaddCommand
# reads them: a syntax error for words after the options that make no
# triples or for NX with XX, then each position in turn (a float, within
# the ranges), then ZADD of the scores of their geohashes (its own check:
# no triple, a syntax error). Its WRONGTYPE comes as ZADD's, as it runs.
def geoadd.word(+w: String) -> Nat:
  +c = zopt.word(w)
  Bool.pick(Nat, Bool.or(Bool.or(Nat.is_eq(c, 1n), Nat.is_eq(c, 2n)), Nat.is_eq(c, 5n)), c, 0n)

def geoadd.head(+xs: List<&2, String>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case Con{+w, r}:
      geoadd.word(w)

def geoadd.opts(xs: List<&2, String>, c: Nat, o: ZOpts) -> ZOpts & List<&2, String>:
  match xs c:
    case Con{w, +rest} 1n+p:
      geoadd.opts(rest, geoadd.head(rest), zopts.set(1n+p, o))
    case ys _:
      (o, ys)

# the positions as ZADD's pairs, or the error of the first that does not
# read
type GAdd is Data:
  GAOk{ps: List<&2, ZPair>}
  GAErr{r: Reply}

def geoadd.score(+p: G.Pos) -> String:
  G.geo.score_text(G.pos.lon(p), G.pos.lat(p))

def geoadd.con(p: GPt, m: String, rest: GAdd) -> GAdd:
  match p rest:
    case GPtErr{r} _:
      GAErr{r}
    case GPtOk{x} GAErr{r}:
      GAErr{r}
    case GPtOk{+x} GAOk{ps}:
      GAOk{ZPair{geoadd.score(x), m} <> ps}

def geoadd.pairs(xs: List<&2, String>) -> GAdd:
  match xs:
    case Con{+a, Con{+b, Con{m, rest}}}:
      geoadd.con(geo.lonlat(a, b), m, geoadd.pairs(rest))
    case _:
      GAOk{Nil{}}

def geoadd.of(r: GAdd, +k: String, o: ZOpts) -> Cmd:
  match r:
    case GAErr{e}:
      Bad{e}
    case GAOk{Nil{}}:
      e_syntax()
    case GAOk{Con{p, ps}}:
      Upd{k, UZset{ZWAdd{o, Con{p, ps}}}}

def geoadd.nxx(+o: ZOpts) -> Bool:
  match o:
    case ZOpts{+nx, +xx, gt, lt, ch, incr}:
      Bool.and(nx, xx)

def geoadd.check(bad: Bool, +k: String, o: ZOpts, ws: List<&2, String>) -> Cmd:
  match bad:
    case True{}:
      e_syntax()
    case False{}:
      geoadd.of(geoadd.pairs(ws), k, o)

def geoadd.go(+k: String, +o: ZOpts, +ws: List<&2, String>) -> Cmd:
  geoadd.check(Bool.or(Nat.is_ne(Nat.mod(List.length(&2, String, ws), 3n), 0n), geoadd.nxx(o)), k, o, ws)

def geoadd.at(+k: String, p: ZOpts & List<&2, String>) -> Cmd:
  (o, ws) = p
  geoadd.go(k, o, ws)

def parse_geoadd(+k: String, +rest: List<&2, String>) -> Cmd:
  geoadd.at(k, geoadd.opts(rest, geoadd.head(rest), zopts.none()))

# GEODIST key a b [unit]: the unit read first (a word after it: a syntax
# error), then the key
def geodist.of(ok: Bool, +k: String, +a: String, +b: String, +u: String) -> Cmd:
  match ok:
    case True{}:
      Peek{k, PZset{ZRGeoDist{[a, b, u]}}}
    case False{}:
      Bad{e_unit()}

def parse_geodist(args: List<&2, String>) -> Cmd:
  match args:
    case Con{k, Con{a, Con{b, Nil{}}}}:
      Peek{k, PZset{ZRGeoDist{[a, b]}}}
    case Con{+k, Con{+a, Con{+b, Con{+u, Nil{}}}}}:
      geodist.of(Maybe.is_some(&2, G.D, geo.unit(u)), k, a, b, u)
    case Con{k, Con{a, Con{b, Con{u, more}}}}:
      e_syntax()
    case _:
      e_arity("geodist")

# the options of a GEORADIUS or GEORADIUSBYMEMBER, read as their loop
# reads them (nothing in them needs the key): the destination of the last
# STORE or STOREDIST before any error, if one comes
def gopt.dst(o: GOpt) -> Maybe<&2, String>:
  match o:
    case GOpt{wd, wh, wc, any, sort, count, store, sdist, fm, fl, br, bb, ctr, shp, conv}:
      store
    case GOptOf{x}:
      gopt.dst(x)

def geo.walk.of(st: GSt) -> Maybe<&2, String>:
  match st:
    case GGo{xs, o}:
      gopt.dst(o)
    case GErr{r}:
      None{}

def geo.walk(+kind: Nat, +opts: List<&2, String>) -> Maybe<&2, String>:
  geo.walk.of(geo.loop(Nat.add(List.length(&2, String, opts), 1n), GGo{opts, gopt.new()}, kind, None{}))

# whether a search stores: GEOSEARCHSTORE always, GEORADIUS and
# GEORADIUSBYMEMBER with a STORE or a STOREDIST (opts: their options)
def geo.walk.if(+kind: Nat, +opts: List<&2, String>) -> Maybe<&2, String>:
  match kind:
    case 0n:
      geo.walk(0n, opts)
    case 2n:
      geo.walk(2n, opts)
    case 5n:
      Some{""}
    case _:
      None{}

# the destination a GEO store writes (SGeoStore's args, its name first)
def geo.dst(+kind: Nat, args: List<&2, String>) -> Maybe<&2, String>:
  match kind args:
    case 5n Con{nm, Con{d, rest}}:
      Some{d}
    case 0n Con{nm, Con{k, +rest}}:
      geo.walk(0n, List.drop(&2, String, rest, 4n))
    case 2n Con{nm, Con{k, +rest}}:
      geo.walk(2n, List.drop(&2, String, rest, 3n))
    case _ _:
      None{}

def geo.route(m: Maybe<&2, String>, +kind: Nat, k: String, args: List<&2, String>) -> Cmd:
  match m:
    case Some{d}:
      Own{SGeoStore{kind, args}}
    case None{}:
      Peek{k, PZset{ZRGeoFind{args}}}

def geo.parse.of(ok: Bool, +kind: Nat, +name: String, args: List<&2, String>, +n: Nat, lname: String) -> Cmd:
  match ok args:
    case True{} Con{+k, +rest}:
      geo.route(geo.walk.if(kind, List.drop(&2, String, rest, Nat.sub(n, 1n))), kind, k, name <> Con{k, rest})
    case _ _:
      e_arity(lname)

# a search of a kind (n: Redis's arity, the arguments it takes at least):
# a read of its key (a Peek, its arguments read as it runs), or SGeoStore
# when it stores
def geo.parse(+kind: Nat, +name: String, +args: List<&2, String>, +n: Nat, lname: String) -> Cmd:
  geo.parse.of(Nat.is_le(n, List.length(&2, String, args)), kind, name, args, n, lname)

# The administrative commands
# ---------------------------
# LASTSAVE, MEMORY STATS and MEMORY DOCTOR read the server's state, and
# LOLWUT's drawings its random numbers: SAdmin, its kind (0 LASTSAVE, 1
# MEMORY STATS, 2 MEMORY DOCTOR, 3 LOLWUT VERSION 5, 4 SHUTDOWN, 5 LOLWUT
# VERSION 6) and its arguments (session.bend, The administrative
# commands). SLOWLOG and LATENCY read the timing of the calls (info.bend,
# Timing) and RESET changes it: SAdmin too, kinds 6 SLOWLOG GET (of a
# count, -1 for all, or none for the default 10), 7 SLOWLOG LEN, 8
# SLOWLOG RESET, 9 LATENCY LATEST, 10 LATENCY HISTORY (of an event), 11
# LATENCY RESET (of events, all for none), 12 LATENCY GRAPH (of an
# event), 13 LATENCY DOCTOR and 14 LATENCY HISTOGRAM (of commands, all
# for none), and 15 SAVE (which the shell runs: server.bend, The RDB
# file). ROLE answers as a master with no replica answers. WAIT is a
# blocking command (SBlock) when it asks for a replica, which none will
# acknowledge.

# SLOWLOG: GET of a count, as getRangeLongFromObjectOrReply reads it (a
# long long from -1 on; its own error for any other argument, and for a
# second), LEN, RESET, HELP
def slowlog_id(+n: String, len: Nat) -> Nat:
  match len:
    case 3n:
      Bool.pick(Nat, String.eq(n, "GET"), 1n, Bool.pick(Nat, String.eq(n, "LEN"), 2n, 0n))
    case 4n:
      Bool.pick(Nat, String.eq(n, "HELP"), 4n, 0n)
    case 5n:
      Bool.pick(Nat, String.eq(n, "RESET"), 3n, 0n)
    case _:
      0n

def slowlog_help() -> List<&2, String>:
  ["GET [<count>]",
   "    Return top <count> entries from the slowlog (default: 10, -1 mean all).",
   "    Entries are made of:",
   "    id, timestamp, time in microseconds, arguments array, client IP and port,",
   "    client name",
   "LEN",
   "    Return the length of the slowlog.",
   "RESET",
   "    Reset the slowlog."]

def slowlog.bad() -> SessOp:
  SBad{RError{"ERR count should be greater than or equal to -1"}}

# a count past 10^14 as 10^14, more than the log can hold
def slowlog.count(+l: LL) -> SessOp:
  match l:
    case LL{+neg, +hi, +lo}:
      Bool.pick(SessOp, neg, Bool.pick(SessOp, Bool.and(Nat.is_eq(hi, 0n), Nat.is_eq(lo, 1n)), SAdmin{6n, ["-1"]}, slowlog.bad()),
        SAdmin{6n, [Nat.show(Nat.add(Nat.mul(Nat.min(hi, 100000n), 1000000000n), lo))]})
    case LLBad{}:
      slowlog.bad()

def parse_slowlog(id: Nat, sub: String, args: List<&2, String>) -> SessOp:
  match id:
    case 1n:  # GET
      match args:
        case Nil{}:
          SAdmin{6n, Nil{}}
        case Con{+c, Nil{}}:
          slowlog.count(ll.read(c))
        case _:
          SBad{e_sub_syntax(sub, "SLOWLOG")}
    case 2n:  # LEN
      match args:
        case Nil{}:
          SAdmin{7n, Nil{}}
        case _:
          s_arity("slowlog|len")
    case 3n:  # RESET
      match args:
        case Nil{}:
          SAdmin{8n, Nil{}}
        case _:
          s_arity("slowlog|reset")
    case 4n:  # HELP
      match args:
        case Nil{}:
          help("SLOWLOG", slowlog_help())
        case _:
          s_arity("slowlog|help")
    case _:
      e_unknown_sub(sub, "SLOWLOG")

# LATENCY: DOCTOR, GRAPH and HISTORY of an event, HISTOGRAM of commands,
# LATEST, RESET of events, HELP
def latency_id(+n: String, len: Nat) -> Nat:
  match len:
    case 4n:
      Bool.pick(Nat, String.eq(n, "HELP"), 3n, 0n)
    case 5n:
      Bool.pick(Nat, String.eq(n, "GRAPH"), 2n, Bool.pick(Nat, String.eq(n, "RESET"), 7n, 0n))
    case 6n:
      Bool.pick(Nat, String.eq(n, "DOCTOR"), 1n, Bool.pick(Nat, String.eq(n, "LATEST"), 6n, 0n))
    case 7n:
      Bool.pick(Nat, String.eq(n, "HISTORY"), 5n, 0n)
    case 9n:
      Bool.pick(Nat, String.eq(n, "HISTOGRAM"), 4n, 0n)
    case _:
      0n

def latency_help() -> List<&2, String>:
  ["DOCTOR",
   "    Return a human readable latency analysis report.",
   "GRAPH <event>",
   "    Return an ASCII latency graph for the <event> class.",
   "HISTORY <event>",
   "    Return time-latency samples for the <event> class.",
   "LATEST",
   "    Return the latest latency samples for all events.",
   "RESET [<event> ...]",
   "    Reset latency data of one or more <event> classes.",
   "    (default: reset all data for all event classes)",
   "HISTOGRAM [COMMAND ...]",
   "    Return a cumulative distribution of latencies in the format of a histogram for the specified command names.",
   "    If no commands are specified then all histograms are replied."]

def parse_latency(id: Nat, sub: String, args: List<&2, String>) -> SessOp:
  match id:
    case 1n:  # DOCTOR
      match args:
        case Nil{}:
          SAdmin{13n, Nil{}}
        case _:
          s_arity("latency|doctor")
    case 2n:  # GRAPH
      match args:
        case Con{e, Nil{}}:
          SAdmin{12n, [e]}
        case _:
          s_arity("latency|graph")
    case 3n:  # HELP
      match args:
        case Nil{}:
          help("LATENCY", latency_help())
        case _:
          s_arity("latency|help")
    case 4n:  # HISTOGRAM
      SAdmin{14n, args}
    case 5n:  # HISTORY
      match args:
        case Con{e, Nil{}}:
          SAdmin{10n, [e]}
        case _:
          s_arity("latency|history")
    case 6n:  # LATEST
      match args:
        case Nil{}:
          SAdmin{9n, Nil{}}
        case _:
          s_arity("latency|latest")
    case 7n:  # RESET
      SAdmin{11n, args}
    case _:
      e_unknown_sub(sub, "LATENCY")

# ACL: its subcommands, as aclCommand reads them, are SAcl, their number
# and arguments (session.bend, ACL): the users, the log and the
# descriptions are the session's, and the server answers WHOAMI and
# GENPASS, closes the clients of a user DELUSER removed, and logs
# (server.bend, ACL). Redis checks the arity of each subcommand first; CAT,
# GENPASS and LOG then refuse a second argument themselves. LOAD and SAVE
# need an ACL file, which BendKV does not read yet: they answer as Redis
# answers without aclfile.
def acl_id(+n: String, len: Nat) -> Nat:
  match len:
    case 3n:
      Bool.pick(Nat, String.eq(n, "CAT"), 1n, Bool.pick(Nat, String.eq(n, "LOG"), 9n, 0n))
    case 4n:
      Bool.pick(Nat, String.eq(n, "HELP"), 6n, Bool.pick(Nat, String.eq(n, "LIST"), 7n, Bool.pick(Nat, String.eq(n, "LOAD"), 8n, Bool.pick(Nat, String.eq(n, "SAVE"), 10n, 0n))))
    case 5n:
      Bool.pick(Nat, String.eq(n, "USERS"), 12n, 0n)
    case 6n:
      Bool.pick(Nat, String.eq(n, "DRYRUN"), 3n, Bool.pick(Nat, String.eq(n, "WHOAMI"), 13n, 0n))
    case 7n:
      Bool.pick(Nat, String.eq(n, "DELUSER"), 2n, Bool.pick(Nat, String.eq(n, "GENPASS"), 4n, Bool.pick(Nat, String.eq(n, "GETUSER"), 5n, Bool.pick(Nat, String.eq(n, "SETUSER"), 11n, 0n))))
    case _:
      0n

def acl_help() -> List<&2, String>:
  ["CAT [<category>]",
   "    List all commands that belong to <category>, or all command categories",
   "    when no category is specified.",
   "DELUSER <username> [<username> ...]",
   "    Delete a list of users.",
   "DRYRUN <username> <command> [<arg> ...]",
   "    Returns whether the user can execute the given command without executing the command.",
   "GETUSER <username>",
   "    Get the user's details.",
   "GENPASS [<bits>]",
   "    Generate a secure 256-bit user password. The optional `bits` argument can",
   "    be used to specify a different size.",
   "LIST",
   "    Show users details in config file format.",
   "LOAD",
   "    Reload users from the ACL file.",
   "LOG [<count> | RESET]",
   "    Show the ACL log entries.",
   "SAVE",
   "    Save the current config to the ACL file.",
   "SETUSER <username> <attribute> [<attribute> ...]",
   "    Create or modify a user with the specified attributes.",
   "USERS",
   "    List all the registered usernames.",
   "WHOAMI",
   "    Return the current connection username."]

def acl.nofile() -> SessOp:
  SBad{RError{"ERR This Redis instance is not configured to use an ACL file. You may want to specify users via the ACL SETUSER command and then issue a CONFIG REWRITE (assuming you have a Redis configuration file set) in order to store users in the Redis configuration."}}

# a subcommand that takes no argument, or at most one (opt: CAT, GENPASS
# and LOG, which refuse a second themselves), or at least least
def acl.none(+id: Nat, sub: String, args: List<&2, String>) -> SessOp:
  match args:
    case Nil{}:
      SAcl{id, Nil{}}
    case _:
      s_arity("acl|" ++ String.to_lower(sub))

def acl.opt(+id: Nat, sub: String, args: List<&2, String>) -> SessOp:
  match args:
    case Nil{}:
      SAcl{id, Nil{}}
    case Con{a, Nil{}}:
      SAcl{id, [a]}
    case _:
      SBad{e_sub_syntax(sub, "ACL")}

def acl.least(+id: Nat, +least: Nat, sub: String, args: List<&2, String>) -> SessOp:
  +xs = args
  Bool.pick(SessOp, Nat.is_le(least, List.length(&2, String, xs)), SAcl{id, xs}, s_arity("acl|" ++ String.to_lower(sub)))

def parse_acl(id: Nat, sub: String, args: List<&2, String>) -> SessOp:
  match id:
    case 1n:  # CAT
      acl.opt(1n, sub, args)
    case 2n:  # DELUSER
      acl.least(2n, 1n, sub, args)
    case 3n:  # DRYRUN
      acl.least(3n, 2n, sub, args)
    case 4n:  # GENPASS
      acl.opt(4n, sub, args)
    case 5n:  # GETUSER
      match args:
        case Con{u, Nil{}}:
          SAcl{5n, [u]}
        case _:
          s_arity("acl|getuser")
    case 6n:  # HELP
      match args:
        case Nil{}:
          help("ACL", acl_help())
        case _:
          s_arity("acl|help")
    case 7n:  # LIST
      acl.none(7n, sub, args)
    case 8n:  # LOAD
      match args:
        case Nil{}:
          acl.nofile()
        case _:
          s_arity("acl|load")
    case 9n:  # LOG
      acl.opt(9n, sub, args)
    case 10n:  # SAVE
      match args:
        case Nil{}:
          acl.nofile()
        case _:
          s_arity("acl|save")
    case 11n:  # SETUSER
      acl.least(11n, 1n, sub, args)
    case 12n:  # USERS
      acl.none(12n, sub, args)
    case 13n:  # WHOAMI
      acl.none(13n, sub, args)
    case _:
      e_unknown_sub(sub, "ACL")

# ROLE: a master at the replication offset 0, with no replica
# (roleCommand)
def role.reply() -> Reply:
  RArray{[RBulk{"master"}, RInt{IPos{0n}}, RArray{Nil{}}]}

# WAIT numreplicas timeout, read as waitCommand reads them: numreplicas a
# long, the timeout a long long of ms, not negative. No replica
# acknowledges anything, so WAIT answers 0 at once for numreplicas up to
# 0, and otherwise once its time is up (SBlock: session.bend, BlkWait)
def wait.go(n: LL, t: LL, +args: List<&2, String>) -> Cmd:
  match n t:
    case LLBad{} _:
      Bad{e_int()}
    case LL{nn, nh, nl} LLBad{}:
      Bad{RError{"ERR timeout is not an integer or out of range"}}
    case LL{nn, nh, nl} LL{True{}, th, tl}:
      Bad{RError{"ERR timeout is negative"}}
    case LL{+nn, +nh, +nl} LL{False{}, th, tl}:
      Bool.pick(Cmd, Bool.or(nn, Bool.and(Nat.is_eq(nh, 0n), Nat.is_eq(nl, 0n))), Own{SReply{RInt{IPos{0n}}}}, Own{SBlock{186n, args}})

def wait.of(+args: List<&2, String>) -> Cmd:
  match args:
    case Con{+n, Con{+t, Nil{}}}:
      wait.go(ll.read(n), ll.read(t), args)
    case _:
      e_arity("wait")

# SHUTDOWN's flags, NOSAVE, SAVE, NOW, FORCE and ABORT, in any case, as
# shutdownCommand reads them: SdBad at a word that is none of them
type Sd is Data:
  Sd{nosave: Bool, save: Bool, now: Bool, force: Bool, abort: Bool}
  SdBad{}

def sd.word(+u: String, s: Sd) -> Sd:
  match s:
    case Sd{+nosave, +save, +now, +force, +abort}:
      Bool.pick(Sd, String.eq(u, "NOSAVE"), Sd{True{}, save, now, force, abort},
        Bool.pick(Sd, String.eq(u, "SAVE"), Sd{nosave, True{}, now, force, abort},
          Bool.pick(Sd, String.eq(u, "NOW"), Sd{nosave, save, True{}, force, abort},
            Bool.pick(Sd, String.eq(u, "FORCE"), Sd{nosave, save, now, True{}, abort},
              Bool.pick(Sd, String.eq(u, "ABORT"), Sd{nosave, save, now, force, True{}}, SdBad{})))))
    case SdBad{}:
      SdBad{}

def sd.of(args: List<&2, String>, s: Sd) -> Sd:
  match args:
    case Nil{}:
      s
    case Con{+w, rest}:
      sd.of(rest, sd.word(String.to_upper(cstr(w)), s))

def sd.flags(+args: List<&2, String>) -> Sd:
  sd.of(args, Sd{False{}, False{}, False{}, False{}, False{}})

# whether SHUTDOWN is to save the data set (SAVE: server.bend writes the
# RDB file, as it does with save points unless NOSAVE), and whether FORCE
# goes on when the save fails
def sd.save(+s: Sd) -> Bool:
  match s:
    case Sd{nosave, +save, now, force, abort}:
      save
    case SdBad{}:
      False{}

def sd.force(+s: Sd) -> Bool:
  match s:
    case Sd{nosave, save, now, +force, abort}:
      force
    case SdBad{}:
      False{}

# SHUTDOWN: ABORT with another flag, and NOSAVE with SAVE, are a syntax
# error; ABORT finds no shutdown to abort (Redis's waits for its replicas,
# and BendKV has none), as Redis answers when none waits; the others are
# SAdmin's kind 4, the flags read again as it runs
def shutdown.of(s: Sd, +args: List<&2, String>) -> Cmd:
  match s:
    case Sd{+nosave, +save, +now, +force, +abort}:
      Bool.pick(Cmd, Bool.or(Bool.and(abort, Bool.or(Bool.or(nosave, save), Bool.or(now, force))), Bool.and(nosave, save)), e_syntax(),
        Bool.pick(Cmd, abort, Bad{RError{"ERR No shutdown in progress."}}, Own{SAdmin{4n, args}}))
    case SdBad{}:
      e_syntax()

def shutdown.cmd(+args: List<&2, String>) -> Cmd:
  shutdown.of(sd.flags(args), args)

# LOLWUT [VERSION v ...]: 7.0.15's own LOLWUT writes Redis's version;
# VERSION 5 and VERSION 6 draw the art of Redis 5 and Redis 6, as
# lolwutCommand picks them by the version as an unsigned int ("%u.0.0"),
# the arguments after it longs, clamped as lolwut5Command and
# lolwut6Command clamp them; any other version is 7.0.15's, which takes
# no argument
def lolwut.text() -> Reply:
  RVerb{"Redis ver. 7.0.15\n"}

# a long clamped to 1..hi (None: no long)
def lw.clamp(l: LL, +hi: Nat) -> Maybe<&2, Nat>:
  match l:
    case LL{+neg, +h, +lo}:
      Some{Bool.pick(Nat, Bool.or(neg, Bool.and(Nat.is_eq(h, 0n), Nat.is_eq(lo, 0n))), 1n, Bool.pick(Nat, Bool.or(Nat.is_lt(0n, h), Nat.is_lt(hi, lo)), hi, lo))}
    case LLBad{}:
      None{}

# the first argument clamped to 1..hi, or d when there is none
def lw.arg(args: List<&2, String>, +hi: Nat, +d: Nat) -> Maybe<&2, Nat>:
  match args:
    case Con{+a, rest}:
      lw.clamp(ll.read(a), hi)
    case Nil{}:
      Some{d}

def lw.tail(args: List<&2, String>) -> List<&2, String>:
  match args:
    case Con{a, rest}:
      rest
    case Nil{}:
      Nil{}

# LOLWUT VERSION 5 [cols [squares-per-row [squares-per-col]]] (66, 8, 12)
def lw.five(c: Maybe<&2, Nat>, r: Maybe<&2, Nat>, q: Maybe<&2, Nat>) -> Cmd:
  match c r q:
    case Some{+cols} Some{+per} Some{+rows}:
      Own{SAdmin{3n, [Nat.show(cols), Nat.show(per), Nat.show(rows)]}}
    case _ _ _:
      Bad{e_int()}

# LOLWUT VERSION 6 [cols [rows]] (80, 20)
def lw.six(c: Maybe<&2, Nat>, r: Maybe<&2, Nat>) -> Cmd:
  match c r:
    case Some{+cols} Some{+rows}:
      Own{SAdmin{5n, [Nat.show(cols), Nat.show(rows)]}}
    case _ _:
      Bad{e_int()}

# a long's low 32 bits, as (unsigned int) keeps them: its magnitude
# hi * 10^9 + lo mod 2^32 (hi's high and low 16 bits apart, so that no
# product passes 2^48), and the complement of that for a negative long
def lw.u32.mag(+hi: Nat, +lo: Nat) -> Nat:
  +w = Nat.mul(65536n, 65536n)
  +a = Nat.mod(hi, w)
  +a1 = Nat.div(a, 65536n)
  +a0 = Nat.mod(a, 65536n)
  Nat.mod(Nat.add(Nat.add(Nat.mul(Nat.mod(Nat.mul(a1, 1000000000n), 65536n), 65536n), Nat.mul(a0, 1000000000n)), lo), w)

def lw.ver(l: LL) -> Maybe<&2, Nat>:
  match l:
    case LL{+neg, +hi, +lo}:
      +m = lw.u32.mag(hi, lo)
      Some{Bool.pick(Nat, Bool.and(neg, Nat.is_lt(0n, m)), Nat.sub(Nat.mul(65536n, 65536n), m), m)}
    case LLBad{}:
      None{}

def lw.pick(m: Maybe<&2, Nat>, +rest: List<&2, String>) -> Cmd:
  match m:
    case Some{+v}:
      Bool.pick(Cmd, Nat.is_eq(v, 5n), lw.five(lw.arg(rest, 1000n, 66n), lw.arg(lw.tail(rest), 200n, 8n), lw.arg(lw.tail(lw.tail(rest)), 200n, 12n)),
        Bool.pick(Cmd, Nat.is_eq(v, 6n), lw.six(lw.arg(rest, 1000n, 80n), lw.arg(lw.tail(rest), 1000n, 20n)), Own{SReply{lolwut.text()}}))
    case None{}:
      Bad{e_int()}

def lw.if(ver: Bool, +n: String, +rest: List<&2, String>) -> Cmd:
  match ver:
    case True{}:
      lw.pick(lw.ver(ll.read(n)), rest)
    case False{}:
      Own{SReply{lolwut.text()}}

def lolwut.of(+args: List<&2, String>) -> Cmd:
  match args:
    case Con{+v, Con{+n, +rest}}:
      lw.if(is_word(v, "VERSION"), n, rest)
    case _:
      Own{SReply{lolwut.text()}}

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
    case 1n:  # A
      Bool.pick(Nat, String.eq(n, "ACL"), 210n, 0n)
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
      Bool.pick(Nat, String.eq(n, "DECR"), 11n,
      Bool.pick(Nat, String.eq(n, "DUMP"), 199n, 0n))
    case 5n:  # E
      Bool.pick(Nat, String.eq(n, "ECHO"), 2n,
      Bool.pick(Nat, String.eq(n, "EVAL"), 65n,
      Bool.pick(Nat, String.eq(n, "EXEC"), 162n, 0n)))
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
      Bool.pick(Nat, String.eq(n, "RPOP"), 71n,
      Bool.pick(Nat, String.eq(n, "ROLE"), 185n, 0n))
    case 19n:  # S
      Bool.pick(Nat, String.eq(n, "SCAN"), 22n,
      Bool.pick(Nat, String.eq(n, "SADD"), 83n,
      Bool.pick(Nat, String.eq(n, "SREM"), 84n,
      Bool.pick(Nat, String.eq(n, "SPOP"), 119n,
      Bool.pick(Nat, String.eq(n, "SORT"), 177n,
      Bool.pick(Nat, String.eq(n, "SAVE"), 203n, 0n))))))
    case 20n:  # T
      Bool.pick(Nat, String.eq(n, "TYPE"), 25n,
      Bool.pick(Nat, String.eq(n, "TIME"), 113n, 0n))
    case 23n:  # W
      Bool.pick(Nat, String.eq(n, "WAIT"), 186n, 0n)
    case 24n:  # X
      Bool.pick(Nat, String.eq(n, "XLEN"), 211n,
      Bool.pick(Nat, String.eq(n, "XADD"), 217n,
      Bool.pick(Nat, String.eq(n, "XDEL"), 219n, 0n)))
    case 26n:  # Z
      Bool.pick(Nat, String.eq(n, "ZADD"), 121n,
      Bool.pick(Nat, String.eq(n, "ZREM"), 123n, 0n))
    case _:
      0n

def cmd_id.l5(+n: String, c: Nat) -> Nat:
  match c:
    case 2n:  # B
      Bool.pick(Nat, String.eq(n, "BITOP"), 48n,
      Bool.pick(Nat, String.eq(n, "BLPOP"), 153n,
      Bool.pick(Nat, String.eq(n, "BRPOP"), 154n, 0n)))
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
    case 13n:  # M
      Bool.pick(Nat, String.eq(n, "MULTI"), 161n, 0n)
    case 16n:  # P
      Bool.pick(Nat, String.eq(n, "PFADD"), 179n, 0n)
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
    case 23n:  # W
      Bool.pick(Nat, String.eq(n, "WATCH"), 164n, 0n)
    case 24n:  # X
      Bool.pick(Nat, String.eq(n, "XREAD"), 214n,
      Bool.pick(Nat, String.eq(n, "XINFO"), 215n,
      Bool.pick(Nat, String.eq(n, "XTRIM"), 218n, 0n)))
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
      Bool.pick(Nat, String.eq(n, "BITPOS"), 43n,
      Bool.pick(Nat, String.eq(n, "BLMOVE"), 156n,
      Bool.pick(Nat, String.eq(n, "BLMPOP"), 157n,
      Bool.pick(Nat, String.eq(n, "BZMPOP"), 160n, 0n))))
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
      Bool.pick(Nat, String.eq(n, "GETBIT"), 40n,
      Bool.pick(Nat, String.eq(n, "GEOADD"), 189n,
      Bool.pick(Nat, String.eq(n, "GEOPOS"), 192n, 0n)))))
    case 8n:  # H
      Bool.pick(Nat, String.eq(n, "HSETNX"), 52n, 0n)
    case 9n:  # I
      Bool.pick(Nat, String.eq(n, "INCRBY"), 12n, 0n)
    case 12n:  # L
      Bool.pick(Nat, String.eq(n, "LPUSHX"), 68n,
      Bool.pick(Nat, String.eq(n, "LINDEX"), 73n,
      Bool.pick(Nat, String.eq(n, "LRANGE"), 74n,
      Bool.pick(Nat, String.eq(n, "LOLWUT"), 188n, 0n))))
    case 13n:  # M
      Bool.pick(Nat, String.eq(n, "MSETNX"), 45n,
      Bool.pick(Nat, String.eq(n, "MEMORY"), 118n, 0n))
    case 15n:  # O
      Bool.pick(Nat, String.eq(n, "OBJECT"), 114n, 0n)
    case 16n:  # P
      Bool.pick(Nat, String.eq(n, "PSETEX"), 24n,
      Bool.pick(Nat, String.eq(n, "PUBSUB"), 174n, 0n))
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
    case 24n:  # X
      Bool.pick(Nat, String.eq(n, "XRANGE"), 212n,
      Bool.pick(Nat, String.eq(n, "XSETID"), 220n, 0n))
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
    case 4n:  # D
      Bool.pick(Nat, String.eq(n, "DISCARD"), 163n, 0n)
    case 6n:  # F
      Bool.pick(Nat, String.eq(n, "FLUSHDB"), 20n, 0n)
    case 7n:  # G
      Bool.pick(Nat, String.eq(n, "GEODIST"), 190n,
      Bool.pick(Nat, String.eq(n, "GEOHASH"), 191n, 0n))
    case 8n:  # H
      Bool.pick(Nat, String.eq(n, "HSTRLEN"), 58n,
      Bool.pick(Nat, String.eq(n, "HEXISTS"), 59n,
      Bool.pick(Nat, String.eq(n, "HGETALL"), 62n,
      Bool.pick(Nat, String.eq(n, "HINCRBY"), 63n, 0n))))
    case 12n:  # L
      Bool.pick(Nat, String.eq(n, "LINSERT"), 76n,
      Bool.pick(Nat, String.eq(n, "LATENCY"), 202n, 0n))
    case 13n:  # M
      Bool.pick(Nat, String.eq(n, "MONITOR"), 175n, 0n)
    case 16n:  # P
      Bool.pick(Nat, String.eq(n, "PEXPIRE"), 29n,
      Bool.pick(Nat, String.eq(n, "PERSIST"), 36n,
      Bool.pick(Nat, String.eq(n, "PUBLISH"), 172n,
      Bool.pick(Nat, String.eq(n, "PFCOUNT"), 180n,
      Bool.pick(Nat, String.eq(n, "PFMERGE"), 181n,
      Bool.pick(Nat, String.eq(n, "PFDEBUG"), 182n, 0n))))))
    case 18n:  # R
      Bool.pick(Nat, String.eq(n, "RESTORE"), 200n, 0n)
    case 19n:  # S
      Bool.pick(Nat, String.eq(n, "SORT_RO"), 178n,
      Bool.pick(Nat, String.eq(n, "SLOWLOG"), 201n, 0n))
    case 21n:  # U
      Bool.pick(Nat, String.eq(n, "UNWATCH"), 165n, 0n)
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
      Bool.pick(Nat, String.eq(n, "BITFIELD"), 49n,
      Bool.pick(Nat, String.eq(n, "BZPOPMIN"), 158n,
      Bool.pick(Nat, String.eq(n, "BZPOPMAX"), 159n, 0n))))
    case 5n:  # E
      Bool.pick(Nat, String.eq(n, "EXPIREAT"), 30n, 0n)
    case 6n:  # F
      Bool.pick(Nat, String.eq(n, "FLUSHALL"), 19n,
      Bool.pick(Nat, String.eq(n, "FUNCTION"), 106n, 0n))
    case 7n:  # G
      Bool.pick(Nat, String.eq(n, "GETRANGE"), 37n, 0n)
    case 12n:  # L
      Bool.pick(Nat, String.eq(n, "LASTSAVE"), 184n, 0n)
    case 18n:  # R
      Bool.pick(Nat, String.eq(n, "RENAMENX"), 47n, 0n)
    case 19n:  # S
      Bool.pick(Nat, String.eq(n, "SETRANGE"), 39n,
      Bool.pick(Nat, String.eq(n, "SMEMBERS"), 88n,
      Bool.pick(Nat, String.eq(n, "SPUBLISH"), 173n,
      Bool.pick(Nat, String.eq(n, "SHUTDOWN"), 187n, 0n))))
    case 24n:  # X
      Bool.pick(Nat, String.eq(n, "XPENDING"), 216n, 0n)
    case 26n:  # Z
      Bool.pick(Nat, String.eq(n, "ZREVRANK"), 128n, 0n)
    case _:
      0n

def cmd_id.l9(+n: String, c: Nat) -> Nat:
  match c:
    case 7n:  # G
      Bool.pick(Nat, String.eq(n, "GEORADIUS"), 193n,
      Bool.pick(Nat, String.eq(n, "GEOSEARCH"), 197n, 0n))
    case 16n:  # P
      Bool.pick(Nat, String.eq(n, "PEXPIREAT"), 31n, 0n)
    case 18n:  # R
      Bool.pick(Nat, String.eq(n, "RPOPLPUSH"), 81n,
      Bool.pick(Nat, String.eq(n, "RANDOMKEY"), 110n, 0n))
    case 19n:  # S
      Bool.pick(Nat, String.eq(n, "SISMEMBER"), 86n,
      Bool.pick(Nat, String.eq(n, "SUBSCRIBE"), 166n, 0n))
    case 24n:  # X
      Bool.pick(Nat, String.eq(n, "XREVRANGE"), 213n, 0n)
    case 26n:  # Z
      Bool.pick(Nat, String.eq(n, "ZLEXCOUNT"), 130n,
      Bool.pick(Nat, String.eq(n, "ZREVRANGE"), 136n, 0n))
    case _:
      0n

def cmd_id.l10(+n: String, c: Nat) -> Nat:
  match c:
    case 2n:  # B
      Bool.pick(Nat, String.eq(n, "BRPOPLPUSH"), 155n, 0n)
    case 5n:  # E
      Bool.pick(Nat, String.eq(n, "EXPIRETIME"), 34n, 0n)
    case 8n:  # H
      Bool.pick(Nat, String.eq(n, "HRANDFIELD"), 117n, 0n)
    case 16n:  # P
      Bool.pick(Nat, String.eq(n, "PSUBSCRIBE"), 168n,
      Bool.pick(Nat, String.eq(n, "PFSELFTEST"), 183n, 0n))
    case 19n:  # S
      Bool.pick(Nat, String.eq(n, "SMISMEMBER"), 87n,
      Bool.pick(Nat, String.eq(n, "SINTERCARD"), 92n,
      Bool.pick(Nat, String.eq(n, "SDIFFSTORE"), 97n,
      Bool.pick(Nat, String.eq(n, "SSUBSCRIBE"), 170n, 0n))))
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
    case 21n:  # U
      Bool.pick(Nat, String.eq(n, "UNSUBSCRIBE"), 167n, 0n)
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
    case 2n:  # B
      Bool.pick(Nat, String.eq(n, "BGREWRITEAOF"), 176n, 0n)
    case 7n:  # G
      Bool.pick(Nat, String.eq(n, "GEORADIUS_RO"), 194n, 0n)
    case 8n:  # H
      Bool.pick(Nat, String.eq(n, "HINCRBYFLOAT"), 99n, 0n)
    case 16n:  # P
      Bool.pick(Nat, String.eq(n, "PUNSUBSCRIBE"), 169n, 0n)
    case 19n:  # S
      Bool.pick(Nat, String.eq(n, "SUNSUBSCRIBE"), 171n, 0n)
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
    case 7n:  # G
      Bool.pick(Nat, String.eq(n, "GEOSEARCHSTORE"), 198n, 0n)
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

def cmd_id.l17(+n: String, c: Nat) -> Nat:
  match c:
    case 7n:  # G
      Bool.pick(Nat, String.eq(n, "GEORADIUSBYMEMBER"), 195n, 0n)
    case _:
      0n

def cmd_id.l20(+n: String, c: Nat) -> Nat:
  match c:
    case 7n:  # G
      Bool.pick(Nat, String.eq(n, "GEORADIUSBYMEMBER_RO"), 196n, 0n)
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
    case 17n:
      cmd_id.l17(n, Nat.sub(U32.to_nat(String.code_at(n, 0n)), 64n))
    case 20n:
      cmd_id.l20(n, Nat.sub(U32.to_nat(String.code_at(n, 0n)), 64n))
    case _:
      0n

# whether a command's number is parse_sess's (a command of the
# connection, of the server or of several databases)
def cmd_own(+id: Nat) -> Bool:
  Bool.or(Bool.and(Nat.is_le(100n, id), Nat.is_le(id, 120n)), Bool.and(Nat.is_le(152n, id), Nat.is_le(id, 176n)))
# END gen_commands: dispatch

# Streams
# -------
# The commands that read a stream (XLEN, XRANGE, XREVRANGE, XREAD, XINFO,
# XPENDING) are Peeks of their key (PStream), but XREAD of several keys
# or with BLOCK (SXRead), each read as Redis 7.0.15 reads it (t_stream.c):
# what Redis reads before it looks the key up, the parser reads, and what
# it reads after, the read does (as XRead's forms keep it). stream.bend
# reads the stream. A count past any stream's (2^47) stands for none.

def xc.inf() -> Nat:
  Nat.mul(8388608n, 16777216n)

# a long long's count: 0 below 0, xc.inf() past it
def xc.of.big(big: Bool, +hi: Nat, +lo: Nat) -> Nat:
  match big:
    case True{}:
      xc.inf()
    case False{}:
      Nat.min(Nat.add(Nat.mul(hi, 1000000000n), lo), xc.inf())

def xc.of(l: LL) -> Maybe<&2, Nat>:
  match l:
    case LL{+neg, +hi, +lo}:
      Some{Bool.pick(Nat, neg, 0n, xc.of.big(Nat.is_le(140737n, hi), hi, lo))}
    case LLBad{}:
      None{}

def e_xid() -> Reply:
  RError{"ERR Invalid stream ID specified as stream command argument"}

def e_xstart() -> Reply:
  RError{"ERR invalid start ID for the interval"}

def e_xend() -> Reply:
  RError{"ERR invalid end ID for the interval"}

# XRANGE key start end [COUNT count] (XREVRANGE key end start ...),
# read as xrangeGenericCommand reads it: the start, then the end (each a
# bound, X.xb.parse), then its options from the fourth word on, COUNT and
# a long long (below 0 as 0) any number of times, the last holding; any
# other word, or COUNT last, a syntax error

# the count of XRANGE's options as read so far, or their error
type XCnt is Data:
  XCOk{c: Nat}
  XCBad{r: Reply}

def xr.count.of(m: Maybe<&2, Nat>) -> XCnt:
  match m:
    case Some{c}:
      XCOk{c}
    case None{}:
      XCBad{e_int()}

def xr.count(cnt: Bool, +v: String) -> XCnt:
  match cnt:
    case True{}:
      xr.count.of(xc.of(ll.read(v)))
    case False{}:
      XCBad{e_syntax_r()}

def xr.opts(xs: List<&2, String>, r: XCnt) -> XCnt:
  match xs r:
    case Con{+w, Con{+v, rest}} XCOk{c}:
      xr.opts(rest, xr.count(is_word(w, "COUNT"), v))
    case Con{w, Nil{}} XCOk{c}:
      XCBad{e_syntax_r()}
    case _ other:
      other

def xq.of(rev: Bool, q: XQ) -> XQ:
  match rev:
    case True{}:
      XQRev{q}
    case False{}:
      q

def xr.cmd(r: XCnt, +rev: Bool, +k: String, +lo: KV.XId, +hi: KV.XId) -> Cmd:
  match r:
    case XCOk{+c}:
      Peek{k, PStream{XRRange{xq.of(rev, XQ{lo, hi, c})}}}
    case XCBad{e}:
      Bad{e}

def xr.hi(b: X.XB, +rev: Bool, +k: String, +lo: KV.XId, xs: List<&2, String>) -> Cmd:
  match b:
    case X.XB{+hi}:
      xr.cmd(xr.opts(xs, XCOk{xc.inf()}), rev, k, lo, hi)
    case X.XBBad{}:
      Bad{e_xid()}
    case X.XBOver{}:
      Bad{e_xend()}

def xr.lo(b: X.XB, +rev: Bool, +k: String, +e: String, xs: List<&2, String>) -> Cmd:
  match b:
    case X.XB{+lo}:
      xr.hi(X.xb.parse(e, False{}), rev, k, lo, xs)
    case X.XBBad{}:
      Bad{e_xid()}
    case X.XBOver{}:
      Bad{e_xstart()}

def xrange.parse(+rev: Bool, +k: String, +a: String, +e: String, xs: List<&2, String>) -> Cmd:
  xr.lo(X.xb.parse(a, True{}), rev, k, e, xs)

# XREAD [COUNT count] [BLOCK ms] STREAMS key... id..., read as
# xreadCommand reads it: its options in any order up to STREAMS, the last
# of a kind holding (BLOCK a long long of ms, not below 0; COUNT a long
# long, 0 and below for none), GROUP and NOACK XREADGROUP's alone, any
# other word, or an option without its value, a syntax error; STREAMS
# with words after it, as many keys as IDs. One key without BLOCK is a
# Peek of it; more, or BLOCK, are SXRead, which the server sees. BendKV
# blocks on no stream yet: a BLOCK that would wait answers an error
# (server.bend, sh.plain), but in MULTI, where Redis answers it as a
# client that may not wait, a null array.

# XREAD's options as read so far, a word at a time: COUNT's (0 for none),
# whether BLOCK came, and what the next word is (want: 0 an option, 1
# BLOCK's value, 2 COUNT's); or, past STREAMS, the words after it (the
# last first); or the error that ends them
type XRo is Data:
  XRo{c: Nat, block: Bool, want: Nat}
  XRoAt{c: Nat, block: Bool, ws: List<&2, String>}
  XRoBad{r: Reply}

# an option's word: 1 BLOCK, 2 COUNT, 3 STREAMS, 4 GROUP, 5 NOACK, 0 another
def xro.word(+w: String) -> Nat:
  +up = String.to_upper(cstr(w))
  Bool.pick(Nat, String.eq(up, "BLOCK"), 1n, Bool.pick(Nat, String.eq(up, "COUNT"), 2n, Bool.pick(Nat, String.eq(up, "STREAMS"), 3n, Bool.pick(Nat, String.eq(up, "GROUP"), 4n, Bool.pick(Nat, String.eq(up, "NOACK"), 5n, 0n)))))

def e_xunbalanced() -> Reply:
  RError{"ERR Unbalanced XREAD list of streams: for each stream key an ID or '$' must be specified."}

# an option of word k, with more words after it
def xro.opt(+k: Nat, +more: Nat, +c: Nat, +b: Bool) -> XRo:
  match k:
    case 1n:
      Bool.pick(XRo, Nat.is_lt(0n, more), XRo{c, b, 1n}, XRoBad{e_syntax_r()})
    case 2n:
      Bool.pick(XRo, Nat.is_lt(0n, more), XRo{c, b, 2n}, XRoBad{e_syntax_r()})
    case 3n:
      Bool.pick(XRo, Nat.is_lt(0n, more), Bool.pick(XRo, Nat.is_eq(Nat.mod(more, 2n), 1n), XRoBad{e_xunbalanced()}, XRoAt{c, b, Nil{}}), XRoBad{e_syntax_r()})
    case 4n:
      Bool.pick(XRo, Nat.is_le(2n, more), XRoBad{RError{"ERR The GROUP option is only supported by XREADGROUP. You called XREAD instead."}}, XRoBad{e_syntax_r()})
    case 5n:
      XRoBad{RError{"ERR The NOACK option is only supported by XREADGROUP. You called XREAD instead."}}
    case _:
      XRoBad{e_syntax_r()}

# BLOCK's value: a long long of ms, not below 0
def xro.block(l: LL, +c: Nat) -> XRo:
  match l:
    case LL{True{}, hi, lo}:
      XRoBad{RError{"ERR timeout is negative"}}
    case LL{False{}, hi, lo}:
      XRo{c, True{}, 0n}
    case LLBad{}:
      XRoBad{RError{"ERR timeout is not an integer or out of range"}}

def xro.count(m: Maybe<&2, Nat>, +b: Bool) -> XRo:
  match m:
    case Some{+c}:
      XRo{c, b, 0n}
    case None{}:
      XRoBad{e_int()}

# the options after one more word w, more words after it
def xro.step(+w: String, +more: Nat, o: XRo) -> XRo:
  match o:
    case XRo{+c, +b, want}:
      match want:
        case 0n:
          xro.opt(xro.word(w), more, c, b)
        case 1n:
          xro.block(ll.read(w), c)
        case _:
          xro.count(xc.of(ll.read(w)), b)
    case XRoAt{c, b, ws}:
      XRoAt{c, b, w <> ws}
    case XRoBad{r}:
      XRoBad{r}

def xro.go(xs: List<&2, String>, +n: Nat, o: XRo) -> XRo:
  match xs:
    case Nil{}:
      o
    case Con{+w, rest}:
      +m = Nat.sub(n, 1n)
      xro.go(rest, m, xro.step(w, m, o))

# a count of XREAD (0 for none) as a read takes it
def xc.read(+c: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_eq(c, 0n), xc.inf(), c)

def xread.keys(+c: Nat, b: Bool, ws: List<&2, String>) -> Cmd:
  match b ws:
    case False{} Con{+k, Con{+id, Nil{}}}:
      Peek{k, PStream{XRRead{XRq{k, id, xc.read(c)}}}}
    case False{} other:
      Own{SXRead{XRm{xc.read(c), False{}, other}}}
    case True{} other:
      Own{SXRead{XRm{xc.read(c), True{}, other}}}

def xread.cmd(o: XRo) -> Cmd:
  match o:
    case XRo{c, b, w}:
      e_syntax()
    case XRoAt{+c, +b, ws}:
      xread.keys(c, b, List.reverse(&2, String, ws))
    case XRoBad{r}:
      Bad{r}

def xread.parse(+args: List<&2, String>) -> Cmd:
  xread.cmd(xro.go(args, List.length(&2, String, args), XRo{0n, False{}, 0n}))

# with 3 words at least (XREAD's arity, -4)
def xread.of(+args: List<&2, String>) -> Cmd:
  Bool.pick(Cmd, Nat.is_le(3n, List.length(&2, String, args)), xread.parse(args), e_arity("xread"))

# XINFO: CONSUMERS key group, GROUPS key, STREAM key [FULL [COUNT
# count]], HELP; its options read once the key is found
def xinfo_id(+n: String, len: Nat) -> Nat:
  match len:
    case 4n:
      Bool.pick(Nat, String.eq(n, "HELP"), 1n, 0n)
    case 6n:
      Bool.pick(Nat, String.eq(n, "STREAM"), 2n, Bool.pick(Nat, String.eq(n, "GROUPS"), 3n, 0n))
    case 9n:
      Bool.pick(Nat, String.eq(n, "CONSUMERS"), 4n, 0n)
    case _:
      0n

def xinfo_help() -> List<&2, String>:
  ["CONSUMERS <key> <groupname>",
   "    Show consumers of <groupname>.",
   "GROUPS <key>",
   "    Show the stream consumer groups.",
   "STREAM <key> [FULL [COUNT <count>]",
   "    Show information about the stream."]

def xinfo.parse(id: Nat, sub: String, args: List<&2, String>) -> Cmd:
  match id:
    case 1n:  # HELP
      match args:
        case Nil{}:
          Own{help("XINFO", xinfo_help())}
        case _:
          e_arity("xinfo|help")
    case 2n:  # STREAM
      match args:
        case Con{k, rest}:
          Peek{k, PStream{XRInfo{XIStream{sub, rest}}}}
        case Nil{}:
          e_arity("xinfo|stream")
    case 3n:  # GROUPS
      match args:
        case Con{k, Nil{}}:
          Peek{k, PStream{XRInfo{XIGroups{}}}}
        case _:
          e_arity("xinfo|groups")
    case 4n:  # CONSUMERS
      match args:
        case Con{+k, Con{g, Nil{}}}:
          Peek{k, PStream{XRInfo{XICons{k, g}}}}
        case _:
          e_arity("xinfo|consumers")
    case _:
      Own{e_unknown_sub(sub, "XINFO")}

# XPENDING key group [[IDLE min-idle-time] start end count [consumer]],
# read as xpendingCommand reads it: 3 words, or 6 to 9 (else a syntax
# error); IDLE's time (a long long), with 8 words at least; the count (a
# long long, below 0 as 0), then the start and the end (bounds,
# X.xb.parse), then the consumer, when there is one (the words after it
# are not read)

# IDLE's time: none for 0
def xp.idle(l: LL) -> Maybe<&2, X.XIdle>:
  match l:
    case LL{+neg, +hi, +lo}:
      +n = xc.of.big(Nat.is_le(140737n, hi), hi, lo)
      Some{Bool.pick(X.XIdle, Nat.is_eq(n, 0n), X.XINone{}, X.XIMin{neg, n})}
    case LLBad{}:
      None{}

def xp.con(xs: List<&2, String>) -> Maybe<&2, String>:
  match xs:
    case Con{c, rest}:
      Some{c}
    case Nil{}:
      None{}

def xp.end(b: X.XB, +k: String, +g: String, +idle: X.XIdle, +lo: KV.XId, +c: Nat, con: Maybe<&2, String>) -> Cmd:
  match b:
    case X.XB{+hi}:
      Peek{k, PStream{XRPend{XPExt{k, g, idle, lo, hi, c, con}}}}
    case X.XBBad{}:
      Bad{e_xid()}
    case X.XBOver{}:
      Bad{e_xend()}

def xp.start(b: X.XB, +k: String, +g: String, +idle: X.XIdle, +c: Nat, +e: String, con: Maybe<&2, String>) -> Cmd:
  match b:
    case X.XB{+lo}:
      xp.end(X.xb.parse(e, False{}), k, g, idle, lo, c, con)
    case X.XBBad{}:
      Bad{e_xid()}
    case X.XBOver{}:
      Bad{e_xstart()}

def xp.count(m: Maybe<&2, Nat>, +k: String, +g: String, +idle: X.XIdle, xs: List<&2, String>) -> Cmd:
  match m xs:
    case Some{+c} Con{+a, Con{+e, Con{n, rest}}}:
      xp.start(X.xb.parse(a, True{}), k, g, idle, c, e, xp.con(rest))
    case None{} _:
      Bad{e_int()}
    case _ _:
      e_syntax()

# the count, the third word of xs
def xp.third(xs: List<&2, String>) -> Maybe<&2, Nat>:
  match xs:
    case Con{a, Con{e, Con{+n, rest}}}:
      xc.of(ll.read(n))
    case _:
      Some{0n}

def xp.ext(i: X.XIdle, +k: String, +g: String, +xs: List<&2, String>) -> Cmd:
  xp.count(xp.third(xs), k, g, i, xs)

def xp.idle.at(m: Maybe<&2, X.XIdle>, enough: Bool, +k: String, +g: String, +xs: List<&2, String>) -> Cmd:
  match m enough:
    case Some{i} True{}:
      xp.ext(i, k, g, xs)
    case Some{i} False{}:
      e_syntax()
    case None{} _:
      Bad{e_int()}

def xp.of(idle: Bool, +k: String, +g: String, +n: Nat, xs: List<&2, String>) -> Cmd:
  match idle xs:
    case True{} Con{w, Con{+v, rest}}:
      xp.idle.at(xp.idle(ll.read(v)), Nat.is_le(5n, n), k, g, rest)
    case _ other:
      xp.ext(X.XINone{}, k, g, other)

def xp.shape(+n: Nat) -> Bool:
  Bool.and(Nat.is_le(3n, n), Nat.is_le(n, 6n))

def xp.head(+xs: List<&2, String>) -> Bool:
  match xs:
    case Con{+w, rest}:
      is_word(w, "IDLE")
    case Nil{}:
      False{}

def xpending.of(+n: Nat, +k: String, +g: String, +xs: List<&2, String>) -> Cmd:
  match n:
    case 0n:
      Peek{k, PStream{XRPend{XPSum{k, g}}}}
    case _:
      Bool.pick(Cmd, xp.shape(n), xp.of(xp.head(xs), k, g, n, xs), e_syntax())

def xpending.parse(+k: String, +g: String, +xs: List<&2, String>) -> Cmd:
  xpending.of(List.length(&2, String, xs), k, g, xs)

# XADD key [NOMKSTREAM] [MAXLEN|MINID [=|~] threshold [LIMIT count]]
# *|id field value [field value ...] and XTRIM key MAXLEN|MINID [=|~]
# threshold [LIMIT count], read as streamParseAddOrTrimArgsOrReply reads
# them: a word at a time from the one after the key, the last of a kind
# holding; XADD's "*" its ID at once; MAXLEN or MINID and its threshold
# when a word follows it, with ~ or = before the threshold when two do
# (a count, a long long not below 0; an ID, read strictly), MAXLEN or
# MINID a second time a syntax error; LIMIT and its count when a word
# follows it (a long long not below 0); XADD's NOMKSTREAM; any other word
# XADD's ID (read strictly, or <ms>-*), XTRIM's syntax error. Then a
# LIMIT but 0 without a strategy, XTRIM without one, and LIMIT without ~
# are each a syntax error; ~ without LIMIT takes 10000, 100 times
# Redis's default node of 100 entries. XADD's fields and values follow
# its ID, two words at least and an even number of them, and its ID is
# not 0-0.

def e_xmaxlen() -> Reply:
  RError{"ERR The MAXLEN argument must be >= 0."}

def e_xlimit() -> Reply:
  RError{"ERR The LIMIT argument must be >= 0."}

def e_xboth() -> Reply:
  RError{"ERR syntax error, MAXLEN and MINID options at the same time are not compatible"}

def e_xnostrat() -> Reply:
  RError{"ERR syntax error, LIMIT cannot be used without specifying a trimming strategy"}

def e_xtrimstrat() -> Reply:
  RError{"ERR syntax error, XTRIM must be called with a trimming strategy"}

def e_xnotilde() -> Reply:
  RError{"ERR syntax error, LIMIT cannot be used without the special ~ option"}

def e_xzero() -> Reply:
  RError{"ERR The ID specified in XADD must be greater than 0-0"}

def e_xadd_arity() -> Reply:
  RError{"ERR wrong number of arguments for 'xadd' command"}

# a trim as XADD and XTRIM read it: none, or its strategy, its
# threshold's word as it came, whether by whole nodes (~), and its limit
# (0 for none)
type XTo is Data:
  XTNo{}
  XTo{s: X.XTs, v: String, ap: Bool, lim: Nat}

def xto.is(+t: XTo) -> Bool:
  match t:
    case XTNo{}:
      False{}
    case XTo{s, v, ap, lim}:
      True{}

def xto.ap(+t: XTo) -> Bool:
  match t:
    case XTNo{}:
      False{}
    case XTo{s, v, +ap, lim}:
      ap

# the options read so far: the trim (its limit not set yet), LIMIT's
# count and whether it came, NOMKSTREAM
type XOp is Data:
  XOp{tr: XTo, lim: Nat, limg: Bool, nomk: Bool}

def xop.none() -> XOp:
  XOp{XTNo{}, 0n, False{}, False{}}

def xop.has(+st: XOp) -> Bool:
  match st:
    case XOp{+tr, lim, limg, nomk}:
      xto.is(tr)

def xop.trim(st: XOp, +s: X.XTs, +v: String, +ap: Bool) -> XOp:
  match st:
    case XOp{tr, lim, limg, nomk}:
      XOp{XTo{s, v, ap, 0n}, lim, limg, nomk}

def xop.limit(st: XOp, +n: Nat) -> XOp:
  match st:
    case XOp{tr, lim, limg, nomk}:
      XOp{tr, n, True{}, nomk}

def xop.nomk(st: XOp) -> XOp:
  match st:
    case XOp{tr, lim, limg, nomk}:
      XOp{tr, lim, limg, True{}}

# XADD's ID: "*", <ms>-* (its ms), or an ID
type XAId is Data:
  XAAuto{}
  XASeq{ms: KV.XN}
  XAAt{id: KV.XId}

# a step of the option loop: the options so far and the words left; an
# error; XADD's ID (its word, the ID, the words after it); or the end of
# the words
type XOs is Data:
  XOsGo{st: XOp, ws: List<&2, String>}
  XOsBad{r: Reply}
  XOsId{st: XOp, w: String, id: XAId, fv: List<&2, String>}
  XOsEnd{st: XOp}

# what the word w is to the loop (more: a word follows it): 0 XADD's
# "*", 1 MAXLEN, 2 MINID, 3 LIMIT, 4 NOMKSTREAM, 5 XADD's ID, 6 XTRIM's
# syntax error
def xo.kind(+xadd: Bool, +w: String, +more: Bool) -> Nat:
  +star = Bool.and(xadd, Bool.and(U32.is_eq(String.code_at(w, 0n), 42), X.su.cend(w, 1n)))
  Bool.pick(Nat, star, 0n, Bool.pick(Nat, Bool.and(more, is_word(w, "MAXLEN")), 1n, Bool.pick(Nat, Bool.and(more, is_word(w, "MINID")), 2n, Bool.pick(Nat, Bool.and(more, is_word(w, "LIMIT")), 3n, Bool.pick(Nat, Bool.and(xadd, is_word(w, "NOMKSTREAM")), 4n, Bool.pick(Nat, xadd, 5n, 6n))))))

# a trim's operator: ~ (1), = (2), or none (0), each a C string of it
def xo.opw(+w: String) -> Nat:
  +c = String.code_at(w, 0n)
  Bool.pick(Nat, X.su.cend(w, 1n), Bool.pick(Nat, U32.is_eq(c, 126), 1n, Bool.pick(Nat, U32.is_eq(c, 61), 2n, 0n)), 0n)

# a count (MAXLEN's, LIMIT's): a long long not below 0 (neg: the error
# of one below), past any stream's as xc.inf()
def xo.count(l: LL, neg: Reply) -> XCnt:
  match l:
    case LL{+n, +hi, +lo}:
      Bool.pick(XCnt, n, XCBad{neg}, XCOk{xc.of.big(Nat.is_le(140737n, hi), hi, lo)})
    case LLBad{}:
      XCBad{e_int()}

def xo.thr.max(c: XCnt, +v: String, +ap: Bool, more: List<&2, String>, st: XOp) -> XOs:
  match c:
    case XCOk{+n}:
      XOsGo{xop.trim(st, X.XTMax{n}, v, ap), more}
    case XCBad{r}:
      XOsBad{r}

def xo.thr.min(m: Maybe<&2, KV.XId>, +v: String, +ap: Bool, more: List<&2, String>, st: XOp) -> XOs:
  match m:
    case Some{+id}:
      XOsGo{xop.trim(st, X.XTMin{id}, v, ap), more}
    case None{}:
      XOsBad{e_xid()}

# MAXLEN's (max) or MINID's threshold v (ap: after ~), the words more
# after it
def xo.thr(max: Bool, +v: String, +ap: Bool, more: List<&2, String>, st: XOp) -> XOs:
  match max:
    case True{}:
      xo.thr.max(xo.count(ll.read(v), e_xmaxlen()), v, ap, more, st)
    case False{}:
      xo.thr.min(X.xid.parse(v, True{}, X.xn.zero()), v, ap, more, st)

def xo.trim.two(c: Nat, +max: Bool, +a: String, +v: String, more: List<&2, String>, st: XOp) -> XOs:
  match c:
    case 0n:
      xo.thr(max, a, False{}, v <> more, st)
    case 1n:
      xo.thr(max, v, True{}, more, st)
    case _:
      xo.thr(max, v, False{}, more, st)

def xo.trim.at(+max: Bool, rest: List<&2, String>, st: XOp) -> XOs:
  match rest:
    case Con{+a, Con{+v, more}}:
      xo.trim.two(xo.opw(a), max, a, v, more, st)
    case Con{+v, Nil{}}:
      xo.thr(max, v, False{}, Nil{}, st)
    case Nil{}:
      XOsBad{e_syntax_r()}

def xo.trim(both: Bool, +max: Bool, rest: List<&2, String>, st: XOp) -> XOs:
  match both:
    case True{}:
      XOsBad{e_xboth()}
    case False{}:
      xo.trim.at(max, rest, st)

def xo.limit.of(c: XCnt, more: List<&2, String>, st: XOp) -> XOs:
  match c:
    case XCOk{+n}:
      XOsGo{xop.limit(st, n), more}
    case XCBad{r}:
      XOsBad{r}

def xo.limit(rest: List<&2, String>, st: XOp) -> XOs:
  match rest:
    case Con{+v, more}:
      xo.limit.of(xo.count(ll.read(v), e_xlimit()), more, st)
    case Nil{}:
      XOsBad{e_syntax_r()}

def xo.id(p: X.XIdP, +w: String, rest: List<&2, String>, st: XOp) -> XOs:
  match p:
    case X.XIdPSeq{ms}:
      XOsId{st, w, XASeq{ms}, rest}
    case X.XIdPAt{id}:
      XOsId{st, w, XAAt{id}, rest}
    case X.XIdPBad{}:
      XOsBad{e_xid()}

def xo.word(+c: Nat, +w: String, rest: List<&2, String>, +st: XOp) -> XOs:
  match c:
    case 0n:
      XOsId{st, w, XAAuto{}, rest}
    case 1n:
      xo.trim(xop.has(st), True{}, rest, st)
    case 2n:
      xo.trim(xop.has(st), False{}, rest, st)
    case 3n:
      xo.limit(rest, st)
    case 4n:
      XOsGo{xop.nomk(st), rest}
    case 5n:
      xo.id(X.xid.parse.add(w), w, rest, st)
    case _:
      XOsBad{e_syntax_r()}

def xo.step(+xadd: Bool, ws: List<&2, String>, +st: XOp) -> XOs:
  match ws:
    case Nil{}:
      XOsEnd{st}
    case Con{+w, +rest}:
      xo.word(xo.kind(xadd, w, Bool.not(List.is_empty(&2, String, rest))), w, rest, st)

# the loop, k more steps at most
def xo.loop(k: Nat, +xadd: Bool, s: XOs) -> XOs:
  match k s:
    case 1n+j XOsGo{+st, ws}:
      xo.loop(j, xadd, xo.step(xadd, ws, st))
    case _ other:
      other

def xo.run(+xadd: Bool, +ws: List<&2, String>) -> XOs:
  xo.loop(Nat.add(List.length(&2, String, ws), 1n), xadd, XOsGo{xop.none(), ws})

# the checks after the options (xadd: XADD's), and the trim with its
# limit, and NOMKSTREAM
type XTq is Data:
  XTqOk{tr: XTo, nomk: Bool}
  XTqBad{r: Reply}

def xo.post.tr(tr: XTo, +lim: Nat, +limg: Bool) -> XTo:
  match tr:
    case XTo{+s, +v, +ap, l}:
      XTo{s, v, ap, Bool.pick(Nat, ap, Bool.pick(Nat, limg, lim, 10000n), 0n)}
    case XTNo{}:
      XTNo{}

def xo.post(st: XOp, +xadd: Bool) -> XTq:
  match st:
    case XOp{+tr, +lim, +limg, +nomk}:
      +has = xto.is(tr)
      Bool.pick(XTq, Bool.and(Nat.is_lt(0n, lim), Bool.not(has)), XTqBad{e_xnostrat()}, Bool.pick(XTq, Bool.and(Bool.not(xadd), Bool.not(has)), XTqBad{e_xtrimstrat()}, Bool.pick(XTq, Bool.and(limg, Bool.not(xto.ap(tr))), XTqBad{e_xnotilde()}, XTqOk{xo.post.tr(tr, lim, limg), nomk})))

# XADD's arguments read: NOMKSTREAM, the trim, the ID and its word, the
# fields and values and how many pairs; or the error
type XA is Data:
  XA{nomk: Bool, tr: XTo, id: XAId, w: String, fv: List<&2, String>, nf: Nat}
  XABad{r: Reply}

def xaid.zero(+id: XAId) -> Bool:
  match id:
    case XAAt{+x}:
      X.xid.is_zero(x)
    case _:
      False{}

def xadd.zero(z: Bool, tr: XTo, +nomk: Bool, +id: XAId, +w: String, fv: List<&2, String>, +n: Nat) -> XA:
  match z:
    case True{}:
      XABad{e_xzero()}
    case False{}:
      XA{nomk, tr, id, w, fv, Nat.div(n, 2n)}

def xadd.fv.of(bad: Bool, tr: XTo, +nomk: Bool, +id: XAId, +w: String, fv: List<&2, String>, +n: Nat) -> XA:
  match bad:
    case True{}:
      XABad{e_xadd_arity()}
    case False{}:
      xadd.zero(xaid.zero(id), tr, nomk, id, w, fv, n)

def xadd.fv(q: XTq, +w: String, +id: XAId, +fv: List<&2, String>) -> XA:
  match q:
    case XTqBad{r}:
      XABad{r}
    case XTqOk{tr, +nomk}:
      +n = List.length(&2, String, fv)
      xadd.fv.of(Bool.or(Nat.is_lt(n, 2n), Nat.is_eq(Nat.mod(n, 2n), 1n)), tr, nomk, id, w, fv, n)

def xadd.end(q: XTq) -> XA:
  match q:
    case XTqBad{r}:
      XABad{r}
    case XTqOk{tr, nomk}:
      XABad{e_xadd_arity()}

def xadd.of(s: XOs) -> XA:
  match s:
    case XOsBad{r}:
      XABad{r}
    case XOsId{st, +w, +id, +fv}:
      xadd.fv(xo.post(st, True{}), w, id, fv)
    case XOsEnd{st}:
      xadd.end(xo.post(st, True{}))
    case XOsGo{st, ws}:
      xadd.end(xo.post(st, True{}))

# XADD's arguments after its key, as they read
def xadd.read(+ws: List<&2, String>) -> XA:
  xadd.of(xo.run(True{}, ws))

# XTRIM's arguments read: the trim; or the error
type XT is Data:
  XT{tr: XTo}
  XTBad{r: Reply}

def xtrim.q(q: XTq) -> XT:
  match q:
    case XTqOk{tr, nomk}:
      XT{tr}
    case XTqBad{r}:
      XTBad{r}

def xtrim.of(s: XOs) -> XT:
  match s:
    case XOsBad{r}:
      XTBad{r}
    case XOsEnd{st}:
      xtrim.q(xo.post(st, False{}))
    case _:
      XTBad{e_syntax_r()}

def xtrim.read(+ws: List<&2, String>) -> XT:
  xtrim.of(xo.run(False{}, ws))

# XSETID key last-id [ENTRIESADDED entries-added] [MAXDELETEDID
# max-deleted-id], read as xsetidCommand reads it before the key: the ID
# (read strictly), then its options in any order, each with a word after
# it (a long long not below 0; an ID read strictly, not past the first),
# any other word a syntax error
type XS is Data:
  XS{id: KV.XId, added: Maybe<&2, KV.XN>, maxdel: KV.XId}
  XSBad{r: Reply}

type XSs is Data:
  XSsGo{s: XS, ws: List<&2, String>}
  XSsEnd{s: XS}

# an option's word (more: a word follows it): 1 ENTRIESADDED, 2
# MAXDELETEDID, 0 another
def xsetid.opt(+w: String, +more: Bool) -> Nat:
  Bool.pick(Nat, Bool.and(more, is_word(w, "ENTRIESADDED")), 1n, Bool.pick(Nat, Bool.and(more, is_word(w, "MAXDELETEDID")), 2n, 0n))

def xsetid.added(l: LL, +v: String, s: XS, more: List<&2, String>) -> XSs:
  match l s:
    case LL{+neg, hi, lo} XS{+id, a, +md}:
      Bool.pick(XSs, neg, XSsEnd{XSBad{RError{"ERR entries_added must be positive"}}}, XSsGo{XS{id, Some{KV.xn.of_int(v)}, md}, more})
    case LLBad{} x:
      XSsEnd{XSBad{e_int()}}
    case _ bad:
      XSsEnd{bad}

def xsetid.maxdel(m: Maybe<&2, KV.XId>, s: XS, more: List<&2, String>) -> XSs:
  match m s:
    case Some{+md} XS{+id, +a, old}:
      Bool.pick(XSs, Cmp.is_lt(KV.xid.cmp(id, md)), XSsEnd{XSBad{RError{"ERR The ID specified in XSETID is smaller than the provided max_deleted_entry_id"}}}, XSsGo{XS{id, a, md}, more})
    case None{} x:
      XSsEnd{XSBad{e_xid()}}
    case _ bad:
      XSsEnd{bad}

def xsetid.word(c: Nat, rest: List<&2, String>, s: XS) -> XSs:
  match c rest:
    case 1n Con{+v, more}:
      xsetid.added(ll.read(v), v, s, more)
    case 2n Con{+v, more}:
      xsetid.maxdel(X.xid.parse(v, True{}, X.xn.zero()), s, more)
    case _ _:
      XSsEnd{XSBad{e_syntax_r()}}

def xsetid.step(ws: List<&2, String>, s: XS) -> XSs:
  match ws:
    case Nil{}:
      XSsEnd{s}
    case Con{+w, +rest}:
      xsetid.word(xsetid.opt(w, Bool.not(List.is_empty(&2, String, rest))), rest, s)

def xsetid.loop(k: Nat, s: XSs) -> XS:
  match k s:
    case 1n+j XSsGo{x, ws}:
      xsetid.loop(j, xsetid.step(ws, x))
    case _ XSsEnd{x}:
      x
    case _ XSsGo{x, ws}:
      x

def xsetid.id(m: Maybe<&2, KV.XId>, +rest: List<&2, String>) -> XS:
  match m:
    case Some{id}:
      xsetid.loop(Nat.add(List.length(&2, String, rest), 1n), XSsGo{XS{id, None{}, X.xid.zero()}, rest})
    case None{}:
      XSBad{e_xid()}

# XSETID's arguments after its key, as they read
def xsetid.read(ws: List<&2, String>) -> XS:
  match ws:
    case Con{+i, rest}:
      xsetid.id(X.xid.parse(i, True{}, X.xn.zero()), rest)
    case Nil{}:
      XSBad{RError{"ERR wrong number of arguments for 'xsetid' command"}}

# the errors of the words of each, none when they read: the parser's
# checks, which the writes run again (and PROOF.bend's log_args reads
# the effects back with)
def xadd.err.of(a: XA) -> Maybe<&2, Reply>:
  match a:
    case XA{nomk, tr, id, w, fv, nf}:
      None{}
    case XABad{r}:
      Some{r}

def xadd.err(+ws: List<&2, String>) -> Maybe<&2, Reply>:
  xadd.err.of(xadd.read(ws))

def xtrim.err.of(t: XT) -> Maybe<&2, Reply>:
  match t:
    case XT{tr}:
      None{}
    case XTBad{r}:
      Some{r}

def xtrim.err(+ws: List<&2, String>) -> Maybe<&2, Reply>:
  xtrim.err.of(xtrim.read(ws))

def xsetid.err.of(s: XS) -> Maybe<&2, Reply>:
  match s:
    case XS{id, a, md}:
      None{}
    case XSBad{r}:
      Some{r}

def xsetid.err(+ws: List<&2, String>) -> Maybe<&2, Reply>:
  xsetid.err.of(xsetid.read(ws))

# a write of a stream, or its error
def xwr.cmd(m: Maybe<&2, Reply>, +k: String, op: XWrite) -> Cmd:
  match m:
    case None{}:
      Upd{k, UStream{op}}
    case Some{r}:
      Bad{r}

def xadd.parse(+k: String, +ws: List<&2, String>) -> Cmd:
  xwr.cmd(xadd.err(ws), k, XWAdd{ws})

def xtrim.parse(+k: String, +ws: List<&2, String>) -> Cmd:
  xwr.cmd(xtrim.err(ws), k, XWTrim{ws})

def xsetid.parse(+k: String, +ws: List<&2, String>) -> Cmd:
  xwr.cmd(xsetid.err(ws), k, XWSetId{ws})

# The script of a new stream: its key deleted, then XADD of its
# arguments, as the file logs an XADD where a key whose time had passed
# lay (as for a new hash: one entry). BendKV reads it as XWNew when its
# arguments read as XADD's.
def xnew.script() -> String:
  "redis.call('del',KEYS[1]) return redis.call('xadd',KEYS[1],unpack(ARGV))"

def parse_eval.xnew.of(m: Maybe<&2, Reply>, +k: String, ws: List<&2, String>) -> Cmd:
  match m:
    case None{}:
      Upd{k, UStream{XWNew{ws}}}
    case Some{r}:
      e_lua()

def parse_eval.xnew(ok: Bool, rest: List<&2, String>) -> Cmd:
  match ok rest:
    case True{} Con{+k, +ws}:
      parse_eval.xnew.of(xadd.err(ws), k, ws)
    case _ _:
      e_lua()

# which script: 1 a new hash's, list's or set's, 2 a list's move, 3 a
# set's move, 4 a new sorted set's, 5 a new stream's, 0 another
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
    case 5n:
      parse_eval.xnew(String.eq(nk, "1"), rest)
    case _:
      e_lua()

def parse_eval(args: List<&2, String>) -> Cmd:
  match args:
    case Con{+s, Con{+nk, rest}}:
      parse_eval.which(Bool.pick(Nat, String.eq(s, hnew.script()), 1n, Bool.pick(Nat, String.eq(s, lmove.script()), 2n, Bool.pick(Nat, String.eq(s, smove.script()), 3n, Bool.pick(Nat, String.eq(s, znew.script()), 4n, Bool.pick(Nat, String.eq(s, xnew.script()), 5n, 0n))))), nk, rest)
    case _:
      e_arity("eval")

# Dump and restore
# ----------------
# DUMP's payload (PDump) and RESTORE's (URestore) are rdb.bend's: Redis's
# RDB serialization of a value, its version and its CRC64. RESTORE key
# ttl payload [REPLACE] [ABSTTL] [IDLETIME s] [FREQ f] reads its options
# first, as restoreCommand does (rs.go: IDLETIME not after FREQ, nor FREQ
# after IDLETIME, each with a value of its own, their errors Redis's),
# then, once the key is looked up: BUSYKEY for a key there without
# REPLACE, the time's errors (not a long long; less than 0), the
# payload's version or checksum (D.verify), its value (D.load: "Bad data
# format"); then OK, and the key set to the payload's value with its time
# (none for 0; ABSTTL's from 1970, else from now), or, for a time already
# past (or one from now past LLONG_MAX, which Redis's sum wraps into the
# past), deleted when it was there (REPLACE), else left as it is.
# IDLETIME and FREQ (ac: 0 none, 1 + f FREQ f, 257 + s IDLETIME: rs.idle.at)
# are the server's to set, in the key's access cell.

# RESTORE's options as read so far: REPLACE, ABSTTL, the access option
# (ac), and whether the next word is IDLETIME's value (want 1) or FREQ's
# (want 2); or the error of one
type RsO is Data:
  RsO{rep: Bool, abs: Bool, ac: Nat, want: Nat}
  RsBad{r: Reply}

# an option's word: 1 REPLACE, 2 ABSTTL, 3 IDLETIME, 4 FREQ, 0 another
def rs.word(+w: String) -> Nat:
  +up = String.to_upper(cstr(w))
  Bool.pick(Nat, String.eq(up, "REPLACE"), 1n, Bool.pick(Nat, String.eq(up, "ABSTTL"), 2n, Bool.pick(Nat, String.eq(up, "IDLETIME"), 3n, Bool.pick(Nat, String.eq(up, "FREQ"), 4n, 0n))))

# whether FREQ was given (an IDLETIME after it is a syntax error), and
# IDLETIME (so for a FREQ after it)
def rs.freq(+ac: Nat) -> Bool:
  Bool.and(Nat.is_lt(0n, ac), Nat.is_le(ac, 256n))

def rs.idle(+ac: Nat) -> Bool:
  Nat.is_lt(256n, ac)

def rs.after(bad: Bool, +rep: Bool, +abs: Bool, +ac: Nat, +want: Nat) -> RsO:
  Bool.pick(RsO, bad, RsBad{e_syntax_r()}, RsO{rep, abs, ac, want})

def rs.opt(+c: Nat, +rep: Bool, +abs: Bool, +ac: Nat) -> RsO:
  match c:
    case 1n:
      RsO{True{}, abs, ac, 0n}
    case 2n:
      RsO{rep, True{}, ac, 0n}
    case 3n:
      rs.after(rs.freq(ac), rep, abs, ac, 1n)
    case 4n:
      rs.after(rs.idle(ac), rep, abs, ac, 2n)
    case _:
      RsBad{e_syntax_r()}

# IDLETIME's value: a long long at least 0, its seconds (hi * 10^9 + lo)
# kept as Redis's LRU clock of 24 bits reads them (objectSetLRUOrLFU):
# below 2^24 as they are, else as 2^24 and their remainder mod 2^24, more
# than any second the clock shows (10^9 is 10144256 mod 2^24). Past
# LLONG_MAX / 1000 s Redis's product of them and 1000 overflows; BendKV
# reads them as below. FREQ's value: a long long from 0 to 255.
def rs.idle.at(+hi: Nat, +lo: Nat) -> Nat:
  Bool.pick(Nat, Bool.and(Nat.is_eq(hi, 0n), Nat.is_lt(lo, 16777216n)), lo, Nat.add(16777216n, Nat.mod(Nat.add(Nat.mul(Nat.mod(hi, 16777216n), 10144256n), lo), 16777216n)))

def rs.idle.of(l: LL, +rep: Bool, +abs: Bool) -> RsO:
  match l:
    case LL{neg, +hi, +lo}:
      Bool.pick(RsO, neg, RsBad{RError{"ERR Invalid IDLETIME value, must be >= 0"}}, RsO{rep, abs, Nat.add(257n, rs.idle.at(hi, lo)), 0n})
    case LLBad{}:
      RsBad{e_int()}

def rs.freq.of(l: LL, +rep: Bool, +abs: Bool) -> RsO:
  match l:
    case LL{neg, +hi, +lo}:
      +bad = Bool.or(neg, Bool.or(Nat.is_lt(0n, hi), Nat.is_lt(255n, lo)))
      Bool.pick(RsO, bad, RsBad{RError{"ERR Invalid FREQ value, must be >= 0 and <= 255"}}, RsO{rep, abs, Nat.add(1n, lo), 0n})
    case LLBad{}:
      RsBad{e_int()}

# the options after one more word w
def rs.step(+w: String, o: RsO) -> RsO:
  match o:
    case RsO{+rep, +abs, +ac, want}:
      match want:
        case 0n:
          rs.opt(rs.word(w), rep, abs, ac)
        case 1n:
          rs.idle.of(ll.read(w), rep, abs)
        case _:
          rs.freq.of(ll.read(w), rep, abs)
    case RsBad{r}:
      RsBad{r}

def rs.go(xs: List<&2, String>, o: RsO) -> RsO:
  match xs:
    case Nil{}:
      o
    case Con{+w, rest}:
      rs.go(rest, rs.step(w, o))

# RESTORE once its options are read: an update of its key, a command of
# the session with IDLETIME or FREQ (SRestore); IDLETIME or FREQ last,
# without its value, is a syntax error, as Redis takes neither without
# one
def restore.upd(own: Bool, +k: String, op: UpdOp) -> Cmd:
  match own:
    case False{}:
      Upd{k, op}
    case True{}:
      Own{SRestore{k, op}}

def restore.want(+want: Nat, +k: String, +ttl: String, p: String, +rep: Bool, +abs: Bool, +ac: Nat) -> Cmd:
  Bool.pick(Cmd, Nat.is_eq(want, 0n), restore.upd(Nat.is_lt(0n, ac), k, URestore{p, tm.of(ttl, abs, False{}, False{}, "restore"), rep, ac}), e_syntax())

def restore.cmd(o: RsO, +k: String, +ttl: String, p: String) -> Cmd:
  match o:
    case RsO{+rep, +abs, +ac, +want}:
      restore.want(want, k, ttl, p, rep, abs, ac)
    case RsBad{r}:
      Bad{r}

def restore.parse(+k: String, +ttl: String, p: String, xs: List<&2, String>) -> Cmd:
  restore.cmd(rs.go(xs, RsO{False{}, False{}, 0n, 0n}), k, ttl, p)

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
          IncrBy{k, ByPos{0n, 1n}}
        case _:
          e_arity("incr")
    case 11n:  # DECR
      match args:
        case Con{k, Nil{}}:
          IncrBy{k, ByNeg{0n, 1n}}
        case _:
          e_arity("decr")
    case 12n:  # INCRBY
      match args:
        case Con{k, Con{n, Nil{}}}:
          parse_incrby(k, ll.read(n))
        case _:
          e_arity("incrby")
    case 13n:  # DECRBY
      match args:
        case Con{k, Con{n, Nil{}}}:
          parse_decrby(k, ll.read(n))
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
          parse_hincrby(k, f, ll.read(n))
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
    case 177n:  # SORT
      parse_sort(args, False{}, "sort")
    case 178n:  # SORT_RO
      parse_sort(args, True{}, "sort_ro")
    case 179n:  # PFADD
      match args:
        case Con{k, rest}:
          Upd{k, UHll{HAdd{rest}}}
        case Nil{}:
          e_arity("pfadd")
    case 180n:  # PFCOUNT
      match args:
        case Con{k, Nil{}}:
          Upd{k, UHll{HCount{}}}
        case Con{k, rest}:
          Own{SPfCount{k <> rest}}
        case Nil{}:
          e_arity("pfcount")
    case 181n:  # PFMERGE
      match args:
        case Con{d, rest}:
          Own{SPfMerge{d, rest}}
        case Nil{}:
          e_arity("pfmerge")
    case 182n:  # PFDEBUG
      match args:
        case Con{sub, Con{k, Nil{}}}:
          Upd{k, UHll{HDebug{sub}}}
        case _:
          e_arity("pfdebug")
    case 183n:  # PFSELFTEST
      match args:
        case Nil{}:
          Own{SPfSelfTest{}}
        case _:
          e_arity("pfselftest")
    case 184n:  # LASTSAVE
      match args:
        case Nil{}:
          Own{SAdmin{0n, Nil{}}}
        case _:
          e_arity("lastsave")
    case 185n:  # ROLE
      match args:
        case Nil{}:
          Own{SReply{role.reply()}}
        case _:
          e_arity("role")
    case 186n:  # WAIT
      wait.of(args)
    case 187n:  # SHUTDOWN
      shutdown.cmd(args)
    case 188n:  # LOLWUT
      lolwut.of(args)
    case 189n:  # GEOADD
      match args:
        case Con{+k, Con{+a, Con{+b, Con{+c, rest}}}}:
          parse_geoadd(k, Con{a, Con{b, Con{c, rest}}})
        case _:
          e_arity("geoadd")
    case 190n:  # GEODIST
      parse_geodist(args)
    case 191n:  # GEOHASH
      match args:
        case Con{k, ms}:
          Peek{k, PZset{ZRGeoHash{ms}}}
        case Nil{}:
          e_arity("geohash")
    case 192n:  # GEOPOS
      match args:
        case Con{k, ms}:
          Peek{k, PZset{ZRGeoPos{ms}}}
        case Nil{}:
          e_arity("geopos")
    case 193n:  # GEORADIUS
      geo.parse(0n, name, args, 5n, "georadius")
    case 194n:  # GEORADIUS_RO
      geo.parse(1n, name, args, 5n, "georadius_ro")
    case 195n:  # GEORADIUSBYMEMBER
      geo.parse(2n, name, args, 4n, "georadiusbymember")
    case 196n:  # GEORADIUSBYMEMBER_RO
      geo.parse(3n, name, args, 4n, "georadiusbymember_ro")
    case 197n:  # GEOSEARCH
      geo.parse(4n, name, args, 6n, "geosearch")
    case 198n:  # GEOSEARCHSTORE
      geo.parse(5n, name, args, 7n, "geosearchstore")
    case 199n:  # DUMP
      match args:
        case Con{k, Nil{}}:
          Peek{k, PDump{}}
        case _:
          e_arity("dump")
    case 200n:  # RESTORE
      match args:
        case Con{k, Con{ttl, Con{p, rest}}}:
          restore.parse(k, ttl, p, rest)
        case _:
          e_arity("restore")
    case 201n:  # SLOWLOG
      match args:
        case Nil{}:
          e_arity("slowlog")
        case Con{+sub, rest}:
          +up = String.to_upper(sub)
          Own{parse_slowlog(slowlog_id(up, String.length(up)), sub, rest)}
    case 202n:  # LATENCY
      match args:
        case Nil{}:
          e_arity("latency")
        case Con{+sub, rest}:
          +up = String.to_upper(sub)
          Own{parse_latency(latency_id(up, String.length(up)), sub, rest)}
    case 203n:  # SAVE
      match args:
        case Nil{}:
          Own{SAdmin{15n, Nil{}}}
        case _:
          e_arity("save")
    case 210n:  # ACL
      match args:
        case Nil{}:
          e_arity("acl")
        case Con{+sub, rest}:
          +up = String.to_upper(sub)
          Own{parse_acl(acl_id(up, String.length(up)), sub, rest)}
    case 211n:  # XLEN
      match args:
        case Con{k, Nil{}}:
          Peek{k, PStream{XRLen{}}}
        case _:
          e_arity("xlen")
    case 212n:  # XRANGE
      match args:
        case Con{+k, Con{+a, Con{+e, rest}}}:
          xrange.parse(False{}, k, a, e, rest)
        case _:
          e_arity("xrange")
    case 213n:  # XREVRANGE
      match args:
        case Con{+k, Con{+e, Con{+a, rest}}}:
          xrange.parse(True{}, k, a, e, rest)
        case _:
          e_arity("xrevrange")
    case 214n:  # XREAD
      xread.of(args)
    case 215n:  # XINFO
      match args:
        case Nil{}:
          e_arity("xinfo")
        case Con{+sub, rest}:
          +up = String.to_upper(sub)
          xinfo.parse(xinfo_id(up, String.length(up)), sub, rest)
    case 216n:  # XPENDING
      match args:
        case Con{+k, Con{+g, rest}}:
          xpending.parse(k, g, rest)
        case _:
          e_arity("xpending")
    case 217n:  # XADD
      match args:
        case Con{+k, Con{+a, Con{+b, Con{+c, rest}}}}:
          xadd.parse(k, Con{a, Con{b, Con{c, rest}}})
        case _:
          e_arity("xadd")
    case 218n:  # XTRIM
      match args:
        case Con{+k, Con{+a, Con{+b, rest}}}:
          xtrim.parse(k, Con{a, Con{b, rest}})
        case _:
          e_arity("xtrim")
    case 219n:  # XDEL
      match args:
        case Con{k, Con{i, rest}}:
          Upd{k, UStream{XWDel{Con{i, rest}}}}
        case _:
          e_arity("xdel")
    case 220n:  # XSETID
      match args:
        case Con{+k, Con{+i, rest}}:
          xsetid.parse(k, Con{i, rest})
        case _:
          e_arity("xsetid")
    case _:
      e_unknown(name, args)

# a blocking command of number id with n arguments at least (block.least)
# or just n (block.just), as Redis checks a command's arity before it runs
def block.of(ok: Bool, +id: Nat, name: String, args: List<&2, String>) -> SessOp:
  match ok:
    case True{}:
      SBlock{id, args}
    case False{}:
      s_arity(name)

def block.least(+id: Nat, +n: Nat, name: String, +args: List<&2, String>) -> SessOp:
  block.of(Nat.is_le(n, List.length(&2, String, args)), id, name, args)

def block.just(+id: Nat, +n: Nat, name: String, +args: List<&2, String>) -> SessOp:
  block.of(Nat.is_eq(n, List.length(&2, String, args)), id, name, args)

# AUTH's arguments, its password put as its SHA-256: the session
# compares that with the users' hashes (session.bend, login_ok), so that a
# call hashes its password once, here, however many of its reply, its
# client's connection and the server's log in ask. More arguments are a
# syntax error, which reads no password
def auth.hashed(args: List<&2, String>) -> List<&2, String>:
  match args:
    case Con{p, Nil{}}:
      [Sha.sha256(p)]
    case Con{u, Con{p, Nil{}}}:
      [u, Sha.sha256(p)]
    case xs:
      xs

# what HELLO's next argument is, after an option x with n arguments from
# it on: the user of an AUTH that has its two (1), the name of a SETNAME
# that has its one (3), or none, past an option the session refuses (4)
def hello.hashed.opt(au: Bool, sn: Bool) -> Nat:
  match au sn:
    case True{} _:
      1n
    case False{} True{}:
      3n
    case False{} False{}:
      4n

# HELLO's options from xs on, n of them, each AUTH's password put as its
# SHA-256 (as AUTH's): they are read as the session reads them
# (session.bend, hello.step), st saying what the next one is: an option
# (0), the user of an AUTH (1), its password (2), the name of a SETNAME
# (3); past an option the session refuses (4), the rest is as it was
def hello.hashed.go(xs: List<&2, String>, +n: Nat, +st: Nat) -> List<&2, String>:
  match xs st:
    case Nil{} _:
      Nil{}
    case Con{+x, rest} 0n:
      x <> hello.hashed.go(rest, Nat.sub(n, 1n), hello.hashed.opt(Bool.and(is_word(x, "AUTH"), Nat.is_le(3n, n)), Bool.and(is_word(x, "SETNAME"), Nat.is_le(2n, n))))
    case Con{x, rest} 1n:
      x <> hello.hashed.go(rest, Nat.sub(n, 1n), 2n)
    case Con{x, rest} 2n:
      Sha.sha256(x) <> hello.hashed.go(rest, Nat.sub(n, 1n), 0n)
    case Con{x, rest} 3n:
      x <> hello.hashed.go(rest, Nat.sub(n, 1n), 0n)
    case Con{x, rest} _:
      x <> rest

# HELLO's arguments: its version, then its options with their passwords
# hashed. A version the session refuses leaves the options unread
def hello.hashed(args: List<&2, String>) -> List<&2, String>:
  match args:
    case Con{v, +rest}:
      v <> hello.hashed.go(rest, List.length(&2, String, rest), 0n)
    case Nil{}:
      Nil{}

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
      SHello{hello.hashed(args)}
    case 102n:  # AUTH
      match args:
        case Nil{}:
          s_arity("auth")
        case Con{a, rest}:
          SAuth{auth.hashed(a <> rest)}
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
    case 153n:  # BLPOP
      block.least(153n, 2n, "blpop", args)
    case 154n:  # BRPOP
      block.least(154n, 2n, "brpop", args)
    case 155n:  # BRPOPLPUSH
      block.just(155n, 3n, "brpoplpush", args)
    case 156n:  # BLMOVE
      block.just(156n, 5n, "blmove", args)
    case 157n:  # BLMPOP
      block.least(157n, 4n, "blmpop", args)
    case 158n:  # BZPOPMIN
      block.least(158n, 2n, "bzpopmin", args)
    case 159n:  # BZPOPMAX
      block.least(159n, 2n, "bzpopmax", args)
    case 160n:  # BZMPOP
      block.least(160n, 4n, "bzmpop", args)
    case 161n:  # MULTI
      match args:
        case Nil{}:
          SMulti{}
        case _:
          s_arity("multi")
    case 162n:  # EXEC
      match args:
        case Nil{}:
          SExec{}
        case _:
          s_arity("exec")
    case 163n:  # DISCARD
      match args:
        case Nil{}:
          SDiscard{}
        case _:
          s_arity("discard")
    case 164n:  # WATCH
      match args:
        case Con{k, rest}:
          SWatch{k <> rest}
        case Nil{}:
          s_arity("watch")
    case 165n:  # UNWATCH
      match args:
        case Nil{}:
          SUnwatch{}
        case _:
          s_arity("unwatch")
    case 166n:  # SUBSCRIBE
      match args:
        case Con{c, rest}:
          SPub{0n, c <> rest}
        case Nil{}:
          s_arity("subscribe")
    case 167n:  # UNSUBSCRIBE
      SPub{3n, args}
    case 168n:  # PSUBSCRIBE
      match args:
        case Con{c, rest}:
          SPub{1n, c <> rest}
        case Nil{}:
          s_arity("psubscribe")
    case 169n:  # PUNSUBSCRIBE
      SPub{4n, args}
    case 170n:  # SSUBSCRIBE
      match args:
        case Con{c, rest}:
          SPub{2n, c <> rest}
        case Nil{}:
          s_arity("ssubscribe")
    case 171n:  # SUNSUBSCRIBE
      SPub{5n, args}
    case 172n:  # PUBLISH
      match args:
        case Con{c, Con{m, Nil{}}}:
          SPub{6n, [c, m]}
        case _:
          s_arity("publish")
    case 173n:  # SPUBLISH
      match args:
        case Con{c, Con{m, Nil{}}}:
          SPub{7n, [c, m]}
        case _:
          s_arity("spublish")
    case 174n:  # PUBSUB
      match args:
        case Nil{}:
          s_arity("pubsub")
        case Con{+sub, rest}:
          +up = String.to_upper(sub)
          parse_pubsub(pubsub_id(up, String.length(up)), sub, rest)
    case 175n:  # MONITOR
      match args:
        case Nil{}:
          SMonitor{}
        case _:
          s_arity("monitor")
    case 176n:  # BGREWRITEAOF
      match args:
        case Nil{}:
          SRewrite{}
        case _:
          s_arity("bgrewriteaof")
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
# With the key comes what a call counts as (stat.code: 3 times the key
# plus that, its class: code.key and code.class read them back): 0 when it runs; 1 when it is refused before it runs, as
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
    case 153n:
      153n
    case 154n:
      154n
    case 155n:
      155n
    case 156n:
      156n
    case 157n:
      157n
    case 158n:
      158n
    case 159n:
      159n
    case 160n:
      160n
    case 161n:
      161n
    case 162n:
      162n
    case 163n:
      163n
    case 164n:
      164n
    case 165n:
      165n
    case 166n:
      166n
    case 167n:
      167n
    case 168n:
      168n
    case 169n:
      169n
    case 170n:
      170n
    case 171n:
      171n
    case 172n:
      172n
    case 173n:
      173n
    case 174n:
      174n
    case 175n:
      175n
    case 176n:
      176n
    case 177n:
      177n
    case 178n:
      178n
    case 179n:
      179n
    case 180n:
      180n
    case 181n:
      181n
    case 182n:
      182n
    case 183n:
      183n
    case 184n:
      184n
    case 185n:
      185n
    case 186n:
      186n
    case 187n:
      187n
    case 188n:
      188n
    case 189n:
      189n
    case 190n:
      190n
    case 191n:
      191n
    case 192n:
      192n
    case 193n:
      193n
    case 194n:
      194n
    case 195n:
      195n
    case 196n:
      196n
    case 197n:
      197n
    case 198n:
      198n
    case 199n:
      199n
    case 200n:
      200n
    case 201n:
      201n
    case 202n:
      202n
    case 203n:
      203n
    case 210n:
      204n
    case 211n:
      205n
    case 212n:
      206n
    case 213n:
      207n
    case 214n:
      208n
    case 215n:
      209n
    case 216n:
      210n
    case 217n:
      211n
    case 218n:
      212n
    case 219n:
      213n
    case 220n:
      214n
    case _:
      0n

# a subcommand of CLIENT's key, by its number; 0 for none
def stat.sub.client(+sub: Nat) -> Nat:
  match sub:
    case 1n:
      215n
    case 2n:
      216n
    case 3n:
      217n
    case 4n:
      218n
    case 5n:
      219n
    case 6n:
      220n
    case 7n:
      221n
    case 8n:
      222n
    case 9n:
      223n
    case 10n:
      224n
    case 11n:
      225n
    case 12n:
      226n
    case 13n:
      227n
    case 14n:
      228n
    case 15n:
      229n
    case 16n:
      230n
    case _:
      0n

# a subcommand of FUNCTION's key, by its number; 0 for none
def stat.sub.function(+sub: Nat) -> Nat:
  match sub:
    case 1n:
      231n
    case 2n:
      232n
    case _:
      0n

# a subcommand of CONFIG's key, by its number; 0 for none
def stat.sub.config(+sub: Nat) -> Nat:
  match sub:
    case 1n:
      233n
    case 2n:
      234n
    case 3n:
      235n
    case 4n:
      236n
    case 5n:
      237n
    case _:
      0n

# a subcommand of COMMAND's key, by its number; 0 for none
def stat.sub.command(+sub: Nat) -> Nat:
  match sub:
    case 1n:
      238n
    case 2n:
      239n
    case 3n:
      240n
    case 4n:
      241n
    case 5n:
      242n
    case 6n:
      243n
    case 7n:
      244n
    case _:
      0n

# a subcommand of OBJECT's key, by its number; 0 for none
def stat.sub.object(+sub: Nat) -> Nat:
  match sub:
    case 1n:
      245n
    case 2n:
      246n
    case 3n:
      247n
    case 4n:
      248n
    case 5n:
      249n
    case _:
      0n

# a subcommand of MEMORY's key, by its number; 0 for none
def stat.sub.memory(+sub: Nat) -> Nat:
  match sub:
    case 1n:
      250n
    case 2n:
      251n
    case 3n:
      252n
    case 4n:
      253n
    case 5n:
      254n
    case 6n:
      255n
    case _:
      0n

# a subcommand of PUBSUB's key, by its number; 0 for none
def stat.sub.pubsub(+sub: Nat) -> Nat:
  match sub:
    case 1n:
      256n
    case 2n:
      257n
    case 3n:
      258n
    case 4n:
      259n
    case 5n:
      260n
    case 6n:
      261n
    case _:
      0n

# a subcommand of SLOWLOG's key, by its number; 0 for none
def stat.sub.slowlog(+sub: Nat) -> Nat:
  match sub:
    case 1n:
      262n
    case 2n:
      263n
    case 3n:
      264n
    case 4n:
      265n
    case _:
      0n

# a subcommand of LATENCY's key, by its number; 0 for none
def stat.sub.latency(+sub: Nat) -> Nat:
  match sub:
    case 1n:
      266n
    case 2n:
      267n
    case 3n:
      268n
    case 4n:
      269n
    case 5n:
      270n
    case 6n:
      271n
    case 7n:
      272n
    case _:
      0n

# a subcommand of ACL's key, by its number; 0 for none
def stat.sub.acl(+sub: Nat) -> Nat:
  match sub:
    case 1n:
      273n
    case 2n:
      274n
    case 3n:
      275n
    case 4n:
      276n
    case 5n:
      277n
    case 6n:
      278n
    case 7n:
      279n
    case 8n:
      280n
    case 9n:
      281n
    case 10n:
      282n
    case 11n:
      283n
    case 12n:
      284n
    case 13n:
      285n
    case _:
      0n

# a subcommand of XINFO's key, by its number; 0 for none
def stat.sub.xinfo(+sub: Nat) -> Nat:
  match sub:
    case 1n:
      286n
    case 2n:
      287n
    case 3n:
      288n
    case 4n:
      289n
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
      "blpop"
    case 154n:
      "brpop"
    case 155n:
      "brpoplpush"
    case 156n:
      "blmove"
    case 157n:
      "blmpop"
    case 158n:
      "bzpopmin"
    case 159n:
      "bzpopmax"
    case 160n:
      "bzmpop"
    case 161n:
      "multi"
    case 162n:
      "exec"
    case 163n:
      "discard"
    case 164n:
      "watch"
    case 165n:
      "unwatch"
    case 166n:
      "subscribe"
    case 167n:
      "unsubscribe"
    case 168n:
      "psubscribe"
    case 169n:
      "punsubscribe"
    case 170n:
      "ssubscribe"
    case 171n:
      "sunsubscribe"
    case 172n:
      "publish"
    case 173n:
      "spublish"
    case 174n:
      "pubsub"
    case 175n:
      "monitor"
    case 176n:
      "bgrewriteaof"
    case 177n:
      "sort"
    case 178n:
      "sort_ro"
    case 179n:
      "pfadd"
    case 180n:
      "pfcount"
    case 181n:
      "pfmerge"
    case 182n:
      "pfdebug"
    case 183n:
      "pfselftest"
    case 184n:
      "lastsave"
    case 185n:
      "role"
    case 186n:
      "wait"
    case 187n:
      "shutdown"
    case 188n:
      "lolwut"
    case 189n:
      "geoadd"
    case 190n:
      "geodist"
    case 191n:
      "geohash"
    case 192n:
      "geopos"
    case 193n:
      "georadius"
    case 194n:
      "georadius_ro"
    case 195n:
      "georadiusbymember"
    case 196n:
      "georadiusbymember_ro"
    case 197n:
      "geosearch"
    case 198n:
      "geosearchstore"
    case 199n:
      "dump"
    case 200n:
      "restore"
    case 201n:
      "slowlog"
    case 202n:
      "latency"
    case 203n:
      "save"
    case 204n:
      "acl"
    case 205n:
      "xlen"
    case 206n:
      "xrange"
    case 207n:
      "xrevrange"
    case 208n:
      "xread"
    case 209n:
      "xinfo"
    case 210n:
      "xpending"
    case 211n:
      "xadd"
    case 212n:
      "xtrim"
    case 213n:
      "xdel"
    case 214n:
      "xsetid"
    case 215n:
      "client|id"
    case 216n:
      "client|help"
    case 217n:
      "client|reply"
    case 218n:
      "client|getname"
    case 219n:
      "client|setname"
    case 220n:
      "client|caching"
    case 221n:
      "client|unblock"
    case 222n:
      "client|getredir"
    case 223n:
      "client|no-evict"
    case 224n:
      "client|trackinginfo"
    case 225n:
      "client|list"
    case 226n:
      "client|info"
    case 227n:
      "client|kill"
    case 228n:
      "client|pause"
    case 229n:
      "client|unpause"
    case 230n:
      "client|tracking"
    case 231n:
      "function|flush"
    case 232n:
      "function|help"
    case 233n:
      "config|get"
    case 234n:
      "config|set"
    case 235n:
      "config|resetstat"
    case 236n:
      "config|rewrite"
    case 237n:
      "config|help"
    case 238n:
      "command|info"
    case 239n:
      "command|docs"
    case 240n:
      "command|list"
    case 241n:
      "command|help"
    case 242n:
      "command|count"
    case 243n:
      "command|getkeys"
    case 244n:
      "command|getkeysandflags"
    case 245n:
      "object|help"
    case 246n:
      "object|freq"
    case 247n:
      "object|encoding"
    case 248n:
      "object|refcount"
    case 249n:
      "object|idletime"
    case 250n:
      "memory|help"
    case 251n:
      "memory|usage"
    case 252n:
      "memory|stats"
    case 253n:
      "memory|doctor"
    case 254n:
      "memory|purge"
    case 255n:
      "memory|malloc-stats"
    case 256n:
      "pubsub|channels"
    case 257n:
      "pubsub|help"
    case 258n:
      "pubsub|numpat"
    case 259n:
      "pubsub|numsub"
    case 260n:
      "pubsub|shardchannels"
    case 261n:
      "pubsub|shardnumsub"
    case 262n:
      "slowlog|get"
    case 263n:
      "slowlog|len"
    case 264n:
      "slowlog|reset"
    case 265n:
      "slowlog|help"
    case 266n:
      "latency|doctor"
    case 267n:
      "latency|graph"
    case 268n:
      "latency|help"
    case 269n:
      "latency|histogram"
    case 270n:
      "latency|history"
    case 271n:
      "latency|latest"
    case 272n:
      "latency|reset"
    case 273n:
      "acl|cat"
    case 274n:
      "acl|deluser"
    case 275n:
      "acl|dryrun"
    case 276n:
      "acl|genpass"
    case 277n:
      "acl|getuser"
    case 278n:
      "acl|help"
    case 279n:
      "acl|list"
    case 280n:
      "acl|load"
    case 281n:
      "acl|log"
    case 282n:
      "acl|save"
    case 283n:
      "acl|setuser"
    case 284n:
      "acl|users"
    case 285n:
      "acl|whoami"
    case 286n:
      "xinfo|help"
    case 287n:
      "xinfo|stream"
    case 288n:
      "xinfo|groups"
    case 289n:
      "xinfo|consumers"
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
      7n
    case 154n:
      7n
    case 155n:
      8n
    case 156n:
      12n
    case 157n:
      11n
    case 158n:
      7n
    case 159n:
      7n
    case 160n:
      11n
    case 161n:
      2n
    case 162n:
      2n
    case 163n:
      2n
    case 164n:
      5n
    case 165n:
      2n
    case 166n:
      5n
    case 167n:
      3n
    case 168n:
      5n
    case 169n:
      3n
    case 170n:
      5n
    case 171n:
      3n
    case 172n:
      6n
    case 173n:
      6n
    case 174n:
      5n
    case 175n:
      2n
    case 176n:
      2n
    case 177n:
      5n
    case 178n:
      5n
    case 179n:
      5n
    case 180n:
      5n
    case 181n:
      5n
    case 182n:
      6n
    case 183n:
      2n
    case 184n:
      2n
    case 185n:
      2n
    case 186n:
      6n
    case 187n:
      3n
    case 188n:
      3n
    case 189n:
      11n
    case 190n:
      9n
    case 191n:
      5n
    case 192n:
      5n
    case 193n:
      13n
    case 194n:
      13n
    case 195n:
      11n
    case 196n:
      11n
    case 197n:
      15n
    case 198n:
      17n
    case 199n:
      4n
    case 200n:
      9n
    case 201n:
      5n
    case 202n:
      5n
    case 203n:
      2n
    case 204n:
      5n
    case 205n:
      4n
    case 206n:
      9n
    case 207n:
      9n
    case 208n:
      9n
    case 209n:
      5n
    case 210n:
      7n
    case 211n:
      11n
    case 212n:
      9n
    case 213n:
      7n
    case 214n:
      7n
    case 215n:
      4n
    case 216n:
      4n
    case 217n:
      6n
    case 218n:
      4n
    case 219n:
      6n
    case 220n:
      6n
    case 221n:
      7n
    case 222n:
      4n
    case 223n:
      6n
    case 224n:
      4n
    case 225n:
      5n
    case 226n:
      4n
    case 227n:
      7n
    case 228n:
      7n
    case 229n:
      4n
    case 230n:
      7n
    case 231n:
      5n
    case 232n:
      4n
    case 233n:
      7n
    case 234n:
      9n
    case 235n:
      4n
    case 236n:
      4n
    case 237n:
      4n
    case 238n:
      5n
    case 239n:
      5n
    case 240n:
      5n
    case 241n:
      4n
    case 242n:
      4n
    case 243n:
      9n
    case 244n:
      9n
    case 245n:
      4n
    case 246n:
      6n
    case 247n:
      6n
    case 248n:
      6n
    case 249n:
      6n
    case 250n:
      4n
    case 251n:
      7n
    case 252n:
      4n
    case 253n:
      4n
    case 254n:
      4n
    case 255n:
      4n
    case 256n:
      5n
    case 257n:
      4n
    case 258n:
      4n
    case 259n:
      5n
    case 260n:
      5n
    case 261n:
      5n
    case 262n:
      5n
    case 263n:
      4n
    case 264n:
      4n
    case 265n:
      4n
    case 266n:
      4n
    case 267n:
      6n
    case 268n:
      4n
    case 269n:
      5n
    case 270n:
      6n
    case 271n:
      4n
    case 272n:
      5n
    case 273n:
      5n
    case 274n:
      7n
    case 275n:
      9n
    case 276n:
      5n
    case 277n:
      6n
    case 278n:
      4n
    case 279n:
      4n
    case 280n:
      4n
    case 281n:
      5n
    case 282n:
      4n
    case 283n:
      7n
    case 284n:
      4n
    case 285n:
      4n
    case 286n:
      4n
    case 287n:
      7n
    case 288n:
      6n
    case 289n:
      8n
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
    case 177n:
      True{}
    case 178n:
      True{}
    case 179n:
      True{}
    case 180n:
      True{}
    case 181n:
      True{}
    case 182n:
      True{}
    case 183n:
      True{}
    case 189n:
      True{}
    case 190n:
      True{}
    case 191n:
      True{}
    case 192n:
      True{}
    case 193n:
      True{}
    case 194n:
      True{}
    case 195n:
      True{}
    case 196n:
      True{}
    case 197n:
      True{}
    case 198n:
      True{}
    case 200n:
      True{}
    case 205n:
      True{}
    case 206n:
      True{}
    case 207n:
      True{}
    case 208n:
      True{}
    case 210n:
      True{}
    case 211n:
      True{}
    case 212n:
      True{}
    case 213n:
      True{}
    case 214n:
      True{}
    case 246n:
      True{}
    case 249n:
      True{}
    case 251n:
      True{}
    case 287n:
      True{}
    case 288n:
      True{}
    case 289n:
      True{}
    case _:
      False{}

# whether a call of the command of a key goes unseen by MONITOR: an
# administrative command (admin), or one that feeds the monitors
# itself (skip_monitor), as Redis's call() leaves them out
def stat.unseen(+key: Nat) -> Bool:
  match key:
    case 65n:
      True{}
    case 175n:
      True{}
    case 176n:
      True{}
    case 182n:
      True{}
    case 183n:
      True{}
    case 187n:
      True{}
    case 203n:
      True{}
    case 221n:
      True{}
    case 223n:
      True{}
    case 225n:
      True{}
    case 227n:
      True{}
    case 228n:
      True{}
    case 229n:
      True{}
    case 233n:
      True{}
    case 234n:
      True{}
    case 235n:
      True{}
    case 236n:
      True{}
    case 262n:
      True{}
    case 263n:
      True{}
    case 264n:
      True{}
    case 266n:
      True{}
    case 267n:
      True{}
    case 269n:
      True{}
    case 270n:
      True{}
    case 271n:
      True{}
    case 272n:
      True{}
    case 274n:
      True{}
    case 275n:
      True{}
    case 277n:
      True{}
    case 279n:
      True{}
    case 280n:
      True{}
    case 281n:
      True{}
    case 282n:
      True{}
    case 283n:
      True{}
    case 284n:
      True{}
    case _:
      False{}

# whether the command of a key reads or writes keys, or may be
# replicated (write, readonly, may_replicate): a monitor may not run it
def stat.keyspace(+key: Nat) -> Bool:
  match key:
    case 3n:
      True{}
    case 4n:
      True{}
    case 5n:
      True{}
    case 6n:
      True{}
    case 7n:
      True{}
    case 8n:
      True{}
    case 9n:
      True{}
    case 10n:
      True{}
    case 11n:
      True{}
    case 12n:
      True{}
    case 13n:
      True{}
    case 14n:
      True{}
    case 15n:
      True{}
    case 16n:
      True{}
    case 17n:
      True{}
    case 18n:
      True{}
    case 19n:
      True{}
    case 20n:
      True{}
    case 21n:
      True{}
    case 22n:
      True{}
    case 23n:
      True{}
    case 24n:
      True{}
    case 25n:
      True{}
    case 26n:
      True{}
    case 27n:
      True{}
    case 28n:
      True{}
    case 29n:
      True{}
    case 30n:
      True{}
    case 31n:
      True{}
    case 32n:
      True{}
    case 33n:
      True{}
    case 34n:
      True{}
    case 35n:
      True{}
    case 36n:
      True{}
    case 37n:
      True{}
    case 38n:
      True{}
    case 39n:
      True{}
    case 40n:
      True{}
    case 41n:
      True{}
    case 42n:
      True{}
    case 43n:
      True{}
    case 44n:
      True{}
    case 45n:
      True{}
    case 46n:
      True{}
    case 47n:
      True{}
    case 48n:
      True{}
    case 49n:
      True{}
    case 50n:
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
    case 65n:
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
    case 110n:
      True{}
    case 111n:
      True{}
    case 112n:
      True{}
    case 115n:
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
    case 153n:
      True{}
    case 154n:
      True{}
    case 155n:
      True{}
    case 156n:
      True{}
    case 157n:
      True{}
    case 158n:
      True{}
    case 159n:
      True{}
    case 160n:
      True{}
    case 172n:
      True{}
    case 173n:
      True{}
    case 177n:
      True{}
    case 178n:
      True{}
    case 179n:
      True{}
    case 180n:
      True{}
    case 181n:
      True{}
    case 182n:
      True{}
    case 188n:
      True{}
    case 189n:
      True{}
    case 190n:
      True{}
    case 191n:
      True{}
    case 192n:
      True{}
    case 193n:
      True{}
    case 194n:
      True{}
    case 195n:
      True{}
    case 196n:
      True{}
    case 197n:
      True{}
    case 198n:
      True{}
    case 199n:
      True{}
    case 200n:
      True{}
    case 205n:
      True{}
    case 206n:
      True{}
    case 207n:
      True{}
    case 208n:
      True{}
    case 210n:
      True{}
    case 211n:
      True{}
    case 212n:
      True{}
    case 213n:
      True{}
    case 214n:
      True{}
    case 231n:
      True{}
    case 246n:
      True{}
    case 247n:
      True{}
    case 248n:
      True{}
    case 249n:
      True{}
    case 251n:
      True{}
    case 287n:
      True{}
    case 288n:
      True{}
    case 289n:
      True{}
    case _:
      False{}

# whether CLIENT PAUSE WRITE holds a call of the command of a key back:
# one that writes or may be replicated (write, may_replicate)
def stat.pausable(+key: Nat) -> Bool:
  match key:
    case 4n:
      True{}
    case 5n:
      True{}
    case 6n:
      True{}
    case 7n:
      True{}
    case 8n:
      True{}
    case 10n:
      True{}
    case 11n:
      True{}
    case 12n:
      True{}
    case 13n:
      True{}
    case 14n:
      True{}
    case 17n:
      True{}
    case 19n:
      True{}
    case 20n:
      True{}
    case 23n:
      True{}
    case 24n:
      True{}
    case 26n:
      True{}
    case 27n:
      True{}
    case 28n:
      True{}
    case 29n:
      True{}
    case 30n:
      True{}
    case 31n:
      True{}
    case 36n:
      True{}
    case 39n:
      True{}
    case 41n:
      True{}
    case 45n:
      True{}
    case 46n:
      True{}
    case 47n:
      True{}
    case 48n:
      True{}
    case 49n:
      True{}
    case 51n:
      True{}
    case 52n:
      True{}
    case 55n:
      True{}
    case 56n:
      True{}
    case 63n:
      True{}
    case 65n:
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
    case 75n:
      True{}
    case 76n:
      True{}
    case 77n:
      True{}
    case 78n:
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
    case 90n:
      True{}
    case 93n:
      True{}
    case 95n:
      True{}
    case 97n:
      True{}
    case 98n:
      True{}
    case 99n:
      True{}
    case 111n:
      True{}
    case 112n:
      True{}
    case 115n:
      True{}
    case 119n:
      True{}
    case 121n:
      True{}
    case 122n:
      True{}
    case 123n:
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
    case 153n:
      True{}
    case 154n:
      True{}
    case 155n:
      True{}
    case 156n:
      True{}
    case 157n:
      True{}
    case 158n:
      True{}
    case 159n:
      True{}
    case 160n:
      True{}
    case 172n:
      True{}
    case 173n:
      True{}
    case 177n:
      True{}
    case 179n:
      True{}
    case 180n:
      True{}
    case 181n:
      True{}
    case 182n:
      True{}
    case 189n:
      True{}
    case 193n:
      True{}
    case 195n:
      True{}
    case 198n:
      True{}
    case 200n:
      True{}
    case 211n:
      True{}
    case 212n:
      True{}
    case 213n:
      True{}
    case 214n:
      True{}
    case 231n:
      True{}
    case _:
      False{}

# whether the command of a key may take memory (denyoom): past
# maxmemory with nothing left to evict, Redis refuses it
def stat.denyoom(+key: Nat) -> Bool:
  match key:
    case 4n:
      True{}
    case 5n:
      True{}
    case 6n:
      True{}
    case 10n:
      True{}
    case 11n:
      True{}
    case 12n:
      True{}
    case 13n:
      True{}
    case 14n:
      True{}
    case 17n:
      True{}
    case 23n:
      True{}
    case 24n:
      True{}
    case 39n:
      True{}
    case 41n:
      True{}
    case 45n:
      True{}
    case 48n:
      True{}
    case 49n:
      True{}
    case 51n:
      True{}
    case 52n:
      True{}
    case 55n:
      True{}
    case 63n:
      True{}
    case 66n:
      True{}
    case 67n:
      True{}
    case 68n:
      True{}
    case 69n:
      True{}
    case 75n:
      True{}
    case 76n:
      True{}
    case 80n:
      True{}
    case 81n:
      True{}
    case 83n:
      True{}
    case 93n:
      True{}
    case 95n:
      True{}
    case 97n:
      True{}
    case 98n:
      True{}
    case 99n:
      True{}
    case 115n:
      True{}
    case 121n:
      True{}
    case 122n:
      True{}
    case 147n:
      True{}
    case 148n:
      True{}
    case 149n:
      True{}
    case 150n:
      True{}
    case 155n:
      True{}
    case 156n:
      True{}
    case 177n:
      True{}
    case 179n:
      True{}
    case 181n:
      True{}
    case 182n:
      True{}
    case 189n:
      True{}
    case 193n:
      True{}
    case 195n:
      True{}
    case 198n:
      True{}
    case 200n:
      True{}
    case 211n:
      True{}
    case 214n:
      True{}
    case _:
      False{}

# whether the command of a key may not run in a transaction (no_multi:
# SHUTDOWN, SAVE): in MULTI, Redis refuses it before it is queued
def stat.nomulti(+key: Nat) -> Bool:
  match key:
    case 187n:
      True{}
    case 203n:
      True{}
    case _:
      False{}

# whether Redis flags the command of a key fast: the latency monitor
# names a slow call of it fast-command, of any other command
def stat.fast(+key: Nat) -> Bool:
  match key:
    case 1n:
      True{}
    case 2n:
      True{}
    case 3n:
      True{}
    case 5n:
      True{}
    case 6n:
      True{}
    case 8n:
      True{}
    case 9n:
      True{}
    case 10n:
      True{}
    case 11n:
      True{}
    case 12n:
      True{}
    case 13n:
      True{}
    case 14n:
      True{}
    case 15n:
      True{}
    case 16n:
      True{}
    case 18n:
      True{}
    case 25n:
      True{}
    case 26n:
      True{}
    case 27n:
      True{}
    case 28n:
      True{}
    case 29n:
      True{}
    case 30n:
      True{}
    case 31n:
      True{}
    case 32n:
      True{}
    case 33n:
      True{}
    case 34n:
      True{}
    case 35n:
      True{}
    case 36n:
      True{}
    case 40n:
      True{}
    case 44n:
      True{}
    case 47n:
      True{}
    case 50n:
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
    case 63n:
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
    case 90n:
      True{}
    case 98n:
      True{}
    case 99n:
      True{}
    case 100n:
      True{}
    case 101n:
      True{}
    case 102n:
      True{}
    case 103n:
      True{}
    case 104n:
      True{}
    case 111n:
      True{}
    case 112n:
      True{}
    case 113n:
      True{}
    case 119n:
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
    case 140n:
      True{}
    case 141n:
      True{}
    case 158n:
      True{}
    case 159n:
      True{}
    case 161n:
      True{}
    case 163n:
      True{}
    case 164n:
      True{}
    case 165n:
      True{}
    case 172n:
      True{}
    case 173n:
      True{}
    case 179n:
      True{}
    case 184n:
      True{}
    case 185n:
      True{}
    case 188n:
      True{}
    case 205n:
      True{}
    case 211n:
      True{}
    case 213n:
      True{}
    case 214n:
      True{}
    case _:
      False{}

# whether the slow log skips the calls of the command of a key
# (skip_slowlog: EXEC, whose commands are logged on their own)
def stat.noslow(+key: Nat) -> Bool:
  match key:
    case 162n:
      True{}
    case _:
      False{}

# whether the command of a key only reads (readonly): a client that
# tracks keys (CLIENT TRACKING) has the keys of its calls remembered
def stat.ro(+key: Nat) -> Bool:
  match key:
    case 3n:
      True{}
    case 9n:
      True{}
    case 15n:
      True{}
    case 16n:
      True{}
    case 18n:
      True{}
    case 21n:
      True{}
    case 22n:
      True{}
    case 25n:
      True{}
    case 32n:
      True{}
    case 33n:
      True{}
    case 34n:
      True{}
    case 35n:
      True{}
    case 37n:
      True{}
    case 38n:
      True{}
    case 40n:
      True{}
    case 42n:
      True{}
    case 43n:
      True{}
    case 44n:
      True{}
    case 50n:
      True{}
    case 53n:
      True{}
    case 54n:
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
    case 64n:
      True{}
    case 72n:
      True{}
    case 73n:
      True{}
    case 74n:
      True{}
    case 79n:
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
    case 91n:
      True{}
    case 92n:
      True{}
    case 94n:
      True{}
    case 96n:
      True{}
    case 110n:
      True{}
    case 116n:
      True{}
    case 117n:
      True{}
    case 120n:
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
    case 152n:
      True{}
    case 178n:
      True{}
    case 180n:
      True{}
    case 188n:
      True{}
    case 190n:
      True{}
    case 191n:
      True{}
    case 192n:
      True{}
    case 194n:
      True{}
    case 196n:
      True{}
    case 197n:
      True{}
    case 199n:
      True{}
    case 205n:
      True{}
    case 206n:
      True{}
    case 207n:
      True{}
    case 208n:
      True{}
    case 210n:
      True{}
    case 246n:
      True{}
    case 247n:
      True{}
    case 248n:
      True{}
    case 249n:
      True{}
    case 251n:
      True{}
    case 287n:
      True{}
    case 288n:
      True{}
    case 289n:
      True{}
    case _:
      False{}

# whether the command of a key touches the key of its first argument
# (its first key is there), as Redis's lookups set a key's access time:
# all but those that look a key up without touching it (LOOKUP_NOTOUCH)
def stat.touch(+key: Nat) -> Bool:
  match key:
    case 3n:
      True{}
    case 4n:
      True{}
    case 5n:
      True{}
    case 6n:
      True{}
    case 7n:
      True{}
    case 8n:
      True{}
    case 10n:
      True{}
    case 11n:
      True{}
    case 12n:
      True{}
    case 13n:
      True{}
    case 14n:
      True{}
    case 15n:
      True{}
    case 16n:
      True{}
    case 17n:
      True{}
    case 23n:
      True{}
    case 24n:
      True{}
    case 26n:
      True{}
    case 27n:
      True{}
    case 28n:
      True{}
    case 29n:
      True{}
    case 30n:
      True{}
    case 31n:
      True{}
    case 36n:
      True{}
    case 37n:
      True{}
    case 38n:
      True{}
    case 39n:
      True{}
    case 40n:
      True{}
    case 41n:
      True{}
    case 42n:
      True{}
    case 43n:
      True{}
    case 44n:
      True{}
    case 45n:
      True{}
    case 46n:
      True{}
    case 47n:
      True{}
    case 49n:
      True{}
    case 50n:
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
    case 112n:
      True{}
    case 115n:
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
    case 147n:
      True{}
    case 148n:
      True{}
    case 149n:
      True{}
    case 150n:
      True{}
    case 152n:
      True{}
    case 153n:
      True{}
    case 154n:
      True{}
    case 155n:
      True{}
    case 156n:
      True{}
    case 158n:
      True{}
    case 159n:
      True{}
    case 164n:
      True{}
    case 170n:
      True{}
    case 171n:
      True{}
    case 173n:
      True{}
    case 177n:
      True{}
    case 178n:
      True{}
    case 179n:
      True{}
    case 180n:
      True{}
    case 181n:
      True{}
    case 189n:
      True{}
    case 190n:
      True{}
    case 191n:
      True{}
    case 192n:
      True{}
    case 193n:
      True{}
    case 194n:
      True{}
    case 195n:
      True{}
    case 196n:
      True{}
    case 197n:
      True{}
    case 198n:
      True{}
    case 199n:
      True{}
    case 200n:
      True{}
    case 205n:
      True{}
    case 206n:
      True{}
    case 207n:
      True{}
    case 210n:
      True{}
    case 211n:
      True{}
    case 212n:
      True{}
    case 213n:
      True{}
    case 214n:
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
    case 736n:
      3161
    case 737n:
      3162
    case 738n:
      3164
    case 739n:
      3171
    case 740n:
      3173
    case 741n:
      3174
    case 742n:
      3177
    case 743n:
      3178
    case 744n:
      3180
    case 745n:
      3185
    case 746n:
      3186
    case 747n:
      3188
    case 748n:
      3192
    case 749n:
      3207
    case 750n:
      3211
    case 751n:
      3213
    case 752n:
      3214
    case 753n:
      3219
    case 754n:
      3221
    case 755n:
      3222
    case 756n:
      3225
    case 757n:
      3226
    case 758n:
      3228
    case 759n:
      3235
    case 760n:
      3237
    case 761n:
      3238
    case 762n:
      3241
    case 763n:
      3242
    case 764n:
      3244
    case 765n:
      3249
    case 766n:
      3250
    case 767n:
      3252
    case 768n:
      3256
    case 769n:
      3267
    case 770n:
      3269
    case 771n:
      3270
    case 772n:
      3273
    case 773n:
      3274
    case 774n:
      3276
    case 775n:
      3281
    case 776n:
      3282
    case 777n:
      3284
    case 778n:
      3288
    case 779n:
      3297
    case 780n:
      3298
    case 781n:
      3300
    case 782n:
      3304
    case 783n:
      3312
    case 784n:
      3335
    case 785n:
      3339
    case 786n:
      3341
    case 787n:
      3342
    case 788n:
      3347
    case 789n:
      3349
    case 790n:
      3350
    case 791n:
      3353
    case 792n:
      3354
    case 793n:
      3356
    case 794n:
      3363
    case 795n:
      3365
    case 796n:
      3366
    case 797n:
      3369
    case 798n:
      3370
    case 799n:
      3372
    case 800n:
      3377
    case 801n:
      3378
    case 802n:
      3380
    case 803n:
      3384
    case 804n:
      3395
    case 805n:
      3397
    case 806n:
      3398
    case 807n:
      3401
    case 808n:
      3402
    case 809n:
      3404
    case 810n:
      3409
    case 811n:
      3410
    case 812n:
      3412
    case 813n:
      3416
    case 814n:
      3425
    case 815n:
      3426
    case 816n:
      3428
    case 817n:
      3432
    case 818n:
      3440
    case 819n:
      3459
    case 820n:
      3461
    case 821n:
      3462
    case 822n:
      3465
    case 823n:
      3466
    case 824n:
      3468
    case 825n:
      3473
    case 826n:
      3474
    case 827n:
      3476
    case 828n:
      3480
    case 829n:
      3489
    case 830n:
      3490
    case 831n:
      3492
    case 832n:
      3496
    case 833n:
      3504
    case 834n:
      3521
    case 835n:
      3522
    case 836n:
      3524
    case 837n:
      3528
    case 838n:
      3536
    case 839n:
      3552
    case 840n:
      3591
    case 841n:
      3595
    case 842n:
      3597
    case 843n:
      3598
    case 844n:
      3603
    case 845n:
      3605
    case 846n:
      3606
    case 847n:
      3609
    case 848n:
      3610
    case 849n:
      3612
    case 850n:
      3619
    case 851n:
      3621
    case 852n:
      3622
    case 853n:
      3625
    case 854n:
      3626
    case 855n:
      3628
    case 856n:
      3633
    case 857n:
      3634
    case 858n:
      3636
    case 859n:
      3640
    case 860n:
      3651
    case 861n:
      3653
    case 862n:
      3654
    case 863n:
      3657
    case 864n:
      3658
    case 865n:
      3660
    case 866n:
      3665
    case 867n:
      3666
    case 868n:
      3668
    case 869n:
      3672
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
    case 25n:
      736n
    case 26n:
      737n
    case 28n:
      738n
    case 35n:
      739n
    case 37n:
      740n
    case 38n:
      741n
    case 41n:
      742n
    case 42n:
      743n
    case 44n:
      744n
    case 49n:
      745n
    case 50n:
      746n
    case 52n:
      747n
    case 56n:
      748n
    case _:
      0n

def stat.code.lo50(+lo: Nat) -> Nat:
  match lo:
    case 7n:
      749n
    case 11n:
      750n
    case 13n:
      751n
    case 14n:
      752n
    case 19n:
      753n
    case 21n:
      754n
    case 22n:
      755n
    case 25n:
      756n
    case 26n:
      757n
    case 28n:
      758n
    case 35n:
      759n
    case 37n:
      760n
    case 38n:
      761n
    case 41n:
      762n
    case 42n:
      763n
    case 44n:
      764n
    case 49n:
      765n
    case 50n:
      766n
    case 52n:
      767n
    case 56n:
      768n
    case _:
      0n

def stat.code.lo51(+lo: Nat) -> Nat:
  match lo:
    case 3n:
      769n
    case 5n:
      770n
    case 6n:
      771n
    case 9n:
      772n
    case 10n:
      773n
    case 12n:
      774n
    case 17n:
      775n
    case 18n:
      776n
    case 20n:
      777n
    case 24n:
      778n
    case 33n:
      779n
    case 34n:
      780n
    case 36n:
      781n
    case 40n:
      782n
    case 48n:
      783n
    case _:
      0n

def stat.code.lo52(+lo: Nat) -> Nat:
  match lo:
    case 7n:
      784n
    case 11n:
      785n
    case 13n:
      786n
    case 14n:
      787n
    case 19n:
      788n
    case 21n:
      789n
    case 22n:
      790n
    case 25n:
      791n
    case 26n:
      792n
    case 28n:
      793n
    case 35n:
      794n
    case 37n:
      795n
    case 38n:
      796n
    case 41n:
      797n
    case 42n:
      798n
    case 44n:
      799n
    case 49n:
      800n
    case 50n:
      801n
    case 52n:
      802n
    case 56n:
      803n
    case _:
      0n

def stat.code.lo53(+lo: Nat) -> Nat:
  match lo:
    case 3n:
      804n
    case 5n:
      805n
    case 6n:
      806n
    case 9n:
      807n
    case 10n:
      808n
    case 12n:
      809n
    case 17n:
      810n
    case 18n:
      811n
    case 20n:
      812n
    case 24n:
      813n
    case 33n:
      814n
    case 34n:
      815n
    case 36n:
      816n
    case 40n:
      817n
    case 48n:
      818n
    case _:
      0n

def stat.code.lo54(+lo: Nat) -> Nat:
  match lo:
    case 3n:
      819n
    case 5n:
      820n
    case 6n:
      821n
    case 9n:
      822n
    case 10n:
      823n
    case 12n:
      824n
    case 17n:
      825n
    case 18n:
      826n
    case 20n:
      827n
    case 24n:
      828n
    case 33n:
      829n
    case 34n:
      830n
    case 36n:
      831n
    case 40n:
      832n
    case 48n:
      833n
    case _:
      0n

def stat.code.lo55(+lo: Nat) -> Nat:
  match lo:
    case 1n:
      834n
    case 2n:
      835n
    case 4n:
      836n
    case 8n:
      837n
    case 16n:
      838n
    case 32n:
      839n
    case _:
      0n

def stat.code.lo56(+lo: Nat) -> Nat:
  match lo:
    case 7n:
      840n
    case 11n:
      841n
    case 13n:
      842n
    case 14n:
      843n
    case 19n:
      844n
    case 21n:
      845n
    case 22n:
      846n
    case 25n:
      847n
    case 26n:
      848n
    case 28n:
      849n
    case 35n:
      850n
    case 37n:
      851n
    case 38n:
      852n
    case 41n:
      853n
    case 42n:
      854n
    case 44n:
      855n
    case 49n:
      856n
    case 50n:
      857n
    case 52n:
      858n
    case 56n:
      859n
    case _:
      0n

def stat.code.lo57(+lo: Nat) -> Nat:
  match lo:
    case 3n:
      860n
    case 5n:
      861n
    case 6n:
      862n
    case 9n:
      863n
    case 10n:
      864n
    case 12n:
      865n
    case 17n:
      866n
    case 18n:
      867n
    case 20n:
      868n
    case 24n:
      869n
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
    case 50n:
      stat.code.lo50(lo)
    case 51n:
      stat.code.lo51(lo)
    case 52n:
      stat.code.lo52(lo)
    case 53n:
      stat.code.lo53(lo)
    case 54n:
      stat.code.lo54(lo)
    case 55n:
      stat.code.lo55(lo)
    case 56n:
      stat.code.lo56(lo)
    case 57n:
      stat.code.lo57(lo)
    case _:
      0n

# a word's code (0 for one no code has)
def stat.code.cw(+w: Nat) -> Nat:
  stat.code.hl(Nat.div(w, 64n), Nat.mod(w, 64n))

# the high twelve bits of the hash of a call of GET, SET, INCR and
# RESTORE that runs, as the parser writes them
def stat.mark.get() -> U32:
  191889408

def stat.mark.set() -> U32:
  199229440

def stat.mark.incr() -> U32:
  326107136

def stat.mark.restore() -> U32:
  2744123392
# END gen_commands: stats

# a container (CLIENT, FUNCTION, CONFIG, COMMAND, OBJECT, MEMORY, PUBSUB,
# SLOWLOG, LATENCY, ACL, XINFO)
# by its first argument; alone, the container itself (top)
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
    case 174n:
      stat.sub.pubsub(pubsub_id(up, String.length(up)))
    case 201n:
      stat.sub.slowlog(slowlog_id(up, String.length(up)))
    case 202n:
      stat.sub.latency(latency_id(up, String.length(up)))
    case 210n:
      stat.sub.acl(acl_id(up, String.length(up)))
    case 215n:
      stat.sub.xinfo(xinfo_id(up, String.length(up)))
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
    case 174n:
      stat.key.args(stat.top(174n), 174n, args)
    case 201n:
      stat.key.args(stat.top(201n), 201n, args)
    case 202n:
      stat.key.args(stat.top(202n), 202n, args)
    case 210n:
      stat.key.args(stat.top(210n), 210n, args)
    case 215n:
      stat.key.args(stat.top(215n), 215n, args)
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
  Nat.add(Nat.mul(key, 3n), class)

# a code's key and class, and the code of a call of its key that is
# refused (class 1)
def code.key(+k: Nat) -> Nat:
  Nat.div(k, 3n)

def code.class(+k: Nat) -> Nat:
  Nat.mod(k, 3n)

def code.refused(+k: Nat) -> Nat:
  Nat.add(Nat.mul(Nat.div(k, 3n), 3n), 1n)

# a command whose error is a failed call (class 2), as the server runs
# it: SFail, which only a client that may run commands is answered, as
# Redis's command finds the error only as it runs, after processCommand
# asked for AUTH; an error refused before it runs (class 1) stays Bad or
# SBad, answered whoever the client is
def fail.own(o: SessOp) -> SessOp:
  match o:
    case SBad{r}:
      SFail{r}
    case _:
      o

def fail.of(c: Cmd) -> Cmd:
  match c:
    case Bad{r}:
      Own{SFail{r}}
    case Own{o}:
      Own{fail.own(o)}
    case _:
      c

def fail.if(+class: Nat, c: Cmd) -> Cmd:
  match class:
    case 2n:
      fail.of(c)
    case _:
      c

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
  Bool.pick(Nat, Nat.is_eq(code.class(k), 1n), 0n, n)

# whether replies of calls of code k need a look for errors: calls
# refused or failed by the parser, or calls that can fail as they run
# (stat.risky: INCR, DECR, INCRBY and DECRBY meet values that are not
# integers, and overflows)
def code.risky(+k: Nat) -> Bool:
  Bool.or(Nat.is_lt(0n, code.class(k)), stat.risky(code.key(k)))

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
  +c = U32.from_nat(code.class(k))
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

# the error replies among the replies of a batch of calls of one code k
def errs.one(+rs: List<&2, Reply>, +k: Nat, acc: List<&2, Erred>) -> List<&2, Erred>:
  match rs:
    case Con{+r, +rest}:
      errs.one(rest, k, err.put(r, k, acc))
    case Nil{}:
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

# INCRBY: the stored value must read as a long long, and the sum must be
# one (s: none when it is not). A key there at now keeps its time (keep);
# a new one, or one whose time has passed, gets none: m and y are the
# counts once the sum is stored, n and x before.
def incr.put(keep: Bool, t: KV.Trie<KV.Val>, +k: String, v: String, +h: U32) -> KV.Trie<KV.Val>:
  match keep:
    case True{}:
      KV.keep.at(KV.Val, t, k, KV.VStr{v}, h)
    case False{}:
      KV.set.at(KV.Val, t, k, KV.VStr{v}, h)

def incr.fit(t: KV.Trie<KV.Val>, +k: String, +h: U32, s: LL, keep: Bool, m: Nat, n: Nat, y: Nat, x: Nat, now: Nat, rr: Maybe<&2, Db>) -> Reply & Db:
  match s:
    case LL{+neg, +hi, +lo}:
      +v = ll.show(neg, hi, lo)
      (RIntS{v}, Db{incr.put(keep, t, k, v, h), m, y, now, rr})
    case LLBad{}:
      (RError{"ERR increment or decrement would overflow"}, Db{t, n, x, now, rr})

# the long long a key there holds, or none
def incr.num(t: KV.Trie<KV.Val>, +k: String, +h: U32, by: By, +n: Nat, +x: Nat, now: Nat, rr: Maybe<&2, Db>, cur: LL) -> Reply & Db:
  match cur:
    case LL{+neg, +hi, +lo}:
      incr.fit(t, k, h, ll.add(neg, hi, lo, by), True{}, n, n, x, x, now, rr)
    case LLBad{}:
      (e_int(), Db{t, n, x, now, rr})

# a key that is not there reads as 0: the sum is by; c is its code
def incr.new(t: KV.Trie<KV.Val>, +k: String, +h: U32, by: By, +n: Nat, +x: Nat, now: Nat, rr: Maybe<&2, Db>, +c: Nat) -> Reply & Db:
  incr.fit(t, k, h, by.ll(by), False{}, cnt.n(c, n), n, cnt.x(c, 0n, x), x, now, rr)

# the value of INCRBY's key there at now (old), or none; a value of
# another kind is WRONGTYPE
def incr.got(t: KV.Trie<KV.Val>, +k: String, +h: U32, by: By, +n: Nat, +x: Nat, now: Nat, rr: Maybe<&2, Db>, old: KV.Got) -> Reply & Db:
  match old:
    case KV.GStr{s}:
      incr.num(t, k, h, by, n, x, now, rr, ll.read(s))
    case KV.GColl{}:
      (e_wrongtype(), Db{t, n, x, now, rr})
    case KV.GNone{}:
      +u = t
      incr.new(u, k, h, by, n, x, now, rr, KV.code.at(KV.Val, u, k, h))

def db.incr(db: Db, +k: String, by: By) -> Reply & Db:
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

# k's value in a database it lends, when the key is there at now. A read
# of the trie that db.trie answers would give KV.read a value made for
# the call, and the compiler would make KV.read own its trie for every
# caller: a copy of each node on the key's path
def db.read(+d: Db, +k: String) -> Maybe<&2, KV.Val>:
  match d:
    case Db{+t, n, x, +now, rr}:
      KV.read(KV.Val, t, k, now)

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
    case KV.HSmall{+m, +b}:
      hscan.rep(0n, KV.hb.pairs(m, b, 0n), pat)
    case KV.HLong{m, +ps}:
      hscan.rep(0n, KV.hl.pairs(ps), pat)
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
      RMap{hp.flat(KV.hash.pairs(h))}
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
      RMap{Nil{}}
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
    case KV.CStream{+x}:
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
    case KV.CStream{+x}:
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
      sscan.rep(0n, KV.ints.list(xs), pat)
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
      RSet{lbulks(KV.mems.all(s))}
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
      RSet{Nil{}}
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
    case KV.CStream{+x}:
      e_wrongtype()

# A sorted set's reads. A key not there reads as an empty sorted set, as
# in Redis (ZCARD 0, nils for scores and ranks, no elements in a range,
# an empty scan with cursor 0); a key that holds another kind answers
# WRONGTYPE. A score is answered as Redis writes a double (%.17g; inf,
# -inf: F.f64.show), a double of RESP3 (RDbl).

def zscore.reply(m: Maybe<&2, F.F64>) -> Reply:
  match m:
    case Some{+d}:
      RDbl{F.f64.show(d)}
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
def zrank.of(m: Maybe<&2, Nat>, +rev: Bool, +z: KV.Zset) -> Reply:
  match m:
    case Some{+r}:
      r_int(Bool.pick(Nat, rev, Nat.sub(Nat.sub(KV.zset.len(z), r), 1n), r))
    case None{}:
      RNull{}

def zel.m(e: KV.ZEl) -> String:
  match e:
    case KV.ZEl{m, d}:
      m

# a range's elements as Redis answers them: each member, or under
# WITHSCORES each member and its score as a pair (a flat array in RESP2,
# an array of pairs in RESP3: Redis's zrangeResultEmitCStringForClient)
def zels.one(ws: Bool, m: String, +d: F.F64, rest: List<&2, Reply>) -> List<&2, Reply>:
  match ws:
    case True{}:
      RPair{[RBulk{m}, RDbl{F.f64.show(d)}]} <> rest
    case False{}:
      RBulk{m} <> rest

def zels(xs: List<&2, KV.ZEl>, +ws: Bool) -> List<&2, Reply>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{KV.ZEl{m, +d}, rest}:
      zels.one(ws, m, d, zels(rest, ws))

def zels.wrap(ws: Bool, xs: List<&2, Reply>) -> Reply:
  match ws:
    case True{}:
      RPairs{xs}
    case False{}:
      RArray{xs}

def zels.reply(xs: List<&2, KV.ZEl>, +ws: Bool) -> Reply:
  zels.wrap(ws, zels(xs, ws))

# each member and its score, flat in both protocols (ZPOPMIN without a
# count)
def zels.flat(xs: List<&2, KV.ZEl>) -> List<&2, Reply>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{KV.ZEl{m, +d}, rest}:
      RBulk{m} <> (RDbl{F.f64.show(d)} <> zels.flat(rest))

# How a range's elements are found. By rank, as LRANGE reads its range
# (lspan); from the last element when reversed. By score (in order, so a
# walk finds where a bound falls, KV.zset.before): the ranks
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
def zlex.in(+z: KV.Zset, +lo: KV.ZLB, +hi: KV.ZLB) -> Bool:
  +n = KV.zset.len(z)
  Bool.and(Bool.not(zlb.empty(lo, hi)), Bool.and(Nat.is_lt(0n, n), Bool.and(zel.ok(KV.zset.nth(z, Nat.sub(n, 1n)), KV.ZGeL{lo}), zel.ok(KV.zset.nth(z, 0n), KV.ZLeL{hi}))))

def zlex.take(ok: Bool, +s: List<&2, KV.ZEl>, +o: Nat, +p: KV.ZP, +c: Nat) -> List<&2, KV.ZEl>:
  match ok:
    case True{}:
      zl.take(zl.drop(s, o), p, c)
    case False{}:
      Nil{}

def zlex.small.in(ok: Bool, rev: Bool, +z: KV.Zset, +lo: KV.ZLB, +hi: KV.ZLB, +o: Nat, +c: Nat) -> List<&2, KV.ZEl>:
  match ok rev:
    case False{} _:
      Nil{}
    case True{} False{}:
      +s = zl.from(KV.zset.all(z), KV.ZGeL{lo})
      zlex.take(zl.ok(s, KV.ZLeL{hi}), s, o, KV.ZLeL{hi}, c)
    case True{} True{}:
      +s = zl.from(KV.zset.slice(True{}, z, 0n, KV.zset.len(z)), KV.ZLeL{hi})
      zlex.take(zl.ok(s, KV.ZGeL{lo}), s, o, KV.ZGeL{lo}, c)

def zlex.small(off: Int, +rev: Bool, +z: KV.Zset, +lo: KV.ZLB, +hi: KV.ZLB, +c: Nat) -> List<&2, KV.ZEl>:
  match off:
    case INeg{x}:
      Nil{}
    case IPos{+o}:
      zlex.small.in(zlex.in(z, lo, hi), rev, z, lo, hi, o, c)

def zlex.of(small: Bool, +lo: KV.ZLB, +hi: KV.ZLB, +rev: Bool, +off: Int, +cnt: Int, +z: KV.Zset) -> List<&2, KV.ZEl>:
  match small:
    case True{}:
      zlex.small(off, rev, z, lo, hi, zcnt(cnt, KV.zset.len(z)))
    case False{}:
      +n = KV.zset.len(z)
      zwin.slice(zwin(off, rev, KV.zset.before(z, KV.ZGeL{lo}), KV.zset.before(z, KV.ZGtL{hi}), zcnt(cnt, n), n), rev, z)

# a range's elements, in the order Redis answers them
def zrange.of(r: ZRng, +rev: Bool, +off: Int, +cnt: Int, +z: KV.Zset) -> List<&2, KV.ZEl>:
  match r:
    case ZRankR{+a, +b}:
      zrank.range(lspan(a, b, KV.zset.len(z)), rev, z)
    case ZScoreR{+lo, +hi}:
      +n = KV.zset.len(z)
      zwin.slice(zwin(off, rev, KV.zset.before(z, KV.ZGeS{lo}), KV.zset.before(z, KV.ZGtS{hi}), zcnt(cnt, n), n), rev, z)
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
  zels.reply(zq.run(q, z), zq.scores(q))

# ZCOUNT: the elements between the ranks of its bounds; ZLEXCOUNT: of a
# small sorted set, those its range by member holds (as above), of a
# large one, those between the ranks of its bounds
def zcount(+lo: KV.ZSB, +hi: KV.ZSB, +z: KV.Zset) -> Nat:
  Nat.sub(KV.zset.before(z, KV.ZGtS{hi}), KV.zset.before(z, KV.ZGeS{lo}))

def zlexcount.of(small: Bool, +lo: KV.ZLB, +hi: KV.ZLB, +z: KV.Zset) -> Nat:
  match small:
    case True{}:
      List.length(&2, KV.ZEl, zlex.small(IPos{0n}, False{}, z, lo, hi, KV.zset.len(z)))
    case False{}:
      Nat.sub(KV.zset.before(z, KV.ZGtL{hi}), KV.zset.before(z, KV.ZGeL{lo}))

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
    case KV.ZSmall{+k, +b}:
      hscan.rep(0n, zscan.lp(KV.zb.all(k, b)), pat)
    case KV.ZWide{+tr}:
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
      zrank.of(KV.zset.rank(m, z), False{}, z)
    case ZRRevRank{+m}:
      zrank.of(KV.zset.rank(m, z), True{}, z)
    case ZRCount{args}:
      zcount.args(2n, args, z)
    case ZRLexCount{args}:
      zcount.args(3n, args, z)
    case ZRRange{q}:
      zq.reply(q, z)
    case ZRScan{args}:
      zscan.of(hscan.args(args), z)
    case ZRGeoPos{ms}:
      RArray{geo.poss(ms, z)}
    case ZRGeoHash{ms}:
      RArray{geo.hashes(ms, z)}
    case ZRGeoDist{args}:
      geo.dist(args, z)
    case ZRGeoFind{args}:
      geo.find(args, Some{z})

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
    case ZRGeoPos{ms}:
      RArray{geo.nulls(ms, RNullA{})}
    case ZRGeoHash{ms}:
      RArray{geo.nulls(ms, RNull{})}
    case ZRGeoDist{args}:
      RNull{}
    case ZRGeoFind{args}:
      geo.find(args, None{})

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

# DUMP's reply: the payload of the key's value (rdb.bend), or a null
# when the key is not there
def dump.of(m: Maybe<&2, KV.Item<String>>) -> Reply:
  match m:
    case Some{KV.Item{w, e}}:
      RBulk{D.dump(KV.VStr{w})}
    case None{}:
      RNull{}

# Reads of a stream
# -----------------
# The replies of PStream, from the stream stream.bend reads (Streams,
# above, for what each reads before the key): its entries, each its ID
# and its fields and values; XREAD's keys and their entries (RKMap); a
# count Redis keeps as a long long as one (X.xn.show.ll)

def xv.bulks(xs: List<&2, String>) -> List<&2, Reply>:
  match xs:
    case Con{x, rest}:
      RBulk{x} <> xv.bulks(rest)
    case Nil{}:
      Nil{}

def xv.entry(e: X.XE) -> Reply:
  match e:
    case X.XE{+id, fv}:
      RArray{[RBulk{X.xid.show(id)}, RArray{xv.bulks(fv)}]}

def xv.entries(es: List<&2, X.XE>) -> List<&2, Reply>:
  match es:
    case Con{e, rest}:
      xv.entry(e) <> xv.entries(rest)
    case Nil{}:
      Nil{}

def xv.id(+id: KV.XId) -> Reply:
  RBulk{X.xid.show(id)}

def xv.ll(+n: KV.XN) -> Reply:
  RIntS{X.xn.show.ll(n)}

# XRANGE's entries, or a null for COUNT 0
def xv.range.of(+c: Nat, +x: KV.XStream, +lo: KV.XId, +hi: KV.XId, +rev: Bool) -> Reply:
  match c:
    case 0n:
      RNullA{}
    case _:
      RArray{xv.entries(X.xs.range(x, lo, hi, c, rev))}

def xv.range(+x: KV.XStream, q: XQ) -> Reply:
  match q:
    case XQ{+lo, +hi, +c}:
      xv.range.of(c, x, lo, hi, False{})
    case XQRev{XQ{+lo, +hi, +c}}:
      xv.range.of(c, x, lo, hi, True{})
    case XQRev{r}:
      RArray{Nil{}}

# XREAD's ID of a key: "$" its last ID (0-0 for a key not there), ">"
# an error, another a strict ID (missing sequence 0); each compared as a
# C string, up to its first NUL
type XRid is Data:
  XRid{id: KV.XId}
  XRidBad{r: Reply}

def xv.rid.of(m: Maybe<&2, KV.XId>) -> XRid:
  match m:
    case Some{id}:
      XRid{id}
    case None{}:
      XRidBad{e_xid()}

def xv.rid(+s: String, +last: KV.XId) -> XRid:
  +c = cstr(s)
  Bool.pick(XRid, String.eq(c, "$"), XRid{last}, Bool.pick(XRid, String.eq(c, ">"), XRidBad{RError{"ERR The > ID can be specified only when calling XREADGROUP using the GROUP <group> <consumer> option."}}, xv.rid.of(X.xid.parse(s, True{}, X.xn.zero()))))

# a key XREAD reads: a stream and the ID its entries must be past, a key
# not there, or the error that ends the read
type XRk is Data:
  XRkS{key: String, x: KV.XStream, id: KV.XId}
  XRkNone{}
  XRkBad{r: Reply}

def xv.rk.of(r: XRid, +k: String, +x: KV.XStream) -> XRk:
  match r:
    case XRid{id}:
      XRkS{k, x, id}
    case XRidBad{e}:
      XRkBad{e}

def xv.rk.none(r: XRid) -> XRk:
  match r:
    case XRid{id}:
      XRkNone{}
    case XRidBad{e}:
      XRkBad{e}

# key k's entry m, with its ID s: WRONGTYPE for a key of another kind
def xv.rk(m: Maybe<&2, KV.Item<KV.Val>>, +k: String, +s: String) -> XRk:
  match m:
    case Some{KV.Item{KV.VColl{KV.CStream{+x}}, e}}:
      xv.rk.of(xv.rid(s, X.xstream.last(x)), k, x)
    case Some{_}:
      XRkBad{e_wrongtype()}
    case None{}:
      xv.rk.none(xv.rid(s, X.xid.zero()))

# the ID after id; past the last one, 0-0 (as streamIncrID leaves it)
def xv.after.of(m: Maybe<&2, KV.XId>) -> KV.XId:
  match m:
    case Some{+id}:
      id
    case None{}:
      X.xid.zero()

def xv.after(+id: KV.XId) -> KV.XId:
  xv.after.of(X.xid.incr(id))

def xv.serve.if(go: Bool, +k: String, +x: KV.XStream, +id: KV.XId, +c: Nat) -> Maybe<&2, Reply>:
  match go:
    case True{}:
      Some{RKPair{[RBulk{k}, RArray{xv.entries(X.xs.range(x, xv.after(id), X.xid.max(), c, False{}))}]}}
    case False{}:
      None{}

# a key served: its entries past id, when the last live one is past it
def xv.serve.of(m: Maybe<&2, KV.XId>, +k: String, +x: KV.XStream, +id: KV.XId, +c: Nat) -> Maybe<&2, Reply>:
  match m:
    case Some{+top}:
      xv.serve.if(Cmp.is_gt(KV.xid.cmp(top, id)), k, x, id, c)
    case None{}:
      None{}

def xv.serve(r: XRk, +c: Nat) -> Maybe<&2, Reply>:
  match r:
    case XRkS{+k, +x, +id}:
      xv.serve.of(X.xs.top(x), k, x, id, c)
    case _:
      None{}

# XREAD's reply: the keys served, or none, a null array (with BLOCK, as
# Redis answers a client that may not wait; the server answers that
# BendKV blocks on no stream yet)
def xv.read.reply(ps: List<&2, Reply>) -> Reply:
  match ps:
    case Nil{}:
      RNullA{}
    case xs:
      RKMap{xs}

def xv.maybe(m: Maybe<&2, Reply>) -> List<&2, Reply>:
  match m:
    case Some{r}:
      [r]
    case None{}:
      Nil{}

def xv.read.one(r: XRk, +c: Nat) -> Reply:
  match r:
    case XRkBad{e}:
      e
    case other:
      xv.read.reply(xv.maybe(xv.serve(other, c)))

# XREAD of one key, its entry m
def xv.read(q: XRq, m: Maybe<&2, KV.Item<KV.Val>>) -> Reply:
  match q:
    case XRq{+k, +s, +c}:
      xv.read.one(xv.rk(m, k, s), c)
    case XRqOf{y}:
      xv.read(y, m)

# XREAD of several keys in the database d: each key, then its ID, in
# turn, the first error ending the read before any is served; then each
# key served in turn
type XRks is Data:
  XRksOk{rs: List<&2, XRk>}
  XRksBad{r: Reply}

def xv.rks.add(r: XRk, rest: XRks) -> XRks:
  match r rest:
    case XRkBad{e} _:
      XRksBad{e}
    case _ XRksBad{e}:
      XRksBad{e}
    case x XRksOk{rs}:
      XRksOk{x <> rs}

def xv.rks(ks: List<&2, String>, ids: List<&2, String>, +d: Db) -> XRks:
  match ks ids:
    case Con{+k, krest} Con{+s, irest}:
      xv.rks.add(xv.rk(db.ent(d, k), k, s), xv.rks(krest, irest, d))
    case _ _:
      XRksOk{Nil{}}

def xv.serves(rs: List<&2, XRk>, +c: Nat) -> List<&2, Reply>:
  match rs:
    case Con{r, rest}:
      List.append(&2, Reply, xv.maybe(xv.serve(r, c)), xv.serves(rest, c))
    case Nil{}:
      Nil{}

def xv.read.all(r: XRks, +c: Nat) -> Reply:
  match r:
    case XRksOk{rs}:
      xv.read.reply(xv.serves(rs, c))
    case XRksBad{e}:
      e

# the keys and their IDs of XREAD's words ws (keys, then as many IDs), in
# the database d
def xv.rks.of(+ws: List<&2, String>, +d: Db) -> XRks:
  +n = Nat.div(List.length(&2, String, ws), 2n)
  xv.rks(List.take(&2, String, ws, n), List.drop(&2, String, ws, n), d)

def xread.many(q: XRm, +d: Db) -> Reply:
  match q:
    case XRm{+c, b, ws}:
      xv.read.all(xv.rks.of(ws, d), c)
    case XRmOf{y}:
      xread.many(y, d)

# whether no key of rs is served (its last live entry past its ID)
def xv.unserved.of(m: Maybe<&2, KV.XId>, +id: KV.XId) -> Bool:
  match m:
    case Some{+top}:
      Bool.not(Cmp.is_gt(KV.xid.cmp(top, id)))
    case None{}:
      True{}

def xv.unserved(rs: List<&2, XRk>) -> Bool:
  match rs:
    case Con{XRkS{k, x, +id}, rest}:
      Bool.and(xv.unserved.of(X.xs.top(x), id), xv.unserved(rest))
    case Con{r, rest}:
      xv.unserved(rest)
    case Nil{}:
      True{}

def xv.waits(r: XRks) -> Bool:
  match r:
    case XRksOk{rs}:
      xv.unserved(rs)
    case XRksBad{e}:
      False{}

# whether XREAD q would wait on the database d: BLOCK came, and it
# answers no error and serves no key (the server answers it then, as
# BendKV blocks on no stream yet)
def xread.waits(q: XRm, +d: Db) -> Bool:
  match q:
    case XRm{c, True{}, ws}:
      xv.waits(xv.rks.of(ws, d))
    case XRm{c, False{}, ws}:
      False{}
    case XRmOf{y}:
      xread.waits(y, d)

# a group's count of entries read: none as a null
def xv.read.cnt(r: KV.XRd) -> Reply:
  match r:
    case KV.XRdN{+n}:
      xv.ll(n)
    case KV.XRdNone{}:
      RNull{}

def xv.lag(m: Maybe<&2, KV.XN>) -> Reply:
  match m:
    case Some{+n}:
      xv.ll(n)
    case None{}:
      RNull{}

def xv.first(es: List<&2, X.XE>) -> Reply:
  match es:
    case Con{e, rest}:
      xv.entry(e)
    case Nil{}:
      RNull{}

# XINFO STREAM's fields that both forms answer
def xv.info.head(+x: KV.XStream) -> List<&2, Reply>:
  [RBulk{"length"}, r_int(KV.xstream.len(x)), RBulk{"radix-tree-keys"}, r_int(KV.xns.size(X.xstream.nodes(x))), RBulk{"radix-tree-nodes"}, r_int(X.xs.rax(x)), RBulk{"last-generated-id"}, xv.id(X.xstream.last(x)), RBulk{"max-deleted-entry-id"}, xv.id(X.xstream.maxdel(x)), RBulk{"entries-added"}, xv.ll(X.xstream.added(x)), RBulk{"recorded-first-entry-id"}, xv.id(X.xstream.first(x))]

def xv.info.plain(+x: KV.XStream) -> Reply:
  RMap{List.append(&2, Reply, xv.info.head(x), [RBulk{"groups"}, r_int(KV.xgs.size(X.xstream.groups(x))), RBulk{"first-entry"}, xv.first(X.xs.range(x, X.xid.zero(), X.xid.max(), 1n, False{})), RBulk{"last-entry"}, xv.first(X.xs.range(x, X.xid.zero(), X.xid.max(), 1n, True{}))])}

# XINFO STREAM FULL's pending entries of a group, and of a consumer
def xv.nack.full(+n: KV.XNack) -> Reply:
  RArray{[xv.id(KV.xnack.id(n)), RBulk{X.xnack.owner(n)}, r_int(X.xnack.time(n)), xv.ll(X.xnack.count(n))]}

def xv.nacks.full(ns: List<&2, KV.XNack>) -> List<&2, Reply>:
  match ns:
    case Con{n, rest}:
      xv.nack.full(n) <> xv.nacks.full(rest)
    case Nil{}:
      Nil{}

def xv.cnack.full(+n: KV.XNack) -> Reply:
  RArray{[xv.id(KV.xnack.id(n)), r_int(X.xnack.time(n)), xv.ll(X.xnack.count(n))]}

def xv.cnacks.full(ns: List<&2, KV.XNack>) -> List<&2, Reply>:
  match ns:
    case Con{n, rest}:
      xv.cnack.full(n) <> xv.cnacks.full(rest)
    case Nil{}:
      Nil{}

def xv.con.full(+c: KV.XCon, +pel: KV.XPel, +n: Nat) -> Reply:
  +ids = X.xcon.ids(c)
  RMap{[RBulk{"name"}, RBulk{KV.xcon.name(c)}, RBulk{"seen-time"}, r_int(X.xcon.seen(c)), RBulk{"pel-count"}, r_int(KV.xis.size(ids)), RBulk{"pending"}, RArray{xv.cnacks.full(X.xs.pending(pel, Some{ids}, X.xid.zero(), X.xid.max(), n, X.XINone{}, 0n))}]}

def xv.cons.full(cs: List<&2, KV.XCon>, +pel: KV.XPel, +n: Nat) -> List<&2, Reply>:
  match cs:
    case Con{+c, rest}:
      xv.con.full(c, pel, n) <> xv.cons.full(rest, pel, n)
    case Nil{}:
      Nil{}

def xv.group.full(+x: KV.XStream, +g: KV.XGroup, +n: Nat) -> Reply:
  +pel = X.xgroup.pel(g)
  RMap{[RBulk{"name"}, RBulk{KV.xgroup.name(g)}, RBulk{"last-delivered-id"}, xv.id(X.xgroup.last(g)), RBulk{"entries-read"}, xv.read.cnt(X.xgroup.read(g)), RBulk{"lag"}, xv.lag(X.xs.lag(x, g)), RBulk{"pel-count"}, r_int(KV.xpl.size(pel)), RBulk{"pending"}, RArray{xv.nacks.full(X.xs.pending(pel, None{}, X.xid.zero(), X.xid.max(), n, X.XINone{}, 0n))}, RBulk{"consumers"}, RArray{xv.cons.full(KV.xcs.list(X.xgroup.cons(g), Nil{}), pel, n)}]}

def xv.groups.full(gs: List<&2, KV.XGroup>, +x: KV.XStream, +n: Nat) -> List<&2, Reply>:
  match gs:
    case Con{+g, rest}:
      xv.group.full(x, g, n) <> xv.groups.full(rest, x, n)
    case Nil{}:
      Nil{}

# FULL with COUNT n (0 for all): the entries, then the groups
def xv.info.full(+x: KV.XStream, +n: Nat) -> Reply:
  RMap{List.append(&2, Reply, xv.info.head(x), [RBulk{"entries"}, RArray{xv.entries(X.xs.range(x, X.xid.zero(), X.xid.max(), n, False{}))}, RBulk{"groups"}, RArray{xv.groups.full(KV.xgs.list(X.xstream.groups(x), Nil{}), x, n)}])}

# FULL's COUNT: a long long, below 0 as 10, 0 for all
def xv.full.count(m: Maybe<&2, LL>, +x: KV.XStream) -> Reply:
  match m:
    case Some{LL{True{}, hi, lo}}:
      xv.info.full(x, 10n)
    case Some{LL{False{}, +hi, +lo}}:
      xv.info.full(x, xc.read(xc.of.big(Nat.is_le(140737n, hi), hi, lo)))
    case Some{LLBad{}}:
      e_int()
    case None{}:
      xv.info.full(x, 10n)

def xv.ll.of(l: LL) -> Maybe<&2, LL>:
  Some{l}

# FULL's reply when its words are right (ok), else the subcommand's
# syntax error; a match, so that a wrong word reads no entry
def xv.info.full.if(ok: Bool, m: Maybe<&2, LL>, +sub: String, +x: KV.XStream) -> Reply:
  match ok:
    case True{}:
      xv.full.count(m, x)
    case False{}:
      e_sub_syntax(sub, "XINFO")

# XINFO STREAM's options (xinfoReplyWithStreamInfo): none, FULL, or FULL
# COUNT count; any other shape the subcommand's syntax error
def xv.info.stream(+sub: String, args: List<&2, String>, +x: KV.XStream) -> Reply:
  match args:
    case Nil{}:
      xv.info.plain(x)
    case Con{+f, Nil{}}:
      xv.info.full.if(is_word(f, "FULL"), None{}, sub, x)
    case Con{+f, Con{+w, Con{+n, Nil{}}}}:
      xv.info.full.if(Bool.and(is_word(f, "FULL"), is_word(w, "COUNT")), xv.ll.of(ll.read(n)), sub, x)
    case _:
      e_sub_syntax(sub, "XINFO")

# XINFO GROUPS
def xv.group.info(+x: KV.XStream, +g: KV.XGroup) -> Reply:
  RMap{[RBulk{"name"}, RBulk{KV.xgroup.name(g)}, RBulk{"consumers"}, r_int(KV.xcs.size(X.xgroup.cons(g))), RBulk{"pending"}, r_int(KV.xpl.size(X.xgroup.pel(g))), RBulk{"last-delivered-id"}, xv.id(X.xgroup.last(g)), RBulk{"entries-read"}, xv.read.cnt(X.xgroup.read(g)), RBulk{"lag"}, xv.lag(X.xs.lag(x, g))]}

def xv.groups.info(gs: List<&2, KV.XGroup>, +x: KV.XStream) -> List<&2, Reply>:
  match gs:
    case Con{+g, rest}:
      xv.group.info(x, g) <> xv.groups.info(rest, x)
    case Nil{}:
      Nil{}

# XINFO CONSUMERS: each consumer's idle time, now less its seen time (0
# for one past now)
def xv.con.info(+c: KV.XCon, +now: Nat) -> Reply:
  RMap{[RBulk{"name"}, RBulk{KV.xcon.name(c)}, RBulk{"pending"}, r_int(KV.xis.size(X.xcon.ids(c))), RBulk{"idle"}, r_int(Nat.sub(now, X.xcon.seen(c)))]}

def xv.cons.info(cs: List<&2, KV.XCon>, +now: Nat) -> List<&2, Reply>:
  match cs:
    case Con{+c, rest}:
      xv.con.info(c, now) <> xv.cons.info(rest, now)
    case Nil{}:
      Nil{}

def xv.info.cons(m: Maybe<&2, KV.XGroup>, +k: String, +g: String, +now: Nat) -> Reply:
  match m:
    case Some{+gr}:
      RArray{xv.cons.info(KV.xcs.list(X.xgroup.cons(gr), Nil{}), now)}
    case None{}:
      RError{e_fmt("NOGROUP No such consumer group '" ++ cstr(g) ++ "' for key name '" ++ cstr(k) ++ "'")}

def xv.info(i: XInf, +now: Nat, +x: KV.XStream) -> Reply:
  match i:
    case XIStream{+sub, args}:
      xv.info.stream(sub, args, x)
    case XIGroups{}:
      RArray{xv.groups.info(KV.xgs.list(X.xstream.groups(x), Nil{}), x)}
    case XICons{+k, +g}:
      xv.info.cons(X.xs.group(x, g), k, g, now)
    case XIOf{y}:
      xv.info(y, now, x)

# XPENDING
def e_xnogroup(+k: String, +g: String) -> Reply:
  RError{e_fmt("NOGROUP No such key '" ++ cstr(k) ++ "' or consumer group '" ++ cstr(g) ++ "'")}

def xv.pend.con(c: KV.XCon) -> Reply:
  match c:
    case KV.XCon{+name, seen, +ids}:
      RArray{[RBulk{name}, RBulk{Nat.show(KV.xis.size(ids))}]}

def xv.pend.cons(cs: List<&2, KV.XCon>) -> List<&2, Reply>:
  match cs:
    case Con{c, rest}:
      xv.pend.con(c) <> xv.pend.cons(rest)
    case Nil{}:
      Nil{}

def xv.pend.edge(m: Maybe<&2, KV.XId>) -> Reply:
  match m:
    case Some{+id}:
      xv.id(id)
    case None{}:
      RNull{}

# the summary: the count of pending entries, the first and last IDs, and
# each consumer with pending entries and its count, as a bulk
def xv.pend.sum(+g: KV.XGroup) -> Reply:
  +pel = X.xgroup.pel(g)
  +n = KV.xpl.size(pel)
  Bool.pick(Reply, Nat.is_eq(n, 0n), RArray{[r_int(0n), RNull{}, RNull{}, RNullA{}]}, RArray{[r_int(n), xv.pend.edge(X.xpl.first(pel, None{})), xv.pend.edge(X.xpl.last(pel, None{})), RArray{xv.pend.cons(X.xcs.pending(KV.xcs.list(X.xgroup.cons(g), Nil{}), Nil{}))}]})

# an entry: its ID, its owner, its idle time (now less its time, 0 past
# now) and its count of deliveries
def xv.pend.one(+n: KV.XNack, +now: Nat) -> Reply:
  RArray{[xv.id(KV.xnack.id(n)), RBulk{X.xnack.owner(n)}, r_int(Nat.sub(now, X.xnack.time(n))), xv.ll(X.xnack.count(n))]}

def xv.pend.all(ns: List<&2, KV.XNack>, +now: Nat) -> List<&2, Reply>:
  match ns:
    case Con{n, rest}:
      xv.pend.one(n, now) <> xv.pend.all(rest, now)
    case Nil{}:
      Nil{}

# the entries of the group, or of a consumer of it; none of a consumer
# not there
def xv.pend.ids(m: Maybe<&2, KV.XCon>) -> Maybe<&2, Maybe<&2, KV.XIds>>:
  match m:
    case Some{+c}:
      Some{Some{X.xcon.ids(c)}}
    case None{}:
      None{}

def xv.pend.of(m: Maybe<&2, Maybe<&2, KV.XIds>>, +g: KV.XGroup, +idle: X.XIdle, +lo: KV.XId, +hi: KV.XId, +c: Nat, +now: Nat) -> Reply:
  match m:
    case Some{ids}:
      RArray{xv.pend.all(X.xs.pending(X.xgroup.pel(g), ids, lo, hi, c, idle, now), now)}
    case None{}:
      RArray{Nil{}}

def xv.pend.con.of(m: Maybe<&2, String>, +g: KV.XGroup) -> Maybe<&2, Maybe<&2, KV.XIds>>:
  match m:
    case Some{+name}:
      xv.pend.ids(X.xgroup.con(g, name))
    case None{}:
      Some{None{}}

def xv.pend.ext(+g: KV.XGroup, +idle: X.XIdle, +lo: KV.XId, +hi: KV.XId, +c: Nat, con: Maybe<&2, String>, +now: Nat) -> Reply:
  xv.pend.of(xv.pend.con.of(con, g), g, idle, lo, hi, c, now)

def xv.pend.group(m: Maybe<&2, KV.XGroup>, q: XPq, +now: Nat) -> Reply:
  match m q:
    case Some{+g} XPSum{k, gn}:
      xv.pend.sum(g)
    case Some{+g} XPExt{k, gn, +idle, +lo, +hi, +c, con}:
      xv.pend.ext(g, idle, lo, hi, c, con, now)
    case None{} XPSum{+k, +gn}:
      e_xnogroup(k, gn)
    case None{} XPExt{+k, +gn, idle, lo, hi, c, con}:
      e_xnogroup(k, gn)
    case _ _:
      RArray{Nil{}}

def xv.pend(q: XPq, +now: Nat, +x: KV.XStream) -> Reply:
  match q:
    case XPSum{+k, +g}:
      xv.pend.group(X.xs.group(x, g), XPSum{k, g}, now)
    case XPExt{+k, +g, idle, lo, hi, c, con}:
      xv.pend.group(X.xs.group(x, g), XPExt{k, g, idle, lo, hi, c, con}, now)
    case XPqOf{y}:
      xv.pend(y, now, x)

# a key not there: XPENDING's group is not there either
def xv.pend.none(q: XPq) -> Reply:
  match q:
    case XPSum{+k, +g}:
      e_xnogroup(k, g)
    case XPExt{+k, +g, idle, lo, hi, c, con}:
      e_xnogroup(k, g)
    case XPqOf{y}:
      xv.pend.none(y)

# a read of a stream x (at now)
def xread(op: XRead, +now: Nat, +x: KV.XStream) -> Reply:
  match op:
    case XRLen{}:
      r_int(KV.xstream.len(x))
    case XRRange{q}:
      xv.range(x, q)
    case XRRead{q}:
      xv.read(q, Some{KV.Item{KV.VColl{KV.CStream{x}}, 0n}})
    case XRInfo{i}:
      xv.info(i, now, x)
    case XRPend{q}:
      xv.pend(q, now, x)

# of a key not there
def xread.none(op: XRead) -> Reply:
  match op:
    case XRLen{}:
      r_int(0n)
    case XRRange{q}:
      RArray{Nil{}}
    case XRRead{q}:
      xv.read(q, None{})
    case XRInfo{i}:
      RError{"ERR no such key"}
    case XRPend{q}:
      xv.pend.none(q)

# of a key that holds a string (m: the string's entry, or none)
def xread.str(op: XRead, m: Maybe<&2, KV.Item<String>>) -> Reply:
  match m:
    case Some{x}:
      e_wrongtype()
    case None{}:
      xread.none(op)

# of a key that holds a collection
def xread.coll(op: XRead, +now: Nat, +cl: KV.Coll) -> Reply:
  match cl:
    case KV.CStream{+x}:
      xread(op, now, x)
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
    case PDump{}:
      dump.of(m)
    case PStream{op}:
      xread.str(op, m)

# a Peek of a key that holds a collection: its type, its time, a read of
# a hash of a hash (so of the others), its payload, or WRONGTYPE for a
# read of a string
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
    case PDump{}:
      RBulk{D.dump(KV.VColl{cl})}
    case PStream{op}:
      xread.coll(op, now, cl)
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
# not there at now (CMemsNew: the members ms added in turn); or set it
# to the value v of a payload p, with its time e (CRestore: RESTORE's,
# which the append-only file logs as the RESTORE of p); or set it to a
# stream: one the key held, changed by a write of a stream, its time kept
# (CStream), or a new one, with no time, made by XADD where the key was
# not there at now (CStreamNew: the XADD's words ws); each keeps the
# write resolved (Stream writes, below). Each keeps the write the
# append-only file logs. An
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
  CRestore{p: String, v: KV.Val, e: Nat}
  CStream{op: XWrite, x: KV.XStream}
  CStreamNew{ws: List<&2, String>, x: KV.XStream}

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

# INCRBY as an update (as db.incr runs it): the long long the key holds
# plus by, keeping the key's time (keep), or by for a key that is not
# there; the value must read as a long long, and the sum must be one
def uincr.ch(keep: Bool, v: String) -> Change:
  match keep:
    case True{}:
      CKeepT{v}
    case False{}:
      CPut{v, 0n}

def uincr.fit(s: LL, keep: Bool) -> Out:
  match s:
    case LL{+neg, +hi, +lo}:
      +v = ll.show(neg, hi, lo)
      Out{RIntS{v}, uincr.ch(keep, v)}
    case LLBad{}:
      Out{RError{"ERR increment or decrement would overflow"}, CKeep{}}

def uincr.num(by: By, cur: LL) -> Out:
  match cur:
    case LL{+neg, +hi, +lo}:
      uincr.fit(ll.add(neg, hi, lo, by), True{})
    case LLBad{}:
      Out{e_int(), CKeep{}}

def uincr.of(by: By, m: Maybe<&2, KV.Item<String>>) -> Out:
  match m:
    case Some{KV.Item{+w, e}}:
      uincr.num(by, ll.read(w))
    case None{}:
      uincr.fit(by.ll(by), False{})

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

# (the read of each field before its write, as in KV.hash.put)
def hset.go(ps: List<&2, KV.HPair>, acc: HPut) -> HPut:
  match ps acc:
    case Nil{} acc:
      acc
    case Con{KV.HP{+f, +v}, rest} HPut{+h, +made}:
      +had = KV.hash.has(f, h)
      hset.go(rest, HPut{KV.hash.put(h, f, v), Bool.pick(Nat, had, made, 1n+made)})

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

# HINCRBY: the field's long long (0 when it is not there) plus by, which
# must make one, as INCRBY's
def hincr.fit(s: LL, +fresh: Bool, +f: String, h: KV.Hash) -> Out:
  match s:
    case LL{+neg, +hi, +lo}:
      +v = ll.show(neg, hi, lo)
      Out{RIntS{v}, hchange(fresh, [KV.HP{f, v}], KV.hash.put(h, f, v))}
    case LLBad{}:
      Out{RError{"ERR increment or decrement would overflow"}, CKeep{}}

def hincr.num(m: LL, +fresh: Bool, +f: String, by: By, h: KV.Hash) -> Out:
  match m:
    case LL{+neg, +hi, +lo}:
      hincr.fit(ll.add(neg, hi, lo, by), fresh, f, h)
    case LLBad{}:
      Out{RError{"ERR hash value is not an integer"}, CKeep{}}

def hincr.of(cur: Maybe<&2, String>, +fresh: Bool, +f: String, by: By, h: KV.Hash) -> Out:
  match cur:
    case Some{s}:
      hincr.num(ll.read(s), fresh, f, by, h)
    case None{}:
      hincr.fit(by.ll(by), fresh, f, h)

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
    case KV.CStream{x}:
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
    case KV.CStream{x}:
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
      KV.ints.nth(xs, srand.at(r, n))
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
      srand.ints(k, KV.ints.list(xs), n, r)
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

# SPOP's reply: the member it took (a nil for none), or the members (a
# set), and its change: the SREM of them
def spop.reply(one: Bool, xs: List<&2, String>) -> Reply:
  match one xs:
    case True{} Con{x, rest}:
      RBulk{x}
    case True{} Nil{}:
      RNull{}
    case False{} ys:
      RSet{lbulks(ys)}

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
    case KV.CStream{x}:
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

def zadd.old.of(nx: Bool, nan: Bool, keep: Bool, same: Bool, +sc: F.F64, +c: F.F64, +i: Nat, +m: String, z: KV.Zset, +added: Nat, +upd: Nat, +done: Nat, last: F.F64) -> ZAdd:
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
      ZAdd{KV.zset.set(z, i, m, c, sc), added, Nat.add(upd, 1n), Nat.add(done, 1n), sc}

# a member there, of score c (i: where KV.zset.find found it)
def zadd.old(+o: ZOpts, +c: F.F64, +i: Nat, +d: F.F64, +m: String, z: KV.Zset, +added: Nat, +upd: Nat, +done: Nat, last: F.F64) -> ZAdd:
  match o:
    case ZOpts{+nx, xx, +gt, +lt, ch, +incr}:
      +sc = zadd.score(incr, c, d)
      +cmp = F.f64.cmp(sc, c)
      zadd.old.of(nx, F.f64.is_nan(sc), Bool.or(Bool.and(lt, Bool.not(Cmp.is_lt(cmp))), Bool.and(gt, Bool.not(Cmp.is_gt(cmp)))), Cmp.is_eq(cmp), sc, c, i, m, z, added, upd, done, last)

def zadd.at(cur: KV.ZHit, +o: ZOpts, +d: F.F64, +m: String, z: KV.Zset, +added: Nat, +upd: Nat, +done: Nat, last: F.F64) -> ZAdd:
  match cur:
    case KV.ZYes{+c, +i}:
      zadd.old(o, c, i, d, m, z, added, upd, done, last)
    case KV.ZNo{}:
      zadd.new(zopts.xx(o), d, m, z, added, upd, done, last)

def zadd.step(+o: ZOpts, p: ZPair, st: ZAdd) -> ZAdd:
  match p st:
    case _ ZAddNaN{}:
      ZAddNaN{}
    case ZPair{+s, +m} ZAdd{+z, added, upd, done, last}:
      zadd.at(KV.zset.find(m, z), o, zadd.num(F.f64.parse(s)), m, z, added, upd, done, last)

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
      Bool.pick(Reply, Nat.is_eq(done, 0n), RNull{}, RDbl{F.f64.show(last)})
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

def zrem.one(m: KV.ZHit, z: KV.Zset, +k: String, +gone: Nat) -> ZDel:
  match m:
    case KV.ZYes{+d, +i}:
      ZDel{KV.zset.del.at(z, i, k, d), Nat.add(gone, 1n)}
    case KV.ZNo{}:
      ZDel{z, gone}

def zrem.go(ms: List<&2, String>, st: ZDel) -> ZDel:
  match ms st:
    case Nil{} acc:
      acc
    case Con{+m, rest} ZDel{+z, +gone}:
      zrem.go(rest, zrem.one(KV.zset.find(m, z), z, m, gone))

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
# last), answered with their scores, in the order they are taken: flat
# without a count, as pairs with one (genericZpopCommand's nested array
# in RESP3)
def zpop.reply(+op: ZWrite, xs: List<&2, KV.ZEl>) -> Reply:
  match op:
    case ZWPopN{max, c}:
      RPairs{zels(xs, True{})}
    case _:
      RArray{zels.flat(xs)}

def zpop.pick(max: Bool, +k: Nat, +n: Nat, +z: KV.Zset) -> List<&2, KV.ZEl>:
  match max:
    case True{}:
      KV.zset.slice(True{}, z, Nat.sub(n, k), n)
    case False{}:
      KV.zset.slice(False{}, z, 0n, k)

def zpop.els(+max: Bool, +c: Nat, +z: KV.Zset) -> List<&2, KV.ZEl>:
  +n = KV.zset.len(z)
  zpop.pick(max, Nat.min(c, n), n, z)

def zpop.of(m: Maybe<&2, Nat>, +max: Bool, +op: ZWrite, +z: KV.Zset) -> Out:
  match m:
    case Some{+c}:
      +xs = zpop.els(max, c, z)
      zdels.out(xs, op, z, zpop.reply(op, xs))
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

# Stream writes
# -------------
# XADD, XTRIM, XDEL and XSETID on a stream x (an empty one for a key not
# there: fresh), each read again from the words it keeps, as Redis reads
# them (Stream.bend changes the stream). A write whose change depends on
# the clock or on what the stream holds (XADD's * and <ms>-*, a trim by
# ~, and NOMKSTREAM, which a key there makes no matter) is resolved
# first: its words become those of the exact write it makes (the ID it
# adds; the exact trim at the threshold it reaches, X.xs.approx), which
# the write then runs and the change keeps, and the file logs. Resolved
# words resolve to themselves, so the file's write makes the same change
# at time 0 (PROOF.bend: log_replay).

def e_xexhausted() -> Reply:
  RError{"ERR The stream has exhausted the last possible ID, unable to add more items"}

def e_xsmall() -> Reply:
  RError{"ERR The ID specified in XADD is equal or smaller than the target stream top item"}

def e_xlarge() -> Reply:
  RError{"ERR Elements are too large to be stored"}

def e_xres() -> Reply:
  RError{"ERR the stream write does not resolve"}

# XADD's words resolved, or the error its ID or its elements meet
type XRs is Data:
  XRsOk{ws: List<&2, String>}
  XRsBad{r: Reply}

# the ID XADD adds after the stream's last ID: an ID's own; for * the
# next one at now (now's with sequence 0 when now is past the last's ms,
# else the one after the last: streamNextID); for <ms>-* the last's
# sequence + 1 when the last is of ms (none past the last sequence), else
# sequence 0
def xa.seq(same: Bool, +ms: KV.XN, +lsq: KV.XN) -> Maybe<&2, KV.XId>:
  match same:
    case True{}:
      Bool.pick(Maybe<&2, KV.XId>, X.xn.is_max(lsq), None{}, Some{KV.XId{ms, KV.xn.add(lsq, X.xn.one())}})
    case False{}:
      Some{KV.XId{ms, X.xn.zero()}}

def xa.auto(+now: KV.XN, +lms: KV.XN, +lsq: KV.XN) -> Maybe<&2, KV.XId>:
  Bool.pick(Maybe<&2, KV.XId>, Cmp.is_gt(KV.xn.cmp(now, lms)), Some{KV.XId{now, X.xn.zero()}}, X.xid.incr(KV.XId{lms, lsq}))

def xa.newid.at(id: XAId, +lms: KV.XN, +lsq: KV.XN, +now: Nat) -> Maybe<&2, KV.XId>:
  match id:
    case XAAt{x}:
      Some{x}
    case XAAuto{}:
      xa.auto(KV.xn.of(now), lms, lsq)
    case XASeq{+ms}:
      xa.seq(KV.xn.is_eq(ms, lms), ms, lsq)

def xa.newid(id: XAId, +last: KV.XId, +now: Nat) -> Maybe<&2, KV.XId>:
  match last:
    case KV.XId{+lms, +lsq}:
      xa.newid.at(id, lms, lsq, now)

# a trim's words resolved: an exact one's threshold word as it came, a ~'s
# threshold as the exact trim that runs it (X.xs.approx), on x1, the
# stream it trims
def xts.kind(+s: X.XTs) -> String:
  match s:
    case X.XTMax{n}:
      "MAXLEN"
    case X.XTMin{id}:
      "MINID"

def xts.words(+s: X.XTs, rest: List<&2, String>) -> List<&2, String>:
  match s:
    case X.XTMax{+n}:
      "MAXLEN" <> "=" <> Nat.show(n) <> rest
    case X.XTMin{+id}:
      "MINID" <> "=" <> X.xid.show(id) <> rest

def xadd.trw.of(ap: Bool, +s: X.XTs, +v: String, +lim: Nat, +x: KV.XStream, +nid: KV.XId, +fv: List<&2, String>, +nf: Nat, +tot: Nat, rest: List<&2, String>) -> List<&2, String>:
  match ap:
    case True{}:
      xts.words(X.xs.approx(X.xs.add(x, nid, fv, nf, tot), s, lim), rest)
    case False{}:
      xts.kind(s) <> "=" <> v <> rest

def xadd.trw(t: XTo, +x: KV.XStream, +nid: KV.XId, +fv: List<&2, String>, +nf: Nat, +tot: Nat, rest: List<&2, String>) -> List<&2, String>:
  match t:
    case XTNo{}:
      rest
    case XTo{+s, +v, ap, +lim}:
      xadd.trw.of(ap, s, v, lim, x, nid, fv, nf, tot, rest)

def xaid.at(+id: XAId) -> Bool:
  match id:
    case XAAt{x}:
      True{}
    case _:
      False{}

# XADD's checks of the ID it adds and of its elements (streamAppendItem):
# the ID past the stream's last (gt), its fields and values within 1 GiB
# (big: past it)
def xadd.res.chk(gt: Bool, big: Bool, +nid: KV.XId, tr: XTo, +id: XAId, +w: String, +fv: List<&2, String>, +nf: Nat, +tot: Nat, +x: KV.XStream) -> XRs:
  match gt big:
    case False{} _:
      XRsBad{e_xsmall()}
    case True{} True{}:
      XRsBad{e_xlarge()}
    case True{} False{}:
      XRsOk{xadd.trw(tr, x, nid, fv, nf, tot, Bool.pick(String, xaid.at(id), w, X.xid.show(nid)) <> fv)}

def xadd.res.at(m: Maybe<&2, KV.XId>, a: XA, +x: KV.XStream) -> XRs:
  match m a:
    case Some{+nid} XA{nomk, tr, +id, +w, +fv, +nf}:
      +tot = X.xe.tot(fv, 0n)
      xadd.res.chk(Cmp.is_gt(KV.xid.cmp(nid, X.xstream.last(x))), Nat.is_lt(1073741824n, tot), nid, tr, id, w, fv, nf, tot, x)
    case None{} XA{nomk, tr, id, w, fv, nf}:
      XRsBad{e_xlarge()}
    case _ XABad{r}:
      XRsBad{r}

def xa.newid.of(+a: XA, +x: KV.XStream, +now: Nat) -> Maybe<&2, KV.XId>:
  match a:
    case XA{nomk, tr, +id, w, fv, nf}:
      xa.newid(id, X.xstream.last(x), now)
    case XABad{r}:
      None{}

# XADD's words ws (a: as they read) resolved on x at now: as they are
# when they are resolved (an ID, no NOMKSTREAM, an exact trim or none)
def xto.exact(tr: XTo) -> Bool:
  match tr:
    case XTNo{}:
      True{}
    case XTo{s, v, ap, lim}:
      Bool.not(ap)

def xa.fixed(a: XA) -> Bool:
  match a:
    case XA{nomk, tr, id, w, fv, nf}:
      Bool.and(Bool.not(nomk), Bool.and(xto.exact(tr), xaid.at(id)))
    case XABad{r}:
      False{}

def xadd.res.if(c: Bool, +ws: List<&2, String>, +a: XA, +x: KV.XStream, +now: Nat) -> XRs:
  match c:
    case True{}:
      XRsOk{ws}
    case False{}:
      xadd.res.at(xa.newid.of(a, x, now), a, x)

def xadd.resolve(+ws: List<&2, String>, +a: XA, +x: KV.XStream, +now: Nat) -> XRs:
  xadd.res.if(xa.fixed(a), ws, a, x, now)

# the stream x1 trimmed by a resolved XADD (exactly), or as it is
def xs.trimmed(r: X.XTrd) -> KV.XStream:
  match r:
    case X.XTrd{x, del}:
      x

def xadd.trim(t: XTo, +x1: KV.XStream) -> KV.XStream:
  match t:
    case XTNo{}:
      x1
    case XTo{+s, v, +ap, +lim}:
      xs.trimmed(X.xs.trim(x1, s, ap, lim))

def xadd.out(fresh: Bool, +ws: List<&2, String>, r: Reply, x2: KV.XStream) -> Out:
  match fresh:
    case True{}:
      Out{r, CStreamNew{ws, x2}}
    case False{}:
      Out{r, CStream{XWAdd{ws}, x2}}

def xadd.apply.chk(gt: Bool, big: Bool, +id: KV.XId, tr: XTo, +fv: List<&2, String>, +nf: Nat, +tot: Nat, +ws: List<&2, String>, +fresh: Bool, +x: KV.XStream) -> Out:
  match gt big:
    case False{} _:
      Out{e_xsmall(), CKeep{}}
    case True{} True{}:
      Out{e_xlarge(), CKeep{}}
    case True{} False{}:
      xadd.out(fresh, ws, RBulk{X.xid.show(id)}, xadd.trim(tr, X.xs.add(x, id, fv, nf, tot)))

# a resolved XADD run: its entry added, then its exact trim
def xadd.apply(tr: XTo, +id: KV.XId, +fv: List<&2, String>, +nf: Nat, +ws: List<&2, String>, +fresh: Bool, +x: KV.XStream) -> Out:
  +tot = X.xe.tot(fv, 0n)
  xadd.apply.chk(Cmp.is_gt(KV.xid.cmp(id, X.xstream.last(x))), Nat.is_lt(1073741824n, tot), id, tr, fv, nf, tot, ws, fresh, x)

# the resolved words ws (a1: as they read again) run; words that do not
# resolve are no write, nor fewer than XADD's three (which the parser
# answers first, and the file's command needs)
def xadd.fin.of(a1: XA, +ws: List<&2, String>, +fresh: Bool, +x: KV.XStream) -> Out:
  match a1:
    case XA{False{}, XTNo{}, XAAt{+id}, w, +fv, +nf}:
      xadd.apply(XTNo{}, id, fv, nf, ws, fresh, x)
    case XA{False{}, XTo{+s, +v, False{}, +lim}, XAAt{+id}, w, +fv, +nf}:
      xadd.apply(XTo{s, v, False{}, lim}, id, fv, nf, ws, fresh, x)
    case _:
      Out{e_xres(), CKeep{}}

def xadd.fin(a1: XA, +ws: List<&2, String>, +fresh: Bool, +x: KV.XStream) -> Out:
  match ws:
    case Con{+a, Con{+b, Con{+c, +rest}}}:
      xadd.fin.of(a1, Con{a, Con{b, Con{c, rest}}}, fresh, x)
    case _:
      Out{e_xres(), CKeep{}}

def xadd.go(r: XRs, +fresh: Bool, +x: KV.XStream) -> Out:
  match r:
    case XRsOk{+ws1}:
      xadd.fin(xadd.read(ws1), ws1, fresh, x)
    case XRsBad{e}:
      Out{e, CKeep{}}

def xa.err(+a: XA) -> Reply:
  match a:
    case XABad{+r}:
      r
    case _:
      e_xres()

# what XADD meets first: 0 nothing, 1 a key not there with NOMKSTREAM (a
# null), 2 an error of its words; then (ex) a stream at the last ID
def xa.code(+a: XA, +fresh: Bool) -> Nat:
  match a:
    case XABad{r}:
      2n
    case XA{+nomk, tr, id, w, fv, nf}:
      Bool.pick(Nat, Bool.and(fresh, nomk), 1n, 0n)

def xadd.run.of(c: Nat, ex: Bool, +ws: List<&2, String>, +a: XA, +fresh: Bool, +x: KV.XStream, +now: Nat) -> Out:
  match c ex:
    case 0n False{}:
      xadd.go(xadd.resolve(ws, a, x, now), fresh, x)
    case 0n True{}:
      Out{e_xexhausted(), CKeep{}}
    case 1n _:
      Out{RNull{}, CKeep{}}
    case _ _:
      Out{xa.err(a), CKeep{}}

# XADD of the words ws (a: as they read) on x at now
def xadd.run(+ws: List<&2, String>, +a: XA, +fresh: Bool, +x: KV.XStream, +now: Nat) -> Out:
  xadd.run.of(xa.code(a, fresh), X.xs.exhausted(x), ws, a, fresh, x, now)

# XTRIM: by ~, resolved to the exact trim that runs it; the reply the
# entries deleted, no change for none
def xtrim.resolve(+ws: List<&2, String>, tr: XTo, +x: KV.XStream) -> List<&2, String>:
  match tr:
    case XTo{+s, v, True{}, +lim}:
      xts.words(X.xs.approx(x, s, lim), Nil{})
    case _:
      ws

def xtrim.out.of(none: Bool, +del: Nat, x2: KV.XStream, +ws: List<&2, String>) -> Out:
  match none:
    case True{}:
      Out{r_int(0n), CKeep{}}
    case False{}:
      Out{r_int(del), CStream{XWTrim{ws}, x2}}

def xtrim.out(r: X.XTrd, +ws: List<&2, String>) -> Out:
  match r:
    case X.XTrd{x2, +del}:
      xtrim.out.of(Nat.is_eq(del, 0n), del, x2, ws)

def xtrim.fin.of(t: XT, +ws: List<&2, String>, +x: KV.XStream) -> Out:
  match t:
    case XT{XTo{+s, v, False{}, lim}}:
      xtrim.out(X.xs.trim(x, s, False{}, 0n), ws)
    case _:
      Out{e_xres(), CKeep{}}

# (nor fewer words than XTRIM's two)
def xtrim.fin(t: XT, +ws: List<&2, String>, +x: KV.XStream) -> Out:
  match ws:
    case Con{+a, Con{+b, +rest}}:
      xtrim.fin.of(t, Con{a, Con{b, rest}}, x)
    case _:
      Out{e_xres(), CKeep{}}

def xtrim.run(+ws: List<&2, String>, t: XT, +x: KV.XStream) -> Out:
  match t:
    case XTBad{r}:
      Out{r, CKeep{}}
    case XT{tr}:
      +ws1 = xtrim.resolve(ws, tr, x)
      xtrim.fin(xtrim.read(ws1), ws1, x)

# XDEL: its IDs read (strictly), then each live entry of them deleted;
# the reply how many, no change for none
def xdel.out.of(none: Bool, +n: Nat, x2: KV.XStream, +ids: List<&2, String>) -> Out:
  match none:
    case True{}:
      Out{r_int(0n), CKeep{}}
    case False{}:
      Out{r_int(n), CStream{XWDel{ids}, x2}}

def xdel.out(r: X.XDr, +ids: List<&2, String>) -> Out:
  match r:
    case X.XDr{x2, +n}:
      xdel.out.of(Nat.is_eq(n, 0n), n, x2, ids)

def xdel.of(m: Maybe<&2, List<&2, KV.XId>>, +ids: List<&2, String>, +x: KV.XStream) -> Out:
  match m:
    case Some{xl}:
      xdel.out(X.xs.del(x, xl), ids)
    case None{}:
      Out{e_xid(), CKeep{}}

def xdel.run(+ids: List<&2, String>, +x: KV.XStream) -> Out:
  match ids:
    case Con{+i, +rest}:
      xdel.of(X.xids.parse(Con{i, rest}), Con{i, rest}, x)
    case Nil{}:
      Out{r_int(0n), CKeep{}}

# XSETID: on a stream with entries, an ID below its last live one or an
# entries-added below its length is an error; else the last ID, the
# entries added (when given) and the greatest ID deleted (when given, but
# 0-0) set. Redis 7.0 does not check the ID against the greatest deleted
# one the stream holds (7.2 does)
def xsetid.top.of(m: Maybe<&2, KV.XId>) -> KV.XId:
  match m:
    case Some{t}:
      t
    case None{}:
      X.xid.zero()

def xsetid.few(+added: Maybe<&2, KV.XN>, +n: Nat) -> Bool:
  match added:
    case Some{+a}:
      Cmp.is_gt(KV.xn.cmp(KV.xn.of(n), a))
    case None{}:
      False{}

def xsetid.code(+id: KV.XId, +added: Maybe<&2, KV.XN>, +x: KV.XStream) -> Nat:
  +n = KV.xstream.len(x)
  +some = Nat.is_lt(0n, n)
  Bool.pick(Nat, Bool.and(some, Cmp.is_lt(KV.xid.cmp(id, xsetid.top.of(X.xs.top(x))))), 1n, Bool.pick(Nat, Bool.and(some, xsetid.few(added, n)), 2n, 0n))

def xsetid.added.or(m: Maybe<&2, KV.XN>, +d: KV.XN) -> KV.XN:
  match m:
    case Some{a}:
      a
    case None{}:
      d

def xsetid.set(+x: KV.XStream, +id: KV.XId, +added: Maybe<&2, KV.XN>, +md: KV.XId) -> KV.XStream:
  match x:
    case KV.XStr{n, last, first, +maxdel, +ad, nodes, groups}:
      KV.XStr{n, id, first, Bool.pick(KV.XId, X.xid.is_zero(md), maxdel, md), xsetid.added.or(added, ad), nodes, groups}
    case KV.XStrOf{+y}:
      xsetid.set(y, id, added, md)

def xsetid.chk(c: Nat, +id: KV.XId, +added: Maybe<&2, KV.XN>, +md: KV.XId, +ws: List<&2, String>, +x: KV.XStream) -> Out:
  match c:
    case 0n:
      Out{r_ok(), CStream{XWSetId{ws}, xsetid.set(x, id, added, md)}}
    case 1n:
      Out{RError{"ERR The ID specified in XSETID is smaller than the target stream top item"}, CKeep{}}
    case _:
      Out{RError{"ERR The entries_added specified in XSETID is smaller than the target stream length"}, CKeep{}}

def xsetid.run.of(+ws: List<&2, String>, s: XS, +x: KV.XStream) -> Out:
  match s:
    case XSBad{r}:
      Out{r, CKeep{}}
    case XS{+id, +added, +md}:
      xsetid.chk(xsetid.code(id, added, x), id, added, md, ws, x)

# (an XSETID has its ID word, as the parser has it)
def xsetid.run(+ws: List<&2, String>, s: XS, +x: KV.XStream) -> Out:
  match ws:
    case Con{+i, +rest}:
      xsetid.run.of(Con{i, rest}, s, x)
    case Nil{}:
      Out{e_xres(), CKeep{}}

def xsetid.none(s: XS) -> Out:
  match s:
    case XSBad{r}:
      Out{r, CKeep{}}
    case XS{id, a, md}:
      Out{RError{"ERR no such key"}, CKeep{}}

# a write of a stream to the stream x (an empty one for a key not there:
# fresh) at now; XWNew makes a new stream whatever x is
def xwrite(op: XWrite, +fresh: Bool, +x: KV.XStream, +now: Nat) -> Out:
  match op:
    case XWAdd{+ws}:
      xadd.run(ws, xadd.read(ws), fresh, x, now)
    case XWTrim{+ws}:
      xtrim.run(ws, xtrim.read(ws), x)
    case XWDel{+ids}:
      xdel.run(ids, x)
    case XWSetId{+ws}:
      xsetid.run(ws, xsetid.read(ws), x)
    case XWNew{+ws}:
      xadd.run(ws, xadd.read(ws), True{}, X.xs.empty(), now)

# of a key not there: XADD makes it (with NOMKSTREAM a null), XTRIM and
# XDEL answer 0, XSETID an error (after its words' errors)
def xwrite.none(op: XWrite, +now: Nat) -> Out:
  match op:
    case XWTrim{ws}:
      Out{r_int(0n), CKeep{}}
    case XWDel{ids}:
      Out{r_int(0n), CKeep{}}
    case XWSetId{+ws}:
      xsetid.none(xsetid.read(ws))
    case other:
      xwrite(other, True{}, X.xs.empty(), now)

# of a key that holds another kind: WRONGTYPE, but for XWNew
def xwrite.wrong(op: XWrite, +now: Nat) -> Out:
  match op:
    case XWNew{+ws}:
      xwrite(XWNew{ws}, True{}, X.xs.empty(), now)
    case _:
      Out{e_wrongtype(), CKeep{}}

# of a key that holds a string (m: the string's entry, or none)
def xwrite.str(op: XWrite, +now: Nat, m: Maybe<&2, KV.Item<String>>) -> Out:
  match m:
    case Some{x}:
      xwrite.wrong(op, now)
    case None{}:
      xwrite.none(op, now)

# of a key that holds a collection
def xwrite.coll(op: XWrite, +now: Nat, +cl: KV.Coll) -> Out:
  match cl:
    case KV.CStream{x}:
      xwrite(op, False{}, x, now)
    case _:
      xwrite.wrong(op, now)

# HyperLogLog
# -----------
# PFADD, PFCOUNT, PFMERGE, PFDEBUG and PFSELFTEST as Redis 7.0.15 runs
# them (hyperloglog.c) on a string that holds a HyperLogLog (hll.bend).
# A string that is none (H.valid) answers the WRONGTYPE error of its
# own, a key of another kind the usual one; a sparse HyperLogLog whose
# opcodes Redis finds invalid answers INVALIDOBJ. A sparse one turns
# dense past 3000 bytes, hll-sparse-max-bytes's default: BendKV does not
# read the parameter, as a write of one key runs on its database alone.

def e_hll_type() -> Reply:
  RError{"WRONGTYPE Key is not a valid HyperLogLog string value."}

def e_hll_bad() -> Reply:
  RError{"INVALIDOBJ Corrupted HLL object detected"}

def hll.max() -> Nat:
  3000n

# a cardinality as addReplyLongLong sends a uint64_t: as a long long
def hll.reply(c: H.W) -> Reply:
  match c:
    case H.W{+hi, +lo}:
      RIntS{w64.show(W64{hi, lo})}

# PFADD: of a key not there, a new HyperLogLog with the elements in it
# (1, its value set with no time); of one there, 1 and its value with
# its time when a register changed, else 0; the error of an invalid one
# (its value changed by the elements before, which Redis keeps; a key
# made keeps its value, as Redis adds the key before it adds to it)
def pfadd.out(o: H.AddOut, made: Bool) -> Out:
  match o:
    case H.AddDone{ch, v}:
      match ch made:
        case True{} True{}:
          Out{r_int(1n), CPut{v, 0n}}
        case True{} False{}:
          Out{r_int(1n), CKeepT{v}}
        case False{} _:
          Out{r_int(0n), CKeep{}}
    case H.AddErr{ch, v}:
      match ch made:
        case _ True{}:
          Out{e_hll_bad(), CPut{v, 0n}}
        case True{} False{}:
          Out{e_hll_bad(), CKeepT{v}}
        case False{} False{}:
          Out{e_hll_bad(), CKeep{}}

def pfadd.some(ok: Bool, +w: String, els: List<&2, String>) -> Out:
  match ok:
    case True{}:
      pfadd.out(H.add(False{}, w, hll.max(), els), False{})
    case False{}:
      Out{e_hll_type(), CKeep{}}

def pfadd.of(els: List<&2, String>, m: Maybe<&2, KV.Item<String>>) -> Out:
  match m:
    case Some{KV.Item{+w, e}}:
      pfadd.some(H.valid(w), w, els)
    case None{}:
      pfadd.out(H.add(True{}, H.fresh(), hll.max(), els), True{})

# PFCOUNT of one key: 0 for a key not there; the count kept in the value,
# when it is valid; else the count made, which the value keeps (the
# SETRANGE of its 8 bytes at 8)
def pfcount.cnt(c: H.Count, +w: String) -> Out:
  match c:
    case H.CntBad{}:
      Out{e_hll_bad(), CKeep{}}
    case H.CntKept{x}:
      Out{hll.reply(x), CKeep{}}
    case H.CntNew{+x}:
      +s = H.card.bytes(x)
      Out{hll.reply(x), CRange{8n, s, range.put(w, 8n, s)}}

def pfcount.some(ok: Bool, +w: String) -> Out:
  match ok:
    case True{}:
      pfcount.cnt(H.count(w), w)
    case False{}:
      Out{e_hll_type(), CKeep{}}

def pfcount.of(m: Maybe<&2, KV.Item<String>>) -> Out:
  match m:
    case Some{KV.Item{+w, e}}:
      pfcount.some(H.valid(w), w)
    case None{}:
      Out{r_int(0n), CKeep{}}

# PFDEBUG's subcommands, as strcasecmp compares them: 1 GETREG, 2 DECODE,
# 3 ENCODING, 4 TODENSE, 0 none
def pfdebug.id(+sub: String) -> Nat:
  +u = String.to_upper(cstr(sub))
  Bool.pick(Nat, String.eq(u, "GETREG"), 1n,
  Bool.pick(Nat, String.eq(u, "DECODE"), 2n,
  Bool.pick(Nat, String.eq(u, "ENCODING"), 3n,
  Bool.pick(Nat, String.eq(u, "TODENSE"), 4n, 0n))))

def pfdebug.regs(xs: List<&2, Nat>) -> List<&2, Reply>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{x, rest}:
      r_int(x) <> pfdebug.regs(rest)

# a sparse value made dense, which the key keeps: the reply r says what
# of it (GETREG: its registers; TODENSE: 1)
def pfdebug.dense(m: Maybe<&2, String>, regs: Bool) -> Out:
  match m:
    case Some{+v}:
      Out{Bool.pick(Reply, regs, RArray{pfdebug.regs(H.d.regs(v))}, r_int(1n)), CKeepT{v}}
    case None{}:
      Out{e_hll_bad(), CKeep{}}

def pfdebug.sub(id: Nat, sparse: Bool, +sub: String, +w: String) -> Out:
  match id:
    case 1n:
      match sparse:
        case True{}:
          pfdebug.dense(H.sp.dense(w, 0), True{})
        case False{}:
          Out{RArray{pfdebug.regs(H.d.regs(w))}, CKeep{}}
    case 2n:
      Out{Bool.pick(Reply, sparse, RBulk{H.sp.decode(w)}, RError{"ERR HLL encoding is not sparse"}), CKeep{}}
    case 3n:
      Out{RStatus{Bool.pick(String, sparse, "sparse", "dense")}, CKeep{}}
    case 4n:
      match sparse:
        case True{}:
          pfdebug.dense(H.sp.dense(w, 0), False{})
        case False{}:
          Out{r_int(0n), CKeep{}}
    case _:
      Out{RError{e_fmt("ERR Unknown PFDEBUG subcommand '" ++ cstr(sub) ++ "'")}, CKeep{}}

def pfdebug.some(ok: Bool, +sub: String, +w: String) -> Out:
  match ok:
    case True{}:
      pfdebug.sub(pfdebug.id(sub), H.is_sparse(w), sub, w)
    case False{}:
      Out{e_hll_type(), CKeep{}}

# PFDEBUG: the key must be there, and hold a HyperLogLog; GETREG and
# TODENSE make a sparse one dense
def pfdebug.of(+sub: String, m: Maybe<&2, KV.Item<String>>) -> Out:
  match m:
    case Some{KV.Item{+w, e}}:
      pfdebug.some(H.valid(w), sub, w)
    case None{}:
      Out{RError{"ERR The specified key does not exist"}, CKeep{}}

# a write of a HyperLogLog's key, from the string it holds there at now
def hll.upd(op: HllOp, m: Maybe<&2, KV.Item<String>>) -> Out:
  match op:
    case HAdd{els}:
      pfadd.of(els, m)
    case HCount{}:
      pfcount.of(m)
    case HDebug{+sub}:
      pfdebug.of(sub, m)

# The HyperLogLogs of several keys (PFCOUNT of several, PFMERGE): their
# registers' maxima so far, or the error of the first key that is not
# one (or whose opcodes are invalid), in the keys' order
type PfRead is Data:
  PfOk{acc: H.Acc}
  PfErr{r: Reply}

def pf.read.acc(a: H.Acc) -> PfRead:
  match a:
    case H.AccS{x}:
      PfOk{H.AccS{x}}
    case H.AccD{x}:
      PfOk{H.AccD{x}}
    case H.AccBad{}:
      PfErr{e_hll_bad()}

def pf.read.s(ok: Bool, +w: String, acc: H.Acc) -> PfRead:
  match ok:
    case True{}:
      pf.read.acc(H.acc.add(acc, w))
    case False{}:
      PfErr{e_hll_type()}

def pf.read.v(m: Maybe<&2, KV.Val>, acc: H.Acc) -> PfRead:
  match m:
    case None{}:
      PfOk{acc}
    case Some{KV.VStr{+w}}:
      pf.read.s(H.valid(w), w, acc)
    case Some{KV.VColl{c}}:
      PfErr{e_wrongtype()}

def pf.read(ks: List<&2, String>, st: PfRead, +t: KV.Trie<KV.Val>, +now: Nat) -> PfRead:
  match ks:
    case Nil{}:
      st
    case Con{+k, rest}:
      match st:
        case PfOk{acc}:
          pf.read(rest, pf.read.v(KV.read(KV.Val, t, k, now), acc), t, now)
        case PfErr{r}:
          PfErr{r}

def pf.count.of(r: PfRead) -> Reply:
  match r:
    case PfOk{a}:
      hll.reply(H.acc.count(a))
    case PfErr{e}:
      e

# PFCOUNT of several keys: the count of their union (a key not there as
# an empty HyperLogLog); none of them keeps it
def pf.count(ks: List<&2, String>, +d: Db) -> Reply:
  pf.count.of(pf.read(ks, PfOk{H.acc.new()}, db.trie(d), db.now(d)))

# PFMERGE's reply, as its act (APfMerge) answers: OK, or the error of the
# first key that is no HyperLogLog
def pf.merge.reply.of(r: PfRead) -> Reply:
  match r:
    case PfErr{e}:
      e
    case PfOk{a}:
      r_ok()

def pf.merge.reply(+dst: String, srcs: List<&2, String>, +d: Db) -> Reply:
  pf.merge.reply.of(pf.read(dst <> srcs, PfOk{H.acc.new()}, db.trie(d), db.now(d)))

def pf.merge.put(m: Maybe<&2, String>, +dst: String) -> Cmd:
  match m:
    case Some{v}:
      Upd{dst, USet{v, 0n, TKeep{}, "set"}}
    case None{}:
      Bad{e_hll_bad()}

def pf.merge.at(v: Maybe<&2, KV.Val>, +dst: String, a: H.Acc) -> Cmd:
  match v:
    case Some{KV.VStr{+w}}:
      pf.merge.put(H.merge(w, a, hll.max()), dst)
    case _:
      pf.merge.put(H.merge(H.fresh(), a, hll.max()), dst)

def pf.merge.of(r: PfRead, +dst: String, +t: KV.Trie<KV.Val>, +now: Nat) -> Cmd:
  match r:
    case PfOk{a}:
      pf.merge.at(KV.read(KV.Val, t, dst, now), dst, a)
    case PfErr{e}:
      Bad{e}

# PFMERGE's write of its destination (APfMerge): the union of the
# HyperLogLogs of its keys (the destination's among them), which the
# destination keeps with its time, or holds as a new key; the SET of the
# value that makes, with KEEPTTL, which answers OK as PFMERGE does; or
# the error of a key, which writes nothing
def pf.merge.cmd(+t: KV.Trie<KV.Val>, +now: Nat, +dst: String, srcs: List<&2, String>) -> Cmd:
  pf.merge.of(pf.read(dst <> srcs, PfOk{H.acc.new()}, t, now), dst, t, now)

def pf.selftest.of(m: Maybe<&2, String>) -> Reply:
  match m:
    case None{}:
      r_ok()
    case Some{e}:
      RError{"ERR " ++ e}

# PFSELFTEST's reply (H.selftest)
def pf.selftest() -> Reply:
  pf.selftest.of(H.selftest())

# RESTORE's update, from whether its key is there at now (live)
def restore.gone(live: Bool) -> Out:
  Bool.pick(Out, live, Out{r_ok(), CDel{}}, Out{r_ok(), CKeep{}})

def restore.past(past: Bool, +a: At, p: String, v: KV.Val, live: Bool) -> Out:
  match past:
    case True{}:
      restore.gone(live)
    case False{}:
      Out{r_ok(), CRestore{p, v, KV.clamp(at.exp(a))}}

def restore.at(m: Maybe<&2, At>, p: String, v: KV.Val, live: Bool, +now: Nat) -> Out:
  match m:
    case Some{+a}:
      restore.past(at.past(a, now), a, p, v, live)
    case None{}:
      restore.gone(live)

def restore.ms(ms: Nat, at: Bool, p: String, v: KV.Val, live: Bool, +now: Nat) -> Out:
  match ms:
    case 0n:
      Out{r_ok(), CRestore{p, v, 0n}}
    case 1n+q:
      restore.at(at.of(TmN{at, 1n+q}, now), p, v, live, now)

def restore.when(t: Tm, p: String, v: KV.Val, live: Bool, +now: Nat) -> Out:
  match t:
    case TmN{at, ms}:
      restore.ms(ms, at, p, v, live, now)
    case TmB{at, neg, hi, lo}:
      restore.at(at.of(TmB{at, neg, hi, lo}, now), p, v, live, now)

def restore.load(m: Maybe<&2, KV.Val>, p: String, t: Tm, live: Bool, +now: Nat) -> Out:
  match m:
    case Some{v}:
      restore.when(t, p, v, live, now)
    case None{}:
      Out{RError{"ERR Bad data format"}, CKeep{}}

def restore.check(ok: Bool, +p: String, t: Tm, live: Bool, +now: Nat) -> Out:
  match ok:
    case True{}:
      restore.load(D.load(p), p, t, live, now)
    case False{}:
      Out{RError{"ERR DUMP payload version or checksum are wrong"}, CKeep{}}

def restore.ttl(t: TmR, +p: String, live: Bool, +now: Nat) -> Out:
  match t:
    case TOk{TmB{at, True{}, hi, lo}}:
      Out{RError{"ERR Invalid TTL value, must be >= 0"}, CKeep{}}
    case TOk{x}:
      restore.check(D.verify(p), p, x, live, now)
    case TBad{r}:
      Out{r, CKeep{}}

def restore.busy(busy: Bool, p: String, t: TmR, live: Bool, +now: Nat) -> Out:
  match busy:
    case True{}:
      Out{RError{"BUSYKEY Target key name already exists."}, CKeep{}}
    case False{}:
      restore.ttl(t, p, live, now)

def restore.live(+live: Bool, p: String, t: TmR, +rep: Bool, +now: Nat) -> Out:
  restore.busy(Bool.and(Bool.not(rep), live), p, t, live, now)

# RESTORE of a key whose entry there at now is m (a collection's seen as a
# string's: RESTORE reads only whether the key is there)
def restore.of(p: String, t: TmR, +rep: Bool, +now: Nat, m: Maybe<&2, KV.Item<String>>) -> Out:
  restore.live(Maybe.is_some(&2, KV.Item<String>, m), p, t, rep, now)

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
    case UHll{op}:
      hll.upd(op, m)
    case URestore{p, t, +rep, ac}:
      restore.of(p, t, rep, now, m)
    case UStream{op}:
      xwrite.str(op, now, m)

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
    case URestore{p, t, rep, ac}:
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
    case UStream{xop}:
      xwrite.coll(xop, now, cl)
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
    case CRestore{p, v, +e}:
      (r, Db{KV.setx.at(KV.Val, t, k, v, e, h), cnt.n(c, n), cnt.x(c, e, x), now, rr})
    case CStream{op, xv}:
      (r, Db{KV.keep.at(KV.Val, t, k, KV.VColl{KV.CStream{xv}}, h), n, x, now, rr})
    case CStreamNew{ws, xv}:
      (r, Db{KV.setx.at(KV.Val, t, k, KV.VColl{KV.CStream{xv}}, 0n, h), cnt.n(c, n), cnt.x(c, 0n, x), now, rr})

def upd.put(t: KV.Trie<KV.Val>, +k: String, +h: U32, +n: Nat, +x: Nat, now: Nat, rr: Maybe<&2, Db>, +c: Nat, o: Out) -> Reply & Db:
  match o:
    case Out{r, ch}:
      upd.ch(t, k, h, n, x, now, rr, c, r, ch)

# whether an update of a key whose entry there at now is m takes the key's
# value out of the keyspace while it changes it: an HSET of pairs to a
# hash, or an SADD to a set that lacks its first member, which write the
# collection over for sure (PROOF.bend: takes_over). The keyspace holding
# the collection meanwhile would make the write copy the path it changes
# in it, and the keyspace drop the old path after.
def upd.takes(+op: UpdOp, +m: Maybe<&2, KV.Item<KV.Val>>) -> Bool:
  match op m:
    case UHash{HWSet{Con{p, rest}, mset}} Some{KV.Item{KV.VColl{KV.CHash{h}}, e}}:
      True{}
    case UMems{SWAdd{Con{+x, rest}}} Some{KV.Item{KV.VColl{KV.CMems{KV.MBig{n, +t}}}, e}}:
      Bool.not(KV.has(Unit, t, x))
    case UMems{SWAdd{Con{+x, rest}}} Some{KV.Item{KV.VColl{KV.CMems{KV.MInts{n, +xs}}}, e}}:
      Bool.not(KV.mems.ints.has(KV.ints.ok(x), x, xs))
    case _ _:
      False{}

# the key's value in the keyspace while an update takes it out: an empty
# string, which the change writes over
def upd.hole() -> KV.Val:
  KV.VStr{""}

# an Upd of k from the code c of k's entry and the entry there at now
# (lm): taken, the value leaves the keyspace before the change, which
# writes the new one in its place (PROOF.bend: db_upd_unfold)
def db.upd.go(take: Bool, t: KV.Trie<KV.Val>, +k: String, +h: U32, +n: Nat, +x: Nat, +now: Nat, rr: Maybe<&2, Db>, op: UpdOp, +c: Nat, lm: Maybe<&2, KV.Item<KV.Val>>) -> Reply & Db:
  match take:
    case True{}:
      u = KV.keep.at(KV.Val, t, k, upd.hole(), h)
      upd.put(u, k, h, n, x, now, rr, c, upd.v(op, now, lm))
    case False{}:
      upd.put(t, k, h, n, x, now, rr, c, upd.v(op, now, lm))

# an Upd of k: k's entry is read while the trie is lent, then the change
# is made where it lies. The entry's code is read before the entry is
# given to ent.live, so that the value the entry holds is held once.
def db.upd(db: Db, +k: String, op: UpdOp) -> Reply & Db:
  match db:
    case Db{+t, +n, +x, +now, rr}:
      +h = KV.hash(k)
      +m = KV.entry.at(KV.Val, t, k, h)
      +c = ent.code(m)
      +lm = ent.live(now, m)
      +o = op
      db.upd.go(upd.takes(o, lm), t, k, h, n, x, now, rr, o, c, lm)

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
      RSet{lbulks(sop.members(KInter{}, ks, ss))}
    case KUnion{}:
      RSet{lbulks(sop.members(KUnion{}, ks, ss))}
    case KDiff{}:
      RSet{lbulks(sop.members(KDiff{}, ks, ss))}

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
      KV.zset.all(z)
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
  KV.zt.drain(zres.put(xs, KV.ZTip{}), Nil{})

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
      zels.reply(zop.els(op, ss), zop.sc(op))

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
  zrs.of(db.read(x, s), q, d, x)

# ZMPOP: as LMPOP, from the first of the keys there at now: its elements
# popped (ZWPopN), answered with the key, each element as a pair of its
# member and its score, an array in both protocols
def zmpop.pairs(xs: List<&2, Reply>) -> List<&2, Reply>:
  match xs:
    case Con{RPair{ys}, rest}:
      RArray{ys} <> zmpop.pairs(rest)
    case _:
      Nil{}

def zmpop.reply(+k: String, r: Reply) -> Reply:
  match r:
    case RPairs{xs}:
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

# Sorting
# -------
# SORT and SORT_RO as Redis 7.0.15 runs them (sort.c). The elements of
# the list, set or sorted set at the key (a key not there: none, as Redis
# sorts an empty list for it; another kind: WRONGTYPE) are sorted by
# their own values or by the values a BY pattern names for each, as
# doubles (a value strtod reads to its end or to a NUL, past blanks, with
# no range error and no NaN; a value not there is 0; ties in the order of
# the elements' bytes) or with ALPHA as strings (bytes for a STORE; up to
# the first NUL else, as strcoll compares them in the C locale; with BY,
# a value not there first), DESC turning each comparison around. The sort
# is stable, as glibc's qsort is. A BY without a '*' leaves a list's and
# a sorted set's elements in their order (reversed for DESC) and a set's
# in its own (an intset's, increasing; a hashtable's, the trie's, which
# is not Redis's), but SORT with STORE sorts a set's elements with ALPHA
# then, as Redis does. LIMIT takes a range of the result, and each
# element of it answers itself or, with GETs, the values the patterns
# name ("#": the element; none not there, the empty string for a STORE).
# The patterns name values as lookupKeyByPattern does: the first '*'
# before the pattern's first NUL stands for the element, and "->" with a
# field after it (before the NUL) names that field of the hash at the key
# made of what comes before "->"; the key holds a string otherwise; no
# '*', or a key not there at now or of another kind, names none.

# the elements SORT sorts: a list's, a set's or a sorted set's, or
# WRONGTYPE
type SortSrc is Data:
  SrcList{xs: List<&2, String>}
  SrcSet{xs: List<&2, String>}
  SrcZset{xs: List<&2, String>}
  SrcWrong{}

def sort.members(xs: List<&2, KV.ZEl>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{KV.ZEl{m, d}, rest}:
      m <> sort.members(rest)

def sort.src(m: Maybe<&2, KV.Val>) -> SortSrc:
  match m:
    case None{}:
      SrcList{Nil{}}
    case Some{KV.VColl{KV.CList{+l}}}:
      SrcList{KV.deq.all(l)}
    case Some{KV.VColl{KV.CMems{+s}}}:
      SrcSet{KV.mems.all(s)}
    case Some{KV.VColl{KV.CZset{+z}}}:
      SrcZset{sort.members(KV.zset.all(z))}
    case Some{v}:
      SrcWrong{}

# whether "->" starts s
def sort.arrow.hit(+s: String) -> Bool:
  Bool.and(U32.is_eq(String.code_at(s, 0n), 45), U32.is_eq(String.code_at(s, 1n), 62))

# the index of the first "->" in s, plus k (hit: whether one starts s);
# k plus s's length when s holds none
def sort.arrow(s: String, +k: Nat, hit: Bool) -> Nat:
  match s hit:
    case _ True{}:
      k
    case SNil{} False{}:
      k
    case SCon{h, +t} False{}:
      sort.arrow(t, Nat.add(k, 1n), sort.arrow.hit(t))

# a pattern of BY or GET, read once for a SORT as lookupKeyByPattern
# reads it: "#" (up to its first NUL), which names the element itself; no
# '*' before its first NUL, which names nothing; or a key made of what
# comes before its first '*' (pre), the element, and what comes after it
# (post), up to "->" when a field follows that before the NUL, and then
# the field of the hash at that key (f)
type SPat is Data:
  PSelf{}
  PNone{}
  PKey{pre: String, post: String, f: Maybe<&2, String>}

# the pattern p with its '*' at index i and "->" at index a (field: a
# field follows it before p's first NUL)
def sort.pat.key(field: Bool, +p: String, +i: Nat, +a: Nat) -> SPat:
  match field:
    case True{}:
      PKey{String.take(p, i), String.slice(p, Nat.add(i, 1n), Nat.sub(Nat.sub(a, i), 1n)), Some{String.drop(p, Nat.add(a, 2n))}}
    case False{}:
      PKey{String.take(p, i), String.drop(p, Nat.add(i, 1n)), None{}}

# the pattern p, c being p up to its first NUL, with a '*' at index i of c
# (found: c holds one)
def sort.pat.star(found: Bool, +p: String, +c: String, +i: Nat) -> SPat:
  match found:
    case False{}:
      PNone{}
    case True{}:
      +r = String.drop(c, Nat.add(i, 1n))
      +a = Nat.add(Nat.add(i, 1n), sort.arrow(r, 0n, sort.arrow.hit(r)))
      sort.pat.key(Nat.is_lt(Nat.add(a, 2n), String.length(c)), p, i, a)

def sort.pat.of(self: Bool, +p: String, +c: String) -> SPat:
  match self:
    case True{}:
      PSelf{}
    case False{}:
      +i = String.find(c, '*', 0n)
      sort.pat.star(Nat.is_lt(i, String.length(c)), p, c, i)

def sort.pat(+p: String) -> SPat:
  +c = cstr(p)
  sort.pat.of(String.eq(c, "#"), p, c)

def sort.pats(gs: List<&2, String>) -> List<&2, SPat>:
  match gs:
    case Nil{}:
      Nil{}
    case Con{+g, rest}:
      sort.pat(g) <> sort.pats(rest)

# the value of a key a pattern names: a string, or the field f of a hash
def sort.val(m: Maybe<&2, KV.Val>, +f: Maybe<&2, String>) -> Maybe<&2, String>:
  match m f:
    case Some{KV.VStr{s}} None{}:
      Some{s}
    case Some{KV.VColl{KV.CHash{+h}}} Some{+x}:
      KV.hash.get(x, h)
    case _ _:
      None{}

# the value the pattern q names for element e at now
def sort.look(+t: KV.Trie<KV.Val>, +now: Nat, +q: SPat, +e: String) -> Maybe<&2, String>:
  match q:
    case PSelf{}:
      Some{e}
    case PNone{}:
      None{}
    case PKey{+pre, +post, +f}:
      sort.val(KV.read(KV.Val, t, pre ++ e ++ post, now), f)

# an element and what it sorts by: its score (a numeric sort), or the
# value ALPHA compares (none: not there)
type SEl is Data:
  SEl{e: String, d: F.F64, c: Maybe<&2, String>}

# a score: 0 for a value not there; none for a value that is no score
def sort.sc(+m: Maybe<&2, String>) -> Maybe<&2, F.F64>:
  match m:
    case None{}:
      Some{F.F64{0n, 0n}}
    case Some{+v}:
      F.f64.parse_sort(v)

# an element's score: by its own value (by: none), or by the value of the
# BY pattern
def sort.score(+t: KV.Trie<KV.Val>, +now: Nat, +by: Maybe<&2, SPat>, +e: String) -> Maybe<&2, F.F64>:
  match by:
    case None{}:
      F.f64.parse_sort(e)
    case Some{+q}:
      sort.sc(sort.look(t, now, q, e))

def sort.sc.bad(+m: Maybe<&2, F.F64>) -> Bool:
  Maybe.is_none(&2, F.F64, m)

def sort.sc.d(+m: Maybe<&2, F.F64>) -> F.F64:
  match m:
    case Some{+d}:
      d
    case None{}:
      F.F64{0n, 0n}

# the elements with their scores, or none when one is no score (bad: one
# before was not)
def sort.nums(xs: List<&2, String>, bad: Bool, +t: KV.Trie<KV.Val>, +now: Nat, +by: Maybe<&2, SPat>, acc: List<&2, SEl>) -> Maybe<&2, List<&2, SEl>>:
  match xs bad:
    case _ True{}:
      None{}
    case Nil{} False{}:
      Some{List.reverse(&2, SEl, acc)}
    case Con{+e, rest} False{}:
      +sc = sort.score(t, now, by, e)
      sort.nums(rest, sort.sc.bad(sc), t, now, by, SEl{e, sort.sc.d(sc), None{}} <> acc)

# a string up to its first NUL, at i (nul: the string holds one)
def sort.cut(nul: Bool, +s: String, +i: Nat) -> String:
  match nul:
    case True{}:
      String.take(s, i)
    case False{}:
      s

# what ALPHA compares of a string: all its bytes in a STORE (bin), as
# Redis compares them then, else those up to its first NUL, as strcoll
# compares them in the C locale
def sort.key(+bin: Bool, +s: String) -> String:
  match bin:
    case True{}:
      s
    case False{}:
      +i = String.find(s, Chr{0}, 0n)
      sort.cut(Nat.is_lt(i, String.length(s)), s, i)

def sort.key.m(+bin: Bool, +m: Maybe<&2, String>) -> Maybe<&2, String>:
  match m:
    case None{}:
      None{}
    case Some{+v}:
      Some{sort.key(bin, v)}

# the value ALPHA compares for element e: its own (by: none), or the one
# the BY pattern names
def sort.alpha.key(+t: KV.Trie<KV.Val>, +now: Nat, +bin: Bool, +by: Maybe<&2, SPat>, +e: String) -> Maybe<&2, String>:
  match by:
    case None{}:
      Some{sort.key(bin, e)}
    case Some{+q}:
      sort.key.m(bin, sort.look(t, now, q, e))

# the elements with the values ALPHA compares, each read once
def sort.alphas(xs: List<&2, String>, +bin: Bool, +t: KV.Trie<KV.Val>, +now: Nat, +by: Maybe<&2, SPat>) -> List<&2, SEl>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{+e, rest}:
      SEl{e, F.F64{0n, 0n}, sort.alpha.key(t, now, bin, by, e)} <> sort.alphas(rest, bin, t, now, by)

def sort.elems(xs: List<&2, SEl>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{SEl{e, d, c}, rest}:
      e <> sort.elems(rest)

# two values ALPHA compares: one not there first, else by their bytes
def sort.obj.cmp(+a: Maybe<&2, String>, +b: Maybe<&2, String>) -> Cmp:
  match a b:
    case None{} None{}:
      EQ{}
    case None{} Some{+y}:
      LT{}
    case Some{+x} None{}:
      GT{}
    case Some{+x} Some{+y}:
      String.order(x, y)

# equal scores: the elements' bytes
def sort.tie(c: Cmp, +a: String, +b: String) -> Cmp:
  match c:
    case LT{}:
      LT{}
    case EQ{}:
      String.order(a, b)
    case GT{}:
      GT{}

# how two elements compare: by their scores, or (alpha) by the values
# ALPHA compares
def sort.cmp(+alpha: Bool, +x: SEl, +y: SEl) -> Cmp:
  match alpha x y:
    case False{} SEl{+a, +da, +ca} SEl{+b, +db, +cb}:
      sort.tie(F.f64.cmp(da, db), a, b)
    case True{} SEl{+a, +da, +ca} SEl{+b, +db, +cb}:
      sort.obj.cmp(ca, cb)

def sort.le.of(+desc: Bool, c: Cmp) -> Bool:
  match c:
    case LT{}:
      Bool.not(desc)
    case EQ{}:
      True{}
    case GT{}:
      desc

# whether x goes no later than y (DESC turns the comparison around)
def sort.le(+alpha: Bool, +desc: Bool, +x: SEl, +y: SEl) -> Bool:
  sort.le.of(desc, sort.cmp(alpha, x, y))

# whether the first of xs goes no later than y (none: it does)
def sort.le.l(+alpha: Bool, +desc: Bool, +xs: List<&2, SEl>, +y: SEl) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case Con{+x, +r}:
      sort.le(alpha, desc, x, y)

# whether x goes no later than the first of ys (none: it does)
def sort.le.r(+alpha: Bool, +desc: Bool, +x: SEl, +ys: List<&2, SEl>) -> Bool:
  match ys:
    case Nil{}:
      True{}
    case Con{+y, +r}:
      sort.le(alpha, desc, x, y)

def sort.le.ab(+alpha: Bool, +desc: Bool, +xs: List<&2, SEl>, +ys: List<&2, SEl>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case Con{+x, +r}:
      sort.le.r(alpha, desc, x, ys)

# xs and ys, each in order, merged in order after acc (reversed), the
# first of xs before the first of ys when le: when the two compare equal,
# so that the sort is stable; fuel bounds the steps (the number of
# elements sorted, which no merge passes)
def sort.merge(fuel: Nat, xs: List<&2, SEl>, ys: List<&2, SEl>, le: Bool, +alpha: Bool, +desc: Bool, acc: List<&2, SEl>) -> List<&2, SEl>:
  match fuel xs ys le:
    case 0n a b _:
      List.reverse.go(&2, SEl, acc, List.append(&2, SEl, a, b))
    case _ Nil{} b _:
      List.reverse.go(&2, SEl, acc, b)
    case _ a Nil{} _:
      List.reverse.go(&2, SEl, acc, a)
    case 1n+f Con{x, +xt} Con{+y, +yt} True{}:
      sort.merge(f, xt, Con{y, yt}, sort.le.l(alpha, desc, xt, y), alpha, desc, x <> acc)
    case 1n+f Con{+x, +xt} Con{y, +yt} False{}:
      sort.merge(f, Con{x, xt}, yt, sort.le.r(alpha, desc, x, yt), alpha, desc, y <> acc)

# the elements, each a run of its own, and how many there are
type SRuns is Data:
  SRuns{n: Nat, rs: List<&2, List<&2, SEl>>}

def sort.runs.con(x: SEl, r: SRuns) -> SRuns:
  match r:
    case SRuns{n, rs}:
      SRuns{Nat.add(n, 1n), [x] <> rs}

def sort.runs(xs: List<&2, SEl>) -> SRuns:
  match xs:
    case Nil{}:
      SRuns{0n, Nil{}}
    case Con{x, rest}:
      sort.runs.con(x, sort.runs(rest))

def sort.two(+n: Nat, +alpha: Bool, +desc: Bool, +a: List<&2, SEl>, +b: List<&2, SEl>) -> List<&2, SEl>:
  sort.merge(n, a, b, sort.le.ab(alpha, desc, a, b), alpha, desc, Nil{})

# the runs merged two by two, in order (n: how many elements they hold)
def sort.pass(rs: List<&2, List<&2, SEl>>, +n: Nat, +alpha: Bool, +desc: Bool) -> List<&2, List<&2, SEl>>:
  match rs:
    case Con{+a, Con{+b, rest}}:
      sort.two(n, alpha, desc, a, b) <> sort.pass(rest, n, alpha, desc)
    case other:
      other

# the runs merged pass after pass until one is left (a stable merge
# sort); fuel bounds the passes
def sort.passes(fuel: Nat, rs: List<&2, List<&2, SEl>>, +n: Nat, +alpha: Bool, +desc: Bool) -> List<&2, SEl>:
  match fuel rs:
    case _ Nil{}:
      Nil{}
    case _ Con{r, Nil{}}:
      r
    case 0n other:
      List.concat(&2, SEl, other)
    case 1n+f other:
      sort.passes(f, sort.pass(other, n, alpha, desc), n, alpha, desc)

def sort.sorted.of(r: SRuns, +alpha: Bool, +desc: Bool) -> List<&2, String>:
  match r:
    case SRuns{+n, rs}:
      sort.elems(sort.passes(n, rs, n, alpha, desc))

def sort.sorted(xs: List<&2, SEl>, +alpha: Bool, +desc: Bool) -> List<&2, String>:
  sort.sorted.of(sort.runs(xs), alpha, desc)

# the elements in the order SORT leaves them: none when a value is no
# score. by: the BY pattern (none: the elements themselves)
def sort.num(m: Maybe<&2, List<&2, SEl>>, +desc: Bool) -> Maybe<&2, List<&2, String>>:
  match m:
    case Some{xs}:
      Some{sort.sorted(xs, False{}, desc)}
    case None{}:
      None{}

def sort.order(alpha: Bool, +by: Maybe<&2, SPat>, xs: List<&2, String>, +t: KV.Trie<KV.Val>, +now: Nat, +desc: Bool, +bin: Bool) -> Maybe<&2, List<&2, String>>:
  match alpha:
    case False{}:
      sort.num(sort.nums(xs, False{}, t, now, by, Nil{}), desc)
    case True{}:
      Some{sort.sorted(sort.alphas(xs, bin, t, now, by), True{}, desc)}

# the elements left in their order: a list's and a sorted set's reversed
# for DESC, a set's as they are
def sort.kept.of(rev: Bool, xs: List<&2, String>) -> List<&2, String>:
  match rev:
    case True{}:
      List.reverse(&2, String, xs)
    case False{}:
      xs

def sort.kept(+src: Nat, +desc: Bool, xs: List<&2, String>) -> List<&2, String>:
  sort.kept.of(Bool.and(desc, Nat.is_ne(src, 1n)), xs)

# LIMIT's range among n elements: its start, and how many it takes
def sort.start(+off: Int, +n: Nat) -> Nat:
  match off:
    case IPos{+x}:
      Nat.min(x, n)
    case INeg{x}:
      0n

def sort.count(+cnt: Int, +n: Nat, +s: Nat) -> Nat:
  match cnt:
    case IPos{+x}:
      Nat.min(x, Nat.sub(n, s))
    case INeg{x}:
      Nat.sub(n, s)

def sort.range(+off: Int, +cnt: Int, xs: List<&2, String>) -> List<&2, String>:
  +ys = xs
  +n = List.length(&2, String, ys)
  +s = sort.start(off, n)
  List.take(&2, String, List.drop(&2, String, ys, s), sort.count(cnt, n, s))

# the values GET's patterns name for each element, in turn (no GET: the
# elements), after acc (reversed)
def sort.gets.of(+t: KV.Trie<KV.Val>, +now: Nat, +qs: List<&2, SPat>, +e: String, acc: List<&2, Maybe<&2, String>>) -> List<&2, Maybe<&2, String>>:
  match qs:
    case Nil{}:
      acc
    case Con{+q, +rest}:
      sort.gets.of(t, now, rest, e, sort.look(t, now, q, e) <> acc)

def sort.gets(+t: KV.Trie<KV.Val>, +now: Nat, +qs: List<&2, SPat>, xs: List<&2, String>, acc: List<&2, Maybe<&2, String>>) -> List<&2, Maybe<&2, String>>:
  match xs:
    case Nil{}:
      List.reverse(&2, Maybe<&2, String>, acc)
    case Con{+e, rest}:
      sort.gets(t, now, qs, rest, sort.gets.of(t, now, qs, e, acc))

def sort.selves(xs: List<&2, String>) -> List<&2, Maybe<&2, String>>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{e, rest}:
      Some{e} <> sort.selves(rest)

def sort.out(+t: KV.Trie<KV.Val>, +now: Nat, gs: List<&2, String>, xs: List<&2, String>) -> List<&2, Maybe<&2, String>>:
  match gs:
    case Nil{}:
      sort.selves(xs)
    case Con{g, rest}:
      sort.gets(t, now, sort.pats(Con{g, rest}), xs, Nil{})

# SORT's result: the values it answers (none: not there), or WRONGTYPE,
# or a value that is no score
type SortOut is Data:
  SortOut{xs: List<&2, Maybe<&2, String>>}
  SortWrong{}
  SortBad{}

def sort.fin(m: Maybe<&2, List<&2, String>>, +off: Int, +cnt: Int, gs: List<&2, String>, +t: KV.Trie<KV.Val>, +now: Nat) -> SortOut:
  match m:
    case Some{xs}:
      SortOut{sort.out(t, now, gs, sort.range(off, cnt, xs))}
    case None{}:
      SortBad{}

# the elements of src (0 a list, 1 a set, 2 a sorted set) sorted as by
# says (none: left in their order)
def sort.all(by: SortBy, +src: Nat, +alpha: Bool, xs: List<&2, String>, +t: KV.Trie<KV.Val>, +now: Nat, +desc: Bool, +bin: Bool) -> Maybe<&2, List<&2, String>>:
  match by:
    case SByNone{}:
      Some{sort.kept(src, desc, xs)}
    case SByElem{}:
      sort.order(alpha, None{}, xs, t, now, desc, bin)
    case SByPat{+p}:
      sort.order(alpha, Some{sort.pat(p)}, xs, t, now, desc, bin)

# a set left in its order by a STORE is sorted with ALPHA, as Redis sorts
# it so that a replica stores what it stores
def sort.by.of(+src: Nat, +store: Bool, by: SortBy) -> SortBy:
  match by:
    case SByNone{}:
      Bool.pick(SortBy, Bool.and(store, Nat.is_eq(src, 1n)), SByElem{}, SByNone{})
    case SByElem{}:
      SByElem{}
    case SByPat{p}:
      SByPat{p}

def sort.alpha.of(+src: Nat, +store: Bool, +by: SortBy, +alpha: Bool) -> Bool:
  match by:
    case SByNone{}:
      Bool.or(alpha, Bool.and(store, Nat.is_eq(src, 1n)))
    case _:
      alpha

def sort.go.src(+src: Nat, xs: List<&2, String>, o: SortO, +t: KV.Trie<KV.Val>, +now: Nat, +store: Bool) -> SortOut:
  match o:
    case SortO{+by, +off, +cnt, gs, +desc, +alpha}:
      sort.fin(sort.all(sort.by.of(src, store, by), src, sort.alpha.of(src, store, by, alpha), xs, t, now, desc, store), off, cnt, gs, t, now)
    case SortStore{d, x}:
      sort.go.src(src, xs, x, t, now, store)

def sort.run.of(s: SortSrc, o: SortO, +t: KV.Trie<KV.Val>, +now: Nat, +store: Bool) -> SortOut:
  match s:
    case SrcList{xs}:
      sort.go.src(0n, xs, o, t, now, store)
    case SrcSet{xs}:
      sort.go.src(1n, xs, o, t, now, store)
    case SrcZset{xs}:
      sort.go.src(2n, xs, o, t, now, store)
    case SrcWrong{}:
      SortWrong{}

# SORT of the key k at now with the options o (store: for a STORE)
def sort.run(+t: KV.Trie<KV.Val>, +now: Nat, +k: String, o: SortO, +store: Bool) -> SortOut:
  sort.run.of(sort.src(KV.read(KV.Val, t, k, now)), o, t, now, store)

def e_score() -> Reply:
  RError{"ERR One or more scores can't be converted into double"}

# SORT's reply: an array of its values (one not there: a null)
def sort.bulks(xs: List<&2, Maybe<&2, String>>) -> List<&2, Reply>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{m, rest}:
      r_get(m) <> sort.bulks(rest)

def sort.reply(o: SortOut) -> Reply:
  match o:
    case SortOut{xs}:
      RArray{sort.bulks(xs)}
    case SortWrong{}:
      e_wrongtype()
    case SortBad{}:
      e_score()

# the values a STORE pushes, one not there as the empty string
def sort.strs(xs: List<&2, Maybe<&2, String>>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{m, rest}:
      Maybe.default(&2, String, m, "") <> sort.strs(rest)

# SORT with STORE: the command that writes its destination d (session.bend
# runs it as an act of its database, ASort, below): the DEL of d when the
# sort leaves no value, else the list of them where d was, whatever it
# held (LWNew), which drops d's time to live as Redis's setKey does; an
# error writes nothing (Bad)
def sort.write.of(o: SortOut, +d: String) -> Cmd:
  match o:
    case SortOut{Nil{}}:
      Del{[d]}
    case SortOut{Con{x, rest}}:
      Upd{d, UList{LWNew{False{}, sort.strs(Con{x, rest})}}}
    case SortWrong{}:
      Bad{e_wrongtype()}
    case SortBad{}:
      Bad{e_score()}

def sort.write(+t: KV.Trie<KV.Val>, +now: Nat, +k: String, o: SortO) -> Cmd:
  match o:
    case SortStore{+d, x}:
      sort.write.of(sort.run(t, now, k, x, True{}), d)
    case SortO{by, off, cnt, gs, desc, alpha}:
      Bad{RError{"ERR syntax error"}}

# SORT with STORE's reply: how many values it stored
def sort.stored(o: SortOut) -> Reply:
  match o:
    case SortOut{+xs}:
      r_int(List.length(&2, Maybe<&2, String>, xs))
    case SortWrong{}:
      e_wrongtype()
    case SortBad{}:
      e_score()

def sort.store.reply(+t: KV.Trie<KV.Val>, +now: Nat, +k: String, o: SortO) -> Reply:
  match o:
    case SortStore{d, x}:
      sort.stored(sort.run(t, now, k, x, True{}))
    case SortO{by, off, cnt, gs, desc, alpha}:
      RError{"ERR syntax error"}

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
    case Sort{+k, o}:
      +d = db
      (sort.reply(sort.run(db.trie(d), db.now(d), k, o, False{})), d)

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

# k's entry in the focus, there at now or not
def ds.entry(+ds: Ds, +k: String) -> Maybe<&2, KV.Item<KV.Val>>:
  match ds:
    case Ds{+d, pre, post}:
      db.entry(d, k)

# k's entry in the j-th of xs, there at now or not; none when xs has
# fewer
def dbs.entry(j: Nat, +k: String, +xs: List<&2, Db>) -> Maybe<&2, KV.Item<KV.Val>>:
  match j xs:
    case 0n Con{+x, rest}:
      db.entry(x, k)
    case 1n+i Con{x, +rest}:
      dbs.entry(i, k, rest)
    case _ Nil{}:
      None{}

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
# (FLUSHALL); SORT with STORE, which writes what it makes of the keys of
# the focus to its destination there (sort.write); PFMERGE, which writes
# the union of its keys to its destination (pf.merge.cmd); a GEO search
# that stores, which writes what it finds to its destination (geo.write)
type Act is Data:
  ARun{c: Cmd}
  AFocus{db: Nat}
  ASwap{a: Nat, b: Nat}
  APurge{key: String, db: Nat}
  AMove{key: String, db: Nat}
  ACopy{src: String, dst: String, db: Nat, rep: Bool}
  ACopyHere{src: String, dst: String, rep: Bool}
  AWipe{}
  ASort{key: String, o: SortO}
  APfMerge{dst: String, srcs: List<&2, String>}
  AGeo{kind: Nat, args: List<&2, String>}

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

# a command of one database run on the focus
def act.cmd(c: Cmd, ds: Ds) -> Reply & Ds:
  match ds:
    case Ds{d, pre, post}:
      act.run(exec(c, d), pre, post)

# SORT with STORE's command (sort.write) on the focus
def sort.write.ds(+ds: Ds, +k: String, o: SortO) -> Cmd:
  +d = ds.focused(ds)
  sort.write(db.trie(d), db.now(d), k, o)

# PFMERGE's command (pf.merge.cmd) on the focus
def pf.merge.ds(+ds: Ds, +dst: String, srcs: List<&2, String>) -> Cmd:
  +d = ds.focused(ds)
  pf.merge.cmd(db.trie(d), db.now(d), dst, srcs)

# a GEO store's source: GEOSEARCHSTORE's second key, the others' first
def geo.src(+kind: Nat, args: List<&2, String>) -> String:
  match kind args:
    case 5n Con{nm, Con{d, Con{k, rest}}}:
      k
    case _ Con{nm, Con{k, rest}}:
      k
    case _ _:
      ""

def geo.on(m: Maybe<&2, KV.Val>, +kind: Nat, args: List<&2, String>) -> GFound:
  match m:
    case None{}:
      geo.found(kind, args, None{})
    case Some{KV.VColl{KV.CZset{+z}}}:
      geo.found(kind, args, Some{z})
    case Some{v}:
      GFErr{e_wrongtype()}

# what a GEO store finds at now in the trie t: its source looked up first
# (WRONGTYPE for a key of another kind), then its search
def geo.store.found(+t: KV.Trie<KV.Val>, +now: Nat, +kind: Nat, +args: List<&2, String>) -> GFound:
  geo.on(KV.read(KV.Val, t, geo.src(kind, args), now), kind, args)

# a GEO store's reply (session.bend), on the database in focus as it is
# before the act that writes (AGeo)
def geo.store.reply(+d: Db, +kind: Nat, args: List<&2, String>) -> Reply:
  geo.stored(geo.store.found(db.trie(d), db.now(d), kind, args))

# a GEO store's command (geo.write) on the focus
def geo.store.ds(+ds: Ds, +kind: Nat, args: List<&2, String>) -> Cmd:
  +d = ds.focused(ds)
  geo.write(geo.store.found(db.trie(d), db.now(d), kind, args))

# an act's reply, and the databases after it (SORT with STORE, PFMERGE
# and a GEO store run the command they make, so each acts as ARun of that
# command does)
def act(a: Act, ds: Ds) -> Reply & Ds:
  match a ds:
    case ARun{c} x:
      act.cmd(c, x)
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
    case ASort{+k, o} x:
      +y = x
      act.cmd(sort.write.ds(y, k, o), y)
    case APfMerge{+d, srcs} x:
      +y = x
      act.cmd(pf.merge.ds(y, d, srcs), y)
    case AGeo{+k, args} x:
      +y = x
      act.cmd(geo.store.ds(y, k, args), y)

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
