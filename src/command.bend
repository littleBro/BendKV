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
import ./config.bend as C

# Types
# -----

# a key specification of an index and a range (the only kind BendKV's
# commands have): its flags, the index of its first key, the last key
# (from the first one, or counted from the end when negative), the step
# between keys, and the limit of a range to the end
type KSpec is Data:
  KSpec{flags: List<&2, String>, pos: Nat, last: R.Int, step: Nat, limit: Nat}

# how COMMAND GETKEYS finds a command's keys: from its key specs, or as
# the function Redis has for SET (whose key's flags depend on its GET)
type KWay is Data:
  KBySpecs{}
  KBySet{}

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

# The table
# ---------

# BEGIN gen_commands: table
def cmd.append() -> Top:
  Top{Desc{"append", R.IPos{3n}, ["write", "string", "fast"], [KSpec{["RW", "insert"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"append"}, R.RInt{R.IPos{3n}}, R.RArray{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RArray{[R.RStatus{"@write"}, R.RStatus{"@string"}, R.RStatus{"@fast"}]}, R.RArray{[]}, R.RArray{[R.RArray{[R.RBulk{"flags"}, R.RArray{[R.RStatus{"RW"}, R.RStatus{"insert"}]}, R.RBulk{"begin_search"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Append a value to a key"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(1). The amortized time complexity is O(1) assuming the appended value is small and the already present value is of any size, since the dynamic string library used by Redis will double the free space available on every reallocation."}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RArray{[R.RBulk{"name"}, R.RBulk{"value"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]},
  []}

def cmd.auth() -> Top:
  Top{Desc{"auth", R.INeg{1n}, ["fast", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"auth"}, R.RInt{R.INeg{1n}}, R.RArray{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}, R.RStatus{"fast"}, R.RStatus{"no_auth"}, R.RStatus{"allow_busy"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@fast"}, R.RStatus{"@connection"}]}, R.RArray{[]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Authenticate to the server"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of passwords defined for the user"}, R.RBulk{"history"}, R.RArray{[R.RArray{[R.RBulk{"6.0.0"}, R.RBulk{"Added ACL style (username and password)."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"username"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"since"}, R.RBulk{"6.0.0"}, R.RBulk{"flags"}, R.RArray{[R.RStatus{"optional"}]}]}, R.RArray{[R.RBulk{"name"}, R.RBulk{"password"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]},
  []}

def cmd.client() -> Top:
  Top{Desc{"client", R.INeg{1n}, ["slow"], [], KBySpecs{}, False{},
    [R.RBulk{"client"}, R.RInt{R.INeg{1n}}, R.RArray{[]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@slow"}]}, R.RArray{[]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"A container for client connection commands"}, R.RBulk{"since"}, R.RBulk{"2.4.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"Depends on subcommand."}]},
  [Desc{"client|caching", R.IPos{3n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"client|caching"}, R.RInt{R.IPos{3n}}, R.RArray{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RArray{[]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Instruct the server about tracking or not keys in the next request"}, R.RBulk{"since"}, R.RBulk{"6.0.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"mode"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"yes"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"YES"}]}, R.RArray{[R.RBulk{"name"}, R.RBulk{"no"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"NO"}]}]}]}]}]}, Desc{"client|getname", R.IPos{2n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"client|getname"}, R.RInt{R.IPos{2n}}, R.RArray{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RArray{[]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the current connection name"}, R.RBulk{"since"}, R.RBulk{"2.6.9"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"client|getredir", R.IPos{2n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"client|getredir"}, R.RInt{R.IPos{2n}}, R.RArray{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RArray{[]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Get tracking notifications redirection client ID if any"}, R.RBulk{"since"}, R.RBulk{"6.0.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"client|help", R.IPos{2n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"client|help"}, R.RInt{R.IPos{2n}}, R.RArray{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RArray{[]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Show helpful text about the different subcommands"}, R.RBulk{"since"}, R.RBulk{"5.0.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"client|id", R.IPos{2n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"client|id"}, R.RInt{R.IPos{2n}}, R.RArray{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RArray{[]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Returns the client ID for the current connection"}, R.RBulk{"since"}, R.RBulk{"5.0.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"client|no-evict", R.IPos{3n}, ["admin", "slow", "dangerous", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"client|no-evict"}, R.RInt{R.IPos{3n}}, R.RArray{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}, R.RStatus{"@connection"}]}, R.RArray{[]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Set client eviction mode for the current connection"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"enabled"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"on"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ON"}]}, R.RArray{[R.RBulk{"name"}, R.RBulk{"off"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"OFF"}]}]}]}]}]}, Desc{"client|reply", R.IPos{3n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"client|reply"}, R.RInt{R.IPos{3n}}, R.RArray{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RArray{[]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Instruct the server whether to reply to commands"}, R.RBulk{"since"}, R.RBulk{"3.2.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"on_off_skip"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"on"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ON"}]}, R.RArray{[R.RBulk{"name"}, R.RBulk{"off"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"OFF"}]}, R.RArray{[R.RBulk{"name"}, R.RBulk{"skip"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"SKIP"}]}]}]}]}]}, Desc{"client|setname", R.IPos{3n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"client|setname"}, R.RInt{R.IPos{3n}}, R.RArray{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RArray{[]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Set the current connection name"}, R.RBulk{"since"}, R.RBulk{"2.6.9"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"connection-name"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]}, Desc{"client|trackinginfo", R.IPos{2n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"client|trackinginfo"}, R.RInt{R.IPos{2n}}, R.RArray{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RArray{[]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Return information about server assisted client side caching for the current connection"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"client|unblock", R.INeg{2n}, ["admin", "slow", "dangerous", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"client|unblock"}, R.RInt{R.INeg{2n}}, R.RArray{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}, R.RStatus{"@connection"}]}, R.RArray{[]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Unblock a client blocked in a blocking command from a different connection"}, R.RBulk{"since"}, R.RBulk{"5.0.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(log N) where N is the number of client connections"}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"client-id"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RArray{[R.RBulk{"name"}, R.RBulk{"timeout_error"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"flags"}, R.RArray{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"timeout"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"TIMEOUT"}]}, R.RArray{[R.RBulk{"name"}, R.RBulk{"error"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ERROR"}]}]}]}]}]}]}

def cmd.command() -> Top:
  Top{Desc{"command", R.INeg{0n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"command"}, R.RInt{R.INeg{0n}}, R.RArray{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RArray{[R.RBulk{"nondeterministic_output_order"}]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Get array of Redis command details"}, R.RBulk{"since"}, R.RBulk{"2.8.13"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the total number of Redis commands"}]},
  [Desc{"command|count", R.IPos{2n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"command|count"}, R.RInt{R.IPos{2n}}, R.RArray{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RArray{[]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Get total number of Redis commands"}, R.RBulk{"since"}, R.RBulk{"2.8.13"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"command|docs", R.INeg{1n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"command|docs"}, R.RInt{R.INeg{1n}}, R.RArray{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RArray{[R.RBulk{"nondeterministic_output_order"}]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Get array of specific Redis command documentation"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of commands to look up"}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"command-name"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RArray{[R.RStatus{"optional"}, R.RStatus{"multiple"}]}]}]}]}, Desc{"command|getkeys", R.INeg{3n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"command|getkeys"}, R.RInt{R.INeg{3n}}, R.RArray{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RArray{[]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Extract keys given a full Redis command"}, R.RBulk{"since"}, R.RBulk{"2.8.13"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of arguments to the command"}]}, Desc{"command|getkeysandflags", R.INeg{3n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"command|getkeysandflags"}, R.RInt{R.INeg{3n}}, R.RArray{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RArray{[]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Extract keys and access flags given a full Redis command"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of arguments to the command"}]}, Desc{"command|help", R.IPos{2n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"command|help"}, R.RInt{R.IPos{2n}}, R.RArray{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RArray{[]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Show helpful text about the different subcommands"}, R.RBulk{"since"}, R.RBulk{"5.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"command|info", R.INeg{1n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"command|info"}, R.RInt{R.INeg{1n}}, R.RArray{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RArray{[R.RBulk{"nondeterministic_output_order"}]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Get array of specific Redis command details, or all when no argument is given."}, R.RBulk{"since"}, R.RBulk{"2.8.13"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of commands to look up"}, R.RBulk{"history"}, R.RArray{[R.RArray{[R.RBulk{"7.0.0"}, R.RBulk{"Allowed to be called with no argument to get info on all commands."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"command-name"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RArray{[R.RStatus{"optional"}, R.RStatus{"multiple"}]}]}]}]}, Desc{"command|list", R.INeg{1n}, ["slow", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"command|list"}, R.RInt{R.INeg{1n}}, R.RArray{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@slow"}, R.RStatus{"@connection"}]}, R.RArray{[R.RBulk{"nondeterministic_output_order"}]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Get an array of Redis command names"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the total number of Redis commands"}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"filterby"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"token"}, R.RBulk{"FILTERBY"}, R.RBulk{"flags"}, R.RArray{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"module-name"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"token"}, R.RBulk{"MODULE"}]}, R.RArray{[R.RBulk{"name"}, R.RBulk{"category"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"token"}, R.RBulk{"ACLCAT"}]}, R.RArray{[R.RBulk{"name"}, R.RBulk{"pattern"}, R.RBulk{"type"}, R.RBulk{"pattern"}, R.RBulk{"token"}, R.RBulk{"PATTERN"}]}]}]}]}]}]}

def cmd.config() -> Top:
  Top{Desc{"config", R.INeg{1n}, ["slow"], [], KBySpecs{}, False{},
    [R.RBulk{"config"}, R.RInt{R.INeg{1n}}, R.RArray{[]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@slow"}]}, R.RArray{[]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"A container for server configuration commands"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"Depends on subcommand."}]},
  [Desc{"config|get", R.INeg{2n}, ["admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"config|get"}, R.RInt{R.INeg{2n}}, R.RArray{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RArray{[]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the values of configuration parameters"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N) when N is the number of configuration parameters provided"}, R.RBulk{"history"}, R.RArray{[R.RArray{[R.RBulk{"7.0.0"}, R.RBulk{"Added the ability to pass multiple pattern parameters in one call"}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"parameter"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"flags"}, R.RArray{[R.RStatus{"multiple"}]}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"parameter"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]}]}]}, Desc{"config|help", R.IPos{2n}, ["slow"], [], KBySpecs{}, False{},
    [R.RBulk{"config|help"}, R.RInt{R.IPos{2n}}, R.RArray{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@slow"}]}, R.RArray{[]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Show helpful text about the different subcommands"}, R.RBulk{"since"}, R.RBulk{"5.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"config|resetstat", R.IPos{2n}, ["admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"config|resetstat"}, R.RInt{R.IPos{2n}}, R.RArray{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RArray{[]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Reset the stats returned by INFO"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"config|rewrite", R.IPos{2n}, ["admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"config|rewrite"}, R.RInt{R.IPos{2n}}, R.RArray{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RArray{[]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Rewrite the configuration file with the in memory configuration"}, R.RBulk{"since"}, R.RBulk{"2.8.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}, Desc{"config|set", R.INeg{3n}, ["admin", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"config|set"}, R.RInt{R.INeg{3n}}, R.RArray{[R.RStatus{"admin"}, R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@admin"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RArray{[R.RBulk{"request_policy:all_nodes"}, R.RBulk{"response_policy:all_succeeded"}]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Set configuration parameters to the given values"}, R.RBulk{"since"}, R.RBulk{"2.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N) when N is the number of configuration parameters provided"}, R.RBulk{"history"}, R.RArray{[R.RArray{[R.RBulk{"7.0.0"}, R.RBulk{"Added the ability to set multiple parameters in one call."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"parameter_value"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"flags"}, R.RArray{[R.RStatus{"multiple"}]}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"parameter"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RArray{[R.RBulk{"name"}, R.RBulk{"value"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]}]}]}]}

def cmd.dbsize() -> Top:
  Top{Desc{"dbsize", R.IPos{1n}, ["keyspace", "read", "fast"], [], KBySpecs{}, False{},
    [R.RBulk{"dbsize"}, R.RInt{R.IPos{1n}}, R.RArray{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@keyspace"}, R.RStatus{"@read"}, R.RStatus{"@fast"}]}, R.RArray{[R.RBulk{"request_policy:all_shards"}, R.RBulk{"response_policy:agg_sum"}]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Return the number of keys in the selected database"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]},
  []}

def cmd.decr() -> Top:
  Top{Desc{"decr", R.IPos{2n}, ["write", "string", "fast"], [KSpec{["RW", "access", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"decr"}, R.RInt{R.IPos{2n}}, R.RArray{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RArray{[R.RStatus{"@write"}, R.RStatus{"@string"}, R.RStatus{"@fast"}]}, R.RArray{[]}, R.RArray{[R.RArray{[R.RBulk{"flags"}, R.RArray{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Decrement the integer value of a key by one"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]},
  []}

def cmd.decrby() -> Top:
  Top{Desc{"decrby", R.IPos{3n}, ["write", "string", "fast"], [KSpec{["RW", "access", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"decrby"}, R.RInt{R.IPos{3n}}, R.RArray{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RArray{[R.RStatus{"@write"}, R.RStatus{"@string"}, R.RStatus{"@fast"}]}, R.RArray{[]}, R.RArray{[R.RArray{[R.RBulk{"flags"}, R.RArray{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Decrement the integer value of a key by the given number"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RArray{[R.RBulk{"name"}, R.RBulk{"decrement"}, R.RBulk{"type"}, R.RBulk{"integer"}]}]}]},
  []}

def cmd.del() -> Top:
  Top{Desc{"del", R.INeg{1n}, ["keyspace", "write", "slow"], [KSpec{["RM", "delete"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"del"}, R.RInt{R.INeg{1n}}, R.RArray{[R.RStatus{"write"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.INeg{0n}}, R.RInt{R.IPos{1n}}, R.RArray{[R.RStatus{"@keyspace"}, R.RStatus{"@write"}, R.RStatus{"@slow"}]}, R.RArray{[R.RBulk{"request_policy:multi_shard"}, R.RBulk{"response_policy:agg_sum"}]}, R.RArray{[R.RArray{[R.RBulk{"flags"}, R.RArray{[R.RStatus{"RM"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"lastkey"}, R.RInt{R.INeg{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Delete a key"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of keys that will be removed. When a key to remove holds a value other than a string, the individual complexity for this key is O(M) where M is the number of elements in the list, set, sorted set or hash. Removing a single key that holds a string value is O(1)."}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RArray{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.echo() -> Top:
  Top{Desc{"echo", R.IPos{2n}, ["fast", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"echo"}, R.RInt{R.IPos{2n}}, R.RArray{[R.RStatus{"loading"}, R.RStatus{"stale"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@fast"}, R.RStatus{"@connection"}]}, R.RArray{[]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Echo the given string"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"message"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]},
  []}

def cmd.exists() -> Top:
  Top{Desc{"exists", R.INeg{1n}, ["keyspace", "read", "fast"], [KSpec{["RO"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"exists"}, R.RInt{R.INeg{1n}}, R.RArray{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.INeg{0n}}, R.RInt{R.IPos{1n}}, R.RArray{[R.RStatus{"@keyspace"}, R.RStatus{"@read"}, R.RStatus{"@fast"}]}, R.RArray{[R.RBulk{"request_policy:multi_shard"}, R.RBulk{"response_policy:agg_sum"}]}, R.RArray{[R.RArray{[R.RBulk{"flags"}, R.RArray{[R.RStatus{"RO"}]}, R.RBulk{"begin_search"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"lastkey"}, R.RInt{R.INeg{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Determine if a key exists"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of keys to check."}, R.RBulk{"history"}, R.RArray{[R.RArray{[R.RBulk{"3.0.3"}, R.RBulk{"Accepts multiple `key` arguments."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RArray{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.flushall() -> Top:
  Top{Desc{"flushall", R.INeg{0n}, ["keyspace", "write", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"flushall"}, R.RInt{R.INeg{0n}}, R.RArray{[R.RStatus{"write"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@keyspace"}, R.RStatus{"@write"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RArray{[R.RBulk{"request_policy:all_shards"}, R.RBulk{"response_policy:all_succeeded"}]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Remove all keys from all databases"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the total number of keys in all databases"}, R.RBulk{"history"}, R.RArray{[R.RArray{[R.RBulk{"4.0.0"}, R.RBulk{"Added the `ASYNC` flushing mode modifier."}]}, R.RArray{[R.RBulk{"6.2.0"}, R.RBulk{"Added the `SYNC` flushing mode modifier."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"async"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"flags"}, R.RArray{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"async"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ASYNC"}, R.RBulk{"since"}, R.RBulk{"4.0.0"}]}, R.RArray{[R.RBulk{"name"}, R.RBulk{"sync"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"SYNC"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}]}]}]}]}]},
  []}

def cmd.flushdb() -> Top:
  Top{Desc{"flushdb", R.INeg{0n}, ["keyspace", "write", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"flushdb"}, R.RInt{R.INeg{0n}}, R.RArray{[R.RStatus{"write"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@keyspace"}, R.RStatus{"@write"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RArray{[R.RBulk{"request_policy:all_shards"}, R.RBulk{"response_policy:all_succeeded"}]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Remove all keys from the current database"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of keys in the selected database"}, R.RBulk{"history"}, R.RArray{[R.RArray{[R.RBulk{"4.0.0"}, R.RBulk{"Added the `ASYNC` flushing mode modifier."}]}, R.RArray{[R.RBulk{"6.2.0"}, R.RBulk{"Added the `SYNC` flushing mode modifier."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"async"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"flags"}, R.RArray{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"async"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ASYNC"}, R.RBulk{"since"}, R.RBulk{"4.0.0"}]}, R.RArray{[R.RBulk{"name"}, R.RBulk{"sync"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"SYNC"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}]}]}]}]}]},
  []}

def cmd.function() -> Top:
  Top{Desc{"function", R.INeg{1n}, ["slow"], [], KBySpecs{}, False{},
    [R.RBulk{"function"}, R.RInt{R.INeg{1n}}, R.RArray{[]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@slow"}]}, R.RArray{[]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"A container for function commands"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"scripting"}, R.RBulk{"complexity"}, R.RBulk{"Depends on subcommand."}]},
  [Desc{"function|flush", R.INeg{1n}, ["write", "slow", "scripting"], [], KBySpecs{}, False{},
    [R.RBulk{"function|flush"}, R.RInt{R.INeg{1n}}, R.RArray{[R.RStatus{"write"}, R.RStatus{"noscript"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@write"}, R.RStatus{"@slow"}, R.RStatus{"@scripting"}]}, R.RArray{[R.RBulk{"request_policy:all_shards"}, R.RBulk{"response_policy:all_succeeded"}]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Deleting all functions"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"scripting"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of functions deleted"}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"async"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"flags"}, R.RArray{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"async"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"ASYNC"}]}, R.RArray{[R.RBulk{"name"}, R.RBulk{"sync"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"SYNC"}]}]}]}]}]}, Desc{"function|help", R.IPos{2n}, ["slow", "scripting"], [], KBySpecs{}, False{},
    [R.RBulk{"function|help"}, R.RInt{R.IPos{2n}}, R.RArray{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@slow"}, R.RStatus{"@scripting"}]}, R.RArray{[]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Show helpful text about the different subcommands"}, R.RBulk{"since"}, R.RBulk{"7.0.0"}, R.RBulk{"group"}, R.RBulk{"scripting"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]}]}

def cmd.get() -> Top:
  Top{Desc{"get", R.IPos{2n}, ["read", "string", "fast"], [KSpec{["RO", "access"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"get"}, R.RInt{R.IPos{2n}}, R.RArray{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RArray{[R.RStatus{"@read"}, R.RStatus{"@string"}, R.RStatus{"@fast"}]}, R.RArray{[]}, R.RArray{[R.RArray{[R.RBulk{"flags"}, R.RArray{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the value of a key"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]},
  []}

def cmd.getset() -> Top:
  Top{Desc{"getset", R.IPos{3n}, ["write", "string", "fast"], [KSpec{["RW", "access", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"getset"}, R.RInt{R.IPos{3n}}, R.RArray{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RArray{[R.RStatus{"@write"}, R.RStatus{"@string"}, R.RStatus{"@fast"}]}, R.RArray{[]}, R.RArray{[R.RArray{[R.RBulk{"flags"}, R.RArray{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Set the string value of a key and return its old value"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"doc_flags"}, R.RArray{[R.RStatus{"deprecated"}]}, R.RBulk{"deprecated_since"}, R.RBulk{"6.2.0"}, R.RBulk{"replaced_by"}, R.RBulk{"`SET` with the `!GET` argument"}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RArray{[R.RBulk{"name"}, R.RBulk{"value"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]},
  []}

def cmd.hello() -> Top:
  Top{Desc{"hello", R.INeg{0n}, ["fast", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"hello"}, R.RInt{R.INeg{0n}}, R.RArray{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}, R.RStatus{"fast"}, R.RStatus{"no_auth"}, R.RStatus{"allow_busy"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@fast"}, R.RStatus{"@connection"}]}, R.RArray{[]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Handshake with Redis"}, R.RBulk{"since"}, R.RBulk{"6.0.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"history"}, R.RArray{[R.RArray{[R.RBulk{"6.2.0"}, R.RBulk{"`protover` made optional; when called without arguments the command reports the current connection's context."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"arguments"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"flags"}, R.RArray{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"protover"}, R.RBulk{"type"}, R.RBulk{"integer"}]}, R.RArray{[R.RBulk{"name"}, R.RBulk{"username_password"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"token"}, R.RBulk{"AUTH"}, R.RBulk{"flags"}, R.RArray{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"username"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RArray{[R.RBulk{"name"}, R.RBulk{"password"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]}, R.RArray{[R.RBulk{"name"}, R.RBulk{"clientname"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"token"}, R.RBulk{"SETNAME"}, R.RBulk{"flags"}, R.RArray{[R.RStatus{"optional"}]}]}]}]}]}]},
  []}

def cmd.incr() -> Top:
  Top{Desc{"incr", R.IPos{2n}, ["write", "string", "fast"], [KSpec{["RW", "access", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"incr"}, R.RInt{R.IPos{2n}}, R.RArray{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RArray{[R.RStatus{"@write"}, R.RStatus{"@string"}, R.RStatus{"@fast"}]}, R.RArray{[]}, R.RArray{[R.RArray{[R.RBulk{"flags"}, R.RArray{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Increment the integer value of a key by one"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]},
  []}

def cmd.incrby() -> Top:
  Top{Desc{"incrby", R.IPos{3n}, ["write", "string", "fast"], [KSpec{["RW", "access", "update"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"incrby"}, R.RInt{R.IPos{3n}}, R.RArray{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RArray{[R.RStatus{"@write"}, R.RStatus{"@string"}, R.RStatus{"@fast"}]}, R.RArray{[]}, R.RArray{[R.RArray{[R.RBulk{"flags"}, R.RArray{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Increment the integer value of a key by the given amount"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RArray{[R.RBulk{"name"}, R.RBulk{"increment"}, R.RBulk{"type"}, R.RBulk{"integer"}]}]}]},
  []}

def cmd.info() -> Top:
  Top{Desc{"info", R.INeg{0n}, ["slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"info"}, R.RInt{R.INeg{0n}}, R.RArray{[R.RStatus{"loading"}, R.RStatus{"stale"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RArray{[R.RBulk{"nondeterministic_output"}, R.RBulk{"request_policy:all_shards"}, R.RBulk{"response_policy:special"}]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Get information and statistics about the server"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"server"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"history"}, R.RArray{[R.RArray{[R.RBulk{"7.0.0"}, R.RBulk{"Added support for taking multiple section arguments."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"section"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RArray{[R.RStatus{"optional"}, R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.keys() -> Top:
  Top{Desc{"keys", R.IPos{2n}, ["keyspace", "read", "slow", "dangerous"], [], KBySpecs{}, False{},
    [R.RBulk{"keys"}, R.RInt{R.IPos{2n}}, R.RArray{[R.RStatus{"readonly"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@keyspace"}, R.RStatus{"@read"}, R.RStatus{"@slow"}, R.RStatus{"@dangerous"}]}, R.RArray{[R.RBulk{"request_policy:all_shards"}, R.RBulk{"nondeterministic_output_order"}]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Find all keys matching the given pattern"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(N) with N being the number of keys in the database, under the assumption that the key names in the database and the given pattern have limited length."}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"pattern"}, R.RBulk{"type"}, R.RBulk{"pattern"}]}]}]},
  []}

def cmd.mget() -> Top:
  Top{Desc{"mget", R.INeg{1n}, ["read", "string", "fast"], [KSpec{["RO", "access"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"mget"}, R.RInt{R.INeg{1n}}, R.RArray{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.INeg{0n}}, R.RInt{R.IPos{1n}}, R.RArray{[R.RStatus{"@read"}, R.RStatus{"@string"}, R.RStatus{"@fast"}]}, R.RArray{[R.RBulk{"request_policy:multi_shard"}]}, R.RArray{[R.RArray{[R.RBulk{"flags"}, R.RArray{[R.RStatus{"RO"}, R.RStatus{"access"}]}, R.RBulk{"begin_search"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"lastkey"}, R.RInt{R.INeg{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the values of all the given keys"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of keys to retrieve."}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RArray{[R.RStatus{"multiple"}]}]}]}]},
  []}

def cmd.mset() -> Top:
  Top{Desc{"mset", R.INeg{2n}, ["write", "string", "slow"], [KSpec{["OW", "update"], 1n, R.INeg{0n}, 2n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"mset"}, R.RInt{R.INeg{2n}}, R.RArray{[R.RStatus{"write"}, R.RStatus{"denyoom"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.INeg{0n}}, R.RInt{R.IPos{2n}}, R.RArray{[R.RStatus{"@write"}, R.RStatus{"@string"}, R.RStatus{"@slow"}]}, R.RArray{[R.RBulk{"request_policy:multi_shard"}, R.RBulk{"response_policy:all_succeeded"}]}, R.RArray{[R.RArray{[R.RBulk{"flags"}, R.RArray{[R.RStatus{"OW"}, R.RStatus{"update"}]}, R.RBulk{"begin_search"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"lastkey"}, R.RInt{R.INeg{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{2n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Set multiple keys to multiple values"}, R.RBulk{"since"}, R.RBulk{"1.0.1"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(N) where N is the number of keys to set."}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"key_value"}, R.RBulk{"type"}, R.RBulk{"block"}, R.RBulk{"flags"}, R.RArray{[R.RStatus{"multiple"}]}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RArray{[R.RBulk{"name"}, R.RBulk{"value"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]}]}]},
  []}

def cmd.ping() -> Top:
  Top{Desc{"ping", R.INeg{0n}, ["fast", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"ping"}, R.RInt{R.INeg{0n}}, R.RArray{[R.RStatus{"fast"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@fast"}, R.RStatus{"@connection"}]}, R.RArray{[R.RBulk{"request_policy:all_shards"}, R.RBulk{"response_policy:all_succeeded"}]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Ping the server"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"message"}, R.RBulk{"type"}, R.RBulk{"string"}, R.RBulk{"flags"}, R.RArray{[R.RStatus{"optional"}]}]}]}]},
  []}

def cmd.quit() -> Top:
  Top{Desc{"quit", R.INeg{0n}, ["fast", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"quit"}, R.RInt{R.INeg{0n}}, R.RArray{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}, R.RStatus{"fast"}, R.RStatus{"no_auth"}, R.RStatus{"allow_busy"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@fast"}, R.RStatus{"@connection"}]}, R.RArray{[]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Close the connection"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]},
  []}

def cmd.reset() -> Top:
  Top{Desc{"reset", R.IPos{1n}, ["fast", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"reset"}, R.RInt{R.IPos{1n}}, R.RArray{[R.RStatus{"noscript"}, R.RStatus{"loading"}, R.RStatus{"stale"}, R.RStatus{"fast"}, R.RStatus{"no_auth"}, R.RStatus{"allow_busy"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@fast"}, R.RStatus{"@connection"}]}, R.RArray{[]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Reset the connection"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}]},
  []}

def cmd.select() -> Top:
  Top{Desc{"select", R.IPos{2n}, ["fast", "connection"], [], KBySpecs{}, False{},
    [R.RBulk{"select"}, R.RInt{R.IPos{2n}}, R.RArray{[R.RStatus{"loading"}, R.RStatus{"stale"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RInt{R.IPos{0n}}, R.RArray{[R.RStatus{"@fast"}, R.RStatus{"@connection"}]}, R.RArray{[]}, R.RArray{[]}],
    [R.RBulk{"summary"}, R.RBulk{"Change the selected database for the current connection"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"connection"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"index"}, R.RBulk{"type"}, R.RBulk{"integer"}]}]}]},
  []}

def cmd.set() -> Top:
  Top{Desc{"set", R.INeg{2n}, ["write", "string", "slow"], [KSpec{["RW", "access", "update", "variable_flags"], 1n, R.IPos{0n}, 1n, 0n}], KBySet{}, False{},
    [R.RBulk{"set"}, R.RInt{R.INeg{2n}}, R.RArray{[R.RStatus{"write"}, R.RStatus{"denyoom"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RArray{[R.RStatus{"@write"}, R.RStatus{"@string"}, R.RStatus{"@slow"}]}, R.RArray{[]}, R.RArray{[R.RArray{[R.RBulk{"notes"}, R.RBulk{"RW and ACCESS due to the optional `GET` argument"}, R.RBulk{"flags"}, R.RArray{[R.RStatus{"RW"}, R.RStatus{"access"}, R.RStatus{"update"}, R.RStatus{"variable_flags"}]}, R.RBulk{"begin_search"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Set the string value of a key"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"history"}, R.RArray{[R.RArray{[R.RBulk{"2.6.12"}, R.RBulk{"Added the `EX`, `PX`, `NX` and `XX` options."}]}, R.RArray{[R.RBulk{"6.0.0"}, R.RBulk{"Added the `KEEPTTL` option."}]}, R.RArray{[R.RBulk{"6.2.0"}, R.RBulk{"Added the `GET`, `EXAT` and `PXAT` option."}]}, R.RArray{[R.RBulk{"7.0.0"}, R.RBulk{"Allowed the `NX` and `GET` options to be used together."}]}]}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RArray{[R.RBulk{"name"}, R.RBulk{"value"}, R.RBulk{"type"}, R.RBulk{"string"}]}, R.RArray{[R.RBulk{"name"}, R.RBulk{"condition"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"since"}, R.RBulk{"2.6.12"}, R.RBulk{"flags"}, R.RArray{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"nx"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"NX"}]}, R.RArray{[R.RBulk{"name"}, R.RBulk{"xx"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"XX"}]}]}]}, R.RArray{[R.RBulk{"name"}, R.RBulk{"get"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"GET"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}, R.RBulk{"flags"}, R.RArray{[R.RStatus{"optional"}]}]}, R.RArray{[R.RBulk{"name"}, R.RBulk{"expiration"}, R.RBulk{"type"}, R.RBulk{"oneof"}, R.RBulk{"flags"}, R.RArray{[R.RStatus{"optional"}]}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"seconds"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"EX"}, R.RBulk{"since"}, R.RBulk{"2.6.12"}]}, R.RArray{[R.RBulk{"name"}, R.RBulk{"milliseconds"}, R.RBulk{"type"}, R.RBulk{"integer"}, R.RBulk{"token"}, R.RBulk{"PX"}, R.RBulk{"since"}, R.RBulk{"2.6.12"}]}, R.RArray{[R.RBulk{"name"}, R.RBulk{"unix-time-seconds"}, R.RBulk{"type"}, R.RBulk{"unix-time"}, R.RBulk{"token"}, R.RBulk{"EXAT"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}]}, R.RArray{[R.RBulk{"name"}, R.RBulk{"unix-time-milliseconds"}, R.RBulk{"type"}, R.RBulk{"unix-time"}, R.RBulk{"token"}, R.RBulk{"PXAT"}, R.RBulk{"since"}, R.RBulk{"6.2.0"}]}, R.RArray{[R.RBulk{"name"}, R.RBulk{"keepttl"}, R.RBulk{"type"}, R.RBulk{"pure-token"}, R.RBulk{"token"}, R.RBulk{"KEEPTTL"}, R.RBulk{"since"}, R.RBulk{"6.0.0"}]}]}]}]}]},
  []}

def cmd.setnx() -> Top:
  Top{Desc{"setnx", R.IPos{3n}, ["write", "string", "fast"], [KSpec{["OW", "insert"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"setnx"}, R.RInt{R.IPos{3n}}, R.RArray{[R.RStatus{"write"}, R.RStatus{"denyoom"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RArray{[R.RStatus{"@write"}, R.RStatus{"@string"}, R.RStatus{"@fast"}]}, R.RArray{[]}, R.RArray{[R.RArray{[R.RBulk{"flags"}, R.RArray{[R.RStatus{"OW"}, R.RStatus{"insert"}]}, R.RBulk{"begin_search"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Set the value of a key, only if the key does not exist"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}, R.RArray{[R.RBulk{"name"}, R.RBulk{"value"}, R.RBulk{"type"}, R.RBulk{"string"}]}]}]},
  []}

def cmd.strlen() -> Top:
  Top{Desc{"strlen", R.IPos{2n}, ["read", "string", "fast"], [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"strlen"}, R.RInt{R.IPos{2n}}, R.RArray{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RArray{[R.RStatus{"@read"}, R.RStatus{"@string"}, R.RStatus{"@fast"}]}, R.RArray{[]}, R.RArray{[R.RArray{[R.RBulk{"flags"}, R.RArray{[R.RStatus{"RO"}]}, R.RBulk{"begin_search"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Get the length of the value stored in a key"}, R.RBulk{"since"}, R.RBulk{"2.2.0"}, R.RBulk{"group"}, R.RBulk{"string"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]},
  []}

def cmd.type() -> Top:
  Top{Desc{"type", R.IPos{2n}, ["keyspace", "read", "fast"], [KSpec{["RO"], 1n, R.IPos{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"type"}, R.RInt{R.IPos{2n}}, R.RArray{[R.RStatus{"readonly"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RInt{R.IPos{1n}}, R.RArray{[R.RStatus{"@keyspace"}, R.RStatus{"@read"}, R.RStatus{"@fast"}]}, R.RArray{[]}, R.RArray{[R.RArray{[R.RBulk{"flags"}, R.RArray{[R.RStatus{"RO"}]}, R.RBulk{"begin_search"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"lastkey"}, R.RInt{R.IPos{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Determine the type stored at key"}, R.RBulk{"since"}, R.RBulk{"1.0.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(1)"}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}]}]}]},
  []}

def cmd.unlink() -> Top:
  Top{Desc{"unlink", R.INeg{1n}, ["keyspace", "write", "fast"], [KSpec{["RM", "delete"], 1n, R.INeg{0n}, 1n, 0n}], KBySpecs{}, False{},
    [R.RBulk{"unlink"}, R.RInt{R.INeg{1n}}, R.RArray{[R.RStatus{"write"}, R.RStatus{"fast"}]}, R.RInt{R.IPos{1n}}, R.RInt{R.INeg{0n}}, R.RInt{R.IPos{1n}}, R.RArray{[R.RStatus{"@keyspace"}, R.RStatus{"@write"}, R.RStatus{"@fast"}]}, R.RArray{[R.RBulk{"request_policy:multi_shard"}, R.RBulk{"response_policy:agg_sum"}]}, R.RArray{[R.RArray{[R.RBulk{"flags"}, R.RArray{[R.RStatus{"RM"}, R.RStatus{"delete"}]}, R.RBulk{"begin_search"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"index"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"index"}, R.RInt{R.IPos{1n}}]}]}, R.RBulk{"find_keys"}, R.RArray{[R.RBulk{"type"}, R.RBulk{"range"}, R.RBulk{"spec"}, R.RArray{[R.RBulk{"lastkey"}, R.RInt{R.INeg{0n}}, R.RBulk{"keystep"}, R.RInt{R.IPos{1n}}, R.RBulk{"limit"}, R.RInt{R.IPos{0n}}]}]}]}]}],
    [R.RBulk{"summary"}, R.RBulk{"Delete a key asynchronously in another thread. Otherwise it is just as DEL, but non blocking."}, R.RBulk{"since"}, R.RBulk{"4.0.0"}, R.RBulk{"group"}, R.RBulk{"generic"}, R.RBulk{"complexity"}, R.RBulk{"O(1) for each key removed regardless of its size. Then the command does O(N) work in a different thread in order to reclaim memory, where N is the number of allocations the deleted objects where composed of."}, R.RBulk{"arguments"}, R.RArray{[R.RArray{[R.RBulk{"name"}, R.RBulk{"key"}, R.RBulk{"type"}, R.RBulk{"key"}, R.RBulk{"key_spec_index"}, R.RInt{R.IPos{0n}}, R.RBulk{"flags"}, R.RArray{[R.RStatus{"multiple"}]}]}]}]},
  []}

# the commands, by name
def table() -> List<&2, Top>:
  [cmd.append(), cmd.auth(), cmd.client(), cmd.command(), cmd.config(), cmd.dbsize(), cmd.decr(), cmd.decrby(), cmd.del(), cmd.echo(), cmd.exists(), cmd.flushall(), cmd.flushdb(), cmd.function(), cmd.get(), cmd.getset(), cmd.hello(), cmd.incr(), cmd.incrby(), cmd.info(), cmd.keys(), cmd.mget(), cmd.mset(), cmd.ping(), cmd.quit(), cmd.reset(), cmd.select(), cmd.set(), cmd.setnx(), cmd.strlen(), cmd.type(), cmd.unlink()]

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

def info.desc(d: Desc, subs: List<&2, R.Reply>) -> R.Reply:
  match d:
    case Desc{name, arity, cats, specs, way, nokeys, info, docs}:
      R.RArray{List.append(&2, R.Reply, info, [R.RArray{subs}])}

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
      R.RArray{List.append(&2, R.Reply, docs, more)}

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
      [R.RBulk{"subcommands"}, R.RArray{docs.subs(d <> rest)}]

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
      R.RArray{docs.all(table())}
    case Con{n, rest}:
      R.RArray{docs.named(n <> rest)}

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
      C.stringmatch(p, name, True{})

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

# a spec's keys in a command line of argc arguments (Redis's
# getKeysUsingKeySpecs): none for a spec of no keys (not_key), and no
# answer at all for a range out of the line or an incomplete spec
def keys.spec(sp: KSpec, +argc: Nat) -> Maybe<&2, List<&2, KeyAt>>:
  match sp:
    case KSpec{+flags, +pos, last, +step, +limit}:
      Bool.pick(Maybe<&2, List<&2, KeyAt>>, has("not_key", flags), Some{Nil{}},
        Bool.pick(Maybe<&2, List<&2, KeyAt>>, Bool.or(Nat.is_le(argc, pos), has("incomplete", flags)), None{},
          keys.span(keys.last(pos, last, limit, argc), pos, step, argc, flags)))

def keys.more(m: Maybe<&2, List<&2, KeyAt>>, rest: Maybe<&2, List<&2, KeyAt>>) -> Maybe<&2, List<&2, KeyAt>>:
  match m rest:
    case Some{ks} Some{more}:
      Some{List.append(&2, KeyAt, ks, more)}
    case _ _:
      None{}

def keys.specs(sps: List<&2, KSpec>, +argc: Nat) -> Maybe<&2, List<&2, KeyAt>>:
  match sps:
    case Nil{}:
      Some{Nil{}}
    case Con{sp, rest}:
      keys.more(keys.spec(sp, argc), keys.specs(rest, argc))

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

def keys.find(way: KWay, sps: List<&2, KSpec>, +argv: List<&2, String>) -> Maybe<&2, List<&2, KeyAt>>:
  match way:
    case KBySpecs{}:
      keys.specs(sps, List.length(&2, String, argv))
    case KBySet{}:
      Some{set.keys(argv)}

def keys.has.specs(sps: List<&2, KSpec>) -> Bool:
  match sps:
    case Nil{}:
      False{}
    case Con{KSpec{+flags, pos, last, step, limit}, rest}:
      Bool.or(Bool.not(has("not_key", flags)), keys.has.specs(rest))

# whether a command has keys: a spec of keys, or a function of its own
def keys.has(+way: KWay, sps: List<&2, KSpec>) -> Bool:
  match way:
    case KBySet{}:
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
      Bool.pick(R.Reply, flags, R.RArray{[R.RBulk{nth(at, argv)}, R.RArray{R.statuses(fl)}]}, R.RBulk{nth(at, argv)}) <> keys.out(flags, rest, argv)

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
