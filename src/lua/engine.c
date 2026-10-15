// The engine of BendKV's scripts
// ==============================
// Redis 7.0.15's own Lua (deps/redis/deps/lua: Lua 5.1.5 with Redis's
// changes, cjson, cmsgpack, struct and bit) with the glue of its script_lua.c,
// eval.c and script.c ported here, so that a script's results, errors,
// tostring, the order of pairs, table.sort and cjson are Redis's byte for
// byte. Bend declares the effects below in src/script.bend, and the
// compiler splices this file into the program after its runtime
// (bend2/guide/EFFECTS.md), so every runtime symbol is in scope.
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
//     ":1" when the command is known or ":0" when it is not.
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

#include <ctype.h>
#include <errno.h>
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <ucontext.h>

#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>

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

static void sc_double(ScRun* r, ScBuf* b, double d) {
  if (isinf(d)) {
    if (r->caller_resp == 2) {
      sc_buf_str(b, d > 0 ? "$3\r\ninf\r\n" : "$4\r\n-inf\r\n");
    } else {
      sc_buf_str(b, d > 0 ? ",inf\r\n" : ",-inf\r\n");
    }
    return;
  }
  char dbuf[5 * 1024 + 32];
  int n = snprintf(dbuf, sizeof(dbuf), "%.17g", d);
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
    sc_buf_fmt(b, ":%lld\r\n", (long long)lua_tonumber(L, -1));
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
// written as "%.17g", as Redis writes it; 0 and an error pushed when one
// is neither a string nor a number
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
      int n = snprintf(dbuf, sizeof(dbuf), "%.17g", (double)lua_tonumber(L, j + 1));
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
    sc_push_error(L, "redis.set_repl() requires two arguments.");
    return lua_error(L);
  }
  int flags = (int)lua_tonumber(L, -1);
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
  if (r->in[0] == ':' && r->in[1] == '1') {
    lua_pushboolean(L, 1);
    return 1;
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
  int level = (int)lua_tonumber(L, -argc);
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
  int resp = (int)lua_tonumber(L, -argc);
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
  if (!sc_run.live) {
    return luaL_error(L, "math.random can only be called inside a script invocation");
  }
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
  if (!sc_run.live) {
    return luaL_error(L, "math.randomseed can only be called inside a script invocation");
  }
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
  "xpcall", "tostring", "getfenv", "setmetatable", "next", "assert",
  "tonumber", "rawequal", "collectgarbage", "getmetatable", "rawset",
  "pcall", "coroutine", "type", "_G", "select", "unpack", "gcinfo",
  "pairs", "rawget", "loadstring", "ipairs", "_VERSION", "setfenv",
  "load", "error", NULL,
};

static const char* sc_lua_builtins_not_documented_allow_list[] = {
  "newproxy", NULL,
};

static const char* sc_lua_builtins_removed_after_initialization_allow_list[] = {
  "debug", NULL,
};

static const char** sc_allow_lists[] = {
  sc_libraries_allow_list,
  sc_redis_api_allow_list,
  sc_lua_builtins_allow_list,
  sc_lua_builtins_not_documented_allow_list,
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
  if (*allow_l) {
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

// REDIS_VERSION and REDIS_VERSION_NUM, Redis 7.0.15's
#define SC_REDIS_VERSION "7.0.15"
#define SC_REDIS_VERSION_NUM 0x0007000f

static void sc_register_redis_api(lua_State* L) {
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
  // eval.c's additions
  sc_set_field_fn(L, "breakpoint", sc_breakpoint);
  sc_set_field_fn(L, "debug", sc_debug);
  sc_set_field_fn(L, "replicate_commands", sc_replicate_commands);
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
  sc_register_redis_api(L);
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
// "..." and '...' and their escapes; NULL on unbalanced quotes
static char** sc_split(const char* line, int* argc) {
  const char* p = line;
  ScBuf current = { 0 };
  int have = 0;
  char** vector = NULL;
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
      vector[*argc] = sc_strdup(current.p);
      (*argc)++;
    } else {
      free(current.p);
      if (vector == NULL) vector = io_mem(malloc(sizeof(void*)));
      return vector;
    }
  }
err:
  while ((*argc)--) free(vector[*argc]);
  free(vector);
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
    const char* end = memchr(body, '\n', len);
    if (end == NULL) {
      sc_buf_str(err, "Invalid script shebang");
      return 0;
    }
    shebang_len = (size_t)(end - body);
    char* shebang = io_mem(malloc(shebang_len + 1));
    memcpy(shebang, body, shebang_len);
    shebang[shebang_len] = '\0';
    int numparts;
    char** parts = sc_split(shebang, &numparts);
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

// the body of a run, on the script's stack: luaCallFunction
static void sc_main(void) {
  ScRun* r = &sc_run;
#ifdef SC_ASAN
  __sanitizer_finish_switch_fiber(NULL, &r->host_bottom, &r->host_size);
#endif
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
  } else {
    lua_sethook(L, sc_hook, LUA_MASKCOUNT, 100000);
    sc_set_global_array(L, "KEYS", r->keys, r->keys_len);
    sc_set_global_array(L, "ARGV", r->args, r->args_len);
    int err = lua_pcall(L, 0, 1, -2);
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
        sc_buf_fmt(&r->out, "ERR Error running script %s, %.100s", r->funcname + 2, msg);
      } else {
        ScErrInfo info;
        sc_err_info(L, &info);
        sc_buf_str(&r->out, info.msg != NULL ? info.msg : "ERR execution failure");
        if (info.line != NULL && info.source != NULL) {
          sc_buf_fmt(&r->out, " script: %s, on ", r->funcname + 2);
          sc_buf_str(&r->out, info.source);
          sc_buf_add(&r->out, ":", 1);
          sc_buf_str(&r->out, info.line);
          sc_buf_add(&r->out, ".", 1);
        }
        r->nostats = info.ignore;
        sc_err_info_free(&info);
      }
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

// Engine.start(sha, keys, args, word): the run's first step. keys and
// args are RESP arrays; word holds the caller's protocol (bits 0 to 3),
// whether the command was EVAL_RO or EVALSHA_RO (bit 4) and whether it
// is EVAL rather than FCALL (bit 5).
Term engine_start_run(Env e, Term* f, IoWork* w) {
  (void)w;
  sc_ensure();
  ScRun* r = &sc_run;
  if (r->live) {
    return sc_done_error(e, r, "ERR a script is running already");
  }
  u64 n = 0;
  char* hex = io_craw(e, f[0], &n);
  uint8_t bin[20];
  if (hex == NULL || !sc_hex_to_bin(hex, n, bin)) {
    free(hex);
    return sc_done_error(e, r, "NOSCRIPT No matching script. Please use EVAL.");
  }
  ScScript* s = sc_script_find(bin);
  if (s == NULL) {
    free(hex);
    return sc_done_error(e, r, "NOSCRIPT No matching script. Please use EVAL.");
  }
  r->funcname[0] = 'f';
  r->funcname[1] = '_';
  sc_bin_to_hex(bin, r->funcname + 2);
  free(hex);
  free(r->keys);
  free(r->args);
  r->keys = io_craw(e, f[1], &r->keys_len);
  r->args = io_craw(e, f[2], &r->args_len);
  u64 word = (u64)f[3];
  r->caller_resp = (int)(word & 15) == 3 ? 3 : 2;
  r->ro = (int)((word >> 4) & 1);
  r->eval = (int)((word >> 5) & 1);
  r->resp = 2;
  r->repl = SC_REPL_AOF | SC_REPL_REPLICA;
  r->killed = 0;
  r->flags = s->flags;
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

#ifdef CID(Engine.flush)

// Engine.flush(): the cache emptied and the state made anew, SCRIPT FLUSH
Term engine_flush_run(Env e, Term* f, IoWork* w) {
  (void)e; (void)f; (void)w;
  if (sc_lua != NULL) {
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
