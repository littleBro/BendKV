#!/bin/sh
# layouts.sh FILE.c OUT/NAME [SEEDS]: builds one generated C file as
# `make build` does (clang-19 -O3), once per seed of SEEDS ("1 2 3"), each
# with its functions in a different shuffled order (lld's
# --shuffle-sections), as OUT/NAME_s1, OUT/NAME_s2, ... Two builds of the
# same C can differ by 5-10% in time from code layout alone; timing a
# variant over several layouts, against a base built the same way, and
# pooling the layouts (pair_ratios.py and memtier_specs.py fold NAME_sK
# into NAME) keeps that lottery out of the comparison.
set -e
C=$1; NAME=$2; SEEDS=${3:-"1 2 3"}
mkdir -p "$(dirname "$NAME")"
for s in $SEEDS; do
  clang-19 -std=c11 -O3 -w -ffunction-sections -fuse-ld=lld -Wl,--shuffle-sections="*=$s" \
    "$C" -lpthread -lm -o "${NAME}_s$s" &
done
wait
for s in $SEEDS; do [ -x "${NAME}_s$s" ] || { echo "no ${NAME}_s$s" >&2; exit 1; }; done
