#!/usr/bin/env python3
"""Adds allocation and refcount counters to a C file emitted by `bend x.bend
-o x.c`: SIGUSR1 prints them to stderr, SIGUSR2 zeroes them, and with
CNT_ATEXIT set the program prints them when it exits.

    count_allocs.py x.c x_counted.c && clang -std=c11 -O3 x_counted.c -lpthread -lm
"""
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
decl = r'''
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
static unsigned long long CNT_alloc[64], CNT_free[64], CNT_wrap, CNT_bump, CNT_drop, CNT_dec, CNT_take_shr;
static void cnt_dump(int sig) {
  (void)sig;
  unsigned long long a = 0, f = 0;
  for (int i = 0; i < 64; i++) { a += CNT_alloc[i]; f += CNT_free[i]; }
  fprintf(stderr, "CNT alloc=%llu (c0=%llu c1=%llu c2=%llu c3=%llu c4+=%llu) free=%llu wrap=%llu bump=%llu drop_calls=%llu rc_dec=%llu take_shared=%llu\n",
    a, CNT_alloc[0], CNT_alloc[1], CNT_alloc[2], CNT_alloc[3], a - CNT_alloc[0] - CNT_alloc[1] - CNT_alloc[2] - CNT_alloc[3], f, CNT_wrap, CNT_bump, CNT_drop, CNT_dec, CNT_take_shr);
}
static void cnt_reset(int sig) {
  (void)sig;
  for (int i = 0; i < 64; i++) { CNT_alloc[i] = 0; CNT_free[i] = 0; }
  CNT_wrap = CNT_bump = CNT_drop = CNT_dec = CNT_take_shr = 0;
}
__attribute__((constructor)) static void cnt_init(void) { signal(SIGUSR1, cnt_dump); signal(SIGUSR2, cnt_reset); }
__attribute__((destructor)) static void cnt_fini(void) { if (getenv("CNT_ATEXIT")) cnt_dump(0); }
'''
anchor = "typedef u64 Term;\n"
assert anchor in s
s = s.replace(anchor, anchor + decl, 1)
pairs = [
 ("INLINE u64 heap_alloc(Env e, u32 cls) {\n", "INLINE u64 heap_alloc(Env e, u32 cls) {\n  CNT_alloc[cls & 63]++;\n"),
 ("INLINE void heap_free(Env e, u32 cls, u64 loc) {\n", "INLINE void heap_free(Env e, u32 cls, u64 loc) {\n  CNT_free[cls & 63]++;\n"),
 ("OUTLINE Term rfc_wrap(Env e, Term t, u32 cnt) {\n", "OUTLINE Term rfc_wrap(Env e, Term t, u32 cnt) {\n  CNT_wrap++;\n"),
 ("INLINE void rfc_bump(Env e, u64 r, u32 k) {\n", "INLINE void rfc_bump(Env e, u64 r, u32 k) {\n  CNT_bump++;\n"),
 ("FAR void term_drop(Env e, Term t) {\n", "FAR void term_drop(Env e, Term t) {\n  CNT_drop++;\n"),
 ("      if ((a32_sub_rel(p, 1) & RFC_CNT) != 1) {\n", "      CNT_dec++;\n      if ((a32_sub_rel(p, 1) & RFC_CNT) != 1) {\n"),
 ("  u64 src = term_peek(H, t);\n  for (u32 j = 0; j < n; j += 1) {\n    out[j] = H[src + j];\n  }\n", "  u64 src = term_peek(H, t);\n  CNT_take_shr++;\n  for (u32 j = 0; j < n; j += 1) {\n    out[j] = H[src + j];\n  }\n"),
]
for a, b in pairs:
    assert a in s, a
    s = s.replace(a, b, 1)
open(dst, 'w').write(s)
print("ok")
