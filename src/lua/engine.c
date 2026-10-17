// The engine of BendKV's scripts
// ==============================
// Redis 7.2.16's own Lua (deps/redis/deps/lua: Lua 5.1.5 with Redis's
// changes, cjson, cmsgpack, struct and bit) with the glue of its script_lua.c,
// eval.c, script.c, function_lua.c and functions.c ported here, so that a
// script's results, errors, tostring, the order of pairs, table.sort and
// cjson are Redis's byte for byte. Bend declares the effects below in
// src/script.bend, and the compiler splices this file into the program
// after its runtime (bend2/guide/EFFECTS.md), so every runtime symbol is
// in scope.
//
// Bend drives a script as an automaton. A run gets a C stack of its own
// (makecontext, swapcontext), on which Lua runs the script; whenever the
// script needs the server, it swaps back to the loop with a step, and
// the effect that was running returns the step to Bend as a word and a
// string:
//
//   kind 0, a call: redis.call's or redis.pcall's arguments, as the RESP
//     request a client would send; Bend runs them and hands the reply's
//     bytes back with Engine.next(0, bytes), which Redis's own parser of
//     replies turns into Lua values;
//   kind 1, a tick: the hook Lua runs every 100,000 instructions, where
//     Redis checks lua-time-limit, serves other clients BUSY and honors
//     SCRIPT KILL; Bend answers Engine.next(1, "") to go on, or
//     Engine.next(2, "") to kill the script;
//   kind 2, done: the script's reply as RESP bytes in the caller's
//     protocol, or (bit 8) an error's text after its "-";
//   kind 3, a log line of redis.log (its level in bits 12 to 15), answered
//     with Engine.next(1, "");
//   kind 4, redis.acl_check_cmd's arguments as a request, answered with
//     ":1" when the caller's user may run the command, ":0" when it may
//     not, "-" when the command is not known, or "!" when its arity does
//     not allow the request's number of words.
//
// The word of a step: bits 0 to 3 its kind; 4 to 7 the script client's
// protocol (redis.setresp: 2 or 3), in which Bend encodes the reply to a
// call; bit 8 an error (done); bit 9 an error the statistics must not
// count again (done: it was counted when the call that made it ran); bits
// 10 and 11 redis.set_repl's flags (the append-only file, replicas); bits
// 12 to 15 a log line's level.
//
// The C side never calls Bend: a run only swaps stacks, and every call a
// script makes runs through the server's own exec. One script runs at a
// time, as in Redis.
//
// FUNCTION and FCALL (Redis's functions.c and function_lua.c) run on the
// same machinery, in a Lua state of their own (Functions, below): an
// FCALL is a run of a function, its keys and arguments its parameters
// rather than KEYS and ARGV; FUNCTION LOAD and RESTORE are runs of loads,
// whose only steps are log lines and done, since a library's code runs
// once, at its load, with nothing of the server's but
// redis.register_function, redis.log and the version.

#include <ctype.h>
#include <errno.h>
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <ucontext.h>

#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>

#include "fpconv_dtoa.h"
#include "rand.h"
#include "resp_parser.h"
#include "server.h"
#include "sha1.h"

#if defined(__has_feature)
#if __has_feature(address_sanitizer)
#define SC_ASAN 1
#endif
#if __has_feature(thread_sanitizer)
#define SC_TSAN 1
#endif
#endif
#if defined(__SANITIZE_ADDRESS__) && !defined(SC_ASAN)
#define SC_ASAN 1
#endif
#if defined(__SANITIZE_THREAD__) && !defined(SC_TSAN)
#define SC_TSAN 1
#endif
#ifdef SC_ASAN
void __sanitizer_start_switch_fiber(void** fake_stack_save,
  const void* bottom, size_t size);
void __sanitizer_finish_switch_fiber(void* fake_stack_save,
  const void** bottom_old, size_t* size_old);
#endif
#ifdef SC_TSAN
void* __tsan_get_current_fiber(void);
void* __tsan_create_fiber(unsigned flags);
void __tsan_destroy_fiber(void* fiber);
void __tsan_switch_to_fiber(void* fiber, unsigned flags);
#endif

// The flags of a script (Redis's script.h): its shebang's, and
// EVAL_COMPAT for a script without one.
#define SC_FLAG_NO_WRITES        (1u << 0)
#define SC_FLAG_ALLOW_OOM        (1u << 1)
#define SC_FLAG_ALLOW_STALE      (1u << 2)
#define SC_FLAG_NO_CLUSTER       (1u << 3)
#define SC_FLAG_EVAL_COMPAT_MODE (1u << 4)
#define SC_FLAG_ALLOW_CROSS_SLOT (1u << 5)

// What a run runs: an EVAL's script, an FCALL's function, or the loads of
// FUNCTION LOAD and RESTORE (and of the libraries a start reads)
#define SC_MODE_SCRIPT   0
#define SC_MODE_FUNCTION 1
#define SC_MODE_LOAD     2

// How a load takes its libraries in: FUNCTION LOAD's, with REPLACE or not,
// and FUNCTION RESTORE's three policies
#define FN_LOAD         0
#define FN_LOAD_REPLACE 1
#define FN_APPEND       2
#define FN_REPLACE      3
#define FN_FLUSH        4

// The kinds of a step
#define SC_CALL 0
#define SC_TICK 1
#define SC_DONE 2
#define SC_LOG  3
#define SC_ACL  4

// redis.set_repl's flags
#define SC_REPL_AOF 1
#define SC_REPL_REPLICA 2

// Redis's log levels, redis.log's first argument
#define SC_LL_DEBUG 0
#define SC_LL_VERBOSE 1
#define SC_LL_NOTICE 2
#define SC_LL_WARNING 3

// A growing buffer of bytes
// -------------------------

typedef struct {
  char*  p;
  size_t n;
  size_t cap;
} ScBuf;

static void sc_buf_room(ScBuf* b, size_t more) {
  if (b->n + more + 1 > b->cap) {
    size_t cap = b->cap == 0 ? 256 : b->cap;
    while (cap < b->n + more + 1) {
      cap *= 2;
    }
    b->p = io_mem(realloc(b->p, cap));
    b->cap = cap;
  }
}

static void sc_buf_add(ScBuf* b, const char* s, size_t n) {
  sc_buf_room(b, n);
  memcpy(b->p + b->n, s, n);
  b->n += n;
  b->p[b->n] = '\0';
}

static void sc_buf_str(ScBuf* b, const char* s) {
  sc_buf_add(b, s, strlen(s));
}

static void sc_buf_fmt(ScBuf* b, const char* fmt, ...) {
  char tmp[64];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(tmp, sizeof(tmp), fmt, ap);
  va_end(ap);
  if (n < 0) {
    return;
  }
  if ((size_t)n < sizeof(tmp)) {
    sc_buf_add(b, tmp, (size_t)n);
    return;
  }
  sc_buf_room(b, (size_t)n);
  va_start(ap, fmt);
  vsnprintf(b->p + b->n, (size_t)n + 1, fmt, ap);
  va_end(ap);
  b->n += (size_t)n;
}

static void sc_buf_clear(ScBuf* b) {
  b->n = 0;
  if (b->p != NULL) {
    b->p[0] = '\0';
  }
}

// A C string of a buffer's bytes with every "\r" and "\n" a space, as
// Redis's sdsmapchars(s, "\r\n", "  ", 2) makes one
static void sc_one_line(char* s, size_t n) {
  for (size_t i = 0; i < n; i += 1) {
    if (s[i] == '\r' || s[i] == '\n') {
      s[i] = ' ';
    }
  }
}

// The cache of scripts
// --------------------
// A script by the 20 bytes of its SHA1: its body and its flags, as
// Redis's lua_scripts dictionary keeps them (the compiled function is in
// the Lua state's registry under "f_<sha>"). SCRIPT EXISTS and EVALSHA
// read the hexadecimal sha in either case.

typedef struct {
  uint8_t  sha[20];
  char*    body;
  size_t   len;
  uint32_t flags;
  int      used;
} ScScript;

static ScScript* sc_scripts;
static size_t    sc_scripts_cap;
static size_t    sc_scripts_n;
static size_t    sc_scripts_mem;

static int sc_hex_digit(char c) {
  if (c >= '0' && c <= '9') {
    return c - '0';
  }
  if (c >= 'a' && c <= 'f') {
    return c - 'a' + 10;
  }
  if (c >= 'A' && c <= 'F') {
    return c - 'A' + 10;
  }
  return -1;
}

// the 20 bytes of 40 hexadecimal digits; 0 when they are not that
static int sc_hex_to_bin(const char* hex, size_t n, uint8_t* out) {
  if (n != 40) {
    return 0;
  }
  for (size_t i = 0; i < 20; i += 1) {
    int a = sc_hex_digit(hex[2 * i]);
    int b = sc_hex_digit(hex[2 * i + 1]);
    if (a < 0 || b < 0) {
      return 0;
    }
    out[i] = (uint8_t)(a * 16 + b);
  }
  return 1;
}

static void sc_bin_to_hex(const uint8_t* sha, char* hex41) {
  static const char cset[] = "0123456789abcdef";
  for (size_t i = 0; i < 20; i += 1) {
    hex41[2 * i] = cset[sha[i] >> 4];
    hex41[2 * i + 1] = cset[sha[i] & 15];
  }
  hex41[40] = '\0';
}

static size_t sc_sha_slot(const uint8_t* sha, size_t cap) {
  uint64_t h = 0;
  memcpy(&h, sha, 8);
  return (size_t)(h & (cap - 1));
}

static ScScript* sc_script_find(const uint8_t* sha) {
  if (sc_scripts_cap == 0) {
    return NULL;
  }
  size_t i = sc_sha_slot(sha, sc_scripts_cap);
  for (;;) {
    ScScript* s = &sc_scripts[i];
    if (!s->used) {
      return NULL;
    }
    if (memcmp(s->sha, sha, 20) == 0) {
      return s;
    }
    i = (i + 1) & (sc_scripts_cap - 1);
  }
}

static void sc_script_put(ScScript* table, size_t cap, ScScript* s) {
  size_t i = sc_sha_slot(s->sha, cap);
  while (table[i].used) {
    i = (i + 1) & (cap - 1);
  }
  table[i] = *s;
}

static void sc_script_add(const uint8_t* sha, const char* body, size_t len,
  uint32_t flags) {
  if ((sc_scripts_n + 1) * 2 > sc_scripts_cap) {
    size_t cap = sc_scripts_cap == 0 ? 64 : sc_scripts_cap * 2;
    ScScript* table = io_mem(calloc(cap, sizeof(ScScript)));
    for (size_t i = 0; i < sc_scripts_cap; i += 1) {
      if (sc_scripts[i].used) {
        sc_script_put(table, cap, &sc_scripts[i]);
      }
    }
    free(sc_scripts);
    sc_scripts = table;
    sc_scripts_cap = cap;
  }
  ScScript s;
  memcpy(s.sha, sha, 20);
  s.body = io_mem(malloc(len + 1));
  memcpy(s.body, body, len);
  s.body[len] = '\0';
  s.len = len;
  s.flags = flags;
  s.used = 1;
  sc_script_put(sc_scripts, sc_scripts_cap, &s);
  sc_scripts_n += 1;
  sc_scripts_mem += sizeof(ScScript) + len + 1 + 48;
}

static void sc_scripts_clear(void) {
  for (size_t i = 0; i < sc_scripts_cap; i += 1) {
    if (sc_scripts[i].used) {
      free(sc_scripts[i].body);
    }
  }
  free(sc_scripts);
  sc_scripts = NULL;
  sc_scripts_cap = 0;
  sc_scripts_n = 0;
  sc_scripts_mem = 0;
}

// The run
// -------

typedef struct {
  int live;            // a script runs: its context exists
  int started;         // the context has been entered once
  ucontext_t host;     // the loop's context while the script runs
  ucontext_t me;       // the script's
  void* stack;
  size_t stack_size;
  // the step handed to Bend
  int kind;
  int err;
  int nostats;
  int level;
  ScBuf out;
  // what Bend hands back
  const char* in;
  size_t in_len;
  int verdict;         // 0 a reply, 1 go on, 2 kill
  // the run's state
  int resp;            // the script client's protocol, redis.setresp's
  int caller_resp;     // the caller's
  int ro;              // EVAL_RO, EVALSHA_RO: no writes
  int eval;            // EVAL rather than FCALL, for the messages
  int repl;            // redis.set_repl's flags
  int killed;
  char funcname[43];   // "f_<sha>"
  char* keys;          // KEYS as a RESP array
  size_t keys_len;
  char* args;          // ARGV as a RESP array
  size_t args_len;
  uint32_t flags;      // the script's flags
  int mode;            // what runs: SC_MODE_SCRIPT, _FUNCTION or _LOAD
  int fref;            // a function's callback, in the functions' registry
  char* fname;         // the function's name, as it was registered
  char* codes;         // a load's libraries: a RESP array of their codes
  size_t codes_len;
  int policy;          // how a load takes them in: FN_LOAD to FN_FLUSH
  int timed;           // a load held to FUNCTION LOAD's 500 ms
  int tail;            // its last code the error of a read that failed
#ifdef SC_ASAN
  void* host_fake;
  void* me_fake;
  const void* host_bottom;
  size_t host_size;
#endif
#ifdef SC_TSAN
  void* tsan_host;
  void* tsan_me;
#endif
} ScRun;

static lua_State* sc_lua;
static ScRun      sc_run;
static long       sc_gc_count;
static int        sc_inuse;

#define SC_STACK_SIZE (8u << 20)

// the switch from the loop into the script's stack, which returns when
// the script swaps back with a step
static void sc_enter(ScRun* r) {
#ifdef SC_ASAN
  __sanitizer_start_switch_fiber(&r->host_fake, r->stack, r->stack_size);
#endif
#ifdef SC_TSAN
  __tsan_switch_to_fiber(r->tsan_me, 0);
#endif
  swapcontext(&r->host, &r->me);
#ifdef SC_ASAN
  const void* bottom;
  size_t size;
  __sanitizer_finish_switch_fiber(r->host_fake, &bottom, &size);
#endif
}

// the switch from the script's stack back to the loop with the step in
// r->kind and r->out, which returns when Bend hands the next thing back
static void sc_yield(ScRun* r) {
#ifdef SC_ASAN
  __sanitizer_start_switch_fiber(&r->me_fake, r->host_bottom, r->host_size);
#endif
#ifdef SC_TSAN
  __tsan_switch_to_fiber(r->tsan_host, 0);
#endif
  swapcontext(&r->me, &r->host);
#ifdef SC_ASAN
  __sanitizer_finish_switch_fiber(r->me_fake, &r->host_bottom, &r->host_size);
#endif
}

// Errors as Lua values
// --------------------
// An error is a table with an "err" field, "CODE message", as
// luaPushErrorBuff makes one: "-CODE message" keeps its code, anything
// else gets "ERR".

static void sc_push_error_n(lua_State* L, const char* s, size_t n) {
  char* buf = io_mem(malloc(n + 1));
  memcpy(buf, s, n);
  buf[n] = '\0';
  const char* code = "ERR";
  const char* msg = buf;
  char* code_buf = NULL;
  if (buf[0] == '-') {
    char* sp = strstr(buf, " ");
    if (sp == NULL) {
      msg = buf + 1;
    } else {
      *sp = '\0';
      msg = sp + 1;
      code_buf = buf + 1;
      code = code_buf;
    }
  }
  // the newline at the end taken off, as sdstrim(msg, "\r\n")
  size_t m = strlen(msg);
  while (m > 0 && (msg[m - 1] == '\r' || msg[m - 1] == '\n')) {
    m -= 1;
  }
  size_t start = 0;
  while (start < m && (msg[start] == '\r' || msg[start] == '\n')) {
    start += 1;
  }
  lua_newtable(L);
  lua_pushstring(L, "err");
  lua_pushfstring(L, "%s ", code);
  lua_pushlstring(L, msg + start, m - start);
  lua_concat(L, 2);
  lua_settable(L, -3);
  free(buf);
}

static void sc_push_error(lua_State* L, const char* s) {
  sc_push_error_n(L, s, strlen(s));
}

typedef struct {
  char* msg;
  char* source;
  char* line;
  int   ignore;
} ScErrInfo;

static char* sc_strdup(const char* s) {
  size_t n = strlen(s);
  char* p = io_mem(malloc(n + 1));
  memcpy(p, s, n + 1);
  return p;
}

// luaExtractErrorInformation: the fields of the error at the top
static void sc_err_info(lua_State* L, ScErrInfo* info) {
  memset(info, 0, sizeof(*info));
  if (lua_isstring(L, -1)) {
    const char* s = lua_tostring(L, -1);
    info->msg = io_mem(malloc(strlen(s) + 5));
    sprintf(info->msg, "ERR %s", s);
    return;
  }
  lua_getfield(L, -1, "err");
  if (lua_isstring(L, -1)) {
    info->msg = sc_strdup(lua_tostring(L, -1));
  }
  lua_pop(L, 1);
  lua_getfield(L, -1, "source");
  if (lua_isstring(L, -1)) {
    info->source = sc_strdup(lua_tostring(L, -1));
  }
  lua_pop(L, 1);
  lua_getfield(L, -1, "line");
  if (lua_isstring(L, -1)) {
    info->line = sc_strdup(lua_tostring(L, -1));
  }
  lua_pop(L, 1);
  lua_getfield(L, -1, "ignore_error_stats_update");
  if (lua_isboolean(L, -1)) {
    info->ignore = lua_toboolean(L, -1);
  }
  lua_pop(L, 1);
}

static void sc_err_info_free(ScErrInfo* info) {
  free(info->msg);
  free(info->source);
  free(info->line);
}

// Replies as Lua values
// ---------------------
// Redis's own parser of replies (deps/redis/resp_parser.c) with the
// callbacks of script_lua.c, which make a Lua value of each kind of reply.

static void sc_room(lua_State* L, int n) {
  if (!lua_checkstack(L, n)) {
    err_fail("lua stack limit reach when parsing redis.call reply");
  }
}

static void sc_cb_int(void* ctx, long long val, const char* proto,
  size_t proto_len) {
  (void)proto; (void)proto_len;
  if (ctx == NULL) return;
  lua_State* L = ctx;
  sc_room(L, 1);
  lua_pushnumber(L, (lua_Number)val);
}

static void sc_cb_null_bulk(void* ctx, const char* proto, size_t proto_len) {
  (void)proto; (void)proto_len;
  if (ctx == NULL) return;
  lua_State* L = ctx;
  sc_room(L, 1);
  lua_pushboolean(L, 0);
}

static void sc_cb_null_array(void* ctx, const char* proto, size_t proto_len) {
  (void)proto; (void)proto_len;
  if (ctx == NULL) return;
  lua_State* L = ctx;
  sc_room(L, 1);
  lua_pushboolean(L, 0);
}

static void sc_cb_bulk(void* ctx, const char* str, size_t len,
  const char* proto, size_t proto_len) {
  (void)proto; (void)proto_len;
  if (ctx == NULL) return;
  lua_State* L = ctx;
  sc_room(L, 1);
  lua_pushlstring(L, str, len);
}

static void sc_cb_status(void* ctx, const char* str, size_t len,
  const char* proto, size_t proto_len) {
  (void)proto; (void)proto_len;
  if (ctx == NULL) return;
  lua_State* L = ctx;
  sc_room(L, 3);
  lua_newtable(L);
  lua_pushstring(L, "ok");
  lua_pushlstring(L, str, len);
  lua_settable(L, -3);
}

static void sc_cb_error(void* ctx, const char* str, size_t len,
  const char* proto, size_t proto_len) {
  (void)proto; (void)proto_len;
  if (ctx == NULL) return;
  lua_State* L = ctx;
  sc_room(L, 3);
  char* buf = io_mem(malloc(len + 2));
  buf[0] = '-';
  memcpy(buf + 1, str, len);
  sc_push_error_n(L, buf, len + 1);
  free(buf);
  // the statistics counted it when the command ran
  lua_pushstring(L, "ignore_error_stats_update");
  lua_pushboolean(L, 1);
  lua_settable(L, -3);
}

static void sc_cb_map(struct ReplyParser* parser, void* ctx, size_t len,
  const char* proto) {
  (void)proto;
  lua_State* L = ctx;
  if (L != NULL) {
    sc_room(L, 3);
    lua_newtable(L);
    lua_pushstring(L, "map");
    lua_newtable(L);
  }
  for (size_t j = 0; j < len; j += 1) {
    parseReply(parser, L);
    parseReply(parser, L);
    if (L != NULL) lua_settable(L, -3);
  }
  if (L != NULL) lua_settable(L, -3);
}

static void sc_cb_set(struct ReplyParser* parser, void* ctx, size_t len,
  const char* proto) {
  (void)proto;
  lua_State* L = ctx;
  if (L != NULL) {
    sc_room(L, 3);
    lua_newtable(L);
    lua_pushstring(L, "set");
    lua_newtable(L);
  }
  for (size_t j = 0; j < len; j += 1) {
    parseReply(parser, L);
    if (L != NULL) {
      sc_room(L, 1);
      lua_pushboolean(L, 1);
      lua_settable(L, -3);
    }
  }
  if (L != NULL) lua_settable(L, -3);
}

static void sc_cb_array(struct ReplyParser* parser, void* ctx, size_t len,
  const char* proto) {
  (void)proto;
  lua_State* L = ctx;
  if (L != NULL) {
    sc_room(L, 2);
    lua_newtable(L);
  }
  for (size_t j = 0; j < len; j += 1) {
    if (L != NULL) lua_pushnumber(L, (lua_Number)(j + 1));
    parseReply(parser, L);
    if (L != NULL) lua_settable(L, -3);
  }
}

static void sc_cb_attribute(struct ReplyParser* parser, void* ctx, size_t len,
  const char* proto) {
  (void)proto;
  for (size_t j = 0; j < len; j += 1) {
    parseReply(parser, NULL);
    parseReply(parser, NULL);
  }
  parseReply(parser, ctx);
}

static void sc_cb_verbatim(void* ctx, const char* format, const char* str,
  size_t len, const char* proto, size_t proto_len) {
  (void)proto; (void)proto_len;
  if (ctx == NULL) return;
  lua_State* L = ctx;
  sc_room(L, 5);
  lua_newtable(L);
  lua_pushstring(L, "verbatim_string");
  lua_newtable(L);
  lua_pushstring(L, "string");
  lua_pushlstring(L, str, len);
  lua_settable(L, -3);
  lua_pushstring(L, "format");
  lua_pushlstring(L, format, 3);
  lua_settable(L, -3);
  lua_settable(L, -3);
}

static void sc_cb_big_number(void* ctx, const char* str, size_t len,
  const char* proto, size_t proto_len) {
  (void)proto; (void)proto_len;
  if (ctx == NULL) return;
  lua_State* L = ctx;
  sc_room(L, 3);
  lua_newtable(L);
  lua_pushstring(L, "big_number");
  lua_pushlstring(L, str, len);
  lua_settable(L, -3);
}

static void sc_cb_null(void* ctx, const char* proto, size_t proto_len) {
  (void)proto; (void)proto_len;
  if (ctx == NULL) return;
  lua_State* L = ctx;
  sc_room(L, 1);
  lua_pushnil(L);
}

static void sc_cb_bool(void* ctx, int val, const char* proto,
  size_t proto_len) {
  (void)proto; (void)proto_len;
  if (ctx == NULL) return;
  lua_State* L = ctx;
  sc_room(L, 1);
  lua_pushboolean(L, val);
}

static void sc_cb_double(void* ctx, double d, const char* proto,
  size_t proto_len) {
  (void)proto; (void)proto_len;
  if (ctx == NULL) return;
  lua_State* L = ctx;
  sc_room(L, 3);
  lua_newtable(L);
  lua_pushstring(L, "double");
  lua_pushnumber(L, d);
  lua_settable(L, -3);
}

static const ReplyParserCallbacks sc_callbacks = {
  .null_array_callback = sc_cb_null_array,
  .bulk_string_callback = sc_cb_bulk,
  .null_bulk_string_callback = sc_cb_null_bulk,
  .error_callback = sc_cb_error,
  .simple_str_callback = sc_cb_status,
  .long_callback = sc_cb_int,
  .array_callback = sc_cb_array,
  .set_callback = sc_cb_set,
  .map_callback = sc_cb_map,
  .bool_callback = sc_cb_bool,
  .double_callback = sc_cb_double,
  .null_callback = sc_cb_null,
  .big_number_callback = sc_cb_big_number,
  .verbatim_string_callback = sc_cb_verbatim,
  .attribute_callback = sc_cb_attribute,
  .error = NULL,
};

// the Lua value of a reply's bytes, pushed
static void sc_reply_to_lua(lua_State* L, const char* reply) {
  ReplyParser parser = { .curr_location = reply, .callbacks = sc_callbacks };
  parseReply(&parser, L);
}

// Lua values as replies
// ---------------------
// luaReplyToRedisReply: the value at the top of the stack as RESP bytes
// in the caller's protocol, consumed. A boolean is Lua's 1 or null while
// the script speaks RESP2, a boolean when it set RESP3.

static void sc_null(ScRun* r, ScBuf* b) {
  sc_buf_str(b, r->caller_resp == 2 ? "$-1\r\n" : "_\r\n");
}

static void sc_bulk(ScBuf* b, const char* s, size_t n) {
  sc_buf_fmt(b, "$%zu\r\n", n);
  sc_buf_add(b, s, n);
  sc_buf_add(b, "\r\n", 2);
}

// util.c's double2ll: whether d is an integer that a long long holds
// without loss (within 2^62 either way), and which. A NaN fails the range's
// test before the cast, which Redis makes of it too and C leaves undefined
static int sc_double2ll(double d, long long* out) {
  if (!(d >= (double)(-LLONG_MAX / 2) && d <= (double)(LLONG_MAX / 2))) {
    return 0;
  }
  long long ll = (long long)d;
  if ((double)ll == d) {
    *out = ll;
    return 1;
  }
  return 0;
}

// util.c's d2string, as Redis 7.2 writes a double reply (addReplyDouble):
// nan, inf and -inf, 0 and -0, an integer as one, any other in
// fpconv_dtoa's shortest form; its length
static int sc_d2string(char* buf, size_t len, double d) {
  if (isnan(d)) {
    return snprintf(buf, len, "nan");
  }
  if (isinf(d)) {
    return snprintf(buf, len, d < 0 ? "-inf" : "inf");
  }
  if (d == 0) {
    return snprintf(buf, len, signbit(d) ? "-0" : "0");
  }
  long long ll;
  if (sc_double2ll(d, &ll)) {
    return snprintf(buf, len, "%lld", ll);
  }
  int n = fpconv_dtoa(d, buf);
  buf[n] = '\0';
  return n;
}

static void sc_double(ScRun* r, ScBuf* b, double d) {
  char dbuf[64];
  int n = sc_d2string(dbuf, sizeof(dbuf), d);
  if (r->caller_resp == 2) {
    sc_bulk(b, dbuf, (size_t)n);
  } else {
    sc_buf_add(b, ",", 1);
    sc_buf_add(b, dbuf, (size_t)n);
    sc_buf_add(b, "\r\n", 2);
  }
}

static void sc_lua_to_reply(ScRun* r, lua_State* L, ScBuf* b) {
  int t = lua_type(L, -1);
  if (!lua_checkstack(L, 4)) {
    sc_buf_str(b, "-ERR reached lua stack limit\r\n");
    lua_pop(L, 1);
    return;
  }
  switch (t) {
  case LUA_TSTRING: {
    size_t n;
    const char* s = lua_tolstring(L, -1, &n);
    sc_bulk(b, s, n);
    break;
  }
  case LUA_TBOOLEAN:
    if (r->resp == 2) {
      if (lua_toboolean(L, -1)) {
        sc_buf_str(b, ":1\r\n");
      } else {
        sc_null(r, b);
      }
    } else if (r->caller_resp == 2) {
      sc_buf_str(b, lua_toboolean(L, -1) ? ":1\r\n" : ":0\r\n");
    } else {
      sc_buf_str(b, lua_toboolean(L, -1) ? "#t\r\n" : "#f\r\n");
    }
    break;
  case LUA_TNUMBER:
    // Redis casts with (long long): past the range, x86-64 gives the least
    // one (luaconf.h's luai_num2long, defined in C), as for 2^63
    sc_buf_fmt(b, ":%lld\r\n", (long long)luai_num2long(lua_tonumber(L, -1)));
    break;
  case LUA_TTABLE: {
    // an error
    lua_pushstring(L, "err");
    lua_rawget(L, -2);
    t = lua_type(L, -1);
    if (t == LUA_TSTRING) {
      lua_pop(L, 1);
      ScErrInfo info;
      sc_err_info(L, &info);
      size_t n = strlen(info.msg);
      while (n > 0 && (info.msg[n - 1] == '\r' || info.msg[n - 1] == '\n')) {
        n -= 1;
      }
      sc_one_line(info.msg, n);
      sc_buf_add(b, "-", 1);
      sc_buf_add(b, info.msg, n);
      sc_buf_add(b, "\r\n", 2);
      sc_err_info_free(&info);
      lua_pop(L, 1);
      return;
    }
    lua_pop(L, 1);
    // a status
    lua_pushstring(L, "ok");
    lua_rawget(L, -2);
    t = lua_type(L, -1);
    if (t == LUA_TSTRING) {
      size_t n;
      const char* s = lua_tolstring(L, -1, &n);
      char* ok = io_mem(malloc(n + 1));
      memcpy(ok, s, n);
      ok[n] = '\0';
      n = strlen(ok);
      sc_one_line(ok, n);
      sc_buf_add(b, "+", 1);
      sc_buf_add(b, ok, n);
      sc_buf_add(b, "\r\n", 2);
      free(ok);
      lua_pop(L, 2);
      return;
    }
    lua_pop(L, 1);
    // a double
    lua_pushstring(L, "double");
    lua_rawget(L, -2);
    t = lua_type(L, -1);
    if (t == LUA_TNUMBER) {
      sc_double(r, b, lua_tonumber(L, -1));
      lua_pop(L, 2);
      return;
    }
    lua_pop(L, 1);
    // a big number
    lua_pushstring(L, "big_number");
    lua_rawget(L, -2);
    t = lua_type(L, -1);
    if (t == LUA_TSTRING) {
      size_t n;
      const char* s = lua_tolstring(L, -1, &n);
      char* num = io_mem(malloc(n + 1));
      memcpy(num, s, n);
      num[n] = '\0';
      sc_one_line(num, n);
      if (r->caller_resp == 2) {
        sc_bulk(b, num, n);
      } else {
        sc_buf_add(b, "(", 1);
        sc_buf_add(b, num, n);
        sc_buf_add(b, "\r\n", 2);
      }
      free(num);
      lua_pop(L, 2);
      return;
    }
    lua_pop(L, 1);
    // a verbatim string
    lua_pushstring(L, "verbatim_string");
    lua_rawget(L, -2);
    t = lua_type(L, -1);
    if (t == LUA_TTABLE) {
      lua_pushstring(L, "format");
      lua_rawget(L, -2);
      t = lua_type(L, -1);
      if (t == LUA_TSTRING) {
        const char* format = lua_tostring(L, -1);
        lua_pushstring(L, "string");
        lua_rawget(L, -3);
        t = lua_type(L, -1);
        if (t == LUA_TSTRING) {
          size_t n;
          const char* s = lua_tolstring(L, -1, &n);
          if (r->caller_resp == 2) {
            sc_bulk(b, s, n);
          } else {
            char ext[4] = "   ";
            for (int i = 0; i < 3 && format[i] != '\0'; i += 1) {
              ext[i] = format[i];
            }
            sc_buf_fmt(b, "=%zu\r\n", n + 4);
            sc_buf_add(b, ext, 3);
            sc_buf_add(b, ":", 1);
            sc_buf_add(b, s, n);
            sc_buf_add(b, "\r\n", 2);
          }
          lua_pop(L, 4);
          return;
        }
        lua_pop(L, 1);
      }
      lua_pop(L, 1);
    }
    lua_pop(L, 1);
    // a map
    lua_pushstring(L, "map");
    lua_rawget(L, -2);
    t = lua_type(L, -1);
    if (t == LUA_TTABLE) {
      size_t count = 0;
      lua_pushnil(L);
      while (lua_next(L, -2)) {
        lua_pop(L, 1);
        count += 1;
      }
      if (r->caller_resp == 2) {
        sc_buf_fmt(b, "*%zu\r\n", count * 2);
      } else {
        sc_buf_fmt(b, "%%%zu\r\n", count);
      }
      lua_pushnil(L);
      while (lua_next(L, -2)) {
        lua_pushvalue(L, -2);
        sc_lua_to_reply(r, L, b);
        sc_lua_to_reply(r, L, b);
      }
      lua_pop(L, 2);
      return;
    }
    lua_pop(L, 1);
    // a set
    lua_pushstring(L, "set");
    lua_rawget(L, -2);
    t = lua_type(L, -1);
    if (t == LUA_TTABLE) {
      size_t count = 0;
      lua_pushnil(L);
      while (lua_next(L, -2)) {
        lua_pop(L, 1);
        count += 1;
      }
      sc_buf_fmt(b, r->caller_resp == 2 ? "*%zu\r\n" : "~%zu\r\n", count);
      lua_pushnil(L);
      while (lua_next(L, -2)) {
        lua_pop(L, 1);
        lua_pushvalue(L, -1);
        sc_lua_to_reply(r, L, b);
      }
      lua_pop(L, 2);
      return;
    }
    lua_pop(L, 1);
    // an array, up to its first nil
    size_t count = 0;
    for (;;) {
      lua_rawgeti(L, -1, (int)count + 1);
      t = lua_type(L, -1);
      lua_pop(L, 1);
      if (t == LUA_TNIL) {
        break;
      }
      count += 1;
    }
    sc_buf_fmt(b, "*%zu\r\n", count);
    for (size_t j = 1; j <= count; j += 1) {
      lua_rawgeti(L, -1, (int)j);
      sc_lua_to_reply(r, L, b);
    }
    break;
  }
  default:
    sc_null(r, b);
  }
  lua_pop(L, 1);
}

// The redis API
// -------------

// the arguments of a call as a RESP request in r->out: a number is
// written as luaArgsToRedisArgv writes it, an integer as one, any other in
// fpconv_dtoa's shortest form (-0 as 0, and a NaN as fpconv_dtoa has it,
// nan or -nan); 0 and an error pushed when one is neither a string nor a
// number
static int sc_args_to_request(lua_State* L, ScRun* r) {
  int argc = lua_gettop(L);
  if (argc == 0) {
    sc_push_error(L, "Please specify at least one argument for this redis lib call");
    return 0;
  }
  sc_buf_clear(&r->out);
  sc_buf_fmt(&r->out, "*%d\r\n", argc);
  int j;
  for (j = 0; j < argc; j += 1) {
    if (lua_type(L, j + 1) == LUA_TNUMBER) {
      char dbuf[64];
      double num = (double)lua_tonumber(L, j + 1);
      long long ll;
      int n = sc_double2ll(num, &ll) ? snprintf(dbuf, sizeof(dbuf), "%lld", ll) : fpconv_dtoa(num, dbuf);
      sc_bulk(&r->out, dbuf, (size_t)n);
    } else {
      size_t n;
      const char* s = lua_tolstring(L, j + 1, &n);
      if (s == NULL) {
        break;
      }
      sc_bulk(&r->out, s, n);
    }
  }
  lua_pop(L, argc);
  if (j != argc) {
    sc_push_error(L, "Lua redis lib command arguments must be strings or integers");
    return 0;
  }
  return 1;
}

// redis.call and redis.pcall
static int sc_generic_command(lua_State* L, int raise_error) {
  ScRun* r = &sc_run;
  if (!r->live) {
    sc_push_error(L, "redis.call/pcall can only be called inside a script invocation");
    return lua_error(L);
  }
  if (!sc_args_to_request(L, r)) {
    return raise_error ? lua_error(L) : 1;
  }
  if (sc_inuse) {
    sc_push_error(L, "luaRedisGenericCommand() recursive call detected. Are you doing funny stuff with Lua debug hooks?");
    return 1;
  }
  sc_inuse += 1;
  r->kind = SC_CALL;
  sc_yield(r);
  const char* reply = r->in;
  if (raise_error && reply[0] != '-') {
    raise_error = 0;
  }
  sc_reply_to_lua(L, reply);
  sc_inuse -= 1;
  if (raise_error) {
    return lua_error(L);
  }
  return 1;
}

static int sc_call(lua_State* L) {
  return sc_generic_command(L, 1);
}

static int sc_pcall(lua_State* L) {
  return sc_generic_command(L, 0);
}

// pcall as Redis defines it: an error that is a table answers its "err"
// field alone, as older versions answered the string
static int sc_lua_pcall(lua_State* L) {
  int argc = lua_gettop(L);
  lua_pushboolean(L, 1);
  lua_insert(L, 1);
  if (lua_pcall(L, argc - 1, LUA_MULTRET, 0)) {
    lua_remove(L, 1);
    if (lua_istable(L, -1)) {
      lua_getfield(L, -1, "err");
      if (lua_isstring(L, -1)) {
        lua_replace(L, -2);
      }
    }
    lua_pushboolean(L, 0);
    lua_insert(L, 1);
  }
  return lua_gettop(L);
}

static void sc_sha1hex(char* digest, const char* s, size_t len) {
  SHA1_CTX ctx;
  unsigned char hash[20];
  SHA1Init(&ctx);
  SHA1Update(&ctx, (const unsigned char*)s, (uint32_t)len);
  SHA1Final(hash, &ctx);
  sc_bin_to_hex(hash, digest);
}

static int sc_sha1hex_command(lua_State* L) {
  int argc = lua_gettop(L);
  char digest[41];
  size_t len;
  if (argc != 1) {
    sc_push_error(L, "wrong number of arguments");
    return lua_error(L);
  }
  const char* s = lua_tolstring(L, 1, &len);
  sc_sha1hex(digest, s, len);
  lua_pushstring(L, digest);
  return 1;
}

static int sc_error_reply(lua_State* L) {
  if (lua_gettop(L) != 1 || lua_type(L, -1) != LUA_TSTRING) {
    sc_push_error(L, "wrong number or type of arguments");
    return 1;
  }
  const char* err = lua_tostring(L, -1);
  if (err[0] != '-') {
    size_t n = strlen(err);
    char* buf = io_mem(malloc(n + 2));
    buf[0] = '-';
    memcpy(buf + 1, err, n + 1);
    sc_push_error(L, buf);
    free(buf);
  } else {
    sc_push_error(L, err);
  }
  return 1;
}

static int sc_status_reply(lua_State* L) {
  if (lua_gettop(L) != 1 || lua_type(L, -1) != LUA_TSTRING) {
    sc_push_error(L, "wrong number or type of arguments");
    return 1;
  }
  lua_newtable(L);
  lua_pushstring(L, "ok");
  lua_pushvalue(L, -3);
  lua_settable(L, -3);
  return 1;
}

static int sc_set_repl(lua_State* L) {
  ScRun* r = &sc_run;
  if (!r->live) {
    sc_push_error(L, "redis.set_repl can only be called inside a script invocation");
    return lua_error(L);
  }
  if (lua_gettop(L) != 1) {
    sc_push_error(L, "redis.set_repl() requires one argument.");
    return lua_error(L);
  }
  int flags = luai_num2int(lua_tonumber(L, -1));
  if ((flags & ~(SC_REPL_AOF | SC_REPL_REPLICA)) != 0) {
    sc_push_error(L, "Invalid replication flags. Use REPL_AOF, REPL_REPLICA, REPL_ALL or REPL_NONE.");
    return lua_error(L);
  }
  r->repl = flags;
  return 0;
}

static int sc_acl_check_cmd(lua_State* L) {
  ScRun* r = &sc_run;
  if (!r->live) {
    sc_push_error(L, "redis.acl_check_cmd can only be called inside a script invocation");
    return lua_error(L);
  }
  if (!sc_args_to_request(L, r)) {
    return lua_error(L);
  }
  r->kind = SC_ACL;
  sc_yield(r);
  if (r->in_len >= 2 && r->in[0] == ':' && (r->in[1] == '1' || r->in[1] == '0')) {
    lua_pushboolean(L, r->in[1] == '1');
    return 1;
  }
  if (r->in_len >= 1 && r->in[0] == '!') {
    sc_push_error(L, "Wrong number of args for redis.acl_check_cmd()");
    return lua_error(L);
  }
  sc_push_error(L, "Invalid command passed to redis.acl_check_cmd()");
  return lua_error(L);
}

static int sc_log(lua_State* L) {
  ScRun* r = &sc_run;
  int argc = lua_gettop(L);
  if (argc < 2) {
    sc_push_error(L, "redis.log() requires two arguments or more.");
    return lua_error(L);
  } else if (!lua_isnumber(L, -argc)) {
    sc_push_error(L, "First argument must be a number (log level).");
    return lua_error(L);
  }
  int level = luai_num2int(lua_tonumber(L, -argc));
  if (level < SC_LL_DEBUG || level > SC_LL_WARNING) {
    sc_push_error(L, "Invalid debug level.");
    return lua_error(L);
  }
  if (!r->live) {
    return 0;
  }
  sc_buf_clear(&r->out);
  for (int j = 1; j < argc; j += 1) {
    size_t n;
    const char* s = lua_tolstring(L, -argc + j, &n);
    if (s != NULL) {
      if (j != 1) {
        sc_buf_add(&r->out, " ", 1);
      }
      sc_buf_add(&r->out, s, n);
    }
  }
  r->kind = SC_LOG;
  r->level = level;
  sc_yield(r);
  return 0;
}

static int sc_setresp(lua_State* L) {
  ScRun* r = &sc_run;
  if (!r->live) {
    sc_push_error(L, "redis.setresp can only be called inside a script invocation");
    return lua_error(L);
  }
  int argc = lua_gettop(L);
  if (argc != 1) {
    sc_push_error(L, "redis.setresp() requires one argument.");
    return lua_error(L);
  }
  int resp = luai_num2int(lua_tonumber(L, -argc));
  if (resp != 2 && resp != 3) {
    sc_push_error(L, "RESP version must be 2 or 3.");
    return lua_error(L);
  }
  r->resp = resp;
  return 0;
}

// redis.breakpoint and redis.debug: the debugger is never active
static int sc_breakpoint(lua_State* L) {
  lua_pushboolean(L, 0);
  return 1;
}

static int sc_debug(lua_State* L) {
  (void)L;
  return 0;
}

static int sc_replicate_commands(lua_State* L) {
  lua_pushboolean(L, 1);
  return 1;
}

// math.random and math.randomseed on Redis's own generator, the same
// sequence on every machine
static int sc_math_random(lua_State* L) {
  lua_Number r = (lua_Number)(redisLrand48() % REDIS_LRAND48_MAX) /
    (lua_Number)REDIS_LRAND48_MAX;
  switch (lua_gettop(L)) {
    case 0: {
      lua_pushnumber(L, r);
      break;
    }
    case 1: {
      int u = luaL_checkint(L, 1);
      luaL_argcheck(L, 1 <= u, 1, "interval is empty");
      lua_pushnumber(L, floor(r * u) + 1);
      break;
    }
    case 2: {
      int l = luaL_checkint(L, 1);
      int u = luaL_checkint(L, 2);
      luaL_argcheck(L, l <= u, 2, "interval is empty");
      lua_pushnumber(L, floor(r * (u - l + 1)) + l);
      break;
    }
    default: return luaL_error(L, "wrong number of arguments");
  }
  return 1;
}

static int sc_math_randomseed(lua_State* L) {
  redisSrand48(luaL_checkint(L, 1));
  return 0;
}

// The hook: every 100,000 instructions a tick for Bend, which answers
// "go on" or "kill"; a killed script's hook fires at every line from then
// on, so that pcall cannot keep it alive
static void sc_hook(lua_State* L, lua_Debug* ar) {
  (void)ar;
  ScRun* r = &sc_run;
  if (!r->killed) {
    r->kind = SC_TICK;
    sc_buf_clear(&r->out);
    sc_yield(r);
    if (r->verdict != 2) {
      return;
    }
    r->killed = 1;
    lua_sethook(L, sc_hook, LUA_MASKLINE, 0);
  }
  sc_push_error(L, "Script killed by user with SCRIPT KILL...");
  lua_error(L);
}

// The sandbox
// -----------

static const char* sc_libraries_allow_list[] = {
  "string", "cjson", "bit", "cmsgpack", "math", "table", "struct", NULL,
};

static const char* sc_redis_api_allow_list[] = {
  "redis", "__redis__err__handler", NULL,
};

static const char* sc_lua_builtins_allow_list[] = {
  "xpcall", "tostring", "setmetatable", "next", "assert",
  "tonumber", "rawequal", "collectgarbage", "getmetatable", "rawset",
  "pcall", "coroutine", "type", "_G", "select", "unpack", "gcinfo",
  "pairs", "rawget", "loadstring", "ipairs", "_VERSION",
  "load", "error", NULL,
};

// the builtins Redis 7.2 deprecates for the sandbox's sake: kept out of
// the globals unless lua-enable-deprecated-api is yes, which only the
// start sets (Engine.deprecated: the parameter is immutable), before any
// state is made
static const char* sc_lua_builtins_deprecated[] = {
  "newproxy", "setfenv", "getfenv", NULL,
};

static int sc_lua_enable_deprecated_api = 0;

static const char* sc_lua_builtins_removed_after_initialization_allow_list[] = {
  "debug", NULL,
};

static const char** sc_allow_lists[] = {
  sc_libraries_allow_list,
  sc_redis_api_allow_list,
  sc_lua_builtins_allow_list,
  sc_lua_builtins_removed_after_initialization_allow_list,
  NULL,
};

static int sc_protected_table_error(lua_State* L) {
  int argc = lua_gettop(L);
  if (argc != 2) {
    luaL_error(L, "Wrong number of arguments to luaProtectedTableError");
  }
  if (!lua_isstring(L, -1) && !lua_isnumber(L, -1)) {
    luaL_error(L, "Second argument to luaProtectedTableError must be a string or number");
  }
  const char* variable_name = lua_tostring(L, -1);
  luaL_error(L, "Script attempted to access nonexistent global variable '%s'", variable_name);
  return 0;
}

static void sc_set_error_metatable(lua_State* L) {
  lua_newtable(L);
  lua_pushcfunction(L, sc_protected_table_error);
  lua_setfield(L, -2, "__index");
  lua_setmetatable(L, -2);
}

// a global added while the engine is set up has to be on the allow lists
static int sc_new_index_allow_list(lua_State* L) {
  int argc = lua_gettop(L);
  if (argc != 3) {
    luaL_error(L, "Wrong number of arguments to luaNewIndexAllowList");
  }
  if (!lua_istable(L, -3)) {
    luaL_error(L, "first argument to luaNewIndexAllowList must be a table");
  }
  if (!lua_isstring(L, -2) && !lua_isnumber(L, -2)) {
    luaL_error(L, "Second argument to luaNewIndexAllowList must be a string or number");
  }
  const char* variable_name = lua_tostring(L, -2);
  const char*** allow_l = sc_allow_lists;
  for (; *allow_l; ++allow_l) {
    const char** c = *allow_l;
    for (; *c; ++c) {
      if (strcmp(*c, variable_name) == 0) {
        break;
      }
    }
    if (*c) {
      break;
    }
  }
  int allowed = (*allow_l != NULL);
  if (!allowed) {
    for (const char** c = sc_lua_builtins_deprecated; *c; ++c) {
      if (strcmp(*c, variable_name) == 0) {
        allowed = sc_lua_enable_deprecated_api;
        break;
      }
    }
  }
  if (allowed) {
    lua_rawset(L, -3);
  }
  return 0;
}

static void sc_set_allow_list_protection(lua_State* L) {
  lua_newtable(L);
  lua_pushcfunction(L, sc_new_index_allow_list);
  lua_setfield(L, -2, "__newindex");
  lua_setmetatable(L, -2);
}

// the table at the top, every table it reaches and their metatables
// made readonly
static void sc_set_table_protection_recursively(lua_State* L) {
  if (lua_isreadonlytable(L, -1)) {
    return;
  }
  lua_enablereadonlytable(L, -1, 1);
  lua_checkstack(L, 2);
  lua_pushnil(L);
  while (lua_next(L, -2)) {
    if (lua_istable(L, -1)) {
      sc_set_table_protection_recursively(L);
    }
    lua_pop(L, 1);
  }
  if (lua_getmetatable(L, -1)) {
    sc_set_table_protection_recursively(L);
    lua_pop(L, 1);
  }
}

// the metatables of the basic types (a string's, a number's and the
// others') made readonly, as Redis 7.2's luaSetTableProtectionForBasicTypes
// makes them (CVE-2025-46818: a script could change the string metatable
// that the next script, of another user, runs with)
static void sc_set_table_protection_for_basic_types(lua_State* L) {
  static const int types[] = {
    LUA_TSTRING, LUA_TNUMBER, LUA_TBOOLEAN, LUA_TNIL, LUA_TFUNCTION,
    LUA_TTHREAD, LUA_TLIGHTUSERDATA,
  };
  for (size_t i = 0; i < sizeof(types) / sizeof(types[0]); i += 1) {
    switch (types[i]) {
      case LUA_TSTRING: lua_pushstring(L, ""); break;
      case LUA_TNUMBER: lua_pushnumber(L, 0); break;
      case LUA_TBOOLEAN: lua_pushboolean(L, 0); break;
      case LUA_TNIL: lua_pushnil(L); break;
      case LUA_TFUNCTION: lua_pushcfunction(L, NULL); break;
      case LUA_TTHREAD: lua_newthread(L); break;
      case LUA_TLIGHTUSERDATA: lua_pushlightuserdata(L, (void*)L); break;
    }
    if (lua_getmetatable(L, -1)) {
      sc_set_table_protection_recursively(L);
      lua_pop(L, 1);
    }
    lua_pop(L, 1);
  }
}

static void sc_load_lib(lua_State* L, const char* libname, lua_CFunction luafunc) {
  lua_pushcfunction(L, luafunc);
  lua_pushstring(L, libname);
  lua_call(L, 1, 0);
}

LUALIB_API int (luaopen_cjson) (lua_State *L);
LUALIB_API int (luaopen_struct) (lua_State *L);
LUALIB_API int (luaopen_cmsgpack) (lua_State *L);
LUALIB_API int (luaopen_bit) (lua_State *L);

static void sc_load_libraries(lua_State* L) {
  sc_load_lib(L, "", luaopen_base);
  sc_load_lib(L, LUA_TABLIBNAME, luaopen_table);
  sc_load_lib(L, LUA_STRLIBNAME, luaopen_string);
  sc_load_lib(L, LUA_MATHLIBNAME, luaopen_math);
  sc_load_lib(L, LUA_DBLIBNAME, luaopen_debug);
  sc_load_lib(L, "cjson", luaopen_cjson);
  sc_load_lib(L, "struct", luaopen_struct);
  sc_load_lib(L, "cmsgpack", luaopen_cmsgpack);
  sc_load_lib(L, "bit", luaopen_bit);
}

static void sc_set_field_fn(lua_State* L, const char* name, lua_CFunction fn) {
  lua_pushstring(L, name);
  lua_pushcfunction(L, fn);
  lua_settable(L, -3);
}

static void sc_set_field_num(lua_State* L, const char* name, lua_Number n) {
  lua_pushstring(L, name);
  lua_pushnumber(L, n);
  lua_settable(L, -3);
}

// REDIS_VERSION and REDIS_VERSION_NUM, those of the Redis BendKV answers
// as (7.2.16: its version_num is 0x00070210)
#define SC_REDIS_VERSION "7.2.16"
#define SC_REDIS_VERSION_NUM 0x00070210

// luaRegisterRedisAPI, and with eval scriptingInit's additions (the
// debugger's breakpoint and debug, replicate_commands), which the
// functions' state has not
static void sc_register_redis_api(lua_State* L, int eval) {
  lua_pushvalue(L, LUA_GLOBALSINDEX);
  sc_set_allow_list_protection(L);
  lua_pop(L, 1);

  sc_load_libraries(L);

  lua_pushcfunction(L, sc_lua_pcall);
  lua_setglobal(L, "pcall");

  lua_newtable(L);
  sc_set_field_fn(L, "call", sc_call);
  sc_set_field_fn(L, "pcall", sc_pcall);
  sc_set_field_fn(L, "log", sc_log);
  sc_set_field_num(L, "LOG_DEBUG", SC_LL_DEBUG);
  sc_set_field_num(L, "LOG_VERBOSE", SC_LL_VERBOSE);
  sc_set_field_num(L, "LOG_NOTICE", SC_LL_NOTICE);
  sc_set_field_num(L, "LOG_WARNING", SC_LL_WARNING);
  sc_set_field_num(L, "REDIS_VERSION_NUM", SC_REDIS_VERSION_NUM);
  lua_pushstring(L, "REDIS_VERSION");
  lua_pushstring(L, SC_REDIS_VERSION);
  lua_settable(L, -3);
  sc_set_field_fn(L, "setresp", sc_setresp);
  sc_set_field_fn(L, "sha1hex", sc_sha1hex_command);
  sc_set_field_fn(L, "error_reply", sc_error_reply);
  sc_set_field_fn(L, "status_reply", sc_status_reply);
  sc_set_field_fn(L, "set_repl", sc_set_repl);
  sc_set_field_num(L, "REPL_NONE", 0);
  sc_set_field_num(L, "REPL_AOF", SC_REPL_AOF);
  sc_set_field_num(L, "REPL_SLAVE", SC_REPL_REPLICA);
  sc_set_field_num(L, "REPL_REPLICA", SC_REPL_REPLICA);
  sc_set_field_num(L, "REPL_ALL", SC_REPL_AOF | SC_REPL_REPLICA);
  sc_set_field_fn(L, "acl_check_cmd", sc_acl_check_cmd);
  if (eval) {
    // eval.c's additions
    sc_set_field_fn(L, "breakpoint", sc_breakpoint);
    sc_set_field_fn(L, "debug", sc_debug);
    sc_set_field_fn(L, "replicate_commands", sc_replicate_commands);
  }
  lua_setglobal(L, "redis");

  lua_getglobal(L, "math");
  sc_set_field_fn(L, "random", sc_math_random);
  sc_set_field_fn(L, "randomseed", sc_math_randomseed);
  lua_setglobal(L, "math");
}

// scriptingInit: the state with the API, the error handler (which keeps
// the debug library for itself and takes it from the globals), and the
// globals locked
static void sc_init_state(void) {
  lua_State* L = lua_open();
  sc_register_redis_api(L, 1);
  {
    const char* errh_func =
      "local dbg = debug\n"
      "debug = nil\n"
      "function __redis__err__handler(err)\n"
      "  local i = dbg.getinfo(2,'nSl')\n"
      "  if i and i.what == 'C' then\n"
      "    i = dbg.getinfo(3,'nSl')\n"
      "  end\n"
      "  if type(err) ~= 'table' then\n"
      "    err = {err='ERR ' .. tostring(err)}"
      "  end"
      "  if i then\n"
      "    err['source'] = i.source\n"
      "    err['line'] = i.currentline\n"
      "  end"
      "  return err\n"
      "end\n";
    luaL_loadbuffer(L, errh_func, strlen(errh_func), "@err_handler_def");
    lua_pcall(L, 0, 0, 0);
  }
  lua_pushvalue(L, LUA_GLOBALSINDEX);
  sc_set_error_metatable(L);
  sc_set_table_protection_recursively(L);
  lua_pop(L, 1);
  sc_set_table_protection_for_basic_types(L);
  sc_lua = L;
}

static void sc_ensure(void) {
  if (sc_lua == NULL) {
    sc_init_state();
  }
  if (sc_run.stack == NULL) {
    size_t page = 4096;
    size_t size = SC_STACK_SIZE + page;
    void* p = mmap(NULL, size, PROT_READ | PROT_WRITE,
      MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (p == MAP_FAILED) {
      err_fail("mmap of the script stack");
    }
    // a guard page under the stack
    mprotect(p, page, PROT_NONE);
    sc_run.stack = (char*)p + page;
    sc_run.stack_size = SC_STACK_SIZE;
  }
}

// The shebang and the cache
// -------------------------

// sdssplitargs: a line split into arguments as a REPL splits them, with
// "..." and '...' and their escapes; NULL on unbalanced quotes. Each one
// ends with a NUL; with lens, *lens holds their lengths, which count the
// bytes after a NUL that an escape put in one ("\x00")
static char** sc_split(const char* line, int* argc, size_t** lens) {
  const char* p = line;
  ScBuf current = { 0 };
  int have = 0;
  char** vector = NULL;
  size_t* lv = NULL;
  *argc = 0;
  for (;;) {
    while (*p && isspace((unsigned char)*p)) p++;
    if (*p) {
      int inq = 0, insq = 0, done = 0;
      sc_buf_clear(&current);
      sc_buf_room(&current, 1);
      have = 1;
      while (!done) {
        if (inq) {
          if (*p == '\\' && *(p + 1) == 'x' && sc_hex_digit(*(p + 2)) >= 0 &&
              sc_hex_digit(*(p + 3)) >= 0) {
            char byte = (char)(sc_hex_digit(*(p + 2)) * 16 + sc_hex_digit(*(p + 3)));
            sc_buf_add(&current, &byte, 1);
            p += 3;
          } else if (*p == '\\' && *(p + 1)) {
            char c;
            p++;
            switch (*p) {
            case 'n': c = '\n'; break;
            case 'r': c = '\r'; break;
            case 't': c = '\t'; break;
            case 'b': c = '\b'; break;
            case 'a': c = '\a'; break;
            default: c = *p; break;
            }
            sc_buf_add(&current, &c, 1);
          } else if (*p == '"') {
            if (*(p + 1) && !isspace((unsigned char)*(p + 1))) goto err;
            done = 1;
          } else if (!*p) {
            goto err;
          } else {
            sc_buf_add(&current, p, 1);
          }
        } else if (insq) {
          if (*p == '\\' && *(p + 1) == '\'') {
            p++;
            sc_buf_add(&current, "'", 1);
          } else if (*p == '\'') {
            if (*(p + 1) && !isspace((unsigned char)*(p + 1))) goto err;
            done = 1;
          } else if (!*p) {
            goto err;
          } else {
            sc_buf_add(&current, p, 1);
          }
        } else {
          switch (*p) {
          case ' ':
          case '\n':
          case '\r':
          case '\t':
          case '\0':
            done = 1;
            break;
          case '"':
            inq = 1;
            break;
          case '\'':
            insq = 1;
            break;
          default:
            sc_buf_add(&current, p, 1);
            break;
          }
        }
        if (*p) p++;
      }
      vector = io_mem(realloc(vector, ((size_t)*argc + 1) * sizeof(char*)));
      lv = io_mem(realloc(lv, ((size_t)*argc + 1) * sizeof(size_t)));
      vector[*argc] = io_mem(malloc(current.n + 1));
      memcpy(vector[*argc], current.p, current.n);
      vector[*argc][current.n] = '\0';
      lv[*argc] = current.n;
      (*argc)++;
    } else {
      free(current.p);
      if (vector == NULL) vector = io_mem(malloc(sizeof(void*)));
      if (lens != NULL) {
        *lens = lv;
      } else {
        free(lv);
      }
      return vector;
    }
  }
err:
  while ((*argc)--) free(vector[*argc]);
  free(vector);
  free(lv);
  if (have) free(current.p);
  *argc = 0;
  return NULL;
}

static void sc_split_free(char** v, int n) {
  if (v == NULL) return;
  for (int i = 0; i < n; i += 1) free(v[i]);
  free(v);
}

typedef struct {
  uint32_t flag;
  const char* str;
} ScFlagDef;

static const ScFlagDef sc_flags_def[] = {
  { SC_FLAG_NO_WRITES, "no-writes" },
  { SC_FLAG_ALLOW_OOM, "allow-oom" },
  { SC_FLAG_ALLOW_STALE, "allow-stale" },
  { SC_FLAG_NO_CLUSTER, "no-cluster" },
  { SC_FLAG_ALLOW_CROSS_SLOT, "allow-cross-slot-keys" },
  { 0, NULL },
};

// evalExtractShebangFlags: the flags of a body's "#!lua" line, EVAL_COMPAT
// without one; 0 with the error's text in err when the line is wrong
static int sc_shebang_flags(const char* body, size_t len, uint32_t* out_flags,
  size_t* out_shebang_len, ScBuf* err) {
  size_t shebang_len = 0;
  uint32_t flags = SC_FLAG_EVAL_COMPAT_MODE;
  if (len >= 2 && strncmp(body, "#!", 2) == 0) {
    const char* end = memchr(body, '\n', strnlen(body, len));
    if (end == NULL) {
      sc_buf_str(err, "Invalid script shebang");
      return 0;
    }
    shebang_len = (size_t)(end - body);
    char* shebang = io_mem(malloc(shebang_len + 1));
    memcpy(shebang, body, shebang_len);
    shebang[shebang_len] = '\0';
    int numparts;
    char** parts = sc_split(shebang, &numparts, NULL);
    free(shebang);
    if (parts == NULL || numparts == 0) {
      sc_buf_str(err, "Invalid engine in script shebang");
      sc_split_free(parts, numparts);
      return 0;
    }
    if (strcmp(parts[0], "#!lua") != 0) {
      sc_buf_fmt(err, "Unexpected engine in script shebang: %s", parts[0]);
      sc_split_free(parts, numparts);
      return 0;
    }
    flags &= ~SC_FLAG_EVAL_COMPAT_MODE;
    for (int j = 1; j < numparts; j += 1) {
      if (strncmp(parts[j], "flags=", 6) == 0) {
        char* list = parts[j] + 6;
        char* save = NULL;
        // the flags between the commas, an empty one taken as "" (as
        // sdssplitlen gives it), which no flag matches; an empty list
        // holds none (sdssplitlen gives no element)
        char* copy = sc_strdup(list);
        char* at = copy;
        int bad = 0;
        for (; copy[0] != '\0';) {
          char* comma = strchr(at, ',');
          if (comma != NULL) *comma = '\0';
          const ScFlagDef* sf;
          for (sf = sc_flags_def; sf->flag; sf++) {
            if (strcmp(at, sf->str) == 0) break;
          }
          if (!sf->flag) {
            sc_buf_fmt(err, "Unexpected flag in script shebang: %s", at);
            bad = 1;
            break;
          }
          flags |= sf->flag;
          if (comma == NULL) break;
          at = comma + 1;
        }
        (void)save;
        free(copy);
        if (bad) {
          sc_split_free(parts, numparts);
          return 0;
        }
      } else {
        sc_buf_fmt(err, "Unknown lua shebang option: %s", parts[j]);
        sc_split_free(parts, numparts);
        return 0;
      }
    }
    sc_split_free(parts, numparts);
  }
  if (out_shebang_len) *out_shebang_len = shebang_len;
  *out_flags = flags;
  return 1;
}

// luaCreateFunction: the script compiled and cached under its sha; 1 and
// the sha and flags, or 0 and an error's text ("ERR ...")
static int sc_create_function(const char* body, size_t len, char* sha_out,
  uint32_t* flags_out, ScBuf* err) {
  char funcname[43];
  funcname[0] = 'f';
  funcname[1] = '_';
  sc_sha1hex(funcname + 2, body, len);
  uint8_t bin[20];
  sc_hex_to_bin(funcname + 2, 40, bin);
  ScScript* have = sc_script_find(bin);
  if (have != NULL) {
    memcpy(sha_out, funcname + 2, 41);
    *flags_out = have->flags;
    return 1;
  }
  size_t shebang_len = 0;
  uint32_t flags;
  ScBuf reason = { 0 };
  if (!sc_shebang_flags(body, len, &flags, &shebang_len, &reason)) {
    sc_buf_str(err, "ERR ");
    sc_buf_add(err, reason.p, reason.n);
    free(reason.p);
    return 0;
  }
  lua_State* L = sc_lua;
  if (luaL_loadbuffer(L, body + shebang_len, len - shebang_len, "@user_script")) {
    sc_buf_fmt(err, "ERR Error compiling script (new function): %s", lua_tostring(L, -1));
    lua_pop(L, 1);
    return 0;
  }
  lua_setfield(L, LUA_REGISTRYINDEX, funcname);
  sc_script_add(bin, body, len, flags);
  memcpy(sha_out, funcname + 2, 41);
  *flags_out = flags;
  return 1;
}

// Running a script
// ----------------

// the elements of a RESP array of bulk strings, as a Lua table (a
// request's arguments as Bend sends them)
static void sc_push_array(lua_State* L, const char* p, size_t n) {
  lua_newtable(L);
  const char* end = p + n;
  if (n == 0 || p[0] != '*') {
    return;
  }
  long long count = 0;
  const char* q = memchr(p, '\r', n);
  if (q == NULL || !string2ll(p + 1, (size_t)(q - p - 1), &count)) {
    return;
  }
  p = q + 2;
  for (long long j = 0; j < count && p < end && p[0] == '$'; j += 1) {
    long long len;
    q = memchr(p, '\r', (size_t)(end - p));
    if (q == NULL || !string2ll(p + 1, (size_t)(q - p - 1), &len) || len < 0) {
      return;
    }
    p = q + 2;
    if (p + len + 2 > end) {
      return;
    }
    lua_pushlstring(L, p, (size_t)len);
    lua_rawseti(L, -2, (int)j + 1);
    p += len + 2;
  }
}

static void sc_set_global_array(lua_State* L, const char* name, const char* p,
  size_t n) {
  sc_push_array(L, p, n);
  lua_enablereadonlytable(L, LUA_GLOBALSINDEX, 0);
  lua_setglobal(L, name);
  lua_enablereadonlytable(L, LUA_GLOBALSINDEX, 1);
}

// the end of a run of a script or a function (luaCallFunction's): Lua's
// stack holds the error handler and the run's result or error, which
// become the reply in the caller's protocol, or an error in Redis's
// words, with name the script's sha or the function's name
static void sc_finish(ScRun* r, lua_State* L, int err, const char* name) {
  {
    sc_gc_count += 1;
    if (sc_gc_count == 50) {
      lua_gc(L, LUA_GCSTEP, 50);
      sc_gc_count = 0;
    }
    sc_buf_clear(&r->out);
    if (err) {
      r->err = 1;
      if (!lua_istable(L, -1)) {
        const char* msg = "execution failure";
        if (lua_isstring(L, -1)) {
          msg = lua_tostring(L, -1);
        }
        sc_buf_fmt(&r->out, "ERR Error running script %s, %.100s", name, msg);
      } else {
        ScErrInfo info;
        sc_err_info(L, &info);
        sc_buf_str(&r->out, info.msg != NULL ? info.msg : "ERR execution failure");
        if (info.line != NULL && info.source != NULL) {
          sc_buf_fmt(&r->out, " script: %s, on ", name);
          sc_buf_str(&r->out, info.source);
          sc_buf_add(&r->out, ":", 1);
          sc_buf_str(&r->out, info.line);
          sc_buf_add(&r->out, ".", 1);
        }
        r->nostats = info.ignore;
        sc_err_info_free(&info);
      }
      // with every "\r" and "\n" a space, as addReplyErrorFormat and
      // Redis 7.2's addReplyErrorSdsExSafe send it (7.0 sent the second
      // kind as it came, a newline in it breaking the protocol)
      sc_one_line(r->out.p, r->out.n);
      lua_pop(L, 1);
    } else if (lua_istable(L, -1) && (lua_pushstring(L, "err"), lua_rawget(L, -2),
        lua_type(L, -1) == LUA_TSTRING ? (lua_pop(L, 1), 1) : (lua_pop(L, 1), 0))) {
      // an error returned (redis.error_reply, a pcall's error): the
      // reply is the error, counted unless a call made it
      ScErrInfo info;
      sc_err_info(L, &info);
      size_t n = strlen(info.msg);
      while (n > 0 && (info.msg[n - 1] == '\r' || info.msg[n - 1] == '\n')) {
        n -= 1;
      }
      sc_one_line(info.msg, n);
      sc_buf_add(&r->out, info.msg, n);
      r->err = 1;
      r->nostats = info.ignore;
      sc_err_info_free(&info);
      lua_pop(L, 1);
    } else {
      sc_lua_to_reply(r, L, &r->out);
    }
    lua_pop(L, 1);
    lua_sethook(L, NULL, 0, 0);
  }
}

// a run of an EVAL's script, on the script's stack: evalGenericCommand's
// part of luaCallFunction
static void sc_main_script(ScRun* r) {
  lua_State* L = sc_lua;
  r->err = 0;
  r->nostats = 0;
  lua_getglobal(L, "__redis__err__handler");
  lua_getfield(L, LUA_REGISTRYINDEX, r->funcname);
  if (lua_isnil(L, -1)) {
    lua_pop(L, 2);
    sc_buf_clear(&r->out);
    sc_buf_str(&r->out, "NOSCRIPT No matching script. Please use EVAL.");
    r->err = 1;
    return;
  }
  lua_sethook(L, sc_hook, LUA_MASKCOUNT, 100000);
  sc_set_global_array(L, "KEYS", r->keys, r->keys_len);
  sc_set_global_array(L, "ARGV", r->args, r->args_len);
  int err = lua_pcall(L, 0, 1, -2);
  sc_finish(r, L, err, r->funcname + 2);
}

// Functions
// ---------
// FUNCTION and FCALL, as Redis 7.2.16 has them (functions.c and
// function_lua.c). A library is its code, whose first line names it
// ("#!lua name=<library>"), and the functions its code registered with
// redis.register_function when FUNCTION LOAD ran it; FCALL calls a
// function by its name, which no two libraries share (case set aside).
// The libraries live in a Lua state of their own (fn_lua), with the
// scripts' API but for EVAL's debugger. A library's code runs once, at
// its load, with the globals' lookups sent to the library API (a table of
// redis.register_function, redis.log and the version alone) and FUNCTION
// LOAD's 500 ms limit; a function runs as a script does, with the real
// globals, its keys and arguments as its two parameters. Redis keeps the
// libraries and functions in dicts, which it walks in the order of their
// hashes, under a seed drawn at its start: BendKV keeps them in the order
// they were loaded and registered, one of the orders Redis can give.

typedef struct FnLib FnLib;

typedef struct {
  char* name;          // as it was registered
  char* desc;          // NULL for none
  uint32_t flags;      // SC_FLAG_* of its flags
  int ref;             // its callback, in fn_lua's registry
  FnLib* lib;
} FnFunc;

struct FnLib {
  char* name;
  char* code;          // the whole payload, its first line included
  size_t code_len;
  FnFunc** fs;
  int n;
};

// a set of libraries (functionsLibCtx): the server's, or one a RESTORE
// fills before it takes it in
typedef struct {
  FnLib** libs;
  int n;
} FnCtx;

#define FN_LIBRARY_API "__LIBRARY_API__"
#define FN_GLOBALS_API "__GLOBALS_API__"
#define FN_ERROR_HANDLER "__ERROR_HANDLER__"
#define FN_LOAD_TIMEOUT_MS 500

static lua_State* fn_lua;
static FnCtx      fn_cur;
static FnLib*     fn_loading;      // the library a load runs the code of
static uint64_t   fn_load_start;   // when it started, in ms
static int        fn_load_timed;   // whether FUNCTION LOAD's limit holds it

static uint64_t fn_now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

static void fn_func_free(lua_State* L, FnFunc* f) {
  if (L != NULL) {
    lua_unref(L, f->ref);
  }
  free(f->name);
  free(f->desc);
  free(f);
}

static void fn_lib_free(FnLib* li) {
  if (li == NULL) {
    return;
  }
  for (int j = 0; j < li->n; j += 1) {
    fn_func_free(fn_lua, li->fs[j]);
  }
  free(li->fs);
  free(li->name);
  free(li->code);
  free(li);
}

static void fn_ctx_clear(FnCtx* ctx) {
  for (int i = 0; i < ctx->n; i += 1) {
    fn_lib_free(ctx->libs[i]);
  }
  free(ctx->libs);
  ctx->libs = NULL;
  ctx->n = 0;
}

// the library of this name (exactly: Redis's librariesDictType)
static FnLib* fn_lib_find(FnCtx* ctx, const char* name, size_t len) {
  for (int i = 0; i < ctx->n; i += 1) {
    FnLib* li = ctx->libs[i];
    if (strlen(li->name) == len && memcmp(li->name, name, len) == 0) {
      return li;
    }
  }
  return NULL;
}

// the function of this name, in any case (functionDictType)
static FnFunc* fn_find(FnCtx* ctx, const char* name, size_t len) {
  for (int i = 0; i < ctx->n; i += 1) {
    FnLib* li = ctx->libs[i];
    for (int j = 0; j < li->n; j += 1) {
      FnFunc* f = li->fs[j];
      if (strlen(f->name) == len && strncasecmp(f->name, name, len) == 0) {
        return f;
      }
    }
  }
  return NULL;
}

static int fn_count(FnCtx* ctx) {
  int n = 0;
  for (int i = 0; i < ctx->n; i += 1) {
    n += ctx->libs[i]->n;
  }
  return n;
}

// libraryLink and libraryUnlink: a library taken in and out of a set
static void fn_link(FnCtx* ctx, FnLib* li) {
  ctx->libs = io_mem(realloc(ctx->libs, ((size_t)ctx->n + 1) * sizeof(FnLib*)));
  ctx->libs[ctx->n] = li;
  ctx->n += 1;
}

static void fn_unlink(FnCtx* ctx, FnLib* li) {
  for (int i = 0; i < ctx->n; i += 1) {
    if (ctx->libs[i] == li) {
      memmove(ctx->libs + i, ctx->libs + i + 1, (size_t)(ctx->n - i - 1) * sizeof(FnLib*));
      ctx->n -= 1;
      return;
    }
  }
}

// functionsVerifyName: [a-zA-Z0-9_]+
static int fn_name_ok(const char* s, size_t n) {
  if (n == 0) {
    return 0;
  }
  for (size_t i = 0; i < n; i += 1) {
    char c = s[i];
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_')) {
      return 0;
    }
  }
  return 1;
}

// The library API
// ...............

// luaRegisterFunctionReadFlags: the flags of the table on the top
static int fn_read_flags(lua_State* L, uint32_t* out) {
  int j = 1;
  uint32_t flags = 0;
  for (;;) {
    lua_pushnumber(L, j++);
    lua_gettable(L, -2);
    int t = lua_type(L, -1);
    if (t == LUA_TNIL) {
      lua_pop(L, 1);
      break;
    }
    if (!lua_isstring(L, -1)) {
      lua_pop(L, 1);
      return 0;
    }
    const char* str = lua_tostring(L, -1);
    int found = 0;
    for (const ScFlagDef* flag = sc_flags_def; flag->str; ++flag) {
      if (!strcasecmp(flag->str, str)) {
        flags |= flag->flag;
        found = 1;
        break;
      }
    }
    lua_pop(L, 1);
    if (!found) {
      return 0;
    }
  }
  *out = flags;
  return 1;
}

// a Lua string as bytes (luaGetStringSds), its length in len; NULL for
// a value that is no string
static char* fn_lua_string(lua_State* L, int index, size_t* len) {
  if (!lua_isstring(L, index)) {
    return NULL;
  }
  size_t n;
  const char* str = lua_tolstring(L, index, &n);
  char* out = io_mem(malloc(n + 1));
  memcpy(out, str, n);
  out[n] = '\0';
  if (len != NULL) {
    *len = n;
  }
  return out;
}

typedef struct {
  char* name;
  size_t name_len;     // its bytes, a NUL among them (functionsVerifyName)
  char* desc;
  int ref;             // LUA_NOREF for none
  uint32_t flags;
} FnArgs;

static void fn_args_free(lua_State* L, FnArgs* a) {
  free(a->name);
  free(a->desc);
  if (a->ref != LUA_NOREF) {
    lua_unref(L, a->ref);
  }
  a->name = NULL;
  a->desc = NULL;
  a->ref = LUA_NOREF;
}

// luaRegisterFunctionReadNamedArgs: redis.register_function{...}
static const char* fn_read_named(lua_State* L, FnArgs* a) {
  if (!lua_istable(L, 1)) {
    return "calling redis.register_function with a single argument is only applicable to Lua table (representing named arguments).";
  }
  lua_pushnil(L);
  while (lua_next(L, -2)) {
    if (!lua_isstring(L, -2)) {
      return "named argument key given to redis.register_function is not a string";
    }
    const char* key = lua_tostring(L, -2);
    if (!strcasecmp(key, "function_name")) {
      free(a->name);
      if (!(a->name = fn_lua_string(L, -1, &a->name_len))) {
        return "function_name argument given to redis.register_function must be a string";
      }
    } else if (!strcasecmp(key, "description")) {
      free(a->desc);
      if (!(a->desc = fn_lua_string(L, -1, NULL))) {
        return "description argument given to redis.register_function must be a string";
      }
    } else if (!strcasecmp(key, "callback")) {
      if (!lua_isfunction(L, -1)) {
        return "callback argument given to redis.register_function must be a function";
      }
      // Redis keeps the last callback's ref and leaks the one before
      a->ref = luaL_ref(L, LUA_REGISTRYINDEX);
      continue;
    } else if (!strcasecmp(key, "flags")) {
      if (!lua_istable(L, -1)) {
        return "flags argument to redis.register_function must be a table representing function flags";
      }
      if (!fn_read_flags(L, &a->flags)) {
        return "unknown flag given";
      }
    } else {
      return "unknown argument given to redis.register_function";
    }
    lua_pop(L, 1);
  }
  if (a->name == NULL) {
    return "redis.register_function must get a function name argument";
  }
  if (a->ref == LUA_NOREF) {
    return "redis.register_function must get a callback argument";
  }
  return NULL;
}

// luaRegisterFunctionReadPositionalArgs: redis.register_function(name, f)
static const char* fn_read_positional(lua_State* L, FnArgs* a) {
  if (!(a->name = fn_lua_string(L, 1, &a->name_len))) {
    return "first argument to redis.register_function must be a string";
  }
  if (!lua_isfunction(L, 2)) {
    return "second argument to redis.register_function must be a function";
  }
  a->ref = luaL_ref(L, LUA_REGISTRYINDEX);
  return NULL;
}

// redis.register_function (luaRegisterFunction, functionLibCreateFunction)
static int fn_register(lua_State* L) {
  FnLib* li = fn_loading;
  if (li == NULL) {
    sc_push_error(L, "redis.register_function can only be called on FUNCTION LOAD command");
    return lua_error(L);
  }
  FnArgs a = { NULL, 0, NULL, LUA_NOREF, 0 };
  int argc = lua_gettop(L);
  const char* err = NULL;
  if (argc < 1 || argc > 2) {
    err = "wrong number of arguments to redis.register_function";
  } else if (argc == 1) {
    err = fn_read_named(L, &a);
  } else {
    err = fn_read_positional(L, &a);
  }
  if (err == NULL && !fn_name_ok(a.name, a.name_len)) {
    err = "Library names can only contain letters, numbers, or underscores(_) and must be at least one character long";
  }
  if (err == NULL) {
    for (int j = 0; j < li->n; j += 1) {
      if (strcmp(li->fs[j]->name, a.name) == 0) {
        err = "Function already exists in the library";
        break;
      }
    }
  }
  if (err != NULL) {
    fn_args_free(L, &a);
    sc_push_error(L, err);
    return lua_error(L);
  }
  FnFunc* f = io_mem(malloc(sizeof(FnFunc)));
  f->name = a.name;
  f->desc = a.desc;
  f->flags = a.flags;
  f->ref = a.ref;
  f->lib = li;
  li->fs = io_mem(realloc(li->fs, ((size_t)li->n + 1) * sizeof(FnFunc*)));
  li->fs[li->n] = f;
  li->n += 1;
  return 0;
}

// luaEngineLoadHook: FUNCTION LOAD's limit
static void fn_load_hook(lua_State* L, lua_Debug* ar) {
  (void)ar;
  uint64_t duration = fn_now_ms() - fn_load_start;
  if (fn_load_timed && duration > FN_LOAD_TIMEOUT_MS) {
    lua_sethook(L, fn_load_hook, LUA_MASKLINE, 0);
    sc_push_error(L, "FUNCTION LOAD timeout");
    lua_error(L);
  }
}

// luaEngineInitEngine: the state, the library API, the error handler and
// the globals, made readonly behind a table of globals of their own
static void fn_init_state(void) {
  lua_State* L = lua_open();
  sc_register_redis_api(L, 0);

  lua_newtable(L);  // the library API's globals
  lua_newtable(L);  // its redis table
  lua_pushstring(L, "register_function");
  lua_pushcfunction(L, fn_register);
  lua_settable(L, -3);
  sc_set_field_fn(L, "log", sc_log);
  sc_set_field_num(L, "LOG_DEBUG", SC_LL_DEBUG);
  sc_set_field_num(L, "LOG_VERBOSE", SC_LL_VERBOSE);
  sc_set_field_num(L, "LOG_NOTICE", SC_LL_NOTICE);
  sc_set_field_num(L, "LOG_WARNING", SC_LL_WARNING);
  sc_set_field_num(L, "REDIS_VERSION_NUM", SC_REDIS_VERSION_NUM);
  lua_pushstring(L, "REDIS_VERSION");
  lua_pushstring(L, SC_REDIS_VERSION);
  lua_settable(L, -3);
  sc_set_error_metatable(L);
  lua_setfield(L, -2, "redis");
  sc_set_error_metatable(L);
  sc_set_table_protection_recursively(L);
  lua_setfield(L, LUA_REGISTRYINDEX, FN_LIBRARY_API);

  lua_pushstring(L, FN_ERROR_HANDLER);
  const char* errh_func =
    "local dbg = debug\n"
    "debug = nil\n"
    "local error_handler = function (err)\n"
    "  local i = dbg.getinfo(2,'nSl')\n"
    "  if i and i.what == 'C' then\n"
    "    i = dbg.getinfo(3,'nSl')\n"
    "  end\n"
    "  if type(err) ~= 'table' then\n"
    "    err = {err='ERR ' .. tostring(err)}"
    "  end"
    "  if i then\n"
    "    err['source'] = i.source\n"
    "    err['line'] = i.currentline\n"
    "  end"
    "  return err\n"
    "end\n"
    "return error_handler";
  luaL_loadbuffer(L, errh_func, strlen(errh_func), "@err_handler_def");
  lua_pcall(L, 0, 1, 0);
  lua_settable(L, LUA_REGISTRYINDEX);

  lua_pushvalue(L, LUA_GLOBALSINDEX);
  sc_set_error_metatable(L);
  sc_set_table_protection_recursively(L);
  lua_pop(L, 1);

  lua_pushvalue(L, LUA_GLOBALSINDEX);
  lua_setfield(L, LUA_REGISTRYINDEX, FN_GLOBALS_API);

  lua_newtable(L);  // the new globals
  lua_newtable(L);  // and their metatable
  lua_pushvalue(L, LUA_GLOBALSINDEX);
  lua_setfield(L, -2, "__index");
  lua_enablereadonlytable(L, -1, 1);
  lua_setmetatable(L, -2);
  lua_enablereadonlytable(L, -1, 1);
  lua_replace(L, LUA_GLOBALSINDEX);
  sc_set_table_protection_for_basic_types(L);
  fn_lua = L;
}

static void fn_ensure(void) {
  if (fn_lua == NULL) {
    fn_init_state();
  }
}

// the globals' lookups sent to the library API (or the real globals
// again), as luaEngineCreate sends them: it lifts the protection of the
// globals' metatable and sets it on the globals, which have it already,
// so the metatable stays writable after a first load, as in Redis
static void fn_globals_to(lua_State* L, const char* api) {
  lua_getmetatable(L, LUA_GLOBALSINDEX);
  lua_enablereadonlytable(L, -1, 0);
  lua_getfield(L, LUA_REGISTRYINDEX, api);
  lua_setfield(L, -2, "__index");
  lua_enablereadonlytable(L, LUA_GLOBALSINDEX, 1);
  lua_pop(L, 1);
}

// luaEngineCreate: the library's code compiled and run, its functions
// registered into li; 1, or 0 and the error's text
static int fn_engine_create(FnLib* li, const char* body, size_t len, int timed, ScBuf* err) {
  lua_State* L = fn_lua;
  int ok = 0;
  fn_globals_to(L, FN_LIBRARY_API);
  if (luaL_loadbuffer(L, body, len, "@user_function")) {
    sc_buf_fmt(err, "Error compiling function: %s", lua_tostring(L, -1));
    lua_pop(L, 1);
    goto done;
  }
  fn_loading = li;
  fn_load_start = fn_now_ms();
  fn_load_timed = timed;
  lua_sethook(L, fn_load_hook, LUA_MASKCOUNT, 100000);
  if (lua_pcall(L, 0, 0, 0)) {
    ScErrInfo info;
    sc_err_info(L, &info);
    sc_buf_fmt(err, "Error registering functions: %s", info.msg != NULL ? info.msg : "");
    sc_err_info_free(&info);
    lua_pop(L, 1);
    goto done;
  }
  ok = 1;
done:
  fn_globals_to(L, FN_GLOBALS_API);
  lua_sethook(L, NULL, 0, 0);
  fn_loading = NULL;
  return ok;
}

// functionExtractLibMetaData and functionsCreateWithLibraryCtx: a library
// made from its payload into ctx, the one of the same name there replaced
// if replace; 1, or 0 and the error's text, ctx as it was
static int fn_create(const char* code, size_t n, int replace, FnCtx* ctx, int timed, ScBuf* err) {
  if (n < 2 || strncmp(code, "#!", 2) != 0) {
    sc_buf_str(err, "Missing library metadata");
    return 0;
  }
  const char* end = memchr(code, '\n', strnlen(code, n));
  if (end == NULL) {
    sc_buf_str(err, "Invalid library metadata");
    return 0;
  }
  size_t shebang_len = (size_t)(end - code);
  char* shebang = io_mem(malloc(shebang_len + 1));
  memcpy(shebang, code, shebang_len);
  shebang[shebang_len] = '\0';
  int numparts = 0;
  size_t* lens = NULL;
  char** parts = sc_split(shebang, &numparts, &lens);
  free(shebang);
  if (parts == NULL || numparts == 0) {
    sc_buf_str(err, "Invalid library metadata");
    sc_split_free(parts, numparts);
    free(lens);
    return 0;
  }
  char* name = NULL;
  size_t name_len = 0;
  int ok = 0;
  for (int i = 1; i < numparts; i += 1) {
    if (strncasecmp(parts[i], "name=", 5) == 0) {
      if (name != NULL) {
        sc_buf_str(err, "Invalid metadata value, name argument was given multiple times");
        goto out;
      }
      name = sc_strdup(parts[i] + 5);
      name_len = lens[i] - 5;
      continue;
    }
    sc_buf_fmt(err, "Invalid metadata value given: %s", parts[i]);
    goto out;
  }
  if (name == NULL) {
    sc_buf_str(err, "Library name was not given");
    goto out;
  }
  if (!fn_name_ok(name, name_len)) {
    sc_buf_str(err, "Library names can only contain letters, numbers, or underscores(_) and must be at least one character long");
    goto out;
  }
  if (strcasecmp(parts[0] + 2, "lua") != 0) {
    sc_buf_fmt(err, "Engine '%s' not found", parts[0] + 2);
    goto out;
  }
  FnLib* old = fn_lib_find(ctx, name, strlen(name));
  if (old != NULL && !replace) {
    sc_buf_fmt(err, "Library '%s' already exists", name);
    goto out;
  }
  if (old != NULL) {
    fn_unlink(ctx, old);
  }
  FnLib* li = io_mem(calloc(1, sizeof(FnLib)));
  li->name = sc_strdup(name);
  li->code = io_mem(malloc(n + 1));
  memcpy(li->code, code, n);
  li->code[n] = '\0';
  li->code_len = n;
  if (!fn_engine_create(li, end, n - shebang_len, timed, err)) {
    goto fail;
  }
  if (li->n == 0) {
    sc_buf_str(err, "No functions registered");
    goto fail;
  }
  for (int j = 0; j < li->n; j += 1) {
    if (fn_find(ctx, li->fs[j]->name, strlen(li->fs[j]->name)) != NULL) {
      sc_buf_fmt(err, "Function %s already exists", li->fs[j]->name);
      goto fail;
    }
  }
  fn_link(ctx, li);
  fn_lib_free(old);
  ok = 1;
  goto out;
fail:
  fn_lib_free(li);
  if (old != NULL) {
    fn_link(ctx, old);
  }
out:
  free(name);
  sc_split_free(parts, numparts);
  free(lens);
  return ok;
}

// libraryJoin: src's libraries taken into dst, those of the same names
// replaced if replace; 1, or 0 and the error's text, dst as it was
static int fn_join(FnCtx* dst, FnCtx* src, int replace, ScBuf* err) {
  FnCtx old = { NULL, 0 };
  int ok = 0;
  for (int i = 0; i < src->n; i += 1) {
    FnLib* li = src->libs[i];
    FnLib* had = fn_lib_find(dst, li->name, strlen(li->name));
    if (had != NULL) {
      if (!replace) {
        sc_buf_fmt(err, "Library %s already exists", li->name);
        goto done;
      }
      fn_unlink(dst, had);
      fn_link(&old, had);
    }
  }
  for (int i = 0; i < src->n; i += 1) {
    FnLib* li = src->libs[i];
    for (int j = 0; j < li->n; j += 1) {
      if (fn_find(dst, li->fs[j]->name, strlen(li->fs[j]->name)) != NULL) {
        sc_buf_fmt(err, "Function %s already exists", li->fs[j]->name);
        goto done;
      }
    }
  }
  for (int i = 0; i < src->n; i += 1) {
    fn_link(dst, src->libs[i]);
  }
  free(src->libs);
  src->libs = NULL;
  src->n = 0;
  fn_ctx_clear(&old);
  ok = 1;
done:
  if (!ok) {
    for (int i = 0; i < old.n; i += 1) {
      fn_link(dst, old.libs[i]);
    }
    free(old.libs);
  }
  return ok;
}

// the libraries' codes of a RESP array of bulk strings
typedef struct {
  const char** p;
  size_t* n;
  int count;
} FnCodes;

static int fn_codes_read(const char* p, size_t n, FnCodes* out) {
  out->p = NULL;
  out->n = NULL;
  out->count = 0;
  const char* end = p + n;
  if (n == 0 || p[0] != '*') {
    return 0;
  }
  long long count = 0;
  const char* q = memchr(p, '\r', n);
  if (q == NULL || !string2ll(p + 1, (size_t)(q - p - 1), &count) || count < 0) {
    return 0;
  }
  p = q + 2;
  out->p = io_mem(calloc((size_t)count + 1, sizeof(char*)));
  out->n = io_mem(calloc((size_t)count + 1, sizeof(size_t)));
  for (long long j = 0; j < count; j += 1) {
    long long len;
    if (p >= end || p[0] != '$') {
      return 0;
    }
    q = memchr(p, '\r', (size_t)(end - p));
    if (q == NULL || !string2ll(p + 1, (size_t)(q - p - 1), &len) || len < 0 || q + 2 + len + 2 > end) {
      return 0;
    }
    out->p[j] = q + 2;
    out->n[j] = (size_t)len;
    out->count += 1;
    p = q + 2 + len + 2;
  }
  return 1;
}

static void fn_codes_free(FnCodes* c) {
  free((void*)c->p);
  free(c->n);
}

// a run of loads, on the script's stack: FUNCTION LOAD's library made in
// the server's set, or FUNCTION RESTORE's in a set of their own, taken in
// by its policy (functionRestoreCommand); done with the library's name
// (LOAD) or nothing, or an error's text
static void fn_load_main(ScRun* r) {
  r->err = 0;
  r->nostats = 0;
  sc_buf_clear(&r->out);
  FnCodes codes;
  ScBuf err = { 0 };
  if (!fn_codes_read(r->codes, r->codes_len, &codes)) {
    fn_codes_free(&codes);
    sc_buf_str(&r->out, "ERR the libraries came in no array");
    r->err = 1;
    return;
  }
  // (a library's redis.log leaves its line in out: each answer clears it)
  if (r->policy == FN_LOAD || r->policy == FN_LOAD_REPLACE) {
    int ok = codes.count == 1 && fn_create(codes.p[0], codes.n[0], r->policy == FN_LOAD_REPLACE, &fn_cur, r->timed, &err);
    sc_buf_clear(&r->out);
    if (ok) {
      FnLib* li = fn_cur.libs[fn_cur.n - 1];
      sc_buf_str(&r->out, li->name);
    } else {
      sc_buf_str(&r->out, "ERR ");
      sc_buf_add(&r->out, err.p == NULL ? "" : err.p, err.n);
      r->err = 1;
    }
  } else {
    // RESTORE's libraries made in a set of their own, in turn; a read of
    // the payload that failed after them (the last code, its error's
    // text: tail) fails it once they are made, as Redis's loop makes each
    // library it reads before it reads the next
    FnCtx tmp = { NULL, 0 };
    int ok = 1;
    int made = codes.count - (r->tail && codes.count > 0 ? 1 : 0);
    for (int j = 0; j < made && ok; j += 1) {
      ok = fn_create(codes.p[j], codes.n[j], 0, &tmp, r->timed, &err);
    }
    if (ok && made < codes.count) {
      sc_buf_add(&err, codes.p[made], codes.n[made]);
      ok = 0;
    }
    if (ok && r->policy == FN_FLUSH) {
      fn_ctx_clear(&fn_cur);
      fn_cur = tmp;
      tmp.libs = NULL;
      tmp.n = 0;
    } else if (ok) {
      ok = fn_join(&fn_cur, &tmp, r->policy == FN_REPLACE, &err);
    }
    sc_buf_clear(&r->out);
    if (!ok) {
      sc_buf_str(&r->out, "ERR ");
      sc_buf_add(&r->out, err.p == NULL ? "" : err.p, err.n);
      r->err = 1;
    }
    fn_ctx_clear(&tmp);
  }
  free(err.p);
  fn_codes_free(&codes);
}

// a run of an FCALL's function, on the script's stack: luaEngineCall
static void fn_main(ScRun* r) {
  lua_State* L = fn_lua;
  r->err = 0;
  r->nostats = 0;
  lua_getfield(L, LUA_REGISTRYINDEX, FN_ERROR_HANDLER);
  lua_rawgeti(L, LUA_REGISTRYINDEX, r->fref);
  lua_sethook(L, sc_hook, LUA_MASKCOUNT, 100000);
  sc_push_array(L, r->keys, r->keys_len);
  sc_push_array(L, r->args, r->args_len);
  int err = lua_pcall(L, 2, 1, -4);
  sc_finish(r, L, err, r->fname);
}

// the body of a run, on the script's stack
static void sc_main(void) {
  ScRun* r = &sc_run;
#ifdef SC_ASAN
  __sanitizer_finish_switch_fiber(NULL, &r->host_bottom, &r->host_size);
#endif
  switch (r->mode) {
  case SC_MODE_FUNCTION:
    fn_main(r);
    break;
  case SC_MODE_LOAD:
    fn_load_main(r);
    break;
  default:
    sc_main_script(r);
    break;
  }
  r->kind = SC_DONE;
  r->live = 0;
#ifdef SC_ASAN
  __sanitizer_start_switch_fiber(NULL, r->host_bottom, r->host_size);
#endif
#ifdef SC_TSAN
  __tsan_switch_to_fiber(r->tsan_host, 0);
#endif
  swapcontext(&r->me, &r->host);
}

// the step as a Term for Bend: a Step{w, s}
static Term sc_step(Env e, ScRun* r) {
  u64 word = (u64)r->kind | ((u64)r->resp << 4) | ((u64)(r->err ? 1 : 0) << 8)
    | ((u64)(r->nostats ? 1 : 0) << 9) | ((u64)r->repl << 10)
    | ((u64)r->level << 12);
  return io_node(e, CID(Step), (Term)word,
    io_raw(e, r->out.p == NULL ? "" : r->out.p, r->out.n));
}

static Term sc_done_error(Env e, ScRun* r, const char* msg) {
  r->kind = SC_DONE;
  r->err = 1;
  r->nostats = 0;
  sc_buf_clear(&r->out);
  sc_buf_str(&r->out, msg);
  return sc_step(e, r);
}

// The effects
// -----------

#ifdef CID(Engine.load)

// Engine.load(body): a Step of 1 + (flags << 1) and the sha, or of 0
// and the error
Term engine_load_run(Env e, Term* f, IoWork* w) {
  (void)w;
  sc_ensure();
  u64 n = 0;
  char* body = io_craw(e, f[0], &n);
  if (body == NULL) {
    return io_node(e, CID(Step), (Term)0, io_raw(e, "ERR a script is bytes", 21));
  }
  char sha[41];
  uint32_t flags = 0;
  ScBuf err = { 0 };
  Term out;
  if (sc_create_function(body, n, sha, &flags, &err)) {
    out = io_node(e, CID(Step), (Term)(1 | ((u64)flags << 1)), io_raw(e, sha, 40));
  } else {
    out = io_node(e, CID(Step), (Term)0, io_raw(e, err.p == NULL ? "" : err.p, err.n));
  }
  free(err.p);
  free(body);
  return out;
}

static void __attribute__((constructor)) engine_load_use(void) {
  io_eff(CID(Engine.load), engine_load_run);
}

#endif

#ifdef CID(Engine.find)

// Engine.find(sha): 0 when no script has the sha, else 1 + (flags << 1)
Term engine_find_run(Env e, Term* f, IoWork* w) {
  (void)w;
  sc_ensure();
  u64 n = 0;
  char* hex = io_craw(e, f[0], &n);
  if (hex == NULL) {
    return (Term)0;
  }
  uint8_t bin[20];
  Term out = (Term)0;
  if (sc_hex_to_bin(hex, n, bin)) {
    ScScript* s = sc_script_find(bin);
    if (s != NULL) {
      out = (Term)(1 | ((u64)s->flags << 1));
    }
  }
  free(hex);
  return out;
}

static void __attribute__((constructor)) engine_find_use(void) {
  io_eff(CID(Engine.find), engine_find_run);
}

#endif

#ifdef CID(Engine.start)

// Engine.start(name, keys, args, word): the run's first step, of the
// script of the sha name (EVAL and its kin) or of the function of that
// name (FCALL, FCALL_RO). keys and args are RESP arrays; word holds the
// caller's protocol (bits 0 to 3), whether the command was one of the
// read-only ones (bit 4) and whether it is EVAL rather than FCALL (bit 5).
Term engine_start_run(Env e, Term* f, IoWork* w) {
  (void)w;
  sc_ensure();
  ScRun* r = &sc_run;
  if (r->live) {
    return sc_done_error(e, r, "ERR a script is running already");
  }
  u64 word = (u64)f[3];
  u64 n = 0;
  char* name = io_craw(e, f[0], &n);
  uint32_t flags;
  if ((word >> 5) & 1) {
    uint8_t bin[20];
    if (name == NULL || !sc_hex_to_bin(name, n, bin)) {
      free(name);
      return sc_done_error(e, r, "NOSCRIPT No matching script. Please use EVAL.");
    }
    ScScript* s = sc_script_find(bin);
    if (s == NULL) {
      free(name);
      return sc_done_error(e, r, "NOSCRIPT No matching script. Please use EVAL.");
    }
    r->funcname[0] = 'f';
    r->funcname[1] = '_';
    sc_bin_to_hex(bin, r->funcname + 2);
    r->mode = SC_MODE_SCRIPT;
    flags = s->flags;
  } else {
    fn_ensure();
    FnFunc* fn = name == NULL ? NULL : fn_find(&fn_cur, name, n);
    if (fn == NULL) {
      free(name);
      return sc_done_error(e, r, "ERR Function not found");
    }
    r->mode = SC_MODE_FUNCTION;
    r->fref = fn->ref;
    free(r->fname);
    r->fname = sc_strdup(fn->name);
    flags = fn->flags;
  }
  free(name);
  free(r->keys);
  free(r->args);
  r->keys = io_craw(e, f[1], &r->keys_len);
  r->args = io_craw(e, f[2], &r->args_len);
  r->caller_resp = (int)(word & 15) == 3 ? 3 : 2;
  r->ro = (int)((word >> 4) & 1);
  r->eval = (int)((word >> 5) & 1);
  r->resp = 2;
  r->repl = SC_REPL_AOF | SC_REPL_REPLICA;
  r->killed = 0;
  r->flags = flags;
  r->level = 0;
  r->err = 0;
  r->nostats = 0;
  r->live = 1;
  getcontext(&r->me);
  r->me.uc_stack.ss_sp = r->stack;
  r->me.uc_stack.ss_size = r->stack_size;
  r->me.uc_link = NULL;
  makecontext(&r->me, sc_main, 0);
#ifdef SC_TSAN
  r->tsan_host = __tsan_get_current_fiber();
  r->tsan_me = __tsan_create_fiber(0);
#endif
  sc_enter(r);
#ifdef SC_TSAN
  if (!r->live) {
    __tsan_destroy_fiber(r->tsan_me);
    r->tsan_me = NULL;
  }
#endif
  return sc_step(e, r);
}

static void __attribute__((constructor)) engine_start_use(void) {
  io_eff(CID(Engine.start), engine_start_run);
}

#endif

#ifdef CID(Engine.next)

// Engine.next(word, data): the next step, after a reply (0, its bytes),
// a go-ahead (1) or a kill (2)
Term engine_next_run(Env e, Term* f, IoWork* w) {
  (void)w;
  ScRun* r = &sc_run;
  if (!r->live) {
    return sc_done_error(e, r, "ERR no script is running");
  }
  u64 n = 0;
  char* data = io_craw(e, f[1], &n);
  if (data == NULL) {
    data = sc_strdup("");
    n = 0;
  }
  r->verdict = (int)((u64)f[0] & 3);
  r->in = data;
  r->in_len = n;
  sc_enter(r);
  r->in = NULL;
  free(data);
#ifdef SC_TSAN
  if (!r->live && r->tsan_me != NULL) {
    __tsan_destroy_fiber(r->tsan_me);
    r->tsan_me = NULL;
  }
#endif
  return sc_step(e, r);
}

static void __attribute__((constructor)) engine_next_use(void) {
  io_eff(CID(Engine.next), engine_next_run);
}

#endif

#ifdef CID(Engine.deprecated)

// Engine.deprecated(on): lua-enable-deprecated-api, as the start reads it
// (1: yes), for the states made from then on
Term engine_deprecated_run(Env e, Term* f, IoWork* w) {
  (void)e; (void)w;
  sc_lua_enable_deprecated_api = (u64)f[0] != 0;
  return term_pak(CID(Unit), 0);
}

static void __attribute__((constructor)) engine_deprecated_use(void) {
  io_eff(CID(Engine.deprecated), engine_deprecated_run);
}

#endif

#ifdef CID(Engine.flush)

// Engine.flush(): the cache emptied and the state made anew, SCRIPT FLUSH
Term engine_flush_run(Env e, Term* f, IoWork* w) {
  (void)e; (void)f; (void)w;
  if (sc_lua != NULL) {
    // a full collection first, as eval.c's scriptingRelease does since the
    // fix of CVE-2024-46981: closed in the middle of a cycle, Lua could
    // free a userdata that a __gc callback still reads
    lua_gc(sc_lua, LUA_GCCOLLECT, 0);
    lua_close(sc_lua);
    sc_lua = NULL;
  }
  sc_scripts_clear();
  sc_ensure();
  return term_pak(CID(Unit), 0);
}

static void __attribute__((constructor)) engine_flush_use(void) {
  io_eff(CID(Engine.flush), engine_flush_run);
}

#endif

#ifdef CID(Engine.count)

// Engine.count(): how many scripts the cache holds
Term engine_count_run(Env e, Term* f, IoWork* w) {
  (void)e; (void)f; (void)w;
  return (Term)(u64)sc_scripts_n;
}

static void __attribute__((constructor)) engine_count_use(void) {
  io_eff(CID(Engine.count), engine_count_run);
}

#endif

#ifdef CID(Engine.mem)

// Engine.mem(): the bytes the Lua state holds
Term engine_mem_run(Env e, Term* f, IoWork* w) {
  (void)e; (void)f; (void)w;
  u64 lua_mem = 0;
  if (sc_lua != NULL) {
    lua_mem = (u64)lua_gc(sc_lua, LUA_GCCOUNT, 0) * 1024
      + (u64)lua_gc(sc_lua, LUA_GCCOUNTB, 0);
  }
  return (Term)(lua_mem & 0xFFFFFFFFu);
}

static void __attribute__((constructor)) engine_mem_use(void) {
  io_eff(CID(Engine.mem), engine_mem_run);
}

#endif

#ifdef CID(Engine.cache_mem)

// Engine.cache_mem(): the bytes the cache of scripts holds
Term engine_cache_mem_run(Env e, Term* f, IoWork* w) {
  (void)e; (void)f; (void)w;
  return (Term)((u64)sc_scripts_mem & 0xFFFFFFFFu);
}

static void __attribute__((constructor)) engine_cache_mem_use(void) {
  io_eff(CID(Engine.cache_mem), engine_cache_mem_run);
}

#endif

// Functions' effects
// ------------------
// Only a load makes the functions' Lua state (fn_ensure); the others read
// or change the libraries there are, none before the first load, so that
// a server that runs no function, and a start that finds none to load,
// make no state (Redis makes it at its start: an empty one, whose bytes
// INFO shows as used_memory_vm_functions; BendKV's is 0 until a load)

// stringmatchlen, with the bound on nesting of Redis's fix for
// CVE-2024-31228: FUNCTION LIST's LIBRARYNAME pattern, which matches in
// any case
static int fn_match_impl(const char* pattern, int patternLen, const char* string,
  int stringLen, int nocase, int* skipLongerMatches, int nesting) {
  if (nesting > 1000) {
    return 0;
  }
  while (patternLen && stringLen) {
    switch (pattern[0]) {
    case '*':
      while (patternLen && pattern[1] == '*') {
        pattern++;
        patternLen--;
      }
      if (patternLen == 1) {
        return 1;
      }
      while (stringLen) {
        if (fn_match_impl(pattern + 1, patternLen - 1, string, stringLen, nocase,
            skipLongerMatches, nesting + 1)) {
          return 1;
        }
        if (*skipLongerMatches) {
          return 0;
        }
        string++;
        stringLen--;
      }
      *skipLongerMatches = 1;
      return 0;
    case '?':
      string++;
      stringLen--;
      break;
    case '[': {
      int not, match;
      pattern++;
      patternLen--;
      not = pattern[0] == '^';
      if (not) {
        pattern++;
        patternLen--;
      }
      match = 0;
      while (1) {
        if (pattern[0] == '\\' && patternLen >= 2) {
          pattern++;
          patternLen--;
          if (pattern[0] == string[0]) {
            match = 1;
          }
        } else if (pattern[0] == ']') {
          break;
        } else if (patternLen == 0) {
          pattern--;
          patternLen++;
          break;
        } else if (patternLen >= 3 && pattern[1] == '-') {
          int start = pattern[0];
          int end = pattern[2];
          int c = string[0];
          if (start > end) {
            int t = start;
            start = end;
            end = t;
          }
          if (nocase) {
            start = tolower(start);
            end = tolower(end);
            c = tolower(c);
          }
          pattern += 2;
          patternLen -= 2;
          if (c >= start && c <= end) {
            match = 1;
          }
        } else {
          if (!nocase) {
            if (pattern[0] == string[0]) {
              match = 1;
            }
          } else {
            if (tolower((int)pattern[0]) == tolower((int)string[0])) {
              match = 1;
            }
          }
        }
        pattern++;
        patternLen--;
      }
      if (not) {
        match = !match;
      }
      if (!match) {
        return 0;
      }
      string++;
      stringLen--;
      break;
    }
    case '\\':
      if (patternLen >= 2) {
        pattern++;
        patternLen--;
      }
      // fall through
    default:
      if (!nocase) {
        if (pattern[0] != string[0]) {
          return 0;
        }
      } else {
        if (tolower((int)pattern[0]) != tolower((int)string[0])) {
          return 0;
        }
      }
      string++;
      stringLen--;
      break;
    }
    pattern++;
    patternLen--;
    if (stringLen == 0) {
      while (*pattern == '*') {
        pattern++;
        patternLen--;
      }
      break;
    }
  }
  if (patternLen == 0 && stringLen == 0) {
    return 1;
  }
  return 0;
}

static int fn_match(const char* pattern, size_t plen, const char* s, size_t slen) {
  int skip = 0;
  return fn_match_impl(pattern, (int)plen, s, (int)slen, 1, &skip, 0);
}

// the bytes of a reply in a protocol (2 or 3)
static void fn_map_len(ScBuf* b, int resp, long n) {
  if (resp == 3) {
    sc_buf_fmt(b, "%%%ld\r\n", n);
  } else {
    sc_buf_fmt(b, "*%ld\r\n", 2 * n);
  }
}

static void fn_set_len(ScBuf* b, int resp, long n) {
  sc_buf_fmt(b, resp == 3 ? "~%ld\r\n" : "*%ld\r\n", n);
}

static void fn_null(ScBuf* b, int resp) {
  sc_buf_str(b, resp == 3 ? "_\r\n" : "$-1\r\n");
}

static void fn_bulk_str(ScBuf* b, const char* s) {
  sc_bulk(b, s, strlen(s));
}

// functionListCommand's reply for a library
static void fn_list_lib(ScBuf* b, int resp, FnLib* li, int with_code) {
  fn_map_len(b, resp, with_code ? 4 : 3);
  fn_bulk_str(b, "library_name");
  fn_bulk_str(b, li->name);
  fn_bulk_str(b, "engine");
  fn_bulk_str(b, "LUA");
  fn_bulk_str(b, "functions");
  sc_buf_fmt(b, "*%d\r\n", li->n);
  for (int j = 0; j < li->n; j += 1) {
    FnFunc* f = li->fs[j];
    fn_map_len(b, resp, 3);
    fn_bulk_str(b, "name");
    fn_bulk_str(b, f->name);
    fn_bulk_str(b, "description");
    if (f->desc != NULL) {
      fn_bulk_str(b, f->desc);
    } else {
      fn_null(b, resp);
    }
    fn_bulk_str(b, "flags");
    int count = 0;
    for (const ScFlagDef* flag = sc_flags_def; flag->str; ++flag) {
      if (f->flags & flag->flag) {
        count += 1;
      }
    }
    fn_set_len(b, resp, count);
    for (const ScFlagDef* flag = sc_flags_def; flag->str; ++flag) {
      if (f->flags & flag->flag) {
        sc_buf_fmt(b, "+%s\r\n", flag->str);
      }
    }
  }
  if (with_code) {
    fn_bulk_str(b, "library_code");
    sc_bulk(b, li->code, li->code_len);
  }
}

// the libraries' codes, as a RESP array (DUMP, the RDB file, the rewrite)
static void fn_codes_out(ScBuf* b) {
  sc_buf_fmt(b, "*%d\r\n", fn_cur.n);
  for (int i = 0; i < fn_cur.n; i += 1) {
    sc_bulk(b, fn_cur.libs[i]->code, fn_cur.libs[i]->code_len);
  }
}

static Term fn_buf_term(Env e, ScBuf* b) {
  Term t = io_raw(e, b->p == NULL ? "" : b->p, b->n);
  free(b->p);
  return t;
}

#ifdef CID(Engine.fload)

// Engine.fload(codes, word): a run of loads, its libraries' codes a RESP
// array; word: how to take them in (bits 0 to 2: FN_LOAD to FN_FLUSH),
// whether FUNCTION LOAD's limit of 500 ms holds them (bit 3), and whether
// the last code is the error's text of RESTORE's read that failed after
// the others (bit 4). Its steps are log lines and done, with the
// library's name (FN_LOAD and FN_LOAD_REPLACE) or nothing, or an error's
// text.
Term engine_fload_run(Env e, Term* f, IoWork* w) {
  (void)w;
  sc_ensure();
  fn_ensure();
  ScRun* r = &sc_run;
  if (r->live) {
    return sc_done_error(e, r, "ERR a script is running already");
  }
  free(r->codes);
  r->codes = io_craw(e, f[0], &r->codes_len);
  if (r->codes == NULL) {
    r->codes = sc_strdup("");
    r->codes_len = 0;
  }
  u64 word = (u64)f[1];
  r->mode = SC_MODE_LOAD;
  r->policy = (int)(word & 7);
  r->timed = (int)((word >> 3) & 1);
  r->tail = (int)((word >> 4) & 1);
  r->resp = 2;
  r->repl = SC_REPL_AOF | SC_REPL_REPLICA;
  r->killed = 0;
  r->flags = 0;
  r->level = 0;
  r->err = 0;
  r->nostats = 0;
  r->live = 1;
  getcontext(&r->me);
  r->me.uc_stack.ss_sp = r->stack;
  r->me.uc_stack.ss_size = r->stack_size;
  r->me.uc_link = NULL;
  makecontext(&r->me, sc_main, 0);
#ifdef SC_TSAN
  r->tsan_host = __tsan_get_current_fiber();
  r->tsan_me = __tsan_create_fiber(0);
#endif
  sc_enter(r);
#ifdef SC_TSAN
  if (!r->live) {
    __tsan_destroy_fiber(r->tsan_me);
    r->tsan_me = NULL;
  }
#endif
  return sc_step(e, r);
}

static void __attribute__((constructor)) engine_fload_use(void) {
  io_eff(CID(Engine.fload), engine_fload_run);
}

#endif

#ifdef CID(Engine.fdelete)

// Engine.fdelete(name): FUNCTION DELETE; 1 when the library was there
Term engine_fdelete_run(Env e, Term* f, IoWork* w) {
  (void)w;
  u64 n = 0;
  char* name = io_craw(e, f[0], &n);
  Term out = (Term)0;
  if (name != NULL) {
    FnLib* li = fn_lib_find(&fn_cur, name, n);
    if (li != NULL) {
      fn_unlink(&fn_cur, li);
      fn_lib_free(li);
      out = (Term)1;
    }
  }
  free(name);
  return out;
}

static void __attribute__((constructor)) engine_fdelete_use(void) {
  io_eff(CID(Engine.fdelete), engine_fdelete_run);
}

#endif

#ifdef CID(Engine.fflush)

// Engine.fflush(): FUNCTION FLUSH, every library gone
Term engine_fflush_run(Env e, Term* f, IoWork* w) {
  (void)e; (void)f; (void)w;
  fn_ctx_clear(&fn_cur);
  return term_pak(CID(Unit), 0);
}

static void __attribute__((constructor)) engine_fflush_use(void) {
  io_eff(CID(Engine.fflush), engine_fflush_run);
}

#endif

#ifdef CID(Engine.flist)

// Engine.flist(pattern, word): FUNCTION LIST's reply; word: WITHCODE
// (bit 0), LIBRARYNAME given (bit 1), the protocol (bits 4 to 7)
Term engine_flist_run(Env e, Term* f, IoWork* w) {
  (void)w;
  u64 n = 0;
  char* pat = io_craw(e, f[0], &n);
  u64 word = (u64)f[1];
  int with_code = (int)(word & 1);
  int has_pat = (int)((word >> 1) & 1);
  int resp = (int)((word >> 4) & 15) == 3 ? 3 : 2;
  int count = 0;
  for (int i = 0; i < fn_cur.n; i += 1) {
    FnLib* li = fn_cur.libs[i];
    if (!has_pat || pat == NULL || fn_match(pat, n, li->name, strlen(li->name))) {
      count += 1;
    }
  }
  ScBuf b = { 0 };
  sc_buf_fmt(&b, "*%d\r\n", count);
  for (int i = 0; i < fn_cur.n; i += 1) {
    FnLib* li = fn_cur.libs[i];
    if (!has_pat || pat == NULL || fn_match(pat, n, li->name, strlen(li->name))) {
      fn_list_lib(&b, resp, li, with_code);
    }
  }
  free(pat);
  return fn_buf_term(e, &b);
}

static void __attribute__((constructor)) engine_flist_use(void) {
  io_eff(CID(Engine.flist), engine_flist_run);
}

#endif

#ifdef CID(Engine.fcodes)

// Engine.fcodes(): the libraries' codes, a RESP array
Term engine_fcodes_run(Env e, Term* f, IoWork* w) {
  (void)f; (void)w;
  ScBuf b = { 0 };
  fn_codes_out(&b);
  return fn_buf_term(e, &b);
}

static void __attribute__((constructor)) engine_fcodes_use(void) {
  io_eff(CID(Engine.fcodes), engine_fcodes_run);
}

#endif

#ifdef CID(Engine.ffuncs)

// Engine.ffuncs(): the functions, for the actor's mirror: a RESP array
// of each one's name in lower case and its flags in decimal
Term engine_ffuncs_run(Env e, Term* f, IoWork* w) {
  (void)f; (void)w;
  ScBuf b = { 0 };
  sc_buf_fmt(&b, "*%d\r\n", 2 * fn_count(&fn_cur));
  for (int i = 0; i < fn_cur.n; i += 1) {
    FnLib* li = fn_cur.libs[i];
    for (int j = 0; j < li->n; j += 1) {
      size_t len = strlen(li->fs[j]->name);
      char* low = io_mem(malloc(len + 1));
      for (size_t k = 0; k < len; k += 1) {
        low[k] = (char)tolower((unsigned char)li->fs[j]->name[k]);
      }
      low[len] = '\0';
      sc_bulk(&b, low, len);
      free(low);
      char num[16];
      int m = snprintf(num, sizeof(num), "%u", li->fs[j]->flags);
      sc_bulk(&b, num, (size_t)m);
    }
  }
  return fn_buf_term(e, &b);
}

static void __attribute__((constructor)) engine_ffuncs_use(void) {
  io_eff(CID(Engine.ffuncs), engine_ffuncs_run);
}

#endif

#ifdef CID(Engine.fcount)

// Engine.fcount(which): the libraries (0) or the functions (1)
Term engine_fcount_run(Env e, Term* f, IoWork* w) {
  (void)e; (void)w;
  u64 which = (u64)f[0];
  return (Term)(u64)(which == 0 ? fn_cur.n : fn_count(&fn_cur));
}

static void __attribute__((constructor)) engine_fcount_use(void) {
  io_eff(CID(Engine.fcount), engine_fcount_run);
}

#endif

#ifdef CID(Engine.fmem)

// Engine.fmem(which): INFO's bytes of the functions: the Lua state's
// (0: used_memory_vm_functions, luaEngineGetUsedMemoy), or their
// structures' (1: used_memory_functions, functionsMemoryOverhead's, here
// the bytes of their names, descriptions and codes and of the records
// that hold them)
Term engine_fmem_run(Env e, Term* f, IoWork* w) {
  (void)e; (void)w;
  u64 which = (u64)f[0];
  u64 out = 0;
  if (which == 0) {
    if (fn_lua != NULL) {
      out = (u64)lua_gc(fn_lua, LUA_GCCOUNT, 0) * 1024 + (u64)lua_gc(fn_lua, LUA_GCCOUNTB, 0);
    }
  } else {
    for (int i = 0; i < fn_cur.n; i += 1) {
      FnLib* li = fn_cur.libs[i];
      out += sizeof(FnLib) + strlen(li->name) + 1 + li->code_len + 1;
      for (int j = 0; j < li->n; j += 1) {
        FnFunc* fn = li->fs[j];
        out += sizeof(FnFunc) + strlen(fn->name) + 1 + (fn->desc != NULL ? strlen(fn->desc) + 1 : 0);
      }
    }
  }
  return (Term)(out & 0xFFFFFFFFu);
}

static void __attribute__((constructor)) engine_fmem_use(void) {
  io_eff(CID(Engine.fmem), engine_fmem_run);
}

#endif
