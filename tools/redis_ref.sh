#!/bin/sh
# redis_ref.sh [DIR]: Redis 7.2.16, the reference the tests compare BendKV
# with, built from its tarball into DIR (default: REDIS_REF_DIR, or
# ~/redis-7.2.16) unless a build of that version is there already. Prints
# the directory that holds its redis-server, redis-cli and redis-benchmark,
# to put first on the PATH:
#
#     PATH="$(sh tools/redis_ref.sh):$PATH" make test
#
# The tarball's sha256 is the one redis-hashes lists, checked before the
# tarball is unpacked. `make -C src` builds the server alone, without TLS,
# as Redis's own `make` does by default. 7.2.16 is BSD-3 (NOTICE).
set -e
VER=7.2.16
SHA=960a8ec15e34ff40e57ff16837b26b33bd81f2da6d24497bb63de532a323a18e
DIR=${1:-${REDIS_REF_DIR:-$HOME/redis-$VER}}
if [ -x "$DIR/src/redis-server" ] && "$DIR/src/redis-server" --version | grep -q "v=$VER "; then
  echo "$DIR/src"
  exit 0
fi
tmp=$(mktemp -d)
curl -fsSL -o "$tmp/redis-$VER.tar.gz" "https://download.redis.io/releases/redis-$VER.tar.gz"
echo "$SHA  $tmp/redis-$VER.tar.gz" | sha256sum -c - >&2
mkdir -p "$DIR"
tar -xzf "$tmp/redis-$VER.tar.gz" -C "$DIR" --strip-components=1
rm -rf "${tmp:?}"
if ! make -C "$DIR/src" -j"$(nproc)" > "$DIR/build.log" 2>&1; then
  tail -n 20 "$DIR/build.log" >&2
  exit 1
fi
"$DIR/src/redis-server" --version >&2
echo "$DIR/src"
