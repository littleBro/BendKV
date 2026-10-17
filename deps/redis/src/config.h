/* A stand-in for Redis's config.h: the one thing sha1.c takes from it is
 * the byte order, read here from the compiler. */
#ifndef BENDKV_REDIS_CONFIG_H
#define BENDKV_REDIS_CONFIG_H
#ifndef LITTLE_ENDIAN
#define LITTLE_ENDIAN 1234
#endif
#ifndef BIG_ENDIAN
#define BIG_ENDIAN 4321
#endif
#ifndef BYTE_ORDER
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
#define BYTE_ORDER BIG_ENDIAN
#else
#define BYTE_ORDER LITTLE_ENDIAN
#endif
#endif
#endif
