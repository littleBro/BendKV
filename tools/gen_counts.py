#!/usr/bin/env python3
# gen_counts.py: the counts that README.md states in "In numbers" (the
# block between "<!-- BEGIN gen_counts: numbers -->" and "<!-- END
# gen_counts: numbers -->"), taken from the files they count, so that a
# count is stated in one place, which the other documents link to:
#
# - the laws of proof/LAWS.bend (its lines that begin with "law ");
# - the patches to Bend: those bend-patches/apply.sh applies, each a
#   .patch file of bend-patches/ (a file there that it does not apply,
#   one it applies that is not there, or one it applies twice is an
#   error);
# - the constructors of Cmd, a parsed command, in src/redis.bend;
# - Redis 7.0.15's parameters, all of which CONFIG serves
#   (tools/data/redis-configs.json);
# - the lines of code of each file of src/ and proof/, comments and blank
#   lines left out, and among them those a generator writes (between a
#   "# BEGIN gen_" line and a "# END gen_" line); and whether the laws are
#   about a file of src/: whether proof/LAWS.bend imports it.
#
# A count of lines is written to two significant figures, and is current
# while it is within a tenth of the file's count: nearly every change to
# the code changes some file's lines, and counts exact to the line would
# make each pull request rewrite README.md and conflict with every other
# open one, for numbers no reader needs to the line. A rewrite keeps the
# counts of lines that are current, so that it changes only what drifted
# (empty the block to count every file afresh), and --check fails on one
# that is not. Every other count must be exact.
#
# The block cannot hold the two places where README.md states the laws in
# its prose, so --check reads them too: "against N laws" in its first
# paragraph, and the column of laws of the table in "What is proved",
# which has a row for each section of proof/LAWS.bend (a title over a
# line of "="), in the same order.
#
#   python3 tools/gen_counts.py          # rewrites the block in place
#   python3 tools/gen_counts.py --check  # fails if a count is out of date
import difflib, json, re, sys, pathlib

HERE = pathlib.Path(__file__).resolve().parent.parent
README = HERE / "README.md"
LAWS = HERE / "proof" / "LAWS.bend"
APPLY = HERE / "bend-patches" / "apply.sh"
REDIS = HERE / "src" / "redis.bend"
CONFIGS = HERE / "tools" / "data" / "redis-configs.json"

BEGIN, END = "<!-- BEGIN gen_counts: numbers -->\n", "<!-- END gen_counts: numbers -->\n"
# how far a count of lines may drift from the file's before --check fails
SLACK = 0.1

# The counts
# ----------

def laws():
    """the laws of proof/LAWS.bend, by section, in the file's order:
    [(title, number of laws)]"""
    lines = LAWS.read_text().splitlines()
    sections = []
    for i, line in enumerate(lines):
        if i + 1 < len(lines) and re.fullmatch(r"# =+", lines[i + 1]) and line.startswith("# "):
            sections.append([line[2:], 0])
        elif line.startswith("law "):
            if not sections:
                sys.exit(f"{LAWS.name}: a law before the first section")
            sections[-1][1] += 1
    return sections

def patches():
    """the patches apply.sh applies, in its order"""
    applied = re.findall(r'^git -C "\$1" apply "\$here/([^"/]+\.patch)"$', APPLY.read_text(), re.M)
    files = {p.name for p in APPLY.parent.glob("*.patch")}
    errs = [f"bend-patches/apply.sh does not apply {f}" for f in sorted(files - set(applied))]
    errs += [f"bend-patches/apply.sh applies {f}, which bend-patches/ does not hold"
             for f in sorted(set(applied) - files)]
    errs += [f"bend-patches/apply.sh applies {f} twice" for f in sorted(set(applied)) if applied.count(f) > 1]
    if errs:
        sys.exit("\n".join(errs))
    return applied

def constructors(src, name):
    """the constructors of the datatype name"""
    m = re.search(r"(?m)^type %s is Data:\n((?:  [A-Z]\w*\{.*\}\n)+)" % name, src)
    if not m:
        sys.exit(f"{REDIS.name}: no type {name}")
    return re.findall(r"(?m)^  ([A-Z]\w*)\{", m.group(1))

def lines_of(path):
    """a file's lines of code, comments and blank lines left out, and
    how many of them a generator writes"""
    code = gen = 0
    inside = False
    for line in path.read_text().splitlines():
        s = line.strip()
        if s.startswith("# BEGIN gen_"):
            inside = True
        elif s.startswith("# END gen_"):
            inside = False
        elif s and not s.startswith("#"):
            code += 1
            gen += inside
    return code, gen

def imported():
    """the files of src/ that proof/LAWS.bend imports, in its order"""
    return re.findall(r"(?m)^import \.\./src/([\w.]+\.bend) as ", LAWS.read_text())

# The block
# ---------

def approx(n):
    """n to two significant figures"""
    if n < 100:
        return n
    q = 10 ** (len(str(n)) - 2)
    return (n + q // 2) // q * q

def show(n):
    return f"{n:,}" if n else ""

def close(stated, n):
    """a count of lines stated in the block that is still current"""
    return abs(stated - n) <= SLACK * n

def file_rows():
    """[(label, lines, generated, the laws import it)]: the files of src/,
    those the laws import first, then those of proof/, and their sums"""
    laws_import = imported()
    srcs = sorted(p.name for p in (HERE / "src").glob("*.bend"))
    if any(f not in srcs for f in laws_import):
        sys.exit(f"{LAWS.name} imports a file src/ does not hold")
    order = laws_import + [f for f in srcs if f not in laws_import]
    rows, sums = [], {True: [0, 0], False: [0, 0], "proof": [0, 0]}
    for f in order:
        c, g = lines_of(HERE / "src" / f)
        rows.append((f"`src/{f}`", c, g, "yes" if f in laws_import else "no"))
        sums[f in laws_import][0] += c
        sums[f in laws_import][1] += g
    for f in ("LAWS.bend", "SPEC.bend", "PROOF.bend"):
        c, g = lines_of(HERE / "proof" / f)
        rows.append((f"`proof/{f}`", c, g, ""))
        sums["proof"][0] += c
        sums["proof"][1] += g
    n = len(laws_import)
    rows.append((f"`src/`, the {n} files the laws import", *sums[True], ""))
    rows.append((f"`src/`, the {len(srcs) - n} others", *sums[False], ""))
    rows.append(("`proof/`", *sums["proof"], ""))
    return rows

def block(kept):
    """the block; a count of lines in kept (label -> (lines, generated),
    as the block states them) is written as stated while it is current"""
    sections = laws()
    cmd = constructors(REDIS.read_text(), "Cmd")
    out = ["| what | how many | counted in |",
           "|---|---:|---|",
           f"| laws | {sum(n for _, n in sections)} | `proof/LAWS.bend` (by group: [What is proved](#what-is-proved)) |",
           f"| patches to the Bend compiler | {len(patches())} | `bend-patches/apply.sh` |",
           f"| constructors of `Cmd`, a parsed command | {len(cmd)} | `src/redis.bend` |",
           f"| Redis 7.0.15's parameters, all of which CONFIG serves | {len(json.loads(CONFIGS.read_text()))} | `tools/data/redis-configs.json` |",
           "",
           "| file | lines of code | of them written by a generator | the laws import it |",
           "|---|---:|---:|---|"]
    for label, c, g, laws_import in file_rows():
        sc, sg = kept.get(label, (None, None))
        if sc is None or not close(sc, c) or not close(sg, g):
            sc, sg = approx(c), approx(g)
        out.append(f"| {label} | {show(sc)} | {show(sg)} | {laws_import} |")
    return "\n".join(out) + "\n"

def stated(text):
    """the counts of lines the block states: label -> (lines, generated)"""
    out = {}
    for m in re.finditer(r"(?m)^\| (`[^|]*) \| ([\d,]*) \| ([\d,]*) \| [^|]* \|$", text):
        num = lambda s: int(s.replace(",", "")) if s else 0
        out[m.group(1)] = (num(m.group(2)), num(m.group(3)))
    return out

# The prose
# ---------

def prose(text):
    """what README.md says of the laws outside the block, against
    proof/LAWS.bend: errors"""
    errs = []
    sections = laws()
    total = sum(n for _, n in sections)
    # its first paragraph: "... are proved against N laws"
    m = re.search(r"are proved\s+against (\d+) laws", text)
    if not m:
        errs.append("README.md: no \"are proved against N laws\" in its first paragraph")
    elif int(m.group(1)) != total:
        errs.append(f"README.md says \"against {m.group(1)} laws\"; {LAWS.name} has {total}")
    # the table of What is proved: "| group | laws | what they say |", then
    # a row for each section, "| <group> | <laws> | ... |"
    m = re.search(r"(?m)^\| group \| laws \| what they say \|\n\|[-|:]+\|\n((?:\|.*\n)+)", text)
    if not m:
        errs.append("README.md: no table of laws (| group | laws | what they say |)")
    else:
        got = [int(n) for n in re.findall(r"(?m)^\| [^|]+ \| (\d+) \|", m.group(1))]
        want = [n for _, n in sections]
        if got != want:
            errs.append(f"README.md's table of laws has {got} laws by group; the sections of {LAWS.name} "
                        f"hold {want} ({', '.join(t for t, _ in sections)})")
    return errs

def main(check):
    text = README.read_text()
    if text.count(BEGIN) != 1 or text.count(END) != 1 or text.index(BEGIN) > text.index(END):
        sys.exit("README.md: no block gen_counts: numbers")
    a, b = text.index(BEGIN) + len(BEGIN), text.index(END)
    old = text[a:b]
    new = block(stated(old))
    if not check:
        README.write_text(text[:a] + new + text[b:])
        errs = prose(text)
        if errs:
            sys.exit("\n".join(errs))
        return
    errs = prose(text)
    if new != old:
        diff = difflib.unified_diff(old.splitlines(), new.splitlines(), "README.md", "counted", lineterm="", n=0)
        errs.append("README.md's counts are out of date: run tools/gen_counts.py\n"
                    + "\n".join(l for l in diff if not l.startswith("@@")))
    if errs:
        sys.exit("\n".join(errs))

if __name__ == "__main__":
    main("--check" in sys.argv)
