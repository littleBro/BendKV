#!/bin/bash
# The SessionStart hook of Claude Code's cloud sessions: the toolchain that
# CONTRIBUTING.md and AGENTS.md ask for, so that a session can build, prove
# and test at once. Bend at 1cce499 with bend-patches/ applied, in
# ../bend-patched, made again when the patches change; clang 19, Lean 4.34.0
# (through elan, for make verdict) and Redis 7.0.15's tools when they are
# missing and can be installed. It exports BEND (the patched compiler) and
# BEND_CC for the session and prints what it found. Each step that fails is
# reported and the session starts all the same; a step whose result is there
# already costs nothing, so a resumed session starts at once.
set -uo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

ROOT=${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}
BENDDIR=$(cd "$ROOT/.." && pwd)/bend-patched
LOG=/tmp/bendkv-session-start.log
: > "$LOG"
notes=""

note() { notes="${notes:+$notes; }$1"; }
quiet() { "$@" >> "$LOG" 2>&1; }

apt_ready=""
apt_get() {
  if [ -z "$apt_ready" ]; then
    quiet apt-get update -q && apt_ready=yes || return 1
  fi
  DEBIAN_FRONTEND=noninteractive quiet apt-get install -y -q --no-install-recommends "$@"
}

# Bend with the patches, kept as one local commit in ../bend-patched and made
# again when bend-patches/ changes; a clone this hook did not make, or one
# with changes of its own (a patch in the making), is left as it is
stamp=$(cat "$ROOT"/bend-patches/apply.sh "$ROOT"/bend-patches/*.patch | sha256sum | cut -c1-16)
made=$(cat "$BENDDIR/.git/bendkv-patches" 2> /dev/null)
make_bend() {
  rm -rf "$BENDDIR"
  quiet git clone -q https://github.com/bendlang/bend "$BENDDIR" &&
    quiet sh "$ROOT/bend-patches/apply.sh" "$BENDDIR" &&
    quiet git -C "$BENDDIR" add -A &&
    quiet git -C "$BENDDIR" -c user.name=bendkv-hook -c user.email=hook@localhost \
      commit -q -m "bend-patches $stamp" &&
    echo "$stamp" > "$BENDDIR/.git/bendkv-patches" ||
    { rm -rf "$BENDDIR"; return 1; }
}
if [ ! -d "$BENDDIR" ]; then
  make_bend || note "the patched Bend could not be made (see $LOG)"
elif [ -z "$made" ]; then
  note "../bend-patched was not made by this hook: left as it is"
elif [ "$made" != "$stamp" ]; then
  if [ -z "$(git -C "$BENDDIR" status --porcelain 2> /dev/null)" ]; then
    make_bend || note "the patched Bend could not be made again (see $LOG)"
  else
    note "../bend-patched has changes of its own and predates bend-patches/: left as it is"
  fi
fi

# bun runs the compiler
if ! command -v bun > /dev/null && [ -x "$HOME/.bun/bin/bun" ]; then
  export PATH="$HOME/.bun/bin:$PATH"
fi
command -v bun > /dev/null || note "bun is missing: install it from https://bun.sh"

# clang 19: clang 18 builds too, with about 8% more instructions
if ! command -v clang-19 > /dev/null; then
  apt_get clang-19 || true
fi
if command -v clang-19 > /dev/null; then
  cc=clang-19
else
  cc=clang
  note "clang-19 is missing: BEND_CC=clang, and make perfcheck counts too high"
fi

# Redis 7.0.15, the reference of make test
if ! redis-server --version 2> /dev/null | grep -q 'v=7\.0\.15 '; then
  apt_get redis-server redis-tools || true
  quiet service redis-server stop || true
  redis-server --version 2> /dev/null | grep -q 'v=7\.0\.15 ' ||
    note "redis-server 7.0.15 is missing: make test compares with it"
fi

# Lean 4.34.0 for make verdict, where the compiler looks for it
lean="$HOME/.elan/toolchains/leanprover--lean4---v4.34.0/bin/lean"
if [ ! -x "$lean" ]; then
  if [ ! -x "$HOME/.elan/bin/elan" ]; then
    # elan's release v4.2.4, checked against the sha256 that CI checks
    # (.github/workflows/ci.yml), not the script of elan's master branch
    t=$(mktemp -d)
    if curl -sSfL -o "$t/elan.tar.gz" \
        https://github.com/leanprover/elan/releases/download/v4.2.4/elan-x86_64-unknown-linux-gnu.tar.gz 2>> "$LOG" &&
      echo "42b94d4244e8353142c456ec0e4ca6528fd898a6c604d4059f494e706e431f63  $t/elan.tar.gz" | quiet sha256sum -c - &&
      quiet tar xzf "$t/elan.tar.gz" -C "$t"; then
      quiet "$t/elan-init" -y --no-modify-path --default-toolchain none
    fi
    rm -rf "$t"
  fi
  quiet "$HOME/.elan/bin/elan" toolchain install leanprover/lean4:v4.34.0 ||
    note "Lean 4.34.0 could not be installed: make verdict needs it"
fi

# valgrind for make perfcheck
command -v valgrind > /dev/null || apt_get valgrind || note "valgrind is missing: make perfcheck needs it"

if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    echo "export BEND=\"bun $BENDDIR/bend2/main.ts\""
    echo "export BEND_CC=$cc"
    echo "export PATH=\"\$HOME/.elan/bin:\$HOME/.bun/bin:\$PATH\""
  } >> "$CLAUDE_ENV_FILE"
fi

echo "BendKV toolchain: BEND=\"bun $BENDDIR/bend2/main.ts\" (Bend at 1cce499 with bend-patches/), BEND_CC=$cc${notes:+. $notes}"
exit 0
