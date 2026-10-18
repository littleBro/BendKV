#!/usr/bin/env python3
"""The float library (src/float.bend) against glibc: random texts of
numbers, decimal and hex, with up to 800 digits, exact ties between two
doubles or two long doubles, numbers near each end of both ranges, and
forms strtod reads only in part (inf, infinity, nan, a sign, a point, an
exponent with no digit), each read as Redis reads a double (string2d) and
written as "%.17g" writes it, read as a long double (string2ld) and
written for people ("%.17Lf", the zeros that end its fraction taken out),
and read as SORT reads a score (strtod, then errno and the end it
reached); sums and products of doubles and sums of long doubles; and
doubles by their bits (random ones, integers and their neighbours, short
decimals, subnormals, every exponent's edges, NaNs, infinities and
zeros), each written as Redis 7.2 writes a double (d2string: an integer,
or fpconv_dtoa's Grisu2) and as its AOF rewrite does (fpconv_dtoa). A
Bend program (build/float_check.bend) answers each line, a C program
with glibc's strtod, strtold and printf, and Redis 7.2.16's fpconv_dtoa
(deps/redis/deps/fpconv), answers it as Redis does on x86-64
(tests/float_ref.c), and the answers must be the same bytes.

    python3 tests/float_test.py --bend "bend" --cc clang-19 --seed 1 --n 1500
"""
import argparse
import math
import os
import random
import struct
import subprocess
import sys
from decimal import Decimal, getcontext
from fractions import Fraction

getcontext().prec = 2000
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
rnd = random.Random(1)

def rdigits(k):
    return ''.join(rnd.choice('0123456789') for _ in range(k))

def rdec(emax=350):
    s = rnd.choice(['', '', '-', '+'])
    n = rnd.choice([1, 1, 2, 3, 5, 8, 12, 15, 16, 17, 18, 19, 20, 25, 40, 80])
    d = rdigits(n)
    p = rnd.randint(0, n)
    body = d[:p] + ('.' + d[p:] if p < n or rnd.random() < 0.2 else '')
    if body.startswith('.') and len(body) == 1: body = '0'
    if rnd.random() < 0.6:
        e = rnd.randint(-emax, emax)
        body += rnd.choice('eE') + (rnd.choice(['', '+']) if e >= 0 else '') + str(e)
    return s + body

def rhex(emax=1100):
    s = rnd.choice(['', '-'])
    n = rnd.choice([1, 2, 6, 13, 14, 16, 20])
    h = ''.join(rnd.choice('0123456789abcdefABCDEF') for _ in range(n))
    p = rnd.randint(0, n)
    body = h[:p] + ('.' + h[p:] if p < n else '')
    if body.startswith('.') and len(body) == 1: body = '0'
    out = s + rnd.choice(['0x', '0X']) + body
    if rnd.random() < 0.8:
        out += rnd.choice('pP') + str(rnd.randint(-emax, emax))
    return out

def rdouble_bits():
    b = rnd.getrandbits(64)
    return struct.unpack('<d', struct.pack('<Q', b))[0]

def exact_dec(fr):
    # exact decimal expansion of a dyadic rational
    num, den = fr.numerator, fr.denominator
    sign = '-' if num < 0 else ''
    num = abs(num)
    k = 0
    while den % 2 == 0:
        den //= 2; k += 1
    assert den == 1
    # num / 2^k = num * 5^k / 10^k
    v = num * 5 ** k
    s = str(v)
    if k == 0: return sign + s
    s = s.rjust(k + 1, '0')
    return sign + s[:-k] + '.' + s[-k:]

def rmid():
    # an exact tie between two neighbouring doubles (or one slightly off)
    while True:
        d = rdouble_bits()
        if d != d or d in (float('inf'), float('-inf')): continue
        break
    a = Fraction(d)
    b = Fraction(math.nextafter(d, math.inf))
    m = (a + b) / 2
    r = rnd.random()
    if r < 0.3: m += Fraction(1, 2 ** 1200)
    elif r < 0.6: m -= Fraction(1, 2 ** 1200)
    s = exact_dec(m)
    if len(s) > 1500: return repr(d)
    return s

def rld_mid():
    # a tie between two neighbouring long doubles near a random exponent
    e = rnd.randint(-16400, 16380)
    m = rnd.getrandbits(63) | (1 << 63)
    a = Fraction(m) * Fraction(2) ** (e - 63)
    b = Fraction(m + 1) * Fraction(2) ** (e - 63)
    mid = (a + b) / 2
    # print with 25 significant digits: close to a tie, not exactly it
    d = Decimal(mid.numerator) / Decimal(mid.denominator)
    return format(d, '.25e')

special = ["inf", "INF", "Infinity", "-iNfInItY", "+inf", "infinit", "infx", "nan", "NaN", "-nan", "nan(123)",
  "1e", "1e+", "1e-", "1E5", "0x", "0x.", "0x.p1", "0x1p", "0x1p+", "0X1P-3", ".", "-", "+", "+.5", "-.5e-3", "5.", "5.e3",
  ".e1", "e1", "1_0", "0", "-0", "+0", "0.0", "-0.0", "00000.000001", "1" + "0" * 400, "0." + "0" * 400 + "1",
  "1" * 800, "2.2250738585072011e-308", "2.2250738585072014e-308", "4.9406564584124654e-324",
  "2.4703282292062327e-324", "2.4703282292062328e-324", "1.7976931348623157e308", "1.7976931348623158e308",
  "1.7976931348623159e308", "1e309", "-1e309", "1e-324", "3e-324", "0x1p-1074", "0x1p-1075", "0x1.8p-1075",
  "0x1.fffffffffffff8p1023", "0x1.fffffffffffff7ffp1023", "1e4932", "1.18973149535723176502e4932", "1.2e4932",
  "3.6e-4951", "1.8e-4951", "1e-4951", "1e-4952", "10.5", "1.5", "0.1", "0.2", "0.3", "-1.1", "9007199254740993",
  "9007199254740992", "18446744073709551616", "1e1000000000000", "1e-1000000000000", "0e1000000000000",
  "1e0000000000000000005", "00", "0x00", "0x0p0", "-0x0p0", " 3", "   -1e2", "3 ", " ", "", "\x0b7",
  "1e-310", "2.2250738585072009e-308", "-4e-320", "0x1.8p-1074", "0x1p-1023", "0x1.0000000000001p-1022",
  "007", "-007", "12345678901234", "-99999999999999", "123456789012345", "-123456789012345", "-x"]



# doubles by their bits, for d2string and fpconv_dtoa: random ones,
# integers (to past 2^62, where d2string stops writing integers) and their
# neighbours, short decimals (Grisu2's short digits and each of its
# layouts), subnormals and each exponent's edges
def rbits():
    r = rnd.random()
    if r < 0.4:
        return rnd.getrandbits(64)
    if r < 0.6:
        v = rnd.randint(-2 ** rnd.randint(1, 64), 2 ** rnd.randint(1, 64))
        b = struct.unpack('<Q', struct.pack('<d', float(v)))[0]
        return (b + rnd.choice([0, 0, 0, 1, -1])) % 2 ** 64
    if r < 0.85:
        k = rnd.randint(1, 17)
        v = float(str(rnd.randint(1, 10 ** k)) + 'e' + str(rnd.randint(-30, 30) if rnd.random() < 0.7 else rnd.randint(-340, 300)))
        b = struct.unpack('<Q', struct.pack('<d', v))[0]
        return b | (1 << 63) if rnd.random() < 0.5 else b
    b = rnd.choice([rnd.getrandbits(52), (rnd.randint(0, 2047) << 52) | rnd.choice([0, 1, 2 ** 52 - 1, rnd.getrandbits(52)])])
    return b | (1 << 63) if rnd.random() < 0.5 else b

def dbits(v):
    return struct.unpack('<Q', struct.pack('<d', v))[0]

special_bits = [0, 1 << 63, 0x7FF0000000000000, 0xFFF0000000000000, 0x7FF8000000000000, 0xFFF8000000000000,
  0x7FF0000000000001, 0x7FFFFFFFFFFFFFFF, 1, 2, 0x000FFFFFFFFFFFFF, 0x0010000000000000, 0x7FEFFFFFFFFFFFFF] + [
  dbits(v) for v in [1.0, -1.0, 0.1, 0.5, 0.3, 1.5, 123.456, 1e7, 1e8, 1e15, 1e16, 1e17, 1e18, 1e21, 1e22, 1e23,
  2.0 ** 62, -2.0 ** 62, 2.0 ** 62 + 1024, -(2.0 ** 62 + 1024), 2.0 ** 63, 2.0 ** 53, 2.0 ** 53 + 2, 2.0 ** 47,
  2.0 ** 47 + 0.5, 2.0 ** 52 + 0.5, 4611686018427387903.0, 9007199254740993.0, 12345678.0, 123456789.0,
  1234567.5, 0.000001, 0.0000001, 0.00001234, 1e-5, 1e-6, 1e-7, 1e-300, 5e-324, 1.7976931348623157e308,
  2.2250738585072014e-308, 3.14159, -2.5e-8, 100.0, 1000.0, 1e9, 1e10, 9.999999999999999e22, 0.1 + 0.2]]


def inputs(n):
    global N
    N = n
    lines = []
    for s in special:
        lines.append(('p', s, ''))
    kinds = ['dec', 'dec', 'hex', 'mid', 'bits', 'lddec', 'ldmid', 'ldhex']
    for _ in range(N):
        k = rnd.choice(kinds)
        if k == 'dec': x = rdec()
        elif k == 'hex': x = rhex()
        elif k == 'mid': x = rmid()
        elif k == 'bits':
            d = rdouble_bits()
            x = repr(d) if d == d else 'nan'
        elif k == 'lddec': x = rdec(5000)
        elif k == 'ldmid': x = rld_mid()
        else: x = rhex(16500)
        lines.append(('p', x, ''))
        if rnd.random() < 0.5:
            op = rnd.choice(['ad', 'md', 'al'])
            if op == 'al':
                a = rnd.choice([rdec(40), rdec(5000), rld_mid(), rdec(3)])
                b = rnd.choice([rdec(40), rdec(5000), rld_mid(), rdec(3), '-' + a.lstrip('+-') if not a.startswith('-') else a[1:]])
            else:
                a = rnd.choice([rdec(), repr(rdouble_bits()), rmid(), rdec(5)])
                b = rnd.choice([rdec(), repr(rdouble_bits()), rmid(), rdec(5), ('-' + a.lstrip('+-')) if not a.startswith('-') else a[1:]])
            if 'nan' in a: a = '1'
            if 'nan' in b: b = '2'
            lines.append((op, a, b))

    return lines

def esc(s):
    out = []
    for ch in s:
        o = ord(ch)
        if ch == '\\': out.append('\\\\')
        elif ch == '"': out.append('\\"')
        elif ch == '\n': out.append('\\n')
        elif ch == '\t': out.append('\\t')
        elif ch == '\r': out.append('\\r')
        elif o == 0: out.append('\\0')
        elif o < 32 or o > 126: out.append('\\u{%X}' % o)
        else: out.append(ch)
    return ''.join(out)


BEND = """import Base
import ../src/float.bend as F

type T is Data:
  T{op: String, a: String, b: String}

type W is Data:
  W{hi: Nat, lo: Nat}

def show.d(m: Maybe<&2, F.F64>) -> String:
  match m:
    case None{}:
      "ERR"
    case Some{d}:
      F.f64.show_g(d)

def show.ld(m: Maybe<&2, F.Fl>) -> String:
  match m:
    case None{}:
      "ERR"
    case Some{x}:
      F.fl.show_human(x)

def d2(m: Maybe<&2, F.F64>, n: Maybe<&2, F.F64>, +mul: Bool) -> String:
  match m n:
    case Some{x} Some{y}:
      match mul:
        case True{}:
          F.fl.show_g(F.fl.mul(F.fmt.d(), F.f64.to(x), F.f64.to(y)))
        case False{}:
          F.fl.show_g(F.fl.add(F.fmt.d(), F.f64.to(x), F.f64.to(y)))
    case _ _:
      "ERR"

def l2(m: Maybe<&2, F.Fl>, n: Maybe<&2, F.Fl>) -> String:
  match m n:
    case Some{x} Some{y}:
      F.fl.show_human(F.fl.add(F.fmt.ld(), x, y))
    case _ _:
      "ERR"

def one(t: T) -> String:
  match t:
    case T{+op, +a, +b}:
      Bool.pick(String, String.eq(op, "p"), show.d(F.f64.parse(a)) ++ " | " ++ show.ld(F.ld.parse(a)) ++ " | " ++ show.d(F.f64.parse_sort(a)),
        Bool.pick(String, String.eq(op, "al"), l2(F.ld.parse(a), F.ld.parse(b)), d2(F.f64.parse(a), F.f64.parse(b), String.eq(op, "md"))))

def run(xs: List<&2, T>) -> IO(Unit):
  match xs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{t, rest}:
      do IO<Unit>:
        Unit <- IO.print(one(t) ++ "\\n")
        run(rest)

def wone(w: W) -> String:
  match w:
    case W{+hi, +lo}:
      F.f64.show(F.F64{hi, lo}) ++ " | " ++ F.f64.dtoa(F.F64{hi, lo})

def wrun(xs: List<&2, W>) -> IO(Unit):
  match xs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{w, rest}:
      do IO<Unit>:
        Unit <- IO.print(wone(w) ++ "\\n")
        wrun(rest)

def main() -> IO(Unit):
  do IO<Unit>:
    Unit <- run([@ITEMS@])
    wrun([@WITEMS@])
"""


def main():
    global rnd
    ap = argparse.ArgumentParser()
    ap.add_argument("--bend", default="bend")
    ap.add_argument("--cc", default="cc")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--n", type=int, default=1500)
    a = ap.parse_args()
    rnd = random.Random(a.seed)
    lines = inputs(a.n)
    ws = special_bits + [rbits() for _ in range(a.n)]
    os.makedirs(os.path.join(ROOT, "build"), exist_ok=True)
    txt = os.path.join(ROOT, "build", "float_in.txt")
    with open(txt, "w") as f:
        for op, x, y in lines:
            f.write(op + "\t" + x + ("\t" + y if op != "p" else "") + "\n")
        for b in ws:
            f.write("w\t%016x\n" % b)
    items = ['T{"%s", "%s", "%s"}' % (op, esc(x), esc(y)) for op, x, y in lines]
    witems = ['W{%dn, %dn}' % (b >> 32, b & 0xFFFFFFFF) for b in ws]
    src = BEND.replace("@ITEMS@", ",\n    ".join(items)).replace("@WITEMS@", ",\n    ".join(witems))
    lines = lines + [('w', '%016x' % b, '') for b in ws]
    bf = os.path.join(ROOT, "build", "float_check.bend")
    open(bf, "w").write(src)
    ref = os.path.join(ROOT, "build", "float_ref")
    fp = os.path.join(ROOT, "deps", "redis", "deps", "fpconv")
    subprocess.run([a.cc, "-O2", "-I", fp, "-o", ref, os.path.join(HERE, "float_ref.c"), os.path.join(fp, "fpconv_dtoa.c"), "-lm"], check=True)
    want = subprocess.run([ref, txt], check=True, capture_output=True).stdout.decode("latin1").split("\n")
    env = dict(os.environ, CC=a.cc)
    got = subprocess.run(a.bend + " " + bf, shell=True, env=env, capture_output=True).stdout.decode("latin1")
    got = [l for l in got.split("\n") if l and "bend update" not in l]
    want = [l for l in want if l]
    bad = 0
    for i, (op, x, y) in enumerate(lines):
        g = got[i] if i < len(got) else "(none)"
        if g != want[i]:
            bad += 1
            if bad <= 10:
                print("DIFF %s %r %r: bend %r, glibc %r" % (op, x[:80], y[:80], g[:120], want[i][:120]))
    if bad or len(got) != len(want):
        print("FAIL: %d of %d differ (%d answers for %d lines)" % (bad, len(lines), len(got), len(want)))
        sys.exit(1)
    print("OK: %d numbers read, written and added as glibc and Redis 7.2.16 do" % len(lines))


if __name__ == "__main__":
    main()
