#!/bin/sh
# spin_names.sh BEND2 SRC MAP: names the spin_N loops of the C that the
# patched Bend at BEND2 (its bend2 directory) generates for SRC
# (src/server.bend), for tools/phases.py: one "spin_N = def" line each in MAP.
# A spin is a tail-recursive def compiled to a C loop, numbered in the
# order the compiler meets them; the number says nothing of the def, and
# the C has no other trace of it. A copy of BEND2 makes the compiler write
# each spin's def in a comment above it, and the numbering stays that of
# the unchanged compiler: given the plain C of SRC as a fourth argument,
# the script checks that the copy's C is that C plus the comments.
set -e
BEND2=$1; SRC=$2; MAP=$3; PLAIN=$4
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cp -r "$BEND2" "$T/bend2"
python3 - "$T/bend2/comp.ts" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "FL.spins.push({ ...seg, lines: [`${seg.lines.length < SPIN_FAR"
new = "FL.spins.push({ ...seg, lines: [`// SPIN ${name} = ${k}`, `${seg.lines.length < SPIN_FAR"
if s.count(old) != 1:
    sys.exit("spin_names.sh: comp.ts has changed; update the edit")
open(p, "w").write(s.replace(old, new))
EOF
bun "$T/bend2/main.ts" "$SRC" -o "$T/named.c" > /dev/null
grep '^// SPIN ' "$T/named.c" | sed 's|^// SPIN ||' > "$MAP"
if [ -n "$PLAIN" ]; then
  grep -v '^// SPIN ' "$T/named.c" | cmp -s - "$PLAIN" || { echo "spin_names.sh: the numbering differs from $PLAIN" >&2; exit 1; }
fi
echo "$(wc -l < "$MAP") spins named in $MAP"
