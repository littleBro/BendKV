#!/usr/bin/env python3
"""phases.py: where a request's instructions and time go, by phase of the
request path (reading, RESP parsing, command parsing, hashes and hints,
execution, replies, the actor, the event loop, the kernel).

  phases.py cg DUMP [--spins MAP] [--top N] [--n REQS]
      self cost per function and per phase of a callgrind dump of
      tools/callgrind_req.sh (REQS requests, 20000): instructions,
      last-level and L1 data read misses per request
  phases.py callers DUMP REGEX [--spins MAP] [--n REQS]
      who calls the functions matching REGEX: calls and inclusive
      instructions per request
  phases.py sprof OUT EXE [--spins MAP] [--redis] [--thread N]
      the samples of tools/sprof_run.sh by phase (EXE as for
      tools/sprof_report.py; - for redis-server, with --redis)

MAP (tools/spin_names.sh) names the generated C's spin_N loops after the
Bend defs they run; without it they keep their numbers and go to "other".
A WL segment's continuations (_K123, _C123) and callgrind's recursion
marks ('2) count as their def. The self costs of a dump sum to ~3% more
than its total: callgrind counts some jumps between segments twice.
"""
import collections, re, subprocess, sys

# the phases of a BendKV request; the first rule that matches a function wins
KV = [
    ("0 kernel: send, recv, epoll", r"^(send|recv|epoll_wait|write|read|writev|sendmsg)$"),
    ("1 RESP parse", r"^resp:(num|bulk_at|bulk\.|bulks|array|one|cut|batch|words|line|digit)"
     r"|^str_(slice|mov|chunk|drop_n|vtail|code_at_far|find_far|slice_far)$|memchr"
     r"|^WL_FID_RESP_(ONE|BATCH_GO|PARSE|WORDS)|^List\.reverse \[spin_16\]|^WL_FID_COUNT_UPTO$|^glue|^cat "),
    ("2 command parse", r"^WL_FID_REDIS_PARSE|^redis:(cmd_id|parse_|e_)|^spare_free$|^ctr_take$"
     r"|^term_sink$|^WL_FID_BATCH_CMDS_OF$|^Char\.|^String\.is_empty"),
    ("3 hash, hints", r"^str_hash$|^WL_FID_BATCH_REQ_HASHES$|^batch:|^map:(touch|ttouch|tetouch|btouch|hash|hex|shr4)|^slot_keep$"),
    ("4 execute", r"^WL_FID_REDIS_(EXEC|INCR|SETNX|APPEND)|^redis:(exec|int_|incr|r_get|r_int|i_get|append|strlen|got)"
     r"|^map:|^WL_FID_MAP_|^str_eq$|memcmp|^term_drop$|^nat_show_str$|^List\.reverse \[spin_90\]"
     r"|^Bool\.|^Nat\.|^Cmp\.|^Maybe\.|^U32\."),
    ("5 reply encode", r"^resp:(bulk_into|item_into|int_into)|^WL_FID_RESP_(ENCODE|ITEMS)|^str_append|^str_copy$|^str_scan$|memmove|memcpy"),
    ("6 actor, channels", r"^chan_|^WL_FID_(CHAN_|DB_LOOP|DB_SERVE|DB_GROUP|RUN_|ANS_OF|BATCH_REQ$|BATCH_EXEC_BATCH|GROUP)"),
    ("7 event loop (user)", r"^io_|^tcp_|^WL_FID_(TCP_|CONN_|PUT_OUT|SENT_OK|AFTER|IO_|CLO_APPLY|ENTER|EXIT|REPLY_TO|SOCKET)"
     r"|^corpus_|^span_|^posts|^err_|^work_|^_init$|^pthread_cond"),
]
# the same phases for redis-server 7 (its symbols as sprof resolves them)
REDIS = [
    ("0 kernel: send, recv, epoll", r"^(send|recv|epoll_wait|write|read|writev|sendmsg)$"),
    ("1 RESP parse", r"^(processMultibulkBuffer|processInputBuffer|readQueryFromClient|__strchr|string2ll|sdsnewlen|sdsMakeRoomFor|createStringObject|sdsrange|__memchr)"),
    ("2 command parse", r"^(processCommand|lookupCommand|ACL|aclCommand|__strcasecmp|siphash_nocase|commandProcessed|call$|moduleCallCommandFilters|getObjectTypeName)"),
    ("4 execute", r"^(dictFind|lookupKey|dictSdsKeyCompare|siphash$|dictSdsHash|getCommand|getGenericCommand|setKey|setGenericCommand|setCommand"
     r"|dbAdd|dbOverwrite|incrDecrCommand|keyIsExpired|getExpire|tryObjectEncoding|__memcmp|dictAdd|dictReplace|moduleNotify"
     r"|notifyKeyspaceEvent|signalModifiedKey|incrCommand|getLongLongFromObject|string2l|ll2string|alsoPropagate|touchWatchedKey)"),
    ("5 reply encode", r"^(_addReply|addReply|prepareClientToWrite|clientHasPendingReplies|__memmove|__memcpy|writeToClient|_writeToClient|handleClientsWithPendingWrites)"),
    ("8 memory", r"^(malloc|free|zmalloc|zfree|decrRefCount|malloc_usable_size|createEmbeddedStringObject|resetClient|freeClientArgv|sdsfree|zrealloc|realloc|createObject)"),
]


def rules(redis):
    return [(n, re.compile(p)) for n, p in (REDIS if redis else KV)]


def phase(rs, f):
    for n, p in rs:
        if p.search(f):
            return n
    return "9 other"


def spins(path):
    return dict(l.strip().split(" = ")[:2] for l in open(path)) if path else {}


def fold(f, sp):
    f = re.sub(r"'\d+$", "", f)
    if f in sp:
        return sp[f] + " [" + f + "]"
    m = re.match(r"(WL_FID_.*?)_[KC]\d+$", f)
    return m.group(1) if m else f


def cg_read(dump, sp):
    """self costs by folded function, and call edges with inclusive costs"""
    names, self_cost = {}, collections.defaultdict(lambda: collections.Counter())
    edges = collections.defaultdict(lambda: [0, 0])
    events, fn, cfn, calls, take = [], None, None, 0, False

    def name_of(tok):
        m = re.match(r"\((\d+)\)(?: (.*))?", tok)
        if not m:
            return tok
        if m.group(2) is not None:
            names[m.group(1)] = m.group(2)
        return names[m.group(1)]
    for line in open(dump):
        line = line.rstrip("\n")
        if line.startswith("events:"):
            events = line.split()[1:]
        elif line.startswith("fn="):
            fn = name_of(line[3:])
        elif line.startswith("cfn="):
            cfn = name_of(line[4:])
        elif line.startswith("calls="):
            calls, take = int(line[6:].split()[0]), True
        elif line and (line[0].isdigit() or line[0] in "+-*"):
            costs = [int(x) for x in line.split()[1:]]
            if take:
                e = edges[(fold(fn, sp), fold(cfn, sp))]
                e[0] += calls
                e[1] += costs[0] if costs else 0
                take = False
            else:
                c = self_cost[fold(fn, sp)]
                for ev, v in zip(events, costs):
                    c[ev] += v
    return self_cost, edges


# runtime helpers that serve every phase: in a dump their cost goes to the
# phases of their callers, in proportion to what each call costs
SHARED = re.compile(r"^(str_|term_|slot_keep$|spare_free$|ctr_take$|nat_|heap_|__mem)")


def cmd_cg(dump, sp, top, n):
    self_cost, edges = cg_read(dump, sp)
    rs = rules(False)
    total = sum(c["Ir"] for c in self_cost.values())
    print(f"{total / n:.0f} instructions per request (sum of self costs)")
    callers = collections.defaultdict(collections.Counter)
    for (a, b), (_, ir) in edges.items():
        if a != b and not SHARED.search(a):
            callers[b][phase(rs, a)] += ir
    ph = collections.defaultdict(collections.Counter)
    for f, c in self_cost.items():
        by = callers.get(f) if SHARED.search(f) else None
        if not by:
            ph[phase(rs, f)].update(c)
            continue
        whole = sum(by.values())
        for p, w in by.items():
            ph[p].update({k: v * w / whole for k, v in c.items()})
    for p in sorted(ph):
        c = ph[p]
        print(f"  {p:30s} {c['Ir'] / n:6.0f} {100 * c['Ir'] / total:5.1f}%"
              f"  LL misses {c['DLmr'] / n:4.2f}  L1 misses {c['D1mr'] / n:5.2f}")
    print("functions:")
    for f, c in sorted(self_cost.items(), key=lambda kv: -kv[1]["Ir"])[:top]:
        print(f"  {c['Ir'] / n:7.1f} {100 * c['Ir'] / total:5.1f}%  LL {c['DLmr'] / n:4.2f}"
              f"  L1 {c['D1mr'] / n:5.2f}  {f}  ({phase(rs, f)[2:]})")


def cmd_callers(dump, rx, sp, n):
    _, edges = cg_read(dump, sp)
    p = re.compile(rx)
    rows = [(k, v) for k, v in edges.items() if p.search(k[1]) and k[0] != k[1]]
    for (a, b), (k, ir) in sorted(rows, key=lambda kv: -kv[1][1])[:20]:
        print(f"  {ir / n:8.1f} instructions  {k / n:6.2f} calls per request  {a} -> {b}")


def cmd_sprof(out, exe, sp, redis, thread):
    here = __file__.rsplit("/", 1)[0]
    args = [sys.executable, here + "/sprof_report.py", out, "100000"]
    if exe != "-":
        args.append(exe)
    if thread is not None:
        args += ["--thread", thread]
    rep = subprocess.run(args, capture_output=True, text=True).stdout.splitlines()
    total = int(rep[0].split()[0])
    rs = rules(redis)
    acc, top = collections.Counter(), collections.defaultdict(list)
    for l in rep[1:]:
        m = re.match(r"\s*[\d.]+%\s+(\d+)\s+(\S+)", l)
        if m:
            k, f = int(m.group(1)), fold(m.group(2), sp)
            p = phase(rs, f)
            acc[p] += k
            top[p].append((k, f))
    print(f"{total} samples")
    for p in sorted(acc):
        fs = ", ".join(f"{f} {100 * k / total:.1f}" for k, f in sorted(top[p], reverse=True)[:4])
        print(f"  {p:30s} {100 * acc[p] / total:5.1f}%  ({fs})")


def main(a):
    def opt(name, default=None, flag=False):
        if name in a:
            i = a.index(name)
            a.pop(i)
            return True if flag else a.pop(i)
        return False if flag else default
    sp = spins(opt("--spins"))
    n = int(opt("--n", "20000"))
    top = int(opt("--top", "40"))
    redis = opt("--redis", flag=True)
    thread = opt("--thread")
    if len(a) >= 2 and a[0] == "cg":
        cmd_cg(a[1], sp, top, n)
    elif len(a) >= 3 and a[0] == "callers":
        cmd_callers(a[1], a[2], sp, n)
    elif len(a) >= 3 and a[0] == "sprof":
        cmd_sprof(a[1], a[2], sp, redis, thread)
    else:
        sys.exit(__doc__)


main(sys.argv[1:])
