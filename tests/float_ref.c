// float_ref.c: what Redis does with a number's text on x86-64, with
// glibc's strtod, strtold and printf: string2d and "%.17g" for a double
// (the score of a sorted set), string2ld and ld2string's LD_STR_HUMAN for
// a long double (INCRBYFLOAT), as 7.0.15's util.c has them; and how Redis
// 7.2.16 writes a double: d2string and double2ll (its util.c), and the
// fpconv_dtoa of its deps/fpconv, which this program is built with. The
// reference of tests/float_test.py.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <ctype.h>
#include <limits.h>
#include <stdint.h>
#include <math.h>
#include "fpconv_dtoa.h"

#define MAX_LONG_DOUBLE_CHARS 5*1024

static int string2d(const char *s, size_t slen, double *dp) {
    errno = 0; char *eptr;
    *dp = strtod(s, &eptr);
    if (slen == 0 || isspace(((const char*)s)[0]) || (size_t)(eptr-(char*)s) != slen ||
        (errno == ERANGE && (*dp == HUGE_VAL || *dp == -HUGE_VAL || fpclassify(*dp) == FP_ZERO)) ||
        isnan(*dp)) return 0;
    return 1;
}
static int string2ld(const char *s, size_t slen, long double *dp) {
    char buf[MAX_LONG_DOUBLE_CHARS]; long double value; char *eptr;
    if (slen == 0 || slen >= sizeof(buf)) return 0;
    memcpy(buf,s,slen); buf[slen] = '\0';
    errno = 0;
    value = strtold(buf, &eptr);
    if (isspace(buf[0]) || eptr[0] != '\0' || (size_t)(eptr-buf) != slen ||
        (errno == ERANGE && (value == HUGE_VAL || value == -HUGE_VAL || fpclassify(value) == FP_ZERO)) ||
        errno == EINVAL || isnan(value)) return 0;
    if (dp) *dp = value;
    return 1;
}
// a score as SORT reads one (sort.c): strtod, then the end of what it
// read must be a NUL, with no ERANGE and no NaN (errno cleared first: Redis
// does not clear it, tests/sort_test.py)
static int sortscore(const char *s, double *dp) {
    char *eptr; errno = 0;
    *dp = strtod(s, &eptr);
    if (eptr[0] != '\0' || errno == ERANGE || isnan(*dp)) return 0;
    return 1;
}
static int ld2human(char *buf, size_t len, long double value) {
    size_t l = 0;
    if (isnan(value)) { strcpy(buf, "nan"); return 3; }
    if (isinf(value)) { if (value > 0) { memcpy(buf,"inf",3); l = 3; } else { memcpy(buf,"-inf",4); l = 4; } }
    else {
        l = snprintf(buf,len,"%.17Lf",value);
        if (l+1 > len) return 0;
        if (strchr(buf,'.') != NULL) {
            char *p = buf+l-1;
            while(*p == '0') { p--; l--; }
            if (*p == '.') l--;
        }
        if (l == 2 && buf[0] == '-' && buf[1] == '0') { buf[0] = '0'; l = 1; }
    }
    buf[l] = '\0';
    return l;
}
// Redis 7.2.16's double2ll and d2string (util.c)
static int double2ll(double d, long long *out) {
    if (d < (double)(-LLONG_MAX/2) || d > (double)(LLONG_MAX/2))
        return 0;
    long long ll = d;
    if (ll == d) {
        *out = ll;
        return 1;
    }
    return 0;
}
static int d2string(char *buf, size_t len, double value) {
    if (isnan(value)) {
        len = snprintf(buf,len,"nan");
    } else if (isinf(value)) {
        if (value < 0)
            len = snprintf(buf,len,"-inf");
        else
            len = snprintf(buf,len,"inf");
    } else if (value == 0) {
        if (1.0/value < 0)
            len = snprintf(buf,len,"-0");
        else
            len = snprintf(buf,len,"0");
    } else {
        long long lvalue;
        if (double2ll(value, &lvalue))
            len = snprintf(buf,len,"%lld",lvalue);
        else {
            len = fpconv_dtoa(value, buf);
            buf[len] = '\0';
        }
    }
    return len;
}
static void showd(double d) {
    if (isnan(d)) printf("nan"); else printf("%.17g", d);
}
static void showld(long double x) {
    static char buf[MAX_LONG_DOUBLE_CHARS+32];
    ld2human(buf, MAX_LONG_DOUBLE_CHARS, x); fputs(buf, stdout);
}
// a line: op TAB a [TAB b]; ops: p (parse all three ways), ad, md (double add,
// mul), al (long double add)
int main(int argc, char **argv) {
    FILE *f = fopen(argv[1], "rb");
    static char line[1<<20];
    while (fgets(line, sizeof line, f)) {
        size_t n = strlen(line);
        if (n && line[n-1] == '\n') line[--n] = 0;
        char *a = strchr(line, '\t'); *a++ = 0;
        char *b = strchr(a, '\t'); if (b) *b++ = 0;
        if (!strcmp(line, "p")) {
            double d; long double x;
            if (string2d(a, strlen(a), &d)) showd(d); else printf("ERR");
            printf(" | ");
            if (string2ld(a, strlen(a), &x)) showld(x); else printf("ERR");
            printf(" | ");
            if (sortscore(a, &d)) showd(d); else printf("ERR");
        } else if (!strcmp(line, "ad") || !strcmp(line, "md")) {
            double x, y;
            if (!string2d(a, strlen(a), &x) || !string2d(b, strlen(b), &y)) printf("ERR");
            else showd(line[0] == 'a' ? x + y : x * y);
        } else if (!strcmp(line, "w")) {
            uint64_t bits = strtoull(a, NULL, 16);
            double d; memcpy(&d, &bits, 8);
            char buf[64];
            d2string(buf, sizeof buf, d);
            printf("%s | ", buf);
            int n = fpconv_dtoa(d, buf); buf[n] = 0;
            printf("%s", buf);
        } else if (!strcmp(line, "al")) {
            long double x, y;
            if (!string2ld(a, strlen(a), &x) || !string2ld(b, strlen(b), &y)) printf("ERR");
            else showld(x + y);
        }
        printf("\n");
    }
    return 0;
}
