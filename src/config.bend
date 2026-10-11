# config.bend: the server's parameters, and CONFIG GET and CONFIG SET as
# Redis 7.0.15 has them. The table (written by tools/gen_config.py from
# Redis's own) has every parameter Redis knows, with its type, bounds,
# flags and the value the server starts with. CONFIG SET checks a value as
# Redis checks it, keeps it in the form CONFIG GET gives back, and sets
# all the parameters of a command or none of them.
#
# BendKV acts on few of them: requirepass is the password (session.bend),
# hz is capped as Redis caps it, and the port, the addresses, TLS and the
# append-only file cannot change while the server runs, so a new value for
# them fails as it fails in Redis when Redis cannot apply it. The others
# are kept and read back, and tune nothing: BendKV has no eviction, no
# replication and no encodings for them to tune.

import Base
import ./redis.bend as R

# Types
# -----

# how a number reads: an integer (as Redis's string2ll reads one), a
# memory value (digits and a unit: b, k, kb, m, mb, g or gb), a memory
# value or a percent (digits and '%'), or octal digits
type NumFmt is Data:
  NPlain{}
  NMem{}
  NMemPct{}
  NOct{}

# a check a value must pass besides its type
type Vet is Data:
  VNone{}
  VFile{}
  VAofFile{}
  VAofDir{}
  VHost{}
  VTitle{}
  VSig{}
  VDefrag{}

# the parameters that have a syntax of their own
type XSpec is Data:
  XDir{}
  XSave{}
  XObuf{}
  XOom{}
  XNotify{}
  XBind{}
  XReplicaof{}
  XPct{}

# a parameter's type: yes or no; one of some names (or several, as bit
# flags); a number between lo and hi (decimal strings: a number reaches
# 2^64-1, past what a Nat holds in the runtime); a string; or one of the
# parameters above
type CTy is Data:
  CBool{vet: Vet}
  CEnum{names: List<&2, String>, vals: List<&2, U32>, bits: Bool, vet: Vet}
  CNum{signed: Bool, lo: String, hi: String, fmt: NumFmt}
  CStr{null: Bool, vet: Vet}
  CSpec{x: XSpec}

# what a new value does in BendKV: nothing more; hz is capped to 1..500;
# a value below min is raised to it (repl-backlog-size); requirepass is
# the password; or it cannot change, and msg is the error
type CApp is Data:
  AppNone{}
  AppHz{}
  AppMin{min: String}
  AppPass{}
  AppFixed{msg: String}

# a parameter: its name, its other name (empty for none), whether it
# cannot change while the server runs, whether a pattern skips it, whether
# it is protected (enable-protected-configs), whether its value is words,
# its type and what a new value does
type CParam is Data:
  CParam{name: String, alias: String, imm: Bool, hidden: Bool, prot: Bool, multi: Bool, ty: CTy, app: CApp}

# a parameter and its value, in the form CONFIG GET gives it
type CItem is Data:
  CItem{p: CParam, v: String}

# BEGIN gen_config: table
# every parameter of Redis 7.0.15 (built with TLS, as distributions build it), in the order of
# Redis's table, each with its value when the server starts (written by
# tools/gen_config.py from tools/data/redis-configs.json)
def config.table() -> List<&2, CItem>:
  [
    CItem{CParam{"rdbchecksum", "", True{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "yes"},
    CItem{CParam{"daemonize", "", True{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "no"},
    CItem{CParam{"io-threads-do-reads", "", True{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "no"},
    CItem{CParam{"always-show-logo", "", True{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "no"},
    CItem{CParam{"protected-mode", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "yes"},
    CItem{CParam{"rdbcompression", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "yes"},
    CItem{CParam{"rdb-del-sync-files", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "no"},
    CItem{CParam{"activerehashing", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "yes"},
    CItem{CParam{"stop-writes-on-bgsave-error", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "yes"},
    CItem{CParam{"set-proc-title", "", True{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "yes"},
    CItem{CParam{"dynamic-hz", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "yes"},
    CItem{CParam{"lazyfree-lazy-eviction", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "no"},
    CItem{CParam{"lazyfree-lazy-expire", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "no"},
    CItem{CParam{"lazyfree-lazy-server-del", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "no"},
    CItem{CParam{"lazyfree-lazy-user-del", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "no"},
    CItem{CParam{"lazyfree-lazy-user-flush", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "no"},
    CItem{CParam{"repl-disable-tcp-nodelay", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "no"},
    CItem{CParam{"repl-diskless-sync", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "yes"},
    CItem{CParam{"aof-rewrite-incremental-fsync", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "yes"},
    CItem{CParam{"no-appendfsync-on-rewrite", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "no"},
    CItem{CParam{"cluster-require-full-coverage", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "yes"},
    CItem{CParam{"rdb-save-incremental-fsync", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "yes"},
    CItem{CParam{"aof-load-truncated", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "yes"},
    CItem{CParam{"aof-use-rdb-preamble", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "yes"},
    CItem{CParam{"aof-timestamp-enabled", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "no"},
    CItem{CParam{"cluster-replica-no-failover", "cluster-slave-no-failover", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "no"},
    CItem{CParam{"replica-lazy-flush", "slave-lazy-flush", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "no"},
    CItem{CParam{"replica-serve-stale-data", "slave-serve-stale-data", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "yes"},
    CItem{CParam{"replica-read-only", "slave-read-only", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "yes"},
    CItem{CParam{"replica-ignore-maxmemory", "slave-ignore-maxmemory", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "yes"},
    CItem{CParam{"jemalloc-bg-thread", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "yes"},
    CItem{CParam{"activedefrag", "", False{}, False{}, False{}, False{}, CBool{VDefrag{}}, AppNone{}}, "no"},
    CItem{CParam{"syslog-enabled", "", True{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "no"},
    CItem{CParam{"cluster-enabled", "", True{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "no"},
    CItem{CParam{"appendonly", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppFixed{"Unable to turn on AOF. Check server logs."}}, "no"},
    CItem{CParam{"cluster-allow-reads-when-down", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "no"},
    CItem{CParam{"cluster-allow-pubsubshard-when-down", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "yes"},
    CItem{CParam{"crash-log-enabled", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "yes"},
    CItem{CParam{"crash-memcheck-enabled", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "yes"},
    CItem{CParam{"use-exit-on-panic", "", False{}, True{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "no"},
    CItem{CParam{"disable-thp", "", True{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "yes"},
    CItem{CParam{"cluster-allow-replica-migration", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "yes"},
    CItem{CParam{"replica-announced", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "yes"},
    CItem{CParam{"latency-tracking", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "yes"},
    CItem{CParam{"aof-disable-auto-gc", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "no"},
    CItem{CParam{"replica-ignore-disk-write-errors", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "no"},
    CItem{CParam{"aclfile", "", True{}, False{}, False{}, False{}, CStr{False{}, VNone{}}, AppNone{}}, ""},
    CItem{CParam{"unixsocket", "", True{}, False{}, False{}, False{}, CStr{True{}, VNone{}}, AppNone{}}, ""},
    CItem{CParam{"pidfile", "", True{}, False{}, False{}, False{}, CStr{True{}, VNone{}}, AppNone{}}, ""},
    CItem{CParam{"replica-announce-ip", "slave-announce-ip", False{}, False{}, False{}, False{}, CStr{True{}, VNone{}}, AppNone{}}, ""},
    CItem{CParam{"masteruser", "", False{}, False{}, False{}, False{}, CStr{True{}, VNone{}}, AppNone{}}, ""},
    CItem{CParam{"cluster-announce-ip", "", False{}, False{}, False{}, False{}, CStr{True{}, VNone{}}, AppNone{}}, ""},
    CItem{CParam{"cluster-config-file", "", True{}, False{}, False{}, False{}, CStr{False{}, VNone{}}, AppNone{}}, "nodes.conf"},
    CItem{CParam{"cluster-announce-hostname", "", False{}, False{}, False{}, False{}, CStr{True{}, VHost{}}, AppNone{}}, ""},
    CItem{CParam{"syslog-ident", "", True{}, False{}, False{}, False{}, CStr{False{}, VNone{}}, AppNone{}}, "redis"},
    CItem{CParam{"dbfilename", "", False{}, False{}, True{}, False{}, CStr{False{}, VFile{}}, AppNone{}}, "dump.rdb"},
    CItem{CParam{"appendfilename", "", True{}, False{}, False{}, False{}, CStr{False{}, VAofFile{}}, AppNone{}}, "appendonly.aof"},
    CItem{CParam{"appenddirname", "", True{}, False{}, False{}, False{}, CStr{False{}, VAofDir{}}, AppNone{}}, "appendonlydir"},
    CItem{CParam{"server_cpulist", "", True{}, False{}, False{}, False{}, CStr{True{}, VNone{}}, AppNone{}}, ""},
    CItem{CParam{"bio_cpulist", "", True{}, False{}, False{}, False{}, CStr{True{}, VNone{}}, AppNone{}}, ""},
    CItem{CParam{"aof_rewrite_cpulist", "", True{}, False{}, False{}, False{}, CStr{True{}, VNone{}}, AppNone{}}, ""},
    CItem{CParam{"bgsave_cpulist", "", True{}, False{}, False{}, False{}, CStr{True{}, VNone{}}, AppNone{}}, ""},
    CItem{CParam{"ignore-warnings", "", False{}, False{}, False{}, False{}, CStr{False{}, VNone{}}, AppNone{}}, ""},
    CItem{CParam{"proc-title-template", "", False{}, False{}, False{}, False{}, CStr{False{}, VTitle{}}, AppNone{}}, "{title} {listen-addr} {server-mode}"},
    CItem{CParam{"bind-source-addr", "", False{}, False{}, False{}, False{}, CStr{True{}, VNone{}}, AppNone{}}, ""},
    CItem{CParam{"logfile", "", True{}, False{}, False{}, False{}, CStr{False{}, VNone{}}, AppNone{}}, ""},
    CItem{CParam{"masterauth", "", False{}, False{}, False{}, False{}, CStr{True{}, VNone{}}, AppNone{}}, ""},
    CItem{CParam{"requirepass", "", False{}, False{}, False{}, False{}, CStr{True{}, VNone{}}, AppPass{}}, ""},
    CItem{CParam{"supervised", "", True{}, False{}, False{}, False{}, CEnum{["upstart", "systemd", "auto", "no"], [3, 2, 1, 0], False{}, VNone{}}, AppNone{}}, "no"},
    CItem{CParam{"syslog-facility", "", True{}, False{}, False{}, False{}, CEnum{["user", "local0", "local1", "local2", "local3", "local4", "local5", "local6", "local7"], [8, 128, 136, 144, 152, 160, 168, 176, 184], False{}, VNone{}}, AppNone{}}, "local0"},
    CItem{CParam{"repl-diskless-load", "", False{}, False{}, False{}, False{}, CEnum{["disabled", "on-empty-db", "swapdb"], [0, 1, 2], False{}, VNone{}}, AppNone{}}, "disabled"},
    CItem{CParam{"loglevel", "", False{}, False{}, False{}, False{}, CEnum{["debug", "verbose", "notice", "warning"], [0, 1, 2, 3], False{}, VNone{}}, AppNone{}}, "notice"},
    CItem{CParam{"maxmemory-policy", "", False{}, False{}, False{}, False{}, CEnum{["volatile-lru", "volatile-lfu", "volatile-random", "volatile-ttl", "allkeys-lru", "allkeys-lfu", "allkeys-random", "noeviction"], [1, 258, 768, 512, 1029, 1286, 1540, 1792], False{}, VNone{}}, AppNone{}}, "noeviction"},
    CItem{CParam{"appendfsync", "", False{}, False{}, False{}, False{}, CEnum{["everysec", "always", "no"], [2, 1, 0], False{}, VNone{}}, AppNone{}}, "everysec"},
    CItem{CParam{"oom-score-adj", "", False{}, False{}, False{}, False{}, CEnum{["no", "yes", "relative", "absolute"], [0, 1, 1, 2], False{}, VNone{}}, AppNone{}}, "no"},
    CItem{CParam{"acl-pubsub-default", "", False{}, False{}, False{}, False{}, CEnum{["allchannels", "resetchannels"], [8, 0], False{}, VNone{}}, AppNone{}}, "resetchannels"},
    CItem{CParam{"sanitize-dump-payload", "", False{}, False{}, False{}, False{}, CEnum{["no", "yes", "clients"], [0, 1, 2], False{}, VNone{}}, AppNone{}}, "no"},
    CItem{CParam{"enable-protected-configs", "", True{}, False{}, False{}, False{}, CEnum{["no", "yes", "local"], [0, 1, 2], False{}, VNone{}}, AppNone{}}, "no"},
    CItem{CParam{"enable-debug-command", "", True{}, False{}, False{}, False{}, CEnum{["no", "yes", "local"], [0, 1, 2], False{}, VNone{}}, AppNone{}}, "no"},
    CItem{CParam{"enable-module-command", "", True{}, False{}, False{}, False{}, CEnum{["no", "yes", "local"], [0, 1, 2], False{}, VNone{}}, AppNone{}}, "no"},
    CItem{CParam{"cluster-preferred-endpoint-type", "", False{}, False{}, False{}, False{}, CEnum{["ip", "hostname", "unknown-endpoint"], [0, 1, 2], False{}, VNone{}}, AppNone{}}, "ip"},
    CItem{CParam{"propagation-error-behavior", "", False{}, False{}, False{}, False{}, CEnum{["ignore", "panic", "panic-on-replicas"], [0, 1, 2], False{}, VNone{}}, AppNone{}}, "ignore"},
    CItem{CParam{"shutdown-on-sigint", "", False{}, False{}, False{}, True{}, CEnum{["default", "save", "nosave", "now", "force"], [0, 1, 2, 4, 8], True{}, VSig{}}, AppNone{}}, "default"},
    CItem{CParam{"shutdown-on-sigterm", "", False{}, False{}, False{}, True{}, CEnum{["default", "save", "nosave", "now", "force"], [0, 1, 2, 4, 8], True{}, VSig{}}, AppNone{}}, "default"},
    CItem{CParam{"databases", "", True{}, False{}, False{}, False{}, CNum{True{}, "1", "2147483647", NPlain{}}, AppNone{}}, "1"},
    CItem{CParam{"port", "", False{}, False{}, False{}, False{}, CNum{True{}, "0", "65535", NPlain{}}, AppFixed{"Unable to listen on this port. Check server logs."}}, "6379"},
    CItem{CParam{"io-threads", "", True{}, False{}, False{}, False{}, CNum{True{}, "1", "128", NPlain{}}, AppNone{}}, "1"},
    CItem{CParam{"auto-aof-rewrite-percentage", "", False{}, False{}, False{}, False{}, CNum{True{}, "0", "2147483647", NPlain{}}, AppNone{}}, "100"},
    CItem{CParam{"cluster-replica-validity-factor", "cluster-slave-validity-factor", False{}, False{}, False{}, False{}, CNum{True{}, "0", "2147483647", NPlain{}}, AppNone{}}, "10"},
    CItem{CParam{"list-max-listpack-size", "list-max-ziplist-size", False{}, False{}, False{}, False{}, CNum{True{}, "-2147483648", "2147483647", NPlain{}}, AppNone{}}, "-2"},
    CItem{CParam{"tcp-keepalive", "", False{}, False{}, False{}, False{}, CNum{True{}, "0", "2147483647", NPlain{}}, AppNone{}}, "300"},
    CItem{CParam{"cluster-migration-barrier", "", False{}, False{}, False{}, False{}, CNum{True{}, "0", "2147483647", NPlain{}}, AppNone{}}, "1"},
    CItem{CParam{"active-defrag-cycle-min", "", False{}, False{}, False{}, False{}, CNum{True{}, "1", "99", NPlain{}}, AppNone{}}, "1"},
    CItem{CParam{"active-defrag-cycle-max", "", False{}, False{}, False{}, False{}, CNum{True{}, "1", "99", NPlain{}}, AppNone{}}, "25"},
    CItem{CParam{"active-defrag-threshold-lower", "", False{}, False{}, False{}, False{}, CNum{True{}, "0", "1000", NPlain{}}, AppNone{}}, "10"},
    CItem{CParam{"active-defrag-threshold-upper", "", False{}, False{}, False{}, False{}, CNum{True{}, "0", "1000", NPlain{}}, AppNone{}}, "100"},
    CItem{CParam{"lfu-log-factor", "", False{}, False{}, False{}, False{}, CNum{True{}, "0", "2147483647", NPlain{}}, AppNone{}}, "10"},
    CItem{CParam{"lfu-decay-time", "", False{}, False{}, False{}, False{}, CNum{True{}, "0", "2147483647", NPlain{}}, AppNone{}}, "1"},
    CItem{CParam{"replica-priority", "slave-priority", False{}, False{}, False{}, False{}, CNum{True{}, "0", "2147483647", NPlain{}}, AppNone{}}, "100"},
    CItem{CParam{"repl-diskless-sync-delay", "", False{}, False{}, False{}, False{}, CNum{True{}, "0", "2147483647", NPlain{}}, AppNone{}}, "5"},
    CItem{CParam{"maxmemory-samples", "", False{}, False{}, False{}, False{}, CNum{True{}, "1", "2147483647", NPlain{}}, AppNone{}}, "5"},
    CItem{CParam{"maxmemory-eviction-tenacity", "", False{}, False{}, False{}, False{}, CNum{True{}, "0", "100", NPlain{}}, AppNone{}}, "10"},
    CItem{CParam{"timeout", "", False{}, False{}, False{}, False{}, CNum{True{}, "0", "2147483647", NPlain{}}, AppNone{}}, "0"},
    CItem{CParam{"replica-announce-port", "slave-announce-port", False{}, False{}, False{}, False{}, CNum{True{}, "0", "65535", NPlain{}}, AppNone{}}, "0"},
    CItem{CParam{"tcp-backlog", "", True{}, False{}, False{}, False{}, CNum{True{}, "0", "2147483647", NPlain{}}, AppNone{}}, "511"},
    CItem{CParam{"cluster-port", "", True{}, False{}, False{}, False{}, CNum{True{}, "0", "65535", NPlain{}}, AppNone{}}, "0"},
    CItem{CParam{"cluster-announce-bus-port", "", False{}, False{}, False{}, False{}, CNum{True{}, "0", "65535", NPlain{}}, AppNone{}}, "0"},
    CItem{CParam{"cluster-announce-port", "", False{}, False{}, False{}, False{}, CNum{True{}, "0", "65535", NPlain{}}, AppNone{}}, "0"},
    CItem{CParam{"cluster-announce-tls-port", "", False{}, False{}, False{}, False{}, CNum{True{}, "0", "65535", NPlain{}}, AppNone{}}, "0"},
    CItem{CParam{"repl-timeout", "", False{}, False{}, False{}, False{}, CNum{True{}, "1", "2147483647", NPlain{}}, AppNone{}}, "60"},
    CItem{CParam{"repl-ping-replica-period", "repl-ping-slave-period", False{}, False{}, False{}, False{}, CNum{True{}, "1", "2147483647", NPlain{}}, AppNone{}}, "10"},
    CItem{CParam{"list-compress-depth", "", False{}, False{}, False{}, False{}, CNum{True{}, "0", "2147483647", NPlain{}}, AppNone{}}, "0"},
    CItem{CParam{"rdb-key-save-delay", "", False{}, True{}, False{}, False{}, CNum{True{}, "-2147483648", "2147483647", NPlain{}}, AppNone{}}, "0"},
    CItem{CParam{"key-load-delay", "", False{}, True{}, False{}, False{}, CNum{True{}, "-2147483648", "2147483647", NPlain{}}, AppNone{}}, "0"},
    CItem{CParam{"active-expire-effort", "", False{}, False{}, False{}, False{}, CNum{True{}, "1", "10", NPlain{}}, AppNone{}}, "1"},
    CItem{CParam{"hz", "", False{}, False{}, False{}, False{}, CNum{True{}, "0", "2147483647", NPlain{}}, AppHz{}}, "10"},
    CItem{CParam{"min-replicas-to-write", "min-slaves-to-write", False{}, False{}, False{}, False{}, CNum{True{}, "0", "2147483647", NPlain{}}, AppNone{}}, "0"},
    CItem{CParam{"min-replicas-max-lag", "min-slaves-max-lag", False{}, False{}, False{}, False{}, CNum{True{}, "0", "2147483647", NPlain{}}, AppNone{}}, "10"},
    CItem{CParam{"watchdog-period", "", False{}, True{}, False{}, False{}, CNum{True{}, "0", "2147483647", NPlain{}}, AppNone{}}, "0"},
    CItem{CParam{"shutdown-timeout", "", False{}, False{}, False{}, False{}, CNum{True{}, "0", "2147483647", NPlain{}}, AppNone{}}, "10"},
    CItem{CParam{"repl-diskless-sync-max-replicas", "", False{}, False{}, False{}, False{}, CNum{True{}, "0", "2147483647", NPlain{}}, AppNone{}}, "0"},
    CItem{CParam{"maxclients", "", False{}, False{}, False{}, False{}, CNum{False{}, "1", "4294967295", NPlain{}}, AppNone{}}, "10000"},
    CItem{CParam{"unixsocketperm", "", True{}, False{}, False{}, False{}, CNum{False{}, "0", "511", NOct{}}, AppNone{}}, "0"},
    CItem{CParam{"socket-mark-id", "", True{}, False{}, False{}, False{}, CNum{False{}, "0", "4294967295", NPlain{}}, AppNone{}}, "0"},
    CItem{CParam{"active-defrag-max-scan-fields", "", False{}, False{}, False{}, False{}, CNum{False{}, "1", "9223372036854775807", NPlain{}}, AppNone{}}, "1000"},
    CItem{CParam{"slowlog-max-len", "", False{}, False{}, False{}, False{}, CNum{False{}, "0", "9223372036854775807", NPlain{}}, AppNone{}}, "128"},
    CItem{CParam{"acllog-max-len", "", False{}, False{}, False{}, False{}, CNum{False{}, "0", "9223372036854775807", NPlain{}}, AppNone{}}, "128"},
    CItem{CParam{"busy-reply-threshold", "lua-time-limit", False{}, False{}, False{}, False{}, CNum{True{}, "0", "9223372036854775807", NPlain{}}, AppNone{}}, "5000"},
    CItem{CParam{"cluster-node-timeout", "", False{}, False{}, False{}, False{}, CNum{True{}, "0", "9223372036854775807", NPlain{}}, AppNone{}}, "15000"},
    CItem{CParam{"slowlog-log-slower-than", "", False{}, False{}, False{}, False{}, CNum{True{}, "-1", "9223372036854775807", NPlain{}}, AppNone{}}, "10000"},
    CItem{CParam{"latency-monitor-threshold", "", False{}, False{}, False{}, False{}, CNum{True{}, "0", "9223372036854775807", NPlain{}}, AppNone{}}, "0"},
    CItem{CParam{"proto-max-bulk-len", "", False{}, False{}, False{}, False{}, CNum{True{}, "1048576", "9223372036854775807", NMem{}}, AppNone{}}, "536870912"},
    CItem{CParam{"stream-node-max-entries", "", False{}, False{}, False{}, False{}, CNum{True{}, "0", "9223372036854775807", NPlain{}}, AppNone{}}, "100"},
    CItem{CParam{"repl-backlog-size", "", False{}, False{}, False{}, False{}, CNum{True{}, "1", "9223372036854775807", NMem{}}, AppMin{"16384"}}, "1048576"},
    CItem{CParam{"maxmemory", "", False{}, False{}, False{}, False{}, CNum{False{}, "0", "18446744073709551615", NMem{}}, AppNone{}}, "0"},
    CItem{CParam{"cluster-link-sendbuf-limit", "", False{}, False{}, False{}, False{}, CNum{False{}, "0", "18446744073709551615", NMem{}}, AppNone{}}, "0"},
    CItem{CParam{"hash-max-listpack-entries", "hash-max-ziplist-entries", False{}, False{}, False{}, False{}, CNum{False{}, "0", "9223372036854775807", NPlain{}}, AppNone{}}, "512"},
    CItem{CParam{"set-max-intset-entries", "", False{}, False{}, False{}, False{}, CNum{False{}, "0", "9223372036854775807", NPlain{}}, AppNone{}}, "512"},
    CItem{CParam{"zset-max-listpack-entries", "zset-max-ziplist-entries", False{}, False{}, False{}, False{}, CNum{False{}, "0", "9223372036854775807", NPlain{}}, AppNone{}}, "128"},
    CItem{CParam{"active-defrag-ignore-bytes", "", False{}, False{}, False{}, False{}, CNum{False{}, "1", "9223372036854775807", NMem{}}, AppNone{}}, "104857600"},
    CItem{CParam{"hash-max-listpack-value", "hash-max-ziplist-value", False{}, False{}, False{}, False{}, CNum{False{}, "0", "9223372036854775807", NMem{}}, AppNone{}}, "64"},
    CItem{CParam{"stream-node-max-bytes", "", False{}, False{}, False{}, False{}, CNum{False{}, "0", "9223372036854775807", NMem{}}, AppNone{}}, "4096"},
    CItem{CParam{"zset-max-listpack-value", "zset-max-ziplist-value", False{}, False{}, False{}, False{}, CNum{False{}, "0", "9223372036854775807", NMem{}}, AppNone{}}, "64"},
    CItem{CParam{"hll-sparse-max-bytes", "", False{}, False{}, False{}, False{}, CNum{False{}, "0", "9223372036854775807", NMem{}}, AppNone{}}, "3000"},
    CItem{CParam{"tracking-table-max-keys", "", False{}, False{}, False{}, False{}, CNum{False{}, "0", "9223372036854775807", NPlain{}}, AppNone{}}, "1000000"},
    CItem{CParam{"client-query-buffer-limit", "", False{}, False{}, False{}, False{}, CNum{False{}, "1048576", "9223372036854775807", NMem{}}, AppNone{}}, "1073741824"},
    CItem{CParam{"maxmemory-clients", "", False{}, False{}, False{}, False{}, CNum{True{}, "-100", "9223372036854775807", NMemPct{}}, AppNone{}}, "0"},
    CItem{CParam{"repl-backlog-ttl", "", False{}, False{}, False{}, False{}, CNum{True{}, "0", "9223372036854775807", NPlain{}}, AppNone{}}, "3600"},
    CItem{CParam{"auto-aof-rewrite-min-size", "", False{}, False{}, False{}, False{}, CNum{True{}, "0", "9223372036854775807", NMem{}}, AppNone{}}, "67108864"},
    CItem{CParam{"loading-process-events-interval-bytes", "", False{}, True{}, False{}, False{}, CNum{True{}, "1024", "2147483647", NPlain{}}, AppNone{}}, "2097152"},
    CItem{CParam{"tls-port", "", False{}, False{}, False{}, False{}, CNum{True{}, "0", "65535", NPlain{}}, AppFixed{"Unable to update TLS configuration. Check server logs."}}, "0"},
    CItem{CParam{"tls-session-cache-size", "", False{}, False{}, False{}, False{}, CNum{True{}, "0", "2147483647", NPlain{}}, AppNone{}}, "20480"},
    CItem{CParam{"tls-session-cache-timeout", "", False{}, False{}, False{}, False{}, CNum{True{}, "0", "2147483647", NPlain{}}, AppNone{}}, "300"},
    CItem{CParam{"tls-cluster", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppFixed{"Unable to update TLS configuration. Check server logs."}}, "no"},
    CItem{CParam{"tls-replication", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppFixed{"Unable to update TLS configuration. Check server logs."}}, "no"},
    CItem{CParam{"tls-auth-clients", "", False{}, False{}, False{}, False{}, CEnum{["no", "yes", "optional"], [0, 1, 2], False{}, VNone{}}, AppNone{}}, "yes"},
    CItem{CParam{"tls-prefer-server-ciphers", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "no"},
    CItem{CParam{"tls-session-caching", "", False{}, False{}, False{}, False{}, CBool{VNone{}}, AppNone{}}, "yes"},
    CItem{CParam{"tls-cert-file", "", False{}, False{}, False{}, False{}, CStr{True{}, VNone{}}, AppNone{}}, ""},
    CItem{CParam{"tls-key-file", "", False{}, False{}, False{}, False{}, CStr{True{}, VNone{}}, AppNone{}}, ""},
    CItem{CParam{"tls-key-file-pass", "", False{}, False{}, False{}, False{}, CStr{True{}, VNone{}}, AppNone{}}, ""},
    CItem{CParam{"tls-client-cert-file", "", False{}, False{}, False{}, False{}, CStr{True{}, VNone{}}, AppNone{}}, ""},
    CItem{CParam{"tls-client-key-file", "", False{}, False{}, False{}, False{}, CStr{True{}, VNone{}}, AppNone{}}, ""},
    CItem{CParam{"tls-client-key-file-pass", "", False{}, False{}, False{}, False{}, CStr{True{}, VNone{}}, AppNone{}}, ""},
    CItem{CParam{"tls-dh-params-file", "", False{}, False{}, False{}, False{}, CStr{True{}, VNone{}}, AppNone{}}, ""},
    CItem{CParam{"tls-ca-cert-file", "", False{}, False{}, False{}, False{}, CStr{True{}, VNone{}}, AppNone{}}, ""},
    CItem{CParam{"tls-ca-cert-dir", "", False{}, False{}, False{}, False{}, CStr{True{}, VNone{}}, AppNone{}}, ""},
    CItem{CParam{"tls-protocols", "", False{}, False{}, False{}, False{}, CStr{True{}, VNone{}}, AppNone{}}, ""},
    CItem{CParam{"tls-ciphers", "", False{}, False{}, False{}, False{}, CStr{True{}, VNone{}}, AppNone{}}, ""},
    CItem{CParam{"tls-ciphersuites", "", False{}, False{}, False{}, False{}, CStr{True{}, VNone{}}, AppNone{}}, ""},
    CItem{CParam{"dir", "", False{}, False{}, True{}, False{}, CSpec{XDir{}}, AppNone{}}, ""},
    CItem{CParam{"save", "", False{}, False{}, False{}, True{}, CSpec{XSave{}}, AppNone{}}, ""},
    CItem{CParam{"client-output-buffer-limit", "", False{}, False{}, False{}, True{}, CSpec{XObuf{}}, AppNone{}}, "normal 0 0 0 slave 268435456 67108864 60 pubsub 33554432 8388608 60"},
    CItem{CParam{"oom-score-adj-values", "", False{}, False{}, False{}, True{}, CSpec{XOom{}}, AppNone{}}, "0 200 800"},
    CItem{CParam{"notify-keyspace-events", "", False{}, False{}, False{}, False{}, CSpec{XNotify{}}, AppNone{}}, ""},
    CItem{CParam{"bind", "", False{}, False{}, False{}, True{}, CSpec{XBind{}}, AppFixed{"Failed to bind to specified addresses."}}, "127.0.0.1"},
    CItem{CParam{"replicaof", "slaveof", True{}, False{}, False{}, True{}, CSpec{XReplicaof{}}, AppNone{}}, ""},
    CItem{CParam{"latency-tracking-info-percentiles", "", False{}, False{}, False{}, True{}, CSpec{XPct{}}, AppNone{}}, "50 99 99.9"}
  ]
# END gen_config: table

# Bytes and words
# ---------------

def byte.digit(+x: U32) -> Bool:
  Bool.and(U32.is_ge(x, 48), U32.is_le(x, 57))

def byte.alpha(+x: U32) -> Bool:
  Bool.or(Bool.and(U32.is_ge(x, 65), U32.is_le(x, 90)), Bool.and(U32.is_ge(x, 97), U32.is_le(x, 122)))

# ASCII lower case, as C's tolower
def byte.lower(+x: U32) -> U32:
  U32.add(x, U32.mul(Bool.to_u32(Bool.and(U32.is_ge(x, 65), U32.is_le(x, 90))), 32))

# C's isspace
def byte.space(+x: U32) -> Bool:
  Bool.or(U32.is_eq(x, 32), Bool.and(U32.is_ge(x, 9), U32.is_le(x, 13)))

# whether every byte is a digit ("" is)
def text.digits(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{Chr{+x}, t}:
      Bool.and(byte.digit(x), text.digits(t))

# how many digits s starts with
def text.ndigits(s: String) -> Nat:
  match s:
    case SNil{}:
      0n
    case SCon{Chr{+x}, t}:
      Bool.pick(Nat, byte.digit(x), 1n+text.ndigits(t), 0n)

def text.has(s: String, +c: U32) -> Bool:
  match s:
    case SNil{}:
      False{}
    case SCon{Chr{+x}, t}:
      Bool.or(U32.is_eq(x, c), text.has(t, c))

def text.octal(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{Chr{+x}, t}:
      Bool.and(Bool.and(U32.is_ge(x, 48), U32.is_le(x, 55)), text.octal(t))

# a name compared as Redis compares parameter names: case aside
def text.same(+a: String, +b: String) -> Bool:
  String.eq(String.to_lower(a), String.to_lower(b))

# the words of a value of several arguments: split at each space, as
# Redis splits one, so that two spaces make an empty word; none for ""
def words(v: String) -> List<&2, String>:
  match v:
    case SNil{}:
      Nil{}
    case SCon{h, t}:
      String.split(SCon{h, t}, ' ')

def text.member(xs: List<&2, String>, +s: String) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Con{x, rest}:
      Bool.or(String.eq(x, s), text.member(rest, s))

def unwords(ws: List<&2, String>) -> String:
  String.join(ws, " ")

# Patterns
# --------
# CONFIG GET matches names as Redis's stringmatchlen does, with case
# aside: '*' any run of bytes, '?' any byte, '[...]' a class (with '^',
# ranges and '\'), '\' the byte after it. A '*' whose rest matches nowhere
# in the rest of the string ends the search (Redis's skipLongerMatches): a
# longer run for an earlier '*' could only start the rest later, so a
# pattern costs polynomial time, not exponential. A '*' does not match an
# empty string, as in Redis, where the empty string never enters the loop.

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

# whether an argument of CONFIG GET is a pattern
def is_pattern(+s: String) -> Bool:
  Bool.or(text.has(s, 91), Bool.or(text.has(s, 42), text.has(s, 63)))

# Numbers
# -------
# Numbers stay decimal strings: compared by their length and then digit
# by digit, multiplied by a unit a digit at a time.

# the digits without leading zeros ("0" for none)
def dec.trim(s: String) -> String:
  match s:
    case SCon{'0', t}:
      dec.trim(t)
    case SNil{}:
      "0"
    case SCon{h, t}:
      SCon{h, t}

# a <= b, for digits without leading zeros
def dec.le(+a: String, +b: String) -> Bool:
  Bool.or(Nat.is_lt(String.length(a), String.length(b)), Bool.and(Nat.is_eq(String.length(a), String.length(b)), String.is_le(a, b)))

# a <= b for numbers as they print: an optional '-' and digits
def dec.sle(+a: String, +b: String) -> Bool:
  match a b:
    case SCon{'-', x} SCon{'-', y}:
      dec.le(y, x)
    case SCon{'-', x} _:
      True{}
    case _ SCon{'-', y}:
      False{}
    case _ _:
      dec.le(a, b)

def dec.vals(s: String, acc: List<&2, Nat>) -> List<&2, Nat>:
  match s:
    case SNil{}:
      acc
    case SCon{Chr{x}, t}:
      dec.vals(t, U32.to_nat(U32.sub(x, 48)) <> acc)

def dec.digit(n: Nat) -> Char:
  Chr{U32.add(48, U32.from_nat(n))}

def dec.mul.go(ds: List<&2, Nat>, +m: Nat, +c: Nat, +acc: String) -> String:
  match ds:
    case Nil{}:
      Bool.pick(String, Nat.is_eq(c, 0n), acc, Nat.show(c) ++ acc)
    case Con{d, rest}:
      +t = Nat.add(Nat.mul(d, m), c)
      dec.mul.go(rest, m, Nat.div(t, 10n), SCon{dec.digit(Nat.mod(t, 10n)), acc})

# digits times m (m below 2^31)
def dec.mul(s: String, m: Nat) -> String:
  dec.trim(dec.mul.go(dec.vals(s, Nil{}), m, 0n, ""))

def dec.u64max() -> String:
  "18446744073709551615"

def dec.i64max() -> String:
  "9223372036854775807"

# Redis's string2ll: "0", or an optional '-' and digits that do not start
# with 0, within 64 bits; such a number is written the one way it prints
def ll.mag(+t: String, +lim: String) -> Bool:
  match t:
    case SNil{}:
      False{}
    case SCon{'0', r}:
      False{}
    case _:
      Bool.and(text.digits(t), dec.le(t, lim))

def ll.ok(+s: String) -> Bool:
  match s:
    case SCon{'-', t}:
      ll.mag(t, "9223372036854775808")
    case SCon{'0', SNil{}}:
      True{}
    case _:
      ll.mag(s, dec.i64max())

# Redis's memtoull: digits (none reads as 0, leading zeros are fine) and
# a unit: b, k (1000), kb (1024), m, mb, g, gb, case aside; more than 127
# digits, a '-' or another unit fail. Digits past 2^64-1 read as 2^64-1,
# as strtoull reads them, and the product wraps around 2^64, as an
# unsigned long long does.
def dec.two64() -> String:
  "18446744073709551616"

def dec.sub.d(+x: Nat, +s: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_le(s, x), Nat.sub(x, s), Nat.sub(Nat.add(x, 10n), s))

def dec.sub.go(xs: List<&2, Nat>, ys: List<&2, Nat>, +br: Nat, acc: String) -> String:
  match xs ys:
    case Nil{} _:
      acc
    case Con{+x, xr} Con{+y, yr}:
      dec.sub.go(xr, yr, Bool.pick(Nat, Nat.is_le(Nat.add(y, br), x), 0n, 1n), SCon{dec.digit(dec.sub.d(x, Nat.add(y, br))), acc})
    case Con{+x, xr} Nil{}:
      dec.sub.go(xr, Nil{}, Bool.pick(Nat, Nat.is_le(br, x), 0n, 1n), SCon{dec.digit(dec.sub.d(x, br)), acc})

# a - b, for digits a >= b
def dec.sub(a: String, b: String) -> String:
  dec.trim(dec.sub.go(dec.vals(a, Nil{}), dec.vals(b, Nil{}), 0n, ""))

# r less 2^64 while it is not below it (n times at most)
def dec.mod.fix(n: Nat, +r: String) -> String:
  match n:
    case 0n:
      r
    case 1n+m:
      Bool.pick(String, dec.le(dec.two64(), r), dec.mod.fix(m, dec.sub(r, dec.two64())), r)

def dec.mod.go(ds: String, r: String) -> String:
  match ds:
    case SNil{}:
      r
    case SCon{d, t}:
      dec.mod.go(t, dec.mod.fix(10n, dec.trim(r ++ SCon{d, SNil{}})))

# digits modulo 2^64, by long division
def dec.mod64(p: String) -> String:
  dec.mod.go(p, "0")

def mem.unit(+u: String) -> Maybe<&2, Nat>:
  Bool.pick(Maybe<&2, Nat>, Bool.or(String.is_empty(u), text.same(u, "b")), Some{1n},
  Bool.pick(Maybe<&2, Nat>, text.same(u, "k"), Some{1000n},
  Bool.pick(Maybe<&2, Nat>, text.same(u, "kb"), Some{1024n},
  Bool.pick(Maybe<&2, Nat>, text.same(u, "m"), Some{1000000n},
  Bool.pick(Maybe<&2, Nat>, text.same(u, "mb"), Some{1048576n},
  Bool.pick(Maybe<&2, Nat>, text.same(u, "g"), Some{1000000000n},
  Bool.pick(Maybe<&2, Nat>, text.same(u, "gb"), Some{1073741824n}, None{})))))))

def mem.cap(+v: String) -> String:
  Bool.pick(String, dec.le(v, dec.u64max()), v, dec.u64max())

def mem.of(+ds: String, u: Maybe<&2, Nat>, short: Bool) -> Maybe<&2, String>:
  match u short:
    case Some{m} True{}:
      Some{dec.mod64(dec.mul(mem.cap(dec.trim(ds)), m))}
    case _ _:
      None{}

def mem.read(+s: String) -> Maybe<&2, String>:
  match s:
    case SCon{'-', t}:
      None{}
    case _:
      mem.of(String.take(s, text.ndigits(s)), mem.unit(String.drop(s, text.ndigits(s))), Nat.is_lt(text.ndigits(s), 128n))

# a percent: digits as string2ll reads them, and '%' (Redis keeps a
# percent as a negative number, so 0% is 0); the digits
def pct.of(ok: Bool, +p: String) -> Maybe<&2, String>:
  match ok p:
    case True{} SCon{'-', t}:
      None{}
    case True{} _:
      Bool.pick(Maybe<&2, String>, ll.ok(p), Some{p}, None{})
    case False{} _:
      None{}

def pct.read(+s: String) -> Maybe<&2, String>:
  pct.of(Bool.and(String.ends_with(s, "%"), Nat.is_lt(1n, String.length(s))), String.take(s, Nat.sub(String.length(s), 1n)))

# Values
# ------
# A value checked against its parameter's type gives the value as CONFIG
# GET prints it, or the error as Redis words it (without the "CONFIG SET
# failed" before it).

def between(+lo: String, +hi: String) -> String:
  "argument must be between " ++ lo ++ " and " ++ hi ++ " inclusive"

def num.in(+n: String, +lo: String, +hi: String) -> Result<&2, &2, String, String>:
  Bool.pick(Result<&2, &2, String, String>, Bool.and(dec.sle(lo, n), dec.sle(n, hi)), Done{n}, Fail{between(lo, hi)})

def num.plain(+v: String, +lo: String, +hi: String) -> Result<&2, &2, String, String>:
  Bool.pick(Result<&2, &2, String, String>, ll.ok(v), num.in(v, lo, hi), Fail{"argument couldn't be parsed into an integer"})

def num.mem(m: Maybe<&2, String>, +lo: String, +hi: String) -> Result<&2, &2, String, String>:
  match m:
    case Some{u}:
      num.in(u, lo, hi)
    case None{}:
      Fail{"argument must be a memory value"}

# a percent p: Redis keeps it as -p, and -p must not be below lo
def num.pct(+p: String, +lo: String) -> Result<&2, &2, String, String>:
  Bool.pick(Result<&2, &2, String, String>, String.eq(p, "0"), Done{"0"},
    Bool.pick(Result<&2, &2, String, String>, dec.le(p, String.drop(lo, 1n)), Done{p ++ "%"},
      Fail{"percentage argument must be less or equal to " ++ String.drop(lo, 1n)}))

def dec.small(s: String, acc: Nat) -> Nat:
  match s:
    case SNil{}:
      acc
    case SCon{Chr{x}, t}:
      dec.small(t, Nat.add(Nat.mul(acc, 10n), U32.to_nat(U32.sub(x, 48))))

# a memory value past 2^63-1 for a signed parameter: Redis reads it as
# 2^64 less, a negative number, so one within 100 of 2^64 is a percent
def num.wrap(+u: String, +lo: String) -> Result<&2, &2, String, String>:
  Bool.pick(Result<&2, &2, String, String>, dec.le("18446744073709551516", u),
    num.pct(Nat.show(Nat.sub(1616n, dec.small(String.drop(u, 16n), 0n))), lo),
    Fail{"percentage argument must be less or equal to " ++ String.drop(lo, 1n)})

def num.mempct(m: Maybe<&2, String>, p: Maybe<&2, String>, +lo: String, +hi: String) -> Result<&2, &2, String, String>:
  match m p:
    case Some{+u} _:
      Bool.pick(Result<&2, &2, String, String>, dec.le(u, dec.i64max()), num.in(u, lo, hi), num.wrap(u, lo))
    case None{} Some{d}:
      num.pct(d, lo)
    case None{} None{}:
      Fail{"argument must be a memory or percent value"}

# octal digits (unixsocketperm, which cannot change while the server runs;
# its bounds are octal too)
def num.oct(+v: String, +lo: String, +hi: String) -> Result<&2, &2, String, String>:
  Bool.pick(Result<&2, &2, String, String>, Bool.and(Bool.not(String.is_empty(v)), text.octal(v)),
    Bool.pick(Result<&2, &2, String, String>, dec.le(dec.trim(v), hi), Done{dec.trim(v)}, Fail{between(lo, hi)}),
    Fail{"argument couldn't be parsed as an octal number"})

# hz is capped to 1..500, as Redis caps it
def num.hz(r: Result<&2, &2, String, String>) -> Result<&2, &2, String, String>:
  match r:
    case Done{+n}:
      Done{Bool.pick(String, String.eq(n, "0"), "1", Bool.pick(String, dec.le(n, "500"), n, "500"))}
    case Fail{e}:
      Fail{e}

def num.set(fmt: NumFmt, +v: String, +lo: String, +hi: String) -> Result<&2, &2, String, String>:
  match fmt:
    case NPlain{}:
      num.plain(v, lo, hi)
    case NMem{}:
      num.mem(mem.read(v), lo, hi)
    case NMemPct{}:
      num.mempct(mem.read(v), pct.read(v), lo, hi)
    case NOct{}:
      num.oct(v, lo, hi)

# activedefrag cannot be turned on, as in a Redis built without its own
# jemalloc (BendKV has no defragmentation)
def bool.yes(vet: Vet) -> Result<&2, &2, String, String>:
  match vet:
    case VDefrag{}:
      Fail{"Active defragmentation cannot be enabled: it requires a Redis server compiled with a modified Jemalloc like the one shipped by default with the Redis source distribution"}
    case _:
      Done{"yes"}

def bool.set(vet: Vet, +v: String) -> Result<&2, &2, String, String>:
  Bool.pick(Result<&2, &2, String, String>, text.same(v, "yes"), bool.yes(vet),
    Bool.pick(Result<&2, &2, String, String>, text.same(v, "no"), Done{"no"}, Fail{"argument must be 'yes' or 'no'"}))

# one of some names, case aside (several, as bit flags, for a parameter
# of words): their value, or None when a word is no name
def enum.find(+w: String, names: List<&2, String>, vals: List<&2, U32>) -> Maybe<&2, U32>:
  match names vals:
    case Con{+n, ns} Con{+x, xs}:
      Bool.pick(Maybe<&2, U32>, text.same(w, n), Some{x}, enum.find(w, ns, xs))
    case _ _:
      None{}

def enum.join(a: Maybe<&2, U32>, b: Maybe<&2, U32>) -> Maybe<&2, U32>:
  match a b:
    case Some{x} Some{y}:
      Some{U32.or(x, y)}
    case _ _:
      None{}

def enum.or(ws: List<&2, String>, +names: List<&2, String>, +vals: List<&2, U32>, acc: Maybe<&2, U32>) -> Maybe<&2, U32>:
  match ws:
    case Nil{}:
      acc
    case Con{+w, rest}:
      enum.or(rest, names, vals, enum.join(acc, enum.find(w, names, vals)))

def enum.read(ws: List<&2, String>, +names: List<&2, String>, +vals: List<&2, U32>) -> Maybe<&2, U32>:
  match ws:
    case Nil{}:
      None{}
    case Con{w, rest}:
      enum.or(Con{w, rest}, names, vals, Some{0})

def enum.hit(+bits: Bool, +x: U32, +un: U32) -> Bool:
  Bool.and(bits, Bool.and(U32.is_ne(x, 0), U32.is_eq(U32.and(un, x), x)))

def enum.fin(acc: List<&2, String>, +un: U32) -> String:
  match acc:
    case Nil{}:
      "unknown"
    case Con{a, rest}:
      Bool.pick(String, U32.is_eq(un, 0), unwords(Con{a, rest}), "unknown")

# Redis's configEnumGetName: the first name of the value; for bit flags,
# else the names of the flags in it, or "unknown"
def enum.name(names: List<&2, String>, vals: List<&2, U32>, +v: U32, +bits: Bool, +un: U32, +acc: List<&2, String>) -> String:
  match names vals:
    case Con{+n, ns} Con{+x, xs}:
      Bool.pick(String, U32.is_eq(v, x), n,
        enum.name(ns, xs, v, bits, Bool.pick(U32, enum.hit(bits, x, un), U32.and(un, U32.not(x)), un),
          Bool.pick(List<&2, String>, enum.hit(bits, x, un), List.append(&2, String, acc, [n]), acc)))
    case _ _:
      enum.fin(acc, un)

def enum.vet(vet: Vet, +x: U32) -> Bool:
  match vet:
    case VSig{}:
      Bool.not(Bool.and(U32.is_ne(U32.and(x, 1), 0), U32.is_ne(U32.and(x, 2), 0)))
    case _:
      True{}

def enum.got(m: Maybe<&2, U32>, +names: List<&2, String>, +vals: List<&2, U32>, +bits: Bool, vet: Vet) -> Result<&2, &2, String, String>:
  match m:
    case None{}:
      Fail{"argument(s) must be one of the following: " ++ String.join(names, ", ")}
    case Some{+x}:
      Bool.pick(Result<&2, &2, String, String>, enum.vet(vet, x), Done{enum.name(names, vals, x, bits, x, Nil{})},
        Fail{"shutdown options SAVE and NOSAVE can't be used simultaneously"})

def enum.set(+names: List<&2, String>, +vals: List<&2, U32>, +bits: Bool, vet: Vet, +v: String) -> Result<&2, &2, String, String>:
  enum.got(enum.read(Bool.pick(List<&2, String>, bits, words(v), [v]), names, vals), names, vals, bits, vet)

# Strings
# -------

def text.path(+s: String) -> Bool:
  Bool.or(text.has(s, 47), text.has(s, 92))

def text.host(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{Chr{+x}, t}:
      Bool.and(Bool.or(Bool.or(byte.digit(x), byte.alpha(x)), Bool.or(U32.is_eq(x, 45), U32.is_eq(x, 46))), text.host(t))

# proc-title-template: Redis expands it with an empty title and keeps it
# only when it expands to more than spaces. Its variables: {title},
# {listen-addr}, {server-mode}, {config-file}, {port}, {tls-port} and
# {unixsocket}, of which listen-addr, config-file and the ports never
# expand to nothing here; "{{" is a '{'.
type TMode is Data:
  TText{}
  TVar{name: String}

def title.known(+n: String) -> Bool:
  Bool.or(Bool.or(String.eq(n, "title"), String.eq(n, "listen-addr")),
    Bool.or(Bool.or(String.eq(n, "server-mode"), String.eq(n, "config-file")),
      Bool.or(Bool.or(String.eq(n, "port"), String.eq(n, "tls-port")), String.eq(n, "unixsocket"))))

def title.full(+n: String) -> Bool:
  Bool.or(Bool.or(String.eq(n, "listen-addr"), String.eq(n, "config-file")), Bool.or(String.eq(n, "port"), String.eq(n, "tls-port")))

def title.if(ok: Bool, r: Maybe<&2, Bool>) -> Maybe<&2, Bool>:
  match ok:
    case True{}:
      r
    case False{}:
      None{}

# whether the template is well formed, and then whether it shows more
# than spaces
def title.go(s: String, m: TMode, +seen: Bool) -> Maybe<&2, Bool>:
  match s m:
    case SNil{} TText{}:
      Some{seen}
    case SNil{} TVar{n}:
      None{}
    case SCon{'{', SCon{'{', t}} TText{}:
      title.go(t, TText{}, True{})
    case SCon{'{', SNil{}} TText{}:
      None{}
    case SCon{'{', t} TText{}:
      title.go(t, TVar{""}, seen)
    case SCon{Chr{+x}, t} TText{}:
      title.go(t, TText{}, Bool.or(seen, U32.is_ne(x, 32)))
    case SCon{'}', t} TVar{+n}:
      title.if(title.known(String.reverse(n)), title.go(t, TText{}, Bool.or(seen, title.full(String.reverse(n)))))
    case SCon{c, t} TVar{n}:
      title.go(t, TVar{SCon{c, n}}, seen)

def title.ok(m: Maybe<&2, Bool>) -> Bool:
  match m:
    case Some{b}:
      b
    case None{}:
      False{}

def str.set(vet: Vet, +v: String) -> Result<&2, &2, String, String>:
  match vet:
    case VFile{}:
      Bool.pick(Result<&2, &2, String, String>, text.path(v), Fail{"dbfilename can't be a path, just a filename"}, Done{v})
    case VAofFile{}:
      Bool.pick(Result<&2, &2, String, String>, String.is_empty(v), Fail{"appendfilename can't be empty"},
        Bool.pick(Result<&2, &2, String, String>, text.path(v), Fail{"appendfilename can't be a path, just a filename"}, Done{v}))
    case VAofDir{}:
      Bool.pick(Result<&2, &2, String, String>, String.is_empty(v), Fail{"appenddirname can't be empty"},
        Bool.pick(Result<&2, &2, String, String>, text.path(v), Fail{"appenddirname can't be a path, just a dirname"}, Done{v}))
    case VHost{}:
      Bool.pick(Result<&2, &2, String, String>, Nat.is_le(256n, String.length(v)), Fail{"Hostnames must be less than 256 characters"},
        Bool.pick(Result<&2, &2, String, String>, text.host(v), Done{v}, Fail{"Hostnames may only contain alphanumeric characters, hyphens or dots"}))
    case VTitle{}:
      Bool.pick(Result<&2, &2, String, String>, title.ok(title.go(v, TText{}, False{})), Done{v}, Fail{"template format is invalid or contains unknown variables"})
    case _:
      Done{v}

# The parameters with a syntax of their own
# -----------------------------------------

# a word read as C's strtoll reads one, and as Redis checks it (all of it
# read): "" is 0, leading C spaces and a sign may come before the digits,
# and a value past 64 bits stops at the bound
def text.unspace(s: String) -> String:
  match s:
    case SCon{Chr{+x}, +t}:
      Bool.pick(String, byte.space(x), text.unspace(t), SCon{Chr{x}, t})
    case SNil{}:
      SNil{}

def ll.digits(+ds: String, neg: Bool) -> Maybe<&2, String>:
  match neg:
    case True{}:
      Bool.pick(Maybe<&2, String>, String.eq(dec.trim(ds), "0"), Some{"0"},
        Some{"-" ++ Bool.pick(String, dec.le(dec.trim(ds), "9223372036854775808"), dec.trim(ds), "9223372036854775808")})
    case False{}:
      Some{Bool.pick(String, dec.le(dec.trim(ds), dec.i64max()), dec.trim(ds), dec.i64max())}

def ll.signed(+u: String, neg: Bool) -> Maybe<&2, String>:
  Bool.pick(Maybe<&2, String>, Bool.and(Bool.not(String.is_empty(u)), text.digits(u)), ll.digits(u, neg), None{})

def ll.loose.of(u: String) -> Maybe<&2, String>:
  match u:
    case SCon{'-', t}:
      ll.signed(t, True{})
    case SCon{'+', t}:
      ll.signed(t, False{})
    case _:
      ll.signed(u, False{})

def ll.loose(t: String) -> Maybe<&2, String>:
  match t:
    case SNil{}:
      Some{"0"}
    case SCon{h, r}:
      ll.loose.of(text.unspace(SCon{h, r}))

# the values of a list of checks, or None when one failed
def maybes.cons(x: String, m: Maybe<&2, List<&2, String>>) -> Maybe<&2, List<&2, String>>:
  match m:
    case Some{xs}:
      Some{x <> xs}
    case None{}:
      None{}

def maybes(ms: List<&2, Maybe<&2, String>>) -> Maybe<&2, List<&2, String>>:
  match ms:
    case Nil{}:
      Some{Nil{}}
    case Con{Some{x}, rest}:
      maybes.cons(x, maybes(rest))
    case Con{None{}, rest}:
      None{}

def odd(n: Nat) -> Bool:
  Nat.is_eq(Nat.mod(n, 2n), 1n)

# save: pairs of seconds (at least 1) and changes (at least 0)
def save.tok(m: Maybe<&2, String>, even: Bool) -> Maybe<&2, String>:
  match m:
    case Some{+v}:
      Bool.pick(Maybe<&2, String>, dec.sle(Bool.pick(String, even, "1", "0"), v), Some{v}, None{})
    case None{}:
      None{}

def save.map(ws: List<&2, String>, +even: Bool) -> List<&2, Maybe<&2, String>>:
  match ws:
    case Nil{}:
      Nil{}
    case Con{w, rest}:
      save.tok(ll.loose(w), even) <> save.map(rest, Bool.not(even))

def save.got(m: Maybe<&2, List<&2, String>>) -> Result<&2, &2, String, String>:
  match m:
    case Some{xs}:
      Done{unwords(xs)}
    case None{}:
      Fail{"Invalid save parameters"}

def save.set(+ws: List<&2, String>) -> Result<&2, &2, String, String>:
  Bool.pick(Result<&2, &2, String, String>, odd(List.length(&2, String, ws)), Fail{"Invalid save parameters"}, save.got(maybes(save.map(ws, True{}))))

# client-output-buffer-limit: groups of a class (normal, slave or replica,
# pubsub), a hard and a soft limit (memory values) and seconds; a group
# sets its class, the others keep theirs
type OLim is Data:
  OLim{nh: String, ns: String, nt: String, sh: String, ss: String, st: String, ph: String, ps: String, pt: String}

type OGrp is Data:
  OOk{k: Nat, h: String, s: String, t: String}
  OBadClass{}
  OBadVal{}

def obuf.of(ws: List<&2, String>) -> OLim:
  match ws:
    case [a, nh, ns, nt, b, sh, ss, st, c, ph, ps, pt]:
      OLim{nh, ns, nt, sh, ss, st, ph, ps, pt}
    case _:
      OLim{"0", "0", "0", "268435456", "67108864", "60", "33554432", "8388608", "60"}

def obuf.show(l: OLim) -> String:
  match l:
    case OLim{nh, ns, nt, sh, ss, st, ph, ps, pt}:
      unwords(["normal", nh, ns, nt, "slave", sh, ss, st, "pubsub", ph, ps, pt])

def obuf.class(+c: String) -> Nat:
  Bool.pick(Nat, text.same(c, "normal"), 1n, Bool.pick(Nat, Bool.or(text.same(c, "slave"), text.same(c, "replica")), 2n, Bool.pick(Nat, text.same(c, "pubsub"), 3n, 0n)))

# seconds: as Redis keeps them, in an int that must not be negative
def obuf.secs(m: Maybe<&2, String>) -> Maybe<&2, String>:
  match m:
    case Some{+v}:
      Bool.pick(Maybe<&2, String>, Bool.and(dec.sle("0", v), dec.sle(v, "2147483647")), Some{v}, None{})
    case None{}:
      None{}

def obuf.grp(k: Nat, h: Maybe<&2, String>, s: Maybe<&2, String>, t: Maybe<&2, String>) -> OGrp:
  match k h s t:
    case 0n _ _ _:
      OBadClass{}
    case 1n++j Some{x} Some{y} Some{z}:
      OOk{1n+j, x, y, z}
    case _ _ _ _:
      OBadVal{}

def obuf.grps(ws: List<&2, String>) -> List<&2, OGrp>:
  match ws:
    case Con{+c, Con{h, Con{s, Con{t, rest}}}}:
      obuf.grp(obuf.class(c), mem.read(h), mem.read(s), obuf.secs(ll.loose(t))) <> obuf.grps(rest)
    case _:
      Nil{}

def obuf.err(gs: List<&2, OGrp>) -> Maybe<&2, String>:
  match gs:
    case Nil{}:
      None{}
    case Con{OBadClass{}, rest}:
      Some{"Invalid client class specified in buffer limit configuration."}
    case Con{OBadVal{}, rest}:
      Some{"Error in hard, soft or soft_seconds setting in buffer limit configuration."}
    case Con{OOk{k, h, s, t}, rest}:
      obuf.err(rest)

def obuf.put(l: OLim, g: OGrp) -> OLim:
  match l g:
    case OLim{nh, ns, nt, sh, ss, st, ph, ps, pt} OOk{1n, h, s, t}:
      OLim{h, s, t, sh, ss, st, ph, ps, pt}
    case OLim{nh, ns, nt, sh, ss, st, ph, ps, pt} OOk{2n, h, s, t}:
      OLim{nh, ns, nt, h, s, t, ph, ps, pt}
    case OLim{nh, ns, nt, sh, ss, st, ph, ps, pt} OOk{3n, h, s, t}:
      OLim{nh, ns, nt, sh, ss, st, h, s, t}
    case l0 _:
      l0

def obuf.apply(gs: List<&2, OGrp>, l: OLim) -> OLim:
  match gs:
    case Nil{}:
      l
    case Con{g, rest}:
      obuf.apply(rest, obuf.put(l, g))

def obuf.fin(e: Maybe<&2, String>, +old: String, +gs: List<&2, OGrp>) -> Result<&2, &2, String, String>:
  match e:
    case Some{m}:
      Fail{m}
    case None{}:
      Done{obuf.show(obuf.apply(gs, obuf.of(words(old))))}

def obuf.set(+ws: List<&2, String>, +old: String) -> Result<&2, &2, String, String>:
  Bool.pick(Result<&2, &2, String, String>, Nat.is_eq(Nat.mod(List.length(&2, String, ws), 4n), 0n),
    obuf.fin(obuf.err(obuf.grps(ws)), old, obuf.grps(ws)),
    Fail{"Wrong number of arguments in buffer limit configuration."})

# oom-score-adj-values: three numbers from -2000 to 2000
def oom.tok(m: Maybe<&2, String>) -> Maybe<&2, String>:
  match m:
    case Some{+v}:
      Bool.pick(Maybe<&2, String>, Bool.and(dec.sle("-2000", v), dec.sle(v, "2000")), Some{v}, None{})
    case None{}:
      None{}

def oom.map(ws: List<&2, String>) -> List<&2, Maybe<&2, String>>:
  match ws:
    case Nil{}:
      Nil{}
    case Con{w, rest}:
      oom.tok(ll.loose(w)) <> oom.map(rest)

def oom.got(m: Maybe<&2, List<&2, String>>) -> Result<&2, &2, String, String>:
  match m:
    case Some{xs}:
      Done{unwords(xs)}
    case None{}:
      Fail{"Invalid oom-score-adj-values, elements must be between -2000 and 2000."}

def oom.set(+ws: List<&2, String>) -> Result<&2, &2, String, String>:
  Bool.pick(Result<&2, &2, String, String>, Nat.is_eq(List.length(&2, String, ws), 3n), oom.got(maybes(oom.map(ws))), Fail{"wrong number of arguments"})

# notify-keyspace-events: classes of events by letter, printed in Redis's
# order ("A" for all of g$lshzxetd, which leaves n out)
def notify.bit(+c: U32) -> Maybe<&2, U32>:
  Bool.pick(Maybe<&2, U32>, U32.is_eq(c, 65), Some{10236},
  Bool.pick(Maybe<&2, U32>, U32.is_eq(c, 103), Some{4},
  Bool.pick(Maybe<&2, U32>, U32.is_eq(c, 36), Some{8},
  Bool.pick(Maybe<&2, U32>, U32.is_eq(c, 108), Some{16},
  Bool.pick(Maybe<&2, U32>, U32.is_eq(c, 115), Some{32},
  Bool.pick(Maybe<&2, U32>, U32.is_eq(c, 104), Some{64},
  Bool.pick(Maybe<&2, U32>, U32.is_eq(c, 122), Some{128},
  Bool.pick(Maybe<&2, U32>, U32.is_eq(c, 120), Some{256},
  Bool.pick(Maybe<&2, U32>, U32.is_eq(c, 101), Some{512},
  Bool.pick(Maybe<&2, U32>, U32.is_eq(c, 75), Some{1},
  Bool.pick(Maybe<&2, U32>, U32.is_eq(c, 69), Some{2},
  Bool.pick(Maybe<&2, U32>, U32.is_eq(c, 116), Some{1024},
  Bool.pick(Maybe<&2, U32>, U32.is_eq(c, 109), Some{2048},
  Bool.pick(Maybe<&2, U32>, U32.is_eq(c, 100), Some{8192},
  Bool.pick(Maybe<&2, U32>, U32.is_eq(c, 110), Some{16384}, None{})))))))))))))))

def notify.read(s: String, acc: Maybe<&2, U32>) -> Maybe<&2, U32>:
  match s:
    case SNil{}:
      acc
    case SCon{Chr{+x}, t}:
      notify.read(t, enum.join(acc, notify.bit(x)))

def notify.flag(+f: U32, bit: U32, c: String) -> String:
  Bool.pick(String, U32.is_ne(U32.and(f, bit), 0), c, "")

def notify.show(+f: U32) -> String:
  Bool.pick(String, U32.is_eq(U32.and(f, 10236), 10236), "A",
    notify.flag(f, 4, "g") ++ notify.flag(f, 8, "$") ++ notify.flag(f, 16, "l") ++ notify.flag(f, 32, "s") ++
    notify.flag(f, 64, "h") ++ notify.flag(f, 128, "z") ++ notify.flag(f, 256, "x") ++ notify.flag(f, 512, "e") ++
    notify.flag(f, 1024, "t") ++ notify.flag(f, 8192, "d") ++ notify.flag(f, 16384, "n"))
    ++ notify.flag(f, 1, "K") ++ notify.flag(f, 2, "E") ++ notify.flag(f, 2048, "m")

def notify.got(m: Maybe<&2, U32>) -> Result<&2, &2, String, String>:
  match m:
    case Some{+f}:
      Done{notify.show(f)}
    case None{}:
      Fail{"Invalid event class character. Use 'Ag$lshzxeKEtmdn'."}

def notify.set(v: String) -> Result<&2, &2, String, String>:
  notify.got(notify.read(v, Some{0}))

# bind: at most 16 addresses
def bind.set(+ws: List<&2, String>) -> Result<&2, &2, String, String>:
  Bool.pick(Result<&2, &2, String, String>, Nat.is_lt(16n, List.length(&2, String, ws)), Fail{"Too many bind addresses specified."}, Done{unwords(ws)})

# latency-tracking-info-percentiles: numbers from 0 to 100, read as
# Redis's string2d reads a double and printed as "%f" prints one, with
# its trailing zeros cut. BendKV reads decimal numbers (an optional sign,
# digits with an optional point, an optional exponent of up to three
# digits); "inf" is out of range, and the rest (nan, hex) is invalid.
type PctTok is Data:
  PVal{s: String}
  PBad{}
  PRange{}

type PExp is Data:
  PE{neg: Bool, n: Nat}
  PEBad{}

def pct.inf(+s: String) -> Bool:
  Bool.or(text.same(s, "inf"), text.same(s, "infinity"))

def pct.nan(+s: String) -> Bool:
  String.starts_with(String.to_lower(s), "nan")

def pct.exp.of(neg: Bool, +ds: String) -> PExp:
  Bool.pick(PExp, Bool.and(Bool.and(text.digits(ds), Bool.not(String.is_empty(ds))), Nat.is_le(String.length(ds), 3n)), PE{neg, dec.small(ds, 0n)}, PEBad{})

def pct.exp.sign(t: String) -> PExp:
  match t:
    case SCon{'-', u}:
      pct.exp.of(True{}, u)
    case SCon{'+', u}:
      pct.exp.of(False{}, u)
    case _:
      pct.exp.of(False{}, t)

def pct.exp(r: String) -> PExp:
  match r:
    case SNil{}:
      PE{False{}, 0n}
    case SCon{Chr{+c}, t}:
      Bool.pick(PExp, Bool.or(U32.is_eq(c, 101), U32.is_eq(c, 69)), pct.exp.sign(t), PEBad{})

# the digits after a point, and what follows them
def pct.frac(+r: String) -> String & String:
  match r:
    case SCon{'.', +t}:
      (String.take(t, text.ndigits(t)), String.drop(t, text.ndigits(t)))
    case _:
      ("", r)

def dec.zeros(n: Nat) -> String:
  match n:
    case 0n:
      ""
    case 1n+m:
      "0" ++ dec.zeros(m)

# whether s has a digit other than 0
def dec.nonzero(s: String) -> Bool:
  match s:
    case SNil{}:
      False{}
    case SCon{Chr{+x}, t}:
      Bool.or(U32.is_ne(x, 48), dec.nonzero(t))

# the digits after a point cut of their trailing zeros, and the point
# when nothing follows it
def pct.trim(s: String) -> String:
  match s:
    case SCon{'0', t}:
      pct.trim(t)
    case SCon{'.', t}:
      t
    case _:
      s

def pct.show(+n: Nat) -> String:
  String.reverse(pct.trim(String.reverse(Nat.show(Nat.div(n, 1000000n)) ++ "." ++ String.drop(Nat.show(Nat.add(1000000n, Nat.mod(n, 1000000n))), 1n))))

# a value of digits d times 10^(p-q), times 10^6 and rounded half up, when
# it is from 0 to 100: k digits are cut, the first of them decides the
# rounding, the others whether the value is past 100.000000
def pct.cut(+d: String, +k: Nat) -> Nat & (Nat & Bool):
  Bool.pick(Nat & (Nat & Bool), Nat.is_le(k, String.length(d)),
    (dec.small(String.take(d, Nat.sub(String.length(d), k)), 0n), (dec.small(String.take(String.drop(d, Nat.sub(String.length(d), k)), 1n), 0n), dec.nonzero(String.drop(d, Nat.sub(String.length(d), k))))),
    (0n, (0n, dec.nonzero(d))))

def pct.fin(+neg: Bool, +zero: Bool, c: Nat & (Nat & Bool)) -> PctTok:
  (f, rr) = c
  (r1, rest) = rr
  +fl = f
  Bool.pick(PctTok, Bool.and(neg, Bool.not(zero)), PRange{},
    Bool.pick(PctTok, Bool.or(Nat.is_lt(100000000n, fl), Bool.and(Nat.is_eq(fl, 100000000n), rest)), PRange{},
      PVal{Bool.pick(String, neg, "-", "") ++ pct.show(Nat.add(fl, Bool.pick(Nat, Nat.is_le(5n, r1), 1n, 0n)))}))

def pct.val(neg: Bool, +d: String, +p: Nat, +q: Nat) -> PctTok:
  Bool.pick(PctTok, Bool.and(dec.nonzero(d), Nat.is_lt(Nat.add(q, 3n), Nat.add(String.length(d), p))), PRange{},
    pct.fin(neg, Bool.not(dec.nonzero(d)),
      Bool.pick(Nat & (Nat & Bool), Nat.is_le(q, Nat.add(p, 6n)),
        (dec.small(d ++ dec.zeros(Nat.sub(Nat.add(p, 6n), q)), 0n), (0n, False{})),
        pct.cut(d, Nat.sub(q, Nat.add(p, 6n))))))

def pct.num3(neg: Bool, +i: String, +f: String, e: PExp) -> PctTok:
  match e:
    case PEBad{}:
      PBad{}
    case PE{+en, +n}:
      Bool.pick(PctTok, Bool.and(String.is_empty(i), String.is_empty(f)), PBad{},
        pct.val(neg, dec.trim(i ++ f), Bool.pick(Nat, en, 0n, n), Nat.add(String.length(f), Bool.pick(Nat, en, n, 0n))))

def pct.num2(neg: Bool, +i: String, fr: String & String) -> PctTok:
  (f, r) = fr
  pct.num3(neg, i, f, pct.exp(r))

def pct.num(neg: Bool, +u: String) -> PctTok:
  pct.num2(neg, String.take(u, text.ndigits(u)), pct.frac(String.drop(u, text.ndigits(u))))

def pct.unsigned(neg: Bool, +u: String) -> PctTok:
  Bool.pick(PctTok, pct.inf(u), PRange{}, Bool.pick(PctTok, pct.nan(u), PBad{}, pct.num(neg, u)))

def pct.tok(+t: String) -> PctTok:
  match t:
    case SCon{'-', u}:
      pct.unsigned(True{}, u)
    case SCon{'+', u}:
      pct.unsigned(False{}, u)
    case _:
      pct.unsigned(False{}, t)

def pct.toks(ws: List<&2, String>) -> List<&2, PctTok>:
  match ws:
    case Nil{}:
      Nil{}
    case Con{+w, rest}:
      pct.tok(w) <> pct.toks(rest)

def pct.cons(x: String, r: Result<&2, &2, String, List<&2, String>>) -> Result<&2, &2, String, List<&2, String>>:
  match r:
    case Done{xs}:
      Done{x <> xs}
    case Fail{e}:
      Fail{e}

def pct.collect(ts: List<&2, PctTok>) -> Result<&2, &2, String, List<&2, String>>:
  match ts:
    case Nil{}:
      Done{Nil{}}
    case Con{PBad{}, rest}:
      Fail{"Invalid latency-tracking-info-percentiles parameters"}
    case Con{PRange{}, rest}:
      Fail{"latency-tracking-info-percentiles parameters should sit between [0.0,100.0]"}
    case Con{PVal{x}, rest}:
      pct.cons(x, pct.collect(rest))

def pct.got(r: Result<&2, &2, String, List<&2, String>>) -> Result<&2, &2, String, String>:
  match r:
    case Done{xs}:
      Done{unwords(xs)}
    case Fail{e}:
      Fail{e}

def pct.set(ws: List<&2, String>) -> Result<&2, &2, String, String>:
  pct.got(pct.collect(pct.toks(ws)))

# A value for a parameter
# -----------------------

def spec.set(x: XSpec, +old: String, +v: String) -> Result<&2, &2, String, String>:
  match x:
    case XDir{}:
      Bool.pick(Result<&2, &2, String, String>, String.eq(v, old), Done{old}, Fail{"BendKV cannot change its working directory"})
    case XSave{}:
      save.set(words(v))
    case XObuf{}:
      obuf.set(words(v), old)
    case XOom{}:
      oom.set(words(v))
    case XNotify{}:
      notify.set(v)
    case XBind{}:
      bind.set(words(v))
    case XReplicaof{}:
      Done{v}
    case XPct{}:
      pct.set(words(v))

def num.min(+m: String, r: Result<&2, &2, String, String>) -> Result<&2, &2, String, String>:
  match r:
    case Done{+n}:
      Done{Bool.pick(String, dec.sle(m, n), n, m)}
    case Fail{e}:
      Fail{e}

def ty.num(app: CApp, fmt: NumFmt, +v: String, +lo: String, +hi: String) -> Result<&2, &2, String, String>:
  match app:
    case AppHz{}:
      num.hz(num.set(fmt, v, lo, hi))
    case AppMin{m}:
      num.min(m, num.set(fmt, v, lo, hi))
    case _:
      num.set(fmt, v, lo, hi)

def ty.set(ty: CTy, app: CApp, +old: String, +v: String) -> Result<&2, &2, String, String>:
  match ty:
    case CBool{vet}:
      bool.set(vet, v)
    case CEnum{names, vals, bits, vet}:
      enum.set(names, vals, bits, vet, v)
    case CNum{signed, lo, hi, fmt}:
      ty.num(app, fmt, v, lo, hi)
    case CStr{null, vet}:
      str.set(vet, v)
    case CSpec{x}:
      spec.set(x, old, v)

def item.set(it: CItem, +v: String) -> Result<&2, &2, String, String>:
  match it:
    case CItem{CParam{name, alias, imm, hidden, prot, multi, ty, app}, old}:
      ty.set(ty, app, old, v)

# A value at the start
# --------------------
# A line of the configuration file, or an option of the command line,
# sets a parameter as CONFIG SET does, with the differences Redis has: a
# parameter of several words takes the words of the line as they are
# (CONFIG SET splits its value at each space); nothing is done with the
# new value but hz's cap; and the immutable and protected parameters may
# be set too. startup.bend reads the lines; dir and save's pairs added to
# the ones before are its own.

# replicaof: "no one", or a host and a port, read as strtol reads one
def replicaof.port(+h: String, m: Maybe<&2, String>) -> Result<&2, &2, String, String>:
  match m:
    case Some{+p}:
      Bool.pick(Result<&2, &2, String, String>, Bool.and(dec.sle("0", p), dec.sle(p, "65535")), Done{h ++ " " ++ p}, Fail{"Invalid master port"})
    case None{}:
      Fail{"Invalid master port"}

def replicaof.load(ws: List<&2, String>) -> Result<&2, &2, String, String>:
  match ws:
    case Con{+h, Con{+p, Nil{}}}:
      Bool.pick(Result<&2, &2, String, String>, Bool.and(text.same(h, "no"), text.same(p, "one")), Done{""}, replicaof.port(h, ll.loose(p)))
    case _:
      Fail{"wrong number of arguments"}

# one empty word is no words, for the parameters Redis reads so
def words.none(ws: List<&2, String>) -> List<&2, String>:
  match ws:
    case Con{SNil{}, Nil{}}:
      Nil{}
    case other:
      other

def spec.load(x: XSpec, +old: String, ws: List<&2, String>) -> Result<&2, &2, String, String>:
  match x:
    case XDir{}:
      Done{old}
    case XSave{}:
      save.set(words.none(ws))
    case XObuf{}:
      obuf.set(ws, old)
    case XOom{}:
      oom.set(ws)
    case XNotify{}:
      notify.set(unwords(ws))
    case XBind{}:
      bind.set(words.none(ws))
    case XReplicaof{}:
      replicaof.load(ws)
    case XPct{}:
      pct.set(words.none(ws))

# what a new value does at the start: hz is capped, the rest is kept
def app.load(app: CApp) -> CApp:
  match app:
    case AppHz{}:
      AppHz{}
    case _:
      AppNone{}

def ty.load(ty: CTy, app: CApp, +old: String, ws: List<&2, String>) -> Result<&2, &2, String, String>:
  match ty:
    case CEnum{+names, +vals, +bits, vet}:
      enum.got(enum.read(ws, names, vals), names, vals, bits, vet)
    case CSpec{x}:
      spec.load(x, old, ws)
    case other:
      ty.set(other, app.load(app), old, unwords(ws))

# the value a parameter takes from the words after its name: one word,
# but for a parameter of several
def item.load(it: CItem, ws: List<&2, String>) -> Result<&2, &2, String, String>:
  match it:
    case CItem{CParam{name, alias, imm, hidden, prot, multi, ty, app}, old}:
      ty.load(ty, app, old, ws)

# whether a parameter's value is words
def item.multi(+it: CItem) -> Bool:
  match it:
    case CItem{CParam{name, alias, imm, hidden, prot, multi, ty, app}, v}:
      multi

# Parameters by name
# ------------------

def item.name(+it: CItem) -> String:
  match it:
    case CItem{CParam{name, alias, imm, hidden, prot, multi, ty, app}, v}:
      name

def item.val(+it: CItem) -> String:
  match it:
    case CItem{p, v}:
      v

# whether a parameter is called lname (in lower case), by its name or by
# its other one
def item.is(+lname: String, +it: CItem) -> Bool:
  match it:
    case CItem{CParam{+name, +alias, imm, hidden, prot, multi, ty, app}, v}:
      Bool.or(String.eq(lname, name), Bool.and(Bool.not(String.is_empty(alias)), String.eq(lname, alias)))

# whether the first parameter is called lname
def item.head_is(+lname: String, +items: List<&2, CItem>) -> Bool:
  match items:
    case Con{+it, rest}:
      item.is(lname, it)
    case Nil{}:
      False{}

# the first parameter called lname: hit says whether the first of items
# is, so that the search stops there (a Bool.pick would go on to the end)
def item.find.go(items: List<&2, CItem>, +lname: String, hit: Bool) -> Maybe<&2, CItem>:
  match items hit:
    case Con{it, rest} True{}:
      Some{it}
    case Con{it, +rest} False{}:
      item.find.go(rest, lname, item.head_is(lname, rest))
    case Nil{} _:
      None{}

def item.find(+items: List<&2, CItem>, +lname: String) -> Maybe<&2, CItem>:
  item.find.go(items, lname, item.head_is(lname, items))

def item.val_of(m: Maybe<&2, CItem>) -> String:
  match m:
    case Some{+it}:
      item.val(it)
    case None{}:
      ""

# a parameter's value, by its name in lower case ("" for none)
def config.get_value(+items: List<&2, CItem>, +name: String) -> String:
  item.val_of(item.find(items, name))

# the parameters with one of them set to nv
def items.put(items: List<&2, CItem>, +name: String, +nv: String) -> List<&2, CItem>:
  match items:
    case Nil{}:
      Nil{}
    case Con{CItem{CParam{+n, a, i, h, pr, m, t, ap}, v}, rest}:
      CItem{CParam{n, a, i, h, pr, m, t, ap}, Bool.pick(String, String.eq(n, name), nv, v)} <> items.put(rest, name, nv)

# CONFIG GET
# ----------
# The keys matched so far, newest first: as the client spelled an exact
# name, or as the table spells a matched one, with the value. Redis keeps
# them in a dict that compares keys case aside and sends them in its
# hash order; BendKV sends them in the order they matched.

type Got is Data:
  Got{k: String, lk: String, v: String}

def got.has(gs: List<&2, Got>, +lk: String) -> Bool:
  match gs:
    case Nil{}:
      False{}
    case Con{Got{k, +l, v}, rest}:
      Bool.or(String.eq(l, lk), got.has(rest, lk))

def got.add(ok: Bool, k: String, lk: String, v: String, gs: List<&2, Got>) -> List<&2, Got>:
  match ok:
    case True{}:
      Got{k, lk, v} <> gs
    case False{}:
      gs

def got.found(m: Maybe<&2, CItem>, +a: String, gs: List<&2, Got>) -> List<&2, Got>:
  match m:
    case Some{+it}:
      Got{a, String.to_lower(a), item.val(it)} <> gs
    case None{}:
      gs

# a name: the parameter of that name, hidden or not, unless its key is in
def get.exact(+items: List<&2, CItem>, +a: String, +gs: List<&2, Got>) -> List<&2, Got>:
  Bool.pick(List<&2, Got>, got.has(gs, String.to_lower(a)), gs, got.found(item.find(items, String.to_lower(a)), a, gs))

# a pattern on a parameter that is not hidden: its name and its other
# name, each a key of its own in Redis's table of names
def get.keys(+pat: String, +name: String, +alias: String, +v: String, +gs: List<&2, Got>) -> List<&2, Got>:
  +g1 = got.add(Bool.and(Bool.not(got.has(gs, name)), stringmatch(pat, name, True{})), name, name, v, gs)
  got.add(Bool.and(Bool.not(String.is_empty(alias)), Bool.and(Bool.not(got.has(g1, alias)), stringmatch(pat, alias, True{}))), alias, alias, v, g1)

def get.item(+pat: String, it: CItem, +gs: List<&2, Got>) -> List<&2, Got>:
  match it:
    case CItem{CParam{name, alias, imm, hidden, prot, multi, ty, app}, v}:
      Bool.pick(List<&2, Got>, hidden, gs, get.keys(pat, name, alias, v, gs))

def get.pat(items: List<&2, CItem>, +pat: String, gs: List<&2, Got>) -> List<&2, Got>:
  match items:
    case Nil{}:
      gs
    case Con{it, rest}:
      get.pat(rest, pat, get.item(pat, it, gs))

def get.one(pat: Bool, +items: List<&2, CItem>, +a: String, gs: List<&2, Got>) -> List<&2, Got>:
  match pat:
    case True{}:
      get.pat(items, a, gs)
    case False{}:
      get.exact(items, a, gs)

def get.args(args: List<&2, String>, +items: List<&2, CItem>, gs: List<&2, Got>) -> List<&2, Got>:
  match args:
    case Nil{}:
      gs
    case Con{+a, rest}:
      get.args(rest, items, get.one(is_pattern(a), items, a, gs))

def get.reply(gs: List<&2, Got>, acc: List<&2, R.Reply>) -> List<&2, R.Reply>:
  match gs:
    case Nil{}:
      acc
    case Con{Got{k, lk, v}, rest}:
      get.reply(rest, R.RBulk{k} <> (R.RBulk{v} <> acc))

# CONFIG GET parameter [parameter ...]: a flat list of keys and values
def config.get(args: List<&2, String>, +items: List<&2, CItem>) -> R.Reply:
  R.RArray{get.reply(get.args(args, items, Nil{}), Nil{})}

# CONFIG SET
# ----------
# As Redis runs it: first every name is looked up (an unknown one, one
# that cannot change, a protected one and one named twice fail, the first
# of them in order); then every value is checked, in order; then what the
# new values do is done, in order of the parameters (only a new port,
# address, TLS or append-only setting fails). A failure anywhere leaves
# every parameter as it was.

def e.set(+name: String, +why: String) -> String:
  R.no_newlines("ERR CONFIG SET failed (possibly related to argument '" ++ name ++ "') - " ++ why)

# a name looked up: unknown, refused (immutable, protected, or named twice:
# Redis keeps a parameter's other name as a parameter of its own, so a
# name and its other name are not the same twice), or the parameter, the
# name it was found by (its spelling in the table) and the new value
type Look is Data:
  LUnknown{name: String}
  LDeny{name: String, why: String}
  LOk{it: CItem, key: String, v: String}

def look.deny(imm: Bool, prot: Bool, +dup: Bool, +n: String, ok: Look) -> Look:
  match imm prot:
    case True{} _:
      LDeny{n, "can't set immutable config"}
    case False{} True{}:
      LDeny{n, "can't set protected config"}
    case False{} False{}:
      Bool.pick(Look, dup, LDeny{n, "duplicate parameter"}, ok)

def look.it(it: CItem, +n: String, v: String, +seen: List<&2, String>, +prot_ok: Bool) -> Look:
  match it:
    case CItem{CParam{name, alias, +imm, hidden, +prot, multi, ty, app}, old}:
      look.deny(imm, Bool.and(prot, Bool.not(prot_ok)), text.member(seen, String.to_lower(n)), n, LOk{CItem{CParam{name, alias, imm, hidden, prot, multi, ty, app}, old}, String.to_lower(n), v})

def look.mk(f: Maybe<&2, CItem>, +n: String, v: String, +seen: List<&2, String>, +prot_ok: Bool) -> Look:
  match f:
    case None{}:
      LUnknown{n}
    case Some{it}:
      look.it(it, n, v, seen, prot_ok)

def looks(args: List<&2, String>, +seen: List<&2, String>, +items: List<&2, CItem>, +prot_ok: Bool) -> List<&2, Look>:
  match args:
    case Con{+n, Con{v, rest}}:
      look.mk(item.find(items, String.to_lower(n)), n, v, seen, prot_ok) <> looks(rest, String.to_lower(n) <> seen, items, prot_ok)
    case _:
      Nil{}

def looks.err(ls: List<&2, Look>) -> Maybe<&2, String>:
  match ls:
    case Nil{}:
      None{}
    case Con{LUnknown{n}, rest}:
      Some{R.no_newlines("ERR Unknown option or number of arguments for CONFIG SET - '" ++ n ++ "'")}
    case Con{LDeny{n, why}, rest}:
      Some{e.set(n, why)}
    case Con{LOk{it, k, v}, rest}:
      looks.err(rest)

# the values checked: the parameter with its old value, the name it was
# found by and the new value; or the error
type Val is Data:
  VOk{it: CItem, key: String, nv: String}
  VErr{msg: String}

def val.mk(r: Result<&2, &2, String, String>, it: CItem, +key: String) -> Val:
  match r:
    case Done{nv}:
      VOk{it, key, nv}
    case Fail{e}:
      VErr{e.set(key, e)}

def vals(ls: List<&2, Look>) -> List<&2, Val>:
  match ls:
    case Nil{}:
      Nil{}
    case Con{LOk{+it, +k, +v}, rest}:
      val.mk(item.set(it, v), it, k) <> vals(rest)
    case Con{l, rest}:
      vals(rest)

def vals.err(vs: List<&2, Val>) -> Maybe<&2, String>:
  match vs:
    case Nil{}:
      None{}
    case Con{VErr{m}, rest}:
      Some{m}
    case Con{VOk{it, k, nv}, rest}:
      vals.err(rest)

# a new value that cannot be applied: one that changes a fixed parameter
def fixed.of(app: CApp, +key: String, same: Bool) -> Maybe<&2, String>:
  match app same:
    case AppFixed{msg} False{}:
      Some{e.set(key, msg)}
    case _ _:
      None{}

def fixed.err(it: CItem, +key: String, +nv: String) -> Maybe<&2, String>:
  match it:
    case CItem{CParam{name, alias, imm, hidden, prot, multi, ty, app}, +old}:
      fixed.of(app, key, String.eq(old, nv))

def fixed.first(vs: List<&2, Val>) -> Maybe<&2, String>:
  match vs:
    case Nil{}:
      None{}
    case Con{VOk{+it, +k, +nv}, rest}:
      Maybe.or(&2, String, fixed.err(it, k, nv), fixed.first(rest))
    case Con{VErr{m}, rest}:
      fixed.first(rest)

def vals.apply(vs: List<&2, Val>, items: List<&2, CItem>) -> List<&2, CItem>:
  match vs:
    case Nil{}:
      items
    case Con{VOk{+it, k, nv}, rest}:
      vals.apply(rest, items.put(items, item.name(it), nv))
    case Con{VErr{m}, rest}:
      vals.apply(rest, items)

def set.fixed(e: Maybe<&2, String>, vs: List<&2, Val>, items: List<&2, CItem>) -> Result<&2, &2, R.Reply, List<&2, CItem>>:
  match e:
    case Some{m}:
      Fail{R.RError{m}}
    case None{}:
      Done{vals.apply(vs, items)}

def set.valued(e: Maybe<&2, String>, +vs: List<&2, Val>, items: List<&2, CItem>) -> Result<&2, &2, R.Reply, List<&2, CItem>>:
  match e:
    case Some{m}:
      Fail{R.RError{m}}
    case None{}:
      set.fixed(fixed.first(vs), vs, items)

def set.vals(+vs: List<&2, Val>, items: List<&2, CItem>) -> Result<&2, &2, R.Reply, List<&2, CItem>>:
  set.valued(vals.err(vs), vs, items)

def set.looked(e: Maybe<&2, String>, ls: List<&2, Look>, items: List<&2, CItem>) -> Result<&2, &2, R.Reply, List<&2, CItem>>:
  match e:
    case Some{m}:
      Fail{R.RError{m}}
    case None{}:
      set.vals(vals(ls), items)

# whether a protected parameter may change: enable-protected-configs is
# yes, or local (BendKV's clients are all on the loopback)
def prot_ok(+items: List<&2, CItem>) -> Bool:
  Bool.not(String.eq(config.get_value(items, "enable-protected-configs"), "no"))

def set.go(+ls: List<&2, Look>, items: List<&2, CItem>) -> Result<&2, &2, R.Reply, List<&2, CItem>>:
  set.looked(looks.err(ls), ls, items)

# CONFIG SET name value [name value ...] (an even number of arguments):
# the error, or the parameters after it
def config.set(args: List<&2, String>, +items: List<&2, CItem>) -> Result<&2, &2, R.Reply, List<&2, CItem>>:
  set.go(looks(args, Nil{}, items, prot_ok(items)), items)

def config.set.reply(r: Result<&2, &2, R.Reply, List<&2, CItem>>) -> R.Reply:
  match r:
    case Fail{e}:
      e
    case Done{items}:
      R.r_ok()

def config.set.items(r: Result<&2, &2, R.Reply, List<&2, CItem>>, items: List<&2, CItem>) -> List<&2, CItem>:
  match r:
    case Fail{e}:
      items
    case Done{new}:
      new
