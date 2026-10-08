#!/usr/bin/env python3
# hash_buckets.py [N...]: how keys spread over the buckets of map.bend's
# trie (five hex digits: the low 20 bits of the hash) for the keys
# redis-benchmark uses ("key:%012d", N of them; 100000 and 1000000 by
# default), under String.hash (FNV-1a) and under the CRC32C-and-mix hash
# of tools/cc_variants.sh. Prints the buckets in use, the longest chain,
# the share of keys that share a bucket and the mean number of key
# comparisons for a hit.
import collections
import sys

CRC = []
for i in range(256):
    c = i
    for _ in range(8):
        c = (c >> 1) ^ (0x82F63B78 if c & 1 else 0)
    CRC.append(c)


def fnv1a(b):
    h = 2166136261
    for x in b:
        h = ((h ^ x) * 16777619) & 0xFFFFFFFF
    return h


def crc_mix(b):
    h = 2166136261
    for x in b:
        h = (h >> 8) ^ CRC[(h ^ x) & 0xFF]
    h ^= h >> 16
    h = (h * 0x7FEB352D) & 0xFFFFFFFF
    h ^= h >> 15
    return h


for n in map(int, sys.argv[1:] or ["100000", "1000000"]):
    keys = [b"key:%012d" % i for i in range(n)]
    for name, f in (("fnv1a", fnv1a), ("crc32c+mix", crc_mix)):
        c = collections.Counter(f(k) & 0xFFFFF for k in keys)
        compares = sum(m * (m + 1) / 2 for m in c.values()) / n
        shared = sum(m for m in c.values() if m > 1) / n
        print(f"{n:8d} keys {name:11s} buckets {len(c):7d}  longest {max(c.values()):2d}"
              f"  sharing {shared:.3f}  compares per hit {compares:.3f}")
