#!/bin/sh
# A diagnosis on a throwaway branch, in place of the tests: the floods of
# tests/obuf_test.py many times, and the sockets of each that stalls
# (tests/obuf_diag.py)
mkdir -p build
python3 tests/obuf_diag.py --bin build/bendkv --port "${PORT:-6380}" --dir build/diag --rounds 12
