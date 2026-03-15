/**
 * Custom inttypes.h shim for wasm32-freestanding.
 *
 * Zig's built-in <inttypes.h> uses #include_next to find a system libc
 * version, which doesn't exist on freestanding targets. This shim provides
 * the PRI* macros that LVGL needs without triggering that chain.
 */

#ifndef _WASM_INTTYPES_H
#define _WASM_INTTYPES_H

#include <stdint.h>

/* 8-bit */
#define PRId8   "d"
#define PRIi8   "i"
#define PRIo8   "o"
#define PRIu8   "u"
#define PRIx8   "x"
#define PRIX8   "X"

/* 16-bit */
#define PRId16  "d"
#define PRIi16  "i"
#define PRIo16  "o"
#define PRIu16  "u"
#define PRIx16  "x"
#define PRIX16  "X"

/* 32-bit */
#define PRId32  "d"
#define PRIi32  "i"
#define PRIo32  "o"
#define PRIu32  "u"
#define PRIx32  "x"
#define PRIX32  "X"

/* 64-bit - wasm32 uses "lld" for 64-bit */
#define PRId64  "lld"
#define PRIi64  "lli"
#define PRIo64  "llo"
#define PRIu64  "llu"
#define PRIx64  "llx"
#define PRIX64  "llX"

/* pointer-sized (32-bit on wasm32) */
#define PRIdPTR "d"
#define PRIiPTR "i"
#define PRIoPTR "o"
#define PRIuPTR "u"
#define PRIxPTR "x"
#define PRIXPTR "X"

/* intmax_t (64-bit) */
#define PRIdMAX "lld"
#define PRIiMAX "lli"
#define PRIoMAX "llo"
#define PRIuMAX "llu"
#define PRIxMAX "llx"
#define PRIXMAX "llX"

/* SCN (scanf) macros - less commonly needed but included for completeness */
#define SCNd8   "hhd"
#define SCNi8   "hhi"
#define SCNu8   "hhu"
#define SCNx8   "hhx"

#define SCNd16  "hd"
#define SCNi16  "hi"
#define SCNu16  "hu"
#define SCNx16  "hx"

#define SCNd32  "d"
#define SCNi32  "i"
#define SCNu32  "u"
#define SCNx32  "x"

#define SCNd64  "lld"
#define SCNi64  "lli"
#define SCNu64  "llu"
#define SCNx64  "llx"

#endif /* _WASM_INTTYPES_H */
