# command.bend: COMMAND, as Redis 7.0.15 answers it, about the commands
# BendKV has: their descriptions (COMMAND and COMMAND INFO), their
# documentation (COMMAND DOCS), how many they are (COUNT), their names
# (LIST, with Redis's filters) and the keys of a command line (GETKEYS,
# GETKEYSANDFLAGS). A command with subcommands lists the ones BendKV has.
# Each description is Redis's own: the table below is written by
# tools/gen_commands.py from what Redis answers (Redis builds it at its
# start from src/commands/*.json). Redis lists commands in the order of a
# hash table with a random seed; BendKV lists them by name.

import Base
import ./redis.bend as R

# Types
# -----

# a key specification of a range (the only kind BendKV's commands have):
# its flags, the index of its first key, the last key (from the first
# one, or counted from the end when negative), the step between keys, and
# the limit of a range to the end; or of a range from the word after a
# keyword, the first one from an index on (KSpecKw: GEORADIUS's STORE and
# STOREDIST)
type KSpec is Data:
  KSpec{flags: List<&2, String>, pos: Nat, last: R.Int, step: Nat, limit: Nat}
  KSpecKw{flags: List<&2, String>, kw: String, from: Nat, last: R.Int, step: Nat, limit: Nat}

# how COMMAND GETKEYS finds a command's keys: from its key specs, or as
# the function Redis has for SET (whose key's flags depend on its GET) or
# BITFIELD (on its subcommands), or for EVAL, LMPOP (and ZMPOP), BLMPOP
# (and BZMPOP), SINTERCARD (and ZUNION, ZINTER, ZDIFF, ZINTERCARD) and
# ZUNIONSTORE (and ZINTERSTORE, ZDIFFSTORE), whose spec counts their keys
# with an argument, and whose function reads them when the spec does not,
# or for SORT and SORT_RO, whose patterns name keys of their own, and
# SORT's STORE may come anywhere among its options
type KWay is Data:
  KBySpecs{}
  KBySet{}
  KByBitfield{}
  KByEval{}
  KByLmpop{}
  KBySintercard{}
  KByZstore{}
  KByBlmpop{}
  KBySort{}
  KBySortRo{}

# a command or a subcommand: its full name ("client|id" for a
# subcommand), its arity, its ACL categories, its key specs, how its keys
# are found, whether it may have none (no_mandatory_keys), and the
# entries Redis gives it in COMMAND INFO (the first nine; the tenth is
# its subcommands) and in COMMAND DOCS (all but its subcommands)
type Desc is Data:
  Desc{name: String, arity: R.Int, cats: List<&2, String>, specs: List<&2, KSpec>, way: KWay, nokeys: Bool, info: List<&2, R.Reply>, docs: List<&2, R.Reply>}

# a command with the subcommands BendKV has, by name
type Top is Data:
  Top{cmd: Desc, subs: List<&2, Desc>}

# a command that only reads: its arity, its key specs and how its keys
# are found, as its description has them, for the keys a call of it read
# (ro.key, below)
type Ro is Data:
  Ro{arity: R.Int, specs: List<&2, KSpec>, way: KWay}

# The table
# ---------

# BEGIN gen_commands: table
def cmd.acl() -> Top:
  Top{Desc{"acl", R.INeg{1n}, ["slow"], [], KBySpecs{}, False{},
    [R.RBulk{"acl"}, R.RInt{R.INeg{1n}}, R.RSet{[]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"A container for Access List Control commands "}, R.RBulk{"since"}, R.RBulk{"6.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"Depends on subcommand."}]},
  [Desc{"acl|cat", R.INeg{1n}, ["slow"], [], KBySpecs{}, False{},
    [R.RBulk{"acl|cat"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"List the ACL categories or the commands inside a category"}, R.RBulk{"since"}, R.RBulk{"6.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1) since the categories and commands are a fixed set."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"categoryname"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]}, Desc{"acl|deluser", R.INeg{2n}, ["admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"acl|deluser"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Remove the specified ACL users and the associated rules"}, R.RBulk{"since"}, R.RBulk{"6.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1) amortized time considering the typical user."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"username"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]}, Desc{"acl|dryrun", R.INeg{3n}, ["admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"acl|dryrun"}, R.RInt{R.INeg{3n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Returns whether the user can execute the given command without executing the command."}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"username"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"command"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"arg"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}, R.RStatus{"multiple"}]}]}]}]}, Desc{"acl|genpass", R.INeg{1n}, ["slow"], [], KBySpecs{}, False{},
    [R.RBulk{"acl|genpass"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Generate a pseudorandom secure password to use for ACL users"}, R.RBulk{"since"}, R.RBulk{"6.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"bits"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]}, Desc{"acl|getuser", R.IPos{3n}, ["admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"acl|getuser"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the rules for a specific ACL user"}, R.RBulk{"since"}, R.RBulk{"6.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N). Where N is the number of password, command and pattern rules that the user has."}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"6.2.0"}, R.RBulk{"Added Pub/Sub channel patterns."}]}, R.RArray{[R.RBulk{"7.0.0"}, R.RBulk{"Added selectors and changed the format of key and channel patterns from a list to their rule representation."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"username"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]}, Desc{"acl|help", R.IPos{2n}, ["slow"], [], KBySpecs{}, False{},
    [R.RBulk{"acl|help"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Show helpful text about the different subcommands"}, R.RBulk{"since"}, R.RBulk{"6.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"acl|list", R.IPos{2n}, ["admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"acl|list"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"List the current ACL rules in ACL config file format"}, R.RBulk{"since"}, R.RBulk{"6.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N). Where N is the number of configured users."}]}, Desc{"acl|load", R.IPos{2n}, ["admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"acl|load"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Reload the ACLs from the configured ACL file"}, R.RBulk{"since"}, R.RBulk{"6.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N). Where N is the number of configured users."}]}, Desc{"acl|log", R.INeg{1n}, ["admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"acl|log"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"List latest events denied because of ACLs in place"}, R.RBulk{"since"}, R.RBulk{"6.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N) with N being the number of entries shown."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"operation"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"reset"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"RESET"}]}]}]}]}]}, Desc{"acl|save", R.IPos{2n}, ["admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"acl|save"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Save the current ACL rules in the configured ACL file"}, R.RBulk{"since"}, R.RBulk{"6.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N). Where N is the number of configured users."}]}, Desc{"acl|setuser", R.INeg{2n}, ["admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"acl|setuser"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Modify or create the rules for a specific ACL user"}, R.RBulk{"since"}, R.RBulk{"6.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N). Where N is the number of rules provided."}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"6.2.0"}, R.RBulk{"Added Pub/Sub channel patterns."}]}, R.RArray{[R.RBulk{"7.0.0"}, R.RBulk{"Added selectors and key based permissions."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"username"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"rule"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}, R.RStatus{"multiple"}]}]}]}]}, Desc{"acl|users", R.IPos{2n}, ["admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"acl|users"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"List the username of all the configured ACL rules"}, R.RBulk{"since"}, R.RBulk{"6.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N). Where N is the number of configured users."}]}, Desc{"acl|whoami", R.IPos{2n}, ["slow"], [], KBySpecs{}, False{},
    [R.RBulk{"acl|whoami"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Return the name of the user associated to the current connection"}, R.RBulk{"since"}, R.RBulk{"6.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}]}

def cmd.append() -> Top:
  Top{Desc{"append", R.IPos{3n}, ["write", "string", "fast"], [KSpec{["RW", "insert"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"append"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@string"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"insert"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Append a value to a key"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(1). The amortized time complexity is O(1) assuming the appended value is small and the already present value is of any size, since the dynamic string library used by Redis will double the free space available on every reallocation."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"value"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]},
  []}

def cmd.auth() -> Top:
  Top{Desc{"auth", R.INeg{1n}, ["fast", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"auth"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}, R.RStatus{"fast"}, R.RStatus{"no_auth"}, R.RStatus{"allow_busy"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@fast"}, R.RStatus{"@connection"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Authenticate to the server"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of passwords defined for the user"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"6.0.0"}, R.RBulk{"Added ACL style (username and password)."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"username"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"since"}, R.RBulk{"6.0.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"password"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]},
  []}

def cmd.bgrewriteaof() -> Top:
  Top{Desc{"bgrewriteaof", R.IPos{1n}, ["admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"bgrewriteaof"}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"no_async_loading"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Asynchronously rewrite the append-only file"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]},
  []}

def cmd.bgsave() -> Top:
  Top{Desc{"bgsave", R.INeg{0n}, ["admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"bgsave"}, R.RInt{R.INeg{0n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"no_async_loading"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Asynchronously save the dataset to disk"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"3.2.2"}, R.RBulk{"Added the `SCHEDULE` option."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"schedule"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"SCHEDULE"}, R.RBulk{"since"}, R.RBulk{"3.2.2"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.bitcount() -> Top:
  Top{Desc{"bitcount", R.INeg{1n}, ["read", "bitmap", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"bitcount"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@bitmap"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Count set bits in a string"}, R.RBulk{"since"}, R.RBulk{"2.6.0"}, R.RBulk{"group"}, R.RBulk{"bitmap"}, R.RBulk{"complexity"}, R.RBulk{"O(N)"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"7.0.0"}, R.RBulk{"Added the `BYTE|BIT` option."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"index"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"start"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"end"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"index_unit"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"byte"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"BYTE"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"bit"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"BIT"}]}]}]}]}]}]}]},
  []}

def cmd.bitfield() -> Top:
  Top{Desc{"bitfield", R.INeg{1n}, ["write", "bitmap", "slow"], [KSpec{["RW", "access", "update", "variable_flags"], 1n, R.IPos{0n}, 1n, 0n}], KByBitfield{}, False{},
    [R.RBulk{"bitfield"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@bitmap"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"notes"}, R.RBulk{"This command allows both access and modification of the key"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"update"}, R.RStatus{"variable_flags"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Perform arbitrary bitfield integer operations on strings"}, R.RBulk{"since"}, R.RBulk{"3.2.0"}, R.RBulk{"group"}, R.RBulk{"bitmap"}, R.RBulk{"complexity"}, R.RBulk{"O(1) for each subcommand specified"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"operation"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}, R.RStatus{"multiple"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"encoding_offset"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"token"}, R.RBulk{"GET"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"encoding"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"offset"}, R.RBulk{"type"}, R.RBulk{"integer"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"write"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"wrap_sat_fail"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"token"}, R.RBulk{"OVERFLOW"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"wrap"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"WRAP"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"sat"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"SAT"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"fail"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"FAIL"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"write_operation"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"encoding_offset_value"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"token"}, R.RBulk{"SET"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"encoding"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"offset"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"value"}, R.RBulk{"type"}, R.RBulk{"integer"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"encoding_offset_increment"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"token"}, R.RBulk{"INCRBY"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"encoding"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"offset"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"increment"}, R.RBulk{"type"}, R.RBulk{"integer"}]}]}]}]}]}]}]}]}]}]}]},
  []}

def cmd.bitfield_ro() -> Top:
  Top{Desc{"bitfield_ro", R.INeg{1n}, ["read", "bitmap", "fast"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"bitfield_ro"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@bitmap"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Perform arbitrary bitfield integer operations on strings. Read-only variant of BITFIELD"}, R.RBulk{"since"}, R.RBulk{"6.0.0"}, R.RBulk{"group"}, R.RBulk{"bitmap"}, R.RBulk{"complexity"}, R.RBulk{"O(1) for each subcommand specified"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"encoding_offset"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"token"}, R.RBulk{"GET"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}, R.RStatus{"multiple"}, R.RStatus{"multiple_token"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"encoding"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"offset"}, R.RBulk{"type"}, R.RBulk{"integer"}]}]}]}]}]},
  []}

def cmd.bitop() -> Top:
  Top{Desc{"bitop", R.INeg{3n}, ["write", "bitmap", "slow"], [KSpec{["OW", "update"], 2n, R.IPos{0n}, 1n, 0n}, KSpec{["RO", "access"], 3n, R.INeg{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"bitop"}, R.RInt{R.INeg{3n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}]}, R.RInt{R.IPos{2n}}, R.RInt{R.INeg{0n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@bitmap"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"OW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}, R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{3n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.INeg{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Perform bitwise operations between strings"}, R.RBulk{"since"}, R.RBulk{"2.6.0"}, R.RBulk{"group"}, R.RBulk{"bitmap"}, R.RBulk{"complexity"}, R.RBulk{"O(N)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"operation"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"destkey"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{1n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.bitpos() -> Top:
  Top{Desc{"bitpos", R.INeg{2n}, ["read", "bitmap", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"bitpos"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@bitmap"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Find first bit set or clear in a string"}, R.RBulk{"since"}, R.RBulk{"2.8.7"}, R.RBulk{"group"}, R.RBulk{"bitmap"}, R.RBulk{"complexity"}, R.RBulk{"O(N)"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"7.0.0"}, R.RBulk{"Added the `BYTE|BIT` option."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"bit"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"index"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"start"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"end_index"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"end"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"index_unit"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"byte"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"BYTE"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"bit"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"BIT"}]}]}]}]}]}]}]}]}]},
  []}

def cmd.blmove() -> Top:
  Top{Desc{"blmove", R.IPos{6n}, ["write", "list", "slow", "blocking"], [KSpec{["RW", "access", "delete"], 1n, R.IPos{0n}, 1n, 0n}, KSpec{["RW", "insert"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"blmove"}, R.RInt{R.IPos{6n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"noscript"}, R.RStatus{"blocking"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{2n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@list"}, R.RStatus{"@slow"}, R.RStatus{"@blocking"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}, R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"insert"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Pop an element from a list, push it to another list and return it; or block until one is available"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"group"}, R.RBulk{"list"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"source"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"destination"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{1n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"wherefrom"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"left"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"LEFT"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"right"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"RIGHT"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"whereto"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"left"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"LEFT"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"right"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"RIGHT"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"timeout"}, R.RBulk{"type"}, R.RBulk{"double"}]}]}]},
  []}

def cmd.blmpop() -> Top:
  Top{Desc{"blmpop", R.INeg{4n}, ["write", "list", "slow", "blocking"], [], KByBlmpop{}, False{},
    [R.RBulk{"blmpop"}, R.RInt{R.INeg{4n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"blocking"}, R.RStatus{"movablekeys"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@list"}, R.RStatus{"@slow"}, R.RStatus{"@blocking"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"keynum"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"keynumidx"}, R.RInt{R.IPos{0n}}, R.RBulk{"firstkey"}, R.RInt{R.IPos{1n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Pop elements from a list, or block until one is available"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"list"}, R.RBulk{"complexity"}, R.RBulk{"O(N+M) where N is the number of provided keys and M is the number of elements returned."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"timeout"}, R.RBulk{"type"}, R.RBulk{"double"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"numkeys"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"where"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"left"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"LEFT"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"right"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"RIGHT"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"COUNT"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.blpop() -> Top:
  Top{Desc{"blpop", R.INeg{2n}, ["write", "list", "slow", "blocking"], [KSpec{["RW", "access", "delete"], 1n, R.INeg{1n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"blpop"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"noscript"}, R.RStatus{"blocking"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.INeg{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@list"}, R.RStatus{"@slow"}, R.RStatus{"@blocking"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.INeg{1n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Remove and get the first element in a list, or block until one is available"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"list"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of provided keys."}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"6.0.0"}, R.RBulk{"`timeout` is interpreted as a double instead of an integer."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"timeout"}, R.RBulk{"type"}, R.RBulk{"double"}]}]}]},
  []}

def cmd.brpop() -> Top:
  Top{Desc{"brpop", R.INeg{2n}, ["write", "list", "slow", "blocking"], [KSpec{["RW", "access", "delete"], 1n, R.INeg{1n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"brpop"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"noscript"}, R.RStatus{"blocking"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.INeg{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@list"}, R.RStatus{"@slow"}, R.RStatus{"@blocking"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.INeg{1n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Remove and get the last element in a list, or block until one is available"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"list"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of provided keys."}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"6.0.0"}, R.RBulk{"`timeout` is interpreted as a double instead of an integer."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"timeout"}, R.RBulk{"type"}, R.RBulk{"double"}]}]}]},
  []}

def cmd.brpoplpush() -> Top:
  Top{Desc{"brpoplpush", R.IPos{4n}, ["write", "list", "slow", "blocking"], [KSpec{["RW", "access", "delete"], 1n, R.IPos{0n}, 1n, 0n}, KSpec{["RW", "insert"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"brpoplpush"}, R.RInt{R.IPos{4n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"noscript"}, R.RStatus{"blocking"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{2n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@list"}, R.RStatus{"@slow"}, R.RStatus{"@blocking"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}, R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"insert"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Pop an element from a list, push it to another list and return it; or block until one is available"}, R.RBulk{"since"}, R.RBulk{"2.2.0"}, R.RBulk{"group"}, R.RBulk{"list"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"doc_flags"}, R.RSet{[R.RStatus{"deprecated"}]}, R.RBulk{"deprecated_since"}, R.RBulk{"6.2.0"}, R.RBulk{"replaced_by"}, R.RBulk{"`BLMOVE` with the `RIGHT` and `LEFT` arguments"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"6.0.0"}, R.RBulk{"`timeout` is interpreted as a double instead of an integer."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"source"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"destination"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{1n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"timeout"}, R.RBulk{"type"}, R.RBulk{"double"}]}]}]},
  []}

def cmd.bzmpop() -> Top:
  Top{Desc{"bzmpop", R.INeg{4n}, ["write", "sortedset", "slow", "blocking"], [], KByBlmpop{}, False{},
    [R.RBulk{"bzmpop"}, R.RInt{R.INeg{4n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"blocking"}, R.RStatus{"movablekeys"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@sortedset"}, R.RStatus{"@slow"}, R.RStatus{"@blocking"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"keynum"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"keynumidx"}, R.RInt{R.IPos{0n}}, R.RBulk{"firstkey"}, R.RInt{R.IPos{1n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Remove and return members with scores in a sorted set or block until one is available"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(K) + O(M*log(N)) where K is the number of provided keys, N being the number of elements in the sorted set, and M being the number of elements popped."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"timeout"}, R.RBulk{"type"}, R.RBulk{"double"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"numkeys"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"where"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"min"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"MIN"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"max"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"MAX"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"COUNT"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.bzpopmax() -> Top:
  Top{Desc{"bzpopmax", R.INeg{2n}, ["write", "sortedset", "fast", "blocking"], [KSpec{["RW", "access", "delete"], 1n, R.INeg{1n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"bzpopmax"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"noscript"}, R.RStatus{"blocking"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.INeg{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@sortedset"}, R.RStatus{"@fast"}, R.RStatus{"@blocking"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.INeg{1n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Remove and return the member with the highest score from one or more sorted sets, or block until one is available"}, R.RBulk{"since"}, R.RBulk{"5.0.0"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(log(N)) with N being the number of elements in the sorted set."}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"6.0.0"}, R.RBulk{"`timeout` is interpreted as a double instead of an integer."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"timeout"}, R.RBulk{"type"}, R.RBulk{"double"}]}]}]},
  []}

def cmd.bzpopmin() -> Top:
  Top{Desc{"bzpopmin", R.INeg{2n}, ["write", "sortedset", "fast", "blocking"], [KSpec{["RW", "access", "delete"], 1n, R.INeg{1n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"bzpopmin"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"noscript"}, R.RStatus{"blocking"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.INeg{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@sortedset"}, R.RStatus{"@fast"}, R.RStatus{"@blocking"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.INeg{1n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Remove and return the member with the lowest score from one or more sorted sets, or block until one is available"}, R.RBulk{"since"}, R.RBulk{"5.0.0"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(log(N)) with N being the number of elements in the sorted set."}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"6.0.0"}, R.RBulk{"`timeout` is interpreted as a double instead of an integer."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"timeout"}, R.RBulk{"type"}, R.RBulk{"double"}]}]}]},
  []}

def cmd.client() -> Top:
  Top{Desc{"client", R.INeg{1n}, ["slow"], [], KBySpecs{}, False{},
    [R.RBulk{"client"}, R.RInt{R.INeg{1n}}, R.RSet{[]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"A container for client connection commands"}, R.RBulk{"since"}, R.RBulk{"2.4.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"Depends on subcommand."}]},
  [Desc{"client|caching", R.IPos{3n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"client|caching"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Instruct the server about tracking or not keys in the next request"}, R.RBulk{"since"}, R.RBulk{"6.0.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"mode"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"yes"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"YES"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"no"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"NO"}]}]}]}]}]}, Desc{"client|getname", R.IPos{2n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"client|getname"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the current connection name"}, R.RBulk{"since"}, R.RBulk{"2.6.9"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"client|getredir", R.IPos{2n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"client|getredir"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Get tracking notifications redirection client ID if any"}, R.RBulk{"since"}, R.RBulk{"6.0.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"client|help", R.IPos{2n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"client|help"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Show helpful text about the different subcommands"}, R.RBulk{"since"}, R.RBulk{"5.0.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"client|id", R.IPos{2n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"client|id"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Returns the client ID for the current connection"}, R.RBulk{"since"}, R.RBulk{"5.0.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"client|info", R.IPos{2n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"client|info"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RSet{[R.RBulk{"nondeterministic_output"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Returns information about the current client connection."}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"client|kill", R.INeg{2n}, ["admin", "slow", "dangerous", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"client|kill"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}, R.RStatus{"@connection"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Kill the connection of a client"}, R.RBulk{"since"}, R.RBulk{"2.4.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of client connections"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"2.8.12"}, R.RBulk{"Added new filter format."}]}, R.RArray{[R.RBulk{"2.8.12"}, R.RBulk{"`ID` option."}]}, R.RArray{[R.RBulk{"3.2.0"}, R.RBulk{"Added `master` type in for `TYPE` option."}]}, R.RArray{[R.RBulk{"5.0.0"}, R.RBulk{"Replaced `slave` `TYPE` with `replica`. `slave` still supported for backward compatibility."}]}, R.RArray{[R.RBulk{"6.2.0"}, R.RBulk{"`LADDR` option."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"filter"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"ip:port"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"deprecated_since"}, R.RBulk{"2.8.12"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"new-format"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"client-id"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"ID"}, R.RBulk{"since"}, R.RBulk{"2.8.12"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"normal_master_slave_pubsub"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"token"}, R.RBulk{"TYPE"}, R.RBulk{"since"}, R.RBulk{"2.8.12"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"normal"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"NORMAL"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"master"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"MASTER"}, R.RBulk{"since"}, R.RBulk{"3.2.0"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"slave"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"SLAVE"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"replica"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"REPLICA"}, R.RBulk{"since"}, R.RBulk{"5.0.0"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"pubsub"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"PUBSUB"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"username"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"token"}, R.RBulk{"USER"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"ip:port"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"token"}, R.RBulk{"ADDR"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"ip:port"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"token"}, R.RBulk{"LADDR"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"yes/no"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"token"}, R.RBulk{"SKIPME"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]}]}]}]}]}, Desc{"client|list", R.INeg{1n}, ["admin", "slow", "dangerous", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"client|list"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}, R.RStatus{"@connection"}]}, R.RSet{[R.RBulk{"nondeterministic_output"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the list of client connections"}, R.RBulk{"since"}, R.RBulk{"2.4.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of client connections"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"2.8.12"}, R.RBulk{"Added unique client `id` field."}]}, R.RArray{[R.RBulk{"5.0.0"}, R.RBulk{"Added optional `TYPE` filter."}]}, R.RArray{[R.RBulk{"6.0.0"}, R.RBulk{"Added `user` field."}]}, R.RArray{[R.RBulk{"6.2.0"}, R.RBulk{"Added `argv-mem`, `tot-mem`, `laddr` and `redir` fields and the optional `ID` filter."}]}, R.RArray{[R.RBulk{"7.0.0"}, R.RBulk{"Added `resp`, `multi-mem`, `rbs` and `rbp` fields."}]}, R.RArray{[R.RBulk{"7.0.3"}, R.RBulk{"Added `ssub` field."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"normal_master_replica_pubsub"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"token"}, R.RBulk{"TYPE"}, R.RBulk{"since"}, R.RBulk{"5.0.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"normal"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"NORMAL"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"master"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"MASTER"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"replica"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"REPLICA"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"pubsub"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"PUBSUB"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"id"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"token"}, R.RBulk{"ID"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"client-id"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]}]}]}, Desc{"client|no-evict", R.IPos{3n}, ["admin", "slow", "dangerous", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"client|no-evict"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}, R.RStatus{"@connection"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Set client eviction mode for the current connection"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"enabled"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"on"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ON"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"off"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"OFF"}]}]}]}]}]}, Desc{"client|pause", R.INeg{2n}, ["admin", "slow", "dangerous", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"client|pause"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}, R.RStatus{"@connection"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Stop processing commands from clients for some time"}, R.RBulk{"since"}, R.RBulk{"2.9.50"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"6.2.0"}, R.RBulk{"`CLIENT PAUSE WRITE` mode added along with the `mode` option."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"timeout"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"mode"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"write"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"WRITE"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"all"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ALL"}]}]}]}]}]}, Desc{"client|reply", R.IPos{3n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"client|reply"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Instruct the server whether to reply to commands"}, R.RBulk{"since"}, R.RBulk{"3.2.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"on_off_skip"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"on"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ON"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"off"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"OFF"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"skip"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"SKIP"}]}]}]}]}]}, Desc{"client|setname", R.IPos{3n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"client|setname"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Set the current connection name"}, R.RBulk{"since"}, R.RBulk{"2.6.9"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"connection-name"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]}, Desc{"client|tracking", R.INeg{2n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"client|tracking"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Enable or disable server assisted client side caching support"}, R.RBulk{"since"}, R.RBulk{"6.0.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1). Some options may introduce additional complexity."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"status"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"on"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ON"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"off"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"OFF"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"client-id"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"REDIRECT"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"prefix"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"token"}, R.RBulk{"PREFIX"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}, R.RStatus{"multiple"}, R.RStatus{"multiple_token"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"bcast"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"BCAST"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"optin"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"OPTIN"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"optout"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"OPTOUT"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"noloop"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"NOLOOP"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]}, Desc{"client|trackinginfo", R.IPos{2n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"client|trackinginfo"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Return information about server assisted client side caching for the current connection"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"client|unblock", R.INeg{2n}, ["admin", "slow", "dangerous", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"client|unblock"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}, R.RStatus{"@connection"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Unblock a client blocked in a blocking command from a different connection"}, R.RBulk{"since"}, R.RBulk{"5.0.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(log N) where N is the number of client connections"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"client-id"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"timeout_error"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"timeout"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"TIMEOUT"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"error"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ERROR"}]}]}]}]}]}, Desc{"client|unpause", R.IPos{2n}, ["admin", "slow", "dangerous", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"client|unpause"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}, R.RStatus{"@connection"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Resume processing of clients that were paused"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(N) Where N is the number of paused clients"}]}]}

def cmd.command() -> Top:
  Top{Desc{"command", R.INeg{0n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"command"}, R.RInt{R.INeg{0n}}, R.RSet{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RSet{[R.RBulk{"nondeterministic_output_order"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Get array of Redis command details"}, R.RBulk{"since"}, R.RBulk{"2.8.13"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the total number of Redis commands"}]},
  [Desc{"command|count", R.IPos{2n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"command|count"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Get total number of Redis commands"}, R.RBulk{"since"}, R.RBulk{"2.8.13"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"command|docs", R.INeg{1n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"command|docs"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RSet{[R.RBulk{"nondeterministic_output_order"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Get array of specific Redis command documentation"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of commands to look up"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"command-name"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}, R.RStatus{"multiple"}]}]}]}]}, Desc{"command|getkeys", R.INeg{3n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"command|getkeys"}, R.RInt{R.INeg{3n}}, R.RSet{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Extract keys given a full Redis command"}, R.RBulk{"since"}, R.RBulk{"2.8.13"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of arguments to the command"}]}, Desc{"command|getkeysandflags", R.INeg{3n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"command|getkeysandflags"}, R.RInt{R.INeg{3n}}, R.RSet{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Extract keys and access flags given a full Redis command"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of arguments to the command"}]}, Desc{"command|help", R.IPos{2n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"command|help"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Show helpful text about the different subcommands"}, R.RBulk{"since"}, R.RBulk{"5.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"command|info", R.INeg{1n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"command|info"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RSet{[R.RBulk{"nondeterministic_output_order"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Get array of specific Redis command details, or all when no argument is given."}, R.RBulk{"since"}, R.RBulk{"2.8.13"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of commands to look up"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"7.0.0"}, R.RBulk{"Allowed to be called with no argument to get info on all commands."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"command-name"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}, R.RStatus{"multiple"}]}]}]}]}, Desc{"command|list", R.INeg{1n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"command|list"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RSet{[R.RBulk{"nondeterministic_output_order"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Get an array of Redis command names"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the total number of Redis commands"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"filterby"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"token"}, R.RBulk{"FILTERBY"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"module-name"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"token"}, R.RBulk{"MODULE"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"category"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"token"}, R.RBulk{"ACLCAT"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"pattern"}, R.RBulk{"type"}, R.RBulk{"pattern"}, R.RBulk{"token"}, R.RBulk{"PATTERN"}]}]}]}]}]}]}

def cmd.config() -> Top:
  Top{Desc{"config", R.INeg{1n}, ["slow"], [], KBySpecs{}, False{},
    [R.RBulk{"config"}, R.RInt{R.INeg{1n}}, R.RSet{[]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"A container for server configuration commands"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"Depends on subcommand."}]},
  [Desc{"config|get", R.INeg{2n}, ["admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"config|get"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the values of configuration parameters"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N) when N is the number of configuration parameters provided"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"7.0.0"}, R.RBulk{"Added the ability to pass multiple pattern parameters in one call"}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"parameter"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"parameter"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]}]}]}, Desc{"config|help", R.IPos{2n}, ["slow"], [], KBySpecs{}, False{},
    [R.RBulk{"config|help"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Show helpful text about the different subcommands"}, R.RBulk{"since"}, R.RBulk{"5.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"config|resetstat", R.IPos{2n}, ["admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"config|resetstat"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Reset the stats returned by INFO"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"config|rewrite", R.IPos{2n}, ["admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"config|rewrite"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Rewrite the configuration file with the in memory configuration"}, R.RBulk{"since"}, R.RBulk{"2.8.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"config|set", R.INeg{3n}, ["admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"config|set"}, R.RInt{R.INeg{3n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[R.RBulk{"request_policy:all_nodes"}, R.RBulk{"response_policy:all_succeeded"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Set configuration parameters to the given values"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N) when N is the number of configuration parameters provided"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"7.0.0"}, R.RBulk{"Added the ability to set multiple parameters in one call."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"parameter_value"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"parameter"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"value"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]}]}]}]}

def cmd.copy() -> Top:
  Top{Desc{"copy", R.INeg{2n}, ["keyspace", "write", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}, KSpec{["OW", "update"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"copy"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{2n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@write"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}, R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"OW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Copy a key"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(N) worst case for collections, where N is the number of nested items. O(1) for string values."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"source"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"destination"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{1n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"destination-db"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"DB"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"replace"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"REPLACE"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.dbsize() -> Top:
  Top{Desc{"dbsize", R.IPos{1n}, ["keyspace", "read", "fast"], [], KBySpecs{}, False{},
    [R.RBulk{"dbsize"}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@read"}, R.RStatus{"@fast"}]}, R.RSet{[R.RBulk{"request_policy:all_shards"}, R.RBulk{"response_policy:agg_sum"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Return the number of keys in the selected database"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]},
  []}

def cmd.decr() -> Top:
  Top{Desc{"decr", R.IPos{2n}, ["write", "string", "fast"], [KSpec{["RW", "access", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"decr"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@string"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Decrement the integer value of a key by one"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]},
  []}

def cmd.decrby() -> Top:
  Top{Desc{"decrby", R.IPos{3n}, ["write", "string", "fast"], [KSpec{["RW", "access", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"decrby"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@string"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Decrement the integer value of a key by the given number"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"decrement"}, R.RBulk{"type"}, R.RBulk{"integer"}]}]}]},
  []}

def cmd.del() -> Top:
  Top{Desc{"del", R.INeg{1n}, ["keyspace", "write", "slow"], [KSpec{["RM", "delete"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"del"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"write"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.INeg{0n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@write"}, R.RStatus{"@slow"}]}, R.RSet{[R.RBulk{"request_policy:multi_shard"}, R.RBulk{"response_policy:agg_sum"}]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RM"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.INeg{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Delete a key"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of keys that will be removed. When a key to remove holds a value other than a string, the individual complexity for this key is O(M) where M is the number of elements in the list, set, sorted set or hash. Removing a single key that holds a string value is O(1)."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.discard() -> Top:
  Top{Desc{"discard", R.IPos{1n}, ["fast", "transaction"], [], KBySpecs{}, False{},
    [R.RBulk{"discard"}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}, R.RStatus{"fast"}, R.RStatus{"allow_busy"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@fast"}, R.RStatus{"@transaction"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Discard all commands issued after MULTI"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"transactions"}, R.RBulk{"complexity"}, R.RBulk{"O(N), when N is the number of queued commands"}]},
  []}

def cmd.dump() -> Top:
  Top{Desc{"dump", R.IPos{2n}, ["keyspace", "read", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"dump"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@read"}, R.RStatus{"@slow"}]}, R.RSet{[R.RBulk{"nondeterministic_output"}]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Return a serialized version of the value stored at the specified key."}, R.RBulk{"since"}, R.RBulk{"2.6.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(1) to access the key and additional O(N*M) to serialize it, where N is the number of Redis objects composing the value and M their average size. For small string values the time complexity is thus O(1)+O(1*M) where M is small, so simply O(1)."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]},
  []}

def cmd.echo() -> Top:
  Top{Desc{"echo", R.IPos{2n}, ["fast", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"echo"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"loading"}, R.RStatus{"stale"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@fast"}, R.RStatus{"@connection"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Echo the given string"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"message"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]},
  []}

def cmd.eval() -> Top:
  Top{Desc{"eval", R.INeg{2n}, ["slow", "scripting"], [], KByEval{}, True{},
    [R.RBulk{"eval"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"noscript"}, R.RStatus{"stale"}, R.RStatus{"skip_monitor"}, R.RStatus{"no_mandatory_keys"}, R.RStatus{"movablekeys"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}, R.RStatus{"@scripting"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"notes"}, R.RBulk{"We cannot tell how the keys will be used so we assume the worst, RW and UPDATE"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"keynum"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"keynumidx"}, R.RInt{R.IPos{0n}}, R.RBulk{"firstkey"}, R.RInt{R.IPos{1n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Execute a Lua script server side"}, R.RBulk{"since"}, R.RBulk{"2.6.0"}, R.RBulk{"group"}, R.RBulk{"scripting"}, R.RBulk{"complexity"}, R.RBulk{"Depends on the script that is executed."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"script"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"numkeys"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}, R.RStatus{"multiple"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"arg"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}, R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.eval_ro() -> Top:
  Top{Desc{"eval_ro", R.INeg{2n}, ["slow", "scripting"], [], KByEval{}, True{},
    [R.RBulk{"eval_ro"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"noscript"}, R.RStatus{"stale"}, R.RStatus{"skip_monitor"}, R.RStatus{"no_mandatory_keys"}, R.RStatus{"movablekeys"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}, R.RStatus{"@scripting"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"notes"}, R.RBulk{"We cannot tell how the keys will be used so we assume the worst, RO and ACCESS"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"keynum"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"keynumidx"}, R.RInt{R.IPos{0n}}, R.RBulk{"firstkey"}, R.RInt{R.IPos{1n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Execute a read-only Lua script server side"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"scripting"}, R.RBulk{"complexity"}, R.RBulk{"Depends on the script that is executed."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"script"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"numkeys"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}, R.RStatus{"multiple"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"arg"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}, R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.evalsha() -> Top:
  Top{Desc{"evalsha", R.INeg{2n}, ["slow", "scripting"], [], KByEval{}, True{},
    [R.RBulk{"evalsha"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"noscript"}, R.RStatus{"stale"}, R.RStatus{"skip_monitor"}, R.RStatus{"no_mandatory_keys"}, R.RStatus{"movablekeys"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}, R.RStatus{"@scripting"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"keynum"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"keynumidx"}, R.RInt{R.IPos{0n}}, R.RBulk{"firstkey"}, R.RInt{R.IPos{1n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Execute a Lua script server side"}, R.RBulk{"since"}, R.RBulk{"2.6.0"}, R.RBulk{"group"}, R.RBulk{"scripting"}, R.RBulk{"complexity"}, R.RBulk{"Depends on the script that is executed."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"sha1"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"numkeys"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}, R.RStatus{"multiple"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"arg"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}, R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.evalsha_ro() -> Top:
  Top{Desc{"evalsha_ro", R.INeg{2n}, ["slow", "scripting"], [], KByEval{}, True{},
    [R.RBulk{"evalsha_ro"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"noscript"}, R.RStatus{"stale"}, R.RStatus{"skip_monitor"}, R.RStatus{"no_mandatory_keys"}, R.RStatus{"movablekeys"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}, R.RStatus{"@scripting"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"keynum"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"keynumidx"}, R.RInt{R.IPos{0n}}, R.RBulk{"firstkey"}, R.RInt{R.IPos{1n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Execute a read-only Lua script server side"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"scripting"}, R.RBulk{"complexity"}, R.RBulk{"Depends on the script that is executed."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"sha1"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"numkeys"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}, R.RStatus{"multiple"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"arg"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}, R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.exec() -> Top:
  Top{Desc{"exec", R.IPos{1n}, ["slow", "transaction"], [], KBySpecs{}, False{},
    [R.RBulk{"exec"}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}, R.RStatus{"skip_slowlog"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}, R.RStatus{"@transaction"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Execute all commands issued after MULTI"}, R.RBulk{"since"}, R.RBulk{"1.2.0"}, R.RBulk{"group"}, R.RBulk{"transactions"}, R.RBulk{"complexity"}, R.RBulk{"Depends on commands in the transaction"}]},
  []}

def cmd.exists() -> Top:
  Top{Desc{"exists", R.INeg{1n}, ["keyspace", "read", "fast"], [KSpec{["RO"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"exists"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.INeg{0n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@read"}, R.RStatus{"@fast"}]}, R.RSet{[R.RBulk{"request_policy:multi_shard"}, R.RBulk{"response_policy:agg_sum"}]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.INeg{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Determine if a key exists"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of keys to check."}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"3.0.3"}, R.RBulk{"Accepts multiple `key` arguments."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.expire() -> Top:
  Top{Desc{"expire", R.INeg{2n}, ["keyspace", "write", "fast"], [KSpec{["RW", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"expire"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@write"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Set a key's time to live in seconds"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"7.0.0"}, R.RBulk{"Added options: `NX`, `XX`, `GT` and `LT`."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"seconds"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"condition"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"nx"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"NX"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"xx"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"XX"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"gt"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"GT"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"lt"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"LT"}]}]}]}]}]},
  []}

def cmd.expireat() -> Top:
  Top{Desc{"expireat", R.INeg{2n}, ["keyspace", "write", "fast"], [KSpec{["RW", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"expireat"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@write"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Set the expiration for a key as a UNIX timestamp"}, R.RBulk{"since"}, R.RBulk{"1.2.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"7.0.0"}, R.RBulk{"Added options: `NX`, `XX`, `GT` and `LT`."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"unix-time-seconds"}, R.RBulk{"type"}, R.RBulk{"unix-time"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"condition"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"nx"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"NX"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"xx"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"XX"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"gt"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"GT"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"lt"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"LT"}]}]}]}]}]},
  []}

def cmd.expiretime() -> Top:
  Top{Desc{"expiretime", R.IPos{2n}, ["keyspace", "read", "fast"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"expiretime"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@read"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the expiration Unix timestamp for a key"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]},
  []}

def cmd.flushall() -> Top:
  Top{Desc{"flushall", R.INeg{0n}, ["keyspace", "write", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"flushall"}, R.RInt{R.INeg{0n}}, R.RSet{[R.RStatus{"write"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@write"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[R.RBulk{"request_policy:all_shards"}, R.RBulk{"response_policy:all_succeeded"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Remove all keys from all databases"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the total number of keys in all databases"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"4.0.0"}, R.RBulk{"Added the `ASYNC` flushing mode modifier."}]}, R.RArray{[R.RBulk{"6.2.0"}, R.RBulk{"Added the `SYNC` flushing mode modifier."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"async"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"async"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ASYNC"}, R.RBulk{"since"}, R.RBulk{"4.0.0"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"sync"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"SYNC"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}]}]}]}]}]},
  []}

def cmd.flushdb() -> Top:
  Top{Desc{"flushdb", R.INeg{0n}, ["keyspace", "write", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"flushdb"}, R.RInt{R.INeg{0n}}, R.RSet{[R.RStatus{"write"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@write"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[R.RBulk{"request_policy:all_shards"}, R.RBulk{"response_policy:all_succeeded"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Remove all keys from the current database"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of keys in the selected database"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"4.0.0"}, R.RBulk{"Added the `ASYNC` flushing mode modifier."}]}, R.RArray{[R.RBulk{"6.2.0"}, R.RBulk{"Added the `SYNC` flushing mode modifier."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"async"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"async"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ASYNC"}, R.RBulk{"since"}, R.RBulk{"4.0.0"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"sync"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"SYNC"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}]}]}]}]}]},
  []}

def cmd.function() -> Top:
  Top{Desc{"function", R.INeg{1n}, ["slow"], [], KBySpecs{}, False{},
    [R.RBulk{"function"}, R.RInt{R.INeg{1n}}, R.RSet{[]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"A container for function commands"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"scripting"}, R.RBulk{"complexity"}, R.RBulk{"Depends on subcommand."}]},
  [Desc{"function|flush", R.INeg{1n}, ["write", "slow", "scripting"], [], KBySpecs{}, False{},
    [R.RBulk{"function|flush"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"noscript"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@slow"}, R.RStatus{"@scripting"}]}, R.RSet{[R.RBulk{"request_policy:all_shards"}, R.RBulk{"response_policy:all_succeeded"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Deleting all functions"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"scripting"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of functions deleted"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"async"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"async"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ASYNC"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"sync"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"SYNC"}]}]}]}]}]}, Desc{"function|help", R.IPos{2n}, ["slow", "scripting"], [], KBySpecs{}, False{},
    [R.RBulk{"function|help"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}, R.RStatus{"@scripting"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Show helpful text about the different subcommands"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"scripting"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}]}

def cmd.geoadd() -> Top:
  Top{Desc{"geoadd", R.INeg{4n}, ["write", "geo", "slow"], [KSpec{["RW", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"geoadd"}, R.RInt{R.INeg{4n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@geo"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Add one or more geospatial items in the geospatial index represented using a sorted set"}, R.RBulk{"since"}, R.RBulk{"3.2.0"}, R.RBulk{"group"}, R.RBulk{"geo"}, R.RBulk{"complexity"}, R.RBulk{"O(log(N)) for each item added, where N is the number of elements in the sorted set."}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"6.2.0"}, R.RBulk{"Added the `CH`, `NX` and `XX` options."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"condition"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"nx"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"NX"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"xx"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"XX"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"change"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"CH"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"longitude_latitude_member"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"longitude"}, R.RBulk{"type"}, R.RBulk{"double"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"latitude"}, R.RBulk{"type"}, R.RBulk{"double"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"member"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]}]}]},
  []}

def cmd.geodist() -> Top:
  Top{Desc{"geodist", R.INeg{3n}, ["read", "geo", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"geodist"}, R.RInt{R.INeg{3n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@geo"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Returns the distance between two members of a geospatial index"}, R.RBulk{"since"}, R.RBulk{"3.2.0"}, R.RBulk{"group"}, R.RBulk{"geo"}, R.RBulk{"complexity"}, R.RBulk{"O(log(N))"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"member1"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"member2"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"unit"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"m"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"M"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"km"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"KM"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"ft"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"FT"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"mi"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"MI"}]}]}]}]}]},
  []}

def cmd.geohash() -> Top:
  Top{Desc{"geohash", R.INeg{1n}, ["read", "geo", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"geohash"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@geo"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Returns members of a geospatial index as standard geohash strings"}, R.RBulk{"since"}, R.RBulk{"3.2.0"}, R.RBulk{"group"}, R.RBulk{"geo"}, R.RBulk{"complexity"}, R.RBulk{"O(log(N)) for each member requested, where N is the number of elements in the sorted set."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"member"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.geopos() -> Top:
  Top{Desc{"geopos", R.INeg{1n}, ["read", "geo", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"geopos"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@geo"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Returns longitude and latitude of members of a geospatial index"}, R.RBulk{"since"}, R.RBulk{"3.2.0"}, R.RBulk{"group"}, R.RBulk{"geo"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of members requested."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"member"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.georadius() -> Top:
  Top{Desc{"georadius", R.INeg{5n}, ["write", "geo", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}, KSpecKw{["OW", "update"], "STORE", 6n, R.IPos{0n}, 1n, 0n}, KSpecKw{["OW", "update"], "STOREDIST", 6n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"georadius"}, R.RInt{R.INeg{5n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"movablekeys"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@geo"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}, R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"OW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"keyword"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"keyword"}, R.RBulk{"STORE"}, R.RBulk{"startfrom"}, R.RInt{R.IPos{6n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}, R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"OW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"keyword"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"keyword"}, R.RBulk{"STOREDIST"}, R.RBulk{"startfrom"}, R.RInt{R.IPos{6n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Query a sorted set representing a geospatial index to fetch members matching a given maximum distance from a point"}, R.RBulk{"since"}, R.RBulk{"3.2.0"}, R.RBulk{"group"}, R.RBulk{"geo"}, R.RBulk{"complexity"}, R.RBulk{"O(N+log(M)) where N is the number of elements inside the bounding box of the circular area delimited by center and radius and M is the number of items inside the index."}, R.RBulk{"doc_flags"}, R.RSet{[R.RStatus{"deprecated"}]}, R.RBulk{"deprecated_since"}, R.RBulk{"6.2.0"}, R.RBulk{"replaced_by"}, R.RBulk{"`GEOSEARCH` and `GEOSEARCHSTORE` with the `BYRADIUS` argument"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"6.2.0"}, R.RBulk{"Added the `ANY` option for `COUNT`."}]}, R.RArray{[R.RBulk{"7.0.0"}, R.RBulk{"Added support for uppercase unit names."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"longitude"}, R.RBulk{"type"}, R.RBulk{"double"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"latitude"}, R.RBulk{"type"}, R.RBulk{"double"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"radius"}, R.RBulk{"type"}, R.RBulk{"double"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"unit"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"m"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"M"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"km"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"KM"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"ft"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"FT"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"mi"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"MI"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"withcoord"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"WITHCOORD"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"withdist"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"WITHDIST"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"withhash"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"WITHHASH"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"COUNT"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"any"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ANY"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"order"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"asc"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ASC"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"desc"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"DESC"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{1n}}, R.RBulk{"token"}, R.RBulk{"STORE"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{2n}}, R.RBulk{"token"}, R.RBulk{"STOREDIST"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.georadius_ro() -> Top:
  Top{Desc{"georadius_ro", R.INeg{5n}, ["read", "geo", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"georadius_ro"}, R.RInt{R.INeg{5n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@geo"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"A read-only variant for GEORADIUS"}, R.RBulk{"since"}, R.RBulk{"3.2.10"}, R.RBulk{"group"}, R.RBulk{"geo"}, R.RBulk{"complexity"}, R.RBulk{"O(N+log(M)) where N is the number of elements inside the bounding box of the circular area delimited by center and radius and M is the number of items inside the index."}, R.RBulk{"doc_flags"}, R.RSet{[R.RStatus{"deprecated"}]}, R.RBulk{"deprecated_since"}, R.RBulk{"6.2.0"}, R.RBulk{"replaced_by"}, R.RBulk{"`GEOSEARCH` with the `BYRADIUS` argument"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"6.2.0"}, R.RBulk{"Added the `ANY` option for `COUNT`."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"longitude"}, R.RBulk{"type"}, R.RBulk{"double"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"latitude"}, R.RBulk{"type"}, R.RBulk{"double"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"radius"}, R.RBulk{"type"}, R.RBulk{"double"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"unit"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"m"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"M"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"km"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"KM"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"ft"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"FT"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"mi"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"MI"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"withcoord"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"WITHCOORD"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"withdist"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"WITHDIST"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"withhash"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"WITHHASH"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"COUNT"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"any"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ANY"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"order"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"asc"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ASC"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"desc"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"DESC"}]}]}]}]}]},
  []}

def cmd.georadiusbymember() -> Top:
  Top{Desc{"georadiusbymember", R.INeg{4n}, ["write", "geo", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}, KSpecKw{["OW", "update"], "STORE", 5n, R.IPos{0n}, 1n, 0n}, KSpecKw{["OW", "update"], "STOREDIST", 5n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"georadiusbymember"}, R.RInt{R.INeg{4n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"movablekeys"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@geo"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}, R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"OW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"keyword"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"keyword"}, R.RBulk{"STORE"}, R.RBulk{"startfrom"}, R.RInt{R.IPos{5n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}, R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"OW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"keyword"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"keyword"}, R.RBulk{"STOREDIST"}, R.RBulk{"startfrom"}, R.RInt{R.IPos{5n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Query a sorted set representing a geospatial index to fetch members matching a given maximum distance from a member"}, R.RBulk{"since"}, R.RBulk{"3.2.0"}, R.RBulk{"group"}, R.RBulk{"geo"}, R.RBulk{"complexity"}, R.RBulk{"O(N+log(M)) where N is the number of elements inside the bounding box of the circular area delimited by center and radius and M is the number of items inside the index."}, R.RBulk{"doc_flags"}, R.RSet{[R.RStatus{"deprecated"}]}, R.RBulk{"deprecated_since"}, R.RBulk{"6.2.0"}, R.RBulk{"replaced_by"}, R.RBulk{"`GEOSEARCH` and `GEOSEARCHSTORE` with the `BYRADIUS` and `FROMMEMBER` arguments"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"7.0.0"}, R.RBulk{"Added support for uppercase unit names."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"member"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"radius"}, R.RBulk{"type"}, R.RBulk{"double"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"unit"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"m"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"M"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"km"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"KM"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"ft"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"FT"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"mi"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"MI"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"withcoord"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"WITHCOORD"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"withdist"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"WITHDIST"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"withhash"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"WITHHASH"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"COUNT"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"any"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ANY"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"order"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"asc"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ASC"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"desc"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"DESC"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{1n}}, R.RBulk{"token"}, R.RBulk{"STORE"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{2n}}, R.RBulk{"token"}, R.RBulk{"STOREDIST"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.georadiusbymember_ro() -> Top:
  Top{Desc{"georadiusbymember_ro", R.INeg{4n}, ["read", "geo", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"georadiusbymember_ro"}, R.RInt{R.INeg{4n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@geo"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"A read-only variant for GEORADIUSBYMEMBER"}, R.RBulk{"since"}, R.RBulk{"3.2.10"}, R.RBulk{"group"}, R.RBulk{"geo"}, R.RBulk{"complexity"}, R.RBulk{"O(N+log(M)) where N is the number of elements inside the bounding box of the circular area delimited by center and radius and M is the number of items inside the index."}, R.RBulk{"doc_flags"}, R.RSet{[R.RStatus{"deprecated"}]}, R.RBulk{"deprecated_since"}, R.RBulk{"6.2.0"}, R.RBulk{"replaced_by"}, R.RBulk{"`GEOSEARCH` with the `BYRADIUS` and `FROMMEMBER` arguments"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"member"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"radius"}, R.RBulk{"type"}, R.RBulk{"double"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"unit"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"m"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"M"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"km"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"KM"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"ft"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"FT"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"mi"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"MI"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"withcoord"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"WITHCOORD"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"withdist"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"WITHDIST"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"withhash"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"WITHHASH"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"COUNT"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"any"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ANY"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"order"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"asc"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ASC"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"desc"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"DESC"}]}]}]}]}]},
  []}

def cmd.geosearch() -> Top:
  Top{Desc{"geosearch", R.INeg{6n}, ["read", "geo", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"geosearch"}, R.RInt{R.INeg{6n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@geo"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Query a sorted set representing a geospatial index to fetch members inside an area of a box or a circle."}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"group"}, R.RBulk{"geo"}, R.RBulk{"complexity"}, R.RBulk{"O(N+log(M)) where N is the number of elements in the grid-aligned bounding box area around the shape provided as the filter and M is the number of items inside the shape"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"7.0.0"}, R.RBulk{"Added support for uppercase unit names."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"from"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"member"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"token"}, R.RBulk{"FROMMEMBER"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"longitude_latitude"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"token"}, R.RBulk{"FROMLONLAT"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"longitude"}, R.RBulk{"type"}, R.RBulk{"double"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"latitude"}, R.RBulk{"type"}, R.RBulk{"double"}]}]}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"by"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"circle"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"radius"}, R.RBulk{"type"}, R.RBulk{"double"}, R.RBulk{"token"}, R.RBulk{"BYRADIUS"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"unit"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"m"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"M"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"km"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"KM"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"ft"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"FT"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"mi"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"MI"}]}]}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"box"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"width"}, R.RBulk{"type"}, R.RBulk{"double"}, R.RBulk{"token"}, R.RBulk{"BYBOX"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"height"}, R.RBulk{"type"}, R.RBulk{"double"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"unit"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"m"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"M"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"km"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"KM"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"ft"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"FT"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"mi"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"MI"}]}]}]}]}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"order"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"asc"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ASC"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"desc"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"DESC"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"COUNT"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"any"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ANY"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"withcoord"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"WITHCOORD"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"withdist"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"WITHDIST"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"withhash"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"WITHHASH"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.geosearchstore() -> Top:
  Top{Desc{"geosearchstore", R.INeg{7n}, ["write", "geo", "slow"], [KSpec{["OW", "update"], 1n, R.IPos{0n}, 1n, 0n}, KSpec{["RO", "access"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"geosearchstore"}, R.RInt{R.INeg{7n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{2n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@geo"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"OW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}, R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Query a sorted set representing a geospatial index to fetch members inside an area of a box or a circle, and store the result in another key."}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"group"}, R.RBulk{"geo"}, R.RBulk{"complexity"}, R.RBulk{"O(N+log(M)) where N is the number of elements in the grid-aligned bounding box area around the shape provided as the filter and M is the number of items inside the shape"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"7.0.0"}, R.RBulk{"Added support for uppercase unit names."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"destination"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"source"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{1n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"from"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"member"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"token"}, R.RBulk{"FROMMEMBER"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"longitude_latitude"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"token"}, R.RBulk{"FROMLONLAT"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"longitude"}, R.RBulk{"type"}, R.RBulk{"double"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"latitude"}, R.RBulk{"type"}, R.RBulk{"double"}]}]}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"by"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"circle"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"radius"}, R.RBulk{"type"}, R.RBulk{"double"}, R.RBulk{"token"}, R.RBulk{"BYRADIUS"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"unit"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"m"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"M"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"km"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"KM"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"ft"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"FT"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"mi"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"MI"}]}]}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"box"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"width"}, R.RBulk{"type"}, R.RBulk{"double"}, R.RBulk{"token"}, R.RBulk{"BYBOX"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"height"}, R.RBulk{"type"}, R.RBulk{"double"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"unit"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"m"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"M"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"km"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"KM"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"ft"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"FT"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"mi"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"MI"}]}]}]}]}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"order"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"asc"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ASC"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"desc"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"DESC"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"COUNT"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"any"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ANY"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"storedist"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"STOREDIST"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.get() -> Top:
  Top{Desc{"get", R.IPos{2n}, ["read", "string", "fast"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"get"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@string"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the value of a key"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]},
  []}

def cmd.getbit() -> Top:
  Top{Desc{"getbit", R.IPos{3n}, ["read", "bitmap", "fast"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"getbit"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@bitmap"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Returns the bit value at offset in the string value stored at key"}, R.RBulk{"since"}, R.RBulk{"2.2.0"}, R.RBulk{"group"}, R.RBulk{"bitmap"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"offset"}, R.RBulk{"type"}, R.RBulk{"integer"}]}]}]},
  []}

def cmd.getdel() -> Top:
  Top{Desc{"getdel", R.IPos{2n}, ["write", "string", "fast"], [KSpec{["RW", "access", "delete"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"getdel"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@string"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the value of a key and delete the key"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]},
  []}

def cmd.getex() -> Top:
  Top{Desc{"getex", R.INeg{1n}, ["write", "string", "fast"], [KSpec{["RW", "access", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"getex"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@string"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"notes"}, R.RBulk{"RW and UPDATE because it changes the TTL"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the value of a key and optionally set its expiration"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"expiration"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"seconds"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"EX"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"milliseconds"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"PX"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"unix-time-seconds"}, R.RBulk{"type"}, R.RBulk{"unix-time"}, R.RBulk{"token"}, R.RBulk{"EXAT"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"unix-time-milliseconds"}, R.RBulk{"type"}, R.RBulk{"unix-time"}, R.RBulk{"token"}, R.RBulk{"PXAT"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"persist"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"PERSIST"}]}]}]}]}]},
  []}

def cmd.getrange() -> Top:
  Top{Desc{"getrange", R.IPos{4n}, ["read", "string", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"getrange"}, R.RInt{R.IPos{4n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@string"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get a substring of the string stored at a key"}, R.RBulk{"since"}, R.RBulk{"2.4.0"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the length of the returned string. The complexity is ultimately determined by the returned length, but because creating a substring from an existing string is very cheap, it can be considered O(1) for small strings."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"start"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"end"}, R.RBulk{"type"}, R.RBulk{"integer"}]}]}]},
  []}

def cmd.getset() -> Top:
  Top{Desc{"getset", R.IPos{3n}, ["write", "string", "fast"], [KSpec{["RW", "access", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"getset"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@string"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Set the string value of a key and return its old value"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"doc_flags"}, R.RSet{[R.RStatus{"deprecated"}]}, R.RBulk{"deprecated_since"}, R.RBulk{"6.2.0"}, R.RBulk{"replaced_by"}, R.RBulk{"`SET` with the `!GET` argument"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"value"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]},
  []}

def cmd.hdel() -> Top:
  Top{Desc{"hdel", R.INeg{2n}, ["write", "hash", "fast"], [KSpec{["RW", "delete"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"hdel"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@hash"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Delete one or more hash fields"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"hash"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of fields to be removed."}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"2.4.0"}, R.RBulk{"Accepts multiple `field` arguments."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"field"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.hello() -> Top:
  Top{Desc{"hello", R.INeg{0n}, ["fast", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"hello"}, R.RInt{R.INeg{0n}}, R.RSet{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}, R.RStatus{"fast"}, R.RStatus{"no_auth"}, R.RStatus{"allow_busy"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@fast"}, R.RStatus{"@connection"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Handshake with Redis"}, R.RBulk{"since"}, R.RBulk{"6.0.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"6.2.0"}, R.RBulk{"`protover` made optional; when called without arguments the command reports the current connection's context."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"arguments"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"protover"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"username_password"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"token"}, R.RBulk{"AUTH"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"username"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"password"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"clientname"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"token"}, R.RBulk{"SETNAME"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]}]}]},
  []}

def cmd.hexists() -> Top:
  Top{Desc{"hexists", R.IPos{3n}, ["read", "hash", "fast"], [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"hexists"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@hash"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Determine if a hash field exists"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"hash"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"field"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]},
  []}

def cmd.hget() -> Top:
  Top{Desc{"hget", R.IPos{3n}, ["read", "hash", "fast"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"hget"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@hash"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the value of a hash field"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"hash"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"field"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]},
  []}

def cmd.hgetall() -> Top:
  Top{Desc{"hgetall", R.IPos{2n}, ["read", "hash", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"hgetall"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@hash"}, R.RStatus{"@slow"}]}, R.RSet{[R.RBulk{"nondeterministic_output_order"}]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get all the fields and values in a hash"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"hash"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the size of the hash."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]},
  []}

def cmd.hincrby() -> Top:
  Top{Desc{"hincrby", R.IPos{4n}, ["write", "hash", "fast"], [KSpec{["RW", "access", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"hincrby"}, R.RInt{R.IPos{4n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@hash"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Increment the integer value of a hash field by the given number"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"hash"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"field"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"increment"}, R.RBulk{"type"}, R.RBulk{"integer"}]}]}]},
  []}

def cmd.hincrbyfloat() -> Top:
  Top{Desc{"hincrbyfloat", R.IPos{4n}, ["write", "hash", "fast"], [KSpec{["RW", "access", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"hincrbyfloat"}, R.RInt{R.IPos{4n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@hash"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Increment the float value of a hash field by the given amount"}, R.RBulk{"since"}, R.RBulk{"2.6.0"}, R.RBulk{"group"}, R.RBulk{"hash"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"field"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"increment"}, R.RBulk{"type"}, R.RBulk{"double"}]}]}]},
  []}

def cmd.hkeys() -> Top:
  Top{Desc{"hkeys", R.IPos{2n}, ["read", "hash", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"hkeys"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@hash"}, R.RStatus{"@slow"}]}, R.RSet{[R.RBulk{"nondeterministic_output_order"}]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get all the fields in a hash"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"hash"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the size of the hash."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]},
  []}

def cmd.hlen() -> Top:
  Top{Desc{"hlen", R.IPos{2n}, ["read", "hash", "fast"], [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"hlen"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@hash"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the number of fields in a hash"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"hash"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]},
  []}

def cmd.hmget() -> Top:
  Top{Desc{"hmget", R.INeg{2n}, ["read", "hash", "fast"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"hmget"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@hash"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the values of all the given hash fields"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"hash"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of fields being requested."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"field"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.hmset() -> Top:
  Top{Desc{"hmset", R.INeg{3n}, ["write", "hash", "fast"], [KSpec{["RW", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"hmset"}, R.RInt{R.INeg{3n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@hash"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Set multiple hash fields to multiple values"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"hash"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of fields being set."}, R.RBulk{"doc_flags"}, R.RSet{[R.RStatus{"deprecated"}]}, R.RBulk{"deprecated_since"}, R.RBulk{"4.0.0"}, R.RBulk{"replaced_by"}, R.RBulk{"`HSET` with multiple field-value pairs"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"field_value"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"field"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"value"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]}]}]},
  []}

def cmd.hrandfield() -> Top:
  Top{Desc{"hrandfield", R.INeg{1n}, ["read", "hash", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"hrandfield"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@hash"}, R.RStatus{"@slow"}]}, R.RSet{[R.RBulk{"nondeterministic_output"}]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get one or multiple random fields from a hash"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"group"}, R.RBulk{"hash"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of fields returned"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"options"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"withvalues"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"WITHVALUES"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]}]}]},
  []}

def cmd.hscan() -> Top:
  Top{Desc{"hscan", R.INeg{2n}, ["read", "hash", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"hscan"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@hash"}, R.RStatus{"@slow"}]}, R.RSet{[R.RBulk{"nondeterministic_output"}]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Incrementally iterate hash fields and associated values"}, R.RBulk{"since"}, R.RBulk{"2.8.0"}, R.RBulk{"group"}, R.RBulk{"hash"}, R.RBulk{"complexity"}, R.RBulk{"O(1) for every call. O(N) for a complete iteration, including enough command calls for the cursor to return back to 0. N is the number of elements inside the collection.."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"cursor"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"pattern"}, R.RBulk{"type"}, R.RBulk{"pattern"}, R.RBulk{"token"}, R.RBulk{"MATCH"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"COUNT"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.hset() -> Top:
  Top{Desc{"hset", R.INeg{3n}, ["write", "hash", "fast"], [KSpec{["RW", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"hset"}, R.RInt{R.INeg{3n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@hash"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Set the string value of a hash field"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"hash"}, R.RBulk{"complexity"}, R.RBulk{"O(1) for each field/value pair added, so O(N) to add N field/value pairs when the command is called with multiple field/value pairs."}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"4.0.0"}, R.RBulk{"Accepts multiple `field` and `value` arguments."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"field_value"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"field"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"value"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]}]}]},
  []}

def cmd.hsetnx() -> Top:
  Top{Desc{"hsetnx", R.IPos{4n}, ["write", "hash", "fast"], [KSpec{["RW", "insert"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"hsetnx"}, R.RInt{R.IPos{4n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@hash"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"insert"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Set the value of a hash field, only if the field does not exist"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"hash"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"field"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"value"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]},
  []}

def cmd.hstrlen() -> Top:
  Top{Desc{"hstrlen", R.IPos{3n}, ["read", "hash", "fast"], [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"hstrlen"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@hash"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the length of the value of a hash field"}, R.RBulk{"since"}, R.RBulk{"3.2.0"}, R.RBulk{"group"}, R.RBulk{"hash"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"field"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]},
  []}

def cmd.hvals() -> Top:
  Top{Desc{"hvals", R.IPos{2n}, ["read", "hash", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"hvals"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@hash"}, R.RStatus{"@slow"}]}, R.RSet{[R.RBulk{"nondeterministic_output_order"}]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get all the values in a hash"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"hash"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the size of the hash."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]},
  []}

def cmd.incr() -> Top:
  Top{Desc{"incr", R.IPos{2n}, ["write", "string", "fast"], [KSpec{["RW", "access", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"incr"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@string"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Increment the integer value of a key by one"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]},
  []}

def cmd.incrby() -> Top:
  Top{Desc{"incrby", R.IPos{3n}, ["write", "string", "fast"], [KSpec{["RW", "access", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"incrby"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@string"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Increment the integer value of a key by the given amount"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"increment"}, R.RBulk{"type"}, R.RBulk{"integer"}]}]}]},
  []}

def cmd.incrbyfloat() -> Top:
  Top{Desc{"incrbyfloat", R.IPos{3n}, ["write", "string", "fast"], [KSpec{["RW", "access", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"incrbyfloat"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@string"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Increment the float value of a key by the given amount"}, R.RBulk{"since"}, R.RBulk{"2.6.0"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"increment"}, R.RBulk{"type"}, R.RBulk{"double"}]}]}]},
  []}

def cmd.info() -> Top:
  Top{Desc{"info", R.INeg{0n}, ["slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"info"}, R.RInt{R.INeg{0n}}, R.RSet{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[R.RBulk{"nondeterministic_output"}, R.RBulk{"request_policy:all_shards"}, R.RBulk{"response_policy:special"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Get information and statistics about the server"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"7.0.0"}, R.RBulk{"Added support for taking multiple section arguments."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"section"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}, R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.keys() -> Top:
  Top{Desc{"keys", R.IPos{2n}, ["keyspace", "read", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"keys"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@read"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[R.RBulk{"request_policy:all_shards"}, R.RBulk{"nondeterministic_output_order"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Find all keys matching the given pattern"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(N) with N being the number of keys in the database, under the assumption that the key names in the database and the given pattern have limited length."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"pattern"}, R.RBulk{"type"}, R.RBulk{"pattern"}]}]}]},
  []}

def cmd.lastsave() -> Top:
  Top{Desc{"lastsave", R.IPos{1n}, ["admin", "fast", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"lastsave"}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"loading"}, R.RStatus{"stale"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@fast"}, R.RStatus{"@dangerous"}]}, R.RSet{[R.RBulk{"nondeterministic_output"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the UNIX time stamp of the last successful save to disk"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]},
  []}

def cmd.latency() -> Top:
  Top{Desc{"latency", R.INeg{1n}, ["slow"], [], KBySpecs{}, False{},
    [R.RBulk{"latency"}, R.RInt{R.INeg{1n}}, R.RSet{[]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"A container for latency diagnostics commands"}, R.RBulk{"since"}, R.RBulk{"2.8.13"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"Depends on subcommand."}]},
  [Desc{"latency|doctor", R.IPos{2n}, ["admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"latency|doctor"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[R.RBulk{"nondeterministic_output"}, R.RBulk{"request_policy:all_nodes"}, R.RBulk{"response_policy:special"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Return a human readable latency analysis report."}, R.RBulk{"since"}, R.RBulk{"2.8.13"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"latency|graph", R.IPos{3n}, ["admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"latency|graph"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[R.RBulk{"nondeterministic_output"}, R.RBulk{"request_policy:all_nodes"}, R.RBulk{"response_policy:special"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Return a latency graph for the event."}, R.RBulk{"since"}, R.RBulk{"2.8.13"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"event"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]}, Desc{"latency|help", R.IPos{2n}, ["slow"], [], KBySpecs{}, False{},
    [R.RBulk{"latency|help"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Show helpful text about the different subcommands."}, R.RBulk{"since"}, R.RBulk{"2.8.13"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"latency|histogram", R.INeg{1n}, ["admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"latency|histogram"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[R.RBulk{"nondeterministic_output"}, R.RBulk{"request_policy:all_nodes"}, R.RBulk{"response_policy:special"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Return the cumulative distribution of latencies of a subset of commands or all."}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of commands with latency information being retrieved."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"command"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}, R.RStatus{"multiple"}]}]}]}]}, Desc{"latency|history", R.IPos{3n}, ["admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"latency|history"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[R.RBulk{"nondeterministic_output"}, R.RBulk{"request_policy:all_nodes"}, R.RBulk{"response_policy:special"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Return timestamp-latency samples for the event."}, R.RBulk{"since"}, R.RBulk{"2.8.13"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"event"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]}, Desc{"latency|latest", R.IPos{2n}, ["admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"latency|latest"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[R.RBulk{"nondeterministic_output"}, R.RBulk{"request_policy:all_nodes"}, R.RBulk{"response_policy:special"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Return the latest latency samples for all events."}, R.RBulk{"since"}, R.RBulk{"2.8.13"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"latency|reset", R.INeg{1n}, ["admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"latency|reset"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[R.RBulk{"request_policy:all_nodes"}, R.RBulk{"response_policy:all_succeeded"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Reset latency data for one or more events."}, R.RBulk{"since"}, R.RBulk{"2.8.13"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"event"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}, R.RStatus{"multiple"}]}]}]}]}]}

def cmd.lcs() -> Top:
  Top{Desc{"lcs", R.INeg{2n}, ["read", "string", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{1n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"lcs"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{2n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@string"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{1n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Find longest common substring"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(N*M) where N and M are the lengths of s1 and s2, respectively"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key1"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"key2"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"len"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"LEN"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"idx"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"IDX"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"len"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"MINMATCHLEN"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"withmatchlen"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"WITHMATCHLEN"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.lindex() -> Top:
  Top{Desc{"lindex", R.IPos{3n}, ["read", "list", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"lindex"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@list"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get an element from a list by its index"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"list"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of elements to traverse to get to the element at index. This makes asking for the first or the last element of the list O(1)."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"index"}, R.RBulk{"type"}, R.RBulk{"integer"}]}]}]},
  []}

def cmd.linsert() -> Top:
  Top{Desc{"linsert", R.IPos{5n}, ["write", "list", "slow"], [KSpec{["RW", "insert"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"linsert"}, R.RInt{R.IPos{5n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@list"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"insert"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Insert an element before or after another element in a list"}, R.RBulk{"since"}, R.RBulk{"2.2.0"}, R.RBulk{"group"}, R.RBulk{"list"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of elements to traverse before seeing the value pivot. This means that inserting somewhere on the left end on the list (head) can be considered O(1) and inserting somewhere on the right end (tail) is O(N)."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"where"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"before"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"BEFORE"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"after"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"AFTER"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"pivot"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"element"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]},
  []}

def cmd.llen() -> Top:
  Top{Desc{"llen", R.IPos{2n}, ["read", "list", "fast"], [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"llen"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@list"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the length of a list"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"list"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]},
  []}

def cmd.lmove() -> Top:
  Top{Desc{"lmove", R.IPos{5n}, ["write", "list", "slow"], [KSpec{["RW", "access", "delete"], 1n, R.IPos{0n}, 1n, 0n}, KSpec{["RW", "insert"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"lmove"}, R.RInt{R.IPos{5n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{2n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@list"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}, R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"insert"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Pop an element from a list, push it to another list and return it"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"group"}, R.RBulk{"list"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"source"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"destination"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{1n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"wherefrom"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"left"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"LEFT"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"right"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"RIGHT"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"whereto"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"left"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"LEFT"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"right"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"RIGHT"}]}]}]}]}]},
  []}

def cmd.lmpop() -> Top:
  Top{Desc{"lmpop", R.INeg{3n}, ["write", "list", "slow"], [], KByLmpop{}, False{},
    [R.RBulk{"lmpop"}, R.RInt{R.INeg{3n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"movablekeys"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@list"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"keynum"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"keynumidx"}, R.RInt{R.IPos{0n}}, R.RBulk{"firstkey"}, R.RInt{R.IPos{1n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Pop elements from a list"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"list"}, R.RBulk{"complexity"}, R.RBulk{"O(N+M) where N is the number of provided keys and M is the number of elements returned."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"numkeys"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"where"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"left"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"LEFT"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"right"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"RIGHT"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"COUNT"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.lolwut() -> Top:
  Top{Desc{"lolwut", R.INeg{0n}, ["read", "fast"], [], KBySpecs{}, False{},
    [R.RBulk{"lolwut"}, R.RInt{R.INeg{0n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Display some computer art and the Redis version"}, R.RBulk{"since"}, R.RBulk{"5.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"version"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"VERSION"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.lpop() -> Top:
  Top{Desc{"lpop", R.INeg{1n}, ["write", "list", "fast"], [KSpec{["RW", "access", "delete"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"lpop"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@list"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Remove and get the first elements in a list"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"list"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of elements returned"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"6.2.0"}, R.RBulk{"Added the `count` argument."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.lpos() -> Top:
  Top{Desc{"lpos", R.INeg{2n}, ["read", "list", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"lpos"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@list"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Return the index of matching elements on a list"}, R.RBulk{"since"}, R.RBulk{"6.0.6"}, R.RBulk{"group"}, R.RBulk{"list"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of elements in the list, for the average case. When searching for elements near the head or the tail of the list, or when the MAXLEN option is provided, the command may run in constant time."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"element"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"rank"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"RANK"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"num-matches"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"COUNT"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"len"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"MAXLEN"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.lpush() -> Top:
  Top{Desc{"lpush", R.INeg{2n}, ["write", "list", "fast"], [KSpec{["RW", "insert"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"lpush"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@list"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"insert"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Prepend one or multiple elements to a list"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"list"}, R.RBulk{"complexity"}, R.RBulk{"O(1) for each element added, so O(N) to add N elements when the command is called with multiple arguments."}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"2.4.0"}, R.RBulk{"Accepts multiple `element` arguments."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"element"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.lpushx() -> Top:
  Top{Desc{"lpushx", R.INeg{2n}, ["write", "list", "fast"], [KSpec{["RW", "insert"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"lpushx"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@list"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"insert"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Prepend an element to a list, only if the list exists"}, R.RBulk{"since"}, R.RBulk{"2.2.0"}, R.RBulk{"group"}, R.RBulk{"list"}, R.RBulk{"complexity"}, R.RBulk{"O(1) for each element added, so O(N) to add N elements when the command is called with multiple arguments."}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"4.0.0"}, R.RBulk{"Accepts multiple `element` arguments."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"element"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.lrange() -> Top:
  Top{Desc{"lrange", R.IPos{4n}, ["read", "list", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"lrange"}, R.RInt{R.IPos{4n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@list"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get a range of elements from a list"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"list"}, R.RBulk{"complexity"}, R.RBulk{"O(S+N) where S is the distance of start offset from HEAD for small lists, from nearest end (HEAD or TAIL) for large lists; and N is the number of elements in the specified range."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"start"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"stop"}, R.RBulk{"type"}, R.RBulk{"integer"}]}]}]},
  []}

def cmd.lrem() -> Top:
  Top{Desc{"lrem", R.IPos{4n}, ["write", "list", "slow"], [KSpec{["RW", "delete"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"lrem"}, R.RInt{R.IPos{4n}}, R.RSet{[R.RStatus{"write"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@list"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Remove elements from a list"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"list"}, R.RBulk{"complexity"}, R.RBulk{"O(N+M) where N is the length of the list and M is the number of elements removed."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"element"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]},
  []}

def cmd.lset() -> Top:
  Top{Desc{"lset", R.IPos{4n}, ["write", "list", "slow"], [KSpec{["RW", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"lset"}, R.RInt{R.IPos{4n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@list"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Set the value of an element in a list by its index"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"list"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the length of the list. Setting either the first or the last element of the list is O(1)."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"index"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"element"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]},
  []}

def cmd.ltrim() -> Top:
  Top{Desc{"ltrim", R.IPos{4n}, ["write", "list", "slow"], [KSpec{["RW", "delete"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"ltrim"}, R.RInt{R.IPos{4n}}, R.RSet{[R.RStatus{"write"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@list"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Trim a list to the specified range"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"list"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of elements to be removed by the operation."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"start"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"stop"}, R.RBulk{"type"}, R.RBulk{"integer"}]}]}]},
  []}

def cmd.memory() -> Top:
  Top{Desc{"memory", R.INeg{1n}, ["slow"], [], KBySpecs{}, False{},
    [R.RBulk{"memory"}, R.RInt{R.INeg{1n}}, R.RSet{[]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"A container for memory diagnostics commands"}, R.RBulk{"since"}, R.RBulk{"4.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"Depends on subcommand."}]},
  [Desc{"memory|doctor", R.IPos{2n}, ["slow"], [], KBySpecs{}, False{},
    [R.RBulk{"memory|doctor"}, R.RInt{R.IPos{2n}}, R.RSet{[]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}]}, R.RSet{[R.RBulk{"nondeterministic_output"}, R.RBulk{"request_policy:all_shards"}, R.RBulk{"response_policy:special"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Outputs memory problems report"}, R.RBulk{"since"}, R.RBulk{"4.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"memory|help", R.IPos{2n}, ["slow"], [], KBySpecs{}, False{},
    [R.RBulk{"memory|help"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Show helpful text about the different subcommands"}, R.RBulk{"since"}, R.RBulk{"4.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"memory|malloc-stats", R.IPos{2n}, ["slow"], [], KBySpecs{}, False{},
    [R.RBulk{"memory|malloc-stats"}, R.RInt{R.IPos{2n}}, R.RSet{[]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}]}, R.RSet{[R.RBulk{"nondeterministic_output"}, R.RBulk{"request_policy:all_shards"}, R.RBulk{"response_policy:special"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Show allocator internal stats"}, R.RBulk{"since"}, R.RBulk{"4.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"Depends on how much memory is allocated, could be slow"}]}, Desc{"memory|purge", R.IPos{2n}, ["slow"], [], KBySpecs{}, False{},
    [R.RBulk{"memory|purge"}, R.RInt{R.IPos{2n}}, R.RSet{[]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}]}, R.RSet{[R.RBulk{"request_policy:all_shards"}, R.RBulk{"response_policy:all_succeeded"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Ask the allocator to release memory"}, R.RBulk{"since"}, R.RBulk{"4.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"Depends on how much memory is allocated, could be slow"}]}, Desc{"memory|stats", R.IPos{2n}, ["slow"], [], KBySpecs{}, False{},
    [R.RBulk{"memory|stats"}, R.RInt{R.IPos{2n}}, R.RSet{[]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}]}, R.RSet{[R.RBulk{"nondeterministic_output"}, R.RBulk{"request_policy:all_shards"}, R.RBulk{"response_policy:special"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Show memory usage details"}, R.RBulk{"since"}, R.RBulk{"4.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"memory|usage", R.INeg{2n}, ["read", "slow"], [KSpec{["RO"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"memory|usage"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{2n}}, R.RInt{R.IPos{2n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Estimate the memory usage of a key"}, R.RBulk{"since"}, R.RBulk{"4.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of samples."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"SAMPLES"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]}]}

def cmd.mget() -> Top:
  Top{Desc{"mget", R.INeg{1n}, ["read", "string", "fast"], [KSpec{["RO", "access"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"mget"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.INeg{0n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@string"}, R.RStatus{"@fast"}]}, R.RSet{[R.RBulk{"request_policy:multi_shard"}]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.INeg{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the values of all the given keys"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of keys to retrieve."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.monitor() -> Top:
  Top{Desc{"monitor", R.IPos{1n}, ["admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"monitor"}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Listen for all requests received by the server in real time"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}]},
  []}

def cmd.move() -> Top:
  Top{Desc{"move", R.IPos{3n}, ["keyspace", "write", "fast"], [KSpec{["RW", "access", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"move"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@write"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Move a key to another database"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"db"}, R.RBulk{"type"}, R.RBulk{"integer"}]}]}]},
  []}

def cmd.mset() -> Top:
  Top{Desc{"mset", R.INeg{2n}, ["write", "string", "slow"], [KSpec{["OW", "update"], 1n, R.INeg{0n}, 2n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"mset"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.INeg{0n}}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@string"}, R.RStatus{"@slow"}]}, R.RSet{[R.RBulk{"request_policy:multi_shard"}, R.RBulk{"response_policy:all_succeeded"}]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"OW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.INeg{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{2n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Set multiple keys to multiple values"}, R.RBulk{"since"}, R.RBulk{"1.0.1"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of keys to set."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key_value"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"value"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]}]}]},
  []}

def cmd.msetnx() -> Top:
  Top{Desc{"msetnx", R.INeg{2n}, ["write", "string", "slow"], [KSpec{["OW", "insert"], 1n, R.INeg{0n}, 2n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"msetnx"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.INeg{0n}}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@string"}, R.RStatus{"@slow"}]}, R.RSet{[R.RBulk{"request_policy:multi_shard"}, R.RBulk{"response_policy:agg_min"}]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"OW"}, R.RStatus{"insert"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.INeg{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{2n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Set multiple keys to multiple values, only if none of the keys exist"}, R.RBulk{"since"}, R.RBulk{"1.0.1"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of keys to set."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key_value"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"value"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]}]}]},
  []}

def cmd.multi() -> Top:
  Top{Desc{"multi", R.IPos{1n}, ["fast", "transaction"], [], KBySpecs{}, False{},
    [R.RBulk{"multi"}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}, R.RStatus{"fast"}, R.RStatus{"allow_busy"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@fast"}, R.RStatus{"@transaction"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Mark the start of a transaction block"}, R.RBulk{"since"}, R.RBulk{"1.2.0"}, R.RBulk{"group"}, R.RBulk{"transactions"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]},
  []}

def cmd.object() -> Top:
  Top{Desc{"object", R.INeg{1n}, ["slow"], [], KBySpecs{}, False{},
    [R.RBulk{"object"}, R.RInt{R.INeg{1n}}, R.RSet{[]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"A container for object introspection commands"}, R.RBulk{"since"}, R.RBulk{"2.2.3"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"Depends on subcommand."}]},
  [Desc{"object|encoding", R.IPos{3n}, ["keyspace", "read", "slow"], [KSpec{["RO"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"object|encoding"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{2n}}, R.RInt{R.IPos{2n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@read"}, R.RStatus{"@slow"}]}, R.RSet{[R.RBulk{"nondeterministic_output"}]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Inspect the internal encoding of a Redis object"}, R.RBulk{"since"}, R.RBulk{"2.2.3"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]}, Desc{"object|freq", R.IPos{3n}, ["keyspace", "read", "slow"], [KSpec{["RO"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"object|freq"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{2n}}, R.RInt{R.IPos{2n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@read"}, R.RStatus{"@slow"}]}, R.RSet{[R.RBulk{"nondeterministic_output"}]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the logarithmic access frequency counter of a Redis object"}, R.RBulk{"since"}, R.RBulk{"4.0.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]}, Desc{"object|help", R.IPos{2n}, ["keyspace", "slow"], [], KBySpecs{}, False{},
    [R.RBulk{"object|help"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Show helpful text about the different subcommands"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"object|idletime", R.IPos{3n}, ["keyspace", "read", "slow"], [KSpec{["RO"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"object|idletime"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{2n}}, R.RInt{R.IPos{2n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@read"}, R.RStatus{"@slow"}]}, R.RSet{[R.RBulk{"nondeterministic_output"}]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the time since a Redis object was last accessed"}, R.RBulk{"since"}, R.RBulk{"2.2.3"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]}, Desc{"object|refcount", R.IPos{3n}, ["keyspace", "read", "slow"], [KSpec{["RO"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"object|refcount"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{2n}}, R.RInt{R.IPos{2n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@read"}, R.RStatus{"@slow"}]}, R.RSet{[R.RBulk{"nondeterministic_output"}]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the number of references to the value of the key"}, R.RBulk{"since"}, R.RBulk{"2.2.3"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]}]}

def cmd.persist() -> Top:
  Top{Desc{"persist", R.IPos{2n}, ["keyspace", "write", "fast"], [KSpec{["RW", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"persist"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@write"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Remove the expiration from a key"}, R.RBulk{"since"}, R.RBulk{"2.2.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]},
  []}

def cmd.pexpire() -> Top:
  Top{Desc{"pexpire", R.INeg{2n}, ["keyspace", "write", "fast"], [KSpec{["RW", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"pexpire"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@write"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Set a key's time to live in milliseconds"}, R.RBulk{"since"}, R.RBulk{"2.6.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"7.0.0"}, R.RBulk{"Added options: `NX`, `XX`, `GT` and `LT`."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"milliseconds"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"condition"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"nx"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"NX"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"xx"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"XX"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"gt"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"GT"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"lt"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"LT"}]}]}]}]}]},
  []}

def cmd.pexpireat() -> Top:
  Top{Desc{"pexpireat", R.INeg{2n}, ["keyspace", "write", "fast"], [KSpec{["RW", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"pexpireat"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@write"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Set the expiration for a key as a UNIX timestamp specified in milliseconds"}, R.RBulk{"since"}, R.RBulk{"2.6.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"7.0.0"}, R.RBulk{"Added options: `NX`, `XX`, `GT` and `LT`."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"unix-time-milliseconds"}, R.RBulk{"type"}, R.RBulk{"unix-time"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"condition"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"nx"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"NX"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"xx"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"XX"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"gt"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"GT"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"lt"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"LT"}]}]}]}]}]},
  []}

def cmd.pexpiretime() -> Top:
  Top{Desc{"pexpiretime", R.IPos{2n}, ["keyspace", "read", "fast"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"pexpiretime"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@read"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the expiration Unix timestamp for a key in milliseconds"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]},
  []}

def cmd.pfadd() -> Top:
  Top{Desc{"pfadd", R.INeg{1n}, ["write", "hyperloglog", "fast"], [KSpec{["RW", "insert"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"pfadd"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@hyperloglog"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"insert"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Adds the specified elements to the specified HyperLogLog."}, R.RBulk{"since"}, R.RBulk{"2.8.9"}, R.RBulk{"group"}, R.RBulk{"hyperloglog"}, R.RBulk{"complexity"}, R.RBulk{"O(1) to add every element."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"element"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}, R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.pfcount() -> Top:
  Top{Desc{"pfcount", R.INeg{1n}, ["read", "hyperloglog", "slow"], [KSpec{["RW", "access"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"pfcount"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.INeg{0n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@hyperloglog"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"notes"}, R.RBulk{"RW because it may change the internal representation of the key, and propagate to replicas"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.INeg{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Return the approximated cardinality of the set(s) observed by the HyperLogLog at key(s)."}, R.RBulk{"since"}, R.RBulk{"2.8.9"}, R.RBulk{"group"}, R.RBulk{"hyperloglog"}, R.RBulk{"complexity"}, R.RBulk{"O(1) with a very small average constant time when called with a single key. O(N) with N being the number of keys, and much bigger constant times, when called with multiple keys."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.pfdebug() -> Top:
  Top{Desc{"pfdebug", R.IPos{3n}, ["write", "hyperloglog", "admin", "slow", "dangerous"], [KSpec{["RW", "access"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"pfdebug"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"admin"}]}, R.RInt{R.IPos{2n}}, R.RInt{R.IPos{2n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@hyperloglog"}, R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Internal commands for debugging HyperLogLog values"}, R.RBulk{"since"}, R.RBulk{"2.8.9"}, R.RBulk{"group"}, R.RBulk{"hyperloglog"}, R.RBulk{"complexity"}, R.RBulk{"N/A"}, R.RBulk{"doc_flags"}, R.RSet{[R.RStatus{"syscmd"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"subcommand"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]},
  []}

def cmd.pfmerge() -> Top:
  Top{Desc{"pfmerge", R.INeg{1n}, ["write", "hyperloglog", "slow"], [KSpec{["RW", "access", "insert"], 1n, R.IPos{0n}, 1n, 0n}, KSpec{["RO", "access"], 2n, R.INeg{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"pfmerge"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.INeg{0n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@hyperloglog"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"insert"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}, R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.INeg{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Merge N different HyperLogLogs into a single one."}, R.RBulk{"since"}, R.RBulk{"2.8.9"}, R.RBulk{"group"}, R.RBulk{"hyperloglog"}, R.RBulk{"complexity"}, R.RBulk{"O(N) to merge N HyperLogLogs, but with high constant times."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"destkey"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"sourcekey"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{1n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.pfselftest() -> Top:
  Top{Desc{"pfselftest", R.IPos{1n}, ["hyperloglog", "admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"pfselftest"}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"admin"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@hyperloglog"}, R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"An internal command for testing HyperLogLog values"}, R.RBulk{"since"}, R.RBulk{"2.8.9"}, R.RBulk{"group"}, R.RBulk{"hyperloglog"}, R.RBulk{"complexity"}, R.RBulk{"N/A"}, R.RBulk{"doc_flags"}, R.RSet{[R.RStatus{"syscmd"}]}]},
  []}

def cmd.ping() -> Top:
  Top{Desc{"ping", R.INeg{0n}, ["fast", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"ping"}, R.RInt{R.INeg{0n}}, R.RSet{[R.RStatus{"fast"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@fast"}, R.RStatus{"@connection"}]}, R.RSet{[R.RBulk{"request_policy:all_shards"}, R.RBulk{"response_policy:all_succeeded"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Ping the server"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"message"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.psetex() -> Top:
  Top{Desc{"psetex", R.IPos{4n}, ["write", "string", "slow"], [KSpec{["OW", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"psetex"}, R.RInt{R.IPos{4n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@string"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"OW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Set the value and expiration in milliseconds of a key"}, R.RBulk{"since"}, R.RBulk{"2.6.0"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"milliseconds"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"value"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]},
  []}

def cmd.psubscribe() -> Top:
  Top{Desc{"psubscribe", R.INeg{1n}, ["pubsub", "slow"], [], KBySpecs{}, False{},
    [R.RBulk{"psubscribe"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"pubsub"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@pubsub"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Listen for messages published to channels matching the given patterns"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"pubsub"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of patterns the client is already subscribed to."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"pattern"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"pattern"}, R.RBulk{"type"}, R.RBulk{"pattern"}]}]}]}]}]},
  []}

def cmd.pttl() -> Top:
  Top{Desc{"pttl", R.IPos{2n}, ["keyspace", "read", "fast"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"pttl"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@read"}, R.RStatus{"@fast"}]}, R.RSet{[R.RBulk{"nondeterministic_output"}]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the time to live for a key in milliseconds"}, R.RBulk{"since"}, R.RBulk{"2.6.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"2.8.0"}, R.RBulk{"Added the -2 reply."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]},
  []}

def cmd.publish() -> Top:
  Top{Desc{"publish", R.IPos{3n}, ["pubsub", "fast"], [], KBySpecs{}, False{},
    [R.RBulk{"publish"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"pubsub"}, R.RStatus{"loading"}, R.RStatus{"stale"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@pubsub"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Post a message to a channel"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"pubsub"}, R.RBulk{"complexity"}, R.RBulk{"O(N+M) where N is the number of clients subscribed to the receiving channel and M is the total number of subscribed patterns (by any client)."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"channel"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"message"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]},
  []}

def cmd.pubsub() -> Top:
  Top{Desc{"pubsub", R.INeg{1n}, ["slow"], [], KBySpecs{}, False{},
    [R.RBulk{"pubsub"}, R.RInt{R.INeg{1n}}, R.RSet{[]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"A container for Pub/Sub commands"}, R.RBulk{"since"}, R.RBulk{"2.8.0"}, R.RBulk{"group"}, R.RBulk{"pubsub"}, R.RBulk{"complexity"}, R.RBulk{"Depends on subcommand."}]},
  [Desc{"pubsub|channels", R.INeg{1n}, ["pubsub", "slow"], [], KBySpecs{}, False{},
    [R.RBulk{"pubsub|channels"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"pubsub"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@pubsub"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"List active channels"}, R.RBulk{"since"}, R.RBulk{"2.8.0"}, R.RBulk{"group"}, R.RBulk{"pubsub"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of active channels, and assuming constant time pattern matching (relatively short channels and patterns)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"pattern"}, R.RBulk{"type"}, R.RBulk{"pattern"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]}, Desc{"pubsub|help", R.IPos{2n}, ["slow"], [], KBySpecs{}, False{},
    [R.RBulk{"pubsub|help"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Show helpful text about the different subcommands"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"group"}, R.RBulk{"pubsub"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"pubsub|numpat", R.IPos{2n}, ["pubsub", "slow"], [], KBySpecs{}, False{},
    [R.RBulk{"pubsub|numpat"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"pubsub"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@pubsub"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the count of unique patterns pattern subscriptions"}, R.RBulk{"since"}, R.RBulk{"2.8.0"}, R.RBulk{"group"}, R.RBulk{"pubsub"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"pubsub|numsub", R.INeg{1n}, ["pubsub", "slow"], [], KBySpecs{}, False{},
    [R.RBulk{"pubsub|numsub"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"pubsub"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@pubsub"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the count of subscribers for channels"}, R.RBulk{"since"}, R.RBulk{"2.8.0"}, R.RBulk{"group"}, R.RBulk{"pubsub"}, R.RBulk{"complexity"}, R.RBulk{"O(N) for the NUMSUB subcommand, where N is the number of requested channels"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"channel"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}, R.RStatus{"multiple"}]}]}]}]}, Desc{"pubsub|shardchannels", R.INeg{1n}, ["pubsub", "slow"], [], KBySpecs{}, False{},
    [R.RBulk{"pubsub|shardchannels"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"pubsub"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@pubsub"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"List active shard channels"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"pubsub"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of active shard channels, and assuming constant time pattern matching (relatively short shard channels)."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"pattern"}, R.RBulk{"type"}, R.RBulk{"pattern"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]}, Desc{"pubsub|shardnumsub", R.INeg{1n}, ["pubsub", "slow"], [], KBySpecs{}, False{},
    [R.RBulk{"pubsub|shardnumsub"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"pubsub"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@pubsub"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the count of subscribers for shard channels"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"pubsub"}, R.RBulk{"complexity"}, R.RBulk{"O(N) for the SHARDNUMSUB subcommand, where N is the number of requested shard channels"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"shardchannel"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}, R.RStatus{"multiple"}]}]}]}]}]}

def cmd.punsubscribe() -> Top:
  Top{Desc{"punsubscribe", R.INeg{0n}, ["pubsub", "slow"], [], KBySpecs{}, False{},
    [R.RBulk{"punsubscribe"}, R.RInt{R.INeg{0n}}, R.RSet{[R.RStatus{"pubsub"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@pubsub"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Stop listening for messages posted to channels matching the given patterns"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"pubsub"}, R.RBulk{"complexity"}, R.RBulk{"O(N+M) where N is the number of patterns the client is already subscribed and M is the number of total patterns subscribed in the system (by any client)."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"pattern"}, R.RBulk{"type"}, R.RBulk{"pattern"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}, R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.quit() -> Top:
  Top{Desc{"quit", R.INeg{0n}, ["fast", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"quit"}, R.RInt{R.INeg{0n}}, R.RSet{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}, R.RStatus{"fast"}, R.RStatus{"no_auth"}, R.RStatus{"allow_busy"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@fast"}, R.RStatus{"@connection"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Close the connection"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]},
  []}

def cmd.randomkey() -> Top:
  Top{Desc{"randomkey", R.IPos{1n}, ["keyspace", "read", "slow"], [], KBySpecs{}, False{},
    [R.RBulk{"randomkey"}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@read"}, R.RStatus{"@slow"}]}, R.RSet{[R.RBulk{"request_policy:all_shards"}, R.RBulk{"nondeterministic_output"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Return a random key from the keyspace"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]},
  []}

def cmd.rename() -> Top:
  Top{Desc{"rename", R.IPos{3n}, ["keyspace", "write", "slow"], [KSpec{["RW", "access", "delete"], 1n, R.IPos{0n}, 1n, 0n}, KSpec{["OW", "update"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"rename"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"write"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{2n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@write"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}, R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"OW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Rename a key"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"newkey"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{1n}}]}]}]},
  []}

def cmd.renamenx() -> Top:
  Top{Desc{"renamenx", R.IPos{3n}, ["keyspace", "write", "fast"], [KSpec{["RW", "access", "delete"], 1n, R.IPos{0n}, 1n, 0n}, KSpec{["OW", "insert"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"renamenx"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{2n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@write"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}, R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"OW"}, R.RStatus{"insert"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Rename a key, only if the new key does not exist"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"3.2.0"}, R.RBulk{"The command no longer returns an error when source and destination names are the same."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"newkey"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{1n}}]}]}]},
  []}

def cmd.reset() -> Top:
  Top{Desc{"reset", R.IPos{1n}, ["fast", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"reset"}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}, R.RStatus{"fast"}, R.RStatus{"no_auth"}, R.RStatus{"allow_busy"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@fast"}, R.RStatus{"@connection"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Reset the connection"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]},
  []}

def cmd.restore() -> Top:
  Top{Desc{"restore", R.INeg{3n}, ["keyspace", "write", "slow", "dangerous"], [KSpec{["OW", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"restore"}, R.RInt{R.INeg{3n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@write"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"OW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Create a key using the provided serialized value, previously obtained using DUMP."}, R.RBulk{"since"}, R.RBulk{"2.6.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(1) to create the new key and additional O(N*M) to reconstruct the serialized value, where N is the number of Redis objects composing the value and M their average size. For small string values the time complexity is thus O(1)+O(1*M) where M is small, so simply O(1). However for sorted set values the complexity is O(N*M*log(N)) because inserting values into sorted sets is O(log(N))."}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"3.0.0"}, R.RBulk{"Added the `REPLACE` modifier."}]}, R.RArray{[R.RBulk{"5.0.0"}, R.RBulk{"Added the `ABSTTL` modifier."}]}, R.RArray{[R.RBulk{"5.0.0"}, R.RBulk{"Added the `IDLETIME` and `FREQ` options."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"ttl"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"serialized-value"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"replace"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"REPLACE"}, R.RBulk{"since"}, R.RBulk{"3.0.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"absttl"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ABSTTL"}, R.RBulk{"since"}, R.RBulk{"5.0.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"seconds"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"IDLETIME"}, R.RBulk{"since"}, R.RBulk{"5.0.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"frequency"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"FREQ"}, R.RBulk{"since"}, R.RBulk{"5.0.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.role() -> Top:
  Top{Desc{"role", R.IPos{1n}, ["admin", "fast", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"role"}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@fast"}, R.RStatus{"@dangerous"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Return the role of the instance in the context of replication"}, R.RBulk{"since"}, R.RBulk{"2.8.12"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]},
  []}

def cmd.rpop() -> Top:
  Top{Desc{"rpop", R.INeg{1n}, ["write", "list", "fast"], [KSpec{["RW", "access", "delete"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"rpop"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@list"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Remove and get the last elements in a list"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"list"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of elements returned"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"6.2.0"}, R.RBulk{"Added the `count` argument."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.rpoplpush() -> Top:
  Top{Desc{"rpoplpush", R.IPos{3n}, ["write", "list", "slow"], [KSpec{["RW", "access", "delete"], 1n, R.IPos{0n}, 1n, 0n}, KSpec{["RW", "insert"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"rpoplpush"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{2n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@list"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}, R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"insert"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Remove the last element in a list, prepend it to another list and return it"}, R.RBulk{"since"}, R.RBulk{"1.2.0"}, R.RBulk{"group"}, R.RBulk{"list"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"doc_flags"}, R.RSet{[R.RStatus{"deprecated"}]}, R.RBulk{"deprecated_since"}, R.RBulk{"6.2.0"}, R.RBulk{"replaced_by"}, R.RBulk{"`LMOVE` with the `RIGHT` and `LEFT` arguments"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"source"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"destination"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{1n}}]}]}]},
  []}

def cmd.rpush() -> Top:
  Top{Desc{"rpush", R.INeg{2n}, ["write", "list", "fast"], [KSpec{["RW", "insert"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"rpush"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@list"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"insert"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Append one or multiple elements to a list"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"list"}, R.RBulk{"complexity"}, R.RBulk{"O(1) for each element added, so O(N) to add N elements when the command is called with multiple arguments."}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"2.4.0"}, R.RBulk{"Accepts multiple `element` arguments."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"element"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.rpushx() -> Top:
  Top{Desc{"rpushx", R.INeg{2n}, ["write", "list", "fast"], [KSpec{["RW", "insert"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"rpushx"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@list"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"insert"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Append an element to a list, only if the list exists"}, R.RBulk{"since"}, R.RBulk{"2.2.0"}, R.RBulk{"group"}, R.RBulk{"list"}, R.RBulk{"complexity"}, R.RBulk{"O(1) for each element added, so O(N) to add N elements when the command is called with multiple arguments."}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"4.0.0"}, R.RBulk{"Accepts multiple `element` arguments."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"element"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.sadd() -> Top:
  Top{Desc{"sadd", R.INeg{2n}, ["write", "set", "fast"], [KSpec{["RW", "insert"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"sadd"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@set"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"insert"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Add one or more members to a set"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"set"}, R.RBulk{"complexity"}, R.RBulk{"O(1) for each element added, so O(N) to add N elements when the command is called with multiple arguments."}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"2.4.0"}, R.RBulk{"Accepts multiple `member` arguments."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"member"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.save() -> Top:
  Top{Desc{"save", R.IPos{1n}, ["admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"save"}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"no_async_loading"}, R.RStatus{"no_multi"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Synchronously save the dataset to disk"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the total number of keys in all databases"}]},
  []}

def cmd.scan() -> Top:
  Top{Desc{"scan", R.INeg{1n}, ["keyspace", "read", "slow"], [], KBySpecs{}, False{},
    [R.RBulk{"scan"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@read"}, R.RStatus{"@slow"}]}, R.RSet{[R.RBulk{"nondeterministic_output"}, R.RBulk{"request_policy:special"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Incrementally iterate the keys space"}, R.RBulk{"since"}, R.RBulk{"2.8.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(1) for every call. O(N) for a complete iteration, including enough command calls for the cursor to return back to 0. N is the number of elements inside the collection."}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"6.0.0"}, R.RBulk{"Added the `TYPE` subcommand."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"cursor"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"pattern"}, R.RBulk{"type"}, R.RBulk{"pattern"}, R.RBulk{"token"}, R.RBulk{"MATCH"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"COUNT"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"type"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"token"}, R.RBulk{"TYPE"}, R.RBulk{"since"}, R.RBulk{"6.0.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.scard() -> Top:
  Top{Desc{"scard", R.IPos{2n}, ["read", "set", "fast"], [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"scard"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@set"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the number of members in a set"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"set"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]},
  []}

def cmd.script() -> Top:
  Top{Desc{"script", R.INeg{1n}, ["slow"], [], KBySpecs{}, False{},
    [R.RBulk{"script"}, R.RInt{R.INeg{1n}}, R.RSet{[]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"A container for Lua scripts management commands"}, R.RBulk{"since"}, R.RBulk{"2.6.0"}, R.RBulk{"group"}, R.RBulk{"scripting"}, R.RBulk{"complexity"}, R.RBulk{"Depends on subcommand."}]},
  [Desc{"script|exists", R.INeg{2n}, ["slow", "scripting"], [], KBySpecs{}, False{},
    [R.RBulk{"script|exists"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"noscript"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}, R.RStatus{"@scripting"}]}, R.RSet{[R.RBulk{"request_policy:all_shards"}, R.RBulk{"response_policy:agg_logical_and"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Check existence of scripts in the script cache."}, R.RBulk{"since"}, R.RBulk{"2.6.0"}, R.RBulk{"group"}, R.RBulk{"scripting"}, R.RBulk{"complexity"}, R.RBulk{"O(N) with N being the number of scripts to check (so checking a single script is an O(1) operation)."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"sha1"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]}, Desc{"script|flush", R.INeg{1n}, ["slow", "scripting"], [], KBySpecs{}, False{},
    [R.RBulk{"script|flush"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"noscript"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}, R.RStatus{"@scripting"}]}, R.RSet{[R.RBulk{"request_policy:all_nodes"}, R.RBulk{"response_policy:all_succeeded"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Remove all the scripts from the script cache."}, R.RBulk{"since"}, R.RBulk{"2.6.0"}, R.RBulk{"group"}, R.RBulk{"scripting"}, R.RBulk{"complexity"}, R.RBulk{"O(N) with N being the number of scripts in cache"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"6.2.0"}, R.RBulk{"Added the `ASYNC` and `SYNC` flushing mode modifiers."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"async"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"async"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ASYNC"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"sync"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"SYNC"}]}]}]}]}]}, Desc{"script|help", R.IPos{2n}, ["slow", "scripting"], [], KBySpecs{}, False{},
    [R.RBulk{"script|help"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}, R.RStatus{"@scripting"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Show helpful text about the different subcommands"}, R.RBulk{"since"}, R.RBulk{"5.0.0"}, R.RBulk{"group"}, R.RBulk{"scripting"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"script|kill", R.IPos{2n}, ["slow", "scripting"], [], KBySpecs{}, False{},
    [R.RBulk{"script|kill"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"noscript"}, R.RStatus{"allow_busy"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}, R.RStatus{"@scripting"}]}, R.RSet{[R.RBulk{"request_policy:all_shards"}, R.RBulk{"response_policy:one_succeeded"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Kill the script currently in execution."}, R.RBulk{"since"}, R.RBulk{"2.6.0"}, R.RBulk{"group"}, R.RBulk{"scripting"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"script|load", R.IPos{3n}, ["slow", "scripting"], [], KBySpecs{}, False{},
    [R.RBulk{"script|load"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"noscript"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}, R.RStatus{"@scripting"}]}, R.RSet{[R.RBulk{"request_policy:all_nodes"}, R.RBulk{"response_policy:all_succeeded"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Load the specified Lua script into the script cache."}, R.RBulk{"since"}, R.RBulk{"2.6.0"}, R.RBulk{"group"}, R.RBulk{"scripting"}, R.RBulk{"complexity"}, R.RBulk{"O(N) with N being the length in bytes of the script body."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"script"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]}]}

def cmd.sdiff() -> Top:
  Top{Desc{"sdiff", R.INeg{1n}, ["read", "set", "slow"], [KSpec{["RO", "access"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"sdiff"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.INeg{0n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@set"}, R.RStatus{"@slow"}]}, R.RSet{[R.RBulk{"nondeterministic_output_order"}]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.INeg{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Subtract multiple sets"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"set"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the total number of elements in all given sets."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.sdiffstore() -> Top:
  Top{Desc{"sdiffstore", R.INeg{2n}, ["write", "set", "slow"], [KSpec{["OW", "update"], 1n, R.IPos{0n}, 1n, 0n}, KSpec{["RO", "access"], 2n, R.INeg{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"sdiffstore"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.INeg{0n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@set"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"OW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}, R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.INeg{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Subtract multiple sets and store the resulting set in a key"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"set"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the total number of elements in all given sets."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"destination"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{1n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.select() -> Top:
  Top{Desc{"select", R.IPos{2n}, ["fast", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"select"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"loading"}, R.RStatus{"stale"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@fast"}, R.RStatus{"@connection"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Change the selected database for the current connection"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"index"}, R.RBulk{"type"}, R.RBulk{"integer"}]}]}]},
  []}

def cmd.set() -> Top:
  Top{Desc{"set", R.INeg{2n}, ["write", "string", "slow"], [KSpec{["RW", "access", "update", "variable_flags"], 1n, R.IPos{0n}, 1n, 0n}], KBySet{}, False{},
    [R.RBulk{"set"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@string"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"notes"}, R.RBulk{"RW and ACCESS due to the optional `GET` argument"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"update"}, R.RStatus{"variable_flags"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Set the string value of a key"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"2.6.12"}, R.RBulk{"Added the `EX`, `PX`, `NX` and `XX` options."}]}, R.RArray{[R.RBulk{"6.0.0"}, R.RBulk{"Added the `KEEPTTL` option."}]}, R.RArray{[R.RBulk{"6.2.0"}, R.RBulk{"Added the `GET`, `EXAT` and `PXAT` option."}]}, R.RArray{[R.RBulk{"7.0.0"}, R.RBulk{"Allowed the `NX` and `GET` options to be used together."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"value"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"condition"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"since"}, R.RBulk{"2.6.12"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"nx"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"NX"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"xx"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"XX"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"get"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"GET"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"expiration"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"seconds"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"EX"}, R.RBulk{"since"}, R.RBulk{"2.6.12"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"milliseconds"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"PX"}, R.RBulk{"since"}, R.RBulk{"2.6.12"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"unix-time-seconds"}, R.RBulk{"type"}, R.RBulk{"unix-time"}, R.RBulk{"token"}, R.RBulk{"EXAT"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"unix-time-milliseconds"}, R.RBulk{"type"}, R.RBulk{"unix-time"}, R.RBulk{"token"}, R.RBulk{"PXAT"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"keepttl"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"KEEPTTL"}, R.RBulk{"since"}, R.RBulk{"6.0.0"}]}]}]}]}]},
  []}

def cmd.setbit() -> Top:
  Top{Desc{"setbit", R.IPos{4n}, ["write", "bitmap", "slow"], [KSpec{["RW", "access", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"setbit"}, R.RInt{R.IPos{4n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@bitmap"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Sets or clears the bit at offset in the string value stored at key"}, R.RBulk{"since"}, R.RBulk{"2.2.0"}, R.RBulk{"group"}, R.RBulk{"bitmap"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"offset"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"value"}, R.RBulk{"type"}, R.RBulk{"integer"}]}]}]},
  []}

def cmd.setex() -> Top:
  Top{Desc{"setex", R.IPos{4n}, ["write", "string", "slow"], [KSpec{["OW", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"setex"}, R.RInt{R.IPos{4n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@string"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"OW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Set the value and expiration of a key"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"seconds"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"value"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]},
  []}

def cmd.setnx() -> Top:
  Top{Desc{"setnx", R.IPos{3n}, ["write", "string", "fast"], [KSpec{["OW", "insert"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"setnx"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@string"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"OW"}, R.RStatus{"insert"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Set the value of a key, only if the key does not exist"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"value"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]},
  []}

def cmd.setrange() -> Top:
  Top{Desc{"setrange", R.IPos{4n}, ["write", "string", "slow"], [KSpec{["RW", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"setrange"}, R.RInt{R.IPos{4n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@string"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Overwrite part of a string at key starting at the specified offset"}, R.RBulk{"since"}, R.RBulk{"2.2.0"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(1), not counting the time taken to copy the new string in place. Usually, this string is very small so the amortized complexity is O(1). Otherwise, complexity is O(M) with M being the length of the value argument."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"offset"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"value"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]},
  []}

def cmd.shutdown() -> Top:
  Top{Desc{"shutdown", R.INeg{0n}, ["admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"shutdown"}, R.RInt{R.INeg{0n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}, R.RStatus{"no_multi"}, R.RStatus{"allow_busy"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Synchronously save the dataset to disk and then shut down the server"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N) when saving, where N is the total number of keys in all databases when saving data, otherwise O(1)"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"7.0.0"}, R.RBulk{"Added the `NOW`, `FORCE` and `ABORT` modifiers."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"nosave_save"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"nosave"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"NOSAVE"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"save"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"SAVE"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"now"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"NOW"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"force"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"FORCE"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"abort"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ABORT"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.sinter() -> Top:
  Top{Desc{"sinter", R.INeg{1n}, ["read", "set", "slow"], [KSpec{["RO", "access"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"sinter"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.INeg{0n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@set"}, R.RStatus{"@slow"}]}, R.RSet{[R.RBulk{"nondeterministic_output_order"}]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.INeg{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Intersect multiple sets"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"set"}, R.RBulk{"complexity"}, R.RBulk{"O(N*M) worst case where N is the cardinality of the smallest set and M is the number of sets."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.sintercard() -> Top:
  Top{Desc{"sintercard", R.INeg{2n}, ["read", "set", "slow"], [], KBySintercard{}, False{},
    [R.RBulk{"sintercard"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"movablekeys"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@set"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"keynum"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"keynumidx"}, R.RInt{R.IPos{0n}}, R.RBulk{"firstkey"}, R.RInt{R.IPos{1n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Intersect multiple sets and return the cardinality of the result"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"set"}, R.RBulk{"complexity"}, R.RBulk{"O(N*M) worst case where N is the cardinality of the smallest set and M is the number of sets."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"numkeys"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"limit"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"LIMIT"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.sinterstore() -> Top:
  Top{Desc{"sinterstore", R.INeg{2n}, ["write", "set", "slow"], [KSpec{["RW", "update"], 1n, R.IPos{0n}, 1n, 0n}, KSpec{["RO", "access"], 2n, R.INeg{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"sinterstore"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.INeg{0n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@set"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}, R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.INeg{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Intersect multiple sets and store the resulting set in a key"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"set"}, R.RBulk{"complexity"}, R.RBulk{"O(N*M) worst case where N is the cardinality of the smallest set and M is the number of sets."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"destination"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{1n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.sismember() -> Top:
  Top{Desc{"sismember", R.IPos{3n}, ["read", "set", "fast"], [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"sismember"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@set"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Determine if a given value is a member of a set"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"set"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"member"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]},
  []}

def cmd.slowlog() -> Top:
  Top{Desc{"slowlog", R.INeg{1n}, ["slow"], [], KBySpecs{}, False{},
    [R.RBulk{"slowlog"}, R.RInt{R.INeg{1n}}, R.RSet{[]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"A container for slow log commands"}, R.RBulk{"since"}, R.RBulk{"2.2.12"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"Depends on subcommand."}]},
  [Desc{"slowlog|get", R.INeg{1n}, ["admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"slowlog|get"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[R.RBulk{"request_policy:all_nodes"}, R.RBulk{"nondeterministic_output"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the slow log's entries"}, R.RBulk{"since"}, R.RBulk{"2.2.12"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of entries returned"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"4.0.0"}, R.RBulk{"Added client IP address, port and name to the reply."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]}, Desc{"slowlog|help", R.IPos{2n}, ["slow"], [], KBySpecs{}, False{},
    [R.RBulk{"slowlog|help"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Show helpful text about the different subcommands"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"slowlog|len", R.IPos{2n}, ["admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"slowlog|len"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[R.RBulk{"request_policy:all_nodes"}, R.RBulk{"response_policy:agg_sum"}, R.RBulk{"nondeterministic_output"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the slow log's length"}, R.RBulk{"since"}, R.RBulk{"2.2.12"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"slowlog|reset", R.IPos{2n}, ["admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"slowlog|reset"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"admin"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[R.RBulk{"request_policy:all_nodes"}, R.RBulk{"response_policy:all_succeeded"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Clear all entries from the slow log"}, R.RBulk{"since"}, R.RBulk{"2.2.12"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of entries in the slowlog"}]}]}

def cmd.smembers() -> Top:
  Top{Desc{"smembers", R.IPos{2n}, ["read", "set", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"smembers"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@set"}, R.RStatus{"@slow"}]}, R.RSet{[R.RBulk{"nondeterministic_output_order"}]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get all the members in a set"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"set"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the set cardinality."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]},
  []}

def cmd.smismember() -> Top:
  Top{Desc{"smismember", R.INeg{2n}, ["read", "set", "fast"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"smismember"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@set"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Returns the membership associated with the given elements for a set"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"group"}, R.RBulk{"set"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of elements being checked for membership"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"member"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.smove() -> Top:
  Top{Desc{"smove", R.IPos{4n}, ["write", "set", "fast"], [KSpec{["RW", "access", "delete"], 1n, R.IPos{0n}, 1n, 0n}, KSpec{["RW", "insert"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"smove"}, R.RInt{R.IPos{4n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{2n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@set"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}, R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"insert"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Move a member from one set to another"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"set"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"source"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"destination"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{1n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"member"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]},
  []}

def cmd.sort() -> Top:
  Top{Desc{"sort", R.INeg{1n}, ["write", "set", "sortedset", "list", "slow", "dangerous"], [], KBySort{}, False{},
    [R.RBulk{"sort"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"movablekeys"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@set"}, R.RStatus{"@sortedset"}, R.RStatus{"@list"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}, R.RMap{[R.RBulk{"notes"}, R.RBulk{"For the optional BY/GET keyword. It is marked 'unknown' because the key names derive from the content of the key we sort"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"unknown"}, R.RBulk{"spec"}, R.RMap{[]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"unknown"}, R.RBulk{"spec"}, R.RMap{[]}]}]}, R.RMap{[R.RBulk{"notes"}, R.RBulk{"For the optional STORE keyword. It is marked 'unknown' because the keyword can appear anywhere in the argument array"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"OW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"unknown"}, R.RBulk{"spec"}, R.RMap{[]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"unknown"}, R.RBulk{"spec"}, R.RMap{[]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Sort the elements in a list, set or sorted set"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(N+M*log(M)) where N is the number of elements in the list or set to sort, and M the number of returned elements. When the elements are not sorted, complexity is O(N)."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"pattern"}, R.RBulk{"type"}, R.RBulk{"pattern"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{1n}}, R.RBulk{"token"}, R.RBulk{"BY"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"offset_count"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"token"}, R.RBulk{"LIMIT"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"offset"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"pattern"}, R.RBulk{"type"}, R.RBulk{"pattern"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{1n}}, R.RBulk{"token"}, R.RBulk{"GET"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}, R.RStatus{"multiple"}, R.RStatus{"multiple_token"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"order"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"asc"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ASC"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"desc"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"DESC"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"sorting"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ALPHA"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"destination"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{2n}}, R.RBulk{"token"}, R.RBulk{"STORE"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.sort_ro() -> Top:
  Top{Desc{"sort_ro", R.INeg{1n}, ["read", "set", "sortedset", "list", "slow", "dangerous"], [], KBySortRo{}, False{},
    [R.RBulk{"sort_ro"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"movablekeys"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@set"}, R.RStatus{"@sortedset"}, R.RStatus{"@list"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}, R.RMap{[R.RBulk{"notes"}, R.RBulk{"For the optional BY/GET keyword. It is marked 'unknown' because the key names derive from the content of the key we sort"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"unknown"}, R.RBulk{"spec"}, R.RMap{[]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"unknown"}, R.RBulk{"spec"}, R.RMap{[]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Sort the elements in a list, set or sorted set. Read-only variant of SORT."}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(N+M*log(M)) where N is the number of elements in the list or set to sort, and M the number of returned elements. When the elements are not sorted, complexity is O(N)."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"pattern"}, R.RBulk{"type"}, R.RBulk{"pattern"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{1n}}, R.RBulk{"token"}, R.RBulk{"BY"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"offset_count"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"token"}, R.RBulk{"LIMIT"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"offset"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"pattern"}, R.RBulk{"type"}, R.RBulk{"pattern"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{1n}}, R.RBulk{"token"}, R.RBulk{"GET"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}, R.RStatus{"multiple"}, R.RStatus{"multiple_token"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"order"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"asc"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ASC"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"desc"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"DESC"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"sorting"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ALPHA"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.spop() -> Top:
  Top{Desc{"spop", R.INeg{1n}, ["write", "set", "fast"], [KSpec{["RW", "access", "delete"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"spop"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@set"}, R.RStatus{"@fast"}]}, R.RSet{[R.RBulk{"nondeterministic_output"}]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Remove and return one or multiple random members from a set"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"set"}, R.RBulk{"complexity"}, R.RBulk{"Without the count argument O(1), otherwise O(N) where N is the value of the passed count."}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"3.2.0"}, R.RBulk{"Added the `count` argument."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"since"}, R.RBulk{"3.2.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.spublish() -> Top:
  Top{Desc{"spublish", R.IPos{3n}, ["pubsub", "fast"], [KSpec{["not_key"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"spublish"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"pubsub"}, R.RStatus{"loading"}, R.RStatus{"stale"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@pubsub"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"not_key"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Post a message to a shard channel"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"pubsub"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of clients subscribed to the receiving shard channel."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"shardchannel"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"message"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]},
  []}

def cmd.srandmember() -> Top:
  Top{Desc{"srandmember", R.INeg{1n}, ["read", "set", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"srandmember"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@set"}, R.RStatus{"@slow"}]}, R.RSet{[R.RBulk{"nondeterministic_output"}]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get one or multiple random members from a set"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"set"}, R.RBulk{"complexity"}, R.RBulk{"Without the count argument O(1), otherwise O(N) where N is the absolute value of the passed count."}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"2.6.0"}, R.RBulk{"Added the optional `count` argument."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"since"}, R.RBulk{"2.6.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.srem() -> Top:
  Top{Desc{"srem", R.INeg{2n}, ["write", "set", "fast"], [KSpec{["RW", "delete"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"srem"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@set"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Remove one or more members from a set"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"set"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of members to be removed."}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"2.4.0"}, R.RBulk{"Accepts multiple `member` arguments."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"member"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.sscan() -> Top:
  Top{Desc{"sscan", R.INeg{2n}, ["read", "set", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"sscan"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@set"}, R.RStatus{"@slow"}]}, R.RSet{[R.RBulk{"nondeterministic_output"}]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Incrementally iterate Set elements"}, R.RBulk{"since"}, R.RBulk{"2.8.0"}, R.RBulk{"group"}, R.RBulk{"set"}, R.RBulk{"complexity"}, R.RBulk{"O(1) for every call. O(N) for a complete iteration, including enough command calls for the cursor to return back to 0. N is the number of elements inside the collection.."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"cursor"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"pattern"}, R.RBulk{"type"}, R.RBulk{"pattern"}, R.RBulk{"token"}, R.RBulk{"MATCH"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"COUNT"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.ssubscribe() -> Top:
  Top{Desc{"ssubscribe", R.INeg{1n}, ["pubsub", "slow"], [KSpec{["not_key"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"ssubscribe"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"pubsub"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.INeg{0n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@pubsub"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"not_key"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.INeg{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Listen for messages published to the given shard channels"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"pubsub"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of shard channels to subscribe to."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"shardchannel"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.strlen() -> Top:
  Top{Desc{"strlen", R.IPos{2n}, ["read", "string", "fast"], [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"strlen"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@string"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the length of the value stored in a key"}, R.RBulk{"since"}, R.RBulk{"2.2.0"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]},
  []}

def cmd.subscribe() -> Top:
  Top{Desc{"subscribe", R.INeg{1n}, ["pubsub", "slow"], [], KBySpecs{}, False{},
    [R.RBulk{"subscribe"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"pubsub"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@pubsub"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Listen for messages published to the given channels"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"pubsub"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of channels to subscribe to."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"channel"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.substr() -> Top:
  Top{Desc{"substr", R.IPos{4n}, ["read", "string", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"substr"}, R.RInt{R.IPos{4n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@string"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get a substring of the string stored at a key"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the length of the returned string. The complexity is ultimately determined by the returned length, but because creating a substring from an existing string is very cheap, it can be considered O(1) for small strings."}, R.RBulk{"doc_flags"}, R.RSet{[R.RStatus{"deprecated"}]}, R.RBulk{"deprecated_since"}, R.RBulk{"2.0.0"}, R.RBulk{"replaced_by"}, R.RBulk{"`GETRANGE`"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"start"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"end"}, R.RBulk{"type"}, R.RBulk{"integer"}]}]}]},
  []}

def cmd.sunion() -> Top:
  Top{Desc{"sunion", R.INeg{1n}, ["read", "set", "slow"], [KSpec{["RO", "access"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"sunion"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.INeg{0n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@set"}, R.RStatus{"@slow"}]}, R.RSet{[R.RBulk{"nondeterministic_output_order"}]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.INeg{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Add multiple sets"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"set"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the total number of elements in all given sets."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.sunionstore() -> Top:
  Top{Desc{"sunionstore", R.INeg{2n}, ["write", "set", "slow"], [KSpec{["OW", "update"], 1n, R.IPos{0n}, 1n, 0n}, KSpec{["RO", "access"], 2n, R.INeg{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"sunionstore"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.INeg{0n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@set"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"OW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}, R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.INeg{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Add multiple sets and store the resulting set in a key"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"set"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the total number of elements in all given sets."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"destination"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{1n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.sunsubscribe() -> Top:
  Top{Desc{"sunsubscribe", R.INeg{0n}, ["pubsub", "slow"], [KSpec{["not_key"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"sunsubscribe"}, R.RInt{R.INeg{0n}}, R.RSet{[R.RStatus{"pubsub"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.INeg{0n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@pubsub"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"not_key"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.INeg{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Stop listening for messages posted to the given shard channels"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"pubsub"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of clients already subscribed to a shard channel."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"shardchannel"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}, R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.swapdb() -> Top:
  Top{Desc{"swapdb", R.IPos{3n}, ["keyspace", "write", "fast", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"swapdb"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@write"}, R.RStatus{"@fast"}, R.RStatus{"@dangerous"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Swaps two Redis databases"}, R.RBulk{"since"}, R.RBulk{"4.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the count of clients watching or blocking on keys from both databases."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"index1"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"index2"}, R.RBulk{"type"}, R.RBulk{"integer"}]}]}]},
  []}

def cmd.time() -> Top:
  Top{Desc{"time", R.IPos{1n}, ["fast"], [], KBySpecs{}, False{},
    [R.RBulk{"time"}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"loading"}, R.RStatus{"stale"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@fast"}]}, R.RSet{[R.RBulk{"nondeterministic_output"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Return the current server time"}, R.RBulk{"since"}, R.RBulk{"2.6.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]},
  []}

def cmd.touch() -> Top:
  Top{Desc{"touch", R.INeg{1n}, ["keyspace", "read", "fast"], [KSpec{["RO"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"touch"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.INeg{0n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@read"}, R.RStatus{"@fast"}]}, R.RSet{[R.RBulk{"request_policy:multi_shard"}, R.RBulk{"response_policy:agg_sum"}]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.INeg{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Alters the last access time of a key(s). Returns the number of existing keys specified."}, R.RBulk{"since"}, R.RBulk{"3.2.1"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of keys that will be touched."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.ttl() -> Top:
  Top{Desc{"ttl", R.IPos{2n}, ["keyspace", "read", "fast"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"ttl"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@read"}, R.RStatus{"@fast"}]}, R.RSet{[R.RBulk{"nondeterministic_output"}]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the time to live for a key in seconds"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"2.8.0"}, R.RBulk{"Added the -2 reply."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]},
  []}

def cmd.type() -> Top:
  Top{Desc{"type", R.IPos{2n}, ["keyspace", "read", "fast"], [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"type"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@read"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Determine the type stored at key"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]},
  []}

def cmd.unlink() -> Top:
  Top{Desc{"unlink", R.INeg{1n}, ["keyspace", "write", "fast"], [KSpec{["RM", "delete"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"unlink"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.INeg{0n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@keyspace"}, R.RStatus{"@write"}, R.RStatus{"@fast"}]}, R.RSet{[R.RBulk{"request_policy:multi_shard"}, R.RBulk{"response_policy:agg_sum"}]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RM"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.INeg{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Delete a key asynchronously in another thread. Otherwise it is just as DEL, but non blocking."}, R.RBulk{"since"}, R.RBulk{"4.0.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(1) for each key removed regardless of its size. Then the command does O(N) work in a different thread in order to reclaim memory, where N is the number of allocations the deleted objects where composed of."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.unsubscribe() -> Top:
  Top{Desc{"unsubscribe", R.INeg{0n}, ["pubsub", "slow"], [], KBySpecs{}, False{},
    [R.RBulk{"unsubscribe"}, R.RInt{R.INeg{0n}}, R.RSet{[R.RStatus{"pubsub"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@pubsub"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Stop listening for messages posted to the given channels"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"pubsub"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of clients already subscribed to a channel."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"channel"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}, R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.unwatch() -> Top:
  Top{Desc{"unwatch", R.IPos{1n}, ["fast", "transaction"], [], KBySpecs{}, False{},
    [R.RBulk{"unwatch"}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}, R.RStatus{"fast"}, R.RStatus{"allow_busy"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@fast"}, R.RStatus{"@transaction"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Forget about all watched keys"}, R.RBulk{"since"}, R.RBulk{"2.2.0"}, R.RBulk{"group"}, R.RBulk{"transactions"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]},
  []}

def cmd.wait() -> Top:
  Top{Desc{"wait", R.IPos{3n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"wait"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"noscript"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RSet{[R.RBulk{"request_policy:all_shards"}, R.RBulk{"response_policy:agg_min"}]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Wait for the synchronous replication of all the write commands sent in the context of the current connection"}, R.RBulk{"since"}, R.RBulk{"3.0.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"numreplicas"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"timeout"}, R.RBulk{"type"}, R.RBulk{"integer"}]}]}]},
  []}

def cmd.watch() -> Top:
  Top{Desc{"watch", R.INeg{1n}, ["fast", "transaction"], [KSpec{["RO"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"watch"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}, R.RStatus{"fast"}, R.RStatus{"allow_busy"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.INeg{0n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@fast"}, R.RStatus{"@transaction"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.INeg{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Watch the given keys to determine execution of the MULTI/EXEC block"}, R.RBulk{"since"}, R.RBulk{"2.2.0"}, R.RBulk{"group"}, R.RBulk{"transactions"}, R.RBulk{"complexity"}, R.RBulk{"O(1) for every key."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.xinfo() -> Top:
  Top{Desc{"xinfo", R.INeg{1n}, ["slow"], [], KBySpecs{}, False{},
    [R.RBulk{"xinfo"}, R.RInt{R.INeg{1n}}, R.RSet{[]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"A container for stream introspection commands"}, R.RBulk{"since"}, R.RBulk{"5.0.0"}, R.RBulk{"group"}, R.RBulk{"stream"}, R.RBulk{"complexity"}, R.RBulk{"Depends on subcommand."}]},
  [Desc{"xinfo|consumers", R.IPos{4n}, ["read", "stream", "slow"], [KSpec{["RO", "access"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"xinfo|consumers"}, R.RInt{R.IPos{4n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{2n}}, R.RInt{R.IPos{2n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@stream"}, R.RStatus{"@slow"}]}, R.RSet{[R.RBulk{"nondeterministic_output"}]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"List the consumers in a consumer group"}, R.RBulk{"since"}, R.RBulk{"5.0.0"}, R.RBulk{"group"}, R.RBulk{"stream"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"groupname"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]}, Desc{"xinfo|groups", R.IPos{3n}, ["read", "stream", "slow"], [KSpec{["RO", "access"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"xinfo|groups"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{2n}}, R.RInt{R.IPos{2n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@stream"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"List the consumer groups of a stream"}, R.RBulk{"since"}, R.RBulk{"5.0.0"}, R.RBulk{"group"}, R.RBulk{"stream"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"7.0.0"}, R.RBulk{"Added the `entries-read` and `lag` fields"}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]}, Desc{"xinfo|help", R.IPos{2n}, ["stream", "slow"], [], KBySpecs{}, False{},
    [R.RBulk{"xinfo|help"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@stream"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Show helpful text about the different subcommands"}, R.RBulk{"since"}, R.RBulk{"5.0.0"}, R.RBulk{"group"}, R.RBulk{"stream"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"xinfo|stream", R.INeg{2n}, ["read", "stream", "slow"], [KSpec{["RO", "access"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"xinfo|stream"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{2n}}, R.RInt{R.IPos{2n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@stream"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get information about a stream"}, R.RBulk{"since"}, R.RBulk{"5.0.0"}, R.RBulk{"group"}, R.RBulk{"stream"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"6.0.0"}, R.RBulk{"Added the `FULL` modifier."}]}, R.RArray{[R.RBulk{"7.0.0"}, R.RBulk{"Added the `max-deleted-entry-id`, `entries-added`, `recorded-first-entry-id`, `entries-read` and `lag` fields"}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"full"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"token"}, R.RBulk{"FULL"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"COUNT"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]}]}]}]}

def cmd.xlen() -> Top:
  Top{Desc{"xlen", R.IPos{2n}, ["read", "stream", "fast"], [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"xlen"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@stream"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Return the number of entries in a stream"}, R.RBulk{"since"}, R.RBulk{"5.0.0"}, R.RBulk{"group"}, R.RBulk{"stream"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]},
  []}

def cmd.xpending() -> Top:
  Top{Desc{"xpending", R.INeg{2n}, ["read", "stream", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"xpending"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@stream"}, R.RStatus{"@slow"}]}, R.RSet{[R.RBulk{"nondeterministic_output"}]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Return information and entries from a stream consumer group pending entries list, that are messages fetched but never acknowledged."}, R.RBulk{"since"}, R.RBulk{"5.0.0"}, R.RBulk{"group"}, R.RBulk{"stream"}, R.RBulk{"complexity"}, R.RBulk{"O(N) with N being the number of elements returned, so asking for a small fixed number of entries per call is O(1). O(M), where M is the total number of entries scanned when used with the IDLE filter. When the command returns just the summary and the list of consumers is small, it runs in O(1) time; otherwise, an additional O(N) time for iterating every consumer."}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"6.2.0"}, R.RBulk{"Added the `IDLE` option and exclusive range intervals."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"group"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"filters"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"min-idle-time"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"IDLE"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"start"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"end"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"consumer"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]}]}]},
  []}

def cmd.xrange() -> Top:
  Top{Desc{"xrange", R.INeg{3n}, ["read", "stream", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"xrange"}, R.RInt{R.INeg{3n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@stream"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Return a range of elements in a stream, with IDs matching the specified IDs interval"}, R.RBulk{"since"}, R.RBulk{"5.0.0"}, R.RBulk{"group"}, R.RBulk{"stream"}, R.RBulk{"complexity"}, R.RBulk{"O(N) with N being the number of elements being returned. If N is constant (e.g. always asking for the first 10 elements with COUNT), you can consider it O(1)."}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"6.2.0"}, R.RBulk{"Added exclusive ranges."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"start"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"end"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"COUNT"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.xread() -> Top:
  Top{Desc{"xread", R.INeg{3n}, ["read", "stream", "slow", "blocking"], [KSpecKw{["RO", "access"], "STREAMS", 1n, R.INeg{0n}, 1n, 2n}], KBySpecs{}, False{},
    [R.RBulk{"xread"}, R.RInt{R.INeg{3n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"blocking"}, R.RStatus{"movablekeys"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@stream"}, R.RStatus{"@slow"}, R.RStatus{"@blocking"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"keyword"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"keyword"}, R.RBulk{"STREAMS"}, R.RBulk{"startfrom"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.INeg{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{2n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Return never seen elements in multiple streams, with IDs greater than the ones reported by the caller for each stream. Can block."}, R.RBulk{"since"}, R.RBulk{"5.0.0"}, R.RBulk{"group"}, R.RBulk{"stream"}, R.RBulk{"complexity"}, R.RBulk{"For each stream mentioned: O(N) with N being the number of elements being returned, it means that XREAD-ing with a fixed COUNT is O(1). Note that when the BLOCK option is used, XADD will pay O(M) time in order to serve the M clients blocked on the stream getting new data."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"COUNT"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"milliseconds"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"BLOCK"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"streams"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"token"}, R.RBulk{"STREAMS"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"id"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]}]}]},
  []}

def cmd.xrevrange() -> Top:
  Top{Desc{"xrevrange", R.INeg{3n}, ["read", "stream", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"xrevrange"}, R.RInt{R.INeg{3n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@stream"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Return a range of elements in a stream, with IDs matching the specified IDs interval, in reverse order (from greater to smaller IDs) compared to XRANGE"}, R.RBulk{"since"}, R.RBulk{"5.0.0"}, R.RBulk{"group"}, R.RBulk{"stream"}, R.RBulk{"complexity"}, R.RBulk{"O(N) with N being the number of elements returned. If N is constant (e.g. always asking for the first 10 elements with COUNT), you can consider it O(1)."}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"6.2.0"}, R.RBulk{"Added exclusive ranges."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"end"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"start"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"COUNT"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.zadd() -> Top:
  Top{Desc{"zadd", R.INeg{3n}, ["write", "sortedset", "fast"], [KSpec{["RW", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"zadd"}, R.RInt{R.INeg{3n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@sortedset"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Add one or more members to a sorted set, or update its score if it already exists"}, R.RBulk{"since"}, R.RBulk{"1.2.0"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(log(N)) for each item added, where N is the number of elements in the sorted set."}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"2.4.0"}, R.RBulk{"Accepts multiple elements."}]}, R.RArray{[R.RBulk{"3.0.2"}, R.RBulk{"Added the `XX`, `NX`, `CH` and `INCR` options."}]}, R.RArray{[R.RBulk{"6.2.0"}, R.RBulk{"Added the `GT` and `LT` options."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"condition"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"since"}, R.RBulk{"3.0.2"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"nx"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"NX"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"xx"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"XX"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"comparison"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"gt"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"GT"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"lt"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"LT"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"change"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"CH"}, R.RBulk{"since"}, R.RBulk{"3.0.2"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"increment"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"INCR"}, R.RBulk{"since"}, R.RBulk{"3.0.2"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"score_member"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"score"}, R.RBulk{"type"}, R.RBulk{"double"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"member"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]}]}]},
  []}

def cmd.zcard() -> Top:
  Top{Desc{"zcard", R.IPos{2n}, ["read", "sortedset", "fast"], [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"zcard"}, R.RInt{R.IPos{2n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@sortedset"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the number of members in a sorted set"}, R.RBulk{"since"}, R.RBulk{"1.2.0"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]},
  []}

def cmd.zcount() -> Top:
  Top{Desc{"zcount", R.IPos{4n}, ["read", "sortedset", "fast"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"zcount"}, R.RInt{R.IPos{4n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@sortedset"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Count the members in a sorted set with scores within the given values"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(log(N)) with N being the number of elements in the sorted set."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"min"}, R.RBulk{"type"}, R.RBulk{"double"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"max"}, R.RBulk{"type"}, R.RBulk{"double"}]}]}]},
  []}

def cmd.zdiff() -> Top:
  Top{Desc{"zdiff", R.INeg{2n}, ["read", "sortedset", "slow"], [], KBySintercard{}, False{},
    [R.RBulk{"zdiff"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"movablekeys"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@sortedset"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"keynum"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"keynumidx"}, R.RInt{R.IPos{0n}}, R.RBulk{"firstkey"}, R.RInt{R.IPos{1n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Subtract multiple sorted sets"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(L + (N-K)log(N)) worst case where L is the total number of elements in all the sets, N is the size of the first set, and K is the size of the result set."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"numkeys"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"withscores"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"WITHSCORES"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.zdiffstore() -> Top:
  Top{Desc{"zdiffstore", R.INeg{3n}, ["write", "sortedset", "slow"], [], KByZstore{}, False{},
    [R.RBulk{"zdiffstore"}, R.RInt{R.INeg{3n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"movablekeys"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@sortedset"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"OW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}, R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"keynum"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"keynumidx"}, R.RInt{R.IPos{0n}}, R.RBulk{"firstkey"}, R.RInt{R.IPos{1n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Subtract multiple sorted sets and store the resulting sorted set in a new key"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(L + (N-K)log(N)) worst case where L is the total number of elements in all the sets, N is the size of the first set, and K is the size of the result set."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"destination"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"numkeys"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{1n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.zincrby() -> Top:
  Top{Desc{"zincrby", R.IPos{4n}, ["write", "sortedset", "fast"], [KSpec{["RW", "access", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"zincrby"}, R.RInt{R.IPos{4n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@sortedset"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Increment the score of a member in a sorted set"}, R.RBulk{"since"}, R.RBulk{"1.2.0"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(log(N)) where N is the number of elements in the sorted set."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"increment"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"member"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]},
  []}

def cmd.zinter() -> Top:
  Top{Desc{"zinter", R.INeg{2n}, ["read", "sortedset", "slow"], [], KBySintercard{}, False{},
    [R.RBulk{"zinter"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"movablekeys"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@sortedset"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"keynum"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"keynumidx"}, R.RInt{R.IPos{0n}}, R.RBulk{"firstkey"}, R.RInt{R.IPos{1n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Intersect multiple sorted sets"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(N*K)+O(M*log(M)) worst case with N being the smallest input sorted set, K being the number of input sorted sets and M being the number of elements in the resulting sorted set."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"numkeys"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"weight"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"WEIGHTS"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}, R.RStatus{"multiple"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"aggregate"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"token"}, R.RBulk{"AGGREGATE"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"sum"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"SUM"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"min"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"MIN"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"max"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"MAX"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"withscores"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"WITHSCORES"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.zintercard() -> Top:
  Top{Desc{"zintercard", R.INeg{2n}, ["read", "sortedset", "slow"], [], KBySintercard{}, False{},
    [R.RBulk{"zintercard"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"movablekeys"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@sortedset"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"keynum"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"keynumidx"}, R.RInt{R.IPos{0n}}, R.RBulk{"firstkey"}, R.RInt{R.IPos{1n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Intersect multiple sorted sets and return the cardinality of the result"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(N*K) worst case with N being the smallest input sorted set, K being the number of input sorted sets."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"numkeys"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"limit"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"LIMIT"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.zinterstore() -> Top:
  Top{Desc{"zinterstore", R.INeg{3n}, ["write", "sortedset", "slow"], [], KByZstore{}, False{},
    [R.RBulk{"zinterstore"}, R.RInt{R.INeg{3n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"movablekeys"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@sortedset"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"OW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}, R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"keynum"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"keynumidx"}, R.RInt{R.IPos{0n}}, R.RBulk{"firstkey"}, R.RInt{R.IPos{1n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Intersect multiple sorted sets and store the resulting sorted set in a new key"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(N*K)+O(M*log(M)) worst case with N being the smallest input sorted set, K being the number of input sorted sets and M being the number of elements in the resulting sorted set."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"destination"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"numkeys"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{1n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"weight"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"WEIGHTS"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}, R.RStatus{"multiple"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"aggregate"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"token"}, R.RBulk{"AGGREGATE"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"sum"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"SUM"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"min"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"MIN"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"max"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"MAX"}]}]}]}]}]},
  []}

def cmd.zlexcount() -> Top:
  Top{Desc{"zlexcount", R.IPos{4n}, ["read", "sortedset", "fast"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"zlexcount"}, R.RInt{R.IPos{4n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@sortedset"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Count the number of members in a sorted set between a given lexicographical range"}, R.RBulk{"since"}, R.RBulk{"2.8.9"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(log(N)) with N being the number of elements in the sorted set."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"min"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"max"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]},
  []}

def cmd.zmpop() -> Top:
  Top{Desc{"zmpop", R.INeg{3n}, ["write", "sortedset", "slow"], [], KByLmpop{}, False{},
    [R.RBulk{"zmpop"}, R.RInt{R.INeg{3n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"movablekeys"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@sortedset"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"keynum"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"keynumidx"}, R.RInt{R.IPos{0n}}, R.RBulk{"firstkey"}, R.RInt{R.IPos{1n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Remove and return members with scores in a sorted set"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(K) + O(M*log(N)) where K is the number of provided keys, N being the number of elements in the sorted set, and M being the number of elements popped."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"numkeys"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"where"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"min"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"MIN"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"max"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"MAX"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"COUNT"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.zmscore() -> Top:
  Top{Desc{"zmscore", R.INeg{2n}, ["read", "sortedset", "fast"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"zmscore"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@sortedset"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the score associated with the given members in a sorted set"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of members being requested."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"member"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.zpopmax() -> Top:
  Top{Desc{"zpopmax", R.INeg{1n}, ["write", "sortedset", "fast"], [KSpec{["RW", "access", "delete"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"zpopmax"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@sortedset"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Remove and return members with the highest scores in a sorted set"}, R.RBulk{"since"}, R.RBulk{"5.0.0"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(log(N)*M) with N being the number of elements in the sorted set, and M being the number of elements popped."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.zpopmin() -> Top:
  Top{Desc{"zpopmin", R.INeg{1n}, ["write", "sortedset", "fast"], [KSpec{["RW", "access", "delete"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"zpopmin"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@sortedset"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Remove and return members with the lowest scores in a sorted set"}, R.RBulk{"since"}, R.RBulk{"5.0.0"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(log(N)*M) with N being the number of elements in the sorted set, and M being the number of elements popped."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.zrandmember() -> Top:
  Top{Desc{"zrandmember", R.INeg{1n}, ["read", "sortedset", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"zrandmember"}, R.RInt{R.INeg{1n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@sortedset"}, R.RStatus{"@slow"}]}, R.RSet{[R.RBulk{"nondeterministic_output"}]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get one or multiple random elements from a sorted set"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of elements returned"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"options"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"withscores"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"WITHSCORES"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]}]}]},
  []}

def cmd.zrange() -> Top:
  Top{Desc{"zrange", R.INeg{3n}, ["read", "sortedset", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"zrange"}, R.RInt{R.INeg{3n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@sortedset"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Return a range of members in a sorted set"}, R.RBulk{"since"}, R.RBulk{"1.2.0"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(log(N)+M) with N being the number of elements in the sorted set and M the number of elements returned."}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"6.2.0"}, R.RBulk{"Added the `REV`, `BYSCORE`, `BYLEX` and `LIMIT` options."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"start"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"stop"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"sortby"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"byscore"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"BYSCORE"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"bylex"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"BYLEX"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"rev"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"REV"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"offset_count"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"token"}, R.RBulk{"LIMIT"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"offset"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"withscores"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"WITHSCORES"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.zrangebylex() -> Top:
  Top{Desc{"zrangebylex", R.INeg{3n}, ["read", "sortedset", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"zrangebylex"}, R.RInt{R.INeg{3n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@sortedset"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Return a range of members in a sorted set, by lexicographical range"}, R.RBulk{"since"}, R.RBulk{"2.8.9"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(log(N)+M) with N being the number of elements in the sorted set and M the number of elements being returned. If M is constant (e.g. always asking for the first 10 elements with LIMIT), you can consider it O(log(N))."}, R.RBulk{"doc_flags"}, R.RSet{[R.RStatus{"deprecated"}]}, R.RBulk{"deprecated_since"}, R.RBulk{"6.2.0"}, R.RBulk{"replaced_by"}, R.RBulk{"`ZRANGE` with the `BYLEX` argument"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"min"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"max"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"offset_count"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"token"}, R.RBulk{"LIMIT"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"offset"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}]}]}]}]}]},
  []}

def cmd.zrangebyscore() -> Top:
  Top{Desc{"zrangebyscore", R.INeg{3n}, ["read", "sortedset", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"zrangebyscore"}, R.RInt{R.INeg{3n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@sortedset"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Return a range of members in a sorted set, by score"}, R.RBulk{"since"}, R.RBulk{"1.0.5"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(log(N)+M) with N being the number of elements in the sorted set and M the number of elements being returned. If M is constant (e.g. always asking for the first 10 elements with LIMIT), you can consider it O(log(N))."}, R.RBulk{"doc_flags"}, R.RSet{[R.RStatus{"deprecated"}]}, R.RBulk{"deprecated_since"}, R.RBulk{"6.2.0"}, R.RBulk{"replaced_by"}, R.RBulk{"`ZRANGE` with the `BYSCORE` argument"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"2.0.0"}, R.RBulk{"Added the `WITHSCORES` modifier."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"min"}, R.RBulk{"type"}, R.RBulk{"double"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"max"}, R.RBulk{"type"}, R.RBulk{"double"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"withscores"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"WITHSCORES"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"offset_count"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"token"}, R.RBulk{"LIMIT"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"offset"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}]}]}]}]}]},
  []}

def cmd.zrangestore() -> Top:
  Top{Desc{"zrangestore", R.INeg{4n}, ["write", "sortedset", "slow"], [KSpec{["OW", "update"], 1n, R.IPos{0n}, 1n, 0n}, KSpec{["RO", "access"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"zrangestore"}, R.RInt{R.INeg{4n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{2n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@sortedset"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"OW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}, R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Store a range of members from sorted set into another key"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(log(N)+M) with N being the number of elements in the sorted set and M the number of elements stored into the destination key."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"dst"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"src"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{1n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"min"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"max"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"sortby"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"byscore"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"BYSCORE"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"bylex"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"BYLEX"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"rev"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"REV"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"offset_count"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"token"}, R.RBulk{"LIMIT"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"offset"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}]}]}]}]}]},
  []}

def cmd.zrank() -> Top:
  Top{Desc{"zrank", R.IPos{3n}, ["read", "sortedset", "fast"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"zrank"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@sortedset"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Determine the index of a member in a sorted set"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(log(N))"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"member"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]},
  []}

def cmd.zrem() -> Top:
  Top{Desc{"zrem", R.INeg{2n}, ["write", "sortedset", "fast"], [KSpec{["RW", "delete"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"zrem"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@sortedset"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Remove one or more members from a sorted set"}, R.RBulk{"since"}, R.RBulk{"1.2.0"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(M*log(N)) with N being the number of elements in the sorted set and M the number of elements to be removed."}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"2.4.0"}, R.RBulk{"Accepts multiple elements."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"member"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.zremrangebylex() -> Top:
  Top{Desc{"zremrangebylex", R.IPos{4n}, ["write", "sortedset", "slow"], [KSpec{["RW", "delete"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"zremrangebylex"}, R.RInt{R.IPos{4n}}, R.RSet{[R.RStatus{"write"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@sortedset"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Remove all members in a sorted set between the given lexicographical range"}, R.RBulk{"since"}, R.RBulk{"2.8.9"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(log(N)+M) with N being the number of elements in the sorted set and M the number of elements removed by the operation."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"min"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"max"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]},
  []}

def cmd.zremrangebyrank() -> Top:
  Top{Desc{"zremrangebyrank", R.IPos{4n}, ["write", "sortedset", "slow"], [KSpec{["RW", "delete"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"zremrangebyrank"}, R.RInt{R.IPos{4n}}, R.RSet{[R.RStatus{"write"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@sortedset"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Remove all members in a sorted set within the given indexes"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(log(N)+M) with N being the number of elements in the sorted set and M the number of elements removed by the operation."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"start"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"stop"}, R.RBulk{"type"}, R.RBulk{"integer"}]}]}]},
  []}

def cmd.zremrangebyscore() -> Top:
  Top{Desc{"zremrangebyscore", R.IPos{4n}, ["write", "sortedset", "slow"], [KSpec{["RW", "delete"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"zremrangebyscore"}, R.RInt{R.IPos{4n}}, R.RSet{[R.RStatus{"write"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@sortedset"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RW"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Remove all members in a sorted set within the given scores"}, R.RBulk{"since"}, R.RBulk{"1.2.0"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(log(N)+M) with N being the number of elements in the sorted set and M the number of elements removed by the operation."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"min"}, R.RBulk{"type"}, R.RBulk{"double"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"max"}, R.RBulk{"type"}, R.RBulk{"double"}]}]}]},
  []}

def cmd.zrevrange() -> Top:
  Top{Desc{"zrevrange", R.INeg{3n}, ["read", "sortedset", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"zrevrange"}, R.RInt{R.INeg{3n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@sortedset"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Return a range of members in a sorted set, by index, with scores ordered from high to low"}, R.RBulk{"since"}, R.RBulk{"1.2.0"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(log(N)+M) with N being the number of elements in the sorted set and M the number of elements returned."}, R.RBulk{"doc_flags"}, R.RSet{[R.RStatus{"deprecated"}]}, R.RBulk{"deprecated_since"}, R.RBulk{"6.2.0"}, R.RBulk{"replaced_by"}, R.RBulk{"`ZRANGE` with the `REV` argument"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"start"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"stop"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"withscores"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"WITHSCORES"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.zrevrangebylex() -> Top:
  Top{Desc{"zrevrangebylex", R.INeg{3n}, ["read", "sortedset", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"zrevrangebylex"}, R.RInt{R.INeg{3n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@sortedset"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Return a range of members in a sorted set, by lexicographical range, ordered from higher to lower strings."}, R.RBulk{"since"}, R.RBulk{"2.8.9"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(log(N)+M) with N being the number of elements in the sorted set and M the number of elements being returned. If M is constant (e.g. always asking for the first 10 elements with LIMIT), you can consider it O(log(N))."}, R.RBulk{"doc_flags"}, R.RSet{[R.RStatus{"deprecated"}]}, R.RBulk{"deprecated_since"}, R.RBulk{"6.2.0"}, R.RBulk{"replaced_by"}, R.RBulk{"`ZRANGE` with the `REV` and `BYLEX` arguments"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"max"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"min"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"offset_count"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"token"}, R.RBulk{"LIMIT"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"offset"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}]}]}]}]}]},
  []}

def cmd.zrevrangebyscore() -> Top:
  Top{Desc{"zrevrangebyscore", R.INeg{3n}, ["read", "sortedset", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"zrevrangebyscore"}, R.RInt{R.INeg{3n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@sortedset"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Return a range of members in a sorted set, by score, with scores ordered from high to low"}, R.RBulk{"since"}, R.RBulk{"2.2.0"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(log(N)+M) with N being the number of elements in the sorted set and M the number of elements being returned. If M is constant (e.g. always asking for the first 10 elements with LIMIT), you can consider it O(log(N))."}, R.RBulk{"doc_flags"}, R.RSet{[R.RStatus{"deprecated"}]}, R.RBulk{"deprecated_since"}, R.RBulk{"6.2.0"}, R.RBulk{"replaced_by"}, R.RBulk{"`ZRANGE` with the `REV` and `BYSCORE` arguments"}, R.RBulk{"history"}, R.RSet{[R.RArray{[R.RBulk{"2.1.6"}, R.RBulk{"`min` and `max` can be exclusive."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"max"}, R.RBulk{"type"}, R.RBulk{"double"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"min"}, R.RBulk{"type"}, R.RBulk{"double"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"withscores"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"WITHSCORES"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"offset_count"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"token"}, R.RBulk{"LIMIT"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"offset"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}]}]}]}]}]},
  []}

def cmd.zrevrank() -> Top:
  Top{Desc{"zrevrank", R.IPos{3n}, ["read", "sortedset", "fast"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"zrevrank"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@sortedset"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Determine the index of a member in a sorted set, with scores ordered from high to low"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(log(N))"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"member"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]},
  []}

def cmd.zscan() -> Top:
  Top{Desc{"zscan", R.INeg{2n}, ["read", "sortedset", "slow"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"zscan"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@sortedset"}, R.RStatus{"@slow"}]}, R.RSet{[R.RBulk{"nondeterministic_output"}]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Incrementally iterate sorted sets elements and associated scores"}, R.RBulk{"since"}, R.RBulk{"2.8.0"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(1) for every call. O(N) for a complete iteration, including enough command calls for the cursor to return back to 0. N is the number of elements inside the collection.."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"cursor"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"pattern"}, R.RBulk{"type"}, R.RBulk{"pattern"}, R.RBulk{"token"}, R.RBulk{"MATCH"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"count"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"COUNT"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.zscore() -> Top:
  Top{Desc{"zscore", R.IPos{3n}, ["read", "sortedset", "fast"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"zscore"}, R.RInt{R.IPos{3n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@sortedset"}, R.RStatus{"@fast"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the score associated with the given member in a sorted set"}, R.RBulk{"since"}, R.RBulk{"1.2.0"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"member"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]},
  []}

def cmd.zunion() -> Top:
  Top{Desc{"zunion", R.INeg{2n}, ["read", "sortedset", "slow"], [], KBySintercard{}, False{},
    [R.RBulk{"zunion"}, R.RInt{R.INeg{2n}}, R.RSet{[R.RStatus{"readonly"}, R.RStatus{"movablekeys"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RSet{[R.RStatus{"@read"}, R.RStatus{"@sortedset"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"keynum"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"keynumidx"}, R.RInt{R.IPos{0n}}, R.RBulk{"firstkey"}, R.RInt{R.IPos{1n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Add multiple sorted sets"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(N)+O(M*log(M)) with N being the sum of the sizes of the input sorted sets, and M being the number of elements in the resulting sorted set."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"numkeys"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"weight"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"WEIGHTS"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}, R.RStatus{"multiple"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"aggregate"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"token"}, R.RBulk{"AGGREGATE"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"sum"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"SUM"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"min"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"MIN"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"max"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"MAX"}]}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"withscores"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"WITHSCORES"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.zunionstore() -> Top:
  Top{Desc{"zunionstore", R.INeg{3n}, ["write", "sortedset", "slow"], [], KByZstore{}, False{},
    [R.RBulk{"zunionstore"}, R.RInt{R.INeg{3n}}, R.RSet{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"movablekeys"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RSet{[R.RStatus{"@write"}, R.RStatus{"@sortedset"}, R.RStatus{"@slow"}]}, R.RSet{[]}, R.RSet{[R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"OW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}, R.RMap{[R.RBulk{"flags"}, R.RSet{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"index"}, R.RInt{R.IPos{2n}}]}]}, R.RBulk{"find_keys"}, R.RMap{[R.RBulk{"type"}, R.RBulk{"keynum"}, R.RBulk{"spec"}, R.RMap{[R.RBulk{"keynumidx"}, R.RInt{R.IPos{0n}}, R.RBulk{"firstkey"}, R.RInt{R.IPos{1n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Add multiple sorted sets and store the resulting sorted set in a new key"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"sorted-set"}, R.RBulk{"complexity"}, R.RBulk{"O(N)+O(M log(M)) with N being the sum of the sizes of the input sorted sets, and M being the number of elements in the resulting sorted set."}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"destination"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"numkeys"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{1n}}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"multiple"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"weight"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"WEIGHTS"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}, R.RStatus{"multiple"}]}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"aggregate"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"token"}, R.RBulk{"AGGREGATE"}, R.RBulk{"flags"}, R.RSet{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RMap{[R.RBulk{"name"}, R.RBulk{"sum"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"SUM"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"min"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"MIN"}]}, R.RMap{[R.RBulk{"name"}, R.RBulk{"max"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"MAX"}]}]}]}]}]},
  []}

# the commands, by name
def table() -> List<&2, Top>:
  [cmd.acl(), cmd.append(), cmd.auth(), cmd.bgrewriteaof(), cmd.bgsave(), cmd.bitcount(), cmd.bitfield(), cmd.bitfield_ro(), cmd.bitop(), cmd.bitpos(), cmd.blmove(), cmd.blmpop(), cmd.blpop(), cmd.brpop(), cmd.brpoplpush(), cmd.bzmpop(), cmd.bzpopmax(), cmd.bzpopmin(), cmd.client(), cmd.command(), cmd.config(), cmd.copy(), cmd.dbsize(), cmd.decr(), cmd.decrby(), cmd.del(), cmd.discard(), cmd.dump(), cmd.echo(), cmd.eval(), cmd.eval_ro(), cmd.evalsha(), cmd.evalsha_ro(), cmd.exec(), cmd.exists(), cmd.expire(), cmd.expireat(), cmd.expiretime(), cmd.flushall(), cmd.flushdb(), cmd.function(), cmd.geoadd(), cmd.geodist(), cmd.geohash(), cmd.geopos(), cmd.georadius(), cmd.georadius_ro(), cmd.georadiusbymember(), cmd.georadiusbymember_ro(), cmd.geosearch(), cmd.geosearchstore(), cmd.get(), cmd.getbit(), cmd.getdel(), cmd.getex(), cmd.getrange(), cmd.getset(), cmd.hdel(), cmd.hello(), cmd.hexists(), cmd.hget(), cmd.hgetall(), cmd.hincrby(), cmd.hincrbyfloat(), cmd.hkeys(), cmd.hlen(), cmd.hmget(), cmd.hmset(), cmd.hrandfield(), cmd.hscan(), cmd.hset(), cmd.hsetnx(), cmd.hstrlen(), cmd.hvals(), cmd.incr(), cmd.incrby(), cmd.incrbyfloat(), cmd.info(), cmd.keys(), cmd.lastsave(), cmd.latency(), cmd.lcs(), cmd.lindex(), cmd.linsert(), cmd.llen(), cmd.lmove(), cmd.lmpop(), cmd.lolwut(), cmd.lpop(), cmd.lpos(), cmd.lpush(), cmd.lpushx(), cmd.lrange(), cmd.lrem(), cmd.lset(), cmd.ltrim(), cmd.memory(), cmd.mget(), cmd.monitor(), cmd.move(), cmd.mset(), cmd.msetnx(), cmd.multi(), cmd.object(), cmd.persist(), cmd.pexpire(), cmd.pexpireat(), cmd.pexpiretime(), cmd.pfadd(), cmd.pfcount(), cmd.pfdebug(), cmd.pfmerge(), cmd.pfselftest(), cmd.ping(), cmd.psetex(), cmd.psubscribe(), cmd.pttl(), cmd.publish(), cmd.pubsub(), cmd.punsubscribe(), cmd.quit(), cmd.randomkey(), cmd.rename(), cmd.renamenx(), cmd.reset(), cmd.restore(), cmd.role(), cmd.rpop(), cmd.rpoplpush(), cmd.rpush(), cmd.rpushx(), cmd.sadd(), cmd.save(), cmd.scan(), cmd.scard(), cmd.script(), cmd.sdiff(), cmd.sdiffstore(), cmd.select(), cmd.set(), cmd.setbit(), cmd.setex(), cmd.setnx(), cmd.setrange(), cmd.shutdown(), cmd.sinter(), cmd.sintercard(), cmd.sinterstore(), cmd.sismember(), cmd.slowlog(), cmd.smembers(), cmd.smismember(), cmd.smove(), cmd.sort(), cmd.sort_ro(), cmd.spop(), cmd.spublish(), cmd.srandmember(), cmd.srem(), cmd.sscan(), cmd.ssubscribe(), cmd.strlen(), cmd.subscribe(), cmd.substr(), cmd.sunion(), cmd.sunionstore(), cmd.sunsubscribe(), cmd.swapdb(), cmd.time(), cmd.touch(), cmd.ttl(), cmd.type(), cmd.unlink(), cmd.unsubscribe(), cmd.unwatch(), cmd.wait(), cmd.watch(), cmd.xinfo(), cmd.xlen(), cmd.xpending(), cmd.xrange(), cmd.xread(), cmd.xrevrange(), cmd.zadd(), cmd.zcard(), cmd.zcount(), cmd.zdiff(), cmd.zdiffstore(), cmd.zincrby(), cmd.zinter(), cmd.zintercard(), cmd.zinterstore(), cmd.zlexcount(), cmd.zmpop(), cmd.zmscore(), cmd.zpopmax(), cmd.zpopmin(), cmd.zrandmember(), cmd.zrange(), cmd.zrangebylex(), cmd.zrangebyscore(), cmd.zrangestore(), cmd.zrank(), cmd.zrem(), cmd.zremrangebylex(), cmd.zremrangebyrank(), cmd.zremrangebyscore(), cmd.zrevrange(), cmd.zrevrangebylex(), cmd.zrevrangebyscore(), cmd.zrevrank(), cmd.zscan(), cmd.zscore(), cmd.zunion(), cmd.zunionstore()]

# Redis's ACL categories (ACL CAT)
def categories() -> List<&2, String>:
  ["keyspace", "read", "write", "set", "sortedset", "list", "hash", "string", "bitmap", "hyperloglog", "geo", "stream", "pubsub", "admin", "fast", "slow", "blocking", "dangerous", "connection", "transaction", "scripting"]
# END gen_commands: table

# Lookup
# ------

def desc.name(+d: Desc) -> String:
  match d:
    case Desc{name, arity, cats, specs, way, nokeys, info, docs}:
      name

def top.name(+t: Top) -> String:
  match t:
    case Top{+d, subs}:
      desc.name(d)

def top.find(+n: String, ts: List<&2, Top>) -> Maybe<&2, Top>:
  match ts:
    case Nil{}:
      None{}
    case Con{+t, rest}:
      Bool.pick(Maybe<&2, Top>, String.eq(top.name(t), n), Some{t}, top.find(n, rest))

def sub.find(+n: String, ds: List<&2, Desc>) -> Maybe<&2, Desc>:
  match ds:
    case Nil{}:
      None{}
    case Con{+d, rest}:
      Bool.pick(Maybe<&2, Desc>, String.eq(desc.name(d), n), Some{d}, sub.find(n, rest))

# a command, or a subcommand
type Hit is Data:
  HTop{t: Top}
  HSub{d: Desc}

def hit.of_sub(m: Maybe<&2, Desc>) -> Maybe<&2, Hit>:
  match m:
    case Some{s}:
      Some{HSub{s}}
    case None{}:
      None{}

def hit.of_top(m: Maybe<&2, Top>) -> Maybe<&2, Hit>:
  match m:
    case Some{t}:
      Some{HTop{t}}
    case None{}:
      None{}

def hit.sub(t: Maybe<&2, Top>, +n: String) -> Maybe<&2, Hit>:
  match t:
    case Some{Top{d, subs}}:
      hit.of_sub(sub.find(n, subs))
    case None{}:
      None{}

def hit.parts(ps: List<&2, String>) -> Maybe<&2, Hit>:
  match ps:
    case Con{+a, Nil{}}:
      hit.of_top(top.find(a, table()))
    case Con{+a, Con{+b, Nil{}}}:
      hit.sub(top.find(a, table()), a ++ "|" ++ b)
    case _:
      None{}

# a command by its name, case aside, or a subcommand by its parent's name,
# '|' and its own, as Redis's lookupCommandBySds
def find(+name: String) -> Maybe<&2, Hit>:
  hit.parts(String.split(String.to_lower(name), '|'))

def desc.sub(t: Maybe<&2, Top>, +n: String) -> Maybe<&2, Desc>:
  match t:
    case Some{Top{d, subs}}:
      sub.find(n, subs)
    case None{}:
      None{}

def desc.top(t: Maybe<&2, Top>) -> Maybe<&2, Desc>:
  match t:
    case Some{Top{d, subs}}:
      Some{d}
    case None{}:
      None{}

def top.has_subs(+t: Maybe<&2, Top>) -> Bool:
  match t:
    case Some{Top{d, Con{s, rest}}}:
      True{}
    case _:
      False{}

def desc.argv.of(+t: Maybe<&2, Top>, +a: String, rest: List<&2, String>) -> Maybe<&2, Desc>:
  match rest:
    case Con{+b, more}:
      Bool.pick(Maybe<&2, Desc>, top.has_subs(t), desc.sub(t, a ++ "|" ++ String.to_lower(b)), desc.top(t))
    case Nil{}:
      desc.top(t)

# the command of a command line, as Redis's lookupCommand: by its name,
# then, for a command with subcommands, by its first argument
def desc.argv(argv: List<&2, String>) -> Maybe<&2, Desc>:
  match argv:
    case Con{a, rest}:
      +l = String.to_lower(a)
      desc.argv.of(top.find(l, table()), l, rest)
    case Nil{}:
      None{}

# Descriptions and documentation
# ------------------------------

# a description and its subcommands' (an empty set for none, as Redis
# answers it in RESP3)
def info.subs.of(subs: List<&2, R.Reply>) -> R.Reply:
  match subs:
    case Nil{}:
      R.RSet{Nil{}}
    case Con{x, rest}:
      R.RArray{x <> rest}

def info.desc(d: Desc, subs: List<&2, R.Reply>) -> R.Reply:
  match d:
    case Desc{name, arity, cats, specs, way, nokeys, info, docs}:
      R.RArray{List.append(&2, R.Reply, info, [info.subs.of(subs)])}

def info.subs(ds: List<&2, Desc>) -> List<&2, R.Reply>:
  match ds:
    case Nil{}:
      Nil{}
    case Con{d, rest}:
      info.desc(d, Nil{}) <> info.subs(rest)

def info.top(t: Top) -> R.Reply:
  match t:
    case Top{d, subs}:
      info.desc(d, info.subs(subs))

def info.hit(h: Hit) -> R.Reply:
  match h:
    case HTop{t}:
      info.top(t)
    case HSub{d}:
      info.desc(d, Nil{})

def docs.desc(d: Desc, more: List<&2, R.Reply>) -> R.Reply:
  match d:
    case Desc{name, arity, cats, specs, way, nokeys, info, docs}:
      R.RMap{List.append(&2, R.Reply, docs, more)}

# each subcommand's name and documentation
def docs.subs(ds: List<&2, Desc>) -> List<&2, R.Reply>:
  match ds:
    case Nil{}:
      Nil{}
    case Con{+d, rest}:
      R.RBulk{desc.name(d)} <> (docs.desc(d, Nil{}) <> docs.subs(rest))

def docs.more(ds: List<&2, Desc>) -> List<&2, R.Reply>:
  match ds:
    case Nil{}:
      Nil{}
    case Con{d, rest}:
      [R.RBulk{"subcommands"}, R.RMap{docs.subs(d <> rest)}]

def docs.top(t: Top) -> R.Reply:
  match t:
    case Top{d, subs}:
      docs.desc(d, docs.more(subs))

# a command's name and documentation
def docs.hit(h: Hit) -> List<&2, R.Reply>:
  match h:
    case HTop{+t}:
      [R.RBulk{top.name(t)}, docs.top(t)]
    case HSub{+d}:
      [R.RBulk{desc.name(d)}, docs.desc(d, Nil{})]

def infos.all(ts: List<&2, Top>) -> List<&2, R.Reply>:
  match ts:
    case Nil{}:
      Nil{}
    case Con{t, rest}:
      info.top(t) <> infos.all(rest)

def docs.all(ts: List<&2, Top>) -> List<&2, R.Reply>:
  match ts:
    case Nil{}:
      Nil{}
    case Con{+t, rest}:
      R.RBulk{top.name(t)} <> (docs.top(t) <> docs.all(rest))

def info.maybe(m: Maybe<&2, Hit>) -> R.Reply:
  match m:
    case Some{h}:
      info.hit(h)
    case None{}:
      R.RNull{}

# COMMAND INFO of names: each one's description, or a null for no command
def infos.named(names: List<&2, String>) -> List<&2, R.Reply>:
  match names:
    case Nil{}:
      Nil{}
    case Con{+n, rest}:
      info.maybe(find(n)) <> infos.named(rest)

def docs.maybe(m: Maybe<&2, Hit>, rest: List<&2, R.Reply>) -> List<&2, R.Reply>:
  match m:
    case Some{h}:
      List.append(&2, R.Reply, docs.hit(h), rest)
    case None{}:
      rest

# COMMAND DOCS of names: the commands found, each with its documentation
def docs.named(names: List<&2, String>) -> List<&2, R.Reply>:
  match names:
    case Nil{}:
      Nil{}
    case Con{+n, rest}:
      docs.maybe(find(n), docs.named(rest))

def info.named(names: List<&2, String>) -> R.Reply:
  match names:
    case Nil{}:
      R.RArray{infos.all(table())}
    case Con{n, rest}:
      R.RArray{infos.named(n <> rest)}

def docs.named.of(names: List<&2, String>) -> R.Reply:
  match names:
    case Nil{}:
      R.RMap{docs.all(table())}
    case Con{n, rest}:
      R.RMap{docs.named(n <> rest)}

# Names
# -----

# which names COMMAND LIST keeps: all, none (no modules), those of an ACL
# category, those matching a pattern (case aside)
type Filt is Data:
  FAll{}
  FNone{}
  FCat{c: String}
  FPat{p: String}

def has(+x: String, xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Con{+y, rest}:
      Bool.or(String.eq(x, y), has(x, rest))

def filt.ok(+f: Filt, +d: Desc) -> Bool:
  match f d:
    case FAll{} _:
      True{}
    case FNone{} _:
      False{}
    case FCat{+c} Desc{name, arity, cats, specs, way, nokeys, info, docs}:
      has(c, cats)
    case FPat{+p} Desc{+name, arity, cats, specs, way, nokeys, info, docs}:
      R.stringmatch(p, name, True{})

def names.keep.if(ok: Bool, +d: Desc, rest: List<&2, R.Reply>) -> List<&2, R.Reply>:
  match ok:
    case True{}:
      R.RBulk{desc.name(d)} <> rest
    case False{}:
      rest

def names.keep(+f: Filt, +d: Desc, rest: List<&2, R.Reply>) -> List<&2, R.Reply>:
  names.keep.if(filt.ok(f, d), d, rest)

def names.subs(+f: Filt, ds: List<&2, Desc>, rest: List<&2, R.Reply>) -> List<&2, R.Reply>:
  match ds:
    case Nil{}:
      rest
    case Con{+d, more}:
      names.keep(f, d, names.subs(f, more, rest))

# each command's name, then those of its subcommands, as the filter keeps them
def names.of(+f: Filt, ts: List<&2, Top>) -> List<&2, R.Reply>:
  match ts:
    case Nil{}:
      Nil{}
    case Con{Top{+d, subs}, rest}:
      names.keep(f, d, names.subs(f, subs, names.of(f, rest)))

def filt.cat(+c: String) -> Filt:
  Bool.pick(Filt, has(c, categories()), FCat{c}, FNone{})

def filt.by(+t: String, +v: String) -> Maybe<&2, Filt>:
  Bool.pick(Maybe<&2, Filt>, String.eq(t, "MODULE"), Some{FNone{}},
  Bool.pick(Maybe<&2, Filt>, String.eq(t, "ACLCAT"), Some{filt.cat(String.to_lower(v))},
  Bool.pick(Maybe<&2, Filt>, String.eq(t, "PATTERN"), Some{FPat{v}}, None{})))

def list.of(m: Maybe<&2, Filt>) -> R.Reply:
  match m:
    case Some{+f}:
      R.RArray{names.of(f, table())}
    case None{}:
      R.RError{"ERR syntax error"}

# COMMAND LIST [FILTERBY MODULE m | ACLCAT c | PATTERN p]
def list(args: List<&2, String>) -> R.Reply:
  match args:
    case Nil{}:
      list.of(Some{FAll{}})
    case Con{+by, Con{+t, Con{+v, Nil{}}}}:
      list.of(Bool.pick(Maybe<&2, Filt>, String.eq(String.to_upper(by), "FILTERBY"), filt.by(String.to_upper(t), v), None{}))
    case _:
      list.of(None{})

# Keys
# ----

# a key found: its index in the command line, and its flags
type KeyAt is Data:
  KeyAt{at: Nat, flags: List<&2, String>}

# the keys from index i to last, step by step
def keys.range(n: Nat, +i: Nat, +last: Nat, +step: Nat, +flags: List<&2, String>) -> List<&2, KeyAt>:
  match n:
    case 0n:
      Nil{}
    case 1n+m:
      Bool.pick(List<&2, KeyAt>, Nat.is_le(i, last), KeyAt{i, flags} <> keys.range(m, Nat.add(i, step), last, step, flags), Nil{})

# the last key's index k+1 before the end of argc arguments, or, with a
# limit, k+1 before the end of the limit's share of what follows the
# first (first is below argc); none when it falls before the first
def keys.last.neg(nolimit: Bool, +first: Nat, +k: Nat, +limit: Nat, +argc: Nat) -> Maybe<&2, Nat>:
  match nolimit:
    case True{}:
      Bool.pick(Maybe<&2, Nat>, Nat.is_le(Nat.add(first, 1n+k), argc), Some{Nat.sub(argc, 1n+k)}, None{})
    case False{}:
      +q = Nat.div(Nat.sub(argc, first), limit)
      Bool.pick(Maybe<&2, Nat>, Nat.is_le(1n+k, q), Some{Nat.sub(Nat.add(first, q), 1n+k)}, None{})

# the last key's index, for the first at first: k after it, or counted
# from the end
def keys.last(+first: Nat, last: R.Int, +limit: Nat, +argc: Nat) -> Maybe<&2, Nat>:
  match last:
    case R.IPos{+k}:
      Some{Nat.add(first, k)}
    case R.INeg{+k}:
      keys.last.neg(Nat.is_eq(limit, 0n), first, k, limit, argc)

def keys.span(m: Maybe<&2, Nat>, +first: Nat, +step: Nat, +argc: Nat, +flags: List<&2, String>) -> Maybe<&2, List<&2, KeyAt>>:
  match m:
    case Some{+last}:
      Bool.pick(Maybe<&2, List<&2, KeyAt>>, Bool.and(Nat.is_lt(last, argc), Nat.is_le(first, last)), Some{keys.range(1n+argc, first, last, Nat.max(step, 1n), flags)}, None{})
    case None{}:
      None{}

# the index after the first word of argv that is kw (strcasecmp's), from
# index i on, up to the last but one (Redis's keyword search from a
# positive startfrom); none when none is
def keys.kw.at(fuel: Nat, hit: Bool, xs: List<&2, String>, +kw: String, +i: Nat) -> Maybe<&2, Nat>:
  match fuel hit xs:
    case _ True{} _:
      Some{Nat.add(i, 1n)}
    case 1n+f False{} Con{+x, Con{y, rest}}:
      keys.kw.at(f, String.eq(String.to_upper(R.cstr(x)), kw), Con{y, rest}, kw, Nat.add(i, 1n))
    case _ _ _:
      None{}

def keys.kw.of(xs: List<&2, String>, +kw: String, +from: Nat, +n: Nat) -> Maybe<&2, Nat>:
  match xs:
    case Con{+x, Con{y, rest}}:
      keys.kw.at(n, String.eq(String.to_upper(R.cstr(x)), kw), Con{y, rest}, kw, from)
    case _:
      None{}

def keys.kw(+argv: List<&2, String>, +kw: String, +from: Nat) -> Maybe<&2, Nat>:
  keys.kw.of(List.drop(&2, String, argv, from), kw, from, List.length(&2, String, argv))

def keys.kw.span(m: Maybe<&2, Nat>, last: R.Int, +step: Nat, +limit: Nat, +argc: Nat, +flags: List<&2, String>) -> Maybe<&2, List<&2, KeyAt>>:
  match m:
    case Some{+first}:
      keys.span(keys.last(first, last, limit, argc), first, step, argc, flags)
    case None{}:
      Some{Nil{}}

# a spec's keys in a command line argv (Redis's getKeysUsingKeySpecs):
# none for a spec of no keys (not_key) or whose keyword is not there, and
# no answer at all for a range out of the line or an incomplete spec
def keys.spec(sp: KSpec, +argv: List<&2, String>) -> Maybe<&2, List<&2, KeyAt>>:
  match sp:
    case KSpec{+flags, +pos, last, +step, +limit}:
      +argc = List.length(&2, String, argv)
      Bool.pick(Maybe<&2, List<&2, KeyAt>>, has("not_key", flags), Some{Nil{}},
        Bool.pick(Maybe<&2, List<&2, KeyAt>>, Bool.or(Nat.is_le(argc, pos), has("incomplete", flags)), None{},
          keys.span(keys.last(pos, last, limit, argc), pos, step, argc, flags)))
    case KSpecKw{+flags, +kw, +from, last, +step, +limit}:
      +argc = List.length(&2, String, argv)
      Bool.pick(Maybe<&2, List<&2, KeyAt>>, has("not_key", flags), Some{Nil{}},
        Bool.pick(Maybe<&2, List<&2, KeyAt>>, has("incomplete", flags), None{},
          keys.kw.span(keys.kw(argv, kw, from), last, step, limit, argc, flags)))

def keys.more(m: Maybe<&2, List<&2, KeyAt>>, rest: Maybe<&2, List<&2, KeyAt>>) -> Maybe<&2, List<&2, KeyAt>>:
  match m rest:
    case Some{ks} Some{more}:
      Some{List.append(&2, KeyAt, ks, more)}
    case _ _:
      None{}

def keys.specs(sps: List<&2, KSpec>, +argv: List<&2, String>) -> Maybe<&2, List<&2, KeyAt>>:
  match sps:
    case Nil{}:
      Some{Nil{}}
    case Con{sp, rest}:
      keys.more(keys.spec(sp, argv), keys.specs(rest, argv))

# SET's key: read and written when it has GET (after its key and value),
# else only overwritten (Redis's setGetKeys)
def set.get(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Con{+x, rest}:
      Bool.or(String.eq(String.to_upper(x), "GET"), set.get(rest))

def set.keys(argv: List<&2, String>) -> List<&2, KeyAt>:
  match argv:
    case Con{c, Con{k, Con{v, rest}}}:
      [KeyAt{1n, Bool.pick(List<&2, String>, set.get(rest), ["RW", "access", "update"], ["OW", "update"])}]
    case _:
      [KeyAt{1n, ["OW", "update"]}]

# BITFIELD's key: read alone when its words are GETs and OVERFLOWs with
# the words they take (Redis's bitfieldGetKeys, which stops at the first
# other word, as a write: a SET, an INCRBY, or a syntax error); skip is
# the words left to pass over, none once a write is met
def bitfield.ro.skip(+u: String, +rest: List<&2, String>) -> Maybe<&2, Nat>:
  Bool.pick(Maybe<&2, Nat>, Bool.and(String.eq(u, "GET"), R.bf.has(2n, rest)), Some{2n},
    Bool.pick(Maybe<&2, Nat>, Bool.and(String.eq(u, "OVERFLOW"), R.bf.has(1n, rest)), Some{1n}, None{}))

def bitfield.ro.step(+k: Nat, +x: String, +rest: List<&2, String>) -> Maybe<&2, Nat>:
  match k:
    case 0n:
      bitfield.ro.skip(String.to_upper(R.cstr(x)), rest)
    case 1n+j:
      Some{j}

def bitfield.ro(xs: List<&2, String>, skip: Maybe<&2, Nat>) -> Bool:
  match xs skip:
    case _ None{}:
      False{}
    case Nil{} Some{k}:
      True{}
    case Con{+x, +rest} Some{+k}:
      bitfield.ro(rest, bitfield.ro.step(k, x, rest))

def bitfield.keys(argv: List<&2, String>) -> List<&2, KeyAt>:
  match argv:
    case Con{c, Con{k, rest}}:
      [KeyAt{1n, Bool.pick(List<&2, String>, bitfield.ro(rest, Some{0n}), ["RO", "access"], ["RW", "access", "update"])}]
    case _:
      [KeyAt{1n, ["RW", "access", "update"]}]

# EVAL's keys: numkeys (its third word) of them after it, read as its key
# spec reads them (numkeys a long long of at least 1, with that many words
# after it), flagged RW, access and update; else as Redis's evalGetKeys
# reads them: numkeys as C's atoi reads it, from 1 to the words after it,
# with no flags (an atoi of ten digits or more, which C cuts to an int,
# reads as none here)
# what the first char of s is to atoi's digits: a digit's value, or none
def atoi.ch(s: String) -> Maybe<&2, Nat>:
  match s:
    case SCon{Chr{+x}, t}:
      Bool.pick(Maybe<&2, Nat>, U32.is_lt(U32.sub(x, 48), 10), Some{U32.to_nat(U32.sub(x, 48))}, None{})
    case SNil{}:
      None{}

# the digits of s read after acc, k more at most (0 for more than that);
# c is what s's first char is
def atoi.digits(s: String, k: Nat, +acc: Nat, c: Maybe<&2, Nat>) -> Nat:
  match s k c:
    case SCon{h, +t} 1n+j Some{+d}:
      atoi.digits(t, j, Nat.add(Nat.mul(acc, 10n), d), atoi.ch(t))
    case SCon{h, t} 0n Some{d}:
      0n
    case _ _ None{}:
      acc
    case SNil{} _ _:
      acc

def atoi.from(+s: String) -> Nat:
  atoi.digits(s, 9n, 0n, atoi.ch(s))

# what atoi makes of the first char of s: a space it skips (0), a plus
# (1), a minus (2), anything else (3)
def atoi.kind(s: String) -> Nat:
  match s:
    case SCon{Chr{+x}, t}:
      Bool.pick(Nat, Bool.or(U32.is_eq(x, 32), Bool.and(U32.is_lt(8, x), U32.is_lt(x, 14))), 0n,
        Bool.pick(Nat, U32.is_eq(x, 43), 1n, Bool.pick(Nat, U32.is_eq(x, 45), 2n, 3n)))
    case SNil{}:
      3n

# a positive int as atoi reads it from s, else 0; kind is atoi.kind(s)
def atoi.pos(s: String, kind: Nat) -> Nat:
  match s kind:
    case SCon{h, +t} 0n:
      atoi.pos(t, atoi.kind(t))
    case SCon{h, +t} 1n:
      atoi.from(t)
    case SCon{h, t} 2n:
      0n
    case r _:
      atoi.from(r)

# the n keys from argv's first-th on, when there are n > 0 and as many
# words left
def eval.keys.in(ok: Bool, +n: Nat, +first: Nat, +flags: List<&2, String>) -> Maybe<&2, List<&2, KeyAt>>:
  match ok:
    case True{}:
      Some{keys.range(n, first, Nat.sub(Nat.add(first, n), 1n), 1n, flags)}
    case False{}:
      None{}

def eval.keys.at(+n: Nat, +first: Nat, +left: Nat, +flags: List<&2, String>) -> Maybe<&2, List<&2, KeyAt>>:
  eval.keys.in(Bool.and(Nat.is_lt(0n, n), Nat.is_le(n, left)), n, first, flags)

def eval.keys.fn(m: Maybe<&2, List<&2, KeyAt>>) -> List<&2, KeyAt>:
  match m:
    case Some{ks}:
      ks
    case None{}:
      Nil{}

def eval.keys.or(m: Maybe<&2, List<&2, KeyAt>>, +nk: String, +first: Nat, +left: Nat) -> List<&2, KeyAt>:
  match m:
    case Some{ks}:
      ks
    case None{}:
      eval.keys.fn(eval.keys.at(atoi.pos(nk, atoi.kind(nk)), first, left, Nil{}))

def eval.keys.spec(l: R.LL, +first: Nat, +left: Nat, +flags: List<&2, String>) -> Maybe<&2, List<&2, KeyAt>>:
  match l:
    case R.LL{neg, +hi, +lo}:
      Bool.pick(Maybe<&2, List<&2, KeyAt>>, Bool.or(neg, Nat.is_lt(0n, hi)), None{}, eval.keys.at(lo, first, left, flags))
    case R.LLBad{}:
      None{}

# the keys of a command whose numkeys is nk, the words after it rest, its
# keys from argv's first-th on, with the flags of its spec
def numkeys(+nk: String, rest: List<&2, String>, +first: Nat, +flags: List<&2, String>) -> List<&2, KeyAt>:
  +left = List.length(&2, String, rest)
  eval.keys.or(eval.keys.spec(R.ll.read(nk), first, left, flags), nk, first, left)

def eval.keys(argv: List<&2, String>) -> List<&2, KeyAt>:
  match argv:
    case Con{e, Con{s, Con{+nk, rest}}}:
      numkeys(nk, rest, 3n, ["RW", "access", "update"])
    case _:
      Nil{}

def lmpop.keys(argv: List<&2, String>) -> List<&2, KeyAt>:
  match argv:
    case Con{e, Con{+nk, rest}}:
      numkeys(nk, rest, 2n, ["RW", "access", "delete"])
    case _:
      Nil{}

def blmpop.keys(argv: List<&2, String>) -> List<&2, KeyAt>:
  match argv:
    case Con{e, Con{t, Con{+nk, rest}}}:
      numkeys(nk, rest, 3n, ["RW", "access", "delete"])
    case _:
      Nil{}

def sintercard.keys(argv: List<&2, String>) -> List<&2, KeyAt>:
  match argv:
    case Con{e, Con{+nk, rest}}:
      numkeys(nk, rest, 2n, ["RO", "access"])
    case _:
      Nil{}

# ZUNIONSTORE dst numkeys key ...: dst (OW, update) and the keys (RO,
# access) by the specs; when numkeys does not read for them, the keys and
# then dst, with no flags, by Redis's function (as atoi reads numkeys)
def zstore.fb(m: Maybe<&2, List<&2, KeyAt>>) -> List<&2, KeyAt>:
  match m:
    case Some{ks}:
      List.append(&2, KeyAt, ks, [KeyAt{1n, Nil{}}])
    case None{}:
      Nil{}

def zstore.keys.or(m: Maybe<&2, List<&2, KeyAt>>, +nk: String, +left: Nat) -> List<&2, KeyAt>:
  match m:
    case Some{ks}:
      KeyAt{1n, ["OW", "update"]} <> ks
    case None{}:
      zstore.fb(eval.keys.at(atoi.pos(nk, atoi.kind(nk)), 3n, left, Nil{}))

def zstore.keys(argv: List<&2, String>) -> List<&2, KeyAt>:
  match argv:
    case Con{e, Con{d, Con{+nk, rest}}}:
      +left = List.length(&2, String, rest)
      zstore.keys.or(eval.keys.spec(R.ll.read(nk), 3n, left, ["RO", "access"]), nk, left)
    case _:
      Nil{}

# SORT's keys, as Redis's sortGetKeys finds them: the key (RO, access),
# and the destination of the last STORE that has a word after it (OW,
# update), passing over the words LIMIT, GET and BY take (and none after
# STORE). A word of SORT's options to it: 2 LIMIT, 1 GET or BY, 3 STORE, 0
# another
def sort.kind(+w: String) -> Nat:
  +up = String.to_upper(R.cstr(w))
  Bool.pick(Nat, String.eq(up, "LIMIT"), 2n, Bool.pick(Nat, Bool.or(String.eq(up, "GET"), String.eq(up, "BY")), 1n, Bool.pick(Nat, String.eq(up, "STORE"), 3n, 0n)))

# the words xs from index i on, k of them passed over first; st: the
# index of STORE's destination so far
def sort.dst(xs: List<&2, String>, +k: Nat, +i: Nat, st: Maybe<&2, Nat>) -> Maybe<&2, Nat>:
  match xs k:
    case Nil{} _:
      st
    case Con{x, rest} 1n+j:
      sort.dst(rest, j, Nat.add(i, 1n), st)
    case Con{+x, +rest} 0n:
      +c = sort.kind(x)
      sort.dst(rest, Bool.pick(Nat, Nat.is_eq(c, 3n), 0n, c), Nat.add(i, 1n), Bool.pick(Maybe<&2, Nat>, Bool.and(Nat.is_eq(c, 3n), Bool.not(List.is_empty(&2, String, rest))), Some{Nat.add(i, 1n)}, st))

def sort.dst.at(m: Maybe<&2, Nat>) -> List<&2, KeyAt>:
  match m:
    case Some{i}:
      [KeyAt{i, ["OW", "update"]}]
    case None{}:
      Nil{}

def sort.keys(argv: List<&2, String>) -> List<&2, KeyAt>:
  match argv:
    case Con{c, Con{k, rest}}:
      KeyAt{1n, ["RO", "access"]} <> sort.dst.at(sort.dst(rest, 0n, 2n, None{}))
    case _:
      Nil{}

def keys.find(way: KWay, sps: List<&2, KSpec>, +argv: List<&2, String>) -> Maybe<&2, List<&2, KeyAt>>:
  match way:
    case KBySpecs{}:
      keys.specs(sps, argv)
    case KBySet{}:
      Some{set.keys(argv)}
    case KByBitfield{}:
      Some{bitfield.keys(argv)}
    case KByEval{}:
      Some{eval.keys(argv)}
    case KByLmpop{}:
      Some{lmpop.keys(argv)}
    case KBySintercard{}:
      Some{sintercard.keys(argv)}
    case KByZstore{}:
      Some{zstore.keys(argv)}
    case KByBlmpop{}:
      Some{blmpop.keys(argv)}
    case KBySort{}:
      Some{sort.keys(argv)}
    case KBySortRo{}:
      Some{[KeyAt{1n, ["RO", "access"]}]}

def keys.has.specs(sps: List<&2, KSpec>) -> Bool:
  match sps:
    case Nil{}:
      False{}
    case Con{KSpec{+flags, pos, last, step, limit}, rest}:
      Bool.or(Bool.not(has("not_key", flags)), keys.has.specs(rest))
    case Con{KSpecKw{+flags, kw, from, last, step, limit}, rest}:
      Bool.or(Bool.not(has("not_key", flags)), keys.has.specs(rest))

# whether a command has keys: a spec of keys, or a function of its own
def keys.has(+way: KWay, sps: List<&2, KSpec>) -> Bool:
  match way:
    case KBySet{}:
      True{}
    case KByBitfield{}:
      True{}
    case KByEval{}:
      True{}
    case KByLmpop{}:
      True{}
    case KBySintercard{}:
      True{}
    case KByZstore{}:
      True{}
    case KByBlmpop{}:
      True{}
    case KBySort{}:
      True{}
    case KBySortRo{}:
      True{}
    case KBySpecs{}:
      keys.has.specs(sps)

def nth(n: Nat, xs: List<&2, String>) -> String:
  match n xs:
    case 0n Con{x, rest}:
      x
    case 1n+m Con{x, rest}:
      nth(m, rest)
    case _ Nil{}:
      ""

def keys.out(+flags: Bool, ks: List<&2, KeyAt>, +argv: List<&2, String>) -> List<&2, R.Reply>:
  match ks:
    case Nil{}:
      Nil{}
    case Con{KeyAt{+at, fl}, rest}:
      Bool.pick(R.Reply, flags, R.RArray{[R.RBulk{nth(at, argv)}, R.RSet{R.statuses(fl)}]}, R.RBulk{nth(at, argv)}) <> keys.out(flags, rest, argv)

def keys.found(+flags: Bool, m: Maybe<&2, List<&2, KeyAt>>, nokeys: Bool, +argv: List<&2, String>) -> R.Reply:
  match m:
    case Some{Con{k, rest}}:
      R.RArray{keys.out(flags, k <> rest, argv)}
    case _:
      Bool.pick(R.Reply, nokeys, R.RArray{Nil{}}, R.RError{"ERR Invalid arguments specified for command"})

# whether argc arguments fit an arity (exactly n, or at least n for -n)
def arity.ok(a: R.Int, +argc: Nat) -> Bool:
  match a:
    case R.IPos{n}:
      Nat.is_eq(n, argc)
    case R.INeg{n}:
      Nat.is_le(1n+n, argc)

def keys.of(+flags: Bool, d: Desc, +argv: List<&2, String>) -> R.Reply:
  match d:
    case Desc{name, arity, cats, +specs, +way, nokeys, info, docs}:
      Bool.pick(R.Reply, Bool.not(keys.has(way, specs)), R.RError{"ERR The command has no key arguments"},
        Bool.pick(R.Reply, Bool.not(arity.ok(arity, List.length(&2, String, argv))), R.RError{"ERR Invalid number of arguments specified for command"},
          keys.found(flags, keys.find(way, specs, argv), nokeys, argv)))

def keys.desc(m: Maybe<&2, Desc>, +flags: Bool, +argv: List<&2, String>) -> R.Reply:
  match m:
    case Some{d}:
      keys.of(flags, d, argv)
    case None{}:
      R.RError{"ERR Invalid command specified"}

# COMMAND GETKEYS and GETKEYSANDFLAGS of a command line
def keys(+flags: Bool, +argv: List<&2, String>) -> R.Reply:
  keys.desc(desc.argv(argv), flags, argv)

# BEGIN gen_commands: by key
# the arity and key specs of the command or subcommand of a key that
# only reads (readonly); none for any other
def ro.key(+key: Nat) -> Maybe<&2, Ro>:
  match key:
    case 3n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 9n:
      Some{Ro{R.INeg{1n}, [KSpec{["RO"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}}}
    case 15n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 16n:
      Some{Ro{R.INeg{1n}, [KSpec{["RO", "access"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}}}
    case 18n:
      Some{Ro{R.IPos{1n}, [], KBySpecs{}}}
    case 21n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 22n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 25n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 32n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 33n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 34n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 35n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 37n:
      Some{Ro{R.IPos{4n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 38n:
      Some{Ro{R.IPos{4n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 40n:
      Some{Ro{R.IPos{3n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 42n:
      Some{Ro{R.INeg{1n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 43n:
      Some{Ro{R.INeg{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 44n:
      Some{Ro{R.INeg{1n}, [KSpec{["RO"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}}}
    case 50n:
      Some{Ro{R.INeg{1n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 53n:
      Some{Ro{R.IPos{3n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 54n:
      Some{Ro{R.INeg{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 57n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 58n:
      Some{Ro{R.IPos{3n}, [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 59n:
      Some{Ro{R.IPos{3n}, [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 60n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 61n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 62n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 64n:
      Some{Ro{R.INeg{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 72n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 73n:
      Some{Ro{R.IPos{3n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 74n:
      Some{Ro{R.IPos{4n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 79n:
      Some{Ro{R.INeg{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 85n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 86n:
      Some{Ro{R.IPos{3n}, [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 87n:
      Some{Ro{R.INeg{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 88n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 89n:
      Some{Ro{R.INeg{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 91n:
      Some{Ro{R.INeg{1n}, [KSpec{["RO", "access"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}}}
    case 92n:
      Some{Ro{R.INeg{2n}, [], KBySintercard{}}}
    case 94n:
      Some{Ro{R.INeg{1n}, [KSpec{["RO", "access"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}}}
    case 96n:
      Some{Ro{R.INeg{1n}, [KSpec{["RO", "access"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}}}
    case 110n:
      Some{Ro{R.IPos{1n}, [], KBySpecs{}}}
    case 116n:
      Some{Ro{R.INeg{2n}, [KSpec{["RO", "access"], 1n, R.IPos{1n}, 1n, 0n}], KBySpecs{}}}
    case 117n:
      Some{Ro{R.INeg{1n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 120n:
      Some{Ro{R.INeg{1n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 124n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 125n:
      Some{Ro{R.IPos{3n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 126n:
      Some{Ro{R.INeg{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 127n:
      Some{Ro{R.IPos{3n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 128n:
      Some{Ro{R.IPos{3n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 129n:
      Some{Ro{R.IPos{4n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 130n:
      Some{Ro{R.IPos{4n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 131n:
      Some{Ro{R.INeg{3n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 132n:
      Some{Ro{R.INeg{3n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 133n:
      Some{Ro{R.INeg{3n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 134n:
      Some{Ro{R.INeg{3n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 135n:
      Some{Ro{R.INeg{3n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 136n:
      Some{Ro{R.INeg{3n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 142n:
      Some{Ro{R.INeg{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 143n:
      Some{Ro{R.INeg{2n}, [], KBySintercard{}}}
    case 144n:
      Some{Ro{R.INeg{2n}, [], KBySintercard{}}}
    case 145n:
      Some{Ro{R.INeg{2n}, [], KBySintercard{}}}
    case 146n:
      Some{Ro{R.INeg{2n}, [], KBySintercard{}}}
    case 152n:
      Some{Ro{R.INeg{1n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 178n:
      Some{Ro{R.INeg{1n}, [], KBySortRo{}}}
    case 180n:
      Some{Ro{R.INeg{1n}, [KSpec{["RW", "access"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}}}
    case 188n:
      Some{Ro{R.INeg{0n}, [], KBySpecs{}}}
    case 190n:
      Some{Ro{R.INeg{3n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 191n:
      Some{Ro{R.INeg{1n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 192n:
      Some{Ro{R.INeg{1n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 194n:
      Some{Ro{R.INeg{5n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 196n:
      Some{Ro{R.INeg{4n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 197n:
      Some{Ro{R.INeg{6n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 199n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 205n:
      Some{Ro{R.INeg{2n}, [], KByEval{}}}
    case 206n:
      Some{Ro{R.INeg{2n}, [], KByEval{}}}
    case 209n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 210n:
      Some{Ro{R.INeg{3n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 211n:
      Some{Ro{R.INeg{3n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 212n:
      Some{Ro{R.INeg{3n}, [KSpecKw{["RO", "access"], "STREAMS", 1n, R.INeg{0n}, 1n, 2n}], KBySpecs{}}}
    case 214n:
      Some{Ro{R.INeg{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 247n:
      Some{Ro{R.IPos{3n}, [KSpec{["RO"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 248n:
      Some{Ro{R.IPos{3n}, [KSpec{["RO"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 249n:
      Some{Ro{R.IPos{3n}, [KSpec{["RO"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 250n:
      Some{Ro{R.IPos{3n}, [KSpec{["RO"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 252n:
      Some{Ro{R.INeg{2n}, [KSpec{["RO"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 293n:
      Some{Ro{R.INeg{2n}, [KSpec{["RO", "access"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 294n:
      Some{Ro{R.IPos{3n}, [KSpec{["RO", "access"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 295n:
      Some{Ro{R.IPos{4n}, [KSpec{["RO", "access"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case _:
      None{}

# the same of the command or subcommand of any key, for ACL's check of
# a call (acl.bend); none for key 0
def spec.key(+key: Nat) -> Maybe<&2, Ro>:
  match key:
    case 1n:
      Some{Ro{R.INeg{0n}, [], KBySpecs{}}}
    case 2n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 3n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 4n:
      Some{Ro{R.INeg{2n}, [KSpec{["RW", "access", "update", "variable_flags"], 1n, R.IPos{0n}, 1n, 0n}], KBySet{}}}
    case 5n:
      Some{Ro{R.IPos{3n}, [KSpec{["OW", "insert"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 6n:
      Some{Ro{R.IPos{3n}, [KSpec{["RW", "access", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 7n:
      Some{Ro{R.INeg{1n}, [KSpec{["RM", "delete"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}}}
    case 8n:
      Some{Ro{R.INeg{1n}, [KSpec{["RM", "delete"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}}}
    case 9n:
      Some{Ro{R.INeg{1n}, [KSpec{["RO"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}}}
    case 10n:
      Some{Ro{R.IPos{2n}, [KSpec{["RW", "access", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 11n:
      Some{Ro{R.IPos{2n}, [KSpec{["RW", "access", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 12n:
      Some{Ro{R.IPos{3n}, [KSpec{["RW", "access", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 13n:
      Some{Ro{R.IPos{3n}, [KSpec{["RW", "access", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 14n:
      Some{Ro{R.IPos{3n}, [KSpec{["RW", "insert"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 15n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 16n:
      Some{Ro{R.INeg{1n}, [KSpec{["RO", "access"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}}}
    case 17n:
      Some{Ro{R.INeg{2n}, [KSpec{["OW", "update"], 1n, R.INeg{0n}, 2n, 0n}], KBySpecs{}}}
    case 18n:
      Some{Ro{R.IPos{1n}, [], KBySpecs{}}}
    case 19n:
      Some{Ro{R.INeg{0n}, [], KBySpecs{}}}
    case 20n:
      Some{Ro{R.INeg{0n}, [], KBySpecs{}}}
    case 21n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 22n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 23n:
      Some{Ro{R.IPos{4n}, [KSpec{["OW", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 24n:
      Some{Ro{R.IPos{4n}, [KSpec{["OW", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 25n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 26n:
      Some{Ro{R.INeg{1n}, [KSpec{["RW", "access", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 27n:
      Some{Ro{R.IPos{2n}, [KSpec{["RW", "access", "delete"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 28n:
      Some{Ro{R.INeg{2n}, [KSpec{["RW", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 29n:
      Some{Ro{R.INeg{2n}, [KSpec{["RW", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 30n:
      Some{Ro{R.INeg{2n}, [KSpec{["RW", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 31n:
      Some{Ro{R.INeg{2n}, [KSpec{["RW", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 32n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 33n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 34n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 35n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 36n:
      Some{Ro{R.IPos{2n}, [KSpec{["RW", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 37n:
      Some{Ro{R.IPos{4n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 38n:
      Some{Ro{R.IPos{4n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 39n:
      Some{Ro{R.IPos{4n}, [KSpec{["RW", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 40n:
      Some{Ro{R.IPos{3n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 41n:
      Some{Ro{R.IPos{4n}, [KSpec{["RW", "access", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 42n:
      Some{Ro{R.INeg{1n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 43n:
      Some{Ro{R.INeg{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 44n:
      Some{Ro{R.INeg{1n}, [KSpec{["RO"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}}}
    case 45n:
      Some{Ro{R.INeg{2n}, [KSpec{["OW", "insert"], 1n, R.INeg{0n}, 2n, 0n}], KBySpecs{}}}
    case 46n:
      Some{Ro{R.IPos{3n}, [KSpec{["RW", "access", "delete"], 1n, R.IPos{0n}, 1n, 0n}, KSpec{["OW", "update"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 47n:
      Some{Ro{R.IPos{3n}, [KSpec{["RW", "access", "delete"], 1n, R.IPos{0n}, 1n, 0n}, KSpec{["OW", "insert"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 48n:
      Some{Ro{R.INeg{3n}, [KSpec{["OW", "update"], 2n, R.IPos{0n}, 1n, 0n}, KSpec{["RO", "access"], 3n, R.INeg{0n}, 1n, 0n}], KBySpecs{}}}
    case 49n:
      Some{Ro{R.INeg{1n}, [KSpec{["RW", "access", "update", "variable_flags"], 1n, R.IPos{0n}, 1n, 0n}], KByBitfield{}}}
    case 50n:
      Some{Ro{R.INeg{1n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 51n:
      Some{Ro{R.INeg{3n}, [KSpec{["RW", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 52n:
      Some{Ro{R.IPos{4n}, [KSpec{["RW", "insert"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 53n:
      Some{Ro{R.IPos{3n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 54n:
      Some{Ro{R.INeg{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 55n:
      Some{Ro{R.INeg{3n}, [KSpec{["RW", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 56n:
      Some{Ro{R.INeg{2n}, [KSpec{["RW", "delete"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 57n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 58n:
      Some{Ro{R.IPos{3n}, [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 59n:
      Some{Ro{R.IPos{3n}, [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 60n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 61n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 62n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 63n:
      Some{Ro{R.IPos{4n}, [KSpec{["RW", "access", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 64n:
      Some{Ro{R.INeg{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 65n:
      Some{Ro{R.INeg{2n}, [], KByEval{}}}
    case 66n:
      Some{Ro{R.INeg{2n}, [KSpec{["RW", "insert"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 67n:
      Some{Ro{R.INeg{2n}, [KSpec{["RW", "insert"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 68n:
      Some{Ro{R.INeg{2n}, [KSpec{["RW", "insert"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 69n:
      Some{Ro{R.INeg{2n}, [KSpec{["RW", "insert"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 70n:
      Some{Ro{R.INeg{1n}, [KSpec{["RW", "access", "delete"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 71n:
      Some{Ro{R.INeg{1n}, [KSpec{["RW", "access", "delete"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 72n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 73n:
      Some{Ro{R.IPos{3n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 74n:
      Some{Ro{R.IPos{4n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 75n:
      Some{Ro{R.IPos{4n}, [KSpec{["RW", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 76n:
      Some{Ro{R.IPos{5n}, [KSpec{["RW", "insert"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 77n:
      Some{Ro{R.IPos{4n}, [KSpec{["RW", "delete"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 78n:
      Some{Ro{R.IPos{4n}, [KSpec{["RW", "delete"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 79n:
      Some{Ro{R.INeg{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 80n:
      Some{Ro{R.IPos{5n}, [KSpec{["RW", "access", "delete"], 1n, R.IPos{0n}, 1n, 0n}, KSpec{["RW", "insert"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 81n:
      Some{Ro{R.IPos{3n}, [KSpec{["RW", "access", "delete"], 1n, R.IPos{0n}, 1n, 0n}, KSpec{["RW", "insert"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 82n:
      Some{Ro{R.INeg{3n}, [], KByLmpop{}}}
    case 83n:
      Some{Ro{R.INeg{2n}, [KSpec{["RW", "insert"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 84n:
      Some{Ro{R.INeg{2n}, [KSpec{["RW", "delete"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 85n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 86n:
      Some{Ro{R.IPos{3n}, [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 87n:
      Some{Ro{R.INeg{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 88n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 89n:
      Some{Ro{R.INeg{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 90n:
      Some{Ro{R.IPos{4n}, [KSpec{["RW", "access", "delete"], 1n, R.IPos{0n}, 1n, 0n}, KSpec{["RW", "insert"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 91n:
      Some{Ro{R.INeg{1n}, [KSpec{["RO", "access"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}}}
    case 92n:
      Some{Ro{R.INeg{2n}, [], KBySintercard{}}}
    case 93n:
      Some{Ro{R.INeg{2n}, [KSpec{["RW", "update"], 1n, R.IPos{0n}, 1n, 0n}, KSpec{["RO", "access"], 2n, R.INeg{0n}, 1n, 0n}], KBySpecs{}}}
    case 94n:
      Some{Ro{R.INeg{1n}, [KSpec{["RO", "access"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}}}
    case 95n:
      Some{Ro{R.INeg{2n}, [KSpec{["OW", "update"], 1n, R.IPos{0n}, 1n, 0n}, KSpec{["RO", "access"], 2n, R.INeg{0n}, 1n, 0n}], KBySpecs{}}}
    case 96n:
      Some{Ro{R.INeg{1n}, [KSpec{["RO", "access"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}}}
    case 97n:
      Some{Ro{R.INeg{2n}, [KSpec{["OW", "update"], 1n, R.IPos{0n}, 1n, 0n}, KSpec{["RO", "access"], 2n, R.INeg{0n}, 1n, 0n}], KBySpecs{}}}
    case 98n:
      Some{Ro{R.IPos{3n}, [KSpec{["RW", "access", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 99n:
      Some{Ro{R.IPos{4n}, [KSpec{["RW", "access", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 100n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 101n:
      Some{Ro{R.INeg{0n}, [], KBySpecs{}}}
    case 102n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 103n:
      Some{Ro{R.INeg{0n}, [], KBySpecs{}}}
    case 104n:
      Some{Ro{R.IPos{1n}, [], KBySpecs{}}}
    case 105n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 106n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 107n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 108n:
      Some{Ro{R.INeg{0n}, [], KBySpecs{}}}
    case 109n:
      Some{Ro{R.INeg{0n}, [], KBySpecs{}}}
    case 110n:
      Some{Ro{R.IPos{1n}, [], KBySpecs{}}}
    case 111n:
      Some{Ro{R.IPos{3n}, [], KBySpecs{}}}
    case 112n:
      Some{Ro{R.IPos{3n}, [KSpec{["RW", "access", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 113n:
      Some{Ro{R.IPos{1n}, [], KBySpecs{}}}
    case 114n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 115n:
      Some{Ro{R.INeg{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}, KSpec{["OW", "update"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 116n:
      Some{Ro{R.INeg{2n}, [KSpec{["RO", "access"], 1n, R.IPos{1n}, 1n, 0n}], KBySpecs{}}}
    case 117n:
      Some{Ro{R.INeg{1n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 118n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 119n:
      Some{Ro{R.INeg{1n}, [KSpec{["RW", "access", "delete"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 120n:
      Some{Ro{R.INeg{1n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 121n:
      Some{Ro{R.INeg{3n}, [KSpec{["RW", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 122n:
      Some{Ro{R.IPos{4n}, [KSpec{["RW", "access", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 123n:
      Some{Ro{R.INeg{2n}, [KSpec{["RW", "delete"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 124n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 125n:
      Some{Ro{R.IPos{3n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 126n:
      Some{Ro{R.INeg{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 127n:
      Some{Ro{R.IPos{3n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 128n:
      Some{Ro{R.IPos{3n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 129n:
      Some{Ro{R.IPos{4n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 130n:
      Some{Ro{R.IPos{4n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 131n:
      Some{Ro{R.INeg{3n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 132n:
      Some{Ro{R.INeg{3n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 133n:
      Some{Ro{R.INeg{3n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 134n:
      Some{Ro{R.INeg{3n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 135n:
      Some{Ro{R.INeg{3n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 136n:
      Some{Ro{R.INeg{3n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 137n:
      Some{Ro{R.IPos{4n}, [KSpec{["RW", "delete"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 138n:
      Some{Ro{R.IPos{4n}, [KSpec{["RW", "delete"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 139n:
      Some{Ro{R.IPos{4n}, [KSpec{["RW", "delete"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 140n:
      Some{Ro{R.INeg{1n}, [KSpec{["RW", "access", "delete"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 141n:
      Some{Ro{R.INeg{1n}, [KSpec{["RW", "access", "delete"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 142n:
      Some{Ro{R.INeg{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 143n:
      Some{Ro{R.INeg{2n}, [], KBySintercard{}}}
    case 144n:
      Some{Ro{R.INeg{2n}, [], KBySintercard{}}}
    case 145n:
      Some{Ro{R.INeg{2n}, [], KBySintercard{}}}
    case 146n:
      Some{Ro{R.INeg{2n}, [], KBySintercard{}}}
    case 147n:
      Some{Ro{R.INeg{3n}, [], KByZstore{}}}
    case 148n:
      Some{Ro{R.INeg{3n}, [], KByZstore{}}}
    case 149n:
      Some{Ro{R.INeg{3n}, [], KByZstore{}}}
    case 150n:
      Some{Ro{R.INeg{4n}, [KSpec{["OW", "update"], 1n, R.IPos{0n}, 1n, 0n}, KSpec{["RO", "access"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 151n:
      Some{Ro{R.INeg{3n}, [], KByLmpop{}}}
    case 152n:
      Some{Ro{R.INeg{1n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 153n:
      Some{Ro{R.INeg{2n}, [KSpec{["RW", "access", "delete"], 1n, R.INeg{1n}, 1n, 0n}], KBySpecs{}}}
    case 154n:
      Some{Ro{R.INeg{2n}, [KSpec{["RW", "access", "delete"], 1n, R.INeg{1n}, 1n, 0n}], KBySpecs{}}}
    case 155n:
      Some{Ro{R.IPos{4n}, [KSpec{["RW", "access", "delete"], 1n, R.IPos{0n}, 1n, 0n}, KSpec{["RW", "insert"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 156n:
      Some{Ro{R.IPos{6n}, [KSpec{["RW", "access", "delete"], 1n, R.IPos{0n}, 1n, 0n}, KSpec{["RW", "insert"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 157n:
      Some{Ro{R.INeg{4n}, [], KByBlmpop{}}}
    case 158n:
      Some{Ro{R.INeg{2n}, [KSpec{["RW", "access", "delete"], 1n, R.INeg{1n}, 1n, 0n}], KBySpecs{}}}
    case 159n:
      Some{Ro{R.INeg{2n}, [KSpec{["RW", "access", "delete"], 1n, R.INeg{1n}, 1n, 0n}], KBySpecs{}}}
    case 160n:
      Some{Ro{R.INeg{4n}, [], KByBlmpop{}}}
    case 161n:
      Some{Ro{R.IPos{1n}, [], KBySpecs{}}}
    case 162n:
      Some{Ro{R.IPos{1n}, [], KBySpecs{}}}
    case 163n:
      Some{Ro{R.IPos{1n}, [], KBySpecs{}}}
    case 164n:
      Some{Ro{R.INeg{1n}, [KSpec{["RO"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}}}
    case 165n:
      Some{Ro{R.IPos{1n}, [], KBySpecs{}}}
    case 166n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 167n:
      Some{Ro{R.INeg{0n}, [], KBySpecs{}}}
    case 168n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 169n:
      Some{Ro{R.INeg{0n}, [], KBySpecs{}}}
    case 170n:
      Some{Ro{R.INeg{1n}, [KSpec{["not_key"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}}}
    case 171n:
      Some{Ro{R.INeg{0n}, [KSpec{["not_key"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}}}
    case 172n:
      Some{Ro{R.IPos{3n}, [], KBySpecs{}}}
    case 173n:
      Some{Ro{R.IPos{3n}, [KSpec{["not_key"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 174n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 175n:
      Some{Ro{R.IPos{1n}, [], KBySpecs{}}}
    case 176n:
      Some{Ro{R.IPos{1n}, [], KBySpecs{}}}
    case 177n:
      Some{Ro{R.INeg{1n}, [], KBySort{}}}
    case 178n:
      Some{Ro{R.INeg{1n}, [], KBySortRo{}}}
    case 179n:
      Some{Ro{R.INeg{1n}, [KSpec{["RW", "insert"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 180n:
      Some{Ro{R.INeg{1n}, [KSpec{["RW", "access"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}}}
    case 181n:
      Some{Ro{R.INeg{1n}, [KSpec{["RW", "access", "insert"], 1n, R.IPos{0n}, 1n, 0n}, KSpec{["RO", "access"], 2n, R.INeg{0n}, 1n, 0n}], KBySpecs{}}}
    case 182n:
      Some{Ro{R.IPos{3n}, [KSpec{["RW", "access"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 183n:
      Some{Ro{R.IPos{1n}, [], KBySpecs{}}}
    case 184n:
      Some{Ro{R.IPos{1n}, [], KBySpecs{}}}
    case 185n:
      Some{Ro{R.IPos{1n}, [], KBySpecs{}}}
    case 186n:
      Some{Ro{R.IPos{3n}, [], KBySpecs{}}}
    case 187n:
      Some{Ro{R.INeg{0n}, [], KBySpecs{}}}
    case 188n:
      Some{Ro{R.INeg{0n}, [], KBySpecs{}}}
    case 189n:
      Some{Ro{R.INeg{4n}, [KSpec{["RW", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 190n:
      Some{Ro{R.INeg{3n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 191n:
      Some{Ro{R.INeg{1n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 192n:
      Some{Ro{R.INeg{1n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 193n:
      Some{Ro{R.INeg{5n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}, KSpecKw{["OW", "update"], "STORE", 6n, R.IPos{0n}, 1n, 0n}, KSpecKw{["OW", "update"], "STOREDIST", 6n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 194n:
      Some{Ro{R.INeg{5n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 195n:
      Some{Ro{R.INeg{4n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}, KSpecKw{["OW", "update"], "STORE", 5n, R.IPos{0n}, 1n, 0n}, KSpecKw{["OW", "update"], "STOREDIST", 5n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 196n:
      Some{Ro{R.INeg{4n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 197n:
      Some{Ro{R.INeg{6n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 198n:
      Some{Ro{R.INeg{7n}, [KSpec{["OW", "update"], 1n, R.IPos{0n}, 1n, 0n}, KSpec{["RO", "access"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 199n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 200n:
      Some{Ro{R.INeg{3n}, [KSpec{["OW", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 201n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 202n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 203n:
      Some{Ro{R.IPos{1n}, [], KBySpecs{}}}
    case 204n:
      Some{Ro{R.INeg{2n}, [], KByEval{}}}
    case 205n:
      Some{Ro{R.INeg{2n}, [], KByEval{}}}
    case 206n:
      Some{Ro{R.INeg{2n}, [], KByEval{}}}
    case 207n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 208n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 209n:
      Some{Ro{R.IPos{2n}, [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 210n:
      Some{Ro{R.INeg{3n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 211n:
      Some{Ro{R.INeg{3n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 212n:
      Some{Ro{R.INeg{3n}, [KSpecKw{["RO", "access"], "STREAMS", 1n, R.INeg{0n}, 1n, 2n}], KBySpecs{}}}
    case 213n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 214n:
      Some{Ro{R.INeg{2n}, [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 215n:
      Some{Ro{R.INeg{0n}, [], KBySpecs{}}}
    case 216n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 217n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 218n:
      Some{Ro{R.IPos{3n}, [], KBySpecs{}}}
    case 219n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 220n:
      Some{Ro{R.IPos{3n}, [], KBySpecs{}}}
    case 221n:
      Some{Ro{R.IPos{3n}, [], KBySpecs{}}}
    case 222n:
      Some{Ro{R.INeg{2n}, [], KBySpecs{}}}
    case 223n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 224n:
      Some{Ro{R.IPos{3n}, [], KBySpecs{}}}
    case 225n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 226n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 227n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 228n:
      Some{Ro{R.INeg{2n}, [], KBySpecs{}}}
    case 229n:
      Some{Ro{R.INeg{2n}, [], KBySpecs{}}}
    case 230n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 231n:
      Some{Ro{R.INeg{2n}, [], KBySpecs{}}}
    case 232n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 233n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 234n:
      Some{Ro{R.INeg{2n}, [], KBySpecs{}}}
    case 235n:
      Some{Ro{R.INeg{3n}, [], KBySpecs{}}}
    case 236n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 237n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 238n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 239n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 240n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 241n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 242n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 243n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 244n:
      Some{Ro{R.INeg{3n}, [], KBySpecs{}}}
    case 245n:
      Some{Ro{R.INeg{3n}, [], KBySpecs{}}}
    case 246n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 247n:
      Some{Ro{R.IPos{3n}, [KSpec{["RO"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 248n:
      Some{Ro{R.IPos{3n}, [KSpec{["RO"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 249n:
      Some{Ro{R.IPos{3n}, [KSpec{["RO"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 250n:
      Some{Ro{R.IPos{3n}, [KSpec{["RO"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 251n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 252n:
      Some{Ro{R.INeg{2n}, [KSpec{["RO"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 253n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 254n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 255n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 256n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 257n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 258n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 259n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 260n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 261n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 262n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 263n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 264n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 265n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 266n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 267n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 268n:
      Some{Ro{R.IPos{3n}, [], KBySpecs{}}}
    case 269n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 270n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 271n:
      Some{Ro{R.IPos{3n}, [], KBySpecs{}}}
    case 272n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 273n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 274n:
      Some{Ro{R.IPos{3n}, [], KBySpecs{}}}
    case 275n:
      Some{Ro{R.INeg{2n}, [], KBySpecs{}}}
    case 276n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 277n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 278n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 279n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 280n:
      Some{Ro{R.INeg{2n}, [], KBySpecs{}}}
    case 281n:
      Some{Ro{R.INeg{3n}, [], KBySpecs{}}}
    case 282n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 283n:
      Some{Ro{R.IPos{3n}, [], KBySpecs{}}}
    case 284n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 285n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 286n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 287n:
      Some{Ro{R.INeg{1n}, [], KBySpecs{}}}
    case 288n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 289n:
      Some{Ro{R.INeg{2n}, [], KBySpecs{}}}
    case 290n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 291n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 292n:
      Some{Ro{R.IPos{2n}, [], KBySpecs{}}}
    case 293n:
      Some{Ro{R.INeg{2n}, [KSpec{["RO", "access"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 294n:
      Some{Ro{R.IPos{3n}, [KSpec{["RO", "access"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case 295n:
      Some{Ro{R.IPos{4n}, [KSpec{["RO", "access"], 2n, R.IPos{0n}, 1n, 0n}], KBySpecs{}}}
    case _:
      None{}

# what else ACL's check of a call reads of its command, by its key: 1
# PUBLISH and SPUBLISH, 2 SUBSCRIBE and SSUBSCRIBE, 3 PSUBSCRIBE (the
# channels it names), 4 AUTH, HELLO, QUIT and RESET (which every user
# may run: Redis's CMD_NO_AUTH), 5 SORT, 6 SORT_RO (whose patterns name
# keys); 0 any other
def acl.kind.key(+key: Nat) -> Nat:
  match key:
    case 101n:
      4n
    case 102n:
      4n
    case 103n:
      4n
    case 104n:
      4n
    case 166n:
      2n
    case 168n:
      3n
    case 170n:
      2n
    case 172n:
      1n
    case 173n:
      1n
    case 177n:
      5n
    case 178n:
      6n
    case _:
      0n
# END gen_commands: by key

# whether the key at the head of ks is argument j or one after it
def keys.ge(+ks: List<&2, KeyAt>, +j: Nat) -> Bool:
  match ks:
    case Con{KeyAt{+at, +fl}, +rest}:
      Nat.is_le(j, at)
    case Nil{}:
      False{}

# the keys a call read, as Redis's getKeysFromCommand finds them for a
# client that tracks keys (trackingRememberKeys): of a command that only
# reads, by its key specs, when its arguments fit its arity. xs is argv
# from its index j on, and a key at j or after it (ge: keys.ge of ks's
# head) is found by dropping to it from there, so that argv is walked
# once while the keys' indices grow; an index below j, as a command's
# specs may give one, is read from argv's start. Read from the start
# each, the keys of an MGET of n keys took n * n / 2 steps.
def keys.names.go(ks: List<&2, KeyAt>, ge: Bool, xs: List<&2, String>, +j: Nat, +argv: List<&2, String>) -> List<&2, String>:
  match ks ge:
    case Con{KeyAt{+at, fl}, +rest} True{}:
      +ys = List.drop(&2, String, xs, Nat.sub(at, j))
      nth(0n, ys) <> keys.names.go(rest, keys.ge(rest, at), ys, at, argv)
    case Con{KeyAt{+at, fl}, +rest} False{}:
      nth(at, argv) <> keys.names.go(rest, keys.ge(rest, j), xs, j, argv)
    case Nil{} _:
      Nil{}

def keys.names(+ks: List<&2, KeyAt>, +argv: List<&2, String>) -> List<&2, String>:
  keys.names.go(ks, keys.ge(ks, 0n), argv, 0n, argv)

def keys.read.at(m: Maybe<&2, List<&2, KeyAt>>, +fits: Bool, +argv: List<&2, String>) -> List<&2, String>:
  match m fits:
    case Some{ks} True{}:
      keys.names(ks, argv)
    case _ _:
      Nil{}

def keys.read.of(m: Maybe<&2, Ro>, +argv: List<&2, String>) -> List<&2, String>:
  match m:
    case Some{Ro{arity, specs, way}}:
      keys.read.at(keys.find(way, specs, argv), arity.ok(arity, List.length(&2, String, argv)), argv)
    case None{}:
      Nil{}

def keys.read(+key: Nat, +argv: List<&2, String>) -> List<&2, String>:
  keys.read.of(ro.key(key), argv)

# COMMAND
# -------

def reply.sub(id: Nat, args: List<&2, String>) -> R.Reply:
  match id:
    case 1n:  # INFO
      info.named(args)
    case 2n:  # DOCS
      docs.named.of(args)
    case 3n:  # LIST
      list(args)
    case 5n:  # COUNT
      R.RInt{R.IPos{List.length(&2, Top, table())}}
    case 6n:  # GETKEYS
      keys(False{}, args)
    case 7n:  # GETKEYSANDFLAGS
      keys(True{}, args)
    case _:
      R.RError{"ERR unknown subcommand"}

# the reply to COMMAND and to the subcommands the parser let through
# (R.parse_command), with their arguments as they came
def reply(args: List<&2, String>) -> R.Reply:
  match args:
    case Nil{}:
      R.RArray{infos.all(table())}
    case Con{+sub, rest}:
      +up = String.to_upper(sub)
      reply.sub(R.command_id(up, String.length(up)), rest)
