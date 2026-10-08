// loadgen.c: a light load generator for Redis-protocol servers, so that one
// core of a small machine can load a server on the others (memtier needs
// more than one core for a million requests a second). One thread, epoll,
// C connections, each keeping P requests in flight, as memtier's --pipeline
// does: a write sends as many new requests as replies came in since the
// last one. Keys are "key:<n>" with n uniform
// below the key space; SET values are V bytes. A run first sets every key
// once (unless -L 0), then measures for S seconds after a second of warm-up
// and prints requests per second.
//
//   cc -O2 -o loadgen tools/loadgen.c
//   taskset -c 0 ./loadgen -p 6380 -c 100 -P 10 -s 10 -r 1000000 -d 100 -g 1.0
//
// -g is the share of GETs (the rest are SETs). With -m K, each GET is an
// MGET of K keys instead.
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#include <arpa/inet.h>

typedef struct {
  int    fd;
  char*  out;
  size_t out_len, out_at, out_cap;
  char*  in;
  size_t in_len, in_cap;
  int    want;
} Conn;

static int    port = 6380, nconn = 50, pipe_n = 1, secs = 10, mget = 0;
static long   keys = 1000000;
static int    vsize = 100;
static double gets = 1.0;
static int    preload = 1;
static char*  value;
static uint64_t rng = 88172645463325252ull;

static uint64_t next_rand(void) {
  rng ^= rng << 13;
  rng ^= rng >> 7;
  rng ^= rng << 17;
  return rng;
}

static double now_s(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void put(char** b, size_t* len, size_t* cap, const char* s, size_t n) {
  if (*len + n > *cap) {
    *cap = (*len + n) * 2;
    *b   = realloc(*b, *cap);
  }
  memcpy(*b + *len, s, n);
  *len += n;
}

static void put_bulk(char** b, size_t* len, size_t* cap, const char* s, size_t n) {
  char h[32];
  int  k = snprintf(h, sizeof h, "$%zu\r\n", n);
  put(b, len, cap, h, (size_t)k);
  put(b, len, cap, s, n);
  put(b, len, cap, "\r\n", 2);
}

// one request: a GET (or MGET of mget keys) or a SET of a random key
static void request(char** b, size_t* len, size_t* cap, int set) {
  char key[32];
  char h[32];
  if (set) {
    put(b, len, cap, "*3\r\n$3\r\nSET\r\n", 13);
    int k = snprintf(key, sizeof key, "key:%ld", (long)(next_rand() % (uint64_t)keys));
    put_bulk(b, len, cap, key, (size_t)k);
    put_bulk(b, len, cap, value, (size_t)vsize);
  } else if (mget > 0) {
    int k = snprintf(h, sizeof h, "*%d\r\n$4\r\nMGET\r\n", mget + 1);
    put(b, len, cap, h, (size_t)k);
    for (int i = 0; i < mget; i += 1) {
      k = snprintf(key, sizeof key, "key:%ld", (long)(next_rand() % (uint64_t)keys));
      put_bulk(b, len, cap, key, (size_t)k);
    }
  } else {
    put(b, len, cap, "*2\r\n$3\r\nGET\r\n", 13);
    int k = snprintf(key, sizeof key, "key:%ld", (long)(next_rand() % (uint64_t)keys));
    put_bulk(b, len, cap, key, (size_t)k);
  }
}

// the length of the complete reply at p (n bytes there), or 0
static size_t reply_len(const char* p, size_t n) {
  if (n < 3) {
    return 0;
  }
  const char* e = memchr(p, '\n', n);
  if (e == NULL) {
    return 0;
  }
  size_t line = (size_t)(e - p) + 1;
  if (p[0] == '$') {
    long len = atol(p + 1);
    if (len < 0) {
      return line;
    }
    return line + (size_t)len + 2 <= n ? line + (size_t)len + 2 : 0;
  }
  if (p[0] == '*') {
    long   k  = atol(p + 1);
    size_t at = line;
    for (long i = 0; i < k; i += 1) {
      size_t m = reply_len(p + at, n - at);
      if (m == 0) {
        return 0;
      }
      at += m;
    }
    return at;
  }
  return line;
}

// k new requests after what is left to send
static void fill(Conn* c, int k) {
  if (c->out_at > 0) {
    memmove(c->out, c->out + c->out_at, c->out_len - c->out_at);
    c->out_len -= c->out_at;
    c->out_at   = 0;
  }
  for (int i = 0; i < k; i += 1) {
    request(&c->out, &c->out_len, &c->out_cap, (double)(next_rand() % 1000000) / 1e6 >= gets);
  }
  c->want += k;
}

static int dial(void) {
  int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
  int one = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
  struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons((uint16_t)port) };
  inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
  if (connect(fd, (struct sockaddr*)&a, sizeof a) < 0 && errno != EINPROGRESS) {
    perror("connect");
    exit(1);
  }
  return fd;
}

// sets every key once, over one connection, 1000 at a time
static void load(void) {
  int fd = dial();
  int fl = 0;
  struct timeval tv = { 30, 0 };
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  (void)fl;
  char*  b   = NULL;
  size_t cap = 0;
  char*  in  = malloc(1 << 20);
  for (long base = 0; base < keys; base += 1000) {
    size_t len = 0;
    long   m   = keys - base < 1000 ? keys - base : 1000;
    for (long i = 0; i < m; i += 1) {
      char key[32];
      put(&b, &len, &cap, "*3\r\n$3\r\nSET\r\n", 13);
      int k = snprintf(key, sizeof key, "key:%ld", base + i);
      put_bulk(&b, &len, &cap, key, (size_t)k);
      put_bulk(&b, &len, &cap, value, (size_t)vsize);
    }
    for (size_t at = 0; at < len;) {
      ssize_t n = send(fd, b + at, len - at, MSG_NOSIGNAL);
      if (n > 0) {
        at += (size_t)n;
      } else if (n < 0 && errno != EAGAIN) {
        perror("send");
        exit(1);
      }
    }
    long got = 0;
    while (got < m * 5) {
      ssize_t n = recv(fd, in, 1 << 20, 0);
      if (n > 0) {
        got += n;
      } else if (n == 0 || errno != EAGAIN) {
        perror("recv");
        exit(1);
      }
    }
  }
  close(fd);
  free(in);
  free(b);
}

int main(int argc, char** argv) {
  int o;
  while ((o = getopt(argc, argv, "p:c:P:s:r:d:g:m:L:")) != -1) {
    switch (o) {
      case 'p': port = atoi(optarg); break;
      case 'c': nconn = atoi(optarg); break;
      case 'P': pipe_n = atoi(optarg); break;
      case 's': secs = atoi(optarg); break;
      case 'r': keys = atol(optarg); break;
      case 'd': vsize = atoi(optarg); break;
      case 'g': gets = atof(optarg); break;
      case 'm': mget = atoi(optarg); break;
      case 'L': preload = atoi(optarg); break;
      default:
        fprintf(stderr, "usage: loadgen -p port -c conns -P pipeline -s secs -r keys -d bytes -g get-share [-m mget] [-L 0]\n");
        return 2;
    }
  }
  value = malloc((size_t)vsize + 1);
  memset(value, 'x', (size_t)vsize);
  if (preload) {
    load();
  }
  int   ep = epoll_create1(0);
  Conn* cs = calloc((size_t)nconn, sizeof(Conn));
  for (int i = 0; i < nconn; i += 1) {
    Conn* c   = &cs[i];
    c->fd     = dial();
    c->in_cap = 1 << 16;
    c->in     = malloc(c->in_cap);
    fill(c, pipe_n);
    struct epoll_event ev = { .events = EPOLLIN | EPOLLOUT | EPOLLET, .data.ptr = c };
    epoll_ctl(ep, EPOLL_CTL_ADD, c->fd, &ev);
  }
  double start = now_s(), from = start + 1.0, end = from + secs;
  long   done = 0, counted = 0;
  int    measuring = 0;
  struct epoll_event evs[256];
  for (;;) {
    double t = now_s();
    if (!measuring && t >= from) {
      measuring = 1;
      counted   = done;
    }
    if (t >= end) {
      break;
    }
    int n = epoll_wait(ep, evs, 256, 100);
    for (int i = 0; i < n; i += 1) {
      Conn* c = evs[i].data.ptr;
      if (c->out_at < c->out_len) {
        ssize_t k = send(c->fd, c->out + c->out_at, c->out_len - c->out_at, MSG_NOSIGNAL);
        if (k > 0) {
          c->out_at += (size_t)k;
        }
      }
      for (;;) {
        if (c->in_len == c->in_cap) {
          c->in_cap *= 2;
          c->in = realloc(c->in, c->in_cap);
        }
        ssize_t k = recv(c->fd, c->in + c->in_len, c->in_cap - c->in_len, 0);
        if (k <= 0) {
          if (k == 0) {
            fprintf(stderr, "server closed a connection\n");
            return 1;
          }
          break;
        }
        c->in_len += (size_t)k;
      }
      size_t at  = 0;
      int    got = 0;
      while (c->want > 0) {
        size_t m = reply_len(c->in + at, c->in_len - at);
        if (m == 0) {
          break;
        }
        at      += m;
        c->want -= 1;
        got     += 1;
        done    += 1;
      }
      memmove(c->in, c->in + at, c->in_len - at);
      c->in_len -= at;
      if (got > 0) {
        fill(c, got);
        ssize_t k = send(c->fd, c->out + c->out_at, c->out_len - c->out_at, MSG_NOSIGNAL);
        if (k > 0) {
          c->out_at += (size_t)k;
        }
      }
    }
  }
  double span = now_s() - from;
  printf("%.0f\n", (double)(done - counted) / span);
  return 0;
}
