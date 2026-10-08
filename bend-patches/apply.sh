#!/bin/sh
# apply.sh <bend checkout>: puts the twenty patches on bendlang/bend at
# 1cce499 (Bend 2.0.35), in order, on a branch of their own.
set -e
here=$(cd "$(dirname "$0")" && pwd)
git -C "$1" checkout -b bendkv-patches 1cce499
git -C "$1" apply "$here/lazy-seal.patch"
git -C "$1" apply "$here/packed-strings.patch"
git -C "$1" apply "$here/borrow-reads.patch"
git -C "$1" apply "$here/string-natives.patch"
git -C "$1" apply "$here/node-update.patch"
git -C "$1" apply "$here/huge-pages.patch"
git -C "$1" apply "$here/digit-select.patch"
git -C "$1" apply "$here/string-blobs.patch"
git -C "$1" apply "$here/mem-prefetch.patch"
git -C "$1" apply "$here/io-loops.patch"
git -C "$1" apply "$here/io-epoll.patch"
git -C "$1" apply "$here/file-raw.patch"
git -C "$1" apply "$here/chan-drain.patch"
git -C "$1" apply "$here/string-imm-index.patch"
git -C "$1" apply "$here/writer-share.patch"
git -C "$1" apply "$here/effect-pairs.patch"
git -C "$1" apply "$here/writer-demand.patch"
git -C "$1" apply "$here/string-scan.patch"
git -C "$1" apply "$here/io-cps.patch"
git -C "$1" apply "$here/value-reads.patch"
echo "patched: bun $1/bend2/main.ts <file>.bend -o <binary>"
